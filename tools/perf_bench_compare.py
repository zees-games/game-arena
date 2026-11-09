#!/usr/bin/env python3
"""Per-system tables of dot-profiler reports side by side.

  perf_bench_compare.py REF RUN...            each RUN against REF (the first file)
  perf_bench_compare.py --ab A1 B1 A2 B2 ...  group by label (LABEL=path; else A/B by position), mean B-A
  perf_bench_compare.py --per-tick RUN...     the per-tick systems in ms per game tick (mean over the runs)

A file is a profiler report (.json) or a log with PERF_BENCH_REPORT / PERF_BENCH_SIDECAR lines.
ms/frame differs with frame rate (2 ticks a frame at 50 ms, fewer on a faster box), so the
per-call column is the one to compare across machines; ms/frame is what a player feels.
"""
import json
import statistics
import sys


def load(path):
    label = None
    if "=" in path and not path.startswith("/") and path.split("=", 1)[0].isidentifier():
        label, path = path.split("=", 1)
    report = side = None
    with open(path) as f:
        text = f.read()
    if text.lstrip().startswith("{"):
        report = json.loads(text)
    else:
        for line in text.splitlines():
            if line.startswith("PERF_BENCH_REPORT "):
                report = json.loads(line.split(" ", 1)[1])
            elif line.startswith("PERF_BENCH_SIDECAR "):
                side = json.loads(line.split(" ", 1)[1])
    if report is None:
        sys.exit(f"{path}: no report in it")
    frames = max(report.get("frames", 1), 1)
    rows = {}
    for s in report["systems"]:
        rows[s["system"]] = {"ms": s["ms"] / frames, "call": s["ms"] / max(s["calls"], 1), "calls": s["calls"] / frames}
    for k, v in report.get("phases", {}).items():
        rows["phase." + k] = {"ms": v / frames, "call": v / frames, "calls": 1}
    # What the engine spends in physics beyond the game's own physics section.
    if "phase.physics" in rows and "arena.physics" in rows:
        rest = rows["phase.physics"]["ms"] - rows["arena.physics"]["ms"]
        rows["engine.physics_outside_arena"] = {"ms": rest, "call": rest, "calls": 1}
    if side:
        for k, v in side.get("per_frame", {}).items():
            if k.endswith("_ms"):
                rows["engine." + k] = {"ms": v, "call": v, "calls": 1}
        for k, v in side.get("motor_queries", {}).items():
            rows["query." + k] = {"ms": v["ms_per_frame"], "call": v["us_each"] / 1000.0, "calls": v["per_frame"]}
    head = {
        "p50": report.get("p50_ms", 0.0), "p95": report.get("p95_ms", 0.0), "p99": report.get("p99_ms", 0.0),
        "frames": report.get("frames", 0),
        "ticks/frame": rows.get("arena.physics", {}).get("calls", 0.0),
        "ticks/sec": (side or {}).get("ticks_per_sec", 0.0),
        # Ticks real time asked for and the step cap dropped (older sidecars: from tick_hz and ticks/sec).
        "dropped/sec": (side or {}).get("dropped_per_sec", max((side or {}).get("tick_hz", 0) - (side or {}).get("ticks_per_sec", 0.0), 0.0)),
        "dropped": (side or {}).get("dropped_ticks", -1),
        "box": (side or {}).get("adapter") or (side or {}).get("display", "") or "owner",
    }
    return label, path, head, rows


def pct(a, b):
    return (b - a) / a * 100.0 if a > 1e-9 else float("nan")


def order(rows, top):
    keys = sorted(rows, key=lambda k: -rows[k]["ms"])
    keep = [k for k in keys if not k.startswith(("phase.", "engine.", "query."))][:top]
    return keep + sorted(k for k in keys if k.startswith("phase.")) + sorted(k for k in keys if k.startswith(("engine.", "query.")))


