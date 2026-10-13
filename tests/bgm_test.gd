extends SceneTree
## Headless checks for the background music: the sequencer (timing, running status, loops, pitch, fades, end of track), the
## voices (envelope status), the missing-track rule, and, when assets/audio/bgm/ is exported, every track: its sequence runs to
## the end (or loops), no note is left sounding, and three seconds render to a non-silent buffer.
##
## Run from the project folder (headless, silent):
##   G:\Software\Redot\redot.windows.editor.x86_64.exe --headless --path G:\Development\Godot\Projects\ForbiddenMemories --script res://tests/bgm_test.gd
## Prints PASS or FAIL per check, then a summary. Exits 0 when every check passes, 1 otherwise. No audio is played: the tests
## only render into memory.

const BgmTrack := preload("res://scripts/system/bgm_track.gd")
const BgmPlayer := preload("res://scripts/system/bgm_player.gd")
const BgmVoices := preload("res://scripts/system/bgm_voices.gd")
const BgmSequencer := preload("res://scripts/system/bgm_sequencer.gd")

const RATE := 44100
const DATA_ROOT := "res://assets/audio/bgm/"
const DATA_LIMIT_SECONDS := 120.0   # a track that has not ended by then is taken as looping

var passed := 0
var failed := 0
var group := ""
var data_tracks := 0


func check(label: String, ok: bool) -> void:
	var full := label if group == "" else "%s: %s" % [group, label]
	if ok:
		passed += 1
		print("PASS  ", full)
	else:
		failed += 1
		print("FAIL  ", full)


func _init() -> void:
	group = "synthetic"
	_test_pitch_table()
	_test_timing_and_note()
	_test_running_status()
	_test_loop()
	_test_fade()
	_test_end_of_track()
	_test_envelope_status()
	_test_render_non_silent()
	_test_missing_track()
	group = "data"
	_test_data_tracks()
	print("")
	print("%d passed, %d failed, %d checks (%d exported tracks)" % [passed, failed, passed + failed, data_tracks])
	quit(0 if failed == 0 else 1)


# ---- helpers -------------------------------------------------------------------------------------------------------------

