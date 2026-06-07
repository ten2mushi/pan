# examples/animation — audio-reactive 3-D feature animations

Turns a recording into a generative 3-D point-cloud animation, using the **pan
library** for all feature extraction and **WebGL** for rendering. One command runs
the whole pipeline and writes a self-describing output folder.

```
audio ─(to_lpcm)─► mono/stereo f32 LPCM ─(example-analyze, pan)─► <base>.f32 + .json
                                                                       │
                                  ┌────────────────────────────────────┤
                                  ▼                                     ▼
                            viewer.html                          capture_webgl.mjs
                       (three.js, real-time GPU,             (headless Chrome → mp4,
                        interactive orbit/scrub)              audio muxed; no npm deps)
```

## One command

```
python examples/animation/render.py <experiment>          # e.g. andesana_helix
python examples/animation/render.py --list                # show all experiments
python examples/animation/render.py --batch               # the curated compound "hero" set
python examples/animation/render.py --all                 # render every experiment
python examples/animation/render.py incea_torus --seconds 20   # quick preview
python examples/animation/render.py andesana_helix --fps 60 --cam-speed 0.05  # ad-hoc overrides
```

An experiment is named `<input>_<mode>`. **Inputs** (in `experiments.py`): `andesana`
(overtone singing), `incea`, `pachelbel` (Canon in D), `integraation`, `strasbourgeoise`
— add your own by dropping a file in `data/input/` and one line in `INPUTS`. **Modes** are
listed below. `--list` prints every registered combination.

`render.py` resolves the experiment, then runs **decode → frequency pre-scan →
analyze → GPU capture → stamp config**, caching every stage. The output folder is

```
data/output/animation/ideation/<EXPERIMENT>/
├── <experiment>.mp4              the render (audio muxed)
├── <experiment>_description.md   what you're seeing + the exact reproduce command
├── config.json                   the fully-resolved parameters (output ↔ config link)
└── features.json                 the feature-matrix column layout
```

So an output is never orphaned from the code/config that produced it: the
description carries `python examples/animation/render.py <experiment>`, and
`config.json` records the mode, FFT window, detected frequency band, fps, channels,
and every forwarded viewer parameter.

## Files

| file | role |
|---|---|
| `render.py` | The orchestrator (the single command). Decode (cached), numpy frequency pre-scan, analyze (cached), drive the capturer, stamp `config.json` + `_description.md`. |
| `experiments.py` | Declarative experiment registry. Every render is named `<input>_<mode>`; the full mode×input grid is generated, hand-tuned presets extend it. |
| `layouts.js` | **Standalone, importable** visualization modes. Each mode = `place()` (geometry) + `knn` (edge strategy) + `camera()` (its own adapted motion). Add a mode here; nothing else changes. |
| `analyze.zig` | The pan Analyzer pull graph → per-frame feature matrix. Runtime **granularity** (`frame` ∈ 1024/2048/4096/8192) and a `--stereo` path (two STFT branches → L/R spectra). |
| `viewer.html` | Self-contained three.js viewer: spectral peak detection, mode dispatch, fat-line kNN web, ICE colour, track-adaptive pitch axis. Live (orbit/scrub) or headless. |
| `capture_webgl.mjs` | Headless-Chrome frame capture (DevTools Protocol, zero npm deps) → mp4 with audio muxed (silent intermediate auto-deleted). |
| `probe.py` | Thin mono/stereo probe: is this input *usably* stereo? Used to gate `channels=stereo`. |
| `spectrogram.py` | Wide, high-res STFT spectrogram PNG from the same feature matrix (`python spectrogram.py <input>`; see below). |

## Modes

Each mode carries its own camera (the camera is part of the design — pure feature
space gets an auto-fitting orbit that always frames the whole cube; the timeline
flies down its own time axis; etc.).

| mode | kind | what it does |
|---|---|---|
| `feature-space` | information | Axes are the features (X brightness, Y pitch, Z loudness). Auto-fitting camera tours the whole feature cube. |
| `cylinder` | aesthetic | Audio-driven phyllotaxis: azimuth = frame×golden-angle + centroid drift, radius = loudness+flux, height = pitch — time→angle, so the cloud grows as an emergent cylindrical coil. Global kNN web. |
| `constellation` | aesthetic | An **organic acoustic-similarity star cloud**: points embedded purely by timbre (sphere direction from brightness/pitch-class, radius from energy, deterministic feature-hash jitter), never by time, so similar moments cluster with no central form. |
| `timeline` | information | Cartesian timbre space — time unrolled along Z, pitch up Y, brightness across X; the camera flies down the timeline. |
| `helix` | aesthetic | The Shepard pitch helix — one turn per octave, height = octave; harmonic series spiral, octave-related partials stack. |
| `torus` | aesthetic | The chroma torus — pitch class wraps the tube, octave wraps the ring; rising pitch winds around the surface. |
| `harmonic` | information | **Harmonic comb / overtone detachment.** Per frame the fundamental f0 is estimated (HPS); every partial sits on a vertical ladder by harmonic number, the sung pitch slides the ladder, time unrolls into depth, and a reinforced overtone *detaches* (brighter, lifted) the instant it overtakes the fundamental. Edges are the comb teeth. |
| `pca` | information | **PCA timbral fingerprint.** Each frame is projected onto the track's own top-3 principal timbral axes (centroid/rolloff/flux/rms + flatness + spectral contrast + MFCCs); acoustically-similar moments cluster, so the silhouette is unique to the track. Built in `render.py` (numpy SVD), served as `<base>.pca.*.f32`. |
| `stereo-field` | information | **Stereo only.** Each peak placed at its real pan position (√L−√R)/(√L+√R); pitch up Y, time into Z — a literal moving image of the stereo spectrum. |

