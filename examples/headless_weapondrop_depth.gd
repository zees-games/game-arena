extends Node

## Dropped weapons at rest on a server (a plain box) and on a client (the real model), over flat floor, ramp, stairs, a crate, a bumpy trimesh floor, a wall and imported maps' spawn floors, dropped still and thrown:
## after 10 s the client's lowest mesh point is not below the surface, the drop does not jitter, and the client's box is the server's box.
## Run: [code]godot --headless --path . res://examples/headless_weapondrop_depth.tscn[/code]

const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const Wiring := preload("../game/arena_weapon_drop_wiring.gd")

const TOLERANCE := 0.02
const RUN_TICKS := 640
const JITTER_TICKS := 128
const MAPS: Array[StringName] = [&"crackhouse", &"surf_10x_reloaded_fixed"]

var _checks := 0
var _failed := 0
var _worst := {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = 64
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _box(root: Node3D, pos: Vector3, size: Vector3, tilt: float = 0.0) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	root.add_child(body)
	body.position = pos
	body.rotation.x = tilt


func _bumpy(root: Node3D) -> void:
	var n := 40
	var pts := PackedVector3Array()
	for zi in n:
		for xi in n:
			var x := (xi - n / 2) * 0.5
			var z := (zi - n / 2) * 0.5
			var h := 0.12 * sin(x * 1.3) * cos(z * 1.1)
			var h10 := 0.12 * sin((x + 0.5) * 1.3) * cos(z * 1.1)
			var h01 := 0.12 * sin(x * 1.3) * cos((z + 0.5) * 1.1)
			var h11 := 0.12 * sin((x + 0.5) * 1.3) * cos((z + 0.5) * 1.1)
			pts.append_array([Vector3(x, h, z), Vector3(x, h01, z + 0.5), Vector3(x + 0.5, h10, z),
				Vector3(x + 0.5, h10, z), Vector3(x, h01, z + 0.5), Vector3(x + 0.5, h11, z + 0.5)])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(pts)
	shape.backface_collision = true
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	root.add_child(body)


## Height of the first surface under (x, z), searching down from [param from_y].
func _ground(x: float, z: float, from_y: float) -> float:
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, from_y - 40.0, z), 1)
	var h := space.intersect_ray(q)
	return float(h["position"].y) if not h.is_empty() else NAN


## How far the deepest mesh vertex under [param node] is below the surface (negative: all clear).
func _sunk(node: Node) -> float:
	var space := get_viewport().world_3d.direct_space_state
	var worst := -INF
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and (n as MeshInstance3D).visible:
			var t := (n as MeshInstance3D).global_transform
			var faces := (n as MeshInstance3D).mesh.get_faces()
			var step := maxi(1, faces.size() / 120)
			for k in range(0, faces.size(), step):
				var w := t * faces[k]
				var q := PhysicsRayQueryParameters3D.create(w + Vector3.UP * 0.4, w + Vector3.DOWN * 0.4, 1)
				var h := space.intersect_ray(q)
				worst = maxf(worst, (float(h["position"].y) - w.y) if not h.is_empty() else -0.4)
		stack.append_array(n.get_children())
	return worst


func _box_of(body: RigidBody3D) -> Vector3:
	for c in body.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is BoxShape3D:
			return ((c as CollisionShape3D).shape as BoxShape3D).size
	return Vector3.ZERO


## One course: every weapon in [param ids] dropped at [param spots] with [param velocity], on a
## server layer and a client layer that mirrors it; reports the client's depth at 10 s.
func _course(course: String, world: Node3D, ids: Array, spots: Array, velocity: Vector3) -> void:
	var server := DotWeaponDrops.new()
	server.is_authority = true
	server.draws = false
	server.look_of = Wiring.look
	server.rules.lifetime = 0.0
	server.rules.max_count = 0
	var client := DotWeaponDrops.new()
	client.is_authority = false
	client.draws = true
	client.look_of = Wiring.look
	client.rules.lifetime = 0.0
	client.rules.max_count = 0
	world.add_child(server)
	world.add_child(client)
	server.dropped.connect(func(i: int, s: Dictionary, at: Transform3D, v: Vector3, _o: int) -> void: client.mirror_drop(i, s, at, v))
	server.settled.connect(func(i: int, at: Transform3D) -> void: client.mirror_settled(i, at))
	server.pushed.connect(func(i: int, at: Transform3D, v: Vector3, sp: Vector3) -> void: client.mirror_pushed(i, at, v, sp))
	var sent := {}
	for k in ids.size():
		var id := server.spawn({"id": ids[k], "magazine": 1, "reserve": 1}, spots[k % spots.size()], velocity, 0)
		sent[id] = ids[k]
	var trail := {}
	for t in RUN_TICKS:
		await get_tree().physics_frame
		if t >= RUN_TICKS - JITTER_TICKS:
			for id: int in sent:
				var b: RigidBody3D = client._entries[id]["body"]
				var tr: Array = trail.get(id, [b.global_position, b.global_position])
				tr[0] = (tr[0] as Vector3).min(b.global_position)
				tr[1] = (tr[1] as Vector3).max(b.global_position)
				trail[id] = tr
	var deepest := -INF
	var deepest_id := &""
	var lost := 0
	var jitter := 0.0
	var shape_gap := 0.0
	var unrested := 0
	for id: int in sent:
		var cb: RigidBody3D = client._entries[id]["body"]
		var sb: RigidBody3D = server._entries[id]["body"]
		if cb.global_position.y < -50.0:
			lost += 1
			continue
		if not bool(server._entries[id]["rest"]):
			unrested += 1
		var s := _sunk(cb)
		if s > deepest:
			deepest = s
			deepest_id = sent[id]
		jitter = maxf(jitter, ((trail[id][1] as Vector3) - (trail[id][0] as Vector3)).length())
		shape_gap = maxf(shape_gap, (_box_of(cb) - _box_of(sb)).abs().length())
	var detail := "deepest %s %.3f m" % [deepest_id, deepest]
	_worst[course] = deepest
	print("  %-22s deepest=%+.3f (%s) jitter=%.4f shape_gap=%.3f unrested=%d lost=%d" % [course, deepest, deepest_id, jitter, shape_gap, unrested, lost])
	_check(lost == 0, "%s: no drop fell out of the world" % course, str(lost))
	_check(deepest <= TOLERANCE, "%s: client mesh not below the surface at 10 s" % course, detail)
	_check(jitter <= 0.003, "%s: resting drops do not jitter" % course, "%.4f" % jitter)
	_check(shape_gap <= 0.01, "%s: client and server collision boxes agree" % course, "%.3f" % shape_gap)
	_check(unrested == 0, "%s: every drop came to rest" % course, str(unrested))
	server.queue_free()
	client.queue_free()


