extends "arena_client_part4.gd"

func _present_frame(delta: float) -> void:
	if net != null and not _offline:
		# Every frame: remote players otherwise step at the snapshot rate.
		var t := Time.get_ticks_usec()
		var replays := bridge.probe_replays_before() if bridge != null else -1
		net.interpolate_frame()
		if bridge != null:
			bridge.probe_replays_after(replays)
		ArenaFrameProbe.add(&"interpolate", t)

	# Where every speaker is, so a proximity voice comes from the player who said it.
	var lap := ArenaFrameProbe.lap_start()
	if extras != null:
		extras.pump_voice(delta)
	lap = ArenaFrameProbe.lap(&"c_voice", lap)

	_ease_view_turn(delta)
	_fold_look()
	_fold_correction()
	_fold_alpha()
	lap = ArenaFrameProbe.lap(&"c_fold", lap)

	# Your own body when you look down: the player's setting, else the server's mp_fp_body.
	if player != null and game != null and player.controller != null:
		player.present_own_body(own_body_mode(),
			(player.view_now as Vector2).x if player.view_now != null else player.controller.state.yaw)

	lap = ArenaFrameProbe.lap(&"c_own_body", lap)
	_face_a_respawn()
	_present_sprite_view()
	lap = ArenaFrameProbe.lap(&"c_sprite_view", lap)

	if presentation != null:
		# Neither dot-audio nor dot-fx ticks itself: `_process` stops while paused.
		var eye := camera_position()
		var forward := Vector3.FORWARD
		if player != null and player.camera != null:
			forward = -player.camera.global_transform.basis.z
		var t_pres := Time.get_ticks_usec()
		presentation.present(delta, eye, forward)
		_apply_shake()
		ArenaFrameProbe.add(&"c_presentation", t_pres)
		if platform != null and platform.slide_sounds != null and presentation.steps != null:
			presentation.steps.surf_rules = platform.slide_sounds.get(&"surf_rules")
		var t_walk := Time.get_ticks_usec()
		presentation.keep_walkers(game.players())
		ArenaFrameProbe.add(&"c_walkers", t_walk)
		lap = ArenaFrameProbe.lap_start()
		_present_roof(delta, eye)
		lap = ArenaFrameProbe.lap(&"c_roof", lap)

	# A position report once a second: the only way to see where a browser client thinks it is.
	_report_timer += delta

	if _report_timer >= 1.0 and player != null:
		_report_timer = 0.0
		var st := player.controller.state
		DotLog.debug(CHANNEL, "where the local player is", {
			"position": st.position,
			"node": player.global_position,
			"camera": camera_position(),
			"yaw": st.yaw,
			"pitch": st.pitch,
			"grounded": st.is_grounded(),
			"predicted": _is_predicted(),
		})

	if game == null:
		return

	var t := Time.get_ticks_usec()
	# The camera the viewer sees through (a spectator's or the death view's too), so that no
	# body is thinned out in front of it. None: everything is drawn in full.
	var view_cam := get_viewport().get_camera_3d()
	var frustum: Array = view_cam.get_frustum() if view_cam != null and ArenaPlayer.present_lod_enabled and ArenaPlayer.lod_frustum else []
	for body in game.players():
		if view_cam != null:
			body.present_lod(delta, view_cam.global_position, -view_cam.global_transform.basis.z, frustum)
		else:
			body.present(delta)
	ArenaFrameProbe.add(&"bodies", t)

	var t_flash := Time.get_ticks_usec()
	_present_flashlights()
	ArenaFrameProbe.add(&"c_flashlights", t_flash)
	var t_rest := Time.get_ticks_usec()
	_present_frame_rest()
	ArenaFrameProbe.add(&"c_rest", t_rest)

## The roof the world's physics layout names, for the name tags, the roof sounds and the shot effects.
func _present_roof(delta: float, eye: Vector3) -> void:
	var stack_now := game.player_stack
	if stack_now != null and stack_now.physics != null and stack_now.physics.layout != null:
		if _roof_layout != stack_now.physics.layout:
			_roof_layout = stack_now.physics.layout
			_roof_mask = _roof_layout.mask_of([&"world"])
			_tag_mask = _roof_layout.mask_of([&"world", &"prop"])
		sync_name_tags(_tag_mask)
		presentation.follow_roof(delta, eye, get_viewport().world_3d.direct_space_state, _roof_mask)
		var shot_rig: Object = player.weapons if player != null else null
		if shot_rig != null and is_instance_valid(shot_rig) and shot_rig.has_method(&"shot_fx"):
			var shot_fx: Object = shot_rig.call(&"shot_fx")
			if shot_fx != null:
				shot_fx.set(&"roof", presentation.shot_roof)


