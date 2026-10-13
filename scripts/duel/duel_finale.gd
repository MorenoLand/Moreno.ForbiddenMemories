extends Node2D
## The end of a duel, from the moment it is decided (the duel scene's "over" mode) to the result screen.
## Three endings:
## - Exodia (the holder's five pieces are all in its hand): the five pieces leave the hand and fly to their places on the picture
##   (a cosine ease over 180 frames), sparkle, light up one at a time in the game's display-slot order (top, right, lower right,
##   lower left, left), and a white burst covers the picture before the result.
## - Life points at 0: the loser's readout counts down to 0 (the duel scene does the counting), then a short hold.
## - Deck-out: a short hold after the last card has been dealt (the duel scene deals the cards before the decision).
## Approximated: the sparkles are small gold squares, not the game's effect sprites; the duel music is not played.
## The duel scene removes this node and opens the result screen when step() returns true.

const EXODIA_ADJUSTMENT := 40               # the rank adjustment of an Exodia win (the winner's record)
const DECK_OUT_ADJUSTMENT := -40            # the rank adjustment of a deck-out win
const EXODIA_IDS := [17, 18, 19, 20, 21]    # the five pieces: Exodia, the two arms and the two legs
## The centre of each piece's place on the 320 x 240 picture, by card id.
const POSES := {21: Vector2(160, 32), 20: Vector2(251, 98), 18: Vector2(216, 206), 17: Vector2(104, 206), 19: Vector2(69, 98)}
const FLASH_ORDER := [21, 20, 18, 17, 19]   # the order the pieces light up (the game's display-slot order)
const CARD_SIZE := Vector2(52, 60)          # a piece's face on the picture
const CARD_ORIGIN := Vector2(26, 30)        # the card object's origin is its top-left: its centre is the origin plus half the size
const HAND_ZONE_X := 14                     # the duel scene's hand row (duel_hand.gd): first slot x, slot step and row y
const HAND_ZONE_STEP := 60
const HAND_Y := 146
const FOE_ENTRY := Vector2(160, -40)        # where the foe's pieces come in from (the foe's hand is not drawn)
const FLY_FRAMES := 180
const SPARKLE_FRAMES := 60
const FLASH_STEP := 4                       # frames between one piece lighting and the next
const FLASH_LIFE := 12
const BURST_FRAMES := 24
const HOLD_FRAMES := 30
const LP_WAIT_LIMIT := 600                  # the watchdog for the loser's readout
const EffectCanvas := preload("res://scripts/duel/effects/effect_canvas.gd")
const EffectRegistry := preload("res://scripts/duel/effects/effect_registry.gd")

var host                                    # the duel scene
var burst_program = null                       # the Exodia final effect (program 24) while it runs
var burst_canvas = null
var kind := ""                              # "exodia", "lp" or "deck_out"
var winner := 0
var phase := ""
var t := 0
var pieces: Array = []                      # {node, id, start, end}
var marks: Array = []                       # {node, life, full}: the sparkles, the flashes and the burst
var flash_index := 0
var rng := RandomNumberGenerator.new()


func setup(scene) -> void:
	host = scene
	rng.randomize()


## Reads the decided duel and sets the ending up. Call once, after setup().
func begin() -> void:
	winner = int(host.engine.winner)
	var adjustment := int(host.engine.state.sides[winner].rank["result_adjustment"])
	t = 0
	if adjustment == EXODIA_ADJUSTMENT:
		kind = "exodia"
		_begin_exodia()
	else:
		kind = "deck_out" if adjustment == DECK_OUT_ADJUSTMENT else "lp"
		phase = "wait"


