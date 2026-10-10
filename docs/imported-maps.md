# The combat surf maps

game-g2gfast imports compiled maps from the surf genre, and some of them are not courses: small maps with buy zones, weapons on the floor and teleports back to a spawn, built to fight on. g2gfast marks them `"kind": "arena"` in its `maps/zones/<id>.json`, the importer copies the kind into each map's manifest, g2gfast keeps them out of its own rotation, and this game plays them as a deathmatch.

## Where the files come from

`maps/imported` is a link to `g2gfast-maps/maps` (the `# bootstrap-link:` line in `.gitignore`), at the same path game-g2gfast links it, so the `.import` markers committed there are right here too. `ArenaImportedMaps` scans it (and `user://maps`) for manifests whose `kind` is `arena`: discovered, never listed, so a map g2gfast re-classifies is picked up or dropped with nothing edited here. `ArenaMap.by_id` falls through to `ArenaMap.imported(id)` and `imported_ids()` sits beside `ids()`. A local import's def has no `content_id` and is at version `0.0.0-<12 hex of its manifest's md5>`, so two machines holding different imports of one map disagree at the announce instead of colliding against different brushes.

**A checkout without the link plays the three built-ins** and every check about the imports skips, saying so. That is a supported state.

## A copy of g2gfast's loader, not a dependency

`maps/arena_bsp_map.gd` is the half of g2gfast's loader arena needs: the mesh `.bin`, the lightmap through two shaders (`arena_bsp_{lightmapped,translucent}.gdshader`, opaque unless the material says translucent, because writing `ALPHA` at all moves a surface into the transparent pass), one `ConvexPolygonShape3D` per brush and one welded displacement trimesh, the spawns and the pits. `maps/arena_map_mechanics.gd` and `maps/arena_ladder_mode.gd` are copies of g2gfast's mechanics and ladder mode, in metres through `ArenaBspMap.METRES_PER_UNIT` (0.01905).

A game cannot name another game's script and a delivered pack cannot resolve a `class_name`, so these are preloaded by path. Lifting the loader into an addon is the right home eventually; it would put it in the client shell (so arena could not use it until the addon is tagged and the shell rebuilt), and the reusable half is tangled with g2gfast's genre units, timer zones, textures and lighting. Duplicated deliberately, per the family rule.

A surface with a texture draws it; anything else draws `ArenaMap.dev_texture`, one square to 64 units, tinted the colour the map's compiler measured (black only when the material is named black, g2gfast's rule). Water with no texture draws with `arena_bsp_water.gdshader` (translucent, both sides, a slow ripple). The map's sky, sun and fog are not read (that is dot-lighting, which arena does not link); surfaces are unshaded and lit by their own lightmap.

## The solid is the game's, on every machine

`ArenaGame._build_world_collision` adds `ArenaMap.to_collision()` (the brushes) as `WorldCollision` before the combat manager and before any player is built or re-bodied, on setup and on every `change_map`, and frees it with `free()`, not `queue_free()`, when the map goes. `ArenaMap.movement_body()` and `shot_trace()` bind to it (`DotFpsPhysicsBody`, `DotTracePhysics`); a built-in map still gets `to_fps_body()` and `to_trace()`. `to_scene()` of an imported map is the drawn mesh only, so a client never has two copies of a brush. Both ends query the same convex hulls through the same solver, which is the condition the prediction rule is about ([netcode](netcode.md#the-client-predicts-with-the-servers-collision)); the body is still a shape query from a plain `Node3D`.

**Arena needs dot-player-controller v0.1.5 or later** (in client shell 20261009-1627 and after): `DotFpsFlatBody.rest_contact` used to push a player out of a box along its deepest axis, and with the 512 m extent's quantisation a client slid 2.8 m along a wall during a launch the server made straight up.

## Spawns and teleports are settled at load

Mapper spawns and pit destinations are often inside solid, and the motor pushes out at most a step a tick, so a player rose through the floor. `ArenaMap.settle_spawns` lifts each one in 5 cm steps until a standing hull is clear, up to 2 m, before `_build_match` makes spawn points of them.

## Pits are teleports, and the floor under the map catches

`ArenaPlayer._follow_map_volumes` runs inside the simulated tick, on the server and in the owning client's prediction alike, so neither end has to tell the other: feet entering a RESPAWN zone are put at its destination facing its yaw, and a player 10 m under the map's bounds is put back at a spawn.

## The surf genre's air control on these maps

`ArenaPlayer.SURF_TUNABLES` is `air_accelerate` 150 (what g2gfast runs them at), a 30 u/s wish cap, 800 u/s² of gravity, a 57-unit jump and the 3500 u/s limit; ground movement, slide, launch and dash stay the arena's. `ArenaGame.map_movement()` is derived on both ends from `ArenaMap.movement_profile` (`&"surf"` for a `kind: arena` map), and `ArenaPlayer.apply_map_movement` writes it and puts every key it is not given back to `arena_tunables()`, which is what takes it off on the next built-in map. It is applied before a player enters the tree and before `rebind_map`. `arena_surf` (1/0) and `arena_surf_airaccelerate` (150) ride RULES because a client predicts with them. Christian's pick is the default; the arena's own movement is one cvar away.

**The hull stays the arena's 1.8 m**, not the genre's 1.37 m, because the hitboxes and avatars are built for it. Every spawn room and doorway checked fits it; a genre-sized vent somewhere would not.

## Rotation and modes

`arena_imported_rotation` (`all`, `none`, or ids) defaults to `surf_10x_reloaded_fixed,surf_110b_austinpowers`, the two Christian named; the rest are `enabled = false`, which the rotation, the ballot and nominations already read, and stay loadable with `arena_map <id>`. `ArenaMaps.supports_mode` keeps siege, the objective modes and every props mode off them (`needs_built_world`: navigation, objective layout and scattered props are built from a box list), and their untagged spawns keep the team modes off. Free-for-all, gun game and the weapon pools play.

## Delivered maps

A server names its combat surf maps the way every game does: `ArenaMapDirector.server` is the dot-server, `ArenaMaps.server_map_keys` reads `games.current_maps()` (the descriptor's `maps`, which dot-server-deploy's `cfg/content.yml` fills; duck-typed, so no list is the old behaviour), and `ArenaMaps.adopt_delivered` puts each `<owner>/<id>@<version>` in the catalogue as delivered content without fetching it (they are megabytes each). `game.yml` has no `maps:` on purpose: the server owner names them.

- `ArenaMapSession._mount_delivered` fetches the pack on the change (`DotMapLoader.ensure_content`; arena does not link dot-game) and registers the mount with `ArenaImportedMaps.add_mounted(id, dir)`. A mount holds `<id>.json` directly, so it is registered per id rather than scanned as a root. It is not in `ids()`, and it wins over a link copy of the same id, because both ends must build the pack's bytes.
- On a client the same session method runs from `DotMapSyncClient`'s load. A client with the link drops its local def for that id first (`ArenaClientExtras._prefer_delivered`), or dot-map refuses the announce as a different version.
- **A delivered map's version is the pack's**, so server and client agree by construction; the md5 version is for local imports only.
- Only `"kind": "arena"` manifests play: one on disk that says otherwise is skipped, one fetched on a change is refused and leaves the catalogue. A key with a built-in id is skipped. `director.adopt_server_maps()` re-reads the list; the running map keeps its mount.

Not covered by a suite: a real client fetching a real pack over the wire, and `_prefer_delivered`.

## The maps' own mechanics

Pushes and boosters, water, ladders, conveyors, gravity and hurt volumes from each manifest's `mechanics` block run here. `ArenaMap.imported` reads it into `ArenaMap.mechanics`, null on a built-in map, and that null is how every caller knows there is nothing to run.

- **Inside the simulated tick, on both ends.** `ArenaPlayer.simulate_tick` runs `_run_map_mechanics` after the controller's move and before `_follow_map_volumes`: pushes, then gravity or a conveyor, then the ladder, then water (a ladder wins over water), then the pits. The node is moved after a push so the muzzle and hitboxes follow.
- **The swim and ladder modes are registered on every player on every map** (`controller.extra_modes = [swim, ladder]`, in that order), because a mode's id travels in the state's flags and a client that registered them only on a map with water would misread a swimmer's mode. With no volumes neither is entered and a built-in map moves exactly as before.
- **Pushes are stateless.** g2gfast keys a push history by `DotFpsState.tick`, which a rewind does not restore. Here "was this player in it last tick" is asked of the hull where the tick started, and a push that displaces a player out of its box hands its velocity over on that same tick, or a floor booster's own displacement carries the player off its end before it throws. (Whether g2gfast's history mispredicts a booster on a connected client is unchecked.)
- **The ladder's jump-off grace counts the game's tick** (`ArenaLadderMode.now`, written by the player), for the same reason.
- **Hurt is real damage.** `ArenaGame._hurt_from_map` deals `damage` per second every half second (`ArenaMapMechanics.HURT_INTERVAL`), the first pulse on entering, through `DotCombatManager.apply_damage` as attacker 0 with the `world` type, on the authority only, after the shots and before the match. A negative amount heals. Not predicted: health is the server's.
- **Sinking blocks are not ported**: none of the maps has one, and they are a timer map's mechanic. `ArenaMapMechanics.blocks_skipped` counts them so a map that gains one says so in `describe()`.
- The water is the genre's (200 u/s, a 60 u/s idle sink, so a pit full of water is climbed out of by holding jump), with waist and float depths as the genre's proportions of the 1.8 m hull.

Most of these maps' water is a few centimetres over a pit, and most hurt volumes sit over a teleport, so checks look for the deep pool and the pit-free volumes rather than the first one found.
