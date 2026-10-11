# History: bugs worth recognising again

Almost every one of these parsed cleanly, produced no error, and passed the suites of the day. Each is kept because the shape could come back; where the lesson is still a rule, the rule is also in [CLAUDE.md](../CLAUDE.md) or a topic file. Many are told at length in the family's [bugs-found.md](../../../docs/bugs-found.md).

## Found here, in other repositories

One line each; the detail is in [bugs-found.md](../../../docs/bugs-found.md) or the addon's own docs.

- **dot-chat: a parser with a default for every field cannot refuse anything.** dot-server's chat payload parsed as a valid `DotChatMessage` with no text, and every line drew as `": "`. `m` is the discriminator now.
- **dot-ui: `DotTableView` drew one column** (the rest zero-width) and the rebinder's rows came out in interned-pointer order. Found by `tools/screenshot_menus.sh`.
- **dot-ui: `DotBindingsPanel.prefix` was one string**; arena's chat keys are a second namespace. `also_prefixed` was added for it.
- **dot-match: `refresh_spawns` walked `current_scene`** when no `spawns_ref` was set, so a second game in the process contributed its spawns. It also warned "no spawn points" on every code-built map; `announce_empty` was added.
- **dot-weapon: a held trigger on an empty weapon restarted its reload for ever.** Seen as bots scoring a third of their usual kills.
- **The rocket launcher never damaged anything** until dot-weapon's projectile spawn forced `ArenaProjectiles` into existence; then every rocket that went off more than 2.5 m from its owner exploded in the owner's face (dot-combat's origin correction re-traced the blast). Any explosive check asks the thrower's health.
- **dot-net: `DotNetStats` reported half of every clean link lost** (it counted ticks; arena snapshots every second tick), **the render timeline went backwards with every late packet**, and **the interpolation delay had the flight time taken out of it.** All found by `headless_lossy`.
- **The engine passes `create_server`'s `max_channels` to ENet as the host's incoming bandwidth**, so every dot-server told every ENet client it could take six bytes a second, and the client throttled its commands to 1/32 for its first seconds. Fixed in dot-core's `DotTransportENet` by passing 0. A `throttle_configure` on the client does not help.
- **dot-player-controller: `DotFpsFlatBody.rest_contact` pushed out along the deepest axis**, exposed when the world extent moved the quantisation step; a client slid 2.8 m along a wall during a straight-up launch. Fixed in v0.1.5, so arena must not run on a client shell older than 20261009-1627.
- **dot-player-controller's rewind kept the client's own launch cooldown and buttons**; they travel in `net_flags` now.
- **dot-player-controller: a wall run ended four ticks in over the wire.** Jumping off the gallery's high ledge onto the north wall, the uncrouch after the slide dropped the feet past the ledge's top a hand beyond its end face, and the wall probe took the nearest wall, that face, whose speed "along" was nothing. Offline the driver's timing missed it by centimetres; one lost crouch press in `headless_net` shifted it a tick and both ends agreed on a run that ended. A run now keeps the wall beside its velocity (2026-10-10).
- **dot-spawn: the spawning player was their own enemy**; a two-argument `enemies_fn` gets the spawning key.
- **dot-spectate: a mirror held the death camera until the respawn**; it now refuses `on_death` on a mirror, loudly.
- **The bridge's extra reconcile pass** was found from game-hungario, whose bridge was written from this one and inherited it: `correction_rate()` 0.500 with it, 0.032 without.

## Joining a dedicated server

**Nobody could ever join a dedicated arena server.** `ArenaModule` looked a session up by `peer_id`, which `client_spawn` does not carry; a null session is a legitimate thing to find. `dedicated` passed throughout, because it never connects a client.

**The two ends quantised against different world extents** (128 and 256, in two files). The client connected, sealed an identical schema, adopted its player alive with 100 health, and drew sky in every direction with a HUD reading zero.

**The client waited on `player_spawned`**, which a mirror never fires: no camera and no world, while the HUD and scoreboard worked. The same bug game-g2gfast shipped, one signal over.

**The client tried Godot physics first**: the player fell through a perfectly drawn floor into a void.

## Map changes

**A map change kept everybody where they stood**, so a player whose spot was a box on the next map was pushed down through the floor. Found building `dm_atrium`'s keep.

**The client rebuilt the map it was already showing**, reading `game.map` (server-only) instead of the def it was handed. On a live server it read as the client freezing; `headless_net` has no renderer and could not see it. The same live change showed `arena_maps` printing "No hot changelevel yet." four lines from the command that does one.

**A map change silently unhooked the effects layer**: the `adjust` hook stayed on the freed resolver, and every hit after the first changelevel went unscaled.

**`_build_world_layers` ran once at setup**, so `koth` on a running server had a null objectives layer and `siege` no monsters. `arena_mode` was the first thing to change a mode at runtime.

**The director did not know about sides**: sites lost their team tag and the roster kept the previous mode's sides, so a team mode spawned both sides from one pool.

**The first map that said no** (`dm_pit`, untagged) found that the refusal read the map's own mode (never set) instead of the mode being played, and that the rotation could hand a team game a map that would then refuse to load.

**The survey's first run found five closed slots on two maps**: piers and a stair stopped half a metre short, pillars 0.75 m off two stairs. Driving bots found 1.0 m crate gaps nobody can climb.

## Values produced and consumed by nothing

The family's most repeated shape, found here many times:

- `ArenaPlayer.team` was declared and assigned by nothing since the class was written; friendly fire, the scoreboard and the renderer all read it.
- Spawn protection was three mechanisms with two durations; dot-spawn's ledger was drained every tick and filled by nothing, and `ArenaEffects.on_spawn` was called by nothing, so a player who died burning respawned burning.
- `DotPlayerClassDef.loadout_id` reached nothing; everybody got a hardcoded pair.
- The physics gun and gravity gun were built per player and reachable from nothing; the avatar documents were resolved and every player drew a capsule; the client's chat history was fed by nothing. Found by the unused-method grep.
- `fx_catalogue()` named four effect scenes in a directory that did not exist, and the suite asserted the refusal as if it were correct. Found from mg-buses-from-hell, the first game to ship its effect scenes.
- `sensitivity`, `invert_pitch` and `crosshair` were on the Settings screen and read by nothing. The crosshair measured spread through a hardcoded 75 degree lens.
- Leave was `var _unused := pause`, and no `push(&"servers")` existed anywhere: a whole server browser built on every launch and unreachable.
- The rebinder filtered on `arena_` and there had never been an `arena_` action: a Controls menu with no controls.
- The game's chat commands were behind a prefix check that returned before `player_chat`; `!rtv` and `!vote` looked alive because dot-server has commands of those names.
- dot-vote's commands were never installed, two map clocks ran, and nothing called `note_score` or `note_round_end`.
- `ArenaHud.notice` did not exist; the client had called it for chat lines and map-change notices since it was written. Found because the parser refused the same call inside the HUD's own file.
- `DotFpsSampler.suspended` was documented "for a chat box" and never set, so typing walked the player.
- `ArenaGame.mode_id` was read once at setup: a game with five modes and one of them.

## Wiring the horde

- **Monster entity ids collided** (instance id modulo a million); one of each pair was unkillable.
- `_on_entity_killed` and `_on_damage_applied` handed monster ids to dot-match and the stats, filing scoreboard and leaderboard rows against a monster.
- A brain that set `character` inside `_build` made a firing squad; senses assigned after `add_child` were read by nobody; eight map props against a budget of twelve placed seven.
- Monsters were not replicated at first: a connected player was hurt by monsters they could not see.

## Weapons and the wire

- **A connected client's arsenal was empty for the whole of every match**: no predicted shot, no flash, no report, a HUD reading zero, while the server fired correctly. `headless_net` had written it down as "not asserted".
- **Every reconciliation re-played every shot** in its window: the sound, flash and kick several times per shot.
- A grenade cooked past its fuse floated for twelve seconds; a client's projectile copies bounced off the old map after a change.
- The highest slot became the throwable, so players spawned holding a grenade; optional loadout slots vanished a frame after every spawn (found by rendering).
- The first death camera fed and ticked only on the authority: a dead player in a browser looked at the floor for every death while `headless_match` passed.
- A client's `props_on_e` read its own `game.mode` and launched instead of grabbing.
- The first spawn-avoidance asked dot-match's team manager whether there were sides and told a free-for-all respawner their old team-mates were friends.
- **No input was ever resent**: at 20% loss the server had A's command for 80% of its ticks. **The clock's round trip came from a heartbeat that is -1 for eight seconds.**
- A slay inside spawn protection was refused, for the first second and a half of every life.

## The wire

- **A predicted replay re-emitted every movement signal.** `ArenaPlayerNet._predict` marked a replay for the weapon rig only, never for `DotFpsController`, so the slide's, the dash's and the launch's signals and the jump statistics repeated on every correction, and nothing listened closely enough to say. The wall moves' sounds did: one wall run heard six times and one wall jump seven, over 20% loss (`headless_lossy`, 2026-10-10). The controller is marked now; the rule is in [netcode](netcode.md#weapons-over-the-wire).

## Feedback the client decided for itself

- **The hit marker sounded on the client's own prediction** (`ArenaPresentation.on_used`, `shot.damages`), so a shot the server refused still said "hit". And revenge and the nemesis line were counted on each client from the kill feed: a client that joined late or missed one KILL disagreed with the server about who was whose nemesis. Both moved to the server on 2026-10-10 (`HIT`, `AWARD`); the rule is in [client](client.md#kill-feedback).

## Seen only by rendering

- The Kenney characters at 2.70 m against a 1.8 m capsule, limbs drifting from a double-scaled origin, and capsules floating above their mount point.
- The round clock starting at the middle of the screen; the local player's own nose across the bottom of every offline frame; the first blind leaving a sixteen-pixel frame of world; the scope sized to the safe area; the low-health edge as a red rectangle.
- The muzzle flash as six additive white squares; the explosion as the death burst's gibs; a resting grenade as two pixels; the weapon name right-aligned over a left-aligned count.
- An offline player always facing -Z because the spawn's yaw went to the wrong sampler; on a surf map, the spawn room's back wall three metres away.
- `--feel` arming in `_init`, before anything was in the tree, so every frame showed empty hands.
- The first-person body as a grey slab of hip tops.
- Untextured water: a swimmer standing in an empty pool.

## Still open, unexplained

- `dedicated` exited with 23 ObjectDB instances and 6 resources leaked (2026-09-23), as many before the message self-preloads were removed as after: too few to be the whole script graph, so a different shape from the one mg-buses-from-hell had. Not re-measured since.
