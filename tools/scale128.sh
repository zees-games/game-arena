#!/usr/bin/env bash
# 128-player scale matrix (nightly arena-128-scale-1). Runs tools/scale128.tscn through heavy,
# one run at a time, and appends each `SCALE128 {json}` line to $OUT (default scale128-<date>.jsonl).
#
#   tools/scale128.sh server  "16 32 64 128" "22 33 66" [SECONDS]   dedicated server, N bots, per tick rate
#   tools/scale128.sh offline "16 32 64" "66" [SECONDS]             in-process offline client, N bots
#   tools/scale128.sh net     "16 32 64 128"                        bytes per client (tools/net_probe.tscn)
#   tools/scale128.sh child   "16 32 64" "66"                       client + CHILD dedicated server process (client_bench)
#   tools/scale128.sh table FILE.jsonl                              print the table
#
# Run it as the work user so heavy gives you that user's slots: sudo -u gamedev tools/scale128.sh ...
set -uo pipefail
cd "$(dirname "$0")/.."
MODE=${1:-server}; NS=${2:-"16 32 64 128"}; HZ=${3:-"66"}; SECS=${4:-30}
OUT=${OUT:-scale128-$(date +%Y%m%d).jsonl}
WT=$PWD
# timing runs stay on dev02 (hv local = heavy local lane, never offloaded)
run() { env GPU_OFFLOAD=0 heavy -- timeout 1500 godot --headless --path . "$@" 2>&1; }
case $MODE in
  server|offline)
    for hz in $HZ; do for n in $NS; do
      echo "== $MODE n=$n hz=$hz" >&2
      run res://tools/scale128.tscn -- --role "$MODE" --bots "$n" --tick "$hz" --seconds "$SECS" ${FAST:+--fastsense $FAST} ${MPROF:+--motorprof 1} ${HGRID:+--hullgrid $HGRID} | grep '^SCALE128 ' | sed 's/^SCALE128 //' | tee -a "$OUT"
    done; done;;
  net)
    for n in $NS; do echo "== net n=$n" >&2; run res://tools/net_probe.tscn -- --bots "$n" --seconds 20 | tail -4 | sed "s/^/n=$n /" | tee -a "$OUT.net"; done;;
  child)
    for hz in $HZ; do for n in $NS; do echo "== child n=$n hz=$hz" >&2
      run res://tools/client_bench.tscn -- --bots "$n" --tick "$hz" --delay 0 --seconds "$SECS" --json | grep -E '^PERF|^server:' | sed "s/^/n=$n hz=$hz /" | tee -a "$OUT.child"
    done; done;;
  table)
    python3 - "$2" <<'PY'
import json,sys
print("%-8s %4s %3s %7s %7s %7s %7s %6s %7s %6s %6s" % ("role","bots","hz","mean","p95","max","budget","ticks%","us/act","rssMB","holds"))
for l in open(sys.argv[1]):
    d=json.loads(l); s=d["script_ms"]
    print("%-8s %4d %3d %7.2f %7.2f %7.2f %7.2f %6.1f %7.1f %6.0f %6s" % (d["role"],d["bots"],d["tick_hz"],s["mean"],s["p95"],s["max"],d["budget_ms"],100*d["tick_ratio"],d["per_actor_us"],d["rss_mb"],d["verdict_holds"]))
PY
  ;;
esac
