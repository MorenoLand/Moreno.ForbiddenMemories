extends Control
## The campaign map (the campaign map run, the original's set location routine / UpdateLocation / PickExit / UpdateLocationTransition): the 3D terrain
## seen from the camera of the current place, the place's name, and movement between the sixteen places along their exits. Confirm on a
## place with no destination of its own leaves the map (finished(place): the story then runs scene place + 32).
##
## The terrain, textures and the place table come from tools/extract.py --screens (assets/screens/map/). The place table is the
## game's: camera distance / heading / pitch / target, and four exits (story flag, arrow position, direction mask, destination,
## steps). Direction masks: up 0x1000, right 0x2000, down 0x4000, left 0x8000.
##
## A move runs the original's update location transition routine for its steps: the camera tween, the Millennium Puzzle marker's cosine slide between
## two marker places, and the spotlight's panel slide (its inner radius 180 -> 32 when a marker place is left for a plain one, 32 -> up
## when a plain place is left for a marker one). The departure (a confirm with no destination, or the tournament's cancel) moves the
## camera back 2 per frame while the screen fades to black, and the map ends when the fade does.
##
## Not built: the track fade is only signalled (music_fade); the tournament's cancel is the Q / Esc / Backspace keys, as the duel uses.

signal finished(place: int)
signal sound(effect: int)
signal music(id: int)           # the BGM play: the map's track when it opens (0x70A0, or 0x70B0 once the tournament is complete)
signal music_fade(step: int)    # the BGM fade-out with a step: the track fades out as the map leaves

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const GameState := preload("res://scripts/state/game_state.gd")

const DIR := "res://assets/screens/map/"
const TOURNAMENT_FLAG := 0x47            # the tournament complete flag: selects the after-the-tournament package
const TRACK := 0x70A0
const TRACK_AFTER_TOURNAMENT := 0x70B0
const NAME_STRING := 0x8350              # place n's name
const GLOBAL_BANK := "res://assets/screens/text_bank_global.bin"
var global_bank := PackedByteArray()
const NAME_ORIGIN := Vector2(96, 24)
# the name's dark plate behind the letters: the reference frame has a near-black panel over the wood banner at x 94 to 226, y 21 to 45
# (measured on the frame; the label's own text box is 96, 24, 128 x 12, its panel not yet ported)
const NAME_PLATE := Rect2(94, 21, 132, 24)
const NAME_PLATE_COLOUR := Color(14.0 / 255.0, 10.0 / 255.0, 14.0 / 255.0)
const PROJECTION := 300.0
const FOG_NEAR := 2000.0
const FOG_FAR := 2400.0
const TURN := TAU / 4096.0
const MASK_UP := 0x1000
const MASK_RIGHT := 0x2000
const MASK_DOWN := 0x4000
const MASK_LEFT := 0x8000
const SE_MOVE := 6
const SE_CONFIRM := 48
const CANCEL_KEYS := [KEY_Q, KEY_ESCAPE, KEY_BACKSPACE]
const MARKER_FROM := 10                  # places from 10 on carry the Millennium Puzzle marker (the original's set location routine: index >= 10)
const MARKER_SPAN := 2048                # f96 runs 0..2048 over the move
const GO_STEPS := 24                     # the original's pick exit routine's MoveState for a confirm-to-destination and for the cancel
const SPOT_INNER := 32                   # the spotlight's inner radius at rest (f72); its outer radius (f74) is 160 further out
const SPOT_WIDTH := 160
const SPOT_SLIDE_IN := 180               # the retract a marker place's spotlight starts from when a plain place is entered
const SPOT_SLIDE_STEP := 7
const DEPART_STEP := 2                   # the original's update location routine: the distance (field_00) drops by 2 a frame while the map leaves
const FADE_STEP := 2                     # the data at 0x800E9ECF = 2: the departure fade's step per tick
const FADE_TICK := 1                     # the data at 0x8009B0D8 at the normal rate

