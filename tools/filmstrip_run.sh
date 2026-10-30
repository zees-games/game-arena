#!/usr/bin/env bash
# Records one clip of tools/filmstrip_scenarios.json (first-person left, third-person right)
# with --write-movie at a fixed frame rate and makes its contact sheet. Runs where there is
# a display: tools/filmstrip.sh runs it on a GPU box under xvfb.
#   tools/filmstrip_run.sh <clip> [fps]
set -euo pipefail
cd "$(dirname "$0")/.."
clip=${1:?clip}; fps=${2:-60}
out=screenshots/filmstrip
mkdir -p "$out"
timeout "${FILMSTRIP_TIMEOUT:-240}" xvfb-run -a godot --path . --resolution 1280x480 --fixed-fps "$fps" \
  --write-movie "$out/$clip.avi" --script res://tools/filmstrip_capture.gd -- "$clip" 2>&1 | tail -n 40
bash addons/dot_core/tools/dot_filmstrip.sh "$out/$clip.avi" "$out/$clip" --views fp,tp
