#!/usr/bin/env bash
# The weapon lab on one GPU box: every animation of every weapon (or --only a,b / --shard i/n) as frames, strips and mp4s
# (tools/weapon_lab.gd), then ffmpeg on the frames. Normally started by tools/weapon_lab_all.sh through gpu.sh shot.
#   tools/weapon_lab.sh --out /home/gamedev/weapon-lab/out/run1 [--only rifle,pistol] [--shard 0/4] [--anims fire,reload_empty] [--no-turntable]
set -euo pipefail
cd "$(dirname "$0")/.."
out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ ${args[i]} == --out ]] && out=${args[i+1]}; done
[[ -n $out ]] || { echo "weapon_lab.sh: --out DIR is required" >&2; exit 2; }
mkdir -p "$out"
rc=0
xvfb-run -a -s "-screen 0 960x540x24" timeout 3300 godot --path . --resolution 960x540 --fixed-fps 30 \
  --script tools/weapon_lab.gd -- "$@" 2>&1 | grep -E 'WEAPON_LAB|SCRIPT ERROR|ERROR: .*weapon_lab' | tee -a "$out/report.txt" || rc=$?
# frames -> mp4 (h264, yuv420p so every browser plays them); the JPEG frames are dropped afterwards
for d in "$out"/*/_frames/*/; do
  [[ -d $d ]] || continue
  clip=$(basename "$d"); w=$(dirname "$(dirname "$d")")
  [[ $clip == tp_orbit ]] && continue
  ls "$d"/f_*.jpg >/dev/null 2>&1 || continue
  ffmpeg -y -loglevel error -framerate 30 -i "$d/f_%03d.jpg" -c:v libx264 -pix_fmt yuv420p -crf 20 -preset veryfast "$w/$clip.mp4" || echo "WEAPON_LAB ffmpeg failed: $w/$clip"
done
rm -rf "$out"/*/_frames
echo "weapon_lab.sh: $(find "$out" -name '*.mp4' | wc -l) mp4s, $(find "$out" -name '*_strip.png' | wc -l) strips in $out"
exit $rc
