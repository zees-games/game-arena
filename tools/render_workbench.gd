extends SceneTree

## Renders the solo client with the lazy workbench opened (the toggle_action key): screenshots/workbench/open.png.
## Run under xvfb with the compatibility renderer (Forward+ on llvmpipe segfaults in Mesa's shader code
## within a second, which Godot reports as "/root: The caller thread can't call propagate_notification()"):
##   xvfb-run -a godot --path . --rendering-method gl_compatibility --rendering-driver opengl3 \
##     --resolution 1280x720 --script tools/render_workbench.gd

const ArenaPresentation := preload("../game/arena_presentation.gd")
const OUT := "res://screenshots/workbench/open.png"


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_workbench")
	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	client.set("offline_bots", 2)
	root.add_child(client)
	_run.call_deferred(client)


func _run(client: Node) -> void:
	await create_timer(4.0, true, false, true).timeout
	# The load cover draws over everything until the gate opens; software GL takes a while.
	var gate: Object = client.get("gate")
	var waited := 0.0
	while gate != null and not gate.call("is_open") and waited < 120.0:
		await create_timer(0.5, true, false, true).timeout
		waited += 0.5
	print("gate open: %s after %.1fs" % [gate == null or gate.call("is_open"), waited])
	var wb: Node = client.get("_workbench")
	print("workbench: %s panel before open: %s" % [wb != null, wb.get("overlay") != null if wb != null else "-"])
	if wb == null:
		quit(1)
		return
	var action: StringName = wb.get("toggle_action")
	var key := InputEventKey.new()
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			key.keycode = ev.keycode
			key.physical_keycode = ev.physical_keycode
	key.pressed = true
	Input.parse_input_event(key)
	# The panel fades in; on software GL a second can be a handful of frames, so wait frames too.
	await create_timer(1.0, true, false, true).timeout
	for _i in 30:
		await process_frame
	print("open after toggle: %s" % wb.call("is_open"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots/workbench"))
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path(OUT))
	quit(0 if wb.call("is_open") else 1)
