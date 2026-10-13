extends Control
## The TRADE screen (the trade run: the trade screen setup, the trade screen update and the inventory and offer helpers). Two
## players, each with a column: the chest (the owned copies less the deck's) listed card by card, and up to ten cards offered.
## Player 1 is the save in memory (GameState), player 2 is the second memory card's save (user://save2.json, the same format as
## GameState.save_game). The trade is only open while both are there; otherwise the caller shows MEMORY CARD REQUIRED.
##
## Player 1 keys: W and S move, E adds the highlighted card to the offer, Q takes the last offer back (or leaves the screen when
## nothing is offered), F settles (SETTLED!). Player 2 keys: Up and Down move, Enter adds, Backspace takes back, / settles. Both
## work the same way the controls do in the game (Cross adds, Circle takes back, Square settles). Mouse: a click on a row adds that
## card, a right click takes back or leaves for the side under the pointer. A and D (player 2: Left and Right) turn the list a page
## of seven rows.
## When both players have settled, the three choices come up: EXECUTE TRADE, RE-SELECT and RETURN TO TITLE (string 0x20, Up and
## Down choose, E or Enter confirms, Q or Backspace is RE-SELECT). EXECUTE TRADE moves each offered card from the offering chest
## to the other one (250 at most), writes both saves while NOW TRADING CARD(S) is up, and shows TRADE COMPLETE! (the offers clear
## and the screen goes on) or TRADE FAILED! (the choice comes back with nothing moved).
##
## Approximations: the lists are sorted by card id (the game's sort modes, the R1 and L2 keys, are not ported), the card viewer (Triangle)
## is not opened, the inventory rows are name and count only, the names are cut to 13 characters, the list moves a row at a time without
## the game's scroll animation, and the write takes about a second instead of the memory card's own time.

