extends RefCounted
## The duel field as the game draws it: the board model of the chosen terrain (the HMD in the terrain package's phase 11, with
## the textures the package's phases upload) seen from the duel's camera (the routine at 0x800178BC and the view orbit: distance,
## elevation and heading in the view record, a reference point that moves along z with the cursor row through the data at 0x800907AC,
## the projection 300 centred on line 108). The cards are textured quads lying on the board at their grid slots (the field card
## drawing and the routine at 0x80015EF4): a card on the field hangs 24 units above the board (out_y = -0x18), a face-down card shows
## its back, a defence-position card is turned a quarter turn, and the foe's cards are turned a half turn.
##
## The game's units are kept: x right, y down (a card's height above the board is negative), z forward. Godot is y up, z toward
## the viewer, so every point is mapped (x, y, z) -> (x, -y, -z). The field is drawn 264 lines tall so that the game's centre
## (line 108) is the middle of the view; the picture shows lines 24 to 263 of it.
##
## The camera (the view record of the duel): the opening sweep (the startup state of the duel scene: distance 0x4B0 to 0x258,
## elevation 0x358 to 0x100 and heading 0x16C0 to 0x400, each stepped by 2, 2 and 16 a frame over 300 frames); the hand view
## (distance 600, elevation 256); the field view for a monster cursor (distance 334, elevation 1022, eased over 16 frames); a turn
## swing (48 frames to the hand view and the turn side's heading, 0x400 for the player and 0xC00 for the foe); and the reference
## point's z tween (8 frames per row). Every tween is linear per frame, as the game's view tween (the routine at 0x80022D94).
##
## Card motion: a card placed on the field drops from out_y = -0xF0 to -0x18 (the routine at 0x8001B170: the sine slide over about 25
## frames, here an ease over the same frames); a card that leaves the field flashes where it was; an attacker lunges toward its
## target. The layout (assets/screens/duel_field/layout.json) and the terrain models come from tools/extract.py --screens.

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const DIR := "res://assets/screens/duel_field/"
const VIEW_HEIGHT := 264
const SHIFT := 24.0                  # the picture's first line within the view (the field viewport's line 24 is the picture's line 0)
const TURN := TAU / 4096.0
const TWEEN_FRAMES := 8              # frames for the reference point to move to a new row (the routine at 0x80023D08 uses 8 or 16)
const NEAR_DISTANCE := 334.0         # the field view (the routine at 0x800178BC; the monster cursor's view)
const NEAR_ELEVATION := 1022.0
const FAR_DISTANCE := 600.0          # the hand view (the startup's end and the turn switch)
const FAR_ELEVATION := 256.0
const VIEW_FRAMES := 16              # frames for the field view to ease in or out (the routine at 0x80022D94 with 16)
const TURN_FRAMES := 48              # frames for the turn swing (the turn switch state)
const INTRO_FRAMES := 300            # the opening sweep (the startup state's 300 frames)
const INTRO_FADE_FRAMES := 32        # the duel's opening fade from black (the original's start in routine: the level steps 8 a frame over 0 to 255)
const INTRO_START := [1200.0, 856.0, 5824.0]   # the opening's distance, elevation and heading (0x4B0, 0x358, 0x16C0)
const CARD_HEIGHT := -24.0           # a card on the field: out_y = -0x18 (the routine at 0x8001B170, the routine at 0x80024C1C)
const SPAWN_HEIGHT := -240.0         # where a placed card starts: out_y = -0xF0
const DROP_FRAMES := 25              # field_60 climbs from -0x400 by 0x2A to 0 (the routine at 0x8001B170)
const FLASH_FRAMES := 14
const DEFENCE_TURN_FRAMES := 8        # a card changing between attack and defence turns a quarter (90 degrees) about its vertical axis over 8
									 # frames, one step a frame (the defence rotation routine at 0x8001D240 steps 8 of 256 units a frame)
const FLIP_FRAMES := 8               # a face-down card turning over: a colour pulse over 8 frames, the picture changing at its middle
const LUNGE_FRAMES := 16
const LUNGE_SHARE := 0.35            # how far an attacker moves toward its target, as a share of the way
const CARD_QUAD := [[-25.0, 29.0], [26.0, 29.0], [-25.0, -30.0], [26.0, -30.0]]   # the routine at 0x80015EF4's corners (x, z); the top is z = 29
const FLAT_SIZE := Vector2(52.0, 60.0)   # a card in the field view is a flat sprite of the card's size (the same routine's ground sprite,
										 # a POLY_FT4 flattened to the board: it is not foreshortened, see _place_sprites)

