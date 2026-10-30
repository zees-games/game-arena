extends SceneTree

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaWeaponIcons := preload("../game/arena_weapon_icons.gd")
const ArenaSpriteWeapon := preload("../game/arena_sprite_weapon.gd")
const ArenaAwards := preload("../game/arena_awards.gd")
const ArenaViewArms := preload("../game/arena_view_arms.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaDrops := preload("../game/arena_drops.gd")
const ArenaJailView := preload("../game/arena_jail_view.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

## The `--admin`, `--feel`, `--fx` and `--action` stagings of tools/screenshot.gd, kept apart for the file-size budget.

var _shots: Array[Dictionary] = []
var _index := 0
var _camera: Camera3D = null

## `--admin`'s cast: drawn every frame by their own `present`, as a client draws them.
var _players: Array[ArenaPlayer] = []
var _local: ArenaPlayer = null
var _hud: ArenaHud = null

var _action_figure: DotHumanoidFigure = null
var _toy_box: DotPropToyBox = null
var _toy_placements: Array = []


# --- --admin ----------------------------------------------------------------

## Players in the map, and the frames that show an administrator's beacon and blind.
##
## Written against `dm_box`'s layout — open floor at the south end, a five-metre pillar
## at (-12, -4) — and still renders on another map, where the pillar frame may simply not
## have a pillar in it.
func _stage_admin(map: ArenaMap, id: StringName) -> void:
	# Beaconed, on open floor, with a player who is not beside them for contrast.
	var marked := _cast(map, 101, "Marked", Vector3(1.0, 0.05, 11.0), 200.0)
	var plain := _cast(map, 102, "Plain", Vector3(4.2, 0.05, 12.5), 160.0)
	marked.beacon = true
	# Behind the pillar from where the second frame stands.
	var hidden := _cast(map, 103, "Hidden", Vector3(-12.0, 0.05, -9.0), 0.0)
	hidden.beacon = true

	# Whose eyes the last two frames are behind, looking north at the other two.
	_local = ArenaPlayer.new()
	_local.name = "Local"
	_local.setup(ArenaPlayer.Mode.HEADLESS, map, 104, "You")
	root.add_child(_local)
	_local.spawn(Transform3D(Basis(), Vector3(-1.0, 0.05, 20.0)), 0)
	_local.attach_camera(100.0)
	_local.camera.current = false
	_players.append(_local)

	_hud = ArenaHud.new()
	_hud.name = "Hud"
	_hud.config = DotUiConfig.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_hud)
	_hud.build(null)
	_hud.follow(_local)
	_hud.visible = false

	var _unused := plain

	_shots = [
		{
			"name": "%s_beacon" % String(id),
			"from": Vector3(-4.5, 3.4, 18.5),
			"at": Vector3(2.0, 0.6, 11.5),
		},
		{
			# Eye level, the pillar between the camera and the player: the body is hidden
			# and the column is not, which is the reason it is drawn through walls.
			"name": "%s_beacon_wall" % String(id),
			"from": Vector3(-11.0, 1.7, 9.0),
			"at": Vector3(-12.0, 4.0, -9.0),
		},
		{
			"name": "%s_eye_hud" % String(id),
			"local": true,
			"arm": func() -> void: _hud.visible = true,
		},
		{
			"name": "%s_blind" % String(id),
			"local": true,
			"arm": func() -> void: _local.blinded = true,
			# The HUD fades a blind in over a quarter of a second; software rendering is
			# slow enough that three frames can be less than that.
			"wait": 12,
		},
	]


# --- --feel -----------------------------------------------------------------

## What the arena's 2026-10-06 additions look like, which no suite can say: the sniper's
## scope, the HUD (hurt, the launch counting down, the slide prompt), a body exploding on a
## lethal critical, and your own body when you look down.
var _feel_tick: int = 1


func _stage_feel(map: ArenaMap, id: StringName) -> void:
	var victim := _cast(map, 111, "Victim", Vector3(1.0, 0.05, 12.0), 180.0)
	var hurt := _cast(map, 113, "Hurt", Vector3(4.0, 0.05, 13.0), 200.0)

	_local = ArenaPlayer.new()
	_local.name = "Local"
	_local.setup(ArenaPlayer.Mode.HEADLESS, map, 112, "You")
	root.add_child(_local)
	_local.spawn(Transform3D(Basis(), Vector3(-1.0, 0.05, 20.0)), 0)
	_local.attach_camera(100.0)
	_local.camera.current = false
	# Where the arena's vendored weapon art is; the client says so at boot, and without it
	# the hands are drawn holding nothing.
	ZeeModelCache.set_asset_root("res://")
	_players.append(_local)

	# The hands are armed on the first frame, not here: this runs in the script's _init,
	# before anything is in the tree, so the rig's `get_path()` of the hands failed ("Cannot
	# get path of node") and every frame showed empty hands.
	var arm_hands := func() -> void:
		# A second set of hands from an earlier frame would draw its weapon too.
		var old_hands := _local.get_node_or_null(^"Camera/Hands")
		if old_hands != null:
			old_hands.get_parent().remove_child(old_hands)
			old_hands.free()
		var hands := ZeeViewModel.new()
		hands.name = "Hands"
		_local.camera.add_child(hands)
		var old_arms := root.get_node_or_null(^"ViewArms")
		if old_arms != null:
			old_arms.free()
		ArenaViewArms.mount(root, hands, _local, ArenaAvatars.look_of(_local.avatar, &"arena-player-00000001"))
		_local.arm_first_person(hands, true)
		var _given := _local.weapons.give_everything()

	_hud = ArenaHud.new()
	_hud.name = "Hud"
	_hud.config = DotUiConfig.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_hud)
	_hud.build(null)
	_hud.follow(_local)
	_hud.visible = false

	var hold := func(slot: int) -> void:
		# Asked for through the command, as the client does, and ticked the way the game
		# ticks a player: the rig equips the view model on a tick and nothing else here
		# ticks it.
		var ask := DotWeaponCommand.new()
		ask.slot = slot
		for tick in range(_feel_tick, _feel_tick + 80):
			var _o := _local.simulate_tick(tick, 1.0 / 64.0, DotFpsCommand.new(), ask)
			ask = DotWeaponCommand.new()
		_feel_tick += 80

	var shots_view := _feel_shots_view(id, victim, hurt, arm_hands, hold)
	_shots = shots_view
	_shots.append_array(_feel_shots_world(id, victim, hurt, arm_hands, hold))
	if OS.get_cmdline_user_args().has("--muzzle"):
		_stage_muzzle(id, arm_hands, hold)


