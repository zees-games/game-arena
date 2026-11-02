extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaBots := preload("../game/arena_bots.gd")

## A surf map's jail through the global importer: a pad beside the jail is a release to the top of the
## spawn, the cell's glass is one-way, and the use key on the button swings the jail doors.
##
## [codeblock]
## godot --headless --path . res://examples/headless_jailrelease.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_CHECKS := 24
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

	_check_glass_sight(game, centre)

	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


## The jail glass as a rule for gameplay: a bot inside cannot see out, a shot from inside stops at the glass, a shooter
## outside reaches in, and a camera (plain world-layer ray) is unaffected.
func _check_glass_sight(game: ArenaGame, centre: Vector3) -> void:
	var rules: DotMapGlassSight = game.glass_rules
	_check(rules.glass_mask != 0 and rules.centre.distance_to(centre) < 0.01, "the game's glass rule has the cell and the glass layer", str(rules.glass_mask))
	_check(rules.problem() == "" and rules.world_mask != 0 and rules.glass_mask & rules.world_mask == 0, "the glass has its own bit, apart from the world's", rules.problem())
	var root := game.map.collision_root
	var space := root.get_world_3d().direct_space_state
	var glass_body: StaticBody3D = null
	for child in root.find_children("*", "StaticBody3D", true, false):
		if (child as StaticBody3D).collision_layer & rules.glass_mask != 0:
			glass_body = child
	_check(glass_body != null and (glass_body.collision_layer & rules.glass_mask) == rules.glass_mask, "the glass hulls sit on their own layer")
	# The nearest window: a glass hit with open world-layer air 1.5 m inside and 5 m outside. The rule's cell is moved there
	# for the checks (the map's own cell centre is not beside a window), and restored after.
	var dir := Vector3.ZERO
	var edge := Vector3.ZERO
	var best := INF
	var tried := 0
	for body in root.find_children("*", "StaticBody3D", true, false):
		if (body as StaticBody3D).collision_layer & rules.glass_mask == 0:
			continue
		for shape_node in body.get_children():
			var sh := (shape_node as CollisionShape3D).shape as ConvexPolygonShape3D
			if sh == null:
				continue
			var c := Vector3.ZERO
			for pt in sh.points:
				c += pt
			c = (shape_node as Node3D).global_transform * (c / float(sh.points.size()))
			for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
				for sign in [-1.0, 1.0]:
					var d: Vector3 = axis * sign
					var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(c - d * 4.0, c, rules.glass_mask))
					if hit.is_empty():
						continue
					tried += 1
					var h: Vector3 = hit["position"]
					if h.distance_to(centre) >= best:
						continue
					if space.intersect_ray(PhysicsRayQueryParameters3D.create(h - d * 1.5, h - d * 0.01, 1)).is_empty() \
							and space.intersect_ray(PhysicsRayQueryParameters3D.create(h + d * 0.01, h + d * 3.5, 1)).is_empty():
						best = h.distance_to(centre)
						dir = d
						edge = h
	_check(dir != Vector3.ZERO, "a window of the glass layer with open air on both sides", "%s at %.1f, %d faces tried" % [edge, best, tried])
	if dir == Vector3.ZERO:
		return
	var origin := edge - dir * 1.5
	var real_centre := rules.centre
	rules.centre = origin
	var beyond := edge + dir * 3.0
	var far := origin + dir * (rules.radius + 4.0)
	var trace: DotTrace = game.combat.trace
	var bots := ArenaBots.world_for(game)
	_check(not bots.line_of_sight(origin, beyond), "a bot inside cannot see out through the glass")
	rules.block_sight = false
	var open := bots.line_of_sight(origin, beyond)
	rules.block_sight = true
	_check(open, "sv_glass_block_sight 0 lets it see out", "origin %s edge %s beyond %s" % [origin, edge, beyond])
	_check(not rules.blocks(space, far, edge - dir * 0.5), "a query from outside the cell is never stopped by the glass layer")
	var out_hit := trace.ray(origin, dir, 40.0)
	_check(out_hit.blocked and out_hit.distance < origin.distance_to(edge) + 0.1, "a shot from inside stops at the glass", "%.2f of %.2f" % [out_hit.distance, origin.distance_to(edge)])
	rules.block_shots = false
	var through := trace.ray(origin, dir, 40.0)
	rules.block_shots = true
	_check(not through.blocked or through.distance > origin.distance_to(edge) + 0.1, "sv_glass_block_shots 0 lets it out", "%s %.2f vs %.2f edge, mask %d" % [through.blocked, through.distance, origin.distance_to(edge), trace.collision_mask])
	var shot_in := trace.ray(far, -dir, 40.0)
	_check(not (shot_in.blocked and absf(shot_in.distance - far.distance_to(edge)) < 0.1), "a shooter outside reaches in past the glass")
	var cam := PhysicsRayQueryParameters3D.create(origin, beyond, 1)
	_check(space.intersect_ray(cam).is_empty() or (space.intersect_ray(cam)["position"] as Vector3).distance_to(edge) > 0.1, "a camera ray (world layer) is not stopped by the glass")
	rules.centre = real_centre


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
