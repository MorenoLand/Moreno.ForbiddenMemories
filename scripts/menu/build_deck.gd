extends Control
## The BUILD DECK screen (the build deck menu): the chest on the left pane and the deck on the right, a native port of
## the routine at 0x800323F8 (setup), the card list input update, the chest pane input update, the deck pane input update,
## the pane transition update, the routine at 0x800339D0 (leaving), the routine at 0x80033BE8 (the per-frame driver), the routine at 0x80032C48 (the card list sort),
## the routine at 0x8003201C (the deck count), the card add, the chest-to-deck card move and the deck-to-chest card move, with the row
## drawing of the routine at 0x80031874. Everything steps at the game's 60 Hz.
##
## The chest is the 722-card list and the deck the 40-card list. Each list is sorted by the sort mode the SELECT and START
## buttons pick (the sort icons of the header). Cross or Square on the chest adds the highlighted card to the deck (up to three
## copies, one of each Exodia piece, and only up to 40 cards); Cross or Square on the deck returns it to the chest. Triangle would
## open the card viewer and Circle leaves the screen: a deck with an open slot asks first (the narrow confirmation, string 9) and
## a choice other than the first saves; the first choice goes back to the editing. Leaving saves the deck order to
## GameState.deck and the owned copies to GameState.card_counts.
##
## Owned copies: GameState.card_counts holds the copies of each card the player owns, chest and deck together. The chest copies
## are that count less the deck's copies, which is what the game keeps as chest_card_quantities (the save's trunk at deck + 0x50).
##
## The name order is the card name sort key (cards.json's name_sort_key, extracted from the executable). Without the key in the data
## it falls back to an alphabetical rank of the names. The "your order" sort and the "New!" plates use GameState.recent_drops (the
## newest first). The BGM is emitted as music(0x70E0) when the screen opens; nothing plays it yet.
## The card viewer (Triangle) opens the card: its picture, frame, the card's text box (the shared card view helper, scripts/ui/card_view.gd: the
## race or kind icon and name, the guardian stars with their icons, the card text), the stats and the attribute, with Up and Down browsing.
## Not built yet: the card-type icon that flies from a moved card (the routine at 0x80031574), and the screen fades (the fade-in wait, the
## fade target level set).
## The pictures are baked from the boot UI image and the resident display bank (tools/extract.py bake_build_deck); layout.json gives
## each object picture's offset from its object's origin, which the board adds to the origins above (see the text layout below for
## the count line's numbers).

signal closed                 # the screen is left: back to the menu (the build deck menu returns on state 0)
signal sound(effect: int)     # the full SE play ids: 6 cursor moves, 7 card moved, 8 leave, 9 refused, 0x1E pane slide, 0x2F sort
signal music(id: int)         # the Build Deck BGM (the routine at 0x800323F8's the BGM play 0x70E0): nothing plays it yet, the hook is here

