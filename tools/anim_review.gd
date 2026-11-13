extends "weapon_lab.gd"

## The animation review: the weapon lab's first-person clips, plus a third-person view of your own body and numeric
## glitch metrics per frame, judged per clip. See docs/anim-review.md; run through tools/anim_review.sh.
## Per clip it prints an `ANIMREVIEW {json}` verdict line and an `ANIMFRAMES {json}` line with every frame's numbers (both
## travel on stdout, since a GPU box only sends PNGs back).

## Your own body draws only in the third-person view; the arms only in the first-person one.
const BODY_LAYER := 1 << 18
const ARMS_LAYER := 1 << 17
const VIEW_LAYER := 1 << 19
const ARM_BONES: PackedStringArray = ["UpperArm.R", "LowerArm.R", "Middle1.R", "UpperArm.L", "LowerArm.L", "Middle1.L"]
## Failure limits. Distances in metres, angles in degrees, per frame at the run's fps.
const LIMITS := {"detach_m": 0.06, "intersect_m": 0.03, "near_cut_m": 0.005, "pop_m": 0.04, "pop_deg": 25.0,
	"pop_ratio": 3.0, "kick_m": 0.09, "wrong_hand_frames": 2, "hidden_frames": 3, "tpose_frames": 1}

var _tp_view: SubViewport = null
var _tp_cam: Camera3D = null
var _frames: Array[Dictionary] = []
var _body_metrics := DotClipMetrics.new()
var _clip_key := ""


func _build_lab() -> void:
	super._build_lab()
	_tp_view = SubViewport.new()
	_tp_view.size = Vector2i(480, 540)
	_tp_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_tp_view.world_3d = root.world_3d
	root.add_child(_tp_view)
	_tp_cam = Camera3D.new()
	_tp_cam.fov = 50.0
	_tp_cam.cull_mask = 0xFFFFF & ~VIEW_LAYER & ~ARMS_LAYER
	var me = client.get("player")
	_tp_cam.environment = (me.camera as Camera3D).environment
	_tp_view.add_child(_tp_cam)
	# With your own body off the client draws the figure whole and only hides it, which the staging undoes before the draw.
	var presentation = client.get("presentation")
	if presentation != null and presentation.settings != null:
		var _off: Variant = presentation.settings.set_value(DotOwnBodySetting.KEY, false)


func _save_frame(d: String, i: int, vp: Viewport = null) -> void:
	if vp != null or _tp_view == null:
		await super._save_frame(d, i, vp)
		return
	if i == 0:
		_frames.clear()
		_body_metrics = DotClipMetrics.new()
	# Staged after every _process (the client re-hides your body each frame) and just before this frame draws.
	await RenderingServer.frame_pre_draw
	_stage_views()
	_frames.append(_sample(float(i) / float(fps)))
	await RenderingServer.frame_post_draw
	var _e := root.get_viewport().get_texture().get_image().save_jpg("%s/f_%03d.jpg" % [d, i], 0.9)
	var _t := _tp_view.get_texture().get_image().save_jpg("%s/t_%03d.jpg" % [d, i], 0.9)
	_frames_saved += 1


## Shows your own body to the third-person camera only, and places that camera at a fixed front-right three-quarter view.
func _stage_views() -> void:
	var me = client.get("player")
	var cam := me.camera as Camera3D
	cam.cull_mask = 0xFFFFF & ~BODY_LAYER
	var arms_node := client.get("view_arms") as Node
	if arms_node != null:
		_tag(arms_node, ARMS_LAYER, null)
	var body: Node3D = me.body_mesh
	if body != null:
		body.visible = true
		body.global_position = me.controller.state.position
		body.global_rotation = Vector3(0.0, deg_to_rad(float(me.controller.state.yaw)), 0.0)
		# The gun in the body's hands, as everyone else sees it; the first-person present hides it.
		me._present_held()
		_tag(body, BODY_LAYER, cam)
	var feet: Vector3 = me.controller.state.position
	var yaw := deg_to_rad(float(me.controller.state.yaw))
	_tp_cam.global_position = feet + Basis(Vector3.UP, yaw) * Vector3(1.4, 1.5, -2.0)
	_tp_cam.look_at(feet + Vector3(0.0, 1.1, 0.0))


func _tag(node: Node, layer: int, skip: Node) -> void:
	if node == skip:
		return
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layer
	for child in node.get_children():
		_tag(child, layer, skip)


