extends "net_probe.gd"

## Looks for weapon drops resting in the air: a real server with hunting bots (FFA) and a real client over loopback
## ENet, both in this process. Every 0.25 s each resting drop on the server and on the client is swept down; one
## that can fall more than [constant EPS] is reported once, with its age, pose and what rested it.
##
## [codeblock]
## godot --headless --path . res://tools/floatgun_probe.tscn -- --bots 10 --seconds 120 [--map atrium]
## [/codeblock]

const EPS := 0.05

var _map := "atrium"
var _seen := {}   ## "s:id" / "c:id" -> true once reported
var _how := {}    ## server drop id -> what rested it last
var _floats := [0, 0]
var _checked := [0, 0]
var _guns := [0, 0]     ## [held or prop guns checked, wrong ones]
var _prop_seen := {}    ## ragdoll gun prop -> time first seen
var _gun_unseen := 0   ## held guns whose own meshes were all hidden
var _shots := 0         ## windowed only: pictures taken of what was reported


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--map":
			_map = args[i + 1]
	super._ready()


func _run() -> void:
	await _boot_server()
	_tune_server()
	await _connect_client()
	await _wait_alive()
	_watch_server()
	await _probe()
	_link.disconnect_from_server("done")
	await get_tree().create_timer(0.3).timeout
	DotPaths.remove_tree(DATA)
	print("floatgun: server floats=%d of %d checks, client floats=%d of %d checks, stray guns=%d of %d checks (%d guns hidden mesh by mesh)" % [_floats[0], _checked[0], _floats[1], _checked[1], _guns[1], _guns[0], _gun_unseen])
	get_tree().quit(1 if _floats[0] + _floats[1] + _guns[1] > 0 else 0)


func _setup_game() -> void:
	var m: ArenaMap = ArenaMap.dm_atrium() if _map == "atrium" else (ArenaMap.dm_pit() if _map == "pit" else ArenaMap.dm_box())
	_game.mode = preload("../game/arena_mode.gd").free_for_all(0)
	_game.setup(m)


func _watch_server() -> void:
	var drops: DotWeaponDrops = _game.weapon_drops
	drops.settled.connect(func(id: int, _at: Transform3D) -> void:
		var e: Dictionary = drops.get("_entries").get(id, {})
		_how[id] = "grounded" if e.has("ground_in") else ("plain-rest" if not _how.has(id) else "ground-moved"))
	drops.pushed.connect(func(id: int, _at: Transform3D, _v: Vector3, _s: Vector3) -> void: _how.erase(id))


func _probe() -> void:
	var t := 0.0
	var next := 0.25
	while t < _seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if t < next:
			continue
		next += 0.25
		_check_side(_game.weapon_drops, "s", t)
		var cg = _client.get("game")
		if cg != null and cg.weapon_drops != null:
			_check_side(cg.weapon_drops, "c", t)
		if cg != null:
			_check_guns(cg, t)


func _check_side(drops: DotWeaponDrops, side: String, t: float) -> void:
	var entries: Dictionary = drops.get("_entries")
	for id: int in entries:
		var e: Dictionary = entries[id]
		var body: RigidBody3D = e["body"]
		var resting := bool(e["rest"])
		# A client drop never told it settled is still judged once it has had time to land.
		if not resting and not (side == "c" and float(e["age"]) > 6.0):
			continue
		if e.has("ground_in"):
			continue
		_checked[0 if side == "s" else 1] += 1
		var fall: float = drops.call("_sweep_down", body, body.global_transform, 3.0).length()
		var embed := _embedded(body, drops)
		var key := "%s:%d" % [side, id]
		if embed > 0.05 and not _seen.has(key + "e"):
			_seen[key + "e"] = true
			_floats[0 if side == "s" else 1] += 1
			_want_shot("embed-%s-%d" % [side, id], body.global_position)
			print("EMBED %s t=%.1f id=%d %s age=%.1f at=%s depth=%.2f how=%s basis=%s" % [side, t, id, String(e["state"].get("id", "")),
				float(e["age"]), body.global_position, embed, _how.get(id, "?") if side == "s" else "-", body.global_basis.get_euler()])
		if fall > EPS and not _seen.has(key):
			_seen[key] = true
			_floats[0 if side == "s" else 1] += 1
			var other := ""
			if side == "c":
				var se: Dictionary = _game.weapon_drops.get("_entries").get(id, {})
				other = " server=%s rest=%s" % [(se["body"] as Node3D).global_position, se["rest"]] if not se.is_empty() else " server=gone"
			_want_shot("float-%s-%d" % [side, id], body.global_position)
			print("FLOAT %s t=%.1f id=%d %s age=%.1f rest=%s at=%s fall=%.2f how=%s frozen=%s%s" % [side, t, id,
				String(e["state"].get("id", "")), float(e["age"]), resting, body.global_position, fall,
				_how.get(id, "?") if side == "s" else "-", body.freeze, other])


