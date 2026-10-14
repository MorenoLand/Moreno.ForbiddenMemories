extends Node2D
## The presentation of a duel's events, drawn over the field (the duel scene adds it above the board).
## The engine has already changed its state when an event list arrives, so this layer holds the field as it was before (shown()),
## plays the events one beat at a time, and hands the field back to the scene (host.refresh) when the last beat has ended. While
## busy() the scene takes no input, and a life point readout waits for its figure to land (holds_life()).
##
## Presented: the battle (the attacker's lunge toward the defender, the clash flash and sparks, the defence-position reveal, the
## damage figure over the loser, the destruction of each loser), a direct hit (the attacker rises toward the life point readout,
## the readout flashes and shows the damage), trap springing (the trap turns over and rises), the Swords of Revealing Light lock
## (a banner, then a frame and the turns left over the locked row), fusion (the cards fly together and gather into a flash), equip
## (the equip card flies onto its monster, then the bonus figure), stat changes, terrain change (a flash and the terrain's name),
## discards, and the magic card window: the card enlarged in the middle of the field with a per-group effect.
##
## The game draws these effects as GTE polygons from the duel effects overlay. Here each one is an approximation built from the same
## kinds of primitive (rays, rings, particles, flashes, the card UI's digit sprites). Frame counts follow the states that call them
## (the field's 14-frame clash flash, the 16-frame lunge). A terrain change swaps the FIELD box's name (duel_field_3d.gd's set_terrain_plate)
## and not the board: the game loads the board's textures once, for the terrain the duel opens with.

const DuelEffects := preload("res://scripts/duel/duel_effects.gd")
const EffectCanvas := preload("res://scripts/duel/effects/effect_canvas.gd")   # the picture of a ported effect program (effects/)
const EffectRegistry := preload("res://scripts/duel/effects/effect_registry.gd")
const CardView := preload("res://scripts/ui/card_view.gd")   # split_ink: a card view ink piece's texels laid over and subtracted

const CARD_UI := "res://assets/screens/card_ui/"
const CENTRE := Vector2(160, 108)                # the game's centre line (108) and the picture's middle
const CENTRE_AT := Vector2(134, 90)              # the top-left of a card lifted to the centre step (duel_scene.gd CENTRE_AT)
const LP_AT := {0: Vector2(277, 45), 1: Vector2(277, 19)}          # each side's life point readout (duel_scene.gd's digit positions)
const LP_RECT := {0: Rect2(270, 40, 50, 16), 1: Rect2(270, 14, 50, 16)}
const PICTURE := Rect2(0, 0, 320, 240)
const DIGIT_WIDTH := 6.0
const WINDOW_FRAMES := 88                        # the magic card window (the card-use sequence): lift 24, the view swings in 16, holds 32, fades 16
const WINDOW_LIFT := 24
const WINDOW_HOLD := 32
const CLOSE_UP_TURN := 16                         # the card view swings in from edge-on over this many frames
const CLOSE_UP_FADE := 16
const RITUAL_STAND_FRAMES := 36                 # the monster rises into its zone after the view (the reference's field shows it at about +528)
const RITUAL_VIEW_HOLD := 24                   # the ritual monster's close-up holds this long (the reference's summon view)
const WINDOW_SIZE := Vector2(140, 196)            # the card view: the card's box (the Password reveal's card size, the reference close-up)
const WINDOW_CENTRE := Vector2(160, 120)          # the card view's centre on the picture (the reference close-up: its box spans y 22 to 218)
const HAND_SIZE := Vector2(52, 60)                # a hand card's face (the centre step's card)
const WHITE := Color(1.0, 1.0, 1.0)
const GREEN := Color(0.5, 1.0, 0.6)
const RED := Color(1.0, 0.4, 0.35)
const GOLD := Color(1.0, 0.9, 0.4)
const BLUE := Color(0.6, 0.8, 1.0)
const PURPLE := Color(0.7, 0.4, 1.0)
const CARD_RECT_SIZE := Vector2(51, 59)          # a card on the field (duel_field_3d.gd's CARD_QUAD)

var host                                          # the duel scene (duel_scene.gd)
var field = null                                  # the 3D board (duel_field_3d.gd)
var sharp: ShaderMaterial
var active := false
var visible_entries: Array = []                   # the field's cards while a sequence runs (the entries the field shows)
var held_off: Dictionary = {}                       # record -> entry taken off the field while it flies
var after_entries: Array = []                     # the field's cards as the engine left them
var beats: Array = []                             # {start: Callable, hold: int}
var beat_running := false
var beat_t := 0
var beat_hold := 0
var beat_budget := 0
var ops: Array = []                               # the things drawn now (see _op)
var life_hold: Array = [false, false]
var locks: Dictionary = {}                        # side -> Rect2 of the monster row locked by Swords
var battle_running := false                       # a battle sequence plays: the FIELD box and the life-point panel are off the picture
var battle_view := false                         # a battle has the view on the hand view (the field view gives way for the battle's length)
var battle_view_t := 0                           # ticks since the battle's swing to the hand view began
var view_hold := false                          # the field view is held on a trap's zone (the pan of an attack into a trap): the cursor does not refocus
const BATTLE_VIEW_HOLD := 184                    # the reference: the field view comes back about 184 frames after the battle starts (its swing out at the start)
var rng := RandomNumberGenerator.new()
var card_views: Dictionary = {}                   # card id -> the close-up texture (_card_view)
var card_ui_layout: Dictionary = CardView.load_ui()   # the card_ui pieces' layout (the close-up's pieces, CardView.card_picture)
var hand_hidden := false                          # the hand is not drawn while a card-use sequence runs (the magic window)
var programs: Array = []                         # the ported effect programs running: {program, canvas} (effects/effect_registry.gd)
var object_state: Dictionary = {}                 # record -> the card object state the programs set (CardObjects; the field draws it)
var objects_channel                               # the card-object channel every program gets as context.objects
var plays_total := 0                              # debug: sequences started and finished (debug_state)
var finishes_total := 0


func setup(scene, duel_field, material: ShaderMaterial) -> void:
	host = scene
	field = duel_field
	sharp = material
	rng.seed = 20260
	objects_channel = CardObjects.new(self)
	if field != null:
		field.object_state = object_state


## The card-object channel of the effect programs (the overlay's card display objects, by record). A program reads a row's occupied
## cards (rows), each card's position, spin and brightness, and sets them: the field draws each posed card at its state until the
## sequence ends. The state is kept here when there is no field (the checks of the effect tests).
class CardObjects extends RefCounted:
	const NEUTRAL := Vector3i(128, 128, 128)
	var owner                                    # the duel_fx node

	func _init(fx) -> void:
		owner = fx

	## The occupied cards of a side's row ("monsters" or "traps"), in zone order: the card records the overlay's collector returns.
	func rows(side: int, row: String) -> Array:
		var out: Array = []
		for zone in 5:
			var record: int = owner._rec(side, row, zone)
			if not owner._entry_in(owner.visible_entries, record).is_empty():
				out.append(record)
		return out

	## Every occupied card on the board (both sides' monsters and traps unless monsters_only), in side, row and zone order.
	func field_cards(monsters_only: bool = false) -> Array:
		var out: Array = []
		for side in 2:
			out.append_array(rows(side, "monsters"))
			if not monsters_only:
				out.append_array(rows(side, "traps"))
		return out

	func size(record: int) -> Vector2i:
		return _state(record)["size"]

	func set_size(record: int, to: Vector2i) -> void:
		_state(record)["size"] = to

	## The board tint (the overlay's global colour for the board's drawing; 128 is neutral).
	func set_tint(rgb: Vector3i) -> void:
		owner.set_board_tint(rgb)

	func _state(record: int) -> Dictionary:
		if not owner.object_state.has(record):
			owner.object_state[record] = {"pos": owner._board_at(record), "spin": Vector3i.ZERO, "brightness": NEUTRAL, "shown": true, "size": Vector2i(4096, 4096)}
		return owner.object_state[record]

	func position(record: int) -> Vector3i:
		return _state(record)["pos"]

	func move(record: int, to: Vector3i) -> void:
		_state(record)["pos"] = to

	func spin(record: int) -> Vector3i:
		return _state(record)["spin"]

	func turn(record: int, bytes: Vector3i) -> void:
		_state(record)["spin"] = bytes

	func brightness(record: int) -> Vector3i:
		return _state(record)["brightness"]

	func set_brightness(record: int, rgb: Vector3i) -> void:
		_state(record)["brightness"] = rgb

	func shown(record: int) -> bool:
		return bool(_state(record)["shown"])

	## Shows or hides a card object. Showing it again also puts its field entry back (a ritual's tribute leaves the field with the window
	## and comes back when its flight starts).
	func set_shown(record: int, on: bool) -> void:
		_state(record)["shown"] = on
		if on:
			owner._unhide(record)


## A card object's board point in game units: its grid cell at the card height (0, 0, 0 without a field).
## The board tint the effect programs set (the field draws the board with it; reset when the sequence ends).
func set_board_tint(rgb: Vector3i) -> void:
	if field != null:
		field.set_board_tint(rgb)


## The board point of a card object (see CardObjects), in game units.
func _board_at(record: int) -> Vector3i:
	if field == null:
		return Vector3i.ZERO
	var p: Vector3 = field.board_point(record)
	return Vector3i(roundi(p.x), roundi(p.y), roundi(p.z))


