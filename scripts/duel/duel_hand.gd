extends RefCounted
## The player's hand row as the original lays it out: five slots 60 pixels apart whose first card sits at x 14, on the picture's row
## y 146 (the draw resolution's slot is 0x14E + 60 * i, and its draw slide is 0x140 to the right of that, so the card lands at
## x 14 + 60 * i). A card is 52 x 60 (the frame's extent): the duel card face at that size. The row is drawn over the field in the
## picture's own 320 x 240 space, not through the field camera; the hand view camera only frames the board above it.
##
## The hand is drawn by the scene (duel_scene.gd); this file holds the geometry (the slots, the hit test, the draw slide) and the
## sprite of a card's face so the scene's refresh, cursor and hover code agree.

const FIRST_X := 14            # the first slot's x (the slot 0x14E less the slide's 0x140)
const STEP := 60               # the slot spacing (60 units)
const ROW_Y := 146             # the row's top (0x92)
const CARD_W := 52             # the card's width (the frame's 52 x 60 extent)
const CARD_H := 60
const SLIDE := 320.0           # the draw slide starts this far to the right of the slot (0x140)


## The top-left picture point of hand slot i.
static func place(i: int) -> Vector2:
	return Vector2(FIRST_X + STEP * i, ROW_Y)


## The picture box a card in slot i covers (the card's own size, without the spacing).
static func box(i: int) -> Rect2:
	return Rect2(place(i), Vector2(CARD_W, CARD_H))


## The hand slot under a point of the picture, or -1. The gap between two cards belongs to the card on its left, so the hover
## never drops out between cards; points off the row, or past the last card, are -1.
static func index_at(local: Vector2, count: int) -> int:
	if local.y < ROW_Y or local.y >= ROW_Y + CARD_H:
		return -1
	var i := int(floor((local.x - FIRST_X) / float(STEP)))
	if i < 0 or i >= count:
		return -1
	return i


## Where a card dealt into slot i is while its slide runs: `progress` runs 0 (at the slide's start, SLIDE to the right) to 1 (in place).
## The slide is a sine ease over a quarter turn of phase, as the draw slide is.
static func slide_position(i: int, progress: float) -> Vector2:
	var t := clampf(progress, 0.0, 1.0)
	return place(i) + Vector2(SLIDE * (1.0 - sin(t * PI * 0.5)), 0.0)


## A card face sprite for the hand: the picture scaled to the 52 x 60 slot. texture is the card's face (the same picture the field
## quads use). at is the slot's top-left; material is the screen's sharp pixel material.
static func face(texture: Texture2D, at: Vector2, material: Material) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = texture
	sprite.position = at
	if texture != null:
		var size := texture.get_size()
		sprite.scale = Vector2(CARD_W / maxf(size.x, 1.0), CARD_H / maxf(size.y, 1.0))
	sprite.material = material
	return sprite


## The destination rules of a hand card (the hand actions' rules, duel_scene.gd's destination mode). A monster goes to the monster row only:
## an empty cell, or an occupied one for a chain. A magic, ritual, equip or trap that is set goes to the magic and trap row, into an
## empty cell; an equip alone cannot go to the monster row. A face-up magic or ritual is not placed at all: it resolves where it is held.
const ROW_MONSTERS := 0       # the cursor's row in the destination: the player's monster row
const ROW_SPELLS := 1         # the magic and trap row

## True for a card that is set on the magic and trap row (a trap, an equip, or a magic or ritual set face-down).
static func goes_to_spell_row(is_monster: bool, card_type: String, set_face_down: bool) -> bool:
	if is_monster:
		return false
	if card_type == "Trap" or card_type == "Equip":
		return true
	return set_face_down           # a face-up magic or ritual resolves at once; a set one is placed on the row


## The row a hand card can be placed into, from its kind and whether it is set: the monster row or the spell row.
static func row_for(is_monster: bool, card_type: String, set_face_down: bool) -> int:
	return ROW_SPELLS if goes_to_spell_row(is_monster, card_type, set_face_down) else ROW_MONSTERS


## Whether the cursor's row takes a card of that kind and face: a card on the wrong row cannot be placed (the cannot sound plays).
static func accepts(is_monster: bool, card_type: String, set_face_down: bool, cursor_row: int) -> bool:
	return row_for(is_monster, card_type, set_face_down) == cursor_row
