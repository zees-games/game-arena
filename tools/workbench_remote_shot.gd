extends SceneTree

const ArenaConfig := preload("../game/arena_config.gd")
const ArenaGame := preload("../game/arena_game.gd")

## Renders the remote admin's tuning panel (what an admin sees on a server that allows `sv_workbench_remote`) to
## res://screenshots/workbench_remote.png. Run under xvfb-run: tools/workbench_remote_shot.sh


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var net := DotNetManager.new()
	net.is_server = false
	net.local_peer_id = 5
	net.config_file = ""
	var _s := net.setup()
	var client := DotGameWorkbenchRemoteClient.attach(net)
	var wb := DotGameWorkbench.new()
	wb.remote_client = client
	wb.remote_fn = func() -> bool: return true
	var binder := ArenaConfig.make_binder(ArenaGame.new().config)
	var _l := binder.load_layers()
	for set: DotProfileSet in binder.profile_sets():
		wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	root.add_child(wb)
	var started := wb.start(DotProfileRuntime.new())
	var told := DotGameWorkbenchMessage.new()
	told.kind = DotGameWorkbenchMessage.KIND_ACCESS
	told.allowed = true
	told.flags = "cvar,root"
	client.handle_message(told)
	await _frames(3)
	wb.toggle()
	await _frames(6)
	var img := root.get_viewport().get_texture().get_image()
	var saved := img.save_png(ProjectSettings.globalize_path("res://screenshots/workbench_remote.png"))
	print("started=%s panel=%s open=%s saved=%d" % [started.ok, wb.overlay != null, wb.is_open(), saved])
	quit(0 if started.ok and wb.overlay != null and wb.is_open() else 1)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame
