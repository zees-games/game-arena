extends RefCounted

const ArenaPaths := preload("../game/arena_paths.gd")

## What colour each box of a built-in map is drawn in, decided from the box list rather
## than written into it.
##
## [b]The box list stays geometry and nothing else.[/b] It is what the movement body, the
## shot trace and the survey are built from, and `MAP_VERSIONS` says when it changed; a
## colour carried inside it would make a repaint look like a geometry change to anything
## that compares lists. So a box's paint is a function of the box (its shape says its
## role) and of the map's zones (its position says where it is), and the survey never
## sees either.
##
## [b]Colour by role, then by place, so a position can be called out.[/b] The ground is
## light; a structure and its stairs are its zone's pastel ("pink stairs", "the mint
## arcade"); a walkway slab is that pastel paled, so the surfaces a player runs on stay
## light; cover is an accent that is never a zone colour, so a crate reads as a crate
## against any wall. A zone is either named by the map (`ArenaMap.paint_zones`) or, when
## no named zone holds the box, its compass side: north is -Z, as the map docs say.
##
## The texture is Kenney's prototype grid (CC0, `assets/prototype/`), light grey with white
## lines, tinted per material. Tinting one light texture keeps the grid identical on every
## surface, which is what lets the grid measure distance the same everywhere.

enum Role { WALL, STRUCTURE, SLAB, TREAD, COVER }

## The zone colours. Albedo, sRGB; the grid texture under them is about 0.82 grey, so they
## land a step darker. Saturated pastels rather than pale ones: the first play test's
## frames were near white everywhere (pale paint, a white floor, a full ambient), and a
## player in them had nothing to stand out against.
const LAVENDER := Color(0.62, 0.48, 0.96)
const MINT := Color(0.30, 0.84, 0.60)
const PINK := Color(0.98, 0.50, 0.72)
const BUTTER := Color(1.00, 0.80, 0.28)
const SKY := Color(0.36, 0.64, 0.98)
## A zone that is not a compass side: dm_atrium's north gallery, the wall-run ledges. Cool on
## purpose: it lies in the north wall's shade, and the warm pastels tried there (a peach, a
## coral) went brown under the cool ambient in both renderers, where this stays a pastel.
const AQUA := Color(0.24, 0.76, 0.80)

## Cover. Saturated where the zones are soft, and never one of them.
const ACCENT := Color(1.00, 0.62, 0.10)
## Cover inside a butter-yellow zone, where the yellow accent would vanish.
const ACCENT_ALT := Color(0.94, 0.30, 0.42)

## The ground: a mid cool grey, so the sun reads warm on it and a player stands out
## against it. It was near white, which was most of what read as washed out, and then
## (0.74, 0.76, 0.84), whose sunlit floor still rendered at 0.79 luminance under the
## Compatibility renderer the client shell uses; this lands it at 0.70, a light grey.
const GROUND := Color(0.62, 0.64, 0.72)

## Compass sides, for a box no named zone holds. The perimeter wall on each side takes the
## same colour, so the wall behind a fight says which side of the map it is.
const NORTH := LAVENDER
const EAST := SKY
const SOUTH := MINT
const WEST := PINK
const CENTRE := BUTTER

## How far a walkway slab is paled toward white.
const SLAB_PALE := 0.3
## How far a perimeter wall is paled: it fills most of every frame and at full strength
## one colour drowns the rest.
const WALL_PALE := 0.12

