extends SceneTree

## Renders the solo client with the lazy workbench opened (F9): screenshots/workbench/open.png.
## Run under xvfb: xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_workbench.gd

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
	var wb: Node = client.get("_workbench")
	print("workbench: %s panel before open: %s" % [wb != null, wb.get("overlay") != null if wb != null else "-"])
	if wb == null:
		quit(1)
		return
	var key := InputEventKey.new()
	key.keycode = wb.get("toggle_key")
	key.pressed = true
	wb.call("_unhandled_key_input", key)
	await create_timer(1.0, true, false, true).timeout
	print("open after F9: %s" % wb.call("is_open"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots/workbench"))
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path(OUT))
	quit(0 if wb.call("is_open") else 1)
