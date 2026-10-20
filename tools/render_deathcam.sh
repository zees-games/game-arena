#!/usr/bin/env bash
# The solo client's death camera for a death against a wall (see render_deathcam.gd).
#   tools/render_deathcam.sh [map]    # dm_atrium by default; frames in screenshots/deathcam/
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout 300 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_deathcam.gd -- --map "${1:-dm_atrium}"
