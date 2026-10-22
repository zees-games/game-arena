extends Node

const ArenaEvent := preload("arena_event.gd")
const ArenaContent := preload("arena_content.gd")
const ArenaEvents := preload("arena_events.gd")
const ArenaGame := preload("arena_game.gd")
const ArenaNetCommand := preload("arena_net_command.gd")
const ArenaNetLink := preload("arena_net_link.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaPlayerNet := preload("arena_player_net.gd")
const ArenaToyNet := preload("arena_toy_net.gd")
const ArenaNpcNet := preload("arena_npc_net.gd")
const ArenaNpcs := preload("arena_npcs.gd")
const ArenaBots := preload("arena_bots.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")
const ArenaRequest := preload("arena_request.gd")

## Joins [ArenaGame] to a [DotNetManager]. The netcode seam, and the only file in
## game-arena that names both.
##
## [b]Every other join in this project is a few lines because the addons refuse to
## know about each other; this one is a file because the ordering is the hard part.[/b]
## dot-net drives simulation per entity, and this game's tick order is a whole-game
## property — everybody moves, then every shot is resolved against the world as it is
## afterwards, then the match clock runs. Those two facts have to be reconciled
## somewhere, and this is where.
##
## [codeblock]
## # server
## bridge.attach(game, net)
## bridge.add_player(peer_id, session_id, "Ada")
## bridge.server_tick(tick)                      # instead of game.tick()
##
## # client
## bridge.attach(game, net)
## bridge.apply_join(join_bytes)                 # from the server
## socket.send(bridge.encode_input(tick, move, fire))
## bridge.receive_snapshot(payload)
## bridge.client_tick(tick, move, fire)
## [/codeblock]

const CHANNEL := "arena.net"

## Bytes [method DotNetManager.encode_ack] produces, and the prefix of every input
## packet. Fixed width, so the command that follows starts at a known offset.
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so a packet lost
## costs the server no tick unless four more after it are lost too. See [method encode_input].
##
## [b]Five, not three (2026-10-09).[/b] With three, at 20% loss the server was still short
## of the command on 1.7% of its ticks in a bad run (headless_lossy: "a hole 4 times, not
## there yet 7 times" of 641), ran each on the previous one while the player was turning,
## and the prediction was off by over 5 cm on more than one tick in twenty until the
## correction landed -- one run in twenty failing on it. Two more copies are a few bytes
## each (a varint tick step and a command that is mostly the one before it).
const INPUT_COPIES := 5

## Input packets taken, per peer. Server side; what `arena_net` reads to tell one client's
## lossy uplink from another's.
var inputs_from: Dictionary = {}

## Announced a player. Server side: these bytes go to every client.
signal player_announced(payload: PackedByteArray)

## The most an avatar document may take in a JOIN. Arena's three slots are about two
## hundred bytes; the rest is room, and a cap a hostile document cannot talk past.
const AVATAR_BYTES := 1024

## `func(session_id: int) -> DotAvatar`: what a player looks like, asked as they are
## seated and whenever the module re-announces them. Set by the module, which has the
## identity layer; unset or null is the stock figure, which every client derives alike.
var avatar_fn: Callable = Callable()

var game: ArenaGame = null
var net: DotNetManager = null

## player id -> ArenaPlayerNet, for the ones this process knows about.
var _behaviours: Dictionary = {}

## peer id -> player id.
var _players_by_peer: Dictionary = {}

var _game_ticked_for: int = -1
var _tick: int = 0

## The RPC surface, on both ends. Created by [method attach].
var link: ArenaNetLink = null

## [code]func(bytes: PackedByteArray) -> void[/code]. Where a received voice frame
## goes on a client. [ArenaClient] points it at `DotVoiceManager.receive`.
##
## A callable rather than a typed reference, because this file must not name dot-voice:
## a server build with no voice addon installed would otherwise fail to parse, and the
## whole point of the bridge is that it is the only file naming two things at once.
var voice_in_fn: Callable = Callable()

## [code]func(speaker_peer: int, bytes: PackedByteArray) -> void[/code]. Where a
## client's captured audio goes on a server. [ArenaServices] points it at
## `DotVoiceRouter.relay`.
var voice_relay_fn: Callable = Callable()

## [code]func(payload: Dictionary) -> void[/code]. A map-change announcement, client
## side. [ArenaClient] points it at `DotMapSyncClient.handle`.
var map_in_fn: Callable = Callable()

## [code]func(peer: int, payload: Dictionary) -> void[/code]. A client's map progress
## or readiness, server side. [ArenaModule] points it at `DotMapSyncHost.handle`.
var map_report_fn: Callable = Callable()

## [code]func(peer: int) -> void[/code]. A peer said READY, server side. [ArenaModule]
## points it at [method ArenaMapDirector.admit_peer], which tells the peer the map the
## server is on: a client builds its world on the default map and, without this, stays
## there until the next change, predicting against walls the server does not have.
var peer_ready_fn: Callable = Callable()

## How the client learns its round-trip time, in milliseconds.
##
## [b]Nothing in dot-net writes an RTT sample, and it needs one.[/b]
## `DotNetStats` has a median and a mean-absolute-deviation behind it, and
## `receive_snapshot` reads `rtt_percentile(0.5)` on every snapshot to feed the clock —
## while no caller anywhere in dot-net writes a sample, because dot-net never touches a
## transport. The host has to feed it and nothing said so. A client points this at
## `DotClientLink.ping_ms`.
##
## What it costs when it is unset: the clock's input lead has to include the flight
## time, because a command stamped for tick N must be in the server's hands BEFORE it
## simulates N. With no samples the lead is a guess, and on any link past about 30 ms
## every input arrives after its tick has passed and is discarded as late — the player
## moves perfectly on their own screen and nowhere else.
##
## [b]Point it at [method link_rtt_ms], not at `ping_ms` alone.[/b] See there.
var rtt_source: Callable = Callable()


## A client link's round trip, in milliseconds: ENet's own measurement when the link is on
## ENet, and dot-server's heartbeat ping otherwise. 0 while neither knows.
##
## [b]Why not just `DotClientLink.ping_ms`.[/b] That is one heartbeat every two seconds,
## sent unreliable, and it is -1 until the first comes back -- once, through a real UDP
## relay (`headless_lossy`), eight seconds after connecting. Until then the clock believes
## the link is instant and leaves the flight time out of its input lead, so the commands
## arrive after their ticks and are thrown away while the player moves perfectly on their
## own screen: on a steady 55 ms each way, the server had the client's command for 46% of
## its ticks in the first three seconds, 102 of them late (`--ping-rtt`, the control).
## ENet times every acknowledged packet from the connect handshake on, so on ENet its
## number is right before the first snapshot lands (100% in time, 0 late). Read by duck
## typing, because a web build has no ENet class to name.
static func link_rtt_ms(link: Node) -> float:
	if link == null or not is_instance_valid(link):
		return 0.0

	var api := link.multiplayer
	var peer: Object = api.multiplayer_peer if api != null else null

	if peer != null and peer.has_method("get_peer") and ClassDB.class_exists(&"ENetPacketPeer"):
		var server: Object = peer.call("get_peer", 1)

		if server != null and server.has_method("get_statistic"):
			var stat := ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_ROUND_TRIP_TIME")
			var rtt := float(server.call("get_statistic", stat))

			if rtt > 0.0:
				return rtt

	if link.has_method("ping_ms"):
		return float(maxi(0, int(link.call("ping_ms"))))

	return 0.0

## Peers that have said they can receive. Server side.
##
## [b]Nothing may be sent to a peer before it says READY.[/b] dot-server's signon
## finishes and *then* the client builds its scene, so everything sent in between lands
## on a node that does not exist and is lost — one "Node not found" per call, and a
## client that never learns who it is.
var _ready_peers: Dictionary = {}

## Peers whose READY came before their seat ([method add_player]). Server side.
##
## [b]Kept, not answered.[/b] A client sends READY when its link says PLAYING, which the link
## decides itself after sending `loaded` on another channel; over ENet with loss the READY can
## overtake `loaded` and so the seat. Answered then, its HELLO named session 0 and its signon
## no player of its own: a client with a world and no idea which body is its own, for good,
## because nothing sends a HELLO again. The seat answers it instead.
var _ready_unseated: Dictionary = {}

## Whether this end has had its HELLO. Client side.
var _hello: Dictionary = {}



## Emitted on a client when HELLO arrives, with what it said.
signal hello_received(info: Dictionary)

## Emitted on a client for anything the server wants shown as text.
signal notice_received(text: String)

## Emitted on a client for the map vote: a cue to play and a countdown second, from
## [method ArenaEvents.read_vote].
signal vote_received(info: Dictionary)

## Emitted on a client when the server reports a kill.
signal kill_received(info: Dictionary)

## Emitted on a client when the match state or clock changes.
signal match_received(info: Dictionary)

## Emitted on a client when its own damage landed: [method ArenaEvents.read_hit].
signal hit_received(info: Dictionary)

## Emitted on a client for every kill's medals and points: [method ArenaEvents.read_award].
signal award_received(info: Dictionary)

## This tick's confirmed hits, summed: attacker -> victim -> [amount, point, headshot,
## lethal]. Server side; sent and cleared after the tick ([method _flush_hits]).
var _pending_hits: Dictionary = {}


## Binds a game and a manager to each other.
func attach(p_game: ArenaGame, p_net: DotNetManager) -> DotResult:
	if p_game == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs both halves.")

	if p_game.is_authority != p_net.is_server:
		# A game that thinks it is authoritative behind a client manager would
		# resolve its own hits; a server whose game is not authoritative would
		# resolve nobody's. Both are silent, and both are unplayable.
		return DotResult.fail(
			DotError.CODE_STATE,
			"The game and the manager disagree about who is authoritative.",
			"game.is_authority=%s, net.is_server=%s"
				% [p_game.is_authority, p_net.is_server]
		)

	game = p_game
	net = p_net

	net.send_fn = _send

	# Registered on BOTH ends, in the same order, because `DotNetMessageRegistry.seal`
	# assigns wire ids from a sort of the type names and hashes the resulting schema.
	# A type registered on one end only is two different ids and two different schema
	# hashes, and the peers disagree on the first connection. That is not theoretical:
	# `Array.sort()` on a StringName sorts by interned pointer, which every suite in
	# this family missed by running both ends in one process and sharing one intern
	# table, and a browser client — a genuinely separate program — found immediately.
	var event := net.messages.register(
		ArenaEvent.NAME,
		ArenaEvent,
		DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		ArenaRequest.NAME,
		ArenaRequest,
		DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(ArenaEvent.NAME, _on_event)
	net.messages.on(ArenaRequest.NAME, _on_request)

	# The map's toys: the server's leave the registry before their nodes go and the new ones are
	# named; a client's mirrors stay registered and are handed this end's toys when they exist.
	if net.is_server:
		game.toys_clearing.connect(_release_toys)
		game.toys_built.connect(_register_toys)
		if game.toys != null:
			_register_toys()
	else:
		game.toys_clearing.connect(_unpair_toys)
		game.toys_built.connect(_pair_pending_toys)

	if net.is_server:
		game.player_killed.connect(_on_player_killed)
		game.match_state_changed.connect(_on_match_state_changed)
		game.movement_rules_changed.connect(_on_movement_rules_changed)
		game.jail_changed.connect(_on_jail_changed)
		game.hit_confirmed.connect(_on_hit_confirmed)
		game.medals_awarded.connect(_on_medals_awarded)

	return DotResult.success(self)


## Creates the RPC surface under [param parent].
##
## Separate from [method attach] because the parent differs by end and by deployment:
## on a server it is the [DotServer] node, on a client the [DotClientLink], and in the
## headless suite it is a bare [Node] with a loopback in place of a socket. All three
## must be NAMED the same, because the name is the routing.
func open_link(parent: Node) -> ArenaNetLink:
	link = ArenaNetLink.attached_to(parent, self, net != null and net.is_server)
	# Through DotGameLink, not a bare add_child: the link sits under the server node (the
	# route is by path), so nothing frees it when this bridge's module unloads, and the next
	# load's link would be renamed `@Node@n` and every RPC to a client lost.
	DotGameLink.attach(link, parent, self, ArenaNetLink.NODE_NAME)
	return link


## Where dot-net's own outgoing bytes go.
##
## [param delivery] decides the call, not the caller: a snapshot is unreliable and an
## event is not, and dot-net knows which is which.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		# A client's reliable send is a request. dot-net sends exactly one through here --
		# its message schema, as it starts -- and it used to go to `send_event`, a call only
		# the server may make, which the server's end refuses.
		link.send_request(payload)


# --- Membership ------------------------------------------------------------

## Adds a player and makes them a replicated entity. Server side.
##
## [param session_id] is the id everything downstream uses — the scoreboard key, the
## combat entity id, the damage attribution and the loadout key. [b]It is not the peer
## id.[/b] A peer id is reassigned the moment someone reconnects, and everything keyed
## by one would be handed to the next player to join.
func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var added := game.add_player(session_id, display_name)

	if not added.ok:
		return added

	# Before registering, not after: the manager only builds snapshots for peers it
	# knows about and only holds an input buffer for those, so an entity registered
	# to an unknown peer is an entity nothing is ever sent about and nothing can be
	# driven by. It is silent — the server simulates it perfectly and alone.
	net.add_peer(peer_id)

	var identity := _build_identity(added.value as ArenaPlayer, peer_id)
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		net.remove_peer(peer_id)
		game.remove_player(session_id)
		return registered

	_players_by_peer[peer_id] = session_id

	var player := added.value as ArenaPlayer

	if player.avatar == null and avatar_fn.is_valid():
		var avatar: Variant = avatar_fn.call(session_id)
		player.avatar = avatar as DotAvatar if avatar is DotAvatar else null

	var payload := join_payload(session_id)
	player_announced.emit(payload)

	# [b]To everybody already in, not only to the next to arrive.[/b] A peer is sent
	# every player when it says READY, and nothing else ever sent a JOIN — so a client
	# never learned of anybody who joined after it, and `player_announced` was connected
	# only in the suite, which forwarded the bytes by hand and so could not see it. Ready
	# peers only: one that is not ready yet gets the whole roster when it is.
	send_event(0, ArenaEvents.Kind.JOIN, payload)

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		mark_ready(peer_id)

	return DotResult.success(identity)


## Tells everybody who somebody is now: a profile that arrived after they were seated,
## a new avatar, an operator's rename. Server side.
##
## [b]Through JOIN, which a client already applies to a player it has.[/b] A second
## message for "this person changed" would be a second thing a late joiner has to be
## told. An empty [param display_name] keeps the one they have.
func refresh_player(session_id: int, display_name: String, avatar: DotAvatar) -> bool:
	if net == null or not net.is_server or not _behaviours.has(session_id):
		return false

	var behaviour: ArenaPlayerNet = _behaviours[session_id]

	if display_name != "":
		behaviour.player.display_name = display_name

	behaviour.player.avatar = avatar
	send_event(0, ArenaEvents.Kind.JOIN, join_payload(session_id))
	return true


## Mirrors a player the server has announced. Client side.
func mirror_player(
	net_id: int,
	peer_id: int,
	session_id: int,
	display_name: String
) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client mirrors.")

	if _behaviours.has(session_id):
		return DotResult.success(_behaviours[session_id])

	var added := game.add_player(session_id, display_name)

	if not added.ok:
		return added

	var identity := _build_identity(added.value as ArenaPlayer, peer_id)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)

	if not registered.ok:
		game.remove_player(session_id)
		return registered

	_players_by_peer[peer_id] = session_id
	return DotResult.success(identity)


## Builds the identity and behaviour that make an [ArenaPlayer] replicate.
##
## The behaviour is added before the identity on purpose: [DotNetIdentity] collects
## its behaviours in [code]_ready[/code], by walking the entity's subtree, and a
## behaviour added afterwards would never be found — the entity would register with
## nothing to replicate and simply never move on any other machine.
func _build_identity(player: ArenaPlayer, peer_id: int) -> DotNetIdentity:
	var behaviour := ArenaPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED, not SERVER: the server stays authoritative and corrects, and the owning
	# client predicts. `DotNetIdentity.is_predicted()` is false for any other
	# authority, so SERVER would mean a client that sees its own movement a full
	# round trip late — noticeable at 80 ms and unplayable at 150.
	identity.authority = DotNetIdentity.Authority.SHARED
	player.add_child(identity)

	_behaviours[player.player_id] = behaviour
	return identity


## Drops a peer's player from the game and from replication.
func remove_peer(peer_id: int) -> void:
	# A peer that said READY and left before its seat: a peer id is reused, and a stale entry
	# would answer the next owner's seat with a signon before it has asked.
	_ready_unseated.erase(peer_id)

	if not _players_by_peer.has(peer_id):
		return

	var session_id := int(_players_by_peer[peer_id])
	_players_by_peer.erase(peer_id)
	_behaviours.erase(session_id)
	_ready_peers.erase(peer_id)

	# Announced BEFORE the entity is unregistered, and to everybody still here.
	# A client that is only told an entity stopped arriving in snapshots has no way to
	# tell that from a player who walked out of its interest rectangle, so it would
	# leave a body standing in the arena for ever.
	if net != null and net.is_server:
		send_event(0, ArenaEvents.Kind.LEAVE, ArenaEvents.write_leave(session_id))

	if net != null:
		if net.is_server:
			# Releases the peer's entities, its input buffer and its acknowledgement
			# record in one place, so nothing is left keyed by a peer id that the
			# next player to connect will be given.
			net.remove_peer(peer_id)
		else:
			for identity in net.registry.take_owned_by(peer_id):
				net.registry.unregister(identity.net_id)

	game.remove_player(session_id)


func behaviour_for(session_id: int) -> ArenaPlayerNet:
	return _behaviours.get(session_id)


func session_for_peer(peer_id: int) -> int:
	return int(_players_by_peer.get(peer_id, 0))


# --- The tick --------------------------------------------------------------

## One authoritative tick. Server side, and it replaces [method ArenaGame.tick].
##
## [method DotNetManager.server_tick] hands each peer's input to the entities it owns,
## simulates, records history for lag compensation and sends snapshots — in that
## order, and the game tick has to happen between the first two. It does, from
## [method ArenaPlayerNet._net_simulate], through [method ensure_game_ticked].
##
## The call afterwards is not redundant. A server with no players registered runs no
## behaviours at all, and the match clock still has to advance — otherwise an empty
## server's warmup never ends and the first player to join arrives into a match that
## has been frozen since it booted.
## Monsters this server replicates: instance id -> their [ArenaNpcNet]. Server side.
var _monster_nets: Dictionary = {}

## Monsters this client draws: net id -> their [ArenaNpcNet]. Client side.
var _monster_mirrors: Dictionary = {}

## The horde spawner whose signals this bridge is connected to. A mode change builds a new
## horde, so this is checked every tick rather than connected once.
var _watched_spawner: DotNpcSpawner = null

## Where a client's monster mirrors live.
var _monster_world: Node3D = null


func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1
	_watch_horde()
	_watch_projectiles()
	_watch_drops()

	if net != null:
		net.server_tick(tick)

	ensure_game_ticked(tick)
	_flush_hits()


## Runs the whole game for a tick, at most once.
##
## Called from every replicated player's [code]_net_simulate[/code]; the first one
## through does the work.
func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick
	game.tick(_commands())

	# The toys where the physics left them, before the snapshot: a toy's own `_net_simulate`
	# can run before the player whose turns this tick.
	for behaviour: ArenaToyNet in _toy_nets:
		behaviour.pull()


## The command table [method ArenaGame.tick] takes, built from what each peer sent.
func _commands() -> Dictionary:
	var out: Dictionary = {}

	# A bot's commands are made here, in the slot a client's input lands in, so the game
	# ticks it exactly as it ticks a person. It sees the present, so no view lag.
	for session_id in _bot_minds:
		var behaviour: ArenaPlayerNet = _behaviours.get(session_id)
		if behaviour == null or behaviour.player == null:
			continue
		var made := ArenaBots.think(game, behaviour.player, _bot_minds[session_id], _tick, float(Engine.physics_ticks_per_second))
		behaviour.last_move = made[0]
		behaviour.last_fire = made[1]
		behaviour.last_view_lag = -1.0

	for session_id in _behaviours:
		var behaviour: ArenaPlayerNet = _behaviours[session_id]
		out[int(session_id)] = [behaviour.last_move, behaviour.last_fire, behaviour.last_view_lag]

	return out


# --- Bots ------------------------------------------------------------------

## Where a bot's session id starts. Far above any userid dot-server hands out (they count up
## from 1 for the life of the process), and far below the entity table's ids (10^12), so a
## bot's id is a player id like anybody's and can never be a person's.
const BOT_SESSION_BASE := 900_000_000

var _bot_minds: Dictionary = {}
var _next_bot := 0


## Adds a server-side bot called [param display_name]. Its session id, or 0 if the game
## refused it.
func add_bot(display_name: String) -> int:
	if net == null or not net.is_server:
		return 0

	_next_bot += 1
	var session_id := BOT_SESSION_BASE + _next_bot
	var added := game.add_player(session_id, display_name)

	if not added.ok:
		return 0

	var player := added.value as ArenaPlayer
	player.set_meta(&"bot", true)

	# Owned by the server (peer 0): nobody predicts it, every client mirrors it.
	var identity := _build_identity(player, 0)
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		_behaviours.erase(session_id)
		game.remove_player(session_id)
		return 0

	var mind := ArenaBots.Mind.new()
	mind.seed = session_id
	_bot_minds[session_id] = mind
	ArenaBots.world_for(game).warm()

	var payload := join_payload(session_id)
	player_announced.emit(payload)
	send_event(0, ArenaEvents.Kind.JOIN, payload)
	return session_id


## Takes a bot out, told to everybody as a leave.
func remove_bot(session_id: int) -> void:
	if not _bot_minds.has(session_id):
		return

	_bot_minds.erase(session_id)
	ArenaBots.forget(game, session_id)
	var behaviour: ArenaPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if net != null and net.is_server:
		send_event(0, ArenaEvents.Kind.LEAVE, ArenaEvents.write_leave(session_id))
		var identity := behaviour.player.get_node_or_null(^"Identity") as DotNetIdentity if behaviour != null and behaviour.player != null else null
		if identity != null and identity.net_id > 0:
			net.registry.unregister(identity.net_id)

	game.remove_player(session_id)


## The bots in the game, oldest first.
func bot_ids() -> Array[int]:
	var out: Array[int] = []
	for id in _bot_minds.keys():
		out.append(int(id))
	out.sort()
	return out


## One client tick: record the local command, predict, reconcile.
##
## The command is recorded into the behaviour and into the manager's input history
## before predicting, because reconciliation replays that history — an input the
## buffer never saw is a tick the replay cannot reproduce, and the correction is then
## measured against a state the server never computed.
func client_tick(tick: int, move: DotFpsCommand, fire: DotWeaponCommand) -> void:
	_tick = tick

	if net == null or net.is_server:
		return

	# A networked client never calls `game.tick`, so the spectate layer is advanced here
	# or not at all. See `ArenaSpectate.client_tick`.
	if game != null and game.spectate != null:
		game.spectate.client_tick(tick)

	# The copies of every rocket and grenade the server announced, flown for drawing.
	# Here for the same reason: nothing else ticks anything on a mirroring client.
	if game != null and game.projectiles != null:
		game.projectiles.tick(net.clock.tick_duration())

	var command := ArenaNetCommand.new()
	command.tick = tick
	command.delta = net.clock.tick_duration()
	command.move = move
	command.fire = fire
	command.view_lag_q = view_lag_q(tick)

	net.local_inputs().push(command)

	var t := Time.get_ticks_usec()
	# The snapshots read since the last tick, reconciled once against the newest, before
	# this tick predicts on top of them (DotNetConfig.reconcile_once_per_frame; by name for
	# an older shell's dot-net, where each snapshot already reconciled as it came).
	if net.has_method(&"flush_reconcile"):
		var replays := probe_replays_before()
		net.call(&"flush_reconcile")
		probe_replays_after(replays)
		ArenaFrameProbe.add(&"reconcile", t)
		t = Time.get_ticks_usec()
	# [b]Through dot-net's predictor, not around it[/b] (`DotNetManager.predict_tick`, API 10).
	# Simulating the predicted behaviours here by hand predicted the same thing, but the
	# predictor never saw these ticks: `skip_matching_replays` had nothing remembered to
	# compare a snapshot with unless a replay had happened to cover its tick, so most snapshots
	# replayed the whole lead, and the net graph's prediction row read 0 ms/s. By name, with
	# the old loop kept, for an older shell's dot-net.
	#
	# [b]The old loop predicts what the server will compute, and says so.[/b] The web shell
	# pinned 2026-10-17 has dot-net 0.1.12: the skip (`skip_matching_replays`, `_remember`)
	# but no `predict_tick`. That loop predicted on the command as typed while the server ran
	# it as it arrived, rounded by the wire, so the prediction drifted off the server's by
	# millimetres a tick and never matched a snapshot; and it remembered nothing, so nothing
	# could be skipped anyway. Every snapshot replayed the whole lead: 29-41 ticks re-simulated
	# a frame in a browser, the frame's largest cost. Rounding the command the way the wire
	# does (what `predict_tick` does under `predict_wire_input`) and remembering each tick
	# took a replica of that shell (24 s against three bots) from 92 of 500 snapshots skipped and
	# 9.2 ticks re-simulated a frame to 458 of 485 skipped and 0.6.
	if net.has_method(&"predict_tick"):
		net.call(&"predict_tick", tick, command)
	else:
		# Same object as the one buffered above, so its replays run on the rounded one too.
		var wire := DotNetWriter.new(32)
		command.write(wire)
		command.read(DotNetReader.new(wire.to_bytes()))
		var remember := net.predictor != null and net.predictor.has_method(&"_remember")
		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				if behaviour.has_method("_net_apply_input"):
					behaviour.call("_net_apply_input", command, tick)
				behaviour._net_simulate(tick, net.clock.tick_duration())
			if remember:
				net.predictor.call(&"_remember", identity, tick)
	ArenaFrameProbe.add(&"predict", t)


## Applies a snapshot. Client side.
##
## [b]Reconciliation is [DotNetManager]'s, not this file's.[/b]
## [method DotNetManager.receive_snapshot] already routes a predicted entity's state to
## [method DotNetPredictor.reconcile] rather than applying it — applying it directly would
## undo everything predicted since — and acknowledges the inputs that state covers.
##
## This used to do a second pass on top of that, reconciling against
## [method DotNetBehaviour.snapshot_values] which by then held values that had [i]already[/i]
## been rewound and replayed. The inputs were therefore replayed twice, and one correction
## became two. Nothing failed: the client still converged, because the second replay
## started from the first one's answer.
##
## What it cost was visible only in the number that exists to measure it.
## [method DotNetPredictor.correction_rate] read [b]0.500[/b] with the extra pass and
## [b]0.032[/b] without — and a correction rate near a half is precisely the reading that
## class documents as "the two simulations disagree, and no smoothing will fix that". It
## was found in dot-2d-hungry, whose bridge was written from this one and inherited it.
func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	# The one place an RTT sample is written. `DotNetStats` has a median and a
	# mean-absolute-deviation behind it and `receive_snapshot` reads
	# `rtt_percentile(0.5)` on every snapshot to feed the clock — and no caller
	# anywhere in dot-net writes a sample, because dot-net never touches a transport.
	# Without this the clock's input lead omits the flight time and, past about 30 ms
	# of latency, every command arrives after its tick and is discarded as late.
	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	if not ArenaFrameProbe.on():
		return net.receive_snapshot(payload)
	var t := Time.get_ticks_usec()
	var replays := probe_replays_before()
	var received := net.receive_snapshot(payload)
	probe_replays_after(replays)
	ArenaFrameProbe.add(&"snapshot", t)
	return received


## The predictor's reconciliation count, for [method probe_replays_after]; -1 with the probe off.
func probe_replays_before() -> int:
	if not ArenaFrameProbe.on() or net == null or net.predictor == null:
		return -1
	return net.predictor._replays


## Counts the ticks the reconciliation since [param before] replayed, for `cl_perf`.
func probe_replays_after(before: int) -> void:
	if before >= 0 and net.predictor._replays != before:
		ArenaFrameProbe.count(&"replay_n", net.predictor._last_replay_ticks)


# --- The client-to-server channel ------------------------------------------

## An input packet, with the snapshot acknowledgement in front of it.
##
## [b]dot-net does not send either of these for you.[/b] It owns no client-to-server
## channel — inventing one would need a second socket or make every payload ambiguous
## with a message — so the four bytes of acknowledgement ride inside the input packet
## a host already sends every tick. Wiring it is what makes a property lost to a
## dropped packet get re-sent instead of sitting at a stale value until it happens to
## change again; a game that skips it still works, and a player's health is then
## whatever the last packet that arrived said.
##
## The acknowledgement goes first because it is fixed width. A bit-packed command is
## not, so a reader that had to skip it would need to decode it to know where it ends.
##
## [b]And the command rides with the two before it.[/b] An input is unreliable and a lost
## one is a tick the server simulates on the previous command -- with the view turning,
## a different command -- so the client is corrected for something it did right. Through a
## real UDP relay in front of an ENet server (`headless_lossy`), one copy: the server had a
## moving player's command for 80% of its ticks at 20% loss and 94% at 5%, and corrected
## his prediction on 9% of snapshots; three copies: 99-100% and under 3%. WebSocket never
## loses one, which is why nothing had seen it. The copies come out of the client's own
## replay history, so they are exactly what it predicted with, and the server skips the
## ones it has already simulated.
func encode_input(tick: int, move: DotFpsCommand, fire: DotWeaponCommand) -> PackedByteArray:
	var command := ArenaNetCommand.new()
	command.tick = tick
	command.delta = net.clock.tick_duration()
	command.move = move
	command.fire = fire
	command.view_lag_q = view_lag_q(tick)

	# The ones before this tick from the replay history; this one from the arguments,
	# because a caller may encode before or after `client_tick` recorded it.
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(command)

	var writer := DotNetWriter.new()
	DotNetInput.write_batch(writer, batch)

	var out := net.encode_ack()
	out.append_array(writer.to_bytes())
	return out


## How far behind [param tick] this client is drawing everybody else, in quarter ticks:
## what the server rewinds the other players by when this tick's command fires.
##
## Remote players are drawn at the receive timeline less the interpolation delay
## ([method DotNetManager.interpolate_frame]); this command is for [param tick], ahead of
## the server by the input lead. A shot on it was aimed at players as they were drawn, so
## the difference is the whole of what the server has to undo: the lead, the flight time
## and the interpolation delay. -1 when there is nothing to measure against yet.
func view_lag_q(tick: int) -> int:
	if net == null or net.interpolator == null or not net.clock.is_synced():
		return -1
	var drawn := float(net.clock.received_tick()) - net.interpolator.delay_ticks()
	return clampi(int(roundf((float(tick) - drawn) * 4.0)), 0, ArenaNetCommand.MAX_VIEW_LAG_Q)


## Takes one of those packets. Server side.
##
## The acknowledgement is applied even when the command is refused: they are
## independent claims, and a duplicate or late input says nothing about which
## snapshots arrived.
func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))
	inputs_from[peer_id] = int(inputs_from.get(peer_id, 0)) + 1

	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return ArenaNetCommand.new()
	)

	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")

	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)

	# The copies of ticks already simulated are skipped rather than pushed, or every one
	# would count as a late input and the number that says "this client's clock is
	# behind" would say it about every healthy client. The packet's own tick is always
	# pushed, so a genuinely late one is still counted.
	for command in batch:
		if command != newest and command.tick <= buffer.last_consumed_tick():
			continue
		pushed = buffer.push(command)

	return pushed


