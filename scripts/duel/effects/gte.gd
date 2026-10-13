extends RefCounted
## The console's geometry engine as the duel effect programs use it: a local-to-view matrix (RT), a screen distance H, a geometry
## offset, and the projection of 3D vertices onto the picture, with the same integer arithmetic.
##   - matrices are 4.12 fixed point (4096 is 1.0) and their entries are 16-bit; a translation is a full integer;
##   - rotation angles run 4096 to a turn (the sine table is round(4096 * sin(2 pi i / 4096)), exact for the executable's table);
##   - a point projects to x = offset_x + IR1 * H / SZ, y = offset_y + IR2 * H / SZ, with SZ the view depth (IR3), and the
##     picture is clamped to -1024..1023 as the engine clamps it (a clamp, or a depth of zero or less, clears the flag);
##   - the average of several depths is the sum times 1/4 (RotAverage4) or 1/3 (RotAverage3); the programs shift it by 2 for their order.
## The call names in comments are the geometry calls the overlay makes: RotTrans, RotTransPers, RotAverage4, RotMatrix, MulMatrix2,
## ScaleMatrix, SetGeomOffset, SetGeomScreen and GsSetLsMatrix.

static var SIN := PackedInt32Array()
static var COS := PackedInt32Array()


## A 3x3 rotation (row-major, m[row * 3 + column]) and a translation, as a MATRIX record.
class Mat:
	extends RefCounted
	var m := PackedInt32Array([4096, 0, 0, 0, 4096, 0, 0, 0, 4096])
	var t := PackedInt32Array([0, 0, 0])

	func copy_from(other: Mat) -> void:
		m = other.m.duplicate()
		t = other.t.duplicate()

	func clone() -> Mat:
		var out := Mat.new()
		out.copy_from(self)
		return out


var rt := Mat.new()                  # the current local-to-view matrix (GsSetLsMatrix)
var screen_h := 300                  # the projection distance H (SetGeomScreen; 0x12C in the North American build)
var offset_x := 0                    # the geometry offset (SetGeomOffset)
var offset_y := 0
var _stack: Array = []               # PushMatrix / PopMatrix


static func _init_tables() -> void:
	if not SIN.is_empty():
		return
	SIN.resize(4096)
	COS.resize(4096)
	for i in 4096:
		SIN[i] = roundi(4096.0 * sin(TAU * i / 4096.0))
		COS[i] = roundi(4096.0 * cos(TAU * i / 4096.0))


func _init() -> void:
	_init_tables()


## C's (short) cast: wraps to 16 bits.
static func s16(value: int) -> int:
	return ((value + 32768) & 0xFFFF) - 32768


## The engine's saturation of an intermediate result (IR registers): -0x8000..0x7FFF.
static func ir(value: int) -> int:
	return clampi(value, -32768, 32767)


func set_geom_offset(x: int, y: int) -> void:
	offset_x = x
	offset_y = y


func set_screen_distance(h: int) -> void:
	screen_h = h


## GsSetLsMatrix: the view matrix that the next transforms use.
func set_rt(matrix: Mat) -> void:
	rt.copy_from(matrix)


func push() -> void:
	_stack.push_back(rt.clone())


func pop() -> void:
	if not _stack.is_empty():
		rt.copy_from(_stack.pop_back())


## RotTrans: the view-space point of a local vector (not projected). Returns the untruncated MAC values.
func rot_trans(v: Vector3i) -> Vector3i:
	var m := rt.m
	var t := rt.t
	return Vector3i(
		t[0] + ((m[0] * v.x + m[1] * v.y + m[2] * v.z) >> 12),
		t[1] + ((m[3] * v.x + m[4] * v.y + m[5] * v.z) >> 12),
		t[2] + ((m[6] * v.x + m[7] * v.y + m[8] * v.z) >> 12))


## RotTransPers: the picture point and depth of a local vector. Returns Vector4i(x, y, depth, ok), ok = 1 when no flag was raised.
func rot_trans_pers(v: Vector3i) -> Vector4i:
	var view := rot_trans(v)
	var ok := 1
	if view.x < -32768 or view.x > 32767 or view.y < -32768 or view.y > 32767:
		ok = 0
	var sz := view.z
	if sz <= 0 or sz > 0xFFFF:
		ok = 0
	var projected := _project(ir(view.x), ir(view.y), sz)
	if projected.z == 0:
		ok = 0
	return Vector4i(projected.x, projected.y, clampi(sz, 0, 0xFFFF), ok)


## The picture point of view coordinates (x, y) at depth sz: the engine's division by SZ, scaled by H, then the offset.
func _project(x: int, y: int, sz: int) -> Vector3i:
	var q := 0x1FFFF
	var bad := 0
	if sz > 0:
		q = mini((screen_h * 0x20000 / sz + 1) / 2, 0x1FFFF)
	else:
		bad = 1
	var sx := ((x * q) >> 16) + offset_x
	var sy := ((y * q) >> 16) + offset_y
	if sx < -1024 or sx > 1023 or sy < -1024 or sy > 1023:
		bad = 1
	return Vector3i(clampi(sx, -1024, 1023), clampi(sy, -1024, 1023), 1 - bad)


