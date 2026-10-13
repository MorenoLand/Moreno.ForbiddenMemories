extends RefCounted
## PlayStation SPU as software sees it: 512 KB sound RAM, the transfer address/FIFO and DMA path, control/status registers and the
## 24 voices' register blocks. Key on/off and voice parameter writes are turned into events (decoded ADPCM sample streams plus
## pitch/volume/envelope values) that the audio output node plays with Godot's mixer; reverb and the noise generator are not modelled.

const RAM_SIZE := 0x80000
const BASE := 0x1F801C00
const END := 0x1F801E00
const MAIN_VOLUME_L := 0x1F801D80
const MAIN_VOLUME_R := 0x1F801D82
const KEY_ON_LOW := 0x1F801D88
const KEY_ON_HIGH := 0x1F801D8A
const KEY_OFF_LOW := 0x1F801D8C
const KEY_OFF_HIGH := 0x1F801D8E
const ENDX_LOW := 0x1F801D9C
const ENDX_HIGH := 0x1F801D9E
const TRANSFER_ADDRESS := 0x1F801DA6
const FIFO := 0x1F801DA8
const CONTROL := 0x1F801DAA
const STATUS := 0x1F801DAE
const MIX_RATE := 44100
const MAX_SAMPLES := 4000000

const FILTER_A := [0, 60, 115, 98, 122]
const FILTER_B := [0, 0, -52, -55, -60]

var ram := PackedByteArray()
var regs := PackedInt32Array()
var transfer_pointer := 0
var events: Array = []
var pending_on: Dictionary = {}
var pending_off: Dictionary = {}
var streams: Dictionary = {}     # start address -> {stream, begin, end, looped, length}
var active := PackedInt32Array()  # per voice: 1 while keyed on
var main_l := 0x3FFF
var main_r := 0x3FFF


func _init() -> void:
	ram.resize(RAM_SIZE)
	regs.resize((END - BASE) / 2)
	active.resize(24)


func owns(address: int) -> bool:
	return address >= BASE and address < END


func read16(address: int) -> int:
	if address == STATUS:
		var control := regs[(CONTROL - BASE) / 2]
		return (control & 0x3F) | (0x80 if (control & 0x20) != 0 else 0)
	if address == ENDX_LOW or address == ENDX_HIGH:
		# voices that reached a loop end flag; software polls it to know a sample finished
		return regs[(address - BASE) / 2] & 0xFFFF
	return regs[(address - BASE) / 2] & 0xFFFF


func write16(address: int, value: int) -> void:
	value &= 0xFFFF
	regs[(address - BASE) / 2] = value
	if address < MAIN_VOLUME_L:
		var voice := (address - BASE) / 16
		var reg := ((address - BASE) % 16) / 2
		if reg == 2 and active[voice] != 0:
			events.append(["pitch", voice, value])
		elif (reg == 0 or reg == 1) and active[voice] != 0:
			events.append(["volume", voice, regs[(BASE + voice * 16 - BASE) / 2], regs[(BASE + voice * 16 + 2 - BASE) / 2]])
		return
	match address:
		TRANSFER_ADDRESS:
			transfer_pointer = (value * 8) % RAM_SIZE
		FIFO:
			push_halfword(value)
		MAIN_VOLUME_L:
			main_l = value
			events.append(["main", main_l, main_r])
		MAIN_VOLUME_R:
			main_r = value
			events.append(["main", main_l, main_r])
		KEY_ON_LOW:
			_key_on(value, 0)
		KEY_ON_HIGH:
			_key_on(value, 16)
		KEY_OFF_LOW:
			_key_off(value, 0)
		KEY_OFF_HIGH:
			_key_off(value, 16)


## Accesses through a pointer the port could not resolve land in main RAM at the I/O window (0x1F801C00 maps to 0x801C00).
## Once per frame the window is compared with the register file and differences are applied as writes, voice parameters before the
## key registers; the key-on/off registers are cleared afterwards, as on the console, so the same mask can be written again.
func sync_from_ram(main_ram: PackedByteArray) -> void:
	var first := 0x801C00
	var count := (END - BASE) / 2
	var key_indices := [(KEY_ON_LOW - BASE) / 2, (KEY_ON_HIGH - BASE) / 2, (KEY_OFF_LOW - BASE) / 2, (KEY_OFF_HIGH - BASE) / 2]
	var skip := [(FIFO - BASE) / 2, (STATUS - BASE) / 2, (ENDX_LOW - BASE) / 2, (ENDX_HIGH - BASE) / 2]
	for i in count:
		if key_indices.has(i) or skip.has(i):
			continue
		var value := main_ram.decode_u16(first + i * 2)
		if value != (regs[i] & 0xFFFF):
			write16(BASE + i * 2, value)
	# key-off first: the driver silences voices before it starts new notes on them
	for i in [key_indices[2], key_indices[3], key_indices[0], key_indices[1]]:
		var value := main_ram.decode_u16(first + i * 2)
		if value != 0:
			write16(BASE + i * 2, value)
		regs[i] = 0
		main_ram.encode_u16(first + i * 2, 0)
	flush_keys()


func take_events() -> Array:
	var out := events
	events = []
	return out


## Key-on and key-off are noted when written and resolved at the frame boundary (flush_keys), once every register write of the frame,
## whichever path it took, has landed: a note starts with its final volume, pitch and envelope.
func _key_on(mask: int, first: int) -> void:
	for bit in 16:
		if (mask & (1 << bit)) != 0 and first + bit < 24:
			pending_on[first + bit] = true
			pending_off.erase(first + bit)


