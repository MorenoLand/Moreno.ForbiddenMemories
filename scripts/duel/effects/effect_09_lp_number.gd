extends "res://scripts/duel/effects/effect_program.gd"
## Effect 9: the life point change with its number, the second request (the number of the life points rising). A red number drops
## from above, bounces on the ground line until it settles, then the background brightens and a ring burst opens (a gradient strip,
## the layered sprite and the rotating gradient quads) while a second number of the configured colour rises and fades. The variant
## (phase 0 to 4) is the configuration; 5 and up is the debug banner. Picture geometry.
##
## The overlay plays a sound at the burst's start (its sound effect 26); the port plays no sound (the effect programs are visual).

var config: Dictionary = {}
var start_scale := Vector3i(4096, 4096, 4096)
var negative := Vector3i.ZERO
var negative_step := 0
var positive := Vector3i.ZERO
var positive_step := 0
var negative_mode := 0
var positive_mode := 0
var stage := 0
var bounce_count := 1
var rings: Array = []
var positions: Array = []
var velocities: Array = []
var rotations: Array = []
var negative_colour := PackedInt32Array([0, 0, 0])
var background_colour := PackedInt32Array([0, 0, 0])
var effects_colour := PackedInt32Array([0, 0, 0])
var positive_colour := PackedInt32Array([0, 0, 0])
const BURST_SCALE := 0x7000


func _init() -> void:
	variant_count = 5


func _start(phase: int) -> void:
	config = Data.configs()["effect_9"][phase]
	var s: Array = Data.configs()["scale"]["9"]
	start_scale = Vector3i(s[0], s[1], s[2])
	var radii: Array = config["radii"]
	rings = []
	for i in 3:
		rings.append(ring(radii[i]))
	negative = Vector3i(0, -120, 0)
	negative_step = 0
	positive = Vector3i.ZERO
	positive_step = 0
	var speed := int(config["particle_speed"])
	positions = []
	for i in 32:
		positions.append(Vector3i.ZERO)
	velocities = random_scatter(speed, speed, speed, 32)
	rotations = random_scatter(4096, 4096, 4096, int(config["rotation_count"]))
	var c: Array = config["color"]
	var n: Array = config["number_color"]
	set_rgb(negative_colour, 255, 64, 64)
	set_rgb(background_colour, int(c[0]) >> 2, int(c[1]) >> 2, int(c[2]) >> 2)
	set_rgb(effects_colour, c[0], c[1], c[2])
	set_rgb(positive_colour, n[0], n[1], n[2])
	bounce_count = 1
	negative_mode = 0
	positive_mode = 0
	stage = 0


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var rotation := Vector3i.ZERO
	gte.pose(world, saved, Vector3i.ZERO, rotation, start_scale, 1)
	if is_lit(background_colour):
		screen_gradient(background_colour)
		if stage != 0:
			fade_down(background_colour, 4)
	if is_lit(negative_colour):
		number_glyphs(-int(config["value"]), colour_of(negative_colour), negative, negative_mode, 16, 0)
		negative = Vector3i(negative.x, negative.y + negative_step, negative.z)
		negative_step += 4
		if negative.y >= 0:
			negative = Vector3i(negative.x, 0, negative.z)
			if stage == 0:
				positive_step = negative_step
				negative_step = -int(config["bounce_speed"])
				stage = 1
			elif bounce_count < 5:
				bounce_count += 1
				negative_step = -int(config["bounce_speed"]) / bounce_count
			else:
				negative_mode = 1
				negative_step = 0
				fade_down(negative_colour, 15)
	if is_lit(positive_colour) and positive.y < 200:
		number_glyphs(int(config["value"]), colour_of(positive_colour), positive, positive_mode, 16, 0)
		positive = Vector3i(positive.x, positive.y + positive_step, positive.z)
		if stage != 0:
			positive_mode = 1
			fade_down(positive_colour, 15)
	elif positive.y >= 200:
		set_all(positive_colour, 0)
	if is_lit(effects_colour):
		var lit := colour_of(effects_colour)
		if stage >= 2:
			for i in 32:
				sparkle(lit, shifted(square(4), positions[i]), 0)
				positions[i] = positions[i] + velocities[i]
		gte.scaled_saved(saved, Vector3i(BURST_SCALE >> 3, BURST_SCALE >> 3, 4096))
		gradient_strip(lit, rings[0], rings[1], rings[2], 0)
		gte.scaled_saved(saved, Vector3i(BURST_SCALE, BURST_SCALE, 4096))
		layered_sprite(lit, int(config["sprite_size"]), 0, Vector3i.ZERO)
		var widths: Array = config["widths"]
		for i in int(config["rotation_count"]):
			gte.pose(world, saved, Vector3i.ZERO, rotations[i], Vector3i(4096, BURST_SCALE, 4096), 2)
			gradient_quads(lit, widths, int(config["height"]), 0)
		if stage != 0:
			fade_down(effects_colour, 15)
	if stage == 1:
		impact = true
		set_rgb(background_colour, 63, 16, 63)
		set_rgb(effects_colour, 255, 64, 255)
		stage = 2
	gte.pop()
	if is_black(negative_colour) and is_black(background_colour) and is_black(effects_colour) and is_black(positive_colour):
		done = true
