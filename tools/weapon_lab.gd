extends SceneTree

## The weapon lab: one fixed neutral environment, first-person camera, model-viewer camera and lighting, so only the weapon and its animation change. See tools/weapon_lab_README.md.
## `xvfb-run -a godot --path . --resolution 960x540 --fixed-fps 30 --script tools/weapon_lab.gd -- --out <dir> [--only a,b] [--anims idle,draw,fire,ads,reload_empty,reload_tactical,melee,holster,sprint] [--no-turntable] [--no-anims]`
## Per weapon, under <out>/<id>/: fp_<anim>.mp4 + strips, tp_turntable.mp4, tp_orbit_strip.png, closeups and manifest.json (JPEG frames in _frames/ for weapon_lab.sh).

const ArenaPresentation := preload("../game/arena_presentation.gd")

const ALL_ANIMS: PackedStringArray = ["idle", "draw", "fire", "ads", "reload_empty", "reload_tactical", "melee", "holster", "sprint", "inspect"]
const STRIP_FRAMES := 8
const THUMB := Vector2i(480, 270)
## The stage the model viewer lives on, far from the arena so nothing else is in shot.
const STAGE := Vector3(400.0, 0.0, 0.0)
const FP_FLOOR_DROP := 1.0

var client: Node = null
var out_dir := "screenshots/weapon_lab"
var fps := 30
var _manifest: Dictionary = {}
var _frames_saved := 0
var _fp_ready := false
var _lab_cam: Camera3D = null
var _sv: SubViewport = null
var _stage_node: Node3D = null


func _initialize() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var _scratch := ArenaPresentation.use_scratch_settings("weapon_lab")
	client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	client.set("offline_bots", 0)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	out_dir = _arg(args, "--out", out_dir)
	fps = int(_arg(args, "--fps", "30"))
	DirAccess.make_dir_recursive_absolute(out_dir)
	await _wait(16.0)
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)
	_build_lab()
	await _wait(1.0)

	var ids: Array = []
	for id: StringName in AwWeaponCatalogue.table():
		ids.append(str(id))
	ids.sort()
	var only := _arg(args, "--only", "")
	if only != "":
		ids = Array(only.split(","))
	var anims: PackedStringArray = ALL_ANIMS
	var anim_arg := _arg(args, "--anims", "")
	if anim_arg != "":
		anims = anim_arg.split(",")
	var shard := _arg(args, "--shard", "")
	if shard != "":
		var parts := shard.split("/")
		var k := int(parts[0])
		var n := maxi(int(parts[1]), 1)
		var picked: Array = []
		for j in ids.size():
			if j % n == k:
				picked.append(ids[j])
		ids = picked
	var done := 0
	for id_s in ids:
		var id := StringName(id_s)
		var def: DotWeaponDef = AwWeaponCatalogue.table().get(id)
		if def == null:
			print("WEAPON_LAB %s: unknown weapon, skipped" % id)
			continue
		var wdir := "%s/%s" % [out_dir, id]
		DirAccess.make_dir_recursive_absolute(wdir + "/_frames")
		_manifest = {"id": str(id), "slot": str(def.slot), "uses_magazine": def.uses_magazine(), "fp": {}, "tp": {}}
		if not args.has("--no-anims"):
			await _first_person(id, def, wdir, anims)
		if not args.has("--no-turntable"):
			await _model_viewer(id, wdir)
		var f := FileAccess.open(wdir + "/manifest.json", FileAccess.WRITE)
		f.store_string(JSON.stringify(_manifest, "  "))
		f.close()
		print("WEAPON_LAB %s done" % id)
		done += 1
	print("WEAPON_LAB: %d weapons done, %d frames" % [done, _frames_saved])
	quit(0 if done > 0 else 1)


# the lab

