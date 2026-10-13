extends Control
## The credits: the credits run (frontend mode 15) and the SU credits module it runs, built from
## assets/screens/credits/ (tools/extract.py bake_credits): roll.json holds the module's 153 table rows (group, flags, text) and the five
## secret numbers, font_0..2.png are the glyph atlases under the three palettes of the routine at 0x801807B0.
##
## The phases follow the credits run: the save prompt (save_requested; the host answers with save_done), the secret number box, then the
## roll. The roll is the routine at 0x80180A24 run at the credits' 30 fps tick (two VBlanks per tick, the data at 0x8009B0D8 = 2): two lines, each fading in,
## holding, fading out, one paragraph at a time, and a group that ends starts the next one in the free line. Its last card (group 99) holds.
##
## The wireframe monsters behind the roll (scripts/menu/credits_monsters.gd: the two model slots, their animation (monster_anim.gd, baked
## into credits/monsters.bin) and the camera; started with the roll, faded when it ends). Not reproduced: the original rand() sequence (which
## monster each slot takes and the colour walk use Godot's randomness), the loader's frame timing (a slot loads at once), and the exact
## camera framing (the look-at point is the monsters' centre; the original's move target and distance are approximated). The credits BGM
## (track 0x330, the routine at 0x80047314(0x7330)) is cued at the roll start (not verified against the reference audio).
## The save-state completion (campaign index 0x30, the card
## flags, the completed bits) is GameState.complete_campaign(), which boot runs as the ending starts. The background is black. The end is approximated: the last card holds for 0x98 ticks, then
## finished() is emitted; the original waits for the presentation to end.

signal finished
signal save_requested
signal sound(effect: int)
signal music(id: int)   # the routine at 0x80047314(0x7330): the credits track, played as the roll begins (the audio plays it)

const SCREENS := "res://assets/screens/credits/"
const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const TouchControls := preload("res://scripts/system/touch_controls.gd")
const CreditsMonsters := preload("res://scripts/menu/credits_monsters.gd")

const TICK_FRAMES := 2          # the roll runs at 30 fps: one tick per two 60 Hz frames
const DELTA := 2                # the data at 0x8009B0D8, the VBlanks per tick; the fading states move their timers by DELTA * 2
const HOLD_TIMER := 0x98        # the timer a line starts each state with
const FADE_WAIT_TIMER := 0x3C   # state 3 (the blank between two paragraphs)
const END_HOLD := 0x98          # approximation: the last card holds for this many ticks before finished()
const ROW := 16                 # the row pitch of the roll
const LINE_X := 40              # a line that fits (width <= 160 and height <= 120) sits at (40, 40)
const LINE_Y := 40
const GLYPH := Vector2(8, 12)
const ATLAS := Vector2(128, 72)
const GROUP_END := 0x63         # a line whose first row is group 99 holds the roll (the last card)
const BGM := 0x7330             # the routine at 0x80047314(29488): the credits track, BGM 0x330 (not played yet)

const SECRET_STRING := 0x23     # the flagged text box creation(0, 0x23, 0x10, 0x70, 0x120, 0x20, 8)
const SECRET_BOX := Vector2(16, 112)
const SECRET_SIZE := Vector2(288, 32)
const SECRET_TEXT := Vector2(24, 120)
const NUMBER_LO := 0x801D5608   # the data at 0x801D5608[0].pair: the lo and hi halves the box prints
const NUMBER_HI := 0x801D560C
const DIGIT_SJIS := 0x824F      # the Shift-JIS code of '0'; the digits follow it

