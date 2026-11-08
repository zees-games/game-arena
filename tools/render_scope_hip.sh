#!/usr/bin/env bash
# Every frame of a scoped rifle's raise, hip, aim-in, release and sprint, plus contact sheets
# (screenshots/scope_hip/<role>_<phase>_sheet.png). See tools/render_scope_hip.gd.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf screenshots/scope_hip
xvfb-run -a -s "-screen 0 1280x720x24" timeout 600 godot --path . --resolution 1280x720 --script tools/render_scope_hip.gd 2>&1 | grep -E 'ERROR|SCRIPT|no def|scope_hip' | head -20 || true
cd screenshots/scope_hip
for r in $(ls | sed -n 's/^\(.*\)_raise_000\.png$/\1/p'); do
  for p in raise hip aimin release sprint; do
    montage $(ls ${r}_${p}_[0-9][0-9][0-9].png | awk 'NR%3==1') -tile 4x -geometry 320x180+1+1 ${r}_${p}_sheet.png 2>/dev/null || true
  done
done
