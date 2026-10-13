extends Node2D
## The background of a flagged text box (the text channel's flag 0x20) and its end arrow (the choice box the flag 0x08 opens when the
## box's text is done). The box is two Gouraud quads of one hexagon around the box's rectangle (the routine at 0x800391E4 and
## the box layout code lays them out; the renderer draws them): the top corners 8 above the box, the
## side points 8 out at half its height, the bottom corners 8 below. Both quads are coloured 0xA0A0A0 at the outer corners and the
## neutral 0x808080 at the sides, and they are drawn in GsALON | GsATWO, the subtractive semi-transparency: the panel takes its colour
## off what is under it, so a dark picture reads as black. The box has no slide of its own: its glyphs come in one by one (glyph_fx.gd).
##
## The end arrow is the sprite Dialog_OpenChoice puts at (x + width - 16, y + height - 16) once the text is done: the blinking frames of
## assets/screens/dialog_arrow/ (tools/extract.py bake_dialog_arrow). It shows `arrow_after` frames after the node is set up, when the
## caller says the box's text is done (the game sets the done flag after the last glyph step, two frames per glyph).

const ARROW_DIR := "res://assets/screens/dialog_arrow/"
const TOP_COLOUR := Color(160.0 / 255.0, 160.0 / 255.0, 160.0 / 255.0, 1.0)     # 0xA0A0A0, the outer corners
const SIDE_COLOUR := Color(128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, 1.0)    # COLOR_RGB24_NEUTRAL_GREY, the side points
const CORNER_OUT := 8.0                                                          # the six points lie 8 pixels outside the box

var box := Rect2()
var arrow_after := -1          # frames until the arrow shows; -1 when the box has no arrow
var arrow: Sprite2D
var arrow_layout: Dictionary = {}
var arrow_textures: Array = []
var ticks := 0                 # frames since the box was set up (the arrow's blink counts from here)


## Sets the box up: the rectangle of the text (the origin and the size of the box as the game gives them), the material of the
## picture (the screen's sharp material; the panel itself is untextured), and whether the box has the arrow.
func setup(rect: Rect2, arrow_material: Material = null, with_arrow := false) -> void:
	box = rect
	_build_panel()
	if with_arrow:
		_build_arrow(arrow_material)


## Shows the arrow after `frames` frames (the box's text takes two frames a glyph to come in; the caller counts its glyphs).
func show_arrow_after(frames: int) -> void:
	arrow_after = maxi(frames, 0)
	if arrow != null:
		arrow.visible = false


func _build_panel() -> void:
	var x := roundf(box.position.x)
	var y := roundf(box.position.y)
	var w := roundf(box.size.x)
	var h := roundf(box.size.y)
	var mid := y + floorf(h / 2.0)
	var bottom := y + h
	# the top quad: the top edge (its corners 8 above the box) down to the side points; the bottom quad mirrors it below the side points
	_quad(PackedVector2Array([Vector2(x, y - CORNER_OUT), Vector2(x + w, y - CORNER_OUT), Vector2(x + w + CORNER_OUT, mid), Vector2(x - CORNER_OUT, mid)]))
	_quad(PackedVector2Array([Vector2(x, bottom + CORNER_OUT), Vector2(x + w, bottom + CORNER_OUT), Vector2(x + w + CORNER_OUT, mid), Vector2(x - CORNER_OUT, mid)]))


## One Gouraud quad: `points` are the outer edge (two points) then the side edge (two points), in the game's vertex order
## v0 v1 v3 v2 so the polygon is the quad. The outer corners take the top colour and the side points the neutral one.
func _quad(points: PackedVector2Array) -> void:
	var sub := Polygon2D.new()
	sub.polygon = PackedVector2Array([points[0], points[1], points[2], points[3]])
	sub.vertex_colors = PackedColorArray([TOP_COLOUR, TOP_COLOUR, SIDE_COLOUR, SIDE_COLOUR])
	var mode := CanvasItemMaterial.new()
	mode.blend_mode = CanvasItemMaterial.BLEND_MODE_SUB
	sub.material = mode
	add_child(sub)


func _build_arrow(arrow_material: Material) -> void:
	var json = JSON.parse_string(FileAccess.get_file_as_string(ARROW_DIR + "layout.json")) if FileAccess.file_exists(ARROW_DIR + "layout.json") else null
	if typeof(json) != TYPE_DICTIONARY:
		return
	arrow_layout = json
	for i in (json["frames"] as Array).size():
		var path := ARROW_DIR + "%d.png" % i
		var image := Image.load_from_file(path) if FileAccess.file_exists(path) else null
		arrow_textures.append(ImageTexture.create_from_image(image) if image != null else null)
	arrow = Sprite2D.new()
	arrow.centered = false
	arrow.material = arrow_material
	arrow.visible = false
	add_child(arrow)


func _physics_process(_delta: float) -> void:
	ticks += 1
	if arrow == null or arrow_after < 0 or ticks < arrow_after:
		return
	var sequence: Array = arrow_layout["sequence"]
	var duration := maxi(int(arrow_layout["duration"]), 1)
	var index: int = int(sequence[int((ticks - arrow_after) / duration) % sequence.size()])
	if arrow_textures[index] == null:
		return
	arrow.visible = true
	arrow.texture = arrow_textures[index]
	var o: Dictionary = arrow_layout["frames"][index]
	arrow.position = Vector2(box.position.x + box.size.x - 16 + int(o["x"]), box.position.y + box.size.y - 16 + int(o["y"]))
