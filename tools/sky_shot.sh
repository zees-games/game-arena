#!/usr/bin/env bash
# Weapon impacts shot into a map's sky, before (sky as plain world) or after the sky split (see sky_shot.gd).
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout 300 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/sky_shot.gd -- "${1:-cp-orange-x3}" "${2:-after}"
