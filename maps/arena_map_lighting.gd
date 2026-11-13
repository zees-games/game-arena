extends RefCounted

## A map's sun, sky and air, as one node a client adds beside the level and replaces with it.
##
## [b]A built-in map's lighting is a dot-lighting document the map carries[/b]
## (`ArenaMap.lighting`), so it changes with the map and a map can be lit differently from
## the next without any code knowing which map it is. [DotLightRig] turns the document into
## a sun and an [Environment]; what stays here is this game's: which [DotLightProfile] a
## machine gets and the shape of the sun's shadow map. The
## reasoning for each is in docs/maps.md, "Colour and light".
##
## [b]An imported map is lit from its manifest's `lighting` block[/b], as game-airdrift
## lights it: the same [DotLightRig] over the sun, ambient, fog and sky the importer read
## out of the compiled map, plus three decisions copied from g2gfast's `G2GLighting` and
## `G2GBspMap` (duplicated on purpose; a game cannot name another game's script): a white
## ambient is the map editor's default and not a sky, so the zenith comes from the sky's
## name ([constant SKY_TOPS]); a sky named black is black all round; and a map that packed
## its own six sky faces draws them (`arena_bsp_sky.gdshader`). The surfaces keep their
## textures and their lightmap: they are unshaded, so the sun lights the players and the
## props, and the fog and the sky are what change around the map.

const ArenaImportedMaps := preload("arena_imported_maps.gd")
const ArenaBspMap := preload("arena_bsp_map.gd")
const ArenaPaths := preload("../game/arena_paths.gd")

const CHANNEL := "arena.lighting"
const SKY_SHADER := preload("arena_sky.gdshader")

## The fixed light for a map that is not there (a null map, or an imported one whose
## manifest cannot be read): a sun and a flat grey-blue, what every imported map had before
## its own block was read.
const FIXED_SKY := Color(0.36, 0.42, 0.52)
const FIXED_AMBIENT := Color(0.55, 0.58, 0.64)


## The lighting [param map] asks for, under one node named `Lighting`.
static func build(map: Object) -> Node3D:
	var root := Node3D.new()
	root.name = "Lighting"

	if map == null:
		_fixed(root)
		return root

	if map.is_imported():
		_build_imported(root, map)
		return root

	var lighting: Dictionary = map.lighting
	var sun := DotLightRig.apply(root, DotLightDocument.from_dictionary(lighting), profile())
	if sun != null and sun.shadow_enabled:
		# One orthogonal shadow map over the whole map rather than four cascades: the
		# largest built-in map is 64 m across, so one map covers it at a usable resolution,
		# and it is one depth pass instead of four, which is what lets a browser keep it.
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = maxf(float(map.extent) * 3.0, 60.0)

	if sun != null:
		_cloud_sky(root, sun)

	return root


## The rig's gradient sky replaced by `arena_sky.gdshader`: the same colours (so the horizon
## still meets the fog) with clouds and a sun glow.
static func _cloud_sky(root: Node3D, sun: DirectionalLight3D) -> void:
	for child in root.get_children():
		var world := child as WorldEnvironment

		if world == null or world.environment == null or world.environment.sky == null:
			continue

		var old := world.environment.sky.sky_material as ProceduralSkyMaterial

		if old == null:
			return

		var mat := ShaderMaterial.new()
		mat.shader = SKY_SHADER
		mat.set_shader_parameter("top_colour", old.sky_top_color)
		mat.set_shader_parameter("horizon_colour", old.sky_horizon_color)
		mat.set_shader_parameter("sun_colour", sun.light_color)
		# A light shines along its -Z, so the sun is toward +Z.
		mat.set_shader_parameter("sun_dir", sun.transform.basis.z)
		world.environment.sky.sky_material = mat
		return


