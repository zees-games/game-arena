#!/usr/bin/env bash
# Plays the offline client and photographs a bot from over its shoulder every 0.4 s, at the
# preset named (default medium), into screenshots/bots_<preset>_NN.png. See tools/render_bots.gd.
#
# Needs xvfb-run, because it needs a rendering context: under --headless every frame it
# saves is empty, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout 300 xvfb-run -a godot --path . --resolution 1280x720 \
  --script res://tools/render_bots.gd -- "${1:-medium}"
