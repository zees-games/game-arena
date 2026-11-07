#!/usr/bin/env bash
# Net and connected-client part of the matrix, in one heavy slot (see scale128_all.sh). OUTDIR/{net,child}.txt
set -u
OUT=${1:-scale128-out}; mkdir -p "$OUT"; G="godot --headless --path ."
for n in 16 32 64 128; do echo "== net n=$n" >&2
  timeout 200 $G res://tools/net_probe.tscn -- --bots $n --seconds 20 2>&1 | tail -6 | sed "s/^/n=$n /" >> "$OUT/net.txt"; done
for spec in "16 66" "32 66" "64 66" "64 33" "128 33"; do set -- $spec; echo "== child n=$1 hz=$2" >&2
  timeout 240 $G res://tools/client_bench.tscn -- --bots $1 --tick $2 --delay 0 --seconds 15 2>&1 | grep -E 'client_bench|server:|net:|frame|fps|input' | sed "s/^/n=$1 hz=$2 /" >> "$OUT/child.txt"; done
echo finished >&2