var layout: Dictionary = {}
var terrain := -1
var viewport := SubViewport.new()
var camera := Camera3D.new()
var board := Node3D.new()
var cards := Node3D.new()
var screen := Sprite2D.new()
var plate: Sprite2D = null         # the FIELD box (the terrain's name)
var plate_x := 0.0                 # the box's rest x (plate.json)
var plate_shift := 0.0             # the box's shift from its rest x (the battle's slide)
var view_side := 0                  # the side whose heading the view uses (the turn side)
var cam := [FAR_DISTANCE, FAR_ELEVATION, 1024.0, 0.0]   # the view now: distance, elevation, heading (game units), reference z
var cam_from: Array = []
var cam_to: Array = []
var cam_total := 0
var cam_left := 0
var last_target: Array = []         # the view the tween is heading for (a new target is started only when it changes)
var near := false                   # the field view (a monster cursor is on the board) or the hand view
var intro_running := false          # the opening sweep runs; the view does not take other targets until it ends
var intro_fade := -1                # frames left in the opening fade from black (-1: none)
var target_z := 0.0                 # the reference point's z target (the cursor's row)
var focused := -1                   # the row (0 to 3 of the grid) the reference point is moving to or on
var shader_board: Shader
var board_tint := Vector3i(128, 128, 128)   # the board tint the effect programs set (Dark Hole dims it; 128 is neutral)
var board_materials: Array = []
var shader_card: Shader
var shader_flash: Shader
var nodes: Dictionary = {}          # record -> {node, key, side, slot}: the card on the board
var flat_layer := Node2D.new()      # the flat card sprites of the field view, drawn over the board in the viewport
var flights: Dictionary = {}        # record -> {sprite, from, t}: a placed card's 2D flight from its hand slot (begin_flight)
const FLIGHT_DELAY := 36            # the reference: the placed card waits at its hand slot about 36 frames after the confirm (5800 to 5836)
const FLIGHT_OUT := 24              # then slides from the hand slot to the centre point over 24 frames (5836 to 5860)
const FLIGHT_UP := 10               # then leaves the top of the picture over 10 frames (5860 to 5870); the 3D card drops in after
const FLIGHT_CENTRE := Vector2(134, 42)   # the centre step's card (the placement's 2D point), top-left in picture pixels
const FLIGHT_TOP := Vector2(108, -24)     # the sample at 5870 (the card leaving the top of the picture)
const FLAT_OFFSET_Y := -2.0         # the flat sprite sits 2 px higher than the centred cell: the reference's sprite top is 54 on cell 53..113
var sprites: Dictionary = {}        # record -> Sprite2D: the card's flat sprite (shown instead of its 3D quad in the field view)
var object_state: Dictionary = {}   # record -> {pos: Vector3i, spin: Vector3i, brightness: Vector3i, shown: bool}: the cards the effect programs drive (duel_fx.gd CardObjects)
var animations: Array = []          # {node, kind, frames, left, base, to, from}
var ready_ok := false


## Builds the view and the board for a terrain. host gets the viewport (it must be in the tree before the camera is aimed) and the
## screen sprite goes into world. sharp is the screen's pixel material.
func setup(host: Node, world: Node2D, sharp: ShaderMaterial, duel_terrain: int) -> bool:
	if not FileAccess.file_exists(DIR + "layout.json"):
		return false
	layout = JSON.parse_string(FileAccess.get_file_as_string(DIR + "layout.json"))
	if typeof(layout) != TYPE_DICTIONARY:
		return false
	terrain = clampi(duel_terrain, 0, 6)
	shader_board = Shader.new()
	shader_board.code = _shader(false)
	shader_card = Shader.new()
	shader_card.code = _shader(true)
	shader_flash = Shader.new()
	shader_flash.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled, blend_mix;\nuniform vec4 tint : source_color = vec4(1.0);\n" \
			+ "void fragment() {\n\tALBEDO = tint.rgb;\n\tALPHA = tint.a;\n}\n"
	viewport.size = Vector2i(320, VIEW_HEIGHT)   # set_view_scale raises it to the window's resolution
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = false
	# the surround is pure black (the reference frame's background above and around the board); the default clear colour is grey
	var surround := Environment.new()
	surround.background_mode = Environment.BG_COLOR
	surround.background_color = Color(0.0, 0.0, 0.0)
	var environment := WorldEnvironment.new()
	environment.environment = surround
	viewport.add_child(environment)
	host.add_child(viewport)
	viewport.add_child(camera)
	viewport.add_child(board)
	viewport.add_child(cards)
	viewport.add_child(flat_layer)
	camera.fov = rad_to_deg(2.0 * atan((VIEW_HEIGHT * 0.5) / float(layout["projection"])))
	camera.near = 1.0
	camera.far = 6000.0
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.current = true
	screen.centered = false
	screen.position = Vector2(0, -SHIFT)
	screen.texture = viewport.get_texture()
	screen.material = ScreenFit.make_material(false, true)   # the shaded board: takes the PS1 dither when the F9 option is on
	world.add_child(screen)
	_add_plate(world, sharp)
	if not _build_board(DIR + "terrain_%d/" % terrain):
		return false
	view_side = 0
	target_z = 0.0
	cam = [FAR_DISTANCE, FAR_ELEVATION, _heading(0), 0.0]
	last_target = cam.duplicate()
	near = false
	_aim()
	ready_ok = true
	return true


## The terrain's field plate ("FIELD" over the terrain's name): the duel's screen-space object at (12, 24) drawn over the picture.
func _add_plate(world: Node2D, sharp: ShaderMaterial) -> void:
	plate = Sprite2D.new()
	plate.centered = false
	plate.material = sharp
	world.add_child(plate)
	set_terrain_plate(terrain)


## The board takes a new terrain (a field magic's change, once its terrain package has loaded): the board's mesh is built again from the
## terrain's model and textures, as the reference's board changes with the terrain.
func set_board_terrain(duel_terrain: int) -> void:
	var next := clampi(duel_terrain, 0, 6)
	if next == terrain or not ready_ok:
		return
	terrain = next
	for child in board.get_children():
		child.queue_free()
	board_materials.clear()
	_build_board(DIR + "terrain_%d/" % terrain)


