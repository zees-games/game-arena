extends SceneTree
func _initialize() -> void:
	print("debug_build ", OS.is_debug_build(), " ", Engine.get_version_info().string)
	var m0 := OS.get_static_memory_usage()
	var packed = load("res://game/arena.tscn")
	var m1 := OS.get_static_memory_usage()
	print("load MB ", (m1 - m0) / 1048576.0)
	var rows: Array = []
	var tot_src := 0
	var n := 0
	var all_gd: Array = []
	_scan("res://", all_gd)
	for p in all_gd:
		if not ResourceLoader.has_cached(p): continue
		var s: GDScript = load(p)
		var src := s.source_code.length()
		tot_src += src
		n += 1
		rows.append([src, p, s.get_script_method_list().size(), s.get_script_constant_map().size()])
	print("cached scripts ", n, " of ", all_gd.size(), " total source chars ", tot_src, " (UTF32 MB ", tot_src * 4 / 1048576.0, ")")
	rows.sort_custom(func(a, b): return a[0] > b[0])
	for i in 25: print("SRC %d KB %s methods=%d consts=%d" % [rows[i][0] / 1024, rows[i][1], rows[i][2], rows[i][3]])
	var by := {}
	for r in rows:
		var parts: PackedStringArray = (r[1] as String).split("/")
		var k: String = parts[3] if (r[1] as String).begins_with("res://addons/") else parts[2]
		by[k] = by.get(k, 0) + r[0]
	var ks := by.keys(); ks.sort_custom(func(a, b): return by[a] > by[b])
	for i in mini(30, ks.size()): print("DIR %s %d KB" % [ks[i], by[ks[i]] / 1024])
	quit(0)
func _scan(d: String, out: Array) -> void:
	for f in DirAccess.get_files_at(d):
		if f.ends_with(".gd"): out.append(d.path_join(f))
	for s in DirAccess.get_directories_at(d):
		if s.begins_with(".") : continue
		_scan(d.path_join(s), out)
