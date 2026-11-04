extends "headless_match_part6.gd"

## Every position and velocity of the north gallery's two wall routes, driven the
## intended way, as one hash.
func _wall_trace(map: ArenaMap, tunables: DotFpsTunables) -> int:
	var numbers := PackedFloat64Array()
	var body := map.to_fps_body()

	for route in map.wall_routes:
		var motor := DotFpsMotor.new(tunables, body)
		var driver := WallRouteDriver.new(route, &"walls")
		var state := DotFpsState.new()
		state.position = driver.start
		state.yaw = driver.yaw
		state.mode = DotFpsState.Mode.AIR
		for _i in range(200):
			motor.simulate(state, driver.next(state), 1.0 / float(TICK_RATE))
			for v in [state.position, state.velocity]:
				numbers.append_array([v.x, v.y, v.z])

	return hash(numbers)

## The wall moves arena turns on, the cvar for each, and what "off" means.
func _test_wall_rules() -> void:
	_section("wall movement: on in the arena, a cvar each, and off is what it was")

	var t := ArenaPlayer.arena_tunables()
	_check(t.wall_run_enabled and t.wall_jump_enabled and is_equal_approx(t.wall_slide_speed, 2.5),
		"the arena wall-runs, wall-jumps and wall-slides by default")
	_check(t.wall_run_min_speed > t.max_speed,
		"a run needs more than the plain run along the wall (%.1f over %.1f m/s)" % [t.wall_run_min_speed, t.max_speed],
		"at or under it, every jump beside a wall would become a run")

	var unbacked := PackedStringArray()
	var walls_cvars := 0
	for cvar: String in ArenaModule.MOVEMENT_CVARS:
		if not cvar.begins_with("arena_wall"):
			continue
		walls_cvars += 1
		var key: String = ArenaModule.MOVEMENT_CVARS[cvar][0]
		if not ArenaPlayer.MOVEMENT_RULES.has(key) or (t.get(key) == null and not ArenaPlayer.BODY_RULES.has(key)):
			unbacked.append(cvar)
	_check(walls_cvars >= 3 and unbacked.is_empty(),
		"every arena_wall_* cvar sets a tunable RULES carries (%d)" % walls_cvars, ", ".join(unbacked))

	var off := {"wall_run_enabled": 0.0, "wall_jump_enabled": 0.0, "wall_slide_speed": 0.0,
		"wall_jump_max_per_air": 2.0}
	_game.set_movement_rules(off)
	var all_off := true
	for player in _game.players():
		var pt := player.controller.tunables
		all_off = all_off and not pt.wall_run_enabled and not pt.wall_jump_enabled \
			and pt.wall_slide_speed == 0.0 and typeof(pt.get("wall_jump_max_per_air")) == TYPE_INT \
			and pt.wall_jump_max_per_air == 2
	_check(all_off, "the rules reach every player's movement, a count as a count")
	var on := {"wall_run_enabled": 1.0, "wall_jump_enabled": 1.0, "wall_slide_speed": 2.5,
		"wall_jump_max_per_air": 3.0}
	_game.set_movement_rules(on)
	var back := _game.players()[0].controller.tunables
	_check(back.wall_run_enabled and back.wall_jump_enabled and back.wall_slide_speed == t.wall_slide_speed
			and back.wall_jump_max_per_air == t.wall_jump_max_per_air,
		"and back on, a player has the arena's wall numbers again")

	# Off, through the same path a cvar takes, against the motor's own pre-wall defaults.
	var ruled_off := ArenaPlayer.arena_tunables()
	for key in off:
		ArenaPlayer._set_rule(ruled_off, key, off[key])
	var before := ArenaPlayer.arena_tunables()
	var stock := DotFpsTunables.new()
	for property in before.get_property_list():
		var name := String(property["name"])
		if name.begins_with("wall_"):
			before.set(name, stock.get(name))

	var map := ArenaMap.dm_atrium()
	var off_hash := _wall_trace(map, ruled_off)
	var before_hash := _wall_trace(map, before)
	var on_hash := _wall_trace(map, ArenaPlayer.arena_tunables())
	_check(off_hash == before_hash, "with the wall cvars at 0 the motor moves byte for byte as it did before walls",
		"%d against %d" % [off_hash, before_hash])
	_check(on_hash != before_hash, "and the same ticks with them on do not, so the trace reaches a wall",
		"if this fails, the comparison above proves nothing")
	_done()