## The first-person frames of `--feel`: sniper at the hip, scope, HUD and kill feedback.
func _feel_shots_view(id: StringName, victim: ArenaPlayer, hurt: ArenaPlayer, arm_hands: Callable, hold: Callable) -> Array[Dictionary]:
	return [
		{
			# The sniper at the hip: its view model against the vendored art.
			"name": "%s_feel_sniper_hip" % String(id),
			"local": true,
			"arm": func() -> void:
				arm_hands.call()
				var _g := _local.arsenal.give(ZeeWeaponIds.SNIPER)
				hold.call(ZeeWeaponIds.SLOT_HEAVY),
			"wait": 30,
		},
		{
			"name": "%s_feel_scope" % String(id),
			"local": true,
			"arm": func() -> void:
				arm_hands.call()
				# The sniper itself: give_everything leaves the heavy slot holding the last
				# heavy it gave, which is not the sniper.
				var _g := _local.arsenal.give(ZeeWeaponIds.SNIPER)
				hold.call(ZeeWeaponIds.SLOT_HEAVY)
				_local.aim_held = true
				_hud.visible = true,
			"wait": 30,
		},
		{
			"name": "%s_feel_hud" % String(id),
			"local": true,
			"arm": func() -> void:
				_local.aim_held = false
				hold.call(ZeeWeaponIds.SLOT_PRIMARY)
				_local.health.health = _local.health.max_health * 0.12
				_local.controller.state.launch_cooldown_left = 5.5
				_local.controller.state.slide_time = 0.3
				for v in [201, 202, 203]:
					_hud.note_kill({"killer_id": 112, "victim_id": v, "headshot": v == 203, "weapon": "rifle"}, 112, "You")
				_hud.notice("Victim is on a 3 kill streak: heal")
				_local.challenge = 1
				_local.challenge_value = 11,
			"wait": 30,
		},
		{
			# Kill feedback: medals from the server's AWARD, "+points  Victim", the streak
			# meter, and, staged late so they are still up, the hit marker and the numbers.
			"name": "%s_feel_kill" % String(id),
			"local": true,
			"arm": func() -> void:
				_local.health.health = _local.health.max_health
				_local.controller.state.launch_cooldown_left = 0.0
				_local.controller.state.slide_time = -1.0
				_hud.notice("")
				_local.challenge = -1,
			"late": [
				[12, func() -> void:
					var medals := [ArenaAwards.Medal.FIRST_BLOOD, ArenaAwards.Medal.HEADSHOT, ArenaAwards.Medal.DOUBLE_KILL]
					_hud.note_kill({"killer_id": 112, "victim_id": 111, "headshot": true, "weapon": "rifle"}, 112, "You")
					_hud.note_award(
						{"killer_id": 112, "victim_id": 111, "medals": medals,
							"points": ArenaAwards.points_for(medals), "streak": 4},
						112, "Victim", "You"
					)],
				[4, func() -> void:
					_hud.note_hit(113, 47.0, hurt.global_position + Vector3(0.0, 1.5, 0.0), false, false)
					_hud.note_hit(111, 100.0, victim.global_position + Vector3(0.0, 1.7, 0.0), true, true)],
			],
			"wait": 34,
		},
	]


