extends "arena_client_part3.gd"

## What the renderer drew last frame, and the lights that cast shadows: the web's budget is draw calls.
func _render_cost() -> Dictionary:
	var lights := 0
	var casters := 0
	var shown := 0
	var local := 0
	for l in get_tree().root.find_children("*", "Light3D", true, false):
		lights += 1
		var light := l as Light3D
		if light.shadow_enabled:
			casters += 1
		if light.is_visible_in_tree():
			shown += 1
			if light is OmniLight3D or light is SpotLight3D:
				local += 1
	var vp := get_viewport().get_viewport_rid()
	return {
		"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"prims": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"lights": lights,
		"lights_on": shown,
		"local_lights_on": local,
		"shadow_lights": casters,
		"vp_cpu_ms": snappedf(RenderingServer.viewport_get_measured_render_time_cpu(vp), 0.01),
		"setup_cpu_ms": snappedf(RenderingServer.get_frame_setup_time_cpu(), 0.01),
	}

## Times the draw itself, from `frame_pre_draw` to `frame_post_draw`, as the probe's "draw"
## section: on the web the draw runs on the same thread as the scripts, so it is part of the frame.
## Wired once, and only while the probe runs.
var _draw_at_usec := 0

func _watch_draw() -> void:
	if ArenaFrameProbe.interval <= 0.0 or RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		return
	RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

func _on_pre_draw() -> void:
	_draw_at_usec = Time.get_ticks_usec()

func _on_post_draw() -> void:
	if _draw_at_usec > 0:
		ArenaFrameProbe.add(&"draw", _draw_at_usec)
		_draw_at_usec = 0

## The round trip and the input lead beside a frame report: a stalled frame shows up in
## both before it shows up anywhere else.
func _probe_extra() -> Dictionary:
	if net == null or _offline:
		return _render_cost()
	var clock := net.clock.describe()
	var out := _render_cost()
	out.merge({
		"rtt_ms": int(net.stats.rtt_percentile(0.5)),
		"link_rtt_ms": int(ArenaNetBridge.link_rtt_ms(link)) if link != null else -1,
		"lead": net.clock.tick - net.clock.server_tick(),
		"snaps": clock.get("snaps", 0),
		"lost_ms": clock.get("lost_ms", 0),
	})
	return out

func _on_detonated(at: Vector3, _spawn: DotWeaponSpawn) -> void:
	if presentation != null:
		presentation.on_explosion(at, camera_position())

## Points the drawing and the explosions at whichever projectile layer the game has now. Every frame
## and cheap, because a map change builds a new layer on the authority and a layer connected once at
## boot would go deaf after the first `changelevel`.
func _watch_projectiles() -> void:
	var layer: RefCounted = game.projectiles if game != null else null

	if projectile_view != null:
		projectile_view.projectiles = layer

	if layer == _heard_projectiles:
		return

	_heard_projectiles = layer

	if layer != null and not layer.detonated.is_connected(_on_detonated):
		layer.detonated.connect(_on_detonated)

## Whether the screen shows a replay (the kill view or final killcam): live pickup prompts do not belong over it.
func _in_replay_view() -> bool:
	return is_inside_tree() and KillPovRules.is_replay_camera(get_viewport().get_camera_3d())

## The prompt for the dropped weapon in front of the player, which the use key takes; empty when none.
func _pickup_hint() -> String:
	if game.map_io != null and player != null and player.is_alive():
		var aimed: Dictionary = game.map_io.aim_from(player.camera.global_position, -player.camera.global_basis.z)
		if not aimed.is_empty() and game.map_io.use.in_reach(aimed):
			return String(aimed["label"])
	return ""

static func _strength(action: StringName) -> float:
	return Input.get_action_strength(action) if InputMap.has_action(action) else 0.0

