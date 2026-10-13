extends RefCounted
## One credits monster: its coordinate units, polygons and part animation, read from credits/monsters.bin (tools/extract.py
## bake_credits_monsters, encode_monster), and played as the monster slots of the credits play it. This is a port of tools/monster_anim.py,
## which is the reference: the same integer arithmetic (GDScript's integer division truncates toward zero, as C's does), the same
## tables (the loader's row and relink work is baked), the same per-VBlank order: the controller (credits_monsters.gd), the draw (the
## sequencer, then the row output), the row clock.
##
## The units are read as
##   coords[k]   Coord: m (9 Q12 words, rows), t (3), rot (3 Euler angles), parent (-1 for the root)
##   units[u]    the unit's coordinate index (u - 1, or -1), and its blocks: vertices (flat x y z) and polygons (flat: flags, c0 .. c3)
## The animation: seqs (one dictionary of GsSEQ fields per part), commands (the command words, after the relink), params (keyframe
## halfwords from the parameter table, nine per keyframe), k2c8 and t750 (10 rows x 58 parts), t750_max, the coordinate-bit flags.

const BASE_ROW := 1
const SPEED := 16
const ROW_CLOCK := 16
const E16_MODE := 0x3E
const INTERPOLATE_TYPE := 0x03002119
const KIND_FOR_STEP := [1, 2, 1, 7, 1]
const ROWS := 10
const PARTS := 58
const SIN_TABLE_SIZE := 4096

static var _sin_table := PackedInt32Array()

var coord_m: Array = []        # per coordinate: PackedInt32Array(9), the rows of the local matrix
var coord_t: Array = []        # per coordinate: PackedInt32Array(3)
var coord_rot: Array = []      # per coordinate: PackedInt32Array(3)
var coord_parent := PackedInt32Array()
var units: Array = []          # per unit: {coord: int, blocks: [{vertices: PackedInt32Array, polys: PackedInt32Array}]}
var root := -1
var cf8 := PackedInt32Array()  # the slot's centre offsets (signed bytes of the META sector, multiplied by 16 when used)

var part_count := 0
var seqs: Array = []           # per part: {rewrite, size, num, ii, aframe, sid, speed, srcii, rframe, tframe, ci, ti, start, start_sid, traveling}
var k2c8 := PackedInt32Array()     # ROWS x PARTS
var t750 := PackedInt32Array()     # ROWS x PARTS
var t750_max := PackedInt32Array() # ROWS
var bec := PackedInt32Array()      # 8 bytes
var handlers := PackedInt64Array()
var commands := PackedInt64Array()
var params := PackedInt32Array()   # keyframe halfwords

# The slot's controller state (the model slot's fields the credits use).
var E0F := 0
var BF5 := BASE_ROW
var BF4 := BASE_ROW
var BF6 := BASE_ROW
var E06 := 0
var E10 := 0
var E15 := 0
var saved := PackedInt32Array()


## Parses one monster blob (already decompressed).
static func from_blob(blob: PackedByteArray) -> RefCounted:
	var m: RefCounted = load("res://scripts/menu/monster_anim.gd").new()
	m.call("_read", blob)
	return m


