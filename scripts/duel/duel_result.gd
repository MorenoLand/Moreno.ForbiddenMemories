extends Control
## The duel result screen (RESULTS OF DUEL): the three pages SPOILS, the statistics and SPECIAL ARTS, drawn with the game's own
## pictures (assets/screens/duel_result/, baked by tools/extract.py --screens) and text (assets/screens/text.json, text_bank.bin).
## The rank (score, letter and tier), the starchip prize and the card dealt from the opponent's drop pool are worked out by the
## static functions below, which follow the rank score sum, the result rewards update and the card drop selection. They take no
## scene state, so DuelResult.evaluate() can be run headless (scratchpad tests).
## Input: `stats` (set before the screen enters the tree): {"winner": 0|1, "opponent_id": n (-1: none), "seed": n (optional),
## "sides": [side0, side1]}, where each side has result_adjustment (+2 at zero LP, +40 Exodia, -40 deck-out, else 0), turns_taken,
## effective_attacks, defensive_wins, face_down_plays, pure_magic_used, traps_triggered, fusions_initiated, equips_used, change_field,
## cards_used and life_points. DuelEngine.result_stats() makes it.
## Left and right turn the pages, Confirm (E or Space) leaves: the screen emits finished() when it is gone and sound(effect) for the
## game's sound effects (6 page turn, 0x30 leave). The caller applies `result` (starchips, the card) to the save.
## The outro (the result outro update) runs first: the confetti of the winning side's row (the data at 0x80090928 / the data at 0x80090960) orbits its
## spawn point, holds, and fades away, then the pages open. The confetti pictures are baked as duel_result/confetti_<side>_<kind>.png
## (the pieces of the YOU WIN / YOU LOSE banner, drawn around their spawn point) and their trails as confetti_<side>_<kind>_trail.png
## (additive, see _spawn_trail); a missing picture is skipped. The starchip picture is duel_result/starchip.png (baked from the game's starchip object). The banner (YOU WIN / YOU LOSE) is the winning side's seven pieces at their rest points: the pieces spell it out as they settle. The result
## jingle plays through the music signal; the outro's hold ends when the jingle stops (or after 0x258 frames, the game's own limit); the duel picture behind the screen is dimmed by the rewards state's fade (level 255 to 128, 2 a frame, once the pages open) and the leave fade takes it to 0 at 6 a frame (the spec's Fade_SetTargetLevel steps); the outro plays over the undimmed picture, and the FIELD box and life-point panel slide off during it (see signal panels).

signal finished
signal sound(effect: int)
signal music(id: int)          # the result jingle: 0x72E0 lose, 0x72F0 win over a real opponent
signal panels(field_x: int, lp_x: int, divisor: int)   # the outro slides the FIELD box and the life-point panel off (the duel scene's slide_panels)

class PsxRand extends RefCounted:
	## The Psy-Q rand() the game draws its drops with: state = state * 1103515245 + 12345 (32 bits), the value is bits 16 to 30.
	var state: int

	func _init(seed_value: int = 1) -> void:
		state = seed_value & 0xFFFFFFFF

	func rand() -> int:
		state = (state * 1103515245 + 12345) & 0xFFFFFFFF
		return (state >> 16) & 0x7FFF


const TouchControls := preload("res://scripts/system/touch_controls.gd")
const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const GameText := preload("res://scripts/ui/game_text.gd")
const CardDB := preload("res://scripts/data/card_db.gd")

const DIR := "res://assets/screens/duel_result/"
const TEXT_BANK := "res://assets/screens/text_bank.bin"
const RANK_PATH := "res://assets/data/duel_rank.json"
const DUELISTS_PATH := "res://assets/data/duelists.json"
const STARCHIP_PATH := DIR + "starchip.png"

const RANK_SCORE_INITIAL := 50          # the rank score's starting value
const STARCHIP_MAX := 999999            # SAVE_DATA_STARCHIP_MAX
const CARD_COUNT := 722
const DROP_WEIGHT_TOTAL := 2048         # the drop weight total
const POOL_KEYS := ["pow", "bcd", "tec"]   # the card drop selection's index: 0 S/A POW, 1 B/C/D, 2 S/A TEC
const LETTERS := ["D", "C", "B", "A", "S"]   # the rank tier 0 to 4

