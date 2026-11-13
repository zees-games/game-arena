# CS:S server scopes against FC's sim host, scope by scope

This file maps every CS:S dedicated-server VProf scope to the FC sim-host span that does the same job. Each one is given in ms per tick and µs per player or bot. The bot think gets a closer look: what one think costs, its sight and target scans, and how Source budgets and staggers it.

[css-dedicated-server-baseline.md](css-dedicated-server-baseline.md) has the runs and [source-server-comparison.md](source-server-comparison.md) has the network techniques. This file does not repeat their tables.

## Inputs

- **CS:S**: run B4 of `perf-logs/external/cstrike/server-pterodactyl/20261113-164932/`. That is srcds_linux64 on de_dust2 at tick 66.7 with 31 bots, 4120 ticks and load average about 5. B4 is the median 31-bot window (2.20 ms per tick). Runs A1-B6 move 0.5-2.4 ms of bot cost with fighting density, so read the CS:S column as one window, not a constant.
  - Bots receive no snapshots, so `ProcessUsercmds` and `SV_ComputeClientPacks` do not appear there. Those rows come from the owner's listen server (`vprof_report_32bots.log`), as in source-server-comparison.md.
- **FC**: staging02, windowed `tools/perf_bench.sh --box staging02 -- --sim-host 1`, on cp-orange-x3 CTF with 31 bots and the script brain. `--sim_sections 2` gives the spans. The log shows `SIM_HOST ready bots=31 bot_threads=3`, so the sim host was really up.
  - Bench logs: `/home/gamedev/perf-bench/20261113-172144-staging02-arena-botscope-botscope-thr.log` (spans) and `20261113-172711-...-botscope-sub.log` (sub-laps inside the bot tail).
  - Threads 0 (`--bot_threads 0`) runs come from the same session. They are used for the ray costs, because there every ray is on the main thread.
- **Source code**, read-only: `game/shared/cstrike/bot/bot_manager.cpp`, `game/server/cstrike/bot/cs_bot.cpp`, `cs_bot_vision.cpp`, `cs_bot_update.cpp`.

## Scope table

ms per tick, inclusive. "Per unit" is per call for CS:S and per player or bot-tick for FC. The "Native" column is explained under "Recommended Rust scope".