var text := GameText.new()
var places: Array = []
var place := 0
var world := Node2D.new()
var viewport := SubViewport.new()
var screen := Sprite2D.new()
var camera := Camera3D.new()
var sharp: ShaderMaterial
var name_layer := Node2D.new()
var spotlight := ColorRect.new()
var panel_layer := Node2D.new()
var marker_layer := Node2D.new()
var ready_ok := false
var remaining := 0              # the data at 0x801695D4: the frames the move has left (0 when there is no move)
var tween_steps := 1
var from_pose: Array = []       # [distance, pitch, heading, target x, target z]
var to_pose: Array = []
var pose: Array = []
var held: Dictionary = {}
var sprite_frames: Dictionary = {}   # name -> [{texture, duration, x, y}] (assets/screens/map/sprites)
var hud := Node2D.new()              # the exit arrows
var animated: Array = []             # [{node, frames, index, wait, at}]
var click_confirm := false           # a click off the arrows: confirm, as E
var click_exit := -1                 # a click on an exit arrow: the index into the place's exits
var spot_inner := SPOT_INNER         # f72: the spotlight's inner radius
var spot_on := true                  # the spotlight's renderable flag (f8 bit 0x40)
var slide := 0                       # the data at 0x801695EC & 0x60: 0x40 the spotlight slides, 0x20 it retracts
var marker_entry: Dictionary = {}    # the data at 0x801695C8: the Millennium Puzzle marker, its "at" is its drawn position (f48/f50)
var marker_start := Vector2.ZERO     # the marker's position when the move began (SavePosition)
var marker_progress := 0             # f96
var departing := false               # the data at 0x8016960D: the map is leaving
var ended := false                   # the departure has reported finished
var leave_level := 255               # the departure fade's level (0xFF down to 0)
var leave_shade := ColorRect.new()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all():
		return
	var after := GameState.test_flag(TOURNAMENT_FLAG)
	var label := "after" if after else "before"
	var json = JSON.parse_string(FileAccess.get_file_as_string(DIR + "places_%s.json" % label)) \
			if FileAccess.file_exists(DIR + "places_%s.json" % label) else null
	if typeof(json) != TYPE_ARRAY:
		return
	places = json
	if not _build_terrain(DIR + label + "/"):
		return
	sharp = ScreenFit.make_material()
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(world)
	add_to_group("fit")
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	camera.fov = rad_to_deg(2.0 * atan(120.0 / PROJECTION))
	camera.near = 8.0
	camera.far = 12000.0
	viewport.add_child(camera)
	viewport.add_child(terrain)
	var back := ColorRect.new()
	back.color = Color.BLACK
	back.size = Vector2(320, 240)
	world.add_child(back)
	screen.centered = false
	screen.texture = viewport.get_texture()
	screen.material = sharp
	screen.scale = Vector2.ONE   # set by _fit_viewport(): the viewport is as large as the picture on the window
	world.add_child(screen)
	spotlight.size = Vector2(320, 240)
	spotlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	# the original's set location routine's mask on the world map: clear within the inner radius, black from 160 further out, 1.25 wider than tall
	# subtractive: the picture loses the ramp's level (0 inside the inner radius, 255 from 160 further out), as the original's gouraud ring does
	shader.code = "shader_type canvas_item;\nrender_mode blend_sub;\nuniform float inner = 32.0;\nvarying vec2 local;\nvoid vertex() {\n\tlocal = VERTEX;\n}\nvoid fragment() {\n\tvec2 p = local - vec2(160.0, 144.0);\n\tfloat t = length(vec2(p.x / 1.25, p.y));\n\tfloat g = clamp((t - inner) / 160.0, 0.0, 1.0);\n\tCOLOR = vec4(g, g, g, 1.0);\n}\n"
	var material := ShaderMaterial.new()
	material.shader = shader
	spotlight.material = material
	world.add_child(spotlight)
	world.add_child(panel_layer)
	world.add_child(hud)
	world.add_child(marker_layer)
	world.add_child(name_layer)
	leave_shade.size = Vector2(320, 240)
	leave_shade.color = Color(0, 0, 0, 0)
	leave_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world.add_child(leave_shade)
	_load_sprites()
	_enter(place)
	_set_location()
	get_viewport().size_changed.connect(refit)
	refit()

	ScreenFit.pass_mouse(self)
	ready_ok = true