## Shows a terrain's name on the FIELD box (the game's SetResourceVariant on the box when a field magic changes the terrain).
func set_terrain_plate(duel_terrain: int) -> void:
	if plate == null:
		return
	var table = JSON.parse_string(FileAccess.get_file_as_string(DIR + "plate.json"))
	var key := str(clampi(duel_terrain, 0, 6))
	if typeof(table) != TYPE_DICTIONARY or not table.has(key):
		return
	var image := Image.load_from_file(DIR + "plate_%s.png" % key)
	if image == null:
		return
	plate.texture = ImageTexture.create_from_image(image)
	plate_x = float(table[key]["x"])
	plate.position = Vector2(plate_x + plate_shift, float(table[key]["y"]))


## Moves the FIELD box by a shift in screen pixels from its rest place (the battle takes it off the left edge and gives it back).
func place_plate(shift: float) -> void:
	plate_shift = shift
	if plate != null:
		plate.position.x = plate_x + shift


## Starts the opening: the view begins at the opening's pose and sweeps to the hand view over INTRO_FRAMES (the startup state).
func open_intro() -> void:
	if not ready_ok:
		return
	cam = [INTRO_START[0], INTRO_START[1], INTRO_START[2], 0.0]
	near = false
	target_z = 0.0
	cam_to = [FAR_DISTANCE, FAR_ELEVATION, _heading(view_side), target_z]
	last_target = cam_to.duplicate()
	cam_from = cam.duplicate()
	cam_total = INTRO_FRAMES
	intro_fade = INTRO_FADE_FRAMES
	screen.modulate = Color(0.0, 0.0, 0.0, 1.0)
	cam_left = INTRO_FRAMES
	intro_running = true
	_aim()


## The GTE depth cue (NCDS and RotColorDpq, the board's and the cards' colour op): per vertex, the factor IR0 is
## clamp((H * 0x10000 / SZ3) * DQA + DQB >> 12, 0, 0x1000), with SZ3 the vertex depth, H the projection and DQA, DQB from
## SetFogNearFar(650, 800, H) (the SDK's fog set-up routine). The colour is the lit colour
## mixed toward the far colour (black) by IR0 / 0x1000, interpolated across the polygon as the GTE's Gouraud shading does.
static func _fog_constants(near: int, far: int, h: int) -> Vector2i:
	var span := far - near
	var dqa := (((-near * far) / span) << 8) / h
	dqa = clampi(dqa, -32767, 32767)
	var dqb := ((far << 12) / span) << 12
	return Vector2i(dqa, dqb)


func _shader(cards_too: bool) -> String:
	var fog_k := _fog_constants(650, 800, int(layout["projection"]))
	var code := "shader_type spatial;\nrender_mode unshaded, cull_disabled;\nuniform sampler2D albedo_texture : filter_nearest;\n"
	code += "varying float fog;\n"
	# the console's 4 x 4 ordered dither, indexed by the screen pixel's row and column (modulo 4)
	code += "const float DITHER[16] = float[16](-4.0, 0.0, -3.0, 1.0, 2.0, -2.0, 3.0, -1.0, -3.0, 1.0, -4.0, 0.0, 3.0, -1.0, 2.0, -2.0);\n"
	code += "const float H = %d.0;\nconst float DQA = %d.0;\nconst float DQB = %d.0;\n" % [int(layout["projection"]), fog_k.x, fog_k.y]
	code += "void vertex() {\n\tfloat sz = max(-(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z, 1.0);\n"
	code += "\tfloat mac0 = (H * 65536.0 / sz) * DQA + DQB;\n\tfog = clamp(mac0 / 4096.0, 0.0, 4096.0) / 4096.0;\n}\n"
	code += "void fragment() {\n\tvec4 c = texture(albedo_texture, UV);\n"
	var tint := ""
	if not cards_too:
		code = code.replace("uniform sampler2D albedo_texture : filter_nearest;\n", "uniform sampler2D albedo_texture : filter_nearest;\nuniform vec4 board_tint : source_color = vec4(1.0);\nuniform float dither_px = 1.0;\n")
		tint = " * board_tint.rgb"
	if cards_too:
		code = code.replace("uniform sampler2D albedo_texture : filter_nearest;\n", "uniform sampler2D albedo_texture : filter_nearest;\nuniform vec4 flip_tint : source_color = vec4(1.0);\n")
		code += "\tif (c.a < 0.5) { discard; }\n"
		tint = " * flip_tint.rgb"      # the flip's colour pulse (a card turning over, see _animate)
	# the board is not depth-cued in the reference frame (its far rows stay bright, measured on the real 2P screen): only the cards take the fog
	# the board's colour is stored halved (see _build_board): doubled here; the cards' own colour is white and stays as it is
	if cards_too:
		code += "\tALBEDO = c.rgb * COLOR.rgb" + tint + " * (1.0 - fog);\n}\n"
	else:
		# the board is drawn the way the console draws a dithered textured polygon: the texel (8 bits) times the lit factor
		# (COLOR * 2, times the board tint), truncated; the 4 x 4 ordered dither added at the screen pixel (FRAGCOORD); the sum
		# clamped and cut to five bits a channel. Every textured board polygon of the reference has its dither on.
		code += "\tvec3 t8 = floor(c.rgb * 255.0 + 0.5);\n"
		code += "\tvec3 f8 = floor(t8 * COLOR.rgb * 2.0" + tint + ");\n"
		# the pixel of the 320 x 240 picture (the field viewport is view_scale times that size: dither_px is the scale)
		code += "\tfloat dd = DITHER[(int(mod(floor(FRAGCOORD.y / dither_px), 4.0)) * 4) + int(mod(floor(FRAGCOORD.x / dither_px), 4.0))];\n"
		code += "\tvec3 q = floor(clamp(f8 + vec3(dd), 0.0, 255.0) / 8.0) * 8.0;\n"
		code += "\tALBEDO = q / 255.0 * (1.0 - fog);\n}\n"
	return code


