extends Node
## The duel's controls help, in the game's own look and inside the picture. H, ? or Tab opens the controls menu: a list (KEYBOARD,
## MOUSE, TOUCH, CLOSE) in the story's stone dialog frame, with the duel's yellow choice bar as the selector. The menu works with the
## keys, the mouse and the touch layer; Esc, Q, Cancel or a right click backs out, and H closes it. The first duel opens the tutorial
## in the same frame. A refusal, and the first-time fuse tip, are said on the game's own info line. The hand gets its COMBINE badges
## and the fusion preview, and the monsters that can attack pulse. The scene reads the keys; this file shows them and reads the engine
## (resolve_chain is a preview and changes nothing), so no rule is decided here.

const DuelHand := preload("res://scripts/duel/duel_hand.gd")
const TextFrame := preload("res://scripts/ui/text_frame.gd")

const REFUSE_TIME := 2.5                # seconds a refusal stays on the info line
const TIP_TIME := 6.0                   # seconds the first-time fuse tip stays on the info line
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "duel_help"
const FRAME_PATH := "res://assets/screens/story/frame.png"
const FRAME_SRC := Rect2(0, 152, 320, 88)            # the dialog frame's panel in the story frame picture
const FRAME_BORDER := Vector4(8, 8, 8, 8)            # its stone border, in source pixels
const TIP_LINE := "F MARKS CARDS TO FUSE THEM IN ORDER"
const BAR_H := 10.0                                  # the selector's height (the duel's quit box uses the same band)
const ROW_X := 92.0
const ROW_W := 136.0
const ROW_Y0 := 104.0                                # the first row's line in the menu
const ROW_STEP := 16.0
static var tutorial_allowed := true     # the first-duel tutorial may open (the rule and capture scripts turn it off)
static var persist := true              # the seen flags are written to the settings file (capture scripts turn it off)

const MENU_ROWS := ["KEYBOARD", "MOUSE", "TOUCH", "CLOSE"]
const PAGES := [
	["A/D OR ARROWS   MOVE CURSOR", "W/S   MONSTER OR SPELL ROW", "E OR SPACE   CONFIRM", "Q, ESC OR BKSP   BACK",
			"F   MARK A CARD TO COMBINE", "R   SET FACE-DOWN OR POSITION", "T   CARD INFO", "ENTER   FIELD OR END TURN",
			"H OR TAB   THIS MENU", " ", "MARK CARDS IN ORDER, E PLAYS THEM"],
	["HOVER   MOVE CURSOR", "LEFT CLICK   CONFIRM", "RIGHT CLICK   BACK", "MIDDLE CLICK   MARK A CARD", "WHEEL   MOVE CURSOR"],
	["D-PAD   MOVE CURSOR", "CROSS   CONFIRM", "CIRCLE   BACK", "SQUARE   MARK A CARD", "TRIANGLE   SET OR POSITION",
			"START   FIELD OR END TURN", "SELECT   THIS MENU"],
]
const TUTORIAL := [
	"FIRST DUEL",
	" ",
	"DRAW  A CARD JOINS YOUR HAND",
	"HAND  E PLAYS, F MARKS TO FUSE",
	"FIELD  E ATTACK, R POSITION",
	"END TURN  ENTER WHEN DONE",
	" ",
	"H OR TAB OPENS THE CONTROLS",
	"PRESS ANY KEY TO START",
]


## Pulses the monsters that can attack: a soft gold outline that breathes in and out.
class Pulse extends Node2D:
	var rects: Array = []

	func _draw() -> void:
		for r in rects:
			draw_rect(r, Color(1.0, 0.85, 0.35, 0.9), false, 1.0)


## The COMBINE badges: a gold strip with its text, drawn in the picture's units.
class Tags extends Node2D:
	var items: Array = []     # {rect: Rect2, text: String}

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		for item in items:
			var r: Rect2 = item["rect"]
			draw_rect(r, Color(1.0, 0.85, 0.35), true)
			draw_string(font, Vector2(r.position.x, r.position.y + 7.0), str(item["text"]), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 7,
					Color(0.02, 0.03, 0.08))


