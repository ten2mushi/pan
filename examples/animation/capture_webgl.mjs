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

// Camera: spherical Lissajous orbit. The polar wobble frequencies are derived
// from cam-speed via the golden ratio (always incommensurate → quasi-periodic).
// --cam-speed   azimuthal angular velocity (rad/s). 0.10 → one orbit ~63s.
// --cam-radius  orbital distance in world units. Smaller = tighter framing.
// --cam-polar1  primary polar wobble amplitude (radians). 0 = flat orbit.
// --cam-polar2  secondary polar wobble amplitude; adds organic texture.
const CAM_SPEED  = arg("cam-speed",  "0.10");
const CAM_RADIUS = arg("cam-radius", "11");
const CAM_POLAR1 = arg("cam-polar1", "0.90");
const CAM_POLAR2 = arg("cam-polar2", "0.25");

// Edge recency: soft exponential fade over this many seconds.
// --edge-life  0 = no fade, all edges persist (original behaviour).
//              30 (default) → edges reach ~5% opacity at 30s, culled at 90s.
const EDGE_LIFE = arg("edge-life", "30");

// Colour: time-based hue progression across the piece.
// --hue-shift  fraction of the colour wheel (0–1). 0 = original ICE blue→white.
//              0.50 (default) = 180° rotation: blue→teal→green→violet→rose.
const HUE_SHIFT = arg("hue-shift", "0.50");

// kNN clustering mode for the constellation edge mesh.
// --knn         "spatial" (default) = K nearest in 3D position space.
//               "temporal" = K nearest in emission time (ribbon/thread).
//               "spectro-temporal" = spatial kNN with ±knn-window time constraint.
// --knn-k       neighbours per point (default 4). For temporal: 1=thread, 2=ribbon.
// --knn-window  time window in seconds for spectro-temporal mode (default 5).
const KNN_MODE   = arg("knn",        "spatial");
const KNN_K      = arg("knn-k",      "4");
const KNN_WINDOW = arg("knn-window", "5");

// Spectral peak detection (when the matrix contains full_spectrum).
// --max-peaks   peaks per frame (default 5; 0 = legacy single-point)
// --peak-floor  min power fraction of frame-max to count as peak (default 0.01)
const MAX_PEAKS  = arg("max-peaks",  "5");
const PEAK_FLOOR = arg("peak-floor", "0.01");
const PURE_FEATURE_SPACE = arg("pure-feature-space", "false");

const SRC = path.basename(BASE).replace(/\.features$/, "");
const OUT = arg("out", path.join(REPO, "data", "output", `${EXPERIMENT}_${SRC}`,
  `${SRC}.constellation.mp4`));
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
const params = new URLSearchParams({ base: BASE, capture: "1" });
if (TITLE) params.set("title", TITLE);
// Forward all viewer params as URL query strings
params.set("cam_speed",  CAM_SPEED);
params.set("cam_radius", CAM_RADIUS);
params.set("cam_polar1", CAM_POLAR1);
params.set("cam_polar2", CAM_POLAR2);
params.set("edge_life",  EDGE_LIFE);
params.set("hue_shift",  HUE_SHIFT);
params.set("knn",        KNN_MODE);
params.set("knn_k",      KNN_K);
params.set("knn_window", KNN_WINDOW);
params.set("max_peaks",  MAX_PEAKS);
params.set("peak_floor", PEAK_FLOOR);
params.set("pure_feature_space", PURE_FEATURE_SPACE);
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
} finally {
  try { cdp && cdp.close(); } catch { /* ignore */ }
  chrome.kill();
  srv.close();
  try { fs.rmSync(userDir, { recursive: true, force: true }); } catch { /* ignore */ }
}
