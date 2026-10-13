extends RefCounted
## The card view's text box and pieces, shared by the Library and the Build Deck viewers (the card view of the Library and of the
## duel's card viewer, the routine at 0x800283F4). The box's text is the game's own layout: the text bank's strings 3 (a monster) and 4
## (a spell, trap, ritual or equip), which the card's escapes fill in:
##   F8 00 op   the card's kind (op 0x00 kind 0: the race icon, or the race's name with 0x80), a guardian star (op 1 and 2: its icon,
##              or its name with 0x80; a star 0 has neither), the card text (op 0x40) and the card's name (op 0x20)
##   F8 01 n    the line moves down n (x back to 0); FE a new line; 0 a blank cell; any other glyph a letter
## An icon entry is a code below 0x22: the races and kinds are codes 0 to 23 (race_icons/), the stars 0x18 to 0x21 (star_icons/).
## The box is 168 x 192; a glyph starts a new line when the pen is past its width, and the text is cut at the box's bottom (no card's
## text needs a second page at this size, so no page wait is drawn).
## The stats (ATK and DEF with their labels, the level stars) and the attribute icon sit at the positions the viewers always used
## (box-relative; approximated, as the game's own stat positions are not in the text bank).

const CARD_UI := "res://assets/screens/card_ui/"
const STAR_ICONS := "res://assets/screens/star_icons/"
const RACE_ICONS := "res://assets/screens/race_icons/"
const BOX_SIZE := Vector2(168, 192)
const LINE := 12
const GLYPH_ADVANCE := 8
const ICON_ADVANCE := 16
const LAYOUT_MONSTER := 3       # the text bank string of a monster's layout
const LAYOUT_OTHER := 4         # the text bank string of a spell, trap, ritual or equip
const RACE_NAME_BASE := 0x8300  # string 0x8300 + the card type: the race or kind name
const STAR_ICON_BASE := 0x17    # icon code 0x17 + the star's id (1 to 10)
const STAR_NAME_BASE := 0x8300  # string 0x8300 + 0x17 + the star's id: the star's name
const SPECIAL_TYPES := ["Magic", "Equip", "Trap", "Ritual"]
const RACE_TYPES := ["Dragon", "Spellcaster", "Zombie", "Warrior", "Beast-Warrior", "Beast", "Winged Beast", "Fiend", "Fairy",
		"Insect", "Dinosaur", "Reptile", "Fish", "Sea Serpent", "Machine", "Thunder", "Aqua", "Pyro", "Rock", "Plant",
		"Magic", "Trap", "Ritual", "Equip"]   # the card type numbers: CARD_TYPE_DRAGON 0 .. CARD_TYPE_EQUIP 23
const STARS := {"": 0, "Mars": 1, "Jupiter": 2, "Saturn": 3, "Uranus": 4, "Pluto": 5, "Neptune": 6, "Mercury": 7, "Sun": 8,
		"Moon": 9, "Venus": 10}
const STAR_FILES := ["", "mars", "jupiter", "saturn", "uranus", "pluto", "neptune", "mercury", "sun", "moon", "venus"]
const ATTRIBUTE_AT := Vector2(0x6E, 0xD)
const ATK_AT := Vector2(72, 158)          # the ATK label; its digits right-aligned from (97, 157)
const DEF_AT := Vector2(72, 170)          # the DEF label; its digits from (97, 171)
const LEVEL_AT := Vector2(119, 32)        # the level stars, the first at the right and each nine pixels left of the last
const DIGIT_ADVANCE := 6
const SYMBOLS := {" ": 0, "<": 84, ">": 81, "/": 68, ".": 11, "'": 27, ",": 31, "-": 48, "#": 60, "&": 67}   # the font's symbol glyphs

var text                       # the GameText engine (strings, glyphs and the font's ramps), loaded
var sharp: Material            # the screen's sharpening material for the pieces and text
var glyph_codes: Dictionary = {}   # Shift-JIS code -> glyph index
var ui_layout: Dictionary = {}
var ui_cache: Dictionary = {}
var icon_cache: Dictionary = {}
var _parent: Node2D            # the text's layer: the box's own
var _icons: Node2D             # the stat and attribute pieces' layer
var _id := 0
var _race := 0
var _stars: Array = [0, 0]
var _pen := Vector2.ZERO