const TextFrame := preload("res://scripts/ui/text_frame.gd")
const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const CardDB := preload("res://scripts/data/card_db.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const CardView := preload("res://scripts/ui/card_view.gd")
const DIR := "res://assets/screens/build_deck/"
const CARD_COUNT := 722
const DECK_SIZE := 40
const COPY_LIMIT := 3                         # DECK_CARD_COPY_LIMIT
const CHEST_LIMIT := 250                      # CARD_CHEST_QUANTITY_MAX
const EXODIA_FIRST := 0x11
const EXODIA_COUNT := 5
const CARD_TYPE_MAGIC := 20                   # monsters are the types below it
const PAGE := 8                               # visible rows on a pane
const ROW_STEP := 22                          # 0x16 between the rows
const ROW_TOP := 43                           # 0x2B: the first row's y
const CURSOR_Y := 42                          # 0x2A + cursor * 22
const SCROLL_Y := 41                          # 0x29 + the thumb's row
const SCROLL_X := [310, 618]                  # the thumbs (0x136 and 0x26A)
const CURSOR_X := [0, 328]                    # the cursor bars (0 and 0x148)
const PANE_X := [0, 320]                      # the panes' x in the 640-wide workspace (0x140 for the deck)
const BOX_X := [0, 320]                       # the CHEST and DECK boxes
const HEADER_X := [0x88, 0x6A]                # the sort icons' x in each pane
const HEADER_Y := 15
const PANE_TICKS := 16
const PAGE_JUMP := 0x32                       # L2 and R2 page by 50 rows
const REPEAT_THRESHOLD := 0x18
const REPEAT_RELOAD := 0x14
const U32_NEG := 0xFFFFFFFF                   # -1 as the sort's u32 key
const COUNT_LINE_ORIGIN := Vector2(22, 23)    # the flagged text box creation(3, 0xE, 0x16, 0x17, ...)
const COUNT_STRING := 14
const CHEST_TOTAL_ADDRESS := 0x801D5608     # the data at 0x801D5608[0].build_deck.chest
const DECK_TOTAL_ADDRESS := 0x801D560C      # the data at 0x801D5608[0].build_deck.deck
const DIGIT_SJIS := 0x824F                  # the Shift-JIS code of '0'; the digits follow it
const DIALOG_STRING := 9                      # BUILD DECK / EXIT ... SETTLED? (the narrow confirmation)
const DIALOG_RECT := Rect2(48, 96, 224, 48)   # the flagged text box creation(0, 9, 0x30, 0x60, 0xE0, 0x30)
const DIALOG_TEXT := Vector2(56, 94)          # the text at the box top - 2 (the story dialog's line origin)
const DIALOG_FRAME_SOURCE := Rect2(0, 152, 320, 88)   # the dialog frame's panel in the story frame picture
const DIALOG_FRAME_BORDER := Vector4(8, 8, 8, 8)     # its stone border, in source pixels
const DIALOG_LINE_TOP := 107.0               # the first choice line's highlight top: the string opens with an empty line (its line break), so the choices are the second and third lines (line top 94 + 12 + 1), 12 a line, 10 tall
const DIALOG_FRAME_OUTSIDE := 8.0            # the stone frame is drawn around the text box, its border outside the box
# the pointer's places in the workspace: the ORDER bars of the two panes (the sort name's bar cycles the sort), the L2, L1, R1 and R2
# pictures of the page column (the deck pane's left edge, the page_buttons picture at (320, 40) and its two groups)
const HEADER_BAR := [Rect2(97, 10, 170, 24), Rect2(385, 10, 172, 24)]
const PAGE_BUTTON_RECTS := {"l2": Rect2(320, 40, 15, 20), "l1": Rect2(320, 60, 15, 20), "r1": Rect2(320, 176, 15, 20), "r2": Rect2(320, 196, 15, 20)}
const EMPTY_CELL_X := 261                     # the chest's copy cells (the lock and diamond columns of the chest picture) start here
const EMPTY_CELL_WIDTH := 47
const CELL_TOP := 41                          # the first row's cell in the chest picture, 22 pixels per row
const CELL_HEIGHT := 20
const GRID_COLOUR := Color(0, 0, 32.0 / 255.0)  # the grid's ground colour, drawn over the copy cells of an empty row
# the sort modes of each pane's SELECT/START choices (the low nibble of the data at 0x80090DD8's second byte per choice)
const SORT_MODES := [[1, 2, 3, 4, 5, 6, 8], [1, 2, 3, 4, 5, 6, 9]]
const SORT_ICONS := ["sort_card_number", "sort_owned_first", "sort_best_stat", "sort_attack", "sort_defense", "sort_card_type"]
const TYPE_NAMES := ["Dragon", "Spellcaster", "Zombie", "Warrior", "Beast-Warrior", "Beast", "Winged Beast", "Fiend", "Fairy", "Insect",
	"Dinosaur", "Reptile", "Fish", "Sea Serpent", "Machine", "Thunder", "Aqua", "Pyro", "Rock", "Plant", "Magic", "Trap", "Ritual", "Equip"]
const VIEW_DIR := "res://assets/screens/library/"     # the card view's frame picture (the same card frame as the duel's viewer)
const VIEW_TICKS := 19                               # the viewer's slide: 0x400 of speed at 0x55 a tick
const VIEW_Y := 20                                   # the viewer sits 20 pixels down (the original's viewer offset)
const VIEW_BOX_REST := 148.0                         # the text box's x at rest (it slides in from 328)
const VIEW_BOX_OFF := 328.0
const VIEW_ART_OFF := -140.0                         # the card picture slides in from -140 to 2
const VIEW_ART_REST := 2.0
const VIEW_FADE_REST := 0x40                         # the board dims to 0x40 with the viewer up, back to 0xFF after
const FLAG_ON := 1
const FLAG_HELD := 0x80                       # in the deck, none in the chest: drawn dim

# the screen's states (state & 0x3F, the data at 0x80090DF8): 0 done, 1 pane slide, 2 chest, 3 deck, 4 leaving
const STATE_DONE := 0
const STATE_SLIDE := 1
const STATE_CHEST := 2
const STATE_DECK := 3
const STATE_LEAVE := 4

var text := GameText.new()
var cards := CardDB.new()
var sharp: ShaderMaterial
var tex: Dictionary = {}
var art: Dictionary = {}                      # layout.json: each object picture's {x, y} offset from its object's origin
var world := Node2D.new()
var clip := Control.new()                     # the window: the 640-wide workspace shows 320 pixels of it
var board := Node2D.new()                     # both panes; moves by -viewport_x
var counts_line := Node2D.new()
var dialog := Node2D.new()
var ready_ok := false
var finished := false
var timers: Dictionary = {}
var frame := 0
var stat_records: Array = []                  # index id: {type, atk, def} (raw stat values, as the packed word holds them)
var name_rank := PackedInt32Array()           # index id: the card's name sort key (the card name sort key, or the alphabetical rank without it)
var digit_codes: Array = []                   # the ten digit glyph codes of the count line
var card_rank := PackedInt32Array()           # index id: 1 + the index of the card's newest recent drop, 0 when it has none
var lists: Array = []                         # 0 the chest, 1 the deck: {kind, rows, first, first_target, cursor, sort_mode, sort_choice, row_count, sort_row_count}
var chest_qty := PackedInt32Array()           # index id: copies in the chest
var deck_qty := PackedInt32Array()            # index id: copies in the deck
var deck_total := 0
var viewport_x := 0                           # the viewport x
var viewport_target := 0
var pane := 0                                 # pane_index
var state := STATE_CHEST
var next_state := STATE_CHEST
var initialised := false                      # the 0x8000 bit: the current state's first call has run
var slide_step := 0
var slide_ticks := 0
var dialog_open := false                      # the 0x4000 bit: the confirmation is up
var dialog_choice := 0                        # the dialog choice
var click_pending := false                    # left mouse button: Cross
var cancel_click := false                     # right mouse button: Circle
var wheel_steps := 0                          # mouse wheel notches: negative up, positive down; one row each
var mouse_keys: Dictionary = {}               # pointer presses on the buttons, taken as one tick of the named key
var drag_pane := -1                          # the scroll thumb being dragged (the pane), -1 for none
var drag_grab := 0.0                         # the pointer's offset inside the thumb when the drag began


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all() or not cards.load_all():
		return
	var names: Array = ["chest_box", "deck_box", "sand", "page_buttons", "cursor_bar", "cursor_bar_blue", "thumb", "arrow_left", "arrow_right",
		"atk_mark", "def_mark", "new_mark", "sort_your_order", "sort_random"] + SORT_ICONS
	var layout = JSON.parse_string(FileAccess.get_file_as_string(DIR + "layout.json"))
	art = layout if layout is Dictionary else {}
	for i in 10:
		names.append("digit_%d" % i)
	for name in names:
		var digit := ModArt.texture(DIR + name + ".png")
		if digit == null:
			return
		tex[name] = digit
	# the red arrows' animation frames (layout.json: each arrow's frames and its [hold, frame] sequence)
	for arrow in ["arrow_right", "arrow_left"]:
		for frame_name in art.get(arrow, {}).get("frames", []):
			var frame := ModArt.texture(DIR + frame_name + ".png")
			if frame == null:
				return
			tex[frame_name] = frame
	_load_records()
	sharp = ScreenFit.make_material()
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(world)
	add_to_group("fit")
	clip.size = Vector2(320, 240)
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(320, 240)
	clip.add_child(black)
	world.add_child(clip)
	board.material = sharp
	board.draw.connect(_draw_board)
	clip.add_child(board)
	board.add_child(counts_line)
	viewer_shade.color = Color(0, 0, 0, 0)
	viewer_shade.size = Vector2(320, 240)
	viewer_shade.z_index = 8
	clip.add_child(viewer_shade)
	viewer_node.z_index = 9
	viewer_node.visible = false
	viewer_art.centered = false
	viewer_art.material = sharp
	viewer_frame.centered = false
	viewer_frame.material = sharp
	viewer_node.add_child(viewer_frame)
	viewer_node.add_child(viewer_art)
	viewer_node.add_child(viewer_text)
	viewer_node.add_child(viewer_icons)
	clip.add_child(viewer_node)
	var frame_texture := ModArt.texture(VIEW_DIR + "card_frame.png")
	if frame_texture != null:
		viewer_frame.texture = frame_texture
	var view_layout = _read_viewer_json(VIEW_DIR + "layout.json")
	if view_layout is Dictionary and view_layout.has("card_frame"):
		viewer_frame_offset = Vector2(float(view_layout["card_frame"]["x"]), float(view_layout["card_frame"]["y"]))
	viewer_view = CardView.new(text, sharp)
	clip.add_child(dialog)                        # the confirmation is drawn on the window, not on the sliding board
	dialog.z_index = 10
	_rebuild_counts()
	get_viewport().size_changed.connect(refit)
	refit()

	ScreenFit.pass_mouse(self)
	ready_ok = true
	music.emit(0x70E0)


func refit() -> void:
	ScreenFit.apply(world, size)


## the routine at 0x800323F8: the two lists from the deck and the owned copies, both sorted, the deck counted.
func _load_records() -> void:
	var names: Array = []
	stat_records = [null]
	for id in range(1, CARD_COUNT + 1):
		var data: Dictionary = cards.card(id)
		var record := {"id": id, "flags": 0, "type": _type_index(String(data.get("type", ""))),
			"atk": int(data.get("attack", 0)) / 10, "def": int(data.get("defense", 0)) / 10, "key": 0}
		stat_records.append(record)
		names.append([String(data.get("name", "")).to_lower(), id])
	names.sort_custom(func(a, b): return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	name_rank.resize(CARD_COUNT + 1)
	name_rank[0] = 0x7FFFFFFF
	for i in names.size():
		name_rank[names[i][1]] = i + 1
	# the card name sort key, extracted from the executable (tools/extract.py): the disc's own order when every card has its key
	var keys_known := true
	for id in range(1, CARD_COUNT + 1):
		keys_known = keys_known and cards.card(id).has("name_sort_key")
	if keys_known:
		for id in range(1, CARD_COUNT + 1):
			name_rank[id] = int(cards.card(id)["name_sort_key"])
	# the routine at 0x800323F8: card_sort_rank[id] is the newest drop's index + 1 (the recent card drops, newest first), 0 for the rest
	card_rank.resize(CARD_COUNT + 1)
	card_rank.fill(0)
	var drops: PackedInt32Array = GameState.recent_drops
	for n in range(mini(drops.size(), GameState.RECENT_DROP_COUNT) - 1, -1, -1):
		var drop := int(drops[n])
		if drop >= 1 and drop <= CARD_COUNT:
			card_rank[drop] = n + 1
	var owned: PackedInt32Array = GameState.owned_counts()
	deck_qty.resize(CARD_COUNT + 1)
	chest_qty.resize(CARD_COUNT + 1)
	var deck_rows: Array = []
	for j in DECK_SIZE:
		var id := int(GameState.deck[j]) if j < GameState.deck.size() else 0
		var row := {"id": 0, "flags": 0, "type": 0, "atk": 0, "def": 0, "key": 0}
		if id != 0:
			row = stat_records[id].duplicate()
			row.flags = FLAG_ON
		deck_rows.append(row)
	var chest_rows: Array = []
	for id in range(1, CARD_COUNT + 1):
		chest_rows.append(stat_records[id])
	lists = [_new_list(0, chest_rows, CARD_COUNT), _new_list(1, deck_rows, DECK_SIZE)]
	deck_total = _recount_deck()
	for id in range(1, CARD_COUNT + 1):
		chest_qty[id] = maxi(owned[id - 1] - deck_qty[id], 0)
		stat_records[id].flags = _flag_of(id)
	_sort(lists[0])
	_sort(lists[1])
	state = STATE_CHEST
	next_state = STATE_CHEST


func _new_list(kind: int, rows: Array, count: int) -> Dictionary:
	return {"kind": kind, "rows": rows, "first": 0, "first_target": 0, "cursor": 0, "sort_choice": 0,
		"sort_mode": SORT_MODES[kind][0], "row_count": count, "sort_row_count": count}


func _type_index(name: String) -> int:
	var wanted := name.to_lower().replace(" ", "").replace("-", "")
	for i in TYPE_NAMES.size():
		if TYPE_NAMES[i].to_lower().replace(" ", "").replace("-", "") == wanted:
			return i
	return 0


## the routine at 0x8003201C: the deck's copies of each card, and the count of leading deck rows that are still in use.
func _recount_deck() -> int:
	deck_qty.fill(0)
	for row in lists[1].rows:
		if row.flags != 0:
			deck_qty[row.id] += 1
	var leading := 0
	for row in lists[1].rows:
		if row.flags == 0:
			break
		leading += 1
	return leading


func _flag_of(id: int) -> int:
	if chest_qty[id] > 0:
		return FLAG_ON
	return FLAG_HELD if deck_qty[id] > 0 else 0


func _chest_total() -> int:
	var total := 0
	for id in range(1, CARD_COUNT + 1):
		total += chest_qty[id]
	return total


func _pad() -> Dictionary:
	var down := {
		"left": Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT),
		"right": Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT),
		"up": Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP),
		"down": Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN),
		"confirm": Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_F)
			or Input.is_joy_button_pressed(0, JOY_BUTTON_A) or Input.is_joy_button_pressed(0, JOY_BUTTON_X),
		"cancel": Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_BACKSPACE)
			or Input.is_joy_button_pressed(0, JOY_BUTTON_B),
		"triangle": Input.is_key_pressed(KEY_R) or Input.is_joy_button_pressed(0, JOY_BUTTON_Y),
		"l1": Input.is_key_pressed(KEY_Z) or Input.is_joy_button_pressed(0, JOY_BUTTON_LEFT_SHOULDER),
		"r1": Input.is_key_pressed(KEY_C) or Input.is_joy_button_pressed(0, JOY_BUTTON_RIGHT_SHOULDER),
		"l2": Input.is_key_pressed(KEY_1) or Input.is_joy_button_pressed(0, JOY_BUTTON_LEFT_STICK),
		"r2": Input.is_key_pressed(KEY_3) or Input.is_joy_button_pressed(0, JOY_BUTTON_RIGHT_STICK),
		"start": Input.is_key_pressed(KEY_ENTER) or Input.is_key_pressed(KEY_KP_ENTER) or Input.is_joy_button_pressed(0, JOY_BUTTON_START),
		"select": Input.is_key_pressed(KEY_TAB) or Input.is_key_pressed(KEY_SHIFT) or Input.is_joy_button_pressed(0, JOY_BUTTON_BACK),
	}
	var pressed := {}
	var repeat := {}
	for key in down:
		var timer: int = timers.get(key, -1)
		if down[key]:
			if timer < 0:
				pressed[key] = true
				repeat[key] = true
				timer = 0
			else:
				timer += 1
				if timer >= REPEAT_THRESHOLD:
					repeat[key] = true
					timer = REPEAT_RELOAD
			timers[key] = timer
		else:
			timers[key] = -1
	# the pointer acts on the open list (and on the card viewer, which the wheel browses like Up and Down and a right click closes like
	# Circle): a click is Cross, a right click Circle
	var list_open := _list_open()
	var dialog_up := state == STATE_LEAVE and dialog_open
	if (list_open or viewer_open) and wheel_steps != 0:
		repeat["up" if wheel_steps < 0 else "down"] = true
		wheel_steps -= signi(wheel_steps)
	if click_pending:
		if list_open:
			repeat["confirm"] = true
		elif dialog_up:
			pressed["confirm"] = true
		click_pending = false
	if cancel_click:
		if list_open or state == STATE_LEAVE or viewer_open:
			pressed["cancel"] = true
		cancel_click = false
	for key in mouse_keys:
		down[key] = true
		pressed[key] = true
		repeat[key] = true
	mouse_keys.clear()
	if not (list_open or viewer_open):
		wheel_steps = 0
	return {"down": down, "pressed": pressed, "repeat": repeat}


