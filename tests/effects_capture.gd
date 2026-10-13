extends SceneTree
## Renders one ported effect program over a dark picture and saves frames, to look at it. Not part of the test suite.
##
## Run minimized and silent (the window is never shown, no sound):
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --minimized --audio-driver Dummy --path G:\Development\Godot\Projects\ForbiddenMemories --script res://tests/effects_capture.gd -- <id> <phase> <number> <out folder> <frames,...> [x,y]
##   (x,y: the request's offset, default 240,120 for program 2 and 160,104 otherwise; scene programs draw about (160,108) + offset)
## Frames are saved as <out folder>/effect_<id>_<frame>.png (the picture is 320 x 240).

const EffectCanvas := preload("res://scripts/duel/effects/effect_canvas.gd")
const EffectRegistry := preload("res://scripts/duel/effects/effect_registry.gd")

var viewport: SubViewport
var picture
var program
var id := 2
var phase := 0
var number := 0
var out_dir := ""
var shots: Array = []
var frame := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	id = int(args[0]) if args.size() > 0 else 2
	phase = int(args[1]) if args.size() > 1 else 0
	number = int(args[2]) if args.size() > 2 else 0
	out_dir = args[3] if args.size() > 3 else "user://"
	for s in (args[4] if args.size() > 4 else "10,30,60").split(","):
		shots.append(int(s))
	viewport = SubViewport.new()
	viewport.size = Vector2i(320, 240)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.04, 0.05, 0.09)
	backdrop.size = Vector2(320, 240)
	viewport.add_child(backdrop)
	picture = EffectCanvas.new()
	viewport.add_child(picture)
	var origin := Vector2i(240, 120) if id == 2 else Vector2i(160, 104)
	if args.size() > 5:
		var parts: PackedStringArray = args[5].split(",")
		origin = Vector2i(int(parts[0]), int(parts[1]))
	var context := {"x": origin.x, "y": origin.y, "number": number, "seed": 5}
	# program 15 takes the monsters it removes as scene positions (the duel gives them; these two stand in for a field row)
	context["cards"] = [Vector3i(-40, -20, 300), Vector3i(60, -10, 310)]
	# program 24 takes the five pieces' origins (top-left of each card), in the finale's display-slot order (top, right, lower right,
	# lower left, left): the centres of the finale's pieces less the card's half size (26, 30)
	if id == 24:
		var centres := [Vector2(160, 32), Vector2(251, 98), Vector2(216, 206), Vector2(104, 206), Vector2(69, 98)]
		context["cards"] = centres.map(func(c): return c - Vector2(26, 30))
	program = EffectRegistry.create(id, picture, context)
	if program == null:
		push_error("effect %d is not ported" % id)
		quit(1)
		return
	picture.clear()
	program.dispatch(phase)
	picture.present()


func _process(_delta: float) -> bool:
	frame += 1
	if frame >= 2:
		var step := frame - 1
		if shots.has(step):
			var image := viewport.get_texture().get_image()
			image.save_png(out_dir.path_join("effect_%d_%03d.png" % [id, step]))
			print("saved frame ", step)
		if not program.done and step < 400:
			picture.clear()
			program.dispatch(-1)
			picture.present()
		elif program.done or step >= 400:
			print("finished at frame ", step, " done=", program.done)
			quit(0)
	return false
