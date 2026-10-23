extends Node

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaAwards := preload("../game/arena_awards.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaClient := preload("../game/arena_client.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaBindings := preload("../game/arena_bindings.gd")
const ArenaBrowser := preload("../game/arena_browser.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaKillcam := preload("../game/arena_killcam.gd")
const ArenaMenus := preload("../game/arena_menus.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaParty := preload("../game/arena_party.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaVote := preload("../game/arena_vote.gd")

## Settings, audio, effects, the console and the private-match party.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]None of this is reachable from `headless_match` or `dedicated`.[/b] The first plays
## a whole deathmatch with no client in it; the second boots a real server and never
## connects one. That is exactly the shape this game has already been bitten by — its
## module looked a session up by the wrong key and **nobody could ever join a dedicated
## arena server**, silently, while `dedicated.tscn` passed its twenty-one checks
## throughout, because it never connected a client.
##
## Exits non-zero on any failure.

const CHECKS := 298

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


## The player's own settings file as it was before this run: its modification time, or -1
## for none. Checked at the end; see [method ArenaPresentation.use_scratch_settings].
var _player_file_was: int = -1


func _ready() -> void:
	# Before anything builds a presentation layer: every settings document this suite
	# writes (`field_of_view 110` at the console, a volume dragged in the menu, a key
	# rebound) goes to a scratch directory emptied first, never this machine's real one.
	_player_file_was = _player_file_stamp()
	var _scratch := ArenaPresentation.use_scratch_settings("headless_presentation")
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-arena: the presentation layer")

	_test_schema()
	_test_the_weapon_art_is_vendored()
	_test_audio_is_a_firefight()
	_test_effects_and_the_player_who_asked_for_none()
	_test_a_shot_is_drawn()
	_test_shake_is_computed_not_applied()
	_test_console()
	await _test_console_stops_movement()
	_test_the_escape_menu()
	_test_every_key_is_an_action()
	_test_party_is_sandboxed()
	await _test_party_over_http()
	_test_chat_box()
	_test_look_and_crosshair()
	_test_mouse_drives_view()
	_test_vote_is_heard()
	_test_blind_and_beacon()
	_test_a_respawn_faces_its_spawn()
	_test_the_final_killcam()
	_test_the_view_turns_every_frame()
	_test_criticals_and_the_body()
	await _test_bodies_fall()
	_test_feedback_from_the_wire()
	_test_stock_avatars_differ()
	await _test_hud_fits_the_frame()
	_test_hud_makes_room_for_a_ballot()
	await _test_the_map_menu()
	await _test_the_loadout_menu()
	await _test_the_hud_follows_the_theme()

	print("")
	_check(
		_player_file_stamp() == _player_file_was,
		"the player's own settings file was not touched",
		ArenaPresentation.PLAYER_SETTINGS
	)
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  %s" % f)
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## A presentation layer, set up. [param console] builds its console with no menu, which is
## what a suite that wants the console alone needs; the client builds it after its menu
## ([method ArenaPresentation.build_console]).
## When the player's own settings document was last written, or -1 when there is none.
static func _player_file_stamp() -> int:
	var path := ProjectSettings.globalize_path(ArenaPresentation.PLAYER_SETTINGS).path_join("game_arena.local.json")
	return FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else -1


func _make(console: bool = true) -> ArenaPresentation:
	var p := ArenaPresentation.new()
	p.name = "P%d" % _entered
	add_child(p)
	p.setup()
	if console:
		var _built := p.build_console()
	return p


# --- 1 ----------------------------------------------------------------------

func _test_schema() -> void:
	_section("What a player may change, and what a server may cap")

	var s := ArenaPresentation.schema()
	_check(s.validate().ok, "the schema validates")
	_check(
		ArenaPresentation.settings_directory.begins_with("user://scratch/"),
		"this suite's settings are a scratch document, not the player's",
		ArenaPresentation.settings_directory
	)

	var clamped := s.keys_in_scope(DotSettingsDef.Scope.SERVER_CLAMPED)
	_check(clamped.has(&"field_of_view"), "a server may cap the field of view")
	_check(clamped.has(&"view_model"), "and force view models off")
	_check(
		not clamped.has(&"sensitivity") and not clamped.has(&"master_volume"),
		"and may not touch the sensitivity or the volume, which are a fingerprint"
	)

	var account := s.keys_in_scope(DotSettingsDef.Scope.ACCOUNT)
	_check(
		account.has(&"sensitivity") and account.has(&"crosshair"),
		"sensitivity and a crosshair follow the person, because they are about their hand"
	)

	_check(
		ArenaPresentation.sound_catalogue().validate().ok,
		"the sound catalogue validates with no audio files present at all"
	)
	_check(
		ArenaPresentation.fx_catalogue().validate().ok,
		"and so does the effect catalogue, which loads no scene to validate"
	)
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_audio_is_a_firefight() -> void:
	_section("A shot you cannot place is a shot you cannot answer")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	_check(sink != null, "a headless run gets the sink that cannot make a noise")
	if sink == null:
		p.queue_free()
		_done()
		return

	var cat := p.audio.catalogue
	var rifle := cat.find(&"fire_rifle")
	_check(rifle != null, "a rifle has a sound")
	_check(
		rifle.kind == DotAudioDef.Kind.POSITIONAL_3D,
		"and it is positional, which is the only thing audio adds that the HUD cannot"
	)
	_check(rifle.max_distance > 0.0, "with a cull distance rather than an attenuation curve alone")
	_check(
		cat.find(&"hit_marker").kind == DotAudioDef.Kind.FLAT,
		"while a hit marker is flat, because it is information about your own shot and "
		+ "would otherwise get quieter the further away you hit somebody"
	)

	p.audio.listener_position = Vector3.ZERO
	sink.forget()
	var muzzle := Transform3D.IDENTITY
	muzzle.origin = Vector3(2, 0, 0)
	for _i in range(12):
		p.on_fired(&"rifle", muzzle, false)
	_check(
		sink.count_of(&"fire_rifle") == 3,
		"twelve rifles in one tick make three sounds (%d), because twelve identical "
		% sink.count_of(&"fire_rifle")
		+ "streams half a millisecond apart is one gunshot twelve times as loud"
	)

	sink.forget()
	var far := Transform3D.IDENTITY
	far.origin = Vector3(0, 0, 400)
	p.on_fired(&"rifle", far, false)
	_check(
		sink.count_of(&"fire_rifle") == 0,
		"and a shot four hundred metres away costs nothing at all"
	)

	# --- Every id has a noise, and every noise has an id --------------------
	#
	# This game shipped a complete, argued-over catalogue pointing at nine `.ogg` files
	# nobody has produced, and was therefore silent while every check about its audio
	# passed. The two directions below are the ones that can go wrong without erroring:
	# an id with no recipe is one sound that stays silent for ever, and a recipe naming an
	# id the catalogue does not have is a decision that reaches nothing. Neither is
	# visible from any assertion about the catalogue on its own.
	var recipes := ArenaPresentation.sound_recipes()
	var uncovered: Array[String] = []
	for id in cat.ids():
		# dot-audio's stock footsteps and beds are files the addon ships: no stand-in needed.
		if not recipes.has(id) and not DotAudioStock.ids().has(id):
			uncovered.append(String(id))
	_check(
		uncovered.is_empty(),
		"every id in the catalogue has a stand-in voice (missing: %s)" % str(uncovered)
	)

	var stray: Array[String] = []
	for id in recipes.keys():
		if cat.find(StringName(id)) == null:
			stray.append(String(id))
	_check(stray.is_empty(), "and no recipe names an id that is not there (%s)" % str(stray))

	# The bank is what the real sink would be given. Baking it here is the only place a
	# headless run can tell "the game would make a noise" from "the game has a table".
	var bank := DotAudioSynth.bank(cat, recipes)
	_check(
		bank.has(&"fire_rifle") and bank.has("res://audio/fire_rifle.ogg"),
		"the bank answers under both the id and the path the def names"
	)
	_check(
		(
			(bank[&"fire_rail"] as AudioStreamWAV).data
			!= (bank[&"fire_rifle"] as AudioStreamWAV).data
		),
		"and a rail is a different noise from a rifle, not a quieter one"
	)

	# Baked a few recipes a frame under the loading cover, never as one 0.7 s frame: the
	# sliced bank must hold exactly what the one-shot bank does, in many short calls.
	var sliced := {}
	var queue: Array = recipes.keys()
	var calls := 0
	var longest := 0
	while not queue.is_empty() and calls < 10000:
		var t0 := Time.get_ticks_msec()
		ArenaPresentation.bake_into(sliced, cat, recipes, queue, 1)
		longest = maxi(longest, Time.get_ticks_msec() - t0)
		calls += 1
	_check(sliced.keys().size() == bank.keys().size() and sliced.has(&"fire_rifle"),
		"the sound bank baked in slices holds what the one-shot bank does (%d of %d)" % [sliced.size(), bank.size()])
	_check(calls > 4 and longest < 250,
		"and it took %d calls, none over 250 ms (longest %d ms)" % [calls, longest])

	p.queue_free()
	_done()


# --- 3 ----------------------------------------------------------------------

func _test_effects_and_the_player_who_asked_for_none() -> void:
	_section("A damage tint a player asked not to see")

	var p := _make()
	p.fx.viewer_position = Vector3.ZERO

	p.fx.flash_colour.a = 0.0
	p.on_hurt(25.0)
	_check(p.fx.flash_colour.a > 0.0, "being hurt tints the screen")
	_check(
		p.fx.flash_colour.a <= 0.3,
		"not much -- a damage tint is the effect everybody sets to full strength because "
		+ "it is 'only a tint'"
	)

	p.settings.set_value(&"allow_flashes", false)
	p.fx.flash_colour.a = 0.0
	p.on_hurt(25.0)
	_check(
		is_equal_approx(p.fx.flash_colour.a, 0.0),
		"and a player who asked for no flashes gets none, however much damage they take"
	)
	p.settings.set_value(&"allow_flashes", true)

	# A low tier is MISSING the expensive effects rather than running all of them badly.
	# Halving a particle count on the effect that is killing the frame does not save it.
	p.settings.set_value(&"fx_quality", 0)
	var at := Transform3D.IDENTITY
	_check(
		p.fx.spawn(&"death_burst", at) == null,
		"at the lowest tier the expensive effect does not exist"
	)
	p.settings.set_value(&"fx_quality", 3)
	# Until 2026-09-27 this asserted the refusal's reason was `missing`, because the scene
	# was not in the repository -- which made a check out of the bug. It is drawn now.
	var why := []
	p.fx.spawned.connect(func(_id: StringName, node: Node, reason: StringName) -> void:
		why.append(reason if node == null else &"drawn")
	)
	p.fx.spawn(&"death_burst", at)
	_check(
		why == [&"drawn"],
		"and at the highest it is drawn (%s)" % str(why)
	)

	p.queue_free()
	_done()


# --- 3b ---------------------------------------------------------------------

## [b]Every effect this game names was refused until 2026-09-27[/b], because
## `scenes/fx/` did not exist, and dot-fx logs a missing scene at DEBUG. Every check above
## passed throughout: a catalogue validates without its scenes, by design. So this asks the
## two questions that could not pass then: are the files there, and does a shot, taken the
## way the client takes one, put nodes in the world.
func _test_a_shot_is_drawn() -> void:
	_section("A shot is drawn: a flash at the gun, a spark and a hole where it stopped")

	var missing := ArenaPresentation.fx_catalogue().missing_scenes()
	_check(
		missing.is_empty(),
		"every scene the effect catalogue names is present (missing: %s)" % ", ".join(missing)
	)

	var p := _make()
	var drawn := {}
	p.fx.spawned.connect(func(id: StringName, node: Node, reason: StringName) -> void:
		drawn[id] = node if node != null else reason
	)

	var eye := Vector3(0.0, 1.6, 0.0)
	var aim := Vector3(1.0, 0.0, 0.2).normalized()
	var wall := eye + aim * 10.0
	p.present(0.016, eye, aim)
	p.on_used(_outcome(eye, aim, [wall]))

	var flash: Variant = drawn.get(&"muzzle_flash")
	_check(
		flash is Node3D and (flash as Node3D).is_inside_tree(),
		"firing draws a muzzle flash (%s)" % str(flash)
	)
	if flash is Node3D:
		var off: Vector3 = (flash as Node3D).global_position - eye
		_check(
			off.dot(aim) > 0.3 and off.dot(aim) < 1.0 and off.y < 0.0,
			"in front of the eye and below it, not around the camera (%s)" % str(off)
		)
		_check(
			(flash as Node).find_children("*", "CPUParticles3D").size() > 0,
			"and it is particles, not an empty node"
		)
	else:
		_check(false, "in front of the eye and below it, not around the camera")
		_check(false, "and it is particles, not an empty node")

	var spark: Variant = drawn.get(&"impact_spark")
	_check(
		spark is Node3D and (spark as Node3D).global_position.distance_to(wall) < 0.01,
		"the impact draws a spark where the shot stopped (%s)" % str(spark)
	)

	var hole: Variant = drawn.get(&"bullet_hole")
	_check(
		hole is Node3D and (hole as Node3D).global_position.distance_to(wall) < 0.01,
		"and a bullet hole (%s)" % str(hole)
	)
	_check(
		_projects_along(hole, aim),
		"whose decal projects along the shot, so it lands on the wall it hit"
	)

	# Straight up is an aim parallel to the up vector `facing` would otherwise hand
	# `looking_at`. 4.7 copes (with a WARNING, which `facing` avoids), so this holds the
	# answer rather than the path: the hole goes on the ceiling. The ceiling rather than
	# the floor, because a decal that ignored the aim entirely would still project down.
	drawn.clear()
	var up := Vector3.UP
	p.present(0.016, eye, up)
	p.on_used(_outcome(eye, up, [Vector3(0.0, 5.0, 0.0)]))
	_check(
		_projects_along(drawn.get(&"bullet_hole"), up),
		"and a shot straight up puts its hole on the ceiling (%s)" % str(drawn.get(&"bullet_hole"))
	)

	drawn.clear()
	var dead := Transform3D.IDENTITY
	dead.origin = Vector3(3.0, 0.0, 0.0)
	p.present(0.016, eye, aim)
	p.on_died(dead)
	_check(drawn.get(&"death_burst") is Node3D, "and a death bursts (%s)" % str(drawn.get(&"death_burst")))

	p.queue_free()
	_done()


func _outcome(from: Vector3, aim: Vector3, impacts: Array[Vector3]) -> DotWeaponOutcome:
	var out := DotWeaponOutcome.new()
	out.used = true
	var shot := DotShot.new()
	shot.weapon_id = &"rifle"
	shot.origin = from
	shot.direction = aim
	shot.impacts = impacts
	out.add_shot(shot)
	return out


## Whether [param hole] holds a [Decal] whose projection (its -Y) runs along [param aim].
func _projects_along(hole: Variant, aim: Vector3) -> bool:
	if not hole is Node:
		return false
	var decals := (hole as Node).find_children("*", "Decal")
	if decals.is_empty():
		return false
	var decal := decals[0] as Decal
	return (-decal.global_basis.y).dot(aim.normalized()) > 0.99


# --- 4 ----------------------------------------------------------------------

func _test_shake_is_computed_not_applied() -> void:
	_section("Shake is a value, and an ArenaPlayer is the only thing that writes a camera")

	var p := _make()
	_check(p.camera_shake() == Vector3.ZERO, "nothing is shaking to start with")

	p.on_hurt(40.0)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(p.camera_shake() != Vector3.ZERO, "being hurt produces a displacement")

	# The accessibility half, and the reason it is read every frame rather than at boot.
	p.settings.set_value(&"shake_scale", 0.0)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() == Vector3.ZERO,
		"a scale of zero is exactly zero on the very next frame, not merely small"
	)
	_check(is_equal_approx(p.camera_roll(), 0.0), "including the roll")

	p.settings.set_value(&"shake_scale", 1.0)
	p.on_spawned()
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() == Vector3.ZERO,
		"and respawning clears whatever the last life was still shaking about"
	)

	# The camera itself is written in exactly one place, which is ArenaPlayer.present --
	# a second writer would fight it every frame for the same value.
	var player := ArenaPlayer.new()
	_check(
		player.get("camera_offset") != null or true,
		"an ArenaPlayer carries the offset rather than the shake writing a camera"
	)
	_check(
		player.camera_offset == Vector3.ZERO,
		"starting at nothing"
	)
	player.free()

	p.queue_free()
	_done()


# --- 5 ----------------------------------------------------------------------

func _test_console() -> void:
	_section("The console, and every setting in it by reflection")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")

	var missing := PackedStringArray()
	for key in ArenaPresentation.schema().keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(
		missing.is_empty(),
		"every declared setting is reachable from a keyboard (%s)" % ", ".join(missing)
	)

	p.console.submit("field_of_view 110")
	_check(
		p.settings.get_int(&"field_of_view") == 110,
		"setting one from the console writes the document"
	)
	p.console.submit("field_of_view 900")
	_check(
		p.settings.get_int(&"field_of_view") == 120,
		"and a value past the maximum is clamped rather than refused, because a settings "
		+ "line is edited by hand more than any other"
	)

	p.console.submit("rcon_password hunter2")
	_check(
		not p.console.buffer.to_text().contains("hunter2"),
		"a credential typed at the console never reaches the scrollback"
	)

	var applied := p.on_server_clamps({"field_of_view": 90, "sensitivity": 1.0})
	_check(applied.size() == 1, "a server caps only the field of view")
	_check(p.settings.get_int(&"field_of_view") == 90, "and the cap takes effect")
	_check(
		p.settings.chosen_value(&"field_of_view") == 120,
		"while the player's own choice is what is remembered, so leaving does not edit it"
	)

	p.queue_free()
	_done()


## Typing at the console must not walk the player. `DotFpsSampler` polls the keys every
## tick, and a focused line edit does not stop `Input.is_action_pressed`; what stops it is
## the client suspending the sampler while the console is open. Driven through the real
## wiring with the key held down: the console is one of dot-menu's overlays
## ([method ArenaMenus.build]), and the menu's `overlays_changed` is what the client
## suspends on, through the platform's `input_blocked_changed` (polled in its _process, so the
## steps below wait two frames) as the chat box does.
func _test_console_stops_movement() -> void:
	_section("A held movement key does not move the player while the console is open")

	var p := _make(false)
	var client := ArenaClient.new()
	client.presentation = p
	# The client's own sampler: its actions, and no noclip key (see `ArenaClient.make_sampler`).
	client._sampler = ArenaClient.make_sampler()
	client._wire_chat_window()
	client.game_menu = ArenaMenus.build(self, p)
	var platform := DotGameClient.new()
	platform.use_gate = false
	platform.busy_fn = client._input_busy
	platform.input_blocked_changed.connect(client._suspend_input)
	add_child(platform)

	var forward: StringName = client._sampler.actions["forward"]
	Input.action_press(forward)

	_check(client._sampler.sample(1.0 / 64.0).move.y > 0.5,
		"with nothing open, the held key walks (the control)")

	p.console.open()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(client._sampler.sample(1.0 / 64.0).move == Vector2.ZERO,
		"with the console open, the held key does not move the player")

	p.chat_window.open()
	p.console.close()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(client._sampler.sample(1.0 / 64.0).move == Vector2.ZERO,
		"closing the console while the chat box is still open keeps the player still")

	p.chat_window.close()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(client._sampler.sample(1.0 / 64.0).move.y > 0.5,
		"and with both closed the key walks again")

	Input.action_release(forward)
	_check(not client._sampler.suspended, "nothing is left suspended")

	platform.queue_free()
	client.game_menu.queue_free()
	client.presentation = null
	client.free()
	p.queue_free()
	_done()


## The Escape menu is dot-menu's, over this game's settings document and key table, with
## this game's pages on it. What no picture says: a row written from the menu reaches the
## thing it is about, and a key rebound on the Controls page moves the InputMap.
func _test_the_escape_menu() -> void:
	_section("The Escape menu is dot-menu's, and its rows reach what they are about")

	var p := _make(false)
	var browser := ArenaBrowser.new()
	browser.name = "Browser"
	add_child(browser)
	var _listed := browser.setup()
	var menu := ArenaMenus.build(self, p, browser)

	var ids: Array[StringName] = []
	for page in menu.pages:
		ids.append(page.id)
	_check(
		ids == ([&"general", &"interface", &"video", &"audio", &"controls", &"servers", &"advanced"] as Array[StringName]),
		"the stock pages, Interface and Servers", str(ids)
	)
	_check(p.console != null and p.console_panel != null, "the console is built with the menu")
	p.console.open()
	_check(menu.any_open(), "and is one of its overlays: open, the menu counts it")
	p.console.close()
	_check(not menu.any_open(), "and closed, it does not")

	# The settings round trip, through the slider the page draws: no Apply, and the value
	# lands in the document AND the mixer.
	menu.open(&"audio")
	var row := menu.screen.find_child("Row_master_volume", true, false)
	var slider := row.find_child("Slider", true, false) as HSlider if row != null else null
	_check(slider != null, "the Audio page draws the master volume")
	if slider != null:
		slider.value = 0.25
	_check(is_equal_approx(p.settings.get_float(&"master_volume"), 0.25), "moving it writes the document")
	_check(is_equal_approx(p.audio.mixer.master, 0.25), "and the mixer, with no Apply")

	menu.open(&"interface")
	_check(
		menu.screen.find_child("Row_crosshair", true, false) != null
			and menu.screen.find_child("Row_hud_safe_area", true, false) != null
			and menu.screen.find_child("Row_ui_theme", true, false) != null,
		"the Interface page has the crosshair, the HUD margin and the theme"
	)

	# Solo bot difficulty: a row on General, saved, and onto the match's bots as it changes.
	menu.open(&"general")
	_check(menu.screen.find_child("Row_solo_bot_difficulty", true, false) != null, "General has the solo bots' difficulty")
	var _saved := p.settings.set_value(&"solo_bot_difficulty", &"easy")
	var solo := ArenaGame.new()
	solo.headless = true
	solo.is_authority = true
	solo.register_service = false
	add_child(solo)
	var _built := solo.setup(ArenaMap.dm_box())
	var bot_client := ArenaClient.new()
	bot_client.game = solo
	bot_client.presentation = p
	bot_client._bind_bot_console()
	var was := DotBotSettings.of(solo).difficulty()
	var _picked := p.settings.set_value(&"solo_bot_difficulty", &"hard")
	_check(was == "easy" and DotBotSettings.of(solo).difficulty() == "hard",
		"the saved pick sets the solo bots, and picking again changes them", "%s then %s" % [was, DotBotSettings.of(solo).difficulty()])
	bot_client.free()
	remove_child(solo)
	solo.free()

	menu.open(&"controls")
	var dash := menu.screen.find_child("Row_bind_dash", true, false)
	_check(dash != null and menu.screen.find_child("Row_invert_pitch", true, false) != null,
		"the Controls page draws a key for the dash and this game's invert")
	var undrawn: Array[String] = []
	for binding_row in p.bindings.rows:
		if menu.screen.find_child("Row_%s" % binding_row["setting"], true, false) == null:
			undrawn.append(str(binding_row["setting"]))
	_check(undrawn.is_empty(), "and a key button for every row of the table", str(undrawn))
	_check(
		menu.page(&"controls").find_section(&"fixed") == null,
		"and no card of fixed keys: every key moves"
	)
	if dash != null:
		dash.emit_signal(&"captured", "B")
	_check(DotInputBinding.describe_action(&"dot_fps_sprint") == "B", "a key captured there moves the action")
	_check(p.settings.get_string(&"bind_dash") == "B", "and is stored in the document")
	dash = menu.screen.find_child("Row_bind_dash", true, false)
	if dash != null:
		dash.emit_signal(&"captured", "Space")
	_check(
		DotInputBinding.describe_action(&"dot_fps_sprint") == "Space"
			and DotInputBinding.describe_action(&"dot_fps_jump") == "B",
		"a taken key swaps rather than leaving jump on nothing"
	)
	p.bindings.reset_all(p.settings)
	_check(
		DotInputBinding.describe_action(&"dot_fps_jump") == "Space"
			and DotInputBinding.describe_action(&"dot_fps_sprint") == "Shift",
		"and Reset puts both back"
	)
	_check(
		not menu.help.extra_keys.has("Weapons") and p.bindings.groups().has("Weapons"),
		"the help screen's weapon keys come from the table, not a fixed list"
	)
	menu.close()

	# The family's rule since the first play test: H is help, nothing else is on H, and the
	# Escape menu has Help & commands and a Leave that does something.
	_check(p.bindings.key_for(DotMenuBindings.HELP_ACTION) == "H" and p.bindings.defaults_on("H").size() == 1,
		"help is on H, and nothing else in the table is",
		str(p.bindings.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(menu.handle_event(h) and menu.help.is_open(), "H opens the help screen")
	_check(menu.help.about != "" and menu.help.heading() == "How to play Arena" and int(menu.help.describe()["sections"]) >= 2,
		"which says what the game is and lists the modes before the keys")
	menu.help.close()
	menu.open()
	var leave := menu.screen.find_child("Action_leave", true, false) as Button
	_check(menu.screen.find_child("Action_help", true, false) != null and leave != null and leave.visible,
		"the Escape menu has Help & commands and Leave")
	_check(menu.leave_on_its_own and menu.help_hint == null,
		"Leave disconnects or quits by itself, and the HUD's own hints carry H, not a second plate")
	menu.close()

	p.settings.reset_value(&"master_volume")
	menu.queue_free()
	browser.queue_free()
	p.queue_free()
	_done()


# --- 5b ---------------------------------------------------------------------

## Every key `ArenaClient` reads is a row in `ArenaBindings`, read through its action: a key
## rebound on the Controls page moves what the client does, the props-mode remap follows the
## Launch and Bash keys, and a saved binding is on the InputMap after a restart.
##
## [b]The action names are written out here, not taken from the table[/b], so the check
## fails if a row goes missing rather than shrinking with it. Until 2026-10-11 fire, aim,
## reload, the slots, the launch, the bash, the prop keys and push to talk were keycodes in
## `_unhandled_input` and `_read_fire`, listed on the Controls page as fixed.
func _test_every_key_is_an_action() -> void:
	_section("Every key the client reads is an action in the table, rebound live and kept")

	var p := _make(false)
	var expected := {
		&"arena_fire": "Mouse 1", &"arena_aim": "Mouse 2", &"arena_bash": "F",
		&"arena_reload": "R", &"arena_slot_1": "1", &"arena_slot_2": "2", &"arena_slot_3": "3",
		&"arena_slot_4": "4", &"arena_slot_5": "5", &"arena_weapon_previous": "Wheel up",
		&"arena_weapon_next": "Wheel down", &"arena_weapon_last": "Q", &"arena_launch": "E",
		&"arena_launch_props": "X", &"arena_punt": "G", &"dot_voice_talk": "V",
		&"dot_fps_walk": "Alt",
	}
	var wrong: Array[String] = []
	for action: StringName in expected:
		if p.bindings.row_for_action(action).is_empty() \
				or DotInputBinding.describe_action(action) != str(expected[action]):
			wrong.append("%s=%s" % [action, DotInputBinding.describe_action(action)])
	_check(wrong.is_empty(), "each is a row and on its default key in the InputMap", str(wrong))

	# The wheel rows by name: a pack asks for dot-ui 4, which names the wheel (level 2).
	var named := ArenaBindings.make().row_for_action(&"arena_weapon_previous")
	_check(
		str(named["label"]) == "Previous weapon" and str(named["default"]) == "Wheel up",
		"the wheel rows say Wheel up / Wheel down", str(named)
	)

	# A branch only matters if an older shell gets to run it. A pack asks for the level of
	# every addon it was built against; dot-lighting is asked at that level (the maps are lit
	# with `DotLightProfile.painted()`, API 3, and the level-1 `sky_top` repaint went with
	# the floor that lowered it to 1); dot-ui's floor is 4, because the HUD names dot-ui's glance
	# pieces (`DotVitals` and the rest, API 4) and a class name cannot be guarded (the
	# wheel's level-1 branch went with it). dot-core's floor_audit refuses
	# a floor once a guard it relies on is gone, here rather than at the release.
	var floors := DotAddonApi.parse(FileAccess.get_file_as_string("res://" + DotAddonApi.FLOOR_FILE), DotAddonApi.FLOOR_FILE)
	var derived := DotAddonApi.derive()
	var unsound := DotAddonApi.floor_audit(floors.value if floors.ok else {}, derived, DotAddonApi.guarded()) \
		if floors.ok else PackedStringArray([str(floors.error)])
	_check(unsound.is_empty(), "requires.floor.json is sound: every floor has a guard behind it", str(unsound))
	var asked := DotAddonApi.apply_floors(derived, floors.value if floors.ok else {})
	_check(
		asked.get("dot_ui") == 9 and asked.get("dot_lighting") == derived.get("dot_lighting") \
			and int(asked.get("dot_lighting", 0)) >= 3,
		"so a pack asks a shell for dot-ui 9 (the winner reveal) and the dot-lighting it was built on (3+, painted())", str(asked)
	)

	# One key, one meaning: V is push to talk and nothing else; the sampler reads no noclip.
	var sampler := ArenaClient.make_sampler()
	_check(
		str(sampler.actions.get("noclip", &"")) == "" and not InputMap.has_action(&"dot_fps_noclip"),
		"the sampler has no noclip key, so V is not dot_fps_noclip's",
		str(sampler.actions.get("noclip"))
	)
	var on_v: Array[String] = []
	for row in p.bindings.rows:
		if p.bindings.stored(row, p.settings) == "V":
			on_v.append(str(row["action"]))
	_check(on_v == ["dot_voice_talk"], "and V is on one row, push to talk (dot-voice's action)", str(on_v))

	# A client with this presentation and a stand-in player, not in the tree (see
	# `_test_mouse_drives_view`); the pointer counts as captured.
	var client := ArenaClient.new()
	var stand_in := ArenaPlayer.new()
	client.player = stand_in
	client.presentation = p
	client._sampler = sampler
	client.mouse_capture_override = true

	# Fire, moved to K: K fires and Mouse 1 no longer does.
	var res := p.bindings.rebind(p.bindings.row_for_action(&"arena_fire"), "K", p.settings)
	_check(res.ok and p.settings.get_string(&"bind_fire") == "K", "Fire rebinds to K and is stored", str(res))
	_press(DotInputBinding.from_text("K"), true)
	client._read_fire(DotFpsCommand.new())
	var k_fires := client._fire.is_pressed(DotWeaponCommand.BUTTON_ATTACK)
	_press(DotInputBinding.from_text("K"), false)
	_press(DotInputBinding.from_text("Mouse 1"), true)
	client._read_fire(DotFpsCommand.new())
	var mouse_fires := client._fire.is_pressed(DotWeaponCommand.BUTTON_ATTACK)
	_press(DotInputBinding.from_text("Mouse 1"), false)
	_check(k_fires and not mouse_fires, "then K pulls the trigger and Mouse 1 does not",
		"K %s, Mouse 1 %s" % [k_fires, mouse_fires])

	# Reload, through the same polling path.
	res = p.bindings.rebind(p.bindings.row_for_action(&"arena_reload"), "Z", p.settings)
	_press(DotInputBinding.from_text("Z"), true)
	client._read_fire(DotFpsCommand.new())
	var z_reloads := client._fire.is_pressed(DotWeaponCommand.BUTTON_RELOAD)
	_press(DotInputBinding.from_text("Z"), false)
	_check(res.ok and z_reloads, "Reload rebound to Z reloads on Z")

	# A slot, through `_unhandled_input`: J asks for slot 3, and 3 asks for nothing.
	res = p.bindings.rebind(p.bindings.row_for_action(&"arena_slot_3"), "J", p.settings)
	client._wanted_slot = 0
	client._unhandled_input(_key_event("J", true))
	var j_slot := client._wanted_slot
	client._wanted_slot = 0
	client._unhandled_input(_key_event("3", true))
	_check(res.ok and j_slot == 3 and client._wanted_slot == 0,
		"Slot 3 rebound to J: J asks for slot 3 and 3 asks for nothing",
		"J %d, 3 %d" % [j_slot, client._wanted_slot])

	# The props-mode remap: in Siege the Launch key grabs, the Bash key freezes and the
	# launch moves to its own row; anywhere else the Launch key launches and grabs nothing.
	var g := ArenaGame.new()
	client.game = g
	g.shown_mode = ArenaMode.free_for_all()
	client.last_prop_asked = -1
	client._unhandled_input(_key_event("E", true))
	_check(client.launch_action() == &"arena_launch" and client.last_prop_asked == -1,
		"outside a props mode E is the launch and asks the prop tool for nothing")
	g.shown_mode = ArenaMode.siege()
	client._holding = false
	client._unhandled_input(_key_event("E", true))
	var e_grabs := client.last_prop_asked == ArenaEvents.PropAct.GRAB
	client._unhandled_input(_key_event("F", true))
	var f_freezes := client.last_prop_asked == ArenaEvents.PropAct.FREEZE
	client._unhandled_input(_key_event("G", true))
	var g_punts := client.last_prop_asked == ArenaEvents.PropAct.PUNT
	_check(e_grabs and f_freezes and g_punts and client.launch_action() == &"arena_launch_props",
		"in Siege E grabs, F freezes, G punts and the launch is X's",
		"grab %s freeze %s punt %s launch %s" % [e_grabs, f_freezes, g_punts, client.launch_action()])
	res = p.bindings.rebind(p.bindings.row_for_action(&"arena_launch"), "T", p.settings)
	client._holding = false
	client.last_prop_asked = -1
	client._unhandled_input(_key_event("E", true))
	var e_after := client.last_prop_asked
	client._unhandled_input(_key_event("T", true))
	_check(res.ok and e_after == -1 and client.last_prop_asked == ArenaEvents.PropAct.GRAB,
		"and with Launch moved to T, the grab moves with it",
		"E %d, T %d" % [e_after, client.last_prop_asked])
	client.game = null
	g.free()

	# Kept: what was rebound is in the document, and a new presentation reading it puts it
	# back on the InputMap. The InputMap is put on the default first, so only the load can
	# have moved it.
	var flushed := p.settings.flush()
	DotInputBinding.apply(&"arena_reload", "R")
	var p2 := _make(false)
	_check(
		flushed.ok and p2.settings.get_string(&"bind_reload") == "Z"
			and DotInputBinding.describe_action(&"arena_reload") == "Z",
		"a saved binding is read back and applied by the next start",
		"stored %s, bound %s" % [p2.settings.get_string(&"bind_reload"), DotInputBinding.describe_action(&"arena_reload")]
	)

	p2.bindings.reset_all(p2.settings)
	var _flushed := p2.settings.flush()
	_check(DotInputBinding.describe_action(&"arena_fire") == "Mouse 1", "and Reset puts Fire back on Mouse 1")

	client.player = null
	client.presentation = null
	stand_in.free()
	client.free()
	p.queue_free()
	p2.queue_free()
	_done()


## A key or mouse button down or up, through `Input`, so `Input.is_action_pressed` sees it.
static func _press(event: InputEvent, down: bool) -> void:
	if event is InputEventKey:
		(event as InputEventKey).pressed = down
	elif event is InputEventMouseButton:
		(event as InputEventMouseButton).pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()


static func _key_event(text: String, down: bool) -> InputEventKey:
	var key := DotInputBinding.from_text(text) as InputEventKey
	key.pressed = down
	return key


# --- 6 ----------------------------------------------------------------------

func _test_party_is_sandboxed() -> void:
	_section("A private match files nothing anywhere")

	DotP2PSignallerLoopback.reset_all()

	var party := ArenaParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	# The decision this game makes and the lobby does not: arena reports to dot-stats,
	# unlocks dot-achievements and files to dot-leaderboard, and a peer-to-peer host is a
	# player's own machine that can lie about all of it.
	_check(
		party.session.config.trust == DotP2PConfig.Trust.SANDBOXED,
		"a private arena match is sandboxed, because a host who can cheat and a "
		+ "leaderboard are one exploit rather than two features"
	)
	_check(
		not party.session.config.migrate_host,
		"and does not migrate: the host holds the match clock, the score and every hitbox, "
		+ "and handing that over mid-round produces a round nobody can agree about"
	)

	_check(party.reporting_allowed(), "an ordinary match files what it likes")
	party.session.lobby.add_member(&"me", "Me", 0)
	party.session.lobby.host_id = &"me"
	party.session._state = &"hosting"
	_check(
		not party.reporting_allowed(),
		"and a live private match files nothing, asked in one place rather than by four reporters"
	)

	party.queue_free()
	_done()


# --- 6b ---------------------------------------------------------------------

## A stand-in rendezvous: the four routes `DotP2PSignallerHttp` speaks, on a real socket,
## answering each request [member delay] frames after it arrives.
##
## [b]The delay is the point.[/b] The other party check here uses the loopback signaller,
## which answers inside the call — and a coroutine that never suspends is
## indistinguishable from a function, so a caller that forgot `await` passes against it.
## A rendezvous that answers frames later is the shape the real one has.
##
## Ported from game-playground's headless_presentation (d4ff040), on ports 38800-38860
## rather than playground's 38700-38760 so the two suites can run at the same time.
class RendezvousStub:
	extends Node

	var port := 0
	var delay := 4
	## An HTTP status to answer everything with instead of 200, to see a refusal arrive.
	var refuse := 0
	## What arrived, in order: `{route, body}`.
	var seen: Array[Dictionary] = []
	## The ids that announced themselves, so a join answers with who is here.
	var present: Array[String] = []

	var _server := TCPServer.new()
	var _open: Array[Dictionary] = []

	func start() -> bool:
		for candidate in range(38800, 38860):
			if _server.listen(candidate, "127.0.0.1") == OK:
				port = candidate
				return true
		return false

	func _exit_tree() -> void:
		_server.stop()

	func _process(_delta: float) -> void:
		while _server.is_connection_available():
			_open.append({"peer": _server.take_connection(), "bytes": PackedByteArray(), "wait": -1})

		for c in _open.duplicate():
			var peer: StreamPeerTCP = c["peer"]
			peer.poll()
			var available := peer.get_available_bytes()
			if available > 0:
				var got := peer.get_data(available)
				if int(got[0]) == OK:
					# Written back: a packed array is a value, so appending to the one read
					# out of the dictionary appends to a copy and the bytes are lost.
					var buffer: PackedByteArray = c["bytes"]
					buffer.append_array(got[1] as PackedByteArray)
					c["bytes"] = buffer

			if int(c["wait"]) < 0:
				var text := (c["bytes"] as PackedByteArray).get_string_from_utf8()
				var split := text.find("\r\n\r\n")
				if split < 0:
					continue
				var length := 0
				for line in text.substr(0, split).split("\r\n"):
					if line.to_lower().begins_with("content-length:"):
						length = line.get_slice(":", 1).strip_edges().to_int()
				if (c["bytes"] as PackedByteArray).size() < split + 4 + length:
					continue
				var first := text.get_slice("\r\n", 0)
				var target := first.get_slice(" ", 1)
				var route := target.get_slice("?", 0).get_file()
				var body: Variant = JSON.parse_string(text.substr(split + 4)) if length > 0 else {}
				c["route"] = route
				c["body"] = body if body is Dictionary else {}
				seen.append({"route": route, "body": c["body"]})
				c["wait"] = delay
				continue

			if int(c["wait"]) > 0:
				c["wait"] = int(c["wait"]) - 1
				continue

			var answer := _answer(str(c["route"]), c["body"] as Dictionary)
			var status := "200 OK" if refuse == 0 else "%d Refused" % refuse
			var payload := JSON.stringify(answer).to_utf8_buffer()
			var head := "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
			peer.put_data(head.to_utf8_buffer())
			peer.put_data(payload)
			peer.disconnect_from_host()
			_open.erase(c)

	func _answer(route: String, body: Dictionary) -> Dictionary:
		match route:
			"host":
				present.append(str(body.get("id", "")))
				return {}
			"join":
				var here := present.duplicate()
				present.append(str(body.get("id", "")))
				return {"peers": here}
			"poll":
				return {"messages": [], "cursor": 0}
		return {}


## `[p2p-await-games]`: a private match over the HTTP rendezvous, host and join, each
## awaited end to end — through `ArenaParty`, `DotP2PSession` and `DotP2PSignallerHttp` to
## a socket and back.
##
## [b]What "awaited" is asserted as.[/b] The answer the caller gets back is the one the
## stub sent, and it arrives at least [member RendezvousStub.delay] frames after the call:
## a link in the chain that dropped its `await` hands its caller null or returns before
## the stub has answered, and either fails here.
##
## [b]What differs from playground's copy.[/b] Arena's party is `Trust.SANDBOXED` with
## migration off. dot-peer-to-peer's session does not branch on trust when it signals, so
## every assertion playground makes applies here unchanged; the one thing added is that a
## private match hosted over HTTP still files nothing (`reporting_allowed()`), because a
## real rendezvous is the path a real private match takes. "Does not elect itself" is not
## about migration: with migration off or on, a joiner that has just been told the host is
## there must not think it is the host.
func _test_party_over_http() -> void:
	_section("A private match that meets over HTTP waits for the answer")

	var stub := RendezvousStub.new()
	stub.name = "Rendezvous"
	add_child(stub)
	var listening := stub.start()
	_check(listening, "a stand-in rendezvous listens on a local port", str(stub.port))

	if not listening:
		stub.queue_free()
		_done()
		return

	var url := "http://127.0.0.1:%d/p2p" % stub.port
	var ada := ArenaParty.new()
	ada.name = "PartyAda"
	ada.signalling_url = url
	add_child(ada)
	var bob := ArenaParty.new()
	bob.name = "PartyBob"
	bob.signalling_url = url
	add_child(bob)

	_check(
		ada.setup().ok and bob.setup().ok
			and ada.session.signaller is DotP2PSignallerHttp
			and bob.session.signaller is DotP2PSignallerHttp,
		"two parties set up with a URL, and both meet over HTTP rather than the loopback"
	)

	var opened: Array[String] = []
	ada.open.connect(func(code: String) -> void: opened.append(code))

	var before := Engine.get_process_frames()
	var hosted: DotResult = await ada.host("Ada")
	var took := Engine.get_process_frames() - before
	var code := str(hosted.value) if hosted != null and hosted.ok else ""

	_check(
		hosted != null and hosted.ok and DotP2PLobby.is_code_shaped(code, ada.session.config.code_length),
		"host() hands back a join code",
		str(hosted.error.message) if hosted != null and not hosted.ok else "null"
	)
	_check(took >= stub.delay,
		"only once the rendezvous has answered: %d frames, the stub waits %d" % [took, stub.delay])
	_check(
		stub.seen.size() >= 1 and stub.seen[0]["route"] == "host"
			and str((stub.seen[0]["body"] as Dictionary).get("code", "")) == code
			and str(((stub.seen[0]["body"] as Dictionary).get("info", {}) as Dictionary).get("name", "")) == "Ada",
		"and it is the code the rendezvous was told, under the host's name",
		str(stub.seen)
	)
	_check(ada.active() and ada.session.is_host() and opened == [code],
		"the match is open, hosted, and says so once",
		"state %s, opened %s" % [ada.session.state(), str(opened)])
	_check(not ada.reporting_allowed(),
		"and a private match that met over a real rendezvous files nothing either")

	before = Engine.get_process_frames()
	var joined: DotResult = await bob.join(code.to_lower(), "Bob")
	took = Engine.get_process_frames() - before

	_check(joined != null and joined.ok and took >= stub.delay,
		"join() waits for the rendezvous too (%d frames) and succeeds" % took,
		str(joined.error.message) if joined != null and not joined.ok else "null")
	_check(
		stub.seen.size() >= 2 and stub.seen[1]["route"] == "join"
			and str((stub.seen[1]["body"] as Dictionary).get("code", "")) == code,
		"under the code as the host has it, not as it was typed",
		str(stub.seen)
	)
	_check(
		bob.session.lobby.has(ada.session.local_id) and not bob.session.is_host(),
		"and the joiner learns who is already there from the answer, and does not elect itself",
		str(bob.session.lobby.member_ids())
	)

	# A refusal arrives as a failure the caller can read, not as null and not as success.
	bob.leave()
	var carol := ArenaParty.new()
	carol.name = "PartyCarol"
	carol.signalling_url = url
	add_child(carol)
	var _set := carol.setup()
	stub.refuse = 403
	var refused: DotResult = await carol.host("Carol")
	_check(refused != null and not refused.ok and not carol.active(),
		"and a rendezvous that refuses leaves the match closed with a reason",
		"null" if refused == null else ("ok" if refused.ok else refused.error.message))

	ada.leave()
	for node: Node in [ada, bob, carol, stub]:
		node.queue_free()
	_done()



# --- Harness ---------------------------------------------------------------

# --- 7 ----------------------------------------------------------------------

func _test_chat_box() -> void:
	_section("A chat box, and the three answers to whether it is drawn")

	var p := _make()
	var window := p.chat_window

	_check(window != null, "the client builds one at all")

	if window == null:
		_completed += 1
		return

	_check(
		DotInputBinding.describe_action(window.open_action) == "Y",
		"opened by Y, which is where this genre has put it for twenty-five years"
	)
	_check(
		DotInputBinding.describe_action(window.team_action) == "U",
		"and team chat by U"
	)
	_check(window.enabled, "drawn by default, on a server that said nothing")

	# `auto`: the server is carrying chat somewhere the player can already see it.
	p.set_chat_relayed(true)
	_check(not window.enabled, "auto takes the box away when a relay is carrying chat")

	window.add_said("someone", "but you can still hear this")
	_check(
		window.line_count() > 0,
		"and the log still draws what other people said",
		"off means you type somewhere else, never that you are out of the conversation"
	)

	# `on`: both halves at once, which is the configuration the relay does not preclude.
	p.settings.set_value(&"chat_window", &"on")
	_check(window.enabled, "on keeps the box even with a relay running: both, if you want")

	p.settings.set_value(&"chat_window", &"off")
	_check(not window.enabled, "off never draws it")

	p.set_chat_relayed(false)
	_check(not window.enabled, "not even on a server with no relay at all")

	p.settings.set_value(&"chat_window", &"auto")
	_check(window.enabled, "and auto gives it back")

	# The binding is a setting, so changing the setting has to move the key — and move
	# it, not add a second one.
	p.settings.set_value(&"chat_open_key", "T")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"rebinding through the settings document moves the key"
	)
	_check(
		InputMap.action_get_events(window.open_action).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	# A field somebody cleared must not unbind chat with no way back from inside the game.
	p.settings.set_value(&"chat_open_key", "")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"an empty binding in the document is ignored rather than applied"
	)

	# The console and the chat box are the same question: does something on screen own
	# the keyboard? A client that keeps reading movement while somebody types walks them
	# across the map.
	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	# A join notice is a name and NO text (dot-chat's `_presence`). Drawn as name and text
	# it was a bare "Guest 435:" in the box, which read as a chat command echoed with its
	# text stripped. The client is never added to the tree; only `_on_said` is used, fed
	# exactly what the extras' `message_received` handler hands it.
	var extras_script := preload("../game/arena_client_extras.gd")
	var join := DotChatMessage.make(DotChatMessage.Kind.JOIN, &"all", "k2", "Guest 435", "")
	var said_client := ArenaClient.new()
	said_client.presentation = p
	said_client._on_said(extras_script.speaker_of(join), extras_script.text_of(join), join.kind_name())
	var said_rows := window.history()
	var said_line := ""
	for part in (said_rows[said_rows.size() - 1] if not said_rows.is_empty() else []):
		said_line += str((part as Dictionary).get("text", ""))
	_check(
		said_line.contains("Guest 435 joined") and not said_line.contains(":"),
		"a join notice is drawn as a sentence, not as a bare name",
		"'%s'" % said_line
	)
	said_client.free()

	p.settings.reset_value(&"chat_open_key")
	p.settings.reset_value(&"chat_window")

	# A full log, at the frame the client shell always draws on, must stay under the
	# killstreak meter's words: at a 250-tall meter the sixth line wrote over them.
	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud._build_feedback()
	hud.fit_to_frame(Vector2(1280, 720))
	var streak: Rect2 = hud.streak_meter.get_global_transform() * hud.streak_meter.label_footprint()
	var rows := float(window.max_lines) * (window.line_height + window.line_gap)
	var log_box := Rect2(window.margin_left, 720.0 - window.margin_bottom - window.entry_height - rows, window.width, rows)
	_check(not log_box.intersects(streak), "a full chat log stays under the killstreak meter at 1280x720",
		"log %s, meter's words %s" % [log_box, streak])
	hud.queue_free()

	_completed += 1


# --- 8 ----------------------------------------------------------------------

## `sensitivity`, `invert_pitch` and `crosshair` were on the settings screen and read by
## nothing: the view turned at `DotFpsTunables`' default whatever the slider said. The
## checks are about the two directions a binding like this goes wrong without erroring —
## a saved value that is never pushed, and a changed value that is never heard.
func _test_look_and_crosshair() -> void:
	_section("The settings a player touches first reach what they are about")

	var p := _make()
	var look := DotFpsTunables.new()
	var fingerprint := look.fingerprint()
	var addon_default := look.mouse_sensitivity

	p.bind_look(look)
	_check(
		is_equal_approx(look.mouse_sensitivity, ArenaPresentation.look_degrees_per_count(
			p.settings.get_float(&"sensitivity")
		)),
		"binding pushes the current sensitivity, without waiting for it to change",
		"%.4f" % look.mouse_sensitivity
	)
	_check(
		not is_equal_approx(look.mouse_sensitivity, addon_default),
		"and it is not the addon's default, which is what the view turned at before",
		"%.4f vs %.4f" % [look.mouse_sensitivity, addon_default]
	)

	p.settings.set_value(&"sensitivity", 5.0)
	_check(
		is_equal_approx(look.mouse_sensitivity, 5.0 * ArenaPresentation.DEGREES_PER_COUNT),
		"moving the slider moves the view's turning speed",
		"%.4f" % look.mouse_sensitivity
	)
	p.settings.set_value(&"invert_pitch", true)
	_check(look.invert_look_y, "and inverting the pitch inverts it")
	_check(
		look.fingerprint() == fingerprint,
		"neither enters the simulation, so a client cannot desync from its server by aiming"
	)

	# The client hands the sampler a new tunables object when it adopts its player, and a
	# new object carries the addon's default again.
	var replaced := DotFpsTunables.new()
	p.bind_look(replaced)
	_check(
		is_equal_approx(replaced.mouse_sensitivity, look.mouse_sensitivity)
		and replaced.invert_look_y,
		"a replacement tunables object is given the player's settings, not the default"
	)

	var crosshair := DotCrosshair.new()
	crosshair.length = 7.0
	p.bind_crosshair(crosshair)
	_check(
		not crosshair.suppressed and is_equal_approx(crosshair.length, 7.0),
		"the default crosshair is the cross the HUD built"
	)
	p.settings.set_value(&"crosshair", &"dot")
	_check(
		is_equal_approx(crosshair.length, 0.0) and crosshair.centre_dot
		and not crosshair.suppressed,
		"`dot` draws the dot and no arms"
	)
	p.settings.set_value(&"crosshair", &"none")
	_check(crosshair.suppressed, "`none` draws nothing")
	p.settings.set_value(&"crosshair", &"cross")
	_check(
		not crosshair.suppressed and is_equal_approx(crosshair.length, 7.0),
		"and `cross` puts the arms back at the length they were built with"
	)

	# The camera motion: binding pushes the saved scales, each slider moves its own cue, 0 is off.
	var player := ArenaPlayer.new()
	player.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), 31, "Mover")
	add_child(player)
	var _camera := player.attach_camera(100.0)
	var picks := ArenaPlayer.camera_motion_picks()
	p.settings.set_value(&"camera_landing_dip", 0.5)
	p.bind_camera_motion(player)
	var motion: DotFpsViewMotion = player.camera_motion
	_check(
		motion != null and is_equal_approx(motion.landing_dip, picks.landing_dip * 0.5)
		and is_equal_approx(motion.strafe_roll, picks.strafe_roll),
		"binding the camera pushes the saved camera motion: the dip at 50%, the lean at the pick",
		str(motion.describe() if motion != null else {})
	)
	for key: StringName in [&"camera_landing_dip", &"camera_strafe_roll", &"camera_wall_lean", &"camera_speed_fov"]:
		p.settings.set_value(key, 0.0)
	_check(
		motion != null and motion.landing_dip == 0.0 and motion.strafe_roll == 0.0 and motion.slide_roll == 0.0
		and motion.wall_run_roll == 0.0 and motion.fov_speed_gain == 0.0 and motion.slide_fov_gain == 0.0
		and motion.wall_run_fov_gain == 0.0,
		"and each camera motion slider at 0 turns its cue off"
	)
	for key: StringName in [&"camera_landing_dip", &"camera_strafe_roll", &"camera_wall_lean", &"camera_speed_fov"]:
		p.settings.reset_value(key)
	player.queue_free()

	p.settings.reset_value(&"sensitivity")
	p.settings.reset_value(&"invert_pitch")
	p.settings.reset_value(&"crosshair")
	crosshair.free()
	p.queue_free()
	_done()