## True while a sequence plays: the scene takes no input.
func hides_hand() -> bool:
	return hand_hidden


func busy() -> bool:
	return active


## A readout of the queue for the soak test's stall notes: the sequence's clock, the beat, the ops and each running program.
func debug_state() -> String:
	var progs: Array = []
	for entry in programs:
		var program = entry["program"]
		progs.append("id %d done %s impact %s banner %s stage %s nonblocking %s" % [int(entry["id"]), str(program.get("done")),
				str(program.get("impact")), str(program.get("_banner")), str(program.get("stage")), str(bool(entry.get("nonblocking", false)))])
	var kinds: Array = []
	for op in ops:
		kinds.append("%s t%d/%d" % [str(op["kind"]), int(op["t"]), int(op["frames"]) + int(op["delay"])])
	return "active %s, sequence %d, plays %d, finishes %d, beats left %d, beat running %s (%d of %d), ops %s, programs [%s]" % [str(active),
			sequence_t, plays_total, finishes_total, beats.size(), str(beat_running), beat_t, beat_hold, str(kinds.slice(0, 6)), "; ".join(progs)]


## The field entries the scene should show: the held ones during a sequence, the given ones otherwise.
func shown(entries: Array) -> Array:
	return visible_entries if active else entries


## True while a side's life point readout waits for its figure to land.
func holds_life(side: int) -> bool:
	return active and bool(life_hold[side])


## Plays an engine event list. `before` is the field's entries before the engine call (the scene's _field_cards()). `context` says
## who acted: side, attacker (the zone that attacked), card (a magic card whose window is shown), cards (the hand's card ids a fusion
## used) and the events' own order is kept.
func play(events: Array, before: Array, context: Dictionary) -> void:
	var window := int(context.get("card", 0)) > 0
	if events.is_empty() and not window:
		return
	if not active:
		sequence_t = 0
		visible_entries = before.duplicate()
		held_off.clear()
	after_entries = host._field_cards()
	_build(events, context)
	plays_total += 1
	active = true
	# the battle presentation takes the FIELD box and the life-point panel off the picture until it ends (duel_scene.gd slides them)
	for e in events:
		if str(e["kind"]) == "battle":
			battle_running = true
	_show()


# ---- the beat queue --------------------------------------------------------------------------------------------------------

## The watchdog: no sequence may keep input blocked for longer than SEQUENCE_BUDGET frames, and no beat longer than BEAT_BUDGET.
const SEQUENCE_BUDGET := 1200     # a ritual summon (the window and the apply, effect 22) runs past 600 frames
const BEAT_BUDGET := 240
const RITUAL_APPLY_BUDGET := 600   # a ritual's apply waits for its impact (about 450 frames in the reference's timing)
const RITUAL_APPLY_AT := 64        # the frame of the window at which the ritual's apply starts (its portal is neutral at about +96)
const RITUAL_VIEW_DELAY := 24      # the ritual monster's close-up follows the impact by this many frames (the reference: +456 at a +432 white)
var sequence_t := 0


func tick() -> void:
	if battle_view:
		# the battle's view returns on the reference's timing, whatever the presentation's beats still hold (see BATTLE_VIEW_HOLD)
		battle_view_t += 1
		if battle_view_t >= BATTLE_VIEW_HOLD:
			battle_view = false
			host.end_battle_view()
	if active:
		sequence_t += 1
		if sequence_t > SEQUENCE_BUDGET:
			push_warning("duel_fx: sequence exceeded %d frames; forcing the queue clear" % SEQUENCE_BUDGET)
			_finish()
			queue_redraw()
			return
		_advance_programs()
		if beat_running:
			beat_t += 1
			_advance()
			if beat_t >= beat_hold and _beat_ops_left() == 0 and _blocking() == 0:
				beat_running = false
			elif beat_t > beat_hold + beat_budget:
				push_warning("duel_fx: beat exceeded its budget; dropping its ops")
				ops.clear()
				beat_running = false
		if not beat_running and not beats.is_empty():
			var beat: Dictionary = beats.pop_front()
			beat_running = true
			beat_t = 0
			beat_hold = int(beat["hold"])
			beat_budget = int(beat.get("budget", BEAT_BUDGET))
			var start: Callable = beat["start"]
			start.call()
		if not beat_running and beats.is_empty() and _blocking() == 0:
			_finish()
	for side in locks.keys():
		if int(host.engine.state.sides[side].swords_turns) <= 0:
			locks.erase(side)
			_release_swords(side)
	queue_redraw()


func _beat(start: Callable, hold: int, budget: int = BEAT_BUDGET) -> void:
	beats.append({"start": start, "hold": hold, "budget": budget})


## The ops that keep the beat going: the held ones (a card that stays on the picture past its beat, e.g. the battle's close-ups) do not.
func _beat_ops_left() -> int:
	var count := 0
	for op in ops:
		if not bool(op.get("held", false)):
			count += 1
	return count


func _finish() -> void:
	finishes_total += 1
	active = false
	battle_running = false
	battle_view = false
	view_hold = false
	beats.clear()
	beat_running = false
	sequence_t = 0
	hand_hidden = false
	ops.clear()
	# the field's own programs (nonblocking: the Swords field effect) outlive the sequence; the others are freed with it
	var kept := _nonblocking_entries()
	var kept_canvases: Array = []
	for entry in kept:
		kept_canvases.append(entry["canvas"])
	programs = kept
	for child in get_children():
		if not child in kept_canvases:
			child.queue_free()
	visible_entries = []
	held_off.clear()
	life_hold = [false, false]
	if field != null:
		field.clear_objects()
	object_state.clear()
	host.refresh()


## Starts a ported effect program (effects/) at the request's phase, on its own picture above the board. Its frames run in tick()
## until its finish flag, and the beat that started it waits for it. Returns false when the program is not ported.
func _program(id: int, phase: int, context: Dictionary) -> bool:
	var picture := EffectCanvas.new()
	add_child(picture)
	if objects_channel == null:
		objects_channel = CardObjects.new(self)
	context["objects"] = objects_channel
	var program = EffectRegistry.create(id, picture, context)
	if program == null:
		picture.queue_free()
		return false
	picture.clear()
	program.dispatch(phase)
	picture.present()
	# a stage the game sets once the program's impact has landed (the terrain change's -2, after its package loads)
	programs.append({"id": id, "program": program, "canvas": picture, "stage": int(context.get("stage_on_impact", 0)),
		"nonblocking": bool(context.get("nonblocking", false)), "release_at_impact": bool(context.get("release_at_impact", false)),
		"side": int(context.get("side", -1))})
	return true


## The running programs that hold the sequence (all but the nonblocking ones).
func _blocking() -> int:
	var count := 0
	for entry in programs:
		if not _releases(entry):
			count += 1
	return count


## A program that does not hold the sequence: a nonblocking one, or one that releases at its impact once the impact is raised (a ritual's
## apply: the summon follows the impact while the apply's picture fades out).
func _releases(entry: Dictionary) -> bool:
	if bool(entry.get("nonblocking", false)):
		return true
	return bool(entry.get("release_at_impact", false)) and bool(entry["program"].impact)


## The programs that outlive the sequence: the nonblocking ones (the Swords field effect), and an apply still fading after its impact.
func _nonblocking_entries() -> Array:
	var out: Array = []
	for entry in programs:
		if _releases(entry) and not bool(entry["program"].done):
			out.append(entry)
	return out


## The Swords field effect of a side ends when its lock ends: its program is switched off (the overlay's disabling of the slot).
func _release_swords(side: int) -> void:
	for entry in programs:
		if int(entry.get("side", -1)) == side and entry["program"].has_method("release"):
			entry["program"].release()


## One frame of every running program: the frame step, then the picture is shown; a finished program's picture is freed.
func _advance_programs() -> void:
	for entry in programs.duplicate():
		var program = entry["program"]
		var picture = entry["canvas"]
		if int(entry.get("stage", 0)) != 0 and program.impact:
			program.sticky_phase = int(entry["stage"])
			entry["stage"] = 0
		picture.clear()
		program.dispatch(-1)
		picture.present()
		if entry.has("on_impact") and program.impact:
			var hook: Callable = entry["on_impact"]
			entry.erase("on_impact")
			hook.call()
		if program.done:
			picture.queue_free()
			programs.erase(entry)


## Adds an op: kind is "card", "flash", "rays", "ring", "particles", "digits" or "banner"; frames is its length, delay the frames
## before it starts. Its anim is a Callable taking the fraction p (0 to 1) and returning a Dictionary of the props it uses.
func _op(kind: String, frames: int, delay: int, extra: Dictionary) -> Dictionary:
	var op := {"kind": kind, "frames": maxi(frames, 1), "delay": delay, "t": 0}
	op.merge(extra)
	ops.append(op)
	return op


func _advance() -> void:
	var keep: Array = []
	for op in ops:
		op["t"] = int(op["t"]) + 1
		var t: int = op["t"]
		var delay: int = op["delay"]
		var frames: int = op["frames"]
		if op["kind"] == "particles" and t > delay:
			_step_particles(op)
		if op["kind"] == "banner" and t >= delay:
			var p := clampf(float(t - delay) / float(frames), 0.0, 1.0)
			var anim: Callable = op["anim"]
			var props: Dictionary = anim.call(p)
			var node: CanvasItem = op["node"]
			node.modulate.a = float(props.get("alpha", 1.0))
		if t >= delay + frames:
			if op["kind"] == "banner" and is_instance_valid(op["node"]):
				op["node"].queue_free()
			if op.has("done"):
				var done: Callable = op["done"]
				done.call()
		else:
			keep.append(op)
	ops = keep


