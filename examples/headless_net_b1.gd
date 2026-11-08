extends "headless_net_solid.gd"

func _test_owner_only() -> void:
	print("")
	_section("[audience]")

	# Client 2 owns player 11 and observes player 12. Ammunition is owner-only, so it
	# must know its own and not the other's — data never sent cannot be read out of a
	# modified client.
	var bridge: ArenaNetBridge = _clients[2]["bridge"]
	var own: ArenaPlayerNet = bridge.behaviour_for(11)
	var other: ArenaPlayerNet = bridge.behaviour_for(12)

	var declaration := own.find_var(&"net_magazine")
	_check(
		declaration != null and declaration.audience == DotNetVar.Audience.OWNER,
		"ammunition is declared owner-only"
	)
	_check(
		other.net_magazine == 0,
		"and an opponent's is never received",
		"received %d" % other.net_magazine
	)
	# That the owner's own ammunition arrives is asserted in [weapons over the wire]: it
	# could not be while a client's arsenal was empty, because nothing sent what a
	# player carries and the predicted `pull()` overwrote what arrived with a zero.
	_check(other.net_health > 0, "while an opponent's health does arrive",
		str(other.net_health))
	_done()


## A player dies and THEIR CLIENT draws the death camera, then hands it over.
func _test_client_death_camera() -> void:
	print("")
	_section("[the death camera on a client]")

	var client: Dictionary = _clients[2]
	var client_game: ArenaGame = client["game"]
	var victim := 11
	var killer := 12

	# The map change before this restarted the match: its warmup is seconds, so at a low tick rate it ends (and
	# respawns everybody) in the middle of the chain. Let the round go live first, at every rate.
	var waited_live := 0
	while not _server_game.match_node.is_live() and waited_live < 4000:
		_pump(10)
		waited_live += 10

	# Nobody respawns inside the chain, so every check below measures the chain.
	_server_game.match_node.rules.respawn_delay_sec = 60.0

	var health := _server_game.combat.health_of(victim)
	health.invulnerable_until_tick = -1
	var damage := DotDamage.make(killer, victim, health.health + health.armour + 50.0, _server_game.combat.damage_type(&""))
	damage.tick = _server_game.current_tick()
	var applied := health.apply(damage)
	_server_game.combat.entity_killed.emit(victim, applied)
	_pump(2)

	var fell := client_game.player_for(victim).controller.state.position

	# The KILL event, encoded by the server's registry and received by the client's the way
	# a link delivers it. The harness carries snapshots and not events.
	var writer := DotNetWriter.new()
	var _enc := _server_net.messages.encode(
		ArenaEvent.new(ArenaEvents.Kind.KILL, ArenaEvents.write_kill(killer, victim, "rifle", false)),
		writer
	)
	var _got := (client["bridge"] as ArenaNetBridge).receive_event(writer.to_bytes())

	_check(
		client_game.spectate != null and client_game.spectate.is_spectating(victim),
		"a dead player's own client is watching something rather than lying on the floor"
	)
	var eye := client_game.spectate.camera_for(victim) if client_game.spectate != null else Transform3D.IDENTITY
	_check(
		eye != Transform3D.IDENTITY and Vector2(eye.origin.x - fell.x, eye.origin.z - fell.z).length() < 0.5,
		"from where they fell on that client", "%s against %s" % [eye.origin, fell]
	)

	_pump(TICK_RATE * 3)
	var view := client_game.spectate.manager.view(str(victim)) if client_game.spectate != null else DotSpectatorView.new()
	_check(
		view.mode == DotSpectatorView.Mode.FIRST_PERSON or view.mode == DotSpectatorView.Mode.CHASE,
		"and the chain hands over on the client rather than holding the death camera",
		DotSpectatorView.Mode.keys()[view.mode]
	)
	_check(view.target == str(killer), "to the one other player", view.target)
	_check(
		client_game.spectate.camera_for(victim).origin.distance_to(
			client_game.player_for(killer).controller.state.position
		) < 3.0,
		"and the camera is on them"
	)

	# The server brings them back (its respawn, called directly: when it would is dot-match's business).
	# Under test is the client reading "alive again" off the replicated health, having heard no spawn.
	_server_game.player_for(victim).spawn(_server_game.map.spawns[0], _server_game.current_tick())
	_server_game.player_for(victim).give_default_loadout()
	_pump(TICK_RATE)
	_check(
		client_game.player_for(victim).is_alive() and not client_game.spectate.is_spectating(victim),
		"and the client stops watching once the server has them alive again",
		"alive=%s watching=%s server alive=%s" % [client_game.player_for(victim).is_alive(), client_game.spectate.is_spectating(victim), _server_game.player_for(victim).is_alive()]
	)
	_done()


