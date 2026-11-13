#!/usr/bin/env bash
# The animation review loop's capture step (docs/anim-review.md): plays every first-person clip of the named weapons, writes
# labelled contact sheets per weapon and clip (first person and third person) and a PASS/FAIL report from the glitch metrics.
#   tools/anim_review.sh <game-dir> <weapon[,weapon]|all> [--anim reload_empty[,draw]] [--frames] [--soft]
# Every clip's per-frame numbers go to <weapon>/<clip>_frames.tsv; a FAIL clip's (every clip's with --frames) are printed too.
# The capture goes through heavy, which hands tools/*_shot.sh to a GPU box; run it as gamedev (who holds the box key) from the
# checkout or a ~/wt worktree. --soft keeps it here on software rendering (slower, same frames apart from lighting).
set -euo pipefail
game=${1:?usage: anim_review.sh <game-dir> <weapon|all> [--anim X] [--soft]}
weapons=${2:?usage: anim_review.sh <game-dir> <weapon|all> [--anim X] [--soft]}
shift 2
anims="idle,draw,holster,fire,ads,reload_empty,reload_tactical,sprint,inspect"
soft=0
frames=0
while (($#)); do
  case $1 in
    --anim | --anims) anims=$2; shift 2 ;;
    --soft) soft=1; shift ;;
    --frames) frames=1; shift ;;
    *) echo "anim_review.sh: unknown argument $1 (weapons and clips are one comma list each: launcher,knife)" >&2; exit 2 ;;
  esac
done
# heavy and the godot it hands on live in gamedev's own bin dirs, which sudo -u gamedev leaves off PATH.
command -v heavy > /dev/null || PATH=$HOME/bin:$HOME/.local/bin:/home/gamedev/bin:/home/gamedev/.local/bin:$PATH
command -v heavy > /dev/null || { echo "anim_review.sh: no heavy on PATH (run as gamedev)" >&2; exit 2; }
cd "$game"
out=screenshots/anim_review
log=$out/capture.log
mkdir -p "$out"
# Only the picked weapons' old sheets go: a run for one weapon keeps every other weapon's review.
if [[ $weapons == all ]]; then
  rm -f "$out"/*/*_sheet.png "$out"/*/*_metrics.json
