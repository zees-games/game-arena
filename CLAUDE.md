# game-arena

The reference game: a 3D dev-textured deathmatch with free-for-all, team, objective, horde (`siege`), props and gun-game modes, three built-in maps plus the combat surf maps from g2gfast-maps, server bots, and zee-dot-weapons for every gun. Networked over dot-net and delivered as a signed dot-cloud pack. It is the deployment shape where most of the family runs in one process, so it is a game and also the only test of the joins between the addons.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this game. **The detail is in [docs/](docs/README.md)**: open the file for what you are touching.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/architecture.md](docs/architecture.md) | a join between addons, the player id space, tick order, the map's three representations, delivery |
| [docs/netcode.md](docs/netcode.md) | the bridge, shared constants, event kinds, RULES, weapons and monsters on the wire, server bots, input copies, the clock, lag compensation |
| [docs/client.md](docs/client.md) | the client, mouse, keys, camera, presentation and effects, menus, HUD, chat box, avatars, render tools |
| [docs/modes.md](docs/modes.md) | movement, modes, gun game, objectives, effects, spawn protection, spawning, spectating, criticals, drops, streaks |
| [docs/maps.md](docs/maps.md) | a built-in map, the catalogue, `change_map`, the director and sync, mode filtering, the survey, the design rules |
| [docs/imported-maps.md](docs/imported-maps.md) | the combat surf maps: loader, solid, spawns, pits, surf movement, rotation, delivery, mechanics |
| [docs/horde.md](docs/horde.md) | monsters and the props tools |
| [docs/weapons.md](docs/weapons.md) | zee-dot-weapons' wiring, the rig, projectiles, loadout slots |
| [docs/services.md](docs/services.md) | progression, chat, moderation, voice, the relay, admin tools, the vote, the browser, private matches |
| [docs/testing.md](docs/testing.md) | adding a check, or believing a green run |
| [docs/history.md](docs/history.md) | a bug that "cannot be happening"; what this game found and how it looked |

## Layout

| Path | What |
| --- | --- |
| `game/` | everything that runs, flat: the simulation (`arena_game`, `arena_player*`), modes and the round's layers, the horde and props, the server (`arena_module`, `arena_services`, maps, vote, bots), the wire (`arena_net_*`, events, requests), the client (`arena_client`, `arena_hud`, `arena_hud_glance`, `arena_menus`, `arena_bindings`, `arena_presentation`, browser, avatars; never loaded by a dedicated server), progression, `arena_paths` (pack rebasing). File by file: [architecture](docs/architecture.md#where-the-code-is) |
| `maps/` | the built-in maps as box lists with their survey, paint and lighting; the combat surf maps' loader (copies of g2gfast's); `maps/imported` is the g2gfast-maps link |
| `npcs/`, `props/`, `avatars/`, `scenes/fx/`, `assets/` | monster and prop scenes, avatar parts (generated), effect scenes, vendored zee art, Kenney's prototype grid and medal icons |
| `examples/` | the eight suites; `wall_route_driver.gd` drives a map's wall routes |
| `tools/` | `screenshot.sh` (`--glance` is the whole HUD), `screenshot_menus.sh`, `screenshot_weapons.sh`, `render_wall_moves.sh`, `build_avatar_parts.gd`, `build_weapon_icons.sh`, `audio_probe.sh` |
| `scenes/arena_server.tscn`, `game.yml` | the server scene and the descriptor that travels in the pack |

## Running and testing

