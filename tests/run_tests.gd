extends SceneTree
## Headless regression suite for the duel rules: the tables (duel_data.gd), the state (duel_state.gd), the rules (duel_engine.gd)
## and the magic/trap effects (duel_effects.gd). Every assertion is deterministic: the random draws use fixed seeds, and the
## battles build their own cards with known stats. Nothing here reads or writes the player's save (user://).
##
## Run from the project folder (headless, silent):
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --headless --path G:\Development\Godot\Projects\ForbiddenMemories --script res://tests/run_tests.gd
## Prints PASS or FAIL for every assertion, then a summary. Exits with code 0 when every assertion passes, 1 otherwise.

const DuelData = preload("res://scripts/duel/duel_data.gd")
const DuelEngine = preload("res://scripts/duel/duel_engine.gd")
const Effects = preload("res://scripts/duel/duel_effects.gd")
const DuelResult = preload("res://scripts/duel/duel_result.gd")
const DuelHand = preload("res://scripts/duel/duel_hand.gd")
const OpeningMovie = preload("res://scripts/boot/opening_movie.gd")
const ScreenFit = preload("res://scripts/system/screen_fit.gd")
const ModArt = preload("res://scripts/system/mod_art.gd")
const DuelCardFace = preload("res://scripts/duel/duel_card_face.gd")
const CardView = preload("res://scripts/ui/card_view.gd")

## a folder that does not exist: the suite runs on the disc's tables alone, with no mod applied
const NO_MODS := "res://tests/no_mods_folder"

var data
var by_name := {}
var passed := 0
var failed := 0
var group := ""


func check(label: String, ok: bool) -> void:
	var full := label if group == "" else "%s: %s" % [group, label]
	if ok:
		passed += 1
		print("PASS  ", full)
	else:
		failed += 1
		print("FAIL  ", full)


func _init() -> void:
	data = DuelData.new()
	data.mods_dir = NO_MODS
	if not data.load_all():
		print("FAIL  the duel tables could not be loaded from res://assets/data")
		quit(1)
		return
	for card in data.cards:
		by_name[str(card["name"])] = int(card["id"])
	_test_tables()
	_test_star_matchup()
	_test_terrain()
	_test_deck_building()
	_test_draw_phase()
	_test_chain()
	_test_hand_plays()
	_test_field_phase()
	_test_battle()
	_test_traps()
	_test_magic()
	_test_back_row()
	_test_rituals()
	_test_win_conditions()
	_test_statistics()
	_test_result_outro()
	_test_opening_movie()
	_test_glyph_exit()
	_test_second_card()
	_test_star_icons()
	_test_display()
	_test_card_faces()
	_test_card_viewer()
	print("")
	print("%d passed, %d failed, %d assertions" % [passed, failed, passed + failed])
	quit(0 if failed == 0 else 1)


# ---- helpers -------------------------------------------------------------------------------------------------------------

func engine(seed_value := 7) -> Object:
	return DuelEngine.new(data, seed_value)


## A monster record for card `id`, with its printed ATK and DEF overridden when given (-1 keeps the card's own).
func zone(eng, id: int, atk := -1, def := -1, defense := false, face_down := false) -> Dictionary:
	var z: Dictionary = eng.state.make_zone(id, face_down, defense)
	if atk >= 0:
		z["base_atk"] = atk
	if def >= 0:
		z["base_def"] = def
	return z


func card_of_type(kind: String, skip := 0) -> int:
	for card in data.cards:
		if str(card.get("type", "")) == kind:
			if skip == 0:
				return int(card["id"])
			skip -= 1
	return 0


func ritual_recipe(id: int) -> Dictionary:
	for recipe in data.rituals:
		if int(recipe["id"]) == id:
			return recipe
	return {}