func _step_particles(op: Dictionary) -> void:
	var points: Array = op["points"]
	var vels: Array = op["vels"]
	var gather = op.get("gather", null)
	for i in points.size():
		var v: Vector2 = vels[i]
		if gather != null:
			v = (v + (gather - points[i]) * float(op["pull"])) * float(op["drag"])
		else:
			v.y += float(op["gravity"])
		vels[i] = v
		points[i] = points[i] + v


# ---- entries ---------------------------------------------------------------------------------------------------------------

## The face of a card for a ghost: the scene's composed face with a fresh zone for the stats (the ghost has no zone of its own).
func _face(id: int) -> Texture2D:
	return host._field_face(id, host.engine.state.make_zone(id), "monsters")


func _rec(side: int, row: String, zone: int) -> int:
	return host._record(side, row, zone)


func _show() -> void:
	if field != null:
		field.set_cards(visible_entries)


func _entry_in(list: Array, record: int) -> Dictionary:
	for entry in list:
		if int(entry["record"]) == record:
			return entry
	return {}


func _texture_of(entry: Dictionary) -> Texture2D:
	return entry["back"] if bool(entry.get("face_down", false)) else entry["texture"]


## Takes a card's entry off the shown field while it flies (_unhide gives it back).
func _hide(record: int) -> void:
	for i in visible_entries.size():
		if int(visible_entries[i]["record"]) == record:
			held_off[record] = visible_entries[i]
			visible_entries.remove_at(i)
			_show()
			return


func _unhide(record: int) -> void:
	if held_off.has(record):
		visible_entries.append(held_off[record])
		held_off.erase(record)
		_show()


func _drop(record: int) -> void:
	for i in visible_entries.size():
		if int(visible_entries[i]["record"]) == record:
			visible_entries.remove_at(i)
			_show()
			return


func _add(record: int) -> void:
	var entry := _entry_in(after_entries, record)
	if entry.is_empty() or not _entry_in(visible_entries, record).is_empty():
		return
	visible_entries.append(entry)
	_show()


## The shown entry of a record takes its state after the engine call (a reveal, a turn to defence).
func _replace(record: int) -> void:
	var fresh := _entry_in(after_entries, record)
	for i in visible_entries.size():
		if int(visible_entries[i]["record"]) == record:
			if fresh.is_empty():
				visible_entries.remove_at(i)
			else:
				visible_entries[i] = fresh
			_show()
			return


## The card's box on the screen. duel_field_3d.gd resolves a record through the side being viewed, so the record's own side is
## viewed for the moment of the call.
func _rect(record: int) -> Rect2:
	if field == null:
		return Rect2(CENTRE - CARD_RECT_SIZE / 2.0, CARD_RECT_SIZE)
	var was: int = field.view_side
	field.view_side = 1 if record >= 20 else 0
	var box: Rect2 = field.card_box(record)
	field.view_side = was
	return box


func _row_rect(side: int) -> Rect2:
	var out := Rect2()
	for i in 5:
		var box := _rect(_rec(side, "monsters", i))
		out = box if i == 0 else out.merge(box)
	return out


# ---- building the beats ----------------------------------------------------------------------------------------------------

func _build(events: Array, context: Dictionary) -> void:
	var card := int(context.get("card", 0))
	if card > 0:
		var also := Callable()
		if DuelEffects.is_ritual(card) and events.any(func(e): return str(e["kind"]) == "summon"):
			# the tributes leave the picture with the card's window (the reference's ritual shows none of them until the apply's flight)
			for record in _ritual_tributes(events, int(context.get("side", 0))):
				_hide(record)
				objects_channel.set_shown(record, false)
			also = _ritual_start(card, events, int(context.get("side", 0)))
		_window(card, int(context.get("side", 0)), also)
	# a monster removal (the removal cards and Crush Card): effect 15 over the removed monsters, then their fragments (effect 11)
	if card > 0 and (DuelEffects.REMOVAL_TYPE.has(card) or card == DuelEffects.CRUSH_CARD):
		_removal(card, events)
	var i := 0
	while i < events.size():
		var kind := str(events[i]["kind"])
		if kind == "trap" and int(context.get("attacker", -1)) >= 0:
			# an attack into a trap: the attacker's removal comes with the attack (the engine lists it right after the trap)
			var gone: Array = []
			var j := i + 1
			while j < events.size() and (str(events[j]["kind"]) == "destroyed" or str(events[j]["kind"]) == "remove"):
				gone.append(events[j])
				j += 1
			_attack_trap(events[i], gone)
			i = j
			continue
		if (kind == "destroyed" or kind == "remove") and not (card > 0 and DuelEffects.is_ritual(card)):
			# a ritual's tributes left the picture with its window and the apply (no destruction of their own)
			var group: Array = []
			while i < events.size() and (str(events[i]["kind"]) == "destroyed" or str(events[i]["kind"]) == "remove"):
				group.append(events[i])
				i += 1
			_destroy(group)
			continue
		_event(events[i], events, i, context)
		i += 1


func _event(e: Dictionary, events: Array, index: int, ctx: Dictionary) -> void:
	var side := int(e.get("side", ctx.get("side", 0)))
	match str(e["kind"]):
		"battle":
			_battle(e, ctx)
		"trap":
			_trap(e)
		"direct":
			_direct(e, ctx)
		"lp":
			_life(int(e["side"]), int(e["amount"]), e)
		"summon":
			# a face-up summon has the light beam and flash; a set monster just appears (no beam in the reference placement). A monster
			# that comes back from an equip or a fusion is shown by that presentation, so it only appears here.
			var after_chain := index > 0 and str(events[index - 1]["kind"]) in ["equip", "fusion"]
			if DuelEffects.is_ritual(int(ctx.get("card", 0))):
				_ritual_summon(_rec(side, "monsters", int(e["zone"])), int(e["id"]))
			elif bool(e.get("face_down", false)) or after_chain:
				_appear(_rec(side, "monsters", int(e["zone"])))
			else:
				_placed(_rec(side, "monsters", int(e["zone"])))
		"set_trap", "set_back":
			_appear(_rec(side, "traps", int(e["zone"])))
		"reveal", "defense_off":
			_turn(_rec(side, "monsters", int(e["zone"])))
		"stat":
			_stat(_rec(side, "monsters", int(e["zone"])), int(e["delta"]))
		"swords":
			_swords(side)
		"terrain":
			_terrain(int(e["value"]))
		"fusion":
			_fusion(e, ctx)
		"equip":
			_equip(e, events, index, ctx)
		"discard":
			_discard(int(e["id"]))


## A ritual's monster, after the apply's impact: its full-card close-up (the card view with its ATK and DEF) swings in, then the monster
## stands in its zone (the reference shows no beam for a ritual summon; the guardian star is asked once it stands).
func _ritual_summon(record: int, id: int) -> void:
	var view := func() -> void:
		_close_up(_card_view(id), RITUAL_VIEW_DELAY, CLOSE_UP_TURN, RITUAL_VIEW_HOLD, CLOSE_UP_FADE)
	_beat(view, RITUAL_VIEW_DELAY + CLOSE_UP_TURN + RITUAL_VIEW_HOLD + CLOSE_UP_FADE)
	var stand := func() -> void:
		_add(record)
	_beat(stand, RITUAL_STAND_FRAMES)


## A card placed on the field: its light beam and screen flash (effect 1) at the placement's point (x 128, y the card's top + 30).
## The card appears with the beam's start, as the placement shows it.
func _placed(record: int) -> void:
	var start := func() -> void:
		_add(record)
		if record >= 0:
			# the beam and flash sit on the placed card: its box's centre (the card's own projected place, so the zoomed view places it right)
			var box := _rect(record)
			_program(1, 0, {"x": int(box.position.x + box.size.x / 2.0), "y": int(box.position.y) + 30, "flags": 8, "seed": record + 1})
	_beat(start, 10)


func _appear(record: int) -> void:
	var start := func() -> void:
		_add(record)
	_beat(start, 10)


func _turn(record: int) -> void:
	var start := func() -> void:
		_turn_card(record, 0)
	_beat(start, 22)


## A card turns over where it stands: the shown face is swapped for the engine's face at the middle of the turn.
func _turn_card(record: int, delay: int) -> void:
	var shown_entry := _entry_in(visible_entries, record)
	var fresh := _entry_in(after_entries, record)
	if shown_entry.is_empty() or fresh.is_empty():
		return
	var a := _texture_of(shown_entry)
	var b := _texture_of(fresh)
	if a == b:
		_replace(record)
		return
	var anim := func(p: float) -> Dictionary:
		return {"sx": absf(cos(p * PI))}
	var done := func() -> void:
		_replace(record)
	_card(a, _rect(record), 20, delay, anim, b, 0.5, done)


