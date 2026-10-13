extends RefCounted
## The music sequencer: plays one sequence (the SEQp / MThd style chunk in seq.bin) through the 20 music voices, the way the
## game's sound driver does it. The behaviour below is the driver's, restated.
##
## Sequence layout (from the start of the chunk): bytes 0-3 are the tag, bytes 8-9 the timebase (u16 BE), bytes 10-12 the
## tempo as microseconds per quarter note (u24 BE), byte 14 a lead-in byte, and the first track data starts at byte 15. There is
## one track; its events are standard MIDI channel messages with running status, meta events and SysEx.
##
## Timing. The driver runs one step (`call`) at 590.625 Hz: the RCnt2 timer fires 73.828 times a second and each interrupt
## runs eight steps. Each step adds the tempo step to an 8-bit accumulator; when the sum reaches 256 the track advances one
## sequencer tick (its delta countdown runs down, and at zero the next event is read). The tempo step is
## 60000000 / tempo * 100 / 115, clamped to 255, and divided by 2 (timebase 0x18 or 0x3C) or by 4 (0x1E). Delta times are
## rescaled from the file's timebase by a factor per timebase (see `_scale_delta`), so one quarter note is 120 units for the
## common timebases.
##
## Every 11 steps the driver sweeps the voices: it frees the voices whose envelope has finished, refreshes pitch bend, and
## ages the note slots (the oldest slot is the one stolen first).
##
## Controllers used: 7 (channel volume), 10 (pan), 11 (expression), 30 (0x1E: the global volume, all voices), 48 (0x30: the
## channel's voice limit in the high nibble), 6 (data entry: the loop count while the channel is in loop mode), 99 (0x63: loop
## mode, 0x14 start and 0x1E end). Pitch bend (E0) is the MSB, 64 is centre. Program change (C0) selects the program.

const BgmVoices := preload("res://scripts/system/bgm_voices.gd")
const CALLS_PER_SECOND := 590.625
const SWEEP_EVERY := 11
const OBJECTS := 20
const CHANNELS := 16
const NONE := 99
const SAMPLE_RATE := 44100.0
const FADE_RATE := 60.0
const FIELD_0044 := 210            # the driver's default music master level (0xD2), used only when the track has no bank volume
const EVENT_GUARD := 20000         # bounds the events one step may read (a track of empty deltas would loop)

## Data entries per status high nibble: 0 for 0x0-0x7 and 0xF, 2 for 0x8-0xB and 0xE, 1 for 0xC-0xD.
const EVENT_DATA := [0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 1, 1, 2, 0]

var voices                           # bgm_voices.gd instance
var track                            # bgm_track.gd instance
var seq: PackedByteArray = PackedByteArray()
var seq_len := 0

# the track
var active := false                  # a sequence is playing (field_07E2 == 1)
var ended := false                   # the track's end was reached
var pos := 0
var delta := 0
var frac := 0                        # delta rescale remainder (field_0018)
var acc := 0                         # tempo accumulator (u16)
var tempo_step := 0
var timebase := 0
var running_status := 0
var running_held := false
var loop_count := 0x7F
var pos_saved := 0
var step_count := 0                  # steps since the last sweep (field_0508)

# the channels (16) and the sound objects (20)
var program := PackedInt32Array()
var ch_pan := PackedInt32Array()
var ch_volume := PackedInt32Array()
var ch_expression := PackedInt32Array()
var ch_bend := PackedInt32Array()
var ch_mode := PackedInt32Array()
var ch_field6 := PackedInt32Array()  # high nibble: voice limit, low nibble: voices in use
var ch_parameter := PackedInt32Array()
var obj_channel := PackedInt32Array()
var obj_note := PackedInt32Array()
var obj_flag := PackedInt32Array()   # 0 free, 1 sounding, 2+ counting an envelope that has ended
var obj_keyed := PackedInt32Array()
var obj_age := PackedInt32Array()
var obj_level_l := PackedInt32Array()
var obj_level_r := PackedInt32Array()
var obj_mvol := PackedInt32Array()
var obj_mpan := PackedInt32Array()
var obj_tvol := PackedInt32Array()
var obj_tpan := PackedInt32Array()
var obj_velocity := PackedInt32Array()
var obj_center := PackedInt32Array()
var obj_shift := PackedInt32Array()
var obj_pbmax := PackedInt32Array()
var obj_pbmin := PackedInt32Array()
var obj_cached_bend := PackedInt32Array()

