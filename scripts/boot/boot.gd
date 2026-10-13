extends Control
## Entry point of the native port. Plays the boot sequence exactly as the boot sequence does: fade in (step 12 of 255 per frame)
## on the Konami logo, hold at least 4 frames, switch to the "Konami Computer Entertainment Japan" screen and hold 180 frames
## (Start or Cross skips the hold), then fade out into the front-end menu.

const SCREENS := "res://assets/screens/"
const MainMenu := preload("res://scripts/menu/main_menu.gd")
const NameEntry := preload("res://scripts/menu/name_entry.gd")
const StoryPlayer := preload("res://scripts/story/story_player.gd")
const MessageBox := preload("res://scripts/ui/message_box.gd")
const GameState := preload("res://scripts/state/game_state.gd")
const Options := preload("res://scripts/menu/options.gd")
const Library := preload("res://scripts/menu/library.gd")
const BuildDeck := preload("res://scripts/menu/build_deck.gd")
const FreeDuel := preload("res://scripts/menu/free_duel.gd")
const Credits := preload("res://scripts/menu/credits.gd")
const CampaignMap := preload("res://scripts/map/campaign_map.gd")
const DuelScene := preload("res://scripts/duel/duel_scene.gd")
const DuelData := preload("res://scripts/duel/duel_data.gd")
const GameAudio := preload("res://scripts/system/game_audio.gd")
const ScreenFit := preload("res://scripts/system/screen_fit.gd")
const GameOver := preload("res://scripts/menu/game_over.gd")
const Password := preload("res://scripts/menu/password.gd")
const TwoPlayerSetup := preload("res://scripts/menu/two_player_setup.gd")
const SecondCard := preload("res://scripts/menu/second_card.gd")
const Trade := preload("res://scripts/menu/trade.gd")
const TouchControls := preload("res://scripts/system/touch_controls.gd")
const DuelSpectator := preload("res://scripts/duel/duel_spectator.gd")
const OpeningMovie := preload("res://scripts/boot/opening_movie.gd")
const SettingsMenu := preload("res://scripts/runner/settings_menu.gd")
const ModArt := preload("res://scripts/system/mod_art.gd")
const FADE_STEP := 12
const FIRST_HOLD := 4
const SECOND_HOLD := 180

var world := Node2D.new()
var audio := GameAudio.new()
var picture := Sprite2D.new()
var shade := ColorRect.new()
var textures: Array = []
var phase := "fade_in"
var level := 0
var hold := 0
## The curtain: a black layer over every screen, for the hand-offs between a duel and the story, the menus and the campaign (a duel
## fades out to it when it ends, the next screen fades in from it, and a duel starts from it and fades in on its own).
const CURTAIN_FRAMES := 32
var curtain_layer := CanvasLayer.new()
var curtain := ColorRect.new()
var curtain_level := 0.0
var curtain_target := 0.0
var curtain_step_size := 0.0
var curtain_then := Callable()
var spectator_rng := RandomNumberGenerator.new()   # F3's random match (duel_spectator.gd)
## The opening movie after the Konami screens (opening_movie.gd), while it plays; the front-end menu follows it.
var movie: Node2D = null
## F9: the options panel (window, sound, picture); it sits above every screen and is applied at once.
var settings_layer := CanvasLayer.new()
var settings_panel: PanelContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_make_curtain()
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	black.name = "Backdrop"     # the boot's backdrop: F3 (the spectator match) clears the screens on top of it, not this
	add_child(black)
	for name in ["boot_0", "boot_1"]:
		var texture := ModArt.texture(SCREENS + name + ".png")
		if texture == null:
			return
		textures.append(texture)
	picture.centered = false
	picture.texture = textures[0]
	picture.modulate = Color(0, 0, 0)
	world.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	picture.material = ScreenFit.make_material()
	world.add_child(picture)
	add_child(world)
	add_child(ScreenFit.new())
	add_child(audio)
	add_child(TouchControls.new())   # on-screen buttons above every screen (touch and web; F4 toggles)
	settings_layer.layer = 90
	settings_panel = SettingsMenu.new()
	settings_layer.add_child(settings_panel)
	add_child(settings_layer)
	add_to_group("fit")
	get_viewport().size_changed.connect(refit)
	refit()
	set_physics_process(true)


