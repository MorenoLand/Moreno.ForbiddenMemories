extends "res://scripts/duel/effects/effect_program.gd"
## Effect 18: the ring burst of the ritual's start and the Swords of Revealing Light's start. Two quads contour a ring of light
## (the contour helper), then after a delay a field of sparkles leaves the centre and a gradient burst of three rings opens, with
## spinning gradient quads and, in variant 1, an outer ring strip; the colour fades out in the burst. Variant 0 and 1 are the two
## configurations (the variant at 2 or more is the debug banner, the cross-line path).

var config: Dictionary = {}
var rings: Array = []          # three rings of 32 points: the burst's gradient strip
var outer_rings: Array = []    # three rings of the variant 1 outer strip
var quads: Array = []          # two four-point quads: the contour's inner and outer ring
var rotations: Array = []      # sixteen spin angles of the gradient quads
var positions: Array = []      # the sparkles' positions and velocities (32 each)
var velocities: Array = []
var colour := PackedInt32Array([1, 1, 1])
var scale_now := 4096
var frame := 0


func _init() -> void:
	variant_count = 2


func _start(phase: int) -> void:
	config = Data.configs()["effect_18"][phase]
	rings = []
	for radius in config["radii"]:
		rings.append(ring(int(radius)))
	outer_rings = []
	for radius in config["outer_radii"]:
		outer_rings.append(ring(int(radius)))
	quads = []
	for i in 2:
		if int(config["variant"]) == 1:
			quads.append(diamond(24 + i * 6, 28 + i * 6, 4))
		else:
			quads.append(diamond(70 + i * 6, 98 + i * 6, 4))
	rotations = []
	for i in 16:
		rotations.append(Vector3i(rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095)))
	var speed := int(config["particle_speed"])
	positions = []
	velocities = random_scatter(speed, speed, speed, 32)
	for i in 32:
		positions.append(Vector3i.ZERO)
	set_all(colour, 1)
	scale_now = 4096
	frame = 0


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var position := Vector3i.ZERO
	var rotation := Vector3i.ZERO
	var scale := Vector3i(4096, 4096, 4096)
	if is_lit(colour):
		gte.pose(world, saved, position, rotation, scale, 1)
		var lit := colour_of(colour)
		contour(lit, quads[0], quads[1], 0, 1)
		if frame >= int(config["delay"]):
			impact = true
			for i in 32:
				sparkle(lit, shifted(square(4), positions[i]), 0)
				positions[i] = positions[i] + velocities[i]
			var grown := scale_now
			gte.scaled_saved(saved, Vector3i(grown >> 3, grown >> 3, 4096))
			gradient_strip(lit, rings[0], rings[1], rings[2], 0)
			if int(config["variant"]) == 1:
				ring_strip(half(lit), outer_rings[0], outer_rings[1], outer_rings[2], 0)
			gte.scaled_saved(saved, Vector3i(grown, grown, 4096))
			layered_sprite(lit, int(config["sprite_size"]), 0, position)
			scale = Vector3i(4096, grown, 4096)
			var widths: Array = config["widths"]
			for i in 16:
				gte.pose(world, saved, position, rotations[i], scale, 2)
				gradient_quads(lit, widths, int(config["height"]), 0)
				rotations[i] = rotations[i] + Vector3i(128, 128, 128)
			fade_down(colour, 15)
			if scale_now < 0x7000:
				scale_now += 0x1000
		else:
			var target: Array = config["color"]
			fade_up(colour, Vector3i(int(target[0]), int(target[1]), int(target[2])), 31)
	frame += 1
	gte.pop()
	if is_black(colour):
		done = true
