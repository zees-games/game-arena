extends "arena_client_part2.gd"

func _ready() -> void:
	# arena-weapons' art is this game's copy of it, wherever this game is mounted. A
	# delivered pack sits under `res://dot_cloud/<id>/<version>/`, and the pack's art table
	# names `res://assets/...` — so without this every gun loads invisible, one WARN each.
	AwModelCache.set_asset_root(ArenaPaths.root())
	# Before anything reads the art table: the first read caches it.
	ArenaWeaponSkins.apply()
	ArenaFrameProbe.from_launch()

	# Closed before anything else is built, so no frame shows a half-made world.
	_build_platform()
	_offline = platform.offline

	game = ArenaGame.new()
	game.name = "Game"
	game.is_authority = _offline
	game.stats_file = "user://arena_stats.json"

	# HEADLESS collision on a client with a screen: a predicting client must use the
	# server's analytic backend, or replays land differently and reconciliation corrects
	# a client that did nothing wrong. The visible level below is only what the player sees.
	game.headless = true
	game.register_service = _offline
	if _offline:
		_load_solo_config()
	add_child(game)

	# Connected here, before anything can create a player, rather than inside `_watch`.
	game.player_added.connect(_on_player_added)
	# The mode's banner, the moment a client learns it: "Gun Game: every kill gives you a
	# different gun", the way the genre says it when you spawn into one.
	game.mode_shown.connect(func(shown: ArenaMode) -> void:
		if hud != null:
			hud.notice("%s  -  %s" % [shown.display_name, shown.description])
	)

	# Offline, `-- --map <id>` picks the map, as it does for a dedicated server; a
	# connected client is told the server's map and rebuilds on it.
	game.defer_map_io = true
	var built := game.setup(_startup_map() if _offline else ArenaMap.dm_box())

	if not built.ok:
		DotLog.result(CHANNEL, "the arena could not be built", built)
		return

	# The world, which the server does not need and a player cannot do without. Held, because a map
	# change has to take it away again — see `_on_map_changed`.
	_enter_level.call(_offline)

	projectile_view = ArenaProjectileView.new()
	projectile_view.name = "Projectiles"
	add_child(projectile_view)

	_build_ragdolls()
	_build_killcam()
	_build_killview()
	if _offline:
		# Solo, the world is this process's and there is no KILL message: the death the game
		# decided is on the kill's entry.
		game.player_killed.connect(_on_solo_kill)
		game.loadout_rolled.connect(func(id: int, text: String) -> void:
			if player != null and id == player.player_id and hud != null:
				hud.notice(text))

	_sampler = make_sampler()
	# C slides as well as Duck: added once the key table has been applied, in
	# `_build_interface` (`_add_slide_key`), or applying it would take C off again.

	# Before the interface, because the field of view and the crosshair come out of the
	# settings document and a screen built first would have laid itself out from the
	# defaults.
	_build_presentation()
	_build_interface()

	# The player's look and crosshair settings, onto the two things they shape. After both
	# exist, and pushed rather than waited for: a value loaded from disk has not changed,
	# so a binding that only listened would leave a saved sensitivity doing nothing.
	if presentation != null:
		presentation.bind_look(_sampler.tunables)
		if hud != null:
			presentation.bind_crosshair(hud.crosshair)

	if _offline:
		_start_offline()
	else:
		var netted := _build_netcode()
		DotLog.result(CHANNEL, "netcode", netted)
		if netted.ok and link != null:
			_start_remote_workbench()

	# The server's arena_ambient* (a link tells them) drive the quiet layer; the player's sliders multiply on top.
	if presentation != null and presentation.ambient != null:
		presentation.ambient.follow_settings(presentation.settings, game.ambient_rules)
	if presentation != null:
		presentation.use_shot_rules(game.shot_rules)

	_grab_mouse()
	platform.slide_settings = presentation.settings
	DotLog.result(CHANNEL, "the platform", platform.setup())
	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	DotLog.result(CHANNEL, "avatar actions", platform.add_avatar_actions(net, _avatar_figure))
	_suspend_input(platform.is_input_blocked())

## The view key: the other view if the server's `mp_forceview` allows it, a line if not.
func toggle_view() -> void:
	if player == null:
		return
	var wanted := game.view_rules.toggled(player.third_person)
	if wanted == player.third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.notice(game.view_rules.refusal())
		return
	_set_third_person(wanted)
	if hud != null:
		hud.notice("Third person" if wanted else "First person")