# --- Joins -----------------------------------------------------------------

## Everything a client needs to mirror one player.
##
## A message rather than a spawn: [DotNetSpawner] builds entities from a prefab table,
## and an [ArenaPlayer] is built by [method ArenaGame.add_player] so that the netted
## and the headless deployments get the same player rather than two that drift.
func join_payload(session_id: int) -> PackedByteArray:
	var behaviour: ArenaPlayerNet = _behaviours.get(session_id)

	if behaviour == null or behaviour.identity == null:
		return PackedByteArray()

	var writer := DotNetWriter.new()
	writer.write_varint(behaviour.identity.net_id)
	writer.write_varint(behaviour.identity.owner_peer_id)
	writer.write_varint(session_id)
	writer.write_string(behaviour.player.display_name, 64)
	# Appended, never inserted: a field before it would move every other one for a
	# reader of the old layout. JSON rather than a skin index, so a slot added later needs
	# no new wire; empty is the stock figure.
	var avatar := behaviour.player.avatar
	writer.write_string(JSON.stringify(avatar.to_dict()) if avatar != null else "", AVATAR_BYTES)
	return writer.to_bytes()


## Mirrors whatever a [method join_payload] described. Client side.
func apply_join(payload: PackedByteArray) -> DotResult:
	var reader := DotNetReader.new(payload)
	var net_id := reader.read_varint()
	var peer_id := reader.read_varint()
	var session_id := reader.read_varint()
	var display_name := reader.read_string(64)
	var avatar_text := reader.read_string(AVATAR_BYTES)

	if not reader.ok():
		return DotResult.fail(DotError.CODE_PARSE, "Truncated join.")

	# A document that does not parse is the stock figure, not a refused join: an avatar
	# is cosmetic, and somebody who cannot be drawn as themselves can still be drawn.
	var avatar: DotAvatar = null

	if avatar_text != "":
		var parsed: Variant = JSON.parse_string(avatar_text)

		if parsed is Dictionary:
			var built := DotAvatar.from_dict(parsed)

			if built.ok:
				avatar = built.value

	# A JOIN for somebody this client already has is the server saying who they are NOW.
	if _behaviours.has(session_id):
		var known: ArenaPlayerNet = _behaviours[session_id]
		known.player.display_name = display_name
		known.player.rewear(avatar)
		return DotResult.success(known)

	var mirrored := mirror_player(net_id, peer_id, session_id, display_name)

	if mirrored.ok and _behaviours.has(session_id):
		(_behaviours[session_id] as ArenaPlayerNet).player.avatar = avatar

	return mirrored


