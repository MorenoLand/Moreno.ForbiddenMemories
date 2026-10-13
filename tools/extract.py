"""One command to prepare the game data from your own disc.

    python tools/extract.py                  # finds a .cue/.bin next to the project or uses FM_DISC; extracts everything
    python tools/extract.py "path/to/game.cue"
    python tools/extract.py --screens        # only what you name: --cards --tables --images --screens --text --audio
    python tools/extract.py --audio          # menu sound effects as WAV (the default run includes them too)
    python tools/extract.py --mod mods/assets-hd   # images replaced by a mod's texture pack (default: every enabled mod under mods/)
    python tools/extract.py --mods-only      # apply the mods to the images already baked, no disc needed

Reads the disc image directly (nothing is written but the finished assets), and creates under assets/:
    data/cards.json        names, types, attributes, levels, guardian stars, ATK/DEF, password, starchips
    data/fusions.json      every fusion recipe: materials a and b, result (names and ids)
    data/equips.json       each equip card, its ATK/DEF bonus and the monsters it may equip
    data/rituals.json      each ritual card: its three tributes and result
    data/duelists.json     the 40 duelists: name, AI row, deck and drop pools (card name -> weight out of 2048)
    data/terrain.json      terrain bonus to ATK by monster type
    data/duel_rank.json    the duel rank rule table: ten rows of (threshold, change) pairs per rule
    data/attack_traps.json the attack threshold of each trap
    data/starter_pools.json the starter deck build's seven pools: draw count and card weights
    data/ai_scripts/       the duel AI's two scripts, hand.bin and field.bin (binary, read by the game's AI VM)
    images/                card art, thumbnails, frames and UI sprites as PNG
    screens/               the boot screens, baked from the game's sprite data
    screens/duel_field/    the duel board for each terrain (3D model and textures) and layout.json: the field grid and camera
    audio/se/              menu sound effects as 16-bit mono WAV, plus index.json {id: {file, rate}}
    audio/bgm/             background music: one folder per track (key = package << 4 | sequence, hex) with seq.bin, tones.json and samples/*.wav; index.json lists the tracks (format: docs/bgm-format.md)
    movies/                the opening movie: frames/fNNNN.png (320 x 240, 15 a second, decoded from the disc's STR),
                           opening.wav (XA audio, 16-bit stereo) and opening.json (frame count)
Existing files are kept unless you pass --overwrite (or --overwrite-only PATTERN, relative to assets/).
The other files in tools/ are the library this command uses; you never need to run them.
Standard library only; Python 3.11+.
"""
import argparse, fnmatch, io, json, math, os, re, struct, sys, wave, zlib
from array import array
from pathlib import Path


# ---- common ------------------------------------------------------
SECTOR = 2048
ROOT = Path(__file__).resolve().parents[1]
_policy = {"all": False, "patterns": [], "verbose": False}
_written, kept = set(), []


def glob_regex(pattern):
    pattern, parts, i = pattern.replace("\\", "/").strip("/"), [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i): parts.append("(?:.*/)?"); i += 3
        elif pattern.startswith("**", i): parts.append(".*"); i += 2
        elif pattern[i] == "*": parts.append("[^/]*"); i += 1
        elif pattern[i] == "?": parts.append("[^/]"); i += 1
        else: parts.append(re.escape(pattern[i])); i += 1
    return re.compile("".join(parts))


def configure(overwrite=False, patterns=(), verbose=False):
    _policy.update(all=bool(overwrite), patterns=[glob_regex(p) for p in patterns], verbose=verbose)
    _written.clear(); kept.clear()


def add_flags(parser):
    parser.add_argument("--overwrite", action="store_true", help="replace every existing output")
    parser.add_argument("--overwrite-only", action="append", default=[], metavar="PATTERN", help="replace existing outputs matching this glob (relative to the output root; repeatable)")
    parser.add_argument("--verbose", action="store_true")


def apply_flags(args):
    configure(args.overwrite, args.overwrite_only, args.verbose)


def may_write(path, root=None):
    path = Path(path)
    if not path.exists() or str(path.resolve()) in _written: return True
    if _policy["all"]: return True
    try: rel = path.resolve().relative_to(Path(root or ROOT).resolve()).as_posix()
    except ValueError: rel = path.name
    parts = rel.split("/")
    return any(p.fullmatch("/".join(parts[:n])) for p in _policy["patterns"] for n in range(1, len(parts) + 1))


def write_output(path, data, root=None, force=False):
    """Write bytes or text; returns False (and records it) when an existing file is kept. force replaces it regardless."""
    path = Path(path)
    if not force and not may_write(path, root):
        kept.append(str(path))
        if _policy["verbose"]: print("kept existing " + str(path))
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)
    _written.add(str(path.resolve()))
    return True


def kept_summary():
    return f"Kept {len(kept)} existing files; use --overwrite or --overwrite-only PATTERN to replace them." if kept else ""


# ---- disc --------------------------------------------------------
RAW_SECTOR, USER_OFFSET, USER_SIZE = 2352, 24, 2048


