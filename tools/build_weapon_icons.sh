#!/usr/bin/env bash
# Renders every zee weapon as a white silhouette into assets/weapon_icons/<id>.png, for the
# HUD's kill feed and weapon slots. See tools/build_weapon_icons.gd. Commit the PNGs.
#
# Needs xvfb-run: under --headless every frame it saves is empty.
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout 300 xvfb-run -a godot --path . --resolution 640x256 --script res://tools/build_weapon_icons.gd
