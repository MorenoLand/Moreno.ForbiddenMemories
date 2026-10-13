extends RefCounted
## The duel's tables, read from assets/data/*.json (written by tools/extract.py --cards --tables): cards, fusion recipes, equips,
## rituals, terrain bonuses and the duelists' deck and drop weights.

const DIR := "res://assets/data/"

var cards: Array = []              # index = card id - 1
var fusion_table: Dictionary = {}  # (low id << 10 | high id) -> result id
var equip_table: Dictionary = {}   # equip id -> {"monsters": {id: true}, "bonus": int}
var rituals: Array = []
var terrain: Dictionary = {}
var traps: Dictionary = {}
var duelists: Array = []
var starter_pools: Array = []      # the starter deck build: [{count, weights {card id: weight}}] seven pools summing to 40 cards

const MODS_DIR := "res://mods"     # the mods' folder (mods/ in the project); a test may point mods_dir elsewhere
const POOL_TOTAL := 2048           # a pool's weights, out of 2048
const DECK_COPIES := 40
const MIN_DECK_CARDS := 14         # a weighted deck with fewer cards is refused (40 cards at 3 copies each need 14)
const MEGAMORPH := 657
const SPELL_TYPES := ["Magic", "Trap", "Ritual", "Equip"]
const DROP_KEYS := {"pow": "pow", "sa-pow": "pow", "bcd": "bcd", "b-c-d": "bcd", "tec": "tec", "sa-tec": "tec"}
const TERRAIN_ALIASES := {"sogen": "Meadow", "umi": "Sea", "yami": "Dark"}

var mods_dir := MODS_DIR
var skipped: Array = []            # rules of the mods this build cannot use; printed when the mods are read
var mod_fusions: Dictionary = {}   # (low id << 10 | high id) -> result id, 0 for "does not fuse": the mods' own recipes
var fixed_decks: Dictionary = {}   # opponent index -> the forty card ids of a mod's fixed deck
var _by_name: Dictionary = {}      # normalised card name -> id
var _types: Dictionary = {}        # normalised monster type -> the type's name
var _explicit_bonus: Dictionary = {}   # equip id -> true when a mod's rule sets its bonus
var _default_bonus = null          # the latest equip_bonus_default of the mods


func load_all() -> bool:
	cards = _json("cards.json")
	var fusions: Array = _json("fusions.json")
	var equips: Array = _json("equips.json")
	rituals = _json("rituals.json")
	duelists = _json("duelists.json")
	starter_pools = _json("starter_pools.json")
	var terrain_json = _json_value("terrain.json")
	var traps_json = _json_value("attack_traps.json")
	if cards.is_empty() or fusions.is_empty():
		return false
	for f in fusions:
		var ids: Array = f["ids"]
		fusion_table[(mini(ids[0], ids[1]) << 10) | maxi(ids[0], ids[1])] = int(ids[2])
	for e in equips:
		var set := {}
		for id in e["monster_ids"]:
			set[int(id)] = true
		equip_table[int(e["id"])] = {"monsters": set, "bonus": int(e["bonus"])}
	terrain = terrain_json if typeof(terrain_json) == TYPE_DICTIONARY else {}
	traps = traps_json if typeof(traps_json) == TYPE_DICTIONARY else {}
	_index_names()
	_apply_mods()
	return true


func card(id: int) -> Dictionary:
	return cards[id - 1] if id >= 1 and id <= cards.size() else {}


## The card two cards fuse into, or 0 (Fusion table lookup, order independent).
func fuse(a: int, b: int) -> int:
	var key := (mini(a, b) << 10) | maxi(a, b)
	if mod_fusions.has(key):
		return int(mod_fusions[key])
	return int(fusion_table.get(key, 0))


func can_equip(equip: int, monster: int) -> bool:
	return equip_table.has(equip) and equip_table[equip]["monsters"].has(monster)


