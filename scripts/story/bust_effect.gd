## The speaker busts of the story: the display effect of ids 1 to 0x40 (the dialog's F6 command and the show-menu opcode).
## A bust is two records, one per slot (left and right). A record owns four rows of three layers: row 0 is the bust as it is
## shown (the body, the eyes that blink, the mouth that talks); rows 1 to 3 are the copies the fades and the expression change
## draw with. Each layer plays its stream of frames (baked by tools/extract.py, the bank of holds, jumps and stops) and the
## record's step runs the slide in and out, the fade in and out and the expression change. The blink and the mouth are driven
## once a tick while a dialog or a show-menu opcode runs; the layers play on every tick. Ticks are 60 a second.
class_name BustEffect
extends RefCounted

const DIR := "res://assets/screens/story/busts/"
const ModArt := preload("res://scripts/system/mod_art.gd")
const SHADER := "res://shaders/bust_layer.gdshader"
const TICK := 1.0 / 60.0
const SLOT_X := [0x68, 0xD8]          # the resting x of the left and right slot
const SLOT_OFF := [-0x38, 0x178]      # where a bust slides in from and out to
const BUST_Y := 0xB2
const QUARTER := 0x400                # a quarter turn in the cosine's units (4096 to a full turn)
const ONE := 4096
const NEUTRAL := 0x80                 # a colour multiplier of 1.0
const BLINK_BASE := 60                # the blink's random delay: 60 to 315 ticks
const BLINK_MASK := 0xFF
const MOUTH_HOLD := 6                 # ticks a mouth shape stays before the next one can start

static var _sine: PackedInt32Array = PackedInt32Array()

var root: Node2D
var records: Array = []               # the two records (left, right)
var orphans: Array = []               # layers no record holds any more: they stay on screen and keep playing their streams
var live := false                     # the records' logic runs (a dialog or a show-menu opcode is running)
var pending_kind := -1                # the mouth kind of the glyph printed since the last tick (-1: none)
var last_kind := 0
var _clock := 0.0
var _serial_count := 0
var _data: Dictionary = {}
var _layout: Dictionary = {}
var _layout_read := false


class BustData extends RefCounted:
	var bank := PackedByteArray()
	var frames: Dictionary = {}       # frame offset (int) -> {"file": String, "origin": Vector2}
	var textures: Dictionary = {}

	func texture(offset: int) -> Texture2D:
		if not textures.has(offset):
			var info: Dictionary = frames.get(offset, {})
			var file := str(info.get("file", ""))
			textures[offset] = null
			if file != "" and FileAccess.file_exists(BustEffect.DIR + file):
				textures[offset] = ModArt.texture(BustEffect.DIR + file)
		return textures[offset]

	func origin(offset: int) -> Vector2:
		return frames.get(offset, {}).get("origin", Vector2.ZERO)