func refit() -> void:
	ScreenFit.apply(world, size)
	if movie != null:
		ScreenFit.apply(movie, size, 240.0, 480.0)


func _skip_pressed() -> bool:
	return Input.is_key_pressed(KEY_ENTER) or Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE) \
		or TouchControls.game_pointer_held()


func _shade(value: int) -> void:
	var f := float(clampi(value, 0, 255)) / 255.0
	picture.modulate = Color(f, f, f)


func _physics_process(_delta: float) -> void:
	_curtain_step()
	if textures.is_empty():
		return
	match phase:
		"fade_in":
			level += FADE_STEP
			_shade(level)
			if level >= 255:
				phase = "first"
				hold = FIRST_HOLD
		"first":
			hold -= 1
			if hold < 0:
				picture.texture = textures[1]
				phase = "second"
				hold = SECOND_HOLD
		"second":
			hold -= 1
			if _skip_pressed():
				hold = -1
			if hold < 0:
				phase = "fade_out"
		"fade_out":
			level -= FADE_STEP
			_shade(level)
			if level <= 0:
				phase = "movie"
				picture.visible = false
				_start_movie()


## The opening movie (the boot's STR movie, pre-decoded): it plays on black, and its end, a skip or the menu's fade-in follow.
func _start_movie() -> void:
	movie = OpeningMovie.new()
	movie.finished.connect(_movie_finished)
	add_child(movie)
	refit()


func _movie_finished() -> void:
	phase = "done"
	movie.queue_free()
	movie = null
	_open_menu(0)


func _open_menu(initial: int) -> void:
	var menu := MainMenu.new()
	menu.initial_menu = initial
	menu.sound.connect(audio.play_se)
	menu.music.connect(audio.play_bgm)
	menu.chosen.connect(_menu_chosen.bind(menu))
	menu.load_requested.connect(_load_requested.bind(menu))
	menu.save_requested.connect(_save_requested.bind(menu))
	add_child(menu)


