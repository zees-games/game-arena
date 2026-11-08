#!/usr/bin/env bash
# Capture the flag online: a dedicated server and the real client, the server walks the human onto the flags.
#   tools/play_ctf_online.sh [map]       # cp-orange-x3
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-cp-orange-x3}"
exec timeout 300 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" res://tools/play_ctf_online.tscn -- --map "$map"