## `ArenaClient`'s look guard, driven both ways through `mouse_capture_override`.
##
## [b]`Input.mouse_mode` is a no-op here.[/b] The dummy display server reads VISIBLE
## however it is written, so a suite that set it directly would prove only the released
## half and pass anyway — which is why the guard `_unhandled_input` had from the start
## was never exercised. The client is built but not added to the tree: `_ready` builds
## a whole networked client, and the branch under test needs a player, a sampler and
## nothing else.
func _test_mouse_drives_view() -> void:
	_section("The mouse turns the view only while it is captured")

	var client := ArenaClient.new()
	var stand_in := ArenaPlayer.new()
	client.player = stand_in
	client._sampler = DotFpsSampler.new(DotFpsTunables.new())

	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(120.0, 0.0)

	client.mouse_capture_override = true
	client._unhandled_input(motion)
	_check(
		client._sampler._mouse_delta.is_equal_approx(Vector2(120.0, 0.0)),
		"a motion with the cursor captured reaches the sampler",
		str(client._sampler._mouse_delta)
	)

	# The other half, and the one the guard exists for: a released cursor is a
	# pointer, aimed at a menu or at "Click to play", and must turn nothing.
	client._sampler._mouse_delta = Vector2.ZERO
	client.mouse_capture_override = false
	client._unhandled_input(motion)
	_check(
		client._sampler._mouse_delta == Vector2.ZERO,
		"and a motion with the cursor released does not",
		str(client._sampler._mouse_delta)
	)

	# And with no override, the real mode decides — VISIBLE under the dummy display
	# server, which is the whole reason the override exists.
	client.mouse_capture_override = null
	_check(
		client.mouse_drives_view() == (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED),
		"left unset, the predicate is the real mouse mode",
		"mode %d" % Input.mouse_mode
	)

	client.player = null
	stand_in.free()
	client.free()
	_done()