## What this machine draws of a map's lighting: dot-lighting's `painted()`.
##
## [b]`painted()` is the family's profile for flat-painted boxes[/b] (dot-lighting API 3):
## a longer filmic shoulder and a lower exposure, a contrast and saturation grade, ambient
## occlusion where Forward+ can draw it, and a shadowless fill from the side the sun is not
## on, so a crate's two shaded faces are two shades under Compatibility, which has no
## occlusion. Its light numbers are per renderer: the client shell draws Compatibility
## everywhere, which clips before it tone maps. This game's own grade and its hand-set
## Compatibility numbers (reference 700, ambient 0.45) were the first try at the same thing
## and moved into dot-lighting so every painted game gets it; measured on dm_box from a
## player's eye, the sunlit floor went 0.88 -> 0.70 luminance with the darker `GROUND`.
##
## [b]A browser gets the sun's shadows put back.[/b] `web()` drops them because on a large
## imported level the shadow pass draws the whole level a second time. A built-in map here
## is under a hundred boxes, and drawn without shadows it loses the sunlit look entirely
## (rendered and compared: flat, every face lit alike), which is most of what this lighting
## is for. [method build] makes it one orthogonal pass. There is no capability query for
## "this GPU is slow", so the platform is the question here.
##
## [b]The sky continues under the horizon.[/b] These maps are walled, so from inside it is
## never seen; from above (an overview, a spectator) the default dark ground half is a brown
## void around a bright map, which is the first thing the old look was criticised for.
static func profile() -> DotLightProfile:
	var p := DotLightProfile.painted()
	p.sun_shadows = true
	p.sky_below_horizon = true
	return p


# imported map

## An imported map under its own manifest's lighting.
static func _build_imported(root: Node3D, map: Object) -> void:
	var manifest := ArenaImportedMaps.manifest(map.id)

	# A local copy has no legacy lighting block, which is expected rather than a broken manifest.
	if manifest.is_empty() and str(map.get("local_prefix")) != "":
		_fixed(root)
		return

	if manifest.is_empty():
		DotLog.warn(CHANNEL, "an imported map's manifest did not read; it gets the fixed light", {
			"map": String(map.id),
		})
		_fixed(root)
		return

	var lighting: Dictionary = manifest.get("lighting", {}) if manifest.get("lighting") is Dictionary else {}
	var document := imported_document(lighting)
	var _sun := DotLightRig.apply(root, DotLightDocument.from_dictionary(document), imported_profile())
	_apply_named_sky(root, str(lighting.get("sky_name", "")))
	_apply_air(root, map)

	if is_black_sky(lighting):
		_darken(root)

	_apply_packed_sky(root, lighting, str(map.manifest_path).get_base_dir())


## The document an imported map is drawn from: its own block, with a `sky_top` where its
## ambient cannot stand for the sky ([method white_sky_replacement]).
static func imported_document(lighting: Dictionary) -> Dictionary:
	var document := lighting.duplicate(true)
	var top := white_sky_replacement(lighting)

	if top.a > 0.0 and not document.has("sky_top"):
		document["sky_top"] = [top.r, top.g, top.b]

	return document


## What this machine draws of an imported map: g2gfast's choice for the same maps.
##
## [b]A browser drops the sun's shadows and keeps the glow[/b] (dot-lighting's `web()`): a
## surf map is a large open volume, so a shadow pass costs the whole canyon, while the glow
## is what makes a neon strip read as a light. [b]The sky continues under the horizon[/b]:
## these maps float inside their sky, and the default dark ground half turns every glance
## down between two ramps into a floor that is not there.
static func imported_profile() -> DotLightProfile:
	var p := DotLightProfile.web() if OS.has_feature("web") else DotLightProfile.high()
	p.sky_below_horizon = true
	return p


## A clear day's zenith, for a sky [constant SKY_TOPS] does not know.
const CLEAR_SKY := Color(0.36, 0.55, 0.82)

