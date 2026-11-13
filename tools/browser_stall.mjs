// Frames of the FC web client in a real browser, split at the loading cover (needs ?cl_perf, which
// makes the client set window.dotWeb.publishedAt.arena_gate_open when the gate opens).
//
//   node tools/browser_stall.mjs [pageUrl] [--budget-ms N] [--runs N] [--phases]
//
// Connects over CDP to a Chrome on a GPU box (`gpu.sh cdp-run --serve 8099 -- node ...` sets
// GPU_CDP_URL; or CDP=..., default 127.0.0.1:9222); SwiftShader frame times say nothing. Per run it
// prints fps and the worst frame for the cover, the first 2 s of play and the rest, the content
// download's end (the page's .pck/.dot-pack responses), the cover drop, the time to the first smooth
// second (no frame of 50 ms or more for 1 s) and the worst frames after the drop, each named by the
// client's last load mark before it (arena_load / arena_after_open, published by ArenaLoadTimeline).
// --phases also prints the load marks on the page clock, after the boot marks (each .wasm/.pck/.js
// fetch with its size over the wire, wasm compile, the engine's first prints). Several runs end in a median line. Exits 1
// when a run's first 2 s of play hold a frame over --budget-ms (default 0, off). How to run it:
// docs/client.md.
const pw = (await import(process.env.PLAYWRIGHT_CORE ?? '/home/christian/.local/share/mcp/playwright-mcp/node_modules/playwright-core/index.js')).default;
const args = process.argv.slice(2);
const num = (flag, dflt) => args.includes(flag) ? Number(args[args.indexOf(flag) + 1]) : dflt;
const budget = num('--budget-ms', 0);
const runs = num('--runs', 1);
const phases = args.includes('--phases');
const url = args.find(a => a.startsWith('http')) ?? 'http://127.0.0.1:8099/embed.html?server=ws://127.0.0.1:6174&cl_perf=5';
const SMOOTH_MS = 50;
const browser = await pw.chromium.connectOverCDP(process.env.CDP ?? process.env.GPU_CDP_URL ?? 'http://127.0.0.1:9222');
const context = browser.contexts()[0] ?? await browser.newContext();
const stat = (a) => { if (!a.length) return null; const d = a.map(x => x[1]).sort((x, y) => x - y); const sum = a.reduce((s, x) => s + x[1], 0); return { n: a.length, fps: +(a.length / (sum / 1000)).toFixed(1), median: +d[d.length >> 1].toFixed(1), worst: +d[d.length - 1].toFixed(0) }; };
const median = (a) => { const s = a.filter(x => x != null).sort((x, y) => x - y); return s.length ? +s[s.length >> 1].toFixed(0) : null; };

// Load marks on the page clock: a published report's engine stamps shifted by its publish time.
function pageMarks(report, at) {
  if (!report || at == null) return [];
  const r = JSON.parse(report);
  return r.marks.map(([ms, frame, label]) => [at - (r.now_ms - ms), frame, label]);
}