## The heading of a side's view in game units (the layout's headings: 0x400 for the player, 0xC00 for the foe).
func _heading(side: int) -> float:
	return float(layout["headings"][side])


## The camera: the view orbit's eye for the reference point (0, 0, its z), in game units, then mapped to Godot.
func _aim() -> void:
	var distance: float = cam[0]
	var elevation: float = float(cam[1]) * TURN
	var heading: float = float(cam[2]) * TURN
	var n := -distance
	var x := n * cos(elevation)
	var rise := n * sin(elevation)
	var reference_z: float = cam[3]
	var eye := Vector3(x * cos(heading), rise, x * sin(heading) + reference_z)
	var target := Vector3(0.0, 0.0, reference_z)
	# the screen's up is the horizontal direction away from the eye (the view's forward on the ground), so the roll follows the
	# heading and never flips: the view is the same board turned about the vertical axis, at any heading and during the swing.
	var g_eye := _godot(eye)
	var g_target := _godot(target)
	var ahead := Vector3(g_target.x - g_eye.x, 0.0, g_target.z - g_eye.z)
	if ahead.length() < 0.0001:
		ahead = Vector3.FORWARD
	camera.look_at_from_position(g_eye, g_target, ahead.normalized())


static func _godot(p: Vector3) -> Vector3:
	return Vector3(p.x, -p.y, -p.z)


## Starts a view tween toward the state the view is in now (the field or hand distance, the side's heading and the reference z).
## Nothing starts while the opening sweep runs, and a target already reached or heading there is left alone.
func _retarget(frames: int, always := false) -> void:
	if intro_running:
		return
	var target := [NEAR_DISTANCE if near else FAR_DISTANCE, NEAR_ELEVATION if near else FAR_ELEVATION, _heading(view_side), target_z]
	if target == last_target and not always:
		return
	last_target = target
	cam_to = target
	if frames <= 0:
		cam = target.duplicate()
		cam_left = 0
		_aim()
		return
	cam_from = cam.duplicate()
	cam_total = frames
	cam_left = frames


## The view turns to a side: its heading swings over the frames given (the turn switch's 48 frames, or none).
func set_view_side(side: int, frames := 0) -> void:
	if side == view_side:
		return
	view_side = side
	focused = -1
	_retarget(frames)


## The field view on (a monster cursor is on the board) or off (the hand view), easing over VIEW_FRAMES.
func show_near(on: bool) -> void:
	if on == near:
		return
	near = on
	_retarget(VIEW_FRAMES)


## The view's reference point moves to the row of a card record of a side (the cursor's zone), a few frames at a time. Asking
## for the row the view is already on does nothing, so this can be called every frame.
func focus(side: int, record: int, frames := TWEEN_FRAMES) -> void:
	set_view_side(side, 0)
	var slot := slot_of(record)
	if slot < 0 or slot / 5 == focused:
		return
	focused = slot / 5
	var refs: Array = layout["reference_z"][side][0]
	target_z = float(refs[focused])
	_retarget(frames)


## The field view turns to the row of a card record (a trap's zone when an attack springs it) without changing the view side: the
## field view on, the reference point on the record's row, over VIEW_FRAMES (the reference's pan to the trap).
func pan_to(record: int) -> void:
	var slot := slot_of(record)
	if slot < 0:
		return
	near = true
	focused = slot / 5
	var refs: Array = layout["reference_z"][view_side][0]
	target_z = float(refs[focused])
	_retarget(VIEW_FRAMES, true)


## The battle's view: the field view gives way to the hand view (the reference point goes back to 0), all three values over the
## VIEW_FRAMES of the field view's tween (the reference's battle swing: distance 334 to 600, elevation 1022 to 256, z -119 to 0).
func swing_out() -> void:
	near = false
	focused = -1
	target_z = 0.0
	_retarget(VIEW_FRAMES, true)


func tick() -> void:
	if not ready_ok:
		return
	_advance_flights()
	if cam_left > 0:
		cam_left -= 1
		if cam_left == 0:
			cam = cam_to.duplicate()
			intro_running = false
		else:
			var t := 1.0 - float(cam_left) / float(cam_total)
			for k in 4:
				cam[k] = lerpf(float(cam_from[k]), float(cam_to[k]), t)
		_aim()
	_animate()
	_apply_objects()
	_place_sprites()
	if intro_fade > 0:
		intro_fade -= 1
		var level := 1.0 - float(intro_fade) / float(INTRO_FADE_FRAMES)
		screen.modulate = Color(level, level, level, 1.0)
	if intro_fade == 0:
		intro_fade = -1
		screen.modulate = Color(1.0, 1.0, 1.0, 1.0)


