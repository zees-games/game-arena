#!/usr/bin/env bash
# Flies the arena's third-person and chase cameras round every spawn of a map, fails on any
# frame inside the level, and draws the worst case before and after the probe, plus a body
# between the camera and the player and one walking into the first-person camera.
#
#   tools/render_cameras.sh            # dm_box
#   tools/render_cameras.sh dm_atrium
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-dm_box}"
exec timeout 300 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_cameras.gd -- --map "$map"
