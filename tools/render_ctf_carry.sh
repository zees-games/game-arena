#!/usr/bin/env bash
# Carrying a flag in the real offline client: a bot carrier from the front and both sides, the carrier's own shoulder view
# (both hands) and a flag thrown with the drop key, in flight and at rest (screenshots/ctf_carry/*.png), failing on any defect.
#
#   tools/render_ctf_carry.sh                 # dm_atrium
set -euo pipefail
cd "$(dirname "$0")/.."
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-8} DOT_SHOT_SECS=${DOT_SHOT_SECS:-1}
map="${1:-dm_atrium}"
exec timeout 600 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_ctf_carry.gd -- --map "$map"
