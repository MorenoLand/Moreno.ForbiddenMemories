# Quality report

A check of the scripts, the extractor, the assets it writes and the repository layout, run on 2026-10-12. It lists what was checked,
what was fixed and what is left. Nothing here changes game behaviour.

## Parse check

Every script in `scripts/` and `tests/` (49 files) was loaded with the Redot 26.2 headless `--check-only` mode. All 49 parse and
compile. Two limits: `--check-only` does not print GDScript warnings in this build, so warnings were not counted; and the check
covers syntax and compile errors only, not runtime behaviour.

Warnings are on in `project.godot`, except two that stay off on purpose: `unused_parameter` (the screens' signal and input
callbacks have fixed signatures) and `integer_division` (the port keeps whole-number arithmetic on purpose).

## Unused declarations

A regex scan (`const`, `var`, `func`, `signal` declarations whose name appears nowhere else in the project). A name that is only
looked up by a string or a dynamic call would be a false positive, so check before deleting.

- `scripts/duel/ai_vm.gd`: const `TYPE_TRAP`, const `TYPE_RITUAL`, const `SEL_COMBO`
- `scripts/duel/duel_ai.gd`: func `uses_script`
- `scripts/duel/duel_card_face.gd`: const `BLANK_DIGIT`
- `scripts/duel/duel_result.gd`: func `starchips_after`
- `scripts/duel/duel_scene.gd`: var `card_backs`, const `CARD_FRAMES`, const `ICONS`, func `_tex`
- `scripts/duel/duel_state.gd`: const `HAND`
- `scripts/map/campaign_map.gd`: const `FOG_NEAR`, const `FOG_FAR`, const `SPOT_WIDTH`
- `scripts/menu/main_menu.gd`: func `_entry_y`
- `scripts/menu/trade.gd`: const `STRING_SETTLED`
- `scripts/runner/disc.gd`: func `open_image`, func `read_raw`
- `scripts/runner/input_map.gd`: func `note_event`, func `pad_word`
- `scripts/runner/spu.gd`: func `read16`, func `sync_from_ram`, func `take_events`, func `dma_write`, func `dma_read`
- `scripts/runner/str_movie.gd`: func `rewind`
- `scripts/state/game_state.gd`: func `mark_library_owned`
- `scripts/story/story_player.gd`: func `_bank_u16`, var `bust_expression`
- `scripts/system/touch_controls.gd`: func `is_shown`

Not removed: each is small and may be a planned hook. Remove them in a separate change once the owners agree.

## Scripts that nothing loads

Found by searching for each script's path and class name in the scenes, scripts and project file.

- `scripts/runner/input_map.gd`, `scripts/runner/settings_menu.gd`, `scripts/runner/controls_menu.gd`: a key rebinding screen and a
  sound and window settings screen. No scene or script creates them, so the bindings in the README are fixed. The F2 key used by the
  game is the stretch toggle in `scripts/system/screen_fit.gd`, not this settings screen.
- `scripts/runner/spu.gd`: a sound chip model. Nothing uses it.
- `scripts/runner/str_movie.gd` and `scripts/runner/mdec.gd`: the movie decoder. Only the test script `tests/godot/decode_movie.gd`
  uses them, so movies are not played in the game.
- `scripts/runner/disc.gd`: a runtime disc reader. Its helpers `open_image` and `read_raw` have no callers, and `open_folder` is
  only reached through `open_image`.
- `tests/godot/decode_movie.gd` and `tests/story_smoke.gd`: test scripts run by hand. They are not part of the game.

These are work in progress rather than stray files, so they were kept. Decide whether to wire them in or move them out.

## Extractor (`tools/extract.py`)

- The default run (everything) was run end to end from an empty folder: exit 0, no traceback, 184 seconds.
- Re-running the same command kept every existing file and wrote nothing new. A second run that rewrote nothing was confirmed by
  file modification times.
- Each section flag (`--cards`, `--tables`, `--images`, `--screens`, `--text`, `--audio`) was run alone, into its own folder. Each
  produced only its own outputs, and every file it produced is identical to the full run's output.
- `--no-mods`, `--mods-only` and `--mod` / `--mod-off` (checked with a scratch mod folder) run without errors. A missing mod folder
  stops with a clear message.
- The disc is read once per run. The disc image is opened once, and each section works on the bytes read from it. Nothing re-reads
  the disc.