func step() -> bool:
	t += 1
	_tick_marks()
	match phase:
		"wait":
			var loser := winner ^ 1
			var ready := kind == "deck_out" or int(host.shown_life[loser]) == 0
			if (ready and not host.fx.busy()) or t > LP_WAIT_LIMIT:
				_enter("hold")
		"fly":
			var k := clampf(float(t) / FLY_FRAMES, 0.0, 1.0)
			var e := (1.0 - cos(k * PI)) * 0.5      # the cosine ease the game's interpolation uses
			for p in pieces:
				p["node"].position = (p["start"] as Vector2).lerp(p["end"], e)
			if t >= FLY_FRAMES:
				host.sound.emit(0x1D)
				_enter("sparkle")
		"sparkle":
			if t % 3 == 0:
				_sparkle()
			if t >= SPARKLE_FRAMES:
				_enter("flash")
		"flash":
			if flash_index < FLASH_ORDER.size() and t % FLASH_STEP == 0:
				_flash_piece(int(FLASH_ORDER[flash_index]))
				flash_index += 1
			if flash_index >= FLASH_ORDER.size() and marks.is_empty():
				_enter("burst")
		"burst":
			if t == 1:
				host.sound.emit(0x1D)
				if not _start_burst_program():
					_mark(Vector2.ZERO, Vector2(320, 240), Color(1, 1, 1), BURST_FRAMES)
			if burst_program != null:
				burst_canvas.clear()
				burst_program.dispatch(-1)
				burst_canvas.present()
				if burst_program.done:
					burst_canvas.queue_free()
					burst_program = null
					burst_canvas = null
					_enter("hold")
			elif t >= BURST_FRAMES and marks.is_empty():
				_enter("hold")
		"hold":
			if t >= HOLD_FRAMES:
				return true
	return false


## The white burst is the Exodia final effect (program 24) at the five pieces' places, in the display-slot order. False when the
## program is not ported (the burst is then the plain white flash).
func _start_burst_program() -> bool:
	var cards: Array = []
	for id in FLASH_ORDER:
		cards.append(POSES[int(id)] - CARD_ORIGIN)   # program 24 takes the card objects' origins (top-left), as the overlay does
	burst_canvas = EffectCanvas.new()
	add_child(burst_canvas)
	burst_program = EffectRegistry.create(24, burst_canvas, {"cards": cards, "flags": 8, "seed": 24})
	if burst_program == null:
		burst_canvas.queue_free()
		burst_canvas = null
		return false
	burst_canvas.clear()
	burst_program.dispatch(0)
	burst_canvas.present()
	return true


func _enter(next: String) -> void:
	phase = next
	t = 0


## The five pieces leave the holder's hand (its own hand is drawn at the bottom; the foe's come in from the top).
func _begin_exodia() -> void:
	host._clear()
	# the Exodia ending's slide (the routine at 0x80018FEC): the FIELD box to x -64 and the life-point panel to 384, 16 frames
	host.slide_panels(-64, 384, 0x10)
	phase = "fly"
	var hand: Array = host.engine.state.sides[winner].hand
	for id in EXODIA_IDS:
		var start := FOE_ENTRY
		var index := hand.find(id)
		if winner == 0 and index >= 0:
			start = Vector2(HAND_ZONE_X + HAND_ZONE_STEP * index + 26, HAND_Y + 30)
		var texture: Texture2D = host._field_face(id, host.engine.state.make_zone(id), "monsters")
		if texture == null:
			continue
		var sprite := Sprite2D.new()
		sprite.texture = texture
		sprite.material = host.sharp
		sprite.position = start
		sprite.scale = CARD_SIZE / texture.get_size()
		add_child(sprite)
		pieces.append({"node": sprite, "id": id, "start": start, "end": POSES[id]})


func _piece(id: int) -> Dictionary:
	for p in pieces:
		if int(p["id"]) == id:
			return p
	return {}


func _flash_piece(id: int) -> void:
	var p := _piece(id)
	if not p.is_empty():
		p["node"].modulate = Color(1.3, 1.25, 1.0)     # the piece stays lit
	var c: Vector2 = POSES[id]
	_mark(c - CARD_SIZE * 0.6, CARD_SIZE * 1.2, Color(1, 1, 0.8), FLASH_LIFE)
	host.sound.emit(0x17)


func _sparkle() -> void:
	var c := Vector2(rng.randf_range(40.0, 280.0), rng.randf_range(20.0, 220.0))
	_mark(c, Vector2(3, 3), Color(1.0, 0.92, 0.45), 16)


func _mark(at: Vector2, size_: Vector2, colour: Color, life: int) -> void:
	var r := ColorRect.new()
	r.position = at
	r.size = size_
	r.color = colour
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(r)
	marks.append({"node": r, "life": life, "full": life})


func _tick_marks() -> void:
	var i := marks.size() - 1
	while i >= 0:
		var m: Dictionary = marks[i]
		m["life"] = int(m["life"]) - 1
		var node: CanvasItem = m["node"]
		if int(m["life"]) <= 0:
			node.queue_free()
			marks.remove_at(i)
		else:
			node.modulate.a = float(m["life"]) / float(m["full"])
		i -= 1