## The grid slot (0 to 19) a card record has in the view side's table, or -1.
func slot_of(record: int) -> int:
	var table: Array = layout["records"][view_side]
	for slot in table.size():
		if int(table[slot]) == record:
			return slot
	return -1


## The board position (game units, height 0) of a card record in the view side's table.
func grid_position(record: int) -> Vector3:
	var slot := slot_of(record)
	if slot < 0:
		return Vector3.ZERO
	var at: Array = layout["grid"][view_side][slot]
	return Vector3(float(at[0]), 0.0, float(at[1]))


## The screen point (in the picture) of a card record's grid cell on either side, or ZERO when the record has no cell. The zone cursor
## is placed from this point, as the field cursor is placed from its cell's screen position.
func cell_point(record: int) -> Vector2:
	for side in 2:
		var table: Array = layout["records"][side]
		for slot in table.size():
			if int(table[slot]) == record:
				var at: Array = layout["grid"][side][slot]
				if near:
					return _flat_box(Vector3(float(at[0]), 0.0, float(at[1]))).get_center()
				# the card's own height: a card on the field hangs at CARD_HEIGHT, and the zone's point must agree with the card drawn there
				return project(Vector3(float(at[0]), CARD_HEIGHT, float(at[1])))
	return Vector2.ZERO


## The flat card sprite's rectangle (picture pixels) for a board point: the sprite is centred on the card's cell, whole pixels.
func _flat_box(ground: Vector3) -> Rect2:
	var centre := project(ground).round()
	return Rect2(centre - FLAT_SIZE * 0.5 + Vector2(0.0, FLAT_OFFSET_Y), FLAT_SIZE)


## A placed card's 2D flight (the reference's placement): the card's flat sprite leaves its hand slot (from, the picture's top-left),
## slides to the centre point and off the top, then the 3D card drops in (_start_drop). The 3D card is hidden until then.
func begin_flight(record: int, from: Vector2) -> void:
	if flights.has(record):
		_end_flight(record, false)
	var sprite := Sprite2D.new()
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.visible = false
	flat_layer.add_child(sprite)
	flights[record] = {"sprite": sprite, "from": from, "t": 0}


func _advance_flights() -> void:
	for record in flights.keys():
		var f: Dictionary = flights[record]
		f["t"] += 1
		var u: int = int(f["t"]) - FLIGHT_DELAY
		var sprite: Sprite2D = f["sprite"]
		if u <= 0 or not nodes.has(record) or nodes[record]["texture"] == null:
			continue
		var texture: Texture2D = nodes[record]["texture"]
		var at := Vector2.ZERO
		if u <= FLIGHT_OUT:
			at = (f["from"] as Vector2).lerp(FLIGHT_CENTRE, sin(float(u) / FLIGHT_OUT * PI * 0.5))
		else:
			at = FLIGHT_CENTRE.lerp(FLIGHT_TOP, minf(float(u - FLIGHT_OUT) / FLIGHT_UP, 1.0))
		var size := texture.get_size()
		sprite.texture = texture
		sprite.visible = true
		sprite.scale = Vector2(view_scale * FLAT_SIZE.x / size.x, view_scale * FLAT_SIZE.y / size.y)
		sprite.position = Vector2((at.x + FLAT_SIZE.x * 0.5) * view_scale, (at.y + FLAT_SIZE.y * 0.5 + SHIFT) * view_scale)
		if u >= FLIGHT_OUT + FLIGHT_UP:
			_end_flight(record, true)


func _end_flight(record: int, drop: bool) -> void:
	var f: Dictionary = flights[record]
	(f["sprite"] as Sprite2D).queue_free()
	flights.erase(record)
	if drop:
		_start_drop(record)


## The 3D card drops onto its cell from the spawn height (the flight's end).
func _start_drop(record: int) -> void:
	if not nodes.has(record):
		return
	var node: MeshInstance3D = nodes[record]["node"]
	var base := grid_position(record) + Vector3(0.0, CARD_HEIGHT, 0.0)
	animations.append({"node": node, "kind": "drop", "frames": DROP_FRAMES, "left": DROP_FRAMES,
			"base": _godot(base), "from": _godot(base + Vector3(0.0, SPAWN_HEIGHT - CARD_HEIGHT, 0.0))})
	node.position = _godot(base + Vector3(0.0, SPAWN_HEIGHT - CARD_HEIGHT, 0.0))


## The screen point (in the game's 320 x 240 picture) of a board point at a height above it.
func project(point: Vector3) -> Vector2:
	var view := camera.unproject_position(_godot(point)) / float(view_scale)
	return Vector2(view.x, view.y - SHIFT)


## The field's internal resolution: the board is drawn at view_scale times the 320 x 264 picture (the same projection, the same
## geometry), so its edges stay sharp at window sizes; the picture's own texels keep their nearest look. The sprite shows the viewport
## at 1 / view_scale. The scale is kept to 1..VIEW_SCALE_MAX (the web build stays small).
const VIEW_SCALE_MAX := 4
var view_scale := 1


func set_view_scale(k: int) -> void:
	k = clampi(k, 1, VIEW_SCALE_MAX)
	if k == view_scale or not ready_ok:
		return
	view_scale = k
	viewport.size = Vector2i(320 * k, VIEW_HEIGHT * k)
	screen.scale = Vector2(1.0 / k, 1.0 / k)
	for material in board_materials:
		(material as ShaderMaterial).set_shader_parameter("dither_px", float(k))


