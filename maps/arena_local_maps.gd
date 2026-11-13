extends RefCounted

## Maps copied in by hand: a raw convert folder under `res://addons/maps/<map>/` or `user://maps/<map>/`, found by dot-map's
## [code]DotMapLocalMaps[/code] as `<name>_local`. Solo only: the catalogue lists them when [code]ArenaMaps.list_local[/code] is on
## (a solo client and its sim host), and no server rotation, vote or pack ever names one.
##
## The folder is dot-map's own mesh format, not the legacy manifest [code]ArenaImportedMaps[/code] reads, so the map's
## spawns, bounds and solid come from the mesh here and its drawing from [code]ArenaBspMap.world_prefix[/code], which
## answers a local id with its folder.

const CHANNEL := "arena.maps"

## prefix -> {version, mesh}: the listing and the load read the same copy once, and a re-converted copy (a new version) is read again.
static var _meshes: Dictionary = {}


## Whether [param id] names a local copy (it ends in [code]DotMapLocalMaps.ID_SUFFIX[/code]).
static func is_local(id: StringName) -> bool:
	return String(id).ends_with(DotMapLocalMaps.ID_SUFFIX)


## Every local map found now, sorted by id.
static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for entry: Dictionary in DotMapLocalMaps.scan():
		out.append(StringName(str(entry["id"])))
	return out


## The entry for [param id], or empty.
static func entry(id: StringName) -> Dictionary:
	return DotMapLocalMaps.find(id) if is_local(id) else {}


## The mesh prefix of local map [param id] when it lives in [param map_dir], else empty.
static func prefix_in(id: String, map_dir: String) -> String:
	if map_dir.is_empty() or not is_local(StringName(id)):
		return ""
	var prefix := map_dir.path_join(id.trim_suffix(DotMapLocalMaps.ID_SUFFIX))
	return prefix if FileAccess.file_exists(prefix + ".json") and FileAccess.file_exists(prefix + ".bin") else ""


## The read mesh of [param found], or null when it does not load (dot-map logs why).
static func mesh(found: Dictionary) -> DotMapBspMesh:
	var prefix := str(found.get("prefix", ""))
	var version := DotMapLocalMaps.version_of(found)
	var cached: Dictionary = _meshes.get(prefix, {})
	if not cached.is_empty() and str(cached["version"]) == version:
		return cached["mesh"]
	var opened := DotMapLocalMaps.open(found)
	if not opened.ok:
		return null
	_meshes[prefix] = {"version": version, "mesh": opened.value}
	return opened.value


## The space the world's solid hulls fill, in metres.
static func bounds_of(got: DotMapBspMesh) -> AABB:
	var box := AABB()
	var first := true
	var origin := got.model_origin(DotMapBspMesh.WORLD)
	for hull: Dictionary in got.hull_shapes(DotMapBspMesh.WORLD):
		for p in (hull["shape"] as ConvexPolygonShape3D).points:
			if first:
				box = AABB(p + origin, Vector3.ZERO)
				first = false
			else:
				box = box.expand(p + origin)
	return box


## The start points as transforms with their tags: `{at, tag}` each, a tag of "" for a spot any side may use.
static func spawns_of(got: DotMapBspMesh) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for spot: Dictionary in DotMapLocalMaps.spawns(got):
		var team := str(spot["team"])
		out.append({
			"at": Transform3D(Basis(Vector3.UP, deg_to_rad(float(spot["yaw"]))), spot["origin"]),
			"tag": "" if team == "any" else team,
		})
	return out


## The world's solid: one body with every player-solid hull of the world model plus the solid props, mask 0 like
## the legacy solid ([code]ArenaBspMap.build_collision[/code]). Doors and lifts are the drawn world's movers.
static func build_collision(prefix: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "ImportedSolid"
	body.collision_mask = 0
	var found := DotMapLocalMaps.entry_at(prefix.get_base_dir())
	var got := mesh(found) if not found.is_empty() else null
	if got == null:
		DotLog.error(CHANNEL, "a local map's solid is missing", {"prefix": prefix})
		return body
	var origin := got.model_origin(DotMapBspMesh.WORLD)
	for hull: Dictionary in got.hull_shapes(DotMapBspMesh.WORLD):
		var shape := CollisionShape3D.new()
		shape.shape = hull["shape"]
		shape.position = origin
		body.add_child(shape)
	var props := got.build_prop_collision()
	if props != null:
		props.collision_mask = 0
		body.add_child(props)
	return body
