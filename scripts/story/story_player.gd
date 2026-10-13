extends Control
## The campaign's story scenes: the script VM (the story tick and its opcodes) over the event script bank, the story pictures and
## the dialog box with the game's text engine. Steps at 60 Hz. The script and its pictures come from tools/extract.py --screens.
##
## Opcodes handled: 1 load image, 2 show dialog, 3 story flag, 4/5 stage and show image, 6 viewport tween, 8 open the campaign
## map, 9 show a speaker bust, 10 sound, 11 fade BGM, 12 jump, 13 the card shop's menu, 16 fade out, 17 duel result, 20 wait,
## 22 return to the menu.

signal finished(kind: String, argument: int)    # "map", "menu", "loaded_menu", "duel", "gameover", "credits"
signal build_deck_requested                     # the card shop's BUILD DECK: the screen opens the deck editor and answers build_deck_returned
signal build_deck_returned
signal notice_requested(string_id: int)         # a notice box (SAVING... or SAVE INCOMPLETE!): the screen shows it and answers notice_closed
signal notice_closed
signal sound(effect: int)
signal music(id: int)           # the BGM play from the text (F8 0E, and F8 0F's track): the audio plays it
var audio = null                 # the game audio (set by the boot): the duel track and the fade wait
signal music_fade(step: int)    # the BGM fade-out / the BGM fade-out with a step from the text (F8 11; step 0 is the default)
signal run_done                 # the script VM returned (the scene ended or halted): tests/story_smoke.gd waits for it

## Test hooks (tests/story_smoke.gd only; none is set in play). test_skip stands for holding Shift, test_choice answers every
## choice (called with the line count and the lines above it, returns the pick), and while `auditing` the events of a run are
## counted into `audit` (see _note). selected_card is the card the game's selection holds: the card F8 00 names (0: none selected).
static var test_skip := false
static var test_choice: Callable = Callable()
static var auditing := false
static var audit: Dictionary = {}
static var selected_card := 0
static var test_press := false       # the confirm key is held (the harness toggles it: the non-skip run)
static var glyph_log: Array = []     # while auditing: [code, page, printable, dropped] for every glyph the text places or drops

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const GLYPH_FX := preload("res://scripts/ui/glyph_fx.gd")
const GLYPH_EXIT := preload("res://scripts/ui/glyph_exit.gd")
const TextBoxBg := preload("res://scripts/ui/text_box_bg.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const GameAudio := preload("res://scripts/system/game_audio.gd")
const TouchControls := preload("res://scripts/system/touch_controls.gd")
const DIR := "res://assets/screens/story/"
const TEXT_DIR := "res://assets/screens/"
const FADE_STEP := 12
const BOX := Rect2(16, 176, 288, 48)
const ADVANCE := Vector2(8, 12)
const DEFEATED_FLAG_BASE := 0x1F       # the defeated-duelist flag base
const FREE_DUEL_FLAG_BASE := 0x6E0     # the Free Duel unlock flag base

var scene_index := 0x30
var ended := false         # the text itself ended the scene (a duel or the map opened from inside a dialog)
var text := GameText.new()
var event_script := PackedByteArray()
var bank := PackedByteArray()
var offsets: Array = []
var world := Node2D.new()
var sharp: ShaderMaterial
var picture := Sprite2D.new()
var frame := Sprite2D.new()
var portrait := Sprite2D.new()
var shade := ColorRect.new()
var text_layer := Node2D.new()
var arrow := Sprite2D.new()
var arrow_layout: Dictionary = {}
var arrow_textures: Array = []
var arrow_tick := 0
var arrow_wanted := false
var portraits: Dictionary = {}
var pictures: Dictionary = {}
var busts: BustEffect = BustEffect.new()   # the speaker busts (both slots' records and their layers)
var fade := 255            # the picture's brightness (the shade is the opposite)
var ready_ok := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if GameState.flags.is_empty():
		GameState.reset()
	if not text.load_all():
		return
	event_script = FileAccess.get_file_as_bytes(DIR + "script.bin")
	bank = FileAccess.get_file_as_bytes(TEXT_DIR + "text_bank.bin")
	var data = JSON.parse_string(FileAccess.get_file_as_string(TEXT_DIR + "text.json"))
	offsets = data["offsets"]
	if event_script.is_empty() or bank.is_empty():
		return
	sharp = ScreenFit.make_material()
	add_child(world)
	add_to_group("fit")
	get_viewport().size_changed.connect(refit)
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(320, 240)
	world.add_child(black)
	picture.centered = false
	picture.material = sharp
	world.add_child(picture)
	busts.attach(world)
	world.move_child(busts.root, picture.get_index() + 1)   # over the picture, under the dialog frame
	frame.centered = false
	frame.material = sharp
	frame.texture = _texture(DIR + "frame.png")
	world.add_child(frame)
	portrait.centered = false
	portrait.material = sharp
	portrait.position = Vector2(240, 96)
	world.add_child(portrait)
	world.add_child(text_layer)
	arrow.centered = false
	arrow.material = sharp
	arrow.visible = false
	world.add_child(arrow)
	var arrow_json = JSON.parse_string(FileAccess.get_file_as_string(TEXT_DIR + "dialog_arrow/layout.json"))
	if typeof(arrow_json) == TYPE_DICTIONARY:
		arrow_layout = arrow_json
		for i in (arrow_json["frames"] as Array).size():
			arrow_textures.append(_texture(TEXT_DIR + "dialog_arrow/%d.png" % i))
	shade.size = Vector2(320, 240)
	shade.color = Color(0, 0, 0, 0)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world.add_child(shade)

	ScreenFit.pass_mouse(self)
	ready_ok = true
	refit()
	_run.call_deferred()


func refit() -> void:
	ScreenFit.apply(world, size)


static func _texture(path: String) -> Texture2D:
	return ModArt.texture(path)


## Holding Shift skips: every wait shrinks to (almost) nothing, the text appears at once, pages turn by themselves and fades,
## tweens, pauses and shakes jump to their end. A choice always waits for the player: skipping stops there until Shift is
## let go. A skip is free of the confirm key, so it never answers a prompt by itself.
func _skipping() -> bool:
	return test_skip or Input.is_key_pressed(KEY_SHIFT)


var skip_budget := 0              # waits that may finish at once inside one physics frame while skipping


func _frames(count: int) -> void:
	if _skipping():
		# a run of short waits (a glyph per frame, a fade step, a pause) collapses into a few frames
		if skip_budget > 0:
			skip_budget -= 1
			return
		skip_budget = 24
		await get_tree().physics_frame
		arrow_tick += 1
		_update_arrow()
		_update_skip_hint()
		return
	for i in maxi(count, 0):
		await get_tree().physics_frame
		arrow_tick += 1
		_update_arrow()
		_update_skip_hint()


var skip_hint: Label
var hint_frames := 0
var choice_open := false          # a choice's lines are on screen (its wheel steps count only then)
var wheel_steps := 0              # mouse wheel notches during a choice: negative up, positive down; one line each


## A small label in the top-right corner: a faint reminder for the first seconds of a scene, bright while skipping.
func _update_skip_hint() -> void:
	if not is_instance_valid(self) or not is_inside_tree():
		return
	if skip_hint == null:
		var layer := CanvasLayer.new()
		layer.layer = 60
		skip_hint = Label.new()
		skip_hint.add_theme_font_size_override("font_size", 16)
		skip_hint.add_theme_color_override("font_outline_color", Color.BLACK)
		skip_hint.add_theme_constant_override("outline_size", 5)
		skip_hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		skip_hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		skip_hint.offset_top = 8
		skip_hint.offset_right = -12
		skip_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(skip_hint)
		add_child(layer)
	hint_frames += 1
	if _skipping():
		skip_hint.text = ">> SKIP >>"
		skip_hint.add_theme_color_override("font_color", Color(1, 0.95, 0.3))
		skip_hint.visible = true
	elif hint_frames < 360:
		skip_hint.text = "Hold SHIFT to skip"
		skip_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
		skip_hint.visible = true
	else:
		skip_hint.visible = false


func _update_arrow() -> void:
	if not is_instance_valid(arrow):
		return   # a fade or text coroutine can still tick after the scene was freed
	arrow.visible = arrow_wanted and not arrow_textures.is_empty()
	if not arrow.visible:
		return
	var sequence: Array = arrow_layout["sequence"]
	var step := int(arrow_tick / int(arrow_layout["duration"])) % sequence.size()
	var index: int = int(sequence[step])
	arrow.texture = arrow_textures[index]
	var o: Dictionary = arrow_layout["frames"][index]
	arrow.position = Vector2(BOX.position.x + BOX.size.x - 16 + int(o["x"]), BOX.position.y + BOX.size.y - 16 + int(o["y"]))


func _pressed_confirm() -> bool:
	if test_press:
		return true
	return Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER) \
		or TouchControls.game_pointer_held() or Input.is_joy_button_pressed(0, JOY_BUTTON_A)


