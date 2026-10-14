extends "res://scripts/duel/effects/effect_program.gd"
## Effect 22: the ritual apply (the summon of a ritual monster). The tributes fly to a point in front of the portal, shrink and vanish
## as they reach it (the flight and the hold). A flash bursts from the portal, with rays, a ring and a flame pair at its sides that
## settle and then turn into a column of lines and sparkles around the portal, while a fan of gradient quads turns and the board dims
## and returns. Each ritual has its own colours, spread and widths (the configuration), chosen by the card's id (the request's phase).
## The impact flag is raised when the column has finished its hold, before the monster is shown.
##
## The request's phase is the ritual card's id. The ids of the 24 configurations are the overlay's table (RITUAL_INDEX); any other id
## takes the banner path. The tributes are the request's `tributes` (the monsters the ritual spent); the card-object channel moves them.
## The overlay's per-object rotation (the field_20 bytes) and size (field_44) are the channel's spin and size.

const PORTAL_PAIR := 17          # pairs[17]: the portal's page
const FLAME_PAIR := 4            # pairs[4]: the flame's frames
const FAN_PAIR := 15             # pairs[15]: the fan's gradient page (as effect 17's)
const PORTAL_UV := [Vector2i(96, 64), Vector2i(159, 64), Vector2i(96, 127), Vector2i(159, 127)]
const FAN_UV := [Vector2i(96, 0), Vector2i(159, 0), Vector2i(96, 63), Vector2i(159, 63)]
const PORTAL_AT := Vector3i(0, -96, 0)
const LINE_COUNT := 64
const PARTICLE_COUNT := 64
const RING_COUNT := 32
const NEUTRAL := 128
## The overlay's ritual card id to its configuration index (the switch in the apply's first call).
const RITUAL_INDEX := {670: 0, 671: 1, 673: 2, 674: 3, 675: 4, 676: 5, 677: 6, 678: 7, 679: 8, 680: 9, 691: 10, 692: 11, 693: 12,
	694: 13, 695: 14, 696: 15, 697: 16, 698: 17, 699: 18, 700: 19, 721: 20, 665: 21, 666: 22, 667: 23}

var config: Dictionary = {}
var tributes: Array = []         # the card records the ritual spends (the overlay's CARD(i), at most three in the disc's ritual)
var card_velocities: Array = []
var card_rotations: Array = []
var card_states := PackedInt32Array()
var positions: Array = []        # two Vector3i: the portal's flame points
var rings: Array = []            # two rings of four points
var points: Array = []           # 32 flash points
var rotations: Array = []        # 32 turns (Vector3i)
var particles: Array = []        # 64 points
var particle_velocities: Array = []
var particle_colours: Array = []
var line_inner: Array = []
var line_outer: Array = []
var line_velocities: Array = []
var portal := PackedInt32Array([0, 0, 0])
var flame := PackedInt32Array([0, 0, 0])
var flash := PackedInt32Array([0, 0, 0])
var particle_colour := PackedInt32Array([0, 0, 0])
var fan := PackedInt32Array([0, 0, 0])
var texture_frames := PackedInt32Array([0, 0])
var ring_scale := 4096
var brightness := NEUTRAL
var stage := 0
var frame := 0
var hold := 0
var active_cards := 0
var active_particles := 0
var fan_speed := 8
var card_count := 0
var revealed := false           # the tributes are shown again (the flight's start)


func _init() -> void:
	geometry = Vector2i(160, 108)
	world = field_view()


## The duel's field view as the apply's geometry sees it (the view matrix the game holds while the field is shown, read from the
## reference's geometry trace of the apply: the rotation about x and the view offset of 602 in depth). The portal's points are then
## 397 deep at the tributes' z of -95 (the portal at -190), which places its quads and flames where the reference draws them.
static func field_view() -> Gte.Mat:
	var view := Gte.Mat.new()
	view.m = PackedInt32Array([4125, 0, 0, 0, 3779, -1585, 0, 1573, 3805])
	view.t = PackedInt32Array([0, -4, 602])
	return view


