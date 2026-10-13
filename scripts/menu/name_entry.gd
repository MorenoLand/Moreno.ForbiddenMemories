extends Control
## The New Game name entry screen: a native port of the password module's the name entry setup, the name entry keyboard update,
## the name length adjustment, the name entry selection frame drawing and the name entry dialog update. Steps at the game's 60 Hz.
## The keyboard, the right-hand arrows/END and the name field are drawn with the game's own font; typing on a PC keyboard or
## clicking a cell takes the same path as pressing Cross on it.
##
## flags: the data at 0x8016D400 bit 0x04 dialog open, 0x02 dialog sliding, 0x20 accepted, 0x10 completed, 0x40 finish requested.

signal completed(name_codes: Array)   # the six Shift-JIS words of the name (0 for blank), after the YES
signal sound(effect: int)
signal cancelled                      # Esc: back to the menu (the console has no way out; Circle is Backspace here, as there)

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const DIR := "res://assets/screens/name_entry/"
const NAME_ORIGIN := Vector2(112, 204)
const CARET_X := 107
const CARET_Y := 199
const SLOTS := 6
const DIALOG_NEW := 244
const DIALOG_CONFIRM := 245

var text := GameText.new()
var cells: Array = []
var links: Array = []
var world := Node2D.new()
var sharp: ShaderMaterial
var frame_node := Node2D.new()
var caret_sprite := Sprite2D.new()
var panel := Sprite2D.new()
var keyboard: Array = []            # glyph entries of box 1
var side: Array = []                # glyph entries of box 0
var name_nodes: Array = []          # sprites of the name field
var dialog_holder: Node2D
var choice_bar: Polygon2D
var arrow: Sprite2D
var arrow_tick := 0
var arrow_layout: Dictionary = {}
var arrow_textures: Array = []
var shade := ColorRect.new()
var field_layer := Node2D.new()   # the name field and the typed glyph in flight: under the dialog's panel

var col := 0
var row := 0
var saved_row := 0
var caret := 0
var name_codes: Array = []          # glyph codes, 0 = blank
var frame_x := 22.0
var frame_y := 24.0
var frame_w := 16.0
var bonus := 0
var target := Vector2(22, 24)
var step := Vector2.ZERO
var timer := 0
var held: Dictionary = {}
var busy := 0                       # frames left of the pulse / transfer sprites (they block the keyboard)
var pending_slot := -1              # a typed glyph in flight: slot it lands in, frames left
var flight_left := 0
var flight_sprite: Sprite2D
var flight_from := Vector2.ZERO
var flight_to := Vector2.ZERO
var pulses: Array = []              # [sprite, frame]
var caret_from := 0.0
var caret_tween := 0
var finish_requested := false
var dialog_id := DIALOG_NEW
var dialog_open := false
var dialog_slide := 0
var dialog_choice := 0
var dialog_done := false
var fade_out := -1
var ready_ok := false
var click_cell := Vector2i(-1, -1)
var typed_queue: Array = []
var pending_click_confirm := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # clicks reach _unhandled_input (a stopping Control would consume them)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all():
		return
	var json = JSON.parse_string(FileAccess.get_file_as_string(DIR + "keyboard.json")) if FileAccess.file_exists(DIR + "keyboard.json") else null
	if typeof(json) != TYPE_DICTIONARY:
		return
	cells = json["cells"]
	links = json["links"]
	sharp = ScreenFit.make_material()
	add_child(world)
	add_to_group("fit")
	get_viewport().size_changed.connect(refit)
	var backdrop := Sprite2D.new()
	backdrop.centered = false
	backdrop.texture = _texture("backdrop.png")
	backdrop.modulate = Color(0.5, 0.5, 0.5)   # COLOR_RGB24_DIM_GREY: 0x40 of the neutral 0x80
	backdrop.material = sharp
	world.add_child(backdrop)
	keyboard = text.layout(world, text.string_bytes(242), Vector2(22, 24), Vector2(20, 18), 0, sharp)
	side = text.layout(world, text.string_bytes(243), Vector2(262, 60), Vector2(20, 18), 0, sharp)
	name_codes = [0, 0, 0, 0, 0, 0]
	_rebuild_name()
	world.add_child(field_layer)
	caret_sprite.centered = false
	caret_sprite.texture = _texture("caret.png")
	caret_sprite.material = sharp
	caret_sprite.modulate = Color(1, 1, 1, 0.5)   # GsALON: averaged with what is behind
	caret_sprite.position = Vector2(CARET_X, CARET_Y)
	world.add_child(caret_sprite)
	frame_node.set_script(preload("res://scripts/menu/name_entry_frame.gd"))
	world.add_child(frame_node)
	var arrow_json = JSON.parse_string(FileAccess.get_file_as_string("res://assets/screens/dialog_arrow/layout.json"))
	if typeof(arrow_json) == TYPE_DICTIONARY:
		arrow_layout = arrow_json
		for i in (arrow_json["frames"] as Array).size():
			var image := Image.load_from_file("res://assets/screens/dialog_arrow/%d.png" % i)
			arrow_textures.append(ImageTexture.create_from_image(image))
	panel.centered = false
	panel.texture = _texture("dialog_panel.png")
	panel.material = sharp
	panel.visible = false
	world.add_child(panel)
	shade.size = Vector2(320, 240)
	shade.color = Color(0, 0, 0, 0)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world.add_child(shade)

	ScreenFit.pass_mouse(self)
	ready_ok = true
	refit()
	_update_frame()


