# Performance architecture: where a 32-player frame goes

An architecture-level audit (2026-11-13) against the owner's target of **400 fps with 32 players (2.5 ms a frame)**. Every number here is measured on staging02 (RTX 2070, i7-8700K 6c/12t, Godot 4.7.2, Forward+ Vulkan, headless Xorg, windowed 1152x648) with `tools/perf_bench.sh --box staging02`, the frame-time bench described in [testing](testing.md#performance-measurement). Running findings stay on the nightly item `arena-perf-bench-1`; this file is the map of the costs and what each lever is worth.

## The short answer

- **The shipped game is the sim host** ([sim-thread](sim-thread.md)): the solo game's server runs in a second process. With 32 players its client frame is **12.8 ms p50 (78 fps)**, not the 30 ms the bench shows by default (`--sim-host 0`, the in-process game, which ships nowhere on desktop).
- **Even an empty match misses 2.5 ms**: 0 bots is 2.85 ms p50 (about 330 fps).
- The client costs about **0.33 ms per remote player** on the main thread, nearly all of it GDScript presentation and netcode (interpolate, predict, bodies, animation). 400 fps at 32 needs that cost down about ten times: a native per-body path, not trimming.
- The GPU is not the limit: 2.7 ms GPU at 32 players, in parallel with an idle-waiting CPU.
- The server process runs **10.5-11.0 ms of its 15.15 ms tick** at 32 (66 Hz), on one thread; its worker threads are idle.

## Budget (ms per client frame, p50 of n runs)

| | 0 bots (n=2) | 8 bots (n=2) | 32 players, sim host (n=3) | 32 players, in-process (n=3) |
| --- | --- | --- | --- | --- |
| frame p50 | 2.85 | 5.88 | 12.9 | 30.0 |
| frame p95 | 4.3 | 8.6 | 18 | 48 |
| main: script phase (`_process`) | 1.68 | 3.70 | 8.22 | 7.85 |
| main: physics phase (net, predict, physics) | 0.21 | 0.77 | 3.07 | 21.18 |
| main: render phase (CPU) | 0.85 | 1.23 | 1.57 | 1.44 |
| main: wait | 0.26 | 0.38 | 0.40 | 0.30 |
| GPU (`render_gpu_ms`) | 0.97 | 1.28 | 2.70 | 4.90 |
| nodes | 2382 | 3019 | 4120-4550 | |
| server process main thread, ms per 66 Hz tick | 0.78 | 4.35 | 10.5-11.0 (+0.73 send) | (on the client: 21.2 above) |
| server worker threads | idle | idle | 0.14 each | |

The client has one busy thread (main). The render thread is the main thread (`rendering/driver/threads/thread_model` default) and physics runs on it too.

### The 32-player client frame by system (sim host, ms/frame)

| System | ms | What it is |
| --- | --- | --- |
| `arena.present` | 4.5-4.8 | everything drawn per frame for players, of which: |
| - `arena.bodies` | 2.3-2.7 | remote bodies: pose, held weapon, tag, animation |
| - `arena.r_anim` | 1.1-1.4 | `DotHumanoidFigure.animate` per body |
| - `arena.r_held` and hooks | 0.45 | third-person weapons |
| - `arena.r_tag`, `r_pose` | 0.35 | name tags, pose |
| `arena.interpolate` | 1.23 | snapshot interpolation of every remote player |
| `arena.physics` (client prediction) | 1.3 | the local player's predicted ticks |
| `arena.predict` | 0.8 | |
| `arena.net_snapshot` | 0.5-0.8 | decoding snapshots |
| `arena.c_rest`, `c_killcam`, `hud`, `c_spectate`, `c_flashlights` | 1.2 | the rest of the client |
| engine physics outside game code | 1.7 | GodotPhysics step: ragdolls, drops, 135 GPU particle nodes' physics notification |
| process phase outside arena spans | about 1.0 | 50-odd singletons' `_process`, skeleton flushes |

The process phase split (`--proc-split 1`, wall clock, n=2): early flush 0.52, `_process` pass 6.5-6.7, late flush (Skeleton3D pose updates) 0.62-0.65, transform notifications to pre-draw 0.24.

### Census at 32 players (sim host, `--proc-split 1`)

4120 nodes; 1330 MeshInstance3D (616 visible, 383 casting shadows, 49 skinned); 49 Skeleton3D with 2107 bones, all internally processing; 100 AnimationPlayer (54 processing themselves, 46 manual); 135 GPUParticles3D, all in internal physics process; 70 audio players (none playing); 19 visible lights (15 directional: the HUD portrait worlds; 4 omni; 1 shadowed); 110 OmniLight3D nodes in all; 22 Camera3D; 34 Label3D; 352 collision shapes on 15 rigid, 3 static bodies and 1 area; 1348 signal connections. Scripts with a `_process`: `dot_humanoid_figure` 46 (32 bodies and about 14 HUD portraits), `aw_shot_fx` 33, `aw_charge_fx` 13, `aw_world_model` 11, `aw_view_model` 6, and about 50 singletons (HUD, menus, audio).

## The candidates

### (a) Scene-tree cost

4120 nodes is not the cost by itself: transform notifications to pre-draw are 0.24 ms and the early flush 0.52 ms. The cost is per-node *script*: 46 humanoid figures and about 60 effect nodes each with a GDScript `_process`, and the per-body work in `arena.bodies`. The about 1 ms of process phase outside arena spans at 0 bots is the singletons and engine flushes; worth one profile with `profiler_script_top` under the debugger before any change.

### (b) Skinning and animation