# the levels: the global volume (controller 30 on the driver's global side, default 127), the spatial levels, the master
var global_volume := 127
var spatial_l := 127
var spatial_r := 127
var master_l := 127
var master_r := 127
var vab_mvol := 127                  # the bank's master volume (the transfer's level)
var vab_mpan := 64                   # the bank's master pan (the transfer's base pan)
var panning := true                  # false: mono output, every voice centred

# the fades (the driver's music fade fields)
var fade_level := 255                # field_1580: the fade-out multiplier, 255 full
var fade_step := 0                   # field_1582
var fade_target := 255               # field_1584
var volume_level := 0                # field_1586: the fade-in / volume level
var volume_step := 0                 # field_1588
var volume_target := 0               # field_158A

var pitch_table := PackedInt32Array()
## Counts for the tests and the report: notes started and ended, notes whose program or tone the data lacks, steals.
var stats := {"note_on": 0, "note_off": 0, "no_program": 0, "no_tone": 0, "steal": 0, "steps": 0}


func _init(voice_set) -> void:
	voices = voice_set
	program.resize(CHANNELS)
	ch_pan.resize(CHANNELS)
	ch_volume.resize(CHANNELS)
	ch_expression.resize(CHANNELS)
	ch_bend.resize(CHANNELS)
	ch_mode.resize(CHANNELS)
	ch_field6.resize(CHANNELS)
	ch_parameter.resize(CHANNELS)
	for name in ["obj_channel", "obj_note", "obj_flag", "obj_keyed", "obj_age", "obj_level_l", "obj_level_r", "obj_mvol",
			"obj_mpan", "obj_tvol", "obj_tpan", "obj_velocity", "obj_center", "obj_shift", "obj_pbmax", "obj_pbmin",
			"obj_cached_bend"]:
		set(name, PackedInt32Array())
		get(name).resize(OBJECTS)
	pitch_table.resize(12 * 128)
	for semitone in 12:
		for fine in 128:
			pitch_table[semitone * 128 + fine] = int(floor(4096.0 * pow(2.0, (semitone * 128 + fine) / (12.0 * 128.0))))  # floor: the reference SPU pitch table (checked against 16 real pitch registers)
	_reset_playback()


## Start a sequence of `track` (bgm_track.gd) from its chunk: the driver's routine.
func start(bgm_track) -> bool:
	track = bgm_track
	seq = track.seq
	seq_len = seq.size()
	if seq_len < 16:
		return false
	_reset_playback()
	_read_header()
	if ended:
		active = false
		return false
	active = true
	fade_level = 255
	fade_step = 255
	fade_target = 255
	volume_step = 255
	volume_target = 255
	return true


## Stop at once: every voice is released and the sequence is closed (the driver's stop).
func stop() -> void:
	active = false
	volume_level = 0
	volume_step = 0
	volume_target = 0
	for i in OBJECTS:
		voices.key_off(i)
	_reset_playback()


## End of track: every voice is keyed off and the channels and
## objects are reset, and the volume level fades to 0 at -128 per tick.
func finish() -> void:
	_reset_playback()
	volume_step = -128
	volume_target = 0


## Fade-out with a step (negative: the level goes down by |step| per tick, to 0).
func fade_out(step: int) -> void:
	fade_step = -absi(step)
	fade_target = 0


## One step of the driver's timer.
func call_step() -> void:
	if not active:
		return
	stats["steps"] += 1
	if not ended:
		var sum := acc + tempo_step
		acc = sum & 0xFFFF
		if (sum & 0xFFFF) >= 0x100:
			acc = sum & 0xFF
			if delta != 0:
				delta -= 1
			else:
				_run_events()
	step_count += 1
	if step_count >= SWEEP_EVERY:
		step_count = 0
		_age_objects()
		_sweep_voices()