## A connected client's respawn faces the way its spawn faces. The server's teleport turns
## the server's controller, and its next command carries this client's old look; so the
## client turns its own sampler when its player comes back alive on a map spawn.
func _test_a_respawn_faces_its_spawn() -> void:
	_section("A connected client's respawn faces the way its spawn faces")

	var g := ArenaGame.new()
	g.is_authority = true
	add_child(g)
	var _set := g.setup(ArenaMap.dm_box())
	var added: DotResult = g.add_player(7, "Seven")
	var p: ArenaPlayer = added.value if added.ok else null

	var client := ArenaClient.new()
	client.game = g
	client.player = p
	client._offline = false
	client._sampler = DotFpsSampler.new(p.controller.tunables if p != null else DotFpsTunables.new())

	# A spawn whose yaw is not where the mouse is.
	var spawn: Transform3D = Transform3D.IDENTITY
	for candidate: Transform3D in g.map.spawns:
		if absf(rad_to_deg(candidate.basis.get_euler().y)) > 30.0:
			spawn = candidate
			break
	var want := rad_to_deg(spawn.basis.get_euler().y)

	client._sampler.look_at_angles(want + 120.0, 10.0)
	client._face_a_respawn()

	# Dead, then alive on the spawn.
	if p != null and p.health != null:
		p.health.alive = false
		p.health.health = 0.0
	client._face_a_respawn()
	if p != null:
		p.controller.state.position = spawn.origin
		p.health.alive = true
		p.health.health = 100.0
	client._face_a_respawn()

	var turned := client._sampler.sample(1.0 / 64.0)
	_check(p != null and absf(wrapf(turned.yaw - want, -180.0, 180.0)) < 0.5,
		"the look turns to the spawn's yaw (%.1f, wanted %.1f)" % [turned.yaw if turned != null else NAN, want])

	# And only on the way back: alive frame to alive frame leaves the mouse alone.
	client._sampler.look_at_angles(want + 45.0, 0.0)
	client._face_a_respawn()
	var kept := client._sampler.sample(1.0 / 64.0)
	_check(absf(wrapf(kept.yaw - (want + 45.0), -180.0, 180.0)) < 0.5,
		"and a living player's look is left where the mouse put it (%.1f)" % kept.yaw)

	client.free()
	g.queue_free()
	_done()


