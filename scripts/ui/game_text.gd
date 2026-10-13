extends RefCounted
## The game's font and strings (assets/screens/text.json and font/ramp_N.png, written by tools/extract.py --text).
## A string is a script of bytes: below 0xF0 a glyph code (an index into the glyph table, which gives the glyph's cell on the
## font page), 0xFE a new line, 0xFF the end, 0xF8 0x0A n the colour ramp n; the other control bytes belong to the dialog system.

const DIR := "res://assets/screens/"
const GLYPH := 16
const RAMPS := 7
const POSITIONAL_OPS := [0x03, 0x04, 0x06, 0x17, 0x18]
const GameState := preload("res://scripts/state/game_state.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")

var glyphs: Array = []
var strings: Dictionary = {}
var ramps: Array = []
var tiny_ramps: Array = []    # the 8 by 8 font per colour (font/tiny_<colour>.png, see tools/extract.py export_text)
var slots: Array = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]   # the text colour slots (zero at boot; a duel result sets them): a colour operand with bit 7 set picks slot n & 15


static var _cache = null      # the parsed text.json, kept for the whole run (it is about 3 MB)
static var _ramp_cache: Array = []
static var _tiny_cache: Array = []


func load_all() -> bool:
	var path := DIR + "text.json"
	if _cache == null:
		if not FileAccess.file_exists(path):
			return false
		_cache = JSON.parse_string(FileAccess.get_file_as_string(path))
	var data = _cache
	if typeof(data) != TYPE_DICTIONARY:
		_cache = null
		return false
	glyphs = data["glyphs"]
	strings = data["strings"]
	if _ramp_cache.size() == RAMPS and _tiny_cache.size() == RAMPS:
		ramps = _ramp_cache.duplicate()
		tiny_ramps = _tiny_cache.duplicate()
		return true
	for i in RAMPS:
		var image := Image.load_from_file(DIR + "font/ramp_%d.png" % i)
		if image == null:
			return false
		ramps.append(ImageTexture.create_from_image(image))
	# the 8 by 8 font is optional (assets baked before it existed have none: its letters then draw nothing)
	for i in RAMPS:
		var tiny_image := Image.load_from_file(DIR + "font/tiny_%d.png" % i)
		if tiny_image != null:
			tiny_ramps.append(ImageTexture.create_from_image(tiny_image))
	_ramp_cache = ramps.duplicate()
	_tiny_cache = tiny_ramps.duplicate()
	return true


func string_bytes(id: int) -> Array:
	return strings.get(str(id), [0xFF])


## A card's name as a byte stream for layout(): the global string 0x8000 + card id (the card's name in the Library, the Build Deck and
## the duel). Card ids are 1 to 722; past the disc's cards the result is the empty string.
func card_name_bytes(id: int) -> Array:
	return string_bytes(0x8000 + id)


## A card's description (its effect or flavour text) as a byte stream for layout(): string 0xD100 + card id, the card text the card
## view and the duel's card panel show. Written by tools/extract.py --text into text.json.
func card_description_bytes(id: int) -> Array:
	return string_bytes(0xD100 + id)


## The glyph code (index into the glyph table) whose Shift-JIS code is `sjis`, or 0.
func code_for_sjis(sjis: int) -> int:
	for i in glyphs.size():
		if int(glyphs[i]["sjis"]) == sjis:
			return i
	return 0


func sjis_of(code: int) -> int:
	return int(glyphs[code]["sjis"]) if code >= 0 and code < glyphs.size() else 0


func sprite_for(code: int, ramp: int, material: Material = null, small := false) -> Sprite2D:
	var cell: Dictionary = glyphs[code]
	var atlas := AtlasTexture.new()
	atlas.atlas = ramps[clampi(ramp, 0, RAMPS - 1)]
	if small:
		atlas.region = Rect2(int(cell["su"]), int(cell["sv"]), 8, 12)
	else:
		atlas.region = Rect2(int(cell["u"]), int(cell["v"]), GLYPH, GLYPH)
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = atlas
	if material != null:
		sprite.material = material
	return sprite


