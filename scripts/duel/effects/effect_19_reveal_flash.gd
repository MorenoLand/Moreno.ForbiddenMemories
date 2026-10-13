extends "res://scripts/duel/effects/effect_program.gd"
## Effect 19: the reveal flash. A ring burst that opens from a point: three rings, a layered sprite, gradient strips, and a rising
## fan of gradient quads, all in a warm colour that brightens to white; then the sparkles leave and the screen flashes and fades.
## It has no variants (its first call is phase 0).

var rings: Array = []
var rotations: Array = []
var positions: Array = []
var velocities: Array = []
var widths: Array = [64, 67, 68]
var scale_now := 4096
var frame := 0
var fade_started := 0
var spawned := 0
var colour := PackedInt32Array([31, 28, 30])


func _start(_phase: int) -> void:
	widths = [64, 67, 68]
	rotations = []
	for i in 64:
		rotations.append(Vector3i(rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095)))
	rings = [ring(widths[0]), ring(widths[1]), ring(widths[2])]
	positions = []
	velocities = []
	for i in 32:
		positions.append(Vector3i.ZERO)
		velocities.append(random_vector(6))
	scale_now = 4096
	frame = 0
	fade_started = 0
	spawned = 0
	set_rgb(colour, 31, 28, 30)


func _update() -> void:
	widths[0] = 1
	widths[1] = 2
	gte.push()
	var saved := Gte.Mat.new()
	var position := Vector3i.ZERO
	var rotation := Vector3i.ZERO
	var scale := Data.start_vector(19)
	gte.pose(world, saved, position, rotation, scale, 1)
	if is_lit(colour):
		if fade_started == 1:
			for i in 32:
				sparkle(colour_of(colour), shifted(square(4), positions[i]), 0)
				positions[i] = positions[i] + velocities[i]
		scale = Vector3i(scale_now, scale_now, 0)
		gte.scaled_saved(saved, scale)
		layered_sprite(colour_of(colour), 12, 0, position)
		scale = Vector3i(scale_now >> 2, scale_now >> 2, 0)
		gte.scaled_saved(saved, scale)
		gradient_strip(colour_of(colour), rings[0], rings[1], rings[2], 0)
		scale = Vector3i(4096, 4096 + (scale_now >> 2), 4096)
		if fade_started == 0:
			for i in spawned:
				gte.pose(world, saved, position, rotations[i], scale, 2)
				gradient_quads(colour_of(colour), widths, 48, 0)
				rotations[i] = rotations[i] + Vector3i(32, 32, 32)
			spawned += 1
			if spawned > 64:
				spawned = 64
		if fade_started == 0:
			fade_started = 1 if fade_up(colour, Vector3i(255, 224, 240), 4) else 0
			if scale_now < 0x5000:
				scale_now += 0x100
			else:
				scale_now = 0x5000
		else:
			impact = true
			screen_flash(colour, 8)
	frame += 1
	gte.pop()
	if is_black(colour):
		done = true
