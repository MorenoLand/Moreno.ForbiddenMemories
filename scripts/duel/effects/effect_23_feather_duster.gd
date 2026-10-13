extends "res://scripts/duel/effects/effect_program.gd"
## Effect 23: Harpie's Feather Duster. A feather sprite sweeps across the row of the opponent's magic and trap cards, from one end to
## the other, swinging as it goes. Where it passes a card, the card's object is struck: the card then drifts off along the feather's
## slots, spins, dims and is hidden, one card at a time, while the feather's sparkles trail behind. It has no variants; it reads the
## row's card objects through the host's card-object channel (extra.objects, see duel_fx.gd CardObjects).
##
## The request's direction is `forward` (the overlay's offset z >= 0): the feather starts at the left end (x = -204) and moves right,
## otherwise from the right end. The slots' height is the card height (-24); their depth follows the swept row (the port's layout
## puts the magic and trap row at the far z, so the slots take that row's depth rather than a constant).

const FEATHER_PAIR := 19          # pairs[19]: the feather sprite
const SPARK_TEXTURE_PAIR := 20    # pairs[20]: the dust sprites
const FEATHER_UV := [Vector2i(144, 128), Vector2i(191, 128), Vector2i(144, 255), Vector2i(191, 255)]
const NEUTRAL := 128              # a card object's brightness channel at rest (the overlay's 0x80 field_0C byte)

var forward := true
var objects: Array = []           # the swept card records (the row's occupied cards, in zone order)
var velocities: Array = []        # per card: Vector3i
var spins: Array = []             # per card: Vector3i (the field_20 bytes' step: the same value on all three)
var states := PackedInt32Array([0, 0, 0, 0, 0])
var ages := PackedInt32Array([0, 0, 0, 0, 0])
var slots: Array = []             # five Vector3i: where the dust of each slot starts
var particles: Array = []         # [i][j] Vector3i
var particle_velocities: Array = []
var position := Vector3i.ZERO
var rotation := Vector3i.ZERO
var speed := 0
var stage := 0
var swing := 0
var active := 0
var hidden := 0
var colour := PackedInt32Array([0, 0, 0])
var card_count := 0


func _init() -> void:
	geometry = Vector2i(160, 108)   # the scene space (the overlay sets the geometry offset for effect 23)


func _start(_phase: int) -> void:
	forward = bool(extra.get("forward", true))
	var board = extra.get("objects", null)
	objects = board.rows(int(extra.get("side", 0)), "traps").slice(0, 5) if board != null else []   # a row holds five cards
	card_count = objects.size()
	var dir := 1 if forward else -1
	position = Vector3i(-204 if forward else 204, -184, -190 if forward else 190)
	speed = 4 * dir
	rotation = Vector3i(0, 0, -384 if forward else 384)
	states = PackedInt32Array([0, 0, 0, 0, 0])
	var left := -140 if forward else 140
	var row_z := int(extra.get("row_z", -95 if forward else 95))
	velocities = []
	spins = []
	for i in card_count:
		velocities.append(Vector3i(speed / 2, -absi(speed) * rng.randi_range(0, 4095) / 4096,
			absi(speed) * ((rng.randi_range(0, 4095) - rng.randi_range(0, 4095)) % 4096) / 4096))
		var sign := -1 if forward else 1
		# the overlay's three spin steps are each 2 to 6 with the sign; only the first is used (all three bytes take it)
		var sx := (2 + rng.randi_range(0, 4)) * sign
		var sy := (2 + rng.randi_range(0, 4)) * sign
		var sz := (2 + rng.randi_range(0, 4)) * sign
		spins.append(Vector3i(sx, sy, sz))
		var x := int(board.position(objects[i]).x) if board != null else 0
		for k in 5:
			if x == left + 70 * k * dir:
				states[k] = 1
				break
	slots = []
	particles = []
	particle_velocities = []
	for i in 5:
		var slot := Vector3i(left + i * 70 * dir, -24, row_z)
		slots.append(slot)
		var dust: Array = []
		var dust_v: Array = []
		for j in 3:
			dust.append(slot)
			dust_v.append(Vector3i(speed * rng.randi_range(0, 4095) / 4096, -absi(speed) * rng.randi_range(0, 4095) / 4096,
				absi(speed) * ((rng.randi_range(0, 4095) - rng.randi_range(0, 4095)) % 4096) / 4096))
		particles.append(dust)
		particle_velocities.append(dust_v)
	ages = PackedInt32Array([0, 0, 0, 0, 0])
	active = 0
	hidden = 0
	set_all(colour, 1)
	stage = 0
	swing = 0


