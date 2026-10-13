extends RefCounted
## The base of a port of one duel effect program (see docs/duel-effects.md for the protocol and the table of ids).
##
## The duel calls a program once per frame with the request's phase: a phase of 0 or more is the first call, which sets the
## program up for that variant (a configuration index, or a mode); a negative phase is a frame step, which draws the frame and
## advances the state. A variant at or past variant_count takes the debug banner path (two diagonal lines for 180 frames).
## `done` ends the request (the overlay's finish flag); `impact` says the effect reached the point where the game may go on.
##
## The helpers mirror the overlay's packet helpers, with their ordering rules kept: "bias 0" primitives are ordered at the request's
## flags and get its offset, the others are ordered at their depth less bias - 1, shifted by 2 (the ordering-table slot).
## Colours are the console's 0..255 values in Vector3i (or a PackedInt32Array of three when a program fades them in place).

const Gte := preload("res://scripts/duel/effects/gte.gd")
const Data := preload("res://scripts/duel/effects/effect_data.gd")

const WHITE := Vector3i(255, 255, 255)
const SCREEN_W := 320
const SCREEN_H := 240
const DIGIT_PAIR := 9        # pairs[9]: the digit atlas (the number renderer's texture page)
const RING_PAIR := 1         # pairs[1]: the ring and gradient page (its texture words are the page_at_04 pair)
const SPARK_PAIR := 3        # pairs[3]: the sparkle sprites (page_at_0C)
const HALO_PAIR := 2         # pairs[2]: the halo sprite (page_at_08)
const GLOW_PAIR := 10        # pairs[10]: the glow squares (the textured quads' page 0)
const LAYER_PAIR := 0        # pairs[0]: the layered sprite (page_at_00)
const RING_UV := [Vector2i(128, 0), Vector2i(159, 0), Vector2i(128, 63), Vector2i(159, 63)]   # the ring page's cell

var canvas                   # effect_canvas.gd: the picture the program draws into
var gte := Gte.new()
var rng := RandomNumberGenerator.new()
var world := Gte.world_identity()  # the identity world (the view 300 units in front of the picture)
var offset := Vector3i.ZERO  # the request's offset (the offset vector: request fields 00, 02 and 04)
var flags := 0               # the request's flags (request field 10), the ordering slot of the bias-0 primitives
var number := 0              # the request's number (field 12) for the programs that show one
var geometry := Vector2i.ZERO   # the geometry offset the program draws with: (0, 0) in picture space, (160, 108) in scene space
var variant_count := -1      # variants at or past this take the banner path (-1: no banner)
var done := false            # the finish flag: the request ends after this frame
var impact := false          # the request's impact flag: the effect reached the point the game may continue at
var _banner := 0
var fixed_phase := -1        # a first-call phase the id always uses (program 20 is program 16 with phase 1); -1: the request's phase
var extra: Dictionary = {}   # the request's context as given, for the programs that read more than the offset and number
var sticky_phase := -1      # the request's phase once the game sets it to a negative stage value (the terrain change sets -2); later frames carry it
var frame_phase := -1       # the phase of the frame being drawn: -1, or the sticky stage value (the overlay's phase below -1)

# ---- lifecycle --------------------------------------------------------------------------------------------------------------


## Binds the program to a picture and a request. context holds x, y, z (the request's offset), flags, number and seed.
func setup(picture, context: Dictionary) -> void:
	canvas = picture
	extra = context
	offset = Vector3i(int(context.get("x", 0)), int(context.get("y", 0)), int(context.get("z", 0)))
	flags = int(context.get("flags", 0))
	number = int(context.get("number", 0))
	rng.seed = int(context.get("seed", 1))


## The dispatcher's call for one frame (phase >= 0 on the first call, -1 after it).
func dispatch(phase: int) -> void:
	gte.set_geom_offset(geometry.x, geometry.y)
	if phase >= 0 and fixed_phase >= 0:
		phase = fixed_phase
	if phase == -1 and sticky_phase != -1:
		phase = sticky_phase
	if phase >= 0:
		if variant_count >= 0 and phase >= variant_count:
			_banner = 1
		else:
			_banner = 0
			_start(phase)
	elif _banner != 0:
		_banner_frame()
	else:
		frame_phase = phase
		_update()


## The first call: set up the variant. Override.
func _start(_phase: int) -> void:
	pass