## The battle, as the reference shows it when the monsters are not 3D (frames from the confirm, the reference's pictures): the attacker
## lunges on the field; the two battle card close-ups (140 x 196, the attacker on the left and the defender on the right) turn in and
## stand; a white flash covers the picture; the result's burst and figure land on the card that loses life or is destroyed (the
## attack's hit, effect 2); the card that is destroyed breaks up (the tile effect 3 over its close-up); the close-ups fade and the
## field view comes back (BATTLE_VIEW_HOLD).
const BATTLE_LUNGE_AT := 10
const BATTLE_CARDS_AT := 44
const BATTLE_FLASH_AT := 88
const BATTLE_BURST_AT := 104
const BATTLE_DESTROY_AT := 128
const BATTLE_CLOSE_AT := 168
const BATTLE_END_AT := 200
const BATTLE_CARD_TURN := 16
const BATTLE_CARD_RECTS := [Rect2(10, 22, 140, 196), Rect2(170, 22, 140, 196)]     # the attacker (left), the defender (right)
const BATTLE_POINTS := [Vector2(80, 120), Vector2(240, 120)]                       # each card's point for the effects (the card + (70, 98))


func _battle(e: Dictionary, ctx: Dictionary) -> void:
	var side := int(ctx.get("side", 0))
	var ra := _rec(side, "monsters", int(e["attacker"]))
	var rt := _rec(1 - side, "monsters", int(e["target"]))
	var r := int(e["result"])
	var star := int(e.get("star", 0))
	# which cards leave the field: a -1 result destroys both; a win destroys the defender; a loss destroys the attacker unless the
	# defender is in defence position (then the attacker only loses life points)
	var defender_leaves := r > 0 or r == -1
	var attacker_leaves := r == -1 or (r < -1 and not bool(e.get("target_defense", false)))
	var ids := [int(e.get("attacker_id", 0)), int(e.get("target_id", 0))]
	var lunge := func() -> void:
		if field != null:
			field.lunge(ra, rt)              # the attacker moves toward the defender (the field's own lunge)
	var swing := func() -> void:
		battle_view = true
		battle_view_t = 0
		if field != null:
			field.swing_out()
	var turned := func() -> void:
		_turn_card(rt, 0)                # a defender still face-down is shown face-up when the battle reveals it
	var cards := func() -> void:
		_battle_cards(ids, attacker_leaves, defender_leaves)
	var gather := func() -> void:
		# the guardian star bonus: the star card's gather (effect 14), the attacker's point for a bonus to it, else the defender's
		if star > 0:
			_gather_card(ids[0], BATTLE_POINTS[0], 0)
		else:
			_gather_card(ids[1], BATTLE_POINTS[1], 1)
	var burst := func() -> void:
		_battle_burst(r, attacker_leaves, defender_leaves, bool(e.get("target_defense", false)))
	var destroy := func() -> void:
		_battle_destroy(ids, ra, rt, attacker_leaves, defender_leaves, e)
	_beat(swing, BATTLE_LUNGE_AT)
	_beat(lunge, BATTLE_CARDS_AT - BATTLE_LUNGE_AT)
	_beat(cards, BATTLE_FLASH_AT - BATTLE_CARDS_AT)
	_beat(_battle_flash, BATTLE_BURST_AT - BATTLE_FLASH_AT)
	if star != 0:
		_beat(gather, 0)
	_beat(turned, 0)
	_beat(burst, BATTLE_DESTROY_AT - BATTLE_BURST_AT)
	_beat(destroy, BATTLE_CLOSE_AT - BATTLE_DESTROY_AT)
	_beat(func() -> void: pass, BATTLE_END_AT - BATTLE_CLOSE_AT)


## The two close-ups of the battle: each card's picture turns in over BATTLE_CARD_TURN frames and stands. A card that leaves is taken off
## by its own tile effect at BATTLE_DESTROY_AT; the others fade out at BATTLE_CLOSE_AT.
func _battle_cards(ids: Array, attacker_leaves: bool, defender_leaves: bool) -> void:
	for i in 2:
		var id := int(ids[i])
		if id <= 0:
			continue
		var leaves := attacker_leaves if i == 0 else defender_leaves
		var total := (BATTLE_DESTROY_AT - BATTLE_CARDS_AT) if leaves else (BATTLE_CLOSE_AT - BATTLE_CARDS_AT)
		var anim := func(p: float) -> Dictionary:
			var f := p * float(total)
			var s := sin(clampf(f / float(BATTLE_CARD_TURN), 0.0, 1.0) * PI * 0.5)
			var a := 1.0 if leaves else 1.0 - clampf((f - float(total - BATTLE_CARD_TURN)) / float(BATTLE_CARD_TURN), 0.0, 1.0)
			return {"sx": maxf(s, 0.02), "alpha": a}
		_card(_card_view(id), BATTLE_CARD_RECTS[i], total, 0, anim, null, 2.0, Callable())
		ops.back()["held"] = true     # the close-up stays through the beats that follow (the beat's hold ends the beat)


## The white flash over the picture: it rises and falls within 16 frames (between the cards and the burst).
func _battle_flash() -> void:
	var anim := func(p: float) -> Dictionary:
		return {"alpha": sin(clampf(p, 0.0, 1.0) * PI)}
	_op("flash", 16, 0, {"rect": PICTURE, "colour": WHITE, "anim": anim, "travel": Vector2.ZERO})


## The burst and the figure of the battle's result: effect 2 at the point of the card that loses life (the defender for a win, the
## attacker for a loss), the centre for a mutual destruction (number 0). A result of 0 has no figure.
func _battle_burst(r: int, attacker_leaves: bool, defender_leaves: bool, target_defense: bool) -> void:
	if r == 0:
		return
	var at := BATTLE_POINTS[1] if r > 0 else BATTLE_POINTS[0]
	var number := r
	if r == -1:
		at = Vector2(160, 120)
		number = 0
	elif r > 0 and target_defense:
		number = 0                  # a defence-position defender is destroyed without life points lost: the burst has no figure
	_program(2, maxi(mini(absi(number) / 1000, 2) + 3, 0) if number != 0 else 6, {"x": int(at.x), "y": int(at.y), "number": number, "seed": number + 2})
	if attacker_leaves or defender_leaves:
		_rays(at, 10, 4.0, 14.0, WHITE, 14, 0)


## The guardian star gather for the card (effect 14, variant the card's level less one) at its point.
func _gather_card(id: int, point: Vector2, side_index: int) -> void:
	if id <= 0 or host == null:
		return
	var level := int(host.engine.state.data.card(id).get("level", 1)) & 15
	_program(14, maxi(level - 1, 0), {"x": int(point.x), "y": int(point.y), "seed": id + 14 + side_index})


## The destruction of the battle's loser(s): effect 3 over the card's close-up (its picture as the battle shows it). A card in defence
## position is drawn with the defence phase.
func _battle_destroy(ids: Array, ra: int, rt: int, attacker_leaves: bool, defender_leaves: bool, e: Dictionary) -> void:
	# the leaving cards are off the field from here (the destroyed events after the battle then find nothing to take off)
	if attacker_leaves:
		_drop(ra)
		_tile_card(int(ids[0]), BATTLE_POINTS[0], bool(e.get("attacker_defense", false)))
	if defender_leaves:
		_drop(rt)
		_tile_card(int(ids[1]), BATTLE_POINTS[1], bool(e.get("target_defense", false)))


func _tile_card(id: int, point: Vector2, defence: bool) -> void:
	if id <= 0 or host == null:
		return
	var sheet: Image = _card_view(id).get_image()
	_program(3, 1 if defence else 0, {"x": int(point.x), "y": int(point.y), "sheet": sheet, "seed": id + 3})


## The ritual apply (effect 22): the tributes (the monsters the ritual's remove events name) are passed to the program, which moves and
## hides them through the card-object channel. The phase is the ritual card's id.
func _ritual_tributes(events: Array, side: int) -> Array:
	var tributes: Array = []
	for e in events:
		if str(e["kind"]) == "remove" and str(e.get("row", "")) == "monsters" and int(e["side"]) == side:
			tributes.append(_rec(side, "monsters", int(e["zone"])))
	return tributes


func _ritual_start(card: int, events: Array, side: int) -> Callable:
	var tributes := _ritual_tributes(events, side)
	return func() -> void:
		hand_hidden = true          # the hand stays off the picture through the apply (the tributes come back in its flight: effect 22)
		_program(22, card, {"x": 0, "y": 0, "z": 0, "seed": card + 22, "tributes": tributes, "side": side, "release_at_impact": true})


## The removal order of the monster removal cards (effect 15's configuration index; the list is the port's, the overlay's table is the
## same set of cards in its own order).
const REMOVAL_ORDER := [653, 656, 660, 661, 662, 663, 664]


## A monster removal (effect 15 at the removed monsters' points, then one fragment request per monster, effect 11 at its point with the
## card-type variant: monster 1, magic and equip 2, trap 3, ritual 4). The removed monsters are hidden as their fragments start; the
## removal's own events then drop them.
func _removal(card: int, events: Array) -> void:
	var targets: Array = []
	for e in events:
		if str(e["kind"]) == "remove" and str(e.get("row", "")) == "monsters":
			targets.append({"record": _rec(int(e["side"]), "monsters", int(e["zone"])), "variant": _card_variant(int(e["side"]), int(e["zone"]))})
	if targets.is_empty():
		return
	var points: Array = []
	for t in targets:
		points.append(_board_at(int(t["record"])))
	var index := maxi(REMOVAL_ORDER.find(card), 0)
	var first := func() -> void:
		_program(15, index, {"x": 0, "y": 0, "seed": card + 15, "cards": points})
	_beat(first, 0)
	var fragments := func() -> void:
		for k in targets.size():
			var record: int = targets[k]["record"]
			var at: Vector3i = points[k]
			if objects_channel != null:
				objects_channel.set_shown(record, false)
			_program(11, int(targets[k]["variant"]), {"x": at.x, "y": at.y, "z": at.z, "seed": record + 11})
	_beat(fragments, 0)


