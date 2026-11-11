extends SceneTree

## The offline client's first-person reload of each weapon, frame by frame: screenshots/reload/<id>_NN.png and a sheet per
## weapon (tools/render_reload.sh). Each frame also counts the arm sets that draw pixels (each owner hidden in turn and
## the frame re-rendered); anything but exactly one fails.
##   xvfb-run -a godot --path . --resolution 1920x1080 --script tools/render_reload.gd [-- --frames 12 --left 1 --only a,b --pose-debug]

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaViewArms := preload("../game/arena_view_arms.gd")
## The fractions to stop at, the wait for a rig to reach one and the contact sheet: dot-weapon's, shared with ZZ's review.
const ReloadShots := preload("res://addons/dot_weapon/view/dot_weapon_reload_shots.gd")

var OUT_DIR := "screenshots/reload"

var client: Node = null
var _failed := 0
var _arm_failed := 0
var retried: Array = []


func _initialize() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var _scratch := ArenaPresentation.use_scratch_settings("render_reload")
	client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	var _a0 := OS.get_cmdline_user_args()
	if _a0.has("--out"):
		OUT_DIR = _a0[_a0.find("--out") + 1]
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var args := OS.get_cmdline_user_args()
	var frames := int(_arg(args, "--frames", "12"))
	var left := int(_arg(args, "--left", "1"))
	await _wait(16.0)
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)

	# The round going LIVE hands the player the loadout again and equips its first gun, cancelling a reload in progress: wait it out,
	# or the weapons rendered over that moment lose their last frames ("the reload ended first", the rifle in hand afterwards).
	# The match node lives on the game object (client.game), not on the client: reading it off the client gave null and skipped this wait.
	var game_obj: Object = client.get("game")
	var match_node: Object = game_obj.get("match_node") if game_obj != null else null
	if match_node == null:
		print("render_reload: no match node found, not waiting for LIVE")
	for i in 600:
		if match_node == null or int(match_node.get("state")) == DotMatch.State.LIVE:
			break
		await _wait(0.5)
	if match_node != null:
		print("render_reload: match state %d (LIVE %d) after the wait" % [int(match_node.get("state")), DotMatch.State.LIVE])
	await _wait(1.0)

	var ids: Array = []
	for id: StringName in AwWeaponCatalogue.table():
		var def: DotWeaponDef = AwWeaponCatalogue.table()[id]
		if def.uses_magazine():
			ids.append(str(id))
	ArenaViewArms.debug_pose = args.has("--pose-debug")
	ArenaViewArms.hand_scale_mult = float(_arg(args, "--hand-scale", "1.0"))
	ArenaViewArms.forearm_scale_mult = float(_arg(args, "--forearm-scale", "1.0"))
	ArenaViewArms.max_lean_override = float(_arg(args, "--max-lean", "-1"))
	var only := _arg(args, "--only", "")
	if only != "":
		ids = Array(only.split(","))

	if args.has("--probe"):
		await _probe(ids)
		return

	if args.has("--holds"):
		await _holds(args)
		return

	await _run_rest(frames, left, ids, args.has("--tp"))