func _test_players_exist() -> void:
	_section("players")

	_check(_game.players().size() == BOTS, "every bot has a body")

	for player in _game.players():
		_check(
			player.controller != null and player.arsenal != null and player.health != null,
			"bot %d has movement, an arsenal and health" % player.player_id
		)
		_check(
			_game.combat.hitboxes_of(player.player_id) != null,
			"and is registered as shootable"
		)
		_check(
			_game.combat.health_of(player.player_id) == player.health,
			"and as damageable"
		)
	_done()

func _nearest_target(from: ArenaPlayer) -> ArenaPlayer:
	var best: ArenaPlayer = null
	var best_distance := INF

	for other in _game.players():
		if other == from or not other.is_alive():
			continue

		var distance := from.muzzle_position().distance_to(other.muzzle_position())

		if distance < best_distance:
			best_distance = distance
			best = other

	return best

# --- Playing ---------------------------------------------------------------

## Aims at the nearest living opponent and holds the trigger. Deliberately simple: four of them produce kills, deaths,
## respawns and blocked shots without anything called by hand.
func _commands_for_tick(tick: int) -> Dictionary:
	var commands := {}

	for player in _game.players():
		if not player.is_alive():
			continue

		var target := _nearest_target(player)
		var move := DotFpsCommand.new()
		var fire := DotWeaponCommand.new()

		if target != null:
			var to_target := (
				target.muzzle_position() - player.muzzle_position()
			).normalized()

			# The inverse of DotWeaponCommand.aim_direction() (-Z forward). A wrong sign makes every bot shoot backwards, which
			# reads as broken hit registration.
			move.yaw = rad_to_deg(atan2(-to_target.x, -to_target.z))
			move.pitch = rad_to_deg(asin(clampf(to_target.y, -1.0, 1.0)))

			fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)

			# Strafe, so they are not four statues: it exercises the movement-based spread and the
			# ground friction, and it means the shots are not all fired from a standstill.
			move.move = Vector2(sin(float(tick) * 0.05 + float(player.player_id)), 0.33)

		move.sanitise()
		fire.sanitise()
		commands[player.player_id] = [move, fire]

	return commands

func _play() -> void:
	_section("playing")

	var ticks := 0

	while ticks < MAX_TICKS:
		if _game.match_node.state == DotMatch.State.MATCH_END:
			break

		_game.tick(_commands_for_tick(ticks))
		ticks += 1

		if _vote != null:
			_vote.advance(1.0 / float(TICK_RATE))

		for player in _game.players():
			var at := player.controller.state.position
			_lowest_y = minf(_lowest_y, at.y)
			_furthest = maxf(_furthest, maxf(absf(at.x), absf(at.z)))

			if player.controller.state.is_grounded():
				_grounded_ticks += 1

		# Loadouts apply through an awaited store call, so the frame must turn over or the deferred half never runs. Every 4
		# ticks, not 64: at 64 a respawned bot stayed unarmed and a 3,300-tick match ran past 5,760 on CI.
		if ticks % 4 == 0:
			await get_tree().process_frame

	_check(
		ticks < MAX_TICKS,
		"the match reached an end on its own",
		"ran %d ticks" % ticks
	)
	print("       %d ticks, %d kills" % [ticks, _kills.size()])
	_done()