## Solo: the bridge's per-tick record and delivery, in this process. Only the local player's clip is played.
func _tick_solo_killview() -> void:
	if solo_killview == null or not game.killview_rules.enabled:
		return
	var tick := game.current_tick()
	var now := float(tick) / float(game.tick_rate)
	solo_killview.record(now)
	for ready: Dictionary in solo_killview.collect(now, tick):
		if player != null and int(ready["victim"]) == player.player_id:
			_on_killview(ready["clip"], ready["info"])

## The kill view, the final killcam and the winner reveal each hide the HUD and put back what they found. When two overlap, the later one found it already hidden and restores it hidden, for the rest of the session; this is the one owner that says no screen is up, so the HUD returns.
func _restore_hud_if_orphaned() -> void:
	if hud == null or hud.visible or not _reveal_hid.is_empty():
		return
	if killcam != null and killcam.is_playing():
		return
	if killview != null and killview.is_active():
		return
	if winner_reveal != null and winner_reveal.is_active():
		return
	DotLog.warn(CHANNEL, "HUD was left hidden with no screen up; restored")
	hud.visible = true

## Records the frame for the killcam, or draws the replay over it. Solo has no MATCH message,
## so the end of a solo match is seen here.
func _killcam_frame() -> void:
	if killcam == null or game == null:
		return
	killcam.hide_while_playing = [hud, view_model]
	killcam.world_mask = _level_mask()
	killcam.frame()
	_restore_hud_if_orphaned()
	var now := int(game.match_node.state) if game.match_node != null else -1
	if _offline and now != _seen_match_state and now == DotMatch.State.MATCH_END:
		_begin_match_end()
	_seen_match_state = now

func is_ready_to_show() -> bool:
	return gate != null and gate.is_open()

## What a shell draws once under its loading screen besides what is already in the tree: the meshes
## and materials of every weapon model the art table names, so the first time somebody draws a gun
## nobody has held yet is not also the first time its materials compile (in a browser.
func warm_up_items() -> Array:
	return gate.warm_items() if gate != null else []

## `cl_weapon_sprites 1`: the held weapon as a flat sprite under the camera in place of the hands.
func _present_sprite_view() -> void:
	if view_model == null or player == null or player.camera == null:
		return
	if not ArenaWeaponIcons.shared.sprites:
		if _sprite_view != null:
			_sprite_view.queue_free()
			_sprite_view = null
			view_model.visible = true
		return
	if _sprite_view == null:
		_sprite_view = ArenaSpriteWeapon.make(ArenaSpriteWeapon.Mode.VIEW)
		player.camera.add_child(_sprite_view)
	var def: Variant = player.arsenal.current_def() if player.arsenal != null else null
	_sprite_view.show_weapon(def.id if def != null else &"")
	view_model.visible = _sprite_view.texture == null

## Whether right mouse aims (the player's setting, on by default) rather than bashes.
func right_mouse_aims() -> bool:
	if presentation == null or presentation.settings == null:
		return true
	return bool(presentation.settings.get_value(&"right_mouse_aims"))

## Whether [param action] is held, and false for an action the InputMap does not have (a
## suite's client, built with no presentation, has applied no table).
static func _held(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)

func _local_commands(move: DotFpsCommand) -> Dictionary:
	var out: Dictionary = {}

	if player != null:
		out[player.player_id] = [move, _fire]

	for id in _bots:
		var bot: ArenaPlayer = _bots[id]
		out[int(id)] = [bot.get_meta("bot_move", DotFpsCommand.new()), bot.get_meta("bot_fire", DotWeaponCommand.new())]

	return out

func is_roaming() -> bool:
	return game != null and game.spectate != null and player != null \
		and game.spectate.is_roaming(player.player_id)

func _touch_held(id: StringName) -> bool:
	return _touch != null and bool(_touch.call(&"is_held", id))


## Remembers the slot before the one in hand, for Q.
func _note_held_slot() -> void:
	if player == null or player.arsenal == null:
		return

	var now := player.arsenal.current_slot()

	if now != _held_slot:
		if _held_slot > 0:
			_last_slot = _held_slot
		_held_slot = now

## Whether the pointer is currently the player's aim rather than a pointer.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)

	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

