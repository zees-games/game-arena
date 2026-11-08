extends DotGameCheckSuite

const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaKillcamBodies := preload("../game/arena_killcam_bodies.gd")

## Remote players nobody can see are presented less often, and the ones in view never are (arena-client-perf-1).
## A bare ArenaPlayer has no controller, so `present` returns at once and the counters in `present_lod` are the whole
## story. Run: [code]godot --headless --path . res://examples/headless_remote_lod.tscn[/code]

const SECTIONS := 6
const CHECKS := 19

var _entered := 0
var _completed := 0
var _root: Node3D = null
var _cam: Camera3D = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("game-arena: remote players out of sight are thinned, in sight are not")
	_run.call_deferred()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _body(at: Vector3) -> ArenaPlayer:
	var p := ArenaPlayer.new()
	_root.add_child(p)
	p.global_position = at
	return p


## Presents [param p] for [param frames] frames and returns how many of them were let through (lod counter reset).
func _passes(p: ArenaPlayer, frames: int) -> int:
	var passed := 0
	var frustum := _cam.get_frustum()
	for _i in frames:
		var before := p.get("_lod_frames") as int
		p.present_lod(0.016, _cam.global_position, -_cam.global_basis.z, frustum)
		if (p.get("_lod_frames") as int) == 0 or (p.get("_lod_frames") as int) <= before:
			passed += 1
	return passed


func _run() -> void:
	_root = Node3D.new()
	add_child(_root)
	_cam = Camera3D.new()
	_cam.fov = 75.0
	_root.add_child(_cam)
	_cam.global_position = Vector3.ZERO
	_cam.look_at(Vector3(0, 0, -10), Vector3.UP)
	_cam.make_current()
	await get_tree().process_frame
	ArenaPlayer.present_lod_enabled = true
	ArenaPlayer.lod_frustum = true
	ArenaPlayer.lod_off_every = 4

	_section("a body in the frustum is presented every frame")
	var ahead := _body(Vector3(0, 0, -20))
	_check(_passes(ahead, 8) == 8, "20 m straight ahead: all 8 frames", "%d" % _passes(ahead, 8))
	var edge := _body(Vector3(12, 0, -20))
	_check(_passes(edge, 8) == 8, "inside the right edge of the view: all 8 frames", "%d" % _passes(edge, 8))
	var near := _body(Vector3(0, 0, 4))
	_check(_passes(near, 8) == 8, "behind but within 6 m: all 8 frames")
	_done()

	_section("a body out of the frustum is presented every fourth frame")
	var behind := _body(Vector3(0, 0, 20))
	_check(_passes(behind, 8) == 2, "20 m behind: 2 of 8 frames", "%d" % _passes(behind, 8))
	var beside := _body(Vector3(40, 0, -20))
	_check(_passes(beside, 8) == 2, "past the right edge of the view (the old cone kept it): 2 of 8", "%d" % _passes(beside, 8))
	var carried := _body(Vector3(0, 0, 20))
	var _a := _passes(carried, 3)
	_check((carried.get("_lod_delta") as float) > 0.04, "the skipped time is carried to the frame that presents")
	_done()

	_section("the cvars")
	ArenaPlayer.lod_off_every = 8
	var slow := _body(Vector3(0, 0, 20))
	_check(_passes(slow, 16) == 2, "cl_remote_lod_every 8: 2 of 16 frames", "%d" % _passes(slow, 16))
	ArenaPlayer.lod_off_every = 1
	var every := _body(Vector3(0, 0, 20))
	_check(_passes(every, 8) == 8, "cl_remote_lod_every 1 presents everything")
	ArenaPlayer.lod_off_every = 4
	ArenaPlayer.present_lod_enabled = false
	var off := _body(Vector3(0, 0, 20))
	_check(_passes(off, 8) == 8, "cl_remote_lod 0 presents everything")
	ArenaPlayer.present_lod_enabled = true
	ArenaPlayer.lod_frustum = false
	var cone := _body(Vector3(40, 0, -20))
	_check(_passes(cone, 8) == 8, "cl_remote_lod_frustum 0: the cone keeps that body in view (all 8)", "%d" % _passes(cone, 8))
	var cone_back := _body(Vector3(0, 0, 20))
	_check(_passes(cone_back, 8) == 2, "cl_remote_lod_frustum 0: behind is still thinned")
	ArenaPlayer.lod_frustum = true
	_done()

	_section("the kill-cam recording cap")
	_check(ArenaKillcamBodies.record_hz == 60.0, "default 60 recordings a second")
	_check(ArenaKillcamBodies.record_hz > 0.0 and 1.0e6 / ArenaKillcamBodies.record_hz < 20000.0, "a gap under 20 ms: a replay at 60 fps loses no frame")
	_done()

	_section("thinning is a rate, not only a frame count (render step 6)")
	ArenaPlayer.anim_gate_enabled = true
	var fast_behind := _body(Vector3(0, 0, 20))
	var fast_n := 0
	var fast_frustum := _cam.get_frustum()
	for _i in 36:  # 36 frames of 4 ms (250 fps): a frame count of 4 alone would be 9 presents; 30 Hz makes it 4
		var b4 := fast_behind.get("_lod_frames") as int
		fast_behind.present_lod(0.004, _cam.global_position, -_cam.global_basis.z, fast_frustum)
		if (fast_behind.get("_lod_frames") as int) <= b4:
			fast_n += 1
	_check(fast_n >= 3 and fast_n <= 5, "out of sight at 250 fps: about 30 presents a second (4 of 36 frames)", "%d" % fast_n)
	ArenaPlayer.anim_gate_enabled = false
	var ungated := _body(Vector3(0, 0, 20))
	var ungated_n := 0
	for _i in 36:
		var b5 := ungated.get("_lod_frames") as int
		ungated.present_lod(0.004, _cam.global_position, -_cam.global_basis.z, fast_frustum)
		if (ungated.get("_lod_frames") as int) <= b5:
			ungated_n += 1
	_check(ungated_n == 9, "cl_remote_anim_gate 0: back to every fourth frame (9 of 36)", "%d" % ungated_n)
	ArenaPlayer.anim_gate_enabled = true
	var mid := _body(Vector3(0, 0, -30))
	var _m := _passes(mid, 1)
	_check(is_equal_approx(mid.get("_anim_min_dt") as float, ArenaPlayer.ANIM_GATE_DT), "in view past 15 m: the clip is stepped at 60 Hz at most")
	var close := _body(Vector3(0, 0, -8))
	var _c := _passes(close, 1)
	_check((close.get("_anim_min_dt") as float) == 0.0, "in view within 15 m: the clip is stepped every frame")
	_done()

	_section("the fast kill-cam pose record is the figure's own")
	var fig := DotHumanoidFigure.new()
	_root.add_child(fig)
	fig.build(DotHumanoidLook.stock(21), 1.8)
	fig.set_hold(DotHumanoidFigure.Hold.GUN)
	fig.set_motion({"on_floor": true, "aim": 0.3})
	fig.animate(4.6, 1.0 / 60.0)
	var own := fig.pose_record()
	var quick: PackedFloat32Array = ArenaKillcamBodies._record_fast(fig, fig.get(&"_skeleton"), fig.get(&"_model"))
	_check(own.size() > 13 and own == quick, "same floats, same layout", "%d vs %d" % [own.size(), quick.size()])
	_check(fig.pose_apply(quick, quick, 0.0), "and pose_apply takes it")
	_done()

	_root.queue_free()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)
