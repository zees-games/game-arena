#!/usr/bin/env python3
"""Judges one netchaos run (reports, server truth, logs) and aggregates runs.

  netchaos_eval.py RUN_DIR PROFILE NAME:BOX...    writes RUN_DIR/result.json, prints a summary
  netchaos_eval.py OUT_DIR --all PROFILE...       writes OUT_DIR/summary.json and payload.json

Thresholds are the tunables below; each can be overridden with the environment variable
NC_<NAME> (for example NC_POS_SELF=0.1). A per-profile value is a dict keyed by profile.
"""
import json
import math
import os
import re
import sys

# Per profile: longest stretch (s) a client may go without a snapshot, longest first join (s),
# worst single prediction correction (m), and the share of replays that needed a correction.
GAP_S = {"clean": 1.0, "lossy100": 2.5, "jitter200": 4.0, "awful400": 8.0, "bwcap": 8.0, "blackout": 8.0}
JOIN_S = {"clean": 20.0, "lossy100": 30.0, "jitter200": 35.0, "awful400": 45.0, "bwcap": 30.0, "blackout": 30.0}
WORST_ERR_M = {"clean": 0.5, "lossy100": 1.0, "jitter200": 1.5, "awful400": 3.0, "bwcap": 3.0, "blackout": 3.0}
CORRECTION_RATE = {"clean": 0.10, "lossy100": 0.25, "jitter200": 0.40, "awful400": 0.60, "bwcap": 0.30, "blackout": 0.30}
# Settled (everyone idle for the settle time) distance to the server's truth.
POS_SELF_M = 0.25
POS_OTHER_M = 0.75
REJOIN_S = 25.0
SERVER_FRAME_MS = 500.0
SERVER_ERR = re.compile(r"\bERROR\b|\bFATAL\b|SCRIPT ERROR")
# The server's first calls reach a client before its Arena link node exists (see netchaos_client.gd).
JOIN_RACE = re.compile(r'Node not found: "Netchaos/Server/Arena"|Parameter "node" is null|Invalid packet received. Requested node was not found|Failed to get path from RPC|scene_cache_interface|node\.cpp:1975|scene_rpc_interface|rpcp \(|get_node \(scene')
JOIN_RACE_MAX = 12
CLIENT_ERR = re.compile(r"SCRIPT ERROR|Parse Error|leaked at exit|still in use at exit|^ERROR:|Invalid (get|set|call)|Cannot (call|infer)")


def tun(name, default, profile=None):
    v = os.environ.get("NC_" + name)
    if v is not None:
        return float(v)
    return default[profile] if isinstance(default, dict) else default


def dist(a, b):
    return math.dist(a[:3], b[:3])


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def grep(path, rx, limit=6, skip=None):
    out = []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if skip is not None and skip.search(line):
                    continue
                if rx.search(line):
                    out.append(line.strip()[:200])
    except OSError:
        pass
    return out[:limit], len(out)


