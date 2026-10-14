extends SceneTree
## Headless checks for the duel effect framework (scripts/duel/effects/): the console's geometry arithmetic, the colour steps, the
## picture's sorting and blend runs, and each ported program running to its finish flag without errors.
##
## Run from the project folder (headless, silent):
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --headless --path G:\Development\Godot\Projects\ForbiddenMemories --script res://tests/effects_test.gd
## Prints PASS or FAIL for each check and exits 0 when all pass, 1 otherwise.

const Gte := preload("res://scripts/duel/effects/gte.gd")
const Canvas := preload("res://scripts/duel/effects/effect_canvas.gd")
const Program := preload("res://scripts/duel/effects/effect_program.gd")
const Registry := preload("res://scripts/duel/effects/effect_registry.gd")
const Data := preload("res://scripts/duel/effects/effect_data.gd")
const DuelFx := preload("res://scripts/duel/duel_fx.gd")

var passed := 0
var failed := 0


func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("PASS  ", label)
	else:
		failed += 1
		print("FAIL  ", label)


func _init() -> void:
	_geometry()
	_colour()
	_canvas_order()
	_programs()
	_programs_8_to_16()
	_programs_18_to_24()
	_programs_23()
	_programs_3()
	_programs_17()
	_programs_22()
	print("%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _geometry() -> void:
	var gte := Gte.new()
	check("sine table: a quarter turn is 4096", Gte.rsin(1024) == 4096 and Gte.rcos(0) == 4096)
	check("sine table: the executable's rounding (sin of 1 unit is 6)", Gte.rsin(1) == 6 and Gte.rcos(1) == 4096)
	var m := Gte.new().rot_matrix(Vector3i(0, 0, 1024))
	check("rot matrix: a quarter turn about z sends x to y", m[0] == 0 and m[1] == -4096 and m[3] == 4096 and m[4] == 0)
	var identity := Gte.Mat.new().m
	check("rot matrix: zero angles give the identity", gte.rot_matrix(Vector3i.ZERO) == identity)
	var world := Gte.world_identity()
	gte.set_rt(world)
	var p := gte.rot_trans_pers(Vector3i(0, 0, 0))
	check("projection: the origin is at the offset (0, 0) with no geometry offset", p.x == 0 and p.y == 0 and p.w == 1)
	gte.set_geom_offset(160, 108)
	p = gte.rot_trans_pers(Vector3i(0, 0, 0))
	check("projection: the geometry offset is added", p.x == 160 and p.y == 108)
	p = gte.rot_trans_pers(Vector3i(300, 0, 0))
	check("projection: x scales by H over depth (300 * 300 / 300 = 300 off centre)", p.x == 160 + 300)
	var averaged := gte.rot_average([Vector3i(0, 0, 0), Vector3i(0, 0, 0), Vector3i(0, 0, 0), Vector3i(0, 0, 0)])
	check("rot average: four vertices at depth 300 average to 300", averaged.depth == 300 and averaged.ok)
	var pose_matrix := Gte.Mat.new()
	gte.pose(world, pose_matrix, Vector3i(10, 0, 0), Vector3i.ZERO, Vector3i(4096, 4096, 4096), 0)
	check("pose: a translation of the local origin under the world", gte.rt.t[2] == 300)
	gte.pose(world, pose_matrix, Vector3i.ZERO, Vector3i.ZERO, Vector3i(4096, 0, 4096), 1)
	var top := gte.rot_trans_pers(Vector3i(0, 16, 0))
	var bottom := gte.rot_trans_pers(Vector3i(0, -16, 0))
	check("pose: a zero y scale collapses a glyph's height", top.y == bottom.y)
	var start2 := Data.start_vector(2)
	var start19 := Data.start_vector(19)
	check("start vectors: effects 2 and 19 start from the baked (4096, 4096, 4096) at their symbol addresses", start2 == Vector3i(4096, 4096, 4096) and start19 == Vector3i(4096, 4096, 4096))
	gte.pose(world, pose_matrix, Vector3i.ZERO, Vector3i.ZERO, start2, 1)
	top = gte.rot_trans_pers(Vector3i(0, 16, 0))
	bottom = gte.rot_trans_pers(Vector3i(0, -16, 0))
	check("pose: the start vector of effect 2 gives a glyph its height", top.y != bottom.y)


func _colour() -> void:
	var c := PackedInt32Array([10, 200, 0])
	Program.fade_down(c, 15)
	check("fade down: a channel above step + 1 drops by the step, else to zero", c[0] == 0 and c[1] == 185 and c[2] == 0)
	var up := PackedInt32Array([0, 0, 0])
	var reached := false
	for i in 100:
		reached = Program.fade_up(up, Vector3i(255, 128, 64), 31)
		if reached:
			break
	check("fade up: reaches the target and reports it", reached and up[0] == 255 and up[1] == 128 and up[2] == 64)
	check("lit and black tests", Program.is_lit(up) and not Program.is_black(up) and Program.is_black(PackedInt32Array([0, 0, 0])))


func _canvas_order() -> void:
	var picture := Canvas.new()
	root.add_child(picture)
	picture.clear()
	picture.add_poly([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)], [Vector3i(255, 0, 0)], [], -1, 5, -1)
	picture.add_poly([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)], [Vector3i(0, 255, 0)], [], -1, 9, -1)
	picture.add_poly([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)], [Vector3i(0, 0, 255)], [], -1, 5, 1)
	picture.present()
	check("canvas: runs of one blend mode become layers (opaque, add, opaque)", picture.layer_count() == 3)
	picture.queue_free()


