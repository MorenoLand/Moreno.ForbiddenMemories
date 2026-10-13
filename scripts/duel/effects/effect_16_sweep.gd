extends "res://scripts/duel/effects/effect_program.gd"
## Effect 16: the Raigeki sweep. Five columns of bolt-like flashes (four strips each, a random wobble per column) rise over the field,
## one more column every eight frames up to five; each column that completes its rise lights its sparkles, a pair of rings opens at its
## foot and the strip's colour fades. The variant is the configuration (phase 0 or 1; 2 and up is the banner). Program 20 is this
## program with phase 1. Scene geometry: (160, 108).
##
## The overlay sets the impact flag to the count of columns that have struck (a non-zero value); the port sets it to true.

var config: Dictionary = {}
var start_scale := Vector3i(4096, 4096, 4096)
var paths: Array = []        # paths[column][row][strip]: the strip's point at the row
var clouds: Array = []       # clouds[column]: the ray points of the column's glow
var rings: Array = []
var positions: Array = []    # 160 points: window j * 5 holds column j's sparkles (the overlay's overlapping windows)
var velocities: Array = []
var origins: Array = []
var activated: Array = []
var ages: Array = []
var scales: Array = []
var primary: Array = []      # per column: the strip colour (192 to black)
var secondary: Array = []    # per column: the glow colour (the configuration's)
var hits := 0
var count := 0
var tick := 0


func _init() -> void:
	variant_count = 2
	geometry = Vector2i(160, 108)


func _start(phase: int) -> void:
	config = Data.configs()["effect_16"][0]
	var s: Array = Data.configs()["scale"]["16"]
	start_scale = Vector3i(s[0], s[1], s[2])
	var spread := int(config["spread"])
	var vertical := int(config["vertical_step"])
	paths = []
	clouds = []
	origins = []
	activated = []
	ages = []
	scales = []
	primary = []
	secondary = []
	var c: Array = config["color"]
	var direction := -1 if offset.z < 0 else 1
	for i in 5:
		var column: Array = []
		for k in 5:
			var row: Array = []
			for l in 4:
				var x := spread * rng.randi_range(-4095, 4095) / 4096
				var z := spread * rng.randi_range(-4095, 4095) / 4096
				var point := Vector3i(x, k * vertical - 256, z)
				if k == 4:
					point = Vector3i(0, point.y, 0)
				row.append(point)
			column.append(row)
		paths.append(column)
		clouds.append(random_scatter(int(config["particle_spread"]), int(config["particle_spread"]), int(config["particle_spread"]), 32))
		var window := random_upward(8, 8, 8, 32)
		for k in 32:
			if positions.size() < 160 and i * 5 + k >= positions.size():
				positions.append(Vector3i.ZERO)
				velocities.append(Vector3i.ZERO)
			positions[i * 5 + k] = Vector3i.ZERO
			velocities[i * 5 + k] = window[k]
		scales.append(4096)
		ages.append(0)
		var primary_colour := PackedInt32Array([0, 0, 0])
		set_all(primary_colour, 192)
		primary.append(primary_colour)
		var secondary_colour := PackedInt32Array([0, 0, 0])
		set_rgb(secondary_colour, c[0], c[1], c[2])
		secondary.append(secondary_colour)
		origins.append(Vector3i((70 * i - 140) * direction, -24, 95 * (1 if offset.z >= 0 else -1)))
		activated.append(0)
	rings = []
	var radii: Array = config["ring_radii"]
	for k in 3:
		rings.append(ring_xz(radii[k], radii[k], int(config["ring_height"]) * k, 32))
	count = 0
	hits = 0
	tick = 0


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var rotation := Vector3i.ZERO
	var scale := start_scale
	var widths: Array = config["widths"]
	var glows: Array = config["glow_sizes"]
	var uv := [Vector2i(80, 0), Vector2i(127, 0), Vector2i(80, 127), Vector2i(127, 127)]
	for j in count:
		gte.pose(world, saved, origins[j], rotation, scale, 3)
		if is_lit(primary[j]) or is_lit(secondary[j]):
			var age: int = ages[j]
			for i in 4:
				for k in age:
					var strip: Array = []
					for l in 4:
						var point: Vector3i = paths[j][k + l / 2][i]
						strip.append(point + Vector3i(sign_of(l) * int(widths[i]), 0, 0))
					ft4(strip, 14, uv, colour_of(primary[j]), 32, 1)
				var size: int = int(glows[i]) * 2 if age == 4 else int(glows[i])
				layered_sprite(colour_of(secondary[j]), size, 32, paths[j][age][i])
			var halved := half(colour_of(secondary[j]))
			var translation: Vector3i = paths[j][age][0] + origins[j]
			gte.pose(world, saved, translation, rotation, scale, 2)
			ray_triangles(halved, int(config["line_width"]), clouds[j], 32)
			ages[j] = age + 1
			if ages[j] >= 5:
				if activated[j] == 0:
					hits += 1
					activated[j] = 1
					impact = true
				ages[j] = 4
				for k in 32:
					var index := j * 5 + k
					sparkle(colour_of(secondary[j]), shifted(square(4), positions[index]), 1)
					positions[index] = positions[index] + velocities[index]
				scale = Vector3i(scales[j], 4096, scales[j])
				gte.scaled_saved(saved, scale)
				ring_strip(halved, rings[0], rings[1], rings[2], 32)
				scale = Vector3i(scales[j] / 2, 6144, scales[j] / 2)
				gte.scaled_saved(saved, scale)
				ring_strip(colour_of(secondary[j]), rings[0], rings[1], rings[2], 32)
				if scales[j] < 16384:
					scales[j] += 4096
				fade_down(primary[j], 31)
				fade_down(secondary[j], 15)
	tick += 1
	if (tick & 7) == 0:
		count += 1
		if count > 5:
			count = 5
	gte.pop()
	if is_black(primary[4]) and is_black(secondary[4]):
		done = true


## The sign the overlay's corner helper gives point l: -1 for points 0 and 2, +1 for 1 and 3.
static func sign_of(l: int) -> int:
	return -1 if l % 2 == 0 else 1
