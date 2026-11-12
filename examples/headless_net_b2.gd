extends "headless_net_b1.gd"

func _test_command_wire() -> void:
	print("")
	_section("[command wire]")

	var move := DotFpsCommand.new()
	move.move = Vector2(0.6, -0.4)
	move.yaw = 137.5
	move.pitch = -12.0
	move.set_button(DotFpsCommand.BUTTON_JUMP, true)

	var fire := DotWeaponCommand.new()
	fire.slot = 2
	fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)

	var sent := ArenaNetCommand.new()
	sent.tick = 4242
	sent.delta = 1.0 / float(TICK_RATE)
	sent.move = move
	sent.fire = fire

	var writer := DotNetWriter.new()
	sent.write(writer)

	var got := ArenaNetCommand.new()
	got.read(DotNetReader.new(writer.to_bytes()))

	_check(got.tick == 4242, "the tick survives the wire")
	_check(got.move.move.distance_to(move.move) < 0.01, "the move vector survives")
	_check(absf(got.move.yaw - move.yaw) < 0.2, "the yaw survives", str(got.move.yaw))
	_check(got.move.is_pressed(DotFpsCommand.BUTTON_JUMP), "jump survives")
	_check(got.fire.slot == 2, "the weapon slot survives")
	_check(got.fire.is_pressed(DotWeaponCommand.BUTTON_ATTACK), "attack survives")
	_check(
		absf(got.fire.yaw - got.move.yaw) < 0.001,
		"the aim is the movement's, not a second copy"
	)

	# Lag compensation's one field: how far behind the command's tick the client drew
	# everybody, in quarter ticks. Sent only with a button down.
	sent.view_lag_q = 37
	var lagged := DotNetWriter.new()
	sent.write(lagged)
	var got_lag := ArenaNetCommand.new()
	got_lag.read(DotNetReader.new(lagged.to_bytes()))
	_check(got_lag.view_lag_q == 37 and absf(got_lag.view_lag_ticks() - 9.25) < 0.001,
		"the view lag survives the wire (%d quarter ticks)" % got_lag.view_lag_q)
	var idle := ArenaNetCommand.new()
	idle.view_lag_q = 37
	var quiet := DotNetWriter.new()
	idle.write(quiet)
	var got_idle := ArenaNetCommand.new()
	got_idle.read(DotNetReader.new(quiet.to_bytes()))
	_check(got_idle.view_lag_q == -1 and quiet.to_bytes().size() < lagged.to_bytes().size(),
		"and a command with no button down sends none (%d bytes against %d)" % [quiet.to_bytes().size(), lagged.to_bytes().size()])

	# The one thing quantisation cannot bound: a legal pair of components with an
	# illegal length. Diagonal at full deflection is 41% more speed than anyone else.
	var cheat := ArenaNetCommand.new()
	cheat.move = DotFpsCommand.new()
	cheat.move.move = Vector2(1.0, 1.0)
	cheat.fire = DotWeaponCommand.new()
	cheat.sanitise(TICK_RATE)
	_check(
		cheat.move.move.length() <= 1.001,
		"a diagonal cannot outrun a straight line",
		str(cheat.move.move.length())
	)

	var greedy := ArenaNetCommand.new()
	greedy.move = DotFpsCommand.new()
	greedy.fire = DotWeaponCommand.new()
	greedy.delta = 10.0
	greedy.sanitise(TICK_RATE)
	_check(greedy.delta <= 2.0 / float(TICK_RATE), "a ten-second tick is refused")
	_done()


