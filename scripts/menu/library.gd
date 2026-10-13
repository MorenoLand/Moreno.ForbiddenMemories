extends Control
## The card library (LIBRARY, entry 8 of the front-end's second page): a native port of the cursor and glide, the grid scroll, the card grid drawing, the card info box and the card view state, written from the original's behaviour.
## The grid is 40 rows of 20 cards: ids 1..722, a block of ten per row and the right block 100 ids on. The cursor glides between
## cells over 6 frames (2 with Square held) and the grid scrolls to keep it between 0x40 and 0xB0 pixels from the top. Cross opens
## the card view, Circle closes it, and on the grid Circle returns to the menu. Steps at the game's 60 Hz.
## What is drawn: the eight stone section panels with their range numbers, the card tiles of the cards the player has seen (in
## their type's colour; a card the player does not own is drawn at half brightness), the cursor sprite with the crosshair, the info
## band and the card view. The pictures are baked by tools/extract.py --screens (assets/screens/library/).
## The card view's box is the library's own frame picture. Approximated: the positions of the stats, the level stars and the icons in
## the card view's text box, its layout strings, stars, race icons and card text, and the stats, are drawn by the shared card view
## helper (scripts/ui/card_view.gd), which the Build Deck viewer uses too.

signal closed                 # Circle on the grid: back to the main menu
signal sound(effect: int)     # the sound effect ids: 0x32 card chosen, 0x34 view slides in, 0x31 slides out, 0x33 grid again, 0x35 cursor arrives, 8 cancel
signal music(id: int)           # the BGM play this screen starts when it opens (the driver's BGM play)

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const CardDB := preload("res://scripts/data/card_db.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const DIR := "res://assets/screens/library/"
const CardView := preload("res://scripts/ui/card_view.gd")
const CARD_BOX := Rect2(148, 14, 168, 192)        # the card view's text box (x 0x94, y 0xE, 0xA8 x 0xC0)
const CARD_COUNT := 722
const ROWS := 40
const SECTIONS := 4
const SLIDE_FRAMES := 20
const TILE_KINDS := {"Magic": 1, "Equip": 1, "Trap": 2, "Ritual": 3}   # the grid tile's CLUT: monsters 0, magic and equip 1, trap 2, ritual 3
const NOT_OWNED_TINT := Color(0.5, 0.5, 0.5)   # 0x404040 against the neutral 0x808080 (the sprite's colour is a half-scale multiply)

var text := GameText.new()
var cards := CardDB.new()
var box_view: CardView             # the card view's box (the layout, stats and icons), shared with the Build Deck viewer
var tiles: Array = []
var panels: Array = []             # the eight section panels: {"texture", "at"} (at = where the picture's top-left goes)
var cursor_piece: Dictionary = {}  # the cursor sprite: {"texture", "at"} relative to the cursor's cell
var band_piece: Dictionary = {}    # the info band: {"texture", "at"}
var frame_piece: Dictionary = {}  # the card view box (the library's frame object): {"texture", "at"}
var seen := PackedByteArray()      # per card id (index = id): the seen mark (the card flag 0x80)
var owned := PackedInt32Array()    # per card id - 1: the copies owned
var seen_total := 0
var sharp: ShaderMaterial
var ready_ok := false
var held: Dictionary = {}
var click_pending := false         # left mouse button: Cross
var cancel_click := false          # right mouse button: Circle
var hover_pending := Vector2i(-1, -1)   # the cell the pointer is over, taken up when the glide is free
var wheel_steps := 0               # mouse wheel notches: negative up, positive down; one row each
var frame := 0                     # the 60 Hz count the crosshair pulses with
var column := 0                    # gCardGrid_bCursorColumn
var row := 0                       # gCardGrid_bCursorRow
var cursor_pos := Vector2i(14, 14)  # LibraryMotionState x and y
var rest_pos := Vector2i(14, 14)
var glide_pos := Vector2.ZERO      # the glide's position, the 16.16 fraction kept as a float
var glide_step := Vector2.ZERO
var glide_frames := 0              # LibraryMotionState.frames; 0 when still
var view_y := 0                    # gGraphics_sViewportY
var state := "grid"                # grid, opening, card, closing
var slide := 0
var selected := 0                  # the card the cursor selected
var world := Node2D.new()
var view := Node2D.new()           # scrolls with the grid: the grid and the heading
var grid := Node2D.new()
var heading := Node2D.new()
var cross := Node2D.new()          # the crosshair lines and the cursor sprite, in screen space
var band := Node2D.new()           # the info band (drawn under the info text)
var info := Node2D.new()
var card_view := Node2D.new()      # slides in from the right: the frame, the art and the text
var frame_node := Node2D.new()
var art := Sprite2D.new()
var card_text := Node2D.new()
var icons := Node2D.new()


func _ready() -> void:
	music.emit(29392)   # the BGM play in this screen's open routine
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all() or not cards.load_all():
		return
	for i in 4:
		var tile := ModArt.texture(DIR + "tile_%d.png" % i)
		if tile == null:
			return
		tiles.append(tile)
	var layout = _read_json(DIR + "layout.json")
	if layout == null:
		return
	for i in 8:
		var piece := _piece("panel_%d" % i, layout)
		if piece.is_empty():
			return
		panels.append(piece)
	cursor_piece = _piece("cursor", layout)
	band_piece = _piece("info_band", layout)
	if cursor_piece.is_empty() or band_piece.is_empty():
		return
	frame_piece = _piece("card_frame", layout)
	if frame_piece.is_empty():
		return
	_read_seen()
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sharp = ScreenFit.make_material()
	box_view = CardView.new(text, sharp)
	add_child(world)
	add_to_group("fit")
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(320, 240)
	world.add_child(black)
	world.add_child(view)
	world.add_child(cross)
	world.add_child(band)
	world.add_child(info)
	world.add_child(card_view)
	view.add_child(grid)
	view.add_child(heading)
	card_view.add_child(frame_node)
	# the picture is drawn over the box's text: where a star name crosses the picture's top edge, the opaque picture covers it
	card_view.add_child(card_text)
	card_view.add_child(art)
	card_view.add_child(icons)
	grid.draw.connect(_draw_grid)
	cross.draw.connect(_draw_cross)
	frame_node.draw.connect(_draw_frame)
	var band_sprite := Sprite2D.new()
	band_sprite.centered = false
	band_sprite.texture = band_piece["texture"]
	band_sprite.position = band_piece["at"]
	band.add_child(band_sprite)
	art.centered = false
	art.material = sharp
	# the picture sits left of the text box, at the screen's (2, 0), as the Build Deck and the duel's viewers place it
	art.position = CardView.art_at(CARD_BOX.position)
	card_text.position = CARD_BOX.position
	icons.position = CARD_BOX.position
	text.layout(heading, box_view.bytes_of("<%3d/%d>" % [seen_total, CARD_COUNT]), Vector2(88, -24), Vector2(16, 16), 0, sharp)
	_scroll()
	_show_info()
	_set_visibility()
	get_viewport().size_changed.connect(refit)
	refit()

	ScreenFit.pass_mouse(self)
	ready_ok = true


func refit() -> void:
	ScreenFit.apply(world, size)


func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if typeof(data) == TYPE_DICTIONARY else null


## A baked piece: its texture, and where its top-left goes relative to the origin the Library places it at (origin + at).
func _piece(name: String, layout: Dictionary) -> Dictionary:
	var texture := ModArt.texture(DIR + name + ".png")
	if texture == null or not layout.has(name):
		return {}
	var entry: Dictionary = layout[name]
	var origin: Array = entry["origin"]
	return {"texture": texture,
			"at": Vector2(float(origin[0]) + float(entry["x"]), float(origin[1]) + float(entry["y"]))}


## The seen marks and the owned copies of every card (the library's flags, GameState).
func _read_seen() -> void:
	seen = PackedByteArray()
	seen.resize(CARD_COUNT + 1)
	seen_total = 0
	for id in range(1, CARD_COUNT + 1):
		if GameState.is_card_seen(id):
			seen[id] = 1
			seen_total += 1
	owned = GameState.owned_counts()


func _card_seen(id: int) -> bool:
	return id >= 1 and id <= CARD_COUNT and seen[id] != 0


func _card_owned(id: int) -> bool:
	return id >= 1 and id <= owned.size() and owned[id - 1] > 0


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


## The card at a cursor cell: 0 past the last card.
func _card_at(col: int, r: int) -> int:
	var id := (r / 10) * 200 + (r % 10) * 10 + (100 if col >= 10 else 0) + 1 + col % 10
	return id if id <= CARD_COUNT else 0


## The cursor's rest position in a cell: the right block sits 0xA0 further right.
func _rest(col: int, r: int) -> Vector2i:
	return Vector2i((col % 10) * 14 + (0xAE if col >= 10 else 0xE), (r / 10) * 178 + (r % 10) * 16 + 0xE)


## Pad edges for this frame: the pressed edges and the held state of the directions and buttons this screen reads.
func _pad() -> Dictionary:
	var down := {
		"left": Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_LEFT),
		"right": Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_RIGHT),
		"up": Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP),
		"down": Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN),
		"confirm": Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_A),
		"cancel": Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_BACKSPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_B),
		"square": Input.is_key_pressed(KEY_F) or Input.is_joy_button_pressed(0, JOY_BUTTON_X),
		"l1": Input.is_key_pressed(KEY_Z) or Input.is_joy_button_pressed(0, JOY_BUTTON_LEFT_SHOULDER),
		"r1": Input.is_key_pressed(KEY_C) or Input.is_joy_button_pressed(0, JOY_BUTTON_RIGHT_SHOULDER),
	}
	var pressed := {}
	for key in down:
		if down[key] and not held.get(key, false):
			pressed[key] = true
		held[key] = down[key]
	# a click or right click waits until the cursor has landed and any hovered cell has been taken, so Cross acts on the cell clicked
	if state != "grid" or (glide_frames == 0 and hover_pending.x < 0):
		if click_pending:
			pressed["confirm"] = true
			click_pending = false
		if cancel_click:
			pressed["cancel"] = true
			cancel_click = false
	return {"pressed": pressed, "down": down}