func _menu_chosen(id: int, menu: Node) -> void:
	audio.fade_bgm(0)   # the menu's exit fade
	if id == 4:
		# OPTION: the options screen (the options menu); closing it returns to the menu on that entry
		menu.queue_free()
		var options := Options.new()
		options.sound.connect(audio.play_se)
		options.music.connect(audio.play_bgm)
		options.closed.connect(_options_closed.bind(options))
		add_child(options)
		return
	if id == 6:
		# FREE DUEL: the opponent select (the Free Duel setup); circle returns to the menu on that entry
		menu.queue_free()
		var duel := FreeDuel.new()
		duel.sound.connect(audio.play_se)
		duel.music.connect(audio.play_bgm)
		duel.closed.connect(_free_duel_closed.bind(duel))
		duel.chosen.connect(_free_duel_chosen.bind(duel))
		add_child(duel)
		return
	if id == 7:
		# BUILD DECK: the deck editor (the build deck menu); leaving it returns to the menu on that entry
		menu.queue_free()
		_open_build_deck(_menu_build_deck_closed)
		return
	if id == 8:
		# LIBRARY: the card library; closing it returns to the menu on that entry
		menu.queue_free()
		var library := Library.new()
		library.sound.connect(audio.play_se)
		library.music.connect(audio.play_bgm)
		library.closed.connect(_library_closed.bind(library))
		add_child(library)
		return
	if id == 5:
		# CAMPAIGN: continue the story at the map place it was left at; with no campaign there is nothing to continue
		if GameState.has_campaign():
			menu.queue_free()
			var map := CampaignMap.new()
			map.place = GameState.map_place
			map.sound.connect(audio.play_se)
			map.finished.connect(_map_finished.bind(map))
			add_child(map)
		else:
			_notice(0xD3, menu, id)   # NO DATA!
		return
	if id == 3:
		# TRADE (the trade run): the second save file stands in for the memory card in slot 2; without it, MEMORY CARD REQUIRED.
		# Then (port) the second card screen offers to make the card, and a made card goes straight on to the trade.
		if Trade.can_open():
			menu.queue_free()
			_open_trade()
			return
		if GameState.has_campaign():
			_notice(0xD2, menu, id, _second_card.bind(_open_menu.bind(id), _open_trade))
		else:
			_notice(0xD2, menu, id)
		return
	if id == 9:
		# PASSWORD: the password shop (the password menu); leaving it returns to the menu on that entry
		menu.queue_free()
		var password := Password.new()
		password.sound.connect(audio.play_se)
		password.closed.connect(_password_closed.bind(password))
		add_child(password)
		return
	if id == 2:
		# 2P DUEL: the life point setup (the 2P duel setup run); RETURN TO TITLE comes back to the menu on that entry. Its load is the
		# trade's (both saves): without the second card's file the MEMORY CARD REQUIRED notice comes first, then the second card screen.
		if Trade.can_open():
			menu.queue_free()
			_open_two_player_setup()
			return
		if GameState.has_campaign():
			_notice(0xD2, menu, id, _second_card.bind(_open_menu.bind(id), _open_two_player_setup))
		else:
			_notice(0xD3, menu, id)   # NO DATA!
		return
	if id != 0:
		# any other entry that is not built yet: back to the menu on that entry instead of leaving it stuck
		menu.queue_free()
		_open_menu(id)
		return
	# NEW GAME: the name entry screen (the menu selection -> the name entry setup)
	menu.queue_free()
	var entry := NameEntry.new()
	entry.sound.connect(audio.play_se)
	entry.completed.connect(_name_entered.bind(entry))
	entry.cancelled.connect(_name_cancelled.bind(entry))
	add_child(entry)


func _password_closed(password: Node) -> void:
	password.queue_free()
	_open_menu(9)


## 2P DUEL: the setup's START gives the two life point totals; the duel has no AI and player 2's deck is the second card's.
func _two_player_started(life: Array, setup: Node) -> void:
	setup.queue_free()
	var duel := DuelScene.new()
	duel.two_player = true
	duel.life_points = life
	duel.second_deck = TwoPlayerSetup.second_player_deck()
	duel.sound.connect(audio.play_se)
	duel.music.connect(audio.play_bgm)
	duel.finished.connect(_two_player_finished.bind(duel))
	audio.play_duel_bgm()
	add_child(duel)


func _two_player_finished(winner: int, duel: Node) -> void:
	_curtain(1.0, CURTAIN_FRAMES, _two_player_done.bind(winner, duel))


func _two_player_done(winner: int, duel: Node) -> void:
	duel.queue_free()
	GameState.record_two_player_duel(winner)
	_open_menu(2)
	_curtain(0.0, CURTAIN_FRAMES)


func _trade_closed(trade: Node) -> void:
	audio.fade_bgm(0)   # the menu's exit fade
	trade.queue_free()
	_open_menu(3)


## The 2P DUEL setup: opened from the menu (once both saves are there) or from the second card screen when the card is made.
func _open_two_player_setup() -> void:
	var setup := TwoPlayerSetup.new()
	setup.sound.connect(audio.play_se)
	setup.music.connect(audio.play_bgm)
	setup.started.connect(_two_player_started.bind(setup))
	setup.cancelled.connect(_two_player_cancelled.bind(setup))
	add_child(setup)


func _two_player_cancelled(setup: Node) -> void:
	audio.fade_bgm(0)   # the menu's exit fade
	setup.queue_free()
	_open_menu(2)


func _options_closed(options: Node) -> void:
	audio.fade_bgm(0)   # the menu's exit fade
	audio.bgm.set_panning(not GameAudio.mono)   # the output type set on this screen
	options.queue_free()
	_open_menu(4)


