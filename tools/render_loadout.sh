#!/usr/bin/env bash
# Renders the loadout menu at 1080p: free (default) and --costed. Imports first so a fresh box has the class cache.
#   GPU_SHOT_BOXES=staging02 ../gpu.sh shot wt-ros-game-arena tools/render_loadout.sh
set -uo pipefail
cd "$(dirname "$0")/.."
godot --headless --path . --import >/dev/null 2>&1 || true
for mode in "" "--costed"; do
  xvfb-run -a godot --path . --resolution 1920x1080 --script tools/render_loadout.gd -- $mode || true
done
