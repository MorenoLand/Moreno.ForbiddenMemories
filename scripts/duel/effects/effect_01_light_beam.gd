extends "res://scripts/duel/effects/effect_program.gd"
## Effect 1: the card placement's light beam. A halo that spins and brightens while it grows, then a beam (a layered sprite and
## spinning gradient fans that grow), which turns into a field of sparkles that rise and fade, and a full-screen flash at the end.
## The variant (phase 0 or 1) is the configuration; phase 2 and past take the debug banner. It is drawn in picture space.

var config: Dictionary = {}
var rotations: Array = []
var positions: Array = []
var velocities: Array = []
var rotation_step := 0
var stage := 0
var growth := 0
var frame := 0
var tick := 0
var base := PackedInt32Array([0, 0, 0])
var beam := PackedInt32Array([0, 0, 0])
var screen := PackedInt32Array([0, 0, 0])


func _init() -> void:
	variant_count = 2


func _start(phase: int) -> void:
	config = Data.configs()["effect_1"][phase]
	rotations = []
	for i in 12:
		rotations.append(Vector3i(rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095)))
	positions = []
	velocities = []
	for i in 64:
		positions.append(Vector3i.ZERO)
		velocities.append(random_vector(int(config["particle_speed"])))
	set_all(base, 1)
	set_all(beam, 0)
	set_all(screen, 0)
	rotation_step = int(config["initial_rotation_step"])
	frame = 0
	tick = 0
	stage = 0
	growth = 0


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var widths: Array = config["widths"]
	var height: int = config["height"]
	var c: Array = config["color"]
	if is_lit(base):
		var s := 4096 + (growth >> 4)
		var spin := Vector3i(0, 0, (rotation_step * tick) & 0xFFF)
		gte.pose(world, saved, zero, spin, Vector3i(s, s, 4096), 0)
		halo(colour_of(base))
		var first_end: int = config["first_end"]
		var second_end: int = config["second_end"]
		if frame < first_end:
			fade_up(base, Vector3i(128, 128, 128), 8)
			rotation_step = (rotation_step + int(config["rotation_acceleration"])) & 0xFFFF
		elif frame < second_end:
			fade_up(beam, Vector3i(c[0], c[1], c[2]), 15)
			if growth < 0x7000:
				growth += 0x400
		else:
			if stage == 0:
				stage = 1
				set_all(screen, 255)
				rotation_step = int(config["initial_rotation_step"])
			fade_down(base, 15)
	if is_lit(beam):
		var s := 4096 + (growth >> 2)
		var spin := Vector3i(0, 0, (int(config["beam_rotation_step"]) * tick) & 0xFFF)
		gte.pose(world, saved, zero, spin, Vector3i(s, s, 4096), 0)
		layered_sprite(quarter(colour_of(beam)), int(config["sprite_size"]), 0, zero)
		if stage == 0:
			var stretch := Vector3i(4096, 4096 + (growth >> 3), 4096)
			var step := int(config["beam_rotation_step"])
			for i in 12:
				gte.pose(world, saved, zero, rotations[i], stretch, 2)
				gradient_quads(colour_of(beam), widths, height, 0)
				rotations[i] = rotations[i] + Vector3i(step, step, step)
		else:
			var spin2 := Vector3i(0, 0, (rotation_step * (tick << 1)) & 0xFFF)
			gte.pose(world, saved, zero, spin2, Vector3i(4096, 4096, 4096), 0)
			for i in 64:
				sparkle(colour_of(beam), shifted(square(4), positions[i]), 0)
				positions[i] = positions[i] + velocities[i]
		if stage != 0:
			fade_down(beam, 8)
	if is_lit(screen):
		screen_flash(screen, 15)
		impact = true
	frame += 1
	tick += 1
	gte.pop()
	if is_black(base) and is_black(beam) and is_black(screen):
		done = true