## A frame step: draw the frame and advance the state. Override.
func _update() -> void:
	pass


## The debug banner: the two diagonals of the picture for 180 frames (the North American build also printed text, which is not drawn).
func _banner_frame() -> void:
	canvas.add_line(Vector2(0, 0), Vector2(SCREEN_W, SCREEN_H), WHITE, WHITE, 0, -1)
	canvas.add_line(Vector2(SCREEN_W, 0), Vector2(0, SCREEN_H), WHITE, WHITE, 0, -1)
	_banner += 1
	if _banner > 180:
		done = true


# ---- colour state (the overlay's colour helpers) ---------------------------------------------------------------------------


static func colour_of(c: PackedInt32Array) -> Vector3i:
	return Vector3i(c[0], c[1], c[2])


static func set_all(c: PackedInt32Array, value: int) -> void:
	c[0] = value
	c[1] = value
	c[2] = value


static func set_rgb(c: PackedInt32Array, r: int, g: int, b: int) -> void:
	c[0] = r
	c[1] = g
	c[2] = b


## Each channel steps down by step, to zero .
static func fade_down(c: PackedInt32Array, step: int) -> void:
	for i in 3:
		c[i] = c[i] - step if c[i] > step + 1 else 0


## Each channel steps up by step toward the target; true once every channel is at the target .
static func fade_up(c: PackedInt32Array, target: Vector3i, step: int) -> bool:
	var goal := [target.x, target.y, target.z]
	for i in 3:
		c[i] = c[i] + step if c[i] < goal[i] + 1 - step else goal[i]
	return c[0] == goal[0] and c[1] == goal[1] and c[2] == goal[2]


static func is_black(c: PackedInt32Array) -> bool:
	return c[0] == 0 and c[1] == 0 and c[2] == 0


static func is_lit(c: PackedInt32Array) -> bool:
	return c[0] != 0 or c[1] != 0 or c[2] != 0


static func half(rgb: Vector3i) -> Vector3i:
	return Vector3i(rgb.x >> 1, rgb.y >> 1, rgb.z >> 1)


static func quarter(rgb: Vector3i) -> Vector3i:
	return Vector3i(rgb.x >> 2, rgb.y >> 2, rgb.z >> 2)


# ---- shapes (the overlay's vertex helpers) ----------------------------------------------------------------------------------


## A circle of 32 points of the given radius in the x-y plane (ring_vertices: the engine's sine and cosine, 128 units a step).
static func ring(radius: int) -> Array:
	var out: Array = []
	for i in 32:
		out.append(Vector3i(radius * Gte.rcos(i * 128) / 4096, radius * Gte.rsin(i * 128) / 4096, 0))
	return out


## Four points of a square of the given size: (-s, -s), (s, -s), (-s, s), (s, s) (the flat quad the overlay builds).
static func square(size: int) -> Array:
	return [Vector3i(-size, -size, 0), Vector3i(size, -size, 0), Vector3i(-size, size, 0), Vector3i(size, size, 0)]


## A quad from a width and a height per row: the top row at +height top, the bottom at +height bottom .
static func quad_rows(top_w: int, bottom_w: int, top_h: int, bottom_h: int) -> Array:
	return [Vector3i(-top_w, top_h, 0), Vector3i(top_w, top_h, 0), Vector3i(-bottom_w, bottom_h, 0), Vector3i(bottom_w, bottom_h, 0)]


static func shifted(points: Array, by: Vector3i) -> Array:
	var out: Array = []
	for p in points:
		out.append(p + by)
	return out


## The random vector of the overlay's velocity helpers: each component is scale * (r - r') % 4096 / 4096, with r the random draw.
func random_component(scale: int) -> int:
	return scale * rng.randi_range(-4095, 4095) / 4096


func random_vector(scale: int) -> Vector3i:
	return Vector3i(random_component(scale), random_component(scale), random_component(scale))


# ---- primitives: the overlay's packet helpers, with their ordering -------------------------------------------------------


func _projected(vertices: Array) -> Dictionary:
	return gte.rot_average(vertices)


## The picture points with the request's offset added, as the bias-0 helpers do (their packet's x and y).
func _offset_points(xy: Array) -> Array:
	var out: Array = []
	for p in xy:
		out.append(Vector2i(p.x + offset.x, p.y + offset.y))
	return out


