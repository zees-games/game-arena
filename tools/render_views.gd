extends SceneTree

## The offline client in first person, then third person through the view key's own path,
## then under a server's `mp_forceview 1`: a frame of each and a line saying what the
## client did. The check behind the view toggle (dot-player-controller's
## `DotPlayerViewRules`); the camera itself is checked by `render_cameras`.
##
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_views.gd

const ArenaPresentation := preload("../game/arena_presentation.gd")

const OUT_DIR := "screenshots/cameras"

var client: Node = null
var _failed := 0


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_views")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(6.0)
	var me = client.get("player")
	var game = client.get("game")
	me.health.invulnerable = true

	_check(not me.third_person, "starts in first person")
	await _shot("arena_view_first")

	client.call("toggle_view")
	await _wait(0.6)
	_check(me.third_person, "the view key puts the player in third person")
	_check(not me.weapons.view_model().visible, "with no view model")
	_check(me.body_mesh != null and me.body_mesh.visible, "and their own body drawn")
	var behind: float = (me.camera.global_position - me.view.global_position).length()
	_check(behind > 0.5, "the camera is behind the eye (%.2f m)" % behind)
	await _shot("arena_view_third")

	game.view_rules.force_view = DotPlayerViewRules.FIRST_ONLY
	await _wait(0.3)
	_check(not me.third_person, "mp_forceview 1 puts them back in first person")
	client.call("toggle_view")
	await _wait(0.3)
	_check(not me.third_person, "and the view key does nothing")
	await _shot("arena_view_forced_first")

	game.view_rules.force_view = DotPlayerViewRules.THIRD_ONLY
	await _wait(0.3)
	_check(me.third_person, "mp_forceview 2 holds third person")

	print("%d failed" % _failed)
	quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


func _shot(file: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var path := "%s/%s.png" % [OUT_DIR, file]
	var _saved := root.get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
