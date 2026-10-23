#!/usr/bin/env bash
# Frames of the end of a solo match: the final killcam, the winner reveal, the scoreboard.
# tools/render_killcam.sh [map] [--reduce-motion]; frames in screenshots/killcam/.
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-dm_atrium}"
shift || true
exec timeout 300 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_killcam.gd -- --map "$map" "$@"
