extends RefCounted
## Images a mod may replace (tools/extract.py --mod). A replaced image is the mod's PNG under the baked image's name; how many
## times the baked size that PNG is sits in assets/mod_scales.json, keyed by the path under assets/ ("images/card_art/001.png").
## A picture without a scale is 1, so a vanilla extraction (no sidecar) is drawn exactly as before.
##
## HD art (mods/auto-hd, written by tools/extract.py --hd N): a mirror of assets/ with the pictures scaled up (Scale2x, once or twice).
## A picture of the mirror is used where the baked picture is not replaced by a texture pack. The texture of a picture always reports
## its BAKED size through get_size() (the HD pixels are kept, the size is overridden), so every consumer that lays a picture out, reads
## its size or draws it whole is the same with the HD art on or off. Only a consumer that reads pixels or regions must choose: it uses
## base_image() or plain_texture() (the baked 1x pixels), never the HD copy. The switch is the "hd_art" setting (the settings menu, F9;
## default on). A web export leaves mods/auto-hd out, so the browser keeps the baked pictures.

const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const PREFIX := "res://assets/"
const SCALES := "res://assets/mod_scales.json"
const HD_DIR := "res://mods/auto-hd/"
const HD_SCALES := "res://mods/auto-hd/scales.json"
const HD_MOD := "res://mods/auto-hd/mod.json"

static var _scales: Dictionary = {}
static var _read := false
static var _hd: Dictionary = {}
static var _hd_read := false


## {"texture": Texture2D or null, "scale": 1.0} for an image under res://assets/. The texture's get_size() is the baked size (see the
## header); "scale" stays 1.0, so apply() draws it at that size. Callers that multiplied by an old scale now read the baked size directly.
static func load_art(path: String) -> Dictionary:
	return {"texture": texture(path), "scale": 1.0}


## A picture under res://assets/ as a texture of its baked size: the HD copy when the mod has one, else the baked picture (or the
## texture pack's replacement). The pixels may be larger than the size; regions must not be taken from it (use plain_texture()).
## Null when there is no such picture.
static func texture(path: String) -> Texture2D:
	var rel := _rel(path)
	var hd := _hd_entry(rel)
	var file := path
	var size_scale := scale_of(path)
	if not hd.is_empty() and size_scale == 1.0:
		file = HD_DIR + "assets/" + rel
		size_scale = float(hd["scale"])
	if not FileAccess.file_exists(file):
		return null
	var image := Image.load_from_file(file)
	if image == null:
		return null
	var out := ImageTexture.create_from_image(image)
	if size_scale != 1.0:
		out.set_size_override(Vector2i(roundi(image.get_width() / size_scale), roundi(image.get_height() / size_scale)))
	return out


## The picture at its baked (1x) size as an image: the baked file, or a texture pack's replacement scaled down to it. Never the HD copy:
## a picture composed pixel by pixel (the duel's card face) lands on the same pixels with the HD art on or off.
static func base_image(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null:
		return null
	var scale := scale_of(path)
	if scale != 1.0:
		image.resize(roundi(image.get_width() / scale), roundi(image.get_height() / scale), Image.INTERPOLATE_NEAREST)
	return image


## The baked (1x) picture as a texture whose pixels are the baked size, for the consumers that take regions of it (the story's panels).
static func plain_texture(path: String) -> Texture2D:
	var image := base_image(path)
	return ImageTexture.create_from_image(image) if image != null else null


static func scale_of(path: String) -> float:
	_load_scales()
	return float(_scales.get(_rel(path), 1.0))


## Shows an art record on a sprite at its baked size: the texture, drawn 1/scale times its own size.
static func apply(sprite: Sprite2D, art: Dictionary) -> void:
	sprite.texture = art["texture"]
	var scale: float = art["scale"]
	sprite.scale = Vector2.ONE / scale


static func _rel(path: String) -> String:
	return path.trim_prefix(PREFIX)


## The HD copy of a picture ({"scale", "width", "height"} of the baked picture), or {} when the mod has none or the setting is off.
static func _hd_entry(rel: String) -> Dictionary:
	if not _hd_enabled():
		return {}
	if not _hd_read:
		_hd_read = true
		# tools/extract.py --mod-off auto-hd sets "enabled" false in the mod's manifest: the mirror is then not read
		var manifest = JSON.parse_string(FileAccess.get_file_as_string(HD_MOD)) if FileAccess.file_exists(HD_MOD) else null
		if typeof(manifest) == TYPE_DICTIONARY and manifest.get("enabled", true) == false:
			return {}
		if FileAccess.file_exists(HD_SCALES):
			var data = JSON.parse_string(FileAccess.get_file_as_string(HD_SCALES))
			if typeof(data) == TYPE_DICTIONARY:
				_hd = data
	var entry = _hd.get(rel, {})
	return entry if typeof(entry) == TYPE_DICTIONARY else {}


static func _hd_enabled() -> bool:
	return bool(ScreenFit.load_setting("hd_art", true))


static func _load_scales() -> void:
	if _read:
		return
	_read = true
	if FileAccess.file_exists(SCALES):
		var data = JSON.parse_string(FileAccess.get_file_as_string(SCALES))
		if typeof(data) == TYPE_DICTIONARY:
			_scales = data