func rng_of(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


# ---- the disc's tables ---------------------------------------------------------------------------------------------------

func _test_tables() -> void:
	group = "tables"
	check("fusion table holds the disc's 25131 recipes", data.fusion_table.size() == 25131)
	check("equip table holds 34 equip cards", data.equip_table.size() == 34)
	check("the disc has 24 ritual recipes", data.rituals.size() == 24)
	# recipes checked against the disc's fusion table (both orders)
	var recipes := [[2, 8, 638], [8, 357, 571], [8, 359, 99], [8, 362, 511], [8, 363, 638], [352, 403, 627], [352, 405, 413],
			[2, 9, 470], [2, 10, 551], [2, 12, 551]]
	for r in recipes:
		check("fuse %d + %d makes %d" % [r[0], r[1], r[2]], data.fuse(r[0], r[1]) == r[2])
		check("fuse %d + %d makes %d (order reversed)" % [r[1], r[0], r[2]], data.fuse(r[1], r[0]) == r[2])
	# pairs that make nothing
	for pair in [[1, 1], [1, 2], [1, 3], [1, 337], [2, 337]]:
		check("fuse %d + %d makes nothing" % [pair[0], pair[1]], data.fuse(pair[0], pair[1]) == 0)
	check("Legendary Sword equips Swamp Battleguard", data.can_equip(301, 12))
	check("Legendary Sword does not equip Blue-Eyes White Dragon", not data.can_equip(301, 1))
	check("Legendary Sword bonus is +500", data.equip_bonus(301) == 500)
	check("Megamorph bonus is +1000", data.equip_bonus(657) == 1000)
	check("Megamorph equips Blue-Eyes White Dragon", data.can_equip(657, 1))
	var dark_magic: Dictionary = ritual_recipe(721)
	check("Dark Magic Ritual (721) makes Magician of Black Chaos (722)", int(dark_magic.get("result_id", 0)) == 722)
	check("Dark Magic Ritual takes Winged Dragon #1, Dark Magician and Blast Juggler",
			_ints(dark_magic.get("tribute_ids", [])) == [7, 35, 417])
	var ultimate: Dictionary = ritual_recipe(675)
	check("Ultimate Dragon ritual takes three Blue-Eyes White Dragon", _ints(ultimate.get("tribute_ids", [])) == [1, 1, 1])
	check("Ultimate Dragon ritual makes Blue-eyes Ultimate Dragon (380)", int(ultimate.get("result_id", 0)) == 380)
	check("starter build has seven pools", data.starter_pools.size() == 7)
	var starter_total := 0
	var starter_weights_ok := true
	for pool in data.starter_pools:
		starter_total += int(pool["count"])
		var weight_sum := 0
		for key in pool["weights"]:
			weight_sum += int(pool["weights"][key])
		starter_weights_ok = starter_weights_ok and weight_sum == 2048
	check("starter pools draw 40 cards in all", starter_total == 40)
	check("every starter pool's weights sum to 2048", starter_weights_ok)
	for i in data.duelists.size():
		var duelist: Dictionary = data.duelists[i]
		if bool(duelist.get("unused", false)):
			continue
		var deck_sum := 0
		for key in duelist.get("deck", {}):
			deck_sum += int(duelist["deck"][key])
		check("duelist %d deck weights sum to 2048" % i, deck_sum == 2048)
		var drops_ok := true
		for pool in ["pow", "bcd", "tec"]:
			var sum := 0
			for key in duelist.get("drops", {}).get(pool, {}):
				sum += int(duelist["drops"][pool][key])
			drops_ok = drops_ok and sum == 2048
		check("duelist %d drop pools sum to 2048" % i, drops_ok)
	# the starter deck build: forty cards, three copies at most
	var rng := rng_of(41)
	var starter: Array = data.deal_starter_deck(rng)
	check("starter deck has 40 cards", starter.size() == 40)
	var starter_copies_ok := true
	for id in starter:
		starter_copies_ok = starter_copies_ok and starter.count(id) <= 3
	check("starter deck has at most three copies of a card", starter_copies_ok)


# ---- guardian stars: the disc's matchup, every pair (row = attacker's star, column = defender's; 0 = no star) -----------

func _test_star_matchup() -> void:
	group = "star matchup"
	var eng = engine()
	var table := [
		[0, 500, 0, 0, 0, -500, 0, 0, 0, 0, 0],
		[0, 0, 500, 0, 0, 0, -500, 0, 0, 0, 0],
		[0, -500, 0, 500, 0, 0, 0, 0, 0, 0, 0],
		[0, 0, -500, 0, 500, 0, 0, 0, 0, 0, 0],
		[0, 0, 0, -500, 0, 500, 0, 0, 0, 0, 0],
		[0, 0, 0, 0, -500, 0, 500, 0, 0, 0, 0],
		[0, 500, 0, 0, 0, -500, 0, 0, 0, 0, 0],
		[0, 0, 0, 0, 0, 0, 0, 0, 500, 0, -500],
		[0, 0, 0, 0, 0, 0, 0, -500, 0, 500, 0],
		[0, 0, 0, 0, 0, 0, 0, 0, -500, 0, 500],
		[0, 0, 0, 0, 0, 0, 0, 500, 0, -500, 0],
	]
	for a in 11:
		for b in 11:
			check("attacker star %d against defender star %d" % [a, b], DuelEngine.star_bonus(a, b) == table[a][b])
	check("star names map to the disc's ids (Mars 1 .. Venus 10)",
			eng.STARS["Mars"] == 1 and eng.STARS["Neptune"] == 6 and eng.STARS["Mercury"] == 7 and eng.STARS["Venus"] == 10)


# ---- terrain boosts and the ATK / DEF clamps -----------------------------------------------------------------------------

func _test_terrain() -> void:
	group = "terrain"
	var eng = engine()
	var st = eng.state
	var insect := card_of_type("Insect")
	var dragon := card_of_type("Dragon")
	var fairy := card_of_type("Fairy")
	var machine := card_of_type("Machine")
	var warrior := card_of_type("Warrior")
	var fiend := card_of_type("Fiend")
	check("no terrain gives no boost", st.terrain_boost(insect) == 0)
	st.terrain = 1   # Forest
	check("Forest boosts Insects by +500", st.terrain_boost(insect) == 500)
	check("Forest does not boost Dragons", st.terrain_boost(dragon) == 0)
	st.terrain = 3   # Mountain
	check("Mountain boosts Dragons by +500", st.terrain_boost(dragon) == 500)
	st.terrain = 6   # Dark
	check("Dark boosts Fiends by +500", st.terrain_boost(fiend) == 500)
	check("Dark lowers Fairies by -500", st.terrain_boost(fairy) == -500)
	st.terrain = 5   # Sea
	check("Sea lowers Machines by -500", st.terrain_boost(machine) == -500)
	st.terrain = 4   # Meadow
	check("Meadow boosts Warriors by +500", st.terrain_boost(warrior) == 500)
	check("a magic card gets no terrain boost", st.terrain_boost(330) == 0)
	st.terrain = 2
	check("Wasteland leaves Warriors alone", st.terrain_boost(warrior) == 0)
	st.terrain = 3
	var high := zone(eng, dragon, 9900, 100)
	high["mod"] = 500
	check("ATK clamps at 9999", st.atk(high) == 9999)
	var low := zone(eng, dragon, 0, 0)
	low["mod"] = -500
	check("ATK clamps at zero", st.atk(low) == 0)
	check("DEF clamps at zero", st.def(low) == 0)
	var boosted := zone(eng, dragon, 1000, 1000)
	check("terrain adds to ATK and DEF alike", st.atk(boosted) == 1500 and st.def(boosted) == 1500)


# ---- deck building and the shuffle -------------------------------------------------------------------------------------

func _test_deck_building() -> void:
	group = "deck building"
	var names_pool := {}
	for i in 14:
		names_pool[str(data.cards[i]["name"])] = 146 + (1 if i < 4 else 0)   # fourteen cards, 2048 weight in all
	var first = engine(99).build_pool_deck(names_pool)
	var second = engine(99).build_pool_deck(names_pool)
	check("a CPU deck has 40 cards", first.size() == 40)
	check("a CPU deck is the same for the same seed", first == second)
	var copies_ok := true
	var ids_ok := true
	for id in first:
		copies_ok = copies_ok and first.count(id) <= 3
		ids_ok = ids_ok and int(id) >= 1 and int(id) <= 14
	check("a CPU deck holds at most three copies of a card", copies_ok)
	check("a CPU deck draws only from its pool", ids_ok)
	# the weights are walked in card order, so a pool written in another order gives the same deck for the same seed
	var reversed_pool := {}
	var keys: Array = names_pool.keys()
	keys.reverse()
	for key in keys:
		reversed_pool[key] = names_pool[key]
	check("a CPU deck does not depend on the order the pool is written in",
			engine(99).build_pool_deck(reversed_pool) == first)
	var eng = engine(5)
	var deck0: Array = []
	var deck1: Array = []
	for i in 40:
		deck0.append(1 + i % 20)
		deck1.append(21 + i % 20)
	eng.start(deck0, deck1)
	var st = eng.state
	check("start: each side has 40 cards in its deck", st.sides[0].deck.size() == 40 and st.sides[1].deck.size() == 40)
	check("start: both sides have 8000 life points", st.sides[0].lp == 8000 and st.sides[1].lp == 8000)
	check("start: side 0 moves first, attacks locked", st.turn_side == 0 and eng.attack_locked and eng.first_turn)
	var sorted_before := deck0.duplicate()
	sorted_before.sort()
	var sorted_after: Array = st.sides[0].deck.duplicate()
	sorted_after.sort()
	check("the shuffle keeps every card (160 swaps)", sorted_before == sorted_after)
	check("the shuffle changes the order", st.sides[0].deck != deck0)
	var same_cards: Array = []
	for i in 40:
		same_cards.append(1)
	var eng2 = engine(6)
	eng2.start(same_cards.duplicate(), same_cards.duplicate())
	check("average ATK factor of a deck of Blue-Eyes (3000) is 3000", eng2.state.sides[0].rank["avg_atk_factor"] == 3000)
	check("average DEF factor of a deck of Blue-Eyes (2500) is 2500", eng2.state.sides[0].rank["avg_dfd_factor"] == 2500)
	var starter_deck: Array = data.deal_starter_deck(rng_of(12))
	check("starter build: 40 cards", starter_deck.size() == 40)


# ---- the draw phase ----------------------------------------------------------------------------------------------------

func _test_draw_phase() -> void:
	group = "draw phase"
	var deck: Array = []
	for i in 40:
		deck.append(1 + i)
	var eng = engine(3)
	eng.start(deck.duplicate(), deck.duplicate())
	var st = eng.state
	var ordered: Array = [5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
	for i in 30:
		ordered.append(1)
	st.sides[0].deck = ordered
	st.sides[0].hand = []
	var drawn: Array = eng.draw_phase(0)
	check("draw phase fills the hand to five", st.sides[0].hand.size() == 5)
	check("draw phase takes the deck's top cards in order", st.sides[0].hand == [5, 6, 7, 8, 9] and drawn == [5, 6, 7, 8, 9])
	check("draw phase leaves the rest of the deck in place", st.sides[0].deck.slice(0, 5) == [10, 11, 12, 13, 14] and st.sides[0].deck.size() == 35)
	check("the turn counts for the drawing side", int(st.sides[0].rank["turns_taken"]) == 1)
	var result: Dictionary = eng.result_stats()
	check("cards used counts the cards drawn from the deck", int(result["sides"][0]["cards_used"]) == 5)
	# used flags clear at the start of a side's turn
	eng = engine(4)
	eng.start(deck.duplicate(), deck.duplicate())
	var used_zone := zone(eng, 1)
	used_zone["used"] = true
	eng.state.sides[0].monsters[0] = used_zone
	eng.draw_phase(0)
	check("the used flag clears when the turn starts", eng.state.sides[0].monsters[0]["used"] == false)
	# deck-out: the drawing side has no cards left, so its opponent wins
	eng = engine(4)
	eng.start(deck.duplicate(), deck.duplicate())
	eng.state.sides[0].deck = []
	eng.state.sides[0].hand = []
	eng.draw_phase(0)
	check("deck-out: the opponent wins", eng.winner == 1 and eng.check_winner() == 1)
	check("deck-out: the winner's record takes -40", int(eng.state.sides[1].rank["result_adjustment"]) == -40)
	# Exodia: the fifth piece completes the hand
	eng = engine(4)
	eng.start(deck.duplicate(), deck.duplicate())
	eng.state.sides[0].hand = [17, 18, 19, 20]
	var top: Array = [21]
	for i in 39:
		top.append(1)
	eng.state.sides[0].deck = top
	eng.draw_phase(0)
	check("Exodia in hand wins for the drawing side", eng.winner == 0)
	check("Exodia records +40 for the winner", int(eng.state.sides[0].rank["result_adjustment"]) == 40)
	check("Exodia leaves the opponent at zero life points", eng.state.sides[1].lp == 0)
	# Swords of Revealing Light: the opponent's counter ticks down on each of its turns
	eng = engine(9)
	eng.start(deck.duplicate(), deck.duplicate())
	eng.state.sides[1].swords_turns = 4
	eng.end_turn(0)
	eng.draw_phase(1)
	check("swords counter ticks down at the affected side's draw", eng.state.sides[1].swords_turns == 3)
	eng.end_turn(1)
	eng.draw_phase(0)
	check("swords counter does not tick on the other side's draw", eng.state.sides[1].swords_turns == 3)
	eng.end_turn(0)
	eng.draw_phase(1)
	eng.end_turn(1)
	eng.draw_phase(1)
	check("swords counter holds at 1 on the affected side's last locked turn", eng.state.sides[1].swords_turns == 1)


# ---- chains: fusion, equip, failed pairings (pure, the same resolver the scene previews with) ----------------------------

func _test_chain() -> void:
	group = "chain"
	var eng = engine()
	var fused: Dictionary = eng.resolve_chain(0, [2, 8])
	check("Mystical Elf + Mushroom Man resolve to Queen of Autumn Leaves", int(fused["card"]) == 638)
	check("a fusion reports a fusion event", str(fused["events"][0]["kind"]) == "fusion")
	var equip_on: Dictionary = eng.resolve_chain(0, [12, 301])
	check("an equip picked second lands on its monster", int(equip_on["card"]) == 12 and int(equip_on["mod"]) == 500)
	var equip_first: Dictionary = eng.resolve_chain(0, [301, 12])
	check("an equip picked first lands on the monster picked second", int(equip_first["card"]) == 12 and int(equip_first["mod"]) == 500)
	var mega: Dictionary = eng.resolve_chain(0, [1, 657])
	check("Megamorph adds +1000 to the monster it equips", int(mega["mod"]) == 1000)
	var raigeki_thrown: Dictionary = eng.resolve_chain(0, [1, 337])
	check("a non-monster picked onto a monster is thrown away, the monster stays", int(raigeki_thrown["card"]) == 1 and
			str(raigeki_thrown["events"][0]["kind"]) == "discard" and int(raigeki_thrown["events"][0]["id"]) == 337)
	var raigeki_base: Dictionary = eng.resolve_chain(0, [337, 1])
	check("a non-monster base with a monster picked: the monster becomes the base", int(raigeki_base["card"]) == 1 and
			int(raigeki_base["events"][0]["id"]) == 337)
	var monsters: Dictionary = eng.resolve_chain(0, [1, 2])
	check("two monsters that do not fuse: the base is thrown away, the picked one becomes the base",
			int(monsters["card"]) == 2 and int(monsters["events"][0]["id"]) == 1)
	var carried: Dictionary = eng.resolve_chain(0, [1, 337], 300)
	check("a thrown-away card keeps the base's modifier", int(carried["mod"]) == 300)
	check("an empty chain resolves to nothing", int(eng.resolve_chain(0, [])["card"]) == 0)


# ---- cards played from the hand, through play() ------------------------------------------------------------------------

func _test_hand_plays() -> void:
	group = "play"
	var eng = engine(11)
	var st = eng.state
	st.sides[0].hand = [2, 8]
	eng.play(0, [0, 1])
	check("playing two hand cards that fuse summons the result", st.sides[0].monsters[0] != null and
			int(st.sides[0].monsters[0]["id"]) == 638)
	check("fused cards leave the hand", st.sides[0].hand.is_empty())
	check("a fusion started from the hand counts for the rank", int(st.sides[0].rank["fusions_initiated"]) == 1)
	eng = engine(12)
	st = eng.state
	st.sides[0].monsters[0] = zone(eng, 12)
	st.sides[0].hand = [301]
	st.sides[1].traps[0] = zone(eng, 689, -1, -1, true)
	var events: Array = eng.play(0, [0], 0)
	check("Reverse Trap on the opposing row turns an equip's bonus into -500", int(st.sides[0].monsters[0]["mod"]) == -500)
	check("Reverse Trap is spent on the equip it reverses", st.sides[1].traps[0] == null)
	check("the trap's owner counts the trap as triggered", int(st.sides[1].rank["traps_triggered"]) == 1)
	var sprung := false
	for event in events:
		if str(event["kind"]) == "trap" and int(event["id"]) == 689:
			sprung = true
	check("the play reports the Reverse Trap springing", sprung)
	eng = engine(13)
	st = eng.state
	st.sides[0].monsters[0] = zone(eng, 12)
	st.sides[0].hand = [301]
	eng.play(0, [0], 0)
	check("an equip with no Reverse Trap adds +500", int(st.sides[0].monsters[0]["mod"]) == 500)
	check("an equip from the hand counts for the rank", int(st.sides[0].rank["equips_used"]) == 1)


# ---- the magic and trap row: setting a card on a chosen cell, activating from the row, and the destination rules ------------

func _first_of_type(eng, kind: String) -> int:
	for k in range(1, 723):
		if eng.state.card_type(k) == kind:
			return k
	return 0


func _test_back_row() -> void:
	group = "back row"
	var eng = engine(31)
	var st = eng.state
	var magic := _first_of_type(eng, "Magic")
	var trap := _first_of_type(eng, "Trap")
	var equip := _first_of_type(eng, "Equip")
	st.sides[0].hand = [magic, trap, equip]
	var events: Array = eng.set_back_row(0, 0, 3)
	check("a magic set from hand lands on the chosen cell", st.sides[0].traps[3] != null and int(st.sides[0].traps[3]["id"]) == magic)
	check("a set card is face-down by default", bool(st.sides[0].traps[3]["face_down"]))
	check("the set card leaves the hand", st.sides[0].hand.size() == 2 and int(st.sides[0].hand[0]) == trap)
	check("the set reports its cell", not events.is_empty() and int(events[0]["zone"]) == 3)
	check("a set into a taken cell does nothing", eng.set_back_row(0, 0, 3).is_empty() and st.sides[0].hand.size() == 2)
	check("a set with a missing hand card does nothing", eng.set_back_row(0, 9, 1).is_empty())
	eng.set_back_row(0, 0, 1, false)
	check("a set face-up stays face-up", not bool(st.sides[0].traps[1]["face_down"]))
	eng.set_back_row(0, 0)
	check("without a chosen cell the first empty one takes the card", st.sides[0].traps[0] != null and int(st.sides[0].traps[0]["id"]) == equip)
	check("the hand is empty after the three sets", st.sides[0].hand.is_empty())
	st.sides[0].traps[2] = st.make_zone(trap, true)
	check("a trap in the row is not activated", eng.activate_back_row(0, 2).is_empty() and st.sides[0].traps[2] != null)
	check("an equip in the row is not activated as a magic", eng.activate_back_row(0, 0).is_empty() and st.sides[0].traps[0] != null)
	check("activating an empty cell does nothing", eng.activate_back_row(0, 4).is_empty())
	var used_before := int(st.sides[0].rank["pure_magic_used"])
	eng.activate_back_row(0, 3)
	check("activating a set magic empties its cell", st.sides[0].traps[3] == null)
	check("a magic activated from the row counts for the rank", int(st.sides[0].rank["pure_magic_used"]) == used_before + 1)
	check("a monster goes to the monster row", DuelHand.row_for(true, "", false) == DuelHand.ROW_MONSTERS)
	check("a set trap goes to the magic and trap row", DuelHand.row_for(false, "Trap", true) == DuelHand.ROW_SPELLS)
	check("an equip goes to the magic and trap row, never the monster row", DuelHand.row_for(false, "Equip", false) == DuelHand.ROW_SPELLS)
	check("a set magic goes to the magic and trap row", DuelHand.row_for(false, "Magic", true) == DuelHand.ROW_SPELLS)
	check("a set ritual goes to the magic and trap row", DuelHand.row_for(false, "Ritual", true) == DuelHand.ROW_SPELLS)
	check("a face-up magic is not placed (it resolves)", DuelHand.row_for(false, "Magic", false) == DuelHand.ROW_MONSTERS)
	check("the cursor on the monster row cannot take an equip", not DuelHand.accepts(false, "Equip", false, DuelHand.ROW_MONSTERS))
	check("the cursor on the magic and trap row cannot take a monster", not DuelHand.accepts(true, "", false, DuelHand.ROW_SPELLS))


# ---- the field phase: attack eligibility and position changes ---------------------------------------------------------

func _test_field_phase() -> void:
	group = "field phase"
	var eng = engine(14)
	eng.start([1, 2, 3], [4, 5, 6])
	var st = eng.state
	st.sides[0].monsters[0] = zone(eng, 1)
	check("no attacks on the first turn", not eng.can_attack(0, 0))
	eng.end_turn(0)
	st.sides[1].monsters[0] = zone(eng, 1)
	check("attacks open after the first turn ends", eng.can_attack(1, 0))
	st.sides[1].monsters[1] = zone(eng, 1, -1, -1, true)
	check("a defense-position monster cannot attack", not eng.can_attack(1, 1))
	st.sides[1].monsters[2] = zone(eng, 1, -1, -1, false, true)
	check("a face-down monster can attack", eng.can_attack(1, 2))
	st.sides[1].monsters[3] = zone(eng, 1)
	st.sides[1].monsters[3]["used"] = true
	check("a monster that already attacked this turn cannot attack", not eng.can_attack(1, 3))
	st.sides[1].swords_turns = 3
	check("Swords of Revealing Light stops the affected side's attacks", not eng.can_attack(1, 0))
	st.sides[1].swords_turns = 0
	eng.change_position(1, 0)
	check("a position change moves the monster to defense", st.sides[1].monsters[0]["defense"] == true)
	eng.change_position(1, 2)
	check("a position change turns a face-down monster face up", st.sides[1].monsters[2]["face_down"] == false)
	st.sides[1].monsters[4] = zone(eng, 1)
	st.sides[1].monsters[4]["used"] = true
	check("a monster that has attacked cannot change position", not eng.can_change_position(1, 4))


# ---- battles: the outcome table, damage, destruction and the rank counters ----------------------------------------------

## Fights `attacker` (side 0, zone 0) against `defender` (side 1, zone 0) on a fresh duel. Both use Blue-Eyes White Dragon,
## which has the same guardian star on both sides, so no star matchup applies. Returns the engine for inspection.
func _fight(attacker: Dictionary, defender) -> Object:
	var eng = engine(21)
	eng.start([1, 2, 3], [4, 5, 6])
	eng.end_turn(0)
	eng.state.sides[0].monsters[0] = attacker
	eng.state.sides[1].monsters[0] = defender
	eng.attack(0, 0, 0)
	return eng


func _test_battle() -> void:
	group = "battle"
	var a := zone(engine(), 1, 2000, 2000)
	var eng = _fight(a, zone(engine(), 1, 1500, 1500))
	check("ATK 2000 beats ATK 1500: the defender is destroyed", eng.state.sides[1].monsters[0] == null)
	check("ATK 2000 beats ATK 1500: the defender's side loses 500", eng.state.sides[1].lp == 7500)
	check("ATK 2000 beats ATK 1500: the attacker counts a card destruction and an effective attack",
			int(eng.state.sides[0].rank["card_destruction"]) == 1 and int(eng.state.sides[0].rank["effective_attacks"]) == 1)
	# the battle event carries what the presentation shows after the state has changed (the ids, the guardian star bonus and the positions)
	var shown_engine = engine(21)
	shown_engine.start([1, 2, 3], [4, 5, 6])
	shown_engine.end_turn(0)
	shown_engine.state.sides[0].monsters[0] = zone(shown_engine, 1, 2000, 2000)
	shown_engine.state.sides[1].monsters[0] = zone(shown_engine, 1, 1500, 1500, true)
	var battle_event: Dictionary = {}
	for event in shown_engine.attack(0, 0, 0):
		if str(event["kind"]) == "battle":
			battle_event = event
	check("battle event: the ids of both cards", int(battle_event.get("attacker_id", 0)) == 1 and
			int(battle_event.get("target_id", 0)) == 1)
	check("battle event: the star bonus, 0 for two Blue-Eyes", int(battle_event.get("star", -1)) == 0)
	check("battle event: the defender's position (defence)", bool(battle_event.get("target_defense", false)))
	eng = _fight(zone(engine(), 1, 1500, 1500), zone(engine(), 1, 1500, 1500))
	check("equal ATK: both monsters are destroyed", eng.state.sides[0].monsters[0] == null and eng.state.sides[1].monsters[0] == null)
	check("equal ATK: no life points lost", eng.state.sides[0].lp == 8000 and eng.state.sides[1].lp == 8000)
	eng = _fight(zone(engine(), 1, 1000, 1000), zone(engine(), 1, 1500, 1500))
	check("ATK 1000 into ATK 1500: the attacker is destroyed", eng.state.sides[0].monsters[0] == null)
	check("ATK 1000 into ATK 1500: the attacker's side loses 500", eng.state.sides[0].lp == 7500)
	check("ATK 1000 into ATK 1500: the defender survives", eng.state.sides[1].monsters[0] != null)
	eng = _fight(zone(engine(), 1, 2000, 2000), zone(engine(), 1, 1000, 1500, true))
	check("ATK 2000 into a defense 1500: the defender is destroyed as a defensive loss",
			eng.state.sides[1].monsters[0] == null and int(eng.state.sides[1].rank["defensive_losses"]) == 1)
	check("ATK 2000 into a defense 1500: no life points lost", eng.state.sides[1].lp == 8000)
	eng = _fight(zone(engine(), 1, 1000, 1000), zone(engine(), 1, 1000, 1500, true))
	check("ATK 1000 into a defense 1500: the attacker survives", eng.state.sides[0].monsters[0] != null)
	check("ATK 1000 into a defense 1500: the attacker's side loses 500", eng.state.sides[0].lp == 7500)
	check("a defense-position defender that holds counts a defensive win", int(eng.state.sides[1].rank["defensive_wins"]) == 1)
	eng = _fight(zone(engine(), 1, 1500, 1500), zone(engine(), 1, 1000, 1500, true))
	check("ATK 1500 into a defense 1500 (a draw of stats): nothing is destroyed", eng.state.sides[0].monsters[0] != null and
			eng.state.sides[1].monsters[0] != null and eng.state.sides[0].lp == 8000)
	check("a tie against a defense-position defender is not a defensive win", int(eng.state.sides[1].rank["defensive_wins"]) == 0)
	eng = _fight(zone(engine(), 1, 1200, 1200, true), zone(engine(), 1, 1000, 1000))
	check("DEF 1200 against ATK 1000 (defense attacker): the defender is destroyed and loses 200",
			eng.state.sides[1].monsters[0] == null and eng.state.sides[1].lp == 7800)
	eng = _fight(zone(engine(), 1, 1000, 1000, true), zone(engine(), 1, 1000, 1000))
	check("DEF 1000 against ATK 1000: nothing happens", eng.state.sides[0].monsters[0] != null and
			eng.state.sides[1].monsters[0] != null and eng.state.sides[1].lp == 8000)
	eng = _fight(zone(engine(), 1, 1500, 1500), zone(engine(), 1, 1000, 1000, true))
	check("ATK 1500 into a defense 1000: the defense monster is destroyed", eng.state.sides[1].monsters[0] == null)
	eng = engine(22)
	eng.start([1, 2, 3], [4, 5, 6])
	eng.end_turn(0)
	eng.state.sides[0].monsters[0] = zone(eng, 1, 1800, 1800)
	eng.attack(0, 0, -1)
	check("a direct attack deals its ATK to the opponent's life points", eng.state.sides[1].lp == 6200)
	var refused = engine(23)
	refused.start([1, 2, 3], [4, 5, 6])
	refused.end_turn(0)
	refused.state.sides[0].monsters[0] = zone(refused, 1, 1800, 1800)
	refused.state.sides[1].monsters[1] = zone(refused, 1, 1000, 1000)
	var refused_events: Array = refused.attack(0, 0, -1)
	check("a direct attack is refused while the opponent has a monster", refused_events.is_empty() and refused.state.sides[1].lp == 8000)
	check("an attack on an empty zone is refused while the opponent has a monster", refused.attack(0, 0, 0).is_empty())
	check("a refused attack does not use the attacker", refused.state.sides[0].monsters[0]["used"] == false)
	eng.state.sides[1].lp = 1000
	eng.state.sides[0].monsters[0]["used"] = false
	eng.attack(0, 0, -1)
	check("a direct attack that empties the life points decides the duel", eng.check_winner() == 0)
	check("the lethal side's win records +2", int(eng.state.sides[0].rank["result_adjustment"]) == 2)


# ---- traps: attack traps, Fake Trap, and the traps that spring on a card's play ------------------------------------------

func _test_traps() -> void:
	group = "traps"
	var eng = engine(31)
	var st = eng.state
	st.sides[1].traps[0] = zone(eng, 683, -1, -1, true)    # Bear Trap, 1500
	st.sides[1].traps[1] = zone(eng, 681, -1, -1, true)    # House of Adhesive Tape, 500
	check("the weakest attack trap that stops the attack springs (ATK 400: House of Adhesive Tape)",
			Effects.select_attack_trap(st, 1, 400) == 1)
	check("ATK 1200: Bear Trap springs", Effects.select_attack_trap(st, 1, 1200) == 0)
	check("ATK 2000: no attack trap stops it", Effects.select_attack_trap(st, 1, 2000) == -1)
	st.sides[1].traps[2] = zone(eng, 690, -1, -1, true)    # Fake Trap
	check("with no attack trap that fits, Fake Trap is the fallback", Effects.select_attack_trap(st, 1, 2000) == 2)
	st.sides[1].traps[0] = null
	st.sides[1].traps[1] = null
	st.sides[1].traps[2] = null
	st.sides[1].traps[3] = zone(eng, 686, -1, -1, true)    # Widespread Ruin
	check("Widespread Ruin catches any attack", Effects.select_attack_trap(st, 1, 9999) == 3)
	st.sides[1].traps[3] = null
	# an attack trap at its threshold springs (the boundary is inclusive); one point over does not
	var at := engine(32)
	at.start([1, 2, 3], [4, 5, 6])
	at.end_turn(0)
	at.state.sides[1].traps[0] = zone(at, 683, -1, -1, true)
	at.state.sides[0].monsters[0] = zone(at, 1, 1500, 1500)
	at.attack(0, 0, -1)
	check("Bear Trap springs on ATK 1500 (inclusive threshold): the attacker is destroyed",
			at.state.sides[0].monsters[0] == null and at.state.sides[1].traps[0] == null)
	check("a trap that springs counts for its owner's rank", int(at.state.sides[1].rank["traps_triggered"]) == 1)
	var over := engine(33)
	over.start([1, 2, 3], [4, 5, 6])
	over.end_turn(0)
	over.state.sides[1].traps[0] = zone(over, 683, -1, -1, true)
	over.state.sides[0].monsters[0] = zone(over, 1, 1501, 1500)
	over.attack(0, 0, -1)
	check("Bear Trap does not spring on ATK 1501: the attacker survives", over.state.sides[0].monsters[0] != null)
	var fake := engine(34)
	fake.start([1, 2, 3], [4, 5, 6])
	fake.end_turn(0)
	fake.state.sides[1].traps[0] = zone(fake, 690, -1, -1, true)
	fake.state.sides[0].monsters[0] = zone(fake, 1, 2000, 2000)
	var fake_events: Array = fake.attack(0, 0, 0)
	check("Fake Trap springs and the attacker survives", fake.state.sides[0].monsters[0] != null and fake.state.sides[1].traps[0] == null)
	var had_battle := false
	for event in fake_events:
		if str(event["kind"]) == "battle":
			had_battle = true
	check("a sprung Fake Trap stops the battle", not had_battle)
	# Bad Reaction to Simochi, Goblin Fan and Reverse Trap: spent when they spring on a card's play
	var mage := engine(35)
	mage.state.sides[1].traps[0] = zone(mage, 688, -1, -1, true)
	mage.state.sides[0].lp = 8000
	Effects.resolve(mage.state, 0, 338, rng_of(1))
	check("Bad Reaction turns a recovery into a loss (Mooyan Curry: -200)", mage.state.sides[0].lp == 7800)
	check("Bad Reaction is spent", mage.state.sides[1].traps[0] == null)
	var goblin := engine(36)
	goblin.state.sides[1].traps[0] = zone(goblin, 687, -1, -1, true)
	Effects.resolve(goblin.state, 0, 343, rng_of(1))
	check("Goblin Fan reflects a direct damage card onto its caster", goblin.state.sides[0].lp == 7950)
	check("Goblin Fan leaves the opponent untouched", goblin.state.sides[1].lp == 8000)
	check("Goblin Fan is spent", goblin.state.sides[1].traps[0] == null)


# ---- magic cards: every group in the dispatch table ---------------------------------------------------------------------

func _test_magic() -> void:
	group = "magic"
	var eng = engine(41)
	var st = eng.state
	var rng := rng_of(2)
	st.sides[0].lp = 7000
	var events: Array = Effects.resolve(st, 0, 338, rng)
	check("Mooyan Curry restores 200 life points", st.sides[0].lp == 7200 and int(events[0]["amount"]) == 200)
	st.sides[0].lp = 4000
	Effects.resolve(st, 0, 342, rng)
	check("Dian Keto restores 5000 but stops at the 8000 maximum", st.sides[0].lp == 8000)
	st.sides[0].lp = 9000
	Effects.resolve(st, 0, 338, rng)
	check("healing never lowers life points above the maximum", st.sides[0].lp == 9000)
	st.sides[0].lp = 8000
	st.sides[1].lp = 8000
	Effects.resolve(st, 0, 343, rng)
	check("Sparks deals 50 to the opponent", st.sides[1].lp == 7950)
	st.sides[1].lp = 8000
	Effects.resolve(st, 0, 347, rng)
	check("Tremendous Fire deals 1000 to the opponent", st.sides[1].lp == 7000)
	st.sides[1].lp = 30
	Effects.resolve(st, 0, 345, rng)
	check("direct damage stops at zero life points", st.sides[1].lp == 0)
	# Dark Hole clears both rows of both sides
	eng = engine(42)
	st = eng.state
	for side in 2:
		st.sides[side].monsters[0] = zone(eng, 1)
		st.sides[side].traps[0] = zone(eng, 683, -1, -1, true)
	Effects.resolve(st, 0, 336, rng)
	check("Dark Hole clears the monsters and traps of both sides", st.sides[0].monsters[0] == null and st.sides[1].monsters[0] == null
			and st.sides[0].traps[0] == null and st.sides[1].traps[0] == null)
	# Raigeki clears the opponent's monsters only
	eng = engine(43)
	st = eng.state
	st.sides[0].monsters[0] = zone(eng, 1)
	st.sides[1].monsters[0] = zone(eng, 1)
	Effects.resolve(st, 0, 337, rng)
	check("Raigeki clears the opponent's monsters", st.sides[1].monsters[0] == null)
	check("Raigeki leaves the caster's monsters", st.sides[0].monsters[0] != null)
	# Harpie's Feather Duster clears the opponent's magic/trap row only
	eng = engine(44)
	st = eng.state
	st.sides[1].traps[0] = zone(eng, 683, -1, -1, true)
	st.sides[1].monsters[0] = zone(eng, 1)
	st.sides[0].traps[0] = zone(eng, 683, -1, -1, true)
	Effects.resolve(st, 0, 672, rng)
	check("Harpie's Feather Duster clears the opponent's traps", st.sides[1].traps[0] == null)
	check("Harpie's Feather Duster leaves the opponent's monsters and the caster's traps", st.sides[1].monsters[0] != null
			and st.sides[0].traps[0] != null)
	# Dragon Capture Jar takes the opponent's Dragons only
	eng = engine(45)
	st = eng.state
	st.sides[1].monsters[0] = zone(eng, 1)
	st.sides[1].monsters[1] = zone(eng, 2)
	Effects.resolve(st, 0, 329, rng)
	check("Dragon Capture Jar takes the opponent's Dragon", st.sides[1].monsters[0] == null)
	check("Dragon Capture Jar leaves the opponent's other monsters", st.sides[1].monsters[1] != null)
	# type removal and Crush Card
	eng = engine(46)
	st = eng.state
	st.sides[1].monsters[0] = zone(eng, 12)
	st.sides[1].monsters[1] = zone(eng, 2)
	Effects.resolve(st, 0, 653, rng)
	check("Warrior Elimination takes the opponent's Warrior", st.sides[1].monsters[0] == null)
	check("Warrior Elimination leaves the opponent's Spellcaster", st.sides[1].monsters[1] != null)
	eng = engine(47)
	st = eng.state
	st.sides[1].monsters[0] = zone(eng, 2, 1500, 1000)
	st.sides[1].monsters[1] = zone(eng, 2, 1499, 1000)
	Effects.resolve(st, 0, 661, rng)
	check("Crush Card destroys an opponent's monster with ATK 1500", st.sides[1].monsters[0] == null)
	check("Crush Card leaves an opponent's monster with ATK 1499", st.sides[1].monsters[1] != null)
	# Stop Defense, Spellbinding Circle, Shadow Spell
	eng = engine(48)
	st = eng.state
	st.sides[1].monsters[0] = zone(eng, 2, 1000, 1000, true)
	st.sides[0].monsters[0] = zone(eng, 2, 1000, 1000, true)
	Effects.resolve(st, 0, 320, rng)
	check("Stop Defense turns the opponent's defense monsters to attack", st.sides[1].monsters[0]["defense"] == false)
	check("Stop Defense leaves the caster's defense monsters alone", st.sides[0].monsters[0]["defense"] == true)
	st.sides[1].monsters[1] = zone(eng, 2, 1000, 1000)
	Effects.resolve(st, 0, 349, rng)
	check("Spellbinding Circle lowers the opponent's monsters by 500", st.sides[1].monsters[1]["mod"] == -500)
	Effects.resolve(st, 0, 669, rng)
	check("Shadow Spell lowers the opponent's monsters by 1000 more", st.sides[1].monsters[1]["mod"] == -1500)
	check("Spellbinding Circle leaves the caster's monsters alone", st.sides[0].monsters[0]["mod"] == 0)
	# Swords of Revealing Light and Dark-piercing Light reveal the opponent's face-down monsters
	eng = engine(49)
	st = eng.state
	st.sides[1].monsters[0] = zone(eng, 2, 1000, 1000, false, true)
	st.sides[0].monsters[0] = zone(eng, 2, 1000, 1000, false, true)
	Effects.resolve(st, 0, 348, rng)
	check("Swords of Revealing Light reveals the opponent's face-down monster", st.sides[1].monsters[0]["face_down"] == false)
	check("Swords of Revealing Light locks the opponent for four counter steps", st.sides[1].swords_turns == 4)
	check("Swords of Revealing Light leaves the caster's face-down monster hidden", st.sides[0].monsters[0]["face_down"] == true)
	eng = engine(50)
	st = eng.state
	st.sides[1].monsters[0] = zone(eng, 2, 1000, 1000, false, true)
	st.sides[0].monsters[0] = zone(eng, 2, 1000, 1000, false, true)
	Effects.resolve(st, 0, 350, rng)
	check("Dark-piercing Light reveals the opponent's face-down monster", st.sides[1].monsters[0]["face_down"] == false)
	check("Dark-piercing Light leaves the caster's face-down monster hidden", st.sides[0].monsters[0]["face_down"] == true)
	# Cursebreaker (as the port applies it: the caster's own negative modifiers are removed)
	eng = engine(51)
	st = eng.state
	st.sides[0].monsters[0] = zone(eng, 2, 1000, 1000)
	st.sides[0].monsters[0]["mod"] = -300
	Effects.resolve(st, 0, 655, rng)
	check("Cursebreaker removes the caster's negative modifier", st.sides[0].monsters[0]["mod"] == 0)
	# terrain cards
	eng = engine(52)
	st = eng.state
	Effects.resolve(st, 0, 330, rng)
	check("Forest sets the terrain to 1", st.terrain == 1)
	Effects.resolve(st, 0, 335, rng)
	check("Yami sets the terrain to 6 (Dark)", st.terrain == 6)
	check("the magic card table covers the six terrains (330..335)", Effects.has_effect(330) and Effects.has_effect(335))


# ---- rituals -------------------------------------------------------------------------------------------------------------

func _test_rituals() -> void:
	group = "rituals"
	var eng = engine(61)
	var st = eng.state
	var rng := rng_of(3)
	for i in 3:
		st.sides[0].monsters[i * 2] = zone(eng, 1)
	Effects.resolve(st, 0, 675, rng)
	check("Ultimate Dragon takes three Blue-Eyes and summons Blue-eyes Ultimate Dragon", st.sides[0].monsters[2] != null and
			int(st.sides[0].monsters[2]["id"]) == 380)
	check("Ultimate Dragon removes the other two tributes", st.sides[0].monsters[0] == null and st.sides[0].monsters[4] == null)
	eng = engine(62)
	st = eng.state
	st.sides[0].monsters[0] = zone(eng, 1)
	st.sides[0].monsters[1] = zone(eng, 1)
	var events: Array = Effects.resolve(st, 0, 675, rng)
	check("a ritual with a missing tribute does nothing", events.is_empty() and st.sides[0].monsters[0] != null)
	eng = engine(63)
	st = eng.state
	st.sides[0].monsters[0] = zone(eng, 7)
	st.sides[0].monsters[2] = zone(eng, 35)
	st.sides[0].monsters[4] = zone(eng, 417)
	Effects.resolve(st, 0, 721, rng)
	check("Dark Magic Ritual summons Magician of Black Chaos on the middle tribute's zone", st.sides[0].monsters[2] != null and
			int(st.sides[0].monsters[2]["id"]) == 722)
	check("Dark Magic Ritual clears the other tributes", st.sides[0].monsters[0] == null and st.sides[0].monsters[4] == null)
	check("Dark Magic Ritual leaves one monster on the field", _count(st.sides[0].monsters) == 1)


# ---- win conditions and the result statistics -----------------------------------------------------------------------------

func _test_win_conditions() -> void:
	group = "win"
	var eng = engine(71)
	eng.start([1, 2, 3], [4, 5, 6])
	eng.state.sides[1].lp = 0
	check("a side at zero life points has lost", eng.check_winner() == 0)
	check("the winner's record takes +2", int(eng.state.sides[0].rank["result_adjustment"]) == 2)
	check("the loser's record takes nothing", int(eng.state.sides[1].rank["result_adjustment"]) == 0)
	eng = engine(72)
	eng.start([1, 2, 3], [4, 5, 6])
	eng.state.sides[0].lp = 0
	eng.state.sides[1].lp = 0
	eng.state.turn_side = 0
	check("with both at zero, the side that is not active wins", eng.check_winner() == 1)
	var stats: Dictionary = eng.result_stats()
	check("result statistics name the winner", int(stats["winner"]) == 1)
	check("result statistics carry each side's life points", int(stats["sides"][0]["life_points"]) == 0)
	check("a decided duel keeps its first ending", eng.check_winner() == 1)


# ---- the result statistics: each rank counter, the averages and the result screen's rows ---------------------------------

func _test_statistics() -> void:
	group = "statistics"
	var eng = engine(11)
	eng.state.sides[0].hand = [2, 8]
	eng.play(0, [0, 1])
	check("a two-card play that summons a monster counts a combo play", int(eng.state.sides[0].rank["combo_plays"]) == 1)
	eng = engine(12)
	eng.state.sides[0].hand = [1]
	eng.play(0, [0])
	check("a single card played counts no combo play", int(eng.state.sides[0].rank["combo_plays"]) == 0)
	eng = engine(13)
	eng.state.sides[0].hand = [1]
	eng.play(0, [0], -1, -1, true)
	check("a single monster set face-down counts a face-down play", int(eng.state.sides[0].rank["face_down_plays"]) == 1)
	eng = engine(14)
	var magic := card_of_type("Magic")
	eng.state.sides[0].hand = [magic]
	eng.play(0, [0])
	check("a magic card played counts a pure magic", int(eng.state.sides[0].rank["pure_magic_used"]) == 1)
	eng = engine(15)
	eng.state.sides[0].hand = [330]
	eng.play(0, [0])
	eng.state.sides[0].hand = [330]
	eng.play(0, [0])
	check("each field magic played counts a change of field, even one that sets the terrain it already has",
			int(eng.state.sides[0].rank["change_field"]) == 2 and eng.state.terrain == 1)
	# the averages: 20 Blue-Eyes (ATK 3000, DEF 2500) and 20 magic cards (no ATK or DEF) give 1500 and 1250
	var mixed: Array = []
	for i in 20:
		mixed.append(1)
		mixed.append(magic)
	eng = engine(16)
	eng.start(mixed.duplicate(), mixed.duplicate())
	check("average ATK factor over a half-magic deck is 1500", int(eng.state.sides[0].rank["avg_atk_factor"]) == 1500)
	check("average DEF factor over a half-magic deck is 1250", int(eng.state.sides[0].rank["avg_dfd_factor"]) == 1250)
	# a battle: the attacker's card destruction and the defender's defensive loss reach the statistics
	eng = _fight(zone(engine(), 1, 2000, 2000), zone(engine(), 1, 1000, 1500, true))
	var stats: Dictionary = eng.result_stats()
	check("result statistics carry the attacker's card destruction", int(stats["sides"][0]["card_destruction"]) == 1)
	check("result statistics carry the defender's defensive losses", int(stats["sides"][1]["defensive_losses"]) == 1)
	# the result screen's numbers: every statistic row is written at its page address (rank rows are 8 bytes apart, two sides)
	var numbers: Dictionary = DuelResult._numbers(stats["sides"], 0)
	var base: int = DuelResult.STAT_BASE
	check("the card destruction row shows the attacker's count", int(numbers[base + 3 * 8 + 0]) == 1)
	check("the defensive losses row shows the defender's count", int(numbers[base + 6 * 8 + 4]) == 1)
	check("the combo plays row is written for both sides", numbers.has(base + 8 * 8 + 0) and numbers.has(base + 8 * 8 + 4))
	check("the average ATK and DFD rows show the sides' factors", int(numbers[base + 2 * 8 + 4]) == int(stats["sides"][1]["avg_atk_factor"])
			and int(numbers[base + 5 * 8 + 0]) == int(stats["sides"][0]["avg_dfd_factor"]))
	check("the change field row is written", numbers.has(base + 12 * 8 + 0))


## The outro's confetti (the YOU WIN / YOU LOSE banner): the baked pieces keep the parts left of and above their spawn point (the
## layout's boxes are negative, the bake's margin), every piece has its trail picture, and a trail lives 16 frames (brightness 128 falls
## 8 a frame and is released at 0).
func _test_result_outro() -> void:
	group = "result outro"
	check("a trail is at full brightness when spawned", DuelResult.trail_brightness(0) == 128)
	check("a trail is still lit at frame 15", DuelResult.trail_brightness(15) > 0)
	check("a trail is released at frame 16", DuelResult.trail_brightness(16) <= 0)
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DuelResult.DIR + "layout.json"))
	var rows: Array = layout.get("confetti", [])
	var clipped := true
	var trails := true
	for side in 2:
		for kind in range(1, 30):
			var box = rows[side][kind - 1] if rows.size() > side and rows[side].size() >= kind else null
			if box is Dictionary:
				# the parts reach 20 to 24 pixels left of and above the spawn point, so an unclipped box starts left of and above it
				clipped = clipped and int(box["x"]) < 0 and int(box["y"]) < 0
				if not FileAccess.file_exists(DuelResult.DIR + "confetti_%d_%d_trail.png" % [side, kind]):
					trails = false
	check("the confetti pieces keep their left and top parts (boxes start left of and above the spawn point)", clipped)
	check("every confetti piece has its trail picture", trails)