## A real kill on the server: the hit goes to the attacker's client alone and the medals
## to everybody, and a client's bridge hands each to whoever draws it.
func _test_hits_and_medals_reach_clients() -> void:
	print("")
	_section("[hits and medals reach the right clients]")

	var killer := 12
	var victim := 11
	var killer_peer := 3
	var sent: Array = []
	var previous := _server_bridge.link
	var link := _capture_link(sent)
	sent.clear()

	var heard := {}
	for peer in _clients:
		heard[peer] = {"hits": [], "awards": []}
		var bridge: ArenaNetBridge = _clients[peer]["bridge"]
		var mine: Dictionary = heard[peer]
		bridge.hit_received.connect(func(info: Dictionary) -> void: (mine["hits"] as Array).append(info))
		bridge.award_received.connect(func(info: Dictionary) -> void: (mine["awards"] as Array).append(info))

	_server_game.medals.reset_round()
	var target := _server_game.player_for(victim)
	if not target.is_alive():
		target.spawn(_server_game.map.spawns[0], _server_game.current_tick())
	# Past spawn protection, which is three records and not only the health's window.
	_pump(int(_server_game.match_node.rules.spawn_protection_sec * TICK_RATE) + 4)
	var health := _server_game.combat.health_of(victim)
	health.invulnerable_until_tick = -1
	var type := _server_game.combat.damage_type(&"")
	for amount in [10.0, 12.0]:
		var pellet := DotDamage.make(killer, victim, amount, type)
		pellet.tick = _server_game.current_tick()
		var _p := _server_game.combat.apply_damage(pellet)
	var shot := DotDamage.make(killer, victim, 500.0, type)
	shot.tick = _server_game.current_tick()
	shot.hit_group = DotHitGroup.HEAD
	var _s := _server_game.combat.apply_damage(shot)
	_server_bridge.server_tick(_server_game.current_tick() + 1)

	# Deliver what the server put on the link, to whom it addressed it.
	for item in sent:
		var targets: Array = _clients.keys() if int(item[0]) == 0 else [int(item[0])]
		for peer in targets:
			if _clients.has(peer):
				var _r: DotResult = _clients[peer]["bridge"].receive_event(item[1])

	var to_killer: Array = heard[killer_peer]["hits"]
	var to_victim: Array = heard[2]["hits"]
	_check(
		to_killer.size() == 1 and int(to_killer[0]["victim_id"]) == victim and bool(to_killer[0]["lethal"])
			and bool(to_killer[0]["headshot"]) and int(to_killer[0]["amount"]) > 22,
		"one tick's hits reach the attacker as one HIT, summed, lethal and to the head",
		str(to_killer)
	)
	_check(to_victim.is_empty(), "and nobody else hears about them", str(to_victim))
	var award_killer: Array = heard[killer_peer]["awards"]
	var award_victim: Array = heard[2]["awards"]
	_check(
		award_killer.size() == 1 and award_victim.size() == 1
			and (award_killer[0]["medals"] as Array).has(ArenaAwards.Medal.FIRST_BLOOD)
			and (award_killer[0]["medals"] as Array).has(ArenaAwards.Medal.HEADSHOT),
		"the AWARD reaches every client, with the server's First Blood and Headshot",
		"%s / %s" % [award_killer, award_victim]
	)

	_server_bridge.link = previous
	link.free()
	target.spawn(_server_game.map.spawns[0], _server_game.current_tick())
	_pump(2)
	_done()


