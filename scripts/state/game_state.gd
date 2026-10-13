extends RefCounted
## What a campaign remembers while the game runs: the player's name (six Shift-JIS words), the story flags (the save block's
## flag bytes at 0x618, bit 0x80 >> (flag & 7) of byte flag >> 3), the deck, the owned card counts, the starchips, the duel
## records, the recent card drops and the map place. The save file stands in for the memory card (save_game / load_game).

const CARD_COUNT := 722
const DUELIST_COUNT := 40                 # the grid entry count: the duelist records, cell 0 (the deck) unused
const RECENT_DROP_COUNT := 16             # the recent card drop count, newest first at save +0x5BC
const CARD_CHEST_QUANTITY_MAX := 250      # CARD_CHEST_QUANTITY_MAX: the card award's copy limit
const STARCHIP_MAX := 999999              # SAVE_DATA_STARCHIP_MAX
const TWO_PLAYER_RECORD_MAX := 9999       # the two-player record cap (duel_wins / duel_losses)
const FREE_DUEL_RECORD_MAX := 999         # the Free Duel record cap: a duelist's wins or losses
const CARD_SEEN_FLAG_BASE := 0x120        # the library card flag base: a card's library flag is base + id
const CAMPAIGN_FLAG_CLEAR := 0x8000       # the clear modifier: an update that clears the bit
const CREDITS_FLAG_BITS := 3              # field_3DE |= 3 when the ending starts (the credits run)
const CREDITS_FLAG_FIRST := 0x20          # the credits run clears the flags 0x20 .. 0x11F
const CREDITS_FLAG_END := 0x120
const NEW_GAME_SCENE := 0x30              # gCampaignSceneIndex on a new game and after the credits

static var player_name: Array = [0, 0, 0, 0, 0, 0]
static var flags := PackedByteArray()
static var deck: Array = []        # the player's 40 card ids (the starter deck dealt when a name is entered)
static var card_counts := PackedInt32Array()   # the copies the player owns of card n+1 at index n, the chest and the deck together;
                                              # empty until owned_counts() makes it (the deck's copies, as the first owned)
static var starchips := 0          # the starchip balance (SaveDataState.starchips, capped at STARCHIP_MAX)
static var duel_wins := 0          # SaveDataState.duel_wins (+0x518): two-player duels only
static var duel_losses := 0        # SaveDataState.duel_losses (+0x51A): two-player duels only
static var duelist_records := PackedInt32Array()  # per duelist cell: [wins, losses] at +0x51C (the Free Duel record line)
static var recent_drops := PackedInt32Array()     # the last 16 card ids awarded, newest first (+0x5BC)
static var output_type := 0        # the sound output type (saved): 0 stereo, 1 mono, chosen on the options screen
static var duelist_code := 0       # SaveDataState.duelist_code (+0x334): the secret number's key
static var campaign_scene_index := NEW_GAME_SCENE  # SaveDataState.campaign_scene_index (+0x5DC)
static var credits_flags := 0      # SaveDataState.field_3DE (+0x3DE): the ending's bits


static func reset() -> void:
	player_name = [0, 0, 0, 0, 0, 0]
	deck = []
	card_counts = PackedInt32Array()
	flags = PackedByteArray()
	flags.resize(256)
	starchips = 0
	duel_wins = 0
	duel_losses = 0
	duelist_records = PackedInt32Array()
	duelist_records.resize(DUELIST_COUNT * 2)
	recent_drops = PackedInt32Array()
	recent_drops.resize(RECENT_DROP_COUNT)
	duelist_code = 0
	output_type = 0
	campaign_scene_index = NEW_GAME_SCENE
	credits_flags = 0


## the name entry main routine's duelist code: the name's bytes XORed together in the low byte, a random byte above them, never zero.
## `words` is the name's six Shift-JIS words (each stored high byte first, as the save holds them); the random source is the caller's.
static func roll_duelist_code(words: Array, rng: RandomNumberGenerator) -> int:
	var checksum := 0
	for w in words:
		checksum ^= (int(w) >> 8) & 0xFF
		checksum ^= int(w) & 0xFF
	var value := (rng.randi() & 0xFF) << 8
	while (value | checksum) == 0:
		value = (rng.randi() & 0xFF) << 8
	return value | checksum


## The owned copies of each card (722 entries). With no save yet, a card is owned as often as the deck holds it.
static func owned_counts() -> PackedInt32Array:
	if card_counts.size() != CARD_COUNT:
		card_counts = PackedInt32Array()
		card_counts.resize(CARD_COUNT)
		for id in deck:
			if int(id) >= 1 and int(id) <= CARD_COUNT:
				card_counts[int(id) - 1] += 1
	return card_counts


static func test_flag(command: int) -> bool:
	if flags.is_empty():
		flags.resize(256)
	var id := command & 0x7FF
	var set_bit := (flags[id >> 3] & (0x80 >> (id & 7))) != 0
	return not set_bit if (command & 0x8000) != 0 else set_bit


static func write_flag(command: int) -> void:
	if flags.is_empty():
		flags.resize(256)
	var id := command & 0x7FF
	if (command & 0x8000) != 0:
		flags[id >> 3] &= ~(0x80 >> (id & 7))
	else:
		flags[id >> 3] |= 0x80 >> (id & 7)


# ---- duel results (the routine at 0x800218F0, the card award, the Free Duel record) ----------------------------------------------------

