# Source's server tick against Fatal Contact's, technique by technique

A CS:S server with 31 bots runs a 66 Hz tick in about 1.4 ms. FC's sim host needs about 12 ms for the same 32 players. This file goes through the server techniques Source uses and maps each to FC. For each one it gives FC's current equivalent, what it could save, and the risk to hit reg and lag compensation.

[perf-vs-css.md](perf-vs-css.md) already compares the per-player game code: movement, bots, bones and the client. This file covers the network and tick-loop side, and only repeats that file's numbers where a technique needs them.

## Inputs

- **Owner's vprof** (`perf-logs/external/cstrike/vprof_report_32bots.log`): a CS:S listen server with one person and 31 bots on de_dust2 at 66 tick, 4404 server frames.
  - `_Host_RunFrame_Server`: 1.395 ms per call.
  - `CBotManager::StartFrame`: 0.664 ms per call.
  - `NET_ProcessSocket`: 0.064 ms per call (2 calls per tick).
  - `SV_ComputeClientPacks`: 0.042 ms per call. It has two vprof scopes per snapshot (CheckTransmit and the packing), and 3929 snapshots were sent in 4404 ticks.
  - `CBaseServer::WriteDeltaEntities`: 0.012 ms per call.
  - `CPhysicsHook::FrameUpdatePostEntityThink`: 0.102 ms.
  - Server `CBaseAnimating::SetupBones`: 8 per tick, 21 µs each.
- **Owner's net_graph video** (`cstrike_win64_XBkh1cPlfS.mp4`, frames read with ffmpeg at 10, 40, 80, 120 and 150 s): the server line shows 452-1181 server fps and 0.7-1.9 ms per server frame on de_dust2.
- **Source code**, read-only, from `source-engine`:
  - `engine/sv_main.cpp`: `SV_CreateClientSnapshots` / `SV_SendClientMessages`, lines 1860-1915;
  - `engine/sv_packedentities.cpp`: `SV_PackEntity`, `PackEntities_Normal`, `SV_ComputeClientPacks`;
  - `engine/baseclient.cpp`: `ShouldSendMessages`;
  - `game/shared/cstrike/bot/bot_manager.cpp`: `CBotManager::StartFrame`.
- **FC's figures** come from staging02, windowed, sim host, cp-orange-x3, 32 players:
  - the SIM_HOST line: sim 11.8-12.5 ms per tick, send 0.73-0.77;
  - `--sim_sections 2` (bench logs 20261113-130207 and later);
  - the dot-net split on nightly `simhost-net-dispatch-1`: `srv_net` 12.47 = n_sim 11.76 + n_send 0.65 + input about 0.05. Inside n_sim, `net_pull` is 0.56 and the dispatch residual is 0.14.

## Where the 10x is

The CS:S server frame is 1.4 ms: about 0.66 ms of bots, about 0.6 ms of player commands and game code, and about 0.13 ms of networking. The networking is packing, the delta write and the socket.

FC's 12 ms per tick splits like this:

| Part | FC ms per tick | CS:S ms per tick | Who owns the gap |
| --- | --- | --- | --- |
| Game tick (`srv_game`: players, weapons, world) | 7.9-9.6 (`p_controller` alone 3.1) | about 0.6 | GDScript against C++: perf-vs-css.md rows 2 and 4 |
| Bots (`srv_bots`) | 2.7-3.3 | 0.66 | addons; `simhost-bot-native-glue-1` |
| Copying sim state into replicated fields (`net_pull`) | 0.56-1.7 | 0 (props are read at pack time) | in flight: bot pulls only on snapshot ticks (worktree `arena-simnet`) |
| Kill view eyes | 0.45 | none | in flight: eyes only on ring-due ticks (`arena-simnet`) |
| dot-net dispatch and input | about 0.2 | inside `NET_ProcessSocket` 0.064 x 2 | dot-net; measured below the gate |
| Snapshot build and send | 0.65-0.77 | about 0.09 | dot-net; see technique 1 |

The network-side techniques explain about 1.5-2.5 ms of the roughly 10.5 ms gap. The other 8-9 ms is the same work done in GDScript instead of C++, which perf-vs-css.md already covers.

## Technique by technique

"Saves" is per 66 Hz tick at 32 players (31 bots and one person) on staging02. "Risk" is risk to hit reg, lag compensation and the authoritative sim.

### 1. SV_ComputeClientPacks: pack once, share across clients

