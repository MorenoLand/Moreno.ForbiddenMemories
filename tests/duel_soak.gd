extends SceneTree
## Soak test for the whole duel scene (duel_scene.gd with duel_field_3d.gd, duel_fx.gd, duel_hud.gd, duel_hand.gd, duel_prompt.gd,
## duel_finale.gd and duel_result.gd). Each duel is a real DuelScene in the window, played through its own _physics_process. The
## player side is driven with key events (Input.parse_input_event): random but valid presses for the mode the scene is in (hand
## marks, lifts, placing, flips, attacks, position changes, the activation prompt, star choices, the viewer, cancels, end turn). The
## AI plays the other side. Nothing is sped up: the engine runs its physics at the rate set in SPEED_TPS.
##
## Checked every frame, with the reasons written to the report:
## - a mode that does not change for MODE_STALL frames while no effect is busy (soft-lock), and one effect sequence busy for
##   BUSY_STALL frames (a foe's next action can start in the frame the last sequence ends: the count restarts with each sequence);
## - keys the scene never read (a press and its release in one flush of the main loop: the hold must be long enough);
## - the readouts' life points off the engine's for LP_DESYNC frames together (the readout steps toward the real total);
## - the field's cards against the engine: the set of records, each card's defence turn and face (back or front);
## - the node count of the duel's tree at each turn (growth per turn is a leak);
## - the input: per mode and key, how often a press changed the scene's cursor, mode or stance (the "ignored" table).
## Every ending is checked against the engine: the winner's record (rank result_adjustment), the loser's life points or deck, the
## winner's five Exodia pieces, and the result screen having opened when finished is emitted.
## Forced endings set the engine's state at the player's turn start, then end the turn: Exodia, deck-out for either side. Life point
## endings (win and loss) are natural, with the opponent's or the player's life points lowered, and two-player duels run both sides.
##
## Script errors and warnings are not visible from here: the run's stderr is captured by the caller and counted (see the summary the
## shell prints). The fx watchdog's warnings land there too.
##
## Options (after --):  --seeds=N (default 1)  --first-seed=N (seeds from N to N-1, default 0)  --opponents=A-B or A,B,C (default 1-39)
##                      --no-endings  --no-two-player
##                      --only-endings  --tps=N (physics ticks a second, default 240)  --press=N (ticks a key is held, default 8)
##                      --out=res://path.json
##
## Run (minimized, silent):
##   G:\Software\Redot\redot.windows.editor.x86_64.console.exe --minimized --audio-driver Dummy --path G:\Development\Godot\Projects\ForbiddenMemories -s res://tests/duel_soak.gd -- --seeds=1

const DuelScene := preload("res://scripts/duel/duel_scene.gd")
const DuelData := preload("res://scripts/duel/duel_data.gd")
const DuelResult := preload("res://scripts/duel/duel_result.gd")
const GameState := preload("res://scripts/state/game_state.gd")

const FRAME_BUDGET := 20000        # physics frames a duel may run before it is cut off (the stalemate limit)
const MODE_STALL := 600            # frames a mode may hold with no effect busy
const BUSY_STALL := 600            # frames an effect may stay busy
const OVER_STALL := 1500           # frames the ending may take before its result screen
const RESULT_STALL := 3000         # frames the result screen may wait for its leave key
const LP_DESYNC := 400             # frames the life point readout may differ from the engine
const HUD_SETTLE := 300            # frames after a turn starts before its readouts must agree with the engine
const PRESS_FRAMES_DEFAULT := 8            # a key is held this many physics frames: the scene reads held keys, and input events reach it
								   # only at the main loop's flushes (several physics ticks apart), so a shorter press could be lost
const COOLDOWN := 3                # frames between a release and the next press
const PROBE_FRAMES := 3            # frames after a press before the scene's change is read
const SPEED_TPS := 240

const OUT_PATH := "res://build/duel_soak.json"
const EXODIA := [17, 18, 19, 20, 21]

var data
var rng := RandomNumberGenerator.new()
var plan: Array = []
var plan_index := 0
var duel = null
var cur: Dictionary = {}
var frame := 0
var cooldown := 0
var press_frames := PRESS_FRAMES_DEFAULT
var held_keys: Array = []          # [key, release frame, read] (read: the scene's Input saw the key down)
var probe: Dictionary = {}          # the last press: {mode, key, fingerprint, frame, busy}
var recent_keys: Array = []         # the last eight presses, "mode:key", for the stall notes
var finished_flag := false
var finished_info: Dictionary = {}
var presses: Dictionary = {}        # "mode|key" -> [presses, changes]
var results: Array = []             # one record per duel
var totals := {"duels": 0, "turns": 0, "frames": 0, "endings": {}, "stalls": 0, "desyncs": 0, "errors": 0, "budget": 0,
		"two_player": 0, "forced_ok": 0, "forced_bad": 0, "result_missing": 0, "leaks": 0, "hud_turn_mismatch": 0, "keys_sent": 0, "keys_lost": 0}
