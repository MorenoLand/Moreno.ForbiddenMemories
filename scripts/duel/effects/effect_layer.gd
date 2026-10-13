extends Node2D
## One run of effect primitives that share a blend mode (see effect_canvas.gd). The records are drawn in the order the canvas
## sorted them; each is a triangle or a quad (drawn as the console draws it, as the triangles 0-1-2 and 1-2-3), or a line.

const Canvas := preload("res://scripts/duel/effects/effect_canvas.gd")

var records: Array = []
var blend := Canvas.BLEND_OPAQUE
var _blend_set := -1


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


## Sets the blend mode of this run (MIX, ADD or SUB), once per change.
func set_blend(mode: int) -> void:
	if mode == _blend_set:
		return
	_blend_set = mode
	var material := CanvasItemMaterial.new()
	match mode:
		Canvas.BLEND_ADD:
			material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		Canvas.BLEND_SUB:
			material.blend_mode = CanvasItemMaterial.BLEND_MODE_SUB
		_:
			material.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX
	self.material = material


func _draw() -> void:
	for record in records:
		var pts: PackedVector2Array = record["pts"]
		var cols: PackedColorArray = record["cols"]
		var uvs: PackedVector2Array = record["uvs"]
		var tex: Texture2D = record["tex"]
		if record["line"]:
			draw_polyline_colors(pts, cols, 1.0, false)
			continue
		_tri(pts, cols, uvs, tex, 0, 1, 2)
		if pts.size() == 4:
			_tri(pts, cols, uvs, tex, 1, 2, 3)


func _tri(pts: PackedVector2Array, cols: PackedColorArray, uvs: PackedVector2Array, tex: Texture2D, a: int, b: int, c: int) -> void:
	var p := PackedVector2Array([pts[a], pts[b], pts[c]])
	var k := PackedColorArray([cols[a if cols.size() > 1 else 0], cols[b if cols.size() > 1 else 0], cols[c if cols.size() > 1 else 0]])
	if tex == null:
		draw_polygon(p, k)
	else:
		draw_polygon(p, k, PackedVector2Array([uvs[a], uvs[b], uvs[c]]), tex)