- `./game.sh` plays offline; `./game.sh online` runs a local server and client; `./game.sh test` parses everything and runs all eight suites; `./game.sh test <suite>` runs one; `./game.sh help` lists the rest. The addon links come from `.gitignore` through dot-bootstrap; do not hand-make them.
- **Run the suites after changing any dot-* addon this game links.** That is what this project is for. [testing](docs/testing.md)
- `headless_presentation` is the only suite with a client in it; `headless_lossy` is the only one with real ENet and real loss (about 50 s, real time). [testing](docs/testing.md#the-suites)
- Read every suite's stderr even when it exits 0; cap every run with `timeout`. [testing](docs/testing.md#traps-the-suites-have-hit)
- A suite or tool that builds a presentation or client calls `ArenaPresentation.use_scratch_settings` first: never the player's file. [testing](docs/testing.md#traps-the-suites-have-hit)
- **Look at it.** No check reaches the screen: `tools/screenshot.sh <map> [--view|--admin|--fx|--feel]`, `tools/screenshot_menus.sh`, `tools/screenshot_weapons.sh`, `tools/render_wall_moves.sh` (a move as a frame sequence), under `xvfb-run`. [client](docs/client.md#looking-at-it)
- Without the `maps/imported` link the three built-in maps play and the imported checks skip; that is supported.

## Rules that bite

Short forms; the reasoning is in the linked file.

**Architecture**

- One player id: `player_id` is the session userid, never the peer id. Loadout keys are `"arena-player-%08d"`. [architecture](docs/architecture.md#one-id-space-for-players)
- Tick order: movement, then shots after everyone moved, then map hurt, then the match. [architecture](docs/architecture.md#order-inside-a-tick)
- `ArenaMap`'s scene, movement body and trace come from one box list; never build one separately. [architecture](docs/architecture.md#one-description-three-representations)
- No `class_name` anywhere (pack delivery): preload by relative path, `res://` through `ArenaPaths.rebase`. [architecture](docs/architecture.md#where-it-runs)
- Only `ArenaModule` and `ArenaServices` name dot-server; only `ArenaNetBridge` names both the game and dot-net.

**Netcode**

- The first `_net_simulate` on a tick runs the whole game (`ensure_game_ticked`); the server tick calls it again. [netcode](docs/netcode.md#the-bridge)
- `Authority.SHARED`; `receive_snapshot` must not reconcile. [netcode](docs/netcode.md#the-bridge)
- `NET_WORLD_EXTENT` (512) and `NET_SNAPSHOT_RATE` are written once, on `ArenaGame`. [netcode](docs/netcode.md#one-number-written-once)
- The client predicts with the server's collision (`Mode.HEADLESS`, or the imported map's brushes), never Godot physics of its own. [netcode](docs/netcode.md#the-client-predicts-with-the-servers-collision)
- Event and request kinds are appended, never inserted. No message script preloads itself. [netcode](docs/netcode.md#events-and-requests)
- Anything a client predicts or draws from a server rule travels in RULES, to a joiner before any JOIN. [netcode](docs/netcode.md#rules-a-client-predicts-with-travel-in-rules)
- Ammunition, the carried set and blind are owner-only. A replayed tick fires nothing and emits no movement signal: `_predict` marks the rig and the controller (`begin_replay`). [netcode](docs/netcode.md#weapons-over-the-wire)
- `INPUT_COPIES` (5) and `link_rtt_ms` are what keep commands on time under loss. [netcode](docs/netcode.md#inputs-and-the-clock-under-real-loss)
- The local view is `view_now` (`DotFpsSampler.look_now()`, every frame) and the eye adds `drawn_offset` (`DotNetPredictor.visual_offset`); drawing the state's angles freezes the view on every frame with no tick. [netcode](docs/netcode.md#drawing-between-ticks)

**Client**

- Adopt the player on `player_added`, never `player_spawned`. Offline, name the player before creating it. [client](docs/client.md#booting-and-adopting-a-player)
- The camera is written only in `ArenaPlayer.present`, the wall-run lean included (`wall_run_roll`; arena does not use `DotFpsView`). A server may clamp the field of view, never read it. [client](docs/client.md#the-camera-is-written-in-exactly-one-place)
- A client's own `mode` is never replaced; display reads `displayed_mode()`. [client](docs/client.md#a-client-knows-the-mode-only-for-display)
- Effects are built against `ArenaPresentation.facing` (-Z along the shot); a missing scene is a warning. [client](docs/client.md#effect-scenes)
- The Escape menu is dot-menu's (`ArenaMenus`): Escape releases, then opens it; only a click captures; the client owns the pointer (`manage_pointer`, `manage_mouse` off). Movable keys are one table, `ArenaBindings`. [client](docs/client.md#escape-the-pointer-and-the-menu)
- Typing suspends the sampler as well as swallowing input; the console does it as a menu overlay, so it is built after the menu (`build_console(menu)`). [client](docs/client.md#the-chat-box)
- Full-screen overlays are sized to the viewport. HUD pieces (`ArenaHudGlance`) draw handed values; judge them with `screenshot.sh --glance` at 16:9 and 4:3. [client](docs/client.md#the-hud)
- The hit marker, damage numbers, medals, points and nemesis come only from the server's HIT and AWARD; never from a predicted shot or a client's own count of kills. [client](docs/client.md#kill-feedback)
- Medal rules live in `ArenaAwards.MedalBook` on the authority; `ArenaAwards.Medal` is a wire index, appended only. [services](docs/services.md#progression)
- Third person is deliberately not here: one motor to agree about. [client](docs/client.md#avatars)

**Modes and the round**

- Wall run, wall jump and wall slide are on (`arena_wall_*`, in RULES); `wall_run_min_speed` stays above `max_speed`, or every jump beside a wall becomes a run. [modes](docs/modes.md#movement-is-a-games-choice)
- Modes are `ArenaMode` resources; `team_count` and `team_based` must agree; the rules are duplicated before use. [modes](docs/modes.md#modes-are-data)
- Build the team manager before `add_child(match_node)`; assign `resolver.team_of` after `add_child(combat)`. [modes](docs/modes.md#modes-are-data)
- Whether there are sides is the mode's answer (`is_team_mode()`), not the team manager's. [modes](docs/modes.md#modes-are-data)
- Gun game's level is the match score, and its score limit is the list's length. [modes](docs/modes.md#gun-game-and-weapon-pools)
- Anything hooked to the combat manager rebinds on `map_changed`. [modes](docs/modes.md#effects)
- Spawn protection: one duration, three records; it does not break on attack; an admin slay passes. [modes](docs/modes.md#spawn-protection)
- Body breaking is seeded from victim and killer, never the tick. [modes](docs/modes.md#criticals-and-bodies)
- A monster brain seeds from `npc.seed` (per spawn), never `npc.instance_id` (an identity whose value moves with every allocation). dot-npc `docs/runtime.md`
- Take a pickup out of the field as it goes, not at the end of the frame. [modes](docs/modes.md#coins-out-of-a-body)

**Maps**

- The catalogue is built from `ArenaMap.ids()`, never a second list. Bump a map's entry in `MAP_VERSIONS` when its geometry changes. [maps](docs/maps.md#maps-are-content-and-these-maps-are-code)
- `setup` is not re-entrant; `change_map` is, and respawns everybody. Rebind, never rebuild, what survives. [maps](docs/maps.md#changing-the-map)
- A client builds the def it is handed, never `game.map`. [maps](docs/maps.md#reaching-the-players)
- `dm_pit`'s spawns stay untagged; `restrict_rotation` never empties the order. [maps](docs/maps.md#modes-a-map-can-host)
- Every map passes the survey: no slot under 0.8 m unless a declared climb, nothing unreached unless declared; a bot that covers ground does not hold jump. [maps](docs/maps.md#every-map-is-surveyed)
- Stairs are 0.36 treads ending flush; crate gaps 0.5; a new way up is watched from above.
- A wall route is declared (`add_wall_route`) and driven through the motor in `headless_match`; a run gap drops about 0.7 m and outspans a dash-jump. [maps](docs/maps.md#design-rules-every-map-follows)
- Colour is derived from a box's role and zone (`arena_map_paint.gd`), never stored in the box list; a repaint is not a `MAP_VERSIONS` bump. [maps](docs/maps.md#colour-and-light)
- A built-in map's light is its `lighting` document (dot-lighting), replaced with the level. Render a look change with `RENDERER=gl_compatibility` too: the shell is Compatibility. [maps](docs/maps.md#colour-and-light)
- An imported map's solid is in the tree on every machine before any player is bodied; its spawns are settled. [imported](docs/imported-maps.md#the-solid-is-the-games-on-every-machine)
- Map mechanics run inside the simulated tick on both ends; pushes are stateless; swim and ladder modes are registered on every map. [imported](docs/imported-maps.md#the-maps-own-mechanics)
- Arena needs a client shell with dot-player-controller v0.1.5 or later, and with the wall moves (`arena_player.gd` names them). [imported](docs/imported-maps.md#the-solid-is-the-games-on-every-machine)

**Horde, weapons, services**

- Monster entity ids come from the `DotEntityTable`; players keep session ids on purpose. [horde](docs/horde.md#a-monsters-entity-id)
- A non-player death goes to `non_player_killed`, never `report_kill`. [horde](docs/horde.md#a-non-player-entity-in-dot-combat)
- `DotPhysGun.hold` every tick; the prop tool is an intent. [horde](docs/horde.md#props)
- The rig drives the player's own `Arsenal`; call newer zee methods through `has_method`. [weapons](docs/weapons.md#the-rig-drives-the-players-own-arsenal)
- A detonation pins the attacker's origin to the blast. [weapons](docs/weapons.md#projectiles)
- A projectile passes through a team-mate holding its launch point (dot-combat's `pass_through_sets`, called by name). [weapons](docs/weapons.md#projectiles)
- `mp_teammate_passthrough` is dot-combat's cvar, bound in `arena_module.gd` by name; at 2 (`pass_through_team_mates`) the projectile sweep keeps every team-mate out for the whole flight. [weapons](docs/weapons.md#projectiles)
- `DotAchievementStatsLink`, never `recorded.connect`. [services](docs/services.md#progression)
- One chat path; hook `player_command` too; moderation is built first. [services](docs/services.md#chat)
- The speaker id comes from the transport, never the payload. [services](docs/services.md#voice)
- `admin_abilities` on every player, both ends. [services](docs/services.md#an-administrators-live-tools)
- One vote clock; voters keyed by bare session id. [services](docs/services.md#the-map-vote)
- A private match reports nothing (`reporting_allowed()`), and does not migrate. [services](docs/services.md#a-private-match-files-nothing)

## Not here yet

- **Fire, aim, reload, the slots, the launch, the bash, the prop keys and push to talk cannot be rebound**: they are keycodes in `ArenaClient._unhandled_input`, not actions, so the Controls page lists them as fixed. Unfinished; queued as `arena-bindable-keys-1`. [client](docs/client.md#keys)
- **dot-game.** The module extends `DotModule` and `ArenaServices` is its own, not `DotGameModule` / `DotGameServices`. Not yet converted; dot-game's CLAUDE.md names arena as the one to convert first.
- **Delivering the combat surf maps**: code done; the packs need publishing from g2gfast-maps, each author's permission confirming, and naming in `cfg/content.yml`. [imported](docs/imported-maps.md#delivered-maps)
- **Server bots** do not use the horde's navigation graph (on a map with corners they walk into walls between spawns until they see somebody), buy or choose nothing, and are not a separate count in the query answer. [netcode](docs/netcode.md#server-bots)
- **Monsters do not animate**: the figure stands while the monster moves. [horde](docs/horde.md#figures)
- **Coins** do not feed the match score or a power-up meter and are not a dot-stats stat. **Challenges** (a dot-achievements progress bar) are not built. [modes](docs/modes.md#coins-out-of-a-body)
- **Pickups in the world**: the map places none (only what a critical kill drops). A level-design decision, not a wiring one.
- **Joining from the browser** is deliberately not done: Join notes the visit and says where to go, because reconnecting elsewhere is the launcher's job and this game is loaded by one.
- **Real audio files**: synthesised stand-ins for every id. [client](docs/client.md#the-presentation-layer)
- **Heavy-loss stalls** and the other games' bridges lacking input copies. [netcode](docs/netcode.md#still-open)
