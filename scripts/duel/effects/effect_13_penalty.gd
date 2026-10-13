extends "res://scripts/duel/effects/effect_program.gd"
## Effect 13: the stat penalty (Spellbinding, Shadow Spell) and the field effects that share it. Forty-eight jagged bolts rise from the
## ground beneath the monster, one more each frame, their colour fading along each bolt; a glow and (in the variants with a background)
## a textured disc surround the origin, the bolts' ends burst into sprites, and a number in the penalty's colour (the request's number)
## bounces up from the monster once twelve bolts are out. The variant (phase 0 to 3) is the configuration; 4 and up is the banner.
## Scene geometry: (160, 108).
##
## The overlay switches the page's semi-transparency for the glow to the configuration's blend; the sprites are drawn additive with
## their own mode (the primitive's mode overrides the page's), so the port uses the blend only for the bolts and the faint outer glow.

var config: Dictionary = {}
var start_scale := Vector3i(4096, 4096, 4096)
var paths: Array = []
var endpoints: Array = []
var colours: Array = []
var ages: Array = []
var states: Array = []
var angles: Array = []
var origin := Vector3i.ZERO
var number_position := Vector3i.ZERO
var number_velocity := Vector3i(0, -12, 0)
var number_mode := 0
var bounces := 0
var active := 0
var tick := 1
var ready := 0
var glow := PackedInt32Array([0, 0, 0])
var background := PackedInt32Array([0, 0, 0])
var number_colour := PackedInt32Array([0, 0, 0])


func _init() -> void:
	variant_count = 4
	geometry = Vector2i(160, 108)


func _start(phase: int) -> void:
	config = Data.configs()["effect_13"][phase]
	var s: Array = Data.configs()["scale"]["13"]
	start_scale = Vector3i(s[0], s[1], s[2])
	var c: Array = config["color"]
	var n: Array = config["number_color"]
	origin = Vector3i(0, -int(config["height"]), 0) + offset
	paths = []
	endpoints = []
	colours = []
	ages = []
	states = []
	angles = []
	for i in 48:
		paths.append(bolt_path(int(config["radius"]), int(config["size"]) >> 1, int(config["height"]), 8))
		endpoints.append([Vector3i.ZERO])
		var bolt := PackedInt32Array([0, 0, 0])
		set_rgb(bolt, c[0], c[1], c[2])
		colours.append(bolt)
		ages.append(0)
		states.append(0)
		angles.append(rng.randi_range(0, 511))
	number_position = Vector3i.ZERO
	number_velocity = Vector3i(0, -12, 0)
	active = 0
	bounces = 0
	tick = 1
	ready = 0
	number_mode = 0
	set_rgb(glow, int(c[0]) >> 3, int(c[1]) >> 3, int(c[2]) >> 3)
	set_all(background, 1 if int(config["background"]) != 0 else 0)
	set_rgb(number_colour, n[0], n[1], n[2])


## The disc's quad at one corner (the overlay's quad helper): (sx * size, sy * size), (0, sy * size), (sx * size, 0), (0, 0).
static func disc_corner(size: int, index: int) -> Array:
	var sx := -1 if index % 2 == 0 else 1
	var sy := -1 if index < 2 else 1
	return [Vector3i(sx * size, sy * size, 0), Vector3i(0, sy * size, 0), Vector3i(sx * size, 0, 0), Vector3i.ZERO]


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var scale := start_scale
	var rot := zero          # the overlay's rotation variable: the last one set (the endpoints' poses use it)
	if is_lit(glow):
		rot = Vector3i(0, 0, tick * 128)
		gte.pose(world, saved, origin, rot, scale, 0)
		layered_sprite(colour_of(glow), int(config["size"]), 1, zero)
		if int(config["blend"]) != 1:
			var faint := Vector3i(glow[0] / 64, glow[1] / 64, glow[2] / 64)
			layered_sprite(faint, int(config["size"]) * 2, 16, zero)
		if active == 48:
			fade_down(glow, 15)
		else:
			fade_up(glow, Vector3i(int(config["color"][0]) >> 1, int(config["color"][1]) >> 1, int(config["color"][2]) >> 1), 15)
	if int(config["background"]) == 1 and is_lit(background):
		rot = zero
		gte.pose(world, saved, origin, rot, scale, 0)
		var size := int(config["size"]) * 2
		var uv := [Vector2i(128, 128), Vector2i(191, 128), Vector2i(128, 191), Vector2i(191, 191)]
		for i in 4:
			ft4(disc_corner(size, i), 7, uv, colour_of(background), 32, 1)
		if ready == 0:
			ready = 1 if fade_up(background, Vector3i(128, 128, 128), 8) else 0
		if active == 48:
			fade_down(background, 8)
	var blend := int(config["blend"])
	for i in active:
		rot = Vector3i(0, angles[i], 0)
		gte.pose(world, saved, offset, rot, scale, 2)
		if is_lit(colours[i]):
			var bolt := colour_of(colours[i])
			if states[i] != 2:
				states[i] = bolt_lines(bolt, ages[i], paths[i], 16, 1, endpoints[i], blend)
			else:
				bolt_lines(bolt, ages[i], paths[i], 32, 0, endpoints[i], blend)
			ages[i] = ages[i] + 1
			if ages[i] >= 8:
				ages[i] = 7
				fade_down(colours[i], 15)
	for i in active:
		if states[i] == 2 and is_lit(colours[i]):
			impact = true
			gte.pose(world, saved, endpoints[i][0], rot, scale, 0)
			layered_sprite(colour_of(colours[i]), int(config["particle_size"]), 1, zero)
	if active >= 12 and is_lit(number_colour):
		rot = zero
		gte.pose(world, saved, offset, rot, Vector3i(4096, 4096, 4096), 0)
		number_glyphs(-absi(number), colour_of(number_colour), number_position, number_mode, 10, 1)
		number_position = number_position + number_velocity
		number_velocity = number_velocity + Vector3i(0, 3, 0)
		if number_position.y >= 0:
			number_position = Vector3i(number_position.x, 0, number_position.z)
			if bounces < 5:
				bounces += 1
				number_velocity = Vector3i(0, -12 / bounces, 0)
			else:
				number_mode = 1
				number_velocity = Vector3i.ZERO
				fade_down(number_colour, 15)
	active = mini(active + 2, 48)
	tick += 1
	gte.pop()
	if is_black(colours[47]) and is_black(background) and is_black(number_colour):
		done = true
