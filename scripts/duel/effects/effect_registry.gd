extends RefCounted
## The effect programs the port has, by request id (the overlay's dispatch table: id -> program). An id with no entry is not ported
## yet; its requests are then not drawn and the duel shows its own approximation. See docs/duel-effects.md for the table and status.

const PROGRAMS := {
	0: preload("res://scripts/duel/effects/effect_00_contour_burst.gd"),
	1: preload("res://scripts/duel/effects/effect_01_light_beam.gd"),
	2: preload("res://scripts/duel/effects/effect_02_attack_hit.gd"),
	3: preload("res://scripts/duel/effects/effect_03_tile_sparkle.gd"),
	4: preload("res://scripts/duel/effects/effect_04_equip_card.gd"),
	5: preload("res://scripts/duel/effects/effect_05_heal_splash.gd"),
	6: preload("res://scripts/duel/effects/effect_06_damage_splash.gd"),
	7: preload("res://scripts/duel/effects/effect_07_damage_figure.gd"),
	8: preload("res://scripts/duel/effects/effect_08_trap.gd"),
	9: preload("res://scripts/duel/effects/effect_09_lp_number.gd"),
	10: preload("res://scripts/duel/effects/effect_10_terrain.gd"),
	11: preload("res://scripts/duel/effects/effect_11_removal.gd"),
	12: preload("res://scripts/duel/effects/effect_12_stop.gd"),
	13: preload("res://scripts/duel/effects/effect_13_penalty.gd"),
	14: preload("res://scripts/duel/effects/effect_14_gather.gd"),
	15: preload("res://scripts/duel/effects/effect_15_field.gd"),
	16: preload("res://scripts/duel/effects/effect_16_sweep.gd"),
	20: preload("res://scripts/duel/effects/effect_16_sweep.gd"),   # program 16 called with phase 1 (see create)
	17: preload("res://scripts/duel/effects/effect_17_board_destruction.gd"),
	18: preload("res://scripts/duel/effects/effect_18_ring_burst.gd"),
	19: preload("res://scripts/duel/effects/effect_19_reveal_flash.gd"),
	21: preload("res://scripts/duel/effects/effect_21_swords_field.gd"),
	22: preload("res://scripts/duel/effects/effect_22_ritual_apply.gd"),
	23: preload("res://scripts/duel/effects/effect_23_feather_duster.gd"),
	24: preload("res://scripts/duel/effects/effect_24_exodia_final.gd"),
}


static func has(id: int) -> bool:
	return PROGRAMS.has(id)


## A new program for an id bound to a picture and request context (see effect_program.gd's setup), or null when not ported.
static func create(id: int, picture, context: Dictionary):
	if not PROGRAMS.has(id):
		return null
	var program = PROGRAMS[id].new()
	program.setup(picture, context)
	if id == 20:
		program.fixed_phase = 1
	return program