## The screen box of a card on its slot, as the box of its four corners at the height a card on the field hangs at.
func card_box(record: int) -> Rect2:
	if near:
		return _flat_box(grid_position(record))
	var centre := grid_position(record) + Vector3(0.0, CARD_HEIGHT, 0.0)
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for corner in CARD_QUAD:
		var p := project(centre + Vector3(corner[0], 0.0, corner[1]))
		low = low.min(p)
		high = high.max(p)
	return Rect2(low, high - low)


## The board's picture and the field plate shown or hidden: the card viewer's screen is black, with neither (duel_scene.gd _draw_panel).
func set_shown(on: bool) -> void:
	screen.visible = on
	if plate != null:
		plate.visible = on


## Updates the cards on the board. Each entry: {record, texture, back (Texture2D), face_down, defense, foe}. A card whose entry is
## unchanged keeps its node; a card that is new drops in; a card that is gone flashes where it was. A card that stays on its slot
## turns in place when it changes between attack and defence (a quarter turn, _start_turn) and flips when it changes face (_start_flip).
func set_cards(entries: Array) -> void:
	if not ready_ok:
		return
	var wanted := {}
	for entry in entries:
		var record := int(entry["record"])
		wanted[record] = true
		var face_down := bool(entry.get("face_down", false))
		var defense := bool(entry.get("defense", false))
		var texture: Texture2D = entry["back"] if face_down else entry["texture"]
		var key := "%s|%s|%s|%s" % [str(view_side), str(texture), str(face_down), str(defense)]
		if nodes.has(record) and nodes[record]["key"] == key and nodes[record]["side"] == view_side:
			continue
		var old: Dictionary = nodes.get(record, {})
		if not old.is_empty() and texture != null and old["side"] == view_side and old["texture"] != null:
			var turning: MeshInstance3D = old["node"]
			if bool(old["defense"]) != defense:
				_start_turn(turning, -90.0 if defense else 90.0)
			if old["texture"] != texture:
				_start_flip(turning, texture)
			nodes[record] = {"node": turning, "key": key, "side": view_side, "texture": texture, "defense": defense}
			continue
		var fresh := not nodes.has(record)
		if not fresh:
			_remove_node(record, false)
		if texture == null:
			continue
		var node := MeshInstance3D.new()
		node.mesh = _card_mesh(texture)
		var turn := 0.0
		if defense:
			turn += 270.0
		if bool(entry.get("foe", false)):
			turn += 180.0
		node.rotation_degrees = Vector3(0.0, turn, 0.0)
		cards.add_child(node)
		nodes[record] = {"node": node, "key": key, "side": view_side, "texture": texture, "defense": defense}
		_place(record, node, fresh)
	for record in nodes.keys():
		if not wanted.has(record):
			_remove_node(record, true)


## A card turns a quarter about its vertical axis (its attack and defence positions differ by that turn): delta is -90 going into
## defence, +90 coming out of it. The turn runs over TURN_FRAMES from the card's angle now.
func _start_turn(node: MeshInstance3D, delta: float) -> void:
	for i in range(animations.size() - 1, -1, -1):
		if animations[i]["node"] == node and animations[i]["kind"] == "turn":
			animations.remove_at(i)
	var from := node.rotation_degrees.y
	animations.append({"node": node, "kind": "turn", "frames": DEFENCE_TURN_FRAMES, "left": DEFENCE_TURN_FRAMES, "from": from, "to": from + delta})


## A card turns over to a new face (a face-down card revealed, or a card set down): its colour pulses over FLIP_FRAMES and the picture
## changes at the pulse's middle (duel_field_3d.gd's flip is a stand-in for the game's colour sweep over 8 frames).
func _start_flip(node: MeshInstance3D, texture: Texture2D) -> void:
	for i in range(animations.size() - 1, -1, -1):
		if animations[i]["node"] == node and animations[i]["kind"] == "flip":
			animations.remove_at(i)
	animations.append({"node": node, "kind": "flip", "frames": FLIP_FRAMES, "left": FLIP_FRAMES, "texture": texture, "swapped": false})


## Puts a card's node on its slot; a card entering the field drops from the spawn height.
func _place(record: int, node: MeshInstance3D, drop: bool) -> void:
	var base := grid_position(record) + Vector3(0.0, CARD_HEIGHT, 0.0)
	node.position = _godot(base)
	if drop and flights.has(record):
		node.position = _godot(base + Vector3(0.0, SPAWN_HEIGHT - CARD_HEIGHT, 0.0))   # the flight holds the card; it drops at the flight's end
	elif drop:
		animations.append({"node": node, "kind": "drop", "frames": DROP_FRAMES, "left": DROP_FRAMES,
				"base": _godot(base), "from": _godot(base + Vector3(0.0, SPAWN_HEIGHT - CARD_HEIGHT, 0.0))})
		node.position = _godot(base + Vector3(0.0, SPAWN_HEIGHT - CARD_HEIGHT, 0.0))


func _remove_node(record: int, flash: bool) -> void:
	if flights.has(record):
		_end_flight(record, false)
	var entry: Dictionary = nodes[record]
	var node: MeshInstance3D = entry["node"]
	if flash and entry["side"] == view_side:
		_flash(node.position)
	cards.remove_child(node)
	node.queue_free()
	nodes.erase(record)
	if sprites.has(record):
		sprites[record].queue_free()
		sprites.erase(record)
	for i in range(animations.size() - 1, -1, -1):
		if animations[i]["node"] == node:
			animations.remove_at(i)


