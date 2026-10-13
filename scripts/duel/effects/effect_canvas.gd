extends Node2D
## The picture an effect program draws into. Programs record their primitives (triangles and quads, flat or Gouraud, textured or
## not, and lines) with an order slot and a semi-transparency mode; present() sorts them the way the console's ordering table
## does (a larger slot is drawn first, so a smaller slot is nearer and lands on top; within a slot the record added last is drawn
## first) and hands each run of one blend mode to a child layer. The picture is 320 x 240 in the scene's own pixels.
##
## Colours are in the console's units: flat and Gouraud colours are 0..255, and a textured primitive's colour multiplies the
## texel, where 128 is unchanged (so it is divided by 128 here). Textured coordinates are texels of the texture page
## (the baked pages in assets/screens/duel_fx/, see docs/duel-effects.md).
##
## Semi-transparency: abr -1 is opaque; abr 0 averages the two layers (drawn as 50 percent mix), 1 adds, 2 subtracts, and 3 adds
## a quarter of the colour. The console's per-texel semi-transparency bit (CLUT bit 15) is not kept per texel: a texel with the bit
## is drawn half transparent only inside a primitive that is itself semi-transparent.

const Layer := preload("res://scripts/duel/effects/effect_layer.gd")

const BLEND_OPAQUE := 0
const BLEND_ADD := 2
const BLEND_SUB := 3
const PAGE_DIR := "res://assets/screens/duel_fx/"
const PICTURE := Vector2(320, 240)

var _records: Array = []
var _order := 0
var _layers: Array = []
var _pages := {}                 # pair index -> Texture2D, or null when the page is missing
var _page_size := {}             # pair index -> Vector2 (the page's texel size)


## Starts a frame: the records of the last one are dropped (the layers keep their nodes).
func clear() -> void:
	_records.clear()
	_order = 0


## A polygon of 3 or 4 points (picture pixels), with one colour or one per point, and texture coordinates (texels) when pair >= 0.
## slot is the order slot; abr is -1 for opaque or the semi-transparency mode 0..3.
func add_poly(points: Array, colours: Array, uvs: Array, pair: int, slot: int, abr: int) -> void:
	var pts := PackedVector2Array()
	for p in points:
		pts.append(Vector2(p))
	var textured := pair >= 0
	var tex: Texture2D = texture(pair) if textured else null
	if textured and tex == null:
		textured = false
	var cols := PackedColorArray()
	var unit := 1.0 / 128.0 if textured else 1.0 / 255.0
	var blend := BLEND_OPAQUE
	var alpha := 1.0
	var weight := 1.0
	if abr >= 0:
		match abr & 3:
			0:
				alpha = 0.5
			1:
				blend = BLEND_ADD
			2:
				blend = BLEND_SUB
			3:
				blend = BLEND_ADD
				weight = 0.25
	for c in colours:
		var rgb: Vector3i = c
		cols.append(Color(rgb.x * unit * weight, rgb.y * unit * weight, rgb.z * unit * weight, alpha))
	var uv := PackedVector2Array()
	if textured:
		var size: Vector2 = _page_size[pair]
		for uvp in uvs:
			var t: Vector2i = uvp
			uv.append(Vector2(t.x / size.x, t.y / size.y))
	_records.append({"line": false, "slot": slot, "order": _order, "blend": blend, "pts": pts, "cols": cols, "uvs": uv, "tex": tex})
	_order += 1


## A line between two picture points, with a colour at each end (both Vector3i in the console's 0..255 units).
func add_line(a: Vector2, b: Vector2, colour_a: Vector3i, colour_b: Vector3i, slot: int, abr: int) -> void:
	var blend := BLEND_OPAQUE
	var alpha := 1.0
	if abr >= 0:
		match abr & 3:
			0:
				alpha = 0.5
			1:
				blend = BLEND_ADD
			2:
				blend = BLEND_SUB
			_:
				blend = BLEND_ADD
	var ca := Color(colour_a.x / 255.0, colour_a.y / 255.0, colour_a.z / 255.0, alpha)
	var cb := Color(colour_b.x / 255.0, colour_b.y / 255.0, colour_b.z / 255.0, alpha)
	_records.append({"line": true, "slot": slot, "order": _order, "blend": blend, "pts": PackedVector2Array([a, b]),
		"cols": PackedColorArray([ca, cb]), "uvs": PackedVector2Array(), "tex": null})
	_order += 1


## Sorts the records and shows them: runs of one blend mode go to child layers in order.
func present() -> void:
	_records.sort_custom(func(a, b) -> bool:
		if a["slot"] != b["slot"]:
			return a["slot"] > b["slot"]
		return a["order"] > b["order"])
	var run := 0
	var current := -1
	for record in _records:
		if record["blend"] != current:
			current = record["blend"]
			if run >= _layers.size():
				var layer := Layer.new()
				add_child(layer)
				_layers.append(layer)
			var layer_node = _layers[run]
			layer_node.set_blend(current)
			layer_node.records = []
			run += 1
		_layers[run - 1].records.append(record)
	for i in _layers.size():
		var layer_node = _layers[i]
		if i >= run:
			layer_node.records = []
		layer_node.queue_redraw()
	_records.clear()


## The page texture for a pair index, loaded once from the baked pages. Null when the page is not baked.
func texture(pair: int) -> Texture2D:
	if _pages.has(pair):
		return _pages[pair]
	var path := PAGE_DIR + "pair_%02d.png" % pair
	var image := Image.load_from_file(path)
	if image == null:
		_pages[pair] = null
		return null
	var tex := ImageTexture.create_from_image(image)
	_pages[pair] = tex
	_page_size[pair] = Vector2(image.get_width(), image.get_height())
	return tex


## A page copied at run time (the picture of the scene, not a baked page): the image is the pair's texture for this picture.
func set_page(pair: int, image: Image) -> void:
	_pages[pair] = ImageTexture.create_from_image(image)
	_page_size[pair] = Vector2(image.get_width(), image.get_height())


## The number of layers in use this frame (for tests).
func layer_count() -> int:
	return _layers.size()
