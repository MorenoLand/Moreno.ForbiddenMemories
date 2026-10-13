extends CanvasLayer
## On-screen controls for touch screens and for the web build: a D-pad, Cross, Circle, Square, Triangle, Start, Select, L1/R1 and
## L2/R2, drawn over the game. Each control presses the keyboard key the screens already read (the arrows, E, Q, F, R, Z, C, 1, 3,
## Enter, Tab, Shift for SKIP, F1 and F2), so every screen works unchanged. The keys are injected as real key events through Input.parse_input_event, held
## while the finger (or mouse button) stays on the control, with key repeat for the D-pad. A swipe over empty space sends mouse
## wheel steps, which scroll the lists.
##
## Shown by default on a touch screen and on the web; F4 shows or hides them on any platform, and the choice is kept in
## user://settings.cfg (section [touch], key show). Touches that land on a control are consumed, so they do not click the game
## underneath; touches elsewhere reach the game as the emulated mouse (project setting input_devices/pointing/emulate_mouse_from_touch).

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "touch"
const PULSE_TIME := 0.12          # the shortest press: the screens poll the keys once per frame
const REPEAT_DELAY := 0.4         # D-pad repeat: the first repeat after this many seconds held
const REPEAT_INTERVAL := 0.12
const SWIPE_STEP := 26.0          # pixels of swipe per wheel step
const DPAD_DEAD := 0.35           # a finger this far from the D-pad centre (in buttons) counts as a direction
const NAV_KEYS := [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]
const EMULATED_DEVICE := -1      # InputEvent.device of the mouse events made from touches (emulate_mouse_from_touch)

var _pad: Control
var _zones: Array = []            # {id, shape ("dpad", "circle", "pill"), center, radius, rect, keys, label}
var _touches := {}                # index (-1 = mouse) -> {zone, keys, swipe}
var _key_count := {}              # keycode -> number of holders (touches or mouse)
var _key_down := {}              # keycode -> true while the press is down in Input
var _key_until := {}             # keycode -> seconds before its release may happen
var _key_echo := {}              # keycode -> seconds of the next repeat (nav keys)
var _shown := false
var _on_control := false          # the left button (a touch or the mouse) is held on a control, not on the game

static var instance: Object = null


## True while the left button is held on the game itself. The screens that poll Input.is_mouse_button_pressed use this, so a
## finger on a control does not click through (the engine's emulated click for that touch is still down).
static func game_pointer_held() -> bool:
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return false
	return instance == null or not instance._on_control


func _ready() -> void:
	layer = 90   # above every screen, below the F1 toast (100)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_pad = Control.new()
	_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pad.draw.connect(_draw_pad)
	_pad.resized.connect(_layout)
	add_child(_pad)
	get_viewport().size_changed.connect(_layout)
	instance = self
	_set_shown(_load_shown(), false)


func _exit_tree() -> void:
	if instance == self:
		instance = null


func _load_shown() -> bool:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK and config.has_section_key(SETTINGS_SECTION, "show"):
		return bool(config.get_value(SETTINGS_SECTION, "show"))
	return DisplayServer.is_touchscreen_available() or OS.has_feature("web")


func _save_shown(on: bool) -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)   # keeps the other sections; a missing file is written new
	config.set_value(SETTINGS_SECTION, "show", on)
	config.save(SETTINGS_PATH)


func _set_shown(on: bool, save: bool) -> void:
	_shown = on
	_pad.visible = on
	if not on:
		_release_all()
	_layout()
	if save:
		_save_shown(on)


func is_shown() -> bool:
	return _shown


func _notification(what: int) -> void:
	# a focus loss can swallow the release events: nothing may stay held
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_release_all()
		_touches.clear()