func _wait_press() -> void:
	if _skipping():
		await _frames(1)
		return
	while _pressed_confirm():
		await _frames(1)
	while not _pressed_confirm():
		await _frames(1)
	sound.emit(11)
	while _pressed_confirm():
		await _frames(1)


func _u16(at: int) -> int:
	return int(event_script[at]) | (int(event_script[at + 1]) << 8)


func _fade_to(target: int) -> void:
	if _skipping():
		fade = target
		shade.color = Color(0, 0, 0, 1.0 - fade / 255.0)
		await _frames(1)
		return
	while fade != target:
		fade = clampi(fade + (FADE_STEP if target > fade else -FADE_STEP), 0, 255)
		shade.color = Color(0, 0, 0, 1.0 - fade / 255.0)
		await _frames(1)


## The duel result opcode's picture: the title logo over the hieroglyph backdrop, baked by tools/extract.py into
## assets/screens/logo/ (layout.json gives the logo's origin, the backdrop panels and the fill). The screen fades in from black, holds,
## then fades out to black, and the script goes on. The logo is one still frame: the logo object's stream starts with a hold of 0, which
## parks it on that frame. The fill is a subtractive gradient (black at the top, white at the bottom): the bottom of the backdrop darkens.
## Timing: the game waits for the track that is playing to end (SD status 0x80). This opcode starts no track and the port has no music,
## so the hold is the opcode's operand in frames (0x1E0 = 480, 8 seconds): the one number the script gives for this picture (the game
## keeps it at 0x8009B29C). The fades are the game's band fades: 80 frames in (step 4 over 30 bands, 255 levels) and 48 out (step 8);
## the port fades the whole picture as one shade, where the game wipes it in bands.
const LOGO_DIR := "res://assets/screens/logo/"
const LOGO_FADE_IN := 80
const LOGO_FADE_OUT := 48


func _result_panel(hold: int) -> void:
	var layout = JSON.parse_string(FileAccess.get_file_as_string(LOGO_DIR + "layout.json"))
	if typeof(layout) != TYPE_DICTIONARY:
		return
	var shown := [picture, frame, portrait, text_layer, arrow]
	var was_visible := []
	for node in shown:
		was_visible.append(node.visible)
		node.visible = false
	var added: Array[Node] = []
	var backdrop := ModArt.plain_texture(LOGO_DIR + layout["backdrop"]["file"])   # the panels are regions in the baked picture's pixels
	for panel in layout["backdrop"]["panels"]:
		var part := Sprite2D.new()
		part.centered = false
		part.texture = backdrop
		part.region_enabled = true
		part.region_rect = Rect2(0, 0, panel[2], panel[3])
		part.position = Vector2(panel[0], panel[1])
		part.material = sharp
		added.append(part)
	var ramp := Image.create(1, 240, false, Image.FORMAT_RGBA8)
	for y in 240:
		var v := int(round(255.0 * (y + 0.5) / 240.0))
		ramp.set_pixel(0, y, Color8(v, v, v, 255))
	var fill := Sprite2D.new()
	fill.centered = false
	fill.texture = ImageTexture.create_from_image(ramp)
	fill.position = Vector2(layout["fill"]["x"], layout["fill"]["y"])
	fill.scale = Vector2(layout["fill"]["width"], layout["fill"]["height"] / 240.0)
	var subtract := CanvasItemMaterial.new()
	subtract.blend_mode = CanvasItemMaterial.BLEND_MODE_SUB
	fill.material = subtract
	added.append(fill)
	var logo := Sprite2D.new()
	logo.centered = false
	logo.texture = _texture(LOGO_DIR + layout["logo"]["file"])
	logo.position = Vector2(layout["logo"]["x"], layout["logo"]["y"])
	logo.material = sharp
	added.append(logo)
	for node in added:
		world.add_child(node)
	world.move_child(shade, -1)
	await _result_fade(255, LOGO_FADE_IN)
	await _frames(hold)
	await _result_fade(0, LOGO_FADE_OUT)
	for node in added:
		node.queue_free()
	for i in shown.size():
		shown[i].visible = was_visible[i]


## Moves the picture's brightness to target over the given frames (the shade is its opposite); a skip jumps to the end.
func _result_fade(target: int, frames: int) -> void:
	if _skipping():
		fade = target
		shade.color = Color(0, 0, 0, 1.0 - fade / 255.0)
		await _frames(1)
		return
	var start := fade
	for i in frames:
		fade = clampi(roundi(lerpf(start, target, float(i + 1) / frames)), 0, 255)
		shade.color = Color(0, 0, 0, 1.0 - fade / 255.0)
		await _frames(1)


