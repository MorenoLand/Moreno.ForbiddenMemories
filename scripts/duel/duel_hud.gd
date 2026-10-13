extends RefCounted
## Helpers for the duel's readouts and the card panel (duel_scene.gd draws with them).

## Frees the glyph sprites of a laid-out text (GameText.layout's placed list) whose cell lies outside the box, so a text
## never draws past the panel's edges. A glyph is kept when its cell overlaps the box.
static func clip_placed(placed: Array, box: Rect2) -> void:
	for entry in placed:
		var x: float = float(entry["x"])
		var y: float = float(entry["y"])
		var inside := x + 8.0 > box.position.x and x < box.end.x and y + 12.0 > box.position.y and y < box.end.y
		if not inside and entry["sprite"] != null:
			entry["sprite"].queue_free()
			entry["sprite"] = null

## A translucent dark cover over a field card's box: the mark of a monster that has already acted this turn (it can neither
## attack nor change position until the turn ends). The cover does not take the mouse.
static func dim_box(parent: Node, box: Rect2) -> void:
	var cover := ColorRect.new()
	cover.position = box.position
	cover.size = box.size
	cover.color = Color(0.0, 0.0, 0.0, 0.45)
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(cover)