func _gui_input(event: InputEvent) -> void:
	if not ready_ok:
		return
	if event is InputEventMouseMotion:
		if state == "grid":
			var cell := _cell_at(event.position)
			if cell.x >= 0:
				hover_pending = cell
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if state == "grid":
				wheel_steps = maxi(wheel_steps - 1, -10)
		MOUSE_BUTTON_WHEEL_DOWN:
			if state == "grid":
				wheel_steps = mini(wheel_steps + 1, 10)
		MOUSE_BUTTON_LEFT:
			if state == "grid":
				var cell := _cell_at(event.position)
				if cell.x >= 0:
					hover_pending = cell
			click_pending = true
		MOUSE_BUTTON_RIGHT:
			cancel_click = true


## The grid cell under a point in the control's local coordinates (the grid is scrolled by view_y), or (-1, -1) between the cards.
func _cell_at(at: Vector2) -> Vector2i:
	var none := Vector2i(-1, -1)
	var local: Vector2 = (at - world.position) / world.scale
	var gy := local.y + view_y
	if gy < 8.0:
		return none
	var section := int((gy - 8.0) / 178.0)
	if section >= SECTIONS:
		return none
	var within := gy - 8.0 - section * 178.0
	var line := int(within / 16.0)
	var tile: Vector2 = tiles[0].get_size()
	if line >= 10 or within - line * 16.0 >= tile.y:
		return none
	var x := local.x
	var k := int(floor((x - 8.0) / 14.0))
	if x >= 8.0 and k < 10 and x - 8.0 - k * 14.0 < tile.x:
		return Vector2i(k, section * 10 + line)
	k = int(floor((x - 168.0) / 14.0))
	if x >= 168.0 and k < 10 and x - 168.0 - k * 14.0 < tile.x:
		return Vector2i(10 + k, section * 10 + line)
	return none


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible:
		return
	frame += 1
	var pad := _pad()
	match state:
		"grid":
			_update_grid(pad)
		"opening", "closing":
			_slide_step()
		"card":
			if pad.pressed.has("cancel"):
				sound.emit(0x31)
				state = "closing"
				slide = SLIDE_FRAMES
				_place_card()
				_set_visibility()
	grid.queue_redraw()
	cross.queue_redraw()
	frame_node.queue_redraw()