## The list takes input when the screen is on a pane and no slide or confirmation is running.
func _list_open() -> bool:
	if not (state == STATE_CHEST or state == STATE_DECK) or dialog_open or viewer_open:
		return false
	return lists[pane].first == lists[pane].first_target


func _gui_input(event: InputEvent) -> void:
	if not ready_ok or not (event is InputEventMouse):
		return
	var local: Vector2 = (event.position - world.position) / world.scale
	if event is InputEventMouseMotion:
		if drag_pane >= 0:
			if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
				_drag_scroll(local.y)
			else:
				drag_pane = -1
		elif dialog_open:
			_hover_dialog(local)
		elif _list_open():
			_hover_row(event.position)
		return
	if not (event is InputEventMouseButton):
		return
	if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		drag_pane = -1
		return
	if not event.pressed:
		return
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if dialog_open:
				var line := _dialog_line(local)
				if line >= 0:
					_answer_dialog(line)
				return
			if _list_open():
				if _press_pointer(local):
					return
				_hover_row(event.position)
			click_pending = true
		MOUSE_BUTTON_RIGHT:
			cancel_click = true
		MOUSE_BUTTON_WHEEL_UP:
			if _list_open() or viewer_open:
				wheel_steps = maxi(wheel_steps - 1, -10)
		MOUSE_BUTTON_WHEEL_DOWN:
			if _list_open() or viewer_open:
				wheel_steps = mini(wheel_steps + 1, 10)


