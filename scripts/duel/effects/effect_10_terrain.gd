extends "res://scripts/duel/effects/effect_program.gd"
## Effect 10: the terrain change. A ring of two contour rings opens and rises, a flat plane in the terrain's colour fades in, and then
## (once the game has loaded the new terrain, the stage signal -2) the plane's sparkles rise from it while columns of coloured
## fragments spawn on the field and rise and fade, and a full-screen flash follows. The variant (phase 0 to 5) is the terrain's
## configuration; 6 and up is the debug banner. Scene geometry: (160, 108).
##
## The variant's page mode (its semi-transparency) is the configuration's mode: the column quads use the page of the program's own
## image record (pair 22) when it is not 1, and the shared page (pair 12) when it is.

var config: Dictionary = {}
var start_scale := Vector3i(4096, 4096, 4096)
var rings: Array = []
var plate: Array = []
var particles: Array = []
var speeds: Array = []
var columns: Array = []
var ages: Array = []
var column_colours: Array = []
var height := 0
var stage := 0
var colour_ready := 0
var ring_ready := 0
var spawned := 0
var tick := 0
var colour := PackedInt32Array([0, 0, 0])
var screen_colour := PackedInt32Array([0, 0, 0])
var ring_colour := PackedInt32Array([0, 0, 0])
var plane_colour := PackedInt32Array([0, 0, 0])


func _init() -> void:
	variant_count = 6
	geometry = Vector2i(160, 108)


func _start(phase: int) -> void:
	config = Data.configs()["effect_10"][phase]
	var s: Array = Data.configs()["scale"]["10"]
	start_scale = Vector3i(s[0], s[1], s[2])
	rings = []
	for i in 2:
		rings.append(ring_level(175, 194, 16 - i * 8, 4))
	plate = plane(175, 16, 194)
	particles = random_scatter(175, 16, 194, 64)
	var speed := int(config["particle_speed"])
	speeds = []
	for i in 64:
		speeds.append(speed / 2 + speed * rng.randi_range(0, 4095) / 4096)
	columns = random_scatter(139, 0, 182, 64)
	column_colours = []
	ages = []
	for i in 64:
		column_colours.append(PackedInt32Array([1, 1, 1]))
		ages.append(0)
	var c: Array = config["color"]
	set_rgb(colour, int(c[0]) >> 3, int(c[1]) >> 3, int(c[2]) >> 3)
	set_all(screen_colour, 255)
	set_all(ring_colour, 1)
	set_all(plane_colour, 1)
	height = 8
	stage = 0
	ring_ready = 0
	colour_ready = 0
	spawned = 0
	tick = 0


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var mode := int(config["mode"])
	gte.pose(world, saved, zero, zero, start_scale, 2)
	if is_lit(colour) and stage == 0:
		f4(plate, colour_of(colour), mode, 1)
		f4(plate, colour_of(plane_colour), mode, 1)
		var c: Array = config["color"]
		if mode == 1:
			fade_up(colour, Vector3i(c[0], c[1], c[2]), 4)
			colour_ready = 1 if fade_up(plane_colour, Vector3i(192, 192, 192), 2) else 0
		else:
			colour_ready = 1 if fade_up(colour, Vector3i(c[0], c[1], c[2]), 4) else 0
	if is_lit(ring_colour) and stage == 0:
		contour(colour_of(ring_colour), rings[0], rings[1], 1, 1)
		if height < int(config["maximum_height"]):
			height += int(config["height_step"])
			var outer: Array = []
			for p in rings[1]:
				outer.append(Vector3i(p.x, -height, p.z))
			rings[1] = outer
		if ring_ready == 0:
			ring_ready = 1 if fade_up(ring_colour, Vector3i(255, 255, 255), 8) else 0
	gte.pose(world, saved, zero, zero, start_scale, 0)
	if is_lit(colour) and stage == 1:
		var lit := colour_of(colour)
		for i in 64:
			sparkle(lit, shifted(square(4), particles[i]), 80)
			particles[i] = particles[i] - Vector3i(0, speeds[i], 0)
		fade_down(colour, 8)
	if stage == 0:
		var pair := 12 if mode == 1 else 22
		var uv := [Vector2i(224, 192), Vector2i(255, 192), Vector2i(224, 223), Vector2i(255, 223)]
		for i in spawned:
			var column: PackedInt32Array = column_colours[i]
			if not is_lit(column):
				continue
			for j in 4:
				var shade := 0
				var rgb := Vector3i.ZERO
				if ((tick + i + j) & 1) == 0:
					rgb = Vector3i(column[0] / (j + 1), column[1] / (j + 1), column[2] / (j + 1))
				else:
					shade = 192 / (j + 1)
					rgb = Vector3i(shade, shade, shade)
				var quad := rect(12 - j, 24 - j)
				for k in quad.size():
					quad[k] = quad[k] + columns[i] + Vector3i(0, (j + 1) * 10 - int(ages[i]), 0)
				ft4(quad, pair, uv, rgb, 1, mode)
			ages[i] = int(ages[i]) + 12
			var target: Array = config["color"]
			if int(ages[i]) > 160:
				fade_down(column, 15)
				if is_black(column):
					ages[i] = 0
					set_all(column, 1)
			else:
				fade_up(column, Vector3i(int(target[0]) >> 1, int(target[1]) >> 1, int(target[2]) >> 1), 15)
		if (tick & 3) == 0:
			spawned += 1
			if spawned > 64:
				spawned = 64
	if is_lit(screen_colour) and stage == 1:
		screen_flash(screen_colour, 15)
	if colour_ready == 1 and ring_ready == 1:
		impact = true
	if stage == 0 and frame_phase < -1:
		if mode == 2:
			set_all(colour, 64)
		stage = 1
	tick += 1
	gte.pop()
	if is_black(colour) and is_black(screen_colour) and stage == 1:
		done = true
