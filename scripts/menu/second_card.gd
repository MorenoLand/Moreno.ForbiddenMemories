extends Control
## The SECOND MEMORY CARD panel (a port screen, shown on the sand backdrop of the 2P setup). The trade and the 2P setup read the
## second card's save file (user://save2.json, the memory card in slot 2). Without it the trade says MEMORY CARD REQUIRED (the
## original's notice, string 0xD2); this panel is what the port offers next, so the player can make the second card:
##   COPY THIS SAVE      the current save (the memory card's campaign) is written to the second card, both decks are the same
##   NEW STARTER DECK    a new card with a starter deck dealt the way a new game deals one (DuelData.deal_starter_deck)
##   LOAD A SAVE FILE    a save file picked in a file dialog (desktop only; the web build has no dialog)
##   RETURN TO TITLE     back to where it was opened from (cancelled)
## A save .json dropped on the game window is loaded the same way as LOAD A SAVE FILE (any platform the window reports drops on).
## A file is only taken when it is a save: a JSON dictionary with the card counts and the deck.
##
## Keys: Up and Down (W and S) choose, E, Enter or Space confirm, Q, Escape or Backspace go back. Mouse: a click on a row picks it,
## a right click goes back. Touch: the emulated mouse does the same.
## The panel's own strings are the port's (the original's second card screen is not ported); the notice before it is the original's.

signal finished                 # the second card is in its save file: the caller goes on to the trade or the 2P setup
signal cancelled
signal sound(effect: int)       # the SE play ids: 6 cursor, 7 confirm, 8 cancel, 9 refused

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const TextFrame := preload("res://scripts/ui/text_frame.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const DuelData := preload("res://scripts/duel/duel_data.gd")
const SLOT_TWO := "user://save2.json"
const CARD_COUNT := 722
const START_PLACE := 14                 # the map place a new game starts at (GameState.map_place)
const NEW_GAME_SCENE := 0x30            # GameState.NEW_GAME_SCENE
const PLAYER_TWO_NAME := "PLAYER"       # the second card's name: six Shift-JIS letters, shown in the trade's status line
const BACKDROP := "res://assets/screens/backdrops/"
const ROW_Y := [72, 96, 120, 144]
const ROW_X := 40
const BAR_X := 32
const BAR_WIDTH := 160                  # the bar's frame: the trade cursor's nine-slice, as wide as the labels need
const TITLE_ORIGIN := Vector2(32, 24)
const ADVANCE := Vector2(8, 12)

var text := GameText.new()
var glyph_codes: Dictionary = {}
var sharp: ShaderMaterial
var world := Node2D.new()
var labels := Node2D.new()
var cursor_node := Node2D.new()
var cursor_texture: Texture2D
var status_node := Node2D.new()
var rows: Array = []                    # the row ids shown: 0 copy, 1 new starter deck, 2 load a file (desktop only), 3 return
var choice := 0
var status := ""                        # a line the panel shows when a file is refused
var dialog: FileDialog
var ready_ok := false
var click_pending := false
var click_at := Vector2.ZERO
var right_pending := false
var held: Dictionary = {}


## The rows the panel offers: the file dialog is a desktop thing (the web build has no native file picker in this port).
static func has_file_dialog() -> bool:
	return not OS.has_feature("web")


## The second card's file as the trade and the 2P setup read it: a JSON dictionary with the card counts and the deck.
static func is_save(data: Variant) -> bool:
	return typeof(data) == TYPE_DICTIONARY and data.get("counts") is Array and data.get("deck") is Array


## A new card with a starter deck dealt the way a new game deals one (the name entry's deal): the same fields as GameState.save_game.
static func starter_card(rng: RandomNumberGenerator) -> Dictionary:
	var data := DuelData.new()
	if not data.load_all():
		return {}
	var deck: Array = data.deal_starter_deck(rng)
	# the chest: a second starter deal's cards (a new game has no chest; the trade needs cards to offer, so this is the port's choice)
	var chest: Array = data.deal_starter_deck(rng)
	var counts := PackedInt32Array()
	counts.resize(CARD_COUNT)
	for id in deck + chest:
		if int(id) >= 1 and int(id) <= CARD_COUNT:
			counts[int(id) - 1] += 1
	var name := _sjis_words(PLAYER_TWO_NAME)
	var records := PackedInt32Array()
	records.resize(GameState.DUELIST_COUNT * 2)
	var drops := PackedInt32Array()
	drops.resize(GameState.RECENT_DROP_COUNT)
	var flags := PackedByteArray()
	flags.resize(256)
	return {"name": name, "flags": Array(flags), "deck": deck, "counts": Array(counts), "place": START_PLACE, "starchips": 0,
		"wins": 0, "losses": 0, "records": Array(records), "drops": Array(drops),
		"code": GameState.roll_duelist_code(name, rng), "scene": NEW_GAME_SCENE, "credits": 0, "output": 0}


## Writes a save dictionary to the second card's file. Returns false when it cannot be written.
static func write_second_card(data: Dictionary) -> bool:
	var file := FileAccess.open(SLOT_TWO, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data))
	file.close()
	return true


