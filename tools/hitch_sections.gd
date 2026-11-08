extends "offline_cost.gd"

## offline_cost with a per-frame hitch breakdown: every frame over `--hitch MS` (default 150)
## prints which ArenaFrameProbe sections grew in it, the physics and process monitors, and the
## node count change, so a periodic stall is named by the section that holds it:
## `godot --headless --path . res://tools/hitch_sections.tscn -- --map cp-orange-x3 --bots 31 --seconds 40`.

var _hitch_ms := 150.0
var _prev_rows := {}
var _prev_nodes := 0
var _prev_usec := 0
var _listed := 0
var _census_at := 0
var _last_census := {}
var _prev_orphans := 0
var _legacy := false
const ArenaHud := preload("../game/arena_hud.gd")


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--hitch")
	if i >= 0 and i + 1 < args.size():
		_hitch_ms = float(args[i + 1])
	# `--legacy`: the lag16 caps off, so one build measures before and after.
	if args.has("--legacy"):
		ArenaPlayer.held_equips_per_frame = 0
		ArenaHud.ArenaHudGlance.PortraitCache.builds_per_frame = 0
		ArenaHud.ArenaHudGlance.PortraitCache.keep_extra = 0
		AwViewArms.albedo_cache = false
		ArenaPresentation.fx_pool_idle = -1
		AwWeaponCatalogue.def_cache = false
		_legacy = true
	super._ready()
	print("LAG16 legacy=%s held_equips=%d fx_pool_idle=%d glove_cache=%s def_cache=%s portraits=%d/%d" % [_legacy,
		ArenaPlayer.held_equips_per_frame, ArenaPresentation.fx_pool_idle, AwViewArms.albedo_cache, AwWeaponCatalogue.def_cache,
		ArenaHud.ArenaHudGlance.PortraitCache.builds_per_frame, ArenaHud.ArenaHudGlance.PortraitCache.keep_extra])
	_watch.call_deferred()


func _watch() -> void:
	while is_inside_tree():
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - _prev_usec) / 1000.0 if _prev_usec > 0 else 0.0
		_prev_usec = now
		var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var rows: Dictionary = ArenaFrameProbe._sections
		if ms >= _hitch_ms and _listed < 80:
			_listed += 1
			var grew: Array = []
			for key: StringName in rows:
				var row: PackedInt64Array = rows[key]
				var was: PackedInt64Array = _prev_rows.get(key, PackedInt64Array([0, 0, 0]))
				var d := float(row[0] - was[0]) / 1000.0
				if d >= 1.0:
					grew.append([d, key, row[1] - was[1]])
			grew.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
			var text := PackedStringArray()
			for g in grew.slice(0, 10):
				text.append("%s %.1fms x%d" % [g[1], g[0], g[2]])
			print("HITCH t=%.2fs %.1f ms phys %.1f proc %.1f nodes %+d orphans %d | %s" % [
				now / 1.0e6, ms, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, nodes - _prev_nodes,
				int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)), ", ".join(text)])
		var orphans := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
		if orphans - _prev_orphans >= 40:
			_orphan_census()
		_prev_orphans = orphans
		if now - _census_at > 10_000_000:
			_census_at = now
			_census()
		_prev_nodes = nodes
		_prev_rows.clear()
		for key: StringName in rows:
			_prev_rows[key] = (rows[key] as PackedInt64Array).duplicate()



## Which kinds of node the tree holds, by class and parent name, and how that changed since the last census.
func _census() -> void:
	var counts := {}
	_count_under(get_tree().root, counts)
	var rows: Array = []
	for k: String in counts:
		rows.append([int(counts[k]) - int(_last_census.get(k, 0)), k, counts[k]])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return absi(a[0]) > absi(b[0]))
	var text := PackedStringArray()
	for r in rows.slice(0, 14):
		if r[0] != 0:
			text.append("%s %+d (%d)" % [r[1], r[0], r[2]])
	print("CENSUS t=%.1fs nodes %d | %s" % [Time.get_ticks_usec() / 1.0e6, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), ", ".join(text)])
	_last_census = counts


func _count_under(node: Node, counts: Dictionary) -> void:
	var parent := node.get_parent()
	var key := "%s<%s" % [node.get_class(), String(parent.name).left(24) if parent != null else "-"]
	counts[key] = int(counts.get(key, 0)) + 1
	for c in node.get_children(true):
		_count_under(c, counts)


## The orphan nodes by class and, for the roots of orphaned subtrees, their name and script.
func _orphan_census() -> void:
	if not ClassDB.class_has_method(&"Node", &"get_orphan_node_ids"):
		print("ORPHANS (no get_orphan_node_ids)")
		return
	var ids: Array = ClassDB.class_call_static(&"Node", &"get_orphan_node_ids")
	var by_class := {}
	var roots := {}
	for id: int in ids:
		var n := instance_from_id(id) as Node
		if n == null:
			continue
		by_class[n.get_class()] = int(by_class.get(n.get_class(), 0)) + 1
		if n.get_parent() == null:
			var sc: Script = n.get_script()
			var key := "%s:%s:%s" % [n.get_class(), String(n.name).left(30), sc.resource_path.get_file() if sc != null else ""]
			roots[key] = int(roots.get(key, 0)) + 1
	print("ORPHANS t=%.1fs %d | classes %s | roots %s" % [Time.get_ticks_usec() / 1.0e6, ids.size(), JSON.stringify(by_class), JSON.stringify(roots).left(1500)])
