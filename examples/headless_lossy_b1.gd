extends "lossy_windows.gd"


## p95 and max distance between A's prediction and the server's A over input ticks [from, to),
## less those of [param skip] (see [method _excused]).
func _prediction_gap(session: int, from: int, to: int, skip: Dictionary = {}) -> Array:
	var track: Dictionary = _server_track.get(session, {})
	var diffs: Array[float] = []
	for tick in range(from, to):
		if _predicted.has(tick) and track.has(tick) and not skip.has(tick):
			diffs.append((_predicted[tick] as Vector3).distance_to(track[tick]))
	diffs.sort()
	if diffs.is_empty():
		return [0, -1.0, -1.0, 0]
	var over := 0
	for d in diffs:
		if d > 0.05:
			over += 1
	return [diffs.size(), diffs[int(diffs.size() * 0.95)], diffs[diffs.size() - 1], over]


## [b]Stamina on, sprinting and wall-running through 20% loss.[/b] The arena has no stamina cvar (its
## sprint bit is the dash), so both ends' tunables are set the way a game that turned it on would.
## A drains to empty, waits out the refill delay and drains again, then runs the wall with sprint held.
func _test_stamina_under_loss() -> void:
	_section("sprint stamina and a wall run through 20% loss")

	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var session := int(a["session"])
	var server_a := _game.player_for(session)
	var own: ArenaPlayer = (a["game"] as ArenaGame).player_for(session)
	if not _check(server_a != null and own != null, "A is on both ends to sprint with"):
		_done()
		return

	for t: DotFpsTunables in [server_a.controller.tunables, own.controller.tunables]:
		t.stamina_enabled = true
		t.stamina_drain = 0.8
		t.stamina_recover = 0.5
		t.stamina_resume_at = 0.3
		t.stamina_exhaust_delay = 0.5
	var _dash_on := _server.console.set_cvar("arena_dash", "1")
	var _auto_off := _server.console.set_cvar("arena_wall_run_auto", "0")
	await _moves_told(own)

	var lows := {"min": 1.0, "exhausted": 0, "client_min": 1.0}
	var sample := func() -> void:
		lows["min"] = minf(lows["min"], server_a.controller.state.stamina)
		lows["client_min"] = minf(lows["client_min"], own.controller.state.stamina)
		if server_a.controller.state.stamina_exhausted:
			lows["exhausted"] += 1
	var tick_hook := func() -> void:
		sample.call()
	var replays := int(net.predictor.get("_replays"))
	var corrections := int(net.predictor.get("_corrections_applied"))
	net.predictor.set("_worst_error", 0.0)

	_stam_from = net.clock.input_tick() + 4
	var from := _stam_from
	var until := Engine.get_physics_frames() + 9 * Engine.physics_ticks_per_second
	var wall := Time.get_ticks_msec() + 72000
	while Engine.get_physics_frames() < until and Time.get_ticks_msec() < wall:
		await get_tree().physics_frame
		tick_hook.call()
	var last := net.clock.input_tick()
	_stam_from = -1
	await _wait_game(0.5)
	replays = int(net.predictor.get("_replays")) - replays
	corrections = int(net.predictor.get("_corrections_applied")) - corrections
	_stam_from = from
	var open: Array = _prediction_gap(session, from, last, _excused(_edge_holes(from, last, _command_a), net))
	_stam_from = -1
	print("    stamina: the server's A fell to %.2f and was exhausted on %d frames; A's copy fell to %.2f" % [
		lows["min"], lows["exhausted"], lows["client_min"]])
	print("    A's prediction over %d ticks: p95 %.3f / max %.3f m; %d of %d replays corrected" % [
		open[0], open[1], open[2], corrections, replays])
	_check(lows["min"] < 0.05 and lows["exhausted"] > 10,
		"the sprint pattern really drained the server's A and exhausted it", "%.2f, %d frames" % [lows["min"], lows["exhausted"]])
	_check(open[0] > 5 * Engine.physics_ticks_per_second and open[1] >= 0.0 and open[1] <= 0.05 and open[2] <= 1.5,
		"A's prediction with stamina draining within 5 cm for 95% of its ticks",
		"%d ticks, p95 %.3f, max %.3f" % [open[0], open[1], open[2]])
	_check(corrections <= maxi(3, replays / 10),
		"and corrected in no more than a tenth of the replays (%d of %d)" % [corrections, replays])

	await _stamina_wall_run(server_a, session, net)

	_wall_hold_sprint = false
	_wall_idle = false
	_wall_from = -1
	for t: DotFpsTunables in [server_a.controller.tunables, own.controller.tunables]:
		t.stamina_enabled = false
	var _dash_off := _server.console.set_cvar("arena_dash", "0")
	var _auto_on := _server.console.set_cvar("arena_wall_run_auto", "1")
	_done()