| CS:S scope | CS:S ms/tick | CS:S per unit | FC span | FC ms/tick | FC per unit | Ratio | Native |
| --- | ---: | ---: | --- | ---: | ---: | ---: | --- |
| `_Host_RunFrame_Server` / `GameFrame` | 2.20 / 2.17 | | SIM_HOST `sim` | 12.15-12.31 | | 5.6x | structural (the sum of the rows) |
| `CBotManager::StartFrame` (all bot work) | 1.115 | 36 µs per bot-tick | `srv_bots` | 2.98-3.0 | 97 µs per bot-tick | 2.7x | mixed: sight scan (`DotSimBotSenses`) and mind (`DotSimBotMind`) are native; the tick loop around them is GDScript |
| `CCSBot::Update` (full think) | 1.083, 15.5 calls | 70 µs per think | `bot_brain` wall + `bot_refresh` | 1.14-1.16 + 0.54, 16 thinks | 71 µs per think (brain) + 34 (refresh) | 1.5x | already native, measured no gain: `--bot_native_brain 1` leaves `bot_brain` at 1.07 ms (see A/B). The remaining cost is the GDScript think loop: native candidate in the bot-tick scope below |
| `CCSBot::Upkeep` (aim each tick) | inside StartFrame, about 0.03 | about 1 µs | `bt_coast` + `bt_gate` | 0.13-0.14 + 0.12 | 10 µs per coast, 4 µs per gate | about 8x | native candidate: about 0.2 ms, about 150 lines (`arena_bots.gd` coast and gate) |
| `UpdateReactionQueue` / `FindMostDangerousThreat` | 0.72 | 46 µs per think | `br_contacts` + `_candidates` / `_sees` inside `bot_brain` | 0.44 + part of 1.15 | 0.44 shared, once a tick | about 1x | native candidate: about 0.3 ms, about 200 lines (`arena_bots_world.gd` contact table) |
| `IsVisible(player)` | 80 calls, 0.58 | 7.3 µs | `_sees` (chest, then head) | inside brain | 1-2 rays | | structural: Godot physics rays |
| `IsVisible(pos)` | 249 calls, 0.43 | 1.74 µs | `bot_los` (one ray) | 0.2-0.72 at 8-33 rays | 22 µs at threads 0, about 6 µs per worker ray | 3-12x per ray | structural on threads 3 (rays run on workers). A Rust BSP trace would be about 0.15 ms at threads 0, about 800 lines; not recommended now |
| `BoxTrace` (engine trace) | 548 calls, 0.44 | 0.8 µs | `DotTracePhysics.line_of_sight` | | 22 µs | 27x | structural: Godot physics against BSP brushes |
| `ComputePartPositions` | about 0.28 | cached per target per frame | none (bots aim at chest/head offsets) | 0 | | | n/a |
| `CBasePlayer::PhysicsSimulate` | 0.745 | 24 µs per player | `pl_sim` | 4.6-4.7 (56 calls) | 84 µs | 3.5x | motor already native (`motor_tick=full`); the wrapper is a native candidate, see `p_controller` |
| `PlayerRunCommand` (movement) | 0.718 | 23 µs | `p_controller` | 2.3 | 74 µs | 3.2x | native candidate: about 1.2 of 2.3 ms, about 600 lines of `dot_fps_controller.gd`. It is authoritative sim, so it needs a parity suite like `perf-native-motor-2`; `arena-p-controller-2` covers the engine queries |
| (weapon think inside PlayerRunCommand) | | | `p_weapons` | 1.3 | 42 µs | | native candidate, high risk: about 0.6 of 1.3 ms, about 1,500 lines of dot-combat. Hit reg, so not recommended now |
| `CPhysicsHook::FrameUpdatePostEntityThink` | 0.157 | | `tick_world` (props, ragdolls) | inside `srv_game` | | | structural: Godot physics |
| `SV_ComputeClientPacks` (listen) | 0.042 per snapshot | | SIM_HOST `send` | 0.73-0.75 | | 17x, see source-server-comparison.md 1 | snapshot codec already native; the rest is structural (`net-pack-once-1`) |
| `CBaseServer::WriteDeltaEntities` (listen) | 0.012 | | inside `send` | | | | already native (`DotSimSnapshotCodec`) |
| `NET_ProcessSocket` + `ProcessUsercmds` (listen) | 0.064 x 2 | | dot-net dispatch and input | about 0.2 | | about 1.5x | structural: dot-net dispatch, about 0.2 ms |
| `SV_SendClientMessages` (bots only) | 0.001 | | none on bots | 0 | | | n/a |
| (no Source equivalent) | | | `net_pull` | 0.56-1.7 | | in flight, `arena-simnet` | in flight (`arena-simnet`) |
| (no Source equivalent) | | | bot glue: `bot_after` 0.25, `ba_tail` 0.30, `bt_setup` 0.11, `ba_throw` 0.10, `ba_write` 0.07, `ba_sanitise` 0.04, `br_tiers` 0.04, `br_near` 0.03 | about 0.95 | 31 µs per bot-tick | | native candidate: about 0.7 of 0.95 ms, about 500 lines (`arena_bots.gd` tail and glue) |

`srv_game` (7.2-7.3) holds `pl_sim`, `p_controller`, `p_weapons` and the world. `srv_net` (13.0) wraps the whole sim plus the send.

## Bot think

### How Source budgets it

- **Two levels a tick.** `CBotManager::StartFrame` runs `Upkeep()` for every bot every tick: it turns the view toward the aim target and does nothing else. The full `Update()` runs only when `(gpGlobals->tickcount + entindex) % g_BotUpdateSkipCount == 0` (`bot_manager.cpp:131`). The skip count is 2, so half the bots think on even ticks and half on odd. In B4 that is 15.5 `Update` calls a tick, 70 µs each.
- **One scan a think, then a reaction delay.** `UpdateReactionQueue` (`cs_bot_vision.cpp:1576-1642`) calls `FindMostDangerousThreat` once per `Update` and pushes the result into a ring. The bot acts on the entry `reactionTime / interval` back. Reaction time is a delay over scans the bot already did, not extra scans.
- **Cheap tests first.** `IsVisible(player)` does the FOV test first, then the gut point, then the head and limbs. `IsVisible(pos)` checks blindness, `FInViewCone` and smoke before it traces. Only then does it call `UTIL_TraceLine`.
- **Part positions shared across bots.** `ComputePartPositions` caches each target's gut, head and limb points in a static `m_partInfo` keyed on `m_validFrame`. The first bot that looks at a target in a frame pays for the bones and every other bot reuses them.
- **Slow scans throttled.** Peripheral vision (`UpdatePeripheralVision`) runs every 0.29 s. Look-around and the noise checks run every 1-10 s.
- **One trace is 0.8 µs.** `BoxTrace` walks the BSP brush tree in C++, so 548 traces a tick cost 0.44 ms.

### What FC does now

