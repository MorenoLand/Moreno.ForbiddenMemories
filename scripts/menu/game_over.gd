extends Control
## The Game Over screen: a native port of the game over run, the game over setup and the routine at 0x8003CA5C. The background is the picture on
## page 16, read straight from VRAM at 8 bits. The flying sprite is the bank's stream: three variants (flying, hovering, idling)
## that each run to their Stop before the next one starts; at the end of the idle variant it comes back from the right edge once it
## has gone past the left one. Steps at the game's 60 Hz. The fade in and out are the game's 30-band wipe (the band fade step).
## Confirm or cancel, once the fade in is done, fades out and emits finished: the front end's title menu comes back then.
## The pictures and the stream timing are baked by tools/extract.py --screens (assets/screens/game_over/).

signal finished              # the fade out is done: back to the front-end menu (the game over run's mode 8 path)
signal sound(effect: int)    # the game over plays no sound effect (no the SE play in its code); kept for the screens' convention
signal music(id: int)           # the BGM play this screen starts when it opens (the driver's BGM play)

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const TouchControls := preload("res://scripts/system/touch_controls.gd")
const DIR := "res://assets/screens/game_over/"
const START_X := 448                  # the game over setup: the sprite starts at (448, 192), off the right edge
const START_Y := 192
const FLY_VELOCITY := -0xC0           # phase 0: x velocity in 1/256 pixel a tick (the sprite drifts left)
const WRAP_X := -0x2F                 # phase 2 end: x below -47 brings it back...
const RESPAWN_X := 0x160              # ...at x 352, with a height of rand(0xB0) + 0x30
const RESPAWN_Y := 0x30
const RESPAWN_RANGE := 0xB0
const FADE_IN_STEP := 2               # the fade-in start, then the game over setup sets the step to 2
const FADE_OUT_STEP := 8              # the fade-out start
const FADE_LEVEL_MAX := 255           # 0xFF: the fade in's target (the picture fully shown)
const BANDS := 30                     # FADE_BAND_COUNT: 30 bands of 8 lines
const BAND_HEIGHT := 8
const TICK := 1                       # the data at 0x8009B0D8 at the normal rate
const FRACTION_RESET := 0x80          # the velocity reset: the position fractions go back to half a pixel
const SCREEN_W := 320
const SCREEN_H := 240

var world := Node2D.new()
var stage := Control.new()           # the 320 x 240 picture, clipped, so the sprite is hidden outside it
var background := Sprite2D.new()
var sprite := Sprite2D.new()
var bands: Array = []
var ready_ok := false
var was_down := false
var exiting := false
var done := false

var frames: Array = []               # Texture2D per frame, with its offset from the sprite's origin
var offsets: Array = []
var streams: Array = []              # per variant: [hold, frame] pairs in play order; the Stop follows them

var fade_level := 0                  # the fade state.level: 0 when the screen starts (black), assumed from the fade out before it
var fade_target := FADE_LEVEL_MAX
var fade_acc := 0                    # field_08: the band wipe's accumulator
var fade_step := FADE_IN_STEP
var fade_active := true
var fade_bands := PackedInt32Array()

var sprite_x := START_X              # the sprite velocity x, with its fraction
var sprite_y := START_Y
var fraction := 0x80
var velocity := 0
var phase := 0                       # field_6C: 0 fly-in, 1 hover, 2 idle
var variant := 0                     # field_69: the stream the sprite plays
var started := false                 # flags 0x10: the stream's first command has been read since the variant changed
var hold := 0                        # field_5A: the ticks left on the current frame, 0 at a Stop
var command := 0                     # the stream cursor, as a command index
var frame := -1                      # the frame on show


func _ready() -> void:
	music.emit(29440)   # the BGM play in this screen's open routine
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(black)
	var json = JSON.parse_string(FileAccess.get_file_as_string(DIR + "layout.json")) if FileAccess.file_exists(DIR + "layout.json") else null
	if typeof(json) != TYPE_DICTIONARY:
		return
	for file_frame in json["frames"]:
		frames.append(_texture(file_frame["file"]))
		offsets.append(Vector2i(int(file_frame["x"]), int(file_frame["y"])))
	for variant_stream in json["streams"]:
		var pairs := []
		for pair in variant_stream:
			pairs.append([int(pair[0]), int(pair[1])])
		streams.append(pairs)
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(world)
	add_to_group("fit")
	stage.size = Vector2(SCREEN_W, SCREEN_H)
	stage.clip_contents = true
	world.add_child(stage)
	var sharp := ScreenFit.make_material()
	background.centered = false
	background.texture = _texture("background.png")
	background.material = sharp
	stage.add_child(background)
	sprite.centered = false
	sprite.material = sharp
	stage.add_child(sprite)
	for i in BANDS:
		var band := ColorRect.new()
		band.color = Color(0, 0, 0, 1)
		band.position = Vector2(0, i * BAND_HEIGHT)
		band.size = Vector2(SCREEN_W, BAND_HEIGHT)
		band.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stage.add_child(band)
		bands.append(band)
	ScreenFit.pass_mouse(self)
	fade_bands.resize(BANDS)
	_fade_start_in()
	was_down = _confirm_or_cancel_down()   # a key already held when the screen opens does not count as a press
	ready_ok = true
	get_viewport().size_changed.connect(refit)
	refit()


func _texture(file: String) -> Texture2D:
	return ModArt.texture(DIR + file)