func _texture(file: String) -> Texture2D:
	return ModArt.texture(DIR + file)


func refit() -> void:
	ScreenFit.apply(world, size)


func _rebuild_name() -> void:
	for node in name_nodes:
		node.queue_free()
	name_nodes.clear()
	for i in SLOTS:
		if int(name_codes[i]) != 0:
			var sprite := text.sprite_for(int(name_codes[i]), 0, sharp)
			sprite.position = NAME_ORIGIN + Vector2(16 * i + int(text.glyphs[int(name_codes[i])]["shift"]), 0)
			field_layer.add_child(sprite)
			name_nodes.append(sprite)


func _update_frame() -> void:
	frame_node.set("rect", Rect2(frame_x, frame_y, frame_w, 16))
	frame_node.queue_redraw()


## the name length adjustment.
func _adjust(delta: int) -> bool:
	if delta < 0 and caret == 0:
		return false
	if delta > 0 and caret == SLOTS - 1:
		return false
	caret += delta
	caret_from = caret_sprite.position.x
	caret_tween = 6
	sound.emit(12)
	return true


func _code_at(c: int, r: int) -> int:
	return int(cells[r][c]) & 0xF if c >= 0 and c < 15 and r >= 0 and r < 9 else 0


## The keyboard glyph at a local position of box 1, or {} when the cell is empty.
func _glyph_at(box: Array, local_x: int, local_y: int) -> Dictionary:
	for entry in box:
		if int(entry["x"]) == local_x and int(entry["y"]) == local_y and int(entry["code"]) != 0:
			return entry
	return {}


## The cursor moves to column c / row r exactly as the update's tail does (walk the table, restore the row, bonus width).
func _land(c: int, r: int) -> void:
	var work: int = int(cells[r][c])
	var walk := c
	while work < 0:
		walk += work
		work = int(cells[r][walk])
	col = walk
	row = saved_row
	bonus = 0
	if work != 0:
		if (work & 0x40) != 0:
			bonus = 20
		row = work & 0xF
	target = Vector2(col * 20 + (42 if col >= 11 else 22), row * 18 + 24)
	step = Vector2((target.x - frame_x) * 256.0 / 8.0, (target.y - frame_y) * 256.0 / 8.0)
	timer = 8
	sound.emit(47)


func _held(key: String) -> bool:
	return bool(held.get(key, false))


func _poll_input() -> Dictionary:
	var down := {
		"up": Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP),
		"down": Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN),
		"left": Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT),
		"right": Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT),
		"confirm": Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_A),
		"cancel": Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_BACKSPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_B),
		"start": Input.is_key_pressed(KEY_ENTER) or Input.is_key_pressed(KEY_KP_ENTER) or Input.is_joy_button_pressed(0, JOY_BUTTON_START),
	}
	var pressed := {}
	var repeat := {}
	for key in down:
		var timer_value: int = int(held.get("t_" + key, -1))
		if down[key]:
			if timer_value < 0:
				pressed[key] = true
				repeat[key] = true
				timer_value = 0
			else:
				timer_value += 1
				if timer_value >= 0x18:
					repeat[key] = true
					timer_value = 0x14
			held["t_" + key] = timer_value
		else:
			held["t_" + key] = -1
		held[key] = bool(down[key])
	return {"pressed": pressed, "repeat": repeat}