## The world frames of `--feel`: a broken body, the health bar, drops and your own body.
func _feel_shots_world(id: StringName, victim: ArenaPlayer, hurt: ArenaPlayer, arm_hands: Callable, hold: Callable) -> Array[Dictionary]:
	return [
		{
			"name": "%s_feel_break" % String(id),
			# From the east: the west side of this floor is the stair block, which hid
			# all but a flying head in the first two renders.
			"from": Vector3(6.5, 2.6, 16.5),
			"at": Vector3(1.0, 0.9, 12.0),
			"arm": func() -> void:
				_hud.visible = false
				var rules := DotPlayerBreakRules.new()
				rules.mode = DotPlayerBreakRules.Mode.EXPLODE
				rules.criticals_only = false
				# Slowed, so the frame is mid-burst rather than after it.
				rules.force = 2.5
				rules.lift = 2.0
				victim.make_dead()
				var _b := victim.break_body(rules, Vector3(0.0, 0.0, -1.0), 7, true),
			"wait": 8,
		},
		{
			"name": "%s_feel_health" % String(id),
			"from": Vector3(4.0, 2.4, 18.5),
			"at": Vector3(4.0, 1.6, 13.0),
			"arm": func() -> void:
				hurt.health.health = 40.0,
			"wait": 6,
		},
		{
			"name": "%s_feel_drops" % String(id),
			"from": Vector3(3.5, 2.4, 19.0),
			"at": Vector3(0.0, 0.3, 14.5),
			"arm": func() -> void:
				var drops := ArenaDrops.new()
				drops.is_authority = false
				drops.draws = true
				root.add_child(drops)
				var from := Vector3(0.0, 0.05, 14.5)
				for i in range(5):
					var a := TAU * float(i) / 5.0
					drops.mirror_drop(i + 1, ArenaDrops.Kind.COIN, from + Vector3(cos(a) * 1.6, 0.0, sin(a) * 1.6), from, 1)
				drops.mirror_drop(9, ArenaDrops.Kind.HEALTH, from + Vector3(0.0, 0.0, 0.3), from, 25),
			"wait": 40,
		},
		{
			"name": "%s_feel_body" % String(id),
			"local": true,
			"arm": func() -> void:
				_local.controller.state.slide_time = -1.0
				# Through teleport, which sets the drawn state too: the camera draws from the
				# controller's interpolated render state, and a pitch written into `state`
				# alone never reached it (the first two body frames looked at the horizon).
				_local.controller.teleport(_local.controller.state.position, _local.controller.state.yaw, -62.0)
				# And the sampler, which owns a local player's look and writes it every tick.
				if _local.get("sampler") != null:
					_local.sampler.look_at_angles(_local.controller.state.yaw, -62.0)
				_local.health.health = _local.health.max_health
				# A real avatar: a player with none is drawn as a capsule, which has no legs to keep.
				_local.avatar = load("res://game/arena_avatars.gd").stock_avatar(&"you")
				# Current first: present_own_body draws nothing for a camera nobody looks through.
				_local.camera.current = true
				_local.present_own_body(1, _local.controller.state.yaw)
				_hud.visible = true,
			"wait": 12,
		},
	]


