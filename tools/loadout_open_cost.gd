extends Node

const ArenaPresentation := preload("../game/arena_presentation.gd")

## What pressing B costs in the offline client: the time of each phase of an open, the nodes,
## viewports and textures it creates, first open against repeat opens.
##
##   xvfb-run -a godot --path . --rendering-method gl_compatibility --rendering-driver opengl3 \
##     res://tools/loadout_open_cost.tscn -- [--opens 4]
##
## Under `--headless` nothing is drawn, so the render-target costs show only on a display (xvfb llvmpipe is a fine stand-in for the relative size).

var _client: Node = null
var _opens := 4


func _ready() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--opens":
			_opens = int(args[i + 1])
	var _scratch := ArenaPresentation.use_scratch_settings("loadout_open_cost")
	_run.call_deferred()


func _viewports(n: Node) -> int:
	var c := 1 if n is SubViewport else 0
	for k in n.get_children():
		c += _viewports(k)
	return c


func _snap() -> Dictionary:
	return {
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"viewports": _viewports(get_tree().root),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"texmem_kb": int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1024.0),
	}


func _run() -> void:
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	var gate: DotLoadGate = null
	var t_gate := Time.get_ticks_msec()
	var waited := 0.0
	while waited < 120.0:
		gate = _client.get("gate")
		if gate != null and gate.is_open():
			break
		await get_tree().create_timer(0.25, true, false, true).timeout
		waited += 0.25
	print("LOADOUT_COST gate open after %d ms" % (Time.get_ticks_msec() - t_gate))
	for _i in 120:
		await get_tree().process_frame
	var menu: Object = _client.get("loadout_menu")
	var gm: DotMenu = _client.get("game_menu")
	if menu == null or gm == null:
		print("LOADOUT_COST no loadout menu on this host")
		get_tree().quit(1)
		return
	for n in _opens:
		var before := _snap()
		var t0 := Time.get_ticks_usec()
		await menu.call(&"open")
		var t1 := Time.get_ticks_usec()
		var screen: DotMenuLoadoutScreen = gm.loadout_screen
		var mid := _snap()
		await get_tree().process_frame
		var t2 := Time.get_ticks_usec()
		await get_tree().process_frame
		var t3 := Time.get_ticks_usec()
		await get_tree().process_frame
		var t4 := Time.get_ticks_usec()
		var after := _snap()
		print("LOADOUT_COST open#%d: open() %.1f ms, frame+1 %.1f ms, +2 %.1f ms, +3 %.1f ms | nodes +%d (call) +%d (total), subviewports +%d, resources +%d, texmem +%d KB, open=%s" % [
			n + 1, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0, (t4 - t3) / 1000.0,
			int(mid["nodes"]) - int(before["nodes"]), int(after["nodes"]) - int(before["nodes"]),
			int(after["viewports"]) - int(before["viewports"]), int(after["resources"]) - int(before["resources"]),
			int(after["texmem_kb"]) - int(before["texmem_kb"]), str(screen != null and screen.is_open())])
		var d0 := Time.get_ticks_usec()
		var _d: Dictionary = menu.call(&"decorate", menu.get(&"last_offer"))
		print("LOADOUT_COST   decorate alone (all slots, warm) %.1f ms" % ((Time.get_ticks_usec() - d0) / 1000.0))
		var r0 := Time.get_ticks_usec()
		screen._rebuild()
		print("LOADOUT_COST   _rebuild alone %.1f ms (grid children %d)" % [(Time.get_ticks_usec() - r0) / 1000.0, screen._grid.get_child_count()])
		screen.close()
		for _i in 10:
			await get_tree().process_frame
	get_tree().quit(0)
