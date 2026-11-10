extends Node

const ArenaFrameProbe := preload("../game/arena_frame_probe.gd")
const ArenaPresentation := preload("../game/arena_presentation.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ClientBench := preload("client_bench.gd")
const ArenaKillcamBodies := preload("../game/arena_killcam_bodies.gd")

## What the CLIENT costs per remote player in one offline process: the frame, engine process time, each client section in ms per frame and per remote player, and a node census.
## `godot --headless --path . res://tools/client_cost.tscn -- --bots 16 --seconds 15 [--map dm_atrium] [--variants default,full]`; variants `before`, `default`, `off8`, `full`, `no_anim`/`no_held`/`no_held_proc`/`no_rest`/`bare` (`full` less that part, `ArenaPlayer.present_ablate`), `still` (remotes not presented).
## Headless draws nothing: this is script and scene-tree cost; render cost needs a windowed GPU profile.

var _bots := 16
var _seconds := 15.0
var _variants: PackedStringArray = ["before", "default", "full", "bare"]
var _client: Node = null
var _rounds := 3


func _ready() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--variants": _variants = args[i + 1].split(",")
			"--rounds": _rounds = maxi(1, int(args[i + 1]))
	var _scratch := ArenaPresentation.use_scratch_settings("client_cost")
	_run.call_deferred()


func _run() -> void:
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	var _warmed := AwModelCache.warm(AwWeaponArtTable.model_paths())
	var pilot := ClientBench.Pilot.new()
	pilot.process_priority = -999
	add_child(pilot)
	ArenaFrameProbe.set_interval(1.0e9)
	await _frames_for(8.0)
	var remotes := 0
	for p: ArenaPlayer in _client.game.players():
		if p.camera == null:
			remotes += 1
	print("CLIENT_COST bots %d remotes %d" % [_bots, remotes])
	_census()
	# Interleaved rounds, so a machine that speeds up or slows down mid-run hits every variant alike.
	var acc := {}
	for round_i in _rounds:
		for v in _variants:
			_apply(v)
			await _frames_for(1.5)
			var got := await _measure(_seconds / _rounds)
			if not acc.has(v):
				acc[v] = {"proc": PackedFloat64Array(), "frame": PackedFloat64Array(), "sections": {}, "n": 0}
			var a_v: Dictionary = acc[v]
			a_v.proc.append_array(got.proc)
			a_v.frame.append_array(got.frame)
			a_v.n += got.proc.size()
			for key: StringName in got.sections:
				a_v.sections[key] = a_v.sections.get(key, 0.0) + got.sections[key]
	_apply("default")
	_report(acc, remotes)
	get_tree().quit(0)


func _apply(variant: String) -> void:
	# "before" is the game as it was: the cone, a kill-cam recording every frame. "default" is the game as it ships now.
	ArenaPlayer.lod_frustum = variant != "before"
	ArenaPlayer.lod_off_every = 8 if variant == "off8" else 4
	ArenaKillcamBodies.record_hz = 0.0 if variant == "before" else 60.0
	ArenaPlayer.present_lod_enabled = variant in ["default", "before", "off8"]
	ArenaPlayer.present_remote_paused = variant == "still"
	# "full" with one part of the remote presentation left out: the cost of that part alone.
	ArenaPlayer.present_ablate = {"no_anim": 1, "no_held": 2, "no_held_proc": 6, "no_rest": 8, "bare": 15}.get(variant, 0)
	if variant in ["default", "before", "off8", "full"]:
		for p: ArenaPlayer in _client.game.players():
			if p.held != null:
				p.held.set_process(true)


func _frames_for(seconds: float) -> void:
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) / 1.0e6 < seconds:
		await get_tree().process_frame


func _measure(seconds: float) -> Dictionary:
	ArenaFrameProbe._reset()
	var frames := PackedFloat64Array()
	var proc := PackedFloat64Array()
	var t0 := Time.get_ticks_usec()
	var last := t0
	while (last - t0) / 1.0e6 < seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	var sections := {}
	for key: StringName in ArenaFrameProbe._sections:
		var row: PackedInt64Array = ArenaFrameProbe._sections[key]
		sections[key] = float(row[0]) / 1000.0
	return {"proc": proc, "frame": frames, "sections": sections}


static func _median(values: PackedFloat64Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2] if sorted.size() > 0 else 0.0


func _report(acc: Dictionary, remotes: int) -> void:
	var r := maxf(float(remotes), 1.0)
	var bare: float = _median(acc["bare"].proc) if acc.has("bare") else NAN
	for v: String in _variants:
		var a: Dictionary = acc[v]
		var n: int = a.n
		var mean := 0.0
		for f in a.frame:
			mean += f
		mean /= maxi(n, 1)
		var med := _median(a.proc)
		var extra := ""
		if not is_nan(bare):
			extra = " | over bare %.2f ms = %.3f ms per remote" % [med - bare, (med - bare) / r]
		print("  [%s] fps %.1f (frame mean %.2f p50 %.2f) | engine process median %.2f ms/frame%s" % [v, 1000.0 / mean, mean, _median(a.frame), med, extra])
		var keys: Array = a.sections.keys()
		keys.sort()
		for key: StringName in keys:
			if String(key).begins_with("bot") or String(key).begins_with("tick") or String(key).begins_with("p_") or key in [&"physics", &"game_tick", &"bots"]:
				continue
			var per_frame: float = a.sections[key] / n
			print("      %-16s %7.3f ms/frame  %7.4f ms/remote" % [key, per_frame, per_frame / r])


## Nodes, meshes, lights, skeletons and processing nodes under one remote player (the render-side bill the headless run cannot time).
func _census() -> void:
	for p: ArenaPlayer in _client.game.players():
		if p.camera != null:
			continue
		var c := {"nodes": 0, "meshes": 0, "lights": 0, "skeletons": 0, "processing": 0, "particles": 0, "audio": 0, "visible_meshes": 0}
		_count(p, c)
		print("  census per remote: ", c)
		return


func _count(node: Node, c: Dictionary) -> void:
	c.nodes += 1
	if node.is_processing() or node.is_physics_processing():
		c.processing += 1
	if node is MeshInstance3D:
		c.meshes += 1
		if (node as MeshInstance3D).is_visible_in_tree():
			c.visible_meshes += 1
	elif node is Light3D:
		c.lights += 1
	elif node is Skeleton3D:
		c.skeletons += 1
	elif node is GPUParticles3D:
		c.particles += 1
	elif node is AudioStreamPlayer3D:
		c.audio += 1
	for ch in node.get_children():
		_count(ch, c)
