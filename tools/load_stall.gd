extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")
const StallRecorder := preload("stall_recorder.gd")

## The frames around the loading cover, offline: how long the cover is up and what the first
## seconds after it drop look like.
##
## [codeblock]
## xvfb-run -a godot --path . --rendering-driver opengl3 --resolution 480x270 res://tools/load_stall.tscn
## [/codeblock]
##
## Exits 1 when the worst frame in the first `--window` seconds (default 2) after the cover
## is more than `--budget` times the median frame (default 0, off). A ratio, because software
## GL is slow and a stall is what stands out from the rest.

var _seconds := 3.0
var _window := 2.0
var _budget := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--seconds": _seconds = float(args[i + 1])
			"--window": _window = float(args[i + 1])
			"--budget": _budget = float(args[i + 1])
	DotLog.set_level(DotLog.Level.ERROR)
	var _scratch := ArenaPresentation.use_scratch_settings("load_stall")
	Engine.max_fps = 0
	_run.call_deferred()


func _run() -> void:
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	var rec := StallRecorder.new()
	rec.start(get_tree())
	add_child(client)
	rec.watch(client.get("gate"))
	var t0 := Time.get_ticks_usec()
	while rec.open_seconds() < maxf(_seconds, _window) and (Time.get_ticks_usec() - t0) < 90_000_000:
		await get_tree().process_frame
	rec.stop()
	for line in rec.lines(_window):
		print(line)
	var s := rec.summary(_window)
	get_tree().quit(0 if not s.is_empty() and (_budget <= 0.0 or float(s["ratio"]) <= _budget) else 1)
