#!/usr/bin/env bash
# Plays the offline client and saves the health bars and name tags to screenshots/tags_*.png.
# Needs xvfb-run: under --headless every frame it saves is empty.
set -euo pipefail
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-8} DOT_SHOT_SECS=${DOT_SHOT_SECS:-1}
cd "$(dirname "$0")/.."
exec timeout 400 xvfb-run -a godot --path . --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1280x720 \
  --script res://tools/screenshot_tags.gd -- "$@"
