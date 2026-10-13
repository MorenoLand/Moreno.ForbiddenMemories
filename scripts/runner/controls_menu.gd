extends PanelContainer
## F1: shows the pad bindings and lets the player rebind a button by clicking it and pressing a key, pad button or mouse button.

var input_map: RefCounted
var waiting := ""
var buttons: Dictionary = {}


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.text = "Controls  (F1 closes; click a row, then press a key, pad button or mouse button)"
	box.add_child(title)
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	for action in input_map.ACTIONS:
		var name := Label.new()
		name.text = action[1]
		grid.add_child(name)
		var button := Button.new()
		button.custom_minimum_size = Vector2(380, 0)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_begin.bind(action[0]))
		grid.add_child(button)
		buttons[action[0]] = button
	var reset := Button.new()
	reset.text = "Reset to defaults"
	reset.pressed.connect(_reset)
	box.add_child(reset)
	refresh()


func refresh() -> void:
	for action in buttons:
		buttons[action].text = input_map.summary(action) if waiting != action else "press a key / button..."


func toggle() -> void:
	visible = not visible
	waiting = ""
	refresh()


func _begin(action: String) -> void:
	waiting = action
	refresh()


func _reset() -> void:
	input_map.reset()
	input_map.save_file()
	refresh()


func _input(event: InputEvent) -> void:
	if not visible or waiting == "":
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		return   # clicks on the rows themselves select what to rebind
	var entry: Dictionary = input_map.capture(event)
	if entry.is_empty():
		return
	input_map.rebind(waiting, entry)
	waiting = ""
	refresh()
	get_viewport().set_input_as_handled()
