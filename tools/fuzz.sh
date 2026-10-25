#!/usr/bin/env bash
# Seeded bot-soak sweep: every (map, seed) pair through tools/soak.tscn, one at a time under heavy.
#   tools/fuzz.sh [--seeds N] [--minutes M] [--maps a,b|all] [--out DIR] [--first-seed S]
#   tools/fuzz.sh --repro MAP SEED [--minutes M]     one pair, full log kept in .godot/fuzz-repro
# Exit 1 when any pair fails. Default maps: the three built-ins.
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
seeds=3; minutes=1; maps=dm_box,dm_atrium,dm_pit; out=""; first=1; repro=""; rmap=""; rseed=""
while [ $# -gt 0 ]; do
    case "$1" in
        --seeds) seeds=$2; shift 2 ;;
        --minutes) minutes=$2; shift 2 ;;
        --maps) maps=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --first-seed) first=$2; shift 2 ;;
        --repro) repro=1; rmap=$2; rseed=$3; shift 3 ;;
        -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
if [ -n "$repro" ]; then
    out=${out:-.godot/fuzz-repro}; maps=$rmap; first=$rseed; seeds=1
fi
out=${out:-.godot/fuzz/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$out"
[ "$maps" = all ] && maps=dm_box,dm_atrium,dm_pit,$(ls maps/imported 2>/dev/null | paste -sd,)
# Simulated minutes run slower than real time under load; leave room, then kill.
limit=$(python3 -c "print(int($minutes*60*6+300))")

for m in ${maps//,/ }; do
    for ((s = first; s < first + seeds; s++)); do
        tag=$m-s$s
        echo "fuzz: $tag"
        heavy -- timeout -k 10 "$limit" "$GODOT" --headless --path . res://tools/soak.tscn -- \
            --map "$m" --seed "$s" --minutes "$minutes" --report "$PWD/$out/$tag.report.json" \
            >"$out/$tag.log" 2>&1
        echo $? >"$out/$tag.exit"
        pkill -f "res://tools/soak.tscn -- --map $m --seed $s " 2>/dev/null
    done
done

python3 -I - "$out" "$repro" <<'E2'
import glob, json, os, re, sys
out, repro = sys.argv[1], sys.argv[2]
rows = []
for ef in sorted(glob.glob(out + "/*.exit")):
    tag = os.path.basename(ef)[:-5]
    m, s = tag.rsplit("-s", 1)
    code = int(open(ef).read().strip() or -1)
    log = open(f"{out}/{tag}.log", errors="replace").read().splitlines()
    soak = next((l for l in log if l.startswith("SOAK ")), "")
    errs = [l.strip() for l in log if re.search(r"SCRIPT ERROR|ERROR|leaked|Parse Error", l)]
    stuck = [l.strip() for l in log if "stuck" in l.lower() and not l.startswith("SOAK ")]
    reasons = [l.strip() for l in log if l.strip().startswith(("-", "!")) or "FAIL" in l][:6]
    fail = code != 0 or not soak or bool(errs)
    row = {"map": m, "seed": int(s), "exit": code, "failed": fail, "soak": soak, "errors": errs[:20],
           "stuck": stuck[:10], "reasons": reasons,
           "repro": f"tools/fuzz.sh --repro {m} {s}"}
    json.dump(row, open(f"{out}/{tag}.json", "w"), indent=1)
    rows.append(row)
rows.sort(key=lambda r: (not r["failed"], r["map"], r["seed"]))
bad = [r for r in rows if r["failed"]]
json.dump({"pairs": len(rows), "failed": len(bad), "runs": rows}, open(out + "/summary.json", "w"), indent=1)
lines = [f"fuzz: {len(rows)} pairs, {len(bad)} failed ({out})"]
for r in rows:
    lines.append(f"{'FAIL' if r['failed'] else 'ok  '} {r['map']} seed {r['seed']} exit {r['exit']}")
    if r["failed"]:
        for x in (r["reasons"] + r["errors"])[:5] or ["no SOAK line" if not r["soak"] else "nonzero exit"]:
            lines.append("     " + x[:160])
        lines.append("     " + r["repro"])
open(out + "/summary.txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(1 if bad else 0)
E2
