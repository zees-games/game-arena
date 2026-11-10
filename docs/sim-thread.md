# The simulation off the render thread

Solo play runs the whole authoritative game (players, bots, weapons, projectiles) inside `_physics_process`, on the thread that also draws. At 24 bots a tick costs 8 to 13 ms of a 15.15 ms budget, so a frame that draws slowly owes two or three ticks, takes longer still, and the game settles at a fraction of the display rate. Making the tick cheaper helps by percents; taking it off the render thread removes it from the frame.

## Stage 1: the solo game in its own process (on by default)

The game launched as itself (`game/arena.tscn` the current scene) on a desktop build hosts; `-- --sim_host 0` opts out, `-- --sim_host 1` forces it. A suite, a tool or a shell that instances the client in its own scene stays in-process unless it sets `ArenaSimHost.forced`. `ArenaSimHost` (`game/arena_sim_host.gd`) starts the same executable again as a second, headless process on a free loopback port (`--headless --log-file user://logs/sim_server.log -- --sim_server 1 --port N ...`); that process runs the main scene, which hands over to `scenes/arena_sim_server.tscn` at once. No scene path or `--path` goes on the child's command line: a release export refuses both ("compiled without support for path overrides"). The host waits for the child's ready file; if the child dies while booting, the fallback line carries its exit code and the last errors of its log. Then the host joins it with a `DotClientLink` over UDP. The client then takes the connected path it already has: it predicts its own player, interpolates everyone else from snapshots, and draws. The server process is the same `ArenaModule` on dot-server that a public server runs, so hit registration, lag compensation and every simulation result are the tested online ones; nothing in the simulation changed.

- It is a launch flag, not a console cvar: it is read before the client builds anything, like `--map`.
- `--offline` turns it off: dot-game's `DotGameClient` reads that flag as "no link", so a hosted client under it would play the offline path. dot-bootstrap's `--play`, `--play-export`, `-Play` and `-PlayExport` all pass `--offline`; run the executable directly to get the host.
- Any failure (no server scene, no port, the process dies, no join in time) is logged on `arena.client` and the stock in-process solo game starts instead.
- The server ends a few seconds after its one remote player left, and after two minutes if none ever came. A process cannot ask the OS about its parent, so it watches its sessions.
- The link sits at `/root/ArenaSimServer/Server` in the client because RPCs address nodes by path and that is where the server's node is.
- `tools/perf_bench.sh ... -- --sim-host 1` benches it; the server prints a `SIM_HOST` line with ticks per second and ms per tick. `headless_sim_host` covers the start, the join and the shutdown.

Measured numbers live on the nightly item `arena-perf-bench-1`, not here.

### What the owner of the process can do

The client owns its server process (`ArenaSimOwner`, `game/arena_sim_owner.gd`; the client half is `ArenaHostConsole`). A console line no local command claims goes up as `Ask.HOST` and the answer comes down as the HOST sub-kind of the MORE event (`arena_host_wire.gd`); every other server drops the ask. So `bot_quota` (counted with the player, as solo counts it), `bot_difficulty` (the menu's saved pick and `--bot_difficulty` too), `sv_cheats` and every other server name work at the solo console and as `+name value` launch lines. Three verbs are the owner's own: `host_names` (the names Tab and launch lines learn), `host_change <map|-> [mode]` (what M calls; a pack map is fetched by the client first, both read one `user://`) and `host_pause 0|1` (the game stops ticking; the link and snapshots carry on). The server process plays a map until it is changed: no map clock, so no vote or rotation.

Match end, the kill view, the team menu and chat take the connected paths, the ones a public server tests.

Not covered: web and shell-delivered packs (no second process, or no server scene in the pack), and launches with `--offline`.

## What must stay on the main thread

The scene tree and everything that hangs off it: adding, removing or reparenting nodes, node transforms, `AnimationTree`, `Skeleton3D`, particles, decals, `AudioStreamPlayer` and all effects, UI, input events, and `get_world_3d().direct_space_state` unless the project runs physics on its own thread. `RenderingServer` and `PhysicsServer3D` calls are queued and safe from a thread; `Resource` loading is safe through `ResourceLoader.load_threaded_request`. A script object touched by two threads needs its own lock: GDScript containers are not thread safe for a writer and a reader. Check `DotPlatform.has_threads()` first; the web build without threads must keep the stock path.

So a simulation thread may own plain data (states, commands, the rewind history, shape queries against a space it owns) and must hand the scene a finished snapshot.

## Later stages

1. The `--offline` launches hosted too: dot-game must let a client with a link it was handed play connected under `--offline`.
2. The same server in a thread of the client process, joined through an in-memory transport instead of a socket. It needs the simulation free of scene-tree calls (today `ArenaPlayer` bodies are nodes), which is the real work; it buys web-with-threads and delivered packs.
3. Double-buffered snapshots for presentation: the simulation writes buffer A while the frame reads buffer B, swapped at the tick boundary with one atomic index, so drawing never waits for a tick.
4. Fork-join inside a tick: `WorkerThreadPool.add_group_task` over players for the movement step, joined before weapons resolve, so results stay ordered and identical. Smaller win than moving the tick, and only once the bodies are thread-owned.
