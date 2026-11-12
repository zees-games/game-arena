extends "arena_presentation_b0.gd"

const ArenaScopePrefs := preload("arena_scope_prefs.gd")

func _local_commands() -> DotConsoleLocal:
	var local := DotConsoleLocal.new()

	local.add_command(&"quit", "Leave the match", func(_a: PackedStringArray) -> Variant:
		get_tree().quit()
		return null
	)
	local.add_command(&"audio", "Show the audio system", func(_a: PackedStringArray) -> Variant:
		return audio.describe_lines()
	)
	local.add_command(&"fx", "Show the effects system", func(_a: PackedStringArray) -> Variant:
		return fx.describe_lines()
	)
	local.add_var(&"cl_penetration_decals", "1 marks both faces of a wall a shot passed through and each ricochet, 0 draws none.",
		func() -> Variant: return 1 if fx.config.penetration_decals else 0,
		func(v: Variant) -> Variant:
			var _set := settings.set_value(&"penetration_decals", str(v).strip_edges() != "0")
			fx.config.penetration_decals = settings.get_bool(&"penetration_decals", true)
			return DotResult.success(1 if fx.config.penetration_decals else 0)
	)
	local.add_var(&"cl_respawn_jump_gate", "1 swallows Space after a death until it is released, so the key that skips the kill view does not jump on the respawn; 0 lets it through.",
		func() -> Variant: return 1 if settings.get_bool(&"respawn_jump_gate", true) else 0,
		func(v: Variant) -> Variant:
			var _set := settings.set_value(&"respawn_jump_gate", str(v).strip_edges() != "0")
			return DotResult.success(1 if settings.get_bool(&"respawn_jump_gate", true) else 0)
	)
	_add_perf_vars(local)
	local.add_var(&"cl_def_cache", "1 keeps one weapon catalogue for watched hands' lookups; 0 builds it again on each (a reload start, a fitted code).",
		func() -> Variant: return 1 if _addon_static(AwWeaponCatalogue, &"def_cache", false) else 0,
		func(v: Variant) -> Variant:
			return DotResult.success(1 if _addon_static(AwWeaponCatalogue, &"def_cache", false, str(v).strip_edges() != "0") else 0))
	local.add_var(&"cl_glove_cache", "1 remembers each gun texture's colour for the first-person glove contrast; 0 reads it back on every equip.",
		func() -> Variant: return 1 if _addon_static(AwViewArms, &"albedo_cache", false) else 0,
		func(v: Variant) -> Variant:
			return DotResult.success(1 if _addon_static(AwViewArms, &"albedo_cache", false, str(v).strip_edges() != "0") else 0)
	)
	_add_remote_vars(local)
	local.add_var(&"cl_killcam_hz", "Most times a second the kill-cam records every body while no replay plays (0: every frame; 60 is the default).",
		func() -> Variant: return ArenaKillcamBodies.record_hz,
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_float():
				return DotResult.fail(DotError.CODE_INVALID, "cl_killcam_hz takes a number")
			ArenaKillcamBodies.record_hz = maxf(text.to_float(), 0.0)
			return DotResult.success(ArenaKillcamBodies.record_hz)
	)
	local.add_var(&"cl_pose_debug", "1 draws the held weapon's grip sockets, the hand targets and the arm bones over the view.",
		func() -> Variant: return 1 if ArenaViewArms.debug_pose else 0,
		func(v: Variant) -> Variant:
			ArenaViewArms.debug_pose = str(v).strip_edges() == "1"
			return DotResult.success(1 if ArenaViewArms.debug_pose else 0)
	)
	_add_arm_vars(local)
	ArenaFlagCarry.bind_console(local, settings)
	var _icons_bound := ArenaWeaponIcons.shared.bind_console(local)
	_add_view_vars(local)
	local.add_command(&"where", "Where this client thinks it is", func(_a: PackedStringArray) -> Variant:
		# The one thing no assertion and no screenshot can give you, and the reason ArenaClient
		# already logs a position once a second: when a browser client draws sky in every direction.
		if client == null or not client.has_method("describe_position"):
			return "no client"
		return client.call("describe_position")
	)

	return local


