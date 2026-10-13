extends RefCounted
## The computer opponent's turn, one action at a time (begin_turn, next_action -> {kind: play | attack | defense | end | noop},
## perform). When the duelist's bytecode is extracted (assets/data/ai_scripts/hand.bin and field.bin) the turn is the game's
## own: the hand program plans the play, then the field program plans each attack, defense or the end (ai_vm.gd). Without the
## scripts the stand-in policy below plays the same rules.

const AiVm := preload("res://scripts/duel/ai_vm.gd")
const HAND_PATH := "res://assets/data/ai_scripts/hand.bin"
const FIELD_PATH := "res://assets/data/ai_scripts/field.bin"

var engine
var duelist := -1
var vm = null
var played := false
var attacked: Array = []


func _init(duel_engine, duelist_id := -1) -> void:
	engine = duel_engine
	duelist = duelist_id
	if FileAccess.file_exists(HAND_PATH) and FileAccess.file_exists(FIELD_PATH):
		vm = AiVm.new(engine, duelist, FileAccess.get_file_as_bytes(HAND_PATH), FileAccess.get_file_as_bytes(FIELD_PATH))


## Whether this opponent plays the game's bytecode (false: the stand-in policy).
func uses_script() -> bool:
	return vm != null


func begin_turn(_p: int) -> void:
	played = false
	attacked.clear()
	if vm != null:
		vm.noops = 0


func next_action(p: int) -> Dictionary:
	if vm != null:
		return _script_action(p)
	return _stand_in_action(p)


func _script_action(p: int) -> Dictionary:
	if not played:
		played = true
		var plan: Dictionary = vm.hand_plan(p)
		if not plan.is_empty():
			var picks: Array = plan["picks"]
			if picks.size() == 1 and engine.state.card_type(int(engine.state.sides[p].hand[picks[0]])) == "Equip":
				return {"kind": "set_back", "hand": picks[0]}
			return {"kind": "play", "picks": picks, "dest": plan["dest"], "face_down": plan["face_down"], "star2": plan["star2"]}
	var act: Dictionary = vm.field_action(p)
	var zone = null
	if act.has("zone") and act["kind"] != "spent":
		zone = engine.state.sides[p].monsters[int(act["zone"])]
	match act["kind"]:
		"attack":
			# a defense-position monster turns to attack first (the position bit toggles, the attack is not spent); a monster that
			# cannot attack this turn ends the field phase, since the same program would repeat the decision
			if zone != null and not zone["used"] and not engine.attack_locked and engine.state.sides[p].swords_turns == 0:
				return act
			return {"kind": "end"}
		"equip":
			var equip_card = engine.state.sides[p].traps[int(act["trap"])]
			if equip_card != null and zone != null and engine.state.data.can_equip(int(equip_card["id"]), int(zone["id"])):
				return act
			return {"kind": "spent", "row": "traps", "zone": int(act["trap"])}
		"defense", "spent":
			if zone == null and act["kind"] == "defense":
				return {"kind": "noop"}
			return act
	return act


func perform(p: int, action: Dictionary) -> Array:
	match action["kind"]:
		"set_back":
			return engine.set_back_row(p, int(action["hand"]))
		"equip":
			return engine.equip_from_back_row(p, int(action["trap"]), int(action["zone"]))
		"play":
			var dest := int(action.get("dest", -1))
			return engine.play(p, action["picks"], _on_top(p, action["picks"], dest), dest, bool(action.get("face_down", false)),
					bool(action.get("face_down", false)), bool(action.get("star2", false)))
		"attack":
			var zone = engine.state.sides[p].monsters[int(action["zone"])]
			if zone != null and zone["defense"]:
				zone["defense"] = false
			return engine.attack(p, int(action["zone"]), int(action["target"]))
		"defense":
			var zone = engine.state.sides[p].monsters[int(action["zone"])]
			if zone != null:
				if not zone["defense"]:
					engine.change_position(p, int(action["zone"]))
				zone["used"] = true
			return []
		"spent":
			var row: Array = engine.state.sides[p].monsters if action["row"] == "monsters" else engine.state.sides[p].traps
			if row[int(action["zone"])] != null:
				row[int(action["zone"])]["used"] = true
			return []
	return []


# ---- the stand-in policy (used only when the duelist's bytecode is not extracted) ---------------------------------------

func _stand_in_action(p: int) -> Dictionary:
	var s = engine.state
	var side = s.sides[p]
	if not played:
		played = true
		var plan := _best_play(p)
		if not plan.is_empty():
			return plan
	for i in 5:
		if attacked.has(i) or not engine.can_attack(p, i):
			continue
		attacked.append(i)
		var mine = side.monsters[i]
		var power: int = s.atk(mine)
		var foe = s.sides[p ^ 1]
		var best := -1
		var best_gain := -1
		var any := false
		for t in 5:
			var zone = foe.monsters[t]
			if zone == null:
				continue
			any = true
			var wanted: int = s.def(zone) if zone["defense"] else s.atk(zone)
			if power > wanted and wanted > best_gain:
				best = t
				best_gain = wanted
		if not any:
			return {"kind": "attack", "zone": i, "target": -1}
		if best >= 0:
			return {"kind": "attack", "zone": i, "target": best}
	return {"kind": "end"}


func _best_play(p: int) -> Dictionary:
	var s = engine.state
	var side = s.sides[p]
	var hand: Array = side.hand
	if _free(side.monsters) < 0:
		return {}
	var best := {}
	var best_value := -1
	for i in hand.size():
		var id: int = hand[i]
		if s.is_monster(id):
			var value: int = int(s.data.card(id)["attack"])
			if value > best_value:
				best_value = value
				best = {"kind": "play", "picks": [i]}
		for j in range(i + 1, hand.size()):
			var fused: int = s.data.fuse(id, hand[j])
			if fused != 0:
				var value2: int = int(s.data.card(fused)["attack"])
				if value2 > best_value:
					best_value = value2
					best = {"kind": "play", "picks": [i, j]}
	return best


## The own monster zone a played chain lands on, or -1 (an empty zone, or no monster base). A monster played into an occupied zone
## lands on the card there (the chain's base: fused, equipped or replaced, duel_engine.gd play). With no empty zone a monster
## overwrites the weakest own monster (the placement rule of the computer's hand program).
func _on_top(p: int, picks: Array, dest: int) -> int:
	if picks.is_empty() or vm == null:
		return -1
	var s = engine.state
	if not s.is_monster(int(s.sides[p].hand[int(picks[0])])):
		return -1
	var row: Array = s.sides[p].monsters
	if dest >= 0 and dest < row.size():
		return dest if row[dest] != null else -1
	if _free(row) >= 0:
		return -1
	var slot: int = vm._find_weakest(0, 0, 0, 0)     # the script's own weakest search over the own monsters (slots 1..5)
	return slot - 1 if slot >= 1 and slot <= 5 else -1


func _free(row: Array) -> int:
	for i in row.size():
		if row[i] == null:
			return i
	return -1
