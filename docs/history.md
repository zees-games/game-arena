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

**A READY that overtook the seat was answered with nobody (2026-10-12).** Over a lossy ENet link a client's READY can arrive before its seat, and `mark_ready` sent the signon then: a HELLO naming session 0, so the client never knew which body was its own. Eleven other bridges had already been fixed for the same race the same day; arena's `mark_ready` never looked at the seat and had not been checked. `headless_net`'s ready gate had asserted the bug as the rule ("marking it ready sends it the whole signon", to a peer nobody had seated).

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
- The Interface screen (dot-ui's `DotSettingsScreen` over a `DotUiConfig`) edited an object nothing saved and nothing read again after the HUD was built: scale, safe area, transition time and line counts all moved a slider and changed nothing. Found converting to dot-menu (2026-10-10); `hud_safe_area` is the one kept, as a real setting.

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

- **The `mp_teammate_passthrough` checks waited 5 s for a reliable message through 20% loss** (`headless_lossy`, 2026-10-11). One run in 30 failed "and to 0" and then the map-change check: the 2 took past 5 s to land, and the 0 waited behind it in order on the channel, nine seconds in all. 60 changes measured 48 ms to 4.2 s, in steps that are ENet's resend backoff. Six runs after the waits went to 35 s saw one 2 land at 12.3 s and one change at 4.7 s, with the 0 behind the late 2 landing 100 ms after it, so it was always arriving. Nothing was lost, so nothing in the game changed: the waits are the suite's `RELIABLE_SECONDS`, and the map-change check is held to what the link holds, so one late message fails one check.

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
- The HUD's health, ammunition and key hints all but invisible over the pale prototype floors: regular-weight text, no outline, no plate (`dm_box_feel_kill_compat.png`, 2026-10-10). Rebuilt as `ArenaHudGlance`, bold and outlined on plates.
- The first portraits were the back of each head: the character kit faces -Z here and the camera had been put on +Z. Weapon silhouettes drawn from 600-pixel renders broke into dashes until they were saved at 48 px and mipmapped.

## Frames, not ticks (2026-10-11)

Measured by `headless_feel`, the first suite to judge what a frame shows rather than what a tick computed, and invisible to the other eight: offline bots drawn where their last tick left them (every frame 6 to 8 cm off at 144 Hz); the view model bobbing ten footfalls a second at a run (zee-dot-weapons, now a cadence); the eye stepping up each stair tread in one tick; the connected eye standing still and then moving double after every physics frame the drifting clock ran no tick or two (dot-net `render_alpha`); remote players jumping a tick when the receive timeline re-anchored, and snapping back after every extrapolation (dot-net `receive_slip`, the interpolator's resume easing). The first fix tried for the slips drew at the clock's own accumulator, which is continuous but sits up to a tick past the newest tick all the time and extrapolated through every wall: 474 of 719 frames off at 144 Hz, worse than before. Measured against the state's velocity, every wall a runner touched read as a stutter, so the runners run circles on open floor and corners are not judged.

## The runner was never on open floor (2026-10-12)

`headless_feel` failed one check now and then for several sessions, always a different one, and passed every time it was rerun. No arena commit broke it: the runner placed on its circle at `bd2fb1e` and `00e7130` was against the east wall too. `_place_on_circle` assumed the local runner's yaw grows; it shrinks (the mouse moves right and forward and right are held), so its circle was centred 4.4 m off, under the east ledge's lip at x 17.5. In the jumping window held jump bunny-hopped it from 11 to 24 m/s into the wall, and each apex hit the ledge's underside at 3.0 m. Client and server disagree about a ceiling bump and a wall slide by up to 7 cm after a quantised snapshot, the correction was eased across the frames being judged, and on a busy machine one of those landed on a judged frame (29 mm). The runner now starts every window on its circle in the open south floor, jump is pressed every 52 ticks rather than held, and a check fails any window in which either runner came within 0.7 m of a wall or a ceiling. On open floor a jump's corrections are quantisation, about 1 cm. Once the eye was judged at a run on open floor, the clock's own work showed: while it gains lead its ticks run 12% short and a slip is taken up at 27% a tick, so a frame ran half a step fast by design (2.4-2.9 cm, one 40 to 70 ms window in four); the eye's allowance includes what the clock was doing on that frame now. The suite is still real time: on a machine whose load is over its cores, frames stall and the stair, the lean and the bot fail.

## Camera motion (2026-10-11)

Arena had none of the landing dip, strafe roll and speed widening dot-player-controller's own camera had, because it writes its camera itself and had copied only the wall-run lean. Measured first: the landing was a 4.9 cm a frame corner at 144 Hz. The addon's own dip turned out to be a snap (the full dip and a 6 degree pitch set on the landing frame), so the cues moved into `DotFpsViewMotion` there, the dip as a spring kicked in velocity, and arena calls it. Two things only the frames showed: kicked when `landed` fired, the dip began a tick early, while the eye was still drawing the last of the fall (21 cm in two frames, then a stop); and the step-easing reset from `39e7d23` sat at the end of `_follow_map_volumes`, which runs every tick on an imported map, so stairs there were never eased and the frame two ticks back was always forgotten. It is `_forget_drawn` now, on a spawn and a teleport.

## Solo bots were the test fixture (2026-10-11)

The first play test on Windows (bootstrap, solo) died twelve times in ninety seconds and was killed from 30 to 40 m within a second, again and again. Nothing was mistuned: `ArenaClient._drive_bots` was `headless_match`'s fixture, copied into the client to get kills on screen, and its own comment said so. It faced the nearest player through any wall at pitch 0 and held the trigger under 40 m. The brain a server ran (sight, reaction, aim error, range, strafing) was never met by anybody playing solo, because solo never ran it. Both run dot-bot's `DotBotBrain` now (`ArenaBots`), and `headless_bots` holds every preset to a K/D band in the real game. The lesson for any game here: a bot driver in the client is a second brain, and the one players meet first.

Building it found one dot-bot bug: a sound made on the same timestamp as a brain's last think was never heard (a time comparison), so a bot with its back to a shooter died without turning round. Sounds carry a sequence number now.

## A wall the server could not see (2026-10-12)

The first play test respawned in view of the bot that had just killed him, twice in ninety seconds, under a spawn rule that charges 500 for a site an enemy can see. The sight test asked Godot's physics space, and a dedicated server or a headless game has no built-in map there: the level is analytic and only a client builds bodies. Every site was "seen" by every enemy, the penalty was charged to all of them alike, and it decided nothing. It asks the map's trace now, the one shots use, and `headless_match` checks a wall hides a site in a headless game. Fixing it changed `headless_bots`: one-on-one with hidden respawns there are fewer fights a minute, and at 300 s hard and medium swapped places on one seed, so the suite plays 600 s. The lesson: any question about the level asked on a server goes to the map's trace or movement body, never the physics space.

## Players walked through each other (2026-10-12)

`mp_solidplayers` is the family's cvar, and every other first-person game makes it bite with a capsule in the physics space that the motor's physics sweep stops at. Arena's motor sweeps the map's box list on the server and on every predicting client, so that capsule reached neither, and bots walked through the player, their faces filling the screen. The other players are boxes in the movement body's sweep now (`arena_solid_body.gd`), and `headless_net` walks one player into another on a server with a predicting client, both ways round the cvar.

## A route through a crate's corner (2026-10-12)

`headless_bots` failed "the world routes between spawns … every leg clear" on all four presets, and bisecting arena, dot-bot and the people commits found nothing: fresh clones of every committed head passed. The failure was an uncommitted change in the shared dot-npc checkout, a native A* that breaks equal-cost ties the other way. Its path was as short as the old one, but dot-npc's smoother then cut the first leg through the corner of dm_box's east top crate: a probe inside a grid cell the builder had removed snapped to the nearest point left, across the corner, and the hop to it was a real, clear diagonal edge, so `can_walk_straight` passed it. The check measured the right thing (a knee-height ray through a box is a bot walking into it); the smoother was wrong, and only the old tie-break had hidden it. The fix is dot-npc's: `can_walk_straight` refuses a probe further than 0.75 of a grid cell from every point, which is a probe in a removed cell. When a suite fails at HEAD and the commits do not explain it, look at `git status` in every linked addon first.

## A chimney that failed only on CI (2026-10-14)

From 39e7d23 every CI and release run failed `headless_net`'s "up the chimney onto the gallery" with the same numbers, 0.432 m at tick 1254, and every desk run passed. The runner was not different: it links no g2gfast-maps, so the imported-map checks skip, and every tick after them is numbered differently. A fresh clone without the link failed with the same numbers to the millimetre. What the tick numbers moved was where the climb's wall jumps fell among the harness's snapshots, and the harness made every jump a tick late on the client: it handed tick T's snapshot over before the client had played T, so the client rewound to T with its clock on T - 1, replayed nothing, and simulated T a second time. From then on its tick T + 1 was built from command T, which a held input never shows and a press always does. The next snapshot pulled it back, so the gap was the wait for that snapshot: 0.13 m on a desk, 0.43 m on the runner. With the order fixed alone, a lost jump press became a climb the server never made, because the harness had no input lead either. `_driven_window` now plays a real link's order with a one-tick lead and the copies, and both wall routes agree to 5 to 7 mm whatever tick they start on (20 phases tried); the check holds 5 cm instead of 0.35 m.

The same release failed `headless_lossy`'s 20% window (p95 0.59 m, max 2.1 m): the server there filled itself with two quota bots, and A's prediction against a bot it last heard of a round trip ago is a correction no loss caused. A desk run met a bot too, at 0.9 to 1.3 m, under the 1.5 m limit. The suite switches the quota off, as `headless_feel` already did.

## Still open, unexplained

- `dedicated` exited with 23 ObjectDB instances and 6 resources leaked (2026-09-23), as many before the message self-preloads were removed as after: too few to be the whole script graph, so a different shape from the one mg-buses-from-hell had. Not re-measured since.