func dispatch(phase: int) -> void:
	# a ritual card that is not one of the 24 configurations takes the banner (the overlay's default case)
	if phase >= 0 and not RITUAL_INDEX.has(phase):
		_banner = 1
		return
	super.dispatch(phase)


func _start(phase: int) -> void:
	config = Data.configs()["effect_22"][RITUAL_INDEX[phase]]
	var board = extra.get("objects", null)
	tributes = extra.get("tributes", []) if board != null else []
	if tributes.is_empty() and board != null:
		tributes = board.rows(int(extra.get("side", 0)), "monsters").slice(0, 3)
	card_count = tributes.size()
	card_velocities = []
	card_rotations = []
	card_states = PackedInt32Array()
	for i in card_count:
		var at: Vector3i = board.position(tributes[i])
		var spin: Vector3i = board.spin(tributes[i])
		card_velocities.append(Vector3i(-at.x / 32, (-96 - at.y) / 32, -at.z / 32))
		card_rotations.append(Vector3i(2, -spin.y / 32, -spin.z / 32))
		card_states.append(0)
	var z := 190
	if card_count > 0:
		var first: Vector3i = board.position(tributes[0])
		z = 190 if first.z >= 0 else -190
	positions = [Vector3i(70, -48, z), Vector3i(-70, -48, z)]
	texture_frames = PackedInt32Array([rng.randi_range(0, 3), rng.randi_range(0, 3)])
	rings = [ellipse(24, 28, 4), ellipse(30, 34, 4)]
	points = random_planar(int(config["spread"]), int(config["spread"]), RING_COUNT)
	rotations = []
	for i in RING_COUNT:
		rotations.append(Vector3i(rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095)))
	particles = random_scatter(392, 392, 392, RING_COUNT)
	while particles.size() < PARTICLE_COUNT:
		particles.append(Vector3i.ZERO)
	particle_velocities = []
	particle_colours = []
	line_inner = []
	line_outer = []
	line_velocities = []
	var c: Array = config["color"]
	for i in PARTICLE_COUNT:
		var p: Vector3i = particles[i]
		particle_velocities.append(Vector3i(-p.x / 8, -p.y / 8, -p.z / 8))
		particle_colours.append(PackedInt32Array([int(c[0]), int(c[1]), int(c[2])]))
		var j := rng.randi_range(0, 32767) - rng.randi_range(0, 32767)
		var k := rng.randi_range(0, 32767) - rng.randi_range(0, 32767)
		var l := rng.randi_range(0, 32767) - rng.randi_range(0, 32767)
		var inner := Vector3i(j % 4096 * 328 / 4096, k % 4096 * 328 / 4096, l % 4096 * 328 / 4096)
		var outer := Vector3i(j % 4096 * 392 / 4096, k % 4096 * 392 / 4096, l % 4096 * 392 / 4096)
		line_inner.append(inner)
		line_outer.append(outer)
		line_velocities.append(Vector3i(-outer.x / 8, -outer.y / 8, -outer.z / 8))
	ring_scale = 4096
	brightness = NEUTRAL
	active_cards = 1
	stage = 0
	frame = 0
	hold = 0
	revealed = false
	active_particles = 0
	fan_speed = 8
	portal = PackedInt32Array([1, 1, 1])
	flame = PackedInt32Array([1, 1, 1])
	flash = PackedInt32Array([int(c[0]), int(c[1]), int(c[2])])
	particle_colour = PackedInt32Array([int(c[0]), int(c[1]), int(c[2])])
	var f: Array = config["fan_color"]
	fan = PackedInt32Array([int(f[0]) / 8, int(f[1]) / 8, int(f[2]) / 8])