## The pointer's press on the open pane's furniture, in the workspace (board) coordinates: the sort icons pick that sort, the header's
## bar cycles the sort as START does, the red arrow switches the pane (RIGHT or LEFT), the L1, L2, R1 and R2 pictures page the list as
## their keys do, and the scroll thumb or its track starts a drag. True when the press was taken here.
func _press_pointer(local: Vector2) -> bool:
	var at := Vector2(local.x + viewport_x, local.y)
	var k := pane
	var list: Dictionary = lists[k]
	for i in 7:
		if Rect2(PANE_X[k] + HEADER_X[k] + 18 * i, HEADER_Y, 16, 16).has_point(at):
			_choose_sort(list, i)
			return true
	if HEADER_BAR[k].has_point(at):
		mouse_keys["start"] = true
		return true
	var arrow := "arrow_right" if k == 0 else "arrow_left"
	if _sprite_rect(arrow, Vector2(BOX_X[k], 0)).has_point(at):
		mouse_keys["right" if k == 0 else "left"] = true
		return true
	for key in PAGE_BUTTON_RECTS:
		if PAGE_BUTTON_RECTS[key].has_point(at):
			mouse_keys[key] = true
			return true
	var track := Rect2(SCROLL_X[k] - 3, SCROLL_Y - 3, 12, 152 + 28)
	if track.has_point(at):
		var thumb_y := SCROLL_Y + _thumb_row(list)
		drag_pane = k
		drag_grab = at.y - thumb_y if at.y >= thumb_y and at.y < thumb_y + 22 else 11.0
		_drag_scroll(local.y)
		return true
	return false


## The sort icon's choice: the same as START or SELECT stepping onto it.
func _choose_sort(list: Dictionary, choice: int) -> void:
	sound.emit(0x2F)
	list.sort_choice = choice
	list.sort_mode = SORT_MODES[list.kind][choice]
	_sort(list)


## The scroll thumb follows the pointer: its track position gives the absolute row under the cursor, the list scrolls to show it.
func _drag_scroll(y: float) -> void:
	var list: Dictionary = lists[drag_pane]
	var n: int = list.row_count
	if n <= 1:
		return
	var t := clampf((y - drag_grab - SCROLL_Y) / 152.0, 0.0, 1.0)
	var absolute := int(round(t * (n - 1)))
	var first := clampi(absolute - list.cursor, 0, maxi(n - PAGE, 0))
	list.first = first
	list.first_target = first
	list.cursor = clampi(absolute - first, 0, PAGE - 1)


## The thumb's offset down the track, as the board draws it.
func _thumb_row(list: Dictionary) -> int:
	if (list.first | list.cursor) == 0:
		return 0
	return (list.first + list.cursor + 1) * 152 / list.sort_row_count


func _sprite_rect(name: String, at: Vector2) -> Rect2:
	return Rect2(_art(name, at), tex[name].get_size())


## The confirmation's choice line under a point of the window, or -1: the two lines of its text, the width of the box less its margins.
func _dialog_line(local: Vector2) -> int:
	if local.x < DIALOG_RECT.position.x or local.x >= DIALOG_RECT.end.x:
		return -1
	var line := int(floor((local.y - DIALOG_LINE_TOP) / 12.0))
	if local.y - DIALOG_LINE_TOP - 12.0 * line >= 10.0:
		return -1
	return line if line >= 0 and line < 2 else -1


func _hover_dialog(local: Vector2) -> void:
	var line := _dialog_line(local)
	if line >= 0 and line != dialog_choice:
		dialog_choice = line
		sound.emit(6)
		_rebuild_dialog()


## A row of the visible pane under the pointer becomes its cursor, as moving the cursor there does.
func _hover_row(at: Vector2) -> void:
	var local: Vector2 = (at - world.position) / world.scale
	if local.y < ROW_TOP:
		return
	var row := int((local.y - ROW_TOP) / ROW_STEP)
	if row >= PAGE:
		return
	var list: Dictionary = lists[pane]
	if list.cursor != row:
		list.cursor = row
		sound.emit(6)


## True when the key is the only one held (the game's Held == PAD_DIRECTION_x test).
func _only(down: Dictionary, key: String) -> bool:
	for k in down:
		if k != key and down[k]:
			return false
	return down[key]


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible or finished:
		return
	frame += 1
	var pad := _pad()
	_dispatch(pad)
	if state == STATE_DONE and not finished:
		finished = true
		closed.emit()
		return
	board.position = Vector2(-viewport_x, 0)
	board.queue_redraw()