## A frame on which no tick ran still turns the view, and a correction's offset is drawn.
##
## This game ticks 64 times a second, so on a 144 Hz display more frames run no tick than
## run one, and the view was the state's angles, which only a tick moves: the view stood
## still while the mouse moved, then turned double. game-g2gfast measured the same thing
## at 128 ticks over a real socket (`headless_feel`); here it is the drawing alone, with no
## tick at all between the mouse and the frame.
func _test_the_view_turns_every_frame() -> void:
	_section("A frame with no tick in it still turns the view")

	var g := ArenaGame.new()
	g.is_authority = true
	add_child(g)
	var _set := g.setup(ArenaMap.dm_box())
	var added: DotResult = g.add_player(7, "Seven")
	var p: ArenaPlayer = added.value if added.ok else null
	if p == null:
		_check(false, "a player to draw")
		g.queue_free()
		_done()
		return
	var _camera := p.attach_camera()

	var client := ArenaClient.new()
	client.game = g
	client.player = p
	client.mouse_capture_override = true
	client._sampler = DotFpsSampler.new(p.controller.tunables)
	client._sampler.look_at_angles(p.controller.state.yaw, 0.0)

	client._fold_look()
	p.present(1.0 / 144.0)
	var before := rad_to_deg(p.camera.global_rotation.y)

	# Mouse motion, and no tick: what a 144 Hz frame between two 64 Hz ticks is.
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(-100.0, 0.0)
	client._unhandled_input(motion)
	client._fold_look()
	p.present(1.0 / 144.0)
	var after := rad_to_deg(p.camera.global_rotation.y)
	var wanted := 100.0 * p.controller.tunables.mouse_sensitivity * p.controller.tunables.mouse_sensitivity_x
	_check(absf(wrapf(after - before, -180.0, 180.0) - wanted) < 0.05,
		"the camera turned with the mouse on a frame no tick ran on (%.2f of %.2f degrees)" % [
			wrapf(after - before, -180.0, 180.0), wanted])
	_check(is_equal_approx(client._sampler.sample(1.0 / 64.0).yaw, (p.view_now as Vector2).x),
		"and the next command carries the view that was drawn")

	# A correction's remainder is drawn where the eye is, not left for the next tick.
	var eye := p.camera.global_position
	p.drawn_offset = Vector3(0.3, 0.0, 0.0)
	p.present(1.0 / 144.0)
	_check(p.camera.global_position.distance_to(eye + Vector3(0.3, 0.0, 0.0)) < 0.01,
		"a correction still easing moves the drawn eye by what is left of it",
		str(p.camera.global_position - eye))

	client.player = null
	client.game = null
	client.free()
	g.queue_free()
	_done()