func refit() -> void:
	ScreenFit.apply(world, size)
	_fit_viewport()


## The 3D picture is rendered at the window's own pixels: the height the picture takes on the window, at the 4:3 shape of the
## original viewport (so the framing is the same), and the picture is shown at 320 x 240 over it. Its edges are then the screen's
## pixels, not a stretched 320 x 240 render.
func _fit_viewport() -> void:
	if not is_instance_valid(get_window()):
		return
	var canvas := get_viewport().get_visible_rect().size
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return
	var per_unit := Vector2(get_window().size) / canvas
	var on_screen := Vector2(320.0, 240.0) * world.scale * per_unit
	var height := maxi(240, roundi(on_screen.y))
	var pixels := Vector2i(roundi(height * 4.0 / 3.0), height)
	if viewport.size != pixels:
		viewport.size = pixels
	screen.scale = Vector2(320.0 / pixels.x, 240.0 / pixels.y)


# ---- terrain ---------------------------------------------------------------------------------------------------------

func _build_terrain(folder: String) -> bool:
	if not FileAccess.file_exists(folder + "model.json"):
		return false
	var model = JSON.parse_string(FileAccess.get_file_as_string(folder + "model.json"))
	if typeof(model) != TYPE_DICTIONARY:
		return false
	var verts: Array = model["vertices"]
	var count := int(model["textures"])
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled;\nuniform sampler2D albedo : filter_nearest;\nvarying float depth;\n" \
			+ "void vertex() {\n\tdepth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;\n}\n" \
			+ "void fragment() {\n\tvec4 c = texture(albedo, UV);\n\tif (c.a < 0.5) { discard; }\n" \
			+ "\tfloat fog = depth <= 2000.0 ? 0.0 : min(1.0, 2400.0 * (depth - 2000.0) / (depth * 400.0));\n" \
			+ "\tALBEDO = c.rgb * COLOR.rgb * (1.0 - fog);\n}\n"
	var surfaces: Array = []
	for i in count:
		surfaces.append({"v": PackedVector3Array(), "uv": PackedVector2Array(), "c": PackedColorArray()})
	for face in model["faces"]:
		var s: Dictionary = surfaces[int(face["t"])]
		for k in 3:
			var p: Array = verts[int(face["v"][k])]
			s["v"].append(Vector3(p[0], -p[1], -p[2]))
			var uv: Array = face["uv"][k]
			s["uv"].append(Vector2((float(uv[0]) + 0.5) / 256.0, (float(uv[1]) + 0.5) / 256.0))
			var shade := clampf(float(face["s"][k]), 0.0, 1.0)
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
		material.shader = shader
		var image := Image.load_from_file(folder + "texture_%d.png" % i)
		if image != null:
			material.set_shader_parameter("albedo", ImageTexture.create_from_image(image))
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	terrain = instance
	return true


var terrain: MeshInstance3D


# ---- places ----------------------------------------------------------------------------------------------------------

func _pose_of(i: int) -> Array:
	var p: Dictionary = places[i]
	return [float(p["distance"]), float(p["pitch"]), float(p["heading"]), float(p["view_x"]), float(p["view_z"])]


func _apply_pose(p: Array) -> void:
	# the view orbit: the viewpoint is `distance` back from the target (x, 0, z), raised by the pitch, turned by the heading;
	# the game's y points down and z forward, so both points are mapped to y up, z toward the viewer
	var level: float = -p[0] * cos(p[1] * TURN)
	var rise: float = -p[0] * sin(p[1] * TURN)
	var eye := Vector3(p[3] + level * cos(p[2] * TURN), rise, p[4] + level * sin(p[2] * TURN))
	var target := Vector3(p[3], 0.0, p[4])
	var from_ := Vector3(eye.x, -eye.y, -eye.z)
	var to := Vector3(target.x, -target.y, -target.z)
	var up := Vector3.UP
	if abs((to - from_).normalized().dot(up)) > 0.999:
		up = Vector3.FORWARD
	camera.look_at_from_position(from_, to, up)