class Layer extends RefCounted:
	var bust: BustData
	var expression := 0               # the layer's expression (the stream table's first index)
	var layer := 0                    # 0 body, 1 eyes, 2 mouth (the stream table's second index)
	var variant := 0                  # the stream table's third index: the blink's and the mouth's selections
	var mode := 0                     # 0 as drawn, 1 the additive copy, 2 the subtractive copy
	var tint := BustEffect.NEUTRAL    # the colour multiplier (0x80 neutral)
	var x := 0
	var y := 0
	var depth := 0
	var started := false              # the stream is running (cleared when the variant changes, so it starts again)
	var hold := 0                     # the ticks left on the current frame (0: the frame stays, or the stream stopped)
	var stream := 0                   # the stream's start in the bank
	var offset := 0                   # the cursor within the stream (three bytes a command)
	var frame := -1                   # the frame the layer shows (its offset in the bank)
	var container: Node2D
	var sprite: Sprite2D
	var material: ShaderMaterial
	var shown := -2
	var serial := 0                   # creation order: layers of equal depth keep it

	func set_variant(value: int) -> void:
		variant = value
		started = false

	func update_variant(value: int) -> void:
		if variant != value:
			set_variant(value)

	func update_stream() -> void:
		var bank := bust.bank
		if not started:
			started = true
			offset = 0
			var table := BustEffect.u16(bank, expression * 2)
			table = BustEffect.u16(bank, table + layer * 2)
			stream = BustEffect.u16(bank, table + variant * 2)
			hold = 1
			_read_next()
		elif hold != 0:
			hold -= 1
			if hold <= 0:
				_read_next()

	## The next command of the stream: a control opcode (0xF0 and up) is carried out and the cursor moves on; a frame command sets
	## the hold and the frame. Stop holds the last frame for good.
	func _read_next() -> void:
		var bank := bust.bank
		var at := stream + offset
		var op := BustEffect.byte(bank, at)
		at += 1
		var guard := 0
		while op >= 0xF0:
			guard += 1
			if guard > 64:
				hold = 0
				return
			match op:
				0xFF:
					hold = 0
					return
				0xFE:
					offset = 0
				0xFD:
					hold = 0          # no operation: the game loops on it, so the port holds the frame instead
					return
				0xFC:
					offset = 0
					stream = BustEffect.u16(bank, at)
				0xFB:
					offset = 0
					stream = BustEffect.u16(bank, at)
				0xFA:
					var count := BustEffect.byte(bank, at)
					var pick := randi() % maxi(count, 1)
					offset = 0
					stream = BustEffect.u16(bank, at + 1 + pick * 2)
				0xF9:
					stream += 4       # the rotation operands are skipped (rotation is not drawn)
			at = stream + offset
			op = BustEffect.byte(bank, at)
			at += 1
		hold = op
		frame = BustEffect.u16(bank, at)
		offset += 3

	func refresh() -> void:
		if container == null:
			return
		material.set_shader_parameter("mode", mode)
		material.set_shader_parameter("tint", float(tint) / BustEffect.NEUTRAL)
		if frame < 0 or not bust.frames.has(frame) or bust.frames[frame].get("file", null) == null:
			sprite.visible = false
			return
		if shown != frame:
			shown = frame
			sprite.texture = bust.texture(frame)
		sprite.visible = sprite.texture != null
		sprite.position = Vector2(x, y) + bust.origin(frame)


class Record extends RefCounted:
	var id := -1                      # the bust's id, -1 when the record holds nothing
	var slot := 0
	var expression := 0
	var flags := 0                    # bit 0 blink, bit 1 mouth, bit 4 busy (the blink and the mouth wait), bit 6 the layers are built
	var step := 0                     # the step: 0 none, bit 7 the step has started, bit 6 the picture is loaded, low five bits its handler
	var x := 0
	var y := 0
	var counter := 0                  # the destination x of a slide, or the fade's level, or the next step of a show
	var dest_y := 0
	var dist_x := 0                   # the distance a slide covers
	var dist_y := 0
	var angle := 0                    # a slide's position on the cosine
	var angle_step := 0
	var blink := 0                    # ticks until the next blink
	var mouth_count := 0              # ticks since the mouth last changed
	var mouth_arg := 0
	var rows: Array = [[null, null, null], [null, null, null], [null, null, null], [null, null, null]]


static func u16(bank: PackedByteArray, at: int) -> int:
	if at < 0 or at + 2 > bank.size():
		return 0
	return bank[at] | (bank[at + 1] << 8)


static func byte(bank: PackedByteArray, at: int) -> int:
	if at < 0 or at >= bank.size():
		return 0xFF                   # past the bank the stream ends
	return bank[at]


static func _s16(value: int) -> int:
	return ((value + 0x8000) & 0xFFFF) - 0x8000


static func _s8(value: int) -> int:
	return ((value + 0x80) & 0xFF) - 0x80


func _init() -> void:
	records = [Record.new(), Record.new()]


## The root node the busts live under (the caller places it in the picture's stacking).
func attach(parent: Node2D) -> void:
	root = Node2D.new()
	root.name = "Busts"
	parent.add_child(root)


