#!/usr/bin/env bash
# Every magazine weapon's first-person reload, frame by frame, with the one-arm-set check (tools/render_reload.gd):
# screenshots/reload/<id>_NN.png and <id>_sheet.png. Run it on a GPU box: ../gpu.sh shot game-arena tools/render_reload.sh
#   tools/render_reload.sh [--frames 12 --left 1 --only grenade_launcher,revolver]
# The sheets need PIL; without it (the GPU boxes) they are built where the frames come back.
set -euo pipefail
cd "$(dirname "$0")/.."
out=screenshots/reload
rm -rf "$out"; mkdir -p "$out"
rc=0
xvfb-run -a -s "-screen 0 1920x1080x24" timeout 900 godot --path . --resolution 1920x1080 \
  --script tools/render_reload.gd -- "$@" 2>&1 | grep -E 'arm sets|reload |render_reload|skipped|SCRIPT ERROR|parts shown|style|no sequence|  grip |hand gaps|ended first' | tee "$out/report.txt" || rc=$?
python3 -I - "$out" <<'PY' || true
import glob, os, sys
try:
    from PIL import Image
except ImportError:
    sys.exit("no PIL: frames only, no sheets")
out = sys.argv[1]
ids = sorted({os.path.basename(p).rsplit("_", 1)[0] for p in glob.glob(os.path.join(out, "*_[0-9][0-9].png"))})
for i in ids:
    fs = sorted(glob.glob(os.path.join(out, f"{i}_[0-9][0-9].png")))
    tiles = [Image.open(f).convert("RGB").resize((480, 270)) for f in fs]
    cols = 4
    sheet = Image.new("RGB", (480 * cols, 270 * ((len(tiles) + cols - 1) // cols)))
    for k, t in enumerate(tiles):
        sheet.paste(t, ((k % cols) * 480, (k // cols) * 270))
    sheet.save(os.path.join(out, f"{i}_sheet.png"))
print(f"wrote {len(ids)} sheets in {out}/")
PY
grep -q "0 weapons failed" "$out/report.txt"
