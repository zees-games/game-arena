extends "arena_map_part2.gd"

## An imported map by id, built from its manifest, or null.
##
## [b]A fresh object every call, like the built-ins.[/b] What it holds per instance —
## [member collision_root] above all — belongs to the one game that loaded it, and a
## shared instance would hand a second game in the same process (a suite runs several)
## the first one's solid.
##
## [b]`extent` and `floor_y` are derived, and only the generic layers read them[/b]: the
## half-width of the space the map occupies, round the origin, and the bottom of it. The
## monster navigation, the objective layout and the scattered props are built from them
## and from `boxes`, which an imported map does not have, so `ArenaMaps.supports_mode`
## keeps those modes off it rather than letting them build a layout out of nothing.
## [param light] stops after what a listing reads (name, author, bounds, spawns and their tags, the modes, the movement): no pits, jail or mechanics, which a catalogue of sixty maps would build and discard (about a third of the time a cold catalogue takes).
static func imported(map_id: StringName, light: bool = false) -> ArenaMap:
	if ArenaLocalMaps.is_local(map_id):
		return local(map_id, light)

	var manifest := ArenaImportedMaps.manifest(map_id)

	if manifest.is_empty():
		return null

	var map := ArenaMap.new()
	map.id = map_id
	map.display_name = String(map_id)
	map.manifest_path = ArenaImportedMaps.manifest_path(map_id)
	map.source_kind = str(manifest.get("kind", ""))
	map.author = str(manifest.get("author", ""))
	# Surf maps get the genre's air control; the deathmatch maps (fc-dm-maps) are walked.
	map.movement_profile = ArenaImportedMaps.movement_of(map_id) if map.source_kind == ArenaImportedMaps.KIND else &""
	map.bounds = ArenaBspMap.bounds_of(manifest)
	map.floor_y = map.bounds.position.y
	map.wall_height = map.bounds.size.y
	map.extent = maxf(
		maxf(absf(map.bounds.position.x), absf(map.bounds.end.x)),
		maxf(absf(map.bounds.position.z), absf(map.bounds.end.z))
	)

	var tags := ArenaBspMap.spawn_tags_of(manifest)
	var at_index := 0

	for at in ArenaBspMap.spawns_of(manifest):
		var _m := map.add_spawn(at, StringName(tags[at_index] if at_index < tags.size() else ""))
		at_index += 1

	map.flag_homes = ArenaBspMap.flag_homes_of(manifest)
	map.modes = PackedStringArray(manifest.get("modes", []))

	if light:
		return map

	map.pits = ArenaBspMap.pits_of(manifest)
	map.jail = ArenaJail.detect(map.pits)
	map.mechanics = ArenaMapMechanics.new()
	map.mechanics.read(manifest)
	return map

## A map copied in by hand ([code]ArenaLocalMaps[/code]), or null when there is none by that id or it does not load.
## It has no pits, jail, mechanics or listed modes: a raw convert carries none of the legacy manifest's extras.
static func local(map_id: StringName, light: bool = false) -> ArenaMap:
	var found := ArenaLocalMaps.entry(map_id)
	var got: DotMapBspMesh = ArenaLocalMaps.mesh(found) if not found.is_empty() else null

	if got == null:
		return null

	var map := ArenaMap.new()
	map.id = map_id
	map.display_name = str(found["title"])
	map.local_prefix = str(found["prefix"])
	map.manifest_path = map.local_prefix + ".json"
	map.source_kind = String(found["kind"])
	map.movement_profile = &"surf" if found["kind"] == DotMapDef.KIND_SURF else &""
	map.bounds = ArenaLocalMaps.bounds_of(got)
	map.floor_y = map.bounds.position.y
	map.wall_height = map.bounds.size.y
	map.extent = maxf(
		maxf(absf(map.bounds.position.x), absf(map.bounds.end.x)),
		maxf(absf(map.bounds.position.z), absf(map.bounds.end.z))
	)

	for spot: Dictionary in ArenaLocalMaps.spawns_of(got):
		var _m := map.add_spawn(spot["at"], StringName(str(spot["tag"])))

	if not light:
		map.mechanics = ArenaMapMechanics.new()
	return map

## Every map this game ships, by id.
##
## [b]A function rather than a constant array, because a map is 40-odd boxes and an
## array of them is 40-odd boxes built at load time for the one the server is not
## running.[/b] `ids()` is the cheap half — a menu, a `arena_maps` listing and a
## validity check all want the names and none of them want the geometry.
static func by_id(id: StringName) -> ArenaMap:
	var found: ArenaMap = _by_id_bare(id)
	# Tests only: a map set up by id (a map change) gets the placements a test registered,
	# since no deathmatch map carries toys of its own.
	if found != null and test_toys.has(id):
		found.toys = (test_toys[id] as Array).duplicate(true)
	return found

