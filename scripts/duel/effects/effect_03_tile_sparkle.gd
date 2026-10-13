extends "res://scripts/duel/effects/effect_program.gd"
## Effect 3: the tile sparkle of a battle reveal. The revealed card's picture (140 x 196, read back from the screen with its corners
## rounded: the copy is taken when the battle reveals the card, and the request's point is the card's top-left plus (70, 98)) is laid
## out as five columns of seven 28 x 28 tiles. Each column lights its tiles one at a time from the bottom up (a countdown and a
## cursor); a lit tile is drawn semi-transparent once its sparkle starts, and the sparkle sprite (a cell of the descriptor's
## texture page) grows around the tile's jittered corners while the tile's colours fade. Phase 0 and 1 select the descriptor (the
## attack's and the defence's reveal); phase 2 and up is the banner path.
##
## The tiles, the jitter and the sparkle corners are picture points (the overlay's packets, not the geometry engine); the request's
## offset is added to them as the bias-0 packets do. The page is the copy of the screen, held as the runtime page SHEET_PAIR.

const SHEET_PAIR := 29            # the picture copy's page: no baked pair uses it (the readback of the card at VRAM (320, 256))
const SHEET_SIZE := Vector2i(140, 196)
const COLUMNS := 5
const ROWS := 7
const TILE := 28

var descriptor: Dictionary = {}
var texture_pair := 0             # the sparkle sprites' page: the descriptor's texture index (the page table's pairs[])
var active := PackedInt32Array()  # per tile (column * 7 + row): 1 while its sparkle runs
var cursor := PackedInt32Array()  # per column: the next tile to light (7 when the column is done)
var countdown := PackedInt32Array()
var sparkles := PackedInt32Array()
var radius := PackedInt32Array()
var jitter := PackedInt32Array()
var colours_a: Array = []         # per tile: the top colours (vertices 0 and 1)
var colours_c: Array = []         # per tile: the bottom colours (vertices 2 and 3)
var colours_b: Array = []         # per tile: the sparkle's colour
var frame := 0


func _init() -> void:
	variant_count = 2
	geometry = Vector2i.ZERO


func _start(phase: int) -> void:
	var descriptors: Array = Data.configs().get("effect_3", [])
	descriptor = descriptors[phase] if phase < descriptors.size() else {"size": 8, "delay": 4, "frames": 60, "texture": 0}
	texture_pair = int(descriptor["texture"])
	var sheet = extra.get("sheet", null)
	if not sheet is Image:
		sheet = Image.create(SHEET_SIZE.x, SHEET_SIZE.y, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0.5, 0.5, 0.5, 1.0))
	canvas.set_page(SHEET_PAIR, sheet)
	var delay := int(descriptor["delay"])
	var size := int(descriptor["size"])
	var tiles := COLUMNS * ROWS
	active = PackedInt32Array()
	sparkles = PackedInt32Array()
	radius = PackedInt32Array()
	jitter = PackedInt32Array()
	colours_a = []
	colours_c = []
	colours_b = []
	for n in tiles:
		active.append(0)
		sparkles.append(rng.randi_range(0, 3))
		radius.append(size + rng.randi_range(0, 32767) % maxi(size / 2, 1))
		jitter.append((rng.randi_range(0, 32767) - rng.randi_range(0, 32767)) % 12)
		colours_a.append(PackedInt32Array([128, 128, 128]))
		colours_c.append(PackedInt32Array([128, 128, 128]))
		colours_b.append(PackedInt32Array([128, 128, 128]))
	cursor = PackedInt32Array()
	countdown = PackedInt32Array()
	for k in COLUMNS:
		cursor.append(ROWS - 1)
		countdown.append(delay)
	frame = 0


func _update() -> void:
	var delay := int(descriptor["delay"])
	var frames := int(descriptor["frames"])
	for k in COLUMNS:
		for i in ROWS:
			var n := k * ROWS + i
			var a: PackedInt32Array = colours_a[n]
			var c: PackedInt32Array = colours_c[n]
			var b: PackedInt32Array = colours_b[n]
			if is_lit(a) or is_lit(c) or is_lit(b):
				var top := [colour_of(a), colour_of(a), colour_of(c), colour_of(c)]
				var x0 := k * TILE - 70
				var y0 := i * TILE - 98
				var y2 := i * TILE - (98 - TILE)
				# the tile's own picture points (the overlay's packet); its texels are the card's (k * 28, i * 28) cell
				var points := [Vector2i(x0, y0), Vector2i(x0 + TILE, y0), Vector2i(x0, y2), Vector2i(x0 + TILE, y2)]
				var uv := [Vector2i(k * TILE, i * TILE), Vector2i(k * TILE + TILE, i * TILE),
					Vector2i(k * TILE, i * TILE + TILE), Vector2i(k * TILE + TILE, i * TILE + TILE)]
				if active[n] == 1:
					var j: int = jitter[n]
					var r: int = radius[n]
					var q0 := Vector2i(x0 + j, y0 + j)
					var q1 := Vector2i(x0 + TILE + j, y0 + j)
					var q2 := Vector2i(x0 + j, y2 + j)
					var q3 := Vector2i(x0 + TILE + j, y2 + j)
					var spark_points := [Vector2i(q0.x - r, q0.y - 3 * r), Vector2i(q1.x + r, q1.y - 3 * r),
						Vector2i(q2.x - r, q2.y + r), Vector2i(q3.x + r, q3.y + r)]
					var s: int = sparkles[n]
					var su: int
					var sv: Array
					if int(descriptor["texture"]) == 4:
						su = posmod(s * 32 - 0x80, 256)
						sv = [64, 127]
					else:
						su = posmod(s * 32, 256)
						sv = [128, 191]
					var spark_uv := [Vector2i(su, sv[0]), Vector2i(posmod(su + 31, 256), sv[0]),
						Vector2i(su, sv[1]), Vector2i(posmod(su + 31, 256), sv[1])]
					var spark_colour: Vector3i = colour_of(b)
					canvas.add_poly(_offset_points(spark_points), [spark_colour, spark_colour, spark_colour, spark_colour],
						spark_uv, texture_pair, flags, 1)
					fade_down(a, 15)
					fade_down(c, 31)
					fade_down(b, 8)
					sparkles[n] = (s + 1) % 4
					canvas.add_poly(_offset_points(points), top, uv, SHEET_PAIR, flags, 1)
				else:
					canvas.add_poly(_offset_points(points), top, uv, SHEET_PAIR, flags + 1, -1)
		if cursor[k] < ROWS:
			var wait := rng.randi() % countdown[k] if countdown[k] > 0 else 0
			if wait == 0:
				active[k * ROWS + cursor[k]] = 1
				countdown[k] = delay
				if cursor[k] == 0:
					cursor[k] = ROWS
				else:
					cursor[k] = cursor[k] - 1
			else:
				countdown[k] = countdown[k] - 1
	frame += 1
	if frames < frame:
		done = true
