#!/usr/bin/env bash
# Renders dm_atrium's wall routes from first person as frame sequences, then reads the
# per-frame log for a camera that steps, reverses or snaps. See tools/render_wall_moves.gd.
#
#   tools/render_wall_moves.sh                    # run, runjump and chimney
#   tools/render_wall_moves.sh run chimney        # some of them
#   RENDERER=gl_compatibility tools/render_wall_moves.sh
#
# Writes screenshots/wall_moves/<scenario>_NNN.png (every second tick), <scenario>.csv
# (every frame) and <scenario>_sheet.png (the sequence on one page, if PIL is there).
# Needs xvfb-run: under --headless every saved frame is empty.
set -euo pipefail
cd "$(dirname "$0")/.."
out=screenshots/wall_moves
rm -f "$out"/*.png "$out"/*.csv
timeout 300 xvfb-run -a godot --path . --resolution 960x540 --fixed-fps 192 \
  ${RENDERER:+--rendering-method "$RENDERER"} \
  --script res://tools/render_wall_moves.gd -- "$@"

# The log, read as a person would read the frames: how far the eye moves each frame, and
# the largest change in that step (a stutter is a step much longer or shorter than its
# neighbours); the roll, its largest step per frame, and whether it ever turns back while
# the target has not (a snap or a wobble).
python3 - "$out" <<'EOF'
import csv, glob, os, sys
out = sys.argv[1]
for path in sorted(glob.glob(os.path.join(out, "*.csv"))):
    rows = list(csv.DictReader(open(path)))
    if len(rows) < 3:
        print(f"{path}: {len(rows)} frames, nothing to read")
        continue
    eye = [tuple(float(r[k]) for k in ("eye_x", "eye_y", "eye_z")) for r in rows]
    step = [sum((a - b) ** 2 for a, b in zip(eye[i + 1], eye[i])) ** 0.5 for i in range(len(eye) - 1)]
    jerk = [abs(step[i + 1] - step[i]) for i in range(len(step) - 1)]
    rise = [eye[i + 1][1] - eye[i][1] for i in range(len(eye) - 1)]
    vjerk = [abs(rise[i + 1] - rise[i]) for i in range(len(rise) - 1)]
    roll = [float(r["roll_deg"]) for r in rows]
    droll = [roll[i + 1] - roll[i] for i in range(len(roll) - 1)]
    turns = sum(1 for i in range(len(droll) - 1) if droll[i] * droll[i + 1] < -1e-6 and abs(droll[i]) > 0.02)
    worst = max(range(len(jerk)), key=lambda i: jerk[i])
    print(f"{os.path.basename(path)}: {len(rows)} frames; eye step {min(step):.3f}..{max(step):.3f} m, "
          f"largest change of step {max(jerk):.3f} m at frame {worst + 1}; largest change of vertical step {max(vjerk):.4f} m; "
          f"roll {min(roll):.2f}..{max(roll):.2f} deg, largest step {max(abs(d) for d in droll):.3f} deg/frame, "
          f"{turns} reversals")
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
