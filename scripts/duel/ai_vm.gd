extends RefCounted
## The computer duelist's bytecode interpreter. One hand program and one field program (assets/data/ai_scripts/hand.bin and
## field.bin, extracted by tools/extract.py) serve every duelist: they read the duelist id (opcode 0x15) and its row of
## duelists.json "ai" and branch on them. Each run works over a snapshot of the duel laid out as the routine at 0x80027DF8 lays it out
## (active-card slots: 1..5 own monsters, 6..10 own traps, 11.. own hand then the remaining deck, 56..60 foe monsters,
## 61..65 foe traps, 66..70 foe hand), with the registers, card and type sets, fusion search and selection record of
## the script interpreter and the opcode and fusion search handlers. Retail branches only (the arms the retail build takes).
## Not established by the code read so far: the rand() sequence (the port's RNG stands in), the controller's exact field
## semantics for every category value (see field_action), and the ritual check's side argument (the acting side's own field is used).

const Effects = preload("res://scripts/duel/duel_effects.gd")

const MEMORY_COUNT := 20
const RETURN_STACK := 8
const CARD_SET_COUNT := 32
const TYPE_SET_COUNT := 25
const FUSION_USED_COUNT := 0x2A
const SNAPSHOT_SLOTS := 71
const RUN_BUDGET := 200000
const SEL_SIZE := 16

const TYPE_NAMES := ["Dragon", "Spellcaster", "Zombie", "Warrior", "Beast-Warrior", "Beast", "Winged Beast", "Fiend", "Fairy", "Insect",
		"Dinosaur", "Reptile", "Fish", "Sea Serpent", "Machine", "Thunder", "Aqua", "Pyro", "Rock", "Plant", "Magic", "Trap", "Ritual", "Equip"]
const TYPE_MAGIC := 20
const TYPE_TRAP := 21
const TYPE_RITUAL := 22
const TYPE_EQUIP := 23
const FLAG_DEFENSE := 0x800
const FLAG_FACE_DOWN := 0x1000
const FLAG_USED := 0x4000
const FLAG_OCCUPIED := 0x8000
const STAT_MAX := 9999
const DIRECT_DAMAGE := {343: 50, 344: 100, 345: 200, 346: 500, 347: 1000}
const FIELD_CATEGORY_NONE := 0x3A

# the selection record the data at 0x800EAE88 (AiSelection): combo 0..4, zero 5, position 6, guardian star 7, face-down 8, slot 9, category 10, third 11
const SEL_COMBO := 0
const SEL_POSITION := 6
const SEL_STAR := 7
const SEL_RANDOM := 8
const SEL_SLOT := 9
const SEL_CATEGORY := 10
const SEL_THIRD := 11

const CONTINUE := 0
const END_HAND := 1
const PLAY_FIELD_CARD := 2
const END_FIELD := 3
const FAULT := -1

var engine
var duelist := 0
var row: Array = [0, 0, 0, 0, 0, 0, 0, 0, 0]
var hand_program := PackedByteArray()
var field_program := PackedByteArray()

# the interpreter
var prog := PackedByteArray()
var cursor := 0
var fault := false
var mem := PackedInt32Array()
var stack := PackedInt32Array()
var depth := 0
var card_set := PackedInt32Array()
var type_set := PackedInt32Array()
var combo := PackedInt32Array()
var sel := PackedInt32Array()
var field97 := 0
var snap: Array = []
var side := 1
var best_difference := 0       # the best difference: no writer in the code read so far
var best_attacker := 0         # the best attacker: no writer in the code read so far
var best_target := 0           # the best target: no writer in the code read so far
var attack_best_stat := 0
var attack_best_slot := 0
var attack_best_target := 0
var fus_count := 0
var fus_limit := 0
var fus_set := 0
var fus_best := 0
var fus_depth := 0
var fus_best_depth := 0
var fus_path := PackedInt32Array()
var fus_used := PackedInt32Array()
var noops := 0


func _init(duel_engine, duelist_id: int, hand_bytes: PackedByteArray, field_bytes: PackedByteArray) -> void:
	engine = duel_engine
	duelist = duelist_id
	hand_program = hand_bytes
	field_program = field_bytes
	if duelist >= 0 and duelist < engine.state.data.duelists.size():
		var ai = engine.state.data.duelists[duelist].get("ai", [])
		if ai.size() >= 9:
			row = ai.duplicate()


# ---- decisions ----------------------------------------------------------------------------------------------------------