## Frame-report and per-frame build limits.
func _add_perf_vars(local: DotConsoleLocal) -> void:
	local.add_var(&"cl_perf", "Seconds between frame reports in the log (arena.perf); 0 is off.",
		func() -> Variant: return ArenaFrameProbe.interval,
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_float():
				return DotResult.fail(DotError.CODE_INVALID, "cl_perf takes a number of seconds")
			ArenaFrameProbe.set_interval(text.to_float())
			return DotResult.success(ArenaFrameProbe.interval)
	)
	local.add_var(&"cl_held_equips", "Most remote bodies that build a newly held gun in one frame; the rest wait a frame (0: no limit; 2 is the default).",
		func() -> Variant: return ArenaPlayer.held_equips_per_frame,
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_int():
				return DotResult.fail(DotError.CODE_INVALID, "cl_held_equips takes a whole number")
			ArenaPlayer.held_equips_per_frame = clampi(text.to_int(), 0, 64)
			return DotResult.success(ArenaPlayer.held_equips_per_frame)
	)
	local.add_var(&"cl_portrait_builds", "Most scoreboard portraits rendered in one frame (0: no limit; 1 is the default).",
		func() -> Variant: return ArenaHud.ArenaHudGlance.PortraitCache.builds_per_frame,
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_int():
				return DotResult.fail(DotError.CODE_INVALID, "cl_portrait_builds takes a whole number")
			ArenaHud.ArenaHudGlance.PortraitCache.builds_per_frame = clampi(text.to_int(), 0, 64)
			return DotResult.success(ArenaHud.ArenaHudGlance.PortraitCache.builds_per_frame)
	)
	local.add_var(&"cl_portrait_keep", "Portraits kept for players who drop out of the ranked row, so rank changes do not re-render them (24 is the default).",
		func() -> Variant: return ArenaHud.ArenaHudGlance.PortraitCache.keep_extra,
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_int():
				return DotResult.fail(DotError.CODE_INVALID, "cl_portrait_keep takes a whole number")
			ArenaHud.ArenaHudGlance.PortraitCache.keep_extra = clampi(text.to_int(), 0, 128)
			return DotResult.success(ArenaHud.ArenaHudGlance.PortraitCache.keep_extra)
	)
	local.add_var(&"cl_fx_pool_idle", "Most idle meshes each player's shot effects keep for reuse; a release past it frees the mesh (-1: keep all; 8 is the default).",
		func() -> Variant: return _addon_static(DotFxMeshPool, &"max_idle", -1),
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_int():
				return DotResult.fail(DotError.CODE_INVALID, "cl_fx_pool_idle takes a whole number")
			fx_pool_idle = clampi(text.to_int(), -1, 256)
			return DotResult.success(_addon_static(DotFxMeshPool, &"max_idle", -1, fx_pool_idle))
	)


## How far recoil turns the views, and the weapon sprite switch.
func _add_view_vars(local: DotConsoleLocal) -> void:
	local.add_var(&"cl_recoil_view", "How far each shot's recoil turns your view: 0 keeps the crosshair still (bullets still climb), 1 as tuned, up to 5.",
		func() -> Variant: return ArenaRecoilView.scale,
		func(v: Variant) -> Variant:
			ArenaRecoilView.scale = clampf(float(str(v).strip_edges()), 0.0, 5.0)
			return DotResult.success(ArenaRecoilView.scale)
	)
	local.add_var(&"cl_killcam_recoil", "How far the killer's recoil turns the killcam view: 0 holds it still, 1 as they saw it (default), up to 5.",
		func() -> Variant: return ArenaKillPovRecoil.scale,
		func(v: Variant) -> Variant:
			ArenaKillPovRecoil.scale = clampf(float(str(v).strip_edges()), 0.0, 5.0)
			return DotResult.success(ArenaKillPovRecoil.scale)
	)
	local.add_var(&"cl_weapon_sprites", "1 draws the held weapon as a flat sprite (view model and held), 0 the 3D models.",
		func() -> Variant: return 1 if ArenaWeaponIcons.shared.sprites else 0,
		func(v: Variant) -> Variant:
			ArenaWeaponIcons.shared.sprites = str(v).strip_edges() == "1"
			return DotResult.success(1 if ArenaWeaponIcons.shared.sprites else 0)
	)


