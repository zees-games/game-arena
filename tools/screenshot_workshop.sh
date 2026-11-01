#!/usr/bin/env bash
# The solo map menu with a Workshop map in it, to screenshots/menu_maps_workshop.png (see tools/screenshot_workshop.gd).
# Needs xvfb-run: --headless saves empty frames.
set -euo pipefail
# A short frame sequence beside the still (DotShotSeq), so Nightly -> Review can play and scrub it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-16} DOT_SHOT_SECS=${DOT_SHOT_SECS:-2}
cd "$(dirname "$0")/.."
exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x800}" --script tools/screenshot_workshop.gd