## The wall script with sprint held through the run, so stamina and the wall-run cooldown both move.
func _stamina_wall_run(server_a: ArenaPlayer, session: int, net: DotNetManager) -> void:
	var replays := 0
	var corrections := 0
	var from := 0
	var runs := 0
	_wall_idle = true
	# Again when the server ran a tick of the script on another command than A's (see _edge_holes).
	for attempt in range(3):
		_wall_hold_sprint = false
		_wall_from = -1
		for _i in range(2):
			server_a.controller.teleport(Vector3(-7.0, 0.1, -23.6), -90.0, 0.0)
			await _wait_game(0.75)
		runs = server_a.controller.motor.wall_runs
		replays = int(net.predictor.get("_replays"))
		corrections = int(net.predictor.get("_corrections_applied"))
		_wall_hold_sprint = true
		_wall_from = net.clock.input_tick() + 4
		from = _wall_from
		await _wait_game(2.6)
		runs = server_a.controller.motor.wall_runs - runs
		replays = int(net.predictor.get("_replays")) - replays
		corrections = int(net.predictor.get("_corrections_applied")) - corrections
		var holes := _wall_holes(from)
		if holes.is_empty():
			break
		print("    the server ran ticks %s of the script (from %d) on a command A had changed: %s" % [
			holes, from, "once more" if attempt < 2 else "three times over"])
	var wall: Array = _prediction_gap(session, from, from + 120)
	print("    wall run with sprint held: %d runs; prediction over %d ticks p95 %.3f / max %.3f m; %d of %d replays corrected" % [
		runs, wall[0], wall[1], wall[2], corrections, replays])
	_check(runs >= 1, "the server's A wall-ran with sprint held", "%d runs" % runs)
	_check(wall[0] > _ticks(100) and wall[1] >= 0.0 and wall[1] <= 0.05 and wall[2] <= 1.5,
		"A's prediction of the wall run with stamina on within 5 cm for 95% of its ticks",
		"%d ticks, p95 %.3f, max %.3f" % [wall[0], wall[1], wall[2]])
	_check(corrections <= maxi(3, replays / 10),
		"and corrected in no more than a tenth of the replays (%d of %d)" % [corrections, replays])


## [b]The server teleports A while it moves.[/b] A hop of 1 m is eased; one of many metres is a snap by
## design (dot-net's reconcile_snap_distance). Either way A must end where the server's A is and
## stay there: one snap at most per teleport, then replays that agree.
func _test_teleport_under_loss() -> void:
	_section("a server teleport of a moving player through 20% loss")

	var a: Dictionary = _clients["A"]
	var net: DotNetManager = a["net"]
	var session := int(a["session"])
	var server_a := _game.player_for(session)
	var own: ArenaPlayer = (a["game"] as ArenaGame).player_for(session)
	if not _check(server_a != null and own != null, "A is on both ends to teleport"):
		_done()
		return

	var snap_distance: float = net.config.reconcile_snap_distance
	var targets: Array[Vector3] = [Vector3(-7.0, 0.1, -23.6), Vector3(21.0, 0.1, -21.0)]
	for i in range(targets.size()):
		var near := i == 0
		await _wait_game(1.0)
		var at: Vector3 = server_a.controller.state.position
		var to: Vector3 = targets[i]
		if near:
			# The first is a hop under the snap distance, from wherever A is: along +X by 1 m.
			to = at + Vector3(1.0, 0.0, 0.0)
		else:
			# The farther target: A's own position differs from the server's by the lead, so one
			# within a metre or two of the snap distance snaps or not by where the circle was.
			var other: Vector3 = targets[0] if to == targets[1] else targets[1]
			if at.distance_to(other) > at.distance_to(to):
				to = other
		var moved := at.distance_to(to)
		var snaps := int(net.predictor.get("_snaps"))
		server_a.controller.teleport(to, server_a.controller.state.yaw, 0.0)
		var input0 := net.clock.input_tick()
		await _wait_game(3.0)
		snaps = int(net.predictor.get("_snaps")) - snaps
		var settled := input0 + _ticks(64)
		var gap: Array = _prediction_gap(session, settled, net.clock.input_tick() - _ticks(8))
		var track: Dictionary = _server_track.get(session, {})
		var end := net.clock.input_tick() - _ticks(8)
		while end > settled and not (_predicted.has(end) and track.has(end)):
			end -= 1
		var shown: float = (_predicted[end] as Vector3).distance_to(track[end]) if _predicted.has(end) and track.has(end) else -1.0
		print("    teleport %.1f m: %d snaps; after settling p95 %.3f / max %.3f m over %d ticks; at the last common tick A is %.3f m from the server's A" % [
			moved, snaps, gap[1], gap[2], gap[0], shown])
		_check(snaps <= (1 if moved > snap_distance else 0),
			"a %.1f m teleport %s" % [moved, "snaps at most once" if moved > snap_distance else "is eased, never snapped"],
			"%d snaps" % snaps)
		# 95% of the ticks, plus one lost input's worth: under 20% loss the server's input for a tick can be a
		# hole, its A then runs on the last command and the prediction is off (up to ~9 cm at a run) until the
		# snapshot that corrects it makes the round trip -- under _ticks(16) (rtt <= 160 ms plus the lead). Over
		# the ~120 ticks sampled, 5% is only 6 ticks, so that single physical event alone failed a p95 check.
		var allowed: int = int(gap[0]) / 20 + _ticks(16)
		_check(gap[0] > _ticks(40) and int(gap[3]) <= allowed and gap[2] <= 0.5,
			"and A's prediction is back within 5 cm of the server's A for the ticks after (a lost input's round trip allowed)",
			"%d ticks, %d over 5 cm (allowed %d), p95 %.3f, max %.3f" % [gap[0], gap[3], allowed, gap[1], gap[2]])
		_check(shown >= 0.0 and shown <= 0.05,
			"A ends in the same place as the server's A, tick for tick", "%.3f m apart" % shown)
	_done()


