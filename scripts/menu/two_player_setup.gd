extends Control
## The 2P DUEL rules setup (the value setup of the 2P duel). The frame is baked whole by
## tools/extract.py (rules/static.png: the sand, the stone plate with its title, the legend, the labels, the value boxes, the
## bars' tick rows and the footer with its two button pictures). What moves is drawn over it, as the screen's own objects do:
## each player's bar (red for player 1, blue for player 2, 0 to the life points, dithered gouraud from 64 to 255), its life point
## digits (page 11 cells, right-aligned at x 158), the star that marks the bar's end, and the legend's star that marks the
## choice between DECK NUMBER (x 116) and OPEN CARD (x 220).
##
## Each row has its own mode, as the game has: 2 is the row's life points (its star sits at the bar's end), 0 or 1 is the
## legend (the star is on the legend's choice). In the legend a row's left or right picks the choice for both rows; in the
## life points left and right step the row's value (left takes 500 off while the total stays positive, otherwise 1; right goes
## from 1 to 500, then adds 500 up to 8000); up and down move the row's star between the two places. The game takes these
## from two pads: player 1 (arrows, WASD, the first gamepad) drives row 1, player 2 (I, J, K, L, the second gamepad) row 2.
## Enter, E or Space (the START button) starts the duel with START_LIFE set in both rows when no star is moving and no value is
## still counting up; Q, Escape or Backspace (the circle button) returns to the menu with cancelled(). Mouse and touch: click a
## row's value to move its star there and click the bar to set the value; click the legend to pick the choice; click the
## footer's lines for START DUEL and RETURN TO TITLE. The wheel moves the row under the pointer (up, down) or its value (left,
## right).
##
## Approximations: the second player's deck is the second memory card's (user://save2.json, see second_player_deck). The
## game's choice also sets the card view byte of the save (the shared option, default 1); it is not written here.
## The value stars' sparkle is drawn as one frame.

signal started(life_points: Array)
signal cancelled
signal sound(effect: int)     # the SE play ids: 6 the values and choices move, 7 start, 8 cancel
signal music(id: int)           # the BGM play this screen starts when it opens (the driver's BGM play)

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const SLOT_TWO := "user://save2.json"
const PICTURES := "res://assets/screens/rules/"
const START_LIFE := 8000          # DUEL_STARTING_LIFE_POINTS (the top of the setup)
const STEP := 500                 # DUEL_LIFE_POINT_SELECTION_STEP
const BAR_X := 176                # the bars start here and span 128 pixels for the whole life point range
const BAR_SPAN := 128
const BAR_Y := [107, 135]         # the bars' top rows (eight rows each)
const DIGIT_RIGHT := 158          # the least significant digit's cell (the cells go left by 8)
const DIGIT_Y := [106, 134]
const STAR_Y := [111, 139]        # the value star's centre row
const MARK_Y := 74                # the legend star's centre row
const MARK_X := [116, 220]        # the legend choice: DECK NUMBER, OPEN CARD
const TWEEN_FRAMES := 10
const REPEAT_DELAY := 24
const REPEAT_RATE := 6
const FOOTER_START := Rect2(40, 178, 240, 18)   # START DUEL (the footer's first line)
const FOOTER_RETURN := Rect2(40, 196, 240, 18)  # RETURN TO TITLE (the second line)
const LEGEND_ROW := Rect2(20, 60, 280, 24)
const ROW_HIT := [Rect2(100, 100, 220, 22), Rect2(100, 128, 220, 22)]
const DITHER := [[-4, 0, -3, 1], [2, -2, 3, -1], [-3, 1, -4, 0], [3, -1, 2, -2]]   # the PS1 dither matrix [y & 3][x & 3]
const KEYS := [
	{"left": [KEY_A, KEY_LEFT], "right": [KEY_D, KEY_RIGHT], "up": [KEY_W, KEY_UP], "down": [KEY_S, KEY_DOWN], "pad": 0},
	{"left": [KEY_J], "right": [KEY_L], "up": [KEY_I], "down": [KEY_K], "pad": 1},
]
const CONFIRM_KEYS := [KEY_E, KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]
const CANCEL_KEYS := [KEY_Q, KEY_ESCAPE, KEY_BACKSPACE]