# the rule rows of the duel rank table (one row per rank rule)
const RULE_TURNS := 0
const RULE_EFFECTIVE_ATTACKS := 1
const RULE_DEFENSIVE_WINS := 2
const RULE_FACE_DOWN_PLAYS := 3
const RULE_PURE_MAGIC := 4
const RULE_TRAPS_TRIGGERED := 5
const RULE_CARDS_USED := 6
const RULE_REMAINING_LP := 7
const RULE_INITIATE_FUSION := 8
const RULE_EQUIP_MAGIC := 9

# the statistics: [row of the data at 0x801D5608.rank_rows, key in a side's stats]. Rows 2, 3, 5, 6, 8 and 12 are printed by the game but feed no
# score; the duel counts them as the rank counters do (DuelEngine.result_stats), so every field shows its value.
const NUMBER_ROWS := [[0, "cards_used"], [1, "life_points"], [2, "avg_atk_factor"], [3, "card_destruction"],
		[4, "effective_attacks"], [5, "avg_dfd_factor"], [6, "defensive_losses"], [7, "defensive_wins"], [8, "combo_plays"],
		[9, "face_down_plays"], [10, "fusions_initiated"], [11, "equips_used"], [12, "change_field"], [13, "pure_magic_used"],
		[14, "traps_triggered"], [15, "turns_taken"]]
const STAT_BASE := 0x801D5608          # the data at 0x801D5608.rank_rows: [row][side] words, two sides
const CARD_NUMBER := 0x801D56A8        # the data at 0x801D56A8: the dropped card's number, printed on SPOILS
const SELECTOR_DEFAULT := 0x40         # the statistics page's text: 0x40 default, 0x41 deck-out, 0x42 Exodia
const SELECTOR_DECK_OUT := 0x41
const SELECTOR_EXODIA := 0x42
const SPOILS_TEXT := 0x44
const SPECIAL_ARTS_TEXT := 0x45
const TEXT_ORIGIN := Vector2(26, 40)   # the text box creation(0, id, 0x1A, 0x28, 0x120, 0x120)
const STARCHIP_ORIGIN := Vector2(160, 192)
# the page-turn arrows (duel_result/arrow_left.png, arrow_right.png) of each page: SPOILS and SPECIAL ARTS have them at 14 and 290, the
# statistics page at 16 and 288 (measured on the reference frames)
const ARROW_AT := [[Vector2(14, 16), Vector2(290, 16)], [Vector2(16, 16), Vector2(288, 16)], [Vector2(14, 16), Vector2(290, 16)]]
const STARCHIP_STEP := 20
const DIM_LEVEL := 128                  # the rewards state's fade level (Fade_SetTargetLevel(128, 2)): the duel picture behind the pages
const DIM_STEP := 2                     # the level falls 2 a frame from full (255) to DIM_LEVEL
const LEAVE_STEP := 6                   # the leave fade (Fade_SetTargetLevel(0, 6)): the level falls 6 a frame to 0
const PAGES := 3
const SE_PAGE := 6
const SE_LEAVE := 0x30
const DIGIT_SJIS := 0x824F             # the Shift-JIS code of '0'; the digits follow it

