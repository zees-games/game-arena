#!/usr/bin/env bash
# Same-box interleaved sweep of bot_threads (nightly arena-128-scale-6): for each rep, each bot count, each thread
# count in turn, one server cell. Output: $OUT.t<threads> (jsonl, one SCALE128 line per cell).
#   tools/scale128_threads.sh "64 128" "0 1 2 4 8" 33 30 2
cd "$(dirname "$0")/.."
NS=${1:-"64 128"}; TS=${2:-"0 1 2 4 8"}; HZ=${3:-33}; SECS=${4:-30}; REPS=${5:-2}; OUT=${OUT:-scale128-threads}
for r in $(seq "$REPS"); do for n in $NS; do for t in $TS; do
  THREADS=$t OUT=$OUT.t$t tools/scale128.sh server "$n" "$HZ" "$SECS" >/dev/null
done; done; done
echo SWEEP_DONE
