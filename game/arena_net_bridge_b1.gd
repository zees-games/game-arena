extends "arena_net_knives.gd"

const ArenaEvent := preload("arena_event.gd")


const ArenaNetLink := preload("arena_net_link.gd")
const ArenaPlayer := preload("arena_player.gd")
const ArenaPlayerNet := preload("arena_player_net.gd")
const ArenaNpcNet := preload("arena_npc_net.gd")


const ArenaBots := preload("arena_bots.gd")
const ArenaBotThreads := preload("arena_bot_threads.gd")
const ArenaFrameProbe := preload("arena_frame_probe.gd")


## Announced a player. Server side: these bytes go to every client.
signal player_announced(payload: PackedByteArray)


## The most an avatar document may take in a JOIN. Arena's three slots are about two
## hundred bytes; the rest is room, and a cap a hostile document cannot talk past.
const AVATAR_BYTES := 1024


## `func(session_id: int) -> DotAvatar`: what a player looks like, asked as they are
## seated and whenever the module re-announces them. Set by the module, which has the
## identity layer; unset or null is the stock figure, which every client derives alike.
var avatar_fn: Callable = Callable()


## player id -> ArenaPlayerNet, for the ones this process knows about.
var _behaviours: Dictionary = {}


## peer id -> player id.
var _players_by_peer: Dictionary = {}


var _game_ticked_for: int = -1
var _tick: int = 0


## The RPC surface, on both ends. Created by [method attach].
var link: ArenaNetLink = null


## [code]func(peer: int) -> void[/code]. A peer said READY, server side.
var peer_ready_fn: Callable = Callable()


## Peers that have said they can receive. Server side.
var _ready_peers: Dictionary = {}


## Peers whose READY came before their seat ([method add_player]). Server side.
var _ready_unseated: Dictionary = {}


## dot-net's own sends (snapshots, its schema) held back from a peer that has not said READY. Server side.
var unready_held: int = 0

## READY and RESPAWN requests heard between ticks, as [peer_id, kind]; answered by [method _answer_tick_asks] at the top of
## [method server_tick]. A request handler runs in the idle frame, and what these start (a spawn and its sight trace) must not query
## the physics space outside the physics step. Server side.
var _tick_asks: Array = []


## Server: records every view and cuts the victims' clips (null until the first tick).
var killview: DotKillViewServer = null


## This tick's confirmed hits, summed: attacker -> victim -> [amount, point, headshot,
## lethal]. Server side; sent and cleared after the tick ([method _flush_hits]).
var _pending_hits: Dictionary = {}


## Adds a player and makes them a replicated entity. Server side. [param session_id] is the id everything downstream uses: the scoreboard key, combat entity id, damage attribution and loadout key.
## [b]It is not the peer id[/b]: a peer id is reassigned when someone reconnects, and everything keyed by one would go to the next player to join.
func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var added := game.add_player(session_id, display_name)

	if not added.ok:
		return added

	# Before registering, not after: the manager only builds snapshots and input buffers for peers it knows, so an entity registered to an unknown peer is one nothing is sent about and nothing can drive. It is silent.
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

	# [b]To everybody already in, not only to the next to arrive.[/b] A peer is sent every player when it says READY and nothing else sent a JOIN, so a client never learned of anybody who joined after it.
	# Ready peers only: one that is not ready yet gets the whole roster when it is.
	send_event(0, ArenaEvents.Kind.JOIN, payload)

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		mark_ready(peer_id)

	return DotResult.success(identity)


## Builds the identity and behaviour that make an [ArenaPlayer] replicate. The behaviour is added before the identity on purpose: [DotNetIdentity] collects its behaviours in [code]_ready[/code] by walking the entity's subtree,
## and one added afterwards would never be found, so the entity would register with nothing to replicate and never move on any other machine.
func _build_identity(player: ArenaPlayer, peer_id: int) -> DotNetIdentity:
	var behaviour := ArenaPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED, not SERVER: the server stays authoritative and corrects, and the owning client predicts.
	# `DotNetIdentity.is_predicted()` is false for any other authority, so SERVER would mean a client that
	# sees its own movement a full round trip late — noticeable at 80 ms and unplayable at 150.
	identity.authority = DotNetIdentity.Authority.SHARED
	player.add_child(identity)

	_behaviours[player.player_id] = behaviour
	return identity


## Rounds a position the way `net_position` reaches a client, or an invalid Callable.
func _position_wire(other_id: int) -> Callable:
	var other: ArenaPlayerNet = _behaviours.get(other_id)
	var spec: DotNetVar = other.find_var(&"net_position") if other != null else null
	if spec == null or not spec.has_method(&"wire_value"):
		return Callable()
	return Callable(spec, &"wire_value")


