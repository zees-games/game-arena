extends "headless_match_part7.gd"

## dot-stats, dot-achievements and dot-leaderboard, over the match that just ran. Every check is against a number the match
## PRODUCED, not one this test filed: reading back one's own readings tests dot-stats, and what is untested elsewhere is
## whether a kill here reaches those three addons at all.
func _test_progression() -> void:
	_section("progression")

	var progress := _game.progress

	if not _check(progress != null, "the game keeps progress"):
		return

	_check(
		progress.stats != null and progress.achievements != null
			and progress.boards != null,
		"stats, achievements and boards are all up"
	)

	var bot_id: int = ArenaGame.BOT_SESSION_BASE + 1
	progress.begin(bot_id, "bot")
	progress.record(bot_id, &"kills", 1.0)
	_check(not progress.stats.has_player(StringName(ArenaGame.storage_key(bot_id))), "a bot never enters the stats")

	# The catalogue's validator refuses one stat read with two merge rules (a total and a personal best cannot be one number);
	# checked here because otherwise one achievement never unlocks for one player with nothing erroring.
	var catalogue_ok := progress.achievements.catalogue.validate()
	_check(catalogue_ok.ok, "the achievement catalogue validates", str(catalogue_ok.error))

	var schema_ok := progress.stats.schema.validate()
	_check(schema_ok.ok, "the stats schema validates", str(schema_ok.error))

	# Every stat an achievement reads must be declared by the schema. Neither addon can check this (each is unaware of
	# the other): two ends of one serialisation that never met, and one loop.
	var undeclared := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not progress.stats.schema.has(stat):
			undeclared.append(String(stat))

	_check(
		undeclared.is_empty(),
		"every stat an achievement watches is one the schema declares",
		", ".join(undeclared)
	)

	# --- What the match actually filed -----------------------------------

	var total_kills := 0.0
	var total_fired := 0.0
	var total_hit := 0.0
	var any_deaths := false
	var best_streak := 0.0

	for player in _game.players():
		var values := progress.session_values(player.player_id)
		total_kills += values.get_value(ArenaStats.KILLS, 0.0)
		total_fired += values.get_value(ArenaStats.SHOTS_FIRED, 0.0)
		total_hit += values.get_value(ArenaStats.SHOTS_HIT, 0.0)
		best_streak = maxf(best_streak, values.get_value(ArenaStats.BEST_STREAK, 0.0))

		if values.get_value(ArenaStats.DEATHS, 0.0) > 0.0:
			any_deaths = true

	# The kill feed is the independent witness. Suicides carry no killer, so the
	# stat total is the feed's count minus those — asserting equality against the
	# raw feed size would fail the moment a bot rocket-jumped into a wall.
	var credited := 0

	for entry in _kills:
		if entry.killer_key != "" and not entry.suicide:
			credited += 1

	_check(
		total_kills == float(credited),
		"every credited kill reached dot-stats",
		"feed %d, stats %d" % [credited, int(total_kills)]
	)

	_check(any_deaths, "deaths were counted too")

	_stats_event_check(progress)

	_check(
		total_fired > 0.0,
		"shots fired were counted",
		"%d" % int(total_fired)
	)

	# One shot is one shot whatever it fired. If this counted damage events instead,
	# a shotgun's nine pellets would make hits exceed shots and a shotgun player nine
	# times as accurate as a rifle player.
	_check(
		total_hit <= total_fired,
		"shots landed never exceed shots fired",
		"%d hit of %d fired" % [int(total_hit), int(total_fired)]
	)

	_check(
		best_streak >= 1.0,
		"a best streak was filed as a best rather than a sum",
		"%d" % int(best_streak)
	)

	# Achievements: First Blood is one kill and the match produced six, so this would pass even if dot-stats and
	# dot-achievements were wired straight through (the bug DotAchievementStatsLink prevents); it proves they connect at all.
	var unlocked_any := false

	for player in _game.players():
		if progress.achievements.is_unlocked(
			ArenaGame.storage_key(player.player_id), &"arena.first_blood"
		):
			unlocked_any = true

	_check(unlocked_any, "somebody unlocked First Blood")

	# The differencing itself. A player with N session kills must hold N lifetime
	# kills, not the running sum 1+2+...+N that a direct signal connection produces —
	# which for six kills is twenty-one and for a hundred is five thousand.
	var mismatched := PackedStringArray()

	for player in _game.players():
		var key := ArenaGame.storage_key(player.player_id)
		var held := progress.achievements.progress_of(key)

		if held == null:
			continue

		var session := progress.session_values(player.player_id).get_value(
			ArenaStats.KILLS, 0.0
		)

		if absf(held.value_of(ArenaStats.KILLS) - session) > 0.001:
			mismatched.append("%s: lifetime %.0f, session %.0f" % [
				key, held.value_of(ArenaStats.KILLS), session
			])

	_check(
		mismatched.is_empty(),
		"lifetime kills equal session kills, so the link differences rather than sums",
		", ".join(mismatched)
	)

	# Boards: filed when a player leaves, so this removes one. The only place `leave` is exercised, and it is a coroutine
	# (the achievement store may be remote), so it is awaited here.
	var leaver := _game.players()[0]
	var leaver_key := StringName(ArenaGame.storage_key(leaver.player_id))
	var leaver_kills := progress.session_values(leaver.player_id).get_value(
		ArenaStats.KILLS, 0.0
	)

	await progress.leave(leaver.player_id)

	var scope := ArenaBoards.scope_for(_game.mode.id)
	var entry := progress.boards.entry_for(ArenaBoards.KILLS, scope, leaver_key)

	if leaver_kills > 0.0:
		_check(
			entry.ok and entry.value is DotLeaderboardEntry,
			"a player who leaves lands on the kills board"
		)

		if entry.ok and entry.value is DotLeaderboardEntry:
			_check(
				absf((entry.value as DotLeaderboardEntry).value - leaver_kills) < 0.001,
				"with the number they actually scored",
				"board %s, session %d" % [
					str((entry.value as DotLeaderboardEntry).value), int(leaver_kills)
				]
			)
	else:
		# A zero is deliberately NOT filed: a SCORE board of zeroes is noise and a
		# zero on the PENALTY board would hold first place for ever.
		_check(
			not (entry.ok and entry.value is DotLeaderboardEntry),
			"a player who scored nothing is not put on a board"
		)

	await _test_boards_async(progress)

	# Every board this game defines has to be one the manager will accept. A
	# definition rejected at boot is a board that silently holds nothing.
	var defined := progress.boards.definitions().size()
	_test_progression_rest(defined)