# The outro's confetti (the data at 0x80090928 with a real opponent, the data at 0x80090960 without): per winning side, seven rows of [x, y, kind, tag]
# (kind 0 is no sprite; kind is the picture's variant in the display bank, the side its record). The tag is not used.
const CONFETTI_OPPONENT := [
	[[112, 68, 1, 20], [160, 68, 2, 20], [208, 68, 3, 20], [88, 124, 4, 20], [136, 124, 5, 8], [184, 124, 6, 20], [232, 124, 7, 8]],
	[[112, 68, 8, 20], [160, 68, 9, 20], [208, 68, 10, 20], [88, 124, 11, 20], [136, 124, 12, 8], [184, 124, 13, 20], [232, 124, 14, 8]],
]
const CONFETTI_NONE := [
	[[136, 68, 16, 12], [184, 68, 17, 20], [0, 0, 0, 20], [88, 124, 4, 20], [136, 124, 5, 8], [184, 124, 6, 20], [232, 124, 7, 8]],
	[[136, 68, 24, 12], [184, 68, 25, 20], [0, 0, 0, 20], [88, 124, 26, 20], [136, 124, 27, 8], [184, 124, 28, 20], [232, 124, 29, 8]],
]
const CONFETTI_RADIUS := 0x140          # the result outro update: the radius starts at 0x140 + (rand & 0x3F)
const CONFETTI_ORBIT_STEP := 0x30       # the orbit angle step, the angle (of 4096) a frame
const BgmPlayer := preload("res://scripts/system/bgm_player.gd")
var jingle_started := false
var jingle_heard := false         # the track has been heard playing (the hold ends when it stops)
const CONFETTI_HOLD := 0x258            # the outro's hold: 600 frames (see the header on the music)
const CONFETTI_FLY_FLOOR := 0xC0        # the routine at 0x80020EE8 releases a sprite once its brightness falls below this (2 a frame)
const TRAIL_BRIGHTNESS := 128           # a sprite's colour multiply (128 is 1.0); the trail is spawned at it (the slot's default colour)
const TRAIL_FADE_STEP := 8              # the trail's brightness falls by 8 a frame and is released at 0 (the slot's fade routine)
const ANGLE_FULL := 4096                # TRIG_ANGLE_FULL_TURN; ONE is 4096 too


# ---- the rank, starchips and drop (pure) ------------------------------------------------------------------------------------

## the rank score change: the change of the first threshold strictly above the value (rows[rule] is five [threshold, change]).
static func rank_change(rows: Array, rule: int, value: int) -> int:
	for pair in rows[rule]:
		if value < int(pair[0]):
			return int(pair[1])
	return 0


## One side's score as the rank score sum sums it: 50, the way the duel ended, and each counter's row change.
static func side_score(side: Dictionary, rows: Array) -> int:
	var score := RANK_SCORE_INITIAL + int(side.get("result_adjustment", 0))
	score += rank_change(rows, RULE_CARDS_USED, int(side.get("cards_used", 0)))
	score += rank_change(rows, RULE_REMAINING_LP, int(side.get("life_points", 0)))
	score += rank_change(rows, RULE_EFFECTIVE_ATTACKS, int(side.get("effective_attacks", 0)))
	score += rank_change(rows, RULE_DEFENSIVE_WINS, int(side.get("defensive_wins", 0)))
	score += rank_change(rows, RULE_FACE_DOWN_PLAYS, int(side.get("face_down_plays", 0)))
	score += rank_change(rows, RULE_INITIATE_FUSION, int(side.get("fusions_initiated", 0)))
	score += rank_change(rows, RULE_EQUIP_MAGIC, int(side.get("equips_used", 0)))
	score += rank_change(rows, RULE_PURE_MAGIC, int(side.get("pure_magic_used", 0)))
	score += rank_change(rows, RULE_TRAPS_TRIGGERED, int(side.get("traps_triggered", 0)))
	score += rank_change(rows, RULE_TURNS, int(side.get("turns_taken", 0)))
	return score


## The letter's axis and tier from a score (the result rewards update): below 50 is TEC and mirrored as 99 - score (from 0),
## 100 and up count as 99, and (score - 50) / 10 is the tier, 0 (D) to 4 (S).
static func grade(score: int) -> Dictionary:
	var tec := false
	var value := score
	if value < RANK_SCORE_INITIAL:
		tec = true
		if value < 0:
			value = 0
		value = 99 - value
	if value >= 100:
		value = 99
	var tier: int = (value - RANK_SCORE_INITIAL) / 10
	return {"tec": tec, "tier": tier, "letter": "%s-%s" % [LETTERS[tier], "TEC" if tec else "POW"]}


## the card drop selection's pool: a tier below 3 (B, C, D) draws from pool 1, otherwise S/A POW is 0 and S/A TEC is 2.
static func pool_index(tier: int, tec: bool) -> int:
	if tier < 3:
		return 1
	return 2 if tec else 0