func _run_rest(frames: int, left: int, ids: Array, tp: bool = false) -> void:
	var tag := "tp_" if tp else ""
	if tp:
		client.call(&"_set_third_person", true)
		await _wait(0.5)
	for id_s in ids:
		var id := StringName(id_s)
		var def: DotWeaponDef = AwWeaponCatalogue.table().get(id)
		if def == null:
			continue
		var me = client.get("player")
		me.health.invulnerable = true
		# The previous weapon's reload must be over, or this one's press is swallowed or reads the old view model.
		for _w in 120:
			if not me.arsenal.is_reloading():
				break
			await process_frame
		# Carry weight refuses a heavy gun on top of the earlier ones, which read as "not in hand".
		if me.arsenal.carry != null:
			me.arsenal.carry.enabled = false
		var given: DotResult = me.arsenal.give(id)
		if not given.ok:
			print("%s: give failed: %s" % [id, given.message])
		me.arsenal.equip(def.slot)
		await _wait(2.5)
		var slot: DotWeaponSlot = me.arsenal.current()
		if slot == null or slot.def.id != id:
			print("%s: not in hand, skipped" % id)
			continue
		slot.magazine = clampi(left, 0, def.magazine - 1)
		var seconds := _reload_seconds(me.arsenal, def)
		for _try in 6:
			Input.action_press(&"arena_reload")
			await _wait(0.15)
			Input.action_release(&"arena_reload")
			if me.arsenal.is_reloading():
				break
			await _wait(0.2)
		var started: bool = me.arsenal.is_reloading()
		var worst := 0
		var least := 99
		var mags_most := 0
		var mags_none := 0
		var frames_taken := 0
		var last_seen := 0.0
		var slow_captures := 0
		var view := _view_model(me)
		if view != null and not view.has_method(&"reload_sequence"):
			view = null
		# The view model builds its sequence a frame or two after the arsenal starts the reload.
		for _w in 30:
			if view == null or view.call(&"reload_sequence") != null or not me.arsenal.is_reloading():
				break
			await process_frame
		if view != null:
			print("%s: %s" % [id, view.call(&"reload_sequence").describe() if view.call(&"reload_sequence") != null else "no sequence"])
		if tp:
			# The watcher's model of the gun: frames on the clock, the magazines under the held model counted.
			var held: Node = me.get("held")
			var tp_tiles: Array[Image] = []
			for f in frames:
				await _wait(seconds / float(frames))
				tp_tiles.append(await _shot("%s%s_%02d" % [tag, id, f]))
				var seen := 0
				if held != null:
					for m in held.find_children("Magazine*", "MeshInstance3D", true, false):
						seen += 1 if (m as Node3D).is_visible_in_tree() else 0
				print("%s tp frame %d: %d carved magazines shown, held %s" % [id, f, seen, held != null])
			_save_sheet(tag + id, tp_tiles)
			await _wait(0.8)
			continue
		var tiles: Array[Image] = []
		var due_at := ReloadShots.fractions(frames)
		var progress := func() -> float:
			return float(view.get(&"_reload_fraction")) if me.arsenal.is_reloading() else -1.0
		for f in frames:
			# Frames are spread over the reload itself: the tree is paused while the arm sets are counted.
			if view != null:
				await ReloadShots.wait_for(self, progress, due_at[f])
			if not me.arsenal.is_reloading():
				var cur: DotWeaponSlot = me.arsenal.current()
				print("%s frame %d: the reload ended first at fraction %.2f (last seen %.2f), magazine %d/%d, reserve %d, current %s" % [id, f, float(view.get(&"_reload_fraction")) if view != null else -1.0, last_seen, cur.magazine if cur != null else -1, def.magazine, me.arsenal._ammo.count(def.ammo_type) if def.ammo_type != &"" else -1, cur.def.id if cur != null else &"none"])
				break
			last_seen = float(view.get(&"_reload_fraction")) if view != null else 0.0
			var f_before := float(view.get(&"_reload_fraction")) if view != null else 0.0
			var t_before := Time.get_ticks_msec()
			tiles.append(await _shot("%s_%02d" % [id, f]))
			if view == null:
				print("%s frame %d: hand gaps %s" % [id, f, _hand_gaps()])
			else:
				var mags: int = view.call(&"reload_magazines_visible")
				mags_most = maxi(mags_most, mags)
				mags_none += 1 if mags == 0 else 0
				print("%s frame %d: f %.2f, %d parts shown, %d magazines in sight, phase %s, hand gaps %s" % [id, f, float(view.get(&"_reload_fraction")), view.call(&"reload_parts_shown"), mags, _phase(view), _hand_gaps()])
			var drawn := await _drawn_sets(me)
			# The reload runs on the sim's clock, not the tree's: a capture that costs more of the reload than the gap to the next
			# frame (slow render on llvmpipe, a busy box) makes the reload end before the last frames. Say so, it is not a short reload.
			if view != null:
				var burn := float(view.get(&"_reload_fraction")) - f_before
				print("%s frame %d: capture took %d ms, the reload advanced %.2f meanwhile (a frame gap is %.2f)" % [id, f, Time.get_ticks_msec() - t_before, burn, 1.0 / float(frames)])
				if burn > 1.0 / float(frames):
					slow_captures += 1
			frames_taken += 1
			worst = maxi(worst, drawn.size())
			least = mini(least, drawn.size())
			if drawn.size() != 1:
				print("%s frame %d: %d arm sets drawn %s" % [id, f, drawn.size(), drawn])
		_save_sheet(id, tiles)
		await _wait(0.6)
		print("%s: reload %.2f s (started %s), %d frames, arm sets drawn per frame %d..%d, most magazines in sight %d (none in %d frames), magazine %d/%d" % [id, seconds, started, frames, least, worst, mags_most, mags_none, me.arsenal.current().magazine, def.magazine])
		var held_now: DotWeaponSlot = me.arsenal.current()
		if frames_taken < frames:
			var swapped := held_now != null and held_now.def.id != id
			print("%s: only %d of %d frames captured: %s (the reload itself is %.2f s, %d captures cost more than a frame gap)" % [id, frames_taken, frames, "the game swapped the gun for %s mid-reload (a loadout re-applied), not a short reload" % held_now.def.id if swapped else "the reload ended", seconds, slow_captures])
			if swapped and not retried.has(id):
				retried.append(id)
				ids.append(id)
				print("%s: rendering it again" % id)
				continue
		if frames_taken == 0:
			print("%s: no frame captured, arm sets not counted" % id)
		elif worst != 1 or least != 1:
			_arm_failed += 1
		# Exactly one magazine in sight per frame bar the instant the hand fetches the next: never two.
		if mags_most > 1 or not started:
			_failed += 1
			print("%s: FAILED, %d magazines in sight at once" % [id, mags_most])
	print("render_reload: %d weapons with two arm sets (or none) at some frame (not fatal)" % _arm_failed)
	print("render_reload: %d weapons failed the one-magazine check" % _failed)
	quit(1 if _failed > 0 else 0)