## Prints what [method remote_feet] answered while the two are within 3 m, so a netchaos run
## can line the server's answers up with the client's (`tools/solid_trace.py`).
func _trace_feet(other_id: int, mover: ArenaPlayerNet, tick: int, lag: float, at: Variant) -> void:
	var other: ArenaPlayerNet = _behaviours.get(other_id)
	if mover.player == null or other == null or other.player == null:
		return
	var from: Vector3 = mover.player.controller.state.position
	var now: Vector3 = other.player.controller.state.position
	var feet: Vector3 = at if at is Vector3 else now
	if Vector2(feet.x - from.x, feet.z - from.z).length() > 3.0:
		return
	var newest := -1
	var near := ""
	var view := floori(float(tick) - lag)
	if net.is_server:
		for k in range(view - 2, view + 3):
			var p: Variant = game.unlag_position_at(other_id, float(k))
			near += " %d:%s" % [k, ("%.3f" % (p as Vector3).x) if p is Vector3 else "-"]
	elif other.identity != null:
		var track: Variant = (net.interpolator.get(&"_tracks") as Dictionary).get(other.identity.net_id)
		newest = track.newest_tick() if track != null else -1
		if track != null:
			for sample: Dictionary in track.samples:
				if absi(int(sample["tick"]) - view) <= 4:
					var p: Variant = (sample["values"] as Dictionary).get(&"net_position")
					near += " %d:%s" % [int(sample["tick"]), ("%.3f" % (p as Vector3).x) if p is Vector3 else "-"]
	print("SOLIDTRACE %s t=%d mover=%d other=%d lag=%.2f raw=%.2f null=%d feet=%.3f,%.3f,%.3f mover_at=%.3f,%.3f,%.3f newest=%d near=%s" % [
		"S" if net.is_server else "C", tick, mover.player.player_id, other_id, lag, mover.last_view_lag,
		1 if at == null else 0, feet.x, feet.y, feet.z, from.x, from.y, from.z, newest, near])


## Drops a peer's player from the game and from replication.
func remove_peer(peer_id: int) -> void:
	# A peer that said READY and left before its seat: a peer id is reused, and a stale entry
	# would answer the next owner's seat with a signon before it has asked.
	_ready_unseated.erase(peer_id)
	_tick_asks = _tick_asks.filter(func(ask: Array) -> bool: return int(ask[0]) != peer_id)

	if not _players_by_peer.has(peer_id):
		return

	var session_id := int(_players_by_peer[peer_id])
	_players_by_peer.erase(peer_id)
	_behaviours.erase(session_id)
	_ready_peers.erase(peer_id)
	if game != null and game.map_io != null:
		game.map_io.remove_peer(peer_id)
	if killview != null:
		killview.forget(session_id)

	# Announced BEFORE the entity is unregistered, and to everybody still here. A client that is only told
	# an entity stopped arriving in snapshots has no way to tell that from a player who walked out of its
	# interest rectangle, so it would leave a body standing in the arena for ever.
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


func session_for_peer(peer_id: int) -> int:
	return int(_players_by_peer.get(peer_id, 0))


## One authoritative tick. Server side, and it replaces [method ArenaGame.tick]. [method DotNetManager.server_tick] hands each peer's input to its entities, simulates, records lag-compensation history and sends snapshots, in that order;
## the game tick happens between the first two, from [method ArenaPlayerNet._net_simulate] through [method ensure_game_ticked]. The call afterwards is not redundant: a server with no players runs no behaviours and the match clock still has to advance, or an empty server's warmup never ends.
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
	# What a console line, a chat command or an admin heard since the last tick (a restart, a mode
	# change, a respawn, a map change's swap), then the clients' queued asks (dot_tick_gate.gd).
	var t_watch := Time.get_ticks_usec()
	if game != null:
		game.tick_gate.open()
	_answer_tick_asks()
	_watch_horde()
	_watch_projectiles()
	_watch_drops()
	_watch_weapon_drops()
	_watch_knives()
	_watch_panes()
	_watch_map_io()
	_watch_bullets()
	_send_ctf(0, tick)
	_send_teams(0, tick)
	_send_scores(0, tick)
	ArenaFrameProbe.add(&"srv_watch", t_watch)

	var t_net := Time.get_ticks_usec()
	if net != null:
		net.server_tick(tick)
	ArenaFrameProbe.add(&"srv_net", t_net)

	ensure_game_ticked(tick)
	var t_hits := Time.get_ticks_usec()
	_flush_hits()
	ArenaFrameProbe.add(&"srv_hits", t_hits)


