extends "headless_net_base.gd"


## Walking into another player: the server stops the walker, the client predicted it, and a strafing blocker too.
func _solid_walk_checks(c: Dictionary) -> void:
	var server_a: ArenaPlayer = c.server_a
	var server_b: ArenaPlayer = c.server_b
	var client_game: ArenaGame = c.client_game
	var place: Callable = c.place
	var walk: DotFpsCommand = c.walk
	var idle: DotFpsCommand = c.idle
	var lane_x: float = c.lane_x
	var two_radii: float = c.two_radii
	place.call()
	var solid := _flight_window(2, 96, 0, {2: walk, 3: idle})
	var a_z := server_a.controller.state.position.z
	var b_z := server_b.controller.state.position.z
	print("  measured: solid, closest %.3f m (two radii %.2f), A at z %.2f, B at z %.2f, worst prediction gap %.3f m" % [
		float(solid["closest"]), two_radii, a_z, b_z, float(solid["worst_aligned"])])
	_check(
		float(solid["closest"]) >= two_radii - 0.02 and float(solid["closest"]) <= two_radii + 0.25,
		"walked into another player, the server stops the walker two radii from them",
		"closest %.3f m, two radii %.2f" % [float(solid["closest"]), two_radii]
	)
	_check(
		a_z > b_z,
		"and never past them",
		"A z %.2f, B z %.2f" % [a_z, b_z]
	)
	_check(
		float(solid["worst_aligned"]) < 0.03,
		"and the walker's client predicted the stop (worst %.3f m from the server)" % float(solid["worst_aligned"])
	)
	# A blocker that strafes across the lane and jumps, changing direction on odd ticks, between
	# the client's snapshots: both ends must meet it at the same place.
	server_a.controller.teleport(Vector3(lane_x, 0.1, 19.0), 0.0)
	server_b.controller.teleport(Vector3(lane_x, 0.1, 16.5), 0.0)
	var _settle_moving := _flight_window(0, 24, 0, {2: idle, 3: idle})
	var stops_before := ArenaSolidBody.hull_stops
	var moving_worst := 0.0
	ArenaNetBridge.solid_trace = OS.get_environment("NC_SOLID_TRACE") == "1"
	for leg in range(14):
		var strafe := DotFpsCommand.new()
		strafe.move = Vector2(1.0 if leg % 2 == 0 else -1.0, 0.0)
		strafe.yaw = 0.0
		strafe.buttons = DotFpsCommand.BUTTON_JUMP if leg % 3 == 1 else 0
		var lean := DotFpsCommand.new()
		lean.move = Vector2(0.0, 1.0)
		lean.yaw = 0.0
		var window := _flight_window(2, 7, 0, {2: lean, 3: strafe})
		moving_worst = maxf(moving_worst, float(window["worst_aligned"]))
	ArenaNetBridge.solid_trace = false
	var moving_stops := ArenaSolidBody.hull_stops - stops_before
	print("  measured: a strafing, jumping blocker, %d hull stops, worst prediction gap %.3f m" % [moving_stops, moving_worst])
	_check(
		moving_stops > 0 and moving_worst < 0.03,
		"a walk into a blocker that strafes and jumps is predicted where the server stopped it",
		"%d stops, worst %.3f m" % [moving_stops, moving_worst]
	)


## The view lag a walker sends, its cap, and the unlag history below tick 0.
func _solid_lag_checks(c: Dictionary) -> void:
	var server_a: ArenaPlayer = c.server_a
	var server_b: ArenaPlayer = c.server_b
	var client_game: ArenaGame = c.client_game
	var place: Callable = c.place
	var walk: DotFpsCommand = c.walk
	var idle: DotFpsCommand = c.idle
	var session_a: int = c.session_a
	# The newest command in each packet is the encoded one, and the server keeps the first copy.
	var walker_lag := _server_bridge.behaviour_for(session_a).last_view_lag
	_check(
		walker_lag >= 0.0,
		"a walker that never fires still sends its view lag while solid (%.2f ticks)" % walker_lag
	)
	var saved_unlag := _server_game.max_unlag_ms
	var cap := _server_game.collision_lag(127.0)
	_check(
		cap > 0.0 and cap <= ArenaGame.COLLISION_LAG_MAX_TICKS and _server_game.collision_lag(2.5) == 2.5,
		"a claimed view lag of 127 ticks collides at most %.0f back" % cap
	)
	# No event link here: RULES handed over as the link would carry it.
	var relay := func(rules: Dictionary) -> void:
		var bytes := _server_bridge.encode_event(ArenaEvents.Kind.RULES, ArenaEvents.write_rules(rules))
		for peer_id in _clients:
			var _r: DotResult = _clients[peer_id]["bridge"].receive_event(bytes)
	_server_game.movement_rules_changed.connect(relay)
	_server_game.max_unlag_ms = 0.0
	_check(
		_server_game.collision_lag(4.0) < 0.0 and client_game.collision_lag(4.0) < 0.0,
		"with arena_max_unlag_ms 0 both ends collide with the present (the limit travels in RULES)",
		"client limit %.0f" % client_game.max_unlag_ms
	)
	_server_game.max_unlag_ms = saved_unlag
	_server_game.movement_rules_changed.disconnect(relay)
	var fresh_ticks := PackedInt32Array()
	fresh_ticks.resize(ArenaGame.UNLAG_HISTORY)
	fresh_ticks.fill(-1)
	var fresh_positions := PackedVector3Array()
	fresh_positions.resize(ArenaGame.UNLAG_HISTORY)
	_server_game._unlag[-77] = [fresh_positions, fresh_ticks]
	_check(
		_server_game.unlag_position_at(-77, -0.5) == null,
		"a view tick below 0 finds no history, not the unfilled last slot at the origin"
	)
	_server_game._unlag.erase(-77)