func _grid(origin: Vector3, count: int, cols: int = 10, pitch: float = 1.5) -> Array:
	var out := []
	for i in count:
		out.append(origin + Vector3((i % cols) * pitch, 0.0, (i / cols) * pitch))
	return out


func _run() -> void:
	var ids: Array = ZeeWeaponArtTable.table().keys()
	ids.sort()
	_check(ids.size() > 10, "the art table has weapons", str(ids.size()))
	var n := ids.size()
	var still := Vector3(0.3, 0.0, 0.3)
	var thrown := Vector3(5.0, 2.0, -3.0)
	var fast := Vector3(14.0, -4.0, 0.0)

	var world := Node3D.new()
	add_child(world)
	_box(world, Vector3(0, -0.5, 0), Vector3(80, 1, 80))
	await _course("flat still", world, ids, _grid(Vector3(-7, 1.2, -4), n), still)
	await _course("flat thrown", world, ids, _grid(Vector3(-17, 1.4, -4), n), thrown)
	await _course("flat fast", world, ids, _grid(Vector3(-30, 1.0, -4), n), fast)
	_box(world, Vector3(-8, 0.3, 14), Vector3(30, 0.6, 3))
	await _course("on a crate", world, ids, _grid(Vector3(-20, 1.4, 14), n, 20, 1.0), still)
	await _course("beside a crate", world, ids, _grid(Vector3(-20, 0.8, 11.5), n, 20, 1.0), Vector3(0, 0, 2.0))
	world.queue_free()

	world = Node3D.new()
	add_child(world)
	_box(world, Vector3(0, -0.5, 0), Vector3(80, 1, 80), deg_to_rad(20.0))
	await _course("ramp 20 deg", world, ids, _grid(Vector3(-7, 1.2, -4), n), still)
	world.queue_free()

	world = Node3D.new()
	add_child(world)
	_box(world, Vector3(0, -0.5, 0), Vector3(80, 1, 80))
	for s in 12:
		_box(world, Vector3(0, 0.18 * (s + 1) - 0.5, 0.3 * s + 0.15), Vector3(80, 1, 0.3))
	await _course("stairs", world, ids, _grid(Vector3(-7, 3.0, 0.3), n, 10, 1.5).map(func(p: Vector3) -> Vector3: return Vector3(p.x, 3.0, 0.3 + (p.z - 0.3) * 0.2)), still)
	world.queue_free()

	world = Node3D.new()
	add_child(world)
	_bumpy(world)
	await _course("trimesh floor", world, ids, _grid(Vector3(-7, 1.0, -4), n), still)
	await _course("trimesh thrown", world, ids, _grid(Vector3(-9, 1.2, 4), n), thrown)
	world.queue_free()

	world = Node3D.new()
	add_child(world)
	_box(world, Vector3(0, -0.5, 0), Vector3(80, 1, 80))
	_box(world, Vector3(6, 2, 0), Vector3(1, 4, 40))
	await _course("against a wall", world, ids, _grid(Vector3(0, 1.0, -10), n, 10, 1.5), Vector3(8.0, 1.0, 0.0))
	world.queue_free()

	for map_id in MAPS:
		await _map_course(map_id, ids)
	print("weapondrop_depth: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _map_course(map_id: StringName, ids: Array) -> void:
	var path := ArenaImportedMaps.manifest_path(map_id)
	if path == "":
		print("  %s: not linked, skipped" % map_id)
		return
	var manifest := ArenaBspMap.read_manifest(path)
	var solid := ArenaBspMap.build_collision(manifest, path.get_base_dir())
	var world := Node3D.new()
	add_child(world)
	world.add_child(solid)
	var spawns := ArenaBspMap.spawns_of(manifest)
	var spots := []
	await get_tree().physics_frame
	await get_tree().physics_frame
	for sp in spawns:
		var g := _ground(sp.origin.x, sp.origin.z, sp.origin.y + 1.0)
		if not is_nan(g) and spots.size() < 6:
			spots.append(Vector3(sp.origin.x, g + 1.0, sp.origin.z))
	_check(not spots.is_empty(), "%s: spawn floors found" % map_id)
	if not spots.is_empty():
		var some: Array = []
		for k in range(0, ids.size(), 3):
			some.append(ids[k])
		await _course("%s still" % map_id, world, some, spots, Vector3(0.3, 0.0, 0.3))
		await _course("%s thrown" % map_id, world, some, spots, Vector3(5.0, 2.0, -3.0))
	world.queue_free()