- **The same think rate.** `DotBotThinkTier` thinks every tick up to 16 players. Above that it staggers: near bots every 2 ticks, far bots every 4 (body tiers up to `MAX_PERIOD` 8). Bots that do not think coast on their last command. At 31 bots that is about 16 thinks a tick, the same as Source's 15.5.
- **Scans are already shared and throttled.**
  - `br_contacts` builds one contact table a tick (0.44 ms) and every think reads it.
  - `_candidates` filters by FOV and range before any ray.
  - `_sees` traces the chest, then the head: at most 2 rays.
  - Sight answers are reused for `SIGHT_REUSE` 0.045 s, and for 0.15 s beyond `sight_far` 20 m (`dot_bot_brain.gd:64`).
  - Brains run on `WorkerThreadPool` with `bot_threads` 3 by default.
- **The cost per think is the gap.** `srv_bots` is 2.98 ms for 31 bots: 97 µs per bot-tick against CS:S's 36. Per think it is about 71 µs of brain plus 34 µs of refresh, and 0.95 ms of glue is spread over all 31 bots.
  - **Visibility**: 8-33 rays a tick at threads 0 (`bot_los` 0.2-0.72 ms), about 22 µs per ray. Each ray goes through `DotTracePhysics.line_of_sight`. That builds two `DotHitbox.Hit` objects and looks up the surface material, then calls `intersect_ray`. A worker-thread ray is about 6 µs.
  - **Target scan**: `br_contacts` 0.44 ms a tick, about 14 µs per bot. That is less than CS:S's `UpdateReactionQueue` at 0.72 ms, because FC's FOV filter runs on a shared table.
  - **Tail per think** (`ba_tail` 0.30): the tier classify about 10 µs (`ba_tier` 0.15-0.16, two `_classify` calls a think), keeping the last commands about 8 µs (`ba_keep` 0.12, two `duplicate_command` calls) and recoil compensation 0.06-0.09.
  - **Coasting**: 14-15 bots a tick, about 10 µs each (`bt_coast`), of which 2 command duplicates.

So FC already thinks as often as Source and scans no more than Source does. The remaining gap is the per-think cost of GDScript and of engine physics rays against a BSP trace.

## Implemented here

Two bot-only changes. Neither touches human commands, hit reg, lag compensation or the authoritative player sim:

1. **Sight rays skip the hit report** (`game/arena_bots_world.gd`, `_line_of_sight`). When the bots' trace is the plain `DotTracePhysics` or `ArenaGlassTrace`, the sight test does one `intersect_ray` with a reused `PhysicsRayQueryParameters3D`. It uses the same mask, glass exclusion and exclude RIDs as the trace's own `line_of_sight`, and builds no `Hit` objects and no material lookup. Bullets, rockets and hit reg still use the full trace. `headless_imported` checks 200 seeded rays around the spawns and requires the same answer from both paths.
2. **Kept commands are reused** (`game/arena_bots.gd`, `think_finish`). The bot's `last_move` and `last_fire` are overwritten in place instead of being duplicated twice a think. The coast still hands out copies, so no command is ever shared.

A/B results (n=3 interleaved, staging02, sim host up): see the "A/B" section below.

## A/B

Interleaved A/B, n=3 a side, windowed on staging02 with the sim host up (`SIM_HOST ready ... bots=31` in every leg). A is the base (`15906d1`) and B is this change. Values are means over each leg's sim-host lines after the first.

**Default threads** (`--sim-host 1`, `bot_threads=3`):

| Leg | A sim ms/tick | B sim ms/tick |
| --- | ---: | ---: |
| 1 | 11.55 | 11.77 |
| 2 | 11.86 | 11.61 |
| 3 | 11.56 | 11.36 |
| Mean | 11.66 | 11.58 |

The legs overlap, so this reads as noise. With brains on workers, the rays do not run on the main thread.

**Threads 0** (`--sim-host 1 --bot_threads 0 --sim_sections 2`, every ray on the main thread):

| Span, ms/tick | A legs | A mean | B legs | B mean | Delta |
| --- | --- | ---: | --- | ---: | ---: |
| `bot_los` | 0.276 / 0.332 / 0.344 | 0.317 | 0.170 / 0.154 / 0.202 | 0.175 | -0.14 (-45%) |
| `bot_brain` | 1.701 / 1.694 / 1.781 | 1.725 | 1.623 / 1.474 / 1.619 | 1.572 | -0.15 (-9%) |
| `srv_bots` | 3.612 / 3.588 / 3.694 | 3.631 | 3.617 / 3.424 / 3.691 | 3.577 | -0.05, overlaps |
| sim (total) | 12.94 / 12.90 / 13.00 | 12.95 | 12.97 / 12.60 / 13.58 | 13.05 | noise |

