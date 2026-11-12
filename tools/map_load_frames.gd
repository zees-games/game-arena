extends Node

## The frames a client spends drawing an imported map: [method ArenaMap.to_scene_async] behind a [DotFrameSlice],
## then [method ArenaMap.to_collision], each frame's length recorded. Headless, so the CPU side only (no culling node,
## no GPU upload); the windowed numbers come from `tools/perf_bench.sh` on staging02.
## [codeblock]
## godot --headless --path . res://tools/map_load_frames.tscn -- --map cp-orange-x3 [--budget 8] [--limit 0]
## [/codeblock]
## Prints one `map_load_frames:` line per phase with the frame count and the worst frame. Exits 1 when `--limit` (ms,
## 0 = off) is set and a scene-build frame is longer.

const ArenaMap := preload("../maps/arena_map.gd")

var _map := "cp-orange-x3"
var _budget := 8
var _limit := 0
var _frames: Array[int] = []
var _last := 0
var _on := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--map": _map = args[i + 1]
			"--budget": _budget = int(args[i + 1])
			"--limit": _limit = int(args[i + 1])
	_run.call_deferred()


func _process(_delta: float) -> void:
	if not _on:
		return
	var now := Time.get_ticks_usec()
	_frames.append(now - _last)
	_last = now


func _start() -> void:
	_frames.clear()
	_last = Time.get_ticks_usec()
	_on = true


func _stop(label: String) -> int:
	_on = false
	_frames.append(Time.get_ticks_usec() - _last)
	var worst := 0
	var total := 0
	for f in _frames:
		worst = maxi(worst, f)
		total += f
	var sorted: Array[int] = _frames.duplicate()
	sorted.sort()
	var top := PackedStringArray()
	for u in sorted.slice(maxi(sorted.size() - 5, 0)):
		top.append("%.1f" % (u / 1000.0))
	print("map_load_frames: %s frames %d total %.1f ms worst %.1f ms (top %s)" % [label, _frames.size(), total / 1000.0, worst / 1000.0, ", ".join(top)])
	return worst


func _run() -> void:
	var map := ArenaMap.by_id(StringName(_map))
	if map == null:
		print("map_load_frames: no map %s" % _map)
		get_tree().quit(2)
		return
	await get_tree().process_frame
	_start()
	var made: Node3D = await map.to_scene_async(DotFrameSlice.new(_budget))
	var worst := _stop("to_scene_async budget %d" % _budget)
	_start()
	add_child(made)
	await get_tree().process_frame
	_stop("add_child")
	var t := Time.get_ticks_usec()
	var solid := map.to_collision()
	print("map_load_frames: to_collision %.1f ms" % ((Time.get_ticks_usec() - t) / 1000.0))
	solid.free()
	made.queue_free()
	await get_tree().process_frame
	var ok := _limit <= 0 or worst <= _limit * 1000
	print("map_load_frames: %s" % ("PASS" if ok else "FAIL worst frame over %d ms" % _limit))
	get_tree().quit(0 if ok else 1)
