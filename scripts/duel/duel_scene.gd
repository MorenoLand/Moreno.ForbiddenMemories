extends Control
## A duel on the game's 3D field (duel_field_3d.gd: the terrain's board and the camera of the turn side, the cards on their grid
## slots), with the hand under it, the life-point and deck readouts, and the hovered card's stats in the game's small font.
## Drives DuelEngine; the opponent's turns are played by DuelAi.
## Controls: A/D or left/right move, E/Space/Enter-less confirm, F marks a hand card for a chain, R sets a monster face-down in
## defence (placing) or changes position (field), Enter ends the turn, Q/Esc/Backspace cancels. H, ? or Tab opens the controls
## menu (duel_help.gd).
## Emits finished(winner_side) when the duel is decided and the result has been acknowledged.

signal finished(winner: int)
signal sound(effect: int)
signal music(id: int)
signal music_fade(step: int)
var outcome: Dictionary = {}   # the result screen's result (DuelResult.evaluate) and the cards the player used; set when finished

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const CardDB := preload("res://scripts/data/card_db.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const DuelData := preload("res://scripts/duel/duel_data.gd")
const DuelEngine := preload("res://scripts/duel/duel_engine.gd")
const Ai := preload("res://scripts/duel/duel_ai.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const DuelResult := preload("res://scripts/duel/duel_result.gd")
const DuelField := preload("res://scripts/duel/duel_field_3d.gd")
const CardViewScript := preload("res://scripts/ui/card_view.gd")
const DuelCardFace := preload("res://scripts/duel/duel_card_face.gd")
const DuelFx := preload("res://scripts/duel/duel_fx.gd")
const DuelHud := preload("res://scripts/duel/duel_hud.gd")
const DuelFinale := preload("res://scripts/duel/duel_finale.gd")
const DuelHand := preload("res://scripts/duel/duel_hand.gd")
const DuelPrompt := preload("res://scripts/duel/duel_prompt.gd")
const DuelSpectator := preload("res://scripts/duel/duel_spectator.gd")
const DuelQuit := preload("res://scripts/duel/duel_quit.gd")
const DuelHelp := preload("res://scripts/duel/duel_help.gd")

const INFO_Y := 208
const BAR_BOX := Rect2(16, 210, 288, 64)  # the hovered card's box at the picture's foot
const TextFrame := preload("res://scripts/ui/text_frame.gd")
const BAR_FRAME_SOURCE := Rect2(0, 152, 320, 88)   # the dialog frame's panel in the story frame picture (build_deck.gd's DIALOG_FRAME_SOURCE)
const BAR_FRAME_BORDER := Vector4(8, 8, 8, 8)     # its stone border, in source pixels
const BAR_FRAME_OUTSIDE := 8.0                    # the frame is drawn around the box, its border outside the box
var bar_frame_texture: Texture2D = null
const BAR_TEXT := Vector2(16, 210)        # the bar box's text origin: the name's glyph cells at y 212 (the reference's bar text, decoded from its prim trace)
const SYMBOLS := {" ": 0, "<": 84, ">": 81, "/": 68, ".": 11, "'": 27, ",": 31, "-": 48, "#": 60, "&": 67, ":": 0}
## The computer's pacing, in frames (one per vblank, the reference's timeline: the phase dwells of the original's turn). The turn's
## first action waits out the draw phase and its resolution (FOE_DRAW: phases 2 and 3, 16 and 64 frames); then each action waits
## its own dwell from the visible action before it (_foe_gap). A play is the hand phase (120 frames) and the placement's phase
## (32), the card shows about 166 frames after the draw; an attack follows the field phase (80 frames); an end after an attack
## follows the battle's presentation (272 frames) and the field phase's 48.
const FOE_DRAW := 80
const FOE_PLAY_WAIT := 166
const FOE_ATTACK_WAIT := 122
const FOE_END_WAIT := 122
const FOE_END_AFTER_ATTACK := 320
const FOE_DEFENSE_WAIT := 40
const FOE_EQUIP_WAIT := 122

var data := DuelData.new()
var cards := CardDB.new()
var text := GameText.new()
var engine
var opponent_id := 0
var terrain := 0              # the field terrain the duel opens with (campaign duels set it)
var engine_seed := 0          # the engine's random seed (0: random); the soak test sets it to replay a duel
var world := Node2D.new()
var board := Node2D.new()
var field = null             # the 3D board and cards (duel_field_3d.gd)
var fx = null                # the presentation of the events: battle, traps, magic windows (duel_fx.gd)
const FIELD_VIEW_FRAMES := 16   # the field view's tween (duel_field_3d.gd VIEW_FRAMES): the view back after a battle
var card_backs: Dictionary = {}
var hud := Node2D.new()             # the readouts: life points, deck counts, the turn panels and the card's icons, drawn every frame
var shown_life: Array = [-1, -1]    # the life points each side's readout shows (the readout steps toward the real total)
var panel_share := 0.0              # the battle's slide of the FIELD box (left) and the life-point panel (right): 0 at rest, 1 off the picture
var panel_target := 0.0
var panel_from := 0.0
var panel_left := 0                 # frames left in the slide
var slide_field := 0.0              # the FIELD box's x offset from its rest place (12), in pixels: the battle's slide or a result slide
var slide_lp := 0.0                 # the life-point panel's x offset from its rest place (280), in pixels
var slide_plan: Dictionary = {}     # a result slide in progress (slide_panels): the x positions it goes from and to, and its angle
var slide_held := false             # a result slide has run: from then on the battle's slide does not move the panels
var sprites: Dictionary = {}        # path -> art record {texture, scale} (mod_art.gd)
var sharp: ShaderMaterial
var glyph_codes: Dictionary = {}
var thumb_images: Dictionary = {}     # card id -> the thumbnail at its baked size (see _thumb_base)
var mode := "hand"            # hand, dest, star, field, target, foe, over
var hand_index := 0
var marks: Array = []         # hand indices in pick order
var zone_index := 0
var zone_row := 0             # the field cursor's row: 0 the monster row, 1 the magic and trap row (own side); see duel_prompt.gd
var prompt_choice := 0        # the activation prompt's choice: 0 YES (the left label, where the cursor starts), 1 NO
var attacker := -1
var set_down := false
var star_choice := 0
var star_id := 0             # the monster whose guardian star is asked (the placement is done, the box shows it)
var star_zone := -1            # its zone; -1 when no star is asked
var pending: Dictionary = {}  # the chain waiting for its destination / star
var timer := 0
var held: Dictionary = {}
var mouse_pending: Dictionary = {}   # "confirm", "cancel" and "mark" from the mouse, taken once a frame
var wheel_steps := 0                 # wheel notches in the hand and zone modes: negative is left, positive right; one step each
const WHEEL_MODES := ["hand", "dest", "field", "target", "equip_pick"]   # the modes whose cursor the wheel moves
var ready_ok := false
var message := ""
var viewer := false           # the card viewer (Triangle or T, or a tap on a hand card): the hovered card's picture and text over black
var viewer_view = null              # the viewer's text box (CardView, built for the card shown)
var viewer_card_ui: Dictionary = CardViewScript.load_ui()   # the card_ui pieces' layout (the picture's stats and labels)
var viewer_pictures: Dictionary = {}   # "id:atk:def" -> the card viewer's picture (CardView.card_picture)
var foe_ai
var two_player := false              # the hot-seat duel (2P DUEL): side 1 is a second person, there is no AI
var life_points: Array = [8000, 8000]  # two-player: each side's starting life points (the setup's values)
var second_deck: Array = []          # two-player: player 2's deck
var flipped := false                 # two-player: the sides are swapped in the engine while player 2 has the turn, so the side to act is 0
## The deal: cards entering the hand one at a time (the draw resolution state: one card every 8 frames, each sliding in from the deck
## over 12 frames). deal_base is the hand index of the first card dealt, deal_total the number dealt, deal_started how many have
## begun, and deal_clock counts frames from the deal's start (negative while the opening sweep or the turn swing runs first).
const DEAL_INTERVAL := 8
const DEAL_SLIDE := 12
const INTRO_WAIT := 300              # the opening sweep's frames before the first card is dealt
const TURN_WAIT := 48                # the turn swing's frames before a drawn card is dealt
const TURN_FRAMES := 48              # the turn swing (the turn switch state's 48 frames)
const FADE_FRAMES := 32              # the opening fade: the step of 8 over the 256 levels
var deal_base := 0
var deal_total := 0
var deal_started := 0
var deal_clock := 0
var deal_active := false
var fade_left := 0
var fade_rect: ColorRect
var finale = null                   # the ending of a decided duel (duel_finale.gd), while it plays
var spectator := false              # F3 (duel_spectator.gd): an AI v AI match; side 0 is the computer too, and the player has no input but Esc
var spectator_ids: Array = []       # spectator: the duelists of side 0 and side 1
var spectator_decks: Array = []     # spectator: whose deck each side plays (Duel Master K plays another duelist's)
var spectator_ai = null             # spectator: side 0's computer opponent (foe_ai plays side 1)
var spectator_over := false         # spectator: the match is decided and waits for its confirm
var spectator_done := false         # spectator: the match has been left (the quit or the confirm); it is not run again
var quit_box = null                 # spectator: the quit confirm (duel_quit.gd) while it is open
var help = null                     # the controls help: the pulse, the tutorial and the controls menu (duel_help.gd)
var foe_actions := 0                # spectator: the computer's actions this turn (duel_spectator.gd's FOE_ACTION_LIMIT)
var foe_next: Dictionary = {}       # the computer's next action, decided ahead of its wait (_foe_decide)
var foe_due := 0                    # the timer's count at which foe_next is performed
var foe_clock := 0                  # the frames since the computer's turn began (its hand is dealt over the first frames)
var foe_prev := ""                  # the kind of the computer's last visible action this turn ("" at the turn's start)

## The baked cursors (tools/extract.py bake_duel_cursors): the zone cursor's streams and the hand's pointer and order badges.
const FIELD_ART := "res://assets/screens/duel_field/"
const HAND_ART := "res://assets/screens/duel_hand/"
const HAND_LIFT := 4.0                    # a marked hand card rises 4 pixels (the order mark)
const POINTER_Y := 194.0                  # the hand pointer's row: its origin is (slot * 60 + 14, 194)
const ZONE_ORIGIN := Vector2(32, 30)      # the zone cursor's origin, 32 left and 30 up from the zone's point
const STAR_BOX := Rect2(72, 110, 176, 48)  # the guardian star box: a flagged text box at (0x48, 0x6E), 0xB0 x 0x30
const STAR_CARD_AT := Vector2(134, 42)    # where the placed card waits while the box is open (0x86, 0x2A)
var zone_art: Dictionary = {}             # zone_cursor.json's streams: "0" to "7" (the zone cursor's frames and play order)
var hand_art: Dictionary = {}             # hand/layout.json: "pointer" (a stream) and "badges" (one picture per pick)
var anim_tick := 0                        # the cursors' animation clock (one a physics frame)
var zone_sprite: Sprite2D = null          # the zone cursor on the board, animated by _animate_cursors
var zone_track := {}                      # its stream and origin
var pointer_sprite: Sprite2D = null       # the hand pointer on the board
var pointer_track := {}

## The single-card centre step (the hand actions' case 3): a monster or trap with no marks moves to the board's centre and
## its face is chosen with left (face-down, set) or right (face-up, the arrow label); confirm sends it back to its hand slot and on to the
## destination, cancel returns it to the hand. The positions and frames are the hand action's (0x86, 0x5A), 0x1E below for the labels.
const CENTRE_MODES := ["centre", "centre_back"]
const CENTRE_AT := Vector2(134, 90)
const CENTRE_FRAMES := 12                 # the move's frames: the interpolation step of 0xAA to 0x800 is about this many
const PASSWORD_ART := "res://assets/screens/password/"    # the direction arrows (the pack shop's, the same disc stream as the labels)
var centre_face_down := true              # the chosen face: a monster or trap starts flipped to its back (set)
var centre_clock := 0
var arrow_art: Dictionary = {}            # the right label's arrow stream (password/layout.json's arrows[0])
var arrow_left_art: Dictionary = {}       # the left label's arrow stream (arrows[2])


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not data.load_all() or not text.load_all() or not cards.load_all():
		return
	for i in text.glyphs.size():
		var sjis := int(text.glyphs[i]["sjis"])
		if not glyph_codes.has(sjis):
			glyph_codes[sjis] = i
	sharp = ScreenFit.make_material()
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(world)
	add_to_group("fit")
	var black := ColorRect.new()
	black.color = Color(0.0, 0.0, 0.0)     # the original's surround is pure black above and around the board
	black.size = Vector2(320, 240)
	world.add_child(black)
	field = DuelField.new()
	if not field.setup(self, world, sharp, terrain):
		push_error("duel field: the board is not baked (run tools/extract.py --screens)")
		field = null
	world.add_child(hud)        # the readouts go under the board, so the card panel and the field's cards draw over them
	world.add_child(board)
	fx = DuelFx.new()
	fx.setup(self, field, sharp)
	world.add_child(fx)         # above the board: the events' presentation
	help = DuelHelp.new()
	add_child(help)
	help.build(self)            # the attack pulse layer (duel_help.gd)
	engine = DuelEngine.new(data, engine_seed)
	var foe_deck: Array
	if two_player:
		foe_deck = second_deck.duplicate()
	elif spectator:
		foe_deck = DuelSpectator.deck_of(data, engine, spectator_decks[1])
	elif opponent_id == 39:
		foe_deck = GameState.deck.duplicate()      # Duel Master K is dealt the player's own deck
	elif not data.fixed_deck(opponent_id).is_empty():
		foe_deck = data.fixed_deck(opponent_id)    # a mod's fixed deck (duel_data.gd)
	else:
		foe_deck = engine.build_pool_deck(data.duelists[opponent_id]["deck"])
	var mine: Array = GameState.deck.duplicate() if not spectator else DuelSpectator.deck_of(data, engine, spectator_decks[0])
	if mine.is_empty():
		mine = data.deal_starter_deck(engine.rng)
	engine.start(mine, foe_deck, terrain)
	if two_player:
		for i in 2:
			engine.state.sides[i].lp = life_points[i]
			engine.state.sides[i].max_lp = life_points[i]
	else:
		foe_ai = Ai.new(engine, spectator_ids[1] if spectator else opponent_id)
		if spectator:
			spectator_ai = Ai.new(engine, spectator_ids[0])
			world.add_child(DuelSpectator.tag())
	if field != null:
		field.open_intro()          # the opening sweep (the startup state: the camera swings in over 300 frames)
	_begin_turn(0)
	# the opening: the five cards are dealt into the hand one at a time once the sweep has run (the startup, then the draw resolution)
	_start_deal(0, engine.state.sides[0].hand.size(), -INTRO_WAIT)
	help.begin(self)            # the first duel's tutorial (once; duel_help.gd keeps the flag in user://settings.cfg)
	fade_rect = ColorRect.new()
	fade_rect.color = Color(0.0, 0.0, 0.0, 1.0)
	fade_rect.position = Vector2.ZERO
	fade_rect.size = Vector2(320, 240)
	fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world.add_child(fade_rect)  # the opening fade-in (the fade's banded step of 8 over 32 frames), drawn over everything
	fade_left = FADE_FRAMES
	get_viewport().size_changed.connect(refit)
	refit()

	ScreenFit.pass_mouse(self)
	ready_ok = true


func refit() -> void:
	ScreenFit.apply(world, size)
	if field != null:
		# the 3D board is drawn at the window's resolution (whole multiples of the picture, up to 4), so its edges are not blown up
		field.set_view_scale(int(ceil(size.y / 240.0)))


# ---- text ------------------------------------------------------------------------------------------------------------

func _bytes(string: String) -> Array:
	var out: Array = []
	for c in string:
		if SYMBOLS.has(c):
			out.append(SYMBOLS[c])
			continue
		var code := c.unicode_at(0)
		var sjis := 0
		if code >= 97 and code <= 122:
			sjis = 0x8281 + code - 97
		elif code >= 65 and code <= 90:
			sjis = 0x8260 + code - 65
		elif code >= 48 and code <= 57:
			sjis = 0x824F + code - 48
		out.append(glyph_codes.get(sjis, 0))
	return out


func _say(string: String, at: Vector2, ramp := 0) -> void:
	text.layout(board, _bytes(string), at, Vector2(8, 12), ramp, sharp, true)


## The thumbnail at its baked (1x) size as an image: the card's face is composed from its pixels (duel_card_face.gd), so it is never the
## HD copy (ModArt.base_image), and the face is the same with the HD art on or off.
func _thumb_base(id: int) -> Image:
	if not thumb_images.has(id):
		thumb_images[id] = ModArt.base_image(cards.thumbnail_path(id))
	return thumb_images[id]


## The face of a card on the 3D field, composed by duel_card_face.gd the way the game lays out a card: the frame of its kind, the
## 40 x 32 picture at (6, 6), and a monster's ATK and DEF or a spell's label. The field quad maps the whole 52 x 60 face.
func _field_face(id: int, cell: Dictionary, row: String) -> Texture2D:
	var kind := DuelCardFace.kind_of(str(data.card(id).get("type", "")))
	var monster := kind == "monster"
	var s = engine.state
	return DuelCardFace.face(kind, _thumb_base(id), s.atk(cell) if monster else 0, s.def(cell) if monster else 0, cards.thumbnail_path(id))


## The face of a card in the hand: the same 52 x 60 face as the field (duel_card_face.gd), with a monster's base ATK and DEF.
func _hand_face(id: int) -> Texture2D:
	var c: Dictionary = data.card(id)
	var kind := DuelCardFace.kind_of(str(c.get("type", "")))
	var monster := kind == "monster"
	return DuelCardFace.face(kind, _thumb_base(id), int(c.get("attack", 0)) if monster else 0, int(c.get("defense", 0)) if monster else 0, cards.thumbnail_path(id))


# ---- drawing ---------------------------------------------------------------------------------------------------------

func _clear() -> void:
	for child in board.get_children():
		board.remove_child(child)
		child.queue_free()


func _rect(at: Vector2, size_: Vector2, color: Color, fill := false) -> void:
	var r := ColorRect.new()
	r.position = at
	r.size = size_
	r.color = color
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not fill:
		# an outline: four thin bars
		var t := 1.0
		for bar in [Rect2(at, Vector2(size_.x, t)), Rect2(at + Vector2(0, size_.y - t), Vector2(size_.x, t)),
				Rect2(at, Vector2(t, size_.y)), Rect2(at + Vector2(size_.x - t, 0), Vector2(t, size_.y))]:
			var b := ColorRect.new()
			b.position = bar.position
			b.size = bar.size
			b.color = color
			b.mouse_filter = Control.MOUSE_FILTER_IGNORE
			board.add_child(b)
		r.queue_free()
		return
	board.add_child(r)


## The card record of a side's zone (the grid's records of the scene setup's tables): the player's monsters are 5 to 9 and traps
## 10 to 14, the foe's monsters 20 to 24 and traps 25 to 29. The field is drawn by duel_field_3d.gd from these.
func _record(side: int, row: String, i: int) -> int:
	return (5 if side == 0 else 20) + (0 if row == "monsters" else 5) + i


## The back of a face-down card: the card's back, baked from the card frame's window (duel_card/back_<kind>.png).
func _back(id: int, _row: String) -> Texture2D:
	return DuelCardFace.back(DuelCardFace.kind_of(str(data.card(id).get("type", ""))))


## The cards on the board: each side's monsters and traps, with the record of its grid slot.
func _field_cards() -> Array:
	var out: Array = []
	var s = engine.state
	for side in 2:
		for i in 5:
			for row in ["monsters", "traps"]:
				var cell = s.sides[side].monsters[i] if row == "monsters" else s.sides[side].traps[i]
				if cell == null:
					continue
				out.append({"record": _record(side, row, i), "texture": _field_face(int(cell["id"]), cell, row), "back": _centre_face(int(cell["id"]), int(cell.get("slot", 0))) if side == 0 else _back(int(cell["id"]), row),
						"face_down": bool(cell.get("face_down", false)), "defense": bool(cell.get("defense", false)),
						"foe": side == 1})
	return out


## The computer's hand during its turn, until its first action: its cards in the hand's places, one dealt every FOE_DEAL frames from the
## turn's start (the reference's computer draw: the backs come in over the first 40 frames), then they leave the picture.
const FOE_DEAL := 8
func _draw_foe_hand() -> void:
	var hand: Array = engine.state.sides[engine.state.turn_side].hand
	for i in hand.size():
		if foe_clock < FOE_DEAL * (i + 1):
			break
		board.add_child(DuelHand.face(DuelCardFace.foe_hand(), DuelHand.place(i), sharp))


## The camera follows the cursor: the view's reference point moves to the row of the zone the cursor is on.
func _focus_camera(frames := 8) -> void:
	if fx != null and (fx.battle_view or fx.view_hold):
		return                      # the battle's view (duel_fx.gd): the hand view until the battle's presentation has played, or the pan to a trap
	field.show_near(mode in ["dest", "field", "target", "equip_pick", "prompt"])   # the field view while a monster cursor is on the board, the hand view otherwise
	match mode:
		"dest", "field", "equip_pick", "prompt":
			field.focus(0, _record(0, _cursor_row(), zone_index), frames)
		"target":
			field.focus(0, _record(1, "monsters", zone_index), frames)


## The battle's view ends (duel_fx.gd): the field view comes back to the cursor's row over the field view's frames.
func end_battle_view() -> void:
	_focus_camera(FIELD_VIEW_FRAMES)


## The row of the field cursor's card records: the magic and trap row when the cursor is on it (field and prompt), else the monsters.
func _cursor_row() -> String:
	return "traps" if zone_row == 1 and mode in ["field", "prompt", "dest"] else "monsters"


## The zone (0 to 4) of a side's monster under a point of the picture, or -1: the card's box on the board as it is drawn now.
func _monster_at(local: Vector2, side: int) -> int:
	if field == null:
		return -1
	for i in 5:
		if field.card_box(_record(side, "monsters", i)).grow(3.0).has_point(local):
			return i
	return -1


## The zone (0 to 4) of an own magic and trap card under a point of the picture, or -1.
func _trap_at(local: Vector2) -> int:
	if field == null:
		return -1
	for i in 5:
		if field.card_box(_record(0, "traps", i)).grow(3.0).has_point(local):
			return i
	return -1


func refresh() -> void:
	_clear()
	if field != null:
		field.set_shown(not _viewer_up())   # the card viewer's screen is black: the board and the readouts are off while it is up
	hud.visible = not _viewer_up()
	if _viewer_up():
		var shown := _hovered_card()
		if shown != 0:
			_draw_panel(shown)
		return
	_draw_band()                # the information band first: the hand and the text draw over it (the duel frame's draw list)
	var s = engine.state
	var hand: Array = s.sides[0].hand
	var foe_turn := mode == "foe"                # the computer's turn: the player's hand leaves the picture (the reference's field view)
	# the field view (a monster cursor on the board, or the equip's target): the hand is off the picture there too (reference frames
	# of the placed monster and of the field phase show no hand; the hand shows in the hand phase only)
	var field_view := mode == "field" or mode == "equip_pick" or mode == "star"     # the guardian star box is asked in the field view
	for i in (0 if foe_turn or field_view or (fx != null and fx.hides_hand()) else hand.size()):
		var at: Vector2 = DuelHand.place(i)
		if mode in CENTRE_MODES and i == hand_index:
			continue                    # the centred card is drawn by _draw_centre, away from its slot
		if deal_active and i >= deal_base and i < deal_base + deal_total:
			var j := i - deal_base
			if j >= deal_started:
				continue                # not dealt yet: the card is still in the deck
			var age := deal_clock - DEAL_INTERVAL * j
			if age < DEAL_SLIDE:
				# the draw slide (duel_hand.gd): from a screen width to the right of its place, on the draw slide's sine ease
				at = DuelHand.slide_position(i, float(age) / float(DEAL_SLIDE))
		if marks.has(i):
			at.y -= HAND_LIFT           # a marked card rises (its order mark is on it)
		# the chosen card in its slot while it is placed: its back with the number (the reference shows it face-down)
		var shown: Texture2D = _centre_face(int(hand[i]), DuelEngine.hand_slot(s.sides[0], i)) if (mode == "dest" and i == hand_index) else _hand_card_face(int(hand[i]), DuelEngine.hand_slot(s.sides[0], i))
		board.add_child(DuelHand.face(shown, at, sharp))
	if foe_turn and foe_actions == 0:
		_draw_foe_hand()            # the computer's hand shows until its first action (its cards leave the picture as they are played)
	_draw_badges(hand)
	_draw_centre(hand)
	# the terrain name is on the field plate (duel_field_3d.gd), not a text label
	if field != null:
		field.set_cards(fx.shown(_field_cards()))
		_focus_camera()
	_draw_cursor()
	if mode == "prompt":
		_draw_prompt()
	_mark_used()
	if mode == "star":
		_draw_star_prompt()
	else:
		_draw_info()
	if not (fx != null and fx.hides_hand()):
		help.draw_hand(self)    # the COMBINE badges on the marked cards and the fusion preview above the hand, over the hover panel (duel_help.gd)


## The eligibility mark: an own monster that has already acted this turn is covered dark on the board (duel_hud.gd).
func _mark_used() -> void:
	if field == null:
		return
	for i in 5:
		var z = engine.state.sides[0].monsters[i]
		if z != null and bool(z.get("used", false)) and not bool(z.get("face_down", false)):
			DuelHud.dim_box(board, field.card_box(_record(0, "monsters", i)))


func _cursor_rect() -> Rect2:
	match mode:
		"hand":
			return DuelHand.box(hand_index).grow(3.0)
		"dest", "field", "target", "equip_pick", "prompt":
			if field == null:
				return Rect2()
			var side := 1 if mode == "target" else 0
			var row := "monsters" if mode == "target" else _cursor_row()
			return field.card_box(_record(side, row, zone_index)).grow(3.0)
	return Rect2()


func _draw_cursor() -> void:
	if _draw_art_cursor():
		return
	var r := _cursor_rect()
	if r.size != Vector2.ZERO:
		_rect(r.position, r.size, Color(1.0, 0.9, 0.2))


## The baked cursors: the hand's red pointer under the hand slot (the hand mode) and the zone cursor over the zone the field cursor is on
## (the field, destination, target and prompt modes). Returns false when the art is not extracted, so the outline above stands in.
func _draw_art_cursor() -> bool:
	_load_cursor_art()
	zone_sprite = null
	pointer_sprite = null
	if mode == "hand" and not hand_art.is_empty() and engine.state.sides[0].hand.size() > 0:
		pointer_sprite = _hand_pointer(hand_index)
		return pointer_sprite.texture != null
	if mode == "dest" and not hand_art.is_empty() and engine.state.sides[0].hand.size() > 0:
		# the chosen card stays in its slot while it is placed: the red pointer keeps its place under the slot (the reference's draw list)
		_hand_pointer(hand_index)
	if field == null or zone_art.is_empty() or not (mode in ["dest", "field", "target", "equip_pick", "prompt"]):
		return false
	var side := 1 if mode == "target" else 0
	var row := "monsters" if mode == "target" else _cursor_row()
	var record := _record(side, row, zone_index)
	var k := side * 4                       # the table index plus 4 for the foe (the zone cursor's streams 0 to 3 and 4 to 7)
	var entry: Dictionary = zone_art.get(str(k), {})
	var origin: Vector2 = field.cell_point(record) - ZONE_ORIGIN
	zone_track = {"entry": entry, "folder": FIELD_ART, "at": origin}
	zone_sprite = _cursor_sprite(FIELD_ART, _stream_frame(entry, anim_tick), origin)
	return zone_sprite.texture != null


## The order badges on the marked hand cards: badge n (1 to 5) on the card of the n-th pick, on the card's lifted place. Shown in the
## hand and the destination modes, where the picks are still marked (the same modes as the COMBINE tags).
func _draw_badges(hand: Array) -> void:
	_load_cursor_art()
	if mode != "hand" and mode != "dest":
		return
	var badges: Array = hand_art.get("badges", [])
	for k in marks.size():
		var i := int(marks[k])
		if i < 0 or i >= hand.size() or k >= badges.size():
			continue
		var at := DuelHand.place(i) + Vector2(0, -HAND_LIFT)
		_cursor_sprite(HAND_ART, badges[k], at)


## The guardian star choice (the placement state's box, string 0x21): the placed card waits at the box's top centre, and the box's
## panel, the heading, the two star rows and the choice bar follow the text box's own geometry (the box is 176 x 48, the rows 16 apart).
func _draw_star_prompt() -> void:
	var card: Dictionary = data.card(star_id)
	var X := STAR_BOX.position.x
	var Y := STAR_BOX.position.y
	var W := STAR_BOX.size.x
	var H := STAR_BOX.size.y
	# the panel: the six-point outline of the translucent panel (8 out at the top and bottom corners' sides, half height at the sides), the average
	# blend of a 0xA0 grey: half the board and half grey
	var panel := Polygon2D.new()
	panel.polygon = PackedVector2Array([Vector2(X, Y - 8), Vector2(X + W, Y - 8), Vector2(X + W + 8, Y + H / 2), Vector2(X + W, Y + H + 8),
			Vector2(X, Y + H + 8), Vector2(X - 8, Y + H / 2)])
	panel.color = Color(0.627, 0.627, 0.627, 0.5)
	board.add_child(panel)
	# the placed card at the box's top centre
	board.add_child(DuelHand.face(_hand_face(star_id), STAR_CARD_AT, sharp))
	_say("SELECT A GUARDIAN STAR", Vector2(X, Y))
	# the choice bar: the chosen row's band, 16 tall across the box (the original's highlight choice routine, the yellow additive band with darker edges)
	var top := Y + 16.0 + 16.0 * star_choice
	var bar := Polygon2D.new()
	bar.polygon = PackedVector2Array([Vector2(X, top), Vector2(X + W, top), Vector2(X + W, top + 16.0), Vector2(X, top + 16.0)])
	bar.vertex_colors = PackedColorArray([Color(0.19, 0.19, 0.0), Color(0.75, 0.75, 0.0), Color(0.75, 0.75, 0.0), Color(0.19, 0.19, 0.0)])
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bar.material = add
	board.add_child(bar)
	# the rows: the star's symbol (one 8-pixel cell, the baked star picture at half size), a space, then its name in capitals
	for k in 2:
		var name := str(card.get("guardian_star_%d" % (k + 1), ""))
		var at := Vector2(X, Y + 16.0 + 16.0 * k)
		# the symbol is the baked 16 x 16 icon of the star (star_icons/, the text's icon entry), drawn at full size; a star 0 has none
		if name != "":
			var icon := _tex(STAR_ICONS + "%s.png" % name.to_lower())
			if icon != null:
				var symbol := Sprite2D.new()
				symbol.texture = icon
				symbol.centered = false
				symbol.position = at
				symbol.material = sharp
				board.add_child(symbol)
		text.layout(board, _bytes(name.to_upper()), at + Vector2(16, 0), Vector2(8, 12), 0, sharp, true)


## The centre step: a monster or trap with no marks is moved to the centre and its face is chosen (the hand action's case 3). The card
## starts flipped to its back (set), left sets it, right turns it face-up under the arrow label (the picture's own offsets).
## Whether the card under the hand cursor takes the centre step: a monster or a trap (a magic, ritual or equip has no face to choose).
func _centre_card() -> bool:
	var id := int(engine.state.sides[0].hand[hand_index])
	return engine.state.is_monster(id) or engine.state.card_type(id) in ["Trap", "Magic", "Ritual", "Equip"]


func _enter_centre() -> void:
	mode = "centre"
	centre_clock = 0
	centre_face_down = true
	sound.emit(0x2F)


## Confirm in the centre step: the chosen face is the placement's, the card goes back to its hand slot, then the destination is chosen.
func _centre_confirm() -> void:
	set_down = centre_face_down
	var kind: String = engine.state.card_type(int(engine.state.sides[0].hand[hand_index]))
	if not set_down and kind in ["Magic", "Ritual", "Equip"]:
		# a face-up magic, ritual or equip leaves from the centre: it resolves there (the card-use sequence) or goes on to its monster
		sound.emit(7)
		_lift()
		return
	mode = "centre_back"
	centre_clock = 0
	sound.emit(7)


## The centred card: it moves from its hand slot to the centre (cosine ease over CENTRE_FRAMES), and back in centre_back. The labels show
## once it has arrived. The left label is the text-control object of the disc (the set choice); its words are not extracted yet, so only
## the right arrow is drawn.
func _draw_centre(hand: Array) -> void:
	if not (mode in CENTRE_MODES) or hand_index >= hand.size():
		return
	_load_cursor_art()
	var t := clampf(float(centre_clock) / float(CENTRE_FRAMES), 0.0, 1.0)
	if mode == "centre_back":
		t = 1.0 - t
	var at := DuelHand.place(hand_index).lerp(CENTRE_AT, (1.0 - cos(t * PI)) / 2.0)
	var id := int(hand[hand_index])
	var face: Texture2D = _centre_face(id, DuelEngine.hand_slot(engine.state.sides[0], hand_index)) if centre_face_down else _hand_card_face(id, DuelEngine.hand_slot(engine.state.sides[0], hand_index))
	board.add_child(DuelHand.face(face, at, sharp))
	if mode == "centre" and centre_clock >= CENTRE_FRAMES and not arrow_art.is_empty():
		# the two choices: the green left arrow (set face-down) and the green right arrow (face-up), at the reference's places
		_choice_arrow(false, ARROW_LEFT_AT)
		_choice_arrow(true, ARROW_RIGHT_AT)

## The art tables, read once from the extraction (zone_cursor.json and hand/layout.json). Missing files leave them empty.
func _load_cursor_art() -> void:
	if arrow_art.is_empty():
		var arrows: Array = _read_json(PASSWORD_ART + "layout.json").get("arrows", [])
		if arrows.size() >= 3:
			arrow_art = arrows[0]          # the right-pointing arrow: the face-up choice's label
			arrow_left_art = arrows[2]     # the left-pointing arrow (its own offset: -15): the face-down choice
	if zone_art.is_empty():
		zone_art = _read_json(FIELD_ART + "zone_cursor.json").get("streams", {})
	if hand_art.is_empty():
		hand_art = _read_json(HAND_ART + "layout.json")


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## The frame of a baked stream ({frames, order}) at a tick: the play order's holds in turn, looping. Empty when there is none.
func _stream_frame(entry: Dictionary, tick: int) -> Dictionary:
	var order: Array = entry.get("order", [])
	var frames: Array = entry.get("frames", [])
	var total := 0
	for step in order:
		total += int(step[0])
	if total <= 0 or frames.is_empty():
		return {}
	var t := posmod(tick, total)
	for step in order:
		if t < int(step[0]):
			return frames[int(step[1])]
		t -= int(step[0])
	return {}


## A sprite of one baked frame at an origin (the frame's own offset is added), on the board.
func _cursor_sprite(folder: String, frame: Dictionary, origin: Vector2, mirror := false) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.material = sharp
	_set_frame(sprite, folder, frame, origin, mirror)
	board.add_child(sprite)
	return sprite


## The sprite shows a frame at its origin plus the frame's own offset. A mirrored frame (the hand pointer) is flipped within the same box,
## so its apex turns to the card: the baked picture points the other way, the original's pointer points into the card.
func _set_frame(sprite: Sprite2D, folder: String, frame: Dictionary, origin: Vector2, mirror := false) -> void:
	sprite.flip_h = mirror
	sprite.position = origin + Vector2(float(frame.get("x", 0)), float(frame.get("y", 0)))
	if frame.has("file"):
		var art := _art(folder + str(frame["file"]))
		ModArt.apply(sprite, art)


## The red hand pointer under hand slot i: the reference draws it as one 16 x 16 picture (pointer.png, mirrored so its tip points into the
## card), at (6, 186) for slot 0, that is the slot's (14, 194) less 8 on each side. It does not animate in the reference's frames.
const HAND_POINTER := "res://assets/screens/duel_hand/pointer.png"


func _hand_pointer(i: int) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.centered = false
	ModArt.apply(sprite, _art(HAND_POINTER))      # the picture's own size and scale (the art record), as the other pieces are drawn
	sprite.flip_h = true
	sprite.position = Vector2(DuelHand.place(i).x - 8.0, 186.0)
	sprite.material = sharp
	board.add_child(sprite)
	return sprite


## Each physics frame: the cursors' clock moves on and the zone cursor and the hand pointer show their next frame.
func _animate_cursors() -> void:
	anim_tick += 1
	if zone_sprite != null and is_instance_valid(zone_sprite) and not zone_track.is_empty():
		_set_frame(zone_sprite, zone_track["folder"], _stream_frame(zone_track["entry"], anim_tick), zone_track["at"])


## The activation prompt under the magic or trap card: YES and NO in the game's letters, the choice's bar behind the selected one.
func _draw_prompt() -> void:
	if field == null:
		return
	var at: Vector2 = field.card_box(_record(0, "traps", zone_index)).position
	board.add_child(DuelPrompt.bar(at, prompt_choice))
	var labels: Array = DuelPrompt.origins(at)
	_say("YES", labels[0])
	_say("NO", labels[1])


func _hovered_card() -> int:
	var s = engine.state
	match mode:
		"hand":
			return int(s.sides[0].hand[hand_index]) if hand_index < s.sides[0].hand.size() else 0
		"dest", "field", "equip_pick", "prompt":
			var z = s.sides[0].traps[zone_index] if _cursor_row() == "traps" else s.sides[0].monsters[zone_index]
			# a face-down card shows no name or stats in the bar (the reference bar stays empty over a set card)
			return int(z["id"]) if z != null and not bool(z.get("face_down", false)) else 0
		"target":
			var t = s.sides[1].monsters[zone_index]
			return int(t["id"]) if t != null and not bool(t["face_down"]) else 0
	return 0


func _draw_info() -> void:
	var id := _hovered_card()
	if spectator and mode in ["over", "result"]:
		# the spectator match's ending: the winner's name, and MATCH OVER once the match is decided for good
		_say("%s WINS" % DuelSpectator.duelist_name(data, spectator_ids[engine.winner]), Vector2(16, INFO_Y))
		if mode == "result":
			_say("MATCH OVER", Vector2(16, INFO_Y + 12))
		return
	if mode == "over":
		_say("YOU WIN" if engine.winner == 0 else "YOU LOSE", Vector2(120, INFO_Y), 0)
		return
	var line: String = help.info_line() if help != null else ""
	if line != "":
		_say(line, Vector2(16, INFO_Y))     # a refusal or the first-time tip, on the game's info line (duel_help.gd)
		if mode != "hand":
			return
	if id == 0:
		if message != "":
			_say(message, BAR_TEXT)     # a message sits on the bar's first text row (the bar is 16 high inside the band)
		return
	_draw_bar_card(id)      # the selected card's name, and its stats or type on the right (the original's bottom bar)


## The bottom bar: the field card box of the hovered card (the field display builds it as a text box create
## (field_00.x + 0x10, field_00.y + field_16, 0x120, 0x40); the hand source's field_00 sits at y 0xAE and field_16 is 0x24, so the box is
## at (16, 210) and the screen cuts its foot). Its fill here is a dark box; the frame art of a text box is not drawn yet.
func _draw_bar() -> void:
	pass   # the band is drawn by _draw_band (the baked duel frame); the text goes over it


## The story dialog frame picture (assets/screens/story/frame.png), loaded once.
func _bar_frame() -> Texture2D:
	if bar_frame_texture == null:
		var image := Image.load_from_file("res://assets/screens/story/frame.png")
		if image != null:
			bar_frame_texture = ImageTexture.create_from_image(image)
	return bar_frame_texture


## The hovered card's text in the bar box: the name on the first row and, on the second, the monster's ATK and DEF (its stars on the
## first row's right end, as glyphs 0x17 + the star id) or the spell's or trap's type. A text box starts 2 pixels above its top and
## its rows are 12 apart (the port's dialog rule).
func _draw_bar_card(id: int) -> void:
	var strip: Dictionary = data.card(id)
	var named: Array = text.layout(board, _bytes(str(strip.get("name", ""))), BAR_TEXT, Vector2(8, 12), 0, sharp, true)
	DuelHud.clip_placed(named, BAR_BOX)
	var second := BAR_TEXT + Vector2(0, 12)
	if mode == "dest" and set_down:
		_say("SET FACE-DOWN", second)
		return
	# the card's race or kind icon (race_icons/, the card's type number: the text channel's icon entry of kind 0) and its guardian
	# stars (star_icons/, the entries of kinds 1 and 2): all 16 x 16 at the bar's top row (y 210)
	var race := CardViewScript.RACE_TYPES.find(str(strip.get("type", "")))
	var z = null
	if mode in ["dest", "field"]:
		z = engine.state.sides[0].monsters[zone_index]
	elif mode == "target":
		z = engine.state.sides[1].monsters[zone_index]
	if engine.state.is_monster(id):
		var atk: int = engine.state.atk(z) if z != null else int(strip["attack"])
		var dfn: int = engine.state.def(z) if z != null else int(strip["defense"])
		var face_down_zone: bool = z != null and bool(z.get("face_down", false))
		if not face_down_zone:
			# the stat rows: the sword (ATK) and the shield (DEF) 8 x 8 marks at x 211, their digits from x 243, no padding
			_board_put(Vector2(211, 210), BAR_ICONS + "label_sword.png")
			_board_put(Vector2(211, 218), BAR_ICONS + "label_shield.png")
			_bar_digits(atk, Vector2(243, 210))
			_bar_digits(dfn, Vector2(243, 218))
		# the race icon sits at x 253 whatever the digit count: the digits are right aligned to the units cell at 243 (the reference's
		# bar: ATK 1200 in the cells 219 to 243, DEF 700 in 227 to 243, the race icon at 253 in a face-up Baby Dragon's field bar)
		var icon_x := 253.0
		if race >= 0:
			_board_put(Vector2(icon_x, 210), RACE_ICONS + "%02d.png" % race)
		var star_x := icon_x + 26.0
		# the field's bar (the monster cursor on the board) shows the race and the attribute only; the reference draws no guardian star there
		if not face_down_zone and not (mode in ["dest", "field", "target"]):
			for key in ["guardian_star_1", "guardian_star_2"]:
				var star: String = str(strip.get(key, ""))
				if star != "":
					_board_put(Vector2(star_x, 210), STAR_ICONS + star.to_lower() + ".png")
					star_x += 18.0
				elif key == "guardian_star_1":
					# a monster with no guardian star still gets the first star's slot: the star-0 icon (code 0x17), the fist cell
					# (the reference bar's icon for a card with no star)
					_board_put(Vector2(star_x, 210), RACE_ICONS + "23.png")
					star_x += 18.0
	else:
		_say(str(engine.state.card_type(id)).to_upper(), second)
		# a spell, trap, ritual or equip: its kind icon alone at the bar's right (x 271 in the hand, 279 on the field)
		if race >= 0:
			_board_put(Vector2(271.0 if mode == "hand" else 279.0, 210), RACE_ICONS + "%02d.png" % race)


## The bar's digits: 8 x 8 cells (duel_bar/digit_<d>.png), right aligned: the units digit's cell starts at at.x, the tens 8 to its left,
## and so on (the reference's bar: 1200 in the cells 219 to 243, 700 in 227 to 243).
func _bar_digits(value: int, at: Vector2) -> void:
	var text_value := str(value)
	var n := text_value.length()
	for i in n:
		_board_put(at + Vector2(8.0 * (i - (n - 1)), 0), BAR_ICONS + "digit_%s.png" % text_value.substr(i, 1))


## The card viewer's screen (Triangle, or a tap on a hand card): the reference's viewer over black, with the field and the hand off. The
## whole card at 1x at (2, 24), composed by CardView.card_picture (its frame, picture, name plate, kind label or level stars with ATK and
## DEF, and the attribute ball). The card's text box at (148, 34), framed by the library's card frame 8 pixels out, holds the kind, the
## guardian stars and the text (CardView's box without the stats, which are on the card).
const VIEW_CARD_AT := Vector2(2, 24)
const VIEW_BOX_AT := Vector2(148, 34)
const VIEW_BOX_FRAME := "res://assets/screens/library/card_frame.png"
const VIEW_TEXT_DOWN := Vector2(0, 2)


## The card viewer is up over the board (the end screens take no viewer).
func _viewer_up() -> bool:
	return viewer and mode != "over" and mode != "result"


func _draw_panel(id: int) -> void:
	var c: Dictionary = data.card(id)
	var atk := int(c.get("attack", 0))
	var dfn := int(c.get("defense", 0))
	var z = null
	if mode in ["dest", "field"]:
		z = engine.state.sides[0].monsters[zone_index]
	elif mode == "target":
		z = engine.state.sides[1].monsters[zone_index]
	if engine.state.is_monster(id) and z != null:
		# a monster on the field shows its current ATK and DEF
		atk = engine.state.atk(z)
		dfn = engine.state.def(z)
	var picture := _viewer_picture(id, c, atk, dfn)
	if picture != null:
		var card := Sprite2D.new()
		card.centered = false
		card.texture = picture
		card.material = sharp
		card.position = VIEW_CARD_AT
		board.add_child(card)
	_board_put(VIEW_BOX_AT + Vector2(-8, -8), VIEW_BOX_FRAME)
	if viewer_view == null:
		viewer_view = CardViewScript.new(text, sharp)
	var box := Node2D.new()
	box.position = VIEW_BOX_AT + VIEW_TEXT_DOWN   # the box's rows sit 2 pixels below its frame's top (the reference's viewer)
	board.add_child(box)
	viewer_view.build(box, null, id, c, false)


## The card's picture for these values (ATK and DEF as shown), cached per card and value.
func _viewer_picture(id: int, c: Dictionary, atk: int, dfn: int) -> Texture2D:
	var key := "%d:%d:%d" % [id, atk, dfn]
	if not viewer_pictures.has(key):
		var image: Image = CardViewScript.card_picture(id, c, atk, dfn, viewer_card_ui)
		viewer_pictures[key] = ImageTexture.create_from_image(image) if image != null else null
	return viewer_pictures[key]


## A sprite of a picture under res://assets/ on the board (the panel's pictures and icons); nothing when the picture is missing.
func _board_put(at: Vector2, path: String) -> void:
	var art := _art(path)
	if art["texture"] == null:
		return
	var sprite := Sprite2D.new()
	sprite.centered = false
	ModArt.apply(sprite, art)
	sprite.position = at
	sprite.material = sharp
	board.add_child(sprite)


# ---- the readouts ----------------------------------------------------------------------------------------------------------

const STAR_ICONS := "res://assets/screens/star_icons/"   # the guardian star symbols, 16 x 16, baked from the disc (tools/extract.py bake_star_icons)
const RACE_ICONS := "res://assets/screens/race_icons/"   # the race and kind icons, codes 0 to 23 (tools/extract.py bake_race_icons)
const BAR_ICONS := "res://assets/screens/duel_bar/"      # the bar's sword, shield and digit cells (tools/extract.py bake_duel_bar_icons)
const CARD_DIGITS := "res://assets/screens/duel_card/"   # the 8 x 8 digit cells of the duel card (tools/extract.py bake_duel_card_face): the readouts' digits
const HUD_PANEL := "res://assets/screens/duel_hud/"   # the readout panels: life-point panel, flipped for the second player (extracted by tools/extract.py)
const ICONS := "res://assets/images/"
const COLOUR_NORMAL := Color(1.0, 1.0, 1.0)     # the normal display colour (0x808080: the sprite at full brightness)
const COLOUR_DIMMED := Color(0.5, 0.5, 0.5)     # the dimmed display colour (0x404040)


## The art record ({texture, scale}) of a picture under res://assets/, cached per path.
func _art(path: String) -> Dictionary:
	if not sprites.has(path):
		sprites[path] = ModArt.load_art(path)
	return sprites[path]


func _tex(path: String) -> Texture2D:
	return _art(path)["texture"]


func _put(at: Vector2, path: String, tint := COLOUR_NORMAL) -> void:
	var art := _art(path)
	if art["texture"] == null:
		return
	var sprite := Sprite2D.new()
	sprite.centered = false
	ModArt.apply(sprite, art)
	sprite.position = at
	sprite.modulate = tint
	sprite.material = sharp
	hud.add_child(sprite)


## A number in the game's font, in 8-pixel cells, most significant first, with leading zeros (the routine at 0x80016D2C writes one cell
## per digit). The digit sprites of card_frames are not in the extraction, so the font's digits stand in for them; the tint dims
## a readout the way the game's shade does.
func _digits(at: Vector2, value: int, count: int, tint: Color) -> void:
	# The readout's digits are the duel card's 8 x 8 digit cells (duel_card/digit_<d>.png: VRAM page 30, CLUT row 241), eight pixels
	# apart from `at`, most significant first. A leading zero is the blank cell the reference's decimal encoding leaves (the units
	# digit is always drawn), so it draws nothing.
	var shown := str(maxi(value, 0) % int(pow(10.0, count)))
	while shown.length() < count:
		shown = "0" + shown
	var leading := true
	for i in shown.length():
		var digit := shown[i]
		if leading and digit == "0" and i < shown.length() - 1:
			continue
		leading = false
		var art := _art(CARD_DIGITS + "digit_%s.png" % digit)
		if art["texture"] == null:
			continue
		var sprite := Sprite2D.new()
		sprite.centered = false
		ModArt.apply(sprite, art)
		sprite.position = at + Vector2(8 * i, 0)
		sprite.modulate = tint
		sprite.material = sharp
		hud.add_child(sprite)


## The life points a readout shows steps toward the real total: 9 a frame, or 19, 47 or 97 as the gap passes 300, 1000 and
## 3000 (the life point display update).
func _count_life(side: int) -> void:
	if fx != null and fx.holds_life(side):
		return                  # the readout waits for the damage or recovery figure to land (duel_fx.gd)
	var real: int = engine.state.sides[side].lp
	if shown_life[side] < 0:
		shown_life[side] = real
		return
	var difference: int = shown_life[side] - real
	if difference == 0:
		return
	var magnitude := absi(difference)
	var step := 9
	if magnitude >= 300:
		step = 19
	if magnitude >= 1000:
		step = 47
	if magnitude >= 3000:
		step = 97
	if difference > 0:
		difference = maxi(difference - step, 0)
	else:
		difference = mini(difference + step, 0)
	shown_life[side] = real + difference


const PANEL_SLIDE := 128.0      # the slide's reach: the FIELD box goes from x 12 to -116 and the life-point panel from 280 to 408
const PANEL_FRAMES := 16        # the slide's length: 16 frames, the cosine ease of the game's panel slide (the routine at 0x8001ED20)
const TRIG_HALF_TURN := 2048    # TRIG_ANGLE_HALF_TURN: the trig angles are 4096 to a full turn


## The battle takes the FIELD box and the life-point panel off the picture (left and right) for its presentation, and gives them back
## when it ends (the battle's first frame and its resume state). Each slide eases over PANEL_FRAMES, as the game's slide does.
func _panels_follow() -> void:
	if not slide_plan.is_empty():
		_slide_step()
	elif not slide_held:
		var want := 1.0 if (fx != null and fx.battle_running) else 0.0
		if want != panel_target:
			panel_target = want
			panel_from = panel_share
			panel_left = PANEL_FRAMES
		if panel_left > 0:
			panel_left -= 1
			var t := 1.0 - float(panel_left) / float(PANEL_FRAMES)
			panel_share = lerpf(panel_from, panel_target, (1.0 - cos(PI * t)) * 0.5)
		slide_field = -PANEL_SLIDE * panel_share
		slide_lp = PANEL_SLIDE * panel_share
	if field != null:
		field.place_plate(slide_field)


## Slides the FIELD box and the life-point panel to the x positions field_x and lp_x (the spec's coordinates: the box rests at 12,
## the panel at 280), in steps of 0x800 / divisor angle units a frame. The game's position routine (0x8001EC70) does this: the
## position is the cosine ease between the start and the target, with no snap at the end, so the last frame stands where the
## last step put it. Used by the result outro (divisor 0x30) and the Exodia ending (divisor 0x10); the battle's slide stands aside after.
func slide_panels(field_x: int, lp_x: int, divisor: int) -> void:
	slide_held = true
	slide_plan = {"from_field": 12 + int(round(slide_field)), "to_field": field_x,
			"from_lp": 280 + int(round(slide_lp)), "to_lp": lp_x, "angle": 0, "step": TRIG_HALF_TURN / divisor}


## One frame of a result slide (slide_panels): the position at the current angle, then the angle moves by the step; the slide ends
## once the angle reaches a half turn (the game's routine checks after the step, so the last position is the one at the angle before).
func _slide_step() -> void:
	var p := slide_plan
	var angle := int(p["angle"])
	slide_field = float(_ease(int(p["from_field"]), int(p["to_field"]), angle) - 12)
	slide_lp = float(_ease(int(p["from_lp"]), int(p["to_lp"]), angle) - 280)
	angle += int(p["step"])
	if angle >= TRIG_HALF_TURN:
		slide_plan = {}
	else:
		p["angle"] = angle


## The game's cosine interpolation at an angle (of 4096 for a full turn): the midpoint, plus the start's distance from it times the
## cosine (4096 is 1.0), with the C division that truncates toward zero.
static func _ease(from: int, to: int, angle: int) -> int:
	var mid := (from + to) >> 1
	var scale := int(cos(float(angle) * TAU / 4096.0) * 4096.0)
	return mid + (from - mid) * scale / 4096


## Every frame: the life-point boxes and their digits, the deck counts (the side to act lit), and the hovered card's attribute and level.
## The digits are at the positions of the life point and deck count drawing for the anchor at (280, 32): a side's life points at x 277,
## the foe's on line 19 and the player's on line 45; the deck counts at x 294 on lines 27 and 37.
func _update_hud() -> void:
	for child in hud.get_children():
		hud.remove_child(child)
		child.queue_free()
	if engine == null:
		return
	var s = engine.state
	var turn: int = s.turn_side
	_count_life(0)
	_count_life(1)
	var foe_tint := COLOUR_DIMMED if turn == 0 else COLOUR_NORMAL
	var you_tint := COLOUR_DIMMED if turn != 0 else COLOUR_NORMAL
	# the life-point panel: the object at (280, 32) with its part at the offset layout.json gives (the boot UI's LP and COM / YOU labels).
	# Its palette row is 0x2E0 plus 16 for the side to act (the turn start writes it), so the side whose turn it is is the lit panel.
	# The battle slides it off the right edge and back (panel_share, _panels_follow).
	# A two-player duel's panel is the other resource of the object (side 1 of the setup): its labels read 2P and 1P (life_point_panel_2p,
	# baked by tools/extract.py).
	var slide := Vector2(slide_lp, 0.0)
	var panel := "life_point_panel_2p" if two_player else "life_point_panel"
	_put(Vector2(280 - 32, 32 - 15) + slide, HUD_PANEL + panel + ("_flipped.png" if turn != 0 else ".png"))
	_digits(Vector2(277, 19) + slide, shown_life[1], 4, foe_tint)
	_digits(Vector2(294, 27) + slide, s.sides[1].deck.size(), 2, foe_tint)
	_digits(Vector2(277, 45) + slide, shown_life[0], 4, you_tint)
	_digits(Vector2(294, 37) + slide, _deck_shown(0), 2, you_tint)
	# no attribute or level icons on the duel screen: the spec's duel draws none (the card viewer's panel has its own)


# ---- input -----------------------------------------------------------------------------------------------------------

## Starts a deal of total hand cards from hand index base; clock is the frame count it starts at (negative while a sweep or swing runs).
func _start_deal(base: int, total: int, clock: int) -> void:
	deal_base = base
	deal_total = total
	deal_started = 0
	deal_clock = clock
	deal_active = total > 0
	if deal_active:
		mode = "deal"
	refresh()


## One frame of the deal (the draw resolution): a card enters every DEAL_INTERVAL frames with the draw sound, and the turn's input
## waits until the last card has landed.
func _deal_step() -> void:
	deal_clock += 1
	if deal_clock >= 0 and deal_clock % DEAL_INTERVAL == 0 and deal_started < deal_total:
		deal_started += 1
		sound.emit(0x0A)            # the draw sound (effect 0x0A)
	if deal_started >= deal_total and deal_clock >= DEAL_INTERVAL * (deal_total - 1) + DEAL_SLIDE:
		deal_active = false
		mode = "over" if engine.winner >= 0 else ("foe" if spectator else "hand")    # a decided draw ends the duel once its cards are dealt
	refresh()


## The deck count the readout shows: the cards still in the deck, plus the dealt-to-be ones still on their way from it.
func _deck_shown(side: int) -> int:
	var n: int = engine.state.sides[side].deck.size()
	if deal_active and side == 0:
		n += maxi(deal_total - deal_started, 0)
	return n


## The opening fade (the fade-in state): black over the picture, lifting over FADE_FRAMES.
func _fade_step() -> void:
	if fade_left <= 0 or fade_rect == null:
		return
	fade_left -= 1
	fade_rect.color = Color(0.0, 0.0, 0.0, float(fade_left) / float(FADE_FRAMES))
	fade_rect.visible = fade_left > 0


func _down(keys: Array) -> bool:
	for k in keys:
		if Input.is_key_pressed(k):
			return true
	return false


func _edge(name: String, keys: Array) -> bool:
	var now := _down(keys)
	var was: bool = held.get(name, false)
	held[name] = now
	return now and not was


func _physics_process(_delta: float) -> void:
	if not ready_ok:
		return
	timer += 1
	if mode == "foe":
		foe_clock += 1
		if foe_actions == 0 and foe_clock <= FOE_DEAL * 6:
			refresh()               # the computer's hand is dealt in (_draw_foe_hand)
	_animate_cursors()
	if mode in CENTRE_MODES:
		centre_clock += 1
		if mode == "centre_back" and centre_clock >= CENTRE_FRAMES:
			_lift()                 # the card is back in its slot: the destination is chosen with its picks (the card is the only pick)
		refresh()
	if field != null:
		field.tick()
		if field.cam_left > 0 and ready_ok:
			refresh()               # the field camera is still moving: the cursors and the card boxes are drawn at its current pose
	_fade_step()
	_panels_follow()
	_update_hud()
	help.update(self)           # the refusal and tip timers and the attack pulse (duel_help.gd)
	fx.tick()
	if spectator:
		# the Shift fast-forward (held) and the match's own input: the quit box, and the match over waiting for its confirm
		Engine.time_scale = DuelSpectator.FAST_SCALE if (Input.is_key_pressed(KEY_SHIFT) and quit_box == null and not spectator_done) else 1.0
		if _spectator_control():
			return
	if fx.busy():
		refresh()               # an event's presentation is playing (the hand may leave the picture: refresh draws it)
		return                  # an event's presentation is playing: no input and no AI step until it ends
	if star_zone >= 0 and mode == "field":
		mode = "star"           # the placement has shown: the guardian star of the placed monster is asked now
		star_choice = 0
	var left := _edge("left", [KEY_A, KEY_LEFT])
	var right := _edge("right", [KEY_D, KEY_RIGHT])
	var confirm := _edge("confirm", [KEY_E, KEY_SPACE])
	var cancel := _edge("cancel", [KEY_Q, KEY_ESCAPE, KEY_BACKSPACE])
	var mark := _edge("mark", [KEY_F])
	var flip := _edge("flip", [KEY_R])
	var start := _edge("start", [KEY_ENTER])
	var up := _edge("up", [KEY_UP, KEY_W])
	var down := _edge("down", [KEY_DOWN, KEY_S])
	if _edge("viewer", [KEY_T]) and (viewer or help == null or help.overlay_kind == ""):
		_set_viewer(not viewer)     # Triangle (T) shows the card under the hand cursor, or closes the viewer; not over the help sheet
	confirm = confirm or _take("confirm")
	cancel = cancel or _take("cancel")
	mark = mark or _take("mark")
	if viewer and mode not in ["foe", "deal", "over", "result"]:
		# the card viewer takes the pad, as the reference's viewer does: only its close keys act (Circle or Q, Escape, Backspace)
		if cancel:
			_set_viewer(false)
		return
	var help_key := _edge("help", [KEY_H, KEY_TAB]) or (_edge("help_question", [KEY_SLASH]) and Input.is_key_pressed(KEY_SHIFT))
	if help.frame(help_key, up, down, confirm, cancel, left or right or up or down or confirm or cancel or mark or flip or start):
		return                  # the controls sheet or the tutorial is open: the duel waits for it to close
	if mode == "deal":
		_deal_step()                # the cards enter the hand; the player's input waits for the last one
		return
	if mode == "foe":
		_foe_step()
		return
	if mode == "over":
		_finale_step()
		return
	if mode == "result":
		return
	var dx := (1 if right else 0) - (1 if left else 0)
	if mode in WHEEL_MODES and dx == 0 and wheel_steps != 0:
		dx = signi(wheel_steps)
		wheel_steps -= dx
	elif not (mode in WHEEL_MODES):
		wheel_steps = 0
	match mode:
		"hand":
			var n: int = engine.state.sides[0].hand.size()
			if dx != 0 and n > 0:
				hand_index = posmod(hand_index + dx, n)
				sound.emit(0x2F)
			elif mark and n > 0:
				# the mark (F, Triangle) adds the card under the cursor as the next pick; a marked card takes no second mark (the original's
				# hand state: a pick is made only on an unmarked card, with the order number the count then holds)
				if not marks.has(hand_index):
					marks.append(hand_index)
			elif flip and n > 0:
				set_down = not set_down
				message = "SET FACE-DOWN" if set_down else ""
			elif confirm and n > 0 and marks.is_empty() and _centre_card():
				_enter_centre()         # a single monster or trap goes to the centre to choose its face first (the hand action's case 3)
			elif confirm and n > 0 and marks.size() != 1:
				_lift()                 # one marked card cannot be confirmed: the original's Confirm needs no picks or two or more (the field_15 != 1 guard)
			elif start:
				mode = "field"
				zone_index = 0
				zone_row = 0
			elif cancel and marks.has(hand_index):
				marks.erase(hand_index)     # the cancel (Circle, Q) takes the mark off the card under the cursor; the others keep their order
				sound.emit(0x2F)
			refresh()
		"dest":
			if dx != 0:
				zone_index = posmod(zone_index + dx, 5)
				sound.emit(0x2F)
			if up or down:
				zone_row = DuelHand.ROW_SPELLS if up else DuelHand.ROW_MONSTERS
				sound.emit(0x2F)
			if flip:
				set_down = not set_down
				message = "SET FACE-DOWN" if set_down else ""
			if confirm:
				_place()
			elif cancel:
				mode = "hand"
			refresh()
		"centre":
			# the face choice (the hand action's case 3): left sets the card face-down, right turns it face-up; Confirm places it with that face,
			# cancel puts it back in the hand. Nothing is taken until the card has arrived in the centre.
			if centre_clock >= CENTRE_FRAMES:
				if dx != 0:
					centre_face_down = dx < 0
					sound.emit(0x2F)
				if confirm:
					_centre_confirm()
				elif cancel:
					mode = "hand"
					sound.emit(8)
			refresh()
		"centre_back":
			pass                        # the card goes back to its slot, then the destination opens (_physics_process)
		"star":
			# the choice box (the original's read choice input routine): up, down, left or right moves between the two stars; there is no cancel
			if dx != 0 or up or down:
				star_choice = 1 - star_choice
				sound.emit(0x2F)
			if confirm:
				_set_star(star_choice == 1)
			refresh()
		"field":
			if dx != 0:
				zone_index = posmod(zone_index + dx, 5)
				sound.emit(0x2F)
			if up or down:
				zone_row = 1 if up else 0      # up to the magic and trap row, down to the monsters (the d-pad's up and down)
				sound.emit(0x2F)
			if zone_row == 1:
				# the magic and trap row: confirm asks to activate an own set magic or equip; Enter still ends the turn
				if confirm:
					_ask_activation()
				elif start:
					_end_turn()
			else:
				if flip and engine.can_change_position(0, zone_index):
					engine.change_position(0, zone_index)
				elif flip:
					_refuse(DuelHelp.change_reason(engine, zone_index))
				if confirm and engine.can_attack(0, zone_index):
					attacker = zone_index
					if _foe_row_empty():
						_resolve_attack(-1)
					else:
						mode = "target"
						zone_index = _first_foe_zone()
				elif confirm:
					_refuse(DuelHelp.attack_reason(engine, zone_index))
				elif start:
					_end_turn()
			if cancel:
				mode = "hand"          # Q or Esc goes back to the hand (the field has no other back)
			refresh()
		"prompt":
			if dx != 0:
				prompt_choice = 1 - prompt_choice
				sound.emit(0x2F)
			if confirm:
				if prompt_choice == 0:
					_activate_back_row()
				else:
					_cancel_prompt()
			elif cancel:
				_cancel_prompt()
			refresh()
		"equip_pick":
			if dx != 0:
				zone_index = posmod(zone_index + dx, 5)
				sound.emit(0x2F)
			if confirm:
				_equip_from_back_row()
			elif cancel:
				if bool(pending.get("from_hand", false)):
					_cancel_equip_hand()
				else:
					_cancel_prompt()
			refresh()
		"target":
			if dx != 0:
				zone_index = _next_foe_zone(zone_index, dx)
				sound.emit(0x2F)
			if confirm:
				_resolve_attack(zone_index)
			elif cancel:
				mode = "field"
				zone_index = attacker
			refresh()


## The card viewer on or off: the Triangle key (T), a tap on a hand card (on) and a tap or a click while it is up (off) all play the
## reference's viewer sound (0x34) and redraw the screen.
func _set_viewer(on: bool) -> void:
	viewer = on
	sound.emit(0x34)
	refresh()


func _take(which: String) -> bool:
	var was: bool = mouse_pending.get(which, false)
	mouse_pending[which] = false
	return was


## Mouse: hovering moves the hand cursor or the monster cursor as the arrows do, a click is Cross (confirm), the middle button marks as F,
## and the right button is Circle (cancel). Only the modes that take a cursor react to hovering.
func _gui_input(event: InputEvent) -> void:
	if not ready_ok:
		return
	if spectator:
		_spectator_mouse(event)
		return
	if event is InputEventMouseMotion:
		if not viewer:
			_hover(event.position)      # the card viewer shows its card: the pointer leaves the cursors alone while it is up
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	if viewer:
		# the card viewer is up: a tap or a click closes it (tapping again closes it), and the wheel does nothing
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			_set_viewer(false)
		return
	if event.button_index == MOUSE_BUTTON_LEFT and mode == "hand" and not fx.busy() and (help == null or help.overlay_kind == ""):
		# a tap on a hand card shows it in the card viewer (the pick is made with Cross or E, and the viewer closes on the next tap)
		var n: int = engine.state.sides[0].hand.size()
		var at := DuelHand.index_at((event.position - world.position) / world.scale, n)
		if at >= 0 and at < n:
			hand_index = at
			_set_viewer(true)
			return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		# the wheel moves the hand or zone cursor left (up) or right (down), as the arrows do
		if mode in WHEEL_MODES:
			var step := -1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1
			wheel_steps = clampi(wheel_steps + step, -10, 10)
		return
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			_hover(event.position)
			mouse_pending["confirm"] = true
		MOUSE_BUTTON_MIDDLE:
			_hover(event.position)
			mouse_pending["mark"] = true
		MOUSE_BUTTON_RIGHT:
			mouse_pending["cancel"] = true


func _hover(at: Vector2) -> void:
	var local: Vector2 = (at - world.position) / world.scale
	if help != null and help.overlay_kind == "menu":
		help.hover(local)          # the controls menu takes the pointer (duel_help.gd)
		return
	match mode:
		"hand":
			var n: int = engine.state.sides[0].hand.size()
			var i := DuelHand.index_at(local, n)
			if i >= 0 and i < n and i != hand_index:
				hand_index = i
				sound.emit(0x2F)
		"dest":
			var m := _monster_at(local, 0)
			if m >= 0:
				if zone_row != DuelHand.ROW_MONSTERS or m != zone_index:
					zone_row = DuelHand.ROW_MONSTERS
					zone_index = m
					sound.emit(0x2F)
			else:
				var t := _trap_at(local)
				if t >= 0 and (zone_row != DuelHand.ROW_SPELLS or t != zone_index):
					zone_row = DuelHand.ROW_SPELLS
					zone_index = t
					sound.emit(0x2F)
		"equip_pick":
			var i := _monster_at(local, 0)
			if i >= 0 and i != zone_index:
				zone_index = i
				sound.emit(0x2F)
		"centre":
			# the two face choices under the card: the left label sets it face-down, the right arrow turns it face-up (the hover picks; the click confirms)
			if centre_clock >= CENTRE_FRAMES:
				var down := Rect2(CENTRE_AT + Vector2(-8, 30), Vector2(24, 12)).has_point(local)
				var up := Rect2(CENTRE_AT + Vector2(60, 30), Vector2(16, 16)).has_point(local)
				if (down or up) and centre_face_down != down:
					centre_face_down = down
					sound.emit(0x2F)
		"star":
			# the two star rows of the box: hovering a row chooses it, the click confirms it
			var row := int(floor((local.y - (STAR_BOX.position.y + 16.0)) / 16.0))
			if row >= 0 and row < 2 and STAR_BOX.has_point(local) and star_choice != row:
				star_choice = row
				sound.emit(0x2F)
		"field":
			# the monster row or the magic and trap row, whichever card the point is on
			var m := _monster_at(local, 0)
			if m >= 0:
				if zone_row != 0 or m != zone_index:
					zone_row = 0
					zone_index = m
					sound.emit(0x2F)
			else:
				var t := _trap_at(local)
				if t >= 0 and (zone_row != 1 or t != zone_index):
					zone_row = 1
					zone_index = t
					sound.emit(0x2F)
		"prompt":
			if field == null:
				return
			var boxes: Array = DuelPrompt.hit_boxes(field.card_box(_record(0, "traps", zone_index)).position)
			for choice in 2:
				if boxes[choice].has_point(local) and prompt_choice != choice:
					prompt_choice = choice
					sound.emit(0x2F)
		"target":
			var i := _monster_at(local, 1)
			# a foe zone with no monster is not a target (the keys skip them too)
			if i >= 0 and i != zone_index and engine.state.sides[1].monsters[i] != null:
				zone_index = i
				sound.emit(0x2F)


func _foe_row_empty() -> bool:
	for z in engine.state.sides[1].monsters:
		if z != null:
			return false
	return true


func _first_foe_zone() -> int:
	for i in 5:
		if engine.state.sides[1].monsters[i] != null:
			return i
	return 0


func _next_foe_zone(from: int, dx: int) -> int:
	for k in range(1, 6):
		var i := posmod(from + dx * k, 5)
		if engine.state.sides[1].monsters[i] != null:
			return i
	return from


# ---- the player's turn ------------------------------------------------------------------------------------------------

func _begin_turn(p: int) -> void:
	if two_player and engine.winner < 0:
		_face(p)
		p = 0
	if spectator and engine.winner < 0 and DuelSpectator.stalled(engine):
		DuelSpectator.end_stalled(engine)       # a stalled spectator match is decided on the life points (duel_spectator.gd)
	engine.state.turn_side = p
	var before: int = engine.state.sides[p].hand.size()
	engine.draw_phase(p)
	var drew: int = engine.state.sides[p].hand.size() - before
	marks.clear()
	hand_index = 0
	zone_row = 0
	message = ""
	if spectator and engine.winner < 0:
		message = DuelSpectator.title(data, spectator_ids)     # the info line names the two duelists
	if field != null:
		# the turn side's view: its heading and its own monster row (the camera turns to the foe's side on the foe's turn)
		field.set_view_side(p, TURN_FRAMES)
		field.focus(p, _record(p, "monsters", 0))
	if engine.winner >= 0:
		mode = "over"
		if p == 0 and drew > 0:
			_start_deal(before, drew, -TURN_WAIT)   # the decided draw: its cards are dealt first, then the ending
	elif p == 0 and not spectator:
		mode = "hand"
		if drew > 0:
			_start_deal(before, drew, -TURN_WAIT)   # the drawn cards slide in after the turn swing (the draw resolution)
	else:
		mode = "foe"
		timer = 0
		foe_clock = 0
		foe_actions = 0
		foe_prev = ""
		_ai_for(p).begin_turn(p)
		_foe_decide(p)
		if spectator and p == 0 and drew > 0:
			_start_deal(before, drew, -TURN_WAIT)   # a spectator's side 0 draws in view: the cards slide in, then its computer plays
	refresh()


func _lift() -> void:
	var picks: Array = marks.duplicate() if not marks.is_empty() else [hand_index]
	var first_id: int = int(engine.state.sides[0].hand[picks[0]])
	var kind: String = engine.state.card_type(first_id)
	var monster: bool = engine.state.is_monster(first_id)
	pending = {"picks": picks, "card": first_id}
	if picks.size() == 1 and not monster and not set_down and (kind == "Magic" or kind == "Ritual"):
		_resolve_held(first_id)
		return
	if picks.size() == 1 and not monster and not set_down and kind == "Equip":
		_begin_hand_equip()         # a face-up equip goes on to one of its own monsters (the field pick), as the hand action does
		return
	mode = "dest"
	# a single card goes to the row its kind takes (duel_hand.gd); a chain goes to the monster row
	zone_row = DuelHand.row_for(monster, kind, set_down) if picks.size() == 1 else DuelHand.ROW_MONSTERS
	zone_index = _first_empty_spell() if zone_row == DuelHand.ROW_SPELLS else _first_empty_zone()


## A face-up magic or ritual resolves where it is held: the card is played from the hand (the card's effect and window).
func _resolve_held(id: int) -> void:
	var before: Array = _field_cards()
	var events: Array = engine.play(0, pending["picks"])
	# a ritual's monster with two guardian stars asks for its star once it is placed (as a placement does: _place)
	for e in events:
		if str(e["kind"]) == "summon" and int(e["side"]) == 0:
			var card: Dictionary = data.card(int(e["id"]))
			var star_one := str(card.get("guardian_star_1", ""))
			var star_two := str(card.get("guardian_star_2", ""))
			if star_two != "" and star_two != star_one:
				star_id = int(e["id"])
				star_zone = int(e["zone"])
	_after_play(events, before, {"card": id, "cards": [id]})


func _first_empty_spell() -> int:
	for i in 5:
		if engine.state.sides[0].traps[i] == null:
			return i
	return 0


func _first_empty_zone() -> int:
	for i in 5:
		if engine.state.sides[0].monsters[i] == null:
			return i
	return 0


func _place() -> void:
	var picks: Array = pending["picks"]
	var id := int(pending["card"])
	var monster: bool = engine.state.is_monster(id)
	var kind: String = engine.state.card_type(id)
	if picks.size() == 1 and not monster and not set_down and (kind == "Magic" or kind == "Ritual"):
		_resolve_held(id)                       # a face-up magic or ritual resolves wherever the cursor is
		return
	if not DuelHand.accepts(monster, kind, set_down, zone_row):
		_refuse("Cannot place there: monsters use the monster row" if monster else "Cannot place there: spells and traps use the spell row")
		return
	if picks.size() == 1 and zone_row == DuelHand.ROW_SPELLS:
		if engine.state.sides[0].traps[zone_index] != null:
			_refuse("That spell zone is taken" if engine.state.sides[0].traps.has(null) else "No empty spell zone")
			return
		var before: Array = _field_cards()
		var set_events: Array = engine.set_back_row(0, int(picks[0]), zone_index, set_down or kind == "Trap")
		_after_play(set_events, before, {"cards": [id]})
		return
	var field_zone := -1
	if engine.state.sides[0].monsters[zone_index] != null:
		field_zone = zone_index
	# the chain's result decides whether the monster needs a star choice
	var ids: Array = []
	if field_zone >= 0:
		ids.append(int(engine.state.sides[0].monsters[field_zone]["id"]))
	for i in picks:
		ids.append(int(engine.state.sides[0].hand[i]))
	var result: Dictionary = engine.resolve_chain(0, ids, 0)
	pending["field_zone"] = field_zone
	pending["dest"] = zone_index
	# the box asks for a star only for a face-up monster with two different stars (a set monster is placed face-down, with no star asked)
	var star_card: Dictionary = data.card(int(result["card"]))
	var star_one := str(star_card.get("guardian_star_1", ""))
	var star_two := str(star_card.get("guardian_star_2", ""))
	if not set_down and engine.state.is_monster(int(result["card"])) and star_two != "" and star_two != star_one:
		# the guardian star is asked once the monster is placed (its placement and any fusion motion show first: _physics_process)
		star_id = int(result["card"])
		star_zone = zone_index
		_finish_play(false)
		return
	_finish_play(false)


func _finish_play(star2: bool) -> void:
	var before: Array = _field_cards()
	var ids: Array = []             # the chain's cards, for the fusion presentation: the field monster first, then the hand picks
	var field_zone := int(pending.get("field_zone", -1))
	if field_zone >= 0 and engine.state.sides[0].monsters[field_zone] != null:
		ids.append(int(engine.state.sides[0].monsters[field_zone]["id"]))
	for i in pending["picks"]:
		ids.append(int(engine.state.sides[0].hand[i]))
	var events: Array = engine.play(0, pending["picks"], field_zone, int(pending.get("dest", -1)), set_down,
			set_down, star2)
	# a monster placed from one hand slot flies from that slot to the field (duel_field_3d.gd begin_flight)
	var dest := int(pending.get("dest", -1))
	if field != null and dest >= 0 and zone_row == 0 and (pending["picks"] as Array).size() == 1 and not events.is_empty():
		field.begin_flight(_record(0, "monsters", dest), DuelHand.place(int(pending["picks"][0])))
	_after_play(events, before, {"cards": ids})


func _after_play(events: Array, before: Array = [], context: Dictionary = {}) -> void:
	marks.clear()
	# the played cards have left the hand: the hand cursor must stay on a card of it (playing the last card leaves it past the end)
	hand_index = clampi(hand_index, 0, maxi(engine.state.sides[0].hand.size() - 1, 0))
	pending = {}
	sound.emit(0x30)
	engine.check_winner()
	if engine.winner >= 0:
		mode = "over"
	else:
		mode = "field"
		zone_index = 0
		zone_row = 0
	set_down = false
	if events.is_empty():
		message = ""
	context["side"] = 0
	fx.play(events, before, context)
	refresh()


func _resolve_attack(target: int) -> void:
	var before: Array = _field_cards()
	var events: Array = engine.attack(0, attacker, target)
	sound.emit(0x30)
	engine.check_winner()
	mode = "over" if engine.winner >= 0 else "field"
	fx.play(events, before, {"side": 0, "attacker": attacker})
	zone_index = attacker
	attacker = -1
	if events.is_empty():
		message = ""
	refresh()


## A refused action: the cannot sound, and the reason on the info line (duel_help.gd) for a few seconds.
func _refuse(reason: String) -> void:
	sound.emit(0x09)
	if help != null:
		help.refuse(reason)


## Confirm on the magic and trap row: an own set magic or equip asks YES or NO to activate it (the prompt starts on YES); any other card
## in the row cannot be activated, and the cannot sound plays.
func _ask_activation() -> void:
	var t = engine.state.sides[0].traps[zone_index]
	if t == null or engine.state.card_type(int(t["id"])) not in ["Magic", "Equip"]:
		_refuse("No card in that zone" if t == null else "Traps trigger on their own")
		return
	pending = {"zone": zone_index, "card": int(t["id"])}
	prompt_choice = 0
	mode = "prompt"


## Back to the field with the cursor on the magic and trap row the activation came from.
func _cancel_prompt() -> void:
	mode = "field"
	zone_row = 1
	zone_index = int(pending.get("zone", zone_index))
	pending = {}


## YES on the prompt: a magic resolves from the row; an equip goes on to a monster of its own side (the monster row's cursor).
func _activate_back_row() -> void:
	var zone := int(pending["zone"])
	var id := int(pending["card"])
	if engine.state.card_type(id) == "Equip":
		var monster := _first_own_monster()
		if monster < 0:
			_refuse("Equip needs one of your monsters")
			_cancel_prompt()
			return
		mode = "equip_pick"
		zone_row = 0
		zone_index = monster
		return
	var before: Array = _field_cards()
	var events: Array = engine.activate_back_row(0, zone)
	if events.is_empty():
		_refuse("Nothing happens with that card now")
		_cancel_prompt()
		return
	_after_play(events, before, {"card": id, "cards": [id]})


## A face-up equip from the hand: the cursor starts on the first own monster the equip can take (the field pick). Nothing it can take
## refuses the card, which stays in the hand.
func _begin_hand_equip() -> void:
	var card := int(pending["card"])
	var monster := -1
	for i in 5:
		var m = engine.state.sides[0].monsters[i]
		if m != null and engine.state.data.can_equip(card, int(m["id"])):
			monster = i
			break
	if monster < 0:
		pending = {}
		mode = "hand"
		_refuse("Equip needs one of your monsters that it can take")
		return
	pending["from_hand"] = true
	mode = "equip_pick"
	zone_row = 0
	zone_index = monster


func _cancel_equip_hand() -> void:
	mode = "hand"
	pending = {}
	sound.emit(8)


## A face-up equip from the hand goes on the chosen monster: the chain (the monster and the equip) places the monster again with its bonus.
func _equip_from_hand() -> void:
	var monster = engine.state.sides[0].monsters[zone_index]
	var id := int(pending["card"])
	if monster == null or not engine.state.data.can_equip(id, int(monster["id"])):
		_refuse("Choose one of your monsters" if monster == null else "That monster cannot take this equip")
		return
	var before: Array = _field_cards()
	var events: Array = engine.play(0, pending["picks"], zone_index, zone_index)
	_after_play(events, before, {"cards": [id]})


## An equip picks its monster: the equip goes on the chosen own monster, or the cannot sound plays and the cursor stays.
func _equip_from_back_row() -> void:
	if bool(pending.get("from_hand", false)):
		_equip_from_hand()
		return
	if engine.state.sides[0].monsters[zone_index] == null:
		_refuse("Choose one of your monsters")
		return
	var before: Array = _field_cards()
	var id := int(pending["card"])
	var events: Array = engine.equip_from_back_row(0, int(pending["zone"]), zone_index)
	if events.is_empty():
		_refuse("That monster cannot take this equip")
		return
	_after_play(events, before, {"cards": [id]})


## The guardian star of the placed monster is set once the choice is made (the monster was placed before the choice: _place).
func _set_star(star2: bool) -> void:
	var zone := star_zone
	star_zone = -1
	if zone >= 0 and engine.state.sides[0].monsters[zone] != null:
		engine.state.sides[0].monsters[zone]["star"] = 1 if star2 else 0
	mode = "field"


func _first_own_monster() -> int:
	for i in 5:
		if engine.state.sides[0].monsters[i] != null:
			return i
	return -1


func _end_turn() -> void:
	engine.end_turn(0)
	_begin_turn(1)


# ---- the opponent's turn ------------------------------------------------------------------------------------------------

## The two-player duel: the sides go back to their real order, the winner is read in that order, and the duel finishes with no result page.
func _two_player_result() -> void:
	if flipped:
		engine.winner ^= 1
	_face(0)
	refresh()                       # the sides are back in their real order: the board is drawn from them again
	# the result screen with no rewards: no opponent, so no starchips and no drop (DuelResult rates only a won duel against a CPU duelist)
	var screen := DuelResult.new()
	screen.stats = engine.result_stats()
	screen.stats["opponent_id"] = -1
	screen.finished.connect(func() -> void:
		outcome = {"winner": engine.winner}
		finished.emit(engine.winner))
	screen.sound.connect(func(effect: int) -> void: sound.emit(effect))
	screen.music.connect(func(id: int) -> void: music.emit(id))
	screen.panels.connect(func(field_x: int, lp_x: int, divisor: int) -> void: slide_panels(field_x, lp_x, divisor))
	add_child(screen)


## The ending of a decided duel (duel_finale.gd) plays first; then the result screen opens.
func _finale_step() -> void:
	if finale == null:
		finale = DuelFinale.new()
		finale.setup(self)
		world.add_child(finale)
		finale.begin()
	if finale.step():
		finale.queue_free()
		finale = null
		_open_result()


## Two-player: the engine keeps the side to act on index 0 (the sides trade places for player 2's turn), so the controls and the board
## work as they do for the player. The sides' records move with them.
func _face(p: int) -> void:
	if flipped == (p == 1):
		return
	var sides: Array = engine.state.sides
	var first = sides[0]
	sides[0] = sides[1]
	sides[1] = first
	# the life point readouts go with their players: the counting of the one who is now at index 0 must not start from the other's total
	var shown: int = shown_life[0]
	shown_life[0] = shown_life[1]
	shown_life[1] = shown
	flipped = p == 1


## The duel is decided: its result screen opens, and the duel finishes when the player leaves that screen.
func _open_result() -> void:
	mode = "result"
	if spectator:
		_spectator_over()
		return
	if two_player:
		_two_player_result()
		return
	var screen := DuelResult.new()
	screen.stats = engine.result_stats()
	screen.stats["opponent_id"] = opponent_id
	screen.finished.connect(func() -> void:
		outcome = screen.result
		outcome["seen"] = engine.seen_cards
		finished.emit(engine.winner))
	screen.sound.connect(func(effect: int) -> void: sound.emit(effect))
	screen.music.connect(func(id: int) -> void: music.emit(id))
	screen.panels.connect(func(field_x: int, lp_x: int, divisor: int) -> void: slide_panels(field_x, lp_x, divisor))
	add_child(screen)


## The computer's next action is decided ahead of its wait: the wait is the action's dwell (FOE_* above) counted from the one before.
func _foe_decide(p: int) -> void:
	foe_next = _ai_for(p).next_action(p)
	var kind := str(foe_next["kind"])
	foe_due = (FOE_DRAW if foe_actions == 0 else 0) + _foe_gap(kind, foe_prev)


## The wait before an action of a kind: the visible actions have their dwell, a noop or a spent zone is no wait.
func _foe_gap(kind: String, prev: String) -> int:
	match kind:
		"play", "set_back":
			return FOE_PLAY_WAIT
		"attack":
			return FOE_ATTACK_WAIT
		"end":
			return FOE_END_AFTER_ATTACK if prev == "attack" else FOE_END_WAIT
		"defense":
			return FOE_DEFENSE_WAIT
		"equip":
			return FOE_EQUIP_WAIT
	return 0


func _foe_step() -> void:
	if timer < foe_due:
		return
	timer = 0
	var p: int = engine.state.turn_side      # the computer's side: 1, or 0 in a spectator match (side 0 is the computer there too)
	var ai = _ai_for(p)
	var action: Dictionary = foe_next
	foe_actions += 1
	if spectator and foe_actions > DuelSpectator.FOE_ACTION_LIMIT:
		action = {"kind": "end"}     # a computer that keeps doing nothing ends its turn (duel_spectator.gd)
	if action["kind"] == "end":
		engine.end_turn(p)
		_begin_turn(p ^ 1)
		return
	if not action["kind"] in ["noop", "spent"]:
		foe_prev = str(action["kind"])
	var before: Array = _field_cards()
	var cards: Array = []           # the card ids the foe plays (a magic or ritual card gets its window)
	var window := 0
	if action["kind"] == "play":
		for i in action["picks"]:
			cards.append(int(engine.state.sides[p].hand[int(i)]))
		if not cards.is_empty() and engine.state.card_type(int(cards[0])) in ["Magic", "Ritual"]:
			window = int(cards[0])
	var events: Array = ai.perform(p, action)
	engine.check_winner()
	if engine.winner >= 0:
		mode = "over"
	var attacker_zone := int(action["zone"]) if action["kind"] == "attack" else -1
	fx.play(events, before, {"side": p, "attacker": attacker_zone, "card": window, "cards": cards})
	refresh()
	if mode == "foe":
		_foe_decide(p)


## The computer of a side: side 0 in a spectator match, else the foe (side 1).
func _ai_for(p: int):
	return spectator_ai if p == 0 else foe_ai


# ---- the spectator match (F3, duel_spectator.gd) -------------------------------------------------------------------------

func _exit_tree() -> void:
	if spectator:
		Engine.time_scale = 1.0     # the Shift fast-forward is the match's own


## A spectator match takes no player input but Esc (or the touch Circle, Q, or a right click), which opens the quit box. The box's
## YES leaves the match, its NO (or Esc again) resumes it; the decided match waits for its confirm. Returns true while the match is
## held by the box, over or left, so the match does not step.
func _spectator_control() -> bool:
	var left := _edge("s_left", [KEY_A, KEY_LEFT])
	var right := _edge("s_right", [KEY_D, KEY_RIGHT])
	var confirm := _edge("s_confirm", [KEY_E, KEY_SPACE, KEY_ENTER]) or _take("confirm")
	var cancel := _edge("s_cancel", [KEY_Q, KEY_ESCAPE, KEY_BACKSPACE]) or _take("cancel")
	if spectator_done:
		return true
	if spectator_over:
		if confirm or cancel:
			_finish_spectator(engine.winner)
		return true
	if quit_box == null:
		if cancel:
			quit_box = DuelQuit.new()
			quit_box.setup(text, sharp)
			world.add_child(quit_box)
			sound.emit(0x30)
			return true
		return false
	var dx := (1 if right else 0) - (1 if left else 0)
	if dx != 0:
		quit_box.choose(1 - quit_box.choice)
		sound.emit(0x2F)
	if confirm:
		if quit_box.choice == 1:
			_finish_spectator(-1)
		else:
			_close_quit()
	elif cancel:
		_close_quit()
	return true


func _close_quit() -> void:
	if quit_box != null:
		quit_box.queue_free()
		quit_box = null


## The match is left (the quit box's YES) or ended with its confirm: the finished signal goes out once; the boot returns to the menus.
func _finish_spectator(winner: int) -> void:
	if spectator_done:
		return
	spectator_done = true
	Engine.time_scale = 1.0
	finished.emit(winner)


## The decided spectator match: the winner's name and MATCH OVER on the info line; no rewards and no result screen.
func _spectator_over() -> void:
	spectator_over = true
	mode = "result"
	refresh()


## The mouse in a spectator match: only the quit box reacts (hovering picks its option, a click confirms it, the right button is Circle).
func _spectator_mouse(event: InputEvent) -> void:
	if quit_box == null:
		return
	var local: Vector2 = (event.position - world.position) / world.scale
	if event is InputEventMouseMotion:
		var hover: int = quit_box.hit(local)
		if hover >= 0 and hover != quit_box.choice:
			quit_box.choose(hover)
			sound.emit(0x2F)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var option: int = quit_box.hit(local)
			if option >= 0:
				quit_box.choose(option)
				mouse_pending["confirm"] = true
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			mouse_pending["cancel"] = true

## The information band of the duel frame (baked by tools/extract.py bake_duel_band): the stone band with the dark bar, from the duel's
## own texture page. The draw list is the reference's: the upper rectangles, the upper quad, the lower rectangles, the foot quad.
const BAND_DIR := "res://assets/screens/duel_frame/"
var band_texture: Texture2D = null
var band_layout: Dictionary = {}


func _draw_band() -> void:
	if band_texture == null:
		var image := Image.load_from_file(BAND_DIR + "band_page.png")
		if image != null:
			band_texture = ImageTexture.create_from_image(image)
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(BAND_DIR + "band.json"))
		band_layout = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	if band_texture == null or band_layout.is_empty():
		return
	var rects: Array = band_layout["rects"]
	var quads: Array = band_layout["quads"]
	for i in [0, 1]:
		_band_rect(rects[i])
	_band_quad(quads[0])
	for i in [2, 3]:
		_band_rect(rects[i])
	_band_quad(quads[1])


func _band_rect(r: Dictionary) -> void:
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = band_texture
	sprite.region_enabled = true
	sprite.region_rect = Rect2(float(r["u"]), float(r["v"]), float(r["w"]), float(r["h"]))
	sprite.position = Vector2(float(r["x"]), float(r["y"]))
	sprite.material = sharp
	board.add_child(sprite)


func _band_quad(q: Dictionary) -> void:
	var c: Array = q["corners"]
	var t: Array = q["uv"]
	var poly := Polygon2D.new()
	# the corners in outline order (top left, top right, bottom right, bottom left); the texels follow their corners
	poly.polygon = PackedVector2Array([Vector2(c[0][0], c[0][1]), Vector2(c[1][0], c[1][1]), Vector2(c[3][0], c[3][1]), Vector2(c[2][0], c[2][1])])
	poly.uv = PackedVector2Array([Vector2(t[0][0], t[0][1]), Vector2(t[1][0], t[1][1]), Vector2(t[3][0], t[3][1]), Vector2(t[2][0], t[2][1])])
	poly.texture = band_texture
	poly.material = sharp
	board.add_child(poly)

## The centre step's arrows (the reference's draw list: 16 x 16 at (110, 120) and (194, 120)).
const ARROW_LEFT_AT := Vector2(110, 120)
const ARROW_RIGHT_AT := Vector2(194, 120)


func _choice_arrow(right: bool, at: Vector2) -> void:
	var texture: Texture2D = DuelCardFace.arrow(right)
	if texture == null:
		return
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = texture
	sprite.position = at
	sprite.material = sharp
	board.add_child(sprite)


## A card in the hand: the two-player duel shows the numbered frame (the card's number in the frame), the one-player duel its face.
func _hand_card_face(id: int, slot := 0) -> Texture2D:
	if two_player:
		return DuelCardFace.numbered(_number_of(id, slot), false)
	return _hand_face(id)


## The centre step's face-down card: its back, numbered in the two-player duel.
func _centre_face(id: int, slot := 0) -> Texture2D:
	if two_player:
		return DuelCardFace.numbered(_number_of(id, slot), true)
	return _back(id, "monsters")


## The number a card shows in the two-player duel: its deck slot (1 to 40, the reference's table index plus 1), or the card id's last two
## digits where the side has no slot for the card.
func _number_of(id: int, slot: int) -> int:
	return slot if slot > 0 else id % 100