## The hand phase of side `p`: the hand program's selection, with its deck picks swapped into the hand (the routine at 0x8001BAF0).
## Returns {} for no play, else {"picks": hand indices in play order, "dest": monster zone or -1, "face_down", "star2"}.
func hand_plan(p: int) -> Dictionary:
	side = p
	_init_run(p, hand_program)
	if _run() != END_HAND:
		return {}
	var s = engine.state
	var hand: Array = s.sides[p].hand
	var deck: Array = s.sides[p].deck
	var picks: Array = []
	for i in 5:
		if sel[i] == 0:
			break
		picks.append(sel[i])
	var used := []
	used.resize(5)
	used.fill(false)
	for v in picks:
		if v >= 11 and v < 16 and v - 11 < 5:
			used[v - 11] = true
	var out: Array = []
	for v in picks:
		if v < 11:
			continue            # field-slot picks (1..10) are not hand plays; the port skips them
		if v < 16:
			if v - 11 < hand.size():
				out.append(v - 11)
			continue
		var j := -1
		for k in mini(5, hand.size()):
			if not used[k]:
				j = k
				break
		if j < 0 or v - 16 >= deck.size():
			continue
		var d: int = v - 16
		var card = hand[j]
		hand[j] = deck[d]
		deck[d] = card
		var hs: Array = s.sides[p].hand_slots
		var ds: Array = s.sides[p].deck_slots
		if j < hs.size() and d < ds.size():
			var slot = hs[j]
			hs[j] = ds[d]
			ds[d] = slot
		used[j] = true
		out.append(j)
	if out.is_empty():
		return {}
	var zone := -1
	if sel[SEL_POSITION] >= 1 and sel[SEL_POSITION] <= 5:
		zone = sel[SEL_POSITION] - 1
	return {"picks": out, "dest": zone, "face_down": sel[SEL_RANDOM] != 0, "star2": (sel[SEL_STAR] & 1) != 0}


## The next field decision of side `p`: a fresh snapshot and a fresh run after every action (the controller re-initializes the
## program). Returns {"kind": "end"}, {"kind": "attack", "zone", "target"} (target -1 is a direct attack), {"kind": "defense",
## "zone"} (turn the monster to defense and spend it), {"kind": "equip", "trap", "zone"} (attach a set equip from the back row),
## {"kind": "spent", "row", "zone"} (mark a card used with no other effect) or {"kind": "noop"} (the program asked for something the
## port cannot do; the same decision is asked again, and three in a row end the field phase).
##
## PlayFieldCard's operands: slot = the own card acting (1..5 monsters, 6..10 back row), category = the target (56..60 foe
## monsters, 1..10 own cards, 0 none, 0x3A for 0xFF or above), third = the mode. A monster with no target and a nonzero mode goes
## to defense and is spent. A card with no target is spent. Attacks use the target slot directly. Magic activations from the back
## row are not representable (magic resolves when it is played from hand).
func field_action(p: int) -> Dictionary:
	side = p
	var s = engine.state
	var me = s.sides[p]
	var foe = s.sides[p ^ 1]
	var result := {"kind": "end"}
	_init_run(p, field_program)
	var code := _run()
	if code != PLAY_FIELD_CARD:
		noops = 0
		return result
	var slot: int = int(sel[SEL_SLOT])
	var category: int = int(sel[SEL_CATEGORY])
	var third: int = int(sel[SEL_THIRD])
	var zone = null
	var row_name := "monsters"
	if slot >= 1 and slot <= 5:
		zone = me.monsters[slot - 1]
	elif slot >= 6 and slot <= 10:
		zone = me.traps[slot - 6]
		row_name = "traps"
	if zone != null:
		if slot <= 5 and category >= 56 and category <= 60:
			var target: int = category - 56
			if foe.monsters[target] != null:
				result = {"kind": "attack", "zone": slot - 1, "target": target}
			elif _count(foe.monsters) == 0:
				result = {"kind": "attack", "zone": slot - 1, "target": -1}
		elif slot <= 5 and category == 0 and third != 0:
			# the position branch: the card turns to defense (or, already there, is only spent) and is marked used
			result = {"kind": "defense", "zone": slot - 1}
		elif slot >= 6 and category >= 1 and category <= 5 and _kind(int(zone["id"])) == TYPE_EQUIP and me.monsters[category - 1] != null:
			# the field program's equip activation: a set equip (back row) onto an own monster
			result = {"kind": "equip", "trap": slot - 6, "zone": category - 1}
		elif category == 0 or (slot >= 6 and category >= 1 and category <= 10):
			# a card with no action this port can take: it is marked used and the program moves on
			result = {"kind": "spent", "row": row_name, "zone": slot - 1 if slot <= 5 else slot - 6}
	if result["kind"] == "end":
		noops += 1
		if noops >= 3:
			noops = 0
			return {"kind": "end"}
		return {"kind": "noop"}
	noops = 0
	return result


func _count(row_values: Array) -> int:
	var n := 0
	for zone in row_values:
		if zone != null:
			n += 1
	return n


# ---- the snapshot (the routine at 0x80027DF8) ---------------------------------------------------------------------------------------

func _empty() -> Dictionary:
	return {"id": 0, "atk": 0, "def": 0, "flags": 0, "type": 0, "star": 0, "star2": 0, "deck": 0}


