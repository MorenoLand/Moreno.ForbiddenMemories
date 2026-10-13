# Card UI art

The card view's small pictures are baked by `tools/extract.py --screens` (function `bake_card_ui`) into `assets/screens/card_ui/`:
one PNG per piece and `layout.json` (each piece's VRAM page and position, its CLUT, and its offset from the cell it was cut from).
Run `python tools/extract.py "<disc>.cue" --screens` to regenerate; existing files are kept unless `--overwrite-only "card_ui/*"` is given.
A contact sheet of every piece can be rendered with the project's own loader (not kept in the repo: it is made of disc art).

## Where the pieces come from on the disc

All of them are in `DATA/WA_MRG.MRG`, in one package: sector 0x2189, 76 sectors (WA offset 0x10C4800). It is requested by the
routine at 0x80032328 and holds the card-detail sheet:

| Part of the package | Sectors | WA offset | What it is |
|---|---|---|---|
| card-detail page | 56-71 | 0x10E0800 | 256 x 256 texels, 4 bits a texel, 128 bytes a row: the VRAM page 0x1F (VRAM x 960, y 256) that the card-detail routine (0x80028B08) draws from |
| palette block | 72-75 | 0x10E8800 | 256 x 16 colours (16 bits each) uploaded at VRAM (256, 240) |

The card-detail routine selects pieces with page 0x1F and CLUTs in rows 248, 249, 255 of this palette block, which is how the
pieces below were located. The texel positions are the ones that routine uses.

## Pieces (`assets/screens/card_ui/`)

| Piece | Page position | CLUT (x, row) | Size | Notes |
|---|---|---|---|---|
| `attribute_light/dark/earth/water/fire/wind` | (16k, 0), k = 0..5 | (256 + 16k, 255) | 16 x 16 | the attribute ball; the card's attribute is the high nibble of the level/attribute byte (0 Light .. 5 Wind) |
| `attribute_spell` | (96, 0) | (352, 255) | 16 x 16 | the ball for nibble 6 (equip, magic, ritual cards) |
| `attribute_trap` | (112, 0) | (368, 255) | 16 x 16 | the ball for nibble 7 (trap cards) |
| `digit_0` .. `digit_9` | (16 + 6d, 16) | (496, 248) | 6 x 13 | the stat digits, white |
| `digit_dim_0` .. `digit_dim_9` | (16 + 6d, 16) | (496, 249) | 6 x 13 | the same digits dimmed (used for a stat that is shown dimmed) |
| `level_star` | (0, 16) | (448, 248) | 9 x 9 | one level star |
| `label_atk` | box at (1, 80) | (480, 248) | 21 x 7 | ATK label, cut to its opaque box |
| `label_def` | box at (1, 96) | (480, 248) | 20 x 7 | DFD label, cut to its opaque box |
| `label_normal_magic` | box at (2, 33) | (480, 248) | 53 x 11 | the normal magic card label |
| `label_trap` | box at (16, 49) | (480, 248) | 39 x 10 | the trap card label |
| `label_equip_magic` | box at (4, 65) | (480, 248) | 51 x 10 | the equip magic card label |

Every piece is cut out with texel index 0 transparent. Digits are kept as the full 6 x 13 cell, so the card view places each the
same way it does on the disc. Labels are cut to their opaque box; `x` and `y` in layout.json give that box's offset from the search
window's corner (for example `label_trap` sits 16 texels right of the window's left edge).

## Verification

- The attribute balls, digit cells, level star and labels were checked by rendering the card-detail page with the palette block
  (the page shows the balls, the digit row, the star, the ATK and DFD labels and the three card-kind labels in their places).
- A contact sheet of every baked piece is rendered locally when auditing and is not kept in the repo.

## Not baked yet

- The life-point panels (`duel/life_points_you`, `duel/life_points_opponent`). The old extraction is garbled. They are on the
  boot UI image (VRAM page 11, x 704, around v 127-165), with the LP and COM words in rows 248-251. Not traced yet.
- The duel card face's own digits, labels and frame (page 30, VRAM x 896, y 256; the duel card routine at 0x80016784).
- The card type icons (monster, magic, trap, ritual; 16 x 16 on page 11 at (0, 200)). Their CLUT rows are not confirmed.
- The guardian star symbols. The card panel chooses them with the star index plus 0x17 (through the text system), so they are
  probably glyphs of the font page rather than sprites. Not yet mapped to glyph codes.
- Old `assets/images/attributes`, `assets/images/card_frames` digits and labels, and `life_points_*` still hold the garbled
  extraction. `scripts/duel/duel_scene.gd` still reads them (its attribute icon at about line 547); switch those readers to
  `assets/screens/card_ui/`.
