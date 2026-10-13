extends "res://scripts/duel/effects/effect_program.gd"
## Effect 21: the Swords of Revealing Light's field effect. Two slots (one per parity of the request's phase) each hold ten
## positions on the field and ten falling tiles; a slot's tiles fall from above (phase below 2: they start 160 units up) or rise
## from the field (phase 2 and up: at the field), each tile cycling through three frames, until the slot is switched off.
##
## The request's phase is written back by the program through sticky_phase, as the overlay writes its status field: a set-up call
## leaves it as ~parity (-1 for slot 0, -2 for slot 1), so the frame steps run that slot; a call on a lit slot switches it off and
## leaves it as the call's own phase (the next call then sets the slot up again). The slots live across requests (static), as the
## overlay's two work areas do; a slot ends a request when it is switched off.
##
## Approximations: the tile frames of slots' unused entries start at zero (the overlay leaves them as they were), and the game's
## frame step is taken as 1.

const TILE_PAIR := 8         # pairs[8]: the tile page (the textured quads' tile cells, page_at_20)

static var slots: Array = []

var slot_index := 0
var scale_vector := Vector3i(4096, 4096, 4096)


func _init() -> void:
	geometry = Vector2i(160, 108)
	if slots.is_empty():
		slots = [_new_slot(), _new_slot()]


static func _new_slot() -> Dictionary:
	var positions: Array = []
	for i in 10:
		positions.append(Vector3i.ZERO)
	return {"positions": positions, "tiles": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "count": 0,
		"color": PackedInt32Array([0, 0, 0]), "enabled": 0, "offsets": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]}


func _start(phase: int) -> void:
	scale_vector = _scale_of("21")
	slot_index = absi(phase) % 2
	var slot: Dictionary = slots[slot_index]
	if slot["enabled"] != 0:
		set_all(slot["color"], 0)
		slot["enabled"] = 0
		sticky_phase = phase
		return
	var table: Array = Data.configs()["effect_21"]
	for i in 10:
		var p: Array = table[i][phase % 2]
		slot["positions"][i] = Vector3i(int(p[0]), int(p[1]), int(p[2]))
	for i in 8:
		var a := rng.randi_range(0, 9)
		var b := rng.randi_range(0, 9)
		var first: Vector3i = slot["positions"][a]
		slot["positions"][a] = slot["positions"][b]
		slot["positions"][b] = first
	set_all(slot["color"], 128)
	slot["tiles"][8] = rng.randi_range(0, 2)
	slot["enabled"] = 1
	if phase < 2:
		slot["count"] = 0
		for i in 10:
			slot["offsets"][i] = 160
	else:
		slot["count"] = 10
		for i in 10:
			slot["offsets"][i] = 0
	sticky_phase = ~slot_index


func _update() -> void:
	var idx := absi(frame_phase + 1) % 2
	var slot: Dictionary = slots[idx]
	gte.push()
	var saved := Gte.Mat.new()
	gte.pose(world, saved, Vector3i.ZERO, Vector3i.ZERO, scale_vector, 2)
	var colour: PackedInt32Array = slot["color"]
	for i in slot["count"]:
		var position: Vector3i = slot["positions"][i] + Vector3i(0, -int(slot["offsets"][i]), 0)
		_tile_quad(colour_of(colour), position, 30, 80, int(slot["tiles"][i]))
		slot["tiles"][i] = (int(slot["tiles"][i]) + 1) % 3
		if slot["offsets"][i] != 0:
			slot["offsets"][i] -= 16
		else:
			impact = true
			slot["offsets"][i] = 0
	slot["count"] = mini(int(slot["count"]) + 1, 10)
	if absi(frame_phase) > 2:
		fade_down(colour, 4)
	gte.pop()
	if is_black(colour) or int(slot["enabled"]) == 0:
		slot["enabled"] = 0
		set_all(colour, 0)
		done = true


## The field effect ends with its lock: the slot is switched off and the request finishes (the overlay's disabling of the slot).
func release() -> void:
	var slot: Dictionary = slots[slot_index]
	slot["enabled"] = 0
	set_all(slot["color"], 0)
	done = true


## The tile quad (the overlay's tile helper): a textured quad of the tile's cell, its points at the offset, additive.
func _tile_quad(rgb: Vector3i, offset: Vector3i, width: int, height: int, tile: int) -> void:
	var uv := [Vector2i(128 + tile * 32, 192), Vector2i(159 + tile * 32, 192),
		Vector2i(128 + tile * 32, 255), Vector2i(159 + tile * 32, 255)]
	var verts := shifted([Vector3i(-width, -height, 0), Vector3i(width, -height, 0), Vector3i(-width, 0, 0), Vector3i(width, 0, 0)], offset)
	ft4(verts, TILE_PAIR, uv, rgb, 1, 1)


static func _scale_of(key: String) -> Vector3i:
	var v: Array = Data.configs()["scale"][key]
	return Vector3i(int(v[0]), int(v[1]), int(v[2]))