## Every gun the client draws that is not a weapon drop: each remote player's held gun must hang at a live, drawn
## body's hand, and each ragdoll gun prop must lie on something once it has had two seconds to fall.
func _check_guns(cg: Node, t: float) -> void:
	for p: Node in cg.call("players"):
		var held: Node3D = p.get("held")
		if held == null or not held.is_visible_in_tree() or p.get("camera") != null and (p.get("camera") as Camera3D).current:
			continue
		_guns[0] += 1
		if _drawn_meshes(held, null) == 0:
			_gun_unseen += 1  # The gun's own meshes are hidden (a camera fade, say): nothing floats.
			continue
		var body: Node3D = p.get("body_mesh")
		var drawn := body != null and body.is_visible_in_tree() and _drawn_meshes(body, held) > 0
		var off := held.global_position - ((body.global_position if body != null else (p as Node3D).global_position) + Vector3(0.0, 1.1, 0.0))
		var why := ""
		if not bool(p.call("is_alive")):
			why = "dead"
		elif not drawn:
			why = "body not drawn"
		elif off.length() > 1.4:
			why = "far from body"
		if why != "":
			_report_gun("held %s %s" % [p.name, why], held.global_position, "off=%s alive=%s fell=%s beyond=%s broken=%d severed=%s seen_dead=%s figure=%s body_vis=%s meshes=%d" % [
				off, p.call("is_alive"), p.get("_fell"), p.get("beyond_figure"), (p.get("_broken") as Array).size(), p.get("_severed"),
				p.get("_down_seen_dead"), p.get("figure") != null, body.visible if body != null else false, _drawn_meshes(body, held) if body != null else -1] + " hidden=%s gun_meshes=%d %s" % [_hidden_paths(body, held) if body != null else [], _drawn_meshes(held, null), _fade_detail(cg, body)] + " " + _pose_detail(p, held), t)
	var yard = cg.get("ragdolls")
	if yard == null:
		return
	for prop: RigidBody3D in yard.get("_props"):
		if not is_instance_valid(prop) or not prop.is_visible_in_tree():
			continue
		var first: float = _prop_seen.get(prop, t)
		_prop_seen[prop] = first
		if t - first < 2.0 or prop.freeze:
			continue
		_guns[0] += 1
		var params := PhysicsTestMotionParameters3D.new()
		params.from = prop.global_transform
		params.motion = Vector3.DOWN * 3.0
		var res := PhysicsTestMotionResult3D.new()
		var hit := PhysicsServer3D.body_test_motion(prop.get_rid(), params, res)
		var fall := res.get_travel().length() if hit else 3.0
		if fall > EPS:
			_report_gun("prop", prop.global_position, "fall=%.2f age=%.1f sleeping=%s v=%s" % [fall, t - first, prop.sleeping, prop.linear_velocity], t)


func _report_gun(what: String, at: Vector3, detail: String, t: float) -> void:
	var key := "%s@%s" % [what, at.snappedf(0.5)]
	if _seen.has(key):
		return
	_seen[key] = true
	_guns[1] += 1
	print("STRAY t=%.1f %s at=%s %s" % [t, what, at, detail])
	_want_shot(what, at)


## How far the physics would push [param body] out of the world it sits in (0 when clear or only touching).
func _embedded(body: RigidBody3D, drops: DotWeaponDrops) -> float:
	var q := PhysicsTestMotionParameters3D.new()
	q.from = body.global_transform
	q.motion = Vector3.ZERO
	q.margin = 0.001
	q.recovery_as_collision = true
	q.exclude_bodies = drops.call("_drop_rids", body)
	var r := PhysicsTestMotionResult3D.new()
	if not PhysicsServer3D.body_test_motion(body.get_rid(), q, r):
		return 0.0
	return maxf(r.get_travel().length(), r.get_collision_depth())


