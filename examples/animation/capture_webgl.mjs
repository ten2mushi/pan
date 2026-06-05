#!/usr/bin/env node
// Headless-GPU frame capture for the WebGL constellation viewer
// (examples/animation/viewer.html).
//
// The offline Python renderers rasterize each frame on the CPU (~0.2 s/frame). This
// drives the SAME viewer.html in headless Chrome — so the scene is drawn by the GPU
// (WebGL) — steps it frame-by-frame deterministically, screenshots each composited
// frame (3-D scene + HUD overlays), pipes the PNGs straight into ffmpeg, and muxes
// the matching audio. No matplotlib, no temp PNGs on disk.
//
// Usage (run from the repo root):
//   node examples/animation/capture_webgl.mjs --base data/work/<name>.features \
//        --audio "<source audio>" [--out PATH] [--fps 30] [--start 0] [--seconds 0] \
//        [--width 1920] [--height 1080] [--title STR]
//   --out defaults to data/output/animation_<source>/<source>.constellation.mp4
//
// Requires: a Chrome/Chromium executable (auto-detected or --chrome PATH) and ffmpeg.

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const EXPERIMENT = "animation";  // output dir: data/output/<EXPERIMENT>_<source>/

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
// Default output: data/output/animation_<source>/<source>.constellation.mp4
const SRC = path.basename(BASE).replace(/\.features$/, "");
const OUT = arg("out", path.join(REPO, "data", "output", `${EXPERIMENT}_${SRC}`,
  `${SRC}.constellation.mp4`));
fs.mkdirSync(path.dirname(OUT), { recursive: true });

const CHROME = arg("chrome",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome");

const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".json": "application/json", ".f32": "application/octet-stream" };

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

function ffmpegPipe(silent) {
  const a = ["-y", "-f", "image2pipe", "-framerate", String(FPS), "-i", "-",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast", silent];
  const p = spawn("ffmpeg", ["-v", "error", ...a], { stdio: ["pipe", "inherit", "inherit"] });
  return p;
}
function run(cmd, a) {
  return new Promise((res, rej) => {
    const p = spawn(cmd, a, { stdio: ["ignore", "inherit", "inherit"] });
    p.on("close", (c) => (c === 0 ? res() : rej(new Error(cmd + " exit " + c))));
  });
}
function write(stream, buf) {
  return new Promise((res) => { stream.write(buf) ? res() : stream.once("drain", res); });
}

const srv = await startServer();
const port = srv.address().port;
const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: "new",
  args: ["--no-sandbox", "--hide-scrollbars", "--mute-audio",
         "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist",
         `--window-size=${W},${H}`],
});
try {
  const page = await browser.newPage();
  await page.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
  const params = new URLSearchParams({ base: BASE, capture: "1" });
  if (TITLE) params.set("title", TITLE);
  const url = `http://127.0.0.1:${port}/examples/animation/viewer.html?${params}`;
  await page.goto(url, { waitUntil: "load", timeout: 60000 });
  await page.waitForFunction("window.panViewer && window.panViewer.ready", { timeout: 60000 });

  const info = await page.evaluate(() => ({ totalT: window.panViewer.totalT, fps: window.panViewer.fps }));
  const dur = SECONDS > 0 ? Math.min(SECONDS, info.totalT - START) : (info.totalT - START);
  const N = Math.max(1, Math.round(dur * FPS));
  console.error(`capture: ${N} frames @ ${FPS}fps (${dur.toFixed(1)}s, start ${START}s) via headless Chrome`);

  const silent = OUT.replace(/\.mp4$/, "") + ".silent.mp4";
  const ff = ffmpegPipe(silent);
  const t0 = Date.now();
  for (let f = 0; f < N; f++) {
    const t = START + f / FPS;
    await page.evaluate((tt) => window.panViewer.renderAt(tt), t);
    const png = await page.screenshot({ type: "png" });
    await write(ff.stdin, png);
    if (f % 120 === 0) console.error(`  frame ${f}/${N}  (${((Date.now()-t0)/Math.max(1,f)).toFixed(0)} ms/frame)`);
  }
  ff.stdin.end();
  await new Promise((r) => ff.on("close", r));
  console.error(`capture: ${((Date.now()-t0)/N).toFixed(1)} ms/frame avg -> ${silent}`);

  if (AUDIO) {
    await run("ffmpeg", ["-v", "error", "-y", "-i", silent, "-ss", String(START), "-i", AUDIO,
      "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
      "-shortest", OUT]);
    console.error(`muxed audio -> ${OUT}`);
  } else {
    fs.copyFileSync(silent, OUT);
  }
} finally {
  await browser.close();
  srv.close();
}
