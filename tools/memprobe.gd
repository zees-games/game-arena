extends SceneTree
## Static-memory attribution for a scene: loads each dependency in file-size order, prints delta per resource and per type.
var seen := {}
var order: Array = []
func _walk(p: String) -> void:
	if seen.has(p): return
	seen[p] = true
	order.append(p)
	for d in ResourceLoader.get_dependencies(p):
		var parts: PackedStringArray = d.split("::")
		var path := parts[2] if parts.size() >= 3 and parts[2] != "" else parts[parts.size() - 1]
		if parts.size() >= 3 and parts[2] == "": path = parts[0]
		if path.begins_with("uid://"): path = ResourceUID.get_id_path(ResourceUID.text_to_id(path)) if ResourceUID.has_id(ResourceUID.text_to_id(path)) else path
		if path.begins_with("res://") and FileAccess.file_exists(path): _walk(path)
func _initialize() -> void:
	var scene := OS.get_cmdline_user_args()[0]
	var m0 := OS.get_static_memory_usage()
	_walk(scene)
	print("deps: ", order.size(), " walk cost MB ", (OS.get_static_memory_usage() - m0) / 1048576.0)
	var items: Array = []
	for p in order:
		var f := FileAccess.open(p, FileAccess.READ)
		items.append([f.get_length() if f else 0, p])
	items.sort_custom(func(a, b): return a[0] > b[0])
	var bytype := {}
	var rows: Array = []
	var base := OS.get_static_memory_usage()
	for it in items:
		var p: String = it[1]
		var b := OS.get_static_memory_usage()
		var r = load(p)
		var d := OS.get_static_memory_usage() - b
		var t := p.get_extension()
		if r: t += ":" + r.get_class()
		bytype[t] = bytype.get(t, 0) + d
		rows.append([d, p, it[0], t])
		r = null
	rows.sort_custom(func(a, b): return a[0] > b[0])
	print("TOTAL after loading deps MB ", (OS.get_static_memory_usage() - base) / 1048576.0)
	for i in mini(40, rows.size()):
		print("ROW %.2f MB  %s  (file %d KB) %s" % [rows[i][0] / 1048576.0, rows[i][1], rows[i][2] / 1024, rows[i][3]])
	for k in bytype: print("TYPE %s %.2f MB" % [k, bytype[k] / 1048576.0])
	var b2 := OS.get_static_memory_usage()
	var ps: PackedScene = load(scene)
	print("scene load after deps: ", (OS.get_static_memory_usage() - b2) / 1048576.0, " total static MB ", OS.get_static_memory_usage() / 1048576.0)
	quit(0)