## the original's set location routine's part after the terrain: the spotlight (renderable on a plain place only), the marker of a marker place,
## and the track.
func _set_location() -> void:
	spot_on = place < MARKER_FROM
	spot_inner = SPOT_INNER
	slide = 0
	_add_sprite(panel_layer, "panel", NAME_ORIGIN)
	if place >= MARKER_FROM:
		_create_marker()
	music.emit(TRACK_AFTER_TOURNAMENT if GameState.test_flag(TOURNAMENT_FLAG) else TRACK)


func _enter(i: int) -> void:
	place = i
	pose = _pose_of(i)
	_apply_pose(pose)
	_clear_name()
	var plate := ColorRect.new()
	plate.position = NAME_PLATE.position
	plate.size = NAME_PLATE.size
	plate.color = NAME_PLATE_COLOUR
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_layer.add_child(plate)
	var bytes: Array = text.string_bytes(NAME_STRING + i)
	# a name is a global string: its flag command (the tournament's if) jumps inside the global text window
	text.layout(name_layer, bytes, NAME_ORIGIN, Vector2(8, 12), 0, sharp, true, {}, {"bank": _global_bank()})
	_clear_arrows()
	_build_arrows(i)


## The 64 KB window of the global strings (assets/screens/text_bank_global.bin), read once.
func _global_bank() -> PackedByteArray:
	if global_bank.is_empty():
		global_bank = FileAccess.get_file_as_bytes(GLOBAL_BANK)
	return global_bank


func _clear_name() -> void:
	for child in name_layer.get_children():
		name_layer.remove_child(child)
		child.queue_free()


## the original's start camera tween routine (the camera's distance, pitch, target and the wrapped heading move linearly over `steps` frames), and the
## state UpdateLocation sets for the move: the marker is saved where it is, the arrows and a marker of a plain place go, and the
## spotlight's slide is armed.
func _start_tween(i: int, steps: int) -> void:
	var previous := place
	from_pose = pose.duplicate()
	to_pose = _pose_of(i)
	var delta: float = fposmod(to_pose[2] - from_pose[2] + 2048.0, 4096.0) - 2048.0
	to_pose[2] = from_pose[2] + delta
	tween_steps = maxi(steps, 1)
	remaining = tween_steps
	place = i
	_clear_name()
	_clear_arrows()
	marker_progress = 0
	if i < MARKER_FROM:
		_remove_marker()
	elif not marker_entry.is_empty():
		marker_start = marker_entry["at"]
	slide = 0
	if i < MARKER_FROM and previous >= MARKER_FROM:
		spot_inner = SPOT_SLIDE_IN
		spot_on = true
		slide = 0x60
	elif i >= MARKER_FROM and previous < MARKER_FROM:
		slide = 0x40


## the original's update location transition routine: one frame of the move. The spotlight's inner radius slides, the marker moves on its cosine,
## the camera tweens. The last frame lands the camera, the spotlight and the marker and rebuilds the arrows and the name.
func _transition() -> void:
	if (slide & 0x40) != 0:
		if (slide & 0x20) == 0:
			spot_inner += SPOT_SLIDE_STEP
		else:
			spot_inner = maxi(spot_inner - SPOT_SLIDE_STEP, SPOT_INNER)
	if not marker_entry.is_empty() and marker_progress < MARKER_SPAN:
		marker_progress += MARKER_SPAN / tween_steps
		var target := _marker_target(place)
		marker_entry["at"] = _cosine(marker_start, target, marker_progress)
		_show_frame(marker_entry)
	remaining -= 1
	var t := 1.0 - float(remaining) / float(tween_steps)
	pose = []
	for k in 5:
		pose.append(lerpf(from_pose[k], to_pose[k], t))
	_apply_pose(pose)
	if remaining == 0:
		_finish_move()


func _finish_move() -> void:
	if (slide & 0x20) != 0:
		spot_inner = SPOT_INNER
	slide = 0
	_enter(place)
	if place >= MARKER_FROM:
		if marker_entry.is_empty():
			_create_marker()
		else:
			marker_entry["at"] = _marker_target(place)
			_show_frame(marker_entry)


