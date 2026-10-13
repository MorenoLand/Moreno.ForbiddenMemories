extends "res://scripts/duel/effects/effect_program.gd"
## Effect 7: the direct damage figure (the second request of a direct damage card). Glowing trails fall from above the start height
## to a point, one by one; each trail's head grows into a ring and particles, and the damage number bounces in the middle of the
## picture and settles, with the screen dimmed to a gradient. The variant (phase 0 to 4) is the configuration; phase 5 and past
## take the debug banner. It is drawn in picture space.

const TRAIL_SPREAD := 12     # the trail's spread (13 in the European build)
const TARGET_HEIGHT := 98    # the trail's target height (106 in the European build)

var config: Dictionary = {}
var trails: Array = []
var velocities: Array = []
var rings: Array = []
var particles: Array = []
var particle_velocities: Array = []
var number_position := Vector3i.ZERO
var number_velocity := Vector3i.ZERO
var sizes: Array = []
var scales: Array = []
var states: Array = []
var ages: Array = []
var number_mode := 0
var active := 0
var bounces := 0
var frame := 0
var tick := 0
var colours: Array = []
var background := PackedInt32Array([0, 0, 0])
var number_colour := PackedInt32Array([0, 0, 0])


func _init() -> void:
	variant_count = 5


func _start(phase: int) -> void:
	config = Data.configs()["effect_7"][phase]
	var duration := maxi(int(config["duration"]), 1)
	var start_y := int(config["start_y"])
	var c: Array = config["color"]
	trails = []
	velocities = []
	colours = []
	ages = []
	sizes = []
	scales = []
	states = []
	particles = []
	particle_velocities = []
	for i in 16:
		var x := rng.randi_range(-4095, 4095)
		var y := rng.randi_range(-4095, 4095)
		var streak := []
		for j in 4:
			streak.append(Vector3i(x * 35 / 4096, start_y + y * TRAIL_SPREAD / 4096, 0))
		trails.append(streak)
		var vx: int = (rng.randi_range(-4095, 4095) * 70 / 4096 - streak[0].x) / duration
		var vy: int = (rng.randi_range(-4095, 4095) * TARGET_HEIGHT / 4096 - streak[0].y) / duration
		velocities.append(Vector3i(vx, vy, 0))
		colours.append(PackedInt32Array([c[0], c[1], c[2]]))
		ages.append(0)
		sizes.append(int(config["size"]))
		scales.append(0)
		states.append(0)
		var spray: Array = []
		var spray_velocity: Array = []
		for j in 32:
			spray.append(Vector3i.ZERO)
			spray_velocity.append(random_vector(int(config["particle_speed"])))
		particles.append(spray)
		particle_velocities.append(spray_velocity)
	number_position = Vector3i.ZERO
	rings = [ring(int(config["radii"][0])), ring(int(config["radii"][1])), ring(int(config["radii"][2]))]
	set_all(background, 1)
	var nc: Array = config["number_color"]
	set_rgb(number_colour, nc[0], nc[1], nc[2])
	number_mode = 0
	active = 0
	bounces = 0
	frame = 0
	tick = 0
	number_velocity = Vector3i(0, -16, 0)


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var unit := Vector3i(4096, 4096, 4096)
	var count := int(config["count"])
	var duration := int(config["duration"])
	var c: Array = config["color"]
	for i in active:
		if states[i] == 0:
			gte.pose(world, saved, zero, zero, unit, 0)
			for j in 4:
				var shade := Vector3i(colours[i][0] / (j + 1), colours[i][1] / (j + 1), colours[i][2] / (j + 1))
				glow_quad(shade, sizes[i] / (j + 1), trails[i][j])
				trails[i][j] = trails[i][j] + Vector3i(velocities[i].x / (j + 1), velocities[i].y / (j + 1), 0)
			if ages[i] >= duration:
				states[i] = 1
			else:
				ages[i] += 1
				sizes[i] += int(config["growth"])
		elif states[i] == 1:
			impact = true
			if is_lit(colours[i]):
				gte.pose(world, saved, trails[i][0], zero, unit, 1)
				for j in int(config["particle_count"]):
					glow_quad(colour_of(colours[i]), int(config["particle_size"]), particles[i][j])
					particles[i][j] = particles[i][j] + particle_velocities[i][j]
				var s: int = scales[i] >> 1
				gte.scaled_saved(saved, Vector3i(s, s, 0))
				ring_strip(colour_of(colours[i]), rings[0], rings[1], rings[2], 0)
				layered_sprite(colour_of(colours[i]), sizes[i], 0, zero)
				if scales[i] < 0x6000:
					scales[i] += 0x1000
				fade_down(colours[i], 15)
			elif is_black(colours[i]):
				states[i] = 2
	if (tick & 1) == 0:
		active = mini(active + 1, count)
	gte.pose(world, saved, zero, zero, unit, 0)
	if states[count - 1] != 0 and is_lit(number_colour):
		number_glyphs(int(config["number"]), colour_of(number_colour), number_position, number_mode, 16, 0)
		number_position = number_position + number_velocity
		number_velocity = number_velocity + Vector3i(0, 4, 0)
		if number_position.y >= 0:
			number_position.y = 0
			if bounces < 5:
				bounces += 1
				number_velocity.y = -16 / bounces
			else:
				number_mode = 1
				number_velocity.y = 0
				fade_down(number_colour, 15)
	if is_lit(background):
		screen_gradient(background)
		if states[count - 1] == 0:
			fade_up(background, Vector3i(c[0] >> 1, c[1] >> 1, c[2] >> 1), 4)
		else:
			fade_down(background, 4)
	frame += 1
	tick += 1
	gte.pop()
	if is_black(colours[count - 1]) and is_black(background) and is_black(number_colour):
		done = true
