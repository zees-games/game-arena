extends RefCounted

const ArenaMap := preload("arena_map.gd")
const ArenaBspMap := preload("arena_bsp_map.gd")
const ArenaGlassTrace := preload("../game/arena_glass_trace.gd")
const ArenaImportedMaps := preload("arena_imported_maps.gd")
const ArenaMapMechanics := preload("arena_map_mechanics.gd")
const ArenaMapPaint := preload("arena_map_paint.gd")
const ArenaJail := preload("arena_jail.gd")
const ArenaPaths := preload("../game/arena_paths.gd")

## A pack's kind in [member packs]: `ArenaDrops.Kind.HEALTH` and `.AMMO`, written out here so a
## map does not depend on the game (a headless check holds the two together).
const PACK_HEALTH := 1
const PACK_AMMO := 2

const CONTACT_SHADE_SCRIPT := "res://addons/dot_lighting/runtime/dot_contact_shade.gd"

## Baked light for the built-in maps (dot-lighting API 5): `lightmaps/<id>.res`, made by
## tools/bake_lightmaps.sh. Reached by path so a shell with an older dot-lighting still draws the map.
const BAKE_SCRIPT := "res://addons/dot_lighting/bake/dot_light_bake.gd"
const SHEET_SCRIPT := "res://addons/dot_lighting/bake/dot_lightmap_sheet.gd"
const BAKE_PATH := "res://lightmaps/%s.res"
## Bump when what a bake means changes beyond the boxes and the sun (tools/lightmap_scenes.gd).
const BAKE_VERSION := 1

## Whether a client looks for a map's bake at all.
static var use_bakes: bool = true

## Whether an imported map is drawn from its converted world when one is linked at `res://worlds`.
static var use_worlds: bool = true

## A level as a list of boxes, and the three things that list becomes. The boxes are declared once
## here and become a [MeshInstance3D] set to see, [StaticBody3D]s for physics, and analytic [AABB]s
## for [DotFpsFlatBody] and [DotTraceFlat] (a headless server has no physics space).

# No `CHANNEL`: a map is content and says nothing at runtime — it is built, turned into
# three representations, and checked in `headless_match`. The session that loads it logs.

## Solid boxes, in world space.
var boxes: Array[AABB] = []

## Ground plane height. Boxes sit on it.
var floor_y: float = 0.0

## Half-extent of the playable area on X and Z. Walls are generated at the edges.
var extent: float = 24.0

## Wall height.
var wall_height: float = 8.0

## Where players appear. Fed into [DotMatch]'s spawn points.
var spawns: Array[Transform3D] = []

## What each spawn belongs to, parallel to [member spawns]. Empty means every spawn is untagged and
## any player may use any of them, which is what a free-for-all wants.
var spawn_tags: PackedStringArray = PackedStringArray()

## What [method by_id] answers to, and what a [DotMapDef] is keyed on.
var id: StringName = &"dm_box"

var display_name: String = "dm_box"

## Every climb this map asks a player to make, derived from the boxes themselves. [b]Always append
## through [method add_climb], and never write this by hand.[/b] See [method jump_reach] for why
## this list exists at all.
var climbs: Array[Climb] = []

## Every route this map builds for the walls: a wall run or a wall jump from one box's top to
## another's, past what the ordinary movement reaches.
var wall_routes: Array[Dictionary] = []

## Top faces a player is deliberately never meant to stand on.
##
## `[gate-sweep-1]`'s second question is whether a map has floor nobody can reach, and
## the honest answer for most maps is "yes, on purpose": a pillar's top is a surface,
## and a pillar you could climb would be a different map. The survey in `headless_match`
## flood-fills every map and fails on any unreached surface that is not one of these,
## so an unreachable top is a decision somebody wrote down rather than a thing nobody
## noticed. Append through [method add_out_of_reach].
var out_of_reach: Array[AABB] = []

## Named colour zones, checked before the compass sides: `{name, region: AABB, colour}`.
##
## [b]Paint, not geometry: nothing that reads [member boxes] reads this.[/b] The survey,
## the movement body, the trace and `MAP_VERSIONS` see the same list they saw before, so a
## repaint is never a new map. See `arena_map_paint.gd` for how a box's colour is chosen.
var paint_zones: Array[Dictionary] = []

## How this map is lit: a dot-lighting document (`DotLightDocument.from_dictionary`).
##
## Carried by the map so it changes with the map; `arena_map_lighting.gd` applies it.
var lighting: Dictionary = DAYLIGHT.duplicate(true)