def compare(files, top):
    ref = load(files[0])
    runs = [load(f) for f in files[1:]]
    def ticks(h):
        return "ticks/frame %.2f  ticks/sec %.1f  dropped %.1f/s (%d)" % (h["ticks/frame"], h["ticks/sec"], h["dropped/sec"], h["dropped"])

    print("ref %s  p50 %.1f ms  p95 %.1f  p99 %.1f  frames %d  %s" % (ref[1], ref[2]["p50"], ref[2]["p95"], ref[2]["p99"], ref[2]["frames"], ticks(ref[2])))
    for r in runs:
        print("run %s  p50 %.1f ms (%+.0f%%)  p95 %.1f  p99 %.1f  frames %d  %s  [%s]" % (
            r[1], r[2]["p50"], pct(ref[2]["p50"], r[2]["p50"]), r[2]["p95"], r[2]["p99"], r[2]["frames"], ticks(r[2]), r[2]["box"]))
    print()
    print("%-32s %9s %9s" % ("system", "ref ms/f", "ms/call") + "".join(" | %8s %7s %8s %7s" % ("ms/f", "d%", "ms/call", "d%") for _ in runs))
    for k in order(ref[3], top):
        a = ref[3][k]
        line = "%-32s %9.2f %9.4f" % (k, a["ms"], a["call"])
        for r in runs:
            b = r[3].get(k)
            if b is None:
                line += " | %8s %7s %8s %7s" % ("-", "", "-", "")
            else:
                line += " | %8.2f %+6.0f%% %8.4f %+6.0f%%" % (b["ms"], pct(a["ms"], b["ms"]), b["call"], pct(a["call"], b["call"]))
        print(line)
    extra = sorted({k for r in runs for k in r[3]} - set(ref[3]))
    for k in extra:
        line = "%-32s %9s %9s" % (k, "-", "-")
        for r in runs:
            b = r[3].get(k)
            line += " | %8.2f %7s %8.4f %7s" % (b["ms"], "", b["call"], "") if b else " | %8s %7s %8s %7s" % ("-", "", "-", "")
        print(line)


