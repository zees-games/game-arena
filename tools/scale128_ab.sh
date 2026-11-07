#!/usr/bin/env bash
# Same-box A/B, A interleaved with B per cell, REPS reps. ARM=hullgrid (default): A = arena_hull_grid 0, B = 1.
# ARM=hullfast: A = arena_hull_fast 0, B = 1. ARM=worldcoarse: flat-body per-tick candidate list off/on. ARM=all: both.
# ARM=fast: A = bot_fast_sense 0, B = 1.
#   tools/scale128_ab.sh "32 64 128" 33 30 2   -> $OUT.A / $OUT.B (jsonl)
cd "$(dirname "$0")/.."
NS=${1:-"32 64 128"}; HZ=${2:-33}; SECS=${3:-30}; REPS=${4:-2}; OUT=${OUT:-scale128-ab}; ARM=${ARM:-hullgrid}
for r in $(seq "$REPS"); do for n in $NS; do
  for arm in A B; do f=0; [ $arm = B ] && f=1
    if [ "$ARM" = fast ]; then FAST=$f OUT=$OUT.$arm tools/scale128.sh server "$n" "$HZ" "$SECS" >/dev/null
    elif [ "$ARM" = hullfast ]; then HFAST=$f OUT=$OUT.$arm tools/scale128.sh server "$n" "$HZ" "$SECS" >/dev/null
    elif [ "$ARM" = worldcoarse ]; then WCOARSE=$f OUT=$OUT.$arm tools/scale128.sh server "$n" "$HZ" "$SECS" >/dev/null
    elif [ "$ARM" = all ]; then HFAST=$f WCOARSE=$f OUT=$OUT.$arm tools/scale128.sh server "$n" "$HZ" "$SECS" >/dev/null
    else HGRID=$f OUT=$OUT.$arm tools/scale128.sh server "$n" "$HZ" "$SECS" >/dev/null; fi
  done
done; done
echo AB_DONE
