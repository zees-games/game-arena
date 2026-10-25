#!/usr/bin/env bash
# Ride caches (maps/surf/<id>.surf.json) for every imported surf map that lacks one: --explore finds the edges, --plan fills the rides.
#   tools/surf_rides_all.sh [--maps a,b] [--no-plan] [--replan]     (default: every surf map without a cache; --replan also plans maps that have one)
# Roughly 12 min to explore and 6 to 30 min per edge to plan on one core, so this belongs in the nightly step, one map at a time under heavy.
# A map whose cache already has planned rides is skipped. Bots on a map without a cache strand on their islands (fuzz "stuck > 10 s").
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
maps=""; plan=1; replan=0
while [ $# -gt 0 ]; do
    case "$1" in
        --maps) maps=$2; shift 2 ;;
        --no-plan) plan=0; shift ;;
        --replan) replan=1; shift ;;
        -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -z "$maps" ] && maps=$(ls maps/imported 2>/dev/null | grep '^surf_' | paste -sd,)
mkdir -p .godot/surf-rides
rc=0
for m in ${maps//,/ }; do
    cache=maps/surf/$m.surf.json
    log=.godot/surf-rides/$m.log
    if [ ! -f "$cache" ]; then
        heavy -- timeout 2400 "$GODOT" --headless --path . res://tools/surf_rides.tscn -- "$m" --explore > "$log" 2>&1 || { echo "explore FAIL $m"; rc=1; continue; }
        echo "explored $m"
    elif [ $replan = 0 ] && python3 -I -c 'import json,sys; sys.exit(0 if any(e.get("ride") or e.get("rides") for e in json.load(open(sys.argv[1])).get("edges", [])) else 1)' "$cache"; then
        echo "skip $m (planned)"; continue
    fi
    [ $plan = 1 ] || continue
    heavy -- timeout 5400 "$GODOT" --headless --path . res://tools/surf_rides.tscn -- "$m" --plan >> "$log" 2>&1 || { echo "plan FAIL $m"; rc=1; continue; }
    echo "planned $m"
done
exit $rc
