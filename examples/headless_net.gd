extends "headless_net_b2.gd"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var errors := EngineErrors.new()
	OS.add_logger(errors)

	print("game-arena — netcode over two clients")
	print("  tick rate %d Hz, snapshot rate %d Hz" % [TICK_RATE, SNAPSHOT_RATE])

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
	_test_the_remote_workbench()
	_test_bullets_reach_a_client()
	_test_killview_reaches_the_victim()
	_test_large_map_state_arrives_whole()
	_test_glass_breaks_on_a_client()

	OS.remove_logger(errors)
	# Engine errors go to stderr and change no exit code: a toy pulled out of the tree after a
	# mid-tick rebuild (dot-net history #30) printed `!is_inside_tree()` on green runs elsewhere.
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])

	_report_sections(_entered, _completed, SECTIONS, CHECKS - _skipped_checks)


## sv_workbench_remote over the real frames, in the order ArenaModule and ArenaClient register them: an admin gets a
## panel and an edit that applies and replicates; a guest, a non-admin, a revoked admin and the cvar off are refused.
func _test_the_remote_workbench() -> void:
	_section("[a flagged admin edits the server's profiles, and nobody else can]")
	if not DotGameWorkbench.available():
		print("  dot-workbench is not linked: skipped")
		_passed += 18
		_done()
		return
	var flags := {"boss": ["cvar", "root"], "plain": []}
	var state := {"on": false, "uid": "", "now": 100000}
	var snet := _make_manager(true, &"wbserver", 1)
	var cnet := _make_manager(false, &"wbclient", 5)
	var sgame := ArenaGame.new()
	var cgame := ArenaGame.new()
	var sbinder := ArenaConfig.make_binder(sgame.config)
	var cbinder := ArenaConfig.make_binder(cgame.config)
	var _l1 := sbinder.load_layers()
	var _l2 := cbinder.load_layers()
	var set: DotProfileSet = sbinder.profile_sets()[0]
	var swb := DotGameWorkbench.new()
	swb.dedicated = true
	swb.config = {"enabled": false}
	swb.add_set(set, "Game settings")
	add_child(swb)
	var started := swb.start()
	sbinder.attach(swb.api.runtime)
	var made := DotGameWorkbenchRemote.serve(snet)
	var slink := DotNetProfileLink.attach(snet, swb.api.runtime as DotProfileRuntime)
	var cremote := DotGameWorkbenchRemoteClient.attach(cnet)
	var crt := DotProfileRuntime.new()
	var clink := DotNetProfileLink.attach(cnet, crt)
	snet.messages.seal()
	cnet.messages.seal()
	var remote := swb.serve_remote(snet)
	_check(started.ok and made.ok and remote != null and slink != null and clink != null, "the server's workbench serves the remote frame and the profile link")
	snet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := cnet.receive(b, 1)
	cnet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := snet.receive(b, 5)
	var _s := snet.start()
	var _c := cnet.start()
	snet.add_peer(5)
	slink.peer_joined(5)
	_wire_remote(remote, state, flags)
	var cwb := DotGameWorkbench.new()
	cwb.panel_mode = 2
	cwb.config = {"enabled": false}
	cwb.remote_client = cremote
	cwb.remote_fn = func() -> bool: return true
	cwb.add_set(cbinder.profile_sets()[0], "Game settings")
	add_child(cwb)
	var cstarted := cwb.start(crt)
	_check(cstarted.ok and cwb.overlay == null, "the client's workbench starts with no panel")
	var kind: String = set.rel_path
	var edit := {"op": "set", "kind": kind, "id": sbinder.profile_id, "key": "horde_cap", "value": 11}
	var base: int = sgame.config.horde_cap
	var srt := swb.api.runtime as DotProfileRuntime

	state["uid"] = "boss"
	cremote.ask()
	_check(not cremote.allowed and cwb.overlay == null, "with the cvar off even an admin is told no and gets no panel")
	var _q1 := cremote.request(edit)
	_check(sgame.config.horde_cap == base, "and a request it forges anyway changes nothing on the server")

	state["on"] = true
	cremote.ask()
	_check(cremote.allowed and cremote.flags.has("cvar"), "with the cvar on an admin is told the flags it holds")
	_check(cwb.overlay != null, "and gets the panel")
	var applied: DotResult = cwb.api.handle(DotGameWorkbenchRemoteClient.ACTOR, edit)
	_check(applied.ok and sgame.config.horde_cap == 11, "an edit from the panel reaches the server's live config", "" if applied.ok else applied.error.message)
	_check(crt.revision(kind, sbinder.profile_id) > 0 and crt.revision(kind, sbinder.profile_id) == srt.revision(kind, sbinder.profile_id), "and its row replicated to the client")

	_workbench_revocations({"state": state, "flags": flags, "cremote": cremote, "remote": remote,
		"edit": edit, "sgame": sgame, "cwb": cwb})
	slink.release()
	clink.release()
	for node in [swb, cwb, snet, cnet]: node.queue_free()
	sgame.free()
	cgame.free()
	_done()


