extends RefCounted
## The duel's rules: setup and decks, the draw phase, the hand phase's chain (fusion, equip, failure), attacks and battle damage,
## guardian-star matchups, the trap triggers and the end conditions. Pure state in, events out, no presentation.
## Side 0 moves first. Every method that changes the duel returns an Array of event dictionaries.

const DuelState = preload("res://scripts/duel/duel_state.gd")
const Effects = preload("res://scripts/duel/duel_effects.gd")

const DECK_SIZE := 40
const HAND_SIZE := 5
const COPY_LIMIT := 3
const POOL_TOTAL := 2048
const EXODIA := [17, 18, 19, 20, 21]
## Guardian star names to the game's ids (1 Mars .. 10 Venus).
const STARS := {"": 0, "Mars": 1, "Jupiter": 2, "Saturn": 3, "Uranus": 4, "Pluto": 5, "Neptune": 6, "Mercury": 7, "Sun": 8, "Moon": 9, "Venus": 10}

var state
var rng := RandomNumberGenerator.new()
var winner := -1               # 0 or 1 once the duel is decided
var first_turn := true
var attack_locked := true      # attacks are refused until the first turn ends (a flag the disc keeps with the turn state)
var names := {}                # card name -> id, for the duelists' pools
var seen_cards: Array = []     # the player's (side 0) placed cards, in order: the library's seen marks


func _init(duel_data, seed_value := 0) -> void:
	state = DuelState.new(duel_data)
	if seed_value != 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	for card in duel_data.cards:
		names[str(card["name"])] = int(card["id"])


# ---- setup -------------------------------------------------------------------------------------------------------

## A CPU duelist's 40-card deck: weighted draws from its pool (a random value in 1..2048 walks the weights), at most three
## copies of any card.
func build_pool_deck(pool: Dictionary) -> Array:
	# the weights are walked in card-id order, as the disc's table is (a pool's order in the file does not matter)
	var entries: Array = []
	for name in pool:
		if names.has(name):
			entries.append([int(names[name]), int(pool[name])])
	entries.sort_custom(func(a, b): return a[0] < b[0])
	var ids: Array = []
	var weights: Array = []
	for entry in entries:
		ids.append(entry[0])
		weights.append(entry[1])
	var deck: Array = []
	var guard := 0
	while deck.size() < DECK_SIZE and guard < 100000:
		guard += 1
		var limit := (rng.randi() & 2047) + 1
		var running := 0
		for i in ids.size():
			running += int(weights[i])
			if running >= limit:
				if deck.count(ids[i]) < COPY_LIMIT:
					deck.append(ids[i])
				break
	return deck


## 160 random swaps, as the game shuffles.
func shuffle(deck: Array, slots: Array = []) -> void:
	for i in 160:
		var x := rng.randi() % deck.size()
		var y := rng.randi() % deck.size()
		var t = deck[x]
		deck[x] = deck[y]
		deck[y] = t
		if slots.size() == deck.size():
			var u = slots[x]
			slots[x] = slots[y]
			slots[y] = u


## the combined deck data build's averages (the result statistics' AVERAGE ATK / DFD FACTOR): the side's 40 cards' attack and
## defense, each packed as the stat table has it (the value / 10 in nine bits, times CARD_STAT_SCALE 10), summed and divided by 40.
func _set_average_factors(p: int, deck: Array) -> void:
	var atk_sum := 0
	var def_sum := 0
	for i in DECK_SIZE:
		var card: Dictionary = state.data.card(int(deck[i])) if i < deck.size() else {}
		atk_sum += ((int(card.get("attack", 0)) / 10) & 0x1FF) * 10
		def_sum += ((int(card.get("defense", 0)) / 10) & 0x1FF) * 10
	state.sides[p].rank["avg_atk_factor"] = atk_sum / DECK_SIZE
	state.sides[p].rank["avg_dfd_factor"] = def_sum / DECK_SIZE


func start(deck0: Array, deck1: Array, terrain := 0) -> void:
	state.sides[0].deck = deck0.duplicate()
	state.sides[1].deck = deck1.duplicate()
	for p in 2:
		_set_average_factors(p, deck0 if p == 0 else deck1)
	for side in state.sides:
		side.deck_slots = range(1, side.deck.size() + 1)
		side.hand_slots = []
		shuffle(side.deck, side.deck_slots)
		side.lp = DuelState.STARTING_LIFE_POINTS
		side.max_lp = DuelState.STARTING_LIFE_POINTS
	state.terrain = terrain
	state.turn_side = 0
	winner = -1
	first_turn = true
	attack_locked = true