## `--probe`: each magazine weapon's model from the side and from behind with the box the magazine is carved from drawn red
## (in the model's own space, where the view model measured it): <id>_probe_side.png and <id>_probe_back.png.
func _probe(ids: Array) -> void:
	var carve: Script = load("res://addons/arena_weapons/view/aw_mag_carve.gd")
	var stage := Node3D.new()
	stage.position = Vector3(5000.0, 0.0, 0.0)
	# Its own world in its own viewport: the client's camera keeps taking the main window back.
	var sv := SubViewport.new()
	sv.size = Vector2i(960, 540)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sv)
	sv.add_child(stage)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40.0, 30.0, 0.0)
	stage.add_child(light)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	stage.add_child(cam)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.85, 0.88, 0.95)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.9, 0.9, 0.9)
	stage.add_child(env)
	for id_s in ids:
		var id := StringName(id_s)
		var def: DotWeaponDef = AwWeaponCatalogue.table().get(id)
		if def == null:
			continue
		var me = client.get("player")
		me.health.invulnerable = true
		if me.arsenal.carry != null:
			me.arsenal.carry.enabled = false
		me.arsenal.give(id)
		me.arsenal.equip(def.slot)
		await _wait(1.4)
		var view := _view_model(me)
		if view == null:
			print("%s: no view model" % id)
			continue
		var art: Object = view.get(&"_art")
		var path := str(art.get(&"model_path"))
		var box: AABB = carve.call(&"recall", path)
		var model := AwModelCache.instantiate(path)
		if model == null:
			continue
		var seat := Transform3D.IDENTITY
		var wn: Variant = view.get(&"_weapon")
		if wn is Node3D:
			seat = (wn as Node3D).transform
		model.transform = seat
		stage.add_child(model)
		var marker := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = box.size
		marker.mesh = bm
		marker.position = box.get_center()
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.1, 0.1, 0.45)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		marker.material_override = mat
		stage.add_child(marker)
		var whole := AABB()
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			if m.mesh != null:
				whole = m.global_transform * m.mesh.get_aabb() if whole.size == Vector3.ZERO else whole.merge(m.global_transform * m.mesh.get_aabb())
		var centre := whole.get_center()
		var span := maxf(whole.size.x, maxf(whole.size.y, whole.size.z)) * 1.15
		cam.size = span
		cam.current = true
		cam.global_position = centre + Vector3(3.0, 0.0, 0.0)
		cam.look_at(centre, Vector3.UP)
		await _shot_vp(sv, "%s_probe_side" % id)
		cam.global_position = centre + Vector3(0.0, 0.0, 3.0)
		cam.look_at(centre, Vector3.UP)
		await _shot_vp(sv, "%s_probe_back" % id)
		cam.global_position = centre + Vector3(0.0, 3.0, 0.0)
		cam.look_at(centre, Vector3.FORWARD)
		await _shot_vp(sv, "%s_probe_top" % id)
		print("%s: model %s, box %s, whole %s" % [id, path, box, whole])
		# The split itself: a fresh copy carved by the real code, the magazine drawn lower so the cut edges show.
		marker.visible = false
		model.queue_free()
		var split := AwModelCache.instantiate(path)
		split.transform = seat
		stage.add_child(split)
		var mag: Node3D = carve.call(&"carve", split, stage, Transform3D.IDENTITY, box, "probe|%s|%s" % [path, box])
		if mag == null:
			print("%s: carve found nothing in the box" % id)
		else:
			var mb := (mag as MeshInstance3D).mesh.get_aabb()
			print("%s: magazine %d surfaces, aabb %s" % [id, (mag as MeshInstance3D).mesh.get_surface_count(), mb])
			mag.position += Vector3(0.0, -mb.size.y * 0.9, 0.0)
		for vw in ["side", "back"]:
			cam.global_position = centre + (Vector3(3.0, 0.0, 0.0) if vw == "side" else Vector3(0.0, 0.0, 3.0))
			cam.look_at(centre, Vector3.UP)
			cam.size = span * 1.1
			await _shot_vp(sv, "%s_split_%s" % [id, vw])
		split.queue_free()
		marker.queue_free()
		cam.current = false
		me.camera.current = true
	quit(0)