func _unhandled_input(event: InputEvent) -> void:
	if not ready_ok:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		cancelled.emit()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.unicode >= 32 and event.unicode < 127:
		typed_queue.append(char(event.unicode))
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var local: Vector2 = (event.position - world.position) / world.scale
		if dialog_open and dialog_id == DIALOG_CONFIRM and dialog_slide == 0:
			# a click on the YES / NO line chooses it
			var line := int(floor((local.y - 176.0) / 12.0)) - 1
			if line == 0 or line == 1:
				dialog_choice = line
				pending_click_confirm = true
			return
		click_cell = _cell_at(local)
		if click_cell == Vector2i(-1, -1):
			typed_queue.append("\n")


func _cell_at(point: Vector2) -> Vector2i:
	var r := int(floor((point.y - 22.0) / 18.0))
	var c := int(floor((point.x - 22.0) / 20.0))
	if point.x >= 252.0:
		c = int(floor((point.x - 42.0) / 20.0))
	if r < 0 or r > 8 or c < 0 or c > 14:
		return Vector2i(-1, -1)
	var work: int = int(cells[r][c])
	if c <= 10:
		var line: Array = _row_glyphs(r)
		return Vector2i(c, r) if c < line.size() else Vector2i(-1, -1)
	return Vector2i(c, r) if work != 0 else Vector2i(-1, -1)


func _row_glyphs(r: int) -> Array:
	var out: Array = []
	for entry in keyboard:
		if int(entry["y"]) == 24 + r * 18:
			out.append(entry)
	return out


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible:
		return
	var input := _poll_input()
	_step_effects()
	if fade_out >= 0:
		fade_out += 1
		shade.color = Color(0, 0, 0, clampf(fade_out / 16.0, 0.0, 1.0))
		if fade_out >= 16:
			set_physics_process(false)
			var words: Array = []
			for code in name_codes:
				words.append(text.sjis_of(int(code)))
			completed.emit(words)
		return
	if dialog_open:
		_update_dialog(input)
		return
	if dialog_id != 0:
		_open_dialog()
		return
	if busy > 0 or finish_requested:
		return
	_update_keyboard(input)


## the name entry keyboard update.
func _update_keyboard(input: Dictionary) -> void:
	var pressed: Dictionary = input["pressed"]
	var repeat: Dictionary = input["repeat"]
	if timer > 0:
		var home := frame_w - 16.0
		var work := bonus - home
		if work != 0.0:
			frame_w += 2.0 if work >= 0.0 else -2.0
		frame_x += step.x / 256.0
		frame_y += step.y / 256.0
		timer -= 1
		_update_frame()
		if timer != 0:
			return
		frame_w = bonus + 16.0
		frame_x = target.x
		frame_y = target.y
		_update_frame()
	var moved := false
	if _held("right") or _held("left") or _held("up") or _held("down"):
		if _held("right"):
			col = (col + 1) % 15
		if _held("left"):
			col = 14 if col == 0 else col - 1
		if _held("up") or _held("down"):
			if col >= 11:
				col = 11
				row = int(links[row][1 if _held("down") else 0])
				saved_row = row
			elif _held("up"):
				row = 8 if row == 0 else row - 1
				saved_row = row
			else:
				row = (row + 1) % 9
				saved_row = row
		_land(col, row)
		return
	if pressed.has("start"):
		# the console's Start jumps the cursor to END; on a PC keyboard Enter (and a pad's Start) then finishes, as typing a name
		# and pressing Enter does everywhere else
		col = 14
		row = 8
		_land(col, row)
		col = 11
		row = 6
		if _code_at(col, row) == 6:
			_confirm()
		return
	if click_cell != Vector2i(-1, -1):
		# a click goes straight to the cell and takes it, as Cross on it would
		col = click_cell.x
		row = click_cell.y
		saved_row = row
		click_cell = Vector2i(-1, -1)
		_land(col, row)
		_confirm()
		return
	if not typed_queue.is_empty():
		var typed: String = typed_queue.pop_front()
		if typed == "\n":
			_confirm()
		else:
			_type(typed)
		return
	if repeat.has("confirm"):
		_confirm()
	elif repeat.has("cancel"):
		sound.emit(12 if _adjust(-1) else 9)


## Typing a letter on a PC keyboard: the cell holding that letter is taken.
func _type(letter: String) -> void:
	var sjis := 0
	var ascii := letter.unicode_at(0)
	if ascii >= 48 and ascii <= 57:
		sjis = 0x824F + (ascii - 48)
	elif ascii >= 65 and ascii <= 90:
		sjis = 0x8260 + (ascii - 65)
	elif ascii >= 97 and ascii <= 122:
		sjis = 0x8281 + (ascii - 97)
	var code := text.code_for_sjis(sjis)
	if code == 0:
		return
	for entry in keyboard:
		if int(entry["code"]) == code:
			col = int((float(entry["x"]) - 22.0) / 20.0)
			row = int((float(entry["y"]) - 24.0) / 18.0)
			saved_row = row
			_land(col, row)
			_confirm()
			return


