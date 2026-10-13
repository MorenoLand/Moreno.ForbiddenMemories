extends RefCounted
## The credits' wireframe monsters: the two model slots the credits run behind the staff roll, drawn as the polygon outlines of
## their models (the outline drawing of the battle's poly mode: one 1-pixel line per polygon edge, the colour of the slot, additive).
##
## The rules are those of the credits' model routines: the controller (the state machine of the credits presentation: a row every 30
## ticks while no row plays, the row's own clock, the crossfade to the other monster at the end of the cycle), the colour (the target
## colour walks toward random targets 8..31 per channel, the crossfade fades the outgoing monster to 0), the camera (a move to a
## monster's centre, then the look-at point follows the monster, the eye orbits it: the orbit's yaw steps 8 a frame, and the radius
## and the pitch are held in the bands the camera's controllers set from the monster's size and the look-at height). The monster
## models and their animation are in monster_anim.gd, baked into credits/monsters.bin by tools/extract.py.
##
## The randomness is Godot's (the original's rand() sequence is not reproduced): which monster a slot takes and the colour walk.
## A slot loads over LOAD_FRAMES frames, the loads one after the other, as the original's loader does.

const MonsterAnim := preload("res://scripts/menu/monster_anim.gd")

const DATA := "res://assets/screens/credits/monsters.bin"
const MAGIC := 0x32534E4D
const CARD_COUNT := 722
const GAPS := [[0x12C, 0x15E], [0x28A, 0x2BC]]
const GAP_SINGLE := 0x2D0
const ID_END := 0x2D2
const CENTRE := Vector2(160, 120)
const PROJECTION := 300.0
const LOAD_FRAMES := 36             # a slot's load (the loader's phases), frames
const FIRST_LOAD_AT := 4            # the first load starts this many frames into the presentation
const MOVE_START_TICKS := 30        # the camera's move to a slot that has just loaded (the slot being the active one)
const MOVE_DEFAULT_TICKS := 90      # the camera's move to the other monster at the end of a cycle
const FOLLOW_STEP := 30             # the look-at point follows the monster by at most this much per axis per frame
const CAMERA_MIN_HEIGHT := -100     # the look-at point's height never goes above this
const ANGLE_FULL := 4096
const START_RADIUS := 1200
const START_YAW := 0xC80
const START_PITCH := -85
const YAW_STEP := 8                 # the orbit's yaw step while following (the camera's field_04)
const DEFAULT_TARGET := Vector3(0, -350, 0)

enum Phase { IDLE, CROSSFADE, FADE, DONE }

var index := {}                     # model id -> {offset, length, raw}
var file := PackedByteArray()
var slots: Array = []               # per slot: {mon, loaded, loading, ready_at, dc, model, yaw, bounds}
var active := 0
var phase := Phase.IDLE
var running := false
var frame := 0
var load_free_at := 0
var mode := 0                       # the camera's mode: 0 static, 1 following
var vr := Vector3(0, -350, 0)       # the look-at point
var eye := Vector3()
var radius := START_RADIUS          # the camera's orbit: radius, yaw and pitch (angles in 4096ths of a turn)
var yaw := START_YAW
var pitch := ANGLE_FULL + START_PITCH
var move := {"active": false, "start": Vector3(), "end": Vector3(), "elapsed": 0, "duration": 0}
var target_slot := -1
var lines := {}                     # slot -> {points: PackedVector2Array, colour: Color}
# Test hook: the model ids the next loads take, in order (empty: random). The comparison harness sets it from a reference run.
var forced_models: Array = []
# Test hook: the camera (eye, look-at) per frame, taken from a reference log; empty: the camera runs.
var camera_track: Array = []
# Test hook: the projection (the picture distance) and the picture centre the outlines are projected with.
var projection := PROJECTION
var centre := CENTRE


func _init() -> void:
	eye = vr + _orbit(vr, radius, yaw, pitch)
	slots = [_empty_slot(), _empty_slot()]


static func _empty_slot() -> Dictionary:
	return {"mon": null, "loaded": false, "loading": false, "ready_at": 0, "dc": PackedInt32Array([0, 0, 0, 2, 0, 0, 0, 5]),
		"model": -1, "yaw": 0, "bounds": PackedInt32Array([0, 0, 0, 0]), "move_on_load": false}


