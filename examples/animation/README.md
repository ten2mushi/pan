# examples/animation — audio-reactive 3-D particle visualization

Turns a recording into the `notes/1.md` generative 3-D point-cloud animation, using
the **pan library** for all feature extraction. Two visual styles share one feature
matrix, and there are two render backends (offline CPU, or real-time GPU).

```
audio ─(scripts/decode_audio.py)─► mono f32 LPCM ─(example-analyze, pan)─► features.f32
                                                                              │
                              ┌───────────────────────────────────────────────┤
                              ▼                                                 ▼
                   render_viz.py / render_viz_v2.py                       viewer.html
                   (matplotlib, offline file)                       (three.js, real-time GPU)
                                                                          │
                                                                  capture_webgl.mjs
                                                                  (headless-GPU → mp4 file)
```

## Files
| file | role |
|---|---|
| `analyze.zig` | the pan Phase-9 Analyzer graph (`LpcmSource → Stft → PowerSpectrum → {dominant band, RMS, centroid, rolloff, flux, flatness, contrast}` + `Framer → BallisticEnvelope` → `Concat → FeatureCollectorSink`). Built by `zig build examples` → `zig-out/bin/example-analyze`. Emits `<base>.features.f32` (row-major f32, one row per 60 fps hop) + `.json` sidecar. |
| `render_viz.py` | **classic** style — soft rainbow particle field (matplotlib, offline). |
| `render_viz_v2.py` | **constellation** style — icy crystalline neural-web (matplotlib, offline). |
| `run_pipeline.py` | one-command driver: decode → analyze → render, with audio muxed and a numeric shape-check. |
| `viewer.html` | real-time WebGL viewer of the feature matrix (interactive orbit + scrub). |
| `capture_webgl.mjs` | headless-Chrome capture of `viewer.html` → mp4 (GPU, ~3–5× faster than matplotlib). |

## Run (from the repo root)

End-to-end (decode + analyze + render + mux), constellation style:
```
.venv/bin/python examples/animation/run_pipeline.py \
    "data/input/<source>/<source>_lpcm.wav" --style constellation --fps 30
# --style classic for the rainbow particle field; --seconds N / --start S to excerpt
```

Real-time GPU render to a file (reuses a cached `data/work/<source>.features`):
```
node examples/animation/capture_webgl.mjs \
    --base data/work/<source>.features \
    --audio "data/input/<source>/<source>_lpcm.wav" --fps 30 --title "<Source>"
```

Interactive viewer:
```
python3 -m http.server 8000
# open http://localhost:8000/examples/animation/viewer.html?base=data/work/<source>.features
```

## Output
Each run writes to its own folder: **`data/output/animation_<source>/<source>.constellation.mp4`**
(or `.mp4` for classic), with the source audio muxed in. 1920×1080 @ 30 fps.

## What you see (notes/1.md schema)
- **colour** = the most-active frequency band at emission (icy blue→white ramp);
- **node size/brightness** = the 0–1 signal amplitude;
- a node is born small, pulses (grow-then-shrink), then settles into the accumulating
  trail; the **current point** is whichever node is mid-pulse;
- thin lines link each point to its nearest neighbours **in frequency/feature space**
  (a constellation that grows as the piece plays);
- the bottom-left readout tracks the current point (frequency, amplitude, lifetime,
  emission time); a slow camera orbits the structure.

## Dependencies
`scripts/decode_audio.py` (numpy/scipy, ffmpeg for compressed inputs) · the venv
(`numpy scipy matplotlib`) for the Python renderers · `zig build examples` for the
analyzer · node + `puppeteer-core` + a system Chrome + ffmpeg for `capture_webgl.mjs`.