## The card-effect variant of a card on the board: monster 1, magic and equip 2, trap 3, ritual 4.
func _card_variant(side: int, zone: int) -> int:
	var cell = host.engine.state.sides[side].monsters[zone] if host != null else null
	if cell == null:
		return 1
	match str(host.engine.state.data.card(int(cell["id"])).get("type", "")):
		"Magic", "Equip":
			return 2
		"Trap":
			return 3
		"Ritual":
			return 4
	return 1


## The life point recovery's figure (effect 9) at the game's point (160, 120), the variant the table index of the amount (200 to 5000).
func _recovery_figure(card: int) -> bool:
	return _program(9, card - 338, {"x": 160, "y": 120, "seed": card + 9})


## The card read-back of effect 3 (the overlay's DuelCard_CaptureRoundedTexture): the card's picture as the screen shows it in its
## box, stretched to the 140 x 196 sheet, with the twelve corner texels cleared (transparent). The picture is the scene's rendered
## viewport when there is one; without it (headless) the card's face is the source.
func _capture_card(record: int, face) -> Image:
	var sheet_size := Vector2i(140, 196)
	var source: Image = null
	if field != null and field.viewport != null and DisplayServer.get_name() != "headless":   # the dummy renderer has no picture to read
		var view_texture: ViewportTexture = field.viewport.get_texture()
		var picture: Image = view_texture.get_image() if view_texture != null else null
		if picture != null and not picture.is_empty():
			var box := _rect(record)
			var region := Rect2i(int(box.position.x), int(box.position.y + field.SHIFT), maxi(int(box.size.x), 1), maxi(int(box.size.y), 1))
			region = region.intersection(Rect2i(Vector2i.ZERO, picture.get_size()))
			if region.size.x > 0 and region.size.y > 0:
				source = picture.get_region(region)
	if source == null and face is Texture2D:
		source = (face as Texture2D).get_image()
	if source == null:
		source = Image.create(sheet_size.x, sheet_size.y, false, Image.FORMAT_RGBA8)
		source.fill(Color(0.5, 0.5, 0.5, 1.0))
	source = source.duplicate()
	source.convert(Image.FORMAT_RGBA8)
	source.resize(sheet_size.x, sheet_size.y, Image.INTERPOLATE_BILINEAR)
	for corner in [Vector2i(138, 195), Vector2i(139, 195), Vector2i(1, 195), Vector2i(0, 195), Vector2i(139, 194), Vector2i(0, 194),
			Vector2i(139, 1), Vector2i(0, 1), Vector2i(138, 0), Vector2i(139, 0), Vector2i(1, 0), Vector2i(0, 0)]:
		source.set_pixel(corner.x, corner.y, Color(0.0, 0.0, 0.0, 0.0))
	return source


## The attack's hit: effect 2 at the game's point (240, 120) with the battle's result as its number (the sign is the figure's
## colour) and the variant by the result's size (the game's result / 1000, capped at 2, plus 3). False when the program is not ported.
func _hit(result: int) -> bool:
	var level := mini(result / 1000, 2)
	return _program(2, maxi(level + 3, 0), {"x": 240, "y": 120, "number": result, "seed": result + 2})


## The attack into a trap (the reference's trap battle, the same beats as its battle): the view swings to the hand view as the attacker
## leaves (its removal is the first beat), the field view pans to the trap's row, and the trap springs TRAP_SPRING_AT frames after the
## attacker's removal (the reference: the attacker gone at 1792, the trap's effect at 1888; the trap is a card back until then).
const TRAP_SPRING_AT := 96
const TRAP_SPRING_HOLD := 40          # the spring's own beat: effect 8 and the card's turn-away (the trap leaves its cell)
const DESTROY_FRAMES := 22            # a destruction's beat: the card shrinks and fades where it stands (_destroy)


func _attack_trap(e: Dictionary, gone: Array) -> void:
	var record := _rec(int(e["side"]), "traps", int(e["zone"]))
	var swing := func() -> void:
		battle_view = true
		battle_view_t = 0
		if field != null:
			field.swing_out()
	_beat(swing, 0)
	if not gone.is_empty():
		_destroy(gone)
	var pan := func() -> void:
		battle_view = false             # the pan holds the view: the battle view's own return (tick) does not refocus the cursor
		view_hold = true
		if field != null:
			field.pan_to(record)
	_beat(pan, 0)
	# the wait ends TRAP_SPRING_AT frames after the attacker's removal: the removal's own beat (_destroy's 22 frames) is part of it
	var wait := TRAP_SPRING_AT - (DESTROY_FRAMES if not gone.is_empty() else 0)
	_beat(func() -> void: pass, maxi(wait, 0))
	_trap(e)


func _trap(e: Dictionary) -> void:
	var record := _rec(int(e["side"]), "traps", int(e["zone"]))
	var id := int(e["id"])
	var spring := func() -> void:
		var entry := _entry_in(visible_entries, record)
		var back: Texture2D = _texture_of(entry) if not entry.is_empty() else host._back(id, "traps")
		# trap resolution: effect 8 (variant 0) at the trap's point, as a scene program (the request's offset is the card's point)
		var centre := _rect(record).get_center()
		_program(8, 0, {"x": int(centre.x) - 160, "y": int(centre.y) - 108, "seed": record + 8})
		var anim := func(p: float) -> Dictionary:
			return {"dy": -18.0 * sin(p * PI), "sx": absf(cos(p * PI))}
		var done := func() -> void:
			_drop(record)
		_card(back, _rect(record), 40, 0, anim, _face(id), 0.5, done)
		_ring(_rect(record).get_center(), GOLD, 30, 16)
	_beat(spring, TRAP_SPRING_HOLD)


func _direct(e: Dictionary, ctx: Dictionary) -> void:
	var side := int(e["side"])                        # the side that takes the damage
	var zone := int(ctx.get("attacker", -1))
	var damage := int(e["damage"])
	var ra := _rec(1 - side, "monsters", zone) if zone >= 0 else -1
	if ra >= 0 and not _entry_in(visible_entries, ra).is_empty():
		var fly := func() -> void:
			var entry := _entry_in(visible_entries, ra)
			_hide(ra)
			var anim := func(p: float) -> Dictionary:
				return {"dy": -44.0 * sin(p * PI)}
			var done := func() -> void:
				_unhide(ra)
			_card(_texture_of(entry), _rect(ra), 24, 0, anim, null, 2.0, done)
		_beat(fly, 24)
	var hit := func() -> void:
		life_hold[side] = true
		_flash(LP_RECT[side], RED, 14, 0)
		_figure_at(LP_AT[side] + Vector2(16, -16), damage, RED, 30)
	_beat(hit, 30)
	_beat(_release(side), 2)


## A life point change. A card's change carries its effect ("heal": program 5; "damage": programs 6 then 7) and its table unit (the
## program's variant); those programs stand in for the figure. Other changes show the figure and the flash.
func _life(side: int, amount: int, e: Dictionary = {}) -> void:
	var unit := int(e.get("unit", -1))
	var card_effect := str(e.get("effect", ""))
	if unit >= 0 and card_effect == "heal":
		var splash := func() -> void:
			life_hold[side] = true
			_program(5, unit, {"x": 160, "y": 120, "flags": 8, "seed": unit + 5})
		_beat(splash, 2)
		_beat(_release(side), 2)
		return
	if unit >= 0 and card_effect == "damage":
		var splash := func() -> void:
			life_hold[side] = true
			_flash(LP_RECT[side], RED, 10, 0)
			_program(6, unit, {"x": 160, "y": 120, "flags": 8, "seed": unit + 6})
		_beat(splash, 2)
		var figure_program := func() -> void:
			_program(7, unit, {"x": 160, "y": 120, "flags": 8, "seed": unit + 7})
		_beat(figure_program, 2)
		_beat(_release(side), 2)
		return
	var figure := func() -> void:
		life_hold[side] = true
		_figure_at(LP_AT[side] + Vector2(16, -16), absi(amount), GREEN if amount > 0 else RED, 30)
		if amount < 0:
			_flash(LP_RECT[side], RED, 10, 0)
	_beat(figure, 30)
	_beat(_release(side), 2)


func _release(side: int) -> Callable:
	return func() -> void:
		life_hold[side] = false


func _stat(record: int, delta: int) -> void:
	var figure := func() -> void:
		_figure(_rect(record), absi(delta), GREEN if delta > 0 else RED, 0)
	_beat(figure, 30)


func _swords(side: int) -> void:
	var lock := func() -> void:
		locks[side] = _row_rect(side)
		_banner("SWORDS OF REVEALING LIGHT", Vector2(CENTRE.x, 60), 60)
		# the game's start request (effect 18 at phase 1) and the field effect of the side (effect 21, its phase the side)
		_program(18, 1, {"x": 160, "y": 120, "flags": 8, "seed": 18})
		_program(21, side, {"x": 160, "y": 120, "flags": 8, "seed": 21 + side, "nonblocking": true, "side": side})
	_beat(lock, 60)


