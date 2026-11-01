extends SceneTree

## The real solo client (res://game/arena.tscn) with its menu open on Advanced, scrolled to the
## Performance card, then a one-second recording. `tools/screenshot.sh --profiler-menu [out.png]`;
## needs a renderer (xvfb-run or a GPU box).


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "screenshots/profiler_menu.png"
	var scene := (load("res://game/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for f in 60:
		await process_frame
	print("profiler_menu_shot: client up after %d ms" % Time.get_ticks_msec())
	var prof: Object = DotRegistry.get_service(&"dot_profiler")
	var menu: Object = scene.get(&"game_menu")
	if prof == null or menu == null:
		print("profiler_menu_shot: FAIL profiler=%s menu=%s" % [prof != null, menu != null])
		quit(1)
		return
	var rec: Variant = prof.call(&"start_recording", 1.0)
	var recording: bool = prof.call(&"is_recording")
	while prof.call(&"is_recording"):
		await process_frame
	print("profiler_menu_shot: recording done %d ms" % Time.get_ticks_msec())
	menu.call(&"open", &"advanced")
	for f in 8:
		await process_frame
	var perf := (menu as Node).find_child("Performance", true, false) as Control
	var p: Node = perf
	while p != null and not p is ScrollContainer:
		p = p.get_parent()
	if p != null:
		(p as ScrollContainer).ensure_control_visible(perf)
	for f in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var err := root.get_texture().get_image().save_png(out)
	print("profiler_menu_shot: %s (%s) performance_card=%s still_recording=%s start=%s" % [out, error_string(err), perf != null, recording, rec])
	quit(0 if err == OK and perf != null else 1)
