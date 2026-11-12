extends "arena_net_bridge_b1.gd"

const KillPov := preload("arena_kill_pov.gd")
const ArenaLinkRtt := preload("arena_link_rtt.gd")


const ArenaNpcs := preload("arena_npcs.gd")
const ArenaRequest := preload("arena_request.gd")

## Joins [ArenaGame] to a [DotNetManager]. The netcode seam, and the only file in game-fatal-contact that
## names both.


## Commands in every input packet: this tick's and the four before it, so a packet lost costs the
## server no tick unless four more after it are lost too. See [method encode_input].
const INPUT_COPIES := 5


## Input packets taken, per peer. Server side; what `arena_net` reads to tell one client's
## lossy uplink from another's.
var inputs_from: Dictionary = {}


## Debug: print every [method remote_feet] answer near a contact (netchaos `NC_SOLID_TRACE=1`).
static var solid_trace := false


## [code]func(bytes: PackedByteArray) -> void[/code]. Where a received voice frame goes on a client.
## [ArenaClient] points it at `DotVoiceManager.receive`.
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


## How the client learns its round-trip time, in milliseconds. [b]Nothing in dot-net writes an RTT
## sample, and the clock needs one.[/b] Without it the input lead is a guess, and on a link past
## about 30 ms every input arrives after its tick and is discarded as late.
var rtt_source: Callable = Callable()


## A client link's round trip in milliseconds, ENet's own measurement or else the heartbeat
## ping; 0 while neither knows. Why it is not just `ping_ms`: see ArenaLinkRtt.
static func link_rtt_ms(link: Node) -> float:
	return ArenaLinkRtt.rtt_ms(link)


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


## Emitted on a client when the server sent the replay of its killer's view: [method DotKillViewClip.unpack].
signal killview_received(clip: Dictionary, info: Dictionary)


## Emitted on a client for every kill's medals and points: [method ArenaEvents.read_award].
signal award_received(info: Dictionary)


## Emitted on a client for every head stomp: [method ArenaEvents.read_stomp].
signal stomp_received(info: Dictionary)


## A smoke cloud, fire zone or blind from a utility grenade, as [method ArenaEvents.read_grenade_fx] reads it.
signal grenade_fx_received(info: Dictionary)


## Binds a game and a manager to each other.
func attach(p_game: ArenaGame, p_net: DotNetManager) -> DotResult:
	if p_game == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs both halves.")

	if p_game.is_authority != p_net.is_server:
		# Silent and unplayable either way: a client that resolves its own hits, or a server that resolves none.
		return DotResult.fail(
			DotError.CODE_STATE,
			"The game and the manager disagree about who is authoritative.",
			"game.is_authority=%s, net.is_server=%s"
				% [p_game.is_authority, p_net.is_server]
		)

	game = p_game
	net = p_net

	net.send_fn = _send
	# Registered on BOTH ends in the same order: `seal` derives wire ids and the schema hash
	# from the type names, and a type on one end only means the peers disagree on connect.
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

	game.remote_feet_fn = remote_feet
	game.remote_lags_fn = remote_lags
	# Server toys leave the registry before their nodes go; a client's mirrors stay registered.
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
		game.stomped.connect(_on_stomped)

	return DotResult.success(self)


## Creates the RPC surface under [param parent]. Separate from [method attach] because the parent differs by end and deployment: on a server the [DotServer] node, on a client the [DotClientLink],
## in the headless suite a bare [Node] with a loopback in place of a socket. All three must be NAMED the same, because the name is the routing.
func open_link(parent: Node) -> ArenaNetLink:
	link = ArenaNetLink.attached_to(parent, self, net != null and net.is_server)
	# Through DotGameLink, not a bare add_child: the link sits under the server node (the
	# route is by path), so nothing frees it when this bridge's module unloads, and the next
	# load's link would be renamed `@Node@n` and every RPC to a client lost.
	DotGameLink.attach(link, parent, self, ArenaNetLink.NODE_NAME)
	return link


