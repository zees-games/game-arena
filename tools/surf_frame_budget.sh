#!/usr/bin/env bash
# Every combat surf map through the connected client bench on the GPU box; fails on any map whose worst frame
# passes the budget (FRAME_BUDGET_MS, default 120, the cap perf_budget.sh holds). Usage: tools/surf_frame_budget.sh [map ...]
# Exit 0 all inside, 1 a map over budget, 2 a run printed no PERF line.
cd "$(dirname "$0")/.." || exit 2
budget=${FRAME_BUDGET_MS:-120}
maps=("$@")
[ ${#maps[@]} -eq 0 ] && mapfile -t maps < <(cd maps/imported && ls -d surf_* | sort)
rc=0
logdir=${SURF_BUDGET_LOGS:-.godot/surf-budget-logs}
mkdir -p "$logdir"
missing=()
# A GPU box whose lock another job holds queues every run here until the timeout; say so up front.
../gpu.sh status 2>/dev/null | grep -q 'lock: HELD' && echo "note: a GPU box lock is HELD; a run may only be waiting its turn (GPU_BOX=staging02 picks the desktop)"
for m in "${maps[@]}"; do
    log="$logdir/$m.log"
    GPU_TIMEOUT=300 timeout -k 10 400 ../gpu.sh run "$(basename "$PWD")" res://tools/client_bench.tscn -- \
        --map "$m" --bots 3 --delay 20 --play --seconds 30 --json >"$log" 2>&1
    run_rc=$?
    line=$(grep -m1 '^PERF ' "$log")
    if [ -z "$line" ]; then
        # No PERF line is a failed measurement, never a pass: say why (timeout, load error, queue) and keep the log.
        why="exit $run_rc"; [ $run_rc -eq 124 ] && why="timed out (a wait for a GPU slot counts)"
        echo "FAIL $m printed NO PERF line ($why); log $log:"
        grep -E "SCRIPT ERROR|ERROR:|load fail|could not|HANG" "$log" | head -3
        tail -2 "$log"
        missing+=("$m"); rc=2; continue
    fi
    stall=$(python3 -I -c 'import json,sys;print(json.loads(sys.argv[1][5:])["stall_ms"])' "$line")
    if python3 -I -c 'import sys;sys.exit(0 if float(sys.argv[1])<=float(sys.argv[2]) else 1)' "$stall" "$budget"; then
        echo "ok   $m worst frame ${stall} ms"
    else
        echo "FAIL $m worst frame ${stall} ms > ${budget} ms"; [ $rc -eq 0 ] && rc=1
    fi
done
[ ${#missing[@]} -gt 0 ] && echo "surf_frame_budget: ${#missing[@]} of ${#maps[@]} maps have NO measurement: ${missing[*]}"
exit $rc