func byte_array(values: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for v in values:
		out.append(int(v) & 0xFF)
	return out


## A sequence chunk: the 'SEQp' tag, filler to the timebase at byte 8, the tempo at 10 to 12, lead-in bytes, then the track.
func seq_chunk(timebase: int, tempo_us: int, track: Array) -> PackedByteArray:
	var head := [0x53, 0x45, 0x51, 0x70, 0, 0, 0, 0, (timebase >> 8) & 0xFF, timebase & 0xFF,
			(tempo_us >> 16) & 0xFF, (tempo_us >> 8) & 0xFF, tempo_us & 0xFF, 0, 0]
	return byte_array(head + track)


## A test track: programs {0: one tone on a looping 0.1 s sine}, the sample at VAG 1.
func make_track(seq: PackedByteArray, adsr1 := 0x0000, adsr2 := 0x000A, loops := true) -> BgmTrack:
	var t := BgmTrack.new()
	t.seq = seq
	var sine := PackedFloat32Array()
	sine.resize(4410)
	for i in 4410:
		sine[i] = sin(TAU * float(i) / 100.0) * 0.5
	t._samples[1] = {"data": BgmVoices.pad_sample(sine, loops, 0), "loop_on": loops, "loop_start": 0, "loop_end": 4410}
	var tone := {"min": 0, "max": 127, "vol": 127, "pan": 64, "center": 60, "shift": 0, "pbmin": 0, "pbmax": 0,
			"adsr1": adsr1, "adsr2": adsr2, "vag": 1}
	t._programs[0] = {"mvol": 127, "mpan": 64, "tones": [tone]}
	return t


func make_player(track: BgmTrack) -> BgmPlayer:
	var player := BgmPlayer.new()
	player.voices = BgmVoices.new()
	player.seq = BgmSequencer.new(player.voices)
	player.track = track
	player.track_id = 0
	player.seq.start(track)
	return player


## Advance in sample steps until `done` is true or the limit is reached. Returns the samples advanced.
func run_until(player: BgmPlayer, limit_samples: int, done: Callable) -> int:
	var total := 0
	while total < limit_samples and not done.call():
		player.advance(64)
		total += 64
	return total


# ---- synthetic checks ----------------------------------------------------------------------------------------------------

func _test_pitch_table() -> void:
	var player := BgmPlayer.new()
	player.voices = BgmVoices.new()
	player.seq = BgmSequencer.new(player.voices)
	var track := make_track(seq_chunk(0x60, 500000, [0, 0x90, 69, 100, 0x00, 0x80, 69, 0, 0, 0xFF, 0x2F, 0]))
	player.track = track
	player.seq.start(track)
	# note 69 over centre 60 is nine semitones up: 4096 * 2^(9/12) = 6889
	var p: int = player.seq.pitch_value(69, 0, 60, 0)
	check("pitch of A4 over centre C4 is 4096 * 2^(9/12)", absi(p - 6889) <= 2)
	var q: int = player.seq.pitch_value(48, 0, 60, 0)
	check("pitch of an octave down is half the native rate", q == 2048)
	var r: int = player.seq.pitch_value(60, 0, 60, 0)
	check("centre note plays at the native rate", r == 4096)
	player.free()


func _test_timing_and_note() -> void:
	# tempo 500000 (120 BPM) at timebase 96: a quarter (96 ticks) is 120 units, so the note lasts 0.5 s.
	var track := make_track(seq_chunk(0x60, 500000, [0, 0x90, 60, 100, 0x60, 0x80, 60, 0, 0, 0xFF, 0x2F, 0]))
	var player := make_player(track)
	var on_at := -1
	var off_at := -1
	var t := 0
	while t < RATE * 3 and off_at < 0:
		player.advance(16)
		t += 16
		if on_at < 0 and player.seq.stats["note_on"] > 0:
			on_at = t
		if off_at < 0 and player.seq.stats["note_off"] > 0:
			off_at = t
	check("the first note starts at the first event", on_at >= 0 and on_at <= 200)
	var span := float(off_at - on_at) / RATE
	check("a quarter note at 120 BPM lasts 0.5 s (measured %.3f s)" % span, absf(span - 0.5) < 0.02)
	check("the track ends after its end-of-track event", player.seq.ended)
	player.free()


func _test_running_status() -> void:
	# note on C4, delta, then running status for D4 on, C4 off (vel 0), D4 off (vel 0)
	var track := make_track(seq_chunk(0x60, 500000, [0, 0x90, 60, 64, 0x30, 62, 64, 0x30, 60, 0, 0x30, 62, 0,
			0, 0xFF, 0x2F, 0]))
	var player := make_player(track)
	run_until(player, RATE * 3, func(): return not player.seq.is_playing())
	check("running status: two notes on", player.seq.stats["note_on"] == 2)
	check("running status: two notes off", player.seq.stats["note_off"] == 2)
	check("running status: no note left sounding", player.seq.held_notes() == 0)
	player.free()


func _test_loop() -> void:
	# an uncounted loop round one note: the sequence never reaches its end-of-track, so the notes keep coming
	var track := make_track(seq_chunk(0x60, 500000, [0, 0xB0, 0x63, 0x14, 0, 0x90, 60, 64, 0x30, 0x80, 60, 0, 0x10,
			0xB0, 0x63, 0x1E, 0, 0xFF, 0x2F, 0]))
	var player := make_player(track)
	player.advance(RATE * 4)
	check("an uncounted loop repeats its body (%d notes in 4 s)" % player.seq.stats["note_on"],
			player.seq.stats["note_on"] >= 6)
	check("the loop does not end the track", player.seq.is_playing())
	player.free()


func _test_fade() -> void:
	var track := make_track(seq_chunk(0x60, 500000, [0, 0xB0, 0x63, 0x14, 0, 0x90, 60, 64, 0x30, 0x80, 60, 0, 0x10,
			0xB0, 0x63, 0x1E, 0, 0xFF, 0x2F, 0]))
	var player := make_player(track)
	player.advance(RATE)
	var before: int = player.seq.master_l
	player.seq.fade_out(8)
	player.advance(RATE)           # 60 ticks of the fade: 255 / 8 = 32 needed
	check("a fade-out takes the music level to zero", player.seq.fade_level <= 0 and player.seq.master_l == 0)
	check("the level was up before the fade (%d)" % before, before > 0)
	player.free()


func _test_end_of_track() -> void:
	var track := make_track(seq_chunk(0x60, 500000, [0, 0x90, 60, 64, 0x60, 0x80, 60, 0, 0, 0xFF, 0x2F, 0]))
	var player := make_player(track)
	player.advance(RATE * 4)
	check("the track ends and the music stops", not player.seq.is_playing())
	check("every voice is silent after the end", not player._any_voice())
	check("no note is left sounding at the end", player.seq.held_notes() == 0)
	player.free()


func _test_envelope_status() -> void:
	var voices := BgmVoices.new()
	var sample := PackedFloat32Array()
	sample.resize(44100)
	sample.fill(0.25)
	sample = BgmVoices.pad_sample(sample, true, 0)
	voices.key_on(0, sample, true, 0, 44100, 4096, 20000, 20000, 0x0000, 0x000A)
	var out_l := PackedFloat32Array()
	var out_r := PackedFloat32Array()
	out_l.resize(4096)
	out_r.resize(4096)
	voices.mix(out_l, out_r, 0, 4096)
	check("a keyed voice reports on", voices.status(0) == BgmVoices.STATUS_ON)
	voices.key_off(0)
	var released := false
	for i in 40:
		voices.mix(out_l, out_r, 0, 1024)
		if voices.status(0) == BgmVoices.STATUS_OFF:
			released = true
			break
	check("a released voice falls to off once its envelope ends", released)


func _test_render_non_silent() -> void:
	var track := make_track(seq_chunk(0x60, 500000, [0, 0xB0, 0x63, 0x14, 0, 0x90, 60, 100, 0x30, 0x80, 60, 0, 0x10,
			0xB0, 0x63, 0x1E, 0, 0xFF, 0x2F, 0]))
	var player := make_player(track)
	var frames := player.render(RATE)
	var energy := 0.0
	var finite := true
	for f in frames:
		energy += f.x * f.x + f.y * f.y
		if is_nan(f.x) or is_nan(f.y) or is_inf(f.x) or is_inf(f.y):
			finite = false
	check("a second of rendered audio is not silent (rms %.4f)" % sqrt(energy / float(frames.size() * 2)),
			energy > 0.0001)
	check("rendered samples are finite", finite)
	player.free()


func _test_missing_track() -> void:
	var player := BgmPlayer.new()
	var found := player.play(0x0FFF)
	check("a track id the data lacks is ignored", not found and not player.is_playing())
	player.free()


# ---- exported data -------------------------------------------------------------------------------------------------------

func _test_data_tracks() -> void:
	var dir := DirAccess.open(DATA_ROOT)
	if dir == null:
		print("SKIP  no exported tracks at ", DATA_ROOT, " (run tools/extract.py --audio)")
		return
	var keys: Array = []
	for name in dir.get_directories():
		if name.length() == 3 and name.is_valid_hex_number():
			keys.append(name)
	keys.sort()
	if keys.is_empty():
		print("SKIP  no track folders in ", DATA_ROOT)
		return
	for key in keys:
		var id: int = key.hex_to_int()
		var track = BgmTrack.open(id)
		if track == null:
			check("track %s opens" % key, false)
			continue
		data_tracks += 1
		var player := make_player(track)
		var started: bool = player.seq.is_playing()
		check("track %s starts" % key, started)
		if not started:
			player.free()
			continue
		var limit := int(DATA_LIMIT_SECONDS * RATE)
		var elapsed := 0
		var chunk := RATE / 10
		while player.seq.is_playing() and elapsed < limit:
			player.advance(chunk)
			elapsed += chunk
		var seconds := float(elapsed) / RATE
		var stats: Dictionary = player.seq.stats
		var ended: bool = not player.seq.is_playing()
		var kind := "ends at %.1f s" % seconds if ended else "loops (no end in %.0f s)" % DATA_LIMIT_SECONDS
		print("INFO  track %s %s: %d notes on, %d off, %d no-program, %d no-tone, %d steals, %d steps, %d sounding at the end"
				% [key, kind, stats["note_on"], stats["note_off"], stats["no_program"], stats["no_tone"], stats["steal"],
				stats["steps"], player.seq.held_notes()])
		check("track %s: the sequence runs (%d steps)" % [key, stats["steps"]], stats["steps"] > 0)
		if ended:
			check("track %s: no note is left sounding at the end" % key, player.seq.held_notes() == 0)
			check("track %s: the duration is plausible (%.1f s)" % [key, seconds], seconds >= 2.0)
		player.free()
		var fresh := make_player(BgmTrack.open(id))
		var frames := fresh.render(3 * RATE)
		var energy := 0.0
		var peak := 0.0
		var finite := true
		for f in frames:
			energy += f.x * f.x + f.y * f.y
			peak = maxf(peak, maxf(absf(f.x), absf(f.y)))
			if is_nan(f.x) or is_nan(f.y):
				finite = false
		var rms := sqrt(energy / float(frames.size() * 2))
		check("track %s: three seconds render non-silent (rms %.4f, peak %.3f)" % [key, rms, peak], rms > 0.0005)
		check("track %s: rendered samples are finite" % key, finite)
		fresh.free()