## The top of a sky by the name a map gives it, for a map whose ambient cannot say. Lower case, without the `_hdr` suffix. A copy of g2gfast's `G2GLighting.SKY_TOPS`:
## the stock names are approximate zeniths picked by eye (the textures are not in any map), the custom ones the ambient another map set under the same sky name.
const SKY_TOPS := {
	"sky_day01_01": Color(0.37, 0.56, 0.82),
	"sky_day01_04": Color(0.40, 0.58, 0.80),
	"sky_day01_05": Color(0.42, 0.60, 0.82),
	"sky_day01_06": Color(0.45, 0.55, 0.70),
	"sky_day01_07": Color(0.40, 0.56, 0.78),
	"sky_day01_08": Color(0.38, 0.55, 0.80),
	"sky_day01_09": Color(0.42, 0.57, 0.78),
	"sky_day02_01": Color(0.52, 0.56, 0.62),
	"sky_dust": Color(0.55, 0.62, 0.72),
	"sky_borealis01": Color(0.12, 0.18, 0.30),
	"sky_wasteland02": Color(0.55, 0.60, 0.62),
	"militia": Color(0.62, 0.68, 0.76),
	"italy": Color(0.40, 0.58, 0.84),
	"office": Color(0.46, 0.52, 0.60),
	"assault": Color(0.50, 0.58, 0.68),
	"tides": Color(0.42, 0.62, 0.86),
	"cx": Color(0.40, 0.56, 0.80),
	"mpa52": Color(0.53, 0.73, 0.93),
	"space_13": Color(0.46, 0.42, 0.76),
	"mpa104": Color(0.49, 0.62, 0.80),
	"hav": Color(0.30, 0.30, 0.46),
}


## The zenith a map should have instead of its ambient, or transparent when its ambient is
## usable.
##
## [b]A white ambient is not a statement about the sky.[/b] dot-lighting draws the top of
## the sky in the map's ambient, which is the colour the sky lit the map with; a mapper who
## never set it compiles with the editor's default white, and the map is drawn under a
## blank white dome. Ten of the thirty-three combat surf maps carry exactly that white. Only the sky
## changes; the ambient light stays the map's.
static func white_sky_replacement(lighting: Dictionary) -> Color:
	var sun: Dictionary = lighting.get("sun", {}) if lighting.get("sun") is Dictionary else {}
	var ambient: Variant = sun.get("ambient_colour", null)

	if not (ambient is Array) or (ambient as Array).size() < 3:
		return Color(0, 0, 0, 0)

	for c: Variant in (ambient as Array).slice(0, 3):
		if float(c) < 0.99:
			return Color(0, 0, 0, 0)

	var name := str(lighting.get("sky_name", "")).to_lower().trim_suffix("_hdr")
	return SKY_TOPS.get(name, CLEAR_SKY)


## Whether a map's sky is black by name. A sky called black is a statement about the sky
## (a map built as lit lines on black), and the default daylight dome round it is the
## brightest thing on screen wherever a wall is open. g2gfast's rule.
static func is_black_sky(lighting: Dictionary) -> bool:
	return str(lighting.get("sky_name", "")).to_lower().contains("black")


static func _darken(root: Node3D) -> void:
	for child in root.get_children():
		var world := child as WorldEnvironment

		if world == null or world.environment == null:
			continue

		var env := world.environment
		env.background_color = Color.BLACK
		env.fog_light_color = Color.BLACK
		var mat := env.sky.sky_material as ProceduralSkyMaterial if env.sky != null else null

		if mat == null:
			continue

		mat.sky_top_color = Color.BLACK
		mat.sky_horizon_color = Color.BLACK
		mat.ground_horizon_color = Color.BLACK
		mat.ground_bottom_color = Color.BLACK


## The map's own six-face sky, over the procedural one, when the importer found one in its
## pakfile (`lighting.sky_faces`). All six or none: a missing face is a hole in the
## horizon, so one that does not load leaves the procedural sky.
## The family's panorama for the map's sky name; an unknown or missing name keeps the gradient.
static func _apply_named_sky(root: Node3D, sky_name: String) -> void:
	var mat := DotMapBspMesh.sky_material_for(sky_name)

	if mat == null:
		return

	for child in root.get_children():
		var world := child as WorldEnvironment

		if world == null or world.environment == null:
			continue

		var env := world.environment

		if env.sky == null:
			env.sky = Sky.new()

		env.sky.sky_material = mat
		env.background_mode = Environment.BG_SKY