func _kind(id: int) -> int:
	if id < 1 or id > engine.state.data.cards.size():
		return 0
	var name: String = engine.state.card_type(id)
	var at := TYPE_NAMES.find(name)
	return at if at >= 0 else 0


func _base_stat(id: int, which: int) -> int:
	if id < 1 or id > engine.state.data.cards.size():
		return 0
	var card: Dictionary = engine.state.data.card(id)
	var v := int(card.get("defense" if which != 0 else "attack", 0))
	var s: int = v + engine.state.terrain_boost(id)
	if s < 0:
		return 0
	return mini(s, STAT_MAX)


func _zone_record(zone) -> Dictionary:
	var r := _empty()
	if zone == null:
		return r
	var id := int(zone["id"])
	var flags := FLAG_OCCUPIED
	if zone["defense"]:
		flags |= FLAG_DEFENSE
	if zone["face_down"]:
		flags |= FLAG_FACE_DOWN
	if zone["used"]:
		flags |= FLAG_USED
	var card: Dictionary = engine.state.data.card(id)
	var stars: Dictionary = engine.STARS
	var star1: int = stars.get(str(card.get("guardian_star_1", "")), 0)
	var star2: int = stars.get(str(card.get("guardian_star_2", "")), 0)
	r["id"] = id
	r["atk"] = engine.state.atk(zone)
	r["def"] = engine.state.def(zone)
	r["flags"] = flags
	r["type"] = _kind(id)
	r["star"] = star2 if int(zone.get("star", 0)) == 1 else star1
	r["star2"] = star2
	return r


func _card_record(id: int) -> Dictionary:
	var r := _empty()
	var card: Dictionary = engine.state.data.card(id)
	var stars: Dictionary = engine.STARS
	r["id"] = id
	r["atk"] = int(card.get("attack", 0))
	r["def"] = int(card.get("defense", 0))
	r["type"] = _kind(id)
	r["star"] = stars.get(str(card.get("guardian_star_1", "")), 0)
	r["star2"] = stars.get(str(card.get("guardian_star_2", "")), 0)
	return r


func _build_snapshot(p: int) -> Array:
	var s = engine.state
	var me = s.sides[p]
	var foe = s.sides[p ^ 1]
	var out: Array = []
	for i in SNAPSHOT_SLOTS:
		out.append(_empty())
	for i in 5:
		out[1 + i] = _zone_record(me.monsters[i])
		out[6 + i] = _zone_record(me.traps[i])
		out[56 + i] = _zone_record(foe.monsters[i])
		out[61 + i] = _zone_record(foe.traps[i])
	for j in me.hand.size():
		out[11 + j] = _card_record(int(me.hand[j]))
	var base: int = 11 + me.hand.size()
	for d in me.deck.size():
		if base + d > 55:
			break
		var rec := _card_record(int(me.deck[d]))
		rec["deck"] = d
		out[base + d] = rec
	for j in mini(5, foe.hand.size()):
		out[66 + j] = _card_record(int(foe.hand[j]))
	return out


# ---- interpreter state --------------------------------------------------------------------------------------------------

func _init_run(p: int, program: PackedByteArray) -> void:
	prog = program
	cursor = 0
	fault = false
	depth = 0
	mem = PackedInt32Array()
	mem.resize(MEMORY_COUNT)
	mem.fill(0)
	stack = PackedInt32Array()
	stack.resize(RETURN_STACK)
	stack.fill(0)
	card_set = PackedInt32Array()
	card_set.resize(CARD_SET_COUNT)
	card_set.fill(0)
	type_set = PackedInt32Array()
	type_set.resize(TYPE_SET_COUNT)
	type_set.fill(0)
	combo = PackedInt32Array()
	combo.resize(COMBO_CARDS_MAX())
	combo.fill(0)
	sel = PackedInt32Array()
	sel.resize(SEL_SIZE)
	sel.fill(0)
	field97 = 0
	fus_count = 0
	fus_limit = 0
	fus_set = 0
	fus_best = 0
	fus_depth = 0
	fus_best_depth = 0
	fus_path = PackedInt32Array()
	fus_path.resize(8)
	fus_path.fill(0)
	fus_used = PackedInt32Array()
	fus_used.resize(FUSION_USED_COUNT)
	fus_used.fill(0)
	snap = _build_snapshot(p)


func COMBO_CARDS_MAX() -> int:
	return 8


## the original's run routine: executes until a terminal handler (1 EndHand, 2 PlayFieldCard, 3 EndField). Returns 0 when the budget runs out
## (the retail yields at VSync 240 and resumes; the port has no frame clock, so a long run is cut here) and -1 on a fault.
func _run() -> int:
	for _n in RUN_BUDGET:
		if cursor < 0 or cursor >= prog.size():
			return FAULT
		var op := int(prog[cursor])
		cursor += 1
		var r := _exec(op)
		if fault:
			return FAULT
		if r != CONTINUE:
			return r
	return CONTINUE


func _u8() -> int:
	if cursor >= prog.size():
		fault = true
		return 0
	var v := int(prog[cursor])
	cursor += 1
	return v