## Reads the index. False when the monster file is missing (the roll then runs without monsters).
func load_all() -> bool:
	if not FileAccess.file_exists(DATA):
		return false
	file = FileAccess.get_file_as_bytes(DATA)
	if file.size() < 8 or file.decode_u32(0) != MAGIC:
		return false
	var count := file.decode_u32(4)
	for i in count:
		var at := 8 + i * 14
		index[file.decode_u16(at)] = {"offset": file.decode_u32(at + 2), "length": file.decode_u32(at + 6), "raw": file.decode_u32(at + 10)}
	return not index.is_empty()


## Starts the presentation: the first slot begins its load, the other follows it.
func start() -> void:
	running = true
	phase = Phase.IDLE
	active = 0
	frame = 0
	mode = 0
	target_slot = -1
	vr = DEFAULT_TARGET
	radius = START_RADIUS
	yaw = START_YAW
	pitch = ANGLE_FULL + START_PITCH
	eye = vr + _orbit(vr, radius, yaw, pitch)
	move["active"] = false
	# the presentation's start (state -1): both slots' tint targets are set to 0 with mode 2, so they start black and drift
	for i in 2:
		slots[i] = _empty_slot()
	load_free_at = FIRST_LOAD_AT
	_begin_load(0)
	_begin_load(1)


## The credits ended: both monsters fade to black, then stop.
func fade() -> void:
	if phase != Phase.DONE:
		phase = Phase.FADE


func _random_model() -> int:
	while true:
		var v := (randi() >> 8) % CARD_COUNT
		if v >= GAPS[0][0] and v < GAPS[0][1]:
			continue
		if v >= GAPS[1][0] and v < GAPS[1][1]:
			continue
		if v == GAP_SINGLE or v >= ID_END:
			continue
		if index.has(v):
			return v
	return -1


## Starts a slot's load: the model is chosen and its record built now; the slot is loaded LOAD_FRAMES later (after the load before it).
func _begin_load(i: int) -> void:
	if slots[i]["loaded"] or slots[i]["loading"]:
		return
	var v := _random_model()
	if not forced_models.is_empty():
		v = int(forced_models.pop_front())
	if v < 0 or not index.has(v):
		return
	var entry: Dictionary = index[v]
	var packed := file.slice(entry["offset"], entry["offset"] + entry["length"])
	var blob := packed.decompress(entry["raw"], FileAccess.COMPRESSION_DEFLATE)
	var mon = MonsterAnim.from_blob(blob)
	mon.init_slot()
	var dc: PackedInt32Array = slots[i]["dc"]
	dc[4] = 0                       # the load: the fade-in words are cleared and the fade flag set
	dc[5] = 0
	dc[6] = 0
	dc[7] = 5
	var begin := maxi(frame, load_free_at)
	load_free_at = begin + LOAD_FRAMES
	slots[i] = {"mon": mon, "loaded": false, "loading": true, "ready_at": load_free_at, "dc": dc, "model": v,
		"yaw": 0, "bounds": PackedInt32Array([0, 0, 0, 0]), "move_on_load": i == active}


## The slot's load completes: its root takes the yaw of the presentation (0x400 for the first slot, the other's + 0x400 for the second).
func _finish_load(i: int) -> void:
	var mon = slots[i]["mon"]
	var other := 1 - i
	var slot_yaw := 0x400 if i == 0 else 0x800
	if slots[other]["loaded"]:
		slot_yaw = (int(slots[other]["yaw"]) + 0x400) & 0xFFF
	if mon.root >= 0:
		mon.coord_rot[mon.root] = PackedInt32Array([0, slot_yaw, 0])
		mon.coord_m[mon.root] = MonsterAnim.rot_matrix_yxz(0, slot_yaw, 0)
		mon.coord_t[mon.root] = PackedInt32Array([0, 0, 0])
	slots[i]["loaded"] = true
	slots[i]["loading"] = false
	slots[i]["yaw"] = slot_yaw
	if slots[i]["move_on_load"]:
		_move_to(i, MOVE_START_TICKS)   # the camera moves to the active slot once it has loaded (the else branch of the controller)


# ---- the camera ---------------------------------------------------------------------------------------------------------

