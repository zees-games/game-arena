extends Node

const ArenaClientExtras := preload("../game/arena_client_extras.gd")
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

const CHECKS := 230

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
const SECTIONS := 21

var _passed := 0
var _failed := 0
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


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var errors := EngineErrors.new()
	OS.add_logger(errors)

	print("game-arena — netcode over two clients")

	_build_server()
	_build_client(2, 11)
	_build_client(3, 12)
	_test_command_wire()
	_test_event_wire()
	_test_config_agreement()
	_join_everyone()
	_run_ticks()
	_test_convergence()
	_test_acks_and_recovery()
	_test_owner_only()
	_test_ready_gate()
	_test_predicted_node_is_not_moved()
	await _test_map_sync_wire()
	# The new map's TOYS, which a real link delivers to every ready peer (this harness routes
	# no event by itself): client 3 stayed on the old map, and keeps reading snapshots only
	# because a client registers the toys' mirrors whatever map it is on.
	_deliver_toys()
	await _test_voice_wire()
	_test_forced_noclip_is_predicted()
	_test_blind_and_beacon()
	_test_client_death_camera()
	_test_weapons_over_the_wire()
	# After the weapons: everybody in this harness fires every eighth tick, and this
	# section's windows spent the magazine the weapons section's fresh shot needs.
	_test_movement_rules_reach_clients()
	_test_wall_moves_predicted()
	# After the weapons for the same reason: it waits out spawn protection, and this
	# harness fires every eighth tick. Before the disconnect, which takes the killer away.
	_test_hits_and_medals_reach_clients()
	_test_solid_players_predicted()
	_test_disconnect()
	_test_monsters_reach_a_client()
	await _test_toys_reach_a_client()

	OS.remove_logger(errors)
	# Engine errors go to stderr and change no exit code: a toy pulled out of the tree after a
	# mid-tick rebuild (dot-net history #30) printed `!is_inside_tree()` on green runs elsewhere.
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS - _skipped_checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS - _skipped_checks
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s%s" % [what, "" if detail == "" else "  — " + detail])
	return condition


# --- Construction ----------------------------------------------------------

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


# --- Joining ---------------------------------------------------------------

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


# --- Maps and voice over the link -------------------------------------------

## dot-map's announce/ready/load protocol, over this game's own link.
##
## [b]dot-map's own suite runs this over a loopback `send_fn` and never over
## dot-net.[/b] Its notes say so, and they say what follows from it: the seam between
## a map sync host and a real game's transport is the one nothing has run. This is
## that seam — two [ArenaNetLink]s, a real [DotMapSyncHost] and a real
## [DotMapSyncClient], with the payloads going through the same `send_map` a socket
## would use.
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

	# Both loopbacks, crossed. `send_map` refuses to fall through to an RPC when the
	# byte loopback is set, so a harness that wired one and not the other would get a
	# silent no-op rather than a crash — which is why the counters are asserted below
	# rather than only the outcome.
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

	# The FOLLOWER needs a catalogue too, and leaving it out looks exactly like a
	# trust refusal: `DotMapSyncClient` accepts an announced map only if it is in its
	# own catalogue at the same version, or is delivered content. With no session it
	# has no catalogue, so every one of this game's maps was refused with "a host may
	# not send a map that is not delivered content" — which is the correct answer to
	# the question it was actually being asked.
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

	# The report going back is the half that makes the wait mean anything. Without it
	# the host waits out its whole timeout and swaps without the client — which
	# `swap_without_stragglers` permits, so the change would still "work" and the peer
	# would still be on the old map.
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

	# [b]Where the player stands is the server's, and the client has to follow it.[/b] A
	# map change respawns everybody on the authority (`[arena-mapchange-floor-1]`: a
	# position carried over can be inside a box of the next map) and does nothing of the
	# kind on a mirror, which only rebuilds its geometry. So the client's own predicted
	# player is left where it stood in the old map until a snapshot says otherwise, and
	# this is the check that one does — through the predictor, whose rewind adopts the
	# server's state and replays on top of it, over the same one-in-five loss.
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