## Lays a string out from `origin`: every glyph advances `advance.x`, a new line adds `advance.y`. Returns [{code, x, y, sprite}]
## (blank glyph 0 keeps its place but has no sprite). The sprites are added to `parent`. `streams` maps a stream offset to the
## bytes a pushed stream (FC) reads, e.g. the player's name at 0x125A.
## `ctx` switches on the positional commands the duel result pages use. It may hold "bank" (a PackedByteArray: the text bank that
## FC and the jump tables read from), "numbers" (RAM address -> value, read by F8 03), "digits" (the ten digit glyph codes),
## "flag_34e" and "flag_355" (the selectors of the jump tables F8 17 and F8 18), "card" (the card whose name F8 00 0x20 prints) and
## "name_id" (the string F8 09 prints). With a ctx, F8 04 switches the cell (1: the 8 by 8 tiny font, 2: the 8 by 12 font; the new line
## moves down the cell's height), F8 06 sets the pen's x, a glyph advances 8 pixels when small or tiny and 16 when large, and the jumps,
## numbers and names are read. Without one the layout is the one the other screens use.
func layout(parent: Node2D, bytes: Array, origin: Vector2, advance: Vector2, ramp: int, material: Material = null, small := false,
		streams: Dictionary = {}, ctx: Dictionary = {}) -> Array:
	var bank = ctx.get("bank")
	if bank == null:
		bank = _local_bank()
	# "cls" is the glyph class of the text box entry (the routine at 0x80035E20 places a class 1 glyph at its y, class 2 at y - 2 and
	# every other class at y + 2): a large box is class 1, a small one class 0 until F8 04 sets it
	var state := {"x": 0.0, "y": 0.0, "color": ramp, "placed": [], "stop": false, "small": small, "tiny": false, "ctx": ctx,
			"bank": bank, "cls": 0 if small else 1, "line": advance.y}
	_run(parent, bytes, origin, advance, material, streams, state, 0)
	return state["placed"]


func _run(parent: Node2D, bytes: Array, origin: Vector2, advance: Vector2, material: Material, streams: Dictionary,
		state: Dictionary, depth: int) -> void:
	var ctx: Dictionary = state["ctx"]
	var i := 0
	while i < bytes.size() and not state["stop"]:
		var b: int = bytes[i]
		i += 1
		if b == 0xFF:
			return
		if b == 0xFE:
			# a new line moves down the line height (the text box's line height: 12 by default, 8 under the 8 by 8 cell, 12 under the 8 by 12)
			state["x"] = 0.0
			state["y"] += state["line"] if not ctx.is_empty() else advance.y
			continue
		if b >= 0xF0:
			if b == 0xF8:
				# the secondary escape: the operand counts of the game's text commands (the data at 0x80090EAC)
				var op: int = bytes[i] if i < bytes.size() else 0
				i += 1
				var operand: int = int(bytes[i]) if i < bytes.size() else 0
				if not ctx.is_empty() and op in POSITIONAL_OPS:
					match op:
						0x03:
							# a number from a RAM address: u32 address, one byte of digit count and flags (the routine at 0x80038148)
							var address := _u32(bytes, i)
							var flags := int(bytes[i + 4]) if i + 4 < bytes.size() else 0
							i += 5
							for code in _number_codes(ctx, address, flags):
								_glyph(parent, code, origin, advance, material, state)
							continue
						0x04:
							# the glyph cell (the routine at 0x800382A8): 8 by 8 for 1 (the tiny font, see _glyph) and 8 by 12 for 2; any other operand
							# leaves the cell as it is
							if operand == 1 or operand == 2:
								state["small"] = true
								state["tiny"] = operand == 1
								state["line"] = 8.0 if operand == 1 else 12.0
								# both cells are class 0 (the text box's class, see "cls" in layout)
								state["cls"] = 0
							i += 1
							continue
						0x06:
							# the pen's x is sixteen bits, read signed (the routine at 0x80038388): the operand 248 255 is -8
							var pen := _u16(bytes, i)
							state["x"] = float(pen - 0x10000 if pen >= 0x8000 else pen)
							i += 2
							continue
						0x17, 0x18:
							# a jump: the table starts at the operand byte after the escape's op (the stream's position when the jump
							# runs), two bytes an entry; the entry for the selector is the new stream, and this one is left
							var flag := int(ctx.get("flag_34e", 0)) if op == 0x17 else int(ctx.get("flag_355", 0))
							var sub = _bank_stream(state, _u16(bytes, i + flag * 2))
							if sub != null and depth < 8:
								_run(parent, sub, origin, advance, material, streams, state, depth + 1)
							return
				match op:
					0x00:
						# the card's text (the routine at 0x80037DA4): operand 0x20 is the card's name, 0x40 its description, and the
						# name is pushed as a stream that ends back here; the stats kinds are not printed by these screens
						var card_text: Array = []
						if int(ctx.get("card", 0)) > 0 and (operand & 0x20) != 0:
							card_text = card_name_bytes(int(ctx["card"]))
						i += 1
						if not card_text.is_empty() and depth < 4:
							_run(parent, card_text, origin, advance, material, streams, state, depth + 1)
					0x09:
						# the duelist's name (the routine at 0x800383DC): the name of the string id in ctx "name_id" is pushed as a
						# stream; this command has no operand
						if ctx.has("name_id") and depth < 4:
							_run(parent, string_bytes(int(ctx["name_id"])), origin, advance, material, streams, state, depth + 1)
					0x0A:
						state["color"] = (int(slots[operand & 15]) if slots.size() >= 16 else 0) if (operand & 0x80) != 0 else operand
						i += 1
					0x01:
						# y moves by a signed byte and x returns to 0 (the routine at 0x800380D4)
						state["x"] = 0.0
						state["y"] += operand - 256 if operand >= 128 else operand
						i += 1
					0x02:
						state["x"] += operand
						i += 1
					0x03:
						i += 5
					0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20:
						_glyph(parent, 0x800 | operand, origin, advance, material, state)
						i += 1
					0x0B:
						# a controller picture (the routine at 0x80038094): its code is the operand, and the pen moves on 16 pixels
						_picture(parent, operand, origin, material, state)
						i += 1
					0x04, 0x0C, 0x11, 0x14, 0x15, 0x19:
						i += 1
					0x05, 0x06, 0x07, 0x0E:
						i += 2
					0x0D:
						i += 6
					0x0F:
						i += 3 if (operand & 0x3F) != 0 else 1
					0x10:
						i += 4 if (operand | (int(bytes[i + 1]) << 8 if i + 1 < bytes.size() else 0)) & 0x8000 != 0 else 2
					_:
						pass
			elif b == 0xF9:
				# the flag command: a set (flag bit 0x4000) only writes the flag, so it is skipped here; an if tests its flag and,
				# when set, jumps to its target stream, otherwise the text goes on past the target
				var flag := _u16(bytes, i)
				if (flag & 0x4000) != 0:
					i += 2
				else:
					var target := _u16(bytes, i + 2)
					i += 4
					if GameState.test_flag(flag) and depth < 8:
						var jumped = streams[target] if streams.has(target) else _bank_stream(state, target)
						if jumped != null:
							_run(parent, jumped, origin, advance, material, streams, state, depth + 1)
							return
			elif b == 0xFB:
				var control: int = bytes[i] if i < bytes.size() else 0
				i += 1
				if (control & 0x80) != 0:
					state["stop"] = true       # the jump table that follows is not text
				elif (control & 0x08) != 0:
					i += 1
			elif b == 0xFC:
				var offset: int = _u16(bytes, i)
				i += 2
				var pushed = streams[offset] if streams.has(offset) else _bank_stream(state, offset)
				if depth < 4 and pushed != null:
					_run(parent, pushed, origin, advance, material, streams, state, depth + 1)
			elif b == 0xFD:
				# a jump (the cursor offset set): the stream goes on at that bank offset, and this one is left
				var target: int = _u16(bytes, i)
				i += 2
				var jumped = streams[target] if streams.has(target) else _bank_stream(state, target)
				if jumped != null and depth < 8:
					_run(parent, jumped, origin, advance, material, streams, state, depth + 1)
				return
			elif b <= 0xF5:
				# the extended glyph: the high part is b - F0 and the low byte follows (past the font's table it is a blank glyph)
				var code := ((b - 0xF0) << 8) | (int(bytes[i]) if i < bytes.size() else 0)
				i += 1
				_glyph(parent, code, origin, advance, material, state)
			continue
		_glyph(parent, b, origin, advance, material, state)


