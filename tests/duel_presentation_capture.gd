extends SceneTree
## Scripted duel presentation capture (magic, equip, trap, fusion) for comparing with the reference picture series. The
## player's hand is set to the cards the scenario plays; the picture is saved every EVERY physics frames (320 x 240) with a
## log line of the duel's state. Run it minimized and silent:
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --position -32000,-32000 --resolution 640x480 --minimized --audio-driver Dummy --path G:\Development\Godot\Projects\ForbiddenMemories -s res://tests/duel_presentation_capture.gd -- --scen=magic --out=C:\path\to\folder

const DuelScene := preload("res://scripts/duel/duel_scene.gd")
const GameStateScript := preload("res://scripts/state/game_state.gd")

var scen := "magic"
var out_dir := "user://fx"
var every := 8
var duel
var pf_last := -1
var capturing := false
var steps: Array = []
var step_left := 0
var log_file: FileAccess
var t := 0
var done := false
var swapped := false

const SCENES := {
	"magic": {"deck": [5, 330, 4, 6, 7, 8, 9, 10], "hand": [5, 330, 4, 6, 7]},
	"equip": {"deck": [4, 315, 5, 6, 7, 8, 9, 10], "hand": [4, 315, 5, 6, 7]},
	"trap": {"deck": [5, 681, 4, 6, 7, 8, 9, 10], "hand": [5, 681, 4, 6, 7]},
	"fusion": {"deck": [2, 8, 5, 6, 7, 9, 10, 11], "hand": [2, 8, 5, 6, 7]},
}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scen="):
			scen = arg.substr(7)
		elif arg.begins_with("--out="):
			out_dir = arg.substr(6)
		elif arg.begins_with("--every="):
			every = int(arg.substr(8))
	DirAccess.make_dir_recursive_absolute(out_dir)
	log_file = FileAccess.open(out_dir.path_join("log.txt"), FileAccess.WRITE)
	GameStateScript.deck = SCENES[scen]["deck"].duplicate()
	duel = DuelScene.new()
	duel.opponent_id = 1
	duel.terrain = 0
	duel.engine_seed = 7
	root.add_child(duel)
	steps = _script()
	physics_frame.connect(_on_tick)


func _log(line: String) -> void:
	print(line)
	log_file.store_line(line)
	log_file.flush()


func _key(code: int, down: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = down
	Input.parse_input_event(e)


func _hand_index_of(card: int) -> int:
	return duel.engine.state.sides[0].hand.find(card)


func _script() -> Array:
	# ops: ["wait", n] / ["until_hand"] / ["key", keycode] (3 frames down, 3 up) / ["cap", bool] / ["call", name]
	var s: Array = [["cap", true], ["until_hand"]]
	match scen:
		"magic":
			s += [["move_to", 330], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_D], ["wait", 3], ["key", KEY_E], ["wait", 400]]
		"equip":
			# the monster first (the reference plays it and ends the turn), then the equip on it
			s += [["cap", false], ["move_to", 4], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_D],
				["wait", 3], ["key", KEY_E], ["until_mode", "dest"], ["key", KEY_E], ["wait", 4], ["if_star_confirm"], ["if_star_confirm"], ["until_idle"], ["cap", false], ["end_turn"], ["until_hand"], ["wait", 30],
				["cap", true], ["move_to", 315], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_D], ["wait", 3], ["key", KEY_E], ["until_mode", "equip_pick"], ["wait", 20], ["key", KEY_E], ["wait", 30], ["until_idle"], ["wait", 20], ["key", KEY_W], ["wait", 10], ["key", KEY_E], ["wait", 20], ["key", KEY_E], ["wait", 10], ["key", KEY_E], ["until_idle"], ["wait", 300]]
		"trap":
			s += [["move_to", 681], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_E], ["until_mode", "dest"], ["key", KEY_E], ["until_idle"], ["wait", 30],
				["end_turn"], ["until_hand"], ["wait", 30], ["wait", 300]]
		"fusion":
			s += [["move_to", 2], ["key", KEY_F], ["wait", 6], ["move_to", 8], ["key", KEY_F], ["wait", 6], ["key", KEY_E],
				["wait", 20], ["key", KEY_E], ["wait", 40], ["key", KEY_E], ["wait", 40], ["key", KEY_E], ["wait", 360]]
	return s