## Toys by map id that [method by_id] adds. Empty always, outside a test (see ArenaTestToys).
static var test_toys: Dictionary = {}

static func _by_id_bare(id: StringName) -> ArenaMap:
	match id:
		&"dm_box":
			return dm_box()
		&"dm_atrium":
			return dm_atrium()
		&"dm_pit":
			return dm_pit()

	# Not one of ours: an imported map, if one by that id was found, else nothing.
	return imported(id)

## [method by_id] for a listing: an imported map comes without its pits, jail and mechanics (see [method imported]). Not for playing.
static func listing_by_id(id: StringName) -> ArenaMap:
	if id in ids():
		return by_id(id)
	return imported(id, true)

## The ids [method by_id] answers to, in rotation order.
##
## Kept beside `by_id` and not derived from it, which is the one duplication here worth
## having: a map added to one and not the other is a map that either cannot be listed or
## cannot be loaded, and `headless_match` checks the two agree.
static func ids() -> Array[StringName]:
	return [&"dm_box", &"dm_atrium", &"dm_pit"]

## The imported maps [method by_id] also answers to: every combat surf map found under the
## link, discovered rather than listed (see `ArenaImportedMaps`). Empty without the link.
static func imported_ids() -> Array[StringName]:
	return ArenaImportedMaps.ids()

## Adds a spawn and its tag together, which is the only way to add one.
##
## An empty tag means "any team". Tagging SOME spawns and not others is legal and
## useful: the untagged ones are a shared pool both sides can fall back to when their
## own are all on cooldown, which `DotSpawnSelector._fallback` will do rather than
## refuse to spawn anybody.
func add_spawn(at: Transform3D, tag: StringName = &"") -> ArenaMap:
	spawns.append(at)
	spawn_tags.append(String(tag))
	return self

## Tags this map's spawns for two sides when it has none of its own, and returns how many it tagged.
##
## [b]The fallback for a team mode on a map that does not say which spots are whose[/b] (every imported
## BSP map: the converter writes no sides, and a mapper's `info_player_teamspawn` is not read). With no
## `red` or no `blue` spawn, all spawns are cut into two halves by position: the two spawns
## furthest apart are the sides' anchors (the first is the furthest from the centroid, the second the
## furthest from the first), each spawn goes to the nearer anchor's side by its difference of distances,
## and the list is split at the median. An odd count leaves the middle spawn untagged, a shared point
## either side may use. The red half is the one holding the first anchor; both halves are the same size.
##
## A map that tags at least one spawn for each side keeps its own tags untouched (return 0), and so does
## one with fewer than two spawns. Idempotent. Free-for-all never calls it and stays random.
func split_spawns_for_teams() -> int:
	var red := 0
	var blue := 0
	for tag in spawn_tags:
		if tag == "red":
			red += 1
		elif tag == "blue":
			blue += 1
	if red > 0 and blue > 0:
		return 0
	if spawns.size() < 2:
		return 0
	var centroid := Vector3.ZERO
	for at in spawns:
		centroid += at.origin
	centroid /= float(spawns.size())
	var first := 0
	for i in range(spawns.size()):
		if spawns[i].origin.distance_squared_to(centroid) > spawns[first].origin.distance_squared_to(centroid) + 0.0001:
			first = i
	var second := 0 if first != 0 else 1
	for i in range(spawns.size()):
		if spawns[i].origin.distance_squared_to(spawns[first].origin) > spawns[second].origin.distance_squared_to(spawns[first].origin) + 0.0001:
			second = i
	var order: Array = []
	for i in range(spawns.size()):
		var lean := spawns[i].origin.distance_to(spawns[first].origin) - spawns[i].origin.distance_to(spawns[second].origin)
		order.append([lean, i])
	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	while spawn_tags.size() < spawns.size():
		spawn_tags.append("")
	var half := spawns.size() / 2
	var tagged := 0
	for n in range(order.size()):
		var index: int = order[n][1]
		if n < half:
			spawn_tags[index] = "red"
		elif n >= order.size() - half:
			spawn_tags[index] = "blue"
		else:
			continue
		tagged += 1
	return tagged

## The spawn indices each team may use, `{1: red, 2: blue}`: its own tag plus the untagged (shared) ones.
func team_spawn_sets() -> Dictionary:
	var out := {1: [], 2: []}
	for i in range(spawns.size()):
		var tag := String(spawn_tag(i))
		if tag != "blue":
			out[1].append(i)
		if tag != "red":
			out[2].append(i)
	return out

