extends RefCounted

const ArenaMap := preload("arena_map.gd")

## A Workshop pack's map: a JSON document an entry's `scene` names, which is a box list like
## the built-in maps are (the map's collision, shots and picture all come from the boxes, so
## a document needs no code, and a pack that ships one is not a pack that runs any).
##
## [codeblock]
## {"schema": 1, "id": "hill", "name": "Hill", "extent": 24, "wall_height": 8,
##  "boxes": [[x, y, z, size_x, size_y, size_z], ...],
##  "spawns": [{"at": [x, y, z], "yaw": 90}, ...]}
## [/codeblock]
##
## The four perimeter walls are added, as every built-in does. A bad document is refused
## whole with the reason, never half-built: a map with no spawn drops a player at the
## origin, and one with an extent past the world the net layer quantises (512 m) teleports
## clients.

const MAX_BOXES := 512
const MAX_EXTENT := 200.0
const MAX_SPAWNS := 64


## Builds the map from [param text]. [param entry_id] is the pack entry's id, which the
## document's `id` must equal: a document that names another map would answer to the wrong
## ballot id and replace nothing but confuse everything.
static func build(text: String, entry_id: StringName) -> DotResult:
	# An instance, not JSON.parse_string: that prints an engine error for every bad document,
	# and a refusal is an answer here, reported through the result.
	var json := JSON.new()
	var parsed: Variant = json.data if text != "" and json.parse(text) == OK else null
	if not (parsed is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "the map document is empty or not a JSON object", String(entry_id))
	var doc: Dictionary = parsed
	if str(doc.get("id", "")) != String(entry_id):
		return DotResult.fail(DotError.CODE_INVALID, "the document's id is not the entry's id",
			"%s vs %s" % [str(doc.get("id", "")), entry_id])
	var extent := _number(doc.get("extent", 24.0))
	var wall := _number(doc.get("wall_height", 8.0))
	if is_nan(extent) or extent < 8.0 or extent > MAX_EXTENT:
		return DotResult.fail(DotError.CODE_INVALID, "extent must be 8 to %d" % int(MAX_EXTENT), str(doc.get("extent")))
	if is_nan(wall) or wall < 2.0 or wall > 64.0:
		return DotResult.fail(DotError.CODE_INVALID, "wall_height must be 2 to 64", str(doc.get("wall_height")))

	var map := ArenaMap.new()
	map.id = entry_id
	map.display_name = str(doc.get("name", String(entry_id)))
	map.author = str(doc.get("author", ""))
	map.extent = extent
	map.wall_height = wall

	var boxes: Variant = doc.get("boxes", [])
	if not (boxes is Array) or (boxes as Array).size() > MAX_BOXES:
		return DotResult.fail(DotError.CODE_INVALID, "boxes must be a list of at most %d" % MAX_BOXES)
	for each: Variant in (boxes as Array):
		var six := _numbers(each, 6)
		if six.is_empty() or six[3] <= 0.0 or six[4] <= 0.0 or six[5] <= 0.0:
			return DotResult.fail(DotError.CODE_INVALID, "a box is [x, y, z, size_x, size_y, size_z] with positive sizes", str(each))
		var box := AABB(Vector3(six[0], six[1], six[2]), Vector3(six[3], six[4], six[5]))
		if absf(box.position.x) > extent * 2.0 or absf(box.position.z) > extent * 2.0 or absf(box.end.x) > extent * 2.0 or absf(box.end.z) > extent * 2.0:
			return DotResult.fail(DotError.CODE_INVALID, "a box lies far outside the extent", str(each))
		var _b := map.add_box(box)
	var _p := map.add_perimeter()

	var spawns: Variant = doc.get("spawns", [])
	if not (spawns is Array) or (spawns as Array).is_empty() or (spawns as Array).size() > MAX_SPAWNS:
		return DotResult.fail(DotError.CODE_INVALID, "spawns must be a list of 1 to %d" % MAX_SPAWNS)
	for each: Variant in (spawns as Array):
		if not (each is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "a spawn is {at: [x, y, z], yaw}", str(each))
		var at := _numbers((each as Dictionary).get("at"), 3)
		var yaw := _number((each as Dictionary).get("yaw", 0.0))
		if at.is_empty() or is_nan(yaw) or absf(at[0]) >= extent or absf(at[2]) >= extent:
			return DotResult.fail(DotError.CODE_INVALID, "a spawn is inside the extent: {at: [x, y, z], yaw}", str(each))
		var basis := Basis(Vector3.UP, deg_to_rad(yaw))
		var _s := map.add_spawn(Transform3D(basis, Vector3(at[0], at[1], at[2])))
	return DotResult.success(map)


static func _number(value: Variant) -> float:
	if (value is float or value is int) and is_finite(float(value)):
		return float(value)
	return NAN


static func _numbers(value: Variant, count: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if not (value is Array) or (value as Array).size() != count:
		return out
	for item: Variant in (value as Array):
		var n := _number(item)
		if is_nan(n):
			return PackedFloat64Array()
		out.append(n)
	return out