# ---- turn flow ---------------------------------------------------------------------------------------------------

## The draw phase of side `p`: the swords counter ticks, used flags clear, the hand is topped up to five from the deck (deck-out
## loses), and five Exodia pieces in hand win. Returns the drawn card ids.
func draw_phase(p: int) -> Array:
	var side = state.sides[p]
	side.rank["turns_taken"] += 1
	if not first_turn and side.swords_turns > 0:
		side.swords_turns -= 1
	for s in state.sides:
		for zone in s.monsters:
			if zone != null:
				zone["used"] = false
	var drawn: Array = []
	while side.hand.size() < HAND_SIZE:
		if side.deck.is_empty():
			_decide(p ^ 1, -40)
			return drawn
		var card: int = side.deck.pop_front()
		_pad_hand_slots(side)
		side.hand_slots.append(int(side.deck_slots.pop_front()) if not side.deck_slots.is_empty() else 0)
		side.hand.append(card)
		drawn.append(card)
	if _has_exodia(side.hand):
		_decide(p, 40)
		state.sides[p ^ 1].lp = 0
	return drawn


## The winner and how the duel ended: the rank adjustment (+2 at zero LP, +40 Exodia, -40 deck-out) goes on the winner's record.
func _decide(w: int, adjustment: int) -> void:
	winner = w
	state.sides[w].rank["result_adjustment"] = adjustment


func _has_exodia(hand: Array) -> bool:
	for id in EXODIA:
		if not hand.has(id):
			return false
	return true


func end_turn(p: int) -> void:
	attack_locked = false
	first_turn = false
	state.turn_side = p ^ 1


## The scene-5 win check: a side at 0 LP has lost.
func check_winner() -> int:
	if winner >= 0:
		return winner      # decided already (Exodia, deck-out): the first ending keeps its adjustment
	# the active side is looked at first: when both are at zero, the side that is not active has lost
	var active: int = state.turn_side
	if state.sides[active].lp <= 0:
		_decide(active ^ 1, 2)
	elif state.sides[active ^ 1].lp <= 0:
		_decide(active, 2)
	return winner


## What the duel result screen reads (scripts/duel/duel_result.gd): each side's rank statistics, its cards used (the cards drawn
## from its deck) and its life points, and the winner.
func result_stats() -> Dictionary:
	var sides: Array = []
	for side in state.sides:
		var record: Dictionary = side.rank.duplicate()
		record["cards_used"] = DECK_SIZE - side.deck.size()
		record["life_points"] = side.lp
		sides.append(record)
	return {"winner": winner, "sides": sides}


# ---- the hand phase: chains ----------------------------------------------------------------------------------------

func _kind(id: int) -> String:
	return state.card_type(id)


func _is_monster(id: int) -> bool:
	return state.is_monster(id)


## Resolves a chain of cards the player lays out: `ids` in order (a field monster first when one was picked, then hand picks).
## Returns {"card": final card id, "mod": stat modifier carried, "events": [...], "consumed": [...]}.
## Fusion (A + B -> table result, equips and bonuses are lost), equip (+500 / Megamorph +1000 onto the monster), otherwise the
## failed pairing: a non-monster B is thrown away and A stays, any other pairing throws A away and B becomes the base.
func resolve_chain(p: int, ids: Array, base_mod := 0) -> Dictionary:
	var events: Array = []
	if ids.is_empty():
		return {"card": 0, "mod": 0, "events": events}
	var base: int = ids[0]
	var mod := base_mod
	# Reverse Trap on the opposing row turns the first equip's bonus into a loss; the trap is spent on that equip (play springs it)
	var reverse_zone := Effects.find_trap(state, p ^ 1, Effects.REVERSE_TRAP)
	for k in range(1, ids.size()):
		var other: int = ids[k]
		var fused: int = state.data.fuse(base, other)
		if fused != 0:
			base = fused
			mod = 0
			events.append({"kind": "fusion", "result": fused})
			continue
		var equip_id := 0
		if _kind(other) == "Equip" and _is_monster(base) and state.data.can_equip(other, base):
			equip_id = other
		elif _kind(base) == "Equip" and _is_monster(other) and state.data.can_equip(base, other):
			equip_id = base
			base = other
		if equip_id != 0:
			var bonus: int = state.data.equip_bonus(equip_id)
			var reversed := reverse_zone >= 0
			if reversed:
				bonus = -bonus
			mod += bonus
			events.append({"kind": "equip", "equip": equip_id, "bonus": bonus, "reversed": reversed, "trap_zone": reverse_zone})
			if reversed:
				reverse_zone = -1   # the trap is spent on this equip
			continue
		if not _is_monster(other) and _is_monster(base):
			events.append({"kind": "discard", "id": other})
		else:
			events.append({"kind": "discard", "id": base})
			base = other
			mod = 0
	return {"card": base, "mod": mod, "events": events}


