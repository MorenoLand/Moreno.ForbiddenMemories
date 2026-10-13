extends SceneTree
## Spectator soak (F3's AI v AI match, duel_spectator.gd): five random matches run to completion on the real duel scene, each side driven
## by the computer. Every match is checked for:
## - finished: the scene decides a winner (0 or 1) that the engine agrees with, and the match over waits for its confirm, which leaves it
##   (the scene emits finished once, with the winner; no DuelResult screen opens: a spectator match has no rewards);
## - no soft lock: the match's progress fingerprint (turns, life points, deck and hand sizes, the cards on the board, the computer's
##   actions) changes at least every STALL_FRAMES frames while no effect is busy;
## - the frame budget (BUDGET_FRAMES) is not spent.
## Match 1 also checks the quit box: Esc opens it, Esc again (NO) resumes the match. A sixth match checks YES: the quit box leaves the
## match with no winner (finished with -1). The Shift fast-forward is restored to 1.0 when a match is left.
##
## Script errors are not visible from here: the run's stderr is captured by the caller and counted.
##
## Run (minimized, silent; the 3D board needs a window):
##   G:\Software\Redot\redot.windows.editor.x86_64.console.exe --minimized --audio-driver Dummy --path G:\Development\Godot\Projects\ForbiddenMemories -s res://tests/spectator_test.gd

const DuelScene := preload("res://scripts/duel/duel_scene.gd")
const DuelData := preload("res://scripts/duel/duel_data.gd")
const DuelSpectator := preload("res://scripts/duel/duel_spectator.gd")
const DuelResult := preload("res://scripts/duel/duel_result.gd")

const SPEED_TPS := 240          # physics ticks a second (the duel soak's rate)
const MATCHES := 5              # the matches that must run to completion
const BUDGET_FRAMES := 60000    # physics frames a match may run before it is cut off
const STALL_FRAMES := 1200      # frames the progress fingerprint may stay the same (no effect busy) before it is a soft lock
const OVER_CONFIRM_FRAMES := 60 # frames the match over line stays before the test confirms it (Enter)
const QUIT_AT := 300            # the frame of a match at which the quit box is opened (the opening sweep is over by then)
const KEY_HOLD := 3             # frames a scripted key is held
const SEEDS := [101, 202, 303, 404, 505, 606]

var data
var plan: Array = []
var index := 0
var duel = null
var cur: Dictionary = {}
var frame := 0
var finished_flag := false
var finished_winner := -2
var pending_keys: Array = []        # [key, release frame]
var stage := 0                      # the quit script of the match: see _quit_step
var stage_frame := 0
var over_sent := false
var last_print := ""
var fingerprint := ""
var fingerprint_frame := 0
var fingerprint_checked := 0
var stall_frames := 0
var issues: Array = []
var records: Array = []
var completed := 0
var quits := 0


func _init() -> void:
	Engine.physics_ticks_per_second = SPEED_TPS
	Engine.max_fps = 0
	data = DuelData.new()
	if not data.load_all():
		print("SPECTATOR FATAL  the duel tables could not be loaded")
		quit(2)
		return
	for i in MATCHES:
		plan.append({"name": "match %d" % (i + 1), "seed": SEEDS[i], "quit": "no" if i == 0 else ""})
	plan.append({"name": "quit yes", "seed": SEEDS[MATCHES], "quit": "yes"})
	print("SPECTATOR  %d matches planned" % plan.size())


