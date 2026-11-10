# The simulation off the render thread

Solo play runs the whole authoritative game (players, bots, weapons, projectiles) inside `_physics_process`, on the thread that also draws. At 24 bots a tick costs 8 to 13 ms of a 15.15 ms budget, so a frame that draws slowly owes two or three ticks, takes longer still, and the game settles at a fraction of the display rate. Making the tick cheaper helps by percents; taking it off the render thread removes it from the frame.

## Stage 1: the solo game in its own process (built, off by default)

Launch with `-- --sim_host 1`. `ArenaSimHost` (`game/arena_sim_host.gd`) starts `scenes/arena_sim_server.tscn` as a second, headless process on a free loopback port, waits for its ready file, and joins it with a `DotClientLink` over UDP. The client then takes the connected path it already has: it predicts its own player, interpolates everyone else from snapshots, and draws. The server process is the same `ArenaModule` on dot-server that a public server runs, so hit registration, lag compensation and every simulation result are the tested online ones; nothing in the simulation changed.

- It is a launch flag, not a console cvar: it is read before the client builds anything, like `--map`.
- Any failure (no server scene, no port, the process dies, no join in time) is logged on `arena.client` and the stock in-process solo game starts instead.
- The server ends a few seconds after its one remote player left, and after two minutes if none ever came. A process cannot ask the OS about its parent, so it watches its sessions.
- The link sits at `/root/ArenaSimServer/Server` in the client because RPCs address nodes by path and that is where the server's node is.
- `tools/perf_bench.sh ... -- --sim-host 1` benches it; the server prints a `SIM_HOST` line with ticks per second and ms per tick. `headless_sim_host` covers the start, the join and the shutdown.

Measured numbers live on the nightly item `arena-perf-bench-1`, not here.

Not covered by stage 1: web and shell-delivered packs (no second process, or no server scene in the pack), solo console commands that change the game (`bot_quota` and friends reach a server only from an admin), and pausing.

## What must stay on the main thread

The scene tree and everything that hangs off it: adding, removing or reparenting nodes, node transforms, `AnimationTree`, `Skeleton3D`, particles, decals, `AudioStreamPlayer` and all effects, UI, input events, and `get_world_3d().direct_space_state` unless the project runs physics on its own thread. `RenderingServer` and `PhysicsServer3D` calls are queued and safe from a thread; `Resource` loading is safe through `ResourceLoader.load_threaded_request`. A script object touched by two threads needs its own lock: GDScript containers are not thread safe for a writer and a reader. Check `DotPlatform.has_threads()` first; the web build without threads must keep the stock path.

So a simulation thread may own plain data (states, commands, the rewind history, shape queries against a space it owns) and must hand the scene a finished snapshot.

## Later stages

1. Default on for desktop solo play once stage 1 has soaked: admin rights for the local player, pause, and the server scene in exported builds.
2. The same server in a thread of the client process, joined through an in-memory transport instead of a socket. It needs the simulation free of scene-tree calls (today `ArenaPlayer` bodies are nodes), which is the real work; it buys web-with-threads and delivered packs.
3. Double-buffered snapshots for presentation: the simulation writes buffer A while the frame reads buffer B, swapped at the tick boundary with one atomic index, so drawing never waits for a tick.
4. Fork-join inside a tick: `WorkerThreadPool.add_group_task` over players for the movement step, joined before weapons resolve, so results stay ordered and identical. Smaller win than moving the tick, and only once the bodies are thread-owned.
