#!/usr/bin/env bash
# The kill view's edge cases with frames: tools/killcam_audit.sh <outdir> <bot|world|fall|killer_dead|killer_left|round>
set -euo pipefail
cd "$(dirname "$0")/.."
exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" --script tools/killcam_audit.gd -- "${1:-res://screenshots/killcam_audit}" "${2:-bot}"