## The tag of spawn [param index], or empty.
func spawn_tag(index: int) -> StringName:
	if index < 0 or index >= spawn_tags.size():
		return &""

	return StringName(spawn_tags[index])

func add_pack(kind: int, at: Vector3) -> ArenaMap:
	packs.append({"kind": kind, "at": at})
	return self

func add_box(box: AABB) -> ArenaMap:
	boxes.append(box.abs())
	return self

## Adds the four outer walls. Solid boxes rather than planes, because everything downstream understands a box and only some of it a plane,
## and a map that is boxes all the way down is a map whose three representations cannot disagree.
func add_perimeter(thickness: float = 2.0) -> ArenaMap:
	var span := extent * 2.0 + thickness * 2.0

	add_box(AABB(
		Vector3(-extent - thickness, floor_y, -extent - thickness),
		Vector3(thickness, wall_height, span)
	))
	add_box(AABB(
		Vector3(extent, floor_y, -extent - thickness),
		Vector3(thickness, wall_height, span)
	))
	add_box(AABB(
		Vector3(-extent - thickness, floor_y, -extent - thickness),
		Vector3(span, wall_height, thickness)
	))
	add_box(AABB(
		Vector3(-extent - thickness, floor_y, extent),
		Vector3(span, wall_height, thickness)
	))

	return self

# --- The three representations ---------------------------------------------

## The solid the bots' walking mesh is baked from: [member collision_root], less any slab that
## spans the whole map (a mapper's sealed bounding box, six hulls of 500 m by 430 m and 60 cm
## thick). Recast, handed that box with the islands inside it, found nowhere to walk at all
## (one map: 0 polygons of 63,000 vertices; 7,400 once the box was left out), and the
## box's floor and ceiling are not places anybody stands to fight. Returns a holder added beside
## [member collision_root] that the caller frees after parsing (a bake parses at once), or
## null when there is no such slab and [member collision_root] itself is the source.
func nav_source() -> Node3D:
	if collision_root == null or not collision_root.is_inside_tree() or collision_root.get_parent() == null:
		return null

	var body := StaticBody3D.new()
	var skipped := 0

	for child in collision_root.get_children():
		var shape_node := child as CollisionShape3D
		var hull := shape_node.shape as ConvexPolygonShape3D if shape_node != null else null

		if hull != null and not hull.points.is_empty():
			var box := AABB(hull.points[0], Vector3.ZERO)

			for point in hull.points:
				box = box.expand(point)

			var dims := [box.size.x, box.size.y, box.size.z]
			dims.sort()

			if float(dims[0]) < 1.5 and float(dims[1]) > 150.0:
				skipped += 1
				continue

		if shape_node != null:
			var copy := shape_node.duplicate() as CollisionShape3D
			copy.transform = shape_node.transform
			body.add_child(copy)

	if skipped == 0:
		body.free()
		return null

	var holder := Node3D.new()
	holder.name = &"NavSource"
	holder.add_child(body)
	collision_root.get_parent().add_child(holder)
	return holder

## The movement backend for a headless server or a test.
func to_fps_body() -> DotFpsFlatBody:
	var body := DotFpsFlatBody.new()
	body.floor_y = floor_y

	for box in boxes:
		body.add_box(box)

	return body

## The movement backend the game hands every player on this map.
##
## [method to_fps_body] for a built-in map, unchanged. For an imported one, a
## [DotFpsPhysicsBody] bound to [member collision_root] — the brushes in Godot's physics
## space, on the server and on every client alike. [b]That is still one backend at both
## ends[/b], which is the rule `ArenaClient`'s HEADLESS note is about: a predicting client
## must collide against what the server collides against, and here both query the same
## convex hulls through the same solver. g2gfast predicts against exactly this.
##
## Unbound when the solid is not in the tree yet; the body then answers every query with
## nothing there, which is a player falling through a level, so the game builds the
## solid first.
func movement_body() -> DotFpsBody:
	if not is_imported():
		return to_fps_body()

	var body := DotFpsPhysicsBody.new()

	if collision_root != null and collision_root.is_inside_tree():
		var _bound := body.bind(collision_root)

	return body