func _read(b: PackedByteArray) -> void:
	var p := 0
	var count := b.decode_u32(p)
	p += 4
	for i in count:
		var m := PackedInt32Array()
		for j in 9:
			m.append(b.decode_s16(p + 2 * j))
		coord_m.append(m)
		coord_t.append(PackedInt32Array([b.decode_s32(p + 20), b.decode_s32(p + 24), b.decode_s32(p + 28)]))
		coord_rot.append(PackedInt32Array([b.decode_s16(p + 32), b.decode_s16(p + 34), b.decode_s16(p + 36)]))
		coord_parent.append(b.decode_s16(p + 38))
		p += 42
	var unit_count := b.decode_u32(p)
	p += 4
	for u in unit_count:
		var unit := {"coord": b.decode_s16(p), "blocks": []}
		p += 2
		var blocks := b.decode_u32(p)
		p += 4
		for k in blocks:
			var nverts := b.decode_u32(p)
			p += 4
			var verts := PackedInt32Array()
			for v in nverts * 3:
				verts.append(b.decode_s16(p + 2 * v))
			p += nverts * 6
			var npolys := b.decode_u32(p)
			p += 4
			var polys := PackedInt32Array()
			for q in npolys:
				polys.append(b.decode_u8(p))
				polys.append(b.decode_u16(p + 2))
				polys.append(b.decode_u16(p + 4))
				polys.append(b.decode_u16(p + 6))
				polys.append(b.decode_u16(p + 8))
				p += 10
			(unit["blocks"] as Array).append({"vertices": verts, "polys": polys})
		units.append(unit)
	part_count = b.decode_u32(p)
	p += 4
	for i in part_count:
		seqs.append({
			"rewrite": b.decode_u32(p), "size": b.decode_u16(p + 4), "num": b.decode_u16(p + 6),
			"ii": b.decode_u16(p + 8), "aframe": b.decode_u16(p + 10), "sid": b.decode_u8(p + 12),
			"speed": b.decode_s8(p + 13), "srcii": b.decode_u16(p + 14), "rframe": b.decode_s16(p + 16),
			"tframe": b.decode_u16(p + 18), "ci": b.decode_u16(p + 20), "ti": b.decode_u16(p + 22),
			"start": b.decode_u16(p + 24), "start_sid": b.decode_u8(p + 26), "traveling": b.decode_u8(p + 27),
		})
		p += 28
	k2c8 = _u16_array(b, p, ROWS * PARTS)
	p += ROWS * PARTS * 2
	t750 = _u16_array(b, p, ROWS * PARTS)
	p += ROWS * PARTS * 2
	t750_max = _u16_array(b, p, ROWS)
	p += ROWS * 2
	bec = PackedInt32Array()
	for j in 8:
		bec.append(b.decode_u8(p + j))
	p += 8
	var handler_count := b.decode_u32(p)
	p += 4
	for j in handler_count:
		handlers.append(b.decode_u32(p + 4 * j))
	p += handler_count * 4
	var command_count := b.decode_u32(p)
	p += 4
	commands.resize(command_count)
	for j in command_count:
		commands[j] = b.decode_u32(p + 4 * j)
	p += command_count * 4
	var half_count := b.decode_u32(p)
	p += 4
	params = _u16_array(b, p, half_count)
	p += half_count * 2
	cf8 = PackedInt32Array([b.decode_s8(p), b.decode_s8(p + 1), b.decode_s8(p + 2)])
	p += 3
	root = b.decode_s16(p)


