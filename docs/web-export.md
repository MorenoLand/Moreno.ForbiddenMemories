# Web export

What the Web build needs, what the code does at run time, and what is still to check. Status: the Redot 26.2 web export
templates are installed on the development PC, and a headless Web export runs cleanly (no warnings, no errors). The game has
not been run in a browser yet.

## Export preset

`export_presets.cfg` holds a "Web" preset:

- Single-threaded (`variant/thread_support=false`, so the `web_nothreads_release.zip` template is used), no extensions
  (`variant/extensions_support=false`), canvas resize policy adaptive (`html/canvas_resize_policy=2`), output
  `build/web/index.html` (git-ignored).
- Export filter `all_resources`, plus the non-resource include filter `mods/*`. The include filter is verified: a probe file
  in `mods/` was written into the PCK.
- Excluded: `tools/*`, `tests/*`, `docs/*`, `build/*`, `*.py`.

## Raw files in assets/ (addons/raw_assets_export)

The game loads its pictures, JSON, binary tables, WAV sounds and movie frames from `res://assets/` at run time as raw files
(`Image.load_from_file`, `FileAccess`, `AudioStreamWAV.load_from_file`). They are not imported. `assets/` has a zero-byte
`.gdignore`, so the editor does not import the roughly 5,700 files.

That `.gdignore` also stops the exporter from packing them. The include filter on the preset cannot help, whatever the
pattern: a headless export with `assets/*` and with `*.png, *.json, *.bin, *.wav` both produced a 1.3 MB PCK with no asset in it.
An earlier version of this page named `assets/*` as the fix; that was wrong. Removing `.gdignore` for a test did pack the files,
but it made the editor import 5,509 files (sidecars in `assets/` and about 28,000 cache files in `.godot/imported`), so that is
not the fix either. The test was undone; the sidecars and cache entries it created were deleted.

The fix is `addons/raw_assets_export/`: an `EditorExportPlugin`, enabled in `project.godot` under `[editor_plugins]`. On every
export (editor or headless, any platform) it adds each file under `res://assets/` with `add_file`, skipping `.import` and dot
files. The `.gdignore` stays, so the editor still does not import anything. If `assets/` is missing (a fresh clone before
`tools/extract.py` has run), the plugin adds nothing.

Verified in this pass:

- Export with the plugin: `index.pck` is 133.7 MB and holds 5,684 asset entries (the 5,685 files minus `.gdignore`).
- The exported PCK was run with the desktop release template (`--headless --main-pack index.pck`) from a folder with no
  `project.godot`, so every `res://` read had to come from the pack. The boot scene ran for 600 frames with no error.

Not verified: the same run inside a browser.

Size: `assets/` is 125.8 MiB in 5,685 files (`movies` 43.6 MiB, `audio` 44.3 MiB, `screens` 25.9 MiB, `images` 9.2 MiB,
`data` 2.8 MiB). The PCK is 127.5 MiB uncompressed. The server should send it compressed (gzip or Brotli). The earlier figure of
43 MB and the audio size of 1.8 MB were out of date.

Licence: the assets are extracted from the user's own disc. A web build that includes `assets/` redistributes them. Decide
before publishing.

## Loading calls

Each call in the project, grouped by what it does on the web.