func clear() -> void:
	for rec in records:
		for row in rec.rows:
			for layer in row:
				if layer != null:
					_free_layer(layer)
		rec.rows = [[null, null, null], [null, null, null], [null, null, null], [null, null, null]]
		rec.id = -1
		rec.flags = 0
	for layer in orphans:
		_free_layer(layer)
	orphans.clear()


## The clock: the records' logic and the layers' streams advance 60 times a second, however often the physics runs.
func frame(delta: float) -> void:
	_clock += delta
	while _clock >= TICK:
		_clock -= TICK
		tick(pending_kind)
		pending_kind = -1


## One tick. `kind` is the mouth kind of the glyph printed this tick (-1: none; 4 keeps the last kind).
func tick(kind: int) -> void:
	if live:
		var arg := -1
		if kind >= 0:
			if kind == 4:
				arg = last_kind
			else:
				last_kind = kind
				arg = kind
		for rec in records:
			if rec.id >= 0:
				if (rec.flags & 0x40) != 0:
					_update_menu_record(rec, arg)
				if rec.step != 0:
					_run_step(rec)
	var layers := _all_layers()
	for layer in layers:
		layer.update_stream()
		layer.refresh()
	_order(layers)


## The layers draw in their depth order (the most negative first, as the game's ordering table does), by the position of their
## containers under the root: the root sits in the story's stack, so no z-index is used.
func _order(layers: Array) -> void:
	layers.sort_custom(func(a, b): return a.depth < b.depth or (a.depth == b.depth and a.serial < b.serial))
	for i in layers.size():
		var container: Node2D = layers[i].container
		if container != null and container.get_index() != i and i < root.get_child_count():
			root.move_child(container, i)


func _all_layers() -> Array:
	var out: Array = []
	for rec in records:
		for row in rec.rows:
			for layer in row:
				if layer != null:
					out.append(layer)
	out.append_array(orphans)
	return out


# ---- the text's side -------------------------------------------------------------------------------------------------

## The record a bust id is on screen in (the left slot first), or null.
func find(ident: int) -> Record:
	for rec in records:
		if rec.id == ident:
			return rec
	return null


## The show (F6 with bit 0x80 clear, no 0x60): the record of the slot takes the bust at its start (off the screen, or at rest
## for the fade), with the expression of flag bits 1 and 2 when bit 4 is set. The caller waits for the step.
func start_show(ident: int, flags: int) -> Record:
	var slot := flags & 1
	var rec: Record = records[slot]
	_init_record(rec, slot)
	rec.id = ident
	rec.x = SLOT_OFF[slot]
	rec.counter = 3                   # the next step after the picture loads: the slide
	if (flags & 8) != 0:
		rec.x = 0x400
		rec.counter = 7               # the fade in
	rec.step = 2
	if (flags & 0x10) != 0:
		rec.expression = (flags >> 1) & 3
	return rec


## The show-menu opcode: the bust goes up at its rest at once (the picture loads; no slide). The record of bit 7 is replaced and
## every record is reset, as the game does (the layers of the other record stay on screen).
func start_menu(ident: int, flags: int) -> Record:
	var slot := (flags >> 7) & 1
	var target: Record = records[slot]
	if target.id >= 0:
		_remove(target)
	for rec in records:
		rec.id = -1
		rec.flags = 0
		rec.blink = 0
		rec.mouth_count = 0
		for r in 4:
			_orphan_row(rec, r)
	_init_record(target, slot)
	target.expression = flags & 15
	target.id = ident
	target.step = 2
	if slot != 0:
		target.x = SLOT_X[1]
	return target


## Takes a bust away at once (F6 with bits 0x80 and 2).
func remove(rec: Record) -> void:
	_remove(rec)


func _remove(rec: Record) -> void:
	rec.id = -1
	_release_row(rec, 0)
	for r in range(1, 4):
		_orphan_row(rec, r)


