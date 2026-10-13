extends "res://scripts/duel/effects/effect_program.gd"
## Effect 17: board destruction (Dark Hole). The board's cards are drawn in toward a centre, one at a time: each card's object
## shrinks and spins as it travels, and once it has gone (sixteen frames) it is hidden and a burst of rays leaves from its own
## particles. Meanwhile the board's tint dims to black and comes back (the board tint channel), a gradient of three fanned quads
## turns about the centre, a ring of sparkles drifts outward, and (mode 1) bolts run down to the ground from the centre.
##
## The configuration is the variant (0 or 1). Mode 0 collects every card on the board and centres on (0, -height, 0); mode 1 collects
## the monsters and centres on the request's offset less the height. Scene space (the overlay sets the geometry offset for 17). The
## cards are moved and hidden through the card-object channel (extra.objects), and the board tint through its tint setter.
## Variants past the two configurations take the banner path.

const BURST_PAIR := 15              # pairs[15]: the burst's gradient page
const BURST_UV := [Vector2i(96, 0), Vector2i(159, 0), Vector2i(96, 63), Vector2i(159, 63)]
const PARTICLE_COUNT := 64
const PATH_COUNT := 48
const MAX_CARDS := 20
const NEUTRAL := 128

var config: Dictionary = {}
var mode := 0
var centre := Vector3i.ZERO
var cards: Array = []             # the card records, in the order the collector gives them
var card_velocities: Array = []
var card_rotations: Array = []
var card_particles: Array = []    # per card: 16 points the card's burst rays leave from
var card_states := PackedInt32Array()
var card_ages := PackedInt32Array()
var particles: Array = []
var particle_velocities: Array = []
var particle_colours: Array = []  # PackedInt32Array(3) each
var paths: Array = []
var endpoints: Array = []         # each: [Vector3i] (the bolt's endpoint, as the bolt helper stores it)
var angles := PackedInt32Array()
var path_states := PackedInt32Array()
var path_ages := PackedInt32Array()
var path_colours: Array = []
var colour := PackedInt32Array([0, 0, 0])
var burst := PackedInt32Array([0, 0, 0])
var brightness := NEUTRAL
var stage := 0
var tick := 0
var completed := 0
var active_cards := 0
var active_particles := 0
var active_paths := 0


func _init() -> void:
	variant_count = 2
	geometry = Vector2i(160, 108)


func _start(phase: int) -> void:
	config = Data.configs()["effect_17"][phase]
	mode = int(config["mode"])
	var board = extra.get("objects", null)
	cards = board.field_cards(mode != 0) if board != null else []
	var height := int(config["height"])
	centre = Vector3i(0, -height, 0) if mode == 0 else Vector3i(offset.x, offset.y - height, offset.z)
	card_velocities = []
	card_rotations = []
	card_particles = []
	card_states = PackedInt32Array()
	card_ages = PackedInt32Array()
	for i in cards.size():
		var at: Vector3i = board.position(cards[i])
		var v := Vector3i((centre.x - at.x) / 16, (centre.y - at.y) / 16, (centre.z - at.z) / 16)
		card_velocities.append(v)
		card_rotations.append(Vector3i(
			(_angle(v.z, v.y) % 256) / 16, (_angle(v.x, v.z) % 256) / 16, (_angle(v.y, v.x) % 256) / 16))
		card_particles.append(random_scatter(128, 128, 128, 16))
		card_states.append(0)
		card_ages.append(0)
	var radius := int(config["radius"])
	particles = random_scatter(radius * 2, radius * 2, radius * 2, PARTICLE_COUNT)
	particle_velocities = []
	particle_colours = []
	for p in particles:
		particle_velocities.append(Vector3i(-p.x / 32, -p.y / 32, -p.z / 32))
		particle_colours.append(_scaled_colour(config["color"], 8))
	paths = []
	endpoints = []
	path_colours = []
	path_states = PackedInt32Array()
	path_ages = PackedInt32Array()
	angles = PackedInt32Array()
	for i in PATH_COUNT:
		paths.append(bolt_path(24, 8, height, 8))
		path_colours.append(_colour_of_config("burst_color"))
		endpoints.append([Vector3i.ZERO])
		path_ages.append(0)
		path_states.append(0)
		angles.append(rng.randi_range(0, 511))
	tick = 0
	colour = _scaled_colour(config["color"], 8)
	burst = PackedInt32Array([0, 0, 0])
	completed = 0
	stage = 0
	brightness = NEUTRAL
	active_cards = 0
	active_particles = 0
	active_paths = 0


