extends Node

## Where a solo client's draw calls, objects and primitives go, by ablation: render the same still scene with one
## category switched off at a time and print what the renderer drew (a frame's `RenderingServer.get_rendering_info`,
## which is the same number on a software GL as on a GPU; only the milliseconds differ).
## `xvfb-run -a godot --path . --rendering-driver opengl3 res://tools/draw_ablate.tscn -- --bots 3 --map crackhouse [--web 0]`.
## Web render defaults (no MSAA, 2 sun splits, 60 m sun shadows) are applied first, as the browser does; `--web 0` skips them.

const ArenaPresentation := preload("../game/arena_presentation.gd")
const RenderQuality := preload("../addons/dot_game/runtime/dot_game_render_quality.gd")

var _bots := 3
var _web := true
var _client: Node = null


func _ready() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--web": _web = args[i + 1] != "0"
	var _scratch := ArenaPresentation.use_scratch_settings("draw_ablate")
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _info() -> Array:
	return [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)]


## The lowest of three frames after four settling ones, so a stray shot or particle does not count.
func _measure(label: String, base: Array) -> Array:
	await _frames(4)
	var best: Array = []
	for i in 3:
		await _frames(1)
		var v := _info()
		if best.is_empty() or v[0] < best[0]:
			best = v
	var d0 := "" if base.is_empty() else " (%+d draws, %+d obj, %+d prims)" % [best[0] - base[0], best[1] - base[1], best[2] - base[2]]
	print("DRAW_ABLATE %-34s draws %4d  objects %4d  prims %7d%s" % [label, best[0], best[1], best[2], d0])
	return best


## How often each HUD control redraws over 120 live frames (the `draw` signal): a control that redraws every frame
## re-records its canvas commands every frame for nothing when its content did not change.
func _redraw_census() -> void:
	var counts := {}
	var hud := _client.get_node_or_null("Hud")
	if hud == null:
		return
	for n in hud.find_children("*", "Control", true, false):
		var c := n as Control
		counts[c] = 0
		var _k := c.draw.connect(func() -> void: counts[c] += 1)
	await _frames(120)
	var total := 0
	for c: Control in counts:
		total += counts[c]
		if counts[c] >= 60:
			print("DRAW_ABLATE redraws/120 frames %4d  %s" % [counts[c], hud.get_path_to(c)])
	print("DRAW_ABLATE HUD redraws in 120 frames: %d" % total)


func _hide(n: Node, label: String, base: Array) -> void:
	if not ("visible" in n):
		return
	var v: bool = n.get("visible")
	n.set("visible", false)
	await _measure("hide " + label, base)
	n.set("visible", v)


func _run() -> void:
	if _web:
		RenderQuality.values = RenderQuality.web_defaults()
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	await _frames(40)
	if _web:
		RenderQuality.apply(get_viewport(), get_tree().root)
	await _frames(20)
	await _redraw_census()
	get_tree().paused = true
	await _frames(10)
	var base := await _measure("baseline (paused)", [])
	var tops := PackedStringArray()
	for c in _client.get_children():
		tops.append("%s(%d)" % [c.name, c.get_child_count()])
	print("DRAW_ABLATE top-level nodes: %s" % ", ".join(tops))
	var lights := get_tree().root.find_children("*", "Light3D", true, false)
	var suns := get_tree().root.find_children("*", "DirectionalLight3D", true, false)
	var casters := 0
	for l in lights:
		if (l as Light3D).shadow_enabled:
			casters += 1
	print("DRAW_ABLATE lights %d (suns %d, shadow casters %d)" % [lights.size(), suns.size(), casters])
	for s in suns:
		var sun := s as DirectionalLight3D
		print("DRAW_ABLATE sun shadow=%s mode=%d dist=%.0f" % [sun.shadow_enabled, sun.directional_shadow_mode, sun.directional_shadow_max_distance])
	var was := {}
	for l in lights:
		was[l] = (l as Light3D).shadow_enabled
		(l as Light3D).shadow_enabled = false
	await _measure("no shadows (all lights)", base)
	for l in lights:
		(l as Light3D).shadow_enabled = was[l]
	for s in suns:
		(s as Light3D).shadow_enabled = false
	await _measure("no sun shadow", base)
	for s in suns:
		(s as Light3D).shadow_enabled = was[s]
	for l in lights:
		(l as Light3D).visible = false
	await _measure("no lights", base)
	for l in lights:
		(l as Light3D).visible = true
	for c in _client.get_children():
		await _hide(c, String(c.name), base)
	var hud := _client.get_node_or_null("Hud")
	if hud != null:
		for c in hud.get_children():
			await _hide(c, "Hud/%s [%d kids]" % [c.name, c.get_child_count()], base)
			if c.get_child_count() > 0 and c.get_child_count() < 12:
				for cc in c.get_children():
					await _hide(cc, "Hud/%s/%s" % [c.name, cc.name], base)
	var game := _client.get_node_or_null("Game")
	if game != null:
		for c in game.get_children():
			await _hide(c, "Game/" + String(c.name), base)
	var level := _client.find_child("Level", true, false)
	if level != null:
		for c in level.get_children():
			await _hide(c, "Level/" + String(c.name), base)
		var world := level.find_child("World", true, false)
		if world != null:
			for c in world.get_children():
				await _hide(c, "Level/World/" + String(c.name), base)
	for cam in get_tree().root.find_children("*", "Camera3D", true, false):
		for c in cam.get_children():
			await _hide(c, "Camera/" + String(c.name), base)
	var again := await _measure("baseline again", base)
	get_tree().quit(0)