var world := Node2D.new()
var picture := Node2D.new()
var sharp: ShaderMaterial
var life: Array = [START_LIFE, START_LIFE]     # the values the rows are set to
var shown: Array = [START_LIFE, START_LIFE]    # the values the bars and digits show, moved toward the set values
var mode: Array = [2, 2]                       # 2: the row's life points; 0 or 1: the legend, with that choice
var choice := 0                                # the legend's choice (0 DECK NUMBER, 1 OPEN CARD)
var star_frames: Array = [0, 0]                # the frames left in a row star's move (0: none)
var star_from: Array = [Vector2.ZERO, Vector2.ZERO]
var star_to_mode: Array = [2, 2]
var star_at: Array = [Vector2.ZERO, Vector2.ZERO]
var repeat: Dictionary = {}
var held: Dictionary = {}
var pending: Array = []                        # one-shot actions from the wheel and the clicks: [action, row]
var click_pending := false
var click_at := Vector2.ZERO
var cancel_click := false
var ready_ok := false
var textures: Dictionary = {}
var bar_cache: Array = [null, null]
var bar_cache_width: Array = [-1, -1]


## The second player's deck: the second memory card's deck when the save file for it has one, otherwise the player's own deck.
static func second_player_deck() -> Array:
	if FileAccess.file_exists(SLOT_TWO):
		var data = JSON.parse_string(FileAccess.get_file_as_string(SLOT_TWO))
		if typeof(data) == TYPE_DICTIONARY and not (data.get("deck", []) as Array).is_empty():
			return (data["deck"] as Array).duplicate()
	return GameState.deck.duplicate()


func _ready() -> void:
	music.emit(29376)   # the BGM play in this screen's open routine
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sharp = ScreenFit.make_material()
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(world)
	add_to_group("fit")
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(320, 240)
	world.add_child(black)
	picture.material = sharp
	picture.draw.connect(_draw_picture)
	world.add_child(picture)
	get_viewport().size_changed.connect(refit)
	refit()
	ScreenFit.pass_mouse(self)
	ready_ok = true
	picture.queue_redraw()


func refit() -> void:
	ScreenFit.apply(world, size)


func _texture(name: String) -> Texture2D:
	if not textures.has(name):
		var image := Image.load_from_file(PICTURES + name + ".png")
		textures[name] = ImageTexture.create_from_image(image) if image != null else null
	return textures[name]


## The value of a row's star position: where the star is drawn (its centre), set by its move, its mode or the legend's choice.
func _star_centre(row: int) -> Vector2:
	if star_frames[row] > 0:
		return star_at[row]
	if mode[row] == 2:
		return _value_star(row)
	return _mark_centre()


func _value_star(row: int) -> Vector2:
	return Vector2(shown[row] * BAR_SPAN / START_LIFE + BAR_X, STAR_Y[row])


func _mark_centre() -> Vector2:
	return Vector2(MARK_X[choice], MARK_Y)


func _draw_picture() -> void:
	var frame := _texture("static")
	if frame != null:
		picture.draw_texture(frame, Vector2.ZERO)
	for row in 2:
		var width := _bar_width(row)
		if width > 0:
			picture.draw_texture(_bar_texture(row, width), Vector2(BAR_X, BAR_Y[row]))
	for row in 2:
		var value := str(shown[row])
		for k in value.length():
			var digit := value.unicode_at(value.length() - 1 - k) - 48
			var digit_texture := _texture("digit_%d" % digit)
			if digit_texture != null:
				picture.draw_texture(digit_texture, Vector2(DIGIT_RIGHT - 8 * k, DIGIT_Y[row]))
	# the stars: the row stars (value stars of the rows in their life points or moving) and the legend's star
	for row in 2:
		if star_frames[row] > 0 or mode[row] == 2:
			_draw_star(_star_centre(row))
	_draw_star(_mark_centre())


func _draw_star(at: Vector2) -> void:
	var centre := at.round()
	var large := _texture("star_large")
	var small := _texture("star_small")
	if large != null:
		picture.draw_texture(large, centre + Vector2(-8, -8))
	if small != null:
		picture.draw_texture(small, centre + Vector2(-3, 0))


func _bar_width(row: int) -> int:
	return shown[row] * BAR_SPAN / START_LIFE


