extends SceneTree
## Screenshot harness for the card view (the Library's and the Build Deck's viewers) on a monster, a fusion monster, a ritual, a magic,
## a trap and an equip card. It writes PNG pictures to the folder given after `--out=` and then prints DONE. It needs a window (the
## picture is read from it), so run it minimized and silent:
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --minimized --audio-driver Dummy --path G:\Development\Godot\Projects\ForbiddenMemories --script res://tests/card_view_capture.gd -- --out=C:\path\to\folder
## Each case marks its card as seen in the session's memory only (GameState is not saved here), opens the card's view, waits for the slide
## and captures the window. A case with card 0 captures the Library grid alone.

const GameState := preload("res://scripts/state/game_state.gd")
const Library := preload("res://scripts/menu/library.gd")
const BuildDeck := preload("res://scripts/menu/build_deck.gd")

const CASES := [
	["library_monster", "library", 1],
	["library_fusion", "library", 551],
	["library_ritual", "library", 665],
	["library_magic", "library", 320],
	["library_trap", "library", 681],
	["library_equip", "library", 301],
	["library_grid", "library", 0],
	["build_monster", "build", 1],
	["build_ritual", "build", 665],
	["build_magic", "build", 320],
]
const WAIT_FRAMES := 60

var out_dir := ""
var cases: Array = []
var current: Array = []
var frames := 0
var node: Node = null
var phase := 0            # 0 set up the case, 1 wait, 2 capture and tear down


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.substr(6)
	if out_dir == "":
		out_dir = OS.get_user_data_dir() + "/captures"
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = Vector2i(640, 480)
	DisplayServer.window_set_size(Vector2i(640, 480))
	cases = CASES.duplicate()


func _process(_delta: float) -> bool:
	if node == null and phase == 0:
		if cases.is_empty():
			print("DONE")
			quit(0)
			return false
		current = cases.pop_front()
		_setup(current)
		phase = 1
		frames = 0
		return false
	frames += 1
	if phase == 1 and frames >= WAIT_FRAMES:
		var image := root.get_texture().get_image()
		image.save_png(out_dir + "/" + current[0] + ".png")
		print("saved ", current[0])
		if node != null:
			node.queue_free()
		node = null
		phase = 0
	return false


func _setup(case: Array) -> void:
	var id: int = case[2]
	if id > 0:
		GameState.mark_card_seen(id)
	if case[1] == "library":
		var library: Control = Library.new()
		root.add_child(library)
		var k := id - 1
		var right := k % 200 >= 100
		var within := k % 200 - (100 if right else 0)
		library.row = (k / 200) * 10 + within / 10
		library.column = within % 10 + (10 if right else 0)
		library.cursor_pos = library._rest(library.column, library.row)
		library.rest_pos = library.cursor_pos
		library._scroll()
		if id > 0:
			library._open_card()
		node = library
	else:
		var deck: Control = BuildDeck.new()
		root.add_child(deck)
		deck._open_viewer(id)
		node = deck
