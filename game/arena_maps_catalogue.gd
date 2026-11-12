extends RefCounted

const ArenaPaths := preload("arena_paths.gd")


const ArenaMap := preload("../maps/arena_map.gd")
const ArenaImportedMaps := preload("../maps/arena_imported_maps.gd")
const ArenaMapDoc := preload("../maps/arena_map_doc.gd")
const ArenaMode := preload("arena_mode.gd")

## This game's maps as dot-map content. [b]The awkward part:[/b] dot-map treats a map as content (id, version, scene path) and [ArenaMap] builds these in code on purpose ("the headless test and the played game must get the same map"), so [member DotMapDef.scene_path] names [b]the script that produces the map[/b] and [code]meta.builder[/code] says so.
## That is the seam: rotation, cooldowns, nominations, ballots and the announce/ready/load protocol work on id and version and never open the scene; only [DotMapLoader] reads `scene_path`, and [ArenaMapDirector] calls [method ArenaMap.by_id] for a built-in.
## A [b]delivered[/b] map (see [method delivered_def]) sets [member DotMapDef.content_id] and points at the manifest in its pack. The path is a real file, not a `code://` sentinel, so a validator can check it.


const CHANNEL := "arena.maps"


## The file that builds every map in this catalogue.
static var BUILDER_PATH := ArenaPaths.rebase(ArenaPaths.rebase("res://maps/arena_map.gd"))


## What a map is at, when nothing says otherwise.
##
## Every map starts here and leaves when its geometry moves.
const MAP_VERSION := "1.0.0"


## Per-map versions, for the maps that have moved on from [constant MAP_VERSION]. [b]Per map, not one constant for the catalogue[/b]: a record and a rotation cooldown are both about a map AT a version, so geometry that moved under one id is a different map wearing the same name.
## A single shared constant could only say it about all maps at once (bumping it for `dm_atrium`'s arcade would also invalidate `dm_box` and `dm_pit` records).
## A map absent from here is at [constant MAP_VERSION], the common case, which is why this is a lookup rather than a column every map fills in.
const MAP_VERSIONS := {
	# 1.1.0: the south arcade, the stair onto its roof, and the doorway cut in the bunker's east wall. 1.2.0: the south-east crates rebuilt from three steps of 1.5 m to five of 0.9 (a jump peaks at 1.25).
	# 1.3.0: the north-west stair moved 0.75 m east and the arcade's last piers 0.5 m east, closing slots narrower than a player. 1.4.0: the north-west keep, a roofed room in red's half, reached by a 2 m jump off the ring's north arm.
	# 1.5.0: the east stair. 1.6.0: the rampart, a walkway from the keep's roof to the perch's north face. 1.7.0: the north gallery, two ledges with a 12 m gap only a wall run crosses. 1.7.1: the gap is 9 m (the low ledge starts at x -9).
	&"dm_atrium": "1.7.1",
	# 1.1.0: the east-west bridge, the south-west shelf and the perch. [b]Backdated[/b]: that change moved the geometry and not the version, so records set on the one-bridge dm_pit are recorded against the two-bridge one;
	# this entry makes the runs from here separable from both. 1.2.0: the north-east crates rebuilt from two steps of 1.4 and 1.2 to three of 0.9. 1.3.0: the three pillars moved from ±6 to ±5.75, closing two 0.75 m pinches against the stairs.
	# 1.4.0: the lookout on the east arm, facing the perch. 1.5.0: the shelf stair, twelve treads from the pit floor up the shelf's east face to the south-east stair; one spawn moved off its lane.
	&"dm_pit": "1.5.0",
	# 1.1.0: three crates to each of the two ledges, which had been standable geometry with no way up. 1.2.0: two gantries joining the ledges into a loop, and a nest on the pillars at (4, -12) and (-4, 12), one 0.9 m step off each gantry.
	# 1.3.0: two nest stairs, ten walked treads up the outside of each gantry. 1.4.0: two corner stairs, ten walked treads along the north and south walls up to a landing that carries each ledge on into its corner.
	&"dm_box": "1.4.0",
}


