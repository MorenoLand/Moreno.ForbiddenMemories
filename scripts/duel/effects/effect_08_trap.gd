extends "res://scripts/duel/effects/effect_program.gd"
## Effect 8: the trap's resolution (and the Cursebreaker's). A starburst of thin rays and sparkles at the request's point, a layered
## sprite and a textured quad that grow and shrink as the starburst spreads, and up to two rings that widen behind them. The variant
## (phase 0 to 5) is the configuration; 6 and up is the debug banner. Scene geometry: (160, 108).
##
## Frame order (as the program draws it): the pose at the start vector, the rays (additive, behind), the sparkles (advancing), the
## layered sprite, the textured quad (its width and height step), the fade once the quad has reached its limits, then the rings.

var config: Dictionary = {}
var start_scale := Vector3i(4096, 4096, 4096)
var rays: Array = []
var positions: Array = []
var velocities: Array = []
var rings: Array = []
var width := 0
var height := 0
var scale_now := 4096
var colour := PackedInt32Array([0, 0, 0])


func _init() -> void:
	variant_count = 6
	geometry = Vector2i(160, 108)


func _start(phase: int) -> void:
	config = Data.configs()["effect_8"][phase]
	var s: Array = Data.configs()["scale"]["8"]
	start_scale = Vector3i(s[0], s[1], s[2])
	width = int(config["initial_width"])
	height = int(config["initial_height"])
	var radii: Array = config["radii"]
	rings = []
	for i in 3:
		rings.append(ring_xz(radii[i], radii[i], int(config["ring_height"]) * i, 32))
	var range_ := int(config["ray_range"])
	rays = random_upward(range_, range_, range_, int(config["ray_count"]))
	var speed := int(config["particle_speed"])
	velocities = random_upward(speed, speed, speed, int(config["particle_count"]))
	positions = []
	for i in int(config["particle_count"]):
		positions.append(Vector3i.ZERO)
	scale_now = 4096
	var c: Array = config["color"]
	set_rgb(colour, c[0], c[1], c[2])


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var rotation := Vector3i.ZERO
	gte.pose(world, saved, offset, rotation, start_scale, 1)
	if is_lit(colour):
		var lit := colour_of(colour)
		ray_triangles(lit, int(config["ray_width"]), rays, 64)
		for i in positions.size():
			sparkle(lit, shifted(square(4), positions[i]), 1)
			positions[i] = positions[i] + velocities[i]
		layered_sprite(lit, int(config["sprite_size"]), 64, Vector3i.ZERO)
		var lit4 := [Vector3i.ZERO, Vector3i.ZERO, lit, lit]
		gt4(quad_rows(width, width, -height, 0), 11, [Vector2i(0, 0), Vector2i(31, 0), Vector2i(0, 127), Vector2i(31, 127)],
			lit4, 32, 1)
		width = (width - int(config["width_step"])) & 0xFFFF
		if width < int(config["minimum_width"]):
			width = int(config["minimum_width"])
		height = (height + int(config["height_step"])) & 0xFFFF
		if height > int(config["maximum_height"]):
			height = int(config["maximum_height"])
		if height == int(config["maximum_height"]) and width == int(config["minimum_width"]):
			fade_down(colour, 8)
		if int(config["draw_rings"]) != 0:
			var half_lit := half(colour_of(colour))
			gte.pose(world, saved, offset, rotation, Vector3i(scale_now, 4096, scale_now), 3)
			ring_strip(half_lit, rings[0], rings[1], rings[2], 1)
			gte.scaled_saved(saved, Vector3i(scale_now >> 1, 6144, scale_now >> 1))
			ring_strip(colour_of(colour), rings[0], rings[1], rings[2], 1)
			if scale_now < 0x4000:
				scale_now += 0x1000
	gte.pop()
	if is_black(colour):
		done = true
