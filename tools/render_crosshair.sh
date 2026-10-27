#!/usr/bin/env bash
# The spread crosshair open while standing, running and airborne: screenshots/crosshair/{still,moving,air}.png.
# Needs xvfb-run: under --headless every saved frame is empty.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -f screenshots/crosshair/*.png
timeout 200 xvfb-run -a godot --path . --resolution 960x540 --fixed-fps 64 ${RENDERER:+--rendering-method "$RENDERER"} \
  --script res://tools/render_crosshair.gd -- "$@"
