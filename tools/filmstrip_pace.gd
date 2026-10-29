extends SceneTree

const ArenaAvatars := preload("../game/arena_avatars.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMapLighting := preload("../maps/arena_map_lighting.gd")

## A person jogging with a noisy pace around the run threshold, a rifle in the hand, a side camera:
## for `--write-movie`, to look at whether the held gun snaps. Logs the gun's step per frame.
##   godot --write-movie out.avi --fixed-fps 60 --script res://tools/filmstrip_pace.gd -- [steady|noisy]

const SECONDS := 6.0
var _fig: DotHumanoidFigure = null
var _held: ZeeWorldModel = null
var _cam: Camera3D = null
var _mode := "noisy"
var _t := 0.0
var _prev := Transform3D.IDENTITY
var _have := false
var _max_deg := 0.0
var _max_cm := 0.0
var _steps: Array[float] = []
var _rng := RandomNumberGenerator.new()
var _pace := 4.0
var _next_pace := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_mode = args[0]
	_rng.seed = 7
	var map := ArenaMap.dm_box()
	root.add_child(map.to_scene())
	root.add_child(ArenaMapLighting.build(map))
	var id := &"arena-player-00000007"
	_fig = DotHumanoidFigure.new()
	root.add_child(_fig)
	_fig.build(ArenaAvatars.look_of(ArenaAvatars.stock_avatar(id), id), 1.8)
	_fig.set_run_speeds(4.4, 3.6)
	_fig.sprint_speed = 6.0
	_fig.global_position = Vector3(0.0, 1.05, 0.0)
	_held = ZeeWorldModel.new()
	if not _held.attach_to(_fig):
		printerr("pace: no hand")
	var table := ZeeWeaponArtTable.table()
	var key: Variant = null
	for k: Variant in table:
		if str(k).contains("assault") or str(k).contains("rifle"):
			key = k
			break
	if key == null:
		key = table.keys()[0]
	print("pace: keys ", table.keys().slice(0, 12))
	print("pace: weapon ", key, " mode ", _mode)
	var _r := _held.equip(table[key] as ZeeWeaponArt)
	_cam = Camera3D.new()
	root.add_child(_cam)
	_cam.current = true
	_cam.look_at_from_position(Vector3(3.2, 2.3, 0.0), Vector3(0.0, 2.0, 0.0))
	_cam.fov = 40.0


func _process(delta: float) -> bool:
	_t += delta
	if _mode == "steady":
		_pace = 4.0
	elif _t >= _next_pace:
		# A pace that jumps across the walk, run and sprint thresholds every 80 to 200 ms.
		_pace = _rng.randf_range(2.6, 6.6)
		_next_pace = _t + _rng.randf_range(0.08, 0.2)
	_fig.set_motion({"sprinting": _pace > 5.6, "on_floor": true, "alive": true})
	_fig.animate(_pace, delta)
	var hand := _fig.attachment(&"right_hand")
	var at := _fig.global_transform.affine_inverse() * hand.global_transform
	if _have and _t > 0.5:
		var d := (_prev.basis.get_rotation_quaternion().inverse() * at.basis.get_rotation_quaternion())
		var deg := rad_to_deg(d.get_angle())
		var cm := (at.origin - _prev.origin).length() * 100.0
		_max_deg = maxf(_max_deg, deg)
		_max_cm = maxf(_max_cm, cm)
		_steps.append(deg)
	_prev = at
	_have = true
	if _t >= SECONDS:
		_steps.sort()
		print("PACE %s max_deg=%.2f p99_deg=%.2f max_cm=%.2f frames=%d" % [_mode, _max_deg, _steps[int(_steps.size() * 0.99)], _max_cm, _steps.size()])
		quit(0)
	return false