func _u16() -> int:
	var lo := _u8()
	var hi := _u8()
	return lo | (hi << 8)


func _m(i: int) -> int:
	if i < 0 or i >= MEMORY_COUNT:
		fault = true
		return 0
	return mem[i]


func _w(i: int, v: int) -> void:
	if i < 0 or i >= MEMORY_COUNT:
		fault = true
		return
	mem[i] = v


func _slot(i: int) -> Dictionary:
	if i < 0 or i >= SNAPSHOT_SLOTS:
		return _empty()
	return snap[i]


func _s8(x: int) -> int:
	return ((x + 128) & 255) - 128


func _byte(x: int) -> int:
	return x & 255


func _range(kind: int) -> Vector2i:
	var hs := int(row[0]) if row.size() > 0 else 0
	match kind:
		0, 1:
			return Vector2i(1, 5)
		2, 3:
			return Vector2i(6, 10)
		4:
			return Vector2i(11, hs + 10)
		5, 6:
			return Vector2i(56, 60)
		7, 8:
			return Vector2i(61, 65)
		9:
			return Vector2i(66, 70)
	return Vector2i(1, 0)


func _win_range(kind: int) -> Vector2i:
	var hs := int(row[0]) if row.size() > 0 else 0
	match kind:
		0, 1:
			return Vector2i(1, 5)
		2:
			return Vector2i(11, hs + 10)
		3, 4, 5:
			return Vector2i(56, 60)
		6:
			return Vector2i(66, 70)
	return Vector2i(1, 0)


func _in_card_set(index: int) -> bool:
	var id: int = _slot(index)["id"]
	for i in CARD_SET_COUNT:
		if card_set[i] == id:
			return true
	return false


func _in_type_set(index: int) -> bool:
	var t: int = _slot(index)["type"]
	for i in TYPE_SET_COUNT:
		if t == type_set[i] - 1:
			return true
	return false


func _in_sets(mode: int, index: int) -> bool:
	if mode == 1 and _in_card_set(index):
		return true
	if mode == 2 and _in_type_set(index):
		return true
	return false


# ---- the opcode table (0x800916E0) ----------------------------------------------------------------

