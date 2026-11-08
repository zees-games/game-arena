extends "scale128.gd"

## Long server-tick profile of a bot match (default: cp-orange-x3, 32 bots, tdm, 66 Hz) for the
## 16v16 lag study. scale128's server, plus: the preconditions a valid run needs, checked and
## printed (LPCHECK: dot-sim loaded, native sight scan and native motor in use, the map's PVS
## attached, every bot in the match and alive), one row per tick (LPT: tick gap, script half,
## physics frame, process frame, the main ArenaFrameProbe sections) and one per second (LPS:
## nodes, orphans, physics monitors, alive). tools/lag_profile.py turns the log into the
## percentiles, the ranked sections and the spike periods.
## godot --headless --path . res://tools/lag_profile.tscn -- --perf on --seconds 180

const ArenaBspMap := preload("../maps/arena_bsp_map.gd")

## Per-tick sections; nested: srv_net holds srv_bots and srv_game, srv_game holds tick_*.
const COLS: Array[StringName] = [&"srv_net", &"srv_bots", &"srv_game", &"srv_hits", &"tick_players",
	&"p_controller", &"p_weapons", &"p_mechanics", &"p_hulls", &"tick_shots", &"tick_drops", &"tick_world",
	&"tick_rest", &"bot_brain", &"bot_refresh", &"bot_after", &"bot_los", &"bot_route"]

var _perf := "on"
var _prev_sum := {}
var _last_start := 0
var _gap_us := 0
var _tick_i := 0


func _ready() -> void:
	# A scene run on an offload box has no .godot/extension_list.cfg, so dot-sim is loaded by hand.
	if not ClassDB.class_exists(&"DotSimFpsBody") and FileAccess.file_exists("res://addons/dot_sim/dot_sim.gdextension"):
		var st := GDExtensionManager.load_extension("res://addons/dot_sim/dot_sim.gdextension")
		print("LPCHECK dot_sim load_extension status=%d" % st)
	_map = "cp-orange-x3"
	_bots = 32
	_mode = "tdm"
	_seconds = 180.0
	_settle = 8.0
	var args := OS.get_cmdline_user_args()
	var i := args.find("--perf")
	if i >= 0 and i + 1 < args.size():
		_perf = args[i + 1]
	# on: every perf feature; off: all of them off; nomotor: on but the motor queries in script.
	var on := _perf == "on" or _perf == "nomotor"
	_skip_idle = int(on)
	_visibility = int(on)
	_sim_codec = int(on)
	_tiers = int(on)
	DotBotWorld.native_enabled = on
	DotFpsPhysicsBody.native_enabled = _perf == "on"
	super._ready()


func _sentinel(is_start: bool) -> void:
	if not _recording:
		return
	var now := Time.get_ticks_usec()
	if is_start:
		_gap_us = now - _last_start if _last_start > 0 else 0
		_last_start = now
	super._sentinel(is_start)
	if is_start:
		return
	var row := PackedStringArray([str(_tick_i), str((now - _t_start) / 1000), "%.2f" % (_gap_us / 1000.0),
		"%.2f" % (_script_us[-1] / 1000.0), "%.2f" % _phys_ms[-1],
		"%.2f" % (Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)])
	for k in COLS:
		var r = ArenaFrameProbe._sections.get(k)
		var total: int = r[0] if r != null else 0
		row.append("%.2f" % ((total - int(_prev_sum.get(k, 0))) / 1000.0))
		_prev_sum[k] = total
	_tick_i += 1
	print("LPT ", ",".join(row))


func _begin_record() -> void:
	super._begin_record()
	_prev_sum.clear()
	_tick_i = 0
	_last_start = 0
	print("LPT_COLS tick,t_ms,gap_ms,script_ms,phys_ms,proc_ms,", ",".join(COLS))


## The boot map's PVS, attached here because the module only attaches it on a map change.
func _attach_pvs(module: Object) -> bool:
	var map = module.game.map
	if map == null or not map.has_method(&"is_imported") or not map.is_imported():
		return false
	var prefix: String = ArenaBspMap.world_prefix(String(map.id), String(map.manifest_path).get_base_dir())
	var got: DotResult = DotMapBspMesh.load_prefix(prefix) if not prefix.is_empty() else null
	var mesh: Object = got.value if got != null and got.ok else null
	print("LPCHECK pvs prefix=%s mesh=%s" % [prefix, mesh != null])
	return bool((DotGameNetcode as GDScript).call(&"attach_visibility", module.net, mesh))


func _native_bodies(game: Object) -> Array:
	var used := 0
	var seen := 0
	for p in game.players():
		var ctl = p.get("controller")
		var body = ctl.get("flat_body") if ctl != null else null
		var inner = body.get("inner") if body != null and "inner" in body else body
		if inner is DotFpsPhysicsBody:
			seen += 1
			used += int(inner.get("_native") != null)
	return [seen, used]


