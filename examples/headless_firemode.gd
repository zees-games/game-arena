extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaPlayerNet := preload("../game/arena_player_net.gd")

## The fire-mode key through the whole game: a press moves the held gun to its next mode, a held key moves
## it once, and the replicated `net_fire_mode` follows. Arena binds the key to N.
##
## [codeblock]
## godot --headless --path . res://examples/headless_firemode.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_CHECKS := 8

var _checks := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _step(game: ArenaGame, id: int, down: bool, ticks: int) -> void:
	for _k in ticks:
		var c := DotWeaponCommand.new()
		c.set_button(DotWeaponCommand.BUTTON_FIRE_MODE, down)
		game.tick({id: [DotFpsCommand.new(), c]})
		await get_tree().physics_frame


func _run() -> void:
	_check(
		DotInputBinding.describe_action(&"arena_fire_mode") == "N" or not InputMap.has_action(&"arena_fire_mode"),
		"the fire-mode action is N by default (or not registered in a bare game)"
	)
	var game := ArenaGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch()
	add_child(game)
	_check(game.setup(ArenaMap.dm_atrium()).ok, "a game sets up")
	game.start(0)
	var _a := game.add_player(31, "A")
	game.tick({})
	var player := game.player_for(31)
	player.give_default_loadout()
	game.tick({})

	var chosen := 0
	for s in player.arsenal.slots():
		var held = player.arsenal.weapons_in(s)
		if not held.is_empty() and held[0].def.allowed_fire_modes().size() > 1:
			chosen = s
			break
	_check(chosen != 0, "the default loadout has a gun with a selector", str(player.arsenal.slots()))
	player.hold(chosen)
	for _k in TICK_RATE:
		await _step(game, 31, false, 1)
	var slot = player.arsenal.current()
	var modes: Array = slot.def.allowed_fire_modes()
	var start: int = slot.fire_mode_index

	var net := ArenaPlayerNet.new()
	net.player = player
	net.pull()
	_check(net.net_fire_mode == start, "before the press net_fire_mode is the gun's mode", str(net.net_fire_mode))

	await _step(game, 31, true, 5)
	var after: int = player.arsenal.current().fire_mode_index
	_check(after == (start + 1) % modes.size(), "a held key moves the gun on by one mode, not one per tick", "%d -> %d" % [start, after])
	net.pull()
	_check(net.net_fire_mode == after and after != start, "and net_fire_mode follows it", str(net.net_fire_mode))
	await _step(game, 31, false, 2)
	await _step(game, 31, true, 1)
	await _step(game, 31, false, 1)
	var again: int = player.arsenal.current().fire_mode_index
	_check(again == (start + 2) % modes.size(), "a second press moves it on again", str(again))
	net.pull()
	_check(net.net_fire_mode == again, "net_fire_mode follows that too", str(net.net_fire_mode))
	net.free()

	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)