## The record's slide out (F6 with bit 0x80): the destination is the off-screen x of its slot, then the step ends.
func start_slide_out(rec: Record) -> void:
	rec.counter = SLOT_OFF[rec.slot]
	rec.dest_y = BUST_Y
	rec.dist_x = 0x10
	rec.step = 3


## The record's fade out (F6 with bits 0x80 and 1): the fade's step, once the blink and the mouth are not busy.
func start_fade_out(rec: Record) -> void:
	rec.flags |= 0x10
	rec.step = 6


## The record's expression change (F6 with bit 0x40): the crossfade's step, once the blink and the mouth are not busy.
func start_crossfade(rec: Record) -> void:
	rec.flags |= 0x10
	rec.step = 4


## The record's state after the show's picture loaded: the slide in, or the fade in (its step is in the counter).
func start_slide_in(rec: Record) -> void:
	rec.step = rec.counter
	rec.counter = SLOT_X[rec.slot]
	rec.dest_y = BUST_Y
	rec.dist_x = -0x10


## F6 with bit 0x20: the busy flag is set or cleared (bit 0 set); busy suspends the blink and the mouth.
func set_busy(rec: Record, on: bool) -> void:
	rec.flags &= 0xEF
	if on:
		rec.flags |= 0x10


## The layers that wait on the blink and the mouth: a fade or crossfade starts only when they are idle.
func idle(rec: Record) -> bool:
	return (rec.flags & 3) == 0


# ---- building and releasing the layers ---------------------------------------------------------------------------------

func _init_record(rec: Record, slot: int) -> void:
	for r in 4:
		_orphan_row(rec, r)
	rec.slot = slot
	rec.flags = 0
	rec.step = 0
	rec.expression = 0
	rec.x = SLOT_X[slot]
	rec.y = BUST_Y
	rec.blink = (randi() & BLINK_MASK) + BLINK_BASE
	rec.mouth_count = 0
	rec.mouth_arg = 0


func _data_of(ident: int) -> BustData:
	if _data.has(ident):
		return _data[ident]
	if not _layout_read:
		_layout_read = true
		var path := DIR + "layout.json"
		if FileAccess.file_exists(path):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
			if typeof(parsed) == TYPE_DICTIONARY:
				_layout = parsed
	var entry = _layout.get("%02d" % ident, null)
	if typeof(entry) != TYPE_DICTIONARY:
		push_warning("bust %d has no baked data in %slayout.json: it is not drawn" % [ident, DIR])
		_data[ident] = null
		return null
	var data := BustData.new()
	data.bank = Marshalls.base64_to_raw(str(entry.get("bank", "")))
	for key in entry.get("frames", {}):
		var info: Dictionary = entry["frames"][key]
		var origin: Array = info.get("origin", [0, 0])
		data.frames[int(key)] = {"file": info.get("file", null), "origin": Vector2(float(origin[0]), float(origin[1]))}
	_data[ident] = data
	return data


static func _has_entry(bank: PackedByteArray, expression: int, layer: int, variant: int) -> bool:
	var table := u16(bank, expression * 2)
	if table == 0:
		return false
	table = u16(bank, table + layer * 2)
	if table == 0:
		return false
	return u16(bank, table + variant * 2) != 0


## Creates the layers of one row for an expression: the body, then the eyes and the mouth when their streams exist. The body's
## stream must exist, or nothing is made and the row stays as it was.
func _build_row(rec: Record, row: int, expression: int) -> bool:
	var data := _data_of(rec.id)
	if data == null or not _has_entry(data.bank, expression, 0, 0):
		return false
	var depth := -10 if rec.slot != 0 else -14
	var made := [null, null, null]
	for layer in 3:
		if layer == 0 or _has_entry(data.bank, expression, layer, 0):
			made[layer] = _make_layer(data, expression, layer, rec.x, rec.y, depth if layer == 0 else (depth | 1))
	_orphan_row(rec, row)
	rec.rows[row] = made
	return true


