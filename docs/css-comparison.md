# FC client frame vs Counter-Strike: Source

Why CS:S shows about 0.6 ms per frame with 32 bots while the FC client spends about 11.8 ms, and what FC can cut. The server side is in [perf-vs-css.md](perf-vs-css.md). This page covers the client.

## The CS:S number is 1.2-1.7 ms

The source is `vprof_report_32bots.log`: a CS:S listen server with 31 bots, `vprof` over two windows. The second report is cumulative, so its window is the difference of the two (57112 frames). **VProf counts two frames per engine frame**, so its "Avg/Frame" of 0.6 ms is half the real cost. Divided by real engine frames, `CEngine::Frame` is 1.20 ms in window 1 and 1.68 ms in window 2. The `stats` lines say 554-844 fps, which is 1.2-1.8 ms. These figures include the listen server and its bots.

The net_graph in the matching video (`cstrike_win64_XBkh1cPlfS.mp4`, read frame by frame with ffmpeg) shows:

| Item | Reading |
| --- | --- |
| fps | 293-864 |
| ping | 0 ms (listen server) |
| sv | 435-952 fps, var 0.6-2.6 ms |
| in | 103-437 B/packet, 6.4-22.2 KB/s, about 67 updates/s |
| out | 78-118 B/packet, 5.2-7.1 KB/s, 67-74 cmds/s |
| lerp | 30 ms |
| tick | 66 |
| loss / choke | 0 / 0 |

### Per engine frame (ms)

| Scope | Window 1 | Window 2 | Note |
| --- | --- | --- | --- |
| CEngine::Frame | 1.200 | 1.677 | everything, server included |
| CViewRender::Render (all 3D) | 0.661 | 0.832 | render thread does submission (Mat_ThreadedEndframe 0.07-0.14) |
| CEngineVGui::Paint (HUD and VGUI) | 0.270 | 0.353 | 2 calls |
| _Host_RunFrame_Server (31 bots) | 0.135 | 0.270 | |
| C_BaseAnimating::SetupBones | 0.054 | 0.193 | 48 calls, about 4 us each |
| Draw3dSkyboxworld | 0.077 | 0.122 | |
| Client SimulateEntities | 0.061 | 0.127 | |
| DrawWorld + BuildWorldRenderLists | 0.152 | 0.132 | |
| DrawOpaqueRenderables | 0.068 | 0.081 | |
| C_BaseAnimating::DrawModel | 0.022 | 0.048 | 18 calls (only bodies in view) |
| UpdateClientSideAnimations | 0.015 | 0.057 | |
| CStaticPropMgr::DrawStaticProps | 0.046 | 0.029 | |
| Particles (simulate + draw) | 0.043 | 0.069 | |
| Shadows (ComputeShadowTextures + PreRender + RenderShadows) | 0.040 | 0.103 | |
| CClientLeafSystem::PreRender | 0.008 | 0.030 | |
| CPrediction::Update | 0.020 | 0.034 | |
| InterpolateServerEntities | 0.009 | 0.019 | about 0.5 us per entity |
| Net (NET_ProcessSocket + CL_ReadPackets) | 0.022 | 0.042 | |
| Sound | 0.015 | 0.022 | |

## How Source stays cheap (source-sdk-2013/src/game/client)

- **Lazy, cached bone setup.** `C_BaseAnimating::SetupBones` (c_baseanimating.cpp:2796) runs only when something asks for bones: a draw, a shadow, an attachment, a hitbox. It runs at most once a frame (`m_iMostRecentModelBoneCounter` against `g_iModelBoneCounter`). It sets up only the bones in the requested mask (hitbox, attachment or vertex LOD). A body nobody draws sets up no bones. `cl_threaded_bone_setup` (line 2767) spreads the setup across threads.
- **Interpolation list.** `g_InterpolationList` (c_baseentity.cpp:99, `ProcessInterpolatedList` at 3123, `AddToInterpolationList` at 6282) holds only entities whose networked vars changed. An entity leaves the list once nothing moves.
- **Dormancy.** An entity outside the PVS is dormant (`IsDormant`, c_baseentity.cpp:1422, 1873). The server does not send it, and the client does not simulate or draw it.
- **Dirty-only leaf system.** `CClientLeafSystem` (clientleafsystem.cpp:314) reinserts a renderable into the leaves only when it moved, and does it in parallel in PreRender.
- **Budgeted shadows.** `r_shadowmaxrendered` 32 (clientshadowmgr.cpp:685, 4050). A shadow texture is updated only when it is dirty.
- **Threaded material system.** The draw calls are built on the main thread and submitted on another.
- **Native code throughout.** Each of these costs microseconds per entity. FC's equivalent work runs 25-60 us per body in GDScript and per-node callbacks.

## FC at 32 players (staging02 windowed, sim host, cp-orange-x3)

