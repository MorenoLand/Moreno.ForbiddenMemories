extends RefCounted
## Card data read from assets/data/cards.json (written by tools/cards.py from the player's own disc).

const ModArt := preload("res://scripts/system/mod_art.gd")
const PATH := "res://assets/data/cards.json"
const ART_DIR := "res://assets/images/card_art/"
const THUMB_DIR := "res://assets/images/thumbnails/"

var cards: Array = []


static var _cache: Array = []


func load_all() -> bool:
	if _cache.is_empty():
		if not FileAccess.file_exists(PATH):
			return false
		var data = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if typeof(data) != TYPE_ARRAY:
			return false
		_cache = data
	cards = _cache
	return not cards.is_empty()


func card(id: int) -> Dictionary:
	return cards[id - 1] if id >= 1 and id <= cards.size() else {}


## {"texture", "scale"}: the card's picture, and how many times its baked size a mod's replacement is (see mod_art.gd).
func art(id: int) -> Dictionary:
	return ModArt.load_art(ART_DIR + "%03d.png" % id)


## {"texture", "scale"} of the card's small picture.
func thumbnail(id: int) -> Dictionary:
	return ModArt.load_art(thumbnail_path(id))


## The path of the card's small picture under res://assets/ (the face of a card is composed from it at its baked size).
func thumbnail_path(id: int) -> String:
	return THUMB_DIR + "%03d.png" % id