## The script VM: one opcode at a time from the scene's offset table entry.
var test_only_dialog := -1          # >= 0: the test runs this one text box and nothing else
var _page := 0


func _run() -> void:
	if test_only_dialog >= 0:
		await _dialog(test_only_dialog)
	else:
		await _vm()
	run_done.emit()


## The script's opcodes from the scene's offset table entry, until a halt, a return to the menu or the map, or a duel.
func _vm() -> void:
	var pc := _u16(scene_index * 2)
	var viewport := Vector2.ZERO
	var staged := 0
	while ready_ok:
		var op := int(event_script[pc]) & 0x1F
		pc += 1
		match op:
			0, 14, 15:
				return
			1, 4:
				var word := _u16(pc)
				pc += 2
				if (word & 0x8000) != 0:
					viewport = Vector2(_u16(pc), _u16(pc + 2))
					pc += 4
				if op == 1:
					await _fade_to(0)
					_set_picture(word & 0xFFF, viewport)
					await _fade_to(255)
				else:
					staged = word & 0xFFF
			5:
				await _fade_to(0)
				_set_picture(staged, viewport)
				await _fade_to(255)
			2:
				var word2 := _u16(pc)
				pc += 2
				await _dialog(word2 & 0xFFF, (word2 & 0x8000) == 0)
				if ended:
					return
			3:
				var command := _u16(pc)
				pc += 2
				if (command & 0x4000) != 0:
					GameState.write_flag(command & 0xBFFF)
				else:
					var target := _u16(pc)
					pc += 2
					if GameState.test_flag(command):
						pc = target
			6:
				var tx := _u16(pc)
				var ty := _u16(pc + 2)
				var frames := _u16(pc + 4)
				pc += 6
				await _tween_viewport(Vector2(tx, ty), frames)
				viewport = Vector2(tx, ty)
			8:
				finished.emit("map", event_script[pc])
				return
			9:
				# The show-menu opcode: a speaker bust is put up at once at its resting place (id, flags: bit 7 right slot,
				# low nibble the expression)
				var bust_id := int(event_script[pc])
				var bust_flags := int(event_script[pc + 1])
				pc += 2
				await _bust_menu(bust_id, bust_flags)
			10:
				var control := int(event_script[pc])
				pc += 1
				if (control & 0x3F) == 0:
					var effect := _u16(pc)
					pc += 2
					if (control & 0x40) != 0:
						sound.emit(effect)
				elif (control & 2) != 0:
					pc += 2
			11:
				pc += 1
			12:
				pc = _u16(pc)
			13:
				# The save prompt (the original's op save prompt routine): the card shop's menu. Its operands are the text id of the greeting box (0: none)
				# and the scene index the save keeps. LEAVE SHOP goes on with the script; the other endings finish the scene.
				var shop_text := _u16(pc)
				var shop_scene := _u16(pc + 2)
				pc += 4
				var ending := await _card_shop(shop_text, shop_scene)
				if ending != "":
					finished.emit(ending, 0)
					return
			16:
				pc += 1
				await _fade_to(0)
			17:
				# The duel result opcode: its two-byte operand is kept by the game at 0x8009B29C, and the port holds the title logo for that many
				# frames (see _result_panel). The script goes on with the next command after it (it never ends the scene)
				var hold := _u16(pc)
				pc += 2
				await _result_panel(hold)
			18:
				finished.emit("gameover", 0)
				return
			19:
				finished.emit("credits", 0)
				return
			20:
				var count := _u16(pc)
				pc += 2
				await _frames(count)
			21:
				pc += 2   # a deck that is not complete jumps; the new game's starter deck is, so it falls through
			22:
				finished.emit("menu", 0)
				return
			_:
				_note("vm:unknown_opcode:%02x" % op)
				return


func _set_picture(id: int, viewport: Vector2) -> void:
	if not pictures.has(id):
		pictures[id] = _texture(DIR + "scenes/%03X.png" % id)
		if pictures[id] == null:
			_note("picture:missing:%03x" % id)
	picture.texture = pictures[id]
	picture.position = -viewport


func _tween_viewport(target: Vector2, frames: int) -> void:
	var start := -picture.position
	for i in maxi(frames, 1):
		picture.position = -start.lerp(target, float(i + 1) / maxf(frames, 1))
		await _frames(1)


func _clear_text() -> void:
	for child in text_layer.get_children():
		child.queue_free()


## The text state's clear (the game's states 2 and 3): every glyph on the box lets go with its exit effect (glyph_exit.gd), then the
## box is empty. `choice` is the choice clear (state 3): each glyph waits its own delay first. The clear comes one frame after the
## last glyph is gone, as the state resets on the step after its entries leave.
func _leave_text(choice: bool) -> void:
	var owned := {}
	for child in text_layer.get_children():
		if child.get_script() == GLYPH_FX:
			owned[child.sprite] = true
	var exits: Array = []
	for child in text_layer.get_children():
		var sprite: Sprite2D = null
		if child.get_script() == GLYPH_FX:
			sprite = child.sprite
			child.queue_free()   # a glyph still coming in leaves from where it stands
		elif child is Sprite2D and not owned.has(child):
			sprite = child
		if sprite == null:
			continue
		var fx := Polygon2D.new()
		fx.set_script(GLYPH_EXIT)
		fx.sprite = sprite
		fx.choice = choice
		fx.local = sprite.position - _origin
		text_layer.add_child(fx)
		exits.append(fx)
	# the box is cleared only when every exit has run its course: a skip collapses the frame waits, and clearing under a
	# running exit would free its sprite (glyph_exit.gd stops itself if that happens, but the wait keeps it from happening)
	var guard := 0
	while _exits_running(exits) and guard < 4096:
		await _frames(1)
		guard += 1
	await _frames(1)
	_clear_text()


func _exits_running(exits: Array) -> bool:
	for fx in exits:
		if is_instance_valid(fx) and not fx.is_queued_for_deletion():
			return true
	return false


func _bank_u16(at: int) -> int:
	return int(bank[at & 0xFFFF]) | (int(bank[(at + 1) & 0xFFFF]) << 8)


const NAME_STREAM := 0x125A     # where the text refers to the player's name (a stream of glyph codes ended by 0xFF)


## The player's name is written where the text's name stream reads it: one glyph code per entered word.
func _write_name() -> void:
	var at := NAME_STREAM
	var last := GameState.player_name.size()
	while last > 0 and int(GameState.player_name[last - 1]) == 0:
		last -= 1                      # the trailing blanks of a short name are not part of it
	for i in last:
		var w := int(GameState.player_name[i])
		bank[at] = text.code_for_sjis(w) if w != 0 else 0
		at += 1
	bank[at] = 0xFF


## Counts an event of the run (only while the audit harness runs; see the test hooks above).
func _note(event: String) -> void:
	if auditing:
		audit[event] = int(audit.get(event, 0)) + 1


