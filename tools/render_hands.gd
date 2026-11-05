extends SceneTree

## Each weapon's first-person hands from several sides: the player's own camera, then the drawn gun and arms frozen and
## photographed from the right, left, top, below, front and behind, at the hip and at reload moments.
## Writes screenshots/hands/<id>_<moment>_<view>.png (tools/render_hands.sh joins a sheet per weapon).
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_hands.gd [-- --only pistol,rifle --reload 0.2,0.45,0.75]

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaViewArms := preload("../game/arena_view_arms.gd")

const OUT_DIR := "screenshots/hands"
const VIEWS := ["right", "left", "top", "below", "front", "behind"]

var client: Node = null


func _initialize() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var _scratch := ArenaPresentation.use_scratch_settings("render_hands")
	client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var args := OS.get_cmdline_user_args()
	await _wait(16.0)
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)
	var ids: Array = Array(_arg(args, "--only", "pistol,smg,rifle,carbine,shotgun,sniper").split(","))
	var moments: Array = []
	for s in _arg(args, "--reload", "0.2,0.45,0.75").split(",", false):
		moments.append(float(s))
	for id_s: String in ids:
		await _weapon(StringName(id_s), moments)
	print("render_hands: done")
	quit(0)


func _weapon(id: StringName, moments: Array) -> void:
	var def: DotWeaponDef = AwWeaponCatalogue.table().get(id)
	if def == null:
		print("%s: no such weapon" % id)
		return
	var me = client.get("player")
	me.health.invulnerable = true
	for _w in 120:
		if not me.arsenal.is_reloading():
			break
		await process_frame
	if me.arsenal.carry != null:
		me.arsenal.carry.enabled = false
	var _given: DotResult = me.arsenal.give(id)
	me.arsenal.equip(def.slot)
	await _wait(1.4)
	var slot: DotWeaponSlot = me.arsenal.current()
	if slot == null or slot.def.id != id:
		print("%s: not in hand, skipped" % id)
		return
	await _moment(me, "%s_hip" % id)
	if not def.uses_magazine() or moments.is_empty():
		return
	slot.magazine = maxi(1, def.magazine / 3)
	for _try in 6:
		Input.action_press(&"arena_reload")
		await _wait(0.15)
		Input.action_release(&"arena_reload")
		if me.arsenal.is_reloading():
			break
		await _wait(0.2)
	var view := _view_model(me)
	for m: float in moments:
		while view != null and me.arsenal.is_reloading() and float(view.get(&"_reload_fraction")) < m:
			await process_frame
		if not me.arsenal.is_reloading():
			print("%s: the reload ended before %.2f" % [id, m])
			break
		var seq: Variant = view.call(&"reload_sequence")
		print("%s reload %.2f: phase %s" % [id, float(view.get(&"_reload_fraction")), "-" if seq == null else str(seq.call(&"phase_at", float(view.get(&"_reload_fraction"))))])
		await _moment(me, "%s_r%02d" % [id, int(m * 100.0)])


