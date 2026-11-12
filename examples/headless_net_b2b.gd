extends "headless_net_b2.gd"

## A drawing client's event budget: a backlog past it waits for later frames, then lands whole and in order.
func _test_event_budget() -> void:
	print("")
	_section("[events over a frame budget]")
	var sent: Array[PackedByteArray] = []
	var bridge := ArenaNetBridge.new()
	bridge.name = "BudgetBridge"
	add_child(bridge)
	var game := _make_game(true)
	var net := _make_manager(true, &"budget", 1)
	var _attached := bridge.attach(game, net)
	_start(net)
	var link := bridge.open_link(bridge)
	link.loopback = func(method: StringName, peer: int, payload: PackedByteArray) -> void:
		if method == &"event" and peer == 77:
			sent.append(payload)
	bridge.mark_ready(77)
	var _seated := bridge.add_player(77, 701, "First")
	var expected: Array[int] = [701]
	for i in 5:
		var _joined := bridge.add_player(80 + i, 710 + i, "Joiner %d" % i)
		expected.append(710 + i)

	var watcher := ArenaNetBridge.new()
	watcher.name = "BudgetWatcher"
	watcher.event_budget_usec = 1
	add_child(watcher)
	var watcher_game := _make_game(false)
	var watcher_net := _make_manager(false, &"budgetwatch", 77)
	var _watching := watcher.attach(watcher_game, watcher_net)
	_start(watcher_net)
	var order: Array[int] = []
	watcher_game.player_added.connect(func(added: ArenaPlayer) -> void: order.append(added.player_id))
	for payload in sent:
		var _got := watcher.receive_event(payload)
	_check(sent.size() >= 6 and watcher.events_waiting() > 0 and order.size() < expected.size(),
		"a backlog past the frame budget waits for later frames",
		"%d sent, %d waiting, %d joined" % [sent.size(), watcher.events_waiting(), order.size()])
	var frames := 0
	while watcher.events_waiting() > 0 and frames < 120:
		await get_tree().process_frame
		frames += 1
	_check(watcher.events_waiting() == 0 and order == expected and frames > 1,
		"and every event lands over the frames that follow, in arrival order",
		"%d frames, joined %s" % [frames, str(order)])

	for node: Node in [watcher, watcher_game, watcher_net, bridge, game, net]:
		node.queue_free()
	_done()


func _test_predicted_node_is_not_moved() -> void:
	print("")
	_section("[the predicted entity's node]")

	# `DotNetManager.receive_snapshot` calls `read_state` — and therefore `_net_state_applied` —
	# BEFORE `DotNetPredictor.reconcile`, and the first thing reconcile does is read the node as
	# "what the client is showing" so it can measure the correction.
	var behaviour := (_clients[2]["bridge"] as ArenaNetBridge).behaviour_for(11)

	if not _check(behaviour != null, "the local player's behaviour is found"):
		return

	var player := behaviour.player
	var predicted := behaviour.identity != null and behaviour.identity.is_predicted()

	_check(predicted, "and the local player is predicted, not server-driven")

	# Put the node somewhere the state is not, then hand the behaviour a state applied.
	var parked := Vector3(123.0, 4.0, 56.0)
	player.global_position = parked
	behaviour.net_position = Vector3(7.0, 0.0, 7.0)
	behaviour._net_state_applied((_clients[2]["net"] as DotNetManager).clock.tick)

	_check(
		player.global_position.is_equal_approx(parked),
		"applying state does NOT move a predicted player's node",
		str(player.global_position)
	)

	# The remote player is the other half, and it must move: its node is driven by
	# nothing else, so a guard that skipped it would leave every remote player standing
	# where they spawned.
	var remote := (_clients[2]["bridge"] as ArenaNetBridge).behaviour_for(12)

	if not _check(remote != null, "the remote player's behaviour is found"):
		return

	_check(
		remote.identity == null or not remote.identity.is_predicted(),
		"and the remote player is not predicted"
	)

	remote.player.global_position = parked
	remote.net_position = Vector3(3.0, 0.0, 3.0)
	remote._net_state_applied((_clients[2]["net"] as DotNetManager).clock.tick)

	_check(
		not remote.player.global_position.is_equal_approx(parked),
		"applying state DOES move a remote player's node",
		str(remote.player.global_position)
	)
	_done()


