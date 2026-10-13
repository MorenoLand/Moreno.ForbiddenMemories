extends Node2D
## the name entry selection frame drawing: four green corner brackets around the cell under the cursor and four green-to-black lines that run
## from its sides to the edges of the screen, all added to what is behind (draw mode abr 1).

var rect := Rect2(22, 24, 16, 16)


func _ready() -> void:
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = add


func _draw() -> void:
	var green := Color(0, 1, 0)
	var x := rect.position.x
	var y := rect.position.y
	var w := rect.size.x
	var h := rect.size.y
	var right := x + w
	draw_polyline(PackedVector2Array([Vector2(x - 1, y + 3), Vector2(x - 1, y - 1), Vector2(x + 3, y - 1)]), green)
	draw_polyline(PackedVector2Array([Vector2(right + 1, y + 3), Vector2(right + 1, y - 1), Vector2(right - 3, y - 1)]), green)
	draw_polyline(PackedVector2Array([Vector2(right + 1, y + h - 3), Vector2(right + 1, y + h + 1), Vector2(right - 3, y + h + 1)]), green)
	draw_polyline(PackedVector2Array([Vector2(x - 1, y + h - 3), Vector2(x - 1, y + h + 1), Vector2(x + 3, y + h + 1)]), green)
	var middle_x: float = x + floorf(w / 2.0)
	var middle_y: float = y + floorf(h / 2.0)
	var black := Color(0, 0, 0)
	_gradient(Vector2(middle_x, y + 2), Vector2(middle_x, 0), green, black)
	_gradient(Vector2(middle_x, y + h - 2), Vector2(middle_x, 192), green, black)
	_gradient(Vector2(x + 2, middle_y), Vector2(0, middle_y), green, black)
	_gradient(Vector2(right - 2, middle_y), Vector2(320, middle_y), green, black)


func _gradient(from: Vector2, to: Vector2, start: Color, end: Color) -> void:
	draw_polyline_colors(PackedVector2Array([from, to]), PackedColorArray([start, end]))
