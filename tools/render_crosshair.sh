#!/usr/bin/env bash
# The spread crosshair in each posture (still, moving, crouched, firing, crouched_firing, air): screenshots/crosshair/*.png.
# Needs xvfb-run: under --headless every saved frame is empty.
set -euo pipefail
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play and scrub it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-8} DOT_SHOT_SECS=${DOT_SHOT_SECS:-1}
cd "$(dirname "$0")/.."
rm -f screenshots/crosshair/*.png
timeout 200 xvfb-run -a godot --path . --resolution ${RESOLUTION:-1920x1080} --fixed-fps 64 ${RENDERER:+--rendering-method "$RENDERER"} \
  --script res://tools/render_crosshair.gd -- "$@"