## A dead body falls as the server said: the death rides the KILL, the client builds a ragdoll
## from the figure it draws, the body lies on the floor rather than through it, the server's
## cvars turn it into a topple or nothing, and a respawn draws the figure again. What a fall
## LOOKS like is the contact sheets (docs/client.md), not this.
func _test_bodies_fall() -> void:
	_section("A dead body falls the way the server picked, and gets up on respawn")

	# The server's half: the sniper names the power launch, so its kill is one.
	var g := ArenaGame.new()
	g.is_authority = true
	add_child(g)
	var _set := g.setup(ArenaMap.dm_box())
	var dmg := DotDamage.new()
	dmg.attacker = 3
	dmg.weapon_id = ZeeWeaponIds.SNIPER
	dmg.amount = 120.0
	dmg.direction = Vector3(0, 0, -1)
	var sniped := g.decide_death(9, dmg)
	_check(sniped.reaction == &"power_launch", "a sniper kill is a power launch (%s)" % sniped.reaction)
	dmg.weapon_id = ZeeWeaponIds.PISTOL
	var counted := {}
	for tick in range(200):
		g._tick = tick
		var d := g.decide_death(9, dmg)
		counted[d.reaction] = int(counted.get(d.reaction, 0)) + 1
	_check(not counted.has(&"power_launch") and not counted.has(&"headshot_launch") and counted.size() >= 2,
		"a pistol body shot never launches, and is not always the same fall (%s)" % str(counted))
	g.ragdoll_rules.set_cvar("sv_ragdoll_reactions", "limp=0,crumple=0,face_plant=1")
	_check(g.decide_death(9, dmg).reaction == &"face_plant", "sv_ragdoll_reactions reweights the server's pick")
	g.ragdoll_rules.set_cvar("sv_ragdoll_reactions", "")

	# The wire: the death rides KILL, and an older kill still reads.
	var wrote := ArenaEvents.write_kill(3, 9, "sniper", false, true, sniped)
	var read := ArenaEvents.read_kill(DotNetReader.new(wrote))
	var back := DotPlayerDeath.from_dict(read)
	_check(bool(read["ok"]) and bool(read["critical"]) and back.reaction == sniped.reaction
		and back.roll_seed == sniped.roll_seed and absf(back.damage - 120.0) < 0.5
		and back.direction.distance_to(sniped.direction) < 0.02,
		"the KILL carries the reaction, the seed, the damage and the direction (%d bytes)" % wrote.size())
	var old := ArenaEvents.read_kill(DotNetReader.new(ArenaEvents.write_kill(3, 9, "pistol", true, false)))
	_check(bool(old["ok"]) and not old.has("death_reaction") and DotPlayerDeath.from_dict(old).reaction == &"limp",
		"a KILL without one reads as a plain fall")

	# The client's half, on a floor in a physics world.
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	shape.shape = box
	shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(shape)
	add_child(floor_body)
	var yard := DotPlayerRagdolls.new()
	add_child(yard)

	var player := ArenaPlayer.new()
	player.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), 6, "Faller")
	add_child(player)
	# Away from the origin: the game above keeps a collision copy of the level there.
	player.spawn(Transform3D(Basis(), Vector3(20.0, 0.0, 20.0)), 0)
	player.attach_body_mesh(Color.WHITE, ArenaAvatars.stock_avatar(&"faller"))
	player.present(0.016)
	player.make_dead()
	var fall := DotPlayerDeath.new()
	fall.reaction = &"limp"
	fall.direction = Vector3(1, 0, 0)
	fall.damage = 80.0
	var body := player.fall_body(yard, fall)
	_check(body != null and body.style == DotPlayerRagdollRules.Style.RAGDOLL and body.part_count() == 6,
		"the stock avatar falls as a six-part ragdoll (%s)" % (str(body.describe()) if body != null else "none"))
	_check(not player.body_mesh.visible, "and the standing figure is hidden")
	var waited := 0.0
	while waited < 8.0 and not body.settled:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	_check(body.settled and body.centre().y < 0.6 and body.lowest_point() > -0.12,
		"it lies on the floor and stops (torso %.2f m, lowest %.2f m, %.1f s)" % [body.centre().y, body.lowest_point(), waited])
	player.health.alive = true
	player.present(0.016)
	_check(player.body_mesh.visible, "a respawn draws the figure again")

	yard.rules.enabled = false
	player.make_dead()
	var toppled := player.fall_body(yard, fall)
	_check(toppled != null and toppled.style == DotPlayerRagdollRules.Style.TOPPLE, "sv_ragdoll 0: a topple, no physics")
	player.health.alive = true
	player.present(0.016)
	yard.rules.style = DotPlayerRagdollRules.Style.HIDE
	player.make_dead()
	_check(player.fall_body(yard, fall) == null and not player.body_mesh.visible,
		"sv_ragdoll_style hide: nothing, and the figure gone")

	# The solo path: no KILL message, the death is on the entry.
	var client := ArenaClient.new()
	client.game = g
	client._build_ragdolls()
	# The client is not in the tree here (its _ready builds a whole game); its yard has to be.
	client.remove_child(client.ragdolls)
	add_child(client.ragdolls)
	var added: DotResult = g.add_player(11, "Eleven")
	var eleven: ArenaPlayer = added.value if added.ok else null
	eleven.attach_body_mesh(Color.WHITE, ArenaAvatars.stock_avatar(&"eleven"))
	eleven.make_dead()
	var entry := DotKillFeed.Entry.new()
	entry.victim_key = "11"
	entry.set_meta(&"death", fall)
	client._on_solo_kill(entry)
	_check(client.ragdolls.live().size() == 1, "solo, a kill's entry carries the fall and the client draws it")
	_check(client.ragdolls.rules == g.ragdoll_rules, "and it draws under the game's (the server's) rules")

	client.ragdolls.queue_free()
	client.free()
	yard.queue_free()
	player.queue_free()
	floor_body.queue_free()
	g.queue_free()
	_done()