## A map vote over the match `_play` is about to run, with a score limit and nothing else. Real frags, not a reported number:
## dot-vote's suite calls `note_score` by hand, and until this no game did, so `trigger: score_limit` validated and did nothing.
func _build_vote() -> void:
	_section("a map vote over the match")

	var maps := ArenaMapDirector.new()
	maps.name = "VoteMaps"
	maps.game = _game
	maps.map_seconds = 0.0
	add_child(maps)
	_check(maps.setup().ok, "a map director for the vote sets up")

	_vote = ArenaVote.new()
	_vote.name = "Vote"
	_vote.game = _game
	_vote.maps = maps
	# Counts and never applies: a winner would change the map under every section after
	# this one. `auto_apply` follows it, and so does the registry.
	_vote.authoritative = false
	_vote.config_path = ""
	add_child(_vote)

	var ready := _vote.setup()
	if not _check(ready.ok, "and the vote sets up", str(ready.error)):
		_vote = null
		return

	# A score limit ABOVE the match's own, so the clock is still running when the round ends and the
	# round end can be seen arriving.
	var rules := _vote.director.rules
	rules.trigger = DotVoteRules.Trigger.SCORE_LIMIT
	rules.duration_sec = 0.0
	rules.score_limit = SCORE_LIMIT + 10
	rules.vote_lead_score = SCORE_LIMIT + 6
	rules.vote_warning_sec = 0.0
	# Open for the whole match, so a ballot closing unanswered does not restart the clock
	# and open a second one.
	rules.vote_duration_sec = 600.0
	_check(rules.validate().ok, "a score-limited vote validates", str(rules.validate().error))

	# The clock reads its limits when it starts.
	_vote.director.begin(_vote.source.current_id())

	_vote.director.vote_opened.connect(func(_options: Array, _seconds: float) -> void:
		_vote_seen.append([
			DotMatch.State.keys()[_game.match_node.state], _vote.leading_score()
		])
	)
	_done()

func _test_score_vote() -> void:
	_section("the map vote heard the match")

	if not _check(_vote != null, "there is a vote"):
		return

	_check(
		_vote_seen.size() == 1,
		"a ballot opened, once, off the bots' own frags (%d)" % _vote_seen.size(),
		"nothing called note_score, and trigger: score_limit decided nothing"
	)

	if not _vote_seen.is_empty():
		var first: Array = _vote_seen[0]
		_check(
			String(first[0]) == "LIVE" and int(first[1]) >= SCORE_LIMIT - 2
				and int(first[1]) < SCORE_LIMIT,
			"while the round was live, two short of the limit (%s at %d)" % [first[0], first[1]]
		)

	_check(
		_vote.director.clock.top_score == _game.match_node.scoreboard.best_score()
			and _vote.director.clock.top_score >= SCORE_LIMIT,
		"and followed the leader to the match's own limit (%d)" % _vote.director.clock.top_score
	)
	_check(
		_vote.director.clock.rounds_played == 1,
		"and dot-match's round end reached it (%d)" % _vote.director.clock.rounds_played,
		"ArenaVote.note_round_end existed and was called by nothing"
	)

	# A new match is followed without a map change: `arena_mode` calls `game.change_map` directly, which never fires
	# `maps.map_changed`, so a vote bound only there held the freed match. A stand-in match node, not a real mode change.
	var real_match: DotMatch = _game.match_node
	var stand_in := DotMatch.new()
	_game.match_node = stand_in
	_vote.advance(1.0 / float(TICK_RATE))
	var followed: bool = _vote.get("_match") == stand_in \
		and stand_in.round_ended.is_connected(_vote._on_round_ended)
	_game.match_node = real_match
	_vote.advance(1.0 / float(TICK_RATE))
	_check(
		followed and _vote.get("_match") == real_match
			and not stand_in.round_ended.is_connected(_vote._on_round_ended),
		"and it follows a new match the moment the game has one, and lets the old one go",
		"a mode change builds a match without map_changed, and the vote kept the freed one"
	)
	stand_in.free()

	_vote.director.close_vote()
	_vote.queue_free()
	_vote.maps.queue_free()
	_vote = null
	_done()