## `--holds`: every weapon in the catalogue (or `--only`) at the hip and down the sights, the hands' reach to each grip printed.
func _holds(args: PackedStringArray) -> void:
	var ids: Array = AwWeaponCatalogue.table().keys()
	ids.sort()
	var only := _arg(args, "--only", "")
	if only != "":
		ids = Array(only.split(",")).map(func(s: String) -> StringName: return StringName(s))
	for id: StringName in ids:
		var def: DotWeaponDef = AwWeaponCatalogue.table()[id]
		var me = client.get("player")
		me.health.invulnerable = true
		if me.arsenal.carry != null:
			me.arsenal.carry.enabled = false
		var given: DotResult = me.arsenal.give(id)
		if not given.ok:
			print("%s: give failed: %s" % [id, given.message])
		me.arsenal.equip(def.slot)
		await _wait(1.4)
		var slot: DotWeaponSlot = me.arsenal.current()
		if slot == null or slot.def.id != id:
			print("%s: not in hand, skipped" % id)
			continue
		await _shot("%s_hip" % id)
		print("%s hip: hand gaps %s" % [id, _hand_gaps()])
		Input.action_press(&"arena_aim")
		await _wait(0.9)
		await _shot("%s_ads" % id)
		print("%s ads: hand gaps %s" % [id, _hand_gaps()])
		Input.action_release(&"arena_aim")
		await _wait(0.5)
	print("render_reload: holds done")
	quit(0)


## The whole reload as the arsenal times it: the opening and every round for a per-round reload.
func _reload_seconds(arsenal: DotWeaponArsenal, def: DotWeaponDef) -> float:
	var tps := float(Engine.physics_ticks_per_second)
	if def.reload_per_round:
		var rounds := def.magazine - int(arsenal.current().magazine)
		return (arsenal.ticks_for(def, def.reload_start_ticks) + rounds * arsenal.ticks_for(def, def.reload_ticks)) / tps
	return arsenal.ticks_for(def, def.reload_ticks) / tps


## The arm sets that put pixels on the frame: the tree paused, every arms owner hidden in turn and the frame re-rendered.
func _drawn_sets(me: Node) -> Array:
	var out: Array = []
	paused = true
	var image: Image = await _render()
	for owner: Node3D in _arm_owners(me):
		owner.visible = false
		var without: Image = await _render()
		owner.visible = true
		var changed := _changed(image, without)
		if changed > 40:
			out.append("%s (%d px)" % [client.get_path_to(owner), changed])
	paused = false
	return out


