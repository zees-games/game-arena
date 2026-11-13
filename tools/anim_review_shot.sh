#!/usr/bin/env bash
# One animation-review capture on this machine: tools/anim_review.gd plays each weapon's clips, then ffmpeg turns the frames
# into labelled contact sheets (PNG, which gpu.sh brings back from a GPU box) and drops the frames.
# Normally started by tools/anim_review.sh through heavy, which routes *_shot.sh to a GPU box.
#   tools/anim_review_shot.sh [--only rifle,pistol] [--anims reload_empty,draw] [--out screenshots/anim_review]
set -euo pipefail
cd "$(dirname "$0")/.."
out=screenshots/anim_review
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ ${args[i]} == --out ]] && out=${args[i+1]}; done
mkdir -p "$out"
rc=0
xvfb-run -a -s "-screen 0 960x540x24" timeout 3300 "${GODOT:-godot}" --path . --resolution 960x540 --fixed-fps 30 \
  --script tools/anim_review.gd -- --out "$out" --no-turntable "$@" 2>&1 \
  | grep -E '^ANIM(REVIEW|FRAMES) |WEAPON_LAB|SCRIPT ERROR|ERROR: .*(anim_review|weapon_lab)' || rc=$?
# Every second frame (15 per second), eight to a row, each cell labelled with its frame index and time.
sheet() {
  local pattern=$1 count=$2 dest=$3
  local rows=$(( (count + 15) / 16 ))
  ffmpeg -y -loglevel error -framerate 30 -i "$pattern" -vf \
    "scale=240:-2,drawtext=text='#%{n} %{pts\:flt}s':x=4:y=4:fontsize=14:fontcolor=white:box=1:boxcolor=black@0.6,select='not(mod(n\,2))',tile=8x${rows}:padding=2" \
    -frames:v 1 "$dest" || echo "ANIMREVIEW_SHEET failed: $dest"
}
for d in "$out"/*/_frames/fp_*/; do
  [[ -d $d ]] || continue
  clip=$(basename "$d"); w=$(dirname "$(dirname "$d")")
  n=$(find "$d" -name 'f_*.jpg' | wc -l)
  (( n > 0 )) || continue
  sheet "$d/f_%03d.jpg" "$n" "$w/${clip#fp_}_fp_sheet.png"
  [[ -e $d/t_000.jpg ]] && sheet "$d/t_%03d.jpg" "$n" "$w/${clip#fp_}_tp_sheet.png"
done
rm -rf "$out"/*/_frames
echo "anim_review_shot.sh: $(find "$out" -name '*_sheet.png' | wc -l) sheets in $out"
exit $rc
