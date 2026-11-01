#!/usr/bin/env bash
# Records every weapon's reload and fire (tools/review_clips.gd) with --write-movie and cuts the movie into
# screenshots/review/<id>__reload.mp4 and <id>__fire.mp4. Needs a display: tools/capture_reviews.sh runs it on a GPU box.
#   tools/review_clips_run.sh [weapon,weapon...]     # default: every weapon
set -euo pipefail
cd "$(dirname "$0")/.."
only=${1:-}; fps=30
out=screenshots/review
rm -rf "$out"; mkdir -p "$out"
extra=(); [[ -n $only ]] && extra=(--only "$only")
timeout "${REVIEW_TIMEOUT:-900}" xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 --fixed-fps "$fps" \
  --write-movie "$out/all.avi" --script res://tools/review_clips.gd -- --fps "$fps" "${extra[@]}" > "$out/run.log" 2>&1 || true
grep -E "^(REVIEW_CLIP|review_clips|.*skipped|.*give failed)|SCRIPT ERROR" "$out/run.log" | head -n 80
n=0
while read -r _ id kind first count; do
  # A loop-friendly clip: h264, no audio, even dimensions.
  ffmpeg -v error -y -i "$out/all.avi" -vf "select=between(n\,$first\,$((first + count - 1))),setpts=N/(FRAME_RATE*TB),scale=960:-2" \
    -an -c:v libx264 -pix_fmt yuv420p -crf 26 -preset fast -movflags +faststart "$out/${id}__${kind}.mp4"
  n=$((n + 1))
done < <(grep "^REVIEW_CLIP" "$out/run.log")
rm -f "$out/all.avi"
echo "review_clips_run: $n clips in $out"
[[ $n -gt 0 ]]
