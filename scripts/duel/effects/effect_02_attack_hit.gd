extends "res://scripts/duel/effects/effect_program.gd"
## Effect 2: the attack's hit with its figure. A burst of rings and sparkles at the defender, a starburst of three quads that grows
## and then rests, and the damage figure (red for damage, green for a gain) that fades in and out. The variant (phase 0 to 6) is
## the configuration: the damage's size class (3 to 5 in the battle), 0 to 2 for the plain bursts, and 6 when the number is zero.
## The request's number is the damage value (positive: a gain, negative: damage).
##
## Frame order (as the program draws it): the first pose (its scale starts from the program's start vector, configs "scale") draws the number;
## then the starburst pose at zero rotation, the three starburst quads (the first stage), the impact flag, the sparkles, the sprite,
## the ring strips and, in the variant with a second strip, the gradient ring; the screen flash when its colour is lit.

var config: Dictionary = {}
var rings: Array = []
var positions: Array = []
var velocities: Array = []
var rotations: Array = []
var scale_now := 0
var stage := 0
var number_state := 0
var colour := PackedInt32Array([0, 0, 0])
var background := PackedInt32Array([0, 0, 0])
var number_colour := PackedInt32Array([0, 0, 0])
var value := 0


func _init() -> void:
	variant_count = 7


func _start(phase: int) -> void:
	value = number
	var index := 6 if number == 0 else phase
	config = Data.configs()["effect_2"][index]
	var radii: Array = config["radii"]
	rings = [ring(radii[0]), ring(radii[1]), ring(radii[2])]
	var count: int = config["particle_count"]
	positions = []
	velocities = []
	for i in count:
		positions.append(Vector3i.ZERO)
		velocities.append(random_vector(config["particle_speed"]))
	rotations = []
	for i in 64:
		rotations.append(Vector3i(rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095)))
	scale_now = 0
	var c: Array = config["color"]
	set_rgb(colour, c[0], c[1], c[2])
	set_all(background, 0)
	stage = 0
	number_state = 0
	if value > 0:
		var red: Array = config["number_red"]
		var green: Array = config["number_green"]
		var blue: Array = config["number_blue"]
		set_rgb(number_colour, red[1] >> 3, green[1] >> 3, blue[1] >> 3)
	elif value < 0:
		var red: Array = config["number_red"]
		var green: Array = config["number_green"]
		var blue: Array = config["number_blue"]
		set_rgb(number_colour, red[0] >> 3, green[0] >> 3, blue[0] >> 3)
	else:
		set_all(number_colour, 0)


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var position := Vector3i.ZERO
	var rotation := Vector3i.ZERO
	var scale := Data.start_vector(2)
	gte.pose(world, saved, position, rotation, scale, 1)
	var widths: Array = config["widths"]
	var heights: Array = config["heights"]
	if stage != 0 and is_lit(number_colour) and value != 0:
		number_glyphs(-absi(value), colour_of(number_colour), position, 1, 16, 0)
		if number_state == 0:
			var red: Array = config["number_red"]
			var green: Array = config["number_green"]
			var blue: Array = config["number_blue"]
			var index := 1 if value > 0 else 0
			if value != 0:
				number_state = 1 if fade_up(number_colour, Vector3i(red[index], green[index], blue[index]), 15) else 0
		else:
			fade_down(number_colour, 8)
	if is_lit(colour):
		rotation = Vector3i(0, 0, -1536)
		scale = Vector3i(4096, 4096, 4096)
		gte.pose(world, saved, position, rotation, scale, 0)
		var lit := colour_of(colour)
		var lit4 := [Vector3i.ZERO, Vector3i.ZERO, lit, lit]
		if stage == 0:
			gt4(quad_rows(widths[2], widths[3], heights[1], heights[2]), RING_PAIR, RING_UV, lit4, 0, 1)
			gt4(quad_rows(widths[4], widths[3], heights[3], heights[2]), RING_PAIR, RING_UV, lit4, 0, 1)
		else:
			if stage == 1:
				set_all(background, 255)
			gt4(quad_rows(widths[2], widths[1], heights[1], 0), RING_PAIR, RING_UV, lit4, 0, 1)
		if stage >= 2:
			gt4(quad_rows(widths[0], widths[1], heights[0], 0), RING_PAIR, RING_UV, lit4, 0, 1)
		if stage != 0:
			impact = true
			for i in positions.size():
				sparkle(lit, shifted(square(4), positions[i]), 0)
				positions[i] = positions[i] + velocities[i]
			var big := scale_now >> 1
			scale = Vector3i(big + 4096, big + 4096, 0)
			gte.pose(world, saved, position, rotation, scale, 1)
			layered_sprite(lit, int(config["sprite_size"]), 0, position)
			var grown: int = scale_now + 4096
			gte.scaled_saved(saved, Vector3i(grown, grown, 0))
			ring_strip(half(lit), rings[0], rings[1], rings[2], 0)
			if int(config["variant"]) == 1:
				var half_grown := grown >> 1
				gte.scaled_saved(saved, Vector3i(half_grown, half_grown, 0))
				ring_strip(lit, rings[0], rings[1], rings[2], 0)
				scale = Vector3i(4096, scale_now, 4096)
				var strip: Array = config["strip_widths"]
				for i in 64:
					gte.pose(world, saved, position, rotations[i], scale, 2)
					gradient_quads(lit, strip, int(config["strip_height"]), 0)
			if scale_now < 0x6000:
				scale_now += 0x800
			fade_down(colour, 8)
		if stage < 3:
			stage += 1
	if is_lit(background):
		screen_flash(background, 15)
	gte.pop()
	if is_black(colour) and is_black(background) and is_black(number_colour):
		done = true