# --- Events and requests ---------------------------------------------------
#
# Everything the server tells a client that is not a snapshot, and everything a client
# asks for. Both ride one message type with a kind inside it — see [ArenaEvent] — so
# adding one is not a wire-id change on two separately-built programs.


## Sends an event to one peer, or to every ready peer when [param peer_id] is 0.
##
## [b]Ready peers, not connected ones.[/b] A peer that has finished dot-server's signon
## has a socket and has not yet built its scene; an RPC to it lands on a node that does
## not exist and is lost with one "Node not found" per call. The gate is [enum
## ArenaEvents.Ask].READY.
## The server changed a movement rule: every client gets the whole set. Server side; a
## client's own set_movement_rules emits this too and must not echo it back.
func _on_movement_rules_changed(rules: Dictionary) -> void:
	if net == null or not net.is_server:
		return
	send_event(0, ArenaEvents.Kind.RULES, ArenaEvents.write_rules(rules))


## The jail's gate was pressed or its rules changed: every client gets the state. Server side.
func _on_jail_changed() -> void:
	if net == null or not net.is_server or game == null or game.map == null or game.map.jail == null:
		return
	send_event(0, ArenaEvents.Kind.JAIL, _jail_body())


func _jail_body() -> PackedByteArray:
	var jail: RefCounted = game.map.jail
	return ArenaEvents.write_jail(jail.enabled, jail.open_ticks, jail.cooldown_ticks, jail.opened_at)