## A drop pool as weights indexed by card id - 1 (722 entries), from duelists.json's name -> weight.
static func drop_weights(pool: Dictionary, names: Dictionary) -> Array:
	var weights: Array = []
	weights.resize(CARD_COUNT)
	weights.fill(0)
	for card_name in pool:
		var id := int(names.get(card_name, 0))
		if id >= 1 and id <= CARD_COUNT:
			weights[id - 1] = int(pool[card_name])
	return weights


## the card drop selection: one rand() gives the threshold (rand & 2047) + 1, and the first card whose running weight reaches it wins.
## Returns the card id, or 0 when the weights never reach the threshold.
static func select_drop(weights: Array, rng: PsxRand) -> int:
	var threshold := (rng.rand() & (DROP_WEIGHT_TOTAL - 1)) + 1
	var sum := 0
	for i in CARD_COUNT:
		sum += int(weights[i])
		if sum >= threshold:
			return i + 1
	return 0


## The starchip balance after a prize, capped as the save's counter is (the routine at 0x800218F0).
static func starchips_after(balance: int, prize: int) -> int:
	return mini(balance + prize, STARCHIP_MAX)


## The whole result from the stats (see the header). Only the winner's score matters for the prize and the drop. The prize and the
## drop are the player's, from a CPU duelist: winner 0 with opponent_id 0 or more (the data at 0x8009B360[0] < 0 and the opponent id >= 0).
## `duelist` is the opponent's entry of duelists.json, and `names` maps card names to ids (cards.json).
static func evaluate(stats: Dictionary, rows: Array, duelist: Dictionary, names: Dictionary, rng: PsxRand) -> Dictionary:
	var sides: Array = stats.get("sides", [])
	var winner := int(stats.get("winner", -1))
	var scores: Array = []
	for side in sides:
		scores.append(side_score(side, rows))
	var out := {"winner": winner, "scores": scores, "tec": false, "tier": 0, "letter": "", "rated": false, "starchips": 0,
			"pool": -1, "card": 0, "adjustment": 0}
	if winner < 0 or winner >= scores.size():
		return out
	out["adjustment"] = int(sides[winner].get("result_adjustment", 0))
	var graded := grade(int(scores[winner]))
	out["tec"] = graded["tec"]
	out["tier"] = graded["tier"]
	out["letter"] = graded["letter"]
	out["rated"] = winner == 0 and int(stats.get("opponent_id", -1)) >= 0
	if not out["rated"]:
		return out
	out["starchips"] = int(graded["tier"]) + 1
	out["pool"] = pool_index(int(graded["tier"]), bool(graded["tec"]))
	var drops: Dictionary = duelist.get("drops", {})
	var weights := drop_weights(drops.get(POOL_KEYS[int(out["pool"])], {}), names)
	out["card"] = select_drop(weights, rng)
	return out


# ---- the screen ---------------------------------------------------------------------------------------------------------

