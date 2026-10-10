# Netcode

dot-net's own rules are in [dot-net's CLAUDE.md](../../dot-net/CLAUDE.md); this is what is specific to the arena's bridge.

## The bridge

`ArenaNetBridge` is the only file that names both `ArenaGame` and `DotNetManager`, and it is a file rather than a few lines because the ordering is the hard part. dot-net simulates per entity; this game's tick order is a whole-game property ([architecture](architecture.md#order-inside-a-tick)). Those meet in `ensure_game_ticked`: the first `_net_simulate` on a given tick drives the entire game and the rest find it done.

- **`Authority.SHARED`, not `SERVER`.** The server stays authoritative and corrects; the owning client predicts. `DotNetIdentity.is_predicted()` is false for any other authority, so `SERVER` would mean a player seeing their own movement a full round trip late.
- **The acknowledgement rides the input packet.** dot-net owns no client-to-server channel, so `encode_ack()` produces four fixed-width bytes in front of the bit-packed command: in front, because a bit-packed command is not fixed width and a reader that had to skip it would have to decode it first.
- **The server tick calls `ensure_game_ticked` again afterwards.** A server with no players registered runs no behaviours at all, and the match clock still has to advance.
- **`receive_snapshot` must not reconcile.** `DotNetManager.receive_snapshot` already routes a predicted entity's state to `DotNetPredictor.reconcile` and acknowledges the inputs it covers. A second pass on top replays the same inputs against already rewound values; the client still converges, and the only visible cost is `correction_rate()` near one half, which `DotNetPredictor` documents as "the two simulations disagree".

`ArenaPlayerNet` resolves `DotFpsNetSync` and `DotCombatNetSync`'s specs against `DotNetVar.Type`, which is why neither addon has to know dot-net exists. Ammunition is `to_owner_only()`: not a bandwidth saving, but because exact ammunition is information an opponent should not have, and data never sent cannot be read out of a modified client.

## One number, written once

`ArenaGame.NET_WORLD_EXTENT` and `NET_SNAPSHOT_RATE` are constants on the game because the module and the client both build a `DotNetConfig`, and a quantised position decoded against a different range is a different position, not a less precise one. Written separately (128 in one file, 256 in another) it looked like a client that connects, seals a byte-identical schema, adopts its player alive, and draws sky in every direction with no error anywhere. `headless_net._test_config_agreement` asserts the two ends agree on the extent, the tick rate and the schema hash.

The extent is 512 because the combat surf maps reach 312 m from the origin; at 128 every position on the far half of one was clamped to the quantiser's edge.

## The client predicts with the server's collision

The client uses `Mode.HEADLESS` collision, on a client with a screen. `HEADLESS` is `ArenaMap`'s analytic geometry, the same list of boxes the meshes come from, and it gives the same answer on a client replaying a tick as on the server that ran it. **A predicting client must use the same collision backend as the server it is predicting against.** Godot physics on the client is a second solver with its own contact epsilons, and reconciliation would correct a client that had done nothing wrong. (`Mode.PHYSICS` also wants a collision shape on the player node, and `ArenaPlayer` is a plain `Node3D`: the player fell through a floor that was drawn perfectly.)

An imported map gives every player a `DotFpsPhysicsBody` bound to the map's brushes, which both ends put in the tree alike, so the rule holds ([imported maps](imported-maps.md#the-solid-is-the-games-on-every-machine)).

## Drawing between ticks

`ArenaPlayer.present` uses `DotFpsController.render_state`, and `ArenaNetBridge._adopt_tick_rate` moves `Engine.physics_ticks_per_second` as well as the game's, the config's and the clock's. Either half alone measures as no better than nothing: the fraction a renderer interpolates at is a fraction through a physics frame, which is a fraction through a tick only while the two rates agree.