## Hides the arena and builds the one neutral room: flat grey floor and backdrop, one fixed sun, flat ambient. The player stands
## where it spawned; the stage for the model viewer is the same room built again far away.
func _build_lab() -> void:
	for n in ["Level", "Lighting", "Hud", "Flashlights"]:
		var node := client.get_node_or_null(n)
		if node != null:
			node.set("visible", false)
	var me = client.get("player")
	me.health.invulnerable = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.36, 0.38, 0.41)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.64, 0.68)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	(me.camera as Camera3D).environment = env
	var fp_origin: Vector3 = (me.global_position as Vector3)
	_make_room(fp_origin - Vector3(0, FP_FLOOR_DROP, 0))
	_make_room(STAGE)
	_stage_node = Node3D.new()
	_stage_node.position = STAGE + Vector3(0, 1.2, 0)
	root.add_child(_stage_node)
	# The model viewer renders into its own viewport (sharing the world), so the player's camera stays the main view.
	_sv = SubViewport.new()
	_sv.size = Vector2i(960, 540)
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_sv)
	_lab_cam = Camera3D.new()
	_lab_cam.fov = 30.0
	_lab_cam.environment = env
	_lab_cam.far = 60.0
	_sv.add_child(_lab_cam)
	_hide_ui()


## Every screen-space layer of the client (HUD, killcam, menus, crosshair) off, so only the world is in shot.
func _hide_ui() -> void:
	root.canvas_cull_mask = 0
	for node in client.find_children("*", "CanvasLayer", true, false):
		(node as CanvasLayer).visible = false
	var hud := client.get_node_or_null("Hud")
	if hud != null:
		hud.set("visible", false)


func _make_room(at: Vector3) -> void:
	var holder := Node3D.new()
	holder.position = at
	root.add_child(holder)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.52, 0.53, 0.55)
	mat.roughness = 0.95
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	floor_mesh.mesh = plane
	floor_mesh.material_override = mat
	holder.add_child(floor_mesh)
	var wall := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(60, 20, 0.5)
	wall.mesh = box
	wall.material_override = mat
	wall.position = Vector3(0, 10, -14)
	holder.add_child(wall)
	var back := wall.duplicate() as MeshInstance3D
	back.position = Vector3(0, 10, 14)
	holder.add_child(back)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = false
	holder.add_child(sun)


# first person

func _first_person(id: StringName, def: DotWeaponDef, wdir: String, anims: PackedStringArray) -> void:
	var me = client.get("player")
	(me.camera as Camera3D).current = true
	_hide_ui()
	for _w in 200:
		if not me.arsenal.is_reloading():
			break
		await process_frame
	if me.arsenal.carry != null:
		me.arsenal.carry.enabled = false
	var given: DotResult = me.arsenal.give(id)
	if not given.ok:
		print("WEAPON_LAB %s: give failed: %s" % [id, given.message])
	else:
		# The game's catalogue may put a weapon in another slot than the pack's table does; the arsenal switches by its own.
		def = (given.value as DotWeaponSlot).def
	# The weapon swapped to for draw/holster: the first catalogue weapon (by id) in a different slot, so it is the same every run.
	var other_slot := -1
	var keys: Array = me.arsenal.catalogue.ids()
	keys.sort()
	for k: StringName in keys:
		var other: DotWeaponDef = me.arsenal.catalogue.get_def(k)
		if other.slot != def.slot and me.arsenal.give(k).ok:
			other_slot = other.slot
			break
	for a in anims:
		var res: Dictionary = await _fp_animation(a, me, id, def, wdir, other_slot)
		(_manifest["fp"] as Dictionary)[a] = res
		await _wait(0.3)
	await _equip_slot(me, other_slot)