func _update() -> void:
	var board = extra.get("objects", null)
	if stage < 2:
		brightness = maxi(brightness - 8, 0)
	elif brightness < 120:
		brightness += 8
	else:
		brightness = NEUTRAL
		stage = 3
	if board != null:
		board.set_tint(Vector3i(brightness, brightness, brightness))
	gte.push()
	var saved := Gte.Mat.new()
	var rot := Vector3i(0, 0, (int(config["spin"]) * tick) % 4096)
	var scale := Data.start_vector(17)
	gte.pose(world, saved, centre, rot, scale, 0)
	# the sparkles that drift out from the centre (the particles run while their card is still in)
	for i in active_particles:
		if not is_lit(particle_colours[i]):
			continue
		var lit := colour_of(particle_colours[i])
		var p: Vector3i = particles[i]
		if i % 4 == 0:
			layered_sprite(lit, 8, 1, p)
		sparkle(lit, shifted(square(4), p), 1)
		if absi(p.x) > 32 or absi(p.y) > 32 or absi(p.z) > 32:
			particles[i] = p + particle_velocities[i]
			fade_up(particle_colours[i], Vector3i(int(config["color"][0]), int(config["color"][1]), int(config["color"][2])), 31)
		else:
			fade_down(particle_colours[i], 31)
			if is_black(particle_colours[i]) and _last_state() == 0:
				var r := int(config["radius"])
				particles[i] = Vector3i(
					r * (2 * (rng.randi_range(0, 32767) - rng.randi_range(0, 32767)) % 4096) / 4096,
					r * (2 * (rng.randi_range(0, 32767) - rng.randi_range(0, 32767)) % 4096) / 4096,
					r * (2 * (rng.randi_range(0, 32767) - rng.randi_range(0, 32767)) % 4096) / 4096)
				var q: Vector3i = particles[i]
				particle_velocities[i] = Vector3i(-q.x / 32, -q.y / 32, -q.z / 32)
				particle_colours[i] = _scaled_colour(config["color"], 8)
	# the gradient: three fanned quads at shrinking scales, each made of four turned quads
	if is_lit(colour):
		var r := int(config["radius"])
		var quad := [Vector3i(-r, -r, 0), Vector3i(-r, 0, 0), Vector3i(0, -r, 0), Vector3i(0, 0, 0)]
		var fan := int(config["fan_spin"])
		for j in 3:
			var s := 4096 - j * 1280
			var c := Vector3i(int(config["color"][0]) / (j + 1), int(config["color"][1]) / (j + 1), int(config["color"][2]) / (j + 1))
			var rgb4 := [c, c, c, Vector3i.ZERO]
			for i in 4:
				for k in 3:
					var turn := Vector3i(0, 0, -(tick * ((j * 2 + 1) * fan) + k * 32 + i * 1024) % 4096)
					gte.pose(world, saved, centre, turn, Vector3i(s, s, 0), 0)
					gt4(quad, BURST_PAIR, BURST_UV, rgb4, 1, 1)
			if stage < 2:
				stage = 1 if fade_up(colour, Vector3i(int(config["color"][0]), int(config["color"][1]), int(config["color"][0])), 2) else 0
			else:
				fade_down(colour, 1)
	if card_states.size() > 0 and stage < 2 and not cards.is_empty():
		active_particles = mini(active_particles + 1, PARTICLE_COUNT)
	# the cards are drawn in toward the centre from the stage on; each is hidden when its travel is done
	if stage != 0 and tick > 60:
		if cards.is_empty() and stage == 1:
			stage = 2
		for i in active_cards:
			if card_states[i] == 0:
				var record: int = cards[i]
				board.move(record, board.position(record) + card_velocities[i])
				board.set_size(record, board.size(record) - Vector2i(256, 256))
				var spin: Vector3i = board.spin(record)
				var step: Vector3i = card_rotations[i]
				board.turn(record, Vector3i(posmod(spin.x + step.x, 256), posmod(spin.y + step.y, 256), posmod(spin.z + step.z, 256)))
				card_ages[i] += 1
				if card_ages[i] > 16:
					card_states[i] = 1
			if card_states[i] == 1:
				completed += 1
				board.set_shown(cards[i], false)
				card_states[i] = 2
				burst = _colour_of_config("burst_color")
		if tick & 7 == 0:
			active_cards = mini(active_cards + 1, cards.size())
	# the burst of rays from the completed card's points, and the centre's flash
	gte.pose(world, saved, centre, Vector3i.ZERO, Vector3i(4096, 4096, 4096), 0)
	if is_lit(burst):
		layered_sprite(colour_of(burst), 32, 1, Vector3i.ZERO)
		var half := Vector3i(burst[0] >> 1, burst[1] >> 1, burst[2] >> 1)
		ray_triangles(half, 3, card_particles[completed - 1], 36)
		fade_down(burst, 15)
		if _last_state() >= 2 and is_black(burst):
			stage = 2
	# mode 1: the bolts from the centre to the ground (the bolt lines, as program 13's)
	if mode != 0 and not cards.is_empty():
		for i in active_paths:
			var turn := Vector3i(0, angles[i], 0)
			gte.pose(world, saved, offset, turn, Vector3i(4096, 4096, 4096), 2)
			if not is_lit(path_colours[i]):
				continue
			if path_states[i] != 2:
				path_states[i] = bolt_lines(colour_of(path_colours[i]), path_ages[i], paths[i], 16, 1, endpoints[i], 1)
			else:
				bolt_lines(colour_of(path_colours[i]), path_ages[i], paths[i], 32, 0, endpoints[i], 1)
			if path_states[i] == 2 and is_lit(path_colours[i]):
				gte.pose(world, saved, endpoints[i][0], turn, Vector3i(4096, 4096, 4096), 0)
				layered_sprite(colour_of(path_colours[i]), 4, 1, Vector3i.ZERO)
			path_ages[i] += 1
			if path_ages[i] >= 8:
				path_ages[i] = 7
				fade_down(path_colours[i], 15)
				if is_black(path_colours[i]) and stage < 2:
					path_colours[i] = _colour_of_config("burst_color")
					path_ages[i] = 0
	if stage == 1:
		active_paths = mini(active_paths + 1, PATH_COUNT)
	tick += 1
	gte.pop()
	if stage == 3 and tick > 180:
		done = true


## The C arc tangent in turns of 4096 (the psyq ratan2), rounded, for the card's turn bytes.
static func _angle(y: int, x: int) -> int:
	return int(round(atan2(float(y), float(x)) * 4096.0 / TAU))


func _last_state() -> int:
	if card_states.is_empty():
		return 0
	return card_states[card_states.size() - 1]


func _scaled_colour(source: Array, divisor: int) -> PackedInt32Array:
	return PackedInt32Array([int(source[0]) / divisor, int(source[1]) / divisor, int(source[2]) / divisor])


func _colour_of_config(key: String) -> PackedInt32Array:
	var c: Array = config[key]
	return PackedInt32Array([int(c[0]), int(c[1]), int(c[2])])
