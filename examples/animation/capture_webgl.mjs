#!/usr/bin/env node
// Headless-GPU frame capture for the WebGL constellation viewer
// (examples/animation/viewer.html). DEPENDENCY-FREE: it talks to Chrome's DevTools
// Protocol directly over Node's built-in WebSocket/fetch (Node ≥ 22) — no puppeteer,
// no node_modules. It drives the SAME viewer.html in headless Chrome (scene drawn by
// the GPU), steps it frame-by-frame, reads each frame via canvas.toDataURL (JPEG,
// direct WebGL framebuffer — no compositor screenshot), pipes JPEGs into ffmpeg as
// mjpeg, and muxes the matching audio.
//
// Speed vs the old Page.captureScreenshot path:
//   • JPEG instead of PNG → skips deflate, ~3× smaller payload over CDP WS
//   • canvas.toDataURL reads the GPU framebuffer directly, skips the compositor
//   • 1-frame lookahead: next frame evaluated while current frame is written to ffmpeg
//
// Usage (run from the repo root; needs only `node`, a Chrome/Chromium, and ffmpeg):
//   node examples/animation/capture_webgl.mjs --base data/work/<source>.features \
//        --audio "data/input/<source>/<source>_lpcm.wav" [--out PATH] [--fps 30] \
//        [--start 0] [--seconds 0] [--width 1920] [--height 1080] [--title STR] [--chrome PATH]
//   --out defaults to data/output/animation_<source>/<source>.constellation.mp4

import http from "node:http";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const EXPERIMENT = "animation";

function arg(name, def) {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}
const BASE = arg("base");
if (!BASE) { console.error("need --base"); process.exit(2); }
const AUDIO = arg("audio", "");
const FPS = parseInt(arg("fps", "30"));
const START = parseFloat(arg("start", "0"));
const SECONDS = parseFloat(arg("seconds", "0"));
const W = parseInt(arg("width", "1920"));
const H = parseInt(arg("height", "1080"));
const TITLE = arg("title", "");

// The visualization MODE. Each mode (defined in layouts.js) carries its own
// adapted camera, edge strategy and aesthetic defaults, so we deliberately do NOT
// inject hardcoded camera/edge/hue defaults here — only forward params the caller
// EXPLICITLY set, letting the mode defaults win otherwise.
// --mode  feature-space | constellation | timeline | helix | torus
const MODE = arg("mode", "constellation");

// Track-adaptive frequency window (Hz). The orchestrator pre-scans the audio and
// passes the real active band so the log-pitch axis fits this track exactly.
const FREQ_LO = arg("freq-lo");
const FREQ_HI = arg("freq-hi");

// Optional explicit overrides (undefined = use the mode's own default).
// --cam-speed/-radius/-polar1/-polar2  spherical-orbit params
// --edge-life  edge fade lifetime (s); 0 = persistent web
// --edge-width edge thickness in screen pixels (fat lines)
// --hue-shift  colour-wheel rotation over the piece (0 = pure ICE; default)
// --knn / --knn-k / --knn-window  edge meshing override
// --max-peaks / --peak-floor  spectral peak detection
const OPT = {
  cam_speed:  arg("cam-speed"),
  cam_radius: arg("cam-radius"),
  cam_polar1: arg("cam-polar1"),
  cam_polar2: arg("cam-polar2"),
  edge_life:  arg("edge-life"),
  edge_width: arg("edge-width"),
  hue_shift:  arg("hue-shift"),
  knn:        arg("knn"),
  knn_k:      arg("knn-k"),
  knn_window: arg("knn-window"),
  max_peaks:  arg("max-peaks"),
  peak_floor: arg("peak-floor"),
  // colour & bloom
  color_space:     arg("color-space"),
  palette:         arg("palette"),
  color_by:        arg("color-by"),
  sat_by_timbre:   arg("sat-by-timbre"),
  bloom:           arg("bloom"),
  bloom_strength:  arg("bloom-strength"),
  bloom_radius:    arg("bloom-radius"),
  bloom_threshold: arg("bloom-threshold"),
  tonemap:         arg("tonemap"),
  point_gain:      arg("point-gain"),
  exposure:        arg("exposure"),
  // harmonic comb
  f0_method:                 arg("f0-method"),
  harmonic_max_n:            arg("harmonic-max-n"),
  harmonic_tolerance_cents:  arg("harmonic-tolerance-cents"),
  overtone_detach:           arg("overtone-detach"),
  harmonic_spacing:          arg("harmonic-spacing"),
  harmonic_xscale:           arg("harmonic-xscale"),
  harmonic_timev:            arg("harmonic-timev"),
  // pca timbral fingerprint
  pca_file:         arg("pca-file"),
  pca_pitch_spread: arg("pca-pitch-spread"),
};