## the card award: one more copy of the card (250 at most) and the card goes to the front of the recent drops.
static func award_card(card_id: int) -> void:
	if card_id < 1 or card_id > CARD_COUNT:
		return
	owned_counts()
	var copies := card_counts[card_id - 1] + 1
	if copies >= CARD_CHEST_QUANTITY_MAX + 1:
		copies = CARD_CHEST_QUANTITY_MAX
	card_counts[card_id - 1] = copies
	if recent_drops.size() != RECENT_DROP_COUNT:
		recent_drops = PackedInt32Array()
		recent_drops.resize(RECENT_DROP_COUNT)
	for i in range(RECENT_DROP_COUNT - 1, 0, -1):
		recent_drops[i] = recent_drops[i - 1]
	recent_drops[0] = card_id


## The library's seen mark for a card (the card used flag update with base + id).
static func mark_card_seen(card_id: int) -> void:
	if card_id >= 1 and card_id <= CARD_COUNT:
		write_flag(CARD_SEEN_FLAG_BASE + card_id)


static func is_card_seen(card_id: int) -> bool:
	return card_id >= 1 and card_id <= CARD_COUNT and test_flag(CARD_SEEN_FLAG_BASE + card_id)


## the owned card marking: every card the player owns (chest or deck) gets its seen mark.
static func mark_library_owned() -> void:
	var counts := owned_counts()
	for i in CARD_COUNT:
		if counts[i] != 0:
			mark_card_seen(i + 1)


## The result of a single-player duel against a CPU duelist (the routine at 0x800218F0's starchip branch): only a win pays out, the prize is
## added to the starchips (capped) and the card is awarded. `result` is DuelResult.evaluate's dictionary; `seen` lists the cards the
## player used in the duel (the routine at 0x80019CC8). A duel that is not rated changes nothing here.
static func apply_cpu_duel(result: Dictionary, seen: Array = []) -> void:
	for id in seen:
		mark_card_seen(int(id))
	if not bool(result.get("rated", false)) or int(result.get("winner", -1)) != 0:
		return
	starchips = mini(starchips + int(result.get("starchips", 0)), STARCHIP_MAX)
	var card := int(result.get("card", 0))
	if card >= 1:
		award_card(card)


## The Free Duel record line (the Free Duel screen update after a duel started from the grid): the duelist's wins when the player won,
## its losses otherwise, 999 at most.
static func record_duel(cell: int, player_won: bool) -> void:
	if cell < 1 or cell >= DUELIST_COUNT:
		return
	if duelist_records.size() != DUELIST_COUNT * 2:
		duelist_records = PackedInt32Array()
		duelist_records.resize(DUELIST_COUNT * 2)
	var at := cell * 2 + (0 if player_won else 1)
	duelist_records[at] = mini(duelist_records[at] + 1, FREE_DUEL_RECORD_MAX)


## The two-player branch of the routine at 0x800218F0: the winner's duel_wins and the loser's duel_losses, 9999 at most. No two-player duel
## is built yet, so nothing calls this.
static func record_two_player_duel(winner: int) -> void:
	if winner == 0:
		duel_wins = mini(duel_wins + 1, TWO_PLAYER_RECORD_MAX)
	else:
		duel_losses = mini(duel_losses + 1, TWO_PLAYER_RECORD_MAX)


## the credits run' completion, at the start of the ending: the campaign index parks at 0x30, the flags 0x20 .. 0x11F are cleared
## (the card used flag update with the clear modifier), and field_3DE takes its two low bits.
static func complete_campaign() -> void:
	campaign_scene_index = NEW_GAME_SCENE
	for flag in range(CREDITS_FLAG_FIRST, CREDITS_FLAG_END):
		write_flag(flag | CAMPAIGN_FLAG_CLEAR)
	credits_flags |= CREDITS_FLAG_BITS


const SAVE_PATH := "user://save.json"
static var map_place := 14        # the campaign map place the story last left the player at


static func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


## The campaign state as the memory card holds it: the name, story flags, deck, owned card counts, the map place, the starchips, the
## duel records, the recent drops, the duelist code, the campaign scene index and the credits bits.
static func save_game() -> bool:
	return save_to(SAVE_PATH)


## The same save written to another file: the second memory card's copy (the second card screen's COPY THIS SAVE).
static func save_to(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({
		"name": player_name, "flags": Array(flags), "deck": deck, "counts": Array(owned_counts()), "place": map_place,
		"starchips": starchips, "wins": duel_wins, "losses": duel_losses, "records": Array(duelist_records),
		"drops": Array(recent_drops), "code": duelist_code, "scene": campaign_scene_index, "credits": credits_flags,
		"output": output_type}))
	return true


static func load_game() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var data = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		return false
	player_name = data.get("name", [0, 0, 0, 0, 0, 0])
	flags = PackedByteArray(data.get("flags", []))
	flags.resize(256)
	deck = data.get("deck", [])
	card_counts = PackedInt32Array(data.get("counts", []))
	map_place = int(data.get("place", 14))
	starchips = mini(int(data.get("starchips", 0)), STARCHIP_MAX)
	duel_wins = int(data.get("wins", 0))
	duel_losses = int(data.get("losses", 0))
	duelist_records = PackedInt32Array(data.get("records", []))
	duelist_records.resize(DUELIST_COUNT * 2)
	recent_drops = PackedInt32Array(data.get("drops", []))
	recent_drops.resize(RECENT_DROP_COUNT)
	duelist_code = int(data.get("code", 0))
	campaign_scene_index = int(data.get("scene", NEW_GAME_SCENE))
	credits_flags = int(data.get("credits", 0))
	output_type = clampi(int(data.get("output", 0)), 0, 1)
	return true


## True once a name has been entered (a campaign exists to continue).
static func has_campaign() -> bool:
	for word in player_name:
		if int(word) != 0:
			return true
	return false