## The remote-body thinning variables (ArenaPlayer.present_lod).
func _add_remote_vars(local: DotConsoleLocal) -> void:
	local.add_var(&"cl_remote_lod", "1 draws remote players nobody can see (off screen, far away) less often; 0 presents every remote player every frame.",
		func() -> Variant: return 1 if ArenaPlayer.present_lod_enabled else 0,
		func(v: Variant) -> Variant:
			ArenaPlayer.present_lod_enabled = str(v).strip_edges() != "0"
			return DotResult.success(1 if ArenaPlayer.present_lod_enabled else 0)
	)
	local.add_var(&"cl_remote_lod_frustum", "1 judges a remote player out of sight by the camera's real view frustum, 0 by a wide cone round the view axis.",
		func() -> Variant: return 1 if ArenaPlayer.lod_frustum else 0,
		func(v: Variant) -> Variant:
			ArenaPlayer.lod_frustum = str(v).strip_edges() != "0"
			return DotResult.success(1 if ArenaPlayer.lod_frustum else 0)
	)
	local.add_var(&"cl_remote_anim_gate", "1 also thins remote bodies by game time (clip at most 60 Hz past 15 m, off-sight at most 30 Hz); matters above ~100 fps.",
		func() -> Variant: return 1 if ArenaPlayer.anim_gate_enabled else 0,
		func(v: Variant) -> Variant:
			ArenaPlayer.anim_gate_enabled = str(v).strip_edges() != "0"
			return DotResult.success(1 if ArenaPlayer.anim_gate_enabled else 0)
	)
	local.add_var(&"cl_remote_lod_every", "Frames between updates of a remote player out of sight (1 to 16; 4 is the default).",
		func() -> Variant: return ArenaPlayer.lod_off_every,
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_int():
				return DotResult.fail(DotError.CODE_INVALID, "cl_remote_lod_every takes a whole number of frames")
			ArenaPlayer.lod_off_every = clampi(text.to_int(), 1, 16)
			return DotResult.success(ArenaPlayer.lod_off_every)
	)


## The first-person arm tuning variables.
func _add_arm_vars(local: DotConsoleLocal):
	local.add_var(&"cl_fp_hand_scale", "Multiplier on the first-person hand size of every weapon (1: as the weapon's profile says).",
		func() -> Variant: return ArenaViewArms.hand_scale_mult,
		func(v: Variant) -> Variant:
			ArenaViewArms.hand_scale_mult = clampf(str(v).to_float(), 0.1, 3.0)
			return DotResult.success(ArenaViewArms.hand_scale_mult)
	)
	local.add_var(&"cl_fp_forearm_scale", "Multiplier on the first-person forearm size of every weapon (1: as the weapon's profile says).",
		func() -> Variant: return ArenaViewArms.forearm_scale_mult,
		func(v: Variant) -> Variant:
			ArenaViewArms.forearm_scale_mult = clampf(str(v).to_float(), 0.2, 3.0)
			return DotResult.success(ArenaViewArms.forearm_scale_mult)
	)
	local.add_var(&"cl_fp_scope_arms_hide", "Aim fraction (0 to 1) at which a scoped weapon's first-person arms hide (-1: each weapon's own, 0.6 by default).",
		func() -> Variant: return ArenaViewArms.scope_arms_hide_override,
		func(v: Variant) -> Variant:
			ArenaViewArms.scope_arms_hide_override = clampf(str(v).to_float(), -1.0, 1.0)
			return DotResult.success(ArenaViewArms.scope_arms_hide_override)
	)
	ArenaScopePrefs.bind_cvars(local)
	local.add_var(&"cl_fp_max_lean", "Most the first-person arms lean toward a hand out of reach (-1: each weapon's own, 0.4 by default; 0 is no lean).",
		func() -> Variant: return ArenaViewArms.max_lean_override,
		func(v: Variant) -> Variant:
			ArenaViewArms.max_lean_override = clampf(str(v).to_float(), -1.0, 3.0)
			return DotResult.success(ArenaViewArms.max_lean_override)
	)
	local.add_var(&"cl_fp_look_down_back", "Metres your own body trails back as the view tips fully down (-1: the player's own setting, 0.45 by default).",
		func() -> Variant: return ArenaPlayer.look_down_back_override,
		func(v: Variant) -> Variant:
			ArenaPlayer.look_down_back_override = clampf(str(v).to_float(), -1.0, 2.0)
			return DotResult.success(ArenaPlayer.look_down_back_override)
	)


