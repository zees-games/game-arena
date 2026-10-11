# game-arena

The reference game: a 3D deathmatch (free-for-all, team, objective, horde `siege`, props, gun game) on three built-in maps and g2gfast-maps' combat surf maps, with server bots and zee-dot-weapons, networked over dot-net and delivered as a signed dot-cloud pack. Most of the family runs in one process here, so it is also the only test of the joins between the addons.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this game. **The detail is in [docs/](docs/README.md)**: open the file for what you are touching.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index, with what each file covers |
| [docs/architecture.md](docs/architecture.md) | a join between addons, ids, tick order, delivery |
| [docs/netcode.md](docs/netcode.md) | the bridge, RULES, anything on the wire, bots, the clock |
| [docs/client.md](docs/client.md) | the client, keys, camera, menus, HUD, chat box, render tools |
| [docs/modes.md](docs/modes.md) | movement, modes, spawning, criticals, streaks |
| [docs/maps.md](docs/maps.md), [docs/imported-maps.md](docs/imported-maps.md) | a built-in map or the catalogue; the combat surf maps |
| [docs/horde.md](docs/horde.md), [docs/weapons.md](docs/weapons.md) | monsters and props tools; zee-dot-weapons, projectiles |
| [docs/services.md](docs/services.md) | progression, chat, moderation, voice, admin tools, the vote |
| [docs/testing.md](docs/testing.md) | adding a check, or believing a green run |
| [docs/history.md](docs/history.md) | a bug that "cannot be happening" |
| [docs/not-yet.md](docs/not-yet.md) | planning: what is not built yet |

## Layout

