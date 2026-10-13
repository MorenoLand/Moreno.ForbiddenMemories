extends RefCounted
## The music voices: the software mixer behind the background music. One voice per secondary sound object (20 of them, the
## SPU voices 0 to 19; the four effect slots are not part of the music). A voice plays one decoded VAG sample (mono, 44100
## Hz, as floats from -1 to 1) at a pitch register value (0x1000 is the sample's own rate), through the PS1 ADSR envelope of
## the tone's ADSR1 and ADSR2 words, at a left and right gain (the SPU voice volume, 0 to 0x7FFF). A looping sample repeats
## between its loop points; a sample without a loop stops at its end.
##
## Sample data carries one extra element after its last sample (pad_sample adds it), so the interpolation never checks a
## bound. The envelope follows the hardware's register layout: ADSR1 holds the sustain level (bits 0-3), the decay shift
## (4-7), the attack step and shift (8-14) and the attack mode (15); ADSR2 holds the release shift (0-4), the release mode (5),
## the sustain step and shift (6-12), the sustain direction (14) and the sustain mode (15). Rates follow the hardware's
## shift-and-step rule; they approximate it rather than copy it bit for bit. Inside one mixed block the envelope is a straight
## ramp between its values at the block's two ends.
##
## Key status (what the sequencer reads, SPU codes): 0 off, 1 on, 2 released but still sounding, 3 keyed on with the
## envelope at zero.

const VOICES := 20
const ENV_MAX := 32767.0
const INV_ENV := 1.0 / 32767.0
const PHASE_IDLE := 0
const PHASE_ATTACK := 1
const PHASE_DECAY := 2
const PHASE_SUSTAIN := 3
const PHASE_RELEASE := 4
const STATUS_OFF := 0
const STATUS_ON := 1
const STATUS_OFF_ENV_ON := 2
const STATUS_ON_ENV_OFF := 3

var voice_list: Array = []


## One voice's state. The mixer reads these fields once per block, so they are plain fields.
class Voice:
	var data: PackedFloat32Array = PackedFloat32Array()   # the sample plus one pad element
	var count := 0                # samples (data.size() - 1)
	var loop_on := false
	var loop_start := 0
	var loop_end := 0
	var pos := 0.0
	var step := 0.0
	var gain_l := 0.0             # SPU volume register / 16384: the hardware doubles the 15-bit register (reference SPU volume()), the master 0x3FFF is x1
	var gain_r := 0.0
	var env := 0.0                # 0 to 32767
	var phase := PHASE_IDLE
	var keyed := false
	var running := false
	var attack_rate := 0.0        # env change per sample while attacking (linear)
	var attack_exp := false
	var decay_k := 0.0            # decay multiplier per sample is (1 - decay_k)
	var sustain_level := 0.0
	var sustain_rate := 0.0       # env change per sample in sustain (linear)
	var sustain_exp := false
	var sustain_k := 0.0          # exp sustain: the gap to the end level shrinks by (1 - sustain_k) per sample
	var sustain_up := true
	var release_rate := 0.0       # env change per sample while releasing (linear, negative)
	var release_exp := false
	var release_k := 0.0          # exp release multiplier per sample is (1 - release_k)


func _init() -> void:
	for i in VOICES:
		voice_list.append(Voice.new())


## Hardware rate: a step of `step` each cycle, cycles of 2^(shift - 11) samples (shorter for small shifts). Per sample.
static func linear_rate(shift: int, step: int) -> float:
	var up := 11 - shift
	if up >= 0:
		return float(step << up)
	return float(step) / float(1 << (-up))


## Exponential rate: the fraction of the level that changes per sample at the given shift (step 8).
static func exp_fraction(shift: int) -> float:
	return (8.0 / 32768.0) * linear_rate(shift, 1)


