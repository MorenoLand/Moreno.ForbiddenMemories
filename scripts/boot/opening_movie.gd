extends Node2D
## The opening movie the boot plays after the Konami screens: the first movie of the disc's movie file, pre-decoded by tools/extract.py
## into assets/movies/frames/fNNNN.png (320 x 240, 15 a second) with its XA audio in assets/movies/opening.wav.
## The picture is drawn 1.5 times as wide (480 x 240): the movie's wide display mode. The stream fades to black over its last four
## frames (299 to 303). Skipping (Enter, Space, Esc, a click or a touch) fades it out over four frames the same way.
## When the movie files are missing, the movie is over at once.

signal finished

const DIR := "res://assets/movies/"
const FPS := 15.0
const END_FRAME := 303          # the movie's end frame (the stream's table entry); the picture is black from there on
const FADE_FROM := 299          # the fade starts after this frame: 0xFF down by 0x40 a frame
const FADE_FRAMES := 4
const WIDE := 1.5
## The simple deblock of the MDEC frames: the 8-pixel block seams are blended half-and-half with their neighbour across the seam,
## by this share (0 is the frames as decoded). The shader does it on the draw, so the baked frames stay exact.
const DEBLOCK := 0.5
const ScreenFit := preload("res://scripts/system/screen_fit.gd")

var sprite := Sprite2D.new()
var audio := AudioStreamPlayer.new()
var elapsed := 0.0
var shown := 0
var texture_frame := 0
var skip_time := -1.0          # >= 0 once skipping: the seconds since the skip
var done := false


static func shade_at(frame: int) -> float:
	## The picture's brightness on a frame (1-based): full until the fade, then down a quarter a frame to black.
	if frame <= FADE_FROM:
		return 1.0
	return clampf(1.0 - 0.25 * float(frame - FADE_FROM), 0.0, 1.0)


static func frame_at(seconds: float) -> int:
	## The 1-based frame shown at a time: frame 1 at the start, one more every 1 / FPS seconds.
	return mini(int(floor(seconds * FPS)) + 1, END_FRAME)


static func is_available() -> bool:
	return FileAccess.file_exists(DIR + "frames/f0001.png") and FileAccess.file_exists(DIR + "opening.wav")


func _ready() -> void:
	sprite.centered = false
	sprite.scale = Vector2(WIDE, 1.0)
	sprite.material = ScreenFit.make_material()
	sprite.material.set_shader_parameter("deblock", DEBLOCK)   # the MDEC block seams (0 turns it off; see sharp_pixels.gdshader)
	add_child(sprite)
	add_child(audio)
	if not is_available():
		_finish.call_deferred()
		return
	audio.stream = AudioStreamWAV.load_from_file(DIR + "opening.wav")
	audio.play()
	_show(1)


func skip() -> void:
	if skip_time < 0.0 and not done:
		skip_time = 0.0


func _show(frame: int) -> void:
	if frame != texture_frame and frame <= END_FRAME:
		var image := Image.load_from_file(DIR + "frames/f%04d.png" % frame)
		if image != null:
			sprite.texture = ImageTexture.create_from_image(image)
		texture_frame = frame
	shown = frame
	var shade := shade_at(frame)
	sprite.modulate = Color(shade, shade, shade)


func _process(delta: float) -> void:
	if done:
		return
	if skip_time >= 0.0:
		skip_time += delta
		var left := clampf(1.0 - skip_time / (FADE_FRAMES / FPS), 0.0, 1.0)
		var shade := shade_at(shown) * left
		sprite.modulate = Color(shade, shade, shade)
		if left <= 0.0:
			_finish()
		return
	var clock := elapsed
	if audio.playing:
		# the audio clock, less the output latency: the picture follows the sound
		clock = audio.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency()
	elapsed += delta
	if clock >= float(END_FRAME) / FPS:
		_finish()
		return
	var frame := frame_at(clock)
	if frame != shown:
		_show(frame)


func _finish() -> void:
	if done:
		return
	done = true
	audio.stop()
	finished.emit()