# ---- the text box: the streams, the pen and the control bytes -----------------------------------------------------------
# A string runs on a stack of streams (the game's stream slots). Each frame is {data, pos}: data is the text bank (the dialog's
# own bytes, and the jump targets inside it) or a string's bytes pushed by F8 00 and F8 09. A jump moves the frame's position.

const ICON_ADVANCE := 16        # an icon (F8 08, F8 0B) moves the pen this far
const STREAM_DEPTH := 16        # the nested stream pushes the stack takes

var _stack: Array = []          # the streams in use; the last one is read
var _pen_x := 0.0
var _pen_y := 0.0
var _color := 0                 # the glyphs' colour ramp (F8 0A)
var _adv_x := 8                 # a glyph's advance (F8 05's first operand)
var _line_h := 12               # the line height (F8 05's second operand)
var _origin := Vector2.ZERO
var _choice := {"active": false, "count": 0, "before": 0, "lines": 0, "pick": 0}
var _limit := 0                 # F8 07's glyph count: read and kept; the reveal here does not stop on it
var _saved_track := 0           # the BGM the F8 0F command saves and replays
var jump_select := [0, 0]       # the selectors of F8 17 and F8 18: a duel result sets them in the game
var string_global := -1         # the string F8 09 inserts (the opponent's name after a duel): none is known here


func _at(frame: Dictionary, offset: int) -> int:
	var data: PackedByteArray = frame["data"]
	var at := (int(frame["pos"]) + offset) & 0xFFFF
	return int(data[at]) if at < data.size() else 0xFF


func _word(frame: Dictionary, offset: int) -> int:
	return _at(frame, offset) | (_at(frame, offset + 1) << 8)


func _skip(frame: Dictionary, count: int) -> void:
	frame["pos"] = int(frame["pos"]) + count


func _signed(value: int) -> int:
	return value - 256 if value >= 128 else value


## One text box run: the string's script from the bank, glyph by glyph, with the game's reveal effect. `hold` is the box's end rule:
## a box with no 0x8000 operand (`hold`) waits at its end for the player's confirm with the blinking arrow in its corner; with
## 0x8000 (`hold` false) the script goes on at once and the box stays on screen, as the game keeps it (the box's choice bit is clear).
func _dialog(id: int, hold := true) -> void:
	busts.live = true
	_write_name()
	_clear_text()
	_note("dialog:%d" % id)
	var index := id - 0x100 if id >= 0x500 else id
	_stack = [{"data": bank, "pos": int(offsets[index])}]
	_pen_x = 0.0
	_pen_y = 0.0
	_color = 0
	_adv_x = int(ADVANCE.x)
	_line_h = int(ADVANCE.y)
	_origin = Vector2(BOX.position.x, BOX.position.y - 2)
	_choice = {"active": false, "count": 0, "before": 0, "lines": 0, "pick": 0}
	_limit = 0
	while not _stack.is_empty() and not ended:
		var frame: Dictionary = _stack[-1]
		var b := _at(frame, 0)
		_skip(frame, 1)
		if b < 0xF0:
			await _glyph(b)
		else:
			await _control(b, frame)
	if not ended and hold:
		await _page_wait()
		_clear_text()
		busts.live = false


## The primary control bytes F0 to FF: F0 to F5 are the two-byte glyph codes, the rest are the commands the game's table has.
func _control(b: int, frame: Dictionary) -> void:
	_note("op:%02x" % b)
	match b:
		0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5:
			# an extended glyph: the high part is b - F0 and the low byte follows; past the font's table it is a blank glyph
			var code := ((b - 0xF0) << 8) | _at(frame, 0)
			_skip(frame, 1)
			await _glyph(code)
		0xF6:
			var effect := _at(frame, 0)
			var flags := _at(frame, 1)
			_skip(frame, 2)
			await _display_effect(effect, flags)
		0xF7:
			var state := _at(frame, 0)
			_skip(frame, 1)
			await _text_state(state, frame)
		0xF8:
			var sub := _at(frame, 0)
			_skip(frame, 1)
			await _secondary(sub, frame)
		0xF9:
			_flag_command(frame)
		0xFA:
			await _page_break()
		0xFB:
			_choice_command(frame)
		0xFC:
			_push_stream(frame)
		0xFD:
			frame["pos"] = _word(frame, 0)
		0xFE:
			await _newline()
		0xFF:
			_stack.pop_back()


## One controller picture at the pen (F8 0B): drawn at the pen's line, and the pen moves on 16 pixels whatever the picture is.
func _picture(code: int) -> void:
	var texture := GameText.button_texture(code)
	if texture != null:
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.texture = texture
		sprite.material = sharp
		sprite.position = _origin + Vector2(_pen_x, _pen_y)
		text_layer.add_child(sprite)
	_pen_x += ICON_ADVANCE


## One glyph at the pen. Past the box's right edge the pen starts a new line. A line that would pass the box's bottom waits for a
## page turn, and the glyph that overflowed is dropped, as the game drops it. A code with no picture (0, and the codes past the
## retail font's glyphs) takes its advance and draws nothing.
func _glyph(code: int) -> void:
	if _pen_x >= BOX.size.x:
		_pen_x = 0.0
		_pen_y += _line_h
	if _pen_y + _line_h > BOX.size.y:
		if auditing:
			glyph_log.append([code, _page, text.sjis_of(code) != 0, true])
		await _page_wait()
		_pen_x = 0.0
		_pen_y = 0.0
		return
	if auditing:
		glyph_log.append([code, _page, text.sjis_of(code) != 0, false])
	busts.pending_kind = _talk_kind(code)
	if text.sjis_of(code) != 0:
		var sprite := text.sprite_for(code, _color, sharp, true)
		sprite.position = _origin + Vector2(_pen_x, _pen_y)
		text_layer.add_child(sprite)
		if not _skipping():
			var fx := Polygon2D.new()
			fx.set_script(preload("res://scripts/ui/glyph_fx.gd"))
			fx.sprite = sprite
			fx.small = true
			text_layer.add_child(fx)
	elif code != 0:
		_note("glyph:no_picture")
	_pen_x += _adv_x
	await _frames(2)


func _page_break() -> void:
	await _page_wait()
	_pen_x = 0.0
	_pen_y = 0.0


## The new line (FE, and F8 29): the choice's lines count up here, and the last one takes the choice.
func _newline() -> void:
	_pen_x = 0.0
	_pen_y += _line_h
	if _choice["active"]:
		_choice["lines"] = int(_choice["lines"]) + 1
		if int(_choice["lines"]) >= int(_choice["count"]):
			_choice["active"] = false
			var before := int(_choice["before"])
			_choice["pick"] = await _choose(before, maxi(int(_choice["count"]) - before, 1))
			# the choice is confirmed: state 3 clears the glyphs with their delayed exit, unless the choice keeps its text (0x40)
			if not bool(_choice.get("keep", false)):
				await _leave_text(true)
				_pen_x = 0.0
				_pen_y = 0.0
	# a line feed onto a line past the box's bottom turns the page itself (the game's new-line rule); the glyph after it starts the
	# next page. Left to the glyph path, that glyph would be the one the page turn dropped.
	if _pen_y + _line_h > BOX.size.y:
		await _page_wait()
		_pen_x = 0.0
		_pen_y = 0.0


