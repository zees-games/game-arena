extends SceneTree

const ArenaPresentation := preload("../game/arena_presentation.gd")

## The first-person view at a world field of view and a view-model one, for a sniper and a
## rifle, to look at: the check that the hands keep their size while the world widens.
##
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_fov.gd -- 90:65 110:65
##
## Arguments: `<field_of_view>[:<viewmodel_fov>]` pairs, one render each. Writes
## `screenshots/fov/<weapon>_fov<N>_vm<M>.png`.

const OUT_DIR := "screenshots/fov"

var client: Node = null


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_fov")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var args := OS.get_cmdline_user_args()
	await _wait(25.0)
	var me = client.get("player")
	me.health.invulnerable = true
	var settings = client.get("presentation").settings
	for combo in args:
		var parts := String(combo).split(":")
		var fov := int(parts[0])
		var vm := int(parts[1]) if parts.size() > 1 else DotMenuStock.VIEWMODEL_FOV
		var _r1 = settings.set_value(&"field_of_view", fov)
		var _r2 = settings.set_value(&"viewmodel_fov", vm)
		for id in [&"sniper", &"rifle"]:
			var _g = me.arsenal.give(id)
			var _s = me.arsenal.select(me.arsenal.catalogue.get_def(id).slot, 0)
			await _wait(3.5)
			var path := "%s/%s_fov%d_vm%d.png" % [OUT_DIR, id, fov, vm]
			await process_frame
			await RenderingServer.frame_post_draw
			var _saved := root.get_viewport().get_texture().get_image().save_png(path)
			print("wrote %s (camera fov %.1f, hands scale %.2f)" % [path, me.camera.fov, me.weapons.view_model().scale.x])
	quit(0)


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