## Freezes the clock, shoots the player's own view, then the same pose from every side with the arms grown to the drawn gun's size.
func _moment(me: Node, stem: String) -> void:
	Engine.time_scale = 0.0
	await _render()
	await _save("%s_fp" % stem)
	var view := _view_model(me)
	var mount := _mount()
	if view == null or mount == null or view.weapon_node() == null:
		Engine.time_scale = 1.0
		return
	var arms: DotPlayerViewArms = mount.get(&"arms")
	var saved := {"held": arms.held_scale, "eye": arms.held_eye_from_head, "hs": view.hands_scale, "min": view.hands_min_distance,
		"fov": view.hands_fov, "lean": ArenaViewArms.max_lean_override}
	# The arms are life size and reach a copy of the gun shrunk about the eye: grown by the same factor they hold the drawn gun itself.
	view.hands_fov = (me.camera as Camera3D).fov
	await _frames(2)
	var to_holder: Transform3D = view.transform * (view.get(&"_animated") as Node3D).transform * (view.get(&"_aim_node") as Node3D).transform * (view.get(&"_holder") as Node3D).transform
	var life := AwHandsFrame.life_scale(to_holder, view.get(&"_art"))
	var k := life / maxf(view.hands_scale, 0.01)
	view.hands_scale = life
	view.hands_min_distance = 0.0
	arms.held_scale = saved.held * k
	arms.held_eye_from_head = saved.eye * k
	ArenaViewArms.max_lean_override = (float(view.call(&"art_max_lean")) if view.has_method(&"art_max_lean") else 0.4) * k
	arms.set(&"_fitted", false)
	arms.set(&"_ticks", 3)
	var hidden := _hide_bodies(me)
	var fig: Node = arms.arms()
	var sk: Skeleton3D = (fig as DotHumanoidFigure).skeleton() if fig is DotHumanoidFigure else null
	await _frames(4)
	var gun: Node3D = view.weapon_node()
	var box := _world_box(gun)
	var centre := box.get_center()
	var basis := gun.global_transform.basis.orthonormalized()
	var size := maxf(box.size.length(), 0.2)
	# Its own viewport on the same world: the client makes the player's camera current every frame.
	var port := SubViewport.new()
	port.size = root.get_viewport().get_visible_rect().size
	port.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(port)
	var camera := Camera3D.new()
	camera.fov = 40.0
	camera.near = 0.005
	camera.far = 200.0
	port.add_child(camera)
	camera.current = true
	for v: String in VIEWS:
		var dir: Vector3 = {"right": basis.x, "left": -basis.x, "top": basis.y, "below": -basis.y, "front": -basis.z, "behind": basis.z + basis.y * 0.35}[v]
		var up: Vector3 = -basis.z if v in ["top", "below"] else basis.y
		camera.global_position = centre + dir.normalized() * size * 1.45
		camera.look_at(centre, up)
		await _frames(2)
		await RenderingServer.frame_post_draw
		var _saved := port.get_texture().get_image().save_png("%s/%s_%s.png" % [OUT_DIR, stem, v])
	for side in ([".R", ".L"] if sk != null else []):
		var bone := sk.find_bone("Middle2" + side)
		var at := sk.global_transform * sk.get_bone_global_pose(bone).origin
		for v: String in ["right", "left", "below", "behind"]:
			var dir: Vector3 = {"right": basis.x, "left": -basis.x, "below": -basis.y, "behind": basis.z + basis.y * 0.3}[v]
			camera.global_position = at + dir.normalized() * size * 0.35
			camera.look_at(at, -basis.z if v == "below" else basis.y)
			await _frames(2)
			await RenderingServer.frame_post_draw
			var _h := port.get_texture().get_image().save_png("%s/%s_hand%s_%s.png" % [OUT_DIR, stem, side.substr(1).to_lower(), v])
	ArenaViewArms.hand_pose = false
	camera.global_position = centre + basis.x * size * 1.45
	camera.look_at(centre, basis.y)
	await _frames(3)
	await RenderingServer.frame_post_draw
	var _plain := port.get_texture().get_image().save_png("%s/%s_open.png" % [OUT_DIR, stem])
	ArenaViewArms.hand_pose = true
	port.queue_free()
	for n: Node3D in hidden:
		n.visible = true
	arms.held_scale = saved.held
	arms.held_eye_from_head = saved.eye
	view.hands_scale = saved.hs
	view.hands_min_distance = saved.min
	view.hands_fov = saved.fov
	ArenaViewArms.max_lean_override = saved.lean
	arms.set(&"_fitted", false)
	arms.set(&"_ticks", 3)
	await _frames(3)
	print("%s: hand gaps R %.3f L %.3f (scale %.2f)" % [stem, arms.hand_gap_right, arms.hand_gap_left, k])
	Engine.time_scale = 1.0


## The player's own third-person figure and world gun, which a camera off the eye would see from inside.
func _hide_bodies(me: Node) -> Array:
	var out: Array = []
	for node in (me as Node).find_children("*", "Node3D", true, false):
		var script: Script = node.get_script()
		var named := str(script.get_global_name()) if script != null else ""
		if named in ["DotHumanoidFigure", "AwWorldModel"] and (node as Node3D).is_visible_in_tree() and not _in_view_arms(node):
			(node as Node3D).visible = false
			out.append(node)
	return out


func _in_view_arms(node: Node) -> bool:
	var n := node.get_parent()
	while n != null:
		if n.get_script() == ArenaViewArms or n is DotPlayerViewArms:
			return true
		n = n.get_parent()
	return false


func _world_box(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var b := mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _mount() -> Node:
	for n in client.find_children("ViewArms", "Node3D", true, false):
		if n.get(&"_grip") != null:
			return n
	return null


func _view_model(me: Node) -> AwViewModel:
	var found := (me.camera as Node).find_children("*", "AwViewModel", true, false)
	return found[0] as AwViewModel if not found.is_empty() else null


func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _save(file: String) -> void:
	var image: Image = await _render()
	var _saved := image.save_png("%s/%s.png" % [OUT_DIR, file])


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _render() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_viewport().get_texture().get_image()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
