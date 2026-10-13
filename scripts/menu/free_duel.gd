extends Control
## The FREE DUEL opponent select, a native port of the Free Duel setup, the Free Duel cursor placement, the cursor tween update,
## the scrollbar update, the Free Duel screen update, the sparkle spawn, the sparkle update and the Free Duel entry. The forty
## portraits scroll behind a 320x240 window; the cursor glides one cell in eight frames while a direction is held and the window
## follows it. Steps at the game's 60 Hz. The pictures are baked by tools/extract.py --screens (assets/screens/free_duel/).
##
## Cells run 0..39 in five columns: cell 0 is Build Deck, the others are the opponents. Cross or Square on any cell emits
## chosen(cell): the owner opens the Build Deck for cell 0 and the duel for cells 1..39.

signal chosen(cell: int)      # Cross or Square on an opponent
signal closed                 # Circle: back to the main menu
signal sound(effect: int)     # the full SE play ids: 0x2F the cursor arrives, 0x30 confirm, 8 cancel
signal music(id: int)           # the BGM play this screen starts when it opens (the driver's BGM play)

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const GlyphFx := preload("res://scripts/ui/glyph_fx.gd")
const DIR := "res://assets/screens/free_duel/"
const CELLS := 40
const COLUMNS := 5
const LAST_COLUMN := 4
const LAST_ROW := 7
const CELL_ORIGIN := Vector2(20, 40)
const CELL_SIZE := Vector2(56, 52)
const NAME_STRING := 0x8328                  # the opponent's global name: cell n is NAME_STRING + n
const NAME_ORIGIN := Vector2(16, 204)        # the text box creation(0, ..., 16, 204, 288, 16)
const MESSAGE_STRING := 13                   # "SELECT OPPONENT", the flagged text box creation(1, 13, 48, 108, 224, 16)
const MESSAGE_ORIGIN := Vector2(48, 108)     # the box's text at its top: the flagged box's small glyph class puts the rows 2 pixels below it (game_text.gd)
const MESSAGE_BOX := Rect2(48, 108, 224, 16)  # the flagged box's rectangle (flags 0x1028: the panel and the end arrow)
const TextBoxBg := preload("res://scripts/ui/text_box_bg.gd")
const TEXT_ADVANCE := Vector2(8, 12)
const TEXT_LAYER := 20                       # the text boxes lie over the picture
const TWEEN_FRAMES := 8
const VIEW_TOP := 0x28                       # the window keeps the cursor between 0x28 and 0x90 below its top
const VIEW_BOTTOM := 0x90
const SPARKLE_LIFE := 16
const SPARKLE_LIMIT := 16
const CURSOR_HOLD := 4                       # frames each cursor frame stays
const CURSOR_PIVOT := Vector2(24, 24)        # the centre of the 48 x 48 cursor plate, where the pulse scales it from
const CURSOR_LAYER := 1                      # in front of the portraits, behind the frame: the cursor's depth offset 5 is nearer than the cells' (smaller is nearer), the frame's 10 nearer still
const THUMB_LAYER := 15
const FRAME_LAYER := 10
const BACKDROP_LAYER := -10
const GameState := preload("res://scripts/state/game_state.gd")
const UNLOCK_FLAG_BASE := 0x6E0             # the Free Duel unlock flag base: opponent i (1 to 38) is open when its flag is set
const FIRST_STORY_OPPONENT := 1             # the first story opponent index
const DUEL_MASTER_K := 39                   # the Master K opponent id: always open, like Build Deck
const RECORD_STRING := 12                   # the record line for cells 1..39: the name (pushed by F8 09) then the record at x 160
const DECK_FULL_STRING := 8                 # the flagged text box creation(1, 8, 48, 108, 224, 16) when the deck is not forty cards
const DIGIT_SJIS := 0x824F                  # the Shift-JIS code of '0'; the digits follow it
const WINS_ADDRESS := 0x801D5608            # the data at 0x801D5608.pair.lo: the wins the record line prints first
const LOSSES_ADDRESS := 0x801D560C          # the data at 0x801D5608.pair.hi: the losses printed after them
const PORTRAIT_SIZE := Vector2(48, 48)      # a portrait's picture inside its cell: the gap to the next cell is no cell
const THUMB_TOP_Y := 7                      # the thumb's y on the top row; it travels THUMB_TRAVEL px to the bottom row (the scrollbar update)
const THUMB_TRAVEL := 72
const TRACK_TOP := 32                       # the scroll track is the frame's stripes at x 296 from 32 down to 192 (the thumb's column)
const TRACK_BOTTOM := 192

