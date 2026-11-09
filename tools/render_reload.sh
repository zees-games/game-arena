#!/usr/bin/env bash
# Every magazine weapon's first-person reload, frame by frame, with the one-arm-set check (tools/render_reload.gd):
# screenshots/reload/<id>_NN.png and <id>_sheet.png (the sheet is dot-weapon's DotWeaponReloadShots, built in the script).
# Run it on a GPU box: ../gpu.sh shot game-arena tools/render_reload.sh
#   tools/render_reload.sh [--frames 12 --left 1 --only grenade_launcher,revolver]
set -euo pipefail
cd "$(dirname "$0")/.."
out=screenshots/reload
args=("$@")
for i in "${!args[@]}"; do [ "${args[$i]}" = "--out" ] && out="${args[$((i+1))]}"; done
rm -rf "$out"; mkdir -p "$out"
rc=0
xvfb-run -a -s "-screen 0 1920x1080x24" timeout 900 godot --path . --resolution 1920x1080 \
  --script tools/render_reload.gd -- "$@" 2>&1 | grep -E 'carve|model res|arm sets|magazine|reload |render_reload|skipped|SCRIPT ERROR|parts shown|style|no sequence|  grip |hand gaps|ended first|holds done|not in hand|give failed' | tee "$out/report.txt" || rc=$?
grep -q "render_reload: 0 weapons failed the one-magazine check" "$out/report.txt"