func _make_layer(data: BustData, expression: int, layer: int, x: int, y: int, depth: int) -> Layer:
	var made := Layer.new()
	made.bust = data
	made.expression = expression
	made.layer = layer
	made.x = x
	made.y = y
	made.depth = depth
	made.serial = _serial_count
	_serial_count += 1
	made.container = Node2D.new()
	var copy := BackBufferCopy.new()
	copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	made.container.add_child(copy)
	made.sprite = Sprite2D.new()
	made.sprite.centered = false
	made.material = ShaderMaterial.new()
	made.material.shader = load(SHADER)
	made.sprite.material = made.material
	made.container.add_child(made.sprite)
	root.add_child(made.container)
	return made


func _free_layer(layer: Layer) -> void:
	if layer.container != null:
		layer.container.queue_free()
		layer.container = null


func _release_row(rec: Record, row: int) -> void:
	for layer in rec.rows[row]:
		if layer != null:
			_free_layer(layer)
	rec.rows[row] = [null, null, null]


## A row the record lets go of but whose layers stay on screen (the game never releases them).
func _orphan_row(rec: Record, row: int) -> void:
	for layer in rec.rows[row]:
		if layer != null:
			orphans.append(layer)
	rec.rows[row] = [null, null, null]


func _set_mode(rec: Record, row: int, mode: int, depth: int) -> void:
	for layer in rec.rows[row]:
		if layer != null:
			layer.mode = mode
			layer.depth = depth
			if mode == 0:
				layer.tint = NEUTRAL


func _set_row_position(rec: Record, row: int, x: int, y: int) -> void:
	for layer in rec.rows[row]:
		if layer != null:
			layer.x = x
			layer.y = y


func _set_record_position(rec: Record, x: int, y: int) -> void:
	rec.x = x
	rec.y = y
	_set_row_position(rec, 0, x, y)


func _set_tint(rec: Record, row: int, tint: int) -> void:
	for layer in rec.rows[row]:
		if layer != null:
			layer.tint = tint


# ---- the blink and the mouth ------------------------------------------------------------------------------------------

func _update_menu_record(rec: Record, n: int) -> void:
	var f := rec.flags
	if (f & 0x10) != 0:
		rec.flags = f & 0xFC              # busy: the blink and the mouth stop where they are
		return
	var blink: Layer = rec.rows[0][1]
	if blink != null:
		if (f & 1) != 0:
			if blink.hold == 0:           # the closing eyes have finished: open them and draw the next delay
				rec.blink = (randi() & BLINK_MASK) + BLINK_BASE
				rec.flags &= 0xFE
				blink.set_variant(0)
		else:
			rec.blink = _s16(rec.blink - 1)
			if rec.blink <= 0:
				rec.flags |= 1
				blink.set_variant(1)
	var mouth: Layer = rec.rows[0][2]
	if mouth == null:
		return
	var g := rec.flags
	if (g & 2) != 0:
		rec.mouth_count = (rec.mouth_count - 1) & 0xFF
		if mouth.hold != 0:
			return
		if _s8(rec.mouth_count) > 0:
			return
		if n <= 0:
			rec.mouth_count = 0
			rec.flags &= 0xFD
			return
	else:
		if n < 0:
			rec.mouth_count = (rec.mouth_count + 1) & 0xFF
			if _s8(rec.mouth_count) < MOUTH_HOLD:
				return
			mouth.update_variant(0)
			return
		rec.flags = g | 2
	rec.mouth_count = MOUTH_HOLD
	rec.mouth_arg = n
	mouth.set_variant(n)


# ---- the record's steps -----------------------------------------------------------------------------------------------