## sv_ballistics: the server announces each bullet it flies (BULLET), a client flies the same path
## for a tracer and ends it on BULLET_END; with the cvar off nothing goes out and nothing exists.
func _test_bullets_reach_a_client() -> void:
	print("")
	_section("[simulated bullets reach a client]")
	var client_game: ArenaGame = _clients[2]["game"]
	var sent: Array = []
	var previous := _server_bridge.link
	var link := _capture_link(sent)

	var shooter := _server_game.player_for(11)
	shooter.give_default_loadout()
	var weapon_id := shooter.arsenal.current_def().id
	var tuning := ArenaPlayer.weapon_catalogue().get_def(weapon_id).tuning as DotWeaponBallistics
	var was := [tuning.muzzle_velocity, tuning.max_range, tuning.tracer_interval, tuning.pellets]
	_tune(tuning, [40.0, 30.0, 1, 1])
	_pump(2)
	sent.clear()

	var fire := func() -> void: _fire_test_shot(weapon_id, tuning)
	var kinds := func(kind: int) -> Array:
		var out: Array = []
		for item in sent:
			var decoded: DotResult = _clients[2]["net"].messages.decode(DotNetReader.new(item[1]), 1, false)
			var event := decoded.value as ArenaEvent if decoded.ok else null
			if event != null and event.kind == kind:
				out.append(item)
		return out
	var deliver := func() -> void:
		for item in sent:
			if int(item[0]) == 2:
				var _r: DotResult = _clients[2]["bridge"].receive_event(item[1])
		sent.clear()

	_check(not _server_game.combat_feel.ballistics.enabled, "sv_ballistics is off by default")
	fire.call()
	_pump(2)
	_check(kinds.call(ArenaEvents.Kind.BULLET).is_empty() and kinds.call(ArenaEvents.Kind.BULLET_END).is_empty(),
		"off: a shot sends no bullet event at all", str(sent.size()))
	_check(client_game.bullet_mirrors == null or client_game.bullet_mirrors.count() == 0, "off: the client has no bullet")
	sent.clear()

	for g in [_server_game, client_game]: g.combat_feel.ballistics.set(&"enabled", true)
	fire.call()
	var spawned: Array = kinds.call(ArenaEvents.Kind.BULLET)
	_check(spawned.size() >= 1 and int(spawned[0][0]) == 2, "on: a BULLET goes to the ready client", str(spawned.size()))
	var read := ArenaEvents.read_bullet(DotNetReader.new(ArenaEvents.write_bullet(7, 11, ArenaContent.weapon_index(weapon_id), Vector3(1.0, 8.0, -2.0), Vector3(10.0, 5.0, -30.0))))
	_check(bool(read["ok"]) and int(read["id"]) == 7 and ArenaContent.weapon_at(int(read["weapon"])) == weapon_id
		and (read["velocity"] as Vector3).distance_to(Vector3(10.0, 5.0, -30.0)) < 0.1, "a BULLET round-trips")
	deliver.call()
	_check(client_game.bullet_mirrors != null and client_game.bullet_mirrors.count() == 1, "the client flies a copy of it")
	var local_vel: Vector3 = client_game.bullet_mirrors.velocity_of(int(client_game._mirror_ids.values()[0])) if not client_game._mirror_ids.is_empty() else Vector3.ZERO
	_check(absf(local_vel.length() - 40.0) < 0.5, "flying at the server's speed", str(local_vel.length()))
	_pump(3)
	_check(client_game.tracers != null and client_game.tracers.count() > 0, "and its tracer exists",
		str(client_game.tracers.count() if client_game.tracers != null else -1))
	_pump(100)
	_check(not kinds.call(ArenaEvents.Kind.BULLET_END).is_empty(), "the server says when it ended")
	deliver.call()
	_check(client_game.bullet_mirrors.count() == 0, "and the client's copy is gone")

	fire.call()
	deliver.call()
	var live := client_game.bullet_mirrors.count()
	var server_id := int(client_game._mirror_ids.keys()[0]) if not client_game._mirror_ids.is_empty() else -1
	_deliver_event(2, ArenaEvents.Kind.BULLET_END, ArenaEvents.write_bullet_end(server_id))
	_check(live == 1 and client_game.bullet_mirrors.count() == 0, "a BULLET_END ends a copy early", "%d then %d" % [live, client_game.bullet_mirrors.count()])

	for g in [_server_game, client_game]: g.combat_feel.ballistics.set(&"enabled", false)
	_pump(100)
	sent.clear()
	fire.call()
	_pump(2)
	_check(sent.is_empty(), "off again: nothing is sent", str(sent.size()))
	_tune(tuning, was)
	_server_bridge.link = previous
	link.free()
	_done()