## The marker's place on the map: the place's marker (f12, f14).
func _marker_target(i: int) -> Vector2:
	var p: Dictionary = places[i]
	return Vector2(int(p["marker_x"]), int(p["marker_y"]))


## the cosine position interpolation: the point moves between the start and the target about their midpoint by cos(progress),
## with the 4096 = 1.0 fixed point; progress 0 is the start, 2048 the target.
static func _cosine(start: Vector2, target: Vector2, progress: int) -> Vector2:
	var scale := int(round(4096.0 * cos(float(progress) * TURN)))
	var sx := int(start.x)
	var sy := int(start.y)
	var mx := (sx + int(target.x)) >> 1
	var my := (sy + int(target.y)) >> 1
	return Vector2(mx + (sx - mx) * scale / 4096, my + (sy - my) * scale / 4096)


func _create_marker() -> void:
	_remove_marker()
	marker_entry = _add_sprite(marker_layer, "marker", _marker_target(place))


func _remove_marker() -> void:
	if marker_entry.is_empty():
		return
	animated.erase(marker_entry)
	(marker_entry["node"] as Node).queue_free()
	marker_entry = {}


## The departure: the camera backs off (distance -= 2) while the fade to black runs (its level falls by the step each tick), then the map
## ends on the frame after the fade.
func _depart() -> void:
	if leave_level <= 0:
		if not ended:
			ended = true
			finished.emit(place)
		return
	pose[0] -= DEPART_STEP
	_apply_pose(pose)
	leave_level = maxi(leave_level - FADE_STEP * FADE_TICK, 0)
	leave_shade.color = Color(0, 0, 0, 1.0 - float(leave_level) / 255.0)


## the original's update location routine's departure start: the fade goes, the arrows and the marker are released, the track fades.
func _begin_leave() -> void:
	departing = true
	leave_level = 255
	_clear_arrows()
	_remove_marker()
	music_fade.emit(4)


func _gui_input(event: InputEvent) -> void:
	if not ready_ok or not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var exit := _exit_at(event.position)
	if exit >= 0:
		click_exit = exit
	else:
		click_confirm = true


## The index of the visible exit whose arrow (about 24 pixels, centred on its point) lies under a point, or -1.
func _exit_at(at: Vector2) -> int:
	var local: Vector2 = (at - world.position) / world.scale
	var exits: Array = places[place]["exits"]
	for i in exits.size():
		var exit: Dictionary = exits[i]
		if not _exit_shown(exit):
			continue
		if Rect2(int(exit["x"]) - 12, int(exit["y"]) - 12, 24, 24).has_point(local):
			return i
	return -1


func _exit_shown(exit: Dictionary) -> bool:
	var flag := int(exit["flag"])
	return int(exit["destination"]) != 16 and (flag == 0 or GameState.test_flag(flag))


## the original's pick exit routine's confirm: a place with no gate, or whose first exit's story flag is set, takes the confirm.
func _confirm_open(p: Dictionary) -> bool:
	if int(p["confirm_gate"]) == 0:
		return true
	return GameState.test_flag(int(p["exits"][0]["flag"]))


