# CS:S dedicated server baseline

What a stock Counter-Strike: Source dedicated server (srcds, Steam app 232330) spends per tick with 31 bots, measured on this box's Pterodactyl node. It is the yardstick for FC's server tick. FC's own frame-time bench is `tools/perf_bench.sh` ([testing](testing.md#performance-measurement)); results and open findings live on the nightly item `arena-perf-bench-1`. Why CS:S is cheaper, technique by technique, is in [perf-vs-css.md](perf-vs-css.md), [source-server-comparison.md](source-server-comparison.md) and [css-comparison.md](css-comparison.md); this file only holds the measurement and the tool to repeat it.

## Run it

```
tools/css_server_profile.sh                                # 31:66 31:33 15:66 15:33 (bot_quota:sv_maxupdaterate), then stops the server
tools/css_server_profile.sh --configs "31:66 31:33" --secs 120 --keep
```

The script uses only the panel's client API (power, console, files). It starts the server if needed, sets each config, warms up for 30 s, then runs `vprof_reset`, plays 60 s with `stats` every 10 s, and finishes with `vprof_generate_report`, `status` and `net_stats` (`net_stats` is client-only: srcds answers `Unknown command`). The console goes through `con_logfile` into `cstrike/`. The script reads it back and deletes it, then writes each window's log, the panel's CPU samples and a `summary.tsv` to `~christian/perf-logs/external/cstrike/server-pterodactyl/<date>/`. Its `summary.tsv` columns are ms per tick from vprof's inclusive table, with ticks counted as `_Host_RunFrame_Server` calls. `panel_ms_tick` is the panel's `cpu_absolute` turned into ms per 66.7 Hz tick, a cross-check that agrees with vprof to within about 10%.

## The server

- **Panel server:** "CSS Profile (private test)" on https://panel.tmcdev.net, identifier `0f7b8298`, egg "Custom Source Engine Game".
  - Allocation 10.50.0.3:27015. Limits: 2 cores, 1.5 GB.
  - Inside `gameservers.slice` (12 cores, 8 GB) next to the other game containers.
- **Startup:**
  - `srcds_linux64 -game cstrike -tickrate 66 -maxplayers 32 -insecure +sv_lan 1 +map de_dust2`.
  - `cstrike/cfg/server.cfg` sets `sv_cheats 1` (needed for vprof), a password and no rcon, with `bot_quota 31`, `bot_quota_mode fill`, `bot_difficulty 2`, `mp_autoteambalance 0` and no time or round limit.
  - The server is private and LAN-only.
- **Stopped when idle.** Start it from the panel, or let the script start it.
- **Installed by hand, not by the egg.** SteamCMD on this box logs in anonymously, then times out on the app info request for 232330 (in the egg installer and from the host network alike). The volume was therefore filled from the local SteamCMD copy in `/home/gamedev/projects/mapsrc/basegame/232330`.
  - That depot has no 64-bit `bin/linux64/libsteam_api.so`, so the copy from app 232250 (TF2) was added, as on the earlier staging02 run.
  - The volume's `steamcmd/` directory is renamed `steamcmd.off`, so the image's entrypoint does not hang on the same update at each start.
  - Reinstalling the server from the panel undoes all of this.

## Results (2026-11-13, x-tmc-dev)

Ten 60 s windows on de_dust2 at tick 66.7, 0 humans. Every number is ms per tick, inclusive.