## A voice frame, client to server to another client.
##
## [b]Deliberately not through [DotNetManager].[/b] dot-net decodes a bit-packed
## message against a sealed schema; a voice frame is an opaque blob from a codec and
## putting it through would mean a message type per codec — or a schema that changes
## when the codec does, and the schema hash is what both ends check to agree they are
## speaking the same game.
func _test_voice_wire() -> void:
	print("")
	_section("[voice over the link]")

	var relayed: Array[Dictionary] = []
	var heard: Array[PackedByteArray] = []

	var server_link := ArenaNetLink.attached_to(self, _server_bridge, true)
	add_child(server_link)
	server_link.name = "VoiceServerLink"

	var client_entry: Dictionary = _clients[_clients.keys()[0]]
	var client_bridge: ArenaNetBridge = client_entry["bridge"]
	var client_link := ArenaNetLink.attached_to(self, client_bridge, false)
	add_child(client_link)
	client_link.name = "VoiceClientLink"

	client_link.loopback = func(m: StringName, peer: int, payload: PackedByteArray) -> void:
		server_link.deliver(m, 2, payload)

	server_link.loopback = func(m: StringName, peer: int, payload: PackedByteArray) -> void:
		client_link.deliver(m, peer, payload)

	_server_bridge.voice_relay_fn = func(speaker: int, bytes: PackedByteArray) -> void:
		relayed.append({"speaker": speaker, "bytes": bytes})
		# Straight back out, which is what DotVoiceRouter does after it has decided
		# who hears it. The router itself is checked on a real server in `dedicated`.
		server_link.send_voice(2, bytes)

	client_bridge.voice_in_fn = func(bytes: PackedByteArray) -> void:
		heard.append(bytes)

	var frame := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	client_link.send_voice_frame(frame)

	_check(relayed.size() == 1, "a captured frame reaches the server")

	if not relayed.is_empty():
		# [b]The speaker is stamped from the transport, never read out of the
		# payload.[/b] A client that could name its own speaker id could put words in
		# anybody's mouth, and the only symptom is words coming out of the wrong
		# player — which nobody would report as a security problem.
		_check(
			int(relayed[0]["speaker"]) == 2,
			"stamped with the peer the transport reported",
			str(relayed[0]["speaker"])
		)
		_check(
			(relayed[0]["bytes"] as PackedByteArray) == frame,
			"and the bytes are unchanged"
		)

	_check(heard.size() == 1, "and the relay reaches a listener")

	# Never a broadcast. `send(bytes, 0)` is how this family last delivered a private
	# message to every client at once, and a proximity voice packet sent to peer 0
	# would be exactly that bug with audio in it.
	var before := server_link.voice_sent
	server_link.send_voice(0, frame)
	_check(
		server_link.voice_sent == before,
		"and a voice frame addressed to peer 0 is refused rather than broadcast"
	)

	# [b]The client's own voice reaches the server.[/b] Armed: until 2026-10-11 the client's
	# manager had `frame_sent.connect(pass)` where its send_fn belonged, so an arena player
	# holding the talk key was heard by nobody, while every check above handed the link bytes.
	relayed.clear()
	# The bridge's own link, as `ArenaNetBridge` sets it on a real client; this harness
	# attached the looped one by hand.
	var held_link := client_bridge.link
	client_bridge.link = client_link
	var extras := ArenaClientExtras.new()
	extras.name = "VoiceExtras"
	add_child(extras)
	var attached := extras.attach(client_bridge, client_entry["game"])
	var voice: DotVoiceManager = extras.voice
	_check(attached.ok and voice != null and not voice.is_capturing(),
		"the client's voice attaches with no microphone open before the talk key")
	if voice != null:
		var mic := DotVoiceSourceBuffer.new()
		mic.sample_rate = voice.config.sample_rate
		mic.write(DotVoiceSourceBuffer.tone(440.0, 0.2, mic.sample_rate, 0.4))
		voice.source = mic
		extras.set_talking(true)
		for _i in range(4):
			await get_tree().process_frame
		extras.set_talking(false)
	_check(voice != null and voice.frames_sent > 0 and relayed.size() == voice.frames_sent,
		"holding it sends the player's speech to the server (%d sent, %d relayed)" % [voice.frames_sent if voice != null else 0, relayed.size()])

	# [b]The player's block list (sm) reaches arena's voice.[/b] dot-chat's DotChatSelfMute
	# binds whatever is published as dot_voice_client; arena's manager did not publish, so
	# `sm` muted a player's lines here and never their voice.
	_check(voice != null and DotRegistry.get_service(&"dot_voice_client") == voice,
		"the client's voice is published as dot_voice_client")
	var self_mute := DotChatSelfMute.new()
	self_mute.path = "user://arena_net_self_mute.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(self_mute.path))
	const TALKER := 1_900_000_001
	self_mute.set_roster([{"id": 9, "name": "Loud", "key": "loud-key", "peer": TALKER}], 2)
	self_mute.attach_voice(DotRegistry.get_service(&"dot_voice_client"))
	var heard_buffer := DotVoiceSinkBuffer.new()
	if voice != null:
		heard_buffer.sample_rate = voice.config.sample_rate
		voice.sink_factory = func(_speaker: int) -> DotVoiceSink: return heard_buffer
	var talk := func() -> void:
		var codec := DotVoiceCodec.instance_for(voice.config.codec_id)
		for i in range(10):
			var packet := DotVoicePacket.new()
			packet.speaker = TALKER
			packet.sequence = i
			packet.starts_talk_spurt = i == 0
			packet.sample_count = voice.config.frame_samples()
			packet.codec_id = voice.config.codec_id
			packet.payload = codec.encode(DotVoiceSourceBuffer.tone(300.0, voice.config.frame_ms / 1000.0, voice.config.sample_rate, 0.4))
			var _r := voice.receive(packet.to_bytes())
	self_mute.set_muted({"key": "loud-key", "name": "Loud"}, true)
	if voice != null:
		talk.call()
		for _i in range(15):
			await get_tree().process_frame
	_check(voice != null and voice.is_locally_muted(TALKER) and heard_buffer.frames_written == 0,
		"sm on a player: their voice frames arrive and are not played (%d played)" % heard_buffer.frames_written)
	self_mute.set_muted({"key": "loud-key", "name": "Loud"}, false)
	if voice != null:
		talk.call()
		var deadline := Time.get_ticks_msec() + 1000
		while heard_buffer.frames_written == 0 and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
	_check(heard_buffer.frames_written > 0, "and unmuted, the same frames play (%d)" % heard_buffer.frames_written)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(self_mute.path))
	extras.queue_free()
	client_bridge.link = held_link

	server_link.queue_free()
	client_link.queue_free()
	remove_child(server_link)
	remove_child(client_link)
	_done()


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


