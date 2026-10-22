// Frames of the web client in a real browser, split at the loading cover (needs ?cl_perf, which
// makes the client set window.arena_gate_open when the gate opens).
//
//   node tools/browser_stall.mjs [pageUrl] [--budget-ms N]
//
// Connects over CDP to a Chrome on a GPU box (`gpu.sh cdp 9222`, GPU_CDP_SERVE=8099 for the page, an
// ssh -R for the game server's port); SwiftShader frame times say nothing. Prints fps and the worst
// frame for the cover, the first 2 s of play and the rest; exits 1 when the first 2 s of play hold a
// frame over --budget-ms (default 0, off). The cover's worst frame is the shell compiling the pack's
// scripts and the map build, so it is reported and not budgeted. How to run it: docs/client.md.
const pw = (await import(process.env.PLAYWRIGHT_CORE ?? '/home/christian/.local/share/mcp/playwright-mcp/node_modules/playwright-core/index.js')).default;
const args = process.argv.slice(2);
const budget = args.includes('--budget-ms') ? Number(args[args.indexOf('--budget-ms') + 1]) : 0;
const url = args.find(a => a.startsWith('http')) ?? 'http://127.0.0.1:8099/embed.html?server=ws://127.0.0.1:6174&cl_perf=5';
const browser = await pw.chromium.connectOverCDP(process.env.CDP ?? 'http://127.0.0.1:9222');
const page = await (browser.contexts()[0] ?? await browser.newContext()).newPage();
await page.setViewportSize({ width: 1280, height: 720 });
await page.addInitScript(() => {
  window.__frames = []; let last = performance.now();
  const tick = (t) => { window.__frames.push([t, t - last]); last = t; requestAnimationFrame(tick); };
  requestAnimationFrame(tick);
});
await page.goto(url, { waitUntil: 'load' });
let open = null;
for (let i = 0; i < 180 && open === null; i++) { await page.waitForTimeout(1000); open = await page.evaluate(() => window.arena_gate_open ?? null); }
await page.waitForTimeout(6000);
const r = await page.evaluate(() => {
  const gl = document.createElement('canvas').getContext('webgl2');
  return { frames: window.__frames, gpu: gl.getParameter(gl.getExtension('WEBGL_debug_renderer_info').UNMASKED_RENDERER_WEBGL) };
});
const stat = (a) => { if (!a.length) return null; const d = a.map(x => x[1]).sort((x, y) => x - y); const sum = a.reduce((s, x) => s + x[1], 0); return { n: a.length, fps: +(a.length / (sum / 1000)).toFixed(1), median: +d[d.length >> 1].toFixed(1), worst: +d[d.length - 1].toFixed(0) }; };
console.log('gpu', r.gpu, 'cover dropped at', open && open.toFixed(0), 'ms');
if (open === null) { console.log('FAIL the cover never dropped'); process.exit(1); }
const play = stat(r.frames.filter(f => f[0] > open && f[0] <= open + 2000));
console.log('cover  ', JSON.stringify(stat(r.frames.filter(f => f[0] <= open))));
console.log('play2s ', JSON.stringify(play));
console.log('after  ', JSON.stringify(stat(r.frames.filter(f => f[0] > open + 2000))));
await page.close();
process.exit(budget > 0 && play.worst > budget ? 1 : 0);