## A stone dialog frame around a box of the picture (TextFrame cuts the story frame's panel into nine pieces).
class Dialog extends Node2D:
	var rect := Rect2()
	var tex: Texture2D = null

	func _draw() -> void:
		if tex != null:
			TextFrame.draw(self, tex, FRAME_SRC, rect, FRAME_BORDER)


var scene = null
var layer: Pulse                       # the attack pulse (in the picture, under the cursor)
var overlay: Node2D = null             # the open menu or tutorial; null when none is open
var overlay_kind := ""                 # "menu" or "tutorial"
var menu_page := -1                    # the menu: -1 the list, else the page's index in PAGES
var menu_cursor := 0                   # the menu: the selected row (the last row is CLOSE)
var refuse_text := ""
var refuse_left := 0.0
var tip_done := false                  # the fuse tip has been shown (or the player marked a card): it is not shown again
var tip_clock := 0.0
var tip_showing := false
var pulse_clock := 0.0
var frame_tex: Texture2D = null


## Adds the pulse layer above the board and the events.
func build(host) -> void:
	scene = host
	tip_done = _flag("fuse_tip_seen")
	layer = Pulse.new()
	host.world.add_child(layer)


## The first duel's tutorial: it opens once (the flag is kept in user://settings.cfg); any key or click closes it. Other duels, and the
## spectator and two-player duels, are not interrupted.
func begin(host) -> void:
	scene = host
	if not tutorial_allowed or host.spectator or host.two_player or _flag("tutorial_seen"):
		return
	_open("tutorial")


## The input of a frame. H, ? or Tab opens the menu; while the menu or the tutorial is open, up and down move its selector, confirm
## chooses, Esc, Q or Cancel backs out and H closes it. Returns true when the menu takes the frame, so the duel waits.
func frame(help_key: bool, up: bool, down: bool, confirm: bool, cancel: bool, pressed: bool) -> bool:
	if overlay != null:
		if overlay_kind == "tutorial":
			if pressed or help_key:
				_close()
			return true
		if help_key:
			_close()
		elif cancel:
			if menu_page >= 0:
				menu_page = -1
				_build_menu()
			else:
				_close()
		elif menu_page < 0:
			if up or down:
				menu_cursor = posmod(menu_cursor + (1 if down else -1), MENU_ROWS.size())
				_build_menu()
			elif confirm:
				if menu_cursor == MENU_ROWS.size() - 1:
					_close()
				else:
					menu_page = menu_cursor
					_build_menu()
		elif confirm:
			menu_page = -1
			_build_menu()
		return true
	if help_key:
		_open("menu")
		return true
	return false


## The mouse over the menu: hovering a row moves the selector to it (a click then chooses it, as the keys do).
func hover(local: Vector2) -> void:
	if overlay == null or overlay_kind != "menu" or menu_page >= 0:
		return
	for i in MENU_ROWS.size():
		if Rect2(ROW_X, ROW_Y0 + ROW_STEP * i - 2.0, ROW_W, BAR_H).has_point(local) and i != menu_cursor:
			menu_cursor = i
			_build_menu()
			return


## A refused action: the reason is said on the info line for a few seconds (the scene plays the cannot sound).
func refuse(reason: String) -> void:
	refuse_text = reason
	refuse_left = REFUSE_TIME


## The game's info line text this frame: a refusal, or the first-time fuse tip; "" when there is none (the scene draws the card then).
func info_line() -> String:
	if overlay != null:
		return ""
	if refuse_left > 0.0:
		return refuse_text
	if tip_showing:
		return TIP_LINE
	return ""


## Every physics frame: the refusal timer, the first-time tip, and the pulse.
func update(host) -> void:
	scene = host
	var dt := get_physics_process_delta_time()
	pulse_clock += dt
	refuse_left = maxf(refuse_left - dt, 0.0)
	_track_tip(host, dt)
	_pulse(host)