func _free_duel_chosen(cell: int, select: Node) -> void:
	if cell == 0:
		# BUILD DECK from the opponent select: the select waits hidden, with its cursor, until the deck is left
		select.visible = false
		_open_build_deck(func(deck: Node) -> void: _free_duel_build_deck_closed(select, deck))
		return
	if cell < 1 or cell > 39:
		return
	select.queue_free()
	var duel := DuelScene.new()
	duel.opponent_id = cell
	duel.sound.connect(audio.play_se)
	duel.music.connect(audio.play_bgm)
	duel.finished.connect(_duel_finished.bind(duel, cell))
	audio.duel_bgm = 0x7270   # the free duel's track
	audio.play_duel_bgm()
	add_child(duel)


## Free Duel's return (cell given) adds the duel to the cell's record; the winner side 0 is the player.
func _duel_finished(winner: int, duel: Node, cell := -1) -> void:
	_curtain(1.0, CURTAIN_FRAMES, _duel_done.bind(winner, duel, cell))


func _duel_done(winner: int, duel: Node, cell: int) -> void:
	GameState.apply_cpu_duel(duel.outcome)
	duel.queue_free()
	if cell >= 1:
		GameState.record_duel(cell, winner == 0)
	_open_menu(6)
	_curtain(0.0, CURTAIN_FRAMES)


func _free_duel_closed(duel: Node) -> void:
	audio.fade_bgm(0)   # the menu's exit fade
	duel.queue_free()
	_open_menu(6)


## the build deck menu: the deck editor, its closing callback is given the screen to return to.
func _open_build_deck(on_closed: Callable) -> void:
	var deck := BuildDeck.new()
	deck.sound.connect(audio.play_se)
	deck.music.connect(audio.play_bgm)
	deck.closed.connect(on_closed.bind(deck))
	deck.closed.connect(audio.fade_bgm.bind(0))
	add_child(deck)


func _menu_build_deck_closed(deck: Node) -> void:
	deck.queue_free()
	_open_menu(7)


func _free_duel_build_deck_closed(select: Node, deck: Node) -> void:
	deck.queue_free()
	select.visible = true


func _library_closed(library: Node) -> void:
	audio.fade_bgm(0)   # the menu's exit fade
	library.queue_free()
	_open_menu(8)


func _name_cancelled(entry: Node) -> void:
	entry.queue_free()
	_open_menu(0)


func _name_entered(words: Array, entry: Node) -> void:
	GameState.reset()
	GameState.player_name = words
	var dealer := RandomNumberGenerator.new()
	dealer.randomize()
	GameState.duelist_code = GameState.roll_duelist_code(words, dealer)
	var data := DuelData.new()
	if data.load_all():
		GameState.deck = data.deal_starter_deck(dealer)
	entry.queue_free()
	var story := StoryPlayer.new()
	_connect_story(story)


## A story screen's signals: its sounds, its end, and the card shop's requests (the deck editor, a notice box).
func _connect_story(story: Node) -> void:
	story.sound.connect(audio.play_se)
	story.music.connect(audio.play_bgm)
	story.music_fade.connect(audio.fade_bgm)
	story.audio = audio
	story.finished.connect(_story_finished.bind(story))
	story.build_deck_requested.connect(_story_build_deck.bind(story))
	story.notice_requested.connect(_story_notice.bind(story))
	add_child(story)


## The card shop's BUILD DECK: the deck editor opens over the story; its close answers the story's build_deck_returned.
func _story_build_deck(story: Node) -> void:
	_open_build_deck(func(deck: Node) -> void:
		deck.queue_free()
		story.build_deck_returned.emit())


