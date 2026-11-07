#!/usr/bin/env bash
# Server 32 bots @66 and offline 32 bots @66, the before/after pair for the bot perf work.
#   sudo -u gamedev env GPU_OFFLOAD=0 /home/gamedev/bin/hv <wt> local tools/scale128_pair.sh OUTFILE [BOTS]
set -u
OUT=${1:-scale128_pair.jsonl}; N=${2:-32}
G="godot --headless --path ."
timeout 300 $G res://tools/scale128.tscn -- --role server --bots $N --tick 66 --seconds 30 2>&1 | grep '^SCALE128 ' | sed 's/^SCALE128 //' >> "$OUT"
timeout 300 $G res://tools/scale128.tscn -- --role offline --bots $N --tick 66 --seconds 20 --cold --cold 2>&1 | grep '^SCALE128 ' | sed 's/^SCALE128 //' >> "$OUT"
