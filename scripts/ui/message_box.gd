extends Control
## A one-box message: the memory card and trade notices (the memory card dialog). The box is the memory card dialog's own: a frame
## sprite (assets/screens/card_frame/, the picture cut to its box, its offset from the object's origin in layout.json) and the text box
## at (32, 80), 256 x 48. The frame slides in from above and out below (16 frames each, a sine ease), the
## glyphs come in one by one as the text boxes do, and a press closes the box (closed is emitted once it has slid out).
## The game's string is drawn in the box; the box is closed with confirm, cancel or a click.

signal closed
signal sound(effect: int)

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const TouchControls := preload("res://scripts/system/touch_controls.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const CARD_DIR := "res://assets/screens/card_frame/"
const BOX := Vector2(32, 80)          # the box's origin (x 32, y 80, 256 x 48) and where the frame settles
const SLIDE_TOP := -64.0              # the frame starts 64 pixels above the box
const SLIDE_OUT := 256.0              # and closes down to y 256
const SLIDE_FRAMES := 16
const ADVANCE := Vector2(8, 12)
const TEXT_OFFSET := Vector2(0, -2)   # the glyph rows sit two pixels above the box's top, as the other text boxes draw them

var string_id := 0
var auto_close := 0                   # frames after which the box closes by itself (a notice that waits on a write, such as SAVING...)
var open_frames := 0
var text := GameText.new()
var world := Node2D.new()
var holder := Node2D.new()            # the frame and the text move together
var ready_ok := false
var armed := false                    # the key that opened the box must be let go first
var phase := 0                        # 0 sliding in, 1 open, 2 sliding out
var slide := 0                        # frames done in the current slide
var sharp: ShaderMaterial


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all():
		return
	var json = JSON.parse_string(FileAccess.get_file_as_string(CARD_DIR + "layout.json")) if FileAccess.file_exists(CARD_DIR + "layout.json") else null
	if typeof(json) != TYPE_DICTIONARY:
		return
	sharp = ScreenFit.make_material()
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(world)
	add_to_group("fit")
	world.add_child(holder)
	var image := Image.load_from_file(CARD_DIR + "frame.png")
	if image != null:
		var frame := Sprite2D.new()
		frame.centered = false
		frame.texture = ImageTexture.create_from_image(image)
		frame.material = sharp
		var o: Dictionary = json["frame"]
		frame.position = Vector2(int(o["x"]), int(o["y"]))
		holder.add_child(frame)
	var placed := text.layout(holder, text.string_bytes(string_id), TEXT_OFFSET, ADVANCE, 0, sharp, true)
	var index := 0
	for entry in placed:
		if entry["sprite"] != null:
			var fx := Polygon2D.new()
			fx.set_script(preload("res://scripts/ui/glyph_fx.gd"))
			fx.sprite = entry["sprite"]
			fx.delay = index * 2
			fx.small = true
			holder.add_child(fx)
		index += 1
	_place()
	get_viewport().size_changed.connect(refit)
	refit()
	ScreenFit.pass_mouse(self)
	ready_ok = true


func refit() -> void:
	ScreenFit.apply(world, size)


## The box's height on the screen this frame: a sine ease (open from -64 to 80, close from 80 to 256).
func _place() -> void:
	var t := float(slide) / float(SLIDE_FRAMES)
	var y := BOX.y
	if phase == 0:
		y = SLIDE_TOP + (BOX.y - SLIDE_TOP) * sin(t * PI / 2.0)
	elif phase == 2:
		y = SLIDE_OUT - (SLIDE_OUT - BOX.y) * cos(t * PI / 2.0)
	holder.position = Vector2(BOX.x, roundf(y))


func _pressed() -> bool:
	return Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER) \
		or Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_BACKSPACE) \
		or TouchControls.game_pointer_held() or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)


func _physics_process(_delta: float) -> void:
	if not ready_ok:
		return
	var down := _pressed()
	if phase == 0:
		slide += 1
		_place()
		if slide >= SLIDE_FRAMES:
			phase = 1
		if not armed:
			armed = not down
		return
	if phase == 2:
		slide += 1
		_place()
		if slide >= SLIDE_FRAMES:
			ready_ok = false
			closed.emit()
		return
	if not armed:
		armed = not down
		return
	open_frames += 1
	if auto_close > 0 and open_frames >= auto_close:
		phase = 2
		slide = 0
		return
	if auto_close == 0 and down:
		sound.emit(7)
		phase = 2
		slide = 0