## Dynamic granularity (frequency resolution)

The FFT window is a runtime knob: bigger window = finer Hz/bin (better harmonic
separation) at the cost of coarser time resolution and a larger matrix. Set it per
experiment (`"frame": 4096`) or ad-hoc (`--frame 4096`). The viewer adapts to the
resulting bin count automatically via the sidecar. `render.py` also **pre-scans each
track's active frequency band** (numpy) and feeds `[f_lo, f_hi]` to the viewer so the
log-pitch axis fits the track instead of guessing.

## Mono vs. stereo

`render.py` decodes to mono by default. Request stereo per experiment
(`"channels": "stereo"`) or ad-hoc (`--channels stereo`). Stereo runs two STFT
branches and stores both per-bin spectra, so the viewer can place each peak at its
stereo pan position (and the `stereo-field` mode visualises exactly that).

A 2-channel container is not necessarily *usably* stereo (a phone voice memo is
dual-mono). `probe.py` measures the Side/(Mid+Side) energy fraction; if it's below
the 3% threshold, **`channels=stereo` fails with a clear message** rather than
rendering a misleading stereo image:

```
python examples/animation/probe.py "<file>"          # report
python examples/animation/render.py incea_constellation --channels stereo
  → ERROR: 'incea' is not usably stereo (side energy 0.93% < 3% threshold). Re-run with channels=mono.
```

## Colour & bloom (perceptual, no rainbow)

Colour and glow are fully CLI-configurable (all viewer-only — no re-analysis):

| flag | default | meaning |
|---|---|---|
| `--color-space oklch\|linear` | `oklch` | interpolate the ramp perceptually (OKLab) or in straight RGB. |
| `--palette ice\|ember\|aurora\|bone\|mono` | `ice` | curated multi-stop gradient (all muted, no full hue wheel). |
| `--color-by pitch\|timbre\|pan\|constant` | `pitch` | what drives the ramp position (timbre = per-frame spectral flatness; pan = stereo position). |
| `--sat-by-timbre 0\|1` | `0` | scale chroma by tonality: tonal→saturated, breathy/noisy→grey. |
| `--bloom 0\|1` + `--bloom-strength/-radius/-threshold` | off / 0.7 / 0.4 / 0.6 | cinematic glow (UnrealBloomPass via EffectComposer). |
| `--tonemap 0\|1` | follows `--bloom` | ACES tonemap so additive transients roll off into glow instead of clipping to flat white. |

Harmonic-comb knobs: `--f0-method dominant|lowest|hps`, `--harmonic-max-n`,
`--harmonic-tolerance-cents`, `--overtone-detach 0|1`, `--harmonic-spacing/-xscale/-timev`.
PCA knobs: `--pca-features <scalars,flatness,contrast,mfcc>`, `--pca-whiten 0|1`,
`--pca-pitch-spread <f>`.

## Compound "hero" renders

`experiments.py` generates a curated set that stacks these features — per-track
palette (ice/ember/aurora), saturation-by-timbre, ACES-tonemapped bloom, and long
soft edge trails on the artistic modes — overriding the plain grid entries:

```
python examples/animation/render.py --batch        # render the whole curated set
python examples/animation/render.py andesana_harmonic
python examples/animation/render.py pachelbel_pca
```

## Aesthetic defaults

Pure-black void; a narrow **ICE** blue→white frequency ramp (no rainbow — `hue_shift`
defaults to 0). Round glowing points with a tight grow-then-shrink birth pulse. A
**fat** (screen-space, not 1px) kNN web with a soft exponential recency fade
(`edge_life` is the fade time; 60 → ~20 s soft trails). Slow cameras. Source audio is
always muxed into the mp4.

## Spectrogram (2-D view of the same data)

A wide, high-resolution STFT spectrogram straight from the cached feature matrix —
the literal 2-D form of `timeline` mode (time × frequency × power, with the *full*
spectrum on Y instead of a per-frame summary):

```
python examples/animation/spectrogram.py incea
python examples/animation/spectrogram.py incea --px-per-sec 300 --height 3200   # deeper zoom
# knobs: --frame --px-per-sec --height --fmin --fmax --db-range --cmap
```

Output → `data/output/animation/ideation/<input>_spectrogram/<input>_spectrogram.png`
(log-frequency y-axis, seconds x-axis, dB colour; default 140 px/s ≈ 2.3 px per 60-fps hop).

## Build / dependencies

- `zig build examples` builds `zig-out/bin/example-analyze` (auto-built on first run).
- The repo `.venv` (numpy/scipy) + `ffmpeg` for decode/pre-scan.
- **node ≥ 22** + Chrome/Chromium + `ffmpeg` for `capture_webgl.mjs` (no `npm install`).

## Live exploration

```
python3 -m http.server 8000
# open: http://localhost:8000/examples/animation/viewer.html?base=data/work/andesana.f4096.features&mode=helix
```
Drag to orbit · scroll to zoom · space = play/pause · slider scrubs.