- Unused: the constant `ORIGIN`, and the function `extract()`, which writes a folder of the disc's files. Nothing calls `extract()`,
  so the folder format read by the runner's disc reader has no producer on the command line.

Fixed in this audit:

- The module docstring said `--audio` was not part of the default run. It is part of it. The docstring also lacked two outputs
  (`data/starter_pools.json` and `data/ai_scripts/`), and had a doubled period.
- `-o` had no help text. It now says where the output goes.
- A fresh extraction did not produce the two Build Deck arrow pictures the game loads by name (`arrow_left.png`, `arrow_right.png`);
  the Build Deck would stop setting up. The extractor now writes the first animation frame under that name too. The result is
  byte-identical to the copies in the project.
- A fresh extraction now writes `assets/.gdignore`, so the Redot editor skips the baked folder.

## Assets folder (compared with a clean extraction)

Compared with a clean run of the current extractor (3,427 files, every one hashed). The project's `assets/` was not changed.

- Stale in the project: `screens/build_deck/arrow_left.png` and `arrow_right.png` were missing from a clean run. They are fixed in
  the extractor now; the copies in the project are correct.
- Stale in the project, with a different content: `audio/se/index.json` has 24 entries where the current extractor writes 50.
  `screens/duel_result/layout.json` lacks the `confetti` entry. Regenerate those two with
  `python tools/extract.py "<cue>" --audio --overwrite-only "audio/se/index.json"` and
  `--screens --overwrite-only "screens/duel_result/layout.json"`.
- The other 3,425 files matched exactly, and a 100-file sample byte comparison found no mismatch. No non-determinism was seen.
- The image catalog (`config/images.json`) has 2,777 entries but only 2,399 distinct output names. 42 names each have ten entries
  with different disc data, and only the last one written survives. The other nine variants per name are dropped silently. Decide
  whether these need distinct names; this is not changed here.
- Every PNG in `assets/images/` corresponds to a catalog name. No unused images were found there.

## Line endings

All scripts in `scripts/` and `tests/` that are not being edited now use LF, except the ones listed below. Converted to LF in this
audit: `tests/godot/decode_movie.gd`, `scripts/runner/mdec.gd`, `scripts/runner/input_map.gd`, `scripts/runner/disc.gd`,
`scripts/boot/boot.gd`, `scripts/system/game_audio.gd`, `scripts/system/touch_controls.gd`, and the docs `docs/card-ui-art.md`,
`docs/web-export.md`, `docs/touch-audit.md`, plus the rewritten `README.md`.

Still CRLF, left for a later pass because other agents are editing them: `scripts/duel/*` (ai_vm, duel_ai, duel_data, duel_effects,
duel_engine, duel_fx, duel_state), `scripts/menu/*` (build_deck, free_duel, library, options, trade, two_player_setup), and
`tools/extract.py`.

## Repository hygiene

- Deleted: `scripts/duel/_ai_vm_trace.gd.uid`, a leftover that had no script and no reference, and the `tools/__pycache__` cache.
- `.gitignore` now ignores the whole `assets/` folder (it held only two subfolders). The existing lines still cover `.godot/`,
  `build/`, `mods/`, `__pycache__/`, and the disc and user data formats.
- Every `.uid` file has its script.
- `project.godot`: main scene `scenes/main.tscn`; window 640 x 480 with canvas-items stretch and expand aspect;
  `input_devices/pointing/emulate_mouse_from_touch=true` (touch acts as a mouse) and `emulate_touch_from_mouse=false`.
- `docs/card-text-check.png` is not referenced by any document. It was not deleted.
- `docs/card-ui-sheet.png`, `docs/card-text-check.png` and `docs/story-pictures-sheet.png` (a contact sheet of 105 story pictures,
  4.9 MB) look like pictures baked from the disc. The README says the repository holds no game data, and `docs/` is not git-ignored.
  They were left in place; decide whether they stay in the repository.
- The Web export preset (`export_presets.cfg`) includes `assets/*` and `mods/*`, excludes `tools/*`, `tests/*`, `docs/*`, `build/*` and
  `*.py`. Its output is `build/web/index.html`, which is git-ignored.

## Trade, second card and 2P setup

