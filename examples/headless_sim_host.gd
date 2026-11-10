extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaSimHost := preload("../game/arena_sim_host.gd")

## `--sim_host 1`: the solo game runs as a loopback server process and this client joins it, so the
## simulation is off the render thread. Off unless asked for; asked for, the client is a connected one
## (no authority here), sees the bots, lives, and the server process ends with the client.
## Run: [code]godot --headless --path . res://examples/headless_sim_host.tscn[/code]

const BOTS := 4

var _checks := 0
var _failed := 0
var _client: Node = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("headless_sim_host")
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


func _players() -> int:
	var game: Object = _client.get("game")
	return (game.call("players") as Array).size() if game != null else 0


func _run() -> void:
	print("game-arena: the solo game hosted beside the client")
	_check(not ArenaSimHost.wanted(), "off unless the launch asks for it")

	ArenaSimHost.forced = 1
	ArenaSimHost.ask_map = "dm_box"
	_check(ArenaSimHost.wanted(), "a tool can ask for it")
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	# What a bench sets: the host is joined all the same.
	_client.set("force_offline", true)
	_client.set("offline_bots", BOTS)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	var built := await _until(func() -> bool: return _client.get("game") != null, 90.0)
	_check(built, "the client builds once the server answered")
	if not built:
		_end()
		return
	var host: ArenaSimHost = _client.get("_sim_host")
	_check(host != null and host.up, "the client joined its own server")
	if host == null:
		_end()
		return
	var pid: int = host.get("_pid")
	var game: Object = _client.get("game")
	_check(not bool(game.get("is_authority")), "this process is not the authority")
	_check(not bool(_client.get("_offline")), "the client runs the connected path")
	var seen := await _until(func() -> bool: return _players() >= BOTS + 1, 40.0)
	_check(seen, "the client sees itself and the bots", "%d of %d" % [_players(), BOTS + 1])
	var alive := await _until(func() -> bool:
		var p: Object = _client.get("player")
		return p != null and bool(p.call("is_alive")), 40.0)
	_check(alive, "the local player is alive on the server")
	var net: Object = _client.get("net")
	var synced := await _until(func() -> bool: return net != null and net.get("clock") != null and bool(net.get("clock").call("is_synced")), 20.0)
	_check(synced, "the clock is synced to the server")
	_check(OS.is_process_running(pid), "the server process is running")

	_client.queue_free()
	_client = null
	var gone := await _until(func() -> bool: return not OS.is_process_running(pid), 20.0)
	_check(gone, "the server process ends with the client")
	_end()


func _end() -> void:
	ArenaSimHost.forced = -1
	ArenaSimHost.ask_map = ""
	if _client != null:
		_client.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	print("headless_sim_host: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