static func _apply_packed_sky(root: Node3D, lighting: Dictionary, dir: String) -> void:
	var faces: Variant = lighting.get("sky_faces", null)

	if not (faces is Dictionary) or (faces as Dictionary).size() < 6:
		return

	var mat := ShaderMaterial.new()
	mat.shader = load(ArenaPaths.rebase("res://maps/arena_bsp_sky.gdshader"))

	for suffix: String in ["rt", "lf", "bk", "ft", "up", "dn"]:
		var tex := ArenaBspMap._load_texture(
			dir.path_join("textures").path_join(str((faces as Dictionary).get(suffix, "")))
		)

		if tex == null:
			DotLog.warn(CHANNEL, "a packed sky face did not load; the sky stays a colour", {"face": suffix})
			return

		mat.set_shader_parameter("face_" + suffix, tex)

	for child in root.get_children():
		var world := child as WorldEnvironment

		if world == null or world.environment == null:
			continue

		var env := world.environment

		if env.sky == null:
			env.sky = Sky.new()

		env.sky.sky_material = mat
		env.background_mode = Environment.BG_SKY


# per-map air

## What a map's compiled lighting block cannot say, one entry per map: the importer reads no
## fog or sea from a BSP, so the two maps whose original looks need them are patched here.
## `fog` is an overcast haze (`colour`, exponential `density`, how far it reaches into the
## panorama as `sky_affect`, and a `sky_energy` that dims the panorama); `sea` is a sheet of
## the water shader `depth` metres under the lowest brush, in `tint`. Stand-ins only:
## nothing here is a source texture.
const MAP_AIR := {
	# The original is overcast and raining: a grey, close horizon and a dull sky.
	&"surf_japan_ptad": {
		"fog": {"colour": Color(0.50, 0.54, 0.58), "density": 0.0015, "sky_affect": 0.5, "sky_energy": 0.62},
	},
	# The original floats over an open sea; the compiled map has no water under it.
	&"surf_skyworld": {
		"sea": {"depth": 14.0, "size": 6000.0, "tint": Color(0.06, 0.20, 0.30, 1.0)},
	},
}


static func _apply_air(root: Node3D, map: Object) -> void:
	var air: Dictionary = MAP_AIR.get(StringName(map.id), {})

	if air.is_empty():
		return

	if air.has("fog"):
		_apply_fog(root, air["fog"])

	if air.has("sea"):
		_apply_sea(root, map, air["sea"])


static func _apply_fog(root: Node3D, fog: Dictionary) -> void:
	for child in root.get_children():
		var world := child as WorldEnvironment

		if world == null or world.environment == null:
			continue

		var env := world.environment
		env.fog_enabled = true
		env.fog_light_color = fog["colour"]
		env.fog_density = float(fog["density"])
		env.fog_sky_affect = float(fog["sky_affect"])
		env.background_energy_multiplier = float(fog["sky_energy"])


## A wide water sheet under the map, the same shader the pools use.
static func _apply_sea(root: Node3D, map: Object, sea: Dictionary) -> void:
	var image := Image.create(1, 1, false, Image.FORMAT_RGB8)
	image.fill(Color.WHITE)
	var mat := ShaderMaterial.new()
	mat.shader = load(ArenaPaths.rebase("res://maps/arena_bsp_water.gdshader"))
	mat.set_shader_parameter("lightmap_tex", ImageTexture.create_from_image(image))
	mat.set_shader_parameter("tint", sea["tint"])
	mat.set_shader_parameter("light_boost", 0.7)
	mat.set_shader_parameter("ambient", 0.15)
	mat.set_shader_parameter("alpha_down", 0.92)
	mat.set_shader_parameter("alpha_grazing", 0.97)

	var plane := PlaneMesh.new()
	plane.size = Vector2(float(sea["size"]), float(sea["size"]))
	plane.material = mat
	var sheet := MeshInstance3D.new()
	sheet.name = "Sea"
	sheet.mesh = plane
	sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bounds: AABB = map.bounds
	sheet.position = Vector3(bounds.get_center().x, bounds.position.y - float(sea["depth"]), bounds.get_center().z)
	root.add_child(sheet)


static func _fixed(root: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.shadow_enabled = true
	root.add_child(sun)

	var world := WorldEnvironment.new()
	world.name = "Environment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = FIXED_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = FIXED_AMBIENT
	environment.ambient_light_energy = 0.75
	world.environment = environment
	root.add_child(world)
