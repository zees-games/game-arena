#!/usr/bin/env bash
# Follows a few bots from the side and the front (running, shooting, a forced reload) and joins each bot's frames
# into screenshots/carry/<bot>_{side,front}.png strips. See tools/render_carry.gd. Arguments go to it (--carry 0).
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf screenshots/carry
timeout 300 xvfb-run -a godot --path . --resolution 1280x720 --script res://tools/render_carry.gd -- "$@"
if command -v montage >/dev/null; then
  for f in screenshots/carry/*_side_00.png screenshots/carry/*_front_00.png; do
    [ -e "$f" ] || continue
    base="${f%_00.png}"
    montage "$base"_[0-9][0-9].png -tile 8x -geometry 240x240+2+2 "$base.png"
  done
fi
