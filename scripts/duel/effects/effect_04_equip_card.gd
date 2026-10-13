extends "res://scripts/duel/effects/effect_program.gd"
## Effect 4: the equip card's presentation. The card's picture shows in its frame on a contour (its colour is the equip colour, its
## card colour fades in from grey), then after the configured duration a gradient disc of three rings, a layered sprite and sixteen
## spinning gradient fans grow out of the card, with sparkles rising, and the screen flashes at the end. The variant (phase 0 or 1)
## is the configuration; phase 2 and past take the debug banner. It is drawn in picture space.

var config: Dictionary = {}
var rings: Array = []
var card_rings: Array = []
var rotations: Array = []
var positions: Array = []
var velocities: Array = []
var stage := 0
var scale_now := 0
var frame := 0
var colour := PackedInt32Array([0, 0, 0])
var card_colour := PackedInt32Array([0, 0, 0])
var screen := PackedInt32Array([0, 0, 0])


func _init() -> void:
	variant_count = 2


func _start(phase: int) -> void:
	config = Data.configs()["effect_4"][phase]
	var radii: Array = config["radii"]
	rings = [ring(radii[0]), ring(radii[1]), ring(radii[2])]
	card_rings = []
	for i in 2:
		card_rings.append(diamond(24 + i * 6, 28 + i * 6, 4))
	rotations = []
	for i in 16:
		rotations.append(Vector3i(rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095)))
	positions = []
	velocities = []
	for i in 24:
		positions.append(Vector3i.ZERO)
		velocities.append(random_vector(int(config["particle_speed"])))
	set_all(colour, 1)
	set_all(card_colour, 1)
	set_all(screen, 0)
	stage = 0
	scale_now = 4096
	frame = 0


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var widths: Array = config["widths"]
	var height: int = config["height"]
	var c: Array = config["color"]
	if is_lit(colour) or is_lit(card_colour):
		gte.pose(world, saved, zero, zero, Vector3i(4096, 4096, 4096), 1)
		contour(colour_of(colour), card_rings[0], card_rings[1], 0, 1)
		var texture: int = config["texture"]
		var u0: int = (texture - 5) * 64
		var uv := [Vector2i(u0, 128), Vector2i(u0 + 63, 128), Vector2i(u0, 255), Vector2i(u0 + 63, 255)]
		var cw: int = config["card_width"]
		var ch: int = config["card_height"]
		var card := [Vector3i(-cw, -ch, 0), Vector3i(cw, -ch, 0), Vector3i(-cw, ch, 0), Vector3i(cw, ch, 0)]
		var grey := colour_of(card_colour) == Vector3i(128, 128, 128)
		ft4(card, texture, uv, colour_of(card_colour), 0, 0 if grey else 1)
		if frame >= int(config["duration"]):
			if stage == 0:
				set_all(card_colour, 0)
				set_all(screen, 255)
				stage = 1
			impact = true
			for i in 24:
				sparkle(colour_of(colour), shifted(square(4), positions[i]), 0)
				positions[i] = positions[i] + velocities[i]
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
			fade_up(colour, Vector3i(c[0], c[1], c[2]), 31)
			fade_up(card_colour, Vector3i(128, 128, 128), 31)
	if is_lit(screen):
		screen_flash(screen, 31)
	frame += 1
	gte.pop()
	if is_black(colour):
		done = true
