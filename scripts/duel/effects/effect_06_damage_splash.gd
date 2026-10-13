extends "res://scripts/duel/effects/effect_program.gd"
## Effect 6: the direct damage splash. Glowing trails streak in from the top of the picture and fall to a point, one by one; each
## trail's head bursts into a ring and particles, then a column of the damage number rises and holds. The variant (phase 0 to 5) is
## the configuration (the damage's size class); phase 6 and past take the debug banner. Variants 5 and up hold their last frame.
## It is drawn in picture space.

const START_HEIGHT := 98     # the North American build's trail start height (the European build uses 106)
const TARGET_SPREAD := 12    # the trail target's spread (13 in the European build)

var config: Dictionary = {}
var trails: Array = []          # 16 x 4 positions
var velocities: Array = []      # 16 trail velocities (x, y)
var rings: Array = []
var particles: Array = []       # 16 x 32 positions
var particle_velocities: Array = []
var column := Vector3i.ZERO
var column_step := 0
var column_size := 0
var sizes: Array = []
var scales: Array = []
var states: Array = []
var ages: Array = []
var column_mode := 0
var active := 0
var hold := 0
var frame := 0
var tick := 0
var variant := 0
var colours: Array = []
var background := PackedInt32Array([0, 0, 0])
var column_colour := PackedInt32Array([0, 0, 0])


func _init() -> void:
	variant_count = 6


func _start(phase: int) -> void:
	config = Data.configs()["effect_6"][phase]
	variant = phase
	trails = []
	velocities = []
	colours = []
	ages = []
	sizes = []
	scales = []
	states = []
	particles = []
	particle_velocities = []
	var duration := maxi(int(config["duration"]), 1)
	var c: Array = config["color"]
	for i in 16:
		var x := rng.randi_range(-4095, 4095)
		var y := rng.randi_range(-4095, 4095)
		var streak := []
		for j in 4:
			streak.append(Vector3i(x * 70 / 4096, y * START_HEIGHT / 4096, 0))
		trails.append(streak)
		var vx: int = (rng.randi_range(-4095, 4095) * 35 / 4096 - streak[0].x) / duration
		var vy: int = (int(config["target_y"]) + rng.randi_range(-4095, 4095) * TARGET_SPREAD / 4096 - streak[0].y) / duration
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
	column = Vector3i(0, -60, 0)
	column_step = 12
	column_size = 3
	rings = [ring(int(config["radii"][0])), ring(int(config["radii"][1])), ring(int(config["radii"][2]))]
	set_all(background, 1)
	var cc: Array = config["column_color"]
	set_rgb(column_colour, cc[0], cc[1], cc[2])
	column_mode = 0
	active = 0
	hold = 0
	frame = 0
	tick = 0


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
				sizes[i] -= int(config["shrink"])
		elif states[i] == 1:
			impact = true
			if is_lit(colours[i]) and variant < 5:
				gte.pose(world, saved, trails[i][0], zero, unit, 1)
				for j in int(config["particle_count"]):
					glow_quad(colour_of(colours[i]), int(config["particle_size"]), particles[i][j])
					particles[i][j] = particles[i][j] + particle_velocities[i][j]
				var s: int = scales[i] >> 1
				gte.scaled_saved(saved, Vector3i(s, s, 0))
				ring_strip(colour_of(colours[i]), rings[0], rings[1], rings[2], 0)
				layered_sprite(colour_of(colours[i]), sizes[i] * 2, 0, zero)
				if scales[i] < 0x6000:
					scales[i] += 0x1000
				fade_down(colours[i], 15)
			elif is_black(colours[i]):
				states[i] = 2
	if (tick & 1) == 0:
		active = mini(active + 1, count)
	gte.pose(world, saved, zero, zero, unit, 0)
	if states[count - 1] != 0 and is_lit(column_colour) and variant < 5:
		number_glyphs(int(config["column_value"]), colour_of(column_colour), column, column_mode, column_size, 0)
		if column_size >= 15:
			if hold >= 32:
				column_mode = 1
				fade_down(column_colour, 15)
			else:
				hold += 1
		else:
			column = column + Vector3i(0, column_step, 0)
			column_size += 3
	if is_lit(background) and variant < 5:
		screen_gradient(background)
		if states[count - 1] == 0:
			fade_up(background, Vector3i(c[0] >> 1, c[1] >> 1, c[2] >> 1), 4)
		else:
			fade_down(background, 4)
	frame += 1
	tick += 1
	gte.pop()
	if variant >= 5:
		if states[count - 1] != 0:
			done = true
	elif is_black(colours[count - 1]) and is_black(background) and is_black(column_colour):
		done = true
