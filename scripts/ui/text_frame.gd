extends RefCounted
## A framed rectangle of any size, drawn from one texture cut into nine pieces: the four corners keep their size, the edges
## stretch along their length and the middle is the fill. `src` is the piece of the texture that holds the frame, and
## `border` gives the frame's thickness in source pixels as Vector4(left, top, right, bottom).

static func draw(canvas: CanvasItem, texture: Texture2D, src: Rect2, rect: Rect2, border: Vector4, fill := true) -> void:
	var l := border.x
	var t := border.y
	var r := border.z
	var b := border.w
	var sw := src.size.x
	var sh := src.size.y
	# destination columns and rows: the corner sizes are the frame's, the middle takes what is left
	var dx := [0.0, l, maxf(l, rect.size.x - r), rect.size.x]
	var dy := [0.0, t, maxf(t, rect.size.y - b), rect.size.y]
	var sx := [0.0, l, sw - r, sw]
	var sy := [0.0, t, sh - b, sh]
	for j in 3:
		for i in 3:
			if i == 1 and j == 1 and not fill:
				continue
			var from := Rect2(src.position + Vector2(sx[i], sy[j]), Vector2(sx[i + 1] - sx[i], sy[j + 1] - sy[j]))
			var to := Rect2(rect.position + Vector2(dx[i], dy[j]), Vector2(dx[i + 1] - dx[i], dy[j + 1] - dy[j]))
			if from.size.x <= 0.0 or from.size.y <= 0.0 or to.size.x <= 0.0 or to.size.y <= 0.0:
				continue
			canvas.draw_texture_rect_region(texture, to, from)