## Each refresh: the COMBINE badges on the marked hand cards and the fusion preview above the hand (the engine's resolve_chain).
func draw_hand(host) -> void:
	if host.mode != "hand" and host.mode != "dest":
		return                  # the marks wait for the hand's and the destination's modes; the field shows no badges
	var s = host.engine.state
	var hand: Array = s.sides[0].hand
	var tags := Tags.new()
	# the order badges are drawn by the scene (duel_scene.gd _draw_badges) once they are extracted; the text tags stand in until then
	for k in (host.marks.size() if host.hand_art.get("badges", []).is_empty() else 0):
		var i: int = int(host.marks[k])
		if i < 0 or i >= hand.size():
			continue
		var at: Vector2 = DuelHand.place(i) + Vector2(0, -10)
		tags.items.append({"rect": Rect2(at, Vector2(DuelHand.CARD_W, 9)), "text": "COMBINE %d" % (k + 1)})
	host.board.add_child(tags)
	var ids: Array = []
	if host.mode == "hand":
		for i in host.marks:
			if int(i) < hand.size():
				ids.append(int(hand[int(i)]))
		if ids.size() < 2:
			return
	else:
		var zone = s.sides[0].monsters[host.zone_index]
		if int(host.zone_row) == 0 and zone != null:
			ids.append(int(zone["id"]))          # a chain starts from the field monster the cursor is on
		for i in host.pending.get("picks", []):
			if int(i) < hand.size():
				ids.append(int(hand[int(i)]))
		if ids.size() < 2:
			return
	host._say(preview_text(host, ids), Vector2(14, 124), 2)


## The fusion preview of a chain (the ids in order): the fusion's result name, the equip's bonus, or the failed pairing's loss.
static func preview_text(host, ids: Array) -> String:
	var result: Dictionary = host.engine.resolve_chain(0, ids, 0)
	var events: Array = result["events"]
	for ev in events:
		if ev["kind"] == "fusion":
			return _clip("FUSION - " + _card_name(host, int(result["card"])))
	for ev in events:
		if ev["kind"] == "equip":
			return _clip("EQUIP - %s BONUS %d" % [_card_name(host, int(ev["equip"])), int(ev["bonus"])])
	return "NO FUSION - A CARD IS LOST"


## The reason an own monster cannot attack (empty when it can). The same words serve the refusal line.
static func attack_reason(engine, zone_index: int) -> String:
	var zone = engine.state.sides[0].monsters[zone_index]
	if zone == null:
		return "NO MONSTER IN THAT ZONE"
	if engine.attack_locked:
		return "NO ATTACKS ON THE FIRST TURN"
	if engine.state.sides[0].swords_turns > 0:
		return "SWORDS OF REVEALING LIGHT - NO ATTACK"
	if bool(zone["defense"]):
		return "THIS MONSTER IS IN DEFENCE"
	if bool(zone["used"]):
		return "THIS MONSTER ALREADY ATTACKED"
	return ""


## The reason an own monster cannot change position (empty when it can).
static func change_reason(engine, zone_index: int) -> String:
	var zone = engine.state.sides[0].monsters[zone_index]
	if zone == null:
		return "NO MONSTER IN THAT ZONE"
	if bool(zone["used"]):
		return "THIS MONSTER ALREADY ATTACKED"
	return ""


static func _clip(text: String) -> String:
	return text.substr(0, 34)


static func _card_name(host, id: int) -> String:
	return str(host.data.card(id).get("name", "")).to_upper()


func _track_tip(host, dt: float) -> void:
	tip_showing = false
	if tip_done or host.spectator or overlay != null:
		return
	if host.mode == "hand" and host.marks.is_empty():
		tip_clock += dt
		if tip_clock >= TIP_TIME:
			_seen_tip()
		else:
			tip_showing = true
	elif not host.marks.is_empty():
		_seen_tip()


func _seen_tip() -> void:
	tip_done = true
	_set_flag("fuse_tip_seen")


## The pulse: the own monsters that can attack are outlined in gold, breathing softly, while the field cursor is on the monster row.
func _pulse(host) -> void:
	var rects: Array = []
	if host.mode == "field" and int(host.zone_row) == 0 and host.field != null and overlay == null:
		for i in 5:
			if host.engine.can_attack(0, i):
				rects.append(host.field.card_box(host._record(0, "monsters", i)).grow(2.0))
	layer.rects = rects
	layer.modulate = Color(1, 1, 1, 0.55 + 0.45 * sin(pulse_clock * TAU / 1.2))
	layer.queue_redraw()


