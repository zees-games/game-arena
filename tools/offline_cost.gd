extends Node

const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ClientBench := preload("client_bench.gd")

## Solo (offline) client with N bots on `--map`, frame and physics cost per frame:
## `godot --path . res://tools/offline_cost.tscn -- --map blackhawkdown --bots 10 --seconds 25`.
## Prints fps, frame p50/p95/max, the engine's physics and process monitors and physics steps per frame.

var _bots := 10
var _reuse := true
var _seconds := 25.0
var _client: Node = null
var _frames := PackedFloat64Array()
var _phys := 0.0
var _proc := 0.0
var _steps0 := 0
var _n := 0
var _last := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--reuse": _reuse = int(args[i + 1]) != 0
			"--lod": ArenaPlayer.present_lod_enabled = int(args[i + 1]) != 0
	var _scratch := ArenaPresentation.use_scratch_settings("offline_cost")
	_run.call_deferred()


func _run() -> void:
	# Headless skips the loading-cover warm; do it after the client registers its own art table, or the default table's paths are warmed and the arena rifle loads mid-match.
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	var _warmed := ZeeModelCache.warm(ZeeWeaponArtTable.model_paths())
	var pilot := ClientBench.Pilot.new()
	pilot.process_priority = -999
	add_child(pilot)
	_set_reuse(self)
	var warm := 8.0
	ArenaFrameProbe.set_interval(1.0e9)
	var t0 := Time.get_ticks_usec()
	var measuring := false
	while true:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var t := (now - t0) / 1.0e6
		if t >= warm and not measuring:
			measuring = true
			_steps0 = Engine.get_physics_frames()
			_q0 = _queries(self)
			ArenaFrameProbe._reset()
			_last = now
			t0 = now
			continue
		if measuring:
			_frames.append((now - _last) / 1000.0)
			_last = now
			_phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			_proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			_n += 1
			if t > _seconds:
				break
	var sorted := _frames.duplicate()
	sorted.sort()
	var n := sorted.size()
	var mean := 0.0
	for f in _frames:
		mean += f
	mean /= n
	var hitches := 0
	for f in _frames:
		if f > 33.0:
			hitches += 1
	print("OFFLINE_COST fps %.1f | frame mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f ms | >33ms %d | physics %.2f ms/frame process %.2f ms/frame | steps %.2f/frame (%d Hz, max %d) | %d bots" % [
		1000.0 / mean, mean, sorted[n / 2], sorted[int(n * 0.95)], sorted[int(n * 0.99)], sorted[n - 1], hitches,
		_phys / _n, _proc / _n, float(Engine.get_physics_frames() - _steps0) / _n,
		Engine.physics_ticks_per_second, Engine.max_physics_steps_per_frame, _bots])
	for key: StringName in ArenaFrameProbe._sections:
		var row: PackedInt64Array = ArenaFrameProbe._sections[key]
		print("  section %-14s %.3f ms/frame | %.3f ms/call x%d | max %.2f ms" % [key, float(row[0]) / _n / 1000.0, float(row[0]) / maxi(row[1], 1) / 1000.0, row[1], row[2] / 1000.0])
	print("  controller queries per physics step: %.1f" % (float(_queries(self) - _q0) / maxf(float(Engine.get_physics_frames() - _steps0), 1.0)))
	_ticks = 0; _reused = 0; _settled = 0
	var _qq := _queries(self)
	print("  motor ticks %d settled-skips %d reused start probes %d (queries per tick %.2f)" % [_ticks, _settled, _reused, float(_qq) / maxf(_ticks, 1.0)])
	print("  physics3d active %d islands %d pairs %d" % [Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS), Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT), Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)])
	get_tree().quit(0)


var _q0 := 0


func _set_reuse(node: Node) -> void:
	if node is DotFpsController and node.get("motor") != null:
		node.motor.reuse_settled_ground = _reuse
	for c in node.get_children():
		_set_reuse(c)
var _ticks := 0
var _reused := 0
var _settled := 0


func _queries(node: Node) -> int:
	var total := 0
	if node is DotFpsController and node.body != null:
		var d: Dictionary = node.body.describe()
		total += int(d.get("queries", d.get("inner", {}).get("queries", 0)))
		var m: Dictionary = node.motor.describe() if node.get("motor") != null else {}
		_ticks += int(m.get("ticks", 0))
		_reused += int(m.get("reused_ground_ticks", 0))
		_settled += int(m.get("settled_ground_ticks", 0))
	for c in node.get_children():
		total += _queries(c)
	return total