## The ATK and DEF an equip adds to its monster: the mods' bonus, else the disc's +500 (Megamorph's +1000).
func equip_bonus(equip: int) -> int:
	if equip_table.has(equip):
		return int(equip_table[equip]["bonus"])
	return 1000 if equip == MEGAMORPH else 500


## A mod's fixed deck for this opponent (its forty card ids), or an empty array.
func fixed_deck(opponent: int) -> Array:
	return (fixed_decks.get(opponent, []) as Array).duplicate()


func _json(file: String) -> Array:
	var value = _json_value(file)
	return value if typeof(value) == TYPE_ARRAY else []


static var _json_cache := {}     # parsed files, kept for the whole run (fusions.json alone is over 2 MB)


func _json_value(file: String):
	if _json_cache.has(file):
		return _json_cache[file]
	var path := DIR + file
	if not FileAccess.file_exists(path):
		return null
	var value = JSON.parse_string(FileAccess.get_file_as_string(path))
	_json_cache[file] = value
	return value


## the starter deck build: from each pool, `count` weighted draws (a value in 1..2048 walked over the weights in card order),
## a card that already has three copies is redrawn.
func deal_starter_deck(rng: RandomNumberGenerator) -> Array:
	var deck: Array = []
	var copies := {}
	for pool in starter_pools:
		var remaining := int(pool["count"])
		var weights: Dictionary = pool["weights"]
		var order: Array = weights.keys()
		order.sort_custom(func(a, b): return int(a) < int(b))
		while remaining > 0:
			var threshold := (rng.randi() & 0x7FF) + 1
			var acc := 0
			for key in order:
				acc += int(weights[key])
				if acc >= threshold:
					var id := int(key)
					if int(copies.get(id, 0)) < 3:
						copies[id] = int(copies.get(id, 0)) + 1
						deck.append(id)
						remaining -= 1
					break
	return deck


# ---- mods ----------------------------------------------------------------------------------------------------------------
# The rules of each enabled mods/<folder>/mod.json, laid over the disc's tables: fusions, equips, rituals, drops, decks
# (weighted or fixed) and terrain bonuses. Other keys are left out and printed.

## The rules of every enabled mod under mods_dir, in folder-name order: a later mod's rule is applied after an earlier one's.
func _apply_mods() -> void:
	skipped.clear()
	var dir := DirAccess.open(mods_dir)
	if dir == null:
		return
	var folders := dir.get_directories()
	folders.sort()
	for folder in folders:
		var path := mods_dir.path_join(folder).path_join("mod.json")
		if not FileAccess.file_exists(path):
			continue
		var manifest = JSON.parse_string(FileAccess.get_file_as_string(path).trim_prefix("﻿"))
		if typeof(manifest) != TYPE_DICTIONARY or manifest.get("enabled", true) == false:
			continue
		_apply_manifest(manifest)
	_finish_equips()
	for line in skipped:
		print("mods: left out ", line)


func _apply_manifest(manifest: Dictionary) -> void:
	var settings := {}
	for setting in _list(manifest, "settings"):
		if typeof(setting) == TYPE_DICTIONARY and setting.has("key"):
			settings[str(setting["key"])] = int(setting.get("default", 1)) != 0
	for rule in _list(manifest, "fusions"):
		if _on(rule, settings):
			_fusion_rule(rule)
	for rule in _list(manifest, "equips"):
		if _on(rule, settings):
			_equip_rule(rule)
	for rule in _list(manifest, "rituals"):
		if _on(rule, settings):
			_ritual_rule(rule)
	if manifest.has("equip_bonus_default"):
		_default_bonus = int(manifest["equip_bonus_default"])
	if typeof(manifest.get("drops", null)) == TYPE_DICTIONARY:
		_drop_rules(manifest["drops"])
	if typeof(manifest.get("decks", null)) == TYPE_DICTIONARY:
		_deck_rules(manifest["decks"])
	if typeof(manifest.get("terrain_bonus", null)) == TYPE_DICTIONARY:
		_terrain_rules(manifest["terrain_bonus"])