## A bar as the game draws it: a gouraud quad from the bar's left edge (64 in its colour's channel) to its right (255), the other
## two channels 32; each texel dithered at its pixel and cut to five bits, as the screen's polygons are. Player 1's bar is red,
## player 2's blue. The image is cached by its width.
func _bar_texture(row: int, width: int) -> Texture2D:
	if bar_cache_width[row] == width and bar_cache[row] != null:
		return bar_cache[row]
	var image := Image.create(width, 8, false, Image.FORMAT_RGBA8)
	for y in 8:
		for x in width:
			var t := float(x) / float(width)
			var ramp := int(64.0 + 191.0 * t)
			var rgb := [32, 32, 32]
			rgb[0 if row == 0 else 2] = ramp
			var dither: int = DITHER[(BAR_Y[row] + y) & 3][(BAR_X + x) & 3]
			var out := [0, 0, 0]
			for k in 3:
				out[k] = clampi(rgb[k] + dither, 0, 255) >> 3 << 3
			image.set_pixel(x, y, Color8(out[0], out[1], out[2], 255))
	var texture := ImageTexture.create_from_image(image)
	bar_cache[row] = texture
	bar_cache_width[row] = width
	return texture


func _input_state() -> Dictionary:
	var down := {
		"confirm": false,
		"cancel": false,
	}
	for key in CONFIRM_KEYS:
		down["confirm"] = down["confirm"] or Input.is_key_pressed(key)
	down["confirm"] = down["confirm"] or Input.is_joy_button_pressed(0, JOY_BUTTON_A) or Input.is_joy_button_pressed(0, JOY_BUTTON_X) \
		or Input.is_joy_button_pressed(1, JOY_BUTTON_A) or Input.is_joy_button_pressed(1, JOY_BUTTON_X)
	for key in CANCEL_KEYS:
		down["cancel"] = down["cancel"] or Input.is_key_pressed(key)
	down["cancel"] = down["cancel"] or Input.is_joy_button_pressed(0, JOY_BUTTON_B) or Input.is_joy_button_pressed(1, JOY_BUTTON_B)
	for pad in 2:
		var keys: Dictionary = KEYS[pad]
		var pad_joy := pad
		for direction in ["left", "right", "up", "down"]:
			var pressed := false
			for key in keys[direction]:
				pressed = pressed or Input.is_key_pressed(key)
			var button: int = {"left": JOY_BUTTON_DPAD_LEFT, "right": JOY_BUTTON_DPAD_RIGHT, "up": JOY_BUTTON_DPAD_UP, "down": JOY_BUTTON_DPAD_DOWN}[direction]
			down["%d_%s" % [pad, direction]] = pressed or Input.is_joy_button_pressed(pad_joy, button)
	var pressed := {}
	for key in ["confirm", "cancel"]:
		if down[key] and not held.get(key, false):
			pressed[key] = true
		held[key] = down[key]
	if cancel_click:
		pressed["cancel"] = true
		cancel_click = false
	return {"down": down, "pressed": pressed}


## A held key fires on its first frame and then every REPEAT_RATE frames once REPEAT_DELAY frames have passed.
func _fires(key: String, down: Dictionary) -> bool:
	var count: int = repeat.get(key, 0)
	if not down.get(key, false):
		repeat[key] = 0
		return false
	count += 1
	repeat[key] = count
	return count == 1 or (count > REPEAT_DELAY and (count - REPEAT_DELAY) % REPEAT_RATE == 0)


func _gui_input(event: InputEvent) -> void:
	if not ready_ok or not (event is InputEventMouseButton and event.pressed):
		return
	var at: Vector2 = (event.position - world.position) / world.scale
	match event.button_index:
		MOUSE_BUTTON_RIGHT:
			cancel_click = true
		MOUSE_BUTTON_LEFT:
			click_at = at
			click_pending = true
		MOUSE_BUTTON_WHEEL_UP:
			pending.append(["up", _row_at(at)])
		MOUSE_BUTTON_WHEEL_DOWN:
			pending.append(["down", _row_at(at)])
		MOUSE_BUTTON_WHEEL_LEFT:
			pending.append(["left", _row_at(at)])
		MOUSE_BUTTON_WHEEL_RIGHT:
			pending.append(["right", _row_at(at)])