## One fade tick, at 60 Hz. Returns true when the levels changed.
func fade_tick() -> bool:
	var changed := false
	if volume_step != 0:
		volume_level += volume_step
		changed = true
		if volume_level <= volume_target and volume_step < 0:
			volume_step = 0
			volume_level = volume_target
		if volume_level >= volume_target and volume_step > 0:
			volume_step = 0
			volume_level = volume_target
	if fade_step != 0:
		fade_level += fade_step
		changed = true
		if fade_level <= fade_target and fade_step < 0:
			fade_step = 0
			fade_level = fade_target
		if fade_level >= fade_target and fade_step > 0:
			fade_step = 0
			fade_level = fade_target
	if changed:
		var v: int = track.bank_volume if track != null else FIELD_0044
		if v != 0:
			v = (v * (fade_level + 1)) >> 8
		else:
			v = 0
		if v != 0:
			v = (v * (volume_level + 1)) >> 8
		else:
			v = 0
		master_l = v
		master_r = v
		_update_all_volumes()
	return changed


## Voices still keyed on (a note whose note-off never came): the tests check this is empty at the track's end.
func held_notes() -> int:
	var n := 0
	for i in OBJECTS:
		if obj_keyed[i] != 0:
			n += 1
	return n


## True while a sequence is playing (the driver's status bit 0x80).
func is_playing() -> bool:
	return active


# ---- playback state -----------------------------------------------------------------------------------------------------

func _reset_playback() -> void:
	for c in CHANNELS:
		ch_pan[c] = 64
		ch_volume[c] = 127
		ch_expression[c] = 127
		ch_bend[c] = 64
		ch_field6[c] = 0
	global_volume = 127
	for i in OBJECTS:
		obj_channel[i] = NONE
		obj_flag[i] = 0
		obj_keyed[i] = 0
		obj_age[i] = 0
		obj_level_l[i] = 0
		obj_level_r[i] = 0
		obj_cached_bend[i] = -1
		obj_note[i] = 0
		voices.key_off(i)
	ended = false
	active = false
	pos = 0
	delta = 0
	frac = 0
	acc = 0
	tempo_step = 0
	timebase = 0
	running_status = 0
	running_held = false
	loop_count = 0x7F
	pos_saved = 0
	step_count = 0
	spatial_l = 127
	spatial_r = 127


## The driver's header: timebase, tempo (scaled into the tempo step) and the first delta.
func _read_header() -> void:
	pos = 8
	timebase = _read_u16()
	var raw := (_read_byte() << 16) | (_read_byte() << 8) | _read_byte()
	_read_byte()                     # lead-in byte
	tempo_step = _tempo_to_step(raw)
	acc = tempo_step
	pos = 15
	var value := _read_vlq()
	delta = value
	frac = 0
	if timebase != 0:
		_scale_delta()


func _tempo_to_step(raw: int) -> int:
	if raw <= 0:
		return 0
	var v := 60000000 / raw
	v = v * 100 / 115
	if v >= 0x100:
		v = 0xFF
	match timebase:
		0x1E:
			v = v >> 2
		0x18, 0x3C:
			v = v >> 1
	return v


func _read_byte() -> int:
	if pos >= seq_len:
		ended = true
		pos += 1
		return -1
	var value := seq[pos]
	pos += 1
	return value


func _read_u16() -> int:
	var high := _read_byte()
	var low := _read_byte()
	return ((high & 0xFF) << 8) | (low & 0xFF)


func _read_vlq() -> int:
	var value := _read_byte()
	if value == 0:
		return 0
	if value == 0xFF:
		ended = true
		return 0
	var result := value
	if (result & 0x80) != 0:
		result &= 0x7F
		var guard := 0
		while true:
			value = _read_byte()
			if value < 0:
				break
			result = (result << 7) + (value & 0x7F)
			guard += 1
			if (value & 0x80) == 0 or guard > 8:
				break
	return result


## The driver's delta rescale from the file's timebase (ratios per timebase, the remainder kept in `frac`).
func _scale_delta() -> void:
	match timebase:
		0x30:
			delta = delta * 10 + frac
			frac = delta & 3
			delta = delta >> 2
		0x60:
			delta = delta * 5 + frac
			frac = delta & 3
			delta = delta >> 2
		0xC0, 0xF0:
			delta = delta + frac
			frac = delta & 1
			delta = delta >> 1
		0x120, 0x168:
			delta = delta / 3
		0x180, 0x1E0:
			delta = delta + frac
			frac = delta & 3
			delta = delta >> 2
		0x300, 0x3C0:
			delta = delta + frac
			frac = delta & 7
			delta = delta >> 3
		_:
			pass