## A clear afternoon: a warm sun high in the south-west, a blue sky, a little haze at the
## far walls.
##
## [b]The sun angles are in dot-lighting's source convention[/b] (a negative pitch is a sun
## in the sky; `DotLightRig.sun_rotation` converts the direction, not the angles). The
## brightness is what the rig divides by its reference (200) and square-roots, so 380 is an
## energy of about 1.4. The ambient colour is the light in the shade: a pale cool grey, not
## a sky blue, because at the ambient's strength a saturated blue turns every shaded face
## navy and a yellow crate olive. The fog is what the horizon is drawn in and hazes only
## the far side of dm_atrium's yard; its distances are source units (metres / 0.01905).
##
## `sky_top` is this game's, not dot-lighting's (the document ignores keys it does not
## know): dot-lighting draws the zenith in the ambient colour, which is right for a world
## whose ambient was measured from its sky and wrong here, where the shade is deliberately
## paler than the sky. `arena_map_lighting.gd` repaints the zenith with it.
const DAYLIGHT := {
	"sun": {
		"pitch_src": -50.0,
		"yaw_src": -35.0,
		"colour": [1.0, 0.93, 0.80],
		"brightness": 380.0,
		"spread_degrees": 1.0,
		"ambient_colour": [0.74, 0.78, 0.92],
	},
	"fog": {
		"enabled": true,
		"colour": [0.80, 0.89, 1.0],
		"start": 2600.0,
		"end": 12000.0,
		"max_density": 0.12,
	},
	"sky_top": [0.30, 0.56, 0.96],
}

# --- An imported map -------------------------------------------------------
#
# [b]The one place this class is not a list of boxes.[/b] A combat surf map imported by
# game-g2gfast is a compiled level of a few thousand convex brushes, and its collision is
# the brushes themselves in Godot's physics space (`ArenaBspMap.build_collision`) — there
# is no list of boxes it could be reduced to without losing the ramps, which are the
# whole map. So an imported map has no `boxes`; [method movement_body] and
# [method shot_trace] answer with the physics backends instead of the analytic ones, and
# the game puts the solid in the tree on EVERY machine, a dedicated server included,
# before anything moves or shoots. That keeps this class's rule — one description, every
# representation generated from it — with the manifest as the description.

## The manifest this map was built from; empty for a built-in map.
var manifest_path: String = ""

## The manifest's `kind` (`arena` for the maps this game plays).
var source_kind: String = ""

## Who made it, from the manifest. Shown on a map change; an imported map is somebody
## else's work and the credit travels with it.
var author: String = ""

## The movement this map asks for: `&"surf"` for a combat surf map, empty for the
## arena's own. See `ArenaPlayer.apply_map_movement` for what each means, and
## `ArenaGame.map_movement` for the rule that can switch it off.
var movement_profile: StringName = &""

## The space the map occupies, in metres. A built-in map leaves it empty.
var bounds: AABB = AABB()

## The map's teleport volumes: `{box: AABB, to: Vector3, yaw: float}`. A player whose feet
## enter one is put at its destination facing its yaw; on a combat surf map those are
## the pits under the ramps and the ways into and out of its jail.
var pits: Array[Dictionary] = []

## The map's jail, found among its pits (see `arena_jail.gd`); null when it has none. Its state
## (the gate) belongs to the game that loaded the map, which is why it lives on this instance.
var jail: RefCounted = null

## What the map's brush entities do to a player — pushes, water, ladders, gravity,
## conveyors and hurt — read from the manifest's `mechanics` block. Null on a built-in map,
## which is how every caller knows there is nothing to run. See `arena_map_mechanics.gd`.
var mechanics: ArenaMapMechanics = null

## The map's solid, in the tree. Set by `ArenaGame` when it adds [method to_collision];
## the physics backends bind to it, which is why it has to be in the tree before any
## player is built or re-bodied on this map.
var collision_root: Node3D = null

## The jail glass rule of the game that built this map's solid, when the map has a cell. Set by [ArenaGame].
var glass: DotMapGlassSight = null

## The bake laid over the level by [method to_scene], or null.
var baked: LightmapGI = null

## Where the map's health and ammo packs lie: `{kind, at}` with `kind` an `ArenaDrops.Kind`
## ([constant PACK_HEALTH] or [constant PACK_AMMO]) and `at` the floor point under it. Always append through
## [method add_pack]. The packs are the game's (`arena_packs`, `ArenaDrops.set_packs`); this
## is only where. An imported map has none.
var packs: Array[Dictionary] = []

