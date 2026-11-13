extends DotGameCheckSuite

const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaKillcamBodies := preload("../game/arena_killcam_bodies.gd")

## Remote players nobody can see are presented less often, and the ones in view never are (arena-client-perf-1).
## A bare ArenaPlayer has no controller, so `present` returns at once and the counters in `present_lod` are the whole
## story. Run: [code]godot --headless --path . res://examples/headless_remote_lod.tscn[/code]

const SECTIONS := 7
const CHECKS := 26

var _entered := 0
var _completed := 0
var _root: Node3D = null
var _cam: Camera3D = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("game-fatal-contact: remote players out of sight are thinned, in sight are not")
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


## A remote body with a figure, a held gun and a crest, as far as [method ArenaPlayer.present_lod] needs one.
func _armed_body(at: Vector3) -> ArenaPlayer:
	var p := _body(at)
	p.health = DotHealth.new()
	p.add_child(p.health)
	p.figure = DotHumanoidFigure.new()
	p.add_child(p.figure)
	p.held = AwWorldModel.new()
	p.add_child(p.held)
	var crest := Node3D.new()
	p.add_child(crest)
	p.set("_crest", crest)
	return p


func _shown(node: Variant) -> bool:
	return node is Node3D and (node as Node3D).visible


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

	_section("past the figure's draw range its gun and crest go with it (arena-vm-regress-1)")
	# The figure's mesh stops drawing at DRAW_RANGE; a gun left on would float alone in the sky.
	var armed := _armed_body(Vector3(0, 0, -(DotHumanoidFigure.DRAW_RANGE - 20.0)))
	var _n := _passes(armed, 1)
	_check(armed.held.visible and _shown(armed.get("_crest")), "20 m inside the range: gun and crest drawn")
	armed.global_position = Vector3(0, 0, -(DotHumanoidFigure.DRAW_RANGE + 20.0))
	_n = _passes(armed, 1)
	_check(not armed.held.visible, "20 m past it: the gun is hidden")
	_check(armed.get("_crest") != null and not _shown(armed.get("_crest")), "20 m past it: the crest is hidden")
	armed.held.hide_while_switching = true
	armed.call(&"_present_held", true)
	_check(not armed.held.visible, "its present keeps the gun hidden (the model's own switch hook shows it otherwise)")
	armed.global_position = Vector3(0, 0, -(DotHumanoidFigure.DRAW_RANGE - 20.0))
	_n = _passes(armed, 1)
	_check(armed.held.visible and _shown(armed.get("_crest")), "back in range: both drawn again")
	_done()

	_section("the kill-cam recording cap")
	_check(ArenaKillcamBodies.record_hz == 30.0, "default 30 recordings a second")
	_check(ArenaKillcamBodies.record_hz > 0.0 and 1.0e6 / ArenaKillcamBodies.record_hz < 40000.0, "a gap under 40 ms: the replay interpolates between rows")
	_done()

	_test_anim_gate()
	_root.queue_free()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _test_anim_gate() -> void:
	_section("thinning is a rate, not only a frame count")
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
	var mid := _body(Vector3(0, 0, -12))
	var _m := _passes(mid, 1)
	_check(is_equal_approx(mid.get("_anim_min_dt") as float, ArenaPlayer.ANIM_GATE_DT), "in view past 8 m: the clip is stepped at 30 Hz at most")
	var far := _body(Vector3(0, 0, -30))
	var _f := _passes(far, 1)
	_check(is_equal_approx(far.get("_anim_min_dt") as float, ArenaPlayer.ANIM_GATE_FAR_DT), "in view past 20 m: the clip is stepped at 20 Hz at most")
	var behind := _body(Vector3(0, 0, 20))
	var _b := _passes(behind, 8)
	_check(is_equal_approx(behind.get("_anim_min_dt") as float, ArenaPlayer.ANIM_GATE_OFF_DT), "out of sight: the clip is stepped at 10 Hz at most")
	var close := _body(Vector3(0, 0, -5))
	var _c := _passes(close, 1)
	_check((close.get("_anim_min_dt") as float) == 0.0, "in view within 8 m: the clip is stepped every frame")
	_done()

	_section("in a browser a gated body steps its clip every second present (web-frame-1)")
	var drawn := DotFpsState.new()
	for every: int in [2, 1]:
		ArenaPlayer.anim_gate_every = every
		var gated := _armed_body(Vector3(0, 0, -12))
		gated.set("_anim_min_dt", ArenaPlayer.ANIM_GATE_DT)
		var stepped := 0
		for _i in 8:  # 8 frames of 70 ms (a 14 fps browser): the time gate alone lets every one through
			gated.present_part2(0.07, drawn)
			if (gated.get("_anim_owed") as float) == 0.0:
				stepped += 1
		_check(stepped == 8 / every, "anim_gate_every %d at 14 fps: the clip steps %d of 8 presents" % [every, 8 / every], "%d" % stepped)
	ArenaPlayer.anim_gate_every = 1
	_done()