## Lifts every spawn, and every pit's destination, whose standing hull is inside solid
## until it is clear, and returns how many moved. Needs [member collision_root] in the tree; a built-in map is untouched.
##
## [b]A mapper's spawn is a point, and on some of these maps it is inside the floor.[/b]
## Every one of `surf_10x_final`'s 48 is 44 units under the top of the brush they stand
## in, and the motor pushes a player out of solid at most a step a tick — so each spawn
## there was a player rising through the floor for a sixth of a second, visibly, and on a
## floor any thicker one who never came out. g2gfast's notes name the answer and leave it
## open: one shape query per spawn, at load, in the one place that knows about brushes and
## terrain alike. Up in 5 cm steps to [constant SPAWN_LIFT_MAX]; a spawn that is not clear
## by then is left where it was, because a spawn moved two metres is somewhere the mapper
## never put one.
func settle_spawns(body: DotFpsBody, tunables: DotFpsTunables) -> int:
	if not is_imported() or body == null:
		return 0

	var height := tunables.stand_height - 0.2
	var radius := tunables.radius - 0.05
	var moved := 0

	for index in range(spawns.size()):
		var at := spawns[index]
		var lift := 0.0

		while lift <= SPAWN_LIFT_MAX and body.overlaps(
			at.origin + Vector3.UP * (lift + 0.1 + height * 0.5), height, radius
		):
			lift += 0.05

		if lift > 0.0 and lift <= SPAWN_LIFT_MAX:
			spawns[index] = Transform3D(at.basis, at.origin + Vector3.UP * lift)
			moved += 1

	# And where every pit sends somebody, which is a spawn by another name: the map's
	# teleport destinations are entity points the mapper placed exactly like a spawn.
	for pit in pits:
		var to: Vector3 = pit["to"]
		var lift := 0.0

		while lift <= SPAWN_LIFT_MAX and body.overlaps(
			to + Vector3.UP * (lift + 0.1 + height * 0.5), height, radius
		):
			lift += 0.05

		if lift > 0.0 and lift <= SPAWN_LIFT_MAX:
			pit["to"] = to + Vector3.UP * lift
			moved += 1

	return moved

## The shot-tracing backend for a headless server or a test.
func to_trace() -> DotTraceFlat:
	var trace := DotTraceFlat.with_floor(floor_y)

	for box in boxes:
		trace.add_box(box)

	return trace

## The shot-tracing backend for this map: [method to_trace], or the physics space.
func shot_trace() -> DotTrace:
	if not is_imported():
		return to_trace()

	var trace := ArenaGlassTrace.new()
	trace.glass = glass
	trace.material_fn = DotPhysicsSurfaceSet.material_of

	if collision_root != null and collision_root.is_inside_tree():
		trace.bind_from_node(collision_root)

	return trace

## Whether this host's dot-lighting can lay a bake (API level 5).
static func can_bake() -> bool:
	return DotAddonApi.build_level("dot_lighting") >= 5 and ResourceLoader.exists(BAKE_SCRIPT) \
			and ResourceLoader.exists(SHEET_SCRIPT)

## What the bake must have been made from: the boxes, the floor and the sun, plus the versions of
## everything that lays them out. The same on the machine that baked and on every client.
func light_fingerprint() -> String:
	if not can_bake():
		return ""

	var list: Array = []

	for box in boxes:
		list.append([box.position.x, box.position.y, box.position.z, box.size.x, box.size.y, box.size.z])

	return (load(BAKE_SCRIPT) as GDScript).call(&"fingerprint", {
		"arena": BAKE_VERSION, "boxes": list, "extent": extent, "floor_y": floor_y,
		"sun": lighting.get("sun", {}), "sheet": (load(SHEET_SCRIPT) as GDScript).get("VERSION"),
	})

## The map's bake laid over its level, if the game ships one made from these boxes.
func _attach_bake(level: Node3D) -> void:
	var res: DotResult = (load(BAKE_SCRIPT) as GDScript).call(
		&"attach", level, ArenaPaths.rebase(BAKE_PATH % String(id)), light_fingerprint())

	if res.ok:
		baked = res.value

## Where a box meets the floor or another box, dot-lighting's contact shade (API 4): the
## Compatibility renderer the client shell draws has no ambient occlusion, and every crate and
## wall stood on the floor with no shade at its foot. One unshaded mesh, built once here.
## By path, behind the level, so a shell older than the helper draws the map without it.
func _add_contact_shade(root: Node3D) -> void:
	if DotAddonApi.build_level("dot_lighting") < 4 or not ResourceLoader.exists(CONTACT_SHADE_SCRIPT):
		return
	var shade_boxes: Array = []
	var floor_box := AABB(
		Vector3(-extent - 2.0, floor_y - 1.0, -extent - 2.0),
		Vector3(extent * 2.0 + 4.0, 1.0, extent * 2.0 + 4.0)
	)
	for box: AABB in [floor_box] + boxes:
		shade_boxes.append({"transform": Transform3D(Basis.IDENTITY, box.get_center()), "size": box.size})
	var shade: Variant = (load(CONTACT_SHADE_SCRIPT) as GDScript).call(&"node", shade_boxes)
	if shade is MeshInstance3D and (shade as MeshInstance3D).mesh != null:
		root.add_child(shade)
	elif shade is Node:
		(shade as Node).free()