**The view and the eye are drawn once a frame, not once a tick** (2026-10-10). `ArenaPlayer.present` drew the state's yaw and pitch, which only a tick moves, and this game ticks 64 times a second: on a 144 Hz display more than half the frames run no tick (80 of every 144), and on each the view stood still while the mouse moved and turned double on the next frame. game-g2gfast measured it over a real socket at 128 ticks (96 of 864 frames still at 144 Hz, its `headless_feel`); here it is arithmetic, not measured over a socket. `ArenaClient._fold_look` calls `DotFpsSampler.look_now()` (dot-player-controller) every frame and present draws `ArenaPlayer.view_now`, the own-body yaw included; the commands do not change, since the sampler's angles are cumulative. And `ArenaClient._fold_correction` hands `DotNetPredictor.visual_offset` to `ArenaPlayer.drawn_offset`, which present adds to the eye: dot-net always computed what is left of a correction to ease, and nothing read it, so a correction moved the eye in one frame (30.4 cm in one frame for a 30 cm correction in g2gfast; eased, 4-5 cm at most). Both by name or by plain field, so a shell older than `look_now` draws as before. `headless_presentation`'s *A frame with no tick in it still turns the view* draws a frame with mouse motion and no tick (armed by drawing the state's angles and dropping the offset: two of three fail); `_fold_correction`'s plumbing needs a predicting client and is reached by g2gfast's twin, not by a suite here.

## Events and requests

`ArenaEvents.Kind` and the request kinds are indexes on the wire: **append, never insert or reorder.** After the original seven they run `VOTE`, `NPC`, `NPC_GONE`, `LAUNCH`, `RULES`, `DROP`, `TAKEN`, each appended in its turn.

- **No message script preloads itself.** `arena_event.gd` and `arena_request.gd` are built with `new(kind, body)`, with an `_init` whose arguments default because dot-net's registry decodes with a bare `new()`. A self-preload in a `DotNetMessage` script loaded by a module inside a running `DotServer` was measured in mg-buses-from-hell as leaking the whole script graph at exit. `dedicated`'s last section reads every message script under `game/` as text and fails on one, because the leak is printed after `quit()` where no assertion can reach.
- **The KILL event carries an optional trailing critical bit** (`ArenaEvents.write_kill(..., critical)`); an older server's kill reads as none.

## Rules a client predicts with travel in RULES

A rule set on the server alone is a client that mispredicts every slide. `ArenaGame.set_movement_rules` keeps the changed keys (`movement_rules`), applies them to every player now and on `add_player`, and emits `movement_rules_changed`; the bridge sends `Kind.RULES` to everybody, and to a joiner straight after HELLO and before any JOIN. `ArenaPlayer.apply_movement_rules` writes the class base too, or the next class change would put the old number back. The same event carries what a client draws (`ArenaGame.SHOW_RULES`: body breaking, the surf air control) and the mode's catalogue index (`mode_index`, [client](client.md#a-client-knows-the-mode-only-for-display)).

`headless_net`'s negative control for this is a fingerprint left apart by a server-only change, not a position gap: in this lockstep harness a snapshot corrects a wrong impulse within a tick or two. dot-player-controller's rewind used to keep the client's own launch cooldown and buttons; the timers and `previous_buttons` travel in `net_flags`.

## Weapons over the wire

- **The owner's arsenal is filled from `net_carry`** (one bit per weapon, owner-only, for the ammunition's reason) through `ArenaContent.apply_carry` before the predictor replays, and `correct_ammo` follows. A loadout is resolved from a store on the server; without this a connected client's arsenal was empty for the whole match. `net_weapon` (everybody's) says which weapon is in hand, which a slot number cannot once there are several primaries in one slot.
- **A replayed tick fires nothing.** dot-net's predictor calls `_net_simulate` for a replayed tick exactly as for a fresh one. `ArenaPlayerNet._predict` wraps any tick at or below the newest one simulated in `begin_replay` / `end_replay`, and the rig's `used` is silent in a replay, or every correction re-plays the sound, the flash and the kick.
- **Projectiles**: `Kind.LAUNCH` carries who, which weapon, from where, how fast and the fuse. A client flies a copy through the same `ArenaProjectiles` against the same analytic map from `client_tick`; its copy decides nothing because its combat manager is not the authority. A mirroring client swaps its combat trace on a map change, or its copies bounce off the old map.