`--present-ablate 1` (no figure animation; presentation only) cuts **1.52 ms p50** at 32 (n=2, 12.6 to 11.1 ms; `r_anim` -0.99, `bodies` -1.16, GPU -0.37). An earlier `--ablate noanim` gave 1.65. The per-call cost is inside dot-player-char's `DotHumanoidFigure.animate` (legs restored and applied every call, the motion dictionary duplicated each call). Skinning itself is on the GPU (49 skinned meshes, 2107 bones); the CPU side is the skeleton flush, 0.65 ms.

### (c) GDScript hot loops for native code

On the client: `interpolate` (1.23), `bodies` and `r_anim` (2.5), `predict` (0.8) and `net_snapshot` (0.5-0.8) scale with players and are loops over every remote player in GDScript: about 5.5 ms of the 8.2 ms script phase. On the server: `tick_players` (p_controller 3.4 and p_weapons 2.8 ms per frame in-process), bots 5.7 (bot_brain 2.7, of which line of sight 0.6, refresh 0.95). The server side is authoritative simulation: it moves to native only bit-exactly (`perf-native-motor-2`, `arena-perf-step-2`), never by changing what it computes.

### (d) Physics

The sim host already takes the authoritative physics off the client (21.2 to 3.1 ms physics phase). What remains on the client is prediction (`arena.physics` 1.3 + `predict` 0.8) and 1.7 ms of engine physics outside game code: 15 rigid bodies (ragdolls, drops) and 135 GPU particle nodes in internal physics process.

### (e) Render thread, shadows, MSAA

The render phase is 1.57 ms of the 12.9 ms frame (1.02 ms of it `render_cpu`) and the GPU 2.70 ms, run in parallel with a CPU that waits only 0.4 ms. Two A/Bs at 32 players (sim host, n=2):

- `--ablate no3d` (no 3D drawn): p50 -1.77 ms; render phase 1.53 to 0.82, `render_cpu` 0.98 to 0.40, GPU 2.71 to 0.56, and the physics phase 0.64 lower. So all of 3D drawing costs the main thread about 1-1.8 ms.
- `--res 640x360` (a ninth of the pixels): no change (GPU 2.68 ms, p50 within noise). The game is not fill-bound, so **MSAA (4x, `DotGameRenderQuality`) and shadow resolution are not where the frame goes**: lowering them buys no client fps on this box. Shadows: 383 shadow-casting meshes but one shadowed light; the cost is draw submission on the CPU, counted in the 1.0 ms `render_cpu`.

**A separate render thread (`rendering/driver/threads/thread_model=2`) is not usable on Godot 4.7.2**: the bench run crashed (exit 139) after a sky shader compile race (`arena_sky.gdshader` interleaved with the engine's sky shader: "Expected a ';'"), `RenderingDevice.finalize` "can only be called from the render thread", and 11504 warnings that `particles_is_inactive` forces a RenderingServer sync every frame (dot-fx `dot_muzzle_flash.gd:90`, from `aw_shot_fx_flash._pack_flash`). Even without the crash those syncs would serialise the two threads. The most the render thread could win is the 1.0-1.5 ms of render CPU on main; it needs the engine's threaded model to mature and dot-fx to stop polling particles.

### (f) Bench pacing and vsync

`wait` is 0.3-0.5 ms a frame: the bench is not paced or vsync-bound. The real issue is the default: `--sim-host 0` measures a game that does not ship on desktop and puts 17 ms of authoritative simulation on the client frame. Every number on `arena-perf-bench-1` before this audit is that configuration.

## Ranked by ms saved per effort

Saved ms are at 32 players, sim host, client frame of 12.9 ms p50. Effort: S small, M medium, L large. Each has a nightly item.

| # | What | Saves | Effort | Where | Item |
| --- | --- | --- | --- | --- | --- |
| 1 | Native per-body client path: snapshot decode, interpolation, pose and animation of every remote player in one native loop | 4-5 ms (of the 5.5 ms the per-player GDScript costs) | L | dot-net, dot-player-char | `perf-client-native-body-1` |
| 2 | `DotHumanoidFigure.animate`: no per-call dictionary duplicate, no unchanged leg writes, batched bone poses | up to 1.5 ms (measured ablation 1.52) | M | dot-player-char | `perf-figure-animate-1` |
| 3 | Unattributed process (about 1.0 ms of singletons and effects' `_process`) and engine physics (1.7 ms: ragdolls, 135 particle nodes) | 1-2 ms (estimate, profile first) | M | game-arena, arena_weapons, dot-fx | `perf-unattributed-process-1` |
| 4 | Separate render thread, once safe: needs the engine fixes above and dot-fx's muzzle flash to stop calling `particles_is_inactive` | 1.0-1.5 ms (render CPU on main) | M, blocked | dot-fx, engine | `perf-render-thread-1` |
| 5 | Server: native player row and bots (10.7 of 15.15 ms a tick at 32) | server headroom, not client fps | L | dot-player-controller, dot-bot | existing `simhost-sim-cost-1`, `simhost-native-player-row-1`, `perf-native-motor-2` |
| 6 | Bench default `--sim-host 1`, and report the server's ms per tick | none; measures what ships | S | game-arena tools | `perf-bench-simhost-default-1` |
| 7 | HUD portrait figures stop processing after their single render | under 0.1 ms | S | game-arena | `perf-portrait-figures-1` |

Not worth it on this evidence: MSAA, shadow resolution and render scale (the GPU is parallel and not fill-bound), and node count alone (0.24 ms of transform notifications for 4120 nodes).

Even all of 1-4 leaves the 32-player client near 5-6 ms (about 180 fps), and an empty match is already 2.85 ms. 400 fps at 32 players needs the per-player work native and the fixed 2.9 ms floor (HUD, singletons, render submission) halved as well.