## The opening movie: its timing (15 frames a second, frame 1 first, the end frame 303), the fade to black over the last four frames,
## the pre-decoded files and the wide picture's fit.
func _test_opening_movie() -> void:
	group = "opening movie"
	check("frame 1 at the start", OpeningMovie.frame_at(0.0) == 1)
	check("frame 2 after 1/15 s", OpeningMovie.frame_at(1.0 / 15.0 + 0.001) == 2)
	check("the frame does not pass the end frame", OpeningMovie.frame_at(100.0) == 303)
	check("full brightness before the fade", OpeningMovie.shade_at(299) == 1.0)
	check("three quarters at frame 300", is_equal_approx(OpeningMovie.shade_at(300), 0.75))
	check("black at the end frame", OpeningMovie.shade_at(303) == 0.0)
	check("the movie files are present", OpeningMovie.is_available())
	var info = JSON.parse_string(FileAccess.get_file_as_string("res://assets/movies/opening.json"))
	check("the movie has its 303 frames", typeof(info) == TYPE_DICTIONARY and int(info["frames"]) == 303)
	var last := Image.load_from_file("res://assets/movies/frames/f0303.png")
	check("the last frame is 320 x 240", last != null and last.get_size() == Vector2i(320, 240))
	var wide := Node2D.new()
	ScreenFit.stretch = true
	ScreenFit.apply(wide, Vector2(960, 480), 240.0, 480.0)
	check("the wide picture fills a 2:1 window", is_equal_approx(wide.scale.x, 2.0) and is_equal_approx(wide.scale.y, 2.0))
	ScreenFit.stretch = false
	ScreenFit.apply(wide, Vector2(960, 480), 240.0, 480.0)
	check("the 4:3 shape keeps the wide picture whole", is_equal_approx(wide.scale.x, 2.0) and wide.position.length() < 0.001)
	ScreenFit.stretch = true
	wide.free()
	group = ""