func _fp_animation(a: String, me, id: StringName, def: DotWeaponDef, wdir: String, other_slot: int) -> Dictionary:
	var key := "fp_" + a
	var res := {"status": "ok"}
	match a:
		"idle":
			await _ensure_in_hand(me, id, def)
			await _clip(wdir, key, 36, func(_i: int) -> void: pass, res)
		"draw":
			await _equip_slot(me, other_slot)
			await _wait(0.8)
			await _clip(wdir, key, 36, func(i: int) -> void:
				if i == 2:
					_switch_to(me, def.slot), res)
		"holster":
			await _ensure_in_hand(me, id, def)
			await _clip(wdir, key, 30, func(i: int) -> void:
				if i == 3:
					_equip_slot_now(me, other_slot), res)
		"fire":
			await _ensure_in_hand(me, id, def)
			_refill(me, def)
			await _clip(wdir, key, 66, func(i: int) -> void:
				if i == 2:
					Input.action_press(&"arena_fire")
				elif i == 22:
					Input.action_release(&"arena_fire")
				elif i >= 32 and i < 56 and (i - 32) % 8 == 0:
					Input.action_press(&"arena_fire")
				elif i >= 32 and i < 56 and (i - 32) % 8 == 3:
					Input.action_release(&"arena_fire"), res)
			Input.action_release(&"arena_fire")
		"ads":
			await _ensure_in_hand(me, id, def)
			if not _art_can_aim(id):
				res = {"status": "n/a", "why": "weapon has no aim-down-sights"}
			else:
				await _clip(wdir, key, 70, func(i: int) -> void:
					if i == 3:
						Input.action_press(&"arena_aim")
					elif i == 36:
						Input.action_release(&"arena_aim"), res)
				Input.action_release(&"arena_aim")
		"reload_empty", "reload_tactical":
			if not def.uses_magazine():
				res = {"status": "n/a", "why": "no magazine"}
			else:
				await _ensure_in_hand(me, id, def)
				var left := 0 if a == "reload_empty" else maxi(def.magazine - 1, 1)
				if a == "reload_tactical" and def.magazine <= 1:
					res = {"status": "n/a", "why": "single-shot magazine"}
				else:
					me.arsenal.current().magazine = clampi(left, 0, def.magazine - 1)
					res = await _reload_clip(me, wdir, key)
					res["rounds_left"] = left
		"melee":
			await _ensure_in_hand(me, id, def)
			await _clip(wdir, key, 40, func(i: int) -> void:
				if i == 3:
					Input.action_press(&"arena_bash")
				elif i == 6:
					Input.action_release(&"arena_bash"), res)
			Input.action_release(&"arena_bash")
		"sprint":
			await _ensure_in_hand(me, id, def)
			var view := _view_model(me)
			if view == null:
				res = {"status": "n/a", "why": "no view model"}
			else:
				await _clip(wdir, key, 48, func(i: int) -> void:
					if i == 4:
						view.set_sprinting(true)
					elif i == 40:
						view.set_sprinting(false), res)
				view.set_sprinting(false)
		"inspect":
			await _ensure_in_hand(me, id, def)
			var looked := _view_model(me)
			if looked == null or not looked.has_method(&"inspect"):
				res = {"status": "missing", "why": "fc-weapons below API 21 has no inspect"}
			else:
				# The bound key itself, through the client's input as a player presses it (the client reads keys and
				# buttons only, not bare action events).
				var key_event: InputEvent = null
				for bound in InputMap.action_get_events(&"arena_inspect") if InputMap.has_action(&"arena_inspect") else []:
					if bound is InputEventKey:
						key_event = bound
				if key_event == null:
					res = {"status": "missing", "why": "no key bound to arena_inspect"}
					return res
				await _clip(wdir, key, 96, func(i: int) -> void:
					if i == 3 or i == 5:
						var press := key_event.duplicate() as InputEventKey
						press.pressed = i == 3
						Input.parse_input_event(press)
					elif i == 10:
						res["inspect_started"] = looked.inspect_fraction() < 1.0, res)
				if not bool(res.get("inspect_started", false)):
					res = {"status": "missing", "why": "the inspect key started nothing"}
		_:
			res = {"status": "n/a", "why": "unknown animation"}
	return res


func _art_can_aim(id: StringName) -> bool:
	var art: AwWeaponVisual = AwWeaponArtTable.get_art(id)
	return art != null and art.aim_enabled


func _refill(me: Node, def: DotWeaponDef) -> void:
	var slot: DotWeaponSlot = me.arsenal.current()
	if slot != null and def.uses_magazine():
		slot.magazine = def.magazine


func _equip_slot_now(me: Node, slot: int) -> void:
	_switch_to(me, slot)


## A switch as a slot key makes it (holster, then deploy); `equip` is the spawn hand-out and swaps with no motion at all.
func _switch_to(me: Node, slot: int) -> void:
	if not me.arsenal.select(slot, me.controller.state.tick):
		var held: DotWeaponSlot = me.arsenal.current()
		print("WEAPON_LAB switch to slot %d refused (holding %s, slots %s)" % [slot, held.def.id if held != null else &"", str(me.arsenal.slots())])


func _equip_slot(me: Node, slot: int) -> void:
	me.arsenal.equip(slot)
	await _wait(1.2)