## the routine at 0x80033BE8: the step table, the data at 0x80090DF8, for state & 0x3F.
func _dispatch(pad: Dictionary) -> void:
	match state:
		STATE_DONE, STATE_SLIDE:
			_slide()
		STATE_CHEST:
			_pane_input(pad, false)
		STATE_DECK:
			_pane_input(pad, true)
		STATE_LEAVE:
			_leave(pad)


## The first call of a state returns false and marks it begun (the 0x8000 bit in the initialized flag test).
func _test_and_set() -> bool:
	if initialised:
		return true
	initialised = true
	return false


func _set_state(value: int) -> void:
	state = value
	initialised = false


## the pane transition update: the pane slides to viewport_target over 16 ticks, then the pane changes.
func _slide() -> void:
	if not _test_and_set():
		slide_step = (viewport_target - viewport_x) / PANE_TICKS
		slide_ticks = PANE_TICKS
		sound.emit(0x1E)
	viewport_x += slide_step
	slide_ticks -= 1
	if slide_ticks == 0:
		viewport_x = viewport_target
		pane = 1 if viewport_target != 0 else 0
		_set_state(next_state)


## the chest pane input update and the deck pane input update.
func _pane_input(pad: Dictionary, deck: bool) -> void:
	var list: Dictionary = lists[pane]
	_test_and_set()
	if viewer_open:
		_viewer_update(pad)   # the pane is idle while the viewer is up (the duel's effect state takes the pad)
		return
	if _update_list(list, pad):
		return
	var pressed: Dictionary = pad.pressed
	var down: Dictionary = pad.down
	var repeat: Dictionary = pad.repeat
	if pressed.has("triangle"):
		var viewed := _active_id(list)
		if viewed != 0:
			_open_viewer(viewed)
		return
	if not deck and _only(down, "right"):
		viewport_target = 320
		next_state = STATE_DECK
		_set_state(STATE_SLIDE)
		return
	if deck and _only(down, "left"):
		viewport_target = 0
		next_state = STATE_CHEST
		_set_state(STATE_SLIDE)
		return
	if pressed.has("cancel"):
		next_state = STATE_DECK if deck else STATE_CHEST
		_set_state(STATE_LEAVE)
		return
	if repeat.has("confirm"):
		if deck:
			_return_highlighted(list)
		else:
			_add_highlighted(list)


func _active_id(list: Dictionary) -> int:
	var record: Dictionary = list.rows[list.first + list.cursor]
	return record.id if record.flags != 0 else 0


## Chest, Cross or Square: the card goes to the deck (Exodia pieces at one copy, the deck at most three copies and 40 cards).
func _add_highlighted(list: Dictionary) -> void:
	var id := _active_id(list)
	var allowed := id != 0
	if allowed and id >= EXODIA_FIRST and id < EXODIA_FIRST + EXODIA_COUNT:
		allowed = deck_qty[id] < 1
	if allowed and deck_total < DECK_SIZE and chest_qty[id] != 0 and deck_qty[id] < COPY_LIMIT:
		sound.emit(7)
		_add_to_deck(id)
		_take_from_chest(id)
		_refresh_counts()
		return
	sound.emit(9)


## Deck, Cross or Square: the card goes back to the chest.
func _return_highlighted(list: Dictionary) -> void:
	var id := _active_id(list)
	if id == 0:
		sound.emit(9)
		return
	sound.emit(7)
	list.rows[list.first + list.cursor].flags = 0
	_sort(list)
	deck_total = _recount_deck()
	_return_to_chest(id)
	_refresh_counts()


## the card add: the first free deck row takes the card, then the deck is sorted and counted.
func _add_to_deck(id: int) -> void:
	var rows: Array = lists[1].rows
	for row in rows:
		if row.flags == 0:
			row.id = id
			row.flags = FLAG_ON
			row.type = stat_records[id].type
			row.atk = stat_records[id].atk
			row.def = stat_records[id].def
			break
	_sort(lists[1])
	deck_total = _recount_deck()
	stat_records[id].flags = _flag_of(id)


## the chest-to-deck card move: one copy leaves the chest; when none is left the chest row goes dim and the list is sorted.
func _take_from_chest(id: int) -> void:
	if chest_qty[id] == 0:
		return
	chest_qty[id] -= 1
	if chest_qty[id] == 0:
		stat_records[id].flags = _flag_of(id)
		_sort(lists[0])


## the deck-to-chest card move: a copy comes back; from none, the chest row is shown again and the list sorted. At the chest's
## limit nothing is counted (the copy is lost, as the console does it).
func _return_to_chest(id: int) -> void:
	if chest_qty[id] == 0:
		chest_qty[id] += 1
		stat_records[id].flags = _flag_of(id)
		_sort(lists[0])
	elif chest_qty[id] != CHEST_LIMIT:
		chest_qty[id] += 1


func _refresh_counts() -> void:
	_rebuild_counts()


## the count display refresh: the chest total and the deck total on the count line.
func _rebuild_counts() -> void:
	for child in counts_line.get_children():
		counts_line.remove_child(child)
		child.queue_free()
	# the count display refresh: the flagged text box creation(3, 14, 0x16, 0x17): the string's pen moves and its two numbers (the chest
	# total at 0x801D5608, the deck's at 0x801D560C) are laid out by the text layout, as on the disc
	if digit_codes.size() != 10:
		digit_codes.clear()
		for i in 10:
			digit_codes.append(text.code_for_sjis(DIGIT_SJIS + i))
	var ctx := {"digits": digit_codes, "numbers": {CHEST_TOTAL_ADDRESS: _chest_total(), DECK_TOTAL_ADDRESS: deck_total}}
	text.layout(counts_line, text.string_bytes(COUNT_STRING), COUNT_LINE_ORIGIN, Vector2(8, 12), 0, sharp, true, {}, ctx)
	if dialog_open:
		_rebuild_dialog()


## the routine at 0x800339D0: the screen's exit. A deck with an open slot asks first; the answer other than the first saves and leaves, the
## first returns to the editing. A full deck saves and leaves at once.
func _leave(pad: Dictionary) -> void:
	if not _test_and_set():
		sound.emit(8)
		if _has_open_slot():
			dialog_open = true
			dialog_choice = 0
			_rebuild_dialog()
			return
	if dialog_open:
		var moved := dialog_choice
		if pad.pressed.has("up"):
			moved = 0
		elif pad.pressed.has("down"):
			moved = 1
		if moved != dialog_choice:
			dialog_choice = moved
			sound.emit(6)
			_rebuild_dialog()
		if pad.pressed.has("confirm"):
			_answer_dialog(dialog_choice)
		elif pad.pressed.has("cancel"):
			_answer_dialog(0)
		return
	_save()
	_set_state(STATE_DONE)


