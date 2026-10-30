extends DotGameCheckSuite

const ArenaClientExtras := preload("../game/arena_client_extras.gd")
const ArenaConfig := preload("../game/arena_config.gd")
const ArenaAwards := preload("../game/arena_awards.gd")
const ArenaEvent := preload("../game/arena_event.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaEvents := preload("../game/arena_events.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModTools := preload("../game/arena_mod_tools.gd")
const ArenaMapSession := preload("../game/arena_map_session.gd")
const ArenaMaps := preload("../game/arena_maps.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaNetCommand := preload("../game/arena_net_command.gd")
const ArenaNetLink := preload("../game/arena_net_link.gd")
const ArenaHud := preload("../game/arena_hud.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPlayerNet := preload("../game/arena_player_net.gd")
const ArenaSolidBody := preload("../game/arena_solid_body.gd")
const ArenaHorde := preload("../game/arena_horde.gd")
const ArenaNpcs := preload("../game/arena_npcs.gd")
const WallRouteDriver := preload("wall_route_driver.gd")
const ArenaRequest := preload("../game/arena_request.gd")

## Two clients, one server, one process, and a lossy wire between them.
##
## [b]This is the first time anything in this family runs netcode over more than one
## client.[/b] dot-net's own integration run adds exactly one peer, which is the one
## shape in which "replicate to everybody" and "replicate to whoever is served first"
## look identical — and that is precisely how a replication bug survived in dot-net
## until it was looked for. Two peers here is not thoroughness, it is the minimum that
## tests the thing at all.
##
## Everything is real except the socket: real managers, a real [ArenaGame] on all
## three sides, real bit-packed commands, real snapshots, real acknowledgements, and
## one packet in five dropped in each direction.

const TICK_RATE := 64
const SNAPSHOT_RATE := 16
const RUN_TICKS := 96
const LOSS_EVERY := 5

const CHECKS := 284

## The imported combat surf map the map-sync section also follows a client onto, and how
## many checks that adds. Without arena-surf-dm-maps linked they are skipped and said so, and
## the total expected drops by exactly that many: a skip is allowed, a silent one is not.
const IMPORTED_MAP := &"surf_10x_reloaded_fixed"
const IMPORTED_CHECKS := 9
var _skipped_checks := 0

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 25

var _entered := 0
var _completed := 0

var _server_game: ArenaGame = null
var _server_net: DotNetManager = null
var _server_bridge: ArenaNetBridge = null

## peer id -> {game, net, bridge}
var _clients: Dictionary = {}

## Payloads in flight, server -> client. Each is {peer, bytes}.
var _downstream: Array = []
var _drop_down := 0
var _drop_up := 0
var _joins: Array[PackedByteArray] = []


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


## The server remote's seams: whether it is on, who a peer is, which flags a uid holds, and the clock.
func _wire_remote(remote, state: Dictionary, flags: Dictionary) -> void:
	remote.enabled_fn = func() -> bool: return state["on"]
	remote.uid_fn = func(_p: int) -> String: return state["uid"]
	remote.connected_fn = func(_p: int) -> bool: return true
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	remote.now_fn = func() -> int: return state["now"]
	remote.limiter = DotRateLimiter.new(1000.0, 1000.0)


## A guest, a flagless player, a revoked admin and the cvar switched off are all refused.
func _workbench_revocations(c: Dictionary) -> void:
	var state: Dictionary = c["state"]
	var flags: Dictionary = c["flags"]
	var cremote: DotGameWorkbenchRemoteClient = c["cremote"]
	var remote = c["remote"]
	var edit: Dictionary = c["edit"]
	var sgame: ArenaGame = c["sgame"]
	var cwb: DotGameWorkbench = c["cwb"]
	state["uid"] = ""
	var _q2 := cremote.request(edit.merged({"value": 12}))
	_check(sgame.config.horde_cap == 11, "a guest's forged edit is refused")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel is taken away from it")

	state["uid"] = "plain"
	cremote.ask()
	var _q3 := cremote.request(edit.merged({"value": 13}))
	_check(not cremote.allowed and sgame.config.horde_cap == 11, "a player holding no flag is told no and refused")

	state["uid"] = "boss"
	cremote.ask()
	_check(cremote.allowed and cwb.overlay != null, "an admin is let back in")
	flags["boss"] = []
	var _q4 := cremote.request(edit.merged({"value": 14}))
	_check(sgame.config.horde_cap == 11, "the revoked admin's next edit is refused at once")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel closes")

	flags["boss"] = ["cvar", "root"]
	state["on"] = false
	var _q5 := cremote.request(edit.merged({"value": 15}))
	_check(sgame.config.horde_cap == 11, "switching the cvar off refuses a restored admin too")
	_check(not remote.permit_actor("remote:boss", "cvar"), "and revokes the server-made actors")


func _make_game(authority: bool) -> ArenaGame:
	var game := ArenaGame.new()
	game.name = "Arena%s" % ("Server" if authority else str(_clients.size()))
	game.tick_rate = TICK_RATE
	game.score_limit = 50
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = authority
	game.register_service = false
	add_child(game)

	var ready := game.setup(ArenaMap.dm_box())
	_check(ready.ok, "%s game sets up" % ("server" if authority else "client"), str(ready.error))

	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0
	game.start(0)
	return game


func _make_manager(is_server: bool, scope: StringName, peer_id: int) -> DotNetManager:
	var net := DotNetManager.new()
	net.name = "Net%s" % scope
	net.is_server = is_server
	net.service_scope = scope
	net.local_peer_id = peer_id
	net.auto_tick = false
	net.config_file = ""
	net.config = DotNetConfig.new()
	net.config.tick_rate = TICK_RATE
	net.config.snapshot_rate = SNAPSHOT_RATE
	# From the game, exactly as `ArenaModule` and `ArenaClient` do it. A suite that
	# left this at dot-net's default would agree with itself on both ends and prove
	# nothing about the two that actually ship — which is how the 128-against-256
	# mismatch survived until a browser drew sky in every direction.
	net.config.world_extent = ArenaGame.NET_WORLD_EXTENT
	add_child(net)

	_check(net.setup().ok, "%s manager sets up" % scope)

	# NOT started here. `DotNetManager.start` seals the message registry, and
	# `ArenaNetBridge.attach` registers this game's two message types — registering
	# after the seal fails, because ids are on the wire and adding a type would
	# renumber every id above it and silently reinterpret every message. So the order
	# is setup, attach, start, and it is the same order `ArenaModule` and
	# `ArenaClient` use. See `_start`.
	return net


## Seals the message registry and starts a manager. Called AFTER its bridge attached.
func _start(net: DotNetManager) -> void:
	net.messages.seal()
	net.start()


func _build_server() -> void:
	print("")
	print("[server]")

	_server_game = _make_game(true)
	_server_net = _make_manager(true, &"server", 1)

	_server_bridge = ArenaNetBridge.new()
	_server_bridge.name = "ServerBridge"
	add_child(_server_bridge)
	_check(_server_bridge.attach(_server_game, _server_net).ok, "the bridge attaches")
	_start(_server_net)

	# A game and a manager that disagree about authority is the one wiring mistake
	# that produces a server resolving nobody's hits, silently.
	var wrong := ArenaNetBridge.new()
	_check(
		not wrong.attach(_server_game, _make_manager(false, &"stray", 9)).ok,
		"a client manager behind an authoritative game is refused"
	)
	wrong.free()

	_server_bridge.player_announced.connect(func(payload: PackedByteArray) -> void:
		_joins.append(payload)
	)

	# The server's payloads land in the addressed client, with loss.
	_server_net.send_fn = func(peer_id: int, payload: PackedByteArray, _d: int) -> void:
		_drop_down += 1
		if _drop_down % LOSS_EVERY == 0:
			return
		_downstream.append({"peer": peer_id, "bytes": payload})


func _build_client(peer_id: int, session_id: int) -> void:
	print("")
	print("[client %d]" % peer_id)

	var game := _make_game(false)
	var net := _make_manager(false, &"client%d" % peer_id, peer_id)

	var bridge := ArenaNetBridge.new()
	bridge.name = "Bridge%d" % peer_id
	add_child(bridge)
	_check(bridge.attach(game, net).ok, "the bridge attaches")
	_start(net)

	# The clock is estimated from the server's ticks in a real deployment; this run
	# drives both sides tick for tick, so it is simply told.
	net.clock.tick = 0

	_clients[peer_id] = {
		"game": game, "net": net, "bridge": bridge, "session": session_id
	}


# --- The wire --------------------------------------------------------------

func _join_everyone() -> void:
	print("")
	print("[joins]")

	# What the identity layer resolved for peer 2: a member's site avatar, translated.
	var site_doc := DotAvatar.make(&"builtin")
	site_doc.set_part(&"top", &"top.skin-c")
	site_doc.set_part(&"face", &"face.skin-k")
	var dressed: DotAvatar = preload("../game/arena_avatars.gd").from_site(site_doc)
	var dressed_session := int(_clients[2]["session"])
	_server_bridge.avatar_fn = func(session_id: int) -> DotAvatar:
		return dressed if session_id == dressed_session else null

	for peer_id in _clients:
		var entry: Dictionary = _clients[peer_id]
		var added := _server_bridge.add_player(
			peer_id, int(entry["session"]), "Player %d" % peer_id
		)
		_check(added.ok, "peer %d joins the server" % peer_id, str(added.error))

	_check(_joins.size() == 2, "both joins were announced", str(_joins.size()))
	# And the map's toys, one entity each (see [method _test_toys_reach_a_client]).
	var toys := _server_bridge.toy_count()
	_check(toys > 0 and _server_net.registry.count() == 2 + toys, "two players are replicated, and the map's toys",
		"%d entities, %d toys" % [_server_net.registry.count(), toys])

	# Every client learns about every player, itself included.
	for peer_id in _clients:
		var bridge: ArenaNetBridge = _clients[peer_id]["bridge"]

		for payload in _joins:
			_check(bridge.apply_join(payload).ok, "client %d mirrors a join" % peer_id)

		# The TOYS a signon carries; this harness routes no events by itself. Before any
		# snapshot: a client that has not paired the toys stops reading a snapshot at the
		# first entity it does not know, players and all (dot-net's `receive_snapshot`).
		_deliver_event(peer_id, ArenaEvents.Kind.TOYS, _server_bridge.get("_toys_body"))
		_quiet_client_toys(peer_id)

		var net: DotNetManager = _clients[peer_id]["net"]
		_check(net.registry.count() == 2 + toys and bridge.toy_count() == toys, "client %d knows both players, and the toys" % peer_id)

		var mine := net.registry.owned_by(peer_id)
		_check(mine.size() == 1, "client %d owns exactly one" % peer_id)
		_check(mine[0].is_predicted(), "and predicts it")

	_check(
		not _clients[2]["bridge"].apply_join(PackedByteArray([1, 2])).ok,
		"a truncated join is refused"
	)

	# [b]A member's figure reaches the other screens.[/b] Arena's JOIN carried a name and
	# no avatar, and its client drew everybody as stock, so nobody's choice was ever seen.
	var watcher_game: ArenaGame = _clients[3]["game"]
	var seen := watcher_game.player_for(dressed_session)
	_check(
		seen != null and seen.avatar != null and seen.avatar.digest() == dressed.digest(),
		"another client sees the figure the server resolved for a player",
		seen.avatar.digest() if seen != null and seen.avatar != null else "no avatar"
	)
	var plain := watcher_game.player_for(int(_clients[3]["session"]))
	_check(plain != null and plain.avatar == null, "and nobody else's is invented")

	# The profile arrives after seating: the server re-describes them, and a client that
	# already has them takes the new name and figure.
	var later_doc := DotAvatar.make(&"builtin")
	later_doc.set_part(&"top", &"skin-e")
	var later: DotAvatar = preload("../game/arena_avatars.gd").from_site(later_doc)
	_check(
		_server_bridge.refresh_player(dressed_session, "Ada", later),
		"the server re-describes a seated player"
	)
	_clients[3]["bridge"].apply_join(_server_bridge.join_payload(dressed_session))
	_check(
		seen.display_name == "Ada" and seen.avatar.digest() == later.digest(),
		"and a client that already has them takes the new name and figure"
	)


# --- Running ---------------------------------------------------------------

func _commands_for(peer_id: int, tick: int) -> Array:
	var move := DotFpsCommand.new()
	# Peer 2 runs one way and peer 3 the other, so a client that received only its
	# own entity's updates would still fail the convergence check below.
	move.move = Vector2(0.0, 1.0 if peer_id == 2 else -1.0)
	move.yaw = 0.0 if peer_id == 2 else 180.0

	var fire := DotWeaponCommand.new()
	fire.slot = 2

	if tick % 8 == 0:
		fire.set_button(DotWeaponCommand.BUTTON_ATTACK, true)

	return [move, fire]


func _run_ticks() -> void:
	print("")
	print("[running %d ticks]" % RUN_TICKS)

	for tick in range(1, RUN_TICKS + 1):
		# Clients send input for the tick the server is about to run, which is what
		# "input runs ahead" means in practice.
		for peer_id in _clients:
			var entry: Dictionary = _clients[peer_id]
			var pair := _commands_for(peer_id, tick)
			var packet: PackedByteArray = entry["bridge"].encode_input(
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
			var entry: Dictionary = _clients[peer_id]
			var pair := _commands_for(peer_id, tick)
			entry["net"].clock.tick = tick
			entry["bridge"].client_tick(tick, pair[0], pair[1])

	_check(_server_game.current_tick() == RUN_TICKS, "the server ticked once per tick",
		str(_server_game.current_tick()))
	_check(_server_net.stats.packets_sent > 0, "snapshots went out")


# --- What it proves --------------------------------------------------------

## A client follows the server onto an imported combat surf map, and predicts on it.
##
## [b]Three things only an imported map exercises over the wire[/b]: the client builds the
## map's solid itself (its own `change_map`, from its own copy of the files) and its player
## moves against the physics space; its movement is the surf profile the map asks for,
## derived on its own end rather than sent; and the map is far bigger than any built-in —
## its spawns stand 190 m from the origin, past the 128 m `NET_WORLD_EXTENT` was until
## this map, where every position the server sent was clamped to the edge of the quantiser.
func _follow_onto_imported(
	host: DotMapSyncHost, client_game: ArenaGame, client_entry: Dictionary, peer: int,
	back_to: StringName
) -> void:
	var changed: DotResult = await host.change_to(IMPORTED_MAP)
	_check(changed.ok and _server_game.map.id == IMPORTED_MAP and client_game.map.id == IMPORTED_MAP,
		"the server changes to an imported combat surf map and the client follows",
		str(changed.error) if not changed.ok else String(client_game.map.id))

	var solid := client_game.map.collision_root
	_check(solid != null and solid.is_inside_tree() and solid.get_child_count() > 0
		and solid != _server_game.map.collision_root,
		"the client built the map's solid itself",
		"%d shapes" % (solid.get_child_count() if solid != null else -1))

	var session_id := int(client_entry["session"])
	var client_bridge: ArenaNetBridge = client_entry["bridge"]
	var on_server: ArenaPlayer = _server_bridge.behaviour_for(session_id).player
	var on_client: ArenaPlayer = client_bridge.behaviour_for(session_id).player
	_check(is_equal_approx(on_client.controller.tunables.gravity, float(ArenaPlayer.SURF_TUNABLES["gravity"]))
		and is_equal_approx(on_client.controller.tunables.air_accelerate, 150.0),
		"and moves its player on the genre's air control there, as the server does",
		"gravity %.2f, air %.0f" % [on_client.controller.tunables.gravity, on_client.controller.tunables.air_accelerate])

	var at := on_server.controller.state.position
	var nearest := INF

	for spawn in _server_game.map.spawns:
		nearest = minf(nearest, spawn.origin.distance_to(at))

	_check(nearest < 0.5, "the server put the player at one of the map's spawns, %.0f m out" % Vector2(at.x, at.z).length(),
		"%.1f m from the nearest" % nearest)

	var _settle := _flight_window(peer, 48, 0)
	var gap := on_client.controller.state.position.distance_to(on_server.controller.state.position)
	_check(gap < 0.1, "and the client's predicted player followed it, past the old 128 m extent",
		"%.2f m apart (client %s, server %s)" % [gap, on_client.controller.state.position, at])

	var start_y := on_server.controller.state.position.y
	var peak := [start_y]
	var watch := func(_t: int, state: DotFpsState) -> void: peak[0] = maxf(peak[0], state.position.y)
	on_server.controller.simulated.connect(watch)
	var hop := _flight_window(peer, 64, DotFpsCommand.BUTTON_JUMP)
	on_server.controller.simulated.disconnect(watch)
	print("  measured: imported map, jump peak %.2f m, worst gap %.2f m (%s)" % [
		float(peak[0]) - start_y, float(hop["worst_gap"]), hop["worst_at"]
	])
	_check(float(peak[0]) - start_y > 0.8 and float(hop["worst_gap"]) < 0.05,
		"jumping on it, the client predicts the server to within five centimetres",
		"peak %.2f m, worst %.2f m" % [float(peak[0]) - start_y, float(hop["worst_gap"])])

	# A booster: the map's mechanics run inside prediction on the client exactly as on the
	# server, from the map each end loaded, so a player thrown at 47 m/s is predicted
	# thrown. A client that left them to the server would be corrected across the map.
	var booster := {}
	for p: Dictionary in _server_game.map.mechanics.pushes:
		var push: Vector3 = p["push"]
		if not p["once"] and (p["box"] as AABB).size.y < 0.5 and Vector2(push.x, push.z).length() \
				> Vector2(booster.get("push", Vector3.ZERO).x, booster.get("push", Vector3.ZERO).z).length():
			booster = p
	var pad: AABB = booster["box"]
	var on_pad := Vector3(pad.get_center().x, pad.end.y + 0.02, pad.get_center().z)
	on_server.controller.teleport(on_pad, 0.0, 0.0)
	var boosted := _flight_window(peer, 48, 0)
	var carried := on_server.controller.state.position.distance_to(on_pad)
	print("  measured: imported map, booster carried the player %.1f m, worst gap %.2f m, %.3f m against the server's same tick" % [
		carried, float(boosted["worst_gap"]), float(boosted["worst_aligned"])
	])
	_check(carried > 20.0, "a booster on it carries the server's player on at its speed",
		"%.1f m in 48 ticks" % carried)
	# Both ends on the same tick (a real link's order); measured 0.02 m at 47 m/s. This
	# used to allow 0.1 because the harness's tick of lead was 0.74 m by itself.
	_check(float(boosted["worst_aligned"]) < 0.05,
		"and the client predicts the push with it, tick for tick",
		"worst %.3f m against the server's same tick, %.2f m at the same moment" % [
			float(boosted["worst_aligned"]), float(boosted["worst_gap"])])

	var back: DotResult = await host.change_to(back_to)
	_check(back.ok and client_game.map.id == back_to and client_game.map.collision_root == null,
		"and back to %s, with the imported solid gone from the client too" % back_to,
		str(back.error) if not back.ok else "")


## Runs the harness for [param ticks] more ticks: inputs up, the server, snapshots down,
## the clients. What [method _run_ticks] does, from wherever the server has got to.
func _pump(ticks: int) -> void:
	for _i in range(ticks):
		var tick := _server_game.current_tick() + 1
		for peer_id in _clients:
			var entry: Dictionary = _clients[peer_id]
			var pair := _commands_for(peer_id, tick)
			_server_bridge.receive_input(peer_id, entry["bridge"].encode_input(tick, pair[0], pair[1]))
		_server_bridge.server_tick(tick)
		for entry_down in _downstream:
			var peer: int = entry_down["peer"]
			var targets: Array = _clients.keys() if peer == 0 else [peer]
			for target in targets:
				if _clients.has(target):
					_clients[target]["bridge"].receive_snapshot(entry_down["bytes"])
		_downstream.clear()
		for peer_id in _clients:
			var entry: Dictionary = _clients[peer_id]
			var pair := _commands_for(peer_id, tick)
			entry["net"].clock.tick = tick
			entry["bridge"].client_tick(tick, pair[0], pair[1])


## A link that records every event the server sends into `sent` as [peer, payload], with every client ready.
func _capture_link(sent: Array) -> ArenaNetLink:
	var link := ArenaNetLink.new()
	link.bridge = _server_bridge
	link.is_server = true
	link.loopback = func(method: StringName, peer: int, payload: PackedByteArray) -> void:
		if method == &"event":
			sent.append([peer, payload])
	_server_bridge.link = link
	for peer in _clients:
		if not _server_bridge._ready_peers.has(peer):
			_server_bridge.mark_ready(peer)
	return link


## Sets a ballistic tuning's [muzzle_velocity, max_range, tracer_interval, pellets].
func _tune(tuning: DotWeaponBallistics, v: Array) -> void:
	tuning.muzzle_velocity = v[0]
	tuning.max_range = v[1]
	tuning.tracer_interval = v[2]
	tuning.pellets = v[3]


## One deferred shot from player 11 at a fixed origin, resolved through the bullet bridge.
func _fire_test_shot(weapon_id: StringName, tuning: DotWeaponBallistics) -> void:
	var shot := DotShot.new()
	shot.attacker = 11
	shot.weapon_id = weapon_id
	shot.tick = _server_game.current_tick()
	shot.origin = Vector3(0.0, 8.0, 0.0)
	shot.direction = Vector3(0.3, 0.2, -0.9).normalized()
	shot.pellets = [shot.direction] as Array[Vector3]
	shot.deferred = true
	var _r := _server_game.bullet_bridge.resolve_shot(shot, tuning, -1.0)


## The server's current TOYS to every client, as a signon or a map change sends it.
func _deliver_toys() -> void:
	for peer_id in _clients:
		_deliver_event(peer_id, ArenaEvents.Kind.TOYS, _server_bridge.get("_toys_body"))
		_quiet_client_toys(peer_id)


## One process, one physics space: a client's frozen copies would stand exactly where the
## server's balls are and push them off. A real client is another machine.
func _quiet_client_toys(peer_id: int) -> void:
	var client_game: ArenaGame = _clients[peer_id]["game"]
	if client_game.toys != null:
		for toy in client_game.toys.toys:
			if toy.body != null:
				toy.body.collision_layer = 0
				toy.body.collision_mask = 0


func _deliver_event(peer_id: int, kind: int, body: PackedByteArray) -> void:
	var writer := DotNetWriter.new()
	var _wrote := _server_net.messages.encode(ArenaEvent.new(kind, body), writer)
	var _received: DotResult = _clients[peer_id]["bridge"].receive_event(writer.to_bytes())


## The client's copy of a monster is where the server has it and faces the same way.
func _check_monster_mirror(mirror: Node3D, monster, client_bridge: ArenaNetBridge, server_net: Object, net_id: int) -> void:
	var gap := mirror.global_position.distance_to(monster.position())
	_check(gap < 1.0, "and draws it where the server has it", "%.2f m apart" % gap)
	_check(absf(angle_difference(mirror.rotation.y, DotNpcNetSync.yaw_of(monster))) < 0.3,
		"facing the way the server's faces",
		"client %.2f, server %.2f rad; client faces %s, server faces %s" % [
			mirror.rotation.y, DotNpcNetSync.yaw_of(monster),
			str((-mirror.global_basis.z).snapped(Vector3(0.01, 0.01, 0.01))),
			str(monster.facing().snapped(Vector3(0.01, 0.01, 0.01))),
		] + " | mirror net (%.2f,%.2f,%.2f) yaw %d, server net (%.2f,%.2f,%.2f) yaw %d" % [
			client_bridge.get("_monster_mirrors")[net_id].net_x, client_bridge.get("_monster_mirrors")[net_id].net_y,
			client_bridge.get("_monster_mirrors")[net_id].net_z, client_bridge.get("_monster_mirrors")[net_id].net_yaw,
			server_net.get("net_x"), server_net.get("net_y"), server_net.get("net_z"), server_net.get("net_yaw"),
		])


## [method _flight_window] with [param peer]'s commands from [param driver], read off the
## client's own predicted state, until the driver has landed (or [param ticks] run out).
##
## [b]Played the way a real link plays it, not the way [method _flight_window] does.[/b]
## Two things differ, and each one alone made the chimney's result depend on nothing but
## where its presses fell among the harness's snapshots and lost packets -- that is, on
## which sections ran before this one: CI, without the imported maps, failed it on every
## run from 2026-10-11 with the same numbers, and a desk with them passed.
##
## - The client plays a tick before the server's snapshot of it arrives. Handed over first,
##   the snapshot rewinds the client to the server's tick T with its clock still on T - 1,
##   there is nothing to replay, and the client simulates T a second time with T's command.
##   From then on its tick T + 1 is built from command T: invisible on a held input, a tick
##   late on every press. Each wall jump came out a tick late on the client and the next
##   snapshot pulled it back, 0.13 to 0.43 m apart in between.
## - A command reaches the server a tick before the server runs it, carrying copies of the
##   ones before it, as [constant ArenaNetBridge.INPUT_COPIES] and the client's input lead
##   arrange on a real link. With no lead, a lost packet is a command the server never
##   gets, and a lost jump press is a climb the server never makes.
##
## So the loss here is what a real link survives: one packet in five upstream, recovered
## from the copies, and one snapshot in five downstream.
func _driven_window(peer: int, driver: WallRouteDriver, ticks: int) -> Dictionary:
	var first := _server_game.current_tick() + 1
	var worst_aligned := 0.0
	var worst_at := ""
	var session := int(_clients[peer]["session"])
	var predicted: ArenaPlayer = (_clients[peer]["bridge"] as ArenaNetBridge).behaviour_for(session).player
	var actual: ArenaPlayer = _server_bridge.behaviour_for(session).player
	var after_landing := 0
	var last_aligned := INF

	# Each peer's command for a tick, made and sent the tick before.
	var send := func(tick: int) -> Dictionary:
		var made := {}
		for peer_id in _clients:
			var pair := _commands_for(peer_id, tick)
			if peer_id == peer:
				pair = [driver.next(predicted.controller.state), DotWeaponCommand.new()]
			made[peer_id] = pair

			var packet: PackedByteArray = _clients[peer_id]["bridge"].encode_input(
				tick, pair[0], pair[1]
			)
			_drop_up += 1
			if _drop_up % LOSS_EVERY != 0:
				_server_bridge.receive_input(peer_id, packet)
		return made

	var commands: Dictionary = send.call(first)

	for tick in range(first, first + ticks):
		for peer_id in _clients:
			var pair: Array = commands[peer_id]
			_clients[peer_id]["net"].clock.tick = tick
			_clients[peer_id]["bridge"].client_tick(tick, pair[0], pair[1])

		commands = send.call(tick + 1)
		_server_bridge.server_tick(tick)

		# Both ends have run this tick on this tick's command: what the client predicted,
		# against what the server did, before the snapshot replaces the prediction.
		var gap := predicted.controller.state.position.distance_to(actual.controller.state.position)
		last_aligned = gap
		if gap > worst_aligned:
			worst_aligned = gap
			worst_at = "tick %d client %s server %s" % [
				tick, predicted.controller.state.position, actual.controller.state.position
			]

		for entry_down in _downstream:
			var target_peer: int = entry_down["peer"]
			var targets: Array = _clients.keys() if target_peer == 0 else [target_peer]
			for target in targets:
				if _clients.has(target):
					_clients[target]["bridge"].receive_snapshot(entry_down["bytes"])
		_downstream.clear()

		# A dozen ticks standing after the landing, so a late correction is still counted.
		if driver.finished(predicted.controller.state) and driver.finished(actual.controller.state):
			after_landing += 1
			if after_landing > 12:
				break

	return {"worst_aligned": worst_aligned, "worst_at": worst_at, "last_aligned": last_aligned}


## A spawn point with no map box over it, for a launch to go straight up from. Spawns
## because they are open floor by design — a point picked by geometry alone landed inside
## the middle structure and under the south arcade's roof.
static func _open_sky(map: ArenaMap) -> Vector3:
	for spawn: Transform3D in map.spawns:
		var at := spawn.origin + Vector3(0.0, 0.1, 0.0)
		var clear := true
		for box: AABB in map.boxes:
			if (
				at.x > box.position.x - 1.0 and at.x < box.end.x + 1.0
				and at.z > box.position.z - 1.0 and at.z < box.end.z + 1.0
				and box.end.y > at.y + 0.2 and box.position.y < at.y + 8.0
			):
				clear = false
				break
		if clear:
			return at
	return map.spawns[0].origin + Vector3(0.0, 0.1, 0.0)


## Runs [param ticks] more ticks with [param peer] holding [param buttons] and nothing else
## (0 for nobody), and reports how far that peer's prediction of itself strayed from the
## server's simulation of it: `{worst_gap, grounded_ticks}`, the second counting ticks the
## client predicted it out of noclip.
## [param moves] overrides a peer's command for the whole window (peer -> DotFpsCommand), and
## `closest` is the nearest the server ever had the two clients' players on the ground plane.
func _flight_window(peer: int, ticks: int, buttons: int, moves: Dictionary = {}) -> Dictionary:
	var first := _server_game.current_tick() + 1
	var closest := INF
	var server_a: ArenaPlayer = _server_bridge.behaviour_for(int(_clients[2]["session"])).player
	var server_b: ArenaPlayer = _server_bridge.behaviour_for(int(_clients[3]["session"])).player
	var worst := 0.0
	var worst_at := ""
	var grounded := 0
	var worst_aligned := 0.0
	# Measured only once a snapshot from inside the window has arrived: before that the gap is latency.
	var heard_before: int = int(_clients[peer]["net"].stats.packets_received) if peer != 0 else 0

	# A real link's order, as in _driven_window: each command is made and sent the tick
	# before the server runs it (with its copies), the client plays tick T before T's
	# snapshot reaches it, and the gap is read with both ends on T.
	var send := func(tick: int) -> Dictionary:
		var made := {}
		for peer_id in _clients:
			var pair := _commands_for(peer_id, tick)
			if peer_id == peer:
				var held := DotFpsCommand.new()
				held.buttons = buttons
				pair = [held, DotWeaponCommand.new()]
			if moves.has(peer_id):
				pair = [moves[peer_id], DotWeaponCommand.new()]
			made[peer_id] = pair

			var packet: PackedByteArray = _clients[peer_id]["bridge"].encode_input(
				tick, pair[0], pair[1]
			)
			_drop_up += 1
			if _drop_up % LOSS_EVERY != 0:
				_server_bridge.receive_input(peer_id, packet)
		return made

	var commands: Dictionary = send.call(first)

	for tick in range(first, first + ticks):
		for peer_id in _clients:
			var pair2: Array = commands[peer_id]
			_clients[peer_id]["net"].clock.tick = tick
			_clients[peer_id]["bridge"].client_tick(tick, pair2[0], pair2[1])

		# Not past the last tick: that command would sit ahead of the next window's own.
		if tick < first + ticks - 1:
			commands = send.call(tick + 1)
		_server_bridge.server_tick(tick)
		var apart := server_a.controller.state.position - server_b.controller.state.position
		closest = minf(closest, Vector2(apart.x, apart.z).length())

		# Both ends ran this tick: the prediction against the server, before the snapshot replaces it.
		var measure := peer != 0 and int(_clients[peer]["net"].stats.packets_received) != heard_before
		if measure:
			var session := int(_clients[peer]["session"])
			var predicted: ArenaPlayer = (_clients[peer]["bridge"] as ArenaNetBridge).behaviour_for(session).player
			var actual: ArenaPlayer = _server_bridge.behaviour_for(session).player
			var gap := predicted.controller.state.position.distance_to(actual.controller.state.position)
			if gap > worst:
				worst_at = "tick %d client %s server %s" % [
					tick, predicted.controller.state.position, actual.controller.state.position
				]
			worst = maxf(worst, gap)
			worst_aligned = worst
			if predicted.controller.state.mode != DotFpsState.Mode.NOCLIP:
				grounded += 1

		for entry_down in _downstream:
			var target_peer: int = entry_down["peer"]
			var targets: Array = _clients.keys() if target_peer == 0 else [target_peer]
			for target in targets:
				if _clients.has(target):
					_clients[target]["bridge"].receive_snapshot(entry_down["bytes"])
		_downstream.clear()

	return {"worst_gap": worst, "grounded_ticks": grounded, "worst_at": worst_at,
		"worst_aligned": worst_aligned, "closest": closest}
