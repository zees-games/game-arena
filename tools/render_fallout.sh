#!/usr/bin/env bash
# Photographs where a fall into a combat surf map's biggest teleport volumes puts a player,
# from the player's eye, in six directions, into screenshots/fallout_<map>_<pit>_<n>.png.
# See tools/render_fallout.gd.
#
#   tools/render_fallout.sh surf_ski_2          # the biggest volume's destination
#   tools/render_fallout.sh surf_ski_2,surf_ski_2_source 0,1   # two maps, the two biggest
#
# Needs xvfb-run: under --headless every frame it saves is empty.
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout 300 xvfb-run -a godot --path . --resolution 1280x720 \
  --script res://tools/render_fallout.gd -- --map "${1:?a map id}" --rank "${2:-0}"
