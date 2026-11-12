extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaPlayerTunables := preload("../game/arena_player_tunables.gd")

## How far offline bots' drawn bodies sink into the floor, in absolute metres (DotClipMetrics'
## floor_contact is relative to the first frame): lowest sole and root against a floor ray, per frame.
## `hv . scene res://tools/floor_probe.tscn -- [--bots 12] [--seconds 20] [--unit 0.025]`

var _bots := 12
var _seconds := 20.0
var _unit := 0.0
var _client: Node = null
var _clear := {}
var _worst: PackedStringArray = []
var _floor_normal := Vector3.UP


func _ready() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--unit": _unit = float(args[i + 1])
	var _scratch := ArenaPresentation.use_scratch_settings("floor_probe")
	if _unit > 0.0:
		get_tree().node_added.connect(_override_unit)
	_run.call_deferred()


## The A/B: the same body at another map unit (0.025 is the 1.8 m body before the classic one).
func _override_unit(node: Node) -> void:
	var config = node.get("config")
	if config is Object and "avatar_unit_metres" in config:
		config.avatar_unit_metres = _unit


func _run() -> void:
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	await _frames_for(30.0)
	var rows := {"stand": PackedFloat64Array(), "crouch": PackedFloat64Array(), "root": PackedFloat64Array()}
	var t0 := Time.get_ticks_usec()
	var heights := {}
	while (Time.get_ticks_usec() - t0) / 1.0e6 < _seconds:
		await get_tree().process_frame
		for p: ArenaPlayer in _client.game.players():
			if p.camera != null or p.figure == null or p.body_mesh == null or not p.body_mesh.visible or not p.is_alive():
				continue
			var state: DotFpsState = p.controller.state
			if not state.is_grounded():
				continue
			var floor_y := _floor_under(p)
			if is_nan(floor_y):
				continue
			heights["%.3f" % p.figure.height] = true
			rows.root.append(p.body_mesh.global_position.y - floor_y)
			var sole := _sole_y(p.figure)
			if not is_nan(sole):
				(rows.crouch if state.is_crouched() else rows.stand).append(sole - floor_y)
				if sole - floor_y < -0.06 and _worst.size() < 12:
					_worst.append("gap %.3f clip %s speed %.2f crouch %.2f step %d normal_y %.2f" % [sole - floor_y, p.figure.clip, state.horizontal_speed(), state.crouch_fraction, p.figure.anim_step, _floor_normal.y])
	print("FLOOR_PROBE figure heights %s stand_height %.3f" % [str(heights.keys()), ArenaPlayerTunables.stand_height_m()])
	for w: String in _worst:
		print("FLOOR_PROBE worst ", w)
	for key: String in rows:
		print("FLOOR_PROBE %s" % _line(key, rows[key]))
	get_tree().quit(0)


func _line(key: String, v: PackedFloat64Array) -> String:
	if v.is_empty():
		return "%-6s n 0" % key
	var s := v.duplicate()
	s.sort()
	var sum := 0.0
	var sunk := 0
	for x in s:
		sum += x
		if x < -0.03:
			sunk += 1
	return "%-6s n %d min %.3f p05 %.3f p50 %.3f mean %.3f max %.3f below_3cm %.1f%%" % [key, s.size(), s[0], s[s.size() / 20], s[s.size() / 2], sum / s.size(), s[s.size() - 1], 100.0 * sunk / s.size()]


func _floor_under(p: ArenaPlayer) -> float:
	var at := p.body_mesh.global_position
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.6, at + Vector3.DOWN * 2.0, p.controller.tunables.collision_mask)
	q.collide_with_areas = false
	var hit := p.body_mesh.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return NAN
	_floor_normal = hit.normal
	return float((hit.position as Vector3).y)


## The lowest sole in world y: each ankle (found as [DotClipMetrics] finds it, IK feet through their
## leg) less its rest height over the mesh bottom, so a sole on the floor reads 0.
func _sole_y(figure: DotHumanoidFigure) -> float:
	var skel := figure.skeleton()
	var mesh := figure.mesh()
	if skel == null or mesh == null or mesh.mesh == null:
		return NAN
	var key := figure.get_instance_id()
	if not _clear.has(key):
		var to_fig := figure.global_transform.affine_inverse()
		var bottom := (to_fig * mesh.global_transform * mesh.mesh.get_aabb()).position.y
		var feet: Array = []
		for i in skel.get_bone_count():
			var bone := skel.get_bone_name(i).to_lower()
			if bone.contains("foot") and not bone.contains("toe"):
				var rest := skel.get_bone_global_rest(i).origin
				feet.append([i, DotClipMetrics._leg_anchor(skel, i), (to_fig * skel.global_transform * rest).y - bottom])
		_clear[key] = feet
		print("FLOOR_PROBE figure %s look %s mesh %s bottom %.3f height %.3f" % [figure.get_path(), String(figure.look.body) if figure.look else "-", mesh.mesh.resource_path, bottom, figure.height])
		if _clear.size() == 1:
			print("FLOOR_PROBE ankles %s" % str(feet.map(func(f: Array) -> String: return "%s ik=%s clear %.3f" % [skel.get_bone_name(f[0]), f[1] != null, f[2]])))
	var low := INF
	for f: Array in _clear[key]:
		var at := skel.get_bone_global_pose(f[0]).origin
		if f[1] != null:
			at = skel.get_bone_global_pose(f[1][0]) * (f[1][1] as Vector3)
		low = minf(low, (skel.global_transform * at).y - float(f[2]))
	return low if low < INF else NAN


func _frames_for(seconds: float) -> void:
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) / 1.0e6 < seconds:
		await get_tree().process_frame
