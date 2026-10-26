#!/usr/bin/env bash
# The delivered-map suite with a renderer, saving a frame of the map built from its pack.
#
#   tools/render_delivered.sh [out.png]     default screenshots/delivered.png
set -euo pipefail
cd "$(dirname "$0")/.."
exec xvfb-run -a godot --path . --resolution 1280x720 --rendering-method gl_compatibility \
  res://examples/headless_delivered.tscn -- --shot "$(pwd)/${1:-screenshots/delivered.png}"
