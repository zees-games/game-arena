#!/usr/bin/env bash
# The floor experiment (tools/floor_bench.gd), windowed on a GPU box as tools/perf_bench.sh runs: dot-bootstrap's gpu.sh run,
# GPU_XORG=1 (the NVIDIA card through a headless Xorg), the same Godot binary and default window. n process runs, logs in
# ~/perf-bench/floor-<stamp>-<i>.log, then the median p50 of each step over the runs.
# Usage: tools/floor_bench.sh [-n 3] [--box staging02] [-- extra bench args, e.g. --bots 31 --warmup 8]
set -u
n=3 box=staging02
while [ $# -gt 0 ]; do case $1 in -n) n=$2; shift 2 ;; --box) box=$2; shift 2 ;; --) shift; break ;; *) break ;; esac; done
dir=$(cd "$(dirname "$0")/.." && pwd)
gpu=${GPU_SH:-/home/gamedev/godot/dot-bootstrap/tools/gpu.sh}
out=$HOME/perf-bench; mkdir -p "$out"
stamp=$(date +%Y%m%d%H%M%S)
logs=()
for i in $(seq 1 "$n"); do
	log=$out/floor-$stamp-$i.log; logs+=("$log")
	GPU_XORG=1 GODOT_ROOT=$(dirname "$dir") GPU_BOX=$box GPU_TIMEOUT=${GPU_TIMEOUT:-900} \
		"$gpu" run "$(basename "$dir")" res://tools/floor_bench.tscn -- --bots 31 --warmup 8 "$@" > "$log" 2>&1
	grep -q FLOOR_DONE "$log" || { echo "floor_bench: run $i did not finish: $log" >&2; tail -5 "$log" >&2; }
done
python3 - "${logs[@]}" <<'PY'
import json, sys, statistics as st
runs = [[json.loads(l.split("FLOOR_ROW ", 1)[1]) for l in open(f, errors="replace") if "FLOOR_ROW " in l] for f in sys.argv[1:]]
order = [r["id"] for r in runs[0]] if runs else []
print("%-16s %7s %7s %6s %6s %6s %5s  %s" % ("step", "p50", "p50s", "gpu", "rcpu", "draws", "n", "what"))
for i in order:
    rows = [r for run in runs for r in run if r["id"] == i]
    p = [r["p50"] for r in rows]
    w = next(r["what"] for r in rows)
    print("%-16s %7.2f %7s %6.2f %6.2f %6d %5d  %s" % (i, st.median(p), "/".join("%.1f" % x for x in p), st.median([r["gpu"] for r in rows]),
        st.median([r["rcpu"] for r in rows]), st.median([r["draws"] for r in rows]), len(rows), w[:60]))
PY