## Photographic surfaces (ambientCG, CC0) by role, from dot-map's `DotMapSurfaces`, vendored into
## `assets/surfaces` (client-only in `sides.json`). The zone colour still says where a thing is:
## it multiplies the photograph, paled toward white by `PHOTO_PALE` because the colours were
## chosen against a light grid and a photograph under a full pastel went muddy. A build without
## the textures (a checkout not imported, an older shell) draws the Kenney grid as it did.
const SURFACES_SCRIPT := "res://addons/dot_map/surfaces/dot_map_surfaces.gd"
const SURFACES_ROOT := "res://assets/surfaces"
const KIND_OF_ROLE := {
	Role.WALL: &"brick",
	Role.STRUCTURE: &"plaster",
	Role.SLAB: &"concrete_clean",
	Role.TREAD: &"metal",
	Role.COVER: &"wood_planks",
}
const KIND_GROUND := &"concrete"
const PHOTO_PALE := {
	Role.WALL: 0.82, Role.STRUCTURE: 0.62, Role.SLAB: 0.7, Role.TREAD: 0.85, Role.COVER: 0.35,
}
const PHOTO_PALE_GROUND := 0.8
## A photograph is darker than the 0.82 grey grid, so the tint is lifted a little too.
const PHOTO_GAIN := 1.2
## Concrete slabs are the brightest photograph and a walkway fills the frame from above.
const PHOTO_GAIN_SLAB := 0.9

const GRID_PATH := "res://assets/prototype/grid.png"
const TILES_PATH := "res://assets/prototype/tiles.png"

## One grid square of the texture's major lines is this many metres.
##
## The texture has two major cells across, so a tile of 4 m puts a major line every 2 m and
## a faint one every 0.5 m: the 0.5 m is what a crate gap and a stair tread are measured in.
const TILE_METRES := 4.0


## The role a box plays, from its shape and where it stands.
static func role_of(box: AABB, extent: float) -> Role:
	var lo := box.position
	var hi := box.end

	if lo.x < -extent - 0.01 or hi.x > extent + 0.01 or lo.z < -extent - 0.01 or hi.z > extent + 0.01:
		return Role.WALL

	var narrow := minf(box.size.x, box.size.z)
	var wide := maxf(box.size.x, box.size.z)

	# A stair tread: one step deep, a stair wide. A pier is narrow both ways and is not.
	if narrow <= 1.0 and wide >= 2.5 and box.size.y <= 5.0:
		return Role.TREAD

	# Something walked on: a ledge, a gantry, a ring, a bridge.
	if box.size.y <= 1.0 and wide > 3.6:
		return Role.SLAB

	# A column: slim and over head height. It holds something up (the arcade's roof), so it
	# belongs to its zone; painted as cover, a colonnade read as a row of crates.
	if wide <= 1.6 and box.size.y >= 2.5:
		return Role.STRUCTURE

	# A crate, at chest-to-head height.
	if wide <= 3.6 and box.size.y <= 3.7:
		return Role.COVER

	return Role.STRUCTURE


## The zone colour at a point: the first named zone holding it, else its compass side.
static func zone_colour(at: Vector3, zones: Array[Dictionary], extent: float) -> Color:
	for zone in zones:
		var region: AABB = zone["region"]
		if region.grow(0.01).has_point(Vector3(at.x, region.get_center().y, at.z)):
			return zone["colour"]

	if absf(at.x) < extent * 0.3 and absf(at.z) < extent * 0.3:
		return CENTRE

	if absf(at.z) >= absf(at.x):
		return NORTH if at.z < 0.0 else SOUTH

	return WEST if at.x < 0.0 else EAST


## The colour box [param index] of [param map] is drawn in.
static func colour_of(map: Object, index: int) -> Color:
	var box: AABB = map.boxes[index]
	var zones: Array[Dictionary] = map.paint_zones
	var zone := zone_colour(box.get_center(), zones, map.extent)

	match role_of(box, map.extent):
		Role.WALL:
			return zone.lerp(Color.WHITE, WALL_PALE)
		Role.SLAB:
			return zone.lerp(Color.WHITE, SLAB_PALE)
		Role.COVER:
			return ACCENT_ALT if zone == BUTTER else ACCENT
		_:
			return zone


