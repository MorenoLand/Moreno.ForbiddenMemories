# Duel effects: the effect programs and their port

The duel's visual effects (attack hits, summon beams, magic casts, trap springs, lightning, flashes, the Exodia result) are drawn by a
set of 25 effect programs that run inside a loaded overlay. The original draws them as PlayStation GTE polygons: 3D points are
rotated, translated and projected in the geometry engine, then emitted as flat, Gouraud or textured triangles and quads, lines and
sprites, into an ordering table. This port reproduces the same arithmetic and the same draw calls, in `scripts/duel/effects/`, and
hosts the programs in `scripts/duel/duel_fx.gd`.

Status: framework done. Programs 0, 1, 2, 4 to 16, 19 and 20 are ported and registered (the table in section 5); 0, 1, 2, 4, 19 and the equip, placement and
life/damage hooks are in `duel_fx.gd`. Everything else is listed in section 5 with its size, so the rest can be ported in parallel by effect id.

Everything here is described by behaviour. The reference is the overlay's dispatch routine (`case N` runs program N) and the
programs it calls; read those directly when porting.

---

## 1. Dispatch and the request record

A request is a 0x20-byte record the duel's update loop walks each frame (eight records in a pool). When a record is active the loop
calls the dispatcher with the record's id, its phase, its bank buffer and the record. The record fields a program reads:

| Offset | Meaning |
|---|---|
| `+0x00`, `+0x02`, `+0x04` | the offset vector (x, y, z). Added to the projected picture points of bias-0 primitives (section 3). Battle hit: (240, 120). Reveal: (160, 104) |
| `+0x08`, `+0x0C` | the two ordering tables the frame gives the effects: `+0x08` for the scene-space programs, `+0x0C` for the picture-space programs (section 5) |
| `+0x10` | flags: the ordering slot of the bias-0 primitives (and the mode of the additive ones) |
| `+0x12` | the number, for the programs that show one (the battle hit's damage value; program 13's figure) |
| `+0x14` | the bank buffer the program keeps its state in (its work struct) |
| `+0x18` | the effect id (0 to 24) |
| `+0x1A` | the phase (section 2) |
| `+0x1C` | the request's flags (active, initialized, nonblocking). The update loop clears the byte when the program reports done |
| `+0x1D` | the impact flag: set by a program once its visible impact has landed; the game's coordinator waits on it before going on (the ritual, the battle) |

The dispatcher, for every call:
1. Sets the offset vector from `+0x00..+0x04` and the flags from `+0x10`.
2. On the first call (phase 0 or more) converts the 21 texture image records into texture page and CLUT words (section 3).
3. Chooses the ordering table and the geometry offset by effect id (table in section 5: "scene" means the geometry offset is (160, 108), "picture" means (0, 0)).
4. Calls the program with the phase.

After each request the update loop resets the geometry offset to (0, 0) and the projection, and when the finish flag is set clears the request.

### Phase protocol

- **First call, phase 0 or more.** The program sets up its work for the variant the phase names. The variant is an index into the
  program's configuration table, a mode, or a packed value (program 11 packs a variant in the low 4 bits and a flag at bit 7).
  Some programs also draw nothing on this call.
- **Later calls, phase -1.** The update loop replaces the phase with -1 after the first call. Each -1 call draws one frame and advances
  the state (timers, positions, colours), and sets the finish flag when the effect is over.
- **Out-of-range variant.** Most programs check the variant against their table size. A variant at or past the size takes a debug
  banner path: two diagonal lines across the picture for 180 frames. The North American build also printed debug text, which is not drawn
  here. This path is not reachable from valid game data.
- **Program 20** is program 16 called with phase 1 whenever the phase is 0 or more. It has no caller in normal play (the debug screen can
  request any id).

### Finish and impact

