extends SceneTree
## Scripted duel presentation capture (magic, equip, trap, fusion, ritual, faceup, battle_a to battle_g) for comparing with the reference picture series.
## The battle_* scenarios put the monsters on the field (BATTLES) and attack (or let the CPU attack, battle_g) from its start. The
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
var star_settle := 0
const DEBUG_FX := false

const SCENES := {
	"magic": {"deck": [5, 330, 4, 6, 7, 8, 9, 10], "hand": [5, 330, 4, 6, 7]},
	"equip": {"deck": [4, 315, 5, 6, 7, 8, 9, 10], "hand": [4, 315, 5, 6, 7]},
	"trap": {"deck": [5, 681, 4, 6, 7, 8, 9, 10], "hand": [5, 681, 4, 6, 7]},
	"fusion": {"deck": [2, 8, 5, 6, 7, 9, 10, 11], "hand": [2, 8, 5, 6, 7]},
	"ritual": {"deck": [1, 1, 1, 675, 5, 6, 7, 8, 9, 10], "hand": [1, 1, 1, 675, 5]},
	"faceup": {"deck": [4, 315, 5, 6, 7, 8, 9, 10], "hand": [4, 315, 5, 6, 7]},
	"hand_magic": {"deck": [5, 330, 4, 6, 7, 8, 9, 10], "hand": [5, 330, 4, 6, 7]},
	"hand_equip": {"deck": [4, 315, 5, 6, 7, 8, 9, 10], "hand": [4, 315, 5, 6, 7]},
	"hand_trap": {"deck": [5, 681, 4, 6, 7, 8, 9, 10], "hand": [5, 681, 4, 6, 7]},
	"battle_a": {"deck": [1, 428, 5, 6, 7, 8, 9, 10], "hand": [5, 6, 7, 8, 9]},
	"battle_b": {"deck": [123, 192, 5, 6, 7, 8, 9, 10], "hand": [5, 6, 7, 8, 9]},
	"battle_c": {"deck": [123, 428, 5, 6, 7, 8, 9, 10], "hand": [5, 6, 7, 8, 9]},
	"battle_d1": {"deck": [1, 428, 5, 6, 7, 8, 9, 10], "hand": [5, 6, 7, 8, 9]},
	"battle_d2": {"deck": [123, 428, 5, 6, 7, 8, 9, 10], "hand": [5, 6, 7, 8, 9]},
	"battle_e": {"deck": [1, 428, 5, 6, 7, 8, 9, 10], "hand": [5, 6, 7, 8, 9]},
	"battle_f": {"deck": [1, 5, 6, 7, 8, 9, 10, 11], "hand": [5, 6, 7, 8, 9]},
	"battle_g": {"deck": [428, 5, 6, 7, 8, 9, 10, 11], "hand": [5, 6, 7, 8, 9]},
}
# battle scenarios: the monsters are set on the field before the attack (the reference's cases: its player's monster and the CPU's
# monster, by card id; "fu"/"fd" face up or down, "atk"/"def" position). Attacker zone a, target zone t (-1: a direct attack).
const BATTLES := {
	"battle_a": {"mine": [[1, "fu", "atk"]], "foe": [[428, "fu", "atk"]], "a": 0, "t": 0},
	"battle_b": {"mine": [[123, "fu", "atk"]], "foe": [[192, "fu", "atk"]], "a": 0, "t": 0},
	"battle_c": {"mine": [[123, "fu", "atk"]], "foe": [[428, "fu", "atk"]], "a": 0, "t": 0},
	"battle_d1": {"mine": [[1, "fu", "atk"]], "foe": [[428, "fu", "def"]], "a": 0, "t": 0},
	"battle_d2": {"mine": [[123, "fu", "atk"]], "foe": [[428, "fu", "def"]], "a": 0, "t": 0},
	"battle_e": {"mine": [[1, "fu", "atk"]], "foe": [[428, "fd", "def"]], "a": 0, "t": 0},
	"battle_f": {"mine": [[1, "fu", "atk"], [123, "fu", "atk"]], "foe": [], "a": 1, "t": -1},
	"battle_g": {"mine": [], "foe": [[428, "fu", "atk"]], "a": 0, "t": -1, "foe_attacks": true},
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
	if BATTLES.has(scen):
		# the field is set up, then the battle (or the CPU's attack) is pictured from its start to the field's return
		s = [["cap", false], ["until_hand"], ["call", "setup_battle"], ["wait", 30], ["call", "battle"], ["wait", 480], ["cap", false]]
		return s
	match scen:
		"magic":
			s += [["move_to", 330], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_D], ["wait", 3], ["key", KEY_E], ["wait", 400]]
		"equip":
			# the monster first (the reference plays it and ends the turn), then the equip on it
			s += [["cap", false], ["move_to", 4], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_D],
				["wait", 3], ["key", KEY_E], ["until_mode", "dest"], ["key", KEY_E], ["wait", 4], ["star_press"], ["until_idle"], ["cap", false], ["end_turn"], ["until_hand"], ["wait", 30],
				["cap", true], ["move_to", 315], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_D], ["wait", 3], ["key", KEY_E], ["until_mode", "equip_pick"], ["wait", 20], ["key", KEY_E], ["wait", 30], ["until_idle"], ["wait", 20], ["key", KEY_W], ["wait", 10], ["key", KEY_E], ["wait", 20], ["key", KEY_E], ["wait", 10], ["key", KEY_E], ["until_idle"], ["wait", 300]]
		"trap":
			s += [["move_to", 681], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_E], ["until_mode", "dest"], ["key", KEY_E], ["until_idle"], ["wait", 30],
				["end_turn"], ["until_hand"], ["wait", 30], ["wait", 300]]
		"ritual":
			# Ultimate Dragon: three Blue-eyes (3000 ATK, out of the computer's reach) first, one a turn (the field phase after a placement
			# does not go back to the hand), then the ritual from the hand on the next turn
			for tribute in [1, 1, 1]:
				s += [["move_to", tribute], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_D], ["wait", 3], ["key", KEY_E],
					["until_mode", "dest"], ["key", KEY_E], ["wait", 4], ["star_press"], ["until_idle"],
					["end_turn"], ["until_hand"], ["wait", 30]]   # one placement a turn: the field phase after it does not go back to the hand
			s += [["cap", true], ["move_to", 675], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_D], ["wait", 3], ["key", KEY_E],
				["star_press"], ["until_idle"], ["wait", 400]]   # the summoned monster's guardian star is asked
		"hand_magic", "hand_equip", "hand_trap":
			# the first hand phase with the card art loaded (400 frames after the deal): the picture of the hand only
			s += [["cap", false], ["until_hand"], ["wait", 400], ["cap", true], ["wait", 8], ["cap", false]]
		"faceup":
			# the monster face up at the first zone (right, cross, cross as the reference plays it), then the settled picture
			s += [["cap", false], ["move_to", 4], ["key", KEY_E], ["until_mode", "centre"], ["wait", 14], ["key", KEY_D], ["wait", 3], ["key", KEY_E],
				["until_mode", "dest"], ["key", KEY_E], ["wait", 4], ["star_press"], ["until_idle"], ["wait", 400], ["cap", true], ["wait", 16], ["cap", false]]
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
	var f1: Array = []
	for z in s.sides[1].monsters:
		f1.append(z["id"] if z != null else null)
	var f0s: Array = []
	for z in s.sides[0].traps:
		f0s.append(z["id"] if z != null else null)
	var f1s: Array = []
	for z in s.sides[1].traps:
		f1s.append(z["id"] if z != null else null)
	_log("%s pf=%d mode=%s timer=%d busy=%s turn=%d hand=%s m0=%s s0=%s s1=%s lp=%d,%d star=%d m1=%s" % [name, pf, duel.mode, duel.timer, str(_busy()),
		s.turn_side, str(hand), str(f0), str(f0s), str(f1s), s.sides[0].lp, s.sides[1].lp, duel.star_zone, str(f1)])
	if DEBUG_FX:
		_log("  fx %s" % duel.fx.debug_state())
		for entry in duel.fx.programs:
			var cv = entry["canvas"]
			var lay := []
			for l in cv._layers:
				lay.append("%d/%s/%s" % [l.records.size(), str(l.visible), str(l.global_position)])
			_log("  canvas id %d layers %s parent_visible %s pos %s" % [int(entry["id"]), str(lay), str(cv.visible), str(cv.global_position)])
			for l in cv._layers:
				for rec in l.records:
					_log("    rec pts %s tex %s" % [str(rec["pts"]), str(rec["tex"] != null)])
			var pr = entry["program"]
			_log("  program portal %s flame %s stage %s frame %s tributes %s" % [str(pr.get("portal")), str(pr.get("flame")), str(pr.get("stage")), str(pr.get("frame")), str(pr.get("tributes"))])


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
		"star_press":
			# the guardian star box: Cross until it is closed (a press can be lost, so it is repeated after a short wait)
			if duel.mode == "star":
				if not _busy():
					steps.pop_front()
					steps.push_front(["star_press"])
					steps.push_front(["wait", 20])
					steps.push_front(["key", KEY_E])
				else:
					steps.pop_front()
					steps.push_front(["star_press"])
					step_left = 0
			elif _busy() or star_settle < 30:
				# not busy: the star is armed by the placement's end, a few frames later at most
				star_settle = 0 if _busy() else star_settle + 1
				steps.pop_front()
				steps.push_front(["star_press"])
				step_left = 0
			else:
				star_settle = 0
				steps.pop_front()
		"if_star_confirm":
			# the guardian star is asked once the placement has shown: wait for the box (or for the field to be idle without one)
			if duel.mode == "star" and not _busy():
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
		"call":
			steps.pop_front()
			if op[1] == "setup_battle":
				_setup_battle()
			elif op[1] == "battle":
				_battle()
		"key":
			# held for three frames, released for three
			_log("KEY %d pf=%d mode=%s star_zone=%d busy=%s held=%s" % [int(op[1]), Engine.get_physics_frames(), duel.mode, duel.star_zone, str(duel.fx.busy()), str(duel.held)])
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


