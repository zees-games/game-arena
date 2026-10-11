# Modes, movement and the round

## Movement is a game's choice

`ArenaPlayer.arena_tunables()` is fast, floaty, high air control, and has no sprint. None of it is dot-player-controller's default; this is a deliberate departure. The air-acceleration and wish-speed-cap pair is the classic formula: it does nothing when you hold forward and everything when you turn while strafing. Health does not regenerate, because regeneration turns every fight into a question of who disengages first.

The slide, the launch and the dash are dot-player-controller's, turned on here. Shift is free for the dash because this game has no sprint. Every movement cvar (`ArenaModule.MOVEMENT_CVARS`: `arena_slide*`, `arena_launch*`, `arena_dash*`) defaults to what the tunables already say, and changes travel to clients in RULES ([netcode](netcode.md#rules-a-client-predicts-with-travel-in-rules)).

A combat surf map swaps in the surf genre's air control ([imported maps](imported-maps.md#the-surf-genres-air-control-on-these-maps)).

## Modes are data

`ArenaMode` is a `Resource`: an id, a `DotMatchRules`, a team count, what damage does, an objective layout id, a spawn mode, and a weapons group. Free-for-all and team deathmatch differ only in what is written in one, so adding a mode is writing a resource. `ArenaModes` is the catalogue, shaped like `ArenaMap.by_id` / `ids` so a console command or a `DotVoteListSource` can be handed `ids()` without knowing what a mode is. A mode that changes what happens on an event rather than what an event is worth needs code (a `DotMatchRules` subclass hung on the mode).

- **`team_count` and `rules.team_based` are two statements of one fact**, and `validate()` refuses a mode where they disagree. dot-match reads `team_based` to decide whether to assign sides at all.
- **The rules resource is duplicated before use.** Handing dot-match the catalogue's own object means a runtime score limit edits the mode every later match reads. The suite asserts two lookups are not the same object.
- **The team manager is built before `add_child(match_node)`**, because that runs `DotMatch._ready` and `setup`, which makes an untagged `standard_pair()` only when it finds none. Untagged teams draw from one spawn pool, which on a symmetric map spawns a side in the enemy base half the time. `DotTeam.spawn_tag` is what sends a side to its own end.
- **`combat.resolver.team_of` is the whole friendly-fire seam**, assigned after `add_child(combat)` because the resolver is built in `setup`. Unwired, `friendly_fire = false` protects nobody.
- **Whether there are sides is the mode's answer** (`is_team_mode()`), not dot-match's team manager, which exists in a free-for-all too.
- `ArenaMap.add_spawn(at, tag)` is the only way to append a spawn: `spawns` and `spawn_tags` are parallel arrays and the helper is the only reason they cannot disagree.

`arena_mode` is the cvar. It goes through `change_map`, the only re-entrant path, and `_reconcile_world_layers` builds what the new mode needs (objectives, the horde, props) and takes away what it does not; each layer is built once and left alone, because a rebuilt layer's connections have to be remade. A refused mode puts the cvar back, guarded against its own `changed` signal.

### Gun game and weapon pools

`ArenaMode`'s weapons group: `weapon_pool` (zee ids, or `tag:<tag>`), `pool_random`, `pool_keeps_melee`, `gun_game` (the weapons in order). `ArenaGame.arm_for_mode` runs after a loadout is applied, in both of `apply_loadout`'s branches since it awaits a store, and replaces what the loadout gave; a gun-game kill re-arms the killer after `report_kill`. **Gun game's level is the player's match score and its score limit is the list's length**, so advancing and winning are the scoreboard rather than a second counter, and `validate()` refuses a gun game whose two numbers differ. A melee kill takes a point off the victim (`gun_game_melee_demotes`, never below the first gun). Shipped: `gungame` and `snipers` (`tag:scoped`, random per spawn); a one-weapon-class server is a copy with a different pool.

## Objectives

`koth` and `ctf` are scored on more than kills: a capture curve where the second player is worth half a player, a block that pauses rather than undoes, decay, and a hill clock that freezes rather than resets when the point changes hands. dot-objective has all of that and this game none.

The layout comes from the map's own numbers: `ArenaObjectives.build` puts the flags at the ends of the longest axis and the hill at the centre, so a later map gets a working layout for free. That is also why `ArenaMode.objective_layout` is an id rather than a list of positions.

## Effects

`ArenaEffects` assigns dot-combat's `resolver.adjust`, the extension point for a mode's own arithmetic: crits and resistances meet the damage after friendly fire and falloff and before the clamp. It owns no health; dot-effects reports an amount and this applies it through `DotHealth`, so afterburn goes through the same armour, rules and kill feed as a rifle round. **`ArenaEffects` rebinds on `map_changed`**: `change_map` builds a new combat manager and resolver, and the hook left on the old one silently stopped scaling every hit.