## A textured quad (FT4, the helper that adds the offset when bias is 0): mode 1 is the additive semi-transparent case.
func ft4(vertices: Array, pair: int, uv: Array, rgb: Vector3i, bias: int, mode: int) -> void:
	var p := _projected(vertices)
	if not p.ok:
		return
	var colours := [rgb, rgb, rgb, rgb]
	if bias == 0:
		canvas.add_poly(_offset_points(p.xy), colours, uv, pair, flags, 1 if mode == 1 else -1)
	else:
		var depth := maxi(p.depth - (bias - 1), 0)
		canvas.add_poly(p.xy, colours, uv, pair, depth >> 2, -1 if mode == 0 else mode & 3)


## A textured Gouraud quad (GT4): the colours are per point, in packet order.
func gt4(vertices: Array, pair: int, uv: Array, rgb4: Array, bias: int, mode: int) -> void:
	var p := _projected(vertices)
	if not p.ok:
		return
	if bias == 0:
		if mode == 1:
			canvas.add_poly(_offset_points(p.xy), rgb4, uv, pair, flags, 1)
		else:
			canvas.add_poly(_offset_points(p.xy), rgb4, uv, pair, flags + 1, -1)
	else:
		var depth := maxi(p.depth - (bias - 1), 0)
		canvas.add_poly(p.xy, rgb4, uv, pair, depth >> 2, mode & 3)


## A flat quad (F4, no offset): opaque at its depth when mode is 0, else semi-transparent with the ABR the caller passes.
func f4(vertices: Array, rgb: Vector3i, abr_flags: int, mode: int) -> void:
	var p := _projected(vertices)
	if not p.ok:
		return
	canvas.add_poly(p.xy, [rgb], [], -1, p.depth >> 2, -1 if mode == 0 else abr_flags & 3)


## An untextured Gouraud quad (G4) that the strip helpers add: its order is at flags + 1 (bias 0) or at its depth less the bias.
func g4_add(vertices: Array, rgb4: Array, bias: int) -> void:
	var p := _projected(vertices)
	if not p.ok:
		return
	if bias == 0:
		canvas.add_poly(_offset_points(p.xy), rgb4, [], -1, flags + 1, 1)
	else:
		canvas.add_poly(p.xy, rgb4, [], -1, maxi(p.depth - bias, 0) >> 2, 1)


## A gradient strip: untextured Gouraud quads between two rings and a middle ring, black at the outer rings and half the colour
## at the middle one (the gradient strip helper). Each quad is added as an additive g4 at the given bias.
func gradient_strip(rgb: Vector3i, first: Array, middle: Array, last: Array, bias: int) -> void:
	var half_rgb := half(rgb)
	for i in 32:
		var j := (i + 1) % 32
		g4_add([first[i], first[j], middle[i], middle[j]], [Vector3i.ZERO, Vector3i.ZERO, half_rgb, half_rgb], bias)
		g4_add([last[i], last[j], middle[i], middle[j]], [Vector3i.ZERO, Vector3i.ZERO, half_rgb, half_rgb], bias)


## A ring of 32 quads between two rings and a middle ring (the ring strip helper). mode 0 draws the additive case at flags;
## any other mode draws at the depth less the mode, with the mode as its ABR.
func ring_strip(rgb: Vector3i, first: Array, middle: Array, last: Array, mode: int) -> void:
	var uv := [Vector2i(128, 0), Vector2i(159, 0), Vector2i(128, 63), Vector2i(159, 63)]
	for i in 32:
		var j := (i + 1) % 32
		for ring in [first, last]:
			var p := _projected([ring[i], ring[j], middle[i], middle[j]])
			if p.depth < 0 or not p.ok:
				continue
			var colours := [Vector3i.ZERO, Vector3i.ZERO, rgb, rgb]
			if mode == 0:
				canvas.add_poly(_offset_points(p.xy), colours, uv, RING_PAIR, flags, 1)
			else:
				canvas.add_poly(p.xy, colours, uv, RING_PAIR, maxi(p.depth + 1 - mode, 0) >> 2, mode & 3)


## A layered sprite: a textured square of the size at the position, then the half-colour square of twice the size.
func layered_sprite(rgb: Vector3i, size: int, bias: int, at: Vector3i) -> void:
	var uv := [Vector2i(0, 0), Vector2i(63, 0), Vector2i(0, 63), Vector2i(63, 63)]
	ft4(shifted(square(size), at), LAYER_PAIR, uv, rgb, bias, 1)
	ft4(shifted(square(size * 2), at), LAYER_PAIR, uv, half(rgb), bias, 1)


