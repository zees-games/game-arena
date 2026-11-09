#!/usr/bin/env bash
# The 16v16 benchmark on a GPU box: dot-game's tool (addons/dot_game/tools/dot_game_perf_bench.sh), against the owner's profile.
export PERF_BENCH_REF=${PERF_BENCH_REF:-/home/christian/perf-logs/arena/profile-20261108160712-051.json}
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_perf_bench.sh" "$@"