## mp_killview: a bot's kill sends its recorded view to the victim alone, the victim's respawn waits for it,
## and the respawn request of a victim watching it skips the wait. Before the disconnect, which removes a player.
func _test_killview_reaches_the_victim() -> void:
	print("")
	_section("[the kill view reaches the victim]")
	var sent: Array = []
	var previous := _server_bridge.link
	var link := _capture_link(sent)

	var victim := 11
	var bot := _server_bridge.add_bot("Bolt")
	var heard: Array = []
	var other_heard: Array = []
	_clients[2]["bridge"].killview_received.connect(func(clip: Dictionary, info: Dictionary) -> void: heard.append([clip, info]))
	_clients[3]["bridge"].killview_received.connect(func(clip: Dictionary, info: Dictionary) -> void: other_heard.append(clip))
	_check(bot != 0 and _server_game.killview_rules.enabled, "a bot is in, and the kill view is on in this game")

	var target := _server_game.player_for(victim)
	if not target.is_alive():
		target.spawn(_server_game.map.spawns[0], _server_game.current_tick())
	_pump(TICK_RATE * 2)
	_check(_server_bridge.killview != null and _server_bridge.killview.ring.sample_count(bot) > 10,
		"every tick records the bot's eye", str(_server_bridge.killview.ring.sample_count(bot) if _server_bridge.killview != null else -1))

	# The killer's own field of view: a client's setting reaches the server, a bot is drawn with the default.
	var fov_writer := DotNetWriter.new()
	var _fov_wrote := _server_net.messages.encode(ArenaRequest.new(ArenaEvents.Ask.FOV, ArenaEvents.write_fov(110.0)), fov_writer)
	var _fov_asked := _server_bridge.receive_request(2, fov_writer.to_bytes())
	var want_fov := KillPov.degrees_to_vertical(110.0)
	_check(is_equal_approx(KillPov.fov_of(target), want_fov) and absf(want_fov - 83.6) > 5.0,
		"a client's field of view setting is what its kill view is drawn with", "%.2f vs %.2f" % [KillPov.fov_of(target), want_fov])
	_check(is_equal_approx(KillPov.degrees_to_vertical(100.0), 83.6) or absf(KillPov.degrees_to_vertical(100.0) - 83.6) < 0.1, "100 at 4:3 is the 83.6 the addon assumed")
	var recorded_fov := 0.0
	for e: Dictionary in _server_bridge.killview.eyes_fn.call():
		if int(e["id"]) == victim:
			recorded_fov = float(e["fov"])
	_check(is_equal_approx(recorded_fov, want_fov), "and the server records that lens in the clip", str(recorded_fov))
	KillPov.note_field_of_view(target, 9000.0)
	_check(is_equal_approx(KillPov.fov_of(target), want_fov), "a nonsense setting changes nothing")
	_check(is_equal_approx(KillPov.fov_of(_server_game.player_for(bot)), KillPov.DEFAULT_FOV), "a bot has no screen: the default")

	var usual_delay := _server_game.match_node.rules.respawn_delay_sec
	_server_game.match_node.rules.respawn_delay_sec = 2.0
	_server_game.combat.health_of(victim).invulnerable_until_tick = -1
	var kill := DotDamage.make(bot, victim, 5000.0, _server_game.combat.damage_type(&""))
	kill.tick = _server_game.current_tick()
	var _applied := _server_game.combat.apply_damage(kill)
	var died_at := _server_game.current_tick()
	_check(not target.is_alive(), "the bot kills the player")
	sent.clear()
	_pump(int(_server_game.killview_rules.post_seconds * TICK_RATE) + 6)

	var views: Array = []
	for item in sent:
		var decoded: DotResult = _clients[2]["net"].messages.decode(DotNetReader.new(item[1]), 1, false)
		var event := decoded.value as ArenaEvent if decoded.ok else null
		if event != null and event.kind == ArenaEvents.Kind.KILLVIEW:
			views.append(item)
	_check(views.size() == 1 and int(views[0][0]) == 2, "one KILLVIEW goes out, to the victim's peer alone", str(views.size()))
	for item in views:
		var _r: DotResult = _clients[2]["bridge"].receive_event(item[1])
	_check(heard.size() == 1 and other_heard.is_empty(), "the victim's client hears the clip and nobody else does")
	var made := DotKillViewClip.to_buffer(heard[0][0]) if not heard.is_empty() else DotResult.fail(DotError.CODE_STATE, "none")
	_check(made.ok and String(heard[0][1].get("killer", "")) == "Bolt", "the clip is a usable view of the killer", str(heard[0][1] if not heard.is_empty() else {}))
	_check(heard.size() == 1 and heard[0][0]["f"].size() <= ArenaEvents.KILLVIEW_BYTES / 4, "and fits one event")
	var respawns := _server_game.match_node.respawns
	var normal := died_at + int(_server_game.match_node.rules.respawn_delay_sec * TICK_RATE)
	_check(respawns.is_waiting(str(victim)) and respawns.ready_tick(str(victim)) > normal + TICK_RATE,
		"the respawn is held past the usual delay while the clip plays", "%d, usual %d" % [respawns.ready_tick(str(victim)), normal])

	# Space: the client's respawn request, taken only from a victim being held.
	var writer := DotNetWriter.new()
	var _wrote := _server_net.messages.encode(ArenaRequest.new(ArenaEvents.Ask.RESPAWN), writer)
	var _asked := _server_bridge.receive_request(2, writer.to_bytes())
	_pump(2)
	_check(target.is_alive(), "a respawn request from the victim skips the wait: back in the match at once")
	var _again := _server_bridge.receive_request(2, writer.to_bytes())
	_check(not respawns.is_waiting(str(victim)), "and a second request does nothing")

	_server_game.match_node.rules.respawn_delay_sec = usual_delay
	_server_bridge.remove_bot(bot)
	_check(_server_bridge.killview.ring.sample_count(bot) == 0, "a bot that leaves is forgotten")
	_server_bridge.link = previous
	link.free()
	_done()


func _test_disconnect() -> void:
	print("")
	_section("[disconnect]")

	_server_bridge.remove_peer(3)
	_check(_server_net.registry.count() == 1 + _server_bridge.toy_count(), "the peer's entity is released",
		str(_server_net.registry.count()))
	_check(_server_game.player_for(12) == null, "and it leaves the game")
	_check(_server_bridge.behaviour_for(12) == null, "and the bridge forgets it")

	# The remaining player must keep working, which is the thing a removal most often
	# breaks: a stale entry in the command table would crash the next tick.
	var next := _server_game.current_tick() + 1
	_server_bridge.server_tick(next)
	_check(_server_game.current_tick() == next, "the server ticks on")
	_done()