## Once a frame, with where the camera is and which way it is looking.
func present(delta: float, eye: Vector3, forward: Vector3) -> void:
	audio.listener_position = eye
	fx.viewer_position = eye
	fx.viewer_forward = forward
	fx.advance(delta)
	blood.advance(delta)


## The camera offset to add this frame, which the rig applies and this does not. dot-spectate's
## rule: it computes a transform and touches no camera. One implementation then serves the play rig,
## a spectator's, and a headless suite with no camera at all.
func camera_shake() -> Vector3:
	return fx.shake.offset()


func camera_roll() -> float:
	return fx.shake.roll()


## Whether something on screen owns the keyboard right now. Movement must not read while somebody
## types (the chat box is the same bug as a console, for everybody).
func swallows_input() -> bool:
	if console != null and console.is_open():
		return true
	if console_panel != null and console_panel.has_keyboard_focus():
		return true

	return chat_window != null and chat_window.is_open()


## A transform at [param at] whose -Z points along [param direction]. What every effect scene here
## is built against: a muzzle flash sprays along -Z, a spark flies back up +Z toward whoever fired,
## and the bullet hole's decal projects along -Z.
static func facing(at: Vector3, direction: Vector3) -> Transform3D:
	var forward := direction.normalized() if direction.length_squared() > 0.0 else Vector3.FORWARD
	# Straight up or down has no yaw to keep; any other up vector will do. 4.7's
	# `looking_at` copes with a parallel one too, with an engine WARNING per shot.
	var up := Vector3.RIGHT if absf(forward.dot(Vector3.UP)) > 0.99 else Vector3.UP
	return Transform3D(Basis.looking_at(forward, up), at)


## One tick of the local player's weapon use: a flash per shot, a spark and a hole per impact, and
## the hit marker. [b]The flash is pushed out in front of the eye.[/b] A shot starts at the view,
## and a flash drawn there is drawn around the camera.
func on_used(outcome: DotWeaponOutcome, weapon_draws: bool = false) -> void:
	if outcome == null or not outcome.used:
		return

	for shot in outcome.shots:
		if not weapon_draws:
			var aim := facing(shot.origin, shot.direction)
			var muzzle := aim.translated_local(MUZZLE_OFFSET)
			# The weapon's id rather than a slot number. A slot is where a player put
			# something; an id is what it is, and a sound catalogue keyed on a slot would
			# play the rifle whenever anybody put a shotgun in slot one.
			var weapon_id: StringName = shot.weapon_id if shot.weapon_id != &"" else &"rifle"
			on_fired(weapon_id, muzzle, true)

		# Impacts are a list because a shotgun is one shot with several of them, and one impact sound for eight pellets sounds like a rifle. Each faces along the aim, not along its own pellet (the pellet directions are not kept per impact).
		# [b]With the weapon drawing its own shot, only the hole is this layer's:[/b] fc-weapons' `AwShotFx` draws the flash, tracer, spark and report.
		# An impact on a sky brush is open sky to the player: no hole, spark or sound (cp-orange-x3's specks in the clouds). Hit results are untouched.
		var space := _space()
		for at in shot.impacts:
			if ArenaBspMap.on_sky(space, at, shot.direction):
				continue
			if weapon_draws:
				ArenaHoleSizes.fit(fx.spawn_decal(&"bullet_hole", facing(at, shot.direction)), shot.weapon_id)
			else:
				on_impact(facing(at, shot.direction), false, shot.weapon_id)

		fx.spawn_penetration_decals(shot.penetrations)
		fx.spawn_ricochet_decals(shot.ricochets)

		# No hit marker here. `shot.damages` is this client's PREDICTION of what its shot
		# did, and the server may refuse it (a lag-compensated miss, a protected spawn);
		# the marker and its sound wait for the server's HIT ([method on_hit_confirmed]).