## With mp_solidplayers 0 the same walk passes through, predicted so; solidity is restored after.
func _solid_off_checks(c: Dictionary) -> void:
	var server_a: ArenaPlayer = c.server_a
	var server_b: ArenaPlayer = c.server_b
	var client_game: ArenaGame = c.client_game
	var place: Callable = c.place
	var walk: DotFpsCommand = c.walk
	var idle: DotFpsCommand = c.idle
	_server_game.body_rules.solid = false
	client_game.body_rules.solid = false
	for peer_id in _clients:
		(_clients[peer_id]["bridge"] as ArenaNetBridge).game.body_rules.solid = false
	place.call()
	var through := _flight_window(2, 96, 0, {2: walk, 3: idle})
	print("  measured: mp_solidplayers 0, closest %.3f m, A at z %.2f, worst prediction gap %.3f m" % [
		float(through["closest"]), server_a.controller.state.position.z, float(through["worst_aligned"])])
	_check(
		server_a.controller.state.position.z < server_b.controller.state.position.z - 1.0,
		"at mp_solidplayers 0 the same walk passes through them",
		"A z %.2f, B z %.2f" % [server_a.controller.state.position.z, server_b.controller.state.position.z]
	)
	_check(
		float(through["worst_aligned"]) < 0.03,
		"and is predicted so (worst %.3f m)" % float(through["worst_aligned"])
	)

	_server_game.body_rules.solid = true
	for peer_id in _clients:
		(_clients[peer_id]["bridge"] as ArenaNetBridge).game.body_rules.solid = true


## Teammates pass by default, enemies stop, mp_teamblock and the !noblock state string flip the pair on both ends.
func _solid_team_checks(c: Dictionary) -> void:
	var server_a: ArenaPlayer = c.server_a
	var server_b: ArenaPlayer = c.server_b
	var client_game: ArenaGame = c.client_game
	var place: Callable = c.place
	var walk: DotFpsCommand = c.walk
	var idle: DotFpsCommand = c.idle
	# Teams: teammates pass through each other by default (mp_teamblock 0), predicted so on the
	# walker's client; enemies still stop; a player's !block / !noblock request travels as the
	# mp_blockstate string and flips the pair on both ends.
	var games: Array[ArenaGame] = [_server_game]
	for peer_id in _clients:
		games.append((_clients[peer_id]["bridge"] as ArenaNetBridge).game)
	var ids := [server_a.player_id, server_b.player_id]
	var sides := {ids[0]: "1", ids[1]: "1"}
	for g in games:
		if g.noblock == null:
			var _made := g.make_noblock(false)
		g.block_rules.side_fn = func(id: Variant) -> Variant: return sides.get(int(id), "")
	place.call()
	var mates := _flight_window(2, 96, 0, {2: walk, 3: idle})
	_check(
		server_a.controller.state.position.z < server_b.controller.state.position.z - 1.0,
		"teammates pass through each other by default (mp_teamblock 0)",
		"A z %.2f, B z %.2f" % [server_a.controller.state.position.z, server_b.controller.state.position.z]
	)
	_check(float(mates["worst_aligned"]) < 0.03,
		"and the walker's client predicted the pass (worst %.3f m)" % float(mates["worst_aligned"]))

	sides[ids[1]] = "2"
	place.call()
	var foes := _flight_window(2, 96, 0, {2: walk, 3: idle})
	_check(server_a.controller.state.position.z > server_b.controller.state.position.z
		and float(foes["worst_aligned"]) < 0.03, "enemies still stop, predicted",
		"A z %.2f, B z %.2f" % [server_a.controller.state.position.z, server_b.controller.state.position.z])

	sides[ids[1]] = "1"
	for g in games:
		g.block_rules.config.team_block = true
	place.call()
	var forced := _flight_window(2, 96, 0, {2: walk, 3: idle})
	_check(server_a.controller.state.position.z > server_b.controller.state.position.z
		and float(forced["worst_aligned"]) < 0.03, "mp_teamblock 1 makes teammates stop, predicted")

	_check(_server_game.block_rules.request(ids[0], [DotTeamBlockRules.Relation.TEAM], 0).ok,
		"a !noblock request is accepted")
	for g in games:
		if g != _server_game:
			g.block_rules.apply_state_string(_server_game.block_rules.state_string())
	place.call()
	var asked := _flight_window(2, 96, 0, {2: walk, 3: idle})
	_check(server_a.controller.state.position.z < server_b.controller.state.position.z - 1.0
		and float(asked["worst_aligned"]) < 0.03,
		"and with the state string on the client too, the pair passes, predicted")

	for g in games:
		g.block_rules.config.team_block = false
		g.block_rules.clear()
		g.block_rules.side_fn = Callable()