func _has_open_slot() -> bool:
	for row in lists[1].rows:
		if row.flags == 0:
			return true
	return false


func _answer_dialog(choice: int) -> void:
	dialog_choice = choice
	dialog_open = false
	_rebuild_dialog()
	if choice == 0:
		_set_state(next_state)


func _rebuild_dialog() -> void:
	for child in dialog.get_children():
		dialog.remove_child(child)
		child.queue_free()
	if not dialog_open:
		return
	# the box is the campaign dialog frame (assets/screens/story/frame.png, its panel nine-sliced around the box)
	var frame_tex := _dialog_frame()
	var back := Node2D.new()
	dialog.add_child(back)
	# the frame's border lies outside the text box: its panel is the box grown by the border on every side
	var frame_rect := DIALOG_RECT.grow(DIALOG_FRAME_OUTSIDE)
	if frame_tex != null:
		back.draw.connect(func() -> void: TextFrame.draw(back, frame_tex, DIALOG_FRAME_SOURCE, frame_rect, DIALOG_FRAME_BORDER))
	else:
		var black := ColorRect.new()
		black.color = Color(0, 0, 0, 0.9)
		black.position = frame_rect.position
		black.size = frame_rect.size
		back.add_child(black)
	text.layout(dialog, text.string_bytes(DIALOG_STRING), DIALOG_TEXT, Vector2(8, 12), 0, sharp, true)
	# the choice highlight: the yellow additive bar of the story's choice lines, across the box's width, 10 tall from its line's top + 1
	var bar := Polygon2D.new()
	var edge := Color(0.19, 0.19, 0.0)
	var mid := Color(0.75, 0.75, 0.0)
	var top := DIALOG_LINE_TOP + 12.0 * dialog_choice
	var x0 := DIALOG_RECT.position.x
	var x1 := DIALOG_RECT.end.x
	var centre := (x0 + x1) / 2.0
	bar.polygon = PackedVector2Array([Vector2(x0, top), Vector2(centre, top), Vector2(x1, top), Vector2(x1, top + 10), Vector2(centre, top + 10), Vector2(x0, top + 10)])
	bar.vertex_colors = PackedColorArray([edge, mid, edge, edge, mid, edge])
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bar.material = add
	dialog.add_child(bar)


var dialog_frame_texture: Texture2D

# ---- the card viewer (Triangle on a card, as the duel's card viewer opens from the Build Deck) ----
var viewer_open := false                   # the viewer is up (sliding in, shown, or sliding out)
var viewer_closing := false
var viewer_slide := 0                      # ticks of the slide so far
var viewer_id := 0                         # the card shown
var viewer_fade := 255                     # the board's brightness level (0xFF, 0x40 with the viewer up)
var viewer_shade := ColorRect.new()        # the board's dim: black at 1 - level / 255
var viewer_node := Node2D.new()            # the window's own layer above the board
var viewer_frame := Sprite2D.new()
var viewer_art := Sprite2D.new()
var viewer_text := Node2D.new()            # the text box's content, in the box's own coordinates (origin: the box's top-left)
var viewer_icons := Node2D.new()
var viewer_frame_offset := Vector2(-8, -8)  # the frame picture's offset from its box (the library's card_frame layout)
var viewer_view: CardView                  # the card view's text box, stats and icons (shared with the Library)



func _dialog_frame() -> Texture2D:
	if dialog_frame_texture == null:
		var image := Image.load_from_file("res://assets/screens/story/frame.png")
		if image != null:
			dialog_frame_texture = ImageTexture.create_from_image(image)
	return dialog_frame_texture


## The deck as the save keeps it: its rows in order, 0 for an empty row; the owned copies are the chest's plus the deck's.
func _save() -> void:
	var ids: Array = []
	for row in lists[1].rows:
		ids.append(row.id if row.flags != 0 else 0)
	_recount_deck()
	var owned := PackedInt32Array()
	owned.resize(CARD_COUNT)
	for id in range(1, CARD_COUNT + 1):
		owned[id - 1] = chest_qty[id] + deck_qty[id]
	GameState.deck = ids
	GameState.card_counts = owned


## the card list input update: the scroll glide, the held L1 and R1 page by eight rows, the repeated L2 and R2 page by fifty,
## Up and Down move the cursor (the page scrolls when it reaches the edge), and START and SELECT step the sort. True when it used
## the input.
func _update_list(list: Dictionary, pad: Dictionary) -> bool:
	if list.first != list.first_target:
		_step_first(list)
		return true
	var down: Dictionary = pad.down
	var repeat: Dictionary = pad.repeat
	if down.get("l1", false) or down.get("r1", false):
		var sel := -1
		var row: int = list.first
		if down.get("r1", false):
			if row == list.row_count - PAGE and list.cursor != 7:
				sel = 7
			row += PAGE
			if list.row_count - PAGE < row:
				row = list.row_count - PAGE
		else:
			if row == 0 and list.cursor != 0:
				sel = 0
			row -= PAGE
		if row < 0:
			row = 0
		list.first_target = row
		if list.first != row:
			sound.emit(6)
			_step_first(list)
			return true
		if sel >= 0:
			list.cursor = sel
			sound.emit(6)
		return true
	if repeat.has("l2") or repeat.has("r2"):
		var sel := -1
		var row: int = list.first
		if repeat.has("r2"):
			if row == list.row_count - PAGE and list.cursor != 7:
				sel = 7
			row += PAGE_JUMP
			if list.row_count - PAGE < row:
				row = list.row_count - PAGE
		else:
			if row == 0 and list.cursor != 0:
				sel = 0
			row -= PAGE_JUMP
			if row < 0:
				row = 0
		if list.first != row:
			sound.emit(6)
			list.first_target = row
			list.first = row
			return true
		if sel >= 0:
			list.cursor = sel
			sound.emit(6)
		return true
	if repeat.has("up") or repeat.has("down"):
		var row: int = list.first
		if repeat.has("down"):
			list.cursor += 1
			if list.cursor >= PAGE:
				row += 1
				list.cursor = 7
		else:
			list.cursor -= 1
			if list.cursor < 0:
				row -= 1
				list.cursor = 0
		if list.row_count - PAGE < row:
			return true
		if row < 0:
			return true
		sound.emit(6)
		list.first_target = row
		if list.first != row:
			_step_first(list)
		return true
	if repeat.has("start") or repeat.has("select"):
		if repeat.has("start"):
			list.sort_choice += 1
			if list.sort_choice >= 7:
				list.sort_choice = 0
		else:
			list.sort_choice -= 1
			if list.sort_choice < 0:
				list.sort_choice = 6
		sound.emit(0x2F)
		list.sort_mode = SORT_MODES[list.kind][list.sort_choice]
		_sort(list)
		return true
	return false


