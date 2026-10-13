# Story visual audit (partial)

Status: story pictures were fixed in part and re-checked. The dialog, portrait, bust, map, duel result, logo, game over,
credits and new game flow items were only partly inspected (portraits and busts as contact sheets). Items marked open
have not been fixed.

Contact sheet of all 105 baked story pictures: `docs/story-pictures-sheet.png` (labelled with id, scene, size, regenerated).

## Checklist

| Element | Original source | Port status | Evidence |
|---|---|---|---|
| Story pictures 0x000-0x049 (320x160) | picture records, `bake_story_scenes` | Render plausibly. 000 and 042-049 are fully black (5 non-black texels). 000 is referenced from the first scene; 042-049 are not reached by the script. Kept black, not verified as an intended fade frame. | `docs/story-pictures-sheet.png` |
| Story pictures 0x100-0x1FF overlays | overlay pages with the average blend | Fixed in the baker: semi-transparent texels (CLUT bit 15) on overlay layers are averaged with the layer below. The holes in 123, 129, 130, 131 and 132 are the silhouettes: their colour index has the CLUT value 0x0000, which the hardware does not draw, and the story screen has a black backdrop behind the picture. They are now written as opaque black, so they read as the dark figure in any viewer; the in-game look is unchanged. 124, 126 use overlay 1 and 132 uses both. | sheet, scenes regenerated |
| Story pictures 0x200+ (512x256 scroll bases) | base sprite with two overlays | Fixed: texel index 0 is now transparent instead of white. The art ends at column 320 and the white right-hand block was index 0. Magenta bottom bands in 200, 210-212 are the same unused rows and are now transparent. Overlays blended as above. | sheet, ids 201, 203, 208, 210-212 |
| Dialog frame | `story/frame.png` | Not re-inspected in this pass. | none |
| Dialog arrow, text ramps | dialog arrow bake and text bank | Not inspected. | none |
| Portraits 0x41-0x59 (25 portraits, 48x48) | story package, 64-colour CLUT | Frames and art look coherent in the contact sheet. Portrait 21 is genuine: the striped white and blue is the silver hair of the character, the same as the busts 21 and 58 on the disc, and dialog shows it (F6 0x56, five uses). Every portrait's CLUT is fully populated and no index reaches entry 64. | portraits contact sheet, bust comparison (scratch) |
| Busts (`story/busts`, 100+ files) | bust bake with layout.json | Coherent. Busts 05, 11, 39, 40 and 41 show a Japanese "not registered" caption: the disc holds it in those records, and no dialog string or script opcode uses those ids (F6 and the show-menu opcode, all 5587 strings and every script path), so they are never shown. Kept as baked. | busts contact sheet (scratch) |
| Campaign map (terrain per package, names, markers, arrows, spotlight, fog, 16 places) | map bake | Not inspected. | none |
| Duel result screen | duel result bake | Not inspected. | none |
| Logo sequence | logo bake | Not inspected. | none |
| Game over | game over bake | Not inspected. | none |
| Credits | credits bake | Not inspected. | none |
| New game flow | scripts/story | Not inspected. | none |

## Open defects

1. Silhouette holes in 123, 129, 130, 131, 132: resolved as opaque black (see the overlay row). The original's transparent colour is shown over the port's black backdrop, so the figure was never missing.
2. Busts 05, 11, 39, 40, 41: placeholder captions, never shown by any script. Left as baked.
3. Portrait 21: resolved, genuine art (see the portrait row).
4. Black pictures 000 and 042-049: confirm the intended use.
5. Map, duel result, logo, game over, credits, and the new game flow have not been inspected.

## Notes

- Changed in `tools/extract.py`: `average` helper, `blend` parameter on `draw_object`, overlay averaging in `story_picture`,
  and transparent texel index 0 in the 512-wide base.
- Regenerated: `assets/screens/story/scenes/*.png` (via `--screens --overwrite-only "story/scenes/*"`).
- Story picture windows (0x100-0x1FF) are now written with opaque black where the picture draws nothing; the 0x200+ bases are unchanged.
- Regenerated with `--screens --overwrite-only "screens/story/scenes/*"` (patterns are relative to the assets folder).
- A headless Godot run after the change reported no script errors.