## The card shop's notice (SAVING... or SAVE INCOMPLETE!): the box is shown over the story and its close answers notice_closed.
func _story_notice(string_id: int, story: Node) -> void:
	var box := MessageBox.new()
	box.string_id = string_id
	box.sound.connect(audio.play_se)
	if string_id == 0xD6:
		box.auto_close = 75     # SAVING... runs while the write does, then SAVE COMPLETE! waits for a press
	box.closed.connect(func():
		box.queue_free()
		if string_id == 0xD6:
			var done := MessageBox.new()
			done.string_id = 0xD1
			done.sound.connect(audio.play_se)
			done.closed.connect(func(): done.queue_free(); story.notice_closed.emit())
			add_child(done)
			return
		story.notice_closed.emit())
	add_child(box)


## The story ended: "map" opens the campaign map at the script's place, and picking a place runs that place's scene (scene index
## place + 32, the campaign run). "gameover" is the game over screen (GameOver), which returns to the title menu when it is done;
## the other endings that are not built yet return to the front-end menu instead of leaving a black screen.
func _story_finished(kind: String, argument: int, story: Node) -> void:
	if kind == "duel":
		# the story starts a duel: the story fades out to the curtain, then the duel starts from black and fades in on its own
		# (its outcome picks the next scene: the data at 0x8009B370 after a win, the data at 0x8009B372 after a loss)
		_curtain(1.0, CURTAIN_FRAMES, _start_story_duel.bind(argument, story))
		return
	if kind == "loaded_menu":
		# the card shop's RETURN TO TITLE (YES) with a game loaded: the screen fades out and the loaded menu (campaign on) comes back
		_curtain(1.0, CURTAIN_FRAMES, _loaded_menu_open.bind(story))
		return
	story.queue_free()
	if kind == "credits":
		# the ending's credits (the credits run): the save, the secret number and the roll; the end returns to the front-end menu
		GameState.complete_campaign()   # the credits run' completion: the campaign index, the flags and the credits bits
		var credits := Credits.new()
		credits.sound.connect(audio.play_se)
		credits.music.connect(audio.play_bgm)
		credits.save_requested.connect(_credits_save.bind(credits))
		credits.finished.connect(_credits_finished.bind(credits))
		add_child(credits)
		return
	if kind == "map":
		var map := CampaignMap.new()
		map.place = argument
		map.sound.connect(audio.play_se)
		map.music.connect(audio.play_bgm)
		map.music_fade.connect(audio.fade_bgm)
		map.finished.connect(_map_finished.bind(map))
		add_child(map)
		return
	if kind == "gameover":
		# the game over (the game over opcode -> the game over run): the screen fades out and the title menu comes back
		var over := GameOver.new()
		over.sound.connect(audio.play_se)
		over.music.connect(audio.play_bgm)
		over.finished.connect(_game_over_finished.bind(over))
		add_child(over)
		return
	_open_menu(0)


func _loaded_menu_open(story: Node) -> void:
	story.queue_free()
	_open_menu(5)
	_curtain(0.0, CURTAIN_FRAMES)


## The credits' save prompt (the credits run): the save file stands in for the memory card. Without a campaign there is nothing to save.
## A failed save shows SAVE INCOMPLETE! and asks again when it is closed.
func _credits_save(credits: Node) -> void:
	if not GameState.has_campaign() or GameState.save_game():
		credits.save_done(true)
		return
	var box := MessageBox.new()
	box.string_id = 0xCD
	box.sound.connect(audio.play_se)
	box.closed.connect(func():
		box.queue_free()
		credits.save_done(false))
	add_child(box)


func _credits_finished(credits: Node) -> void:
	credits.queue_free()
	_open_menu(0)


func _game_over_finished(over: Node) -> void:
	audio.fade_bgm(0)   # the menu's exit fade
	over.queue_free()
	_open_menu(0)


func _map_finished(place: int, map: Node) -> void:
	GameState.map_place = place
	map.queue_free()
	var story := StoryPlayer.new()
	story.scene_index = place + 32
	_connect_story(story)