def ab(files, top):
    groups = {}
    for i, f in enumerate(files):
        label, path, head, rows = load(f)
        groups.setdefault(label or "AB"[i % 2], []).append((head, rows))
    if len(groups) != 2:
        sys.exit("--ab needs exactly two labels")
    (la, ga), (lb, gb) = groups.items()

    def stat(g, key, field="ms"):
        vals = [rows[key][field] for _, rows in g if key in rows]
        return (statistics.mean(vals), min(vals), max(vals)) if vals else None

    pa = [h["p50"] for h, _ in ga]
    pb = [h["p50"] for h, _ in gb]
    print("%s: %d runs, p50 %s ms   %s: %d runs, p50 %s ms   delta %+.2f ms (%+.1f%%)" % (
        la, len(ga), " ".join("%.1f" % v for v in pa), lb, len(gb), " ".join("%.1f" % v for v in pb),
        statistics.mean(pb) - statistics.mean(pa), pct(statistics.mean(pa), statistics.mean(pb))))
    qa = [h["p99"] for h, _ in ga]
    qb = [h["p99"] for h, _ in gb]
    print("%s p99 %s ms   %s p99 %s ms   delta %+.2f ms" % (
        la, " ".join("%.1f" % v for v in qa), lb, " ".join("%.1f" % v for v in qb), statistics.mean(qb) - statistics.mean(qa)))
    print()
    print("%-32s %9s %15s %9s %15s %9s %7s  %s" % ("system (ms/frame)", la, "range", lb, "range", "delta", "d%", "noise?"))
    for k in order(ga[0][1], top):
        a, b = stat(ga, k), stat(gb, k)
        if a is None or b is None:
            continue
        # A delta inside both runs' spread is not a result.
        noise = "noise" if (b[1] <= a[2] and a[1] <= b[2]) else ""
        print("%-32s %9.2f %7.2f-%-7.2f %9.2f %7.2f-%-7.2f %+9.2f %+6.1f%%  %s" % (k, a[0], a[1], a[2], b[0], b[1], b[2], b[0] - a[0], pct(a[0], b[0]), noise))
    # A cheaper tick can buy more catch-up ticks a frame instead of a shorter frame (ArenaTickBudget),
    # so the per-call cost of the per-tick systems is the direct measure of a sim change.
    print()
    print("%-32s %9s %15s %9s %15s %9s %7s  %s" % ("per call (ms) / ticks", la, "range", lb, "range", "delta", "d%", "noise?"))
    for k in ["arena.physics", "arena.game_tick", "arena.tick_players", "arena.p_controller", "arena.p_weapons",
              "arena.p_hulls", "arena.bots", "arena.bot_brain", "arena.tick_world",
              "arena.pl_pre", "arena.pl_sim", "arena.pl_post", "arena.p_pre", "arena.p_hitbox", "arena.p_wctx"]:
        a, b = stat(ga, k, "call"), stat(gb, k, "call")
        if a is None or b is None:
            continue
        noise = "noise" if (b[1] <= a[2] and a[1] <= b[2]) else ""
        print("%-32s %9.4f %7.4f-%-7.4f %9.4f %7.4f-%-7.4f %+9.4f %+6.1f%%  %s" % (k, a[0], a[1], a[2], b[0], b[1], b[2], b[0] - a[0], pct(a[0], b[0]), noise))
    ta = [h["ticks/frame"] for h, _ in ga]
    tb = [h["ticks/frame"] for h, _ in gb]
    print("%-32s %9.2f %15s %9.2f" % ("ticks/frame", statistics.mean(ta), "", statistics.mean(tb)))
    # Simulated ticks per wall second: the game's speed (66 is real time).
    sa = [h["ticks/sec"] for h, _ in ga]
    sb = [h["ticks/sec"] for h, _ in gb]
    print("%-32s %9.2f %15s %9.2f" % ("ticks/sec (sim speed)", statistics.mean(sa), "", statistics.mean(sb)))
    da = [h["dropped/sec"] for h, _ in ga]
    db = [h["dropped/sec"] for h, _ in gb]
    print("%-32s %9.2f %15s %9.2f" % ("dropped ticks/sec", statistics.mean(da), "", statistics.mean(db)))


def per_tick(files, top):
    runs = [load(f) for f in files]
    heads = [r[2] for r in runs]
    print("%d run(s)  p50 %s ms  p99 %s  ticks/frame %s  ticks/sec %s  dropped/sec %s" % (
        len(runs), " ".join("%.1f" % h["p50"] for h in heads), " ".join("%.1f" % h["p99"] for h in heads),
        " ".join("%.2f" % h["ticks/frame"] for h in heads), " ".join("%.1f" % h["ticks/sec"] for h in heads),
        " ".join("%.1f" % h["dropped/sec"] for h in heads)))
    print("%-32s %10s %10s %9s" % ("system", "ms/tick", "us/call", "calls/tick"))
    keys = [k for k in order(runs[0][3], top) if k.startswith("arena.") or k.startswith("query.")]
    for k in keys:
        vals = [(r[3][k]["ms"] / max(r[2]["ticks/frame"], 1e-9), r[3][k]["call"] * 1000.0, r[3][k]["calls"] / max(r[2]["ticks/frame"], 1e-9))
                for r in runs if k in r[3]]
        if not vals:
            continue
        print("%-32s %10.3f %10.1f %9.1f" % (k, statistics.mean(v[0] for v in vals), statistics.mean(v[1] for v in vals), statistics.mean(v[2] for v in vals)))


def main():
    args = sys.argv[1:]
    top = 40
    if "--top" in args:
        i = args.index("--top")
        top = int(args[i + 1])
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)
    if args[0] == "--ab":
        ab(args[1:], top)
    elif args[0] == "--per-tick":
        per_tick(args[1:], top)
    else:
        compare(args, top)


if __name__ == "__main__":
    main()
