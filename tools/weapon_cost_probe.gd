extends SceneTree

## Times the client's boot-time weapon warm list and counts each weapon model's triangles.
## `godot --headless --path . -s res://tools/weapon_cost_probe.gd`.


func _initialize() -> void:
	preload("../game/arena_weapon_roles.gd").ensure()
	var paths := AwWeaponArtTable.model_paths()
	var total_tris := 0
	var rows: Array = []
	var t0 := Time.get_ticks_usec()
	for path in paths:
		var t := Time.get_ticks_usec()
		var model := AwModelCache.instantiate(path)
		var ms := (Time.get_ticks_usec() - t) / 1000.0
		if model == null:
			continue
		var tris := 0
		var surfaces := 0
		for n in model.find_children("*", "MeshInstance3D", true, false):
			var mesh := (n as MeshInstance3D).mesh
			if mesh == null:
				continue
			for s in mesh.get_surface_count():
				surfaces += 1
				var arr := mesh.surface_get_arrays(s)
				var idx: Variant = arr[Mesh.ARRAY_INDEX]
				tris += ((idx as PackedInt32Array).size() if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
		total_tris += tris
		rows.append([tris, surfaces, ms, path])
		model.free()
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	print("WEAPON_COST %d models, load+instantiate %.0f ms, %d triangles in all" % [rows.size(), (Time.get_ticks_usec() - t0) / 1000.0, total_tris])
	for r: Array in rows:
		print("  %8d tris %3d surf %7.1f ms  %s" % r)
	quit(0)
