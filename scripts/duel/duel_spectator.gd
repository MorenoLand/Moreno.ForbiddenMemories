extends RefCounted
## The AI v AI spectator match (F3, a port-only feature): two random duelists with their own decks play a real duel on the duel scene
## (duel_scene.gd, spectator = true), both sides driven by the computer's AI. This file holds the match's picks and limits; the scene
## runs the match and the quit box (duel_quit.gd) is its confirm.

const DUELIST_COUNT := 39       # ids 1 to 39 (0 is the unused slot)
const DUEL_MASTER_K := 39       # dealt the player's own deck in the story: a spectator match gives it another duelist's deck
const TERRAINS := 7
const FAST_SCALE := 4.0         # Shift held: the match runs at four times the speed
const TURN_LIMIT := 240         # turns (both sides together) before a stalled match is decided on the life points
const FOE_ACTION_LIMIT := 60    # computer actions in one turn before its turn is ended (a no-op loop cannot hold the match)
const TAG := "AI VS AI (F3)"


## A random match: two distinct duelists, the decks they play (ids 1 to 39; Duel Master K plays another duelist's deck) and a terrain
## (the free duel's 0 half the time, else one of the seven). Returns {ids: [side 0, side 1], decks: [...], terrain: n}.
static func pick(rng: RandomNumberGenerator) -> Dictionary:
	var a := rng.randi_range(1, DUELIST_COUNT)
	var b := a
	while b == a:
		b = rng.randi_range(1, DUELIST_COUNT)
	var decks := [_deck_owner(a, rng), _deck_owner(b, rng)]
	var terrain := 0 if rng.randf() < 0.5 else rng.randi_range(0, TERRAINS - 1)
	return {"ids": [a, b], "decks": decks, "terrain": terrain}


static func _deck_owner(id: int, rng: RandomNumberGenerator) -> int:
	if id != DUEL_MASTER_K:
		return id
	return rng.randi_range(1, DUELIST_COUNT - 1)


## The deck a duelist plays in a spectator match: a mod's fixed deck, else the duelist's pool dealt by the engine.
static func deck_of(data, engine, owner: int) -> Array:
	var fixed: Array = data.fixed_deck(owner)
	if not fixed.is_empty():
		return fixed.duplicate()
	return engine.build_pool_deck(data.duelists[owner]["deck"])


## The info line's title: the two duelists' names.
static func title(data, ids: Array) -> String:
	return "%s VS %s" % [duelist_name(data, int(ids[0])), duelist_name(data, int(ids[1]))]


static func duelist_name(data, id: int) -> String:
	return str(data.duelists[id].get("name", "")).to_upper()


## Whether the match has run its turn limit (both sides' turns taken together).
static func stalled(engine) -> bool:
	var taken := 0
	for side in engine.state.sides:
		taken += int(side.rank.get("turns_taken", 0))
	return taken >= TURN_LIMIT


## A stalled match is decided on the life points: the side with fewer loses (a tie: side 1 loses).
static func end_stalled(engine) -> void:
	var sides = engine.state.sides
	var loser := 1 if sides[1].lp <= sides[0].lp else 0
	sides[loser].lp = 0
	engine.check_winner()


## The label in the corner of the picture that marks the match as the port's own feature.
static func tag() -> Label:
	var label := Label.new()
	label.text = TAG
	label.position = Vector2(4, 2)
	label.add_theme_font_size_override("font_size", 8)
	label.add_theme_color_override("font_color", Color(1, 0.95, 0.4))
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 3)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
