#!/usr/bin/env bash
# Renders what headless_feel measures, to look at: a bot running across the view, a run with
# the view model, the stair, and the camera's motion (a landing, a strafe, a slide), at 144
# frames a second against 64 ticks. See tools/render_feel.gd.
#
#   tools/render_feel.sh                # bot, run, stairs, landing, strafe and slide
#   tools/render_feel.sh bot            # some of them
#   tools/render_feel.sh bot --stepped  # the bot drawn at its ticks, as before: the control
#   RENDERER=gl_compatibility tools/render_feel.sh
#
# Writes screenshots/feel/<scenario>_NNN.png, <scenario>.csv (every frame) and
# <scenario>_sheet.png (the sequence on one page, if PIL is there). Needs xvfb-run: under
# --headless every saved frame is empty.
set -euo pipefail
cd "$(dirname "$0")/.."
out=screenshots/feel
mkdir -p "$out"
rm -f "$out"/*.png "$out"/*.csv
timeout 300 xvfb-run -a godot --path . --resolution 960x540 --fixed-fps 144 \
  ${RENDERER:+--rendering-method "$RENDERER"} \
  --script res://tools/render_feel.gd -- "$@"

# The log, read as a person would read the frames: how far the bot moves across the screen
# each frame and the largest change in that (a hitch is one step much longer or shorter
# than its neighbours); the view model's largest change of step; the eye's largest rise in
# a frame on the stair against the average.
python3 - "$out" <<'EOF'
import csv, glob, math, os, sys
out = sys.argv[1]
def steps(values):
    return [values[i + 1] - values[i] for i in range(len(values) - 1)]
def worst_change(values):
    s = steps(values)
    return max((abs(s[i + 1] - s[i]) for i in range(len(s) - 1)), default=0.0)
for path in sorted(glob.glob(os.path.join(out, "*.csv"))):
    rows = list(csv.DictReader(open(path)))
    name = os.path.basename(path)[:-4]
    if len(rows) < 4:
        print(f"{name}: {len(rows)} frames, nothing to read")
        continue
    if name == "bot":
        xs = [float(r["bot_screen_x"]) for r in rows if not math.isnan(float(r["bot_screen_x"]))]
        s = steps(xs)
        print(f"bot: {len(xs)} frames on screen; step across the screen {min(s):.1f}..{max(s):.1f} px, "
              f"largest change of step {worst_change(xs):.2f} px")
    elif name == "run":
        hx = [float(r["hands_x"]) for r in rows]
        hy = [float(r["hands_y"]) for r in rows]
        print(f"run: view model largest change of step {max(worst_change(hx), worst_change(hy)) * 1000:.2f} mm a frame")
    elif name == "stairs":
        ys = [float(r["eye_y"]) for r in rows]
        rise = steps(ys)
        climbing = [r for r in rise if r > 0.0005]
        mean = sum(climbing) / max(1, len(climbing))
        print(f"stairs: eye rise per frame mean {mean * 1000:.1f} mm, largest {max(rise) * 1000:.1f} mm")
    if name in ("landing", "strafe", "slide"):
        # The camera's motion: each column's range, largest change in a frame, and largest
        # change of that (a corner: a snap shows as a change of step as large as the step).
        for col, unit, k in (("dip", "mm", 1000.0), ("roll", "deg", 1.0), ("fov", "deg", 1.0)):
            vs = [float(r[col]) * k for r in rows]
            s = steps(vs)
            print(f"{name}: {col} {min(vs):.2f}..{max(vs):.2f} {unit}, largest step {max(abs(x) for x in s):.3f}, "
                  f"largest change of step {worst_change(vs):.4f}")
        if name == "landing":
            ys = [float(r["eye_y"]) for r in rows]
            s = steps(ys)
            print(f"landing: eye step per frame {min(s) * 1000:.1f}..{max(s) * 1000:.1f} mm, largest change of step {worst_change(ys) * 1000:.1f} mm")
try:
    from PIL import Image
except ImportError:
    sys.exit(0)
for scenario in sorted({os.path.basename(p).rsplit("_", 1)[0] for p in glob.glob(os.path.join(out, "*_[0-9][0-9][0-9].png"))}):
    frames = sorted(glob.glob(os.path.join(out, f"{scenario}_[0-9][0-9][0-9].png")))
    thumbs = [Image.open(f).resize((320, 180)) for f in frames]
    cols = 6
    sheet = Image.new("RGB", (cols * 320, ((len(thumbs) + cols - 1) // cols) * 180))
    for i, t in enumerate(thumbs):
        sheet.paste(t, ((i % cols) * 320, (i // cols) * 180))
    sheet.save(os.path.join(out, f"{scenario}_sheet.png"))
    print(f"wrote {out}/{scenario}_sheet.png ({len(thumbs)} frames)")
EOF
