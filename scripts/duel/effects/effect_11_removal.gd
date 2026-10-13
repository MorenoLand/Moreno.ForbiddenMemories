extends "res://scripts/duel/effects/effect_program.gd"
## Effect 11: the monster removal (the Raigeki-type sweep's card fragments). Twenty-eight fragments (four columns of seven) are set on
## the field where the monster stood: each is a textured quad with a random velocity and spin that flies up, and once it reaches its
## height it chance-bursts into sixteen sprites that fly out and shrink; a glow (a sprite, a growing gradient quad and two rings)
## marks the removal. The packed phase is the variant (its low four bits: the image variant 0 to 4; 5 and up is the debug banner) and
## bit 7 sets the mode of the fragments (the page of the base texture). Scene geometry: (160, 108).
##
## Approximations: the random sequence is the port's own; the spin steps use the arc tangent in turns of 4096 (rounded).

var config: Dictionary = {}
var start_scale := Vector3i(4096, 4096, 4096)
var scale_now := 4096
var positions: Array = []
var velocities: Array = []
var rotations: Array = []
var rotation_steps: Array = []
var particles: Array = []
var sizes: Array = []
var states: Array = []
var frames: Array = []
var chances: Array = []
var modes: Array = []
var colours: Array = []
var particle_colours: Array = []
var rays: Array = []
var dust: Array = []
var dust_velocities: Array = []
var rings: Array = []
var glow := PackedInt32Array([0, 0, 0])
var width := 0
var height := 0
var completed := 0
var tick := 0
var variant := 0
var texture_pair := 24          # pair 24 + the variant (the image's page); pair 24 is also the base texture (variant 0's image)
var origin: Array = [0, 0]      # the variant image's px and py (the overlay's texel bytes for the fragments' coordinates)


func _init() -> void:
	geometry = Vector2i(160, 108)


func _start(phase: int) -> void:
	variant = phase & 15
	if variant >= 5:
		_banner = 1
		return
	config = Data.configs()["effect_11"][0]
	var s: Array = Data.configs()["scale"]["11"]
	start_scale = Vector3i(s[0], s[1], s[2])
	texture_pair = 24 + variant
	origin = Data.configs()["effect_11_origins"][variant]
	var speed := int(config["speed"])
	var lift := int(config["lift"])
	var spread := int(config["spread"])
	var fragment := int(config["fragment_size"])
	var mode := 1 if (phase >> 7) == 1 else 0
	positions = []
	velocities = []
	rotations = []
	rotation_steps = []
	particles = []
	sizes = []
	states = []
	frames = []
	chances = []
	modes = []
	colours = []
	particle_colours = []
	for i in 4:
		for j in 7:
			var p := Vector3i(i * 12 - 18, 0, j * 8 - 24)
			var vx := (speed + (rng.randi_range(0, 2) - 1) * 3) * p.x / 24
			var vy := (rng.randi_range(0, 2) - 1) * 3 - lift
			var vz := (speed + (rng.randi_range(0, 2) - 1) * 3) * p.z / 28
			var v := Vector3i(vx, vy, vz)
			positions.append(p)
			velocities.append(v)
			rotations.append(Vector3i.ZERO)
			rotation_steps.append(Vector3i(_ratan2(v.z, v.y) / 8, _ratan2(v.x, v.z) / 8, _ratan2(v.y, v.x) / 8))
			particles.append(random_scatter(spread, spread, spread, 16))
			positions[positions.size() - 1] = p + offset
			colours.append(PackedInt32Array([128, 128, 128]))
			particle_colours.append(PackedInt32Array([255, 255, 255]))
			states.append(0)
			frames.append(rng.randi_range(0, 3))
			var fragment_sizes: Array = []
			for k in 16:
				fragment_sizes.append(fragment + rng.randi_range(0, maxi(fragment / 2, 1) - 1))
			sizes.append(fragment_sizes)
			chances.append(int(config["chance"]))
			modes.append(mode)
	rays = random_upward(int(config["ray_length"]), int(config["ray_length"]), int(config["ray_length"]), int(config["ray_count"]))
	var dust_speed := int(config["dust_speed"])
	dust = []
	for i in int(config["dust_count"]):
		dust.append(Vector3i.ZERO)
	dust_velocities = random_upward(dust_speed, dust_speed, dust_speed, int(config["dust_count"]))
	width = int(config["width"])
	height = int(config["height"])
	rings = []
	var radii: Array = config["radii"]
	for i in 3:
		rings.append(ring_xz(radii[i], radii[i], int(config["ring_height"]) * i, 32))
	var c: Array = config["color"]
	set_rgb(glow, c[0], c[1], c[2])
	scale_now = 4096
	completed = 0
	tick = 0