## Each ported program runs its first call and then frames until it finishes (within a limit), with no errors.
func _programs() -> void:
	for id in [0, 1, 2, 4, 5, 6, 7, 19]:
		var picture := Canvas.new()
		root.add_child(picture)
		var program = Registry.create(id, picture, {"x": 160, "y": 120, "flags": 0, "number": -300, "seed": 7})
		check("registry: program %d exists" % id, program != null)
		if program == null:
			picture.queue_free()
			continue
		var phase := 4 if id == 2 else 0
		program.dispatch(phase)
		picture.present()
		var frames := 0
		while not program.done and frames < 1200:
			picture.clear()
			program.dispatch(-1)
			picture.present()
			frames += 1
		check("program %d: finishes within 1200 frames (took %d)" % [id, frames], program.done and frames < 1200)
		# program 5 never sets the impact flag in the overlay (the life point splash does not hold the game for it)
		if id != 5:
			check("program %d: the impact flag was raised" % id, program.impact)
		picture.queue_free()
	var banner_picture := Canvas.new()
	root.add_child(banner_picture)
	var banner = Registry.create(2, banner_picture, {"seed": 3})
	banner.dispatch(9)
	var banner_frames := 0
	while not banner.done and banner_frames < 400:
		banner_picture.clear()
		banner.dispatch(-1)
		banner_picture.present()
		banner_frames += 1
	check("program 2: an out-of-range variant takes the banner and finishes after 180 frames (took %d)" % banner_frames, banner.done and banner_frames == 180)
	banner_picture.queue_free()
	# the variants past the configuration count take the banner too (effect 0: 30 configurations; 5: 10; 6: 6; 7: 5; 1 and 4: 2)
	for pair in [[0, 30], [1, 2], [4, 2], [5, 10], [6, 6], [7, 5]]:
		var picture := Canvas.new()
		root.add_child(picture)
		var banner_program = Registry.create(pair[0], picture, {"seed": 3})
		banner_program.dispatch(pair[1])
		var frames_left := 0
		while not banner_program.done and frames_left < 400:
			picture.clear()
			banner_program.dispatch(-1)
			picture.present()
			frames_left += 1
		check("program %d: a variant past its configurations takes the banner (took %d frames)" % [pair[0], frames_left], banner_program.done and frames_left == 180)
		picture.queue_free()
	# the duel's hosting of the programs: the battle's hit (effect 2) and the reveal (effect 19), frame by frame until both finish
	var fx := DuelFx.new()
	root.add_child(fx)
	check("duel_fx: the battle hit starts effect 2", fx._hit(-300))
	check("duel_fx: the reveal starts effect 19", fx._program(19, 0, {"x": 160, "y": 104, "seed": 19}))
	var fx_frames := 0
	while not fx.programs.is_empty() and fx_frames < 1200:
		fx._advance_programs()
		fx_frames += 1
	check("duel_fx: both programs finish and are freed (took %d frames)" % fx_frames, fx.programs.is_empty() and fx_frames < 1200)
	fx.queue_free()
	var data := Data.layout()
	check("data: the layout lists 21 texture pairs and 12 digit cells", data.get("pairs", []).size() == 21 and data.get("digits", []).size() == 12)