func _process(delta: float) -> void:
	var t := Time.get_ticks_usec()
	# Frames that run their whole step cap and still drop owed ticks: shed cosmetic work (ArenaTickBudget.shed).
	if _offline and _tick_budget != null and _frame_at_usec > 0:
		ArenaTickBudget.shed_now = _tick_budget.note_frame((t - _frame_at_usec) / 1000000.0, 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0), Engine.max_physics_steps_per_frame)
	else:
		ArenaTickBudget.shed_now = 0.0
	_frame_at_usec = t
	if _touch != null:
		_touch.call(&"sync", _menu_open() or presentation != null and presentation.swallows_input(), _gun_in_hand())
	if game != null and game.knives != null:
		game.knives.bind_view(ragdolls, presentation.blood if presentation != null else null)
	_present_frame(delta)
	ArenaFrameProbe.add(&"present", t)
	ArenaFrameProbe.frame(delta, _probe_extra)

## The free-roam key: into a free camera while spectating, and back onto a player from it.
## A line when the server has roaming off (`mp_freeroam 0`) or a restricted camera
## (`mp_forcecamera`). Local: this game's client manager is authoritative over its own camera.
func toggle_roam() -> void:
	if game == null or game.spectate == null or player == null:
		return
	var id := player.player_id
	if not game.spectate.is_spectating(str(id)):
		return
	var res := game.spectate.toggle_roam(str(id))
	if not res.ok:
		if hud != null:
			hud.notice("Free roam is off on this server.")
		return
	_free_cam = null
	_roam_look = Vector2.ZERO

## The carried slot [param step] places along from the one in hand, wrapping. For the
## wheel. 0 when there is nothing else to go to.
func _cycled_slot(step: int) -> int:
	if player == null or player.arsenal == null:
		return 0

	var carried := player.arsenal.slots()

	if carried.size() < 2:
		return 0

	var at := carried.find(player.arsenal.current_slot())
	return carried[posmod(at + step, carried.size())]

## The touch NEXT button: the carried slot after the one in hand.
func touch_next_weapon() -> void:
	_wanted_slot = _cycled_slot(1)

## Whether auto-fire and aim assist may act: alive, playing, and the pointer is the aim.
func touch_live() -> bool:
	return player != null and player.is_alive() and mouse_drives_view() and not is_roaming() and not _watching_other()

func _gun_in_hand() -> DotWeaponDef:
	return player.arsenal.current_def() if player != null and player.arsenal != null else null

## Alt-tabbing away leaves a captured pointer on a window nobody is looking at; give the cursor
## back and ask for a click on return, which also re-arms browser pointer lock.
func _exit_tree() -> void:
	super()
	_drain_model_reads()
	ArenaTickBudget.shed_now = 0.0
	if _local_team_menu != null:
		_local_team_menu.release()
		_local_team_menu = null

func _notification(what: int) -> void:
	if what != NOTIFICATION_APPLICATION_FOCUS_OUT and what != NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		return

	if player == null or _menu_open() or not mouse_drives_view():
		return

	_awaiting_click = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if hud != null:
		hud.notice("Click to play")

## Asks the server for a switch (the bit is held a few ticks) and shows it here at once.
func switch_flashlight() -> void:
	if _watching_other():
		return
	_flash_ticks = _flash_hold_ticks()
	_flash_msec = Time.get_ticks_msec()
	if flash != null and is_instance_valid(flash):
		var _asked := flash.toggle()

