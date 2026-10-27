#!/usr/bin/env bash
# Frames of every skinned weapon role in the hands, and a contact sheet: screenshots/weapons/sheet.png
#   tools/render_weapons.sh            # with the installed weapon packs
#   tools/render_weapons.sh --zee      # zee-dot-weapons' own art, for the comparison
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf screenshots/weapons
extra=()
[ "${1:-}" = "--zee" ] && extra=(-- --arena-no-weapon-skins)
xvfb-run -a -s "-screen 0 1280x720x24" timeout 400 godot --path . --resolution 1280x720 \
  --script tools/render_weapons.gd "${extra[@]}" 2>&1 | grep -E 'wrote|skin packs|ERROR|SCRIPT' || true
python3 -I - <<'PY'
import glob, os
from PIL import Image
fs = sorted(glob.glob("screenshots/weapons/*_hip.png"))
if fs:
    cols = 2
    tiles = []
    for f in fs:
        for k in ("hip", "aim"):
            p = f.replace("_hip", "_" + k)
            if os.path.exists(p):
                tiles.append(Image.open(p).convert("RGB").resize((640, 360)))
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (640 * cols, 360 * rows))
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % cols) * 640, (i // cols) * 360))
    sheet.save("screenshots/weapons/sheet.png")
    print("wrote screenshots/weapons/sheet.png")
PY
