extends "res://scripts/duel/effects/effect_program.gd"
## Effect 12: the stop of a defence (the Stop Defense card's effect on the defending monster). Sparks spin off the monster's position
## while three rings widen from it, each ring a gradient strip (the second in the colour's shade), and a layered sprite at the
## centre. When the rings have grown to their limit the impact flag is set and the colour fades out. Scene geometry: (160, 108).

var config: Dictionary = {}
var start_scale := Vector3i(4096, 4096, 4096)
var rings: Array = []
var positions: Array = []
var velocities: Array = []
var scale_now := 4096
var colour := PackedInt32Array([0, 0, 0])


func _init() -> void:
	geometry = Vector2i(160, 108)


func _start(_phase: int) -> void:
	config = Data.configs()["effect_12"][0]
	var s: Array = Data.configs()["scale"]["12"]
	start_scale = Vector3i(s[0], s[1], s[2])
	var radii: Array = config["radii"]
	rings = []
	for i in 3:
		rings.append(ring_xz(radii[i], radii[i], int(config["ring_height"]) * i, 32))
	var speed := int(config["particle_speed"])
	positions = []
	for i in 32:
		positions.append(Vector3i.ZERO)
	velocities = random_upward(speed, speed, speed, 32)
	scale_now = 4096
	var c: Array = config["color"]
	set_rgb(colour, c[0], c[1], c[2])


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	gte.pose(world, saved, offset, zero, start_scale, 3)
	if is_lit(colour):
		var lit := colour_of(colour)
		for i in 32:
			sparkle(lit, shifted(square(4), positions[i]), 1)
			positions[i] = positions[i] + velocities[i]
		var halved := half(lit)
		gte.scaled_saved(saved, Vector3i(scale_now, 4096, scale_now))
		ring_strip(halved, rings[0], rings[1], rings[2], 1)
		gte.scaled_saved(saved, Vector3i(scale_now >> 1, 6144, scale_now >> 1))
		ring_strip(lit, rings[0], rings[1], rings[2], 1)
		layered_sprite(halved, int(config["sprite_size"]), 64, zero)
		if scale_now < 0x4000:
			scale_now += 0x1000
		else:
			impact = true
			fade_down(colour, 15)
	gte.pop()
	if is_black(colour):
		done = true
