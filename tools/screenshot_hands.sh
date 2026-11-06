#!/usr/bin/env bash
# Hip and aim frames of the weapons named in $1 (comma-separated catalogue ids): tools/screenshot_hands.sh bullpup,revolver
# A screenshot*.sh name so heavy draws it on a GPU box; render_weapons.gd does the work.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf screenshots/weapons
export RENDER_ONLY=${1:?ids}
exec timeout 900 xvfb-run -a -s "-screen 0 ${RES:-1280x720}x24" godot --path . --resolution ${RES:-1280x720} --script tools/render_weapons.gd
