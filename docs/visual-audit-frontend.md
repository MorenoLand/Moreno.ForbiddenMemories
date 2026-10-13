# Visual audit: front-end screens

Scope: the boot splash, the title, the main menu (both pages, all eleven entries), the options screen, the New Game name entry
(keyboard, glyphs, caret, name field, dialogs 244 and 245, dialog arrow) and the one-box notices (the memory-card messages).

Method. Each screen was run in the port and captured state by state (every menu entry on, each dialog, each notice) and checked
against the original game's own drawing rules: what it draws, where, from which picture and palette row, and for how long. The
pictures are all baked from the disc by `tools/extract.py --screens`, so the checks cover the bake (sprite stream, page, palette
row, cell offset, crop offset) as well as the screen script (position, order, timing, sound). A picture is never taken from the
old `assets/images/` catalog for these screens; the screen scripts read only `assets/screens/`.

Evidence names refer to captures kept in the audit's scratch folder (not in the repository).

## Checklist

| Element | Original (what it draws) | Port status | Evidence |
|---|---|---|---|
| Konami logo picture | Full-screen picture from the boot package image and palette; fades in 12 steps a frame, held 4 frames | OK. Baked from the disc (`assets/screens/boot_0.png`); timing as the original | boot_0_logo |
| Konami Computer Entertainment Japan picture | Second boot picture, held 180 frames; Start or Cross skips; fades out 12 a frame | OK. Baked (`boot_1.png`); hold and skip as the original | boot_1_japan |
| Title wall | 64-pixel tiles of a 256-wide texture (4-bit, palette row 244), darkened top to bottom by a subtractive gradient on the menu | OK. The bake reproduces the tile order and palette; the gradient is drawn behind the logo | title_pulse_a |
| Title logo (Yu-Gi-Oh! Forbidden Memories) | Object at (0,0), stream (5,0,0) of the menu bank, 8-bit page 0x1A, cell offset on | OK. Cut-out at (11,16) | title_pulse_a |
| Copyright line | Object at (0,8), stream (5,0,2), cell offset on | OK. Cut-out at (61,200). Shows at half brightness on the menu, as the darkening covers all logo objects | title_pulse_a, z_title_copy2 |
| PUSH START BUTTON | Object at (0,8), stream (5,0,1); colour runs between 0x41 and 0x80 with a hold of 60 frames at the top; starts at 0x80 | OK. Pulse timing and colour steps match. Cut-out at (46,177) | title_pulse_a, title_pulse_b |
| Menu entries 0 to 10, selected and not | Each entry is a sprite at x 0xA0, y i*32+50 (i below 5) or (i-5)*32+42; variant i*2 when selected, i*2+1 when not | OK. All 22 pictures baked; each cut-out sits at its object's position. Each selected entry is the bright variant | menu_page1_new_game, menu_page1_load, menu_page1_2p_duel, menu_page1_trade, menu_page1_option, menu_entry_00 to menu_entry_10 |
| Entry slide in and out | Entries slide 16 frames along a sine ease, from -0xA0 or 0x1E0 (alternating), with an afterimage each odd frame; the page turns on the LOAD entry | OK. Same sequence in the port; afterimages fade 8 a frame | menu_entry_05 (page 2 at rest) |
| Menu darkening | Flat subtractive shade of 0x80 once the title is left | OK | menu_entry_04 |
| Cursor sounds | Move 6, confirm 7, cancel 8, refuse 9 | OK | (code) |
| Options background | Options picture (options bank, page 16, palette row 240) at (0,0): frame, OPTION heading, speaker, logo panel | OK. Baked | opt_stereo |
| Options text | String 239 at (24,56), advance 8 by 12, colour slots 0,4,4,4,2 | OK | opt_stereo, opt_mono |
| Options cursor | Star at label x plus 8 and y 0x50; label x 0x68 (stereo) or 0xC8 (mono); sprite offset (-7,-8) | OK. Moves between STEREO and MONO on Left and Right | opt_stereo, opt_mono |
| Options sounds | Output change 0x2F, return 8 | OK | (code) |
| Name entry backdrop | Picture at 50 percent (dim grey) | OK | name_150 |
| Keyboard grid | String 242 at (22,24), advance 20 by 18 | OK | name_150, name_dismissed |
| Side glyphs (arrows and END) | String 243 at (262,60), advance 20 by 18 | OK | name_dismissed |
| Selection frame | Four green corner brackets and four green-to-black lines through the cell's centre | OK. Frame moves to the cell (checked at M) | name_moved_ds |
| Caret | 32 by 32 ring, half transparent, at (107,199); moves 16 pixels per name slot | OK. Moves after a letter lands | name_dismissed, name_after_a |
| Name field | Six glyph slots at (112,204), 16 apart; glyphs fly in and pulse | OK. First letter lands in slot 1 | name_after_a |
| Dialog 244 (Input your NAME!) | Panel slides up 72 pixels (248 to 176); text at (16,176) with a per-glyph reveal | OK | name_150 |
| Dialog arrow | Three-frame blink at the box corner (box x + width - 16, y + height - 16) | OK | name_150 |
| Dialog 245 (Your NAME is X, YES / NO) | Name stream after the text; yellow choice bar on the first line; YES and NO lines | OK. The mark after the name is glyph 48 (U+2212) from the game's own string | name_confirm_late |
| Notice frame | Caution-striped frame sprite at (32,80) (offset -8,-10 from the object origin) | FIXED. Previously a plain story frame at the bottom of the screen | card_ce_open, card_d3_open |
| Notice text | Text box at (32,80), 256 by 48; positioning codes (pen x) honoured | FIXED. Previously drawn at (16,176) | card_ce_open, card_d3_open |
| Notice slide | Frame slides in from y -64 to 80 and out to 256, 16 frames each, sine ease | FIXED. Previously no slide | card_ce_t4, card_ce_closing |
| Notice dim | None in the original (the dark area is the frame's own picture) | FIXED. The 55 percent black layer was removed | card_ce_open |
| Notice glyph reveal | Each glyph comes in with the text box effect, one every 2 frames | ADDED. Same effect as dialog 244 | card_d3_open |

## Fixed in this pass

1. Notices (memory-card messages: UNABLE TO LOCATE LOAD DATA, NO DATA, MEMORY CARD REQUIRED, SAVING, SAVE INCOMPLETE). The port
   drew them in the story's bottom frame with a dim layer. The original draws a caution-striped frame sprite at (32,80), with the
   text box inside it, and slides it in and out. The frame is now baked from the disc
   (`tools/extract.py --screens`, new output `assets/screens/card_frame/`, function `bake_card_frame`) and drawn at its offset.
   `scripts/ui/message_box.gd` now places the frame and text at (32,80), slides it, reveals the glyphs, and no longer dims.

## Checked and left as they are

- Every bake of the front-end pictures was checked against its stream, page, palette row and cell-offset flag. The menu and
  logo headers carry CLUT offsets that apply only where the cell-offset flag is set; both are set for the logo objects and not for
  the menu entries, and the bake agrees with both.
- The entry sprite and the logo object lists match the original's variant numbers.
- The name-entry dialog slide (72 pixels) and the message box's text origin (y minus 2, as the story dialog) match.
- The old `assets/images/` catalog is not read by any front-end screen (checked by search of the screen scripts).

## Remaining

- Sound: while dialog 244 waits for a press, the original's code plays one sound effect per frame (its effect id 11). The port
  stays silent there. This is an audio check and was not changed.
- Entry colour at the very start: the title's PUSH START starts at the object default (0x80) in the port. The original's object
  default is the same value, so the first second matches, but it was not confirmed on a running disc.
- The glyph flight and shatter effects of the name entry (glyphs flying to the name field and breaking up on arrival) are checked
  by code only; no capture of the mid-flight frames was taken.
- Port-only additions, not in the original: mouse hover and click on the menus, the name entry and the options; F1 quick save.
- No emulator is installed on this machine, so the comparison is against the disc data and the original's drawing rules, not a
  rendered reference frame.