var text := GameText.new()
var layout: Dictionary = {}
var world := Node2D.new()
var sharp: ShaderMaterial
var sharp_add: ShaderMaterial
var clip := Control.new()                    # the window: the grid is cut at its 320x240 edge
var scroller := Node2D.new()
var cursor := Node2D.new()
var cursor_pivot := Node2D.new()            # the cursor's centre: the frame scales about it (the object's 24, 24 pivot), not its corner
var cursor_sprite := Sprite2D.new()
var cursor_textures: Array = []
var cursor_offsets: Array = []
var thumb := Sprite2D.new()
var sparkles: Array = []                     # [Sprite2D, updates so far]
var available: Array = []                    # the Free Duel grid availability: a cell can be chosen (Build Deck and Duel Master K always; others by flag)
var digits: Array = []                       # the ten digit glyph codes the record line's numbers are drawn with
var name_box: Node2D
var message_box: Node2D
var message := false                         # the opening message is up (the Free Duel screen flags & 0x20)
var column := 0
var row := 0
var target_column := 0
var target_row := 0
var gliding := false
var glide_left := 0
var glide_from := Vector2.ZERO
var glide_to := Vector2.ZERO
var view_y := 0
var frame := 0
var ready_ok := false
var held: Dictionary = {}
var click_pending := false     # left mouse button: Cross
var cancel_click := false      # right mouse button: Circle
var portraits: Array = []      # the forty portrait sprites by cell: a locked cell's is hidden, as the screen does not draw it
var dragging := false          # the left button is held on the scrollbar thumb or its track
var drag_grab := 0.0           # where on the thumb the drag took hold, from the thumb's top (the track jump takes its middle)


func _ready() -> void:
	music.emit(29312)   # the BGM play in this screen's open routine
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all():
		return
	var json = JSON.parse_string(FileAccess.get_file_as_string(DIR + "layout.json")) if FileAccess.file_exists(DIR + "layout.json") else null
	if typeof(json) != TYPE_DICTIONARY:
		return
	layout = json
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sharp = ScreenFit.make_material()
	sharp_add = ScreenFit.make_material(true)
	add_child(world)
	add_to_group("fit")
	_picture(world, "backdrop.png", _offset("backdrop"), BACKDROP_LAYER)
	clip.size = Vector2(320, 240)
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world.add_child(clip)
	clip.add_child(scroller)
	for i in CELLS:
		portraits.append(_picture(scroller, "portraits/%02d.png" % i, _cell(i % COLUMNS, i / COLUMNS), 0))
	cursor.z_index = CURSOR_LAYER
	scroller.add_child(cursor)
	cursor_pivot.position = CURSOR_PIVOT
	cursor.add_child(cursor_pivot)
	cursor_sprite.centered = false
	cursor_sprite.material = sharp
	cursor_pivot.add_child(cursor_sprite)
	for i in layout["cursor"].size():
		cursor_textures.append(_texture("cursor_%d.png" % i))
		cursor_offsets.append(_offset_of(layout["cursor"][i]))
	_picture(world, "frame.png", _offset("frame"), FRAME_LAYER)
	thumb.centered = false
	thumb.texture = _texture("thumb.png")
	thumb.material = sharp
	thumb.z_index = THUMB_LAYER
	world.add_child(thumb)

	for i in 10:
		digits.append(text.code_for_sjis(DIGIT_SJIS + i))
	_read_availability()

	ScreenFit.pass_mouse(self)
	ready_ok = true
	_place_cursor(false)
	_update_scroll()
	_open_message()
	get_viewport().size_changed.connect(refit)
	refit()


func _texture(file: String) -> Texture2D:
	return ModArt.texture(DIR + file)


func _offset(name: String) -> Vector2:
	return _offset_of(layout[name])


func _offset_of(entry: Dictionary) -> Vector2:
	return Vector2(int(entry["x"]), int(entry["y"]))


func _picture(parent: Node, file: String, at: Vector2, layer: int) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = _texture(file)
	sprite.position = at
	sprite.material = sharp
	sprite.z_index = layer
	parent.add_child(sprite)
	return sprite


func refit() -> void:
	ScreenFit.apply(world, size)


## The grid's origin for a column and row (the Free Duel cursor placement: col * 56 + 20, row * 52 + 40).
func _cell(col: int, r: int) -> Vector2:
	return CELL_ORIGIN + Vector2(col * CELL_SIZE.x, r * CELL_SIZE.y)