## Pad a sample for the mixer: one extra element after its end (the loop's first sample, or silence).
static func pad_sample(samples: PackedFloat32Array, loop_on: bool, loop_start: int) -> PackedFloat32Array:
	var out := samples.duplicate()
	if out.size() == 0:
		out.append(0.0)
	else:
		out.append(samples[loop_start] if loop_on and loop_start < samples.size() else 0.0)
	return out


## Start a voice on a padded sample with the given pitch register value and gains, through the tone's envelope words.
func key_on(index: int, data: PackedFloat32Array, loop_on: bool, loop_start: int, loop_end: int, pitch: int,
		vol_l: int, vol_r: int, adsr1: int, adsr2: int) -> void:
	var v: Voice = voice_list[index]
	v.data = data
	v.count = maxi(data.size() - 1, 0)
	v.loop_on = loop_on and loop_end > loop_start and loop_end <= v.count
	v.loop_start = loop_start
	v.loop_end = loop_end if v.loop_on else v.count
	v.pos = 0.0
	v.step = float(pitch) / 4096.0
	v.gain_l = float(vol_l) / 16384.0
	v.gain_r = float(vol_r) / 16384.0
	v.env = 0.0
	v.keyed = true
	v.running = v.count > 0
	v.phase = PHASE_ATTACK if v.running else PHASE_IDLE
	var ar := (adsr1 >> 8) & 0x7F
	v.attack_exp = (adsr1 & 0x8000) != 0
	v.attack_rate = linear_rate(ar >> 2, 7 - (ar & 3))
	var dr := (adsr1 >> 4) & 0xF
	v.decay_k = exp_fraction(dr)
	v.sustain_level = float(((adsr1 & 0xF) + 1) * 0x800)
	var sr := (adsr2 >> 6) & 0x7F
	v.sustain_up = (adsr2 & 0x4000) == 0
	v.sustain_exp = (adsr2 & 0x8000) != 0
	# the hardware steps 7 - (rate & 3) up and -8 + (rate & 3) down (the reference SPU envelope)
	v.sustain_rate = linear_rate(sr >> 2, (7 - (sr & 3)) if v.sustain_up else (-8 + (sr & 3)))
	v.sustain_k = exp_fraction(sr >> 2)
	var rr := adsr2 & 0x1F
	v.release_exp = (adsr2 & 0x20) != 0
	v.release_rate = linear_rate(rr, -8)
	v.release_k = exp_fraction(rr)


func key_off(index: int) -> void:
	var v: Voice = voice_list[index]
	v.keyed = false
	if v.running and v.phase != PHASE_RELEASE:
		v.phase = PHASE_RELEASE


## Silence every voice at once (used when a track has finished and its level has faded to nothing).
func kill_all() -> void:
	for v: Voice in voice_list:
		v.running = false
		v.keyed = false
		v.phase = PHASE_IDLE
		v.env = 0.0


func is_running(index: int) -> bool:
	return voice_list[index].running


func set_volume(index: int, vol_l: int, vol_r: int) -> void:
	var v: Voice = voice_list[index]
	v.gain_l = float(vol_l) / 16384.0
	v.gain_r = float(vol_r) / 16384.0


func set_pitch(index: int, pitch: int) -> void:
	voice_list[index].step = float(pitch) / 4096.0


## The SPU key status the sequencer reads (see the header comment).
func status(index: int) -> int:
	var v: Voice = voice_list[index]
	if not v.running:
		return STATUS_OFF
	if v.keyed:
		return STATUS_ON if v.env > 0.0 else STATUS_ON_ENV_OFF
	return STATUS_OFF_ENV_ON if v.env > 0.0 else STATUS_OFF


## Mix `count` output samples into out_l and out_r from `start`, adding every running voice.
func mix(out_l: PackedFloat32Array, out_r: PackedFloat32Array, start: int, count: int) -> void:
	for v: Voice in voice_list:
		if v.running:
			_mix_voice(v, out_l, out_r, start, count)


