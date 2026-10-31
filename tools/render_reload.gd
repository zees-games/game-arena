extends SceneTree

## The offline client's first-person reload of each weapon, frame by frame: screenshots/reload/<id>_NN.png and a sheet per
## weapon (tools/render_reload.sh). Each frame also counts the arm sets that draw pixels (each owner hidden in turn and
## the frame re-rendered); anything but exactly one fails.
##   xvfb-run -a godot --path . --resolution 1920x1080 --script tools/render_reload.gd [-- --frames 12 --left 1 --only a,b --pose-debug]

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaViewArms := preload("../game/arena_view_arms.gd")

const OUT_DIR := "screenshots/reload"

var client: Node = null
var _failed := 0


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_reload")
	client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
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

	var ids: Array = []
	for id: StringName in ZeeWeaponPack.table():
		var def: DotWeaponDef = ZeeWeaponPack.table()[id]
		if def.uses_magazine():
			ids.append(str(id))
	ArenaViewArms.debug_pose = args.has("--pose-debug")
	ArenaViewArms.hand_scale_mult = float(_arg(args, "--hand-scale", "1.0"))
	ArenaViewArms.forearm_scale_mult = float(_arg(args, "--forearm-scale", "1.0"))
	var only := _arg(args, "--only", "")
	if only != "":
		ids = Array(only.split(","))

	for id_s in ids:
		var id := StringName(id_s)
		var def: DotWeaponDef = ZeeWeaponPack.table().get(id)
		if def == null:
			continue
		var me = client.get("player")
		me.health.invulnerable = true
		# The previous weapon's reload must be over, or this one's press is swallowed or reads the old view model.
		for _w in 120:
			if not me.arsenal.is_reloading():
				break
			await process_frame
		var _g = me.arsenal.give(id)
		me.arsenal.equip(def.slot)
		await _wait(1.4)
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
		for f in frames:
			# Frames are spread over the reload itself: the tree is paused while the arm sets are counted.
			var due := (float(f) + 0.5) / float(frames)
			while view != null and me.arsenal.is_reloading() and float(view.get(&"_reload_fraction")) < due:
				await process_frame
			if not me.arsenal.is_reloading():
				print("%s frame %d: the reload ended first" % [id, f])
				break
			await _shot("%s_%02d" % [id, f])
			if view == null:
				print("%s frame %d: hand gaps %s" % [id, f, _hand_gaps()])
			else:
				print("%s frame %d: f %.2f, %d parts shown, phase %s, hand gaps %s" % [id, f, float(view.get(&"_reload_fraction")), view.call(&"reload_parts_shown"), _phase(view), _hand_gaps()])
			var drawn := await _drawn_sets(me)
			worst = maxi(worst, drawn.size())
			least = mini(least, drawn.size())
			if drawn.size() != 1:
				print("%s frame %d: %d arm sets drawn %s" % [id, f, drawn.size(), drawn])
		await _wait(0.6)
		print("%s: reload %.2f s (started %s), %d frames, arm sets drawn per frame %d..%d, magazine %d/%d" % [id, seconds, started, frames, least, worst, me.arsenal.current().magazine, def.magazine])
		if worst != 1 or least != 1 or not started:
			_failed += 1
	print("render_reload: %d weapons failed the one-arm-set check" % _failed)
	quit(1 if _failed > 0 else 0)


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


## Every visible arms node near the eye: zee's own arms, dot-player-char's view arms, and any first-person figure.
func _arm_owners(me: Node) -> Array:
	var camera: Camera3D = me.camera
	var out: Array = []
	for node in client.find_children("*", "Node3D", true, false):
		var script: Script = node.get_script()
		var named := str(script.get_global_name()) if script != null else ""
		if not named in ["ZeeViewArms", "DotPlayerViewArms", "DotHumanoidFigure"] or not (node as Node3D).is_visible_in_tree():
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


func _view_model(me: Node) -> ZeeViewModel:
	var found := (me.camera as Node).find_children("*", "ZeeViewModel", true, false)
	return found[0] as ZeeViewModel if not found.is_empty() else null


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


func _phase(view: ZeeViewModel) -> String:
	var seq: Variant = view.call(&"reload_sequence")
	return "-" if seq == null else str(seq.call(&"phase_at", float(view.get(&"_reload_fraction"))))


func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _shot(file: String) -> Image:
	var image: Image = await _render()
	var _saved := image.save_png("%s/%s.png" % [OUT_DIR, file])
	return image


func _render() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_viewport().get_texture().get_image()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