## The text box's glyph exit (scripts/ui/glyph_exit.gd): a page clear darkens the left corners over frames 1 to 8 and the right
## corners over 9 to 16, and the glyph is gone at 16; a choice clear waits 1 + x/16 + y/8 frames from the glyph's pen position, then
## raises its additive colour 4 of 128 a frame for 16 frames. The nodes are stepped by hand, so the counts are exact.
func _test_glyph_exit() -> void:
	group = "glyph exit"
	var GlyphExit = load("res://scripts/ui/glyph_exit.gd")
	var image := Image.create(8, 12, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 1))
	# the node is set up as the text box sets it, then readied by hand (a node made during _init is not readied before the checks)
	var kept: Array = []
	var make = func(choice: bool, local: Vector2) -> Array:
		var sprite := Sprite2D.new()
		sprite.texture = ImageTexture.create_from_image(image)
		var fx = GlyphExit.new()
		fx.sprite = sprite
		fx.choice = choice
		fx.local = local
		fx._ready()
		kept.append_array([sprite, fx])
		return [sprite, fx]
	var made: Array = make.call(false, Vector2.ZERO)
	var sprite: Sprite2D = made[0]
	var page = made[1]
	check("a page glyph lasts 16 frames", int(page.total) == 16)
	check("a page glyph hides its sprite as it leaves", not sprite.visible)
	for i in 8:
		page._physics_process(0.0)
	check("the left corners are black at frame 8", absf(float(page.vertex_colors[0].r)) < 0.001 and absf(float(page.vertex_colors[1].r) - 1.0) < 0.001)
	for i in 4:
		page._physics_process(0.0)
	check("the right corners are half dark at frame 12", absf(float(page.vertex_colors[1].r) - 0.5) < 0.001)
	for i in 4:
		page._physics_process(0.0)
	check("a page glyph is removed at frame 16", page.is_queued_for_deletion())

	made = make.call(true, Vector2(0, 0))
	sprite = made[0]
	var quick = made[1]
	check("a choice glyph at the box's corner waits 1 frame, then 16", int(quick.total) == 17 and int(quick.delay) == 1)
	check("a choice glyph keeps its sprite while it waits", sprite.visible and not quick.visible)
	quick._physics_process(0.0)
	check("a choice glyph waits its one frame", not quick.visible)
	quick._physics_process(0.0)
	check("a choice glyph glows from the frame after the wait", quick.visible and absf(float(quick.vertex_colors[0].r) - 4.0 / 128.0) < 0.001)
	for i in 15:
		quick._physics_process(0.0)
	check("a choice glyph is removed at its 17th frame", quick.is_queued_for_deletion() and not sprite.visible)

	made = make.call(true, Vector2(32, 24))
	sprite = made[0]
	var deep = made[1]
	check("a choice glyph further down and along waits 1 + 2 + 3 frames", int(deep.delay) == 6 and int(deep.total) == 22)
	for i in 6:
		deep._physics_process(0.0)
	check("the glyph waits its delay of 6 frames", not deep.visible and sprite.visible)
	deep._physics_process(0.0)
	check("the glow starts on the 7th frame", deep.visible)
	for node in kept:
		node.free()
	group = ""


