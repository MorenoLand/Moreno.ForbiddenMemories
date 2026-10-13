extends RefCounted
## PC input for the PlayStation pad: keyboard, mouse and gamepad bindings per pad button, saved to user://input.json.
## The pad word has the console's layout: low byte Select L3 R3 Start Up Right Down Left, high byte L2 R2 L1 R1 Triangle Circle Cross Square.

const PATH := "user://input.json"
const ACTIONS := [
	["up", "D-pad Up", 0x0010], ["down", "D-pad Down", 0x0040], ["left", "D-pad Left", 0x0080], ["right", "D-pad Right", 0x0020],
	["cross", "Cross (confirm)", 0x4000], ["circle", "Circle (cancel)", 0x2000], ["square", "Square", 0x8000], ["triangle", "Triangle", 0x1000],
	["l1", "L1", 0x0400], ["r1", "R1", 0x0800], ["l2", "L2", 0x0100], ["r2", "R2", 0x0200],
	["start", "Start", 0x0008], ["select", "Select", 0x0001], ["l3", "L3", 0x0002], ["r3", "R3", 0x0004],
]
const STICK_DEADZONE := 0.5

var bindings: Dictionary = {}
var wheel_up := 0
var wheel_down := 0


func _init() -> void:
	reset()
	load_file()


func reset() -> void:
	bindings = {
		"up": [_key(KEY_W), _key(KEY_UP), _joy(JOY_BUTTON_DPAD_UP), _axis(JOY_AXIS_LEFT_Y, -1)],
		"down": [_key(KEY_S), _key(KEY_DOWN), _joy(JOY_BUTTON_DPAD_DOWN), _axis(JOY_AXIS_LEFT_Y, 1)],
		"left": [_key(KEY_A), _key(KEY_LEFT), _joy(JOY_BUTTON_DPAD_LEFT), _axis(JOY_AXIS_LEFT_X, -1)],
		"right": [_key(KEY_D), _key(KEY_RIGHT), _joy(JOY_BUTTON_DPAD_RIGHT), _axis(JOY_AXIS_LEFT_X, 1)],
		"cross": [_key(KEY_E), _key(KEY_SPACE), _joy(JOY_BUTTON_A), _mouse(MOUSE_BUTTON_LEFT)],
		"circle": [_key(KEY_Q), _key(KEY_BACKSPACE), _joy(JOY_BUTTON_B), _mouse(MOUSE_BUTTON_RIGHT)],
		"square": [_key(KEY_F), _joy(JOY_BUTTON_X)],
		"triangle": [_key(KEY_R), _joy(JOY_BUTTON_Y)],
		"l1": [_key(KEY_Z), _joy(JOY_BUTTON_LEFT_SHOULDER)],
		"r1": [_key(KEY_C), _joy(JOY_BUTTON_RIGHT_SHOULDER)],
		"l2": [_key(KEY_1), _axis(JOY_AXIS_TRIGGER_LEFT, 1)],
		"r2": [_key(KEY_3), _axis(JOY_AXIS_TRIGGER_RIGHT, 1)],
		"start": [_key(KEY_ENTER), _key(KEY_KP_ENTER), _joy(JOY_BUTTON_START), _mouse(MOUSE_BUTTON_MIDDLE)],
		"select": [_key(KEY_SHIFT), _key(KEY_TAB), _joy(JOY_BUTTON_BACK)],
		"l3": [_joy(JOY_BUTTON_LEFT_STICK)],
		"r3": [_joy(JOY_BUTTON_RIGHT_STICK)],
	}


static func _key(code: int) -> Dictionary:
	return {"type": "key", "code": code}


static func _joy(button: int) -> Dictionary:
	return {"type": "joy", "button": button}


static func _axis(axis: int, direction: int) -> Dictionary:
	return {"type": "axis", "axis": axis, "dir": direction}


static func _mouse(button: int) -> Dictionary:
	return {"type": "mouse", "button": button}


func load_file() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if typeof(data) != TYPE_DICTIONARY:
		return
	for action in data:
		if bindings.has(action) and typeof(data[action]) == TYPE_ARRAY:
			var list: Array = []
			for entry in data[action]:
				if typeof(entry) == TYPE_DICTIONARY and entry.has("type"):
					list.append(entry)
			bindings[action] = list


