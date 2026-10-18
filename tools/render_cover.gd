extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")

## Two frames of a real client on a real server, to look at: the loading cover while the
## server still holds the seat as loading, and the first frame after the cover lifts.
## A dedicated arena server runs in a second process (client_bench's server role).
##
## [codeblock]
## xvfb-run -a godot --path . --resolution 1280x720 res://tools/render_cover.tscn
## [/codeblock]
## Writes screenshots/cover_up.png and screenshots/cover_lifted.png.

const PORT := 27199

var _server_pid := -1


func _ready() -> void:
	var _scratch := ArenaPresentation.use_scratch_settings("render_cover")
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://screenshots/%s.png" % name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	print("render_cover: %s %s" % [path, image.save_png(path)])


func _run() -> void:
	_server_pid = OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://tools/client_bench.tscn", "--", "--role", "server", "--port", str(PORT),
		"--bots", "2"]))
	await get_tree().create_timer(6.0).timeout

	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Cover"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	add_child(link)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var t := 0.0
	while not link.is_playing() and t < 30.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25

	var client: Node = (load("res://game/arena.tscn") as PackedScene).instantiate()
	client.set("mouse_capture_override", true)
	add_child(client)
	for i in 3:
		await get_tree().process_frame
	var gate: DotLoadGate = client.get("gate")
	print("render_cover: gate open at the first shot: ", gate.is_open() if gate != null else "no gate")
	await _shot("cover_up")

	t = 0.0
	while gate != null and not gate.is_open() and t < 40.0:
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	for i in 3:
		await get_tree().process_frame
	print("render_cover: lifted after %.1f s" % t)
	await _shot("cover_lifted")
	await get_tree().create_timer(1.0).timeout
	await _shot("cover_after_1s")
	link.disconnect_from_server("done")
	if _server_pid > 0:
		var _k := OS.kill(_server_pid)
	get_tree().quit(0)
