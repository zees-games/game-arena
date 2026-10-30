#!/usr/bin/env bash
# Plays the scripted clips of tools/filmstrip_scenarios.json on GPU box staging02 (xvfb, never
# the desktop session) and brings back screenshots/filmstrip/<clip>_sheet.png, <clip>.mp4 and <clip>_report.txt (foot slide, floor contact, framing, bone pops against tools/filmstrip_thresholds.json).
#   tools/filmstrip.sh [clip...]     # default: every clip
#   FPS=20 tools/filmstrip.sh fire
set -euo pipefail
cd "$(dirname "$0")/.."
out=screenshots/filmstrip
mkdir -p "$out"
clips=("$@")
[[ ${#clips[@]} -gt 0 ]] || mapfile -t clips < <(python3 -c 'import json;print("\n".join(c["name"] for c in json.load(open("tools/filmstrip_scenarios.json"))["clips"]))')
for clip in "${clips[@]}"; do
  GPU_SHOT_BOXES=${GPU_SHOT_BOXES:-staging02} ../gpu.sh shot "$(basename "$PWD")" tools/filmstrip_run.sh "$clip" "${FPS:-60}"
  rsync -az -e "ssh -i ${GPU_KEY:-$HOME/.ssh/gpu-laptop} -o BatchMode=yes" \
    "gamedev@staging02.deacon.internal:gpu/shot/$(basename "$PWD")/$out/$clip.mp4" "gamedev@staging02.deacon.internal:gpu/shot/$(basename "$PWD")/$out/${clip}_report.txt" "$out/"
done
echo "sheets in $out/"