func _physics_process(_delta: float) -> bool:
	frame += 1
	_release_due()
	if duel == null:
		if index >= plan.size():
			_finish_run()
			return true
		_start(plan[index])
		index += 1
		return false
	if not duel.ready_ok:
		if frame - int(cur["start"]) > 5:
			_issue("the duel scene did not become ready")
			_end("not_ready")
		return false
	cur["frames"] = frame - int(cur["start"])
	if finished_flag:
		_end("finished")
		return false
	if int(cur["frames"]) > BUDGET_FRAMES:
		_issue("the match ran past %d frames" % BUDGET_FRAMES)
		_end("budget")
		return false
	_check_progress()
	if duel == null:
		return false
	_quit_step()
	if duel != null and duel.spectator_over and not over_sent:
		# the decided match waits for its confirm (Enter): it leaves the match and the scene emits finished
		if int(cur["over_frame"]) < 0:
			cur["over_frame"] = frame
		elif frame - int(cur["over_frame"]) > OVER_CONFIRM_FRAMES:
			_press(KEY_ENTER)
			over_sent = true
	return false


func _start(scenario: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(scenario["seed"])
	var pick: Dictionary = DuelSpectator.pick(rng)
	duel = DuelScene.new()
	duel.spectator = true
	duel.spectator_ids = pick["ids"]
	duel.spectator_decks = pick["decks"]
	duel.terrain = int(pick["terrain"])
	duel.opponent_id = int(pick["ids"][1])
	duel.engine_seed = int(scenario["seed"])
	duel.finished.connect(_on_finished)
	root.add_child(duel)
	cur = scenario.duplicate()
	cur["start"] = frame
	cur["turns"] = 0
	cur["ids"] = pick["ids"]
	cur["decks"] = pick["decks"]
	cur["terrain"] = int(pick["terrain"])
	cur["over_frame"] = -1
	cur["quit_opened"] = false
	cur["quit_closed"] = false
	cur["frames"] = 0
	finished_flag = false
	finished_winner = -2
	stage = 0
	stage_frame = 0
	over_sent = false
	stall_frames = 0
	fingerprint = ""
	fingerprint_frame = frame
	pending_keys.clear()
	print("SPECTATOR  start %s: %s, terrain %d" % [cur["name"], DuelSpectator.title(data, cur["ids"]), cur["terrain"]])


func _on_finished(winner: int) -> void:
	finished_flag = true
	finished_winner = winner


func _end(reason: String) -> void:
	var rec := cur.duplicate()
	rec["reason"] = reason
	rec["frames"] = int(cur.get("frames", 0))
	var engine = null
	if duel != null:
		engine = duel.engine
		var taken := 0
		for side in engine.state.sides:
			taken += int(side.rank.get("turns_taken", 0))
		rec["turns"] = taken
		rec["engine_winner"] = engine.winner
		rec["spectator_over"] = duel.spectator_over
		rec["result_screens"] = 0
		for child in duel.get_children():
			if child is DuelResult:
				rec["result_screens"] += 1
	rec["winner"] = finished_winner
	if reason == "finished":
		if str(cur["quit"]) == "yes":
			if finished_winner != -1:
				_issue("quit yes: finished with winner %d, expected -1" % finished_winner)
			else:
				quits += 1
		else:
			if finished_winner < 0 or finished_winner > 1:
				_issue("finished without a winner (%d)" % finished_winner)
			elif engine.winner != finished_winner:
				_issue("finished winner %d but the engine says %d" % [finished_winner, engine.winner])
			if not bool(rec.get("spectator_over", false)):
				_issue("finished without the match over line")
			if int(rec.get("result_screens", 0)) != 0:
				_issue("a result screen opened in a spectator match")
			completed += 1
		if str(cur["quit"]) == "no" and not bool(cur["quit_closed"]):
			_issue("the quit box did not resume the match")
	else:
		_issue("%s: %s" % [cur["name"], reason])
	rec["issues"] = issues.duplicate()
	records.append(rec)
	var text := "SPECTATOR  %s: %s, %s, %d turns, %d frames" % [cur["name"], reason,
			("winner %d" % finished_winner) if finished_winner >= 0 else "no winner", int(rec.get("turns", 0)), int(rec["frames"])]
	print(text)
	issues.clear()
	if duel != null:
		root.remove_child(duel)
		duel.queue_free()
		duel = null
	Engine.time_scale = 1.0


## Stops the match's progress fingerprint from staying the same while no effect is busy (a soft lock).
func _check_progress() -> void:
	if duel.fx.busy() or duel.quit_box != null or duel.spectator_over:
		stall_frames = 0
		fingerprint_frame = frame
		return
	if frame - fingerprint_checked >= 10:
		fingerprint_checked = frame
		var now := _fingerprint()
		if now != fingerprint:
			fingerprint = now
			stall_frames = 0
		else:
			stall_frames += 10
	if stall_frames > STALL_FRAMES:
		_issue("soft lock: the match did not progress for %d frames (mode %s)" % [stall_frames, duel.mode])
		_end("stall")


func _fingerprint() -> String:
	var engine = duel.engine
	var parts: Array = [duel.foe_actions, engine.winner, duel.mode]
	for side in engine.state.sides:
		parts.append(side.lp)
		parts.append(side.deck.size())
		parts.append(side.hand.size())
		parts.append(int(side.rank.get("turns_taken", 0)))
		for z in side.monsters:
			parts.append(0 if z == null else int(z["id"]))
		for z in side.traps:
			parts.append(0 if z == null else int(z["id"]))
	return str(parts)


## The quit script: match 1 opens the quit box, checks that NO resumes the match; the sixth match opens it and chooses YES.
func _quit_step() -> void:
	var mode: String = str(cur["quit"])
	if mode == "" or finished_flag:
		return
	match stage:
		0:
			if int(cur["frames"]) >= QUIT_AT:
				_press(KEY_ESCAPE)
				stage = 1
				stage_frame = frame
		1:
			if frame - stage_frame < 8:
				return
			if duel.quit_box == null:
				_issue("Esc did not open the quit box")
				_end("quit")
				return
			cur["quit_opened"] = true
			if mode == "no":
				_press(KEY_ESCAPE)
				stage = 2
			else:
				_press(KEY_RIGHT)
				stage = 2
			stage_frame = frame
		2:
			if frame - stage_frame < 8:
				return
			if mode == "no":
				if duel.quit_box != null:
					_issue("NO did not close the quit box")
					_end("quit")
					return
				cur["quit_closed"] = true
				stage = 9
			else:
				if duel.quit_box == null or duel.quit_box.choice != 1:
					_issue("the quit box did not move to YES")
					_end("quit")
					return
				_press(KEY_ENTER)
				stage = 3
				stage_frame = frame
		3:
			if frame - stage_frame < 8:
				return
			if not finished_flag:
				_issue("YES in the quit box did not leave the match")
				_end("quit")
			return


func _press(key: int) -> void:
	_send(key, true)
	pending_keys.append([key, frame + KEY_HOLD])


func _release_due() -> void:
	var still: Array = []
	for entry in pending_keys:
		if frame >= int(entry[1]):
			_send(int(entry[0]), false)
		else:
			still.append(entry)
	pending_keys = still


func _send(key: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)


func _issue(text: String) -> void:
	issues.append(text)
	print("SPECTATOR  ISSUE %s: %s" % [cur.get("name", "?"), text])


func _finish_run() -> void:
	var failed := 0
	var finished := 0
	for rec in records:
		if str(rec["reason"]) == "finished" and str(rec["quit"]) != "yes":
			finished += 1
		if not (rec["issues"] as Array).is_empty():
			failed += 1
	var turns := 0
	var frames := 0
	for rec in records:
		turns += int(rec.get("turns", 0))
		frames += int(rec.get("frames", 0))
	print("SPECTATOR  summary: %d of %d matches finished with a winner, %d quit (YES), %d records with issues, %d turns, %d frames" % [
			finished, MATCHES, quits, failed, turns, frames])
	var ok := finished == MATCHES and quits == 1 and failed == 0 and Engine.time_scale == 1.0
	print("SPECTATOR  %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
