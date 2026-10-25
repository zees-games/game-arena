#!/usr/bin/env python3
"""Line up SOLIDTRACE answers (NC_SOLID_TRACE=1): server vs the mover's client, per (tick, mover, other).

Usage: tools/solid_trace.py <netchaos profile dir | one headless_net log>"""
import sys, glob, os, re, collections, math

rx = re.compile(r"SOLIDTRACE (\w) t=(\d+) mover=(\d+) other=(\d+) lag=(-?[\d.]+) raw=(-?[\d.]+) null=(\d) feet=([-\d.]+),([-\d.]+),([-\d.]+) mover_at=([-\d.]+),([-\d.]+),([-\d.]+)(?: newest=(-?\d+))?")

def load(path, end=None):
    out = collections.defaultdict(list)
    for line in open(path, errors="replace"):
        m = rx.search(line)
        if not m:
            continue
        g = m.groups()
        if end and g[0] != end:
            continue
        key = (int(g[1]), int(g[2]), int(g[3]))
        out[key].append((float(g[4]), float(g[5]), int(g[6]), tuple(map(float, g[7:10])), tuple(map(float, g[10:13])), int(g[13] or -1)))
    return out

run = sys.argv[1]
if os.path.isdir(run):
    srv = load(os.path.join(run, "server.log"))
    cli = {}
    for p in glob.glob(os.path.join(run, "client-*.log")):
        cli.update(load(p))
else:
    srv = load(run, "S")
    cli = load(run, "C")
print("server keys", len(srv), "client keys", len(cli))
diffs = []
lagd = []
nullmis = 0
both = 0
for key, s in srv.items():
    c = cli.get(key)
    if not c:
        continue
    both += 1
    s0 = s[-1]
    c0 = c[-1]
    if s0[2] != c0[2]:
        nullmis += 1
    d = math.dist(s0[3], c0[3])
    dy = abs(s0[3][1] - c0[3][1])
    diffs.append((d, dy, key, s0, c0, len(c)))
    lagd.append(abs(s0[0] - c0[0]))
diffs.sort(reverse=True)
print("matched", both, "null mismatches", nullmis)
for lim in (0.01, 0.05, 0.1, 0.3):
    print("feet diff > %.2f m: %d" % (lim, sum(1 for d in diffs if d[0] > lim)))
print("lag diff > 0.01: %d, max %.2f" % (sum(1 for x in lagd if x > 0.01), max(lagd) if lagd else 0))
for d in diffs[:int(sys.argv[2]) if len(sys.argv) > 2 else 15]:
    dd, dy, key, s0, c0, n = d
    print("t=%d mover=%d other=%d  d=%.3f dy=%.3f  S lag=%.2f null=%d feet=%s | C lag=%.2f raw=%.2f null=%d feet=%s newest=%d (%d client answers, first %s)" % (
        key[0], key[1], key[2], dd, dy, s0[0], s0[2], s0[3], c0[0], c0[1], c0[2], c0[3], c0[5], n, cli[key][0][3]))
