# Visual audit: the collection and management screens

Status of each display element on the Library, Build Deck, Free Duel, Password, Trade, two-player setup and the Save and Load
notices. "Fixed" means the port now matches the disc data and the original's element positions, and a screenshot shows it. "Open"
means the element is still a stand-in or is known to differ. "Reviewed" means a screenshot was looked at and no defect was seen,
but the element was not compared position by position. "Not audited" means it was not checked.

Evidence screenshots are kept outside the project (in the session scratchpad, not in the repository, since they contain disc art).
The names below refer to them.

## Library (scripts/menu/library.gd, assets/screens/library/)

| Element | Original source (plain words) | Port status | Evidence |
| --- | --- | --- | --- |
| Eight stone section panels, range numbers 100 and 101/200 | Resident bank group 3, streams 0-7, page 25, palette row 246 | Matches the stream layout (not changed) | library-grid.png |
| Card tiles (monster, magic/equip, trap, ritual colours) | Page 27 tile at (96, 240), four palette rows | Matches; unowned cards at half brightness | library-grid.png |
| Seen-card gating (unseen cells empty) | Card seen flag | Matches | library-grid.png |
| Counter "<n/722>" heading | Text, font glyphs | Matches | library-grid.png |
| Green crosshair through the cursor | Drawn lines, pulsing colour | Matches the cycle | library-cursor-zoom.png |
| Cursor sprite (magnifier) | Page 27, texels (112, 224), 16 x 16, palette row 247 at x 320, offset -8,-8 from the cell | **Fixed.** Was a noise square cut from texels (112, 96), which are texture noise | library-cursor-zoom.png |
| Info band (bottom stone bar with X boxes) | Object at (16, 216): page 27, palette (288, 247), bank group 2 stream 1 | Kept. Its pieces and palette follow the original's object setup; the stone look is consistent with the other stone pieces. Visual check against the original still advised | library-grid.png |
| Info text "e nnn" and card name | Text lines at (16, 202) and (16, 216) | Matches the layout | library-grid.png |
| Card view box (frame at 148, 14) | The library's own frame object (bank group 2, stream 0), rests at the box origin | **Fixed.** Was a nine-slice of the campaign dialog frame; now the disc's frame picture (assets/screens/library/card_frame.png) | library-card-view.png |
| Card picture (102 x 96 at box + (19, 50)) | Card detail routine: picture rectangle at its +0x13, +0x32 | **Fixed.** Was at (23, 62), over the grid; now at (167, 64) inside the box | library-card-view.png |
| Type on the name band ("Fairy") | Name band across the top of the box | Placed in the top band at (160, 16). The original's exact text position for the type is not confirmed | card_monster5.png (not kept) |
| Spell and trap cards (no ATK/DEF, no stars) | Layouts 4: the card-kind label and the attribute ball | Trap shows its label and ball; magic and ritual show the normal magic label (the sheet has no ritual label; open) | card_Trap.png, card_Ritual.png (not kept) |
| GUARDIAN STAR heading and the two star names | Text script of layout 3: heading at box + (0, 24), star lines from y 40 on, 16 apart | Matches the script (y 38, 54, 70) | library-card-view.png |
| Monster description text | Not in the library card view: the library's box shows only the layout's own lines | **Fixed.** Removed from the library card view (it overlapped the picture) | - |
| ATK and DEF labels | Card detail routine: labels at box + (72, 158) and (72, 170) | **Fixed position.** Art: the sheet's ATK and DFD text at v 80 and 96 on page 31 (checked by rendering the sheet; the v 206 region is picture art, so the earlier assumption was wrong) | card_monster5.png (not kept) |
| ATK and DEF values | Four digit cells, 6 px apart, from box + (97, 157) and (97, 171); leading cells blank | **Fixed position and alignment.** The digits use the sheet's digit row at palette 248 as baked; they read dark grey on the navy frame. Colour is open for a check against the original | card_monster5.png, zoom (not kept) |
| Level stars | Star cells from box + (119, 32), running left 9 px each | **Fixed position** (five stars checked at the top right, beside the attribute) | card_monster5.png (not kept) |
| Attribute icon | Box + (110, 13) | **Fixed position**; a trap shows the trap ball at the same spot | card_Trap.png (not kept) |
| Guardian star names crossing the picture's top edge | Star line at y 70 (x 148 to about 210) and the picture at (167, 64) both come from the original's data | **Changed.** The picture is drawn over the box's text, so the opaque picture covers the crossing letters instead of printing over them. The original's draw order here is not confirmed | card_monster5.png (not kept) |

## Build Deck (scripts/menu/build_deck.gd, assets/screens/build_deck/)