const SRC = path.basename(BASE).replace(/\.features$/, "");
const OUT = arg("out", path.join(REPO, "data", "output", `${EXPERIMENT}_${SRC}`,
  `${SRC}.${MODE}.mp4`));
fs.mkdirSync(path.dirname(OUT), { recursive: true });

const CHROME = arg("chrome", findChrome());

function findChrome() {
  const cands = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
  ];
  for (const c of cands) if (fs.existsSync(c)) return c;
  return "google-chrome";
}

const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".json": "application/json", ".f32": "application/octet-stream" };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function startServer() {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      const url = decodeURIComponent(req.url.split("?")[0]);
      const fp = path.join(REPO, url);
      if (!fp.startsWith(REPO) || !fs.existsSync(fp) || fs.statSync(fp).isDirectory()) {
        res.writeHead(404); res.end("not found"); return;
      }
      res.writeHead(200, { "content-type": MIME[path.extname(fp)] || "application/octet-stream" });
      fs.createReadStream(fp).pipe(res);
    });
    srv.listen(0, "127.0.0.1", () => resolve(srv));
  });
}
function freePort() {
  return new Promise((res) => {
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => res(p)); });
  });
}
function ffmpegPipe(silent) {
  // Input is MJPEG (JPEG frames) — matches canvas.toDataURL("image/jpeg") output.
  // ffmpeg decodes each JPEG and re-encodes to H.264; no extra transcode overhead.
  return spawn("ffmpeg", ["-v", "error", "-y", "-f", "mjpeg", "-framerate", String(FPS),
    "-i", "-", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast", silent],
    { stdio: ["pipe", "inherit", "inherit"] });
}
function run(cmd, a) {
  return new Promise((res, rej) => {
    const p = spawn(cmd, a, { stdio: ["ignore", "inherit", "inherit"] });
    p.on("close", (c) => (c === 0 ? res() : rej(new Error(cmd + " exit " + c))));
  });
}
function writeChunk(stream, buf) {
  return new Promise((res) => { stream.write(buf) ? res() : stream.once("drain", res); });
}

// --- a tiny CDP (Chrome DevTools Protocol) client over the built-in WebSocket ---
function connectCDP(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const pending = new Map();
    let nextId = 0;
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && pending.has(m.id)) {
        const { res, rej } = pending.get(m.id); pending.delete(m.id);
        m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
      }
    };
    ws.onerror = (e) => reject(e.error || new Error("ws error"));
    ws.onopen = () => resolve({
      send: (method, params = {}) => new Promise((res, rej) => {
        const id = ++nextId; pending.set(id, { res, rej });
        ws.send(JSON.stringify({ id, method, params }));
      }),
      close: () => ws.close(),
    });
  });
}

const srv = await startServer();
const port = srv.address().port;
const cdpPort = await freePort();
const userDir = fs.mkdtempSync(path.join(os.tmpdir(), "pancap-"));
const params = new URLSearchParams({ base: BASE, capture: "1", mode: MODE });
if (TITLE) params.set("title", TITLE);
if (FREQ_LO !== undefined) params.set("freq_lo", FREQ_LO);
if (FREQ_HI !== undefined) params.set("freq_hi", FREQ_HI);
// Forward ONLY explicitly-set overrides; absent params fall to the mode's own
// adapted defaults inside layouts.js.
for (const [k, v] of Object.entries(OPT)) if (v !== undefined) params.set(k, v);
const pageUrl = `http://127.0.0.1:${port}/examples/animation/viewer.html?${params}`;

const chrome = spawn(CHROME, [
  "--headless=new", "--no-sandbox", "--hide-scrollbars", "--mute-audio",
  "--disable-extensions", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist",
  `--remote-debugging-port=${cdpPort}`, `--window-size=${W},${H}`,
  "--force-device-scale-factor=1", `--user-data-dir=${userDir}`, pageUrl,
], { stdio: "ignore" });