| Call | Where | Web status |
| --- | --- | --- |
| `Image.load_from_file("res://...png")` | boot, main menu, options, library, build deck, free duel, game over, name entry, story, credits, duel result, duel field, campaign map, message box, mod art, game text | Packed by the raw-assets plugin. Run from the PCK on the desktop template with no error. Browser not run. |
| `FileAccess.get_file_as_string` / `get_file_as_bytes` / `file_exists` on `res://` | JSON layouts, `text.json`, `cards.json`, `fusions.json`, `duelists.json`, `story/script.bin`, `text_bank.bin`, `ai_scripts/*.bin`, `model.json` | Same as above. Synchronous. Cost is the parse (below). |
| `AudioStreamWAV.load_from_file` (`game_audio.gd`) | the sound effects, on first use | Same as above. Loads are synchronous on the first play of each effect. |
| `DirAccess.open("res://mods")` (`duel_data.gd`) | mod rules at duel load | Returns null when no `mods/` folder is exported, and the code returns early. A `mods/` folder is packed (verified). |
| `FileAccess.open("user://...", WRITE)` | saves (`game_state.gd`, `settings`, `input.json`, `trade.gd` slot two, `second_card.gd`) | `user://` is the browser's IndexedDB. Writes must be closed before the page is left. Not verified in a browser. |
| `ConfigFile.load/save` on `user://settings.cfg` (`touch_controls.gd`, `duel_help.gd`) | the F3 choice, the first-duel tutorial flag | Same as above. |
| `OS.execute`, `Thread`, `Mutex`, `WorkerThreadPool`, threaded `ResourceLoader` loads | none | Not used (checked by a case-insensitive search of `scripts/`). |
| `DisplayServer` / `Window` | F2 4:3 toggle, fullscreen, vsync | See "Window and display" below. |
| `FileDialog`, `files_dropped` | second card, row 2 | See "Window and display" below. |

## Run-time cost (blocking loads)

Native timings from Redot 26.2 headless on the development PC (`JSON.parse_string` on the whole file, one call):

| File | Size | Parse | Where it is parsed |
| --- | --- | --- | --- |
| `assets/screens/text.json` | 3.1 MB | about 132 ms | `GameText.load_all()`, once per screen that uses text (about eight screens); each screen re-parses it |
| `assets/data/fusions.json` | 2.2 MB | about 174 ms | `DuelData.load_all()` at boot (new game) and at each duel |
| `assets/data/cards.json` | 0.19 MB | about 52 ms | `CardDB.load_all()`, once per screen |
| `assets/data/duelists.json` | 0.33 MB | about 18 ms | `DuelData.load_all()` |

`Image.load_from_file` of one screen PNG was about 2 ms natively.

WebAssembly is usually slower than native code for this kind of work. These are native numbers: measure the web build in the
browser before deciding. The per-screen re-parse of `text.json` and `cards.json` is the largest avoidable cost: the cache is
not in the files this pass owns (see below).

Owners' suggested changes (not made here, because the files are being edited by others):

- `scripts/ui/game_text.gd` and `scripts/data/card_db.gd`: parse once and keep the result in a `static var` (or a
  `RefCounted` singleton). Each screen would then pay for the parse once per run.
- `scripts/duel/duel_data.gd`: keep `fusions.json` parsed (cache) and ideally convert it to a compact form (the rules
  need only the fusion table); it is the largest single parse.
- Screens that load many PNGs in `_ready` (menu, build deck, library, duel field, campaign map): load on first use or split
  across frames, so the first frame of a screen does not spike. A loading state is optional and needs a new screen.
- `model.json` (3D duel field and campaign map): check its size in the browser; parse once per run if it is re-read.

## Background music (scripts/system/bgm_player.gd)

- The music is rendered on the main thread (the web build is single-threaded) into an `AudioStreamGenerator` with a 0.25 s
  buffer. `_process` pushes at most 4096 frames a frame, and only while the buffer has room.
- Audio start: `play()` starts the player when a track starts, which can be before the first input. A browser keeps its audio
  context suspended until a user gesture. In that state the buffer fills to 0.25 s, pushing stops, and no CPU is spent on the
  music. Sound is expected once Godot unlocks the web audio on the first key press or tap. That is Godot's web audio behaviour,
  not something the code enforces; not verified in a browser.
- Cost (native, Redot 26.2 headless, render only, 3 s of each track, all 60 tracks): mean 16.9% of real time, worst track
  (`290`) 39.1% of real time, no errors. It runs on one thread, and WebAssembly is usually slower, so a phone may fall
  behind on the heaviest tracks. Options, not made here: a lower mix rate (`RATE` 22050 halves the cost; the sequencer counts
  output samples, so the timing stays right), or fewer voices.

## Window and display

