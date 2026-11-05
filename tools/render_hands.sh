#!/usr/bin/env bash
# Each weapon's hands from the eye and six sides, at the hip and through the reload (tools/render_hands.gd):
# screenshots/hands/<id>_<moment>_<view>.png. Run it on a GPU box: ../gpu.sh shot game-arena tools/render_hands.sh
#   tools/render_hands.sh [--only pistol,rifle --reload 0.2,0.45,0.75]
set -euo pipefail
cd "$(dirname "$0")/.."
out=screenshots/hands
rm -rf "$out"; mkdir -p "$out"
xvfb-run -a -s "-screen 0 1280x720x24" timeout 900 godot --path . --resolution 1280x720 \
  --script tools/render_hands.gd -- "$@" 2>&1 | grep -E 'render_hands|hand gaps|at: |GDScript backtrace|\[[0-9]+\] |reload [0-9]|skipped|no such|ended before|SCRIPT ERROR|ERROR' | tee "$out/report.txt"
grep -q "render_hands: done" "$out/report.txt"
