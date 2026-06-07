# Pipelines (grounding: `incea`)

Telegram-style step dump. Enough to reproduce. One command does it all:
`python examples/animation/render.py <input>_<mode>` (e.g. `incea_constellation`).

`incea`: `data/input/incea/AUD-20260607-WA0000.m4a`, 111.1 s, dual-mono (0.93% side → stereo refused), frame=4096.

---

## A. PREPROCESS (shared, run once / cached)

1. **decode** — `to_lpcm.py --rate 44100 <src> data/work/incea`
   → `data/work/incea.mono.f32` (mono float32 LE @44100). [stereo path: ffmpeg `channelsplit` → `incea.L.f32`+`incea.R.f32`]
2. **scan_band** (numpy, DIAGNOSTIC ONLY — not fed to viewer) — Hann, frame=4096 non-overlap, mean |rfft|², cumulative-energy 2/98 pctile → `[f_lo,f_hi]` (incea 86–2207 Hz). Logged into config.json only.
3. **analyze** — `zig-out/bin/example-analyze incea.mono.f32 44100 data/work/incea.f4096.features 4096`
   → `incea.f4096.features.f32` (+ `.json` sidecar).
   - pan STFT: frame=4096, **hop=735** (=44100/60 → 60 analysis fps), bins=frame/2+1=**2049**, **hz_per_bin=44100/4096=10.77**.
   - matrix = row-major f32, `n_frames × n_cols`. cols: `full_spectrum`(2049 power) · `dominant`(bin) · `amplitude`(0..1 ballistic) · `rms` · `centroid`(bin) · `rolloff`(bin) · `flux`. [stereo: `full_spectrum_l`+`full_spectrum_r`, scalars off L]
4. **(pca mode only) compute_pca** (render.py numpy) — per-frame vector = `[centroid,rolloff,flux,rms]` + flatness(gm/am) + contrast(6 log-spaced sub-bands, log(peak)−log(valley), q=±20%) + MFCC(mel filterbank 26 → log → DCT-II → keep 13) → z-score → `np.linalg.svd` → project top-3 → robust scale per-axis to ~[−8,8] (2/98 pctile) → `incea.f4096.features.pca.<featsig>.f32`. passes `--pca-file`.

caching: each stage skipped if output newer than input.

---

## B. RENDER (shared) — `capture_webgl.mjs` → `viewer.html` → ffmpeg

5. **serve+drive** — node serves repo over http; headless Chrome (`--headless=new`, swiftshader) loads `viewer.html?base=data/work/incea.f4096.features&mode=<mode>&capture=1&<params>`.
6. **viewer load** — fetch `.json`+`.f32` (+ `.pca.*.f32` if pca mode).
7. **peak detect** (per frame, if `amplitude_norm>0.003`): frameMax → floor=frameMax·`peak_floor`(0.01) → local maxima over ±2 bins → keep top `max_peaks`(incea **6**) by power. one point per peak per frame.
8. **band** = 1st/99th pctile of all detected peak-Hz → `[flo,fhi]`; **out-of-band peaks DROPPED** (not clamped). (render.py does NOT pass freq overrides.)
9. **per-frame flatness** = exp(mean(log p))/mean(p), pctile-normalised → drives color-by-timbre + sat.
10. **per-point `p`** = `{lf` (log-freq norm over band)`, pAmp` (power/p95)`, cen,flux,rol` (98-pctile norm)`, pan` ((√L−√R)/(√L+√R), 0 mono)`, peakHz, az` (Σ golden-angle + 0.6·centroid-drift/fps)`, t=i/60, i}`.
11. **place** = `MODES[mode].place(p,ctx)` → xyz (see §C). `ctx`={octLo/Hi/Mid/Span, totalT, fps, nFrames, cam, center/diag (bbox, post-placement), pca, harm*}.
12. **color** = `colorForU(u,frac,chromaScale)`: palette stops interp in OKLab (`color_space=oklch`); `u` from `color_by` (pitch=lf · timbre=flatN · pan=(pan+1)/2 · constant=0.7); `chromaScale=1−0.85·flatN` if `sat_by_timbre`.
13. **edges** = kNN per mode strategy (§C): spatial (grid, k=4) · spectro-temporal (+|Δt|≤window) · temporal · harmonic (ladder rungs).
14. **draw** — points: additive blend, size=4.5+5·pAmp+birth-pulse, alpha = `(0.12+0.88·fresh)·life·(0.30+0.45·pAmp)+0.45·gb·life` clamp[0,0.82]; **node life `life=exp(-age/(edge_life·0.4))`** (edge_life=0→persistent). edges: fat `LineSegments2`, fade `0.62·exp(-age/(edge_life·0.33))`. bloom (UnrealBloomPass, strength 0.7/radius 0.4/threshold 0.72) + ACES tonemap exposure 0.85 if `--bloom 1`.
15. **camera** = `MODES[mode].camera(tt,ctx)` (§C). scripted in capture (free orbit live).
16. **capture+mux** — step frames @ `--fps 30`, 1920×1080, `canvas.toDataURL(jpeg,0.92)` → mjpeg → ffmpeg libx264 yuv420p → `<name>.silent.mp4` → mux audio (`-c:a aac -b:a 192k -shortest`) → `<name>.mp4`; silent auto-deleted.
17. **stamp** — `config.json` (resolved params, reproduce cmd) + `features.json` + `<name>_description.md` into `data/output/animation/ideation/<name>/`.