func _test_convergence() -> void:
	print("")
	_section("[convergence]")

	# The clients fired every eighth tick through encode_input, so the server rewound for
	# their shots: a real client measures how far behind it draws everybody and says so.
	var rewinds := int(_server_game.combat.describe().get("rewinds", 0))
	_check(rewinds > 0, "the server rewound for the clients' shots (%d)" % rewinds)

	for peer_id in _clients:
		var entry: Dictionary = _clients[peer_id]
		var net: DotNetManager = entry["net"]
		_check(
			net.stats.packets_received > 0,
			"client %d received snapshots" % peer_id,
			str(net.stats.packets_received)
		)
		_check(net.stats.decode_failures == 0, "client %d had no decode failures" % peer_id)

	# Every client's copy of every player has to track the server. A client that got
	# only the first peer's updates — the shape of dot-net's replication bug — passes
	# half of these and fails the other half.
	for peer_id in _clients:
		var bridge: ArenaNetBridge = _clients[peer_id]["bridge"]

		for other_peer in _clients:
			var session := int(_clients[other_peer]["session"])
			var mine: ArenaPlayerNet = bridge.behaviour_for(session)
			var theirs: ArenaPlayerNet = _server_bridge.behaviour_for(session)

			_check(mine != null and theirs != null, "client %d has player %d" % [peer_id, session])

			if mine == null or theirs == null:
				continue

			var apart := mine.player.controller.state.position.distance_to(
				theirs.player.controller.state.position
			)
			_check(
				apart < 1.5,
				"client %d tracks player %d within 1.5 m" % [peer_id, session],
				"%.2f m apart" % apart
			)

	var server_moved := _server_bridge.behaviour_for(11).player.controller.state.position
	_check(server_moved.length() > 1.0, "the server actually simulated movement",
		str(server_moved))
	_done()


func _test_acks_and_recovery() -> void:
	print("")
	_section("[acknowledgements]")

	for peer_id in _clients:
		_check(
			_server_net.peer_acks_wired(peer_id),
			"peer %d's acknowledgements are arriving" % peer_id
		)

	# A value that changes rarely is the one acknowledgements exist for: a position is
	# repaired by the next snapshot, health is not.
	var victim: ArenaPlayerNet = _server_bridge.behaviour_for(11)
	victim.player.health.health = maxf(1.0, victim.player.health.health - 37.0)

	for tick in range(RUN_TICKS + 1, RUN_TICKS + 41):
		for peer_id in _clients:
			var pair := _commands_for(peer_id, tick)
			var packet: PackedByteArray = _clients[peer_id]["bridge"].encode_input(
				tick, pair[0], pair[1]
			)
			_drop_up += 1
			if _drop_up % LOSS_EVERY != 0:
				_server_bridge.receive_input(peer_id, packet)

		_server_bridge.server_tick(tick)

		for entry_down in _downstream:
			var peer: int = entry_down["peer"]
			var targets: Array = _clients.keys() if peer == 0 else [peer]
			for target in targets:
				if _clients.has(target):
					_clients[target]["bridge"].receive_snapshot(entry_down["bytes"])
		_downstream.clear()

		for peer_id in _clients:
			_clients[peer_id]["net"].clock.tick = tick
			var pair2 := _commands_for(peer_id, tick)
			_clients[peer_id]["bridge"].client_tick(tick, pair2[0], pair2[1])

	var authoritative := int(ceil(victim.player.health.health))

	for peer_id in _clients:
		var seen: ArenaPlayerNet = _clients[peer_id]["bridge"].behaviour_for(11)
		_check(
			absi(seen.net_health - authoritative) <= 1,
			"client %d has the right health for player 11" % peer_id,
			"saw %d, server has %d" % [seen.net_health, authoritative]
		)

	_check(
		_server_net.stats.packets_sent > 0 and _clients[3]["net"].stats.snapshots_lost > 0,
		"loss was real",
		"client 3 lost %d" % _clients[3]["net"].stats.snapshots_lost
	)
	_done()


