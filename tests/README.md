# Tests

## Story smoke test (`story_smoke.gd`)

Runs every campaign story scene (script indices 0 to 198) through `scripts/story/story_player.gd`, headless:

    "G:\Software\Redot\redot.windows.editor.x86_64.console.exe" --headless --path "G:\Development\Godot\Projects\ForbiddenMemories" -s res://tests/story_smoke.gd

Add `-- --scene=N` to run one scene. The whole pass takes about 75 seconds.

Each scene runs with Shift held (the player's test skip: waits, text reveal and fades collapse), and with every choice answered:

- one run with option 0 for every choice;
- one run per further option (up to four), with the answers rotating from that option so a question that comes back still ends;
- one run with every story flag set, so the branches that test a flag take the other way.

A run ends when the script returns (its `run_done` signal). 20000 physics frames without that is a hang. A choice asked more than 60 times in one run is a choice loop.

Output: `res://build/story_audit.json` (the build folder is ignored by git). It holds, per scene, every run (pick, flags, ending, frames, the choices offered) and the events the run met, summed. The summary line at the end lists the scenes that hung.

### Event names

These are counted by `StoryPlayer._note` while the harness runs (nothing is counted in play):

| Event | Meaning |
|---|---|
| `vm:unknown_opcode:XX` | a script opcode the player does not handle |
| `op:XX` | a primary control byte (F0 to FF) met in a text box |
| `f8:XX` | a secondary (F8) sub-opcode met, or nested under F8 23 |
| `unknown:f8:XX` | an F8 sub-opcode the game's table does not have |
| `approx:...` | a text command the port models approximately (the name says which) |
| `glyph:no_picture` | a glyph code with no picture in the font table |
| `picture:missing:XXX`, `portrait:missing:NN`, `bust:missing:...`, `bust:no_file:...` | art the port does not have |
| `state:XX`, `f6:EE:FF` | a text state (F7, F8 22) and a display effect (F6, F8 21) |
| `choice:N`, `choice:start` | a choice of N lines offered, and a choice started |
| `string:push`, `dialog:ID` | a string pushed as a stream, and a text box run |

`docs/story-audit.md` is written from the static walk and this output.

### Static walk

The harness does not decode the scripts itself. The static walk that feeds `docs/story-audit.md` reads every dialog a scene can reach and the picture, bust and portrait files each scene needs, using the same operand sizes as the player. It is a Python script kept outside the project (in the session scratch folder), run against `assets/screens/story/script.bin` and `assets/screens/text_bank.bin`.

### Reading a failure

- A `SCRIPT ERROR` in the output is a script bug. The harness stops only for that scene's run; check the message's file and line.
- A hang lists the scene in the summary. Open its runs in the JSON: the pick and the flags tell which branch loops.
- `choice_loop` in a run's ending means the question came back more than 60 times with the answers rotating.

## Dialog regression (`--dialogs=A-B`)

Every text box of the bank (indices 0 to 0xEFF) is walked on its own bytes, with the box's layout rules (pen, wrap, page turns on a
page break, a line feed onto the last line, or an overflowing glyph). Each walkable box is then run twice, with Shift held and free,
and the glyphs the player places per page must equal the walk's count, with no printable glyph dropped.

    Redot --headless --path <project> -s res://tests/story_smoke.gd -- --dialogs=000-0FF

Run it in chunks of 256 indices (`000-0FF`, `100-1FF`, ... `E00-EFF`): one process that runs the whole bank in a single pass stops
silently partway (a native exit after about a thousand boxes; not yet diagnosed). The chunks together checked all 3840 indices,
1809 of them walkable, with no failures. A non-zero exit code means a failure; the failures are listed in the summary line.

## Screen capture (`screen_capture.gd`)

Writes PNG pictures of the trade (with offers and a settled side), the MEMORY CARD REQUIRED notice, the second card screen and the 2P
setup, to the folder after `--out=`. It needs a window, so run it minimized with dummy audio:

    "G:\Software\Redot\redot.windows.editor.x86_64.exe" --minimized --audio-driver Dummy --path "G:\Development\Godot\Projects\ForbiddenMemories" --script res://tests/screen_capture.gd -- --out="C:\path\to\folder"

The player's own `user://save.json` and `user://save2.json` are set aside while it runs and put back afterwards. It writes its
fixture saves over them in between, so do not run it while the game is open.

## Duel material scan (`duel_materials.gd`)

Plays a seeded duel (the hand, the field and the readouts are built) and checks every node with a texture for its picture material
(ScreenFit's sharp pixels). A textured node without one samples with the world's LINEAR filter and shows the bilinear blur. Headless:

    Redot --headless --path <project> -s res://tests/duel_materials.gd

The duel needs its tree to run, so this is a script of its own rather than a check in run_tests.gd.