## Whether [param event] is on [param action], pressed or released. False for an action the
## InputMap does not have, which `InputEvent.is_action` reports as an error.
static func _is(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action(action)

func _unhandled_input(event: InputEvent) -> void:
	# [b]The console first, and before the click that captures the mouse.[/b] Without it, a click
	# inside an open console grabs pointer lock and the next keystroke goes to movement.
	if presentation != null and presentation.swallows_input():
		return

	# Before the `player == null` guard, deliberately. A browser player clicks while
	# the world is still loading more often than not, and a click swallowed for want of
	# a player is a click that never captures anything — after which the only
	# affordance the game offers is one it has already ignored.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not _menu_open():
			_awaiting_click = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

			if hud != null:
				hud.notice("")

			return

	# The menu is up: every key is its own (dot-menu closes on Escape), and nothing below
	# may act on the world behind it.
	if _menu_open():
		return

	if event.is_action_pressed(&"ui_cancel"):
		# Escape RELEASES and does not toggle. Escape is how a browser itself exits
		# pointer lock, and it then refuses to re-enter for about a second — so a
		# toggle bound to it silently does nothing every other press on the web. One
		# key that releases and one gesture that captures is the same contract on
		# every platform.
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			if hud != null:
				hud.notice("Click to play. Escape again for the menu.")
		elif game_menu != null:
			game_menu.open()
		return

	if player == null:
		return

	# dot-mobile's overlay forwards every touch to the sampler itself; with the overlay off, a touch moves nothing.
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		return

	if event is InputEventMouseMotion:
		if mouse_drives_view() and (_touch == null or not bool(_touch.call(&"takes", event))):
			if is_roaming():
				# The free camera turns on the mouse, and the dead body's view stays put.
				_roam_look += (event as InputEventMouseMotion).relative
			elif _sampler != null:
				_sampler.handle_event(event)
		return

	# A talk key's release is read wherever the pointer is: push to talk may be on a mouse
	# button, and a release dropped below is a microphone that never closes.
	if _is(event, ArenaBindings.VOICE) and not event.is_pressed():
		if extras != null:
			extras.set_talking(false)
		return

	# A mouse button reaching here with the pointer released is aimed at a menu or at
	# "Click to play" (the click that captures returned above); it acts on nothing.
	if event is InputEventMouseButton and not mouse_drives_view():
		return

	if not (event is InputEventKey or event is InputEventMouseButton):
		return

	if event is InputEventKey and event.is_echo():
		return

	# Every key below is read through its action in `ArenaBindings`, so the Controls page
	# moves it. Push to talk first, BEFORE the "is this a press" filter, because a talk key
	# needs the release as much as the press: a key whose release nobody reads is a
	# microphone that never closes.
	if _is(event, ArenaBindings.VOICE):
		if extras != null:
			extras.set_talking(event.is_pressed())
		return

	if not event.is_pressed():
		return

	_press_action(event)

## A key or button press read through its action in `ArenaBindings`: the prop tool, the lamp, the views and the slots.
func _press_action(event: InputEvent) -> void:
	# In a mode where players use props the Launch key is the prop tool's grab and the Bash
	# key its freeze (the launch moves to its own key, `launch_action`).
	if props_on_e() and _is(event, ArenaBindings.LAUNCH):
		# Grab, or let go of what is already held. One key for both, because a player who
		# has to remember which of two keys they pressed last is a player holding a crate
		# they cannot put down.
		_ask_prop(
			ArenaEvents.PropAct.RELEASE if _holding
			else ArenaEvents.PropAct.GRAB
		)
		_holding = not _holding
		return
	if InputMap.has_action(ArenaBindings.FLASHLIGHT) and event.is_action_pressed(ArenaBindings.FLASHLIGHT):
		switch_flashlight()
		return
	if props_on_e() and _is(event, ArenaBindings.BASH):
		_ask_prop(ArenaEvents.PropAct.FREEZE)
		return
	if _is(event, ArenaBindings.PUNT):
		_ask_prop(ArenaEvents.PropAct.PUNT)
		_holding = false
		return
	if _is(event, ArenaBindings.VIEW):
		toggle_view()
		return
	if _is(event, ArenaBindings.ROAM):
		toggle_roam()
		return

	# The slots: requested through the COMMAND, never by calling the arsenal directly. A
	# client that switched its own weapon would be predicting a switch the server never
	# simulated, and the next snapshot would take it back. Five keys for the pack's five
	# slots: melee, sidearm, primary, heavy, throwable.
	for i in range(ArenaBindings.SLOTS.size()):
		if _is(event, ArenaBindings.SLOTS[i]):
			_wanted_slot = i + 1
			return
	# The wheel walks the carried slots, by the same request.
	if _is(event, ArenaBindings.WEAPON_PREVIOUS):
		_wanted_slot = _cycled_slot(-1)
	elif _is(event, ArenaBindings.WEAPON_NEXT):
		_wanted_slot = _cycled_slot(1)
	elif _is(event, ArenaBindings.WEAPON_LAST):
		# The last weapon, which is the switch players make most.
		_wanted_slot = _last_slot


## Where this client thinks it is, as one line. What the console's `where` prints.
func describe_position() -> PackedStringArray:
	if player == null:
		return PackedStringArray(["no local player yet"])
	var st := player.controller.state
	return PackedStringArray([
		"position %s" % st.position,
		"node     %s" % player.global_position,
		"camera   %s" % camera_position(),
		"yaw %.1f  pitch %.1f  grounded %s" % [st.yaw, st.pitch, st.grounded],
	])

func describe() -> Dictionary:
	return {
		"offline": _offline,
		"player": player.player_id if player != null else -1,
		"watching": _watch_id,
		"bots": _bots.size(),
		"net": bridge.describe() if bridge != null else "none",
	}
