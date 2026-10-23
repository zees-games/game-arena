# game-arena

The reference game: a 3D deathmatch in six kinds of mode on three built-in maps and arena-surf-dm-maps' combat surf maps (delivered, not shipped), with bots and zee-dot-weapons, over dot-net, as a signed dot-cloud pack: the only test of the joins between the addons.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this game. **The detail is in [docs/](docs/README.md)**.

## Read before

| Read | Before |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | a join between addons, ids, tick order, delivery |
| [docs/netcode.md](docs/netcode.md) | the bridge, RULES, anything on the wire, bots, the clock |
| [docs/client.md](docs/client.md) | the client, keys, camera, menus, HUD, chat box, render tools |
| [docs/modes.md](docs/modes.md) | movement, modes, spawning, criticals, streaks |
| [docs/maps.md](docs/maps.md), [docs/imported-maps.md](docs/imported-maps.md) | a built-in map or the catalogue; the combat surf maps |
| [docs/horde.md](docs/horde.md), [docs/weapons.md](docs/weapons.md) | monsters and props tools; zee-dot-weapons, projectiles |
| [docs/services.md](docs/services.md) | progression, chat, moderation, voice, admin tools, the vote |
| [docs/testing.md](docs/testing.md) | adding a check, or believing a green run |
| [docs/history.md](docs/history.md), [docs/not-yet.md](docs/not-yet.md) | a bug that "cannot be happening"; planning what is not built yet |

## Layout