static func _orbit(centre: Vector3, orbit_radius: int, yaw_angle: int, pitch_angle: int) -> Vector3:
	var c := MonsterAnim._rcos(pitch_angle)
	var sn := MonsterAnim._rsin(pitch_angle)
	var u := orbit_radius * c / 4096
	var w := orbit_radius * sn / 4096
	c = MonsterAnim._rcos(yaw_angle)
	sn = MonsterAnim._rsin(yaw_angle)
	var z := u * sn / 4096
	u = u * c / 4096
	return Vector3(u, w, z)


## The camera's angle from a vector, in 4096ths of a turn (the ratan2 of the library).
static func _angle(y: int, x: int) -> int:
	return posmod(roundi(atan2(float(y), float(x)) * ANGLE_FULL / TAU), ANGLE_FULL)


static func _isqrt(v: int) -> int:
	return int(floor(sqrt(float(v))))


## the original routine: turns the orbit by (dyaw, dpitch) and moves the radius by dr (not below 11), then places the eye on the orbit.
func _orbit_call(dyaw: int, dpitch: int, dr: int) -> void:
	if (dyaw & 0xFFF) != 0:
		yaw = posmod(yaw + dyaw, ANGLE_FULL)
	if (dpitch & 0xFFF) != 0:
		pitch = posmod(pitch + dpitch, ANGLE_FULL)
	if radius + dr >= 11:
		radius += dr
	if dyaw != 0 or dpitch != 0 or dr != 0:
		eye = vr + _orbit(vr, radius, yaw, pitch)


## Model_UpdateViewMetrics: the radius, yaw and pitch of the orbit from the eye and the look-at point.
func _update_metrics() -> void:
	var dx := int(eye.x - vr.x)
	var dy := int(eye.y - vr.y)
	var dz := int(eye.z - vr.z)
	var horizontal := _isqrt(dx * dx + dz * dz)
	yaw = _angle(dz, dx)
	pitch = _angle(dy, horizontal)
	radius = _isqrt(dx * dx + dy * dy + dz * dz)


## The radius band of the orbit: the lower limit follows the size of the first slot's bounds (the effect adjustment of
## the original routine), the upper is fixed. Returns [lo, hi].
func _radius_band() -> Array:
	var b: PackedInt32Array = slots[0]["bounds"]
	var largest := 0
	if b[0] > 0:
		largest = b[0]
	if largest < b[1]:
		largest = b[1]
	if largest < b[2]:
		largest = b[2]
	if largest < 50:
		largest = 50
	var delta := largest - 300
	var lo := 700
	var hi := 1000
	if delta != 0:
		var half := 700
		if delta > 0:
			half = 350
		lo = 700 + (delta * half) / 750
	if lo >= hi:
		hi = 1000 + ((delta * (500 if delta > 0 else 1000)) / 750)
	return [lo, hi]


## the original routine: the pitch is held in a band set by the look-at height.
func _pitch_control() -> void:
	var c := pitch
	if c >= 0x801:
		var x := int(vr.y)
		var f := 0
		if x >= -199 and int(eye.y) < x:
			if x < -100:
				f = (-200 - x) * 4096 / -100
			else:
				f = 4096
		var v := (f * 3755 + (4096 - f) * 3968) / 4096
		var lo := v - 16
		var d := v + 16
		if d < c:
			d = d - c
			if d < -1:
				d = -1
			_orbit_call(0, d, 0)
		elif c < 0xEAB:
			_orbit_call(0, 0xEAB - c, 0)
		elif c < lo:
			d = lo - c
			if d >= 5:
				d = 4
			_orbit_call(0, d, 0)
	else:
		_orbit_call(0, -4, 0)


## the original routine: the radius is held in the band (toward it by at most 5 to 10 a frame).
func _radius_control() -> void:
	_pitch_control()
	var band := _radius_band()
	var lo: int = band[0]
	var hi: int = band[1]
	var t := radius
	if t < 0x12C:
		if t < 0x96:
			_orbit_call(0, 0, 0x96 - t)
		else:
			var d := 0x12C - t
			if d >= 0xB:
				d = 0xA
			_orbit_call(0, 0, d)
	elif t < lo:
		var d2 := lo - t
		if d2 >= 6:
			d2 = 5
		_orbit_call(0, 0, d2)
	var jump_last := false
	if hi < radius:
		jump_last = true
	elif lo < radius:
		var d3 := lo - radius
		if d3 < -10:
			d3 = -10
		_orbit_call(0, 0, d3)
	if jump_last or hi < radius:
		var d4 := hi - radius
		if d4 < -20:
			d4 = -20
		_orbit_call(0, 0, d4)
	_pitch_control()


