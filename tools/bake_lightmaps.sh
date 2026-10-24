#!/usr/bin/env bash
# Bake the maps' light: one lightmaps/<id>.res per map, which the game's pack ships and a client
# lays over the map it builds (ArenaMap._attach_bake; dot-lighting's DotLightBake).
#
#   tools/bake_lightmaps.sh                    # every built-in map
#   tools/bake_lightmaps.sh dm_box dm_pit   # these
#   BAKE_LOCAL=1 tools/bake_lightmaps.sh       # on this machine, not the GPU box
#
# Two steps: tools/lightmap_scenes.tscn writes a bake scene per map into lightbake_work/
# (gitignored), then the editor bakes them (dot-lighting's editor plugin, enabled in
# project.godot and inert without its flag). Both need a renderer and the bake needs Vulkan.
#
# By default both run on the family's GPU box through ../gpu.sh (a real card bakes a map in
# seconds; Mesa's software Vulkan on the VMs is enough in principle and takes many minutes), and
# lightmaps/ is copied back. BAKE_LOCAL=1 runs here with xvfb-run; on the family's VMs put it
# through `heavy`. Commit lightmaps/ afterwards: a map changed without a rebake is drawn with the live
# sun and a WARN until it is baked again.
set -euo pipefail
cd "$(dirname "$0")/.."
project="$(basename "$PWD")"
maps=$(IFS=,; echo "$*")
scenes=(res://tools/lightmap_scenes.tscn -- --out=res://lightbake_work ${maps:+--maps=$maps})
bake=(--editor --rendering-method forward_plus -- --dot-bake-lightmaps=res://lightbake_work)
log=.godot/dot-light-bake.log
mkdir -p .godot

if [[ -z "${BAKE_LOCAL:-}" && -x ../gpu.sh ]]; then
    GPU_SCENES_TIMEOUT="${GPU_SCENES_TIMEOUT:-900}"
    [[ "$GPU_SCENES_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "GPU_SCENES_TIMEOUT must be a positive whole number of seconds, not '$GPU_SCENES_TIMEOUT'" >&2; exit 2; }
    rm -rf lightbake_work
    # A step that hangs must end with a way out, never a silent wait.
    rc=0; timeout "$GPU_SCENES_TIMEOUT" ../gpu.sh run "$project" "${scenes[@]}" > "$log.scenes" 2>&1 || rc=$?
    grep -E '^LIGHTMAP_SCENE|ERROR' "$log.scenes" || true
    if [[ $rc -eq 124 ]]; then
        echo "the GPU box did not finish writing scenes in ${GPU_SCENES_TIMEOUT}s (GPU_BOX=${GPU_BOX:-staging}); the remote scenes step may still be running there, check before retrying. Try GPU_BOX=staging02, or BAKE_LOCAL=1 $0 $*" >&2
        exit 1
    elif [[ $rc -ne 0 ]]; then
        echo "the GPU box step that writes scenes failed (exit $rc; ssh or gpu.sh error, see $log.scenes); fix it or run BAKE_LOCAL=1 $0 $*" >&2
        exit 1
    fi
    # No sync between the steps: the scenes were written there, and a sync would delete them.
    ../gpu.sh exec timeout "${GPU_TIMEOUT:-1800}" xvfb-run -a -s "-screen 0 1280x720x24" \
        gpu/bin/godot --path "gpu/godot/$project" --rendering-driver vulkan --gpu-index "${GPU_INDEX:-0}" \
        "${bake[@]}" > "$log" 2>&1 || true
    ../gpu.sh pull "$project" lightmaps
else
    GODOT="${GODOT:-godot}"
    rm -rf lightbake_work
    xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . "${scenes[@]}" 2>&1 \
        | grep -E '^LIGHTMAP_SCENE|ERROR' || true
    ls lightbake_work/*.tscn >/dev/null 2>&1 || { echo "no bake scenes were written" >&2; exit 1; }
    xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . --rendering-driver vulkan "${bake[@]}" \
        > "$log" 2>&1 || true
fi

grep -E '^DOT_BAKE' "$log" || true
grep -q '^DOT_BAKE end' "$log" || { echo "the bake did not finish; see $log" >&2; exit 1; }
! grep -q '^DOT_BAKE fail' "$log" || exit 1
ls -l lightmaps/