| run | bots | maxupdaterate | server frame | `GameFrame` | bots (`CBotManager::StartFrame`) | `PlayerRunCommand` | BoxTrace / tick | peak frame | panel CPU ms/tick |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A1 | 31 | 66 | 2.70 | 2.64 | 1.16 | 0.95 | | 16.7 | 2.86 |
| A2 | 31 | 33 | 4.48 | 4.43 | 2.41 | 1.38 | | 13.8 | 5.07 |
| A3 | 15 | 66 | 1.77 | 1.72 | 0.58 | 0.73 | | 18.1 | 2.41 |
| A4 | 15 | 33 | 1.46 | 1.40 | 0.35 | 0.66 | | 7.8 | 2.13 |
| B1 | 31 | 33 | 1.64 | 1.61 | 0.82 | 0.51 | 509 | 10.1 | 1.37 |
| B2 | 31 | 66 | 3.12 | 3.08 | 1.86 | 0.87 | 1073 | 7.6 | 2.96 |
| B3 | 31 | 33 | 1.29 | 1.26 | 0.49 | 0.50 | 300 | 6.2 | 1.68 |
| B4 | 31 | 66 | 2.20 | 2.17 | 1.12 | 0.72 | 548 | 5.5 | 2.48 |
| B5 | 15 | 33 | 1.25 | 1.21 | 0.51 | 0.46 | 316 | 6.3 | 1.62 |
| B6 | 15 | 66 | 1.28 | 1.25 | 0.53 | 0.48 | 293 | 6.6 | 1.55 |

Raw logs: `server-pterodactyl/20261113-164248/` (run A, load average about 13 on 20 cores) and `20261113-164932/` (run B, interleaved, load average about 5).

- **31 bots cost 1.3-4.5 ms per tick (median about 2.4).** The bots take 0.5-2.4 ms of that (16-78 µs per bot-tick) and the players' movement 0.5-1.4 ms (16-45 µs per player-tick). Everything else in `GameFrame` stays under 0.5 ms.
- **The spread comes from the match, not the settings.** Cost follows the number of traces: 300 BoxTraces a tick cost 1.3 ms and 1073 cost 3.1 ms. Bots that see each other run `CCSBot::IsVisible` and the threat scans, and a round where everyone is dead or hiding is cheap. Compare two configs with several interleaved windows, never one each.
- **`sv_maxupdaterate` 33 vs 66 makes no difference.** At 31 bots, rate 33 gave 4.48, 1.64 and 1.29 ms, and rate 66 gave 2.70, 3.12 and 2.20. Bots receive no snapshots (`SendClientMessages` is about 0.001 ms a tick), so the rate only matters with human clients. Measuring it needs real clients connected.
- **15 bots against 31 roughly halves the bots' share** in matching match states (A3/A4 against A1/A2). Against a quiet 31-bot round (B3) the totals are equal, which is the same match-state effect.
- **The peak frame (5-18 ms) follows the box's load** (13 in run A, 5 in run B), not the config: other containers and agent builds share the cores.

## Against the other measurements

| measurement | server ms per tick at 31-32 bots | bots | per player-tick |
| --- | ---: | ---: | ---: |
| this server (srcds_linux64, Pterodactyl, x-tmc-dev) | 1.3-4.5, median about 2.4 | 0.5-2.4 ms | 16-45 µs (`PlayerRunCommand`) |
| owner's listen server, 32 bots (`perf-logs/external/cstrike/vprof_report_32bots.log`) | 1.40 and 1.90 (two reports, `_Host_RunFrame_Server` per call) | 0.66 and 0.83 ms | 28 µs (`CBasePlayer::PhysicsSimulate`, exclusive) |
| srcds on staging02, 32 bots, 3 × 120 s ([perf-vs-css.md](perf-vs-css.md)) | 2.5-2.8 process CPU, `GameFrame` 1.8-2.0 | 0.85-0.98 ms | 20-23 µs |
| FC server, 31 bots (`tools/perf_bench.sh`, sim host) | about 11.7 | about 106 µs per bot-tick | about 113 µs |

- **CS:S runs the same 31-bot load for 2.4 ms against FC's 11.7: about 5 times less.** The bounds are 2.6x at CS:S's busiest window and 9x at its quietest.
  - The gap is the same per part: a CS:S bot costs 16-78 µs a tick against FC's about 106, and a player's movement 16-45 µs against about 113.
  - Since CS:S's own cost moves 3x with what the bots are doing, an FC bench should be compared with CS:S windows of similar fighting density, not with the best one.
- **The listen server is cheaper per tick than this dedicated server** (1.4-1.9 against 2.4 ms). Its process does not share 20 loaded cores with the fleet, and its scopes start lower (`_Host_RunFrame_Server` per call). Use the dedicated numbers for FC's server, since both are headless servers on shared Linux hosts.