func _input_state() -> Dictionary:
	var down := {
		"left": Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT),
		"right": Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT),
		"up": Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP),
		"down": Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN),
		"confirm": Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_A) \
			or Input.is_joy_button_pressed(0, JOY_BUTTON_X),
		"cancel": Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_BACKSPACE) \
			or Input.is_joy_button_pressed(0, JOY_BUTTON_B),
	}
	var pressed := {}
	for key in down:
		if down[key] and not held.get(key, false):
			pressed[key] = true
		held[key] = down[key]
	# a click waits until the cursor has landed on the cell it was given, so Cross acts on the cell that was clicked
	var settled := not gliding and column == target_column and row == target_row
	if settled:
		if click_pending:
			pressed["confirm"] = true
			click_pending = false
		if cancel_click:
			pressed["cancel"] = true
			cancel_click = false
	return {"down": down, "pressed": pressed}


func _gui_input(event: InputEvent) -> void:
	if not ready_ok:
		return
	if event is InputEventMouseMotion:
		if dragging:
			_drag_to(_to_picture(event.position).y)
		else:
			# hovering a portrait moves the cursor's target there, as the held directions do; the glide carries it on
			_hover(event.position)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		dragging = false
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	# the wheel moves the target row one row a notch, as Up and Down do; the glide then carries the cursor there
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		if not message:
			target_row = maxi(target_row - 1, 0)
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not message:
			target_row = mini(target_row + 1, LAST_ROW)
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		cancel_click = true
	elif event.button_index == MOUSE_BUTTON_LEFT:
		var at := _to_picture(event.position)
		if not message and _on_scrollbar(at):
			# the thumb is taken where it was pressed; a press on the track jumps the thumb's middle to the press
			dragging = true
			drag_grab = at.y - thumb.position.y if _thumb_rect().has_point(at) else thumb.texture.get_height() / 2.0
			_drag_to(at.y)
			return
		_hover(event.position)
		click_pending = true


## The point in the 320x240 picture for a point in the control's local coordinates.
func _to_picture(at: Vector2) -> Vector2:
	return (at - world.position) / world.scale


func _thumb_rect() -> Rect2:
	return Rect2(thumb.position, thumb.texture.get_size())


func _on_scrollbar(at: Vector2) -> bool:
	var track := Rect2(_offset("thumb").x, TRACK_TOP, thumb.texture.get_width(), TRACK_BOTTOM - TRACK_TOP)
	return _thumb_rect().has_point(at) or track.has_point(at)


## The scrollbar drag: the thumb's top follows the pointer (kept on its 72 px of travel), and the cursor's target row is the row the
## thumb stands for, so the cursor glides there and the window follows it under the same rules as the held directions.
func _drag_to(y: float) -> void:
	if message:
		return
	var thumb_y := clampf(y - drag_grab - _offset("thumb").y, THUMB_TOP_Y, THUMB_TOP_Y + THUMB_TRAVEL)
	var row := clampi(roundi((thumb_y - THUMB_TOP_Y) * (LAST_ROW) / THUMB_TRAVEL), 0, LAST_ROW)
	target_row = row


func _hover(at: Vector2) -> void:
	if message:
		return
	var cell := _cell_at(at)
	if cell.x >= 0:
		target_column = cell.x
		target_row = cell.y


## The cell under a point in the control's local coordinates (the window scrolls, so the grid's y adds the view), or (-1, -1).
## Only the portrait counts: the gap between two portraits is no cell.
func _cell_at(at: Vector2) -> Vector2i:
	var local := _to_picture(at)
	local.y += view_y
	var col := int(floor((local.x - CELL_ORIGIN.x) / CELL_SIZE.x))
	var r := int(floor((local.y - CELL_ORIGIN.y) / CELL_SIZE.y))
	if col < 0 or col > LAST_COLUMN or r < 0 or r > LAST_ROW:
		return Vector2i(-1, -1)
	var inside := local - (CELL_ORIGIN + Vector2(col * CELL_SIZE.x, r * CELL_SIZE.y))
	if inside.x >= PORTRAIT_SIZE.x or inside.y >= PORTRAIT_SIZE.y:
		return Vector2i(-1, -1)
	return Vector2i(col, r)


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible:
		return
	frame += 1
	var input := _input_state()
	_update_screen(input)
	_pulse()
	_update_sparkles()
	cursor_sprite.texture = cursor_textures[(frame / CURSOR_HOLD) % cursor_textures.size()]
	cursor_sprite.position = cursor_offsets[(frame / CURSOR_HOLD) % cursor_offsets.size()] - CURSOR_PIVOT


