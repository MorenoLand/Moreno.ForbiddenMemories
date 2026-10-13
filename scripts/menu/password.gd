extends Control
## The PASSWORD screen (the password shop): eight digits are set with up and down and moved between with left and right; Cross or
## Enter looks the password up among the 722 cards (cards.json "password") and the card's picture slides in. A card the player has
## already bought with a password gets "This PASSWORD has already been entered!"; otherwise the card is offered for its starchip
## price (CARD NUMBER / x price, EXCHANGE or QUIT). EXCHANGE, when the balance covers it, adds the card to the chest
## (GameState.award_card) and marks its password as used, then the price counts down from the balance in the game's steps. A balance
## short of the price shows the same prompt with EXCHANGE in red, which cannot be chosen. Circle (or Q, Esc, Backspace) leaves the
## screen; the menu comes back on the PASSWORD entry.
##
## The pictures are the game's own, baked by tools/extract.py into assets/screens/password/: the digit cursor, the translucent
## animated panel at the starchip counter (the only picture the screen draws, so the rest of the screen is the game's black), the
## digit arrows, and the prompt window, which is the campaign dialog frame nine-patched around the prompt box.
##
## Keyboard: the digit keys 0 to 9 type a digit and move on; WASD or the arrows edit the digits, E, Space or Enter confirm, Q, Esc
## or Backspace cancel. Mouse: a digit is picked by clicking it (a second click on the picked digit raises it), a click on the
## prompt window confirms, and a right click cancels.
##
## Approximations: the card is shown as a reveal from the top instead of the game's slide and turn, and its frame, plates and icons
## are not drawn; the dialog text is not typed out glyph by glyph and no music plays; the prompt window is the campaign frame art
## (the game's own window is drawn by its text system and was not located); the choice text is laid out from the game's words with
## the card number and price written in (the bank's number fields are not read); the choice cursor is a '>' rather than the game's pointer.