## The look-at point of a slot: the centre of its units (the average of their world translations, with the slot's offsets).
func _slot_centre(i: int) -> Vector3:
	var mon = slots[i]["mon"]
	var world: Array = mon.world()
	var sx := 0
	var sy := 0
	var sz := 0
	var count := 0
	for u in mon.units.size():
		var unit: Dictionary = mon.units[u]
		var c: int = unit["coord"]
		if c < 0 or (unit["blocks"] as Array).is_empty():
			continue
		var t: Vector3 = world[c][1]
		sx += int(t.x)
		sy += int(t.y)
		sz += int(t.z)
		count += 1
	var x: int
	var y: int
	var z: int
	if count != 0:
		x = sx / count
		y = sy / count
		z = sz / count
	else:
		var rt: Vector3 = world[mon.root][1] if mon.root >= 0 else Vector3()
		x = int(rt.x)
		y = int(rt.y)
		z = int(rt.z)
	var off: PackedInt32Array = mon.cf8
	var ox := off[0] * 16
	var oz := off[2] * 16
	if i > 0:
		x -= ox
		z -= oz
	else:
		x += ox
		z += oz
	y += off[1] * 16
	return Vector3(x, y, z)


## The slot's bounds (the original routinebounding volume: the extents of its units' world translations, held to a target that
## grows by 50 and moves by at most 20 a frame): [w, h, d, largest].
func _update_bounds(i: int) -> void:
	var mon = slots[i]["mon"]
	var world: Array = mon.world()
	var minx := 0x7FFF
	var miny := 0x7FFF
	var minz := 0x7FFF
	var maxx := -0x8000
	var maxy := -0x8000
	var maxz := -0x8000
	for u in mon.units.size():
		var unit: Dictionary = mon.units[u]
		var c: int = unit["coord"]
		if c < 0 or (unit["blocks"] as Array).is_empty():
			continue
		var t: Vector3 = world[c][1]
		minx = mini(minx, int(t.x))
		maxx = maxi(maxx, int(t.x))
		miny = mini(miny, int(t.y))
		maxy = maxi(maxy, int(t.y))
		minz = mini(minz, int(t.z))
		maxz = maxi(maxz, int(t.z))
	var b: PackedInt32Array = slots[i]["bounds"]
	var w := maxx - minx
	var h := maxy - miny
	var d := maxz - minz
	if b[3] < w:
		b[3] = w
	if b[3] < d:
		b[3] = d
	var targets := [w + 0x32, h + 0x32, d + 0x32]
	for k in 3:
		var target: int = targets[k]
		var v := b[k]
		if v != 0:
			if target < v:
				b[k] = v - mini(v - target, 0x14)
			else:
				b[k] = v + mini(target - v, 0x14)
		else:
			b[k] = target
	slots[i]["bounds"] = b


func _move_to(i: int, ticks: int) -> void:
	move["active"] = true
	move["start"] = vr
	move["end"] = _slot_centre(i)
	move["elapsed"] = 0
	move["duration"] = ticks * 2
	target_slot = i
	mode = 1


## One VBlank of the camera (the camera update of the model: the move, or the follow with the orbit; then the radius and pitch bands).
func _camera_step() -> void:
	if move["active"]:
		var duration: int = move["duration"]
		var elapsed: int = move["elapsed"]
		var rate := 1
		if elapsed < duration / 5 or elapsed > 4 * duration / 5:
			rate = 2
		elapsed = mini(elapsed + rate, duration)
		move["elapsed"] = elapsed
		var s: Vector3 = move["start"]
		var e: Vector3 = move["end"]
		var v := Vector3()
		for k in 3:
			v[k] = float(int((e[k] - s[k]) * elapsed / duration) + int(s[k]))
		if v.y >= CAMERA_MIN_HEIGHT:
			v.y = CAMERA_MIN_HEIGHT
		vr = v
		_update_metrics()
		_radius_control()
		if elapsed >= duration:
			move["active"] = false
		return
	if mode == 0:
		return
	if target_slot >= 0:
		var goal := _slot_centre(target_slot)
		var v := vr
		for k in 3:
			var d := int(goal[k] - v[k])
			var step := clampi(d, -FOLLOW_STEP, FOLLOW_STEP)
			v[k] = float(int(v[k]) + step)
		if v.y >= CAMERA_MIN_HEIGHT:
			v.y = CAMERA_MIN_HEIGHT
		vr = v
	_orbit_call(YAW_STEP, 0, 0)
	_radius_control()


