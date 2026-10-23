# Modes, movement and the round

## Movement is a game's choice

`ArenaPlayer.arena_tunables()` is fast, floaty, high air control, and has no sprint. None of it is dot-player-controller's default; this is a deliberate departure. The air-acceleration and wish-speed-cap pair is the classic formula: it does nothing when you hold forward and everything when you turn while strafing. Health does not regenerate, because regeneration turns every fight into a question of who disengages first.

The slide and the launch are dot-player-controller's, turned on here; the dash is too but ships off (`arena_dash 1` turns it on). Shift is the dash when it is on, because this game has no sprint. Every movement cvar (`ArenaModule.MOVEMENT_CVARS`: `arena_slide*`, `arena_launch*`, `arena_dash*`) defaults to what the tunables already say, and changes travel to clients in RULES ([netcode](netcode.md#rules-a-client-predicts-with-travel-in-rules)).

**Walls: run a few steps along one, jump off it, ride it down.** dot-player-controller's wall run, wall jump and wall slide ([its wall-movement.md](../../dot-player-controller/docs/wall-movement.md)), on here, with its defaults but four: `wall_run_enabled`, `wall_jump_enabled`, `wall_slide_speed` 2.5 and `wall_run_min_speed` 9.5. **The run needs more than the 9 m/s plain run, measured along the wall**, so it is something a player does on purpose (a slide-jump, a dash or a strafe into the wall); at or under the run speed every jump taken beside a wall became a run and peaked about 40% lower than the player meant. The wall jump needs no speed, and the slide catches a fall against a wall and what a run decays into. The cvars are `arena_wall_run`, `arena_wall_jump`, `arena_wall_slide` (0 turns each off) and `arena_wall_run_min_speed`, `arena_wall_run_time`, `arena_wall_run_gravity`, `arena_wall_jump_push`, `arena_wall_jump_up`, `arena_wall_jumps`, and the finer ones `arena_wall_run_end_speed`, `arena_wall_run_damping`, `arena_wall_run_max_fall`, `arena_wall_run_angle`, `arena_wall_jump_look`, `arena_wall_jumps_per_wall`, all in RULES; `arena_wall_run_body_roll` and `arena_wall_run_body_yaw` (25 and 12 degrees) pose every drawn body on a wall, feet toward it, in third person and on other players (`ArenaPlayer._pose_body`; a body whose wall the client does not know stays upright, `wall_normal` not being replicated); with the three switches at 0 the motor moves byte for byte as before walls (`headless_match`). The camera leans away from the wall ([client](client.md#the-camera-is-written-in-exactly-one-place)); the places built for it are dm_atrium's north gallery ([maps](maps.md#dm_atrium)).

A combat surf map swaps in the surf genre's air control ([imported maps](imported-maps.md#the-surf-genres-air-control-on-these-maps)).

## Modes are data

`ArenaMode` is a `Resource`: an id, a `DotMatchRules`, a team count, what damage does, an objective layout id, a spawn mode, and a weapons group. Free-for-all and team deathmatch differ only in what is written in one, so adding a mode is writing a resource. `ArenaModes` is the catalogue, shaped like `ArenaMap.by_id` / `ids` so a console command or a `DotVoteListSource` can be handed `ids()` without knowing what a mode is. A mode that changes what happens on an event rather than what an event is worth needs code (a `DotMatchRules` subclass hung on the mode).

- **`team_count` and `rules.team_based` are two statements of one fact**, and `validate()` refuses a mode where they disagree. dot-match reads `team_based` to decide whether to assign sides at all.
- **The rules resource is duplicated before use.** Handing dot-match the catalogue's own object means a runtime score limit edits the mode every later match reads. The suite asserts two lookups are not the same object.
- **The team manager is built before `add_child(match_node)`**, because that runs `DotMatch._ready` and `setup`, which makes an untagged `standard_pair()` only when it finds none. Untagged teams draw from one spawn pool, which on a symmetric map spawns a side in the enemy base half the time. `DotTeam.spawn_tag` is what sends a side to its own end.
- **`combat.resolver.team_of` is the whole friendly-fire seam**, assigned after `add_child(combat)` because the resolver is built in `setup`. Unwired, `friendly_fire = false` protects nobody.
- **Whether there are sides is the mode's answer** (`is_team_mode()`), not dot-match's team manager, which exists in a free-for-all too.
- `ArenaMap.add_spawn(at, tag)` is the only way to append a spawn: `spawns` and `spawn_tags` are parallel arrays and the helper is the only reason they cannot disagree.

**The server's numbers sit over the mode's**: `ArenaGame.score_limit`, `time_limit_sec`, `warmup_sec` and `min_players`, set by `arena_scorelimit`, `arena_timelimit` (seconds), `arena_warmup` and `arena_minplayers`. Each cvar writes the export, which every match `_build_match` builds afterwards reads, and the running match through `ArenaGame.apply_match_limits` (dot-match reads its rules every tick), then sends MATCH so clients get the new limit and clock. Both halves are needed: a server's config is applied after the module loads, when the first match is already running, and every map change builds a new match from the mode. `arena_scorelimit` was registered with no handler and read by nothing until 2026-10-11, and `arena_minplayers` wrote only the live match, so it was back to the mode's 2 after the first map change. Zero (warmup: -1) gives the mode's own number back. Gun game ignores the score limit (below). `dedicated` checks all four through the console and across a map change.

**Everyone is frozen for the countdown before a round** (`mp_freezetime` seconds, `ArenaGame.freeze_sec`; -1 the mode's own 3, 0 none). dot-match's COUNTDOWN already places everybody and exposes `is_frozen`; `ArenaGame._sync_round_freeze` holds each living player (admin freeze modifier, arsenal off, invulnerable) from the tick it starts until LIVE and leaves an admin's own freeze or god mode alone. Client and server both run it from the match state. A test that needs players to move right after `change_map` sets `freeze_sec = 0`, because a new match brings the mode's countdown back.

`arena_mode` is the cvar. It goes through `change_map`, the only re-entrant path, and `_reconcile_world_layers` builds what the new mode needs (objectives, the horde, props) and takes away what it does not; each layer is built once and left alone, because a rebuilt layer's connections have to be remade. A refused mode puts the cvar back, guarded against its own `changed` signal.

### Gun game and weapon pools

`ArenaMode`'s weapons group: `weapon_pool` (zee ids, or `tag:<tag>`), `pool_random`, `pool_keeps_melee`, `gun_game` (the weapons in order). `ArenaGame.arm_for_mode` runs after a loadout is applied, in both of `apply_loadout`'s branches since it awaits a store, and replaces what the loadout gave; a gun-game kill re-arms the killer after `report_kill`. **Gun game's level is the player's match score and its score limit is the list's length**, so advancing and winning are the scoreboard rather than a second counter, and `validate()` refuses a gun game whose two numbers differ. `arena_scorelimit` does not apply to it: it used to, so a gun game on the default 25 went on for ten knife kills past the last gun. A melee kill takes a point off the victim (`gun_game_melee_demotes`, never below the first gun). Shipped: `gungame` and `snipers` (`tag:scoped`, random per spawn); a one-weapon-class server is a copy with a different pool.

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

`arena_spawn_mode` (or `ArenaMode.spawn_mode`): `avoid` (the default: dot-spawn's SAFEST, never nearer an enemy than `arena_spawn_min_enemy`, 10 m, when anywhere else will do), `weighted`, `furthest`, or `random`. `arena_spawn_sight_penalty` is what a site an enemy can see costs, judged eye to head through the map's own trace (`combat.trace`, as shots are; `_can_see_site`), because a dedicated server and every headless game have no built-in map in the physics space: asked there, every site was seen, the penalty charged them all alike, and the first play test respawned in view of his killer. Props are not cover a spawn counts on; `arena_spawn_enemy_weight` what each metre is worth. The enemy list is side-aware in a team mode and everybody in a free-for-all; the spawning player is never their own enemy. `ArenaPlayerStack._adopt_match_sides` re-reads dot-match's assignment on every map change and asks the mode, so a team mode's sides do not survive into a free-for-all, and sites carry the side of the team whose `spawn_tag` claims them.

The collision layout is worn: the level is classified `world`, props `prop`, and `DotFpsTunables.collision_mask` comes from the layout. An `ArenaPlayer` is a `Node3D` with no collider and is deliberately not classified: its movement is a shape query.

A class's loadout is the arsenal's source: `DotWeaponPlayerBridge.give_class_loadout` reads `DotPlayerClassDef.loadout_id` and looks it up in `ArenaPlayerStack.LOADOUT_WEAPONS`, the game's table, because dot-weapon does not own the id space between a loadout and a weapon.

## Spectating

`ArenaSpectate` moves a dead player's camera off the floor, and the server decides who may watch whom through dot-spectate's `mp_forcecamera` (default 0, anybody; 1 is own team only and also switches roaming off), and `mp_freeroam` / `mp_freeroam_speed` (free roam is on by default). The rules are `ArenaGame.spectate_rules`, bound by the module (REPLICATED) and followed by the client. The camera is driven once a frame, because a camera moved on the tick timeline steps at the tick rate however smooth the target is.

On a networked client the layer is built by `_build_spectate`, fed the KILL event (`ArenaSpectate.on_kill_event`) and ticked from `client_tick`; a respawn is read off the replicated health. **Free roam** (T, `ArenaBindings.ROAM`) is local to the client, for the same reason: `ArenaClient.toggle_roam` asks the client's manager (refused with a line when `mp_freeroam 0` or `mp_forcecamera` is set), and `_fly_free_camera` feeds the move keys, Dash (fast), Walk (slow) and the mouse into a `DotSpectatorFreeCam` once a frame while the dead body's command is zeroed. The spectator HUD shows the key as the prompt line (`ArenaHud.roam_hint`). The client's manager is authoritative over its own camera: this server sends no spectator views and a dot-spectate mirror runs no timers.

## Criticals and bodies

A critical is dot-combat's judgement (`DotDamage.critical`, a headshot by default; `arena_crit_chance` and `arena_crit_scale`). On a client a kill whose rules say so breaks the victim's body (`ArenaPlayer.break_body` over dot-player-char's `DotPlayerBodyBreak`), **seeded from victim and killer ids, not the tick**, which each client receives at its own. `_mend_body` restores it on respawn. `arena_break`, `arena_break_limbs` and `arena_break_criticals` travel in RULES because a client draws them.

**Then what is left falls.** `ArenaGame.decide_death` runs on the server for every player death: dot-player-char's `DotPlayerDeath.decide` over the server's `sv_ragdoll_reactions` weights, the shot's direction (or killer to victim), the damage, a seed from the victim and the tick, and the killing weapon's def, which is how zee's sniper and launcher always throw the body (`params.death_reaction`) and its shotguns, mallet and charge rifle may (`params.death_power`). The decision rides the KILL event after `critical`, optional, about seven bytes (`ArenaEvents.write_kill`), and every client calls `ArenaPlayer.fall_body`, which builds a ragdoll in `ArenaClient.ragdolls` from the figure it draws and hides the figure until `_mend_body` on respawn. Solo has no KILL: the death is on the kill feed entry (`_on_solo_kill`). The `sv_ragdoll*` cvars are bound by the module, REPLICATED, and followed by the client through its link (`follow_server_cvars`), because the client draws the bodies; the ragdolls land on the `world` and `prop` layers of the level the client draws. Sounds are dot-player-char's (`DotPlayerDeathSounds`), in the presentation catalogue. See dot-player-char's [docs/ragdolls.md](../../dot-player-char/docs/ragdolls.md).

## Coins out of a body

A lethal critical drops coins and a health pack. `ArenaDrops` is one `Node3D` on both ends. On the authority it holds one-shot `DotPickup`s in a `DotPickupField`, swept each tick after the player stack and before the match; only a hurt player takes a pack (`wants_fn`). On a client it holds drawn copies: DROP bursts one out of the body, TAKEN flies it to its taker. A client never takes its own pickups, and its coin tally is counted from TAKEN. The rules live on `ArenaGame.drop_rules` so a map change keeps them (`arena_drop_*`); the scatter is seeded from the victim and the tick.

The maps dm_box, dm_atrium and dm_pit also carry health and ammo packs (`ArenaMap.packs`), placed as `DotPickup`s in the same field and respawning after `arena_pack_respawn` seconds (20). `arena_packs 0` removes them, `arena_pack_health` is the heal (50) and `arena_pack_ammo` the percent of each weapon's reserve cap an ammo pack refills (50); a pack is taken only by someone who needs it. A joiner is told the packs that are out at signon, and a respawn is announced with a DROP.

An imported surf map with a jail (found by shape: a volume whose destination is outside every volume and that other pits aim into, see [imported maps](imported-maps.md#the-jail)) is played as one while `arena_jail` is 1: a fall lands in the cell, the button opens the gate for `arena_jail_open` seconds (32) and then locks for `arena_jail_cooldown` (64).

**A pickup is taken out of the field as it goes, not at the end of the frame**: a server runs several ticks a frame, and a freed pickup still in the list is swept as a freed object (script errors, every check still passing).

## Kill streaks

Counted on the server for rewards (`ArenaGame.streaks`). The meter reads the killer's streak from the server's AWARD and ends a victim's on their KILL (`ArenaHud.streaks`); a shutdown is judged on the streak the victim died with, before it is reset ([client](client.md#kill-feedback)). `arena_streak_rewards` is `streak:reward` pairs (`heal`, `armour`, `haste`, `empowered`), default `3:heal,5:haste,7:empowered`.

## The end of a match

Every client opens the scoreboard and names the MVP on the notice line (best score, then kills, deaths, assists), from its own MATCH handler on the transition into `MATCH_END`.

## Loadouts and the owner's rules

Players choose their loadout on B by default (Christian's first play test); the owner can restrict or lock it with dot-loadout's three cvars, bound by `ArenaModule` through `ArenaGame.loadout_command` (`DotLoadoutCommand`) and enforced by the server's `DotLoadoutManager.publish`, whatever a client's screen showed:

- `mp_loadout_menu 0`: nobody chooses; everybody spawns with the schema's defaults and the fixed slots.
- `mp_loadout_allow "primary=tag:scoped"`: snipers only (any scoped primary: the marksman rifle, the sniper, the bullpup), everything else as usual. Patterns are item ids or `tag:<tag>`, `-` forbids, `*` is every slot: `"*=-tag:explosive"` is no launchers or grenades.
- `mp_loadout_fixed "primary=sniper thrown=none"`: slots the server fills for everybody.

The slots are `primary` (rifles and the heavies), `secondary`, `melee`, `thrown` and `gear` (armour), on a 7-point budget (`ArenaContent.loadout_schema`). A value naming a slot or item that does not exist, or that leaves a required slot nothing, is refused at the console and the rules stay. A server sets them in `cfg/content.yml` under the game's `cvars:` (see `game.yml`). A mode that hands out the weapons (`ArenaMode.arms_players`: gun game, Only Snipers) overrides the loadout and closes the menu with that reason; that is the mode, the cvars are the owner's whatever the mode. The give order is `ArenaContent.in_give_order` (melee, primary, sidearm, throwable, gear), not the menu's slot order: the arsenal's order is what a bot's weapon choice walks, and changing it moved `headless_bots`' measurements.