## `--feel --muzzle`: only the muzzle flash, first-person, one frame per weapon, grabbed two frames after the trigger (a flash lives about 0.1 s).
func _stage_muzzle(id: StringName, arm_hands: Callable, hold: Callable) -> void:
	_shots = []
	var picks: Array = [[ZeeWeaponIds.PISTOL, ZeeWeaponIds.SLOT_SIDEARM], [ZeeWeaponIds.RIFLE, ZeeWeaponIds.SLOT_PRIMARY],
			[ZeeWeaponIds.SHOTGUN, ZeeWeaponIds.SLOT_PRIMARY], [ZeeWeaponIds.SNIPER, ZeeWeaponIds.SLOT_HEAVY]]
	# `--weapons=smg:3,knife:1` (id:slot) replaces the default four with any weapon in any slot.
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--weapons="):
			picks = []
			for pair: String in arg.trim_prefix("--weapons=").split(",", false):
				var parts := pair.split(":")
				picks.append([StringName(parts[0]), int(parts[1]) if parts.size() > 1 else ZeeWeaponIds.SLOT_PRIMARY])
	for pick: Array in picks:
		var weapon: StringName = pick[0]
		var slot: int = pick[1]
		_shots.append({
			"name": "%s_muzzle_%s" % [String(id), String(weapon)],
			"local": true,
			"arm": func() -> void:
				arm_hands.call()
				var _g := _local.arsenal.give(weapon)
				hold.call(slot),
			"late": [[2, func() -> void:
				var fire := DotWeaponCommand.new()
				fire.buttons = DotWeaponCommand.BUTTON_ATTACK
				var _o := _local.simulate_tick(_feel_tick, 1.0 / 64.0, DotFpsCommand.new(), fire)
				_feel_tick += 1]],
			"wait": 6,
		})


# --- --fx -------------------------------------------------------------------

## A death at [param at], its two emitters (drops and mist) slowed so a frame catches the burst.
func _fx_death(presentation: ArenaPresentation, at: Vector3, eye: Vector3, aim: Vector3, step_first: bool) -> void:
	if step_first:
		presentation.present(0.016, eye, aim)
	presentation.on_died(Transform3D(Basis.IDENTITY, at))
	for particles in presentation.fx.find_children("*", "CPUParticles3D", true, false):
		if particles.name in [&"Drops", &"Mist"]:
			(particles as CPUParticles3D).speed_scale = 0.2
			(particles as CPUParticles3D).restart()


