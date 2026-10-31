#!/usr/bin/env bash
# Renders the view model against a wall (see tools/render_wall_lean.gd) to screenshots/wall_lean/, and a contact sheet if PIL is there.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -f screenshots/wall_lean/*.png
timeout 500 xvfb-run -a godot --path . --resolution 480x270 --script res://tools/render_wall_lean.gd -- "$@"
python3 - <<'PY' || true
from PIL import Image
import glob
fs = sorted(glob.glob("screenshots/wall_lean/d*.png"))
if fs:
    ims = [Image.open(f) for f in fs]
    w, h = ims[0].size
    sheet = Image.new("RGB", (w * 5, h * 3))
    for i, im in enumerate(ims):
        sheet.paste(im, ((i % 5) * w, (i // 5) * h))
    sheet.save("screenshots/wall_lean/sheet.png")
PY