## The field view draws each card as its flat sprite (the reference's ground sprite: 52 x 60, centred on the card's cell, not
## foreshortened); the hand view draws the 3D quad. The 3D quad is hidden from the camera (its layer) while the sprite shows it.
func _place_sprites() -> void:
	var flat := near and cam_left == 0      # the sprite takes over when the field view has arrived (the 3D quad drops in the hand view)
	for record in nodes.keys():
		var entry: Dictionary = nodes[record]
		var node: MeshInstance3D = entry["node"]
		if not sprites.has(record):
			var sprite := Sprite2D.new()
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			flat_layer.add_child(sprite)
			sprites[record] = sprite
		var sprite: Sprite2D = sprites[record]
		var flying := flights.has(record)
		node.layers = 0 if (flat or flying) else 1
		sprite.visible = flat and node.visible and entry["texture"] != null and not flying
		if not sprite.visible:
			continue
		var texture: Texture2D = entry["texture"]
		sprite.texture = texture
		var size := texture.get_size()
		sprite.scale = Vector2(view_scale * FLAT_SIZE.x / size.x, view_scale * FLAT_SIZE.y / size.y)
		# the flat sprite sits FLAT_OFFSET_Y above the centred cell, as _flat_box puts its box (the reference's sprite top is 54 on cell 53..113)
		sprite.position = camera.unproject_position(_godot(grid_position(record))).round() + Vector2(0.0, FLAT_OFFSET_Y * view_scale)
		var tint := Color(1.0, 1.0, 1.0)
		var material: ShaderMaterial = (node.mesh as ArrayMesh).surface_get_material(0)
		var pulse = material.get_shader_parameter("flip_tint") if material != null else null
		if pulse is Color:
			tint = pulse
		sprite.modulate = tint


## A white burst where a card left the board (the game's destruction flash, faded out over FLASH_FRAMES).
func _flash(at: Vector3) -> void:
	var node := MeshInstance3D.new()
	var quad := ArrayMesh.new()
	var c: Array = CARD_QUAD
	var verts := PackedVector3Array([Vector3(c[0][0], 0.0, -c[0][1]), Vector3(c[2][0], 0.0, -c[2][1]), Vector3(c[1][0], 0.0, -c[1][1]),
			Vector3(c[1][0], 0.0, -c[1][1]), Vector3(c[2][0], 0.0, -c[2][1]), Vector3(c[3][0], 0.0, -c[3][1])])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := ShaderMaterial.new()
	material.shader = shader_flash
	material.set_shader_parameter("tint", Color(1.0, 1.0, 1.0, 0.9))
	quad.surface_set_material(0, material)
	node.mesh = quad
	node.position = at
	cards.add_child(node)
	animations.append({"node": node, "kind": "flash", "frames": FLASH_FRAMES, "left": FLASH_FRAMES, "base": at, "material": material})


## The board tint (the overlay's global colour the board is drawn with): the board materials take it, 128 is neutral.
func set_board_tint(rgb: Vector3i) -> void:
	board_tint = rgb
	for material in board_materials:
		if is_instance_valid(material):
			material.set_shader_parameter("board_tint", Color(rgb.x / 128.0, rgb.y / 128.0, rgb.z / 128.0))


## The board point (game units) of a card's object at rest: its grid cell at the card height, in the record's own side's view.
func board_point(record: int) -> Vector3:
	var was := view_side
	view_side = 1 if record >= 20 else 0
	var p := grid_position(record) + Vector3(0.0, CARD_HEIGHT, 0.0)
	view_side = was
	return p


## The effect programs' card objects: each posed card takes its position (game units), its spin (the field_20 bytes: 256 to a turn,
## applied about x and z; y stays the card's turn), its brightness (128 is the neutral tint) and its visibility, every frame.
func _apply_objects() -> void:
	for record in object_state.keys():
		if not nodes.has(record):
			continue
		var s: Dictionary = object_state[record]
		var node: MeshInstance3D = nodes[record]["node"]
		var pos: Vector3i = s["pos"]
		node.position = _godot(Vector3(pos))
		var spin: Vector3i = s["spin"]
		node.rotation = Vector3(float(spin.x) * TAU / 256.0, node.rotation.y, float(spin.z) * TAU / 256.0)
		node.visible = bool(s["shown"])
		var size: Vector2i = s["size"]
		node.scale = Vector3(size.x / 4096.0, 1.0, size.y / 4096.0)
		var b: Vector3i = s["brightness"]
		var material := (node.mesh as ArrayMesh).surface_get_material(0) as ShaderMaterial
		if material != null:
			material.set_shader_parameter("flip_tint", Color(b.x / 128.0, b.y / 128.0, b.z / 128.0))


## Ends the card objects' posing: each card goes back to its board point, upright, lit and shown.
func clear_objects() -> void:
	for record in object_state.keys():
		if not nodes.has(record):
			continue
		var node: MeshInstance3D = nodes[record]["node"]
		node.visible = true
		node.rotation = Vector3(0.0, node.rotation.y, 0.0)
		node.scale = Vector3.ONE
		node.position = _godot(board_point(record))
		var material := (node.mesh as ArrayMesh).surface_get_material(0) as ShaderMaterial
		if material != null:
			material.set_shader_parameter("flip_tint", Color(1.0, 1.0, 1.0))
	object_state.clear()
	set_board_tint(Vector3i(128, 128, 128))


