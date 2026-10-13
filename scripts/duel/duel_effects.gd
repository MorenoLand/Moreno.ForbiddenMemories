extends RefCounted
## What a magic card does when it is played, the retail rules of the card effect dispatcher (ids 301..350, 651..700 and 721 map to
## handler groups). Each call resolves a card for side `p` against `p ^ 1` and returns the events a presentation would show.
## Event shapes: {kind: "lp", side, amount}, {kind: "remove", side, row: "monsters"|"traps", zone}, {kind: "terrain", value},
## {kind: "reveal", side, zone}, {kind: "defense_off", side, zone}, {kind: "stat", side, zone, delta}, {kind: "swords", side}.

const DuelState = preload("res://scripts/duel/duel_state.gd")

const LP_RECOVERY := {338: 200, 339: 500, 340: 1000, 341: 2000, 342: 5000}
const DIRECT_DAMAGE := {343: 50, 344: 100, 345: 200, 346: 500, 347: 1000}
## Monster-removal selectors: a monster type name, or an ATK threshold (Crush Card).
const REMOVAL_TYPE := {653: "Warrior", 656: "Zombie", 660: "Machine", 662: "Insect", 663: "Rock", 664: "Fish"}
const CRUSH_CARD := 661
const CRUSH_THRESHOLD := 1500
const SWORDS_TURNS := 4    # the swords initial counter: the opponent is locked for three of its turns
const GOBLIN_FAN := 687
const BAD_REACTION := 688
const REVERSE_TRAP := 689
const FAKE_TRAP := 690
## Attack traps and the highest attack each one catches.
const ATTACK_TRAPS := {681: 500, 682: 1000, 683: 1500, 684: 2000, 685: 3000, 686: 25500}
const MEGAMORPH := 657


## True when the card id goes through the effect dispatcher at all (as opposed to being a plain equip, a trap or a monster).
static func has_effect(id: int) -> bool:
	return (id >= 329 and id <= 350) or REMOVAL_TYPE.has(id) or id in [CRUSH_CARD, 320, 655, 669, 672, 721] or is_ritual(id)


static func is_ritual(id: int) -> bool:
	return id in [665, 666, 667, 670, 671, 673, 674, 675, 676, 677, 678, 679, 680, 691, 692, 693, 694, 695, 696, 697, 698, 699, 700, 721]


## the trap selection by card id: the zone of an occupied trap with this id on the magic/trap row of `side`, or -1.
static func find_trap(s, side: int, id: int) -> int:
	var row: Array = s.sides[side].traps
	for i in row.size():
		if row[i] != null and int(row[i]["id"]) == id:
			return i
	return -1


## True for the field magics (the terrains: Forest to Dark), each application of which counts as a field change for the rank.
static func is_terrain(id: int) -> bool:
	return id >= 330 and id <= 335