The sight-ray saving is consistent and has no overlap: about 0.14 ms a tick, which is 10-12 µs per ray, so a ray now costs about 10 µs instead of 22. `srv_bots` gains less than `bot_brain` does because B carries four extra probes (`bt_gate`, `bt_coast`, `bt_setup`, `ba_tail`) that A does not have. The total sim swings ±0.5 ms between legs and hides a 0.15 ms gain. The change is kept under the perf keep rule. It is bot-only and the bot suites pass.

**Native mind on or off** (`--sim-host 1 --sim_sections 2 --bot_native_brain 0|1`, threads 3, interleaved, n=3 a side, same tree; the log says `brain=native` on the on legs):

| Span, ms/tick | Script legs | Script mean | Native legs | Native mean |
| --- | --- | ---: | --- | ---: |
| `bot_brain` | 1.089 / 1.081 / 1.037 | 1.069 | 1.036 / 1.077 / 1.067 | 1.060 |
| `srv_bots` | 2.888 / 2.871 / 2.823 | 2.861 | 2.795 / 2.955 / 2.853 | 2.868 |
| sim (total) | 12.29 / 12.13 / 12.24 | 12.22 | 12.05 / 12.72 / 12.29 | 12.35 |

dot-sim's existing mind (aim, fight step, perception) makes no measurable difference here, so it is not the bottleneck. The cost sits in the GDScript around it: the think loop, the contact table, the coast and the glue.

## Recommended Rust scope

The Native column in the scope table marks each line as **already native**, a **native candidate** (estimated ms saved, estimated lines to move) or **structural** (Godot physics, the network or the sum of other rows, which Rust in dot-sim does not fix). Only dot-sim has Rust today (about 8.5k lines: motor, brain, snapshot, bots, math, gdext). dot-bot, dot-net, dot-player-controller and dot-combat are GDScript.

**Recommended: one bot tick in dot-sim** (`simhost-bot-native-glue-1`).

- **What moves**: the per-tick bot loop, which is
  - the think tiers (`DotBotThinkTier`, 221 lines);
  - the contact table (`br_contacts`);
  - coast and gate (`bt_coast`, `bt_gate`);
  - the think tail and glue (`ba_tail`, `bot_after`, `bt_setup`, the `arena_bots.gd` and `arena_bots_world.gd` parts);
  - the brain's per-think GDScript in `dot_bot_brain.gd` (965 lines) that wraps the existing `DotSimBotMind`.
- **Size**: about 1,400 GDScript lines become about 1,500 Rust lines in dot-sim, plus a GDScript twin that is kept for the web.
- **Expected saving**: `srv_bots` from 2.9 to about 1.1-1.4 ms a tick at 31 bots, so 1.5-1.8 ms a tick, or 50-60 µs per bot-tick. That is CS:S's 36 µs per bot-tick plus FC's engine rays.
- **Risk**: low. It covers bots only, and hit reg, lag compensation and the human sim stay outside it. Its parity check is the bot suites plus a seeded command-for-command comparison, like `perf-native-motor-2`.
- **Overlap**: it overlaps `arena-perf-step-2`'s `bot_brain` kernel. Merge the two rather than run both.

**Not recommended now**:

| Candidate | Estimated saving | Size | Why not now |
| --- | --- | --- | --- |
| `p_controller` wrapper | about 1.2 ms | about 600 lines | It is authoritative player sim. It needs its own parity suite, and `arena-p-controller-2` first. |
| `p_weapons` | about 0.6 ms | about 1,500 lines | It is hit reg. |
| A Rust BSP trace | about 0.15 ms, at threads 0 only | about 800 lines | |

## Gaps and board items

| Gap | FC cost now | Source | Owner | Board |
| --- | --- | --- | --- | --- |
| Engine ray against BSP trace | 6-22 µs per ray | 0.8 µs | dot-combat: a shared sight-ray API (no `Hit`, no material) for every game, then a native or BSP-tree trace | `bot-sight-ray-shared-1` |
| Per-target part points shared across bots | each bot computes chest and head offsets | `m_partInfo` per frame | dot-bot | `bot-sight-ray-shared-1` |
| Tier classify twice a think | about 10 µs per think | none (skip count only) | dot-bot `DotBotThinkTier` | `bot-tier-classify-once-1` |
| Coast allocations | 2 duplicates per coasting bot, about 10 µs | `Upkeep` about 1 µs, no allocation | dot-bot / game glue | `bot-tier-classify-once-1` |
| Brain and glue in GDScript | 71 µs brain + 31 µs glue per bot-tick | 36 µs per bot-tick in C++ | dot-sim native brain and glue | `simhost-bot-native-glue-1` |
| Player movement and weapons | 74 + 42 µs per player | 23 µs | dot-sim native player row | `simhost-sim-cost-1` |
| `net_pull` | 0.56-1.7 ms | 0 | in flight, `arena-simnet` | `net-pack-once-1` |
