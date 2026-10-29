#!/usr/bin/env bash
# Records tools/filmstrip_pace.gd (steady|noisy) at 60 fps into out/pace_<mode>.avi and prints its PACE line.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out
mode=${1:-noisy}
timeout 200 xvfb-run -a godot --path . --resolution 960x540 --fixed-fps 60 --write-movie "out/pace_$mode.avi" \
  --script res://tools/filmstrip_pace.gd -- "$mode" 2>&1 | grep -E "PACE|pace:|ERROR|SCRIPT" || true
# Consecutive frames, 24 per sheet at 60 fps, from two moments, cropped to the person.
for at in 2.0 4.0; do
  ffmpeg -v error -y -ss "$at" -i "out/pace_$mode.avi" -t 0.4 \
    -vf "crop=480:480:240:30,scale=240:240,tile=8x3" -frames:v 1 "out/pace_${mode}_${at}.png"
done
rm -f "out/pace_$mode.avi"