## One controller picture at the pen (F8 0B code): the 16 x 16 picture of the code from assets/screens/buttons, drawn at the pen's line
## with no class shift (the glyph routine's icon path), and the pen moves on 16 pixels whatever the cell is. A code with no picture takes
## its place and draws nothing.
func _picture(parent: Node2D, code: int, origin: Vector2, material: Material, state: Dictionary) -> void:
	var entry := {"code": 0x0B00 | code, "x": origin.x + state["x"], "y": origin.y + state["y"], "sprite": null}
	var texture := button_texture(code)
	if texture != null:
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.texture = texture
		if material != null:
			sprite.material = material
		sprite.position = Vector2(entry["x"], entry["y"])
		parent.add_child(sprite)
		entry["sprite"] = sprite
	state["placed"].append(entry)
	state["x"] += 16.0


static var _button_names = null     # the picture file of each F8 0B code, from buttons/buttons.json (keys: the code as two hex digits)
static var _button_cache: Dictionary = {}


## The picture of a controller code (F8 0B n), or null when the bake has none.
static func button_texture(code: int) -> Texture2D:
	if _button_cache.has(code):
		return _button_cache[code]
	if _button_names == null:
		_button_names = {}
		var path := DIR + "buttons/buttons.json"
		if FileAccess.file_exists(path):
			var data = JSON.parse_string(FileAccess.get_file_as_string(path))
			if typeof(data) == TYPE_DICTIONARY and typeof(data.get("codes")) == TYPE_DICTIONARY:
				_button_names = data["codes"]
	var texture: Texture2D = null
	var file = _button_names.get("%02X" % code)
	if file != null:
		texture = ModArt.texture(DIR + "buttons/" + str(file))     # the HD copy when the mod has one (mod_art.gd)
	_button_cache[code] = texture
	return texture