static func resolve(s, p: int, id: int, rng: RandomNumberGenerator) -> Array:
	var events: Array = []
	var me = s.sides[p]
	var foe = s.sides[p ^ 1]
	if is_terrain(id):
		s.terrain = id - 329
		events.append({"kind": "terrain", "value": s.terrain})
	elif LP_RECOVERY.has(id):
		var amount: int = LP_RECOVERY[id]
		var bad_reaction := find_trap(s, p ^ 1, BAD_REACTION)
		if bad_reaction >= 0:
			events.append_array(spring(s, p ^ 1, bad_reaction))
			me.lp = maxi(me.lp - amount, 0)
			events.append({"kind": "lp", "side": p, "amount": -amount, "effect": "heal", "unit": id - 338 + 5})
		else:
			# healing never lowers LP: a side above its maximum keeps what it has (the ceiling is the higher of the two)
			var before: int = me.lp
			var ceiling: int = maxi(me.max_lp, before)
			me.lp = mini(before + amount, ceiling)
			events.append({"kind": "lp", "side": p, "amount": me.lp - before, "effect": "heal", "unit": id - 338})
	elif DIRECT_DAMAGE.has(id):
		var damage: int = DIRECT_DAMAGE[id]
		var target := p ^ 1
		var goblin := find_trap(s, p ^ 1, GOBLIN_FAN)
		if goblin >= 0:
			# the reflected amount: the disc reads one entry past its damage table for this (not decoded); the played card's damage is used
			events.append_array(spring(s, p ^ 1, goblin))
			target = p
		var hit = s.sides[target]
		var lost: int = mini(damage, hit.lp)
		hit.lp -= lost
		# the table unit: the card's index in its five (goblin fan reflects it onto the unit past the table: 5)
		events.append({"kind": "lp", "side": target, "amount": -lost, "effect": "damage", "unit": 5 if goblin >= 0 else id - 343})
	elif id == 336:
		# Dark Hole: both sides' monster and magic/trap rows
		for side in 2:
			for row in ["monsters", "traps"]:
				_clear_row(s, events, side, row)
	elif id == 329:
		# Dragon Capture Jar: the opponent's Dragons
		for i in DuelState.ZONES:
			var zone = foe.monsters[i]
			if zone != null and s.card_type(int(zone["id"])) == "Dragon":
				foe.monsters[i] = null
				events.append({"kind": "remove", "side": p ^ 1, "row": "monsters", "zone": i})
	elif REMOVAL_TYPE.has(id) or id == CRUSH_CARD:
		for i in DuelState.ZONES:
			var zone = foe.monsters[i]
			if zone == null:
				continue
			var hit_it: bool = s.atk(zone) >= CRUSH_THRESHOLD if id == CRUSH_CARD else s.card_type(int(zone["id"])) == REMOVAL_TYPE[id]
			if hit_it:
				foe.monsters[i] = null
				events.append({"kind": "remove", "side": p ^ 1, "row": "monsters", "zone": i})
	elif id == 320:
		# Stop Defense: the opponent's defending monsters turn to attack position
		for i in DuelState.ZONES:
			var zone = foe.monsters[i]
			if zone != null and zone["defense"]:
				zone["defense"] = false
				events.append({"kind": "defense_off", "side": p ^ 1, "zone": i})
	elif id == 337:
		_clear_row(s, events, p ^ 1, "monsters")
	elif id == 350:
		# Dark-piercing Light: the opponent's face-down monsters are revealed (the disc sweeps one side's monster row, and the AI
		# plays the card against the player's face-down monsters)
		for i in DuelState.ZONES:
			var zone = foe.monsters[i]
			if zone != null and zone["face_down"]:
				zone["face_down"] = false
				events.append({"kind": "reveal", "side": p ^ 1, "zone": i})
	elif id == 349 or id == 669:
		var penalty := 500 if id == 349 else 1000
		for i in DuelState.ZONES:
			var zone = foe.monsters[i]
			if zone != null:
				zone["mod"] = int(zone["mod"]) - penalty
				events.append({"kind": "stat", "side": p ^ 1, "zone": i, "delta": -penalty})
	elif id == 348:
		# Swords of Revealing Light: the opponent's face-down monsters are revealed and it cannot attack for three turns
		for i in DuelState.ZONES:
			var zone = foe.monsters[i]
			if zone != null and zone["face_down"]:
				zone["face_down"] = false
				events.append({"kind": "reveal", "side": p ^ 1, "zone": i})
		foe.swords_turns = SWORDS_TURNS
		events.append({"kind": "swords", "side": p ^ 1})
	elif id == 655:
		# Cursebreaker: the acting side's monsters lose their negative modifiers
		for i in DuelState.ZONES:
			var zone = me.monsters[i]
			if zone != null and int(zone["mod"]) < 0:
				events.append({"kind": "stat", "side": p, "zone": i, "delta": -int(zone["mod"])})
				zone["mod"] = 0
	elif id == 672:
		# Harpie's Feather Duster: the opponent's magic/trap row
		_clear_row(s, events, p ^ 1, "traps")
	elif is_ritual(id):
		events.append_array(_ritual(s, p, id, rng))
	return events


