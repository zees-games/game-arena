#!/usr/bin/env bash
# The whole 128-scale matrix in ONE heavy slot (heavy is congested; queueing 25 runs separately takes hours):
#   sudo -u gamedev env GPU_OFFLOAD=0 HV_TIMEOUT=2700 /home/gamedev/bin/hv <wt> local tools/scale128_all.sh OUTDIR
# Writes OUTDIR/{server,offline}.jsonl, net.txt, child.txt. Total about 25 min. Run from the worktree root.
set -u
OUT=${1:-scale128-out}; mkdir -p "$OUT"
G="godot --headless --path ."
for hz in 66 33 22; do for n in 16 32 64 128; do
  echo "== server n=$n hz=$hz" >&2
  timeout 300 $G res://tools/scale128.tscn -- --role server --bots $n --tick $hz --seconds 30 2>&1 | grep '^SCALE128 ' | sed 's/^SCALE128 //' >> "$OUT/server.jsonl"
done; done
for spec in "16 66" "32 66" "64 66" "128 33"; do set -- $spec
  echo "== offline n=$1 hz=$2" >&2
  timeout 300 $G res://tools/scale128.tscn -- --role offline --bots $1 --tick $2 --seconds 20 2>&1 | grep '^SCALE128 ' | sed 's/^SCALE128 //' >> "$OUT/offline.jsonl"
done
for n in 16 32 64 128; do
  echo "== net n=$n" >&2
  timeout 200 $G res://tools/net_probe.tscn -- --bots $n --seconds 15 2>&1 | tail -6 | sed "s/^/n=$n /" >> "$OUT/net.txt"
done
for spec in "16 66" "32 66" "64 33"; do set -- $spec
  echo "== child n=$1 hz=$2" >&2
  timeout 200 $G res://tools/client_bench.tscn -- --bots $1 --tick $2 --delay 0 --seconds 15 2>&1 | grep -E 'client_bench|server:|net:|frame|fps|input' | sed "s/^/n=$1 hz=$2 /" >> "$OUT/child.txt"
done
echo finished >&2