signal closed                 # Circle, back to the menu on the PASSWORD entry
signal sound(effect: int)     # the full SE play ids: 47 digit cursor, 7 digit changed, 8 cancel, 9 refused, 48 password found, 12 card shown

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const CardDB := preload("res://scripts/data/card_db.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const CardView := preload("res://scripts/ui/card_view.gd")   # split_ink: the card view inks, laid over the frame or subtracted from it
const GameState := preload("res://scripts/state/game_state.gd")
const DIR := "res://assets/screens/"
const PICS := "res://assets/screens/password/"
const FRAME := "res://assets/screens/story/frame.png"
const FRAME_RECT := Rect2(0, 154, 320, 84)   # the frame art's bar in its picture (opaque from row 154 down)
const PATCH := [7, 7, 7, 7]                   # the windows' border on the reference screen (thin stone); the frame art is cut to it
const DIGITS := 8
const PASSWORD_USED_BASE := 0x400         # the password-used flag base: a card's used flag is base + id
const STRING_ENTER := 226                 # Please enter 'PASSWORD' and OK / END
const STRING_STARCHIP := 225              # STARCHIP, and the balance on its second line
const STRING_EXCHANGE := 227              # CARD NUMBER, the price, EXCHANGE or QUIT
const STRING_NOT_ENOUGH := 228            # the same, EXCHANGE in red
const STRING_ENTERED := 229               # This 'PASSWORD' has already been entered!
const STARCHIP_NUMBER := 0x801D5608       # the RAM address of the starchip balance that the string's number reads
const DIGIT_ORIGIN := Vector2(168, 104)   # the digit row: 8 large glyphs from (168, 104), 16 apart
const DIGIT_ADVANCE := Vector2(16, 16)
const DIGIT_CELL := 16
const CURSOR_ORIGIN := Vector2(163, 99)   # the digit cursor's place for digit 0: x 163 + 16 a digit, y 99
const CURSOR_TWEEN := 8                   # ticks a move takes; input waits for it, as the game's cursor does
const ARROW_LEFT := Vector2(169, 104)     # the arrow before the first digit, shown unless the cursor is on digit 0
const ARROW_RIGHT := Vector2(297, 104)    # the arrow past the last digit, shown unless the cursor is on the last digit
const ARROW_SIDE := 5                     # the up and down arrows sit 5 to the right of the cursor
const ARROW_UP_Y := 88
const ARROW_DOWN_Y := 120
const STARCHIP_ORIGIN := Vector2(152, 40) # the starchip object and its text box (152, 40), 160 x 32
const CARD_WIN := Vector2(2, 30)          # the card preview's origin: its frame object at (2, 30) (the frame's own offset)
const CARD_SIZE := Vector2(140, 196)      # the frame's box; the card turns about its centre
const PICTURE_AT := Vector2(19, 50)       # the card-detail routine's offsets from the card origin
const NAME_AT := Vector2(12, 14)
const ATTRIBUTE_AT := Vector2(110, 13)
const STARS_AT := Vector2(119, 32)
const ATK_AT := Vector2(72, 158)
const DEF_AT := Vector2(72, 170)
const CARD_UI := "res://assets/screens/card_ui/"
const CARD_BACK := "res://assets/images/card_frames/card_back/"
const NAMEPLATE := "res://assets/images/nameplate/"
const BOX := Vector2(152, 152)            # the prompt's text box: 160 x 64 at (152, 152)
const WINDOW := Rect2(146, 144, 174, 80)  # the prompt window, measured on the reference screen: its border starts at (146, 144)
const STARCHIP_WINDOW := Rect2(146, 32, 174, 48)
const DIGIT_WINDOW := Rect2(146, 81, 174, 62)
const TEXT_ADVANCE := Vector2(8, 12)
const TEXT_LINE := 12
const REVEAL := 128                       # the card's phase: 128 hidden, 0 shown; 8 a frame (16 frames)
const RED := 4                            # the colour ramp the game's F8 0A 04 picks for EXCHANGE when it cannot be chosen
const BLUE_TEXT := 1                      # F8 0A 01 for "This 'PASSWORD'" lines
const REPEAT_DELAY := 24
const REPEAT_RATE := 6
const CHOICE_EXCHANGE := 0
const CHOICE_QUIT := 1
const SYMBOLS := {" ": 0, "<": 84, ">": 81, "/": 68, ".": 11, "'": 27, ",": 31, "-": 48, "#": 60, "&": 67}   # the font's symbol glyphs

var text := GameText.new()
var cards := CardDB.new()
var glyph_codes: Dictionary = {}          # Shift-JIS code -> glyph index
var digit_codes: Array = []               # the ten digit glyphs, 0 to 9
var ids_by_password: Dictionary = {}      # "89631139" -> the lowest card id with that password
var sharp: ShaderMaterial
var plate_subtract: ShaderMaterial          # the card's name plate, subtracted from the frame
var ready_ok := false
var world := Node2D.new()
var card_holder := Node2D.new()           # the card, turned about its centre (scale x = cos of the turn)
var card_front := Node2D.new()            # the frame, picture, name, attribute, stars and stats (origin = the card origin)
var card_back_sprite := Sprite2D.new()
var starchip_window := NinePatchRect.new()
var digit_window := NinePatchRect.new()
var card_streams: Array = []              # the frame's animated picture
var card_ui: Dictionary = {}
var backdrop := Node2D.new()              # the starchip object's animated panel, behind the text
var starchip_node := Node2D.new()
var digit_node := Node2D.new()
var cursor_sprite := Sprite2D.new()
var prompt_node := Node2D.new()
var window := NinePatchRect.new()
var streams: Dictionary = {}              # "starchip", "right", "down", "up" -> an animated picture (see _make_stream)
var digits: Array = [0, 0, 0, 0, 0, 0, 0, 0]
var index := 0                            # the digit under the cursor
var cursor_x := CURSOR_ORIGIN.x           # where the cursor is drawn: it slides to its digit over CURSOR_TWEEN ticks
var cursor_from := CURSOR_ORIGIN.x
var tween_left := 0
var card := 0                             # the card the password named
var state := "entry"                      # entry, reveal, prompt, paid, away
var phase := REVEAL
var prompt_id := 0
var choice := CHOICE_EXCHANGE
var locked := false                       # 228: EXCHANGE cannot be chosen
var remaining := 0                        # the starchips still to count down
var repeat: Dictionary = {}
var held: Dictionary = {}
var click_pending := false
var wheel_pending := 0                    # wheel steps waiting: up raises the digit, down lowers it
var click_at := Vector2.ZERO
var wheel_steps := 0                      # mouse wheel notches while entering: negative raises the digit, positive lowers it
var cancel_click := false
var frame := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all() or not cards.load_all():
		return
	for i in text.glyphs.size():
		var sjis := int(text.glyphs[i]["sjis"])
		if not glyph_codes.has(sjis):
			glyph_codes[sjis] = i
	for d in 10:
		digit_codes.append(glyph_codes.get(0x824F + d, 0))
	for i in cards.cards.size():
		var password := str(cards.cards[i].get("password", ""))
		if not ids_by_password.has(password):
			ids_by_password[password] = i + 1
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sharp = ScreenFit.make_material()
	plate_subtract = ScreenFit.make_material(false, false, true)
	add_child(world)
	add_to_group("fit")
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(320, 240)
	black.z_index = -3
	world.add_child(black)
	var layout := _layout()
	world.add_child(backdrop)
	backdrop.z_index = -2
	world.add_child(card_holder)
	card_holder.position = CARD_WIN + CARD_SIZE / 2.0
	card_holder.z_index = 2
	card_holder.visible = true
	card_holder.add_child(card_front)
	card_front.position = -CARD_SIZE / 2.0
	card_holder.add_child(card_back_sprite)
	card_back_sprite.centered = false
	card_back_sprite.position = -CARD_SIZE / 2.0
	card_back_sprite.material = sharp
	card_back_sprite.visible = true
	var ui = JSON.parse_string(FileAccess.get_file_as_string(CARD_UI + "layout.json"))
	card_ui = ui if typeof(ui) == TYPE_DICTIONARY else {}
	world.add_child(starchip_node)
	starchip_node.z_index = 3
	world.add_child(digit_node)
	digit_node.z_index = 3
	cursor_sprite.centered = false
	cursor_sprite.texture = _texture("cursor.png")
	cursor_sprite.material = sharp
	cursor_sprite.z_index = 5
	world.add_child(cursor_sprite)
	if layout.has("arrows"):
		var arrows: Array = layout["arrows"]
		# the right arrow is the disc's own stream too (arrows[0], like the other three; the reference shows it in the same olive)
		streams["right"] = _make_stream(world, arrows[0], 4)
		streams["down"] = _make_stream(world, arrows[1], 4)
		streams["up"] = _make_stream(world, arrows[3], 4)
		streams["left"] = _make_stream(world, arrows[2], 4)
	for win in [[starchip_window, STARCHIP_WINDOW], [digit_window, DIGIT_WINDOW], [window, WINDOW]]:
		var frame_window: NinePatchRect = win[0]
		frame_window.position = win[1].position
		frame_window.size = win[1].size
		frame_window.z_index = 1
		frame_window.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame_window.material = sharp
		frame_window.patch_margin_left = PATCH[0]
		frame_window.patch_margin_top = PATCH[1]
		frame_window.patch_margin_right = PATCH[2]
		frame_window.patch_margin_bottom = PATCH[3]
		var frame_image := Image.load_from_file(FRAME)
		if frame_image != null:
			var frame_atlas := AtlasTexture.new()
			frame_atlas.atlas = ImageTexture.create_from_image(frame_image)
			frame_atlas.region = FRAME_RECT
			frame_window.texture = frame_atlas
		world.add_child(frame_window)
	card_back_sprite.texture = _back_texture()
	world.add_child(prompt_node)
	prompt_node.z_index = 10
	_refresh_starchips()
	_refresh_digits()
	_place_cursor()
	_show_prompt(STRING_ENTER)
	get_viewport().size_changed.connect(refit)
	refit()
	ScreenFit.pass_mouse(self)
	ready_ok = true


func refit() -> void:
	ScreenFit.apply(world, size)


func _layout() -> Dictionary:
	var data = JSON.parse_string(FileAccess.get_file_as_string(PICS + "layout.json"))
	return data if typeof(data) == TYPE_DICTIONARY else {}


func _texture(file: String) -> Texture2D:
	var image := Image.load_from_file(PICS + file)
	return ImageTexture.create_from_image(image) if image != null else null


## An animated picture: one sprite per frame, shown in play order. Each entry of the order is [hold, frame]; a hold of h shows the
## frame for h + 1 ticks, and the order starts again after its last entry.
func _make_stream(parent: Node2D, entry: Dictionary, z: int) -> Dictionary:
	var nodes: Array = []
	for f in entry.get("frames", []):
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.visible = false
		sprite.z_index = z
		sprite.material = sharp
		if f.has("file"):
			sprite.texture = _texture(str(f["file"]))
		parent.add_child(sprite)
		nodes.append({"sprite": sprite, "x": int(f.get("x", 0)), "y": int(f.get("y", 0))})
	# a stream's entry with a zero hold is its last: the frame it names stays up (the stream does not loop past it)
	var order: Array = []
	for step in entry.get("order", []):
		order.append(step)
		if int(step[0]) == 0:
			break
	return {"nodes": nodes, "order": order, "at": -1, "left": 0, "shown": -1, "on": true}


## Places a stream's frames from its object's origin; `on` false hides the whole stream.
func _place(stream: Dictionary, origin: Vector2, on: bool) -> void:
	stream["on"] = on
	for node in stream["nodes"]:
		node["sprite"].position = origin + Vector2(node["x"], node["y"])


func _tick_stream(stream: Dictionary) -> void:
	var order: Array = stream["order"]
	if order.is_empty():
		return
	if int(stream["left"]) <= 0:
		stream["at"] = (int(stream["at"]) + 1) % order.size()
		stream["left"] = int(order[stream["at"]][0]) + 1
		stream["shown"] = int(order[stream["at"]][1])
	stream["left"] = int(stream["left"]) - 1
	var nodes: Array = stream["nodes"]
	for i in nodes.size():
		nodes[i]["sprite"].visible = bool(stream["on"]) and i == int(stream["shown"])


func _refresh_digits() -> void:
	_clear(digit_node)
	var codes: Array = []
	for d in digits:
		codes.append(digit_codes[int(d)])
	text.layout(digit_node, codes, DIGIT_ORIGIN, DIGIT_ADVANCE, 0, sharp)


func _refresh_starchips() -> void:
	_clear(starchip_node)
	var ctx := {"digits": digit_codes, "numbers": {STARCHIP_NUMBER: GameState.starchips}}
	# the balance is set in the large cell (16 a letter, 16 a line): the reference's STARCHIP and x0 are the large letters
	text.layout(starchip_node, text.string_bytes(STRING_STARCHIP), STARCHIP_ORIGIN, Vector2(16, 16), 0, sharp, false, {}, ctx)


## The cursor and the two arrows that follow it (the arrow past the last digit goes out on the last digit).
func _place_cursor() -> void:
	cursor_sprite.position = Vector2(cursor_x, CURSOR_ORIGIN.y)
	if streams.has("left"):
		_place(streams["left"], ARROW_LEFT, index > 0)
	if streams.has("right"):
		_place(streams["right"], ARROW_RIGHT, index < DIGITS - 1)
	if streams.has("down"):
		_place(streams["down"], Vector2(cursor_x + ARROW_SIDE, ARROW_DOWN_Y), true)
	if streams.has("up"):
		_place(streams["up"], Vector2(cursor_x + ARROW_SIDE, ARROW_UP_Y), true)


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


## The font's glyph codes for a string: letters, digits and the symbols (anything else is a blank), as library.gd does.
func _bytes(string: String) -> Array:
	var out: Array = []
	for c in string:
		if SYMBOLS.has(c):
			out.append(SYMBOLS[c])
			continue
		var code := c.unicode_at(0)
		var sjis := 0
		if code >= 97 and code <= 122:
			sjis = 0x8281 + code - 97
		elif code >= 65 and code <= 90:
			sjis = 0x8260 + code - 65
		elif code >= 48 and code <= 57:
			sjis = 0x824F + code - 48
		elif code == 33:
			sjis = 0x8149
		out.append(glyph_codes.get(sjis, 0))
	return out


func _price() -> int:
	return int(cards.card(card).get("starchips", 0))


## The step for the count-down: a tenth of the rest, then a twentieth, thirtieth and fortieth from 100, 1000 and 10000; never 0.
static func countdown_step(rest: int) -> int:
	var step := 1
	if rest >= 10:
		step = rest / 10
	if rest >= 100:
		step = rest / 20
	if rest >= 1000:
		step = rest / 30
	if rest >= 10000:
		step = rest / 40
	return maxi(step, 1)


## The prompt in its window. 226 is the game's own string; 227 to 229 are written from the game's words with the card number and
## its price in them. A choice shows its cursor beside the option it is on.
func _show_prompt(id: int) -> void:
	prompt_id = id
	_clear(prompt_node)
	var bytes: Array = []
	if id == STRING_ENTER:
		bytes = text.string_bytes(STRING_ENTER)
	else:
		bytes = _bytes("CARD NUMBER %03d" % card)
		bytes.append(0xFE)
		bytes.append_array(_bytes("x%d" % _price()))
		bytes.append(0xFE)
		if id == STRING_ENTERED:
			bytes.append_array([0xF8, 0x0A, BLUE_TEXT])
			bytes.append_array(_bytes("This 'PASSWORD'"))
			bytes.append(0xFE)
			bytes.append_array(_bytes("has already"))
			bytes.append(0xFE)
			bytes.append_array(_bytes("been entered!"))
		else:
			if id == STRING_NOT_ENOUGH:
				bytes.append_array([0xF8, 0x0A, RED])
			bytes.append_array(_bytes("EXCHANGE"))
			if id == STRING_NOT_ENOUGH:
				bytes.append_array([0xF8, 0x0A, 0])
			bytes.append(0xFE)
			bytes.append_array(_bytes("QUIT"))
		bytes.append(0xFF)
	text.layout(prompt_node, bytes, BOX, TEXT_ADVANCE, 0, sharp, true)
	if id == STRING_EXCHANGE or id == STRING_NOT_ENOUGH:
		text.layout(prompt_node, _bytes(">"), Vector2(BOX.x - 8, BOX.y + TEXT_LINE * (2 + choice)), TEXT_ADVANCE, 0, sharp, true)
	window.visible = prompt_node.get_child_count() > 0


## The card's kind from its type: the frame stream and the back it uses (the spell and trap frames share one stream, coloured per kind).
func _card_kind(data: Dictionary) -> String:
	match data.get("type", ""):
		"Magic":
			return "magic"
		"Equip":
			return "equip"
		"Trap":
			return "trap"
		"Ritual":
			return "ritual"
	return "monster"


## A card_ui piece with its top-left at `at` (plus the piece's own offset), added to the card's front.
func _ui(name: String, at: Vector2, parent: Node2D) -> void:
	if not card_ui.has(name):
		return
	var entry: Dictionary = card_ui[name]
	var image := Image.load_from_file(CARD_UI + str(entry["file"]))
	if image == null:
		return
	# the opaque texels are laid over the frame, the card view's inks (the plates' ramp) subtracted from it
	var parts: Array = CardView.split_ink(image)
	for part in [[parts[0], sharp], [parts[1], plate_subtract]]:
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.texture = ImageTexture.create_from_image(part[0])
		sprite.position = at + Vector2(float(entry["x"]), float(entry["y"]))
		sprite.material = part[1]
		parent.add_child(sprite)


## A stat as four digit cells right-aligned on `at`, the leading zeros left blank.
func _stat_digits(value: int, at: Vector2, parent: Node2D) -> void:
	var text := str(clampi(value, 0, 9999)).lpad(4, " ")
	for i in text.length():
		if text[i] != " ":
			_ui("digit_" + text[i], at + Vector2(i * 6, 0), parent)


## Builds the card's front for the card the password named: the frame of its kind (animated), the picture, the name, the
## attribute ball, the level stars and, for a monster, ATK and DEF; for a spell or trap its label.
func _build_card() -> void:
	_clear(card_front)
	card_streams.clear()
	var data: Dictionary = cards.card(card)
	var kind := _card_kind(data)
	var layout := _layout()
	var frames: Dictionary = layout.get("card_frame", {})
	if frames.has(kind):
		# the first frame is the whole frame; the later frames are its partial animation, which is not drawn yet
		var entry: Dictionary = frames[kind].duplicate()
		entry["order"] = [[0, 0]]
		var stream := _make_stream(card_front, entry, 0)
		_place(stream, Vector2.ZERO, true)
		card_streams.append(stream)
	var art: Dictionary = cards.art(card)
	var picture := Sprite2D.new()
	picture.centered = false
	picture.position = PICTURE_AT
	picture.material = sharp
	ModArt.apply(picture, art)
	card_front.add_child(picture)
	var plate := Image.load_from_file(NAMEPLATE + "%03d.png" % card)
	if plate != null:
		var name_sprite := Sprite2D.new()
		name_sprite.centered = false
		name_sprite.texture = ImageTexture.create_from_image(CardView.split_ink(plate)[1])
		name_sprite.position = NAME_AT
		name_sprite.material = plate_subtract   # subtracted from the frame: the letters come out dark on the bar
		card_front.add_child(name_sprite)
	var attribute := "attribute_" + str(data.get("attribute", "")).to_lower()
	match data.get("type", ""):
		"Magic", "Equip", "Ritual":
			attribute = "attribute_spell"
		"Trap":
			attribute = "attribute_trap"
	_ui(attribute, ATTRIBUTE_AT, card_front)
	if kind == "monster":
		for i in clampi(int(data.get("level", 0)), 0, 12):
			_ui("level_star", STARS_AT + Vector2(-9 * i, 0), card_front)
		_ui("label_atk", ATK_AT, card_front)
		_stat_digits(int(data.get("attack", 0)), Vector2(97, 157), card_front)
		_ui("label_def", DEF_AT, card_front)
		_stat_digits(int(data.get("defense", 0)), Vector2(97, 171), card_front)
	else:
		var label := "label_normal_magic"
		if kind == "trap":
			label = "label_trap"
		elif kind == "equip":
			label = "label_equip_magic"
		_ui(label, Vector2(4, 0), card_front)
	card_back_sprite.texture = _back_texture()


## The card turns about its centre with the preview's phase: 128 is its back, 0 its front, the cosine of the turn is its width.
## The card's back: stream frame 2 of its frame, the monster frame's back, which the reference shows at rest (the other kinds
## use the same back until their own is located).
func _back_texture() -> Texture2D:
	var file := PICS + "card_frame_monster_2.png"
	var image := Image.load_from_file(file)
	return ImageTexture.create_from_image(image) if image != null else null


func _draw_card() -> void:
	card_holder.visible = true
	var turn := float(phase) / REVEAL * PI
	var width := cos(turn)
	card_holder.scale = Vector2(width if absf(width) > 0.01 else 0.01, 1.0)
	var showing_back := width < 0.0
	card_front.visible = not showing_back
	card_back_sprite.visible = showing_back


# ---- input -------------------------------------------------------------------------------------------------------------

func _input_state() -> Dictionary:
	var down := {
		"left": Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT),
		"right": Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT),
		"up": Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP),
		"down": Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN),
		"confirm": Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER) \
			or Input.is_key_pressed(KEY_KP_ENTER) or Input.is_joy_button_pressed(0, JOY_BUTTON_A) or Input.is_joy_button_pressed(0, JOY_BUTTON_X),
		"cancel": Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_BACKSPACE) \
			or Input.is_joy_button_pressed(0, JOY_BUTTON_B),
	}
	var pressed := {}
	for key in ["confirm", "cancel"]:
		if down[key] and not held.get(key, false):
			pressed[key] = true
		held[key] = down[key]
	if cancel_click:
		pressed["cancel"] = true
		cancel_click = false
	return {"down": down, "pressed": pressed}


