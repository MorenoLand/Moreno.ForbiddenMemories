@warning_ignore_start("integer_division")
class_name MDEC
extends RefCounted
## PlayStation MDEC (motion decoder) emulation: version 2 bitstream -> RGB8.

# MPEG-1 DCT run/level VLC (codes without sign bit), 111 entries, then escape and EOB.
const _RL_CODE := [0x3, 0x4, 0x5, 0x6, 0x26, 0x21, 0xa, 0x1d, 0x18, 0x13, 0x10, 0x1a, 0x19, 0x18, 0x17, 0x1f,
	0x1e, 0x1d, 0x1c, 0x1b, 0x1a, 0x19, 0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, 0x10, 0x18,
	0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, 0x10, 0x3, 0x6, 0x25, 0xc, 0x1b, 0x16, 0x15, 0x1f,
	0x1e, 0x1d, 0x1c, 0x1b, 0x1a, 0x19, 0x13, 0x12, 0x11, 0x10, 0x5, 0x4, 0xb, 0x14, 0x14, 0x7,
	0x24, 0x1c, 0x13, 0x6, 0xf, 0x12, 0x7, 0x9, 0x12, 0x5, 0x1e, 0x14, 0x4, 0x15, 0x7, 0x11,
	0x5, 0x11, 0x27, 0x10, 0x23, 0x1a, 0x22, 0x19, 0x20, 0x18, 0xe, 0x17, 0xd, 0x16, 0x8, 0x15,
	0x1f, 0x1a, 0x19, 0x17, 0x16, 0x1f, 0x1e, 0x1d, 0x1c, 0x1b, 0x1f, 0x1e, 0x1d, 0x1c, 0x1b]
const _RL_LEN := [2, 4, 5, 7, 8, 8, 10, 12, 12, 12, 12, 13, 13, 13, 13, 14,
	14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 15,
	15, 15, 15, 15, 15, 15, 15, 15, 3, 6, 8, 10, 12, 13, 13, 15,
	15, 15, 15, 15, 15, 15, 16, 16, 16, 16, 4, 7, 10, 12, 13, 5,
	8, 12, 13, 5, 10, 12, 6, 10, 13, 6, 12, 16, 6, 12, 7, 12,
	7, 13, 8, 13, 8, 16, 8, 16, 8, 16, 10, 16, 10, 16, 10, 16,
	12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 16, 16, 16, 16, 16]
const _RL_RUN := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3,
	3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 8, 8,
	9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
	17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31]
const _RL_LEVEL := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
	17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
	33, 34, 35, 36, 37, 38, 39, 40, 1, 2, 3, 4, 5, 6, 7, 8,
	9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 1,
	2, 3, 4, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 1, 2,
	1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]

const _ESC := 111
const _EOB := 112

