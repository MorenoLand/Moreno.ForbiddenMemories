extends "res://scripts/duel/effects/effect_program.gd"
## Effect 5: the life point recovery splash. Sparkles rise from the picture's centre as the heal number climbs (a rising band
## that gathers at a point), the number bounces and settles, and a gradient disc of rings and fans grows around the point. The
## variant (phase 0 to 9) is the configuration (its number and colours); phase 10 and past take the debug banner. It is drawn in
## picture space. Variants 5 and up hold the number until the hold ends instead of settling it.

const RISING_HEIGHT := 98     # the North American build's start height of the rising band (the European build uses 106)

var config: Dictionary = {}
var rings: Array = []
var rising_positions: Array = []
var rising_colours: Array = []
var positions: Array = []
var velocities: Array = []
var rotations: Array = []
var number_position := Vector3i.ZERO
var number_velocity := Vector3i.ZERO
var scale_now := 0
var frame := 0
var tick := 0
var number_state := 0
var spawned := 0
var bounces := 0
var hold_frames := 0
var variant := 0
var background := PackedInt32Array([0, 0, 0])
var colour := PackedInt32Array([0, 0, 0])
var number_colour := PackedInt32Array([0, 0, 0])


func _init() -> void:
	variant_count = 10


func _start(phase: int) -> void:
	config = Data.configs()["effect_5"][phase]
	variant = phase
	var radii: Array = config["radii"]
	rings = [ring(radii[0]), ring(radii[1]), ring(radii[2])]
	rising_positions = []
	rising_colours = []
	for i in 64:
		rising_positions.append(Vector3i(rng_spread(70), -RISING_HEIGHT, rng_spread(70)))
		rising_colours.append(PackedInt32Array([1, 1, 1]))
	number_position = Vector3i.ZERO
	number_velocity = Vector3i(0, -int(config["bounce_speed"]), 0)
	positions = []
	velocities = []
	for i in int(config["particle_count"]):
		positions.append(Vector3i.ZERO)
		velocities.append(random_vector(int(config["particle_speed"])))
	rotations = []
	for i in int(config["strip_count"]):
		rotations.append(Vector3i(rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095)))
	set_all(background, 1)
	var c: Array = config["color"]
	set_rgb(colour, c[0], c[1], c[2])
	var n: Array = config["number_color"]
	set_rgb(number_colour, n[0], n[1], n[2])
	spawned = 0
	bounces = 1
	hold_frames = 0
	number_state = 0
	scale_now = 4096
	frame = 0
	tick = 0


## A random component spread over +-spread (the overlay's (rand() - rand()) % 4096 * spread / 4096).
func rng_spread(spread: int) -> int:
	return rng.randi_range(-4095, 4095) * spread / 4096


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var start: Array = Data.configs()["scale"]["5"]
	gte.pose(world, saved, zero, zero, Vector3i(start[0], start[1], start[2]), 1)
	var strip: int = int(config["strip_count"])
	var c: Array = config["color"]
	for i in spawned:
		if is_lit(rising_colours[i]):
			sparkle(colour_of(rising_colours[i]), shifted(square(4), rising_positions[i]), 0)
			rising_positions[i] = rising_positions[i] + Vector3i(0, int(config["rise_speed"]), 0)
		if rising_positions[i].y < 0:
			fade_up(rising_colours[i], Vector3i(c[0], c[1], c[2]), 31)
		else:
			fade_down(rising_colours[i], 15)
	if is_lit(background):
		screen_gradient(background)
		if rising_positions[strip - 1].y < 0:
			fade_up(background, Vector3i(c[0] >> 1, c[1] >> 1, c[2] >> 1), 4)
		elif variant < 5:
			fade_down(background, 4)
	if rising_positions[strip - 1].y > 0:
		if is_lit(number_colour):
			number_glyphs(int(config["number"]), colour_of(number_colour), number_position, number_state, 16, 0)
			number_position = number_position + number_velocity
			number_velocity = number_velocity + Vector3i(0, 4, 0)
			if number_position.y >= 0:
				number_position.y = 0
				if bounces < 5:
					bounces += 1
					number_velocity.y = -int(config["bounce_speed"]) / bounces
				elif variant < 5:
					number_state = 1
					number_velocity.y = 0
					fade_down(number_colour, 15)
				else:
					hold_frames += 1
		if is_lit(colour):
			var moving := variant < 5 or hold_frames == 0
			for i in int(config["particle_count"]):
				sparkle(colour_of(colour), shifted(square(4), positions[i]), 0)
				if moving:
					positions[i] = positions[i] + velocities[i]
			var small := scale_now >> 3
			gte.scaled_saved(saved, Vector3i(small, small, 4096))
			gradient_strip(colour_of(colour), rings[0], rings[1], rings[2], 0)
			gte.scaled_saved(saved, Vector3i(scale_now, scale_now, 4096))
			layered_sprite(colour_of(colour), int(config["sprite_size"]), 0, zero)
			for i in strip:
				gte.pose(world, saved, zero, rotations[i], Vector3i(4096, scale_now, 4096), 0)
				gradient_quads(colour_of(colour), config["widths"], int(config["height"]), 0)
				if moving:
					rotations[i] = rotations[i] + Vector3i(128, 128, 128)
			if variant < 5:
				fade_down(colour, 15)
			if scale_now < 0x7000:
				scale_now += 0x1000
	spawned = mini(spawned + 1, strip)
	frame += 1
	tick += 1
	gte.pop()
	if is_black(background) and is_black(colour) and is_black(number_colour) and variant < 5:
		done = true
	elif is_black(rising_colours[strip - 1]) and variant >= 5 and hold_frames >= 24:
		done = true