| Phase | FC ms | CS:S equivalent ms | Gap |
| --- | --- | --- | --- |
| Remote bodies: present (pose, held, tag, anim) | 1.48 | SetupBones + DrawModel + UpdateClientSideAnimations about 0.3 | about 1.2 |
| Remote interpolation | 0.97-1.08 | 0.02 | about 1.0 |
| Untimed node `_process` (32 bodies about 0.8, view arms 0.25, the rest small) | 1.9 | SimulateEntities 0.13 | about 1.8 |
| Deferred skeleton and transform updates (pf_tail) | 0.6-0.7 | inside SetupBones | about 0.6 |
| Physics phase (predict 0.82, snapshot apply 0.60, FC physics 1.31) | 2.93 | Prediction 0.03 + net 0.04 + server physics 0.09 | about 2.7 |
| Render CPU | 1.61 | 0.83 (with the render thread) | about 0.8 |
| GPU (parallel) | 2.1-2.5 | not measured | |

The gap is not in rendering. Rendering is 1.6 ms against 0.8 ms. The gap is per-body script work: about 6.8 ms of script against 0.3 ms of native entity code. FC also pays for every remote body every frame. In Source, bodies out of view cost close to nothing.

Note that the bench runs the editor binary. A release export runs GDScript faster, so the script numbers here are an upper bound.

## FC cuts, in priority order

| # | Cut | Where | Expected ms | Status |
| --- | --- | --- | --- | --- |
| 1 | Dormant bodies out of sight: present at most 10 Hz (from 30 Hz), and a thinned body's figure stops its own per-frame floor ray (`cl_remote_dormant`) | FC | measured 0.1 | not kept, see below |
| 2 | Drive each body's figure and held gun from the present loop: one call per body, no `_process` callbacks, nothing for a body that is thinned | dot-player-char, fc-weapons | 0.5-0.8 (of the 0.81 in body subtrees) | board item |
| 3 | Bone setup off the main thread (Source's threaded bone setup): step the figures' clips on the WorkerThreadPool and write the skeletons on the main thread | dot-player-char | 0.6-1.0 (r_anim 0.44-0.75 + pf_tail 0.6) | board item |
| 4 | An interpolation list: skip remote identities whose bracket has not changed (a standing or dead body) | dot-net | 0.3-0.5 | board item; a cache inside the math reached only 0.45 |
| 5 | Run FC's `_net_state_applied` hooks only for fields that changed (0.6-0.85 ms per snapshot) | FC + dot-net | 0.3-0.5 | board item |
| 6 | Render thread (`thread_model=2`), as Source's threaded material system does | engine | about 1 | perf-render-thread-1 (crashes on 4.7.2) |
| 7 | Occlusion dormancy: treat a body in the frustum but behind the level's occluders as out of sight | FC | 0.1-0.3 on open maps | board item |
| 8 | Bench a release export, not the editor binary | tools | measurement, not a cut | board item |

## Cut 1, measured

Measured on staging02, windowed, `--sim-host 1` (all six runs: "sim host: hosted true, map cp-orange-x3, players 32"), n=3, A = `--dormant 0`, B = dormant on. Logs: `/home/gamedev/perf-bench/20261113-1{61902,63732,64849}-staging02-arena-csscompare-A.log` and `-1{63454,64021,65242}-...-B.log`.

| Measure | A (30 Hz) | B (dormant) | Delta |
| --- | --- | --- | --- |
| frame p50 | 10.89 / 11.34 / 11.44 | 10.90 / 11.01 / 11.47 | -0.10 (noise) |
| frame avg | 11.12 / 11.48 / 11.60 | 11.03 / 11.18 / 11.68 | -0.10 (noise) |
| frame p99 | 19.21 / 19.14 / 19.82 | 18.70 / 19.12 / 20.21 | -0.05 |
| arena.present | 3.64 | 3.51 | -0.12 |
| arena.bodies | 1.83 | 1.73 | -0.10 |
| arena.r_anim | 0.52 | 0.52 | 0 |
| ticks/s, dropped | 66.0, 0 | 66.0, 0 | 0 |

The gain is about 0.1 ms, far below the 0.6 ms bar, so the code was not kept (the patch is at `/home/gamedev/perf-bench/cl_remote_dormant-20261113.patch`). The reason is that FC's frustum LOD already does most of what Source's dormancy does: an out-of-sight body was presented at 30 Hz with its clip stepped at 10 Hz and its held gun's `_process` off. Going from 30 Hz to 10 Hz saves only the cheap part of the present, and a figure's floor ray costs little when the body has not moved. What remains is the per-body cost of bodies **in view** (cuts 2-5), which Source keeps cheap with native code, a lazy bone cache and threaded bone setup, not by skipping bodies.

Board items: cut 2 `perf-body-process-from-present-1`, cut 3 `perf-threaded-bone-setup-1`, cut 4 noted on `perf-client-native-body-1`, cut 5 `fc-net-state-hook-cost`, cut 6 `perf-render-thread-1`, cut 7 `perf-occlusion-dormant-1`, cut 8 `perf-bench-release-export-1`.