func _terrain(value: int) -> void:
	# the terrain change (effect 10 at the card's variant): the FIELD box shows the new terrain once the program's impact has landed
	# (the game sets the terrain when its package has loaded, the same point the program's own stage signal follows)
	var lead := func() -> void:
		pass                            # the program starts after the card view's fade (the reference's burst at about 120 frames from the play)
	_beat(lead, 32)
	var change := func() -> void:
		var show_plate := func() -> void:
			if field != null:
				field.set_terrain_plate(value)
				field.set_board_terrain(value)
		if _program(10, clampi(value - 1, 0, 5), {"x": 0, "y": 0, "seed": value + 40, "stage_on_impact": -2}):
			programs[programs.size() - 1]["on_impact"] = show_plate
		else:
			show_plate.call()
	_beat(change, 0)


## Fusion: the chosen cards close in on the centre and flash (the placement's fusion motion), then the fused card's view swings in.
func _fusion(e: Dictionary, ctx: Dictionary) -> void:
	var sources: Array = ctx.get("cards", [])
	var result := int(e.get("result", 0))
	var converge := func() -> void:
		hand_hidden = true              # the hand leaves the picture for the fusion's motion
		var n := sources.size()
		for k in n:
			var from := _fusion_pos(k, n, false)
			var offset := CENTRE - from
			var anim := func(p: float) -> Dictionary:
				return {"dx": offset.x * p, "dy": offset.y * p, "sx": 1.0 - 0.7 * p, "sy": 1.0 - 0.7 * p, "alpha": 1.0 - 0.5 * p}
			_card(_face(int(sources[k])), Rect2(from - CARD_RECT_SIZE / 2.0, CARD_RECT_SIZE), 24, 0, anim, null, 2.0, Callable())
		var points: Array = []
		var vels: Array = []
		for k in 28:
			var a := TAU * float(k) / 28.0
			points.append(CENTRE + Vector2(cos(a), sin(a)) * 60.0)
			vels.append(Vector2.ZERO)
		_particles(points, vels, Color(0.75, 0.9, 1.0), 26, 0, CENTRE, 0.0)
		_flash(Rect2(CENTRE - Vector2(30, 30), Vector2(60, 60)), WHITE, 12, 24)
	var dwell := func() -> void:
		hand_hidden = true
		for k in sources.size():
			_card(_face(int(sources[k])), Rect2(_fusion_pos(k, sources.size(), true) - CARD_RECT_SIZE / 2.0, CARD_RECT_SIZE), 48, 0,
					Callable(), null, 2.0, Callable())
	_beat(dwell, 48)            # the two cards rest in the field's row (the reference: about 48 frames) before they close in
	_beat(converge, 36)
	var view := func() -> void:
		_close_up(_card_view(result), 0, CLOSE_UP_TURN, 24, CLOSE_UP_FADE)
	_beat(view, CLOSE_UP_TURN + 24 + CLOSE_UP_FADE)
	var show := func() -> void:
		hand_hidden = false
	_beat(show, 0)


## Where a fusion source is: resting in the field's row (left and right of the centre), or at its start of the closing-in motion (the
## first over the centre's top, the second under it: the reference's vertical convergence on the centre line).
func _fusion_pos(k: int, n: int, resting: bool) -> Vector2:
	if n == 2 and not resting:
		return Vector2(CENTRE.x - 26.0, CENTRE.y - 40.0) if k == 0 else Vector2(CENTRE.x - 18.0, CENTRE.y + 12.0)
	return Vector2(CENTRE.x + (float(k) - float(n - 1) / 2.0) * 150.0, CENTRE.y + 12.0)


## The equip placement at the card's point (x = its left + 26, y = its top + 30): effect 4 for the equip ids 301 and 302
## (variant 1 for 302), else effect 0 (variant 10 for 0x291). False when the program is not ported.
func _equip_placement(id: int, rect: Rect2) -> bool:
	var at := {"x": int(rect.position.x) + 26, "y": int(rect.position.y) + 30, "flags": 8, "seed": id + 9}
	if id == 301 or id == 302:
		return _program(4, 1 if id == 302 else 0, at)
	return _program(0, 10 if id == 0x291 else 0, at)


## An equip on the chosen monster (the placement's equip motion): the equip card flies from the centre to the monster, the monster
## lifts out of its zone, the placement's burst shows at its point, its card view swings in with the new stats, and it settles back.
func _equip(e: Dictionary, events: Array, index: int, ctx: Dictionary) -> void:
	var side := int(e.get("side", ctx.get("side", 0)))
	var id := int(e["equip"])
	var bonus := int(e["bonus"])
	var zone := int(e["zone"]) if e.has("zone") else -1
	var monster_id := 0
	if e.has("zone"):
		monster_id = 0
	else:
		for k in range(index + 1, events.size()):
			if str(events[k]["kind"]) == "summon":
				zone = int(events[k]["zone"])
				side = int(events[k]["side"])
				monster_id = int(events[k]["id"])
				break
	var dest := _rec(side, "monsters", zone) if zone >= 0 else -1
	var box := _rect(dest) if dest >= 0 else Rect2(CENTRE - CARD_RECT_SIZE / 2.0, CARD_RECT_SIZE)
	var fly := func() -> void:
		var from := Vector2(CENTRE.x, 180.0)
		var offset := box.get_center() - from
		var anim := func(p: float) -> Dictionary:
			return {"dx": offset.x * p, "dy": offset.y * p, "sx": 1.0 - 0.6 * p, "sy": 1.0 - 0.6 * p}
		_card(_face(id), Rect2(from - CARD_RECT_SIZE / 2.0, CARD_RECT_SIZE), 26, 0, anim, null, 2.0, Callable())
	_beat(fly, 26)
	var chosen := func() -> void:
		pass                            # the equip card rests on the chosen monster before the monster lifts out (the reference: 96 frames pick to lift)
	_beat(chosen, 70)
	var lifted := _entry_in(visible_entries, dest) if dest >= 0 else {}
	var before_tex: Texture2D = _texture_of(lifted) if not lifted.is_empty() else _face(monster_id)
	var leave := func() -> void:
		if dest >= 0:
			_hide(dest)
		var anim := func(p: float) -> Dictionary:
			var c := box.get_center()
			return {"dx": (CENTRE.x - c.x) * p, "dy": (CENTRE.y - c.y) * p, "sx": 1.0 + 0.2 * p, "sy": 1.0 + 0.2 * p}
		_card(before_tex, box, 24, 0, anim, null, 2.0, Callable())
	_beat(leave, 24)
	var float_hold := func() -> void:
		pass                            # the monster floats at the centre a while before the placement's burst (the reference)
	_beat(float_hold, 40)
	var place := func() -> void:
		if dest >= 0:
			_equip_placement(id, box)
	_beat(place, 2)
	var mon: Variant = host.engine.state.sides[side].monsters[zone] if zone >= 0 else null
	var after_tex: Texture2D = _face(monster_id)
	if mon != null:
		after_tex = host._field_face(int(mon["id"]), mon, "monsters")
	var view := func() -> void:
		_close_up(_card_view(int(mon["id"]) if mon != null else monster_id), 0, CLOSE_UP_TURN, 24, CLOSE_UP_FADE)
	_beat(view, CLOSE_UP_TURN + 24 + CLOSE_UP_FADE)
	var back := func() -> void:
		var settle := func(p: float) -> Dictionary:
			var c := box.get_center()
			return {"dx": (c.x - CENTRE.x) * (1.0 - p), "dy": (c.y - CENTRE.y) * (1.0 - p), "sx": 1.0 + 0.2 * (1.0 - p), "sy": 1.0 + 0.2 * (1.0 - p)}
		var done := func() -> void:
			if dest >= 0:
				_unhide(dest)
				_replace(dest)
		_card(after_tex, box, 16, 0, settle, null, 2.0, done)
	_beat(back, 16)
	var bump := func() -> void:
		_flash(box, GOLD, 12, 0)
		_figure(box, absi(bonus), GREEN if bonus > 0 else RED, 0)
	_beat(bump, 34)


func _discard(id: int) -> void:
	var drop := func() -> void:
		var anim := func(p: float) -> Dictionary:
			return {"dy": 10.0 * p, "alpha": 1.0 - p}
		_card(_face(id), Rect2(CENTRE - CARD_RECT_SIZE / 2.0 + Vector2(0, 60), CARD_RECT_SIZE), 18, 0, anim, null, 2.0, Callable())
	_beat(drop, 18)


## A destruction: each card shrinks, turns and fades where it stood, then leaves the field.
func _destroy(group: Array) -> void:
	var gone := func() -> void:
		for e in group:
			var row := "traps" if str(e.get("row", "monsters")) == "traps" else "monsters"
			var record := _rec(int(e["side"]), row, int(e["zone"]))
			var entry := _entry_in(visible_entries, record)
			if entry.is_empty():
				continue
			if object_state.has(record) and not bool(object_state[record]["shown"]):
				# a card an effect program already struck and hid (the feather duster): it leaves with the program's own flash
				_drop(record)
				continue
			var box := _rect(record)
			_flash(box, WHITE, 12, 0)
			var anim := func(p: float) -> Dictionary:
				return {"sx": 1.0 - p, "sy": 1.0 - 0.6 * p, "dy": -8.0 * p, "alpha": 1.0 - p, "rot": 0.8 * p}
			var done := func() -> void:
				_drop(record)
			_card(_texture_of(entry), box, DESTROY_FRAMES, 0, anim, null, 2.0, done)
	_beat(gone, DESTROY_FRAMES)