signal closed                  # the trade is left: back to the menu on the TRADE entry
signal sound(effect: int)      # the SE play ids: 6 cursor, 7 card offered, 8 cancel, 9 refused, 48 settled and the choice, 0x1E page
signal music(id: int)           # the BGM play this screen starts when it opens (the driver's BGM play)

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const CardDB := preload("res://scripts/data/card_db.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const FRAME := "res://assets/screens/story/frame.png"
const SLOT_TWO := "user://save2.json"
const CARD_COUNT := 722
const CHEST_LIMIT := 250                   # CARD_CHEST_QUANTITY_MAX
const OFFER_LIMIT := 10                    # a side offers ten cards at most (the data at 0x80185C9C[side][0] < 10)
const VISIBLE := 7                         # rows of the inventory on screen
const CARD_UI := "res://assets/screens/card_ui/"      # the card-kind offer icons (card_type_*.png, tools/extract.py bake_card_ui)
var icon_cache: Dictionary = {}
const BACKDROP := "res://assets/screens/backdrops/"   # the sand, the 1P and 2P panel grid and the red cursor bar (tools/extract.py bake_backdrops)
const ROW_TOP := 36                        # the first inventory row's cell: the panel grid's rows are 22 apart from y 36
const ROW_STEP := 22
const COLUMN_X := [0, 160]
const OFFER_Y := 188                      # the offers: five to a row, 28 apart, the rows 17 apart (the offer drawing at 0xBC)
const OFFER_X := [16, 176]
const OFFER_STEP := Vector2(28, 17)
const TEXT_ORIGIN := Vector2(16, 174)
const TEXT_ADVANCE := Vector2(8, 12)
const WRITE_FRAMES := 60
const REPEAT_DELAY := 24
const REPEAT_RATE := 6
const CHOICE_EXECUTE := 0
const CHOICE_RESELECT := 1
const CHOICE_LEAVE := 2
const CHOICE_LABELS := ["EXECUTE TRADE", "RE-SELECT", "RETURN TO TITLE"]
const STRING_SETTLED := 10                 # SETTLED!
const STRING_HELP := 11                    # SELECT CARD TO TRADE: the help panel up when the screen opens (OK, CANCEL, SELECTION COMPLETE, SELECT CARD)
const HELP_ORIGIN := Vector2(24, 32)       # the help's first line (its own panel, over the lists until the first card is offered)
const HELP_BOX_RECT := Rect2(24, 32, 272, 160)   # the help panel's box (measured on the reference frame: its top corners at y 24, its side points at x 16 and 304)
const TextBoxBg := preload("res://scripts/ui/text_box_bg.gd")
const STRING_WRITING := 196                # NOW TRADING CARD(S) ...
const STRING_FAILED := 197                 # TRADE FAILED!
const STRING_COMPLETE := 198               # TRADE COMPLETE!
const KEYS := [
	{"up": [KEY_W], "down": [KEY_S], "page_up": [KEY_A], "page_down": [KEY_D], "add": [KEY_E], "cancel": [KEY_Q], "ready": [KEY_F]},
	# player 2 also has Triangle (ready) and L1 (cancel) on the touch controls, which have no slash or backspace
	{"up": [KEY_UP], "down": [KEY_DOWN], "page_up": [KEY_LEFT], "page_down": [KEY_RIGHT], "add": [KEY_ENTER, KEY_KP_ENTER],
		"cancel": [KEY_BACKSPACE, KEY_Z], "ready": [KEY_SLASH, KEY_R]},
]
const MODAL_UP := [KEY_W, KEY_UP]
const MODAL_DOWN := [KEY_S, KEY_DOWN]
const MODAL_CONFIRM := [KEY_E, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]
const MODAL_CANCEL := [KEY_Q, KEY_BACKSPACE, KEY_ESCAPE]

var text := GameText.new()
var cards := CardDB.new()
var glyph_codes: Dictionary = {}      # Shift-JIS code -> glyph index
var sharp: ShaderMaterial
var ready_ok := false
var world := Node2D.new()
var sides: Array = []                 # per side: name, chest, deck copies, offers, ready, cursor, top, rows, file (player 2's save)
var state := "browse"                 # browse, choice, writing, message
var choice := CHOICE_EXECUTE
var help_up := false                  # the help panel is up (it goes once a card is offered)
var help_box: Node2D                  # the help's flagged box (text_box_bg.gd): the subtractive hexagon over the lists
var message_id := 0                   # the message up: STRING_COMPLETE or STRING_FAILED
var timer := 0
var repeat: Dictionary = {}
var held: Dictionary = {}
var click_pending := false
var click_at := Vector2.ZERO
var right_pending := false
var right_at := Vector2.ZERO
var wheel_steps: Array = [0, 0]      # per side: wheel notches over its list, negative up, positive down; one row each
var rows_node: Array = [Node2D.new(), Node2D.new()]
var offers_node: Array = [Node2D.new(), Node2D.new()]
var cursor_node := Node2D.new()
var cursor_texture: Texture2D                 # the red cursor bar of the rows (the trade cursor object, 128 x 18)
var cursor_offset := Vector2.ZERO             # its offset from its origin (the origin is (30 + 160 * column, 36))
var status_node := Node2D.new()
var prompt_node := Node2D.new()
var panel: Sprite2D
# the settled side's dim: its column is darkened by a grey 0x40 quad with the subtract blend, and its cursor bar's
# colour is held at 0x40; a side not settled pulses its cursor between 0x40 and 0x7E in steps of 2 (the object starts at 0x80 going down)
var column_dim: Array = []
var cursor_colour: Array = [0x80, 0x80]
var cursor_speed: Array = [-2, -2]


## The trade can open with both saves: this player's (a campaign in memory) and the second memory card's file.
static func can_open() -> bool:
	return GameState.has_campaign() and FileAccess.file_exists(SLOT_TWO)


func _ready() -> void:
	music.emit(29392)   # the BGM play in this screen's open routine
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all() or not cards.load_all() or not can_open():
		return
	for i in text.glyphs.size():
		var sjis := int(text.glyphs[i]["sjis"])
		if not glyph_codes.has(sjis):
			glyph_codes[sjis] = i
	_load_sides()
	sharp = ScreenFit.make_material()
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(world)
	add_to_group("fit")
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(320, 240)
	black.z_index = -3
	world.add_child(black)
	# the backdrop: the sand (its object at the origin), and the panel grid with the 1P and 2P tabs (its object at (0, -3))
	var layout = JSON.parse_string(FileAccess.get_file_as_string(BACKDROP + "layout.json"))
	if layout is Dictionary:
		for key in ["sand", "trade_panel"]:
			var entry: Dictionary = layout.get(key, {})
			if entry.is_empty():
				continue
			var backdrop := Sprite2D.new()
			backdrop.centered = false
			backdrop.position = Vector2(float(entry["origin"][0]) + float(entry["x"]), float(entry["origin"][1]) + float(entry["y"]))
			backdrop.z_index = -2
			var file := "sand.png" if key == "sand" else "trade/panel.png"
			var backdrop_image := Image.load_from_file(BACKDROP + file)
			if backdrop_image != null:
				backdrop.texture = ImageTexture.create_from_image(backdrop_image)
			backdrop.material = sharp
			world.add_child(backdrop)
			# the sand is 224 rows: the 16 below it stay black, as the reference frame has them (the black backdrop behind)
		var cursor_entry: Dictionary = layout.get("trade_cursor", {})
		var cursor_image := Image.load_from_file(BACKDROP + "trade/cursor.png")
		if cursor_image != null:
			cursor_texture = ImageTexture.create_from_image(cursor_image)
		cursor_offset = Vector2(float(cursor_entry.get("x", 0)), float(cursor_entry.get("y", 0)))
	panel = Sprite2D.new()
	panel.centered = false
	panel.z_index = 5
	var image := Image.load_from_file(FRAME)
	if image != null:
		panel.texture = ImageTexture.create_from_image(image)
		panel.material = sharp
	panel.visible = false
	world.add_child(panel)
	help_box = TextBoxBg.new()
	help_box.setup(HELP_BOX_RECT)
	help_box.z_index = 4
	help_box.visible = false
	world.add_child(help_box)
	for i in 2:
		world.add_child(rows_node[i])
		world.add_child(offers_node[i])
		_rebuild(i)
	cursor_node.z_index = 2
	for i in 2:
		var dim := ColorRect.new()
		dim.position = Vector2(COLUMN_X[i], 0)
		dim.size = Vector2(160, 240)
		dim.color = Color(0.25098, 0.25098, 0.25098, 1)   # RGB 0x40: the subtract blend takes it off the column below
		var sub := CanvasItemMaterial.new()
		sub.blend_mode = CanvasItemMaterial.BLEND_MODE_SUB
		dim.material = sub
		dim.z_index = 1
		dim.visible = false
		world.add_child(dim)
		column_dim.append(dim)
	cursor_node.draw.connect(_draw_cursor)
	world.add_child(cursor_node)
	status_node.z_index = 3
	world.add_child(status_node)
	prompt_node.z_index = 6
	world.add_child(prompt_node)
	_refresh_status()
	_show_help()
	get_viewport().size_changed.connect(refit)
	refit()
	ScreenFit.pass_mouse(self)
	ready_ok = true


func refit() -> void:
	ScreenFit.apply(world, size)


## Player 1's chest is the owned copies less the deck's; player 2's is read from its save file the same way.
func _load_sides() -> void:
	var owned: PackedInt32Array = GameState.owned_counts()
	sides = [_side(GameState.player_name, owned, GameState.deck)]
	var data = JSON.parse_string(FileAccess.get_file_as_string(SLOT_TWO))
	if typeof(data) != TYPE_DICTIONARY:
		data = {}
	var counts: PackedInt32Array = PackedInt32Array(data.get("counts", []))
	counts.resize(CARD_COUNT)
	sides.append(_side(data.get("name", [0, 0, 0, 0, 0, 0]), counts, data.get("deck", [])))


func _side(name: Array, owned: PackedInt32Array, deck: Array) -> Dictionary:
	var copies := PackedInt32Array()
	copies.resize(CARD_COUNT)
	for id in deck:
		if int(id) >= 1 and int(id) <= CARD_COUNT:
			copies[int(id) - 1] += 1
	var chest := PackedInt32Array()
	chest.resize(CARD_COUNT)
	for i in CARD_COUNT:
		chest[i] = maxi(int(owned[i]) - copies[i], 0)
	return {"name": name, "chest": chest, "copies": copies, "owned": owned.duplicate(), "deck": deck.duplicate(),
		"offers": [], "ready": false, "cursor": 0, "top": 0, "rows": []}


## The copies a side can still offer: its chest less what it has offered already.
func _working(side: int, id: int) -> int:
	var n: int = sides[side]["chest"][id - 1]
	for offered in sides[side]["offers"]:
		if int(offered) == id:
			n -= 1
	return n


func _rows(side: int) -> Array:
	var out: Array = []
	for id in range(1, CARD_COUNT + 1):
		if _working(side, id) > 0:
			out.append(id)
	return out


## The glyph codes of an ASCII string (library.gd's font mapping; anything else is a blank).
func _bytes(string: String) -> Array:
	var out: Array = []
	for c in string:
		var code := c.unicode_at(0)
		var sjis := 0
		if c == " ":
			out.append(0)
			continue
		elif c == "'":
			out.append(27)
			continue
		elif c == "-":
			out.append(48)
			continue
		elif c == "/":
			out.append(68)
			continue
		elif c == ".":
			out.append(11)
			continue
		elif code >= 97 and code <= 122:
			sjis = 0x8281 + code - 97
		elif code >= 65 and code <= 90:
			sjis = 0x8260 + code - 65
		elif code >= 48 and code <= 57:
			sjis = 0x824F + code - 48
		out.append(glyph_codes.get(sjis, 0))
	return out


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


## The inventory rows and offers of one side: the rows scroll so the cursor is on screen.
## The type icon of an offered card (the card-kind pictures of the card sheet: monster, magic, trap or ritual; equip shows the magic icon).
func _offer_icon(parent: Node2D, id: int, at: Vector2) -> void:
	var kind := "monster"
	match str(cards.card(id).get("type", "")):
		"Magic", "Equip":
			kind = "magic"
		"Trap":
			kind = "trap"
		"Ritual":
			kind = "ritual"
	if not icon_cache.has(kind):
		var image := Image.load_from_file(CARD_UI + "card_type_%s.png" % kind)
		icon_cache[kind] = ImageTexture.create_from_image(image) if image != null else null
	var texture: Texture2D = icon_cache[kind]
	if texture == null:
		return
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = texture
	sprite.material = sharp
	sprite.position = at
	parent.add_child(sprite)


func _rebuild(side: int) -> void:
	var s: Dictionary = sides[side]
	var rows := _rows(side)
	s["rows"] = rows
	if rows.is_empty():
		s["cursor"] = 0
	else:
		s["cursor"] = clampi(int(s["cursor"]), 0, rows.size() - 1)
	var cursor: int = s["cursor"]
	var top: int = s["top"]
	if cursor < top:
		top = cursor
	if cursor >= top + VISIBLE:
		top = cursor - VISIBLE + 1
	s["top"] = maxi(top, 0)
	_clear(rows_node[side])
	var x: int = COLUMN_X[side]
	for r in VISIBLE:
		var index: int = int(s["top"]) + r
		if index >= rows.size():
			break
		var id: int = rows[index]
		var name := str(cards.card(id).get("name", ""))
		if name.length() > 13:
			name = name.substr(0, 13)
		text.layout(rows_node[side], _bytes(name), Vector2(x + 34, ROW_TOP + r * ROW_STEP + 3), TEXT_ADVANCE, 0, sharp, true)
		text.layout(rows_node[side], _bytes("%3d" % _working(side, id)), Vector2(x + 128, ROW_TOP + r * ROW_STEP + 3), TEXT_ADVANCE, 0,
			sharp, true)
	_clear(offers_node[side])
	var offers: Array = s["offers"]
	for k in offers.size():
		var at := Vector2(OFFER_X[side] + (k % 5) * OFFER_STEP.x, OFFER_Y + (k / 5) * OFFER_STEP.y)
		_offer_icon(offers_node[side], int(offers[k]), at)
	cursor_node.queue_redraw()


func _refresh_status() -> void:
	_clear(status_node)
	for side in 2:
		var x: int = COLUMN_X[side]
		var name_bytes: Array = []
		for w in sides[side]["name"]:
			name_bytes.append(text.code_for_sjis(int(w)) if int(w) != 0 else 0)
		text.layout(status_node, name_bytes, Vector2(x + 34, 13), TEXT_ADVANCE, 0, sharp, true)
		if sides[side]["ready"]:
			text.layout(status_node, _bytes("SETTLED"), Vector2(x + 96, 13), TEXT_ADVANCE, 0, sharp, true)   # inside the column (56 wide)


func _draw_cursor() -> void:
	for side in 2:
		var s: Dictionary = sides[side]
		if s["rows"].is_empty():
			continue
		var r: int = int(s["cursor"]) - int(s["top"])
		if r < 0 or r >= VISIBLE:
			continue
		if cursor_texture != null:
			var tint := float(cursor_colour[side]) / 128.0
			cursor_node.draw_texture(cursor_texture, Vector2(COLUMN_X[side] + 30, ROW_TOP + r * ROW_STEP) + cursor_offset, Color(tint, tint, tint))


# ---- prompts -----------------------------------------------------------------------------------------------------------

func _show_frame(bytes: Array, origin := TEXT_ORIGIN) -> void:
	_clear(prompt_node)
	panel.visible = origin == TEXT_ORIGIN
	help_box.visible = origin != TEXT_ORIGIN
	text.layout(prompt_node, bytes, origin, TEXT_ADVANCE, 0, sharp, true)


## The help panel at the screen's opening (string 11).
func _show_help() -> void:
	help_up = true
	_show_frame(text.string_bytes(STRING_HELP), HELP_ORIGIN)
	# the names and the lists are not drawn under the help: they come up with the first offer
	for i in 2:
		rows_node[i].visible = false
	status_node.visible = false


func _hide_frame() -> void:
	_clear(prompt_node)
	panel.visible = false
	help_box.visible = false


## The three choices (string 0x20): the chosen one in the game's first colour, the others in the red ramp.
func _show_choice() -> void:
	var bytes: Array = []
	for i in CHOICE_LABELS.size():
		bytes.append_array([0xF8, 0x0A, 0 if i == choice else 4])
		bytes.append_array(_bytes(CHOICE_LABELS[i]))
		bytes.append_array([0xF8, 0x0A, 0])
		bytes.append(0xFE)
	bytes.pop_back()
	bytes.append(0xFF)
	_show_frame(bytes)


func _show_message(id: int) -> void:
	message_id = id
	_show_frame(text.string_bytes(id))


# ---- input -------------------------------------------------------------------------------------------------------------

func _down(keys: Array) -> bool:
	for k in keys:
		if Input.is_key_pressed(k):
			return true
	return false


## Edge: the key is down now and was not on the last frame.
func _edge(name: String, keys: Array) -> bool:
	var down := _down(keys)
	var was: bool = held.get(name, false)
	held[name] = down
	return down and not was


## A held key fires on its first frame and then every REPEAT_RATE frames once REPEAT_DELAY frames have passed.
func _fires(name: String, keys: Array) -> bool:
	var count: int = repeat.get(name, 0)
	if not _down(keys):
		repeat[name] = 0
		return false
	count += 1
	repeat[name] = count
	return count == 1 or (count > REPEAT_DELAY and (count - REPEAT_DELAY) % REPEAT_RATE == 0)


func _gui_input(event: InputEvent) -> void:
	if not ready_ok or not (event is InputEventMouseButton and event.pressed):
		return
	var local: Vector2 = (event.position - world.position) / world.scale
	if event.button_index == MOUSE_BUTTON_LEFT:
		click_at = local
		click_pending = true
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		right_at = local
		right_pending = true
	elif event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		# the wheel over a side's list moves that side's cursor a row a notch, as Up and Down do
		var step := -1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1
		for side in 2:
			if local.x >= COLUMN_X[side] and local.x < COLUMN_X[side] + 160 and state == "browse":
				wheel_steps[side] = clampi(int(wheel_steps[side]) + step, -10, 10)


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible:
		return
	_step_column_dim()
	match state:
		"browse":
			_browse()
		"choice":
			_choose()
		"writing":
			_write_step()
		"message":
			_message()


## The column dim and the cursor colour, once a frame (the trade drawing callback): a settled side's column is dimmed and its cursor held
## at 0x40; otherwise the cursor colour steps by its speed and turns back at 0x40 going down and at 0x80 going up.
func _step_column_dim() -> void:
	for side in 2:
		var settled: bool = sides[side]["ready"]
		column_dim[side].visible = settled
		if settled:
			cursor_colour[side] = 0x40
			cursor_speed[side] = 2
		else:
			cursor_colour[side] = (int(cursor_colour[side]) + int(cursor_speed[side])) & 0xFF
			var c: int = cursor_colour[side]
			if c < 0x41 or c >= 0x80:
				cursor_speed[side] = -int(cursor_speed[side])
	cursor_node.queue_redraw()


func _browse() -> void:
	for side in 2:
		_side_input(side)
	if state != "browse":
		click_pending = false
		right_pending = false
		wheel_steps = [0, 0]
		return
	var ready_both: bool = sides[0]["ready"] and sides[1]["ready"]
	if ready_both:
		_enter_choice()
	click_pending = false
	right_pending = false


func _side_input(side: int) -> void:
	var keys: Dictionary = KEYS[side]
	var s: Dictionary = sides[side]
	var rows: Array = s["rows"]
	var other: Dictionary = sides[1 - side]
	var click_row := -1
	var on_column: bool = click_at.x >= COLUMN_X[side] and click_at.x < COLUMN_X[side] + 160
	if click_pending and on_column and click_at.y >= ROW_TOP and click_at.y < ROW_TOP + VISIBLE * ROW_STEP:
		click_row = int((click_at.y - ROW_TOP) / ROW_STEP)
	var right_here: bool = right_pending and right_at.x >= COLUMN_X[side] and right_at.x < COLUMN_X[side] + 160
	var moved := false
	if s["ready"]:
		# settled: the cards are fixed; only Cross/Circle's take back answers (the cancel un-settles)
		wheel_steps[side] = 0
		if _edge("cancel%d" % side, keys["cancel"]) or right_here:
			sound.emit(8)
			s["ready"] = false
			_refresh_status()
		return
	if _fires("up%d" % side, keys["up"]) and rows.size() > 0 and int(s["cursor"]) > 0:
		s["cursor"] = int(s["cursor"]) - 1
		moved = true
	if _fires("down%d" % side, keys["down"]) and int(s["cursor"]) < rows.size() - 1:
		s["cursor"] = int(s["cursor"]) + 1
		moved = true
	# a page is VISIBLE rows: the list and the cursor move together (the trade's held Left or Right on the pad moves seven rows)
	if _fires("page_up%d" % side, keys["page_up"]) and rows.size() > 0 and int(s["cursor"]) > 0:
		s["cursor"] = maxi(int(s["cursor"]) - VISIBLE, 0)
		s["top"] = maxi(int(s["top"]) - VISIBLE, 0)
		moved = true
	if _fires("page_down%d" % side, keys["page_down"]) and int(s["cursor"]) < rows.size() - 1:
		s["cursor"] = mini(int(s["cursor"]) + VISIBLE, rows.size() - 1)
		s["top"] = mini(int(s["top"]) + VISIBLE, maxi(rows.size() - VISIBLE, 0))
		moved = true
	var wheel: int = wheel_steps[side]
	if wheel != 0:
		wheel_steps[side] = wheel - signi(wheel)
		if wheel < 0 and rows.size() > 0 and int(s["cursor"]) > 0:
			s["cursor"] = int(s["cursor"]) - 1
			moved = true
		elif wheel > 0 and int(s["cursor"]) < rows.size() - 1:
			s["cursor"] = int(s["cursor"]) + 1
			moved = true
	if click_row >= 0 and int(s["top"]) + click_row < rows.size():
		s["cursor"] = int(s["top"]) + click_row
		moved = true
	if moved:
		sound.emit(6)
		_rebuild(side)
	var add := _edge("add%d" % side, keys["add"]) or (click_row >= 0 and click_pending)
	if add:
		_add(side)
	if _edge("cancel%d" % side, keys["cancel"]) or right_here:
		_take_back_or_leave(side)
	if _edge("ready%d" % side, keys["ready"]):
		_settle(side)


## Cross on a card: the card goes to the offer (SE 7); a full offer, an empty chest or a settled side refuses (9).
func _add(side: int) -> void:
	var s: Dictionary = sides[side]
	var rows: Array = s["rows"]
	if rows.is_empty():
		sound.emit(9)
		return
	if s["ready"] or (s["offers"] as Array).size() >= OFFER_LIMIT:
		sound.emit(9)
		return
	var id: int = rows[int(s["cursor"])]
	if _working(side, id) <= 0:
		sound.emit(9)
		return
	(s["offers"] as Array).append(id)
	sound.emit(7)
	if help_up:
		help_up = false
		_hide_frame()
		for i in 2:
			rows_node[i].visible = true
		status_node.visible = true
	_rebuild(side)


## Circle: the last offer comes back (SE 8); with nothing offered and nothing settled on either side the screen is left.
func _take_back_or_leave(side: int) -> void:
	var s: Dictionary = sides[side]
	var other: Dictionary = sides[1 - side]
	if (s["offers"] as Array).size() > 0:
		(s["offers"] as Array).pop_back()
		sound.emit(8)
		_rebuild(side)
		return
	if (other["offers"] as Array).size() > 0 or other["ready"]:
		sound.emit(9)
		return
	sound.emit(8)
	closed.emit()


## Square: the side settles (SE 48) when the other side is not waiting on an empty offer; both settled opens the choice.
func _settle(side: int) -> void:
	var other: Dictionary = sides[1 - side]
	if other["ready"] and (sides[0]["offers"] as Array).size() + (sides[1]["offers"] as Array).size() == 0:
		sound.emit(9)
		return
	sides[side]["ready"] = true
	sound.emit(48)
	_refresh_status()


func _enter_choice() -> void:
	state = "choice"
	choice = CHOICE_EXECUTE
	sound.emit(48)
	_show_choice()


## The three choices: Up and Down move through them (they wrap), Cross confirms and Circle is RE-SELECT.
func _choose() -> void:
	if _fires("modal_up", MODAL_UP) or _fires("modal_down", MODAL_DOWN):
		choice = (choice + 1) % 3 if _down(MODAL_DOWN) else (choice + 2) % 3
		sound.emit(6)
		_show_choice()
		return
	var pick := -1
	if click_pending:
		click_pending = false
		var line := int(floor((click_at.y - TEXT_ORIGIN.y) / TEXT_ADVANCE.y))
		if line >= 0 and line < CHOICE_LABELS.size():
			choice = line
			pick = line
	if _edge("modal_confirm", MODAL_CONFIRM):
		pick = choice
	if _edge("modal_cancel", MODAL_CANCEL) or right_pending:
		right_pending = false
		pick = CHOICE_RESELECT
	if pick < 0:
		return
	sound.emit(48)
	match pick:
		CHOICE_EXECUTE:
			_hide_frame()
			state = "writing"
			timer = 0
			_show_frame(text.string_bytes(STRING_WRITING))
		CHOICE_RESELECT:
			sides[0]["ready"] = false
			sides[1]["ready"] = false
			_refresh_status()
			_hide_frame()
			state = "browse"
		CHOICE_LEAVE:
			_hide_frame()
			closed.emit()


func _write_step() -> void:
	timer += 1
	if timer < WRITE_FRAMES:
		return
	if _execute():
		_show_message(STRING_COMPLETE)
	else:
		_show_message(STRING_FAILED)
	state = "message"


## The message closes with a confirm or a cancel: after TRADE COMPLETE! the screen goes on, after TRADE FAILED! the choice returns.
func _message() -> void:
	if not (_edge("modal_confirm", MODAL_CONFIRM) or _edge("modal_cancel", MODAL_CANCEL) or click_pending or right_pending):
		return
	click_pending = false
	right_pending = false
	if message_id == STRING_FAILED:
		state = "choice"
		_show_choice()
		return
	_hide_frame()
	state = "browse"


## shop's trade (the trade screen update's exchange): each offered card leaves its side's chest and joins the other chest (250 at most),
## then both saves are written. Nothing changes when a write fails.
func _execute() -> bool:
	var chest: Array = [sides[0]["chest"].duplicate(), sides[1]["chest"].duplicate()]
	for i in 2:
		for id in sides[i]["offers"]:
			var at := int(id) - 1
			if chest[i][at] != 0:
				chest[i][at] -= 1
			if chest[1 - i][at] < CHEST_LIMIT:
				chest[1 - i][at] += 1
	var owned0 := PackedInt32Array()
	owned0.resize(CARD_COUNT)
	var owned1 := PackedInt32Array()
	owned1.resize(CARD_COUNT)
	for i in CARD_COUNT:
		owned0[i] = chest[0][i] + int(sides[0]["copies"][i])
		owned1[i] = chest[1][i] + int(sides[1]["copies"][i])
	var old_slot_two := FileAccess.get_file_as_string(SLOT_TWO)
	var data = JSON.parse_string(old_slot_two)
	if typeof(data) != TYPE_DICTIONARY:
		return false
	data["counts"] = Array(owned1)
	var file := FileAccess.open(SLOT_TWO, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data))
	file.close()
	var previous := GameState.card_counts
	GameState.card_counts = owned0
	if not GameState.save_game():
		GameState.card_counts = previous
		var restore := FileAccess.open(SLOT_TWO, FileAccess.WRITE)
		if restore != null:
			restore.store_string(old_slot_two)
		return false
	for i in 2:
		sides[i]["chest"] = chest[i]
		sides[i]["owned"] = owned0 if i == 0 else owned1
		sides[i]["offers"] = []
		sides[i]["ready"] = false
		_rebuild(i)
	_refresh_status()
	return true