var stats: Dictionary = {}
var result: Dictionary = {}
var numbers: Dictionary = {}
var page := 0
var phase := "start"
var timer := 0
var level := 255                  # the picture's fade level (0 black, 255 the duel picture as it is): the backdrop dims it, the pages stay bright
var backdrop: ColorRect           # the duel picture's dimming layer, under the result's pictures
var held: Dictionary = {}
var ready_ok := false
var rows: Array = []
var layout: Dictionary = {}
var bank := PackedByteArray()
var digits: Array = []
var sharp: ShaderMaterial
var duelist_list: Array = []
var text := GameText.new()
var cards := CardDB.new()
var world := Node2D.new()
var pictures := Node2D.new()
var text_holder := Node2D.new()
var frame_sprite := Sprite2D.new()
var badge_sprite := Sprite2D.new()
var letter_sprite := Sprite2D.new()
var starchip_sprites: Array = []
var arrows: Array = []            # the page-turn arrows (left, right): drawn on every page, in the pictures node
var frames: Array = []
var badges: Array = []
var letters: Array = []
var confetti_holder := Node2D.new()
var confetti: Array = []          # the outro's sprites: {"node", "base", "pos", "radius", "angle", "orbiting"}
var confetti_textures: Dictionary = {}
var outro_step := 0               # 0 orbit, 1 hold, 2 fly away
var outro_timer := 0
var frame := 0
var fly_brightness := 255
var trails: Array = []            # {"node", "frames"}: the trail the orbiting sprites leave every other frame


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not text.load_all() or not cards.load_all() or not _load_art():
		return
	sharp = ScreenFit.make_material()
	for i in 10:
		digits.append(text.code_for_sjis(DIGIT_SJIS + i))
	var names := {}
	for card in cards.cards:
		names[str(card["name"])] = int(card["id"])
	var opponent := int(stats.get("opponent_id", -1))
	var duelist: Dictionary = {}
	if opponent >= 0 and opponent < _duelists().size():
		duelist = _duelists()[opponent]
	var rng := PsxRand.new(int(stats.get("seed", randi())))
	result = evaluate(stats, rows, duelist, names, rng)
	numbers = _numbers(stats.get("sides", []), int(result["card"]))
	_build_slots()
	_build_pictures()
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# the duel picture stays behind the result: the backdrop darkens it (the fade level, see _apply_level) and the pages sit on top
	backdrop = ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.0)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	add_child(world)
	add_to_group("fit")
	world.add_child(confetti_holder)
	world.add_child(pictures)
	world.add_child(text_holder)
	get_viewport().size_changed.connect(refit)
	refit()
	_show_page(0)
	ready_ok = true


func refit() -> void:
	ScreenFit.apply(world, size)


func _load_art() -> bool:
	layout = _read_json(DIR + "layout.json")
	rows = _read_json(RANK_PATH)
	if layout.is_empty() or rows.size() != 10:
		return false
	for p in PAGES:
		frames.append(_texture(DIR + "frame_%d.png" % p))
	for tec in 2:
		badges.append(_texture(DIR + "badge_%d.png" % tec))
	for tier in 5:
		letters.append(_texture(DIR + "letter_%d.png" % tier))
	bank = FileAccess.get_file_as_bytes(TEXT_BANK)
	return not bank.is_empty()


func _duelists() -> Array:
	if duelist_list.is_empty():
		duelist_list = _read_json(DUELISTS_PATH)
	return duelist_list


func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return []
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data != null else []


func _texture(path: String) -> Texture2D:
	return ModArt.texture(path)


## The statistics' numbers by RAM address (see NUMBER_ROWS), and the dropped card's number.
static func _numbers(sides: Array, card: int) -> Dictionary:
	var out := {}
	for i in mini(sides.size(), 2):
		for entry in NUMBER_ROWS:
			var key: String = entry[1]
			if sides[i].has(key):
				out[STAT_BASE + int(entry[0]) * 8 + i * 4] = int(sides[i][key])
	out[CARD_NUMBER] = card
	return out


## the text colour slots: slots 0 and 1 are the ramp 4, and the winner's slot is ramp 0.
func _build_slots() -> void:
	var slots: Array = []
	for k in 16:
		slots.append(0)
	slots[0] = 4
	slots[1] = 4
	var winner := int(result["winner"])
	if winner == 0 or winner == 1:
		slots[winner] = 0
	text.slots = slots


func _build_pictures() -> void:
	frame_sprite.centered = false
	frame_sprite.material = ScreenFit.make_material()
	pictures.add_child(frame_sprite)
	for sprite in [badge_sprite, letter_sprite]:
		sprite.centered = false
		sprite.material = ScreenFit.make_material()
		pictures.add_child(sprite)
	for side in 2:
		var arrow := Sprite2D.new()
		arrow.centered = false
		arrow.texture = _texture(DIR + ["arrow_left.png", "arrow_right.png"][side])
		arrow.material = ScreenFit.make_material()
		pictures.add_child(arrow)
		arrows.append(arrow)
	var tec := 1 if result["tec"] else 0
	badge_sprite.texture = badges[tec]
	badge_sprite.position = _at(layout["badge"][tec])
	letter_sprite.texture = letters[int(result["tier"])]
	letter_sprite.position = _at(layout["letter"][int(result["tier"])])
	var prize := int(result["starchips"])
	var picture: Texture2D = _texture(STARCHIP_PATH)
	for i in prize:
		var star := Sprite2D.new()
		star.centered = false
		star.texture = picture
		star.material = ScreenFit.make_material()
		star.position = STARCHIP_ORIGIN + Vector2(STARCHIP_STEP * i, 0) + _at(layout.get("starchip", {"x": 0, "y": 0}))
		pictures.add_child(star)
		starchip_sprites.append(star)


