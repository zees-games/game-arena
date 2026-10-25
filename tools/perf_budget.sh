#!/usr/bin/env bash
# Frame-time, memory and load budget per map, measured on the family's GPU box (the GTX 1660 Ti laptop by default).
#   tools/perf_budget.sh [--maps a,b,c] [--runs 3] [--seconds 20] [--tolerance 0.10] [--out FILE]
#                        [--update] [--post] [--from-runs DIR]
# Each map is played RUNS times through tools/client_bench.tscn --json (real client, dedicated server with bots, relayed
# link); the median of each metric is compared with tests/perf_budget.json: a metric fails past baseline * (1 + tolerance)
# (and its slack) or past its absolute cap. --update records the medians as the new baseline. A baseline taken on another
# GPU is refused (exit 3), never compared. --post sends the result to the nightly panel's /qa page (kind perf) through dev01.
# Exit 0 pass, 1 regression, 2 a run failed, 3 GPU mismatch. Result JSON: --out, default .godot/perf/<timestamp>.json.
set -uo pipefail
cd "$(dirname "$0")/.."
maps=dm_atrium,dm_pit,surf_adverse; runs=3; seconds=20; tol=""; out=""; update=0; post=0; from=""
while [ $# -gt 0 ]; do
    case "$1" in
        --maps) maps=$2; shift 2 ;;
        --runs) runs=$2; shift 2 ;;
        --seconds) seconds=$2; shift 2 ;;
        --tolerance) tol=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --update) update=1; shift ;;
        --post) post=1; shift ;;
        --from-runs) from=$2; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
stamp=$(date +%Y%m%d-%H%M%S)
work=${from:-.godot/perf/$stamp.runs}
out=${out:-.godot/perf/$stamp.json}
mkdir -p "$work" "$(dirname "$out")"