## The second memory card screen's pure helpers (scripts/menu/second_card.gd): a save is recognised by its counts and deck, and a
## starter card is a full deck with a chest, its own name and its own code. Nothing is written to the player's save here.
func _test_second_card() -> void:
	group = "second card"
	var SecondCard = load("res://scripts/menu/second_card.gd")
	check("a dictionary with counts and a deck is a save", SecondCard.is_save({"counts": [], "deck": []}))
	check("an array is not a save", not SecondCard.is_save([1, 2]))
	check("a dictionary without a deck is not a save", not SecondCard.is_save({"counts": []}))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var card: Dictionary = SecondCard.starter_card(rng)
	check("a starter card is made", not card.is_empty())
	var deck: Array = card.get("deck", [])
	check("the starter card's deck is a full deck of 40", deck.size() == 40)
	var total := 0
	for n in card.get("counts", []):
		total += int(n)
	check("the chest holds a second deal besides the deck", total == 80)
	check("the starter card's name is PLAYER (six words, P first)", (card.get("name", []) as Array).size() == 6 and int(card["name"][0]) == 0x826F)
	check("the starter card is a save the trade reads", SecondCard.is_save(card))
	group = ""


## The guardian star symbols (the text's icon entries 0x18 to 0x21, baked by tools/extract.py bake_star_icons into star_icons/): all
## ten are present and 16 x 16, and the star prompt draws them at full size (the old half-size pictures made the broken symbols).
func _test_star_icons() -> void:
	group = "star icons"
	var names := ["mars", "jupiter", "saturn", "uranus", "pluto", "neptune", "mercury", "sun", "moon", "venus"]
	var all_present := true
	var all_sixteen := true
	for name in names:
		var image := Image.load_from_file("res://assets/screens/star_icons/%s.png" % name)
		if image == null:
			all_present = false
			continue
		if image.get_width() != 16 or image.get_height() != 16:
			all_sixteen = false
	check("the ten star symbols are on disc (star_icons/)", all_present)
	check("each star symbol is 16 x 16", all_sixteen and all_present)
	var source := FileAccess.get_file_as_string("res://scripts/duel/duel_scene.gd")
	check("the star prompt draws the baked symbols, not the old half-size pictures",
			source.find("STAR_ICONS + \"%s.png\"") >= 0 and source.find("star_guardians/%s.png") < 0 and source.find("symbol.scale") < 0)
	group = ""


