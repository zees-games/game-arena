extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")

## Converted-map buttons and doors through the whole game: the use key presses the button a player looks at,
## the door moves on the host and on a mirror fed the host's state, and a map with no movers pays nothing.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapuse.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_CHECKS := 13
const MAP := &"surf_forbidden_ways_2nd"

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


func _fps(pitch: float) -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.pitch = pitch
	return c


func _use(down: bool) -> DotWeaponCommand:
	var c := DotWeaponCommand.new()
	c.pitch = -89.0
	c.set_button(DotWeaponCommand.BUTTON_USE, down)
	return c


## Ticks the game with the player held at [param at], looking straight down, the use key as given.
func _step(game: ArenaGame, id: int, at: Vector3, down: bool, ticks: int) -> void:
	for _k in ticks:
		var p := game.player_for(id)
		p.controller.state.position = at
		p.controller.state.pitch = -89.0
		game.tick({id: [_fps(-89.0), _use(down)]})
		p.controller.state.position = at
		if p.view != null:
			p.view.global_position = at + Vector3(0.0, 1.6, 0.0)
		await get_tree().physics_frame


func _door_y(world: DotMapWorld) -> float:
	var e: DotMapEntity = world.io.entity_of(293)
	return e.node.global_position.y if e.node != null else NAN


func _run() -> void:
	var game := ArenaGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch()
	add_child(game)
	var map := ArenaMap.imported(MAP)
	if map == null:
		print("  skip  %s is not linked (arena-surf-dm-maps)" % MAP)
		get_tree().quit(0)
		return
	var ready := game.setup(map)
	_check(ready.ok, "a game sets up", str(ready.error))
	game.start(0)
	var _a := game.add_player(21, "A")
	game.tick({})
	var mio = game.map_io
	_check(mio != null, "a map with movers builds a mover world")
	if mio == null:
		get_tree().quit(1)
		return
	var world: DotMapWorld = mio.world
	var button_at: Vector3 = world.io.entity_of(39).origin(world.io)
	var stand := button_at + Vector3(0.0, 1.0, 0.0) - Vector3(0.0, 1.6, 0.0)

	# A mirror: a second game that is a client, fed what the host sends.
	var mirror_game := ArenaGame.new()
	mirror_game.name = "M"
	mirror_game.tick_rate = TICK_RATE
	mirror_game.headless = true
	mirror_game.register_service = false
	mirror_game.is_authority = false
	mirror_game.mode = ArenaMode.team_deathmatch()
	add_child(mirror_game)
	var _r := mirror_game.setup(ArenaMap.imported(MAP))
	var mirror = mirror_game.map_io
	_check(mirror != null and not mirror.is_authority, "a client game builds the mirror, without authority")
	var sent := [0]
	mio.transport.raw_send = func(_peer, payload) -> void:
		sent[0] += 1
		mirror.receive(payload)
	mio.add_peer(7)
	game.tick({})
	await get_tree().physics_frame
	_check(sent[0] > 0, "a new peer is sent the mover snapshot", str(sent[0]))

	await _step(game, 21, stand, false, 2)
	var player := game.player_for(21)
	var info: Dictionary = mio.aim_of(player)
	_check(not info.is_empty() and bool(info["in_range"]) and info["label"] != "", "looking down at the button shows the prompt", str(info.get("label", "-")))
	var start_y := _door_y(world)
	await _step(game, 21, stand, true, 10)
	await _step(game, 21, stand, false, 2)
	await _step(game, 21, stand, false, TICK_RATE)
	var opened := _door_y(world)
	_check(opened - start_y > 1.0, "E on the button opens the jail door on the host, once", "%.2f -> %.2f" % [start_y, opened])
	await get_tree().physics_frame
	var mirrored := _door_y(mirror.world)
	_check(absf(mirrored - opened) < 0.3, "and the client's mirror door is there too", "host %.2f, mirror %.2f" % [opened, mirrored])

	var sky_info: Dictionary = mio.aim_from(stand + Vector3(0.0, 1.6, 0.0), Vector3(0.0, 1.0, 0.0))
	_check(sky_info.is_empty(), "looking away shows no prompt, so a pickup's prompt may show")
	_check(not mio.press_for(_AimAway.new(stand + Vector3(0.0, 1.6, 0.0)), 21), "and the key is not spent on nothing, so a dropped weapon can take it")

	var live: Array = mio.bodies()
	_check(live.size() == 1 and int(live[0]["id"]) == 21 and (live[0]["position"] as Vector3).is_equal_approx(player.controller.state.position), "the host hands its living players to the movers as bodies")
	var before: Vector3 = player.controller.state.position
	world.io.carry_body(21, Vector3(0.0, 2.0, 0.0), null)
	_check(absf(player.controller.state.position.y - before.y - 2.0 / TICK_RATE) < 0.0001, "a mover's carry displaces the player by velocity over the tick")
	var hp: float = player.health.health
	world.io.damage_fn.call(21, 10.0, "crush", null)
	_check(player.health.health < hp, "and a crush is world damage through dot-combat", "%s -> %s" % [hp, player.health.health])

	var plain := ArenaGame.new()
	plain.name = "P"
	plain.tick_rate = TICK_RATE
	plain.headless = true
	plain.register_service = false
	plain.mode = ArenaMode.team_deathmatch()
	add_child(plain)
	var _s := plain.setup(ArenaMap.dm_atrium())
	_check(plain.map_io == null, "a map with no movers builds no mover world and costs nothing")

	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


## Stands in for a player who looks along +Y.
class _AimAway:
	var at: Vector3

	func _init(pos: Vector3) -> void:
		at = pos

	func muzzle_position() -> Vector3:
		return at

	func aim_direction() -> Vector3:
		return Vector3.UP
