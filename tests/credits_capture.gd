extends SceneTree
## Frame capture of the credits roll with the wireframe monsters (the comparison with the reference frames). It starts the roll
## directly (the save and the secret number box are passed), writes a PNG every CAPTURE_EVERY physics frames to the folder given
## after `--out=`, a JSON line per roll frame to `--log=` (the monsters' model ids, look-at centres, colours, the view and the active
## slot: the same fields the reference oracle logs), then DONE. `--models=a,b,...` forces the model ids the loads take, in order.
## It needs a window, so run it minimized and silent:
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --position -32000,-32000 --resolution 640x480 --minimized --audio-driver Dummy --path <project> --script res://tests/credits_capture.gd -- --out=C:\path\to\folder --log=C:\path\to\log.jsonl

const CreditsScene := preload("res://scripts/menu/credits.gd")
const CAPTURE_EVERY := 60
const LAST_FRAME := 1500

var out_dir := ""
var log_path := ""
var forced: Array = []
var camera_from := ""
var projection := 300.0
var centre := Vector2(160, 120)
var node: Control = null
var frame := 0
var log_file: FileAccess = null


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.substr(6)
		elif arg.begins_with("--log="):
			log_path = arg.substr(6)
		elif arg.begins_with("--proj="):
			projection = float(arg.substr(7))
		elif arg.begins_with("--centre="):
			var parts := arg.substr(9).split(",")
			centre = Vector2(float(parts[0]), float(parts[1]))
		elif arg.begins_with("--camera="):
			camera_from = arg.substr(9)
		elif arg.begins_with("--models="):
			for part in arg.substr(9).split(","):
				if part.strip_edges() != "":
					forced.append(int(part))
	if out_dir == "":
		out_dir = OS.get_user_data_dir() + "/credits_captures"
	DirAccess.make_dir_recursive_absolute(out_dir)
	if log_path != "":
		log_file = FileAccess.open(log_path, FileAccess.WRITE)
	root.size = Vector2i(640, 480)
	DisplayServer.window_set_size(Vector2i(640, 480))
	node = CreditsScene.new()
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(node)


func _physics_process(_delta: float) -> bool:
	frame += 1
	if frame == 2:
		node.monsters.forced_models = forced.duplicate()
		node.monsters.projection = projection
		node.monsters.centre = centre
		if camera_from != "":
			node.monsters.camera_track = _camera_track(camera_from)
		node.save_done(true)
		node._clear_box()
		node._enter("roll")
	if frame >= 3 and log_file != null:
		_log(frame - 2)
	if frame >= 3 and (frame - 2) % CAPTURE_EVERY == 0:
		var image := root.get_texture().get_image()
		image.save_png(out_dir + "/f%05d.png" % (frame - 2))
	if frame >= LAST_FRAME:
		if log_file != null:
			log_file.close()
		print("DONE")
		quit(0)
	return false


func _log(vb: int) -> void:
	var mon = node.monsters
	var slots := []
	for i in 2:
		var s: Dictionary = mon.slots[i]
		var entry := {"model": s["model"], "loaded": s["loaded"], "dc": Array(s["dc"])}
		if s["loaded"]:
			var centre: Vector3 = mon._slot_centre(i)
			entry["centre"] = [centre.x, centre.y, centre.z]
			entry["e15"] = s["mon"].E15
			entry["e0f"] = s["mon"].E0F
		slots.append(entry)
	var line := {"vb": vb, "active": mon.active, "slots": slots,
		"eye": [mon.eye.x, mon.eye.y, mon.eye.z], "vr": [mon.vr.x, mon.vr.y, mon.vr.z], "yaw": mon.yaw, "mode": mon.mode,
		"target": mon.target_slot, "move": mon.move["active"], "phase": mon.phase}
	log_file.store_line(JSON.stringify(line))


## The camera per frame from a reference log (one JSON line per logged VBlank, even VBlanks only): the odd frames keep the last value.
func _camera_track(path: String) -> Array:
	var by_vb := {}
	var last_vb := 0
	for line in FileAccess.get_file_as_string(path).split("
", false):
		var row = JSON.parse_string(line)
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var view: Dictionary = row["view"]
		var eye := Vector3(view["vpx"], view["vpy"], view["vpz"])
		var target := Vector3(view["vrx"], view["vry"], view["vrz"])
		by_vb[int(row["vb"])] = [eye, target]
		last_vb = maxi(last_vb, int(row["vb"]))
	var track := []
	var current := [Vector3(), Vector3()]
	for vb in last_vb + 1:
		if by_vb.has(vb):
			current = by_vb[vb]
		track.append(current)
	return track
