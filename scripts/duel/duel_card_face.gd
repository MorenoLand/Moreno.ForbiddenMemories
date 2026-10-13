extends RefCounted
## The face of a card on the duel field, composed the way the game's card routines layer it: the frame of the card's kind (its
## colour: monster gold, magic and equip green, trap purple, ritual blue) on a dark window that the picture covers; the card's picture,
## 40 x 32 at (6, 6); then for a monster the sword and shield icon and the ATK and DEF digits (8 x 8 cells, four columns from x 14, ATK
## at y 40 and DEF at y 48, the leading zeros left blank), or for a spell or trap its label (32 x 16 at (10, 40)). A face-down card
## shows its back instead (the same 52 x 60 size). The parts are baked by tools/extract.py (bake_duel_card_face) into
## assets/screens/duel_card/, with the layout in layout.json. The field quad (duel_field_3d.gd) maps the whole face onto its 51 x 59 card.

const DIR := "res://assets/screens/duel_card/"
const FACE_SIZE := Vector2i(52, 60)
const PICTURE_AT := Vector2i(6, 6)
const ICON_AT := Vector2i(5, 40)
const LABEL_AT := Vector2i(10, 40)
const LABEL_SIZE := Vector2i(32, 16)
const ICON_SIZE := Vector2i(8, 16)
const DIGIT_SIZE := Vector2i(8, 8)
const STAT_X := 14            # the first digit column; the four columns are eight pixels apart (thousands first)
const ATK_Y := 40
const DEF_Y := 48
const BLANK_DIGIT := 10       # the cell the decimal encoding leaves for a leading zero

static var _images: Dictionary = {}
static var _faces: Dictionary = {}


## The kind of a card's face from its type: "monster", "magic", "equip", "trap" or "ritual" (anything else is a monster).
static func kind_of(type_name: String) -> String:
	match type_name:
		"Magic":
			return "magic"
		"Equip":
			return "equip"
		"Trap":
			return "trap"
		"Ritual":
			return "ritual"
	return "monster"


## The face-up card: frame, picture, then the monster's stats or the spell's label. atk and def are used for a monster only.
## picture is the card's picture at its BAKED size (ModArt.base_image: never the HD copy, whose pixels are not the face's 40 x 32 cells);
## picture_key names it for the cache. The face is always FACE_SIZE, so the HD art on or off gives the same layout and the same pixels.
static func face(kind: String, picture: Image, atk: int, def: int, picture_key := "") -> Texture2D:
	var key := "%s|%s|%d|%d" % [kind, picture_key, atk, def]
	if _faces.has(key):
		return _faces[key]
	var out := _image("frame_" + kind).duplicate()
	if picture != null:
		var art := picture.duplicate()
		art.convert(Image.FORMAT_RGBA8)
		out.blend_rect(art, Rect2i(Vector2i.ZERO, art.get_size()), PICTURE_AT)
	if kind == "monster":
		out.blend_rect(_image("icon"), Rect2i(Vector2i.ZERO, ICON_SIZE), ICON_AT)
		_digits(out, atk, ATK_Y)
		_digits(out, def, DEF_Y)
	else:
		out.blend_rect(_image("label_" + kind), Rect2i(Vector2i.ZERO, LABEL_SIZE), LABEL_AT)
	var texture := ImageTexture.create_from_image(out)
	_faces[key] = texture
	return texture


## The back of a face-down card of a kind (the same picture for every kind).
static func back(kind: String) -> Texture2D:
	var key := "back|" + kind
	if not _faces.has(key):
		_faces[key] = ImageTexture.create_from_image(_image("back_" + kind))
	return _faces[key]


## Four digit cells of a value (clamped to 0 to 9999) on a row: the leading zeros are blank, the units digit is always shown.
static func _digits(out: Image, value: int, row: int) -> void:
	var text := "%04d" % clampi(value, 0, 9999)
	var leading := true
	for column in 4:
		var digit := text.unicode_at(column) - 48
		if leading and digit == 0 and column < 3:
			continue
		leading = false
		out.blend_rect(_image("digit_%d" % digit), Rect2i(Vector2i.ZERO, DIGIT_SIZE), Vector2i(STAT_X + 8 * column, row))


static func _image(name: String) -> Image:
	if not _images.has(name):
		var image := Image.load_from_file(DIR + name + ".png")
		if image == null:
			image = Image.create(FACE_SIZE.x, FACE_SIZE.y, false, Image.FORMAT_RGBA8)
		image.convert(Image.FORMAT_RGBA8)
		_images[name] = image
	return _images[name]


## The numbered card of the two-player duel (the reference's draw list: the plain frame with the card's number in 12 x 16 digits,
## the tens 15 pixels and the units 27 pixels right of the card's left edge, 15 below its top). The card's kind is not shown; the
## frame is the same for every card. back: the card's back with the number (the centre step's face-down card), else the plain frame.
static func numbered(number: int, back_card: bool) -> Texture2D:
	var key := "numbered|%d|%s" % [number, str(back_card)]
	if _faces.has(key):
		return _faces[key]
	var base_path := DIR + ("back_monster.png" if back_card else "numbered.png")
	var base := Image.load_from_file(base_path)
	if base == null:
		return null
	base.convert(Image.FORMAT_RGBA8)
	var text := "%02d" % clampi(number, 0, 99)
	for k in 2:
		var digit := Image.load_from_file(DIR + "digit_%s_12.png" % text[k])
		if digit == null:
			continue
		digit.convert(Image.FORMAT_RGBA8)
		base.blend_rect(digit, Rect2i(Vector2i.ZERO, Vector2i(12, 16)), Vector2i(15 + 12 * k, 15))
	var texture := ImageTexture.create_from_image(base)
	_faces[key] = texture
	return texture


## The arrow of a choice (the centre step's green arrows): 16 x 16, left or right.
static func arrow(right: bool) -> Texture2D:
	var key := "arrow|%s" % str(right)
	if _faces.has(key):
		return _faces[key]
	var image := Image.load_from_file(DIR + ("arrow_right.png" if right else "arrow_left.png"))
	if image == null:
		return null
	var texture := ImageTexture.create_from_image(image)
	_faces[key] = texture
	return texture