## Monsters are server-authoritative mirrors

`ArenaNpcNet` replicates each monster with dot-npc's `DotNpcNetSync` fields: never predicted, because a monster's position comes out of a navigation graph and a brain no client could reproduce. A client interpolates and draws ([horde](horde.md)).

## Server bots

`ArenaNetBridge.add_bot` / `remove_bot` add a server-side `ArenaPlayer` with no peer, registered with owner 0 so every client mirrors it, announced with a JOIN and a LEAVE like anybody. `game/arena_bots.gd` writes what a bot presses into the same `last_move` / `last_fire` slot a client's input lands in inside `_commands()`, so the game ticks it exactly as a person: the nearest visible enemy (`combat.trace.line_of_sight`, side-aware in a team mode), aim error that settles over two seconds of a fight, a reaction delay, a fighting distance kept and strafed at, and a walk between spawns with nobody to fight. Deterministic per bot and tick.

How many is dot-server's `DotBotQuota` (`bot_quota` 4, `bot_quota_mode fill`, `bot_quota_empty 1`): `ArenaModule._keep_bots` corrects the count once a second, newest bot out first, so each person who joins takes a bot's place. `bot_quota_mode off` is a server with no bots. Needs dot-server API level 5 (`requires.json` is derived at packaging).

The offline client's bots (`_commands_for_tick`) are a different thing: a test fixture that aims at the nearest opponent through walls.

## Inputs and the clock under real loss

- **Every input packet carries this tick's command and the ones before it** (`ArenaNetBridge.INPUT_COPIES`, 5 in all), and `receive_input` skips copies already simulated so they do not count as late. With one copy, a lost packet is a tick the server runs on the previous command; with three, 20% loss still left the server short now and then while the player turned. Two more copies are a few bytes each. `inputs_from` (per peer, in `describe()`) tells one client's uplink from another's.
- **The clock's round trip is ENet's own** (`ArenaNetBridge.link_rtt_ms(link)`, by duck typing because a web build has no ENet class), falling back to `ping_ms`. The heartbeat's ping is -1 for its first seconds, and until it answers the input lead leaves out the flight time and commands arrive after their ticks.
- **Lag compensation**: each command carries the client's view lag (`ArenaNetCommand.view_lag_q`, quarter ticks, only with a button down). The server records every player's position per tick (`ArenaGame._unlag_record`, a ring of 128, restarted on a jump over 10 m in a tick) and dot-combat's `rewind_fn` stands every other living player where the shooter drew them for the trace, then puts them back. `arena_max_unlag_ms` (1000, so 300-400 ms players are compensated; 0 is off) is the limit.

`headless_lossy` is the suite for all of this ([testing](testing.md#headless_lossy-real-enet-through-real-loss)).

## Still open

- The other games' bridges send one command per input packet and feed the clock `ping_ms`; each wants `DotNetInput.write_batch` and its own `link_rtt_ms`.
- The input lead runs 2-4 ticks over what the transit needs (dot-net's clock has no jitter source on ENet).
- ~~About an eighth of frames extrapolate at 5-20% loss because the interpolation buffer adapts to jitter, not to loss.~~ dot-net sizes it from lateness since 2026-10-10 (its docs/timelines.md): `headless_lossy` measured 13-14% of B's frames extrapolated at 5% and 20% loss with the old interpolator and 0.3-2% with the new, the worst jump past B's own motion 0.05-0.06 m against 0.02-0.04, at the cost of the buffer: 8 ticks (125 ms) under loss where it was 5 (80 ms), 3.0 on the steady link where it was 2.5.
- Under heavy loss a run occasionally stalls reliable traffic or freezes a remote player for about a second; queued as `lossy-stalls-1`, and `./game.sh test headless_lossy` is the tool to chase it.
