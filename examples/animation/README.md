# examples/animation — audio-reactive 3-D constellation visualization

Turns a recording into the `notes/1.md` generative 3-D point-cloud animation, using
the **pan library** for all feature extraction and **WebGL** for rendering. No Python
and no npm dependencies — just the pan binary, a browser/Chrome, and ffmpeg.

```
audio ─(scripts/decode_audio.py)─► mono f32 LPCM ─(example-analyze, pan)─► <source>.features.f32
                                                                              │
                                              ┌────────────────────────────────┤
                                              ▼                                 ▼
                                       viewer.html                       capture_webgl.mjs
                                  (three.js, real-time GPU,           (headless Chrome via the
                                   interactive orbit/scrub)            DevTools Protocol → mp4)
```

## Files
| file | role |
|---|---|
| `analyze.zig` | the pan Phase-9 Analyzer graph (`LpcmSource → Stft → PowerSpectrum → {dominant band, RMS, centroid, rolloff, flux, flatness, contrast}` + `Framer → BallisticEnvelope` → `Concat → FeatureCollectorSink`). Built by `zig build examples` → `zig-out/bin/example-analyze`. Emits `<base>.features.f32` (row-major f32, one row per 60 fps hop) + `.json` sidecar. |
| `viewer.html` | self-contained three.js/WebGL viewer of the feature matrix: an icy crystalline neural-web that grows as the piece plays, real-time on the GPU, with interactive orbit + a scrub bar. All per-point behaviour (recency fade, birth pulse) runs in GLSL. |
| `capture_webgl.mjs` | renders `viewer.html` to an mp4 by driving headless Chrome over the **DevTools Protocol** using Node's built-in `WebSocket`/`fetch` — **zero npm dependencies** — then muxes the audio. |

## Run (from the repo root)

1. Decode the source to mono LPCM:
```
.venv/bin/python scripts/decode_audio.py \
    "data/input/<source>/<source>_lpcm.wav" data/work/<source>
```
2. Run the pan analysis (build the binary first with `zig build examples`):
```
./zig-out/bin/example-analyze data/work/<source>.mono.f32 44100 data/work/<source>.features
```
3a. Render to a file (GPU, headless):
```
node examples/animation/capture_webgl.mjs \
    --base data/work/<source>.features \
    --audio "data/input/<source>/<source>_lpcm.wav" --fps 30 --title "<Source>"
```
3b. …or explore it live in a browser:
```
python3 -m http.server 8000
# open http://localhost:8000/examples/animation/viewer.html?base=data/work/<source>.features
```

## Output
`capture_webgl.mjs` writes to **`data/output/animation_<source>/<source>.constellation.mp4`**
(auto-created), 1920×1080 @ 30 fps, with the source audio muxed in. `--out PATH` overrides.

## What you see (notes/1.md schema)
- **colour** = the most-active frequency band at emission (icy blue→white ramp);
- **node size/brightness** = the 0–1 signal amplitude;
- each node is born small, pulses (a tight grow-then-shrink), then settles into the
  accumulating trail — the **current point** is whichever node is mid-pulse;
- hair-thin lines link each point to its nearest neighbours **in frequency/feature
  space**, a constellation that grows as the piece plays;
- bottom-left readout tracks the current point (frequency, amplitude, lifetime,
  emission time); the camera drifts slowly around the structure.

## Dependencies
`scripts/decode_audio.py` (numpy/scipy, ffmpeg for compressed inputs) · `zig build
examples` for the analyzer · **node ≥ 22** + a Chrome/Chromium + **ffmpeg** for
`capture_webgl.mjs` (auto-detects Chrome; override with `--chrome PATH`). No `npm
install` needed.
