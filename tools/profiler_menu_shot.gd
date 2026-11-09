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
	# The overlay with its default (small, translucent, top left) look, then merged in the bottom right corner.
	var cfg: Object = prof.get(&"config")
	prof.call(&"set_overlay_visible", true)
	for f in 90:
		await process_frame
	var base := out.get_basename()
	var errs := await _save("%s_overlay.png" % base)
	cfg.call(&"set_text", "overlay_corner", "bottom_right")
	cfg.call(&"set_text", "overlay_scale", "1.3")
	for f in 30:
		await process_frame
	errs += await _save("%s_corner.png" % base)
	cfg.call(&"set_text", "overlay_corner", "top_left")
	cfg.call(&"set_text", "overlay_scale", "1.0")
	prof.call(&"set_overlay_visible", false)
	menu.call(&"open", &"advanced")
	for f in 8:
		await process_frame
	var perf := (menu as Node).find_child("Performance", true, false) as Control
	for b in perf.find_children("*", "Button", true, false):
		if (b as Button).text.ends_with("(show)"):
			(b as Button).pressed.emit()
	for f in 8:
		await process_frame
	var p: Node = perf
	while p != null and not p is ScrollContainer:
		p = p.get_parent()
	if p != null:
		(p as ScrollContainer).ensure_control_visible(perf)
	for f in 8:
		await process_frame
	errs += await _save(out)
	for b in perf.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with("What does it record"):
			(b as Button).pressed.emit()
	for f in 8:
		await process_frame
	errs += await _save("%s_catalog.png" % base)
	print("profiler_menu_shot: %s errors=%d performance_card=%s still_recording=%s start=%s" % [out, errs, perf != null, recording, rec])
	quit(0 if errs == 0 and perf != null else 1)


func _save(path: String) -> int:
	await RenderingServer.frame_post_draw
	var err := root.get_texture().get_image().save_png(path)
	print("profiler_menu_shot: saved %s (%s)" % [path, error_string(err)])
	return 0 if err == OK else 1