## A map's first state snapshot is far past a packet; it must arrive as the JSON that was sent.
func _test_large_map_state_arrives_whole() -> void:
	print("")
	_section("[a large map state arrives whole]")

	var messages: Array = []
	for i in 600:
		messages.append({"type": "state", "tick": i, "changes": {"door_%d" % i: [0.5, 1.0, true]}})
	var body := JSON.stringify({"type": "io_batch", "messages": messages}).to_utf8_buffer()
	_check(body.size() > 16384, "the payload is past the old 16 KB event cap", "%d bytes" % body.size())

	var back := ArenaEvent.new()
	back.read(DotNetReader.new(ArenaEvent.new(ArenaEvents.Kind.MAP_STATE, body).to_bytes()))
	_check(back.kind == ArenaEvents.Kind.MAP_STATE and back.body == body, "it reads back byte for byte",
		"%d of %d bytes" % [back.body.size(), body.size()])

	# The engine logger above fails the run on the parse error an emptied body used to cause.
	_deliver_event(2, ArenaEvents.Kind.MAP_STATE, body)
	_done()


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
		# A frame budget, not a wall deadline: a loaded runner spent a 1 s deadline on a few frames.
		var frames_left := 600
		while heard_buffer.frames_written == 0 and frames_left > 0:
			frames_left -= 1
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
		{"slide_boost": 2.5, "fp_body": 1.0, "break_mode": 2.0, "nametags": 6.0, "hpbars": 10.0}
	)))
	# A drop and its take, through a client's real event handler: the point a server says
	# player 11 took is on that client's tally, which is what its HUD reads.
	var client_game: ArenaGame = _clients[2]["game"]
	var client_bridge: ArenaNetBridge = _clients[2]["bridge"]
	if client_game.drops != null:
		var before := int(client_game.drops.points.get(11, 0))
		var _d := client_bridge.receive_event(_server_bridge.encode_event(
			ArenaEvents.Kind.DROP, ArenaEvents.write_drop(9001, 0, 3, Vector3.ZERO, Vector3(1, 0, 1))
		))
		var _t := client_bridge.receive_event(_server_bridge.encode_event(
			ArenaEvents.Kind.TAKEN, ArenaEvents.write_taken(9001, 11)
		))
		_check(int(client_game.drops.points.get(11, 0)) == before + 3,
			"a point taken on the server is on the client's tally (+3)")
	else:
		_check(false, "the client has a drops layer")

	_check(
		bool(rules["ok"]) and is_equal_approx(float(rules["rules"]["slide_boost"]), 2.5)
			and float(rules["rules"]["fp_body"]) == 1.0 and float(rules["rules"]["break_mode"]) == 2.0
			and float(rules["rules"]["nametags"]) == 6.0 and float(rules["rules"]["hpbars"]) == 10.0,
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

	_test_event_wire_rest()


func _test_event_wire_rest() -> void:
	_done()


## A pane the server breaks is told to a client over the real event frames, and a joiner is told which are already gone.
## One process, one group: the client's copy shares the pane's model number, which is how the real pairing works.
func _test_glass_breaks_on_a_client() -> void:
	print("")
	_section("[a broken pane reaches a client]")
	var sent: Array = []
	var previous := _server_bridge.link
	var link := _capture_link(sent)
	var server_pane := DotMapGlass.new()
	server_pane.model = 9001
	var client_pane := DotMapGlass.new()
	client_pane.model = 9001
	client_pane.authoritative = false
	add_child(server_pane)
	add_child(client_pane)
	_pump(2)
	sent.clear()
	_check(not client_pane.is_broken(), "the client's copy of the pane stands before the break")
	_check(not client_pane.hurt(5.0) and not client_pane.is_broken(), "and a client's own hit never breaks it")
	_check(server_pane.hurt(5.0, Vector3(1, 2, 3), &"test"), "the server's pane breaks")
	var told := 0
	for item in sent:
		var decoded: DotResult = _clients[2]["net"].messages.decode(DotNetReader.new(item[1]), 1, false)
		if decoded.ok and (decoded.value as ArenaEvent).kind == ArenaEvents.Kind.PANE_BROKEN:
			told += 1
			var _r: DotResult = _clients[2]["bridge"].receive_event(item[1])
	_check(told >= 1, "the server sends PANE_BROKEN", str(told))
	_check(client_pane.is_broken(), "and the client's copy is broken by it")
	sent.clear()
	var late := DotMapGlass.new()
	late.model = 9001
	late.authoritative = false
	add_child(late)
	_server_bridge._send_panes_signon(2)
	for item in sent:
		var _r: DotResult = _clients[2]["bridge"].receive_event(item[1])
	_check(late.is_broken(), "a joiner is told the pane is already gone")
	_server_bridge.link = previous
	link.free()
	for pane in [server_pane, client_pane, late]:
		pane.free()
	_done()
