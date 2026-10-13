extends "res://scripts/duel/effects/effect_program.gd"
## Effect 15: the monster removal (the first request of a removal): a square of the card's art (the board's texture, its bright half)
## is drawn twice over each monster the removal takes, shrinking from a large square to its size; the cards blink for sixteen frames
## and then fade out with the square at its final size. The variant (phase 0 to 7) is the configuration; 8 and up is the banner.
## Scene geometry: (160, 108).
##
## The monsters are the request's `cards`: their scene positions (the duel's field-row or matching collection, given as Vector3i).

var config: Dictionary = {}
var cards: Array = []
var visible := 1
var state := 0
var timer := 0
var scale_now := 4096
var colour := PackedInt32Array([1, 1, 1])


func _init() -> void:
	variant_count = 8
	geometry = Vector2i(160, 108)


func _start(phase: int) -> void:
	config = Data.configs()["effect_15"][phase]
	cards = extra.get("cards", [])
	visible = 1
	state = 0
	timer = 0
	scale_now = 4096
	set_all(colour, 1)


func _update() -> void:
	gte.push()
	var saved := Gte.Mat.new()
	var zero := Vector3i.ZERO
	var sc := Vector3i(scale_now, scale_now, scale_now)
	if is_lit(colour) and visible != 0:
		var lit := colour_of(colour)
		var uv: Array
		if scale_now > 1024:
			uv = [Vector2i(32, 0), Vector2i(95, 0), Vector2i(32, 63), Vector2i(95, 63)]
		else:
			uv = [Vector2i(32, 64), Vector2i(95, 64), Vector2i(32, 127), Vector2i(95, 127)]
		var quad := square(128)
		for card in cards:
			gte.pose(world, saved, card, zero, sc, 0)
			ft4(quad, 13, uv, lit, 32, 1)
			ft4(quad, 13, uv, lit, 32, 1)
		if scale_now > 1024:
			scale_now -= 512
		if state == 0:
			var c: Array = config["color"]
			state = 1 if fade_up(colour, Vector3i(c[0], c[1], c[2]), 15) else 0
		if state == 2 and scale_now == 1024:
			fade_down(colour, 31)
	if state == 1 and timer < 16:
		timer += 1
		if timer % 4 == 0:
			visible = 1 - visible
	elif timer >= 16:
		state = 2
	gte.pop()
	if is_black(colour):
		done = true
