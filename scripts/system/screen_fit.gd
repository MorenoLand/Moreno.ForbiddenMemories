extends Node
## Fits the game's 320x240 picture to the window. By default the picture is stretched to fill the whole window (16:9 on a wide
## screen); F2 switches to the original 4:3 shape with bars. Nodes that own a 320x240 world join the "fit" group and implement
## refit(); they call ScreenFit.apply(world, area) there.
##
## The picture's sampling is the player's choice, kept in user://settings.json: F5 cycles Pixel (nearest), Sharp (the default,
## sharp bilinear) and Smooth (bilinear); F6 toggles faint scanlines. Every picture material made by make_material() follows the
## choice at once. settings_menu.gd (F9) shows the same options.
##
## The PS1 dither (F9, off by default) is a separate option: the shaded pictures (the duel's 3D board, the main menu's wall shade)
## take the GPU's 4x4 dither matrix at each colour step; flat sprites and text never do, as on the console.

enum Filter { PIXEL, SHARP, SMOOTH }
const FILTER_NAMES := ["pixel", "sharp", "smooth"]
const FILTER_LABELS := ["Pixel (nearest)", "Sharp (default)", "Smooth (bilinear)"]
const SETTINGS := "user://settings.json"

static var stretch := true
static var filter: int = Filter.SHARP
static var crt := false
static var dither := false            # the PS1 4x4 dither on shaded pictures (the duel's 3D board, the menu wall): off by default
static var _materials: Array = []     # weak references to the picture materials: a change of the sampling reaches every screen
static var _read := false


## `height` is the picture's real height when a screen is drawn shorter than 240 lines (the options screen is 224).
## `width` is the picture's width when it is not the 320 of the game's screens (the opening movie's wide picture is 480).
static func apply(world: Node2D, area: Vector2, height := 240.0, width := 320.0) -> void:
	if stretch:
		world.scale = Vector2(area.x / width, area.y / height)
		world.position = Vector2.ZERO
	else:
		var factor := minf(area.x / width, area.y / height)
		world.scale = Vector2(factor, factor)
		world.position = (area - Vector2(width, height) * factor) * 0.5


## Lets mouse events through every Control below `root` (backdrops and fade rectangles would otherwise take them before the
## screen's own handler sees them).
static func pass_mouse(root: Node) -> void:
	for child in root.get_children():
		if child is Control:
			child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pass_mouse(child)


## The game's pixels, drawn with the player's sampling (see the header). `deblock` is set by the caller where it wants it.
## shaded: the picture is a shaded 3D picture (the duel's board), which takes the PS1 dither when the F9 option is on (see the shader).
## subtractive: the picture is taken from what is behind it (a name plate over the card's frame).
static func make_material(additive := false, shaded := false, subtractive := false) -> ShaderMaterial:
	_load_picture_settings()
	var material := ShaderMaterial.new()
	var shader_path := "res://shaders/sharp_pixels.gdshader"
	if subtractive:
		shader_path = "res://shaders/sharp_pixels_sub.gdshader"
	elif additive:
		shader_path = "res://shaders/sharp_pixels_add.gdshader"
	material.shader = load(shader_path)
	material.set_meta("shaded", shaded)
	_set_parameters(material)
	_materials.append(weakref(material))
	return material


## The menu wall's shade: a Gouraud quad subtracted from the wall (dither_subtract.gdshader). It takes the PS1 dither when the option is on.
static func make_subtract_material() -> ShaderMaterial:
	_load_picture_settings()
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/dither_subtract.gdshader")
	material.set_meta("shaded", true)
	_set_parameters(material)
	_materials.append(weakref(material))
	return material


static func set_filter(value: int) -> void:
	filter = clampi(value, 0, 2)
	_refresh()
	save_setting("filter", FILTER_NAMES[filter])


static func set_crt(on: bool) -> void:
	crt = on
	_refresh()
	save_setting("crt", on)


static func set_dither(on: bool) -> void:
	dither = on
	_refresh()
	save_setting("dither", on)


## The saved picture settings (user://settings.json); a missing or unreadable file keeps the defaults.
static func _load_picture_settings() -> void:
	if _read:
		return
	_read = true
	var index := FILTER_NAMES.find(str(load_setting("filter", "")))
	filter = index if index >= 0 else Filter.SHARP
	crt = bool(load_setting("crt", false))
	dither = bool(load_setting("dither", false))
	stretch = bool(load_setting("stretch", true))


static func _set_parameters(material: ShaderMaterial) -> void:
	material.set_shader_parameter("filter_mode", filter)
	material.set_shader_parameter("crt", 1.0 if crt else 0.0)
	# only a shaded picture takes the dither (the sharp shader's flat sprites never do)
	material.set_shader_parameter("dither", 1.0 if (dither and material.get_meta("shaded", false)) else 0.0)


static func _refresh() -> void:
	var alive: Array = []
	for ref in _materials:
		var material = ref.get_ref()
		if material != null:
			_set_parameters(material)
			alive.append(ref)
	_materials = alive


## One value of user://settings.json. The file is shared with settings_menu.gd, which keeps the keys it does not own.
static func load_setting(key: String, default: Variant) -> Variant:
	return _settings_file().get(key, default)


static func save_setting(key: String, value: Variant) -> void:
	save_settings({key: value})


## Writes the given entries into user://settings.json and keeps every other key of the file.
static func save_settings(entries: Dictionary) -> void:
	var data := _settings_file()
	data.merge(entries, true)
	var file := FileAccess.open(SETTINGS, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data, "\t"))


static func _settings_file() -> Dictionary:
	if FileAccess.file_exists(SETTINGS):
		var data = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS))
		if typeof(data) == TYPE_DICTIONARY:
			return data
	return {}


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F2:
			stretch = not stretch
			save_setting("stretch", stretch)
			get_tree().call_group("fit", "refit")
		KEY_F5:
			set_filter((filter + 1) % 3)
			_flash("PICTURE: " + FILTER_LABELS[filter])
		KEY_F6:
			set_crt(not crt)
			_flash("SCANLINES " + ("ON" if crt else "OFF"))


## A short notice at the bottom left of the window (the picture setting that was just changed).
func _flash(message: String) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 101
	var label := Label.new()
	label.text = message
	label.position = Vector2(12, get_viewport().get_visible_rect().size.y - 34)
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(1, 0.95, 0.4))
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)
	layer.add_child(label)
	add_child(layer)
	get_tree().create_timer(1.5).timeout.connect(func(): layer.queue_free())
