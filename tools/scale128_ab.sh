#!/usr/bin/env bash
# Same-box A/B for bot_fast_sense: A (FAST=0) and B (FAST=1) interleaved per cell, REPS reps.
#   tools/scale128_ab.sh "32 64 128" 33 30 2   -> $OUT.A / $OUT.B (jsonl)
cd "$(dirname "$0")/.."
NS=${1:-"32 64 128"}; HZ=${2:-33}; SECS=${3:-30}; REPS=${4:-2}; OUT=${OUT:-scale128-ab}
for r in $(seq "$REPS"); do for n in $NS; do
  for arm in A B; do f=0; [ $arm = B ] && f=1
    FAST=$f OUT=$OUT.$arm tools/scale128.sh server "$n" "$HZ" "$SECS" >/dev/null
  done
done; done
echo AB_DONE