## The buttons, sized from the picture's height and kept clear of the safe area (the notches and the rounded corners of a phone).
func _layout() -> void:
	_zones.clear()
	var w := _pad.size.x
	var h := _pad.size.y
	if w <= 0.0 or h <= 0.0:
		return
	var inset := Vector4(0, 0, 0, 0)   # left, top, right, bottom
	var screen := DisplayServer.screen_get_size()
	var safe := DisplayServer.get_display_safe_area()
	if screen.x > 0 and screen.y > 0 and safe.size.x > 0 and safe.size.y > 0:
		inset = Vector4(
			maxf(0.0, safe.position.x) / screen.x * w,
			maxf(0.0, safe.position.y) / screen.y * h,
			maxf(0.0, screen.x - safe.end.x) / screen.x * w,
			maxf(0.0, screen.y - safe.end.y) / screen.y * h)
	var margin := 8.0
	var s := clampf(h * 0.1, 34.0, 60.0)   # one button's size
	var left := inset.x + margin
	var top := inset.y + margin
	var right := w - inset.z - margin
	var bottom := h - inset.w - margin

	var dpad_center := Vector2(left + 1.5 * s, bottom - 1.5 * s)
	_zones.append({"id": "dpad", "shape": "dpad", "center": dpad_center, "radius": 1.6 * s, "unit": s})

	var action_center := Vector2(right - 1.5 * s, bottom - 1.5 * s)
	_add_circle("cross", "X", action_center + Vector2(0, s), s * 0.42, [KEY_E])
	_add_circle("circle", "O", action_center + Vector2(s, 0), s * 0.42, [KEY_Q])
	_add_circle("square", "SQ", action_center + Vector2(-s, 0), s * 0.42, [KEY_F])
	_add_circle("triangle", "TRI", action_center + Vector2(0, -s), s * 0.42, [KEY_R])

	var pill := Vector2(1.5 * s, 0.6 * s)
	var mid := w * 0.5
	_add_pill("select", "SELECT", Rect2(mid - 1.1 * s - pill.x * 0.5, bottom - pill.y, pill.x, pill.y), [KEY_TAB])
	_add_pill("start", "START", Rect2(mid + 1.1 * s - pill.x * 0.5, bottom - pill.y, pill.x, pill.y), [KEY_ENTER])
	_add_pill("l2", "L2", Rect2(left, top, pill.x, pill.y), [KEY_1])
	_add_pill("l1", "L1", Rect2(left, top + pill.y + 6.0, pill.x, pill.y), [KEY_Z])
	_add_pill("r2", "R2", Rect2(right - pill.x, top, pill.x, pill.y), [KEY_3])
	_add_pill("r1", "R1", Rect2(right - pill.x, top + pill.y + 6.0, pill.x, pill.y), [KEY_C])
	# SKIP is held (Shift, the story's fast-forward), sitting above the Select/Start row; F1 and F2 are small taps at the top middle
	_add_pill("skip", "SKIP", Rect2(mid - pill.x * 0.5, bottom - 2.0 * pill.y - 6.0, pill.x, pill.y), [KEY_SHIFT])
	_add_pill("f1", "F1", Rect2(mid - pill.x - 4.0, top, pill.x, pill.y), [KEY_F1])
	_add_pill("f2", "F2", Rect2(mid + 4.0, top, pill.x, pill.y), [KEY_F2])
	# the picture (F5 sampling, F6 scanlines) and the options panel (F9), in a second row under F1 and F2
	var row := top + pill.y + 6.0
	_add_pill("f5", "F5", Rect2(mid - 1.5 * pill.x - 8.0, row, pill.x, pill.y), [KEY_F5])
	_add_pill("f6", "F6", Rect2(mid - 0.5 * pill.x, row, pill.x, pill.y), [KEY_F6])
	_add_pill("f9", "F9", Rect2(mid + 0.5 * pill.x + 8.0, row, pill.x, pill.y), [KEY_F9])
	_pad.queue_redraw()


func _add_circle(id: String, label: String, center: Vector2, radius: float, keys: Array) -> void:
	_zones.append({"id": id, "shape": "circle", "center": center, "radius": radius, "keys": keys, "label": label})


func _add_pill(id: String, label: String, rect: Rect2, keys: Array) -> void:
	_zones.append({"id": id, "shape": "pill", "rect": rect, "keys": keys, "label": label})


func _zone_at(pos: Vector2) -> Dictionary:
	for zone in _zones:
		match zone.shape:
			"dpad", "circle":
				if pos.distance_to(zone.center) <= zone.radius:
					return zone
			"pill":
				if zone.rect.has_point(pos):
					return zone
	return {}


func _zone_by_id(id: String) -> Dictionary:
	for zone in _zones:
		if zone.id == id:
			return zone
	return {}


