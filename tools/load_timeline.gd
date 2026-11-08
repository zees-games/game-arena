extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")

## The load timeline offline (ArenaLoadTimeline prints one `arena.load` line when the cover lifts), for
## comparing a change back to back. Software GL: the CPU side is real, shader compiles are not.
##
## [codeblock]
## xvfb-run -a godot --path . --rendering-driver opengl3 --resolution 480x270 res://tools/load_timeline.tscn [-- --map <id>]
## [/codeblock]


func _ready() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("load_timeline")
	Engine.max_fps = 0
	_run.call_deferred()


func _run() -> void:
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	add_child(client)
	var t0 := Time.get_ticks_msec()
	var gate: Variant = client.get("gate")
	# Software GL frames are slow; the gate's own 20 s timeout would release the holds before the work is done.
	gate.timeout_sec = 300.0
	gate.warm_timeout_sec = 120.0
	while not (gate != null and gate.is_open()) and Time.get_ticks_msec() - t0 < 280_000:
		await get_tree().process_frame
	print("load_timeline: gate open at engine ms %d (%d ms after the client was added)" % [Time.get_ticks_msec(), Time.get_ticks_msec() - t0])
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if gate != null and gate.is_open() else 1)