## The physics this presentation's world answers queries from, or null outside the tree.
func _space() -> PhysicsDirectSpaceState3D:
	if not is_inside_tree():
		return null
	var world := get_viewport().find_world_3d()
	return world.direct_space_state if world != null else null


func on_fired(weapon_id: StringName, muzzle: Transform3D, mine: bool) -> void:
	var layered := shots != null and SHOT_CLASS.has(weapon_id) and shots.fire(StringName("shot_%s" % SHOT_CLASS[weapon_id]), muzzle.origin).ok
	if not layered:
		audio.play_at(StringName("fire_%s" % weapon_id), muzzle.origin)
	fx.spawn(&"muzzle_flash", muzzle)
	if mine:
		# Only your own weapon kicks the camera. Somebody else's rifle going off beside
		# you is a sound and a flash; shaking for it would make a crowded room unplayable.
		fx.shake.add(0.08)


## A rocket or a grenade went off at [param at]; [param eye] is where this client's
## camera is, for how hard it shakes. Everybody's, the local player's own included.
func on_explosion(at: Vector3, eye: Vector3) -> void:
	audio.play_at(EXPLOSION, at)
	fx.spawn(EXPLOSION, Transform3D(Basis.IDENTITY, at))

	var near := 1.0 - clampf(eye.distance_to(at) / EXPLOSION_SHAKE_RANGE, 0.0, 1.0)
	if near > 0.0:
		fx.shake.add(EXPLOSION_SHAKE * near * near)


func on_impact(at: Transform3D, on_player: bool, weapon_id: StringName = &"") -> void:
	# Checked decal first: a miss's endpoint is open air, and a spark there floats too.
	if not on_player:
		var hole := fx.spawn_decal(&"bullet_hole", at)
		if hole == null:
			return
		ArenaHoleSizes.fit(hole, weapon_id)
	audio.play_at(&"impact", at.origin)
	fx.spawn(&"impact_spark", at)


## A map-vote cue from the server. Empty is silence, and an id this catalogue does not
## have is dot-audio's silent refusal rather than an error: a server configured with a
## sound set this client was not built with should cost a noise, not a log line per second.
func on_vote_cue(id: StringName) -> int:
	if id == &"" or audio == null:
		return 0

	return audio.play(id)


## The server confirmed a hit: the tick, or the heavier kill sound when it was lethal.
func on_hit_confirmed(lethal: bool = false) -> void:
	if audio == null:
		return
	var _v := audio.play(KILL_CONFIRMED if lethal else &"hit_marker")


## The server confirmed a hit on [param victim]: blood on the surface behind it, seen from [param eye].
func on_body_hit(victim: int, point: Vector3, eye: Vector3) -> void:
	var _splat := blood.on_body_hit(victim, point, eye)


## A kill's medals, each its own sound, staggered as the HUD staggers their popups.
func on_medals(medals: Array) -> void:
	if audio == null:
		return
	for i in range(medals.size()):
		var id := ArenaAwards.medal_sound(int(medals[i]))
		if i == 0 or not is_inside_tree():
			var _v := audio.play(id)
		else:
			get_tree().create_timer(MEDAL_STAGGER_SEC * float(i)).timeout.connect(
				func() -> void: if audio != null: audio.play(id)
			)


