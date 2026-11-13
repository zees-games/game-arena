#!/usr/bin/env bash
# The 16v16 benchmark on a GPU box: dot-game's tool (addons/dot_game/tools/dot_game_perf_bench.sh), against the owner's profile.
# Present through a headless Xorg, not Xvfb: Xvfb costs the NVIDIA driver ~10 ms/frame of sched_yield spin (gpu.sh ensure_xorg).
export GPU_XORG=${GPU_XORG:-1}
# The reference profile moved from perf-logs/arena to perf-logs/fc; a missing file means "report only", not a crash.
export PERF_BENCH_REF=${PERF_BENCH_REF:-/home/christian/perf-logs/fc/profile-20261108160712-051.json}
[[ -f $PERF_BENCH_REF ]] || { echo "perf_bench: reference profile $PERF_BENCH_REF missing: report only" >&2; export PERF_BENCH_REF=; }
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_perf_bench.sh" "$@"