## The cursor update: the glide runs first and blocks input until it lands; then Cross, Circle and the held directions.
func _update_grid(pad: Dictionary) -> void:
	if not _glide_step():
		var pressed: Dictionary = pad.pressed
		var down: Dictionary = pad.down
		if pressed.has("confirm") and _card_seen(_card_at(column, row)):
			_open_card()
			return
		if pressed.has("cancel"):
			sound.emit(8)
			closed.emit()
			return
		if down.left or down.right or down.up or down.down or down.l1 or down.r1:
			hover_pending = Vector2i(-1, -1)
			_step(down)
		elif wheel_steps != 0:
			# each wheel notch moves one row, as the held Up or Down does
			_step({"left": false, "right": false, "up": wheel_steps < 0, "down": wheel_steps > 0, "l1": false, "r1": false, "square": false})
			wheel_steps -= signi(wheel_steps)
		elif hover_pending.x >= 0:
			_glide_to(hover_pending.x, hover_pending.y, 6)
			hover_pending = Vector2i(-1, -1)
	_scroll()


## The held directions move the cursor one cell: 6 frames a cell (2 with Square), R1 and L1 jump ten rows, and a sideways step past
## the end of a row wraps to the next, four times as slow.
func _step(down: Dictionary) -> void:
	var col := column
	var r := row
	var frames := 2 if down.square else 6
	if down.l1 or down.r1:
		r = clampi(r + 10 if down.r1 else r - 10, 0, ROWS - 1)
		var distance := r - row
		frames = distance * 2 if distance >= 0 else (row - r) * 2
	else:
		if down.left or down.right:
			if down.right:
				col += 1
				if col >= 20:
					col = 19
					if r < ROWS - 1:
						col = 0
						r += 1
						frames *= 4
			else:
				col -= 1
				if col < 0:
					col = 0
					if r != 0:
						col = 19
						r -= 1
						frames *= 4
		if down.up or down.down:
			r = clampi(r + 1 if down.down else r - 1, 0, ROWS - 1)
	_glide_to(col, r, frames)