## A head stomp at [param at]: the configured sound and effect, heard and seen by everybody.
func on_stomp(at: Vector3, sound: StringName, effect: StringName) -> void:
	if audio != null and sound != &"":
		var _v := audio.play_at(sound, at)
	if fx != null and effect != &"":
		fx.spawn(effect, Transform3D(Basis.IDENTITY, at))


## A utility grenade's effect: a cloud or a fire, or a blind for the followed player (through dot-fx, so the flash settings cap it).
func on_grenade_fx(info: Dictionary, own_id: int) -> void:
	var _shown := AwGrenadeFx.show(fx, get_tree(), info, own_id)


## A flag changed hands: a different cue for what I did (took, dropped), what happened to my team's flag, and the rest.
func on_flag_event(what: StringName, flag_team: int, by_me: bool, my_team: int) -> void:
	if audio == null:
		return
	var mine := flag_team == my_team
	var id := &""
	match what:
		&"taken":
			id = &"flag_taken_by_me" if by_me else (&"flag_lost" if mine else &"flag_taken")
		&"dropped":
			id = &"flag_lost_back" if by_me else &"flag_dropped"
		&"returned":
			id = &"flag_returned"
		&"captured":
			id = &"flag_captured"
	if id != &"":
		var _v := audio.play(id)


## The grunt scales with the damage (a graze is quieter and higher than a heavy hit) and is left to
## the death cry when the damage was lethal, so the two do not stack into one muddy noise.
func on_hurt(amount: float, lethal: bool = false) -> void:
	var _grunt := DotHurtSound.play(audio, &"hurt", amount, lethal)
	fx.flash(&"hurt_flash")
	fx.spawn(&"hurt_shake", Transform3D.IDENTITY)


const DEATH_BURST_AHEAD := 1.5


func on_died(where: Transform3D) -> void:
	audio.play(&"died")
	# Read at the moment of the death, so the setting needs no apply step. Only the blood is
	# gated: bullet holes are not gore.
	if settings.get_bool(&"gore", true):
		# The origin is the dying player's own feet under their own camera: the drops would hang in the lens as red balls.
		var ahead := Vector3(fx.viewer_forward.x, 0.0, fx.viewer_forward.z)
		if ahead.length_squared() > 0.0001:
			where.origin += ahead.normalized() * DEATH_BURST_AHEAD
		fx.spawn(&"death_burst", where)
	fx.spawn(&"death_shake", Transform3D.IDENTITY)


func on_spawned() -> void:
	audio.play(&"spawned")
	# Everything from the previous life goes. A decal ring that survives a death is one
	# that survives a map change, which is a hole in a wall that no longer exists.
	fx.shake.reset()


## A beacon's ripple went out from [param at]. `ArenaPlayer.beacon_pulsed`, on every
## client, for every beaconed player — the beaconed one included, who hears their own.
func on_beacon(at: Vector3) -> int:
	if audio == null:
		return 0

	return audio.play_at(BEACON_SOUND, at)


func on_pickup(at: Vector3) -> void:
	audio.play_at(&"pickup", at)


## The local player started or ended a wall run (`DotFpsController.wall_run_changed`,
## never emitted during a replay). Only the start makes a noise; returns the voice, 0 for
## none.
func on_wall_run(running: bool) -> int:
	if audio == null or not running:
		return 0
	return audio.play(WALL_RUN_SOUND)


## The local player jumped off a wall (`DotFpsController.wall_jumped`).
func on_wall_jumped() -> int:
	if audio == null:
		return 0
	return audio.play(WALL_JUMP_SOUND)


## A map changed. Everything drawn for the old one is meaningless now.
func on_map_changed(map_id: StringName = &"") -> void:
	fx.clear()
	blood.clear()
	if ambient != null and ambient.has_moods():
		ambient.on_map(map_id)
	elif ambience != null:
		ambience.set_map_bed(bed_for(map_id))