## Advance every voice by `n` samples without producing output (the sequencer-only path, used by the tests). The position and
## the envelope move as they do in mix().
func step(n: int) -> void:
	for v: Voice in voice_list:
		if v.running:
			_advance_position(v, n)
			_advance_env(v, float(n))


func _advance_position(v: Voice, n: int) -> void:
	v.pos += v.step * float(n)
	if v.loop_on:
		if v.pos >= float(v.loop_end):
			v.pos = float(v.loop_start) + fmod(v.pos - float(v.loop_start), float(v.loop_end - v.loop_start))
	elif v.pos >= float(v.count):
		v.running = false
		v.phase = PHASE_IDLE


## Advance the envelope of `v` by `n` samples, in closed form per phase. Returns the envelope at the end (0 to 32767).
func _advance_env(v: Voice, n: float) -> float:
	var left := n
	var guard := 0
	while left > 0.0 and v.running and guard < 8:
		guard += 1
		match v.phase:
			PHASE_ATTACK:
				var r := v.attack_rate
				if v.attack_exp and v.env > 24576.0:
					r *= 0.25
				if r <= 0.0:
					left = 0.0
				else:
					var need := (ENV_MAX - v.env) / r
					if need <= left:
						v.env = ENV_MAX
						left -= need
						v.phase = PHASE_DECAY
					else:
						v.env += r * left
						left = 0.0
			PHASE_DECAY:
				if v.env <= v.sustain_level:
					v.env = v.sustain_level
					v.phase = PHASE_SUSTAIN
				elif v.decay_k <= 0.0:
					left = 0.0
				else:
					var k := 1.0 - v.decay_k
					var after := v.env * pow(k, left)
					if after <= v.sustain_level:
						left -= log(v.sustain_level / v.env) / log(k)
						v.env = v.sustain_level
						v.phase = PHASE_SUSTAIN
					else:
						v.env = after
						left = 0.0
			PHASE_SUSTAIN:
				if v.sustain_exp and v.sustain_k > 0.0:
					if v.sustain_up:
						v.env = ENV_MAX - (ENV_MAX - v.env) * pow(1.0 - v.sustain_k, left)
					else:
						v.env = v.env * pow(1.0 - v.sustain_k, left)
				else:
					v.env += v.sustain_rate * left
				v.env = clampf(v.env, 0.0, ENV_MAX)
				left = 0.0
			PHASE_RELEASE:
				if v.release_exp and v.release_k > 0.0:
					v.env = v.env * pow(1.0 - v.release_k, left)
				else:
					v.env += v.release_rate * left
				left = 0.0
				if v.env <= 0.5:
					v.env = 0.0
					v.phase = PHASE_IDLE
					v.running = false
			_:
				left = 0.0
	return v.env


func _mix_voice(v: Voice, out_l: PackedFloat32Array, out_r: PackedFloat32Array, start: int, count: int) -> void:
	var data := v.data
	var env0 := v.env
	var env1 := _advance_env(v, float(count))
	var env := env0 * INV_ENV
	var d_env := (env1 - env0) * INV_ENV / float(count)
	var gl := v.gain_l
	var gr := v.gain_r
	var pos := v.pos
	var step := v.step
	var loop_on := v.loop_on
	var limit := float(v.loop_end) if loop_on else float(v.count)
	var loop_len := float(v.loop_end - v.loop_start)
	var i := start
	var stop := start + count
	var ended := false
	while i < stop:
		var idx := int(pos)
		var a: float = data[idx]
		var s := a + (data[idx + 1] - a) * (pos - float(idx))
		var amp := s * env
		out_l[i] += amp * gl
		out_r[i] += amp * gr
		pos += step
		env += d_env
		i += 1
		if pos >= limit:
			if loop_on:
				pos -= loop_len
			else:
				ended = true
				break
	v.pos = pos
	if ended:
		v.running = false
		v.phase = PHASE_IDLE
		v.env = 0.0