## Where dot-net's own outgoing bytes go. [param delivery] decides the call, not the caller: a snapshot is unreliable and an event is not, and dot-net knows which is which.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	# Over a socket, only to a peer that said READY, as [method send_event] does. dot-net sends its schema on
	# add_peer and snapshots from the next tick, while the client may still be building the scene its `Server/Arena`
	# node sits in: the solo host's client joins first and builds for 30 s after, and every call that arrived in that
	# time was a `Node not found: "ArenaSimServer/Server/Arena"` error on its console. [method mark_ready] sends the schema again.
	if net.is_server and holds_unready():
		if peer_id == 0:
			for ready_peer in _ready_peers:
				_send(int(ready_peer), payload, delivery)
			return
		if not _ready_peers.has(peer_id):
			unready_held += 1
			return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		# A client's reliable send is a request. dot-net sends exactly one through here (its message schema, as it starts);
		# `send_event` is a call only the server may make, and the server's end refuses it from a client.
		link.send_request(payload)


## Tells everybody who somebody is now: a profile that arrived after they were seated, a new avatar, an operator's rename. Server side. [b]Through JOIN, which a client already applies to a player it has[/b];
## a second message for "this person changed" would be one more thing a late joiner has to be told. An empty [param display_name] keeps the one they have.
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


## Whether [method remote_feet] can answer anything but now for [param mover_id]'s movement: it has sent a view lag and compensation is on (or the trace is, which prints each answer).
## A bot, or a person with no lag, is moved against the others where they stand.
func remote_lags(mover_id: int) -> bool:
	var mover: ArenaPlayerNet = _behaviours.get(mover_id)
	return mover != null and game != null and (solid_trace or game.collision_lag(mover.last_view_lag) >= 0.0)


## Where [param other_id] stands for [param mover_id]'s movement on [param tick]: where the
## mover's client drew them, the command's view lag behind ([method ArenaGame.collision_lag]),
## the same on both ends. Null is now: no lag sent (a bot), compensation off, or past a teleport.
func remote_feet(other_id: int, mover_id: int, tick: int) -> Variant:
	var mover: ArenaPlayerNet = _behaviours.get(mover_id)
	if mover == null or game == null:
		return null
	# A command repeated over a lost packet keeps its view LAG: the client's receive timeline walks with its clock (`DotNetClock.advance`), so the tick the packet was lost for measured the same lag one tick on.
	# What does not move on is the snapshot bracket, which names two recorded ticks: it is aged by the ticks since, then stepped to the pair the view has reached (holding its offset blended between two ticks the client never held).
	var lag := game.collision_lag(mover.last_view_lag)
	var at: Variant = null
	if lag >= 0.0:
		var older := -1
		if mover.last_view_back >= 0:
			var aged := maxi(tick - mover.last_view_tick, 0) if mover.last_view_tick >= 0 else 0
			older = tick - aged - mover.last_view_back
			if aged > 0 and mover.last_view_span > 0:
				while float(tick) - lag > float(older + mover.last_view_span):
					older += mover.last_view_span
		at = _remote_feet_at(other_id, float(tick) - lag, older, mover.last_view_span)
	if solid_trace:
		_trace_feet(other_id, mover, tick, lag, at)
	return at


## Between the snapshot ticks [param older] and older + [param span] when the command named them
## (-1 for none), else at [param view_tick] as the ring or buffer has it.
func _remote_feet_at(other_id: int, view_tick: float, older: int, span: int) -> Variant:
	var bracketed := older >= 0
	if net.is_server:
		if bracketed:
			# Snapped to the wire, as the client's two samples are: half a centimetre is a contact.
			var wire := _position_wire(other_id)
			return game.unlag_position_between(other_id, older, older + span, view_tick, wire)
		return game.unlag_position_at(other_id, view_tick)
	var other: ArenaPlayerNet = _behaviours.get(other_id)
	if other == null or other.identity == null or net.interpolator == null or not net.interpolator.has_method(&"value_at"):
		return null
	if bracketed and net.interpolator.has_method(&"value_between"):
		return net.interpolator.call(&"value_between", other.identity.net_id, &"net_position", older, older + span, view_tick, ArenaGame.TELEPORT_CUT)
	return net.interpolator.call(&"value_at", other.identity.net_id, &"net_position", view_tick, ArenaGame.TELEPORT_CUT)