## Copies a save file (picked or dropped) to the second card's file; false when it is not a save or cannot be read.
static func import_file(path: String) -> bool:
	var raw := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(raw)
	if not is_save(data):
		return false
	var file := FileAccess.open(SLOT_TWO, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(raw)
	file.close()
	return true


## The Shift-JIS words of an ASCII name (letters and digits), the way the save holds a name (high byte first).
static func _sjis_words(name: String) -> Array:
	var out: Array = []
	for c in name:
		var code := c.unicode_at(0)
		if code >= 65 and code <= 90:
			out.append(0x8260 + code - 65)
		elif code >= 48 and code <= 57:
			out.append(0x824F + code - 48)
		else:
			out.append(0)
	return out


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all():
		return
	for i in text.glyphs.size():
		var sjis := int(text.glyphs[i]["sjis"])
		if not glyph_codes.has(sjis):
			glyph_codes[sjis] = i
	sharp = ScreenFit.make_material()
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(world)
	add_to_group("fit")
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(320, 240)
	world.add_child(black)
	var sand := Sprite2D.new()
	sand.centered = false
	var sand_image := Image.load_from_file(BACKDROP + "sand.png")
	if sand_image != null:
		sand.texture = ImageTexture.create_from_image(sand_image)
	sand.material = sharp
	world.add_child(sand)
	if sand.texture != null:
		var fill := Sprite2D.new()
		fill.centered = false
		fill.texture = sand.texture
		fill.region_enabled = true
		fill.region_rect = Rect2(0, 0, sand.texture.get_width(), 240 - sand.texture.get_height())
		fill.position = Vector2(0, sand.texture.get_height())
		fill.material = sharp
		world.add_child(fill)
	var cursor_image := Image.load_from_file(BACKDROP + "trade/cursor.png")
	if cursor_image != null:
		cursor_texture = ImageTexture.create_from_image(cursor_image)
	rows = [0, 1, 2, 3] if has_file_dialog() else [0, 1, 3]
	world.add_child(labels)
	world.add_child(cursor_node)
	cursor_node.draw.connect(_draw_cursor)
	world.add_child(status_node)
	_build_labels()
	get_window().files_dropped.connect(_on_files_dropped)
	get_viewport().size_changed.connect(refit)
	refit()
	ScreenFit.pass_mouse(self)
	ready_ok = true


func _exit_tree() -> void:
	if get_window() != null and get_window().files_dropped.is_connected(_on_files_dropped):
		get_window().files_dropped.disconnect(_on_files_dropped)
	if dialog != null:
		dialog.queue_free()


func refit() -> void:
	ScreenFit.apply(world, size)


## The font's glyph codes for an ASCII string (the trade's mapping; anything else is a blank).
func _bytes(string: String) -> Array:
	var out: Array = []
	for c in string:
		var code := c.unicode_at(0)
		var sjis := 0
		if c == " ":
			out.append(0)
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


func _build_labels() -> void:
	for child in labels.get_children():
		labels.remove_child(child)
		child.queue_free()
	text.layout(labels, _bytes("SECOND MEMORY CARD"), TITLE_ORIGIN, ADVANCE, 0, sharp, true)
	text.layout(labels, _bytes("PLAYER 2 NEEDS A SECOND CARD"), TITLE_ORIGIN + Vector2(0, 20), ADVANCE, 0, sharp, true)
	var names := {0: "COPY THIS SAVE", 1: "NEW STARTER DECK", 2: "LOAD A SAVE FILE", 3: "RETURN TO TITLE"}
	for i in rows.size():
		text.layout(labels, _bytes(names[rows[i]]), Vector2(ROW_X, ROW_Y[i] + 3), ADVANCE, 0, sharp, true)
	text.layout(labels, _bytes("OR DROP A SAVE .JSON ON THE WINDOW"), Vector2(32, 176), ADVANCE, 0, sharp, true)
	text.layout(labels, _bytes("UP DOWN CHOOSE  E OK  Q BACK"), Vector2(32, 212), ADVANCE, 0, sharp, true)
	_refresh_status()
	cursor_node.queue_redraw()


func _refresh_status() -> void:
	for child in status_node.get_children():
		status_node.remove_child(child)
		child.queue_free()
	if status != "":
		text.layout(status_node, _bytes(status), Vector2(32, 194), ADVANCE, 0, sharp, true)


## The chosen row's bar: the red and gold bar of the trade screen's cursor (128 x 18), behind the row's text.
func _draw_cursor() -> void:
	if cursor_texture == null:
		return
	TextFrame.draw(cursor_node, cursor_texture, Rect2(0, 0, 128, 18), Rect2(BAR_X, ROW_Y[choice] - 3, BAR_WIDTH, 22),
			Vector4(7, 4, 7, 4), false)


func _choose(index: int) -> void:
	choice = clampi(index, 0, rows.size() - 1)
	cursor_node.queue_redraw()


func _activate() -> void:
	match rows[choice]:
		0:
			if not GameState.has_campaign():
				sound.emit(9)
				status = "NO CAMPAIGN TO COPY"
				_refresh_status()
				return
			if GameState.save_to(SLOT_TWO):
				sound.emit(7)
				finished.emit()
			else:
				sound.emit(9)
				status = "COULD NOT WRITE THE CARD"
				_refresh_status()
		1:
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			var data := starter_card(rng)
			if not data.is_empty() and write_second_card(data):
				sound.emit(7)
				finished.emit()
			else:
				sound.emit(9)
		2:
			_open_file_dialog()
		3:
			sound.emit(8)
			cancelled.emit()


func _open_file_dialog() -> void:
	if dialog != null:
		return
	dialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	dialog.filters = PackedStringArray(["*.json ; Save data"])
	dialog.title = "Choose a save file"
	dialog.file_selected.connect(_on_file_picked)
	dialog.canceled.connect(_close_dialog)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


func _close_dialog() -> void:
	if dialog != null:
		dialog.queue_free()
		dialog = null


func _on_file_picked(path: String) -> void:
	_close_dialog()
	_take_file(path)


func _on_files_dropped(files: PackedStringArray) -> void:
	if not ready_ok:
		return
	for path in files:
		if path.get_extension().to_lower() == "json":
			_take_file(path)
			return
	status = "NOT A SAVE FILE"
	_refresh_status()
	sound.emit(9)


func _take_file(path: String) -> void:
	if import_file(path):
		sound.emit(7)
		finished.emit()
	else:
		status = "NOT A SAVE FILE"
		_refresh_status()
		sound.emit(9)


func _held(key: String, keys: Array) -> bool:
	var down := false
	for k in keys:
		if Input.is_key_pressed(k):
			down = true
	var was: bool = held.get(key, false)
	held[key] = down
	return down and not was


func _gui_input(event: InputEvent) -> void:
	if not ready_ok or not (event is InputEventMouseButton and event.pressed):
		return
	var local: Vector2 = (event.position - world.position) / world.scale
	if event.button_index == MOUSE_BUTTON_LEFT:
		click_at = local
		click_pending = true
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		right_pending = true


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible or dialog != null:
		return
	if right_pending or _held("cancel", [KEY_Q, KEY_ESCAPE, KEY_BACKSPACE]):
		right_pending = false
		click_pending = false
		sound.emit(8)
		cancelled.emit()
		return
	if _held("up", [KEY_UP, KEY_W]):
		_choose(choice - 1)
		sound.emit(6)
	if _held("down", [KEY_DOWN, KEY_S]):
		_choose(choice + 1)
		sound.emit(6)
	if click_pending:
		click_pending = false
		for i in rows.size():
			if click_at.y >= ROW_Y[i] - 2 and click_at.y < ROW_Y[i] + 16 and click_at.x >= BAR_X and click_at.x < BAR_X + BAR_WIDTH:
				_choose(i)
				_activate()
				return
	if _held("ok", [KEY_E, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]):
		_activate()