## The choice command (FB, and F8 26). With bit 0x80 it is the selected branch: a table of one u16 target per choice follows the
## control byte (and its mask byte). Otherwise a choice starts: the low three bits are the line count, bits 4 and 5 the lines above
## it, and bit 3 means a mask byte follows the control byte.
func _choice_command(frame: Dictionary) -> void:
	var control := _at(frame, 0)
	var mask := 1 if (control & 8) != 0 else 0
	if (control & 0x80) != 0:
		frame["pos"] = _word(frame, 1 + mask + int(_choice["pick"]) * 2)
		return
	_skip(frame, 1 + mask)
	_choice = {"active": true, "count": control & 7, "before": (control >> 4) & 3, "lines": 0, "pick": 0, "keep": (control & 0x40) != 0}
	_note("choice:start")


## The campaign flag command (F9, and F8 24): a write (bit 0x4000), or a test whose true branch is a u16 target.
func _flag_command(frame: Dictionary) -> void:
	var flag := _word(frame, 0)
	if (flag & 0x4000) != 0:
		GameState.write_flag(flag & 0xBFFF)
		_skip(frame, 2)
	else:
		frame["pos"] = _word(frame, 2) if GameState.test_flag(flag) else int(frame["pos"]) + 4


## The stream push (FC, and F8 27): the stream goes on at the u16 in the same bank, and the pushing stream resumes after it.
func _push_stream(frame: Dictionary) -> void:
	var target := _word(frame, 0)
	_skip(frame, 2)
	if _stack.size() < STREAM_DEPTH:
		_stack.append({"data": frame["data"], "pos": target})


## A string from the text (a card's name or description, or a global string) pushed as a stream; it ends at its 0xFF.
func _push_string(id: int) -> void:
	var bytes := PackedByteArray()
	for value in text.string_bytes(id):
		bytes.append(int(value))
	if bytes.is_empty() or bytes[bytes.size() - 1] != 0xFF:
		bytes.append(0xFF)
	if _stack.size() < STREAM_DEPTH:
		_stack.append({"data": bytes, "pos": 0})
	_note("string:push")


## The secondary commands (F8 and the nested F8 23): one sub-opcode, then its own operands. The sizes follow the game's table.
func _secondary(sub: int, frame: Dictionary) -> void:
	_note("f8:%02x" % sub)
	match sub:
		0x00:
			# the card insert: the name (0x20) and the description (0x40) of the selected card are pushed as a stream. The stat
			# kinds and the colour form (0x10) are not modelled, and the story has no selected card of its own.
			var op := _at(frame, 0)
			_skip(frame, 1)
			if (op & 0x10) == 0 and (op & 0x20) != 0 and selected_card > 0:
				_push_string(0x8000 + selected_card)
			elif (op & 0x10) == 0 and (op & 0x20) == 0 and (op & 0x40) != 0 and selected_card > 0:
				_push_string(0xD100 + selected_card)
			else:
				_note("approx:f8_00_card")
		0x01:
			_pen_x = 0.0
			_pen_y += _signed(_at(frame, 0))
			_skip(frame, 1)
		0x02:
			_pen_x += _at(frame, 0)
			_skip(frame, 1)
		0x03:
			# a number from a RAM address (a u32 and a flag byte): the game's value is not held here, so no digits are drawn
			_skip(frame, 5)
			_note("approx:f8_03_number")
		0x04:
			# the glyph cell: 2 is the box's 8 x 12 font, 1 the 8 x 8 font (not in the port's page); both are drawn small
			_skip(frame, 1)
			if _at(frame, -1) == 1:
				_note("approx:f8_04_tiny")
		0x05:
			_adv_x = _at(frame, 0)
			_line_h = _at(frame, 1)
			_skip(frame, 2)
		0x06:
			var pen := _word(frame, 0)
			_pen_x = float(pen - 0x10000 if pen >= 0x8000 else pen)
			_skip(frame, 2)
		0x07:
			_limit = _word(frame, 0)
			_skip(frame, 2)
			_note("approx:f8_07_limit")
		0x08:
			_pen_x += ICON_ADVANCE
			_note("approx:f8_08_icon")
		0x09:
			if string_global >= 0:
				_push_string(string_global)
			else:
				_note("approx:f8_09_no_string")
		0x0A:
			var colour := _at(frame, 0)
			_skip(frame, 1)
			_color = int(text.slots[colour & 15]) if (colour & 0x80) != 0 and text.slots.size() >= 16 else colour
		0x0B:
			# a controller picture (the code is the operand), from the text's own pictures (game_text.gd)
			_picture(_at(frame, 0))
			_skip(frame, 1)
		0x0C:
			_skip(frame, 1)   # the menu layout flag of the box: nothing here reads it
		0x0D:
			# the campaign duel: the opponent, the scene after a win, the scene after a loss, the terrain, then a BGM u16 (not read:
			# the duel starts at once). Packed as opponent | win << 8 | lose << 16 | terrain << 24
			var packed := _at(frame, 0) | (_at(frame, 1) << 8) | (_at(frame, 2) << 16) | (_at(frame, 3) << 24)
			if audio != null:
				audio.duel_bgm = _word(frame, 4)   # the duel's BGM u16: the duel plays it when it starts
			ended = true
			finished.emit("duel", packed)
		0x0E:
			music.emit(_word(frame, 0))
			_skip(frame, 2)
		0x0F:
			var control := _at(frame, 0)
			_skip(frame, 1)
			if (control & 0x3F) != 0:
				music.emit(_word(frame, 0))
				_skip(frame, 2)
			else:
				if (control & 1) != 0:
					music.emit(_saved_track)
				if (control & 2) != 0:
					_saved_track = _word(frame, 0)
					_skip(frame, 2)
				if (control & 4) != 0:
					_saved_track = GameAudio.current_bgm_command   # the driver's copy of the current BGM command
			if (control & 0x80) != 0:
				_note("approx:f8_0f_wait")
		0x10:
			var effect := _word(frame, 0)
			_skip(frame, 2)
			if (effect & 0x8000) != 0:
				_skip(frame, 2)
				_note("approx:f8_10_voice")
			sound.emit(effect & 0x7FFF)
		0x11:
			var fade_raw := _at(frame, 0)
			music_fade.emit(fade_raw & 0x7F)
			_skip(frame, 1)
			if (fade_raw & 0x80) != 0:
				# the driver waits (state 0xD) until the BGM fade has finished
				while audio != null and audio.is_bgm_fading():
					await _frames(1)
		0x12, 0x13, 0x16:
			pass   # the display-object callbacks and the flag clear: nothing to draw here
		0x14:
			ended = true
			finished.emit("map", _at(frame, 0))
		0x15:
			var fade_byte := _at(frame, 0)
			_skip(frame, 1)
			_note("approx:f8_15_fade")
			var fade_out := (fade_byte & 1) != 0
			if (fade_byte & 0x80) != 0:
				await _fade_to(0 if fade_out else 255)
			else:
				_fade_to(0 if fade_out else 255)
		0x17, 0x18:
			var pick_offset: int = jump_select[0] if sub == 0x17 else jump_select[1]
			frame["pos"] = _word(frame, pick_offset * 2)
		0x19:
			var duelist := _at(frame, 0)
			_skip(frame, 1)
			if duelist > 0:
				GameState.write_flag(duelist + DEFEATED_FLAG_BASE)
				GameState.write_flag(duelist + FREE_DUEL_FLAG_BASE)
		0x1A:
			# the choice close (the original's close choice routine): the text state goes to 2, the page clear, so the glyphs leave with their exit
			# effect before the stream goes on; the pen then starts again at the box's top left
			await _leave_text(false)
			_pen_x = 0.0
			_pen_y = 0.0
		0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20:
			# a two-byte glyph with the high part 8: past the font's table, so a blank glyph with its advance
			var low := _at(frame, 0)
			_skip(frame, 1)
			await _glyph(0x800 | low)
		0x21:
			var effect := _at(frame, 0)
			var flags := _at(frame, 1)
			_skip(frame, 2)
			await _display_effect(effect, flags)
		0x22:
			var state := _at(frame, 0)
			_skip(frame, 1)
			await _text_state(state, frame)
		0x23:
			var inner := _at(frame, 0)
			_skip(frame, 1)
			await _secondary(inner, frame)
		0x24:
			_flag_command(frame)
		0x25:
			await _page_break()
		0x26:
			_choice_command(frame)
		0x27:
			_push_stream(frame)
		0x28:
			frame["pos"] = _word(frame, 0)
		0x29:
			await _newline()
		0x2A:
			_stack.pop_back()
		0x2B, 0x2C, 0x2D, 0x2E:
			pass   # the display-object fades: no fade is run for the text here
		_:
			_note("unknown:f8:%02x" % sub)