## Programs 8 to 16 and 20 (the removal, trap, terrain, penalty, gather, field and sweep ports): each runs its first call and frames
## to its finish flag, the impact flags are raised where the overlay raises them, the banner variants run 180 frames, and program 20
## is program 16 at phase 1. The field program is given two monster positions as its request's `cards`.
func _programs_8_to_16() -> void:
	var cases := {8: 0, 9: 0, 11: 0, 12: 0, 13: 0, 14: 3, 15: 0, 16: 0, 20: 0}
	var impacts := {9: true, 12: true, 13: true, 16: true, 20: true}
	for id in cases:
		var picture := Canvas.new()
		root.add_child(picture)
		var context := {"x": 0, "y": -20, "flags": 0, "number": -300, "seed": 11,
			"cards": [Vector3i(-40, -20, 300), Vector3i(60, -10, 310)]}
		var program = Registry.create(id, picture, context)
		check("registry: program %d exists" % id, program != null)
		if program == null:
			picture.queue_free()
			continue
		program.dispatch(cases[id])
		picture.present()
		var frames := 0
		while not program.done and frames < 1200:
			picture.clear()
			program.dispatch(-1)
			picture.present()
			frames += 1
		check("program %d: finishes within 1200 frames (took %d)" % [id, frames], program.done and frames < 1200)
		if impacts.has(id):
			check("program %d: the impact flag was raised" % id, program.impact)
		picture.queue_free()
	# the terrain change (10): the stage signal (-2) starts the sparkles and the flash; the impact comes once the rings and colour have reached
	var terrain_picture := Canvas.new()
	root.add_child(terrain_picture)
	var terrain = Registry.create(10, terrain_picture, {"seed": 5})
	terrain.dispatch(2)
	var terrain_frames := 0
	while not terrain.impact and terrain_frames < 300:
		terrain_picture.clear()
		terrain.dispatch(-1)
		terrain_picture.present()
		terrain_frames += 1
	check("program 10: the impact comes once the rings and the colour have reached (took %d frames)" % terrain_frames, terrain.impact)
	terrain.sticky_phase = -2
	var stage_frames := 0
	while not terrain.done and stage_frames < 1200:
		terrain_picture.clear()
		terrain.dispatch(-1)
		terrain_picture.present()
		stage_frames += 1
	check("program 10: the stage signal (-2) carries to the later frames and the program finishes (took %d frames)" % stage_frames,
		terrain.done and terrain.stage == 1)
	terrain_picture.queue_free()
	# the banner variants of 8 (6 configurations), 9 (5), 10 (6), 11 (variant 5 of the packed phase), 13 (4), 14 (10), 15 (8), 16 (2)
	for pair in [[8, 6], [9, 5], [10, 6], [11, 5], [13, 4], [14, 10], [15, 8], [16, 2]]:
		var picture := Canvas.new()
		root.add_child(picture)
		var banner_program = Registry.create(pair[0], picture, {"seed": 3, "cards": [Vector3i.ZERO]})
		banner_program.dispatch(pair[1])
		var frames_left := 0
		while not banner_program.done and frames_left < 400:
			picture.clear()
			banner_program.dispatch(-1)
			picture.present()
			frames_left += 1
		check("program %d: a variant past its configurations takes the banner (took %d frames)" % [pair[0], frames_left], banner_program.done and frames_left == 180)
		picture.queue_free()


