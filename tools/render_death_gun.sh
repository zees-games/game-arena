#!/usr/bin/env bash
# A bot shot dead: frames of the body and the gun it held (see render_death_gun.gd).
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-dm_atrium}"
shift || true
exec timeout 300 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_death_gun.gd -- --map "$map" "$@"