const _ZIGZAG := [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

# Default intra quantiser matrix (raster order). Games may load their own; this is the standard default.
const _QUANT := [2, 16, 19, 22, 26, 27, 29, 34, 16, 16, 22, 24, 27, 29, 34, 37,
	19, 22, 26, 27, 29, 34, 34, 38, 22, 22, 26, 27, 29, 34, 37, 40,
	22, 26, 27, 29, 32, 35, 40, 48, 26, 27, 29, 32, 35, 40, 48, 58,
	26, 27, 29, 34, 38, 46, 56, 69, 27, 29, 35, 38, 46, 56, 69, 83]

static var _ready := false
static var _lut := PackedInt32Array()     # 16-bit peek -> VLC entry index
static var _len := PackedInt32Array()     # entry index -> code length
static var _run := PackedInt32Array()
static var _level := PackedInt32Array()
static var _cos := PackedFloat32Array()   # _cos[u * 8 + x] = C(u) / 2 * cos((2x + 1) u pi / 16)


static func _setup() -> void:
	if _ready:
		return
	_ready = true
	_lut.resize(65536)
	_lut.fill(_EOB)
	_len.resize(113)
	_run.resize(113)
	_level.resize(113)
	var codes: Array = _RL_CODE + [1, 2]
	var lens: Array = _RL_LEN + [6, 2]
	for i in 113:
		var length: int = lens[i]
		var shift := 16 - length
		var base: int = int(codes[i]) << shift
		for j in 1 << shift:
			_lut[base + j] = i
		_len[i] = length
		if i < 111:
			_run[i] = _RL_RUN[i]
			_level[i] = _RL_LEVEL[i]
	_cos.resize(64)
	for u in 8:
		var cu := 1.0 / sqrt(2.0) if u == 0 else 1.0
		for x in 8:
			_cos[u * 8 + x] = cu * 0.5 * cos((2 * x + 1) * u * PI / 16.0)


static func _u16(bs: PackedByteArray, i: int) -> int:
	var lo: int = bs[i] if i < bs.size() else 0
	var hi: int = bs[i + 1] if i + 1 < bs.size() else 0
	return lo | (hi << 8)


## Peek 16 bits at bit position pos; the bitstream is little-endian 16-bit words read MSB first.
static func _peek16(bs: PackedByteArray, pos: int) -> int:
	var w := (pos >> 4) * 2
	var v := (_u16(bs, w) << 16) | _u16(bs, w + 2)
	return (v >> (16 - (pos & 15))) & 0xFFFF


static func _read_block(bs: PackedByteArray, pos: int, qscale: int, coef: PackedInt32Array) -> int:
	var dc := _peek16(bs, pos) >> 6
	pos += 10
	if dc >= 512:
		dc -= 1024
	coef[0] = dc * _QUANT[0]
	var k := 1
	while k < 64:
		var e := _lut[_peek16(bs, pos)]
		pos += _len[e]
		if e == _EOB:
			break
		var level: int
		if e == _ESC:
			k += _peek16(bs, pos) >> 10
			pos += 6
			level = _peek16(bs, pos) >> 6
			pos += 10
			if level >= 512:
				level -= 1024
		else:
			k += _run[e]
			level = _level[e]
			if _peek16(bs, pos) & 0x8000:
				level = -level
			pos += 1
		if k >= 64:
			break
		var r: int = _ZIGZAG[k]
		coef[r] = (level * qscale * _QUANT[r] + 4) >> 3
		k += 1
	return pos


static func _idct(coef: PackedInt32Array, out: PackedFloat32Array, tmp: PackedFloat32Array) -> void:
	var has_ac := false
	for i in range(1, 64):
		if coef[i] != 0:
			has_ac = true
			break
	if not has_ac:
		out.fill(coef[0] / 8.0)
		return
	for v in 8:
		for x in 8:
			var s := 0.0
			for u in 8:
				s += _cos[u * 8 + x] * coef[v * 8 + u]
			tmp[v * 8 + x] = s
	for y in 8:
		for x in 8:
			var s := 0.0
			for v in 8:
				s += _cos[v * 8 + y] * tmp[v * 8 + x]
			out[y * 8 + x] = s


static func _store(src: PackedFloat32Array, dst: PackedByteArray, stride: int, x0: int, y0: int) -> void:
	for y in 8:
		var row := (y0 + y) * stride + x0
		for x in 8:
			dst[row + x] = clampi(roundi(src[y * 8 + x]) + 128, 0, 255)


## Decode one frame. The bitstream starts with the 8-byte MDEC frame header
## (run-length word count, 0x3800, quantiser scale, version), followed by macroblock data.
static func decode_frame(bitstream: PackedByteArray, width: int, height: int) -> PackedByteArray:
	return decode_frame_ex(bitstream, width, height)["rgb"]


## Same as decode_frame, also returning the bit position where decoding stopped and the header fields.
static func decode_frame_ex(bitstream: PackedByteArray, width: int, height: int) -> Dictionary:
	_setup()
	var mbw := (width + 15) >> 4
	var mbh := (height + 15) >> 4
	var aw := mbw * 16
	var ah := mbh * 16
	var cw := aw >> 1
	var qscale := _u16(bitstream, 4)
	var version := _u16(bitstream, 6)
	# Version 3 streams use differential DC coding (DC predicted from the previous block of the same
	# component); not implemented here. Only version 2 (plain 10-bit DC) is decoded correctly.
	var yp := PackedByteArray()
	yp.resize(aw * ah)
	var cbp := PackedByteArray()
	cbp.resize(cw * (ah >> 1))
	var crp := PackedByteArray()
	crp.resize(cw * (ah >> 1))
	var coef := PackedInt32Array()
	coef.resize(64)
	var blk := PackedFloat32Array()
	blk.resize(64)
	var tmp := PackedFloat32Array()
	tmp.resize(64)
	var pos := 64
	for mb in mbw * mbh:
		# the MDEC emits macroblocks column by column
		var mx := (mb / mbh) * 16
		var my := (mb % mbh) * 16
		for b in 6:
			coef.fill(0)
			pos = _read_block(bitstream, pos, qscale, coef)
			_idct(coef, blk, tmp)
			if b < 2:
				_store(blk, crp if b == 0 else cbp, cw, mx >> 1, my >> 1)
			else:
				var ox := ((b - 2) & 1) * 8
				var oy := ((b - 2) >> 1) * 8
				_store(blk, yp, aw, mx + ox, my + oy)
	var rgb := PackedByteArray()
	rgb.resize(width * height * 3)
	for py in height:
		for px in width:
			var yy := float(yp[py * aw + px])
			var ci := (py >> 1) * cw + (px >> 1)
			var cb := float(cbp[ci]) - 128.0
			var cr := float(crp[ci]) - 128.0
			var o := (py * width + px) * 3
			rgb[o] = clampi(roundi(yy + 1.402 * cr), 0, 255)
			rgb[o + 1] = clampi(roundi(yy - 0.344136 * cb - 0.714136 * cr), 0, 255)
			rgb[o + 2] = clampi(roundi(yy + 1.772 * cb), 0, 255)
	return {"rgb": rgb, "end_bit": pos, "qscale": qscale, "version": version}