## Programs 18, 21 and 24 (the ring burst, the Swords field effect and the Exodia final): each runs to its finish with no errors.
## 18 finishes at both its variants and raises the impact; 21 switches a slot on, is switched off by a second call on the same slot
## and finishes on the next frame; 24 takes the five picture points of the field's pieces and finishes with the impact raised.
func _programs_18_to_24() -> void:
	for phase in [0, 1]:
		var picture := Canvas.new()
		root.add_child(picture)
		var program = Registry.create(18, picture, {"x": 160, "y": 120, "flags": 8, "seed": 18})
		check("registry: program 18 exists", program != null)
		if program != null:
			picture.clear()
			program.dispatch(phase)
			picture.present()
			var frames := 0
			while not program.done and frames < 1200:
				picture.clear()
				program.dispatch(-1)
				picture.present()
				frames += 1
			check("program 18 at phase %d: finishes (took %d frames) with the impact raised" % [phase, frames], program.done and program.impact)
		picture.queue_free()
	var first_canvas := Canvas.new()
	root.add_child(first_canvas)
	var slot_on = Registry.create(21, first_canvas, {"x": 160, "y": 120, "flags": 8, "seed": 21})
	first_canvas.clear()
	slot_on.dispatch(0)
	first_canvas.present()
	for i in 30:
		first_canvas.clear()
		slot_on.dispatch(-1)
		first_canvas.present()
	check("program 21: a set-up slot runs on and does not finish by itself", not slot_on.done)
	var second_canvas := Canvas.new()
	root.add_child(second_canvas)
	var slot_off = Registry.create(21, second_canvas, {"x": 160, "y": 120, "flags": 8, "seed": 22})
	second_canvas.clear()
	slot_off.dispatch(0)
	second_canvas.present()
	first_canvas.clear()
	slot_on.dispatch(-1)
	first_canvas.present()
	check("program 21: a second call on the same slot switches it off and the first finishes", slot_on.done)
	check("program 21: the second call's request is not finished by its own set-up call", not slot_off.done)
	first_canvas.queue_free()
	second_canvas.queue_free()
	# the card origins (top-left) of the five pieces, in the finale's order (centre less (26, 30))
	var cards := [Vector2(134, 2), Vector2(225, 68), Vector2(190, 176), Vector2(78, 176), Vector2(43, 68)]
	var exodia_canvas := Canvas.new()
	root.add_child(exodia_canvas)
	var exodia = Registry.create(24, exodia_canvas, {"cards": cards, "flags": 8, "seed": 24})
	check("registry: program 24 exists", exodia != null)
	if exodia != null:
		exodia_canvas.clear()
		exodia.dispatch(0)
		exodia_canvas.present()
		var frames := 0
		while not exodia.done and frames < 1200:
			exodia_canvas.clear()
			exodia.dispatch(-1)
			exodia_canvas.present()
			frames += 1
		check("program 24: finishes (took %d frames) with the impact raised" % frames, exodia.done and exodia.impact)
		var tips_ok := true
		for i in 5:
			var tip: Vector3i = exodia.targets[i] + exodia.center
			var origin: Vector2 = cards[i]
			tips_ok = tips_ok and tip.x == int(origin.x) + 24 and tip.y == int(origin.y) + 28
		check("program 24: each beam tip is its card origin plus (24, 28), the card's centre", tips_ok)
	exodia_canvas.queue_free()
	# the duel's hooks: the windows of the sweep, the stop, the penalty and the terrain change start their programs; the terrain's stage
	# signal follows its impact, and every program finishes and is freed
	var window_fx := DuelFx.new()
	root.add_child(window_fx)
	check("duel_fx: the sweep window starts program 16", window_fx._window_program("sweep", 336, Vector2(160, 120)))
	check("duel_fx: the stop window starts program 12", window_fx._window_program("stop", 320, Vector2(160, 120)))
	check("duel_fx: the penalty window starts program 13", window_fx._window_program("penalty", 349, Vector2(160, 120)))
	check("duel_fx: the terrain window starts program 10", window_fx._window_program("terrain", 331, Vector2(160, 120)))
	check("duel_fx: a heal window starts program 9 (its variant the amount table index)", window_fx._window_program("heal", 338, Vector2(160, 120)))
	var window_frames := 0
	while not window_fx.programs.is_empty() and window_frames < 2000:
		window_fx._advance_programs()
		window_frames += 1
	check("duel_fx: the window programs finish and are freed (took %d frames)" % window_frames, window_fx.programs.is_empty())
	window_fx.queue_free()


