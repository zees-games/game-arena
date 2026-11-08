#!/usr/bin/env python3
"""index.html for a weapon-lab run: one section per weapon with its strips, clips, orbit stills and close-ups."""
import glob, html, json, os, sys

out, run = sys.argv[1], sys.argv[2]
rows = []
for wdir in sorted(d for d in glob.glob(os.path.join(out, "*/")) if os.path.exists(os.path.join(d, "manifest.json"))):
    wid = os.path.basename(wdir.rstrip("/"))
    man = json.load(open(os.path.join(wdir, "manifest.json")))
    parts = [f"<section id='{wid}'><h2>{html.escape(wid)}</h2>"]
    na = [f"{a}: {r.get('why', r.get('status'))}" for a, r in man.get("fp", {}).items() if r.get("status") != "ok"]
    if na:
        parts.append("<p class='na'>" + html.escape("; ".join(na)) + "</p>")
    for a in man.get("fp", {}):
        if os.path.exists(os.path.join(wdir, f"fp_{a}.mp4")):
            parts.append(f"<figure><figcaption>first person: {a}</figcaption><video src='{wid}/fp_{a}.mp4' controls loop muted preload='none'></video>"
                         f"<a href='{wid}/fp_{a}_strip.png'><img loading='lazy' src='{wid}/fp_{a}_strip.png'></a></figure>")
    if os.path.exists(os.path.join(wdir, "tp_turntable.mp4")):
        parts.append(f"<figure><figcaption>model: turntable and orbit</figcaption><video src='{wid}/tp_turntable.mp4' controls loop muted preload='none'></video>"
                     f"<a href='{wid}/tp_orbit_strip.png'><img loading='lazy' src='{wid}/tp_orbit_strip.png'></a></figure>")
    for f in sorted(glob.glob(os.path.join(wdir, "tp_closeup_*.jpg"))):
        parts.append(f"<a href='{wid}/{os.path.basename(f)}'><img class='c' loading='lazy' src='{wid}/{os.path.basename(f)}'></a>")
    parts.append("</section>")
    rows.append("".join(parts))
nav = " ".join(f"<a href='#{os.path.basename(d.rstrip('/'))}'>{os.path.basename(d.rstrip('/'))}</a>" for d in sorted(glob.glob(os.path.join(out, "*/"))) if os.path.exists(os.path.join(d, "manifest.json")))
page = f"""<!doctype html><meta charset=utf-8><title>weapon lab {html.escape(run)}</title>
<style>body{{font:14px sans-serif;background:#1d1f22;color:#ddd;margin:16px}}a{{color:#8cf}}video,img{{max-width:480px;margin:4px;vertical-align:top}}
img.c{{max-width:240px}}figure{{display:inline-block;margin:6px;max-width:960px}}.na{{color:#fa6}}section{{border-top:1px solid #444;margin-top:12px}}</style>
<h1>Weapon lab {html.escape(run)}</h1><p>Same room, camera and light for every clip. {nav}</p>{''.join(rows)}"""
open(os.path.join(out, "index.html"), "w").write(page)
print(f"index.html: {len(rows)} weapons")
