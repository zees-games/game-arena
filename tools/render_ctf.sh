#!/usr/bin/env bash
# The real offline client on a full capture-the-flag map: stands at each team's flag, walks onto the enemy flag, carries it home
# and captures, saving frames (screenshots/ctf/*.png) and failing on any defect.
#
#   tools/render_ctf.sh                       # cp-orange-x3
#   tools/render_ctf.sh dm_atrium             # a stock map
set -euo pipefail
cd "$(dirname "$0")/.."
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-8} DOT_SHOT_SECS=${DOT_SHOT_SECS:-1}
map="${1:-cp-orange-x3}"
exec timeout 600 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_ctf.gd -- --map "$map"
