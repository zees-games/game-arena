extends SceneTree

## The real solo client with the period key pressed: the team menu as a player opens it. `tools/screenshot.sh --team-menu-key [out.png]`.
## With `--unwired` a bare DotMenu with no server or offer: the free-for-all fallback (Play, Spectate).


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var unwired := "--unwired" in args
	var out := "screenshots/teams_period.png"
	for a in args:
		if not a.begins_with("--"):
			out = a
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var menu: DotMenu = null
	var client: Node = null
	if unwired:
		var back := ColorRect.new()
		back.color = Color(0.1, 0.12, 0.16)
		back.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.add_child(back)
		menu = DotMenu.new()
		root.add_child(menu)
		var _t := menu.use_teams()
	else:
		client = (load("res://game/arena.tscn") as PackedScene).instantiate()
		root.add_child(client)
		for f in 240:
			await process_frame
		menu = client.get(&"game_menu")
	var e := InputEventKey.new()
	e.physical_keycode = KEY_PERIOD
	e.keycode = KEY_PERIOD
	e.pressed = true
	print("team_menu_period_shot: handled=", menu.handle_event(e), " teams_wired=", menu.teams != null)
	for f in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	print("team_menu_period_shot: ", out, " ", error_string(root.get_texture().get_image().save_png(out)), " last_offer ffa=", menu.teams.last_offer.get("ffa") if menu.teams != null else "n/a")
	quit(0)