## Cross on the cell under the cursor.
func _confirm() -> void:
	var code := _code_at(col, row)
	var gx := 0
	var gy := 0
	var kind := 0
	if code == 4:
		var d := 1
		if col == 11:
			d = -1
			gx = 0
		else:
			gx = 20
		if not _adjust(d):
			sound.emit(9)
		gy = 36
		_pulse(side, gx, gy)
		return
	if code == 6:
		finish_requested = true
		_pulse(side, 0, 72)
		_pulse(side, 20, 72)
		busy = 12
		_begin_finish()
		return
	kind = 1
	gx = col * 20
	gy = row * 18
	sound.emit(41)
	var entry := _glyph_at(keyboard, 22 + gx, 24 + gy)
	_pulse(keyboard, gx, gy, true)
	name_codes[caret] = int(entry["code"]) if not entry.is_empty() else 0
	pending_slot = caret
	flight_left = 8
	flight_from = Vector2(22 + gx, 24 + gy)
	flight_to = NAME_ORIGIN + Vector2(16 * caret, 0)
	flight_sprite = null
	if not entry.is_empty():
		flight_sprite = text.sprite_for(int(entry["code"]), 0, sharp)
		flight_sprite.position = flight_from
		field_layer.add_child(flight_sprite)
	busy = 12


func _pulse(box: Array, local_x: int, local_y: int, keyboard_box := false) -> void:
	var ox := 22 if keyboard_box else 262
	var oy := 24 if keyboard_box else 60
	var entry := _glyph_at(box, ox + local_x, oy + local_y)
	if entry.is_empty():
		return
	var sprite := text.sprite_for(int(entry["code"]), 0 if keyboard_box else 5, sharp)
	sprite.position = Vector2(ox + local_x, oy + local_y) + Vector2(8, 8)
	sprite.offset = Vector2(-8, -8)
	world.add_child(sprite)
	pulses.append([sprite, 0])


func _step_effects() -> void:
	for item in pulses.duplicate():
		item[1] += 1
		var f: int = item[1]
		var s: int = f if f < 6 else 11 - f
		var scale_value := (4096.0 - s * 341.0) / 4096.0
		item[0].scale = Vector2(scale_value, scale_value)
		if f >= 12:
			item[0].queue_free()
			pulses.erase(item)
	if busy > 0:
		busy -= 1
	if flight_left > 0:
		flight_left -= 1
		if flight_sprite != null:
			flight_sprite.position = flight_from.lerp(flight_to, 1.0 - flight_left / 8.0)
		if flight_left == 0:
			if flight_sprite != null:
				flight_sprite.queue_free()
				flight_sprite = null
			_rebuild_name()
			_adjust(1)
			pending_slot = -1
	if caret_tween > 0:
		caret_tween -= 1
		var goal := float(CARET_X + 16 * caret)
		caret_sprite.position.x = lerpf(caret_from, goal, 1.0 - caret_tween / 6.0)


## The 0x40 branch: with a name present the prompt "Your NAME is ..." opens, with none the refusal sound plays.
func _begin_finish() -> void:
	var any := false
	for code in name_codes:
		if int(code) != 0:
			any = true
	finish_requested = false
	if any:
		sound.emit(48)
		dialog_id = DIALOG_CONFIRM
		dialog_choice = 0
	else:
		sound.emit(9)


func _open_dialog() -> void:
	dialog_open = true
	dialog_slide = -1024
	panel.visible = true
	panel.position = Vector2(0, 72)
	_build_dialog()
	dialog_holder.position.y = 72.0


func _clear_dialog_text() -> void:
	if dialog_holder != null:
		dialog_holder.queue_free()
		dialog_holder = null
	choice_bar = null
	arrow = null


func _dialog_bytes() -> Array:
	return text.string_bytes(dialog_id)