## Plays hand cards (indices into the hand, in pick order) with an optional field monster (zone index) as the chain's start.
## A monster result lands in `dest` (an empty monster zone, or the field monster's own zone), a magic or ritual card is used, a
## trap or lone equip is not placed. `star2` selects the second guardian star.
func play(p: int, hand_picks: Array, field_zone := -1, dest := -1, face_down := false, defense := false, star2 := false) -> Array:
	var side = state.sides[p]
	var ids: Array = []
	var mod := 0
	var origin_zone = null
	if field_zone >= 0 and side.monsters[field_zone] != null:
		origin_zone = side.monsters[field_zone]
		ids.append(int(origin_zone["id"]))
		mod = int(origin_zone["mod"])
		side.monsters[field_zone] = null
		if dest < 0:
			dest = field_zone
	var picks: Array = hand_picks.duplicate()
	for i in picks:
		ids.append(int(side.hand[i]))
	var first_slot := hand_slot(side, int(picks[0])) if not picks.is_empty() else 0
	var sorted_picks := picks.duplicate()
	sorted_picks.sort()
	sorted_picks.reverse()
	for i in sorted_picks:
		_remove_hand(side, i)
	var result := resolve_chain(p, ids, mod)
	var events: Array = _with_reverse_trap(p, result["events"])
	var card: int = result["card"]
	if p == 0 and not seen_cards.has(card):
		seen_cards.append(card)
	# the rank counters: a fusion counts when it is started from the hand, an equip when it is valid, a single card from the hand
	# placed face-down counts as a face-down play
	for event in events:
		if event["kind"] == "fusion" and field_zone < 0:
			side.rank["fusions_initiated"] += 1
		elif event["kind"] == "equip":
			side.rank["equips_used"] += 1
	if _kind(card) == "Magic":
		side.rank["pure_magic_used"] += 1
	if _is_monster(card):
		if dest < 0 or side.monsters[dest] != null:
			dest = _free_zone(side.monsters)
		if dest < 0:
			events.append({"kind": "discard", "id": card})
			return events
		var zone: Dictionary = state.make_zone(card, face_down, defense)
		zone["slot"] = first_slot
		zone["mod"] = int(result["mod"])
		zone["star"] = 1 if star2 else 0
		side.monsters[dest] = zone
		events.append({"kind": "summon", "side": p, "zone": dest, "id": card, "face_down": face_down})
		# card placement with a second card in the selection (the game's slots[1]) is a combo play
		if ids.size() >= 2:
			side.rank["combo_plays"] += 1
		if face_down and hand_picks.size() == 1 and field_zone < 0:
			side.rank["face_down_plays"] += 1
	elif _kind(card) == "Trap":
		var slot := _free_zone(side.traps)
		if slot >= 0:
			var trap: Dictionary = state.make_zone(card, true)
			side.traps[slot] = trap
			events.append({"kind": "set_trap", "side": p, "zone": slot, "id": card})
	elif Effects.has_effect(card):
		# every field magic played counts as a change of field, even one that sets the terrain it already has
		if Effects.is_terrain(card):
			side.rank["change_field"] += 1
		events.append_array(Effects.resolve(state, p, card, rng))
	return events


## A card from hand set in the magic and trap row: a magic, equip, ritual or trap goes face-down (or face-up when face_down is false, for
## an equip or magic set face-up). zone is the chosen cell; -1 takes the first empty one (the AI's choice). An occupied or missing cell
## sets nothing.
func set_back_row(p: int, hand_index: int, zone := -1, face_down := true) -> Array:
	var side = state.sides[p]
	var slot := zone if zone >= 0 else _free_zone(side.traps)
	if slot < 0 or slot >= side.traps.size() or side.traps[slot] != null:
		return []
	if hand_index < 0 or hand_index >= side.hand.size():
		return []
	var id: int = int(side.hand[hand_index])
	var card_slot := hand_slot(side, hand_index)
	_remove_hand(side, hand_index)
	side.traps[slot] = state.make_zone(id, face_down)
	side.traps[slot]["slot"] = card_slot
	return [{"kind": "set_back", "side": p, "zone": slot, "id": id}]