## Builds the materials for a map: one per colour, shared by every box of that colour.
##
## [b]Shared, because the browser build draws with the Compatibility renderer[/b], where a
## material change is a state change per draw; ninety boxes in a handful of materials batch
## where ninety materials would not.
class Painter:
	var _cache: Dictionary = {}
	var _grid: Texture2D = null
	var _tiles: Texture2D = null

	func _init() -> void:
		_grid = _texture(GRID_PATH)
		_tiles = _texture(TILES_PATH)

	var _surfaces: Object = null
	var _surfaces_tried := false

	## The material for a box of [param role] painted [param colour]: a photograph tinted by the
	## colour when this build has the textures, else the grid ([method box]).
	func role_box(role: Role, colour: Color) -> StandardMaterial3D:
		var kind: StringName = KIND_OF_ROLE.get(role, &"")
		return _photo(kind, colour, PHOTO_PALE[role], PHOTO_GAIN_SLAB if role == Role.SLAB else PHOTO_GAIN) if kind != &"" else box(colour)

	func photo_ground() -> StandardMaterial3D:
		var m := _photo(KIND_GROUND, GROUND, PHOTO_PALE_GROUND)
		return m if m != null else ground()

	func _photo(kind: StringName, colour: Color, pale_by: float, gain: float = PHOTO_GAIN) -> StandardMaterial3D:
		var key := "photo:%s:%s:%s:%s" % [kind, colour.to_html(false), pale_by, gain]
		if _cache.has(key):
			return _cache[key]
		var lib := _library()
		var made: StandardMaterial3D = null
		if lib != null:
			var pale := colour.lerp(Color.WHITE, pale_by) * gain
			pale.a = 1.0
			var res: DotResult = lib.try_material(kind, pale)
			if res.ok:
				made = res.value
		if made == null:
			made = box(colour)
		_cache[key] = made
		return made

	func _library() -> Object:
		if _surfaces_tried:
			return _surfaces
		_surfaces_tried = true
		if ResourceLoader.exists(SURFACES_SCRIPT) \
				and ResourceLoader.exists(ArenaPaths.rebase(SURFACES_ROOT) + "/concrete/albedo.jpg"):
			_surfaces = (load(SURFACES_SCRIPT) as GDScript).new(ArenaPaths.rebase(SURFACES_ROOT))
		return _surfaces

	func box(colour: Color) -> StandardMaterial3D:
		var key := "box:" + colour.to_html(false)
		if not _cache.has(key):
			_cache[key] = _material(_grid, colour)
		return _cache[key]

	func ground() -> StandardMaterial3D:
		if not _cache.has("ground"):
			_cache["ground"] = _material(_tiles, GROUND)
		return _cache["ground"]

	static func _texture(path: String) -> Texture2D:
		# Through the rebase, because a delivered game's art is under its mount, not at the
		# path it was authored at (see `arena_paths.gd`).
		var at := ArenaPaths.rebase(path)
		if ResourceLoader.exists(at):
			var loaded := load(at) as Texture2D
			if loaded != null:
				return loaded
		# Not an error worth stopping for: a checkout that has not been imported yet still
		# draws a map, in the generated grid it drew before these textures existed.
		return null

	static func _material(texture: Texture2D, tint: Color) -> StandardMaterial3D:
		var material := StandardMaterial3D.new()
		material.albedo_color = tint
		if texture != null:
			material.albedo_texture = texture
			material.uv1_scale = Vector3.ONE / TILE_METRES
		else:
			material.albedo_texture = _fallback()
			material.uv1_scale = Vector3(0.5, 0.5, 0.5)
		# Triplanar, because a BoxMesh maps every face to one 0..1 square: without it a crate
		# and a forty-metre wall show the same number of squares and the grid stops saying
		# anything about size, which is its only job.
		material.uv1_triplanar = true
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		material.roughness = 0.85
		material.metallic = 0.0
		return material

	static func _fallback() -> Texture2D:
		var image := Image.create(128, 128, false, Image.FORMAT_RGB8)
		image.fill(Color(0.82, 0.83, 0.85))
		for i in range(128):
			for j in [0, 64]:
				image.set_pixel(i, j, Color.WHITE)
				image.set_pixel(j, i, Color.WHITE)
		return ImageTexture.create_from_image(image)