## The fire command, from the keyboard and the mouse. [b]`DotWeaponCommand` is a button BITMASK, not
## a set of booleans.[/b] `set_button` is the accessor; assigning `.attack` creates nothing and
## errors at runtime with "Invalid assignment of property or key 'attack'".
func _read_fire(move: DotFpsCommand) -> void:
	var firing := mouse_drives_view() and (_held(ArenaBindings.FIRE) or _touch_held(&"fire"))

	_fire.set_button(DotWeaponCommand.BUTTON_ATTACK, firing)
	# The Aim key (right mouse) aims down the sights, by default; the Bash key (X) is the pack's
	# alt-fire ("quick melee"). A player who would rather bash with the Aim key turns the
	# `right_mouse_aims` setting off.
	var right := mouse_drives_view() and _held(ArenaBindings.AIM) \
		and not _aim_break.blocked(Time.get_ticks_msec() * 0.001)
	var aims := right_mouse_aims() and not props_on_e()
	var bash := (right and not aims) or (not props_on_e() and mouse_drives_view() and _held(ArenaBindings.BASH))
	_fire.set_button(DotWeaponCommand.BUTTON_ALT, bash)
	_fire.set_button(ArenaFlashlight.BUTTON, _flash_ticks > 0)
	_flash_ticks = maxi(_flash_ticks - 1, 0)
	if player != null:
		player.aim_held = right and aims
	if _sampler != null:
		_sampler.look_scale = player.aim_zoom() if player != null else 1.0
	# On the wire as well, for the server's No Scope medal; nothing simulated reads it.
	_fire.set_button(ArenaPlayer.BUTTON_AIM, right and aims)
	_fire.set_button(DotWeaponCommand.BUTTON_RELOAD, mouse_drives_view() and (_held(ArenaBindings.RELOAD) or _touch_held(&"reload")))
	_fire.set_button(DotWeaponCommand.BUTTON_FIRE_MODE, mouse_drives_view() and _held(ArenaBindings.FIRE_MODE))
	_fire.set_button(DotWeaponCommand.BUTTON_DROP, mouse_drives_view() and _held(ArenaBindings.WEAPON_DROP))
	_fire.set_button(DotWeaponCommand.BUTTON_USE, mouse_drives_view() and _held(ArenaBindings.USE))
	_note_held_slot()
	_fire.yaw = move.yaw
	_fire.pitch = move.pitch

	# `DotArsenal` reads `command.slot > 0` as "switch to this" and 0 as "leave it alone", so this
	# is a REQUEST that is cleared once made rather than a mirror of the current slot.
	_fire.slot = _wanted_slot
	_wanted_slot = 0

const ArenaJumpGate := preload("arena_jump_gate.gd")

var _jump_gate := ArenaJumpGate.new()

## `cl_respawn_jump_gate` (default 1): see [ArenaJumpGate].
func _gate_jump_after_death(move: DotFpsCommand) -> void:
	var on := presentation == null or presentation.settings == null \
		or presentation.settings.get_bool(&"respawn_jump_gate", true)
	var away := player != null and (not player.is_alive() \
		or (killcam != null and killcam.is_playing()) \
		or (killview != null and killview.is_active()))
	_jump_gate.filter(move, away, on and player != null)

func _physics_step(delta: float) -> void:
	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	_gate_jump_after_death(move)
	if hud != null and presentation != null and presentation.bindings != null:
		hud.launch_key_text = presentation.bindings.key_for(launch_action())

	# The launch: the movement command's first user bit, which the motor reads when the
	# server's rules have the launch on. Same guard as the trigger, so typing in the chat
	# box does not throw anybody into the air.
	move.set_button(
		DotFpsCommand.BUTTON_USER_0, mouse_drives_view() and _held(launch_action())
	)
	if is_roaming():
		# The roaming spectator flies a camera and does not walk the dead player about.
		move.move = Vector2.ZERO
		move.buttons = 0
	_read_fire(move)

	if _offline:
		if game != null:
			var t_bots := Time.get_ticks_usec()
			_drive_bots()
			ArenaFrameProbe.add(&"bots", t_bots)
			var t_tick := Time.get_ticks_usec()
			game.tick(_local_commands(move))
			ArenaFrameProbe.add(&"game_tick", t_tick)
			_tick_solo_killview()
		return

	if net == null or not net.is_running() or bridge == null:
		return

	# The clock says how many ticks this frame is worth, which on a client whose engine
	# runs at the server's rate is almost always exactly one.
	bridge.advance_latency(delta)
	var ticks := net.clock.advance(delta)

	# [b]Each pass is its own tick.[/b] `advance` has already moved the clock by all of them, so
	# `input_tick()` is the LAST one on every pass: a frame worth two ticks sent the second twice
	# and the first never, the server repeated a stale command for the one it never got.
	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		var tick := net.clock.input_tick() - (ticks - 1 - i)
		bridge.client_tick(tick, move, _fire)

		bridge.send_input(tick, move, _fire)

