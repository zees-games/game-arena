extends RefCounted

## A map's sun, sky and air, as one node a client adds beside the level and replaces with it.
##
## [b]A built-in map's lighting is a dot-lighting document the map carries[/b]
## (`ArenaMap.lighting`), so it changes with the map and a map can be lit differently from
## the next without any code knowing which map it is. [DotLightRig] turns the document into
## a sun and an [Environment]; what stays here is this game's: which [DotLightProfile] a
## machine gets, the zenith (`sky_top`), and the shape of the sun's shadow map. The
## reasoning for each is in docs/maps.md, "Colour and light".
##
## An imported map keeps the fixed light it had before: its surfaces are unshaded and lit by
## their own lightmap, so only the post-processing would change, and that is a separate
## piece of work (its manifest's `lighting` block is what it would read).

## The fixed light every map had before the built-in ones carried their own.
const IMPORTED_SKY := Color(0.36, 0.42, 0.52)
const IMPORTED_AMBIENT := Color(0.55, 0.58, 0.64)


## The lighting [param map] asks for, under one node named `Lighting`.
static func build(map: Object) -> Node3D:
	var root := Node3D.new()
	root.name = "Lighting"

	if map == null or map.is_imported():
		_imported(root)
		return root

	var lighting: Dictionary = map.lighting
	var sun := DotLightRig.apply(root, DotLightDocument.from_dictionary(lighting), profile())
	_paint_sky_top(root, lighting)

	if sun != null and sun.shadow_enabled:
		# One orthogonal shadow map over the whole map rather than four cascades: the
		# largest built-in map is 64 m across, so one map covers it at a usable resolution,
		# and it is one depth pass instead of four, which is what lets a browser keep it.
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = maxf(float(map.extent) * 3.0, 60.0)

	return root


## The zenith in the document's `sky_top`, where the map gives one.
##
## dot-lighting draws the top of the sky in the ambient colour, because in a world it
## imports the ambient was measured from the sky. Here the ambient is chosen for the shade
## and is paler than any sky, so the map names its zenith separately. g2gfast repaints its
## sky after the rig the same way.
static func _paint_sky_top(root: Node3D, lighting: Dictionary) -> void:
	var top: Variant = lighting.get("sky_top", null)

	if not (top is Array and (top as Array).size() >= 3):
		return

	for node in root.get_children():
		if node is WorldEnvironment and (node as WorldEnvironment).environment.sky != null:
			var material := (node as WorldEnvironment).environment.sky.sky_material as ProceduralSkyMaterial
			if material != null:
				material.sky_top_color = Color(float(top[0]), float(top[1]), float(top[2]))
				# [method profile] mirrors the sky under the horizon, from the top colour the
				# rig built it with; the mirror follows the repaint.
				material.ground_bottom_color = material.sky_top_color


## What this machine draws of a map's lighting.
##
## [b]A browser gets dot-lighting's `web()` with the sun's shadows put back.[/b] `web()`
## drops them because on a large imported level the shadow pass draws the whole level a
## second time. A built-in map here is under a hundred boxes, and drawn without shadows
## it loses the sunlit look entirely (rendered and compared: flat, every face lit alike),
## which is most of what this lighting is for. [method build] makes it one orthogonal
## pass. There is no capability query for "this GPU is slow", so the platform is the
## question here.
##
## [b]The sky continues under the horizon.[/b] These maps are walled, so from inside it is
## never seen; from above (an overview, a spectator) the default dark ground half is a brown
## void around a bright map, which is the first thing the old look was criticised for.
static func profile() -> DotLightProfile:
	var p := DotLightProfile.web() if OS.has_feature("web") else DotLightProfile.high()
	p.sun_shadows = true
	p.sky_below_horizon = true
	# Full-strength fill: the reference look's shade is light, and a pastel at 0.8 of a
	# pale ambient reads as a dirty version of itself.
	p.ambient_energy = 1.0

	# [b]The Compatibility renderer has no headroom above white, so the same light is
	# turned down for it.[/b] Forward+ lights into an HDR buffer and the filmic curve rolls
	# a sunlit pastel (sun about 1.4 plus a full ambient) back under white; Compatibility
	# clips it, and every sunlit face rendered as flat white with the colour gone. The
	# client shell runs Compatibility on every platform, so this is the look most players
	# get. Measured side by side: these two numbers put both renderers' frames within a
	# shade of each other. The world is the same; this is what the machine can draw of it.
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		p.brightness_reference = 700.0
		p.ambient_energy = 0.62
	return p


static func _imported(root: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.shadow_enabled = true
	root.add_child(sun)

	var world := WorldEnvironment.new()
	world.name = "Environment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = IMPORTED_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = IMPORTED_AMBIENT
	environment.ambient_light_energy = 0.75
	world.environment = environment
	root.add_child(world)