## Hands a client an event exactly as the server's link would put it on the wire.
## The map's toys on a client: paired by index from TOYS, frozen copies, a ball kicked on the
## server followed there, and the switch... arena places loose toys only, so a kick and a shot.
func _test_toys_reach_a_client() -> void:
	print("")
	_section("[the map's toys reach a client]")
	var client_game: ArenaGame = _clients[2]["game"]
	var client_bridge: ArenaNetBridge = _clients[2]["bridge"]
	_check(client_game.map.id == _server_game.map.id and client_bridge.toy_count() == _server_game.toys.count() and _server_game.toys.count() > 0,
		"the client's toys are paired with the server's, by index, on the map they share",
		"%s and %s, %d of %d" % [client_game.map.id, _server_game.map.id, client_bridge.toy_count(), _server_game.toys.count()])
	var server_ball := _server_game.toys.toy(0)
	var client_ball := client_game.toys.toy(0)
	_check(client_ball != null and client_ball.body.freeze and not client_ball.authoritative and server_ball.authoritative,
		"the client's toys are frozen copies, posed from the server's")
	var start := client_ball.body.global_position
	var _kicked := _server_game.toys.use(server_ball.index, server_ball.body.global_position + Vector3(0, 1.4, 1.2), Vector3(0, -0.3, -1))
	var furthest := 0.0
	for _i in range(30):
		_pump(1)
		await get_tree().physics_frame
		furthest = maxf(furthest, client_ball.body.global_position.distance_to(start))
	for _i in range(40):
		_pump(1)
		await get_tree().physics_frame
	var apart := client_ball.body.global_position.distance_to(server_ball.body.global_position)
	_check(furthest > 1.0 and apart < 0.6, "a ball kicked on the server rolls off on the client and rests where the server's did",
		"%.2f m out, %.2f m apart" % [furthest, apart])
	# A shot on the server: the client sees the second ball go.
	var server_other := _server_game.toys.toy(1)
	var client_other := client_game.toys.toy(1)
	var o0 := client_other.body.global_position
	var shot := DotShot.new()
	shot.origin = server_other.body.global_position + Vector3(0, 0, 5)
	shot.direction = Vector3(0, 0, -1)
	shot.damage = 25.0
	shot.max_range = 30.0
	_server_game._shoot_toys([shot] as Array[DotShot])
	for _i in range(40):
		_pump(1)
		await get_tree().physics_frame
	_check(client_other.body.global_position.distance_to(o0) > 0.5, "a ball shot on the server is seen to go on the client",
		"%.2f m" % client_other.body.global_position.distance_to(o0))
	_done()


## The horde reaches a connected client: a monster the server spawns is drawn, follows the server's,
## and goes when the server's does.
func _test_monsters_reach_a_client() -> void:
	print("")
	_section("[monsters reach a client]")

	var horde := ArenaHorde.new()
	horde.name = "Horde"
	horde.game = _server_game
	horde.persist_heat = false
	add_child(horde)
	var built := horde.setup()
	_check(built.ok, "a horde sets up on the server", str(built.error) if not built.ok else "")
	_server_game.horde = horde
	_pump(1)

	var at: Vector3 = horde.nav.points[horde.nav.point_count() / 2]
	var monster := horde.spawn_one(ArenaNpcs.GRUNT, at)
	_check(monster != null, "a monster spawns")

	if monster == null:
		_done()
		return

	var server_net: Object = _server_bridge.get("_monster_nets").get(monster.instance_id)
	_check(server_net != null, "and the server replicates it")

	var net_id: int = server_net.get("identity").net_id
	_deliver_event(2, ArenaEvents.Kind.NPC, ArenaEvents.write_npc(net_id, monster.def.id, monster.position()))
	var client_bridge: ArenaNetBridge = _clients[2]["bridge"]
	_check(client_bridge.monster_count() == 1, "the client builds it from the NPC event")

	_pump(40)
	# The mirror is drawn a buffer behind, so a turning monster is compared once it holds a
	# heading: how many ticks the run took before here decides whether it is mid-turn.
	var steady := 0
	for _i in range(160):
		var was := DotNpcNetSync.yaw_of(monster)
		_pump(1)
		steady = steady + 1 if absf(angle_difference(was, DotNpcNetSync.yaw_of(monster))) < 0.01 else 0
		if steady >= 12:
			break
	var mirror: Node3D = client_bridge.get("_monster_mirrors")[net_id].body
	_check_monster_mirror(mirror, monster, client_bridge, server_net, net_id)

	horde.spawner.remove(monster.instance_id, DotNpcSpawner.REASON_ADMIN)
	_check(not _server_bridge.get("_monster_nets").has(monster.instance_id), "the server lets it go")
	_deliver_event(2, ArenaEvents.Kind.NPC_GONE, ArenaEvents.write_npc_gone(net_id))
	_check(client_bridge.monster_count() == 0, "and so does the client")

	_server_game.horde = null
	horde.queue_free()
	_pump(1)
	_done()