- The finish flag (a byte in the duel's effect status, set by the programs) ends the request on the frame it is set: the update loop clears the record's flags.
- The impact flag (`+0x1D`) is read by the game coordinators: the battle waits for it before the card effects of the battle, the ritual
  waits for it before the summon, the card-effect steps wait for it. Set it at the frame the effect's visible result is reached.
- In the port, the frame loop of the duel (`duel_fx.gd`) runs a program each tick until its `done` is set. The impact is `impact`.

---

## 2. Shared state

- **Texture pairs.** Twenty-one page/CLUT word pairs (`pairs[0..20]`, the program's texture table). Each is computed from one image record
  (section 3). The program names a pair by index: pair 0 for the layered sprite, 1 for the ring and gradient page, 3 for sparkles, 9 for the
  digit atlas, 10 and 11 for the textured quads. The dispatcher fills them on the first call of every program.
- **Image records.** Twenty-one `GsIMAGE` records (28 bytes each) at bank offset `0x14270`: pixel-mode, page position, size, CLUT position.
  Other programs keep their own image records at `0x14994` (the same 21) and `0x14D14` (the same 21), and a single 16-bit image at
  `0x146F8` (the tile effect's sheet, 140 x 196 texels at VRAM (320, 256); its source in VRAM is not established, see section 8).
- **Modes.** Twenty-one u16 values at `0x144BC`: the semi-transparency mode of each pair (`mode & 3`, the ABR). Entry 20 aliases the low
  half of the first variant image's pixel mode.
- **Digit cells.** Twelve RECTs at `0x145A0` (x, y, w, h as s16): tiles 0 to 9 are the digits, 10 is '+', 11 is '-'. They sit in the digit
  atlas (pair 9).
- **Colour.** Every colour is three bytes (r, g, b, 0..255). The fade helpers step channels toward zero or toward a target (section 4).
- **Scratch display-object table.** Twenty-one pointers at `0x15838` to the duel's card display objects, filled by the duel's
  field-row collector before effects 22 to 24 and 15 to 17 read the card positions from it. Effect 22 uses slot 0 as the ritual result.
- **Board tint.** A global 24-bit colour, written by one program from three components (high, middle, low), read by the board's drawing.
- **Start vectors.** Each program starts its scale from a constant vector in the bank (`(4096, 0, 4096)` for most; `(4096, 4096, 4096)` for
  program 11, and for some others). The vectors used by the ported programs are in `assets/screens/duel_fx/configs.json` under `scale`.
  The first pose of programs 2 and 19 starts from their baked start vector (section 9).
- **Configuration tables.** Per program, in the bank (bank-relative offsets; the records are C structs, so porters check the stride
  against the struct layout): program 0 at `0x15180` (30 records), 1 at `0x1548C` (2), 2 at `0x14FE4` (7 records of 50 bytes),
  3 at `0x14714` (2 of 8 bytes), 4 at `0x15770` (2), 5 at `0x154BC` (10), 6 at `0x153D8` (6), 7 at `0x15624` (5), 8 at `0x14600` (6),
  9 at `0x156BC` (5), 10 at `0x14BE0` (6), 11 at `0x14570` (1), 12 at `0x14FB0` (1), 13 at `0x14F60` (4), 14 at `0x146E4` (1),
  15 at `0x14CD4` (8), 16 at `0x14FC0` (1), 17 at `0x157A8` (2), 18 at `0x15144` (2), 21 at `0x14C34` (10 pairs of 3-word vectors),
  22 at `0x14724` (24).
- **Request offset, flags and ordering table.** The offset vector at `0x157D0`, the flags at `0x157C8`, the ordering-table pointer at `0x1588C`
  (all bank-relative; they are the dispatcher's own variables).
- **Random numbers.** The programs draw from the console's random sequence. The port uses one generator per program, seeded by the request.
  The sequences differ, so random layouts (particle directions, sparkle cells) are the same in kind, not the same numbers.

---

## 3. Textures and the GTE

### Texture pages

The effect textures are in the duel's terrain package: 235 sectors per terrain from WA sector `0x16C6`. The overlay bank itself is terrain
package phase 7 (44 sectors at package sector 140), identical in all seven terrains. The VRAM the effects sample is uploaded by the same
package: phase 0 to (768, 256), phase 1 palette rows at (256, 240), phase 5 palette rows at (0, 240), phase 6 to (512, 256), phase 10 to
(832, 0), phase 12 to (640, 256).

`tools/extract.py`'s `bake_duel_effect_textures` (part of `--screens`) decodes the 21 pairs from that VRAM:
- `assets/screens/duel_fx/pair_NN.png`: one texture page per pair, 256 rows tall, as wide as its colour depth allows (256 texels at 4 bits,
  128 at 8 bits, 64 at 16 bits). Colour 0 is transparent; a texel with the CLUT's semi-transparency bit has alpha 128; others 255.
  The pages are identical in all seven terrains (checked when baked); a differing terrain would get `terrain_N/pair_NN.png`.
- `assets/screens/duel_fx/layout.json`: each pair's page word, CLUT word, depth and default mode, and the digit cells.
- `assets/screens/duel_fx/configs.json`: effect 2's seven configuration records and the start vectors of effects 2 and 19.

To extend the bake for another program's configuration table, decode its records in the same function (bank offsets above).

### Page and CLUT words

The texture page word packs: colour depth (bits 7-8), semi-transparency mode (bits 5-6), page Y bit 4 (256 rows), page X (bits 0-3, in
64-halfword steps), and page Y bit 11 (512 rows). The CLUT word packs the CLUT's y (bits 6 and up) and x/16 (bits 0-5).
The port's `EffectCanvas.add_poly(..., pair, ...)` takes a pair index; the texture coordinates are texels of that page.

### GTE emulation (`gte.gd`)

- `Gte.Mat`: a 3x3 rotation (4.12, 4096 = 1.0) and a translation.
- `rot_trans(v)`: the view-space point of a local vector (no projection).
- `rot_trans_pers(v)`: `Vector4i(x, y, depth, ok)`. With `q = (H * 0x20000 / depth + 1) / 2`, the picture point is
  `offset + ((ir * q) >> 16)`, clamped to -1024..1023; `ok` is 0 when the depth is zero or less or a value saturated.
- `rot_average(vertices)`: `{xy, depth, ok}`. The depth is the sum of the vertex depths divided by 4 (quads) or times 1/3 (triangles).
  Programs then shift it by 2 to get the ordering-table slot.
- `rot_matrix(angles)`: the console's rotation, composed X then Y then Z, from the sine and cosine of the angle (4096 to a turn). The
  sine table is `round(4096 * sin(2 pi i / 4096))`, checked exact against the executable's table.
- `mul_matrix2(world, local)`: rotation product (translation kept). `scale_matrix(m, s)`: each column times one component of `s`, 4096 = 1.0.
- `pose(world, saved, position, rotation, scale, mode)`: the overlay's per-object transform. Mode 0 places the object alone; mode 1 also keeps
  the unscaled pose in `saved`; mode 2 composes it with the world rotation; mode 3 does both. The result is the current view matrix.
- `scaled_saved(saved, scale)`: the saved pose scaled, as the view matrix.
- `push()` / `pop()`: the view-matrix stack.
- `set_geom_offset(x, y)`, `set_screen_distance(h)`: 160,108 and 300 in the duel (the projection distance is 0x12C).

`world_identity()` is the world every effect starts from: no rotation, the view 300 units in front of the picture.

---

## 4. Primitive helpers and their ordering

The overlay's packet helpers each apply one ordering rule; the port's `EffectProgram` helpers keep those rules. Ordering slot = the
depth shifted by 2 (`>> 2`), and the bias (`bias - 1`, clamped at 0) is subtracted from the depth first.

| Port helper | Overlay behaviour | Ordering | Offset added | Blend |
|---|---|---|---|---|
| `ft4(verts, pair, uv, rgb, bias, mode)` | textured quad | bias 0: at flags; else depth - (bias-1) | bias 0 only | bias 0: additive if mode 1, else opaque; else opaque (mode 0) or ABR mode & 3 |
| `gt4(verts, pair, uv, rgb4, bias, mode)` | textured Gouraud quad | bias 0: flags (mode 1) or flags + 1 (other); else depth - (bias-1) | bias 0 only | bias 0: additive if mode 1, else opaque; else ABR mode & 3 |
| `f4(verts, rgb, abr, mode)` | flat quad | depth | no | opaque if mode 0, else ABR abr & 3 |
| `g4_add(verts, rgb4, bias)` | untextured Gouraud quad (strips) | bias 0: flags + 1; else depth - bias | bias 0 only | additive |
| `ring_strip(rgb, first, middle, last, mode)` | 32-segment ring band | mode 0: flags; else depth + 1 - mode | mode 0 only | additive (mode 0) or ABR mode & 3 |
| `gradient_strip(rgb, first, middle, last, bias)` | two gradient rings | as g4_add | as g4_add | additive |
| `gradient_quads(rgb, widths, height, bias)` | two-level gradient quads | as gt4 | as gt4 | additive |
| `layered_sprite(rgb, size, bias, at)` | sprite square and half-colour square of twice the size | as ft4 | as ft4 | additive |
| `sparkle(rgb, verts, bias)` | sprite of one of four sparkle cells | as ft4 | as ft4 | additive |
| `screen_flash(c, step)` | full-screen additive quad, then the colour fades | flags | no | additive |
| `number_glyphs(value, rgb, at, mode, size, bias)` | digits from the atlas, sign first | as ft4 | as ft4 | as ft4 |

Notes:
- "Offset added" means the request's offset vector is added to the projected points, as the bias-0 helpers do. Non-zero bias paths add
  no offset. This is intentional in the overlay and is kept.
- A semi-transparent primitive (ABR 0..3) in the console is averaged, added, subtracted or quarter-added. The port draws averaging as a
  50 percent mix, adding and subtracting with blend modes, and quarter-add as additive with the colour scaled by a quarter.
- Textured colour multiplies the texel, where 128 is unchanged; the port divides by 128. Flat and Gouraud colours are divided by 255.

### Shapes

`EffectProgram` provides the vertex generators the programs use: `ring(radius)` (32 points), `square(size)`, `quad_rows(...)`
(a quad from two widths and two heights), `shifted(points, by)`. Random vectors come from `random_vector(scale)`.

### Colour

`fade_down(c, step)` (each channel minus step, to zero), `fade_up(c, target, step)` (each channel plus step toward the target; returns
true when reached), `is_black`, `is_lit`, `colour_of`, `set_all`, `set_rgb`, `half`, `quarter`.

---

## 5. The dispatch table

Sizes are the program's source line count (the helpers are counted separately: 27 files, 1,219 lines; the dispatcher 134; the whole
overlay 5,677 lines of program and helper source plus 1,515 header lines). "Scene" and "picture" are the geometry offset.

| Id | Program lines | Geometry | Variants (first-call phase) | Triggered by | Port |
|---:|---:|---|---|---|---|
| 0 | 101 | picture | 30 configs (phase < 30) | the Exodia result sequence; placing a card that has no equip effect | **ported** |
| 1 | 141 | picture | 2 configs | card placement (the light beam and the screen flash) | **ported** |
| 2 | 192 | picture | 7 (3 to 5 by damage size; 0 to 2 for plain bursts; 6 when the number is zero) | battle: the attack's hit and damage figure | **ported** |
| 3 | 168 | picture | 2 descriptors (tile sparkle) | battle: the defender's reveal (attack or defence position; phase 1 for defence) | **ported** (the sheet is the card's read-back, see section 9) |
| 4 | 144 | picture | 2 configs | placing an equip card | **ported** |
| 5 | 183 | picture | 10 configs | life point recovery splash (the heal number rising) | **ported** |
| 6 | 202 | picture | 6 configs | direct damage splash (the damage number) | **ported** |
| 7 | 189 | picture | 5 configs | direct damage (second request of the card) | **ported** |
| 8 | 126 | scene | 6 configs | trap resolution; Cursebreaker | **ported** |
| 9 | 158 | picture | 5 configs (the value: 200, 500, 1000, 2000, 5000) | life point recovery from a recovery card (the card window, the trap-presentation path) | **ported** (hooked: the heal window, variant = the amount index) |
| 10 | 175 | scene | 6 configs | terrain change | **ported** |
| 11 | 258 | scene | packed phase (variant in bits 0-3, flag at bit 7) | monster removal fragments (one request per removed monster; variant = card type) | **ported** (hooked: monster removal cards) |
| 12 | 80 | scene | 1 config | stop defence | **ported** |
| 13 | 178 | scene | 4 configs; a number argument | stat penalty (Spellbinding, Shadow Spell); a field effect | **ported** |
| 14 | 211 | picture | 1 descriptor (gather), banner at phase 10+ | battle: the level gather (variant = the shown card's level less one) | **ported** (hooked: the battle beat before the lunge) |
| 15 | 120 | scene | 8 configs | monster removal (first request, the removed monsters' points) | **ported** (hooked: monster removal cards) |
| 16 | 158 | scene | 1 config (phase 0 or 1) | Raigeki (the sweep) | **ported** |
| 17 | 280 | scene | 2 configs | board destruction (Dark Hole, card 336: the window's group "board") | **ported** (the board tint channel, the card objects drawn in) |
| 18 | 131 | picture | 2 configs (phase 1 from both starts) | ritual start; Swords of Revealing Light start | **ported** (the ritual window's group and the Swords lock) |
| 19 | 101 | picture | none (phase 0) | reveal (Dark Piercing Light; the Exodia result's flash) | **ported** |
| 20 | (16) | scene | program 16 with phase 1 | none in normal play | **ported** (registry: program 16 with `fixed_phase` 1) |
| 21 | 91 | scene | 10 slots (phase selects the slot, parity) | Swords field effect (phase = the side); resuming a phase (phase 2 and 3, not hooked) | **ported** (the Swords lock; nonblocking, switched off with the lock) |
| 22 | 481 | scene | ritual modes (phase = the ritual card id: 24 configurations, the table in effect_22) | ritual apply (the summon: the tributes fly into the portal) | **ported** (hooked: a ritual event with a summon) |
| 23 | 210 | scene | none (reads the card positions) | Harpies' Feather Duster (the magic window's group "feather") | **ported** (the card-object channel, section 6) |
| 24 | 246 | picture | none (reads the card positions) | Exodia result (final) | **ported** (the finale's white burst, at the five pieces' places) |

Non-program ids: `0` and `4` are also the card-placement presentation (4 for equip-group cards). Id 20 is the debug-only path.

Other shared programs not in the table: the tile sparkle (id 3's program) and the gather (id 14's program) are separate files in the
overlay and are counted with their ids.

---

## 6. Triggers in the duel

The game's request calls (the card effect steps, the battle, the ritual, the coordinators) are the triggers. The port's hooks in `duel_fx.gd`:
- `_battle` (the clash beat): calls `_hit(result)` (program 2), with `number = result` and the variant `3 + min(result / 1000, 2)`, clamped at 0.
  The port's own damage figure beat is kept (see section 9 for why).
- The window's group effect for the reveal group (Dark Piercing Light, cards 348 and 350): program 19 at (160, 104).
- `_trap` (the spring beat of a trap): program 8 at variant 0, at the trap's point (a scene program: its offset is the point less (160, 108)).
- `_window_program` (the magic window, before the group's stand-in): "sweep" runs program 16 at variant 0 (the window's centre); "stop"
  runs program 12; "penalty" runs program 13 with the port's penalty as its number (-500 for Spellbinding, -1000 for Shadow Spell),
  and Cursebreaker (655) runs program 8 at variant 3 (the overlay's request for it); "terrain" (330 to 335) runs program 10 at the
  variant card - 330 with no offset, and `stage_on_impact` -2: once the program's impact has landed, its stage signal is set (the
  game sets the same value when the terrain package has loaded), so its sparkles and flash follow.
  The stage signal is the request's field value -2 (`sticky_phase`): later frames carry it, as the overlay's update loop does.
- `_placed` (a `summon` event): program 1 at (128, card top + 30), the light beam of a card placement.
- `_equip_placement` (an `equip` event, after its fly): program 4 for equip ids 301 and 302 (variant 1 for 302), else program 0
  (variant 10 for 0x291), at (card left + 26, card top + 30). Derived from the placement code, not yet checked in play.
- `_life` with a card's `effect` (duel_effects.gd tags the `lp` events): "heal" runs program 5 at the card's unit (with +5 for the
  bad-reaction path); "damage" runs program 6 then program 7 at the unit (5 for the goblin fan's reflection). Units come from the
  card id minus the first card of its group (338 for recovery, 343 for direct damage).

- Card-object triggers (the channel of duel_fx.gd, `CardObjects`): the magic window's feather (card 672) runs program 23 over the opponent's
  magic and trap row (its direction is the row's side); the window's "board" group (Dark Hole, 336) runs program 17 over every card on
  the board; a ritual event with a summon (`_ritual_apply`) runs program 22 with the removed tributes before the summon; a monster
  removal (the removal cards 653 to 664 and Crush Card 661, `_removal`) runs program 15 at the removed monsters' points, then program 11
  at each one (its variant the card type); the heal window (a recovery card, 338 to 342) runs program 9 at (160, 120), variant the
  amount index; the battle beat before the lunge (`_gather`) runs program 14 with the shown card's level less one.
- The reveal's tile sparkle (effect 3) runs after the battle's damage beat, with the defender's read-back as its sheet (section 9).

Hook sites not yet taken: fusion and equip (not yet mapped to ids); Exodia (0, 19, 24); the magic window's ritual group is
hooked (18 at the window, 22 at the summon). Program 14 and 15 and 11 are hooked; their live timings are unverified.

---

## 7. The framework

| File | What it is |
|---|---|
| `scripts/duel/effects/gte.gd` | the geometry engine emulation (section 3); class `Gte` with `Gte.Mat` |
| `scripts/duel/effects/effect_canvas.gd` | the picture (Node2D): `clear()`, `add_poly(points, colours, uvs, pair, slot, abr)`, `add_line(...)`, `present()` (sorts by slot, descending; within a slot the latest record first; each run of one blend mode becomes a child layer) |
| `scripts/duel/effects/effect_layer.gd` | one blend run (Node2D): draws triangles, quads (as 0-1-2 and 1-2-3) and lines with `draw_polygon` / `draw_polyline_colors`; ADD and SUB through `CanvasItemMaterial` |
| `scripts/duel/effects/effect_program.gd` | the base class `EffectProgram` (extends RefCounted): `setup(picture, context)`, `dispatch(phase)` (calls `_start(phase)` or `_update()`, banner path), the colour helpers, the shapes and the primitive helpers (section 4) |
| `scripts/duel/effects/effect_data.gd` | the baked data: `layout()`, `configs()`, `digit_cell(tile)` (JSON numbers converted to ints) |
| `scripts/duel/effects/effect_registry.gd` | `PROGRAMS` (id -> script) and `create(id, picture, context)` (null when not ported) |
| `scripts/duel/effects/effect_02_attack_hit.gd`, `effect_19_reveal_flash.gd`, `effect_18_ring_burst.gd`, `effect_21_swords_field.gd`, `effect_24_exodia_final.gd` | the ported programs |
| `scripts/duel/duel_fx.gd` | hosts programs: `_program(id, phase, context)`, `_advance_programs()` (one frame each tick), `_hit(result)`; a beat waits for its programs |
| `tests/effects_test.gd` | 24 headless checks: the arithmetic, the colour steps, the sort and blend runs, every ported program to its finish, the banner count, the duel's hosting |
| `tests/effects_capture.gd` | renders one program over a dark picture and saves frames (minimized, silent) for looking at it |

Commands (from the project folder):

```
G:\Software\Redot\redot.windows.editor.x86_64.exe --headless --path . --script res://tests/effects_test.gd
G:\Software\Redot\redot.windows.editor.x86_64.exe --minimized --audio-driver Dummy --path . --script res://tests/effects_capture.gd -- 2 4 -300 <folder> "10,25,45"
```

The capture writes `<folder>/effect_<id>_<frame>.png`; the arguments are id, first phase, number, output folder, and frames.

---

## 8. How to port an effect

1. Read the program for the id (the dispatch case N), its helper calls and the config records it reads. Read the header of the program
   too: the work struct and the config struct are in there.
2. Add the config decoding to `bake_duel_effect_textures` in `tools/extract.py` if the program reads a configuration table
   (records at the bank offsets in section 2; the struct layout gives the field offsets). Re-run the baker:
   `python tools/extract.py --screens --overwrite-only "screens/duel_fx/*"` (the pattern replaces only the duel_fx outputs).
3. Create `scripts/duel/effects/effect_NN_<what>.gd`, `extends "res://scripts/duel/effects/effect_program.gd"`. Set `variant_count` in
   `_init()` when the program has a banner (its config count), and `geometry` if it draws in scene space (`Vector2i(160, 108)`).
   Override `_start(phase)` (the first call) and `_update()` (the frame). Port the state into member variables (arrays of `Vector3i`
   for vectors, `PackedInt32Array(3)` for colours).
4. Keep the overlay's order of operations: pose, draw, scale, draw, fade; the flags (`done`, `impact`) where the overlay sets them.
   Use the helpers in section 4 for each primitive; they already carry the ordering and offset rules.
5. Register the id in `effect_registry.gd` (`PROGRAMS`).
6. Hook it in `duel_fx.gd` at the trigger (section 6): `_program(id, phase, {"x": .., "y": .., "number": .., "seed": ..})` with the
   request's values, and wait on it in a beat (the beat waits for programs automatically).
7. Test: add checks to `tests/effects_test.gd` (a run to `done`), render with `effects_capture.gd` and look at the frames.

Keep effect-specific constants in the program, not in the helpers. Helpers stay generic so the rest of the ports reuse them.

---

## 9. Open points and approximations

- **Programs 8 to 16 (approximations).** The world is the identity for every program: the overlay's light-source matrix (8, 10 to 13, 15, 16)
  is not in the port; it is the duel's light, so the rays and bolts may differ from the console's angle. The bolts' lines (13, and 17)
  take their semi-transparency from the blend and the GPU line attribute bits are assumed (the port draws them semi-transparent at the
  blend). The spin steps of 11 use the arc tangent in turns of 4096, rounded. Effect 9's sound (sound effect 26, the burst) is not played.
  Effect 13's page switch for the glow is not kept: the sprites are additive in the overlay whatever the page says. Effect 14's sprites
  are the boot UI image's page 11 with the CLUT at (640, 250) (pair 21): the cells are the star icons of the level codes 0x18 to 0x21,
  drawn with that one palette, as the overlay's words give. Effect 10's column pages (pair 22) and 13's glow page (pair 23) and 11's variant
  pages (pairs 24 to 28) are baked by `bake_duel_effect_extra_pages` in `tools/extract.py`; their coordinates are the overlay's bytes.
  The removal's and the gather's requests are not hooked (see section 6).

- **The start vectors were read at the wrong addresses (resolved).** The names the code was read under are not the overlay's load
  addresses: the symbol map gives the real ones (for example a start vector read at the name-derived address 0x801461B8 actually lives at `0x80146200`). The baker had read the names, which
  held `(4096, 0, 4096)`; the vectors at the real addresses are `(4096, 4096, 4096)` for every program. The baker now reads the
  symbol-map addresses, so programs 2 and 19 get a full-height first pose, and the damage glyphs of program 2 have height. Keep the
  symbol map's addresses for every table and vector (the tables in section 2 are the symbol map's bank offsets).
  The duel's own damage figure beat in `_battle` is kept as the approximation of the number's landing; it can go once the program's
  figure is checked against the retail capture.
- **The start vectors of 2 and 19 (resolved).** Programs 2 and 19 now start from `configs.json`'s `scale` (the baker reads the symbol-map addresses); the zero y came from the old read and is gone. Captures: effect 2's damage glyphs have height, effect 19 reads.
- **The tile sheet (id 3): resolved as a screen read-back.** The overlay's DuelCard_CaptureRoundedTexture reads the battle card back from the screen (140 x 196 at the card's point), sets the semi-transparency bit on every texel, clears the twelve corner texels, and uploads it to VRAM (320, 256), where the tile effect draws it. The port takes the card's picture from the field's rendered viewport at the card's box, stretched to 140 x 196 (the field's cards are drawn smaller than the console's battle card, so this is the card as the port shows it, not the console's pixels). Per-texel semi-transparency is not kept (corners are transparent, the rest opaque). The descriptors are baked (configs "effect_3"). Old note: the VRAM upload was not found in the terrain packages.
- **Semi-transparency per texel.** The console's per-texel semi-transparency bit is not kept. A texel with the bit is drawn at alpha 128 only
  in a primitive that is itself semi-transparent; elsewhere it is drawn opaque, as the console does.
- **Averaging mode** is drawn as a 50 percent mix, not the console's (back + front) / 2 per channel.
- **Random numbers** are not the console's sequence (see section 2).
- **Frame order.** The port advances every running program once per tick, before the beat step. The console runs each request once
  per frame, in pool order.
- **Division.** The console divides with a table; the port divides exactly. The difference is at most one unit in the projected picture
  coordinate.
- **Debug banner.** The two diagonal lines are drawn; the debug text is not.