func refit() -> void:
	ScreenFit.apply(world, size)


## One tick: the mode runner (the routine at 0x8003CA5C) first, then the frame's stream and drawing (the display walker), then the fade.
func _physics_process(_delta: float) -> void:
	if not ready_ok or done:
		return
	var pressed := _pressed()
	if not exiting:
		_step_motion()
		if hold == 0:
			_phase_change()
		# after the fade in, a confirm or cancel press starts the fade out (a press during the fade in is lost, as in the game)
		if not fade_active and pressed:
			exiting = true
			_fade_start_out()
	_stream_tick()
	_draw_sprite()
	_fade_update()
	if exiting and not fade_active:
		done = true
		finished.emit()


## the position step: x and its 1/256 fraction move by the velocity.
func _step_motion() -> void:
	var value := (sprite_x << 8) | fraction
	value += velocity
	fraction = value & 0xFF
	sprite_x = value >> 8


## the routine at 0x8003CA5C's switch on the stream's end (field_5A == 0), one step a time: fly in, hover, idle, then back to the fly-in.
func _phase_change() -> void:
	match phase:
		0:
			variant = 1
			started = false
			phase = 1
			velocity = FLY_VELOCITY
		1:
			velocity = 0
			fraction = FRACTION_RESET
			variant = 2
			started = false
			phase = 2
		2:
			variant = 0
			started = false
			phase = 0
			if sprite_x < WRAP_X:
				sprite_x = RESPAWN_X
				sprite_y = randi() % RESPAWN_RANGE + RESPAWN_Y


## the command stream update: the first tick after a variant change reads the first command; after that the hold counts
## down a tick at a time and the next command is read when it runs out. A Stop leaves the hold at 0 and the frame on show.
func _stream_tick() -> void:
	if not started:
		started = true
		command = 0
		_read_next()
		return
	if hold != 0:
		hold -= TICK
		if hold <= 0:
			_read_next()


func _read_next() -> void:
	var commands: Array = streams[variant] if variant < streams.size() else []
	if command >= commands.size():
		hold = 0
		return
	hold = commands[command][0]
	frame = commands[command][1]
	command += 1


func _draw_sprite() -> void:
	if frame < 0 or frame >= frames.size():
		sprite.visible = false
		return
	sprite.visible = true
	sprite.texture = frames[frame]
	var offset: Vector2i = offsets[frame]
	sprite.position = Vector2(sprite_x + offset.x, sprite_y + offset.y)


## the fade-in setup then the fade-in start, then the game over setup's step of 2: the band wipe from black up to the full picture.
func _fade_start_in() -> void:
	fade_target = FADE_LEVEL_MAX
	fade_acc = 0
	fade_active = true
	_fill_bands(fade_level)
	fade_step = FADE_IN_STEP


## the fade-out setup then the fade-out start: the band wipe from the picture down to black.
func _fade_start_out() -> void:
	fade_acc = FADE_LEVEL_MAX
	fade_target = 0
	fade_active = true
	_fill_bands(fade_level)
	fade_step = FADE_OUT_STEP


func _fill_bands(level: int) -> void:
	for i in BANDS:
		fade_bands[i] = level


## the fade update for the banded fades: the bands are stepped until the outer pair reaches the target; the fade ends the tick after.
func _fade_update() -> void:
	if fade_active:
		if fade_level != fade_target:
			_fade_step_bands()
		else:
			fade_active = false
	for i in BANDS:
		bands[i].color = Color(0, 0, 0, float(FADE_LEVEL_MAX - fade_bands[i]) / FADE_LEVEL_MAX)


## the band fade step, literally: fade in visits the middle pair first and subtracts the step, fade out visits the outer pair first
## and adds it; each value is clamped between the current level and the target, and the level follows the outer pair's value.
func _fade_step_bands() -> void:
	var lvl := fade_level
	if fade_level < fade_target:
		var acc := fade_acc
		for i in range(BANDS / 2 - 1, -1, -1):
			acc -= fade_step
			lvl = acc
			if lvl < fade_level:
				lvl = fade_level
			if fade_target < lvl:
				lvl = fade_target
			fade_bands[i] = lvl
			fade_bands[BANDS - 1 - i] = lvl
		fade_acc += fade_step * TICK
	else:
		var acc := fade_acc
		for i in range(BANDS / 2):
			acc += fade_step
			lvl = acc
			if lvl < fade_target:
				lvl = fade_target
			if fade_level < lvl:
				lvl = fade_level
			fade_bands[i] = lvl
			fade_bands[BANDS - 1 - i] = lvl
		fade_acc -= fade_step * TICK
	if lvl == fade_target:
		fade_level = lvl


func _confirm_or_cancel_down() -> bool:
	# a click or a tap on the game counts as well (the mouse and touch have no other way to leave this screen)
	return Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_F) \
		or Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_BACKSPACE) \
		or Input.is_joy_button_pressed(0, JOY_BUTTON_A) or Input.is_joy_button_pressed(0, JOY_BUTTON_X) \
		or Input.is_joy_button_pressed(0, JOY_BUTTON_B) or TouchControls.game_pointer_held()


## The pad's pressed edge for Cross, Square or Circle this tick (gInput_wPad1Pressed).
func _pressed() -> bool:
	var down := _confirm_or_cancel_down()
	var edge := down and not was_down
	was_down = down
	return edge