## Takes a bot out, told to everybody as a leave.
func remove_bot(session_id: int) -> void:
	if not _bot_minds.has(session_id):
		return

	_bot_minds.erase(session_id)
	ArenaBots.forget(game, session_id)
	if killview != null:
		killview.forget(session_id)
	var behaviour: ArenaPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if net != null and net.is_server:
		send_event(0, ArenaEvents.Kind.LEAVE, ArenaEvents.write_leave(session_id))
		var identity := behaviour.player.get_node_or_null(^"Identity") as DotNetIdentity if behaviour != null and behaviour.player != null else null
		if identity != null and identity.net_id > 0:
			net.registry.unregister(identity.net_id)

	game.remove_player(session_id)


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


## Sends an event to one peer, or to every ready peer when [param peer_id] is 0. [b]Ready peers, not connected ones[/b]: a peer past dot-server's signon has a socket and has not built its scene,
## so an RPC lands on a node that does not exist ("Node not found" per call). The gate is [enum ArenaEvents.Ask].READY.
## The server changed a movement rule: every client gets the whole set. Server side; a client's own set_movement_rules emits this too and must not echo it back.
func _on_movement_rules_changed(rules: Dictionary) -> void:
	if net == null or not net.is_server:
		return
	send_event(0, ArenaEvents.Kind.RULES, ArenaEvents.write_rules(rules))


## The jail's gate was pressed or its rules changed: every client gets the state. Server side.
func _on_jail_changed() -> void:
	if net == null or not net.is_server or game == null or game.map == null or game.map.jail == null:
		return
	send_event(0, ArenaEvents.Kind.JAIL, _jail_body())


## Sends a request to the server. Client side.
func send_request(kind: int, body: PackedByteArray = PackedByteArray()) -> void:
	if net == null or net.is_server or link == null:
		return

	var writer := DotNetWriter.new()
	var wrote := net.messages.encode(ArenaRequest.new(kind, body), writer)

	if not wrote.ok:
		return

	_send_held(link.send_request, writer.to_bytes())


func _send_held(sender: Callable, payload: PackedByteArray) -> void:
	if net == null or not net.latency.delaying():
		sender.call(payload)
		return
	var weak: WeakRef = weakref(link)
	net.latency.hold(func() -> void:
		if weak.get_ref() != null:
			sender.call(payload))


## A launch the server announced, flown here as a copy. Client side.
func _mirror_launch(launch: Dictionary) -> void:
	if game == null or game.projectiles == null:
		return

	var id := ArenaContent.weapon_at(int(launch["weapon"]))
	game.projectiles.launch(ArenaEvents.spawn_from_launch(launch, id))


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


func _on_match_state_changed(_from: int, _to: int) -> void:
	_send_match_state(0)


func _on_player_killed(entry: DotKillFeed.Entry) -> void:
	if killview != null and net != null and String(entry.killer_key).is_valid_int() and String(entry.victim_key).is_valid_int():
		var named: ArenaPlayer = game.player_for(int(entry.killer_key))
		var res := killview.note_kill(int(entry.killer_key), int(entry.victim_key), float(game.current_tick()) / float(game.tick_rate), {
			"killer": named.display_name if named != null else "", "weapon": String(entry.cause)})
		if not res.ok:
			DotLog.trace(CHANNEL, "no kill view", {"why": res.error.message})
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


func _on_stomped(attacker: int, victim: int, fall_speed: float, point: Vector3, sound: StringName, effect: StringName) -> void:
	send_event(0, ArenaEvents.Kind.STOMP, ArenaEvents.write_stomp(attacker, victim, fall_speed, point, String(sound), String(effect)))


