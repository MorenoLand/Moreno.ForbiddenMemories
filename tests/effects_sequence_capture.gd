extends SceneTree
## Frame series of a duel's presentation: a real duel scene (the board, the cards and the effect layer) plays a battle, then Dark Hole
## (the board destruction, effect 17) and then a trap's spring (effect 8), each through the duel's own event presentation. The window's
## frames are saved to the folder given after `--out=` every CAPTURE_EVERY frames, and the run prints DONE. It needs a window (the
## picture is read from it), so run it minimized and silent:
##   G:\Software\Redot\redot.windows.editor.x86_64.console.exe --minimized --audio-driver Dummy --path G:\Development\Godot\Projects\ForbiddenMemories -s res://tests/effects_sequence_capture.gd -- --out=C:\path\to\folder
## A watchdog ends the run after MAX_FRAMES frames whatever the presentation is doing: the run reports whether each play finished.

const DuelScene := preload("res://scripts/duel/duel_scene.gd")

const CAPTURE_EVERY := 12
const MAX_FRAMES := 2400

var duel
var out_dir := "user://sequence"
var t := 0
var shots := 0
var phase := 0
var phase_started := -1
var finished_plays: Array = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	duel = DuelScene.new()
	duel.opponent_id = 0
	duel.terrain = 0
	duel.engine_seed = 7
	root.add_child(duel)


func _process(_delta: float) -> bool:
	t += 1
	if t > MAX_FRAMES:
		print("SEQUENCE  watchdog: the run ended at frame %d (plays finished: %s)" % [t, str(finished_plays)])
		print("DONE")
		quit(0)
		return true
	if duel == null or not duel.ready_ok:
		return false
	if phase == 0 and t > 60 and not duel.field.intro_running and duel.field.intro_fade < 0:
		_place_cards()
		duel.refresh()
		phase = 1
		phase_started = t
	if phase == 1 and t >= phase_started + 20:
		_play("battle", [{"kind": "battle", "attacker": 0, "target": 0, "result": -300}], {"side": 0, "attacker": 0})
		phase = 2
		phase_started = t
	if phase == 2 and not duel.fx.busy() and t >= phase_started + 30:
		finished_plays.append("battle")
		_play("dark hole", _dark_hole_events(), {"side": 0, "card": 336, "cards": []})
		phase = 3
		phase_started = t
	if phase == 3 and not duel.fx.busy() and t >= phase_started + 30:
		finished_plays.append("dark hole")
		_play("trap", [{"kind": "trap", "side": 1, "zone": 0, "id": 689}], {"side": 1})
		phase = 4
		phase_started = t
	if phase == 4 and not duel.fx.busy() and t >= phase_started + 30:
		finished_plays.append("trap")
		print("SEQUENCE  all plays finished at frame %d: %s" % [t, str(finished_plays)])
		print("DONE")
		quit(0)
		return true
	if t % CAPTURE_EVERY == 0:
		var image := root.get_texture().get_image()
		image.save_png(out_dir.path_join("frame_%04d.png" % t))
		shots += 1
	return false


## Two monsters on each side's front row and a trap on side 1's magic and trap row, so the presentation has cards to show.
func _place_cards() -> void:
	var s = duel.engine.state
	s.sides[0].monsters[0] = s.make_zone(1)
	s.sides[0].monsters[1] = s.make_zone(2)
	s.sides[1].monsters[0] = s.make_zone(2)
	s.sides[1].monsters[1] = s.make_zone(1)
	s.sides[0].traps[0] = s.make_zone(336)
	s.sides[1].traps[0] = s.make_zone(689)


func _dark_hole_events() -> Array:
	var out: Array = []
	for side in 2:
		for zone in 5:
			out.append({"kind": "remove", "side": side, "row": "monsters", "zone": zone})
	return out


func _play(label: String, events: Array, context: Dictionary) -> void:
	print("SEQUENCE  play %s at frame %d (shots so far %d)" % [label, t, shots])
	var before: Array = duel._field_cards()
	duel.fx.play(events, before, context)