func save_file() -> void:
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(bindings, "\t"))


func describe(entry: Dictionary) -> String:
	match String(entry["type"]):
		"key":
			return OS.get_keycode_string(int(entry["code"]))
		"joy":
			return "Pad button %d" % int(entry["button"])
		"axis":
			return "Pad axis %d%s" % [int(entry["axis"]), "+" if int(entry["dir"]) > 0 else "-"]
		"mouse":
			return ["", "Mouse left", "Mouse right", "Mouse middle"][clampi(int(entry["button"]), 0, 3)]
		"wheel":
			return "Wheel up" if int(entry["dir"]) < 0 else "Wheel down"
	return "?"


func summary(action: String) -> String:
	var parts: Array = []
	for entry in bindings.get(action, []):
		parts.append(describe(entry))
	return ", ".join(parts) if not parts.is_empty() else "(unbound)"


## Replaces the bindings of the same device kind for an action with one captured event (keeping the other kinds).
func rebind(action: String, entry: Dictionary) -> void:
	var kept: Array = []
	var family := _family(entry)
	for old in bindings[action]:
		if _family(old) != family:
			kept.append(old)
	kept.append(entry)
	bindings[action] = kept
	save_file()


static func _family(entry: Dictionary) -> String:
	var type := String(entry["type"])
	if type == "joy" or type == "axis":
		return "pad"
	if type == "mouse" or type == "wheel":
		return "mouse"
	return "key"


func capture(event: InputEvent) -> Dictionary:
	if event is InputEventKey and event.pressed and not event.echo:
		return _key(event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode)
	if event is InputEventJoypadButton and event.pressed:
		return _joy(event.button_index)
	if event is InputEventJoypadMotion and absf(event.axis_value) > 0.7:
		return _axis(event.axis, 1 if event.axis_value > 0.0 else -1)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			return {"type": "wheel", "dir": -1}
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return {"type": "wheel", "dir": 1}
		return _mouse(event.button_index)
	return {}


## Mouse wheel ticks hold their pad button for a few frames so the game sees a press; key events are tracked from the events
## themselves, which also works in embedded game windows where polling can miss focus changes.
func note_event(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			wheel_up = 4
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			wheel_down = 4
	elif event is InputEventKey and not event.echo:
		var code: int = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		held_keys[code] = event.pressed
		held_keys[event.keycode] = event.pressed


var held_keys: Dictionary = {}


func _active(entry: Dictionary, device: int) -> bool:
	match String(entry["type"]):
		"key":
			var code := int(entry["code"])
			return bool(held_keys.get(code, false)) or Input.is_physical_key_pressed(code) or Input.is_key_pressed(code)
		"joy":
			return Input.is_joy_button_pressed(device, int(entry["button"]))
		"axis":
			return Input.get_joy_axis(device, int(entry["axis"])) * float(entry["dir"]) > STICK_DEADZONE
		"mouse":
			return Input.is_mouse_button_pressed(int(entry["button"]))
		"wheel":
			return wheel_up > 0 if int(entry["dir"]) < 0 else wheel_down > 0
	return false


## While a text screen takes typed characters, printable keys and the mouse must not also press pad buttons.
static func _typing_conflict(entry: Dictionary) -> bool:
	var type := String(entry["type"])
	if type == "mouse" or type == "wheel":
		return true
	if type == "key":
		var code := int(entry["code"])
		return code >= KEY_SPACE and code <= KEY_ASCIITILDE or code == KEY_ENTER or code == KEY_KP_ENTER
	return false


## The pad word for this frame (active-high; the host inverts it into the console's active-low pad packet).
func pad_word(text_entry := false) -> int:
	var word := 0
	var pads := Input.get_connected_joypads()
	var device: int = int(pads[0]) if not pads.is_empty() else 0
	for action in ACTIONS:
		for entry in bindings.get(action[0], []):
			if text_entry and _typing_conflict(entry):
				continue
			if _active(entry, device):
				word |= int(action[2])
				break
	if wheel_up > 0:
		word |= 0x0010
		wheel_up -= 1
	if wheel_down > 0:
		word |= 0x0040
		wheel_down -= 1
	return word