def judge(run, profile, names):
    checks = []

    def check(client, label, ok, detail):
        checks.append({"client": client, "check": label, "ok": bool(ok), "detail": detail})

    truth = load(os.path.join(run, "srv", "truth.json"))
    check("server", "truth.json written (server stopped cleanly)", truth is not None, "")
    srv = (truth or {}).get("server", {})
    check("server", "server worst frame under %d ms" % tun("SERVER_FRAME_MS", SERVER_FRAME_MS),
          srv.get("worst_frame_ms", 1e9) <= tun("SERVER_FRAME_MS", SERVER_FRAME_MS), "%.0f ms" % srv.get("worst_frame_ms", -1))
    errs, n = grep(os.path.join(run, "server.log"), SERVER_ERR)
    check("server", "no ERROR lines in the server log", n == 0, "; ".join(errs))
    want = len(names)
    check("server", "all %d clients still connected at the end" % want, srv.get("peers", -1) == want, "peers=%s" % srv.get("peers"))
    tp = (truth or {}).get("players", {})
    clients = []
    for entry in names:
        name, box = entry.split(":", 1)
        rep = load(os.path.join(run, "client-%s.json" % name))
        c = {"name": name, "box": box}
        check(name, "report written", rep is not None, "")
        if rep is None:
            _, n = grep(os.path.join(run, "client-%s.log" % name), CLIENT_ERR)
            clients.append(c)
            continue
        c.update(joins=rep["join_seconds"], sessions=rep["sessions"], disconnects=rep["disconnects"],
                 rejoin_seconds=rep["rejoin_seconds"], prediction=rep["prediction"],
                 max_gap_s=round(rep["max_snapshot_gap_s"], 2), stats=rep.get("stats", {}),
                 rtt_p50=rep.get("stats", {}).get("rtt_p50"), rtt_p95=rep.get("stats", {}).get("rtt_p95"))
        check(name, "connected and playing at the end", rep["connected"] and rep.get("link_playing") and rep.get("clock_synced"),
              "errors=%s" % rep["errors"])
        check(name, "load gate open (not stuck loading)", rep.get("gate_open", False), "")
        first = rep["join_seconds"][0] if rep["join_seconds"] else 1e9
        lim = tun("JOIN_S", JOIN_S, profile)
        check(name, "first join under %.0f s" % lim, first <= lim, "%.1f s" % first)
        if profile == "blackout":
            check(name, "after the blackout it is playing again (%d drop(s), rejoin %s)" % (len(rep["disconnects"]), rep["rejoin_seconds"]),
                  all(s <= tun("REJOIN_S", REJOIN_S) for s in rep["rejoin_seconds"]), "")
        else:
            check(name, "no disconnect", not rep["disconnects"], str(rep["disconnects"]))
        lim = tun("GAP_S", GAP_S, profile)
        check(name, "longest snapshot gap under %.1f s" % lim, rep["max_snapshot_gap_s"] <= lim, "%.2f s" % rep["max_snapshot_gap_s"])
        p = rep["prediction"]
        rate = p["corrections"] / p["replays"] if p["replays"] else 0.0
        c["correction_rate"] = round(rate, 3)
        lim = tun("CORRECTION_RATE", CORRECTION_RATE, profile)
        check(name, "correction rate under %.0f%%" % (lim * 100), rate <= lim,
              "%d of %d replays" % (p["corrections"], p["replays"]))
        lim = tun("WORST_ERR_M", WORST_ERR_M, profile)
        check(name, "worst correction under %.2f m" % lim, p["worst_error_m"] <= lim, "%.3f m" % p["worst_error_m"])
        me = rep.get("self")
        pname = me["name"] if me else None
        if me and pname in tp and tp[pname][3] and me["alive"]:
            e = dist(me["pos"], tp[pname])
            c["pos_error_self_m"] = round(e, 3)
            lim = tun("POS_SELF_M", POS_SELF_M)
            check(name, "settled own position within %.2f m of the server" % lim, e <= lim, "%.3f m" % e)
        else:
            check(name, "own player present in the server truth", me is not None and pname in tp, "self=%s" % (me or {}).get("name"))
        worst = 0.0
        seen = 0
        for oname, o in rep.get("others", {}).items():
            if oname in tp and tp[oname][3] and o[3]:
                worst = max(worst, dist(o, tp[oname]))
                seen += 1
        lim = tun("POS_OTHER_M", POS_OTHER_M)
        c["pos_error_others_m"] = round(worst, 3)
        check(name, "sees all %d other players" % (want - 1), len(rep.get("others", {})) >= want - 1, "saw %d" % len(rep.get("others", {})))
        check(name, "settled view of the others within %.2f m of the server" % lim, worst <= lim, "%.3f m over %d" % (worst, seen))
        log = os.path.join(run, "client-%s.log" % name)
        _, races = grep(log, re.compile(r'Node not found: "Netchaos/Server/Arena"'))
        check(name, "join race under %d engine errors per session" % tun("JOIN_RACE_MAX", JOIN_RACE_MAX),
              races <= tun("JOIN_RACE_MAX", JOIN_RACE_MAX) * rep["sessions"], "%d seen" % races)
        errs, n = grep(log, CLIENT_ERR, skip=JOIN_RACE)
        check(name, "no script errors or leaked objects in stderr", n == 0, "; ".join(errs))
        clients.append(c)
    tc = open(os.path.join(run, "tc-after.txt")).read() if os.path.exists(os.path.join(run, "tc-after.txt")) else ""
    check("tc", "every qdisc clean afterwards", "IMPAIRED" not in tc, tc.replace("\n", " ")[:300])
    return checks, clients, srv


def summarise_run(run, profile, names):
    checks, clients, srv = judge(run, profile, names)
    failed = [c for c in checks if not c["ok"]]
    res = {"profile": profile, "checks": len(checks), "failed": len(failed), "failures": failed, "clients": clients,
           "server": {"worst_frame_ms": srv.get("worst_frame_ms"), "peers": srv.get("peers")}}
    with open(os.path.join(run, "result.json"), "w") as f:
        json.dump(res, f, indent=1)
    print("  %-10s %d checks, %d failed" % (profile, len(checks), len(failed)))
    for c in clients:
        p = c.get("prediction", {})
        print("    %-3s %-9s join %s s  gap %s s  rtt p50/p95 %s/%s  corr %s/%s (%.0f%%)  worst %.3f m  err self %s others %s  sessions %s" % (
            c["name"], c["box"], ["%.1f" % j for j in c.get("joins", [])], c.get("max_gap_s"),
            c.get("rtt_p50") and round(c["rtt_p50"]), c.get("rtt_p95") and round(c["rtt_p95"]),
            p.get("corrections"), p.get("replays"), 100 * c.get("correction_rate", 0), p.get("worst_error_m", 0),
            c.get("pos_error_self_m"), c.get("pos_error_others_m"), c.get("sessions")))
    for c in failed:
        print("    FAIL %s: %s %s" % (c["client"], c["check"], c["detail"]))
    return len(failed) == 0


def aggregate(out, profiles):
    total = failed = 0
    failures = []
    runs = []
    for prof in profiles:
        r = load(os.path.join(out, prof, "result.json"))
        if r is None:
            total += 1
            failed += 1
            failures.append({"name": prof, "repro": "tools/netchaos.sh --profile " + prof, "reasons": ["no result (the run did not finish)"]})
            continue
        runs.append(r)
        total += r["checks"]
        failed += r["failed"]
        if r["failures"]:
            failures.append({"name": "netchaos " + prof, "repro": "heavy -- tools/netchaos.sh --profile " + prof,
                             "reasons": ["%s: %s %s" % (f["client"], f["check"], f["detail"]) for f in r["failures"]][:8]})
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump({"runs": runs, "total": total, "failed": failed}, f, indent=1)
    with open(os.path.join(out, "payload.json"), "w") as f:
        json.dump({"summary": {"total": total, "failed": failed}, "failures": failures}, f, indent=1)
    print("netchaos: %d checks over %d profile(s), %d failed" % (total, len(profiles), failed))
    return failed == 0


if __name__ == "__main__":
    if "--all" in sys.argv:
        ok = aggregate(sys.argv[1], [a for a in sys.argv[3:]])
    else:
        ok = summarise_run(sys.argv[1], sys.argv[2], sys.argv[3:])
    sys.exit(0 if ok else 1)