## One frame's raw numbers: where the hands and weapon are in camera space, and how the arms sit against the grip, the weapon and the near plane.
func _sample(time: float) -> Dictionary:
	var me = client.get("player")
	var cam := me.camera as Camera3D
	var view := _view_model(me)
	var out := {"t": snappedf(time, 0.001), "switching": bool(me.arsenal.is_switching()), "reloading": bool(me.arsenal.is_reloading())}
	var figure: DotHumanoidFigure = me.figure
	if figure != null and figure.skeleton() != null:
		_body_metrics.add(_body_metrics.pose_sample(time, figure.skeleton(), me.controller.state.position, true))
	if view == null:
		return out
	var pose = view.get("_pose")
	if pose != null and pose.has_method(&"deploy_fraction"):
		out["deploy"] = snappedf(float(pose.call(&"deploy_fraction")), 0.001)
	var to_cam := cam.global_transform.affine_inverse()
	var weapon := view.weapon_node()
	out["model_visible"] = view.visible and weapon != null and weapon.is_visible_in_tree()
	out["scoped"] = view.arms_hidden_by_scope()
	out["cut"] = snappedf(view.weapon_cut_depth(cam, cam.near), 0.0001)
	if weapon != null:
		var local := to_cam * weapon.global_transform
		out["weapon"] = _v(local.origin)
		var q := local.basis.get_rotation_quaternion()
		out["weapon_q"] = [snappedf(q.x, 0.00001), snappedf(q.y, 0.00001), snappedf(q.z, 0.00001), snappedf(q.w, 0.00001)]
		out["weapon_id"] = weapon.get_instance_id()
	var mounted := client.get("view_arms") as Node3D
	if mounted == null or not (mounted.get("arms") is DotPlayerViewArms):
		return out
	var arms := mounted.get("arms") as DotPlayerViewArms
	var grip: DotViewGrip = mounted.get("_grip")
	out["arms_visible"] = mounted.is_visible_in_tree() and arms.shown
	out["holding"] = bool(mounted.call(&"holding"))
	if not out["holding"] or not (arms.arms() is DotHumanoidFigure):
		return out
	out["hand_error"] = snappedf(arms.hand_error(grip), 0.0001)
	var skeleton := (arms.arms() as DotHumanoidFigure).skeleton()
	var at := {}
	for bone in ARM_BONES:
		var index := skeleton.find_bone(bone)
		if index >= 0:
			at[bone] = skeleton.global_transform * skeleton.get_bone_global_pose(index).origin
	if at.size() < ARM_BONES.size():
		return out
	for bone: String in at:
		out[bone] = _v(to_cam * (at[bone] as Vector3))
	var grip_at := grip.grip_world()
	out["hand_swap"] = snappedf((at["Middle1.R"] as Vector3).distance_to(grip_at) - (at["Middle1.L"] as Vector3).distance_to(grip_at), 0.0001) if grip.is_two_hand() else 0.0
	out["seen.R"] = _arm_seen(cam, at, ".R")
	out["seen.L"] = _arm_seen(cam, at, ".L")
	out["tpose"] = (_straight_out(to_cam, at, ".R") and out["seen.R"]) or (_straight_out(to_cam, at, ".L") and out["seen.L"])
	out["near"] = snappedf(_near_depth(cam, at, arms.arm_radius), 0.0001)
	out["intersect"] = snappedf(_inside_weapon(weapon, at), 0.0001) if weapon != null else 0.0
	return out


func _v(p: Vector3) -> Array:
	return [snappedf(p.x, 0.0001), snappedf(p.y, 0.0001), snappedf(p.z, 0.0001)]


## The upper arm held straight out sideways and level: a T-pose (no IK applied).
func _straight_out(to_cam: Transform3D, at: Dictionary, side: String) -> bool:
	var dir: Vector3 = (to_cam.basis * ((at["LowerArm" + side] as Vector3) - (at["UpperArm" + side] as Vector3))).normalized()
	return absf(dir.x) > 0.95 and absf(dir.y) < 0.2


## How far inside the near plane plus the arm's own radius any visible point of an arm reaches (positive is a cut).
func _near_depth(cam: Camera3D, at: Dictionary, radius: float) -> float:
	var worst := -1.0
	var size := Vector2(root.get_viewport().get_visible_rect().size)
	for side in [".R", ".L"]:
		for seg in [["UpperArm", "LowerArm"], ["LowerArm", "Middle1"]]:
			for k in 6:
				var p: Vector3 = (at[seg[0] + side] as Vector3).lerp(at[seg[1] + side], float(k) / 5.0)
				var depth := -(cam.global_transform.affine_inverse() * p).z
				if depth <= 0.0:
					continue
				var px := cam.unproject_position(p)
				if px.x < 0.0 or px.y < 0.0 or px.x > size.x or px.y > size.y:
					continue
				worst = maxf(worst, cam.near + radius - depth)
	return worst


