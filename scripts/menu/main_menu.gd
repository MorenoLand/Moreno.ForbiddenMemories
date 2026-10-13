extends Control
## The front-end menu (title screen and the menu wheel), a native port of the main-menu module's the front-end menu setup,
## the front-end menu update, the front-end entry transition and the front-end background drawing. Everything steps at the
## game's 60 Hz. The pictures are baked by tools/extract.py --screens (assets/screens/menu/).
##
## Entries: 0 NEW GAME, 1 LOAD, 2 2P DUEL, 3 TRADE, 4 OPTION (first page), 5 CAMPAIGN, 6 FREE DUEL, 7 BUILD DECK, 8 LIBRARY,
## 9 PASSWORD, 10 SAVE (second page).

signal chosen(id: int)        # a menu entry was taken (after its slide-out), like the module returning the menu id
signal load_requested         # LOAD: answer with finish_load()
signal save_requested         # SAVE
signal demo_requested         # the title waited 3000 frames (the module returns -2)
signal sound(effect: int)     # the SE play ids: 6 move, 7 confirm, 8 cancel, 9 refuse
signal music(id: int)           # the BGM play this screen starts when it opens (the driver's BGM play)

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const DIR := "res://assets/screens/menu/"
const ENTRY_COUNT := 11
const REPEAT_THRESHOLD := 0x18
const REPEAT_RELOAD := 0x14
const IDLE_LIMIT := 0xBB8

var initial_menu := 0         # the menu id the module opens on (coming back from a mode skips the title)
var menu_id := 0
var shade := 0                 # the data at 0x80184597: the wall's darkening, 0..0x80
var shade_step := 0            # the data at 0x80184598
var transitioning := false     # the data at 0x80184599
var transition_mode := 0       # the data at 0x80184596: 0 slide in, 1 slide out
var cancelled := false         # the data at 0x80184595
var loading := false           # the data at 0x8018459B
var title_visible := true      # the data at 0x80184560 renderable
var title_hold := 0x3C         # its field_6C
var title_level := 0x80        # its colour byte
var title_dir := -2            # its field_60
var idle := 0                  # its the field 34 struct.field_36

var entry_x: Array = []        # current x of each entry
var entry_from: Array = []
var entry_to: Array = []
var entry_timer: Array = []
var entry_shown: Array = []
var entry_selected: Array = []

var textures: Dictionary = {}
var layout: Dictionary = {}
var world := Node2D.new()
var sharp: ShaderMaterial
var sharp_add: ShaderMaterial
var wall := Sprite2D.new()
var shade_rect := ColorRect.new()
var logo := Sprite2D.new()
var copyright := Sprite2D.new()
var push_start := Sprite2D.new()
var entries: Array = []
var afterimages: Array = []   # [Sprite2D, level]
var held: Dictionary = {}
var ready_ok := false


func _ready() -> void:
	music.emit(28672)   # the BGM play in this screen's open routine
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not _load_art():
		return
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sharp = ScreenFit.make_material()
	sharp_add = ScreenFit.make_material(true)
	add_child(world)
	add_to_group("fit")
	_place(wall, "wall")
	world.add_child(wall)
	# the wall's own shade: a Gouraud quad, black at the top and white at the bottom, subtracted (draw mode abr 2, depth 4094)
	var gradient := Polygon2D.new()
	gradient.polygon = PackedVector2Array([Vector2(0, 0), Vector2(320, 0), Vector2(320, 240), Vector2(0, 240)])
	gradient.vertex_colors = PackedColorArray([Color.BLACK, Color.BLACK, Color.WHITE, Color.WHITE])
	gradient.material = ScreenFit.make_subtract_material()   # subtractive; takes the PS1 dither when the F9 option is on
	world.add_child(gradient)
	_place(logo, "logo_0")
	world.add_child(logo)
	_place(copyright, "logo_2")
	world.add_child(copyright)
	_place(push_start, "logo_1")
	world.add_child(push_start)
	# the darkening polygon (flat, subtractive, depth 0) lies in front of the wall and the logo objects (depth 0 and 1)
	shade_rect.size = Vector2(320, 240)
	shade_rect.color = Color(0, 0, 0)
	var sub := CanvasItemMaterial.new()
	sub.blend_mode = CanvasItemMaterial.BLEND_MODE_SUB
	shade_rect.material = sub
	world.add_child(shade_rect)
	for i in ENTRY_COUNT:
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.material = sharp
		sprite.visible = false
		world.add_child(sprite)
		entries.append(sprite)
		entry_x.append(0)
		entry_from.append(0)
		entry_to.append(0)
		entry_timer.append(0)
		entry_shown.append(false)
		entry_selected.append(false)
	menu_id = initial_menu % ENTRY_COUNT
	_set_entry_state(menu_id, true)
	if menu_id != 0:
		shade = 0x80
		_apply_shade()
		title_visible = false
		push_start.visible = false
	_start_transition(0)

	ScreenFit.pass_mouse(self)
	ready_ok = true
	_fit()
	get_viewport().size_changed.connect(_fit)