else
  IFS=, read -ra picked <<< "$weapons"
  for w in "${picked[@]}"; do
    [[ -n $w && $w != */* && $w != .* ]] && rm -f "$out/$w"/*_sheet.png "$out/$w"/*_metrics.json
  done
fi
pick=()
[[ $weapons == all ]] || pick=(--only "$weapons")
[[ $soft == 1 ]] && export GPU_OFFLOAD=0
rc=0
heavy -- timeout 3500 tools/anim_review_shot.sh --out "$out" --anims "$anims" "${pick[@]}" > "$log" 2>&1 || rc=$?
grep -E 'SCRIPT ERROR|WARN|ERROR' "$log" | head -5 >&2 || true
python3 - "$out" "$log" "$frames" <<'PY'
import json, math, os, sys
out, log, all_frames = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
rows, per_clip = [], {}
for line in open(log, errors="replace"):
    if line.startswith("ANIMREVIEW {"):
        rows.append(json.loads(line[len("ANIMREVIEW "):]))
    elif line.startswith("ANIMFRAMES {"):
        c = json.loads(line[len("ANIMFRAMES "):])
        per_clip[(c["weapon"], c["anim"])] = c["frames"]

PARTS = [("weapon", "wpn"), ("Middle1.R", "handR"), ("Middle1.L", "handL"), ("LowerArm.R", "foreR"), ("LowerArm.L", "foreL")]
HEAD = ["#", "t", "sw", "rl", "deploy", "wid", "turn"] + [n for _, n in PARTS] + ["hand_err", "isect", "near", "cut", "weapon_xyz"]

def step(a, b, key):
    if key not in a or key not in b or a.get("weapon_id") != b.get("weapon_id"):
        return ""
    return "%.3f" % math.dist(a[key], b[key])

def turn(a, b):
    if "weapon_q" not in a or "weapon_q" not in b or a.get("weapon_id") != b.get("weapon_id"):
        return ""
    d = min(1.0, abs(sum(x * y for x, y in zip(a["weapon_q"], b["weapon_q"]))))
    return "%.1f" % math.degrees(2 * math.acos(d))

def table(frames):
    """One row per frame; a step column is the move from the frame before, as the pop metric reads it."""
    out_rows = [HEAD]
    for i, f in enumerate(frames):
        p = frames[i - 1] if i else {}
        wid = "" if not i or p.get("weapon_id") == f.get("weapon_id") else "swap"
        g = lambda k: "" if k not in f else ("%.3f" % f[k] if isinstance(f[k], float) else str(f[k]))
        out_rows.append([str(i), "%.3f" % f["t"], "S" if f.get("switching") else "", "R" if f.get("reloading") else "", g("deploy"), wid,
            turn(p, f) if i else ""] + [step(p, f, k) if i else "" for k, _ in PARTS]
            + [g("hand_error"), g("intersect"), g("near"), g("cut"), ",".join("%.3f" % x for x in f.get("weapon", []))])
    return out_rows
lines = ["# Animation review", "", "| weapon | clip | verdict | why | first person | third person |", "|---|---|---|---|---|---|"]
fails = 0
skipped = [r for r in rows if "pass" not in r]
rows = [r for r in rows if "pass" in r]
for r in sorted(rows, key=lambda r: (r["weapon"], r["anim"])):
    base = os.path.join(out, r["weapon"], r["anim"])
    fp, tp = base + "_fp_sheet.png", base + "_tp_sheet.png"
    verdict = "PASS" if r["pass"] else "FAIL"
    fails += 0 if r["pass"] else 1
    why = "; ".join(r["fail"]) if r["fail"] else "worst " + ", ".join("%s %s" % kv for kv in r["worst"].items())
    lines.append("| %s | %s | %s | %s | %s | %s |" % (r["weapon"], r["anim"], verdict, why,
        os.path.abspath(fp) if os.path.exists(fp) else "missing", os.path.abspath(tp) if os.path.exists(tp) else "missing"))
for r in sorted(skipped, key=lambda r: (r["weapon"], r["anim"])):
    lines.append("| %s | %s | %s | %s | | |" % (r["weapon"], r["anim"], "MISSING" if r["anim"] == "inspect" else "N/A", r.get("why") or r.get("status")))
lines += ["", "%d clips, %d FAIL, %d not playable" % (len(rows), fails, len(skipped))]
open(os.path.join(out, "report.md"), "w").write("\n".join(lines) + "\n")
for r in sorted(rows, key=lambda r: (r["weapon"], r["anim"])):
    frames = per_clip.get((r["weapon"], r["anim"]))
    if not frames:
        continue
    t = table(frames)
    os.makedirs(os.path.join(out, r["weapon"]), exist_ok=True)
    open(os.path.join(out, r["weapon"], r["anim"] + "_frames.tsv"), "w").write("\n".join("\t".join(row) for row in t) + "\n")
    if all_frames or not r["pass"]:
        width = [max(len(row[c]) for row in t) for c in range(len(HEAD))]
        print("\n== %s %s %s: %s" % (r["weapon"], r["anim"], "PASS" if r["pass"] else "FAIL", "; ".join(r["fail"]) or "clean"))
        for row in t:
            print("  ".join(v.rjust(w) for v, w in zip(row, width)).rstrip())
print("anim_review: %d clips, %d PASS, %d FAIL; report %s" % (len(rows), len(rows) - fails, fails, os.path.abspath(os.path.join(out, "report.md"))))
if not rows and not skipped:
    sys.exit("anim_review: nothing captured (see %s; llvmpipe crashes, so wait for a GPU box with GPU_SHOT_WAIT)" % log)
PY
exit $rc