---

## C. MODES (place · knn · camera · edge_life)

vars: `lg=log2(peakHz)`, `pc=lg−floor(lg)` (pitch class), `az`=golden-angle azimuth, `TAU=2π`.

- **feature-space** — `[(cen−.5)·13, (lf−.5)·13, (pAmp−.5)·13]` · spatial · autoFitOrbit · edge_life **0** (persistent scatter).
- **cylinder** — `r=1+4.6·pAmp+2.2·flux`; `[r·cos az, (lf−.5)·8+.5·sin(az/2), r·sin az]` · spatial · sphericalLissajous · edge_life 30.
- **constellation** — dir: cosθ=(cen−.5)·2, az=pc·TAU; `r=3+9·(0.55·pAmp+0.45·flux)`; +feature-hash jitter(0.9), +yNudge=(rol−.5)·2.6 · spatial · autoFitOrbit · edge_life 30.
- **timeline** — `[(cen−.5)·16, (lf−.5)·8, −t·2]` · spectro-temporal(window 5) · flythrough down −Z · edge_life 12.
- **helix** — ang=pc·TAU, `r=3+3·pAmp`, `y=(lg−octMid)·2.2`; `[r cos, y, r sin]` · spatial · orbit+bob · edge_life 22. *(not in compound batch)*
- **torus** — minor=pc·TAU, major=((lg−octLo)/octSpan)·TAU, R=7.5, r=2+1.6·pAmp; `[(R+r cos minor)cos major, r sin minor, (…)sin major]` · spatial · sphericalLissajous · edge_life 26.
- **harmonic** *(viewer branch, not a place())* — f0/frame via `f0_method`(hps: ∏ 5 downsampled mag copies, search 60–1000 Hz); partial accepted iff `n=round(hz/f0)∈[1,harmonic_max_n=16]` & `|1200·log2(hz/(n·f0))|≤harmonic_tolerance_cents=35`; `X=(log2 f0−octMid)·6, Y=(n−1)·0.9, Z=−t·2`; **detach** (`overtone_detach=1`) if partial power>fundamental → Y+0.6, X+0.7, brighter/bigger; edges=consecutive-n within frame (comb teeth) · flythrough −Z · edge_life 24. *(incea not used — harmonic = andesana, pachelbel only)*
- **pca** — `[pca[i·3]+(lf−.5)·spread, pca[i·3+1]+(pAmp−.5)·spread·.5, pca[i·3+2]+(flux−.5)·spread·.5]`, `spread=pca_pitch_spread`(incea 0.6) · spatial · autoFitOrbit · edge_life 30. needs `--pca-file`.
- **stereo-field** *(stereo only)* — `[pan·11, (lf−.5)·8, −t·2]` · spectro-temporal(window 4) · flythrough · edge_life 10.

---

## D. COMPOUND "hero" style (what `--batch` / the registry applies)

per-track palette: andesana=**ice**, pachelbel=**ember**, incea=**aurora**. all: `color_by=pitch, sat_by_timbre=1, bloom=1`, max_peaks=8 (incea 6). artistic (constellation/cylinder/torus) override **edge_life=60** (≈20–24 s soft trails, nodes+edges coupled). info modes keep own edge_life. helix excluded.

incea set rendered: `incea_{constellation,cylinder,torus,feature-space,timeline,pca}` (no harmonic, no stereo).

reproduce one: `python examples/animation/render.py incea_constellation`
reproduce all incea: loop the 6 names above.