## One row of the scroll towards first_target.
func _step_first(list: Dictionary) -> void:
	if list.first_target < list.first:
		list.first -= 1
	else:
		list.first += 1


## the routine at 0x80032C48: sorts the list's rows by the sort mode. The comparators: the descending one for the stat modes, ascending for
## the rest; equal keys fall to the name order.
func _sort(list: Dictionary) -> void:
	var n: int = list.sort_row_count
	var mode: int = list.sort_mode
	var rows: Array = list.rows
	for i in n:
		rows[i].key = _key(mode, list.kind, rows[i])
	var part: Array = rows.slice(0, n)
	if mode == 3 or mode == 4 or mode == 5:
		part.sort_custom(_less_desc)
	else:
		part.sort_custom(_less_asc)
	for i in n:
		rows[i] = part[i]


func _key(mode: int, kind: int, row: Dictionary) -> int:
	var on: bool = row.flags != 0
	match mode:
		1:
			if kind != 0:
				return row.id if on else 0xFFFF
			return row.id
		2:
			return 0 if on else U32_NEG
		3:
			if not on:
				return 0
			if row.atk * 10 >= row.def * 10:
				return _pack(row.atk, row.def)
			return _pack(row.def, row.atk)
		4:
			return _pack(row.atk, row.def) if on else 0
		5:
			return _pack(row.def, row.atk) if on else 0
		6:
			return row.type if on else U32_NEG
		8:
			if not on:
				return U32_NEG
			# the card list sort case 8: the card's rank among the recent drops (newest is 1), or 0x100 for the rest
			return card_rank[row.id] if card_rank[row.id] != 0 else 0x100
		9:
			return randi() % 0x1000 if on else U32_NEG
	return 0


## The packed sort key of a stat pair (half-scaled stats; the stat is the higher-order one).
func _pack(high: int, low: int) -> int:
	return ((high * 5) << 17) | ((low * 5) << 3) | 1


func _name_key(id: int) -> int:
	return name_rank[id] if id > 0 and id < name_rank.size() else 0x7FFFFFFF


func _less_asc(a: Dictionary, b: Dictionary) -> bool:
	if a.key == b.key:
		return _name_key(a.id) < _name_key(b.id)
	return a.key < b.key


func _less_desc(a: Dictionary, b: Dictionary) -> bool:
	if a.key == b.key:
		return _name_key(a.id) < _name_key(b.id)
	return a.key > b.key


## The board: the two boxes and their sort icons, the rows of both panes, the cursor bars and the scroll thumbs, all in the 640-wide
## workspace (the viewport shows 320 pixels of it). Positions are the routine at 0x800323F8's and the routine at 0x80031874's; the pulse is
## the card list input update's cursor colour from the routine at 0x80033BE8.
func _draw_board() -> void:
	var pulse := _pulse()
	for k in 2:
		# the sand picture is 224 rows; the original leaves the last 16 rows black (under the TV overscan, checked on the
		# reference frame), so nothing is drawn below it and the black plate behind the board shows through
		board.draw_texture(tex["sand"], _art("sand", Vector2(BOX_X[k], 0)))
	board.draw_texture(tex["page_buttons"], _art("page_buttons", Vector2(BOX_X[1], 0)))
	board.draw_texture(tex["chest_box"], _art("chest_box", Vector2(BOX_X[0], 0)))
	board.draw_texture(tex["deck_box"], _art("deck_box", Vector2(BOX_X[1], 0)))
	for k in 2:
		var list: Dictionary = lists[k]
		var header_x: int = PANE_X[k] + HEADER_X[k]
		var icons := SORT_ICONS.duplicate()
		icons.append("sort_your_order" if k == 0 else "sort_random")
		for i in 7:
			var tint := Color(1, 1, 1) if SORT_MODES[k][i] == list.sort_mode else Color(0.25, 0.25, 0.25)
			board.draw_texture(tex[icons[i]], Vector2(header_x + 18 * i, HEADER_Y), tint)
		for i in PAGE:
			var index: int = list.first + i
			if index >= list.rows.size():
				break
			var row: Dictionary = list.rows[index]
			# a chest row with no card keeps the picture's copy cells (the lock and diamond plates), as the reference frame shows
			if row.flags != 0:
				_draw_row(k, list, row, PANE_X[k], ROW_TOP + ROW_STEP * i, index)
		var cursor_tint := Color(pulse, pulse, pulse)
		var cursor := "cursor_bar" if k == 0 else "cursor_bar_blue"
		board.draw_texture(tex[cursor], _art(cursor, Vector2(CURSOR_X[k], CURSOR_Y + ROW_STEP * list.cursor)), cursor_tint)
		var thumb_row := 0
		if (list.first | list.cursor) != 0:
			thumb_row = (list.first + list.cursor + 1) * 152 / list.sort_row_count
		board.draw_texture(tex["thumb"], _art("thumb", Vector2(SCROLL_X[k], SCROLL_Y + thumb_row)))
	_draw_arrow("arrow_right", Vector2(BOX_X[0], 0))
	_draw_arrow("arrow_left", Vector2(BOX_X[1], 0))


## A red arrow: its stream's frames in play order, each held for its ticks, the sequence looping (the arrow's stream holds 6 ticks each).
func _draw_arrow(arrow: String, at: Vector2) -> void:
	var entry: Dictionary = art.get(arrow, {})
	var sequence: Array = entry.get("sequence", [])
	var frames: Array = entry.get("frames", [])
	if sequence.is_empty() or frames.is_empty():
		board.draw_texture(tex[arrow], _art(arrow, at))
		return
	var total := 0
	for step in sequence:
		total += int(step[0])
	var t := frame % maxi(total, 1)
	var index := int(sequence[0][1])
	for step in sequence:
		if t < int(step[0]):
			index = int(step[1])
			break
		t -= int(step[0])
	var name: String = frames[index]
	board.draw_texture(tex[name], _art(name, at))


## A picture's place: the origin the game gives its object plus the offset layout.json cut it to (zero for a sprite).
func _art(name: String, at: Vector2) -> Vector2:
	var entry: Dictionary = art.get(name, {})
	return at + Vector2(float(entry.get("x", 0)), float(entry.get("y", 0)))