func _test_config_agreement() -> void:
	print("")
	_section("[the two ends agree]")

	# **A quantised value decoded against a different range is a different value, not a less precise
	# one.** `world_extent` is the range every replicated position is an integer over, and the
	# server and the client wrote it separately — 128 in `ArenaModule`.
	_check(
		is_equal_approx(_server_net.config.world_extent, ArenaGame.NET_WORLD_EXTENT),
		"the server quantises positions over the game's extent",
		"%.1f" % _server_net.config.world_extent
	)

	for peer_id in _clients:
		var net: DotNetManager = _clients[peer_id]["net"]

		_check(
			is_equal_approx(net.config.world_extent, _server_net.config.world_extent),
			"and client %d over the same one" % peer_id,
			"%.1f vs %.1f" % [net.config.world_extent, _server_net.config.world_extent]
		)

		# The tick rate is the other number the two ends must not disagree about, and the one this family has
		# already paid for: a client counting at its own rate against a 128-tick server read a 0.218 s finish
		# as 0.466 s and never converged. HELLO carries it; `_adopt_tick_rate` is what applies it.
		_check(
			net.config.tick_rate == _server_net.config.tick_rate,
			"and counts at the same rate",
			"%d vs %d" % [net.config.tick_rate, _server_net.config.tick_rate]
		)

	# The schema hash is the third. Peers that registered different message types, or in a
	# different order, hash differently (`Array.sort()` on a StringName sorts by pointer).
	var server_hash := _server_net.messages.schema_hash()

	for peer_id in _clients:
		var net: DotNetManager = _clients[peer_id]["net"]

		_check(
			net.messages.schema_hash() == server_hash,
			"and client %d sealed the same message schema" % peer_id,
			"%s vs %s" % [net.messages.schema_hash(), server_hash]
		)
	_done()


## Counts the engine's own errors while installed (mg-smash-copter's dedicated suite has the
## same class): they go to stderr and change no exit code, so only this makes one fail a run.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append("%s (%s)" % [code, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out