## The campaign duel's start: from the curtain, the duel is put in place, and the curtain lifts (the duel's own fade-in covers it).
func _start_story_duel(argument: int, story: Node) -> void:
	story.queue_free()
	var duel := DuelScene.new()
	duel.opponent_id = argument & 0xFF
	duel.terrain = (argument >> 24) & 0xFF
	duel.sound.connect(audio.play_se)
	duel.music.connect(audio.play_bgm)
	duel.finished.connect(_campaign_duel_finished.bind(duel, (argument >> 8) & 0xFF, (argument >> 16) & 0xFF))
	audio.play_duel_bgm()
	add_child(duel)
	_curtain_set(0.0)


## The campaign duel is decided and its result is left: the screen fades to the curtain, then the story plays the win or lose scene.
func _campaign_duel_finished(winner: int, duel: Node, win_scene: int, lose_scene: int) -> void:
	_curtain(1.0, CURTAIN_FRAMES, _campaign_duel_done.bind(winner, duel, win_scene, lose_scene))


func _campaign_duel_done(winner: int, duel: Node, win_scene: int, lose_scene: int) -> void:
	GameState.apply_cpu_duel(duel.outcome)
	duel.queue_free()
	var story := StoryPlayer.new()
	story.scene_index = win_scene if winner == 0 else lose_scene
	_connect_story(story)
	_curtain(0.0, CURTAIN_FRAMES)


## The curtain (the hand-off layer): it fades to `target` over `frames`, and `then` runs once it has arrived.
func _curtain(target: float, frames: int, then := Callable()) -> void:
	curtain_target = target
	curtain_step_size = absf(target - curtain_level) / float(maxi(frames, 1))
	curtain_then = then
	if curtain_level == target and curtain_step_size == 0.0:
		_curtain_arrived()


func _curtain_set(level: float) -> void:
	curtain_level = level
	curtain_target = level
	curtain_step_size = 0.0
	curtain_then = Callable()
	curtain.color = Color(0, 0, 0, level)


func _curtain_step() -> void:
	if curtain_level == curtain_target:
		if curtain_then.is_valid():
			_curtain_arrived()
		return
	curtain_level = move_toward(curtain_level, curtain_target, curtain_step_size)
	curtain.color = Color(0, 0, 0, curtain_level)
	if curtain_level == curtain_target:
		_curtain_arrived()


func _curtain_arrived() -> void:
	var then := curtain_then
	curtain_then = Callable()
	if then.is_valid():
		then.call()


func _make_curtain() -> void:
	curtain.color = Color(0, 0, 0, 0)
	curtain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	curtain.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	curtain_layer.layer = 50
	curtain_layer.add_child(curtain)
	add_child(curtain_layer)


## A notice in the dialog frame over the menu; closing it reopens the menu on `entry`, or calls `then` when one is given.
func _notice(string_id: int, menu: Node, entry: int, then := Callable()) -> void:
	menu.queue_free()
	var box := MessageBox.new()
	box.string_id = string_id
	box.sound.connect(audio.play_se)
	box.closed.connect(func():
		box.queue_free()
		if then.is_valid():
			then.call()
		else:
			_open_menu(entry))
	add_child(box)


## The TRADE screen (the trade run): both saves are there when this is called.
func _open_trade() -> void:
	var trade := Trade.new()
	trade.sound.connect(audio.play_se)
	trade.music.connect(audio.play_bgm)
	trade.closed.connect(_trade_closed.bind(trade))
	add_child(trade)


## The SECOND MEMORY CARD screen (port): the second card's file is made here (copy, starter deck or a save file). `on_cancel` and
## `on_made` are called when it is left or when the card is in its file.
func _second_card(on_cancel: Callable, on_made: Callable) -> void:
	var card := SecondCard.new()
	card.sound.connect(audio.play_se)
	card.finished.connect(func():
		card.queue_free()
		on_made.call())
	card.cancelled.connect(func():
		card.queue_free()
		on_cancel.call())
	add_child(card)