func _physics_process(_delta: float) -> void:
	if not ready_ok:
		return
	_animate()
	spotlight.visible = spot_on
	(spotlight.material as ShaderMaterial).set_shader_parameter("inner", float(spot_inner))
	# the clicks are taken every frame; one that comes while a move runs is dropped
	var clicked := click_confirm
	var clicked_exit := click_exit
	click_confirm = false
	click_exit = -1
	if departing:
		_depart()
		return
	if remaining > 0:
		_transition()
		return
	var p: Dictionary = places[place]
	var mask := 0
	mask |= MASK_UP if _held([KEY_W, KEY_UP]) else 0
	mask |= MASK_RIGHT if _held([KEY_D, KEY_RIGHT]) else 0
	mask |= MASK_DOWN if _held([KEY_S, KEY_DOWN]) else 0
	mask |= MASK_LEFT if _held([KEY_A, KEY_LEFT]) else 0
	# the original's pick exit routine: a marker place with the tournament complete turns Cancel into a move to place 0
	if place >= MARKER_FROM and GameState.test_flag(TOURNAMENT_FLAG) and _pressed("cancel", CANCEL_KEYS):
		sound.emit(SE_CONFIRM)
		_start_tween(0, GO_STEPS)
		return
	var confirm := _pressed("confirm", [KEY_E, KEY_SPACE, KEY_F])
	confirm = confirm or clicked
	if confirm and _confirm_open(p):
		# a place with a destination of its own (the Metropolis's Card Shop) moves there, any other leaves the map
		var destination := int(p["confirm_destination"])
		sound.emit(SE_CONFIRM)
		if destination != 0:
			_start_tween(destination, GO_STEPS)
		else:
			_begin_leave()
		return
	if clicked_exit >= 0:
		var picked: Dictionary = p["exits"][clicked_exit]
		sound.emit(SE_MOVE)
		_start_tween(int(picked["destination"]), int(picked["steps"]))
		return
	for exit in p["exits"]:
		if int(exit["destination"]) == 16:
			continue
		var flag := int(exit["flag"])
		if flag != 0 and not GameState.test_flag(flag):
			continue
		if (mask & int(exit["mask"])) != 0:
			sound.emit(SE_MOVE)
			_start_tween(int(exit["destination"]), int(exit["steps"]))
			return


func _held(keys: Array) -> bool:
	for k in keys:
		if Input.is_key_pressed(k):
			return true
	return false


func _pressed(name: String, keys: Array) -> bool:
	var now := _held(keys)
	var was: bool = held.get(name, false)
	held[name] = now
	return now and not was


# ---- the sprites: name panel, marker, exit arrows ------------------------------------------------------------------------

func _load_sprites() -> void:
	var path := DIR + "sprites/index.json"
	if not FileAccess.file_exists(path):
		return
	var index = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(index) != TYPE_DICTIONARY:
		return
	for sprite_name in index:
		var frames: Array = []
		for entry in index[sprite_name]:
			var image := Image.load_from_file(DIR + "sprites/" + str(entry["file"]))
			if image != null:
				frames.append({"texture": ImageTexture.create_from_image(image), "duration": int(entry["duration"]),
						"x": int(entry["x"]), "y": int(entry["y"])})
		sprite_frames[sprite_name] = frames


## The exit arrows are the only sprites the move takes away.
func _clear_arrows() -> void:
	for entry in animated.duplicate():
		if (entry["node"] as Node).get_parent() == hud:
			animated.erase(entry)
	for child in hud.get_children():
		hud.remove_child(child)
		child.queue_free()


func _add_sprite(layer: Node2D, sprite_name: String, at: Vector2) -> Dictionary:
	var frames: Array = sprite_frames.get(sprite_name, [])
	if frames.is_empty():
		return {}
	var node := Sprite2D.new()
	node.centered = false
	node.material = sharp
	layer.add_child(node)
	var entry := {"node": node, "frames": frames, "index": 0, "wait": int(frames[0]["duration"]), "at": at}
	_show_frame(entry)
	animated.append(entry)
	return entry


func _show_frame(entry: Dictionary) -> void:
	var frame: Dictionary = entry["frames"][entry["index"]]
	var node: Sprite2D = entry["node"]
	node.texture = frame["texture"]
	node.position = entry["at"] + Vector2(frame["x"], frame["y"])


func _build_arrows(i: int) -> void:
	var p: Dictionary = places[i]
	for exit in p["exits"]:
		if int(exit["destination"]) == 16:
			continue
		var flag := int(exit["flag"])
		if flag != 0 and not GameState.test_flag(flag):
			continue
		_add_sprite(hud, "arrow%d" % int(exit["variant"]), Vector2(int(exit["x"]), int(exit["y"])))


func _animate() -> void:
	for entry in animated:
		var frames: Array = entry["frames"]
		if frames.size() < 2:
			continue
		entry["wait"] -= 1
		if entry["wait"] <= 0:
			entry["index"] = (int(entry["index"]) + 1) % frames.size()
			entry["wait"] = maxi(int(frames[entry["index"]]["duration"]), 1)
			_show_frame(entry)
