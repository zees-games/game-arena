extends SceneTree

## The real solo client with M open: one frame per page of the map picker, so a person can see
## whether the imported deathmatch maps are listed and where. `tools/screenshot.sh --map-menu [dir]`.


func _initialize() -> void:
	_run.call_deferred()


func _key(key: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = key
	e.keycode = key
	e.pressed = true
	return e


func _run() -> void:
	var dir := OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "screenshots"
	DirAccess.make_dir_recursive_absolute(dir)
	var client := (load("res://game/arena.tscn") as PackedScene).instantiate()
	root.add_child(client)
	for f in 240:
		await process_frame
		if f % 60 == 0:
			print("map_menu_shot: frame ", f)
	var menu: DotMenu = client.get(&"game_menu")
	var _o := menu.handle_event(_key(KEY_M))
	for page in 4:
		for f in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := "%s/map_menu_page%d.png" % [dir, page + 1]
		print("map_menu_shot: ", path, " ", error_string(root.get_texture().get_image().save_png(path)))
		var _n := menu.handle_event(_key(KEY_9))
	quit(0)