## A box as an [ArrayMesh] with the second UV set a lightmap needs ([DotLightmapSheet], the same
## on every machine). The bottom face is left out when [param hide_bottom] (the box stands on the floor):
## nobody sees it and it would take as many texels as the top.
static func lightmap_box(size: Vector3, hide_bottom: bool) -> ArrayMesh:
	var sheet: RefCounted = (load(SHEET_SCRIPT) as GDScript).new()
	var h := size * 0.5
	var faces := [
		[Vector3.RIGHT, Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z)],
		[Vector3.LEFT, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z)],
		[Vector3.UP, Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z)],
		[Vector3.DOWN, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z)],
		[Vector3.BACK, Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, -h.y, h.z)],
		[Vector3.FORWARD, Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, -h.y, -h.z)],
	]

	for face: Array in faces:
		if hide_bottom and face[0] == Vector3.DOWN:
			continue
		sheet.face(face[1], face[2], face[3], face[4], face[0])

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	sheet.commit(tool)
	var mesh := tool.commit()
	mesh.lightmap_size_hint = sheet.size
	return mesh

## The third arena: a sunken floor, a catwalk around it, and one bridge across.
##
## [b]Free-for-all only, and that is the point rather than an omission.[/b] Every spawn
## here is untagged, so [method ArenaMaps.supports_mode] answers no for a team mode and
## this is the first map in the game that ever does. `dm_box` and `dm_atrium` both tag
## their spawns, which means the three places that ask the question -- the ballot, the
## mode half of the ballot, and the refusal in [ArenaMapSession] -- had never once been
## told no by a real map. A filter with nothing to filter is a filter nobody has run.
##
## It is also the small map this game did not have. `dm_box` is 48 m across and
## `dm_atrium` 60; this is 28, and a map you can cross in four seconds is a different
## game rather than a smaller one -- which is the reason a shooter ships one.
##
## [b]The shape.[/b] The floor is the pit. A 3 m catwalk runs around all four walls at
## 3.6 m, with 3 m of headroom under it, so the ring is both the high ground and a
## covered gallery for whoever is beneath it. A 2 m bridge crosses north to south
## through the middle at catwalk height, over open air.
##
## Three ways up, and they are deliberately not equivalent:
##
## - [b]the north-west stair[/b], ten treads of 0.36, walkable, slow, and in the open;
## - [b]the south-east stair[/b], its mirror, so the two long diagonals are symmetric
##   and nothing else on the map is;
## - [b]the north-east crates[/b], three jumps and a fourth onto the ring, which is
##   the fast way and the only one that does not announce itself. [b]Two jumps until
##   2026-09-22, the first of them onto a 1.4 m crate, and a jump here peaks at
##   1.25[/b] — so it was the fast way up for nobody.
##
## Down is free everywhere, which is what keeps the pit from being a trap: the ring is
## worth holding for as long as nobody has decided to drop on you.
##
## [b]Extended 2026-09-18.[/b] A second bridge east to west makes the middle a
## crossing rather than a chord, and a shelf in the south-west corner carries a perch
## at 5.4 — the map's third tier, two 0.9 m hops up from the ring. Nine spawns now,
## and still none of them tagged.
static func dm_pit() -> ArenaMap:
	var map := ArenaMap.new()
	map.id = &"dm_pit"
	map.display_name = "dm_pit"
	map.extent = 14.0
	map.wall_height = 7.0

	# --- The catwalk -------------------------------------------------------
	#
	# A ring 3 m wide against all four walls, top face at 3.6. Four boxes rather than
	# a frame with a hole, for the reason every other map here gives: a hole is not a
	# box and everything downstream of this list understands only boxes.
	const RING_Y := 3.0
	const RING_T := 0.6
	const RING_IN := 11.0

	map.add_box(AABB(Vector3(-14.0, RING_Y, -14.0), Vector3(28.0, RING_T, 3.0)))
	map.add_box(AABB(Vector3(-14.0, RING_Y, RING_IN), Vector3(28.0, RING_T, 3.0)))
	map.add_box(AABB(Vector3(-14.0, RING_Y, -RING_IN), Vector3(3.0, RING_T, 22.0)))
	map.add_box(AABB(Vector3(RING_IN, RING_Y, -RING_IN), Vector3(3.0, RING_T, 22.0)))

	# The bridge, north to south through the middle at ring height. Flush with both
	# ends of the ring, so crossing it is a decision rather than a jump.
	map.add_box(AABB(Vector3(-1.0, RING_Y, -RING_IN), Vector3(2.0, RING_T, 22.0)))

	# And its east-west twin, added 2026-09-18, which turns the ring's one shortcut
	# into a crossing. With a single bridge the ring is a loop with a chord and the
	# whole of the high ground is one decision wide; with two, the middle of the map
	# is a junction four ways lead to and the island underneath is the only place on
	# it out of everybody's sight. The two overlap in the middle by construction —
	# overlapping boxes are fine here, and a hole cut between them would not be a box.
	map.add_box(AABB(Vector3(-RING_IN, RING_Y, -1.0), Vector3(22.0, RING_T, 2.0)))

	# --- The two stairs ----------------------------------------------------
	#
	# Ten treads of 0.36, which is under `DotFpsTunables.step_height` (0.4) and so is
	# walked rather than jumped. The number is `dm_atrium`'s, and it is 0.36 there
	# because 0.6 was measured and a bot holding forward stopped dead against the
	# first tread.
	#
	# The last tread's far face lands exactly on `RING_IN`. A stair that stops half a
	# metre short is a stair with a hole at the top of it, which reads as the player
	# falling through the map.
	for index in range(10):
		var rise := 0.36 * float(index + 1)

		# North-west, climbing west onto the west arm.
		map.add_box(AABB(
			Vector3(-2.0 - float(index + 1) * 0.9, 0.0, -10.5),
			Vector3(0.9, rise, 3.0)
		))

		# South-east, climbing east onto the east arm.
		map.add_box(AABB(
			Vector3(2.0 + float(index) * 0.9, 0.0, 7.5),
			Vector3(0.9, rise, 3.0)
		))

	# --- The north-east crates ---------------------------------------------
	#
	# [b]Rebuilt 2026-09-22 alongside dm_atrium's, and for the same reason.[/b] It was
	# 1.4 then 2.6 then the ring at 3.6, described in this file as "none of them over
	# 1.2 m" — which was true of the second and third step and not of the first, and
	# 1.2 would not have been climbable either. A jump's APEX here is 1.25, so the
	# first crate was 0.15 m above everything a player on the pit floor can reach and
	# the whole route started with a wall. The one route on this map that does not
	# announce itself was the one route nobody could take.
	#
	# Three crates at 0.9 now, and the ring is a fourth 0.9 off the top one. Every gap
	# is 0.5 m of clear air, and the last crate's north face is flush with the north
	# arm's inner edge so the step onto the ring has no gap at all.
	var pit_crates: Array[AABB] = [
		AABB(Vector3(5.0, 0.0, -5.0), Vector3(2.5, 0.9, 2.5)),
		AABB(Vector3(5.5, 0.0, -8.0), Vector3(2.5, 1.8, 2.5)),
		AABB(Vector3(6.0, 0.0, -11.0), Vector3(2.5, 2.7, 2.5)),
	]

	for box in pit_crates:
		map.add_box(box)

	map.add_climb("dm_pit: the pit floor onto the first crate", _floor_at(0.0), pit_crates[0])
	map.add_climb("dm_pit: crate 1 onto crate 2", pit_crates[0], pit_crates[1])
	map.add_climb("dm_pit: crate 2 onto crate 3", pit_crates[1], pit_crates[2])
	map.add_climb(
		"dm_pit: the top crate onto the north arm",
		pit_crates[2],
		AABB(Vector3(-14.0, RING_Y, -14.0), Vector3(28.0, RING_T, 3.0))
	)

	# --- Cover in the pit --------------------------------------------------
	#
	# A low island in the middle, under the bridge with 2.2 m of headroom, and three
	# waist-high pillars. Three and not four: the fourth corner is where the crates
	# are, and a pillar there would grow through the first of them.
	#
	# [b]At ±5.75, not ±6.[/b] At 6 the pillars beside the two stairs stood 0.75 m off
	# the stairs' sides — a pinch 0.9 m long and narrower than a player, between two
	# things a player runs along. `[gate-sweep-1]`'s slot rule found both (2026-09-24);
	# a quarter of a metre toward the middle makes each a metre.
	map.add_box(AABB(Vector3(-2.5, 0.0, -2.5), Vector3(5.0, 0.8, 5.0)))

	for corner in [Vector2(-5.75, -5.75), Vector2(-5.75, 5.75), Vector2(5.75, 5.75)]:
		map.add_box(AABB(
			Vector3(corner.x - 0.75, 0.0, corner.y - 0.75), Vector3(1.5, 2.2, 1.5)
		))

	# --- The south-west shelf and the perch --------------------------------
	#
	# A third tier, and the map's only one. The shelf is a 4 m block standing on the
	# pit floor, FLUSH with the inner edges of the west and south arms — x = -11 and
	# z = 11 — and that is the part worth stating rather than the height: set half a
	# metre clear of them instead, it would leave a 0.5 m slot between the block and
	# the catwalk, which is narrower than the 0.8 m a player is and is therefore a
	# gap nothing that plays this map can pass. See `[gate-sweep-1]`: the second
	# question a map has to answer is whether it contains a place its player cannot
	# get to, and a slot is how one appears without anybody drawing it.
	#
	# Two rises of 0.9 — ring 3.6 to shelf 4.5 to perch 5.4 — both under the 1.25 m
	# `arena_tunables()` jumps, so each is a hop rather than a route that needs the
	# crates. The perch sees the whole pit and every metre of the ring sees the
	# perch, which is the trade: it is the best view on the map and the worst place
	# to be found standing still.
	const SHELF_TOP := 4.5
	const PERCH_TOP := 5.4

	var shelf := AABB(Vector3(-11.0, 0.0, 7.0), Vector3(4.0, SHELF_TOP, 4.0))
	var perch := AABB(
		Vector3(-11.0, SHELF_TOP, 9.0), Vector3(2.0, PERCH_TOP - SHELF_TOP, 2.0)
	)

	map.add_box(shelf)
	map.add_box(perch)

	map.add_climb(
		"dm_pit: the west arm onto the shelf",
		AABB(Vector3(-14.0, RING_Y, -RING_IN), Vector3(3.0, RING_T, 22.0)),
		shelf
	)
	map.add_climb("dm_pit: the shelf onto the perch", shelf, perch)

	# --- The shelf stair ---------------------------------------------------
	#
	# Added 2026-09-30 (1.5.0). [b]The third tier could only be reached from the
	# second.[/b] A player on the pit floor who wanted the perch went up a stair onto
	# the ring, round it to the west arm and hopped, so the fight for the map's best
	# view was a fight between people already on the ring and the pit was only ever
	# the place they shot into. The shelf stair walks from the pit floor straight up
	# the shelf's east face: eleven boxes climbing west, the top one 0.18 under the
	# shelf, so the whole way up is walked and the perch is one hop from the floor's
	# own stair rather than from the ring.
	#
	# [b]It shares the south-east stair's lane (z 7.5..10.5) and meets it foot to
	# foot at x = 2[/b], so the two make one valley: down off the east arm, through a
	# dip at 0.36, and up onto the shelf, held in one direction. That is the second
	# thing it is for — a way from the lookout's side of the map to the perch's that
	# goes THROUGH the pit instead of round the ring above it. There is nowhere else
	# for it: the east-west bridge crosses the pit at z -1..1 with its underside at
	# 3.0, so any stair running north off the shelf passes under it with a metre of
	# headroom, and the south half of the pit east of the shelf is exactly 9 m to the
	# other stair's foot.
	#
	# [b]The north-south bridge runs over it.[/b] The bridge is x -1..1 for the whole
	# depth of the pit with its underside at 3.0, so anything a player stands on while
	# any part of them is under it can be no higher than 3.0 less `stand_height`
	# (1.8). The first draft ran twelve even treads from x = 2 and a bot walked into
	# the bridge's side on the fourth, at 1.44; the second put a landing at 0.72
	# exactly the bridge's width, and a bot stopped at its west edge, because the
	# step up off it happens with the hull still 0.35 under the bridge. So: one tread
	# at 0.72 off the other stair's first, a LANDING at 1.08 (1.92 of headroom) that
	# runs a hull's width and a bit (0.9; the 0.4064 hull needs 0.82) past the bridge's west
	# edge, and nine treads from 1.44 to 4.32 against the shelf. Every rise, the shelf's 0.18 lip
	# included, is the 0.36 a bot walks; the nine are 0.57 deep, which is all the
	# room there is. The trade is the one the nest stairs make on dm_box: it climbs
	# straight at the perch, so whoever holds the perch looks down every tread of it
	# (`headless_match` traces all eleven boxes).
	const SHELF_STAIR_RISE := 0.36
	const SHELF_STAIR_FOOT := 2.0
	const SHELF_STAIR_TREADS := 9
	const BRIDGE_WEST := -1.0
	const BRIDGE_EAST := 1.0
	const LANDING_WEST := BRIDGE_WEST - 0.9

	map.add_box(AABB(
		Vector3(BRIDGE_EAST, 0.0, 7.5),
		Vector3(SHELF_STAIR_FOOT - BRIDGE_EAST, SHELF_STAIR_RISE * 2.0, 3.0)
	))
	map.add_box(AABB(
		Vector3(LANDING_WEST, 0.0, 7.5),
		Vector3(BRIDGE_EAST - LANDING_WEST, SHELF_STAIR_RISE * 3.0, 3.0)
	))

	var tread_depth := (LANDING_WEST - (shelf.position.x + shelf.size.x)) \
		/ float(SHELF_STAIR_TREADS)

	for index in range(SHELF_STAIR_TREADS):
		# index 0 is at the landing's west edge; the last is against the shelf.
		map.add_box(AABB(
			Vector3(LANDING_WEST - float(index + 1) * tread_depth, 0.0, 7.5),
			Vector3(tread_depth, SHELF_STAIR_RISE * float(index + 4), 3.0)
		))

	# --- The lookout on the east arm ---------------------------------------
	#
	# Added 2026-09-26. [b]One high point is a throne; two are a duel.[/b] The perch
	# saw the whole pit and nothing on the map could look back at it from above the
	# ring, so whoever held it held the map. The lookout is the answer from across the
	# room: one 0.9 m hop off the east arm, against the east wall, with a clear line
	# to the perch over both bridges (`headless_match` traces it). Now the perch is
	# the higher of two places that watch each other, and the ring between them is in
	# both of their sights.
	#
	# [b]1.5 m deep, against the wall, so the arm keeps 1.5 m of walkway[/b], nearly
	# twice the 0.8 m a player is. The arm is a loop and a lookout that closed it would
	# turn the ring into two dead ends. Between the bridge (z -1..1) and the south-east
	# stair's landing (z 7.5..10.5), so neither arrival lands on it.
	const LOOKOUT_TOP := 4.5

	var lookout := AABB(
		Vector3(12.5, RING_Y + RING_T, 3.0), Vector3(1.5, LOOKOUT_TOP - RING_Y - RING_T, 2.0)
	)

	map.add_box(lookout)
	map.add_climb(
		"dm_pit: the east arm onto the lookout",
		AABB(Vector3(RING_IN, RING_Y, -RING_IN), Vector3(3.0, RING_T, 22.0)),
		lookout
	)

	map.add_perimeter()

	# --- Spawns ------------------------------------------------------------
	#
	# Eight, five in the pit and three on the ring, and [b]every one of them
	# untagged[/b]. This is the property the map exists for: `_has_team_spawns` says
	# no, the catalogue records `teams: false`, and a team mode cannot be played here.
	# Do not tag them.
	var points: Array[Vector3] = [
		Vector3(-8.0, 0.1, 0.0),
		Vector3(8.0, 0.1, 2.0),
		# Was (0, 8.5), which is on the shelf stair's lane; moved 3 m north onto open
		# floor between the two south pillars (1.5.0).
		Vector3(0.0, 0.1, 5.5),
		Vector3(-4.0, 0.1, -4.0),
		Vector3(4.5, 0.1, -2.0),
		Vector3(-12.5, 3.7, -6.0),
		Vector3(12.5, 3.7, 6.0),
		Vector3(0.0, 3.7, -12.5),
		# On the shelf. Nine now, and still not one of them tagged — the property
		# this map exists for survives anything added to it or it is not a property.
		Vector3(-8.5, 4.6, 8.5),
	]

	for at in points:
		var to_centre := Vector3(-at.x, 0.0, -at.z)

		if to_centre.length_squared() < 0.001:
			to_centre = Vector3.FORWARD

		map.add_spawn(
			Transform3D(Basis.looking_at(to_centre.normalized(), Vector3.UP), at)
		)

	# No toys: a deathmatch map keeps its floor clear (ArenaTestToys gives the tests theirs).
	# Packs (health on the east and west, ammo north and south): clear of every box, off the spawns.
	map.add_pack(PACK_HEALTH, Vector3(-12.0, 0.0, 0.0))
	map.add_pack(PACK_HEALTH, Vector3(12.0, 0.0, 0.0))
	map.add_pack(PACK_AMMO, Vector3(0.0, 0.0, -12.0))
	map.add_pack(PACK_AMMO, Vector3(0.0, 0.0, 12.0))

	return map