var text := GameText.new()
var rows: Array = []
var secrets: Array = []
var fonts: Array = []
var lines: Array = []
var done := false          # the data at 0x80182208: the last card has been reached
var pending: Array = []    # what the roll drew last: snapshots of the lines and their corner brightness
var phase := ""
var roll_frame := 0
var end_ticks := 0
var armed := false
var sharp: ShaderMaterial
var world := Node2D.new()
var canvas := Node2D.new()
var box_nodes: Array = []
var monsters := CreditsMonsters.new()     # the wireframe monsters behind the roll (the presentation of the routine at 0x800507D0)
var monster_canvas := Node2D.new()
var monsters_loaded := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not _load():
		return
	sharp = ScreenFit.make_material()
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(black)
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	canvas.material = sharp
	canvas.draw.connect(_draw_canvas)
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD   # the monsters' polylines add to what is behind them
	monster_canvas.material = additive
	monster_canvas.draw.connect(_draw_monsters)
	monsters_loaded = monsters.load_all()
	world.add_child(monster_canvas)
	world.add_child(canvas)
	add_child(world)
	add_to_group("fit")
	get_viewport().size_changed.connect(refit)
	refit()
	_enter("save")


func refit() -> void:
	ScreenFit.apply(world, size)


func _load() -> bool:
	if not text.load_all():
		return false
	var path := SCREENS + "roll.json"
	if not FileAccess.file_exists(path):
		return false
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		return false
	rows = data["rows"]
	secrets = data["secret_numbers"]
	for k in 3:
		var image := Image.load_from_file(SCREENS + "font_%d.png" % k)
		if image == null:
			return false
		fonts.append(ImageTexture.create_from_image(image))
	return true


func _enter(next: String) -> void:
	phase = next
	armed = false
	if next == "save":
		save_requested.emit()
	elif next == "secret":
		_open_secret_box()
	elif next == "roll":
		_begin_roll()


func _pressed() -> bool:
	return Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER) \
		or TouchControls.game_pointer_held()


func _physics_process(_delta: float) -> void:
	if fonts.is_empty():
		return
	match phase:
		"secret":
			var down := _pressed()
			if not armed:
				armed = not down
				return
			if down:
				sound.emit(7)
				_clear_box()
				_enter("roll")
		"roll":
			roll_frame += 1
			if monsters_loaded:
				monsters.step()
			if roll_frame % TICK_FRAMES == 0:
				_tick()
				if done:
					if monsters_loaded:
						monsters.fade()
					end_ticks += 1
					if end_ticks >= END_HOLD:
						phase = "end"
						finished.emit()
	canvas.queue_redraw()
	monster_canvas.queue_redraw()


## The host answers save_requested: ok ends the prompt (the secret number follows); a failed save asks again.
func save_done(ok: bool) -> void:
	if phase != "save":
		return
	if ok:
		_enter("secret")
	else:
		save_requested.emit()


## the credits run' secret number box: string 0x23 with the pair of numbers for duelist_code % 5.
func _open_secret_box() -> void:
	var panel := ColorRect.new()
	panel.color = Color(0, 0, 0, 1)
	panel.position = SECRET_BOX
	panel.size = SECRET_SIZE
	world.add_child(panel)
	box_nodes.append(panel)
	var pair: Array = secrets[GameState.duelist_code % secrets.size()]
	var digits: Array = []
	for i in 10:
		digits.append(text.code_for_sjis(DIGIT_SJIS + i))
	var ctx := {"numbers": {NUMBER_LO: int(pair[0]), NUMBER_HI: int(pair[1])}, "digits": digits}
	for sprite in text.layout(world, text.string_bytes(SECRET_STRING), SECRET_TEXT, GLYPH, 0, sharp, true, {}, ctx):
		if sprite["sprite"] != null:
			box_nodes.append(sprite["sprite"])


func _clear_box() -> void:
	for node in box_nodes:
		node.queue_free()
	box_nodes.clear()


## the routine at 0x801807B0 (both lines empty, the flag clear) and the routine at 0x80181C4C(0): the first group starts in the first free line.
func _begin_roll() -> void:
	music.emit(BGM)
	lines = [_new_line(), _new_line()]
	done = false
	end_ticks = 0
	roll_frame = 0
	if monsters_loaded:
		monsters.start()
	_start_group(0)


func _new_line() -> Dictionary:
	return {"entries": -1, "end": 0, "x": 0, "y": 0, "timer": 0, "width": 0, "height": 0, "state": 0, "field_13": 0, "page": 0}


