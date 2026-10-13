extends SceneTree
## Headless smoke test of the campaign story player (scripts/story/story_player.gd) over every scene of the script bank (0 to 198).
## Each scene runs with Shift held (test_skip: waits and the text reveal collapse), and every choice is answered: the first run
## picks option 0, then one run per further option (up to MAX_OPTIONS), and a last run sets every story flag (the branches that test
## a flag then go the other way). A run stops when the script returns; MAX_FRAMES physics frames without that is a hang.
## What is recorded per run and summed per scene (events are counted by StoryPlayer._note while `auditing`):
##   vm:unknown_opcode:XX      a script opcode the player does not handle
##   f8:XX / op:XX             the text's secondary (F8) and primary control bytes met
##   unknown:f8:XX             an F8 sub-opcode the game's table does not have
##   approx:...                a text command the port models approximately (see the names)
##   glyph:space / no_picture  a blank code, and a glyph code with no picture (a code the font's table lacks)
##   picture:missing:XXX, portrait:missing:NN, bust:missing:..., bust:no_file:...   art the port does not have on disc
##   choice:N, choice:start, string:push, dialog:ID   the choices offered, and the text boxes run
## Output: res://build/story_audit.json (tools: docs/story-audit.md is written from it). Run:
##   Redot --headless --path <project> -s res://tests/story_smoke.gd [-- --scene=N]
## Exit code 0 when the harness ran; the list of hangs and errors is in the JSON and printed at the end.

const StoryPlayer := preload("res://scripts/story/story_player.gd")
const GameState := preload("res://scripts/state/game_state.gd")

const SCENE_COUNT := 199
const MAX_FRAMES := 20000        # physics frames before a run counts as a hang
const MAX_OPTIONS := 4           # the options answered per choice, beyond the first
const MAX_CHOICES := 60          # choices in one run before it counts as a loop (the player would be asked again forever)
const OUT_PATH := "res://build/story_audit.json"


func _init() -> void:
	Engine.physics_ticks_per_second = 600
	_main.call_deferred()


func _main() -> void:
	var only := -1
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="):
			only = int(arg.substr(8))
	var started := Time.get_ticks_msec()
	var scenes: Array = []
	var runs := 0
	var dialogs_only := false
	var run_dialogs := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dialogs="):
			var bounds := arg.substr(10).split("-")
			_dialog_from = bounds[0].hex_to_int()
			_dialog_to = bounds[1].hex_to_int()
			dialogs_only = true
			run_dialogs = true
	for scene in range(SCENE_COUNT if not dialogs_only else 0):
		if only >= 0 and scene != only:
			continue
		var entry: Dictionary = await _scene(scene)
		runs += entry["runs"].size()
		scenes.append(entry)
	var dialogs: Dictionary = {"total": 0, "walked": 0, "not_walked": 0, "failures": []}
	if run_dialogs:
		dialogs = await _dialog_pass()
	var report := {"scene_count": SCENE_COUNT, "runs": runs, "seconds": (Time.get_ticks_msec() - started) / 1000.0, "scenes": scenes,
			"dialogs": dialogs}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build"))
	var file := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("story_smoke: cannot write " + OUT_PATH)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	var hangs := []
	for entry in scenes:
		if entry["timeouts"] > 0:
			hangs.append(entry["scene"])
	print("story_smoke: %d scenes, %d runs, %.1f s; hangs: %s; output %s" % [scenes.size(), runs, report["seconds"], str(hangs), ProjectSettings.globalize_path(OUT_PATH)])
	if run_dialogs:
		print("story_smoke dialogs: %d checked (%d walkable, %d not walked), %d failures; %s" % [dialogs["total"], dialogs["walked"], dialogs["not_walked"], dialogs["failures"].size(), str(dialogs["failures"].slice(0, 8))])
	quit(0 if dialogs["failures"].is_empty() else 1)


## Every run of one scene: option 0, the other options of the choices it met, then every flag set.
func _scene(scene: int) -> Dictionary:
	var entry := {"scene": scene, "runs": [], "events": {}, "choices": [], "timeouts": 0, "endings": []}
	var first: Dictionary = await _run(scene, 0, false)
	_add(entry, first)
	var most := 0
	for count in first["choices"]:
		most = maxi(most, int(count))
	for option in range(1, mini(most, MAX_OPTIONS)):
		_add(entry, await _run(scene, option, false))
	_add(entry, await _run(scene, 0, true))
	return entry


func _add(entry: Dictionary, run: Dictionary) -> void:
	entry["runs"].append({"pick": run["pick"], "flags_set": run["flags_set"], "ending": run["ending"], "argument": run["argument"],
			"frames": run["frames"], "timeout": run["timeout"], "choices": run["choices"]})
	for key in run["events"]:
		entry["events"][key] = int(entry["events"].get(key, 0)) + int(run["events"][key])
	for count in run["choices"]:
		if not entry["choices"].has(count):
			entry["choices"].append(count)
	if run["timeout"]:
		entry["timeouts"] += 1
	var ending := "%s %d" % [run["ending"], run["argument"]] if run["ending"] != "" else "none"
	if not entry["endings"].has(ending):
		entry["endings"].append(ending)