## Every built-in map, as dot-map content, built from [method ArenaMap.ids] rather than listed here. [b]A second list of the maps is the bug this family has shipped four times[/b]:
## `setup.sh`, `tools/check.sh`, `tools/package_check.sh` and bootstrap all carried one and all went stale.
## The fix is to read it from the one place that cannot, the code that makes the maps.
static func catalogue(content: DotContentIndex = null) -> DotMapCatalogue:
	var out := DotMapCatalogue.new()
	out.meta = {"game": "arena"}

	# The built-ins, then every imported combat surf map that was found — discovered by
	# `ArenaImportedMaps` off each manifest's own `kind`, not listed here either.
	for id in ArenaMap.ids() + ArenaMap.imported_ids():
		_list(out, id)

	_follow_content(out, content)
	return out


## [method catalogue] a few maps a frame: reading 100-odd manifests at once was a 156 ms frame on staging02.
static func catalogue_async(slice: DotFrameSlice, content: DotContentIndex = null) -> DotMapCatalogue:
	var out := DotMapCatalogue.new()
	out.meta = {"game": "arena"}
	for id in ArenaMap.ids() + ArenaMap.imported_ids():
		if slice.due():
			await slice.pause()
		_list(out, id)
	_follow_content(out, content)
	return out


static func _list(out: DotMapCatalogue, id: StringName) -> void:
	var map := ArenaMap.listing_by_id(id)

	if map == null:
		return

	if map.id != id:
		# `ids()` is kept beside `by_id` deliberately: a map in one and not the other cannot be listed or cannot be loaded, and this is the third statement of that id.
		# A mismatch means a catalogue entry addressed by a name the builder does not answer to, which fails at the change rather than at the boot.
		DotLog.warn(CHANNEL, "a map's own id disagrees with the one it is listed under", {
			"listed": String(id), "built": String(map.id)
		})
		return

	var added := out.add(_def_for(id, map))

	if not added.ok:
		DotLog.warn(CHANNEL, "a map could not be catalogued", {
			"map": String(id), "why": added.error.message
		})


static func _follow_content(out: DotMapCatalogue, content: DotContentIndex) -> void:
	# The Workshop's maps, after the game's own so that an id of ours always wins. The index
	# is solo or online as its host set it, so an online session lists none of them; the
	# catalogue is built the same way on a server, which is what keeps that one rule.
	out.follow_content(content if content != null else DotContentIndex.shared(), accepted_map_kinds())

	# A pack's map whose document is bad is refused and not listed. Dropped here for the
	# list as built; [method supports_mode] and [method menu_rows] check again, because the
	# catalogue re-adds its followed rows whenever the session turns.
	for def in out.maps.duplicate():
		if is_workshop(def) and not build_workshop(def).ok:
			var _removed := out.remove(def.id)


## The file a game pack states what it takes from subscriptions in (dot-cloud's
## docs/workshop.md, "What a game accepts"). Read from there, not repeated here, because the
## site offers a pack by this same file and a second list would drift from it.
const PROVIDES_PATH := "res://provides.json"


## What [method accepted_map_kinds] answers when the file cannot be read.
const ACCEPTED_MAP_KINDS_FALLBACK := ["arena"]


## The `map_kind`s of subscribed maps this game lists: `accepts.map_kinds` in `provides.json`.
static func accepted_map_kinds() -> PackedStringArray:
	var out := PackedStringArray()
	var path := ArenaPaths.rebase(PROVIDES_PATH)
	var parsed: Variant = null
	if FileAccess.file_exists(path):
		parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	var accepts: Variant = (parsed as Dictionary).get("accepts") if parsed is Dictionary else null
	var kinds: Variant = (accepts as Dictionary).get("map_kinds") if accepts is Dictionary else null
	if not (kinds is Array):
		kinds = ACCEPTED_MAP_KINDS_FALLBACK
	for kind: Variant in (kinds as Array):
		out.append(str(kind))
	return out


## Whether [param def] came from a subscribed pack rather than from this game.
static func is_workshop(def: DotMapDef) -> bool:
	return def != null and def.entry_key != ""