func _at(box: Dictionary) -> Vector2:
	return Vector2(float(box["x"]), float(box["y"]))


func _text_id(p: int) -> int:
	if p == 0:
		return SPOILS_TEXT
	if p == 1:
		# the statistics page's heading follows how the winner's duel ended (the Exodia win adjustment / _DECK_OUT_WIN)
		if int(result["adjustment"]) == 40:
			return SELECTOR_EXODIA
		if int(result["adjustment"]) == -40:
			return SELECTOR_DECK_OUT
		return SELECTOR_DEFAULT
	return SPECIAL_ARTS_TEXT


## Shows page `p`: its frame, the rank and starchips on SPOILS only, and its text.
func _show_page(p: int) -> void:
	page = p
	frame_sprite.texture = frames[p]
	frame_sprite.position = _at(layout["frame"][p])
	var on_spoils := p == 0
	for side in arrows.size():
		arrows[side].position = ARROW_AT[p][side]
	badge_sprite.visible = on_spoils and int(result["winner"]) == 0
	letter_sprite.visible = badge_sprite.visible
	for star in starchip_sprites:
		star.visible = on_spoils
	for child in text_holder.get_children():
		text_holder.remove_child(child)
		child.queue_free()
	# the jump selectors (game_text.gd F8 17 / F8 18): the reward step's RAM bytes 0x8009B34E and 0x8009B355. Both are 0 by default;
	# 0x8009B355 is 1 when side 1 won (the WINNER row reads YOU for side 0 and COM for side 1), and a two-player duel (no opponent) sets
	# 0x8009B34E to 1 and adds 2 to 0x8009B355. The card (F8 00 0x20, its name) is the dropped card, and the name (F8 09) is the
	# opponent's: the id 0x8328 + opponent (the reward step's halfword at 0x8009B32E)
	var two_player := int(stats.get("opponent_id", -1)) < 0
	var ctx := {"bank": bank, "numbers": numbers, "digits": digits, "flag_34e": 1 if two_player else 0,
			"flag_355": int(result["winner"]) + (2 if two_player else 0), "card": int(result["card"]),
			"name_id": 0x8328 + int(stats.get("opponent_id", 0))}
	text.layout(text_holder, text.string_bytes(_text_id(p)), TEXT_ORIGIN, Vector2(8, 12), 0, sharp, true, {}, ctx)


func _physics_process(_delta: float) -> void:
	if not ready_ok:
		return
	timer += 1
	frame += 1
	_update_trails()
	match phase:
		"start":
			_start_outro()
		"outro":
			_run_outro()
		"dim":
			# the rewards state's fade: the duel picture goes from full level to DIM_LEVEL, DIM_STEP a frame, while the pages open
			level = maxi(255 - DIM_STEP * timer, DIM_LEVEL)
			if level <= DIM_LEVEL:
				_enter("page")
		"page":
			if _edge("right", [KEY_D, KEY_RIGHT]):
				_show_page((page + 1) % PAGES)
				sound.emit(SE_PAGE)
			elif _edge("left", [KEY_A, KEY_LEFT]):
				_show_page((page + PAGES - 1) % PAGES)
				sound.emit(SE_PAGE)
			elif _edge("confirm", [KEY_E, KEY_SPACE]):
				sound.emit(SE_LEAVE)
				_enter("fade_out")
		"fade_out":
			# the leave fade: the level falls LEAVE_STEP a frame to 0 (the pages fade with the picture), then the screen is done
			level = maxi(DIM_LEVEL - LEAVE_STEP * timer, 0)
			if level <= 0:
				_enter("done")
				finished.emit()
	_apply_level()