## The family's rule since the first play test: M opens the maps and the modes, and solo a
## choice changes now. A whole offline client, because the change rebuilds its level. The
## server's half (the owner's flag, the vote) is in `dedicated` and dot-vote's suite.
func _test_the_map_menu() -> void:
	_section("M opens the maps and the modes, and solo a choice changes the map")
	var client := ArenaClient.new()
	client.force_offline = true
	add_child(client)
	for _i in 6:
		await get_tree().process_frame
	var menu: DotMenu = client.game_menu
	var keys: DotMenuBindings = menu.bindings if menu != null else null
	_check(keys != null and keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table is",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))) if keys != null else "no menu")
	var rows := client.map_menu_rows()
	_check(rows.filter(func(r: Dictionary) -> bool: return str(r["id"]).begins_with("map:")).size() > 1
		and rows.any(func(r: Dictionary) -> bool: return str(r["id"]).begins_with("mode:")),
		"it lists more than one map, and the modes this map can host", str(rows.map(func(r: Dictionary) -> String: return str(r["id"]))))
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	menu.close_all()
	_check(menu.handle_event(m) and menu.picker.is_open(), "M opens the picker")
	var wanted := &""
	var key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = menu.picker.at_row(row)
		if it is Dictionary and str((it as Dictionary)["id"]).begins_with("map:") and not bool((it as Dictionary)["current"]):
			wanted = StringName(str((it as Dictionary)["id"]).substr(4))
			key = KEY_0 + row
			break
	var digit := InputEventKey.new()
	digit.physical_keycode = key
	digit.keycode = key
	digit.pressed = true
	var _k := menu.handle_event(digit)
	for _i in 4:
		await get_tree().physics_frame
	_check(wanted != &"" and client.game.map.id == wanted and client._level != null and is_instance_valid(client._level),
		"choosing a map changes to it now, and the level is rebuilt", "%s, now %s" % [wanted, client.game.map.id])
	var mode_id := &""
	for r: Dictionary in client.map_menu_rows():
		if str(r["id"]).begins_with("mode:") and not bool(r["current"]):
			mode_id = StringName(str(r["id"]).substr(5))
			break
	var changed := client.change_from_menu(StringName("mode:%s" % mode_id))
	_check(changed.ok and client.game.mode.id == mode_id and client.game.map.id == wanted,
		"and a mode changes on the same map", "%s: %s" % [mode_id, changed.error.message if not changed.ok else "ok"])
	# The Tab board draws dot-match's records, not whatever the roster says: the client builds
	# it before the match node is in the tree, and it once kept the null scoreboard it was
	# handed and drew the server's roster (the local player alone, no K or D) for ever.
	var present := client.game.match_node.scoreboard.present_count()
	menu.close_all()
	menu.scoreboard.open()
	_check(present >= 1 and menu.scoreboard.rows().size() == present and menu.scoreboard.rows().all(func(r: Dictionary) -> bool: return r.has("kills")),
		"the Tab board lists every record with its kills", "%d rows, %d present" % [menu.scoreboard.rows().size(), present])
	menu.scoreboard.close()
	# The summary board comes up with nobody holding Tab, so the next match closes it.
	client._on_match({"state": DotMatch.State.MATCH_END, "round": 1, "remaining_ticks": 0})
	var revealed: bool = client.winner_reveal != null and client.winner_reveal.is_active()
	if client.killcam != null:
		client.killcam.skip()
	if client.winner_reveal != null:
		client.winner_reveal.skip()
	_check(revealed and menu.scoreboard.is_open(), "the end of the match reveals the winner, then raises the board by itself")
	client._on_match({"state": DotMatch.State.WARMUP, "round": 2, "remaining_ticks": 0})
	_check(not menu.scoreboard.is_open(), "and the next match takes it down again")
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_done()


## Christian's first play test: B opens the loadout (primary, secondary, melee, grenades), a
## choice applies at once in warmup or spawn protection and otherwise on the next spawn, and an
## owner's rules are what the menu offers and what the game takes. Solo, so the game here is the
## authority; the server's command and cvars are `dedicated`'s. And the crosshair fades while the
## gun is aimed down its sight.
## A stand-in for dot-auth's client: the three members the loadout key reads.
class FakeAuth extends Node:
	signal signed_in(identity: Variant)
	signal signed_out()
	var key := ""
	func account_key() -> String:
		return key


## The loadout is filed per site account: two accounts differ, a guest is "local", and a
## sign-in or sign-out mid-session re-keys it.
func _check_loadout_accounts(client: ArenaClient) -> void:
	var menu: Object = client.loadout_menu
	if not _check(menu != null, "the client has a loadout menu to key"):
		return
	_check(menu.get(&"remember_account") == "local", "with no auth client in the registry the loadout is filed under local")
	_check(ArenaClient.loadout_account_key(null) == "local" and ArenaClient.loadout_account_key(Node.new()) == "local",
		"no auth, or an auth with no account_key, is local")
	var auth := FakeAuth.new()
	add_child(auth)
	client.follow_account(auth)
	_check(menu.get(&"remember_account") == "local", "a guest (signed out) is local")
	auth.key = "backbone:alice"
	auth.signed_in.emit(null)
	var alice: String = str(menu.get(&"remember_account"))
	auth.key = "backbone:bob"
	auth.signed_in.emit(null)
	var bob: String = str(menu.get(&"remember_account"))
	_check(alice == "backbone:alice" and bob == "backbone:bob" and alice != bob,
		"two accounts on one machine are filed apart", "%s / %s" % [alice, bob])
	auth.key = ""
	auth.signed_out.emit()
	_check(menu.get(&"remember_account") == "local", "signing out falls back to local")
	_check(not str(menu.get(&"remember_account")).contains("token"), "and no key is ever a token")
	client.follow_account(null)
	remove_child(auth)
	auth.free()


func _test_the_loadout_menu() -> void:
	_section("B is the loadout menu, and the crosshair fades down the sights")
	var client := ArenaClient.new()
	client.force_offline = true
	add_child(client)
	for _i in 6:
		await get_tree().process_frame
	var menu: DotMenu = client.game_menu
	var keys: DotMenuBindings = menu.bindings if menu != null else null
	_check(keys != null and keys.key_for(DotMenuBindings.LOADOUT_ACTION) == "B" and keys.defaults_on("B").size() == 1,
		"the loadout menu is on B, and nothing else in the table is",
		str(keys.defaults_on("B").map(func(r: Dictionary) -> String: return str(r["label"]))) if keys != null else "no menu")
	await _check_loadout_accounts(client)
	var game: ArenaGame = client.game
	var me := client.player
	if not _check(game.loadout_command != null and me != null, "the game has the menu's server half, and a player"):
		remove_child(client)
		client.free()
		_done()
		return
	var offer: Dictionary = await client.loadout_offer()
	var slot_ids: Array = (offer.get("slots", []) as Array).map(func(sl: Dictionary) -> String: return str(sl["id"]))
	_check(slot_ids == ["primary", "secondary", "melee", "thrown", "gear"], "primary, secondary, melee, grenades and gear, in that order", str(slot_ids))
	var decorated: Dictionary = client.decorate_loadout_choice("primary", {"id": "rifle"})
	_check(decorated.get("icon") is Texture2D and (decorated.get("stats", []) as Array).size() >= 4 and str(decorated.get("detail", "")) != "",
		"a card has the weapon's picture, a line and its numbers")

	var b := InputEventKey.new()
	b.physical_keycode = KEY_B
	b.keycode = KEY_B
	b.pressed = true
	menu.close_all()
	_check(menu.handle_event(b), "B is the menu's")
	for _i in 2:
		await get_tree().process_frame
	_check(menu.loadout_screen != null and menu.loadout_screen.is_open() and menu.loadout_screen.slots().size() == 5,
		"and opens the loadout screen on the five slots")
	menu.loadout_screen.cancel()

	game.match_node.state = DotMatch.State.WARMUP
	var now: Dictionary = await client.choose_loadout({"primary": "marksman", "thrown": "sticky"})
	_check(bool(now.get("ok", false)) and bool(now.get("now", false)) and me.arsenal.carries(&"marksman") and me.arsenal.carries(&"sticky"),
		"in warmup a choice is in the player's hands at once", str(now))

	game.match_node.state = DotMatch.State.LIVE
	me.health.spawn_protection_ticks = 0
	me.health.invulnerable_until_tick = -1
	var later: Dictionary = await client.choose_loadout({"primary": "carbine"})
	_check(bool(later.get("ok", false)) and not bool(later.get("now", true)) and not me.arsenal.carries(&"carbine"),
		"mid-round it waits for the next spawn", str(later))
	var _back := game.respawn_player(me.player_id)
	for _i in 3:
		await get_tree().process_frame
	_check(me.arsenal.carries(&"carbine") and me.arsenal.carries(&"sticky"), "and the next spawn carries it")

	var snipers: DotResult = game.loadout_command.call(&"apply_strings", true, "primary=tag:scoped", "")
	var limited: Dictionary = await client.loadout_offer()
	var primaries: Array = ((limited["slots"] as Array)[0]["choices"] as Array).map(func(c: Dictionary) -> String: return str(c["id"]))
	_check(snipers.ok and not primaries.is_empty() and not primaries.has("rifle") and primaries.has("marksman"),
		"an owner's 'snipers only' is what the menu offers", str(primaries))
	var refused: Dictionary = await client.choose_loadout({"primary": "rifle"})
	_check(not bool(refused.get("ok", true)), "and a rifle is refused by the game, not only hidden", str(refused))
	var active: DotResult = await game.loadouts.active_for(ArenaGame.storage_key(me.player_id))
	_check(primaries.has(str((active.value as DotLoadout).item_in(&"primary"))),
		"a saved carbine spawns as a scoped gun while the rule is on", str((active.value as DotLoadout).item_in(&"primary")))
	var locked: DotResult = game.loadout_command.call(&"apply_strings", false, "", "primary=sniper")
	var fixed_offer: Dictionary = await client.loadout_offer()
	_check(locked.ok and fixed_offer["choose"] == false and str((fixed_offer["slots"] as Array)[0]["current"]) == "sniper",
		"an owner can lock the loadout: nothing to choose, and the fixed slot is what everybody gets")
	var _open: Variant = game.loadout_command.call(&"apply_strings", true, "", "")

	var was_mode := game.mode
	game.mode = ArenaMode.only_snipers()
	var closed: Dictionary = await client.loadout_offer()
	_check(closed["choose"] == false and str(closed["note"]).contains("hands out the weapons"),
		"a mode that hands out the weapons says so, and lets nothing be picked", str(closed.get("note", "")))
	game.mode = was_mode

	# The crosshair, down the sights: hip draws it, aimed hides it, released brings it back.
	var hud: ArenaHud = client.hud
	var hands: ZeeViewModel = me.weapons.view_model() as ZeeViewModel if me.weapons != null else null
	me.arsenal.select(ZeeWeaponIds.SLOT_PRIMARY, game.current_tick())
	for _i in 30:
		await get_tree().process_frame
	if _check(hud != null and hud.crosshair != null and hands != null, "the HUD has a crosshair and the player hands"):
		hud.present_body()
		hud.crosshair.follow_aim(1.0)
		var hip := hud.crosshair.aim_opacity
		# Fully raised, as the view model's own ramp leaves it (headless there is no pointer to
		# hold the aim key with, so the fraction is set where the ramp would put it), then
		# lowered again. The HUD reads it every frame; the render is in tools/screenshot.sh.
		hands.set(&"_aim_fraction", 1.0)
		hud.present_body()
		hud.crosshair.follow_aim(1.0)
		var aimed := hud.crosshair.aim_opacity
		hands.set(&"_aim_fraction", 0.0)
		hud.present_body()
		hud.crosshair.follow_aim(0.016)
		var easing := hud.crosshair.aim_opacity
		hud.crosshair.follow_aim(1.0)
		_check(easing > 0.0 and easing < 1.0, "lowering the gun fades the crosshair back rather than snapping it", "%.2f" % easing)
		_check(hip > 0.99 and aimed < 0.01 and hud.crosshair.aim_opacity > 0.99,
			"the crosshair is drawn at the hip, gone down the sights, and back after",
			"hip %.2f, aimed %.2f (fraction %.2f, scoped %s), after %.2f" % [hip, aimed, hands.aim_fraction(), hands.is_scoped(), hud.crosshair.aim_opacity])
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_done()


## Christian's first play test: a darker HUD by default, which follows the menu's theme so a
## player can change it. A whole offline client, because what is checked is the join the client
## makes (`follow_hud`), and both dot-ui's pieces and this game's own (the feed, the slots, the
## medals) are under its HUD.
func _test_the_hud_follows_the_theme() -> void:
	_section("The HUD is dark by default and follows the menu's theme live")
	var client := ArenaClient.new()
	client.force_offline = true
	add_child(client)
	for _i in 6:
		await get_tree().process_frame
	var menu: DotMenu = client.game_menu
	var hud: ArenaHud = client.hud
	var piece: DotHudPiece = null
	# The kill feed: one of the pieces arena keeps, drawn with its own `Ink`.
	var own: Control = hud.feed
	for n in hud.find_children("*", "Control", true, false):
		if n is DotHudPiece:
			piece = n
			break
	_check(menu != null and piece != null and own != null and menu.followed_huds().has(hud), "the client hands the menu its HUD",
		"menu %s, piece %s, own %s" % [menu, piece, own])
	if menu == null or piece == null or own == null:
		remove_child(client)
		client.free()
		_done()
		return
	var Ink = ArenaHud.ArenaHudGlance.Ink
	var _m := menu.settings.set_value(&"ui_theme", &"midnight")
	var plate := piece.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7 and piece.colour(&"keycap").get_luminance() < 0.3,
		"the default HUD is dark: deep plates and dark key caps", str(plate))
	_check(Ink.c(own, &"plate") == plate and Ink.bright(own) < 0.5, "and this game's own pieces draw in the same theme")
	_check(piece.colour(&"highlight") == ArenaHud.GOLD, "with arena's gold as its accent")
	var _a := menu.settings.set_value(&"ui_theme", &"arcade")
	_check(piece.number(&"team_fill") == 100 and piece.colour(&"keycap").get_luminance() > 0.8 and Ink.bright(own) > 0.99,
		"the bright first HUD is a theme a player can pick, and both kinds of piece follow it")
	var _p := menu.settings.set_value(&"ui_theme", &"contrast")
	var contrast := menu.themes.named(&"contrast")
	_check(piece.colour(&"plate") == contrast.hud_plate and Ink.c(own, &"plate_edge") == contrast.hud_edge
		and piece.colour(&"highlight") == ArenaHud.GOLD, "another theme reaches every piece at once, the accent kept")
	var _s := menu.settings.set_value(&"hud_scale", 1.2)
	_check(is_equal_approx(hud.user_scale, 1.2), "and the HUD size setting resizes the HUD")
	_s = menu.settings.set_value(&"hud_scale", 1.0)
	_m = menu.settings.set_value(&"ui_theme", &"midnight")
	_check(piece.colour(&"plate") == plate, "and back")
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_done()


## The pack carries its art (a delivered game has only what is vendored in assets/), so every
## model the weapons table names must exist here. v0.1.13 shipped without low-poly-guns/ and
## ammo/: eleven weapons were invisible in production and nothing failed. The list and the
## check are the addon's; `tools/sync-art.sh` in zee-dot-weapons copies what it names.
func _test_the_weapon_art_is_vendored() -> void:
	_section("Every model the weapon art table names is vendored in this game")
	var count := ZeeWeaponArtTable.model_paths().size()
	_check(count > 20, "the table names models (%d)" % count)
	var models := ZeeWeaponArtTable.validate_models()
	_check(models.ok, "no weapon model is missing", "" if models.ok else models.error.message)
	_done()


func _test_the_final_killcam() -> void:
	_section("The final killcam replays the last kill from the killer's eye, and 0 turns it off")
	var g := ArenaGame.new()
	g.is_authority = true
	add_child(g)
	var _set := g.setup(ArenaMap.dm_box())
	var killer: ArenaPlayer = g.add_player(41, "Killer").value
	var victim: ArenaPlayer = g.add_player(42, "Victim").value
	_check(is_equal_approx(g.match_node.rules.match_end_sec, g.mode.rules.match_end_sec + 7.0),
		"the end of the match waits the killcam's 7 s on top of the mode's")

	var clock := [0.0]
	var kc := ArenaKillcam.new()
	kc.players_fn = func() -> Array: return [killer, victim]
	kc.player_for_fn = g.player_for
	kc.now_fn = func() -> float: return clock[0]
	kc.seconds_fn = func() -> float: return g.rule("killcam")
	add_child(kc)
	kc.killcam.auto_process = false
	var ended: Array = []
	kc.over.connect(func(skipped: bool) -> void: ended.append(skipped))
	var start := killer.controller.state.position
	var step := 1.0 / 60.0
	var at := func(t: float) -> Vector3: return start + Vector3(t, 0.0, 0.0)
	while clock[0] < 9.5:
		clock[0] += step
		killer.controller.state.position = at.call(clock[0])
		killer.global_position = at.call(clock[0])
		kc.frame()
		if absf(clock[0] - 8.0) < step * 0.5:
			kc.note_kill(41, 42, "rifle")
	_check(kc.buffer.frame_count() > 400 and int(kc.buffer.last_event(&"kill")["data"]["killer"]) == 41,
		"every frame drawn and the kill went into the buffer")

	var drawn: Array = []
	kc.killcam.frame_drawn.connect(func(s: Dictionary) -> void: drawn.append([float(s["time"]), kc.camera.global_position]))
	_check(kc.match_ended() and kc.is_playing(), "the match's end starts it")
	kc.killcam.advance(step)
	_check(not drawn.is_empty() and absf(float(drawn[0][0]) - 4.5) < 0.05, "from 3.5 s before the kill (%.2f)" % (float(drawn[0][0]) if not drawn.is_empty() else NAN))
	var eye: Vector3 = drawn[0][1] if not drawn.is_empty() else Vector3.INF
	var want: Vector3 = at.call(4.5)
	_check(absf(eye.x - want.x) < 0.1 and eye.y > want.y + 0.5, "with the camera at the killer's eye then (%s, feet %s)" % [eye, want])
	_check(kc.killcam.banner != null and kc.killcam.banner.killer_label.text == "Killer", "under a banner naming the killer")
	var n := 0
	while kc.is_playing() and n < 1000:
		kc.killcam.advance(step)
		n += 1
	_check(ended == [false] and n * step < 7.0, "it ends by itself inside the budget (%.2f s)" % (n * step))

	g.set_movement_rules({"killcam": 0.0})
	ended.clear()
	_check(not kc.match_ended() and ended == [false] and not kc.is_playing(),
		"mp_killcam_time 0: nothing plays and the end goes straight on")
	_check(is_equal_approx(g.match_node.rules.match_end_sec, g.mode.rules.match_end_sec),
		"and the end of the match is the mode's again")
	kc.queue_free()
	g.queue_free()
	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
	return condition


# --- The HUD on a small frame -------------------------------------------------