## One frame of the free camera: the mouse turn folded in, then the movement keys. Seeded from
## where the camera was on the first frame of a roam, so it starts where the spectator looked.
func _fly_free_camera(id: int, current: Transform3D) -> Transform3D:
	if _free_cam == null:
		_free_cam = DotSpectatorFreeCam.new()
		_free_cam.rules = game.spectate_rules
		_free_cam.seed_from(current)
	var tunables := player.controller.tunables if player.controller != null else null
	var sens := deg_to_rad(tunables.mouse_sensitivity) if tunables != null else 0.0025
	_free_cam.look(Vector2(-_roam_look.x, -_roam_look.y) * sens)
	_roam_look = Vector2.ZERO
	var move := Vector3(
		_strength(&"dot_fps_right") - _strength(&"dot_fps_left"),
		_strength(&"dot_fps_jump") - _strength(&"dot_fps_crouch"),
		_strength(&"dot_fps_forward") - _strength(&"dot_fps_back"),
	)
	if not mouse_drives_view():
		move = Vector3.ZERO
	var pose := _free_cam.step(move, _held(ArenaBindings.DASH), _held(ArenaBindings.WALK), get_process_delta_time())
	var _kept := game.spectate.manager.move_free(str(id), pose.origin, pose.basis)
	return pose

## Where a dead player looks. [b]Until this existed the camera stayed where the body fell.[/b] That
## is the one thing a first-person game must not do: the corpse is on the floor, so the view is on
## the floor, and the seconds before a respawn are spent looking at a wall from ankle height.
func _drive_spectator_camera() -> void:
	if game.spectate == null or player == null or player.camera == null:
		return

	var id := player.player_id

	if not game.spectate.is_spectating(str(id)):
		if hud != null:
			hud.roam_hint = ""
		ArenaWeaponDropWiring.update_panel(self, _held(ArenaBindings.USE), get_process_delta_time())
		if hud != null:
			# The world panel over a dropped weapon already says "Take ammo"; the HUD line would repeat it.
			var panel: Node3D = get_meta(&"pickup_view") if has_meta(&"pickup_view") else null
			hud.use_hint = "" if (panel != null and panel.visible) or _in_replay_view() else _pickup_hint()
		if not player.camera.current:
			player.camera.current = true
		return

	# Dead and watching a replay: the live pickup panel must not stay up over the past.
	if has_meta(&"pickup_view") and (get_meta(&"pickup_view") as Node3D).visible:
		(get_meta(&"pickup_view") as Node3D).visible = false
		if hud != null:
			hud.use_hint = ""

	if hud != null:
		var roaming := game.spectate.is_roaming(str(id))
		hud.roam_hint = "Back to players" if roaming else ("Free camera" if game.spectate.can_roam(str(id)) else "")

	# The chase and death cameras are pulled out of the level by dot-spectate, given it.
	var manager := game.spectate.manager
	if manager != null and manager.camera_world == null:
		manager.camera_world = player.camera.get_world_3d()
		manager.camera_mask = _level_mask()

	var where := game.spectate.camera_for(str(id))

	if game.spectate.is_roaming(str(id)):
		where = _fly_free_camera(id, where)
	else:
		_free_cam = null

	if where == Transform3D.IDENTITY:
		return

	player.camera.global_transform = where

func _present_frame_rest() -> void:
	_watch_projectiles()

	var t_spec := Time.get_ticks_usec()
	_drive_spectator_camera()
	ArenaFrameProbe.add(&"c_spectate", t_spec)
	_killcam_frame()

## Hands the local player this frame's view, this frame's mouse motion folded in, so a frame on
## which no tick ran still turns. See [member ArenaPlayer.view_now].
func _fold_look() -> void:
	if player == null:
		return
	if _sampler == null or not _sampler.has_method(&"look_now"):
		player.view_now = null
		return
	player.view_now = _sampler.call(&"look_now")

## Hands the local player what is left of its prediction corrections, so the eye eases
## across one rather than jumping with it. See [member ArenaPlayer.drawn_offset].
func _fold_correction() -> void:
	if player == null:
		return
	player.drawn_offset = Vector3.ZERO
	if _offline or net == null or net.predictor == null or bridge == null:
		return
	var mine := bridge.behaviour_for(player.player_id)
	if mine != null and mine.identity != null and mine.identity.is_predicted():
		player.drawn_offset = net.predictor.visual_offset(mine.identity.net_id)