## An administrator noclips a player on the server, and the player's own client — which has no
## noclip permission of its own — has to PREDICT it.
func _test_forced_noclip_is_predicted() -> void:
	print("")
	_section("[an admin's noclip, predicted by the client it happens to]")

	var entry: Dictionary = _clients[2]
	var session := int(entry["session"])
	var server_player: ArenaPlayer = _server_bridge.behaviour_for(session).player
	var client_player: ArenaPlayer = (entry["bridge"] as ArenaNetBridge).behaviour_for(session).player

	_check(
		not client_player.controller.tunables.can_noclip,
		"the client may not noclip on its own"
	)

	var on := DotFpsAdminModifiers.set_noclip(server_player.controller, true)
	_check(on.ok, "the server holds player %d in noclip" % session, str(on.error))

	var start_y: float = server_player.controller.state.position.y
	var shipped := _flight_window(2, 64, DotFpsCommand.BUTTON_JUMP)

	_check(
		DotFpsAdminModifiers.is_noclipped(client_player.controller)
		and client_player.controller.state.mode == DotFpsState.Mode.NOCLIP,
		"the client learned it from the snapshots and is flying too"
	)
	_check(
		server_player.controller.state.position.y > start_y + 5.0,
		"the server's player rose into the air",
		"y %.2f from %.2f" % [server_player.controller.state.position.y, start_y]
	)
	_check(
		int(shipped["grounded_ticks"]) == 0,
		"and the client never once predicted them out of noclip",
		"%d of 64 ticks" % int(shipped["grounded_ticks"])
	)
	_check(
		float(shipped["worst_gap"]) < 0.05,
		"and never predicted them more than five centimetres from the server",
		"worst %.2f m" % float(shipped["worst_gap"])
	)

	# Back to the ground, and then the version that does NOT work, for contrast.
	var _off := DotFpsAdminModifiers.set_noclip(server_player.controller, false)
	server_player.controller.teleport(Vector3(0.0, 0.1, 18.0))
	var _settle := _flight_window(0, 24, 0)

	server_player.controller.allow_noclip = true
	server_player.controller.tunables.can_noclip = true
	server_player.controller.state.mode = DotFpsState.Mode.NOCLIP

	var naive := _flight_window(2, 64, DotFpsCommand.BUTTON_JUMP)
	print("  measured: shipped %d ticks out of noclip, worst %.2f m; naive %d ticks, worst %.2f m" % [int(shipped["grounded_ticks"]), float(shipped["worst_gap"]), int(naive["grounded_ticks"]), float(naive["worst_gap"])])

	_check(
		int(naive["grounded_ticks"]) > 16 or float(naive["worst_gap"]) > 2.0,
		"a mode set without the modifier is one the client does not predict: the rubber band",
		"naive: %d ticks out of noclip, worst %.2f m — if this passes quietly, the checks above prove nothing"
		% [int(naive["grounded_ticks"]), float(naive["worst_gap"])]
	)

	server_player.controller.allow_noclip = false
	server_player.controller.tunables.can_noclip = false
	server_player.controller.state.mode = DotFpsState.Mode.AIR
	server_player.controller.teleport(Vector3(0.0, 0.1, 18.0))
	var _land := _flight_window(0, 24, 0)
	_done()