## A set equip from the magic/trap row attached to a monster of the same side (the field script's equip activation).
func equip_from_back_row(p: int, trap_zone: int, monster_zone: int) -> Array:
	var side = state.sides[p]
	var equip = side.traps[trap_zone]
	var monster = side.monsters[monster_zone]
	if equip == null or monster == null:
		return []
	var equip_id: int = int(equip["id"])
	if not state.data.can_equip(equip_id, int(monster["id"])):
		return []
	var bonus: int = state.data.equip_bonus(equip_id)
	var reverse_zone := Effects.find_trap(state, p ^ 1, Effects.REVERSE_TRAP)
	if reverse_zone >= 0:
		bonus = -bonus
	monster["mod"] = int(monster["mod"]) + bonus
	side.traps[trap_zone] = null
	side.rank["equips_used"] += 1
	var events: Array = [{"kind": "equip", "side": p, "equip": equip_id, "bonus": bonus, "zone": monster_zone}]
	if reverse_zone >= 0:
		events.append_array(Effects.spring(state, p ^ 1, reverse_zone))
	return events


## A set magic in the magic/trap row is activated from the field: the card leaves the row and its effect resolves as a hand magic's does
## (play). Only a magic card can be activated this way; anything else returns no events.
func activate_back_row(p: int, trap_zone: int) -> Array:
	var side = state.sides[p]
	var zone = side.traps[trap_zone]
	if zone == null or state.card_type(int(zone["id"])) != "Magic":
		return []
	var id: int = int(zone["id"])
	side.traps[trap_zone] = null
	if p == 0 and not seen_cards.has(id):
		seen_cards.append(id)
	side.rank["pure_magic_used"] += 1
	var events: Array = []
	if Effects.has_effect(id):
		if Effects.is_terrain(id):
			side.rank["change_field"] += 1
		events.append_array(Effects.resolve(state, p, id, rng))
	return events


## The Reverse Trap that turned an equip's bonus is spent: its trap event follows the equip's.
func _with_reverse_trap(p: int, events: Array) -> Array:
	var out: Array = []
	for event in events:
		out.append(event)
		if event["kind"] == "equip" and event.get("reversed", false):
			out.append_array(Effects.spring(state, p ^ 1, int(event["trap_zone"])))
	return out


func _has_monster(side) -> bool:
	for zone in side.monsters:
		if zone != null:
			return true
	return false


func _free_zone(row: Array) -> int:
	for i in row.size():
		if row[i] == null:
			return i
	return -1


# ---- the field phase: attacks ------------------------------------------------------------------------------------------

func can_attack(p: int, zone_index: int) -> bool:
	var zone = state.sides[p].monsters[zone_index]
	if zone == null or attack_locked or state.sides[p].swords_turns > 0:
		return false
	return not zone["defense"] and not zone["used"]


func can_change_position(p: int, zone_index: int) -> bool:
	var zone = state.sides[p].monsters[zone_index]
	return zone != null and not zone["used"]


func change_position(p: int, zone_index: int) -> void:
	var zone = state.sides[p].monsters[zone_index]
	if zone != null:
		zone["defense"] = not zone["defense"]
		zone["face_down"] = false


## the guardian star matchup: +-500 for the attacker's star against the defender's.
static func star_bonus(a: int, b: int) -> int:
	var n := 0
	var x := 0
	if a >= 7:
		if b < 7:
			return 0
		n = 4
		x = (a - 7) + 1
		if x >= n:
			x = 0
		if x == b - 7:
			return 500
		x -= 2
		if x < 0:
			x += n
		return -500 if x == b - 7 else 0
	if b - 1 >= 6:
		return 0
	n = 6
	x = a
	if x >= n:
		x = 0
	if x == b - 1:
		return 500
	x -= 2
	if x < 0:
		x += n
	return -500 if x == b - 1 else 0


