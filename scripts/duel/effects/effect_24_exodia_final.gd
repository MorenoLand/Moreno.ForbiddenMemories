extends "res://scripts/duel/effects/effect_program.gd"
## Effect 24: the Exodia result's final flash. The five pieces' centres (the request's `cards`, in picture points) give the centre of
## the scene and the five targets. A glow sits at the centre; five beams spark from the targets to a web that grows across the
## screen (the connections are added in order, the beam widens), a ring of sprites rises from the points, and a fan of rays and
## 64 streaks spins out. Then the screen whitens and the flash ends the request, setting the impact flag on the white-out.
##
## Picture-space program (its origin is the request's offset, moved to the scene's centre each frame, as the overlay does).
## The context gives `cards`: the five card objects' origins (their top-left picture points, as the overlay's field_30 holds them), in the
## order the duel gives them. The beams end at origin + (24, 28), which is the card's centre (its size is 52 x 60).

const CENTRE_PAIR := 18      # pairs[18]: the centre glow's page

var center := Vector3i.ZERO
var half_width := 0
var half_height := 0
var targets: Array = []
var points: Array = []
var point_steps: Array = []
var heads: Array = []
var tails: Array = []
var velocities: Array = []
var rotations: Array = []
var ray_scales: Array = []
var widths: Array = [2, 1]
var scale_now := 4096
var tick := 0
var arrival := 0
var connection_tick := 0
var line_count := 0
var ray_count := 0
var stage := 0
var beam_width := 1
var center_colour := PackedInt32Array([1, 1, 1])
var flash_colour := PackedInt32Array([255, 255, 255])
var line_colour := PackedInt32Array([255, 128, 128])
var scale_vector := Vector3i(4096, 4096, 4096)
var card_points: Array = []


func _start(_phase: int) -> void:
	scale_vector = _scale_of("24")
	card_points = []
	for i in 5:
		var c = context_cards[i] if i < context_cards.size() else Vector2.ZERO
		card_points.append(Vector3i(int(c.x), int(c.y), 0))
	var sx := 0
	var sy := 0
	for p in card_points:
		sx += p.x
		sy += p.y
	center = Vector3i((sx + 120) / 5, (sy + 140) / 5, 0)
	half_width = (card_points[1].x - card_points[4].x) / 2
	half_height = (card_points[2].y - card_points[0].y) / 2
	targets = []
	points = []
	point_steps = []
	for i in 5:
		var target := Vector3i(card_points[i].x - (center.x - 24), card_points[i].y - (center.y - 28), 0)
		targets.append(target)
		points.append(Vector3i.ZERO)
		point_steps.append(Vector3i(target.x / 8, target.y / 8, 0))
	heads = []
	tails = []
	velocities = []
	for i in 64:
		var x := rng.randi_range(-4095, 4095)
		var y := rng.randi_range(-4095, 4095)
		var z := rng.randi_range(-4095, 4095)
		heads.append(Vector3i(x * 96 / 4096, y * 96 / 4096, z * 96 / 4096))
		tails.append(Vector3i(x * 128 / 4096, y * 128 / 4096, z * 128 / 4096))
		velocities.append(-tails[i] / 8)
	rotations = []
	for i in 32:
		rotations.append(Vector3i(rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095)))
	ray_scales = []
	for i in 32:
		ray_scales.append(4096)
	widths = [2, 1]
	scale_now = 4096
	tick = 0
	arrival = 0
	set_all(center_colour, 1)
	set_all(flash_colour, 255)
	set_rgb(line_colour, 255, 128, 128)
	beam_width = 1
	connection_tick = 0
	line_count = 0
	ray_count = 0
	stage = 0


var context_cards: Array = []     # the request's cards: the five picture points of the field's pieces


func setup(picture, context: Dictionary) -> void:
	super.setup(picture, context)
	context_cards = context.get("cards", [])