func _load_art() -> bool:
	var json = JSON.parse_string(FileAccess.get_file_as_string(DIR + "layout.json")) if FileAccess.file_exists(DIR + "layout.json") else null
	if typeof(json) != TYPE_DICTIONARY:
		return false
	layout = json
	for name in layout:
		var texture := ModArt.texture(DIR + name + ".png")
		if texture == null:
			return false
		textures[name] = texture
	return true


func _place(sprite: Sprite2D, name: String) -> void:
	sprite.centered = false
	sprite.material = sharp
	sprite.texture = textures[name]
	sprite.position = Vector2(layout[name]["x"], layout[name]["y"])


func _fit() -> void:
	ScreenFit.apply(world, size)


func refit() -> void:
	_fit()


## The entry sprite for index i in the given state: its x moves, y comes from the original's rows.
func _entry_y(i: int) -> int:
	return i * 32 + 50 if i < 5 else (i - 5) * 32 + 42


func _set_entry_state(i: int, selected: bool) -> void:
	entry_selected[i] = selected
	var name := "entry_%d_%s" % [i, "on" if selected else "off"]
	entries[i].texture = textures[name]
	# the baked picture is cut to its opaque box; the object sits at x = entry_x[i], so shift by the box's offset from 0xA0
	entries[i].set_meta("dx", int(layout[name]["x"]) - 0xA0)
	entries[i].set_meta("dy", int(layout[name]["y"]))


func _sync_entry(i: int) -> void:
	entries[i].position = Vector2(entry_x[i] + int(entries[i].get_meta("dx")), int(entries[i].get_meta("dy")))
	entries[i].visible = entry_shown[i]


## the front-end entry transition.
func _start_transition(mode: int) -> void:
	for i in ENTRY_COUNT:
		var offset := 0x1E0 if (i & 1) != 0 else -0xA0
		if mode != 0:
			entry_from[i] = 0xA0
			entry_to[i] = offset
		else:
			entry_from[i] = offset
			entry_to[i] = 0xA0
		entry_x[i] = entry_from[i]
		entry_timer[i] = 0x10
	transition_mode = mode
	transitioning = true


## Pad edges for this frame: the pressed word and the repeat word of the game's input layer.
func _pad() -> Dictionary:
	var down := {
		"up": Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_UP),
		"down": Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN) or Input.is_joy_button_pressed(0, JOY_BUTTON_DPAD_DOWN),
		"start": Input.is_key_pressed(KEY_ENTER) or Input.is_key_pressed(KEY_KP_ENTER) or Input.is_joy_button_pressed(0, JOY_BUTTON_START),
		"confirm": Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_A),
		"cancel": Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_BACKSPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_B),
	}
	var pressed := {}
	var repeat := {}
	for key in down:
		var timer: int = held.get(key, -1)
		if down[key]:
			if timer < 0:
				pressed[key] = true
				repeat[key] = true
				timer = 0
			else:
				timer += 1
				if timer >= REPEAT_THRESHOLD:
					repeat[key] = true
					timer = REPEAT_RELOAD
			held[key] = timer
		else:
			held[key] = -1
	if click_pending:
		pressed["confirm"] = true
		click_pending = false
	if cancel_click:
		pressed["cancel"] = true
		cancel_click = false
	return {"pressed": pressed, "repeat": repeat}


var click_pending := false
var cancel_click := false     # right mouse button: Q / Esc / Backspace


func _gui_input(event: InputEvent) -> void:
	if not ready_ok:
		return
	if event is InputEventMouseMotion:
		# hovering an entry selects it as moving the cursor there does; only real motion acts, so the keys still work over a resting pointer
		if _menu_active():
			var over := _entry_at(event.position)
			if over >= 0 and over != menu_id:
				_set_entry_state(menu_id, false)
				menu_id = over
				_set_entry_state(menu_id, true)
				sound.emit(6)
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		cancel_click = true
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		var local: Vector2 = (event.position - world.position) / world.scale
		# a click on an entry takes it; elsewhere on the title it is START
		for i in ENTRY_COUNT:
			if entry_shown[i] and Rect2(entries[i].position, entries[i].texture.get_size()).has_point(local) and not transitioning and not title_visible:
				if i != menu_id:
					_set_entry_state(menu_id, false)
					menu_id = i
					_set_entry_state(menu_id, true)
				click_pending = true
				return
		if title_visible:
			start_click = true


## The shown entry under a point in the control's local coordinates, or -1.
func _entry_at(at: Vector2) -> int:
	var local: Vector2 = (at - world.position) / world.scale
	for i in ENTRY_COUNT:
		if entry_shown[i] and Rect2(entries[i].position, entries[i].texture.get_size()).has_point(local):
			return i
	return -1


## The pointer acts only where _update_menu does (not on the title, not while sliding or loading).
func _menu_active() -> bool:
	return not loading and shade_step == 0 and not title_visible and not transitioning


var start_click := false