func _open(kind: String) -> void:
	_close()
	overlay_kind = kind
	menu_page = -1
	menu_cursor = 0
	overlay = Node2D.new()
	scene.world.add_child(overlay)
	if kind == "tutorial":
		_build_tutorial()
	else:
		_build_menu()


func _close() -> void:
	if overlay == null:
		return
	if overlay_kind == "tutorial":
		_set_flag("tutorial_seen")
	overlay.queue_free()
	overlay = null
	overlay_kind = ""


## The menu in the game's frame: the list of rows with the selector on the chosen one, or a page of its controls.
func _build_menu() -> void:
	_clear_overlay()
	if menu_page < 0:
		var box := Rect2(80, 74, 160, 16 + ROW_STEP * MENU_ROWS.size() + 12)
		_frame(box)
		_text("CONTROLS", Vector2(box.position.x + 12, box.position.y + 6))
		_selector(menu_cursor)
		for i in MENU_ROWS.size():
			_text(MENU_ROWS[i], Vector2(ROW_X + 8, ROW_Y0 + ROW_STEP * i - 2.0))
		return
	var lines: Array = PAGES[menu_page]
	var height := (lines.size() + 3) * 12 + 14
	var pbox := Rect2(16, (240 - height) * 0.5, 288, height)
	_frame(pbox)
	_text(MENU_ROWS[menu_page], pbox.position + Vector2(10, 7))
	for i in lines.size():
		_text(lines[i], pbox.position + Vector2(10, 7 + 12 * (i + 2)))
	_text("Q OR ESC   BACK", pbox.position + Vector2(10, 7 + 12 * (lines.size() + 2)))


func _build_tutorial() -> void:
	var height := TUTORIAL.size() * 12 + 14
	var box := Rect2(16, (240 - height) * 0.5, 288, height)
	_frame(box)
	for i in TUTORIAL.size():
		_text(TUTORIAL[i], box.position + Vector2(10, 7 + 12 * i))


func _clear_overlay() -> void:
	for child in overlay.get_children():
		overlay.remove_child(child)
		child.queue_free()
	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.5)
	shade.size = Vector2(320, 240)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(shade)


func _frame(box: Rect2) -> void:
	var frame := Dialog.new()
	frame.rect = box.grow(8)
	frame.tex = _frame_texture()
	overlay.add_child(frame)


## The selector: the duel's yellow choice bar (the same additive band the quit box uses) behind row i.
func _selector(i: int) -> void:
	var bar := Polygon2D.new()
	var top := ROW_Y0 + ROW_STEP * i - 2.0
	bar.polygon = PackedVector2Array([Vector2(ROW_X, top), Vector2(ROW_X + ROW_W, top), Vector2(ROW_X + ROW_W, top + BAR_H),
			Vector2(ROW_X, top + BAR_H)])
	bar.vertex_colors = PackedColorArray([Color(0.19, 0.19, 0.0), Color(0.75, 0.75, 0.0), Color(0.75, 0.75, 0.0), Color(0.19, 0.19, 0.0)])
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bar.material = add
	overlay.add_child(bar)


func _text(value: String, at: Vector2) -> void:
	scene.text.layout(overlay, scene._bytes(value), at, Vector2(8, 12), 0, scene.sharp, true)


func _frame_texture() -> Texture2D:
	if frame_tex == null:
		var image := Image.load_from_file(FRAME_PATH)
		if image != null:
			frame_tex = ImageTexture.create_from_image(image)
	return frame_tex


func _flag(key: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return false
	return bool(cfg.get_value(SETTINGS_SECTION, key, false))


func _set_flag(key: String) -> void:
	if not persist:
		return
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)         # the other sections of the file are kept
	cfg.set_value(SETTINGS_SECTION, key, true)
	cfg.save(SETTINGS_PATH)
