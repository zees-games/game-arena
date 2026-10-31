#!/usr/bin/env bash
# A round through a thin wall: frames of both faces' bullet holes (see render_wallbang.gd).
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-dm_atrium}"
shift || true
exec timeout 300 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_wallbang.gd -- --map "$map" "$@"