## A held direction fires on its first frame and then every REPEAT_RATE frames once REPEAT_DELAY frames have passed.
func _fires(key: String, down: Dictionary) -> bool:
	var count: int = repeat.get(key, 0)
	if not down.get(key, false):
		repeat[key] = 0
		return false
	count += 1
	repeat[key] = count
	return count == 1 or (count > REPEAT_DELAY and (count - REPEAT_DELAY) % REPEAT_RATE == 0)


func _gui_input(event: InputEvent) -> void:
	if not ready_ok:
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		wheel_pending += 1
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		wheel_pending -= 1
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		cancel_click = true
	elif event.button_index == MOUSE_BUTTON_LEFT:
		click_at = (event.position - world.position) / world.scale
		click_pending = true
	elif (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN) and state == "entry":
		# the wheel changes the digit under the cursor as Up and Down do (it waits for the cursor's slide, as they do)
		var step := -1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1
		wheel_steps = clampi(wheel_steps + step, -10, 10)


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible:
		return
	frame += 1
	for key in streams:
		if streams[key] is Dictionary:
			_tick_stream(streams[key])
	for stream in card_streams:
		_tick_stream(stream)
	_tick_cursor()
	var input := _input_state()
	match state:
		"entry":
			_update_entry(input)
		"reveal":
			_update_reveal()
		"prompt":
			_update_prompt(input)
		"paid":
			_update_paid()
		"away":
			_update_away()


