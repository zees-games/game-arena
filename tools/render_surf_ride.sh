#!/usr/bin/env bash
# Plays the offline client on a combat surf map and photographs a bot riding one of the map's
# ride edges, from behind and above, every 0.25 s, into screenshots/surf_ride_<map>_NN.png.
# See tools/render_surf_ride.gd.
#
#   tools/render_surf_ride.sh                              # surf_10x_reloaded_fixed, edge 0
#   tools/render_surf_ride.sh surf_110b_austinpowers 1     # a map and an edge
#
# Needs xvfb-run: under --headless every frame it saves is empty.
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout 300 xvfb-run -a godot --path . --resolution 1280x720 \
  --script res://tools/render_surf_ride.gd -- --map "${1:-surf_10x_reloaded_fixed}" --edge "${2:-0}"
