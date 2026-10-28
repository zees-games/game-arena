extends DotGameCheckSuite
## Shared state, the harness and the boot of headless_lossy, split out for the file size gate.

const ArenaEvents := preload("../game/arena_events.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModTools := preload("../game/arena_mod_tools.gd")
const ArenaContent := preload("../game/arena_content.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## dot-net's lossy UDP relay, by path: a test tool that ships inside the addon so a game
## that links dot_net can reach it, and has no class_name for the same reason.
const Relay := preload("res://addons/dot_net/testing/dot_net_udp_relay.gd")

## A real arena server, real ENet clients, and real packet loss between them.
##
## [codeblock]
## godot --headless --path . res://examples/headless_lossy.tscn
## godot --headless --path . res://examples/headless_lossy.tscn -- --verbose
## [/codeblock]
##
## [code]--verbose[/code] adds the diagnostics every finding here was made with: A's clock
## every quarter second, its inputs and ENet's packet throttle every half second, input
## transit and snapshot age, and a line per freeze. [code]--ping-rtt[/code] puts a defect
## back as a control: it feeds the clock the heartbeat's round trip instead of ENet's (see
## [method ArenaNetBridge.link_rtt_ms]), and it fails checks. (`--stock-enet` was the other
## until dot-core's DotTransportENet stopped advertising six bytes a second; its own
## `dual_transport_selftest` holds that one now.)
##
## [b]What only this can see.[/b] `headless_net` drops one packet in five, but in its own
## loopback: in order, instantly, never twice, and never a reliable one. A browser's
## "unreliable" is TCP. So until a server listened on ENet as well, nothing here had ever
## had a datagram arrive late, out of order, twice, or not at all -- and a reliable event
## had never been retransmitted. This puts dot-net's relay between a real `DotClientLink`
## on ENet and a real `DotServer` running `ArenaModule`, and plays.
##
## Two clients. **A** goes through the relay and is the one measured: it runs, strafes and
## turns, so its prediction has something to get wrong. **B** connects straight to the
## server and runs a circle, so the server's B is a smooth reference A's interpolation can
## be held to. A dummy the server adds itself is slain every couple of seconds, for a kill
## feed nobody's own movement is caught up in.
##
## A's first three seconds are measured on their own, and then each window plays at one
## setting -- a steady 55 ms each way, then 5% and 20% loss each way with 30..80 ms -- and
## measures: whether A stays connected; how far A's clock error moves once settled; how
## smooth A's drawing of B is (the longest freeze while B moved, the largest jump beyond
## B's own motion, how far the drawing is from where the server had B at that render
## time, extrapolated frames); how far A's prediction is from the server's A, tick for
## tick, and what the predictor corrected; the loss DotNetStats reports against what the
## relay injected; and that every reliable event -- a numbered notice, a kill, a chat line
## either way, a join and a leave -- arrived exactly once and in order.

const PORT := 27094
const DATA := "user://arena_lossy"
## `-- --tick-rate=30` (or ARENA_TICK_RATE) runs the same suite at another rate; tick-count thresholds scale with it.
var TICK_RATE := _tick_rate_arg()
const DUMMY_ID := 9001

## The windows: name, loss each way, delay, jitter (so 30..80 ms), seconds.
const WINDOWS := [
	["steady 55 ms", 0.0, 55.0, 0.0, 6.0],
	["5% loss", 0.05, 55.0, 25.0, 10.0],
	["20% loss", 0.20, 55.0, 25.0, 10.0],
]

## How long the first-seconds measurement runs, right after A connects.
const FIRST_SECONDS := 3.0

## How long anything sent reliably may take to land: ENet's own contract, not a guess. With
## dot-core's peer timeouts a reliable command either arrives within 30 s or the peer is
## dropped. ENet doubles a command's resend timeout every time it goes unacknowledged, and a
## try fails if the data OR its acknowledgement is lost: 36% a try at 20% each way. So the
## tail is long and real: a wait shorter than this is a wait on the dice, and every one that
## was written shorter (6 s for the windows' streams, 10 s for B's leave, 5 s for the cvars)
## flaked on exactly that tail. A wait on it ends the moment the thing arrives.
const RELIABLE_SECONDS := 35.0

## Checks per window, and outside them.
const WINDOW_CHECKS := 16
const OTHER_CHECKS := 59

var CHECKS := OTHER_CHECKS + WINDOW_CHECKS * WINDOWS.size()

var _entered := 0
var _completed := 0
var _verbose := false

var _server_side: Node = null
var _server: DotServer = null
var _game: ArenaGame = null
var _relay = null

## name -> client record, see [method _connect_client].
var _clients: Dictionary = {}

## Whether the per-frame drivers run.
var _driving := false

## Server truth: session id -> {tick -> Vector3}, recorded every physics frame.
var _server_track: Dictionary = {}

## A's prediction: input tick -> Vector3.
var _predicted: Dictionary = {}

## What a window measures per frame. Reset by [method _begin_window].
var _w: Dictionary = {}

## The reliable streams, as sent and as A received them.
var _sent_notices: Array[String] = []
var _sent_chat: Array[String] = []
var _sent_kills: Array[String] = []
var _sent_a_chat: Array[String] = []
var _got_notices: Array[String] = []
var _got_chat: Array[String] = []
var _got_kills: Array[String] = []
var _got_a_chat: Array[String] = []
var _a_saw_added: Array[int] = []

## Verbose diagnostics: when A sent each input tick, and the transit times seen.
var _w_sent_at: Dictionary = {}
var _last_half := 0
var _last_sent := 0
var _last_got := 0
var _w_seen_up: Dictionary = {}

## A's input tick its wall script starts on, or -1 while A plays its usual pattern; and
## the tick it went idle at the wall's foot before that. See [method _test_wall_moves].
var _wall_from := -1
var _wall_idle := false
var _hop_from := -1

## A's input tick its sprint pattern starts on (-1 off), and whether the wall script holds sprint.
var _stam_from := -1
var _wall_hold_sprint := false


static func _tick_rate_arg() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tick-rate="):
			return clampi(int(arg.trim_prefix("--tick-rate=")), 10, 240)
	return clampi(int(OS.get_environment("ARENA_TICK_RATE")), 10, 240) if OS.has_environment("ARENA_TICK_RATE") else 64


## A tick-count threshold written for 64 Hz, scaled to the rate this run uses.
func _ticks(at_64: int) -> int:
	return at_64 * TICK_RATE / 64


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


## The client's ENet packet throttle towards the server, out of 32; -1 off ENet.
func _throttle_of(label: String) -> int:
	var mp: Object = (_clients[label]["link"] as DotClientLink).multiplayer.multiplayer_peer
	var server_peer: Object = mp.call("get_peer", 1) if mp != null and mp.has_method("get_peer") else null
	if server_peer == null or not server_peer.has_method("get_statistic"):
		return -1
	return int(server_peer.call("get_statistic",
		ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_PACKET_THROTTLE")))


func _peer_of(label: String) -> int:
	return (_clients[label]["link"] as DotClientLink).multiplayer.get_unique_id()


func _module() -> ArenaModule:
	return _server.modules.get_module("arena") as ArenaModule if _server != null else null


# --- Boot -------------------------------------------------------------------

func _boot() -> bool:
	_section("a dual-stack arena server, and the relay in front of its UDP port")

	_server_side = Node.new()
	_server_side.name = "ServerSide"
	add_child(_server_side)
	# Its own MultiplayerAPI, and so does each client: one process, three ends, and an RPC
	# is routed by its path relative to the API's root -- `Server/Arena` on every end.
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _server_side.get_path())

	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.register_service = true
	_server_side.add_child(_game)

	var ready := _game.setup(ArenaMap.dm_box())
	if not _check(ready.ok, "the arena sets up", str(ready.error)):
		_done()
		return false

	var config := DotServerConfig.new()
	config.hostname = "arena lossy"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % DATA
	config.bans_path = "%s/bans.json" % DATA
	config.audit_log_path = "%s/audit.jsonl" % DATA
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	# No query listener: with one the UDP port is shared through a demux, which is its own
	# measurement (dual-stack-follow-1, point 2). This one is about the game's traffic.
	config.query_enabled = false
	# Its own UDP port, not shared through the demux: that relay is its own measurement too.
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "debug" if _verbose else "error"

	# The server's ENet is dot-core's own: DotTransportENet no longer advertises the engine's
	# channel count as its incoming bandwidth (which throttled every client's commands to
	# 1/32 for its first seconds; see docs/history.md), so nothing is built by hand.

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	_server_side.add_child(_server)

	var booted: DotResult = await _server.boot()
	if not _check(booted.ok, "the server boots, WebSocket and ENet on %d" % PORT, str(booted.error)):
		_done()
		return false

	ArenaModule.punishments_file = "%s/punishments.json" % DATA
	var loaded: DotResult = await _server.modules.load_module("res://game/arena_module.gd")
	if not _check(loaded.ok, "the arena module loads", str(loaded.error)):
		_done()
		return false

	# No quota bots, as in headless_feel. A client predicts its own player against the
	# others where it last heard they are, a round trip old, so a bump into a running bot
	# is a correction of up to a couple of metres that no loss caused; and a bot shoots. A
	# fills a server to four with two bots, and whether A met one in a window was down to
	# the wall clock: 0.9 to 1.3 m worst on a desk, p95 0.59 m and 2.1 m on a CI runner
	# (v0.1.11's release). This suite measures the link; players against players is
	# headless_net's.
	var quota: DotBotQuota = _module().get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("off")

	_relay = Relay.new()
	_relay.seed = 20261009
	var w: Array = WINDOWS[0]
	_relay.up.configure(float(w[1]), float(w[2]), float(w[3]))
	_relay.down.configure(float(w[1]), float(w[2]), float(w[3]))
	var relayed: DotResult = _relay.start(0, "127.0.0.1", config.effective_enet_port())
	_check(relayed.ok, "the relay listens in front of UDP %d" % config.effective_enet_port(),
		str(relayed.error))
	_done()
	return relayed.ok


## A client: a DotClientLink on ENet only, and the netcode `ArenaClient._build_netcode`
## builds, minus everything that draws.
func _connect_client(label: String, udp_port: int, lift_cover: bool = true) -> Dictionary:
	var side := Node.new()
	side.name = "Client%s" % label
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())

	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Runner %s" % label
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % udp_port
	side.add_child(link)

	var record := {
		"label": label, "side": side, "link": link, "game": null, "net": null,
		"bridge": null, "session": 0, "spawned": [false], "gone": [""], "hello": [{}],
	}
	link.spawned.connect(func() -> void: record["spawned"][0] = true)
	link.disconnected.connect(func(reason: String) -> void: record["gone"][0] = reason)

	# Started without `await`, so a failed join is read off the link rather than waited on.
	link.connect_to_server("127.0.0.1:%d" % PORT)

	await _until(func() -> bool:
		return record["spawned"][0] or record["gone"][0] != "" \
			or link.phase == DotClientLink.Phase.FAILED, 30.0)
	if link.last_error != null and not record["spawned"][0]:
		record["error"] = str(link.last_error)
		return record
	if not record["spawned"][0]:
		record["error"] = "never spawned: %s" % record["gone"][0]
		return record

	# What DotGameClient does when its gate opens. A client that never says so is held
	# unharmable by the server for its load timeout, which would change every other section.
	if lift_cover:
		DotGameClient.report_cover(link, false)

	var game := ArenaGame.new()
	game.name = "Game"
	game.is_authority = false
	game.headless = true
	game.register_service = false
	side.add_child(game)
	game.setup(ArenaMap.dm_box())
	# What `ArenaClient._build_netcode` does: the server's replicated cvars, through the link.
	var _following := game.follow_server_cvars(link)

	var net := DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.service_scope = StringName("lossy_%s" % label)
	net.local_peer_id = side.multiplayer.get_unique_id()
	net.auto_tick = false
	net.config_file = ""
	var cfg := DotNetConfig.new()
	cfg.tick_rate = game.tick_rate
	cfg.snapshot_rate = ArenaGame.NET_SNAPSHOT_RATE
	cfg.enable_prediction = true
	cfg.enable_lag_compensation = false
	cfg.max_entities_per_snapshot = 64
	cfg.world_extent = ArenaGame.NET_WORLD_EXTENT
	net.config = cfg
	side.add_child(net)
	net.setup()

	var bridge := ArenaNetBridge.new()
	bridge.name = "Bridge"
	side.add_child(bridge)
	bridge.attach(game, net)
	bridge.open_link(link)
	net.messages.seal()
	# What `ArenaClient` feeds it. `--ping-rtt` puts back the heartbeat alone, which is the
	# control for the clock checks: the first eight seconds of a connection are late then.
	if "--ping-rtt" in OS.get_cmdline_user_args():
		bridge.rtt_source = func() -> float: return float(maxi(0, link.ping_ms()))
	else:
		bridge.rtt_source = func() -> float: return ArenaNetBridge.link_rtt_ms(link)
	bridge.hello_received.connect(func(info: Dictionary) -> void:
		record["hello"][0] = info
		record["session"] = int(info["session_id"])
	)

	record["game"] = game
	record["net"] = net
	record["bridge"] = bridge
	net.start()
	bridge.send_request(ArenaEvents.Ask.READY)

	await _until(func() -> bool: return int(record["session"]) != 0 and net.clock.is_synced(), 20.0)
	return record


## [b]dot-combat's `mp_teammate_passthrough` on a client.[/b] The client traces its own shots
## for tracers and impacts; on its default against a server on 0 or 2 they ended in, or went
## through, a team-mate where the server's did the opposite. The server's value rides
## dot-server's replicated cvars before the scene loads, and every change after it.
func _test_server_cvars_reach_the_client() -> void:
	_section("the server's mp_teammate_passthrough reaches a client's world, live")
	var a: Dictionary = _clients["A"]
	var link: DotClientLink = a["link"]
	var a_game: ArenaGame = a["game"]
	_check(link.replicated_cvar("mp_teammate_passthrough") == "1" and a_game.combat.rules.pass_through_level() == 1,
		"the join carried the server's level and A's world is on it",
		str(link.replicated_cvars))

	# Each change is one reliable CVARS message through the link, still at the last window's
	# 20% loss each way, so each wait is RELIABLE_SECONDS. These were 5 s and failed one run
	# in 30 (2026-10-11): 60 changes measured 48 ms to 4.2 s (one resend 270 ms, three or
	# four 1.1-2.1 s), and one 2 took past 5 s with the 0 queued behind it, in order on the
	# channel, landing 9 s after the 2 was sent. At 35 s, six runs: one 2 at 12.3 s, one
	# change at 4.7 s; the late 2's 0 landed 100 ms after it, so it was arriving all along. What is checked is that the change arrives
	# and A's rules follow it, not how fast ENet resends; the time is in the detail.
	var t0 := Time.get_ticks_msec()
	# What A's link was told, and when: a late change and a lost one look alike otherwise.
	var told: Array[String] = []
	var hear := func(cvar_name: String, value: String) -> void:
		if cvar_name == "mp_teammate_passthrough":
			told.append("%s at +%d ms" % [value, Time.get_ticks_msec() - t0])
	var _hear := link.replicated_cvar_changed.connect(hear)
	var down_from: int = _relay.down.delivered
	var _two := _server.console.set_cvar("mp_teammate_passthrough", "2")
	_check(await _until(func() -> bool: return a_game.combat.rules.pass_through_level() == 2, RELIABLE_SECONDS),
		"the server goes to 2 and A's combat rules follow, so its predicted shot passes team-mates too",
		"%d ms; told %s; %d datagrams down meanwhile; %s" % [Time.get_ticks_msec() - t0, told,
			_relay.down.delivered - down_from, a_game.combat.rules.describe()])
	var _zero := _server.console.set_cvar("mp_teammate_passthrough", "0")
	_check(await _until(func() -> bool: return a_game.combat.rules.pass_through_level() == 0, RELIABLE_SECONDS),
		"and to 0", "+%d ms; told %s; %s" % [Time.get_ticks_msec() - t0, told, a_game.combat.rules.describe()])

	# A map change builds A's world a new manager: it keeps following. Held to what the link
	# holds, not to 0, so a 0 that never came fails "and to 0" above and not this as well;
	# the held value must not be the default, or the check could not tell.
	var held := link.replicated_cvar("mp_teammate_passthrough")
	var rebuilt := a_game.change_map(a_game.map)
	_check(rebuilt.ok and held != "1" and a_game.combat.rules.pass_through_level() == int(held),
		"a manager A's world builds for a new map starts on the server's level, not the default",
		"level %d, the link holds %s" % [a_game.combat.rules.pass_through_level(), held])
	var _two_again := _server.console.set_cvar("mp_teammate_passthrough", "2")
	_check(await _until(func() -> bool: return a_game.combat.rules.pass_through_level() == 2, RELIABLE_SECONDS),
		"and the next change reaches it", "+%d ms; told %s" % [Time.get_ticks_msec() - t0, told])
	var _one := _server.console.set_cvar("mp_teammate_passthrough", "1")
	# The leave section reuses A's link; a listener left behind would outlive this section.
	link.replicated_cvar_changed.disconnect(hear)
	_done()


## [b]`arena_ambient*` on a client.[/b] The server's ambience intent rides the replicated cvars, and a
## director that follows the game's rules (as `ArenaClient` wires it) has it in its layer's config.
func _test_ambient_cvars_reach_the_client() -> void:
	_section("the server's arena_ambient* reaches a client's ambience director, live")
	var a: Dictionary = _clients["A"]
	var link: DotClientLink = a["link"]
	var a_game: ArenaGame = a["game"]
	var director := DotAmbienceDirector.new()
	director.ambient = DotAmbience.new()
	director.follow_settings(null, a_game.ambient_rules)
	_check(link.replicated_cvar("arena_ambient_volume", "") != "" and link.replicated_cvar("arena_ambient_dir", "x") == "x",
		"the join carried arena_ambient_volume, and the machine-local arena_ambient_dir stayed home", str(link.replicated_cvars))
	var _vol := _server.console.set_cvar("arena_ambient_volume", "0.8")
	var _mood := _server.console.set_cvar("arena_ambient_mood", "swamp")
	var _off := _server.console.set_cvar("arena_ambient", "0")
	_check(await _until(func() -> bool:
		return is_equal_approx(director.ambient.config.volume, 0.8) and director.ambient.config.mood == "swamp" \
			and not director.ambient.config.enabled, RELIABLE_SECONDS),
		"a change of volume, mood and the switch reaches A's director live", str(a_game.ambient_rules.describe()))
	var _back_vol := _server.console.set_cvar("arena_ambient_volume", "0.3")
	var _back_mood := _server.console.set_cvar("arena_ambient_mood", "")
	var _back_on := _server.console.set_cvar("arena_ambient", "1")
	_check(await _until(func() -> bool:
		return a_game.ambient_rules.is_on() and a_game.ambient_rules.mood == "", RELIABLE_SECONDS),
		"and back", str(a_game.ambient_rules.describe()))
	director.ambient.free()
	director.free()
	_done()


## [b]zee-dot-weapons' `mp_vm_*` and the map's packs on a client.[/b] The hands are drawn on the
## client, so the server's sway, tilt, bob, landing and aim steadiness have to reach it, at the
## join and live; and a pack lives the whole map, so a client that joined after the server built
## the map has to be told the packs that are out.
func _test_view_feel_and_packs_reach_the_client() -> void:
	_section("the server's mp_vm_* and the map's packs reach a client")
	var a: Dictionary = _clients["A"]
	var a_game: ArenaGame = a["game"]
	var link: DotClientLink = a["link"]
	var held := link.replicated_cvar("mp_vm_sway", "")
	_check(held != "" and is_equal_approx(a_game.feel_rules.sway, held.to_float()),
		"the join carried mp_vm_sway and A's view model feel is on it", "held '%s', sway %s" % [held, a_game.feel_rules.sway])

	var _set := _server.console.set_cvar("mp_vm_sway", "2.5")
	_check(await _until(func() -> bool: return is_equal_approx(a_game.feel_rules.sway, 2.5), RELIABLE_SECONDS),
		"a change of mp_vm_sway reaches A live", str(a_game.feel_rules.describe()))
	var _bob := _server.console.set_cvar("mp_vm_aim_steadiness", "0.4")
	_check(await _until(func() -> bool: return is_equal_approx(a_game.feel_rules.aim_steadiness, 0.4), RELIABLE_SECONDS),
		"and mp_vm_aim_steadiness, which the others are not", str(a_game.feel_rules.describe()))
	var _back := _server.console.set_cvar("mp_vm_sway", "1")
	var _back2 := _server.console.set_cvar("mp_vm_aim_steadiness", "0.75")

	# The harness opens A's bridge after the join, so A missed the signon's packs; send them as the
	# signon does (one DROP each, from the server's bridge) and see them known, through the loss.
	var out: int = _game.drops.packs_available() if _game != null and _game.drops != null else -1
	for pack in _game.drops.packs_out():
		_module().bridge.send_event(_peer_of("A"), ArenaEvents.Kind.DROP, ArenaEvents.write_drop(
			int(pack["id"]), int(pack["kind"]), int(pack["value"]), pack["at"], pack["at"]))
	_check(out > 0 and await _until(func() -> bool: return a_game.drops.known_count() >= out, RELIABLE_SECONDS),
		"A was told every pack that is out (%d)" % out, "A knows %d" % a_game.drops.known_count())
	_done()


func _connect_everyone() -> bool:
	_section("two clients connect, A through the relay at %s" % WINDOWS[0][0])

	var a := await _connect_client("A", _relay.port())
	_clients["A"] = a
	if not _check(a.get("bridge") != null and int(a["session"]) != 0,
			"A connects over ENet through the relay, and is told who it is",
			str(a.get("error", ""))):
		_done()
		return false

	_check((a["link"] as DotClientLink).transport_used == "enet", "on ENet, not WebSocket",
		(a["link"] as DotClientLink).transport_used)

	print("    A's ENet packet throttle: %d/32" % _throttle_of("A"))

	# [b]The first seconds of a connection, which is where the clock had nothing to go on.[/b]
	# A plays from here, before B has even connected. Its round trip used to come from the
	# link's heartbeat, which is -1 until the first one comes back -- two seconds at best,
	# eight in one run -- and until then the clock left the flight time out of its lead
	# and the commands arrived after their ticks. Half a second for the first ones to cross.
	_driving = true
	await _until(func() -> bool: return false, 0.5)
	var first_buffer := _module().net.input_buffer_for(_peer_of("A"))
	var first_starved := first_buffer.starved_count
	var first_late := first_buffer.late_count
	var first_tick := _game.current_tick()
	await _until(func() -> bool: return false, FIRST_SECONDS)
	var first_ticks := _game.current_tick() - first_tick
	var first_in_time := 1.0 - float(first_buffer.starved_count - first_starved) / float(maxi(1, first_ticks))
	_check(first_in_time >= 0.95,
		"in A's first %d seconds the server had its command for %.1f%% of %d ticks, %d late" % [
			int(FIRST_SECONDS), first_in_time * 100.0, first_ticks, first_buffer.late_count - first_late],
		"its clock's round trip %d ms" % int((a["net"] as DotNetManager).clock.rtt_ms()))

	var a_game: ArenaGame = a["game"]
	a_game.player_added.connect(func(p: ArenaPlayer) -> void: _a_saw_added.append(p.player_id))
	(a["bridge"] as ArenaNetBridge).notice_received.connect(func(text: String) -> void:
		if text.begins_with("seq-"):
			_got_notices.append(text)
	)
	(a["bridge"] as ArenaNetBridge).kill_received.connect(func(info: Dictionary) -> void:
		_got_kills.append("%d>%d" % [int(info["killer_id"]), int(info["victim_id"])])
	)
	(a["link"] as DotClientLink).chat_received.connect(func(payload: Dictionary) -> void:
		# dot-server's own line carries `text`; one routed through dot-chat carries `m`.
		var text := str(payload.get("text", payload.get("m", "")))
		if text.begins_with("chat-"):
			_got_chat.append(text)
		elif text.contains("a-says-"):
			# dot-chat puts the speaker in front of a player's line.
			_got_a_chat.append(text.substr(text.find("a-says-")))
		elif _verbose:
			print("    (A got chat %s)" % payload)
	)

	(a["net"] as DotNetManager).snapshot_applied.connect(func(tick: int) -> void:
		if _verbose and not _w.is_empty():
			_w["down_ticks"] = _w.get("down_ticks", []) + [_game.current_tick() - tick]
	)

	var b := await _connect_client("B", _server.config.effective_enet_port())
	_clients["B"] = b
	if not _check(b.get("bridge") != null and int(b["session"]) != 0,
			"B connects straight to the server's UDP port", str(b.get("error", ""))):
		_done()
		return false

	# The dummy the kill feed is about, added on the server alone.
	var dummy := _game.add_player(DUMMY_ID, "Dummy")
	_check(dummy.ok, "the server seats a dummy to slay", str(dummy.error))
	_game.player_killed.connect(func(entry: DotKillFeed.Entry) -> void:
		var killer := int(entry.killer_key) if String(entry.killer_key).is_valid_int() else 0
		var victim := int(entry.victim_key) if String(entry.victim_key).is_valid_int() else 0
		_sent_kills.append("%d>%d" % [killer, victim])
	)

	var b_session := int(b["session"])
	var seen := await _until(func() -> bool: return a_game.player_for(b_session) != null, 10.0)
	_check(seen and _a_saw_added.count(b_session) == 1,
		"A is told B joined, exactly once, through the loss",
		"added %s" % [_a_saw_added])

	_done()
	return true
