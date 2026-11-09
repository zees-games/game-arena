#!/usr/bin/env bash
# Carrying a flag in the real offline client: a bot carrier from the front and both sides, the carrier's own shoulder view
# (both hands) and a flag thrown with the drop key, in flight and at rest (screenshots/ctf_carry/*.png), failing on any defect.
#
#   tools/render_ctf_carry.sh                 # dm_atrium
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-dm_atrium}"
exec timeout 600 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_ctf_carry.gd -- --map "$map"