## The choice lines are on screen: up/down (or the mouse) moves the highlight bar, confirm takes the line.
## the choice input read / the choice highlight; the bar sits 2 above the line like the text (field_18 = 2).
func _choose(before: int, count: int) -> int:
	if test_choice.is_valid():
		await _frames(1)
		_note("choice:%d" % count)
		return clampi(int(test_choice.call(count, before)), 0, count - 1)
	var bar := Polygon2D.new()
	var edge := Color(0.19, 0.19, 0.0)
	var mid := Color(0.75, 0.75, 0.0)
	var top := BOX.position.y - 2.0 + 12.0 * before + 1.0   # the glyphs' rows sit one line-pixel below the cell top
	bar.polygon = PackedVector2Array([Vector2(16, top), Vector2(160, top), Vector2(304, top), Vector2(304, top + 10), Vector2(160, top + 10), Vector2(16, top + 10)])
	bar.vertex_colors = PackedColorArray([edge, mid, edge, edge, mid, edge])
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bar.material = add
	text_layer.add_child(bar)
	var current := 0
	var held := {}
	var last_mouse := get_local_mouse_position()
	while _skipping():
		await _frames(1)       # a skip in progress waits here: the choice is the player's
	wheel_steps = 0
	choice_open = true
	while true:
		await _frames(1)
		var up := Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP)
		var down := Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN)
		if up and not held.get("up", false) and current > 0:
			current -= 1
			sound.emit(6)
		if down and not held.get("down", false) and current < count - 1:
			current += 1
			sound.emit(6)
		if wheel_steps < 0 and current > 0:
			current -= 1
			sound.emit(6)
		elif wheel_steps > 0 and current < count - 1:
			current += 1
			sound.emit(6)
		wheel_steps -= signi(wheel_steps)
		held["up"] = up
		held["down"] = down
		bar.position.y = 12.0 * current
		var mouse := get_local_mouse_position()
		var local: Vector2 = (mouse - world.position) / world.scale
		var line := int(floor((local.y - (BOX.position.y - 2.0)) / 12.0)) - before
		var over := line >= 0 and line < count and local.x >= BOX.position.x and local.x < BOX.position.x + BOX.size.x
		if mouse != last_mouse and over:
			# hovering a line selects it, a click takes it
			if line != current:
				current = line
				sound.emit(6)
				bar.position.y = 12.0 * current
		last_mouse = mouse
		if TouchControls.game_pointer_held():
			if over:
				current = line
				bar.position.y = 12.0 * current
				break
		elif _pressed_confirm():
			break
	sound.emit(11)
	while _pressed_confirm():
		await _frames(1)
	bar.queue_free()
	choice_open = false
	wheel_steps = 0
	return current


## ---- the card shop's menu (opcode 13, the save prompt) ------------------------------------------------------------------------
## The text strings are the game's: 0x11 the four entries (SAVE, BUILD DECK, RETURN TO TITLE, LEAVE SHOP), 0x12 the NO and YES of
## RETURN TO TITLE, 0x1C the notice for a deck that is not complete, 0xD6 SAVING... and 0xCD SAVE INCOMPLETE!. The menu window is the
## game's type 3 box: it slides in from the left (16 frames) at (0x10, 0x38), 120 x 48, with its entries 12 rows apart, and slides
## out again at LEAVE SHOP. The NO / YES window is the type 2 box at (0x90, 0x70). Its fill is a black translucent panel the port draws.
const SHOP_TEXT := 0x11
const SHOP_CONFIRM_TEXT := 0x12
const SHOP_DECK_NOTICE := 0x1C
const SHOP_SAVING := 0xD6
const SHOP_SAVE_FAILED := 0xCD
const SHOP_DECK_SIZE := 40
const SHOP_ROW := 12.0
const SHOP_SLIDE_FRAMES := 16
const SHOP_SLIDE_FROM := -144.0                       # the menu window's offset while it is off to the left (0x10 - 0x90 - 16 px)
## The text rectangles are the original's text box rectangles. A box's text starts 2 pixels above its top, as the
## dialog's does (BOX.y - 2), and its rows are 12 apart.
const SHOP_MENU_ORIGIN := Vector2(16, 54)
const SHOP_MENU_PANEL := Rect2(16, 56, 120, 48)
const SHOP_CONFIRM_ORIGIN := Vector2(144, 110)
const SHOP_CONFIRM_PANEL := Rect2(144, 112, 24, 24)
## The fill is the box's own flagged background (text_box_bg.gd: the hexagon of a box with flags 0x20). Both windows set 0x20.