## The re-firable volley of `--fx`: six shots from [param eye] along [param aim], slowed so a frame catches them.
func _fx_fire(presentation: ArenaPresentation, trace: DotTraceFlat, eye: Vector3, aim: Vector3, side: Vector3) -> Callable:
	var refused := {}
	presentation.fx.spawned.connect(func(fx_id: StringName, node: Node, why: StringName) -> void:
		if node == null:
			refused["%s: %s" % [fx_id, why]] = true
	)
	var fire := func() -> void:
		# A small group, the last one freshest: holes from the earlier shots, the spark
		# and the flash from the last. One shot per frame's budget, as a client fires one
		# a tick: six in one frame is over dot-fx's budget and the last are refused.
		for i in range(6):
			presentation.present(0.016, eye, aim)
			var angle := float(i) * 1.1
			var spread := side * sin(angle) * 0.012 * i + Vector3.UP * cos(angle) * 0.012 * i
			var dir := (aim + spread).normalized()
			var hit := trace.ray(eye, dir, 500.0)
			var shot := DotShot.new()
			shot.weapon_id = &"rifle"
			shot.origin = eye
			shot.direction = dir
			if hit.ok():
				shot.impacts = [hit.point]
				if i == 0:
					print("fx: the first shot stopped at %s, %.1f m away" % [hit.point, hit.distance])
			var outcome := DotWeaponOutcome.new()
			outcome.used = true
			outcome.add_shot(shot)
			presentation.on_used(outcome)
		for particles in presentation.fx.find_children("*", "CPUParticles3D", true, false):
			(particles as CPUParticles3D).speed_scale = 0.05
			# And started again at the slowed speed. A one-shot's first update ages it by
			# the whole frame's delta, and a software frame is longer than a flash lives,
			# so without this the flash has already finished when the slowing lands.
			(particles as CPUParticles3D).restart()
		if not refused.is_empty():
			print("fx: refused %s" % ", ".join(PackedStringArray(refused.keys())))
			refused.clear()
	return fire


## A burst of rifle shots at a wall, drawn by the real presentation layer the way a client
## draws its own: [method ArenaPresentation.on_used] with a [DotWeaponOutcome] whose
## impacts are where the map's own trace says each shot stopped.
##
## [b]The particles are slowed to a twentieth of real speed and restarted once spawned.[/b]
## A muzzle flash lives 80 ms and a software renderer under xvfb takes longer than that per
## frame, so at full speed the frame this saves is the one after it went out. The holes are
## decals and are not affected.
func _stage_fx(map: ArenaMap, id: StringName, eye: Vector3, aim_at: Vector3) -> void:
	var presentation := ArenaPresentation.new()
	presentation.name = "Presentation"
	root.add_child(presentation)
	var built := presentation.setup()
	if not built.ok:
		push_error("the presentation layer: %s" % built.error.message)

	if OS.get_cmdline_user_args().has("--nogore"):
		presentation.settings.set_value(&"gore", false)

	var trace := map.to_trace()
	var aim := (aim_at - eye).normalized()
	var side := aim.cross(Vector3.UP).normalized()
	var fire := _fx_fire(presentation, trace, eye, aim, side)

	var hit0 := trace.ray(eye, aim, 500.0)
	var wall := hit0.point if hit0.ok() else aim_at

	_shots = [
		{
			# Through the shooter's own eye: the flash low and right, the spark on the wall.
			"name": "%s_fx_eye" % String(id),
			"from": eye,
			"at": eye + aim,
			"arm": fire,
			"wait": 4,
		},
		{
			# Beside the wall, looking at the holes, re-fired so the spark is fresh again.
			"name": "%s_fx_wall" % String(id),
			"from": wall - aim * 2.2 + side * 1.2 + Vector3.UP * 0.3,
			"at": wall,
			"arm": fire,
			"wait": 4,
		},
		{
			# A death two metres short of the wall, seen from where the shots came from.
			"name": "%s_fx_death" % String(id),
			"from": eye + side * 1.5,
			"at": wall - aim * 2.0 + Vector3.UP * 0.5,
			"arm": func() -> void: _fx_death(presentation, Vector3(wall.x, map.floor_y, wall.z) - aim * 2.0, eye, aim, true),
			"wait": 4,
		},
		{
			# The same death from four metres, where a player who was nearby sees it: what the
			# burst looks like, not where it is.
			"name": "%s_fx_death_near" % String(id),
			"from": wall - aim * 6.0 + side * 1.5 + Vector3.UP * 0.4,
			"at": wall - aim * 2.0 + Vector3.UP * 1.0,
			"arm": func() -> void: _fx_death(presentation, Vector3(wall.x, map.floor_y, wall.z) - aim * 2.0, eye, aim, false),
			"wait": 6,
		},
		{
			# Blood behind bodies a hit confirmed, the way the HIT event draws it: a few chest
			# points spread across the wall, seen from the side a player would stand.
			"name": "%s_fx_blood" % String(id),
			"from": wall - aim * 3.5 + side * 1.0 + Vector3.UP * 0.4,
			"at": wall + Vector3.UP * 0.2,
			"arm": func() -> void:
				var victim := DotEntity.make_id(DotEntity.KIND_PLAYER, 2)
				for i in range(5):
					var chest := wall - aim * 1.0 + side * (float(i) - 2.0) * 0.45 + Vector3.UP * (-0.3 + 0.3 * float(i % 3))
					presentation.on_body_hit(victim, chest, eye)
				presentation.present(0.016, eye, aim)
				print("fx: %d splatters" % presentation.blood.decals.blood_count()),
			"wait": 4,
		},
	]
	_shots.append_array(_fx_grenade_shots(presentation, id, eye, aim, side))


