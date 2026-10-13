# Tools

The repo ships no game data. One script, `tools/extract.py`, reads your own USA disc (`SLUS-01411`) and writes the ignored `assets/`
folder. The disc is read once per run; a full run takes about 3 minutes and needs no game or emulator.

Requirements: Python 3.11+ (standard library only), Redot 26.2.

```
python tools/extract.py                          # finds a .cue/.bin next to the project (or FM_DISC) and extracts everything
python tools/extract.py "path/to/game.cue"
python tools/extract.py --screens --text         # only what you name
python tools/extract.py --mods-only              # re-apply the mods to images already baked, no disc needed
python tools/extract.py --help                   # every option, with its default
```

| Option | Effect |
| --- | --- |
| `disc` | the `.cue` or `.bin` of your disc. Default: the first `.cue` or `.bin` next to the project (or in its parent or the working folder), or the `FM_DISC` environment variable |
| `-o`, `--output DIR` | where the output goes (default: `assets/` in this project) |
| `--cards` | card data (`data/cards.json`) |
| `--tables` | fusion, equip, ritual, duelist, terrain, trap and starter-pool tables, and the duel AI scripts |
| `--images` | card art, thumbnails, frames and UI sprites as PNG |
| `--screens` | the boot, title, menu, story, map, duel, library, build deck and other screens, and the duel field models |
| `--text` | the font and the game's strings |
| `--audio` | menu sound effects as 16-bit mono WAV |
| (no section flag) | everything: a run with none of the section flags extracts all six sections |
| `--mod FOLDER` | a mod folder whose texture pack replaces the images; repeatable. Default: every enabled folder under `mods/` |
| `--mod-off KEY` | turn one setting of the mods off for this run; repeatable |
| `--no-mods` | bake the disc's art only, ignoring `mods/` |
| `--mods-only` | apply the mods to the images already baked, without reading the disc |
| `--hd N` | HD art: write `mods/auto-hd/`, the baked pictures upscaled N times (2 or 4), without the disc (see HD art below) |
| `--hd-jobs K` | worker processes for `--hd` (default: every CPU but one) |
| `--mod-off auto-hd` | turn the HD art off: `mods/auto-hd/mod.json` gets `"enabled": false`; its files stay on disk |
| `--overwrite` | replace every existing output |
| `--overwrite-only PATTERN` | replace the existing outputs matching a glob (relative to the output folder); repeatable |
| `--verbose` | also list each output that was kept |