## Which spawn of [param map] is nearest [param at], and how far: [index, metres].
func _nearest_spawn(map: ArenaMap, at: Vector3) -> Array:
	var best := -1
	var best_distance := INF

	for index in range(map.spawns.size()):
		var distance := map.spawns[index].origin.distance_to(at)

		if distance < best_distance:
			best = index
			best_distance = distance

	return [best, best_distance]

## The spawn tag of match team [param team_id], or empty outside a team mode.
func _spawn_tag_of_team(team_id: int) -> StringName:
	for team in _game.teams():
		if team.id == team_id:
			return team.spawn_tag

	return &""

func _test_map_change_rest(director: ArenaMapDirector, team: ArenaMode) -> void:
	if team != null:
		var to_team := _game.change_map(ArenaMap.by_id(_game.map.id), team)

		if _check(to_team.ok, "the game moves into a team mode", str(to_team.error)):
			# The respawn a map change now does is the round start's, so it has to
			# honour the sides the new mode just assigned: a side's spawn tag, or an
			# untagged point both may use.
			var wrong_side := PackedStringArray()

			for player in _game.players():
				var nearest := _nearest_spawn(_game.map, player.controller.state.position)
				var tag := _game.map.spawn_tag(int(nearest[0]))
				var wanted := _spawn_tag_of_team(_game.team_of(player.player_id))

				if float(nearest[1]) > 0.5 or (tag != &"" and tag != wanted):
					wrong_side.append("%d (%s) at a %s spawn, %.1f m" % [
						player.player_id, String(wanted), String(tag), float(nearest[1])
					])

			_check(
				wrong_side.is_empty(),
				"and the change puts each side at its own spawns",
				", ".join(wrong_side)
			)

			director.restrict_rotation()

			_check(
				not director.session.rotation.order.has(&"dm_pit"),
				"the rotation stops offering dm_pit while a team mode is played",
				str(director.session.rotation.order)
			)
			_check(
				director.session.rotation.order.has(&"dm_box")
					and director.session.rotation.order.has(&"dm_atrium"),
				"and still offers the two that can host it"
			)

			# Asked for by name, which is what an admin typing `changelevel` does and what a
			# rotation cannot be made to stop doing.
			var refused: DotResult = await director.change_to(&"dm_pit")

			_check(
				not refused.ok,
				"and changing to it by name is refused outright"
			)
			_check(
				_game.map.id != &"dm_pit",
				"with the game left on the map it was on",
				String(_game.map.id)
			)

			var back := _game.change_map(
				ArenaMap.by_id(_game.map.id), ArenaMode.free_for_all()
			)

			if _check(back.ok, "the game goes back to a free-for-all", str(back.error)):
				director.restrict_rotation()

				_check(
					director.session.rotation.order.has(&"dm_pit"),
					"and dm_pit is offered again",
					str(director.session.rotation.order)
				)

	director.queue_free()
	remove_child(director)
	_done()

## The two-metre box [method _test_map_change] builds on top of a player.
func _trap_at(standing: Vector3) -> AABB:
	return AABB(standing + Vector3(-1.0, -0.05, -1.0), Vector3(2.0, 2.4, 2.0))

## The first patch of bare floor, scanning in a fixed order, where a trap box would
## touch no other box and would sit at least four metres from every spawn — so the only
## way a player ends up inside it is by having been left there.
func _open_floor_away_from_spawns(map: ArenaMap) -> Variant:
	var reach := int(map.extent) - 3

	for x in range(-reach, reach + 1, 2):
		for z in range(-reach, reach + 1, 2):
			var at := Vector3(float(x), map.floor_y + 0.05, float(z))
			var trap := _trap_at(at)
			var clear := true

			for box in map.boxes:
				# The floor itself is the one box a trap stands on rather than in.
				if box.end.y <= map.floor_y + 0.01:
					continue

				if box.intersects(trap.grow(0.5)):
					clear = false
					break

			if not clear:
				continue

			if float(_nearest_spawn(map, at)[1]) < 4.0:
				continue

			return at

	return null

## Every player whose body is inside a box of [param map], by id. Two points up the
## body rather than the feet, because a player standing ON a box has their feet on its
## top face and is exactly where they should be.
func _players_inside_boxes(map: ArenaMap) -> Array[int]:
	var out: Array[int] = []

	for player in _game.players():
		var feet := player.controller.state.position

		for box in map.boxes:
			var solid := box.grow(-0.05)

			if solid.has_point(feet + Vector3.UP * 0.3) or solid.has_point(feet + Vector3.UP * 1.2):
				out.append(player.player_id)
				break

	return out