## Hands the local player how far through the clock's current tick this frame is, which a connected
## client's ticks are counted on. See [member ArenaPlayer.drawn_alpha].
func _fold_alpha() -> void:
	if player == null:
		return
	player.drawn_alpha = NAN
	if _offline or net == null or net.clock == null or not net.clock.has_method(&"render_alpha"):
		return
	player.drawn_alpha = float(net.clock.call(&"render_alpha"))

## Tells the name tags and health bars what this player picked, what the server allows and who is looking.
func sync_name_tags(world_mask: int) -> void:
	var settings: Object = presentation.settings if presentation != null else null
	if settings != null:
		TagRules.client_names = maxi(TagRules.parse(settings.get_string(&"name_tags", "team")), 0)
		TagRules.client_bars = maxi(TagRules.parse(settings.get_string(&"health_bars", "smart")), 0)
		TagRules.bar_colour_mode = &"health" if settings.get_string(&"health_bar_colour", "team") == "health" else &"team"
	TagRules.server_names = int(game.rule("nametags"))
	TagRules.server_bars = int(game.rule("hpbars"))
	TagRules.viewer_id = player.player_id if player != null else -1
	var shown := game.displayed_mode()
	var sided := shown != null and shown.is_team_mode() and not game.teams().is_empty()
	TagRules.viewer_team = game.team_of(TagRules.viewer_id) if sided and player != null else -1
	TagRules.team_colours.clear()
	TagRules.team_count = 0
	for t in game.teams():
		if sided and not t.is_spectator:
			TagRules.team_count += 1
			TagRules.team_colours[t.id] = t.colour
	TagRules.occluder_mask = world_mask


## How much of their own body the local player sees in first person (DotPlayerViewRules.BODY_*):
## the `first_person_body` setting, or the server's when it is "auto"; arena's `fp_body` rule keeps at least the legs.
func own_body_mode() -> int:
	var picked := presentation.settings.get_string(&"first_person_body", "auto") if presentation != null and presentation.settings != null else "auto"
	# cl_legs (DotOwnBodySetting) is the client veto: off hides the body whatever the server or the choice says.
	if presentation != null and presentation.settings != null and not presentation.settings.get_bool(DotOwnBodySetting.KEY, DotOwnBodySetting.DEFAULT):
		return DotPlayerViewRules.BODY_OFF
	var mode := game.view_rules.own_body(OWN_BODY_CHOICES.find(StringName(picked)) - 1)
	return DotPlayerViewRules.BODY_LEGS if mode == DotPlayerViewRules.BODY_OFF and picked == "auto" and game.rule("fp_body") != 0.0 else mode

## Whether the camera shows somebody else's view (a spectator, a death or kill cam). The eye light is
## then not ours to switch: the watched player's own beam is drawn by the crowd from their head.
func _watching_other() -> bool:
	if player == null or game == null:
		return false
	return not player.is_alive() or (game.spectate != null and game.spectate.is_spectating(str(player.player_id)))

## The sound manager the flashlight clicks play through, or null before audio is up.
func _flash_audio_ref() -> DotNodeRef:
	if presentation == null or presentation.audio == null or not presentation.audio.is_inside_tree():
		return null
	return DotNodeRef.of_path(presentation.audio.get_path())

## Ticks the flashlight button is held: the game's rate once it exists, the default before.
func _flash_hold_ticks() -> int:
	return ArenaFlashlight.hold_ticks(game.tick_rate if game != null else ArenaGame.DEFAULT_TICK_RATE)


func _on_flash_switch(_want: bool) -> void:
	_flash_ticks = _flash_hold_ticks()
	_flash_msec = Time.get_ticks_msec()

