extends Polygon2D
## The way a text box lets a glyph go. A page clear (`choice` false; the routine at 0x80039BE0, which the text state 2 starts on a
## button press, the F8 1A close and the page overflow): the glyph's left corners darken from full to black over 8 frames, then its
## right corners over 8 more, and it is gone after 16 frames. A choice clear (`choice` true; the routine at 0x80039C94, which the
## text state 3 starts when a choice is confirmed): the glyph first waits (1 + x / 16 + y / 8 frames, from its pen position in the box),
## then its additive colour rises 4 of 128 a frame for 16 frames and it is gone. The additive lane follows the glyph_fx convention, where
## 128 is full. The rise to 0x40 and the removal at its end are the game's; how the rise reads on screen is the port's reading.

var sprite: Sprite2D
var choice := false
var local := Vector2.ZERO     # the glyph's pen position in its box (the entry's x and y, before the glyph's advance)
var total := 16               # frames until the glyph is gone
var frames_done := 0
var delay := 0


func _ready() -> void:
	var tex := sprite.texture
	var atlas := tex as AtlasTexture
	texture = atlas.atlas if atlas != null else tex
	var region := atlas.region if atlas != null else Rect2(Vector2.ZERO, tex.get_size())
	uv = PackedVector2Array([region.position, region.position + Vector2(region.size.x, 0), region.end, region.position + Vector2(0, region.size.y)])
	polygon = PackedVector2Array([Vector2.ZERO, Vector2(region.size.x, 0), region.size, Vector2(0, region.size.y)])
	position = sprite.position
	vertex_colors = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	if choice:
		delay = 1 + (int(local.x) >> 4) + (int(local.y) >> 3)
		total = delay + 16
		var add := CanvasItemMaterial.new()
		add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = add
		visible = false
		sprite.visible = true
	else:
		total = 16
		sprite.visible = false


func _physics_process(_delta: float) -> void:
	# the sprite can be freed under the exit (a clear that did not wait for it): then there is nothing left to show, and the exit goes too
	if is_queued_for_deletion():
		return
	if not is_instance_valid(sprite) or sprite.is_queued_for_deletion():
		queue_free()
		return
	frames_done += 1
	var n := frames_done
	if not choice:
		var left := clampf((128.0 - 16.0 * n) / 128.0, 0.0, 1.0) if n <= 8 else 0.0
		var right := clampf((128.0 - 16.0 * (n - 8)) / 128.0, 0.0, 1.0) if n > 8 else 1.0
		vertex_colors = PackedColorArray([Color(left, left, left), Color(right, right, right), Color(right, right, right), Color(left, left, left)])
		if n >= 16:
			queue_free()
		return
	if n <= delay:
		sprite.visible = true
		return
	# the sprite stays up while the glow rises; the glyph is removed with its last step
	visible = true
	var j := n - delay
	var glow := clampf(4.0 * j / 128.0, 0.0, 1.0)
	vertex_colors = PackedColorArray([Color(glow, glow, glow), Color(glow, glow, glow), Color(glow, glow, glow), Color(glow, glow, glow)])
	if j >= 16:
		sprite.visible = false
		queue_free()