## A player dies and THEIR CLIENT draws the death camera, then hands it over.
##
## [b]Until 2026-09-25 a networked client drew no death camera at all.[/b] The spectate
## layer was built on every side, but on a client it was fed by `game.player_killed`, which
## only the authority emits (dot-combat resolves no deaths on a mirror), and ticked by
## `game.tick`, which a networked client never calls — so `is_spectating` was false for the
## whole of every death and the camera stayed on the body. Every check about the camera
## ran on an offline or authoritative game, where the same code is fed and ticked.
func _test_client_death_camera() -> void:
	print("")
	_section("[the death camera on a client]")

	var client: Dictionary = _clients[2]
	var client_game: ArenaGame = client["game"]
	var victim := 11
	var killer := 12

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

	# The server brings them back — what its respawn does, called directly, because this
	# harness's match has been through a map change and a warmup by now and when it would
	# respawn somebody is dot-match's business, not this check's. What is under test is
	# the client reading "alive again" off the replicated health, having heard no spawn.
	_server_game.player_for(victim).spawn(_server_game.map.spawns[0], _server_game.current_tick())
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


## The horde reaches a connected client: a monster the server spawns is drawn, follows the
## server's, and goes when the server's does.
##
## [b]Monsters were never replicated.[/b] The horde ran on the server only, so a player on a
## dedicated server was hurt by monsters they could not see; every check about the horde ran
## on an authoritative game, where the monsters are real bodies in the same tree. Last,
## because the disconnect section counts the registry, and a monster is an entity in it.
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
	var mirror: Node3D = client_bridge.get("_monster_mirrors")[net_id].body
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

	horde.spawner.remove(monster.instance_id, DotNpcSpawner.REASON_ADMIN)
	_check(not _server_bridge.get("_monster_nets").has(monster.instance_id), "the server lets it go")
	_deliver_event(2, ArenaEvents.Kind.NPC_GONE, ArenaEvents.write_npc_gone(net_id))
	_check(client_bridge.monster_count() == 0, "and so does the client")

	_server_game.horde = null
	horde.queue_free()
	_pump(1)
	_done()