## The map a subscribed pack's [param def] describes. Its `scene` is a box-list map document (`maps/arena_map_doc.gd`) or an imported map's manifest (`"kind": "arena"`, mesh `.bin` beside it), mounted through [method ArenaImportedMaps.add_mounted].
## A fresh [ArenaMap] each call, like [method ArenaMap.by_id]; a refusal is logged once per entry. The entry's id and the document's id may differ in `-` against `_` (`dm_morpheus` against `dm-morpheus`): either is accepted.
## A box list keeps the entry's id; an imported map is canonically its document's id (its files, world and lightmap are named by it), so the map built answers to [method workshop_map_id], not always to `def.id`.
static func build_workshop(def: DotMapDef) -> DotResult:
	if not is_workshop(def):
		return DotResult.fail(DotError.CODE_INVALID, "not a Workshop map", String(def.id) if def != null else "")
	var built: DotResult
	var imported_id := _imported_doc_id(def.scene_path)
	if imported_id != "":
		built = _build_workshop_imported(def, imported_id)
	else:
		var text := FileAccess.get_file_as_string(def.scene_path) if FileAccess.file_exists(def.scene_path) else ""
		built = ArenaMapDoc.build(text, def.id)
	if not built.ok and not _refused_keys.has(def.entry_key):
		_refused_keys[def.entry_key] = true
		DotLog.warn(CHANNEL, "a Workshop map was refused", {
			"entry": def.entry_key, "why": built.error.message,
		})
	return built


## The id [param def]'s map is played under: the document's own for an imported map (see
## [method build_workshop]), else the entry's.
static func workshop_map_id(def: DotMapDef) -> StringName:
	if not is_workshop(def):
		return def.id if def != null else &""
	var imported_id := _imported_doc_id(def.scene_path)
	return StringName(imported_id) if imported_id != "" else def.id


## Whether two map ids are the same map written `-` or `_`.
static func same_map_id(a: String, b: String) -> bool:
	return a == b or a.replace("_", "-") == b.replace("_", "-")


## scene path -> [modified time, the imported document's id or ""], so the menu's repeated asks
## do not parse a manifest of up to a megabyte each time.
static var _doc_ids: Dictionary = {}


## The id of the imported-map manifest at [param path], or "" when it is not one (missing, not
## JSON, a box-list document, or not `"kind": "arena"`).
static func _imported_doc_id(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var stamp := FileAccess.get_modified_time(path)
	var held: Variant = _doc_ids.get(path)
	if held is Array and int((held as Array)[0]) == stamp:
		return str((held as Array)[1])
	var id := ""
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) == OK and json.data is Dictionary:
		var doc: Dictionary = json.data
		if str(doc.get("kind", "")) == ArenaImportedMaps.KIND and not doc.has("boxes"):
			id = str(doc.get("id", ""))
	_doc_ids[path] = [stamp, id]
	return id


static func _build_workshop_imported(def: DotMapDef, doc_id: String) -> DotResult:
	if not same_map_id(doc_id, String(def.id)):
		return DotResult.fail(DotError.CODE_INVALID, "the document's id is not the entry's id",
			"%s vs %s" % [doc_id, def.id])
	var dir := def.scene_path.get_base_dir()
	# add_mounted finds the manifest as <id>.json, so the file must be named for the document.
	if def.scene_path.get_file() != "%s.json" % doc_id:
		return DotResult.fail(DotError.CODE_INVALID, "the manifest is not named for its map", def.scene_path)
	var key := StringName(doc_id)
	# A copy mounted already (a server-named version, or this call's last) stays: a second
	# registration would only re-parse the manifest, or move a mount a delivered map owns.
	if not ArenaImportedMaps.is_mounted(key):
		var added := ArenaImportedMaps.add_mounted(key, dir)
		if not added.ok:
			return added
	var map := ArenaMap.imported(key)
	if map == null:
		return DotResult.fail(DotError.CODE_INVALID, "the manifest cannot be built into a map", def.scene_path)
	if map.spawns.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "the map has no spawn", def.scene_path)
	map.display_name = def.display_name if def.display_name != "" else doc_id
	return DotResult.success(map)


