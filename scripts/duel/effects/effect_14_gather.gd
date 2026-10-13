extends "res://scripts/duel/effects/effect_program.gd"
## Effect 14: the level gather of a battle (the attacker's and defender's levels gathered over the battle's clash). Thirty-two sparks
## fly in from the edges of the picture to a point and fade; forty-eight smaller sparks rise and turn to the colour; a contour and a
## gradient ring bow out around the centre while sixteen spinning gradient quads open in the colour, the centre gets its sprite (one
## of the sheet's cells, chosen by the variant), and the colour brightens to a pale blue-white. The variant (phase 0 to 9) picks the
## sprite cell; 10 and up is the debug banner. Picture geometry: the first pose at the origin, no geometry offset.
##
## The sprite sheet is the boot UI image's page 11 with its CLUT (baked as pair 21). The overlay's own done flag (the colour's
## brightening) is `gather_done` here; the program's done is the finish flag.

var config: Dictionary = {}
var start_scale := Vector3i(4096, 4096, 4096)
var particles: Array = []
var velocities: Array = []
var particles_b: Array = []
var velocities_b: Array = []
var curves: Array = []
var rings: Array = []
var rotations: Array = []
var sizes: Array = []
var fragment_flags: Array = []
var colours: Array = []
var colours_b: Array = []
var colour := PackedInt32Array([1, 1, 1])
var sprite_u := 0
var sprite_v := 0
var particle_count := 0
var particle_b_count := 0
var gather_done := 0
var gather_scale := 0x1000
var frame_count := 0


func _init() -> void:
	variant_count = 10


func _start(phase: int) -> void:
	config = Data.configs()["effect_14"][0]
	var s: Array = Data.configs()["scale"]["14"]
	start_scale = Vector3i(s[0], s[1], s[2])
	var spread := int(config["spread"])
	var frames := int(config["frames"])
	var size := int(config["size"])
	particles = random_planar(spread, spread, 32)
	particles_b = random_planar(spread, spread, 48)
	velocities = []
	for p in particles:
		velocities.append(Vector3i(-p.x / frames, -p.y / frames, 0))
	velocities_b = []
	for p in particles_b:
		velocities_b.append(Vector3i(-p.x / frames, -p.y / frames, 0))
	sprite_u = (phase % 8) * 16 + 0x80
	sprite_v = (phase / 8) * 16 + 0x30
	var radii: Array = config["ring_radius"]
	rings = []
	for i in 3:
		rings.append(ring(radii[i]))
	curves = [diamond(0x46, 98, 4), diamond(0x46 + 6, 98 + 6, 4)]
	rotations = random_scatter(4096, 4096, 4096, 16)
	sizes = []
	fragment_flags = []
	colours = []
	for i in 32:
		sizes.append(size)
		fragment_flags.append(0)
		var c := PackedInt32Array([0, 0, 0])
		set_all(c, 1)
		colours.append(c)
	colours_b = []
	for i in 48:
		var c := PackedInt32Array([0, 0, 0])
		set_all(c, 1)
		colours_b.append(c)
	set_all(colour, 1)
	gather_done = 0
	particle_count = 0
	particle_b_count = 0
	gather_scale = 0x1000


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var scale := start_scale
	var frames := int(config["frames"])
	var size := int(config["size"])
	gte.pose(world, saved, zero, zero, scale, 1)
	var uv := [Vector2i(sprite_u, sprite_v), Vector2i(sprite_u + 15, sprite_v), Vector2i(sprite_u, sprite_v + 15),
		Vector2i(sprite_u + 15, sprite_v + 15)]
	particle_count = mini(particle_count + 2, 32) if particle_count + 2 < 0x21 else 0x20
	particle_b_count = mini(particle_b_count + 3, 48) if particle_b_count + 3 < 0x31 else 0x30
	for i in particle_count:
		if not is_lit(colours[i]):
			continue
		var quad := shifted(square(sizes[i]), particles[i])
		ft4(quad, 21, uv, colour_of(colours[i]), 0, 1)
		var moving: Vector3i = particles[i]
		if absi(moving.x) >= 17 or absi(moving.y) >= 17:
			particles[i] = particles[i] + velocities[i]
		elif i == 31:
			gather_done = 2
		sizes[i] = (int(sizes[i]) - (size * 3 / 4 / frames)) & 0xFFFF
		if fragment_flags[i] == 0:
			fragment_flags[i] = 1 if fade_up(colours[i], Vector3i(255, 255, 255), 0x2F) else 0
		else:
			fade_down(colours[i], 15)
	for i in particle_b_count:
		if not is_lit(colours_b[i]):
			continue
		var quad := shifted(square(4), particles_b[i])
		sparkle(colour_of(colours_b[i]), quad, 0)
		var moving: Vector3i = particles_b[i]
		if absi(moving.x) >= 17 or absi(moving.y) >= 17:
			particles_b[i] = particles_b[i] + velocities_b[i]
			fade_up(colours_b[i], Vector3i(0xB0, 0xB0, 0xFF), 15)
		else:
			fade_down(colours_b[i], 15)
	if is_lit(colour):
		var lit := colour_of(colour)
		contour(lit, curves[0], curves[1], 0, 1)
		scale = Vector3i(gather_scale >> 3, gather_scale >> 3, 0x1000)
		gte.scaled_saved(saved, scale)
		gradient_strip(lit, rings[0], rings[1], rings[2], 0)
		scale = Vector3i(gather_scale, gather_scale, 0x1000)
		gte.scaled_saved(saved, scale)
		layered_sprite(lit, int(config["curve_size"]), 0, zero)
		scale = Vector3i(0x1000, gather_scale, 0x1000)
		var widths: Array = config["widths"]
		for i in 16:
			gte.pose(world, saved, zero, rotations[i], scale, 2)
			gradient_quads(lit, widths, int(config["height"]), 0)
			rotations[i] = rotations[i] + Vector3i(0x80, 0x80, 0x80)
		if gather_scale < 0x7000:
			gather_scale += 0x800
		if gather_done == 0:
			gather_done = 1 if fade_up(colour, Vector3i(0xB0, 0xB0, 0xFF), 15) else 0
		elif gather_done == 2:
			fade_down(colour, 15)
	gte.pop()
	if is_black(colours[31]) and is_black(colour):
		done = true
