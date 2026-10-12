# Weapons: zee-dot-weapons in the arena

Every weapon a player carries is zee-dot-weapons'. `ArenaContent.weapons()` is `ZeeWeaponPack.weapons(damage_table())`. The damage table is the pack's types plus this game's `bullet` (the horde's gunner), `fall` and `world`, built once and handed to the pack and to dot-combat, so the launcher's splash and the registered `blast` are one object. `addons/zee_weapons` is linked. The CC0 art is vendored in `assets/`, because a delivered pack has to carry it, and the client points `ZeeModelCache.set_asset_root` at `ArenaPaths.root()` on `_ready` and back at `res://` on `_exit_tree`. View-model rules are in zee-dot-weapons' own [CLAUDE.md](../../zee-dot-weapons/CLAUDE.md).

## The rig drives the player's own arsenal

`ArenaPlayer._build_rig` hands a `ZeeWeaponRig` the existing `Arsenal` node by `arsenal_ref` rather than letting it build its own. A rig's role, which decides what it draws, is fixed at `setup()`, and a player is built before anybody knows whether it is the one at this keyboard. So the client rebuilds the rig as LOCAL when it adopts its player (`arm_first_person`, with a `ZeeViewModel` under the camera), and everything carried survives because it lives in the arsenal. Every reader of `player.arsenal` (HUD, netcode, mod tools, loadout) reads the same node. The old rig is freed with `free()`, not `queue_free()`: one alive until the end of the frame counts a reload twice.

- Simulation goes through `weapons.simulate_tick`, which runs the arsenal and then the bash.
- `used` is the rig's signal, so it carries the bash and is silent in a replay ([netcode](netcode.md#weapons-over-the-wire)).
- Somebody else's gun is a `ZeeWorldModel` on the hand `ArenaPlayer.attachment()` answers for (the person's own gun hand, `DotHumanoidFigure.attachment`; a capsule gets a fixed point), driven from the snapshot on a mirror and from the rig on anything this machine simulates, on one code path.
- The camera's half of the recoil is added in `present`, through `has_method`: `view_punch` and `shot_fx` are newer than some client shells' copy of zee-dot-weapons, and a call by name to a method the shell's copy lacks would not compile. On such a shell the game runs with no punch and with arena's own flash and report.

## Projectiles

`ArenaProjectiles` separates a fused spawn (bounces, rolls to rest, sticks if the definition says `sticks`, goes off on the fuse) from a contact one (the launcher). A grenade cooked past its fuse goes off at once. The thrower is ignored for eight ticks, because a grenade lobbed while running is overtaken by its own thrower. `ArenaProjectileView` draws the list; `ArenaPresentation.on_explosion` plays `scenes/fx/explosion.tscn` and a shake that falls off with distance. A resting grenade carries a red fuse light, because at range it is two brown pixels.

**A projectile passes through a team-mate who holds its launch point**, as a gun's shot does in dot-combat: `ArenaProjectiles` asks `DotCombatManager.pass_through_sets` for the launch point once, and the flight sweep leaves those bodies out for the thrower's grace and for as long as the projectile is still inside them. Team-mates do not collide, so two can stand in one place, and the sweep used to exclude only the thrower: every rocket from inside a friend went off in them at 0 m with its splash on the shooter, and a grenade bounced off them. The policy is dot-combat's (`DotDamageRules.pass_through_team_mate_at_muzzle`, `pass_through_fn`); an enemy holding the launch point is still hit at 0 m. Called by name, so a host whose dot-combat predates the method loads arena and keeps the old behaviour.

**The server's `mp_teammate_passthrough` reaches projectiles too.** It is dot-combat's cvar (`DotCombatManager.bind_cvars`, bound by name in `arena_module.gd`): 0 turns the launch-point rule off, 1 is the above, and 2 (`DotDamageRules.pass_through_team_mates`) makes `pass_through_sets` answer every team-mate, which `ArenaProjectiles` keeps out for the whole flight (`Flying.pass_all`) rather than dropping each once the projectile has left it. A rocket then flies past a friend in a corridor to the enemy behind them; its blast is not a sweep and still reaches team-mates under friendly fire.

**A detonation pins the attacker's believed origin to the blast** for that one resolution (`ArenaProjectiles.origin_of`) and puts it back. `DotCombatManager.resolve_shot` corrects any shot whose origin is more than `max_origin_error` from where it believes the attacker is (right for a gun) and re-traces; for a blast that put every explosion in its owner's face. Any check about explosives must ask the thrower's health too.

## Loadouts

- **A spawn hands over the heaviest gun** (`_better_hand`), not the highest slot, which is the throwable in the pack's layout.
- **Melee and the throwable are required slots.** dot-loadout's `default_loadout()` fills required slots only, so optional ones vanished a frame after every spawn. A loadout saved before they existed is filled in on load rather than refused.