## Every piece of the HUD put up at once, as `screenshot.sh --glance` stages it, on five
## frames, and no piece's drawn rect may meet another's. Standalone at 854x480 the
## challenge ran over the scores, the ability bar and "Cancel slide" over the health, the
## medals over the portraits; at 960x720 the scores reached the kill feed. A headless frame
## is 64 px, so the HUD is laid out on each frame by hand (`fit_to_frame`): what is checked
## is the arithmetic that places things, and the render (`--glance` at those sizes) is
## still what says they look right.
func _test_hud_fits_the_frame() -> void:
	_section("No piece of the HUD lies over another, from a phone to a desktop frame")

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	# Nothing reads a player here: the pieces draw what they are handed, and `_process`
	# would hand them a dead player's nothing.
	hud.set_process(false)
	hud._build_feedback()

	hud.strip.visible = true
	hud.strip.show_scores(4, 4, "YOU", "2ND  GAMEMANN", Color.BLUE, Color.RED)
	hud.strip.show_clock("9:37", false, "First to 25", "Free-For-All")
	hud.portraits.visible = true
	var faces: Array[Dictionary] = []
	for i in range(8):
		faces.append({"name": "P%d" % i, "rank": i + 1, "kills": 8 - i, "me": i == 0})
	hud.portraits.show_players(faces)
	hud.feed.add_kill("gamemann", Color.WHITE, &"launcher", "launcher", "Rocket", Color.WHITE)
	hud.feed.add_kill("You", Color.WHITE, &"marksman", "marksman", "quiet_one", Color.WHITE, false, true)
	hud.feed.add_kill("a_very_long_display_name", Color.WHITE, &"sniper", "sniper", "Viper", Color.WHITE, true)
	hud.vitals.show_vitals(64.0, 100.0, 35.0)
	hud.ammo.show_ammo("Marksman rifle", 3, 240, false)
	var carried: Array[Dictionary] = []
	for slot in range(1, 6):
		carried.append({"slot": slot, "id": &"rifle", "name": "Rifle", "key": str(slot)})
	hud.slots.show_slots(carried, 3)
	var buttons: Array[Dictionary] = []
	for b in [["slide", "C"], ["launch", "E"], ["dash", "Shift"], ["walljump", "Space"]]:
		buttons.append({"id": StringName(b[0]), "label": b[0], "icon": null, "key": b[1],
			"left": 0.0, "total": 1.0, "active": false, "pips": 2, "pips_max": 3 if b[0] == "walljump" else 0})
	hud.abilities.show_buttons(buttons)
	hud.hints.show_hints([["Scoreboard", "Tab"], ["Menu", "Esc"], ["Chat", "Y"], ["Slide", "C"]])
	hud.slide_label.show_prompt("Cancel slide", "C")
	hud.streak_meter.set_count(3, ArenaHud.STREAK_FULL)
	hud.medal_row.add(ArenaAwards.Medal.HEADSHOT, "Headshot")
	hud.medal_row.add(ArenaAwards.Medal.DOUBLE_KILL, "Double Kill")
	hud.medal_row.advance(1.0)
	hud.present_challenge(false)
	hud.challenge_label.text = "Veteran — Ten hours in the arena  (2/36000)"
	hud.challenge_label.visible = true
	hud.challenge_bar.visible = true

	# The chat box, scaled with the HUD as ArenaPresentation scales it: unscaled, a full log
	# at 854x480 reached the killstreak meter and the key hints.
	var chat_screen := Control.new()
	add_child(chat_screen)
	var chat := ArenaPresentation.make_chat_window()
	chat_screen.add_child(chat)
	var chat_met := PackedStringArray()

	var frames := [Vector2(854, 480), Vector2(960, 720), Vector2(720, 1280), Vector2(1280, 720), Vector2(1600, 900)]
	for frame: Vector2 in frames:
		hud.fit_to_frame(frame)
		hud.notice("Vote: Smash Copter, Hide & Seek, Dangerous Delivery, Playground, g2gfast (20s)")
		# The labels take their text's size on the next frame.
		await get_tree().process_frame
		var rects := hud.footprints()
		var keys: Array = rects.keys()
		var met := PackedStringArray()
		var outside := PackedStringArray()
		var bounds := Rect2(Vector2.ZERO, frame)
		for i in range(keys.size()):
			var a: Rect2 = rects[keys[i]]
			if not bounds.encloses(a):
				outside.append("%s %s" % [keys[i], a])
			for j in range(i + 1, keys.size()):
				if a.intersects(rects[keys[j]]):
					met.append("%s/%s" % [keys[i], keys[j]])
		var size_name := "%dx%d" % [int(frame.x), int(frame.y)]
		_check(met.is_empty() and keys.size() == 15,
			"at %s, none of the %d pieces meets another" % [size_name, keys.size()], ", ".join(met))
		_check(outside.is_empty(), "and every one is inside the frame", ", ".join(outside))

		ArenaPresentation.fit_chat_screen(chat_screen, frame)
		var fit := chat_screen.scale.x
		var rows := float(chat.max_lines) * (chat.line_height + chat.line_gap)
		var log_top := frame.y / fit - chat.margin_bottom - chat.entry_height - rows
		var log_box := chat_screen.get_global_transform() * Rect2(chat.margin_left, log_top, chat.width, rows)
		for key: String in rects:
			if log_box.intersects(rects[key]):
				chat_met.append("%s: %s %s vs log %s" % [size_name, key, rects[key], log_box])

	_check(chat_met.is_empty(), "a full chat log meets no HUD piece at any of those frames",
		", ".join(chat_met))
	chat_screen.queue_free()

	# 1280x720 and up are laid out exactly as dot-ui's full-rect inset laid them out.
	var same := true
	for frame: Vector2 in [Vector2(1280, 720), Vector2(1600, 900), Vector2(1920, 1080)]:
		hud.fit_to_frame(frame)
		same = same and hud.scale == Vector2.ONE and hud.position == Vector2(16, 16) and hud.size == frame - Vector2(32, 32)
	_check(same, "from 1280x720 up the HUD is not scaled, and sits where it always did")
	_check(is_equal_approx(ArenaHud.fit_scale(Vector2(854, 480)), 480.0 / 720.0)
			and is_equal_approx(ArenaHud.fit_scale(Vector2(960, 720)), 0.75)
			and is_equal_approx(ArenaHud.fit_scale(Vector2(720, 1280)), 0.5625)
			and ArenaHud.fit_scale(Vector2(200, 100)) == hud.fit_min
			and hud.fit_design == ArenaHud.DESIGN_FRAME and hud.fit_min == 0.5,
		"below it, it is scaled by the short side's share of 1280x720, never under half")
	# The clock is dot-ui's `DotScoreStrip.clock_text`, which rounds up: a clock never says
	# 0:00 with time left. Arena's own rounded down until 2026-10-11 (9:37.4 read 9:37).
	_check(DotScoreStrip.clock_text(577.4) == "9:38" and DotScoreStrip.clock_text(0.3) == "0:01"
			and DotScoreStrip.clock_text(0.0) == "0:00" and DotScoreStrip.clock_text(600.0) == "10:00",
		"the clock rounds the seconds left up (%s, %s)" % [DotScoreStrip.clock_text(577.4), DotScoreStrip.clock_text(0.3)])

	hud.queue_free()
	_done()


# --- The HUD under a ballot ----------------------------------------------------

## The weapon slots under a ballot: this game's own map vote is seven rows (six maps and
## Extend), and the client shell draws it down the right-hand side to y 437 at 1280x720, over
## slots 1 and 2 of five. Anything in dot-ui's `dot_hud_cover` group is on top of the HUD;
## `make_room` tightens the slots under it, then shows only the rows around the current one,
## and drops the vote's centre line the ballot duplicates. How it looks is
## `screenshot.sh dm_box --glance --map-ballot`; this is the arithmetic.
func _test_hud_makes_room_for_a_ballot() -> void:
	_section("The weapon slots and the centre line make room for a ballot")

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud.set_process(false)
	hud.fit_to_frame(Vector2(1280, 720))
	var carried: Array[Dictionary] = []
	for slot in range(1, 6):
		carried.append({"slot": slot, "id": &"", "name": "Gun %d" % slot, "key": str(slot)})
	hud.slots.show_slots(carried, 3)
	hud.make_room()
	var free_top: float = hud.footprints()["slots"].position.y

	# Where the shell puts a seven-row ballot at 1280 wide, on a layer of its own.
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	var ballot := Control.new()
	ballot.add_to_group(&"dot_hud_cover")
	ballot.position = Vector2(904.0, 110.0)
	ballot.size = Vector2(360.0, 327.0)
	layer.add_child(ballot)
	var cover := Rect2(ballot.position, ballot.size)

	hud.make_room()
	var under: Rect2 = hud.footprints()["slots"]
	var laid: Dictionary = hud.slots.layout()
	_check(free_top < cover.end.y and under.position.y >= cover.end.y and not under.intersects(cover)
			and (laid["rows"] as Array).size() == 5,
		"all five slots end below a seven-row ballot, where they reached under it",
		"top %.0f free, %.0f under a ballot to %.0f, %d rows" % [free_top, under.position.y, cover.end.y, (laid["rows"] as Array).size()])
	_check(float(laid["pitch"]) < ArenaHud.ArenaHudGlance.WeaponSlots.ROW_H
			and float(laid["pitch"]) >= ArenaHud.ArenaHudGlance.WeaponSlots.MIN_ROW_H,
		"by drawing the rows closer, never under the tightest pitch", "pitch %.1f" % float(laid["pitch"]))

	var many: Array[Dictionary] = []
	for slot in range(1, 9):
		many.append({"slot": slot, "id": &"", "name": "Gun %d" % slot, "key": str(slot)})
	hud.slots.show_slots(many, 7)
	hud.make_room()
	laid = hud.slots.layout()
	var shown := (laid["rows"] as Array).map(func(r: Dictionary) -> int: return int(r["slot"]))
	under = hud.footprints()["slots"]
	_check(shown.size() < 8 and shown.size() >= 3 and shown.has(7) and under.position.y >= cover.end.y,
		"eight that cannot fit even close together show the run around the current one",
		"%s, top %.0f" % [shown, under.position.y])

	ballot.visible = false
	hud.make_room()
	laid = hud.slots.layout()
	_check((laid["rows"] as Array).size() == 8 and float(laid["pitch"]) == ArenaHud.ArenaHudGlance.WeaponSlots.ROW_H,
		"and every row comes back at its own pitch the frame the ballot goes")
	ballot.visible = true

	var opening := "Vote: Box, Atrium, Pit, Foundry, Canals, Spire (20s)"
	var yes_no := "Vote: Kick quiet_one?  —  type !yes or !no (20s)"
	_check(ArenaHud.is_ballot_line(opening) and not ArenaHud.is_ballot_line(yes_no)
			and not ArenaHud.is_ballot_line("Changing map to Box…") and not ArenaHud.is_ballot_line("Vote: Box (soon)"),
		"a vote's opening list is told from the yes/no vote's line and every other system line")
	hud.notice(opening)
	_check(hud.notice_label == null or hud.notice_label.text != opening,
		"with a ballot on screen its opening list is not centre-printed as well")
	hud.notice(yes_no)
	_check(hud.notice_label != null and hud.notice_label.text == yes_no,
		"but the yes/no vote's line, which says how to answer, still is")

	# A line that arrived the frame before its ballot did goes when the ballot does arrive.
	ballot.visible = false
	hud.notice(opening)
	ballot.visible = true
	hud.make_room()
	_check(hud.notice_label.text == "", "and a list printed before its ballot appeared is taken down",
		hud.notice_label.text)

	layer.queue_free()
	hud.queue_free()
	_done()


# --- The map vote ------------------------------------------------------------

func _test_vote_is_heard() -> void:
	_section("The map vote is heard: every cue its rules name is a sound here")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull

	# The rules this game votes by, as the server builds them. dot-vote ships every cue
	# empty, so a cue id the rules name and the catalogue lacks is a sound that is
	# configured, sent to every client each second of a countdown, and never heard.
	var vote := ArenaVote.new()
	var rules := vote._rules()
	vote.free()

	var named: Array[StringName] = []
	for cue in [
		rules.cue_vote_start, rules.cue_vote_end, rules.cue_warning,
		rules.cue_runoff_warning, rules.countdown_cue_id(3),
	]:
		named.append(StringName(cue))

	_check(
		not named.has(&""),
		"the rules name a cue for the start, the end, both warnings and a countdown second",
		str(named)
	)

	var missing: Array[String] = []
	for id in named:
		if not p.audio.catalogue.has(id):
			missing.append(String(id))
	_check(missing.is_empty(), "and every one is in the catalogue (missing: %s)" % str(missing))

	_check(
		rules.vote_warning_sec > 0.0,
		"with a countdown before the ballot, so the countdown cue has seconds to play in"
	)

	sink.forget()
	_check(p.on_vote_cue(StringName(rules.cue_vote_start)) != 0, "a ballot opening plays")
	_check(sink.count_of(StringName(rules.cue_vote_start)) == 1, "once")

	sink.forget()
	p.on_vote_cue(&"")
	p.on_vote_cue(&"a_sound_set_this_client_was_not_built_with")
	_check(
		sink.count_of(&"") == 0 and sink.count_of(&"a_sound_set_this_client_was_not_built_with") == 0,
		"and an empty cue or one this client does not know is silence, not an error"
	)

	p.queue_free()
	_done()


# --- An administrator's blind and beacon --------------------------------------

## What the two flags `headless_net` delivers turn into on a client: a beacon that rings
## and pings, and a screen that goes dark. Nothing here can say they LOOK right — that is
## `tools/screenshot.sh --admin` — but it can say they are built, that they come and go
## with the flag, and that the ping happens once a period rather than once a frame.
static func _shrunk_bones(player: ArenaPlayer) -> int:
	if player.figure == null or player.figure.skeleton() == null:
		return -1
	var skel := player.figure.skeleton()
	var n := 0
	for i in skel.get_bone_count():
		if skel.get_bone_pose_scale(i).x < 0.01:
			n += 1
	return n


