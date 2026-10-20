extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("../game/arena_module.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

## A played online session you can look at: a dedicated arena server (this scene again with
## `--role server`, real ENet, the module's own map rotation and vote) and the real client
## (`arena.tscn`) connected to it, a pilot that runs and shoots, and a frame saved every
## `--every` seconds into `screenshots/online/`. The server ends a round fast (`--score`
## frags) and opens the map vote at `--vote-at` seconds, so round end and the ballot are on
## the frames. Needs a display: `xvfb-run -a godot --path . res://tools/play_online.tscn`.
## It asserts nothing; it prints the client's view of the match as it goes.

const PORT := 27199
const OUT := "res://screenshots/online"

var _role := "client"
var _bots := 4
var _seconds := 70.0
var _every := 4.0
var _score := 4
var _vote_at := 30.0
var _map := "dm_box"
var _server_pid := -1
var _client: Node = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--role": _role = args[i + 1]
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--every": _every = float(args[i + 1])
			"--score": _score = int(args[i + 1])
			"--vote-at": _vote_at = float(args[i + 1])
			"--map": _map = args[i + 1]
	DotLog.set_level(DotLog.Level.WARN)
	var _scratch := ArenaPresentation.use_scratch_settings("play_online_" + _role)
	if _role == "server":
		_serve.call_deferred()
	else:
		_run.call_deferred()


func _serve() -> void:
	var data := "user://play_online_server"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))
	var game := ArenaGame.new()
	game.name = "Arena"
	game.tick_rate = 60
	game.score_limit = 0
	game.time_limit_sec = 0.0
	game.warmup_sec = 0.0
	game.headless = true
	game.register_service = true
	add_child(game)
	var map := ArenaMap.by_id(StringName(_map))
	var _set := game.setup(map if map != null else ArenaMap.dm_box())
	var config := DotServerConfig.new()
	config.hostname = "play online"
	config.port = PORT
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
	config.log_level = "warn"
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)
	var booted: DotResult = await server.boot()
	if not booted.ok:
		printerr("play_online server: ", booted.error)
		get_tree().quit(1)
		return
	var loaded: DotResult = await server.modules.load_module("res://game/arena_module.gd")
	if not loaded.ok:
		printerr("play_online server: ", loaded.error)
		get_tree().quit(1)
		return
	var module := server.modules.get_module("arena") as ArenaModule
	game.start(0)
	print("play_online server: ready, vote options ", module.vote.source.choices().size() if module.vote != null else -1)
	await get_tree().create_timer(12.0).timeout
	module.game.score_limit = _score
	module.game.apply_match_limits()
	var spent := 12.0
	while spent < _vote_at:
		await get_tree().create_timer(5.0).timeout
		spent += 5.0
		print("SERVER ", " | ".join(module.game.describe_lines()).substr(0, 600))
	if module.vote != null:
		module.vote.director.rules.min_players_to_vote = 0
		var r := module.vote.director.open_vote(DotVoteClock.REASON_MANUAL)
		print("play_online server: open_vote ok=", r.ok if r != null else "null")


class Pilot extends Node:
	var _t := 0.0
	var _next := 0.0
	var _rng := RandomNumberGenerator.new()

	func _ready() -> void:
		_rng.seed = 7
		Input.action_press(&"dot_fps_forward")
		Input.action_press(&"arena_fire")

	func _process(delta: float) -> void:
		_t += delta
		var turn := InputEventMouseMotion.new()
		turn.relative = Vector2(sin(_t * 0.7) * 6.0, sin(_t * 1.3) * 1.5)
		Input.parse_input_event(turn)
		if _t < _next:
			return
		_next = _t + _rng.randf_range(0.3, 1.2)
		for a: StringName in [&"dot_fps_left", &"dot_fps_right", &"dot_fps_jump"]:
			Input.action_release(a)
		match _rng.randi_range(0, 3):
			0: Input.action_press(&"dot_fps_left")
			1: Input.action_press(&"dot_fps_right")
			2: Input.action_press(&"dot_fps_jump")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://tools/play_online.tscn", "--", "--role", "server", "--bots", str(_bots),
		"--score", str(_score), "--vote-at", str(_vote_at), "--map", _map])
	_server_pid = OS.create_process(OS.get_executable_path(), args)
	await get_tree().create_timer(8.0).timeout
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Looker"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	add_child(link)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var t := 0.0
	while not link.is_playing() and t < 30.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
	print("play_online: connected=", link.is_playing())
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	add_child(_client)
	t = 0.0
	while t < 40.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
		var pl = _client.get("player")
		var nt = _client.get("net")
		if int(t * 4) % 20 == 0:
			if pl != null and int(t) % 10 == 5: print("CLIENT ", str(_client.describe()).substr(0, 1500))
			print("  wait %.0f s: player=%s alive=%s synced=%s fps=%d" % [t, pl != null, pl != null and pl.is_alive(), nt != null and nt.clock.is_synced(), Engine.get_frames_per_second()])
		if pl != null and pl.is_alive() and nt != null and nt.clock.is_synced():
			break
	print("play_online: client ready after %.1f s" % t)
	var pilot := Pilot.new()
	add_child(pilot)
	var n := 0
	var elapsed := 0.0
	while elapsed < _seconds:
		await get_tree().create_timer(_every).timeout
		elapsed += _every
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_png(ProjectSettings.globalize_path("%s/f%03d.png" % [OUT, n]))
		n += 1
		var p = _client.get("player")
		var sb = _client.get("game").match_node.scoreboard if _client.get("game") != null else null
		var gm = _client.get("game_menu")
		print("t=%.0f alive=%s state=%s board_open=%s records=%d present=%d" % [elapsed, p.is_alive() if p != null else "no player",
			_client.get("game").match_node.state, gm.scoreboard.is_open() if gm != null else "?",
			sb.ranked().size() if sb != null else -1, sb.ranked().filter(func(r): return r.present).size() if sb != null else -1])
	link.disconnect_from_server("done")
	OS.kill(_server_pid)
	get_tree().quit(0)