func _run_step(rec: Record) -> void:
	match rec.step & 0x1F:
		0, 1:
			if (rec.flags & 3) == 0:
				rec.flags |= 0x10
				rec.step = 0
		2:
			_step_load(rec)
		3:
			_step_slide(rec)
		4, 6, 7:
			if rec.rows[0][0] == null:    # no body to fade (the picture never loaded or the expression has none): the step ends
				rec.step = 0
				rec.flags &= 0xEF
				for r in range(1, 4):
					_release_row(rec, r)
			elif (rec.step & 0x1F) == 4:
				_step_crossfade(rec)
			elif (rec.step & 0x1F) == 6:
				_step_fade_out(rec)
			else:
				_step_fade_in(rec)
		_:
			pass                          # the portrait and duel effects' steps: a bust never runs them


## Loads the picture and builds row 0. The disc transfer and the picture's VRAM cache are not modelled: the picture is at hand
## at once, so the step takes two ticks, as in the game when the picture is already in VRAM.
func _step_load(rec: Record) -> void:
	if (rec.step & 0x80) == 0:
		rec.step |= 0x80
		rec.step |= 0x40
		return
	if (rec.step & 0x40) == 0:
		return
	_build_row(rec, 0, rec.expression)
	rec.step = 0
	rec.flags |= 0x40


## The slide: a quarter turn of the cosine from the start to the destination, eased. The first tick draws the distance and the
## direction; the position is set each tick and the step ends on the destination.
func _step_slide(rec: Record) -> void:
	if (rec.step & 0x80) == 0:
		rec.step |= 0x80
		rec.angle = QUARTER
		rec.angle_step = _trunc(QUARTER, rec.dist_x)
		if rec.angle_step >= 0:
			rec.angle = 0
		rec.dist_x = _s16(rec.counter - rec.x)
		rec.dist_y = _s16(rec.dest_y - rec.y)
	var t := (rec.angle + (rec.angle_step & 0xFFFF)) & 0xFFFF
	rec.angle = t
	if ((t - 1) & 0xFFFF) >= QUARTER - 1:
		_set_record_position(rec, _s16(rec.counter), _s16(rec.dest_y))
		rec.step = 0
	else:
		var c := _rcos(_s16(t))
		var dx := _trunc(c * rec.dist_x, ONE)
		var dy := _trunc(c * rec.dist_y, ONE)
		if rec.angle_step < 0:
			dx = rec.dist_x - dx
			dy = rec.dist_y - dy
		_set_record_position(rec, _s16(rec.counter - dx), _s16(rec.dest_y - dy))


## The fade in: the copies are built (the additive copy of row 0 and the subtractive copy in row 1); the level climbs from 0 to 0x80.
func _step_fade_in(rec: Record) -> void:
	if (rec.step & 0x80) == 0:
		rec.step |= 0x80
		rec.flags |= 0x10
		rec.x = SLOT_X[1] if rec.slot != 0 else SLOT_X[0]
		_set_row_position(rec, 0, rec.x, rec.y)
		var depth: int = rec.rows[0][0].depth
		var expression: int = rec.rows[0][0].expression
		_set_mode(rec, 0, 1, depth)
		_orphan_row(rec, 1)
		_build_row_at(rec, 1, expression)
		_set_mode(rec, 1, 2, depth - 1)
		rec.counter = 0
	rec.counter = _s16(rec.counter + 8)
	if rec.counter >= NEUTRAL:
		rec.step = 0
		_set_mode(rec, 0, 0, rec.rows[0][0].depth)
		_set_row_position(rec, 0, rec.x, rec.y)
		_release_row(rec, 1)
		rec.flags &= 0xEF
		return
	_set_tint(rec, 0, rec.counter)
	_set_tint(rec, 1, rec.counter)


## The fade out: the copies are built as for the fade in; the level falls from 0x80 to 0, then the record is removed.
func _step_fade_out(rec: Record) -> void:
	if (rec.step & 0x80) == 0:
		rec.step |= 0x80
		rec.flags |= 0x10
		var depth: int = rec.rows[0][0].depth
		var expression: int = rec.rows[0][0].expression
		_set_mode(rec, 0, 1, depth)
		_orphan_row(rec, 1)
		_build_row_at(rec, 1, expression)
		_set_mode(rec, 1, 2, depth - 1)
		rec.counter = NEUTRAL
	rec.counter = _s16(rec.counter - 8)
	if rec.counter <= 0:
		rec.step = 0
		_release_row(rec, 1)
		_remove(rec)
		return
	_set_tint(rec, 0, rec.counter)
	_set_tint(rec, 1, rec.counter)