## Whether any of an arm's elbow-to-hand line is on screen: the free arm of a one-handed weapon hangs out of view, posed or not.
func _arm_seen(cam: Camera3D, at: Dictionary, side: String) -> bool:
	var size := Vector2(root.get_viewport().get_visible_rect().size)
	for k in 5:
		var p: Vector3 = (at["LowerArm" + side] as Vector3).lerp(at["Middle1" + side], float(k) / 4.0)
		if cam.is_position_behind(p):
			continue
		var px := cam.unproject_position(p)
		if px.x >= 0.0 and px.y >= 0.0 and px.x <= size.x and px.y <= size.y:
			return true
	return false


## How deep the arm bones (elbow to just short of the wrist) sink into any one part of the weapon (receiver, scope,
## magazine): the union of the parts' boxes takes in the air under a scope, where a forearm belongs.
func _inside_weapon(weapon: Node3D, at: Dictionary) -> float:
	var worst := 0.0
	for part in weapon.find_children("*", "MeshInstance3D", true, false):
		var mesh := part as MeshInstance3D
		if not mesh.is_visible_in_tree() or mesh.mesh == null:
			continue
		var box := mesh.mesh.get_aabb()
		if not box.has_volume():
			continue
		var to_part := mesh.global_transform.affine_inverse()
		var scale := mesh.global_transform.basis.get_scale()
		for side in [".R", ".L"]:
			for k in 7:
				var p: Vector3 = to_part * (at["LowerArm" + side] as Vector3).lerp(at["Middle1" + side], float(k) / 10.0)
				if box.has_point(p):
					var lo := (p - box.position) * scale
					var hi := (box.end - p) * scale
					worst = maxf(worst, minf(minf(minf(lo.x, hi.x), minf(lo.y, hi.y)), minf(lo.z, hi.z)))
	return worst


## A clip the lab cannot play (no magazine, no sights, no inspect animation) is still a line of the report.
func _fp_animation(a: String, me, id: StringName, def: DotWeaponDef, wdir: String, other_slot: int) -> Dictionary:
	var res: Dictionary = await super._fp_animation(a, me, id, def, wdir, other_slot)
	if res.get("status", "") != "ok":
		print("ANIMREVIEW " + JSON.stringify({"weapon": str(id), "anim": a, "status": res.get("status", ""), "why": res.get("why", "")}))
	return res


func _finish_clip(wdir: String, key: String, count: int) -> void:
	_clip_key = key
	var verdict := _judge(_frames)
	verdict["weapon"] = wdir.get_file()
	verdict["anim"] = key.trim_prefix("fp_")
	verdict["frames"] = count
	verdict["fps"] = fps
	for row in _body_metrics.evaluate({}):
		if row["check"] == "pop" and not row.get("skip", false):
			verdict["tp_pop"] = row["value"]
			if not row["pass"]:
				(verdict["fail"] as Array).append("tp body pop %s" % row["value"])
	verdict["pass"] = (verdict["fail"] as Array).is_empty()
	var file := FileAccess.open("%s/%s_metrics.json" % [wdir, key], FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"verdict": verdict, "frames": _frames}))
	print("ANIMREVIEW " + JSON.stringify(verdict))
	print("ANIMFRAMES " + JSON.stringify({"weapon": verdict["weapon"], "anim": verdict["anim"], "frames": _frames}))
	super._finish_clip(wdir, key, count)


## The clip's worst numbers and the reasons it fails, frame indexes included so a sheet can be read at the right cell.
func _judge(frames: Array[Dictionary]) -> Dictionary:
	var fail: Array = []
	var worst := {"hand_error": 0.0, "intersect": 0.0, "near": -1.0, "cut": 0.0, "pop_m": 0.0, "pop_deg": 0.0}
	var counts := {"wrong_hand": 0, "hidden": 0, "tpose": 0, "detached": 0}
	var first := {}
	for i in frames.size():
		var f := frames[i]
		var steady: bool = not f.get("switching", false)
		for k in ["hand_error", "intersect", "near", "cut"]:
			if f.has(k) and float(f[k]) > float(worst[k]):
				worst[k] = float(f[k])
				first[k] = i
		if float(f.get("hand_error", 0.0)) > LIMITS["detach_m"]:
			counts["detached"] += 1
		if float(f.get("hand_swap", 0.0)) > 0.02:
			counts["wrong_hand"] += 1
			first["wrong_hand"] = first.get("wrong_hand", i)
		if f.get("tpose", false):
			counts["tpose"] += 1
			first["tpose"] = first.get("tpose", i)
		if steady and f.get("model_visible", false) and not f.get("scoped", false) and not f.get("holding", false):
			counts["hidden"] += 1
			first["hidden"] = first.get("hidden", i)
	var pops := _pops(frames, _clip_key.ends_with("fire"))
	worst["pop_m"] = pops["m"]
	worst["pop_deg"] = pops["deg"]
	if worst["hand_error"] > LIMITS["detach_m"]:
		fail.append("hand off grip %.3f m (%d frames, worst #%d)" % [worst["hand_error"], counts["detached"], first["hand_error"]])
	if worst["intersect"] > LIMITS["intersect_m"]:
		fail.append("forearm inside weapon %.3f m at #%d" % [worst["intersect"], first["intersect"]])
	if worst["near"] > 0.0:
		fail.append("arm through near plane %.3f m at #%d" % [worst["near"], first["near"]])
	if worst["cut"] > LIMITS["near_cut_m"]:
		fail.append("weapon through near plane %.3f m at #%d" % [worst["cut"], first["cut"]])
	if counts["wrong_hand"] > LIMITS["wrong_hand_frames"]:
		fail.append("left hand nearer the grip in %d frames from #%d" % [counts["wrong_hand"], first["wrong_hand"]])
	if counts["tpose"] >= LIMITS["tpose_frames"]:
		fail.append("arms in T-pose in %d frames from #%d" % [counts["tpose"], first["tpose"]])
	if counts["hidden"] > LIMITS["hidden_frames"]:
		fail.append("weapon drawn without arms in %d frames from #%d" % [counts["hidden"], first["hidden"]])
	for p: String in pops["at"]:
		fail.append(p)
	# A draw or holster whose deploy never leaves 1 is an instant swap: the gun appears or vanishes with no motion.
	if _clip_key.ends_with("draw") or _clip_key.ends_with("holster"):
		var low := 1.0
		for f in frames:
			low = minf(low, float(f.get("deploy", 1.0)))
		worst["deploy_min"] = low
		if low > 0.9:
			fail.append("no %s motion: deploy never below %.2f" % [_clip_key.trim_prefix("fp_"), low])
	for k in worst:
		worst[k] = snappedf(float(worst[k]), 0.001)
	return {"worst": worst, "counts": counts, "fail": fail}