func _exec(op: int) -> int:
	match op:
		1:  # Jump
			cursor = _u16()
		2, 3, 4, 5:  # JumpGreaterEqual, JumpGreater, JumpEqual, JumpNotEqual
			var a := _m(_u8())
			var b := _m(_u8())
			var target := _u16()
			var hit := false
			match op:
				2: hit = a >= b
				3: hit = a > b
				4: hit = a == b
				5: hit = a != b
			if hit:
				cursor = target
		6:  # JumpBetween
			var v := _m(_u8())
			var hi := _m(_u8())
			var lo := _m(_u8())
			var target := _u16()
			if v <= hi and lo <= v:
				cursor = target
		7:  # JumpRandom
			var limit := _m(_u8())
			var target := _u16()
			if engine.rng.randi() % 100 < limit:
				cursor = target
		8:  # Call
			var target := _u16()
			if depth >= RETURN_STACK:
				fault = true
				return CONTINUE
			stack[depth] = cursor
			depth += 1
			cursor = target
		9:  # Return
			if depth <= 0:
				fault = true
				return CONTINUE
			depth -= 1
			cursor = stack[depth]
		10:  # SetRandom
			var lo := _u16()
			var hi := _u16()
			var idx := _u8()
			var span := hi - lo + 1
			_w(idx, (engine.rng.randi() % span if span > 0 else 0) + lo)
		11:  # Subtract
			var a := _m(_u8())
			var b := _m(_u8())
			_w(_u8(), a - b)
		12:  # PlayFieldCard
			var first := _m(_u8())
			var second := _m(_u8())
			var third := _m(_u8())
			var category := _m(_u8())
			sel[SEL_SLOT] = _s8(first)
			sel[SEL_THIRD] = _s8(third)
			if category == 0:
				if first >= 6 and second == 1:
					sel[SEL_CATEGORY] = _s8(first)
				else:
					sel[SEL_CATEGORY] = 0
			elif category < 0xFF:
				sel[SEL_CATEGORY] = _s8(category)
			else:
				sel[SEL_CATEGORY] = FIELD_CATEGORY_NONE
			return PLAY_FIELD_CARD
		13:  # EndHand
			return END_HAND
		14:  # EndField
			return END_FIELD
		15:  # CalcCardPower
			var card := _m(_u8())
			var mode := _m(_u8())
			var dst := _u8()
			_w(dst, _calc_card_power(card, mode))
		16:  # TestHighStat
			var card := _m(_u8())
			var dst := _u8()
			var result := 0
			if card >= 1 and _kind(card) < TYPE_MAGIC:
				result = 1 if _base_stat(card, 1) >= _base_stat(card, 0) else 0
			_w(dst, result)
		17:  # LoadCardType
			var card := _m(_u8())
			_w(_u8(), _kind(card) if card >= 1 else 0)
		18:  # LoadCardID
			var slot := _m(_u8())
			_w(_u8(), _slot(slot)["id"])
		19:  # SetFaceDown
			var val := _m(_u8())
			var dst := _u8()
			var rec := _slot(val)
			var flag := 0
			if rec["id"] != 0:
				flag = 2 if (rec["flags"] & FLAG_FACE_DOWN) != 0 else 1
			_w(dst, flag)
		20:  # LoadLifePoint
			var i := _m(_u8())
			_w(_u8(), engine.state.sides[side ^ i].lp if i == 0 or i == 1 else 0)
		21:  # LoadOpponentID
			_w(_u8(), duelist)
		22:  # LoadTerrain
			_w(_u8(), engine.state.terrain)
		23:  # LoadDeckSize
			var count := 0
			for i in range(11, 56):
				if snap[i]["id"] != 0:
					count += 1
			_w(_u8(), count - 5)
		24:  # LoadSelectionRandom
			_w(_u8(), sel[SEL_RANDOM])
		25:  # TestPinned
			var idx := _m(_u8())
			var dst := _u8()
			var who := (side ^ 1) ^ idx
			var pinned := 0
			if who >= 0 and who <= 1:
				pinned = 1 if engine.state.sides[who].swords_turns != 0 else 0
			_w(dst, pinned)
		26:  # StartCombo
			var dst := _u8()
			var value := 0
			for i in 5:
				var v: int = combo[i]
				if v >= 1 and v <= 10:
					value = v
					break
			_w(dst, value)
		27:  # LoadBestDifference
			_w(_u8(), best_difference)
		28:  # LoadBestAttacker
			_w(_u8(), best_attacker)
		29:  # LoadBestTarget
			_w(_u8(), best_target)
		30, 31:  # FindStrongest, FindWeakest
			var mode := _m(_u8())
			var kind := _m(_u8())
			var hide := _m(_u8())
			var sets := _m(_u8())
			var dst := _u8()
			if op == 30:
				_w(dst, _find_strongest(mode, kind, hide, sets))
			else:
				_w(dst, _find_weakest(mode, kind, hide, sets))
		32:  # FindKiller
			var a := _m(_u8())
			var m := _m(_u8())
			var w := _u8()
			_w(w, _find_killer(a, m))
		33:  # FindDefenseStopper
			var hide := _m(_u8())
			var dst := _u8()
			_w(dst, _find_defense_stopper(hide))
		34:  # CountCards
			var kind := _m(_u8())
			var dst := _u8()
			_w(dst, _count_cards(kind))
		35:  # FindFirstCard
			var wanted := _m(_u8())
			var kind := _m(_u8())
			var dst := _u8()
			_w(dst, _find_first_card(wanted, kind))
		36:  # FindCard
			var wanted := _m(_u8())
			var kind := _m(_u8())
			var visible := _m(_u8())
			var dst := _u8()
			_w(dst, _find_card(wanted, kind, visible))
		37:  # MatchType
			var t := _m(_u8())
			var kind := _m(_u8())
			var set := _m(_u8())
			var sets := _m(_u8())
			var dst := _u8()
			_w(dst, _match_type(t, kind, set, sets))
		38:  # FindEquipTarget
			var owner := _m(_u8())
			var mode := _m(_u8())
			var kind := _m(_u8())
			var dst := _u8()
			_w(dst, _find_equip_target(owner, mode, kind))
		39:  # CheckRitual
			var card := _m(_u8())
			var dst := _u8()
			_w(dst, 1 if _check_ritual(card) else 0)
		40:  # FindFirstMonster
			var dst := _u8()
			var found := 0
			for i in 5:
				var index: int = int(sel[i])
				var rec := _slot(index)
				if rec["id"] != 0 and rec["type"] < TYPE_MAGIC:
					found = index
					break
			_w(dst, found)
		41:  # FindFirstType
			var t := _m(_u8())
			var dst := _u8()
			var found := 0
			for i in 5:
				var index: int = int(sel[i])
				var rec := _slot(index)
				if rec["id"] != 0 and rec["type"] == t:
					found = index
					break
			_w(dst, found)
		42:  # FindBestCombo
			var depth_value := _m(_u8()) + 1
			var sets := _m(_u8())
			var dst := _u8()
			_find_best_combo(depth_value, sets, dst)
		43:  # EvaluateFusion
			var a := _m(_u8())
			var b := _m(_u8()) + 1
			var c := _m(_u8())
			var k := _u8()
			_evaluate_fusion(a, b, c, k)
		44, 45:  # SkipHand, SkipField
			_u8()
			_u8()
			_u8()
			_u8()
		46:  # PlayFaceUp
			var a := _m(_u8())
			var b := _m(_u8())
			var c := _m(_u8())
			var d := _m(_u8())
			var e := _m(_u8())
			sel[5] = 0
			sel[0] = _byte(a)
			sel[1] = _byte(b)
			sel[2] = _byte(c)
			sel[3] = _byte(d)
			sel[4] = _byte(e)
		47:  # SetPosition
			sel[SEL_POSITION] = _byte(_m(_u8()))
		48:  # FindBestAttack
			var want := _m(_u8())
			var dst := _u8()
			_w(dst, _find_best_attack(want))
		49:  # PushComboCard
			for i in 6:
				sel[i] = 0
			var count := 0
			for i in range(0, fus_best_depth + 1):
				var value: int = combo[i]
				if value >= 11:
					sel[count] = value
					count += 1
		50:  # PushComboEmpty
			var count := 0
			for i in range(0, fus_best_depth + 1):
				var value: int = combo[i]
				if value >= 11:
					sel[count] = value
					count += 1
		51, 52:  # HandNop, FieldNop
			pass
		53:  # AddCard
			var v := _m(_u8())
			for i in CARD_SET_COUNT:
				if card_set[i] == v:
					return CONTINUE
				if card_set[i] == 0:
					card_set[i] = v
					return CONTINUE
		54:  # ClearCards
			card_set.fill(0)
		55:  # AddType
			var t := _m(_u8()) + 1
			for i in TYPE_SET_COUNT:
				if type_set[i] == t:
					break
				if type_set[i] == 0:
					type_set[i] = t
					break
		56:  # ClearTypes
			type_set.fill(0)
		57:  # SetSelectionRandom
			sel[SEL_RANDOM] = 1
		58:  # ClearSelectionRandom
			sel[SEL_RANDOM] = 0
		59:  # the routine at 0x80073464
			field97 = 1
		60:  # the routine at 0x80073474
			field97 = 0
		61:  # MoveCard
			var value := _m(_u8())
			if value >= 0 and value < SNAPSHOT_SLOTS:
				snap[value]["flags"] |= FLAG_USED
		62:  # LoadOpponentData
			var index := _m(_u8())
			var field := _m(_u8())
			var dst := _u8()
			_w(dst, _opponent_data(index, field))
		63:  # Store
			var value := _u16()
			_w(_u8(), value)
		64:  # SetRegister
			var src := _m(_u8())
			_w(_u8(), src)
		65:  # Add
			var l := _m(_u8())
			var r := _m(_u8())
			_w(_u8(), l + r)
		66:  # LoadGuardianStarChoice
			sel[SEL_STAR] = _m(_u8()) & 255
		67:  # Print
			_u8()
		_:
			fault = true
	return CONTINUE