func _init(game_text, material: Material) -> void:
	text = game_text
	sharp = material
	for i in text.glyphs.size():
		var sjis := int(text.glyphs[i]["sjis"])
		if not glyph_codes.has(sjis):
			glyph_codes[sjis] = i
	if FileAccess.file_exists(CARD_UI + "layout.json"):
		var data = JSON.parse_string(FileAccess.get_file_as_string(CARD_UI + "layout.json"))
		if typeof(data) == TYPE_DICTIONARY:
			ui_layout = data


## The card's box: the text at its layer `text_layer` (positioned at the box's top-left by the caller) and the stats, level and
## attribute pieces at `icon_layer`. Both are cleared first. `data` is the card's record (cards.json).
func build(text_layer: Node2D, icon_layer: Node2D, id: int, data: Dictionary) -> void:
	_clear(text_layer)
	_clear(icon_layer)
	_parent = text_layer
	_icons = icon_layer
	_id = id
	_race = RACE_TYPES.find(str(data.get("type", "")))
	if _race < 0:
		_race = 0
	var special := SPECIAL_TYPES.has(str(data.get("type", "")))
	_stars = [STARS.get(str(data.get("guardian_star_1", "")), 0), STARS.get(str(data.get("guardian_star_2", "")), 0)]
	_pen = Vector2.ZERO
	_run(text.string_bytes(LAYOUT_OTHER if special else LAYOUT_MONSTER), 0)
	if not special:
		_piece_at("label_atk", ATK_AT)
		_digits(int(data.get("attack", 0)), ATK_AT + Vector2(25, -1))
		_piece_at("label_def", DEF_AT)
		_digits(int(data.get("defense", 0)), DEF_AT + Vector2(25, -1))
		for i in clampi(int(data.get("level", 0)), 0, 12):
			_piece_at("level_star", LEVEL_AT - Vector2(i * 9, 0))
	_piece_at(_attribute_piece(data), ATTRIBUTE_AT)


## The picture's place for a viewer whose box is at `box` (the art is 2 pixels in from the screen's left, at the box's own top
## less the 14 the box sits below it).
static func art_at(box: Vector2) -> Vector2:
	return Vector2(2, box.y - 14)


## A card view ink piece (the name plate, the labels and the digits of the card view, baked with alpha 128 on the inks: see
## tools/extract.py bake_card_ui) split into the texels laid over the frame (opaque) and the inks the frame has taken away
## (alpha 1 where the ink is; its colour is what is subtracted). Returns [opaque, ink], both RGBA8 of the piece's size.
static func split_ink(piece: Image) -> Array:
	piece.convert(Image.FORMAT_RGBA8)
	var opaque := Image.create(piece.get_width(), piece.get_height(), false, Image.FORMAT_RGBA8)
	var ink := Image.create(piece.get_width(), piece.get_height(), false, Image.FORMAT_RGBA8)
	for y in piece.get_height():
		for x in piece.get_width():
			var texel := piece.get_pixel(x, y)
			if texel.a >= 0.99:
				opaque.set_pixel(x, y, texel)
			elif texel.a > 0.0:
				ink.set_pixel(x, y, Color(texel.r, texel.g, texel.b, 1.0))
	return [opaque, ink]


## The card_ui attribute piece: the monster's attribute, or spell and trap for the other cards.
func _attribute_piece(data: Dictionary) -> String:
	match str(data.get("type", "")):
		"Magic", "Equip", "Ritual":
			return "attribute_spell"
		"Trap":
			return "attribute_trap"
	return "attribute_" + str(data.get("attribute", "")).to_lower()


## Runs a layout's bytes from the pen. `depth` bounds the nesting (a card text has none).
func _run(bytes: Array, depth: int) -> void:
	var i := 0
	while i < bytes.size():
		var b: int = bytes[i]
		i += 1
		if b == 0xFF:
			return
		if b == 0xFE:
			_pen = Vector2(0, _pen.y + LINE)
			continue
		if b == 0xF8:
			if i + 1 >= bytes.size():
				return
			var entry := int(bytes[i])
			var operand := int(bytes[i + 1])
			i += 2
			if entry == 1:
				# the line moves by a signed byte and the pen goes back to the box's left (the routine at 0x800380D4)
				_pen = Vector2(0, _pen.y + (operand - 256 if operand >= 128 else operand))
			elif entry == 0 and depth < 4:
				_command(operand, depth)
			continue
		if b >= 0xF0:
			continue
		_glyph(b)


