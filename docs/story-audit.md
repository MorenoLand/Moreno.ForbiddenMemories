# Campaign story audit

What was checked: every scene of `assets/screens/story/script.bin` (0 to 198) through `scripts/story/story_player.gd`, with Shift held (test skip), every choice answered with each option in turn, and one run per scene with every story flag set. The harness is `tests/story_smoke.gd` (see `tests/README.md`). A second, static pass walks every reachable dialog string with the same operand sizes as the player and checks the picture, bust and portrait files each scene needs.

Result: 199 scenes, 456 runs; no hangs in any scene, no unknown script opcodes, no unknown F8 sub-opcodes, no unterminated text, no missing picture, bust or portrait files, and no glyph code without a picture. Endings reached: map 230, duel 138, gameover 84, credits 4.

The F8 sub-opcodes the story text uses (static count over all reachable dialogs): 02 (x move) 2, 0A (colour) 1, 0D (duel) 183, 0E (BGM) 277, 10 (sound) 18, 11 (BGM fade) 476, 15 (fade) 728, 16 (box flag) 92, 19 (unlock) 53.

## Findings

Status: **fixed** = the port now follows the game; **approximated** = the port keeps a simpler model, the reason is given; **not fixed** = not changed in this pass.

| # | Area | Finding | Status | Evidence |
|---|---|---|---|---|
| 1 | F0-F5 extended glyphs | F0 xx is the glyph code xx (a normal glyph). F1-F5 xx and every code past the 91 retail glyphs are a blank glyph with its advance. The port used to skip the operand and never advance the pen. | fixed (engine); no art to extract | Glyph words 0x100-0x5FF of the glyph table read zero in the executable (the table holds 91 entries), so the game draws nothing there. The extended-glyph handler forms `(op - F0) << 8 | low`. Story text uses none of them (static walk); card text none. |
| 2 | F8 1B-20 | two-byte glyph with high part 8: operand consumed, but no advance. Now a blank glyph with advance (game and layout). | fixed | The secondary entries 27-32 are the extended-glyph handler; the high part comes from the F8 byte (0xF8 - 0xF0 = 8). |
| 3 | F8 26 choice | was skipped (control byte only). Now the same command as FB: the choice start, the mask byte, and the jump table. | fixed | The secondary entry for F8 26 is the same handler as FB. |
| 4 | F8 23 nested | was not dispatched. Now runs the nested sub-command at once. | fixed | The secondary entry for F8 23 reads one byte and calls that entry. |
| 5 | F8 17 / 18 jumps | read the first table entry whatever the selector. Now reads the entry at selector x 2. The two selectors are set by the duel result in the game and are not carried into the story, so they stay 0. | fixed (lookup); approximated (selector) | Secondary entries 23 and 24; the writers are in the duel field and the duel result code. |
| 6 | F8 05 advance / line | the two operands were skipped. Now the glyph advance and the line height. | fixed | Secondary entry 5 writes the advance and the line height the wrap rule uses. |
| 7 | F8 1A choice close | was a no-op. Now clears the box at once (state 2: no wait for the button). | fixed | The choice-close handler sets the box to its clear state, which clears and resumes without input. |
| 8 | F8 0F BGM control | the save form (bit 1 with no track bits) read one byte; it takes a u16. The saved track is kept and replayed on bit 0. | fixed (sizes, save and replay); approximated (copy and wait) | The BGM control handler: bit 0x3F reads a u16; bit 2 copies; bit 0x80 waits. |
| 9 | Page overflow | a glyph that would pass the box's bottom now waits for a page turn and is dropped, as the game drops it; the pen restarts at the top. | fixed | The text box step returns after the wrap check with the byte already consumed, so the overflowing glyph is never drawn. |
| 10 | F8 0A colour slots | bit 7 now picks slot n of the 16-entry colour table (zero at boot as in the game). Before, the operand was used as a ramp index. | fixed (table); approximated (values) | The colour table is zero in the executable; the duel result writes slots 0 and 1 (4) and the winner's slot (0) at run time. The story does not see those writes. |
| 11 | F8 00 card insert | size 1 is right. The name (0x20) and description (0x40) are pushed when a card is selected; the story has no selected card, so nothing is inserted. | approximated | Not used by any story dialog (static walk); the card text of the duel uses it through the card screens. |
| 12 | F8 09 string insert | pushes the global string id that the duel result leaves behind. The story does not set it, so nothing is inserted. | approximated | Not used by any story dialog (static walk). |
| 13 | F8 08 / 0B icons | the pen moves 16 px as the game's icon does. The icon art (stars, types) is not extracted, so nothing is drawn. | approximated | The secondary entries 8 and 11 call the icon routine with an advance of 0x10. |
| 14 | F8 03 number | the operand size (5) is right. The RAM value is not held in the story, so no digits are drawn. | approximated | The secondary entry 3 reads a u32 address and a flag byte. |
| 15 | F8 04 cell | 1 (the 8 x 8 font) is drawn with the 8 x 12 font; the 8 x 8 font is only in the duel result screens. | approximated | The secondary entry 4 sets the cell size. |
| 16 | F8 07 glyph limit | read (2 bytes); no effect. The game's done flag is read by the duel dialogs, not by the story box. | approximated | The secondary entry 7 sets the glyph limit and the box's done flag. |
| 17 | F8 15 fade | the handler's body is not in the spec (declared only). Its size is 1 by consistency: all 728 story uses walk to the string end with no unknown sub-opcode. The fade is the port's black fade. | approximated | The secondary entry 21; static walk of every story dialog. |
| 18 | F8 10 voice | a sound id with bit 15 plays the id without the voice routine (its note word is consumed). | approximated | The secondary entry 16 calls the voice routine with a note word. |
| 19 | F8 0C, 2B-2E | operand sizes are 1 and 0 and right; the menu flag and the display-object fades are not drawn. | approximated | The secondary entries 12 and 43-46. |
| 20 | F6 display effect flags | 0x08 is not read by the game (checked). 0x20 only restates a bust that is on screen (already in the port). 0x01 on hide is a different state in the game (approximated as a slide-out). The expression bits at a start (0x10 rule) are not in the game; the start uses the expression the bust had. | partly fixed; approximated | The display-effect handler: hide (0x80), expression (0x40), restate (0x20), start by slot bit 0. |
| 21 | F7 states | the operand sizes of states 5, 0x0B, 0x0F and 0x10 are as the spec says (u16; byte and u16 for the viewport when bit 0x8000 is set). The byte/word order of the viewport is kept; not confirmed. | verified (sizes) | the spec's text control notes, the states that read operands. |
| 22 | F9 / FA / FC / FD / FE / FF | sizes and behaviour checked against the spec. The pushed stream now stays in the same frame's bank, as the spec's nested streams do. | verified | the spec's text control notes. |
| 23 | Choice bar | the lines above the choice come from bits 4-5 of the control byte. The game's use of the high nibble as a style flag is not confirmed. | approximated | The choice handler: the high nibble of the control byte. |
| 24 | Lowercase letters in the 16 px font | the cells match the page: 'o' is at (240, 136) in the 16 px font and (120, 48) in the 8 x 12 font, 'c' at (48, 136) and (24, 48) (pixel dumps of both cells, and the exported text.json). Card text draws with the 8 x 12 font. The 'o' and 'm' in docs/card-text-check.png could not be traced to the data. | not fixed (not reproduced) | Needs a windowed capture of a card description to see which cell is drawn. The check image is newer than the export. |
| 25 | Bust idle animation (blink, mouth) | not implemented. The bake holds the first frame of each layer only; the game's idle rule was not traced in this pass. | not fixed | Needs the bust state machine and the extra frames from the sprite streams in bake_busts. |
| 26 | Bust blend | whether the game draws busts with semi-transparency was not checked. | not fixed (not checked) | Not traced. |
| 27 | Colour ramps | colour values 0-6 index the seven CLUT ramps: 0 white, 1 yellow, 2 blue, 3 green, 4 grey, 5 orange, 6 red (hue of the ramp pictures). | verified (ramps) | assets/screens/font/ramp_N.png pixel hues. |