## The track's event loop for one tick (the driver's retry loop): read an event, read the next delta, and repeat while
## the delta is zero.
func _run_events() -> void:
	var guard := 0
	while true:
		_read_event()
		if not ended:
			var value := _read_vlq()
			delta = value
			if value == 0:
				guard += 1
				if guard > EVENT_GUARD:
					ended = true
					break
				continue
			if timebase != 0:
				_scale_delta()
			if delta == 0:
				guard += 1
				if guard > EVENT_GUARD:
					ended = true
					break
				continue
		break
	if delta != 0:
		delta -= 1


func _read_event() -> void:
	if ended:
		return
	var cmd := _read_byte()
	if cmd < 0:
		return
	var ev := cmd & 0xFF
	var status: int
	if (cmd & 0x80) == 0:
		status = running_status
		running_held = true
	else:
		if ev != 0xFF:
			running_status = cmd
		status = cmd
		running_held = false
	var kind: int = EVENT_DATA[(status >> 4) & 0xF]
	if kind != 0:
		var b2 := ev
		if not running_held:
			b2 = _read_byte()
		var b3 := 0
		if kind == 2:
			b3 = _read_byte()
		_dispatch(status & 0xFF, b2, b3)
		return
	match ev:
		0xFF:
			_meta(_read_byte() & 0xFF)
		0xF0:
			_sysex()
		_:
			pass


func _meta(kind: int) -> void:
	match kind:
		0x2F:
			ended = true
			_read_byte()
		0x51:
			var raw := (_read_byte() << 16) | (_read_byte() << 8) | _read_byte()
			tempo_step = _tempo_to_step(raw)
			acc = tempo_step
		0x54:
			_read_byte()
			_read_byte()
			_read_byte()
			_read_byte()
			_read_byte()
			_read_byte()
		0x58:
			_read_byte()
			_read_u32()
		0x59:
			_read_byte()
			_read_byte()
			_read_byte()
		_:
			var length := _read_vlq()
			pos += length


func _read_u32() -> int:
	var a := _read_byte()
	var b := _read_byte()
	var c := _read_byte()
	var d := _read_byte()
	return ((a & 0xFF) << 24) | ((b & 0xFF) << 16) | ((c & 0xFF) << 8) | (d & 0xFF)


func _sysex() -> void:
	var count := _read_vlq()
	var i := 0
	while true:
		i += 1
		if (_read_byte() & 0xFF) == 0xF7:
			break
		if i >= count:
			break


func _dispatch(status: int, d1: int, d2: int) -> void:
	var ch := status & 0x0F
	match status & 0xF0:
		0x80:
			_note_off(ch, d1)
		0x90:
			if d2 != 0:
				_note_on(ch, d1, d2)
			else:
				_note_off(ch, d1)
		0xB0:
			_controller(ch, d1, d2)
		0xC0:
			program[ch] = d1
		0xE0:
			ch_bend[ch] = d2 & 0x7F


func _controller(ch: int, d1: int, d2: int) -> void:
	if d1 == 0x63:
		if d2 == 0x14:
			loop_count = 0x7F
			pos_saved = pos
		elif d2 == 0x1E:
			var v := loop_count
			if v != 0:
				if v < 0x7F:
					loop_count = v - 1
				pos = pos_saved
	if d1 == 6 and (ch_mode[ch] == 0x14):
		loop_count = d2
		return
	match d1:
		6:
			pass
		7:
			ch_volume[ch] = d2
			_update_channel_volumes(ch)
		0x0A:
			ch_pan[ch] = d2 if d2 != 0 else 1
			_update_channel_volumes(ch)
		0x0B:
			ch_expression[ch] = d2
			_update_channel_volumes(ch)
		0x1E:
			global_volume = d2
			_update_all_volumes()
		0x30:
			ch_field6[ch] = (ch_field6[ch] & 0xF) | ((d2 & 0xF) << 4)
		0x62:
			ch_parameter[ch] = d2
		0x63:
			ch_mode[ch] = d2
		_:
			pass


# ---- notes ---------------------------------------------------------------------------------------------------------------

