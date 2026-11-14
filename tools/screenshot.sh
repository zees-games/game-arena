#!/usr/bin/env bash
# Renders a map to screenshots/<map>_{overview,eye,roof}.png so a person can look at it.
#
#   tools/screenshot.sh dm_atrium
#   tools/screenshot.sh --weapon-drops [out.png]   # dropped weapons settled on floor, step; any sunk one shows
#   tools/screenshot.sh --profiler-menu [out.png]   # the real client, menu on Advanced, Performance card
#   tools/screenshot.sh --map-menu [dir]   # the solo map picker (M), every page
#   tools/screenshot.sh --map-drop [dir] [convert folder] [map id]   # a map dropped on the solo window: toasts, M, then the map
#   tools/screenshot.sh --team-menu-key [--unwired] [out.png]   # the period key in the real client (or a bare menu: Play, Spectate)
#   tools/screenshot.sh --team-menu   # the team menu: two teams, four renamed, free-for-all
#   tools/screenshot.sh dm_box --admin   # a beacon, a beacon behind a wall, a blind
#   tools/screenshot.sh dm_box --feel --muzzle --weapons=smg:3,knife:1   # first-person frames of chosen weapons (id:slot)
#   tools/screenshot.sh dm_box --action emote dance   # a figure playing an avatar action (pose sit, gesture wave)
#   RENDERER=gl_compatibility tools/screenshot.sh dm_box   # what the client shell draws
#   tools/screenshot.sh dm_atrium --glance [tdm]   # the whole HUD over a real match
#   tools/screenshot.sh dm_atrium --glance --dead   # the local player dead: no crosshair, no hands
#   tools/screenshot.sh dm_atrium --glance --killcam   # the dead player watching the kill view of the bot that killed them
#   tools/screenshot.sh dm_box --glance --map-ballot   # under the 7-row map ballot (--ballot: the 6-row game vote)
#   RESOLUTION=1280x960 SHOT_SUFFIX=_1280x960 tools/screenshot.sh dm_box --glance   # 4:3
#   RESOLUTION=854x480 tools/screenshot.sh dm_box --glance --chat   # a full chat log beside the scaled HUD
#
# Uses xvfb-run because this needs a rendering context and the machines this runs on
# have no display. Nothing here is headless-safe: `--headless` gives a null renderer and
# every frame it saves is empty, which is worse than no screenshot because it looks like
# one.
set -euo pipefail
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play and scrub it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-16} DOT_SHOT_SECS=${DOT_SHOT_SECS:-2}
cd "$(dirname "$0")/.."
# RENDERER picks the rendering method. The client shell runs gl_compatibility everywhere,
# and a look tuned under the editor's default (Forward+) can come out clipped to white
# there; see docs/maps.md, "Colour and light".
# With no Vulkan GPU (dev02 and PH when gpu.sh finds no box free), Forward+ runs on lavapipe, and
# Debian 13's lavapipe (LLVM 19, on these VMs' QEMU CPU) dies in LLVM's InstCombine compiling the
# first 3D material: "propagate_notification" from a thread, then signal 11 (fc-windowed-client-crash-1).
# Such a run draws with gl_compatibility unless RENDERER is set (RENDERER= keeps the project default).
if [ -z "${RENDERER+x}" ] && ! vulkaninfo --summary 2>/dev/null | grep -qE 'PHYSICAL_DEVICE_TYPE_(DISCRETE|INTEGRATED)_GPU'; then
  RENDERER=gl_compatibility
  echo "screenshot.sh: no Vulkan GPU here, drawing with gl_compatibility (Forward+ on lavapipe crashes); RENDERER=forward_plus to force it" >&2
fi
R=(${RENDERER:+--rendering-method "$RENDERER"})
if [ "${1:-}" = "--weapon-drops" ]; then
  shift
  exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" "${R[@]}" --script tools/weapondrop_shot.gd -- "$@"
fi
if [ "${1:-}" = "--profiler-menu" ]; then
  shift
  exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" "${R[@]}" --script tools/profiler_menu_shot.gd -- "$@"
fi
if [ "${1:-}" = "--map-drop" ]; then
  shift
  exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" "${R[@]}" --script tools/local_map_drop_shot.gd -- "$@"
fi
if [ "${1:-}" = "--map-menu" ]; then
  shift
  exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" "${R[@]}" --script tools/map_menu_shot.gd -- "$@"
fi
if [ "${1:-}" = "--team-menu-key" ]; then
  shift
  exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" "${R[@]}" --script tools/team_menu_period_shot.gd -- "$@"
fi
if [ "${1:-}" = "--team-menu" ]; then
  exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" "${R[@]}" --script tools/team_menu_shot.gd
fi
map="${1:-dm_box}"
shift || true
exec xvfb-run -a godot --path . --resolution "${RESOLUTION:-1600x900}" "${R[@]}" \
  --script tools/screenshot.gd -- --map "$map" "$@"