## One F8 00 command: a card field, by its op byte (see the header).
func _command(op: int, depth: int) -> void:
	if (op & 0x40) != 0:
		_run(text.card_description_bytes(_id), depth + 1)
		return
	if (op & 0x20) != 0:
		_run(text.card_name_bytes(_id), depth + 1)
		return
	var kind := op & 0xF
	if kind == 0:
		if (op & 0x80) != 0:
			_run(text.string_bytes(RACE_NAME_BASE + _race), depth + 1)
		else:
			_icon(_race)
		return
	if kind == 1 or kind == 2:
		var star: int = _stars[kind - 1]
		if star == 0:
			return   # a card with no such star: no icon and no name
		if (op & 0x80) != 0:
			_run(text.string_bytes(STAR_NAME_BASE + STAR_ICON_BASE + star), depth + 1)
		else:
			_star_icon(star)


## A race or kind icon at the pen (its code 0 to 23), then the pen moves on past it.
func _icon(code: int) -> void:
	_place(_texture(RACE_ICONS + "%02d.png" % code), _pen)
	_pen.x += ICON_ADVANCE


## A guardian star's icon at the pen, then the pen moves on past it.
func _star_icon(star: int) -> void:
	_place(_texture(STAR_ICONS + STAR_FILES[star] + ".png"), _pen)
	_pen.x += ICON_ADVANCE


## One glyph at the pen: a new line first when the pen is past the box's width, the glyph's sprite (none for the blank glyph 0).
func _glyph(code: int) -> void:
	if _pen.x >= BOX_SIZE.x:
		_pen = Vector2(0, _pen.y + LINE)
	if _pen.y + LINE > BOX_SIZE.y:
		_pen.x += GLYPH_ADVANCE
		return   # cut at the box's bottom
	if code != 0 and code < text.glyphs.size() and int(text.glyphs[code]["sjis"]) != 0:
		var sprite: Sprite2D = text.sprite_for(code, 0, sharp, true)
		sprite.position = _pen
		_parent.add_child(sprite)
	_pen.x += GLYPH_ADVANCE


func _place(texture: Texture2D, at: Vector2) -> void:
	if texture == null:
		return
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = texture
	sprite.material = sharp
	sprite.position = at
	_parent.add_child(sprite)


## A card_ui piece at a box-relative place (its own layout offset is added). A missing piece draws nothing.
func _piece_at(name: String, at: Vector2) -> void:
	var piece := _ui_piece(name)
	if piece.is_empty():
		return
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = piece["texture"]
	sprite.material = sharp
	sprite.position = at + piece["at"]
	_icons.add_child(sprite)


## A stat as four digit cells right-aligned on the value's place: the leading cells are blank.
func _digits(value: int, at: Vector2) -> void:
	var string := str(clampi(value, 0, 9999)).lpad(4, " ")
	for i in string.length():
		if string[i] != " ":
			_piece_at("digit_" + string[i], Vector2(at.x + i * DIGIT_ADVANCE, at.y))


func _ui_piece(name: String) -> Dictionary:
	if ui_cache.has(name):
		return ui_cache[name]
	var piece := {}
	if ui_layout.has(name):
		var entry: Dictionary = ui_layout[name]
		var image := Image.load_from_file(CARD_UI + str(entry["file"]))
		if image != null:
			piece = {"texture": ImageTexture.create_from_image(image), "at": Vector2(float(entry["x"]), float(entry["y"]))}
	ui_cache[name] = piece
	return piece


func _texture(path: String) -> Texture2D:
	if not icon_cache.has(path):
		var image := Image.load_from_file(path)
		icon_cache[path] = ImageTexture.create_from_image(image) if image != null else null
	return icon_cache[path]


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


## The glyph codes of a plain string (letters, digits and the font's symbols; anything else a blank), for the screens' own labels.
func bytes_of(string: String) -> Array:
	var out: Array = []
	for c in string:
		if SYMBOLS.has(c):
			out.append(SYMBOLS[c])
			continue
		var code := c.unicode_at(0)
		var sjis := 0
		if code >= 97 and code <= 122:
			sjis = 0x8281 + code - 97
		elif code >= 65 and code <= 90:
			sjis = 0x8260 + code - 65
		elif code >= 48 and code <= 57:
			sjis = 0x824F + code - 48
		out.append(glyph_codes.get(sjis, 0))
	return out