## The cursor slides from where it was to its digit over CURSOR_TWEEN ticks; the arrows travel with it.
func _tick_cursor() -> void:
	if tween_left <= 0:
		return
	tween_left -= 1
	var target := CURSOR_ORIGIN.x + index * DIGIT_CELL
	cursor_x = lerpf(cursor_from, target, float(CURSOR_TWEEN - tween_left) / CURSOR_TWEEN)
	_place_cursor()


## Starts the slide to the digit under the cursor.
func _slide() -> void:
	cursor_from = cursor_x
	tween_left = CURSOR_TWEEN


func _update_entry(input: Dictionary) -> void:
	var down: Dictionary = input["down"]
	var pressed: Dictionary = input["pressed"]
	if tween_left > 0:
		# the game's cursor takes its input only once it has arrived (the wheel and clicks wait with it)
		click_pending = false
		return
	if pressed.has("cancel"):
		sound.emit(8)
		closed.emit()
		return
	if click_pending:
		click_pending = false
		var cell := _digit_at(click_at)
		if cell >= 0:
			if cell == index:
				_raise_digit()
			else:
				index = cell
				_slide()
				sound.emit(47)
			return
		if WINDOW.has_point(click_at):
			pressed["confirm"] = true
	if wheel_pending != 0:
		var steps := wheel_pending
		wheel_pending = 0
		for i in absi(steps):
			if steps > 0:
				_raise_digit()
			else:
				_lower_digit()
	if down.get("left", false):
		_move_index(-1)
	elif down.get("right", false):
		_move_index(1)
	if _fires("up", down):
		_raise_digit()
	if _fires("down", down):
		_lower_digit()
	if wheel_steps != 0:
		if wheel_steps < 0:
			_raise_digit()
		else:
			_lower_digit()
		wheel_steps -= signi(wheel_steps)
	if pressed.has("confirm"):
		_lookup()