| Element | Original source | Port status | Evidence |
| --- | --- | --- | --- |
| CHEST panel, ORDER bar and its icons, card count with red arrow | Build Deck bake | Reviewed in the chest state: no corrupt or missing pieces seen | build-deck-chest.png (not kept) |
| Rows, digits, ATK/DEF marks, NEW mark, cursor bar | Build Deck bake | Reviewed: rows and digits render; the NEW plate and the blue/orange cursor bars not compared position by position | not kept |
| Scroll thumb and arrows | Build Deck bake | Reviewed: present; animation not compared | not kept |
| Leave dialog (BUILD DECK / EXIT) | Text box with the dialog frame | **Fixed.** Was a flat black box; now the campaign dialog frame around the same rectangle (48, 96, 224 x 48), with the choice bar | build-deck-leave.png (not kept) |
| Card viewer (Triangle) | Not ported | Known missing | - |

## Free Duel (scripts/menu/free_duel.gd, assets/screens/free_duel/)

| Element | Original source | Port status | Evidence |
| --- | --- | --- | --- |
| Banner "FREE DUEL", frame and bottom band | Free Duel bake | Reviewed: present and not corrupt | free-duel-cell0.png (not kept) |
| Duelist portrait cell and cursor frame | Free Duel bake (portraits, cursor) | Reviewed: portrait shows; cursor frame shows on the cell | not kept |
| Name and record line ("Build Deck" on the first cell) | Text | Reviewed: present | not kept |
| Scrollbar thumb (green bar with a column of emblem marks over grey track stripes) | Free Duel bake (thumb.png) | Reviewed in close-up: no corrupt or misplaced pieces seen; the emblem marks are the baked thumb art, not compared with the original | free-duel-scroll-zoom.png (not kept) |

## Password (scripts/menu/password.gd, assets/screens/password/)

| Element | Original source | Port status | Evidence |
| --- | --- | --- | --- |
| Card picture, STARCHIP plate and count, digit row with the red cursor and arrows | Password bake (layout.json) | Reviewed in the entered-password state: no corrupt or missing pieces seen | password-entered.png (not kept) |
| CARD NUMBER and message box | Story dialog frame | Reviewed: frame and text shown | not kept |

## Trade (scripts/menu/trade.gd, assets/screens/card_ui/, assets/screens/backdrops/trade/)

| Element | Original source | Port status | Evidence |
| --- | --- | --- | --- |
| Sand, 1P and 2P panel grid, red cursor bar | Backdrops bake | Reviewed in the list state | trade-list.png (not kept) |
| **Offer type icons** | Card-kind icons (card_ui card_type_monster, magic, trap, ritual) | **Fixed.** Each offered card shows its type icon in the offer grid (five to a row), instead of its number | trade-offers.png (not kept) |
| **Column dim** | Dim state of the column that is not active | **Open.** Not implemented; the original's dim state was not located in this pass | - |

## Two-player setup (scripts/menu/two_player_setup.gd)

| Element | Original source | Port status | Evidence |
| --- | --- | --- | --- |
| Sand backdrop | Backdrops bake (sand.png) | Matches | two-player-setup.png |
| PLAYER 1 / PLAYER 2 labels, digits, prompts | Text and digit pieces | Matches (labels are font text, see the approximations in the script header) | two-player-setup.png |
| **Life point selector** | Value setup's framed bar | **Fixed.** The disc's red and gold bar (backdrops/trade/cursor.png) drawn as a nine-slice around the four digits | two-player-setup.png |

## Save and Load notices

| Element | Original source | Port status | Evidence |
| --- | --- | --- | --- |
| Save incomplete notice (SAVE INCOMPLETE!) | Caution banner box (message box) | Captured: caution banner, one line of text, matching the box style | notice_cd.png (not kept) |
| Load missing notice (UNABLE TO LOCATE LOAD DATA! / PLUG IN MEMORY CARD) | Caution banner, two lines; the second line's sweep is still animating at 240 frames | Captured after the sweep: both lines shown | notice_ce.png (not kept) |
| Third notice (string 0xCF) | Caution banner | Captured | notice_cf.png (not kept) |

## Remaining work (as of this pass)

1. Library card view: the digit colour (dark on the frame), the type text position on the name band, and the ritual label (the
   sheet has only the normal magic, trap and equip labels) need a check against the original screen.
2. Build Deck: the card viewer (Triangle) is still not ported. Also compare the NEW plate, the blue and orange cursor bars, the ORDER
   icon states per sort mode and the row dim state element by element; these were only reviewed in the chest state.
3. Trade: the dim state of the inactive column is not implemented.
4. Free Duel scrollbar thumb: reviewed only; compare against the original.