# --- The loop --------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var t := Time.get_ticks_usec()
	_physics_step(delta)
	ArenaFrameProbe.add(&"physics", t)

## A connected client's respawn faces the way its spawn faces. [b]Only the client can turn the
## view[/b]: the server teleports the player facing the spawn, then applies the next command, whose
## angles are this client's sampler's -- the look the mouse left before the death.
func _face_a_respawn() -> void:
	if _offline or player == null or player.controller == null or _sampler == null or game == null:
		return

	var alive := player.is_alive()
	var came_back := alive and not _was_alive
	_was_alive = alive

	if not came_back or game.map == null:
		return

	var at := player.controller.state.position
	var nearest := INF
	var yaw := NAN

	for spawn: Transform3D in game.map.spawns:
		var d := spawn.origin.distance_to(at)
		if d < nearest:
			nearest = d
			yaw = rad_to_deg(spawn.basis.get_euler().y)

	if nearest < SPAWN_FACE_REACH:
		_sampler.look_at_angles(yaw, 0.0)

## What the renderer drew last frame, and the lights that cast shadows: the web's budget is draw calls.
func _render_cost() -> Dictionary:
	var lights := 0
	var casters := 0
	for l in get_tree().root.find_children("*", "Light3D", true, false):
		lights += 1
		if (l as Light3D).shadow_enabled:
			casters += 1
	return {
		"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"lights": lights,
		"shadow_lights": casters,
	}

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

	if not game.spectate.is_spectating(id):
		if hud != null:
			hud.roam_hint = ""
		ArenaWeaponDropWiring.update_panel(self, _held(ArenaBindings.USE), get_process_delta_time())
		if hud != null:
			# The world panel over a dropped weapon already says "Take ammo"; the HUD line would repeat it.
			var panel: Node3D = get_meta(&"pickup_view") if has_meta(&"pickup_view") else null
			hud.use_hint = "" if panel != null and panel.visible else _pickup_hint()
		if not player.camera.current:
			player.camera.current = true
		return

	if hud != null:
		var roaming := game.spectate.is_roaming(id)
		hud.roam_hint = "Back to players" if roaming else ("Free camera" if game.spectate.can_roam(id) else "")

	# The chase and death cameras are pulled out of the level by dot-spectate, given it.
	var manager := game.spectate.manager
	if manager != null and manager.camera_world == null:
		manager.camera_world = player.camera.get_world_3d()
		manager.camera_mask = _level_mask()

	var where := game.spectate.camera_for(id)

	if game.spectate.is_roaming(id):
		where = _fly_free_camera(id, where)
	else:
		_free_cam = null

	if where == Transform3D.IDENTITY:
		return

	player.camera.global_transform = where

func _present_frame_rest() -> void:
	_watch_projectiles()

	_drive_spectator_camera()
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

## How much of their own body the local player sees in first person (DotPlayerViewRules.BODY_*):
## the `first_person_body` setting, or the server's when it is "auto"; arena's `fp_body` rule keeps at least the legs.
func own_body_mode() -> int:
	var picked := presentation.settings.get_string(&"first_person_body", "auto") if presentation != null and presentation.settings != null else "auto"
	var mode := game.view_rules.own_body(OWN_BODY_CHOICES.find(StringName(picked)) - 1)
	return DotPlayerViewRules.BODY_LEGS if mode == DotPlayerViewRules.BODY_OFF and picked == "auto" and game.rule("fp_body") != 0.0 else mode

## Whether the camera shows somebody else's view (a spectator, a death or kill cam). The eye light is
## then not ours to switch: the watched player's own beam is drawn by the crowd from their head.
func _watching_other() -> bool:
	if player == null or game == null:
		return false
	return not player.is_alive() or (game.spectate != null and game.spectate.is_spectating(player.player_id))

## The sound manager the flashlight clicks play through, or null before audio is up.
func _flash_audio_ref() -> DotNodeRef:
	if presentation == null or presentation.audio == null or not presentation.audio.is_inside_tree():
		return null
	return DotNodeRef.of_path(presentation.audio.get_path())

func _on_flash_switch(_want: bool) -> void:
	_flash_ticks = ArenaFlashlight.HOLD_TICKS
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