## A rule with a "setting" is read only while that setting of its mod is on; a setting the mod does not declare is on.
func _on(rule, settings: Dictionary) -> bool:
	if typeof(rule) != TYPE_DICTIONARY:
		return false
	return not rule.has("setting") or bool(settings.get(str(rule["setting"]), true))


## {"remove": X} takes X's recipes out of the disc's table; {"remove": "all"} takes the whole disc table; {"with": [A, B],
## "result": X} adds or changes the recipe (result null: they do not fuse). The mods' recipes are kept apart from the disc's.
func _fusion_rule(rule: Dictionary) -> void:
	if rule.has("remove"):
		if str(rule["remove"]).to_lower() == "all":
			fusion_table.clear()
			return
		var gone := _card_id(rule["remove"])
		for key in fusion_table.keys():
			if int(fusion_table[key]) == gone:
				fusion_table.erase(key)
		return
	var with := _list(rule, "with")
	if with.size() != 2 or _card_id(with[0]) == 0 or _card_id(with[1]) == 0:
		_skip("fusion %s" % str(rule))
		return
	var a := _card_id(with[0])
	var b := _card_id(with[1])
	var key := (mini(a, b) << 10) | maxi(a, b)
	if rule.has("result") and rule["result"] == null:
		mod_fusions[key] = 0
		return
	var result := _card_id(rule.get("result", 0))
	if result == 0:
		_skip("fusion %s" % str(rule))
		return
	mod_fusions[key] = result


## {"card", "add", "remove", "replace", "bonus"}: the monsters the equip may equip (a card or a monster type), and its bonus.
## Within one rule the removals come after the additions.
func _equip_rule(rule: Dictionary) -> void:
	var card := _card_id(rule.get("card", 0))
	if card == 0:
		_skip("equip %s" % str(rule))
		return
	var entry: Dictionary = equip_table.get(card, {"monsters": {}, "bonus": equip_bonus(card)})
	if bool(rule.get("replace", false)):
		entry["monsters"] = {}
	for item in _list(rule, "add"):
		for id in _monsters_named(item):
			entry["monsters"][id] = true
	for item in _list(rule, "remove"):
		for id in _monsters_named(item):
			entry["monsters"].erase(id)
	if rule.has("bonus"):
		entry["bonus"] = int(rule["bonus"])
		_explicit_bonus[card] = true
	equip_table[card] = entry


## {"card", "tributes", "result"} with one to five tributes from the field; result null takes the ritual away. A ritual
## the disc has is replaced in place; another card becomes a ritual.
func _ritual_rule(rule: Dictionary) -> void:
	var card := _card_id(rule.get("card", 0))
	if card == 0:
		_skip("ritual %s" % str(rule))
		return
	var at := -1
	for i in rituals.size():
		if int(rituals[i]["id"]) == card:
			at = i
			break
	if rule.has("result") and rule["result"] == null:
		if at >= 0:
			rituals.remove_at(at)
		return
	var tributes: Array = []
	for item in _list(rule, "tributes"):
		var id := _card_id(item)
		if id == 0:
			tributes = []
			break
		tributes.append(id)
	var result := _card_id(rule.get("result", 0))
	if result == 0 or tributes.is_empty() or tributes.size() > 5:
		_skip("ritual %s" % str(rule))
		return
	var names: Array = []
	for id in tributes:
		names.append(_name_of(id))
	var record := {"id": card, "card": _name_of(card), "tributes": names, "tribute_ids": tributes,
			"result": _name_of(result), "result_id": result}
	if at >= 0:
		rituals[at] = record
	else:
		rituals.append(record)