func _on_medals_awarded(killer: int, victim: int, medals: Array, points: int, streak: int) -> void:
	send_event(0, ArenaEvents.Kind.AWARD, ArenaEvents.write_award(killer, victim, points, streak, medals))


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
			_adopt_tick_rate(int(info["tick_rate"]), int(info["snapshot_rate"]))
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
		ArenaEvents.Kind.HIT:
			var hit := ArenaEvents.read_hit(reader)
			if bool(hit["ok"]):
				hit_received.emit(hit)
		ArenaEvents.Kind.AWARD:
			var award := ArenaEvents.read_award(reader)
			if bool(award["ok"]):
				award_received.emit(award)
		ArenaEvents.Kind.STOMP:
			var stomp := ArenaEvents.read_stomp(reader)
			if bool(stomp["ok"]):
				stomp_received.emit(stomp)
		ArenaEvents.Kind.GRENADE_FX:
			var burst := ArenaEvents.read_grenade_fx(reader)
			if bool(burst["ok"]):
				grenade_fx_received.emit(burst)
		ArenaEvents.Kind.KILLVIEW:
			var view := DotKillViewClip.unpack(event.body)
			if bool(view["ok"]):
				killview_received.emit(view["clip"], view["info"])
		_:
			_on_world_event(event, reader)


## The events about the world (bullets, toys, drops, the jail and the rules), split from [method _on_event].
func _on_world_event(event: ArenaEvent, reader: DotNetReader) -> void:
	match event.kind:
		ArenaEvents.Kind.BULLET:
			var bullet := ArenaEvents.read_bullet(reader)
			if bool(bullet["ok"]):
				game.mirror_bullet(int(bullet["id"]), ArenaContent.weapon_at(int(bullet["weapon"])),
					bullet["origin"], bullet["velocity"], int(bullet["owner"]))
		ArenaEvents.Kind.BULLET_END:
			var ended := ArenaEvents.read_bullet_end(reader)
			if bool(ended["ok"]):
				game.end_bullet_mirror(int(ended["id"]))
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
		ArenaEvents.Kind.WEAPON_DROP, ArenaEvents.Kind.WEAPON_SETTLED, ArenaEvents.Kind.WEAPON_GONE:
			_apply_weapon_drop_event(event.kind, reader)
		ArenaEvents.Kind.PANE_BROKEN:
			_apply_pane_broken(reader)
		ArenaEvents.Kind.MORE:
			_apply_more_event(reader)
		ArenaEvents.Kind.PROP_BROKEN:
			_apply_prop_broken(reader)
		ArenaEvents.Kind.MAP_STATE:
			var told_state: Variant = null
			if not event.body.is_empty():
				told_state = JSON.parse_string(event.body.get_string_from_utf8())
			if told_state is Dictionary and game != null and game.map_io != null:
				game.map_io.receive(told_state)
		ArenaEvents.Kind.CTF:
			if game != null and game.objectives != null:
				game.objectives.apply_ctf_text(event.body.get_string_from_utf8())
		ArenaEvents.Kind.TEAM:
			if game != null:
				game.apply_teams_text(event.body.get_string_from_utf8())
		ArenaEvents.Kind.SCORE:
			var told_scores := ArenaEvents.read_scores(reader)
			if bool(told_scores["ok"]) and game != null:
				_apply_scores(told_scores)
		ArenaEvents.Kind.JAIL:
			var told_jail := ArenaEvents.read_jail(reader)
			if bool(told_jail["ok"]) and game != null:
				game.apply_jail_state(told_jail)
		ArenaEvents.Kind.RULES:
			var rules := ArenaEvents.read_rules(reader)
			if bool(rules["ok"]) and game != null:
				game.set_movement_rules(rules["rules"])
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
		# READY and RESPAWN can spawn a player, and a spawn's sight test traces the map (the physics space on an imported map):
		# answered at the top of the next server tick ([method _answer_tick_asks]), never here in the idle frame.
		ArenaEvents.Ask.READY, ArenaEvents.Ask.RESPAWN:
			_tick_asks.append([peer_id, request.kind])
		ArenaEvents.Ask.FOV:
			var who: Object = game.player_for(session_for_peer(peer_id)) if game != null else null
			if who != null:
				KillPov.note_field_of_view(who, ArenaEvents.read_fov(request.reader()))
		ArenaEvents.Ask.PROP_TOOL:
			_on_prop_act(peer_id, ArenaEvents.read_prop_act(request.reader()))
		ArenaEvents.Ask.HOST:
			_on_host_ask(peer_id, request.reader())
		_:
			pass