func _count(row: Array) -> int:
	var n := 0
	for zone_entry in row:
		if zone_entry != null:
			n += 1
	return n


## JSON numbers arrive as floats: the recipes are compared as whole numbers.
func _ints(values: Array) -> Array:
	var out: Array = []
	for value in values:
		out.append(int(value))
	return out


## The picture's sampling (F5) and scanlines (F6) reach the materials made before the change; the HD art (mods/auto-hd) is drawn at
## the baked size. Nothing here writes user://settings.json: the setting is changed in the static state only (set_filter saves it).
func _test_display() -> void:
	group = "display"
	var material: ShaderMaterial = ScreenFit.make_material()
	var saved_filter: int = ScreenFit.filter
	var saved_crt: bool = ScreenFit.crt
	ScreenFit.filter = ScreenFit.Filter.PIXEL
	ScreenFit._refresh()
	check("pixel sampling reaches a material made before the change", int(material.get_shader_parameter("filter_mode")) == 0)
	ScreenFit.filter = ScreenFit.Filter.SMOOTH
	ScreenFit._refresh()
	check("smooth sampling reaches it too", int(material.get_shader_parameter("filter_mode")) == 2)
	ScreenFit.filter = ScreenFit.Filter.SHARP
	ScreenFit._refresh()
	check("sharp is the default sampling", int(material.get_shader_parameter("filter_mode")) == 1)
	ScreenFit.crt = true
	ScreenFit._refresh()
	check("scanlines reach the material", is_equal_approx(float(material.get_shader_parameter("crt")), 1.0))
	ScreenFit.crt = saved_crt
	ScreenFit.filter = saved_filter
	ScreenFit._refresh()
	check("the sampling names are the three settings", ScreenFit.FILTER_NAMES == ["pixel", "sharp", "smooth"])
	check("the picture materials are registered for the change", ScreenFit._materials.size() >= 1)
	var mirror := "res://mods/auto-hd/scales.json"
	if FileAccess.file_exists(mirror):
		var scales = JSON.parse_string(FileAccess.get_file_as_string(mirror))
		var entry: Dictionary = scales.get("screens/boot_0.png", {})
		check("the HD mirror lists boot_0 with its scale and baked size", entry.get("width") == 320 and entry.get("height") == 240)
		var scale := int(entry.get("scale", 0))
		var hd := Image.load_from_file("res://mods/auto-hd/assets/screens/boot_0.png")
		check("the HD boot picture is the baked size times its scale", hd != null and hd.get_size() == Vector2i(320 * scale, 240 * scale))
		var drawn: Texture2D = ModArt.texture("res://assets/screens/boot_0.png")
		check("texture() draws the HD picture at the baked size", drawn != null and drawn.get_size() == Vector2(320, 240))
		var art: Dictionary = ModArt.load_art("res://assets/images/card_art/001.png")
		check("load_art() reports the baked size with scale 1 (the HD pixels are behind it)", art["texture"] != null and art["texture"].get_size() == Vector2(102, 96) and is_equal_approx(float(art["scale"]), 1.0))
	else:
		check("no HD mirror in this checkout: texture() still gives the baked size", ModArt.texture("res://assets/screens/boot_0.png").get_size() == Vector2(320, 240))
	group = ""