- **Source.**
  - `SV_CreateClientSnapshots` packs only when at least one client's `ShouldSendMessages()` is due, which is at its `cl_updaterate`.
  - Fake clients (bots) are skipped outright (`sv_main.cpp:1878`): bots never cost a pack or a send.
  - `PackEntities_Normal` then encodes each transmitted entity once, into a shared `PackedEntity`, in parallel (`ParallelProcess`). Every client's `WriteDeltaEntities` then deltas the shared packs against its own acked baseline.
- **FC now.** dot-net builds a snapshot every `ticks_per_snapshot()`: 66/33, so every second tick.
  - It freezes the state, does shared property reads, then per-peer relevance and encoding.
  - It has a native core, and `sv_snapshot_workers` spreads per-peer builds over threads (`fc-snapshot-workers-1`, merged).
  - Bots are server-owned, so they receive nothing, as in Source.
- **Saves.** At most the send itself, 0.65-0.77 ms, against Source's 0.09. At one real client that is below 0.6 ms in practice.
  - The per-peer part grows with real players: `net_probe` with 31 fake peers gave 4.31 ms, 2.86 with 4 workers.
  - A Source-style "encode each entity once, delta per client" cache is the lever there. Filed: `net-pack-once-1`.
- **Risk.** None to hit reg or lag compensation. The wire bytes and the server's history are unchanged; only how they are built changes.

### 2. PackedEntity delta against the baseline, SendProp change tracking

- **Source.**
  - `SV_PackEntity` encodes the entity's SendProps straight from entity memory at pack time.
  - It runs `SendTable_CalcDelta` against the previously sent pack.
  - When `nChanges == 0`, it reuses the previous packet (`UsePreviouslySentPacket`). A `ChangeFrameList` records the tick each prop last changed, so a client's delta only walks props changed since its ack.
  - Nothing is copied between snapshots.
- **FC now.**
  - dot-net deltas against the client's acked snapshot (`encode_ack` / `receive_ack`).
  - The replicated fields are a mirror that `ArenaPlayerNet.pull()` refills every tick, for every player.
  - The in-flight `arena-simnet` patch stops refilling bots between snapshots. That is half of 31 bots' pulls.
  - A person's pull cannot skip, because `_pull_exact` puts his state back through float32 every tick, as his client's replay does.
- **Saves.** The bot half is about 0.3-0.8 ms and is the in-flight patch, not repeated here.
  - Rebuilding dynamic prop sets per tick inside the addon pulls is `simhost-addon-pull-sets-1`, about 0.5 ms.
- **Risk.** None for bots: nothing predicts a bot, and the snapshot ticks still pull. For persons, skipping would change the sim, so it is excluded.

### 3. PVS and CheckTransmit

- **Source.**
  - `CheckTransmit` runs per client per snapshot.
  - The client's PVS cluster row and area portals mark which edicts can be sent; `SetTransmit` and `ShouldTransmit` let an entity force itself in or out.
  - This is inside the 0.042 ms `SV_ComputeClientPacks` scope.
  - It cuts bytes and client work, not server sim time.
- **FC now.**
  - dot-net's `DotNetInterestDistance` / `DotNetInterestGrid`, with a flat radius.
  - FC's `ArenaNetAoi` distance tiers apply from 33 players: full rate inside 40 m, every 2nd snapshot to 80 m, every 4th to 120 m.
  - A beaconed player is `always_relevant`.
  - No PVS yet: a branch exists on `net-visibility-interest-1`, not merged.
- **Saves.** About 0 server ms at one client; it trims client decode and bandwidth.
- **Risk.**
  - Hit reg and lag compensation are server-side and unaffected.
  - A wrongly culled enemy would be drawn late. That is a visual risk, not a hit-reg one.

### 4. Tick rate and cl_updaterate

- **Source.** The sim runs at `-tickrate 66`. Snapshots go to each client at its `cl_updaterate`, capped by `sv_maxupdaterate`. `ShouldSendMessages` paces each client separately.
- **FC now.** The sim runs at 66 ticks. Snapshots go at `sv_snapshot_rate`, 32 by default, sent as the nearest whole-tick divisor, so 33. History is recorded only on snapshot ticks.
- **Saves.** 0 ms: both already decouple the snapshot rate from the tick. Lowering the tick rate would change the authoritative sim, so it is excluded.
- **Risk.** None, since nothing changes.

### 5. Usercmd batching and ProcessUsercmds

- **Source.**
  - A client sends its usercmds in batches at `cl_cmdrate`, with backup copies.
  - `CBasePlayer::ProcessUsercmds` runs `PlayerRunCommand` for each one as the packet arrives (inside `NET_ProcessSocket`, 0.064 ms per call here).
  - Bots never touch the network: `CCSBot` fills a usercmd and runs it straight through `PlayerRunCommand`.
