extends RefCounted
## The rules-level state of a duel: two sides, each with life points, a hand, a deck, five monster zones and five magic/trap
## zones, plus the field terrain. A zone holds null or {id, base_atk, base_def, mod, face_down, defense, used}.

const STARTING_LIFE_POINTS := 8000
const STAT_MAX := 9999
const ZONES := 5
const HAND := 5

var data
var sides: Array = []
var terrain := 0            # 0 none, 1 Forest, 2 Wasteland, 3 Mountain, 4 Meadow, 5 Sea, 6 Dark (card id - 329 for 330..335)
var turn_side := 0


class Side:
	var lp := STARTING_LIFE_POINTS
	var max_lp := STARTING_LIFE_POINTS
	var hand: Array = []
	var deck: Array = []
	# the deck slot (1 to 40) of each card instance, parallel to deck and hand: the reference's table index plus 1, the number a card shows
	var deck_slots: Array = []
	var hand_slots: Array = []
	var monsters: Array = [null, null, null, null, null]
	var traps: Array = [null, null, null, null, null]
	var swords_turns := 0      # Swords of Revealing Light: counts down at the start of this side's turns
	# the rank statistics of the duel result (the rank score sum's counters); result_adjustment is the way the duel ended, set on the winner
	var rank := {"turns_taken": 0, "effective_attacks": 0, "defensive_wins": 0, "face_down_plays": 0, "pure_magic_used": 0,
			"traps_triggered": 0, "fusions_initiated": 0, "equips_used": 0, "change_field": 0, "result_adjustment": 0,
			"avg_atk_factor": 0, "avg_dfd_factor": 0, "card_destruction": 0, "defensive_losses": 0, "combo_plays": 0}


func _init(duel_data) -> void:
	data = duel_data
	sides = [Side.new(), Side.new()]


## A freshly summoned monster record for card `id`.
func make_zone(id: int, face_down := false, defense := false) -> Dictionary:
	var card: Dictionary = data.card(id)
	return {"id": id, "base_atk": int(card.get("attack", 0)), "base_def": int(card.get("defense", 0)), "mod": 0,
			"face_down": face_down, "defense": defense, "used": false}


func card_type(id: int) -> String:
	return str(data.card(id).get("type", ""))


func is_monster(id: int) -> bool:
	return id >= 1 and card_type(id) != "" and not card_type(id) in ["Magic", "Trap", "Ritual", "Equip"]


## the terrain boost: +-500 for a monster type on the current terrain, 0 for none and for non-monster cards.
func terrain_boost(id: int) -> int:
	if terrain == 0 or not is_monster(id):
		return 0
	var names: Array = data.terrain.get("terrains", [])
	var table: Dictionary = data.terrain.get("bonus", {})
	var row: Dictionary = table.get(card_type(id), {})
	return int(row.get(names[terrain - 1], 0))


## the card stats calculation: base plus the equip/penalty modifier plus the terrain bonus, kept within 0..9999.
func atk(zone: Dictionary) -> int:
	return clampi(int(zone["base_atk"]) + int(zone["mod"]) + terrain_boost(int(zone["id"])), 0, STAT_MAX)


func def(zone: Dictionary) -> int:
	return clampi(int(zone["base_def"]) + int(zone["mod"]) + terrain_boost(int(zone["id"])), 0, STAT_MAX)