func _group(i: int) -> int:
	return int(rows[i]["group"]) if i < rows.size() else -1


func _flags(i: int) -> int:
	return int(rows[i]["flags"]) if i < rows.size() else 0


## the routine at 0x80181C4C: the first free line takes `group`, placed at (40, 40) or centred when it is wide or tall.
func _start_group(group: int) -> void:
	for i in 2:
		var line: Dictionary = lines[i]
		if line["entries"] < 0:
			line["height"] = 0
			line["width"] = 0
			line["page"] = 0
			if _collect(i, group) != 0:
				_place(line)
			return


func _place(line: Dictionary) -> void:
	line["x"] = LINE_X
	line["y"] = LINE_Y
	if line["width"] > 160 or line["height"] > 120:
		line["x"] = (320 - int(line["width"])) / 2
		line["y"] = (240 - int(line["height"])) / 2 - 10
	line["state"] = 0
	line["timer"] = HOLD_TIMER
	line["field_13"] = 0


## the routine at 0x80180F58: the rows of `group` for line `index`: the first matching row becomes the line's entries, the width and height
## come from the rows, the page is the paragraph of the row after the first text row, and the row count is returned.
func _collect(index: int, group: int) -> int:
	var line: Dictionary = lines[index]
	var e := 0
	var count := 0
	var cur := 0
	var h := 0
	while _group(e) >= 0:
		if group < _group(e):
			break
		if _group(e) == group:
			var flags := _flags(e)
			var content = rows[e]["text"]
			var g := flags >> 4
			if line["entries"] < 0:
				line["entries"] = e
				cur = g
			if cur == g:
				h += ROW
			else:
				if line["height"] < h:
					line["height"] = h
				cur = g
				h = 0
			if content != null:
				var w: int = (String(content).length() / 2) * 16
				if line["width"] < w:
					line["width"] = w
				if line["page"] == 0:
					line["page"] = _flags(e + 1) >> 4
				count += 1
				if count >= 30:
					break
		e += 1
	line["end"] = e
	if line["height"] < h:
		line["height"] = h
	if line["page"] != 0:
		line["height"] += ROW
	return count


## the routine at 0x80180A24: one tick of both lines. Returns done (the data at 0x80182208).
func _tick() -> void:
	pending.clear()
	for i in 2:
		var line: Dictionary = lines[i]
		if line["entries"] < 0:
			continue
		match int(line["state"]):
			0:
				var t: int = (0x80 - int(line["timer"])) << 7
				var a: int = clampi(t / 32, 0, 0x80)
				var b: int = clampi(t / 64, 0, 0x80)
				var c: int = clampi(t / 96, 0, 0x80)
				var d: int = clampi(t / 128, 0, 0x80)
				line["timer"] = int(line["timer"]) - DELTA * 2
				if int(line["timer"]) <= 0:
					line["timer"] = HOLD_TIMER
					line["state"] = 1
				_queue(i, [a, b, c, d])
			1:
				if _group(line["entries"]) == GROUP_END:
					done = true
				else:
					line["timer"] = int(line["timer"]) - DELTA
					if int(line["timer"]) <= 0:
						line["timer"] = HOLD_TIMER
						line["state"] = 2
						if int(line["field_13"]) != 0:
							if int(line["page"]) == 1:
								line["field_13"] = 0
						else:
							line["field_13"] = int(line["field_13"]) + 1
				_queue(i, [0x80, 0x80, 0x80, 0x80])
			2:
				var k := 0x80
				var t2: int = (k - int(line["timer"])) << 7
				var a2: int = clampi(t2 / 32, 0, 0x80)
				var b2: int = clampi(t2 / 64, 0, 0x80)
				var c2: int = clampi(t2 / 96, 0, 0x80)
				var d2: int = clampi(t2 / 128, 0, 0x80)
				line["timer"] = int(line["timer"]) - DELTA * 2
				if int(line["timer"]) <= 0:
					if int(line["page"]) >= 2:
						line["timer"] = FADE_WAIT_TIMER
						line["state"] = 3
					else:
						line["timer"] = HOLD_TIMER
						line["state"] = 4
				_queue(i, [k - d2, k - c2, k - b2, k - a2])
			3:
				line["timer"] = int(line["timer"]) - DELTA * 2
				if int(line["timer"]) <= 0:
					line["timer"] = HOLD_TIMER
					line["state"] = 0
					line["page"] = int(line["page"]) - 1
					if int(line["page"]) != 0:
						_collect(i, _group(line["entries"]))
					else:
						line["timer"] = HOLD_TIMER
						line["state"] = 4
				_queue(i, [0, 0, 0, 0])
			4:
				line["timer"] = int(line["timer"]) - DELTA * 2
				if int(line["timer"]) <= 0:
					var n := _group(line["end"])
					if n >= 0:
						for j in 2:
							var other: Dictionary = lines[j]
							if other["entries"] < 0:
								other["height"] = 0
								other["width"] = 0
								other["page"] = 0
								if _collect(j, n) != 0:
									_place(other)
								break
					line["entries"] = -1