## A stand-in for the duel's card-object channel: the cards of one row and their object states.
class StubBoard extends RefCounted:
	var rows_list: Array = []
	var pos := {}
	var spins := {}
	var bright := {}
	var shown_of := {}

	func rows(_side: int, _row: String) -> Array:
		return rows_list

	func field_cards(_monsters_only: bool = false) -> Array:
		return rows_list

	var sizes := {}
	var tint_set := Vector3i(128, 128, 128)

	func size(record: int) -> Vector2i:
		return sizes.get(record, Vector2i(4096, 4096))

	func set_size(record: int, to: Vector2i) -> void:
		sizes[record] = to

	func set_tint(rgb: Vector3i) -> void:
		tint_set = rgb

	func position(record: int) -> Vector3i:
		return pos.get(record, Vector3i.ZERO)

	func move(record: int, to: Vector3i) -> void:
		pos[record] = to

	func spin(record: int) -> Vector3i:
		return spins.get(record, Vector3i.ZERO)

	func turn(record: int, bytes: Vector3i) -> void:
		spins[record] = bytes

	func brightness(record: int) -> Vector3i:
		return bright.get(record, Vector3i(128, 128, 128))

	func set_brightness(record: int, rgb: Vector3i) -> void:
		bright[record] = rgb

	func shown(record: int) -> bool:
		return bool(shown_of.get(record, true))

	func set_shown(record: int, on: bool) -> void:
		shown_of[record] = on


## Effect 23 (the feather duster): swept cards are struck left to right and hidden one at a time, its sparkles run, and it finishes
## with the cards dimmed. Run both ways, and the magic window starts it.
func _programs_23() -> void:
	for forward in [true, false]:
		var board := StubBoard.new()
		board.rows_list = [40, 41, 42, 43, 44]
		var z := -95 if forward else 95
		for k in 5:
			board.pos[40 + k] = Vector3i(-140 + 70 * k if forward else 140 - 70 * k, -24, z)
		var picture := Canvas.new()
		root.add_child(picture)
		var program = Registry.create(23, picture, {"seed": 23, "objects": board, "side": 1, "forward": forward, "row_z": z})
		check("registry: program 23 exists", program != null)
		program.dispatch(0)
		picture.present()
		var frames := 0
		while not program.done and frames < 1200:
			picture.clear()
			program.dispatch(-1)
			picture.present()
			frames += 1
		var dark := 0
		var hidden := 0
		for k in 5:
			if board.brightness(40 + k) == Vector3i.ZERO:
				dark += 1
			if not board.shown(40 + k):
				hidden += 1
		check("program 23 (forward %s): finishes within 1200 frames (took %d)" % [str(forward), frames], program.done and frames < 1200)
		check("program 23 (forward %s): every swept card is struck and dimmed to black (%d of 5)" % [str(forward), dark], dark == 5)
		check("program 23 (forward %s): the overlay's hide counter hides a dark card (%d hidden)" % [str(forward), hidden], hidden >= 1)
		check("program 23 (forward %s): the cards moved along the row" % str(forward), board.position(40) != Vector3i(-140 if forward else 140, -24, z))
		picture.queue_free()
	var fx := DuelFx.new()
	root.add_child(fx)
	fx.host = StubHost.new()
	var started: bool = fx._window_program("feather", 672, Vector2(160, 120), 0)
	check("duel_fx: the feather window starts program 23", started)
	var window_frames := 0
	while not fx.programs.is_empty() and window_frames < 1200:
		fx._advance_programs()
		window_frames += 1
	check("duel_fx: the feather program finishes and is freed (took %d frames)" % window_frames, fx.programs.is_empty())
	fx.queue_free()


