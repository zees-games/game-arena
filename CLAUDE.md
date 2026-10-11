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
| `game/arena_game.gd`, `arena_player.gd`, `arena_player_stack.gd` | the simulation: the game and its tick, the player (movement, weapons, health, hitboxes), the roster and spawning |
| `game/arena_mode.gd`, `arena_modes.gd`, `arena_objectives.gd`, `arena_effects.gd`, `arena_spectate.gd`, `arena_drops.gd` | modes as data and the round's layers |
| `game/arena_horde.gd`, `arena_npcs.gd`, `arena_npc_brain.gd`, `arena_props.gd`, `arena_projectiles.gd`, `arena_content.gd` | monsters, props, projectiles, weapons and the damage table |
| `game/arena_module.gd`, `arena_services.gd`, `arena_mod_tools.gd`, `arena_vote*.gd`, `arena_map_director.gd`, `arena_map_session.gd`, `arena_maps.gd`, `arena_bots.gd`, `arena_server.gd` | the server: the dot-server module and its cvars, chat/voice/moderation, admin tools, the vote, maps, bots |
| `game/arena_net_*.gd`, `arena_player_net.gd`, `arena_npc_net.gd`, `arena_events.gd`, `arena_event.gd`, `arena_request.gd` | the dot-net bridge, link, commands, per-entity net state, events and requests |
| `game/arena_client.gd`, `arena_client_extras.gd`, `arena_hud.gd`, `arena_menus.gd`, `arena_presentation.gd`, `arena_browser.gd`, `arena_party.gd`, `arena_avatars.gd`, `arena_beacon.gd`, `arena_projectile_view.gd`, `arena.tscn` | the client: never loaded by a dedicated server |
| `game/arena_stats.gd`, `arena_awards.gd`, `arena_boards.gd`, `arena_progress.gd`, `arena_identity.gd` | progression and identity |
| `game/arena_paths.gd` | `rebase` for every `res://` path (pack delivery) |
| `maps/arena_map.gd`, `arena_map_survey.gd` | the built-in maps as box lists, and the survey |
| `maps/arena_bsp_map.gd`, `arena_imported_maps.gd`, `arena_map_mechanics.gd`, `arena_ladder_mode.gd`, `*.gdshader` | the combat surf maps (copies of g2gfast's loader); `maps/imported` is the g2gfast-maps link |
| `npcs/`, `props/`, `avatars/`, `scenes/fx/`, `assets/` | monster and prop scenes, avatar parts (generated), effect scenes, vendored zee art |
| `examples/` | the eight suites |
| `tools/` | `screenshot.sh`, `screenshot_menus.sh`, `screenshot_weapons.sh`, `build_avatar_parts.gd`, `audio_probe.sh` |
| `scenes/arena_server.tscn`, `game.yml` | the server scene and the descriptor that travels in the pack |

## Running and testing

- `./game.sh` plays offline; `./game.sh online` runs a local server and client; `./game.sh test` parses everything and runs all eight suites; `./game.sh test <suite>` runs one; `./game.sh help` lists the rest. The addon links come from `.gitignore` through dot-bootstrap; do not hand-make them.
- **Run the suites after changing any dot-* addon this game links.** That is what this project is for. [testing](docs/testing.md)
- `headless_presentation` is the only suite with a client in it; `headless_lossy` is the only one with real ENet and real loss (about 50 s, real time). [testing](docs/testing.md#the-suites)
- Read every suite's stderr even when it exits 0; cap every run with `timeout`. [testing](docs/testing.md#traps-the-suites-have-hit)
- **Look at it.** No check reaches the screen: `tools/screenshot.sh <map> [--view|--admin|--fx|--feel]`, `tools/screenshot_menus.sh`, `tools/screenshot_weapons.sh`, under `xvfb-run`. [client](docs/client.md#looking-at-it)
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
- Ammunition, the carried set and blind are owner-only. A replayed tick fires nothing (`begin_replay`). [netcode](docs/netcode.md#weapons-over-the-wire)
- `INPUT_COPIES` (5) and `link_rtt_ms` are what keep commands on time under loss. [netcode](docs/netcode.md#inputs-and-the-clock-under-real-loss)
- The local view is `view_now` (`DotFpsSampler.look_now()`, every frame) and the eye adds `drawn_offset` (`DotNetPredictor.visual_offset`); drawing the state's angles freezes the view on every frame with no tick. [netcode](docs/netcode.md#drawing-between-ticks)

**Client**

- Adopt the player on `player_added`, never `player_spawned`. Offline, name the player before creating it. [client](docs/client.md#booting-and-adopting-a-player)
- The client owns the mouse; `manage_mouse` stays off. [client](docs/client.md#the-mouse)
- The camera is written only in `ArenaPlayer.present`. A server may clamp the field of view, never read it. [client](docs/client.md#the-camera-is-written-in-exactly-one-place)
- A client's own `mode` is never replaced; display reads `displayed_mode()`. [client](docs/client.md#a-client-knows-the-mode-only-for-display)
- Effects are built against `ArenaPresentation.facing` (-Z along the shot); a missing scene is a warning. [client](docs/client.md#effect-scenes)
- Typing (chat box or console) sets `DotFpsSampler.suspended` as well as swallowing input; the console is `DotConsoleKit`'s, wired to the sampler because there is no DotMenu. [client](docs/client.md#the-chat-box)
- Full-screen overlays are sized to the viewport, not the HUD. [client](docs/client.md#the-hud)
- Third person is deliberately not here: one motor to agree about. [client](docs/client.md#avatars)

**Modes and the round**

- Modes are `ArenaMode` resources; `team_count` and `team_based` must agree; the rules are duplicated before use. [modes](docs/modes.md#modes-are-data)
- Build the team manager before `add_child(match_node)`; assign `resolver.team_of` after `add_child(combat)`. [modes](docs/modes.md#modes-are-data)
- Whether there are sides is the mode's answer (`is_team_mode()`), not the team manager's. [modes](docs/modes.md#modes-are-data)
- Gun game's level is the match score, and its score limit is the list's length. [modes](docs/modes.md#gun-game-and-weapon-pools)
- Anything hooked to the combat manager rebinds on `map_changed`. [modes](docs/modes.md#effects)
- Spawn protection: one duration, three records; it does not break on attack; an admin slay passes. [modes](docs/modes.md#spawn-protection)
- Body breaking is seeded from victim and killer, never the tick. [modes](docs/modes.md#criticals-and-bodies)
- Take a pickup out of the field as it goes, not at the end of the frame. [modes](docs/modes.md#coins-out-of-a-body)

**Maps**

- The catalogue is built from `ArenaMap.ids()`, never a second list. Bump a map's entry in `MAP_VERSIONS` when its geometry changes. [maps](docs/maps.md#maps-are-content-and-these-maps-are-code)
- `setup` is not re-entrant; `change_map` is, and respawns everybody. Rebind, never rebuild, what survives. [maps](docs/maps.md#changing-the-map)
- A client builds the def it is handed, never `game.map`. [maps](docs/maps.md#reaching-the-players)
- `dm_pit`'s spawns stay untagged; `restrict_rotation` never empties the order. [maps](docs/maps.md#modes-a-map-can-host)
- Every map passes the survey: no slot under 0.8 m unless a declared climb, nothing unreached unless declared. [maps](docs/maps.md#every-map-is-surveyed)
- A bot that covers ground does not hold jump. [maps](docs/maps.md#every-map-is-surveyed)
- Stairs are 0.36 treads ending flush; crate gaps 0.5; a new way up is watched from above. [maps](docs/maps.md#design-rules-every-map-follows)
- An imported map's solid is in the tree on every machine before any player is bodied; its spawns are settled. [imported](docs/imported-maps.md#the-solid-is-the-games-on-every-machine)
- Map mechanics run inside the simulated tick on both ends; pushes are stateless; swim and ladder modes are registered on every map. [imported](docs/imported-maps.md#the-maps-own-mechanics)
- Arena needs a client shell with dot-player-controller v0.1.5 or later. [imported](docs/imported-maps.md#the-solid-is-the-games-on-every-machine)

**Horde, weapons, services**

- Monster entity ids come from the `DotEntityTable`; players keep session ids on purpose. [horde](docs/horde.md#a-monsters-entity-id)
- A non-player death goes to `non_player_killed`, never `report_kill`. [horde](docs/horde.md#a-non-player-entity-in-dot-combat)
- `DotPhysGun.hold` every tick; the prop tool is an intent. [horde](docs/horde.md#props)
- The rig drives the player's own `Arsenal`; call newer zee methods through `has_method`. [weapons](docs/weapons.md#the-rig-drives-the-players-own-arsenal)
- A detonation pins the attacker's origin to the blast. [weapons](docs/weapons.md#projectiles)
- `DotAchievementStatsLink`, never `recorded.connect`. [services](docs/services.md#progression)
- One chat path; hook `player_command` too; moderation is built first. [services](docs/services.md#chat)
- The speaker id comes from the transport, never the payload. [services](docs/services.md#voice)
- `admin_abilities` on every player, both ends. [services](docs/services.md#an-administrators-live-tools)
- One vote clock; voters keyed by bare session id. [services](docs/services.md#the-map-vote)
- A private match reports nothing (`reporting_allowed()`), and does not migrate. [services](docs/services.md#a-private-match-files-nothing)

## Not here yet

- **The Escape (pause) menu and settings screens are not converted to dot-menu yet.** Every other game uses dot-menu's Escape menu; arena is still on dot-ui's `DotPauseScreen` (`ArenaMenus`). No reason is recorded, and the one game-hungario gives (a `DotConfig`) does not apply, since arena's settings are already dot-settings. Unfinished; queued as `arena-dot-menu-1`. Only the Tab scoreboard is dot-menu's. [client](docs/client.md#screens)
- **dot-game.** The module extends `DotModule` and `ArenaServices` is its own, not `DotGameModule` / `DotGameServices`. Not yet converted; dot-game's CLAUDE.md names arena as the one to convert first.
- **Delivering the combat surf maps.** The code is done; the maps still need publishing as packs from g2gfast-maps, each author's permission for redistribution confirming, and the keys naming in a deployment's `cfg/content.yml`. [imported](docs/imported-maps.md#delivered-maps)
- **Server bots** do not use the horde's navigation graph (on a map with corners they walk into walls between spawns until they see somebody), buy or choose nothing, and are not a separate count in the query answer. [netcode](docs/netcode.md#server-bots)
- **Monsters do not animate**: the figure stands while the monster moves. [horde](docs/horde.md#figures)
- **Coins** do not feed the match score or a power-up meter and are not a dot-stats stat. **Challenges** (a dot-achievements progress bar) are not built. [modes](docs/modes.md#coins-out-of-a-body)
- **Pickups in the world**: the map places none (only what a critical kill drops). A level-design decision, not a wiring one.
- **Joining from the browser** is deliberately not done: Join notes the visit and says where to go, because reconnecting elsewhere is the launcher's job and this game is loaded by one.
- **Real audio files**: synthesised stand-ins for every id. [client](docs/client.md#the-presentation-layer)
- **Heavy-loss stalls** and the other games' bridges lacking input copies. [netcode](docs/netcode.md#still-open)