## Runs the whole game for a tick, at most once. Called from every replicated player's [code]_net_simulate[/code]; the first one through does the work.
func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null or host_paused:
		return

	_game_ticked_for = tick
	var t_cmd := Time.get_ticks_usec()
	var cmds := _commands()
	ArenaFrameProbe.add(&"srv_bots", t_cmd)
	var t_game := Time.get_ticks_usec()
	game.tick(cmds)
	ArenaFrameProbe.add(&"srv_game", t_game)
	var t_kv := Time.get_ticks_usec()
	_tick_killview()
	ArenaFrameProbe.add(&"srv_killview", t_kv)

	# The toys where the physics left them, before the snapshot: a toy's own `_net_simulate`
	# can run before the player whose turns this tick.
	for behaviour: ArenaToyNet in _toy_nets:
		behaviour.pull()


## The command table [method ArenaGame.tick] takes, built from what each peer sent.
func _commands() -> Dictionary:
	var out: Dictionary = {}

	# A bot's commands are made here, in the slot a client's input lands in, so the game
	# ticks it exactly as it ticks a person. It sees the present, so no view lag.
	var driven: Array = []
	var players: Array = []
	var minds: Array = []
	for session_id in _bot_minds:
		var behaviour: ArenaPlayerNet = _behaviours.get(session_id)
		if behaviour == null or behaviour.player == null:
			continue
		driven.append(behaviour)
		players.append(behaviour.player)
		minds.append(_bot_minds[session_id])
	# bot_threads: every brain decides at once on worker threads; 0 thinks one bot after another.
	var made_all: Array = ArenaBotThreads.think_all(game, players, minds, _tick, float(game.tick_rate)) if ArenaBotThreads.active(players.size()) else []
	for i in driven.size():
		var behaviour: ArenaPlayerNet = driven[i]
		var made: Array = made_all[i] if not made_all.is_empty() else ArenaBots.think(game, players[i], minds[i], _tick, float(game.tick_rate))
		behaviour.last_move = made[0]
		behaviour.last_fire = made[1]
		behaviour.last_view_lag = -1.0
		behaviour.last_view_back = -1
		behaviour.last_view_tick = -1

	for session_id in _behaviours:
		var behaviour: ArenaPlayerNet = _behaviours[session_id]
		# The lag as it was sent, on a repeated command too: the client's view runs that far behind
		# its tick on every tick, so the lost command carried the same (headless_net measures it).
		out[int(session_id)] = [behaviour.last_move, behaviour.last_fire, behaviour.last_view_lag]

	return out


## Where a bot's session id starts. Far above any userid dot-server hands out (they count up
## from 1 for the life of the process), and far below the entity table's ids (10^12), so a
## bot's id is a player id like anybody's and can never be a person's.
const BOT_SESSION_BASE := ArenaGame.BOT_SESSION_BASE
var _bot_minds: Dictionary = {}
var _next_bot := 0

## Everything a client needs to mirror one player. A message rather than a spawn: [DotNetSpawner] builds entities from a prefab table,
## and an [ArenaPlayer] is built by [method ArenaGame.add_player] so the netted and headless deployments get the same player rather than two that drift.
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


## Everything a joining peer has to be told, in the order it has to be told it. HELLO first, because it carries the tick rate and the client's own id and nothing else can be interpreted without them;
## then one JOIN per player already in the match, including the joining peer's own; then the match state.
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
		game.time_limit_sec,
		net.config.snapshot_rate
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
	_send_ctf(peer_id, _tick, true)
	_send_teams(peer_id, _tick, true)
	_send_scores(peer_id, _tick, true)

	# The map's packs that are out right now. A kill's drop lives seconds and a joiner never
	# misses one; a pack lives the whole map, so a joiner would otherwise not see it until
	# it was next taken and came back.
	if game != null and game.drops != null:
		for pack in game.drops.packs_out():
			send_event(peer_id, ArenaEvents.Kind.DROP, ArenaEvents.write_drop(
				int(pack["id"]), int(pack["kind"]), int(pack["value"]), pack["at"], pack["at"]
			))

	_send_weapon_drops_signon(peer_id)
	_send_knives_signon(peer_id)
	_send_panes_signon(peer_id)
	if game != null and game.map_io != null:
		game.map_io.add_peer(peer_id)

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


var _watched_projectiles: RefCounted = null


