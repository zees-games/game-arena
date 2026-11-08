extends "headless_presentation_b3.gd"

const ArenaFlashlight := preload("../game/arena_flashlight.gd")


func _ready() -> void:
	# Before anything builds a presentation layer: every settings document this suite writes
	# goes to a scratch directory emptied first, never this machine's real one.
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
	_test_ambience_is_quiet_and_obeys_settings()
	_test_effects_and_the_player_who_asked_for_none()
	await _test_a_shot_is_drawn()
	_test_shake_is_computed_not_applied()
	await _test_blood()
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
	await _test_the_kill_view()
	_test_the_view_turns_every_frame()
	_test_own_body()
	_test_criticals_and_the_body()
	await _test_bodies_fall()
	_test_feedback_from_the_wire()
	_test_stock_avatars_differ()
	await _test_hud_fits_the_frame()
	_test_hud_makes_room_for_a_ballot()
	await _test_the_map_menu()
	await _test_the_loadout_menu()
	_test_click_keeps_modal_pointer()
	await _test_the_hud_follows_the_theme()

	print("")
	_check(
		_player_file_stamp() == _player_file_was,
		"the player's own settings file was not touched",
		ArenaPresentation.PLAYER_SETTINGS
	)
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


## Every key `ArenaClient` reads is a row in `ArenaBindings`; the action names are written out here
## so a missing row fails the check rather than shrinking the table.
func _test_every_key_is_an_action() -> void:
	_section("Every key the client reads is an action in the table, rebound live and kept")

	var p := _make(false)
	var expected := {
		&"arena_fire": "Mouse 1", &"arena_aim": "Mouse 2", &"arena_bash": "X", &"arena_flashlight": "F",
		&"arena_reload": "R", &"arena_slot_1": "1", &"arena_slot_2": "2", &"arena_slot_3": "3",
		&"arena_slot_4": "4", &"arena_slot_5": "5", &"arena_weapon_previous": "Wheel up",
		&"arena_weapon_next": "Wheel down", &"arena_weapon_last": "Z", &"arena_launch": "E",
		&"arena_launch_props": "P", &"arena_punt": "G", &"dot_voice_talk": "V",
		&"dot_fps_walk": "Alt", &"arena_fire_mode": "N",
	}
	var wrong: Array[String] = []
	for action: StringName in expected:
		if p.bindings.row_for_action(action).is_empty() \
				or DotInputBinding.describe_action(action) != str(expected[action]):
			wrong.append("%s=%s" % [action, DotInputBinding.describe_action(action)])
	_check(wrong.is_empty(), "each is a row and on its default key in the InputMap", str(wrong))

	var two := DotWeaponDef.new()
	two.display_name = "Rifle"
	two.fire_modes = DotWeaponDef.selector_modes(DotWeaponDef.Fire.AUTO, true)
	var one := DotWeaponDef.new()
	one.display_name = "Pistol"
	var two_slot := DotWeaponSlot.new()
	two_slot.def = two
	var one_slot := DotWeaponSlot.new()
	one_slot.def = one
	_check(
		ArenaHud.mode_label(two_slot, "N") == "Rifle  AUTO [N]" and ArenaHud.mode_label(one_slot, "N") == "Pistol",
		"the ammo line names the fire mode and its key on a gun with a selector, and only then",
		"%s / %s" % [ArenaHud.mode_label(two_slot, "N"), ArenaHud.mode_label(one_slot, "N")]
	)

	# The wheel rows by name: a pack asks for dot-ui 4, which names the wheel (level 2).
	var named := ArenaBindings.make().row_for_action(&"arena_weapon_previous")
	_check(
		str(named["label"]) == "Previous weapon" and str(named["default"]) == "Wheel up",
		"the wheel rows say Wheel up / Wheel down", str(named)
	)

	# A branch only matters if an older shell gets to run it.
	var floors := DotAddonApi.parse(FileAccess.get_file_as_string("res://" + DotAddonApi.FLOOR_FILE), DotAddonApi.FLOOR_FILE)
	var derived := DotAddonApi.derive()
	var unsound := DotAddonApi.floor_audit(floors.value if floors.ok else {}, derived, DotAddonApi.guarded()) \
		if floors.ok else PackedStringArray([str(floors.error)])
	_check(unsound.is_empty(), "requires.floor.json is sound: every floor has a guard behind it", str(unsound))
	var asked := DotAddonApi.apply_floors(derived, floors.value if floors.ok else {})
	_check(
		asked.get("dot_ui") == 17 and asked.get("dot_lighting") == derived.get("dot_lighting") \
			and int(asked.get("dot_lighting", 0)) >= 3,
		"so a pack asks a shell for dot-ui 17 (the vitals streak row) and the dot-lighting it was built on (3+, painted())", str(asked)
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

	# F is the flashlight and X the melee, through the same polling path.
	client._unhandled_input(_key_event("F", true))
	client._read_fire(DotFpsCommand.new())
	var f_lights := client._fire.is_pressed(ArenaFlashlight.BUTTON)
	client._flash_ticks = 0
	_press(DotInputBinding.from_text("X"), true)
	client._read_fire(DotFpsCommand.new())
	var x_bashes := client._fire.is_pressed(DotWeaponCommand.BUTTON_ALT)
	_press(DotInputBinding.from_text("X"), false)
	_check(f_lights and x_bashes, "F sends the flashlight button and X the melee",
		"F %s, X %s" % [f_lights, x_bashes])

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
	client._unhandled_input(_key_event("X", true))
	var f_freezes := client.last_prop_asked == ArenaEvents.PropAct.FREEZE
	client._unhandled_input(_key_event("G", true))
	var g_punts := client.last_prop_asked == ArenaEvents.PropAct.PUNT
	_check(e_grabs and f_freezes and g_punts and client.launch_action() == &"arena_launch_props",
		"in Siege E grabs, X freezes, G punts and the launch is P's",
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
	_test_every_key_rest(p, client, stand_in, g)


func _test_every_key_rest(p: ArenaPresentation, client: ArenaClient, stand_in: ArenaPlayer, g: ArenaGame) -> void:
	g.free()

	# Kept: what was rebound is in the document, and a new presentation reading it puts it back on
	# the InputMap. The InputMap is put on the default first, so only the load can have moved it.
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


func _test_party_is_sandboxed() -> void:
	_section("A private match files nothing anywhere")

	DotP2PSignallerLoopback.reset_all()

	var party := ArenaParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	# The decision this game makes and the lobby does not: arena reports to dot-stats, unlocks dot-
	# achievements and files to dot-leaderboard.
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


## `[p2p-await-games]`: a private match over the HTTP rendezvous, host and join, each awaited end to
## end — through `ArenaParty`, `DotP2PSession` and `DotP2PSignallerHttp` to a socket and back.
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