| Output | Content |
| --- | --- |
| `assets/data/` | `cards.json` (the 722 cards), `fusions.json`, `equips.json`, `rituals.json`, `duelists.json`, `terrain.json`, `duel_rank.json`, `attack_traps.json`, `starter_pools.json`, and `ai_scripts/` (the duel AI's two scripts) |
| `assets/images/` | card art, thumbnails, frames and UI sprites as PNG |
| `assets/screens/` | the screens as PNG (one folder per screen), `text.json` (glyph table and strings), `text_bank.bin`, the font (one PNG per colour ramp), `duel_field/` (the terrain models and `layout.json`), `credits/monsters.bin` (the credits' wireframe monsters: every rollable model's coordinate units, polygons and part animation, zlib-compressed per model; the layout is in `encode_monster`, the animation reference in `monster_anim.py`, the player in `scripts/menu/credits_monsters.gd`) |
| `assets/audio/se/` | the menu sound effects as WAV, with `index.json` |
| `assets/.gdignore` | an empty file, so the Redot editor does not import the baked folder |

Nothing is overwritten unless asked. An existing output is kept, and the run says how many were kept (`--verbose` lists them). Running
the same command twice is safe: the second run keeps everything.

## Mods

Mods live in `mods/`, next to `project.godot`. The folder is git-ignored; nothing from it is committed. A mod is a folder with a `mod.json` manifest and the files it names. Extract a mod archive so that its `mods/<folder>/mod.json` ends up under this project's `mods/`, for example `mods/assets-hd/`.

Two kinds of mod content are used here:

| Key in `mod.json` | Used by | What it does |
| --- | --- | --- |
| `textures` (a folder with `manifest.json` and PNGs) | `tools/extract.py --images` | Each PNG replaces the baked image that reads the same disc bytes (archive, offset, size, depth, palette). The PNG is written under the baked name, its scale (PNG size / baked size) goes in `assets/mod_scales.json`, and the game draws it at 1/scale. |
| `fusions`, `equips`, `rituals`, `drops`, `decks`, `terrain_bonus`, `equip_bonus_default` | the game at run time (`scripts/duel/duel_data.gd`) | Rule changes laid over the disc's tables, read from `mods/` each time the duel data loads. Nothing is baked for them. |

Settings: a pack entry or rule with `"setting"` is used only while that setting is on. Both the extraction and the game use the mod's own defaults for them (there is no Mods window yet). `--mod-off KEY` turns one off for the extraction only.

Put an empty file named `.gdignore` in `mods/`, so the Redot editor does not import the mods' PNGs when it scans the project.

```
python tools/extract.py --images                 # the mods under mods/ are applied (every enabled folder)
python tools/extract.py --images --mod mods/assets-hd --mod-off duel
python tools/extract.py --images --no-mods       # the disc's art only
python tools/extract.py --mods-only              # re-apply the mods to images already baked, no disc needed
```

`--mods-only` only writes replacements; it cannot bake a disc picture back, so an image a changed mod set no longer replaces needs a run with the disc.

Images follow the mods in force: an image that the mods of a run no longer replace is baked from the disc again, so a `--no-mods` run puts the vanilla art back. `mod_scales.json` (in `assets/`) lists the replaced images and their scales and is rewritten every run that touches images.

The HD art pack (`textures`) covers card art, thumbnails and the card frames (1,624 of its 1,983 pictures). The duel's HUD, the Build Deck and Trade screens, the Free Duel and story portraits are not replaced yet: their pictures are baked by other functions than the catalog in `config/images.json`.

In the game, `scripts/system/mod_art.gd` returns a picture and its scale, and the card art, thumbnails and frames are drawn through it. The rule tables are read from `mods/*/mod.json` each time the duel data loads (at boot and for each duel). A rule that names a card, opponent or type the game does not have is skipped and printed as `mods: left out`.

Not read yet, and ignored: `bonus_if`, `bonus_attack`/`bonus_defense`, ritual tributes from the hand or conditions (a ritual takes plain tribute names from the field), `trap_thresholds` (the attack traps are fixed in `scripts/duel/duel_effects.gd`), `starter`, `cards`, `passwords`, `limits` and the other keys of the mod format.

## HD art (the `auto-hd` mod)

The baked pictures are 320 x 240 pixel art. `--hd N` writes a sharper copy of them to `mods/auto-hd/`, and the game draws that copy
at the same size as the baked picture, so each screen keeps its layout and its edges are finer on a large display.

```
python tools/extract.py                  # bake the disc first (it needs the disc)
python tools/extract.py --hd 4           # then the HD art, 4 times the baked size (for a 4K display); --hd 2 is the lighter copy
python tools/extract.py --mod-off auto-hd   # turn it off (the files stay; the game does not read them)
python tools/extract.py --hd 4           # on again
```

How it is made: each picture is upscaled by Scale2x (EPX), twice for 4. Scale2x only copies the colours of the picture's own pixels, so the
palette is kept exactly, a transparent pixel stays transparent, and the alpha values the speaker busts read (0, 32, 64, 128, 255) are
unchanged. Pixels of a picture are never blended; this is not a smoothing filter. The pictures are the baked ones under `images/` and
`screens/`, except: the 3D textures (`screens/duel_field/`, the map's `texture_*.png`), the glyph atlases (`screens/font/`, the text
banks), the opening movie and the data. A picture larger than 640 pixels on a side is already large and is left out.

What is written:

| Path | Content |
| --- | --- |
| `mods/auto-hd/mod.json` | the manifest: `"enabled"` (set by `--mod-off auto-hd` and `--hd`), `"tree": "assets"`, `"scales": "scales.json"` |
| `mods/auto-hd/assets/` | a mirror of `assets/`: the upscaled PNG of each picture, at the same path |
| `mods/auto-hd/scales.json` | for each picture (path under `assets/`): `scale` (2 or 4), and the baked `width` and `height` |
| `mods/.gdignore` | an empty file, so the editor does not import the mods' PNGs |

A run is resumable: a mirror picture that already has the right size is kept, so a second run only does the new or changed pictures. A
run with another N rewrites the pictures whose size is different. Measured here: 4,118 pictures at `--hd 2` took 37 seconds and 52 MB;
`--hd 4` (4,120 pictures) is 80.6 MB on disk.

In the game (`scripts/system/mod_art.gd`):

- `ModArt.texture(path)` returns the picture drawn at its baked size, from the mirror when the mod is on. Screens that draw a whole
  picture use it (the boot and title screens, the main menu, the options, the name entry, the free duel, the game over, the library,
  the build deck's digits and frames, the duel result, the story pictures and the speaker busts). Screens that cut a picture into
  regions (the password shop, the trade and the second card's backdrops) keep the baked pictures.
- `ModArt.load_art(path)` (the cards' art and thumbnails, and the duel's cards) uses the mirror too. Its texture reports the baked size through `get_size()` (the HD pixels are kept behind it) and its scale is 1, so every consumer lays out the same with the HD art on or off.
- Only a consumer that reads pixels or regions uses the baked pixels: `ModArt.base_image(path)` (the duel's card face is composed from the 40 x 32 thumbnail this way) and `ModArt.plain_texture(path)` (the story's logo panels are regions of their baked picture).
- The setting `hd_art` (the F9 options panel, "HD art where the mod is installed") turns the mirror off for the game: `user://settings.json`.
- A web export leaves `mods/auto-hd/` out (`export_presets.cfg`), so the browser draws the baked pictures.

## Picture options in the game

F5 cycles the picture's sampling: Pixel (nearest: hard edges), Sharp (the default: nearest texels with about one screen pixel of blend
on their edges), and Smooth (plain bilinear). F6 toggles faint scanlines (off by default). F2 switches between filling the window and the original 4:3 shape. F9 opens the
options panel (volume, fullscreen, stretch, V-sync, the picture, HD art). The choice is saved in `user://settings.json` and applies to
every screen at once, including the ones already open. The panel's "PS1 dithering on shaded 3D" option (off by default) applies the
console's 4x4 dither matrix at each colour step to the shaded pictures only: the duel's 3D board and the main menu's wall shade
(shaders/sharp_pixels.gdshader and shaders/dither_subtract.gdshader). Flat sprites and text never dither, as on the console. The touch controls have F5, F6 and F9 keys in a second row at the top middle.
The 3D campaign map is rendered at the window's own pixel size (`scripts/map/campaign_map.gd`), so its edges are the screen's pixels.