static func _u16_array(b: PackedByteArray, at: int, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(count)
	for i in count:
		out[i] = b.decode_u16(at + 2 * i)
	return out


# ---- command words and keyframes (a keyframe is nine halfwords at its word offset in the parameter table)

func _cmd(k: int) -> int:
	var v := commands[k]
	return v - 0x100000000 if v >= 0x80000000 else v


func _cmd_low(k: int) -> int:
	return commands[k] & 0xFFFF


func _sample(w: int) -> PackedInt32Array:
	var s := PackedInt32Array()
	s.resize(9)
	for j in 9:
		s[j] = _s16(params[2 * w + j])
	return s


func _sample_set(w: int, vals: PackedInt32Array) -> void:
	for j in 9:
		params[2 * w + j] = vals[j] & 0xFFFF


static func _s16(v: int) -> int:
	v &= 0xFFFF
	return v - 0x10000 if v & 0x8000 else v


static func _s32(v: int) -> int:
	v &= 0xFFFFFFFF
	return v - 0x100000000 if v & 0x80000000 else v


static func _sin_cos_table() -> PackedInt32Array:
	if _sin_table.is_empty():
		_sin_table.resize(SIN_TABLE_SIZE)
		for a in SIN_TABLE_SIZE:
			_sin_table[a] = roundi(sin(float(a) * TAU / 4096.0) * 4096.0)
	return _sin_table


static func _rsin(a: int) -> int:
	return _sin_cos_table()[a & 0xFFF]


static func _rcos(a: int) -> int:
	return _sin_cos_table()[(a + 1024) & 0xFFF]


## RotMatrixYXZ: the Q12 rotation (rows) for Euler angles rx, ry, rz.
static func rot_matrix_yxz(rx: int, ry: int, rz: int) -> PackedInt32Array:
	var sx := _rsin(rx)
	var cx := _rcos(rx)
	var sy := _rsin(ry)
	var cy := _rcos(ry)
	var sz := _rsin(rz)
	var cz := _rcos(rz)
	var sysx := (sy * sx) >> 12
	var cysx := (cy * sx) >> 12
	var m := PackedInt32Array()
	m.resize(9)
	m[0] = _s16(((cy * cz) >> 12) + ((sz * sysx) >> 12))
	m[1] = _s16(((cz * sysx) >> 12) - ((cy * sz) >> 12))
	m[2] = _s16((cx * sy) >> 12)
	m[3] = _s16((sz * cx) >> 12)
	m[4] = _s16((cz * cx) >> 12)
	m[5] = _s16(-sx)
	m[6] = _s16(((sz * cysx) >> 12) - ((sy * cz) >> 12))
	m[7] = _s16(((cz * cysx) >> 12) + ((sy * sz) >> 12))
	m[8] = _s16((cx * cy) >> 12)
	return m


static func scale_matrix(m: PackedInt32Array, v: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(9)
	for i in 3:
		for j in 3:
			out[3 * i + j] = _s16((m[3 * i + j] * v[j]) >> 12)
	return out


# ---- the table work (the seek of a row, the row change, the controller's control word)

## The part's sequence in row n at position pos (the seek of the row tables).
func _seek(i: int, n: int, pos: int) -> void:
	var sq: Dictionary = seqs[i]
	var k := k2c8[n * PARTS + i]
	if k == 0xFFFF or t750[n * PARTS + i] == 0:
		return
	var step := t750[n * PARTS + i] * 16
	var rem := pos % step
	var cp := k - 1
	if rem == 0 and pos != 0 and E16_MODE != 0x3C:
		rem = step
	var length := _cmd_low(cp)
	var idx := 0
	if idx >= length:
		return
	var q := k
	while idx < length:
		var dur := ((commands[q] >> 16) & 0xFF) << 4
		var d := rem - dur
		if E16_MODE != 0x3C:
			if d <= 0:
				break
		elif d < 0:
			break
		rem = rem - dur
		if _cmd(q + 1) < 0:
			break
		q += 1
		idx += 1
	if idx >= length:
		return
	var v := q
	while true:
		if _cmd(v + 1) >= 0:
			idx += 1
			v += 1
			if idx < length:
				continue
		break
	sq["ti"] = q
	sq["ci"] = q - 1 if q != 0 else v
	var y := ((commands[q] >> 16) & 0xFF) << 4
	var z := y - rem
	sq["tframe"] = y
	sq["rframe"] = _s16(z)
	if E16_MODE == 0x3C and _s16(z) >= y:
		sq["rframe"] = 0x6000


## The slot's state after the loader: the base row, every part seeked to it.
func init_slot() -> void:
	E0F = 0
	BF5 = BASE_ROW
	BF4 = BASE_ROW
	BF6 = BASE_ROW
	E06 = 0
	E10 = 0
	E15 = 0
	saved = PackedInt32Array()
	for i in part_count:
		_seek(i, BF5, 0)


func set_row(flag: int, val: int = 0) -> void:
	E06 = (val << 4) & 0xFFFF
	for i in part_count:
		var arg2 := BF5
		if flag != 0:
			seqs[i]["sid"] = flag
			arg2 = flag
		_seek(i, arg2, E06)
	if flag != 0:
		BF5 = flag


func _bec_words(i: int) -> int:
	return 5 if (bec[i / 8] >> (i % 8)) & 1 else 3


## The row control: -1 clears the output pointers, 0 restores the saved words, a row selects it.
func control(anim: int, flag: int) -> void:
	if anim == -1:
		E10 = 0
		for sq in seqs:
			sq["ii"] = 0xFFFF
		return
	if anim == 0:
		if E0F == 0:
			return
		var pos := 0
		for i in part_count:
			var row_key := k2c8[E0F * PARTS + i]
			if row_key != 0xFFFF:
				var words := _bec_words(i)
				var src := _cmd_low(row_key)
				for j in 2 * words:
					params[2 * src + j] = saved[pos]
					pos += 1
		E0F = 0
		return
	var prev := E0F
	if t750_max[anim] == 0:
		return
	if prev != 0:
		if flag == 0:
			return
		BF6 = BF4
		control(0, 0)
	E0F = anim
	if prev == anim:
		set_row(0, 0)
		return
	E10 = 1
	saved = PackedInt32Array()
	for i in part_count:
		var copy_row := k2c8[E0F * PARTS + i]
		if copy_row != 0xFFFF:
			var words := _bec_words(i)
			var src := _cmd_low(copy_row)
			seqs[i]["ii"] = copy_row
			for j in 2 * words:
				saved.append(params[2 * src + j])


# ---- the sequencer: every part advances one step (the draw of the slot)

func _scan_command(track: Dictionary, index: int) -> int:
	var step := -1 if track["speed"] < 0 else 1
	while true:
		var word := commands[index & 0xFFFF]
		if word & 0x80000000:
			if (word & 0xC0000000) == 0x80000000:
				var cond := (word & 0x7F0000) >> 16
				if cond == 0 or track["sid"] == cond:
					var action := (word & 0x3F800000) >> 23
					if cond != 0 or action != 0:
						track["sid"] = action
					index = word
					continue
			elif (word & 0xC0000000) == 0xC0000000:
				var cond2 := (word & 0x7F0000) >> 16
				var action2 := (word & 0x3F800000) >> 23
				if action2 == 1 and (cond2 == 0 or track["sid"] == cond2):
					return 0xFFFF
			index += step
			continue
		return index
	return 0xFFFF


func _wrap(src: int, tgt: int) -> int:
	var d := _s16(src) - _s16(tgt)
	if d < 0:
		if _s16(tgt) - _s16(src) < 2049:
			return _s16(tgt)
	elif d < 2049:
		return _s16(tgt)
	var w := _s16(tgt)
	return w - 4096 if w > 0 else w + 4096


## The interpolation (0x03002119): one unit's translation, rotation and scale between two keyframes.
func _interpolate(track: Dictionary, src: int, tgt: int, out: int) -> int:
	if track["tframe"] == 0:
		return 1
	var t: int = track["rframe"]
	var dur: int = track["tframe"]
	var rest := dur - t
	var s1 := _sample(src)
	var s2 := _sample(tgt)
	var k := (((track["rewrite"] as int) & 0xFFFFFF) - 1) / 20
	var tt := PackedInt32Array()
	tt.resize(3)
	for j in 3:
		tt[j] = (s1[j] * t + s2[j] * rest) / dur
	coord_t[k] = tt
	var rx := s2[3]
	var ry := s2[4]
	var rz := s2[5]
	var a := s1[3]
	var b := s1[4]
	var c := s1[5]
	if dur == 16:
		rx = _wrap(a, rx)
		ry = _wrap(b, ry)
		rz = _wrap(c, rz)
	var rot := PackedInt32Array([_s16((a * t + rx * rest) / dur), _s16((b * t + ry * rest) / dur), _s16((c * t + rz * rest) / dur)])
	coord_rot[k] = rot
	var scale := PackedInt32Array()
	scale.resize(3)
	for j in 3:
		scale[j] = _s16((s1[6 + j] * t + s2[6 + j] * rest) / dur)
	coord_m[k] = scale_matrix(rot_matrix_yxz(rot[0], rot[1], rot[2]), scale)
	if out >= 0:
		var vals := PackedInt32Array()
		vals.resize(9)
		for j in 3:
			vals[j] = _s16(tt[j])
			vals[3 + j] = rot[j]
			vals[6 + j] = scale[j]
		_sample_set(out, vals)
	return 0


func sequence_step() -> void:
	for track in seqs:
		if (track["aframe"] & 0xFFFF) == 0:
			continue
		if (track["aframe"] & 0xFFFF) != 0xFFFF:
			track["aframe"] = (track["aframe"] - 1) & 0xFFFF
		var direction := -1 if track["speed"] < 0 else 1
		if track["rframe"] == 0x7000:
			direction = 1
			track["rframe"] = 0
		elif track["rframe"] == 0x6000:
			direction = -1
			track["rframe"] = 0
		while true:
			if track["rframe"] == 0 or track["tframe"] == 0:
				track["traveling"] = 0
				var stopped := false
				var found := 0
				if direction == 1:
					if commands[track["ti"]] & 0x80000000:
						found = _scan_command(track, track["ti"] + 1)
						track["ti"] = found & 0xFFFF
						if (found & 0xFFFF) == 0xFFFF:
							stopped = true
					if not stopped:
						track["ci"] = track["ti"]
						found = _scan_command(track, track["ci"] + direction)
						track["ti"] = found & 0xFFFF
				else:
					if commands[track["ci"]] & 0x80000000:
						found = _scan_command(track, track["ci"] + direction)
						track["ci"] = found & 0xFFFF
						if (found & 0xFFFF) == 0xFFFF:
							stopped = true
					if not stopped:
						track["ti"] = track["ci"]
						found = _scan_command(track, track["ti"] + direction)
						track["ci"] = found & 0xFFFF
				if not stopped and (found & 0xFFFF) == 0xFFFF:
					stopped = true
				if stopped:
					track["aframe"] = 0
					break
				track["tframe"] = ((commands[track["ti"]] >> 16) & 0xFF) << 4
				if direction == 1:
					track["rframe"] = _s16(track["tframe"] - (track["rframe"] & 0xFFFF))
			var value := (commands[track["ti"]] >> 24) & 0x7F
			var src := _cmd_low(track["ci"])
			var tgt := _cmd_low(track["ti"])
			var out := _cmd_low(track["ii"]) if track["ii"] != 0xFFFF else -1
			if track["ci"] != track["ti"]:
				if value >= handlers.size() or handlers[value] != INTERPOLATE_TYPE:
					push_error("credits monster: animation handler type not supported")
					break
				var result := _interpolate(track, src, tgt, out)
				if result == 1:
					track["rframe"] = 0
					continue
				if ((commands[track["ti"]] >> 16) & 0xFF) == 0:
					continue
				track["rframe"] = _s16((track["rframe"] & 0xFFFF) - track["speed"])
				if direction == 1 and track["rframe"] < 0:
					track["rframe"] = 0x7000
				elif direction == -1 and track["rframe"] >= track["tframe"]:
					track["rframe"] = 0x6000
			break


## One draw of the slot (the draw in the model update): the sequencer, then the controller's output and row handling.
func draw() -> void:
	sequence_step()
	if E10 != 0:
		control(-1, 0)
	elif E0F != 0:
		if E0F != BF5:
			set_row(E0F, 0)
		else:
			BF6 = 0


## The row clock, once per VBlank after the draw: it counts the row's length and returns to the base row.
func row_clock() -> void:
	var length := t750_max[BF5] << 4
	if E06 >= length:
		E06 = 0
	var v := E06 + ROW_CLOCK
	E06 = length if v >= length else v
	if E10 == 0 and E06 >= length and BF4 != BF6:
		set_row(BF4, 0)
		BF6 = BF4
		if E0F != 0:
			control(0, 0)


## The controller's tick while no row plays (the active slot's state 0). Returns the row to select, KIND_NONE, or
## KIND_DEFAULT when the credits move on (the peer takes over).
const KIND_NONE := -1
const KIND_DEFAULT := -2

func tick() -> int:
	if E0F != 0:
		return KIND_NONE
	var frame := E15 & 0xFF
	var chosen := KIND_NONE
	if frame % 30 == 0:
		var step := (frame / 30) & 0xFF
		if step < KIND_FOR_STEP.size():
			chosen = KIND_FOR_STEP[step]
			control(chosen, 1)
		else:
			chosen = KIND_DEFAULT
	E15 = (E15 + 1) & 0xFF
	return chosen


## The part's world matrix and translation: the coordinate units composed up the parents (the unit's workm).
func world() -> Array:
	var out: Array = []
	out.resize(coord_m.size())
	for k in coord_m.size():
		out[k] = _world_of(k, out)
	return out


func _world_of(k: int, cache: Array) -> Array:
	if cache[k] != null:
		return cache[k]
	var m: PackedInt32Array = coord_m[k]
	var t: PackedInt32Array = coord_t[k]
	var p := coord_parent[k]
	if p < 0:
		cache[k] = [m, Vector3(t[0], t[1], t[2])]
		return cache[k]
	var parent: Array = _world_of(p, cache)
	var pm: PackedInt32Array = parent[0]
	var pt: Vector3 = parent[1]
	var rm := PackedInt32Array()
	rm.resize(9)
	for i in 3:
		for q in 3:
			var acc := 0
			for j in 3:
				acc += pm[3 * i + j] * m[3 * j + q]
			rm[3 * i + q] = acc >> 12
	var rt := Vector3()
	for i in 3:
		var acc2 := 0
		for j in 3:
			acc2 += pm[3 * i + j] * t[j]
		rt[i] = (acc2 >> 12) + pt[i]
	cache[k] = [rm, rt]
	return cache[k]