## What a player carries reaches their own client, what they hold reaches everybody, the use counter
## crosses, a replayed tick is silent, and a launch flies on a client.
func _test_weapons_over_the_wire() -> void:
	print("")
	_section("[weapons over the wire]")

	_pump(16)

	var owner: ArenaNetBridge = _clients[2]["bridge"]
	var watcher: ArenaNetBridge = _clients[3]["bridge"]
	var served := _server_bridge.behaviour_for(11).player
	var own := owner.behaviour_for(11)
	var seen := watcher.behaviour_for(11)

	# The earlier sections fire this sidearm dry (a magazine, no auto-reload); a dry gun uses nothing and shows 0.
	for who: ArenaPlayer in [served, own.player]:
		who.arsenal.current().magazine = who.arsenal.current().def.magazine

	var server_mask := ArenaContent.carry_mask(served.arsenal)
	_check(server_mask != 0, "the server's player carries weapons", str(server_mask))
	_check(
		ArenaContent.carry_mask(own.player.arsenal) == server_mask,
		"and their own client's arsenal carries exactly the same",
		"%d against %d" % [ArenaContent.carry_mask(own.player.arsenal), server_mask]
	)
	_check(
		own.player.arsenal.current_slot() == served.arsenal.current_slot(),
		"holding the same slot", "%d against %d" % [
			own.player.arsenal.current_slot(), served.arsenal.current_slot()
		]
	)
	_check(
		ArenaHud.rounds_in_hand(own.player) > 0,
		"so the owner's HUD counts real ammunition, where it read zero",
		str(ArenaHud.rounds_in_hand(own.player))
	)
	_check(
		seen.net_carry == 0,
		"while the other client never receives what player 11 carries",
		str(seen.net_carry)
	)

	var held := served.arsenal.current_def().id if served.arsenal.current_def() != null else &""
	_check(
		seen.player.mirrored and seen.player.mirror_weapon == held and held != &"",
		"but does see what is in their hand", "%s against %s" % [seen.player.mirror_weapon, held]
	)

	# The counter: everybody fires every eighth tick in this run.
	var before := seen.player.mirror_fire_seq
	_pump(32)
	_check(
		seen.player.mirror_fire_seq != before,
		"a use moves the counter the watcher reads",
		"%d then %d" % [before, seen.player.mirror_fire_seq]
	)

	# A replay is silent. Put the rig back to before a firing tick and run that tick
	# again through the behaviour, the way the predictor's reconcile does.
	var uses: Array[DotWeaponOutcome] = []
	own.player.used.connect(func(o: DotWeaponOutcome) -> void: uses.append(o))

	var idle := ArenaNetCommand.new()
	var shoot := ArenaNetCommand.new()
	shoot.fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)
	shoot.fire.slot = 0

	var t := int(_clients[2]["net"].clock.tick)
	for i in range(TICK_RATE):
		t += 1
		own._net_apply_input(idle, t)
		own._net_simulate(t, 1.0 / float(TICK_RATE))

	# Anything the idle ticks drew (the sidearm's own follow-up) is not this shot.
	var drawn_before := uses.size()
	var rewind := own.player.weapons.snapshot()
	t += 1
	own._net_apply_input(shoot, t)
	own._net_simulate(t, 1.0 / float(TICK_RATE))
	var fresh := uses.size()
	_check(fresh - drawn_before == 1, "a fresh predicted shot is drawn", str(fresh - drawn_before))

	var _restored := own.player.weapons.restore(rewind)
	_check(own.is_replay(t), "the same tick again is known to be a replay")
	own._net_apply_input(shoot, t)
	own._net_simulate(t, 1.0 / float(TICK_RATE))
	_check(
		uses.size() == fresh,
		"and replaying it draws nothing — once per shot, not once per correction",
		"%d uses after the replay" % uses.size()
	)

	_test_launch_flies_on_client(own)
	_done()