## The card shop's menu, run from the save prompt opcode. A greeting box (text `text_id`, none when 0) comes first, then the menu
## slides in and waits for a pick. Returns "" when the script goes on (LEAVE SHOP), or the screen to finish with ("loaded_menu" for
## RETURN TO TITLE when the player agrees, after a deck that is complete has been checked). The cursor stays where the last pick was.
func _card_shop(text_id: int, resume_scene: int) -> String:
	if not _deck_complete():
		# the shopkeeper will not open the menu without a complete deck: the notice, then the loaded menu
		sound.emit(0x2A)
		await _dialog(SHOP_DECK_NOTICE)
		sound.emit(8)
		return "loaded_menu"
	if text_id != 0:
		await _dialog(text_id)
	var menu := _shop_window(SHOP_TEXT, SHOP_MENU_ORIGIN, SHOP_MENU_PANEL)
	menu.position.x = SHOP_SLIDE_FROM
	await _shop_slide(menu, 0.0)
	var pick := 0
	while true:
		pick = await _shop_pick(menu, SHOP_MENU_ORIGIN, SHOP_MENU_PANEL, 4, pick)
		match pick:
			0:
				# SAVE: the scene index is written with the state, then the save notice; the menu comes back on SAVE
				sound.emit(7)
				GameState.campaign_scene_index = resume_scene
				await _shop_save()
			1:
				# BUILD DECK: the deck editor opens over the shop and the menu is there again when it is left
				sound.emit(7)
				GameState.campaign_scene_index = resume_scene
				if not test_choice.is_valid():
					build_deck_requested.emit()
					await build_deck_returned
				else:
					_note("shop:build_deck")
			2:
				# RETURN TO TITLE: NO goes back to the menu on this entry, YES leaves for the loaded menu
				sound.emit(7)
				var confirm := _shop_window(SHOP_CONFIRM_TEXT, SHOP_CONFIRM_ORIGIN, SHOP_CONFIRM_PANEL)
				var yes := await _shop_pick(confirm, SHOP_CONFIRM_ORIGIN, SHOP_CONFIRM_PANEL, 2, 0)
				confirm.queue_free()
				if yes == 1:
					menu.queue_free()
					return "loaded_menu"
				pick = 2
			_:
				# LEAVE SHOP: the menu slides away and the script goes on
				sound.emit(8)
				await _shop_slide(menu, SHOP_SLIDE_FROM)
				menu.queue_free()
				return ""
	return ""   # the loop only leaves by a return; this line is for the parser


## A complete deck: the forty ids of the player's deck, none of them empty.
func _deck_complete() -> bool:
	if GameState.deck.size() < SHOP_DECK_SIZE:
		return false
	for i in SHOP_DECK_SIZE:
		if int(GameState.deck[i]) == 0:
			return false
	return true


## SAVE: the state is written (the memory card stand-in) and the notice says so; a failed write says SAVE INCOMPLETE!. A test run
## answers the menu without writing anything.
func _shop_save() -> void:
	if test_choice.is_valid():
		_note("shop:save")
		return
	var ok := GameState.save_game()
	await _shop_notice(SHOP_SAVING if ok else SHOP_SAVE_FAILED)


func _shop_notice(string_id: int) -> void:
	if test_choice.is_valid():
		_note("shop:notice:%x" % string_id)
		return
	notice_requested.emit(string_id)
	await notice_closed


## A menu window: a black translucent panel under its text. The window sits in `world` and moves as one (its root's x is the slide).
func _shop_window(string_id: int, origin: Vector2, panel: Rect2) -> Node2D:
	var window := Node2D.new()
	var back := TextBoxBg.new()
	back.setup(panel)
	window.add_child(back)
	var lines := Node2D.new()
	window.add_child(lines)
	text.layout(lines, text.string_bytes(string_id), origin, Vector2(8, SHOP_ROW), 0, sharp, true)
	world.add_child(window)
	return window


## The window slides to x `to` over SHOP_SLIDE_FRAMES frames, on a sine ease (the box's the original's slide sine routine steps).
func _shop_slide(window: Node2D, to: float) -> void:
	var from := window.position.x
	for i in SHOP_SLIDE_FRAMES:
		window.position.x = lerpf(from, to, sin(float(i + 1) / SHOP_SLIDE_FRAMES * PI * 0.5))
		await _frames(1)
	window.position.x = to


## The window's entries are picked as the choices are: up and down (or the wheel, or the mouse over a line) moves the yellow bar, and
## confirm (or a click on a line) takes it. Returns the entry's index. A test answers with test_choice, as the story's choices do.
func _shop_pick(window: Node2D, origin: Vector2, panel: Rect2, count: int, start: int) -> int:
	if test_choice.is_valid():
		await _frames(1)
		_note("shop:choice:%d" % count)
		return clampi(int(test_choice.call(count, 0)), 0, count - 1)
	var edge := Color(0.19, 0.19, 0.0)
	var mid := Color(0.75, 0.75, 0.0)
	var w := panel.size.x
	var bar := Polygon2D.new()
	bar.polygon = PackedVector2Array([Vector2(0, 0), Vector2(w * 0.5, 0), Vector2(w, 0), Vector2(w, 10), Vector2(w * 0.5, 10), Vector2(0, 10)])
	bar.vertex_colors = PackedColorArray([edge, mid, edge, edge, mid, edge])
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bar.material = add
	bar.position = Vector2(panel.position.x, origin.y + 1.0)
	window.add_child(bar)
	var current := clampi(start, 0, count - 1)
	bar.position.y = origin.y + 1.0 + SHOP_ROW * current
	var held := {}
	var last_mouse := get_local_mouse_position()
	while _skipping():
		await _frames(1)       # a skip in progress waits here: the pick is the player's
	wheel_steps = 0
	choice_open = true
	while true:
		await _frames(1)
		var up := Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP)
		var down := Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN)
		if up and not held.get("up", false) and current > 0:
			current -= 1
			sound.emit(6)
		if down and not held.get("down", false) and current < count - 1:
			current += 1
			sound.emit(6)
		if wheel_steps < 0 and current > 0:
			current -= 1
			sound.emit(6)
		elif wheel_steps > 0 and current < count - 1:
			current += 1
			sound.emit(6)
		wheel_steps -= signi(wheel_steps)
		held["up"] = up
		held["down"] = down
		var mouse := get_local_mouse_position()
		var local: Vector2 = (mouse - world.position) / world.scale - window.position
		var line := int(floor((local.y - origin.y) / SHOP_ROW))
		var over := line >= 0 and line < count and panel.has_point(local)
		if mouse != last_mouse and over and line != current:
			# hovering a line selects it, a click takes it
			current = line
			sound.emit(6)
		last_mouse = mouse
		bar.position.y = origin.y + 1.0 + SHOP_ROW * current
		if TouchControls.game_pointer_held():
			if over:
				current = line
				bar.position.y = origin.y + 1.0 + SHOP_ROW * current
				break
		elif _pressed_confirm():
			break
	while _pressed_confirm():
		await _frames(1)
	bar.queue_free()
	choice_open = false
	wheel_steps = 0
	return current