# ---- one VBlank of the presentation ----------------------------------------------------------------------------------

func step() -> void:
	if not running:
		return
	frame += 1
	lines.clear()
	for i in 2:
		if slots[i]["loading"] and frame >= slots[i]["ready_at"]:
			_finish_load(i)
	match phase:
		Phase.IDLE:
			_state_idle()
		Phase.CROSSFADE:
			_state_crossfade()
		Phase.FADE:
			_state_fade()
	for i in 2:
		if slots[i]["loaded"]:
			_update_bounds(i)
			_draw_slot(i)
	for i in 2:
		if slots[i]["loaded"]:
			slots[i]["mon"].row_clock()
	_camera_step()
	if frame < camera_track.size():
		eye = camera_track[frame][0]
		vr = camera_track[frame][1]


func _state_idle() -> void:
	var a := active
	if not slots[a]["loaded"]:
		_begin_load(a)
		return
	var mon = slots[a]["mon"]
	var dc: PackedInt32Array = slots[a]["dc"]
	if (mon.E15 & 3) == 0:
		for c in 3:
			var target := randi() % 24 + 8
			if dc[c] != target:
				dc[c] += 1 if dc[c] < target else -1
	if not slots[1 - a]["loaded"]:
		_begin_load(1 - a)
	var k: int = mon.tick()
	if k == MonsterAnim.KIND_DEFAULT:
		if slots[1 - a]["loaded"]:
			_move_to(1 - a, MOVE_DEFAULT_TICKS)
			phase = Phase.CROSSFADE
	# the rows the controller selected are played by the draw and the row clock


func _state_crossfade() -> void:
	var a := active
	var b := 1 - a
	var mon_a = slots[a]["mon"]
	var out_dc: PackedInt32Array = slots[a]["dc"]
	var in_dc: PackedInt32Array = slots[b]["dc"]
	if (mon_a.E15 & 3) == 0:
		for c in 3:
			if out_dc[c] != 0:
				out_dc[c] -= 1
			if in_dc[c] < 8:
				in_dc[c] += 1
		if out_dc[0] == 0 and out_dc[1] == 0 and out_dc[2] == 0:
			slots[a]["loaded"] = false
			phase = Phase.IDLE
			active = b
	var current = slots[active]["mon"]
	current.E15 = (current.E15 + 1) & 0xFF


func _state_fade() -> void:
	var done := true
	for i in 2:
		if not slots[i]["loaded"]:
			continue
		var mon = slots[i]["mon"]
		if (mon.E15 & 3) == 0:
			var dc: PackedInt32Array = slots[i]["dc"]
			for c in 3:
				if dc[c] != 0:
					dc[c] -= 1
		mon.E15 = (mon.E15 + 1) & 0xFF
		var dc2: PackedInt32Array = slots[i]["dc"]
		if dc2[0] != 0 or dc2[1] != 0 or dc2[2] != 0:
			done = false
	if done:
		for i in 2:
			slots[i]["loaded"] = false
		phase = Phase.DONE
		running = false


## The colour a slot's outline is drawn in this draw (the fade in while DC0[7] counts, then the target colour).
func _slot_colour(i: int) -> Color:
	var dc: PackedInt32Array = slots[i]["dc"]
	if (dc[7] % 6) != 0 and dc[3] == 0:
		var colour := Color(dc[4] / 255.0, dc[5] / 255.0, dc[6] / 255.0, 1.0)
		var step := 2
		dc[4] = mini(dc[0], dc[4] + step)
		dc[5] = mini(dc[1], dc[5] + step)
		dc[6] = mini(dc[2], dc[6] + step)
		if dc[4] >= dc[0] and dc[5] >= dc[1] and dc[6] >= dc[2]:
			dc[7] = 0
		return colour
	return Color(dc[0] / 255.0, dc[1] / 255.0, dc[2] / 255.0, 1.0)