# ---- handlers -----------------------------------------------------------------------------------------------------------

func _opponent_data(index: int, field: int) -> int:
	# the opponent data[index].values: index is a duelist id, field 0 is ATK in hundreds, else values[field + 1]
	var source: Array = []
	if index == duelist:
		source = row
	elif index >= 0 and index < engine.state.data.duelists.size():
		source = engine.state.data.duelists[index].get("ai", [])
	if source.size() < 9:
		return 0
	if field == 0:
		return int(source[1]) * 100
	if field + 1 < source.size():
		return int(source[field + 1])
	return 0


func _calc_card_power(card: int, mode: int) -> int:
	if card < 1:
		return 0
	if _kind(card) < TYPE_MAGIC:
		match mode:
			0:
				return _base_stat(card, 0)
			1:
				return _base_stat(card, 1)
			2:
				return maxi(_base_stat(card, 0), _base_stat(card, 1))
		return 0
	if mode == 0 and DIRECT_DAMAGE.has(card):
		return DIRECT_DAMAGE[card]
	return 0


func _find_strongest(mode: int, kind: int, hide: int, sets: int) -> int:
	var best_slot := 0
	var best := -1
	var win := _win_range(kind)
	for i in range(win.x, win.y + 1):
		var rec := _slot(i)
		if rec["id"] == 0:
			continue
		var f: int = rec["flags"]
		if (kind == 1 or kind == 4 or kind == 5) and (f & FLAG_USED) != 0:
			continue
		if kind == 4 and (f & FLAG_DEFENSE) != 0:
			continue
		if kind == 5 and (f & FLAG_DEFENSE) == 0:
			continue
		if kind >= 3 and kind <= 5 and (f & FLAG_FACE_DOWN) != 0 and hide == 1:
			continue
		if _in_sets(sets, i):
			continue
		if mode != 1:
			var v: int = rec["atk"]
			if best < v:
				best = v
				best_slot = i
		if mode == 0:
			continue
		var d: int = rec["def"]
		if best < d:
			best = d
			best_slot = i
	return best_slot


