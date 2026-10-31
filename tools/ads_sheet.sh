#!/usr/bin/env bash
# One contact sheet of every weapon's aimed view, centre-cropped and labelled: screenshots/weapons/ads_sheet.png
#   tools/ads_sheet.sh           render every weapon (render_weapons.sh, on a GPU box via gpu.sh), then sheet
#   tools/ads_sheet.sh --sheet   only rebuild the sheet from the frames already in screenshots/weapons
# render_weapons.gd's see-through check is the automatic part: it fails a gun that hides or near-clips the sight line.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--sheet" ]; then
  ../gpu.sh shot game-arena tools/render_weapons.sh
fi
dir=screenshots/weapons
work=$(mktemp -d)
n=0
for f in $(ls "$dir"/*_aim.png | sort); do
  id=$(basename "$f" _aim.png)
  ffmpeg -loglevel error -y -i "$f" -vf "crop=480:360:720:360,drawtext=text='$id':x=8:y=8:fontsize=22:fontcolor=yellow:box=1:boxcolor=black@0.6" "$work/$(printf %03d $n).png"
  n=$((n + 1))
done
cols=6
rows=$(( (n + cols - 1) / cols ))
ffmpeg -loglevel error -y -framerate 1 -i "$work/%03d.png" -vf "tile=${cols}x${rows}" -frames:v 1 "$dir/ads_sheet.png"
rm -rf "$work"
echo "wrote $dir/ads_sheet.png ($n weapons)"