## One run of a scene with the given pick for every choice, and the flags either as saved (all clear) or all set.
func _run(scene: int, pick: int, flags_set: bool) -> Dictionary:
	GameState.reset()
	if flags_set:
		GameState.flags.fill(0xFF)
	StoryPlayer.audit = {}
	StoryPlayer.auditing = true
	StoryPlayer.test_skip = true
	StoryPlayer.selected_card = 0
	var offered: Array = []
	var seen := {"done": false, "loop": false, "kind": "", "argument": -1}
	var answered := [0]
	StoryPlayer.test_choice = func(count: int, _before: int) -> int:
		# the answers rotate from the pick, so a question that comes back until another option is taken still ends
		if offered.size() < 60:
			offered.append(count)
		answered[0] += 1
		if answered[0] > MAX_CHOICES:
			seen["loop"] = true
		return (pick + answered[0] - 1) % count
	var player = StoryPlayer.new()
	player.scene_index = scene
	player.finished.connect(func(kind: String, argument: int) -> void:
		seen["kind"] = kind
		seen["argument"] = argument)
	player.run_done.connect(func() -> void:
		seen["done"] = true)
	root.add_child(player)
	var frames := 0
	while not seen["done"] and not seen["loop"] and frames < MAX_FRAMES:
		await physics_frame
		frames += 1
	var ending: String = seen["kind"]
	if seen["loop"]:
		ending = "choice_loop"
	var run := {"pick": pick, "flags_set": flags_set, "ending": ending, "argument": seen["argument"], "frames": frames,
			"timeout": not seen["done"] and not seen["loop"], "choices": offered, "events": StoryPlayer.audit.duplicate()}
	player.queue_free()
	await process_frame
	StoryPlayer.auditing = false
	StoryPlayer.audit = {}
	StoryPlayer.test_choice = Callable()
	StoryPlayer.test_skip = false
	return run



## Dialog regression: every text box of the bank (index 0 to 0xEFF). The box's own bytes are walked here, with the operand sizes of the
## text commands and the box's layout (pen, wrap, page turns) on the box's own rules: a glyph advances the pen, a line past the right edge
## starts a new line, a line that would pass the box's bottom turns the page (a line feed, a page-break command or an overflowing glyph),
## and every printable glyph is counted on its page. The player runs the same box twice, with Shift held and free (the confirm key
## pressed in turns), and the glyphs it places per page must equal the walk's count, with no glyph dropped. A box with a branch the walk
## does not follow (choices, jumps, pushed streams, duels, flag tests, the map) is reported as not walked.
const DIALOG_LAST := 0xEFF
const BOX_WIDTH := 288
const BOX_HEIGHT := 48
const WALK_FIXED := {0x00: 1, 0x03: 5, 0x04: 1, 0x05: 2, 0x06: 2, 0x07: 2, 0x08: 0, 0x09: 0, 0x0A: 1, 0x0B: 1,
		0x0C: 1, 0x0E: 2, 0x11: 1, 0x12: 0, 0x13: 0, 0x15: 1, 0x16: 0, 0x19: 1, 0x1A: 0, 0x21: 2, 0x27: 2, 0x29: 0,
		0x2B: 0, 0x2C: 0, 0x2D: 0, 0x2E: 0}
const GameText := preload("res://scripts/ui/game_text.gd")

var _text_bank := PackedByteArray()
var _text_offsets: Array = []
var _glyphs := GameText.new()
var _dialog_from := 0
var _dialog_to := DIALOG_LAST


func _dialog_pass() -> Dictionary:
	var result := {"total": 0, "walked": 0, "not_walked": 0, "failures": []}
	_text_bank = FileAccess.get_file_as_bytes("res://assets/screens/text_bank.bin")
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://assets/screens/text.json"))
	_text_offsets = data["offsets"]
	_glyphs.load_all()
	for index in range(_dialog_from, mini(_dialog_to, DIALOG_LAST) + 1):
		result["total"] += 1
		var expected = _walk_dialog(index)
		if expected == null:
			result["not_walked"] += 1
			continue
		result["walked"] += 1
		for skip in [true, false]:
			var got: Dictionary = await _run_dialog(index, skip)
			if _trim(got["pages"]) != _trim(expected["pages"]) or got["dropped"] > 0:
				result["failures"].append("%03X %s expected %s got %s dropped %d" % [index, "skip" if skip else "free",
						str(expected["pages"]), str(got["pages"]), got["dropped"]])
	return result


## The page counts without the trailing empty page (the player turns one more page when the box is done).
func _trim(pages: Array) -> Array:
	var out := pages.duplicate()
	while out.size() > 1 and int(out[-1]) == 0:
		out.pop_back()
	return out


## The printable glyphs of one box per page, from its own bytes and the box's layout rules; null when the walk does not follow the box.
var _wpos := 0
var _wx := 0
var _wy := 0
var _wadv := 8
var _wline := 12
var _wpages: Array = [0]


func _wbyte(offset: int) -> int:
	return int(_text_bank[(_wpos + offset) & 0xFFFF])


