extends RefCounted
## Reads the user's own disc image (BIN, MODE2/2352) at runtime: sectors by LBA and ISO9660 file lookup.

const RAW := 2352
const USER_OFFSET := 24
const USER := 2048

var file: FileAccess
var sectors := 0
var _cache: Dictionary = {}
var folder := ""
var _files: Array = []        # folder mode: {lba, sectors, raw, path} sorted by lba
var _handles: Dictionary = {}


## A folder of the disc's files plus layout.json, as the extract() helper in tools/extract.py writes it (not run by the command line).
static func open_folder(path: String) -> RefCounted:
	var image = load("res://scripts/runner/disc.gd").new()
	var layout = JSON.parse_string(FileAccess.get_file_as_string(path.path_join("layout.json")))
	if typeof(layout) != TYPE_DICTIONARY:
		return null
	image.folder = path
	image.sectors = int(layout["sectors"])
	for entry in layout["files"]:
		image._files.append({"lba": int(entry["lba"]), "sectors": int(entry["sectors"]), "raw": bool(entry["raw"]), "path": path.path_join(entry["name"])})
	image._files.sort_custom(func(a, b): return a["lba"] < b["lba"])
	return image


static func open_image(path: String) -> RefCounted:
	if DirAccess.dir_exists_absolute(path):
		return open_folder(path)
	var image = load("res://scripts/runner/disc.gd").new()
	var bin := path
	if path.get_extension().to_lower() == "cue":
		var text := FileAccess.get_file_as_string(path)
		var start := text.find("\"")
		var end := text.find("\"", start + 1)
		if start < 0 or end < 0:
			return null
		bin = path.get_base_dir().path_join(text.substr(start + 1, end - start - 1))
		if not FileAccess.file_exists(bin):
			for name in DirAccess.get_files_at(path.get_base_dir()):
				if name.to_lower() == bin.get_file().to_lower():
					bin = path.get_base_dir().path_join(name)
	image.file = FileAccess.open(bin, FileAccess.READ)
	if image.file == null:
		return null
	image.sectors = image.file.get_length() / RAW
	return image


func _folder_sector(lba: int, raw_wanted: bool) -> PackedByteArray:
	var size := RAW if raw_wanted else USER
	var empty := PackedByteArray()
	empty.resize(size)
	var low := 0
	var high := _files.size() - 1
	while low <= high:
		var mid := (low + high) / 2
		var entry: Dictionary = _files[mid]
		if lba < int(entry["lba"]):
			high = mid - 1
		elif lba >= int(entry["lba"]) + int(entry["sectors"]):
			low = mid + 1
		else:
			var handle: FileAccess = _handles.get(entry["path"])
			if handle == null:
				handle = FileAccess.open(entry["path"], FileAccess.READ)
				_handles[entry["path"]] = handle
			if handle == null:
				return empty
			var index: int = lba - int(entry["lba"])
			if entry["raw"]:
				handle.seek(index * RAW)
				var raw := handle.get_buffer(RAW)
				return raw if raw_wanted else raw.slice(USER_OFFSET, USER_OFFSET + USER)
			if raw_wanted:
				return empty
			handle.seek(index * USER)
			return handle.get_buffer(USER)
	return empty


func read_sector(lba: int) -> PackedByteArray:
	if folder != "":
		return _folder_sector(lba, false)
	if lba < 0 or lba >= sectors:
		var empty := PackedByteArray()
		empty.resize(USER)
		return empty
	file.seek(lba * RAW + USER_OFFSET)
	return file.get_buffer(USER)


## Raw 2352 byte sector (movies and XA audio).
func read_raw(lba: int) -> PackedByteArray:
	if folder != "":
		return _folder_sector(lba, true)
	if lba < 0 or lba >= sectors:
		var empty := PackedByteArray()
		empty.resize(RAW)
		return empty
	file.seek(lba * RAW)
	return file.get_buffer(RAW)


func read_bytes(lba: int, length: int) -> PackedByteArray:
	var out := PackedByteArray()
	var count := (length + USER - 1) / USER
	for i in count:
		out.append_array(read_sector(lba + i))
	out.resize(length)
	return out


func _entries(lba: int, size: int) -> Array:
	var data := read_bytes(lba, size)
	var out := []
	var pos := 0
	while pos < data.size():
		var n := data[pos]
		if n == 0:
			pos = (pos / USER + 1) * USER
			continue
		var name_length := data[pos + 32]
		var name := data.slice(pos + 33, pos + 33 + name_length).get_string_from_ascii()
		if name_length > 1 or (name_length == 1 and data[pos + 33] > 1):
			out.append({
				"name": name.get_slice(";", 0),
				"lba": data.decode_u32(pos + 2),
				"size": data.decode_u32(pos + 10),
				"dir": (data[pos + 25] & 2) != 0,
			})
		pos += n
	return out


## {lba, size} of a path such as "\\DATA\\SU.MRG;1", or an empty dictionary.
func find(path: String) -> Dictionary:
	if _cache.has(path):
		return _cache[path]
	var pvd := read_sector(16)
	var lba := pvd.decode_u32(156 + 2)
	var size := pvd.decode_u32(156 + 10)
	var parts := path.replace("/", "\\").split("\\", false)
	var found := {}
	for i in parts.size():
		var want := parts[i].get_slice(";", 0).to_upper()
		found = {}
		for entry in _entries(lba, size):
			if String(entry["name"]).to_upper() == want:
				found = entry
				break
		if found.is_empty():
			break
		lba = found["lba"]
		size = found["size"]
	_cache[path] = found
	return found
