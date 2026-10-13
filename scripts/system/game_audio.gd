extends Node
## Plays the game's sound effects (the SE play ids) from assets/audio/se/NNN.wav, written by tools/extract.py --audio, and the
## background music (the BGM play, fade and stop calls; see bgm_player.gd). Effects load on first use. Nothing plays when the
## files are missing; a music id the data does not have is ignored.

const DIR := "res://assets/audio/se/"
const VOICES := 8
const BgmPlayer := preload("res://scripts/system/bgm_player.gd")

## the sound output type: true for mono. The game's mono output turns off the secondary panning (the secondary panning disable, which
## forces the centre pan in the secondary object spatialization). The menu effects are mono samples played centred in both modes,
## so this flag changes nothing audible for them yet; it is kept in step with the saved output type.
static var mono := false

## The last BGM play command, as the driver keeps it (the id with the 0x7000 class base): the story's F8 0F "copy" saves it.
static var current_bgm_command := 0

var streams: Dictionary = {}
var players: Array = []
var next := 0
var bgm
## The duel's track: set by the campaign duel start and the free duel, played when a duel starts.
var duel_bgm := 0x7270


func _ready() -> void:
	for i in VOICES:
		var player := AudioStreamPlayer.new()
		add_child(player)
		players.append(player)
	bgm = BgmPlayer.new()
	add_child(bgm)
	bgm.set_panning(not mono)


## BGM play: start track `id`, restarting it even when it is already playing. Unknown ids change nothing.
func play_bgm(id: int) -> void:
	var value := id & 0xFFFF
	current_bgm_command = value | 0x7000
	bgm.set_panning(not mono)
	bgm.play(value)


## BGM fade-out.
func fade_bgm(step: int) -> void:
	bgm.fade_out(8 if step == 0 else step)


## The duel's track: played when a duel starts (duel_phase_entry).
func play_duel_bgm() -> void:
	play_bgm(duel_bgm)


## Whether a BGM fade-out is running.
func is_bgm_fading() -> bool:
	return bgm.is_fading()


## BGM stop (the driver's immediate stop).
func stop_bgm() -> void:
	bgm.stop()


func play_se(id: int) -> void:
	if not streams.has(id):
		var path := DIR + "%03d.wav" % id
		streams[id] = AudioStreamWAV.load_from_file(path) if FileAccess.file_exists(path) else null
	var stream = streams[id]
	if stream == null:
		return
	var player: AudioStreamPlayer = players[next]
	next = (next + 1) % VOICES
	player.stream = stream
	player.play()