## {"<opponent>": {"pow": {card: weight}, "bcd": ..., "tec": ...}}: each prize pool of the opponents named.
func _drop_rules(drops: Dictionary) -> void:
	for who in drops:
		var pools = drops[who]
		if typeof(pools) != TYPE_DICTIONARY:
			_skip("drops %s" % str(who))
			continue
		for index in _duelists_named(str(who)):
			var duelist: Dictionary = duelists[index]
			var own: Dictionary = duelist.get("drops", {})
			for key in pools:
				var pool := str(DROP_KEYS.get(str(key), ""))
				if pool == "" or typeof(pools[key]) != TYPE_DICTIONARY:
					_skip("drops %s %s" % [who, key])
					continue
				var edited = _edit_pool(own.get(pool, {}), pools[key], 1)
				if edited == null:
					_skip("drops %s %s" % [who, key])
				else:
					own[pool] = edited
			duelist["drops"] = own


## {"<opponent>": {card: copies...} with "fixed": true, or {card: weight}}: a fixed deck of forty, or an edit of the weighted one.
func _deck_rules(decks: Dictionary) -> void:
	for who in decks:
		var spec = decks[who]
		if typeof(spec) != TYPE_DICTIONARY:
			_skip("decks %s" % str(who))
			continue
		for index in _duelists_named(str(who)):
			if spec.has("fixed"):
				var fixed := _fixed_cards(spec)
				if spec["fixed"] == true and fixed.size() == DECK_COPIES:
					fixed_decks[index] = fixed
				else:
					_skip("fixed deck %s" % str(who))
				continue
			var duelist: Dictionary = duelists[index]
			var edited = _edit_pool(duelist.get("deck", {}), spec, MIN_DECK_CARDS)
			if edited == null:
				_skip("decks %s" % str(who))
			else:
				duelist["deck"] = edited


## {"<terrain>": {"<monster type>": points}, "replace": bool}: the ATK and DEF a terrain gives each monster type.
func _terrain_rules(rule: Dictionary) -> void:
	if not terrain.has("bonus"):
		terrain["bonus"] = {}
	var bonus: Dictionary = terrain["bonus"]
	if bool(rule.get("replace", false)):
		bonus.clear()
	for name in rule:
		if str(name) == "replace":
			continue
		var place := _terrain_name(str(name))
		if place == "" or typeof(rule[name]) != TYPE_DICTIONARY:
			_skip("terrain %s" % str(name))
			continue
		for kind in rule[name]:
			var row: Dictionary = bonus.get(str(kind), {})
			var points := int(rule[name][kind])
			if points == 0:
				row.erase(place)
			else:
				row[place] = points
			bonus[str(kind)] = row


## A weighted pool with a mod's edits: a listed card gets its weight out of 2048 (0
## takes it out); the unlisted cards share what is left in their proportions; "replace" empties the pool first; when the listed
## cards reach 2048, or nothing else is left, they make up the whole pool. Null when the result would be too small.
func _edit_pool(pool: Dictionary, spec: Dictionary, minimum: int):
	var listed := {}
	for key in spec:
		if str(key) == "replace":
			continue
		var id := _card_id(key)
		if id == 0:
			_skip("pool card %s" % str(key))
			return null
		listed[_name_of(id)] = int(spec[key])
	var others := {}
	if not bool(spec.get("replace", false)):
		for name in pool:
			if not listed.has(name):
				others[name] = int(pool[name])
	var listed_sum := 0
	var out := {}
	for name in listed:
		if int(listed[name]) > 0:
			out[name] = float(listed[name])
			listed_sum += int(listed[name])
	var other_sum := 0
	for name in others:
		other_sum += int(others[name])
	if listed_sum < POOL_TOTAL and other_sum > 0:
		var scale := float(POOL_TOTAL - listed_sum) / float(other_sum)
		for name in others:
			if int(others[name]) > 0:
				out[name] = int(others[name]) * scale
	var result := _to_total(out)
	return result if result.size() >= minimum else null


