# Architecture: the joins, the id space and the tick

## Why this project exists

Every addon passes its own suite, and every one of those suites runs one addon with the others absent. A code path only one deployment shape reaches is a code path nothing has run. game-arena is the shape where most of the family is present at once: it is a game, and it is also the only test of the joins between the addons.

```
the fight        dot-player-controller  dot-combat  dot-weapon  dot-loadout  dot-match
                 zee-dot-weapons (the weapons, and everything about them anybody sees)
what you keep    dot-stats  dot-achievements  dot-leaderboard
the world        dot-map  dot-props  dot-npc  dot-npc-ai  dot-npc-ai-director  dot-entity
what plays next  dot-vote
who you are      dot-auth  dot-user  dot-user-avatar  dot-platform  dot-cloud
the server       dot-server  dot-net  dot-chat  dot-voice  dot-moderation
                 dot-browser (its query half)  dot-server-query
the round        dot-objective  dot-effects  dot-spectate  dot-spawn  dot-team
the screen       dot-ui  dot-menu (the Tab board only)  dot-settings  dot-audio  dot-fx  dot-console
everything       dot-core
```

The full list of links is the `/addons/...` lines in `.gitignore`, which is what dot-bootstrap and dot-ci read.

## The seams

Every join between two addons is a few lines, and each is a few lines because the addons refuse to know about each other.