## The magic card window (the card-use sequence of the magic presentation): the card lifts off the centre and shrinks away, the card view
## swings in, holds, and fades. The group's effect follows the window (its own beat), and the terrain change is its own event (_terrain).
func _window(card: int, side: int, also: Callable = Callable()) -> void:
	var group := window_group(card)
	var window := func() -> void:
		hand_hidden = true              # the hand leaves the picture while the card-use sequence runs (the reference's card view)
		var face: Texture2D = _face(card)
		var lift := func(p: float) -> Dictionary:
			var f := p * float(WINDOW_LIFT)
			var t := clampf((f - 8.0) / 16.0, 0.0, 1.0)
			return {"dy": 26.0 * t, "sx": 1.0 - 0.4 * t, "sy": 1.0 - 0.4 * t, "alpha": 1.0 - clampf((f - 16.0) / 8.0, 0.0, 1.0)}
		_card(face, Rect2(CENTRE_AT, HAND_SIZE), WINDOW_LIFT, 0, lift, null, 2.0, Callable())
		_close_up(_card_view(card), WINDOW_LIFT, CLOSE_UP_TURN, WINDOW_HOLD, CLOSE_UP_FADE)
		# a ritual's start (effect 18, the flash) is with its window: the reference's start request is raised as the card is shown
		if group == "ritual":
			_group_effect(group, Rect2(CENTRE - WINDOW_SIZE / 2.0, WINDOW_SIZE), card, side)
		if also.is_valid():
			# the apply starts while the card view fades: its portal fades in from RITUAL_APPLY_AT, so the portal is neutral and the
			# flames show about 32 frames later (the reference's flames show at about +96). The window holds until the apply's impact.
			_op("call", 1, RITUAL_APPLY_AT, {"done": also})
	_beat(window, WINDOW_FRAMES, RITUAL_APPLY_BUDGET if also.is_valid() else BEAT_BUDGET)
	var show := func() -> void:
		hand_hidden = false
	_beat(show, 0)
	if group != "terrain" and group != "ritual":
		var effect := func() -> void:
			_group_effect(group, Rect2(CENTRE - WINDOW_SIZE / 2.0, WINDOW_SIZE), card, side)
		_beat(effect, 0)


## A card view at the centre: it swings in from edge-on over `turn` frames, holds `hold` frames, and fades over `fade` frames. It
## starts `delay` frames after the call. The view is the card's face at the window's size (the duel's own card picture).
## The card's close-up texture: the whole card at 1x (140 x 196), composed by CardView.card_picture as the card-detail routine composes
## it (the Password reveal's card). Cached per card; the field face is the fallback.
func _card_view(id: int) -> Texture2D:
	if card_views.has(id):
		return card_views[id]
	var data: Dictionary = host.engine.state.data.card(id)
	var base := CardView.card_picture(id, data, int(data.get("attack", 0)), int(data.get("defense", 0)), card_ui_layout)
	if base == null:
		return _face(id)
	var tex := ImageTexture.create_from_image(base)
	card_views[id] = tex
	return tex


func _close_up(tex: Texture2D, delay: int, turn: int, hold: int, fade: int) -> void:
	var total := turn + hold + fade
	var rect := Rect2(WINDOW_CENTRE - WINDOW_SIZE / 2.0, WINDOW_SIZE)
	var anim := func(p: float) -> Dictionary:
		var f := p * float(total)
		var s := sin(clampf(f / float(turn), 0.0, 1.0) * PI * 0.5)
		var a := 1.0 - clampf((f - float(turn + hold)) / float(fade), 0.0, 1.0)
		return {"sx": maxf(s, 0.02), "alpha": a}
	_card(tex, rect, total, delay, anim, null, 2.0, Callable())


## The effect group a magic card's window plays: LP recovery, direct damage, a sweep (Dark Hole, Jar, removal, Raigeki), stop
## defense, reveals (Swords, Dark-piercing Light), penalties (Spellbinding, Shadow Spell, Cursebreaker), Feather Duster, terrain,
## ritual, and a plain flash for the rest.
static func window_group(id: int) -> String:
	if DuelEffects.LP_RECOVERY.has(id):
		return "heal"
	if DuelEffects.DIRECT_DAMAGE.has(id):
		return "burst"
	if id == 336:
		return "board"       # Dark Hole: the board destruction (effect 17)
	if id == 329 or id == 337 or DuelEffects.REMOVAL_TYPE.has(id) or id == DuelEffects.CRUSH_CARD:
		return "sweep"
	if id == 320:
		return "stop"
	if id == 348 or id == 350:
		return "reveal"
	if id == 349 or id == 669 or id == 655:
		return "penalty"
	if id == 672:
		return "feather"
	if id >= 330 and id <= 335:
		return "terrain"
	if DuelEffects.is_ritual(id):
		return "ritual"
	return "plain"


## The window's effect program for its group, when one is ported (the stand-ins of _group_effect are kept for the rest): the sweep
## (program 16), the stop of a defence (12), the penalties (13 with the penalty as its number; Cursebreaker, card 655, is program 8 at
## variant 3), and the terrain change (10 at the terrain's variant, with the stage signal after its impact). The scene programs take
## the window's centre less the scene centre (160, 108) as their offset, and the terrain change none (its request has no offset).
## False when no program applies.
func _window_program(group: String, card: int, c: Vector2, side: int = 0) -> bool:
	var scene := {"x": int(c.x) - 160, "y": int(c.y) - 108, "seed": card + 40}
	match group:
		"sweep":
			return _program(16, 0, scene)
		"board":
			return _program(17, 0, {"x": 0, "y": 0, "z": 0, "seed": card + 40})
		"heal":
			return DuelEffects.LP_RECOVERY.has(card) and _recovery_figure(card)
		"stop":
			return _program(12, 0, scene)
		"penalty":
			if card == 655:
				return _program(8, 3, scene)
			var penalty := 500 if card == 349 else 1000
			return _program(13, 0, scene.merged({"number": -penalty}))
		"terrain":
			if card < 330 or card > 335:
				return false
			return _program(10, card - 330, {"x": 0, "y": 0, "seed": card + 40, "stage_on_impact": -2})
		"feather":
			# the duster sweeps the opponent's magic and trap row (the removal's cards); its direction is the row's side of the board
			var foe := side ^ 1
			var row_z := int(_board_at(_rec(foe, "traps", 0)).z)
			return _program(23, 0, {"x": 0, "y": 0, "seed": card + 40, "side": foe, "row_z": row_z, "forward": row_z < 0})
	return false


func _group_effect(group: String, rect: Rect2, card: int = 0, side: int = 0) -> void:
	var c := rect.get_center()
	if _window_program(group, card, c, side):
		return
	match group:
		"heal":
			var points: Array = []
			var vels: Array = []
			for k in 36:
				points.append(Vector2(rect.position.x + rng.randf() * rect.size.x, rect.end.y))
				vels.append(Vector2(rng.randf_range(-0.2, 0.2), -rng.randf_range(1.0, 2.6)))
			_particles(points, vels, GREEN, 60, 8, Vector2.ZERO, 0.0)
			_ring(c, BLUE, 40, 4)
		"burst":
			_rays(c, 16, 10.0, 60.0, RED, 36, 6)
			_flash(PICTURE, RED, 22, 6)
		"sweep":
			_rays(c, 12, 6.0, 40.0, WHITE, 40, 4)
			_ring(c, BLUE, 36, 0)
			_ring(c, WHITE, 36, 10)
		"stop":
			_band(Rect2(0, 30, 320, 14), WHITE, 40, 8, 180.0)
		"reveal":
			# the reveal flash: effect 19 at the game's point (160, 104)
			if not _program(19, 0, {"x": 160, "y": 104, "seed": 19}):
				var points: Array = []
				var vels: Array = []
				for k in 28:
					var a := rng.randf() * TAU
					points.append(c + Vector2(cos(a), sin(a)) * 90.0)
					vels.append(Vector2.ZERO)
				_particles(points, vels, GOLD, 40, 4, c, 0.0)
				_ring(c, GOLD, 30, 30)
		"penalty":
			_flash(PICTURE, Color(0.2, 0.0, 0.3), 30, 0)
			var points: Array = []
			var vels: Array = []
			for k in 30:
				points.append(Vector2(rng.randf() * 320.0, -10.0 - rng.randf() * 60.0))
				vels.append(Vector2(0.0, rng.randf_range(1.8, 3.2)))
			_particles(points, vels, PURPLE, 70, 4, Vector2.ZERO, 0.0)
		"feather":
			var points: Array = []
			var vels: Array = []
			for k in 40:
				points.append(Vector2(340.0 + rng.randf() * 40.0, 30.0 + rng.randf() * 190.0))
				vels.append(Vector2(-rng.randf_range(3.0, 5.0), rng.randf_range(-0.5, 0.5)))
			_particles(points, vels, WHITE, 60, 6, Vector2.ZERO, 0.0)
		"terrain":
			_band(Rect2(-160, 0, 160, 240), Color(0.6, 1.0, 0.7), 40, 4, 480.0)
		"ritual":
			# the ritual's start: effect 18 at phase 1 (the game's start request); the particles stand in when it is not ported
			if not _program(18, 1, {"x": 160, "y": 120, "flags": 8, "seed": 18}):
				var points: Array = []
				var vels: Array = []
				for k in 30:
					var a := rng.randf() * TAU
					points.append(c + Vector2(cos(a), sin(a)) * 80.0)
					vels.append(Vector2.ZERO)
				_particles(points, vels, Color(1.0, 0.85, 0.4), 40, 4, c, 0.0)
				_flash(rect, WHITE, 14, 40)
		_:
			_rays(c, 12, 8.0, 50.0, WHITE, 30, 4)
			_flash(rect, WHITE, 16, 6)


