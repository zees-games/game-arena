extends "headless_match_part8.gd"

# --- Changing the map ------------------------------------------------------

## dot-map, over the game that is already running, with players in it. The deployment shape that did not exist: dot-map's own
## suite runs scenes, this runs a catalogue of code-made maps, a session that builds rather than loads, and an [ArenaGame] that
## tears down a combat manager and a match node it did not expect to lose.
func _test_map_change() -> void:
	_section("changing the map")

	var catalogue := ArenaMaps.catalogue()

	# The built-ins and every imported combat surf map the link holds (none without it).
	var buildable := ArenaMap.ids().size() + ArenaMap.imported_ids().size()
	_check(
		catalogue.size() == buildable,
		"every map ArenaMap can build is in the catalogue",
		"%d of %d" % [catalogue.size(), buildable]
	)

	var problems := catalogue.problems()
	_check(problems.is_empty(), "and every entry validates", ", ".join(problems))

	# A map def whose scene path does not exist is a def that fails at the change
	# rather than at the boot, which is the whole reason the path is a real file
	# rather than a `code://` sentinel.
	var missing := PackedStringArray()

	for def in catalogue.maps:
		if not ResourceLoader.exists(def.scene_path) and not FileAccess.file_exists(def.scene_path):
			missing.append("%s -> %s" % [String(def.id), def.scene_path])

	_check(
		missing.is_empty(),
		"and every one points at a file that exists",
		", ".join(missing)
	)

	var director := ArenaMapDirector.new()
	director.name = "Maps"
	director.game = _game
	director.map_seconds = 0.0
	director.rotation_cooldown = 99
	add_child(director)

	var ready := director.setup()

	if not _check(ready.ok, "the map director sets up", str(ready.error)):
		return

	# More was asked for than any catalogue holds. The director's catalogue also lists the
	# delivered maps, so the size is read from it, not from the built-in one above.
	var pool_size := director.session.catalogue.size()
	_check(
		director.session.rotation.cooldown == maxi(pool_size - 1, 0),
		"a cooldown larger than the catalogue is reduced to fit",
		"%d over %d maps" % [director.session.rotation.cooldown, pool_size]
	)

	_check(
		director.current != null and director.current.id == _game.map.id,
		"it adopts the map already running rather than changing to it"
	)

	# --- The change itself ------------------------------------------------

	var before_id := _game.map.id
	var before_players := _game.players().size()
	var target: StringName = &"dm_atrium" if before_id == &"dm_box" else &"dm_box"

	var kills_before := 0.0

	for player in _game.players():
		kills_before += _game.progress.session_values(player.player_id).get_value(
			ArenaStats.KILLS, 0.0
		)

	var changed_to: Array[StringName] = []
	_game.map_changed.connect(func(m: ArenaMap) -> void: changed_to.append(m.id))

	var changed: DotResult = await director.change_to(target)

	_check(changed.ok, "the map changes under the players", str(changed.error))
	_check(_game.map.id == target, "and the game is on the new one")
	_check(changed_to.has(target), "and map_changed fired for it")

	_check(
		_game.players().size() == before_players,
		"every player survived the change",
		"%d of %d" % [_game.players().size(), before_players]
	)

	# --- What has to have been rebuilt ------------------------------------

	_check(
		_game.combat != null and _game.match_node != null,
		"the combat manager and the match node were rebuilt"
	)

	var registered := 0

	for player in _game.players():
		if _game.combat.hitboxes_of(player.player_id) != null:
			registered += 1

	_check(
		registered == _game.players().size(),
		"and every player is shootable in the new one",
		"%d of %d" % [registered, _game.players().size()]
	)

	var expected_spawns := ArenaMap.by_id(target).spawns.size()
	_check(
		_game.match_node.spawn_points().size() == expected_spawns,
		"the spawn points are the new map's",
		"%d, expected %d" % [_game.match_node.spawn_points().size(), expected_spawns]
	)

	# The trace is the map. Rebuilding the manager and forgetting the trace would
	# leave every shot resolving against the geometry of a room nobody is in — and
	# nothing would error, because a trace that hits nothing is a legitimate answer.
	var new_map := ArenaMap.by_id(target)
	var outward := _game.combat.trace.ray(
		Vector3(0.0, 2.0, 0.0), Vector3.RIGHT, new_map.extent * 4.0
	)
	_check(
		outward.ok() and outward.blocked
			and outward.distance < new_map.extent + 3.0,
		"and a shot at the new perimeter stops at it",
		"%.1f m, extent %.1f" % [outward.distance, new_map.extent]
	)

	_check(
		_game.combat.trace is DotTraceFlat
			and (_game.combat.trace as DotTraceFlat).boxes.size() == new_map.boxes.size(),
		"the trace holds the new map's boxes and not the old one's",
		"%d, expected %d" % [
			(_game.combat.trace as DotTraceFlat).boxes.size(), new_map.boxes.size()
		]
	)

	# Progression across a change: `ArenaProgress` is connected to the combat manager and match node just freed; without
	# `rebind_world` it would listen to two dead objects and count nothing, silently, like a quiet game.
	var alive := _game.players()

	if alive.size() >= 2:
		var shooter := alive[0]

		# An ENEMY, not the next player in the list: the resolver refuses a team-mate when friendly fire is off and a team mode
		# has assigned everybody by now. Team 0 is "no team" and two unassigned players are not allies, so the fallback is right in a FFA.
		var victim: ArenaPlayer = alive[1]

		for candidate in alive.slice(1):
			if _game.team_of(candidate.player_id) \
					!= _game.team_of(shooter.player_id):
				victim = candidate
				break

		# Put the victim back in the world first: the match left everybody dead and damage to a dead entity is correctly refused,
		# so a probe that skipped this would report "nothing was counted" for an unrelated reason.
		victim.hitboxes.enabled = true
		victim.spawn(
			Transform3D(Basis.IDENTITY, Vector3(0.0, new_map.floor_y + 1.0, 0.0)),
			_game.current_tick(),
			0
		)

		# [b]And out of dot-spawn's ledger, which `victim.spawn(..., 0)` does not clear.[/b] The
		# zero above is `DotHealth`'s window; the map change respawned everybody through
		# `_on_respawn_due` and that is what grants the session-scoped protection the resolver now.
		if _game.player_stack != null and _game.player_stack.spawns.protection != null:
			_game.player_stack.spawns.protection.revoke(
				str(victim.player_id), _game.current_tick()
			)

		# [b]And THREE records, not two.[/b] `ArenaPlayerStack.refresh_spawn_rules` says it outright
		# -- spawn protection is enforced by [DotHealth]'s window, by dot-spawn's ledger, and by the
		# `arena_protected` effect -- and this cleared the first two.
		if _game.effects != null and _game.effects.manager != null:
			_game.effects.manager.remove(
				ArenaEffects.PROTECTED, victim.player_id
			)

		var before := _game.progress.session_values(shooter.player_id).get_value(
			ArenaStats.DAMAGE_DEALT, 0.0
		)

		# Stamped, because an unstamped `DotDamage` is tick 0 and every gate that
		# compares a tick against a window refuses it for ever. `ArenaEffects` carries
		# the same warning and names where this family found it the first time.
		var event := DotDamage.make(
			shooter.player_id, victim.player_id, 10.0,
			_game.combat.damage_type(ArenaContent.DAMAGE_BULLET)
		)
		event.tick = _game.current_tick()

		var damage := _game.combat.apply_damage(event)

		var after := _game.progress.session_values(shooter.player_id).get_value(
			ArenaStats.DAMAGE_DEALT, 0.0
		)

		# The refusal reason is in the message because without it this check says
		# only "0.0", and every reason the resolver has for refusing looks
		# identical from here.
		_check(
			damage.health_lost > 0.0,
			"a rebuilt combat manager still applies damage",
			"lost %.1f%s" % [
				damage.health_lost,
				", refused: %s" % damage.refusal if damage.refused else ""
			]
		)
		_check(
			after > before,
			"progress is still counting after the world was replaced",
			"%.0f -> %.0f, damage %.1f" % [before, after, damage.health_lost]
		)

		var zoned := DotDamage.make(
			shooter.player_id, victim.player_id, 5.0,
			_game.combat.damage_type(ArenaContent.DAMAGE_BULLET)
		)
		zoned.tick = _game.current_tick()
		zoned.hit_group = DotHitGroup.NECK
		zoned.weapon_id = &"probe"
		var _z := _game.combat.apply_damage(zoned)
		_check(
			_game.progress.session_values(shooter.player_id).get_cell(DotStatsHitzones.HITS, "zone:neck") >= 1.0,
			"a landed hit is filed by body zone through the dot-stats hitzone hook"
		)
		var pts_before := _game.progress.session_values(shooter.player_id).get_value(ArenaStats.POINTS, 0.0)
		var _landed := _game.progress.points.award(shooter.player_id, DotStatsPoints.SOURCE_PICKUP, 3.0)
		_check(
			_game.progress.session_values(shooter.player_id).get_value(ArenaStats.POINTS, 0.0) == pts_before + 3.0,
			"a points award lands on the player's arena.points stat through the DotStatsPoints hook"
		)
		_game.progress.rank.mode = DotStatsRank.MODE_ELO
		var _moved := _game.progress.rank.duel(shooter.player_id, -999)
		_check(
			_game.progress.session_values(shooter.player_id).get_value(ArenaStats.RANK_SCORE, 0.0) == 1012.0,
			"an Elo win files rank_score through the DotStatsRank hook"
		)
		_game.progress.rank.mode = DotStatsRank.MODE_WEIGHTED
		_game.progress.rank.reset()

		# Lifetime path: a stored baseline lifts the rank, no baseline ranks on the session, a flush never counts twice.
		var rk := _game.progress.rank
		var tracker := _game.progress.stats
		var sess := tracker.session_values(StringName(_game.progress._key_of(shooter.player_id)))
		var session_only := rk.publish(shooter.player_id, sess.to_dictionary())
		var career := DotStatsValues.new()
		career.values[str(ArenaStats.KILLS)] = 100.0
		var store := DotStatsStoreMemory.new()
		var _stored := await store.merge(StringName(_game.progress._key_of(shooter.player_id)), career, tracker.schema)
		rk.forget(shooter.player_id)
		var loaded: DotResult = await store.values_for(StringName(_game.progress._key_of(shooter.player_id)))
		rk.seed_baseline(shooter.player_id, loaded.value as DotStatsValues)
		var lifetime := rk.publish_lifetime(shooter.player_id, sess, tracker.schema)
		_check(lifetime > session_only, "a player with a stored baseline ranks above the session-only figure", "%s vs %s" % [lifetime, session_only])
		_check(
			is_equal_approx(rk.publish_lifetime(victim.player_id, sess, tracker.schema), rk.weighted(sess.to_dictionary())),
			"a player with no baseline ranks on the session alone"
		)
		tracker.store = store
		store.schema = tracker.schema
		var _flushed: DotResult = await tracker.flush()
		_check(
			is_equal_approx(rk.publish_lifetime(shooter.player_id, sess, tracker.schema), lifetime),
			"a flush after the baseline load does not count the session twice"
		)
		tracker.store = null
		rk.mode = DotStatsRank.MODE_ELO
		var stored_rank := DotStatsValues.new()
		stored_rank.values[str(ArenaStats.RANK_SCORE)] = 1500.0
		rk.seed_baseline(victim.player_id, stored_rank)
		_check(rk.rating_of(victim.player_id) == 1500.0, "Elo mode seeds the rating from the stored rank_score")
		rk.mode = DotStatsRank.MODE_WEIGHTED
		rk.reset()

		# Leave and rejoin through the progress node and a file store: the lifetime total survives, and a flush after the rejoin adds only the new session.
		var file_path := "user://headless_match_stats.json"
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file_path))
		var fstore := DotStatsStoreFile.new(file_path)
		fstore.schema = tracker.schema
		tracker.store = fstore
		var visitor := 9001
		var vkey := StringName(_game.progress._key_of(visitor))
		await _game.progress.begin(visitor, "Visitor")
		_game.progress.record(visitor, ArenaStats.KILLS, 3.0)
		await _game.progress.leave(visitor)
		var _w: DotResult = await tracker.flush_store()
		var kills_id := StringName(ArenaStats.KILLS)
		var stored_after_leave: float = (await fstore.values_for(vkey)).value.get_value(kills_id)
		_check(stored_after_leave == 3.0, "a leave files the session into the lifetime store", str(stored_after_leave))
		await _game.progress.begin(visitor, "Visitor")
		var base: DotStatsValues = _game.progress.rank.baselines.get(visitor, null)
		_check(base != null and base.get_value(kills_id) == 3.0, "a rejoin reads the stored lifetime total as the rank baseline")
		_check(_game.progress.stats.session_values(vkey).get_value(kills_id) == 0.0, "the rejoined session starts at zero")
		_game.progress.record(visitor, ArenaStats.KILLS, 2.0)
		var _w2: DotResult = await tracker.flush()
		var stored_after_flush: float = (await fstore.values_for(vkey)).value.get_value(kills_id)
		_check(stored_after_flush == 5.0, "a flush after the rejoin adds only the new session", str(stored_after_flush))
		var _w3: DotResult = await tracker.flush()
		_check((await fstore.values_for(vkey)).value.get_value(kills_id) == 5.0, "a second flush adds nothing")
		var reread := DotStatsStoreFile.new(file_path)
		reread.schema = tracker.schema
		_check((await reread.values_for(vkey)).value.get_value(kills_id) == 5.0, "the file holds the same total for a fresh process")
		await _game.progress.leave(visitor)
		tracker.store = null
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file_path))

	var kills_after := 0.0

	for player in _game.players():
		kills_after += _game.progress.session_values(player.player_id).get_value(
			ArenaStats.KILLS, 0.0
		)

	# A session is a visit to the server, not a visit to a room. Resetting here would
	# mean a player's numbers restart every time the map does.
	_check(
		kills_after >= kills_before,
		"and session totals survived the change",
		"%d before, %d after" % [int(kills_before), int(kills_after)]
	)

	# --- Players can still move -------------------------------------------  The motor holds a
	# reference to the body it was built with, so a player handed new geometry without a rebuilt
	# motor keeps colliding against the level they are no longer in.
	for tick in range(32):
		_game.tick(_commands_for_tick(1000 + tick))

	var below := 0

	for player in _game.players():
		if player.controller.state.position.y < new_map.floor_y - 1.0:
			below += 1

	_check(
		below == 0,
		"nobody fell through the new floor",
		"%d below it" % below
	)

	# --- A box where somebody was standing -------------------------------  [b]The check above
	# passes on the shipped maps by luck of layout.[/b] A map change used to keep every player's
	# position and swap the geometry under them.
	var trap_map := ArenaMap.by_id(_game.map.id)
	var standing: Variant = _open_floor_away_from_spawns(trap_map)

	if _check(
		standing != null,
		"there is open floor away from every spawn to build a box on",
		String(trap_map.id)
	):
		var carried: ArenaPlayer = _game.players()[0]
		carried.controller.teleport(standing as Vector3, 0.0, 0.0)
		trap_map.add_box(_trap_at(standing as Vector3))

		var trapped := _game.change_map(trap_map)

		_check(
			trapped.ok,
			"the map changes to one with a box where player %d is standing"
				% carried.player_id,
			str(trapped.error)
		)

		var inside := _players_inside_boxes(trap_map)
		_check(
			inside.is_empty(),
			"and nobody is inside a box of the new map once it has",
			"inside: %s" % str(inside)
		)

		var astray := PackedStringArray()

		for player in _game.players():
			var nearest := _nearest_spawn(trap_map, player.controller.state.position)

			if float(nearest[1]) > 0.5:
				astray.append("%d %.1f m from a spawn" % [player.player_id, float(nearest[1])])

		_check(
			astray.is_empty(),
			"every player is at a spawn point of the new map, respawned rather than "
			+ "carried over",
			", ".join(astray)
		)

		for tick in range(32):
			_game.tick(_commands_for_tick(1100 + tick))

		var under := 0

		for player in _game.players():
			if player.controller.state.position.y < trap_map.floor_y - 1.0:
				under += 1

		inside = _players_inside_boxes(trap_map)
		_check(
			under == 0 and inside.is_empty(),
			"and after half a second of play nobody is inside a box or under the floor",
			"%d under it, inside: %s" % [under, str(inside)]
		)

	# --- The mode gate, over a live rotation -------------------------------  [b]Last, because it
	# moves the game into a team mode and back.[/b] Nothing below depends on the state this leaves,
	# and nothing above should have to care. What is being checked is the hole `dm_pit` opened.
	var team := _first_team_mode()

	await _test_map_change_rest(director, team)