Audit of the trade (`scripts/menu/trade.gd`) and the 2P duel setup (`scripts/menu/two_player_setup.gd`) against the original's
trade overlay (`overlays/main_menu/trade_*`) and the 2P setup run, with a new port screen for the second memory card
(`scripts/menu/second_card.gd`).

Changed:

- MEMORY CARD REQUIRED (string 0xD2) is still the notice when the second card's file (`user://save2.json`) is missing. The notice is
  now followed by the second card screen, instead of going straight back to the menu. The screen offers COPY THIS SAVE (the current
  save is written to the second card), NEW STARTER DECK (a new card with a starter deal from the name entry's deal, plus a second
  starter deal as its chest so there is something to trade; a new game has no chest), LOAD A SAVE FILE (a file dialog; desktop only,
  the web build has no dialog) and RETURN TO TITLE. A save `.json` dropped on the game window is read the same way. A file is only
  taken when it is a JSON dictionary with `counts` and `deck`; anything else says NOT A SAVE FILE. A made card goes straight on to
  the trade (or the 2P setup).
- The 2P DUEL entry now has the same gate as the trade. The original's 2P load is the trade's load (both saves) followed by a deck
  check, so the port no longer falls back to the player's own deck for player 2. Without the second card the MEMORY CARD REQUIRED
  notice comes first, then the second card screen; with no campaign it says NO DATA! (string 0xD3), as CAMPAIGN does.
- Trade: the page keys. A and D (player 2: Left and Right) turn the list a page of seven rows, with the cursor's row kept (the
  original's held Left and Right, SE 6). They were missing.
- Trade: the SETTLED label on a settled side ran past the column's right edge. It now sits inside the 160-pixel column.
- 2P setup: a click anywhere in the lower part of the screen started the duel, including on RETURN TO TITLE. Now the START DUEL line
  starts it, and the RETURN TO TITLE line goes back.
- `GameState.save_to(path)` writes a save to any file; `save_game()` calls it for the player's save. The new screen uses it for COPY.
- Tests: `tests/run_tests.gd` has a `second card` group (save recognition, the starter card's deck, chest and name). The suite passes.
- Tests: `tests/screen_capture.gd` writes PNG pictures of the trade (with offers and a settled side), the MEMORY CARD REQUIRED notice,
  the second card screen and the 2P setup (with and without the second card). It sets the player's two save files aside and puts them
  back when it ends. Run it minimized with dummy audio (see the file's header).

Checked on the captures (every picture was viewed):

- The backdrops load: the sand, the trade panel grid with the 1P and 2P tabs, the red cursor bar, the card type icons of the offers.
- The cursor bar sits on its row in both columns; the offers show five to a row in both columns and the settled column is dimmed.
- The inventory rows are name and count only, seven to a page. No scroll indicator was found in the original's trade overlay files
  (a search of `overlays/main_menu/trade_*` for scroll code only finds the list's own logic), so none is added; the wheel moves the cursor one row a notch, as Up and Down do.
- The second card screen's labels and cursor bar fit the 320 by 240 picture.

Still approximated (listed in the code header too):

- The lists are sorted by card id. The original's sort modes (R1 and L2, SE 47) are not ported.
- The card viewer (Triangle) is not opened. The original's 50-row jump (the repeated shoulder buttons) is not ported.
- The names are cut to 13 characters; the original's list width was not checked against the font.
- The list moves a row at a time, without the original's one-row-a-frame scroll animation.
- The write takes about a second (60 frames) instead of the memory card's own time. The trade's text is the original's strings.
- The second card screen's own strings (the title, the four lines and the foot lines) are the port's. They use the game's font and
  the trade's cursor bar, but they are not from the original.
- The second card's LOAD A SAVE FILE depends on a native or in-engine file dialog that was not run in this audit (only the layout and
  the keys were checked on the capture). The drop of a file was not run either.
- The fade and slide timings of the 2P setup and the second card screen are not measured against the original.
- The 2P setup's deck check (both decks must be full) is not made: a second card with an empty deck is still played with the
  player's own deck.

## Left for a decision

- About 210 comments in about 25 files cite the original program's code addresses to say which routine something mirrors. They are
  not names, and the requested patterns did not cover them, so they were not changed. Stripping them touches files that other agents
  are editing; it is a separate, larger change.
- One screens run printed a count of 30 written files, although the disk showed that no file had changed. The count comes from the
  bakers' return values and is not reliable; no file was affected.
