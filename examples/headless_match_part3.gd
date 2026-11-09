extends "headless_match_part2.gd"

# --- Spectating ------------------------------------------------------------

func _test_spectating() -> void:
	_section("spectating")

	var game := ArenaGame.new()
	game.name = "SpectateGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch(50)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a spectating game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	_check(game.spectate != null, "every mode gets a spectate layer")
	# The operator's own-team-only camera (mp_forcecamera 1): this section is about it. The
	# default is anybody, with free roam on (`_test_free_roam`).
	_check(
		game.spectate_rules.set_cvar("mp_forcecamera", "1"),
		"mp_forcecamera 1 is read by the rules the manager uses"
	)

	for index in range(4):
		var _added := game.add_player(800 + index, "Watcher %d" % index)

	# Nobody respawns during this section: a dead player who comes back stops spectating, and the chain tested happens in the
	# seconds before that, so a short respawn delay would make every check measure "they respawned".
	game.match_node.rules.respawn_delay_sec = 120.0
	_go_live(game)

	var victim := 800
	var killer := _first_other_team(game, victim)
	_check(killer > 0, "somebody is on the other side", str(killer))

	_kill_through_combat(game, killer, victim)

	_check(
		game.spectate.is_spectating(str(victim)),
		"a dead player is watching something rather than lying on the floor"
	)

	var view := game.spectate.manager.view(str(victim))
	_check(
		view.mode == DotSpectatorView.Mode.DEATH_CAM,
		"starting with the death camera", DotSpectatorView.Mode.keys()[view.mode]
	)

	# The whole chain, and the hand-over at the end of it.
	for t in range(TICK_RATE * 5):
		game.tick({})

	_check(
		view.mode == DotSpectatorView.Mode.FIRST_PERSON
		or view.mode == DotSpectatorView.Mode.CHASE,
		"and ending on somebody alive rather than on their killer",
		DotSpectatorView.Mode.keys()[view.mode]
	)
	_check(view.target != "", "with a target", view.target)
	_check(
		game.team_of(int(view.target)) == game.team_of(victim),
		"on their own side, because this is a team mode and the server decides",
		"%d watching %s" % [victim, view.target]
	)

	var where := game.spectate.camera_for(str(victim))
	_check(
		where.origin.y > game.map.floor_y + 0.5,
		"and the camera is off the floor rather than where the body fell",
		"%.2f" % where.origin.y
	)

	var cycled := game.spectate.next_target(str(victim))
	_check(cycled.ok, "the view can be cycled", str(cycled.error))

	game.player_for(victim).spawn(game.map.spawns[0], game.current_tick())
	game.spectate.manager.on_spawn(str(victim))
	_check(
		not game.spectate.is_spectating(str(victim)),
		"and respawning stops it"
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()

func _test_free_roam_rest(game: ArenaGame, victim: int, rules: DotSpectatorRules) -> void:
	_check(
		not game.spectate.is_roaming(str(victim)),
		"a restricted camera moves a roamer back onto a player"
	)
	_check(not game.spectate.toggle_roam(str(victim)).ok, "and refuses the roam key")
	_check(rules.set_cvar("mp_freeroam_speed", "20"), "mp_freeroam_speed is read")
	_check(is_equal_approx(rules.roam_speed, 20.0), "and sets the speed", str(rules.roam_speed))

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()

## Three checks: what the director is told about players 901..903 when 900 respawns in [param game]'s free-for-all, and which
## of two sites it picks. One shares 900's roster side and stands 2 m from one site; the other two stand 12 m from the other.
func _ffa_spawn_scenario(game: ArenaGame, when: String) -> void:
	var stack := game.player_stack
	var respawner := 900
	var side := stack.teams.team_of(str(respawner))
	var sides := PackedStringArray()

	for index in range(4):
		sides.append("%d %s" % [900 + index, String(stack.teams.team_of(str(900 + index)))])

	var friend := 0
	for index in range(1, 4):
		if stack.teams.team_of(str(900 + index)) == side:
			friend = 900 + index
			break
	if friend == 0:
		friend = 901

	var enemies: Array[int] = []
	for index in range(1, 4):
		if 900 + index != friend:
			enemies.append(900 + index)

	var site_a := Vector3(-20.0, 0.0, 0.0)
	var site_b := Vector3(20.0, 0.0, 0.0)
	var friend_at := site_a + Vector3(2.0, 0.0, 0.0)
	_stand(game, respawner, Vector3(0.0, 0.0, 60.0))
	_stand(game, friend, friend_at)
	_stand(game, enemies[0], site_b + Vector3(0.0, 0.0, 12.0))
	_stand(game, enemies[1], site_b + Vector3(0.0, 0.0, -12.0))

	var told_enemies: Array = stack.spawns.enemies_fn.call(side)
	var told_friends: Array = stack.spawns.friends_fn.call(side)
	var missing := PackedStringArray()

	for id in [friend, enemies[0], enemies[1]]:
		if not told_enemies.has(game.player_for(id).controller.state.position):
			missing.append(str(id))

	_check(
		missing.is_empty(),
		"%s, every other player is an enemy to the director (%s)" % [when, ", ".join(sides)],
		"not enemies: %s" % ", ".join(missing)
	)

	_check(
		not told_friends.has(friend_at),
		"and nobody is a friend, %d on 900's roster side included" % friend,
		"friends: %s" % str(told_friends)
	)

	var saved_mode := stack.spawns.rules.mode
	# The default scatter strategy draws across the map; these checks score the map sites.
	stack.spawns.rules.strategy = "map"
	stack.spawns.rules.mode = DotSpawnRules.Mode.FURTHEST
	stack.spawns.clear_sites()
	stack.spawns.add_site(DotSpawnSite.point(&"beside_the_friend", site_a))
	stack.spawns.add_site(DotSpawnSite.point(&"twelve_from_enemies", site_b))

	var chosen := stack.choose_spawn(respawner)
	var picked := ""
	if chosen.ok:
		picked = String((chosen.value as DotSpawnChoice).site.id)

	stack.spawns.rules.mode = saved_mode
	stack.refresh_spawns()

	_check(
		picked == "twelve_from_enemies",
		"and furthest-from-enemies avoids the spawn 2 m from %d for one 12 m from two "
			% friend + "enemies",
		"picked '%s' %s" % [picked, "" if chosen.ok else str(chosen.error)]
	)

func _sight_scenario_rest(chosen: DotResult, picked: String) -> void:
	_check(
		picked == "behind_the_wall",
		"and of two sites as far from the enemy, the director picks the one it cannot see",
		"picked '%s' %s" % [picked, "" if chosen.ok else str(chosen.error)]
	)

## A wall hides a spawn from an enemy in a headless game, and the director prefers the hidden site.
func _spawn_sight_scenario(game: ArenaGame) -> void:
	var stack := game.player_stack
	var map := game.map
	var trace := map.shot_trace()
	var floor_y := map.floor_y
	var inside := func(at: Vector3) -> bool:
		for box: AABB in map.boxes:
			if box.grow(0.3).has_point(at + Vector3(0, 0.5, 0)) or box.grow(0.3).has_point(at + Vector3(0, 1.6, 0)):
				return true
		return false
	var clear := func(a: Vector3, b: Vector3) -> bool:
		var span := (b - a)
		var hit := trace.ray(a + Vector3(0, 1.6, 0), span.normalized(), span.length())
		return not hit.ok()

	# A wall: a tall box with standing room on both sides of it along x, and an open
	# site the same distance from the enemy on its own side.
	var enemy := Vector3.ZERO
	var hidden := Vector3.ZERO
	var open := Vector3.ZERO
	var found := false
	for box: AABB in map.boxes:
		if box.size.y < 3.0 or box.position.y > floor_y + 0.5 or minf(box.size.x, box.size.z) < 0.8:
			continue
		var z := box.get_center().z
		var a := Vector3(box.position.x - 2.0, floor_y, z)
		var b := Vector3(box.end.x + 2.0, floor_y, z)
		var reach := b.x - a.x
		for sign in [1.0, -1.0]:
			var c := a + Vector3(0, 0, sign * reach)
			if inside.call(a) or inside.call(b) or inside.call(c):
				continue
			if absf(a.x) > map.extent or absf(b.x) > map.extent or absf(c.z) > map.extent:
				continue
			if clear.call(a, b) or not clear.call(a, c):
				continue
			enemy = a
			hidden = b
			open = c
			found = true
			break
		if found:
			break

	if not _check(found, "%s has a wall with standing room either side of it" % String(map.id)):
		return

	_check(
		not stack._can_see_site(enemy, hidden) and stack._can_see_site(enemy, open),
		"headless, a wall hides a spawn from an enemy and open floor does not (%s / %s from %s)"
			% [str(hidden), str(open), str(enemy)]
	)

	# Everybody but the respawner and one enemy out of the way, far below the map, where
	# the trace's floor hides them from both sites.
	_stand(game, 901, enemy)
	_stand(game, 902, Vector3(0, -500, 0))
	_stand(game, 903, Vector3(0, -500, 0))
	_stand(game, 900, Vector3(0, -500, 0))
	var saved_mode := stack.spawns.rules.mode
	var saved_floor := stack.spawns.rules.minimum_enemy_distance
	stack.spawns.rules.strategy = "map"
	stack.spawns.rules.mode = DotSpawnRules.Mode.SAFEST
	stack.spawns.rules.minimum_enemy_distance = 0.0
	stack.spawns.clear_sites()
	# The open site first, so a tie would pick it: only the sight penalty separates them.
	stack.spawns.add_site(DotSpawnSite.point(&"open", open))
	stack.spawns.add_site(DotSpawnSite.point(&"behind_the_wall", hidden))
	var chosen := stack.choose_spawn(900)
	var picked := String((chosen.value as DotSpawnChoice).site.id) if chosen.ok else ""
	stack.spawns.rules.mode = saved_mode
	stack.spawns.rules.minimum_enemy_distance = saved_floor
	stack.refresh_spawns()

	_sight_scenario_rest(chosen, picked)

## The first mode in this game that needs tagged spawns, or null if there is none.
func _first_team_mode() -> ArenaMode:
	for id in ArenaModes.ids():
		var mode := ArenaModes.by_id(id)

		if mode != null and mode.is_team_mode():
			return mode

	return null

# --- Spawning in a free-for-all ---------------------------------------------

## In a free-for-all, every other player is an enemy to the spawn director.
func _test_ffa_spawn_sides() -> void:
	_section("free-for-all: nobody is a friend at a spawn")

	var game := ArenaGame.new()
	game.name = "FfaSpawnGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.free_for_all(50)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a free-for-all game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)

	for index in range(4):
		var _added := game.add_player(900 + index, "Loner %d" % index)

	game.match_node.rules.respawn_delay_sec = 120.0
	_go_live(game)
	_ffa_spawn_scenario(game, "from the start")

	# [b]The case the queue item was written about.[/b] A team mode's sides stay in the roster
	# across a change into a free-for-all.
	var team := _first_team_mode()
	var to_team := game.change_map(ArenaMap.dm_atrium(), team)
	var to_ffa := game.change_map(ArenaMap.dm_atrium(), ArenaMode.free_for_all(50))
	_check(
		to_team.ok and to_ffa.ok,
		"the game goes into a team mode and back into a free-for-all",
		"%s / %s" % [str(to_team.error), str(to_ffa.error)]
	)
	_ffa_spawn_scenario(game, "after a team mode")
	_spawn_sight_scenario(game)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()

# --- Objectives ------------------------------------------------------------

func _test_king_of_the_hill() -> void:
	_section("king of the hill")

	var game := ArenaGame.new()
	game.name = "KothGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.king_of_the_hill()
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a king-of-the-hill game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	_check(game.objectives != null, "and has objectives")
	_check(game.objectives.layout == &"koth", "the koth layout")

	var hill := game.objectives.manager.objective(&"hill") as DotObjectiveCapture
	var clock := game.objectives.manager.objective(&"koth_clock") as DotObjectiveHoldout
	_check(hill != null and clock != null, "a point and a clock")
	_check(clock.linked == hill, "and the clock reads the point's owner")

	var _a := game.add_player(900, "Red")
	var _b := game.add_player(901, "Blue")
	var red_side := game.team_of(900)

	# On the point, and not live: warmup is when everybody stands on everything.
	_stand(game, 900, hill.def.area.centre)
	for t in range(TICK_RATE):
		game.tick({})
	_check(
		hill.owner_team == 0,
		"nothing is captured during warmup", str(hill.owner_team)
	)

	_go_live(game)
	_stand(game, 901, Vector3(1000.0, 0.0, 0.0))

	var ticks := 0
	while hill.owner_team == 0 and ticks < TICK_RATE * 30:
		_stand(game, 900, hill.def.area.centre)
		game.tick({})
		ticks += 1

	_check(
		hill.owner_team == red_side,
		"and a player standing on it takes it once the match is live",
		"%d after %d ticks" % [hill.owner_team, ticks]
	)

	var left := clock.remaining_for(red_side)
	for t in range(TICK_RATE):
		_stand(game, 900, hill.def.area.centre)
		game.tick({})
	_check(
		clock.remaining_for(red_side) < left,
		"holding it runs their clock down",
		"%d from %d" % [clock.remaining_for(red_side), left]
	)

	# The freeze, the whole tension of the mode. Sampled on the tick the point changes hands: red's clock legitimately runs
	# while blue captures, and an earlier sample would measure that instead.
	_stand(game, 900, Vector3(1000.0, 0.0, 0.0))
	var blue_side := game.team_of(901)
	var frozen := -1
	var flipped := 0
	while hill.owner_team != blue_side and flipped < TICK_RATE * 30:
		_stand(game, 901, hill.def.area.centre)
		game.tick({})
		flipped += 1
		if hill.owner_team == blue_side:
			frozen = clock.remaining_for(red_side)

	_check(
		hill.owner_team == blue_side,
		"the other side can take it back", str(hill.owner_team)
	)
	for t in range(TICK_RATE):
		_stand(game, 901, hill.def.area.centre)
		game.tick({})
	_check(
		clock.remaining_for(red_side) == frozen,
		"and the first side's clock is FROZEN where it stopped rather than reset",
		"%d against %d" % [clock.remaining_for(red_side), frozen]
	)
	_check(
		clock.remaining_for(blue_side) < clock.def.holdout_ticks,
		"while the new owner's runs"
	)

	# **A mode change has to build and unbuild the layers the mode asks for.** Without it `changegame` from a deathmatch to koth
	# left a mode claiming objectives with `objectives` null, and nothing errored because a null layer is legitimate.
	var to_ffa := game.change_map(ArenaMap.dm_box(), ArenaMode.free_for_all())
	_check(to_ffa.ok, "the mode changes to one with no objectives", str(to_ffa.error))
	_check(
		game.objectives == null,
		"and the objective layer is taken away, so a HUD does not draw a hill nobody "
		+ "can capture"
	)

	var to_ctf := game.change_map(ArenaMap.dm_atrium(), ArenaMode.capture_the_flag())
	_check(to_ctf.ok, "and to one that has them", str(to_ctf.error))
	_check(
		game.objectives != null and game.objectives.layout == &"ctf",
		"which builds the layer the new mode asks for",
		String(game.objectives.layout) if game.objectives != null else "<none>"
	)
	_check(
		game.effects != null and game.spectate != null,
		"while the layers every mode has survive the change rather than being rebuilt"
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()

func _test_capture_the_flag() -> void:
	_section("capture the flag")

	var game := ArenaGame.new()
	game.name = "CtfGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.capture_the_flag(3)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a capture-the-flag game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return

	game.start(0)
	var red_flag := game.objectives.manager.objective(&"flag_1") as DotObjectiveFlag
	var blue_flag := game.objectives.manager.objective(&"flag_2") as DotObjectiveFlag
	_check(red_flag != null and blue_flag != null, "there are two flags")
	_check(
		red_flag.home_team() != blue_flag.home_team(),
		"one for each side"
	)

	var _a := game.add_player(910, "One")
	var _b := game.add_player(911, "Two")
	_go_live(game)

	# Whoever is NOT on red's side is the one who can take red's flag.
	var thief := 910 if game.team_of(910) != red_flag.home_team() else 911
	var defender := 911 if thief == 910 else 910
	var thief_team := game.team_of(thief)

	_stand(game, defender, Vector3(1000.0, 0.0, 0.0))
	_stand(game, thief, red_flag.at)
	game.tick({})

	_check(
		red_flag.carrier == str(thief),
		"standing on the enemy flag takes it",
		"carrier=%s" % red_flag.carrier
	)

	# The carrier's own flag is at home, so a capture is allowed.
	var target := red_flag.capture_area_for(thief_team, game.objectives.ctf.flags()).centre
	for t in range(20):
		_stand(game, thief, target)
		game.tick({})

	_check(
		red_flag.captures == 1,
		"carrying it to the other end scores it", str(red_flag.captures)
	)
	_check(red_flag.is_home(), "and the flag goes home")
	_check(
		game.match_node.scoreboard.team_score(game.team_of(thief)) > 0,
		"and dot-match has the point, through report_objective rather than a bare "
		+ "team score, so the win check ran with it",
		str(game.match_node.scoreboard.team_score(game.team_of(thief)))
	)

	# A carrier who dies drops it.
	_stand(game, thief, red_flag.at)
	game.tick({})
	_check(red_flag.carrier == str(thief), "it is taken again")
	_kill_through_combat(game, defender, thief)
	game.tick({})
	_check(
		red_flag.state == DotObjectiveFlag.State.DROPPED,
		"and a carrier who dies drops it",
		DotObjectiveFlag.State.keys()[red_flag.state]
	)

	game.queue_free()
	remove_child(game)
	await get_tree().process_frame
	_done()

## Free roam: on by default, off by `mp_freeroam 0`, refused under `mp_forcecamera 1`. The
## client flies the camera (`ArenaClient._fly_free_camera`); this is the policy under it.
func _test_free_roam() -> void:
	_section("free roam")

	var game := ArenaGame.new()
	game.name = "RoamGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch(50)
	add_child(game)

	var ready := game.setup(ArenaMap.dm_atrium())
	if not _check(ready.ok, "a roaming game sets up", str(ready.error)):
		game.queue_free()
		remove_child(game)
		return
	game.start(0)
	for index in range(4):
		var _added := game.add_player(900 + index, "Roamer %d" % index)
	game.match_node.rules.respawn_delay_sec = 120.0
	_go_live(game)

	var victim := 900
	var killer := _first_other_team(game, victim)
	_kill_through_combat(game, killer, victim)
	for t in range(TICK_RATE * 5):
		game.tick({})

	var rules := game.spectate_rules
	_check(
		rules.force_camera == 0 and rules.allow_roaming,
		"a team mode spectates with the defaults: anybody, free roam on",
		"force_camera %d" % rules.force_camera
	)
	var mgr := game.spectate.manager
	_check(game.spectate.can_roam(str(victim)), "a dead player may roam")

	var dead: ArenaPlayer = game.player_for(victim)
	if dead != null and dead.flashlight_cfg != null:
		var lit_dead: bool = dead.flashlight
		for i in range(ArenaFlashlight.HOLD_TICKS):
			_hold(game, victim, ArenaFlashlight.BUTTON)
		_settle(game, victim, 2)
		_check(dead.flashlight == lit_dead, "a dead spectator's flashlight key switches nothing")
	else:
		_check(false, "the dead player is reachable for the flashlight check")

	var before := game.spectate.camera_for(str(victim))
	var entered := game.spectate.toggle_roam(str(victim))
	_check(entered.ok, "the roam key enters a roam", str(entered.error))
	_check(game.spectate.is_roaming(str(victim)), "and the mode is ROAMING")
	_check(
		game.spectate.camera_for(str(victim)).origin.distance_to(before.origin) < 0.01,
		"seeded where the camera was, not at the origin"
	)

	var cam := DotSpectatorFreeCam.new()
	cam.rules = rules
	cam.seed_from(game.spectate.camera_for(str(victim)))
	var moved := cam.step(Vector3(0.0, 0.0, 1.0), false, false, 1.0)
	var _kept := mgr.move_free(str(victim), moved.origin, moved.basis)
	_check(
		game.spectate.camera_for(str(victim)).origin.distance_to(before.origin) > rules.roam_speed * 0.9,
		"flying forward a second moves the camera by the roam speed"
	)
	game.tick({})
	_check(game.spectate.is_roaming(str(victim)), "and a tick leaves the roam alone")

	var left := game.spectate.toggle_roam(str(victim))
	_check(left.ok and not game.spectate.is_roaming(str(victim)), "the same key goes back onto a player")

	_check(rules.set_cvar("mp_freeroam", "0"), "mp_freeroam 0 is read")
	var refused := game.spectate.toggle_roam(str(victim))
	_check(not refused.ok, "with mp_freeroam 0 the roam key is refused")
	_check(not game.spectate.can_roam(str(victim)), "and the hint is not offered")
	_check(rules.set_cvar("mp_freeroam", "1"), "mp_freeroam 1 is read")
	_check(game.spectate.toggle_roam(str(victim)).ok, "back on, it enters again")
	_check(rules.set_cvar("mp_forcecamera", "1"), "mp_forcecamera 1 is read")
	for t in range(4):
		game.tick({})
	await _test_free_roam_rest(game, victim, rules)