| Join | What it is |
| --- | --- |
| loadout → combat | `ArenaPlayer.give_loadout`, item ids that are the pack's weapon ids |
| weapons → player | `ArenaPlayer._build_rig`, a `ZeeWeaponRig` handed the player's own arsenal by `arsenal_ref` |
| weapons → wire | `ArenaPlayerNet`: `ZeeWeaponNet.all_specs()`, `net_weapon` for everybody, `net_carry` for the owner |
| projectiles → clients | `ArenaProjectiles.launched` → `ArenaEvents.Kind.LAUNCH` → a copy flown by `client_tick` |
| combat → match | `ArenaGame._on_entity_killed`, `entity_killed` → `report_kill` |
| match → loadout | `ArenaGame._on_respawn_due` → `_apply_loadout_deferred` |
| movement → combat | `arsenal.movement/airborne/crouched` pushed from `DotFpsState` |
| match → ui | `ArenaHud._on_kill`, a `DotKillFeed.Entry` → coloured fragments |
| game → server | `ArenaModule` and `ArenaServices`, the two files that name dot-server |
| combat → stats | `ArenaProgress._on_shot_resolved` / `_on_killed` |
| stats → achievements | `DotAchievementStatsLink`, which differences rather than connecting ([services](services.md#progression)) |
| stats → leaderboard | `ArenaBoards.submit_session`, once per session rather than per kill |
| map → game | `ArenaMapSession.change_to_map` → `ArenaGame.change_map` |
| map → clients | `DotMapSyncHost.send_fn` → `ArenaNetLink.send_map` |
| vote → map | `ArenaVoteSource.apply`, routed on a `map:` / `mode:` prefix |
| match → vote | `ArenaVote.leading_score` polled each tick; dot-match's `round_ended` → `note_round_end` |
| vote → clients | `ArenaVote.cue_due` → `ArenaEvents.Kind.VOTE` → `ArenaPresentation.on_vote_cue` and the HUD's notice line |
| vote → console | `ArenaVote.install_commands`, dot-vote's `DotVoteCommands` on the module |
| npc → combat | `ArenaHorde._register_combat`, hitboxes and health under one entity id |
| npc → game | the brain reaches `ArenaHorde` through `DotRegistry`, never by name |
| chat → server | `ArenaServices._on_player_chat`, which cancels dot-server's own |
| voice → wire | `ArenaNetLink.send_voice`, on a channel of its own |
| moderation → everything | two registry names nobody imports: `dot_mute_source`, `dot_ban_source` |
| moderation → the world | `ArenaModTools.handlers`, one callable per admin ability; `DotModToolCommands` on the module |

Three small decisions in those joins:

- `_on_entity_killed` passes `""` for a world death rather than `"0"`. dot-match reads an empty killer key as "the world"; `"0"` would create a scoreboard record for a player who does not exist.
- `_apply_loadout_deferred` does not await inside the respawn handler. A loadout comes from a store, which may be slow; a respawn may not be. The player is in the world with what they had and the loadout arrives a frame later.
- `apply_loadout` falls back to the default on any failure. An unreachable loadout store is a reason to give somebody a rifle, not a reason to leave them watching.

## One id space for players

`ArenaPlayer.player_id` is the scoreboard key, the combat entity id, the damage attribution and the loadout key, and dot-server's `session.userid` feeds it.

- **Use the session id, never the peer id.** A peer id is reassigned the moment somebody reconnects, and everything downstream would be handed to the next player to join. `ArenaModule._add` says so at the point it matters.
- The loadout key is `"arena-player-%08d"`, not `str(id)`. `DotLoadoutKey.is_usable` has a minimum length so a malformed key can never reach a filesystem path, and a bare `"7"` is refused. Padding is right; loosening the check is not.
- Monsters are in a different id space, allocated by `DotEntityTable` ([horde](horde.md#a-monsters-entity-id)). The player half is deliberately not converted; the reason is there.
- Server bots are players with session ids from `ArenaNetBridge.BOT_SESSION_BASE` (900,000,000 + n), above any userid and below the entity table's ids ([netcode](netcode.md#bots)).

## Order inside a tick

`ArenaGame.tick()` and `ArenaPlayer.simulate_tick()` both have an order that is not arbitrary:

1. **Movement, then the shot.** Half a tick of movement at arena speeds is fifteen centimetres, which at range is a miss.
2. **Spread inputs are pushed from the simulated state**, never read from a rendered one. An interpolated position differs between client and server by design.
3. **Aim comes from the movement command**, not a second sample. Sampling the mouse twice gives a shot that leaves at a different angle than the player was looking along.
4. **All shots are resolved after everyone has moved**, so a shot is traced against the world as it ends the tick.
5. **Map hurt volumes, then the match.** `_hurt_from_map` runs after the shots; the match ticks last, so a kill scored this tick can end the round this tick.

Inside a player's tick, the map's own mechanics run after the controller's move and before the pits ([imported maps](imported-maps.md#the-maps-own-mechanics)), and drops are swept after the player stack and before the match ([modes](modes.md#coins-out-of-a-body)).

## Nobody is harmed behind a loading cover

A client behind its `DotLoadGate` cover froze itself and cannot see. `ArenaModule` is not on `DotGameModule`, so it borrows dot-game's `DotGameRoster` for the bookkeeping alone (`ArenaModule.loading`): a seat is loading from the spawn event until the client's `game.cover` report says the cover lifted, and again from every map change (`mark_reloading`). `ArenaGame.loading_fn` asks it by player id, and `ArenaEffects.adjust_damage`, the one hook every damage path runs through (weapons, monsters, map hurt volumes, falls), refuses a hit on a loading seat, after the administrator's slay, which is never vetoed. Nobody dies behind a cover, so no round loses a player who never saw it begin. Bots and offline play have no `loading_fn` and are never loading. `headless_lossy` checks it over a real socket.

## One description, three representations

`ArenaMap` holds a list of `AABB`s. `to_scene()` makes meshes and static bodies, `to_fps_body()` makes a `DotFpsFlatBody`, `to_trace()` makes a `DotTraceFlat`. Building those independently is the obvious approach and it is wrong in a way nothing reports: the server's idea of a wall moves a metre and shots start passing through something clients can see. The self-test asserts all three have the same box count and that a shot at the perimeter stops at it.

It is also why a dev-textured game is easy to reason about: the geometry is the gameplay, and there is no separate art pass that could disagree with it. The texture is Kenney's prototype grid tinted per zone ([maps](maps.md#colour-and-light)) and triplanar-mapped, because a `BoxMesh` UV-maps every face to the same 0..1 square; without triplanar a two-metre box and a forty-metre wall show the same number of grid squares and the texture stops telling you about scale, which is its only job.

An imported combat surf map has no box list and is the one exception; it keeps the same rule by other means ([imported maps](imported-maps.md#the-solid-is-the-games-on-every-machine)).

## Where it runs

`game.yml` (`content_id: gamemann/game-arena`, `kind: pack`) is the descriptor that travels in the signed dot-cloud pack: `scenes/arena_server.tscn` on the server, `game/arena.tscn` on the client, `game/arena_module.gd` as the module. dot-server-deploy publishes it and runs it as one of its demo servers (`demo.sh`, server 5, at 64 ticks). Because it is delivered as a pack, nothing here declares a `class_name` ([family rule](../../../CLAUDE.md)): scripts preload each other by relative path and `res://` strings go through `ArenaPaths.rebase`.

## Where the code is

Everything is flat under `game/` and `maps/`, grouped here by what it is for.

| Path | What |
| --- | --- |
| `game/arena_game.gd`, `arena_player.gd`, `arena_player_stack.gd` | the simulation: the game and its tick, the player (movement, weapons, health, hitboxes), the roster and spawning |
| `game/arena_mode.gd`, `arena_modes.gd`, `arena_objectives.gd`, `arena_effects.gd`, `arena_spectate.gd`, `arena_drops.gd` | modes as data and the round's layers |
| `game/arena_horde.gd`, `arena_npcs.gd`, `arena_npc_brain.gd`, `arena_props.gd`, `arena_projectiles.gd`, `arena_content.gd` | monsters, props, projectiles, weapons and the damage table |
| `game/arena_module.gd`, `arena_services.gd`, `arena_mod_tools.gd`, `arena_vote*.gd`, `arena_map_director.gd`, `arena_map_session.gd`, `arena_maps.gd`, `arena_bots.gd`, `arena_server.gd` | the server: the dot-server module and its cvars, chat/voice/moderation, admin tools, the vote, maps, bots |
| `game/arena_net_*.gd`, `arena_player_net.gd`, `arena_npc_net.gd`, `arena_events.gd`, `arena_event.gd`, `arena_request.gd` | the dot-net bridge, link, commands, per-entity net state, events and requests |
| `game/arena_client.gd`, `arena_client_extras.gd`, `arena_hud.gd`, `arena_menus.gd`, `arena_bindings.gd`, `arena_hud_glance.gd`, `arena_presentation.gd`, `arena_browser.gd`, `arena_party.gd`, `arena_avatars.gd`, `arena_projectile_view.gd`, `arena.tscn` | the client: never loaded by a dedicated server |
| `game/arena_stats.gd`, `arena_awards.gd`, `arena_boards.gd`, `arena_progress.gd`, `arena_identity.gd` | progression and identity |
| `game/arena_paths.gd` | `rebase` for every `res://` path (pack delivery) |
| `maps/arena_map.gd`, `arena_map_survey.gd`, `arena_map_paint.gd`, `arena_map_lighting.gd` | the built-in maps as box lists, the survey, their colours, their lighting |
| `maps/arena_bsp_map.gd`, `arena_imported_maps.gd`, `arena_map_mechanics.gd`, `arena_ladder_mode.gd`, `*.gdshader` | the combat surf maps (copies of g2gfast's loader); `maps/imported` is the arena-surf-dm-maps link |