## TextBox 2 at (16, 176) with its text, the choice bar (YES/NO) or, for the plain prompt, the blinking arrow that
## the choice box opening puts in the corner (box x + width - 16, y + height - 16). Every glyph comes in with the text box's effect, one
## glyph every field_53 = 2 frames. The holder moves with the sliding panel.
func _build_dialog() -> void:
	_clear_dialog_text()
	dialog_holder = Node2D.new()
	world.add_child(dialog_holder)
	var y := 176.0
	if dialog_id == DIALOG_CONFIRM:
		choice_bar = Polygon2D.new()
		var edge := Color(0.19, 0.19, 0.0)
		var mid := Color(0.75, 0.75, 0.0)
		var top := y - 2.0 + 12.0   # field_18 = 2 rows: the bar sits 2 above the line; line 0 is the question
		choice_bar.polygon = PackedVector2Array([Vector2(16, top), Vector2(160, top), Vector2(304, top), Vector2(304, top + 8), Vector2(160, top + 8), Vector2(16, top + 8)])
		choice_bar.vertex_colors = PackedColorArray([edge, mid, edge, edge, mid, edge])
		var add := CanvasItemMaterial.new()
		add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		choice_bar.material = add
		dialog_holder.add_child(choice_bar)
	var name_stream: Array = []
	for code in name_codes:
		name_stream.append(int(code))
	name_stream.append(0xFF)
	var placed := text.layout(dialog_holder, _dialog_bytes(), Vector2(16, y - 4), Vector2(8, 12), 0, sharp, true, {0x125A: name_stream})   # the small class (game_text.gd) adds 2 rows
	var index := 0
	for entry in placed:
		if entry["sprite"] != null:
			var fx := Polygon2D.new()
			fx.set_script(preload("res://scripts/ui/glyph_fx.gd"))
			fx.sprite = entry["sprite"]
			fx.delay = index * 2
			fx.small = true
			dialog_holder.add_child(fx)
		index += 1
	if dialog_id != DIALOG_CONFIRM:
		arrow = Sprite2D.new()
		arrow.centered = false
		arrow.material = sharp
		dialog_holder.add_child(arrow)
		arrow_tick = 0
		_update_arrow()


func _update_arrow() -> void:
	if arrow == null:
		return
	var sequence: Array = arrow_layout["sequence"]
	var step := int(arrow_tick / int(arrow_layout["duration"])) % sequence.size()
	var frame: int = int(sequence[step])
	arrow.texture = arrow_textures[frame]
	var o: Dictionary = arrow_layout["frames"][frame]
	arrow.position = Vector2(16 + 288 - 16 + int(o["x"]), 176 + 48 - 16 + int(o["y"]))


func _update_dialog(input: Dictionary) -> void:
	var pressed: Dictionary = input["pressed"]
	arrow_tick += 1
	_update_arrow()
	if dialog_slide != 0 and (dialog_slide < 0 or dialog_done):
		if dialog_slide < 0:
			dialog_slide += 85
			var t := clampf(-float(dialog_slide) / 1024.0, 0.0, 1.0)
			panel.position.y = 72.0 * sin(t * PI / 2.0)
			if dialog_slide >= 0:
				dialog_slide = 0
				panel.position.y = 0.0
		else:
			dialog_slide -= 85
			var u := clampf(float(dialog_slide) / 1024.0, 0.0, 1.0)
			panel.position.y = 72.0 - 72.0 * sin(u * PI / 2.0)
			if dialog_slide < 0:
				_close_dialog()
				return
		if dialog_holder != null:
			dialog_holder.position.y = panel.position.y
		return
	if dialog_id == DIALOG_CONFIRM:
		if pressed.has("up") or pressed.has("down"):
			dialog_choice = 1 - dialog_choice
			sound.emit(6)
			if choice_bar != null:
				choice_bar.position.y = 12.0 * dialog_choice
		if pressed.has("confirm") or pressed.has("start") or pending_click_confirm:
			pending_click_confirm = false
			if dialog_choice == 0:
				_accept()
			else:
				_dismiss()
		elif pressed.has("cancel"):
			dialog_choice = 1
			_dismiss()
		return
	if pressed.has("confirm") or pressed.has("cancel") or pressed.has("start") or not typed_queue.is_empty() or click_cell != Vector2i(-1, -1):
		# a button press that closes the prompt is consumed; a typed letter closes it too and is then entered as the name's first letter
		if pressed.has("confirm") or pressed.has("cancel") or pressed.has("start"):
			typed_queue.clear()
		click_cell = Vector2i(-1, -1)
		_dismiss()


func _dismiss() -> void:
	dialog_done = true
	dialog_slide = 1024


func _accept() -> void:
	sound.emit(45)
	fade_out = 0
	dialog_open = false
	_clear_dialog_text()
	panel.visible = false


func _close_dialog() -> void:
	dialog_open = false
	dialog_done = false
	dialog_id = 0
	panel.visible = false
	_clear_dialog_text()