## One glyph at the current pen position: a sprite (none for the blank glyph 0), and the pen moves on.
func _glyph(parent: Node2D, b: int, origin: Vector2, advance: Vector2, material: Material, state: Dictionary) -> void:
	var small: bool = state["small"]
	var tiny: bool = state["tiny"]
	var entry := {"code": b, "x": origin.x + state["x"], "y": origin.y + state["y"], "sprite": null}
	if tiny:
		# the 8 by 8 cell (F8 04 1): its picture is the glyph's tiny code in the 8 by 8 font, drawn at the pen with no class shift
		var tiny_code: int = int(glyphs[b]["tiny"]) if b < glyphs.size() else 0
		var colour: int = clampi(int(state["color"]), 0, tiny_ramps.size() - 1)
		if tiny_code != 0 and not tiny_ramps.is_empty():
			var atlas := AtlasTexture.new()
			atlas.atlas = tiny_ramps[colour]
			atlas.region = Rect2((tiny_code & 15) * 8, (tiny_code >> 4) * 8, 8, 8)
			var sprite := Sprite2D.new()
			sprite.centered = false
			sprite.texture = atlas
			if material != null:
				sprite.material = material
			sprite.position = Vector2(entry["x"], entry["y"])
			parent.add_child(sprite)
			entry["sprite"] = sprite
	elif b != 0 and b < glyphs.size() and int(glyphs[b]["sjis"]) != 0:
		var sprite := sprite_for(b, state["color"], material, small)
		var cls: int = state["cls"]
		var dy := 2.0 if cls == 0 else (-2.0 if cls == 2 else 0.0)
		sprite.position = Vector2(entry["x"] + (0 if small else int(glyphs[b]["shift"])), entry["y"] + dy)
		parent.add_child(sprite)
		entry["sprite"] = sprite
	state["placed"].append(entry)
	if state["ctx"].is_empty():
		state["x"] += advance.x
	else:
		state["x"] += 8.0 if small else 16.0


func _u16(bytes: Array, at: int) -> int:
	return int(bytes[at]) | (int(bytes[at + 1]) << 8) if at >= 0 and at + 1 < bytes.size() else 0


func _u32(bytes: Array, at: int) -> int:
	return _u16(bytes, at) | (_u16(bytes, at + 2) << 16) if at >= 0 and at + 3 < bytes.size() else 0


static var _bank_cache = null


## The text bank (assets/screens/text_bank.bin), read once: the target of a jump inside a string that continues in another one.
static func _local_bank():
	if _bank_cache == null:
		var path := DIR + "text_bank.bin"
		_bank_cache = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()
	return _bank_cache if _bank_cache.size() > 0 else null


## The text bank from `offset` on, up to a window of 512 bytes (streams end with 0xFF), or null outside the bank.
func _bank_stream(state: Dictionary, offset: int):
	var bank = state["bank"]
	if bank == null or offset < 0 or offset >= bank.size():
		return null
	return Array(bank.slice(offset, mini(offset + 512, bank.size())))


## The glyph codes of a number field (the decimal digit encoding and the routine at 0x80038148). `flags`: the low nibble is the digit count;
## bit 0x80 pads leading zeros with blanks, and bit 0x40 with the digit 0 instead; without 0x80 leading blanks are dropped.
## A RAM address the screen does not fill is left blank.
func _number_codes(ctx: Dictionary, address: int, flags: int) -> Array:
	var n := flags & 0xF
	var digits: Array = ctx.get("digits", [])
	var codes: Array = []
	if n <= 0 or digits.size() < 10:
		return codes
	var numbers: Dictionary = ctx.get("numbers", {})
	if not numbers.has(address):
		for k in n:
			codes.append(0)
		return codes
	var value: int = maxi(int(numbers[address]), 0)
	var buf: Array = []
	buf.resize(n)
	var d := 1
	for k in n - 1:
		d *= 10
	for k in range(n - 1, -1, -1):
		buf[k] = value / d
		value -= buf[k] * d
		d /= 10
	var lead := n - 1
	while lead > 0 and buf[lead] == 0:
		buf[lead] = 10
		lead -= 1
	if (flags & 0x80) != 0:
		var pad := int(digits[0]) if (flags & 0x40) != 0 else 0
		for k in range(n - 1, -1, -1):
			codes.append(int(digits[buf[k]]) if buf[k] < 10 else pad)
		return codes
	var count := n
	var top := n - 1
	while true:
		if buf[top] < 10:
			break
		count = top
		if top < 2:
			break
		top = count - 1
	for k in range(count - 1, -1, -1):
		codes.append(int(digits[buf[k]]) if buf[k] < 10 else 0)
	return codes