## The duel scene's record numbering (the host's _record), for the effect tests that need the record of a board cell.
class StubHost extends RefCounted:
	func _record(side: int, row: String, i: int) -> int:
		return (5 if side == 0 else 20) + (0 if row == "monsters" else 5) + i


## Effect 3 (the tile sparkle): each descriptor runs to its frame count with the sheet's 35 tiles lit and sparkling, the banner path
## takes the variant past the two descriptors, and the copy of a card is 140 x 196 with its corners cleared.
func _programs_3() -> void:
	for phase in [0, 1]:
		var picture := Canvas.new()
		root.add_child(picture)
		var program = Registry.create(3, picture, {"seed": 3})
		program.dispatch(phase)
		picture.present()
		var frames := 0
		while not program.done and frames < 1200:
			picture.clear()
			program.dispatch(-1)
			picture.present()
			frames += 1
		var limit := int(Data.configs()["effect_3"][phase]["frames"])
		check("program 3 (descriptor %d): finishes after its %d frames (took %d)" % [phase, limit, frames], program.done and frames == limit + 1)
		picture.queue_free()
	var banner_picture := Canvas.new()
	root.add_child(banner_picture)
	var banner = Registry.create(3, banner_picture, {"seed": 3})
	banner.dispatch(2)
	var banner_frames := 0
	while not banner.done and banner_frames < 400:
		banner_picture.clear()
		banner.dispatch(-1)
		banner_picture.present()
		banner_frames += 1
	check("program 3: a variant past its descriptors takes the banner (took %d frames)" % banner_frames, banner.done and banner_frames == 180)
	banner_picture.queue_free()
	var fx := DuelFx.new()
	root.add_child(fx)
	var sheet: Image = fx._capture_card(5, null)
	check("duel_fx: the card read-back is 140 x 196 with its corners cleared", sheet.get_size() == Vector2i(140, 196) and sheet.get_pixel(0, 0).a == 0.0 and sheet.get_pixel(70, 98).a == 1.0)
	fx.queue_free()


## Effect 17 (board destruction, Dark Hole): both modes run to their finish flag, every board card is drawn in, hidden and removed from the
## board's sight, the board tint dims and returns to neutral, and the banner path takes a variant past the two configurations.
func _programs_17() -> void:
	for phase in [0, 1]:
		var board := StubBoard.new()
		board.rows_list = [40, 41, 42, 43, 44, 25, 26]
		for k in board.rows_list.size():
			board.pos[board.rows_list[k]] = Vector3i(-140 + 70 * (k % 5), -24, -95 if k < 5 else 95)
		var picture := Canvas.new()
		root.add_child(picture)
		var program = Registry.create(17, picture, {"seed": 17, "objects": board, "x": 0, "y": -20, "z": 0})
		check("registry: program 17 exists", program != null)
		program.dispatch(phase)
		picture.present()
		var frames := 0
		var dimmest := 128
		while not program.done and frames < 1200:
			picture.clear()
			program.dispatch(-1)
			picture.present()
			dimmest = mini(dimmest, board.tint_set.x)
			frames += 1
		var hidden := 0
		for record in board.rows_list:
			if not board.shown(record):
				hidden += 1
		check("program 17 (variant %d): finishes within 1200 frames (took %d)" % [phase, frames], program.done and frames < 1200)
		check("program 17 (variant %d): every card is drawn in and hidden (%d of %d)" % [phase, hidden, board.rows_list.size()], hidden == board.rows_list.size())
		check("program 17 (variant %d): the board tint dims to black and returns (darkest %d, now %d)" % [phase, dimmest, board.tint_set.x], dimmest <= 16 and board.tint_set.x == 128)
		picture.queue_free()
	var banner_picture := Canvas.new()
	root.add_child(banner_picture)
	var banner = Registry.create(17, banner_picture, {"seed": 17})
	banner.dispatch(2)
	var banner_frames := 0
	while not banner.done and banner_frames < 400:
		banner_picture.clear()
		banner.dispatch(-1)
		banner_picture.present()
		banner_frames += 1
	check("program 17: a variant past its configurations takes the banner (took %d frames)" % banner_frames, banner.done and banner_frames == 180)
	banner_picture.queue_free()