var last_mode := ""
var same_mode := 0
var busy_run := 0                  # frames of the current effect sequence (a new one can start in the frame one ends)
var last_finishes := 0
var over_run := 0
var result_run := 0
var last_turn := -1
var turn_pending_check := false
var lp_off := [0, 0]
var field_checked := 0


func _init() -> void:
	var opts := _options()
	Engine.physics_ticks_per_second = int(opts.get("tps", SPEED_TPS))
	Engine.max_fps = 0
	press_frames = int(opts.get("press", PRESS_FRAMES_DEFAULT))
	data = DuelData.new()
	if not data.load_all():
		print("SOAK FATAL  the duel tables could not be loaded")
		quit(2)
		return
	plan = _build_plan(opts)
	print("SOAK  %d duels planned" % plan.size())


func _options() -> Dictionary:
	var out := {"seeds": 1, "first_seed": 0, "opponents": range(1, 40), "endings": true, "two_player": true, "tps": SPEED_TPS, "out": OUT_PATH, "press": PRESS_FRAMES_DEFAULT}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seeds="):
			out["seeds"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--first-seed="):
			out["first_seed"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--opponents="):
			var spec := arg.get_slice("=", 1)
			var list: Array = []
			if spec.contains("-"):
				for i in range(int(spec.get_slice("-", 0)), int(spec.get_slice("-", 1)) + 1):
					list.append(i)
			else:
				for part in spec.split(","):
					list.append(int(part))
			out["opponents"] = list
		elif arg == "--no-endings":
			out["endings"] = false
		elif arg == "--no-two-player":
			out["two_player"] = false
		elif arg == "--only-endings":
			out["opponents"] = []
			out["two_player"] = false
		elif arg.begins_with("--tps="):
			out["tps"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--press="):
			out["press"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--out="):
			out["out"] = arg.get_slice("=", 1)
	return out


func _build_plan(opts: Dictionary) -> Array:
	var out: Array = []
	for s in range(int(opts["first_seed"]), int(opts["seeds"])):
		for opp in opts["opponents"]:
			out.append({"name": "opp%02d/t%d/s%d" % [opp, (opp + s) % 7, s], "opponent": opp, "terrain": (opp + s) % 7,
					"seed": 1000 * (s + 1) + opp, "two_player": false, "setup": "", "expect_kind": "", "expect_winner": -1})
		if bool(opts["two_player"]):
			out.append({"name": "two-player/s%d" % s, "opponent": 0, "terrain": s % 7, "seed": 77000 + s, "two_player": true,
					"setup": "", "expect_kind": "", "expect_winner": -1})
	if bool(opts["endings"]):
		out.append({"name": "ending exodia", "opponent": 5, "terrain": 0, "seed": 9001, "two_player": false, "setup": "exodia",
				"expect_kind": "exodia", "expect_winner": 0})
		out.append({"name": "ending deck-out loss", "opponent": 12, "terrain": 2, "seed": 9002, "two_player": false,
				"setup": "deckout_loss", "expect_kind": "deck_out", "expect_winner": 1})
		out.append({"name": "ending deck-out win", "opponent": 30, "terrain": 4, "seed": 9003, "two_player": false,
				"setup": "deckout_win", "expect_kind": "deck_out", "expect_winner": 0})
		out.append({"name": "ending life points win", "opponent": 20, "terrain": 1, "seed": 9004, "two_player": false,
				"setup": "lp_win", "expect_kind": "lp", "expect_winner": 0})
		out.append({"name": "ending life points loss", "opponent": 7, "terrain": 6, "seed": 9005, "two_player": false,
				"setup": "lp_loss", "expect_kind": "lp", "expect_winner": 1})
		out.append({"name": "ending two-player", "opponent": 0, "terrain": 3, "seed": 9006, "two_player": true,
				"setup": "two_lp", "expect_kind": "lp", "expect_winner": -1})
	return out


# ---- the duel's life cycle ------------------------------------------------------------------------------------------------

func _start(scenario: Dictionary) -> void:
	rng.seed = int(scenario["seed"])
	GameState.deck = data.deal_starter_deck(rng)
	duel = DuelScene.new()
	duel.opponent_id = int(scenario["opponent"])
	duel.terrain = int(scenario["terrain"])
	duel.engine_seed = int(scenario["seed"])
	if bool(scenario["two_player"]):
		duel.two_player = true
		duel.life_points = [1200, 1200]
		duel.second_deck = data.deal_starter_deck(rng)
	duel.finished.connect(_on_finished)
	root.add_child(duel)
	cur = scenario.duplicate()
	cur["start"] = frame
	cur["setup_done"] = false
	cur["turns"] = 0
	cur["max_turn"] = 0
	cur["node_samples"] = []
	cur["stalls"] = []
	cur["desyncs"] = []
	cur["hud_turn_mismatch"] = 0
	cur["hud_notes"] = []
	cur["frames"] = 0
	cur["modes"] = {}
	cur["hud_wait"] = 0
	last_mode = ""
	same_mode = 0
	busy_run = 0
	last_finishes = 0
	over_run = 0
	result_run = 0
	last_turn = -1
	lp_off = [0, 0]
	finished_flag = false
	finished_info = {}
	probe = {}
	held_keys.clear()
	cooldown = 0
	print("SOAK  start %s" % cur["name"])


func _on_finished(winner: int) -> void:
	finished_flag = true
	var has_screen := false
	for child in duel.get_children():
		if child is DuelResult:
			has_screen = true
	finished_info = {"winner": winner, "result_open": has_screen, "outcome_winner": duel.outcome.get("winner", null),
			"frame": frame}


func _end(reason: String) -> void:
	var rec := cur.duplicate()
	var engine = duel.engine
	var sides = engine.state.sides
	rec["reason"] = reason
	rec["frames"] = frame - int(cur["start"])
	rec["turns"] = int(cur["turns"])
	rec["engine_winner"] = engine.winner
	rec["ending"] = ""
	var issues: Array = []
	if reason == "finished":
		var w := int(finished_info["winner"])
		rec["winner"] = w
		rec["ending"] = _classify(engine, w)
		if not bool(finished_info["result_open"]):
			issues.append("finished without a result screen")
			totals["result_missing"] += 1
		if int(finished_info["outcome_winner"]) != w:
			issues.append("outcome winner %s differs from the signal %d" % [str(finished_info["outcome_winner"]), w])
		if engine.winner != w:
			issues.append("finished winner %d but the engine says %d" % [w, engine.winner])
		if rec["ending"] == "lp":
			if sides[w].lp <= 0 or sides[1 - w].lp > 0:
				issues.append("life point ending with lp %d / %d" % [sides[w].lp, sides[1 - w].lp])
		elif rec["ending"] == "exodia":
			var hand: Array = sides[w].hand
			for id in EXODIA:
				if not hand.has(id):
					issues.append("exodia ending without piece %d in the winner's hand" % id)
		elif rec["ending"] == "deck_out":
			if not sides[1 - w].deck.is_empty():
				issues.append("deck-out ending with cards left in the loser's deck")
		else:
			issues.append("unknown ending adjustment %s" % str(sides[w].rank.get("result_adjustment", "?")))
		if not str(cur["expect_kind"]).is_empty() and str(rec["ending"]) != str(cur["expect_kind"]):
			issues.append("expected a %s ending, got %s" % [cur["expect_kind"], rec["ending"]])
		if int(cur["expect_winner"]) >= 0 and w != int(cur["expect_winner"]):
			issues.append("expected winner %d, got %d" % [cur["expect_winner"], w])
		if str(cur["setup"]) != "":
			if issues.is_empty():
				totals["forced_ok"] += 1
			else:
				totals["forced_bad"] += 1
	elif reason == "budget":
		totals["budget"] += 1
		rec["winner"] = -1
		rec["decks"] = [sides[0].deck.size(), sides[1].deck.size()]
		var names: Array = []
		for id in sides[0].hand:
			var c: Dictionary = data.card(int(id))
			names.append("%s (%s, level %s)" % [str(c.get("name", id)), str(c.get("type", "?")), str(c.get("level", "-"))])
		rec["hand"] = names
		var field_names: Array = []
		for cell in sides[0].monsters:
			field_names.append(str(cell["id"]) if cell != null else "-")
		rec["own_field"] = field_names
	for issue in issues:
		print("SOAK  ISSUE %s: %s" % [cur["name"], issue])
	rec["issues"] = issues
	if reason == "finished" and issues.is_empty() and str(cur["setup"]) == "" and str(cur.get("expect_kind", "")) == "":
		pass
	# the leak verdict: the node count of the last third of the turns against the first third
	var samples: Array = rec["node_samples"]
	if samples.size() >= 6:
		var third := samples.size() / 3
		var early := 0
		var late := 0
		for i in third:
			early += int(samples[i]["tree"])
			late += int(samples[samples.size() - 1 - i]["tree"])
		rec["nodes_early"] = early / third
		rec["nodes_late"] = late / third
		if late / third > early / third + 60:
			rec["leak_suspect"] = true
			totals["leaks"] += 1
	rec["node_count"] = samples.size()
	results.append(rec)
	totals["duels"] += 1
	totals["turns"] += int(rec["turns"])
	totals["frames"] += int(rec["frames"])
	if bool(rec["two_player"]):
		totals["two_player"] += 1
	if reason == "finished":
		totals["endings"][rec["ending"]] = int(totals["endings"].get(rec["ending"], 0)) + 1
	totals["stalls"] += cur["stalls"].size()
	totals["desyncs"] += cur["desyncs"].size()
	totals["hud_turn_mismatch"] += int(cur["hud_turn_mismatch"])
	print("SOAK  end %s: %s, winner %s, %s, turns %d, frames %d, issues %d, stalls %d, desyncs %d" % [cur["name"], reason,
			str(rec.get("winner", "-")), rec["ending"], rec["turns"], rec["frames"], issues.size(), cur["stalls"].size(),
			cur["desyncs"].size()])
	for stall in cur["stalls"]:
		print("SOAK  STALL %s: %s" % [cur["name"], stall])
	for desync in cur["desyncs"]:
		print("SOAK  DESYNC %s: %s" % [cur["name"], desync])
	if is_instance_valid(duel):
		duel.queue_free()
	duel = null
	cur = {}


func _classify(engine, w: int) -> String:
	var adj := int(engine.state.sides[w].rank.get("result_adjustment", 0))
	if adj == 40:
		return "exodia"
	if adj == -40:
		return "deck_out"
	if adj == 2:
		return "lp"
	return "unknown"


# ---- the frame loop -------------------------------------------------------------------------------------------------------

func _physics_process(_delta: float) -> bool:
	frame += 1
	if duel == null:
		if plan_index >= plan.size():
			_finish_run()
			return true
		_start(plan[plan_index])
		plan_index += 1
		return false
	_release_due()
	if not duel.ready_ok:
		if frame - int(cur["start"]) > 5:
			print("SOAK  ISSUE %s: the duel scene did not become ready" % cur["name"])
			totals["errors"] += 1
			_end("not_ready")
		return false
	cur["frames"] = frame - int(cur["start"])
	_observe()
	if finished_flag:
		# the scene emits finished when the result screen has been left; the rest of the duel is the same frame
		_end("finished")
		return false
	if _setup_step():
		return false
	_hold_life()
	if int(cur["frames"]) > FRAME_BUDGET:
		_end("budget")
		return false
	if duel.mode == "result":
		result_run += 1
	else:
		result_run = 0
	if result_run > RESULT_STALL:
		_stall("result screen waits %d frames" % result_run)
		_end("result_stuck")
		return false
	_drive()
	return false


func _finish_run() -> void:
	var press_rows := {}
	for key in presses.keys():
		press_rows[key] = {"presses": presses[key][0], "changes": presses[key][1]}
	var out := {"totals": totals, "presses": press_rows, "duels": results}
	var dir := ProjectSettings.globalize_path("res://build")
	DirAccess.make_dir_recursive_absolute(dir)
	var path: String = str(_options()["out"])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(out, "  "))
		file.close()
	var mean_turns := float(totals["turns"]) / maxf(float(totals["duels"]), 1.0)
	var mean_frames := float(totals["frames"]) / maxf(float(totals["duels"]), 1.0)
	print("SOAK  SUMMARY duels %d, turns %d (mean %.1f a duel), frames %d (mean %d), endings %s" % [totals["duels"], totals["turns"],
			mean_turns, totals["frames"], int(mean_frames), str(totals["endings"])])
	print("SOAK  SUMMARY stalls %d, desyncs %d, hud at turn start off %d, leak suspects %d, budget cut-offs %d, two-player %d" % [
			totals["stalls"], totals["desyncs"], totals["hud_turn_mismatch"], totals["leaks"], totals["budget"], totals["two_player"]])
	print("SOAK  SUMMARY keys sent %d, never read by the scene %d" % [totals["keys_sent"], totals["keys_lost"]])
	print("SOAK  SUMMARY forced endings ok %d bad %d, finished without result screen %d" % [totals["forced_ok"], totals["forced_bad"],
			totals["result_missing"]])
	quit(0)


# ---- the invariants -------------------------------------------------------------------------------------------------------

func _observe() -> void:
	var busy: bool = duel.fx.busy()
	var mode: String = duel.mode
	var engine = duel.engine
	var turn_sum := 0
	for side in engine.state.sides:
		turn_sum += int(side.rank.get("turns_taken", 0))
	cur["turns"] = turn_sum
	# the probe of the last press: the scene's cursor, mode or stance changes within PROBE_FRAMES frames
	if not probe.is_empty() and frame - int(probe["frame"]) >= PROBE_FRAMES:
		var key := "%s|%s" % [probe["mode"], probe["key"]]
		var entry: Array = presses.get(key, [0, 0])
		entry[0] = int(entry[0]) + 1
		if _fingerprint() != probe["fingerprint"]:
			entry[1] = int(entry[1]) + 1
		presses[key] = entry
		probe = {}
	# the soft-lock: a mode held with nothing busy
	if mode != last_mode:
		last_mode = mode
		same_mode = 0
	elif not busy:
		same_mode += 1
		if same_mode == MODE_STALL and mode != "over" and mode != "result":
			_stall("mode %s held %d frames with nothing busy (turn side %d, hand %d, zone %d row %d, set down %s, marks %d, last keys %s)" % [
					mode, MODE_STALL, engine.state.turn_side, engine.state.sides[0].hand.size(), duel.zone_index, duel.zone_row,
					str(duel.set_down), duel.marks.size(), str(recent_keys)]
					+ " [Q down %s, cancel edge held %s, help open %s, keys lost %d, hand index %d]" % [
						str(Input.is_key_pressed(KEY_Q)), str(duel.held.get("cancel", false)), str(duel.help.overlay != null), int(cur.get("keys_lost", 0)), duel.hand_index])
	# an effect that stays busy too long: the count is of one sequence (a foe's next action starts in the frame the last one ends, so
	# busy never reads false between them)
	var finishes: int = duel.fx.finishes_total
	if finishes != last_finishes:
		last_finishes = finishes
		busy_run = 0
	if busy:
		busy_run += 1
		cur["max_busy"] = maxi(int(cur.get("max_busy", 0)), busy_run)
		if busy_run == BUSY_STALL:
			_stall("effect busy for %d frames (mode %s, turn side %d, scene timer %d, foe actions %d, keys lost %d) [%s]" % [BUSY_STALL, mode,
						engine.state.turn_side, duel.timer, duel.foe_actions, int(cur.get("keys_lost", 0)), duel.fx.debug_state()])
	else:
		busy_run = 0
	# the ending's own length
	if mode == "over":
		over_run += 1
		if over_run == OVER_STALL:
			_stall("ending takes more than %d frames" % OVER_STALL)
	else:
		over_run = 0
	cur["modes"][mode] = int(cur["modes"].get(mode, 0)) + 1
	# each new turn: the node count of the tree (the leak check) and the readouts against the engine
	if turn_sum != last_turn:
		last_turn = turn_sum
		cur["max_turn"] = turn_sum
		if turn_sum > 0:
			var sample := {"turn": turn_sum, "lp": [engine.state.sides[0].lp, engine.state.sides[1].lp], "mode": mode,
					"nodes": _count(duel), "tree": _count(duel) - _count(duel.board), "world": duel.world.get_child_count(),
					"board": duel.board.get_child_count(), "fx": duel.fx.get_child_count(), "hud": duel.hud.get_child_count(),
						"own_attackers": _attackers(engine, 0), "foe_monsters": _monster_count(engine, 1), "own_monsters": _monster_count(engine, 0)}
			if duel.field != null:
				sample["cards"] = duel.field.cards.get_child_count()
				sample["field_nodes"] = duel.field.nodes.size()
				sample["animations"] = duel.field.animations.size()
			cur["node_samples"].append(sample)
		cur["hud_wait"] = HUD_SETTLE
	# the readouts count toward the engine's life points: after HUD_SETTLE frames without an effect they must agree
	if int(cur["hud_wait"]) > 0 and not busy:
		cur["hud_wait"] = int(cur["hud_wait"]) - 1
		if int(cur["hud_wait"]) == 0:
			for s in 2:
				if duel.shown_life[s] != engine.state.sides[s].lp:
					cur["hud_turn_mismatch"] = int(cur["hud_turn_mismatch"]) + 1
					if cur["hud_notes"].size() < 5:
						cur["hud_notes"].append("turn %d side %d: readout %d, engine %d, mode %s, flipped %s, busy %s, wait %d" % [turn_sum, s,
									duel.shown_life[s], engine.state.sides[s].lp, mode, str(duel.flipped), str(busy), int(cur["hud_wait"])])
					break
	if not busy and mode != "deal":
		for s in 2:
			if duel.shown_life[s] != engine.state.sides[s].lp:
				lp_off[s] += 1
				if lp_off[s] == 60 and cur["hud_notes"].size() < 5:
					cur["hud_notes"].append("frame %d: side %d readout %d, engine %d, mode %s, flipped %s, busy %s, holds %s, active %s" % [
							frame - int(cur["start"]), s, duel.shown_life[s], engine.state.sides[s].lp, mode, str(duel.flipped), str(busy),
							str(duel.fx.holds_life(s)), str(duel.fx.active)])
				if lp_off[s] == LP_DESYNC:
					_desync("life point readout %d is %d, the engine has %d for %d frames" % [s, duel.shown_life[s],
							engine.state.sides[s].lp, LP_DESYNC])
			else:
				lp_off[s] = 0
		_check_field(engine)


## The field's cards against the engine: the same records, each card's defence turn and its face.
func _check_field(engine) -> void:
	var field = duel.field
	if field == null:
		return
	field_checked += 1
	var want := {}
	for entry in duel._field_cards():
		want[int(entry["record"])] = entry
	for record in want.keys():
		if not field.nodes.has(record):
			var e: Dictionary = want[record]
			var offset: int = record - (5 if record < 20 else 20)
			var cell = engine.state.sides[0 if record < 20 else 1].traps[offset - 5] if offset >= 5 else 					engine.state.sides[0 if record < 20 else 1].monsters[offset]
			_desync("field has no card for record %d (card %s, face down %s, front texture null %s, back null %s, mode %s, busy %s)" % [
					record, str(cell["id"]) if cell != null else "none", str(e["face_down"]), str(e["texture"] == null),
					str(e["back"] == null), duel.mode, str(duel.fx.busy())])
			return
	for record in field.nodes.keys():
		if not want.has(record):
			_desync("field shows record %d the engine does not have" % record)
			return
	for record in want.keys():
		var entry: Dictionary = want[record]
		var node: Dictionary = field.nodes[record]
		if bool(node["defense"]) != bool(entry["defense"]):
			_desync("record %d defence is %s, the engine says %s" % [record, str(node["defense"]), str(entry["defense"])])
			return
		var face: Texture2D = entry["back"] if bool(entry["face_down"]) else entry["texture"]
		if node["texture"] != face:
			_desync("record %d face (%s) is not the engine's (%s)" % [record, "back" if bool(entry["face_down"]) else "front",
					"back" if bool(entry["face_down"]) else "front"])
			return


func _attackers(engine, side: int) -> int:
	var n := 0
	for z in 5:
		if engine.state.sides[side].monsters[z] != null and engine.can_attack(side, z):
			n += 1
	return n


func _monster_count(engine, side: int) -> int:
	var n := 0
	for cell in engine.state.sides[side].monsters:
		if cell != null:
			n += 1
	return n


func _count(n: Node) -> int:
	var c := 1
	for child in n.get_children():
		c += _count(child)
	return c


func _fingerprint() -> String:
	var engine = duel.engine
	return "%s|%d|%d|%d|%d|%d|%d|%s|%s|%d|%d|%d|%s" % [duel.mode, duel.hand_index, duel.zone_index, duel.zone_row,
			duel.prompt_choice, duel.star_choice, duel.marks.size(), str(duel.set_down), str(duel.viewer), duel.attacker,
			engine.state.sides[0].hand.size(), engine.state.turn_side, str(duel.wheel_steps)]


func _stall(text: String) -> void:
	cur["stalls"].append("frame %d: %s" % [frame - int(cur["start"]), text])
	print("SOAK  STALL %s: %s" % [cur["name"], text])


func _desync(text: String) -> void:
	if cur["desyncs"].size() < 20:
		cur["desyncs"].append("frame %d: %s" % [frame - int(cur["start"]), text])
	if cur["desyncs"].size() == 1:
		print("SOAK  DESYNC %s: %s" % [cur["name"], text])


# ---- forced endings ---------------------------------------------------------------------------------------------------------

## The ending set-ups run once the player's first turn is up (the opening deal is done and the scene waits for input).
func _setup_step() -> bool:
	if cur["setup"] == "" or cur["setup_done"]:
		return false
	if duel.mode != "hand" or duel.fx.busy() or duel.deal_active or int(cur["frames"]) < 10:
		return false
	var engine = duel.engine
	var sides = engine.state.sides
	match str(cur["setup"]):
		"exodia":
			sides[0].hand = EXODIA.duplicate()
		"deckout_loss":
			sides[0].deck.clear()
			sides[0].hand.clear()
		"deckout_win":
			sides[1].deck.clear()
			sides[1].hand.clear()
		"lp_win":
			# the player's life points are held at 9999 (_hold_life), the foe starts at 100: the player must win on life points
			sides[0].lp = 9999
			sides[0].max_lp = 9999
			sides[1].lp = 100
			# the foe's board is cleared too: with five monsters on its side and the player's life points held, a random player never
			# gets a monster to attack with, and the duel runs to the budget (an artefact of the forced set-up, not of the duel)
			for z in 5:
				sides[1].monsters[z] = null
			# and the player has three of the table's strongest monsters, so its attacks land from the second turn on
			var strongest := 0
			var strongest_atk := -1
			for card in data.cards:
				var id := int(card["id"])
				if engine.state.is_monster(id) and int(card.get("attack", 0)) > strongest_atk:
					strongest = id
					strongest_atk = int(card.get("attack", 0))
			for z in 3:
				sides[0].monsters[z] = engine.state.make_zone(strongest)
			duel.refresh()
		"lp_loss":
			# the foe's life points are held at 9999 (_hold_life), the player starts at 100: the foe must win on life points
			sides[1].lp = 9999
			sides[1].max_lp = 9999
			sides[0].lp = 100
		"two_lp":
			pass
	cur["setup_done"] = true
	if str(cur["setup"]) in ["exodia", "deckout_loss", "deckout_win"]:
		duel._end_turn()          # the foe's turn, then the draw that decides the duel
	return false


## The life point endings: the winner's life points stay at 9999 from the set-up on, so the loser's own attacks decide the duel and
## the other side cannot win on life points first (the scenario's winner is then fixed).
func _hold_life() -> void:
	if not bool(cur.get("setup_done", false)):
		return
	var side := -1
	if str(cur["setup"]) == "lp_win":
		side = 0
	elif str(cur["setup"]) == "lp_loss":
		side = 1
	if side < 0:
		return
	var sides = duel.engine.state.sides
	sides[side].lp = maxi(int(sides[side].lp), 9999)


# ---- the player's keys ------------------------------------------------------------------------------------------------------

func _release_due() -> void:
	var keep: Array = []
	for item in held_keys:
		if not bool(item[2]) and Input.is_key_pressed(int(item[0])):
			item[2] = true
		if frame >= int(item[1]):
			_send(int(item[0]), false)
			if not bool(item[2]):
				# the key went down and up with no read in between: the scene never saw this press
				totals["keys_lost"] += 1
				cur["keys_lost"] = int(cur.get("keys_lost", 0)) + 1
		else:
			keep.append(item)
	held_keys = keep


func _send(key: int, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = key
	ev.physical_keycode = key
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _press(key: int) -> void:
	var mode := "busy" if duel.fx.busy() else str(duel.mode)
	if mode == "hand" and duel.engine.state.sides[0].hand.size() == 0:
		mode = "hand0"
	probe = {"mode": mode, "key": key, "fingerprint": _fingerprint(), "frame": frame}
	recent_keys.append("%s:%d" % [mode, key])
	if recent_keys.size() > 8:
		recent_keys.pop_front()
	_send(key, true)
	held_keys.append([key, frame + press_frames, false])
	totals["keys_sent"] += 1
	cooldown = COOLDOWN


func _drive() -> void:
	if not held_keys.is_empty():
		return                      # one key at a time: the next press starts once the last one is up
	if _scripted_attack():
		return
	if cooldown > 0:
		cooldown -= 1
		return
	var key := _choose()
	if key >= 0:
		_press(key)


## The forced life point win: the player's attacks are made directly (the attacker that can attack, on the first foe monster, or the foe's
## life points when its row is empty). A random player does not clear a five-monster board in a duel's budget; the ending is what the
## check is for, and the other keys are still random. False when there is nothing to attack with.
func _scripted_attack() -> bool:
	if str(cur.get("setup", "")) != "lp_win" or not bool(cur.get("setup_done", false)):
		return false
	if duel.mode != "field" or duel.fx.busy():
		return false
	var engine = duel.engine
	for z in 5:
		if engine.can_attack(0, z):
			var target := -1
			for t in 5:
				if engine.state.sides[1].monsters[t] != null:
					target = t
					break
			duel.attacker = z
			duel._resolve_attack(target)
			return true
	return false


func _choose() -> int:
	if duel.fx.busy():
		# a key during an effect is ignored by the scene: some presses are sent anyway to check that
		if rng.randf() < 0.08:
			return _weighted([[KEY_E, 1.0], [KEY_Q, 1.0], [KEY_F, 1.0], [KEY_A, 1.0], [KEY_D, 1.0], [KEY_ENTER, 1.0]])
		return -1
	if _result_open():
		return _weighted([[KEY_E, 0.12], [KEY_D, 0.08], [KEY_A, 0.05], [KEY_RIGHT, 0.05], [-1, 0.7]])
	var n: int = duel.engine.state.sides[0].hand.size()
	match duel.mode:
		"hand":
			return _weighted([[KEY_D, 0.16 if n > 0 else 0.0], [KEY_A, 0.12 if n > 0 else 0.0], [KEY_F, 0.1 if n > 0 else 0.0],
					[KEY_E, 0.14 if n > 0 else 0.0], [KEY_R, 0.07 if n > 0 else 0.0], [KEY_ENTER, 0.09], [KEY_Q, 0.04], [KEY_T, 0.02], [-1, 0.2]])
		"dest":
			# the destination takes both own rows: Up and Down move between the monster row and the magic and trap row
			return _weighted([[KEY_D, 0.22], [KEY_A, 0.14], [KEY_UP, 0.12], [KEY_DOWN, 0.12], [KEY_R, 0.1], [KEY_E, 0.22], [KEY_Q, 0.06], [-1, 0.02]])
		"star":
			return _weighted([[KEY_D, 0.3], [KEY_E, 0.4], [KEY_Q, 0.1], [-1, 0.2]])
		"centre":
			# the single card's face choice: left sets it, right turns it up, Confirm places it, Q takes it back to the hand
			return _weighted([[KEY_D, 0.25], [KEY_A, 0.25], [KEY_E, 0.3], [KEY_Q, 0.08], [-1, 0.12]])
		"centre_back":
			return -1                   # the card is going back to its slot: no input is taken
		"field":
			if duel.zone_row == 1:
				# on the magic and trap row the monsters are one Down away: the player's attacks need that move
				return _weighted([[KEY_DOWN, 0.3], [KEY_D, 0.12], [KEY_A, 0.1], [KEY_UP, 0.04], [KEY_E, 0.14], [KEY_ENTER, 0.06],
						[KEY_Q, 0.02], [-1, 0.22]])
			return _weighted([[KEY_D, 0.18], [KEY_A, 0.16], [KEY_UP, 0.07], [KEY_DOWN, 0.07], [KEY_R, 0.08], [KEY_E, 0.2],
					[KEY_ENTER, 0.07], [KEY_Q, 0.03], [-1, 0.14]])
		"prompt":
			return _weighted([[KEY_D, 0.25], [KEY_E, 0.42], [KEY_Q, 0.1], [-1, 0.23]])
		"equip_pick":
			return _weighted([[KEY_D, 0.3], [KEY_A, 0.25], [KEY_E, 0.3], [KEY_Q, 0.1], [-1, 0.05]])
		"target":
			return _weighted([[KEY_D, 0.3], [KEY_A, 0.25], [KEY_E, 0.3], [KEY_Q, 0.1], [-1, 0.05]])
		"deal", "foe", "over":
			# no input is taken here: a few presses are sent to check that the scene ignores them
			if rng.randf() < 0.05:
				return _weighted([[KEY_E, 1.0], [KEY_D, 1.0], [KEY_ENTER, 1.0], [KEY_Q, 1.0]])
			return -1
	return -1


func _result_open() -> bool:
	for child in duel.get_children():
		if child is DuelResult:
			return true
	return false


func _weighted(options: Array) -> int:
	var total := 0.0
	for option in options:
		total += float(option[1])
	if total <= 0.0:
		return -1
	var r := rng.randf() * total
	for option in options:
		r -= float(option[1])
		if r < 0.0:
			return int(option[0])
	return -1