## the routine at 0x80031874 for one row: the id (the deck also numbers its rows), the ATK and DEF of a monster, and the chest's and deck's
## copies on the second line. The colour is dim for a card held only in the deck.
func _draw_row(k: int, list: Dictionary, row: Dictionary, x: int, y: int, index: int) -> void:
	var tint := Color(0.5, 0.5, 0.5) if (row.flags & FLAG_HELD) != 0 else Color(1, 1, 1)
	var anchor: int
	if k == 0:
		_digits_zero(row.id, 3, Vector2(x + 4, y), tint)
		if row.flags != 0 and card_rank[row.id] != 0:
			board.draw_texture(tex["new_mark"], Vector2(x + 4, y + 8), tint)     # the routine at 0x80031874: the "New!" plate under a recent drop
		anchor = x + 4 + 24 + 0x88
		_digits(chest_qty[row.id], 3, Vector2(x + 0x107, y + 8), tint)
		var copies: int = deck_qty[row.id]
		var red: bool = copies >= COPY_LIMIT or (row.id >= EXODIA_FIRST and row.id < EXODIA_FIRST + EXODIA_COUNT and copies != 0)
		_digits(copies, 2, Vector2(x + 0x122, y + 8), Color(1, 0.125, 0.125) if red else tint)
	else:
		_digits_zero(index + 1, 2, Vector2(x + 0x11, y), tint)
		_digits_zero(row.id, 3, Vector2(x + 0x25, y), tint)
		anchor = x + 0x25 + 24 + 0x88
	if row.type < CARD_TYPE_MAGIC:
		board.draw_texture(tex["atk_mark"], Vector2(anchor, y), tint)
		_digits(row.atk * 10, 4, Vector2(anchor + 8, y), tint)
		board.draw_texture(tex["def_mark"], Vector2(anchor, y + 8), tint)
		_digits(row.def * 10, 4, Vector2(anchor + 8, y + 8), tint)


## The card id and the deck's row number: the original writes their leading blanks as zero digits (the 005 and 05 of the list).
func _digits_zero(value: int, width: int, at: Vector2, tint: Color) -> void:
	var digits := str(value).lpad(width, "0")
	if digits.length() > width:
		digits = digits.substr(digits.length() - width)
	for k in digits.length():
		board.draw_texture(tex["digit_%s" % digits[k]], at + Vector2(8 * k, 0), tint)


## Draws a number as digit glyphs, eight pixels a digit, with the leading zeros left blank (the blank is no digit).
func _digits(value: int, width: int, at: Vector2, tint: Color) -> void:
	var digits := str(value)
	if digits.length() > width:
		digits = digits.substr(digits.length() - width)
	var pad := width - digits.length()
	for k in digits.length():
		board.draw_texture(tex["digit_%s" % digits[k]], at + Vector2(8 * (pad + k), 0), tint)


## The cursor's colour: the pulse of the routine at 0x80033BE8, 0x40 to 0x7E over a 64-frame cycle, as a fraction of the neutral 0x80.
func _pulse() -> float:
	var intensity := frame & 0x3F
	if intensity >= 0x20:
		intensity = 0x3F - intensity
	return (intensity * 2 + 0x40) / 128.0


## The card viewer: the card's picture slides in from the left and the text box from the right over
## VIEW_TICKS ticks while the board dims; Circle slides both back and closes. Up and Down show the next card that has a row in the
## list (the PC port's card browse, Build Deck): the cursor moves along with it and the card is replaced without a slide.
func _read_viewer_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _open_viewer(id: int) -> void:
	viewer_id = id
	viewer_open = true
	viewer_closing = false
	viewer_slide = 0
	_show_viewer_card(id)
	viewer_node.visible = true
	_place_viewer(0.0)
	sound.emit(0x34)


func _viewer_update(pad: Dictionary) -> void:
	# the board's dim: the fade steps two levels a tick toward its target (0x40 up, 0xFF back down)
	var target := 0xFF if viewer_closing else VIEW_FADE_REST
	if viewer_fade < target:
		viewer_fade = mini(viewer_fade + 2, target)
	elif viewer_fade > target:
		viewer_fade = maxi(viewer_fade - 2, target)
	viewer_shade.color = Color(0, 0, 0, 1.0 - viewer_fade / 255.0)
	if viewer_closing or viewer_slide < VIEW_TICKS:
		viewer_slide += 1
		var progress := clampf(float(viewer_slide) / VIEW_TICKS, 0.0, 1.0)
		_place_viewer(1.0 - progress if viewer_closing else progress)
		if viewer_closing and viewer_slide >= VIEW_TICKS:
			viewer_open = false
			viewer_node.visible = false
		return
	if pad.pressed.has("cancel"):
		viewer_closing = true
		viewer_slide = 0
		sound.emit(0x34)
		return
	if pad.repeat.has("up") or pad.repeat.has("down"):
		_browse_viewer(1 if pad.repeat.has("down") else -1)


## The viewer's place for a progress p (0 off to the side, 1 at rest), eased in with a sine.
func _place_viewer(p: float) -> void:
	var e := sin(p * PI / 2.0)
	var box_x := lerpf(VIEW_BOX_OFF, VIEW_BOX_REST, e)
	var art_x := lerpf(VIEW_ART_OFF, VIEW_ART_REST, e)
	viewer_frame.position = Vector2(box_x, VIEW_Y + 14) + viewer_frame_offset
	viewer_text.position = Vector2(box_x, VIEW_Y + 14)
	viewer_icons.position = Vector2(box_x, VIEW_Y + 14)
	viewer_art.position = Vector2(art_x, VIEW_Y)


## Up or Down with the viewer shown: the list's cursor moves to the next card with a row (none: the cannot sound), the card is replaced.
func _browse_viewer(step: int) -> void:
	var list: Dictionary = lists[pane]
	var rows: int = list.row_count
	var at: int = list.first + list.cursor
	if list.first != list.first_target or int(list.rows[at].id) != viewer_id:
		return
	var row := at + step
	while row >= 0 and row < rows and list.rows[row].flags == 0:
		row += step
	if row < 0 or row >= rows:
		sound.emit(9)
		return
	var first := clampi(row - list.cursor, 0, maxi(rows - PAGE, 0))
	list.first = first
	list.first_target = first
	list.cursor = row - first
	viewer_id = int(list.rows[row].id)
	_show_viewer_card(viewer_id)
	sound.emit(6)


func _show_viewer_card(id: int) -> void:
	for node in [viewer_text, viewer_icons]:
		for child in node.get_children():
			node.remove_child(child)
			child.queue_free()
	var art_record: Dictionary = cards.art(id)
	if not art_record.is_empty():
		ModArt.apply(viewer_art, art_record)
	var data: Dictionary = cards.card(id)
	if data.is_empty():
		return
	viewer_view.build(viewer_text, viewer_icons, id, data)
