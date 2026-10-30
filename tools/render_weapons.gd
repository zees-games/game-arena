extends SceneTree

## The offline client's first-person hands for every role an installed weapon pack skins: a frame at the hip and one aimed,
## written to screenshots/weapons/<role>_{hip,aim}.png (tools/render_weapons.sh joins them into a sheet).
## `--arena-no-weapon-skins` renders zee's own art for the comparison.
##
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_weapons.gd [-- --arena-no-weapon-skins]

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaWeaponSkins := preload("../game/arena_weapon_skins.gd")

const OUT_DIR := "screenshots/weapons"

var client: Node = null
var checked := 0
var failed: Array[String] = []


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_weapons")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(16.0)
	# The loading cover holds until every weapon's view is warmed; a frame under it shows the cover.
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)
	var me = client.get("player")
	me.health.invulnerable = true
	print("skin packs: %s" % [ArenaWeaponSkins.applied])
	var roles: Array = []

	for pack in DirAccess.get_directories_at("res://addons"):
		var path := "res://addons/%s/spawn_provider.gd" % pack
		if ResourceLoader.exists(path) and (load(path) as GDScript).has_method(&"role_art"):
			for role in (load(path) as GDScript).call(&"role_art"):
				roles.append(str(role))

	# A game whose own pack holds the plain ids skins nothing by role: every weapon in the catalogue is its art.
	if roles.is_empty():
		for id: StringName in ZeeWeaponPack.table():
			roles.append(str(id))

	var only := OS.get_environment("RENDER_ONLY")
	if only != "":
		roles = Array(only.split(","))

	for role in roles:
		var id := StringName(role)
		var def: DotWeaponDef = ZeeWeaponPack.table().get(id)
		if def == null:
			continue
		# A warmup ending respawns the player with the default loadout: hand the weapon over again until both frames hold it.
		for attempt in 4:
			me = client.get("player")
			me.health.invulnerable = true
			var _g = me.arsenal.give(id)
			me.arsenal.equip(def.slot)
			await _wait(1.4)
			var vms := client.find_children("*", "ZeeViewModel", true, false)
			if not vms.is_empty():
				print("%s wall=%.3f" % [role, (vms[0] as ZeeViewModel).wall_amount()])
			await _shot("%s_hip" % role)
			Input.action_press(&"arena_aim")
			await _wait(0.9)
			await _shot("%s_aim" % role)
			await _see_through(role)
			Input.action_release(&"arena_aim")
			await _wait(0.3)
			if me == client.get("player") and me.arsenal.current() != null and me.arsenal.current().id() == id:
				break

	for line in failed:
		print("FAIL see-through %s" % line)
	print("see-through: %d checked, %d failed" % [checked, failed.size()])
	quit(1 if not failed.is_empty() else 0)


## Inside the sight's hole round the screen centre, nothing of the gun nearer than its front post (or a red dot's lens) differs
## from the frame without the view model; the camera's far plane hides the world and the post alike. A red dot's lens is a
## faint tint and its centre is red. Measured with the default cone, so a server that turns the cut off fails it.
func _see_through(role: String) -> void:
	var vms := client.find_children("*", "ZeeViewModel", true, false)
	if vms.is_empty():
		return
	var vm := vms[0] as ZeeViewModel
	if vm.is_scoped() or vm.aim_fraction() < 0.99 or vm._art == null or vm._weapon == null:
		return
	var cone: Dictionary = ZeeViewModel.SightFit.cone_for(vm._art, ZeeAdsRules.new(), [vm._weapon], vm._holder, vm._aim_target(), vm._sight_line)
	if cone.is_empty():
		return
	var camera := root.get_viewport().get_camera_3d()
	var to_camera := camera.global_transform.affine_inverse() * vm._holder.global_transform
	var axis: Vector3 = cone.axis
	var eye: Vector3 = cone.eye
	var lens := ZeeViewModel.SightFit.red_of(vm._sight)
	var reach := minf(float(cone.stop), 2.0)
	if cone.red and lens != null:
		reach = (vm._holder.global_transform.affine_inverse() * lens.global_position - eye).dot(axis)
	var u := axis.cross(Vector3.UP).normalized()
	var mid := Vector2(root.get_viewport().get_visible_rect().size) * 0.5
	# The camera is not quite at the cone's apex (the hands lens moves the gun), so take the hole's narrowest from the gun's back on.
	var back := reach
	for corner in 8:
		back = minf(back, (vm._holder.global_transform.affine_inverse() * _corner(vm._weapon, corner) - eye).dot(axis))
	var radius := INF
	for i in 9:
		var d := lerpf(maxf(back, reach * 0.02), reach, i / 8.0)
		radius = minf(radius, mid.distance_to(camera.unproject_position(vm._holder.global_transform * (eye + axis * d + u * d * float(cone.tan) * 0.8))))
	var far := -(to_camera * (eye + axis * reach * 0.97)).z
	var keep_far := camera.far
	paused = true
	camera.far = far
	var near_with := await _frame()
	vm.visible = false
	var near_without := await _frame()
	camera.far = keep_far
	var plain := await _frame()
	vm.visible = true
	var full := await _frame()
	paused = false
	var near := _differ(near_with, near_without, mid, radius, 0.0, 0.06)
	var spot := radius * 0.25 if cone.red else radius
	var tint := _differ(full, plain, mid, radius, spot, 0.12) if cone.red else Vector2i.ZERO
	var dot := full.get_pixel(int(mid.x), int(mid.y))
	var ok: bool = (lens != null or not cone.red) and near.y <= near.x / 100 and tint.y <= tint.x / 100 and (not cone.red or (dot.r > 0.5 and dot.r > dot.g + 0.25))
	checked += 1
	var line := "%s: r=%.0fpx, gun nearer than %.2f m on %d of %d px%s" % [role, radius, far, near.y, near.x,
		(", lens tints %d of %d, dot %s" % [tint.y, tint.x, dot.to_html(false)]) if cone.red else ""]
	print("see-through %s" % line)
	if not ok:
		failed.append(line)
		var _a := near_with.save_png("%s/%s_near_with.png" % [OUT_DIR, role])
		var _b := near_without.save_png("%s/%s_near_without.png" % [OUT_DIR, role])


func _corner(weapon: Node3D, i: int) -> Vector3:
	var box := AABB()
	for mesh: MeshInstance3D in weapon.find_children("*", "MeshInstance3D", true, false):
		var b := mesh.global_transform * mesh.get_aabb()
		box = b if box.size == Vector3.ZERO else box.merge(b)
	return box.get_endpoint(i)


func _frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_viewport().get_texture().get_image()


## (pixels, of them differing by more than [param tolerance]) between [param inner] and [param radius] round [param mid].
func _differ(a: Image, b: Image, mid: Vector2, radius: float, inner: float, tolerance: float) -> Vector2i:
	var out := Vector2i.ZERO
	for y in range(int(mid.y - radius), int(mid.y + radius) + 1):
		for x in range(int(mid.x - radius), int(mid.x + radius) + 1):
			var d := Vector2(x, y).distance_to(mid)
			if d > radius or d < inner:
				continue
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			out.x += 1
			out.y += 1 if maxf(absf(p.r - q.r), maxf(absf(p.g - q.g), absf(p.b - q.b))) > tolerance else 0
	return out


func _shot(file: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var _saved := root.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [OUT_DIR, file])
	print("wrote %s/%s.png" % [OUT_DIR, file])


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
