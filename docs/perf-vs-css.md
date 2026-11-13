# Fatal Contact against Counter-Strike: Source, measured

Why does a 2004 game run 32 players faster than FC? This file answers with measurements: a CS:S dedicated server profiled on the same box as FC's bench, the CS:S map data read straight from the .bsp, and FC's own budget from [perf-architecture](perf-architecture.md). A CS:S client could not be measured (no client install; the SDK download fails with "No subscription"). The client column therefore uses only facts that can be read from the shipped map files or the Source SDK 2013 source.

**The short answer.** CS:S does not do less per player than FC; it does the same work in C++. FC's map rendering already has what made Source fast: BSP visibility culling (dot-map's `DotMapVisibility`, on by default for converted maps) and baked lighting (`LightmapGI`). All 3D drawing together costs FC 0.9-1.8 ms of a 12.9 ms frame. The gap is per-player game code:

- on the server, 4-6 times CS:S per player-tick;
- on the client, about 5.5 ms of GDScript loops over the remote players, where Source runs compiled entity code.

## How it was measured

- **CS:S:** `srcds_linux64` (CS:S dedicated server, app 232330, 64-bit engine libraries) with these settings:
  - on de_dust2 at `-tickrate 66`, with `bot_quota 32` (31 bots fill the 32 slots);
  - `mp_freezetime 0`, `mp_roundtime 9`, rounds playing continuously.
