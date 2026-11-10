extends "arena_net_bridge_b2.gd"

const ArenaNetCommand := preload("arena_net_command.gd")

## Bytes [method DotNetManager.encode_ack] produces, and the prefix of every input
## packet. Fixed width, so the command that follows starts at a known offset.
const ACK_BYTES := 4


# --- Bots ------------------------------------------------------------------


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
	if game != null:
		game.step_bullet_mirrors(float(tick))

	var command := _command_for(tick, move, fire)
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
## A second pass here once replayed inputs twice: [method DotNetPredictor.correction_rate] read
## [b]0.500[/b] with it and [b]0.032[/b] without, though the client still converged.
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
		net.stats.note_rtt(float(rtt_source.call()) + net.latency.effective() * 2000.0)

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
	var command := _command_for(tick, move, fire)

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


var _lag_for_tick := -1
var _lag_for_q := -1
var _back_for := -1
var _span_for := 0


## The command for [param tick], the same whether [method client_tick] or [method encode_input] made
## it: the server keeps the first copy of a tick to arrive, which is usually the encoded one.
func _command_for(tick: int, move: DotFpsCommand, fire: DotWeaponCommand) -> ArenaNetCommand:
	var command := ArenaNetCommand.new()
	command.tick = tick
	command.delta = net.clock.tick_duration()
	command.move = move
	command.fire = fire
	# Measured once per tick: a snapshot read between the two calls moved the receive clock,
	# the server kept one lag and the replay used the other, and bumps diverged.
	if tick != _lag_for_tick:
		_lag_for_tick = tick
		_lag_for_q = view_lag_q(tick)
		_back_for = -1
		_span_for = 0
		var lag := game.collision_lag(float(_lag_for_q) * 0.25) if game != null and _lag_for_q >= 0 else -1.0
		if lag >= 0.0 and net.interpolator.has_method(&"bracket_at"):
			var pair: Vector2i = net.interpolator.call(&"bracket_at", float(tick) - lag)
			if pair.x >= 0 and tick - pair.x < (1 << ArenaNetCommand.VIEW_BACK_BITS) and pair.y - pair.x < (1 << ArenaNetCommand.VIEW_SPAN_BITS):
				_back_for = tick - pair.x
				_span_for = pair.y - pair.x
	command.view_lag_q = _lag_for_q
	command.view_back = _back_for
	command.view_span = _span_for
	command.lag_always = game != null and game.body_rules.solid
	return command


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

	# One call a packet: the copies of ticks already simulated are skipped rather than counted
	# late, and the arrival lead is measured on the packet's own command only. A resend seen
	# first here was in a lost packet, and measuring it made the client's clock jump under loss.
	return net.input_buffer_for(peer_id).push_batch(batch)


# --- Events and requests ---------------------------------------------------
#
# Everything the server tells a client that is not a snapshot, and everything a client
# asks for. Both ride one message type with a kind inside it — see [ArenaEvent] — so
# adding one is not a wire-id change on two separately-built programs.


## Releases what `cl_latency_baseline` is holding. A client drives its own clock (`auto_tick` off), so dot-net's own step never runs and held snapshots would wait for ever; call it once a frame.
func advance_latency(delta: float) -> void:
	if net != null and net.latency.busy():
		net.latency.advance(delta)


## Sends one input command to the server, through `cl_latency_baseline` when it is on (the link's RPC is not dot-net's send path).
func send_input(tick: int, move: DotFpsCommand, fire: DotWeaponCommand) -> void:
	if link != null:
		_send_held(link.send_input, encode_input(tick, move, fire))


# --- Monsters ----------------------------------------------------------------


## How many monsters this end replicates or draws.
func monster_count() -> int:
	return _monster_nets.size() if net != null and net.is_server else _monster_mirrors.size()


## Tells every ready peer where the match is. Server side.
func announce_match_state() -> void:
	_send_match_state(0)


## An extend raised the match's score limit: everybody's HUD shows it, and a late joiner
## would otherwise be told the one the match started with.
func note_score_limit_changed() -> void:
	if net != null and net.is_server:
		_send_match_state(0)


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
## Not through [DotNetManager]: a voice frame is an opaque codec blob, and the replication
## schema must not change with the codec. Handled by [member voice_in_fn].
func receive_voice(payload: PackedByteArray) -> DotResult:
	if not voice_in_fn.is_valid():
		return DotResult.fail(DotError.CODE_STATE, "Nothing here plays voice.")

	voice_in_fn.call(payload)
	return DotResult.success(payload.size())


## A client's captured audio arrived. Server side.
##
## The speaker is [param peer_id] as the transport reported it, never read from the payload,
## or a client could put words in anybody's mouth.
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


func describe() -> Dictionary:
	return {
		"players": _behaviours.size(),
		"peers": _players_by_peer.size(),
		"tick": _tick,
		"ticked_for": _game_ticked_for,
		"inputs_from": inputs_from,
	}