func _test_outcome() -> void:
	_section("what happened")

	_check(_kills.size() > 0, "bots killed each other", "%d kills" % _kills.size())

	# Every kill must have a killer and a victim the scoreboard knows about.
	var orphans := 0
	for entry in _kills:
		if entry.suicide:
			continue
		if entry.killer_key == "" or entry.victim_key == "":
			orphans += 1
	_check(orphans == 0, "and every kill is attributed", "%d orphaned" % orphans)

	var board := _game.match_node.scoreboard
	var total_kills := 0
	var total_deaths := 0

	for record in board.players():
		total_kills += record.kills
		total_deaths += record.deaths

	_check(total_kills > 0, "the scoreboard recorded them", str(total_kills))
	_check(
		total_deaths >= total_kills,
		"and a death for each, plus any suicides",
		"%d deaths, %d kills" % [total_deaths, total_kills]
	)

	# Respawning is what makes it a deathmatch rather than one round of elimination.
	_check(
		_spawns.size() > BOTS,
		"players respawned after dying",
		"%d spawns for %d bots" % [_spawns.size(), BOTS]
	)

	var leader := board.leader()
	_check(leader != null, "there is a leader")
	_check(
		leader.score >= SCORE_LIMIT,
		"who reached the score limit",
		"%d of %d" % [leader.score, SCORE_LIMIT]
	)

	_check(
		_game.match_node.last_outcome() == DotMatchRules.Outcome.SCORE,
		"and the match ended because of it",
		DotMatchRules.Outcome.keys()[_game.match_node.last_outcome()]
	)

	_check(_states.has("MATCH_END"), "the match reached MATCH_END", str(_states))

	# Damage was actually tracked, not merely inferred from kills.
	var dealt := 0.0
	for record in board.players():
		dealt += record.damage_dealt
	_check(dealt > 0.0, "damage was recorded", "%.0f" % dealt)

	# Loadouts reached the arsenals. A player holding nothing is a player whose
	# loadout never arrived, and they would still be able to kill with the default.
	var armed := 0
	for player in _game.players():
		if player.arsenal.slots().size() >= 2:
			armed += 1
	_check(armed == BOTS, "every bot is holding its loadout", "%d of %d" % [armed, BOTS])

	# The combat manager saw real work, including refusals — a shot fired while dead
	# or during a respawn is normal and must be refused rather than resolved.
	var stats := _game.combat.describe()
	_check(
		int(stats["resolved"]) > 0,
		"shots were resolved",
		str(stats["resolved"])
	)
	_done()

func _test_interface_rest(hud: ArenaHud, menu, board) -> void:
	_check(not menu.any_open(), "and closes")
	board.follow("")

	menu.queue_free()
	remove_child(menu)
	hud.queue_free()
	remove_child(hud)
	_done()

# --- Progression -----------------------------------------------------------

## A kill on the feed becomes a kill reading on the registry's tracker, and reporting is off by default.
func _stats_event_check(progress) -> void:
	_check(DotRegistry.get_service(&"dot_stats_tracker") == progress.stats, "the tracker is the dot_stats_tracker service")
	_check(not progress.stats.report_to_backbone, "stats reporting is off by default")
	var players := _game.players()
	if players.size() < 2:
		return
	var killer: Variant = players[0]
	var victim: Variant = players[1]
	var seen: Array = []
	progress.stats.recorded.connect(func(_id: StringName, stat: StringName, _total: float) -> void: seen.append(stat))
	var entry := DotKillFeed.Entry.new()
	entry.killer_key = str(killer.player_id)
	entry.victim_key = str(victim.player_id)
	progress._on_killed(entry)
	_check(
		seen.has(ArenaStats.KILLS) and seen.has(ArenaStats.DEATHS),
		"a kill produces kills and deaths stat events", str(seen)
	)
	_check(progress.stats.reporter.pending_kills() == 0, "a kill is not filed for the site while reporting is off")
	progress.stats.report_to_backbone = true
	var bot_entry := DotKillFeed.Entry.new()
	bot_entry.killer_key = str(ArenaGame.BOT_SESSION_BASE + 1)
	bot_entry.victim_key = str(victim.player_id)
	bot_entry.cause = &"rifle"
	progress._on_killed(bot_entry)
	_check(progress.stats.reporter.pending_kills() == 1, "a bot kill is filed for the vs table", str(progress.stats.reporter.pending_kills()))
	var filed: Dictionary = progress.stats.reporter._kills[0] if progress.stats.reporter.pending_kills() > 0 else {}
	_check(bool(filed.get("killer_bot", false)) and not bool(filed.get("victim_bot", true)) and filed.get("weapon", "") == "rifle", "flagged as a bot killer with its weapon", str(filed))
	progress.stats.report_to_backbone = false

func _test_progression_rest(defined: int) -> void:
	_check(
		defined == ArenaBoards.definitions().size(),
		"every board definition was accepted",
		"%d of %d" % [defined, ArenaBoards.definitions().size()]
	)
	_done()

