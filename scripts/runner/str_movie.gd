class_name STRMovie
extends RefCounted
## Reads a raw 2352-byte-per-sector STR movie file and yields assembled MDEC frames.

const SECTOR_SIZE := 2352
const DATA_OFFSET := 24
const SUBMODE_OFFSET := 18
const SUBMODE_AUDIO := 0x04
const SUBMODE_FORM2 := 0x20
const VIDEO_ID := 0x0160
const VIDEO_HEADER_SIZE := 32

var _file: FileAccess
var _sector_count := 0
var _next_sector := 0


func _init(path: String) -> void:
	_file = FileAccess.open(path, FileAccess.READ)
	if _file:
		_sector_count = int(_file.get_length() / SECTOR_SIZE)


func is_open() -> bool:
	return _file != null


func rewind() -> void:
	_next_sector = 0


## Returns the next complete frame as {frame_number, width, height, frame_size, bitstream}, or {} at end.
## The bitstream starts with the 8-byte MDEC frame header, as expected by MDEC.decode_frame.
func next_frame() -> Dictionary:
	if _file == null:
		return {}
	var bitstream := PackedByteArray()
	var info := {}
	while _next_sector < _sector_count:
		_file.seek(_next_sector * SECTOR_SIZE)
		var sector := _file.get_buffer(SECTOR_SIZE)
		_next_sector += 1
		if sector.size() < SECTOR_SIZE:
			break
		var submode := sector[SUBMODE_OFFSET]
		if submode & SUBMODE_AUDIO:
			continue
		var data_size := 2324 if submode & SUBMODE_FORM2 else 2048
		var data := sector.slice(DATA_OFFSET, DATA_OFFSET + data_size)
		if _u16(data, 0) != VIDEO_ID:
			continue
		var index := _u16(data, 4)
		var count := _u16(data, 6)
		if index == 0:
			bitstream.clear()
			info = {
				"frame_number": _u32(data, 8),
				"frame_size": _u32(data, 12),
				"width": _u16(data, 16),
				"height": _u16(data, 18),
			}
		elif bitstream.is_empty():
			continue
		# Sector 0 keeps the MDEC frame header at its start of data (bytes 32..39);
		# every other sector's payload starts directly after the 32-byte header.
		bitstream.append_array(data.slice(VIDEO_HEADER_SIZE))
		if index == count - 1:
			info["bitstream"] = bitstream
			return info
	return {}


static func _u16(b: PackedByteArray, i: int) -> int:
	return b[i] | (b[i + 1] << 8)


static func _u32(b: PackedByteArray, i: int) -> int:
	return _u16(b, i) | (_u16(b, i + 2) << 16)
