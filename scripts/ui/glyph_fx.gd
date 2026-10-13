extends Polygon2D
## The way a text box brings a glyph in (the routine at 0x80039AFC, drawn by the routine at 0x80035E20's type 2): the glyph is a four-cornered quad that
## starts stretched (right edge 32 pixels out, left corner dropped 8) and shrinks to its size over 16 frames while its colour
## fades in from the left corners (8 frames, +16 of 128 each), then from the right corners (8 frames). Added to what is behind it.
## When it ends the plain sprite replaces it.

var sprite: Sprite2D
var delay := 0
var small := false
var spawned := 0
var stretch := 32
var left := 0
var right := 0
var second := false
var started := false
var size := 16.0
var height := 16.0


func _ready() -> void:
	var atlas := sprite.texture as AtlasTexture
	texture = atlas.atlas
	size = 8.0 if small else 16.0
	height = 12.0 if small else 16.0
	var region := atlas.region
	uv = PackedVector2Array([region.position, region.position + Vector2(region.size.x, 0), region.end, region.position + Vector2(0, region.size.y)])
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = add
	position = sprite.position
	sprite.visible = false
	visible = false


func _physics_process(_delta: float) -> void:
	if spawned < delay:
		spawned += 1
		return
	visible = true
	if not started:
		started = true
		stretch = 32
		left = 0
		right = 0
	stretch -= 2
	if not second:
		left += 16
		if left >= 128:
			left = 128
			stretch = 16
			second = true
	else:
		right += 16
		if right >= 128:
			sprite.visible = true
			queue_free()
			return
	polygon = PackedVector2Array([Vector2(0, stretch >> 2), Vector2(size + stretch, 0), Vector2(size + stretch, height), Vector2(0, height)])
	var l := float(left) / 128.0
	var r := float(right) / 128.0
	vertex_colors = PackedColorArray([Color(l, l, l), Color(r, r, r), Color(r, r, r), Color(l, l, l)])
