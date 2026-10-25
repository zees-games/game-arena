#!/usr/bin/env python3
"""Compares rendered frames to goldens: visual_compare.py GOLDEN FRAME DIFF_OUT.

Prints "ok|FAIL|NEW <name> mean=.. changed=..%" and exits 0 (match) or 1.
Tolerances (env): VISUAL_PIXEL_TOL, the largest channel step that still counts as the
same pixel (GPU noise); VISUAL_MAX_PCT, the share of pixels allowed to differ by more;
VISUAL_MAX_MEAN, the mean absolute difference per channel allowed.
"""
import os
import sys

try:
    from PIL import Image, ImageChops
except ImportError:
    print("FAIL Pillow is not installed (python3 -c 'import PIL')")
    sys.exit(2)

golden_path, frame_path, diff_path = sys.argv[1:4]
pixel_tol = int(os.environ.get("VISUAL_PIXEL_TOL", "12"))
max_pct = float(os.environ.get("VISUAL_MAX_PCT", "0.5"))
max_mean = float(os.environ.get("VISUAL_MAX_MEAN", "0.5"))
name = os.path.basename(golden_path)[:-4]

golden = Image.open(golden_path).convert("RGB")
frame = Image.open(frame_path).convert("RGB")

if golden.size != frame.size:
    print("FAIL %s size %s, golden %s" % (name, frame.size, golden.size))
    sys.exit(1)

diff = ImageChops.difference(golden, frame)
count = lambda im: sum(im.histogram()[1:])
channel_max = ImageChops.lighter(ImageChops.lighter(*(diff.getchannel(c) for c in (0, 1))), diff.getchannel(2))
changed = count(channel_max.point(lambda v: 255 if v > pixel_tol else 0))
pct = 100.0 * changed / (golden.width * golden.height)
hist = diff.histogram()
mean = sum(i % 256 * n for i, n in enumerate(hist)) / (golden.width * golden.height * 3)

line = "%s mean=%.3f changed=%.3f%%" % (name, mean, pct)
if pct > max_pct or mean > max_mean:
    os.makedirs(os.path.dirname(diff_path), exist_ok=True)
    amplified = diff.point(lambda v: min(255, v * 8))
    side = Image.new("RGB", (golden.width * 3, golden.height))
    side.paste(golden, (0, 0))
    side.paste(frame, (golden.width, 0))
    side.paste(amplified, (golden.width * 2, 0))
    side.save(diff_path)
    print("FAIL " + line + " (golden | frame | diff x8: %s)" % diff_path)
    sys.exit(1)

print("ok   " + line)
