#!/usr/bin/env bash
# Renders a map to screenshots/<map>_{overview,eye,roof}.png so a person can look at it.
#
#   tools/screenshot.sh dm_atrium
#   tools/screenshot.sh dm_box --admin   # a beacon, a beacon behind a wall, a blind
#   RENDERER=gl_compatibility tools/screenshot.sh dm_box   # what the client shell draws
#   tools/screenshot.sh dm_atrium --glance [tdm]   # the whole HUD over a real match
#   tools/screenshot.sh dm_box --glance --map-ballot   # under the 7-row map ballot (--ballot: the 6-row game vote)
#   RESOLUTION=1280x960 SHOT_SUFFIX=_1280x960 tools/screenshot.sh dm_box --glance   # 4:3
#   RESOLUTION=854x480 tools/screenshot.sh dm_box --glance --chat   # a full chat log beside the scaled HUD
#
# Uses xvfb-run because this needs a rendering context and the machines this runs on
# have no display. Nothing here is headless-safe: `--headless` gives a null renderer and
# every frame it saves is empty, which is worse than no screenshot because it looks like
# one.
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-dm_box}"
shift || true
# RENDERER picks the rendering method. The client shell runs gl_compatibility everywhere,
# and a look tuned under the editor's default (Forward+) can come out clipped to white
# there; see docs/maps.md, "Colour and light".
exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1600x900}" \
  ${RENDERER:+--rendering-method "$RENDERER"} \
  --script tools/screenshot.gd -- --map "$map" "$@"
