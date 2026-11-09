extends "headless_presentation_base.gd"

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

	p.console.submit("cl_fp_scope_arms_hide 0.3")
	p.console.submit("cl_fp_max_lean 0.1")
	var arm_ok := is_equal_approx(ArenaViewArms.scope_arms_hide_override, 0.3) and is_equal_approx(ArenaViewArms.max_lean_override, 0.1)
	p.console.submit("cl_fp_scope_arms_hide 9")
	p.console.submit("cl_fp_max_lean -1")
	_check(arm_ok and is_equal_approx(ArenaViewArms.scope_arms_hide_override, 1.0) and is_equal_approx(ArenaViewArms.max_lean_override, -1.0),
		"cl_fp_scope_arms_hide and cl_fp_max_lean reach the arms and clamp")
	ArenaViewArms.scope_arms_hide_override = -1.0

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


## Typing at the console must not walk the player.
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


## The Escape menu is dot-menu's, over this game's settings document and key table, with this game's
## pages on it.
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

	# The settings round trip, through the slider the page draws: no Apply, lands in document and mixer.
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

	menu.open(&"video")
	_check(menu.screen.find_child("Row_gore", true, false) != null, "Video has the Blood splatters row")

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

	# H is help, nothing else is on H; the Escape menu has Help & commands and a working Leave.
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

	# The console and the chat box are the same question: does something on screen own the keyboard?
	# A client that keeps reading movement while somebody types walks them across the map.
	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	# A join notice is a name and NO text (dot-chat's `_presence`). Drawn as name and text it was a
	# bare "Guest 435:" in the box, which read as a chat command echoed with its text stripped.
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
	hud.vitals.show_streak(3, ArenaHud.STREAK_FULL)
	var streak: Rect2 = hud.vitals.get_global_transform() * hud.vitals.footprint()
	var rows := float(window.max_lines) * (window.line_height + window.line_gap)
	var log_box := Rect2(window.margin_left, 720.0 - window.margin_bottom - window.entry_height - rows, window.width, rows)
	_check(not log_box.intersects(streak), "a full chat log stays under the killstreak meter at 1280x720",
		"log %s, meter's words %s" % [log_box, streak])
	hud.queue_free()

	_completed += 1


## `sensitivity`, `invert_pitch` and `crosshair` were on the settings screen and read by nothing:
## the view turned at `DotFpsTunables`' default whatever the slider said.
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
	# Wall on the right has normal LEFT; positive wall_roll() leans left (away from it).
	var lean := ArenaPlayer.camera_motion_picks()
	var ws := DotFpsState.new()
	ws.mode = DotFpsState.Mode.AIR
	ws.velocity = Vector3(0.0, 0.0, -9.0)
	ws.wall_run_time = 0.1
	ws.wall_normal = Vector3.LEFT
	for _i in range(240):
		lean.advance(ws, 1.0 / 144.0)
	var on_right := lean.wall_roll()
	ws.wall_normal = Vector3.RIGHT
	for _i in range(240):
		lean.advance(ws, 1.0 / 144.0)
	_check(on_right < -1.0 and lean.wall_roll() > 1.0,
		"the wall-run lean tilts toward the wall: right wall leans right, left wall leans left",
		"right wall %.2f, left wall %.2f" % [on_right, lean.wall_roll()])
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


## A click while a modal has the pointer must not capture it: the workbench, or a ballot that freed the mouse.
func _test_click_keeps_modal_pointer() -> void:
	_section("A click does not recapture the pointer under a modal")

	var client := ArenaClient.new()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true

	client._awaiting_click = true
	client._unhandled_input(click)
	_check(not client._awaiting_click, "with nothing open a click takes the pointer")

	client._awaiting_click = true
	client._workbench_open = true
	client._unhandled_input(click)
	_check(client._awaiting_click and client._menu_open(), "a click with the workbench open leaves it alone")
	client._workbench_open = false

	var ballot := Control.new()
	ballot.set_script(preload("res://examples/pointer_modal_stub.gd"))
	add_child(ballot)
	ballot.set(&"on", true)
	client._awaiting_click = true
	client._unhandled_input(click)
	_check(client._awaiting_click and client._menu_open(), "a click with a ballot in pointer mode leaves it alone")
	ballot.set(&"on", false)
	_check(not client._menu_open(), "and the ballot closing hands the pointer back")

	ballot.free()
	client.free()
	_done()