- F2 (`scripts/system/screen_fit.gd`) only changes how the 320x240 picture is scaled. It has no window call and works on web.
- F11 and the "Fullscreen" option (`scripts/runner/settings_menu.gd`, `apply()`) set `Window.mode`. Toggling it from the menu is
  a user gesture, so the browser accepts it. But `apply()` also runs at boot, so a saved `fullscreen=true` is requested at page
  load with no gesture and the browser refuses it. The window is then not fullscreen while the option says it is. Not changed.
  A fix is to skip the mode change on web when `apply()` runs from `_ready()`.
- `DisplayServer.window_set_vsync_mode` is called at boot. Its effect on web was not checked.
- The port does not minimise or resize the window in game code (the only `window_set_size` calls are in test scripts).
- The second card's row 2 ("LOAD A SAVE FILE", the only `FileDialog`) is offered only when `has_file_dialog()` is true, which is
  false on web. The dialog is created only from that row, so the web build never builds it. `files_dropped` is connected on every
  platform; that is harmless. The on-screen line "OR DROP A SAVE .JSON ON THE WINDOW" still shows on web. Whether the web build
  receives dropped files was not checked, so the line is kept.

## Other web points

- The engine's threads are off, so nothing relies on `SharedArrayBuffer` or cross-origin isolation headers.
- Keyboard: some browser shortcuts can take a function key before the page sees it (F3 is "find next" in some Windows
  browsers). The on-screen controls do not depend on keys the browser might take, but the F3 toggle may not reach the game
  in those browsers (not verified).
- The on-screen controls are shown on the web by default (`touch_controls.gd`), including on a desktop browser; F3 hides them
  and the choice is kept in the browser's `user://`.
- Touch scrolling and pinch on the canvas: check on a phone that the page does not scroll or zoom under the controls. If it
  does, a custom shell (`html/custom_html_shell`) that sets `touch-action: none` on the canvas would stop it (not verified).
- Memory: the PCK is loaded into the browser's memory and the decoded textures stay resident. Peak use was not measured;
  check it on a low-memory phone. The PCK is about 128 MiB before compression, so the memory and download cost is real.

## Steps to produce a web build

1. The web templates for Redot 26.2 are installed (`%APPDATA%\Redot\export_templates\26.2.stable`, including
   `web_nothreads_release.zip`, which matches `thread_support=false`). Nothing needs downloading.
2. `assets/` must be present (run `tools/extract.py` on the user's disc first). The build packs whatever is in `assets/`.
3. Export headless. Run the console build so the output and exit code can be captured (from PowerShell, start it with
   `Start-Process -Wait`; the windowed build returned at once with no output when called with `&`, and no export ran):

       "G:\Software\Redot\redot.windows.editor.x86_64.console.exe" --headless --path "G:\Development\Godot\Projects\ForbiddenMemories" --export-release "Web" build/web/index.html

   The same preset is used by the editor's export dialog. Do not run the export into the project's `build/` folder while a
   test writes there.
4. Serve `build/web/` over HTTPS (or `localhost`) and open `index.html`. Serve the `.pck` and `.wasm` with compression.
5. Check: boot logo and skip, the menu, a name entry, a story scene, a duel, a save and a reload, the on-screen controls on a
   phone, F3 on a desktop, the first sound after a tap (music and effects), the second card screen without a file dialog.

## Not verified

- The browser run of any of the above: boot, the first gesture and audio unlock, asset loads, IndexedDB saves across a reload.
- Frame times and memory in the browser.
- Touch behaviour on a real phone (the layer is tested headless with simulated touches, see below).
- Whether the web build receives dropped files, and the browser's handling of `DisplayServer.window_set_vsync_mode`.
- The browser's handling of F3 and the other function keys.

## Tests that were run

- `tests/run_tests.gd` (headless, `--script res://tests/run_tests.gd`): 467 passed, 0 failed, exit code 0, after the
  raw-assets plugin and the preset change.
- `touch_controls.gd` was tested headless in a minimised window with simulated `InputEventScreenTouch` and
  `InputEventScreenDrag` events: the key presses and releases (cross, D-pad, diagonals, slide, multi-touch, Start), the
  held-key repeat (one press then repeats), the swipe-to-wheel steps, the consumption of the emulated click, and hiding.
- Web export (headless) to a scratch folder: no warnings or errors in the log. The PCK contents and the desktop run of the PCK
  are described under "Raw files in assets/".