- **FC now.**
  - dot-net buffers input per peer and applies it on the tick (`_apply_input`, `has_method`/`call` per behaviour).
  - It then calls `_net_simulate` on every identity; the first player's call runs the whole game tick once (`ArenaNetBridge.ensure_game_ticked`).
  - Bots' commands are made in `_commands()`, in the slot a client's input lands in.
  - Measured: input about 0.05 ms, dispatch residual 0.14 ms.
- **Saves.** At most 0.2 ms. `simhost-net-dispatch-1` was rejected below the gate.
- **Risk.**
  - Applying a person's commands on arrival, as Source does, would change when lag compensation rewinds and how the replay lines up.
  - That is a real hit-reg risk, so it is excluded.

### 6. Bot think

- **Source.**
  - `CBotManager::StartFrame` calls `Upkeep()` (aim and look) every tick for every bot.
  - It calls the full `Update()` only when `(tickcount + entindex) % g_BotUpdateSkipCount == 0`, which staggers bots across ticks (`bot_manager.cpp:131`).
  - In the vprof that is 28590 `Update` calls in 4404 ticks: 6.5 bots a tick, 0.099 ms each.
  - Of the 2.82 ms total, 2.07 ms is threat collection: 1.13 M `IsVisible(pos)` traces at about 1 µs each.
- **FC now.**
  - Bots think on tiers too: `bot_refresh` runs about 16 times a tick at 32 players, which is alternate ticks.
  - `srv_bots` costs 2.7-3.3 ms, with `bot_brain` 1.1-1.3 and the rest glue.
- **Saves.** 1-2 ms, but only native: the per-tick contact table and batch refresh in dot-sim (`simhost-bot-native-glue-1`).
  - FC's think rate is already Source's; the gap is the cost per think.
- **Risk.** None to hit reg if the bot digests stay identical, which is what that item's done-when requires.

### 7. Physics per player

- **Source.**
  - Player movement is `CGameMovement`: swept hull traces against the BSP brush tree (`BoxTrace` about 0.7 µs), 8-10 µs a player.
  - vphysics runs only props (`CPhysicsHook` 0.10 ms here).
  - No rigid body per player.
- **FC now.**
  - `p_controller` about 96 µs a player through dot-sim's motor batch, with native hull collision (`p_hulls` 0.5).
  - Rigid bodies only for props and ragdolls, in `tick_world`.
- **Saves.** The large one, 2-2.5 ms, from the player row in native code (`simhost-native-player-row-1`; perf-vs-css.md row 2). That work is in the addons.
- **Risk.** It must keep the same motor results (sim digests), or prediction and lag compensation drift.

### 8. What Source skips for idle and far entities

- **Source.**
  - Think lists: an entity with no next think costs nothing.
  - Server bones only for the 8 a tick that lag compensation or hit tests ask for.
  - `FL_EDICT_DONTSEND` entities are never packed.
  - An unchanged entity reuses its last pack.
  - Dormant entities on the client stop interpolating.
  - Bots get no snapshot.
- **FC now.**
  - Dead players are skipped in `_tick_players`; a far bot's body sits ticks out (`body_delta` -2).
  - Hit boxes come from the unlag ring, with no per-tick bones.
  - AOI tiers apply, and bots receive nothing.
  - In flight: bot pulls and kill view eyes only on the ticks that use them.
- **Saves.** Covered by the in-flight patch. The rest (idle identity dispatch) measured 0.14 ms.
- **Risk.** None for the skips listed. Skipping a person's tick or pull would change the sim, so it is excluded.

## Implemented here

Nothing in this pass. Every candidate is one of three kinds:

- **Already in flight:**
  - bot pulls on snapshot ticks only;
  - kill view eyes on ring-due ticks only.
- **Measured below 0.6 ms in this repository:**
  - dispatch 0.14;
  - input 0.05;
  - the pre-net watches in `ArenaNetBridge.server_tick`, which are all change-gated or run every 15th tick;
  - the kill view record gate;
  - the per-player glue `pl_pre` + `pl_post`: 0.9 ms with the fine spans on, which inflate it (64 clock-read pairs a tick). It is not split further here, and cutting 0.6 of it is not credible.
- **In an addon:**
  - snapshot pack sharing (dot-net);
  - bot glue (dot-sim);
  - the player row (dot-sim, dot-fps);
  - pull sets (dot-fps, fc-weapons, dot-combat).

The 10x is the language the per-player work runs in, not a missing network trick. FC already has Source's snapshot-rate split, its bot staggering, server-only hit boxes, and interest culling.