func _glide_to(col: int, r: int, frames: int) -> void:
	if col == column and r == row:
		return
	column = col
	row = r
	rest_pos = _rest(col, r)
	glide_pos = Vector2(cursor_pos) + Vector2(0.5, 0.5)
	glide_step = Vector2(rest_pos - cursor_pos) / frames
	glide_frames = frames


## One frame of the glide; true while it is still going.
func _glide_step() -> bool:
	if glide_frames == 0:
		return false
	glide_pos += glide_step
	cursor_pos = Vector2i(floori(glide_pos.x), floori(glide_pos.y))
	glide_frames -= 1
	if glide_frames == 0:
		cursor_pos = rest_pos
		sound.emit(0x35)
		_show_info()
	return glide_frames != 0


## The grid scrolls when the cursor is less than 0x40 from the top or 0xB0 from the bottom.
func _scroll() -> void:
	var d := cursor_pos.y - view_y
	if d < 0x40:
		view_y = cursor_pos.y - 0x40
	if d >= 0xB0:
		view_y = cursor_pos.y - 0xB0
	view.position = Vector2(0, -view_y)


## The info box: "e" and the card number (three digits), then the card's name on  the line below. A card the
## player has not seen gives no line at all.
func _show_info() -> void:
	_clear(info)
	var id := _card_at(column, row)
	if id == 0 or not _card_seen(id):
		return
	text.layout(info, box_view.bytes_of("e%3d  " % id), Vector2(16, 202), Vector2(8, 12), 0, sharp, true)
	text.layout(info, _name_bytes(id), Vector2(16, 216), Vector2(8, 12), 0, sharp, true)