## The map's toys (dot-props' placements, `{toy, at, yaw}`), which [ArenaGame] builds on both
## ends in this order. Loose ones only, never a fixed toy: the movement and the shot trace are
## this list's boxes and nothing else, so a see-saw or a trampoline would be something a player
## walks through and a shot passes, and a fixed toy that did collide would be cover or a ledge
## the map's survey never saw. Set by the built-in maps; an imported map has none.
var toys: Array = []

## One step up a map expects a player to make, measured off the geometry it is made of.
##
## [b]Constructed from the two boxes rather than from two numbers.[/b] A climb written
## as `add_climb("the crates", 1.5, 3.0, 0.5)` is a fourth description of geometry that
## is already described three times, and it goes stale the first time somebody moves a
## crate — which is the failure this whole class exists to catch, reintroduced one level
## up. Reading the boxes means the declaration cannot disagree with the map: what is
## declared is only WHICH two boxes are a route, and that is the one thing the geometry
## genuinely does not say.
class Climb:
	extends RefCounted

	## What to call it when the check fails.
	var name: String = ""

	## Metres gained, top face to top face.
	var rise: float = 0.0

	## Clear horizontal air between the two footprints. Zero when they touch or overlap,
	## which is a step across rather than a jump.
	var gap: float = 0.0

	## The two boxes, kept so that the gap between them is known to be a JUMP. The
	## survey's slot rule reads them: 0.5 m of air between two crates is a slot nobody
	## can walk through and is not meant to be walked through, and the only thing that
	## says which of the two it is is this declaration.
	var from_box: AABB = AABB()
	var to_box: AABB = AABB()

	static func between(of_name: String, from_box: AABB, to_box: AABB) -> Climb:
		var climb := Climb.new()
		climb.name = of_name
		climb.from_box = from_box
		climb.to_box = to_box
		climb.rise = to_box.end.y - from_box.end.y
		climb.gap = maxf(
			_clear_between(from_box.position.x, from_box.end.x, to_box.position.x, to_box.end.x),
			_clear_between(from_box.position.z, from_box.end.z, to_box.position.z, to_box.end.z)
		)
		return climb

	## The clear air between two intervals, or 0 when they overlap.
	##
	## [b]The larger of the two axes is the gap, not the diagonal.[/b] Two boxes offset
	## on both axes are crossed by jumping along whichever axis separates them; the
	## diagonal between their nearest corners is a distance no player travels, and using
	## it would refuse routes that are comfortably crossable.
	static func _clear_between(a_min: float, a_max: float, b_min: float, b_max: float) -> float:
		if b_min >= a_max:
			return b_min - a_max

		if a_min >= b_max:
			return a_min - b_max

		return 0.0

# --- What the movement can actually do -------------------------------------
#
# [b]The numbers every gap on every map here is sized against.[/b] The arithmetic
# itself — the climb limit and the reach of a jump landing higher than it left — is
# `DotFpsTunables`' own (`climb_limit`, `jump_reach`), asked of the very tunables
# `ArenaPlayer.arena_tunables()` hands the server, so there is one formula and one set
# of numbers. A map is content: `by_id` is called from a tool and from a catalogue
# listing with no player anywhere in the tree, which is why that is the STATIC builder
# and not a node, and why it is loaded lazily rather than preloaded — the player script
# preloads this one. The constants below stay because the survey and the suite read
# them directly, and `headless_match` asserts they agree with the tunables.

## Ground speed, m/s. `DotFpsTunables.max_speed`.
const MOVE_SPEED := 5.74

## Metres. `DotFpsTunables.jump_height`, which is the PEAK of a standing jump and not
## the height of something a player can climb onto by walking at it.
const JUMP_HEIGHT := 1.25

## m/s². `DotFpsTunables.gravity`. Not Godot's project default, which is 9.8.
const MOVE_GRAVITY := 22.0

## Metres. `DotFpsTunables.step_height`: a rise under this is WALKED, not jumped.
const STEP_HEIGHT := 0.4

## How much of the jump has to be left over at the top: `DotFpsTunables.CLIMB_MARGIN`,
## which says why nine tenths.
const CLIMB_MARGIN := DotFpsTunables.CLIMB_MARGIN

## The tunables arena plays with, built once; see the note above [constant MOVE_SPEED].
static var _tunables: DotFpsTunables = null

## The furthest [method settle_spawns] lifts a spawn, metres.
const SPAWN_LIFT_MAX := 2.0
