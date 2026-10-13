extends RefCounted
## One exported background track: assets/audio/bgm/<key>/ holds seq.bin (the sequence chunk), tones.json (the VAB header's
## master volume and pan, and the programs with their tones) and samples/vag_NNN.wav (the decoded VAG bodies, 16-bit mono,
## 44100 Hz). The folder key is the id's low 12 bits in three hex digits (see docs/bgm-format.md). Samples are read when a
## note first needs them and kept.

const BgmVoices := preload("res://scripts/system/bgm_voices.gd")

const ROOT := "res://assets/audio/bgm/"

var key := -1
var dir := ""
var seq: PackedByteArray = PackedByteArray()
var master_volume := 127
var bank_volume := 210           # the bank's volume (SD_BGM.DAT's VolInfo block; the driver's 0xD2 when the block is missing)
var master_pan := 64
var _programs: Dictionary = {}
var _samples: Dictionary = {}
var _sample_info: Dictionary = {}     # VAG number (as a string key) -> the export's metadata for it


## The folder of track id `id` (the game's 16-bit id; only its low 12 bits pick the data).
static func folder_for(id: int) -> String:
	return ROOT + "%03X/" % (id & 0xFFF)


## Load the track for id. Returns null when the folder or its sequence is missing (the caller then plays nothing).
static func open(id: int):
	var track := preload("res://scripts/system/bgm_track.gd").new()
	if not track.load_from(folder_for(id), id & 0xFFF):
		return null
	return track


func load_from(folder: String, track_key: int) -> bool:
	key = track_key
	dir = folder
	if not FileAccess.file_exists(dir + "seq.bin"):
		return false
	seq = FileAccess.get_file_as_bytes(dir + "seq.bin")
	if seq.size() < 16:
		return false
	var parsed = null
	if FileAccess.file_exists(dir + "tones.json"):
		parsed = JSON.parse_string(FileAccess.get_file_as_string(dir + "tones.json"))
	if typeof(parsed) == TYPE_DICTIONARY:
		_read_header(parsed)
	return true


func _read_header(root: Dictionary) -> void:
	# The export carries no VAB master volume or pan; the defaults (127 and centre) are used unless it gains them.
	master_volume = int(_pick(root, ["master_volume", "mvol", "vab_master_volume"], 127))
	bank_volume = int(_pick(root, ["bank_volume"], 210))
	master_pan = int(_pick(root, ["master_pan", "mpan", "vab_master_pan"], 64))
	var samples = _pick(root, ["samples"], {})
	if typeof(samples) == TYPE_DICTIONARY:
		_sample_info = samples
	var programs = _pick(root, ["programs"], [])
	var entries: Array = []
	if typeof(programs) == TYPE_ARRAY:
		entries = programs
	elif typeof(programs) == TYPE_DICTIONARY:
		for k in programs:
			var e: Dictionary = programs[k]
			e = e.duplicate()
			if not e.has("program"):
				e["program"] = int(k)
			entries.append(e)
	for entry in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var prog_no := int(_pick(entry, ["program", "index", "id"], -1))
		if prog_no < 0:
			continue
		var tones_out: Array = []
		var tones = _pick(entry, ["tones"], [])
		if typeof(tones) == TYPE_ARRAY:
			for t in tones:
				if typeof(t) == TYPE_DICTIONARY:
					tones_out.append(_tone(t))
		_programs[prog_no] = {
			"mvol": int(_pick(entry, ["volume", "mvol", "program_volume"], 127)),
			"mpan": int(_pick(entry, ["pan", "mpan", "program_pan"], 64)),
			"tones": tones_out,
		}


func _tone(t: Dictionary) -> Dictionary:
	var lo := int(_pick(t, ["min", "key_min"], 0))
	var hi := int(_pick(t, ["max", "key_max"], 127))
	return {
		"min": lo,
		"max": hi,
		"vol": int(_pick(t, ["volume", "vol"], 127)),
		"pan": int(_pick(t, ["pan"], 64)),
		"center": int(_pick(t, ["center", "centre", "note"], 60)),
		"shift": int(_pick(t, ["shift", "fine"], 0)) & 0xFF,
		"pbmin": int(_pick(t, ["pitch_bend_min", "pbmin"], 0)),
		"pbmax": int(_pick(t, ["pitch_bend_max", "pbmax"], 0)),
		"adsr1": int(_pick(t, ["adsr1"], 0)) & 0xFFFF,
		"adsr2": int(_pick(t, ["adsr2"], 0)) & 0xFFFF,
		"vag": int(_pick(t, ["vag", "vag_number"], 0)),
	}


## The program's record ({mvol, mpan, tones}), or null when the track has no such program or it has no tones.
func program(prog_no: int):
	if not _programs.has(prog_no):
		return null
	var p: Dictionary = _programs[prog_no]
	if p["tones"].is_empty():
		return null
	return p


## The sample for VAG number `vag`: {data: PackedFloat32Array, loop_on, loop_start, loop_end}. Missing samples are empty.
func sample(vag: int) -> Dictionary:
	if _samples.has(vag):
		return _samples[vag]
	var result := {"data": PackedFloat32Array(), "loop_on": false, "loop_start": 0, "loop_end": 0}
	var path := dir + "samples/vag_%03d.wav" % vag
	if FileAccess.file_exists(path):
		result = _read_wav(FileAccess.get_file_as_bytes(path))
		var info = _sample_info.get(str(vag), {})
		if typeof(info) == TYPE_DICTIONARY and info.get("loop_start") != null and info.get("loop_end") != null:
			result["loop_on"] = true
			result["loop_start"] = int(info["loop_start"])
			result["loop_end"] = int(info["loop_end"])
		result["data"] = BgmVoices.pad_sample(result["data"], result["loop_on"], result["loop_start"])
	_samples[vag] = result
	return result


## Parse a 16-bit PCM WAV: the sample data, and the loop points of a 'smpl' chunk when it has one.
static func _read_wav(bytes: PackedByteArray) -> Dictionary:
	var result := {"data": PackedFloat32Array(), "loop_on": false, "loop_start": 0, "loop_end": 0}
	if bytes.size() < 12 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF":
		return result
	var pos := 12
	var data_at := -1
	var data_len := 0
	var channels := 1
	var bits := 16
	var loop_start := -1
	var loop_end := -1
	while pos + 8 <= bytes.size():
		var id := bytes.slice(pos, pos + 4).get_string_from_ascii()
		var size := bytes.decode_u32(pos + 4)
		var body := pos + 8
		if id == "fmt ":
			channels = bytes.decode_u16(body + 2)
			bits = bytes.decode_u16(body + 14)
		elif id == "data":
			data_at = body
			data_len = mini(size, bytes.size() - body)
		elif id == "smpl" and body + 36 + 24 <= bytes.size():
			if bytes.decode_u32(body + 28) > 0:
				loop_start = bytes.decode_u32(body + 36 + 8)
				loop_end = bytes.decode_u32(body + 36 + 12)
		pos = body + size + (size & 1)
	if data_at < 0 or bits != 16:
		return result
	var frames := data_len / (2 * channels)
	var out := PackedFloat32Array()
	out.resize(frames)
	for i in frames:
		out[i] = float(bytes.decode_s16(data_at + i * 2 * channels)) / 32768.0
	result["data"] = out
	if loop_start >= 0 and loop_end > loop_start and loop_end <= frames:
		result["loop_on"] = true
		result["loop_start"] = loop_start
		result["loop_end"] = loop_end
	return result


static func _pick(d: Dictionary, names: Array, default):
	for n in names:
		if d.has(n):
			return d[n]
	return default