## The bullet bridge this bridge last connected to. See [method _watch_bullets].
var _watched_bullets: DotWeaponBulletBridge = null


## The mover world this bridge last sent to (a map change builds a new one).
var _watched_map_io: Node = null


## Hands a map's mover state to the peers that are ready, and again to all of them when a map change builds a new world.
func _watch_map_io() -> void:
	if net == null or not net.is_server or game == null or game.map_io == _live_map_io():
		return
	_watched_map_io = game.map_io
	if _watched_map_io == null:
		return
	_watched_map_io.transport.raw_send = _send_map_state
	for peer in _ready_peers:
		_watched_map_io.add_peer(int(peer))


func _live_map_io() -> Node:
	return _watched_map_io if is_instance_valid(_watched_map_io) else null


func _send_map_state(peer: Variant, payload: Dictionary) -> void:
	var body := JSON.stringify(payload).to_utf8_buffer()
	if body.size() > ArenaEvent.MAX_BODY:
		DotLog.error(CHANNEL, "map state too large for one event, dropped", {"bytes": body.size()})
		return
	send_event(int(peer), ArenaEvents.Kind.MAP_STATE, body)


## Follows whichever projectile layer the game has, and tells every client about each launch. Server
## side, every tick, because a map change builds a new one. The bullet bridge a map change rebuilds, so
## checked every tick. Sends nothing while sv_ballistics is 0, because nothing is then spawned.
func _watch_bullets() -> void:
	if net == null or not net.is_server or game == null:
		return
	var bridge := game.bullet_bridge
	if bridge == _watched_bullets:
		return
	_watched_bullets = bridge
	if bridge == null:
		return
	bridge.bullet_spawned.connect(func(id: int, owner_id: int, weapon_id: StringName, origin: Vector3, velocity: Vector3) -> void:
		send_event(0, ArenaEvents.Kind.BULLET, ArenaEvents.write_bullet(
			id, owner_id, ArenaContent.weapon_index(weapon_id), origin, velocity)))
	bridge.bullets.hit.connect(func(id: int, _o: int, _i: Dictionary, _d: float, _m: float, _t: DotWeaponBallistics) -> void:
		send_event(0, ArenaEvents.Kind.BULLET_END, ArenaEvents.write_bullet_end(id)))
	bridge.bullets.expired.connect(func(id: int) -> void:
		send_event(0, ArenaEvents.Kind.BULLET_END, ArenaEvents.write_bullet_end(id)))


func _watch_projectiles() -> void:
	if net == null or not net.is_server or game == null:
		return

	if not game.grenade_effect.is_connected(_on_grenade_effect):
		game.grenade_effect.connect(_on_grenade_effect)

	var layer: RefCounted = game.projectiles

	if layer == _watched_projectiles:
		return

	_watched_projectiles = layer

	if layer != null and not layer.launched.is_connected(_on_launched):
		layer.launched.connect(_on_launched)


func _on_grenade_effect(info: Dictionary) -> void:
	send_event(0, ArenaEvents.Kind.GRENADE_FX, ArenaEvents.write_grenade_fx(
		int(info["fx"]), info["position"], float(info["radius"]), float(info["seconds"]), int(info["victim"]), float(info.get("strength", 1.0))))


func _on_launched(spawn: DotWeaponSpawn) -> void:
	send_event(0, ArenaEvents.Kind.LAUNCH, ArenaEvents.write_launch(
		spawn, ArenaContent.weapon_index(spawn.id)
	))


## Follows whichever horde the game has. Server side. [b]Every tick, not once.[/b] The horde is built by a mode that has one and torn down by a mode change to one that does not (`ArenaGame._reconcile_world_layers`),
## so a bridge that connected at attach would miss every horde after the first, and one connected at a mode change would need the game to tell it, a second thing to forget.
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
	# Relevant to everybody, whatever the interest grid's radius says: an arena is sixty metres across, a gunner fires from eighteen and a horde arrives from anywhere,
	# and culling by distance announced a monster twenty-five metres away and never sent it a snapshot (drawn frozen where it spawned).
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


## Sends the flag state to [param peer_id] (0 for everyone) when it changed, or at once when [param force].
func _send_ctf(peer_id: int, tick: int, force: bool = false) -> void:
	if game == null or game.objectives == null or game.objectives.ctf == null:
		return
	var text: String = game.objectives.ctf_wire_text(tick, force or peer_id != 0)
	if text != "":
		send_event(peer_id, ArenaEvents.Kind.CTF, text.to_utf8_buffer())


## The last sides text sent to everybody.
var _teams_wire := ""