## Makes the card of a record lunge toward another record (an attack); the lunge is a short way toward the target and back.
func lunge(record: int, target: int) -> void:
	if not nodes.has(record) or not nodes.has(target):
		return
	var node: MeshInstance3D = nodes[record]["node"]
	var base := node.position
	var goal: Vector3 = nodes[target]["node"].position
	animations.append({"node": node, "kind": "lunge", "frames": LUNGE_FRAMES, "left": LUNGE_FRAMES, "base": base,
			"to": base.lerp(goal, LUNGE_SHARE)})


func _animate() -> void:
	for i in range(animations.size() - 1, -1, -1):
		var a: Dictionary = animations[i]
		var node: Node3D = a["node"]
		if not is_instance_valid(node):
			animations.remove_at(i)
			continue
		a["left"] -= 1
		var t := 1.0 - float(a["left"]) / float(a["frames"])
		match a["kind"]:
			"drop":
				var ease_t := sin(t * PI * 0.5)
				node.position = (a["from"] as Vector3).lerp(a["base"], ease_t)
			"lunge":
				var wave := sin(t * PI)
				node.position = (a["base"] as Vector3).lerp(a["to"], wave)
			"flash":
				var material: ShaderMaterial = a["material"]
				material.set_shader_parameter("tint", Color(1.0, 1.0, 1.0, 0.9 * (1.0 - t)))
			"turn":
				node.rotation_degrees.y = lerpf(float(a["from"]), float(a["to"]), t)
			"flip":
				var card_node := node as MeshInstance3D
				if not a["swapped"] and t >= 0.5:
					card_node.mesh = _card_mesh(a["texture"])
					a["swapped"] = true
				var pulse := 1.0 - 0.5 * sin(t * PI)
				(card_node.mesh.surface_get_material(0) as ShaderMaterial).set_shader_parameter("flip_tint", Color(pulse, pulse, pulse))
		if a["left"] <= 0:
			match a["kind"]:
				"flash":
					cards.remove_child(node)
					node.queue_free()
				"turn":
					node.rotation_degrees.y = float(a["to"])
				"flip":
					((node as MeshInstance3D).mesh.surface_get_material(0) as ShaderMaterial).set_shader_parameter("flip_tint", Color(1.0, 1.0, 1.0))
				_:
					node.position = a["base"]
			animations.remove_at(i)


func _card_mesh(texture: Texture2D) -> ArrayMesh:
	var c: Array = CARD_QUAD
	var tl := Vector3(c[0][0], 0.0, c[0][1])
	var tr := Vector3(c[1][0], 0.0, c[1][1])
	var bl := Vector3(c[2][0], 0.0, c[2][1])
	var br := Vector3(c[3][0], 0.0, c[3][1])
	# the picture's top is the game's z = 29 edge, which is screen up for the player's view (the camera's up is game +z)
	var v := PackedVector3Array([_godot(tl), _godot(bl), _godot(tr), _godot(tr), _godot(bl), _godot(br)])
	var uv := PackedVector2Array([Vector2(0, 0), Vector2(0, 1), Vector2(1, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := ShaderMaterial.new()
	material.shader = shader_card
	material.set_shader_parameter("albedo_texture", texture)
	mesh.surface_set_material(0, material)
	return mesh


## Builds the board from model.json: one surface per texture, each vertex shaded by the model's own light.
func _build_board(folder: String) -> bool:
	if not FileAccess.file_exists(folder + "model.json"):
		return false
	var model = JSON.parse_string(FileAccess.get_file_as_string(folder + "model.json"))
	if typeof(model) != TYPE_DICTIONARY:
		return false
	var verts: Array = model["vertices"]
	var count := int(model["textures"])
	var surfaces: Array = []
	for i in count:
		surfaces.append({"v": PackedVector3Array(), "uv": PackedVector2Array(), "c": PackedColorArray()})
	for face in model["faces"]:
		var s: Dictionary = surfaces[int(face["t"])]
		for k in 3:
			var p: Array = verts[int(face["v"][k])]
			s["v"].append(_godot(Vector3(p[0], p[1], p[2])))
			var uv: Array = face["uv"][k]
			s["uv"].append(Vector2((float(uv[0]) + 0.5) / 256.0, (float(uv[1]) + 0.5) / 256.0))
			var shade := clampf(float(face["s"][k]) * 0.5, 0.0, 1.0)     # the lit factor (up to 1.5 on the board) is stored halved: a vertex colour is at most 1
			s["c"].append(Color(shade, shade, shade))
	var mesh := ArrayMesh.new()
	for i in count:
		var s: Dictionary = surfaces[i]
		if s["v"].is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = s["v"]
		arrays[Mesh.ARRAY_TEX_UV] = s["uv"]
		arrays[Mesh.ARRAY_COLOR] = s["c"]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := ShaderMaterial.new()
		material.shader = shader_board
		material.set_shader_parameter("board_tint", Color(board_tint.x / 128.0, board_tint.y / 128.0, board_tint.z / 128.0))
		material.set_shader_parameter("dither_px", float(view_scale))
		board_materials.append(material)
		var image := Image.load_from_file(folder + "texture_%d.png" % i)
		if image != null:
			material.set_shader_parameter("albedo_texture", ImageTexture.create_from_image(image))
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	board.add_child(instance)
	return true