## The expression change: the new expression fades in (rows 0 and 1) while the old one fades out (rows 2 and 3), the two sliding
## apart by an eighth of the level each way. The old rows are the ones that were on screen.
func _step_crossfade(rec: Record) -> void:
	if (rec.step & 0x80) == 0:
		rec.step |= 0x80
		rec.flags |= 0x10
		var old_expression: int = rec.rows[0][0].expression
		var old_depth: int = rec.rows[0][0].depth
		_release_row(rec, 0)
		_build_row_at(rec, 0, rec.expression)
		_set_mode(rec, 0, 1, old_depth)
		_orphan_row(rec, 1)
		_build_row_at(rec, 1, rec.expression)
		_set_mode(rec, 1, 2, old_depth - 1)
		_orphan_row(rec, 2)
		_build_row_at(rec, 2, old_expression)
		_set_mode(rec, 2, 1, old_depth)
		_orphan_row(rec, 3)
		_build_row_at(rec, 3, old_expression)
		_set_mode(rec, 3, 2, old_depth - 1)
		rec.counter = NEUTRAL
	var n := _s16(rec.counter - 8)
	rec.counter = n
	if n <= 0:
		rec.step = 0
		_set_mode(rec, 0, 0, rec.rows[0][0].depth)
		_set_record_position(rec, rec.x, rec.y)
		_release_row(rec, 1)
		_release_row(rec, 2)
		_release_row(rec, 3)
		rec.flags &= 0xEF
		return
	_set_tint(rec, 2, n)
	_set_tint(rec, 3, n)
	_set_tint(rec, 0, NEUTRAL - n)
	_set_tint(rec, 1, NEUTRAL - n)
	var share := n / 8
	var rest := (NEUTRAL - n) / 8
	var dd0 := share if rec.slot != 0 else -share
	var dd1 := -rest if rec.slot != 0 else rest
	_set_row_position(rec, 0, _s16(rec.x + dd0), rec.y)
	_set_row_position(rec, 1, _s16(rec.x + dd0), rec.y)
	_set_row_position(rec, 2, _s16(rec.x - dd1), rec.y)
	_set_row_position(rec, 3, _s16(rec.x - dd1), rec.y)


## Builds a row for a fade's copies at the record's position.
func _build_row_at(rec: Record, row: int, expression: int) -> void:
	var data := _data_of(rec.id)
	if data == null or not _has_entry(data.bank, expression, 0, 0):
		return
	var depth := -10 if rec.slot != 0 else -14
	var made := [null, null, null]
	for layer in 3:
		if layer == 0 or _has_entry(data.bank, expression, layer, 0):
			made[layer] = _make_layer(data, expression, layer, rec.x, rec.y, depth if layer == 0 else (depth | 1))
	rec.rows[row] = made


# ---- the cosine (the quarter wave of the game's sine table, 4096 units to a turn) -------------------------------------

func _rcos(angle: int) -> int:
	return _sin_1((absi(angle) + 0x400) & 0xFFF)


func _sin_1(angle: int) -> int:
	if _sine.is_empty():
		_sine.resize(1025)
		for i in 1025:
			_sine[i] = roundi(ONE * sin(i * TAU / 4096.0))
	if angle <= 0x400:
		return _sine[angle]
	if angle <= 0x800:
		return _sine[0x800 - angle]
	if angle <= 0xC00:
		return -_sine[angle - 0x800]
	return -_sine[0x1000 - angle]


## Integer division truncated toward zero, as the game divides (a zero divisor gives zero).
static func _trunc(value: int, divisor: int) -> int:
	if divisor == 0:
		return 0
	return value / divisor
