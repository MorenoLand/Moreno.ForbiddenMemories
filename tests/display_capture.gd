extends SceneTree
## Picture captures for the display options: the front-end menu, a story scene, the campaign map, the library and the password shop,
## drawn in a window of the size given by --size=WxH with the picture sampling of --filter=pixel|sharp|smooth (and --crt for the
## scanlines, --hd=off for the baked pictures without the HD mirror). It writes one PNG per screen to the folder after --out=, then
## prints DONE. It needs a window (the picture is read from it), so run it minimized and silent:
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --minimized --audio-driver Dummy --path G:\Development\Godot\Projects\ForbiddenMemories --script res://tests/display_capture.gd -- --out=C:\path --size=1920x1080 --filter=sharp
## The sampling is set in the static state only (user://settings.json is put back as it was). The boot's sequence is skipped.

const MainMenu := preload("res://scripts/menu/main_menu.gd")
const StoryPlayer := preload("res://scripts/story/story_player.gd")
const CampaignMap := preload("res://scripts/map/campaign_map.gd")
const Library := preload("res://scripts/menu/library.gd")
const Password := preload("res://scripts/menu/password.gd")
const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const OpeningMovie := preload("res://scripts/boot/opening_movie.gd")
const DuelScene := preload("res://scripts/duel/duel_scene.gd")

const SETTINGS := "user://settings.json"
const CASES := ["menu", "story", "map", "library", "password", "movie", "settings", "duel"]
const WAIT_FRAMES := 40
const DUEL_WAIT_FRAMES := 1800     # the duel deals its hand in its opening frames

var out_dir := "user://captures"
var size := Vector2i(1920, 1080)
var filter := 1
var crt := false
var hd := true
var only := ""
var cases: Array = []
var boot: Node = null
var node: Node = null
var frames := 0
var phase := 0
var current := ""
var settings_backup := ""
var had_settings := false


func _initialize() -> void:
	var filter_name := "sharp"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.substr(6)
		elif arg.begins_with("--size="):
			var parts := arg.substr(7).split("x")
			size = Vector2i(int(parts[0]), int(parts[1]))
		elif arg.begins_with("--filter="):
			filter_name = arg.substr(9)
		elif arg.begins_with("--only="):
			only = arg.substr(7)
		elif arg == "--crt":
			crt = true
		elif arg == "--hd=off":
			hd = false
	filter = maxi(ScreenFit.FILTER_NAMES.find(filter_name), 0)
	DirAccess.make_dir_recursive_absolute(out_dir)
	had_settings = FileAccess.file_exists(SETTINGS)
	if had_settings:
		settings_backup = FileAccess.get_file_as_string(SETTINGS)
	if not hd:
		ScreenFit.save_setting("hd_art", false)
	DisplayServer.window_set_size(size)
	cases = CASES.duplicate()
	if only != "":
		cases = [only]
	boot = load("res://scenes/main.tscn").instantiate()
	root.add_child(boot)


func _process(_delta: float) -> bool:
	if boot == null:
		return false
	frames += 1
	if frames < 5:
		return false
	if frames == 5:
		# the boot's own sequence is not wanted: the picture is set up and the front end is the next screen
		boot.phase = "done"
		boot.picture.visible = false
		ScreenFit._read = true
		ScreenFit.filter = filter
		ScreenFit.crt = crt
		ScreenFit._refresh()
		return false
	if node == null and phase == 0:
		if cases.is_empty():
			_restore()
			print("DONE")
			quit(0)
			return false
		current = cases.pop_front()
		_setup(current)
		phase = 1
		frames = 6
		return false
	if phase == 1 and frames >= 6 + (DUEL_WAIT_FRAMES if current == "duel" else WAIT_FRAMES):
		var image := root.get_texture().get_image()
		var path := out_dir.path_join("%s_%s_%dx%d%s%s.png" % [current, ScreenFit.FILTER_NAMES[filter], size.x, size.y, "_crt" if crt else "", "" if hd else "_nohd"])
		image.save_png(path)
		print("saved ", path, " ", image.get_width(), "x", image.get_height())
		if node != null:
			node.queue_free()
		if current == "settings":
			boot.settings_panel.visible = false
		node = null
		phase = 0
	return false


func _setup(name: String) -> void:
	match name:
		"menu":
			boot._open_menu(0)
			node = boot.get_child(boot.get_child_count() - 1)
		"story":
			var story := StoryPlayer.new()
			story.scene_index = 0
			boot._connect_story(story)
			node = story
		"map":
			var map := CampaignMap.new()
			map.place = 0
			boot.add_child(map)
			node = map
		"library":
			node = Library.new()
			boot.add_child(node)
		"password":
			node = Password.new()
			boot.add_child(node)
		"movie":
			node = OpeningMovie.new()
			boot.add_child(node)
			ScreenFit.apply(node, Vector2(boot.size), 240.0, 480.0)
		"settings":
			boot.settings_panel.visible = true
		"duel":
			node = DuelScene.new()
			node.opponent_id = 1
			node.engine_seed = 7     # the same deal with the HD art on or off, so the two captures can be compared
			boot.add_child(node)


func _restore() -> void:
	if had_settings:
		var file := FileAccess.open(SETTINGS, FileAccess.WRITE)
		if file != null:
			file.store_string(settings_backup)
	elif FileAccess.file_exists(SETTINGS):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