func _note_on(ch: int, note: int, velocity: int) -> void:
	var prog = track.program(program[ch])
	if prog == null:
		stats["no_program"] += 1
		return
	var tones: Array = prog["tones"]
	var sounded := false
	for tidx in tones.size():
		var tone: Dictionary = tones[tidx]
		if note < int(tone["min"]) or note > int(tone["max"]):
			continue
		sounded = true
		var limit := ch_field6[ch] & 0xF0
		var stolen := false
		var idx := -1
		if limit != 0 and (ch_field6[ch] & 0xF) >= (limit >> 4):
			idx = _lowest_priority(ch)
			if idx == -1:
				idx = _select(ch, note)
			else:
				stolen = true
		else:
			idx = _select(ch, note)
		if idx == -1:
			continue
		if stolen:
			stats["steal"] += 1
		stats["note_on"] += 1
		obj_channel[idx] = ch
		obj_note[idx] = note
		obj_flag[idx] = 1
		obj_keyed[idx] = 1
		obj_age[idx] = 0xFFFF
		obj_mvol[idx] = int(prog["mvol"])
		obj_mpan[idx] = int(prog["mpan"])
		obj_tvol[idx] = int(tone["vol"])
		obj_tpan[idx] = int(tone["pan"])
		obj_velocity[idx] = velocity
		obj_center[idx] = int(tone["center"])
		obj_shift[idx] = int(tone["shift"])
		obj_pbmax[idx] = int(tone["pbmax"])
		obj_pbmin[idx] = int(tone["pbmin"])
		obj_cached_bend[idx] = -1
		_spatialize(idx)
		var pitch := _pitch_for(idx, ch_bend[ch])
		obj_cached_bend[idx] = ch_bend[ch]
		var sample: Dictionary = track.sample(int(tone["vag"]))
		var vol_l := (obj_level_l[idx] * master_l) >> 7
		var vol_r := (obj_level_r[idx] * master_r) >> 7
		voices.key_on(idx, sample["data"], bool(sample["loop_on"]), int(sample["loop_start"]), int(sample["loop_end"]),
				pitch, vol_l, vol_r, int(tone["adsr1"]), int(tone["adsr2"]))
		if not stolen and (ch_field6[ch] & 0xF) < 0xF:
			ch_field6[ch] = ch_field6[ch] + 1
	if not sounded:
		stats["no_tone"] += 1


func _note_off(ch: int, note: int) -> void:
	for i in OBJECTS:
		if obj_channel[i] == ch and obj_note[i] == note:
			if obj_keyed[i] != 0:
				stats["note_off"] += 1
			voices.key_off(i)
			obj_keyed[i] = 0


## The first free object, else the first that is not sounding, else the same channel's same note, else the oldest.
func _select(ch: int, note: int) -> int:
	for i in OBJECTS:
		if obj_channel[i] == NONE:
			return i
	for i in OBJECTS:
		if obj_flag[i] == 0:
			return _prepare_reuse(i)
	for i in OBJECTS:
		if obj_channel[i] == ch and obj_note[i] == note:
			return _prepare_reuse(i)
	var best := 0xFFFF
	var result := -1
	for i in OBJECTS:
		var candidate: int = obj_age[i]
		if candidate < best:
			best = candidate
			result = i
	if best >= 0xFFFF:
		return -1
	return _prepare_reuse(result)


func _lowest_priority(ch: int) -> int:
	var best := 0xFFFF
	var result := -1
	for i in OBJECTS:
		var candidate: int = obj_age[i]
		if best >= candidate and obj_channel[i] == ch and obj_flag[i] != 0:
			best = candidate
			result = i
	return result


func _prepare_reuse(index: int) -> int:
	var owner: int = obj_channel[index]
	if owner != NONE and owner < CHANNELS:
		if (ch_field6[owner] & 0xF) != 0:
			ch_field6[owner] = ch_field6[owner] - 1
	return index


# ---- levels, pitch --------------------------------------------------------------------------------------------------------

## The driver's pan and level for object `i`, from its channel and tone.
func _spatialize(i: int) -> void:
	var ch: int = obj_channel[i]
	var pan := 64
	if panning:
		pan = vab_mpan + obj_mpan[i] + obj_tpan[i] + ch_pan[ch] - 192
	pan = clampi(pan, 0, 127)
	var level := vab_mvol * global_volume
	level = level * ch_expression[ch]
	level = level * ch_volume[ch]
	level = level >> 14
	level = level * obj_mvol[i]
	var product := level * obj_tvol[i]
	level = product >> 14
	var left := level
	var right := level
	if pan >= 64:
		right = level
		if pan == 64:
			right = (pan * (left << 1)) >> 7
			left = right
		else:
			left = ((64 - (pan & 63)) * (right << 1)) >> 7
	else:
		right = (pan * (left << 1)) >> 7
	var pl := left * spatial_l
	var pr := right * spatial_r
	left = pl >> 7
	level = left * (obj_velocity[i] & 0x7F)
	right = pr >> 7
	var pan_r := right * (obj_velocity[i] & 0x7F)
	obj_level_l[i] = level >> 7
	obj_level_r[i] = pan_r >> 7