## Gradient quads: a two-row quad from the given widths and height, then the same at a quarter of the colour and double size.
func gradient_quads(rgb: Vector3i, widths: Array, height: int, bias: int) -> void:
	var uv := [Vector2i(128, 0), Vector2i(159, 0), Vector2i(128, 63), Vector2i(159, 63)]
	var w0: int = widths[0]
	var w1: int = widths[1]
	var quad := [Vector3i(-w0, -height, 0), Vector3i(w0, -height, 0), Vector3i(-w1, 0, 0), Vector3i(w1, 0, 0)]
	gt4(quad, RING_PAIR, uv, [Vector3i.ZERO, Vector3i.ZERO, half(rgb), half(rgb)], bias, 1)
	var doubled := []
	for v in quad:
		doubled.append(Vector3i(v.x * 2, v.y * 2, 0))
	gt4(doubled, RING_PAIR, uv, [Vector3i.ZERO, Vector3i.ZERO, quarter(rgb), quarter(rgb)], bias, 1)


## The quad of the overlay's corner helper: count points at the angles of a turn split into count parts (each offset half a part),
## the width and height first scaled by the engine's sine of 45 degrees doubled (the square root of two).
static func diamond(width: int, height: int, count: int) -> Array:
	var w := width * (Gte.rsin(512) << 1) / 4096
	var h := height * (Gte.rsin(512) << 1) / 4096
	var out: Array = []
	for i in count:
		var angle := (4096 / count) * i + (4096 / count) / 2
		out.append(Vector3i(w * Gte.rcos(angle) / 4096, h * Gte.rsin(angle) / 4096, 0))
	return out


## The contour (the overlay's contour helper): four edge quads between an outer and an inner ring of four points, black on the
## outer side and half the colour on the inner side, and a textured square at each inner point (size 8 at bias 0, 16 otherwise).
func contour(rgb: Vector3i, inner: Array, outer: Array, bias: int, mode: int) -> void:
	var uv := [Vector2i(0, 0), Vector2i(63, 0), Vector2i(0, 63), Vector2i(63, 63)]
	var half_rgb := half(rgb)
	for i in 4:
		var j := (i + 1) % 4
		var p := _projected([outer[i], outer[j], inner[i], inner[j]])
		if p.ok:
			var colours := [Vector3i.ZERO, Vector3i.ZERO, half_rgb, half_rgb]
			if bias == 0:
				canvas.add_poly(_offset_points(p.xy), colours, [], -1, flags + 1, mode & 3)
			else:
				canvas.add_poly(p.xy, colours, [], -1, maxi(p.depth + 1 - bias, 0) >> 2, mode & 3)
		var size := 8 if bias == 0 else 16
		ft4(shifted(square(size), inner[i]), LAYER_PAIR, uv, rgb, bias, mode)


## The halo (the overlay's halo helper): a textured square of size 64 from the halo page, at half the colour, additive at flags.
func halo(rgb: Vector3i) -> void:
	var uv := [Vector2i(0, 64), Vector2i(63, 64), Vector2i(0, 127), Vector2i(63, 127)]
	ft4(square(64), HALO_PAIR, uv, half(rgb), 0, 1)


## A glow square (the overlay's textured square of the page pair 10, additive at flags): a square of the size at the position.
func glow_quad(rgb: Vector3i, size: int, at: Vector3i) -> void:
	var uv := [Vector2i(192, 128), Vector2i(255, 128), Vector2i(192, 191), Vector2i(255, 191)]
	ft4(shifted(square(size), at), GLOW_PAIR, uv, rgb, 0, 1)


## A sparkle: a textured sprite of one of four cells of the sparkle page, added at the bias.
func sparkle(rgb: Vector3i, vertices: Array, bias: int) -> void:
	var u := rng.randi_range(0, 1)
	var v := rng.randi_range(0, 1)
	var uv := [Vector2i(160 + u * 32, v * 32), Vector2i(191 + u * 32, v * 32),
		Vector2i(160 + u * 32, 31 + v * 32), Vector2i(191 + u * 32, 31 + v * 32)]
	ft4(vertices, SPARK_PAIR, uv, rgb, bias, 1)