## The weapon in hand, settled, and the first-person camera idle: a fixed start for every animation.
func _ensure_in_hand(me: Node, id: StringName, def: DotWeaponDef) -> void:
	var slot: DotWeaponSlot = me.arsenal.current()
	if slot == null or slot.def.id != id:
		me.arsenal.equip(def.slot)
		await _wait(1.4)
	else:
		await _wait(0.6)
	_refill(me, def)


func _reload_clip(me: Node, wdir: String, key: String) -> Dictionary:
	var started := false
	var frames_after_end := 0
	var count := 0
	var d := wdir + "/_frames/" + key
	_clear_dir(d)
	DirAccess.make_dir_recursive_absolute(d)
	var i := 0
	while i < fps * 12:
		if i == 6:
			Input.action_press(&"arena_reload")
		elif i == 12:
			Input.action_release(&"arena_reload")
		if i > 12 and me.arsenal.is_reloading():
			started = true
		await _save_frame(d, count)
		count += 1
		if started and not me.arsenal.is_reloading():
			frames_after_end += 1
			if frames_after_end > 20:
				break
		i += 1
	Input.action_release(&"arena_reload")
	_finish_clip(wdir, key, count)
	return {"status": "ok" if started else "reload-did-not-start", "frames": count, "fps": fps}


func _clip(wdir: String, key: String, frames: int, on_frame: Callable, res: Dictionary) -> void:
	var d := wdir + "/_frames/" + key
	_clear_dir(d)
	DirAccess.make_dir_recursive_absolute(d)
	for i in frames:
		on_frame.call(i)
		await _save_frame(d, i)
	_finish_clip(wdir, key, frames)
	res["frames"] = frames
	res["fps"] = fps


func _save_frame(d: String, i: int, vp: Viewport = null) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := (vp if vp != null else root.get_viewport()).get_texture().get_image()
	var _e := image.save_jpg("%s/f_%03d.jpg" % [d, i], 0.92)
	_frames_saved += 1


## Writes the contact strip (a few evenly spaced frames in a grid) for a clip; weapon_lab.sh encodes the mp4 from the frames.
func _finish_clip(wdir: String, key: String, count: int) -> void:
	var d := wdir + "/_frames/" + key
	_strip("%s/%s_strip.png" % [wdir, key], d, count)


func _strip(path: String, d: String, count: int, labels: bool = false) -> void:
	var n := mini(STRIP_FRAMES, count)
	if n <= 0:
		return
	var cols := 4
	var rows := (n + cols - 1) / cols
	var sheet := Image.create(THUMB.x * cols, THUMB.y * rows, false, Image.FORMAT_RGB8)
	for k in n:
		var idx := int(round(float(k) * float(count - 1) / float(maxi(n - 1, 1))))
		var img := Image.load_from_file("%s/f_%03d.jpg" % [d, idx])
		if img == null:
			continue
		img.convert(Image.FORMAT_RGB8)
		img.resize(THUMB.x, THUMB.y, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(0, 0, THUMB.x, THUMB.y), Vector2i((k % cols) * THUMB.x, (k / cols) * THUMB.y))
	var _s := sheet.save_png(path)


# model viewer