## Single-frame jumps of a hand, an elbow or the weapon, in camera space: far above both neighbours, so steady motion is not one.
## The weapon's own node changing (a swap) is not a pop, nor the hands' regrip in the frame after it, nor a hand jump off screen.
func _pops(frames: Array[Dictionary], firing := false) -> Dictionary:
	var out := {"m": 0.0, "deg": 0.0, "at": []}
	var keys := ["weapon", "Middle1.R", "Middle1.L", "LowerArm.R", "LowerArm.L"]
	for key in keys:
		var steps: Array[float] = []
		for i in range(1, frames.size()):
			# The arms take the new grip a frame after the weapon node swaps, low in the view: that frame is the swap too.
			var regrip: bool = key != "weapon" and i >= 2 and frames[i - 2].get("weapon_id") != frames[i - 1].get("weapon_id")
			# A free hand dropping out of view to its rest is a jump nobody sees.
			var side: String = key.right(2)
			var unseen: bool = key != "weapon" and not (frames[i - 1].get("seen" + side, true) or frames[i].get("seen" + side, true))
			steps.append(-1.0 if regrip or unseen else _step(frames[i - 1], frames[i], key))
		# Every shot kicks the gun and the hands on it back in one frame by design; the fire clip allows a kick, not a snap.
		_spikes(steps, LIMITS["kick_m"] if firing else LIMITS["pop_m"], "%s jumps %.3f m at #%d", key, out, "m")
	var turns: Array[float] = []
	for i in range(1, frames.size()):
		var a: Dictionary = frames[i - 1]
		var b: Dictionary = frames[i]
		if not (a.has("weapon_q") and b.has("weapon_q")) or a.get("weapon_id") != b.get("weapon_id"):
			turns.append(-1.0)
			continue
		var qa := Quaternion(a["weapon_q"][0], a["weapon_q"][1], a["weapon_q"][2], a["weapon_q"][3])
		var qb := Quaternion(b["weapon_q"][0], b["weapon_q"][1], b["weapon_q"][2], b["weapon_q"][3])
		turns.append(rad_to_deg(qa.angle_to(qb)))
	_spikes(turns, LIMITS["pop_deg"], "%s turns %.1f deg at #%d", "weapon", out, "deg")
	return out


func _step(a: Dictionary, b: Dictionary, key: String) -> float:
	if not (a.has(key) and b.has(key)) or a.get("weapon_id") != b.get("weapon_id"):
		return -1.0
	return Vector3(a[key][0], a[key][1], a[key][2]).distance_to(Vector3(b[key][0], b[key][1], b[key][2]))


func _spikes(steps: Array[float], limit: float, text: String, key: String, out: Dictionary, unit: String) -> void:
	for i in steps.size():
		var v := steps[i]
		out[unit] = maxf(float(out[unit]), v)
		var before := steps[i - 1] if i > 0 else 0.0
		var after := steps[i + 1] if i + 1 < steps.size() else 0.0
		if v > limit and v > float(LIMITS["pop_ratio"]) * maxf(maxf(before, after), limit * 0.1):
			(out["at"] as Array).append(text % [key, v, i + 1])