## A launch the server announces flies on a client, and hurts nobody there.
func _test_launch_flies_on_client(own: ArenaPlayerNet) -> void:
	var client_game: ArenaGame = _clients[2]["game"]
	var gone: Array = []
	client_game.projectiles.detonated.connect(func(at: Vector3, _s: DotWeaponSpawn) -> void:
		gone.append(at)
	)
	var spawn := DotWeaponSpawn.make(
		AwWeaponIds.FRAG, own.player.controller.state.position + Vector3(0.0, 1.5, 0.0),
		Vector3(0.0, 3.0, -6.0), 12
	)
	spawn.gravity_scale = 1.0
	spawn.fuse_ticks = 24
	spawn.life_ticks = 400
	spawn.tick = _server_game.current_tick()

	var wire := ArenaEvents.write_launch(spawn, ArenaContent.weapon_index(spawn.id))
	var read := ArenaEvents.read_launch(DotNetReader.new(wire))
	_check(
		bool(read["ok"]) and int(read["fuse"]) == 24 and int(read["owner"]) == 12
		and ArenaContent.weapon_at(int(read["weapon"])) == AwWeaponIds.FRAG
		and (read["velocity"] as Vector3).distance_to(spawn.velocity) < 0.01,
		"a LAUNCH round-trips: who, which weapon, how fast, the fuse"
	)

	var health_before := own.player.health.health
	_deliver_event(2, ArenaEvents.Kind.LAUNCH, wire)
	_check(client_game.projectiles.live_count() == 1, "the client flies a copy of it")
	_pump(32)
	_check(gone.size() == 1, "which goes off on its fuse there", str(gone.size()))
	_check(
		own.player.health.health == health_before,
		"and decides nothing: the client's copy hurts nobody"
	)


## Players are solid to each other (`mp_solidplayers`, 1 by default): a walk into another player
## stops two radii apart on the server, and the walker's own client predicts the same stop. Then, at
## 0 on both ends (the cvar is replicated), the same walk passes through.
func _test_solid_players_predicted() -> void:
	print("")
	_section("[players are solid, and predicted so]")

	var session_a := int(_clients[2]["session"])
	var session_b := int(_clients[3]["session"])
	var server_a: ArenaPlayer = _server_bridge.behaviour_for(session_a).player
	var server_b: ArenaPlayer = _server_bridge.behaviour_for(session_b).player
	var client_game: ArenaGame = (_clients[2]["bridge"] as ArenaNetBridge).game
	var radius := server_a.controller.tunables.radius
	var two_radii := radius * 2.0

	_check(
		_server_game.body_rules.solid and client_game.body_rules.solid,
		"players are solid by default on the server and on a client"
	)

	# A lane of open floor along -z, found with the map's own trace rather than assumed:
	# the first try stood the two on a stair block's edge and measured the stairs.
	var trace := _server_game.map.shot_trace()
	var lane_x := NAN
	for step in range(0, 41):
		var x := -20.0 + float(step)
		var open := true
		for dx in [-0.5, 0.0, 0.5]:
			for y in [0.3, 1.0, 1.7]:
				if trace.ray(Vector3(x + dx, y, 20.0), Vector3(0, 0, -1), 14.0).ok():
					open = false
		if open:
			lane_x = x
			break
	if not _check(not is_nan(lane_x), "the map has a lane of open floor to walk"):
		_done()
		return
	var saved_a := server_a.controller.state.position
	var saved_b := server_b.controller.state.position

	var idle := DotFpsCommand.new()
	var walk := DotFpsCommand.new()
	walk.move = Vector2(0.0, 1.0)
	walk.yaw = 0.0
	var place := func() -> void:
		server_a.controller.teleport(Vector3(lane_x, 0.1, 19.0), 0.0)
		server_b.controller.teleport(Vector3(lane_x, 0.1, 13.0), 0.0)
		var _settle := _flight_window(0, 24, 0, {2: idle, 3: idle})

	place.call()
	var c := {"server_a": server_a, "server_b": server_b, "client_game": client_game, "place": place,
		"walk": walk, "idle": idle, "lane_x": lane_x, "two_radii": two_radii, "session_a": session_a}
	_solid_walk_checks(c)
	_solid_lag_checks(c)
	_solid_off_checks(c)
	_solid_team_checks(c)
	server_a.controller.teleport(saved_a)
	server_b.controller.teleport(saved_b)
	var _back := _flight_window(0, 24, 0)
	_done()