## The picture's level: the backdrop darkens the duel picture to level / 255 (black at 0), and the result's pictures fade with it
## only below DIM_LEVEL (they stay bright while the picture is dimmed to DIM_LEVEL).
func _apply_level() -> void:
	if backdrop != null:
		backdrop.color.a = 1.0 - float(level) / 255.0
	world.modulate.a = clampf(float(level) / float(DIM_LEVEL), 0.0, 1.0)


## the result outro update's spawn (state 2): the winning side's row of confetti, each on its own orbit from its row point. The
## pages stay hidden until the outro has finished.
func _start_outro() -> void:
	_enter("outro")
	# the result jingle (duel_result_runtime): 0x72F0 when the winner side is not 0 and the opponent is a real one, else 0x72E0
	var jingle := 0x72E0
	if int(result.get("winner", 0)) != 0 and int(stats.get("opponent_id", -1)) >= 0:
		jingle = 0x72F0
	jingle_started = true
	music.emit(jingle)
	# the outro's first step sets its two banner objects: the FIELD box goes to x -116 and the life-point
	# panel to 408, each on the cosine routine with a step of 0x800 / 0x30 (49 frames, no snap at the end)
	panels.emit(-116, 408, 0x30)
	pictures.visible = false
	text_holder.visible = false
	var side := clampi(int(result.get("winner", 0)), 0, 1)
	var rows: Array = CONFETTI_OPPONENT if int(stats.get("opponent_id", -1)) >= 0 else CONFETTI_NONE
	for row in rows[side]:
		var kind: int = row[2]
		if kind == 0:
			continue
		var node := Sprite2D.new()
		node.centered = false
		node.texture = _confetti_texture(side, kind)
		node.material = ScreenFit.make_material()
		confetti_holder.add_child(node)
		var base := Vector2(row[0], row[1])
		var sprite := {"node": node, "side": side, "kind": kind, "base": base, "pos": base,
				"radius": CONFETTI_RADIUS + (randi() & 0x3F), "angle": randi() % ANGLE_FULL, "orbiting": true}
		confetti.append(sprite)
		_place(sprite)
	outro_step = 0
	outro_timer = 0


func _run_outro() -> void:
	outro_timer += 1
	match outro_step:
		0:
			# the original's update orbit sprite routine runs until every sprite's radius has decayed
			var moving := false
			for c in confetti:
				if c["orbiting"]:
					_orbit(c)
					moving = true
			if not moving:
				outro_step = 1
				outro_timer = 0
		1:
			# hold, then a press or the end of the hold sends the sprites away (the game also waits for the track to end)
			if BgmPlayer.playing:
				jingle_heard = true
			if outro_timer >= CONFETTI_HOLD or _edge("confirm", [KEY_E, KEY_SPACE]) or (jingle_heard and not BgmPlayer.playing):
				outro_step = 2
				fly_brightness = 255
				for c in confetti:
					c["orbiting"] = false
		2:
			# the routine at 0x80020EE8: the brightness falls by 2 a frame and the sprite is released below 0xC0
			fly_brightness -= 2
			for c in confetti:
				c["node"].modulate.a = float(fly_brightness) / 255.0
			if fly_brightness < CONFETTI_FLY_FLOOR:
				_finish_outro()


func _finish_outro() -> void:
	for c in confetti:
		c["node"].queue_free()
	confetti.clear()
	pictures.visible = true
	text_holder.visible = true
	_enter("dim")


## One frame of the original's update orbit sprite routine: the radius decays by 2, and it ends (back at its base) at 0. On odd frames a trail is
## left at the current point; the angle moves by the orbit step and the point follows base + (cos, sin) * radius / ONE.
func _orbit(c: Dictionary) -> void:
	c["radius"] = int(c["radius"]) - 2
	if int(c["radius"]) <= 0:
		c["orbiting"] = false
		c["pos"] = c["base"]
		_place(c)
		return
	if (frame & 1) == 1:
		_spawn_trail(c)
	c["angle"] = (int(c["angle"]) + CONFETTI_ORBIT_STEP) & 0xFFFF
	var a := int(c["angle"]) & (ANGLE_FULL - 1)
	var r := int(c["radius"])
	c["pos"] = Vector2(c["base"]) + Vector2((_cos4096(a) * r) / ANGLE_FULL, (_sin4096(a) * r) / ANGLE_FULL)
	_place(c)


