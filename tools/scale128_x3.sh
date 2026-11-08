#!/usr/bin/env bash
# Orange X3 perf on/off bench (nightly perf-x3-onoff-1): dedicated server, 31 bots, 66 Hz, cp-orange-x3, same seed/map.
# Configs interleaved per rep so box drift hits all alike. One jsonl line per run in $OUT, tagged with config and rep.
#   tools/scale128_x3.sh "ON OFF" 5 30          configs, reps, seconds
#   tools/scale128_x3.sh "ON OFF no_skip no_vis no_tiers no_native no_codec" 5 30
# Configs: ON (defaults), OFF (all five switches off), no_<x> (defaults with only x off), only_<x> (OFF with only x on).
# Run as gamedev, with maps/imported_dm linked to the arena-dm-maps checkout that has cp-orange-x3.
# Timing runs: heavy with GPU_OFFLOAD=0 in the env (hv unsets it and offers the run to a remote box; scale128.sh does the same).
# Start nothing else heavy meanwhile.
set -uo pipefail
cd "$(dirname "$0")/.."
WT=$PWD; CONFIGS=${1:-"ON OFF"}; REPS=${2:-5}; SECS=${3:-30}; BOTS=${BOTS:-31}; HZ=${HZ:-66}; MAP=${MAP:-cp-orange-x3}
OUT=${OUT:-x3-onoff-$(date +%Y%m%d-%H%M).jsonl}
flags() { # config -> godot user args
  local s=1 v=1 t=1 n=1 c=1
  case $1 in
    ON) ;;
    OFF) s=0 v=0 t=0 n=0 c=0 ;;
    no_skip) s=0 ;; no_vis) v=0 ;; no_tiers) t=0 ;; no_native) n=0 ;; no_codec) c=0 ;;
    only_skip) s=1 v=0 t=0 n=0 c=0 ;; only_vis) s=0 v=1 t=0 n=0 c=0 ;; only_tiers) s=0 v=0 t=1 n=0 c=0 ;;
    only_native) s=0 v=0 t=0 n=1 c=0 ;; only_codec) s=0 v=0 t=0 n=0 c=1 ;;
  esac
  echo "--skipidle $s --visibility $v --tiers $t --native $n --simcodec $c"
}
for r in $(seq "$REPS"); do for cfg in $CONFIGS; do
  echo "== rep $r config $cfg" >&2
  la=$(cut -d' ' -f1-3 /proc/loadavg)
  env GPU_OFFLOAD=0 PATH=/home/gamedev/.local/bin:$PATH heavy -- timeout 900 godot --headless --path . res://tools/scale128.tscn -- \
    --role server --bots "$BOTS" --tick "$HZ" --seconds "$SECS" --map "$MAP" $(flags "$cfg") 2>&1 \
    | grep '^SCALE128 ' | sed 's/^SCALE128 //' \
    | python3 -c "import sys,json
for l in sys.stdin:
    d=json.loads(l); d['config']='$cfg'; d['rep']=$r; d['loadavg_before']='$la'; print(json.dumps(d))" | tee -a "$OUT"
done; done
echo X3_DONE >&2
