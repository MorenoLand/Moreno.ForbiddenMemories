extends RefCounted
## The duel effect data the ports read: the baked texture-page layout and configuration tables (assets/screens/duel_fx/, written
## by tools/extract.py's bake_duel_effect_textures). Loaded once; missing files give empty data, so the ports still run.

const DIR := "res://assets/screens/duel_fx/"

static var _layout = null
static var _configs = null


static func layout() -> Dictionary:
	if _layout == null:
		_layout = _read("layout.json")
	return _layout


static func configs() -> Dictionary:
	if _configs == null:
		_configs = _read("configs.json")
	return _configs


## The digit atlas cell (x, y, w, h) of a digit tile: 0 to 9 are the digits, 10 is '+' and 11 is '-' (the number renderer's table).
static func digit_cell(tile: int) -> Vector4i:
	var digits: Array = layout().get("digits", [])
	if tile < 0 or tile >= digits.size():
		return Vector4i.ZERO
	var c: Array = digits[tile]
	return Vector4i(int(c[0]), int(c[1]), int(c[2]), int(c[3]))


## The start vector a program's scale begins from (the overlay's vector at its symbol address, baked under configs "scale").
## Falls back to (4096, 4096, 4096), the value every baked start vector holds.
static func start_vector(id: int) -> Vector3i:
	var scales: Dictionary = configs().get("scale", {})
	var v: Array = scales.get(str(id), [4096, 4096, 4096])
	return Vector3i(int(v[0]), int(v[1]), int(v[2]))


static func _read(name: String) -> Dictionary:
	var file := FileAccess.open(DIR + name, FileAccess.READ)
	if file == null:
		push_warning("duel effects: %s is missing; run tools/extract.py --screens" % name)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return _integers(parsed) if parsed is Dictionary else {}


## JSON numbers are floats; the programs use them as integers, so every number is converted in place.
static func _integers(value):
	if value is Dictionary:
		for key in value.keys():
			value[key] = _integers(value[key])
		return value
	if value is Array:
		for i in value.size():
			value[i] = _integers(value[i])
		return value
	if value is float:
		return int(value)
	return value
