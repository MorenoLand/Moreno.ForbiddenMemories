extends Control
## The Options screen: a native port of the options menu, the options setup, the options layout update, the options input handling and
## the options update. The one live row is the output type, stereo or mono: Left and Right choose it (SE 0x2F), Circle returns (SE 8).
## Steps at the game's 60 Hz. The pictures are baked by tools/extract.py --screens (assets/screens/options/).

signal closed                 # Circle: the screen is done, back to the main menu
signal sound(effect: int)     # the full SE play ids: 0x2F output type changed, 8 cancel
signal music(id: int)           # the BGM play this screen starts when it opens (the driver's BGM play)

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const GameAudio := preload("res://scripts/system/game_audio.gd")
const DIR := "res://assets/screens/options/"
const TEXT_STRING := 239                        # the text box creation(1, 0xEF, 0x18, 0x38, 0x120, 0x100)
const TEXT_ORIGIN := Vector2(24, 56)      # the text box at (24, 56); the small glyph class (game_text.gd) puts its rows 2 pixels lower, as the reference frame shows
const TEXT_ADVANCE := Vector2(8, 12)
const COLOR_SLOTS := [0, 4, 4, 4, 2]            # the text colour slots after the options text display setup(0)
const LABEL_X := [0x68, 0xC8]                   # where the options layout update puts the cursor's stereo and mono labels
const CURSOR_Y := 0x48 + 8                      # row 0: the cursor sits 8 pixels inside the label row
const LABEL_ROW_TOP := 0x48                     # the label row's band for mouse clicks (approximate: the picture's text is not measured here)
const LABEL_ROW_HEIGHT := 16.0

var text := GameText.new()
var layout: Dictionary = {}
var world := Node2D.new()
var sharp: ShaderMaterial
var cursor := Sprite2D.new()
var cursor_frames: Array = []        # Texture2D per frame of the animated cursor (the sparkle), with its offset in cursor_offsets
var cursor_offsets: Array = []
var cursor_sequence: Array = []      # the frame order; each frame is held for cursor_duration ticks, then the sequence restarts
var cursor_duration := 1
var cursor_tick := 0
var ready_ok := false
var held: Dictionary = {}
var mouse_side := -1           # a click on the stereo (0) or mono (1) label: the Left or Right press it stands for
var mouse_cancel := false      # right mouse button: Circle


func _ready() -> void:
	music.emit(29520)   # the BGM play in this screen's open routine
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	GameAudio.mono = GameState.output_type == 1      # the saved setting, in force before any effect plays
	if not text.load_all():
		return
	var json = JSON.parse_string(FileAccess.get_file_as_string(DIR + "layout.json")) if FileAccess.file_exists(DIR + "layout.json") else null
	if typeof(json) != TYPE_DICTIONARY:
		return
	layout = json
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sharp = ScreenFit.make_material()
	add_child(world)
	add_to_group("fit")
	var background := Sprite2D.new()
	background.centered = false
	background.texture = _texture("background.png")
	background.material = sharp
	world.add_child(background)
	cursor.centered = false
	for i in (layout["cursor"]["frames"] as Array).size():
		cursor_frames.append(_texture("cursor_%d.png" % i))
		cursor_offsets.append(layout["cursor"]["frames"][i])
	cursor_sequence = layout["cursor"]["sequence"]
	cursor_duration = int(layout["cursor"]["duration"])
	cursor.material = sharp
	world.add_child(cursor)
	# the game's colour slot table has 16 bytes; the setup writes the first five and the rest stay zero
	var slots: Array = []
	slots.resize(16)
	slots.fill(0)
	for i in COLOR_SLOTS.size():
		slots[i] = COLOR_SLOTS[i]
	text.slots = slots
	text.layout(world, text.string_bytes(TEXT_STRING), TEXT_ORIGIN, TEXT_ADVANCE, 0, sharp, true)

	ScreenFit.pass_mouse(self)
	ready_ok = true
	_place_cursor()
	get_viewport().size_changed.connect(refit)
	refit()


func _texture(file: String) -> Texture2D:
	return ModArt.texture(DIR + file)


func refit() -> void:
	ScreenFit.apply(world, size)   # the options picture is 224 lines tall, with the game's black below it (the baked background)


## the options layout update for row 0: the cursor's origin is the chosen label's x + 8, and the picture's own offset is added.
func _place_cursor() -> void:
	if cursor_frames.is_empty():
		return
	var frame: int = cursor_sequence[_cursor_step()]
	var at: Dictionary = cursor_offsets[frame]
	cursor.texture = cursor_frames[frame]
	cursor.position = Vector2(LABEL_X[GameState.output_type] + 8 + int(at["x"]), CURSOR_Y + int(at["y"]))


## the frame of the cursor animation this tick: the stream holds each frame for cursor_duration ticks, then restarts
func _cursor_step() -> int:
	return int(cursor_tick / maxi(cursor_duration, 1)) % cursor_sequence.size()


## The pressed edges for this frame; the original reads only pressed bits (no repeat) for this screen.
func _pressed() -> Dictionary:
	var down := {
		"left": Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT),
		"right": Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT),
		"cancel": Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_BACKSPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_B),
	}
	var pressed := {}
	for key in down:
		if down[key] and not held.get(key, false):
			pressed[key] = true
		held[key] = down[key]
	if mouse_side >= 0:
		pressed["left" if mouse_side == 0 else "right"] = true
		mouse_side = -1
	if mouse_cancel:
		pressed["cancel"] = true
		mouse_cancel = false
	return pressed


## A click on the label row picks the side under it (approximate hit boxes: the row's top band, split between the two labels).
func _gui_input(event: InputEvent) -> void:
	if not ready_ok or not (event is InputEventMouseButton and event.pressed):
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		mouse_cancel = true
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var local: Vector2 = (event.position - world.position) / world.scale
	if local.y >= LABEL_ROW_TOP and local.y < LABEL_ROW_TOP + LABEL_ROW_HEIGHT:
		mouse_side = 0 if local.x < (LABEL_X[0] + LABEL_X[1]) / 2.0 else 1


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible:
		return
	cursor_tick += 1
	if not cursor_frames.is_empty():
		_place_cursor()   # the cursor animates every tick (the sparkle), and follows the chosen label
	var pressed := _pressed()
	if pressed.has("left") or pressed.has("right"):
		# the options input handling: a press toward the side already chosen does nothing, and consumes the tick
		var wanted := 1 if pressed.has("right") else 0
		if wanted != GameState.output_type:
			GameState.output_type = wanted
			GameAudio.mono = wanted == 1      # the output type set: the sound effects follow the setting at once
			sound.emit(0x2F)
			_place_cursor()
		return
	if pressed.has("cancel"):
		sound.emit(8)
		closed.emit()