# ---- primitives ------------------------------------------------------------------------------------------------------------

## A card drawn in its box. anim(p) gives {dx, dy, sx, sy, alpha, rot}; tex2 replaces tex from the fraction `switch` on; done runs
## when the op ends.
func _card(tex: Texture2D, rect: Rect2, frames: int, delay: int, anim: Callable, tex2: Texture2D, switch: float, done: Callable) -> void:
	var op := {"tex": tex, "tex2": tex2, "rect": rect, "anim": anim, "switch": switch}
	if done.is_valid():
		op["done"] = done
	_op("card", frames, delay, op)


func _flash(rect: Rect2, colour: Color, frames: int, delay: int) -> void:
	var anim := func(p: float) -> Dictionary:
		return {"alpha": 0.85 * (1.0 - p)}
	_op("flash", frames, delay, {"rect": rect, "colour": colour, "anim": anim, "travel": Vector2.ZERO})


## A band of colour that moves across the picture (horizontal when travel is wide, down otherwise).
func _band(rect: Rect2, colour: Color, frames: int, delay: int, travel: float) -> void:
	var anim := func(p: float) -> Dictionary:
		var horizontal := travel > 300.0
		var dx := travel * p if horizontal else 0.0
		var dy := 0.0 if horizontal else travel * p
		return {"dx": dx, "dy": dy, "alpha": 0.8 * (1.0 - 0.5 * p)}
	_op("flash", frames, delay, {"rect": rect, "colour": colour, "anim": anim, "travel": Vector2.ZERO})


func _rays(c: Vector2, count: int, r0: float, r1: float, colour: Color, frames: int, delay: int) -> void:
	var anim := func(p: float) -> Dictionary:
		return {"r0": r0 + (r1 - r0) * p * 0.5, "r1": r0 + (r1 - r0) * p, "alpha": 1.0 - p}
	_op("rays", frames, delay, {"centre": c, "count": count, "anim": anim, "colour": colour, "spin": 0.6})


func _ring(c: Vector2, colour: Color, frames: int, delay: int) -> void:
	var anim := func(p: float) -> Dictionary:
		return {"radius": 6.0 + 70.0 * p, "alpha": 1.0 - p, "width": 2.0 * (1.0 - p) + 0.5}
	_op("ring", frames, delay, {"centre": c, "colour": colour, "anim": anim})


## Points that fly with their velocities (gravity pulls them down), or gather toward `gather` when it is not zero.
func _particles(points: Array, vels: Array, colour: Color, frames: int, delay: int, gather: Vector2, gravity: float) -> void:
	var op := {"points": points, "vels": vels, "colour": colour, "gravity": gravity, "life": float(frames), "pull": 0.06, "drag": 0.9}
	if gather != Vector2.ZERO:
		op["gather"] = gather
	_op("particles", frames, delay, op)


## A figure of digits over a point: it bounces up and fades.
func _figure(rect: Rect2, value: int, colour: Color, delay: int) -> void:
	_figure_at(Vector2(rect.get_center().x, rect.position.y - 4.0), value, colour, 34, delay)


func _figure_at(at: Vector2, value: int, colour: Color, frames: int, delay := 0) -> void:
	var anim := func(p: float) -> Dictionary:
		return {"dy": -10.0 * sin(clampf(p * 1.5, 0.0, 1.0) * PI), "alpha": 1.0 - clampf((p - 0.7) / 0.3, 0.0, 1.0)}
	_op("digits", frames, delay, {"at": at, "value": value, "colour": colour, "anim": anim})


func _banner(string: String, centre: Vector2, frames: int) -> void:
	var node := Node2D.new()
	add_child(node)
	host.text.layout(node, host._bytes(string), Vector2.ZERO, Vector2(8, 12), 0, sharp, true)
	var width := float(string.length()) * 8.0
	node.position = centre - Vector2(width / 2.0, 6.0)
	var anim := func(p: float) -> Dictionary:
		return {"alpha": minf(1.0, p * 6.0) * (1.0 - clampf((p - 0.8) / 0.2, 0.0, 1.0))}
	_op("banner", frames, 0, {"node": node, "anim": anim})


# ---- drawing ---------------------------------------------------------------------------------------------------------------

func _draw() -> void:
	for op in ops:
		var t: int = op["t"]
		var delay: int = op["delay"]
		if op["kind"] == "banner" or t < delay:
			continue
		var p := clampf(float(t - delay) / float(op["frames"]), 0.0, 1.0)
		match op["kind"]:
			"card":
				_draw_card(op, p)
			"digits":
				var anim: Callable = op["anim"]
				var props: Dictionary = anim.call(p)
				var colour: Color = op["colour"]
				_draw_digits(op["at"] + Vector2(0.0, float(props["dy"])), str(absi(int(op["value"]))), colour, float(props["alpha"]))
			"flash":
				var anim_f: Callable = op["anim"]
				var f: Dictionary = anim_f.call(p)
				var colour_f: Color = op["colour"]
				var rect: Rect2 = op["rect"]
				var moved := rect.position + Vector2(float(f.get("dx", 0.0)), float(f.get("dy", 0.0)))
				draw_rect(Rect2(moved, rect.size), Color(colour_f.r, colour_f.g, colour_f.b, float(f["alpha"])))
			"rays":
				var anim_r: Callable = op["anim"]
				var r: Dictionary = anim_r.call(p)
				var colour_r: Color = op["colour"]
				var centre: Vector2 = op["centre"]
				for k in int(op["count"]):
					var a := TAU * float(k) / float(op["count"]) + float(op["spin"]) * p
					var dir := Vector2(cos(a), sin(a))
					draw_line(centre + dir * float(r["r0"]), centre + dir * float(r["r1"]), Color(colour_r.r, colour_r.g, colour_r.b, float(r["alpha"])), 1.5)
			"ring":
				var anim_g: Callable = op["anim"]
				var q: Dictionary = anim_g.call(p)
				var colour_g: Color = op["colour"]
				draw_arc(op["centre"], float(q["radius"]), 0.0, TAU, 32, Color(colour_g.r, colour_g.g, colour_g.b, float(q["alpha"])), float(q["width"]))
			"particles":
				var colour_p: Color = op["colour"]
				var alpha := clampf(1.0 - float(t - delay) / float(op["life"]), 0.0, 1.0)
				for point in op["points"]:
					draw_rect(Rect2(point - Vector2(1, 1), Vector2(2, 2)), Color(colour_p.r, colour_p.g, colour_p.b, alpha))
	for side in locks.keys():
		var lock_rect: Rect2 = locks[side]
		var turns := int(host.engine.state.sides[side].swords_turns)
		draw_rect(lock_rect.grow(2.0), Color(1.0, 0.85, 0.3, 0.9), false, 1.0)
		_draw_digits(lock_rect.position + Vector2(0, -15), str(turns), GOLD, 1.0)


func _draw_card(op: Dictionary, p: float) -> void:
	var props: Dictionary = {}
	if op["anim"].is_valid():
		var anim: Callable = op["anim"]
		props = anim.call(p)
	var tex: Texture2D = op["tex"]
	if p >= float(op["switch"]) and op["tex2"] != null:
		tex = op["tex2"]
	if tex == null:
		return
	var rect: Rect2 = op["rect"]
	var centre := rect.get_center() + Vector2(float(props.get("dx", 0.0)), float(props.get("dy", 0.0)))
	var size := rect.size * Vector2(float(props.get("sx", 1.0)), float(props.get("sy", 1.0)))
	if size.x <= 0.0 or size.y <= 0.0:
		return
	draw_set_transform(centre, float(props.get("rot", 0.0)), Vector2.ONE)
	draw_texture_rect(tex, Rect2(-size / 2.0, size), false, Color(1, 1, 1, float(props.get("alpha", 1.0))))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## The digits of a figure from the card UI's digit sprites, centred on at.x.
func _draw_digits(at: Vector2, string: String, colour: Color, alpha: float) -> void:
	var x := at.x - float(string.length()) * DIGIT_WIDTH / 2.0
	for i in string.length():
		var art: Dictionary = host._art(CARD_UI + "digit_%s.png" % string[i])
		var tex: Texture2D = art["texture"]
		if tex == null:
			continue
		var size := tex.get_size() / float(art["scale"])
		draw_texture_rect(tex, Rect2(Vector2(x + DIGIT_WIDTH * i, at.y), size), false, Color(colour.r, colour.g, colour.b, alpha))