## dot-map's announce/ready/load protocol, over this game's own link: two [ArenaNetLink]s, a
## real [DotMapSyncHost] and [DotMapSyncClient], payloads through the same `send_map` a socket
## would use. dot-map's own suite only runs a loopback `send_fn`.
func _test_map_sync_wire() -> void:
	print("")
	_section("[map sync over the link]")

	var server_link := ArenaNetLink.attached_to(self, _server_bridge, true)
	add_child(server_link)
	server_link.name = "MapServerLink"

	var client_entry: Dictionary = _clients[_clients.keys()[0]]
	var client_bridge: ArenaNetBridge = client_entry["bridge"]
	var client_link := ArenaNetLink.attached_to(self, client_bridge, false)
	add_child(client_link)
	client_link.name = "MapClientLink"

	# Both loopbacks, crossed. `send_map` refuses to fall through to an RPC when the byte loopback is set,
	# so a harness that wired one and not the other would get a silent no-op rather than a crash — which is
	# why the counters are asserted below rather than only the outcome.
	server_link.loopback = func(_m: StringName, _p: int, _b: PackedByteArray) -> void: pass
	client_link.loopback = func(_m: StringName, _p: int, _b: PackedByteArray) -> void: pass

	server_link.loopback_map = func(m: StringName, peer: int, payload: Dictionary) -> void:
		client_link.deliver_map(m, peer, payload)

	client_link.loopback_map = func(m: StringName, _peer: int, payload: Dictionary) -> void:
		server_link.deliver_map(m, 2, payload)

	var catalogue := ArenaMaps.catalogue()

	var session := ArenaMapSession.new()
	session.name = "MapSession"
	session.game = _server_game
	session.catalogue = catalogue
	add_child(session)

	var host := DotMapSyncHost.new()
	host.name = "MapHost"
	host.session = session
	host.sync_timeout_sec = 5.0
	host.send_fn = func(peer: int, payload: Dictionary) -> void:
		server_link.send_map(peer, payload)
	add_child(host)

	# The FOLLOWER needs a catalogue too: `DotMapSyncClient` accepts an announced map only if
	# it is in its own catalogue at the same version, else it refuses with "a host may not
	# send a map that is not delivered content".
	var client_game: ArenaGame = client_entry["game"]

	var follower_session := ArenaMapSession.new()
	follower_session.name = "FollowerSession"
	follower_session.game = client_game
	follower_session.catalogue = ArenaMaps.catalogue()
	add_child(follower_session)

	var follower := DotMapSyncClient.new()
	follower.name = "MapFollower"
	follower.session = follower_session
	follower.accept_unknown_maps = true
	follower.send_fn = func(payload: Dictionary) -> void:
		client_link.send_map_report(payload)
	add_child(follower)

	# One argument. `DotMapSyncClient.changed` carries the map and nothing else, unlike
	# `DotMapSession.changed`, which carries the world as well.
	# A client set up on the map the server then announces first (a sim host's) keeps the world it built.
	var combat_before := client_game.combat
	var same: DotResult = await follower_session.change_to_map(catalogue.get_map(client_game.map.id))
	_check(
		same.ok and follower_session.current != null and client_game.combat == combat_before,
		"a first announcement of the client's own map keeps the world it was set up with",
		str(same.error) if not same.ok else String(client_game.map.id)
	)

	var loads: Array[StringName] = []
	follower.changed.connect(func(map: DotMapDef) -> void: loads.append(map.id))

	_server_bridge.map_report_fn = func(peer: int, payload: Dictionary) -> void:
		host.handle(peer, payload)

	client_bridge.map_in_fn = func(payload: Dictionary) -> void:
		follower.handle(payload)

	host.add_peer(2)

	var target: StringName = &"dm_atrium" if _server_game.map.id == &"dm_box" else &"dm_box"
	var changed: DotResult = await host.change_to(target)

	_check(changed.ok, "the server changes map with a peer following", str(changed.error))
	_check(
		server_link.map_sent > 0,
		"announcements went out on the link",
		"%d" % server_link.map_sent
	)
	_check(
		client_link.map_received > 0,
		"and the client received them",
		"%d" % client_link.map_received
	)

	# The report going back is the half that makes the wait mean anything. Without it the host waits out its
	# whole timeout and swaps without the client — which `swap_without_stragglers` permits, so the change
	# would still "work" and the peer would still be on the old map.
	_check(
		server_link.map_received > 0,
		"the client reported back, so the host did not wait out its timeout",
		"%d" % server_link.map_received
	)

	_check(loads.has(target), "and the client was told to load the new map")
	_check(_server_game.map.id == target, "the server is on it")
	_check(
		client_game.map.id == target,
		"and so is the client, having rebuilt the world itself",
		String(client_game.map.id)
	)

	# The player's position is the server's and the client has to follow: a map change respawns
	# everybody on the authority and only rebuilds geometry on a mirror, so this checks the
	# predictor adopts the server's state over the same one-in-five loss.
	var peer: int = _clients.keys()[0]
	var session_id := int(client_entry["session"])
	var on_server: ArenaPlayer = _server_bridge.behaviour_for(session_id).player
	var on_client: ArenaPlayer = client_bridge.behaviour_for(session_id).player
	var respawned_at := on_server.controller.state.position
	var nearest := INF

	for spawn in _server_game.map.spawns:
		nearest = minf(nearest, spawn.origin.distance_to(respawned_at))

	_check(
		nearest < 0.5,
		"the server put this client's player at a spawn of the new map",
		"%.1f m from the nearest" % nearest
	)

	var _follow := _flight_window(peer, 48, 0)
	var gap := on_client.controller.state.position.distance_to(
		on_server.controller.state.position
	)
	_check(
		gap < 0.1 and on_client.global_position.distance_to(on_server.controller.state.position) < 0.1,
		"and the client's predicted player followed the respawn, in the state and on the node",
		"%.2f m apart in the state, %.2f on the node" % [
			gap, on_client.global_position.distance_to(on_server.controller.state.position)
		]
	)

	# The same wire onto an imported combat surf map, and back.
	if ArenaMap.imported_ids().has(IMPORTED_MAP):
		await _follow_onto_imported(host, client_game, client_entry, peer, target)
	else:
		print("  skip  no imported maps linked (arena-surf-dm-maps); %d checks not run" % IMPORTED_CHECKS)
		_skipped_checks += IMPORTED_CHECKS

	host.queue_free()
	follower.queue_free()
	follower_session.queue_free()
	remove_child(follower_session)
	session.queue_free()
	server_link.queue_free()
	client_link.queue_free()
	remove_child(host)
	remove_child(follower)
	remove_child(session)
	remove_child(server_link)
	remove_child(client_link)
	_done()