func _find_weakest(mode: int, kind: int, hide: int, sets: int) -> int:
	var best_slot := 0
	var best := STAT_MAX
	var win := _win_range(kind)
	for i in range(win.x, win.y + 1):
		var rec := _slot(i)
		if rec["id"] == 0:
			continue
		var f: int = rec["flags"]
		if (kind == 1 or kind == 4 or kind == 5) and (f & FLAG_USED) != 0:
			continue
		if kind == 4 and (f & FLAG_DEFENSE) != 0:
			continue
		if kind == 5 and (f & FLAG_DEFENSE) == 0:
			continue
		if kind >= 3 and kind <= 5 and (f & FLAG_FACE_DOWN) != 0 and hide == 1:
			continue
		if _in_sets(sets, i):
			continue
		if mode == 0:
			if rec["atk"] < best:
				best = rec["atk"]
				best_slot = i
		elif mode == 1:
			if rec["def"] < best:
				best = rec["def"]
				best_slot = i
		else:
			var a: int = rec["atk"]
			var d: int = rec["def"]
			if d < a:
				if a < best:
					best = a
					best_slot = i
			elif d < best:
				best = d
				best_slot = i
	return best_slot


func _find_killer(a: int, m: int) -> int:
	var best := STAT_MAX
	var k := 0
	var ref := _slot(a)
	for i in range(1, 6):
		var c := _slot(i)
		if c["id"] == 0 or (c["flags"] & FLAG_USED) != 0:
			continue
		var d: int
		if m == 0:
			d = int(c["atk"]) - int(ref["atk"])
		else:
			d = int(c["atk"]) - int(ref["def"])
		d += engine.star_bonus(int(c["star"]), int(ref["star"]))
		if d > 0:
			var t: int = c["atk"]
			if t < best:
				best = t
				k = i
	return k


func _find_defense_stopper(hide: int) -> int:
	var taken_own := [false, false, false, false, false]
	var taken_foe := [false, false, false, false, false]
	var answer := 1
	var i := 0
	while i < 5:
		var best := 0
		for j in 5:
			if not taken_own[j] and _slot(j + 1)["atk"] > _slot(best)["atk"]:
				best = j + 1
		if best != 0:
			taken_own[best - 1] = true
		var other := 0
		for j in 5:
			var rec := _slot(j + 56)
			if taken_foe[j]:
				continue
			if hide == 0 or (rec["flags"] & FLAG_FACE_DOWN) == 0:
				if rec["atk"] > _slot(other)["atk"]:
					other = j + 56
		if other == 0:
			break
		taken_foe[other - 56] = true
		if _slot(best)["atk"] <= _slot(other)["atk"]:
			answer = 0
			break
		i += 1
	if i == 0:
		answer = 0
	return answer


func _count_cards(kind: int) -> int:
	var count := 0
	var r := _range(kind)
	for i in range(r.x, r.y + 1):
		var rec := _slot(i)
		if rec["id"] != 0:
			if kind == 1 or kind == 3 or kind == 6 or kind == 8:
				if (rec["flags"] & FLAG_USED) == 0:
					count += 1
			else:
				count += 1
	return count


func _find_first_card(wanted: int, kind: int) -> int:
	var r := _range(kind)
	var i := r.x
	while i <= r.y:
		var rec := _slot(i)
		var skip: bool = (kind == 1 or kind == 3 or kind == 6 or kind == 8) and (int(rec["flags"]) & FLAG_USED) != 0
		if not skip:
			if rec["id"] != 0:
				if (rec["flags"] & FLAG_FACE_DOWN) != 0:
					if wanted == 2:
						break
				elif wanted == 1:
					break
			elif wanted == 0:
				break
		i += 1
	return 0 if r.y < i else i


func _find_card(wanted: int, kind: int, visible: int) -> int:
	var r := _range(kind)
	var i := r.x
	while i <= r.y:
		var rec := _slot(i)
		if rec["id"] != wanted:
			i += 1
			continue
		if (kind == 1 or kind == 3 or kind == 6 or kind == 8) and (rec["flags"] & FLAG_USED) != 0:
			i += 1
			continue
		if visible != 1:
			break
		if kind < 5:
			break
		if (rec["flags"] & FLAG_FACE_DOWN) == 0:
			break
		i += 1
	return 0 if r.y < i else i


func _match_type(t: int, kind: int, set: int, sets: int) -> int:
	var r := _range(kind)
	if r.y < r.x:
		return 0
	var i := r.x
	while true:
		var rec := _slot(i)
		var hit := false
		if rec["id"] != 0 and rec["type"] == t:
			var skip: bool = (kind == 1 or kind == 3 or kind == 6 or kind == 8) and (int(rec["flags"]) & FLAG_USED) != 0
			if set == 1 and kind >= 5 and (rec["flags"] & FLAG_FACE_DOWN) != 0:
				skip = true
			if not skip and not _in_sets(sets, i):
				hit = true
		if hit:
			break
		i += 1
		if r.y < i:
			break
	return 0 if r.y < i else i


func _find_equip_target(owner: int, mode: int, kind: int) -> int:
	for i in range(1, 6):
		var rec := _slot(i)
		if rec["id"] == 0:
			continue
		if mode == 1 and (rec["flags"] & FLAG_USED) != 0:
			continue
		if _in_sets(kind, i):
			continue
		if engine.state.data.can_equip(owner, rec["id"]):
			return i
	return 0


