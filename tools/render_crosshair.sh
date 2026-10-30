#!/usr/bin/env bash
# The spread crosshair in each posture (still, moving, crouched, firing, crouched_firing, air): screenshots/crosshair/*.png.
# Needs xvfb-run: under --headless every saved frame is empty.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -f screenshots/crosshair/*.png
timeout 200 xvfb-run -a godot --path . --resolution ${RESOLUTION:-1920x1080} --fixed-fps 64 ${RENDERER:+--rendering-method "$RENDERER"} \
  --script res://tools/render_crosshair.gd -- "$@"
