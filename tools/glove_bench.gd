extends Node

## Times AwViewArms.surface_albedos (the glove-contrast fit run on every weapon draw) per weapon model:
## `godot --path . res://tools/glove_bench.tscn`. Prints `GLOVE <path> first ms / again ms`.

func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	await get_tree().process_frame
	var paths: Array = []
	for art in AwWeaponArtTable.all():
		if art.has_model() and not paths.has(art.model_path):
			paths.append(art.model_path)
	var total := 0.0
	var total_again := 0.0
	for p: Variant in paths:
		var n := AwModelCache.instantiate(String(p))
		if n == null:
			continue
		add_child(n)
		await get_tree().process_frame
		var t0 := Time.get_ticks_usec()
		var _a := AwViewArms.surface_albedos(n)
		var first := (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		_a = AwViewArms.surface_albedos(n)
		var again := (Time.get_ticks_usec() - t0) / 1000.0
		total += first
		total_again += again
		print("GLOVE %s first %.1f ms again %.1f ms" % [String(p).get_file(), first, again])
		n.queue_free()
	print("GLOVE_TOTAL %d models first %.1f ms again %.1f ms cache %s (renderer %s)" % [paths.size(), total, total_again, AwViewArms.albedo_cache, RenderingServer.get_current_rendering_method()])
	get_tree().quit()