## The _async forms against the memory store (the default) and against a remote one.
func _test_boards_async(progress) -> void:
	_check(progress.boards.backend == "memory", "the boards backend defaults to memory")
	_check(DotBoardsConfig.for_game("arena").validate().ok, "the boards config validates")

	var values := DotStatsValues.new()
	values.values[ArenaStats.KILLS] = 7.0
	var scope := ArenaBoards.scope_for(&"ffa")

	await ArenaBoards.submit_session(progress.boards, &"ffa", &"async_p", "Ada", values)
	var mem: DotResult = await progress.boards.entry_for_async(ArenaBoards.KILLS, scope, &"async_p")
	_check(
		mem.ok and mem.value is DotLeaderboardEntry and absf((mem.value as DotLeaderboardEntry).value - 7.0) < 0.001,
		"async submit lands on the memory store"
	)
	var memory_page: DotResult = await progress.boards.page_async(ArenaBoards.KILLS, scope, 0, 10)
	_check(memory_page.ok and (memory_page.value as Array).size() >= 1, "async page reads the memory store")

	var site := DotLeaderboardFakeSite.new(get_tree())
	var remote := DotLeaderboardManager.new()
	remote.backend = "backbone"
	remote.backbone_client = site
	add_child(remote)
	for board in ArenaBoards.definitions():
		remote.define(board)

	var plain := remote.page(ArenaBoards.KILLS, scope, 0, 10)
	_check(not plain.ok, "the synchronous form refuses a remote store")

	await ArenaBoards.submit_session(remote, &"ffa", &"async_p", "Ada", values)
	var remote_page: DotResult = await remote.page_async(ArenaBoards.KILLS, scope, 0, 10)
	_check(
		remote_page.ok and (remote_page.value as Array).size() == 1
		and ((remote_page.value as Array)[0] as DotLeaderboardEntry).value == 7.0,
		"a remote board takes the session through the async forms",
		str(remote_page.error) if not remote_page.ok else ""
	)
	_check(site.posts() > 0, "the fake site received the declare and the submit")
	remove_child(remote)
	remote.queue_free()

