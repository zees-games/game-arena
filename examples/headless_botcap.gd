extends "arena_server_suite.gd"

const ArenaNetBridge := preload("../game/arena_net_bridge.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaTestPorts := preload("test_ports.gd")

## `bot_quota N` with `sv_maxplayers 0` (unlimited) spawns exactly N bots, for N past every number a cap might hide at (16, 32, 64, 255, 256). No silent clamp.
## Run: [code]godot --headless --path . res://examples/headless_botcap.tscn[/code]

var PORT := ArenaTestPorts.free_port()
const SERVER_DIR := "user://arena_botcap"
const TICK_RATE := 64

const SECTIONS := 1
const CHECKS := 17






func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: bot_quota spawns exactly N bots")
	DotPaths.remove_tree(SERVER_DIR)
	if await _build():
		await _test_counts()
	_teardown()
	DotPaths.remove_tree(SERVER_DIR)
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _build() -> bool:
	if not await _boot_server("arena botcap", PORT, SERVER_DIR, TICK_RATE):
		return false

	_step(2)
	return true


func _step(n: int) -> void:
	for i in n:
		_tick += 1
		_module.bridge.server_tick(_tick)


func _test_counts() -> void:
	_section("bot_quota is not clamped")
	_cmd("sv_maxplayers 0")
	_cmd("bot_quota_mode fixed")
	_check(_server.config.max_players == 0, "sv_maxplayers 0 is unlimited")
	for n in [16, 17, 32, 64, 128, 256, 300]:
		_cmd("bot_quota %d" % n)
		_module._keep_bots()
		_step(2)
		var bots := _module.bridge.bot_ids()
		_check(bots.size() == n, "bot_quota %d spawns %d bots" % [n, n], "%d bots" % bots.size())
		_check(_game.players().size() == n, "and the game holds %d players" % n, "%d" % _game.players().size())
	_cmd("bot_quota 0")
	_module._keep_bots()
	_check(_module.bridge.bot_ids().is_empty(), "bot_quota 0 removes them all")
	_done()
