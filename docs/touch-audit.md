# Touch and mouse audit

How every screen answers a finger and a mouse, after the on-screen controls (`scripts/system/touch_controls.gd`) and the
project's `emulate_mouse_from_touch` setting.

## How touch reaches the game

- A tap on the game is a left click (`input_devices/pointing/emulate_mouse_from_touch=true`); swipes on empty space send
  mouse wheel steps, so the lists scroll (library, build deck).
- The on-screen controls press the keyboard keys the screens already read: D-pad = arrows, Cross = E, Circle = Q (Cancel),
  Square = F, Triangle = R, Start = Enter, Select = Tab, L1 = Z, R1 = C, L2 = 1, R2 = 3. The keys are held while the finger is
  on the control (D-pad: diagonals and held-key repeat), and pulsed for at least 0.12 s so the per-frame polls see every tap.
- An emulated click that lands on a control (or belongs to a control touch) is consumed, so it does not click the game under
  the button. Screens that poll `Input.is_mouse_button_pressed` use `TouchControls.game_pointer_held()` for the same reason.
- Right-click has no touch equivalent: Circle (Q) is the Cancel/back control. A long-press was not added, because the engine
  emits the left click at touch-down, so a long-press would click and then cancel.

## Status legend

- **OK**: works by tap or on-screen control, no change needed.
- **Fixed**: changed in this pass (file listed).
- **Open**: needs a change in a file that another agent is editing, or a design decision; the suggested fix is given.

## Global

| Screen (file) | State | Problem | Suggested fix | Status |
| --- | --- | --- | --- | --- |
| all | any | Right-click cancel has no touch equivalent | Circle button sends Q (every screen reads Q as cancel) | Fixed (touch_controls.gd) |
| all | any | Emulated click from a control touch reached the game underneath | Consume emulated clicks that land on a control (touch_controls.gd) | Fixed |
| all | any | F4 toggle needs a keyboard on a phone | Shown by default on touch screens and the web; F4 toggles on any platform | Fixed |
| boot.gd, credits.gd, story_player.gd, game_over.gd | any | `Input.is_mouse_button_pressed` also fires for a finger on the D-pad, so a D-pad tap skipped or advanced a screen | `TouchControls.game_pointer_held()` | Fixed (boot, credits, story, game over). Open for message_box.gd |
| boot.gd | F1 quick save | F1 cannot be pressed on touch | F1 small button at the top middle injects F1 | Fixed (touch_controls.gd) |
| screen_fit.gd | F2 4:3 / stretch toggle | F2 cannot be pressed on touch | F2 small button at the top middle injects F2 | Fixed (touch_controls.gd) |
| story_player.gd | fast-forward (Shift held) | No touch key for Shift | SKIP button held injects Shift | Fixed (touch_controls.gd) |

## Screens

| Screen (file) | State | Problem | Suggested fix | Status |
| --- | --- | --- | --- | --- |
| Boot / splash (boot.gd) | Konami logo, skip | A tap skipped the hold; a D-pad tap also did | Skip on Enter, E, Space or a click on the game only | Fixed |
| Title and menu wheel (menu/main_menu.gd) | title, wheel, hover | none: hover, click on entries, START on the title, right-click cancel | none | OK |
| Name entry (menu/name_entry.gd) | letter grid | Letters are typed by key only; touch uses the grid | none: each cell is a click target, Start/Enter ends | OK |
| Name entry (menu/name_entry.gd) | YES / NO dialog | none: a click on the line chooses it | none | OK |
| Password (menu/password.gd) | digit entry | Digits 0, 2, 4 to 9 are reached by tapping the cell and then up/down; L2/R2 inject 1 and 3 as digit keys | Acceptable; a digit pad would be a design change | OK (note) |
| Password (menu/password.gd) | prompt, paid, away | Tap on a text line picks it; Cross and Circle act as keys | none | OK |
| Options (menu/options.gd) | side select | Label-row hit boxes are approximate (left or right half of the row) | Use the label rectangles | OK (note) |
| Free duel (menu/free_duel.gd) | opponent grid | none: hover, click, confirm, right-click cancel | none | OK |
| Two player setup (menu/two_player_setup.gd) | row and value | Tap picks the row; value changes use the D-pad | none | OK |
| Trade (menu/trade.gd) | side 1 browse | W/S move side 1 and no touch control sends them; the D-pad moves side 2 | Tap a row to move side 1 (works); a second D-pad would need a design change | OK (note) |
| Trade (menu/trade.gd) | side 2 ready / cancel | `/` and Backspace were keyboard only | Triangle (R) readies side 2, L1 (Z) cancels it | Fixed |
| Trade (menu/trade.gd) | choice (execute, re-select, return) | none: arrows, Cross, Circle | none | OK |
| Library (menu/library.gd) | grid, card view | Wheel and swipe scroll; L1/R1 page; Square (F); Cross opens | none (swipe sends wheel steps) | OK |
| Build deck (menu/build_deck.gd) | deck and chest panes | Drag of the scroll thumb needs the emulated drag; L1/R1, L2/R2, Triangle and Select have keys | Verify the thumb drag by touch on a device | OK (verify) |
| Free duel / duel (duel/duel_scene.gd) | field, target, star, hand | Cursor, E, Q, F, R, Enter all on the pad; clicks on cards work | none | OK |
| Duel result (duel/duel_result.gd) | results, confirm | No mouse input at all: a tap does nothing; Cross and the D-pad (A/D) work | Accept `TouchControls.game_pointer_held()` as confirm, like credits.gd | Open (duel_result.gd) |
| Story (story/story_player.gd) | dialogue advance | Tap or Cross advances | none (D-pad tap no longer advances) | Fixed |
| Story (story/story_player.gd) | choices | Tap picks a line, D-pad moves | none | Fixed (D-pad false taps) |
| Campaign map (map/campaign_map.gd) | walk | D-pad walks; tap on an exit arrow picks it; a tap elsewhere confirms | Consider only confirming on a tap on the place panel | OK (note) |
| Credits (menu/credits.gd) | roll, save prompt, secret number | Tap or Cross advances; D-pad tap also advanced | none | Fixed |
| Game over (menu/game_over.gd) | fade in, leave | Only keys and pad buttons: a tap could not leave | Tap counts | Fixed |
| Message box (ui/message_box.gd) | any notice | Polls the left mouse button: a D-pad tap dismisses the box | `TouchControls.game_pointer_held()` and keep the keys | Open (message_box.gd not in the fix list) |
| Duel field 3D (duel/duel_field_3d.gd) | no input | none | none | OK |
| Runner screens (runner/*.gd) | settings, controls, disc | Not reached from the front end | none | n/a |