## A card's name as the game's byte stream (the extracted name string; spelled from the card data when it is missing).
func _name_bytes(id: int) -> Array:
	if text.has_method("card_name_bytes"):
		var bytes: Array = text.card_name_bytes(id)
		if not bytes.is_empty():
			return bytes
	return box_view.bytes_of(cards.card(id)["name"])


func _open_card() -> void:
	wheel_steps = 0
	hover_pending = Vector2i(-1, -1)
	selected = _card_at(column, row)
	ModArt.apply(art, cards.art(selected))
	box_view.build(card_text, icons, selected, cards.card(selected))
	state = "opening"
	slide = 0
	sound.emit(0x32)
	_place_card()
	_set_visibility()


func _slide_step() -> void:
	if state == "opening":
		slide += 1
		if slide >= SLIDE_FRAMES:
			state = "card"
	else:
		slide -= 1
		if slide <= 0:
			state = "grid"
			sound.emit(0x33)
	_place_card()
	_set_visibility()


## The card view's slide: 180 pixels out to the right at rest on the screen's right edge, eased in.
func _place_card() -> void:
	card_view.position = Vector2(180.0 * cos(float(slide) / SLIDE_FRAMES * PI / 2.0), 0)


func _set_visibility() -> void:
	var on_grid := state == "grid" or state == "opening"
	view.visible = on_grid
	cross.visible = on_grid
	band.visible = on_grid
	info.visible = on_grid
	card_view.visible = state != "grid"


func _tile_kind(id: int) -> int:
	return TILE_KINDS.get(cards.card(id)["type"], 0)


## Drawing the card grid: the eight section panels of the rows on screen, then the card tiles of those rows in each type's colours.
func _draw_grid() -> void:
	var first := (view_y - 8) / 178
	if first < 0:
		return
	for section in range(first, SECTIONS):
		if section * 178 + 8 - view_y >= 240:
			return
		for block in 2:
			_panel(section * 2 + block, block)
		for line in 10:
			var y := section * 178 + line * 16 + 8
			if y - view_y + 12 <= 0:
				continue
			if y - view_y >= 240:
				return
			for k in 10:
				var id := section * 200 + line * 10 + k + 1
				_tile(id, Vector2(k * 14 + 8, y))
				_tile(id + 100, Vector2(k * 14 + 168, y))


func _panel(index: int, _block: int) -> void:
	if index >= panels.size():
		return
	var piece: Dictionary = panels[index]
	grid.draw_texture(piece["texture"], piece["at"])


## One card's tile: drawn only for a seen card (the seen mark is 0x80); a card the player does not own is at half brightness.
## The ids past the last card are empty cells.
func _tile(id: int, at: Vector2) -> void:
	if id > CARD_COUNT or not _card_seen(id):
		return
	var tint := Color.WHITE if _card_owned(id) else NOT_OWNED_TINT
	grid.draw_texture(tiles[_tile_kind(id)], at, tint)


## The crosshair through the cursor, to the screen's edges, its colour pulsing with the frame count (the end of the grid drawing),
## and the cursor sprite on its cell.
func _draw_cross() -> void:
	if (view_y - 8) / 178 < 0:
		return
	var v := frame & 0x7F
	var g0 := 0
	var g1 := 0
	match v / 32:
		0:
			g0 = v * 8
		1:
			g0 = 255
			g1 = (v - 32) * 8
		2:
			g0 = (0x5F - v) * 8
			g1 = 255
		3:
			g1 = (0x7F - v) * 8
	var at := Vector2(cursor_pos.x, cursor_pos.y - view_y)
	var colours := PackedColorArray([Color(0, g0 / 255.0, 0), Color(0, g1 / 255.0, 0)])
	for target in [Vector2(0, at.y), Vector2(320, at.y), Vector2(at.x, 0), Vector2(at.x, 240)]:
		cross.draw_polyline_colors(PackedVector2Array([at, target]), colours, 1.0)
	cross.draw_texture(cursor_piece["texture"], at + cursor_piece["at"])


## The card view's box: the library's own frame picture (assets/screens/library/card_frame.png), behind the art and the text.
func _draw_frame() -> void:
	frame_node.draw_texture(frame_piece["texture"], frame_piece["at"])