static func _clear_row(s, events: Array, side: int, row: String) -> void:
	var cells: Array = s.sides[side].monsters if row == "monsters" else s.sides[side].traps
	for i in cells.size():
		if cells[i] != null:
			cells[i] = null
			events.append({"kind": "remove", "side": side, "row": row, "zone": i})


## the ritual check (retail): the ritual's recipe, with each tribute matched to the first occupied monster on the player's own
## row that has exactly that card id. Returns {result, zones[3]} or {} when a tribute is missing.
static func ritual_match(s, p: int, id: int) -> Dictionary:
	for recipe in s.data.rituals:
		if int(recipe["id"]) != id:
			continue
		var taken: Array = []
		for tribute in recipe["tribute_ids"]:
			var found := -1
			for i in DuelState.ZONES:
				var zone = s.sides[p].monsters[i]
				if zone != null and int(zone["id"]) == int(tribute) and not taken.has(i):
					found = i
					break
			if found < 0:
				return {}
			taken.append(found)
		return {"result": int(recipe["result_id"]), "zones": taken}
	return {}


## The ritual monster takes the zone of the middle tribute; the other two tributes are removed. The guardian star is a coin flip.
static func _ritual(s, p: int, id: int, rng: RandomNumberGenerator) -> Array:
	var events: Array = []
	var found := ritual_match(s, p, id)
	if found.is_empty():
		return events
	var zones: Array = found["zones"]
	var row: Array = s.sides[p].monsters
	for z in zones:
		row[z] = null
		events.append({"kind": "remove", "side": p, "row": "monsters", "zone": z})
	var summoned: Dictionary = s.make_zone(int(found["result"]))
	summoned["star"] = rng.randi() & 1
	row[zones[1]] = summoned
	events.append({"kind": "summon", "side": p, "zone": zones[1], "id": int(found["result"])})
	return events


## Equip bonus placement: +500 to ATK and DEF (Megamorph 1000). With Reverse Trap on the opponent's row the bonus becomes a loss.
static func equip(s, p: int, zone_index: int, equip_id: int) -> Array:
	var zone = s.sides[p].monsters[zone_index]
	if zone == null:
		return []
	var bonus: int = s.data.equip_bonus(equip_id)
	if find_trap(s, p ^ 1, REVERSE_TRAP) >= 0:
		bonus = -bonus
	zone["mod"] = int(zone["mod"]) + bonus
	return [{"kind": "stat", "side": p, "zone": zone_index, "delta": bonus}]


## Springs the trap in `zone` of `side`'s magic/trap row: the card leaves the row, its owner's traps-triggered count goes up, and
## the trap event is returned for the presentation. Used by the traps that act on a card's play (Bad Reaction, Goblin Fan, Reverse Trap).
static func spring(s, side: int, zone: int) -> Array:
	var trap = s.sides[side].traps[zone]
	if trap == null:
		return []
	s.sides[side].traps[zone] = null
	s.sides[side].rank["traps_triggered"] += 1
	return [{"kind": "trap", "side": side, "id": int(trap["id"]), "zone": zone}]


## the attack trap selection: the face-up or face-down attack trap on `defender`'s row that catches an attacker of this attack:
## the eligible trap with the lowest threshold; with none, Fake Trap if it is there. Returns the zone or -1.
static func select_attack_trap(s, defender: int, attack: int) -> int:
	var best := -1
	var best_threshold := 1 << 30
	var row: Array = s.sides[defender].traps
	for i in row.size():
		var trap = row[i]
		if trap == null or not ATTACK_TRAPS.has(int(trap["id"])):
			continue
		var threshold: int = ATTACK_TRAPS[int(trap["id"])]
		if threshold >= attack and threshold < best_threshold:
			best = i
			best_threshold = threshold
	if best >= 0:
		return best
	return find_trap(s, defender, FAKE_TRAP)