func _queue(i: int, corners: Array) -> void:
	pending.append({"line": (lines[i] as Dictionary).duplicate(), "c": corners})


## the routine at 0x8018173C: one line's current page. Every row of the page is drawn; a row's glyphs are 8 by 12 cells of the font page, one
## quad each, with the four corners at the four brightnesses (fading diagonally from the top left). The shadow of each glyph is
## never drawn (its poly is not sorted), so only the glyph is.
func _draw_canvas() -> void:
	for item in pending:
		_draw_line(item["line"], item["c"])


func _draw_line(line: Dictionary, c: Array) -> void:
	if int(line["entries"]) < 0:
		return
	var drawn := 0
	var x: float = line["x"]
	var y: float = line["y"]
	var entry: int = line["entries"]
	var first := _group(entry)
	while true:
		var flags := _flags(entry)
		var group := flags >> 4
		var kind := flags & 0xF
		var font := 2 if kind == 2 else (1 if kind == 1 else 0)
		var content = rows[entry]["text"]
		if drawn == 0 or int(line["page"]) == group:
			if content != null:
				var r: Array = c.duplicate()
				if int(line["field_13"]) != 0 and int(line["page"]) != 0 and drawn == 0:
					r = [0x80, 0x80, 0x80, 0x80]
				var special := _group(entry) == GROUP_END and kind == 0
				_draw_text(String(content), x, y, font, special, r)
				x = line["x"]
				drawn += 1
			y += ROW
		elif content != null:
			drawn += 1
		entry += 1
		if _group(entry) != first:
			break


func _draw_text(content: String, x: float, y: float, font: int, special: bool, r: Array) -> void:
	for i in content.length():
		var code := content.unicode_at(i)
		code += 0x20 if code >= 0x61 else 0x1F
		var face := font
		if special:
			face = 1 if (code & 0xFF) == 0x69 else 0
		var u := (code & 0xF) * 8
		var v := (((code & 0xF0) >> 4) - 4) * 12
		if v >= 0:
			var colours := PackedColorArray()
			for corner in [r[0], r[1], r[3], r[2]]:
				colours.append(Color(float(corner) / 128.0, float(corner) / 128.0, float(corner) / 128.0, 0.5))
			var points := PackedVector2Array([Vector2(x, y), Vector2(x + 8, y), Vector2(x + 8, y + 12), Vector2(x, y + 12)])
			var uvs := PackedVector2Array([
				Vector2(u, v) / ATLAS, Vector2(u + 8, v) / ATLAS,
				Vector2(u + 8, v + 12) / ATLAS, Vector2(u, v + 12) / ATLAS])
			canvas.draw_polygon(points, colours, uvs, fonts[face])
		x += 8


## The monsters' outlines (the presentation drawn behind the roll, in the picture's coordinates).
func _draw_monsters() -> void:
	monsters.draw_on(monster_canvas)