## Moods by map name prefix (see [method bed_for]); anything else is a hall of machinery.
const AMBIENT_PREFIXES := {
	"surf_": &"snow_wind", "kz_": &"cave_tunnel", "climb_": &"cave_tunnel", "xc_": &"cave_tunnel",
	"bhop_": &"outdoor_night", "bunnyhop": &"outdoor_night",
}


## A map's bed, from its name: the built-in arenas are halls of machinery, a surf map is ramps
## in the air (wind), a climb map is rock (a cave), a hop map is outdoors. By prefix, because
## imported maps arrive by the hundred and nobody will list them.
static func bed_for(map_id: StringName) -> StringName:
	var id := String(map_id).to_lower()
	if id.begins_with("surf_"):
		return &"amb_wind"
	if id.begins_with("kz_") or id.begins_with("climb_") or id.begins_with("xc_"):
		return &"amb_cave"
	if id.begins_with("bhop_") or id.begins_with("bunnyhop"):
		return &"amb_outdoor"
	return &"amb_industrial"


## Everybody on the map steps, once a frame: players and bots, each grounded by a ray (a
## mirrored player's controller is never ticked here, so its own answer is stale).
func keep_walkers(bodies: Array) -> void:
	if steps != null:
		steps.keep(bodies)


## Which stock shot (dot-audio `DotAudioShotStock`) each weapon plays; a weapon not listed keeps its single `fire_*` sound.
const SHOT_CLASS := {&"rifle": &"rifle", &"shotgun": &"shotgun", &"rail": &"sniper"}


## The layered shot player and the enclosure probe it reads (dot-audio); `use_shot_rules` hands both the server's cvars.
var shots: DotShotPlayer = null
var shot_enclosure: DotAudioEnclosure = null


func use_shot_rules(rules: DotShotRules) -> void:
	if shots != null:
		shots.rules = rules
	if shot_enclosure != null:
		shot_enclosure.rules = rules


## The report of somebody else's gun (`AwShotFx.shot_sound`) through this presentation's one layered player.
## Without it each shooter's `AwShotFx` made its own audio manager, enclosure and shot player on its first shot:
## 40 ms a shooter, thirty-one times a match at 16 v 16. False for a class with no stock shot (the single sound plays).
func remote_shot(id: StringName, kind: StringName, at: Vector3, _indoors: bool) -> bool:
	var t_shot := Time.get_ticks_usec()
	var done := _remote_shot(id, kind, at)
	ArenaFrameProbe.add(&"fx_remote_shot", t_shot)
	return done


func _remote_shot(id: StringName, kind: StringName, at: Vector3) -> bool:
	if shots == null or audio == null:
		return false
	var weapon_class := AwWeaponSound.class_for(id, kind)
	var stock_class := AwShotLayers.shot_class(weapon_class)
	if stock_class == &"":
		return false
	var res := shots.fire(DotAudioShotStock.id_of(stock_class), at, weapon_class == AwWeaponSound.SUPPRESSED)
	return res.ok and int(res.value_or(0)) > 0


## Hands a world model's shot effects (made on its hand's first shot) this presentation's player for the report.
func share_shots(hand: Node) -> void:
	if hand == null or hand.child_entered_tree.is_connected(_share_shots_with):
		return
	hand.child_entered_tree.connect(_share_shots_with)


func _share_shots_with(child: Node) -> void:
	if child is AwShotFx:
		(child as AwShotFx).shot_sound = remote_shot
		(child as AwShotFx).layered_shots = false


## The roof probe the weapon's shot sounds read (`AwShotFx.roof`): roofed means a room tail follows a shot.
var shot_roof := DotAmbienceRoof.new()


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("the arena's presentation layer")
	out.append_array(settings.describe_lines())
	out.append_array(audio.describe_lines())
	if ambient != null:
		out.append("ambience: %s" % str(ambient.describe()))
	out.append_array(fx.describe_lines())
	out.append_array(console.describe_lines())

	if chat_window != null:
		out.append("chat box: %s" % str(chat_window.describe()))

	return out