func _busy() -> bool:
	return duel.fx.busy() or duel.mode in ["deal", "foe", "over", "result", "centre", "centre_back"]


func _snap() -> void:
	var img: Image = root.get_texture().get_image()
	img.resize(320, 240, Image.INTERPOLATE_NEAREST)
	var pf := Engine.get_physics_frames()
	var name := "f%05d.png" % pf
	img.save_png(out_dir.path_join(name))
	var s = duel.engine.state
	var hand: Array = []
	for c in s.sides[0].hand:
		hand.append(c)
	var f0: Array = []
	for z in s.sides[0].monsters:
		f0.append(z["id"] if z != null else null)
	var f0s: Array = []
	for z in s.sides[0].traps:
		f0s.append(z["id"] if z != null else null)
	var f1s: Array = []
	for z in s.sides[1].traps:
		f1s.append(z["id"] if z != null else null)
	_log("%s pf=%d mode=%s timer=%d busy=%s turn=%d hand=%s m0=%s s0=%s s1=%s lp=%d,%d" % [name, pf, duel.mode, duel.timer, str(_busy()),
		s.turn_side, str(hand), str(f0), str(f0s), str(f1s), s.sides[0].lp, s.sides[1].lp])


func _on_tick() -> void:
	t += 1
	if t > 12000 or done:
		_log("DONE watchdog or end at %d" % t)
		log_file.close()
		quit(0)
		return
	if duel == null or not duel.ready_ok:
		return
	if not swapped:
		# the opening hand: the scenario's cards, in the order the reference deals them (the deck keeps the rest)
		swapped = true
		duel.engine.state.sides[0].hand = SCENES[scen]["hand"].duplicate()
		duel.refresh()
		_log("hand set: %s" % str(duel.engine.state.sides[0].hand))
	var pf := Engine.get_physics_frames()
	if capturing and pf % every == 0 and pf != pf_last:
		pf_last = pf
		_snap()
	if step_left > 0:
		step_left -= 1
		return
	if steps.is_empty():
		_log("SCRIPT DONE pf=%d" % pf)
		log_file.close()
		done = true
		quit(0)
		return
	var op: Array = steps[0]
	match op[0]:
		"wait":
			step_left = int(op[1])
			steps.pop_front()
		"if_star_confirm":
			# the guardian star is asked once the placement has shown: wait for the box (or for the field to be idle without one)
			if duel.mode == "star":
				steps.pop_front()
				steps.push_front(["key", KEY_E])
			elif not _busy() and duel.mode in ["hand", "field"]:
				steps.pop_front()
		"until_mode":
			if duel.mode == str(op[1]):
				steps.pop_front()
		"until_idle":
			if not _busy() and duel.mode in ["hand", "field"]:
				steps.pop_front()
		"until_hand":
			if duel.mode == "hand" and duel.engine.state.turn_side == 0 and not _busy():
				steps.pop_front()
		"cap":
			capturing = bool(op[1])
			steps.pop_front()
		"key":
			# held for three frames, released for three
			_log("KEY %d pf=%d mode=%s" % [int(op[1]), Engine.get_physics_frames(), duel.mode])
			_key(int(op[1]), true)
			steps.pop_front()
			steps.push_front(["release", int(op[1])])
			step_left = 3
		"release":
			_key(int(op[1]), false)
			steps.pop_front()
			step_left = 3
		"move_to":
			var at := _hand_index_of(int(op[1]))
			var cur: int = duel.hand_index
			steps.pop_front()
			if at > cur:
				steps.push_front(["move_to", int(op[1])])
				steps.push_front(["key", KEY_D])
			elif at >= 0 and at < cur:
				steps.push_front(["move_to", int(op[1])])
				steps.push_front(["key", KEY_A])
		"end_turn":
			_key(KEY_ENTER, true)
			steps.pop_front()
			steps.push_front(["release", KEY_ENTER])
			step_left = 3
	return


func _process(_delta: float) -> bool:
	return false
