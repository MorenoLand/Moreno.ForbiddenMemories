extends PanelContainer
## F9: window, sound and picture options, saved to user://settings.json and applied at once (except the internal resolution, used on restart).
## The picture (its sampling and the scanlines) and the stretch (F2) belong to ScreenFit, so the panel shows and changes the values the
## game uses. The HD art switch is read by mod_art.gd when a picture is loaded: it applies to the screens opened after it.

const PATH := "user://settings.json"
const ScreenFit := preload("res://scripts/system/screen_fit.gd")

var values := {"volume": 1.0, "fullscreen": false, "vsync": true, "scale": 0, "debug": false, "hd_art": true}
var on_change: Callable


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH   # the panel grows from its centre, so it stays on the window whatever its size
	grow_vertical = Control.GROW_DIRECTION_BOTH
	_load()
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.text = "Options  (F9 closes)"
	box.add_child(title)
	_slider(box, "Volume", "volume", 0.0, 1.0, 0.05)
	_toggle(box, "Fullscreen", "fullscreen")
	_check(box, "Stretch to window (F2; off keeps 4:3)", ScreenFit.stretch, _set_stretch)
	_toggle(box, "V-sync", "vsync")
	_picture(box)
	_toggle(box, "HD art where the mod is installed (screens opened after this)", "hd_art")
	_toggle(box, "Show debug line (F3)", "debug")
	var scale_row := HBoxContainer.new()
	var scale_label := Label.new()
	scale_label.text = "Internal resolution multiplier (0 = automatic, applies on restart)"
	scale_row.add_child(scale_label)
	var scale_box := SpinBox.new()
	scale_box.min_value = 0
	scale_box.max_value = 8
	scale_box.value = int(values["scale"])
	scale_box.value_changed.connect(func(v): values["scale"] = int(v); _save())
	scale_row.add_child(scale_box)
	box.add_child(scale_row)
	apply()


func _toggle(box: Control, text: String, key: String) -> void:
	_check(box, text, bool(values[key]), func(on): values[key] = on; apply(); _save())


func _check(box: Control, text: String, on: bool, change: Callable) -> void:
	var check := CheckBox.new()
	check.text = text
	check.button_pressed = on
	check.toggled.connect(change)
	box.add_child(check)


## The picture: the sampling (Pixel, Sharp, Smooth) and the scanlines (F5 and F6 in the game do the same).
func _picture(box: Control) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Picture"
	label.custom_minimum_size = Vector2(120, 0)
	row.add_child(label)
	var choice := OptionButton.new()
	for text in ScreenFit.FILTER_LABELS:
		choice.add_item(text)
	choice.select(ScreenFit.filter)
	choice.item_selected.connect(func(index): ScreenFit.set_filter(index))
	row.add_child(choice)
	box.add_child(row)
	_check(box, "Scanlines (F6)", ScreenFit.crt, func(on): ScreenFit.set_crt(on))
	# the PS1 4x4 dither on the shaded pictures (the duel's 3D board and the menu wall); off keeps the smooth shading
	_check(box, "PS1 dithering on shaded 3D (duel board, menu wall)", ScreenFit.dither, func(on): ScreenFit.set_dither(on))


func _set_stretch(on: bool) -> void:
	ScreenFit.stretch = on
	ScreenFit.save_setting("stretch", on)
	get_tree().call_group("fit", "refit")


func _slider(box: Control, text: String, key: String, low: float, high: float, step: float) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(120, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.value = float(values[key])
	slider.custom_minimum_size = Vector2(240, 0)
	slider.value_changed.connect(func(v): values[key] = v; apply(); _save())
	row.add_child(slider)
	box.add_child(row)


func toggle() -> void:
	visible = not visible


func apply() -> void:
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		# The original has no volume scale: the master bus is 0 dB at full volume (the slider only lowers it).
		AudioServer.set_bus_volume_db(master, linear_to_db(maxf(float(values["volume"]), 0.0001)))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if values["vsync"] else DisplayServer.VSYNC_DISABLED)
	var window := get_window()
	if window != null:
		if not OS.has_feature("web"):   # a browser refuses fullscreen without a user gesture, and the page owns the window size
			window.mode = Window.MODE_FULLSCREEN if values["fullscreen"] else Window.MODE_WINDOWED
	if on_change.is_valid():
		on_change.call(values)


func _load() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if typeof(data) == TYPE_DICTIONARY:
		for key in values:
			if data.has(key):
				values[key] = data[key]


## Merges the panel's values into the file: the keys of the picture and the stretch (ScreenFit's) are kept as they are.
func _save() -> void:
	ScreenFit.save_settings(values)