## LOAD: the save file stands in for the memory card. Found: the state is restored and the wheel moves on to its second page;
## missing: UNABLE TO LOCATE LOAD DATA! and the menu is left as it was.
func _load_requested(menu: Node) -> void:
	if GameState.has_save() and GameState.load_game():
		menu.finish_load(true)
		return
	var box := MessageBox.new()
	box.string_id = 0xCE
	box.sound.connect(audio.play_se)
	box.closed.connect(func():
		box.queue_free()
		menu.finish_load(false))
	add_child(box)


func _save_requested(menu: Node) -> void:
	if not GameState.has_campaign():
		_notice(0xD3, menu, 10)
		return
	var ok := GameState.save_game()
	if not ok:
		_notice(0xCD, menu, 10)   # SAVE INCOMPLETE!
		return
	_saving_then_saved(menu, 10)


## SAVING... (the memory card write: the box closes by itself when the write is done) and then SAVE COMPLETE! (closed with a press).
func _saving_then_saved(menu: Node, entry: int) -> void:
	menu.queue_free()
	var saving := MessageBox.new()
	saving.string_id = 0xD6
	saving.auto_close = 75
	saving.sound.connect(audio.play_se)
	add_child(saving)
	saving.closed.connect(func():
		saving.queue_free()
		var done := MessageBox.new()
		done.string_id = 0xD1
		done.sound.connect(audio.play_se)
		done.closed.connect(func(): done.queue_free(); _open_menu(entry))
		add_child(done))


## F1 quick-saves the campaign to the save file (the memory card stand-in) from anywhere.
func _input(event: InputEvent) -> void:
	if phase == "movie" and movie != null and _movie_skip_event(event):
		movie.skip()
		get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_spectate()
		get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9:
		settings_panel.toggle()
		get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		var ok := GameState.has_campaign() and GameState.save_game()
		_toast("QUICK SAVED" if ok else "NOTHING TO SAVE")
		get_viewport().set_input_as_handled()


## The opening movie is skipped by Enter, Space, Esc, a mouse click or a touch.
func _movie_skip_event(event: InputEvent) -> bool:
	if event is InputEventKey:
		return event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_ESCAPE]
	if event is InputEventMouseButton:
		return event.pressed
	if event is InputEventScreenTouch:
		return event.pressed
	return false


## F3 (port only): an AI v AI spectator match, from the front end. The screens on top of the boot are taken away and a random match of two
## duelists with their own decks starts from the curtain; its quit box (YES) returns to the main menu. Not during the boot, a duel, the
## story, the campaign or another spectator match.
func _spectate() -> void:
	if phase != "done" or curtain_level != 0.0 or curtain_target != 0.0:
		return
	for child in get_children():
		if child is DuelScene or child is StoryPlayer or child is CampaignMap or child is GameOver or child is Credits:
			return
	for child in get_children():
		if child is Control and child.name != "Backdrop":
			child.queue_free()
	spectator_rng.randomize()
	var pick: Dictionary = DuelSpectator.pick(spectator_rng)
	var duel := DuelScene.new()
	duel.spectator = true
	duel.spectator_ids = pick["ids"]
	duel.spectator_decks = pick["decks"]
	duel.terrain = int(pick["terrain"])
	duel.opponent_id = int(pick["ids"][1])
	duel.sound.connect(audio.play_se)
	duel.music.connect(audio.play_bgm)
	duel.finished.connect(_spectator_finished.bind(duel))
	audio.play_duel_bgm()
	add_child(duel)
	_curtain_set(0.0)


func _spectator_finished(_winner: int, duel: Node) -> void:
	_curtain(1.0, CURTAIN_FRAMES, _spectator_done.bind(duel))


func _spectator_done(duel: Node) -> void:
	duel.queue_free()
	Engine.time_scale = 1.0
	_open_menu(0)
	_curtain(0.0, CURTAIN_FRAMES)


func _toast(message: String) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	var label := Label.new()
	label.text = message
	label.position = Vector2(12, 8)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(1, 0.95, 0.4))
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)
	layer.add_child(label)
	add_child(layer)
	var timer := get_tree().create_timer(1.5)
	timer.timeout.connect(func(): layer.queue_free())