func _model_viewer(id: StringName, wdir: String) -> void:
	var art: AwWeaponVisual = AwWeaponArtTable.get_art(id)
	if art == null or art.model_path == "":
		(_manifest["tp"] as Dictionary)["status"] = "n/a: no model"
		return
	for c in _stage_node.get_children():
		c.queue_free()
	var model := AwModelCache.instantiate(art.model_path)
	if model == null:
		(_manifest["tp"] as Dictionary)["status"] = "n/a: model failed to load"
		return
	# Muzzle to -Z, the model centred on the stage origin so every weapon orbits about its own middle.
	var turn := Basis(Quaternion(art.model_forward.normalized(), Vector3.FORWARD)) if art.model_forward.length() > 0.01 else Basis.IDENTITY
	var holder := Node3D.new()
	_stage_node.add_child(holder)
	model.transform = Transform3D(turn, Vector3.ZERO)
	holder.add_child(model)
	var mag_node: Node3D = null
	if art.magazine_path != "":
		mag_node = AwModelCache.instantiate(art.magazine_path)
		if mag_node != null:
			mag_node.transform = art.magazine_transform()
			model.add_child(mag_node)
	elif art.magazine_part != &"":
		mag_node = model.find_child(str(art.magazine_part), true, false) as Node3D
	await process_frame
	var box := _bounds(model)
	var centre := box.get_center()
	holder.position = -(centre - _stage_node.global_position)
	await process_frame
	var radius := maxf(box.size.length() * 0.5, 0.05)
	var fov := _lab_cam.fov
	var dist := radius / tan(deg_to_rad(fov * 0.5)) * 1.15
	var tp: Dictionary = _manifest["tp"]
	tp["radius_m"] = snappedf(radius, 0.001)
	tp["has_magazine_model"] = mag_node != null

	# Orbit stills: eight yaws at a fixed 12 degree elevation.
	var d := wdir + "/_frames/tp_orbit"
	_clear_dir(d)
	DirAccess.make_dir_recursive_absolute(d)
	for k in 8:
		_place_cam(_stage_node.global_position, dist, k * 45.0, 12.0)
		await _save_frame(d, k, _sv)
		var _c := DirAccess.copy_absolute("%s/f_%03d.jpg" % [d, k], "%s/tp_orbit_%03d.jpg" % [wdir, k * 45])
	_strip(wdir + "/tp_orbit_strip.png", d, 8)
	tp["orbit_yaws"] = [0, 45, 90, 135, 180, 225, 270, 315]

	# Turntable clip: 3 seconds, one full turn, same elevation.
	var turn_frames := fps * 3
	var td := wdir + "/_frames/tp_turntable"
	_clear_dir(td)
	DirAccess.make_dir_recursive_absolute(td)
	for k in turn_frames:
		_place_cam(_stage_node.global_position, dist, 360.0 * float(k) / float(turn_frames), 12.0)
		await _save_frame(td, k, _sv)
	tp["turntable"] = {"frames": turn_frames, "fps": fps}

	# Close-ups: top, underside, muzzle, rear, and the magazine (its own centre) from two sides.
	var closeups := {"top": [0.0, 80.0, 0.6], "under": [0.0, -60.0, 0.6], "muzzle": [0.0, 5.0, 0.55], "rear": [180.0, 5.0, 0.55],
		"side_r": [90.0, 3.0, 0.5], "side_l": [270.0, 3.0, 0.5]}
	var made: Array = []
	for cname in closeups:
		var p: Array = closeups[cname]
		_place_cam(_stage_node.global_position, dist * float(p[2]), float(p[0]), float(p[1]))
		await _save_frame(wdir + "/_frames", 0, _sv)
		var _m := DirAccess.rename_absolute(wdir + "/_frames/f_000.jpg", "%s/tp_closeup_%s.jpg" % [wdir, cname])
		made.append(cname)
	if mag_node != null:
		var mbox := _bounds(mag_node)
		var mdist := maxf(mbox.size.length(), 0.03) * 1.6 / tan(deg_to_rad(fov * 0.5)) * 0.5
		for yaw in [90.0, 270.0, 0.0]:
			_place_cam(mbox.get_center(), mdist, yaw, 8.0)
			await _save_frame(wdir + "/_frames", 0, _sv)
			var _m2 := DirAccess.rename_absolute(wdir + "/_frames/f_000.jpg", "%s/tp_closeup_mag_%d.jpg" % [wdir, int(yaw)])
			made.append("mag_%d" % int(yaw))
	tp["closeups"] = made
	tp["status"] = "ok"


func _place_cam(target: Vector3, dist: float, yaw_deg: float, pitch_deg: float) -> void:
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	_lab_cam.global_position = target + dir * dist
	_lab_cam.look_at(target, Vector3.UP if absf(pitch_deg) < 85.0 else Vector3.FORWARD)


func _bounds(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var b := m.global_transform * m.get_aabb()
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


# helpers

func _view_model(me: Node) -> AwViewModel:
	var found := (me.camera as Node).find_children("*", "AwViewModel", true, false)
	return found[0] as AwViewModel if not found.is_empty() else null


func _clear_dir(d: String) -> void:
	if not DirAccess.dir_exists_absolute(d):
		return
	for f in DirAccess.get_files_at(d):
		var _r := DirAccess.remove_absolute(d + "/" + f)


func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