func _update() -> void:
	var board = extra.get("objects", null)
	if stage == 0:
		brightness = maxi(brightness - 4, 0)
	elif stage == 4:
		if brightness < 126:
			brightness += 2
		else:
			brightness = NEUTRAL
			stage = 5
	if board != null:
		board.set_tint(Vector3i(brightness, brightness, brightness))
	gte.push()
	var saved := Gte.Mat.new()
	var scale := Data.start_vector(22)
	var none := Vector3i.ZERO
	gte.pose(world, saved, none, none, scale, 2)
	# the portal's two quads, then the flames beside them once the portal is neutral
	if is_lit(portal):
		for i in 2:
			var quad := rect(24, 24)
			var verts := shifted(quad, positions[i])
			ft4(verts, PORTAL_PAIR, PORTAL_UV, colour_of(portal), 1, 0 if _neutral(portal) else 1)
		if stage < 4:
			fade_up(portal, Vector3i(NEUTRAL, NEUTRAL, NEUTRAL), 4)
		else:
			fade_down(portal, 8)
	if _neutral(portal) and is_lit(flame):
		for i in 2:
			var tf: int = texture_frames[i]
			var uv := [Vector2i(128 + tf * 32, 64), Vector2i(159 + tf * 32, 64), Vector2i(128 + tf * 32, 127), Vector2i(159 + tf * 32, 127)]
			var verts := shifted(rect(24, 36), positions[i])
			for j in verts.size():
				verts[j] = verts[j] + Vector3i(0, -48, 0)
			ft4(verts, FLAME_PAIR, uv, colour_of(flame), 1, 1)
			if stage >= 2:
				texture_frames[i] = (texture_frames[i] + 1) % 4
			elif frame % 3 == 0:
				texture_frames[i] = (texture_frames[i] + 1) % 4
		if stage < 4:
			fade_up(flame, Vector3i(NEUTRAL, NEUTRAL, NEUTRAL), 4)
		else:
			fade_down(flame, 8)
	# the tributes: drawn toward the portal's point; each is shrunk out at the point, then the last one hides them all
	if _neutral(flame) and stage == 0:
		if not revealed:
			# the tributes come back into the picture as their flight starts (they were taken off it with the window)
			revealed = true
			for record in tributes:
				board.set_shown(record, true)
		var i := 0
		while i < active_cards:
			var record: int = tributes[i]
			var at: Vector3i = board.position(record)
			if at.y <= -96:
				if card_states[i] == 0:
					board.move(record, Vector3i(0, -96, 0))
					card_states[i] = 1
					active_cards = mini(active_cards + 1, card_count)
			else:
				board.move(record, at + card_velocities[i])
				var spin: Vector3i = board.spin(record)
				var step: Vector3i = card_rotations[i]
				board.turn(record, Vector3i(posmod(spin.x + step.x, 256), posmod(spin.y + step.y, 256), posmod(spin.z + step.z, 256)))
			i += 1
		if card_count > 0 and card_states[card_count - 1] == 1:
			for n in card_count:
				board.set_size(tributes[n], Vector2i.ZERO)
				board.set_shown(tributes[n], false)
			stage = 1
	# the flash: the rays, the ring, the glow sprite; from stage 1 it runs at stage 2
	if (stage == 1 or stage == 2) and is_lit(flash):
		if stage == 1:
			stage = 2
		gte.pose(world, saved, PORTAL_AT, none, scale, 1)
		ray_triangles(colour_of(flash), int(config["point_size"]), points, 1)
		contour(colour_of(flash), rings[0], rings[1], 1, 1)
		gte.scaled_saved(saved, Vector3i(ring_scale, ring_scale, 4096))
		layered_sprite(colour_of(flash), 12, 1, none)
		screen_flash(flash, 8)
		if ring_scale < 28672:
			ring_scale += 4096
	# the column: the glow, the rotating rings of lines and the particles' lines, once the flash has its colour
	if (stage == 2 or stage == 3) and is_lit(particle_colour):
		var lit_col := Vector3i(255, 255, 255) if frame % 2 == 0 else colour_of(particle_colour)
		var pose_at := PORTAL_AT
		for i in RING_COUNT:
			gte.pose(world, saved, pose_at, rotations[i], scale, 0)
			gradient_quads(lit_col, config["inner_widths"], int(config["inner_height"]), 1)
			rotations[i] = rotations[i] + Vector3i(16, 16, 16)
		gte.pose(world, saved, pose_at, Vector3i(0, 0, -(frame * 12) % 4096), scale, 1)
		layered_sprite(lit_col, 32, 64, none)
		gte.pose(world, saved, pose_at, none, scale, 2)
		for i in active_particles:
			var a := gte.rot_trans_pers(line_inner[i])
			var b := gte.rot_trans_pers(line_outer[i])
			if b.z >= 0 and b.w != 0:
				canvas.add_line(Vector2(a.x, a.y), Vector2(b.x, b.y), colour_of(particle_colour), Vector3i.ZERO, b.z >> 2, -1)
			if absi(line_inner[i].x) > 64 or absi(line_inner[i].y) > 64 or absi(line_inner[i].z) > 64:
				line_inner[i] = line_inner[i] + line_velocities[i]
				line_outer[i] = line_outer[i] + line_velocities[i]
			else:
				var j := rng.randi_range(0, 32767) - rng.randi_range(0, 32767)
				var k := rng.randi_range(0, 32767) - rng.randi_range(0, 32767)
				var l := rng.randi_range(0, 32767) - rng.randi_range(0, 32767)
				var inner := Vector3i(j % 4096 * 328 / 4096, k % 4096 * 328 / 4096, l % 4096 * 328 / 4096)
				var outer := Vector3i(j % 4096 * 392 / 4096, k % 4096 * 392 / 4096, l % 4096 * 392 / 4096)
				line_inner[i] = inner
				line_outer[i] = outer
				line_velocities[i] = Vector3i(-outer.x / 8, -outer.y / 8, -outer.z / 8)
		if frame % 2 == 0:
			active_particles = mini(active_particles + 1, LINE_COUNT)
		if active_particles == LINE_COUNT:
			hold += 1
		if hold > int(config["duration"]):
			stage = 3
	# the particles: a sparkle and a sprite each, moving on their velocities until they fade (stages 2 and 3)
	if stage == 2 or stage == 3:
		for i in active_particles:
			if not is_lit(particle_colours[i]):
				continue
			var lit := colour_of(particle_colours[i])
			var p: Vector3i = particles[i]
			if i % 4 == 0:
				layered_sprite(lit, 4, 32, p)
			sparkle(lit, shifted(square(4), p), 32)
			if absi(p.x) > 32 or absi(p.y) > 32 or absi(p.z) > 32:
				particles[i] = p + particle_velocities[i]
			else:
				fade_down(particle_colours[i], 31)
				if is_black(particle_colours[i]):
					var r := rng.randi_range(0, 32767) - rng.randi_range(0, 32767)
					var s := rng.randi_range(0, 32767) - rng.randi_range(0, 32767)
					var t := rng.randi_range(0, 32767) - rng.randi_range(0, 32767)
					particles[i] = Vector3i((r % 4096) * 392 / 4096, (s % 4096) * 392 / 4096, (t % 4096) * 392 / 4096)
					var q: Vector3i = particles[i]
					particle_velocities[i] = Vector3i(-q.x / 8, -q.y / 8, -q.z / 8)
					var c: Array = config["color"]
					particle_colours[i] = PackedInt32Array([int(c[0]), int(c[1]), int(c[2])])
	# the fan of gradient quads turning about the portal (stages 2 and 3)
	if (stage == 2 or stage == 3) and is_lit(fan):
		var quad := [Vector3i(-196, -196, 0), Vector3i(-196, 0, 0), Vector3i(0, -196, 0), Vector3i(0, 0, 0)]
		for i in 3:
			var s := 4096 - 1280 * i
			var c := Vector3i(fan[0] / (i + 1), fan[1] / (i + 1), fan[2] / (i + 1))
			var rgb4 := [c, c, c, Vector3i.ZERO]
			for j in 4:
				for k in 3:
					var turn := Vector3i(0, 0, -(frame * ((i * 2 + 1) * fan_speed) + k * 32 + j * 1024) % 4096)
					gte.pose(world, saved, PORTAL_AT, turn, Vector3i(s, s, 0), 0)
					gt4(quad, FAN_PAIR, FAN_UV, rgb4, 1, 1)
		var f: Array = config["fan_color"]
		fan = _fade_toward(fan, Vector3i(int(f[0]), int(f[1]), int(f[2])), 2)
		fan_speed = mini(fan_speed + 1, 24)
	# the stage 3 flash: the screen goes to white, and the particles are re-spawned as the release
	if stage == 3:
		full_screen(flash)
		if fade_up(flash, Vector3i(192, 192, 192), 4):
			stage = 4
			flash = PackedInt32Array([255, 255, 255])
			var c: Array = config["color"]
			particle_colour = PackedInt32Array([int(c[0]), int(c[1]), int(c[2])])
			particles = []
			particle_velocities = []
			for i in PARTICLE_COUNT:
				particles.append(Vector3i.ZERO)
				particle_velocities.append(random_vector(4))
	# stage 4 onward: the release (the impact the summon waits for), the rings grow and the screen flash fades
	if stage >= 4:
		impact = true
		screen_flash(flash, 4)
		gte.pose(world, saved, PORTAL_AT, none, scale, 0)
		for i in PARTICLE_COUNT:
			sparkle(colour_of(particle_colour), shifted(square(4), particles[i]), 8)
			particles[i] = particles[i] + particle_velocities[i]
		layered_sprite(colour_of(particle_colour), 128, 1, none)
		for i in RING_COUNT:
			gte.pose(world, saved, PORTAL_AT, rotations[i], scale, 0)
			gradient_quads(colour_of(particle_colour), config["outer_widths"], int(config["outer_height"]), 1)
		fade_down(particle_colour, 4)
	frame += 1
	gte.pop()
	if is_black(flash) and stage == 5:
		done = true


