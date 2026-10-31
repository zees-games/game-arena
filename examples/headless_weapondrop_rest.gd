extends Node

## Every weapon model dropped onto flat floor and onto a stair run: once it has settled its lowest
## mesh point is on or above the surface (not sunk into it) and it stays put.
##
## [codeblock]
## godot --headless --path . res://examples/headless_weapondrop_rest.tscn
## [/codeblock]

const TOLERANCE := 0.02
const SETTLE_TICKS := 360

var _checks := 0
var _failed := 0


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


func _floor(root: Node3D, pos: Vector3, size: Vector3, tilt: float = 0.0) -> void:
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


## The surface height at (x, z) on [param course].
func _surface(course: String, x: float, z: float) -> float:
	match course:
		"ramp":
			return -z * tan(deg_to_rad(20.0))
		"stairs":
			return 0.18 * clampf(floorf(z / 0.3) + 1.0, 0.0, 12.0)
	return 0.0


## The mesh extent in [param body]'s own space, for the failure message.
func _local_bounds(body: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [body]
	var inv := body.global_transform.affine_inverse()
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var t := inv * (n as MeshInstance3D).global_transform
			for v in (n as MeshInstance3D).mesh.get_faces():
				if first:
					out = AABB(t * v, Vector3.ZERO)
					first = false
				else:
					out = out.expand(t * v)
		stack.append_array(n.get_children())
	return out


## How far the deepest mesh vertex under [param node] is below the surface (negative: all clear).
func _sunk(node: Node, course: String) -> float:
	var worst := -INF
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and (n as MeshInstance3D).visible:
			var t := (n as MeshInstance3D).global_transform
			for v in (n as MeshInstance3D).mesh.get_faces():
				var w := t * v
				worst = maxf(worst, _surface(course, w.x, w.z) - w.y)
		stack.append_array(n.get_children())
	return worst


func _run() -> void:
	var ids: Array = ZeeWeaponArtTable.table().keys()
	ids.sort()
	_check(ids.size() > 10, "the art table has weapons", str(ids.size()))
	# Courses: flat floor (top y=0); a 20 degree ramp (surface through y=0 at z=0).
	for course in ["flat", "ramp", "stairs"]:
		var world := Node3D.new()
		add_child(world)
		match course:
			"flat":
				_floor(world, Vector3(0, -0.5, 0), Vector3(40, 1, 40))
			"ramp":
				_floor(world, Vector3(0, -0.5, 0), Vector3(40, 1, 40), deg_to_rad(20.0))
			"stairs":
				_floor(world, Vector3(0, -0.5, 0), Vector3(40, 1, 40))
				for s in 12:
					_floor(world, Vector3(0, 0.18 * (s + 1) - 0.5, 0.3 * s + 0.15), Vector3(40, 1, 0.3))
		var drops := DotWeaponDrops.new()
		drops.is_authority = true
		drops.draws = true
		drops.look_of = func(w: StringName) -> Node3D:
			var art: Variant = ZeeWeaponArtTable.table().get(w)
			if not (art is ZeeWeaponArt):
				return null
			var m := ZeeWorldModel.new()
			var _r := m.equip(art as ZeeWeaponArt)
			return m
		drops.rules.lifetime = 0.0
		drops.rules.max_count = 0
		world.add_child(drops)
		var spots := {}
		var i := 0
		for w: StringName in ids:
			var x := (i % 10) * 1.5 - 7.0
			var z := (i / 10) * 1.5 - 4.0
			if course == "stairs":
				z = 0.3 + (i / 10) * 0.7
			var origin := Vector3(x, 1.2 + _surface(course, x, z), z)
			var y_at := 0.0
			var id := drops.spawn({"id": w, "magazine": 1, "reserve": 1}, origin, Vector3(0.3, 0.0, 0.3), 0)
			spots[id] = [w, y_at]
			i += 1
		var last := {}
		for _t in SETTLE_TICKS:
			await get_tree().physics_frame
		for id: int in spots:
			var e: Dictionary = drops._entries[id]
			var body: RigidBody3D = e["body"]
			var p := body.global_position
			var sunk := _sunk(body, course)
			last[id] = [sunk, p]
			var sw: StringName = spots[id][0]
			_check(p.y > -5.0, "%s %s: still above the world" % [course, sw], "y=%.2f" % p.y)
			_check(sunk <= TOLERANCE, "%s %s: no mesh point below the surface" % [course, sw], "sunk=%.3f" % sunk)
			var cs: CollisionShape3D = body.get_child(body.get_child_count() - 1) if body.get_child(body.get_child_count() - 1) is CollisionShape3D else null
			var sz: Vector3 = ((cs.shape as BoxShape3D).size if cs != null else Vector3.ZERO)
			_check(bool(e["rest"]), "%s %s: came to rest" % [course, sw], "lv=%.3f av=%.3f sleep=%s still=%.2f shape=%s c=%s mesh=%s" % [body.linear_velocity.length(), body.angular_velocity.length(), body.sleeping, float(e["still"]), sz, cs.position if cs != null else 0, _local_bounds(body)])
		for _t in 120:
			await get_tree().physics_frame
		var moved := 0
		for id: int in spots:
			var body: RigidBody3D = drops._entries[id]["body"]
			if (body.global_position - (last[id][1] as Vector3)).length() > 0.005:
				moved += 1
		_check(moved == 0, "%s: resting drops stay put" % course, "%d moved" % moved)
		world.queue_free()
	print("weapondrop_rest: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
