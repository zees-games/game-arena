#!/usr/bin/env python3
"""Ride caches (maps/surf/<id>.surf.json) for every imported surf map, planned in parallel.
  tools/surf_rides_all.py [--maps a,b] [-j N] [--replan] [--godot CMD] [--wrap 'heavy --']
Phase 1 explores each map that has no cache (one process per map); phase 2 plans every unplanned edge
as its own process (`--plan i --out FILE`), phase 3 merges the edges back into the cache. A cache whose
edges are all planned is skipped, so a run cut short continues where it stopped. -j defaults to
cores/2: each process is single-threaded but holds a baked mesh (about 1.5 GB)."""
import argparse, json, os, subprocess, sys, shlex, concurrent.futures as cf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ap = argparse.ArgumentParser()
ap.add_argument("--maps", default="")
ap.add_argument("-j", type=int, default=max(1, (os.cpu_count() or 2) // 2))
ap.add_argument("--replan", action="store_true")
ap.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
ap.add_argument("--wrap", default=os.environ.get("SURF_WRAP", "heavy --"))
a = ap.parse_args()
os.chdir(ROOT)
maps = a.maps.split(",") if a.maps else sorted(m for m in os.listdir("maps/imported") if m.startswith("surf_"))
os.makedirs(".godot/surf-rides", exist_ok=True)
wrap = shlex.split(a.wrap)

def run(m, tail, log, timeout):
    cmd = wrap + ["timeout", str(timeout), *shlex.split(a.godot), "--headless", "--path", ".", "res://tools/surf_rides.tscn", "--", m, *tail]
    with open(log, "ab") as f:
        return subprocess.call(cmd, stdout=f, stderr=subprocess.STDOUT) == 0

def cache(m):
    p = f"maps/surf/{m}.surf.json"
    try:
        return json.load(open(p))
    except Exception:
        return None

def planned(e):
    return "planned" in e

def explore(m):
    ok = run(m, ["--explore"], f".godot/surf-rides/{m}.log", 2400)
    print("explored" if ok else "explore FAIL", m, flush=True)

def plan(job):
    m, i = job
    out = f"res://.godot/surf-rides/{m}-{i}.json"
    ok = run(m, ["--plan", str(i), "--out", out], f".godot/surf-rides/{m}.{i}.log", 5400)
    print("planned" if ok else "plan FAIL", m, "edge", i, flush=True)

with cf.ThreadPoolExecutor(a.j) as ex:
    list(ex.map(explore, [m for m in maps if cache(m) is None]))
    jobs = []
    for m in maps:
        c = cache(m)
        if c:
            jobs += [(m, i) for i, e in enumerate(c.get("edges", [])) if a.replan or not planned(e)]
    print(len(jobs), "edges to plan", flush=True)
    list(ex.map(plan, jobs))

for m, i in jobs:
    part = f".godot/surf-rides/{m}-{i}.json"
    if not os.path.exists(part):
        continue
    c = cache(m)
    c["edges"][i] = json.load(open(part))["edges"][i]
    json.dump(c, open(f"maps/surf/{m}.surf.json", "w"), separators=(",", ":"))
    os.remove(part)
print("merged", flush=True)