## RotAverage3 / RotAverage4: the picture points of the vertices, the order depth (the average SZ) and the flag. A quad's points
## are in the order the packet holds them (0, 1, 2, 3). Returns {"xy": Array[Vector2i], "depth": int, "ok": bool}.
func rot_average(vertices: Array) -> Dictionary:
	var xy: Array = []
	var total := 0
	var ok := true
	for v in vertices:
		var p := rot_trans_pers(v)
		xy.append(Vector2i(p.x, p.y))
		total += p.z
		ok = ok and p.w == 1
	var depth := total >> 2 if vertices.size() == 4 else (total * 0x555) >> 12
	return {"xy": xy, "depth": depth, "ok": ok}


## RotMatrix: a rotation from angles (X, then Y, then Z, as the engine composes them). Only the 3x3 part is set.
func rot_matrix(angles: Vector3i) -> PackedInt32Array:
	var sx_cx := _sin_cos(angles.x)
	var sy_cy := _sin_cos(angles.y)
	var sz_cz := _sin_cos(angles.z)
	var sx: int = sx_cx[0]
	var cx: int = sx_cx[1]
	var sy: int = sy_cy[0]
	var cy: int = sy_cy[1]
	var sz: int = sz_cz[0]
	var cz: int = sz_cz[1]
	var out := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	out[2] = s16(sy)
	out[5] = s16(-(cy * sx) >> 12)
	out[8] = s16((cy * cx) >> 12)
	out[0] = s16((cz * cy) >> 12)
	out[1] = s16(-(sz * cy) >> 12)
	var t := (cz * -sy) >> 12
	out[3] = s16(((sz * cx) >> 12) - ((t * sx) >> 12))
	out[6] = s16(((sz * sx) >> 12) + ((t * cx) >> 12))
	t = (sz * -sy) >> 12
	out[4] = s16(((cz * cx) >> 12) + ((t * sx) >> 12))
	out[7] = s16(((cz * sx) >> 12) - ((t * cx) >> 12))
	return out


func _sin_cos(angle: int) -> Array:
	return [rsin(angle), rcos(angle)]


## The engine's rsin and rcos: angles of 4096 to a turn, results 4.12 fixed point.
static func rsin(angle: int) -> int:
	_init_tables()
	var s: int = SIN[absi(angle) & 0xFFF]
	return -s if angle < 0 else s


static func rcos(angle: int) -> int:
	_init_tables()
	return COS[absi(angle) & 0xFFF]


## MulMatrix2: the rotation of `world` times the rotation of `local`, into `local` (translation kept).
static func mul_matrix2(world: Mat, local: Mat) -> void:
	var out := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	for row in 3:
		for column in 3:
			var sum := 0
			for k in 3:
				sum += world.m[row * 3 + k] * local.m[k * 3 + column]
			out[row * 3 + column] = s16(ir(sum >> 12))
	local.m = out


## ScaleMatrix: each column of the rotation is scaled by one component of `scale` (4096 is 1.0).
static func scale_matrix(matrix: Mat, scale: Vector3i) -> void:
	var factors := [scale.x, scale.y, scale.z]
	for row in 3:
		for column in 3:
			matrix.m[row * 3 + column] = s16((matrix.m[row * 3 + column] * factors[column]) >> 12)


## The identity world the effects start from: no rotation, and the view placed 300 units in front of the picture .
static func world_identity() -> Mat:
	var world := Mat.new()
	world.t = PackedInt32Array([0, 0, 300])
	return world


## The overlay's per-object transform : sets the view matrix to the object's pose under `world`.
## mode 0 places it alone, 1 also keeps the pose in `saved` (for the scale helpers below), 2 composes it with `world`'s rotation,
## 3 does both. The result is left as the view matrix (GsSetLsMatrix).
func pose(world: Mat, saved: Mat, position: Vector3i, rotation: Vector3i, scale: Vector3i, mode: int) -> void:
	set_rt(world)
	var matrix := Mat.new()
	var view := rot_trans(position)
	matrix.t = PackedInt32Array([view.x, view.y, view.z])
	matrix.m = rot_matrix(rotation)
	if mode == 2 or mode == 3:
		mul_matrix2(world, matrix)
	if mode == 1 or mode == 3:
		saved.copy_from(matrix)
	scale_matrix(matrix, scale)
	set_rt(matrix)


## The saved pose scaled by `scale` becomes the view matrix.
func scaled_saved(saved: Mat, scale: Vector3i) -> void:
	var matrix := saved.clone()
	scale_matrix(matrix, scale)
	set_rt(matrix)