## A server owner's movement rules (`arena_slide*`, `arena_launch*`) reach every client. [b]A client
## predicting with different numbers mispredicts every slide and every launch[/b], and the symptom
## is rubber-banding that looks like lag.
func _test_movement_rules_reach_clients() -> void:
	print("")
	_section("[movement rules reach every client]")

	var entry: Dictionary = _clients[2]
	var session := int(entry["session"])
	var server_player: ArenaPlayer = _server_bridge.behaviour_for(session).player
	var client_game: ArenaGame = entry["game"]
	var client_player: ArenaPlayer = (entry["bridge"] as ArenaNetBridge).behaviour_for(session).player

	_check(
		client_player.controller.tunables.slide_enabled and not client_player.controller.tunables.launch_enabled
		and not server_player.controller.tunables.launch_enabled,
		"the arena slides by default and does not launch (E is off until arena_launch 1), on the client as on the server"
	)

	# This harness has no event link, so RULES is handed to each client as the link would
	# carry it: encoded by the server's bridge, read by the client's.
	var relay := func(rules: Dictionary) -> void:
		var bytes := _server_bridge.encode_event(ArenaEvents.Kind.RULES, ArenaEvents.write_rules(rules))
		for peer_id in _clients:
			var _r: DotResult = _clients[peer_id]["bridge"].receive_event(bytes)
	_server_game.movement_rules_changed.connect(relay)

	_server_game.set_movement_rules({"launch_velocity": 14.0, "slide_boost": 2.0})
	var _carry := _flight_window(0, 8, 0)

	# The mode travels the same way: a client's own `mode` is whatever it was built with,
	# and its banner and its keys (E is the prop tool's in a props mode) read this.
	_server_game._announce_mode()
	_check(
		# shown_mode, not displayed_mode(): both ends default to free-for-all, so only the
		# field the announcement sets can tell a told client from an untold one.
		client_game.shown_mode != null and client_game.shown_mode.id == _server_game.mode.id,
		"and so does the mode being played (%s)" % (client_game.displayed_mode().id if client_game.displayed_mode() else &"none")
	)

	_check(
		is_equal_approx(float(client_game.movement_rules.get("launch_velocity", 0.0)), 14.0),
		"a rule the server changes reaches the client's game",
		str(client_game.movement_rules)
	)
	_check(
		client_player.controller.tunables.fingerprint() == server_player.controller.tunables.fingerprint(),
		"and its copy of the player moves by the same numbers as the server's",
		"%s vs %s" % [client_player.controller.tunables.fingerprint(), server_player.controller.tunables.fingerprint()]
	)

	# Somewhere with nothing overhead: the noclip section's spot is under the south arcade, whose
	# roof stopped the first launch measured here at 1.19 m.
	var waited_live := 0
	while not _server_game.match_node.is_live() and waited_live < 40:
		var _wait_live := _flight_window(0, 32, 0)
		waited_live += 1

	var open_sky := _open_sky(_server_game.map)
	server_player.controller.teleport(open_sky)
	server_player.controller.state.velocity = Vector3.ZERO
	var _settle := _flight_window(0, 32, 0)
	var start_y: float = server_player.controller.state.position.y
	var peak := [start_y]
	server_player.controller.simulated.connect(
		func(_t: int, s: DotFpsState) -> void: peak[0] = maxf(peak[0], s.position.y)
	)
	# Default E must do nothing: hold it for a window and the player stays near the ground.
	var idle_peak := [start_y]
	var idle_sub := func(_t: int, s: DotFpsState) -> void: idle_peak[0] = maxf(idle_peak[0], s.position.y)
	server_player.controller.simulated.connect(idle_sub)
	var _idle := _flight_window(2, 32, DotFpsCommand.BUTTON_USER_0)
	server_player.controller.simulated.disconnect(idle_sub)
	_check(float(idle_peak[0]) - start_y < 1.0, "E with the default rules does not throw the player into the air",
		"rose %.2f m" % (float(idle_peak[0]) - start_y))
	_server_game.set_movement_rules({"launch_enabled": true})
	var _arm := _flight_window(0, 8, 0)
	peak[0] = start_y
	var launch := _flight_window(2, 64, DotFpsCommand.BUTTON_USER_0)
	print("  measured: launch peak %.2f m, worst gap %.2f m (%s)" % [float(peak[0]) - start_y, float(launch["worst_gap"]), launch["worst_at"]])
	_check(float(peak[0]) - start_y > 3.0, "E throws the server's player into the air (from %s)" % open_sky,
		"%.2f m" % (float(peak[0]) - start_y))
	_check(float(launch["worst_gap"]) < 0.05, "and the client predicts it to within five centimetres",
		"worst %.2f m" % float(launch["worst_gap"]))

	# The negative control: the same change made on the server's player alone.
	server_player.controller.tunables.launch_velocity = 24.0
	_check(
		client_player.controller.tunables.fingerprint() != server_player.controller.tunables.fingerprint(),
		"a launch changed on the server alone leaves the two ends' movement apart",
		"if this passes quietly, the fingerprint check above proves nothing"
	)

	_server_game.set_movement_rules({"launch_velocity": 15.5, "slide_boost": 3.5})
	_server_game.movement_rules_changed.disconnect(relay)
	# Back where the sections after this one expect the player: the noclip section's spot.
	server_player.controller.teleport(Vector3(0.0, 0.1, 18.0))
	server_player.controller.state.velocity = Vector3.ZERO
	var _back := _flight_window(0, 32, 0)
	_done()