## Where the gun hangs from and what the figure is doing.
func _pose_detail(p: Node, held: Node3D) -> String:
	var fig: Node = p.get("figure")
	var hand: Node3D = p.call("attachment", &"right_hand")
	var skel: Skeleton3D = fig.call("skeleton") if fig != null else null
	var hips := Vector3.ZERO
	if skel != null and skel.get_bone_count() > 0:
		hips = skel.global_transform * skel.get_bone_global_pose(0).origin
	var anim: AnimationPlayer = fig.get("_anim") if fig != null else null
	var extra := " state=%s anim=%s@%.2f playing=%s step=%s owed=%s hand_local=%s" % [fig.get("state") if fig != null else "-",
		anim.current_animation if anim != null else "-", anim.current_animation_position if anim != null and anim.current_animation != "" else -1.0,
		anim.is_playing() if anim != null else false, fig.get("anim_step") if fig != null else "-", fig.get("_owed") if fig != null else "-",
		((fig as Node3D).global_transform.affine_inverse() * hand.global_position) if fig != null and hand != null else Vector3.ZERO]
	return extra + " parent=%s hand_d=%.2f clip=%s hips=%s fig_at=%s fig_basis_y=%s" % [held.get_parent().name if held.get_parent() != null else "-",
		held.global_position.distance_to(hand.global_position) if hand != null else -1.0, fig.get("clip") if fig != null else "-",
		hips, (fig as Node3D).global_position if fig != null else Vector3.ZERO, (fig as Node3D).global_basis.y if fig != null else Vector3.ZERO]


## Paths of hidden nodes under [param root] (the held gun left out), for telling what hid a body.
func _hidden_paths(root: Node, skip: Node) -> Array:
	var out := []
	for c in root.find_children("*", "Node3D", true, false):
		if c == skip or skip.is_ancestor_of(c):
			continue
		if not (c as Node3D).visible:
			out.append(str(root.get_path_to(c)))
	return out


## Whether the client's camera fade holds [param body], how far its camera is, and the skin's transparency.
func _fade_detail(cg: Node, body: Node3D) -> String:
	var me: Node = cg.get("player")
	var cam: Camera3D = me.get("camera") if me != null else null
	if cam == null or body == null:
		return "cam=none"
	var fade: Node = cam.get_node_or_null(^"Fade")
	var fading: Dictionary = fade.get("_fading") if fade != null else {}
	var entry: Dictionary = fading.get(body.get_instance_id(), {})
	var tr := -1.0
	for g in body.find_children("*", "GeometryInstance3D", true, false):
		tr = maxf(tr, (g as GeometryInstance3D).transparency)
	var lens: Variant = cg.call("_replay_lens")
	return "cam_d=%.2f cam_current=%s lens=%s fade_entry=%s amount=%s target=%s max_tr=%.2f fade_proc=%s" % [cam.global_position.distance_to(body.global_position + Vector3.UP),
		cam.current, lens != null, not entry.is_empty(), entry.get("amount", "-"), entry.get("target", "-"), tr, fade.is_processing() if fade != null else false]


func _tree(n: Node, skip: Node, depth: int) -> String:
	if n == skip or depth > 4:
		return ""
	var s := "%s%s(%s%s)" % ["", n.name, n.get_class(), "" if not n is Node3D or (n as Node3D).visible else ",HID"]
	var kids := []
	for c in n.get_children():
		var k := _tree(c, skip, depth + 1)
		if k != "":
			kids.append(k)
	return s + ("[" + ",".join(kids) + "]" if not kids.is_empty() else "")


## Meshes drawn under [param root] (skinned ones too), the held gun's own left out.
func _drawn_meshes(root: Node, skip: Node) -> int:
	if root == skip or root is Node3D and not (root as Node3D).visible:
		return 0
	var n := 1 if root is GeometryInstance3D and not root is GPUParticles3D else 0
	for c in root.get_children():
		n += _drawn_meshes(c, skip)
	return n


## Windowed runs only: a picture of [param at] from 3 m off, eye high, written to screenshots/floatgun_N.png (at most 8).
func _want_shot(what: String, at: Vector3) -> void:
	if DisplayServer.get_name() == "headless" or _shots >= 8:
		return
	_shots += 1
	var n := _shots
	# The game puts its own camera back every frame, so the shot moves whichever camera is current just before drawing.
	var look := Transform3D(Basis.IDENTITY, at + Vector3(2.4, 1.0, 1.6)).looking_at(at, Vector3.UP)
	var aim := func() -> void:
		for cam: Camera3D in get_tree().root.find_children("*", "Camera3D", true, false):
			if cam.current:
				RenderingServer.camera_set_transform(cam.get_camera_rid(), look)
	RenderingServer.frame_pre_draw.connect(aim)
	for _i in 3:
		await RenderingServer.frame_post_draw
	RenderingServer.frame_pre_draw.disconnect(aim)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
	var path := "res://screenshots/floatgun_%d.png" % n
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT %s %s at=%s" % [path, what, at])
