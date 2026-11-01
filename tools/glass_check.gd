extends SceneTree
## Shoots a breakable window of an imported map through dot-combat's own pellet trace: it must break, and the shot must carry on.
## godot --headless --path . --script tools/glass_check.gd -- <map id> [<legacy map dir>]

const Bsp := preload("res://maps/arena_bsp_map.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var id: String = args[0] if args.size() > 0 else "crackhouse"
	var dir: String = args[1] if args.size() > 1 else "res://maps/imported_dm/%s" % id
	var manifest := Bsp.read_manifest(dir.path_join("%s.json" % id))
	var checks := 0
	var failed := 0
	if manifest.is_empty():
		print("FAIL manifest unreadable: ", dir)
		quit(1)
		return
	var body := Bsp.build_collision(manifest, dir)
	root.add_child(body)
	var combat := DotCombatManager.new()
	var trace := DotTracePhysics.new()
	combat.trace = trace
	root.add_child(combat)
	await physics_frame
	await physics_frame
	trace.bind_from_node(body)
	var panes: Array[Node] = []
	for c in body.get_children():
		if c.has_method(&"hurt") and c.has_method(&"is_broken"):
			panes.append(c)
	checks += 1
	print("panes built: ", panes.size())
	if panes.is_empty():
		failed += 1
	var tried := 0
	var passed := 0
	for pane in panes:
		var box := AABB()
		var first := true
		for cs in pane.get_children():
			if cs is CollisionShape3D and cs.shape is ConvexPolygonShape3D:
				for p in (cs.shape as ConvexPolygonShape3D).points:
					var q: Vector3 = p + pane.position
					box = AABB(q, Vector3.ZERO) if first else box.expand(q)
					first = false
		if first:
			continue
		var axis := 0
		for a in 3:
			if box.size[a] < box.size[axis]:
				axis = a
		var dir_v := Vector3.ZERO
		dir_v[axis] = 1.0
		var centre := box.get_center()
		var origin := centre - dir_v * 2.0
		var hit := trace.ray(origin, dir_v, 10.0, [])
		if not hit.ok() or hit.collider != pane:
			print("skip ", pane.name, " hit ", hit.collider if hit.ok() else "nothing")
			continue  # something else in front of this pane
		tried += 1
		var shot := DotShot.new()
		shot.origin = origin
		shot.pellets = [dir_v]
		shot.damage = 100.0
		shot.max_range = 10.0
		var type := DotDamageType.new()
		combat._trace_pellet(shot, 0, type, null, [])
		var broke: bool = pane.is_broken()
		var end: Vector3 = shot.impacts[shot.impacts.size() - 1] if shot.impacts.size() > 0 else origin
		var beyond := (end - origin).dot(dir_v) > 2.0 + box.size[axis] + 0.05
		if broke and beyond:
			passed += 1
		if tried >= 5:
			break
	checks += 1
	print("shot panes: ", tried, ", broken and carried on: ", passed)
	if tried == 0 or passed != tried:
		failed += 1
	print("glass_check: %d checks, %d failed" % [checks, failed])
	quit(1 if failed > 0 else 0)