## A wall run and a wall jump, predicted by the client and run by the server, over this harness's
## one-in-five loss.
func _test_wall_moves_predicted() -> void:
	print("")
	_section("[a wall run and a wall jump, predicted]")

	var peer: int = _clients.keys()[0]
	var entry: Dictionary = _clients[peer]
	var session := int(entry["session"])
	var client_game: ArenaGame = entry["game"]
	var server_player: ArenaPlayer = _server_bridge.behaviour_for(session).player
	var client_player: ArenaPlayer = (entry["bridge"] as ArenaNetBridge).behaviour_for(session).player
	var net: DotNetManager = entry["net"]

	_check(
		_server_game.map.id == &"dm_atrium" and client_game.map.id == &"dm_atrium",
		"both ends are on dm_atrium, where the gallery is",
		"%s / %s" % [_server_game.map.id, client_game.map.id]
	)

	# A map change restarts the match, and its countdown's end respawns everybody: a run
	# cut off by that is a respawn, not a misprediction. Wait for the round to be live.
	var waited := 0
	while not _server_game.match_node.is_live() and waited < 40:
		var _wait := _flight_window(peer, 32, 0)
		waited += 1

	for route: Dictionary in _server_game.map.wall_routes:
		var driver := WallRouteDriver.new(route, &"walls")
		driver.tick_rate = TICK_RATE
		server_player.controller.teleport(driver.start, driver.yaw, 0.0)
		var _settle := _flight_window(peer, 40, 0)

		var runs_before := server_player.controller.motor.wall_runs
		var jumps_before := server_player.controller.motor.wall_jumps
		var measured := _driven_window(peer, driver, 260)
		var runs := server_player.controller.motor.wall_runs - runs_before
		var jumps := server_player.controller.motor.wall_jumps - jumps_before
		var name: String = route["name"]
		var landed_apart := float(measured["last_aligned"])
		print("  measured: %s: %d runs, %d wall jumps on the server; worst gap %.3f m (%s); %.3f m apart once down" % [
			name, runs, jumps, float(measured["worst_aligned"]), measured["worst_at"], landed_apart])

		_check(
			driver.made(server_player.controller.state) and driver.made(client_player.controller.state)
				and (runs >= 1 if route["kind"] == &"run" else jumps >= 2),
			"%s: the server's player makes it, and so does the client's prediction" % name,
			"server %s, client %s" % [server_player.controller.state.position, client_player.controller.state.position]
		)
		# Five centimetres. `_driven_window` plays the link the way a real one plays (the client
		# ahead of its snapshots, each command early with its copies), so what is left is the
		# snapshot's own rounding, 5 to 7 mm whichever tick the presses fall on.
		_check(
			float(measured["worst_aligned"]) < 0.05 and landed_apart < 0.01,
			"%s: the client predicted it within five centimetres of the server, and lands where it does" % name,
			"worst %.3f m at %s, %.3f m apart once down" % [float(measured["worst_aligned"]), measured["worst_at"], landed_apart]
		)

	server_player.controller.teleport(Vector3(0.0, 0.1, 18.0))
	server_player.controller.state.velocity = Vector3.ZERO
	var _back := _flight_window(0, 32, 0)
	_done()


## An administrator's blind and beacon, through the real handlers, over the lossy link. [b]The
## audience is the whole point of both.[/b] Client 2 owns player 11.
func _test_blind_and_beacon() -> void:
	print("")
	_section("[an admin's blind and beacon: who is told]")

	var handlers := ArenaModTools.handlers(_server_game)
	var blind: Callable = handlers[DotModTools.ACTION_BLIND]
	var beacon: Callable = handlers[DotModTools.ACTION_BEACON]

	var owner: ArenaNetBridge = _clients[2]["bridge"]
	var watcher: ArenaNetBridge = _clients[3]["bridge"]

	_check(
		owner.behaviour_for(11).find_var(&"net_blind").audience == DotNetVar.Audience.OWNER
		and owner.behaviour_for(11).find_var(&"net_beacon").audience == DotNetVar.Audience.EVERYONE,
		"the blind is declared owner-only and the beacon for everybody"
	)

	var on_blind: DotResult = blind.call(&"11", {"on": true, "actor": "1"})
	var on_beacon: DotResult = beacon.call(&"11", {"on": true, "actor": "1"})
	_check(on_blind.ok and on_beacon.ok, "the server blinds and beacons player 11")

	# Long enough for several snapshots through one-in-five loss.
	var _window := _flight_window(0, 24, 0)

	_check(
		owner.behaviour_for(11).player.blinded,
		"the owner's client blacks its own screen out"
	)
	_check(
		not watcher.behaviour_for(11).player.blinded
		and not watcher.behaviour_for(11).net_blind,
		"and the other client is never told",
		"client 3 received net_blind = %s" % str(watcher.behaviour_for(11).net_blind)
	)
	_check(
		owner.behaviour_for(11).player.beacon and watcher.behaviour_for(11).player.beacon,
		"while both clients draw the beacon on player 11"
	)
	_check(
		not watcher.behaviour_for(12).player.blinded
		and not watcher.behaviour_for(12).player.beacon,
		"and neither mark lands on the watcher's own player"
	)
	_check(
		_server_bridge.behaviour_for(11).identity.always_relevant,
		"a beaconed player is relevant to every peer, however far away"
	)

	var _off_blind: DotResult = blind.call(&"11", {"on": false, "actor": "1"})
	var _off_beacon: DotResult = beacon.call(&"11", {"on": false, "actor": "1"})
	_window = _flight_window(0, 24, 0)

	_check(
		not owner.behaviour_for(11).player.blinded
		and not owner.behaviour_for(11).player.beacon
		and not watcher.behaviour_for(11).player.beacon,
		"and turning both off reaches both clients"
	)
	_check(
		not _server_bridge.behaviour_for(11).identity.always_relevant,
		"and puts player 11 back under the ordinary interest rules"
	)
	_done()
