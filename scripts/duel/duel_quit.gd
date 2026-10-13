extends Node2D
## The quit confirm of a spectator match (F3, duel_spectator.gd): the game's string 0x22 (QUIT DUEL? / NO / YES) over the board, in a
## box with the story's choice bar behind the selected option. NO is the option the cursor starts on. hit() says which option a point of
## the picture is on, for the mouse.

const STRING_ID := 0x22
const ORIGIN := Vector2(100, 96)      # the string's first line; the options are the lines below it
const ADVANCE := Vector2(8, 12)
const BOX := Rect2(92, 86, 136, 58)
const OPTION_LINE := [1, 2]           # NO and YES: their lines in the string
const OPTION_WIDTH := [28.0, 36.0]    # " NO" and " YES" in 8-pixel cells, with the bar's margin
const BAR_H := 10.0

var choice := 0                       # 0 NO, 1 YES
var bar: Polygon2D


## Draws the box and the string with the game's text (`text`: game_text.gd's GameText), with the material of the picture.
func setup(text, material: Material) -> void:
	var fill := ColorRect.new()
	fill.color = Color(0.02, 0.03, 0.08)
	fill.position = BOX.position
	fill.size = BOX.size
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fill)
	for edge in [Rect2(BOX.position, Vector2(BOX.size.x, 1)), Rect2(BOX.position + Vector2(0, BOX.size.y - 1), Vector2(BOX.size.x, 1)),
			Rect2(BOX.position, Vector2(1, BOX.size.y)), Rect2(BOX.position + Vector2(BOX.size.x - 1, 0), Vector2(1, BOX.size.y))]:
		var line := ColorRect.new()
		line.color = Color(0.8, 0.6, 0.3)
		line.position = edge.position
		line.size = edge.size
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(line)
	bar = Polygon2D.new()
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bar.material = add
	bar.vertex_colors = PackedColorArray([Color(0.19, 0.19, 0.0), Color(0.75, 0.75, 0.0), Color(0.75, 0.75, 0.0), Color(0.19, 0.19, 0.0)])
	add_child(bar)
	text.layout(self, text.string_bytes(STRING_ID), ORIGIN, ADVANCE, 0, material, true)
	choose(0)


## The choice bar moves to option `which` (0 NO, 1 YES): a yellow additive band behind its line, darker at the edges.
func choose(which: int) -> void:
	choice = clampi(which, 0, 1)
	var top := _line_y(choice) - 2.0
	var left := ORIGIN.x - 2.0
	var width: float = OPTION_WIDTH[choice]
	bar.polygon = PackedVector2Array([Vector2(left, top), Vector2(left + width, top), Vector2(left + width, top + BAR_H),
			Vector2(left, top + BAR_H)])


## The option (0 NO, 1 YES) under a point of the picture, or -1.
func hit(local: Vector2) -> int:
	for option in 2:
		var rect := Rect2(ORIGIN.x - 2.0, _line_y(option) - 2.0, OPTION_WIDTH[option], BAR_H)
		if rect.has_point(local):
			return option
	return -1


func _line_y(option: int) -> float:
	return ORIGIN.y + ADVANCE.y * float(OPTION_LINE[option])