if [ -z "$from" ]; then
    # The box keeps its own class cache; a stale one fails every script with "not declared".
    GPU_TIMEOUT=900 timeout -k 10 1000 ../gpu.sh run game-arena --headless --import >"$work/import.log" 2>&1 \
        || { echo "perf: import on the GPU box failed, see $work/import.log" >&2; exit 2; }
    for m in ${maps//,/ }; do
        for ((i = 1; i <= runs; i++)); do
            echo "perf: $m run $i/$runs"
            GPU_TIMEOUT=300 timeout -k 10 360 ../gpu.sh run game-arena res://tools/client_bench.tscn -- \
                --map "$m" --bots 3 --delay 20 --play --seconds "$seconds" --json >"$work/$m.$i.log" 2>&1
            grep -m1 '^PERF ' "$work/$m.$i.log" | cut -c6- >"$work/$m.$i.json"
            [ -s "$work/$m.$i.json" ] || { echo "perf: $m run $i printed no PERF line, see $work/$m.$i.log" >&2; exit 2; }
        done
    done
fi

commit=$(git rev-parse HEAD 2>/dev/null || true)
dirty=$([ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] && echo 1 || echo 0)
python3 -I - "$work" "$out" "$maps" "$update" "$tol" "$commit" "$dirty" <<'PY'
import glob, json, os, statistics, subprocess, sys, time
work, out, maps, update, tol, commit, dirty = sys.argv[1:8]
update = update == "1"
BASE = "tests/perf_budget.json"
# metric: (absolute slack under which a change never counts, default cap); lower is better for all of them.
METRICS = {"p50_ms": (0.5, 25.0), "p95_ms": (1.0, 33.3), "p99_ms": (2.0, 40.0), "stall_ms": (10.0, 120.0),
           "load_s": (1.0, 20.0), "rss_mb": (50.0, 3000.0), "pack_mb": (0.2, 100.0)}

def pack_mb(m):
    total = 0
    for root in (f"maps/imported/{m}", f"lightmaps/{m}.res"):
        if os.path.isfile(root):
            total += os.path.getsize(root)
        for d, _, fs in os.walk(root):
            total += sum(os.path.getsize(os.path.join(d, f)) for f in fs)
    return total / 1048576.0

base = json.load(open(BASE)) if os.path.exists(BASE) else {}
tolerance = float(tol) if tol else float(base.get("tolerance", 0.10))
result = {"game": "game-arena", "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "commit": commit, "dirty": dirty == "1",
          "tolerance": tolerance, "maps": {}, "failures": []}
gpus = set()
for m in maps.split(","):
    runs = [json.load(open(f)) for f in sorted(glob.glob(f"{work}/{m}.*.json"))]
    if not runs:
        sys.exit(f"perf: no runs for {m} in {work}")
    gpus |= {r["gpu"] for r in runs}
    med, noise = {}, {}
    for k in METRICS:
        if k == "pack_mb":
            med[k], noise[k] = pack_mb(m), 0.0
            continue
        vals = [r[k] for r in runs]
        med[k] = statistics.median(vals)
        noise[k] = (max(vals) - min(vals)) / med[k] * 100.0 if med[k] else 0.0
    result["maps"][m] = {"median": med, "noise_pct": noise, "runs": runs}
if len(gpus) != 1:
    sys.exit(f"perf: the runs span several GPUs: {sorted(gpus)}")
result["gpu"] = gpus.pop()
result["resolution"] = next(iter(result["maps"].values()))["runs"][0].get("resolution", "")

caps = dict(base.get("caps", {}))
slack = dict(base.get("slack", {}))
for k, (s, c) in METRICS.items():
    caps.setdefault(k, c); slack.setdefault(k, s)
if update:
    new = {"gpu": result["gpu"], "resolution": result["resolution"], "tolerance": tolerance, "caps": caps, "slack": slack,
           "recorded": result["time"], "commit": commit, "maps": dict(base.get("maps", {}))}
    if base.get("gpu") not in (None, result["gpu"]):
        new["maps"] = {}
    for m, r in result["maps"].items():
        new["maps"][m] = {k: round(v, 3) for k, v in r["median"].items()}
    json.dump(new, open(BASE, "w"), indent=2); open(BASE, "a").write("\n")
    result["updated_baseline"] = True
    base = new
mismatch = bool(base) and base.get("gpu") != result["gpu"]
result["gpu_mismatch"] = mismatch
result["baseline_gpu"] = base.get("gpu", "")
checks = 0
for m, r in result["maps"].items():
    b = base.get("maps", {}).get(m)
    r["metrics"] = {}
    for k, v in r["median"].items():
        row = {"value": round(v, 3), "cap": caps[k], "noise_pct": round(r["noise_pct"][k], 1)}
        if b and not mismatch and k in b:
            row["baseline"] = b[k]
            row["budget"] = round(min(caps[k], max(b[k] * (1 + tolerance), b[k] + slack[k])), 3)
        else:
            row["budget"] = caps[k]
        checks += 1
        why = []
        if v > caps[k]:
            why.append(f"over the cap {caps[k]}")
        if "baseline" in row and v > max(b[k] * (1 + tolerance), b[k] + slack[k]):
            why.append(f"{(v / b[k] - 1) * 100:+.0f}% vs baseline {b[k]}")
        row["status"] = "fail" if why else "ok"
        if why:
            result["failures"].append({"name": f"{m} {k} {v:.2f}", "reasons": why})
        r["metrics"][k] = row
    del r["noise_pct"]
result["total"] = checks
result["ok"] = not result["failures"] and not mismatch
json.dump(result, open(out, "w"), indent=2); open(out, "a").write("\n")

print(f"perf: {result['gpu']} {result['resolution']}, median of {len(next(iter(result['maps'].values()))['runs'])}, tolerance {tolerance:.0%}")
print(f"  {'map':<14}" + "".join(f"{k:>10}" for k in METRICS))
for m, r in result["maps"].items():
    print(f"  {m:<14}" + "".join(f"{r['metrics'][k]['value']:>10.2f}" for k in METRICS))
    print(f"  {'  noise %':<14}" + "".join(f"{r['metrics'][k]['noise_pct']:>10.1f}" for k in METRICS))
for f in result["failures"]:
    print("  FAIL", f["name"], "-", "; ".join(f["reasons"]))
if mismatch:
    print(f"perf: baseline was taken on '{base.get('gpu')}', this is '{result['gpu']}': not compared (use --update to rebase)")
print(f"perf: {'updated ' + BASE if update else 'result ' + out} | {'ok' if result['ok'] else 'FAILED'}")
sys.exit(3 if mismatch else (0 if result["ok"] else 1))
PY
rc=$?
if [ "$post" = 1 ] && [ -s "$out" ]; then
    # The payload is the result plus the /api/qa summary; qa-post.sh lives with the panel on dev01.
    python3 -I - "$out" <<'PY' | ssh dev01 "f=\$(mktemp) && cat >\$f && QA_URL=http://127.0.0.1:3010 QA_COMMIT=$commit ~/stack/nightly/scripts/qa-post.sh perf game-arena \$f; r=\$?; rm -f \$f; exit \$r"
import json, sys
r = json.load(open(sys.argv[1]))
metrics = {m: {k: {x: v[x] for x in ("value", "baseline", "budget", "cap", "noise_pct", "status") if x in v} for k, v in d["metrics"].items()} for m, d in r["maps"].items()}
print(json.dumps({"ok": r["ok"], "timestamp": r["time"], "failures": r["failures"] + ([{"name": "GPU mismatch", "reasons": [f"baseline on {r['baseline_gpu']}, run on {r['gpu']}"]}] if r["gpu_mismatch"] else []),
    "summary": {"total": r["total"], "failed": len(r["failures"]) + int(r["gpu_mismatch"]), "gpu": r["gpu"], "tolerance": r["tolerance"],
                "resolution": r["resolution"], "dirty": r["dirty"], "metrics": metrics}}))
PY
fi
exit $rc