## One glyph at the pen: a line past the right edge starts a new line, and a line that would pass the box's bottom turns the page
## (the glyph is then dropped by the player, which the check counts).
func _wglyph(drawable: bool) -> void:
	if _wx >= BOX_WIDTH:
		_wx = 0
		_wy += _wline
	if _wy + _wline > BOX_HEIGHT:
		_wpages.append(0)
		_wx = 0
		_wy = 0
		return
	if drawable:
		_wpages[-1] += 1
	_wx += _wadv


func _wnewline() -> void:
	_wx = 0
	_wy += _wline
	if _wy + _wline > BOX_HEIGHT:
		_wpages.append(0)
		_wx = 0
		_wy = 0


func _walk_dialog(index: int) -> Variant:
	_wpos = int(_text_offsets[index])
	_wx = 0
	_wy = 0
	_wadv = 8
	_wline = 12
	_wpages = [0]
	for step in 4000:
		var b := _wbyte(0)
		_wpos += 1
		if b == 0xFF:
			return {"pages": _wpages}
		if b < 0xF0:
			_wglyph(b != 0 and _glyphs.sjis_of(b) != 0)
			continue
		if b <= 0xF5:
			var code := ((b - 0xF0) << 8) | _wbyte(0)
			_wpos += 1
			_wglyph(code != 0 and _glyphs.sjis_of(code) != 0)
			continue
		if b == 0xF6:
			_wpos += 2
		elif b == 0xF7:
			var state := _wbyte(0)
			_wpos += 1
			var word := _wbyte(0) | (_wbyte(1) << 8)
			if state == 5:
				_wpos += 2 + (3 if (word & 0x8000) != 0 else 0)
			elif state == 0x0B:
				_wpos += 6
			elif state == 0x0F or state == 0x10:
				_wpos += 2
		elif b == 0xF8:
			var sub := _wbyte(0)
			_wpos += 1
			if sub == 0x25:
				_wpages.append(0)
				_wx = 0
				_wy = 0
			elif sub == 0x29:
				_wnewline()
			elif sub == 0x01:
				_wx = 0
				_wy += _wbyte(0) - 256 if _wbyte(0) >= 128 else _wbyte(0)
				_wpos += 1
			elif sub == 0x02:
				_wx += _wbyte(0)
				_wpos += 1
			elif sub == 0x05:
				_wadv = _wbyte(0)
				_wline = _wbyte(1)
				_wpos += 2
			elif sub == 0x06:
				var pen := _wbyte(0) | (_wbyte(1) << 8)
				_wx = pen - 0x10000 if pen >= 0x8000 else pen
				_wpos += 2
			elif sub == 0x08:
				_wx += 16
			elif sub == 0x0B:
				_wx += 16
				_wpos += 1
			elif sub == 0x0F:
				var control := _wbyte(0)
				_wpos += 1 + (2 if ((control & 0x3F) != 0 or (control & 2) != 0) else 0)
			elif sub == 0x10:
				var effect := _wbyte(0) | (_wbyte(1) << 8)
				_wpos += 2 + (2 if (effect & 0x8000) != 0 else 0)
			elif sub >= 0x1B and sub <= 0x20:
				_wpos += 1
				_wglyph(false)
			elif WALK_FIXED.has(sub):
				_wpos += int(WALK_FIXED[sub])
			else:
				return null
		elif b == 0xF9:
			var flag := _wbyte(0) | (_wbyte(1) << 8)
			if (flag & 0x4000) == 0:
				return null
			_wpos += 2
		elif b == 0xFA:
			_wpages.append(0)
			_wx = 0
			_wy = 0
		elif b == 0xFE:
			_wnewline()
		else:
			return null
	return null


## One box run; returns the glyphs the player placed per page (drawn, not dropped) and the dropped count.
func _run_dialog(index: int, skip: bool) -> Dictionary:
	GameState.reset()
	StoryPlayer.audit = {}
	StoryPlayer.auditing = true
	StoryPlayer.glyph_log = []
	StoryPlayer.test_skip = skip
	StoryPlayer.test_press = false
	StoryPlayer.test_choice = Callable()
	var seen := {"done": false}
	var player = StoryPlayer.new()
	player.test_only_dialog = index if index < 0x500 else index + 0x100
	player.run_done.connect(func() -> void:
		seen["done"] = true)
	root.add_child(player)
	var frames := 0
	while not seen["done"] and frames < 6000:
		if not skip:
			StoryPlayer.test_press = (frames % 12) >= 9
		await physics_frame
		frames += 1
	var log_rows: Array = StoryPlayer.glyph_log.duplicate()
	player.queue_free()
	await process_frame
	StoryPlayer.auditing = false
	StoryPlayer.test_skip = false
	StoryPlayer.test_press = false
	var pages := [0]
	var dropped := 0
	for row in log_rows:
		if row[3]:
			if row[2]:
				dropped += 1   # a printable glyph the page turn dropped: the failure the check is for
			continue
		while pages.size() <= int(row[1]):
			pages.append(0)
		if row[2]:
			pages[int(row[1])] += 1
	return {"pages": pages, "dropped": dropped}
