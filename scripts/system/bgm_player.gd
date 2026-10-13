extends Node
## The background music player: plays the game's tracks (assets/audio/bgm/<key>/, see bgm_track.gd) through the software
## sequencer (bgm_sequencer.gd) and the 20 music voices (bgm_voices.gd), into an AudioStreamGenerator.
##
## Rendering is done on the main thread in small slices (the web build is single-threaded): _process pushes at most MAX_SLICE
## frames a frame until the generator's buffer is full. The sequencer runs at the driver's own rate (590.625 steps a second)
## and the fades at 60 a second, both counted in output samples, so the music keeps its timing whatever the frame rate.
## Track ids the data does not have are ignored: the current track keeps playing.

const BgmVoices := preload("res://scripts/system/bgm_voices.gd")
const BgmSequencer := preload("res://scripts/system/bgm_sequencer.gd")
const BgmTrack := preload("res://scripts/system/bgm_track.gd")

const RATE := 44100
## Whether a track is playing (SD status bit 0x80): the duel result outro waits on it.
static var playing := false
const CALLS_NUM := 590625          # sequencer steps per second, times 1000 (590.625)
const FADE_PER_SECOND := 60
const BUFFER_SECONDS := 0.25
const MAX_SLICE := 4096            # frames rendered per _process call at most

var voices
var seq
var track = null
var track_id := -1
var _t := 0                        # output samples since the track started
var _call_index := 0               # sequencer steps since the track started
var _fade_index := 0               # fade ticks since the track started
var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _generator: AudioStreamGenerator
var _running := false              # the generator is playing (a track or a release tail is sounding)


func _init() -> void:
	voices = BgmVoices.new()
	seq = BgmSequencer.new(voices)


func _ready() -> void:
	_generator = AudioStreamGenerator.new()
	_generator.mix_rate = RATE
	_generator.buffer_length = BUFFER_SECONDS
	_player = AudioStreamPlayer.new()
	_player.stream = _generator
	_player.volume_db = 0.0
	add_child(_player)


## Start track `id` (the game's 16-bit id). Returns false, changing nothing, when the data has no such track.
func play(id: int) -> bool:
	var next = BgmTrack.open(id)
	if next == null:
		return false
	track = next
	track_id = id
	if not seq.start(track):
		return false
	_t = 0
	_call_index = 0
	_fade_index = 0
	_start_output()
	playing = seq.is_playing()
	return true


## Stop at once (the driver's stop: no fade).
func stop() -> void:
	seq.stop()
	playing = false
	track = null
	track_id = -1
	_stop_output()


## Fade the playing track out. `step` is the driver's fade step (per 60 Hz tick, out of 255): 8 is the default.
func fade_out(step: int) -> void:
	if track == null:
		return
	seq.fade_out(step)


func set_panning(enabled: bool) -> void:
	seq.panning = enabled


func is_playing() -> bool:
	return seq.is_playing()


## Whether a BGM fade-out is running.
func is_fading() -> bool:
	return seq.fade_step != 0


## Render `count` stereo frames (used by the output and by the tests).
func render(count: int) -> PackedVector2Array:
	var out_l := PackedFloat32Array()
	var out_r := PackedFloat32Array()
	out_l.resize(count)
	out_r.resize(count)
	out_l.fill(0.0)
	out_r.fill(0.0)
	_run(count, out_l, out_r)
	var frames := PackedVector2Array()
	frames.resize(count)
	for i in count:
		frames[i] = Vector2(out_l[i], out_r[i])
	return frames


## Advance the sequencer and the fades by `count` samples without mixing (the tests run a whole track this way).
func advance(count: int) -> void:
	_run(count, null, null)


func _run(count: int, out_l, out_r) -> void:
	var done := 0
	while done < count:
		var next_call := _boundary(_call_index + 1)
		var next_fade := (_fade_index + 1) * RATE / FADE_PER_SECOND
		var next_event := mini(next_call, next_fade)
		var seg := mini(count - done, next_event - _t)
		if seg > 0:
			if out_l != null:
				if _any_voice():
					voices.mix(out_l, out_r, done, seg)
			else:
				voices.step(seg)
		_t += seg
		done += seg
		if _t >= next_call:
			seq.call_step()
			_call_index += 1
		if _t >= next_fade:
			seq.fade_tick()
			_fade_index += 1
			if seq.active and seq.ended:
				seq.finish()
			if not seq.active and seq.volume_level <= 0:
				voices.kill_all()
			playing = seq.is_playing()


func _process(_delta: float) -> void:
	if not _running or _playback == null:
		return
	if not seq.active and not _any_voice():
		_stop_output()
		return
	var room := _playback.get_frames_available()
	var want := mini(room, MAX_SLICE)
	if want > 0:
		_playback.push_buffer(render(want))


func _start_output() -> void:
	_player.play()
	_playback = _player.get_stream_playback()
	_running = true


func _stop_output() -> void:
	_player.stop()
	_playback = null
	_running = false


func _any_voice() -> bool:
	for v in voices.voice_list:
		if v.running:
			return true
	return false


## The output sample index at which sequencer step k (1-based) happens.
func _boundary(k: int) -> int:
	return k * RATE * 1000 / CALLS_NUM