func _test_ready_gate() -> void:
	print("")
	_section("[the ready gate]")

	# **Nothing may be sent to a peer before it says it can receive.** dot-server's signon finishes
	# and THEN the client builds its scene, so everything sent in between lands on a node that does
	# not exist and is lost — one "Node not found" per call.
	var sent: Array = []
	var bridge := ArenaNetBridge.new()
	bridge.name = "GateBridge"
	add_child(bridge)

	var game := _make_game(true)
	var net := _make_manager(true, &"gate", 1)
	_check(bridge.attach(game, net).ok, "a gate bridge attaches")
	_start(net)

	var link := bridge.open_link(bridge)
	link.loopback = func(method: StringName, peer: int, payload: PackedByteArray) -> void:
		sent.append([method, peer, payload.size(), payload])

	bridge.send_event(77, ArenaEvents.Kind.NOTICE, ArenaEvents.write_notice("early"))
	_check(sent.is_empty(), "an event to a peer that has not said READY is dropped")

	# [b]A READY before the seat is kept, and the seat answers it.[/b] Over ENet with loss a
	# client's READY can overtake the link's `loaded` (another channel) and so its seat; answered
	# at once, its HELLO named session 0 and the client never knew which body was its own.
	bridge.mark_ready(77)
	_check(sent.is_empty(), "a READY before the seat is kept: nothing is sent yet", str(sent.size()))
	var early := bridge.add_player(77, 577, "Early")
	var watcher := ArenaNetBridge.new()
	watcher.name = "GateWatcher"
	add_child(watcher)
	var watcher_game := _make_game(false)
	var watcher_net := _make_manager(false, &"gatewatch", 77)
	var _attached := watcher.attach(watcher_game, watcher_net)
	_start(watcher_net)
	for s: Array in sent:
		if s[0] == &"event" and int(s[1]) == 77:
			var _got: DotResult = watcher.receive_event(s[3])
	var hello: Dictionary = watcher.get("_hello")
	_check(early.ok and int(hello.get("session_id", 0)) == 577 and watcher_game.player_for(577) != null,
		"and the seat answers it: the HELLO names the player seated, and the signon describes them",
		"hello %s" % str(hello))
	watcher.queue_free()
	watcher_game.queue_free()
	watcher_net.queue_free()
	var after_ready: int = sent.size()

	bridge.send_event(77, ArenaEvents.Kind.NOTICE, ArenaEvents.write_notice("late"))
	_check(sent.size() > after_ready, "and later events reach it")

	# A broadcast goes to ready peers only, which is the same rule stated the other way.
	sent.clear()
	bridge.send_event(0, ArenaEvents.Kind.NOTICE, ArenaEvents.write_notice("all"))
	_check(sent.size() == 1, "a broadcast reaches exactly the ready peers", str(sent.size()))

	# [b]A player who joins later is announced to everybody already in.[/b] Only the READY
	# signon ever sent a JOIN, so a client never learned of anybody who arrived after it.
	sent.clear()
	var late := bridge.add_player(88, 588, "Late")
	# Peer 88 itself is sent dot-net's message schema here, which is not this.
	var to_ready := sent.filter(func(s: Array) -> bool: return int(s[1]) == 77)
	_check(
		late.ok and to_ready.size() == 1,
		"a later joiner is announced to the peers already in",
		str(to_ready.size())
	)

	# A READY from a peer that left before its seat is forgotten, or the next owner of that
	# peer id would be sent a signon before it asked.
	bridge.mark_ready(99)
	bridge.remove_peer(99)
	var _again := bridge.add_player(99, 599, "Reused")
	_check(not bridge.get("_ready_peers").has(99), "a READY from a peer that left before its seat is forgotten")

	bridge.queue_free()
	game.queue_free()
	net.queue_free()
	_done()
