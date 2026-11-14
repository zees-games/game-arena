extends SceneTree

## The real solo client, Esc menu open, a map folder named `convert` dropped onto it: frames of the "Importing" toast,
## the "Added" toast over the menu, and every page of M after, so a person can see the drop said what it did and the
## map is listed "(local)". `tools/screenshot.sh --map-drop [dir] [convert folder] [map id]` (default: the suite's fixture); with a map id it then
## plays that map and saves four views of it.

func _initialize() -> void:
	_run.call_deferred()


func _key(key: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = key
	e.keycode = key
	e.pressed = true
	return e


func _shot(dir: String, name: String) -> void:
	for f in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := "%s/%s.png" % [dir, name]
	print("map_drop_shot: ", path, " ", error_string(root.get_texture().get_image().save_png(path)))


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var dir := args[0] if args.size() > 0 else "screenshots"
	DirAccess.make_dir_recursive_absolute(dir)
	var source := args[1] if args.size() > 1 else ""
	if source == "":
		source = "user://zz_map_drop_shot/download/convert"
		DirAccess.make_dir_recursive_absolute(source)
		for n in ["fixture.json", "fixture.bin"]:
			var _copied := DirAccess.copy_absolute("res://examples/local_maps".path_join(n), source.path_join(n))
	var client := (load("res://game/arena.tscn") as PackedScene).instantiate()
	root.add_child(client)
	for f in 300:
		await process_frame
	var menu: Object = client.get(&"game_menu")
	menu.call(&"open")
	await _shot(dir, "map_drop_0_menu")
	# The window's own drop signal, as the OS sends it: the game's handler toasts "Importing" and yields a frame before it copies.
	client.get_window().files_dropped.emit(PackedStringArray([ProjectSettings.globalize_path(source)]))
	await RenderingServer.frame_post_draw
	print("map_drop_shot: importing ", root.get_texture().get_image().save_png("%s/map_drop_1_importing.png" % dir))
	for f in 600:
		await process_frame
		var said := str(client.get(&"last_drop_said"))
		if said != "" and not said.begins_with("Importing"):
			break
	print("map_drop_shot: said: ", client.get(&"last_drop_said"))
	await _shot(dir, "map_drop_2_added")
	menu.call(&"close_all")
	var _m: Variant = menu.call(&"handle_event", _key(KEY_M))
	for f in 120:
		await process_frame
	for page in 4:
		await _shot(dir, "map_drop_3_m_page%d" % (page + 1))
		var _n: Variant = menu.call(&"handle_event", _key(KEY_9))
		for f in 6:
			await process_frame
	var play := args[2] if args.size() > 2 else ""
	if play != "":
		menu.call(&"close_all")
		var host: Object = client.get(&"host_console")
		var changed: Variant = await host.call(&"ask", "host_change %s" % play)
		print("map_drop_shot: host_change ", play, " ", (changed as Object).get(&"ok") if changed is Object else changed)
		for f in 600:
			await process_frame
		for turn in 4:
			await _shot(dir, "map_drop_4_play%d" % turn)
			var look := InputEventMouseMotion.new()
			look.relative = Vector2(400, 0)
			Input.parse_input_event(look)
			for f in 30:
				await process_frame
	quit(0)
