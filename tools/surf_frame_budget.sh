#!/usr/bin/env bash
# Every combat surf map through the connected client bench on the GPU box; fails on any map whose worst frame
# passes the budget (FRAME_BUDGET_MS, default 120, the cap perf_budget.sh holds). Usage: tools/surf_frame_budget.sh [map ...]
# Exit 0 all inside, 1 a map over budget, 2 a run printed no PERF line.
cd "$(dirname "$0")/.." || exit 2
budget=${FRAME_BUDGET_MS:-120}
maps=("$@")
[ ${#maps[@]} -eq 0 ] && mapfile -t maps < <(cd maps/imported && ls -d surf_* | sort)
rc=0
for m in "${maps[@]}"; do
    line=$(GPU_TIMEOUT=300 timeout -k 10 400 ../gpu.sh run "$(basename "$PWD")" res://tools/client_bench.tscn -- \
        --map "$m" --bots 3 --delay 20 --play --seconds 30 --json 2>&1 | grep -m1 '^PERF ')
    if [ -z "$line" ]; then echo "surf_frame_budget: $m printed no PERF line"; rc=2; continue; fi
    stall=$(python3 -I -c 'import json,sys;print(json.loads(sys.argv[1][5:])["stall_ms"])' "$line")
    if python3 -I -c 'import sys;sys.exit(0 if float(sys.argv[1])<=float(sys.argv[2]) else 1)' "$stall" "$budget"; then
        echo "ok   $m worst frame ${stall} ms"
    else
        echo "FAIL $m worst frame ${stall} ms > ${budget} ms"; [ $rc -eq 0 ] && rc=1
    fi
done
exit $rc