## The weights (ints or fractions) scaled to whole numbers that add up to POOL_TOTAL: each takes its floor, and the units left
## over go to the cards with the largest fractions (largest remainder), so no card drifts more than one unit.
func _to_total(weights: Dictionary) -> Dictionary:
	var total := 0.0
	for name in weights:
		total += float(weights[name])
	var out := {}
	if total <= 0.0:
		return out
	var parts: Array = []
	var sum := 0
	for name in weights:
		var value := float(weights[name]) * POOL_TOTAL / total
		var base := floori(value)
		out[name] = base
		sum += base
		parts.append([value - base, name])
	parts.sort_custom(func(a, b): return a[0] > b[0])
	for i in mini(POOL_TOTAL - sum, parts.size()):
		out[parts[i][1]] = int(out[parts[i][1]]) + 1
	for name in out.keys():
		if int(out[name]) <= 0:
			out.erase(name)
	return out


## The card ids of a fixed deck's copies (the "fixed" key aside), or an empty array when a name is unknown.
func _fixed_cards(spec: Dictionary) -> Array:
	var out: Array = []
	for key in spec:
		if str(key) == "fixed":
			continue
		var id := _card_id(key)
		if id == 0:
			return []
		for copy in int(spec[key]):
			out.append(id)
	return out


## The opponents a rule names: "all", a number, or a name (case and punctuation ignored). The unused slot is never named.
func _duelists_named(who: String) -> Array:
	var out: Array = []
	if who.to_lower() == "all":
		for i in duelists.size():
			if not bool(duelists[i].get("unused", false)):
				out.append(i)
		return out
	if who.is_valid_int():
		var number := who.to_int()
		if number >= 0 and number < duelists.size() and not bool(duelists[number].get("unused", false)):
			out.append(number)
		else:
			_skip("opponent %s" % who)
		return out
	var key := _normal(who)
	for i in duelists.size():
		if not bool(duelists[i].get("unused", false)) and _normal(str(duelists[i].get("name", ""))) == key:
			out.append(i)
	if out.is_empty():
		_skip("opponent %s" % who)
	return out


func _terrain_name(text: String) -> String:
	var names: Array = terrain.get("terrains", [])
	if text.is_valid_int():
		var number := text.to_int()
		return str(names[number - 1]) if number >= 1 and number <= names.size() else ""
	var key := _normal(text)
	for name in names:
		if _normal(str(name)) == key:
			return str(name)
	return str(TERRAIN_ALIASES.get(key, ""))


## equip_bonus_default: every equip that no rule gives a bonus of its own adds it.
func _finish_equips() -> void:
	if _default_bonus == null:
		return
	for id in equip_table:
		if not _explicit_bonus.has(id):
			equip_table[id]["bonus"] = _default_bonus


func _index_names() -> void:
	_by_name.clear()
	_types.clear()
	for i in cards.size():
		var name := _normal(str(cards[i].get("name", "")))
		if name != "" and not _by_name.has(name):
			_by_name[name] = i + 1
		var kind := str(cards[i].get("type", ""))
		if kind != "" and not SPELL_TYPES.has(kind):
			_types[_normal(kind)] = kind


## A card as a rule names it: its number, or its name with case, spaces and punctuation ignored. 0 when there is none.
func _card_id(value) -> int:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		var number := int(value)
		return number if number >= 1 and number <= cards.size() else 0
	if typeof(value) != TYPE_STRING:
		return 0
	var text: String = value
	if text.is_valid_int():
		return _card_id(text.to_int())
	return int(_by_name.get(_normal(text), 0))


func _name_of(id: int) -> String:
	return str(card(id).get("name", ""))


## The monsters a card or a monster type names: the one card, or every card of that type.
func _monsters_named(item) -> Array:
	var out: Array = []
	var id := _card_id(item)
	if id != 0:
		out.append(id)
		return out
	var kind := str(_types.get(_normal(str(item)), ""))
	if kind == "":
		_skip("card or type %s" % str(item))
		return out
	for i in cards.size():
		if str(cards[i].get("type", "")) == kind:
			out.append(i + 1)
	return out


func _normal(text: String) -> String:
	var out := ""
	for c in text.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
	return out


func _list(source: Dictionary, key: String) -> Array:
	var value = source.get(key, [])
	return value if typeof(value) == TYPE_ARRAY else []


func _skip(what: String) -> void:
	skipped.append(what)