func _digit_at(at: Vector2) -> int:
	if at.y < CURSOR_ORIGIN.y or at.y > CURSOR_ORIGIN.y + 32:
		return -1
	var cell := int(floor((at.x - CURSOR_ORIGIN.x) / DIGIT_CELL))
	return cell if cell >= 0 and cell < DIGITS else -1


func _move_index(step: int) -> void:
	var moved := clampi(index + step, 0, DIGITS - 1)
	if moved == index:
		return
	index = moved
	_slide()
	sound.emit(47)


func _raise_digit() -> void:
	digits[index] = (int(digits[index]) + 1) % 10
	sound.emit(7)
	_refresh_digits()


func _lower_digit() -> void:
	digits[index] = (int(digits[index]) + 9) % 10
	sound.emit(7)
	_refresh_digits()


## Cross: the eight digits are looked up; no card is a refusal (9), a card goes on to its reveal (48).
func _lookup() -> void:
	var key := ""
	for d in digits:
		key += str(int(d))
	var id: int = ids_by_password.get(key, 0)
	if id == 0:
		sound.emit(9)
		return
	card = id
	sound.emit(48)
	phase = REVEAL
	_build_card()
	state = "reveal"


func _update_reveal() -> void:
	phase -= 8
	_draw_card()
	if phase <= 0:
		phase = 0
		sound.emit(12)
		_begin_prompt()