static func _view_rotation(from: Vector3, to: Vector3) -> Array:
	var dx := to.x - from.x
	var dy := to.y - from.y
	var dz := to.z - from.z
	var dist := sqrt(dx * dx + dy * dy + dz * dz)
	var sine := -(from.y - to.y) / dist
	var ground := sqrt(dx * dx + dz * dz)
	var cosine := ground / dist
	var rx := [[1.0, 0.0, 0.0], [0.0, cosine, -sine], [0.0, sine, cosine]]
	var r := rx
	if ground > 0.0:
		var s2 := dx / ground
		var c2 := dz / ground
		var ry := [[c2, 0.0, -s2], [0.0, 1.0, 0.0], [s2, 0.0, c2]]
		r = _mul(rx, ry)
	return r


static func _mul(a: Array, b: Array) -> Array:
	var out := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	for i in 3:
		for j in 3:
			var acc := 0.0
			for k in 3:
				acc += float(a[i][k]) * float(b[k][j])
			out[i][j] = acc
	return out


func _draw_slot(i: int) -> void:
	var mon = slots[i]["mon"]
	mon.draw()
	var colour := _slot_colour(i)
	var world: Array = mon.world()
	var view := _view_rotation(eye, vr)
	var points := PackedVector2Array()
	var last_world: Array = []
	for u in mon.units.size():
		var unit: Dictionary = mon.units[u]
		var c: int = unit["coord"]
		if c >= 0:
			last_world = world[c]
		if last_world.is_empty():
			continue
		var rm: PackedInt32Array = last_world[0]
		var rt: Vector3 = last_world[1]
		for block in unit["blocks"]:
			var verts: PackedInt32Array = block["vertices"]
			var screen := PackedVector2Array()
			screen.resize(verts.size() / 3)
			var valid := PackedByteArray()
			valid.resize(verts.size() / 3)
			for v in verts.size() / 3:
				var p := Vector3(verts[3 * v], verts[3 * v + 1], verts[3 * v + 2])
				var w := Vector3(
					(rm[0] * p.x + rm[1] * p.y + rm[2] * p.z) / 4096.0 + rt.x,
					(rm[3] * p.x + rm[4] * p.y + rm[5] * p.z) / 4096.0 + rt.y,
					(rm[6] * p.x + rm[7] * p.y + rm[8] * p.z) / 4096.0 + rt.z)
				var d := w - eye
				var cam := Vector3(
					view[0][0] * d.x + view[0][1] * d.y + view[0][2] * d.z,
					view[1][0] * d.x + view[1][1] * d.y + view[1][2] * d.z,
					view[2][0] * d.x + view[2][1] * d.y + view[2][2] * d.z)
				if cam.z <= 20.0:
					valid[v] = 0
					continue
				valid[v] = 1
				screen[v] = centre + Vector2(projection * cam.x / cam.z, projection * cam.y / cam.z)
			var polys: PackedInt32Array = block["polys"]
			for q in polys.size() / 5:
				var flags := polys[5 * q]
				var quad := (flags & 1) != 0
				var v0 := polys[5 * q + 1]
				var v1 := polys[5 * q + 2]
				var v2 := polys[5 * q + 3]
				var v3 := polys[5 * q + 4]
				var corners := [v0, v1, v2] if not quad else [v0, v1, v3, v2]
				var ok := true
				for corner in corners:
					if corner >= valid.size() or valid[corner] == 0:
						ok = false
				if not ok:
					continue
				var count := corners.size()
				for e in count:
					points.append(screen[corners[e]])
					points.append(screen[corners[(e + 1) % count]])
	lines[i] = {"points": points, "colour": colour}


## Draws the monsters' outlines (the picture's coordinates) onto `canvas`, one multiline per slot.
func draw_on(canvas: CanvasItem) -> void:
	for i in 2:
		if not lines.has(i):
			continue
		var entry: Dictionary = lines[i]
		var points: PackedVector2Array = entry["points"]
		if points.size() >= 2:
			canvas.draw_multiline(points, entry["colour"], 1.0)