## Scenes

Ends: the endings the runs reached (map place or argument, duel, gameover, credits). Dialogs: distinct text boxes the scene can reach. Text ops: the primary control bytes in those boxes (static). F8: the sub-opcodes used. Approximated: the approximations the runs hit (see the findings). Missing art: picture, bust or portrait files the scene needs and the disc does not have. Problems: anything the harness or the static walk flagged.

| Scene | Ends | Dialogs | Text ops | F8 | Approximated | Missing art | Problems |
|---|---|---|---|---|---|---|---|
| 000 | map 0 | 0 | none | none | - | none | ok |
| 001 | map 0 | 0 | none | none | - | none | ok |
| 002 | credits 0 | 0 | none | none | - | none | ok |
| 003 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 004 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 005 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 006 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 007 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 008 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 009 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 00A | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 00B | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 00C | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 00D | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 00E | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 00F | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 010 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 011 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 012 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 013 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 014 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 015 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 016 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 017 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 018 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 019 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 01A | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 01B | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 01C | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 01D | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 01E | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 01F | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 020 | map 0 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 021 | duel (opp 17, win scene 08E, lose scene 08F, terrain 1), map 1 | 2 | F6 6, F8 2, F9 5, FA 4, FC 1, FE 3, FF 3 | 0d, 11 | - | none | ok |
| 022 | duel (opp 1B, win scene 096, lose scene 097, terrain 2), map 2 | 2 | F6 6, F8 2, F9 6, FA 4, FC 1, FE 2, FF 3 | 0d, 11 | - | none | ok |
| 023 | map 3 | 1 | F6 3, F9 3, FA 10, FB 2, FD 1, FE 12 | none | f8_15_fade | none | ok |
| 024 | duel (opp 15, win scene 08A, lose scene 08B, terrain 5), map 4 | 2 | F6 6, F8 2, F9 5, FA 4, FC 1, FE 2, FF 3 | 0d, 11 | - | none | ok |
| 025 | map 5 | 1 | FF 1 | none | - | none | ok |
| 026 | duel (opp 19, win scene 092, lose scene 093, terrain 3), map 6 | 2 | F6 6, F8 2, F9 5, FA 4, FC 1, FE 2, FF 3 | 0d, 11 | - | none | ok |
| 027 | map 7 | 1 | F6 6, F8 1, FC 1, FF 2 | 16 | - | none | ok |
| 028 | duel (opp 1D, win scene 09A, lose scene 09B, terrain 4), map 8 | 2 | F6 6, F8 2, F9 5, FA 4, FC 1, FE 3, FF 3 | 0d, 11 | - | none | ok |
| 029 | map 9, duel (opp 21, win scene 09E, lose scene 09F, terrain 6) | 1 | F6 1, F9 1, FA 1, FE 2, FF 1 | none | f8_10_voice, f8_15_fade | none | ok |
| 02A | map 10 | 1 | F9 1, FA 1, FE 1, FF 1 | none | - | none | ok |
| 02B | map 11 | 2 | F6 11, F8 1, F9 1, FA 8, FE 7, FF 2 | 16 | - | none | ok |
| 02C | duel (opp 02, win scene 062, lose scene 063, terrain 0), map 10, map 12 | 4 | F6 71, F7 1, F8 4, F9 2, FA 29, FB 6, FC 9, FD 1, FE 41, FF 10 | 0e, 11, 15 | f8_15_fade | none | ok |
| 02D | map 13 | 2 | FA 1, FF 2 | none | - | none | ok |
| 02E | duel (opp 01, win scene 060, lose scene 061, terrain 0), map 14 | 26 | F6 280, F7 41, F8 99, F9 2, FA 228, FB 8, FC 9, FD 10, FE 203, FF 31 | 0d, 0e, 10, 11, 15, 16 | - | none | ok |
| 02F | map 15 | 1 | F9 2, FA 2, FB 2, FE 3 | none | f8_15_fade | none | ok |
| 030 | map 14 | 3 | F7 6, F8 7, FA 8, FB 2, FD 1, FE 11, FF 2 | 02, 0a, 0e, 10, 15, 16 | f8_10_voice, f8_15_fade | none | ok |
| 031 | map 14 | 1 | FF 1 | none | - | none | ok |
| 032 | map 14 | 1 | F6 1, FA 3, FB 2, FE 6 | none | f8_15_fade | none | ok |
| 033 | map 11 | 2 | F6 11, F8 1, F9 1, FA 8, FE 7, FF 2 | 16 | - | none | ok |
| 034 | map 11 | 1 | F6 1, FA 1, FE 2, FF 1 | none | - | none | ok |
| 035 | duel (opp 03, win scene 06E, lose scene 06F, terrain 0), duel (opp 04, win scene 070, lose scene 071, terrain 0), map 12 | 1 | F6 7, FA 1, FB 2, FC 1, FE 4, FF 1 | none | - | none | ok |
| 036 | duel (opp 08, win scene 074, lose scene 075, terrain 6) | 22 | F6 272, F7 41, F8 99, F9 2, FA 218, FB 2, FC 8, FD 10, FE 186, FF 29 | 0d, 0e, 10, 11, 15, 16 | f8_15_fade | none | ok |
| 037 | duel (opp 08, win scene 074, lose scene 075, terrain 6) | 1 | F6 81, F7 13, F8 12, F9 1, FA 44, FB 2, FC 4, FD 4, FE 36, FF 4 | 0e, 10, 11, 15, 16 | f8_15_fade | none | ok |
| 038 | map 10 | 1 | F9 1, FA 1, FE 1, FF 1 | none | - | none | ok |
| 039 | duel (opp 09, win scene 076, lose scene 077, terrain 0) | 21 | F6 191, F7 28, F8 87, F9 1, FA 174, FC 4, FD 6, FE 150, FF 25 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 03A | duel (opp 09, win scene 076, lose scene 077, terrain 0) | 20 | F6 142, F7 21, F8 74, F9 1, FA 133, FC 3, FD 4, FE 109, FF 23 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 03B | duel (opp 0A, win scene 078, lose scene 079, terrain 0) | 18 | F6 138, F7 20, F8 69, F9 1, FA 127, FC 3, FD 3, FE 106, FF 21 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 03C | duel (opp 0B, win scene 07A, lose scene 07B, terrain 0) | 16 | F6 134, F7 19, F8 64, F9 1, FA 123, FC 3, FD 3, FE 101, FF 19 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 03D | duel (opp 0C, win scene 07C, lose scene 07D, terrain 0) | 14 | F6 130, F7 18, F8 59, F9 1, FA 119, FC 3, FD 3, FE 99, FF 17 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 03E | duel (opp 0D, win scene 07E, lose scene 07F, terrain 0) | 12 | F6 126, F7 17, F8 54, F9 1, FA 115, FC 3, FD 3, FE 96, FF 15 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 03F | duel (opp 0E, win scene 080, lose scene 081, terrain 0) | 10 | F6 41, F7 8, F8 27, F9 1, FA 41, FC 3, FE 42, FF 13 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 040 | duel (opp 0F, win scene 082, lose scene 083, terrain 0) | 8 | F6 36, F7 6, F8 22, F9 1, FA 34, FC 3, FE 35, FF 11 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 041 | duel (opp 10, win scene 084, lose scene 085, terrain 0) | 6 | F6 32, F7 5, F8 17, F9 1, FA 31, FC 3, FE 31, FF 9 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 042 | duel (opp 11, win scene 086, lose scene 087, terrain 0) | 4 | F6 28, F7 4, F8 12, F9 1, FA 27, FC 3, FE 27, FF 7 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 043 | map 5 | 1 | FF 1 | none | - | none | ok |
| 044 | map 5 | 1 | FF 1 | none | - | none | ok |
| 045 | map 5 | 1 | FF 1 | none | - | none | ok |
| 046 | map 5 | 1 | FF 1 | none | - | none | ok |
| 047 | map 5 | 1 | FF 1 | none | - | none | ok |
| 048 | map 5 | 1 | FF 1 | none | - | none | ok |
| 049 | map 5 | 1 | FF 1 | none | - | none | ok |
| 04A | map 5 | 2 | F6 24, F7 3, F8 7, F9 1, FA 19, FC 3, FE 21, FF 5 | 11, 15, 16 | f8_15_fade | none | ok |
| 04B | map 5 | 1 | FA 2, FE 1, FF 1 | none | - | none | ok |
| 04C | map 14 | 1 | FA 1, FB 2, FE 2 | none | - | none | ok |
| 04D | map 14 | 1 | F6 1, FA 1, FB 2, FE 2 | none | f8_15_fade | none | ok |
| 04E | map 13 | 1 | FA 1, FF 1 | none | - | none | ok |
| 04F | duel (opp 13, win scene 0B1, lose scene 0B2, terrain 0), duel (opp 14, win scene 0B3, lose scene 0B4, terrain 0), map 15, map 12 | 2 | F6 57, F7 1, F8 4, F9 1, FA 25, FB 2, FC 7, FD 1, FE 32, FF 8 | 0e, 11, 15 | f8_15_fade | none | ok |
| 050 | map 4 | 1 | FF 1 | none | - | none | ok |
| 051 | map 1 | 1 | FF 1 | none | - | none | ok |
| 052 | map 6 | 1 | FF 1 | none | - | none | ok |
| 053 | map 2 | 1 | FF 1 | none | - | none | ok |
| 054 | map 8 | 1 | FF 1 | none | - | none | ok |
| 055 | duel (opp 13, win scene 0B1, lose scene 0B2, terrain 0), duel (opp 14, win scene 0B3, lose scene 0B4, terrain 0), map 15 | 1 | F6 57, F7 1, F8 4, F9 1, FA 25, FB 2, FC 7, FD 1, FE 31, FF 7 | 0e, 11, 15 | f8_15_fade | none | ok |
| 056 | map 8 | 1 | FF 1 | none | - | none | ok |
| 057 | map 8 | 1 | FF 1 | none | - | none | ok |
| 058 | map 8 | 1 | FF 1 | none | - | none | ok |
| 059 | map 8 | 1 | FF 1 | none | - | none | ok |
| 05A | duel (opp 21, win scene 09E, lose scene 09F, terrain 6) | 5 | F6 25, F7 8, F8 18, FA 36, FB 2, FC 1, FD 1, FE 42, FF 5 | 0d, 0e, 10, 11, 15 | f8_15_fade | none | ok |
| 05B | duel (opp 23, win scene 0A2, lose scene 0A3, terrain 6) | 4 | F6 16, F7 7, F8 13, FA 31, FB 2, FC 1, FD 1, FE 39, FF 4 | 0d, 0e, 10, 11, 15 | - | none | ok |
| 05C | duel (opp 24, win scene 0A4, lose scene 0A5, terrain 0) | 3 | F6 16, F7 7, F8 11, FA 27, FB 2, FC 1, FD 1, FE 36, FF 3 | 0d, 0e, 10, 11, 15 | f8_15_fade | none | ok |
| 05D | duel (opp 25, win scene 0A6, lose scene 0A7, terrain 0) | 2 | F6 3, F7 1, F8 1, FA 8, FB 2, FD 1, FE 11, FF 1 | 0e | f8_10_voice, f8_15_fade | none | ok |
| 05E | map 8 | 1 | FF 1 | none | - | none | ok |
| 05F | map 8 | 1 | FF 1 | none | - | none | ok |
| 060 | map 14 | 1 | F8 2, FA 3, FE 4, FF 1 | 16, 19 | - | none | ok |
| 061 | gameover 0 | 1 | FA 2, FE 4, FF 1 | none | - | none | ok |
| 062 | map 10, duel (opp 04, win scene 064, lose scene 065, terrain 0) | 1 | F8 1, FA 2, FB 2, FE 5 | 19 | f8_15_fade | none | ok |
| 063 | gameover 0 | 1 | F6 6, FA 1, FC 1, FE 3, FF 2 | none | - | none | ok |
| 064 | map 10, duel (opp 05, win scene 066, lose scene 067, terrain 0) | 1 | F8 1, FA 1, FB 2, FE 3 | 19 | f8_15_fade | none | ok |
| 065 | gameover 0 | 1 | FE 1, FF 1 | none | - | none | ok |
| 066 | map 10, duel (opp 06, win scene 068, lose scene 069, terrain 0) | 1 | F8 1, FA 1, FB 2, FE 3 | 19 | f8_15_fade | none | ok |
| 067 | gameover 0 | 1 | FE 2, FF 1 | none | - | none | ok |
| 068 | map 10, duel (opp 02, win scene 062, lose scene 063, terrain 0) | 1 | F8 1, FA 2, FB 2, FE 3 | 19 | f8_15_fade | none | ok |
| 069 | gameover 0 | 1 | FA 1, FE 2, FF 1 | none | - | none | ok |
| 06A | duel (opp 07, win scene 06C, lose scene 06D, terrain 0) | 1 | F6 20, F7 4, F8 3, FA 9, FC 2, FD 1, FE 8, FF 3 | 0d, 11, 19 | - | none | ok |
| 06B | gameover 0 | 1 | F6 6, FA 1, FC 1, FE 2, FF 2 | none | - | none | ok |
| 06C | duel (opp 04, win scene 070, lose scene 071, terrain 0), map 12 | 1 | F6 27, F8 1, FA 12, FB 2, FC 3, FD 2, FE 11, FF 3 | 19 | - | none | ok |
| 06D | gameover 0 | 1 | FA 1, FE 2, FF 1 | none | - | none | ok |
| 06E | map 12 | 1 | F8 1, FA 2, FB 2, FE 3 | 19 | - | none | ok |
| 06F | gameover 0 | 1 | F6 6, FA 1, FC 1, FE 2, FF 2 | none | - | none | ok |
| 070 | duel (opp 03, win scene 06E, lose scene 06F, terrain 0), map 12, duel (opp 05, win scene 072, lose scene 073, terrain 0) | 1 | F8 1, F9 1, FA 2, FB 2, FE 4 | 19 | - | none | ok |
| 071 | gameover 0 | 1 | FE 1, FF 1 | none | - | none | ok |
| 072 | map 12 | 1 | F6 1, F8 1, F9 1, FA 2, FB 2, FE 4 | 19 | - | none | ok |
| 073 | gameover 0 | 1 | FA 1, FF 1 | none | - | none | ok |
| 074 | duel (opp 08, win scene 074, lose scene 075, terrain 6) | 1 | F8 1, FA 2, FE 1, FF 1 | 0d | - | none | ok |
| 075 | duel (opp 09, win scene 076, lose scene 077, terrain 0) | 22 | F6 200, F7 29, F8 91, F9 1, FA 183, FB 2, FC 4, FD 6, FE 161, FF 25 | 0d, 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 076 | duel (opp 0A, win scene 078, lose scene 079, terrain 0) | 19 | F6 139, F7 21, F8 72, F9 1, FA 129, FC 3, FD 3, FE 106, FF 22 | 0d, 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 077 | gameover 0 | 1 | FA 1, FE 2, FF 1 | none | - | none | ok |
| 078 | duel (opp 0B, win scene 07A, lose scene 07B, terrain 0) | 17 | F6 135, F7 20, F8 67, F9 1, FA 125, FC 3, FD 3, FE 103, FF 20 | 0d, 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 079 | gameover 0 | 1 | FA 1, FE 3, FF 1 | none | - | none | ok |
| 07A | duel (opp 0C, win scene 07C, lose scene 07D, terrain 0) | 15 | F6 131, F7 19, F8 62, F9 1, FA 121, FC 3, FD 3, FE 100, FF 18 | 0d, 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 07B | gameover 0 | 1 | FA 1, FE 1, FF 1 | none | - | none | ok |
| 07C | duel (opp 0D, win scene 07E, lose scene 07F, terrain 0) | 13 | F6 127, F7 18, F8 57, F9 1, FA 117, FC 3, FD 3, FE 97, FF 16 | 0d, 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 07D | gameover 0 | 1 | FA 1, FE 1, FF 1 | none | - | none | ok |
| 07E | duel (opp 0E, win scene 080, lose scene 081, terrain 0) | 11 | F6 48, F7 12, F8 35, F9 1, FA 46, FC 3, FE 48, FF 14 | 0d, 0e, 10, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 07F | gameover 0 | 1 | FA 1, FE 2, FF 1 | none | - | none | ok |
| 080 | duel (opp 0F, win scene 082, lose scene 083, terrain 0) | 9 | F6 41, F7 10, F8 30, F9 1, FA 39, FC 3, FE 40, FF 12 | 0d, 0e, 10, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 081 | gameover 0 | 1 | FA 1, FE 1, FF 1 | none | - | none | ok |
| 082 | duel (opp 10, win scene 084, lose scene 085, terrain 0) | 7 | F6 35, F7 8, F8 25, F9 1, FA 34, FC 3, FE 32, FF 10 | 0d, 0e, 10, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 083 | gameover 0 | 1 | FA 1, FE 2, FF 1 | none | - | none | ok |
| 084 | duel (opp 11, win scene 086, lose scene 087, terrain 0) | 5 | F6 31, F7 7, F8 20, F9 1, FA 30, FC 3, FE 29, FF 8 | 0d, 0e, 10, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 085 | gameover 0 | 1 | FA 1, FE 3, FF 1 | none | - | none | ok |
| 086 | map 5 | 3 | F6 37, F7 9, F8 19, F9 1, FA 26, FC 4, FD 1, FE 25, FF 7 | 10, 11, 15, 16, 19 | f8_10_voice, f8_15_fade | none | ok |
| 087 | gameover 0 | 1 | FA 2, FE 3, FF 1 | none | - | none | ok |
| 088 | map 14 | 1 | F6 1, F8 1, F9 2, FA 3, FD 2, FE 2, FF 1 | 19 | - | none | ok |
| 089 | gameover 0 | 1 | FA 1, FE 1, FF 1 | none | - | none | ok |
| 08A | duel (opp 16, win scene 08C, lose scene 08D, terrain 5), map 4 | 1 | F6 1, F8 1, FA 3, FB 2, FE 4 | 19 | f8_15_fade | none | ok |
| 08B | gameover 0 | 1 | FA 1, FE 1, FF 1 | none | - | none | ok |
| 08C | map 4 | 1 | F6 15, F7 3, F8 7, F9 7, FA 6, FC 2, FD 1, FE 8, FF 3 | 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 08D | gameover 0 | 1 | FA 1, FF 1 | none | - | none | ok |
| 08E | duel (opp 18, win scene 090, lose scene 091, terrain 1), map 1 | 1 | F6 1, F8 1, FA 2, FB 2, FE 3 | 19 | f8_15_fade | none | ok |
| 08F | gameover 0 | 1 | FA 1, FE 2, FF 1 | none | - | none | ok |
| 090 | map 1 | 1 | F6 15, F7 2, F8 7, F9 7, FA 7, FC 2, FD 1, FE 7, FF 3 | 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 091 | gameover 0 | 1 | FA 1, FE 1, FF 1 | none | - | none | ok |
| 092 | duel (opp 1A, win scene 094, lose scene 095, terrain 3), map 6 | 1 | F6 1, F8 1, FA 2, FB 2, FE 3 | 19 | f8_15_fade | none | ok |
| 093 | gameover 0 | 1 | FA 1, FE 1, FF 1 | none | - | none | ok |
| 094 | map 6 | 1 | F6 15, F7 2, F8 7, F9 7, FA 6, FC 2, FD 1, FE 7, FF 3 | 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 095 | gameover 0 | 1 | FA 1, FE 3, FF 1 | none | - | none | ok |
| 096 | duel (opp 1C, win scene 098, lose scene 099, terrain 2), map 2 | 1 | F6 1, F8 1, FA 2, FB 2, FE 3 | 19 | f8_15_fade | none | ok |
| 097 | gameover 0 | 1 | FA 1, FE 2, FF 1 | none | - | none | ok |
| 098 | map 2 | 1 | F6 15, F7 2, F8 7, F9 7, FA 5, FC 2, FD 1, FE 6, FF 3 | 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 099 | gameover 0 | 1 | FA 1, FF 1 | none | - | none | ok |
| 09A | duel (opp 1E, win scene 09C, lose scene 09D, terrain 4), map 8 | 1 | F6 7, F8 1, FA 2, FB 2, FC 1, FE 4, FF 1 | 19 | f8_15_fade | none | ok |
| 09B | gameover 0 | 1 | FA 1, FE 2, FF 1 | none | - | none | ok |
| 09C | map 8 | 1 | F6 15, F7 2, F8 7, F9 7, FA 6, FC 2, FD 1, FE 8, FF 3 | 0e, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 09D | gameover 0 | 1 | FA 1, FE 1, FF 1 | none | - | none | ok |
| 09E | duel (opp 22, win scene 0A0, lose scene 0A1, terrain 6) | 2 | F6 8, F8 3, FA 5, FC 1, FE 6, FF 3 | 0d, 11, 19 | - | none | ok |
| 09F | gameover 0 | 1 | FA 1, FE 3, FF 1 | none | - | none | ok |
| 0A0 | duel (opp 23, win scene 0A2, lose scene 0A3, terrain 6) | 5 | F6 14, F7 7, F8 17, F9 5, FA 27, FB 4, FC 1, FD 1, FE 35, FF 4 | 0d, 0e, 10, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 0A1 | gameover 0 | 1 | FA 1, FE 2, FF 1 | none | - | none | ok |
| 0A2 | duel (opp 24, win scene 0A4, lose scene 0A5, terrain 0) | 4 | F6 18, F7 8, F8 18, F9 5, FA 26, FB 4, FC 1, FD 1, FE 36, FF 3 | 0d, 0e, 10, 11, 15, 16, 19 | f8_15_fade | none | ok |
| 0A3 | gameover 0 | 1 | FA 1, FF 1 | none | - | none | ok |
| 0A4 | duel (opp 25, win scene 0A6, lose scene 0A7, terrain 0) | 3 | F6 1, F8 3, F9 5, FA 5, FB 4, FD 1, FE 7, FF 1 | 16, 19 | f8_10_voice, f8_15_fade | none | ok |
| 0A5 | gameover 0 | 1 | F6 6, FA 2, FC 1, FE 2, FF 2 | none | - | none | ok |
| 0A6 | duel (opp 26, win scene 0A8, lose scene 0A9, terrain 0) | 2 | F6 3, F8 5, FA 9, FE 12, FF 2 | 0d, 11, 15, 19 | f8_15_fade | none | ok |
| 0A7 | gameover 0 | 1 | F6 1, FA 5, FE 7, FF 1 | none | - | none | ok |
| 0A8 | credits 0 | 1 | F6 19, F7 9, F8 9, FA 11, FC 3, FD 1, FE 12, FF 4 | 0e, 10, 15, 16, 19 | f8_15_fade | none | ok |
| 0A9 | gameover 0 | 1 | FA 2, FE 2, FF 1 | none | - | none | ok |
| 0AA | duel (opp 23, win scene 0A2, lose scene 0A3, terrain 6) | 4 | F6 13, F7 6, F8 13, F9 5, FA 25, FB 4, FC 1, FD 1, FE 34, FF 3 | 0d, 0e, 10, 11, 15, 19 | - | none | ok |
| 0AB | duel (opp 24, win scene 0A4, lose scene 0A5, terrain 0) | 3 | F6 13, F7 6, F8 11, F9 5, FA 21, FB 4, FC 1, FD 1, FE 31, FF 2 | 0d, 0e, 10, 11, 15, 19 | f8_15_fade | none | ok |
| 0AC | duel (opp 25, win scene 0A6, lose scene 0A7, terrain 0) | 2 | F8 1, F9 5, FA 2, FB 4, FD 1, FE 6 | 19 | f8_10_voice, f8_15_fade | none | ok |
| 0AD | map 15, duel (opp 14, win scene 0B3, lose scene 0B4, terrain 0) | 1 | F8 1, F9 5, FA 2, FB 2, FD 1, FE 4 | 19 | - | none | ok |
| 0AE | map 15, duel (opp 14, win scene 0B3, lose scene 0B4, terrain 0) | 1 | F8 1, F9 5, FA 2, FB 2, FD 1, FE 4 | 19 | - | none | ok |
| 0AF | map 15, duel (opp 14, win scene 0B3, lose scene 0B4, terrain 0) | 1 | F8 1, F9 5, FA 2, FB 2, FD 1, FE 4 | 19 | - | none | ok |
| 0B0 | map 15, duel (opp 14, win scene 0B3, lose scene 0B4, terrain 0) | 1 | F8 1, F9 5, FA 2, FB 2, FD 1, FE 4 | 19 | - | none | ok |
| 0B1 | map 15, duel (opp 14, win scene 0B3, lose scene 0B4, terrain 0) | 1 | F8 1, F9 5, FA 2, FB 2, FD 1, FE 4 | 19 | - | none | ok |
| 0B2 | gameover 0 | 1 | F9 5, FA 1, FD 1, FE 1, FF 1 | none | - | none | ok |
| 0B3 | map 15, duel (opp 04, win scene 0B5, lose scene 0B6, terrain 0) | 1 | F8 1, F9 5, FA 2, FB 2, FD 1, FE 3 | 19 | - | none | ok |
| 0B4 | gameover 0 | 1 | F9 5, FA 1, FD 1, FE 3, FF 1 | none | - | none | ok |
| 0B5 | duel (opp 13, win scene 0B1, lose scene 0B2, terrain 0), map 15, duel (opp 05, win scene 0B7, lose scene 0B8, terrain 0) | 1 | F8 1, F9 5, FA 1, FB 2, FD 1, FE 3 | 19 | - | none | ok |
| 0B6 | gameover 0 | 1 | F6 6, F9 5, FA 1, FC 1, FD 1, FE 3, FF 2 | none | - | none | ok |
| 0B7 | map 15 | 1 | F8 1, F9 5, FA 2, FB 2, FD 1, FE 3 | 19 | - | none | ok |
| 0B8 | gameover 0 | 1 | F9 5, FA 1, FD 1, FE 2, FF 1 | none | - | none | ok |
| 0B9 | duel (opp 1F, win scene 0B9, lose scene 0BA, terrain 0) | 2 | F6 3, F8 1, F9 5, FA 2, FB 2, FE 6, FF 1 | 19 | f8_15_fade | none | ok |
| 0BA | gameover 0 | 1 | FE 2, FF 1 | none | - | none | ok |
| 0BB | map 15 | 1 | F6 30, F7 1, F8 3, FA 12, FC 3, FD 1, FE 11, FF 4 | 0e, 11, 19 | - | none | ok |
| 0BC | gameover 0 | 1 | FA 2, FE 4, FF 1 | none | - | none | ok |
| 0BD | duel (opp 09, win scene 076, lose scene 077, terrain 0) | 20 | F6 142, F7 21, F8 74, F9 1, FA 131, FC 3, FD 4, FE 108, FF 23 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 0BE | duel (opp 0A, win scene 078, lose scene 079, terrain 0) | 18 | F6 138, F7 20, F8 69, F9 1, FA 126, FC 3, FD 3, FE 105, FF 21 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 0BF | duel (opp 0B, win scene 07A, lose scene 07B, terrain 0) | 16 | F6 134, F7 19, F8 64, F9 1, FA 122, FC 3, FD 3, FE 101, FF 19 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 0C0 | duel (opp 0C, win scene 07C, lose scene 07D, terrain 0) | 14 | F6 130, F7 18, F8 59, F9 1, FA 118, FC 3, FD 3, FE 99, FF 17 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 0C1 | duel (opp 0D, win scene 07E, lose scene 07F, terrain 0) | 12 | F6 126, F7 17, F8 54, F9 1, FA 114, FC 3, FD 3, FE 94, FF 15 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 0C2 | duel (opp 0E, win scene 080, lose scene 081, terrain 0) | 10 | F6 41, F7 8, F8 27, F9 1, FA 40, FC 3, FE 41, FF 13 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 0C3 | duel (opp 0F, win scene 082, lose scene 083, terrain 0) | 8 | F6 36, F7 6, F8 22, F9 1, FA 33, FC 3, FE 34, FF 11 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 0C4 | duel (opp 10, win scene 084, lose scene 085, terrain 0) | 6 | F6 32, F7 5, F8 17, F9 1, FA 30, FC 3, FE 30, FF 9 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 0C5 | duel (opp 11, win scene 086, lose scene 087, terrain 0) | 4 | F6 28, F7 4, F8 12, F9 1, FA 26, FC 3, FE 26, FF 7 | 0d, 0e, 11, 15, 16 | f8_15_fade | none | ok |
| 0C6 | map 15 | 1 | FF 1 | none | - | none | ok |

Totals: 199 scenes; approx 66, no text boxes 3.

## Harness output

`build/story_audit.json` (the harness output) holds every run's pick, flags, ending, frames, offered choices and event counts. The event names are the ones in `tests/README.md`.