## An administrator noclips a player on the server, and the player's own client — which
## has no noclip permission of its own — has to PREDICT it.
##
## [b]The symptom this exists for is rubber-banding, and no server-side check can see
## it.[/b] Set naively — `state.mode = NOCLIP` on the server — the client's replay runs its
## own noclip gate, which is closed, drops the player to AIR on every replayed tick, and is
## pulled back by every snapshot: the player flickers between flying and falling while
## every number on the server is right. So this flies the player straight up for a second
## and compares, tick by tick, where the client predicted them against where the server
## put them — once the shipped way and once the naive way, and requires the first to agree
## and the second not to. Without the second half, "agrees" could be a window in which the
## client was never asked to disagree.
##
## [b]Not `DotNetPredictor.correction_rate`.[/b] That was the first measure written here and
## it read 0.0% for BOTH, with a worst error of 0.000 m across the whole run: it measures
## the player NODE before and after a reconcile, and in this harness nothing moves the
## node of a headless player between the two. A measure that cannot see the bug it is
## pointed at is the family's "reports its healthy case while blind", so the comparison is
## on the simulated state, which is what a player's camera follows.
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


## A server owner's movement rules (`arena_slide*`, `arena_launch*`) reach every client.
##
## [b]A client predicting with different numbers mispredicts every slide and every launch[/b],
## and the symptom is rubber-banding that looks like lag. So: the rule lands on the client's
## game and its copy of the player, the two ends' fingerprints match, a launch is predicted
## to within a hand's width — and, the negative control, a launch changed on the server
## alone is not.
func _test_movement_rules_reach_clients() -> void:
	print("")
	_section("[movement rules reach every client]")

	var entry: Dictionary = _clients[2]
	var session := int(entry["session"])
	var server_player: ArenaPlayer = _server_bridge.behaviour_for(session).player
	var client_game: ArenaGame = entry["game"]
	var client_player: ArenaPlayer = (entry["bridge"] as ArenaNetBridge).behaviour_for(session).player

	_check(
		client_player.controller.tunables.slide_enabled and client_player.controller.tunables.launch_enabled,
		"the arena slides and launches by default, on the client as on the server"
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

	# Somewhere with nothing overhead: the noclip section's spot is under the south
	# arcade, whose roof stopped the first launch measured here at 1.19 m.
	# The match may still be moving WARMUP to COUNTDOWN here (join and loading timing
	# decide when), and the state change respawns everybody: a launch cut by that is a
	# respawn, not a misprediction (5.59 m at the tick it happened). Wait for it first.
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
	var launch := _flight_window(2, 64, DotFpsCommand.BUTTON_USER_0)
	print("  measured: launch peak %.2f m, worst gap %.2f m (%s)" % [float(peak[0]) - start_y, float(launch["worst_gap"]), launch["worst_at"]])
	_check(float(peak[0]) - start_y > 3.0, "E throws the server's player into the air (from %s)" % open_sky,
		"%.2f m" % (float(peak[0]) - start_y))
	_check(float(launch["worst_gap"]) < 0.05, "and the client predicts it to within five centimetres",
		"worst %.2f m" % float(launch["worst_gap"]))

	# The negative control: the same change made on the server's player alone. In this
	# lockstep harness a wrong impulse is corrected within a snapshot or two, so the gap
	# above cannot tell a shared rule from a server-only one (0.38 m against 0.42 m when it
	# was tried); what can is the fingerprint the two ends compare at connect.
	server_player.controller.tunables.launch_velocity = 24.0
	_check(
		client_player.controller.tunables.fingerprint() != server_player.controller.tunables.fingerprint(),
		"a launch changed on the server alone leaves the two ends' movement apart",
		"if this passes quietly, the fingerprint check above proves nothing"
	)

	_server_game.set_movement_rules({"launch_velocity": 12.0, "slide_boost": 3.5})
	_server_game.movement_rules_changed.disconnect(relay)
	# Back where the sections after this one expect the player: the noclip section's spot.
	server_player.controller.teleport(Vector3(0.0, 0.1, 18.0))
	server_player.controller.state.velocity = Vector3.ZERO
	var _back := _flight_window(0, 32, 0)
	_done()


## A wall run and a wall jump, predicted by the client and run by the server, over this
## harness's one-in-five loss.
##
## [b]Every bit of a wall move the next tick reads rides in `net_flags`[/b] (the run's
## time, the jump counts, the wall's heading), and a client that replays a tick without
## one of them puts the player somewhere else: off the wall, or allowed a second jump off
## it. So the north gallery's two wall routes are driven from the client's own predicted
## state, the way a player would, and both ends have to make the route, agree to within the
## snapshot's rounding all the way through the loss, and end up in the same place.
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
		# Five centimetres. `_driven_window` plays the link the way a real one plays (the
		# client ahead of its snapshots, each command early with its copies), so what is
		# left is the snapshot's own rounding, 5 to 7 mm whichever tick the presses fall
		# on. A wall jump a tick late is 0.1 m in its first tick; this used to allow 0.35
		# because the harness itself made every jump a tick late on the client, and the
		# gap was then only as big as the wait for the next snapshot.
		_check(
			float(measured["worst_aligned"]) < 0.05 and landed_apart < 0.01,
			"%s: the client predicted it within five centimetres of the server, and lands where it does" % name,
			"worst %.3f m at %s, %.3f m apart once down" % [float(measured["worst_aligned"]), measured["worst_at"], landed_apart]
		)

	server_player.controller.teleport(Vector3(0.0, 0.1, 18.0))
	server_player.controller.state.velocity = Vector3.ZERO
	var _back := _flight_window(0, 32, 0)
	_done()


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


## An administrator's blind and beacon, through the real handlers, over the lossy link.
##
## [b]The audience is the whole point of both.[/b] Client 2 owns player 11. A blind is
## that player's screen and nobody else's, so client 2 must get it and client 3 must NOT —
## an opponent who could read it would know the moment somebody could not see them. A
## beacon is for everybody, so both must get it. Asserted on each client's own copy of
## the player, which is what its HUD and its renderer read.
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


## What a player carries reaches their own client, what they hold reaches everybody, the
## use counter crosses, a replayed tick is silent, and a launch flies on a client.
##
## [b]Before this, a connected client's arsenal was EMPTY for the whole match.[/b] A
## loadout is resolved from a store on the server and nothing sent the result, so the
## client predicted no shot, drew no flash, its HUD read zero and its number keys selected
## nothing, while the server fired everything correctly — and `[audience]` above wrote it
## down as "not asserted". `net_carry` (owner-only) and `net_weapon` (everybody's) are the
## two fields that close it.
func _test_weapons_over_the_wire() -> void:
	print("")
	_section("[weapons over the wire]")

	_pump(16)

	var owner: ArenaNetBridge = _clients[2]["bridge"]
	var watcher: ArenaNetBridge = _clients[3]["bridge"]
	var served := _server_bridge.behaviour_for(11).player
	var own := owner.behaviour_for(11)
	var seen := watcher.behaviour_for(11)

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
	for i in range(TICK_RATE / 2):
		t += 1
		own._net_apply_input(idle, t)
		own._net_simulate(t, 1.0 / float(TICK_RATE))

	var rewind := own.player.weapons.snapshot()
	t += 1
	own._net_apply_input(shoot, t)
	own._net_simulate(t, 1.0 / float(TICK_RATE))
	var fresh := uses.size()
	_check(fresh == 1, "a fresh predicted shot is drawn", str(fresh))

	var _restored := own.player.weapons.restore(rewind)
	_check(own.is_replay(t), "the same tick again is known to be a replay")
	own._net_apply_input(shoot, t)
	own._net_simulate(t, 1.0 / float(TICK_RATE))
	_check(
		uses.size() == fresh,
		"and replaying it draws nothing — once per shot, not once per correction",
		"%d uses after the replay" % uses.size()
	)

	# A launch the server announces flies on a client, and hurts nobody there.
	var client_game: ArenaGame = _clients[2]["game"]
	var gone: Array = []
	client_game.projectiles.detonated.connect(func(at: Vector3, _s: DotWeaponSpawn) -> void:
		gone.append(at)
	)
	var spawn := DotWeaponSpawn.make(
		ZeeWeaponIds.FRAG, own.player.controller.state.position + Vector3(0.0, 1.5, 0.0),
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
		and ArenaContent.weapon_at(int(read["weapon"])) == ZeeWeaponIds.FRAG
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
	_done()


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
	# Measured only once a snapshot from inside the window has arrived. Until then the
	# client cannot know anything the server did at the top of it — the first run of this
	# measured 159 m, which was the client's copy still where an earlier section had
	# parked it — and "the client has not heard yet" is latency, not rubber-banding.
	var heard_before: int = (
		int(_clients[peer]["net"].stats.packets_received) if peer != 0 else 0
	)

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

		# Not past the window's last tick: a command for a tick nobody here runs would sit
		# in the server's buffer ahead of the next window's own for that tick.
		if tick < first + ticks - 1:
			commands = send.call(tick + 1)
		_server_bridge.server_tick(tick)
		var apart := server_a.controller.state.position - server_b.controller.state.position
		closest = minf(closest, Vector2(apart.x, apart.z).length())

		# Both ends have run this tick: what the client predicted, against what the server
		# did, before this tick's snapshot replaces the prediction.
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

## Players are solid to each other (`mp_solidplayers`, 1 by default): a walk into another
## player stops two radii apart on the server, and the walker's own client predicts the same
## stop. Then, at 0 on both ends (the cvar is replicated), the same walk passes through.
##
## [b]Arena's own, not the family's hull.[/b] Movement here is analytic on the server and on
## every predicting client, so dot-player-controller's physics capsule reached neither, and
## until 2026-10-12 everybody walked through everybody (fpt-arena-solid-players-1).
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
	server_a.controller.teleport(saved_a)
	server_b.controller.teleport(saved_b)
	var _back := _flight_window(0, 24, 0)
	_done()


func _test_event_wire() -> void:
	print("")
	_section("[events]")

	# Every encoder and its decoder, round-tripped. **The two ends of a serialisation
	# are exactly as capable of never meeting as the two ends of a wire** — this family
	# has shipped a stored voice mute that loaded back as a warning, and a leaderboard
	# reporter whose file format was not its wire format. Nothing checks that a pair are
	# inverses except a test that runs both.
	var hello := ArenaEvents.read_hello(DotNetReader.new(
		ArenaEvents.write_hello(128, 4242, 7, 90210, "dm_box", 25, 600.0)
	))
	_check(bool(hello["ok"]), "a HELLO round-trips")
	_check(int(hello["tick_rate"]) == 128, "with the tick rate", str(hello["tick_rate"]))
	_check(int(hello["session_id"]) == 4242, "the session id it names")
	_check(int(hello["peer_id"]) == 7, "the peer id")
	_check(int(hello["server_tick"]) == 90210, "the server's tick")
	_check(String(hello["map_name"]) == "dm_box", "and the map")
	_check(int(hello["score_limit"]) == 25, "and the rules")

	var kill := ArenaEvents.read_kill(DotNetReader.new(
		ArenaEvents.write_kill(11, 12, "rifle", true)
	))
	_check(bool(kill["ok"]), "a KILL round-trips")
	_check(
		int(kill["killer_id"]) == 11 and int(kill["victim_id"]) == 12,
		"with both players"
	)
	_check(String(kill["weapon"]) == "rifle", "the weapon")
	_check(bool(kill["headshot"]), "and the headshot flag")
	_check(not bool(kill["critical"]), "and no critical unless one was written")

	var critical := ArenaEvents.read_kill(DotNetReader.new(
		ArenaEvents.write_kill(11, 12, "sniper", true, true)
	))
	_check(bool(critical["ok"]) and bool(critical["critical"]), "a lethal critical says so")

	# An older server's KILL ends after the headshot. The padding to the byte is zeros, so
	# the reader finds no critical rather than a garbage one.
	var old := DotNetWriter.new()
	old.write_varint(11)
	old.write_varint(12)
	old.write_string("rifle", ArenaEvents.WEAPON_BYTES)
	old.write_bool(true)
	var older := ArenaEvents.read_kill(DotNetReader.new(old.to_bytes()))
	_check(bool(older["ok"]) and not bool(older["critical"]), "and an older server's kill reads as no critical")

	var rules := ArenaEvents.read_rules(DotNetReader.new(ArenaEvents.write_rules(
		{"slide_boost": 2.5, "fp_body": 1.0, "break_mode": 2.0}
	)))
	# A drop and its take, through a client's real event handler: the coin a server says
	# player 11 took is on that client's tally, which is what its HUD reads.
	var client_game: ArenaGame = _clients[2]["game"]
	var client_bridge: ArenaNetBridge = _clients[2]["bridge"]
	if client_game.drops != null:
		var before := int(client_game.drops.coins.get(11, 0))
		var _d := client_bridge.receive_event(_server_bridge.encode_event(
			ArenaEvents.Kind.DROP, ArenaEvents.write_drop(9001, 0, 3, Vector3.ZERO, Vector3(1, 0, 1))
		))
		var _t := client_bridge.receive_event(_server_bridge.encode_event(
			ArenaEvents.Kind.TAKEN, ArenaEvents.write_taken(9001, 11)
		))
		_check(int(client_game.drops.coins.get(11, 0)) == before + 3,
			"a coin taken on the server is on the client's tally (+3)")
	else:
		_check(false, "the client has a drops layer")

	_check(
		bool(rules["ok"]) and is_equal_approx(float(rules["rules"]["slide_boost"]), 2.5)
			and float(rules["rules"]["fp_body"]) == 1.0 and float(rules["rules"]["break_mode"]) == 2.0,
		"RULES round-trips movement and presentation rules alike", str(rules["rules"])
	)

	# The world kills as 0, not as a name. It is the one value with two shapes, and a
	# string on the wire for it is a string somebody eventually puts a name in.
	var world := ArenaEvents.read_kill(DotNetReader.new(
		ArenaEvents.write_kill(0, 12, "fall", false)
	))
	_check(int(world["killer_id"]) == 0, "and the world kills as 0")

	var state := ArenaEvents.read_match(DotNetReader.new(
		ArenaEvents.write_match(3, 1920, 5)
	))
	_check(bool(state["ok"]), "a MATCH round-trips")
	_check(int(state["state"]) == 3 and int(state["round"]) == 5, "with the state and round")
	_check(int(state["remaining_ticks"]) == 1920, "and the clock, in ticks")

	# Negative, because "no limit" is negative and a match past its clock reports a
	# negative remainder. A uint here would have wrapped it to four billion.
	var over := ArenaEvents.read_match(DotNetReader.new(
		ArenaEvents.write_match(3, -64, 5)
	))
	_check(int(over["remaining_ticks"]) == -64, "and a clock past zero stays negative")

	# The score limit rides at the end, because an extend raises it mid-match and HELLO
	# is sent once. A MATCH without it — an older server — keeps the limit it had.
	var limited := ArenaEvents.read_match(DotNetReader.new(
		ArenaEvents.write_match(3, 1920, 5, 35)
	))
	_check(
		bool(limited["ok"]) and int(limited.get("score_limit", -1)) == 35
			and not state.has("score_limit"),
		"and the score limit an extend raised, only when it is sent"
	)

	var leave := ArenaEvents.read_leave(DotNetReader.new(ArenaEvents.write_leave(99)))
	_check(bool(leave["ok"]) and int(leave["session_id"]) == 99, "a LEAVE round-trips")

	var notice := ArenaEvents.read_notice(DotNetReader.new(
		ArenaEvents.write_notice("Match point")
	))
	_check(
		bool(notice["ok"]) and String(notice["text"]) == "Match point",
		"a NOTICE round-trips"
	)

	# The map vote's cue and countdown. The one event whose two halves are optional each:
	# a countdown second with no cue, a cue with no second. Both shapes round-trip.
	var counting := ArenaEvents.read_vote(DotNetReader.new(
		ArenaEvents.write_vote("vote_count", 7, true)
	))
	_check(
		bool(counting["ok"]) and String(counting["cue"]) == "vote_count"
			and int(counting["seconds_left"]) == 7 and bool(counting["runoff"]),
		"a VOTE round-trips, with the cue, the second and the runoff flag"
	)
	var opening := ArenaEvents.read_vote(DotNetReader.new(
		ArenaEvents.write_vote("vote_start", 0, false)
	))
	_check(
		bool(opening["ok"]) and String(opening["cue"]) == "vote_start"
			and int(opening["seconds_left"]) == 0 and not bool(opening["runoff"]),
		"and a cue with no countdown second is exactly that"
	)
	_check(
		ArenaEvent.new(ArenaEvents.Kind.VOTE, PackedByteArray()).validate().ok,
		"and VOTE is a kind the message validates"
	)

	var hit := ArenaEvents.read_hit(DotNetReader.new(
		ArenaEvents.write_hit(12, 87.4, Vector3(12.5, 1.4, -30.25), true, false)
	))
	_check(
		bool(hit["ok"]) and int(hit["victim_id"]) == 12 and int(hit["amount"]) == 87
			and (hit["point"] as Vector3).distance_to(Vector3(12.5, 1.4, -30.25)) < 0.02
			and bool(hit["headshot"]) and not bool(hit["lethal"]),
		"a HIT round-trips: victim, whole hit points, where, head, not lethal", str(hit)
	)
	var award := ArenaEvents.read_award(DotNetReader.new(
		ArenaEvents.write_award(11, 12, 225, 6, [0, 1, 10])
	))
	_check(
		bool(award["ok"]) and int(award["killer_id"]) == 11 and int(award["victim_id"]) == 12
			and int(award["points"]) == 225 and int(award["streak"]) == 6
			and award["medals"] == [0, 1, 10],
		"an AWARD round-trips: both players, points, streak and the medals in order", str(award)
	)
	_check(
		ArenaEvents.Kind.HIT == ArenaEvents.Kind.TAKEN + 1 and ArenaEvents.Kind.AWARD == ArenaEvents.Kind.HIT + 1,
		"and both were appended after TAKEN, so no older kind moved"
	)

	var score := ArenaEvents.read_score(DotNetReader.new(ArenaEvents.write_score(11, 7, 3)))
	_check(
		bool(score["ok"]) and int(score["kills"]) == 7 and int(score["deaths"]) == 3,
		"a SCORE round-trips"
	)

	# A truncated body must not read as a valid event of nothing. `StreamPeerBuffer`
	# reads past its end by returning zeros rather than failing, and dot-timer shipped a
	# replay that parsed that way; `DotNetReader.ok()` is the equivalent here and it is
	# sticky, so a decoder that skipped the check gets a plausible value for the field
	# AFTER the overrun.
	var truncated := ArenaEvents.read_hello(DotNetReader.new(
		ArenaEvents.write_hello(128, 1, 1, 1, "dm_box", 25, 600.0).slice(0, 3)
	))
	_check(not bool(truncated["ok"]), "and a truncated HELLO is refused, not guessed")

	# Both message types validate their kind, so a peer that disagrees about the schema
	# is a refusal rather than an out-of-range read.
	_check(
		not ArenaEvent.new(ArenaEvents.Kind.size(), PackedByteArray()).validate().ok,
		"an unknown event kind is refused"
	)
	_check(
		ArenaEvent.new(ArenaEvents.Kind.HELLO, PackedByteArray()).validate().ok,
		"and a known one is not"
	)

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	_check(ArenaEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [ArenaEvents.Kind.size(), ArenaEvent.KIND_BITS])
	_check(ArenaRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [ArenaEvents.Ask.size(), ArenaRequest.KIND_BITS])
	_check(ArenaEvents.prop_acts_fit(), "every prop act fits the prop request's act field",
		"%d acts in %d bits" % [ArenaEvents.PropAct.size(), ArenaEvents.PROP_ACT_BITS])

	_done()


func _test_ready_gate() -> void:
	print("")
	_section("[the ready gate]")

	# **Nothing may be sent to a peer before it says it can receive.** dot-server's
	# signon finishes and THEN the client builds its scene, so everything sent in
	# between lands on a node that does not exist and is lost — one "Node not found"
	# per call, and a client that never learns who it is. game-hungario found this the
	# hard way and the gate is what came out of it.
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


func _test_predicted_node_is_not_moved() -> void:
	print("")
	_section("[the predicted entity's node]")

	# `DotNetManager.receive_snapshot` calls `read_state` — and therefore
	# `_net_state_applied` — BEFORE `DotNetPredictor.reconcile`, and the first thing
	# reconcile does is read the node as "what the client is showing" so it can measure
	# the correction. Writing the server's position there first makes that measurement
	# the entire replay distance: every reconciliation logs a snap, the correction rate
	# reads near 1.0, and the simulation is right the whole time.
	#
	# game-hungario had this exact line and the family's notes have listed it as unfixed
	# here ever since. Nothing in this file could see it before: the check is not on a
	# position, it is on WHETHER THE NODE MOVED, which no assertion about the
	# simulation can reach.
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

	# **A quantised value decoded against a different range is a different value, not a
	# less precise one.** `world_extent` is the range every replicated position is an
	# integer over, and the server and the client used to write it separately — 128 in
	# `ArenaModule`, 256 in `ArenaClient`, in two files a hundred lines apart.
	#
	# What that looked like, in a real browser against a real server: the client
	# connected, sealed an identical message schema, adopted its own player alive with
	# 100 health, logged every stage correctly — and drew sky in every direction with a
	# HUD reading zero. No error anywhere, because there is no error: both ends did
	# exactly what they were told.
	#
	# The fix is that there is now one constant and nothing to keep in step. This check
	# is what stops somebody typing a number into one of the two again.
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

		# The tick rate is the other number the two ends must not disagree about, and
		# the one this family has already paid for: a client counting at its own rate
		# against a 128-tick server read a 0.218 s finish as 0.466 s and never
		# converged. HELLO carries it; `_adopt_tick_rate` is what applies it.
		_check(
			net.config.tick_rate == _server_net.config.tick_rate,
			"and counts at the same rate",
			"%d vs %d" % [net.config.tick_rate, _server_net.config.tick_rate]
		)

	# The schema hash is the third. Two peers that registered different message types,
	# or the same ones in a different order, hash differently — and `Array.sort()` on a
	# StringName sorts by interned POINTER, which every suite in this family missed by
	# running both ends in one process and sharing one intern table.
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
