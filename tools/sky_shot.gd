extends SceneTree
## Shots fired from open ground into a map's sky, with the weapon impacts drawn: "before" treats the sky as plain world (old map data), "after" skips impacts on the marked sky, as the presentation does.
## tools/sky_shot.sh [<map id>] [before|after]  ->  screenshots/<id>_sky_<mode>.png

const Bsp := preload("res://maps/arena_bsp_map.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")

var _cam: Camera3D


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var id: String = args[0] if args.size() > 0 else "cp-orange-x3"
	var mode: String = args[1] if args.size() > 1 else "after"
	var dir := "res://maps/imported_dm/%s" % id
	var _scratch := ArenaPresentation.use_scratch_settings("sky_shot")
	var map := ArenaMap.by_id(StringName(id))
	root.add_child(map.to_scene())
	root.add_child(ArenaMapLighting.build(map))
	var body := Bsp.build_collision(Bsp.read_manifest(dir.path_join("%s.json" % id)), dir)
	root.add_child(body)
	var fx := AwShotFx.new()
	fx.first_person = true
	fx.eject_shells = false
	root.add_child(fx)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	root.add_child(_cam)
	_run.call_deferred(fx, id, mode)


func _run(fx: AwShotFx, id: String, mode: String) -> void:
	for _i in 4:
		await physics_frame
	var skies := get_nodes_in_group(Bsp.SKY_GROUP)
	if skies.is_empty():
		push_error("no marked sky in %s" % id)
		quit(1)
		return
	var sky := skies[0] as Area3D
	var space := root.world_3d.direct_space_state
	var pick := _pick_view(space, sky)
	if pick.is_empty():
		push_error("no open ground under the sky")
		quit(1)
		return
	_cam.look_at_from_position(pick.eye, pick.eye + (pick.dir as Vector3), Vector3.UP)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var on_sky := 0
	var shots := 30
	for i in shots:
		var d := _cone(pick.dir, rng.randf_range(0.0, deg_to_rad(22.0)), rng.randf() * TAU)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(pick.eye, pick.eye + d * 400.0))
		if hit.is_empty():
			continue
		var up_there := Bsp.on_sky(space, hit.position, d)
		on_sky += int(up_there)
		# Old map data had no sky mark, so "before" draws on every hit.
		if mode == "before" or not up_there:
			fx.play_impact(hit.position, hit.normal, hit.collider)
	for _i in 8:
		await process_frame
	DirAccess.make_dir_recursive_absolute("screenshots")
	var out := "screenshots/%s_sky_%s.png" % [id, mode]
	root.get_viewport().get_texture().get_image().save_png(out)
	print("sky_shot %s: %d shots, %d on the sky, %d marks drawn -> %s" % [mode, shots, on_sky, fx.mark_count(), out])
	quit()


# Open ground under the sky with a view that sees sky and some wall: the grid of the cp_orange suite, a few yaws at 55 degrees up.
func _pick_view(space: PhysicsDirectSpaceState3D, sky: Area3D) -> Dictionary:
	var box := AABB()
	var first := true
	for shape: Node in sky.get_children():
		for p: Vector3 in ((shape as CollisionShape3D).shape as ConvexPolygonShape3D).points:
			box = AABB(p, Vector3.ZERO) if first else box.expand(p)
			first = false
	var best := {}
	var best_score := -1.0
	for gx in 12:
		for gz in 12:
			var top := Vector3(box.position.x + box.size.x * (gx + 0.5) / 12.0, box.end.y - 3.0,
				box.position.z + box.size.z * (gz + 0.5) / 12.0)
			var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(top, Vector3(top.x, box.position.y - 1.0, top.z)))
			if down.is_empty() or Bsp.on_sky(space, down.position, Vector3.DOWN):
				continue
			var eye: Vector3 = down.position + Vector3.UP * 1.7
			for yaw in 8:
				var dir := Vector3(cos(yaw * TAU / 8.0), 0.0, sin(yaw * TAU / 8.0)) * cos(deg_to_rad(55.0)) + Vector3.UP * sin(deg_to_rad(55.0))
				var sky_hits := 0
				var n := 0
				for ring in [0.0, 0.2, 0.38]:
					for k in 6:
						var ray := _cone(dir, ring, k * TAU / 6.0)
						var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + ray * 400.0))
						n += 1
						sky_hits += int(not hit.is_empty() and Bsp.on_sky(space, hit.position, ray))
				var frac := float(sky_hits) / n
				var score := 1.0 - absf(frac - 0.65)
				if frac > 0.3 and score > best_score:
					best_score = score
					best = {"eye": eye, "dir": dir}
	return best


func _cone(axis: Vector3, angle: float, spin: float) -> Vector3:
	var side := axis.cross(Vector3.UP).normalized()
	if side.length() < 0.5:
		side = Vector3.RIGHT
	return axis.rotated(side, angle).rotated(axis, spin).normalized()
