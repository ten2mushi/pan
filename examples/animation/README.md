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
| `analyze.zig` | The pan Analyzer graph: `LpcmSource → Stft → PowerSpectrum → {full_spectrum[1025], dominant band, RMS, centroid, rolloff, flux}` + `Framer → BallisticEnvelope` → `Concat → FeatureCollectorSink`. Built by `zig build examples` → `zig-out/bin/example-analyze`. Emits `<base>.features.f32` (row-major f32, 1031 columns per 60 fps hop) + `.json` sidecar. |
| `viewer.html` | Self-contained three.js/WebGL viewer with **spectral peak detection**: instead of one point per frame, the viewer extracts the top spectral peaks from the full 1025-bin power spectrum, emitting one point per peak per frame. This reveals polyphonic structure — simultaneous notes, harmonics, and timbral layers each get their own point. Backward-compatible with old 13-col matrices (single-point legacy path). |
| `capture_webgl.mjs` | Renders `viewer.html` to an mp4 by driving headless Chrome over the **DevTools Protocol** using Node's built-in `WebSocket`/`fetch` — **zero npm dependencies** — then muxes the audio. |

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

## What you see

### Spectral peak detection (new — 1031-col matrices)
When the feature matrix contains the `full_spectrum` column (1025 power-spectrum bins per
frame), the viewer performs **spectral peak detection**: for each frame, it finds local
maxima in the power spectrum and emits one point per peak (up to `--max-peaks`). This
solves two visual artefacts present in the old single-point-per-frame approach:

- **"Infinity symbol" during silence** — zero power → zero peaks → no points born →
  kNN has nothing to cluster into anomalous shapes.
- **"Big kick" masking** — a loud bass kick occupies low-frequency bins, but concurrent
  hi-hats, synths, and vocals appear as separate peaks at higher frequencies. Each gets
  its own point at the correct pitch on the Y-axis. No masking.

Point positions use a **log-frequency Y-axis** (perceptually correct pitch spacing) and
the colour of each point reflects its individual peak frequency, not just the dominant band.

### Visual schema
- **colour** = peak frequency (icy blue→white ramp) + time-based hue progression (`--hue-shift`);
- **node size/brightness** = peak power (normalised against the 95th percentile);
- each node is born small, pulses (a tight grow-then-shrink), then settles;
- **edges** form a crystalline mesh via kNN clustering, with a soft exponential recency fade (`--edge-life`);
- **camera** drifts in a spherical Lissajous orbit quasi-periodically.

### Backward compatibility
Old 13-col matrices (without `full_spectrum`) fall through to the legacy single-point-per-frame
path automatically. No re-analysis needed.

## Configuration & CLI Arguments
The rendering pipeline is highly configurable. `capture_webgl.mjs` forwards these directly to the viewer:

**Spectral Peak Detection**
* `--max-peaks`: Maximum spectral peaks to emit per frame (default: 5). Set to `0` to force the legacy single-point-per-frame path even for new matrices.
* `--peak-floor`: Minimum power fraction of a frame's peak to count as a spectral peak (default: 0.01 = 1% of frame-max). Lower values produce more points from quieter harmonics.

**Clustering & Layout**
* `--knn`: `spatial` (default, folds time into an overlapping cylinder), `temporal` (pure timeline thread/ribbon), or `spectro-temporal` (unrolls time along the Z-axis into a *Cartesian Timbre Space*, mapping Pitch to Y and Texture/Centroid to X).
* `--knn-k`: Neighbours per point (default: 4).
* `--knn-window`: Time window constraint in seconds for spectro-temporal mode (default: 5).

**Aesthetics**
* `--edge-life`: Soft exponential fade duration in seconds for the crystalline web (default: 30). Set to `0` to disable fading.
* `--hue-shift`: Total colour wheel rotation over the piece duration (default: 0.50 = 180° shift from icy blue to rose).

**Camera (Spherical Lissajous)**
* `--cam-speed`: Azimuthal angular velocity (default: 0.10).
* `--cam-radius`: Orbital distance (default: 11).
* `--cam-polar1` & `--cam-polar2`: Golden-ratio-incommensurate polar wobble amplitudes (default: 0.90 and 0.25). Set to `0` for a flat equatorial orbit.

## Dependencies
`scripts/decode_audio.py` (numpy/scipy, ffmpeg for compressed inputs) · `zig build
examples` for the analyzer · **node ≥ 22** + a Chrome/Chromium + **ffmpeg** for
`capture_webgl.mjs` (auto-detects Chrome; override with `--chrome PATH`). No `npm
install` needed.
