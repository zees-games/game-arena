extends DotGameCheckSuite

const ArenaBots := preload("../game/arena_bots.gd")
const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPlayerNet := preload("../game/arena_player_net.gd")
const ArenaKillViewServer := preload("../game/arena_killview_server.gd")

## A bot's replicated copy is pulled only on the ticks a snapshot is written (`ArenaPlayerNet.skip_idle_pull`).
## The same bots on dm_box play the same match through the server's bridge with it off and on: every bot's
## position, view, health and commands every tick, and every replicated property of every bot on every
## snapshot tick, are identical. Only what is sent is read from those properties, so that is the whole claim.
## The kill view asks for an eye only on the ticks its ring keeps one (`ArenaKillViewServer.Due.ask_due_only`):
## with it off and on, every bot's kill view clip, read every second, is identical too.

const TICK_RATE := 66
const SNAPSHOT_RATE := 33
const BOTS := 16
const SECONDS := 12.0

const SECTIONS := 1
const CHECKS := 6

var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: a bot's idle pulls are skipped and nothing sent changes")
	_section("the same match and the same snapshots, every tick pulled or not")
	var was: bool = ArenaPlayerNet.skip_idle_pull
	var was_due: bool = ArenaKillViewServer.Due.ask_due_only
	ArenaPlayerNet.skip_idle_pull = false
	ArenaKillViewServer.Due.ask_due_only = false
	var every := await _play()
	ArenaPlayerNet.skip_idle_pull = true
	ArenaKillViewServer.Due.ask_due_only = true
	var skipped := await _play()
	ArenaPlayerNet.skip_idle_pull = was
	ArenaKillViewServer.Due.ask_due_only = was_due
	_check(every[0].size() > 100 and every[1].size() > 100, "the match was played (%d ticks, %d snapshots)" % [every[0].size(), every[1].size()])
	_check(every[0] == skipped[0], "the simulation is identical, tick for tick", "first differing tick %d" % _first_diff(every[0], skipped[0]))
	_check(every[1] == skipped[1], "every bot's replicated properties are identical on every snapshot tick", "first differing snapshot %d" % _first_diff(every[1], skipped[1]))
	_check(int(every[4]) > 50 and every[3] == skipped[3], "every bot's kill view clip is identical, asked every tick or only when due (%d clips)" % int(every[4]), "first differing read %d" % _first_diff(every[3], skipped[3]))
	_check(int(every[2]) == 0, "pulling every tick leaves no copy behind between snapshots", "%d stale" % int(every[2]))
	_check(int(skipped[2]) > 50, "and the skip really skipped: copies behind the sim between snapshots", "%d stale" % int(skipped[2]))
	_done()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _first_diff(a: PackedStringArray, b: PackedStringArray) -> int:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return i
	return -1 if a.size() == b.size() else mini(a.size(), b.size())


## One match through a server bridge: [sim digests per tick, property digests per snapshot, stale copies seen between
## snapshots, kill view clip digests per second, clips read].
func _play() -> Array:
	var game := ArenaGame.new()
	game.name = "Arena_%s" % ("skip" if ArenaPlayerNet.skip_idle_pull else "every")
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var _setup := game.setup(ArenaMap.dm_box())
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0
	game.start(0)

	var net := DotNetManager.new()
	net.name = "Net_%s" % game.name
	net.is_server = true
	net.service_scope = &"server"
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""
	net.config = DotNetConfig.new()
	net.config.tick_rate = TICK_RATE
	net.config.snapshot_rate = SNAPSHOT_RATE
	net.config.world_extent = ArenaGame.NET_WORLD_EXTENT
	add_child(net)
	var _net_ok := net.setup()
	var bridge := ArenaNetBridge.new()
	bridge.name = "Bridge_%s" % game.name
	add_child(bridge)
	var _attached := bridge.attach(game, net)
	net.messages.seal()
	net.start()
	for i in BOTS:
		var _id := bridge.add_bot("Bot%d" % i)
	await get_tree().process_frame

	var sims := PackedStringArray()
	var snaps := PackedStringArray()
	var stale := 0
	var clips := PackedStringArray()
	var clip_count := 0
	var ids := bridge.bot_ids()
	for tick_index in int(SECONDS * TICK_RATE):
		var tick := game.current_tick() + 1
		bridge.server_tick(tick)
		var sim := PackedStringArray()
		var props := PackedStringArray()
		var snapshot: bool = int(net.get(&"_ticks_since_snapshot")) == 0
		for id in ids:
			var b: ArenaPlayerNet = bridge.behaviour_for(id)
			if b == null or b.player == null:
				sim.append("-")
				continue
			var state: DotFpsState = b.player.controller.state
			sim.append("%d:%.5f,%.5f,%.5f,%.5f,%.5f,%.3f" % [id, state.position.x, state.position.y, state.position.z, state.yaw, state.pitch, b.player.health.health])
			if snapshot:
				for declaration: DotNetVar in b.net_vars:
					props.append(var_to_str(b.get(declaration.property)))
				props.append(str(b.identity.always_relevant))
			elif b.net_position != state.position:
				stale += 1
		sims.append(" ".join(sim).md5_text())
		if tick_index % TICK_RATE == TICK_RATE - 1 and bridge.killview != null:
			var now := float(game.current_tick()) / float(game.tick_rate)
			var clip := PackedStringArray()
			for id in ids:
				var made := bridge.killview.ring.clip_for(id, now - 0.5)
				clip.append(var_to_str(made.value["f"]) if made.ok else "-")
				clip_count += int(made.ok)
			clips.append(" ".join(clip).md5_text())
		if snapshot:
			snaps.append(" ".join(props).md5_text())
		# One physics step every 8 ticks, never "a frame" (headless_botthreads).
		if tick_index % 8 == 0:
			await get_tree().physics_frame
	for node: Node in [bridge, net, game]:
		remove_child(node)
		node.queue_free()
	await get_tree().process_frame
	return [sims, snaps, stale, clips, clip_count]
