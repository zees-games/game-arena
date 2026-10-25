extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaPlayer := preload("../game/arena_player.gd")

## The dedicated arena server of `tools/netchaos.sh`: dual-stack on all interfaces ("*"), no bots,
## one `TRUTH` line a second, and on the `stop` file in `--data` it writes `truth.json` (every
## player's final position, the net totals, the worst frame) and quits.
##
## godot --headless --path . res://tools/netchaos_server.tscn -- --port 27210 --data /tmp/x [--map dm_box]

var _port := 27210
var _data := ""
var _map := "dm_box"
var _module: ArenaModule = null
var _game: ArenaGame = null
var _next_truth := 1.0
var _solid := ""
var _clock := 0.0
var _worst_frame := 0.0
var _frames := 0
var _snap := {}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--port": _port = int(args[i + 1])
			"--data": _data = args[i + 1]
			"--map": _map = args[i + 1]
			"--solid": _solid = args[i + 1]
	name = "Netchaos"  # RPC paths must match the client's root name
	DotLog.set_level(DotLog.Level.WARN)
	var _scratch := ArenaPresentation.use_scratch_settings("netchaos_server")
	_boot.call_deferred()


func _boot() -> void:
	DirAccess.make_dir_recursive_absolute(_data)
	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = 60
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.warmup_sec = 0.0
	_game.headless = true
	_game.register_service = true
	add_child(_game)
	var map := ArenaMap.by_id(StringName(_map))
	var _set := _game.setup(map if map != null else ArenaMap.dm_box())
	var config := DotServerConfig.new()
	config.hostname = "netchaos"
	config.port = _port
	config.bind_address = "*"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % _data
	config.bans_path = "%s/bans.json" % _data
	config.audit_log_path = "%s/audit.jsonl" % _data
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "warn"
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)
	var booted: DotResult = await server.boot()
	if not booted.ok:
		printerr("netchaos server: ", booted.error)
		get_tree().quit(1)
		return
	var loaded: DotResult = await server.modules.load_module("res://game/arena_module.gd")
	if not loaded.ok:
		printerr("netchaos server: ", loaded.error)
		get_tree().quit(1)
		return
	_module = server.modules.get_module("arena") as ArenaModule
	var quota: DotBotQuota = _module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("off")
	if _solid != "":
		# NC_SOLID=0 on netchaos.sh: players pass through each other, which attributes the
		# corrections a bump causes (the client predicts against interpolated hulls).
		var cv: DotConVar = server.console.find_cvar("mp_solidplayers")
		if cv != null:
			cv.force_set(_solid)
	_game.start(0)
	print("netchaos server: ready on udp/%d" % _port)


func _truth() -> Dictionary:
	var players := {}
	for p: ArenaPlayer in _game.players():
		var pos: Vector3 = p.controller.state.position
		players[p.display_name] = [snappedf(pos.x, 0.001), snappedf(pos.y, 0.001), snappedf(pos.z, 0.001), p.is_alive(), _net_alive(p)]
	return {"unix": Time.get_unix_time_from_system(), "players": players}


func _net_alive(p: ArenaPlayer) -> Variant:
	var b = _module.bridge.behaviour_for(p.player_id) if _module.bridge != null else null
	return b.net_alive if b != null else null


func _process(delta: float) -> void:
	if _module == null:
		return
	_clock += delta
	_frames += 1
	_worst_frame = maxf(_worst_frame, delta * 1000.0)
	if _snap.is_empty() and FileAccess.file_exists("%s/truth_at" % _data):
		var at := FileAccess.get_file_as_string("%s/truth_at" % _data).to_float()
		if at > 0.0 and Time.get_unix_time_from_system() >= at:
			_snap = _capture()
	if FileAccess.file_exists("%s/stop" % _data):
		_finish()
		return
	if _clock >= _next_truth:
		_next_truth += 1.0
		print("TRUTH ", JSON.stringify(_truth()))


## The settled world, taken at `truth_at` while the clients are still connected.
func _capture() -> Dictionary:
	var out := _truth()
	var net_d: Dictionary = _module.net.describe() if _module.net != null else {}
	out["server"] = {"seconds": _clock, "frames": _frames, "worst_frame_ms": _worst_frame,
		"peers": net_d.get("peers", -1), "stats": net_d.get("stats", {})}
	return out


func _finish() -> void:
	var out := _snap if not _snap.is_empty() else _capture()
	out["server"]["worst_frame_ms"] = _worst_frame
	var f := FileAccess.open("%s/truth.json" % _data, FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	set_process(false)
	print("netchaos server: stopped")
	get_tree().quit()