## The full-screen flash: an additive screen-size quad at flags, the colour then fading by step.
func screen_flash(c: PackedInt32Array, step: int) -> void:
	canvas.add_poly([Vector2(0, 0), Vector2(SCREEN_W, 0), Vector2(0, SCREEN_H), Vector2(SCREEN_W, SCREEN_H)],
		[colour_of(c)], [], -1, flags, 1)
	fade_down(c, step)


## The full-screen gradient (the overlay's screen gradient helper): black along the top edge, the colour along the bottom edge,
## additive at flags. The caller fades the colour.
func screen_gradient(c: PackedInt32Array) -> void:
	canvas.add_poly([Vector2(0, 0), Vector2(SCREEN_W, 0), Vector2(0, SCREEN_H), Vector2(SCREEN_W, SCREEN_H)],
		[Vector3i.ZERO, Vector3i.ZERO, colour_of(c), colour_of(c)], [], -1, flags, 1)


## The number renderer: the value's digits (a sign tile first) in cells of the digit atlas, centred on the position.
func number_glyphs(value: int, rgb: Vector3i, at: Vector3i, mode: int, size: int, bias: int) -> void:
	var text := str(absi(value))
	var count := text.length() if value != 0 else 0
	var verts: Array = []
	for i in count * 2 + 4:
		var x := size * ((i / 2) << 1) - (((count + 1) / 2) * size * 2 + size * ((count + 1) % 2))
		var y := size if i % 2 == 1 else -size
		verts.append(Vector3i(x, y, 0) + at)
	var vertex := 0
	for i in count + 1:
		var quad := [verts[vertex], verts[vertex + 2], verts[vertex + 1], verts[vertex + 3]]
		var tile: int
		if i == 0:
			tile = 10 if value > 0 else 11
		else:
			tile = int(text[i - 1])
		var cell := Data.digit_cell(tile)
		var uv := [Vector2i(cell.x, cell.y), Vector2i(cell.x + cell.z, cell.y),
			Vector2i(cell.x, cell.y + cell.w), Vector2i(cell.x + cell.z, cell.y + cell.w)]
		if bias == 0:
			if mode == 1:
				ft4(quad, DIGIT_PAIR, uv, rgb, 0, 1)
			elif mode == 0:
				ft4(quad, DIGIT_PAIR, uv, rgb, 0, 0)
		else:
			var p := _projected(quad)
			if p.ok and p.depth + 1 - bias >= 0:
				canvas.add_poly(p.xy, [rgb, rgb, rgb, rgb], uv, DIGIT_PAIR, (p.depth + 1 - bias) >> 2, 1 if mode == 1 else 0)
		vertex += 2


# ---- shapes and random sets of the programs 8 to 16 (the overlay's vertex helpers: rect, plane, rings in x-z, the scatters) ----------


## A rectangle of the given half-width and half-height: (-w, -h), (w, -h), (-w, h), (w, h) (the rect helper).
static func rect(width: int, height: int) -> Array:
	return [Vector3i(-width, -height, 0), Vector3i(width, -height, 0), Vector3i(-width, height, 0), Vector3i(width, height, 0)]


## A plane of four corners at a height, in x and z: (-w, h, -d), (w, h, -d), (-w, h, d), (w, h, d) (the plane helper).
static func plane(width: int, height: int, depth: int) -> Array:
	return [Vector3i(-width, height, -depth), Vector3i(width, height, -depth), Vector3i(-width, height, depth), Vector3i(width, height, depth)]


## A ring of count points in x and z at height -height (the radial helper: x = width cos, z = depth sin, the angle a step of a turn / count).
static func ring_xz(width: int, depth: int, height: int, count: int) -> Array:
	var out: Array = []
	for i in count:
		var angle := (4096 / count) * i
		out.append(Vector3i(width * Gte.rcos(angle) / 4096, -height, depth * Gte.rsin(angle) / 4096))
	return out


## A four-point ring in x and z at a height (the level helper): width and depth scaled by the square root of two, the points at the
## half-step angles.
static func ring_level(width: int, depth: int, height: int, count: int) -> Array:
	var w := width * (Gte.rsin(512) << 1) / 4096
	var d := depth * (Gte.rsin(512) << 1) / 4096
	var out: Array = []
	for i in count:
		var angle := (4096 / count) * i + (4096 / count) / 2
		out.append(Vector3i(w * Gte.rcos(angle) / 4096, height, d * Gte.rsin(angle) / 4096))
	return out