func star_of(zone: Dictionary) -> int:
	var card: Dictionary = state.data.card(int(zone["id"]))
	return STARS.get(str(card.get("guardian_star_2" if int(zone.get("star", 0)) == 1 else "guardian_star_1", "")), 0)


## A battle: side `p`'s monster in `zone_index` attacks the opponent's monster in `target` (-1 = a direct attack on an empty row).
## Attack traps on the defender's row are checked first. Returns the events.
func attack(p: int, zone_index: int, target := -1) -> Array:
	var events: Array = []
	var me = state.sides[p]
	var foe = state.sides[p ^ 1]
	var attacker = me.monsters[zone_index]
	if attacker == null:
		return events
	# a direct attack is made only when the opponent has no monsters at all (the disc's rule); any other attack on an empty zone is refused
	if (target < 0 or foe.monsters[target] == null) and _has_monster(foe):
		return events
	attacker["used"] = true
	attacker["face_down"] = false
	var attack_value: int = state.atk(attacker)
	# the attack traps (and Fake Trap) on the defender's magic/trap row
	var trap_zone := Effects.select_attack_trap(state, p ^ 1, attack_value)
	if trap_zone >= 0:
		var trap: Dictionary = foe.traps[trap_zone]
		foe.traps[trap_zone] = null
		foe.rank["traps_triggered"] += 1
		events.append({"kind": "trap", "side": p ^ 1, "id": int(trap["id"]), "zone": trap_zone})
		if int(trap["id"]) != Effects.FAKE_TRAP:
			me.monsters[zone_index] = null
			events.append({"kind": "destroyed", "side": p, "zone": zone_index})
		return events
	var defender = null
	if target >= 0:
		defender = foe.monsters[target]
	if defender == null:
		# a direct attack: the attack value is the damage
		var damage := mini(attack_value, foe.lp)
		foe.lp -= damage
		events.append({"kind": "direct", "side": p ^ 1, "damage": damage})
		check_winner()
		return events
	defender["face_down"] = false
	var wanted: int = state.def(defender) if defender["defense"] else state.atk(defender)
	var bonus := star_bonus(star_of(attacker), star_of(defender))
	var actual: int
	if attacker["defense"]:
		actual = mini(state.def(attacker) + bonus, 9999)
	else:
		actual = mini(attack_value + bonus, 9999)
	var r: int
	if actual != wanted:
		r = actual - wanted
	elif attacker["defense"] or defender["defense"]:
		r = 0
	else:
		r = -1
	events.append({"kind": "battle", "attacker": zone_index, "target": target, "result": r})
	if r > 0:
		foe.monsters[target] = null
		events.append({"kind": "destroyed", "side": p ^ 1, "zone": target})
		# the battle resolution's win branch: a defense-position monster is destroyed and counts as a defensive loss of its side; an
		# attack-position monster takes the damage and both count (card destruction, effective attack)
		me.rank["card_destruction"] += 1
		if defender["defense"]:
			foe.rank["defensive_losses"] += 1
		else:
			var loss := mini(r, foe.lp)
			foe.lp -= loss
			events.append({"kind": "lp", "side": p ^ 1, "amount": -loss})
			me.rank["effective_attacks"] += 1
	elif r == -1:
		foe.monsters[target] = null
		me.monsters[zone_index] = null
		events.append({"kind": "destroyed", "side": p ^ 1, "zone": target})
		events.append({"kind": "destroyed", "side": p, "zone": zone_index})
	elif r < -1:
		var loss2 := mini(-r, me.lp)
		me.lp -= loss2
		events.append({"kind": "lp", "side": p, "amount": -loss2})
		if defender["defense"]:
			# a defense-position defender that holds through the attack counts as a defensive win
			foe.rank["defensive_wins"] += 1
		else:
			me.monsters[zone_index] = null
			events.append({"kind": "destroyed", "side": p, "zone": zone_index})
	check_winner()
	return events

## The deck slot (1 to 40) of the hand card at index i, or 0 when the side has no slot for it (a test's hand set by hand).
static func hand_slot(side, i: int) -> int:
	return int(side.hand_slots[i]) if i >= 0 and i < side.hand_slots.size() else 0


func _pad_hand_slots(side) -> void:
	while side.hand_slots.size() < side.hand.size():
		side.hand_slots.append(0)


func _remove_hand(side, i: int) -> void:
	_pad_hand_slots(side)
	side.hand.remove_at(i)
	if i < side.hand_slots.size():
		side.hand_slots.remove_at(i)