## Spawn protection

One duration, `DotMatchRules.spawn_protection_sec`, read by all three records: the `DotHealth` window, the `PROTECTED` effect, and dot-spawn's ledger (granted by `DotSpawnDirector.choose`, which `_on_respawn_due` asks; dot-match's points are still the source, copied in by `refresh_spawns`). `ArenaPlayerStack.blocks_damage` is consulted from `ArenaEffects.adjust_damage`. `ArenaEffects.on_spawn` is called from the respawn.

- **Spawn protection is an effect rather than `DotHealth.invulnerable`** because of `no_capture`: an untouchable player on a control point is not a fight.
- **`protection_breaks_on_attack` is off** because only the ledger can be revoked; the other two records have no "somebody shot" input, and revoking one of three is worse than either answer.
- **An admin's slay passes through** (`ArenaEffects.ADMIN_KILL` in the damage context), or slay is refused for the first second and a half of every life, which is the spawn camper slay is for.

## Spawning

`arena_spawn_mode` (or `ArenaMode.spawn_mode`): `avoid` (the default: dot-spawn's SAFEST, never nearer an enemy than `arena_spawn_min_enemy`, 10 m, when anywhere else will do), `weighted`, `furthest`, or `random`. `arena_spawn_sight_penalty` is what a site an enemy can see costs (dot-physics' `line_of_sight_3d`); `arena_spawn_enemy_weight` what each metre is worth. The enemy list is side-aware in a team mode and everybody in a free-for-all; the spawning player is never their own enemy. `ArenaPlayerStack._adopt_match_sides` re-reads dot-match's assignment on every map change and asks the mode, so a team mode's sides do not survive into a free-for-all, and sites carry the side of the team whose `spawn_tag` claims them.

The collision layout is worn: the level is classified `world`, props `prop`, and `DotFpsTunables.collision_mask` comes from the layout. An `ArenaPlayer` is a `Node3D` with no collider and is deliberately not classified: its movement is a shape query.

A class's loadout is the arsenal's source: `DotWeaponPlayerBridge.give_class_loadout` reads `DotPlayerClassDef.loadout_id` and looks it up in `ArenaPlayerStack.LOADOUT_WEAPONS`, the game's table, because dot-weapon does not own the id space between a loadout and a weapon.

## Spectating

`ArenaSpectate` moves a dead player's camera off the floor, and the server decides who may watch whom: a team mode gets `force_camera 1`, a free-for-all `0`. The camera is driven once a frame, because a camera moved on the tick timeline steps at the tick rate however smooth the target is.

On a networked client the layer is built by `_build_spectate`, fed the KILL event (`ArenaSpectate.on_kill_event`) and ticked from `client_tick`; a respawn is read off the replicated health. The client's manager is authoritative over its own camera: this server sends no spectator views and a dot-spectate mirror runs no timers.

## Criticals and bodies

A critical is dot-combat's judgement (`DotDamage.critical`, a headshot by default; `arena_crit_chance` and `arena_crit_scale`). On a client a kill whose rules say so breaks the victim's body (`ArenaPlayer.break_body` over dot-player-char's `DotPlayerBodyBreak`), **seeded from victim and killer ids, not the tick**, which each client receives at its own. `_mend_body` restores it on respawn. `arena_break`, `arena_break_limbs` and `arena_break_criticals` travel in RULES because a client draws them.

## Coins out of a body

A lethal critical drops coins and a health pack. `ArenaDrops` is one `Node3D` on both ends. On the authority it holds one-shot `DotPickup`s in a `DotPickupField`, swept each tick after the player stack and before the match; only a hurt player takes a pack (`wants_fn`). On a client it holds drawn copies: DROP bursts one out of the body, TAKEN flies it to its taker. A client never takes its own pickups, and its coin tally is counted from TAKEN. The rules live on `ArenaGame.drop_rules` so a map change keeps them (`arena_drop_*`); the scatter is seeded from the victim and the tick.

**A pickup is taken out of the field as it goes, not at the end of the frame**: a server runs several ticks a frame, and a freed pickup still in the list is swept as a freed object (script errors, every check still passing).

## Kill streaks

Counted on the server for rewards (`ArenaGame.streaks`). The meter reads the killer's streak from the server's AWARD and ends a victim's on their KILL (`ArenaHud.streaks`); a shutdown is judged on the streak the victim died with, before it is reset ([client](client.md#kill-feedback)). `arena_streak_rewards` is `streak:reward` pairs (`heal`, `armour`, `haste`, `empowered`), default `3:heal,5:haste,7:empowered`.

## The end of a match

Every client opens the scoreboard and names the MVP on the notice line (best score, then kills, deaths, assists), from its own MATCH handler on the transition into `MATCH_END`.