## The scatter of the vector helper: each axis is scale * (r - r') % 4096 / 4096 with random r, count points at zero of velocity.
func random_scatter(sx: int, sy: int, sz: int, count: int) -> Array:
	var out: Array = []
	for i in count:
		out.append(Vector3i(sx * rng.randi_range(-4095, 4095) / 4096, sy * rng.randi_range(-4095, 4095) / 4096,
			sz * rng.randi_range(-4095, 4095) / 4096))
	return out


## The upward scatter (the burst helper and the ray vector helper): x and z as random_scatter, y = -sy * (r % 4096) / 4096 (up).
func random_upward(sx: int, sy: int, sz: int, count: int) -> Array:
	var out: Array = []
	for i in count:
		out.append(Vector3i(sx * rng.randi_range(-4095, 4095) / 4096, -sy * rng.randi_range(0, 4095) / 4096,
			sz * rng.randi_range(-4095, 4095) / 4096))
	return out


## The planar scatter (the flat vector helper): x and y as random_scatter, z zero.
func random_planar(sx: int, sy: int, count: int) -> Array:
	var out: Array = []
	for i in count:
		out.append(Vector3i(sx * rng.randi_range(-4095, 4095) / 4096, sy * rng.randi_range(-4095, 4095) / 4096, 0))
	return out


## The ray triangles (the ray helper): one additive triangle per position, its first point the position (black) and its other two
## (-width, 0, 0) and (width, 0, 0) in the colour, ordered at its depth less bias. Drawn whatever the flag (as the overlay does).
func ray_triangles(rgb: Vector3i, width: int, positions: Array, bias: int) -> void:
	for pos in positions:
		var p := gte.rot_average([pos, Vector3i(-width, 0, 0), Vector3i(width, 0, 0)])
		canvas.add_poly(p.xy, [Vector3i.ZERO, rgb, rgb], [], -1, maxi(p.depth - bias, 0) >> 2, 1)


## The jagged bolt column (the bolt helper): the base at (x, -height, z), x and z jittered by spread; each later point steps down the
## column and lies on a random radius around it, turned by the sine of its angle (the sign of the base's x or z flips it).
func bolt_path(radius: int, spread: int, height: int, count: int) -> Array:
	var x := spread * rng.randi_range(-4095, 4095) / 4096
	var z := spread * rng.randi_range(-4095, 4095) / 4096
	var step := (height + 16) / count
	var out: Array = [Vector3i(x, -height, z)]
	for i in range(1, count):
		var a := radius + (radius >> 1) * rng.randi_range(-4095, 4095) / 4096
		var b := radius + (radius >> 1) * rng.randi_range(-4095, 4095) / 4096
		var n := 2048 / count * i
		var sx := Gte.rsin(n)
		var sz := Gte.rsin(n)
		if x < 0:
			sx = -sx
		if z < 0:
			sz = -sz
		out.append(Vector3i(x + a * sx / 4096, step * i - height, z + b * sz / 4096))
	return out


## The bolt's lines (the gradient line helper): segment i runs from point i to i + 1, its colour fading along the bolt (the colour
## over count + 1 - i at its start and over count - i at its end), ordered at its far depth less bias. Returns the mode: 1 until the
## first point below the ground (y > 0) is passed, which stores the point (x, 0, z) + offset in endpoint[0] and gives mode 2.
func bolt_lines(rgb: Vector3i, count: int, vertices: Array, bias: int, mode: int, endpoint: Array, abr: int) -> int:
	for i in count:
		var c0 := Vector3i(rgb.x / (count + 1 - i), rgb.y / (count + 1 - i), rgb.z / (count + 1 - i))
		var c1 := Vector3i(rgb.x / (count - i), rgb.y / (count - i), rgb.z / (count - i))
		var a := gte.rot_trans_pers(vertices[i])
		var b := gte.rot_trans_pers(vertices[i + 1])
		var depth: int = b.z - bias
		if depth >= 0:
			canvas.add_line(Vector2(a.x, a.y), Vector2(b.x, b.y), c0, c1, depth >> 2, abr)
		if mode == 1 and vertices[i + 1].y > 0:
			endpoint[0] = Vector3i(vertices[i + 1].x, 0, vertices[i + 1].z) + offset
			mode = 2
	return mode
