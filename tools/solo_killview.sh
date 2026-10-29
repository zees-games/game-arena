#!/usr/bin/env bash
# The standalone kill view, as a player sees it: frames in screenshots/solo_killview/. `tools/solo_killview.sh <dir> final` ends the match with the player's own kill instead (the final killcam).
set -euo pipefail
cd "$(dirname "$0")/.."
exec xvfb-run -a godot --path . --resolution 1280x720 --script tools/solo_killview.gd -- "${1:-res://screenshots/solo_killview}" ${2:+"$2"}
