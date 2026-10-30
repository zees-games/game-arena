#!/usr/bin/env bash
# Frames of every skinned weapon role in the hands, and a contact sheet: screenshots/weapons/sheet.png
#   tools/render_weapons.sh            # with the installed weapon packs
#   tools/render_weapons.sh --zee      # zee-dot-weapons' own art, for the comparison
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf screenshots/weapons
extra=()
[ "${1:-}" = "--zee" ] && extra=(-- --arena-no-weapon-skins)
# Exits 1 when an aimed gun hides the screen's middle (render_weapons.gd's see-through check),
# or when the run prints any "must be normalized" error (a rotation built from an unnormalised axis).
status=0
log=$(mktemp)
xvfb-run -a -s "-screen 0 1920x1080x24" timeout 600 godot --path . --resolution 1920x1080 \
  --script tools/render_weapons.gd "${extra[@]}" > "$log" 2>&1 || status=$?
grep -E 'wrote|skin packs|ERROR|SCRIPT|see-through|FAIL' "$log" | sort | uniq -c | sort -rn | head -20 || true
bad=$(grep -c 'must be normalized' "$log" || true)
echo "normalized-axis errors: $bad"
rm -f "$log"
[ "$bad" -gt 0 ] && [ "$status" -eq 0 ] && status=1
# The sheet needs Pillow, which a render box may lack; the frames and the check stand without it.
python3 -I - <<'PY' || echo "no sheet: python3 with Pillow is needed"
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
exit "$status"
