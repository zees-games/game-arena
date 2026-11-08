#!/usr/bin/env python3
"""Summarise tools/lag_profile.gd logs: tick percentiles, ranked sections, spike periods, node/orphan drift.

python3 tools/lag_profile.py LOG [LOG...]
"""
import json
import sys


def pct(xs, p):
    if not xs:
        return 0.0
    s = sorted(xs)
    return s[min(len(s) - 1, int(p / 100.0 * len(s)))]


def parse(path):
    cols, rows, lps, check = None, [], [], None
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("LPT_COLS "):
            cols = line[9:].replace(" ", "").split(",")
        elif line.startswith("LPT ") and cols:
            v = line[4:].split(",")
            if len(v) == len(cols):
                rows.append(dict(zip(cols, map(float, v))))
        elif line.startswith("LPS "):
            lps.append([float(x) for x in line[4:].split(",")])
        elif line.startswith("LPCHECK {"):
            check = json.loads(line[8:])
    return cols, rows, lps, check


def spikes(rows, key, thr):
    """Times (ms) of ticks over thr, merged when consecutive, and the intervals between them."""
    ts, last = [], -1e9
    for r in rows:
        if r[key] >= thr:
            if r["t_ms"] - last > 50:
                ts.append(r["t_ms"])
            last = r["t_ms"]
    gaps = [b - a for a, b in zip(ts, ts[1:])]
    return ts, gaps


def autocorr_peak(rows, key, lo_ms=100, hi_ms=2000):
    """Strongest period of the per-tick series by autocorrelation (lag in ms via mean tick gap)."""
    x = [r[key] for r in rows]
    n = len(x)
    if n < 200:
        return None
    m = sum(x) / n
    d = [v - m for v in x]
    var = sum(v * v for v in d) or 1.0
    dt = (rows[-1]["t_ms"] - rows[0]["t_ms"]) / max(1, n - 1)
    best = (0.0, 0)
    for lag in range(max(1, int(lo_ms / dt)), min(n // 2, int(hi_ms / dt))):
        c = sum(d[i] * d[i + lag] for i in range(n - lag)) / var
        if c > best[0]:
            best = (c, lag)
    return round(best[1] * dt), round(best[0], 3), round(dt, 2)


def main():
    for path in sys.argv[1:]:
        cols, rows, lps, check = parse(path)
        print("==", path)
        if check:
            print("check:", json.dumps({k: check[k] for k in ("perf", "valid", "dot_sim_loaded", "native_scan",
                  "motor_bodies", "motor_bodies_native", "visibility_ready", "bots_made", "alive_at_start", "teams")
                  if k in check}))
        if not rows:
            print("no LPT rows")
            continue
        secs = (rows[-1]["t_ms"] - rows[0]["t_ms"]) / 1000.0
        print("ticks %d over %.1f s = %.1f ticks/s" % (len(rows), secs, len(rows) / max(secs, 1e-6)))
        for k in ("gap_ms", "phys_ms", "script_ms"):
            xs = [r[k] for r in rows]
            print("%-10s mean %6.2f p50 %6.2f p95 %6.2f p99 %6.2f max %7.2f" % (
                k, sum(xs) / len(xs), pct(xs, 50), pct(xs, 95), pct(xs, 99), max(xs)))
        eng = [r["phys_ms"] - r["script_ms"] for r in rows]
        print("%-10s mean %6.2f p95 %6.2f" % ("engine_ms", sum(eng) / len(eng), pct(eng, 95)))
        secs_cols = cols[6:]
        ranked = sorted(((sum(r[k] for r in rows) / len(rows), k) for k in secs_cols), reverse=True)
        print("sections ms/tick (nested):", ", ".join("%s %.2f (p99 %.2f)" % (k, v, pct([r[k] for r in rows], 99))
              for v, k in ranked))
        for key, thr in (("gap_ms", 100.0), ("phys_ms", 100.0)):
            ts, gaps = spikes(rows, key, thr)
            g = sorted(gaps)
            print("%s>=%.0f: %d spikes (%.2f/s); interval p50 %.0f ms; intervals near 380 (330-430): %d" % (
                key, thr, len(ts), len(ts) / max(secs, 1e-6), pct(g, 50) if g else 0,
                sum(1 for x in gaps if 330 <= x <= 430)))
        ac = autocorr_peak(rows, "phys_ms")
        if ac:
            print("phys autocorr peak: period %s ms (r=%s, tick dt %s ms)" % ac)
        worst = sorted(rows, key=lambda r: -r["phys_ms"])[:5]
        print("worst ticks:", "; ".join("t=%d phys %.0f script %.0f %s" % (r["t_ms"], r["phys_ms"], r["script_ms"],
              max(secs_cols, key=lambda k: r[k])) for r in worst))
        if lps:
            a, b = lps[0], lps[-1]
            print("nodes %d->%d orphans %d->%d (max %d) objects %d->%d rss %.0f->%.0f MB alive min %d mean %.1f" % (
                a[1], b[1], a[2], b[2], max(x[2] for x in lps), a[3], b[3], a[7], b[7],
                min(x[8] for x in lps), sum(x[8] for x in lps) / len(lps)))


if __name__ == "__main__":
    main()