## Effect 22 (the ritual apply): two rituals run to their finish flag with the tributes flown in, hidden, and the impact raised; a ritual
## id the table does not know takes the banner.
func _programs_22() -> void:
	for ritual in [670, 691]:
		var board := StubBoard.new()
		board.rows_list = [40, 41, 42]
		for k in 3:
			board.pos[40 + k] = Vector3i(-70 + 70 * k, -24, -95)
		var picture := Canvas.new()
		root.add_child(picture)
		var program = Registry.create(22, picture, {"seed": 22, "objects": board, "tributes": [40, 41, 42], "side": 0})
		program.dispatch(ritual)
		picture.present()
		var frames := 0
		while not program.done and frames < 1500:
			picture.clear()
			program.dispatch(-1)
			picture.present()
			frames += 1
		var hidden := 0
		for k in 3:
			if not board.shown(40 + k):
				hidden += 1
		check("program 22 (ritual %d): finishes within 1500 frames (took %d)" % [ritual, frames], program.done and frames < 1500)
		if ritual == 670:
			# the field view: the portal's first frame quads sit where the reference's geometry puts them (tributes at z -95)
			var first := Canvas.new()
			root.add_child(first)
			var fresh_board := StubBoard.new()
			fresh_board.rows_list = [40, 41, 42]
			for k in 3:
				fresh_board.pos[40 + k] = Vector3i(-70 + 70 * k, -24, -95)
			var first_program = Registry.create(22, first, {"seed": 22, "objects": fresh_board, "tributes": [40, 41, 42], "side": 0})
			first_program.dispatch(ritual)
			first.clear()
			first_program.dispatch(-1)
			var quads: Array = []
			for record in first._records:
				quads.append(record["pts"])
			var want := PackedVector2Array([Vector2(194, 110), Vector2(231, 110), Vector2(193, 141), Vector2(227, 141)])
			check("program 22: the portal's quads sit at the field view's points (%s)" % str(quads),
					quads.size() >= 2 and quads[0].size() == 4 and quads[0][0].distance_to(want[0]) < 2.0 and quads[0][3].distance_to(want[3]) < 2.0)
			first.queue_free()
		check("program 22 (ritual %d): the tributes are hidden (%d of 3)" % [ritual, hidden], hidden == 3)
		check("program 22 (ritual %d): the impact is raised before the finish" % ritual, program.impact)
		check("program 22 (ritual %d): the board tint is back to neutral" % ritual, board.tint_set == Vector3i(128, 128, 128))
		picture.queue_free()
	var banner_picture := Canvas.new()
	root.add_child(banner_picture)
	var banner = Registry.create(22, banner_picture, {"seed": 22, "objects": StubBoard.new(), "tributes": []})
	banner.dispatch(999)
	var banner_frames := 0
	while not banner.done and banner_frames < 400:
		banner_picture.clear()
		banner.dispatch(-1)
		banner_picture.present()
		banner_frames += 1
	check("program 22: an unknown ritual id takes the banner (took %d frames)" % banner_frames, banner.done and banner_frames == 180)
	banner_picture.queue_free()

