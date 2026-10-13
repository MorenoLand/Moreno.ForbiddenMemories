extends SceneTree
## Screenshot harness for the trade, the second card and the 2P setup screens (the menu audit in docs/quality-report.md).
## It writes PNG pictures of each screen to the folder given after `--out=` and then prints DONE. It needs a window (the picture is
## read from it), so run it minimized and silent:
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --minimized --audio-driver Dummy --path G:\Development\Godot\Projects\ForbiddenMemories --script res://tests/screen_capture.gd -- --out=C:\path\to\folder
## The player's own saves (user://save.json and user://save2.json) are set aside while it runs and put back afterwards, so the
## harness never leaves its test saves behind. Each case is run in turn; the frames are counted with _process.

const GameState := preload("res://scripts/state/game_state.gd")
const DuelData := preload("res://scripts/duel/duel_data.gd")
const SecondCard := preload("res://scripts/menu/second_card.gd")
const Trade := preload("res://scripts/menu/trade.gd")
const TwoPlayerSetup := preload("res://scripts/menu/two_player_setup.gd")
const MessageBox := preload("res://scripts/ui/message_box.gd")

const SAVE_ONE := "user://save.json"
const SAVE_TWO := "user://save2.json"
const SET_ASIDE := "user://capture_backup_"
const CASES := ["trade", "trade_offers", "trade_notice", "second_card", "two_player", "two_player_card", "two_player_value", "two_player_legend"]
const WAIT_FRAMES := 120

var out_dir := ""
var cases: Array = []
var current := ""
var frames := 0
var node: Node = null
var phase := 0            # 0 set up the case, 1 wait, 2 capture and tear down
var backups: Dictionary = {}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.substr(6)
	if out_dir == "":
		out_dir = OS.get_user_data_dir() + "/captures"
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = Vector2i(640, 480)
	DisplayServer.window_set_size(Vector2i(640, 480))
	for path in [SAVE_ONE, SAVE_TWO]:
		if FileAccess.file_exists(path):
			backups[path] = FileAccess.get_file_as_string(path)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	cases = CASES.duplicate()


func _process(_delta: float) -> bool:
	if node == null and phase == 0:
		if cases.is_empty():
			_restore()
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
		image.save_png(out_dir + "/" + current + ".png")
		print("saved ", current)
		if node != null:
			node.queue_free()
		node = null
		phase = 0
	return false


func _restore() -> void:
	for path in [SAVE_ONE, SAVE_TWO]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if backups.has(path):
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string(backups[path])
			file.close()


## The fixture saves: player 1 is a starter deal of a named duelist, the second card is a second starter deal (for the trade).
func _write_fixture(with_second: bool) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var data := DuelData.new()
	data.load_all()
	GameState.reset()
	GameState.player_name = [0x8260, 0x8261, 0x8262, 0x8263, 0x8264, 0x8265]
	GameState.deck = data.deal_starter_deck(rng)
	# owned: the deck and a second deal's cards (the chest), as a played campaign has
	var owned := PackedInt32Array()
	owned.resize(SecondCard.CARD_COUNT)
	for id in GameState.deck + data.deal_starter_deck(rng):
		owned[int(id) - 1] += 1
	GameState.card_counts = owned
	GameState.save_game()
	if with_second:
		SecondCard.write_second_card(SecondCard.starter_card(rng))
	elif FileAccess.file_exists(SAVE_TWO):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_TWO))


func _setup(name: String) -> void:
	match name:
		"trade":
			_write_fixture(true)
			node = Trade.new()
		"trade_offers":
			_write_fixture(true)
			node = Trade.new()
		"trade_notice":
			_write_fixture(false)
			node = MessageBox.new()
			node.string_id = 0xD2
		"second_card":
			_write_fixture(false)
			node = SecondCard.new()
		"two_player":
			_write_fixture(true)
			node = TwoPlayerSetup.new()
		"two_player_card":
			_write_fixture(false)
			node = TwoPlayerSetup.new()
		"two_player_value":
			# the reference after one left press: player 1's life points at 7500 (the bar and digits are set without the count-up)
			_write_fixture(true)
			node = TwoPlayerSetup.new()
			node.life[0] = 7500
			node.shown[0] = 7500
		"two_player_legend":
			# the reference after one up press: player 1 is in the legend, its star is not drawn
			_write_fixture(true)
			node = TwoPlayerSetup.new()
			node.mode[0] = 0
	if node != null:
		root.add_child(node)
	if name == "trade_offers":
		# three cards offered by player 1 (the cursor moves down the list between them), player 2 offers one and settles
		for i in 3:
			node.sides[0]["cursor"] = i
			node._rebuild(0)
			node._add(0)
		node.sides[1]["cursor"] = 2
		node._rebuild(1)
		node._add(1)
		node._settle(1)
