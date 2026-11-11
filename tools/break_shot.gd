extends SceneTree
## Renders a real breakable of an imported map before and after a hitscan shot (dot-combat's pellet trace) breaks it, with dot-fx's break effect: one glass pane and one wood breakable.
## xvfb-run godot --path . --script tools/break_shot.gd -- <map id> [<legacy map dir>]  ->  screenshots/<id>_break_<kind>_{before,after}.png

const Bsp := preload("res://maps/arena_bsp_map.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

var _cam: Camera3D
## Frame sequence after the "after" still (DOT_SHOT_FRAMES); see DotShotSeq.
var _seq := DotShotSeq.new()
var _combat := DotCombatManager.new()
var _trace := DotTracePhysics.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var id: String = args[0] if args.size() > 0 else "crackhouse"
	var dir: String = args[1] if args.size() > 1 else "res://maps/imported_dm/%s" % id
	var _scratch := ArenaPresentation.use_scratch_settings("break_shot")
	var map := ArenaMap.by_id(StringName(id))
	root.add_child(map.to_scene())
	root.add_child(ArenaMapLighting.build(map))
	var body := Bsp.build_collision(Bsp.read_manifest(dir.path_join("%s.json" % id)), dir)
	root.add_child(body)
	_combat.trace = _trace
	root.add_child(_combat)
	var fx := DotFxBreak.new()
	fx.add_to_group(&"arena_break_fx")
	root.add_child(fx)
	_cam = Camera3D.new()
	_cam.fov = 70.0
	root.add_child(_cam)
	_run.call_deferred(body, fx, id)


func _run(body: Node, fx: DotFxBreak, id: String) -> void:
	for _i in 4:
		await process_frame
	_trace.bind_from_node(body)
	DirAccess.make_dir_recursive_absolute("screenshots")
	for want in ["glass", "wood"]:
		var pane: Node3D = null
		for c in body.get_children():
			if c.has_method(&"hurt") and String(c.get(&"kind")).begins_with(want) and not bool(c.call(&"is_broken")):
				var big := _box(c).size.length() > 1.0
				if big:
					pane = c
					break
		if pane == null:
			print("no ", want, " breakable found")
			continue
		pane.set(&"shard_count", 0)
		var box := _box(pane)
		var axis := 0
		for a in 3:
			if box.size[a] < box.size[axis]:
				axis = a
		var n := Vector3.ZERO
		n[axis] = 1.0
		var eye := _clear_eye(box, n, pane)
		_cam.look_at_from_position(eye, box.get_center(), Vector3.UP)
		for _i in 6:
			await process_frame
		_save("screenshots/%s_break_%s_before.png" % [id, want])
		var shot := DotShot.new()
		shot.origin = eye
		shot.direction = (box.get_center() - eye).normalized()
		shot.pellets = [shot.direction]
		shot.damage = 1000.0
		shot.max_range = eye.distance_to(box.get_center()) + 2.0
		var _r := _combat.resolve_shot(shot)
		if not bool(pane.call(&"is_broken")):
			print("FAIL the shot did not break ", pane.name, " impacts ", shot.impacts)
		var _b := fx.burst(String(pane.get(&"kind")), box.get_center(), n, 1.0)
		for _i in 7:
			await process_frame
		var after := "screenshots/%s_break_%s_after.png" % [id, want]
		_save(after)
		await _seq.record(self, after)
		print("kind ", pane.get(&"kind"), " health left ", pane.get(&"health"), " broken ", pane.call(&"is_broken"))
	quit()


func _clear_eye(box: AABB, n: Vector3, pane: Node3D) -> Vector3:
	var space := root.world_3d.direct_space_state
	var c := box.get_center()
	var best := c + n * 2.0
	for dist in [1.0, 1.5, 2.5]:
		for sgn in [1.0, -1.0]:
			var eye: Vector3 = c + n * sgn * (maxf(box.size.length(), 1.0) * dist)
			eye.y += 0.2
			var q := PhysicsRayQueryParameters3D.create(eye, c)
			var hit := space.intersect_ray(q)
			if hit.is_empty() or hit.collider == pane or (hit.position as Vector3).distance_to(c) < 0.6:
				return eye
	return best


func _box(pane: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for cs in pane.get_children():
		if cs is CollisionShape3D and cs.shape is ConvexPolygonShape3D:
			for p in (cs.shape as ConvexPolygonShape3D).points:
				var q: Vector3 = p + pane.position
				box = AABB(q, Vector3.ZERO) if first else box.expand(q)
				first = false
	return box


func _save(path: String) -> void:
	root.get_viewport().get_texture().get_image().save_png(path)