## A client asked to do something with a prop, answered in the next tick. [b]The origin comes from the simulation and only the direction comes off the wire[/b]: the server knows where the player is, and a client naming its own origin could grab a prop from anywhere.
## What it cannot know is where they were looking between two ticks, so that is the one thing the payload carries, and a claim.
## The tool decides whether it reaches: `DotPropTool.may_act_on` enforces the range, the mass limit and whose prop it is.
func _on_prop_act(peer_id: int, body: Dictionary) -> void:
	if not bool(body.get("ok", false)) or game == null or game.props == null:
		return

	var session_id := session_for_peer(peer_id)

	if session_id <= 0:
		return

	var player := game.player_for(session_id)

	if player == null or not player.is_alive():
		return

	# Queued: a grab, punt or pull traces the physics space, so it runs in the next tick (`ArenaProps.queue_act`).
	game.props.queue_act(session_id, int(body["act"]), DotFpsMotor.aim_for(float(body["yaw"]), float(body["pitch"])))


## The client's own tick rate comes from the SERVER, and from nowhere else. [b]This is the largest measured error in this family's history.[/b] g2gfast's client took its rate from `Engine.physics_ticks_per_second`,
## which a browser shell never sets (60 against a 128-tick server): correction rate 0.96, prediction never converging, every replicated time wrong by the ratio of the rates. HELLO always carried the number; nothing read it back.
## All four copies move together, the engine's among them: the fraction a renderer interpolates at is a fraction through a PHYSICS frame, a fraction through a tick only while the two rates agree.
func _adopt_tick_rate(rate: int, snapshot_rate: int = 0) -> void:
	if rate <= 0 or game == null or net == null:
		return

	# Players that already exist too, not only the ones added after this.
	game.set_tick_rate(rate)
	net.config.tick_rate = rate
	# The server's own number when HELLO carried one (sv_snapshot_rate), else derived as before.
	net.config.snapshot_rate = snapshot_rate if snapshot_rate > 0 and snapshot_rate <= rate else ArenaGame.snapshot_rate_for(rate)
	net.config.interpolation_buffer = ArenaGame.client_interp_buffer(net.config.snapshot_rate)
	# A copy taken at setup() that writing the config does not touch.
	net.clock.tick_rate = rate
	if game.spectate != null:
		game.spectate.retime()
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap to a quarter second of ticks (a client under 16 fps ran fewer ticks than the server at 128 Hz).
	# A shell built before it gets the same rule here, as game-airdrift does; remove this branch when the oldest shell is API 7.
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


## The server's counters over this client's scoreboard, whose records JOIN made with names and nothing else.
## Whole values, not deltas, so a missed event or a round reset is mended by the next one.
func _apply_scores(told: Dictionary) -> void:
	if game.is_authority or game.match_node == null or game.match_node.scoreboard == null:
		return
	var board: DotScoreboard = game.match_node.scoreboard
	for row: Dictionary in told["rows"]:
		var record := board.find(str(int(row["session_id"])))
		if record == null:
			continue
		record.kills = int(row["kills"])
		record.deaths = int(row["deaths"])
		record.assists = int(row["assists"])
		record.score = int(row["score"])
		record.extra = {&"objectives": int(row["objectives"])} if int(row["objectives"]) > 0 else {}
		board.score_changed.emit(record)
	var teams: Dictionary = told["teams"]
	for team: int in teams:
		board.add_team_score(team, int(teams[team]) - board.team_score(team))
	for team in board.team_scores():
		if not teams.has(team):
			board.add_team_score(int(team), -board.team_score(int(team)))