func _zone_of(spec: Array) -> Dictionary:
	# spec: [card id, "fu" or "fd", "atk" or "def"]
	var z: Dictionary = duel.engine.state.make_zone(int(spec[0]), spec[1] == "fd", spec[2] == "def")
	return z


func _setup_battle() -> void:
	var b: Dictionary = BATTLES[scen]
	var s = duel.engine.state
	for i in range(b["mine"].size()):
		s.sides[0].monsters[i] = _zone_of(b["mine"][i])
	for i in range(b["foe"].size()):
		s.sides[1].monsters[i] = _zone_of(b["foe"][i])
	duel.refresh()
	_log("battle set: mine=%s foe=%s" % [str(b["mine"]), str(b["foe"])])


func _battle() -> void:
	var b: Dictionary = BATTLES[scen]
	capturing = true
	if b.get("foe_attacks", false):
		# the CPU's turn: its monster attacks (the engine's attack, presented as the foe's action is)
		var before: Array = duel._field_cards()
		var events: Array = duel.engine.attack(1, int(b["a"]), int(b["t"]))
		duel.engine.check_winner()
		duel.fx.play(events, before, {"side": 1, "attacker": int(b["a"])})
		_log("foe attack events: %s" % str(events))
	else:
		duel.mode = "field"
		duel.attacker = int(b["a"])
		duel._resolve_attack(int(b["t"]))
	duel.refresh()


func _process(_delta: float) -> bool:
	return false