## the Free Duel screen update: the opening message holds the screen until it is dismissed; otherwise the glide and the window run first,
## then the held directions move the target cell (one cell per glide), and Circle or Cross or Square act when no direction is held.
func _update_screen(input: Dictionary) -> void:
	var down: Dictionary = input["down"]
	var pressed: Dictionary = input["pressed"]
	if message:
		if pressed.has("confirm") or pressed.has("cancel"):
			_close_message()
		return
	_update_glide()
	_update_scroll()
	if gliding:
		return
	if down["right"] or down["left"] or down["up"] or down["down"]:
		if down["right"]:
			target_column = mini(target_column + 1, LAST_COLUMN)
		if down["left"]:
			target_column = maxi(target_column - 1, 0)
		if down["down"]:
			target_row = mini(target_row + 1, LAST_ROW)
		if down["up"]:
			target_row = maxi(target_row - 1, 0)
		return
	if pressed.has("cancel"):
		sound.emit(8)
		closed.emit()
		return
	if not pressed.has("confirm"):
		return
	var cell := row * COLUMNS + column
	if not available[cell]:
		return                                   # an unopened cell does nothing (no sound), as the Free Duel screen update
	if cell != 0 and not _deck_complete():
		# the duel needs a full forty-card deck: SE 9 and the message, which holds the screen until it is dismissed
		sound.emit(9)
		_open_message(DECK_FULL_STRING, false)
		return
	sound.emit(0x30)
	chosen.emit(cell)


## The game checks the built deck for an empty slot (the player deck): the deck is complete at forty cards with none empty.
func _deck_complete() -> bool:
	if GameState.deck.size() != 40:
		return false
	for id in GameState.deck:
		if int(id) == 0:
			return false
	return true


## the cursor tween update: the cursor closes an eighth of the way to its target each frame and leaves a sparkle behind.
func _update_glide() -> void:
	if not gliding:
		if column == target_column and row == target_row:
			return
		gliding = true
		glide_left = TWEEN_FRAMES
		glide_from = cursor.position
		glide_to = _cell(target_column, target_row)
	glide_left -= 1
	if glide_left == 0:
		column = target_column
		row = target_row
		_place_cursor(true)
		gliding = false
		sound.emit(0x2F)
	else:
		cursor.position = glide_from.lerp(glide_to, float(TWEEN_FRAMES - glide_left) / TWEEN_FRAMES)
		_spawn_sparkle()


## the scrollbar update: the window scrolls so the cursor stays between 0x28 and 0x90 below its top; the thumb follows the cursor.
func _update_scroll() -> void:
	var cursor_y := int(cursor.position.y)
	var relative := cursor_y - view_y
	if relative < VIEW_TOP:
		view_y = cursor_y - VIEW_TOP
	if relative >= VIEW_BOTTOM + 1:
		view_y = cursor_y - VIEW_BOTTOM
	scroller.position.y = -view_y
	var thumb_y := (cursor_y - VIEW_TOP) * 72 / 364 + 7
	thumb.position = Vector2(0, thumb_y) + _offset("thumb")


## the Free Duel setup's availability: cell n of 1..38 is open when campaign flag 0x6E0 + n is set; Build Deck and Duel Master K are open.
func _read_availability() -> void:
	available = []
	for cell in CELLS:
		var open := cell == 0 or cell == DUEL_MASTER_K
		if cell >= FIRST_STORY_OPPONENT and cell < DUEL_MASTER_K:
			open = GameState.test_flag(UNLOCK_FLAG_BASE + cell)
		available.append(open)
		# the screen draws a cell's portrait only when the duelist is open: a locked cell is blank, not a face that does nothing
		if cell < portraits.size():
			portraits[cell].visible = open


## the Free Duel cursor placement: the cursor goes to its cell; when armed and open, the opponent's name box is laid out again for that cell.
func _place_cursor(arm: bool) -> void:
	cursor.position = _cell(column, row)
	if name_box != null:
		name_box.queue_free()
		name_box = null
	if not arm or not available[row * COLUMNS + column]:
		return
	name_box = Node2D.new()
	name_box.z_index = TEXT_LAYER
	world.add_child(name_box)
	var cell := row * COLUMNS + column
	if cell == 0:
		_box(name_box, text.string_bytes(NAME_STRING), NAME_ORIGIN)
	else:
		_box(name_box, _record_bytes(cell), NAME_ORIGIN, _record_context(cell))