## The rows of the solo map menu (M), in the ballot's ids so a server's list reads the same:
## every map that can host [param mode] (`map:<id>`), then every mode [param here] can host
## (`mode:<id>`) from [param modes] (passed in: `arena_modes.gd` preloads this file). A pack's map is named with its pack, "Name [Pack]".
static func menu_rows(
	catalogue: DotMapCatalogue, here: StringName, mode: ArenaMode, modes: Array
) -> Array:
	var out: Array = []
	var surf: Array = []
	for def in catalogue.available():
		if mode != null and not supports_mode(def, mode):
			continue
		if is_workshop(def) and not build_workshop(def).ok:
			continue
		var detail := ""
		if bool(def.meta.get("imported", false)):
			detail = imported_label(def.id)
		elif is_workshop(def):
			detail = "Workshop map"
		var row := {"id": "map:%s" % def.id, "name": def.label(), "mode": "Map",
			"detail": detail, "current": def.id == here or (is_workshop(def) and workshop_map_id(def) == here)}
		# Fifty surf maps would otherwise push the deathmatch ones onto page 3.
		if detail == "Combat surf map":
			surf.append(row)
		else:
			out.append(row)
	out.append_array(surf)
	var current_def := catalogue.get_map(here)
	for each: ArenaMode in modes:
		if current_def != null and not supports_mode(current_def, each):
			continue
		out.append({"id": "mode:%s" % each.id, "name": each.display_name, "mode": "Mode", "kind": "mode",
			"detail": each.description.get_slice("\n", 0),
			"current": mode != null and each.id == mode.id})
	return out


## What an imported map is, by id: the surf maps are `surf_*`, gun game `gg-*`, the rest deathmatch.
static func imported_label(id: StringName) -> String:
	var text := String(id)
	if text.begins_with("surf_"):
		return "Combat surf map"
	if text.begins_with("gg-"):
		return "Gun game map"
	return "Deathmatch map"


static func _def_for(id: StringName, map: ArenaMap) -> DotMapDef:
	if map.is_imported():
		return _imported_def_for(id, map)

	var def := DotMapDef.new()
	def.id = id
	def.version = MAP_VERSIONS.get(id, MAP_VERSION)
	def.display_name = map.display_name
	def.kind = DotMapDef.KIND_ARENA
	def.scene_path = BUILDER_PATH
	def.author = "dot"
	def.enabled = true

	# The tier is a difficulty in a timer game and a size here, and dot-map does not care which — it is an
	# integer a nomination filter and a ballot can sort on. One is a room, ten is a complex. Derived from
	# the map's own extent rather than written down, for this file's own reason.
	def.tier = clampi(int(map.extent / 8.0), 1, 10)

	def.description = "%d boxes, %d spawns, %.0f m across." % [
		map.boxes.size(), map.spawns.size(), map.extent * 2.0
	]

	def.meta = {
		"builder": "ArenaMap.by_id",
		"spawns": map.spawns.size(),
		# Whether the map has tagged spawns, which decides if a team mode can be played on it. A ballot reads this to keep team deathmatch off a map where both sides would share one pool,
		# the symptom of which ("the sides keep spawning in each other's base") reads as a spawn-selection bug.
		"teams": _has_team_spawns(map),
	}

	return def


## The imported combat surf maps in the rotation when nothing says otherwise: every one. g2gfast marks them `"kind": "arena"` and keeps them out of its own rotation, so arena is where they are played.
## `arena_imported_rotation` narrows it (`all`, `none`, or ids separated by commas), read into [member imported_rotation].
const IMPORTED_ROTATION_DEFAULT := "all"


## Which imported maps the rotation, the vote and nominations may offer: `all`, `none` (or empty), or a comma-separated list of ids. See [constant IMPORTED_ROTATION_DEFAULT].
## A map left out is [member DotMapDef.enabled] false (the field dot-map's rotation pool, dot-vote's ballot and nominations read) and stays in the catalogue,
## so a change to it by name still works and a client still recognises it when a server plays it.
static var imported_rotation: String = IMPORTED_ROTATION_DEFAULT