func _ratan2(y: int, x: int) -> int:
	return roundi(atan2(float(y), float(x)) * 4096.0 / TAU)


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var scale := start_scale
	gte.pose(world, saved, offset, zero, scale, 2)
	if is_lit(glow):
		var lit := colour_of(glow)
		ray_triangles(lit, int(config["ray_width"]), rays, 64)
		for i in dust.size():
			sparkle(lit, shifted(square(4), dust[i]), 1)
			dust[i] = dust[i] + dust_velocities[i]
		layered_sprite(lit, int(config["glow_size"]), 64, zero)
		gt4(quad_rows(width, width, -height, 0), 11, [Vector2i(0, 0), Vector2i(31, 0), Vector2i(0, 127), Vector2i(31, 127)],
			[Vector3i.ZERO, Vector3i.ZERO, lit, lit], 32, 1)
		width = (width - int(config["shrink"])) & 0xFFFF
		if width < int(config["min_width"]):
			width = int(config["min_width"])
		height = (height + int(config["growth"])) & 0xFFFF
		if height > int(config["max_height"]):
			height = int(config["max_height"])
		if height == int(config["max_height"]) and width == int(config["min_width"]):
			fade_down(glow, 8)
		var halved := half(lit)
		scale = Vector3i(scale_now, 4096, scale_now)
		gte.pose(world, saved, offset, zero, scale, 3)
		ring_strip(halved, rings[0], rings[1], rings[2], 1)
		scale = Vector3i(scale_now >> 1, 6144, scale_now >> 1)
		gte.scaled_saved(saved, scale)
		ring_strip(colour_of(glow), rings[0], rings[1], rings[2], 1)
		if scale_now < 16384:
			scale_now += 4096
	for k in 28:
		if not is_lit(particle_colours[k]):
			continue
		var column := k / 7
		var row := k % 7
		if states[k] == 0:
			# the base texture (pair 24, the first image) in mode 1, else the variant's image; the coordinates are the overlay's bytes
			var pair := 24 if modes[k] == 1 else texture_pair
			var u0 := 56 + column * 12 if modes[k] == 1 else int(origin[0]) + column * 12
			var v0 := 128 + row * 8 if modes[k] == 1 else int(origin[1]) + row * 8
			var uv := [Vector2i(u0 & 0xFF, v0 & 0xFF), Vector2i((u0 + 12) & 0xFF, v0 & 0xFF),
				Vector2i(u0 & 0xFF, (v0 + 8) & 0xFF), Vector2i((u0 + 12) & 0xFF, (v0 + 8) & 0xFF)]
			var quad := plane(6, 0, 4)
			gte.pose(world, saved, positions[k], rotations[k], scale, 2)
			ft4(quad, pair, uv, colour_of(colours[k]), 1, 0)
		var moving: Vector3i = velocities[k]
		if moving.y > 0 and states[k] == 0 and positions[k].y >= -31:
			if chances[k] <= 0 or rng.randi_range(0, chances[k] - 1) == 0:
				states[k] = 1
				set_all(colours[k], 0)
			else:
				chances[k] -= 1
		if states[k] != 0:
			gte.pose(world, saved, positions[k], zero, scale, 0)
			var uv_frame := int(frames[k]) * 32
			var uv := [Vector2i(128 + uv_frame, 64), Vector2i(159 + uv_frame, 64), Vector2i(128 + uv_frame, 127), Vector2i(159 + uv_frame, 127)]
			var rgb := colour_of(particle_colours[k])
			for piece in int(states[k]):
				var size: int = sizes[k][piece]
				var quad := rect(size, size * 2)
				for vertex in quad.size():
					quad[vertex] = quad[vertex] + particles[k][piece]
				ft4(quad, 4, uv, rgb, 1, 1)
				sizes[k][piece] = size - 1
			frames[k] = (int(frames[k]) + 1) % 4
			states[k] = mini(int(states[k]) + 1, 16)
			fade_down(particle_colours[k], 31)
		if states[k] != 0:
			positions[k] = positions[k] + Vector3i(0, -8, 0)
		elif positions[k].y < 16:
			var r: Vector3i = rotations[k]
			var step: Vector3i = rotation_steps[k]
			r = Vector3i((r.x + step.x) % 4096, (r.y + step.y) % 4096, (r.z + step.z) % 4096)
			rotations[k] = r
			var sum := (r.x % 1024) + (r.y % 1024) + (r.z % 1024)
			sum &= 0xFFFF
			if sum % 3 == 0:
				modes[k] = 1 - int(modes[k])
			var p: Vector3i = positions[k]
			if (tick & 1) == 0:
				p.x += velocities[k].x
			p.y += velocities[k].y
			if (tick & 1) == 0:
				p.z += velocities[k].z
			positions[k] = p
			velocities[k] = velocities[k] + Vector3i(0, 3, 0)
			if positions[k].y > 16:
				positions[k] = Vector3i(positions[k].x, 16, positions[k].z)
				states[k] = 1
		if is_black(particle_colours[k]):
			completed += 1
	tick += 1
	gte.pop()
	if completed == 28 and is_black(glow):
		done = true