## The mouse wheel while a choice is up moves its highlight a line a notch, as Up and Down do (read by _choose).
func _gui_input(event: InputEvent) -> void:
	if not choice_open or not (event is InputEventMouseButton and event.pressed):
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		wheel_steps = maxi(wheel_steps - 1, -10)
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		wheel_steps = mini(wheel_steps + 1, 10)


func _page_wait() -> void:
	arrow_wanted = true
	await _wait_press()
	if _skipping():
		# a skipped page still reaches the screen: it is kept for one rendered frame before the box clears
		await get_tree().process_frame
	arrow_wanted = false
	arrow.visible = false
	await _leave_text(false)
	_page += 1


func _show_portrait(index: int) -> void:
	if not portraits.has(index):
		portraits[index] = _texture(DIR + "portraits/%02d.png" % index)
		if portraits[index] == null:
			_note("portrait:missing:%02d" % index)
	portrait.texture = portraits[index]


# ---- speaker busts (F6 ids 1..0x40, and the show-menu opcode) -----------------------------------------------------------

## The display effect command (F6, and F8 21): portraits are the ids 0x41 and up (bit 0x80 hides one, else the portrait of
## effect - 0x41 is shown); the busts are the ids 1 to 0x40 (_bust_command, which drives the bust's records in bust_effect.gd).
func _display_effect(effect: int, flags: int) -> void:
	_note("f6:%02x:%02x" % [effect, flags])
	if effect >= 0x41 and effect <= 0x59 and (flags & 0x80) == 0:
		_show_portrait(effect - 0x41)
	elif effect >= 0x41 and (flags & 0x80) != 0:
		portrait.texture = null
	elif effect >= 1 and effect < 0x41:
		await _bust_command(effect, flags)


## The text holds while a bust record's step runs (the game's text states wait on the step). A record that has gone lets go.
## Under the skip key the steps run to their end at once.
func _bust_settled(rec) -> void:
	var was_live := busts.live
	busts.live = true
	while rec.step != 0 and rec.id >= 0:
		if _skipping():
			for i in 60:
				if rec.step == 0 or rec.id < 0:
					break
				busts.tick(-1)
		else:
			await get_tree().physics_frame
	busts.live = was_live


## The text holds until the record's blink and mouth are idle: a fade or an expression change starts only then.
func _bust_idle(rec) -> void:
	var was_live := busts.live
	busts.live = true
	while not busts.idle(rec) and rec.id >= 0:
		if _skipping():
			for i in 60:
				if busts.idle(rec) or rec.id < 0:
					break
				busts.tick(-1)
		else:
			await get_tree().physics_frame
	busts.live = was_live


## The bust commands (F6 with an id of 1 to 0x40). Bit 0x80 takes the bust away: bit 1 at once, bit 0 with a fade out, otherwise a
## slide out. Bit 0x40 changes its expression (bits 0 and 1). Bit 0x20 sets its busy flag from bit 0 (busy holds the blink and the
## mouth). Otherwise the bust slides in to the slot bit 0 names, with a fade in when bit 3 is set and the expression of bits 1 and
## 2 when bit 4 is set. The text waits on each step as the game's text states do.
func _bust_command(ident: int, flags: int) -> void:
	if (flags & 0x80) != 0:
		var gone = busts.find(ident)
		if gone == null:
			return
		if (flags & 2) != 0:
			busts.remove(gone)
			return
		if (flags & 1) != 0:
			await _bust_idle(gone)
			busts.start_fade_out(gone)
			await _bust_settled(gone)
			return
		busts.start_slide_out(gone)
		await _bust_settled(gone)
		busts.remove(gone)
		return
	if (flags & 0x60) != 0:
		var rec = busts.find(ident)
		if rec == null:
			return
		if (flags & 0x40) != 0:
			rec.expression = flags & 3
			await _bust_idle(rec)
			busts.start_crossfade(rec)
			await _bust_settled(rec)
			return
		busts.set_busy(rec, (flags & 1) != 0)
		return
	var shown = busts.start_show(ident, flags)
	await _bust_settled(shown)        # the picture loads
	busts.start_slide_in(shown)
	await _bust_settled(shown)        # the slide (or the fade in) ends


## The show-menu opcode: the bust goes up at its resting place at once; the script waits until its picture has loaded.
func _bust_menu(ident: int, flags: int) -> void:
	var shown = busts.start_menu(ident, flags)
	await _bust_settled(shown)


## The mouth kind a glyph gives a speaker bust (the glyph table's kind, from text.json; -1 for a code the table lacks).
func _talk_kind(code: int) -> int:
	if code >= 0 and code < text.glyphs.size():
		return int(text.glyphs[code].get("talk", -1))
	return -1


func _physics_process(delta: float) -> void:
	busts.frame(delta)


## The text state setup from a stream's state (F7, and F8 22), and the operands the state reads when it starts: 5 shows a picture (a
## u16, and a byte and a u16 viewport when the word has bit 0x8000), 0x0B tweens the viewport (x, y, frames), 0x0F pauses and 0x10
## shakes for a u16 of frames. The other states read nothing. The operands are read from the stream and it moves past them.
func _text_state(state: int, frame: Dictionary) -> void:
	_note("state:%02x" % state)
	match state:
		5:
			var word := _word(frame, 0)
			_skip(frame, 2)
			var view := Vector2.ZERO
			if (word & 0x8000) != 0:
				view = Vector2(_word(frame, 1), _at(frame, 0))
				_skip(frame, 3)
			await _fade_to(0)
			_set_picture(word & 0xFFF, view)
			await _fade_to(255)
		0x0B:
			var tx := _word(frame, 0)
			var ty := _word(frame, 2) & 0xFFF
			var count := _word(frame, 4)
			_skip(frame, 6)
			await _tween_viewport(Vector2(tx, ty), count)
		0x0F:
			var pause := _word(frame, 0)
			_skip(frame, 2)
			await _frames(pause)
		0x10:
			var shake := _word(frame, 0)
			_skip(frame, 2)
			await _shake(shake)


## the routine at 0x80037A58, the screen shake: for `frames` frames the picture is offset by (rand & 7) - 4 and (rand & 3) - 2 from where it
## stood, and then it returns there. The original moves the whole display; here the picture alone moves.
func _shake(frames: int) -> void:
	var base := picture.position
	for i in maxi(frames, 0):
		picture.position = base + Vector2((randi() & 7) - 4, (randi() & 3) - 2)
		await _frames(1)
	picture.position = base
