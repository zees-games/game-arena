#!/usr/bin/env bash
# Renders the M map picker at 1080p. Imports first so a fresh box has the class cache.
set -uo pipefail
cd "$(dirname "$0")/.."
godot --headless --path . --import >/dev/null 2>&1 || true
xvfb-run -a godot --path . --resolution 1920x1080 --script tools/render_maps.gd
