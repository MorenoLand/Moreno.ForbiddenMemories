# Forbidden Memories

A native Redot / Godot port of Yu-Gi-Oh! Forbidden Memories (PS1, USA), rebuilt screen by screen from the game's own art, text, sound
and logic. It needs your own disc image; no game data is in this repository.

## Setup

```
python tools/extract.py "path/to/game.cue"
```

The extraction reads the disc once and writes the ignored `assets/` folder (about 3 minutes, 43 MB). Then open the folder with
Redot 26.2 and run the main scene. See [docs/tools.md](docs/tools.md) for every option.

Mods: put a mod folder (with its `mod.json`) under `mods/` in this folder, then run `python tools/extract.py --images` to bake its
textures. The folder is git-ignored; see [Mods](docs/tools.md#mods).

## Controls

| Key | Pad | Does |
| --- | --- | --- |
| W A S D or the arrow keys | D-pad | move the cursor |
| E or Space | Cross | confirm |
| Q, Backspace or Esc | Circle | cancel, back |
| F | Square | Square on the screens that use it |
| R | Triangle | Triangle on the screens that use it (duel: flip) |
| Z / C | L1 / R1 | shoulder buttons (library, build deck) |
| 1 / 3 | L2 / R2 | trigger buttons (build deck) |
| Enter | Start | start |
| Tab | Select | select |
| Shift (hold) | SKIP | story: fast-forward; a choice still waits for the player |
| mouse | | click entries and cells; the wheel scrolls lists |
| touch | | a tap is a click; the on-screen pad appears on touch devices and the web |
| F1 | | quick save the campaign to the save file, from any screen |
| F2 | | switch between filling the window and the original 4:3 shape |
| F3 | | watch a random AI v AI match (port only); Esc asks to quit it |
| F4 | | show or hide the on-screen touch controls |
| F5 | | the picture's sampling: Pixel (hard edges), Sharp (the default: crisp, with a blend on the pixel edges) or Smooth |
| F6 | | faint scanlines on or off |
| F9 | | the options panel: volume, window, the picture, the HD art |

The key bindings are fixed; there is no rebinding screen yet.

## Save files

Saves go to Godot's user data folder, never into the project. `save.json` is the campaign (F1 quick save, and the Save and Load
entries of the menu). `save2.json` is the second memory card used by Trade and the 2P duel. Deleting them resets that data.

## Status

Built natively from the game's own art, text and code:

- Konami boot screens, title screen and the menu wheel (both pages), with the front-end sound effects
- New Game name entry with the confirmation dialog; Load and Save from the menu
- Options (stereo and mono output)
- The campaign: the script player (story scenes, dialog boxes, choices, every story picture and bust), the campaign map (3D terrain,
  places, cameras, exits, name panel and markers; picking a place runs its story scene), the game over screen, and the credits roll
  (text, fades and timing)
- Free Duel opponent select, 2P Duel setup (two players, life points), and the Trade screen between two memory cards
- The Password screen (entry, card reveal, starchip exchange)
- The Library (card grid and card view) and the Build Deck screen (chest and deck panes, sorting, moving cards)
- Duels: rules engine (decks, draw, fusion and equip chains, battle, guardian stars, terrain, magic and trap effects, rituals,
  Exodia, deck-out), a 2D board, and the result screen. The opponent's play policy is a stand-in; the original's bytecode AI is not
  yet run.
- Mouse and touch on the menus; the screen fits any window, with F2 for the original shape

Not done yet:

- Music. The background tracks are rendered by a software sequencer and mixer (`scripts/system/bgm_*.gd`) from the disc's music packages; the sample numbering and master volume are not yet checked against a hardware dump.
- Movies other than the opening one (which plays after the Konami screens from frames `tools/extract.py --movie` pre-decodes). The STR
  and MDEC runtime decoders in `scripts/runner/` are not wired into the game.
- The duel's full 3D presentation. The finale's effects are approximated with simple shapes.
- The card viewer on the Build Deck (Triangle) and the credits' 3D backdrop.
- Runner-side tools in `scripts/runner/` (a rebinding screen, a sound and window settings screen, and the runtime SPU) are written but
  not connected to the game.