## Whether imported map [param id] is in the rotation under [member imported_rotation].
static func in_rotation(id: StringName) -> bool:
	var wanted := imported_rotation.strip_edges().to_lower()

	if wanted == "all":
		return true

	if wanted == "" or wanted == "none":
		return false

	for part in imported_rotation.split(",", false):
		if StringName(part.strip_edges()) == id:
			return true

	return false


## Puts [member imported_rotation] onto an existing catalogue, for a setting changed on a
## running server. In place, because a rotation holds its catalogue by reference.
static func apply_rotation(catalogue: DotMapCatalogue) -> void:
	if catalogue == null:
		return

	for def in catalogue.maps:
		if bool(def.meta.get("imported", false)):
			def.enabled = in_rotation(def.id)


## An imported map as dot-map content. [b]Local, not delivered[/b] (no `content_id`): on every machine that has it the map is files in this build's tree (the linked fc-surf-dm-maps) that `ArenaMap.by_id` builds, like a built-in.
## The version is its manifest's hash (`ArenaImportedMaps.version_of`), so a server and a client holding different imports of one map disagree at the announce instead of colliding against different brushes.
static func _imported_def_for(id: StringName, map: ArenaMap) -> DotMapDef:
	var def := DotMapDef.new()
	def.id = id
	def.version = ArenaImportedMaps.version_of(id)
	def.display_name = map.display_name
	def.kind = DotMapDef.KIND_ARENA
	def.scene_path = BUILDER_PATH
	def.author = map.author if map.author != "" else "unknown"
	def.enabled = in_rotation(id)
	def.tier = clampi(int(map.extent / 32.0), 1, 10)
	def.description = "%s, %d spawns, %.0f m across." % [
		imported_label(id), map.spawns.size(), maxf(map.bounds.size.x, map.bounds.size.z)
	]
	def.meta = {
		"builder": "ArenaMap.by_id",
		"spawns": map.spawns.size(),
		"teams": _has_team_spawns(map),
		"modes": Array(map.modes),
		"imported": true,
		"manifest": map.manifest_path,
		"movement": String(map.movement_profile),
	}
	return def


## Keys the server named whose pack turned out not to be an arena map, so a refresh does
## not offer them again (and does not warn again).
static var _refused_keys: Dictionary = {}


## Whether a map can host a team mode: some spawn is tagged.
static func _has_team_spawns(map: ArenaMap) -> bool:
	for index in range(map.spawns.size()):
		if map.spawn_tag(index) != &"":
			return true

	return false


## Whether [param def] can host [param mode], by that one property. Used by [ArenaVote] to build a ballot and by [ArenaMapDirector] to pick the next map.
## A free-for-all runs anywhere; a team mode needs somewhere to put the sides.
static func supports_mode(def: DotMapDef, mode: ArenaMode) -> bool:
	if def == null or mode == null:
		return false

	if is_workshop(def) and not build_workshop(def).ok:
		return false

	# A map that lists its modes (maps/<id>.json `modes`, from zones/<id>.json) is asked first:
	# the list is the map author's word on size and layout, which spawns cannot tell.
	var listed: Array = def.meta.get("modes", [])

	if not listed.is_empty():
		if not listed.has(String(mode.id)):
			return false

		if mode.is_team_mode() and not bool(def.meta.get("teams", false)):
			return false

		return true

	# An imported map has no box list, which the monsters' navigation, the objectives' layout and the scattered props are built out of,
	# so a mode needing one would build a hill in mid-air and a navmesh of nothing. It hosts only the modes about the players:
	# free-for-all, gun game, a weapon pool.
	if (bool(def.meta.get("imported", false)) or is_workshop(def)) and needs_built_world(mode):
		return false

	if not mode.is_team_mode():
		return true

	return bool(def.meta.get("teams", false))


## Whether [param mode] builds a layer out of a built-in map's boxes: monsters,
## objectives or props.
static func needs_built_world(mode: ArenaMode) -> bool:
	return (
		mode.horde or mode.objective_layout != &""
		or mode.player_props or mode.scatter_props > 0
	)