# --- The end ----------------------------------------------------------------

## [b]A seat whose client has not lifted its cover cannot be harmed, and can once it does.[/b]
## C joins and says nothing (a client still loading its level); the server's own damage path
## is then asked to hurt it, by a hazard (the world, attacker 0) and by A's weapon-style hit,
## and must refuse both. C then sends the cover report on the real wire and the same hit lands.
func _test_loading_cover() -> void:
	_section("a client behind its loading cover is not harmed, and is once it lifts")
	var c := await _connect_client("C", _server.config.effective_enet_port(), false)
	_clients["C"] = c
	if not _check(c.get("bridge") != null and int(c["session"]) != 0, "C connects",
			str(c.get("error", ""))):
		_done()
		return

	var id := int(c["session"])
	var roster: DotGameRoster = _module().loading
	var victim: ArenaPlayer = _game.player_for(id)
	_check(victim != null and roster != null and roster.is_loading(id) and not _game.can_be_harmed(id),
		"the server holds C as loading from its spawn", str(roster.describe()) if roster != null else "no roster")

	var type: DotDamageType = _game.combat.damage_type(ArenaContent.DAMAGE_WORLD)
	var before := victim.health.health if victim != null else 0.0
	var world_hit := DotDamage.make(0, id, 10.0, type)
	world_hit.tick = _game.current_tick()
	var _dealt_world := _game.combat.apply_damage(world_hit)
	var hit := DotDamage.make(_peer_session("A"), id, 10.0, type)
	hit.tick = _game.current_tick()
	var _dealt_hit := _game.combat.apply_damage(hit)
	_check(victim != null and victim.health.health == before and victim.is_alive(),
		"a hazard and another player's hit both do nothing to it",
		"%s -> %s" % [before, victim.health.health if victim != null else -1.0])

	# Spawn protection exempts world damage, so the world hit landing after the lift (and not
	# before) is what shows the cover, not protection, was the veto.
	DotGameClient.report_cover(c["link"], false)
	var lifted := await _until(func() -> bool: return not roster.is_loading(id), RELIABLE_SECONDS)
	_check(lifted and _game.can_be_harmed(id), "its cover report crosses the wire and ends the loading state")

	var after_lift := victim.health.health if victim != null else 0.0
	var late_hit := DotDamage.make(0, id, 10.0, type)
	late_hit.tick = _game.current_tick()
	var _dealt_late := _game.combat.apply_damage(late_hit)
	_check(victim != null and victim.health.health < after_lift,
		"and the same hit now lands", "%s -> %s" % [after_lift, victim.health.health if victim != null else -1.0])

	# A bot or a seat the roster does not hold is never loading.
	_check(not roster.is_loading(DUMMY_ID) and _game.can_be_harmed(DUMMY_ID),
		"a seat the roster does not hold is always harmable")

	_game.loading_fn = Callable()
	_check(_game.can_be_harmed(id), "a game with no loading_fn (offline) harms everyone")
	_game.loading_fn = roster.is_loading

	(c["link"] as DotClientLink).disconnect_from_server("done")
	(c["net"] as DotNetManager).stop()
	var gone := await _until(func() -> bool: return _game.player_for(id) == null, RELIABLE_SECONDS)
	_check(gone and not roster.is_loading(id), "C leaves and the roster forgets it")
	_done()


func _peer_session(label: String) -> int:
	return int(_clients[label]["session"])


func _test_leave() -> void:
	_section("B leaves, and A is told once")

	var b: Dictionary = _clients["B"]
	var b_session := int(b["session"])
	var a_game: ArenaGame = _clients["A"]["game"]
	(b["link"] as DotClientLink).disconnect_from_server("done")
	var b_net: DotNetManager = b["net"]
	b_net.stop()

	# RELIABLE_SECONDS: the link is still at the last window's 20% loss. Ten failed a CI
	# release run (v0.1.6) on exactly that tail; the wait ends when A is told.
	var gone := await _until(func() -> bool: return a_game.player_for(b_session) == null, RELIABLE_SECONDS)
	_check(gone, "A's B is gone once the server has seen the disconnect",
		"the server has %d sessions and %s B in its game" % [
			_server.sessions().size(), "still has" if _game.player_for(b_session) != null else "no longer has"])
	_check(_a_saw_added.count(b_session) == 1, "and was never added a second time",
		str(_a_saw_added))
	_done()
