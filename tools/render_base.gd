extends SceneTree

## What the capture-the-flag render scripts share: the real offline client (arena.tscn) on `--map`, a frame saved per call, a wait for the round gate and a teleport that looks at a point.
## A script sets [member _out_dir], [member _scratch_name] and [member _map_id] in [method _setup].

const ArenaPresentation := preload("../game/arena_presentation.gd")

var client: Node = null
var _failed := 0
var _map_id := ""
var _tag := ""
var _out_dir := ""
var _scratch_name := ""


func _setup() -> void:
	pass


func _initialize() -> void:
	_setup()
	var args := OS.get_cmdline_user_args()
	var i := args.find("--map")
	if i >= 0 and i + 1 < args.size():
		_map_id = args[i + 1]
	_tag = _map_id.replace("-", "_")
	var _scratch := ArenaPresentation.use_scratch_settings(_scratch_name)
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


func _check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


func _shot(file: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("%s/%s_%s.png" % [_out_dir, _tag, file])
	var _s := root.get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _wait_gate(limit: float) -> void:
	var t := 0.0
	while t < limit:
		var gate = client.get("gate")
		if gate == null or gate.is_open():
			break
		await _wait(0.5)
		t += 0.5


static func _yaw_to(from: Vector3, target: Vector3) -> float:
	var d := target - from
	return rad_to_deg(atan2(-d.x, -d.z))


func _put(at: Vector3, look_at: Vector3, pitch: float = -8.0) -> void:
	var me = client.get("player")
	var yaw := _yaw_to(at, look_at)
	me.controller.teleport(at + Vector3.UP * 0.05, yaw, 0.0)
	client.get("_sampler").look_at_angles(yaw, pitch)