## The eye's light follows the server (but not for 0.4 s after our own switch, which shows at once); everyone else's beams follow theirs.
func _present_flashlights() -> void:
	if player == null or player.camera == null or game == null:
		return
	var cfg := game.flashlight_conf()
	if flash == null or not is_instance_valid(flash):
		flash = DotFlashlight.new()
		flash.name = "Flashlight"
		flash.config = cfg
		flash.handle_input = false
		flash.authoritative = false
		flash.allowed = DotFlashlightRules.allowed_on(cfg, String(game.map.id if game.map != null else ""))
		flash.audio = _flash_audio_ref()
		if not flash.switch_requested.is_connected(_on_flash_switch):
			flash.switch_requested.connect(_on_flash_switch)
		player.camera.add_child(flash)
	if flash.get_parent() != player.camera:
		flash.reparent(player.camera, false)
	if _watching_other():
		_flash_ticks = 0
		flash.apply_state({"on": false})
	elif Time.get_ticks_msec() - _flash_msec > 400:
		flash.apply_state({"on": player.flashlight and player.is_alive()})
	if flash_crowd == null or not is_instance_valid(flash_crowd):
		flash_crowd = DotFlashlightCrowd.new()
		flash_crowd.name = "Flashlights"
		flash_crowd.config = cfg
		flash_crowd.audio = _flash_audio_ref()
		add_child(flash_crowd)
	flash_crowd.set_viewer(camera_position())
	_flash_seen.clear()
	for other: ArenaPlayer in game.players():
		var key: Variant = other.player_id
		_flash_seen.append(key)
		flash_crowd.set_lit(key, other != player and other.flashlight and other.is_alive())
		flash_crowd.place(key, other.muzzle_position(), other.aim_direction())
	flash_crowd.retain(_flash_seen)

## Settles the view along the wall over about a tenth of a second instead of snapping it.
func _ease_view_turn(delta: float) -> void:
	if _sampler == null or is_zero_approx(_view_turn_left):
		return
	var step := _view_turn_left if absf(_view_turn_left) < 0.1 else _view_turn_left * (1.0 - exp(-VIEW_TURN_RATE * delta))
	_view_turn_left -= step
	_sampler.look_at_angles(_sampler.yaw + step, _sampler.pitch)

## Moves the aim by the change in the hit wobble since last frame, so the shots go where the sights wobble to; none at the hip.
func _apply_hit_wobble(now: float) -> void:
	if _sampler == null:
		return
	var target := _aim_break.wobble(now) if player.aim_held else Vector2.ZERO
	var step := target - _hit_wobble_applied
	_hit_wobble_applied = target
	if step != Vector2.ZERO:
		_sampler.look_at_angles(_sampler.yaw + step.x, _sampler.pitch + step.y)

## Adds the frame's camera shake. dot-fx computes it; this is the only thing that applies it.
##
## Same rule as dot-spectate's camera: one implementation then serves the play rig, a
## spectator's and a headless suite, with no second code path to keep in step.
func _apply_shake() -> void:
	if player == null or player.camera == null or presentation == null:
		return
	# Handed to the player rather than written onto the camera. `ArenaPlayer.present` is
	# the one place the camera's transform is set -- it says so in its own comment -- and a
	# second writer would fight it every frame for the same value.
	var now := Time.get_ticks_msec() * 0.001
	var hit := _aim_break.shake(now)
	player.camera_offset = presentation.camera_shake() + player.camera.global_transform.basis * Vector3(0.0, hit.y, hit.z)
	player.camera_roll = presentation.camera_roll() + deg_to_rad(hit.x)
	_apply_hit_wobble(now)

## Whether the local player is dot-net's idea of a predicted entity.
##
## Not the same question as "is it ours". `DotNetIdentity.is_predicted` also requires
## the authority to be SHARED and the owner peer id to match this manager's local one —
## and a client whose local peer id does not match what the server addressed it as gets
## an entity that is neither predicted nor interpolated, which nothing then moves.
func _is_predicted() -> bool:
	if bridge == null or player == null:
		return false

	var behaviour := bridge.behaviour_for(player.player_id)

	return behaviour != null \
		and behaviour.identity != null \
		and behaviour.identity.is_predicted()