## Sends who is on which side to [param peer_id] (0 for everyone) when it changed, checked a few times a second.
func _send_teams(peer_id: int, tick: int, force: bool = false) -> void:
	if game == null:
		return
	if peer_id == 0 and not force and tick % 15 != 0:
		return
	var text := ""
	if not game.teams().is_empty():
		var parts := PackedStringArray()
		for id in game.player_ids():
			parts.append("%d:%d" % [id, game.team_of(id)])
		text = ";".join(parts)
	if peer_id == 0:
		if text == _teams_wire:
			return
		_teams_wire = text
	elif text == "":
		return
	send_event(peer_id, ArenaEvents.Kind.TEAM, text.to_utf8_buffer())


## The last SCORE body sent to everybody.
var _scores_wire := PackedByteArray()


## Sends every player's counters and the team scores to [param peer_id] (0 for everyone) when they changed, checked a few times a second.
## Without it a client's scoreboard has names and no numbers: kills, captures and team scores live on the server.
func _send_scores(peer_id: int, tick: int, force: bool = false) -> void:
	if game == null or game.match_node == null or game.match_node.scoreboard == null:
		return
	if peer_id == 0 and not force and tick % 15 != 0:
		return
	var board: DotScoreboard = game.match_node.scoreboard
	var rows: Array[Dictionary] = []
	for id in game.player_ids():
		var record := board.find(str(id))
		if record == null:
			continue
		rows.append({"session_id": id, "kills": record.kills, "deaths": record.deaths,
			"assists": record.assists, "score": record.score, "objectives": ArenaEvents.objectives_of(record)})
	var body := ArenaEvents.write_scores(rows, board.team_scores())
	if peer_id == 0:
		if body == _scores_wire:
			return
		_scores_wire = body
	send_event(peer_id, ArenaEvents.Kind.SCORE, body)


func _send_match_state(peer_id: int) -> void:
	if game == null or game.match_node == null:
		return

	# Ticks, not seconds, because seconds are what the two ends would disagree about: `seconds_remaining` is derived from the tick rate, and the client's rate is whatever HELLO told it.
	# Sending the count and letting each end divide keeps one number on the wire and one conversion on each side.
	send_event(peer_id, ArenaEvents.Kind.MATCH, ArenaEvents.write_match(
		int(game.match_node.state),
		int(round(game.match_node.seconds_remaining() * float(net.config.tick_rate))),
		game.match_node.round_number,
		game.match_node.rules.score_limit if game.match_node.rules != null else 0
	))


## Records this tick's views and sends the clips that are ready, each to its victim.
func _tick_killview() -> void:
	if net == null or not net.is_server or not game.killview_rules.enabled:
		return
	if killview == null:
		killview = game.make_killview_server()
	var tick := game.current_tick()
	var now := float(tick) / float(game.tick_rate)
	killview.record(now)
	for ready: Dictionary in killview.collect(now, tick):
		var peer := peer_for_session(int(ready["victim"]))
		if peer != 0:
			send_event(peer, ArenaEvents.Kind.KILLVIEW, DotKillViewClip.pack(ready["clip"], ready["info"], ArenaEvents.KILLVIEW_BYTES))


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


## Answers the queued READY and RESPAWN requests ([member _tick_asks]) in arrival order. Inside the server tick.
func _answer_tick_asks() -> void:
	if _tick_asks.is_empty():
		return

	var asks := _tick_asks
	_tick_asks = []

	for ask: Array in asks:
		var peer_id := int(ask[0])

		match int(ask[1]):
			ArenaEvents.Ask.READY:
				mark_ready(peer_id)
			ArenaEvents.Ask.RESPAWN:
				# Asked for, never taken. dot-match owns respawning and has its own
				# timer; a client that could respawn itself could respawn instantly. The one
				# exception is a victim watching their kill view, who may skip it.
				if killview != null and game != null:
					killview.skip(session_for_peer(peer_id), game.current_tick())


## Whether dot-net's sends wait for a peer's READY: over a socket, where a call to a node the client has not built yet
## is an engine error per call. A loopback harness delivers to bridges that exist, and keeps its old timing.
func holds_unready() -> bool:
	return link != null and not link.loopback.is_valid()


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
	# The schema dot-net sent on add_peer was held back while the peer built its scene ([method _send]).
	if holds_unready():
		var _announced := net.announce_schema(peer_id)
	send_signon(peer_id)

	if peer_ready_fn.is_valid():
		peer_ready_fn.call(peer_id)

	DotLog.info(CHANNEL, "a peer is ready", {"peer": peer_id})