| Path | What |
| --- | --- |
| `game/` | everything that runs, flat; the client half is never loaded by a dedicated server. File by file: [architecture](docs/architecture.md#where-the-code-is) |
| `maps/` | the built-in maps as box lists (survey, paint, lighting); the combat surf maps' loader; `maps/imported` links arena-surf-dm-maps |
| `npcs/`, `props/`, `avatars/`, `scenes/fx/`, `assets/` | monsters, props, avatar parts, effects, vendored zee art, Kenney's grid and medal icons |
| `examples/` | the nine suites; `wall_route_driver.gd` drives a map's wall routes |
| `tools/` | render tools (`screenshot.sh --glance`), avatar and icon builders, `audio_probe.sh`, `loudness_pilot.gd`. [client](docs/client.md#looking-at-it) |
| `scenes/arena_server.tscn`, `game.yml` | the server scene and the descriptor that travels in the pack |

## Running and testing

- `./game.sh` plays offline; `test` parses everything and runs all nine suites (`test <suite>` one); `help` lists the rest. Addon links come from `.gitignore`, never by hand.
- **Run the suites after changing any dot-* addon this game links.** [testing](docs/testing.md)
- `headless_presentation` and `headless_feel` have a client, `headless_lossy` and `headless_feel` real ENet and loss; only `headless_feel` judges frames. [testing](docs/testing.md#the-suites)
- Read every suite's stderr even when it exits 0; cap every run with `timeout`. [testing](docs/testing.md#traps-the-suites-have-hit)
- A suite or tool that builds a presentation or client calls `ArenaPresentation.use_scratch_settings` first. [testing](docs/testing.md#traps-the-suites-have-hit)
- **Look at it.** No check reaches the screen: `tools/` under `xvfb-run`; a camera change in `render_cameras.sh` (armed) and `render_views.gd`. [client](docs/client.md#looking-at-it)
- Without the `maps/imported` link the built-in maps play and the imported checks skip; supported.

## Rules that bite

**Architecture**

- Footsteps and per-map beds are dot-audio's stock; measure levels with its `loudness.sh`, and check the pilot walked. [client](docs/client.md#footsteps-and-the-bed)
- One player id: `player_id` is the session userid, never the peer id. Loadout keys are `"arena-player-%08d"`. [architecture](docs/architecture.md#one-id-space-for-players)
- Tick order: movement, then shots after everyone moved, then map hurt, then the match. [architecture](docs/architecture.md#order-inside-a-tick)
- `ArenaMap`'s scene, movement body and trace come from one box list; never build one separately. [architecture](docs/architecture.md#one-description-three-representations)
- No `class_name` anywhere (pack delivery): preload by relative path, `res://` through `ArenaPaths.rebase`. [architecture](docs/architecture.md#where-it-runs)
- Only `ArenaModule` and `ArenaServices` name dot-server; only `ArenaNetBridge` names both the game and dot-net.

**Netcode**

- The first `_net_simulate` on a tick runs the whole game (`ensure_game_ticked`); the server tick calls it again. [netcode](docs/netcode.md#the-bridge)
- `Authority.SHARED`; `receive_snapshot` must not reconcile. [netcode](docs/netcode.md#the-bridge)
- `NET_WORLD_EXTENT` (512) and `NET_SNAPSHOT_RATE` are written once, on `ArenaGame`. [netcode](docs/netcode.md#one-number-written-once)
- The client predicts with the server's collision (`Mode.HEADLESS`, or the imported brushes), never physics of its own. [netcode](docs/netcode.md#the-client-predicts-with-the-servers-collision)
- Players are solid through the movement body (`mp_solidplayers` REPLICATED), never a physics hull; spawn sight uses `combat.trace`. [netcode](docs/netcode.md#players-are-solid-to-each-other)
- A READY before the seat is kept (`ArenaNetBridge._ready_unseated`) and answered by `add_player`; answered at once its HELLO named session 0. [netcode](docs/netcode.md#events-and-requests)
- Event and request kinds are appended, never inserted. No message script preloads itself. [netcode](docs/netcode.md#events-and-requests)
- Anything a client predicts or draws from a server rule travels in RULES, to a joiner before any JOIN. [netcode](docs/netcode.md#rules-a-client-predicts-with-travel-in-rules)
- A family cvar a client predicts with is `FLAG_REPLICATED` and followed, not in RULES, re-applied after a map change. [netcode](docs/netcode.md#rules-a-client-predicts-with-travel-in-rules)
- Ammunition, the carried set and blind are owner-only; a replayed tick fires nothing and emits no movement signal. [netcode](docs/netcode.md#weapons-over-the-wire)
- `INPUT_COPIES` (5) and `link_rtt_ms` are what keep commands on time under loss. [netcode](docs/netcode.md#inputs-and-the-clock-under-real-loss)
- The local view is `view_now`; the eye adds `drawn_offset` at `drawn_alpha`, never the engine's fraction. [netcode](docs/netcode.md#drawing-between-ticks)

**Client**

- Adopt the player on `player_added`, never `player_spawned`. Offline, name the player before creating it. [client](docs/client.md#booting-and-adopting-a-player)
- The camera is written only in `ArenaPlayer.present`, never `DotFpsView`; a server may clamp the field of view, never read it. [client](docs/client.md#the-camera-is-written-in-exactly-one-place)
- A client's own `mode` is never replaced; display reads `displayed_mode()`. [client](docs/client.md#a-client-knows-the-mode-only-for-display)
- Effects are built against `ArenaPresentation.facing` (-Z along the shot); a missing scene is a warning. [client](docs/client.md#effect-scenes)
- Players and bots are dot-player-char's people (`ArenaAvatars.look_of`); the document stays `arena_stock`; the gun hand is the left. [client](docs/client.md#avatars)
- The Escape menu is dot-menu's (`ArenaMenus`): Escape releases, then opens it; only a click captures. [client](docs/client.md#escape-the-pointer-and-the-menu)
- Every key the client reads is an `ArenaBindings` row read through its action, never a keycode; props modes reuse Launch and Bash; V is push to talk (no noclip). [client](docs/client.md#keys)
- M is the map menu: solo `map_menu_rows()` / `change_from_menu()`, on a server dot-vote's menu over this ballot. No row may default to M. [client](docs/client.md#escape-the-pointer-and-the-menu)
- B is the loadout menu: the authority's `loadout_command` decides; a choice is in the hands at once only in warmup or spawn protection. No row may default to B. [modes](docs/modes.md#loadouts-and-the-owners-rules)
- The crosshair fades down the sights (`set_aim`); a scope still hides it. [client](docs/client.md#escape-the-pointer-and-the-menu)
- The wheel rows are "Wheel up" / "Wheel down" (dot-ui names the wheel from level 2; a pack asks for dot-ui 4). [client](docs/client.md#keys)
- Typing suspends the sampler too; the console is a menu overlay, built after the menu (`build_console(menu)`). [client](docs/client.md#the-chat-box)
- Full-screen overlays are sized to the viewport; HUD pieces draw handed values; judge them with `screenshot.sh --glance` at 16:9, 4:3 and 854x480. [client](docs/client.md#the-hud)
- The HUD follows dot-menu's theme and `hud_scale`; a HUD colour is a theme name (`Ink.c`), never a literal, except side, medal and weapon colours. [client](docs/client.md#the-hud)
- Below 1280x720 the HUD is scaled (`fit_design`), never re-laid out; a new piece gets a `footprint()`. [client](docs/client.md#the-hud)
- Half the HUD is dot-ui's glance pieces and the winner reveal is `DotWinnerReveal`, so the pack needs dot-ui 9 (`requires.floor.json`). [client](docs/client.md#the-hud)
- Nothing of the HUD on the right edge from 110 px down (the shell's column); below a ballot a piece reads `dot_hud_cover`. [client](docs/client.md#the-hud)
- The streak meter ends above a full chat log; the chat box is scaled with the HUD and clear of the slide prompt. [client](docs/client.md#the-chat-box)
- Hit marker, damage numbers, medals, points and nemesis come only from the server's HIT and AWARD, never a predicted shot. [client](docs/client.md#kill-feedback)
- Medal rules live in `ArenaAwards.MedalBook` on the authority; `ArenaAwards.Medal` is a wire index, appended only. [services](docs/services.md#progression)
- Every bot, solo and server, is `ArenaBots.think`; its settings live on the game, never in the registry. [netcode](docs/netcode.md#bots)
- Third person is deliberately not here: one motor to agree about. [client](docs/client.md#avatars)

**Modes and the round**

- Wall run, jump and slide are on (`arena_wall_*`, in RULES); `wall_run_min_speed` stays above `max_speed`, or a jump beside a wall becomes a run. [modes](docs/modes.md#movement-is-a-games-choice)
- Modes are `ArenaMode` resources; `team_count` and `team_based` must agree; the rules are duplicated before use. [modes](docs/modes.md#modes-are-data)
- Build the team manager before `add_child(match_node)`; assign `resolver.team_of` after `add_child(combat)`. [modes](docs/modes.md#modes-are-data)
- Whether there are sides is the mode's answer (`is_team_mode()`), not the team manager's. [modes](docs/modes.md#modes-are-data)
- Gun game's level is the match score, and its score limit is the list's length. [modes](docs/modes.md#gun-game-and-weapon-pools)
- A match cvar writes the `ArenaGame` export AND the live match (`apply_match_limits`). [modes](docs/modes.md#modes-are-data)
- Anything hooked to the combat manager rebinds on `map_changed`. [modes](docs/modes.md#effects)
- Spawn protection: one duration, three records; it does not break on attack; an admin slay passes. [modes](docs/modes.md#spawn-protection)
- Body breaking is seeded from victim and killer, never the tick; a death's fall is the server's pick (`decide_death`), never a client's. [modes](docs/modes.md#criticals-and-bodies)
- A monster brain seeds from `npc.seed`, never `npc.instance_id` (moves with every allocation). dot-npc `docs/runtime.md`
- Take a pickup out of the field as it goes, not at the end of the frame. [modes](docs/modes.md#coins-out-of-a-body)

**Maps**

- The catalogue is built from `ArenaMap.ids()`, never a second list; bump `MAP_VERSIONS` when a map's geometry changes. [maps](docs/maps.md#maps-are-content-and-these-maps-are-code)
- `setup` is not re-entrant; `change_map` is, and respawns everybody. Rebind, never rebuild, what survives. [maps](docs/maps.md#changing-the-map)
- A client builds the def it is handed, never `game.map`. [maps](docs/maps.md#reaching-the-players)
- `dm_pit`'s spawns stay untagged; `restrict_rotation` never empties the order. [maps](docs/maps.md#modes-a-map-can-host)
- Built-in toys are loose only; a client registers every toy mirror before its map is built. [maps](docs/maps.md#toys), [netcode](docs/netcode.md#the-maps-toys)
- Every map passes the survey: no slot under 0.8 m and nothing unreached unless declared; a bot that covers ground does not hold jump. [maps](docs/maps.md#every-map-is-surveyed)
- Stairs are 0.36 treads ending flush; crate gaps 0.5; a new way up is watched from above. [maps](docs/maps.md#design-rules-every-map-follows)
- A wall route is declared (`add_wall_route`) and driven in `headless_match`; a run gap drops about 0.7 m and outspans a dash-jump. [maps](docs/maps.md#design-rules-every-map-follows)
- Colour comes from a box's role and zone, never the box list; a repaint is not a `MAP_VERSIONS` bump. [maps](docs/maps.md#colour-and-light)
- A built-in map's light is its `lighting` document; render a look change under `gl_compatibility` too. [maps](docs/maps.md#colour-and-light)
- An imported map is lit from its manifest (`imported_profile`), a built-in map with `painted()` (dot-lighting 3). [imported](docs/imported-maps.md#lit-from-the-manifest)
- A guard on a host addon's level needs that addon in `requires.floor.json` at the older path's level. [client](docs/client.md#keys)
- An imported map's solid is in the tree on every machine before any player is bodied; spawns are settled. [imported](docs/imported-maps.md#the-solid-is-the-games-on-every-machine)
- Bots route on an imported map over a `DotBotNav` baked in the background, never in the tick. [imported](docs/imported-maps.md#bots-route-over-a-mesh-baked-from-the-brushes)
- Ride edges are planned by `tools/surf_rides.tscn`, never at load; `arena_surf.gd` loads by path only with dot-bot 4, dot-player-controller 3. [imported](docs/imported-maps.md#bots-ride-the-ramps)
- Map mechanics run inside the simulated tick on both ends; pushes are stateless; swim and ladder modes are registered on every map. [imported](docs/imported-maps.md#the-maps-own-mechanics)
- A Workshop map (solo only, `provides.json` `accepts`) is a JSON box-list document whose id is its entry's id; a bad one is refused and unlisted, the game's ids win. [maps](docs/maps.md#workshop-maps)
- Arena needs a shell with dot-player-controller v0.1.5+, the wall moves and `DotFpsViewMotion`. [imported](docs/imported-maps.md#the-solid-is-the-games-on-every-machine)

**Horde, weapons, services**

- Monster entity ids come from the `DotEntityTable`; players keep session ids on purpose. [horde](docs/horde.md#a-monsters-entity-id)
- A non-player death goes to `non_player_killed`, never `report_kill`. [horde](docs/horde.md#a-non-player-entity-in-dot-combat)
- `DotPhysGun.hold` every tick; the prop tool is an intent. [horde](docs/horde.md#props)
- The rig drives the player's own `Arsenal`; call newer zee methods through `has_method`. [weapons](docs/weapons.md#the-rig-drives-the-players-own-arsenal)
- A detonation pins the attacker's origin to the blast. [weapons](docs/weapons.md#projectiles)
- A projectile passes through a team-mate holding its launch point, and at `mp_teammate_passthrough` 2 misses every team-mate all flight (dot-combat's, by name). [weapons](docs/weapons.md#projectiles)
- `DotAchievementStatsLink`, never `recorded.connect`. [services](docs/services.md#progression)
- One chat path; hook `player_command` too; moderation is built first. [services](docs/services.md#chat)
- The speaker id comes from the transport, never the payload. [services](docs/services.md#voice)
- `admin_abilities` on every player, both ends. [services](docs/services.md#an-administrators-live-tools)
- One vote clock; voters keyed by bare session id. [services](docs/services.md#the-map-vote)
- A private match reports nothing (`reporting_allowed()`), and does not migrate. [services](docs/services.md#a-private-match-files-nothing)
