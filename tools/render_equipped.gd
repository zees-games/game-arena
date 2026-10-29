extends SceneTree

## The real offline flow, two frames: the local player's first-person hands, then a bot's held weapon from a debug camera.
## Written to screenshots/equipped_{view,bot}.png; proves the equipped weapon is the weapon pack's art, not zee's stand-in.
##
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_equipped.gd

const ArenaPresentation := preload("../game/arena_presentation.gd")

var client: Node = null


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_equipped")
	client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _run() -> void:
	DirAccess.make_dir_recursive_absolute("screenshots")

	for i in 600:
		await _wait(0.1)
		var p: Object = client.get("player")
		var g: Object = client.get("game")
		if p != null and g != null and p.is_alive() and g.match_node != null and g.match_node.state == DotMatch.State.LIVE:
			break

	await _wait(4.0)
	var me = client.get("player")
	me.health.invulnerable = true
	print("SELECT ", me.arsenal.select(3, Engine.get_physics_frames()))
	await _wait(2.5)
	var def = me.arsenal.current_def()
	var art = ZeeWeaponArtTable.table().get(def.id)
	print("EQUIPPED ", def.id, " model=", art.model_path if art else "none")
	(await _grab("screenshots/equipped_view.png"))

	# Its own viewport, so the player's camera and view model do not take the frame back.
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.world_3d = root.world_3d
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)

	for other in client.get("game").players():
		if other == me or other.held == null or other.held.equipped() == &"":
			continue
		var bart = ZeeWeaponArtTable.table().get(other.held.equipped())
		print("BOT ", other.name, " holds ", other.held.equipped(), " model=", bart.model_path if bart else "none")
		var at: Vector3 = other.held.global_position
		cam.global_position = at + Vector3(0.9, 0.3, 0.9)
		cam.look_at(at, Vector3.UP)
		cam.fov = 40.0
		cam.make_current()
		await _wait(0.5)
		vp.get_texture().get_image().save_png("screenshots/equipped_bot.png")
		break
	quit()


func _grab(path: String) -> void:
	await _wait(0.5)
	root.get_texture().get_image().save_png(path)