## The keys a finger on `zone` at `pos` holds. The D-pad reads the direction from the finger's offset, so a finger can slide
## between directions or hold two at once (a diagonal).
func _keys_for(zone: Dictionary, pos: Vector2) -> Array:
	if zone.shape != "dpad":
		return zone.keys
	var offset: Vector2 = (pos - zone.center) / zone.unit
	var keys := []
	if offset.x < -DPAD_DEAD:
		keys.append(KEY_LEFT)
	if offset.x > DPAD_DEAD:
		keys.append(KEY_RIGHT)
	if offset.y < -DPAD_DEAD:
		keys.append(KEY_UP)
	if offset.y > DPAD_DEAD:
		keys.append(KEY_DOWN)
	return keys


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and not event.echo and event.keycode == KEY_F4:
			_set_shown(not _shown, true)
			get_viewport().set_input_as_handled()
		return
	if not _shown:
		_on_control = false
		return
	var consume := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.device == EMULATED_DEVICE:
		# the click the engine makes from a touch (it arrives before the touch itself): stopped when it lands on a control or
		# belongs to a control touch, so the game underneath is not clicked
		if event.pressed:
			_on_control = not _zone_at(event.position).is_empty()
			consume = _on_control
		else:
			consume = _on_control or _any_zone_touch()
			_on_control = false
		if consume:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and event.device == EMULATED_DEVICE:
		if _any_zone_touch():
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		if event.pressed:
			if _touch_down(event.index, event.position):
				get_viewport().set_input_as_handled()
		elif _touches.has(event.index):
			var on_zone: bool = _touches[event.index].zone != ""
			_touch_up(event.index)
			if on_zone:
				get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if _touches.has(event.index):
			if _touch_drag(event.index, event.position, event.relative):
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# a real mouse (the desktop with F4 on): the same controls as a finger
		if event.pressed:
			_on_control = _touch_down(-1, event.position)
			if _on_control:
				get_viewport().set_input_as_handled()
		else:
			_on_control = false
			if _touches.has(-1):
				var on_zone: bool = _touches[-1].zone != ""
				_touch_up(-1)
				if on_zone:
					get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _touches.has(-1):
		if _touch_drag(-1, event.position, event.relative):
			get_viewport().set_input_as_handled()


func _any_zone_touch() -> bool:
	for touch in _touches.values():
		if touch.zone != "":
			return true
	return false


## Returns true when the touch lands on a control (and so is consumed).
func _touch_down(index: int, pos: Vector2) -> bool:
	var zone := _zone_at(pos)
	if zone.is_empty():
		_touches[index] = {"zone": "", "keys": [], "swipe": 0.0}
		return false
	_touches[index] = {"zone": zone.id, "keys": [], "swipe": 0.0}
	_set_keys(index, _keys_for(zone, pos))
	return true


## Returns true when the drag stays on a control (and so is consumed).
func _touch_drag(index: int, pos: Vector2, relative: Vector2) -> bool:
	var touch: Dictionary = _touches[index]
	if touch.zone != "":
		var zone := _zone_by_id(touch.zone)
		if zone.shape == "dpad":
			_set_keys(index, _keys_for(zone, pos))
		return true
	touch.swipe += relative.y
	while absf(touch.swipe) >= SWIPE_STEP:
		# a finger moving up (negative) turns the list down, like the wheel
		var button := MOUSE_BUTTON_WHEEL_DOWN if touch.swipe < 0 else MOUSE_BUTTON_WHEEL_UP
		_inject_wheel(button, pos)
		touch.swipe -= signf(touch.swipe) * SWIPE_STEP
	return false


func _touch_up(index: int) -> void:
	_set_keys(index, [])
	_touches.erase(index)


## Moves one finger's held keys to `keys`: the keys it leaves are released, the new ones pressed.
func _set_keys(index: int, keys: Array) -> void:
	var touch: Dictionary = _touches[index]
	for key in touch.keys:
		if not keys.has(key):
			_release_key(key)
	for key in keys:
		if not touch.keys.has(key):
			_press_key(key)
	touch.keys = keys


func _press_key(key: int) -> void:
	var count: int = _key_count.get(key, 0) + 1
	_key_count[key] = count
	if count == 1:
		_key_until[key] = _now() + PULSE_TIME
		_send_key(key, true, false)
		_key_down[key] = true
		if NAV_KEYS.has(key):
			_key_echo[key] = _now() + REPEAT_DELAY