## The card pictures with the HD art on or off: a picture reports its baked size through get_size() (the HD pixels are kept behind the
## size); the card's face is composed from the thumbnail's baked pixels, so its picture lands on the same cells (6, 6) with the same
## colours; the story's panels take their regions from the baked picture. The mirror's entries match its pictures.
func _test_card_faces() -> void:
	group = "card art"
	var thumb := "res://assets/images/thumbnails/001.png"
	var base: Image = ModArt.base_image(thumb)
	check("the thumbnail's baked picture is 40 x 32", base != null and base.get_size() == Vector2i(40, 32))
	var art: Dictionary = ModArt.load_art("res://assets/images/card_art/001.png")
	check("the card art's texture reports its baked size (102 x 96)", art["texture"] != null and art["texture"].get_size() == Vector2(102, 96))
	check("load_art's scale is 1: the texture is already the baked size", is_equal_approx(float(art["scale"]), 1.0))
	var thumb_texture: Texture2D = ModArt.texture(thumb)
	check("the thumbnail texture reports 40 x 32", thumb_texture != null and thumb_texture.get_size() == Vector2(40, 32))
	var plain: Texture2D = ModArt.plain_texture(thumb)
	check("the plain texture has the baked pixels (40 x 32)", plain != null and plain.get_image().get_size() == Vector2i(40, 32))
	var face: Texture2D = DuelCardFace.face("monster", base, 1200, 700, thumb)
	check("the face is 52 x 60", face != null and face.get_size() == Vector2(52, 60))
	var face_image := face.get_image()
	var same := true
	for y in 32:
		for x in 40:
			var p := base.get_pixel(x, y)
			if p.a >= 1.0 and not p.is_equal_approx(face_image.get_pixel(6 + x, 6 + y)):
				same = false
	check("every opaque picture cell lands at (6, 6) with its own colour", same)
	var entries = JSON.parse_string(FileAccess.get_file_as_string("res://mods/auto-hd/scales.json")) if FileAccess.file_exists("res://mods/auto-hd/scales.json") else null
	if typeof(entries) == TYPE_DICTIONARY and not ModArt._hd_entry("images/thumbnails/001.png").is_empty():
		var scale := int(entries["images/thumbnails/001.png"]["scale"])
		var hd_image: Image = thumb_texture.get_image()
		check("HD on: the thumbnail keeps its HD pixels", hd_image.get_size() == Vector2i(40 * scale, 32 * scale))
		check("HD on: the thumbnail still reports 40 x 32", thumb_texture.get_size() == Vector2(40, 32))
		var sample_ok := true
		var keys: Array = entries.keys()
		for i in range(0, keys.size(), maxi(keys.size() / 25, 1)):
			var rel: String = keys[i]
			var entry: Dictionary = entries[rel]
			var hd := Image.load_from_file("res://mods/auto-hd/assets/" + rel)
			if hd == null or hd.get_size() != Vector2i(int(entry["width"]) * int(entry["scale"]), int(entry["height"]) * int(entry["scale"])):
				sample_ok = false
		check("the mirror's scales.json matches its pictures (sampled)", sample_ok)
	var backdrop: Texture2D = ModArt.plain_texture("res://assets/screens/boot_0.png")
	check("a region user's texture is the baked picture (320 x 240)", backdrop != null and backdrop.get_image().get_size() == Vector2i(320, 240))
	group = ""