func _check_ritual(card: int) -> bool:
	return not Effects.ritual_match(engine.state, side, card).is_empty()


func _find_best_attack(want: int) -> int:
	# Unreached by both retail programs (the analysis found it absent). The game's outer loop does not advance on an empty
	# slot; the port advances it, and it never runs in a retail script.
	attack_best_stat = 0
	var mine := 1
	while mine <= 5:
		var r := _slot(mine)
		if r["id"] != 0 and (r["flags"] & FLAG_USED) == 0:
			for j in range(56, 61):
				var e := _slot(j)
				var f: int = e["flags"]
				if e["id"] == 0 or (f & FLAG_USED) != 0 or (f & FLAG_DEFENSE) != 0:
					continue
				if want != 0 and (f & FLAG_FACE_DOWN) != 0:
					continue
				var v: int = int(r["atk"]) - int(e["atk"]) + engine.star_bonus(int(r["star"]), int(e["star"]))
				if attack_best_stat < v:
					attack_best_stat = v
					attack_best_slot = mine
					attack_best_target = j
		mine += 1
	return 0 if best_difference != 0 else 1


# ---- fusion search-----------------------------------------------------------------------------------------

func _find_best_combo(depth_value: int, sets: int, dst: int) -> void:
	fus_count = int(row[0]) if row.size() > 0 else 0
	fus_best = 0
	fus_depth = 0
	fus_limit = depth_value
	fus_set = sets
	for i in fus_count:
		fus_used[i] = 0
	for i in 5:
		var card: int = _slot(i + 1)["id"]
		var slot := i + 1
		if card == 0:
			continue
		if _in_sets(sets, slot):
			continue
		fus_path[fus_depth] = slot
		var rec := _slot(i + 1)
		if rec["atk"] > fus_best:
			fus_best = rec["atk"]
			combo[0] = slot
			combo[1] = 0
			fus_best_depth = fus_depth
		if rec["def"] > fus_best:
			fus_best = rec["def"]
			combo[0] = slot
			combo[1] = 0
			fus_best_depth = fus_depth
		if fus_limit >= 2:
			fus_used[i] = 1
			fus_depth += 1
			_complete_fusion(card)
			fus_used[i] = 0
			fus_depth -= 1
	for i in fus_count:
		var card: int = _slot(i + 11)["id"]
		var slot := i + 11
		if card == 0:
			continue
		if _in_sets(sets, slot):
			continue
		fus_path[fus_depth] = slot
		var rec := _slot(i + 11)
		if rec["atk"] > fus_best:
			fus_best = rec["atk"]
			combo[0] = slot
			combo[1] = 0
			fus_best_depth = fus_depth
		if rec["def"] > fus_best:
			fus_best = rec["def"]
			combo[0] = slot
			combo[1] = 0
			fus_best_depth = fus_depth
		if fus_limit >= 3:
			fus_used[i] = 1
			fus_depth += 1
			_complete_fusion(card)
			fus_used[i] = 0
			fus_depth -= 1
	var answer := 3
	if combo[0] != 0:
		if combo[0] >= 6:
			answer = 0
		elif combo[1] != 0:
			answer = 1
		else:
			answer = 2
	_w(dst, answer)


func _evaluate_fusion(a: int, b: int, c: int, k: int) -> void:
	fus_count = int(row[0]) if row.size() > 0 else 0
	fus_limit = b
	fus_best = 0
	fus_depth = 0
	fus_best_depth = 0
	fus_set = c
	for i in fus_count:
		fus_used[i] = 0
	var x := _base_stat(a, 0)
	var y := _base_stat(a, 1)
	fus_best = _base_stat(a, 0) if y < x else _base_stat(a, 1)
	_complete_fusion(a)
	_w(k, 0 if fus_best_depth != 0 else 1)


func _complete_fusion(seed: int) -> void:
	if fus_count == 0:
		return
	var data = engine.state.data
	for i in fus_count:
		if fus_used[i] != 0:
			continue
		var card_id: int = _slot(i + 11)["id"]
		var index := i + 11
		if card_id == 0:
			continue
		if _in_sets(fus_set, index):
			continue
		var result: int = data.fuse(seed, card_id)
		if result == 0 and data.can_equip(seed, card_id):
			result = card_id
		if result == 0:
			continue
		fus_path[fus_depth] = index
		for which in 2:
			var stat := _base_stat(result, which)
			if stat > fus_best or (stat == fus_best and fus_depth < fus_best_depth):
				fus_best = stat
				fus_best_depth = fus_depth
				for j in range(0, fus_best_depth + 1):
					combo[j] = fus_path[j]
				combo[fus_best_depth + 1] = 0
		if fus_depth < fus_limit - 1:
			fus_used[i] = 1
			fus_depth += 1
			_complete_fusion(result)
			fus_used[i] = 0
			fus_depth -= 1