func _update() -> void:
	offset = center
	gte.push()
	var saved := Gte.Mat.new()
	var position := Vector3i.ZERO
	var rotation := Vector3i.ZERO
	var scale := scale_vector
	gte.pose(world, saved, position, rotation, scale, 0)
	if is_lit(center_colour):
		_glow(colour_of(center_colour))
	if is_lit(line_colour):
		var lit := Vector3i.ZERO
		if (tick & 1) == 0:
			lit = half(colour_of(line_colour))
		else:
			lit = Vector3i(255, 255, 255)
		if arrival == 8:
			if connection_tick > 0:
				_beam(lit, targets[0], targets[2], beam_width * 2)
			if connection_tick > 4:
				_beam(lit, targets[2], targets[4], beam_width)
			if connection_tick > 8:
				_beam(lit, targets[1], targets[4], beam_width)
			if connection_tick > 12:
				_beam(lit, targets[1], targets[3], beam_width)
			if connection_tick > 16:
				_beam(lit, targets[0], targets[3], beam_width * 2)
			connection_tick += 1
			if connection_tick > 24:
				connection_tick = 24
				beam_width += 1
				if beam_width > 8:
					beam_width = 8
					if stage == 0:
						stage = 1
					fade_up(center_colour, Vector3i(255, 255, 255), 1)
		var point_colour := colour_of(line_colour) if (tick & 1) == 0 else Vector3i(255, 255, 255)
		for i in 5:
			layered_sprite(point_colour, 16, 0, points[i])
			if arrival < 8:
				points[i] = points[i] + point_steps[i]
		arrival += 1
		if arrival > 8:
			arrival = 8
	if stage != 0:
		for i in line_count:
			var head := gte.rot_trans_pers(heads[i])
			var tail := gte.rot_trans_pers(tails[i])
			if tail.w == 1:
				canvas.add_line(Vector2(head.x + offset.x, head.y + offset.y), Vector2(tail.x + offset.x, tail.y + offset.y),
					Vector3i(255, 128, 128), Vector3i.ZERO, flags, 1)
			if absi(heads[i].x) > 32 or absi(heads[i].y) > 32 or absi(heads[i].z) > 32:
				heads[i] = heads[i] + velocities[i]
				tails[i] = tails[i] + velocities[i]
			else:
				var x := rng.randi_range(-4095, 4095)
				var y := rng.randi_range(-4095, 4095)
				var z := rng.randi_range(-4095, 4095)
				heads[i] = Vector3i(x * 96 / 4096, y * 96 / 4096, z * 96 / 4096)
				tails[i] = Vector3i(x * 128 / 4096, y * 128 / 4096, z * 128 / 4096)
				velocities[i] = -tails[i] / 8
		var ray_colour := Vector3i(255, 128, 128)  # the line colour, as the centre sprite is drawn
		scale = Vector3i(scale_now, scale_now, scale_now)
		gte.pose(world, saved, position, rotation, scale, 0)
		layered_sprite(ray_colour, 8, 0, position)
		var ray_base := Vector3i(127, 64, 64)
		for i in ray_count:
			scale = Vector3i(4096, int(ray_scales[i]), 4096)
			gte.pose(world, saved, position, rotations[i], scale, 0)
			gradient_quads(ray_base, widths, 32, 0)
			if ray_scales[i] < 0x6000:
				ray_scales[i] += 0x400
			else:
				ray_scales[i] = 4096
				rotations[i] = Vector3i(rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095), rng.randi_range(-4095, 4095))
		if scale_now < 0x6000:
			scale_now += 128
		line_count += 1
		if line_count > 64:
			line_count = 64
		if (tick & 1) == 0:
			ray_count += 1
			if ray_count > 32:
				ray_count = 32
	if line_count == 64 and ray_count == 32 and scale_now >= 0x6000 and is_white(center_colour) and stage < 2:
		stage = 2
	if is_lit(flash_colour) and stage == 0:
		screen_flash(flash_colour, 15)
	if stage == 2:
		_fill(flash_colour)
		if fade_up(flash_colour, Vector3i(192, 192, 192), 4):
			set_all(flash_colour, 255)
			impact = true
			stage = 3
	if is_lit(flash_colour) and stage == 3:
		screen_flash(flash_colour, 0)
	tick += 1
	gte.pop()
	if stage == 3:
		done = true


## The centre glow: the glow sprite's two ends (the page's pair 18, the cells of the glow) at the origin, bias 0.
func _glow(c: Vector3i) -> void:
	var uv := [Vector2i(192, 128), Vector2i(255, 128), Vector2i(192, 255), Vector2i(255, 255)]
	for i in 2:
		var sign_x := -1 if i == 0 else 1
		var verts := [Vector3i(half_width * sign_x, -half_height, 0), Vector3i(0, -half_height, 0),
			Vector3i(half_width * sign_x, half_height, 0), Vector3i(0, half_height, 0)]
		ft4(verts, CENTRE_PAIR, uv, c, 0, 1)


## A beam between two targets (the overlay's beam helper): two untextured quads, one above and one below the line, the colour at
## the middle of each edge and black at the outer edge; added at flags + 1 as the bias-0 helper does.
func _beam(c: Vector3i, first: Vector3i, last: Vector3i, width: int) -> void:
	for i in 2:
		var s := -1 if i == 0 else 1
		var quad := [Vector3i(first.x, first.y + s * width, 0), Vector3i(first.x, first.y, 0),
			Vector3i(last.x, last.y, 0), Vector3i(last.x, last.y + s * width, 0)]
		var p := _projected(quad)
		if p.ok:
			canvas.add_poly(_offset_points(p.xy), [Vector3i.ZERO, c, c, Vector3i.ZERO], [], -1, flags + 1, 1)


## The full-screen fill (the overlay's screen fill helper): an additive screen-size quad at flags, without fading.
func _fill(c: PackedInt32Array) -> void:
	canvas.add_poly([Vector2(0, 0), Vector2(SCREEN_W, 0), Vector2(0, SCREEN_H), Vector2(SCREEN_W, SCREEN_H)],
		[colour_of(c)], [], -1, flags, 1)


static func is_white(c: PackedInt32Array) -> bool:
	return c[0] == 255 and c[1] == 255 and c[2] == 255


static func _scale_of(key: String) -> Vector3i:
	var v: Array = Data.configs()["scale"][key]
	return Vector3i(int(v[0]), int(v[1]), int(v[2]))