func _set_voice_volume(i: int) -> void:
	var vol_l := (obj_level_l[i] * master_l) >> 7
	var vol_r := (obj_level_r[i] * master_r) >> 7
	voices.set_volume(i, vol_l, vol_r)


func _update_channel_volumes(ch: int) -> void:
	for i in OBJECTS:
		if obj_channel[i] == ch and obj_flag[i] != 0:
			_spatialize(i)
			_set_voice_volume(i)


func _update_all_volumes() -> void:
	for i in OBJECTS:
		if obj_channel[i] < CHANNELS:
			_spatialize(i)
			_set_voice_volume(i)


## The driver's pitch bend in 1/128 semitone units (CalcPitchBend).
func _bend_units(i: int, msb: int) -> int:
	if msb < 0x40:
		if obj_pbmin[i] == 0:
			return 0
		return -((obj_pbmin[i] << 1) * (0x40 - msb))
	if msb == 0x40:
		return 0
	if obj_pbmax[i] == 0:
		return 0
	return (obj_pbmax[i] << 1) * (msb - 0x3F)


## The SPU pitch register for object `i` at bend `msb`: the note plus bend, against the tone's centre and fine shift.
func _pitch_for(i: int, msb: int) -> int:
	return pitch_value(obj_note[i], _bend_units(i, msb), obj_center[i], obj_shift[i])


## The SPU pitch register (4096 is the sample's own rate) for a note with a bend in 1/128 semitones, over a tone centre and
## its fine shift. Notes are reduced to an octave and a semitone with the 12-row table, as the driver does.
func pitch_value(note: int, bend_units: int, center: int, shift: int) -> int:
	var v := bend_units + note * 128
	var note_high := v >> 7
	var note_low := v & 0x7F
	var fine := note_low + shift
	var semis := note_high + fine / 128
	var col := fine % 128
	var diff := semis - center
	if diff >= 0:
		return (pitch_table[(diff % 12) * 128 + col] << (diff / 12)) & 0xFFFF
	var down := -diff
	return (pitch_table[((12 - (down % 12)) % 12) * 128 + col] >> ((down + 11) / 12)) & 0xFFFF


func _age_objects() -> void:
	for i in OBJECTS:
		if obj_age[i] != 0 and obj_channel[i] < CHANNELS:
			obj_age[i] = obj_age[i] - 1
		else:
			obj_age[i] = 0


## The driver's per-object sweep (once per 11 steps): pitch bend, free finished voices, end the envelope of a note whose
## envelope has run out, and keep released voices releasing.
func _sweep_voices() -> void:
	for i in OBJECTS:
		if obj_channel[i] < CHANNELS:
			if obj_cached_bend[i] != ch_bend[obj_channel[i]]:
				obj_cached_bend[i] = ch_bend[obj_channel[i]]
				voices.set_pitch(i, _pitch_for(i, obj_cached_bend[i]))
		var status: int = voices.status(i)
		if status == BgmVoices.STATUS_OFF:
			if obj_flag[i] != 0:
				var owner: int = obj_channel[i]
				if owner < CHANNELS and (ch_field6[owner] & 0xF) != 0:
					ch_field6[owner] = ch_field6[owner] - 1
				obj_flag[i] = 0
				obj_age[i] = 0
				obj_channel[i] = NONE
		elif obj_flag[i] != 0 and status == BgmVoices.STATUS_ON_ENV_OFF:
			if obj_flag[i] >= 2:
				voices.key_off(i)
				obj_keyed[i] = 0
			else:
				obj_flag[i] = obj_flag[i] + 1
		if obj_keyed[i] == 0 and (status == BgmVoices.STATUS_ON or status == BgmVoices.STATUS_OFF_ENV_ON):
			voices.key_off(i)