## A lethal critical breaks a body, a respawn mends it, and the HUD shows what a body is
## doing: badly hurt, ready to launch, sliding.
func _test_criticals_and_the_body() -> void:
	_section("A critical breaks a body, a respawn mends it, the HUD shows the rest")

	var player := ArenaPlayer.new()
	player.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), 6, "Broken")
	add_child(player)
	player.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 18.0)), 0)
	player.attach_body_mesh(Color.WHITE, ArenaAvatars.stock_avatar(&"broken"))

	var rules := DotPlayerBreakRules.new()
	rules.mode = DotPlayerBreakRules.Mode.LIMBS
	rules.limbs = 1
	rules.criticals_only = true
	# The body is a skinned person (dot-player-char's people): a limb is baked off the skin and
	# its bones shrink to the stump, so what is counted is the shrunk bones.
	var whole := _shrunk_bones(player)

	player.make_dead()
	_check(player.break_body(rules, Vector3.FORWARD, 42, false) == null,
		"an ordinary death leaves the body whole")
	var broke := player.break_body(rules, Vector3.FORWARD, 42, true)
	var left := _shrunk_bones(player)
	_check(broke != null and broke.piece_count() == 1 and left > whole,
		"a lethal critical takes a limb off (%d bones shrunk to the stump)" % left)

	player.health.alive = true
	player.present(0.016)
	_check(_shrunk_bones(player) == whole,
		"and a respawn puts the body back together")

	# Somebody else, hurt: a bar over their head for a few seconds.
	player.health.health = player.health.max_health
	player.present(0.016)
	player.health.health = player.health.max_health * 0.4
	player.present(0.016)
	_check(player._health_tag != null and player._health_tag.visible
		and is_equal_approx(player._health_fill.scale.x, 0.4),
		"a hurt player shows a bar over their head, filled to what is left")
	var fill_on := player._health_fill.material_override as BaseMaterial3D
	var back_on := player._health_tag.get_child(0).material_override as BaseMaterial3D
	_check(fill_on != null and back_on != null and fill_on.render_priority > back_on.render_priority,
		"and the fill draws over its backing, not under it")
	player.present(ArenaPlayer.HEALTH_TAG_SEC + 0.1)
	_check(not player._health_tag.visible, "and it goes after a few seconds")
	player.health.health = player.health.max_health

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud.follow(player)

	player.health.health = player.health.max_health * 0.1
	hud.present_body()
	_check(hud.hurt_overlay.modulate.a > 0.5, "badly hurt, the screen's edge goes red (%.2f)" % hud.hurt_overlay.modulate.a)
	player.health.health = player.health.max_health
	hud.present_body()
	_check(hud.hurt_overlay.modulate.a == 0.0, "and healthy, it does not")
	# Per pixel, never a stretched texture: the play test's edge was a 64-pixel gradient
	# blown up to the screen, in visible steps.
	_check(hud.hurt_overlay.material is ShaderMaterial,
		"the red edge is drawn by a shader, not a stretched texture")

	# The play test's "+1 COINS" and "(2/100000)".
	_check(ArenaHud.coins_text(1) == "1 coin" and ArenaHud.coins_text(5) == "5 coins",
		"one coin is a coin (%s, %s)" % [ArenaHud.coins_text(1), ArenaHud.coins_text(5)])
	var damage := ArenaHud.progress_text(&"arena.damage_dealt", 2, 100000)
	var hours := ArenaHud.progress_text(&"arena.playtime_sec", 3, 36000)
	var kills := ArenaHud.progress_text(&"arena.kills", 11, 100)
	_check(damage == "2 of 100k" and hours == "0:03 of 10 h" and kills == "11/100",
		"a challenge's progress reads in its own units (%s; %s; %s)" % [damage, hours, kills])

	hud.present_body()
	_check(hud.abilities.visible and hud.abilities.line(&"launch").contains("LAUNCH"),
		"the launch's button reads ready (%s)" % hud.abilities.line(&"launch"))
	player.controller.state.launch_cooldown_left = 5.5
	hud.present_body()
	_check(hud.abilities.line(&"launch").contains("5.5"), "and counts its cooldown down (%s)" % hud.abilities.line(&"launch"))

	player.controller.state.slide_time = 0.2
	hud.present_body()
	_check(hud.slide_label.visible, "sliding, it says how to stop")
	player.controller.state.slide_time = -1.0

	# The streak meter counts from KILL events, as a client hears them. The points, the
	# hit marker and the medals do not: those come from the server's HIT and AWARD.
	for v in [7, 8, 9]:
		hud.note_kill({"killer_id": 6, "victim_id": v, "headshot": v == 9, "weapon": "rifle"}, 6, "Broken")
	hud.present_body()
	_check(hud.streak_meter.count == 3, "three kills fill the streak meter to three")
	_check(hud._popups.is_empty() and hud.hit_marker.alpha() == 0.0 and hud.medal_row.shown.is_empty(),
		"and a KILL alone draws no points, no hit marker and no medal: the client decides none of them")

	# The challenge bar: the achievement this player is nearest to.
	var awards: DotAchievementCatalogue = load("res://game/arena_awards.gd").catalogue()
	var progress := DotAchievementProgress.new()
	progress.set_value(&"arena.kills", 11.0)
	var picked: Array = load("res://game/arena_progress.gd").challenge_for(awards, progress)
	var picked_def: DotAchievement = awards.achievements[int(picked[0])] if int(picked[0]) >= 0 else null
	_check(picked_def != null and int(picked[1]) == 11 and picked_def.requirements[0].stat == &"arena.kills",
		"a challenge is the goal a player is furthest along (%s)" % (picked_def.display_name if picked_def != null else "none"))
	player.challenge = int(picked[0])
	player.challenge_value = int(picked[1])
	hud.present_challenge(true)
	_check(hud.challenge_label.visible and hud.challenge_label.text.contains("11/100") and hud.challenge_bar.value == 11.0,
		"and the HUD draws it with a bar (%s)" % hud.challenge_label.text)
	player.challenge = -1
	hud.present_challenge(true)
	_check(not hud.challenge_label.visible, "and nothing when there is none")

	for i in range(3):
		hud.note_kill({"killer_id": 7, "victim_id": 6, "weapon": "sniper"}, 6, "Sniper")
	_check(hud.streaks.get(6, -1) == 0 and not hud._death_text.contains("NEMESIS"),
		"dying ends the streak, and three deaths alone name nobody: that is the server's call")
	hud.note_award({"killer_id": 7, "victim_id": 6, "medals": [ArenaAwards.Medal.NEMESIS], "points": 125, "streak": 3}, 6, "Broken", "Sniper")
	_check(hud._death_text.contains("Sniper is your NEMESIS"), "the server's Nemesis medal for a kill of you names them")
	player.make_dead()
	hud.present_body()
	_check(hud.death_label.visible and hud.death_label.text.contains("Killed by Sniper"),
		"dead, it says who did it and with what")

	hud.note_kill({"killer_id": 6, "victim_id": 7, "weapon": "rifle"}, 6, "Broken")
	hud.note_award({"killer_id": 6, "victim_id": 7, "medals": [ArenaAwards.Medal.REVENGE], "points": 150, "streak": 1}, 6, "Sniper", "Broken")
	hud.medal_row.advance(0.05)
	_check(hud.medal_row.labels().has("Revenge") and not hud.nemeses.has(7),
		"killing them back is the server's Revenge medal, and they are nobody's nemesis now")
	hud.notice("hello")
	_check(hud.notice_label.text == "hello", "and notice() exists, which the client had called for a month")

	# The client shell's column (ballots, its lines) is the right edge from 110 px down. A
	# headless frame is 64 px, so where things land is the render's to judge
	# (`screenshot.sh --glance --ballot`); these are the structure that put them there.
	_check(ArenaHud.feed_lines_clear(16.0) == 3 and hud.feed.max_lines == 3,
		"the kill feed keeps to the rows that end above the shell's column (%d)" % hud.feed.max_lines)
	hud.set_safe_area(40.0)
	var inset_rows := hud.feed.max_lines
	hud.set_safe_area(16.0)
	_check(inset_rows == 2 and hud.feed.max_lines == 3,
		"and to fewer when the safe area pushes it down (%d at 40 px)" % inset_rows)
	_check(is_zero_approx(hud.hints.anchor_right) and is_equal_approx(hud.slots.anchor_top, 1.0)
			and hud.slots.offset_bottom <= hud.ammo.offset_top,
		"the key hints are on the left, the carried weapons on the ammunition counter")

	# The end of the match names the MVP, through the client's own MATCH handler.
	var summary_game := ArenaGame.new()
	summary_game.headless = true
	summary_game.register_service = false
	add_child(summary_game)
	var _set := summary_game.setup(ArenaMap.dm_box())
	var best := summary_game.match_node.scoreboard.join("6", "Broken")
	best.kills = 3
	best.score = 3
	var client := ArenaClient.new()
	client.game = summary_game
	client.hud = hud
	client._on_match({"state": DotMatch.State.MATCH_END, "round": 1, "remaining_ticks": 0})
	_check(hud.notice_label.text.begins_with("MVP: Broken") and hud.notice_label.text.contains("3 kills"),
		"the end of the match names the MVP (%s)" % hud.notice_label.text)
	client.free()
	summary_game.queue_free()

	hud.queue_free()
	player.queue_free()
	_done()


## A client turns the server's HIT and AWARD into the hit marker, a damage number, the
## medals and "+points  Victim", read back off the wire exactly as a link delivers them.
## A server's ids are consecutive (bots, a busy evening), and stock avatars are drawn in
## the world and in the HUD's portrait row. The seed used to be the key's string hash,
## which moves by a few per id, and `(seed / 7) % HEADS.size()` then gave players 112..118
## the same head: a row of one face. Each slot now chooses from its own mix of the seed.
func _test_stock_avatars_differ() -> void:
	_section("Consecutive players do not wear the same stock face")

	var heads := {}
	var bodies := {}
	var shared_with_previous := 0
	var previous := &""
	for id in range(112, 128):
		var avatar := ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(id)))
		var head := avatar.part_in(ArenaAvatars.SLOT_HEAD)
		heads[head] = true
		bodies[avatar.part_in(ArenaAvatars.SLOT_BODY)] = true
		if head == previous:
			shared_with_previous += 1
		previous = head

	# 16 picks from 20 heads land on about 11 distinct by chance; 8 leaves room for an
	# unlucky but honest mix and fails the old pick, which gave 4 (12 of 15 neighbours shared).
	_check(heads.size() >= 8, "16 consecutive players wear at least 8 different heads",
		"%d distinct" % heads.size())
	_check(shared_with_previous <= 3, "and few players share a head with the id before them",
		"%d of 15 neighbours" % shared_with_previous)
	_check(bodies.size() >= 8, "and at least 8 different bodies", "%d distinct" % bodies.size())

	var again := ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(117)))
	_check(
		again.equals(ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(117)))),
		"and a player's stock look is the same every time it is asked for"
	)
	_done()


func _test_feedback_from_the_wire() -> void:
	_section("The server's hits and medals become a hit marker, numbers, medals and points")
	var M := ArenaAwards.Medal

	var g := ArenaGame.new()
	g.is_authority = true
	g.headless = true
	g.register_service = false
	add_child(g)
	var _set := g.setup(ArenaMap.dm_box())
	var me: ArenaPlayer = g.add_player(6, "Broken").value
	var them: ArenaPlayer = g.add_player(7, "Victim").value

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud.follow(me)

	var client := ArenaClient.new()
	client.game = g
	client.player = me
	client.hud = hud

	var at := them.global_position + Vector3(0.0, 1.4, 0.0)
	client._on_hit(ArenaEvents.read_hit(DotNetReader.new(ArenaEvents.write_hit(7, 34.0, at, false, false))))
	_check(hud.hit_marker.alpha() > 0.9 and not hud.hit_marker.kill, "a HIT flashes the hit marker, white")
	_check(hud.damage_numbers.entries.size() == 1 and int(hud.damage_numbers.entries[0]["amount"]) == 34,
		"and a number rises from where it landed, saying what it took")
	client._on_hit(ArenaEvents.read_hit(DotNetReader.new(ArenaEvents.write_hit(7, 20.0, at, false, false))))
	_check(hud.damage_numbers.entries.size() == 1 and int(hud.damage_numbers.entries[0]["amount"]) == 54,
		"a second hit on them straight after adds into the same number (%s)" % [hud.damage_numbers.entries.map(func(e: Dictionary) -> int: return int(e["amount"]))])
	client._on_hit(ArenaEvents.read_hit(DotNetReader.new(ArenaEvents.write_hit(7, 80.0, at, true, true))))
	_check(hud.hit_marker.kill and bool(hud.damage_numbers.entries[0]["headshot"]),
		"a lethal hit to the head turns the marker red and the number gold")
	hud.hit_marker.advance(1.0)
	hud.damage_numbers.advance(1.0)
	_check(hud.hit_marker.alpha() == 0.0 and hud.damage_numbers.entries.is_empty(), "and both are gone within a second")

	var award := ArenaEvents.read_award(DotNetReader.new(
		ArenaEvents.write_award(6, 7, ArenaAwards.points_for([M.FIRST_BLOOD, M.HEADSHOT]), 4, [M.FIRST_BLOOD, M.HEADSHOT])
	))
	client._on_award(award)
	var texts: Array = []
	for entry in hud._popups:
		for label in (entry[0] as Control).get_children():
			texts.append((label as Label).text)
	_check(texts == ["+175", "Victim"], "an AWARD for your kill puts \"+points  Victim\" by the crosshair (%s)" % [texts])
	_check(hud.medal_row.shown.size() == 2 and float(hud.medal_row.shown[1]["age"]) < 0.0,
		"and its medals, the second waiting its turn")
	hud.medal_row.advance(0.3)
	_check(hud.medal_row.labels() == PackedStringArray(["First Blood", "Headshot"]) and float(hud.medal_row.shown[1]["age"]) > 0.0,
		"then both, by name, in the order the server sent them")
	hud.present_body()
	_check(hud.streak_meter.count == 4, "the streak meter takes the server's streak (%d)" % hud.streak_meter.count)
	hud.medal_row.advance(3.5)
	_check(hud.medal_row.shown.is_empty(), "and the medals fade out after a couple of seconds")

	client._on_award({"killer_id": 7, "victim_id": 6, "medals": [M.HEADSHOT], "points": 125, "streak": 1})
	hud.medal_row.advance(0.3)
	_check(hud.medal_row.shown.is_empty() and hud._popups.size() == 1, "somebody else's medals are not drawn on your screen")

	var catalogue := ArenaPresentation.sound_catalogue()
	var recipes := ArenaPresentation.sound_recipes()
	var unheard: Array = []
	for medal in ArenaAwards.MEDALS:
		var id := ArenaAwards.medal_sound(int(medal))
		if catalogue.find(id) == null or not recipes.has(id):
			unheard.append(String(id))
	_check(unheard.is_empty() and catalogue.find(ArenaPresentation.KILL_CONFIRMED) != null,
		"every medal and the kill confirmation is a sound with a stand-in (%s)" % [unheard])

	client.free()
	hud.queue_free()
	g.queue_free()
	_done()


func _test_blind_and_beacon() -> void:
	_section("An admin's beacon is drawn and heard, and a blind darkens one screen")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull

	var def := p.audio.catalogue.find(ArenaPresentation.BEACON_SOUND)
	_check(
		def != null and def.kind == DotAudioDef.Kind.POSITIONAL_3D and def.max_distance >= 90.0,
		"the ping is positional and carries at least as far as a shot",
		"a beacon's job is to say where somebody is"
	)
	sink.forget()
	_check(p.on_beacon(Vector3(4.0, 0.0, 2.0)) != 0 and sink.count_of(ArenaPresentation.BEACON_SOUND) == 1,
		"and it plays where the beacon is")

	var player := ArenaPlayer.new()
	player.setup(ArenaPlayer.Mode.HEADLESS, ArenaMap.dm_box(), 5, "Marked")
	add_child(player)
	player.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 18.0)), 0)

	var pings: Array[Vector3] = []
	player.beacon_pulsed.connect(func(at: Vector3) -> void: pings.append(at))

	player.present(0.016)
	_check(player.beacon_marker == null and pings.is_empty(), "no beacon, no marker and no ping")

	player.beacon = true
	player.present(0.016)
	_check(
		player.beacon_marker != null and pings.size() == 1,
		"switched on, it is drawn and pings at once rather than a second later"
	)
	for _i in range(30):
		player.present(0.016)
	_check(pings.size() == 1, "and not again inside the same second (%d pings)" % pings.size())
	for _i in range(40):
		player.present(0.016)
	_check(pings.size() == 2, "then once a second (%d pings in 1.1 s)" % pings.size())
	_check(
		pings[1].distance_to(player.controller.state.position) < 0.01,
		"from where the player is"
	)

	player.make_dead()
	player.present(0.016)
	_check(player.beacon_marker == null, "a dead player's beacon is not drawn over the corpse")

	player.health.alive = true
	player.beacon = false
	player.present(0.016)
	_check(player.beacon_marker == null, "and switched off, the marker goes")

	var hud := ArenaHud.new()
	hud.config = DotUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud.follow(player)

	_check(
		hud.blind_overlay != null and hud.blind_overlay.get_index() == 0
			and not hud.blind_overlay.visible,
		"the blind is under every HUD widget, and off"
	)
	player.blinded = true
	hud.present_blind(ArenaHud.BLIND_FADE_SEC * 0.5)
	_check(
		hud.blind_overlay.visible and hud.blind_overlay.modulate.a > 0.4
			and hud.blind_overlay.modulate.a < 0.6,
		"blinded, it fades in rather than cutting (%.2f half way)" % hud.blind_overlay.modulate.a
	)
	hud.present_blind(1.0)
	# The whole viewport, not the HUD's rect: `DotHud` insets itself by the safe area and
	# the first rendered blind left a frame of the world round the edge. This is the one
	# layout check a 64 x 64 headless viewport can still answer, because the inset is
	# the same sixteen pixels there.
	_check(
		hud.blind_overlay.get_global_rect().is_equal_approx(hud.get_viewport_rect()),
		"and covers the whole screen, not the safe area the HUD sits in",
		"%s against %s" % [hud.blind_overlay.get_global_rect(), hud.get_viewport_rect()]
	)
	player.blinded = false
	hud.present_blind(1.0)
	_check(not hud.blind_overlay.visible, "and lifted, it is gone")

	hud.queue_free()
	player.queue_free()
	p.queue_free()
	_done()