async function run(i) {
  const page = await context.newPage();
  const errors = new Map(); const raw = [];
  page.on('console', (m) => { if (m.type() !== 'error' && m.type() !== 'warning') return; if (raw.length < 16 && /ERROR|Error|at: /.test(m.text()) && !raw.includes(m.text().slice(0, 240))) raw.push(m.text().slice(0, 240)); const k = m.text().replace(/uid:\/\/\w+/g, 'uid://*').replace(/res:\/\/\S+/g, 'res://*').slice(0, 140); errors.set(k, (errors.get(k) ?? 0) + 1); });
  await page.setViewportSize({ width: 1280, height: 720 });
  await page.addInitScript(() => {
    window.__frames = []; let last = performance.now();
    const tick = (t) => { window.__frames.push([t, t - last]); last = t; requestAnimationFrame(tick); };
    requestAnimationFrame(tick);
    // Boot marks before the engine's own load marks exist: wasm compile and the first engine prints.
    window.__boot = []; const mark = (l) => window.__boot.push([performance.now(), l]);
    for (const f of ['instantiate', 'instantiateStreaming', 'compile', 'compileStreaming']) {
      const orig = WebAssembly[f]; if (!orig) continue;
      WebAssembly[f] = function (...a) { mark(`wasm ${f} begins`); const p = orig.apply(this, a); p.then(() => mark(`wasm ${f} done`), () => {}); return p; };
    }
    let printed = 0;
    for (const f of ['log', 'info']) { const orig = console[f]; console[f] = function (...a) { if (printed < 4) { printed++; mark(`console: ${String(a[0]).slice(0, 80)}`); } return orig.apply(this, a); }; }
  });
  await page.goto(url, { waitUntil: 'load' });
  let open = null;
  for (let s = 0; s < 180 && open === null; s++) { await page.waitForTimeout(1000); open = await page.evaluate(() => window.dotWeb?.publishedAt?.arena_gate_open ?? null); }
  for (let s = 0; s < 12; s++) { await page.waitForTimeout(1000); if (await page.evaluate(() => window.dotWeb?.publishedAt?.arena_after_open != null)) break; }
  await page.waitForTimeout(1000);
  const r = await page.evaluate(() => {
    const gl = document.createElement('canvas').getContext('webgl2');
    const packs = performance.getEntriesByType('resource').filter(e => /\.(pck|dot-pack|wasm)(\?|$)/.test(e.name));
    const w = window.dotWeb ?? { published: {}, publishedAt: {} };
    const MB = (b) => (b / 1048576).toFixed(1);
    const files = performance.getEntriesByType('resource').filter(e => /\.(pck|dot-pack|wasm|js)(\?|$)/.test(e.name))
      .flatMap(e => [[e.startTime, `fetch ${e.name.split('/').pop().split('?')[0]} begins`],
        [e.responseEnd, `fetch ${e.name.split('/').pop().split('?')[0]} done ${MB(e.decodedBodySize)} MB, ${MB(e.transferSize)} MB over the wire, ${(e.responseEnd - e.startTime).toFixed(0)} ms`]]);
    return { frames: window.__frames, gpu: gl.getParameter(gl.getExtension('WEBGL_debug_renderer_info').UNMASKED_RENDERER_WEBGL),
      download: packs.length ? Math.max(...packs.map(e => e.responseEnd)) : null,
      boot: [...performance.getEntriesByType('navigation').flatMap(n => [[n.requestStart, 'page request'], [n.responseEnd, 'page received'], [n.domContentLoadedEventEnd, 'page parsed']]), ...files, ...(window.__boot ?? [])], load: w.published.arena_load, loadAt: w.publishedAt.arena_load, after: w.published.arena_after_open, afterAt: w.publishedAt.arena_after_open };
  });
  await page.close();
  if (i === 0) console.log('gpu', r.gpu, 'url', url);
  if (open === null) { console.log(`run ${i + 1} FAIL the cover never dropped`); return null; }
  const marks = [...r.boot.map(([t, label]) => [t, 0, label]), ...pageMarks(r.load, r.loadAt), ...pageMarks(r.after, r.afterAt)].sort((a, b) => a[0] - b[0]);
  const nameAt = (t) => { let m = null; for (const x of marks) { if (x[0] <= t) m = x; else break; } return m ? m[2] : '?'; };
  const after = r.frames.filter(f => f[0] > open);
  let smooth = null;
  for (let k = 0; k < after.length && smooth === null; k++) {
    const start = after[k][0];
    if (after[k][1] >= SMOOTH_MS) continue;
    let ok = true, end = start;
    for (let j = k + 1; j < after.length && after[j][0] <= start + 1000; j++) { end = after[j][0]; if (after[j][1] >= SMOOTH_MS) { ok = false; break; } }
    if (ok && end >= start + 900) smooth = start;
  }
  const play = stat(r.frames.filter(f => f[0] > open && f[0] <= open + 2000));
  const worst = [...after].sort((a, b) => b[1] - a[1]).slice(0, 5);
  const out = { run: i + 1, download_ms: r.download && +r.download.toFixed(0), open_ms: +open.toFixed(0),
    open_after_download_ms: r.download && +(open - r.download).toFixed(0), first_smooth_after_open_ms: smooth && +(smooth - open).toFixed(0),
    first_smooth_ms: smooth && +smooth.toFixed(0), play2s: play, cover: stat(r.frames.filter(f => f[0] <= open)), after: stat(r.frames.filter(f => f[0] > open + 2000)) };
  console.log(JSON.stringify(out));
  const errs = [...errors].sort((a, b) => b[1] - a[1]);
  console.log(`  console errors/warnings: ${errs.reduce((s, e) => s + e[1], 0)}`, errs.slice(0, 4).map(([k, n]) => `${n}x ${k}`).join(' | '));
  if (phases) for (const t of raw) console.log('    err:', t);
  console.log('  worst after open:', worst.map(f => `${f[1].toFixed(0)}ms@+${(f[0] - open).toFixed(0)} [${nameAt(f[0] - f[1])}]`).join('; '));
  if (phases) for (let k = 0; k < marks.length; k++) {
    const gap = k ? marks[k][0] - marks[k - 1][0] : 0;
    console.log(`  ${marks[k][0].toFixed(0).padStart(6)} (+${gap.toFixed(0).padStart(4)}, f${marks[k][1]}) ${marks[k][2]}`);
  }
  return out;
}

const all = [];
for (let i = 0; i < runs; i++) all.push(await run(i));
const ok = all.filter(Boolean);
if (runs > 1 && ok.length) console.log('median', JSON.stringify({ runs: ok.length, open_after_download_ms: median(ok.map(o => o.open_after_download_ms)),
  first_smooth_after_open_ms: median(ok.map(o => o.first_smooth_after_open_ms)), play2s_worst: median(ok.map(o => o.play2s?.worst)),
  play2s_fps: median(ok.map(o => o.play2s?.fps)), cover_worst: median(ok.map(o => o.cover?.worst)) }));
process.exit(ok.length < runs || (budget > 0 && ok.some(o => o.play2s && o.play2s.worst > budget)) ? 1 : 0);
