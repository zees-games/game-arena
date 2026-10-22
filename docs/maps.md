# Maps

The built-in maps are `dm_box`, `dm_atrium` and `dm_pit`, each a list of boxes in `maps/arena_map.gd` ([architecture](architecture.md#one-description-three-representations)). The combat surf maps are in [imported-maps.md](imported-maps.md).

## Maps are content, and these maps are code

`ArenaMaps.catalogue()` builds a `DotMapCatalogue` from `ArenaMap.ids()` (and the imported ids), never from a second list. `DotMapDef.scene_path` names `arena_map.gd`, the script that produces the map, and `meta.builder` says so. Everything dot-map does with a def (rotation, cooldowns, nominations, ballots, sync) works on the id and the version and never opens the scene; only `DotMapLoader` reads `scene_path`, and `ArenaMapSession` overrides the load for a built-in map and falls through to `super` for a delivered one. The path is a real file so a validator can check it.

**Versions are per map.** `ArenaMaps.MAP_VERSIONS` overrides `MAP_VERSION` for the maps that moved on. A record and a rotation cooldown are about a map at a version, so one shared constant would declare every map new whenever one changed. **Bump a map's version when its geometry changes.**

## Changing the map

`ArenaGame.setup` is not re-entrant: run twice it leaves two matches, two combat managers and two sets of spawns connected to the same signals. `ArenaGame.change_map` is the re-entrant path, and **the teardown is the feature**: every join is a signal connection, and a connection to a freed object errors at the next emit rather than at the skipped disconnect. That is why `ArenaProgress` has `unbind_world` / `bind_world`.

What survives a change:

- **The players do**, re-bodied against the new geometry by `ArenaPlayer.rebind_map`. Assigning the body is not enough, because `DotFpsMotor` holds the one it was built with.
- **Their positions do not.** `_respawn_for_new_map` puts every present, non-spectating player through `_on_respawn_due` after `map_changed`, on the authority, so the director, sides, protection and loadouts apply; a client follows through the predictor's rewind. A kept position can be inside a box on the next map.
- **The match, the combat manager and the world collision do not.** A new map is a new match, and the combat manager's trace is the map.
- **The world layers are reconciled** to the mode ([modes](modes.md#modes-are-data)), and anything hooked to the combat manager rebinds on `map_changed`.

`DotMatch.setup` collects spawn points with a `DotNodeRef` scoped to the game in `PARENT` mode (not `SELF`, which resolves against the match node and finds only the team manager). Unscoped it walks `current_scene`, so a second game in the process, or the outgoing map's points that `queue_free` has not yet removed, contributed spawns. `setup` passes `announce_empty = false` to `refresh_spawns`, because code-built maps add their points on the next lines and the warning would be noise indistinguishable from the real fault.

## The rotation file

`cfg/maps.yml` (or the `--config` directory's, or `sv_map_rotation_file`) says which installed maps the rotation, the next map, the vote's ballot and nominations may choose: dot-map's `DotMapRotationFile`, the `defaults:` / `games: game-arena:` shape with named rotations, plain `maps:` lists, `owner/collection/*` and name globs. `ArenaMapDirector.load_rotation` reads it and `apply_rotation` sets `DotMapDef.in_rotation`; a map outside the active rotation stays installed (`arena_map <id>`, listed "not in rotation") but is never chosen. `arena_imported_rotation` is a separate gate (`enabled`); a map must pass both. `sv_map_rotation <name>` switches the rotation, `maps_rotations` lists them, and the file's `commands:` block renames the map and vote commands. No file: every map rotates, as before. The mode filter (`restrict_rotation`) narrows the file's own list and never widens it.

## Reaching the players

`ArenaMapDirector` is a catalogue, a rotation with a cooldown, a map clock with warnings and rtv, and `DotMapSyncHost`: announce, wait for every peer, swap, tell them to load. Without the sync a change is a change in one process and every client plays a world that no longer exists. With the vote loaded, the vote's clock is the one advanced and the director's is the fallback ([services](services.md#the-map-vote)).

On the client:

- `DotMapSyncClient` accepts an announced map only if it is in its own catalogue at the same version, or is delivered content inside its own mount. It must be built with a catalogue.
- `DotMapSyncClient.changed` carries one argument where `DotMapSession.changed` carries two.
- **`ArenaClient._on_map_changed` builds the `DotMapDef` it is handed, never `game.map`**, which is assigned only on the server. Rebuilding the old map leaves the player in geometry the server no longer has, which reads as the client freezing.

`arena_map <id>` changes the map under the players; `arena_maps` lists what can be loaded. The map commands are console-only, never chat: a map change ends every round in progress.

## Modes a map can host

`ArenaMaps.supports_mode` answers whether a map can host a mode: a team mode needs tagged spawns, and siege, objectives and the props modes need a built world (`needs_built_world`). `dm_pit`'s spawns are untagged on purpose, which makes it the map that says no to a team mode; keep it so.

- `ArenaMapSession` refuses on `_mode_after(map)`: the map's own mode if its def names one, otherwise the one already playing.
- `ArenaMapDirector.restrict_rotation` narrows `DotMapRotation.order` to what the current mode can host before every ask, because the mode changes under a running server. It never empties the order: a mode no map can host is a configuration mistake, and "the map did not change" says so.

## Every map is surveyed

`ArenaMapSurvey` (`maps/arena_map_survey.gd`) runs over the box list and is asserted per map in `headless_match`'s *every map: slots and reach*:

- `slots(map)`: every pair of boxes whose facing sides are under 0.8 m apart, running side by side at least 0.8 m, floor between, nothing in the gap, and not a declared climb. 0.8 is the family's width; the motor's hull is 0.7, so the rule errs toward calling a slot closed. A `Climb` keeps its two boxes, because 0.5 m of air between two crates is a jump and the declaration is the only thing that says so.
- `reach(map)`: a 0.25 m grid of every surface a crouching player fits on, walked under `STEP_HEIGHT`, fallen off anywhere, jumped under `climb_limit()` within `jump_reach(rise)` along an arc that passes through no box, flood-filled from the spawns forward and backward. `unexplained()` is unreached and not declared `out_of_reach` (`ArenaMap.add_out_of_reach`); `trapped` is reached with no way back.
- `ArenaMap.climb_limit()` and `jump_reach(rise)` keep no arithmetic of their own: they ask `DotFpsTunables` of the static `arena_tunables()` (1.125 m climb, 6.07 m reach flat, 4.64 m onto a 0.9 m rise).
- Gaps between 0.8 and 1.05 m are printed as tight, not failed.
- **Wall routes** (`ArenaMap.add_wall_route`: a run along one wall, or a jump off each of two) are one-way edges in the fill, taken on trust there and proved in `headless_match`'s *the wall routes, run and climbed*, which drives each through the motor (`examples/wall_route_driver.gd`): the intended way makes it, the same inputs with the wall moves off do not, and for a run nothing else crosses (a run-jump, a slide-jump, a dash either side of the jump). dm_atrium's two are also on foot by their stairs, so its fill does not need them.

**A bot that has to cover ground does not hold jump.** With `auto_hop` on and jump held, a player leaves the ground the tick it lands, gets no grounded acceleration, and bleeds to `max_air_wish_speed`: 9.00 m/s holding forward, 1.20 m/s holding forward and jump. That is the movement working, not a bug. A check that "the bot hopped" passes for a bot crawling at a metre a second, so every map check drives a walking bot and asserts its pace within 1.5 of `max_speed`; `headless_match` prints the two speeds under *what a bot actually travels at*. A bot turning in mid-hop keeps its old speed (air control only adds along the wish direction), so a climb test stands still on the top crate before turning.

## Colour and light

**Surfaces are photographs (2026-10-20).** `ArenaMapPaint.Painter.role_box` picks a dot-map surface kind by the box's role (`KIND_OF_ROLE`: perimeter brick, structure plaster, walkway clean concrete, stair tread metal, cover planks; the ground is concrete) and the zone colour multiplies the photograph, paled toward white per role (`PHOTO_PALE`) so a brick wall is still brick and a plaster block still says its zone. World-space triplanar, so a texel is the same size on every box. The textures are the kinds in `assets/surfaces/kinds.txt`, copied in by dot-map's `tools/sync-surfaces.sh` (client-only in `sides.json`); a build without them draws Kenney's grid as before. Painting is not a `MAP_VERSIONS` bump. Frames: render with `RENDERER=gl_compatibility tools/screenshot.sh <map>`.

The look is a sunny afternoon over saturated pastel prototype blocks: a mid cool-grey floor, one colour per zone so a position can be called out ("pink stairs", "the lavender keep"), cover in an orange accent, a blue sky, a warm sun with soft shadows, a cool fill a clear step darker in the shade, a little extra contrast and saturation, ambient occlusion on Forward+, mild glow and a filmic tone map. The first play test's frames were near white everywhere (pale paint, a white floor, a fill as bright as the sun side), with nothing to read a player against; the palette, the ground (`GROUND`, a mid grey whose sunlit floor renders at about 0.70 luminance), `WALL_PALE` 0.12, `SLAB_PALE` 0.3 and dot-lighting's `painted()` profile are that answer, rendered in both renderers.

**Paint is derived, never stored.** `ArenaMapPaint.colour_of(map, index)` works a box's colour out from the box itself: its **role** from its shape (`role_of`: a perimeter wall, a stair tread one step deep, a walkway slab under 1 m thick, a slim column over head height, a crate at chest-to-head height, or a structure) and its **zone** from where it stands (`zone_colour`: the first of the map's `paint_zones` that holds its centre, else its compass side, north being -Z, with a butter-yellow centre). Walls and slabs take the zone pastel paled toward white, so the surfaces a player runs on stay light; cover is `ACCENT` (or `ACCENT_ALT` inside a yellow zone) and never a zone colour, so a crate reads as a crate against any wall. The box list stays geometry: the survey, the movement body, the trace and `MAP_VERSIONS` see exactly what they saw before, which `headless_match`'s *map paint and lighting* asserts. A colour stored in the list would make a repaint look like a new map to anything comparing lists. `paint_zones` is for a structure the compass would split or misname: dm_atrium's keep (lavender, where the compass says the west's pink, which is the stair beside it) and its north gallery (`AQUA`, a pastel that stays one in shade).

**The texture** is Kenney's Prototype Textures (CC0), the light grid (`assets/prototype/grid.png`) and the light tiles for the ground (`tiles.png`), tinted per material and mapped triplanar at 4 m a tile, so a major line is 2 m and a faint one 0.5 m, the unit crate gaps and treads are measured in. One material per colour, shared, because the Compatibility renderer pays per material change. A checkout that has not been imported yet falls back to a generated grid rather than failing.

**Lighting is a dot-lighting document the map carries** (`ArenaMap.lighting`, `DAYLIGHT` by default), so it changes with the map: `ArenaMapLighting.build(map)` turns it into a sun and an environment, and the client replaces that node with the level on every map change (two `WorldEnvironment`s in one tree is the second one ignored). What arena adds on top of `DotLightRig`:

- **`sky_top`** in the document. Without it the rig draws the zenith in the ambient colour, which is right for a world whose ambient was measured from its sky; here the ambient is a pale cool grey chosen for the shade (a saturated blue at the ambient's strength turned every shaded face navy and every yellow crate olive), so the sky's blue is named separately.
- **The sky continues under the horizon** (`sky_below_horizon`): from inside a walled map it is never seen, and from above the default dark ground was a brown void around the map.
- **Shadows in the browser too**, as one orthogonal shadow map. dot-lighting's `web()` drops them because on a large imported level the shadow pass draws the whole level again; a built-in map is under a hundred boxes, and without shadows it rendered flat, every face lit alike, which loses most of the look.
- **`DotLightProfile.painted()`** (dot-lighting API 3), the family's profile for flat-painted worlds: a filmic white of 3 and an exposure under 1 so the sunlit floor is a light grey and not white, contrast 1.12 and saturation 1.15, SSAO on Forward+, and a shadowless fill in the ambient's colour from the side the sun is not on, so a crate's two shaded faces are two shades where Compatibility has no occlusion. Its light numbers are per renderer: Forward+ lights into an HDR buffer and the filmic curve rolls a sunlit pastel back under white, while Compatibility clips first, so it divides the sun further and lowers the ambient there. This game's own grade and its hand-set Compatibility numbers (sun / 700, ambient 0.45) were the first form of it and moved into dot-lighting so every painted game gets the same answer. The client shell (dot-server-deploy) is Compatibility on every platform, so that is the look most players get; check both.

- **A contact shade where boxes meet** (`ArenaMap._add_contact_shade`, dot-lighting's `DotContactShade`, API 4): `to_scene` hands the floor and every box to it and adds its one unshaded band mesh, so a crate, a column, a wall and every stair tread meets what it stands on with a soft shade, which SSAO gives on Forward+ and Compatibility cannot. Loaded by path behind `DotAddonApi.build_level("dot_lighting")`, so a shell older than the helper draws the map without it. A built-in map's box list is all axis-aligned, so every crease is exact.

No SDFGI, no volumetric fog, no baked light: the fog is depth fog at 0.12, for the far side of dm_atrium's yard. An imported map is lit from its own manifest instead ([imported-maps](imported-maps.md#lit-from-the-manifest)).

### Baked light

The three built-in maps ship a lightmap each (`lightmaps/<id>.res`, 1.8 MB together), made from the box list by dot-lighting's `DotLightBake`: every box is an `ArrayMesh` with a deterministic second UV set (`ArenaMap.lightmap_box`), and `to_scene` lays the bake over the level when its fingerprint matches the boxes and the sun. The sun stays live (its shadows are how a player reads a corner) and only its bounce is baked, so the bake adds the occlusion at creases, the shade under ledges and the colour bounced off painted walls. Change a box, the sun or `ArenaMap.BAKE_VERSION` and run `tools/bake_lightmaps.sh` (on a GPU box through `../gpu.sh`, `GPU_BOX=staging02` for the desktop; the box needs the project imported once); `headless_match` fails when a bake is stale. `screenshot.sh <map> --no-bake` draws the live lights for a before/after. The bake also carries light probes (dot-lighting's default subdivision), which the `LightmapGI` uses to light players and props standing in it.

## Design rules every map follows

These are what the shipped geometry was measured against. A change that breaks one is a design decision, not a tidy-up.

- **Stairs are treads of 0.36** (under the 0.4 `step_height`, so held forward walks up). A stair ends flush against what it climbs to; stopped short, a player running up leaves the top tread into the air, and stopped 0.5 m short it leaves a slot.
- **Crate climbs have 0.5 m gaps.** A hopping player carries about 0.6 m per hop, so 1.0 m gaps are not climbable.
- **No gap between two boxes may be between 0 and 0.8 m** unless it is a declared climb; flush or at least 0.8.
- **Every way onto a high point is watched from a higher one.** The trade for a new route up is that whoever holds the top sees all of it; checks trace a chest on every tread from that point.
- **Headroom**: anything a player stands on with any part of the hull under a 3.0 m bridge can be no higher than 1.2 (`stand_height` over every tread is checked).
- **A wall-run gap drops 0.7 m or so to its far side**, and is wider than a dash-jump (11 m on the flat at arena's numbers); a wall-jump climb is one jump off each wall it has. Measure both with the motor, never by arithmetic.
- **Spawns are balanced and adding cover is not a reason to add one.** `dm_atrium`'s spawns are tagged by the sign of z, five and five; `dm_box` is its own half-turn about the origin (asserted over the whole box list; its stairs are computed as each other's half-turn); `dm_pit`'s nine are all untagged.

### dm_box

A room with a raised middle, two ledges at the x walls and an upper loop: ledge, gantry, ledge, gantry. Each gantry has one 0.9 m step against the pillar it passes, so the pillars at (4, -12) and (-4, 12) are a third tier (the nests). The two pillars beside the crate stacks are out of reach on purpose and declared so. The ledges are 6.5 m deep because the x-axis spawns stand at ±18 under the lip. Nest stairs run along each gantry's outer face and end flush against the nest pillar (which is why a run stops at a wall with the gantry one sidestep away); corner stairs along the north and south walls climb to a landing that carries the ledge into the corner. The NE and SW corners keep their stubs, which is what a half-turn rather than a mirror gives. dm_box has a platform at the origin, so a body teleported there is pushed out: start position checks on a spawn point.

### dm_atrium

A 60 m yard round a building with a ring at 4.6, a perch at 6.7, a south arcade and a north keep. The arcade is a colonnade, not a tunnel (opaque from above, open from the sides), with its roof (top 3.6) under the ring's underside at 4.0, so the ring still holds the map and the roof is a firing position under it. No spawn was added for it: every spawn it could carry would be on one side. The keep is a roofed room with a door at each end and a roof 0.9 over the ring; the 2 m alley and lane round it are load-bearing (walkable below, one jump up from the ring's north arm), and its west wall's firing slit has a 1.2 sill (over the climb limit) and 0.8 of opening (under a crouching player), because at 1.0 the sill becomes a reachable shelf. The east stair climbs from the east yard to the landing. The rampart joins the keep roof to the perch at 5.86, on piers 8 m apart, reachable only at its two ends (1.26 up from the ring, over the climb limit), so it is a route and not a second ring.

**The north gallery is the walls' place** (1.7.0): two 4 m ledges against the north wall, the high one (2.52, x -30..-18) and the low one (1.80, x -6..6), a 12 m gap between them, a walked stair onto each, and a chimney of two arms 2.4 m apart out from the high ledge. The gap is crossed by running the north wall and nothing else: measured with the motor, a run-jump lands 3 m short, a slide-jump 5 m, a dash-jump 1 m, and a slide-jump onto the wall lands 2 m onto the low ledge. **The 0.72 m drop is what makes it work**: a run levels off and sinks slowly, so between two ledges of one height it arrives under the far top and hits its face. It is one-way east; back is the stairs. The chimney is two wall jumps (one off each arm, `wall_jump_max_per_wall` 1) to about 2.9, over the 2.52 top; its arms are the ledge's height, so nothing new is standable. The rampart sees every 3 m of both ledges and the keep roof the chimney's top. Aqua by its own paint zone, because the gallery lies in the north wall's shade, where the warm pastels tried went brown.

### dm_pit

28 m, a sunken floor with a catwalk ring at 3.6, two bridges crossing (one high point is a throne; the crossing makes the middle a junction), a shelf and perch at 5.4 in the south-west, and a lookout at 4.5 on the east arm so the perch has something to duel. The shelf is flush with the west and south arms' inner edges (x = -11, z = 11); half a metre clear leaves a 0.5 m slot that looks like a corridor from above. The lookout stands against the wall so the arm keeps 1.5 m of walkway; the ring is a loop and must not become two dead ends. The shelf stair runs from the floor up the shelf's east face under the north-south bridge, and its landing runs 0.8 m past the bridge's west edge because the step up happens with the hull still under the bridge. Each bridge is driven by a bot separately: they meet different arms.

## Toys

Each built-in map places a few of dot-props' **loose** toys ([member ArenaMap.toys]): beach balls and a football on the open floor, barrels and tyres by the walls, clear of every box and 2.5 m from every spawn (`headless_match` checks both, and that they are still where they were put two seconds on). Never a fixed toy: the movement and the shot trace are the box list and nothing else, so a see-saw or a trampoline would be something a player walks through and a shot passes, and one that did collide would be cover, a ledge or a launch the survey never saw. A loose toy changes nothing about the fight: a person walks through it and pushes it (`ArenaGame._advance_toys`), a shot down the same ray pushes it and goes on to whoever is behind it (`_shoot_toys`, dot-props' `shot_along` against the `world` layer, before the combat resolves the shot, whose trace never sees a toy), a rocket's blast throws it, and every toy goes home when a round goes live. A headless authority puts a collision copy of a built-in level in the physics space for them to land on (`_toy_level`; nothing else here asks the physics space about one); an imported map's solid is there already, and imported maps place none. `sv_toys`, `sv_toys_awake` and `sv_toys_push` are bound REPLICATED by the module and followed by the client.


## Workshop maps

A subscribed pack's map (map kind `arena`, solo only; `provides.json` says so) is a **JSON box-list document** named by the entry's `scene`: `id` (must equal the entry's id), `name`, optional `extent` (8 to 200), `wall_height`, `boxes` (`[x, y, z, size_x, size_y, size_z]`, at most 512) and `spawns` (`{at: [x, y, z], yaw}`, 1 to 64, inside the extent). `ArenaMapDoc.build` makes an `ArenaMap` of it and adds the four perimeter walls, so collision, shots and the picture come from the one box list as for a built-in. The pack ships no code. A bad document is refused with its reason (logged once) and left off the menu and the ballot; the game's own ids always win. `ArenaMaps.build_workshop(def)` is the one builder, and `ArenaClient._build_map` uses it for a menu choice. Limits: [not-yet](not-yet.md).