## Text for the opponent's record line: the name is pushed where F8 09 stands in string 12 (the routine at 0x800383DC), and the rest is the
## record template. Both streams end in 0xFF; the name's end is dropped so the template follows it on the same line.
func _record_bytes(cell: int) -> Array:
	var name: Array = text.string_bytes(NAME_STRING + cell)
	if not name.is_empty() and int(name[name.size() - 1]) == 0xFF:
		name.resize(name.size() - 1)
	var template: Array = text.string_bytes(RECORD_STRING)
	return name + template.slice(2)               # the two bytes F8 09 are the push itself


## The numbers the record template reads (F8 03 at the two RAM addresses) and the digit codes: the cell's wins and losses.
func _record_context(cell: int) -> Dictionary:
	var table: PackedInt32Array = GameState.duelist_records
	var wins := table[cell * 2] if table.size() >= cell * 2 + 2 else 0
	var losses := table[cell * 2 + 1] if table.size() >= cell * 2 + 2 else 0
	return {"digits": digits, "numbers": {WINS_ADDRESS: wins, LOSSES_ADDRESS: losses}}


## the flagged text box creation(1, string, 48, 108, 224, 16): the opening message, or the deck message; the screen holds until it is dismissed.
func _open_message(string_id := MESSAGE_STRING, hide_cursor := true) -> void:
	message = true
	cursor.visible = not hide_cursor
	message_box = Node2D.new()
	message_box.z_index = TEXT_LAYER
	world.add_child(message_box)
	_box(message_box, text.string_bytes(string_id), MESSAGE_ORIGIN, {}, MESSAGE_BOX)


func _close_message() -> void:
	message = false
	message_box.queue_free()
	message_box = null
	cursor.visible = true
	_place_cursor(true)


## Lays a string out in the small font with each glyph brought in by the text box effect, one glyph every two frames. A box with a
## rectangle (`panel`) is a flagged box: its hexagon background (text_box_bg.gd) lies under the glyphs, and its end arrow comes up
## once the glyphs are all in.
func _box(holder: Node2D, bytes: Array, origin: Vector2, ctx: Dictionary = {}, panel := Rect2()) -> void:
	var bg: Node2D = null
	if panel.size != Vector2.ZERO:
		bg = TextBoxBg.new()
		bg.setup(panel, sharp, true)
		bg.z_index = -1
		holder.add_child(bg)
	var index := 0
	for entry in text.layout(holder, bytes, origin, TEXT_ADVANCE, 0, sharp, true, {}, ctx):
		if entry["sprite"] != null:
			var fx := Polygon2D.new()
			fx.set_script(GlyphFx)
			fx.sprite = entry["sprite"]
			fx.delay = index * 2
			fx.small = true
			holder.add_child(fx)
		index += 1
	if bg != null:
		bg.show_arrow_after(index * 2)


## the Free Duel entry: the cursor breathes over the first sixteen frames of each 128 and then holds its size.
func _pulse() -> void:
	var phase := frame & 0x7F
	if phase < 0x10:
		if phase >= 8:
			phase = 0xF - phase
		var factor := (phase * 48 + 0x1000) / 4096.0
		cursor_pivot.scale = Vector2(factor, factor)


## the sparkle spawn: a copy of the cursor's plate, added where the cursor is, that fades out additively.
func _spawn_sparkle() -> void:
	if sparkles.size() >= SPARKLE_LIMIT:
		return
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.material = sharp_add
	sprite.texture = cursor_sprite.texture
	sprite.scale = cursor_pivot.scale
	sprite.position = cursor.position + CURSOR_PIVOT + cursor_sprite.position * cursor_pivot.scale
	sprite.z_index = CURSOR_LAYER              # the sparkle is the cursor's own depth offset (5), so it is drawn with the cursor
	scroller.add_child(sprite)
	sparkles.append([sprite, 0])


## the sparkle update: the colour falls 4 a frame from 0x40 (of 0x80 full) and the sparkle is released on its sixteenth update.
func _update_sparkles() -> void:
	for item in sparkles.duplicate():
		item[1] += 1
		var level := clampf((0x40 - 4 * item[1]) / 128.0, 0.0, 1.0)
		item[0].modulate = Color(level, level, level, 1.0)
		if item[1] >= SPARKLE_LIFE:
			item[0].queue_free()
			sparkles.erase(item)