| Path | What |
| --- | --- |
| `game/` | everything that runs, flat; the client half is never loaded by a dedicated server. File by file: [architecture](docs/architecture.md#where-the-code-is) |
| `maps/` | the built-in maps as box lists with their survey, paint and lighting; the combat surf maps' loader (copies of g2gfast's); `maps/imported` is the g2gfast-maps link |
| `npcs/`, `props/`, `avatars/`, `scenes/fx/`, `assets/` | monster and prop scenes, avatar parts (generated), effect scenes, vendored zee art, Kenney's prototype grid and medal icons |
| `examples/` | the nine suites; `wall_route_driver.gd` drives a map's wall routes |
| `tools/` | render tools (`screenshot.sh --glance` is the whole HUD), avatar and icon builders, `audio_probe.sh`. [client](docs/client.md#looking-at-it) |
| `scenes/arena_server.tscn`, `game.yml` | the server scene and the descriptor that travels in the pack |

## Running and testing

- `./game.sh` plays offline; `test` parses everything and runs all nine suites (`test <suite>` one); `help` lists the rest. Addon links come from `.gitignore` via dot-bootstrap, never by hand.
- **Run the suites after changing any dot-* addon this game links.** That is what this project is for. [testing](docs/testing.md)
- `headless_presentation` and `headless_feel` have a client; `headless_lossy` and `headless_feel` real ENet and loss; only `headless_feel` judges frames. [testing](docs/testing.md#the-suites)
- Read every suite's stderr even when it exits 0; cap every run with `timeout`. [testing](docs/testing.md#traps-the-suites-have-hit)
- A suite or tool that builds a presentation or client calls `ArenaPresentation.use_scratch_settings` first: never the player's file. [testing](docs/testing.md#traps-the-suites-have-hit)
- **Look at it.** No check reaches the screen: the render tools in `tools/` (above), under `xvfb-run`. [client](docs/client.md#looking-at-it)
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
- A family cvar a client predicts with (`mp_teammate_passthrough`) is `FLAG_REPLICATED` and followed (`ArenaGame.follow_server_cvars`), not in RULES; re-applied after every map change. [netcode](docs/netcode.md#rules-a-client-predicts-with-travel-in-rules)
- Ammunition, the carried set and blind are owner-only. A replayed tick fires nothing and emits no movement signal (`begin_replay`). [netcode](docs/netcode.md#weapons-over-the-wire)
- `INPUT_COPIES` (5) and `link_rtt_ms` are what keep commands on time under loss. [netcode](docs/netcode.md#inputs-and-the-clock-under-real-loss)
- The local view is `view_now`, the eye adds `drawn_offset` and is drawn at `drawn_alpha` (the clock's render alpha, -1..2 after a slip), never the engine's fraction. [netcode](docs/netcode.md#drawing-between-ticks)

**Client**

- Adopt the player on `player_added`, never `player_spawned`. Offline, name the player before creating it. [client](docs/client.md#booting-and-adopting-a-player)
- The camera is written only in `ArenaPlayer.present`, stair easing and `camera_motion` (dot-player-controller's `DotFpsViewMotion`: dip, rolls, widening; picks in `camera_motion_picks`, scaled by the `camera_*` settings) included, never `DotFpsView`; an offline bot's body is drawn between ticks there (`interpolate_body`). A server may clamp the field of view, never read it. [client](docs/client.md#the-camera-is-written-in-exactly-one-place)
- A client's own `mode` is never replaced; display reads `displayed_mode()`. [client](docs/client.md#a-client-knows-the-mode-only-for-display)
- Effects are built against `ArenaPresentation.facing` (-Z along the shot); a missing scene is a warning. [client](docs/client.md#effect-scenes)
- The Escape menu is dot-menu's (`ArenaMenus`): Escape releases, then opens it; only a click captures; the client owns the pointer. [client](docs/client.md#escape-the-pointer-and-the-menu)
- Every key the client reads is an `ArenaBindings` row read through its action, never a keycode; props modes reuse the Launch and Bash keys; no noclip key (V is push to talk). [client](docs/client.md#keys)
- Wheel rows are named only on a host dot-ui at API level 2 (`ArenaBindings.wheel_named`). [client](docs/client.md#keys)
- Typing suspends the sampler as well as swallowing input; the console does it as a menu overlay, so it is built after the menu (`build_console(menu)`). [client](docs/client.md#the-chat-box)
- Full-screen overlays are sized to the viewport. HUD pieces draw handed values; judge them with `screenshot.sh --glance` at 16:9, 4:3 and 854x480. [client](docs/client.md#the-hud)
- Below 1280x720 the whole HUD is scaled (dot-ui's `DotHud.fit_design`, set in `ArenaHud._init`), never re-laid out; a new piece gets a `footprint()`, which the overlap check reads. [client](docs/client.md#the-hud)
- Health, ammunition, the strip and clock, the prompt, the key hints, the hit marker and the damage numbers are dot-ui's glance pieces, so the pack needs dot-ui 4 (`requires.floor.json`); arena keeps the feed, portraits, slots, abilities, medals and streak meter. [client](docs/client.md#the-hud)
- Nothing of the HUD on the right edge below 110 px down to a six-row ballot: the shell's column is there (`--glance --ballot`); below that, a piece reads `dot_hud_cover` (`make_room`, `--map-ballot`). [client](docs/client.md#the-hud)
- The killstreak meter's words end above a full chat log (y 424 at 1280x720); the chat box is scaled with the HUD (`fit_chat_screen`) and 340 wide, clear of the slide prompt; `headless_presentation` checks it at five frames. [client](docs/client.md#the-chat-box)
- Hit marker, damage numbers, medals, points and nemesis come only from the server's HIT and AWARD, never a predicted shot. [client](docs/client.md#kill-feedback)
- Medal rules live in `ArenaAwards.MedalBook` on the authority; `ArenaAwards.Medal` is a wire index, appended only. [services](docs/services.md#progression)
- Third person is deliberately not here: one motor to agree about. [client](docs/client.md#avatars)

**Modes and the round**

- Wall run, wall jump and wall slide are on (`arena_wall_*`, in RULES); `wall_run_min_speed` stays above `max_speed`, or every jump beside a wall becomes a run. [modes](docs/modes.md#movement-is-a-games-choice)
- Modes are `ArenaMode` resources; `team_count` and `team_based` must agree; the rules are duplicated before use. [modes](docs/modes.md#modes-are-data)
- Build the team manager before `add_child(match_node)`; assign `resolver.team_of` after `add_child(combat)`. [modes](docs/modes.md#modes-are-data)
- Whether there are sides is the mode's answer (`is_team_mode()`), not the team manager's. [modes](docs/modes.md#modes-are-data)
- Gun game's level is the match score, and its score limit is the list's length. [modes](docs/modes.md#gun-game-and-weapon-pools)
- A match cvar (`arena_scorelimit`, `_timelimit`, `_warmup`, `_minplayers`) writes the `ArenaGame` export AND the live match (`apply_match_limits`), or it is lost at boot or the next map change. [modes](docs/modes.md#modes-are-data)
- Anything hooked to the combat manager rebinds on `map_changed`. [modes](docs/modes.md#effects)
- Spawn protection: one duration, three records; it does not break on attack; an admin slay passes. [modes](docs/modes.md#spawn-protection)
- Body breaking is seeded from victim and killer, never the tick. [modes](docs/modes.md#criticals-and-bodies)
- A monster brain seeds from `npc.seed`, never `npc.instance_id` (moves with every allocation). dot-npc `docs/runtime.md`
- Take a pickup out of the field as it goes, not at the end of the frame. [modes](docs/modes.md#coins-out-of-a-body)

**Maps**

- The catalogue is built from `ArenaMap.ids()`, never a second list. Bump a map's entry in `MAP_VERSIONS` when its geometry changes. [maps](docs/maps.md#maps-are-content-and-these-maps-are-code)
- `setup` is not re-entrant; `change_map` is, and respawns everybody. Rebind, never rebuild, what survives. [maps](docs/maps.md#changing-the-map)
- A client builds the def it is handed, never `game.map`. [maps](docs/maps.md#reaching-the-players)
- `dm_pit`'s spawns stay untagged; `restrict_rotation` never empties the order. [maps](docs/maps.md#modes-a-map-can-host)
- Every map passes the survey: no slot under 0.8 m and nothing unreached unless declared; a bot that covers ground does not hold jump. [maps](docs/maps.md#every-map-is-surveyed)
- Stairs are 0.36 treads ending flush; crate gaps 0.5; a new way up is watched from above. [maps](docs/maps.md#design-rules-every-map-follows)
- A wall route is declared (`add_wall_route`) and driven through the motor in `headless_match`; a run gap drops about 0.7 m and outspans a dash-jump. [maps](docs/maps.md#design-rules-every-map-follows)
- Colour is derived from a box's role and zone (`arena_map_paint.gd`), never stored in the box list; a repaint is not a `MAP_VERSIONS` bump. [maps](docs/maps.md#colour-and-light)
- A built-in map's light is its `lighting` document (dot-lighting), replaced with the level. Render a look change with `RENDERER=gl_compatibility` too: the shell is Compatibility. [maps](docs/maps.md#colour-and-light)
- An imported map is lit from its manifest's `lighting`; `sky_top` is repainted only on a dot-lighting below level 2. [imported](docs/imported-maps.md#lit-from-the-manifest)
- A guard on a host addon's level (`DotAddonApi.build_level`) needs that addon in `requires.floor.json` at the older path's level, or an older shell refuses the pack. [client](docs/client.md#keys)
- An imported map's solid is in the tree on every machine before any player is bodied; its spawns are settled. [imported](docs/imported-maps.md#the-solid-is-the-games-on-every-machine)
- Map mechanics run inside the simulated tick on both ends; pushes are stateless; swim and ladder modes are registered on every map. [imported](docs/imported-maps.md#the-maps-own-mechanics)
- Arena needs a client shell with dot-player-controller v0.1.5 or later, and with the wall moves and `DotFpsViewMotion` (`arena_player.gd` names them). [imported](docs/imported-maps.md#the-solid-is-the-games-on-every-machine)

**Horde, weapons, services**

- Monster entity ids come from the `DotEntityTable`; players keep session ids on purpose. [horde](docs/horde.md#a-monsters-entity-id)
- A non-player death goes to `non_player_killed`, never `report_kill`. [horde](docs/horde.md#a-non-player-entity-in-dot-combat)
- `DotPhysGun.hold` every tick; the prop tool is an intent. [horde](docs/horde.md#props)
- The rig drives the player's own `Arsenal`; call newer zee methods through `has_method`. [weapons](docs/weapons.md#the-rig-drives-the-players-own-arsenal)
- A detonation pins the attacker's origin to the blast. [weapons](docs/weapons.md#projectiles)
- A projectile passes through a team-mate holding its launch point (dot-combat's `pass_through_sets`, called by name). [weapons](docs/weapons.md#projectiles)
- At `mp_teammate_passthrough` 2 the projectile sweep keeps every team-mate out for the whole flight (dot-combat's cvar, bound by name). [weapons](docs/weapons.md#projectiles)
- `DotAchievementStatsLink`, never `recorded.connect`. [services](docs/services.md#progression)
- One chat path; hook `player_command` too; moderation is built first. [services](docs/services.md#chat)
- The speaker id comes from the transport, never the payload. [services](docs/services.md#voice)
- `admin_abilities` on every player, both ends. [services](docs/services.md#an-administrators-live-tools)
- One vote clock; voters keyed by bare session id. [services](docs/services.md#the-map-vote)
- A private match reports nothing (`reporting_allowed()`), and does not migrate. [services](docs/services.md#a-private-match-files-nothing)