func finish_load(success: bool) -> void:
	## the answer to load_requested: success slides the wheel out and then to the second page, like the original's poll load routine == 1
	if not loading:
		return
	loading = false
	if success:
		_start_transition(1)


func _physics_process(_delta: float) -> void:
	if not ready_ok or not visible:
		return
	_fade_afterimages()
	var pad := _pad()
	var pressed: Dictionary = pad["pressed"]
	var repeat: Dictionary = pad["repeat"]
	if start_click:
		pressed["start"] = true
		start_click = false
	if loading:
		return
	if shade_step != 0:
		shade += shade_step << 3
		_apply_shade()
		var done := false
		if shade_step > 0 and shade >= 0x80:
			shade = 0x80
			done = true
		elif shade_step < 0 and shade <= 0:
			shade = 0
			done = true
		if done:
			if shade_step < 0:
				title_visible = true
				title_hold = 0x3C
				idle = 0
				push_start.modulate = Color(1, 1, 1)
				push_start.visible = true
			shade_step = 0
		return
	if title_visible:
		_update_title(pressed)
		return
	if transitioning:
		_update_transition()
		return
	_update_menu(pressed, repeat)


func _apply_shade() -> void:
	shade_rect.color = Color(shade / 255.0, shade / 255.0, shade / 255.0)


func _update_title(pressed: Dictionary) -> void:
	if title_hold != 0:
		title_hold -= 1
	else:
		title_level += title_dir
		var c := title_level & 0xFF
		if c - 0x41 >= 0x3F or c - 0x41 < 0:
			if c >= 0x80:
				title_hold = 0x3C
			title_dir = -title_dir
	push_start.modulate = Color(minf(title_level / 128.0, 1.0), minf(title_level / 128.0, 1.0), minf(title_level / 128.0, 1.0))
	if pressed.has("start") or pressed.has("confirm"):
		sound.emit(7)
		title_visible = false
		push_start.visible = false
		_start_transition(0)
		shade_step = 1
		return
	idle += 1
	if idle >= IDLE_LIMIT:
		demo_requested.emit()


func _update_transition() -> void:
	var moved := 0
	for i in ENTRY_COUNT:
		if entry_timer[i] <= 0:
			continue
		entry_timer[i] -= 1
		var first_page := menu_id < 5
		if (first_page and i >= 5) or (not first_page and i < 5):
			entry_shown[i] = false
		else:
			var frame: int = 0x10 - entry_timer[i]
			var value: int = entry_to[i]
			if frame != 0x10:
				var delta: int = entry_to[i] - entry_from[i]
				value = entry_from[i] + int(sin(frame * 64 * TAU / 4096.0) * delta)
			entry_x[i] = value
			if (frame & 1) != 0:
				_spawn_afterimage(i)
			entry_shown[i] = true
		moved += 1
		_set_entry_state(i, i == menu_id)
		_sync_entry(i)
	if moved != 0:
		return
	transitioning = false
	if transition_mode == 0:
		return
	if cancelled:
		if menu_id < 5:
			for i in ENTRY_COUNT:
				entry_shown[i] = false
				_sync_entry(i)
			shade_step = -1
		else:
			_start_transition(0)
			_set_entry_state(menu_id, false)
			menu_id = 1
			_set_entry_state(menu_id, true)
		cancelled = false
		return
	if menu_id != 1:
		chosen.emit(menu_id)
		return
	_start_transition(0)
	_set_entry_state(menu_id, false)
	menu_id = 5
	_set_entry_state(menu_id, true)


func _update_menu(pressed: Dictionary, repeat: Dictionary) -> void:
	if repeat.has("up") or repeat.has("down"):
		var base := 5 if menu_id >= 5 else 0
		var count := 6 if menu_id >= 5 else 5
		_set_entry_state(menu_id, false)
		if repeat.has("up"):
			menu_id = (menu_id - base + count - 1) % count + base
		else:
			menu_id = (menu_id - base + count + 1) % count + base
		_set_entry_state(menu_id, true)
		sound.emit(6)
		return
	if not (pressed.has("start") or pressed.has("cancel") or pressed.has("confirm")):
		return
	if pressed.has("cancel"):
		if menu_id < 5:
			sound.emit(9)
			return
		sound.emit(8)
		cancelled = true
	else:
		sound.emit(7)
		match menu_id:
			1:
				loading = true
				load_requested.emit()
				return
			10:
				save_requested.emit()
				return
	_start_transition(1)


func _spawn_afterimage(i: int) -> void:
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = entries[i].texture
	sprite.position = entries[i].position
	sprite.modulate = Color(0.5, 0.5, 0.5, 1.0)
	sprite.material = sharp_add
	world.add_child(sprite)
	afterimages.append([sprite, 0x80])


## the front-end entry afterimage update: the colour falls 8 a frame until it is black, then the sprite is released.
func _fade_afterimages() -> void:
	for item in afterimages.duplicate():
		item[1] -= 8
		if item[1] <= 0:
			item[0].queue_free()
			afterimages.erase(item)
		else:
			var f: float = item[1] / 128.0
			item[0].modulate = Color(f, f, f)