func _release_key(key: int) -> void:
	var count: int = maxi(0, _key_count.get(key, 0) - 1)
	_key_count[key] = count
	if count == 0:
		_key_until[key] = maxf(_key_until.get(key, 0.0), _now() + PULSE_TIME)
		_key_echo.erase(key)


func _release_all() -> void:
	for key in _key_down.keys():
		_send_key(key, false, false)
	_key_down.clear()
	_key_count.clear()
	_key_until.clear()
	_key_echo.clear()
	for index in _touches.keys():
		_touches[index].keys = []


func _process(_delta: float) -> void:
	if not _shown:
		return
	var now := _now()
	for key in _key_down.keys():
		if _key_count.get(key, 0) == 0:
			if now >= _key_until.get(key, 0.0):
				_send_key(key, false, false)
				_key_down.erase(key)
		elif _key_echo.has(key) and now >= _key_echo[key]:
			_send_key(key, true, true)
			_key_echo[key] = now + REPEAT_INTERVAL
	_pad.queue_redraw()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _send_key(code: int, pressed: bool, echo: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	event.echo = echo
	Input.parse_input_event(event)


## `pos` is in the viewport's coordinates (where the controls are); an injected event takes window coordinates.
func _inject_wheel(button: int, pos: Vector2) -> void:
	var window_pos: Vector2 = get_viewport().get_final_transform() * pos
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = window_pos
		event.global_position = window_pos
		event.factor = 1.0
		Input.parse_input_event(event)


func _draw_pad() -> void:
	for zone in _zones:
		var down := _zone_down(zone.id)
		var alpha := 0.55 if down else 0.3
		match zone.shape:
			"dpad":
				_draw_dpad(zone, alpha)
			"circle":
				_pad.draw_circle(zone.center, zone.radius, Color(0, 0, 0, alpha))
				_pad.draw_arc(zone.center, zone.radius, 0, TAU, 40, Color(1, 1, 1, 0.5), 2.0, true)
				var face := Rect2(zone.center - Vector2(zone.radius, zone.radius), Vector2(zone.radius, zone.radius) * 2.0)
				_draw_label(zone.label, face, alpha)
			"pill":
				var box: Rect2 = zone.rect
				_pad.draw_rect(box, Color(0, 0, 0, alpha))
				_pad.draw_rect(box, Color(1, 1, 1, 0.5), false, 2.0)
				_draw_label(zone.label, box, alpha)


func _draw_dpad(zone: Dictionary, alpha: float) -> void:
	var s: float = zone.unit
	var c: Vector2 = zone.center
	var arms := {
		"up": Vector2(c.x - s * 0.5, c.y - 1.5 * s), "down": Vector2(c.x - s * 0.5, c.y + 0.5 * s),
		"left": Vector2(c.x - 1.5 * s, c.y - s * 0.5), "right": Vector2(c.x + 0.5 * s, c.y - s * 0.5)}
	var held := {}
	for key in _keys_held_by_zone("dpad"):
		held[key] = true
	var lit := {"up": held.has(KEY_UP), "down": held.has(KEY_DOWN), "left": held.has(KEY_LEFT), "right": held.has(KEY_RIGHT)}
	for name in arms:
		var rect := Rect2(arms[name], Vector2(s, s))
		_pad.draw_rect(rect, Color(1, 1, 1, 0.45 if lit[name] else alpha))
		_pad.draw_rect(rect, Color(1, 1, 1, 0.5), false, 2.0)


## The label centred in `box`, its size taken from the box height.
func _draw_label(text: String, box: Rect2, alpha: float) -> void:
	var font := ThemeDB.fallback_font
	var size := int(maxf(10.0, box.size.y * 0.5))
	var baseline := box.position.y + box.size.y * 0.5 + font.get_ascent(size) * 0.5
	_pad.draw_string(font, Vector2(box.position.x, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, box.size.x, size,
		Color(1, 1, 1, minf(1.0, alpha + 0.35)))


func _zone_down(id: String) -> bool:
	for touch in _touches.values():
		if touch.zone == id:
			return true
	return false


func _keys_held_by_zone(id: String) -> Array:
	var keys := []
	for touch in _touches.values():
		if touch.zone == id:
			keys.append_array(touch.keys)
	return keys
