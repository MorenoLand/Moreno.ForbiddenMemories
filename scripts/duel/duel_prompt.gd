extends RefCounted
## The field activation prompt: a card in the magic and trap row that the player confirms asks YES or NO beside the card. The original
## draws two option sprites under the card, YES on the left (x - 8) and NO on the right (x + 60), 30 pixels below the card's top; the
## left one is the one the cursor starts on and the one that confirms the activation. The labels here are the game's own YES and NO
## letters (the glyphs the text bank uses), and the choice shows the story's choice bar: a yellow additive band, darker at its edges.
##
## The geometry is shared by the drawing and the hit test (the mouse hovers and clicks the labels), so both read it from here.

const YES_DX := -8.0
const NO_DX := 60.0
const LABEL_DY := 30.0
const LABEL_W := 24.0          # three 8-pixel glyphs
const NO_W := 16.0             # two glyphs
const BAR_H := 10.0


## The label origins of the two options under a card's box (the box's top-left is the card's place on the picture).
static func origins(card_at: Vector2) -> Array:
	return [card_at + Vector2(YES_DX, LABEL_DY), card_at + Vector2(NO_DX, LABEL_DY)]


## The hit boxes of the YES and NO labels (the label plus a pixel of margin each way), in picture coordinates.
static func hit_boxes(card_at: Vector2) -> Array:
	var at := origins(card_at)
	return [Rect2(at[0] - Vector2(1, 1), Vector2(LABEL_W + 2, BAR_H)), Rect2(at[1] - Vector2(1, 1), Vector2(NO_W + 2, BAR_H))]


## The choice bar behind the selected option (choice 0 is YES, 1 is NO), at its label's origin: the story's choice bar.
static func bar(card_at: Vector2, choice: int) -> Polygon2D:
	var at: Vector2 = origins(card_at)[choice]
	var width := LABEL_W if choice == 0 else NO_W
	var top := at.y - 2.0
	var bar_node := Polygon2D.new()
	bar_node.polygon = PackedVector2Array([Vector2(at.x - 2.0, top), Vector2(at.x - 2.0 + width + 4.0, top),
			Vector2(at.x - 2.0 + width + 4.0, top + BAR_H), Vector2(at.x - 2.0, top + BAR_H)])
	bar_node.vertex_colors = PackedColorArray([Color(0.19, 0.19, 0.0), Color(0.75, 0.75, 0.0), Color(0.75, 0.75, 0.0), Color(0.19, 0.19, 0.0)])
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bar_node.material = add
	return bar_node