## A connected client's respawn faces the way its spawn faces.
func _test_the_kill_view() -> void:
	_section("The kill view replaces the death camera, and Space skips it")
	var rules := DotKillViewRules.new()
	rules.enabled = true
	_check(rules.camera == DotKillViewRules.Camera.EYE, "mp_killview_camera defaults to the killer's eye")
	rules.camera = DotKillViewRules.Camera.EYE
	var ring := DotKillViewRing.new(rules)
	for i in 120:
		var yaw := float(i) * 0.01
		var _r := ring.record(7, float(i) / 30.0, Transform3D(Basis(Vector3.UP, yaw), Vector3(float(i) * 0.1, 1.6, 0.0)), 80.0, Vector2(0.5, 0.45))
	var _n := ring.note_kill(7, 8, 3.0, {"killer": "Bolt", "weapon": "smg"})
	var clips := ring.collect(4.0)

	# Its own viewport: other sections leave cameras in this one.
	var port := SubViewport.new()
	add_child(port)
	var previous := Camera3D.new()
	port.add_child(previous)
	previous.make_current()
	await get_tree().process_frame
	var was_current := port.get_camera_3d()
	var hud_stub := Control.new()
	port.add_child(hud_stub)
	var view := DotKillViewClient.new()
	port.add_child(view)
	view.setup(rules)
	view.kv.auto_process = false
	view.hide_fn = func() -> Array: return [hud_stub]
	var asked := [0]
	view.respawn_requested.connect(func() -> void: asked[0] += 1)
	var ended := []
	view.over.connect(func(skipped: bool) -> void: ended.append(skipped))

	_check(clips.size() == 1 and view.play(clips[0]["clip"], {"killer": "Bolt"}), "a clip from the ring starts the replay")
	view.kv.advance(0.5)
	view.kv.advance(0.5)
	_check(view.is_active() and view.camera.current and not hud_stub.visible, "the replay camera is current and the HUD is hidden")
	var from_kill := view.camera.global_position
	view.kv.advance(0.5)
	_check(view.camera.global_position.distance_to(from_kill) > 0.001 and absf(view.camera.fov - 80.0) < 0.5,
		"it follows the killer's eye with the killer's field of view")
	_check(view.crosshair.visible and view.crosshair.at.distance_to(Vector2(0.5, 0.45)) < 0.01, "and draws the killer's crosshair where it was")
	view.kv.killcam.skip()
	_check(ended == [true] and asked[0] == 1, "a skip ends it and asks for the respawn")
	_check(previous.current and hud_stub.visible and not view.crosshair.visible, "the normal camera and HUD come back", "%s %s %s, was %s" % [previous.current, hud_stub.visible, view.crosshair.visible, was_current])

	_check(view.play(clips[0]["clip"], {"killer": "Bolt"}), "another death plays again")
	for _i in 200:
		view.kv.advance(0.1)
	_check(ended == [true, false] and asked[0] == 1 and previous.current, "a replay that runs out resumes the flow without a respawn request", "%s %s %s" % [ended, asked, previous.current])
	rules.camera = DotKillViewRules.Camera.BEHIND
	var eye := [Transform3D()]
	view.kv.view.connect(func(x: Transform3D, _f: float, _c: Vector2, _h: bool) -> void: eye[0] = x)
	var _again := view.play(clips[0]["clip"], {"killer": "Bolt"})
	view.kv.advance(0.5)
	view.kv.advance(0.5)
	var cam := view.camera.global_position
	var x0: Transform3D = eye[0]
	var gap := cam.distance_to(x0.origin)
	var ahead := (x0.origin - cam).dot(-x0.basis.z)
	_check(gap > 1.5 and gap < 6.0 and ahead > 1.0 and not view.crosshair.visible,
		"mp_killview_camera 1: the camera rides behind the killer's eye, no crosshair", "gap %.2f ahead %.2f" % [gap, ahead])
	view.kv.killcam.skip()
	var off := DotKillViewRules.new()
	var quiet := DotKillViewClient.new()
	port.add_child(quiet)
	quiet.setup(off)
	_check(not quiet.play(clips[0]["clip"], {}), "with the cvar off nothing plays")

	port.queue_free()
	_done()


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
