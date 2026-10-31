extends SceneTree

## The offline client's M map picker, to see which maps it offers (the delivered surf packs included).
##
##   xvfb-run -a godot --path . --resolution 1920x1080 --script tools/render_maps.gd

const ArenaPresentation := preload("../game/arena_presentation.gd")

const OUT_DIR := "screenshots/maps"

var client: Node = null
var _failed := 0


func _initialize() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_maps")
	var scene: PackedScene = load("res://game/arena.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait_gate(40.0)
	var rows: Array = client.call(&"map_menu_rows")
	var surf := 0
	for r: Variant in rows:
		if str((r as Dictionary).get("id", "")).begins_with("map:surf_"):
			surf += 1
	print("  picker rows %d, surf maps %d" % [rows.size(), surf])
	_check(surf > 0, "the picker lists surf maps")
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	Input.parse_input_event(m)
	await _wait(0.8)
	await _shot("arena_map_picker")
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


## Polls the client's load gate until it is open (capped): a fixed wait shows the cover on a loaded box.
func _wait_gate(cap: float) -> void:
	var gate: DotLoadGate = client.get("gate")
	var waited := 0.0
	while (gate == null or not gate.is_open()) and waited < cap:
		await _wait(0.25)
		waited += 0.25
		gate = client.get("gate")
	_check(gate != null and gate.is_open(), "load gate open after %.1f s" % waited)
	await _wait(1.0)


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