## The HUD and the menus, built and driven headlessly. Nothing is rendered; what is checked is the wiring: a bound widget reads
## the right value, the Tab board fills from the finished match, and the Escape menu has this game's pages and drops a held board.
func _test_interface() -> void:
	_section("the interface")

	var ui_config := DotUiConfig.new()
	ui_config.allow_pause = false

	var hud := ArenaHud.new()
	hud.name = "Hud"
	hud.config = ui_config
	add_child(hud)
	hud.build(_game)

	var subject := _game.players()[0]

	for candidate in _game.players():
		if candidate.is_alive():
			subject = candidate
			break

	# A respawn at the match's end applies its loadout through an awaited store call.
	for _frame in 4:
		await get_tree().process_frame

	hud.follow(subject)
	hud.refresh_all()

	# Health is dot-ui's `DotVitals`, handed the followed player's numbers by `present_gear`.
	hud.present_gear()
	_check(hud.crosshair != null and hud.vitals != null, "the HUD builds")
	_check(
		absf(hud.vitals.health - subject.health.health) < 0.01,
		"and its health reads the player it follows",
		"%s vs %.1f" % [hud.vitals.health, subject.health.health]
	)

	subject.health.health = 33.0
	hud.present_gear()
	_check(
		absf(hud.vitals.health - 33.0) < 0.01 and hud.vitals.number_text() == "33",
		"and follows it when it changes"
	)

	# The crosshair opens by the real projection (a fixed gap would mean the binding never reaches the weapon). Both readings
	# are taken AFTER a refresh, since `gap_pixels()` reports the spread of the last `refresh_all()`. The subject holds a weapon
	# WITH spread (`spread_degrees()` is zero unless it is [DotWeaponBallistics]) and the movement state is moved, not the arsenal.
	for slot_index in subject.arsenal.slots():
		var slot := subject.arsenal.slot_at(slot_index)

		if slot != null and slot.def.tuning is DotWeaponBallistics:
			subject.arsenal.select(slot_index, _game.current_tick())
			break

	# And standing on the ground, uncrouched: `DotWeaponBallistics.spread_for` returns the airborne spread whatever the speed,
	# so a subject left mid-hop by the match read "4.6 -> 4.6" with a rifle. Only the posture is set, not the position.
	var posture_was := subject.controller.state.mode
	var crouch_was := subject.controller.state.crouch_fraction
	subject.controller.state.mode = DotFpsState.Mode.GROUND
	subject.controller.state.crouch_fraction = 0.0

	# The state-driven cone: with the combat-feel rules attached the cone is the last tick's (headless_combatfeel).
	var rules_was := subject.arsenal.spread_rules
	subject.arsenal.spread_rules = null
	subject.controller.state.velocity = Vector3.ZERO
	hud.refresh_all()
	# A narrowing gap eases closed over `cl_crosshair_ease`; no frame has run, so step it out or `still` reads the match's last cone.
	hud.crosshair.ease_spread(10.0)
	var still := hud.crosshair.gap_pixels()

	subject.controller.state.velocity = Vector3(8.0, 0.0, 0.0)
	hud.refresh_all()
	_check(
		hud.crosshair.gap_pixels() > still,
		"and the crosshair opens when the player moves",
		"%.1f -> %.1f, holding %s" % [
			still,
			hud.crosshair.gap_pixels(),
			subject.arsenal.current_def().id if subject.arsenal.current_def() != null
				else "nothing"
		]
	)
	subject.arsenal.spread_rules = rules_was
	subject.controller.state.mode = posture_was
	subject.controller.state.crouch_fraction = crouch_was

	# And it turns spread into pixels through the FOV the camera really draws with (83.6 vertical at the default 100, not a
	# constant 75, which drew every gap 17% too wide). Two settings, since one could agree with a stale copy by coincidence.
	var had_camera := subject.camera != null
	subject.attach_camera(100.0)
	hud.match_view()
	_check(
		is_equal_approx(hud.crosshair.fov_degrees, subject.camera.fov)
		and not is_equal_approx(subject.camera.fov, 75.0),
		"the crosshair measures with the camera's field of view",
		"crosshair %.2f, camera %.2f" % [hud.crosshair.fov_degrees, subject.camera.fov]
	)
	subject.attach_camera(120.0)
	hud.match_view()
	_check(
		is_equal_approx(hud.crosshair.fov_degrees, subject.camera.fov),
		"and follows it when the player changes it",
		"crosshair %.2f, camera %.2f" % [hud.crosshair.fov_degrees, subject.camera.fov]
	)
	if not had_camera:
		subject.camera.queue_free()
		subject.camera = null

	# This HUD is built after the match ended, as a client joining mid-match is: the kills already happened and the signal
	# has fired. catch_up() fills it; without it the HUD stays empty until the next death.
	_check(hud.feed.line_count() == 0, "a fresh HUD starts with an empty feed")
	var caught := hud.catch_up()
	_check(caught > 0, "and catches up on the kills it missed", "%d entries" % caught)
	_check(
		hud.feed.line_count() == caught,
		"which is what it then shows"
	)

	# The glance layout's pieces read the match, not a copy of it: the strip, the ranked
	# portraits, the ammunition and the carried weapons.
	hud.present_scores()
	var mine := _game.match_node.scoreboard.find(str(subject.player_id))
	_check(
		mine != null and hud.strip.left_score == mine.score and hud.strip.left_tag == "YOU",
		"the strip's left score is the followed player's own", "%d" % hud.strip.left_score
	)
	# The server's figure, as a networked client hands it over: rounded up, never 0:00 with
	# time left (dot-ui's `DotScoreStrip.clock_text`; arena's own rounded down).
	hud.remaining_override = 59.4
	hud.present_scores()
	_check(hud.strip.clock == "1:00" and not hud.strip.clock_low, "the clock rounds the seconds left up (59.4 s reads %s)" % hud.strip.clock)
	hud.remaining_override = 0.3
	hud.present_scores()
	_check(hud.strip.clock == "0:01" and hud.strip.clock_low, "and says 0:01, in red, with a fraction of a second left (%s)" % hud.strip.clock)
	hud.remaining_override = NAN
	hud.present_portraits()
	var ranked_kills: Array = []
	for e in hud.portraits.entries:
		ranked_kills.append(int(e["rank"]))
	_check(
		hud.portraits.entries.size() == mini(BOTS, ArenaHudGlance.Portraits.MAX_SHOWN)
			and ranked_kills == range(1, hud.portraits.entries.size() + 1),
		"the portraits are every player, ranked 1 to N", str(ranked_kills)
	)
	# Somebody alive: a dead player's HUD shows no gear, and the match that ended left
	# whoever it left.
	var armed: ArenaPlayer = null
	for p in _game.players():
		if p.is_alive() and p.arsenal != null and not p.arsenal.slots().is_empty():
			armed = p
			break
	if armed != null:
		hud.follow(armed)
	hud.present_gear()
	_check(
		armed != null and hud.slots.rows.size() == armed.arsenal.slots().size() and hud.ammo.weapon_name != "",
		"the slots are the weapons carried, and the counter names the one in hand",
		"%d rows" % hud.slots.rows.size()
	)
	hud.follow(subject)
	var no_icon := PackedStringArray()
	for weapon in AwWeaponPack.IDS:
		if ArenaHudGlance.Ink.weapon_icon(weapon) == null:
			no_icon.append(String(weapon))
	_check(no_icon.is_empty(), "every weapon has a silhouette for the feed and the slots", ", ".join(no_icon))

	var no_sprite := PackedStringArray()
	for weapon in ArenaWeaponIcons.TAGS:
		if not ArenaWeaponIcons.shared.icon_set().has_icon(weapon):
			no_sprite.append(String(weapon))
	_check(no_sprite.is_empty() and ArenaWeaponIcons.shared.texture(&"pistol") is AtlasTexture, "every mapped weapon draws a Jestan sprite by default", ", ".join(no_sprite))
	_check(ArenaWeaponIcons.shared.set_style(&"silhouette") and ArenaWeaponIcons.shared.texture(&"pistol") == null and ArenaHudGlance.Ink.weapon_icon(&"pistol") != null,
		"the silhouette style turns the sprites off and the old outline answers")
	var _style_back := ArenaWeaponIcons.shared.set_style(&"pixel")
	ArenaWeaponIcons.shared.icon_set().override(&"pistol", ArenaHudGlance.Ink.texture("res://assets/weapon_icons/knife.png"), &"test")
	ArenaWeaponIcons.shared.set_profile(&"test")
	var overridden := ArenaWeaponIcons.shared.texture(&"pistol") == ArenaHudGlance.Ink.texture("res://assets/weapon_icons/knife.png")
	ArenaWeaponIcons.shared.set_profile(&"")
	_check(overridden and ArenaWeaponIcons.shared.texture(&"pistol") is AtlasTexture, "a profile's override replaces one weapon's picture and only for that profile")

	# The Escape menu and the Tab board are dot-menu's (since 2026-10-10), built with no
	# presentation layer here: no settings document, so only rows that need none draw.
	var menu := ArenaMenus.build(self, null)
	_check(menu != null and menu.screen != null, "the menu builds without a settings document")
	var page_ids: Array[StringName] = []
	for page in menu.pages:
		page_ids.append(page.id)
	_check(
		page_ids == ([&"general", &"interface", &"video", &"audio", &"controls", &"advanced"] as Array[StringName]),
		"the stock pages and this game's Interface page, in order", str(page_ids)
	)
	# The Servers page is there only with a browser behind it; a page that opened nothing
	# would be the dot-ui menu's greyed button again.
	_check(menu.page(&"servers") == null, "no Servers page where there is no browser")
	_check(
		menu.bindings != null and menu.bindings.row_for_action(&"arena_scoreboard").get("default", "") == "Tab",
		"the key table holds the board's Tab"
	)

	var board := ArenaMenus.Board.new(menu.scoreboard, _game.match_node.scoreboard, null, _game.match_node.teams)
	menu.scoreboard.open()
	_check(
		menu.scoreboard.is_open() and menu.scoreboard.rows().size() == BOTS,
		"the board fills from the match that just ended",
		"%d rows" % menu.scoreboard.rows().size()
	)
	# Held, never one of the menu's overlays: holding Tab must not stop the player or take
	# the pointer, which is what `any_open()` drives in the client.
	_check(not menu.any_open(), "a held board is not an open menu")
	menu.open(&"controls")
	_check(menu.any_open() and not menu.scoreboard.is_open(), "the menu opened over the board drops the board")
	menu.close()
	_test_interface_rest(hud, menu, board)