## The card viewer's picture (scripts/ui/card_view.gd, card_picture): the whole card at 1x, 140 x 196, on the frame of its kind, with the
## picture at (19, 50) of the card and the name plate's ink taken off the frame.
func _test_card_viewer() -> void:
	group = "card viewer"
	check("a magic card has the magic frame", CardView.frame_kind("Magic") == "magic")
	check("a trap, an equip and a ritual have their own frames", CardView.frame_kind("Trap") == "trap" and CardView.frame_kind("Equip") == "equip" and CardView.frame_kind("Ritual") == "ritual")
	check("a monster's type is its race: the monster frame", CardView.frame_kind("Dragon") == "monster" and CardView.frame_kind("Fiend") == "monster")
	var ui: Dictionary = CardView.load_ui()
	check("the card_ui layout is read", ui.has("label_atk") and ui.has("attribute_spell"))
	var magic: Image = CardView.card_picture(330, data.card(330), 0, 0, ui)
	check("a magic card's picture is the whole card, 140 x 196", magic != null and magic.get_size() == Vector2i(140, 196))
	var frame := Image.load_from_file("res://assets/screens/password/card_frame_magic_0.png")
	var art := Image.load_from_file("res://assets/images/card_art/330.png")
	if magic != null and frame != null and art != null:
		frame.convert(Image.FORMAT_RGBA8)
		art.convert(Image.FORMAT_RGBA8)
		check("the card's corner is the frame's corner", magic.get_pixel(0, 0) == frame.get_pixel(0, 0))
		check("the picture is laid at (19, 50) of the card", magic.get_pixel(19, 50) == art.get_pixel(0, 0) and magic.get_pixel(60, 90) == art.get_pixel(41, 40))
	var monster: Image = CardView.card_picture(5, data.card(5), 1000, 500, ui)
	var monster_frame := Image.load_from_file("res://assets/screens/password/card_frame_monster_0.png")
	check("a monster's picture is the whole card, 140 x 196, on the monster frame",
			monster != null and monster.get_size() == Vector2i(140, 196) and monster_frame != null and monster.get_pixel(0, 0) == monster_frame.get_pixel(0, 0))
	# the name plate's ink is subtracted from the frame, and a laid texel covers it
	var base := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	base.fill(Color(1.0, 1.0, 1.0, 1.0))
	var ink := Image.create(2, 1, false, Image.FORMAT_RGBA8)
	ink.set_pixel(0, 0, Color(0.25, 0.5, 0.75, 1.0))
	ink.set_pixel(1, 0, Color(0, 0, 0, 0))
	CardView.subtract_ink(base, ink, Vector2i(1, 2))
	var taken := base.get_pixel(1, 2)
	check("the ink is taken off the frame by its colour", absf(taken.r - 0.75) < 0.01 and absf(taken.g - 0.5) < 0.01 and absf(taken.b - 0.25) < 0.01)
	check("a clear ink texel leaves the frame alone", base.get_pixel(2, 2) == Color(1, 1, 1, 1))
	var split: Array = CardView.split_ink(_texels([Color(0.2, 0.2, 0.2, 1.0), Color(0.6, 0.6, 0.6, 0.5), Color(0, 0, 0, 0)]))
	check("a full texel is laid over the frame, a half one is an ink", split[0].get_pixel(0, 0).a > 0.99 and split[1].get_pixel(1, 0).a > 0.99 and split[0].get_pixel(1, 0).a == 0.0)


func _texels(colours: Array) -> Image:
	var image := Image.create(colours.size(), 1, false, Image.FORMAT_RGBA8)
	for i in colours.size():
		image.set_pixel(i, 0, colours[i])
	return image
