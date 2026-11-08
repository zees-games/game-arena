#!/usr/bin/env bash
# One command: the whole weapon lab, sharded over the GPU boxes (staging = GTX 1660 Ti, staging02 = RTX 2070), pulled back and
# published to ~/docs/weapon-lab/<run>/ with an index.html. Run on dev02 as gamedev (sudo -u gamedev) from the repo/worktree.
#   tools/weapon_lab_all.sh [--run NAME] [--only a,b] [--anims ...] [--no-turntable] [--no-anims]
# Env: LAB_SHARDS (default 4: two per box, which is the box's shot slot limit), LAB_BOXES ("staging staging02", round robin),
#      GODOT_ROOT (a dir holding one symlink per shard, made here), LAB_PUBLISH=0 to skip ~/docs.
# Each shard is its own gpu.sh project (wl-<n>), so gpu.sh's per-project flock and the box's two shot slots keep other agents'
# GPU jobs apart from the lab, and the lab from itself.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
run=$(date +%Y%m%d-%H%M)
pass=()
while (($#)); do
  case $1 in
    --run) run=$2; shift 2 ;;
    *) pass+=("$1"); shift ;;
  esac
done
shards=${LAB_SHARDS:-4}
read -r -a boxes <<<"${LAB_BOXES:-staging staging02}"
gpu=${GPU_SH:-/home/gamedev/godot/dot-bootstrap/tools/gpu.sh}
export GODOT_ROOT=${GODOT_ROOT:-/home/gamedev/wt/.lab-root}
out=${LAB_OUT:-/home/gamedev/weapon-lab/out}/$run
mkdir -p "$GODOT_ROOT" "$out"
pids=()
for ((i = 0; i < shards; i++)); do
  ln -sfn "$repo" "$GODOT_ROOT/wl-$i"
  box=${boxes[i % ${#boxes[@]}]}
  sdir=$out/shard-$i
  mkdir -p "$sdir"
  GPU_SHOT_BOXES=$box "$gpu" shot --pull "$sdir" "wl-$i" tools/weapon_lab.sh --out "$sdir" --shard "$i/$shards" "${pass[@]}" \
    >"$out/shard-$i.log" 2>&1 &
  pids+=($!)
  echo "shard $i/$shards -> $box (pid ${pids[-1]}, log $out/shard-$i.log)"
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=$((fail + 1)); done
echo "$fail of $shards shards returned non-zero"
for ((i = 0; i < shards; i++)); do
  for d in "$out/shard-$i"/*/; do [[ -d $d ]] && mv "$d" "$out/"; done
  cat "$out/shard-$i/report.txt" 2>/dev/null >>"$out/report.txt" || true
done
python3 "$repo/tools/weapon_lab_index.py" "$out" "$run"
if [[ ${LAB_PUBLISH:-1} == 1 ]]; then
  dest=/home/gamedev/docs/weapon-lab/$run
  mkdir -p "$dest"
  rsync -a --exclude 'shard-*' "$out/" "$dest/"
  echo "published: $dest  (https/nightly links: see docs/weapon_lab.md)"
fi
exit $((fail > 0))