## Case 2: a card already entered is refused with 229; a balance short of its price shows 228 (EXCHANGE locked); otherwise 227.
func _begin_prompt() -> void:
	_refresh_starchips()
	if GameState.test_flag(PASSWORD_USED_BASE + card):
		choice = CHOICE_QUIT
		locked = false
		_show_prompt(STRING_ENTERED)
	elif GameState.starchips < _price():
		choice = CHOICE_QUIT
		locked = true
		_show_prompt(STRING_NOT_ENOUGH)
	else:
		choice = CHOICE_EXCHANGE
		locked = false
		_show_prompt(STRING_EXCHANGE)
	state = "prompt"


func _update_prompt(input: Dictionary) -> void:
	var down: Dictionary = input["down"]
	var pressed: Dictionary = input["pressed"]
	if prompt_id == STRING_ENTERED:
		if pressed.has("confirm") or pressed.has("cancel") or click_pending:
			click_pending = false
			_leave()
		return
	if click_pending:
		click_pending = false
		var line := int(floor((click_at.y - BOX.y) / TEXT_LINE)) - 2
		if line == CHOICE_EXCHANGE or line == CHOICE_QUIT:
			if line == CHOICE_EXCHANGE and locked:
				sound.emit(9)
				return
			choice = line
			pressed["confirm"] = true
	if pressed.has("cancel"):
		_leave()
		return
	if not locked and (_fires("up", down) or _fires("down", down)):
		choice = CHOICE_QUIT if choice == CHOICE_EXCHANGE else CHOICE_EXCHANGE
		sound.emit(7)
		_show_prompt(prompt_id)
	if pressed.has("confirm"):
		if choice == CHOICE_EXCHANGE and not locked:
			_award()
		else:
			_leave()


## The card's password is marked as used (its flag is base + id) and the card goes to the chest; the price counts down next.
func _award() -> void:
	GameState.write_flag(PASSWORD_USED_BASE + card)
	GameState.award_card(card)
	remaining = _price()
	state = "paid"
	_clear(prompt_node)
	window.visible = false


## Case 3: the balance goes down by the step each frame until the price is paid (a free card pays nothing).
func _update_paid() -> void:
	if remaining > 0:
		var step := countdown_step(remaining)
		remaining -= step
		GameState.starchips -= step
		_refresh_starchips()
	if remaining <= 0:
		remaining = 0
		state = "away"


func _leave() -> void:
	state = "away"
	phase = 0
	sound.emit(8)


## Case 4: the card slides away and the entry prompt comes back.
func _update_away() -> void:
	phase += 8
	_draw_card()
	if phase >= REVEAL:
		phase = REVEAL
		card = 0
		_show_prompt(STRING_ENTER)
		state = "entry"