## arena-weapons' smoke and fire clouds, then the blind flash, as the GRENADE_FX event draws them.
func _fx_grenade_shots(presentation: ArenaPresentation, id: StringName, eye: Vector3, aim: Vector3, side: Vector3) -> Array:
	var cloud_at := eye + aim * 5.0
	var cases := [
		["smoke", AwUtilityZones.Fx.SMOKE, cloud_at, 4.0, 1.0, 90],
		["fire", AwUtilityZones.Fx.FIRE, cloud_at + side * 3.0, 3.0, 1.0, 90],
		["blind", AwUtilityZones.Fx.BLIND, eye, 4.0, 0.6, 2],
	]
	var shots := []
	for c in cases:
		var info := {"fx": c[1], "position": c[2], "radius": c[3], "seconds": 30.0, "victim": 0, "strength": c[4]}
		shots.append({
			"name": "%s_fx_%s" % [String(id), c[0]],
			"from": eye,
			"at": eye + aim,
			"arm": func() -> void: presentation.on_grenade_fx(info, 0),
			"wait": c[5],
		})
	return shots


## `--action <kind> <id>` (`--action emote dance`, `--action pose sit`): a figure playing an avatar
## action from the front, early and later in the clip. The id goes through dot-user-avatar's own list.
func _stage_action(map: ArenaMap, id: StringName, kind: StringName, action: String) -> void:
	var body := _cast(map, 1, "Actor", Vector3(0.0, 1.3, 0.0), 0.0)
	_action_figure = body.figure
	var entry := DotAvatarActions.defaults().find(kind, action)
	var play := func() -> void:
		var ok: bool = body.figure != null and body.figure.play_action(StringName(action), bool(entry.get("loop", false)), 0.0)
		print("action %s/%s: figure=%s played=%s" % [kind, action, body.figure != null, ok])
	var from := Vector3(0.0, 2.7, -3.2)
	var at := Vector3(0.0, 2.2, 0.0)
	_shots = [
		{"name": "%s_action_%s_a" % [String(id), action], "from": from, "at": at, "arm": play, "wait": 12},
		{"name": "%s_action_%s_b" % [String(id), action], "from": from, "at": at, "wait": 30},
	]


func _cast(map: ArenaMap, pid: int, name_text: String, at: Vector3, yaw: float) -> ArenaPlayer:
	var body := ArenaPlayer.new()
	body.name = name_text
	body.setup(ArenaPlayer.Mode.HEADLESS, map, pid, name_text)
	root.add_child(body)
	body.spawn(Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), at), 0)
	body.attach_body_mesh(
		Color.from_hsv(fmod(float(pid) * 0.37, 1.0), 0.55, 0.85),
		ArenaAvatars.stock_avatar(StringName(ArenaGame.storage_key(pid)))
	)
	_players.append(body)
	return body