func _update() -> void:
	var board = extra.get("objects", null)
	gte.push()
	var saved := Gte.Mat.new()
	var rot := Vector3i.ZERO
	var scale := Data.start_vector(23)
	gte.pose(world, saved, position, rotation, scale, 1)
	if is_lit(colour):
		var lit := colour_of(colour)
		var half_x := 48 if speed >= 0 else -48
		var quad := [Vector3i(0, 0, 0), Vector3i(half_x, 0, 0), Vector3i(0, 128, 0), Vector3i(half_x, 128, 0)]
		# the feather is drawn semi-transparent unless its colour is the neutral grey (the overlay's 0x8080 and blue 128 test)
		var neutral := colour[0] == NEUTRAL and colour[1] == NEUTRAL and colour[2] == NEUTRAL
		ft4(quad, FEATHER_PAIR, FEATHER_UV, lit, 32, 0 if neutral else 1)
		if position.y < -104:
			position.y += 3
		else:
			stage = 2
			position.x += speed
			if swing == 0:
				if rotation.x < 320:
					rotation.x += 32
				else:
					swing = 1
			else:
				if rotation.x > -320:
					rotation.x -= 32
				else:
					swing = 0
		if speed > 0:
			if position.x > 210:
				fade_down(colour, 8)
			for i in 5:
				if position.x >= i * 70 - 44 and states[i] == 1:
					active += 1
					states[i] = 2
		elif speed < 0:
			if position.x < -210:
				fade_down(colour, 8)
			for i in 5:
				if position.x <= 236 - i * 70 and states[i] == 1:
					active += 1
					states[i] = 2
		if stage == 0:
			stage = 1 if fade_up(colour, Vector3i(NEUTRAL, NEUTRAL, NEUTRAL), 15) else 0
	if stage >= 2 and board != null:
		for i in active:
			var record = objects[i]
			var at: Vector3i = board.position(record) + velocities[i]
			board.move(record, at)
			var spin: Vector3i = board.spin(record)
			var step: int = spins[i].x
			board.turn(record, Vector3i(posmod(spin.x + step, 256), posmod(spin.y + step, 256), posmod(spin.z + step, 256)))
			var brightness: Vector3i = board.brightness(record)
			brightness = Vector3i(maxi(brightness.x - 15, 0), maxi(brightness.y - 15, 0), maxi(brightness.z - 15, 0))
			board.set_brightness(record, brightness)
			if brightness == Vector3i.ZERO and hidden < active:
				board.set_shown(record, false)
				hidden += 1
	if stage >= 2:
		for i in 5:
			if ages[i] < 24 and states[i] >= 2:
				var age := ages[i]
				var u := (age / 3) % 4 * 32
				var v := (age / 12) * 32 + 192
				var uv := [Vector2i(u, v), Vector2i(u + 31, v), Vector2i(u, v + 31), Vector2i(u + 31, v + 31)]
				ages[i] = age + 1
				for j in 3:
					gte.pose(world, saved, particles[i][j], rot, scale, 1)
					ft4(square(32), SPARK_TEXTURE_PAIR, uv, Vector3i(32, 32, 32), 1, 1)
					particles[i][j] = particles[i][j] + particle_velocities[i][j]
	gte.pop()
	var finished := is_black(colour)
	if card_count != 0 and board != null:
		var last = objects[card_count - 1]
		finished = finished and board.brightness(last) == Vector3i.ZERO
	if finished:
		done = true