func _place(c: Dictionary) -> void:
	c["node"].position = c["pos"] + _confetti_offset(int(c["side"]), int(c["kind"]))


## A trail is the same sprite on the palette block with the semi-transparent bit (additive, see the bake), spawned at the
## sprite's current point with the default brightness; its brightness falls each frame and it is released when that reaches 0.
func _spawn_trail(c: Dictionary) -> void:
	var node := Sprite2D.new()
	node.centered = false
	node.texture = _trail_texture(int(c["side"]), int(c["kind"]))
	node.material = ScreenFit.make_material(true)
	node.position = c["pos"] + _confetti_offset(int(c["side"]), int(c["kind"]))
	confetti_holder.add_child(node)
	confetti_holder.move_child(node, 0)      # the trails are drawn under the sprites that leave them
	trails.append({"node": node, "frames": 0})


## The trail's brightness after `frames` frames (the colour multiply, 128 is full).
static func trail_brightness(frames: int) -> int:
	return TRAIL_BRIGHTNESS - TRAIL_FADE_STEP * frames


func _update_trails() -> void:
	var i := trails.size() - 1
	while i >= 0:
		var t: Dictionary = trails[i]
		t["frames"] = int(t["frames"]) + 1
		var node: Sprite2D = t["node"]
		var brightness := trail_brightness(int(t["frames"]))
		if brightness <= 0:
			node.queue_free()
			trails.remove_at(i)
		else:
			var k := float(brightness) / float(TRAIL_BRIGHTNESS)
			node.modulate = Color(k, k, k, 1.0)
		i -= 1


func _confetti_texture(side: int, kind: int) -> Texture2D:
	var key := side * 100 + kind
	if not confetti_textures.has(key):
		var path := DIR + "confetti_%d_%d.png" % [side, kind]
		confetti_textures[key] = _texture(path) if FileAccess.file_exists(path) else null
	return confetti_textures[key]


## The trail picture (confetti_<side>_<kind>_trail.png); the body's picture stands in when it has not been baked.
func _trail_texture(side: int, kind: int) -> Texture2D:
	var key := 10000 + side * 100 + kind
	if not confetti_textures.has(key):
		var path := DIR + "confetti_%d_%d_trail.png" % [side, kind]
		confetti_textures[key] = _texture(path) if FileAccess.file_exists(path) else _confetti_texture(side, kind)
	return confetti_textures[key]


## Where a baked confetti picture is drawn from its spawn point (layout.json's confetti box, the picture's own offset).
func _confetti_offset(side: int, kind: int) -> Vector2:
	var rows: Array = layout.get("confetti", [])
	# a kind with no box in the layout (null) has no offset
	if side >= 0 and side < rows.size() and kind >= 1 and kind - 1 < rows[side].size() and rows[side][kind - 1] is Dictionary:
		return _at(rows[side][kind - 1])
	return Vector2.ZERO


## The PSX rcos and rsin (a full turn is 4096 units, the values are times 4096).
func _cos4096(a: int) -> int:
	return int(cos(float(a) * TAU / float(ANGLE_FULL)) * float(ANGLE_FULL))


func _sin4096(a: int) -> int:
	return int(sin(float(a) * TAU / float(ANGLE_FULL)) * float(ANGLE_FULL))


func _enter(next_phase: String) -> void:
	phase = next_phase
	timer = 0


func _down(keys: Array) -> bool:
	for key in keys:
		if Input.is_key_pressed(key):
			return true
	# a click or tap on the game (not on an on-screen control) confirms like the confirm keys
	return KEY_E in keys and TouchControls.game_pointer_held()


func _edge(action: String, keys: Array) -> bool:
	var now := _down(keys)
	var was: bool = held.get(action, false)
	held[action] = now
	return now and not was