## A stage-3 full-screen quad at the flash's colour (no fade: the overlay's screen rectangle).
func full_screen(c: PackedInt32Array) -> void:
	canvas.add_poly([Vector2(0, 0), Vector2(SCREEN_W, 0), Vector2(0, SCREEN_H), Vector2(SCREEN_W, SCREEN_H)],
		[colour_of(c)], [], -1, flags, 1)


## Four points of an ellipse at count evenly spaced angles, half a step past the axes (the overlay's ring helper: the width and
## height are scaled by the sine of an eighth turn, times two).
static func ellipse(width: int, height: int, count: int) -> Array:
	var w := width * (Gte.rsin(512) * 2) / 4096
	var h := height * (Gte.rsin(512) * 2) / 4096
	var out: Array = []
	for i in count:
		var angle := (4096 / count) * i + (4096 / count) / 2
		out.append(Vector3i(w * Gte.rcos(angle) / 4096, h * Gte.rsin(angle) / 4096, 0))
	return out


func _neutral(c: PackedInt32Array) -> bool:
	return c[0] == NEUTRAL and c[1] == NEUTRAL and c[2] == NEUTRAL


func _fade_toward(c: PackedInt32Array, target: Vector3i, step: int) -> PackedInt32Array:
	var goal := [target.x, target.y, target.z]
	var out := PackedInt32Array([c[0], c[1], c[2]])
	for i in 3:
		out[i] = out[i] + step if out[i] < goal[i] + 1 - step else goal[i]
	return out
