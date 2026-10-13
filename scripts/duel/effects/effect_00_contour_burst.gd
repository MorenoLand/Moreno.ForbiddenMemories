extends "res://scripts/duel/effects/effect_program.gd"
## Effect 0: the placement burst. A contour of two diamond rings that brightens to a colour, then (after the configured delay) a
## gradient disc of three rings, a layered sprite and sixteen spinning gradient fans that grow, with the colour fading out. The
## variant (phase 0 to 29) is the configuration; phase 30 and past take the debug banner. It is drawn in picture space.
## The request's number is not used.

var config: Dictionary = {}
var rings: Array = []
var quads: Array = []
var rotations: Array = []
var scale_now := 0
var frame := 0
var colour := PackedInt32Array([0, 0, 0])


func _init() -> void:
	variant_count = 30


func _start(phase: int) -> void:
	config = Data.configs()["effect_0"][phase]
	var radii: Array = config["radii"]
	rings = [ring(radii[0]), ring(radii[1]), ring(radii[2])]
	quads = []
	for i in 2:
		quads.append(diamond(24 + i * 6, 28 + i * 6, 4))
	rotations = []
	for i in 16:
		rotations.append(random_vector(4096))
	set_all(colour, 1)
	scale_now = 4096
	frame = 0


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var widths: Array = config["widths"]
	var height: int = config["height"]
	if is_lit(colour):
		gte.pose(world, saved, zero, zero, Vector3i(4096, 4096, 4096), 1)
		contour(colour_of(colour), quads[0], quads[1], 0, 1)
		if frame >= int(config["delay"]):
			impact = true
			var small := scale_now >> 3
			gte.scaled_saved(saved, Vector3i(small, small, 4096))
			gradient_strip(colour_of(colour), rings[0], rings[1], rings[2], 0)
			gte.scaled_saved(saved, Vector3i(scale_now, scale_now, 4096))
			layered_sprite(colour_of(colour), int(config["sprite_size"]), 0, zero)
			for i in 16:
				gte.pose(world, saved, zero, rotations[i], Vector3i(4096, scale_now, 4096), 2)
				gradient_quads(colour_of(colour), widths, height, 0)
				rotations[i] = rotations[i] + Vector3i(128, 128, 128)
			fade_down(colour, 15)
			if scale_now < 0x7000:
				scale_now += 0x1000
		else:
			var c: Array = config["color"]
			fade_up(colour, Vector3i(c[0], c[1], c[2]), 31)
	frame += 1
	gte.pop()
	if is_black(colour):
		done = true