- **Box and load:** staging02 (i7-8700K, the box FC's bench uses), load average 1.5-1.7.
- **Each run:**
  - 30 s warm-up;
  - 120 s with `vprof_on`, then `vprof_generate_report`;
  - process CPU taken from `/proc/PID/stat` (utime+stime) over the same 120 s;
  - `stats` reported 66.7 fps and 31 players.
- **Runs:** n=3. The driver scripts were scratch tools under `~/css-prof` on staging02, not in this repo.
- **FC:** `tools/perf_bench.sh --box staging02`, windowed, sim host (hosted true), cp-orange-x3 with 32 players.
  - Client numbers are from perf-architecture.md (n=3).
  - Server numbers are the `--sim_sections 2` split on nightly `arena-perf-bench-1` (srvfine3).

### Caveats

- The maps differ (de_dust2 against cp-orange-x3).
- CS:S bots receive no snapshots, so CS:S's send cost here is about 0. FC's 0.73 ms send is to one real client.
- vprof's own overhead is inside the CS:S numbers, so they are upper bounds.
- CS:S bots think on alternate ticks: 15.5 `CCSBot::Update` calls per tick for 31 bots. FC's bots also think at a tiered rate.

## Server, ms per 66 Hz tick (32 players)

| Component | CS:S (staging02, n=3) | FC sim host (staging02) | Ratio |
| --- | --- | --- | --- |
| Whole process CPU (all threads) | 2.57, 2.51, 2.76 | 10.5-11.0 main thread + 0.73 send | about 4.5x |
| Game frame (`CServerGameDLL::GameFrame`) | 1.84, 1.79, 1.99 | `srv_net` 11.7-12.3 (the game tick is nested in it) | about 6x |
| Bots (`CBotManager::StartFrame`) | 0.94, 0.85, 0.98 | `srv_bots` 3.3 (`bot_brain` 1.7, `bt_begin` 0.84, `bt_finish` 0.67) | about 3.5x |
| Per bot-tick | 27-32 µs | about 106 µs | |
| Player movement and commands (`CCSPlayer::PlayerRunCommand`, 31 per tick) | 0.61, 0.64, 0.71 | `p_controller` 3.4 (30 players) | about 5x |
| Per player-tick | 20-23 µs (`ProcessMovement` alone 8-10 µs) | about 113 µs (117 µs per call on the native collision path) | |
| Hull traces (`BoxTrace`) | 490-616 per tick, 0.35-0.41 ms (about 0.7 µs each) | inside `p_controller` and `bot_brain`; line of sight alone 0.6 ms | |
| Server bones (`CBaseAnimating::SetupBones`) | 8-10 calls a tick, 0.18-0.22 | none (hit boxes come from the unlag ring) | |
| Rigid-body physics (vphysics `CPhysicsHook`) | 0.13-0.16 | in `tick_world` | |
| Network send | about 0 (bots only) | 0.73 | |

The earlier dev02 runs agree in shape. dev02 is a loaded QEMU VM (load 6), and 64-bit for 120 s gave 3.11 ms of process CPU and GameFrame 2.77 ms per tick. Cost moves with the round phase: a 20 s window at round start read 3.2 ms with a 10.9 ms peak. That is why each staging02 run covers 120 s of play.

## Client: what Source does, and what FC already has

**Measured from the shipped .bsp files**, read with a throwaway lump-header parse (Valve BSP v19/20, lumps 4 visibility, 7 faces, 8 lighting, 35 game lump `sprp`):

| Map | PVS clusters | Average PVS row | Lightmap bytes | World faces | Static props |
| --- | --- | --- | --- | --- | --- |
| de_dust2 | 1781 | 20.2% of clusters | 3.35 MB (and the same again for HDR) | 6230 | 321 (53 models) |
| de_inferno | 2450 | 27.5% | 1.67 MB | 11507 | 547 (172 models) |
| cs_office | 1754 | 10.3% | 2.44 MB | 6483 | 324 (47 models) |

From any point in de_dust2, the precomputed PVS rules out about 80% of the map with no runtime test. All world lighting is baked into lightmaps; no runtime light shades the world.

**FC already has both.** FC draws converted maps through dot-map's `DotMapDrawnWorld`:

- `_add_culling` attaches `DotMapVisibility`, the same PVS and area portals read from the source map plus occluders. `cull` defaults to true.
- `DotMapLitWorld` and the game's `LightmapGI` bakes (`tools/lightmap_scenes.gd`) supply the baked lighting.

What is left of FC's drawing is small and already measured:

- `--ablate no3d`, which removes the whole 3D scene, saves 1.77 ms at 32 players (0.93 ms on cp-orange-x3).
- The GPU takes 2.7 ms in parallel with the CPU, and is not fill-bound: 640x360 changes nothing.
- Draw calls run 450 (cp-orange-x3) to 880 (dm-scarletdevilmansion). On the second map, 613 of the 880 are the shadow pass.

**Source SDK 2013 (github.com/ValveSoftware/source-sdk-2013, `src/game/client/`)** shows how the client side of Source works:

- **Interpolation.** Every entity's interpolation is compiled code: `C_BaseEntity::GetInterpolationAmount` in `c_baseentity.cpp` returns `cl_interp`, rounded to ticks, plus one tick. Each networked variable is a `CInterpolatedVar` history.
- **Character shadows** are render-to-texture blobs projected onto the world (`clientshadowmgr.cpp`), not shadow-map passes through every caster.

FC does the same interpolation (dot-net's `DotNetInterpolator`, `cl_interp_ratio` 2) and the same per-body pose and animation, but in GDScript per remote player.

## Top 5 structural differences, ranked by what FC could gain

Gains are at 32 players, sim host, on staging02. Every row already has a nightly item.

| # | Difference | CS:S | FC now | FC could gain | Item |
| --- | --- | --- | --- | --- | --- |
| 1 | Per-entity client work (interpolation, pose, snapshot decode) is compiled | `CInterpolatedVar`, `C_BaseEntity` in C++ | `interpolate` 1.23 + `bodies` 2.3-2.7 + `predict` 0.8 + `net_snapshot` 0.5-0.8: about 5.5 ms of GDScript, 0.33 ms per remote player | **4-5 ms client frame** | `perf-client-native-body-1` |
| 2 | Server player movement and bots in native code with cheap hull traces | 20-23 µs per player-tick, 27-32 µs per bot-tick, 0.7 µs per `BoxTrace` against the BSP brush tree | 113 and about 106 µs | **6-8 ms per server tick** (headroom and 64-128 Hz, not client fps: the sim host is another process) | `perf-native-motor-2`, `simhost-native-player-row-1`, `simhost-sim-cost-1` |
| 3 | Animation is evaluated on demand | server `SetupBones` only for the 8-10 entities a tick whose bones are asked for (0.2 ms) | `r_anim` 1.1-1.4 + skeleton flush 0.65 every frame for every body; the measured ablation is 1.52 | **up to 1.5 ms** | `perf-figure-animate-1` |
| 4 | No per-frame allocation or script dispatch in the fixed floor | entity think lists in C++ | empty match 2.85 ms; about 1.0 ms of singletons' `_process`; 1.7 ms of engine physics (ragdolls, 135 particle nodes in physics process); `animate` duplicates its motion dictionary each call | **1-2 ms** (estimate: profile first) | `perf-unattributed-process-1` |
| 5 | Shadows and draw submission | projected render-to-texture character shadows | shadow pass 613 of 880 draws on one map; all 3D 0.9-1.8 ms; `render_cpu` 1.0 | **under 1 ms**, below the 0.6 ms gate on cp-orange-x3 | `perf-render-thread-1` (render CPU off main) |

Ruled out by measurement:

- **BSP PVS culling and precomputed lighting.** FC already has both, and all of 3D is 0.9-1.8 ms.
- **Fill rate and MSAA.** 640x360 made no change.
- **Interpolation design itself.** It is the same scheme as Source: about 2 snapshots of buffer, a lag-compensated server. The cost is the language it runs in, not the design.

**No cheap win in this pass.** Every lever that fits in this repository and is under the L/M rows above was already benched on `arena-perf-bench-1` and fell under the 0.6 ms gate. Examples:

- the killview record gate: 10.89 to 10.85 ms per tick, against about 3 ms of run-to-run noise;
- the 3D scene on cp-orange-x3: 0.93 ms in total.

Rows 1-3 are work in the addons (dot-net, dot-player-char, dot-player-controller, dot-bot, dot-sim), not in this repository.