func send_event(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or link == null:
		return

	var payload := encode_event(kind, body)

	if payload.is_empty():
		return

	if peer_id != 0:
		if _ready_peers.has(peer_id):
			link.send_event(peer_id, payload)
		return

	for ready_peer in _ready_peers:
		link.send_event(int(ready_peer), payload)


## An event as the bytes [method receive_event] reads, or empty if it would not encode.
## Public so a harness without a link delivers exactly what the link would carry.
func encode_event(kind: int, body: PackedByteArray) -> PackedByteArray:
	var writer := DotNetWriter.new()
	var wrote := net.messages.encode(ArenaEvent.new(kind, body), writer)

	if not wrote.ok:
		DotLog.warn(CHANNEL, "could not encode an event", {
			"kind": ArenaEvents.kind_name(kind), "error": str(wrote.error)
		})
		return PackedByteArray()

	return writer.to_bytes()


## Sends a request to the server. Client side.
func send_request(kind: int, body: PackedByteArray = PackedByteArray()) -> void:
	if net == null or net.is_server or link == null:
		return

	var writer := DotNetWriter.new()
	var wrote := net.messages.encode(ArenaRequest.new(kind, body), writer)

	if not wrote.ok:
		return

	link.send_request(writer.to_bytes())


## Everything a joining peer has to be told, in the order it has to be told it.
##
## HELLO first, because it carries the tick rate and the client's own id and nothing
## else can be interpreted without them; then one JOIN per player already in the match,
## including the joining peer's own; then the match state.
func send_signon(peer_id: int) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_for_peer(peer_id)

	send_event(peer_id, ArenaEvents.Kind.HELLO, ArenaEvents.write_hello(
		net.config.tick_rate,
		session_id,
		peer_id,
		net.clock.tick,
		game.map.display_name if game.map != null else "",
		game.score_limit,
		game.time_limit_sec
	))

	# Straight after HELLO and before any JOIN: the players about to be described are
	# predicted with these numbers, so they have to be in place before the first of them.
	if game != null and not game.movement_rules.is_empty():
		send_event(peer_id, ArenaEvents.Kind.RULES, ArenaEvents.write_rules(game.movement_rules))

	# Every player already here, this peer's own included. A client that was only told
	# about players who joined AFTER it would see an empty arena on a busy server, and
	# nothing would ever correct it.
	for existing in _behaviours.keys():
		send_event(
			peer_id, ArenaEvents.Kind.JOIN, join_payload(int(existing))
		)

	_send_match_state(peer_id)

	# The map's packs that are out right now. A kill's drop lives seconds and a joiner never
	# misses one; a pack lives the whole map, so a joiner would otherwise not see it until
	# it was next taken and came back.
	if game != null and game.drops != null:
		for pack in game.drops.packs_out():
			send_event(peer_id, ArenaEvents.Kind.DROP, ArenaEvents.write_drop(
				int(pack["id"]), int(pack["kind"]), int(pack["value"]), pack["at"], pack["at"]
			))

	# The jail's gate, when the map has one: a joiner mid-open would otherwise predict it shut.
	if game != null and game.map != null and game.map.jail != null:
		send_event(peer_id, ArenaEvents.Kind.JAIL, _jail_body())

	# The map's toys, by net id in toy order: the joiner's own copies are paired with them.
	if not _toys_body.is_empty():
		send_event(peer_id, ArenaEvents.Kind.TOYS, _toys_body)

	# Every monster already in the arena. A client joining a horde in progress would
	# otherwise be hurt by monsters it was never told about.
	for instance_id in _monster_nets.keys():
		var monster: ArenaNpcNet = _monster_nets[instance_id]
		if monster.identity != null and monster.npc != null and monster.npc.is_alive():
			send_event(peer_id, ArenaEvents.Kind.NPC, ArenaEvents.write_npc(
				monster.identity.net_id, monster.npc.def.id, monster.npc.position()
			))


# --- Projectiles -------------------------------------------------------------

var _watched_projectiles: RefCounted = null

## The drops layer this bridge last connected to. See [method _watch_drops].
var _watched_drops: Node = null


## Follows whichever projectile layer the game has, and tells every client about each
## launch. Server side, every tick, because a map change builds a new one.
## Follows whichever drops layer the game has and tells every client about each drop and
## each take. Server side, every tick, because a map change builds a new one.
func _watch_drops() -> void:
	if net == null or not net.is_server or game == null:
		return

	var layer: Node = game.drops

	if layer == _watched_drops:
		return

	_watched_drops = layer

	if layer != null:
		layer.dropped.connect(_on_dropped)
		layer.taken.connect(_on_taken)


func _on_dropped(id: int, kind: int, at: Vector3, from: Vector3, value: int) -> void:
	send_event(0, ArenaEvents.Kind.DROP, ArenaEvents.write_drop(id, kind, value, from, at))


func _on_taken(id: int, taker: int) -> void:
	send_event(0, ArenaEvents.Kind.TAKEN, ArenaEvents.write_taken(id, taker))


func _watch_projectiles() -> void:
	if net == null or not net.is_server or game == null:
		return

	var layer: RefCounted = game.projectiles

	if layer == _watched_projectiles:
		return

	_watched_projectiles = layer

	if layer != null and not layer.launched.is_connected(_on_launched):
		layer.launched.connect(_on_launched)


func _on_launched(spawn: DotWeaponSpawn) -> void:
	send_event(0, ArenaEvents.Kind.LAUNCH, ArenaEvents.write_launch(
		spawn, ArenaContent.weapon_index(spawn.id)
	))


## A launch the server announced, flown here as a copy. Client side.
func _mirror_launch(launch: Dictionary) -> void:
	if game == null or game.projectiles == null:
		return

	var id := ArenaContent.weapon_at(int(launch["weapon"]))
	game.projectiles.launch(ArenaEvents.spawn_from_launch(launch, id))


# --- Monsters ----------------------------------------------------------------

## Follows whichever horde the game has. Server side.
##
## [b]Every tick, not once.[/b] The horde is built by a mode that has one and torn down by a
## mode change to one that does not — `ArenaGame._reconcile_world_layers` — so a bridge that
## connected at attach would miss every horde after the first, and one that connected at a
## mode change would need the game to tell it, which is a second thing to forget.
func _watch_horde() -> void:
	if net == null or not net.is_server or game == null:
		return

	var spawner: DotNpcSpawner = game.horde.spawner if game.horde != null else null

	if spawner == _watched_spawner:
		return

	if _watched_spawner != null and is_instance_valid(_watched_spawner):
		if _watched_spawner.spawned.is_connected(_on_monster_spawned):
			_watched_spawner.spawned.disconnect(_on_monster_spawned)
		if _watched_spawner.removed.is_connected(_on_monster_removed):
			_watched_spawner.removed.disconnect(_on_monster_removed)

	# A horde that went took its monsters with it; their entities go too.
	for instance_id in _monster_nets.keys():
		_forget_monster(int(instance_id))

	_watched_spawner = spawner

	if spawner == null:
		return

	spawner.spawned.connect(_on_monster_spawned)
	spawner.removed.connect(_on_monster_removed)

	for npc in spawner.all_npcs():
		_on_monster_spawned(npc)


func _on_monster_spawned(npc: DotNpcInstance) -> void:
	var body := npc.node as Node3D

	if body == null or net == null or _monster_nets.has(npc.instance_id):
		return

	var behaviour := ArenaNpcNet.new()
	behaviour.name = "Net"
	behaviour.npc = npc
	behaviour.body = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	# Relevant to everybody, whatever the interest grid's radius says. An arena is sixty
	# metres across, a gunner fires from eighteen and a horde arrives from anywhere — and the
	# first version, culled by distance, announced a monster twenty-five metres away and then
	# never sent it a snapshot: the client drew it frozen where it spawned, facing north.
	identity.always_relevant = true
	body.add_child(identity)

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a monster", {"error": str(registered.error)})
		return

	_monster_nets[npc.instance_id] = behaviour
	behaviour.pull()
	send_event(0, ArenaEvents.Kind.NPC, ArenaEvents.write_npc(
		identity.net_id, npc.def.id, body.global_position
	))


func _on_monster_removed(npc: DotNpcInstance, _reason: StringName) -> void:
	_forget_monster(npc.instance_id)


func _forget_monster(instance_id: int) -> void:
	var behaviour: ArenaNpcNet = _monster_nets.get(instance_id)
	_monster_nets.erase(instance_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	var net_id := behaviour.identity.net_id
	net.registry.unregister(net_id)
	send_event(0, ArenaEvents.Kind.NPC_GONE, ArenaEvents.write_npc_gone(net_id))


## Builds a client's copy of a monster: its scene, no brain — the server thinks for it —
## moved by its net behaviour. Client side.
func _mirror_monster(info: Dictionary) -> void:
	var net_id := int(info["net_id"])

	if _monster_mirrors.has(net_id) or net == null:
		return

	var def := ArenaNpcs.catalogue().get_npc(info["kind_id"])

	if def == null:
		DotLog.debug(CHANNEL, "a monster this build does not have", {"id": str(info["kind_id"])})
		return

	var scene: Variant = load(def.scene_path) if ResourceLoader.exists(def.scene_path) else null

	if not (scene is PackedScene):
		DotLog.warn(CHANNEL, "a monster's scene would not load", {"path": def.scene_path})
		return

	var body := (scene as PackedScene).instantiate() as Node3D

	if body == null:
		return

	if _monster_world == null or not is_instance_valid(_monster_world):
		_monster_world = Node3D.new()
		_monster_world.name = "MonsterMirrors"
		game.add_child(_monster_world)

	_monster_world.add_child(body)
	body.global_position = info["position"]

	var behaviour := ArenaNpcNet.new()
	behaviour.name = "Net"
	behaviour.body = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not mirror a monster", {"error": str(registered.error)})
		body.queue_free()
		return

	_monster_mirrors[net_id] = behaviour


func _drop_monster_mirror(net_id: int) -> void:
	var behaviour: ArenaNpcNet = _monster_mirrors.get(net_id)
	_monster_mirrors.erase(net_id)

	if behaviour == null:
		return

	if net != null:
		net.registry.unregister(net_id)

	if behaviour.body != null and is_instance_valid(behaviour.body):
		behaviour.body.queue_free()


## How many monsters this end replicates or draws.
func monster_count() -> int:
	return _monster_nets.size() if net != null and net.is_server else _monster_mirrors.size()


## Tells every ready peer where the match is. Server side.
func announce_match_state() -> void:
	_send_match_state(0)


func _send_match_state(peer_id: int) -> void:
	if game == null or game.match_node == null:
		return

	# Ticks, not seconds, because seconds are what the two ends would disagree about:
	# `seconds_remaining` is derived from the tick rate, and the client's rate is
	# whatever HELLO told it. Sending the count and letting each end divide by the rate
	# it is running keeps one number on the wire and one conversion on each side.
	send_event(peer_id, ArenaEvents.Kind.MATCH, ArenaEvents.write_match(
		int(game.match_node.state),
		int(round(game.match_node.seconds_remaining() * float(net.config.tick_rate))),
		game.match_node.round_number,
		game.match_node.rules.score_limit if game.match_node.rules != null else 0
	))


## An extend raised the match's score limit: everybody's HUD shows it, and a late joiner
## would otherwise be told the one the match started with.
func note_score_limit_changed() -> void:
	if net != null and net.is_server:
		_send_match_state(0)


func _on_match_state_changed(_from: int, _to: int) -> void:
	_send_match_state(0)


func _on_player_killed(entry: DotKillFeed.Entry) -> void:
	# The killer key is a string here and 0-means-the-world on the wire. dot-match
	# reads an empty killer key as "the world"; this game never writes "0" for it,
	# because that would create a scoreboard record for a player who does not exist.
	var killer := int(entry.killer_key) if String(entry.killer_key).is_valid_int() else 0

	send_event(0, ArenaEvents.Kind.KILL, ArenaEvents.write_kill(
		killer,
		int(entry.victim_key) if String(entry.victim_key).is_valid_int() else 0,
		String(entry.cause),
		entry.headshot,
		bool(entry.get_meta(&"critical", false)),
		# The fall the server picked (ArenaGame.decide_death), so every client draws the same.
		entry.get_meta(&"death", null) as DotPlayerDeath
	))


## A player's damage landed. Summed per victim until the tick ends, so a shotgun's nine
## pellets are one number and one marker rather than nine events.
func _on_hit_confirmed(
	attacker: int, victim: int, amount: float, point: Vector3, headshot: bool, lethal: bool
) -> void:
	if net == null or not net.is_server:
		return
	var mine: Dictionary = _pending_hits.get(attacker, {})
	var was: Array = mine.get(victim, [0.0, point, false, false])
	# The headshot's point when there is one: that is where the number should rise from.
	var at: Vector3 = point if headshot or not bool(was[2]) else was[1]
	mine[victim] = [float(was[0]) + amount, at, bool(was[2]) or headshot, bool(was[3]) or lethal]
	_pending_hits[attacker] = mine


## Sends this tick's hits, each to the player who dealt it. A bot has no peer and is told
## nothing.
func _flush_hits() -> void:
	if _pending_hits.is_empty():
		return
	for attacker in _pending_hits:
		var peer := peer_for_session(int(attacker))
		if peer == 0:
			continue
		var mine: Dictionary = _pending_hits[attacker]
		for victim in mine:
			var hit: Array = mine[victim]
			send_event(peer, ArenaEvents.Kind.HIT, ArenaEvents.write_hit(
				int(victim), float(hit[0]), hit[1], bool(hit[2]), bool(hit[3])
			))
	_pending_hits.clear()


## The peer a session plays from, or 0 for a bot or somebody gone.
func peer_for_session(session_id: int) -> int:
	for peer in _players_by_peer:
		if int(_players_by_peer[peer]) == session_id:
			return int(peer)
	return 0


func _on_medals_awarded(killer: int, victim: int, medals: Array, points: int, streak: int) -> void:
	send_event(0, ArenaEvents.Kind.AWARD, ArenaEvents.write_award(killer, victim, points, streak, medals))


## An event arrived. Client side.
##
## Through `DotNetManager.receive` rather than straight to the registry: that is where
## the payload cap, the per-peer rate limit and the direction check live, and a bridge
## that decoded for itself would be a second entry point with none of them.
func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


## A request arrived. Server side.
func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


## A relayed voice frame arrived. Client side.
##
## [b]Deliberately NOT routed through [DotNetManager].[/b] dot-net's `receive` decodes
## a bit-packed message against a sealed schema and applies the payload cap and the
## rate limit that go with it; a voice frame is an opaque blob from a codec and has
## nothing to do with the replication wire. Putting it through would mean either a
## message type per codec or a schema that changes when the codec does — and the
## schema hash is what both ends check to agree they are speaking the same game.
##
## Handled by whatever the host set [member voice_in_fn] to, which on a client is
## `DotVoiceManager.receive`.
func receive_voice(payload: PackedByteArray) -> DotResult:
	if not voice_in_fn.is_valid():
		return DotResult.fail(DotError.CODE_STATE, "Nothing here plays voice.")

	voice_in_fn.call(payload)
	return DotResult.success(payload.size())


## A client's captured audio arrived. Server side.
##
## The speaker is [param peer_id], which the transport reported. It is never read out
## of the payload: a client that could name its own speaker id could put words in
## anybody's mouth, and the only symptom is words coming out of the wrong player.
func receive_voice_frame(peer_id: int, payload: PackedByteArray) -> DotResult:
	if not voice_relay_fn.is_valid():
		return DotResult.fail(DotError.CODE_STATE, "This end does not relay voice.")

	voice_relay_fn.call(peer_id, payload)
	return DotResult.success(payload.size())


## A dot-map announcement arrived. Client side.
func receive_map(payload: Dictionary) -> DotResult:
	if not map_in_fn.is_valid():
		return DotResult.fail(DotError.CODE_STATE, "This end does not follow maps.")

	map_in_fn.call(payload)
	return DotResult.success(payload.size())


## A client's map progress or readiness arrived. Server side.
func receive_map_report(peer_id: int, payload: Dictionary) -> DotResult:
	if not map_report_fn.is_valid():
		return DotResult.fail(DotError.CODE_STATE, "This end does not host maps.")

	map_report_fn.call(peer_id, payload)
	return DotResult.success(payload.size())


func _on_event(message: DotNetMessage) -> void:
	var event := message as ArenaEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		ArenaEvents.Kind.HELLO:
			var info := ArenaEvents.read_hello(reader)
			if not bool(info["ok"]):
				return
			_hello = info
			_adopt_tick_rate(int(info["tick_rate"]))
			hello_received.emit(info)
		ArenaEvents.Kind.JOIN:
			apply_join(event.body)
		ArenaEvents.Kind.LEAVE:
			var left := ArenaEvents.read_leave(reader)
			if bool(left["ok"]):
				_drop_session(int(left["session_id"]))
		ArenaEvents.Kind.KILL:
			var kill := ArenaEvents.read_kill(reader)
			if bool(kill["ok"]):
				# The client's death camera. Fed here rather than by `player_killed`,
				# which only the authority emits. See `ArenaSpectate.on_kill_event`.
				if game.spectate != null:
					game.spectate.on_kill_event(kill)
				kill_received.emit(kill)
		ArenaEvents.Kind.MATCH:
			var state := ArenaEvents.read_match(reader)
			if bool(state["ok"]):
				match_received.emit(state)
		ArenaEvents.Kind.NOTICE:
			var notice := ArenaEvents.read_notice(reader)
			if bool(notice["ok"]):
				notice_received.emit(String(notice["text"]))
		ArenaEvents.Kind.VOTE:
			var voted := ArenaEvents.read_vote(reader)
			if bool(voted["ok"]):
				vote_received.emit(voted)
		ArenaEvents.Kind.NPC:
			var monster := ArenaEvents.read_npc(reader)
			if bool(monster["ok"]):
				_mirror_monster(monster)
		ArenaEvents.Kind.NPC_GONE:
			var gone := ArenaEvents.read_npc_gone(reader)
			if bool(gone["ok"]):
				_drop_monster_mirror(int(gone["net_id"]))
		ArenaEvents.Kind.LAUNCH:
			var launch := ArenaEvents.read_launch(reader)
			if bool(launch["ok"]):
				_mirror_launch(launch)
		ArenaEvents.Kind.TOYS:
			var told := ArenaEvents.read_toys(reader)
			if bool(told["ok"]):
				_apply_toys(told)
		ArenaEvents.Kind.DROP:
			var drop := ArenaEvents.read_drop(reader)
			if bool(drop["ok"]) and game.drops != null:
				game.drops.mirror_drop(
					int(drop["id"]), int(drop["kind"]), drop["at"], drop["from"], int(drop["value"])
				)
		ArenaEvents.Kind.TAKEN:
			var took := ArenaEvents.read_taken(reader)
			if bool(took["ok"]) and game.drops != null:
				game.drops.mirror_taken(int(took["id"]), int(took["taker"]))
		ArenaEvents.Kind.JAIL:
			var told_jail := ArenaEvents.read_jail(reader)
			if bool(told_jail["ok"]) and game != null:
				game.apply_jail_state(told_jail)
		ArenaEvents.Kind.RULES:
			var rules := ArenaEvents.read_rules(reader)
			if bool(rules["ok"]) and game != null:
				game.set_movement_rules(rules["rules"])
		ArenaEvents.Kind.HIT:
			var hit := ArenaEvents.read_hit(reader)
			if bool(hit["ok"]):
				hit_received.emit(hit)
		ArenaEvents.Kind.AWARD:
			var award := ArenaEvents.read_award(reader)
			if bool(award["ok"]):
				award_received.emit(award)
		_:
			pass


func _on_request(message: DotNetMessage) -> void:
	var request := message as ArenaRequest

	if request == null or net == null or not net.is_server:
		return

	# The sender the TRANSPORT reported, carried onto the message by
	# `DotNetManager.receive`. Never a peer id out of the body: that would be a claim.
	var peer_id := request.sender_peer_id

	if peer_id <= 0:
		return

	match request.kind:
		ArenaEvents.Ask.READY:
			mark_ready(peer_id)
		ArenaEvents.Ask.RESPAWN:
			# Asked for, never taken. dot-match owns respawning and has its own
			# timer; a client that could respawn itself could respawn instantly.
			pass
		ArenaEvents.Ask.PROP_TOOL:
			_on_prop_act(peer_id, ArenaEvents.read_prop_act(request.reader()))
		_:
			pass


## A client asked to do something with a prop.
##
## [b]The origin comes from the simulation and only the direction comes off the
## wire.[/b] The server already knows where the player is — it moved them — and a
## client that could name its own origin could grab a prop from anywhere on the map.
## What it cannot know is where they were looking between two ticks, so that is the
## one thing the payload carries and the one thing that is a claim.
##
## The tool itself decides whether it reaches: `DotPropTool.may_act_on` is what
## enforces the range, the mass limit and whose prop it is.
func _on_prop_act(peer_id: int, body: Dictionary) -> void:
	if not bool(body.get("ok", false)) or game == null or game.props == null:
		return

	var session_id := session_for_peer(peer_id)

	if session_id <= 0:
		return

	var player := game.player_for(session_id)

	if player == null or not player.is_alive():
		return

	game.props.act(
		session_id,
		int(body["act"]),
		player.muzzle_position(),
		DotFpsMotor.aim_for(float(body["yaw"]), float(body["pitch"]))
	)


## A peer has built its scene and may be sent things.
func mark_ready(peer_id: int) -> void:
	if net == null or not net.is_server or _ready_peers.has(peer_id):
		return

	# Before the seat: kept, and answered by add_player (see [member _ready_unseated]).
	if not _players_by_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		DotLog.debug(CHANNEL, "a READY before the seat, kept", {"peer": peer_id})
		return

	_ready_peers[peer_id] = true
	send_signon(peer_id)

	if peer_ready_fn.is_valid():
		peer_ready_fn.call(peer_id)

	DotLog.info(CHANNEL, "a peer is ready", {"peer": peer_id})


## The client's own tick rate comes from the SERVER, and from nowhere else.
##
## [b]This is the largest measured error in this family's history.[/b] g2gfast's client
## took its rate from `Engine.physics_ticks_per_second`, which a browser shell never
## sets — 60 against a 128-tick server. Correction rate 0.96, prediction never
## converging, and every replicated time wrong by the ratio of the two rates. HELLO has
## always carried the number; nothing read it back out.
##
## All four copies move together, and the engine's is one of them: the fraction a
## renderer interpolates at is a fraction through a PHYSICS frame, which is a fraction
## through a tick only while the two rates agree.
func _adopt_tick_rate(rate: int) -> void:
	if rate <= 0 or game == null or net == null:
		return

	game.tick_rate = rate
	net.config.tick_rate = rate
	net.config.snapshot_rate = ArenaGame.snapshot_rate_for(rate)
	# A copy taken at setup() that writing the config does not touch.
	net.clock.tick_rate = rate
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap
	# to a quarter second of ticks (8 steps are 62.5 ms at 128 Hz, so a client under 16 fps ran
	# fewer ticks than the server). A shell built before it gets the same rule here, as
	# game-g2gfast does; remove this branch when the oldest shell is API 7.
	if DotAddonApi.build_level("dot_net") >= 7:
		DotNetClock.adopt_tick_rate(rate)
	else:
		Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, ceili(0.25 * float(rate)))
		Engine.physics_ticks_per_second = rate


## Forgets a player a LEAVE named. Client side.
func _drop_session(session_id: int) -> void:
	var behaviour: ArenaPlayerNet = _behaviours.get(session_id)

	if behaviour == null:
		return

	if net != null and behaviour.identity != null:
		net.registry.unregister(behaviour.identity.net_id)

	_behaviours.erase(session_id)

	for peer_id in _players_by_peer.keys():
		if int(_players_by_peer[peer_id]) == session_id:
			_players_by_peer.erase(peer_id)

	game.remove_player(session_id)


# --- Both ends: the map's toys ---------------------------------------------------

## The map's toys on the wire, one behaviour per toy in toy order, and the TOYS event that names
## their net ids (kept for a joiner).
var _toy_nets: Array = []
var _toys_body: PackedByteArray = PackedByteArray()

## Client: which map the last TOYS was for. Its mirrors are registered at once and handed their
## toys when this end's toys for that map exist ([method _pair_pending_toys]).
var _toys_map: StringName = &""

## Client: where the mirrors live, which is not under the toys: a client registers them the
## moment TOYS arrives, before its own map may be built, and keeps them through a map change.
var _toy_holder: Node3D = null


## Server: an entity for each of the map's toys, and TOYS naming them.
func _register_toys() -> void:
	if net == null or not net.is_server or game == null:
		return
	_release_toys()
	var ids := PackedInt64Array()
	if game.toys != null:
		for toy in game.toys.toys:
			var behaviour := _toy_entity(toy, toy, 0)
			if behaviour == null:
				break
			ids.append(behaviour.identity.net_id)
	_toys_body = ArenaEvents.write_toys(game.map.id if game.map != null else &"", ids)
	send_event(0, ArenaEvents.Kind.TOYS, _toys_body)


## A toy's behaviour and identity under [param parent], registered under [param net_id] (0
## allocates: the server); null when the registry refused it. The behaviour before the
## identity, which collects behaviours in its `_ready`.
func _toy_entity(toy: DotPropToy, parent: Node, net_id: int) -> ArenaToyNet:
	var behaviour := ArenaToyNet.new()
	behaviour.name = "Net"
	behaviour.toy = toy
	var holder := Node3D.new() if parent != toy else null
	if holder != null:
		holder.name = "Toy%d" % _toy_nets.size()
		parent.add_child(holder)
	var at: Node = holder if holder != null else toy
	at.add_child(behaviour)
	if net.is_server:
		behaviour.pull()
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	at.add_child(identity)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a toy", {"toy": _toy_nets.size(), "error": str(registered.error)})
		at.remove_child(behaviour)
		at.remove_child(identity)
		behaviour.queue_free()
		identity.queue_free()
		if holder != null:
			parent.remove_child(holder)
			holder.queue_free()
		return null
	_toy_nets.append(behaviour)
	return behaviour


## Every toy entity out of the registry and out of the tree at once: a new identity on the same
## toy collects every behaviour under it in its `_ready`, and a freed one found there broke the
## next snapshot (game-playground found it). The server's, on a map change or a new set.
func _release_toys() -> void:
	for behaviour: ArenaToyNet in _toy_nets:
		if not is_instance_valid(behaviour):
			continue
		if behaviour.identity != null and net != null and net.registry.has(behaviour.identity.net_id):
			net.registry.unregister(behaviour.identity.net_id)
		var at := behaviour.get_parent()
		for node: Node in [behaviour.identity, behaviour]:
			if node != null and is_instance_valid(node) and node.get_parent() != null:
				node.get_parent().remove_child(node)
				node.queue_free()
		if at != null and at.get_parent() == _toy_holder and _toy_holder != null:
			_toy_holder.remove_child(at)
			at.queue_free()
	_toy_nets.clear()


## Client, on TOYS: a mirror for every id at once, under the holder, whether this end's toys
## for that map exist yet or not. [b]A client must know every entity a snapshot carries[/b]:
## dot-net stops reading a snapshot at the first one it does not know (a body cannot be skipped
## without its declarations), so a toy mirror missing while the client loads the map, or ever,
## on a client left on another map, was every player after it frozen. Paired with its toy
## by index as soon as both are here.
func _apply_toys(told: Dictionary) -> void:
	if net == null or net.is_server:
		return
	_release_toys()
	if _toy_holder == null:
		_toy_holder = Node3D.new()
		_toy_holder.name = "ToyMirrors"
		add_child(_toy_holder)
	_toys_map = told["map_id"]
	for id in (told["ids"] as PackedInt64Array):
		var _mirror := _toy_entity(null, _toy_holder, int(id))
	_pair_pending_toys()


## Client: each mirror handed this end's toy at its index, once this end's toys are for the map
## TOYS named; none while they are not (a map change on the way, or another map).
func _pair_pending_toys() -> void:
	if net == null or net.is_server or game == null:
		return
	var box := game.toys if game.toys != null and game.map != null and game.map.id == _toys_map else null
	if box != null and box.count() != _toy_nets.size():
		DotLog.warn(CHANNEL, "the server's map has a different number of toys", {"server": _toy_nets.size(), "here": box.count()})
	for i in range(_toy_nets.size()):
		var behaviour: ArenaToyNet = _toy_nets[i]
		behaviour.toy = box.toy(i) if box != null else null


## Client: the old map's toys are about to go; the mirrors stay registered, without them.
func _unpair_toys() -> void:
	for behaviour: ArenaToyNet in _toy_nets:
		if is_instance_valid(behaviour):
			behaviour.toy = null


## How many toys this end replicates (a client: mirrors paired with a toy). For a check.
func toy_count() -> int:
	var n := 0
	for behaviour: ArenaToyNet in _toy_nets:
		if is_instance_valid(behaviour) and (net.is_server or behaviour.toy != null):
			n += 1
	return n


func describe() -> Dictionary:
	return {
		"players": _behaviours.size(),
		"peers": _players_by_peer.size(),
		"tick": _tick,
		"ticked_for": _game_ticked_for,
		"inputs_from": inputs_from,
	}