let cdp;
try {
  // wait for the DevTools endpoint, then find the viewer page target
  let target = null;
  for (let i = 0; i < 100 && !target; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${cdpPort}/json/list`)).json();
      target = list.find((t) => t.type === "page" && t.url.includes("viewer.html"));
    } catch { /* not up yet */ }
    if (!target) await sleep(100);
  }
  if (!target) throw new Error("Chrome DevTools page target not found (is Chrome installed?)");
  cdp = await connectCDP(target.webSocketDebuggerUrl);

  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: W, height: H, deviceScaleFactor: 1, mobile: false });

  // wait for the viewer module to finish loading (fetch matrix + build scene)
  // 1200 polls × 100 ms = 120 s; large .f32 files (9+ MB) can take 5–10 s to fetch
  // and the kNN mesh build for 180k nodes takes another few seconds.
  let ready = false;
  for (let i = 0; i < 1200 && !ready; i++) {
    const r = await cdp.send("Runtime.evaluate",
      { expression: "!!(window.panViewer && window.panViewer.ready)", returnByValue: true });
    ready = r.result.value === true;
    if (!ready) await sleep(100);
    if (i > 0 && i % 100 === 0) console.error(`  still waiting for viewer… (${i / 10}s)`);
  }
  if (!ready) {
    // try to surface the JS error from the page
    const errR = await cdp.send("Runtime.evaluate",
      { expression: "document.getElementById('err')?.textContent || '(no error element)'", returnByValue: true });
    const consoleErrs = await cdp.send("Runtime.evaluate",
      { expression: "window._panErr || ''", returnByValue: true });
    console.error("page error element:", errR.result.value);
    console.error("window._panErr:", consoleErrs.result.value);
    throw new Error("viewer.html never became ready (check the matrix path / console)");
  }

  const info = JSON.parse((await cdp.send("Runtime.evaluate", {
    expression: "JSON.stringify({totalT:window.panViewer.totalT,fps:window.panViewer.fps})",
    returnByValue: true,
  })).result.value);
  const dur = SECONDS > 0 ? Math.min(SECONDS, info.totalT - START) : (info.totalT - START);
  const N = Math.max(1, Math.round(dur * FPS));
  console.error(`capture: ${N} frames @ ${FPS}fps (${dur.toFixed(1)}s, start ${START}s) via headless Chrome (CDP, no deps)`);

  const silent = OUT.replace(/\.mp4$/, "") + ".silent.mp4";
  const ff = ffmpegPipe(silent);
  const t0 = Date.now();

  // captureFrame(tt) — reads the WebGL framebuffer via canvas.toDataURL (JPEG),
  // bypassing the CDP compositor screenshot path entirely.
  const JPEG_Q = 0.92;
  const captureExpr = (tt) =>
    `(()=>{ const d=window.panViewer.captureFrame(${tt},${JPEG_Q}); return d.slice(d.indexOf(",")+1); })()`;

  // 1-frame lookahead: fire the JS evaluation for frame f+1 while we write frame f
  // to ffmpeg stdin — hides most of the serialization latency.
  let pendingB64 = cdp.send("Runtime.evaluate", { expression: captureExpr(START), returnByValue: true });
  for (let f = 0; f < N; f++) {
    const nextT = START + (f + 1) / FPS;
    // kick off next frame evaluation before we block on writing current frame
    const nextB64 = f + 1 < N
      ? cdp.send("Runtime.evaluate", { expression: captureExpr(nextT), returnByValue: true })
      : null;
    const cur = await pendingB64;
    await writeChunk(ff.stdin, Buffer.from(cur.result.value, "base64"));
    if (f % 60 === 0) console.error(`  frame ${f}/${N}  (${((Date.now() - t0) / Math.max(1, f + 1)).toFixed(0)} ms/frame)`);
    pendingB64 = nextB64;
  }
  ff.stdin.end();
  await new Promise((r) => ff.on("close", r));
  console.error(`capture: ${((Date.now() - t0) / N).toFixed(1)} ms/frame avg -> ${silent}`);

  if (AUDIO) {
    await run("ffmpeg", ["-v", "error", "-y", "-i", silent, "-ss", String(START), "-i", AUDIO,
      "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
      "-shortest", OUT]);
    console.error(`muxed audio -> ${OUT}`);
  } else {
    fs.copyFileSync(silent, OUT);
  }
  // The silent intermediate is redundant once the final mp4 exists — drop it so a
  // batch doesn't accumulate a full second copy of every render (disk-friendly).
  try { fs.rmSync(silent, { force: true }); } catch { /* ignore */ }
} finally {
  try { cdp && cdp.close(); } catch { /* ignore */ }
  chrome.kill();
  srv.close();
  try { fs.rmSync(userDir, { recursive: true, force: true }); } catch { /* ignore */ }
}
