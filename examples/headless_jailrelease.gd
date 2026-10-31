extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")

## A surf map's jail through the global importer: a pad beside the jail is a release to the top of the
## spawn, the cell's glass is one-way, and the use key on the button swings the jail doors.
##
## [codeblock]
## godot --headless --path . res://examples/headless_jailrelease.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_CHECKS := 13
const MAP := &"surf_10x_reloaded_fixed"
const BUTTON := 271
const DOOR := 308

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


func _volume(manifest: Dictionary, entity: int) -> Dictionary:
	for v: Variant in manifest["volumes"]:
		if int((v as Dictionary).get("entity", -1)) == entity:
			return v
	return {}


func _at(manifest: Dictionary, name: String) -> Vector3:
	var a: Array = manifest["destinations"][name]["at"]
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _door_pose(world: DotMapWorld) -> Transform3D:
	var e: DotMapEntity = world.io.entity_of(DOOR)
	return e.node.global_transform if e.node != null else Transform3D.IDENTITY


func _run() -> void:
	var map := ArenaMap.imported(MAP)
	if map == null:
		print("  skip  %s is not linked (arena-surf-dm-maps)" % MAP)
		get_tree().quit(0)
		return
	var prefix := ArenaBspMap.world_prefix(String(MAP), map.manifest_path.get_base_dir())
	var got: DotResult = DotMapBspMesh.load_prefix(prefix)
	_check(got.ok, "the converted world reads", str(got.error))
	if not got.ok:
		get_tree().quit(1)
		return
	var manifest: Dictionary = (got.value as DotMapBspMesh).manifest

	var cell := DotMapOneWayGlass.cell_of(manifest)
	_check(not cell.is_empty(), "the jail cell is found by shape")
	var centre: Vector3 = cell.get("centre", Vector3.ZERO)
	_check(centre.distance_to(_at(manifest, "jail1")) < 3.0, "and it is where the falls land", str(centre))

	var pad := _volume(manifest, 60)
	var pad_to := _at(manifest, str(pad.get("target", "")))
	_check(str(pad.get("retargeted_from", "")) == "outside_jail", "the pad by the ice post was aimed at the jail's doorstep")
	_check(pad_to.y > centre.y + 10.0, "and now sends a player to the top of the spawn", str(pad["target"]))
	var exit := _volume(manifest, 94)
	_check(str(exit.get("target", "")) == "jailbreak" and not exit.has("retargeted_from"), "while the jail's own exit still opens onto its doorstep")
	var falls := 0
	for v: Variant in manifest["volumes"]:
		falls += 1 if str((v as Dictionary).get("target", "")) == "jail1" else 0
	_check(falls >= 3, "and the falls still land in the cell", str(falls))

	var hook := DotMapOneWayGlass.hook(centre, float(cell["radius"]))
	var made: Variant = hook.call({"glass": "glass", "tint": []})
	_check(made is ShaderMaterial, "clear glass takes the one-way material")
	_check(hook.call({"glass": "bars", "tint": []}) == null, "while bars keep their own look")
	_check(DotMapOneWayGlass.sees_solid(centre, centre, float(cell["radius"])) and not DotMapOneWayGlass.sees_solid(centre + Vector3(0, 0, 30), centre, float(cell["radius"])), "the glass is solid from inside the cell and clear from outside")

	var game := ArenaGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch()
	add_child(game)
	var ready := game.setup(map)
	_check(ready.ok, "a game sets up on the map", str(ready.error))
	game.start(0)
	var _a := game.add_player(21, "A")
	game.tick({})
	var mio = game.map_io
	if mio == null:
		_check(false, "the map builds a mover world")
		get_tree().quit(1)
		return
	var world: DotMapWorld = mio.world
	var before := _door_pose(world)
	var button: DotMapEntity = world.io.entity_of(BUTTON)
	var player := game.player_for(21)
	var eye: Vector3 = button.origin(world.io) + Vector3(0.0, 1.0, 0.0)
	player.controller.state.position = eye - Vector3(0.0, 1.6, 0.0)
	var pressed: bool = mio.press_for(_AimAt.new(eye, button.origin(world.io) - eye), 21)
	for _k in TICK_RATE * 2:
		game.tick({})
		await get_tree().physics_frame
	var after := _door_pose(world)
	_check(pressed, "the use key presses the jail button")
	_check(not after.is_equal_approx(before), "and the jail door swings")

	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


## Stands in for a player looking along a direction.
class _AimAt:
	var at: Vector3
	var dir: Vector3

	func _init(pos: Vector3, look: Vector3) -> void:
		at = pos
		dir = look.normalized()

	func muzzle_position() -> Vector3:
		return at

	func aim_direction() -> Vector3:
		return dir