## The row under a point: 0 or 1 for the bars and their value boxes, -1 for the legend and the rest (the wheel's row).
func _row_at(at: Vector2) -> int:
	for row in 2:
		if ROW_HIT[row].has_point(at):
			return row
	return -1


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible:
		return
	var input := _input_state()
	var down: Dictionary = input["down"]
	var pressed: Dictionary = input["pressed"]
	# busy: a row's star is moving, or its value is still counting toward the set value (the game's busy flags)
	var busy := [star_frames[0] > 0, star_frames[1] > 0]
	for row in 2:
		if life[row] != shown[row]:
			var step: int = absi(life[row] - shown[row])
			if shown[row] < 2:
				step = 99
			elif step >= 101:
				step = 100
			shown[row] = shown[row] + step if shown[row] < life[row] else shown[row] - step
			busy[row] = true
	var idle: bool = not busy[0] and not busy[1]
	if click_pending:
		click_pending = false
		_click(click_at, busy)
	if pressed.has("cancel") and idle:
		sound.emit(8)
		cancelled.emit()
		return
	if pressed.has("confirm") and idle:
		sound.emit(7)
		started.emit(life.duplicate())
		return
	for row in 2:
		var go_left := _fires("%d_left" % row, down)
		var go_right := _fires("%d_right" % row, down)
		var go_up := _fires("%d_up" % row, down)
		var go_down := _fires("%d_down" % row, down)
		if busy[row]:
			continue
		if mode[row] < 2:
			if go_left or go_right:
				_set_choice(0 if go_left else 1)
			elif go_down:
				_start_move(row, 2)
		elif go_left or go_right:
			_step_value(row, go_left)
		elif go_up:
			_start_move(row, choice)
	_wheel(busy)
	for row in 2:
		if star_frames[row] > 0:
			_advance_move(row)
	picture.queue_redraw()


## The legend's choice: every row in the legend follows it (the game sets the rows' modes from the one toggle).
func _set_choice(value: int) -> void:
	choice = value
	for row in 2:
		if mode[row] < 2:
			mode[row] = choice
	sound.emit(6)


## The row's value stepped by left or right (the game's value setup: the same rule for both rows).
func _step_value(row: int, left: bool) -> void:
	var value: int = life[row]
	if left:
		value = value - STEP if value - STEP > 0 else 1
	elif value < 2:
		value = STEP
	else:
		value = value + STEP if value + STEP < START_LIFE + 1 else START_LIFE
	life[row] = value
	sound.emit(6)


## The row's star moves from where it is to its place (the row's life points, or the legend's choice) in TWEEN_FRAMES frames.
func _start_move(row: int, to_mode: int) -> void:
	star_from[row] = _star_centre(row)
	star_at[row] = star_from[row]
	star_to_mode[row] = to_mode
	star_frames[row] = TWEEN_FRAMES


func _advance_move(row: int) -> void:
	var remaining: int = star_frames[row] - 1
	star_frames[row] = remaining
	var target: Vector2 = _value_star(row) if star_to_mode[row] == 2 else _mark_centre()
	star_at[row] = star_from[row] * remaining / TWEEN_FRAMES + target * (TWEEN_FRAMES - remaining) / TWEEN_FRAMES
	if remaining <= 0:
		mode[row] = star_to_mode[row]
		star_at[row] = target


## The wheel: up and down move the row under the pointer, left and right step its value (or pick the legend's choice).
func _wheel(busy: Array) -> void:
	while not pending.is_empty():
		var item: Array = pending.pop_front()
		var row: int = item[1]
		if row >= 0 and busy[row]:
			continue
		match item[0]:
			"up":
				if row >= 0 and mode[row] == 2:
					_start_move(row, choice)
			"down":
				if row >= 0 and mode[row] < 2:
					_start_move(row, 2)
			"left", "right":
				if row >= 0 and mode[row] == 2:
					_step_value(row, item[0] == "left")
				else:
					_set_choice(0 if item[0] == "left" else 1)


## A click: the footer's START DUEL line starts the duel (when nothing is moving), its RETURN line returns; a row in its legend is
## moved to its life points; a click on a row's bar sets its value to the nearest step under the pointer; the legend picks the choice.
func _click(at: Vector2, busy: Array) -> void:
	if FOOTER_RETURN.has_point(at):
		sound.emit(8)
		cancelled.emit()
		return
	if FOOTER_START.has_point(at):
		if not busy[0] and not busy[1]:
			sound.emit(7)
			started.emit(life.duplicate())
		return
	if LEGEND_ROW.has_point(at):
		choice = 0 if at.x < 168 else 1
		_set_choice(choice)
		return
	for row in 2:
		if not ROW_HIT[row].has_point(at) or busy[row]:
			continue
		if mode[row] < 2:
			_start_move(row, 2)
		elif at.x >= BAR_X - 4:
			var value := int(round(float(at.x - BAR_X) * START_LIFE / BAR_SPAN / STEP)) * STEP
			value = clampi(value, 1, START_LIFE)
			if value != life[row]:
				life[row] = value
				sound.emit(6)
		return