func _key_off(mask: int, first: int) -> void:
	for bit in 16:
		var voice := first + bit
		if (mask & (1 << bit)) != 0 and voice < 24:
			pending_on.erase(voice)
			pending_off[voice] = true


func flush_keys() -> void:
	for voice in pending_off:
		active[voice] = 0
		events.append(["off", voice])
	pending_off.clear()
	for voice in pending_on:
		var base: int = (BASE + voice * 16 - BASE) / 2
		var start: int = (regs[base + 3] & 0xFFFF) * 8
		var info := _sample(start)
		active[voice] = 1
		var endx_index := ((ENDX_LOW if voice < 16 else ENDX_HIGH) - BASE) / 2
		regs[endx_index] &= ~(1 << (voice % 16))
		events.append(["on", voice, info, regs[base + 2] & 0xFFFF, regs[base], regs[base + 1], regs[base + 4], regs[base + 5]])
	pending_on.clear()


## Decodes one 16-byte ADPCM block into `block` (28 16-bit samples); returns the filter history (old, older) packed as a Vector2i.
func _decode_block(at: int, history: Vector2i, block: PackedByteArray) -> Vector2i:
	var header := ram[at]
	var shift := header & 15
	var filter := mini(header >> 4, 4)
	if shift > 12:
		shift = 9
	var fa: int = FILTER_A[filter]
	var fb: int = FILTER_B[filter]
	var old := history.x
	var older := history.y
	for i in 28:
		var byte := ram[at + 2 + (i >> 1)]
		var nibble := (byte >> 4) if (i & 1) != 0 else (byte & 15)
		var sample := ((nibble << 12) ^ 0x8000) - 0x8000
		sample = (sample >> shift) + ((old * fa + older * fb + 32) >> 6)
		sample = clampi(sample, -32768, 32767)
		older = old
		old = sample
		block.encode_s16(i * 2, sample)
	return Vector2i(old, older)


## Decodes the ADPCM sample that starts at a sound RAM address into a 16-bit mono stream (cached until RAM under it changes).
## A looping sample is decoded again from its loop block with the filter history it has at the end, until the output repeats, so the
## loop is what the console would play (a loop block that decays to silence is silent, not a buzzing copy of its first pass).
func _sample(start: int) -> Dictionary:
	if streams.has(start):
		return streams[start]
	var pcm := PackedByteArray()
	var history := Vector2i.ZERO
	var at := start
	var loop_at := -1
	var loop_start := -1
	var looped := false
	var blocks := 0
	var count := 0
	var block := PackedByteArray()
	block.resize(56)
	var end_at := -1
	while blocks < 8192 and at + 16 <= RAM_SIZE and count < MAX_SAMPLES:
		var flags := ram[at + 1]
		if (flags & 4) != 0 and loop_at < 0:
			loop_at = at
			loop_start = count
		history = _decode_block(at, history, block)
		count += 28
		pcm.append_array(block)
		blocks += 1
		end_at = at
		at += 16
		if (flags & 1) != 0:
			looped = (flags & 2) != 0
			break
	var loop_end := count
	if looped and loop_at >= 0 and end_at >= loop_at:
		var pass_bytes := PackedByteArray()
		var previous := PackedByteArray()
		var passes := 0
		while passes < 24 and count < MAX_SAMPLES and count < loop_end + 200000:
			pass_bytes = PackedByteArray()
			var pass_at := loop_at
			while pass_at <= end_at:
				history = _decode_block(pass_at, history, block)
				pass_bytes.append_array(block)
				pass_at += 16
			passes += 1
			if pass_bytes == previous:
				break
			pcm.append_array(pass_bytes)
			count += pass_bytes.size() / 2
			previous = pass_bytes
		loop_end = count
		# the last pass is what repeats
		loop_start = count - previous.size() / 2
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.stereo = false
	stream.mix_rate = MIX_RATE
	stream.data = pcm
	if looped and count > 0:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = maxi(loop_start, 0)
		stream.loop_end = loop_end
	var info := {"stream": stream, "length": count, "looped": looped, "end": at}
	streams[start] = info
	if streams.size() > 512:
		streams.clear()
	return info


## Sample caches are dropped when sound RAM under them is rewritten.
func _invalidate(from: int, to: int) -> void:
	if streams.is_empty():
		return
	for start in streams.keys():
		var info: Dictionary = streams[start]
		if int(start) < to and from < int(info["end"]):
			streams.erase(start)


func push_halfword(value: int) -> void:
	ram.encode_u16(transfer_pointer % RAM_SIZE, value)
	transfer_pointer = (transfer_pointer + 2) % RAM_SIZE


## DMA channel 4: words between main RAM and sound RAM at the transfer address.
func dma_write(main_ram: PackedByteArray, madr: int, words: int) -> void:
	var from := transfer_pointer
	for i in words:
		var at := (madr + i * 4) & 0x1FFFFC
		push_halfword(main_ram.decode_u16(at))
		push_halfword(main_ram.decode_u16(at + 2))
	_invalidate(from, from + words * 4)


func dma_read(main_ram: PackedByteArray, madr: int, words: int) -> void:
	for i in words:
		var at := (madr + i * 4) & 0x1FFFFC
		main_ram.encode_u16(at, ram.decode_u16(transfer_pointer % RAM_SIZE))
		transfer_pointer = (transfer_pointer + 2) % RAM_SIZE
		main_ram.encode_u16(at + 2, ram.decode_u16(transfer_pointer % RAM_SIZE))
		transfer_pointer = (transfer_pointer + 2) % RAM_SIZE