class Disc:
    def __init__(self, path):
        path = Path(path)
        if path.suffix.lower() == ".cue":
            m = re.search(r'FILE\s+"?([^"\r\n]+?)"?\s+BINARY', path.read_text(errors="replace"))
            if not m: raise ValueError("no FILE entry in cue")
            name = m.group(1).strip()
            found = next((p for p in path.parent.iterdir() if p.name.lower() == name.lower()), None)
            if found is None: raise FileNotFoundError(name)
            path = found
        self.path, self.size = path, path.stat().st_size
        self.sectors = self.size // RAW_SECTOR
        self._fh = open(path, "rb")

    def close(self): self._fh.close()
    def __enter__(self): return self
    def __exit__(self, *a): self.close()

    def sector(self, lba):
        """The 2048 user bytes of one MODE2 FORM1 sector (a FORM2 sector keeps its 2324 bytes zero padded)."""
        self._fh.seek(lba * RAW_SECTOR)
        raw = self._fh.read(RAW_SECTOR)
        if len(raw) < RAW_SECTOR: return b"\0" * USER_SIZE
        return raw[USER_OFFSET:USER_OFFSET + USER_SIZE]

    def raw_sector(self, lba):
        self._fh.seek(lba * RAW_SECTOR)
        return self._fh.read(RAW_SECTOR).ljust(RAW_SECTOR, b"\x00")

    def read(self, lba, length):
        out, count = bytearray(), -(-length // USER_SIZE)
        for i in range(count): out += self.sector(lba + i)
        return bytes(out[:length])

    def entries(self, lba=None, size=None, prefix=""):
        """Recursive ISO9660 listing: [(path, lba, size, is_dir)]."""
        if lba is None:
            pvd = self.sector(16)
            if pvd[1:6] != b"CD001": raise ValueError("no ISO9660 primary volume descriptor")
            lba, size = struct.unpack_from("<I", pvd, 156 + 2)[0], struct.unpack_from("<I", pvd, 156 + 10)[0]
        data, out, pos = self.read(lba, size), [], 0
        while pos < len(data):
            n = data[pos]
            if n == 0: pos = (pos // USER_SIZE + 1) * USER_SIZE; continue
            rec = data[pos:pos + n]; pos += n
            elba, esize = struct.unpack_from("<I", rec, 2)[0], struct.unpack_from("<I", rec, 10)[0]
            flags, idlen = rec[25], rec[32]
            name = rec[33:33 + idlen]
            if name in (b"\0", b"\1"): continue
            name = name.decode("ascii", "replace").split(";")[0]
            full = prefix + name
            if flags & 2:
                out.append((full + "/", elba, esize, True))
                out += self.entries(elba, esize, full + "/")
            else: out.append((full, elba, esize, False))
        return out

    def find(self, path):
        want = path.strip("/").upper()
        for name, lba, size, is_dir in self.entries():
            if not is_dir and name.upper() == want: return lba, size
        raise FileNotFoundError(path)

    def file(self, path):
        lba, size = self.find(path)
        return self.read(lba, size)


def extract(disc, out_dir, only=None, raw=()):
    """Writes the disc's files and a layout.json (name, lba, size, raw) the game can read instead of the BIN.
    Files matching `raw` keep their 2352 byte sectors (movies, XA audio); directory sectors are saved under system/."""
    entries = disc.entries()
    layout = {"sectors": disc.sectors, "files": []}
    done = 0
    pvd = disc.sector(16)
    blocks = [("system/pvd.bin", 16, 2048, False)] + [(f"system/dir_{lba}.bin", lba, size, False) for name, lba, size, is_dir in entries if is_dir]
    root_lba, root_size = struct.unpack_from("<I", pvd, 158)[0], struct.unpack_from("<I", pvd, 166)[0]
    blocks.append((f"system/dir_{root_lba}.bin", root_lba, root_size, False))
    for name, lba, size, is_dir in [(n, l, s, d) for n, l, s, d in entries if not d] + [(n, l, s, False) for n, l, s, _ in blocks]:
        is_raw = any(glob_regex(p).fullmatch(name) for p in raw)
        wanted = name.startswith("system/") or not only or any(glob_regex(p).fullmatch(name) for p in only)
        if not wanted: continue
        count = -(-size // 2048)
        if is_raw:
            data = b"".join(disc.raw_sector(lba + i) for i in range(count))
            layout["files"].append({"name": name + ".raw", "lba": lba, "size": count * RAW_SECTOR, "sectors": count, "raw": True})
            done += write_output(Path(out_dir) / (name + ".raw"), data, out_dir)
        else:
            layout["files"].append({"name": name, "lba": lba, "size": size, "sectors": count, "raw": False})
            done += write_output(Path(out_dir) / name, disc.read(lba, size), out_dir)
    write_output(Path(out_dir) / "layout.json", json.dumps(layout, indent=1) + "\n", out_dir)
    return done


# ---- images ------------------------------------------------------
CONFIG = ROOT / "config" / "images.json"


def png(width, height, rgba: bytes) -> bytes:
    rows = b"".join(b"\x00" + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b"")


def palette(data: bytes, offset: int, entries: int):
    colors = []
    for i in range(entries):
        value = struct.unpack_from("<H", data, offset + i * 2)[0]
        r, g, b = (value & 31) << 3, ((value >> 5) & 31) << 3, ((value >> 10) & 31) << 3   # 5 to 8 bits: v << 3, as rgba()
        # colour 0x0000 is transparent; 0x8000 on its own is black
        a = 0 if value == 0 else 255
        colors.append((r, g, b, a))
    return colors


def ink_palette(data: bytes, offset: int, entries: int):
    """A palette of ink entries (a card's name plate, the card view's ramp): a semi-transparent entry (bit 15 set) is alpha 128, the
    ink the card view subtracts from the frame; an opaque one is alpha 255, and entry 0 (0x0000) is clear."""
    colors = []
    for i in range(entries):
        value = struct.unpack_from("<H", data, offset + i * 2)[0]
        r, g, b = (value & 31) << 3, ((value >> 5) & 31) << 3, ((value >> 10) & 31) << 3
        colors.append((r, g, b, 0 if value == 0 else (128 if value & 0x8000 else 255)))
    return colors


def render(entry, data: bytes):
    words, rows, bpp = entry["words"], entry["rows"], entry["bpp"]
    pixels_per_row = words * (4 if bpp == 4 else 2)
    colors = None
    if "clut_offset" in entry:
        colors = ink_palette(data, entry["clut_offset"], entry["clut_entries"]) if entry.get("ink") else palette(data, entry["clut_offset"], entry["clut_entries"])
    left = entry.get("crop_left", 0)
    width = entry.get("width", pixels_per_row - left)
    out = bytearray()
    base = entry["offset"]
    for y in range(rows):
        row = base + y * words * 2
        for x in range(left, left + width):
            if bpp == 8:
                index = data[row + x]
            else:
                byte = data[row + (x >> 1)]
                index = (byte >> 4) if (x & 1) else (byte & 15)
            out += bytes(colors[index]) if colors and index < len(colors) else bytes((index, index, index, 255))
    return width, rows, bytes(out)


def export_images(archives: dict, output: Path, only=(), mods=()) -> int:
    """archives: archive name -> bytes. Writes one PNG per catalog entry (under the output policy); returns how many were written.
    An entry that a mod's texture pack reads the same way is written from the mod's PNG under the same name, and its scale goes
    in mod_scales.json beside images/. An entry a mod no longer replaces is baked from the disc again, so the vanilla art returns."""
    entries = json.loads(CONFIG.read_text())
    replacements = texture_index(mods) if mods else {}
    sidecar = output.parent / SCALES_FILE
    scales = read_scales(sidecar)
    written = replaced = 0
    for entry in entries:
        if only and not any(fnmatch.fnmatch(entry["name"], pattern) for pattern in only):
            continue
        target = output / (entry["name"] + ".png")
        rel = target.relative_to(output.parent).as_posix()
        hit = replacements.get(tuple(entry.get(k) for k in READING))
        if hit is not None:
            try:
                data = hit[1].read_bytes()
                width, height = png_size(data)
                scale = width / entry["width"]
                if abs(height - entry["rows"] * scale) > 1e-6:
                    raise ValueError(f"{width}x{height} is not a whole multiple of {entry['width']}x{entry['rows']}")
            except (OSError, ValueError, struct.error) as error:
                print(f"  mod image {hit[1]} cannot be used for {entry['name']}: {error}")
            else:
                written += bool(write_output(target, data, output, force=True))
                scales[rel] = round(scale, 6)
                replaced += 1
                continue
        if entry["archive"] not in archives:
            continue
        width, height, rgba = render(entry, archives[entry["archive"]])
        if rel in scales:
            # a replacement from an earlier run that no mod makes now: the disc's picture comes back
            scales.pop(rel)
            written += bool(write_output(target, png(width, height, rgba), output, force=True))
        else:
            written += bool(write_output(target, png(width, height, rgba), output))
    if scales or sidecar.exists():
        write_output(sidecar, json.dumps(dict(sorted(scales.items())), indent=1) + "\n", output.parent, force=True)
    if any(mod["manifest"].get("textures") for mod in mods):
        print(f"  mods: {replaced} images replaced by {', '.join(mod['id'] for mod in mods if mod['manifest'].get('textures'))}")
    return written


# ---- mods --------------------------------------------------------
# A mod is a folder with a mod.json. This reads its texture pack ("textures"):
# each PNG replaces the baked image it reads the same way (archive, offset, size, depth, palette). Settings default to the mod's
# own defaults; --mod-off KEY turns one off. The rule tables of a mod are read by the game itself from mods/ (scripts/duel/duel_data.gd).
MODS_DIR = ROOT / "mods"
SCALES_FILE = "mod_scales.json"
READING = ("archive", "offset", "words", "rows", "bpp", "clut_offset", "clut_entries", "stride", "crop_left", "width")


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def load_mod(path):
    """The mod in a folder (or the mod.json itself): its id, folder, manifest, settings as {key: bool} and enabled flag."""
    folder = Path(path)
    if folder.name.lower() == "mod.json": folder = folder.parent
    if not (folder / "mod.json").exists(): sys.exit(f"No mod.json in {folder}")
    manifest = read_json(folder / "mod.json")
    settings = {s["key"]: bool(s.get("default", 1)) for s in manifest.get("settings", []) if isinstance(s, dict) and "key" in s}
    return {"id": manifest.get("id", folder.name), "dir": folder, "manifest": manifest, "settings": settings,
            "enabled": manifest.get("enabled", True) is not False}


def select_mods(paths=(), off=(), disabled=False):
    """The mods this run uses: the --mod folders, else every enabled folder under mods/, in folder-name order (a later one wins)."""
    if disabled: return []
    found = []
    for path in paths or sorted(MODS_DIR.glob("*/mod.json")):
        try:
            mod = load_mod(path)
        except (OSError, ValueError) as error:
            if paths: sys.exit(f"Cannot read the mod {path}: {error}")
            print(f"  mod {Path(path).parent.name} skipped: {error}")
            continue
        if paths or mod["enabled"]: found.append(mod)
    for mod in found:
        for key in off:
            if key in mod["settings"]: mod["settings"][key] = False
    return sorted(found, key=lambda mod: mod["dir"].name.lower())


def png_size(data: bytes):
    if data[:8] != b"\x89PNG\r\n\x1a\n": raise ValueError("not a PNG")
    return struct.unpack(">II", data[16:24])


def texture_index(mods):
    """(archive, offset, size, depth, palette) reading -> (mod id, PNG path, manifest entry); the last mod that names it wins."""
    index = {}
    for mod in mods:
        pack = mod["manifest"].get("textures")
        if not pack: continue
        folder = mod["dir"] / pack
        if not (folder / "manifest.json").exists():
            print(f"  mod {mod['id']}: no {pack}/manifest.json")
            continue
        for entry in read_json(folder / "manifest.json"):
            if not mod["settings"].get(entry.get("setting"), True): continue
            file = Path(str(entry.get("file", "")))
            if not file.parts or file.is_absolute() or ".." in file.parts: continue
            index[tuple(entry.get(k) for k in READING)] = (mod["id"], folder / file, entry)
    return index


def read_scales(path):
    """assets/mod_scales.json: {"images/<name>.png": scale} for each image a mod replaced in the last run."""
    if not Path(path).exists(): return {}
    try: data = read_json(path)
    except ValueError: return {}
    return {str(k): float(v) for k, v in data.items()} if isinstance(data, dict) else {}


# ---- HD art (the auto-hd mod) ------------------------------------
# --hd N writes mods/auto-hd/: a mirror of assets/ (the pictures under images/ and screens/) with each picture upscaled N times by
# Scale2x (EPX), twice for 4. Scale2x only copies the colours of the picture's own pixels (no blending), so the palette's colours and
# the alpha values the bust layers read (0, 32, 64, 128, 255) stay exact, and a transparent pixel stays transparent. Pictures larger
# than HD_MAX_SOURCE on a side are already large and are left out; so are the 3D textures, the glyph atlases, the movie and the data.
# The game reads the mod (scripts/system/mod_art.gd): mods/auto-hd/mod.json "enabled", and scales.json (the scale and the baked size
# of each picture, keyed by the path under assets/). A run is resumable: a picture whose mirror already has the right size is kept.
HD_MOD = MODS_DIR / "auto-hd"
HD_MAX_SOURCE = 640
# The duel's readout panels and digits (duel_hud/, card_ui/) are left at the baked size: Scale2x rounds the corners and the diagonal
# edges of their small letters and numbers, so on a large screen they look blobby, not chunky (the Sharp and Pixel samplings show the
# baked pixels). Their drawn size and layout are unchanged either way.
HD_SKIP = ("movies/*", "audio/*", "data/*", "*.json", "*.bin", "screens/duel_field/*", "screens/font/*", "screens/text*",
           "screens/map/*/texture_*", "screens/map/texture_*", "screens/duel_hud/*", "screens/card_ui/*")


def png_read(path):
    """(width, height, packed pixels) of a non-interlaced 8-bit PNG (colour types 2 and 6). A transparent pixel is 0."""
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n": raise ValueError("not a PNG")
    width, height, depth, kind, _, _, interlace = struct.unpack(">IIBBBBB", data[16:29])
    if depth != 8 or kind not in (2, 6) or interlace: raise ValueError(f"unsupported PNG (depth {depth}, colour type {kind})")
    pos, idat = 8, []
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        if tag == b"IDAT": idat.append(data[pos + 8:pos + 8 + length])
        pos += 12 + length
    raw = zlib.decompress(b"".join(idat))
    bpp = 4 if kind == 6 else 3
    stride = width * bpp
    rows = []
    prev = bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:
            for i in range(bpp, stride): line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride): line[i] = (line[i] + ((line[i - bpp] if i >= bpp else 0) + prev[i]) // 2) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        elif f != 0: raise ValueError(f"bad PNG filter {f}")
        rows.append(line)
        prev = line
    if kind == 2:
        rgba = bytearray(width * height * 4)
        for y, line in enumerate(rows):
            rgba[y * width * 4:(y + 1) * width * 4] = bytes(v for i in range(width) for v in (line[3 * i], line[3 * i + 1], line[3 * i + 2], 255))
    else:
        rgba = bytearray(b"".join(rows))
    words = array("I", bytes(rgba))
    for i, word in enumerate(words):
        if word >> 24 == 0: words[i] = 0      # a transparent pixel is one value: its colour does not matter, and Scale2x compares whole pixels
    return width, height, words


def scale2x(width, height, px):
    """Scale2x (EPX) on packed pixels (array 'I', r | g << 8 | b << 16 | a << 24): returns (2w, 2h, pixels). The edges repeat the
    picture's own border pixels. Each output pixel is one of its neighbours' colours, never a blend."""
    ow = width * 2
    out = array("I", bytes(4 * ow * height * 2))
    for y in range(height):
        up = px[max(y - 1, 0) * width:(max(y - 1, 0) + 1) * width]
        cur = px[y * width:(y + 1) * width]
        dn = px[min(y + 1, height - 1) * width:(min(y + 1, height - 1) + 1) * width]
        top = array("I", bytes(4 * ow))
        bot = array("I", bytes(4 * ow))
        for x in range(width):
            e = cur[x]
            b = up[x]
            h = dn[x]
            d = cur[x - 1] if x > 0 else e
            f = cur[x + 1] if x < width - 1 else e
            top[2 * x] = d if (d == b and b != f and d != h) else e
            top[2 * x + 1] = f if (b == f and b != d and f != h) else e
            bot[2 * x] = d if (d == h and d != b and h != f) else e
            bot[2 * x + 1] = f if (h == f and d != h and b != f) else e
        out[(2 * y) * ow:(2 * y + 1) * ow] = top
        out[(2 * y + 1) * ow:(2 * y + 2) * ow] = bot
    return ow, height * 2, out


def hd_upscale(path, target, factor):
    """Writes the upscaled picture of `path` to `target` (an RGBA PNG). Returns the baked picture's (width, height)."""
    width, height, px = png_read(path)
    w, h = width, height
    for _ in range(factor // 2):
        w, h, px = scale2x(w, h, px)
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_bytes(png(w, h, px.tobytes()))
    os.replace(tmp, target)
    return width, height


def _hd_job(job):
    source, target, factor, (width, height) = job
    try:
        if Path(target).exists():
            with Path(target).open("rb") as fh:
                if png_size(fh.read(24)) == (width * factor, height * factor):
                    return str(source), "kept"
        hd_upscale(source, target, factor)
        return str(source), "done"
    except (OSError, ValueError, struct.error, zlib.error) as error:
        return str(source), f"failed: {error}"


def hd_pictures(assets: Path):
    """The baked pictures the HD pass upscales: (path, path relative to assets/, width, height)."""
    found = []
    for path in sorted(assets.rglob("*.png")):
        rel = path.relative_to(assets).as_posix()
        if not (rel.startswith("images/") or rel.startswith("screens/")): continue
        if any(fnmatch.fnmatch(rel, pattern) for pattern in HD_SKIP): continue
        with path.open("rb") as fh:
            width, height = png_size(fh.read(24))
        if max(width, height) > HD_MAX_SOURCE: continue
        found.append((path, rel, width, height))
    return found


def hd_pass(assets: Path, factor: int, jobs=0, mod_dir=None):
    """Writes the HD mirror of the baked pictures and the mod's mod.json and scales.json. Returns the number upscaled."""
    from concurrent.futures import ProcessPoolExecutor
    if factor not in (2, 4): sys.exit("--hd takes 2 or 4")
    mod_dir = Path(mod_dir or HD_MOD)
    pictures = hd_pictures(assets)
    if not pictures: sys.exit(f"No baked pictures under {assets}; run the extraction first")
    mod_dir.mkdir(parents=True, exist_ok=True)
    write_output(mod_dir.parent / ".gdignore", b"", mod_dir.parent, force=True)
    manifest = {"id": "auto-hd", "name": "HD art (generated by tools/extract.py --hd)", "version": 1, "enabled": True,
                "tree": "assets", "scales": "scales.json",
                "settings": [{"key": "hd_art", "label": "HD art", "default": 1}],
                "note": "Scale2x of the baked pictures, written by tools/extract.py --hd N. --mod-off auto-hd turns it off."}
    mirror = mod_dir / "assets"
    work = [(path, mirror / rel, factor, (width, height)) for path, rel, width, height in pictures]
    workers = jobs or max(1, (os.cpu_count() or 2) - 1)
    done = kept_count = failed = 0
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for n, (source, status) in enumerate(pool.map(_hd_job, work, chunksize=8), 1):
            if status == "done": done += 1
            elif status == "kept": kept_count += 1
            else:
                failed += 1
                print(f"  hd: {source}: {status}")
            if n % 500 == 0: print(f"  hd: {n}/{len(work)}")
    scales = {rel: {"scale": factor, "width": width, "height": height} for _, rel, width, height in pictures}
    (mod_dir / "scales.json").write_text(json.dumps(scales, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    (mod_dir / "mod.json").write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
    print(f"  hd: {factor}x, {len(pictures)} pictures: {done} upscaled, {kept_count} kept, {failed} failed -> {mod_dir}")
    return done


def hd_disable(mod_dir=None):
    """--mod-off auto-hd: the mirror stays on disk and the game stops reading it (enabled false in mod.json)."""
    mod_dir = Path(mod_dir or HD_MOD)
    if not (mod_dir / "mod.json").exists():
        print("  hd: no auto-hd mod to turn off")
        return
    manifest = read_json(mod_dir / "mod.json")
    manifest["enabled"] = False
    (mod_dir / "mod.json").write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
    print("  hd: auto-hd turned off (enabled false)")


# ---- cards -------------------------------------------------------
LOAD, HEADER = 0x80010000, 0x800
CARD_COUNT = 722
STATS, LEVELS, TEXT_INDEX, TEXT_BASE = 0x801D4244, 0x801D5332, 0x801D5800, 0x801D0000
NAME_SORT_KEYS = 0x801D4D8E             # the card name sort key: 722 s16, the alphabetical rank of each card's name (Build Deck and the Library sort by it)
# glyph code -> character of the executable's text bank
CHARSET = {0: " ", 1: "e", 2: "t", 3: "a", 4: "o", 5: "i", 6: "n", 7: "s", 8: "r", 9: "h", 10: "l", 11: ".", 12: "d", 13: "u", 14: "m",
           15: "c", 16: "g", 17: "y", 18: "w", 19: "f", 20: "p", 21: "b", 22: "k", 24: "A", 25: "v", 26: "I", 27: "'", 28: "T", 29: "S",
           30: "M", 31: ",", 32: "D", 33: "O", 34: "W", 35: "H", 36: "Y", 37: "E", 38: "R", 41: "G", 42: "L", 43: "C", 44: "N", 45: "B",
           47: "P", 48: "-", 49: "F", 50: "z", 51: "K", 52: "j", 53: "U", 54: "x", 55: "q", 56: "0", 57: "V", 58: "2", 59: "J", 60: "#",
           61: "1", 62: "Q", 63: "Z", 65: "3", 67: "&", 69: "7", 85: "α"}
TYPES = {0: "Dragon", 1: "Spellcaster", 2: "Zombie", 3: "Warrior", 4: "Beast-Warrior", 5: "Beast", 6: "Winged Beast", 7: "Fiend",
         8: "Fairy", 9: "Insect", 10: "Dinosaur", 11: "Reptile", 12: "Fish", 13: "Sea Serpent", 14: "Machine", 15: "Thunder",
         16: "Aqua", 17: "Pyro", 18: "Rock", 19: "Plant", 20: "Magic", 21: "Trap", 22: "Ritual", 23: "Equip"}
ATTRIBUTES = {0: "Light", 1: "Dark", 2: "Earth", 3: "Water", 4: "Fire", 5: "Wind"}
STARS = {0: "", 1: "Mars", 2: "Jupiter", 3: "Saturn", 4: "Uranus", 5: "Pluto", 6: "Neptune", 7: "Mercury", 8: "Sun", 9: "Moon", 10: "Venus"}


def text_at(exe: bytes, string_id: int) -> str:
    """A string of the executable's text bank by its id (card ids are the first 722)."""
    at = lambda a: a - LOAD + HEADER
    start = at(TEXT_BASE + struct.unpack_from("<H", exe, at(TEXT_INDEX) + 2 * string_id)[0])
    return "".join(CHARSET.get(g, "?") for g in exe[start:exe.index(b"\xff", start)])


def build(exe: bytes):
    at = lambda a: a - LOAD + HEADER
    cards = []
    for card_id in range(1, CARD_COUNT + 1):
        word = struct.unpack_from("<I", exe, at(STATS) + (card_id - 1) * 4)[0]
        level_attribute = exe[at(LEVELS) + card_id]
        cards.append({"id": card_id, "name": text_at(exe, card_id),
                      "type": TYPES.get((word >> 26) & 31, "?"),
                      "attribute": ATTRIBUTES.get(level_attribute >> 4, ""), "level": level_attribute & 15,
                      "guardian_star_1": STARS.get((word >> 22) & 15, "?"), "guardian_star_2": STARS.get((word >> 18) & 15, "?"),
                      "attack": (word & 0x1FF) * 10, "defense": ((word >> 9) & 0x1FF) * 10,
                      "name_sort_key": struct.unpack_from("<h", exe, at(NAME_SORT_KEYS) + 2 * (card_id - 1))[0]})
    return cards


PASSWORDS = 0xFB9800                   # WA_MRG.MRG: 723 records of u32 starchip cost, then 4 bytes of packed BCD password (entry = card id)


def export_cards(exe: bytes, wa: bytes, output: Path) -> int:
    cards = build(exe)
    for card in cards:
        at = PASSWORDS + card["id"] * 8
        digits = wa[at + 4:at + 8][::-1].hex()
        card["starchips"] = struct.unpack_from("<I", wa, at)[0]
        card["password"] = digits if digits.isdigit() else ""
    return int(bool(write_output(output, json.dumps(cards, indent=1, ensure_ascii=False), output.parent))) * len(cards)


# ---- tables ------------------------------------------------------
DUEL_BLOB = 0x16C6 * SECTOR            # WA_MRG.MRG: the duel blob, 235 sectors; terrain 0's copy (the tables are the same in all seven)
EQUIP_TABLE, FUSION_TABLE, RITUAL_TABLE = DUEL_BLOB + 0x22000, DUEL_BLOB + 0x24800, DUEL_BLOB + 0x34800
DUELIST_BLOCKS, DUELISTS = 0x1D33 * SECTOR, 40   # 3 sectors each: deck weights, then the POW, BCD and TEC drop pools
DUEL_RANK_TABLE = 0x16D0                          # in each duelist's block: the duel rank table, ten rows of five s16 (threshold, change) pairs
POOLS = (("deck", 0x000), ("pow", 0x5B4), ("bcd", 0xB68), ("tec", 0x111C))   # 722 u16 weights each, out of 2048
AI_ROWS, TERRAIN_ROWS, TRAP_THRESHOLDS = 0x800917F0, 0x800909D4, 0x8009AF24   # executable: 40 x 9 signed bytes; 20 x 6 signed, in tens of ATK; 6 bytes, in hundreds of ATK
TERRAINS = ("Forest", "Wasteland", "Mountain", "Meadow", "Sea", "Dark")          # terrain ids 1 to 6
TRAPS = ("House of Adhesive Tape", "Eatgaboon", "Bear Trap", "Invisible Wire", "Acid Trap Hole", "Widespread Ruin")
MEGAMORPH, MEGAMORPH_BONUS, EQUIP_BONUS = 657, 1000, 500   # the equip bonus in points; Megamorph's is double
CARD_STAT_SCALE = 10                   # the terrain table is in tens of points


def fusion_recipes(blob: bytes):
    """the fusion check's table: per smaller card id a u16 offset (0: none) to a count and five-byte groups, each with two (partner, result) pairs."""
    recipes = []
    for a in range(CARD_COUNT + 1):
        off = struct.unpack_from("<H", blob, a * 2)[0]
        if off == 0:
            continue
        p, n = off, blob[off]
        if n == 0:                       # counts of 256 to 511 take a second byte
            n, p = 0x1FF - blob[off + 1], off + 1
        p += 1
        while n > 0:
            g = blob[p]
            recipes.append((a, ((g << 8) & 0x300) | blob[p + 1], ((g << 6) & 0x300) | blob[p + 2]))
            if n > 1:                    # an odd count leaves the second pair unused
                recipes.append((a, ((g << 4) & 0x300) | blob[p + 3], ((g << 2) & 0x300) | blob[p + 4]))
            p += 5
            n -= 2
    return recipes


def equip_pairs(blob: bytes):
    """the equip check's table: u16 equip id (0 ends it), u16 count, then that many u16 monster ids."""
    pairs, p = [], 0
    while True:
        key = struct.unpack_from("<H", blob, p)[0]
        if key == 0:
            return pairs
        n = struct.unpack_from("<H", blob, p + 2)[0]
        pairs += [(key, struct.unpack_from("<H", blob, p + 4 + 2 * i)[0]) for i in range(n)]
        p += 4 + 2 * n


def ritual_recipes(blob: bytes):
    """the ritual check's table: records of ritual id, three tributes, result (u16 each), ended by a zero id."""
    recipes = []
    for p in range(0, SECTOR, 10):
        record = struct.unpack_from("<5H", blob, p)
        if record[0] == 0:
            break
        recipes.append(record)
    return recipes


STARTER_POOL_TABLE, STARTER_POOLS, STARTER_POOL_SIZE, STARTER_SCAN = 0xF92BD4, 7, 0x5B8, 720   # WA_MRG.MRG


def export_tables(exe: bytes, wa: bytes, output: Path) -> int:
    """The duel's rule tables as JSON, written to output (assets/data): fusions, equips, rituals, duelists, terrain, attack traps."""
    names = {card["id"]: card["name"] for card in build(exe)}
    fusions = [{"a": names[a], "b": names[b], "result": names[r], "ids": [a, b, r]} for a, b, r in fusion_recipes(wa[FUSION_TABLE:FUSION_TABLE + 0x10000])]
    grouped = {}
    for equip, monster in equip_pairs(wa[EQUIP_TABLE:EQUIP_TABLE + 0x2800]):
        grouped.setdefault(equip, []).append(monster)
    equips = [{"card": names[e], "id": e, "bonus": MEGAMORPH_BONUS if e == MEGAMORPH else EQUIP_BONUS,
               "monsters": [names[m] for m in ms], "monster_ids": ms} for e, ms in grouped.items()]
    rituals = [{"card": names[r[0]], "id": r[0], "tributes": [names[t] for t in r[1:4]], "tribute_ids": list(r[1:4]),
                "result": names[r[4]], "result_id": r[4]} for r in ritual_recipes(wa[RITUAL_TABLE:RITUAL_TABLE + SECTOR])]
    at = lambda a: a - LOAD + HEADER
    ai_rows = [list(struct.unpack_from("<9b", exe, at(AI_ROWS) + 9 * i)) for i in range(DUELISTS)]
    duelists = []
    for i in range(DUELISTS):
        block = DUELIST_BLOCKS + i * 3 * SECTOR
        pools = {key: {names[c]: w for c, w in enumerate(struct.unpack_from("<722H", wa, block + offset), 1) if w}
                 for key, offset in POOLS}
        # block 0 is an unused copy of block 1; the names are the duelist strings at 0x8329 onward
        duelists.append({"id": i, "name": text_at(exe, 0x328 + max(i, 1)), "unused": i == 0, "ai": ai_rows[i],
                         "deck": pools["deck"], "drops": {key: pools[key] for key in ("pow", "bcd", "tec")}})
    terrain = {"terrains": list(TERRAINS), "bonus": {}}
    values = struct.unpack_from("<120b", exe, at(TERRAIN_ROWS))
    for t in range(20):
        row = {TERRAINS[c]: v * CARD_STAT_SCALE for c, v in enumerate(values[t * 6:t * 6 + 6]) if v}
        if row:
            terrain["bonus"][TYPES[t]] = row
    traps = dict(zip(TRAPS, (v * 100 for v in struct.unpack_from("<6B", exe, at(TRAP_THRESHOLDS)))))
    # the starter deck pools (the starter deck build): seven records of a draw count and 722 weights; only the first 720
    # cards are drawn from, each weight row sums to 2048
    starter = []
    for i in range(STARTER_POOLS):
        base = STARTER_POOL_TABLE + i * STARTER_POOL_SIZE
        count = struct.unpack_from("<H", wa, base)[0]
        weights = struct.unpack_from("<%dH" % STARTER_SCAN, wa, base + 2)
        starter.append({"count": count, "weights": {str(c): w for c, w in enumerate(weights, 1) if w}})
    # the duel rank rule table (the duel rank table): the same forty copies in every duelist's block, so the rows must agree; each row is
    # five [threshold, change] pairs, and the first threshold above a counter gives its change
    ranks = {struct.unpack_from("<100h", wa, DUELIST_BLOCKS + i * 3 * SECTOR + DUEL_RANK_TABLE) for i in range(DUELISTS)}
    assert len(ranks) == 1, "the duel rank table differs between duelists"
    flat = next(iter(ranks))
    rank = [[[flat[(r * 5 + k) * 2], flat[(r * 5 + k) * 2 + 1]] for k in range(5)] for r in range(10)]
    files = {"fusions.json": json.dumps(fusions, ensure_ascii=False, separators=(",", ":")),
             "equips.json": equips, "rituals.json": rituals, "duelists.json": duelists,
             "terrain.json": terrain, "attack_traps.json": traps, "starter_pools.json": starter,
             "duel_rank.json": rank}
    written = 0
    for name, data in files.items():
        text = data if isinstance(data, str) else json.dumps(data, indent=1, ensure_ascii=False)
        written += bool(write_output(output / name, text + "\n", output))
    return written


# The duel's AI bytecode: one hand program and one field program shared by every duelist (each branches on the duelist id, which
# opcode 0x15 loads, and reads its 9-byte row of duelists.json "ai"). The duel package loader copies them from the terrain record
# at DUEL_BLOB + terrain * DUEL_TERRAIN_STRIDE: the hand chunk at relative sector 184 and the field chunk at 187, three sectors each.
# Execution starts at offset 0 of each chunk, which is 0x801A8000 (hand) and 0x801A9800 (field).
DUEL_TERRAIN_STRIDE = 0xEB * SECTOR
AI_SCRIPT_CHUNKS = (("hand.bin", 184), ("field.bin", 187))
AI_SCRIPT_BYTES = 3 * SECTOR


def export_ai_scripts(wa: bytes, output: Path) -> int:
    """The duel AI's hand and field bytecode (assets/data/ai_scripts): 0x1800 bytes each, taken from terrain 0. Terrains 1 to 6 carry the same chunks."""
    written = 0
    for name, sector in AI_SCRIPT_CHUNKS:
        at = DUEL_BLOB + sector * SECTOR
        chunk = wa[at:at + AI_SCRIPT_BYTES]
        if len(chunk) != AI_SCRIPT_BYTES:
            raise ValueError("WA_MRG.MRG is too short for the duel AI script " + name)
        for terrain in range(1, 7):
            other = at + terrain * DUEL_TERRAIN_STRIDE
            if wa[other:other + AI_SCRIPT_BYTES] != chunk:
                print("  warning: AI script " + name + " differs on terrain " + str(terrain))
        written += bool(write_output(output / name, chunk, output))
    return written


# ---- screens -----------------------------------------------------
PACKAGE = 0x1F85 * SECTOR
SCREEN_W, SCREEN_H = 320, 240
ORIGIN = (0, 0)       # screen-space objects: part offsets are absolute screen pixels
OBJECT_PAGE, OBJECT_CLUT = 0x10, (0x100, 0xF0)   # the page and CLUT the boot object is configured with


class Vram:
    def __init__(self):
        self.words = [0] * (1024 * 512)

    def upload_tiles(self, data: bytes, x: int, y: int, w: int = 64, h: int = 16, per_column: int = 16):
        tiles = len(data) // SECTOR
        for t in range(tiles):
            column, row = divmod(t, per_column)
            for j in range(h):
                for i in range(w):
                    self.words[(y + row * h + j) * 1024 + x + column * w + i] = struct.unpack_from("<H", data, t * SECTOR + (j * w + i) * 2)[0]

    def upload_rect(self, data: bytes, x: int, y: int, w: int, h: int):
        for j in range(h):
            for i in range(w):
                self.words[(y + j) * 1024 + x + i] = struct.unpack_from("<H", data, (j * w + i) * 2)[0]

    def texel4(self, page_x, page_y, u, v):
        word = self.words[(page_y + v) * 1024 + page_x + (u >> 2)]
        return (word >> ((u & 3) * 4)) & 15

    def colour(self, cx, cy, index):
        value = self.words[cy * 1024 + cx + index]
        return value


def rgba(value: int) -> bytes:
    """A 15-bit CLUT colour as 8 bits a channel: each 5-bit channel is shifted up by 3 (v << 3), which is what the game's own
    frames hold (checked against the reference VRAM and frames: 17 is 136, 31 is 248)."""
    if value == 0:
        return bytes((0, 0, 0, 0))
    r, g, b = value & 31, (value >> 5) & 31, (value >> 10) & 31
    return bytes((r << 3, g << 3, b << 3, 255))


def semi_rgba(value: int) -> bytes:
    """A texel of a semi-transparent object drawn in the average mode (abr 0): the colour at half alpha, so the picture blends with what is
    behind it when it is drawn over that (Godot's alpha blend is (front + back) / 2 at alpha 128). Colour 0 stays fully transparent."""
    if value == 0:
        return bytes((0, 0, 0, 0))
    r, g, b = (value & 31) << 3, ((value >> 5) & 31) << 3, ((value >> 10) & 31) << 3
    return bytes((r, g, b, 128))


def average(back: bytes, value: int) -> bytes:
    """A semi-transparent texel (the CLUT word's bit 15 set) drawn with the average mode: (back + front) / 2 per 5-bit channel on
    the layer already drawn. An empty backing counts as black."""
    if back[3] == 0:
        back = bytes((0, 0, 0, 255))
    out = []
    for channel, shift in enumerate((0, 5, 10)):
        back5 = back[channel] >> 3
        front5 = (value >> shift) & 31
        out.append(((back5 + front5) // 2) << 3)
    return bytes(out + [255])


def parts_of(bank: bytes, offset: int):
    count, flags, tpage, clut = bank[offset:offset + 4]
    parts = []
    for i in range(count):
        dx, dy, cell, size = struct.unpack_from("<BBHH", bank, offset + 4 + i * 6)
        if flags & 0x10:
            dx |= (cell & 0xC000) >> 6
            dy |= (size & 0xC000) >> 6
            if dx & 0x200:
                dx -= 0x400
            if dy & 0x200:
                dy -= 0x400
        else:
            dx = dx - 256 if dx & 0x80 else dx
            dy = dy - 256 if dy & 0x80 else dy
        u, v = (cell & 0x1F) * 8, ((cell >> 5) & 0x1F) * 8
        w, h = ((size >> 5) & 0xF) * 8 + 8, ((size >> 9) & 0xF) * 8 + 8
        parts.append((dx, dy, u, v, w, h, cell, size))
    return flags, tpage, clut, parts


def draw_object(vram: Vram, bank: bytes, offset: int, x: int, y: int, page: int, clut_x: int, clut_y: int, wide: bool, canvas, margin: int = 0, canvas_w: int = 0, canvas_h: int = 0, cell_offset: bool = True, texture=(0, 0), blend: bool = False, semi: bool = False):
    """the sprite sheet rendering for one frame: `page` and the CLUT are the object's, `wide` is 8 bits per pixel. The canvas
    is the screen (plus the margin) unless canvas_w and canvas_h give it another size. The header's CLUT offset applies only when
    the object carries the texture cell offset flag (0x20), which cell_offset says. `texture` is the object's own (u, v)
    base (field_5E), added to every cell's texel coordinates; 0, 0 for the usual objects."""
    du, dv = texture
    flags, tpage, clut, parts = parts_of(bank, offset)
    width = canvas_w or SCREEN_W + margin * 2
    height = canvas_h or SCREEN_H + margin * 2
    base_cx = clut_x + ((clut & 0xF) * 16 if cell_offset else 0)
    base_cy = clut_y + ((clut >> 4) if cell_offset else 0)
    base_page = page + tpage * (2 if wide else 1)
    for dx, dy, u, v, w, h, cell, size in reversed(parts):
        part_page, cx, cy = base_page, base_cx, base_cy
        if flags & 0xE0:
            if wide:
                part_page += (cell >> 9) & 0xE
                cy = base_cy + (size & 0x1F)
            else:
                part_page += (cell >> 10) & 7
                value = (base_cx & 0xFF) + ((size & 0xF) << 4)
                cx = (base_cx & 0x300) | (value & 0xFF)
                cy = base_cy + (value >> 8)
        page_x, page_y = (part_page & 0xF) * 64, ((part_page >> 4) & 1) * 256
        for j in range(h):
            for i in range(w):
                px, py = x + dx + i + margin, y + dy + j + margin
                if not (0 <= px < width and 0 <= py < height):
                    continue
                uu = u + du + (w - 1 - i if cell & 0x2000 else i)
                if wide:
                    word = vram.words[(page_y + ((v + dv + j) & 0xFF)) * 1024 + page_x + ((uu & 0xFF) >> 1)]
                    index = (word >> (8 * (uu & 1))) & 0xFF
                else:
                    index = vram.texel4(page_x, page_y, uu & 0xFF, (v + dv + j) & 0xFF)
                colour = vram.colour(cx, cy, index)
                if colour and blend and colour & 0x8000:
                    at = (py * width + px) * 4
                    canvas[at:at + 4] = average(bytes(canvas[at:at + 4]), colour)
                elif colour and semi:
                    # a whole semi-transparent object (its primitives' semi-transparency bit, average mode): every drawn texel is half
                    # its colour over what is behind it, as the PS1 draws the trade panel's cells over the sand (semi_rgba)
                    canvas[(py * width + px) * 4:(py * width + px) * 4 + 4] = semi_rgba(colour)
                elif colour:
                    canvas[(py * width + px) * 4:(py * width + px) * 4 + 4] = rgba(colour)


def draw_frame(vram: Vram, bank: bytes, offset: int) -> bytes:
    canvas = bytearray(SCREEN_W * SCREEN_H * 4)
    draw_object(vram, bank, offset, 0, 0, OBJECT_PAGE, OBJECT_CLUT[0], OBJECT_CLUT[1], False, canvas)
    return png(SCREEN_W, SCREEN_H, bytes(canvas))


def resolve_stream(bank: bytes, f67: int, f68: int, f69: int) -> int:
    """The bank is a tree of u16 offsets (resource, group, stream); a stream entry is (duration, u16 frame offset)."""
    u16 = lambda o: struct.unpack_from("<H", bank, o)[0]
    stream = u16(u16(u16(f67 * 2) + f68 * 2) + f69 * 2)
    return u16(stream + 1)


def bake(wa: bytes, output: Path) -> int:
    package = wa[PACKAGE:PACKAGE + 34 * SECTOR]
    vram = Vram()
    vram.upload_tiles(package[:32 * SECTOR], 0, 256)
    vram.upload_rect(package[32 * SECTOR:33 * SECTOR], 256, 240, 256, 4)
    bank = package[33 * SECTOR:34 * SECTOR]

    def stream_frame(f67, f68, f69):
        # the bank is a tree of u16 offsets: resource -> group -> stream; a stream entry is (duration, u16 frame offset)
        u16 = lambda o: struct.unpack_from("<H", bank, o)[0]
        level1 = u16(f67 * 2)
        level2 = u16(level1 + f68 * 2)
        stream = u16(level2 + f69 * 2)
        return struct.unpack_from("<H", bank, stream + 1)[0]
    written = 0
    for index, name in enumerate(("boot_0", "boot_1", "title")):
        written += bool(write_output(output / f"{name}.png", draw_frame(vram, bank, stream_frame(0, 0, index)), output))
    return written


MENU_BANK = 114 * SECTOR   # SU.MRG: image A 64 sectors, image B 32, palette 2, module 16, bank 1


def cropped(canvas: bytes, width: int, height: int, margin: int):
    """The opaque bounding box of a canvas drawn with a margin, as (png bytes, x, y) in screen coordinates; None when empty."""
    xs, ys = [], []
    for y in range(height):
        row = canvas[y * width * 4:(y + 1) * width * 4]
        for x in range(width):
            if row[x * 4 + 3]:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    x0, x1, y0, y1 = min(xs), max(xs) + 1, min(ys), max(ys) + 1
    out = bytearray()
    for y in range(y0, y1):
        out += canvas[(y * width + x0) * 4:(y * width + x1) * 4]
    return png(x1 - x0, y1 - y0, bytes(out)), x0 - margin, y0 - margin


def bake_menu(su: bytes, output: Path) -> int:
    """The main menu (frontend): the wall, the logo objects and the wheel's eleven entries in both states, as cut-out PNGs plus
    menu/layout.json giving each one's screen position (the front-end menu setup, the front-end background drawing)."""
    import json
    vram = Vram()
    vram.upload_tiles(su[:64 * SECTOR], 512, 256)
    vram.upload_tiles(su[64 * SECTOR:96 * SECTOR], 896, 0)
    vram.upload_rect(su[96 * SECTOR:98 * SECTOR], 0, 240, 256, 8)
    bank = su[MENU_BANK:MENU_BANK + SECTOR]
    margin = 64
    width, height = SCREEN_W + margin * 2, SCREEN_H + margin * 2
    layout, written = {}, 0

    def emit(name, f69, f67, f68, x, y, page, clut_row):
        nonlocal written
        canvas = bytearray(width * height * 4)
        draw_object(vram, bank, resolve_stream(bank, f67, f68, f69), x, y, page, 0, 240 + clut_row, True, canvas, margin)
        cut = cropped(bytes(canvas), width, height, margin)
        if cut is None:
            return
        data, ox, oy = cut
        written += bool(write_output(output / "menu" / f"{name}.png", data, output))
        layout[name] = {"x": ox, "y": oy}

    # the wall: 64-wide strips of the 256x240 picture on page 15 (960, 0), 16-colour palette at (0, 244)
    wall = bytearray(SCREEN_W * SCREEN_H * 4)
    for strip in range(0, SCREEN_W, 64):
        u0 = strip % 256
        for j in range(SCREEN_H):
            for i in range(64):
                index = vram.texel4(960, 0, u0 + i, j)
                colour = vram.colour(0, 244, index)
                if colour:
                    wall[(j * SCREEN_W + strip + i) * 4:(j * SCREEN_W + strip + i) * 4 + 4] = rgba(colour)
    written += bool(write_output(output / "menu" / "wall.png", png(SCREEN_W, SCREEN_H, bytes(wall)), output))
    layout["wall"] = {"x": 0, "y": 0}
    emit("logo_0", 0, 5, 0, 0, 0, 0x1A, 1)
    emit("logo_1", 1, 5, 0, 0, 8, 0x1A, 1)
    emit("logo_2", 2, 5, 0, 0, 8, 0x1A, 1)
    for i in range(11):
        y = i * 32 + 50 if i < 5 else (i - 5) * 32 + 42
        for state, selected in (("on", 0), ("off", 1)):
            emit(f"entry_{i}_{state}", i * 2 | selected, 0, 0, 0xA0, y, 0x18, 0)
    written += bool(write_output(output / "menu" / "layout.json", json.dumps(layout, indent=1), output))
    return written


NAME_ENTRY = 0xF6F800   # WA_MRG.MRG: 48 sectors at VRAM (256,256), 16 at (448,256), palette sector 256x4 at (256,240)


def bake_name_entry(wa: bytes, exe: bytes, output: Path) -> int:
    """The name entry screen's two pictures (the name entry setup): the 320x240 backdrop (8 bits per pixel from page (256,256), CLUT row
    (256,243)) and the 32x32 caret (4 bits, page (448,256) UV (144,128), CLUT (256,240))."""
    vram = Vram()
    vram.upload_tiles(wa[NAME_ENTRY:NAME_ENTRY + 48 * SECTOR], 256, 256)
    vram.upload_tiles(wa[NAME_ENTRY + 48 * SECTOR:NAME_ENTRY + 64 * SECTOR], 448, 256)
    vram.upload_rect(wa[NAME_ENTRY + 64 * SECTOR:NAME_ENTRY + 65 * SECTOR], 256, 240, 256, 4)
    back = bytearray(SCREEN_W * SCREEN_H * 4)
    for y in range(SCREEN_H):
        for x in range(SCREEN_W):
            word = vram.words[(256 + y) * 1024 + 256 + (x >> 1)]
            colour = vram.colour(256, 243, (word >> (8 * (x & 1))) & 0xFF)
            if colour:
                back[(y * SCREEN_W + x) * 4:(y * SCREEN_W + x) * 4 + 4] = rgba(colour)
    caret = bytearray(32 * 32 * 4)
    for y in range(32):
        for x in range(32):
            colour = vram.colour(256, 240, vram.texel4(448, 256, 144 + x, 128 + y))
            if colour:
                caret[(y * 32 + x) * 4:(y * 32 + x) * 4 + 4] = rgba(colour)
    # the keyboard's cell table (9 rows x 15 signed bytes at 0x8016AB38) and the vertical links of its right-hand columns (9 x 2 bytes
    # at 0x8016ABC0), both inside the password module loaded at 0x80168000 (WA sector 8054, 15 sectors)
    module = wa[8054 * SECTOR:8054 * SECTOR + 15 * SECTOR]
    table = [[b - 256 if b >= 128 else b for b in module[0x2B38 + r * 15:0x2B38 + r * 15 + 15]] for r in range(9)]
    links = [list(module[0x2BC0 + r * 2:0x2BC0 + r * 2 + 2]) for r in range(9)]
    import json
    written = bool(write_output(output / "name_entry" / "keyboard.json", json.dumps({"cells": table, "links": links}), output))
    written += bool(write_output(output / "name_entry" / "backdrop.png", png(SCREEN_W, SCREEN_H, bytes(back)), output))
    written += bool(write_output(output / "name_entry" / "caret.png", png(32, 32, bytes(caret)), output))
    # the dialog's frame: the first object of the resident tail table at 0x801AC000 (the default resource of display objects),
    # drawn on page 23 with the CLUT at (256, 241), as the name entry dialog update configures it
    base = 0x801AC000 - LOAD + HEADER
    bank = exe[base:base + 0x10000]
    panel = bytearray(SCREEN_W * SCREEN_H * 4)
    draw_object(vram, bank, resolve_stream(bank, 0, 0, 0), 16, 176, 23, 256, 241, False, panel)
    written += bool(write_output(output / "name_entry" / "dialog_panel.png", png(SCREEN_W, SCREEN_H, bytes(panel)), output))
    return written


OPTIONS_IMAGE, OPTIONS_PALETTE, OPTIONS_BANK = 0x108A800, 0x109A800, 0x109B000   # WA_MRG.MRG: 32 sectors at (0,256), 1 palette, 1 bank
BOOT_PALETTE = 0xB60000       # 256 x 8 at (512,248): the boot UI's CLUT rows


def bake_options(wa: bytes, su: bytes, exe: bytes, output: Path) -> int:
    """The options screen (the options menu, the options setup, the options layout update): the background object (the options bank at
    0x801AF000, page 16 = VRAM (0,256), CLUT (256,240)) and the cursor (the resident tail table's stream (3,4,0), page 11 = VRAM
    (704,0), CLUT (512,252) from the boot UI). The cursor is cut to its box; layout.json gives its offset from the object's origin."""
    import json
    vram = font_page(wa)
    # the main menu's images are still in VRAM when the options screen opens from it
    vram.upload_tiles(su[:64 * SECTOR], 512, 256)
    vram.upload_tiles(su[64 * SECTOR:96 * SECTOR], 896, 0)
    vram.upload_rect(su[96 * SECTOR:98 * SECTOR], 0, 240, 256, 8)
    vram.upload_tiles(wa[OPTIONS_IMAGE:OPTIONS_IMAGE + 32 * SECTOR], 0, 256)
    vram.upload_rect(wa[OPTIONS_PALETTE:OPTIONS_PALETTE + SECTOR], 256, 240, 256, 4)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    bank = wa[OPTIONS_BANK:OPTIONS_BANK + SECTOR]
    background = bytearray(SCREEN_W * SCREEN_H * 4)
    draw_object(vram, bank, resolve_stream(bank, 0, 0, 0), 0, 0, OBJECT_PAGE, OBJECT_CLUT[0], OBJECT_CLUT[1], False, background)
    # the options picture is 224 lines tall: the game's frame below it is black (the reference frames' bottom 16 lines), so the
    # texture rows past 224 are cleared
    background[224 * SCREEN_W * 4:] = bytes(len(background) - 224 * SCREEN_W * 4)
    # the resident tail table at 0x801AC000 is the default resource of an acquired display object (as in bake_name_entry)
    base = 0x801AC000 - LOAD + HEADER
    tail = exe[base:base + 0x10000]
    margin = 64
    width, height = SCREEN_W + margin * 2, SCREEN_H + margin * 2
    # the cursor is animated: stream (3,4,0) of the tail table cycles its frames (the sparkle), each held for `duration` ticks,
    # then 0xFE restarts it. Every distinct frame is cut to its box; the layout gives each one's offset from the object's origin.
    u16 = lambda o: struct.unpack_from("<H", tail, o)[0]
    at = u16(u16(u16(3 * 2) + 4 * 2) + 0 * 2)     # the stream's command list (resolve_stream's tree walk)
    offsets, sequence, duration = [], [], 0
    while tail[at] < 0xF0:
        offset = u16(at + 1)
        if offset not in offsets:
            offsets.append(offset)
        sequence.append(offsets.index(offset))
        duration = tail[at]
        at += 3
    written = bool(write_output(output / "options" / "background.png", png(SCREEN_W, SCREEN_H, bytes(background)), output))
    layout = {"background": {"x": 0, "y": 0}, "cursor": {"frames": [], "sequence": sequence, "duration": duration}}
    for index, offset in enumerate(offsets):
        cursor = bytearray(width * height * 4)
        draw_object(vram, tail, offset, 0, 0, 0xB, 0x200, 0xFC, False, cursor, margin)
        cut = cropped(bytes(cursor), width, height, margin)
        if cut is not None:
            data, ox, oy = cut
            written += bool(write_output(output / "options" / f"cursor_{index}.png", data, output))
            layout["cursor"]["frames"].append({"x": ox, "y": oy})
    written += bool(write_output(output / "options" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


CARD_FRAME_STREAM = (3, 2, 1)   # the memory-card dialog's frame: stream (3, 2, 1) of the resident tail table, page 11, CLUT (512, 252)


def bake_card_frame(wa: bytes, exe: bytes, output: Path) -> int:
    """The memory-card notice frame (the memory-card dialog's frame object, placed at (32, 80)): the same tail-table stream family
    and VRAM as the options cursor, the boot UI picture and its palette. The picture is cut to its box; layout.json gives its
    offset from the object's origin, which the notice places at (32, 80)."""
    import json
    vram = font_page(wa)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    base = 0x801AC000 - LOAD + HEADER
    tail = exe[base:base + 0x10000]
    margin = 64
    width, height = SCREEN_W + margin * 2, SCREEN_H + margin * 2
    frame = bytearray(width * height * 4)
    draw_object(vram, tail, resolve_stream(tail, *CARD_FRAME_STREAM), 0, 0, 0xB, 0x200, 0xFC, False, frame, margin)
    written = 0
    layout = {}
    cut = cropped(bytes(frame), width, height, margin)
    if cut is not None:
        data, ox, oy = cut
        written += bool(write_output(output / "card_frame" / "frame.png", data, output))
        layout["frame"] = {"x": ox, "y": oy}
    written += bool(write_output(output / "card_frame" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


def bake_dialog_arrow(wa: bytes, exe: bytes, output: Path) -> int:
    """The blinking arrow the choice box opening puts in a text box's bottom-right corner: stream (3,0,0) of the resident tail table drawn
    on page 11 = VRAM (704,0) with the CLUT at (512,252). The stream cycles three frames (0x1706, 0x1710, 0x171A, 0x1710) for 9
    ticks each and then restarts (opcode 0xFE); the frames are cut to their boxes, layout.json gives each one's offset from the
    object's origin (the box's x + width - 16, y + height - 16)."""
    import json
    vram = font_page(wa)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    base = 0x801AC000 - LOAD + HEADER
    bank = exe[base:base + 0x10000]
    u16 = lambda o: struct.unpack_from("<H", bank, o)[0]
    stream = u16(u16(u16(3 * 2) + 0 * 2) + 0 * 2)
    frames, sequence, at = [], [], stream
    while bank[at] < 0xF0:
        offset = u16(at + 1)
        if offset not in frames:
            frames.append(offset)
        sequence.append(frames.index(offset))
        duration = bank[at]
        at += 3
    margin = 32
    width, height = SCREEN_W + margin * 2, SCREEN_H + margin * 2
    written, layout = 0, {"frames": [], "sequence": sequence, "duration": duration}
    for index, offset in enumerate(frames):
        canvas = bytearray(width * height * 4)
        draw_object(vram, bank, offset, 0, 0, 0xB, 0x200, 0xFC, False, canvas, margin)
        cut = cropped(bytes(canvas), width, height, margin)
        data, ox, oy = cut
        written += bool(write_output(output / "dialog_arrow" / f"{index}.png", data, output))
        layout["frames"].append({"x": ox, "y": oy})
    written += bool(write_output(output / "dialog_arrow" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


LIBRARY_PACKAGE = 0x1DCD * SECTOR   # WA_MRG.MRG: the Library's 138 sectors, streamed in six phases (the routine at 0x8002BD0C)
LIBRARY_TILES = {"tile_0": 0x160, "tile_1": 0x170, "tile_2": 0x180, "tile_3": 0x190}   # CLUT x: monsters, magic and equip, trap, ritual


def bake_library(wa: bytes, output: Path) -> int:
    """The card library's grid tile (the card grid drawing): a 12x14 4-bit picture on page 27 = VRAM (704,256) at (96,240), in the four
    CLUT colours of its card type on row 247 (tile_0 monsters, tile_1 magic and equip, tile_2 trap, tile_3 ritual). The cursor sprite
    and the info and card frames sit on the same page, but their texels are not located yet and are not baked."""
    package = wa[LIBRARY_PACKAGE:LIBRARY_PACKAGE + 138 * SECTOR]
    vram = Vram()
    vram.upload_rect(package[64 * SECTOR:68 * SECTOR], 256, 240, 256, 16)
    vram.upload_tiles(package[68 * SECTOR:116 * SECTOR], 576, 256)
    vram.upload_rect(package[116 * SECTOR:117 * SECTOR], 256, 246, 256, 2)
    written = 0
    for name, clut in LIBRARY_TILES.items():
        canvas = bytearray(12 * 14 * 4)
        for j in range(14):
            for i in range(12):
                colour = vram.colour(clut, 247, vram.texel4(704, 256, 0x60 + i, 0xF0 + j))
                if colour:
                    canvas[(j * 12 + i) * 4:(j * 12 + i) * 4 + 4] = rgba(colour)
        written += bool(write_output(output / "library" / f"{name}.png", png(12, 14, bytes(canvas)), output))
    return written


LIBRARY_TAIL = 0x801AC000       # the resident display bank the Library's objects draw from (default resource of an object)


def bake_library2(wa: bytes, exe: bytes, output: Path) -> int:
    """The Library's sprites from the resident bank: the eight section panels (resource 0, group 3, streams 0-7; 8 bits, page 25,
    CLUT row 246), the info band (group 2, stream 1, at (16, 216), page 27, CLUT row 247) and the cursor sprite (group 2, stream 2,
    page 27, CLUT row 247). Each piece is cut to its opaque box; layout.json gives each one's offset from the origin the Library
    places it at (the panels at x 8 or 168, y 8 + 178 * row; the cursor at its cell)."""
    import json
    package = wa[LIBRARY_PACKAGE:LIBRARY_PACKAGE + 138 * SECTOR]
    vram = Vram()
    vram.upload_tiles(package[:64 * SECTOR], 768, 256)
    vram.upload_rect(package[64 * SECTOR:68 * SECTOR], 256, 240, 256, 16)
    vram.upload_tiles(package[68 * SECTOR:116 * SECTOR], 576, 256)
    vram.upload_rect(package[116 * SECTOR:117 * SECTOR], 256, 246, 256, 2)
    tail = exe[LIBRARY_TAIL - LOAD + HEADER:LIBRARY_TAIL - LOAD + HEADER + 0x10000]
    margin = 64
    width, height = SCREEN_W + margin * 2, SCREEN_H + margin * 2
    layout, written = {}, 0

    def piece(name, stream, origin, page, texture, wide, cell_offset=False, texture_v=0):
        nonlocal written
        canvas = bytearray(width * height * 4)
        draw_object(vram, tail, resolve_stream(tail, *stream), 0, 0, page, texture & 0x3F0, (texture & 0xF) + 0xF0, wide, canvas, margin,
                    cell_offset=cell_offset, texture=(0, texture_v))
        cut = cropped(bytes(canvas), width, height, margin)
        if cut is None:
            return
        data, ox, oy = cut
        written += bool(write_output(output / "library" / f"{name}.png", data, output))
        layout[name] = {"origin": list(origin), "x": ox, "y": oy}

    for i in range(8):
        piece(f"panel_{i}", (0, 3, i), (8 if not i & 1 else 168, (i >> 1) * 178 + 8), 25, 0x106, True)
    piece("info_band", (0, 2, 1), (16, 216), 27, 0x127, False, texture_v=128)   # the band's texel V base is 128 (object byte 0x5E)
    # the card view's box: the library's own frame object (group 2, stream 0), which rests at the text box's origin (148, 14)
    piece("card_frame", (0, 2, 0), (148, 14), 27, 0x107, False, texture_v=128)   # the card view box is drawn 128 texel rows down the page (V base 128)
    # the cursor is the magnifier: a 16 x 16 cell at texels (112, 224) of page 27 in CLUT row 247 at x 320, placed 8 pixels up and
    # left of the cursor's cell (the sprite's own offset). The stream's first frame (texels 112, 96) is texture noise, not the cursor.
    cursor = bytearray(16 * 16 * 4)
    for j in range(16):
        for i in range(16):
            colour = vram.colour(0x140, 247, vram.texel4(704, 256, 112 + i, 224 + j))
            if colour:
                cursor[(j * 16 + i) * 4:(j * 16 + i) * 4 + 4] = rgba(colour)
    written += bool(write_output(output / "library" / "cursor.png", png(16, 16, bytes(cursor)), output))
    layout["cursor"] = {"origin": [0, 0], "x": -8, "y": -8}
    written += bool(write_output(output / "library" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


FREE_DUEL = 0xF44000             # WA_MRG.MRG: the Free Duel package, 87 sectors: 32 image sectors (VRAM (0,256)), the palette, the bank, 40 portraits, the module
FREE_DUEL_PALETTE, FREE_DUEL_BANK, FREE_DUEL_PORTRAITS = 0xF54000, 0xF54800, 0xF55000
PORTRAIT_RECORD = 0x980          # a 48 x 48 8-bit image (0x900 bytes) and its 64-colour CLUT


def stream_frames(bank: bytes, f67: int, f68: int, f69: int):
    """The frame offsets of a stream in play order, up to its loop opcode (a byte of 0xF0 or more); each entry is (hold, u16 offset)."""
    u16 = lambda o: struct.unpack_from("<H", bank, o)[0]
    at, frames = u16(u16(u16(f67 * 2) + f68 * 2) + f69 * 2), []
    while bank[at] < 0xF0:
        frames.append(u16(at + 1))
        at += 3
    return frames


def bake_free_duel(wa: bytes, output: Path) -> int:
    """The Free Duel opponent select (the Free Duel setup): the two backdrop objects (bank streams (0,0,0) and (0,0,1)) on page 16 at 8 bits with
    CLUT row 0; the cursor's four frames (stream (0,0,3)) on page 17 at 4 bits with CLUT row 3, each frame's header shifting its palette
    block; the scroll thumb (stream (0,0,2)), the same page and CLUT row; and the forty portraits (48 x 48, 8 bits, each with its own CLUT).
    The cursor, its sparkles and the thumb are all made with the texel V base 128 (the object's second byte at 0x5E, set by the
    spawn and the thumb configuration), so their texels are read 128 rows down the page. layout.json gives each cut-out's offset from
    its object's origin."""
    import json
    vram = Vram()
    vram.upload_tiles(wa[FREE_DUEL:FREE_DUEL + 32 * SECTOR], 0, 256)
    vram.upload_rect(wa[FREE_DUEL_PALETTE:FREE_DUEL_PALETTE + SECTOR], 0, 240, 256, 4)
    bank = wa[FREE_DUEL_BANK:FREE_DUEL_BANK + SECTOR]
    layout, written = {}, 0

    def emit(name, offset, page, clut_row, wide, texture=(0, 0)):
        nonlocal written
        canvas = bytearray(SCREEN_W * SCREEN_H * 4)
        draw_object(vram, bank, offset, 0, 0, page, 0, 240 + clut_row, wide, canvas, texture=texture)
        cut = cropped(bytes(canvas), SCREEN_W, SCREEN_H, 0)
        data, ox, oy = cut
        written += bool(write_output(output / "free_duel" / f"{name}.png", data, output))
        return {"x": ox, "y": oy}

    layout["frame"] = emit("frame", resolve_stream(bank, 0, 0, 0), 16, 0, True)
    layout["backdrop"] = emit("backdrop", resolve_stream(bank, 0, 0, 1), 16, 0, True)
    layout["thumb"] = emit("thumb", resolve_stream(bank, 0, 0, 2), 17, 3, False, (0, 128))
    layout["cursor"] = [emit(f"cursor_{i}", offset, 17, 3, False, (0, 128)) for i, offset in enumerate(stream_frames(bank, 0, 0, 3))]
    for n in range(40):
        record = FREE_DUEL_PORTRAITS + n * PORTRAIT_RECORD
        clut = record + 0x900
        pixels = bytearray(48 * 48 * 4)
        for y in range(48):
            for col in range(48):
                colour = struct.unpack_from("<H", wa, clut + wa[record + y * 48 + col] * 2)[0]
                pixels[(y * 48 + col) * 4:(y * 48 + col) * 4 + 4] = rgba(colour)
        written += bool(write_output(output / "free_duel" / "portraits" / f"{n:02d}.png", png(48, 48, bytes(pixels)), output))
    written += bool(write_output(output / "free_duel" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


CREDITS_MODULE = 1223 * SECTOR   # SU.MRG: the credits module, 16 sectors loaded at 0x80180000 (the routine at 0x800507D0 requests sectors [1223, 1239))
CREDITS_TABLE = 0x1D38           # the module's the data at 0x80181D38: CreditsEntry rows of 8 bytes (group, flags, two pad, text pointer), ended by group -1
CREDITS_SECRET_NUMBERS = 0x80090B50   # gCredits_awSecretNumbers in the executable: five pairs of u16
CREDITS_PALETTES = (             # the routine at 0x801807B0's three glyph palettes, uploaded at (512, 246), (512, 247) and (512, 248) (the CLUTs 0x3DA0, 0x3DE0, 0x3E20)
    (0x0000, 0x8421, 0x9084, 0x9CE7, 0xA529, 0xAD6B, 0xB5AD, 0xBDEF, 0xC631, 0xCE73, 0xD6B5, 0xDEF7, 0xE739, 0xEF7B, 0xF7BD, 0xFFFF),
    (0x0000, 0x8421, 0x8844, 0x8C67, 0x9089, 0x94AB, 0x98CD, 0x9CEF, 0xA111, 0xA533, 0xA955, 0xAD77, 0xB199, 0xB5BB, 0xB9DD, 0xBDFF),
    (0x0000, 0x8421, 0x8882, 0x8CE3, 0x9124, 0x9565, 0x99A6, 0x9DE7, 0xA228, 0xA669, 0xAAAA, 0xAEEB, 0xB32C, 0xB76D, 0xBBAE, 0xBFEF),
)


def bake_credits(wa: bytes, su: bytes, exe: bytes, output: Path) -> int:
    """The credits roll (the routine at 0x801807B0, the routine at 0x80180F58, the routine at 0x8018173C): the module's 153 table rows (group, flags, text; the text bytes are
    ASCII, drawn one 8 x 12 cell per byte) as credits/roll.json, the three glyph atlases (the font page at (640, 0), 4 bits per pixel, each
    under one of the palettes above, 128 x 72) as credits/font_0..2.png, and the five secret numbers (gCredits_awSecretNumbers) in roll.json."""
    import json
    module = su[CREDITS_MODULE:CREDITS_MODULE + 16 * SECTOR]
    rows, at = [], CREDITS_TABLE
    while True:
        group, flags = struct.unpack_from("<bB", module, at)
        if group < 0:
            break
        pointer = struct.unpack_from("<I", module, at + 4)[0]
        text = None
        if pointer:
            start = pointer - 0x80180000
            text = module[start:module.index(b"\0", start)].decode("latin-1")
        rows.append({"group": group, "flags": flags, "text": text})
        at += 8
    base = CREDITS_SECRET_NUMBERS - LOAD + HEADER
    secrets = [list(struct.unpack_from("<2H", exe, base + 4 * i)) for i in range(5)]
    vram = font_page(wa)
    written = 0
    for k, palette in enumerate(CREDITS_PALETTES):
        pixels = bytearray(128 * 72 * 4)
        for v in range(72):
            for u in range(128):
                pixels[(v * 128 + u) * 4:(v * 128 + u) * 4 + 4] = rgba(palette[vram.texel4(640, 0, u, v)])
        written += bool(write_output(output / "credits" / f"font_{k}.png", png(128, 72, bytes(pixels)), output))
    written += bool(write_output(output / "credits" / "roll.json", json.dumps({"rows": rows, "secret_numbers": secrets}, separators=(",", ":")), output))
    return written


# ---- credits monsters (DATA/MODEL.MRG) -------------------------------------
MONSTER_RECORD_SECTORS = 0x114          # one monster's record: 276 sectors
MONSTER_ID_END = 0x2D2                  # the model ids of the monster MRG (ids at or above it have no record)
MONSTER_GAPS = ((0x12C, 0x15E), (0x28A, 0x2BC))   # model ids with no record (end-exclusive)
MONSTER_GAP_SINGLE = 0x2D0
MONSTER_CARD_COUNT = 722                # the card count: the credits roll the model ids 0..721


def monster_record(model: int):
    """The record index of a model id (the monster loader's arithmetic: the gap ids are rejected and the ids above a gap move down), or None when the id has no record."""
    if not 0 <= model < MONSTER_ID_END or any(a <= model < b for a, b in MONSTER_GAPS) or model == MONSTER_GAP_SINGLE:
        return None
    if model >= MONSTER_ID_END - 1:
        model -= 1
    if model >= MONSTER_GAPS[1][1]:
        model -= MONSTER_GAPS[1][1] - MONSTER_GAPS[1][0]
    if model >= MONSTER_GAPS[0][1]:
        model -= MONSTER_GAPS[0][1] - MONSTER_GAPS[0][0]
    return model


def parse_monster(mrg: bytes, record: int) -> dict:
    """One monster record of MODEL.MRG as libhmd lays it out. Word 3 counts the units; word 4 + u is unit u's first primitive
    block (0 when it has none). A block is next, section group, count (high bit: relocation pending), then primitives: a type
    word (the kind in the low 16 bits; bit 23 marks the block that carries the coordinate array), a size word (polygon count
    in the high 15 bits, size in the low 16), the polygon offset, and the size's words. The section group lists the block's
    sections: polygons, vertices, normals, and (for the flagged block) the coordinate array, a count word then 80-byte units
    (matrix, translation, Euler angles, parent word offset). Coordinate unit k is the transform of unit k + 1.

    Returns {"size", "coords": [{m, t, rot, parent}], "units": [{"blocks": [{"vertices": [[x, y, z]], "polys": [{quad, gouraud,
    v}]}]}]}; each poly's v are indices into its block's vertices (quads list their corners in order 0 1 2 3)."""
    base = record * MONSTER_RECORD_SECTORS * SECTOR
    word = lambda i: struct.unpack_from("<I", mrg, base + i * 4)[0]
    at, units_count = word(2), word(3)
    groups = {}
    p = at + 1
    for _ in range(word(at)):
        n = word(p)
        groups[p] = [word(p + 1 + i) & 0x7FFFFFFF for i in range(n)]
        p += 1 + n
    coord_section = None
    raw_units = []
    for u in range(units_count):
        blocks, b = [], word(4 + u)
        while b:
            nxt, grp, cnt = word(b), word(b + 1), word(b + 2) & 0xFFFF
            sections = groups[grp]
            prims, c = [], b + 3
            for _ in range(cnt):
                t, size_word = word(c), word(c + 1)
                size = size_word & 0xFFFF
                prims.append((t, c + 1, size))
                if t & 0x800000:
                    coord_section = sections[-1]
                c += 1 + size
            blocks.append((sections, prims))
            if nxt == 0xFFFFFFFF:
                break
            b = nxt
        raw_units.append(blocks)
    coords = []
    if coord_section is not None:
        for i in range(word(coord_section)):
            o = coord_section + 1 + i * 20
            m = struct.unpack_from("<9h", mrg, base + o * 4 + 4)
            t = struct.unpack_from("<3i", mrg, base + o * 4 + 24)
            rot = struct.unpack_from("<3h", mrg, base + o * 4 + 68)
            sup = word(o + 19)
            parent = (sup - coord_section - 1) // 20 if sup else -1
            coords.append({"m": list(m), "t": list(t), "rot": list(rot), "parent": parent})
    units = []
    for blocks in raw_units:
        out_blocks = []
        for sections, prims in blocks:
            polys, used = [], 0
            for t, data_at, _size in prims:
                kind = t & 0xFFFF
                if (t >> 24) & 0x7F or kind not in (0x9, 0xD, 0x11, 0x15):
                    continue
                count = (word(data_at) & 0x7FFFFFFF) >> 16
                first = sections[0] + word(data_at + 1)
                quad, gouraud = kind in (0x11, 0x15), kind in (0xD, 0x15)
                stride = {(False, False): 20, (False, True): 24, (True, False): 24, (True, True): 28}[(quad, gouraud)]
                corners = 4 if quad else 3
                for n in range(count):
                    half = struct.unpack_from("<%dH" % (stride // 2), mrg, base + first * 4 + n * stride)
                    if gouraud:
                        v = [half[7 + 2 * i] for i in range(corners)]
                    else:
                        v = [half[(8 if quad else 7) + i] for i in range(corners)]
                    polys.append({"quad": quad, "gouraud": gouraud, "v": v})
                    used = max(used, max(v) + 1)
            vertices = []
            if sections[1:2] and used:
                vsec = sections[1]
                vertices = [list(struct.unpack_from("<3h", mrg, base + vsec * 4 + i * 8)) for i in range(used)]
            out_blocks.append({"vertices": vertices, "polys": polys})
        units.append({"blocks": out_blocks})
    return {"size": word(0), "coords": coords, "units": units}


def encode_monster(monster: dict, anim, meta: bytes) -> bytes:
    """One monster's blob (before compression), read by scripts/menu/credits_monsters.gd (all little endian):
    the coordinate units: u32 count, then per unit 9 s16 matrix words, 2 pad, 3 s32 translation, 3 s16 Euler angles, s16 parent
    (-1 for the root), 2 pad. The units: u32 count, then per unit s16 coordinate index (unit u drives coordinate u - 1, -1 when
    none), u32 block count, then per block u32 vertex count, s16 x y z per vertex, u32 polygon count, then per polygon u8 flags
    (1 quad, 2 Gouraud), u8 pad and u16 corners (4 for quads, the last 0 for triangles). The animation (monster_anim.MonsterAnim,
    after the loader's tables): u32 part count, then per part the GsSEQ fields (u32 rewrite, u16 size, u16 num, u16 ii, u16 aframe,
    u8 sid, s8 speed, u16 srcii, s16 rframe, u16 tframe, u16 ci, u16 ti, u16 start, u8 start_sid, u8 traveling); u16 x 580 (10 rows
    x 58 part keys) and u16 x 580 (the row durations), u16 x 10 (the row maxima), 8 bytes of the coordinate-bit flags; u32 handler
    count, then the handler words; u32 command count, then the command words (after the relink); u32 keyframe halfword count, then
    the keyframe halfwords; s8 x 3 (the slot's offsets from the META sector: the centre adjustments); s16 root coordinate index."""
    out = bytearray(struct.pack("<I", len(monster["coords"])))
    for c in monster["coords"]:
        out += struct.pack("<9h2x3i3hh2x", *c["m"], *c["t"], *c["rot"], c["parent"])
    out += struct.pack("<I", len(monster["units"]))
    for u, unit in enumerate(monster["units"]):
        coord = u - 1 if 1 <= u <= len(monster["coords"]) else -1
        out += struct.pack("<h", coord)
        out += struct.pack("<I", len(unit["blocks"]))
        for block in unit["blocks"]:
            out += struct.pack("<I", len(block["vertices"]))
            for x, y, z in block["vertices"]:
                out += struct.pack("<3h", x, y, z)
            out += struct.pack("<I", len(block["polys"]))
            for poly in block["polys"]:
                corners = list(poly["v"]) + [0] * (4 - len(poly["v"]))
                out += struct.pack("<BxHHHH", (1 if poly["quad"] else 0) | (2 if poly["gouraud"] else 0), *corners)
    out += struct.pack("<I", anim.E1B)
    for sq in anim.seqs:
        out += struct.pack("<IHHHHBbHhHHHHBB", sq.rewrite, sq.size, sq.num, sq.ii, sq.aframe, sq.sid, sq.speed, sq.srcii,
                           sq.rframe, sq.tframe, sq.ci, sq.ti, sq.start, sq.start_sid, sq.traveling)
    for row in anim.k2c8:
        out += struct.pack("<58H", *row)
    for row in anim.t750:
        out += struct.pack("<58H", *row)
    out += struct.pack("<10H", *anim.t750_max)
    out += bytes(anim.BEC)
    n_handlers = anim.W[anim.htop] & 0xFFFF
    out += struct.pack("<I", n_handlers) + struct.pack("<%dI" % n_handlers, *anim.W[anim.htop + 1:anim.htop + 1 + n_handlers])
    commands = anim.W[anim.ctop:anim.ptop]
    out += struct.pack("<I", len(commands)) + struct.pack("<%dI" % len(commands), *commands)
    data_refs = [w & 0xFFFF for w in commands if w < 0x80000000]
    nhalf = 2 * (max(data_refs) if data_refs else 0) + 18      # a keyframe is nine halfwords at its word offset
    words = anim.W[anim.ptop:anim.ptop + (nhalf + 1) // 2]
    halves = []
    for word in words:
        halves += [word & 0xFFFF, word >> 16]
    halves = halves[:nhalf]
    out += struct.pack("<I", len(halves)) + struct.pack("<%dH" % len(halves), *halves)
    out += struct.pack("<3b", *[struct.unpack_from("<b", meta, 256 + j)[0] for j in (4, 5, 6)])
    root = next((i for i, c in enumerate(monster["coords"]) if c["parent"] < 0), -1)
    out += struct.pack("<h", root)
    return bytes(out)


def bake_credits_monsters(mrg: bytes, output: Path) -> int:
    """The credits monsters: every model id the credits can roll (the ids below the card count that have a record), each as
    monster_anim.MonsterAnim loads it and parse_monster reads its polygons, encoded by encode_monster and zlib-compressed. The file,
    credits/monsters.bin: u32 magic 'MNS2', u32 count, then per monster u16 model id, u32 offset, u32 compressed length and u32
    uncompressed length (offsets from the start of the file), then the compressed blobs."""
    import zlib
    import monster_anim
    entries = []
    for model in range(MONSTER_CARD_COUNT):
        record = monster_record(model)
        if record is None:
            continue
        rec_bytes = mrg[record * MONSTER_RECORD_SECTORS * SECTOR:(record + 1) * MONSTER_RECORD_SECTORS * SECTOR]
        anim = monster_anim.MonsterAnim(rec_bytes)
        meta = rec_bytes[275 * SECTOR:276 * SECTOR]
        blob = encode_monster(parse_monster(mrg, record), anim, meta)
        entries.append((model, zlib.compress(blob, 9), len(blob)))
    index_size = 8 + len(entries) * 14
    body, offset = bytearray(), index_size
    index = bytearray(struct.pack("<II", 0x32534E4D, len(entries)))
    for model, packed, raw_length in entries:
        index += struct.pack("<HIII", model, offset, len(packed), raw_length)
        body += packed
        offset += len(packed)
    return int(bool(write_output(output / "credits" / "monsters.bin", bytes(index + body), output)))


DUEL_RESULT_PACKAGE = 0x1DAB * SECTOR   # WA_MRG.MRG: the result screen's 34 sectors (the routine at 0x80020BE4): 32 image sectors at VRAM (0, 256), a palette at (0, 248) 256 x 4, and the display resource (the data at 0x801AF000)


CONFETTI_MARGIN = 32   # the outro's confetti: room around the spawn point for parts up to 24 pixels left of or above it (see bake_duel_result)


def bake_duel_result(wa: bytes, exe: bytes, output: Path) -> int:
    """The duel result screen's pictures, the sprite sheets the result rewards update and the result page display draw from the
    display resource: the page frame (record 4, variant = page) at (0, 8), the rank badge (record 5, variant = is_tec) and the rank
    letter (record 6, variant = tier) at (0, 16). Each is one sheet as the sprite sheet rendering draws it, object page 16 and
    CLUT (0, 248), cut to its opaque box; layout.json gives each box's screen position. The starchip picture is the rewards routine's starchip object, baked as starchip.png."""
    import json
    package = wa[DUEL_RESULT_PACKAGE:DUEL_RESULT_PACKAGE + 34 * SECTOR]
    vram = Vram()
    vram.upload_tiles(package[:32 * SECTOR], 0, 256)
    vram.upload_rect(package[32 * SECTOR:33 * SECTOR], 0, 248, 256, 4)
    bank = package[33 * SECTOR:34 * SECTOR]
    layout, written = {}, 0

    def emit(name, record, variant, x, y, page=OBJECT_PAGE, clut_x=0, clut_y=248, blend=False, margin=0):
        # margin: the canvas is drawn with this much room on every side, for parts that sit left of or above the object's origin
        nonlocal written
        size_w, size_h = SCREEN_W + margin * 2, SCREEN_H + margin * 2
        canvas = bytearray(size_w * size_h * 4)
        try:
            draw_object(vram, bank, resolve_stream(bank, 0, record, variant), x, y, page, clut_x, clut_y, False, canvas, margin=margin,
                        canvas_w=size_w, canvas_h=size_h, blend=blend)
        except (IndexError, struct.error):
            return None            # no such sprite in the bank
        found = cropped(bytes(canvas), size_w, size_h, margin)
        if found is None:
            return None            # nothing opaque
        data, ox, oy = found
        written += bool(write_output(output / "duel_result" / f"{name}.png", data, output))
        return {"x": ox, "y": oy}

    layout["frame"] = [emit(f"frame_{page}", 4, page, 0, 8, margin=CONFETTI_MARGIN) for page in range(3)]
    layout["badge"] = [emit(f"badge_{tec}", 5, tec, 0, 16, margin=CONFETTI_MARGIN) for tec in range(2)]
    layout["letter"] = [emit(f"letter_{tier}", 6, tier, 0, 16, margin=CONFETTI_MARGIN) for tier in range(5)]
    # the outro's confetti: the winning side is the record and the table's kind the variant (1 to 29), drawn at the spawn point, so
    # each box is an offset from it. Variant 0 is the table's unused slot, so record 0, variant 0 is not drawn here; the duel result
    # opcode's picture is the title logo, baked by bake_logo from its own package
    # the spawn configures the page as colour 0x11 + the header's page (VRAM 64, 256), the CLUT row 249 with the texture cell offset,
    # the CLUT x moved by 16 for kinds 26 and up, and the semi-transparent (average) attribute
    # The parts sit around the spawn point (dx and dy down to -24), so the canvas has a margin of CONFETTI_MARGIN on every side:
    # without it the left and top halves of every piece were clipped, which left the flat-edged fragments.
    layout["confetti"] = [[emit(f"confetti_{side}_{kind}", side, kind, 0, 0, page=0x11, clut_x=0x10 if kind >= 0x1A else 0, clut_y=249,
                                blend=True, margin=CONFETTI_MARGIN) for kind in range(1, 30)] for side in range(2)]
    # the trails the orbiting sprites leave (the routine at 0x80020D4C spawns a copy with its CLUT x moved by 0x80, so the
    # copy's palette block is the same colours with the semi-transparent bit set): drawn additively by the port, with the brightness
    # fade in duel_result.gd. Same art and crop as the body, so the body's layout box serves both.
    for side in range(2):
        for kind in range(1, 30):
            emit(f"confetti_{side}_{kind}_trail", side, kind, 0, 0, page=0x11, clut_x=0x80 + (0x10 if kind >= 0x1A else 0), clut_y=249,
                 margin=CONFETTI_MARGIN)
    # the SPOILS prize picture: the rewards routine's starchip object is resource 3, group 4, stream 0 of the display bank, on page 11
    # (the boot UI at VRAM 704, 0) with the CLUT at (512, 252) of the boot palette; it is drawn at its spawn origin, so each box is an offset
    # the object's resource is the resident display bank at 0x801AC000 (the same bank as the duel's life-point panel)
    tail = exe[0x801AC000 - LOAD + HEADER:0x801AC000 - LOAD + HEADER + 0x10000]
    starchip_vram = Vram()
    starchip_vram.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * SECTOR], 640, 0)
    starchip_vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    # the chip's parts sit left of and above its origin too, so it is drawn with the same margin as the confetti (see CONFETTI_MARGIN)
    margin = CONFETTI_MARGIN
    size_w, size_h = SCREEN_W + margin * 2, SCREEN_H + margin * 2
    canvas = bytearray(size_w * size_h * 4)
    draw_object(starchip_vram, tail, resolve_stream(tail, 3, 4, 0), 0, 0, 11, 512, 252, False, canvas, margin=margin,
                canvas_w=size_w, canvas_h=size_h)
    found = cropped(bytes(canvas), size_w, size_h, margin)
    if found is not None:
        data, ox, oy = found
        written += bool(write_output(output / "duel_result" / "starchip.png", data, output))
        layout["starchip"] = {"x": ox, "y": oy}
    # the page-turn arrows (the corners of the three pages): 16 by 16 texels at (96, 192) of the boot UI's page 11 (VRAM 704, 0) in CLUT
    # (544, 252); the right arrow is drawn at (288, 16) and the left one, its mirror, at (16, 16) (the duel_result.gd constants)
    arrow = bytearray(16 * 16 * 4)
    for j in range(16):
        for i in range(16):
            index = starchip_vram.texel4(704, 0, 96 + i, 192 + j)
            colour = starchip_vram.colour(544, 252, index) if index else 0
            if colour:
                arrow[(j * 16 + i) * 4:(j * 16 + i) * 4 + 4] = rgba(colour)
    mirrored = bytearray(len(arrow))
    for j in range(16):
        for i in range(16):
            mirrored[(j * 16 + i) * 4:(j * 16 + i) * 4 + 4] = arrow[(j * 16 + (15 - i)) * 4:(j * 16 + (15 - i)) * 4 + 4]
    written += bool(write_output(output / "duel_result" / "arrow_right.png", png(16, 16, bytes(arrow)), output))
    written += bool(write_output(output / "duel_result" / "arrow_left.png", png(16, 16, bytes(mirrored)), output))
    written += bool(write_output(output / "duel_result" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


LOGO_PACKAGE = 0x1FA7 * SECTOR   # WA_MRG.MRG: the menu background and symbol package, 50 sectors (the routine at 0x8002F630): 48 image sectors, a palette sector, and the display bank (the last sector, at 0x801AF000)
LOGO_BANNER = (0x17, (0, 244))   # the title logo object: 8-bit page 0x17 (VRAM 448, 256), CLUT row 244 with the cell offset
LOGO_BACKDROP = (576, 256, 245)  # the hieroglyph backdrop: 4-bit page 0x19 (VRAM 576, 256), CLUT row 245 (its first 16 colours)


def bake_logo(wa: bytes, output: Path) -> int:
    """The picture of the duel result opcode (the script opcode 17): the title logo over the hieroglyph backdrop. The package's art is
    uploaded as the callback does: the 8-bit logo and the 4-bit backdrop in 16-tile columns from VRAM (448, 256), the 256-colour row at
    (0, 244) and the 16-colour row at (0, 245). The logo object is configured on stream (0, 0, 0) of the display bank; its first entry
    has hold 0, which parks the object on that frame (the stream is never advanced), so the picture is one still frame. layout.json gives
    the logo's origin, the backdrop's two panels (320 x 240 in all) and the fill: a subtractive gradient from black at the top (0) to
    white at the bottom (255), drawn over the backdrop and under the logo."""
    import json
    package = wa[LOGO_PACKAGE:LOGO_PACKAGE + 50 * SECTOR]
    vram = Vram()
    vram.upload_tiles(package[:48 * SECTOR], 448, 256)
    vram.upload_rect(package[48 * SECTOR:48 * SECTOR + 0x400], 0, 244, 256, 2)
    bank = package[49 * SECTOR:50 * SECTOR]
    hold, frame, _mirrored = stream_entries(bank, 0, 0, 0)[0]
    if hold != 0:
        raise ValueError(f"logo stream starts with hold {hold}: the picture would animate, which this baker does not handle")
    page, clut = LOGO_BANNER
    canvas = bytearray(SCREEN_W * SCREEN_H * 4)
    draw_object(vram, bank, frame, 0, 0, page, clut[0], clut[1], True, canvas, cell_offset=True)
    found = cropped(bytes(canvas), SCREEN_W, SCREEN_H, 0)
    if found is None:
        raise ValueError("the logo frame draws nothing")
    logo, lx, ly = found
    written = bool(write_output(output / "logo" / "logo.png", logo, output))
    x0, y0, clut_row = LOGO_BACKDROP[0], LOGO_BACKDROP[1], LOGO_BACKDROP[2]
    backdrop = bytearray(256 * 256 * 4)
    for y in range(256):
        for x in range(256):
            colour = vram.colour(0, clut_row, vram.texel4(x0, y0, x, y))
            if colour:
                backdrop[(y * 256 + x) * 4:(y * 256 + x) * 4 + 4] = rgba(colour)
    written += bool(write_output(output / "logo" / "backdrop.png", png(256, 256, bytes(backdrop)), output))
    layout = {
        "logo": {"file": "logo.png", "x": lx, "y": ly},
        "backdrop": {"file": "backdrop.png", "panels": [[0, 0, 256, 240], [256, 0, 64, 240]]},
        "fill": {"x": 0, "y": 0, "width": 320, "height": 240, "top": 0, "bottom": 255, "blend": "subtract"},
        "stream": {"entry": [0, 0, 0], "hold": hold, "frame": frame},
    }
    written += bool(write_output(output / "logo" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


BUILD_DECK_TABLE = 0x80090DD8   # the sort and type icon table: a row of eight byte pairs for the chest (16 bytes) and one for the deck


def bake_build_deck(wa: bytes, exe: bytes, output: Path) -> int:
    """The Build Deck screen's pictures (the routine at 0x800323F8, the routine at 0x80031874, the routine at 0x80031784, the deck box stats drawing). Its panes, scroll
    thumbs, cursors and arrows are display objects drawn from the resident tail table at 0x801AC000 (resource 0, group 4; the page
    buttons are resource 3, stream 3) on page 12 = VRAM (768, 0), and the digits, marks, New! and sort icons are direct sprites on
    page 11 = VRAM (704, 0). Both pages are the boot UI image (BOOT_UI at VRAM (640, 0)); the CLUT rows are the boot palette's 248-251.
    The package the routine at 0x80032328 requests (WA sector 0x2189, 76 sectors) is not read by any of these pieces. Object pieces are cut to their
    opaque box; layout.json gives each one's offset from its object's origin, the origin being the position the routine at 0x800323F8 gives it.
    Sprite pieces are exact 8x8, 16x16 or 24x8 cells, positioned by the code that draws them."""
    import json
    vram = Vram()
    vram.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * SECTOR], 640, 0)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    tail = exe[0x801AC000 - LOAD + HEADER:0x801AC000 - LOAD + HEADER + 0x10000]
    table = exe[BUILD_DECK_TABLE - LOAD + HEADER:BUILD_DECK_TABLE - LOAD + HEADER + 32]
    margin = 64
    width, height = SCREEN_W + margin * 2, SCREEN_H + margin * 2
    layout, written = {}, 0

    def object_piece(name, stream, origin, page, texture, cell, offset=None):
        nonlocal written
        canvas = bytearray(width * height * 4)
        draw_object(vram, tail, resolve_stream(tail, *stream) if offset is None else offset, 0, 0, page, texture & 0x3F0, (texture & 0xF) + 0xF0, False, canvas, margin,
                    cell_offset=cell)
        cut = cropped(bytes(canvas), width, height, margin)
        if cut is None:
            return
        data, ox, oy = cut
        written += bool(write_output(output / "build_deck" / f"{name}.png", data, output))
        layout[name] = {"origin": list(origin), "x": ox, "y": oy}

    def sprite_piece(name, u, v, w, h, cx, cy, page=11):
        nonlocal written
        pixels = bytearray(w * h * 4)
        for j in range(h):
            for i in range(w):
                index = vram.texel4((page & 0xF) * 64, ((page >> 4) & 1) * 256, (u + i) & 0xFF, (v + j) & 0xFF)
                colour = vram.colour(cx, cy, index)
                if colour:
                    pixels[(j * w + i) * 4:(j * w + i) * 4 + 4] = rgba(colour)
        written += bool(write_output(output / "build_deck" / f"{name}.png", png(w, h, bytes(pixels)), output))

    def icon(name, pair):
        # the sort icon drawing: u = nibble * 8 - 128, v = high nibble, CLUT (high nibble | 512, 251)
        sprite_piece(name, ((pair[0] & 15) * 8 + 128) & 0xFF, pair[0] & 0xF0, 16, 16, (pair[1] & 0xF0) | 0x200, 251)

    # the panes (the routine at 0x800323F8's objects): the two 320 x 240 boxes, the sand behind them, the cursors and thumbs in front, the arrows
    object_piece("chest_box", (0, 4, 0), (0, 0), 12, 0x208, False)
    object_piece("deck_box", (0, 4, 1), (320, 0), 12, 0x208, False)
    object_piece("sand", (0, 4, 11), (0, 0), 12, 0x208, True)
    object_piece("cursor_bar", (0, 4, 2), (0, 42), 12, 0x208, True)
    object_piece("cursor_bar_blue", (0, 4, 3), (328, 42), 12, 0x218, True)
    object_piece("thumb", (0, 4, 12), (310, 41), 12, 0x208, True)
    # the two red arrows animate: their streams hold each frame 6 ticks, looping (sequence of [hold, frame index] in layout.json)
    for name, stream, origin in (("arrow_right", (0, 4, 9), (0, 0)), ("arrow_left", (0, 4, 10), (320, 0))):
        commands, _ = stream_commands(tail, *stream)
        offsets = []
        for _, offset in commands:
            if offset not in offsets:
                offsets.append(offset)
        for i, offset in enumerate(offsets):
            object_piece(f"{name}_{i}", stream, origin, 12, 0x208, True, offset=offset)
        object_piece(name, stream, origin, 12, 0x208, True, offsets[0])     # the base picture is the first frame; the build deck loads it by this name
        layout[name] = {"origin": list(origin), "x": layout[f"{name}_0"]["x"], "y": layout[f"{name}_0"]["y"],
                        "frames": [f"{name}_{i}" for i in range(len(offsets))],
                        "sequence": [[hold, offsets.index(offset)] for hold, offset in commands]}
    object_piece("page_buttons", (3, 0, 3), (320, 0), 11, 0x2F8, False)
    # the routine at 0x80031874's digits (8 x 8, u 0x80 + 8d, v 0x70), the ATK and DEF marks (u 0xD0 and 0xD8, v 0x58), New! (24 x 8 at u 0xE8, v 0x68),
    # all with CLUT (0x290, 250)
    for d in range(10):
        sprite_piece(f"digit_{d}", (d * 8 + 128) & 0xFF, 0x70, 8, 8, 0x290, 0xFA)
    sprite_piece("atk_mark", 0xD0, 0x58, 8, 8, 0x290, 0xFA)
    sprite_piece("def_mark", 0xD8, 0x58, 8, 8, 0x290, 0xFA)
    sprite_piece("new_mark", 0xE8, 0x68, 24, 8, 0x290, 0xFA)
    # the seven sort icons of each list: the chest's first six and the deck's first six are the same pairs; the seventh is
    # "your order" in the chest (pair 6 of its row) and "random" in the deck (pair 6 of its row)
    for i, name in enumerate(("sort_card_number", "sort_owned_first", "sort_best_stat", "sort_attack", "sort_defense", "sort_card_type")):
        icon(name, table[2 * i:2 * i + 2])
    icon("sort_your_order", table[12:14])
    icon("sort_random", table[16 + 12:16 + 14])
    written += bool(write_output(output / "build_deck" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


CARD_UI_PACKAGE = 0x2189 * SECTOR   # WA_MRG.MRG: the card-detail package, 76 sectors (the routine at 0x80032328 requests it; its image sits at WA 0x10E0800)
CARD_UI_PAGE, CARD_UI_PALETTE = 56, 72   # sectors 56-71: the card view's 256 x 256 page (VRAM page 0x1F, 4 bits a texel, 128 bytes a row); sectors 72-75: palette block at VRAM (256, 240)


def bake_card_ui(wa: bytes, output: Path) -> int:
    """The card view's pieces (the routine at 0x80028B08 draws them from VRAM page 0x1F): the eight attribute balls (Light, Dark, Earth,
    Water, Fire, Wind, then the spell and trap balls for the card classes 6 and 7 of the level/attribute byte), the level star, the decimal
    digits in white and dimmed (CLUT row 248 and 249 at x 496), and the labels ATK, DFD and the three card-kind labels (CLUT row 248 at x 480).
    Each ball's palette is the 16 colours at (256 + 16 * index, 255). A digit is a 6 x 13 cell at (16 + 6 * digit, 16). layout.json gives each
    piece's page position, its CLUT and its offset from the cell it was cut from (labels are cut to their opaque box)."""
    import json
    package = wa[CARD_UI_PACKAGE:CARD_UI_PACKAGE + 76 * SECTOR]
    page = package[CARD_UI_PAGE * SECTOR:(CARD_UI_PAGE + 16) * SECTOR]
    palette = package[CARD_UI_PALETTE * SECTOR:(CARD_UI_PALETTE + 4) * SECTOR]

    def texel(u, v):
        byte = page[(v & 0xFF) * 128 + (u & 0xFF) // 2]
        return (byte >> 4) if u & 1 else (byte & 15)

    def colour(x, y):
        return struct.unpack_from("<H", palette, ((y - 240) * 256 + (x - 256)) * 2)[0]

    def cut(u, v, w, h, cx, cy):
        pixels = bytearray(w * h * 4)
        for j in range(h):
            for i in range(w):
                index = texel(u + i, v + j)
                if index:
                    pixels[(j * w + i) * 4:(j * w + i) * 4 + 4] = rgba(colour(cx + index, cy))
        return bytes(pixels)

    def opaque_box(u0, v0, u1, v1):
        points = [(u, v) for v in range(v0, v1) for u in range(u0, u1) if texel(u, v)]
        xs, ys = [p[0] for p in points], [p[1] for p in points]
        return min(xs), min(ys), max(xs) + 1, max(ys) + 1

    layout, written = {}, 0

    def cut_ink(u, v, w, h, cx, cy):
        """A card view ink (CLUT row 248 or 249): a semi-transparent entry (bit 15 set) is alpha 128, the ink the card view subtracts
        from the frame (the name plate's ramp); an opaque entry is alpha 255 and is laid over it. Pieces with no ink are as cut()."""
        pixels = bytearray(w * h * 4)
        for j in range(h):
            for i in range(w):
                index = texel(u + i, v + j)
                if index:
                    value = colour(cx + index, cy)
                    pixels[(j * w + i) * 4:(j * w + i) * 4 + 4] = bytes(rgba(value)[:3]) + bytes([128 if value & 0x8000 else 255])
        return bytes(pixels)

    def piece(name, data, w, h, u, v, cx, cy, ox=0, oy=0):
        nonlocal written
        written += bool(write_output(output / "card_ui" / f"{name}.png", png(w, h, data), output))
        layout[name] = {"file": f"{name}.png", "w": w, "h": h, "page": 0x1F, "u": u, "v": v, "clut": [cx, cy], "x": ox, "y": oy,
                        "ink": 128 in data[3::4]}

    names = ("light", "dark", "earth", "water", "fire", "wind", "spell", "trap")
    for index, name in enumerate(names):
        piece(f"attribute_{name}", cut(16 * index, 0, 16, 16, 256 + 16 * index, 255), 16, 16, 16 * index, 0, 256 + 16 * index, 255)
    for d in range(10):
        piece(f"digit_{d}", cut_ink(16 + 6 * d, 16, 6, 13, 496, 248), 6, 13, 16 + 6 * d, 16, 496, 248)
    for d in range(10):
        piece(f"digit_dim_{d}", cut_ink(16 + 6 * d, 16, 6, 13, 496, 249), 6, 13, 16 + 6 * d, 16, 496, 249)
    piece("level_star", cut_ink(0, 16, 9, 9, 448, 248), 9, 9, 0, 16, 448, 248)
    # the labels: each window holds one label, cut to its opaque box (the offset is where the box sits in the window)
    windows = {"label_normal_magic": (0, 33, 64, 44), "label_trap": (0, 49, 64, 59), "label_equip_magic": (0, 65, 64, 75),
               "label_atk": (0, 80, 40, 87), "label_def": (0, 96, 40, 103)}
    for name, (u0, v0, u1, v1) in windows.items():
        x0, y0, x1, y1 = opaque_box(u0, v0, u1, v1)
        piece(name, cut_ink(x0, y0, x1 - x0, y1 - y0, 480, 248), x1 - x0, y1 - y0, x0, y0, 480, 248, x0 - u0, y0 - v0)
    # the card-kind icons (monster, magic, trap, ritual): one 16 x 16 cell at (0, 200) of VRAM page 11 (the boot UI), coloured per kind by the
    # CLUT at x 608 + 16 * kind on row 252 of the boot palette (the card-kind sprite's palette word 0x260 + 0x10 a kind, row 0xFC)
    boot = Vram()
    boot.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * SECTOR], 640, 0)
    boot.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    for kind, name in enumerate(("monster", "magic", "trap", "ritual")):
        clut_x = 608 + 16 * kind
        pixels = bytearray(16 * 16 * 4)
        for j in range(16):
            for i in range(16):
                index = boot.texel4(704, 0, i, 200 + j)
                if index:
                    pixels[(j * 16 + i) * 4:(j * 16 + i) * 4 + 4] = rgba(boot.colour(clut_x, 252, index))
        written += bool(write_output(output / "card_ui" / f"card_type_{name}.png", png(16, 16, bytes(pixels)), output))
        layout[f"card_type_{name}"] = {"file": f"card_type_{name}.png", "w": 16, "h": 16, "page": 11, "u": 0, "v": 200,
                                       "clut": [clut_x, 252], "x": 0, "y": 0}
    written += bool(write_output(output / "card_ui" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


DUEL_LIFE_POINT_ORIGIN = (280, 32)   # the duel screen's life-point object: its origin (the readout digits sit at offsets from it)
DUEL_LIFE_POINT_CLUT = 0x2E0         # its CLUT x (the phase setup writes 0x2E0, plus 16 when the sides are flipped); CLUT row 252


def bake_duel_hud(wa: bytes, exe: bytes, output: Path) -> int:
    """The duel screen's life-point panel (the object the duel init configures at (280, 32) with resource (4, side, 0) of the
    resident display bank at 0x801AC000): its one part is cut from the boot UI image on VRAM page 11 at (128, 128), 64 x 40 texels,
    drawn in CLUT row 252 at x 736. It shows the LP and COM (or YOU) labels and the boxes the readout digits sit in. Written as
    duel_hud/life_point_panel.png (CLUT x 736) and duel_hud/life_point_panel_flipped.png (CLUT x 752, the two-player flip); layout.json
    gives each one's offset from the object's origin, which the readout digits are measured from.

    The two-player duel's panel is the same object with resource (4, 1, 0) (the setup's side is the opponent's sign: a second person
    is side 1): its labels read 2P and 1P, not COM and YOU. It is written as duel_hud/life_point_panel_2p.png and its flipped copy."""
    import json
    vram = Vram()
    vram.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * SECTOR], 640, 0)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    tail = exe[0x801AC000 - LOAD + HEADER:0x801AC000 - LOAD + HEADER + 0x10000]
    margin, size = 128, 256
    layout, written = {}, 0
    variants = (("life_point_panel", 0, DUEL_LIFE_POINT_CLUT), ("life_point_panel_flipped", 0, DUEL_LIFE_POINT_CLUT + 16),
                ("life_point_panel_2p", 1, DUEL_LIFE_POINT_CLUT), ("life_point_panel_2p_flipped", 1, DUEL_LIFE_POINT_CLUT + 16))
    for name, side, clut_x in variants:
        canvas = bytearray(size * size * 4)
        draw_object(vram, tail, resolve_stream(tail, 4, side, 0), 0, 0, 11, clut_x, 252, False, canvas, margin, size, size, cell_offset=False)
        cut = cropped(bytes(canvas), size, size, margin)
        if cut is None:
            continue
        data, ox, oy = cut
        written += bool(write_output(output / "duel_hud" / f"{name}.png", data, output))
        layout[name] = {"file": f"{name}.png", "origin": list(DUEL_LIFE_POINT_ORIGIN), "x": ox, "y": oy}
    written += bool(write_output(output / "duel_hud" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


DUEL_CURSOR_PAGE = 31                   # the zone cursor's VRAM page (x 960, y 256): column 3 of the terrain package's phase 0 at (768, 256)
DUEL_CURSOR_CLUT = (256, 240)           # its palette row, uploaded from the package's phases 1 and 2


# The duel's information band (the stone frame under the hand, with the dark bar inside it). Its pieces are static sprites of the duel
# screen, drawn from VRAM page 31 (x 960, y 256: column 3 of the terrain package's phase 0) with CLUT row 240 (x 256). The geometry is
# the draw list of the reference build's duel frame (the primitive trace): two textured quads and two textured rectangles, each as
# (x, y, w, h, u, v) for a rectangle or the four corner points and their texels for a quad (the two quads are mirrored in u).
DUEL_BAND_PAGE = (960, 256)
DUEL_BAND_CLUT = (256, 240)
DUEL_BAND_RECTS = [(0, 174, 128, 64, 0, 0), (128, 174, 64, 64, 0, 64), (0, 238, 128, 8, 128, 56), (128, 238, 64, 8, 176, 0)]
DUEL_BAND_QUADS = [
    [(192, 174), (320, 174), (192, 238), (320, 238)],   # the band's upper part: texels (127,0) (0,0) (127,64) (0,64) at the corners
    [(192, 238), (320, 238), (192, 246), (320, 246)],   # the band's foot: texels (255,56) (127,56) (255,64) (127,64)
]
DUEL_BAND_QUAD_UV = [[(127, 0), (0, 0), (127, 64), (0, 64)], [(255, 56), (127, 56), (255, 64), (127, 64)]]


def bake_duel_numbers(wa: bytes, exe: bytes, output: Path) -> int:
    """The duel's numbered cards and the green choice arrows, from the reference's draw list of the 2P duel (prim_A.txt): the numbered
    card (the hand's plain frame: 52 x 60 at texel (0, 192) of VRAM page 30, 8 bits a texel, CLUT row 241 at x 256); the card number's
    digits (12 x 16 cells at texel (12 d, 112) of the same page, d = 0 to 9); and the right arrow (16 x 16 at texel (96, 160) of VRAM
    page 11 (x 704), 4 bits a texel, CLUT (544, 252)), with the left arrow its mirror. The number is drawn 15 and 27 pixels right of
    the card's left edge and 15 below its top. Written as duel_card/numbered.png, duel_card/digit_<d>.png (12 x 16),
    duel_card/arrow_right.png and duel_card/arrow_left.png."""
    vram = Vram()
    base = (0x16C6 + CARD_FACE_TERRAIN * DUEL_TERRAIN_SECTORS) * SECTOR
    package = wa[base:base + DUEL_TERRAIN_SECTORS * SECTOR]
    vram.upload_tiles(package[0:64 * SECTOR], 768, 256)
    vram.upload_rect(package[64 * SECTOR:68 * SECTOR], 256, 240, 256, 16)
    vram.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * SECTOR], 640, 0)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)

    def cut8(u, v, w, h, clut_x, clut_y):
        out = bytearray(w * h * 4)
        for j in range(h):
            for i in range(w):
                word = vram.words[(256 + v + j) * 1024 + 896 + ((u + i) >> 1)]
                index = (word >> (((u + i) & 1) * 8)) & 255
                if index:
                    colour = vram.colour(clut_x, clut_y, index)
                    if colour:
                        out[(j * w + i) * 4:(j * w + i) * 4 + 4] = rgba(colour)
        return bytes(out)

    def cut4(u, v, w, h, clut_x, clut_y, page_x, page_y):
        out = bytearray(w * h * 4)
        for j in range(h):
            for i in range(w):
                index = vram.texel4(page_x, page_y, u + i, v + j)
                colour = vram.colour(clut_x, clut_y, index) if index else 0
                if colour:
                    out[(j * w + i) * 4:(j * w + i) * 4 + 4] = rgba(colour)
        return bytes(out)

    written = bool(write_output(output / "duel_card" / "numbered.png", png(52, 60, cut8(0, 192, 52, 60, 256, 241)), output))
    for d in range(10):
        written += bool(write_output(output / "duel_card" / f"digit_{d}_12.png", png(12, 16, cut8(12 * d, 112, 12, 16, 256, 241)), output))
    arrow = cut4(96, 160, 16, 16, 544, 252, 704, 0)
    written += bool(write_output(output / "duel_card" / "arrow_right.png", png(16, 16, arrow), output))
    mirrored = bytearray(len(arrow))
    for j in range(16):
        for i in range(16):
            mirrored[(j * 16 + i) * 4:(j * 16 + i) * 4 + 4] = arrow[(j * 16 + (15 - i)) * 4:(j * 16 + (15 - i)) * 4 + 4]
    written += bool(write_output(output / "duel_card" / "arrow_left.png", png(16, 16, bytes(mirrored)), output))
    # the hand pointer, as the reference draws it in the destination state (one 16 x 16 quad on the same page and palette, uv 15 to 31 at
    # rows 144 to 160, mirrored: its tip points into the card). Unmirrored cell written; the scene flips it.
    written += bool(write_output(output / "duel_hand" / "pointer.png", png(16, 16, cut4(15, 144, 16, 16, 544, 252, 704, 0)), output))
    return written


def bake_duel_bar_icons(wa: bytes, output: Path) -> int:
    """The card bar's stat marks and digits (the text channel's icon and 8 x 8 font entries): the
    sword at page 11 (0xD0, 0x58), the shield at (0xD8, 0x58) and the digits at (0x80 + 8d, 0x70), all 8 x 8, 4 bits a texel, CLUT
    (656, 250). The race and guardian star icons are race_icons/ and star_icons/ (the same cells). Written as duel_bar/label_sword.png,
    duel_bar/label_shield.png and duel_bar/digit_<d>.png."""
    vram = _icon_vram(wa)
    cells = {"label_sword": (0xD0, 0x58), "label_shield": (0xD8, 0x58)}
    for d in range(10):
        cells[f"digit_{d}"] = (0x80 + 8 * d, 0x70)
    written = 0
    for name, (u, v) in cells.items():
        out = bytearray(8 * 8 * 4)
        for j in range(8):
            for i in range(8):
                index = vram.texel4(STAR_ICON_PAGE * 64, 0, u + i, v + j)
                colour = vram.colour(656, 250, index) if index else 0
                if colour:
                    out[(j * 8 + i) * 4:(j * 8 + i) * 4 + 4] = rgba(colour)
        written += bool(write_output(output / "duel_bar" / f"{name}.png", png(8, 8, bytes(out)), output))
    return written


def bake_duel_band(wa: bytes, exe: bytes, output: Path) -> int:
    """The duel's information band as a 256 x 256 texture page (4 bits a texel, CLUT row 240): duel_frame/band_page.png, and
    duel_frame/band.json with the band's pieces (rectangles and quads with their texel corners), in screen units (320 x 240)."""
    import json
    vram = Vram()
    base = (0x16C6 + CARD_FACE_TERRAIN * DUEL_TERRAIN_SECTORS) * SECTOR
    package = wa[base:base + DUEL_TERRAIN_SECTORS * SECTOR]
    vram.upload_tiles(package[0:64 * SECTOR], 768, 256)                      # pages 28 to 31 at y 256
    vram.upload_rect(package[64 * SECTOR:68 * SECTOR], 256, 240, 256, 16)    # the palette rows
    canvas = bytearray(256 * 256 * 4)
    for v in range(256):
        for u in range(256):
            index = vram.texel4(DUEL_BAND_PAGE[0], DUEL_BAND_PAGE[1], u, v)
            colour = vram.colour(DUEL_BAND_CLUT[0], DUEL_BAND_CLUT[1], index) if index else 0
            if colour:
                canvas[(v * 256 + u) * 4:(v * 256 + u) * 4 + 4] = rgba(colour)
    written = bool(write_output(output / "duel_frame" / "band_page.png", png(256, 256, bytes(canvas)), output))
    layout = {"rects": [{"x": r[0], "y": r[1], "w": r[2], "h": r[3], "u": r[4], "v": r[5]} for r in DUEL_BAND_RECTS],
              "quads": [{"corners": [list(c) for c in q], "uv": [list(t) for t in uv]} for q, uv in zip(DUEL_BAND_QUADS, DUEL_BAND_QUAD_UV)],
              "page": list(DUEL_BAND_PAGE), "clut": list(DUEL_BAND_CLUT), "units": "screen (320 x 240); the texture is the page's own texels"}
    written += bool(write_output(output / "duel_frame" / "band.json", json.dumps(layout, indent=1) + "\n", output))
    return written


def bake_duel_cursors(wa: bytes, exe: bytes, output: Path) -> int:
    """The duel's three cursors, cut from the resident duel bank and the pictures the duel loads:
    - the zone cursor the board draws over a monster or magic and trap zone: resource (4, 3, k) of the bank on page 31, CLUT (256, 240),
      with the texture cell offset, where k is the cursor's table index plus 4 for the foe (the player's is 0 to 3). Its origin is
      placed 32 pixels left and 30 up from the zone's point. Frames are duel_field/zone_cursor_<k>_<n>.png, and
      duel_field/zone_cursor.json holds each k's frames, offsets and play order, and the origin offset.
    - the hand pointer: the red triangle, resource (1, 5, 28) of the bank on page 11, CLUT (512, 252) with the cell offset, which gives 544 (eight
      16 x 16 frames, each held four ticks). Its origin is the hand slot's (14 + 60 i, 194), and the frame's own offset puts the
      arrow at the card's right edge. Frames are duel_hand/hand_pointer_<n>.png.
    - the order badges: a 16 x 16 cell of page 11, CLUT (592, 252), at texels (16 (n - 1), 184) for pick n (1 to 5), placed at the marked
      card's place. duel_hand/badge_<n>.png; duel_hand/layout.json holds the pointer's and the badges' offsets."""
    import json
    base = (0x16C6 + CARD_FACE_TERRAIN * DUEL_TERRAIN_SECTORS) * SECTOR
    package = wa[base:base + DUEL_TERRAIN_SECTORS * SECTOR]
    vram = Vram()
    vram.upload_tiles(package[0:64 * SECTOR], 768, 256)                      # pages 28 to 31 at y 256 (page 31 is the cursor's)
    vram.upload_rect(package[64 * SECTOR:68 * SECTOR], 256, 240, 256, 16)    # the palette rows the cursor's CLUT reads
    vram.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * SECTOR], 640, 0)             # pages 10 to 12 at y 0 (page 11 is the hand's)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    tail = exe[0x801AC000 - LOAD + HEADER:0x801AC000 - LOAD + HEADER + 0x10000]
    written, cursor = 0, {"page": DUEL_CURSOR_PAGE, "clut": list(DUEL_CURSOR_CLUT), "origin_offset": [32, 30], "streams": {}}
    for k in range(8):
        entry = bake_stream_frames(vram, tail, (4, 3, k), output, f"zone_cursor_{k}", DUEL_CURSOR_PAGE, *DUEL_CURSOR_CLUT, True, folder="duel_field")
        cursor["streams"][str(k)] = entry
        written += sum(bool(frame.get("file")) for frame in entry["frames"])
    written += bool(write_output(output / "duel_field" / "zone_cursor.json", json.dumps(cursor, indent=1) + "\n", output))
    layout = {"pointer": bake_stream_frames(vram, tail, (1, 5, 28), output, "hand_pointer", 11, 512, 252, True, folder="duel_hand")}   # the cell offset of 2 takes it to CLUT x 544
    written += sum(bool(frame.get("file")) for frame in layout["pointer"]["frames"])
    layout["badges"] = []
    for n in range(1, 6):
        canvas = bytearray(16 * 16 * 4)
        for j in range(16):
            for i in range(16):
                index = vram.texel4(704, 0, 16 * (n - 1) + i, 184 + j)     # the count is read before its increment: pick 1 is the first cell
                colour = vram.colour(592, 252, index)
                if colour:
                    canvas[(j * 16 + i) * 4:(j * 16 + i) * 4 + 4] = rgba(colour)
        written += bool(write_output(output / "duel_hand" / f"badge_{n}.png", png(16, 16, bytes(canvas)), output))
        layout["badges"].append({"file": f"badge_{n}.png", "x": 0, "y": 0})
    written += bool(write_output(output / "duel_hand" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


DUEL_FX_BANK = 0x80146000                  # the duel effects overlay's bank: terrain package phase 7 (44 sectors at relative 140), the same in all seven
DUEL_FX_BANK_SECTOR, DUEL_FX_BANK_BYTES = 140, 0x16000
DUEL_FX_IMAGES, DUEL_FX_MODES, DUEL_FX_DIGITS = 0x8015A270, 0x8015A4BC, 0x8015A5A0   # 21 GsIMAGE records (28 bytes), 21 u16 modes, 12 digit RECTs


def duel_fx_word(pmode: int, px: int, py: int, cx: int, cy: int, mode: int) -> tuple:
    """The texture page and CLUT words the effect programs build from an image record (the dispatcher's texture-word conversion):
    page = colour depth (pmode & 3) << 7 | mode << 5 (the semi-transparency mode) | the page's Y bit 4 | X (px / 64) | Y bit 9 << 2,
    CLUT = cy << 6 | cx / 16."""
    word0 = ((pmode & 3) << 7) | ((mode & 3) << 5) | (((py & 0x100) >> 8) << 4) | ((px & 0x3FF) >> 6) | (((py & 0x200) >> 9) << 11)
    word1 = (cy << 6) | ((cx >> 4) & 0x3F)
    return word0, word1


def duel_fx_page(vram: "Vram", word0: int, word1: int) -> bytes:
    """One duel effect texture page (256 rows, as wide as its colour depth allows) from a page word and a CLUT word, decoded the way
    bake_duel_effect_textures decodes the 21 pairs: colour 0 is transparent; a texel with the CLUT's semi-transparency bit has alpha 128."""
    depth = [4, 8, 16, 24][(word0 >> 7) & 3]
    width = {4: 256, 8: 128, 16: 64}.get(depth, 64)
    per_word = {4: 4, 8: 2}.get(depth, 1)
    page_x = (word0 & 0xF) * 64
    page_y = ((word0 >> 4) & 1) * 256 + ((word0 >> 11) & 1) * 512
    clut_x, clut_y = (word1 & 0x3F) * 16, word1 >> 6
    canvas = bytearray(width * 256 * 4)
    for v in range(256):
        for u in range(width):
            word = vram.words[(page_y + v) * 1024 + page_x + u // per_word]
            if depth == 16:
                colour = word
            else:
                shift = (u % per_word) * (16 // per_word)
                index = (word >> shift) & ((1 << (16 // per_word)) - 1)
                colour = vram.words[clut_y * 1024 + clut_x + index]
            if colour == 0:
                continue
            alpha = 128 if colour & 0x8000 else 255
            canvas[(v * width + u) * 4:(v * width + u) * 4 + 4] = rgba(colour & 0x7FFF)[:3] + bytes((alpha,))
    return png(width, 256, bytes(canvas))


def bake_duel_effect_extra_pages(wa: bytes, bank: bytes, output: Path) -> int:
    """The texture pages the ported effect programs (8 to 16) read that are not among the 21 pairs (written as duel_fx/pair_NN.png
    with NN from 21 on, from terrain 0's VRAM; the pages are the same in every terrain):
    - pair_21: effect 14's sprite sheet: the boot UI image's page 11 (VRAM x 704, y 0; 4 bits) with the CLUT at (640, 250). Its sprites
      are 16 x 16 cells at u 128 + 16 * (phase % 8), v 48 + 16 * (phase / 8) (the program's tpage 0x2B and CLUT 0x3EA8).
    - pair_22: effect 10's page 12: its own image record's page (the program swaps the page word for the mode) with the CLUT of pair 12.
    - pair_23: effect 13's layer page: its own image record's page with the CLUT of pair 0.
    - pair_24 to pair_28: effect 11's variant images k = 0..4: the page word is fixed at (896, 256) with the image's depth, and the CLUT is
      the image's; the programs' coordinates are the image's px and py (pair_24 also serves as the base texture)."""
    at = lambda address: address - DUEL_FX_BANK
    base = 0x16C6 * SECTOR
    package = wa[base:base + DUEL_TERRAIN_SECTORS * SECTOR]
    vram = Vram()
    vram.upload_tiles(package[0:64 * SECTOR], 768, 256)                  # phase 0
    vram.upload_rect(package[64 * SECTOR:68 * SECTOR], 256, 240, 256, 16)  # phase 1: the palette rows
    vram.upload_rect(package[106 * SECTOR:108 * SECTOR], 0, 240, 256, 8)   # phase 5: the palette rows
    vram.upload_tiles(package[108 * SECTOR:140 * SECTOR], 512, 256)      # phase 6
    vram.upload_tiles(package[190 * SECTOR:198 * SECTOR], 832, 0)        # phase 10
    vram.upload_tiles(package[203 * SECTOR:235 * SECTOR], 640, 256)      # phase 12
    image = lambda address: struct.unpack_from("<IhhHHIhhHHI", bank, at(address))   # pmode, px, py, pw, ph, pixels, cx, cy, cw, ch, clut
    written = 0

    def store(index: int, data: bytes) -> int:
        return bool(write_output(output / "duel_fx" / f"pair_{index:02d}.png", data, output))

    gather = _icon_vram(wa)
    written += store(21, duel_fx_page(gather, 0x2B, 0x3EA8))
    pm10, px10, py10 = image(0x8015A994 + 12 * 28)[:3]
    _, _, _, _, _, _, cx12, cy12, _, _, _ = image(0x8015A270 + 12 * 28)
    written += store(22, duel_fx_page(vram, duel_fx_word(pm10, px10, py10, cx12, cy12, 1)[0], duel_fx_word(pm10, px10, py10, cx12, cy12, 1)[1]))
    pm13, px13, py13, _, _, _, cx13, cy13, _, _, _ = image(0x8015AD14)
    pm0, px0, py0, _, _, _, cx0, cy0, _, _, _ = image(0x8015A270)
    written += store(23, duel_fx_page(vram, duel_fx_word(pm13, px13, py13, cx13, cy13, 1)[0], duel_fx_word(pm0, px0, py0, cx0, cy0, 1)[1]))
    for k in range(5):
        pmode, _, _, _, _, _, cx, cy, _, _, _ = image(0x8015A4E4 + 28 * k)
        written += store(24 + k, duel_fx_page(vram, ((pmode & 3) << 7) | 0x3E, (cy << 6) | ((cx >> 4) & 0x3F)))
    return written


def bake_duel_effect_textures(wa: bytes, output: Path) -> int:
    """The duel effects' texture pages, for each terrain: the 21 texture pairs the effect programs read (the dispatcher converts the
    image records of the overlay bank into a page and CLUT word each). The page each pair names is decoded from the VRAM the terrain
    package uploads (phase 0 to x 768, phase 6 to x 512, phase 12 to x 640 at y 256, phase 10 to x 832 at y 0, the palette rows at
    y 240 from phases 1 and 5), as one 256 rows tall page of its colour depth (4 bits: 256 texels wide, 8 bits: 128, 16 bits: 64).
    Each texel is RGBA: colour 0 is transparent (alpha 0), a texel with the CLUT's semi-transparency bit is alpha 128, others 255.
    Written as screens/duel_fx/pair_<i>.png (the same in every terrain; a terrain whose page differs gets terrain_<n>/pair_<i>.png),
    and screens/duel_fx/layout.json holds each pair's page and CLUT words, its depth and default mode, and the 12 digit RECTs
    (x, y, w, h) the number renderer cuts from the digit atlas."""
    import json
    bank = wa[(0x16C6 + DUEL_FX_BANK_SECTOR) * SECTOR:][:DUEL_FX_BANK_BYTES]     # the terrain 0 copy (the bank is the same in all seven)
    at = lambda address: address - DUEL_FX_BANK
    pairs = []
    for i in range(21):
        pmode, px, py, pw, ph, _pixels, cx, cy, cw, ch, _clut = struct.unpack_from("<IhhHHIhhHHI", bank, at(DUEL_FX_IMAGES + i * 28))
        pairs.append((pmode, px, py, cx, cy))
    modes = list(struct.unpack_from("<21H", bank, at(DUEL_FX_MODES)))
    digits = [list(struct.unpack_from("<4h", bank, at(DUEL_FX_DIGITS + 8 * k))) for k in range(12)]
    layout = {"pairs": [], "digits": digits}
    written, first = 0, {}
    for i, (pmode, px, py, cx, cy) in enumerate(pairs):
        word0, word1 = duel_fx_word(pmode, px, py, cx, cy, modes[i])
        depth = [4, 8, 16, 24][(word0 >> 7) & 3]
        layout["pairs"].append({"file": f"pair_{i:02d}.png", "tpage": word0, "clut": word1, "depth": depth, "mode": modes[i] & 3})
    for terrain in range(DUEL_TERRAIN_COUNT):
        base = (0x16C6 * SECTOR) + terrain * DUEL_TERRAIN_SECTORS * SECTOR          # the duel blob: 235 sectors per terrain from WA sector 0x16C6
        package = wa[base:base + DUEL_TERRAIN_SECTORS * SECTOR]
        vram = Vram()
        vram.upload_tiles(package[0:64 * SECTOR], 768, 256)                  # phase 0
        vram.upload_rect(package[64 * SECTOR:68 * SECTOR], 256, 240, 256, 16)  # phase 1: the palette rows
        vram.upload_rect(package[106 * SECTOR:108 * SECTOR], 0, 240, 256, 8)   # phase 5: the palette rows
        vram.upload_tiles(package[108 * SECTOR:140 * SECTOR], 512, 256)      # phase 6
        vram.upload_tiles(package[190 * SECTOR:198 * SECTOR], 832, 0)        # phase 10
        vram.upload_tiles(package[203 * SECTOR:235 * SECTOR], 640, 256)      # phase 12
        for i, (pmode, px, py, cx, cy) in enumerate(pairs):
            word0, word1 = layout["pairs"][i]["tpage"], layout["pairs"][i]["clut"]
            depth = layout["pairs"][i]["depth"]
            width = {4: 256, 8: 128, 16: 64}.get(depth, 64)
            per_word = {4: 4, 8: 2}.get(depth, 1)
            page_x = (word0 & 0xF) * 64
            page_y = ((word0 >> 4) & 1) * 256 + ((word0 >> 11) & 1) * 512
            clut_x, clut_y = (word1 & 0x3F) * 16, word1 >> 6
            canvas = bytearray(width * 256 * 4)
            for v in range(256):
                for u in range(width):
                    word = vram.words[(page_y + v) * 1024 + page_x + u // per_word]
                    if depth == 16:
                        colour = word
                    else:
                        shift = (u % per_word) * (16 // per_word)
                        index = (word >> shift) & ((1 << (16 // per_word)) - 1)
                        colour = vram.words[clut_y * 1024 + clut_x + index]
                    if colour == 0:
                        continue
                    alpha = 128 if colour & 0x8000 else 255
                    canvas[(v * width + u) * 4:(v * width + u) * 4 + 4] = rgba(colour & 0x7FFF)[:3] + bytes((alpha,))
            data = png(width, 256, bytes(canvas))
            if terrain == 0:
                first[i] = data
                written += bool(write_output(output / "duel_fx" / f"pair_{i:02d}.png", data, output))
            elif first.get(i) != data:
                # the pages are identical in all seven terrains (checked when this was written); a differing one gets its own copy
                written += bool(write_output(output / "duel_fx" / f"terrain_{terrain}" / f"pair_{i:02d}.png", data, output))
    written += bool(write_output(output / "duel_fx" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    # the configuration tables the ported programs read (all in the bank): effect 2's seven 50-byte records, and the vectors
    # the programs start their scale from (effects 2 and 19). Field offsets follow the record layout in the overlay's headers.
    # The start vectors are at their guest addresses (the overlay's symbol map: the names the code was read under are not the
    # addresses). Read at the names' addresses instead, they held (4096, 0, 4096): the zero y was this read, not the game's data.
    vectors = {"2": 0x80146200, "19": 0x80146210, "0": 0x80146230, "1": 0x80146250, "4": 0x80146290, "5": 0x80146260, "6": 0x80146240, "7": 0x80146270}
    configs = {"effect_2": [], "scale": {key: list(struct.unpack_from("<3i", bank, at(address))) for key, address in vectors.items()}}
    for k in range(7):
        r = bank[at(0x8015AFE4) + 50 * k:][:50]
        configs["effect_2"].append({
            "color": list(r[0:3]), "number_red": list(r[3:5]), "number_green": list(r[5:7]), "number_blue": list(r[7:9]),
            "sprite_size": struct.unpack_from("<H", r, 10)[0], "radii": list(struct.unpack_from("<3H", r, 12)),
            "heights": list(struct.unpack_from("<4h", r, 18)), "widths": list(struct.unpack_from("<5h", r, 26)),
            "particle_speed": struct.unpack_from("<H", r, 36)[0], "particle_count": struct.unpack_from("<H", r, 38)[0],
            "variant": struct.unpack_from("<H", r, 40)[0], "strip_widths": list(struct.unpack_from("<2H", r, 42)),
            "strip_height": struct.unpack_from("<H", r, 46)[0], "field_30": struct.unpack_from("<H", r, 48)[0]})
    # the tables of the ported programs 17, 18, 21 and 22 (struct layouts from their headers: 16, 30, 8 and 26 bytes a record), and the
    # start vectors of 17, 18, 21, 22, 23 and 24 (VECTORs, three int32 each)
    for k in range(2):
        r = bank[at(0x8015B7A8) + 16 * k:][:16]
        configs.setdefault("effect_17", []).append({
            "color": list(r[0:3]), "burst_color": list(r[3:6]), "radius": struct.unpack_from("<H", r, 6)[0],
            "spin": struct.unpack_from("<H", r, 8)[0], "height": struct.unpack_from("<H", r, 10)[0],
            "fan_spin": struct.unpack_from("<H", r, 12)[0], "mode": struct.unpack_from("<H", r, 14)[0]})
        r = bank[at(0x8015B144) + 30 * k:][:30]
        configs.setdefault("effect_18", []).append({
            "color": list(r[0:3]), "sprite_size": struct.unpack_from("<H", r, 4)[0], "radii": list(struct.unpack_from("<3H", r, 6)),
            "widths": list(struct.unpack_from("<2H", r, 12)), "height": struct.unpack_from("<H", r, 16)[0],
            "particle_speed": struct.unpack_from("<H", r, 18)[0], "outer_radii": list(struct.unpack_from("<3H", r, 20)),
            "variant": struct.unpack_from("<H", r, 26)[0], "delay": struct.unpack_from("<H", r, 28)[0]})
    for k in range(24):
        r = bank[at(0x8015A724) + 26 * k:][:26]
        configs.setdefault("effect_22", []).append({
            "color": list(r[0:3]), "fan_color": list(r[3:6]), "point_size": struct.unpack_from("<H", r, 6)[0],
            "spread": struct.unpack_from("<H", r, 8)[0], "inner_widths": list(struct.unpack_from("<2H", r, 10)),
            "inner_height": struct.unpack_from("<H", r, 14)[0], "outer_widths": list(struct.unpack_from("<2H", r, 16)),
            "outer_height": struct.unpack_from("<H", r, 20)[0], "duration": struct.unpack_from("<H", r, 22)[0]})
    # effect 21's slot positions: ten SVECTORs for each of the two parities (8 bytes each: three s16 and a pad)
    configs["effect_21"] = [[list(struct.unpack_from("<3h", bank, at(0x8015AC34) + 8 * (2 * i + p))) for p in range(2)] for i in range(10)]
    configs["scale"].update({str(id_): list(struct.unpack_from("<3i", bank, at(address)))
        for id_, address in ((17, 0x801462A0), (18, 0x80146220), (21, 0x801461A0), (22, 0x8014608C), (23, 0x801461F0), (24, 0x80146190))})
    # the other ported programs' tables (guest addresses; the record sizes are the C structs', with their alignment)
    def records(address: int, count: int, size: int, decode) -> list:
        return [decode(bank[at(address) + size * k:][:size]) for k in range(count)]
    # effect 3's two 8-byte descriptors (size, delay, frames, texture: u16 each; at 0x8015A714)
    configs["effect_3"] = records(0x8015A714, 2, 8, lambda r: {
        "size": struct.unpack_from("<H", r, 0)[0], "delay": struct.unpack_from("<H", r, 2)[0],
        "frames": struct.unpack_from("<H", r, 4)[0], "texture": struct.unpack_from("<H", r, 6)[0]})
    configs["effect_0"] = records(0x8015B180, 30, 20, lambda r: {
        "color": list(r[0:3]), "sprite_size": struct.unpack_from("<H", r, 4)[0], "radii": list(struct.unpack_from("<3H", r, 6)),
        "widths": list(struct.unpack_from("<2H", r, 12)), "height": struct.unpack_from("<H", r, 16)[0], "delay": struct.unpack_from("<H", r, 18)[0]})
    configs["effect_1"] = records(0x8015B48C, 2, 24, lambda r: {
        "color": list(r[0:3]), "initial_rotation_step": struct.unpack_from("<H", r, 4)[0], "rotation_acceleration": struct.unpack_from("<H", r, 6)[0],
        "beam_rotation_step": struct.unpack_from("<H", r, 8)[0], "particle_speed": struct.unpack_from("<H", r, 10)[0],
        "sprite_size": struct.unpack_from("<H", r, 12)[0], "widths": list(struct.unpack_from("<2H", r, 14)),
        "height": struct.unpack_from("<H", r, 18)[0], "first_end": struct.unpack_from("<H", r, 20)[0], "second_end": struct.unpack_from("<H", r, 22)[0]})
    configs["effect_4"] = records(0x8015B770, 2, 28, lambda r: {
        "color": list(r[0:3]), "sprite_size": struct.unpack_from("<H", r, 4)[0], "radii": list(struct.unpack_from("<3H", r, 6)),
        "widths": list(struct.unpack_from("<2H", r, 12)), "height": struct.unpack_from("<H", r, 16)[0],
        "card_height": struct.unpack_from("<H", r, 18)[0], "card_width": struct.unpack_from("<H", r, 20)[0],
        "texture": struct.unpack_from("<H", r, 22)[0], "particle_speed": struct.unpack_from("<H", r, 24)[0], "duration": struct.unpack_from("<H", r, 26)[0]})
    configs["effect_5"] = records(0x8015B4BC, 10, 36, lambda r: {
        "color": list(r[0:3]), "number_color": list(r[3:6]), "rise_speed": struct.unpack_from("<H", r, 6)[0],
        "particle_speed": struct.unpack_from("<H", r, 8)[0], "strip_count": struct.unpack_from("<H", r, 10)[0],
        "widths": list(struct.unpack_from("<2H", r, 12)), "height": struct.unpack_from("<H", r, 16)[0], "radii": list(struct.unpack_from("<3H", r, 18)),
        "sprite_size": struct.unpack_from("<H", r, 24)[0], "bounce_speed": struct.unpack_from("<H", r, 26)[0],
        "number": struct.unpack_from("<i", r, 28)[0], "particle_count": struct.unpack_from("<H", r, 32)[0], "field_22": struct.unpack_from("<H", r, 34)[0]})
    configs["effect_6"] = records(0x8015B3D8, 6, 30, lambda r: {
        "color": list(r[0:3]), "column_color": list(r[3:6]), "count": struct.unpack_from("<H", r, 6)[0], "size": struct.unpack_from("<H", r, 8)[0],
        "duration": struct.unpack_from("<H", r, 10)[0], "target_y": struct.unpack_from("<h", r, 12)[0], "shrink": struct.unpack_from("<H", r, 14)[0],
        "radii": list(struct.unpack_from("<3H", r, 16)), "particle_speed": struct.unpack_from("<H", r, 22)[0],
        "particle_count": struct.unpack_from("<H", r, 24)[0], "particle_size": struct.unpack_from("<H", r, 26)[0], "column_value": struct.unpack_from("<h", r, 28)[0]})
    configs["effect_7"] = records(0x8015B624, 5, 30, lambda r: {
        "color": list(r[0:3]), "number_color": list(r[3:6]), "count": struct.unpack_from("<H", r, 6)[0], "size": struct.unpack_from("<H", r, 8)[0],
        "duration": struct.unpack_from("<H", r, 10)[0], "start_y": struct.unpack_from("<h", r, 12)[0], "growth": struct.unpack_from("<H", r, 14)[0],
        "radii": list(struct.unpack_from("<3H", r, 16)), "particle_speed": struct.unpack_from("<H", r, 22)[0],
        "particle_count": struct.unpack_from("<H", r, 24)[0], "particle_size": struct.unpack_from("<H", r, 26)[0], "number": struct.unpack_from("<h", r, 28)[0]})
    # effects 8 to 16 (the record layouts are the C structs' in their headers, with the alignment; field offsets below) and their
    # start vectors (the overlay's symbol addresses, as above)
    configs["scale"].update({str(id_): list(struct.unpack_from("<3i", bank, at(address)))
        for id_, address in ((8, 0x8014606C), (9, 0x80146280), (10, 0x80146180), (11, 0x80146004), (12, 0x801461D0),
                             (13, 0x801461C0), (14, 0x8014607C), (15, 0x801461B0), (16, 0x801461E0))})

    def fields(r: bytes, spec: list) -> dict:
        out = {}
        for name, code, offset, count in spec:
            values = struct.unpack_from("<%d%s" % (count, code), r, offset)
            out[name] = list(values) if count > 1 else values[0]
        return out

    EFFECT_8 = [("color", "B", 0, 3), ("initial_width", "H", 4, 1), ("width_step", "H", 6, 1), ("minimum_width", "H", 8, 1),
                ("initial_height", "H", 10, 1), ("height_step", "H", 12, 1), ("maximum_height", "H", 14, 1), ("sprite_size", "H", 16, 1),
                ("ray_count", "H", 18, 1), ("ray_range", "H", 20, 1), ("ray_width", "H", 22, 1), ("particle_speed", "H", 24, 1),
                ("particle_count", "H", 26, 1), ("draw_rings", "H", 28, 1), ("radii", "H", 30, 3), ("ring_height", "H", 36, 1)]
    EFFECT_9 = [("color", "B", 0, 3), ("number_color", "B", 3, 3), ("particle_speed", "H", 6, 1), ("rotation_count", "H", 8, 1),
                ("widths", "H", 10, 2), ("height", "H", 14, 1), ("radii", "H", 16, 3), ("sprite_size", "H", 22, 1),
                ("bounce_speed", "H", 24, 1), ("value", "i", 28, 1)]
    EFFECT_10 = [("color", "B", 0, 3), ("height_step", "H", 4, 1), ("maximum_height", "H", 6, 1), ("particle_speed", "H", 8, 1),
                 ("mode", "H", 10, 1)]
    EFFECT_11 = [("fragment_size", "H", 0, 1), ("speed", "H", 2, 1), ("lift", "H", 4, 1), ("chance", "H", 6, 1), ("spread", "H", 8, 1),
                 ("color", "B", 12, 3), ("ray_width", "H", 16, 1), ("ray_count", "H", 18, 1), ("ray_length", "H", 20, 1),
                 ("dust_count", "H", 22, 1), ("dust_speed", "H", 24, 1), ("glow_size", "H", 26, 1), ("width", "H", 28, 1),
                 ("shrink", "H", 30, 1), ("min_width", "H", 32, 1), ("height", "H", 34, 1), ("growth", "H", 36, 1),
                 ("max_height", "H", 38, 1), ("radii", "H", 40, 3), ("ring_height", "H", 46, 1)]
    EFFECT_12 = [("color", "B", 0, 3), ("radii", "H", 4, 3), ("ring_height", "H", 10, 1), ("sprite_size", "H", 12, 1),
                 ("particle_speed", "H", 14, 1)]
    EFFECT_13 = [("color", "B", 0, 3), ("number_color", "B", 3, 3), ("radius", "H", 6, 1), ("height", "H", 8, 1), ("size", "H", 10, 1),
                 ("particle_size", "H", 12, 1), ("blend", "H", 14, 1), ("background", "H", 16, 1), ("number", "h", 18, 1)]
    GATHER_14 = [("spread", "H", 0, 1), ("size", "H", 2, 1), ("frames", "H", 4, 1), ("ring_radius", "H", 6, 3), ("curve_size", "H", 12, 1),
                 ("widths", "H", 14, 2), ("height", "H", 18, 1)]
    EFFECT_15 = [("color", "B", 0, 3), ("selector", "i", 4, 1)]
    EFFECT_16 = [("color", "B", 0, 3), ("widths", "H", 4, 4), ("vertical_step", "H", 12, 1), ("spread", "H", 14, 1),
                 ("glow_sizes", "H", 16, 4), ("particle_spread", "H", 24, 1), ("line_width", "H", 26, 1), ("ring_radii", "H", 28, 3),
                 ("ring_height", "H", 34, 1)]
    configs["effect_8"] = records(0x8015A600, 6, 38, lambda r: fields(r, EFFECT_8))
    configs["effect_9"] = records(0x8015B6BC, 5, 36, lambda r: fields(r, EFFECT_9))
    configs["effect_10"] = records(0x8015ABE0, 6, 14, lambda r: fields(r, EFFECT_10))
    configs["effect_11"] = records(0x8015A570, 1, 48, lambda r: fields(r, EFFECT_11))
    configs["effect_12"] = records(0x8015AFB0, 1, 16, lambda r: fields(r, EFFECT_12))
    configs["effect_13"] = records(0x8015AF60, 4, 20, lambda r: fields(r, EFFECT_13))
    configs["effect_14"] = records(0x8015A6E4, 1, 20, lambda r: fields(r, GATHER_14))
    configs["effect_15"] = records(0x8015ACD4, 8, 8, lambda r: fields(r, EFFECT_15))
    configs["effect_16"] = records(0x8015AFC0, 1, 36, lambda r: fields(r, EFFECT_16))
    # effect 11's five variant images (the GsIMAGE records at 0x8015A4E4): the px and py the fragments' texel coordinates start from
    configs["effect_11_origins"] = [list(struct.unpack_from("<2h", bank, at(0x8015A4E4 + 28 * k) + 4)) for k in range(5)]
    written += bake_duel_effect_extra_pages(wa, bank, output)
    written += bool(write_output(output / "duel_fx" / "configs.json", json.dumps(configs, indent=1) + "\n", output))
    return written


STAR_ICON_PAGE = 11                       # the guardian star icon's texture page (sprites[1]'s tpage 0xB: VRAM x 704, y 0)


def _icon_canvas(vram: "Vram", c: int) -> bytes:
    """One 16 x 16 icon entry of the card text (a code c below 0x22, drawn from sprites[1]): the cell at u = ((c & 7) * 16 - 128) mod 256,
    v = (c & 0x38) * 2 of tpage 0xB, in its CLUT at (0x200 + (c & 15) * 16, 0xF9 + (c >> 4)). Index 0 is transparent."""
    u = ((c & 7) * 16 - 128) & 255
    v = (c & 0x38) * 2
    cx, cy = 0x200 + (c & 15) * 16, 0xF9 + (c >> 4)
    canvas = bytearray(16 * 16 * 4)
    for j in range(16):
        for i in range(16):
            index = vram.texel4(STAR_ICON_PAGE * 64, 0, u + i, v + j)
            colour = vram.colour(cx, cy, index) if index else 0
            if colour:
                canvas[(j * 16 + i) * 4:(j * 16 + i) * 4 + 4] = rgba(colour)
    return bytes(canvas)


def _icon_vram(wa: bytes) -> "Vram":
    vram = Vram()
    vram.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * SECTOR], 640, 0)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    return vram


def bake_star_icons(wa: bytes, exe: bytes, output: Path) -> int:
    """The ten guardian star symbols, as the duel's text draws them: an icon entry with code c = 0x17 + its id (the text's icon
    entries), ids 1 to 10 (see _icon_canvas). Written as star_icons/<name>.png (index 0 transparent)."""
    vram = _icon_vram(wa)
    names = {1: "mars", 2: "jupiter", 3: "saturn", 4: "uranus", 5: "pluto", 6: "neptune", 7: "mercury", 8: "sun", 9: "moon", 10: "venus"}
    written = 0
    for star, name in names.items():
        written += bool(write_output(output / "star_icons" / f"{name}.png", png(16, 16, _icon_canvas(vram, 0x17 + star)), output))
    return written


def bake_race_icons(wa: bytes, exe: bytes, output: Path) -> int:
    """The icons of the card text's codes 0 to 23: the monster races (codes 0 to 19, the card type CARD_TYPE_DRAGON..PLANT), then the
    spell, trap, ritual and equip kinds (20 to 23), the same sprites as the stars. Written as race_icons/<code>.png, two digits."""
    vram = _icon_vram(wa)
    written = 0
    for c in range(24):
        written += bool(write_output(output / "race_icons" / f"{c:02d}.png", png(16, 16, _icon_canvas(vram, c)), output))
    return written


BUTTON_CODES = {0x22: "cross", 0x23: "triangle", 0x24: "square", 0x25: "circle", 0x26: "star", 0x27: "start_1", 0x28: "start_2"}


def button_cell(code: int):
    """The texture cell of a picture entry F8 0B n (the picture entry routine's icon path): for n from 0x22, the
    16 x 16 cell at u = (n * 16 - 0x210) mod 256, v = 0x80 of tpage 0xB (VRAM x 704, y 0, 4 bits a texel), in the CLUT at (0x200, 0xFC),
    or (0x210, 0xFC) when that u is 0x50. Index 0 is transparent."""
    u = (code * 16 - 0x210) & 255
    return u, 0x80, (0x210 if u == 0x50 else 0x200), 0xFC


def bake_button_glyphs(wa: bytes, output: Path) -> int:
    """The controller pictures the text draws for F8 0B n (cross, triangle, square, circle, the star and the two halves of START):
    written as buttons/<name>.png, 16 x 16 with index 0 transparent, and buttons/buttons.json maps each code's two hex digits to its
    file. The icon sheet is the boot UI image (_icon_vram), the same as the stars' and the race icons'."""
    vram = _icon_vram(wa)
    written = 0
    codes = {}
    for code, name in BUTTON_CODES.items():
        u, v, cx, cy = button_cell(code)
        canvas = bytearray(16 * 16 * 4)
        for j in range(16):
            for i in range(16):
                index = vram.texel4(STAR_ICON_PAGE * 64, 0, u + i, v + j)
                colour = vram.colour(cx, cy, index) if index else 0
                if colour:
                    canvas[(j * 16 + i) * 4:(j * 16 + i) * 4 + 4] = rgba(colour)
        written += bool(write_output(output / "buttons" / f"{name}.png", png(16, 16, bytes(canvas)), output))
        codes[f"{code:02X}"] = f"{name}.png"
    written += bool(write_output(output / "buttons" / "buttons.json", json.dumps({"size": 16, "codes": codes}, indent=1) + "\n", output))
    return written


def bake_backdrops(wa: bytes, exe: bytes, output: Path) -> int:
    """The backdrops of the Trade screen and the two-player life point setup (the trade screen setup, the value setup): the sand object
    (stream (0,4,11), page 12 = VRAM (768,0), CLUT row 0x208, the boot UI image), drawn at the origin (0, 0) and cut to its box (backdrops/sand.png);
    the trade's 1P and 2P panel grid (stream (0,4,4), origin (0, -3)) as trade/panel.png, and its red cursor bar (stream (0,4,8), origin (30, 36),
    the second column's at x 190) as trade/cursor.png. layout.json gives each cut-out's offset from its origin."""
    import json
    vram = Vram()
    vram.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * SECTOR], 640, 0)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    tail = exe[0x801AC000 - LOAD + HEADER:0x801AC000 - LOAD + HEADER + 0x10000]
    margin = 64
    width, height = SCREEN_W + margin * 2, SCREEN_H + margin * 2
    layout, written = {}, 0

    def piece(path, stream, origin, semi=False):
        nonlocal written
        canvas = bytearray(width * height * 4)
        draw_object(vram, tail, resolve_stream(tail, *stream), 0, 0, 12, 0x200, 0xF8, False, canvas, margin, semi=semi)
        cut = cropped(bytes(canvas), width, height, margin)
        if cut is None:
            return None
        data, ox, oy = cut
        written += bool(write_output(output / path, data, output))
        return {"origin": list(origin), "x": ox, "y": oy}

    layout["sand"] = piece("backdrops/sand.png", (0, 4, 11), (0, 0))
    layout["trade_panel"] = piece("backdrops/trade/panel.png", (0, 4, 4), (0, -3), semi=True)
    layout["trade_cursor"] = piece("backdrops/trade/cursor.png", (0, 4, 8), (30, 36))
    written += bool(write_output(output / "backdrops" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


# The 2P duel rules setup (the value setup of the 2P duel): the frame's primitives in drawing order (the sand
# tiles are drawn first, by RULES_SAND). Each entry is ('s', x, y, w, h, u, v, clut x, clut y, page x, page y) for a textured rectangle,
# ('q', page x, page y, clut x, clut y, tri, [(x, y, u, v) x 4]) for a textured quad (shade 128), or ('f', abr, semi, [(x, y, shade) x 4])
# for a flat quad (the footer's semi-transparent box). Coordinates are screen pixels.
RULES_STATIC = [
    ('s', 177, 51, 8, 96, 16, 32, 0, 245, 896, 0),
    ('s', 177, 147, 8, 16, 40, 32, 0, 245, 896, 0),
    ('s', 0, 10, 16, 96, 48, 32, 32, 245, 896, 0),
    ('s', 0, 106, 16, 64, 24, 64, 32, 245, 896, 0),
    ('s', 16, 10, 64, 16, 64, 32, 32, 245, 896, 0),
    ('s', 80, 10, 64, 16, 64, 48, 32, 245, 896, 0),
    ('s', 16, 42, 64, 16, 64, 64, 32, 245, 896, 0),
    ('s', 80, 42, 64, 16, 64, 80, 32, 245, 896, 0),
    ('s', 16, 154, 64, 16, 64, 96, 32, 245, 896, 0),
    ('s', 80, 154, 64, 16, 64, 112, 32, 245, 896, 0),
    ('s', 144, 10, 32, 16, 128, 112, 32, 245, 896, 0),
    ('s', 144, 42, 32, 16, 160, 112, 32, 245, 896, 0),
    ('s', 144, 154, 32, 16, 192, 112, 32, 245, 896, 0),
    ('q', 896, 0, 32, 245, False, [(176, 10, 127, 48), (240, 10, 63, 48), (176, 26, 127, 64), (240, 26, 63, 64)]),
    ('q', 896, 0, 32, 245, False, [(240, 10, 127, 32), (304, 10, 63, 32), (240, 26, 127, 48), (304, 26, 63, 48)]),
    ('q', 896, 0, 32, 245, False, [(240, 42, 127, 64), (304, 42, 63, 64), (240, 58, 127, 80), (304, 58, 63, 80)]),
    ('q', 896, 0, 32, 245, False, [(176, 42, 127, 80), (240, 42, 63, 80), (176, 58, 127, 96), (240, 58, 63, 96)]),
    ('q', 896, 0, 32, 245, False, [(176, 154, 127, 112), (240, 154, 63, 112), (176, 170, 127, 128), (240, 170, 63, 128)]),
    ('q', 896, 0, 32, 245, False, [(240, 154, 127, 96), (304, 154, 63, 96), (240, 170, 127, 112), (304, 170, 63, 112)]),
    ('q', 896, 0, 32, 245, False, [(304, 10, 63, 32), (320, 10, 47, 32), (304, 106, 63, 128), (320, 106, 47, 128)]),
    ('q', 896, 0, 32, 245, False, [(304, 106, 39, 64), (320, 106, 23, 64), (304, 170, 39, 128), (320, 170, 23, 128)]),
    ('s', 12, 18, 72, 32, 0, 0, 0, 245, 896, 0),
    ('q', 896, 0, 0, 245, False, [(84, 18, 71, 0), (155, 18, 0, 0), (84, 50, 71, 32), (155, 50, 0, 32)]),
    ('q', 896, 0, 0, 245, False, [(236, 18, 71, 0), (307, 18, 0, 0), (236, 50, 71, 32), (307, 50, 0, 32)]),
    ('s', 164, 18, 72, 32, 0, 0, 0, 245, 896, 0),
    ('s', 139, 18, 40, 32, 88, 0, 0, 245, 896, 0),
    ('s', 8, 51, 128, 112, 128, 0, 0, 245, 896, 0),
    ('q', 896, 0, 0, 245, False, [(184, 51, 255, 0), (312, 51, 127, 0), (184, 163, 255, 112), (312, 163, 127, 112)]),
    ('s', 136, 51, 24, 96, 0, 32, 0, 245, 896, 0),
    ('q', 896, 0, 0, 245, False, [(160, 51, 23, 32), (183, 51, 0, 32), (160, 147, 23, 128), (183, 147, 0, 128)]),
    ('s', 136, 147, 24, 16, 24, 32, 0, 245, 896, 0),
    ('q', 896, 0, 0, 245, False, [(160, 147, 47, 32), (184, 147, 23, 32), (160, 163, 47, 48), (184, 163, 23, 48)]),
    ('s', 38, 18, 128, 24, 0, 128, 16, 245, 896, 0),
    ('s', 176, 18, 104, 24, 0, 152, 16, 245, 896, 0),
    ('s', 24, 66, 72, 16, 0, 176, 16, 245, 896, 0),
    ('s', 120, 58, 88, 24, 0, 192, 16, 245, 896, 0),
    ('s', 224, 58, 80, 24, 0, 216, 16, 245, 896, 0),
    ('s', 110, 102, 64, 16, 0, 240, 16, 245, 896, 0),
    ('s', 112, 130, 16, 16, 64, 240, 16, 245, 896, 0),
    ('s', 126, 130, 48, 16, 16, 240, 16, 245, 896, 0),
    ('s', 174, 130, 56, 16, 72, 176, 16, 245, 896, 0),
    ('s', 230, 130, 40, 16, 88, 192, 16, 245, 896, 0),
    ('s', 270, 130, 40, 16, 88, 208, 16, 245, 896, 0),
    ('s', 174, 102, 56, 16, 72, 176, 16, 245, 896, 0),
    ('s', 230, 102, 40, 16, 88, 192, 16, 245, 896, 0),
    ('s', 270, 102, 40, 16, 88, 208, 16, 245, 896, 0),
    ('f', 2, 1, [(52, 220, 160), (268, 220, 160), (44, 196, 128), (276, 196, 128)]),
    ('f', 2, 1, [(52, 172, 160), (268, 172, 160), (44, 196, 128), (276, 196, 128)]),
    ('s', 260, 198, 8, 12, 32, 24, 640, 232, 640, 0),
    ('s', 252, 198, 8, 12, 88, 24, 640, 232, 640, 0),
    ('s', 244, 198, 8, 12, 24, 36, 640, 232, 640, 0),
    ('s', 236, 198, 8, 12, 64, 24, 640, 232, 640, 0),
    ('s', 228, 198, 8, 12, 24, 36, 640, 232, 640, 0),
    ('s', 212, 198, 8, 12, 112, 24, 640, 232, 640, 0),
    ('s', 204, 198, 8, 12, 24, 36, 640, 232, 640, 0),
    ('s', 188, 198, 8, 12, 104, 24, 640, 232, 640, 0),
    ('s', 180, 198, 8, 12, 8, 36, 640, 232, 640, 0),
    ('s', 172, 198, 8, 12, 32, 36, 640, 232, 640, 0),
    ('s', 164, 198, 8, 12, 24, 36, 640, 232, 640, 0),
    ('s', 156, 198, 8, 12, 32, 24, 640, 232, 640, 0),
    ('s', 148, 198, 8, 12, 8, 36, 640, 232, 640, 0),
    ('s', 124, 198, 8, 12, 112, 48, 640, 232, 640, 0),
    ('s', 116, 198, 8, 12, 120, 48, 640, 232, 640, 0),
    ('s', 108, 198, 8, 12, 32, 60, 640, 232, 640, 0),
    ('s', 100, 198, 8, 12, 32, 60, 640, 232, 640, 0),
    ('s', 92, 198, 8, 12, 40, 60, 640, 232, 640, 0),
    ('s', 84, 198, 8, 12, 8, 24, 640, 232, 640, 0),
    ('s', 60, 196, 16, 16, 64, 128, 512, 252, 704, 0),
    ('s', 220, 182, 8, 12, 88, 24, 640, 232, 640, 0),
    ('s', 212, 182, 8, 12, 32, 24, 640, 232, 640, 0),
    ('s', 204, 182, 8, 12, 32, 36, 640, 232, 640, 0),
    ('s', 196, 182, 8, 12, 24, 24, 640, 232, 640, 0),
    ('s', 180, 182, 8, 12, 24, 36, 640, 232, 640, 0),
    ('s', 172, 182, 8, 12, 8, 36, 640, 232, 640, 0),
    ('s', 164, 182, 8, 12, 0, 24, 640, 232, 640, 0),
    ('s', 156, 182, 8, 12, 24, 36, 640, 232, 640, 0),
    ('s', 148, 182, 8, 12, 16, 36, 640, 232, 640, 0),
    ('s', 124, 182, 8, 12, 112, 48, 640, 232, 640, 0),
    ('s', 116, 182, 8, 12, 120, 48, 640, 232, 640, 0),
    ('s', 108, 182, 8, 12, 32, 60, 640, 232, 640, 0),
    ('s', 100, 182, 8, 12, 32, 60, 640, 232, 640, 0),
    ('s', 92, 182, 8, 12, 40, 60, 640, 232, 640, 0),
    ('s', 84, 182, 8, 12, 8, 24, 640, 232, 640, 0),
    ('s', 68, 180, 16, 16, 112, 128, 512, 252, 704, 0),
    ('s', 52, 180, 16, 16, 96, 128, 512, 252, 704, 0),
]


RULES_SAND = (0, 224, 576, 248, 768, 0)   # the sand tile: 32 x 32 texels at (0, 224) of page 12 (VRAM 768,0) in CLUT (576, 248)
RULES_DITHER = ((-4, 0, -3, 1), (2, -2, 3, -1), (-3, 1, -4, 0), (3, -1, 2, -2))   # the PS1 dither matrix, indexed [y & 3][x & 3]


def _rules_quant(value: int, x: int, y: int) -> int:
    """A 8-bit colour as the frame holds it: dithered at the pixel, cut to 5 bits and shown as v << 3."""
    return min(255, max(0, value + RULES_DITHER[y & 3][x & 3])) >> 3 << 3


def _rules_put(canvas, x: int, y: int, r: int, g: int, b: int):
    if 0 <= x < SCREEN_W and 0 <= y < SCREEN_H:
        at = (y * SCREEN_W + x) * 4
        canvas[at:at + 4] = bytes((r, g, b, 255))


def _rules_quad(vram: Vram, canvas, quad, subtract: bool, semi_colour: bool = False):
    """Two triangles of a PS1 quad (v0 v1 v2 and v1 v2 v3), sampled at whole pixels and not drawn on their right and bottom edges. A
    textured quad takes its texels from the page and CLUT; a flat one takes its vertex colour, and the semi-transparent footer
    subtracts it from what is behind it (the mode 2 blend)."""
    for tri in ((0, 1, 2), (1, 2, 3)):
        a, b, c = [quad["v"][i] for i in tri]
        xs = [a[0], b[0], c[0]]
        ys = [a[1], b[1], c[1]]
        d = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
        if d == 0:
            continue
        for y in range(max(0, min(ys)), min(SCREEN_H - 1, max(ys) - 1) + 1):
            for x in range(max(0, min(xs)), min(SCREEN_W - 1, max(xs) - 1) + 1):
                l0 = ((ys[1] - ys[2]) * (x - xs[2]) + (xs[2] - xs[1]) * (y - ys[2])) / d
                l1 = ((ys[2] - ys[0]) * (x - xs[2]) + (xs[0] - xs[2]) * (y - ys[2])) / d
                l2 = 1 - l0 - l1
                if min(l0, l1, l2) < -1e-9:
                    continue
                shade = l0 * a[2] + l1 * b[2] + l2 * c[2]
                if quad["page"] is None:
                    src = [_rules_quant(int(shade), x, y)] * 3
                    if subtract:
                        at = (y * SCREEN_W + x) * 4
                        src = [max(0, canvas[at + k] - src[k]) for k in range(3)]
                    _rules_put(canvas, x, y, *src)
                    continue
                u = l0 * a[3] + l1 * b[3] + l2 * c[3]
                v = l0 * a[4] + l1 * b[4] + l2 * c[4]
                value = vram.colour(quad["clut"][0], quad["clut"][1], vram.texel4(quad["page"][0], quad["page"][1], int(round(u, 4)) & 255, int(round(v, 4)) & 255))
                if value == 0:
                    continue
                r, g, bb = (value & 31) << 3, ((value >> 5) & 31) << 3, ((value >> 10) & 31) << 3
                shade = int(shade)
                out = [_rules_quant(r * shade // 128, x, y), _rules_quant(g * shade // 128, x, y), _rules_quant(bb * shade // 128, x, y)]
                _rules_put(canvas, x, y, *out)


def _rules_sprite(vram: Vram, canvas, x0, y0, w, h, u0, v0, cx, cy, px, py, rows=None):
    """A textured rectangle of 4-bit texels, unshaded (its colour 128 is the identity) and not dithered; index texels whose CLUT
    entry is 0 are transparent."""
    for j in range(h):
        for i in range(w):
            x, y = x0 + i, y0 + j
            if not (0 <= x < SCREEN_W and 0 <= y < SCREEN_H):
                continue
            value = vram.colour(cx, cy, vram.texel4(px, py, (u0 + i) & 255, (v0 + j) & 255))
            if value == 0:
                continue
            _rules_put(canvas, x, y, (value & 31) << 3, ((value >> 5) & 31) << 3, ((value >> 10) & 31) << 3)


def bake_rules(wa: bytes, su: bytes, output: Path) -> int:
    """The 2P duel rules setup (the value setup screen: its frame, the sand and the stone plate with the title, the legend, the
    labels, the value boxes, the bars' tick rows and the footer with its two button pictures). The frame is drawn from the
    primitives the screen draws (RULES_STATIC, in drawing order) with the textures of the menu package (page 14 = VRAM (896,0),
    CLUT rows 245), the boot UI (pages 10 to 12, the sand on page 12) and its palette rows. It is written as rules/static.png,
    with the parts the screen moves drawn over it: the life point digits (rules/digit_0..9.png, page 11 CLUT (656,250), each
    texel modulated by 255 and dithered at the pixel, as the digit quads are), and the value marker's star (rules/star_large.png,
    16 x 16, and rules/star_small.png, 8 x 8: page 11 CLUT (528,252)). The bars are drawn by the screen (gouraud from 64 to 255 in
    red, 32 to 255 in blue, dithered)."""
    import json
    vram = font_page(wa)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    vram.upload_tiles(su[64 * SECTOR:96 * SECTOR], 896, 0)
    vram.upload_rect(su[96 * SECTOR:98 * SECTOR], 0, 240, 256, 8)
    canvas = bytearray(SCREEN_W * SCREEN_H * 4)
    su_, sv, scx, scy, spx, spy = RULES_SAND
    for y in range(0, 224, 32):
        for x in range(0, SCREEN_W, 32):
            _rules_sprite(vram, canvas, x, y, 32, 32, su_, sv, scx, scy, spx, spy)
    for entry in RULES_STATIC:
        if entry[0] == "s":
            _, x, y, w, h, u, v, cx, cy, px, py = entry
            _rules_sprite(vram, canvas, x, y, w, h, u, v, cx, cy, px, py)
        elif entry[0] == "q":
            _, px, py, cx, cy, _tri, points = entry
            verts = [(x, y, 128, u, v) for x, y, u, v in points]
            _rules_quad(vram, canvas, {"v": verts, "page": (px, py), "clut": (cx, cy)}, False)
        else:
            _, abr, semi, points = entry
            verts = [(x, y, rgb, 0, 0) for x, y, rgb in points]
            _rules_quad(vram, canvas, {"v": verts, "page": None, "clut": None}, bool(semi) and abr == 2)
    for at in range(3, len(canvas), 4):
        canvas[at] = 255
    written = bool(write_output(output / "rules" / "static.png", png(SCREEN_W, SCREEN_H, bytes(canvas)), output))
    # the digits: the page 11 cells of the digit glyphs, each texel multiplied by 255 / 128 and dithered at its screen pixel. The cell's
    # origin is (158 - 8 * i, 106) for the value's first digit, so the origin's 4-pixel phase is 2 in x and in y (both rows).
    for digit in range(10):
        canvas_d = bytearray(8 * 8 * 4)
        u0, v0 = (digit * 8 + 128) & 255, 112
        for j in range(8):
            for i in range(8):
                value = vram.colour(656, 250, vram.texel4(704, 0, (u0 + i) & 255, (v0 + j) & 255))
                if value == 0:
                    continue
                pixels = [min(255, ((value >> s) & 31) << 3) * 255 // 128 for s in (0, 5, 10)]
                # the dither is taken at the screen pixel the cell is drawn at (x 150 - 8 * i ... shifted by the digit's place: x & 3 = 2)
                out = [min(255, max(0, c + RULES_DITHER[(106 + j) & 3][(150 + i) & 3])) >> 3 << 3 for c in pixels]
                canvas_d[(j * 8 + i) * 4:(j * 8 + i) * 4 + 4] = bytes((min(255, out[0]), min(255, out[1]), min(255, out[2]), 255))
        written += bool(write_output(output / "rules" / f"digit_{digit}.png", png(8, 8, bytes(canvas_d)), output))
    for name, w, h, u0, v0 in (("star_large", 16, 16, 80, 128), ("star_small", 8, 8, 16, 232)):
        star = bytearray(SCREEN_W * SCREEN_H * 4)
        _rules_sprite(vram, star, 0, 0, w, h, u0, v0, 528, 252, 704, 0)
        cut = bytearray(w * h * 4)
        for j in range(h):
            cut[j * w * 4:(j + 1) * w * 4] = star[j * SCREEN_W * 4:j * SCREEN_W * 4 + w * 4]
        written += bool(write_output(output / "rules" / f"{name}.png", png(w, h, bytes(cut)), output))
    return written


GAME_OVER_IMAGE, GAME_OVER_PALETTE, GAME_OVER_BANK = 0x10AB800, 0x10C3800, 0x10C4000   # WA_MRG.MRG: 48 image sectors at VRAM (0,256), the palette at (0,240) 256 x 4, the bank (the data at 0x801AF000)


def stream_commands(bank: bytes, f67: int, f68: int, f69: int):
    """The commands of a stream in play order as (hold, u16 frame offset) pairs, and the opcode that ends it (0xF0 or more)."""
    u16 = lambda o: struct.unpack_from("<H", bank, o)[0]
    at = u16(u16(u16(f67 * 2) + f68 * 2) + f69 * 2)
    commands = []
    while bank[at] < 0xF0:
        commands.append((bank[at], u16(at + 1)))
        at += 3
    return commands, bank[at]


def bake_game_over(wa: bytes, output: Path) -> int:
    """The Game Over screen (the game over setup, the routine at 0x8003CA5C). The background is the 320x240 picture on page 16 at 8 bits per pixel, straight
    from VRAM (the screen sprite has no stream: its page and CLUT row 240 are its own), so pixel x lives in halfword x / 2 of row 256 + y.
    The flying sprite is the bank's stream (0, 0, variant) for variant 0 to 2: 4 bits, page 18, CLUT (0, 241), its texture base
    (field_5E, u 128 set by the game over setup) added to the cells, cut to its box.
    layout.json gives each frame's offset from the sprite's origin and each variant's stream as [hold, frame] pairs, in play order;
    each stream ends with a Stop (0xFF), which is what the game waits for before it changes variant."""
    import json
    vram = Vram()
    vram.upload_tiles(wa[GAME_OVER_IMAGE:GAME_OVER_IMAGE + 48 * SECTOR], 0, 256)
    vram.upload_rect(wa[GAME_OVER_PALETTE:GAME_OVER_PALETTE + SECTOR], 0, 240, 256, 4)
    bank = wa[GAME_OVER_BANK:GAME_OVER_BANK + SECTOR]
    written = 0
    background = bytearray(SCREEN_W * SCREEN_H * 4)
    for y in range(SCREEN_H):
        for x in range(SCREEN_W):
            word = vram.words[(256 + y) * 1024 + (x >> 1)]
            colour = vram.colour(0, 240, (word >> (8 * (x & 1))) & 0xFF)
            if colour:
                background[(y * SCREEN_W + x) * 4:(y * SCREEN_W + x) * 4 + 4] = rgba(colour)
    written += bool(write_output(output / "game_over" / "background.png", png(SCREEN_W, SCREEN_H, bytes(background)), output))
    margin = 64
    width, height = SCREEN_W + margin * 2, SCREEN_H + margin * 2
    layout = {"background": {"x": 0, "y": 0}, "frames": [], "streams": []}
    index_of = {}

    def frame(offset):
        nonlocal written
        if offset not in index_of:
            canvas = bytearray(width * height * 4)
            draw_object(vram, bank, offset, 0, 0, 18, 0, 241, False, canvas, margin, texture=(128, 0))
            cut = cropped(bytes(canvas), width, height, margin)
            data, ox, oy = cut if cut is not None else (png(1, 1, bytes(4)), 0, 0)
            name = f"sprite_{len(index_of)}.png"
            written += bool(write_output(output / "game_over" / name, data, output))
            index_of[offset] = len(layout["frames"])
            layout["frames"].append({"file": name, "x": ox, "y": oy})
        return index_of[offset]

    for variant in range(3):
        commands, end = stream_commands(bank, 0, 0, variant)
        if end != 0xFF:
            raise ValueError(f"game over stream {variant} ends with opcode 0x{end:02X}, not Stop (0xFF)")
        layout["streams"].append([[hold, frame(offset)] for hold, offset in commands])
    written += bool(write_output(output / "game_over" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


STORY_PACKAGE = 0xF2B800   # WA_MRG.MRG: 16 UI image sectors, palette, 2 script sectors, 25 portraits (30 sectors)
STORY_PICTURES = 0x21D5 * SECTOR
STORY_MODES = ((0x21, 0, 50), (0x51, 0x672, 42), (0x71, 0x13BC, 13))   # stride in sectors, first record, record count


def bake_story(wa: bytes, exe: bytes, output: Path) -> int:
    """The campaign scene package and the story pictures: the event script bank (raw u16 offset table + streams), the 25 dialog
    portraits (48x48, 8 bits, 64-colour CLUT), and every story picture (records of stride-1 image sectors laid out as columns of 16
    tiles, 128 pixels wide each at 8 bits, with the record's last sector as its palette, 256 x 4 at VRAM (0, 240))."""
    # the dialog frame (the primary campaign display object creation): the tail table's first object at (16, 176) on page 13 = VRAM (832, 0),
    # CLUT (256, 240); the campaign UI image is 16 sectors, its palette one sector at 0xF33800
    vram = Vram()
    vram.upload_tiles(wa[STORY_PACKAGE:STORY_PACKAGE + 16 * SECTOR], 832, 0)
    vram.upload_rect(wa[0xF33800:0xF33800 + 512], 256, 240, 256, 1)
    base = 0x801AC000 - LOAD + HEADER
    bank = exe[base:base + 0x10000]
    frame = bytearray(SCREEN_W * SCREEN_H * 4)
    draw_object(vram, bank, resolve_stream(bank, 0, 0, 0), 16, 176, 13, 256, 240, False, frame)
    written = bool(write_output(output / "story" / "frame.png", png(SCREEN_W, SCREEN_H, bytes(frame)), output))
    script = wa[STORY_PACKAGE + 0x8800:STORY_PACKAGE + 0x9800]
    written += bool(write_output(output / "story" / "script.bin", script, output))
    for index in range(25):
        record = 0xF35000 + index * 0x980
        pixels = bytearray(48 * 48 * 4)
        for y in range(48):
            for x in range(48):
                colour = struct.unpack_from("<H", wa, record + 0x900 + wa[record + y * 48 + x] * 2)[0] if wa[record + y * 48 + x] else 0
                if colour:
                    pixels[(y * 48 + x) * 4:(y * 48 + x) * 4 + 4] = rgba(colour)
        written += bool(write_output(output / "story" / "portraits" / f"{index:02d}.png", png(48, 48, bytes(pixels)), output))
    for mode, (stride, first, count) in enumerate(STORY_MODES):
        for index in range(count):
            base = STORY_PICTURES + (first + index * stride) * SECTOR
            sectors = stride - 1
            if not any(wa[base:base + sectors * SECTOR]):
                continue
            columns = -(-sectors // 16)
            width = columns * 128
            palette = struct.unpack_from("<256H", wa, base + sectors * SECTOR)
            pixels = bytearray(width * 256 * 4)
            for tile in range(sectors):
                column, row = divmod(tile, 16)
                data = base + tile * SECTOR
                for j in range(16):
                    for i in range(128):
                        value = palette[wa[data + j * 128 + i]]
                        if value:
                            at = (((row * 16 + j) * width) + column * 128 + i) * 4
                            pixels[at:at + 4] = rgba(value)
            written += bool(write_output(output / "story" / "pictures" / f"m{mode}_{index:02d}.png", png(width, 256, bytes(pixels)), output))
    return written


STORY_WINDOW_H = 160   # the picture region: the old-picture snapshot is 320x160 and the dialog frame starts at y 176


def story_next(script: bytes, pc: int):
    """The pcs an opcode at pc continues to, and the image id it stages (opcodes 1 and 4). Operand sizes are what each handler reads
    (opcode = byte & 0x1F): Sound takes 3 operand bytes, or 1 + 2 with bit 1; StoryFlag takes 2 with the write bit (0x4000) and 4
    otherwise, branching to its offset when the flag is set; Jump and JumpIfDeckIncomplete read an absolute target. Halt, the two
    unused handlers, GameOver, Credits and ReturnToMenu end the scene."""
    u16 = lambda o: struct.unpack_from("<H", script, o)[0] if o + 2 <= len(script) else 0
    op, a = script[pc] & 0x1F, pc + 1
    if op in (1, 4):
        value = u16(a)
        return [pc + 1 + (6 if value & 0x8000 else 2)], value & 0xFFF
    if op == 3:
        return ([pc + 3] if u16(a) & 0x4000 else [pc + 5, u16(a + 2)]), None
    if op == 10:
        return [pc + 1 + (3 if (script[a] & 0x3F) == 0 else 1 + (2 if script[a] & 2 else 0))], None
    if op == 12:
        return [u16(a)], None
    if op == 21:
        return [pc + 3, u16(a)], None
    operands = {2: 2, 5: 0, 6: 6, 7: 0, 8: 1, 9: 2, 11: 1, 13: 4, 16: 1, 17: 2, 20: 2}.get(op)
    return ([pc + 1 + operands] if operands is not None else []), None


def story_images(script: bytes):
    """Image id -> the first scene (offset table entry) whose opcodes reach it; every scene is walked from its table entry."""
    u16 = lambda o: struct.unpack_from("<H", script, o)[0]
    images = {}
    for scene in range(u16(0) // 2):
        todo, seen = [u16(scene * 2)], set()
        while todo:
            pc = todo.pop()
            if pc in seen or pc >= len(script):
                continue
            seen.add(pc)
            following, image = story_next(script, pc)
            if image is not None:
                images.setdefault(image, scene)
            todo += following
    return images


def story_picture(wa: bytes, exe: bytes, image: int) -> bytes:
    """One story picture as the window the game shows at viewport (0, 0), RGBA 320 x 160. the picture transfer request puts the record's
    tiles at VRAM (0, 256) and its last sector's four palette rows at (0, 240). the picture object rebuild then draws the base object
    (page 0x10, CLUT row 0) and up to two overlays from the tail table's stream (2, 0, 0): pages 0x12 and 0x14 with CLUT rows 1 and 2
    at (0, 0) for ids 0x100-0x1FF, and for ids 0x200+ the the data at 0x80090C00 positions on pages 0x14 and 0x16. The 0x200+ base is a 512-wide
    screen sprite whose sheet selectors the code never sets; the (2, 0, 0) sheet stands in for it here."""
    at = lambda a: a - LOAD + HEADER
    mode, index = image >> 8, ((image >> 4) & 15) * 10 + (image & 15)
    stride, first, _ = STORY_MODES[mode]
    record = STORY_PICTURES + (first + index * stride) * SECTOR
    vram = Vram()
    vram.upload_tiles(wa[record:record + (stride - 1) * SECTOR], 0, 256)
    vram.upload_rect(wa[record + (stride - 1) * SECTOR:record + stride * SECTOR], 0, 240, 256, 4)
    tail = exe[at(0x801AC000):at(0x801AC000) + 0x10000]
    sheet = resolve_stream(tail, 2, 0, 0)
    objects = [(0, 0, 0x10, 0xF0)]
    if 0x100 <= image < 0x200:
        mask = exe[at(0x80090BA8) + index * 2]
        if mask & 1:
            objects.append((0, 0, 0x12, 0xF1))
        if mask & 2:
            objects.append((0, 0, 0x14, 0xF2))
    elif image >= 0x200:
        mask, x1, y1, x2, y2 = exe[at(0x80090C00) + index * 6:at(0x80090C00) + index * 6 + 5]
        if mask & 1:
            objects.append((x1, y1, 0x14, 0xF1))
        if mask & 2:
            objects.append((x2, y2, 0x16, 0xF2))
    if image >= 0x200:
        # a 512 x 256 screen sprite over page 0x10 (8 bits, CLUT row 0xF0) with the two overlays at their table positions
        canvas = bytearray(512 * 256 * 4)
        for py in range(256):
            row = [(vram.words[(256 + py) * 1024 + (px >> 1)] >> (8 * (px & 1))) & 0xFF for px in range(512)]
            for px in range(512):
                # texel index 0 is unused picture area (the art ends where its texels do): left transparent, not palette entry 0
                if row[px]:
                    canvas[(py * 512 + px) * 4:(py * 512 + px) * 4 + 4] = rgba(vram.colour(0, 0xF0, row[px]))
        for x, y, page, row in objects[1:]:
            draw_object(vram, tail, sheet, x, y, page, 0, row, True, canvas, 0, 512, 256, blend=True)
        return bytes(canvas)
    canvas = bytearray(SCREEN_W * SCREEN_H * 4)
    for n, (x, y, page, row) in enumerate(objects):
        draw_object(vram, tail, sheet, x, y, page, 0, row, True, canvas, blend=n > 0)
    window = canvas[:SCREEN_W * STORY_WINDOW_H * 4]
    # texels whose colour is 0x0000 are not drawn (the silhouettes, and the empty parts of a picture). The story screen puts a black
    # backdrop behind the picture, so those pixels show black: the window is made opaque black there, as the screen shows it.
    window[3::4] = b"\xff" * (len(window) // 4)
    return bytes(window)


def bake_story_scenes(wa: bytes, exe: bytes, output: Path) -> int:
    """Every story picture on the disc, written as scenes/<id>.png plus scenes/layout.json: the window size, the viewport (0, 0) the
    script leaves it at, and the 512 x 256 base extent for ids 0x200+. The script stages some pictures with its own opcodes and
    others from inside dialog text (F7 05), so every non-empty record is baked; ids are the record's mode and decimal index in
    nibbles (mode << 8 | tens << 4 | units)."""
    import json
    script = wa[STORY_PACKAGE + 0x8800:STORY_PACKAGE + 0x9800]
    reached = story_images(script)
    layout, written = {}, 0
    for mode, (stride, first, count) in enumerate(STORY_MODES):
        for index in range(count):
            record = STORY_PICTURES + (first + index * stride) * SECTOR
            if not any(wa[record:record + (stride - 1) * SECTOR]):
                continue
            image = (mode << 8) | ((index // 10) << 4) | (index % 10)
            size = [512, 256] if image >= 0x200 else [SCREEN_W, STORY_WINDOW_H]
            written += bool(write_output(output / "story" / "scenes" / f"{image:03x}.png", png(size[0], size[1], story_picture(wa, exe, image)), output))
            layout[f"{image:03x}"] = {"scene": reached.get(image, -1), "size": size, "viewport": [0, 0], "scroll": image >= 0x200}
    written += bool(write_output(output / "story" / "scenes" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


# ---- campaign map ------------------------------------------------
MAP_PACKAGES = (("before", 8153), ("after", 8153 + 158))   # WA sector of the overworld package, before and after the tournament flag
MAP_MODEL_SECTOR, MAP_MODEL_SECTORS = 6, 134
MAP_TABLE, MAP_RECORD, MAP_PLACES = 0x11A8, 66, 16          # the location table inside the module image (package +0, 6 sectors)
MAP_SCALE = 1365 / 4096
MAP_AMBIENT, MAP_DIFFUSE, MAP_LIGHT = 0.61, 0.58, (0.10, -0.99, 0.02)   # the lighting the model is baked with


def _rotation_yxz(rx, ry, rz):
    """RotMatrixYXZ: Ry * Rx * Rz, angles in 4096ths of a turn."""
    import math
    c = lambda a: math.cos(a * 2 * math.pi / 4096)
    s = lambda a: math.sin(a * 2 * math.pi / 4096)
    mx = ((1, 0, 0), (0, c(rx), -s(rx)), (0, s(rx), c(rx)))
    my = ((c(ry), 0, s(ry)), (0, 1, 0), (-s(ry), 0, c(ry)))
    mz = ((c(rz), -s(rz), 0), (s(rz), c(rz), 0), (0, 0, 1))
    mul = lambda a, b: tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))
    return mul(mul(my, mx), mz)


def parse_map_model(blob: bytes):
    """The overworld's HMD: image uploads (VRAM words) and the terrain polygons with their vertices, normals and coordinate unit.
    Returns (vram words, polygons [(uvs, clut, tpage, vertex ids, normal ids)], vertices, normals, matrix, translation)."""
    word = lambda i: struct.unpack_from("<I", blob, i * 4)[0]
    if word(0) != 0x50:
        raise SystemExit("the map block is not an HMD")
    vram = [0] * (1024 * 512)
    polygons = []
    position = word(2) + 1
    headers = {}
    for _ in range(word(word(2))):
        count = word(position)
        headers[position] = [word(position + 1 + i) & 0x7FFFFFFF for i in range(count)]
        position += 1 + count
    terrain = None
    for b in range(word(3)):
        block = word(4 + b)
        if not block:
            continue
        sections = headers[word(block + 1)]
        cursor = block + 3
        for _ in range(word(block + 2) & 0xFFFF):
            kind, head = word(cursor), word(cursor + 1)
            size, items = head & 0xFFFF, (head >> 16) & 0x7FFF
            if kind in (0x02000000, 0x02000001):
                at = cursor + 2
                for _ in range(items):
                    for k in range(1 + (kind & 1)):
                        x, y, w, h = struct.unpack_from("<hhhh", blob, at * 4)
                        offset = (sections[k] + word(at + 2)) * 4
                        for row in range(h):
                            line = struct.unpack_from("<%dH" % w, blob, offset + row * w * 2)
                            start = ((y + row) & 511) * 1024 + (x & 1023)
                            vram[start:start + w] = line
                        at += 3
            elif kind & 0xFFFF in (0x000D, 0x0015):
                quad = kind & 0xFFFF == 0x0015
                stride = 14 if quad else 12
                base = (sections[0] + word(cursor + 2)) * 4
                for i in range(items):
                    r = struct.unpack_from("<%dH" % stride, blob, base + i * stride * 2)
                    if quad:
                        polygons.append(((r[0], r[2], r[4], r[6]), r[1], r[3], (r[7], r[9], r[11], r[13]), (r[5], r[8], r[10], r[12])))
                    else:
                        polygons.append(((r[0], r[2], r[4]), r[1], r[3], (r[7], r[9], r[11]), (r[6], r[8], r[10])))
                terrain = sections
            cursor += 1 + size
    vertices_at, normals_at, units_at = terrain[1], terrain[2], terrain[3]
    vertices = [struct.unpack_from("<hhh", blob, (vertices_at + 2 * i) * 4) for i in range((normals_at - vertices_at) // 2)]
    normals = [struct.unpack_from("<hhh", blob, (normals_at + 2 * i) * 4) for i in range((terrain[0] - normals_at) // 2)]
    unit = units_at * 4 + 4
    translation = struct.unpack_from("<3i", blob, unit + 4 + 20)
    matrix = _rotation_yxz(*struct.unpack_from("<3h", blob, unit + 68))
    return vram, polygons, vertices, normals, matrix, translation


def bake_map(wa: bytes, output: Path) -> int:
    """The campaign map: the terrain model (world-space vertices, per-corner light, faces grouped by their texture page and CLUT)
    as map/<before|after>/model.json plus one 256x256 texture per page and palette, and the 16 places' table (camera, markers
    and exits) as map/places_<before|after>.json."""
    written = 0
    for label, sector in MAP_PACKAGES:
        base = sector * SECTOR
        if base + (MAP_MODEL_SECTOR + MAP_MODEL_SECTORS) * SECTOR > len(wa):
            continue
        folder = output / "map" / label
        image = wa[base:base + 6 * SECTOR]
        places = []
        for i in range(MAP_PLACES):
            r = image[MAP_TABLE + i * MAP_RECORD:MAP_TABLE + (i + 1) * MAP_RECORD]
            gate, pitch, heading, distance, vx, vz, mx, my = struct.unpack_from("<Hhhhhhhh", r, 0)
            exits = []
            for e in range(4):
                flag, x, y, mask = struct.unpack_from("<HhhH", r, 0x12 + e * 12)
                variant, destination, steps = r[0x12 + e * 12 + 8:0x12 + e * 12 + 11]
                exits.append({"flag": flag, "x": x, "y": y, "mask": mask, "variant": variant, "destination": destination, "steps": steps})
            places.append({"confirm_gate": gate, "pitch": pitch, "heading": heading, "distance": distance, "view_x": vx, "view_z": vz,
                           "marker_x": mx, "marker_y": my, "confirm_destination": r[0x10], "exits": exits})
        written += bool(write_output(output / "map" / f"places_{label}.json", json.dumps(places, indent=1) + "\n", output))
        blob = wa[base + MAP_MODEL_SECTOR * SECTOR:base + (MAP_MODEL_SECTOR + MAP_MODEL_SECTORS) * SECTOR]
        vram, polygons, vertices, normals, matrix, translation = parse_map_model(blob)
        # The places' cameras frame the terrain in its unrotated, untranslated space: the before package's stored transform is
        # the identity, and the after package's stored offset and turn put its terrain about 1800 units off every camera (the
        # fog then hides it). The stored transform is therefore not applied to either package.
        matrix, translation = ((1, 0, 0), (0, 1, 0), (0, 0, 1)), (0, 0, 0)
        world = []
        for v in vertices:
            world.append([round(sum(matrix[i][j] * v[j] for j in range(3)) * MAP_SCALE + translation[i], 3) for i in range(3)])
        shades = []
        for n in normals:
            turned = [sum(matrix[i][j] * n[j] for j in range(3)) / 4096 for i in range(3)]
            shades.append(round(MAP_AMBIENT + MAP_DIFFUSE * max(0.0, sum(turned[i] * MAP_LIGHT[i] for i in range(3))), 4))
        textures, faces = {}, []
        for uvs, clut, tpage, ids, nids in polygons:
            key = (tpage & 0x1FF, clut)
            if key not in textures:
                textures[key] = len(textures)
            order = ((0, 1, 2),) if len(ids) == 3 else ((0, 1, 2), (1, 3, 2))
            for tri in order:
                faces.append({"t": textures[key], "v": [ids[i] for i in tri], "uv": [[uvs[i] & 255, uvs[i] >> 8] for i in tri],
                              "s": [shades[nids[i]] if nids[i] < len(shades) else 1.0 for i in tri]})
        for (tpage, clut), index in textures.items():
            px, py, depth = (tpage & 15) * 64, ((tpage >> 4) & 1) * 256, (tpage >> 7) & 3
            canvas = bytearray(256 * 256 * 4)
            cbase = (clut >> 6) * 1024 + (clut & 63) * 16
            for v in range(256):
                for u in range(256):
                    if depth >= 2:
                        colour = vram[((py + v) & 511) * 1024 + ((px + u) & 1023)]
                    else:
                        word = vram[((py + v) & 511) * 1024 + px + (u >> (2 if depth == 0 else 1))]
                        idx = (word >> ((u & 3) * 4)) & 15 if depth == 0 else (word >> ((u & 1) * 8)) & 255
                        colour = vram[cbase + idx]
                    if colour:
                        canvas[(v * 256 + u) * 4:(v * 256 + u) * 4 + 4] = rgba(colour)
            written += bool(write_output(folder / f"texture_{index}.png", png(256, 256, bytes(canvas)), output))
        model = {"vertices": world, "faces": faces, "textures": len(textures)}
        written += bool(write_output(folder / "model.json", json.dumps(model, separators=(",", ":")) + "\n", output))
    written += bake_map_sprites(wa, output)
    return written


MAP_SPRITES = {"panel": (0, 0), "marker": (1, 0), **{f"arrow{v}": (2, v) for v in range(8)}}   # animation, variant in the package's bank


def bake_map_sprites(wa: bytes, output: Path) -> int:
    """The map's sprites (the name panel, the Millennium Puzzle marker and the exits' arrows): the package's one-sector bank (+140),
    its 256 x 256 four-bit strip (+141) and its palettes (+157). Each animation stream's frames are written as
    map/sprites/<name>_<n>.png with map/sprites/index.json {name: [{file, duration, x, y}]} (x, y: the frame's top-left corner
    from the object's position)."""
    base = MAP_PACKAGES[0][1] * SECTOR
    if base + 158 * SECTOR > len(wa):
        return 0
    bank = wa[base + 140 * SECTOR:base + 141 * SECTOR]
    strip = wa[base + 141 * SECTOR:base + 157 * SECTOR]
    palettes = wa[base + 157 * SECTOR:base + 157 * SECTOR + 512]
    u16 = lambda blob, at: blob[at] | (blob[at + 1] << 8)
    written, index = 0, {}
    for name, (animation, variant) in MAP_SPRITES.items():
        try:
            at = u16(bank, u16(bank, u16(bank, 0) + animation * 2) + variant * 2)
        except IndexError:
            continue
        frames, seen, mirror = [], set(), False
        while at not in seen and len(frames) < 32:
            seen.add(at)
            op = bank[at]
            if op in (0xFB, 0xFC):      # jump (0xFB also toggles the mirror)
                mirror ^= op == 0xFB
                at = u16(bank, at + 1)
                continue
            if op >= 0xF0:
                break
            frames.append((op, u16(bank, at + 1), mirror))
            if op == 0:                  # a zero duration holds the frame
                break
            at += 3
        entries = []
        for n, (duration, frame, flipped) in enumerate(frames):
            count, flags, _page, step = bank[frame:frame + 4]
            parts = []
            for k in range(count):
                dx, dy, cell, size = struct.unpack_from("<bbHH", bank, frame + 4 + 6 * k)
                w, h = ((size >> 5) & 0xF) * 8 + 8, ((size >> 9) & 0xF) * 8 + 8
                if flipped:
                    dx = -(dx + w)
                parts.append((dx, dy, (cell & 0x1F) * 8, ((cell >> 5) & 0x1F) * 8, w, h, bool(cell & 0x2000) ^ flipped))
            if not parts:
                continue
            left, top = min(p[0] for p in parts), min(p[1] for p in parts)
            width = max(p[0] + p[4] for p in parts) - left
            height = max(p[1] + p[5] for p in parts) - top
            palette = (step & 0xF) + (step >> 4) * 16
            canvas = bytearray(width * height * 4)
            for dx, dy, u, v, w, h, flip in reversed(parts):
                for j in range(h):
                    for i in range(w):
                        uu = u + (w - 1 - i if flip else i)
                        byte = strip[((v + j) & 255) * 128 + (uu & 255) // 2]
                        idx = byte >> 4 if uu & 1 else byte & 15
                        colour = u16(palettes, (palette * 16 + idx) * 2)
                        if colour:
                            x, y = dx - left + i, dy - top + j
                            canvas[(y * width + x) * 4:(y * width + x) * 4 + 4] = rgba(colour)
            file = f"{name}_{n}.png"
            written += bool(write_output(output / "map" / "sprites" / file, png(width, height, bytes(canvas)), output))
            entries.append({"file": file, "duration": duration, "x": left, "y": top})
        index[name] = entries
    written += bool(write_output(output / "map" / "sprites" / "index.json", json.dumps(index, indent=1) + "\n", output))
    return written


# ---- duel field --------------------------------------------------
DUEL_TERRAIN_COUNT, DUEL_TERRAIN_SECTORS = 7, 235            # terrain 0 (none) to 6 (Dark), 0xEB sectors each from WA sector 0x16C6
DUEL_FIELD_GRID, DUEL_FIELD_REFERENCE, DUEL_FIELD_HEADINGS = 0x80090800, 0x800907AC, 0x8009AF20   # executable: the field grid (2 x 20 s16 pairs), the view reference z (2 x 2 x 4 s16), the view headings (2 u16)
DUEL_FIELD_RECORDS = 0x800907D8   # executable: the card record of each grid slot (2 x 20 bytes; the first side is the player)
DUEL_FIELD_DISTANCE, DUEL_FIELD_ELEVATION, DUEL_FIELD_PROJECTION = 0x14E, 0x3FE, 0x12C   # the routine at 0x800178BC: the view's distance and elevation; the default model projection
DUEL_FIELD_CENTRE, DUEL_FIELD_FOG = (0xA0, 0x6C), (0x28A, 0x320)   # the geometry offset in the field card drawing; the fog range 650, 800
DUEL_FIELD_CARD = [[-25, 29], [26, 29], [-25, -30], [26, -30]]   # the routine at 0x80015EF4: a card's four corners on the board (x, z), y = 0


DUEL_LIGHT_ROWS = [[-2000, -3333, -1333], [2000, -3333, 1333], [0, 4104, 0]]   # the duel board's GTE light matrix (SetLightMatrix in the real duel trace)


def bake_duel_field(wa: bytes, exe: bytes, output: Path) -> int:
    """The duel board for each terrain: the board's model (the HMD in the package's phase 11, whose first word is its size, not
    0x50) with its polygons' textures, and the VRAM the package's earlier phases upload (the package stage load: phase 0 to x 768,
    phase 6 to x 512, phase 12 to x 640 at y 256, phase 10 to x 832 at y 0, and the palette rows at y 240). Written as
    duel_field/terrain_<n>/model.json (world vertices in game units, y down, faces with a texture index, uv and shade) and
    texture_<i>.png; duel_field/layout.json holds the field grid, the view reference z per row, the headings and the card outline
    read from the executable and the functions named above."""
    import json
    at = lambda a: a - LOAD + HEADER
    grid = struct.unpack_from("<80h", exe, at(DUEL_FIELD_GRID))
    refs = struct.unpack_from("<16h", exe, at(DUEL_FIELD_REFERENCE))
    headings = struct.unpack_from("<2H", exe, at(DUEL_FIELD_HEADINGS))
    records = struct.unpack_from("<40B", exe, at(DUEL_FIELD_RECORDS))
    root = output / "duel_field"
    layout = {
        "terrains": list(TERRAINS),
        "grid": [[[grid[(side * 20 + slot) * 2], grid[(side * 20 + slot) * 2 + 1]] for slot in range(20)] for side in range(2)],
        "reference_z": [[[refs[(side * 2 + page) * 4 + row] for row in range(4)] for page in range(2)] for side in range(2)],
        "headings": list(headings),
        "records": [list(records[side * 20:side * 20 + 20]) for side in range(2)],
        "distance": DUEL_FIELD_DISTANCE, "elevation": DUEL_FIELD_ELEVATION, "projection": DUEL_FIELD_PROJECTION,
        "centre": list(DUEL_FIELD_CENTRE), "fog": list(DUEL_FIELD_FOG), "card": DUEL_FIELD_CARD,
        "units": "game units: x right, y down (height above the board, which is y = 0), z forward",
    }
    written = bool(write_output(root / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    for terrain in range(DUEL_TERRAIN_COUNT):
        base = (0x16C6 + terrain * DUEL_TERRAIN_SECTORS) * SECTOR
        if base + DUEL_TERRAIN_SECTORS * SECTOR > len(wa):
            break
        package = wa[base:base + DUEL_TERRAIN_SECTORS * SECTOR]
        part = lambda first, count: package[first * SECTOR:(first + count) * SECTOR]
        vram = Vram()
        vram.upload_tiles(part(0, 64), 768, 256)            # phase 0: 64 sectors of image
        vram.upload_rect(part(64, 4), 256, 240, 256, 16)    # phase 1 read, then phase 2 loads it as the palette rows
        vram.upload_rect(part(106, 2), 0, 240, 256, 8)      # phase 5 read, then phase 6 loads it as the palette rows
        vram.upload_tiles(part(108, 32), 512, 256)          # phase 6: 32 sectors of image
        vram.upload_tiles(part(190, 8), 832, 0)             # phase 10: 8 sectors of image
        vram.upload_tiles(part(203, 32), 640, 256)          # phase 12: 32 sectors of image
        hmd = bytearray(part(198, 5))                        # phase 11: the board model
        struct.pack_into("<I", hmd, 0, 0x50)                 # its size word stands where the HMD magic is
        own, polygons, vertices, normals, matrix, translation = parse_map_model(bytes(hmd))
        for i, word in enumerate(own):
            if word:
                vram.words[i] = word
        world = []
        for v in vertices:
            world.append([round(sum(matrix[i][j] * v[j] for j in range(3)) + translation[i], 3) for i in range(3)])
        # the board's lighting, read from the real duel's primitive trace (prim_duel.txt, every drawn vertex): the normal colour op gives IR = 1024
        # + 0.25 max(0, l1) + 0.25 max(0, l2) + 0.125 max(0, l3), with l_i = (light row i . normal) / 4096 and the light rows DUEL_LIGHT_ROWS (fit residual
        # under 1 unit on 222 fog-free corners). The colour byte is IR / 16 and the textured colour is texel * byte / 128, so the stored
        # factor is IR / 2048; the depth cue (IR0 per vertex) is applied in the shader.
        shades = []
        for n in normals:
            lights = [sum(DUEL_LIGHT_ROWS[i][c] * n[c] for c in range(3)) / 4096 for i in range(3)]
            lit = 1024 + 0.25 * max(0.0, lights[0]) + 0.25 * max(0.0, lights[1]) + 0.125 * max(0.0, lights[2])
            shades.append(round(lit / 2048, 4))
        textures, faces = {}, []
        for uvs, clut, tpage, ids, nids in polygons:
            key = (tpage & 0x1FF, clut)
            if key not in textures:
                textures[key] = len(textures)
            order = ((0, 1, 2),) if len(ids) == 3 else ((0, 1, 2), (1, 3, 2))
            for tri in order:
                faces.append({"t": textures[key], "v": [ids[i] for i in tri], "uv": [[uvs[i] & 255, uvs[i] >> 8] for i in tri],
                              "s": [shades[nids[i]] if nids[i] < len(shades) else 1.0 for i in tri]})
        folder = root / f"terrain_{terrain}"
        for (tpage, clut), index in textures.items():
            px, py, depth = (tpage & 15) * 64, ((tpage >> 4) & 1) * 256, (tpage >> 7) & 3
            canvas = bytearray(256 * 256 * 4)
            cbase = (clut >> 6) * 1024 + (clut & 63) * 16
            for v in range(256):
                for u in range(256):
                    if depth >= 2:
                        colour = vram.words[((py + v) & 511) * 1024 + ((px + u) & 1023)]
                    else:
                        word = vram.words[((py + v) & 511) * 1024 + px + (u >> (2 if depth == 0 else 1))]
                        idx = (word >> ((u & 3) * 4)) & 15 if depth == 0 else (word >> ((u & 1) * 8)) & 255
                        colour = vram.words[cbase + idx]
                    if colour:
                        canvas[(v * 256 + u) * 4:(v * 256 + u) * 4 + 4] = rgba(colour)
            written += bool(write_output(folder / f"texture_{index}.png", png(256, 256, bytes(canvas)), output))
        model = {"vertices": world, "faces": faces, "textures": len(textures)}
        written += bool(write_output(folder / "model.json", json.dumps(model, separators=(",", ":")) + "\n", output))
    return written


# ---- duel card face ----------------------------------------------
CARD_FACE_TERRAIN = 0     # the card face parts are the same in every terrain's package (checked for all seven)
CARD_FACE_FRAME_CLUT = 241   # CLUT row of the card frame's colour: row 241 monster, 242 magic and equip, 243 trap, 244 ritual


def bake_duel_card_face(wa: bytes, output: Path) -> int:
    """The duel card's own parts on VRAM page 30 (VRAM x 896, y 256), 8 bits a texel as the field card routines draw them: the
    card frame (the 52 x 60 window at (0, 128), colours by kind from CLUT rows 241 to 244), the card back (the same size at (56, 128),
    with the frame's CLUT row), the sword and shield icon (8 x 16 at (120, 112)), the spell labels Magic, Equip, Trap and Ritual (32 x 16
    at (0, 96), (32, 96), (64, 96), (96, 96), CLUT row 241) and the stat digits (8 x 8 at (8d, 88), d = 0 to 9; cell 10 is the blank
    the decimal encoding leaves for a leading zero). The page is in the terrain package's phase 0 and the palette in phase 1 and 2
    (the same uploads as bake_duel_field). Written as duel_card/<name>.png with the palette index 0 transparent, and layout.json."""
    import json
    base = (0x16C6 + CARD_FACE_TERRAIN * DUEL_TERRAIN_SECTORS) * SECTOR
    package = wa[base:base + DUEL_TERRAIN_SECTORS * SECTOR]
    vram = Vram()
    vram.upload_tiles(package[0:64 * SECTOR], 768, 256)     # phase 0: page 30 is its column 2
    vram.upload_rect(package[64 * SECTOR:68 * SECTOR], 256, 240, 256, 16)   # phases 1 and 2: the palette rows

    def cut(u, v, w, h, clut):
        out = bytearray(w * h * 4)
        for j in range(h):
            for i in range(w):
                word = vram.words[(256 + v + j) * 1024 + 896 + ((u + i) >> 1)]
                index = (word >> (((u + i) & 1) * 8)) & 255
                if index:
                    out[(j * w + i) * 4:(j * w + i) * 4 + 4] = rgba(vram.words[clut * 1024 + 256 + index])
        return bytes(out)

    frame_clut = {"monster": 241, "magic": 242, "equip": 242, "trap": 243, "ritual": 244}
    written = 0
    layout = {"frame": {"x": 0, "y": 128, "w": 52, "h": 60, "clut": frame_clut},
                       "back": {"x": 56, "y": 128, "w": 52, "h": 60, "clut": frame_clut},
                       "icon": {"x": 120, "y": 112, "w": 8, "h": 16},
                       "label": {"w": 32, "h": 16, "y": 96, "x": {"magic": 0, "equip": 32, "trap": 64, "ritual": 96}},
                       "digit": {"w": 8, "h": 8, "x": 0, "y": 88, "blank": 10},
                       "picture": {"x": 6, "y": 6, "w": 40, "h": 32}, "stat": {"x": 14, "atk_y": 40, "def_y": 48, "step": 8}}
    for kind in CARD_FACE_KINDS:
        row = frame_clut[kind]
        written += bool(write_output(output / "duel_card" / f"frame_{kind}.png", png(52, 60, cut(0, 128, 52, 60, row)), output))
        written += bool(write_output(output / "duel_card" / f"back_{kind}.png", png(52, 60, cut(56, 128, 52, 60, row)), output))
    written += bool(write_output(output / "duel_card" / "icon.png", png(8, 16, cut(120, 112, 8, 16, CARD_FACE_FRAME_CLUT)), output))
    for kind, x in (("magic", 0), ("equip", 32), ("trap", 64), ("ritual", 96)):
        written += bool(write_output(output / "duel_card" / f"label_{kind}.png", png(32, 16, cut(x, 96, 32, 16, CARD_FACE_FRAME_CLUT)), output))
    for d in range(11):
        name = f"digit_{d}" if d < 10 else "digit_blank"
        written += bool(write_output(output / "duel_card" / f"{name}.png", png(8, 8, cut(d * 8, 88, 8, 8, CARD_FACE_FRAME_CLUT)), output))
    written += bool(write_output(output / "duel_card" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written


DUEL_PLATE_ORIGIN = (12, 24)   # the field plate's screen-space origin (duel_init_scene: ConfigureSpriteAtPosition at (12, 24), resource (4, 2, terrain))


def bake_duel_plate(wa: bytes, exe: bytes, output: Path) -> int:
    """The field plate of each terrain ("FIELD" over the terrain's name, or "FIELD" alone for terrain 0): the duel's screen-space
    object at (12, 24) with resource (4, 2, terrain) from the resident duel module at 0x801AC000 (the same bank the life-point panel
    uses). Its page is 11 (VRAM x 704) and its CLUT row 252 at x 720 (the texture word 732: x = 732 & 0x3F0, row = 0xF0 + 732 & 0xF),
    4 bits a texel, from the boot UI image and the boot palette rows the duel keeps loaded. Written as duel_field/plate_<terrain>.png
    cut to its opaque box, and duel_field/plate.json holds each box's screen position."""
    import json
    tail = exe[0x801AC000 - LOAD + HEADER:0x801AC000 - LOAD + HEADER + 0x10000]
    vram = Vram()
    vram.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * SECTOR], 640, 0)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    layout, written = {}, 0
    for terrain in range(DUEL_TERRAIN_COUNT):
        canvas = bytearray(SCREEN_W * SCREEN_H * 4)
        draw_object(vram, tail, resolve_stream(tail, 4, 2, terrain), DUEL_PLATE_ORIGIN[0], DUEL_PLATE_ORIGIN[1], 11, 720, 252, False, canvas, cell_offset=False)
        cut = cropped(bytes(canvas), SCREEN_W, SCREEN_H, 0)
        if cut is None:
            continue
        data, ox, oy = cut
        written += bool(write_output(output / "duel_field" / f"plate_{terrain}.png", data, output))
        layout[str(terrain)] = {"x": ox, "y": oy}
    written += bool(write_output(output / "duel_field" / "plate.json", json.dumps(layout, indent=1) + "\n", output))
    return written


CARD_FACE_KINDS = ("monster", "magic", "equip", "trap", "ritual")   # the frame colour: monster 241, magic and equip 242, trap 243, ritual 244


# ---- story busts -------------------------------------------------
BUST_FIRST_SECTOR, BUST_SECTORS, BUST_COUNT = 15182, 50, 0x41   # WA sector of bust id n: n * 50 + 15182 (the routine at 0x8003A560)
BUST_X, BUST_Y = (0x68, 0xD8), 0xB2                              # resting position of the left and right slot
BUST_PAGE, BUST_CLUT = 0x1D, (512, 240)                          # the left slot's texture page (VRAM 832, 256) and palette block
BUST_EXPRESSIONS, BUST_VARIANTS = 16, 8                          # the show-menu nibble, and the glyph kinds 0 to 7 the mouth takes


def bust_stream_start(bank: bytes, expression: int, layer: int, variant: int) -> int:
    """The stream of a bust layer: the bank's three tables of u16 offsets (expression, then layer, then variant), each offset counted
    from the bank's start. 0 when a table has no entry there, as the game's own lookup reads it."""
    def u16(at):
        return struct.unpack_from("<H", bank, at)[0] if 0 <= at and at + 2 <= len(bank) else 0
    group = u16(expression * 2)
    if not group:
        return 0
    table = u16(group + layer * 2)
    if not table:
        return 0
    return u16(table + variant * 2)


def bust_stream_commands(bank: bytes, start: int, limit: int = 64):
    """The commands of a stream read straight through, as (hold, u16 frame offset) pairs, and the control opcode that ends them
    (0xF0 or more; None when the stream runs past the bank)."""
    commands, at = [], start
    while len(commands) < limit and at + 3 <= len(bank) and bank[at] < 0xF0:
        commands.append((bank[at], struct.unpack_from("<H", bank, at + 1)[0]))
        at += 3
    return commands, (bank[at] if at < len(bank) else None)


def bust_frames_of(bank: bytes, start: int) -> set:
    """Every frame offset a stream can show, following its jumps (the states are (stream base, offset) pairs, as the game's
    stream cursor keeps them; the random jump is followed to each of its targets)."""
    def u16(at):
        return struct.unpack_from("<H", bank, at)[0] if 0 <= at and at + 2 <= len(bank) else 0
    frames, todo, seen = set(), [(start, 0)], set()
    while todo and len(seen) < 4096:
        base, off = todo.pop()
        if (base, off) in seen or base + off >= len(bank):
            continue
        seen.add((base, off))
        at = base + off
        op = bank[at]
        if op < 0xF0:
            frames.add(u16(at + 1))
            todo.append((base, off + 3))
        elif op == 0xFE:
            todo.append((base, 0))
        elif op in (0xFC, 0xFB):
            todo.append((u16(at + 1), 0))
        elif op == 0xFA:
            todo.extend((u16(at + 2 + 2 * i), 0) for i in range(bank[at + 1]))
        elif op == 0xF9:
            todo.append((base + 4, off))
    return frames


def bust_frame(vram: Vram, bank: bytes, offset: int):
    """One frame of a bust layer (its sprite sheet of cells) rasterised as the console draws its 8-bit cells, with the object's origin
    at (0, 0). Returns (left, top, width, height, classes, colours) over the box the cells cover (left and top are the box's corner
    relative to the origin): the class is the texel's alpha in the baked picture, 255 an opaque colour, 128 a colour with the palette's
    semi-transparency bit (blended as the average with what is behind), 64 a texel of index not 0 whose colour is 0 (only the fade copies
    draw it), 32 a texel of index 0 that no other cell covers (transparent, drawn only by the fade copy that uses the palette's second
    row; its colour is that row's entry 0), 0 nothing. Colours are 15-bit palette words. None when the frame has no cell."""
    flags, tpage, clut_attr, parts = parts_of(bank, offset)
    if not parts:
        return None
    left = min(part[0] for part in parts)
    top = min(part[1] for part in parts)
    width = max(part[0] + part[4] for part in parts) - left
    height = max(part[1] + part[5] for part in parts) - top
    classes, colours, covered = [0] * (width * height), [0] * (width * height), bytearray(width * height)
    words = vram.words
    base_page = BUST_PAGE + tpage * 2
    base_cx = BUST_CLUT[0] + (clut_attr & 0xF) * 16
    base_cy = BUST_CLUT[1] + (clut_attr >> 4)
    zero = words[((base_cy + 1) & 511) * 1024 + (base_cx & 1023)]
    for dx, dy, u, v, w, h, cell, cell_size in reversed(parts):
        part_page, cy = base_page, base_cy
        if flags & 0xE0:
            part_page += (cell >> 9) & 0xE
            cy = base_cy + (cell_size & 0x1F)
        page_x, page_y = (part_page & 0xF) * 64, ((part_page >> 4) & 1) * 256
        clut_row = (cy & 511) * 1024
        us = [u + (w - 1 - i if cell & 0x2000 else i) for i in range(w)]
        cols = [dx - left + i for i in range(w)]
        for j in range(h):
            row = ((page_y + ((v + j) & 0xFF)) & 511) * 1024
            base = (dy - top + j) * width
            for i in range(w):
                uu = us[i]
                # the VRAM wraps at its edges, which only a stream's garbage reaches
                word = words[row + ((page_x + ((uu & 0xFF) >> 1)) & 1023)]
                index = (word >> (8 * (uu & 1))) & 0xFF
                at = base + cols[i]
                covered[at] = 1
                if index:
                    colour = words[clut_row + ((base_cx + index) & 1023)]
                    classes[at] = 64 if colour == 0 else (128 if colour & 0x8000 else 255)
                    colours[at] = colour
    for at in range(width * height):
        if covered[at] and not classes[at]:
            classes[at] = 32
            colours[at] = zero
    return left, top, width, height, classes, colours


def bake_busts(wa: bytes, output: Path) -> int:
    """The speaker busts a dialog's F6 command (ids below 0x41) shows. A bust is 50 sectors: a 192-word x 256-row 8-bit image
    (uploaded to VRAM (832, 256) for the left slot), a 256 x 2 palette block (512, 240) and the one-sector bank of the layer streams
    (a table of u16 offsets: expression, layer, variant, then the streams of (hold, frame offset) commands and their control opcodes).
    Every frame any stream of the bust can show is written as story/busts/<id>_<frame offset, 4 hex digits>.png: RGBA with the
    class of each pixel in its alpha (see bust_frame) and its colour in RGB. story/busts/layout.json holds per bust the bank (base64),
    each frame's file and origin (relative to the object's position), and the streams and the idle selections the port reads (the
    blink's open and closed streams and the mouth's four)."""
    import base64, json
    written, layout = 0, {}
    for ident in range(1, BUST_COUNT):
        base = (BUST_FIRST_SECTOR + ident * BUST_SECTORS) * SECTOR
        if base + BUST_SECTORS * SECTOR > len(wa):
            break
        record = wa[base:base + BUST_SECTORS * SECTOR]
        if not any(record[:0x18000]):
            continue
        vram = Vram()
        vram.upload_tiles(record[:0x18000], 832, 256)   # 48 sectors: three 16-sector columns of 64 words x 256 rows
        vram.upload_rect(record[0x18000:0x18400], 512, 240, 256, 2)
        bank = record[0x18800:0x19000]
        streams, selections, frame_offsets = {}, {}, set()
        for expression in range(BUST_EXPRESSIONS):
            if not bust_stream_start(bank, expression, 0, 0):
                continue
            chosen = {}
            for layer in range(3):
                for variant in range(BUST_VARIANTS):
                    start = bust_stream_start(bank, expression, layer, variant)
                    if not start or start >= len(bank):
                        continue
                    commands, end = bust_stream_commands(bank, start)
                    key = f"{expression}.{layer}.{variant}"
                    streams[key] = {"start": start, "commands": [[hold, frame] for hold, frame in commands],
                                    "end": None if end is None else f"{end:02x}"}
                    frame_offsets |= bust_frames_of(bank, start)
                    chosen[(layer, variant)] = key
            selections[str(expression)] = {"blink": {"open": chosen.get((1, 0)), "closed": chosen.get((1, 1))},
                                           "mouth": [chosen.get((2, variant)) for variant in range(4)]}
        if not streams:
            continue
        frames = {}
        for offset in sorted(frame_offsets):
            drawn = None
            if offset + 4 <= len(bank) and offset + 4 + bank[offset] * 6 <= len(bank):
                drawn = bust_frame(vram, bank, offset)
            if drawn is None:
                frames[str(offset)] = {"file": None, "origin": [0, 0]}   # not a sprite sheet inside the bank: nothing is drawn
                continue
            left, top, width, height, classes, colours = drawn
            # the picture is cut to the texels that are not class 0
            rows = [y for y in range(height) if any(classes[y * width:(y + 1) * width])]
            if not rows:
                frames[str(offset)] = {"file": None, "origin": [0, 0]}
                continue
            columns = [x for x in range(width) if any(classes[y * width + x] for y in rows)]
            x0, x1, y0, y1 = columns[0], columns[-1], rows[0], rows[-1]
            pixels = bytearray()
            for y in range(y0, y1 + 1):
                for x in range(x0, x1 + 1):
                    at = y * width + x
                    cls = classes[at]
                    if cls:
                        colour = colours[at]
                        pixels += bytes((((colour & 31) << 3), ((colour >> 5) & 31) << 3,
                                         ((colour >> 10) & 31) << 3, cls))
                    else:
                        pixels += b"\0\0\0\0"
            name = f"{ident:02d}_{offset:04x}.png"
            written += bool(write_output(output / "story" / "busts" / name, png(x1 - x0 + 1, y1 - y0 + 1, bytes(pixels)), output))
            frames[str(offset)] = {"file": name, "origin": [left + x0, top + y0]}
        layout[f"{ident:02d}"] = {"bank": base64.b64encode(bytes(bank)).decode("ascii"),
                                  "frames": frames, "streams": streams, "selections": selections}
    written += bool(write_output(output / "story" / "busts" / "layout.json", json.dumps(layout, separators=(",", ":")) + "\n", output))
    return written


# ---- text --------------------------------------------------------
LOAD, HEADER = 0x80010000, 0x800
BOOT_UI = 0xB48000            # WA_MRG.MRG: 48 sectors of the boot UI image
RAMPS = 0xB61000              # 16 colours x 8 rows
GLYPH_WORDS, STRING_OFFSETS, STRING_BANK = 0x801D9000, 0x801C0000, 0x801B0000
STRING_COUNT = 0xF00
SYMBOLS = [0x8149, 0x8168, 0x8194, 0x8190, 0x8193, 0x8195, 0x8166, 0x8169, 0x816A, 0x8196, 0x817B, 0x8143, 0x817C, 0x8144,
           0x815E, 0x8146, 0x8147, 0x8183, 0x8181, 0x8184, 0x8148, 0x8140, 0x83BF, 0x83C0, 0x81C1, 0x81A9, 0x81A8, 0x81BC, 0x81BD]
SPECIAL = {0x83BF: (208, 152, 0), 0x83C0: (224, 152, 0), 0x81C1: (240, 152, 0), 0x81A9: (176, 120, 0), 0x81A8: (192, 120, 0),
           0x81BC: (224, 120, 2), 0x81BD: (240, 120, -2)}


def cell_of(code: int):
    """(u, v, shift) of a glyph on the font page, from its Shift-JIS code."""
    code = {0x8171: 0x8183, 0x8173: 0x8183, 0x8172: 0x8184, 0x8174: 0x8184}.get(code, code)
    if 0x824F <= code < 0x824F + 76:
        if 0x8259 <= code < 0x8260 or 0x827A <= code < 0x8281:
            return 0, 120, 0
        return (code & 0xF) << 4, (((code - 0x8240) >> 4) << 4) + 72, 0
    if code in SYMBOLS:
        i = SYMBOLS.index(code)
        if i < 15:
            return i << 4, 72, 0
        if i < 22:
            return (i << 4) - 96, 88, 0
        return SPECIAL[code]
    return 0, 120, 0


def small_cell_of(code: int):
    """(u, v) of a glyph in the 8x12 font on the same page (what text boxes use by default)."""
    code = {0x8171: 0x8183, 0x8173: 0x8183, 0x8172: 0x8184, 0x8174: 0x8184}.get(code, code)
    if 0x824F <= code < 0x824F + 76:
        if 0x8259 <= code < 0x8260 or 0x827A <= code < 0x8281:
            return 0, 0x30
        return (code & 0xF) * 8, ((code - 0x8240) >> 4) * 12
    if code in SYMBOLS:
        i = SYMBOLS.index(code)
        if i < 15:
            return i * 8, 0
        if i < 22:
            return i * 8 - 0x30, 0xC
        return {0x83BF: (0x68, 0x3C), 0x83C0: (0x70, 0x3C), 0x81C1: (0x78, 0x3C)}.get(code, (0, 0x30))
    return 0, 0x30


def font_page(wa: bytes) -> Vram:
    vram = Vram()
    vram.upload_tiles(wa[BOOT_UI:BOOT_UI + 48 * 2048], 640, 0)
    vram.upload_rect(wa[RAMPS:RAMPS + 256], 640, 232, 16, 8)
    return vram


def _string_at(exe: bytes, start: int):
    """The bytes of one string from `start` through its 0xFF end: F0-F5 and F8 take one operand byte that may itself be 0xFF; FB, F9
    and friends are read by the interpreter."""
    end = start
    while end < len(exe) and exe[end] != 0xFF and end - start < 2048:
        end += 2 if exe[end] in (0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF8) else 1
    return list(exe[start:end + 1])


def export_text(wa: bytes, exe: bytes, output: Path) -> int:
    at = lambda a: a - LOAD + HEADER
    written = 0
    vram = font_page(wa)
    for ramp in range(7):
        pixels = bytearray(256 * 256 * 4)
        for y in range(256):
            for x in range(256):
                colour = vram.colour(640, 232 + ramp, vram.texel4(640, 0, x, y))
                if colour:
                    pixels[(y * 256 + x) * 4:(y * 256 + x) * 4 + 4] = rgba(colour)
        written += bool(write_output(output / "font" / f"ramp_{ramp}.png", png(256, 256, bytes(pixels)), output))
    # the 8 by 8 font (the F8 04 1 cell of the result pages): page 11 = VRAM (704, 0) on the same boot picture, its cells at
    # u = 128 + 8 * low nibble and v = 8 * high nibble of the glyph's tiny code (glyph word bits 20 to 27), in the CLUT row 250 at
    # x = 656 + 16 * colour; written as font/tiny_<colour>.png, a 128 by 128 picture of the cells (texel 0 is transparent)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    for colour_slot in range(7):
        pixels = bytearray(128 * 128 * 4)
        for y in range(128):
            for x in range(128):
                index = vram.texel4(704, 0, 128 + x, y)
                colour = vram.colour(656 + 16 * colour_slot, 250, index) if index else 0
                if colour:
                    pixels[(y * 128 + x) * 4:(y * 128 + x) * 4 + 4] = rgba(colour)
        written += bool(write_output(output / "font" / f"tiny_{colour_slot}.png", png(128, 128, bytes(pixels)), output))
    words = struct.unpack_from("<240I", exe, at(GLYPH_WORDS))
    glyphs = []
    for word in words:
        sjis = word & 0xFFFF
        u, v, shift = cell_of(sjis)
        small_u, small_v = small_cell_of(sjis)
        # talk: the mouth kind a speaker bust takes while this glyph is printed (the word's high halfword, low three bits)
        # tiny: the glyph's cell in the 8 by 8 font, as (tiny & 15) * 8 and (tiny >> 4) * 8 (the cell the 8 by 8 text draws)
        glyphs.append({"sjis": sjis, "u": u, "v": v, "shift": shift, "su": small_u, "sv": small_v, "talk": (word >> 16) & 7,
                       "tiny": (word >> 20) & 0xFF})
    strings = {}
    offsets = struct.unpack_from(f"<{STRING_COUNT}H", exe, at(STRING_OFFSETS))
    for index, offset in enumerate(offsets):
        strings[index] = _string_at(exe, at(STRING_BANK | offset))
    # the global strings (ids 0x8000 and up) are u16 offsets from TEXT_BASE in the table at TEXT_INDEX: the Free Duel opponents' names
    # are 0x8328 + cell, and the table is read through 0x8400
    for index, offset in enumerate(struct.unpack_from("<1025H", exe, at(TEXT_INDEX))):
        strings[0x8000 + index] = _string_at(exe, at(TEXT_BASE + offset))
    # the card names are the global strings 0x8000 + card id (above); the card descriptions are string ids 0xD100 + card id: the
    # offset of entry 0x100 + card id in the table at 0x801C0000, counted from that same address (not from the 0x801B0000 bank)
    for card_id in range(1, CARD_COUNT + 1):
        strings[0xD100 + card_id] = _string_at(exe, at(STRING_OFFSETS + offsets[0x100 + card_id]))
    written += bool(write_output(output / "text.json", json.dumps({"glyphs": glyphs, "strings": strings, "offsets": list(offsets)}, separators=(",", ":")), output))
    # the whole 64 KB string bank: stories jump (FC/FD) to offsets inside it
    bank_at = at(STRING_BANK)
    written += bool(write_output(output / "text_bank.bin", exe[bank_at:bank_at + 0x10000], output))
    # the 64 KB window the global strings (ids 0x8000 and up) live in: their flag jumps and stream jumps are offsets into it
    global_at = at(TEXT_BASE)
    written += bool(write_output(output / "text_bank_global.bin", exe[global_at:global_at + 0x10000], output))
    return written


# ---- audio -------------------------------------------------------
LINKS = (1, 0, 2)                    # the shared effects, resident effects, then the frontend's (a later link's id overrides an earlier one)
PENDING_IDS_OFFSET, PENDING_NOTES_OFFSET, PENDING_CAPACITY, PENDING_NONE = 0x08, 0x1A0, 204, 0xFFFF
SAMPLE_NOTE = 0x3C00                 # the voice sample note set by the voice state setup
BASE_RATE, NOTE_UNITS_PER_OCTAVE = 44100, 1536
FILTERS = ((0, 0), (60, 0), (115, -52), (98, -55), (122, -60))   # PS1 ADPCM predictor, in 1/64 units


def _layout(se):
    """Returns (step, links) with links as (sector offset, size) pairs read from sectors 0 and 1."""
    count = struct.unpack_from("<H", se, 2)[0]
    step = -(-count * 8 // SECTOR) + 1
    links = [struct.unpack_from("<HHI", se, SECTOR + i * 8)[::2] for i in range(count)]
    return step, links


def _link_notes(se, link):
    """Maps each SE id of one link to (pitch, sample start, chunk end) within SD_SE.DAT."""
    step, links = _layout(se)
    if link >= len(links):
        return {}
    offset, size = links[link]
    start = (step + offset) * SECTOR
    block = start + -(-size // SECTOR) * SECTOR
    count = min(struct.unpack_from("<I", se, block)[0], PENDING_CAPACITY)
    keys = struct.unpack_from("<%dH" % count, se, block + PENDING_IDS_OFFSET)
    notes = {}
    for i, key in enumerate(keys):
        if key == PENDING_NONE:
            continue
        pitch, start_units = struct.unpack_from("<HH", se, block + PENDING_NOTES_OFFSET + i * 8 + 4)
        notes[key] = (pitch, start + start_units * 16, block)
    return notes


def _adpcm(se, pos, limit):
    """Decodes PS1 ADPCM frames from pos until a frame carries the end flag (bit 0) or limit is reached."""
    out, old, older = [], 0, 0
    while pos + 16 <= limit:
        header, flags = se[pos], se[pos + 1]
        shift = header & 0x0F if (header & 0x0F) <= 12 else 9
        k0, k1 = FILTERS[header >> 4] if (header >> 4) < len(FILTERS) else (0, 0)
        for byte in se[pos + 2:pos + 16]:
            for nibble in (byte & 0x0F, byte >> 4):
                value = ((nibble - 16 if nibble >= 8 else nibble) << 12) >> shift
                value += (k0 * old + k1 * older + 32) >> 6
                value = max(-32768, min(32767, value))
                out.append(value)
                older, old = old, value
        if flags & 1:
            break
        pos += 16
    return out


def _rate(pitch):
    """Playback rate of a note relative to the 0x3C00 sample note, as the SDK's note_to_pitch computes it."""
    def units(note):
        return ((note >> 8) << 7) + (note & 0xFF)
    return round(BASE_RATE * 2 ** ((units(pitch) - units(SAMPLE_NOTE)) / NOTE_UNITS_PER_OCTAVE))


def _wav(samples, rate):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))
    return buf.getvalue()


def export_audio(se: bytes, output: Path) -> int:
    output = Path(output)
    notes = {}
    for link in LINKS:
        notes.update(_link_notes(se, link))
    written, index = 0, {}
    for se_id in sorted(notes):
        pitch, offset, end = notes[se_id]
        samples = _adpcm(se, offset, end)
        rate = _rate(pitch)
        name = "%03d.wav" % se_id
        written += bool(write_output(output / name, _wav(samples, rate), output))
        index[str(se_id)] = {"file": name, "rate": rate}
    write_output(output / "index.json", json.dumps(index, indent=1) + "\n", output)
    return written


# ---- opening movie (the boot's STR) ------------------------------
MOVIE_TABLE = 0x8009151C        # the executable's movie stream range table: u16 sector count, u16 end frame, per movie
MOVIE_XA_K0, MOVIE_XA_K1 = (0, 60, 115, 98), (0, 0, -52, -55)
MOVIE_RL_CODE = [0x3, 0x4, 0x5, 0x6, 0x26, 0x21, 0xa, 0x1d, 0x18, 0x13, 0x10, 0x1a, 0x19, 0x18, 0x17, 0x1f,
    0x1e, 0x1d, 0x1c, 0x1b, 0x1a, 0x19, 0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, 0x10, 0x18,
    0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, 0x10, 0x3, 0x6, 0x25, 0xc, 0x1b, 0x16, 0x15, 0x1f,
    0x1e, 0x1d, 0x1c, 0x1b, 0x1a, 0x19, 0x13, 0x12, 0x11, 0x10, 0x5, 0x4, 0xb, 0x14, 0x14, 0x7,
    0x24, 0x1c, 0x13, 0x6, 0xf, 0x12, 0x7, 0x9, 0x12, 0x5, 0x1e, 0x14, 0x4, 0x15, 0x7, 0x11,
    0x5, 0x11, 0x27, 0x10, 0x23, 0x1a, 0x22, 0x19, 0x20, 0x18, 0xe, 0x17, 0xd, 0x16, 0x8, 0x15,
    0x1f, 0x1a, 0x19, 0x17, 0x16, 0x1f, 0x1e, 0x1d, 0x1c, 0x1b, 0x1f, 0x1e, 0x1d, 0x1c, 0x1b]
MOVIE_RL_LEN = [2, 4, 5, 7, 8, 8, 10, 12, 12, 12, 12, 13, 13, 13, 13, 14,
    14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 15,
    15, 15, 15, 15, 15, 15, 15, 15, 3, 6, 8, 10, 12, 13, 13, 15,
    15, 15, 15, 15, 15, 15, 16, 16, 16, 16, 4, 7, 10, 12, 13, 5,
    8, 12, 13, 5, 10, 12, 6, 10, 13, 6, 12, 16, 6, 12, 7, 12,
    7, 13, 8, 13, 8, 16, 8, 16, 8, 16, 10, 16, 10, 16, 10, 16,
    12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 16, 16, 16, 16, 16]
MOVIE_RL_RUN = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3,
    3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 8, 8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31]
MOVIE_RL_LEVEL = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
    33, 34, 35, 36, 37, 38, 39, 40, 1, 2, 3, 4, 5, 6, 7, 8,
    9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 1,
    2, 3, 4, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 1, 2,
    1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
MOVIE_ZIGZAG = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
MOVIE_QUANT = [2, 16, 19, 22, 26, 27, 29, 34, 16, 16, 22, 24, 27, 29, 34, 37,
    19, 22, 26, 27, 29, 34, 34, 38, 22, 22, 26, 27, 29, 34, 37, 40,
    22, 26, 27, 29, 32, 35, 40, 48, 26, 27, 29, 32, 35, 40, 48, 58,
    26, 27, 29, 34, 38, 46, 56, 69, 27, 29, 35, 38, 46, 56, 69, 83]
MOVIE_ESC, MOVIE_EOB = 111, 112


def movie_range(exe: bytes, index: int = 0):
    """(sector count, end frame) of movie `index` from the executable's table, which the movie's playback reads."""
    text_address = struct.unpack_from("<I", exe, 0x18)[0]
    return struct.unpack_from("<HH", exe, 0x800 + MOVIE_TABLE - text_address + index * 4)


def xa_audio(sectors):
    """Decodes the XA ADPCM audio sectors (4-bit) into (rate, interleaved stereo int16 samples)."""
    history = [[0, 0], [0, 0]]
    rate, left, right = 37800, [], []
    lanes = (left, right)
    for raw in sectors:
        coding = raw[19]
        if coding & 0x10:
            continue                       # 8-bit XA is not used by this disc
        stereo = coding & 1
        rate = 18900 if coding & 4 else 37800
        for group in range(18):
            data = raw[24 + group * 128:24 + (group + 1) * 128]
            for unit in range(8):
                channel = (unit & 1) if stereo else 0
                header = data[4 + unit]
                shift = header & 15
                if shift > 12:
                    shift = 9
                filt = (header >> 4) & 3
                k0, k1 = MOVIE_XA_K0[filt], MOVIE_XA_K1[filt]
                old, older = history[channel]
                for i in range(28):
                    nib = (data[16 + i * 4 + unit // 2] >> ((unit & 1) * 4)) & 15
                    value = (((nib - 16) if nib >= 8 else nib) << 12) >> shift
                    value += (k0 * old + k1 * older + 32) >> 6
                    value = max(-32768, min(32767, value))
                    older, old = old, value
                    lanes[channel].append(value)
                history[channel] = [old, older]
    if not right:
        right = left
    frames = [0] * (2 * len(left))
    frames[0::2], frames[1::2] = left, right
    return rate, frames


def movie_frames(raws):
    """The STR video frames of a run of raw sectors, as (frame number, width, height, MDEC bitstream), in stream order."""
    out, current = [], None
    u16 = lambda b, i: b[i] | (b[i + 1] << 8)
    for raw in raws:
        submode = raw[18]
        if submode & 0x04:
            continue                       # audio
        data = raw[24:24 + (2324 if submode & 0x20 else 2048)]
        if u16(data, 0) != 0x0160:
            continue
        index, count = u16(data, 4), u16(data, 6)
        if index == 0:
            current = {"frame": struct.unpack_from("<I", data, 8)[0], "width": u16(data, 16), "height": u16(data, 18), "bits": bytearray()}
        elif current is None:
            continue
        current["bits"] += data[32:]
        if index == count - 1:
            out.append((current["frame"], current["width"], current["height"], bytes(current["bits"])))
            current = None
    return out


def _mdec_clamp8(v):
    return 0 if v < 0 else 255 if v > 255 else v


def _mdec_round(x):
    return int(x + 0.5) if x >= 0 else -int(-x + 0.5)


def mdec_decode(bits: bytes, width: int, height: int) -> bytes:
    """Decodes one version 2 MDEC frame into RGBA8 (the same decoder as scripts/runner/mdec.gd, run once at extraction time)."""
    if not hasattr(mdec_decode, "tables"):
        lut = [MOVIE_ESC + 1] * 65536
        codes = MOVIE_RL_CODE + [1, 2]
        lens = MOVIE_RL_LEN + [6, 2]
        length_of, run_of, level_of = [0] * 113, [0] * 113, [0] * 113
        for i in range(113):
            shift = 16 - lens[i]
            base = codes[i] << shift
            for j in range(1 << shift):
                lut[base + j] = i
            length_of[i] = lens[i]
            if i < 111:
                run_of[i] = MOVIE_RL_RUN[i]
                level_of[i] = MOVIE_RL_LEVEL[i]
        cosine = [[(1.0 / math.sqrt(2.0) if u == 0 else 1.0) * 0.5 * math.cos((2 * x + 1) * u * math.pi / 16.0) for x in range(8)] for u in range(8)]
        mdec_decode.tables = (lut, length_of, run_of, level_of, cosine)
    lut, length_of, run_of, level_of, cosine = mdec_decode.tables
    n = len(bits) // 2 + 4
    padded = bits + b"\x00" * (2 * n - len(bits))
    words = [padded[2 * k] | (padded[2 * k + 1] << 8) for k in range(n)]

    def peek(pos):
        k = pos >> 4
        v = (words[k] << 16) | words[k + 1]
        return (v >> (16 - (pos & 15))) & 0xFFFF

    qscale = words[2]
    mbw, mbh = (width + 15) >> 4, (height + 15) >> 4
    aw, ah = mbw * 16, mbh * 16
    cw = aw >> 1
    yp = [0] * (aw * ah)
    cbp = [0] * (cw * (ah >> 1))
    crp = [0] * (cw * (ah >> 1))
    pos = 64

    def idct(coef):
        tmp = [0.0] * 64
        for v in range(8):
            for x in range(8):
                s = 0.0
                for u in range(8):
                    c = coef[v * 8 + u]
                    if c:
                        s += cosine[u][x] * c
                tmp[v * 8 + x] = s
        out = [0.0] * 64
        for y in range(8):
            for x in range(8):
                s = 0.0
                for v in range(8):
                    s += cosine[v][y] * tmp[v * 8 + x]
                out[y * 8 + x] = s
        return out

    def block(pos):
        coef = [0] * 64
        dc = peek(pos) >> 6
        pos += 10
        if dc >= 512:
            dc -= 1024
        coef[0] = dc * MOVIE_QUANT[0]
        k = 1
        while k < 64:
            e = lut[peek(pos)]
            pos += length_of[e]
            if e == MOVIE_EOB:
                break
            if e == MOVIE_ESC:
                k += peek(pos) >> 10
                pos += 6
                level = peek(pos) >> 6
                pos += 10
                if level >= 512:
                    level -= 1024
            else:
                k += run_of[e]
                level = level_of[e]
                if peek(pos) & 0x8000:
                    level = -level
                pos += 1
            if k >= 64:
                break
            r = MOVIE_ZIGZAG[k]
            coef[r] = (level * qscale * MOVIE_QUANT[r] + 4) >> 3
            k += 1
        return pos, coef

    for mb in range(mbw * mbh):
        mx = (mb // mbh) * 16
        my = (mb % mbh) * 16
        for b in range(6):
            pos, coef = block(pos)
            if not any(coef[1:]):
                values = [coef[0] / 8.0] * 64
            else:
                values = idct(coef)
            if b < 2:
                dst, stride, x0, y0 = (crp if b == 0 else cbp), cw, mx >> 1, my >> 1
            else:
                dst, stride = yp, aw
                x0, y0 = mx + ((b - 2) & 1) * 8, my + ((b - 2) >> 1) * 8
            for y in range(8):
                row = (y0 + y) * stride + x0
                for x in range(8):
                    dst[row + x] = _mdec_clamp8(_mdec_round(values[y * 8 + x]) + 128)
    rgba = bytearray(width * height * 4)
    for py in range(height):
        for px in range(width):
            yy = yp[py * aw + px]
            ci = (py >> 1) * cw + (px >> 1)
            cb = cbp[ci] - 128
            cr = crp[ci] - 128
            o = (py * width + px) * 4
            rgba[o] = _mdec_clamp8(_mdec_round(yy + 1.402 * cr))
            rgba[o + 1] = _mdec_clamp8(_mdec_round(yy - 0.344136 * cb - 0.714136 * cr))
            rgba[o + 2] = _mdec_clamp8(_mdec_round(yy + 1.772 * cb))
            rgba[o + 3] = 255
    return bytes(rgba)


def _decode_movie_frame(job):
    number, width, height, bits = job
    return number, png(width, height, mdec_decode(bits, width, height))


def export_movie(disc, exe: bytes, output: Path) -> int:
    """The boot's opening movie (movie 0 of MOVIE.STR), pre-decoded: frames/fNNNN.png (frame 1 to the end frame, 320 x 240, 15 a second)
    and the XA audio of the same sectors as opening.wav (16-bit stereo). opening.json gives the frame count."""
    output = Path(output)
    lba, size = disc.find("DATA/MOVIE.STR")
    count, end_frame = movie_range(exe, 0)
    if count * 2048 > size + 2047:
        raise ValueError("the first movie runs past the end of MOVIE.STR")
    raws = [disc.raw_sector(lba + i) for i in range(count)]
    audio = [r for r in raws if r[18] & 0x04]
    if audio:
        audio = [r for r in audio if r[16:18] == audio[0][16:18]]   # one audio stream: the first audio sector's file and channel
    rate, samples = xa_audio(audio)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))
    written = bool(write_output(output / "opening.wav", buf.getvalue(), output))
    jobs = [job for job in movie_frames(raws) if job[0] <= end_frame]
    from concurrent.futures import ProcessPoolExecutor
    with ProcessPoolExecutor(max_workers=max(1, (os.cpu_count() or 2) - 1)) as pool:
        for number, data in pool.map(_decode_movie_frame, jobs, chunksize=4):
            written += bool(write_output(output / "frames" / ("f%04d.png" % number), data, output))
    write_output(output / "opening.json", json.dumps({"frames": len(jobs), "fps": 15, "end_frame": end_frame, "audio_rate": rate, "size": [320, 240]}, indent=1) + "\n", output)
    return written

# ---- background music (DATA/SD_BGM.DAT) --------------------------
BGM_RATE = 44100                     # VAG playback rate at the base pitch; tones.json keeps each tone's centre note and fine shift
BGM_CLASS = 0x7000                   # the class nibble the game adds to a track id; the key is the id's low 12 bits
BGM_HEADER_OFFSET = 0x50             # the VAB header (pBAV) starts this far into a package's header block
BGM_SEQUENCE_TAG = b"pQES"           # the sequence tag as stored on disc (a little-endian word)
BGM_END_OF_TRACK = b"\xff\x2f\x00"


BGM_BANK_VOLUME_AT = 0x7F8           # the "VolInfo" signature in the package table's last entry (bank information); the byte after it is the bank volume


def _bgm_bank_volume(bgm):
    """The bank's volume: the mixer-out staging buffer's signature block (the game reads it into its master level before it plays
    music; the driver's default is 0xD2 when no block is found)."""
    block = bgm[BGM_BANK_VOLUME_AT:BGM_BANK_VOLUME_AT + 8]
    return block[7] if block[:7] == b"VolInfo" else None


def _bgm_packages(bgm):
    """The package table at the start of SD_BGM.DAT: one 8-byte entry per package index, used only where a VAB header is found."""
    packages = []
    for index in range(256):
        entry = bgm[index * 8:index * 8 + 8]
        if len(entry) < 8:
            break
        body_sector = struct.unpack_from("<H", entry, 2)[0]
        header_sector = body_sector + entry[0]
        if header_sector == 0 or bgm[header_sector * SECTOR + BGM_HEADER_OFFSET:header_sector * SECTOR + BGM_HEADER_OFFSET + 4] != b"pBAV":
            continue
        packages.append({"index": index, "body_sector": body_sector, "header_sector": header_sector, "header_sectors": entry[1], "spu_address": struct.unpack_from("<I", entry, 4)[0]})
    return packages


def _bgm_tone(block, at):
    """One VagAtr record (32 bytes): the tone's volume, pan, centre note, fine shift, pitch and envelope, and the VAG it plays."""
    return {
        "priority": block[at], "mode": block[at + 1], "volume": block[at + 2], "pan": block[at + 3],
        "center": block[at + 4], "shift": struct.unpack_from("<b", block, at + 5)[0],
        "min": block[at + 6], "max": block[at + 7], "vib_width": block[at + 8], "vib_time": block[at + 9],
        "portamento_width": block[at + 10], "portamento_time": block[at + 11],
        "pitch_bend_min": block[at + 12], "pitch_bend_max": block[at + 13], "reserved": block[at + 14:at + 16].hex(),
        "adsr1": struct.unpack_from("<H", block, at + 16)[0], "adsr2": struct.unpack_from("<H", block, at + 18)[0],
        "prog": struct.unpack_from("<h", block, at + 20)[0], "vag": struct.unpack_from("<h", block, at + 22)[0],
    }


def _bgm_vag(bgm, at, size):
    """Decodes one VAG body (PS1 ADPCM, 16-byte frames) up to its end flag; returns (info, samples). The loop is set by the frames' flags: the
    first frame with the loop-start flag (bit 2) is the loop start (0 when none), and the sample loops back there at the end frame when that
    frame has the repeat flag (bit 1). loop_start and loop_end are sample indexes, both None for a one-shot sample."""
    samples = _adpcm(bgm, at, at + size)
    frames = len(samples) // 28
    ended = frames > 0 and bool(bgm[at + 16 * (frames - 1) + 1] & 1)
    repeats = frames > 0 and bool(bgm[at + 16 * (frames - 1) + 1] & 2)
    starts = [j for j in range(frames) if bgm[at + 16 * j + 1] & 4]
    loop_start = (starts[0] * 28 if starts else 0) if repeats else None
    loop_end = len(samples) if repeats else None
    return {"frames": frames, "samples": len(samples), "end_flag": ended, "loop_start": loop_start, "loop_end": loop_end}, samples


def _bgm_package(bgm, package):
    """Parses one package: its header block (sequence records, VAB programs, tones and VAG sizes) and decodes its VAG bodies,
    which sit in their own region of the file (body_sector) and are uploaded to SPU RAM back to back from spu_address."""
    header_at = package["header_sector"] * SECTOR
    block = bgm[header_at:header_at + package["header_sectors"] * SECTOR]
    vab = BGM_HEADER_OFFSET
    ps, tn, vs = struct.unpack_from("<HHH", block, vab + 0x12)
    fsize = struct.unpack_from("<I", block, vab + 0x0C)[0]
    header_size = (ps << 9) + 0xA20
    prog_at = vab + 0x20
    tone_at = prog_at + 0x800
    units = struct.unpack_from("<%dH" % (vs + 1), block, vab + header_size - 0x200)
    programs = []
    for p in range(ps):
        pa = prog_at + 16 * p
        tones = [_bgm_tone(block, tone_at + p * 0x200 + t * 0x20) for t in range(min(block[pa], 16))]
        programs.append({"program": p, "tone_count": block[pa], "volume": block[pa + 1], "priority": block[pa + 2], "mode": block[pa + 3],
                         "pan": block[pa + 4], "attr": struct.unpack_from("<H", block, pa + 6)[0], "tones": tones})
    sequences = []
    count = struct.unpack_from("<H", block, 2)[0]
    starts = [struct.unpack_from("<H", block, 0x10 + 4 * i)[0] * 16 for i in range(count)]
    for s, start in enumerate(starts):
        end = min([r for r in starts if r > start] + [len(block)])
        chunk = block[start:end]
        tempo = struct.unpack_from(">I", chunk, 10)[0] >> 8 if len(chunk) >= 14 else 0
        eot = chunk.find(BGM_END_OF_TRACK)
        sequences.append({"index": s, "offset": start, "length": len(chunk), "tag_ok": chunk[:4] == BGM_SEQUENCE_TAG,
                          "timebase": struct.unpack_from(">H", chunk, 8)[0] if len(chunk) >= 10 else 0,
                          "tempo_us": tempo, "bpm": round(60000000 / tempo, 2) if tempo else None,
                          "first_end_of_track": eot if eot >= 0 else None, "chunk": chunk})
    body = package["body_sector"] * SECTOR
    cursor, offset, samples, info = body, 0, {}, {}
    for n in range(1, vs + 1):
        size = units[n] * 8
        if size:
            details, pcm = _bgm_vag(bgm, cursor, size)
            details.update({"vag": n, "bytes": size, "file": "samples/vag_%03d.wav" % n, "spu_address": package["spu_address"] + offset, "file_offset": cursor})
            info[n], samples[n] = details, pcm
        cursor += size
        offset += size
    return {"block": block, "programs": programs, "sequences": sequences, "vags": info, "samples": samples,
            "fsize": fsize, "vab_size": header_size, "body_bytes": offset, "body_end": body + offset}, samples


def export_bgm(bgm: bytes, output: Path) -> int:
    """Every background-music track as one folder named by its 12-bit key (package << 4 | sequence, three hex digits): seq.bin, tones.json and
    samples/vag_NNN.wav, plus index.json with the game ids, tempo and file names. The format is in docs/bgm-format.md."""
    output = Path(output)
    written = 0
    index = {"sample_rate": BGM_RATE, "class_nibble": "0x%X" % (BGM_CLASS >> 12), "tracks": {}, "packages": []}
    for package in _bgm_packages(bgm):
        parsed, samples = _bgm_package(bgm, package)
        index["packages"].append({"package": package["index"], "header_sector": package["header_sector"], "body_sector": package["body_sector"],
                                  "header_sectors": package["header_sectors"], "spu_address": package["spu_address"],
                                  "sequences": len(parsed["sequences"]), "vags": len(parsed["vags"]), "body_bytes": parsed["body_bytes"]})
        base = {"bank_volume": _bgm_bank_volume(bgm), "package": package["index"], "spu_address": package["spu_address"], "header_sector": package["header_sector"],
                "body_sector": package["body_sector"], "vab_size": parsed["vab_size"], "fsize": parsed["fsize"], "programs": parsed["programs"],
                "samples": {str(n): info for n, info in parsed["vags"].items()}}
        for seq in parsed["sequences"]:
            key = "%03X" % ((package["index"] << 4) | seq["index"])
            folder = output / key
            info = {k: v for k, v in seq.items() if k != "chunk"}
            written += bool(write_output(folder / "seq.bin", seq["chunk"], output))
            written += bool(write_output(folder / "tones.json", json.dumps(dict(base, sequence=info), indent=1) + "\n", output))
            for n, pcm in samples.items():
                written += bool(write_output(folder / "samples" / ("vag_%03d.wav" % n), _wav(pcm, BGM_RATE), output))
            index["tracks"][key] = {"game_id": "0x%04X" % (BGM_CLASS | int(key, 16)), "package": package["index"], "sequence": seq["index"],
                                    "timebase": seq["timebase"], "tempo_us": seq["tempo_us"], "bpm": seq["bpm"], "length": seq["length"],
                                    "files": {"seq": key + "/seq.bin", "tones": key + "/tones.json", "samples": key + "/samples/"}}
    written += bool(write_output(output / "index.json", json.dumps(index, indent=1) + "\n", output))
    return written


PASSWORD_PACKAGE = 0x1F2F * SECTOR   # WA_MRG.MRG: 86 sectors: 64 tile sectors at VRAM (768,256), 4 palette sectors at (256,240) (256 x 16), 3 card-table sectors, the module


def stream_entries(bank: bytes, f67: int, f68: int, f69: int):
    """A stream in play order as (hold, u16 frame offset, mirrored) entries. The stream may open with jumps: 0xFC continues at the
    u16 it names, 0xFB does the same and toggles the mirror (the walker of bake_map_sprites). It ends at a byte of 0xF0 or more."""
    u16 = lambda o: struct.unpack_from("<H", bank, o)[0]
    at, mirror, entries, seen = u16(u16(u16(f67 * 2) + f68 * 2) + f69 * 2), False, [], set()
    while at not in seen and bank[at] < 0xF0 or (bank[at] in (0xFB, 0xFC) and at not in seen):
        seen.add(at)
        if bank[at] in (0xFB, 0xFC):
            mirror ^= bank[at] == 0xFB
            at = u16(at + 1)
            continue
        entries.append((bank[at], u16(at + 1), mirror))
        at += 3
    return entries


def bake_stream_frames(vram: Vram, bank: bytes, stream, output: Path, name: str, page: int, clut_x: int, clut_y: int, cell_offset: bool, wide: bool = False, folder: str = "password") -> dict:
    """Every distinct frame of a resource stream (following its jumps), cut to its box and written as name_<k>.png (k in order of first
    use). A mirrored entry is the same frame reflected about the object's origin. The entry gives each frame's offset from the origin
    and the play order as [hold, frame] pairs (the stream loops back to its first entry)."""
    import json
    origin, size = 256, 512   # the frame is drawn on a 512 square with its origin at the centre, so it can be reflected about it
    frames, order = [], []
    for hold, offset, mirrored in stream_entries(bank, *stream):
        key = (offset, mirrored)
        if key not in frames:
            frames.append(key)
        order.append([hold, frames.index(key)])
    entry = {"frames": [], "order": order}
    for index, (offset, mirrored) in enumerate(frames):
        canvas = bytearray(size * size * 4)
        draw_object(vram, bank, offset, origin, origin, page, clut_x, clut_y, wide, canvas, 0, size, size, cell_offset=cell_offset)
        if mirrored:
            rows = [canvas[y * size * 4:(y + 1) * size * 4] for y in range(size)]
            canvas = bytearray(b"".join(bytes(b"".join(row[x * 4:x * 4 + 4] for x in range(size - 1, -1, -1))) for row in rows))
        cut = cropped(bytes(canvas), size, size, origin)
        if cut is None:
            entry["frames"].append({"x": 0, "y": 0})
            continue
        data, ox, oy = cut
        write_output(output / folder / f"{name}_{index}.png", data, output)
        entry["frames"].append({"x": ox, "y": oy, "file": f"{name}_{index}.png"})
    return entry


def bake_password(wa: bytes, exe: bytes, su: bytes, output: Path) -> int:
    """The password (shop) screen's own pictures, as its setup creates them: the digit cursor's 32 x 32 box (a screen sprite on page 30
    = VRAM (896,256) at UV (16,128), CLUT (256,240)); the starchip object at (152,40) (stream (0,2,3) of the resident tail table on
    page 31 = VRAM (960,256), CLUT (0,241) from the menu palette), an animated translucent panel of up to 320 x 210 pixels; and the
    digit arrows (streams (3,1,0), (3,1,1) and (3,1,3); page 11 = VRAM (704,0), CLUT (512,252) from the boot UI). The left arrow's
    stream starts with a jump the baker does not follow, so it is not baked. Each frame is cut to its box; layout.json gives each
    frame's offset from its object's origin and each stream's play order as [hold, frame] pairs."""
    import json
    vram = font_page(wa)
    vram.upload_rect(wa[BOOT_PALETTE:BOOT_PALETTE + 4096], 512, 248, 256, 8)
    vram.upload_tiles(wa[PASSWORD_PACKAGE:PASSWORD_PACKAGE + 64 * SECTOR], 768, 256)
    vram.upload_rect(wa[PASSWORD_PACKAGE + 64 * SECTOR:PASSWORD_PACKAGE + 68 * SECTOR], 256, 240, 256, 16)
    vram.upload_rect(su[96 * SECTOR:98 * SECTOR], 0, 240, 256, 8)
    base = 0x801AC000 - LOAD + HEADER
    bank = exe[base:base + 0x10000]
    cursor = bytearray(32 * 32 * 4)
    for y in range(32):
        for x in range(32):
            colour = vram.colour(256, 240, vram.texel4(896, 256, 16 + x, 128 + y))
            if colour:
                cursor[(y * 32 + x) * 4:(y * 32 + x) * 4 + 4] = rgba(colour)
    written = bool(write_output(output / "password" / "cursor.png", png(32, 32, bytes(cursor)), output))
    layout = {"cursor": {"width": 32, "height": 32}}
    layout["starchip"] = bake_stream_frames(vram, bank, (0, 2, 3), output, "starchip", 31, 0, 241, False)
    layout["arrows"] = [bake_stream_frames(vram, bank, (3, 1, i), output, f"arrow_{i}", 11, 512, 252, True) for i in range(4)]
    # the card preview's frame (the setup of the card's object on page 28 = VRAM (768,256), 8 bits a texel): the monster frame
    # is stream (1,0,0) with CLUT row 248; the magic, trap, ritual and equip frames are stream (1,0,1) with rows 249, 250, 251, 249
    layout["card_frame"] = {kind: bake_stream_frames(vram, bank, stream, output, f"card_frame_{kind}", 28, 256, row, False, wide=True)
                            for kind, stream, row in (("monster", (1, 0, 0), 248), ("magic", (1, 0, 1), 249), ("trap", (1, 0, 1), 250),
                                                      ("ritual", (1, 0, 1), 251), ("equip", (1, 0, 1), 249))}
    written += bool(write_output(output / "password" / "layout.json", json.dumps(layout, indent=1) + "\n", output))
    return written + sum(len(entry["frames"]) for entry in [layout["starchip"], *layout["arrows"]])


def find_disc(given):
    if given:
        return Path(given)
    if os.environ.get("FM_DISC"):
        return Path(os.environ["FM_DISC"])
    for folder in (ROOT, ROOT.parent, Path.cwd()):
        for pattern in ("*.cue", "*.bin"):
            hits = sorted(folder.glob(pattern))
            if hits:
                return hits[0]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("disc", nargs="?", help=".cue or .bin of your own USA disc (SLUS-01411)")
    parser.add_argument("-o", "--output", type=Path, default=ROOT / "assets", help="folder the output is written to (default: assets/ in this project)")
    for name, help_text in (("cards", "card data"), ("tables", "fusion, equip, ritual, duelist, terrain and trap tables"), ("images", "card art, thumbnails, frames, UI sprites"), ("screens", "boot, title and menu screens"), ("text", "font and strings"), ("audio", "menu sound effects as WAV"), ("movie", "the opening movie (STR) and its XA audio")):
        parser.add_argument("--" + name, action="store_true", help="extract " + help_text + " (default: everything)")
    parser.add_argument("--mod", action="append", default=[], metavar="FOLDER", help="a mod folder whose texture pack replaces the images (repeatable; default: every enabled folder under mods/)")
    parser.add_argument("--mod-off", action="append", default=[], metavar="KEY", help="turn one setting of the mods off (repeatable)")
    parser.add_argument("--no-mods", action="store_true", help="bake the disc's art only, ignoring mods/")
    parser.add_argument("--mods-only", action="store_true", help="apply the mods to the images already baked, without reading the disc")
    parser.add_argument("--hd", type=int, metavar="N", help="HD art: upscale the baked pictures N times (2 or 4) into mods/auto-hd/, without the disc (run the extraction first)")
    parser.add_argument("--hd-jobs", type=int, default=0, metavar="K", help="worker processes for --hd (default: every CPU but one)")
    add_flags(parser)
    args = parser.parse_args()
    apply_flags(args)
    if args.hd or "auto-hd" in args.mod_off:
        if args.hd and "auto-hd" in args.mod_off: sys.exit("--hd and --mod-off auto-hd cannot be used together")
        if args.hd: hd_pass(args.output, args.hd, args.hd_jobs)
        else: hd_disable()
        return
    mods = select_mods(args.mod, args.mod_off, args.no_mods)
    if args.mods_only:
        print(f"  images: {export_images({}, args.output / 'images', mods=mods)}")
        return
    path = find_disc(args.disc)
    if path is None or not path.exists():
        sys.exit("No disc image found. Pass the .cue or .bin of your USA disc: python tools/extract.py \"game.cue\"")
    out = args.output
    write_output(out / ".gdignore", b"", out)     # the editor skips the baked folder (it is large and not imported)
    every = ("cards", "tables", "images", "screens", "text", "audio", "movie")
    chosen = {name for name in every if getattr(args, name)} or set(every)
    with Disc(str(path)) as d:
        print(f"Reading {path}")
        exe = d.file("SLUS_014.11")
        wa = d.file("DATA/WA_MRG.MRG")
        su = d.file("DATA/SU.MRG")
        se = d.file("DATA/SD_SE.DAT") if "audio" in chosen else b""
        bgm = d.file("DATA/SD_BGM.DAT") if "audio" in chosen else b""
        mrg = d.file("DATA/MODEL.MRG") if "screens" in chosen else b""
        movie = export_movie(d, exe, out / "movies") if "movie" in chosen else 0
    if "cards" in chosen:
        print(f"  cards: {export_cards(exe, wa, out / 'data' / 'cards.json')}")
    if "tables" in chosen:
        print(f"  tables: {export_tables(exe, wa, out / 'data')}")
        print(f"  ai scripts: {export_ai_scripts(wa, out / 'data' / 'ai_scripts')}")
    if "images" in chosen:
        print(f"  images: {export_images({'WA_MRG.MRG': wa}, out / 'images', mods=mods)}")
    if "screens" in chosen:
        print(f"  screens: {bake(wa, out / 'screens') + bake_menu(su, out / 'screens') + bake_name_entry(wa, exe, out / 'screens') + bake_options(wa, su, exe, out / 'screens') + bake_story(wa, exe, out / 'screens') + bake_story_scenes(wa, exe, out / 'screens') + bake_dialog_arrow(wa, exe, out / 'screens') + bake_card_frame(wa, exe, out / 'screens') +bake_library(wa, out / 'screens') + bake_library2(wa, exe, out / 'screens') + bake_free_duel(wa, out / 'screens') + bake_map(wa, out / 'screens') + bake_busts(wa, out / 'screens') + bake_duel_result(wa, exe, out / 'screens') + bake_logo(wa, out / 'screens') + bake_build_deck(wa, exe, out / 'screens') + bake_credits(wa, su, exe, out / 'screens') + bake_game_over(wa, out / 'screens') + bake_duel_field(wa, exe, out / 'screens') + bake_duel_card_face(wa, out / 'screens') + bake_duel_plate(wa, exe, out / 'screens') + bake_password(wa, exe, su, out / 'screens') + bake_card_ui(wa, out / 'screens') + bake_backdrops(wa, exe, out / 'screens') + bake_rules(wa, su, out / 'screens') + bake_duel_hud(wa, exe, out / 'screens') + bake_star_icons(wa, exe, out / 'screens') + bake_race_icons(wa, exe, out / 'screens') + bake_button_glyphs(wa, out / 'screens') + bake_duel_cursors(wa, exe, out / 'screens') + bake_duel_band(wa, exe, out / 'screens') + bake_duel_numbers(wa, exe, out / 'screens') + bake_duel_effect_textures(wa, out / 'screens') + bake_duel_bar_icons(wa, out / 'screens') + bake_credits_monsters(mrg, out / 'screens')}")
    if "text" in chosen:
        print(f"  text: {export_text(wa, exe, out / 'screens')}")
    if "audio" in chosen:
        print(f"  audio: {export_audio(se, out / 'audio' / 'se')}")
        print(f"  music: {export_bgm(bgm, out / 'audio' / 'bgm')}")
    if "movie" in chosen:
        print(f"  movie: {movie}")
    if kept_summary():
        print(kept_summary())
    print(f"Done. Game data is in {out}")


if __name__ == "__main__":
    main()