## Every visible arms node near the eye: the pack's own arms, dot-player-char's view arms, and any first-person figure.
func _arm_owners(me: Node) -> Array:
	var camera: Camera3D = me.camera
	var out: Array = []
	for node in client.find_children("*", "Node3D", true, false):
		var script: Script = node.get_script()
		var named := str(script.get_global_name()) if script != null else ""
		if not named in ["AwViewArms", "DotPlayerViewArms", "DotHumanoidFigure"] or not (node as Node3D).is_visible_in_tree():
			continue
		if (node as Node3D).global_position.distance_to(camera.global_position) < 2.0:
			out.append(node)
	# A figure inside a view-arms node is that set's body, not a second set.
	return out.filter(func(n: Node) -> bool: return not out.any(func(o: Node) -> bool: return o != n and o.is_ancestor_of(n)))


## Pixels that differ between two frames, on a 640x360 copy (sampled every other pixel), so a frame costs milliseconds.
func _changed(full_a: Image, full_b: Image) -> int:
	var a := full_a.duplicate() as Image
	var b := full_b.duplicate() as Image
	a.resize(640, 360, Image.INTERPOLATE_NEAREST)
	b.resize(640, 360, Image.INTERPOLATE_NEAREST)
	var n := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			if absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b) > 0.08:
				n += 1
	return n


func _view_model(me: Node) -> AwViewModel:
	var found := (me.camera as Node).find_children("*", "AwViewModel", true, false)
	return found[0] as AwViewModel if not found.is_empty() else null


## How far each drawn hand is from where the view model asked it to be (metres): the arms' reach, not the sequence.
func _hand_gaps() -> String:
	var mounts := client.find_children("ViewArms", "Node3D", true, false).filter(func(n: Node) -> bool: return n.get(&"_grip") != null)
	if mounts.is_empty():
		return "-"
	var grip: DotViewGrip = mounts[0].get(&"_grip")
	var figure := (mounts[0].get(&"arms") as DotPlayerViewArms).arms() as DotHumanoidFigure
	var skeleton := figure.skeleton() if figure != null else null
	if skeleton == null:
		return "-"
	var at := func(bone: String) -> Vector3: return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone)).origin
	var right: float = (at.call("Middle1.R") as Vector3).distance_to(grip.grip_world())
	var left: float = (at.call("Middle1.L") as Vector3).distance_to(grip.support_world()) if grip.is_two_hand() else -1.0
	if OS.get_environment("RELOAD_DEBUG") != "" or OS.get_cmdline_user_args().has("--debug"):
		print("  grip ", grip.grip_world(), " hand ", at.call("Middle1.R"), " shoulder ", at.call("UpperArm.R"), " mount ", (mounts[0] as Node3D).global_position, " anchor ", grip.anchor.global_position, " cam ", client.get("player").camera.global_position, " figure ", figure.global_position, " visible ", figure.is_visible_in_tree())
	return "R %.2f L %.2f" % [right, left]


func _phase(view: AwViewModel) -> String:
	var seq: Variant = view.call(&"reload_sequence")
	return "-" if seq == null else str(seq.call(&"phase_at", float(view.get(&"_reload_fraction"))))


func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


## Frame sequence after each still (DOT_SHOT_FRAMES); see DotShotSeq.
var _seq := DotShotSeq.new()


func _shot(file: String) -> Image:
	var image: Image = await _render()
	var _saved := image.save_png("%s/%s.png" % [OUT_DIR, file])
	await _seq.record(self, "%s/%s.png" % [OUT_DIR, file])
	return image


## The weapon's frames on one sheet, `<id>_sheet.png`.
func _save_sheet(id: String, tiles: Array[Image]) -> void:
	var sheet := ReloadShots.sheet(tiles)
	if sheet != null:
		var _saved := sheet.save_png("%s/%s_sheet.png" % [OUT_DIR, id])


func _shot_vp(sv: SubViewport, file: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var _saved := sv.get_texture().get_image().save_png("%s/%s.png" % [OUT_DIR, file])
	await _seq.record(self, "%s/%s.png" % [OUT_DIR, file], sv)


func _render() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_viewport().get_texture().get_image()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