func _serve() -> void:
	var data := "user://scale128_server"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))
	Engine.physics_ticks_per_second = _tick
	var g := ArenaGame.new()
	g.name = "Arena"
	g.tick_rate = _tick
	g.score_limit = 0
	g.time_limit_sec = 0.0
	g.warmup_sec = 0.0
	g.headless = true
	g.mode_id = StringName(_mode)
	g.register_service = true
	add_child(g)
	var map := ArenaMap.by_id(StringName(_map))
	if map == null:
		printerr("LPCHECK FAIL map %s not found" % _map)
		get_tree().quit(2)
		return
	var _set := g.setup(map)
	var config := DotServerConfig.new()
	config.hostname = "lagprof"
	config.port = _port
	config.tickrate = _tick
	config.max_players = 256
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % data
	config.bans_path = "%s/bans.json" % data
	config.audit_log_path = "%s/audit.jsonl" % data
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "error"
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)
	var booted: DotResult = await server.boot()
	if not booted.ok:
		printerr("lag_profile: ", booted.error)
		get_tree().quit(1)
		return
	var loaded: DotResult = await server.modules.load_module("res://game/arena_module.gd")
	if not loaded.ok:
		printerr("lag_profile: ", loaded.error)
		get_tree().quit(1)
		return
	var module := server.modules.get_module("arena") as ArenaModule
	_apply_switches(module.net)
	var pvs := _attach_pvs(module) if _visibility == 1 else false
	var quota: DotBotQuota = module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("fixed")
		quota.quota_cvar.force_set(str(_bots))
		quota.empty_cvar.force_set("1")
	var t_add := Time.get_ticks_usec()
	while module.bridge.bot_ids().size() < _bots and (Time.get_ticks_usec() - t_add) < 60000000:
		await get_tree().create_timer(0.5).timeout
	var made := module.bridge.bot_ids().size()
	var game: ArenaGame = module.game
	# A bot-only match stays IDLE (no respawns, no combat) and bots that joined before the
	# spawns were read stand at the origin: start the match and respawn everyone.
	if game.match_node != null and game.match_node.state == DotMatch.State.IDLE:
		game.start(int(game.get("_tick")))
	game.call("_respawn_for_new_map")
	await get_tree().create_timer(_settle).timeout
	var net: DotNetManager = module.net
	var sw := _switch_state(net)
	var teams := {}
	var alive0 := 0
	for p in game.players():
		teams[str(p.get("team"))] = int(teams.get(str(p.get("team")), 0)) + 1
		alive0 += int(p.is_alive())
	var nb := _native_bodies(game)
	var checks := {
		"perf": _perf, "dot_sim_loaded": ClassDB.class_exists(&"DotSimFpsBody"),
		"native_scan": DotBotWorld.native_available(), "motor_native_available": DotFpsPhysicsBody.native_available(),
		"motor_bodies": nb[0], "motor_bodies_native": nb[1], "pvs_attached": pvs,
		"visibility_ready": sw["visibility_ready"], "bots_made": made, "players": game.players().size(),
		"alive_at_start": alive0, "teams": teams, "match_state": game.match_node.state if game.match_node != null else -1,
		"physics_engine": ProjectSettings.get_setting("physics/3d/physics_engine", ""),
		"switches": sw,
	}
	var want_native := _perf == "on"
	var ok: bool = made >= _bots and alive0 >= _bots - 1 and checks["native_scan"] == (_perf != "off") \
		and (nb[1] == nb[0] if want_native else nb[1] == 0) and nb[0] > 0 \
		and (sw["visibility_ready"] == true if _visibility == 1 else true)
	checks["valid"] = ok
	print("LPCHECK ", JSON.stringify(checks))
	var before: Dictionary = net.perf_counters()
	_begin_record()
	_tally_on(game)
	var alive_min := 999
	var alive_sum := 0
	var samples := 0
	var t_end := Time.get_ticks_usec() + int(_seconds * 1.0e6)
	while Time.get_ticks_usec() < t_end:
		await get_tree().create_timer(1.0).timeout
		var alive := 0
		for p in game.players():
			alive += int(p.is_alive())
		alive_min = mini(alive_min, alive)
		alive_sum += alive
		samples += 1
		print("LPS %d,%d,%d,%d,%d,%d,%d,%.1f,%d" % [samples, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)), int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)), int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
			int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)), _rss_mb(), alive])
	_recording = false
	var after: Dictionary = net.perf_counters()
	var nt := maxi(1, int(after[&"server_ticks"]) - int(before[&"server_ticks"]))
	nb = _native_bodies(game)
	_report({
		"perf": _perf, "valid": ok, "alive_min": alive_min, "alive_mean": snappedf(float(alive_sum) / maxi(1, samples), 0.1),
		"bots_made": made, "players": game.players().size(), "motor_bodies_native_end": nb[1], "motor_bodies_end": nb[0],
		"net_sim_ms_per_tick": snappedf((int(after[&"server_sim_usec"]) - int(before[&"server_sim_usec"])) / 1000.0 / nt, 0.001),
		"net_send_ms_per_tick": snappedf((int(after[&"server_send_usec"]) - int(before[&"server_send_usec"])) / 1000.0 / nt, 0.001),
		"net_ticks": nt, "switches": _switch_state(net),
	})
	get_tree().quit()
