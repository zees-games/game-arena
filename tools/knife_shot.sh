#!/usr/bin/env bash
# A knife thrown into a bot and one thrown at the floor: frames (see knife_shot.gd).
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-dm_atrium}"
shift || true
exec timeout 300 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/knife_shot.gd -- --map "$map" "$@"