## Pass 2: campaign map (16 places, both packages)

Original, as far as it is described in the reference: the place's camera (distance, pitch, heading, target) frames the terrain
at the origin, the fog runs from 2000 to 2400 units to black, and the terrain is drawn in its own unrotated, untranslated space.
The tournament flag (0x47) selects the after package; the place table and camera values are the same in both packages.

Captured: all 16 places before and after the flag, 8 frames after entering each place (scratch contact sheets, not in the project).

Defect fixed: the after package rendered almost black. Its terrain was placed about 1800 units off every camera, past the fog,
because the bake applied a stored rotation and offset that the before package does not have (its stored transform is the
identity). Neither package now applies the stored transform (`tools/extract.py`, `bake_map`), and `assets/screens/map/after/model.json`
was regenerated (`--overwrite-only "map/*"`). Both packages now have the same vertex bounds, and the after places show their
buildings (Metropolis, Forest, Desert, Meadow, Vast, Town Plaza, Shrine, Duel Ground, Card Shop, Pharaoh's Palace, Hiding).

Checked in the render, no change needed: place names for all 16 places, the name panel frame, the arrows (left, right, up, down
and the diagonal variants at Forbidden Ruins), the Millennium Puzzle marker on places 10 to 15, and the spotlight mask.

Remaining (open):
1. A small white block sits under the left wing of the name panel on Duel Ground and Card Shop (both packages). Source not traced; it is
   probably a stray glyph or sprite from the name text.
2. Marker animation, the eight arrow variants at each exit position, and the camera per place were not checked against the
   reference frame by frame. Only the rest pose was captured.
3. Name panel text colour and the fog ramp were not measured.

## Pass 2: other screens

Not inspected in this pass: duel result (three pages and outro), logo sequence, Game Over, Credits (fonts, colours, secret number box),
New Game flow, dialog frame, dialog arrow frames and timing, text colour ramps, glyph reveal timing, message box frames.
These remain open and need their own screenshot pass against the reference.

## Checks

- `Redot --headless --quit-after 60` on the project: no script errors.
- No script or doc change names the reference source.

## Pass 3: map name panel, duel result

Map name panel, places 12 and 13 (both packages): the small white block under the left wing was the campaign-flag command (byte
0xF9 with a flag word and a jump target) at the start of each name string. The text layout had no handler for it, so its four
operand bytes were drawn as glyphs. The layout now steps over the flag command (`scripts/ui/game_text.gd`): a set form is skipped,
and an if form jumps to its target when the flag is set, otherwise it goes on past the target. The map does not pass a text bank,
so the name is laid out from its inline text in both packages. Open: the after-tournament name variant is the if form's jump target,
which the port cannot resolve. The target bytes in the bank decode to a description of the Card Shop, not a name, so the names
do not share a segment with the bank file. The after-tournament name is therefore not shown yet.

Duel result: the confetti table holds null entries for kinds with no box, and the spawn code read them as positions. That raised a
script error on every frame of the outro. Those kinds now have zero offset (`scripts/duel/duel_result.gd`, `_confetti_offset`).
Headless run: no script errors.

Duel result capture: the outro holds for about 600 frames (the port has no track to wait on) before the page opens. The scratch
harness did not reach the page phase in the time it had, so the three pages have not been compared against the reference yet.

Still open from the task list (not inspected in pass 3): marker animation frames and all eight arrow variants over their frames;
duel result pages and outro; logo sequence; Game Over; Credits; New Game flow; dialog frame; dialog arrow frames and timing; the
F8 0A colour ramps and colour use in strings; glyph reveal timing; message box frames.

## Pass 4: after-tournament map names, duel result pages

Map names, after package: the name strings are global strings, and their flag jumps are offsets into the 64 KB window that starts at
the global text base. `tools/extract.py` (`export_text`) now also writes `assets/screens/text_bank_global.bin` (that window). The map
lays out names with this window, so the after-tournament variant resolves: places 12 and 13 read "Old Duel Ground" and "Old Card
Shop" (before the tournament they read the inline names). Checked in the render.

Duel result pages (captured directly on the page phase, the outro hold skipped): page 0 numbers are correct (COM cards used 30 draws
as "3 0", LP 1300 as "1 3 0 0"). Open, seen in the render, not checked against the layout:
1. Pages 1 and 2: the section headers (OFFENSE / DEFENSE STATISTICS, SPECIAL ARTS, YOU, COM) sit on the frame's top rule. The first
   row of each page is not centred in its bar.
2. Page 1: the victory-condition line ("TOTAL ANNIHILATION") overlaps the line above it.
3. Page 2: COMBO PLAYS shows no values in either column, while the other rows show them. Confirm whether the original blanks it.
4. The outro (confetti, fly-off) is not compared yet; the outro hold is about 600 frames by design.

Not started: marker animation frames and the 8 arrow variants over their frames; logo sequence; Game Over; Credits; New Game flow; dialog
frame and arrow frames and timing; F8 0A colour ramps; glyph reveal timing; message box frames.

## Pass 5: duel result page layout, outro, map arrows and marker, Game Over, Credits, logo, colour ramps

No code changed in this pass. Findings:

Duel result pages (against the reference's page code): the page text box is created at (26, 40) with a 288 by 288 box, matching
TEXT_ORIGIN. The statistics string opens with a y-move of +8 and later a y-move of -8, so "TOTAL ANNIHILATION" is drawn 8 px above
"VICTORY CONDITIONS". This follows the game's own bytes; the overlap is therefore the data, not a port fault. Not confirmed against a
reference picture.
- COMBO PLAYS (and CARD DESTRUCTION, AVERAGE ATK/DFD FACTOR, DEFENSIVE LOSSES) are blank because the duel does not track them yet
  (the reference copies these raw fields into the page rows). This is a missing-stat gap, not a layout fault.
  Fixing it needs the duel engine to count the fields.
- Section headers on the frame's top rule: the header text sits at the same y as the rule in the layout data. Not changed.

Outro: the spawn radius (0x140 + rand & 0x3F), the random orbit angle, the orbit step (0x30), the radius decay by 2, the 600-frame hold
and the fly-off release below 0xC0 match the reference. Not built: the outro's two banner objects (the reference's
the result outro sets them up with the slide routine), and the starchip object. Open.

Map arrows: all eight variants (10 frames, duration 4) render intact across all frames. Each exit's variant agrees with its direction
mask, except place 7's right and left exits, which use diagonal art (variants 1 and 3). The data gives those values, so the port draws
them as the table says. Marker: 16 frames (duration 6) render intact, the pendant turning from red to gold. Frame timing comes from the
baked durations and loops.

Game Over: the frames fade in, the title art and the creature sprite animate, and the background stone and hands are intact. The
creature overlaps the "G" in the title. Not confirmed against the reference.

Credits: the glyph size (8 by 12), the line pitch (16), the CLUT per kind (2 to 0x3E20, 1 to 0x3DE0, else 0x3DA0), and the colour
multiplier match the reference. The reference's shade quad is set up but never sorted, so not drawing it matches. The secret number
box is at (16, 112), 288 by 32, matching the reference's text box call.

Logo (story opcode 17): the layout (logo origin, backdrop panels, subtract fill) matches the bake; the fade, hold and banded wipe are
approximations documented in scripts/story/story_player.gd. Not compared pixel by pixel.

Colour ramps: the font ramps are 0 white, 1 yellow, 2 blue, 3 green, 4 grey, 5 orange, 6 red. Strings use ramp operands 0 to 6 (choices
mostly 1, yellow) and slot forms 0x80 to 0x84, which the port maps through the slots table. The duel result's losing side is dimmed
through slot 4 (grey), which matches the render.

Not inspected: New Game flow (name entry to intro), the dialog frame, dialog arrow frames and timing, glyph reveal timing, message box
frames.
