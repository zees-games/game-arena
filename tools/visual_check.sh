#!/usr/bin/env bash
# Renders the standard map shots and compares them to tests/golden/<map>_<shot>.png.
#
#   tools/visual_check.sh                 every built-in map
#   tools/visual_check.sh dm_box          one map
#   tools/visual_check.sh --update [MAP]  re-record the goldens (look at them first)
#
# Frames are 800x450 (RESOLUTION) to keep the goldens small. Tolerances for GPU noise:
# VISUAL_PIXEL_TOL, VISUAL_MAX_PCT, VISUAL_MAX_MEAN (see visual_compare.py). A failing frame
# leaves golden | frame | diff in .godot/test-logs/visual/. GPU_OFFLOAD=0 renders locally.
set -uo pipefail
cd "$(dirname "$0")/.."

update=0
maps=()
for arg in "$@"; do
    case "$arg" in
        --update) update=1 ;;
        *) maps+=("$arg") ;;
    esac
done
[ ${#maps[@]} -eq 0 ] && maps=(dm_box dm_atrium dm_pit)

out=.godot/test-logs/visual
mkdir -p "$out" tests/golden
export RESOLUTION="${RESOLUTION:-800x450}"
failed=0
total=0

for map in "${maps[@]}"; do
    rm -f screenshots/"${map}"_{overview,eye,roof}.png
    if ! heavy -- timeout 600 tools/screenshot.sh "$map" >"$out/$map.log" 2>&1; then
        echo "FAIL $map: render failed, see $out/$map.log"
        failed=$((failed + 1))
        continue
    fi
    bad=0
    for shot in overview eye roof; do
        frame="screenshots/${map}_${shot}.png"
        golden="tests/golden/${map}_${shot}.png"
        total=$((total + 1))
        if [ ! -s "$frame" ]; then
            echo "FAIL $map $shot: no frame written, see $out/$map.log"
            bad=1
        elif [ $update -eq 1 ]; then
            cp "$frame" "$golden"
        elif [ ! -f "$golden" ]; then
            echo "FAIL $map $shot: no golden $golden; run tools/visual_check.sh --update $map"
            bad=1
        elif ! python3 -I tools/visual_compare.py "$golden" "$frame" "$out/${map}_${shot}_diff.png" | tee -a "$out/$map.compare" | grep -v '^ok'; then
            :
        fi
    done
    if [ $update -eq 0 ]; then
        grep -q '^FAIL' "$out/$map.compare" 2>/dev/null && bad=1
        rm -f "$out/$map.compare"
    fi
    if [ $bad -eq 1 ]; then failed=$((failed + 1)); echo "map $map: FAIL"; else echo "map $map: ok"; fi
done

echo "visual: $((${#maps[@]} - failed))/${#maps[@]} maps ok, $total frames$([ $update -eq 1 ] && echo ' (goldens updated)')"
[ $failed -eq 0 ]
