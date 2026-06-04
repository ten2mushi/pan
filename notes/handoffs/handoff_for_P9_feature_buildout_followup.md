# Handoff — P9 feature-extraction buildout (first wave landed) → next wave

> **Status:** P0–P9 done + green; the P9 **feature-extraction buildout first wave is implemented and
> green across the four-mode matrix** + smoke / cross-linux / fmt-check / neg-compile / bench-gate
> (all exit 0). This session EXTENDED the analysis catalog and CLOSED the open P9 boundary §4.1.
> Advisory handoff, not a spec — `specifications/` + `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-04. **Toolchain:** `zig 0.16.0` (re-run `zig version` first — Rule 13).
> Predecessor: `notes/handoffs/handoff_for_P9_feature_buildout.md` (the mission brief) and
> `notes/p9_coverage_audit.md` (the P9 gate audit). This file records what the buildout added on top.

---

## 1. What landed this session (honest, Rule 12)

**14 new feature-extraction blocks** in `src/feat.zig`, each a rate-1:1 `Map`, each with its EXACT formula
restated in the doc-comment (self-contained, §0.2 — no spec/research refs in `src/`). That doc-comment IS
the oracle spec. All reachable as `pan.feat.<Name>` (the `feat` namespace is re-exported at `root.zig`).

Spectrum-consuming Maps (`[]const FeatureFrame(bins)` → scalar/vector), identical shape to the original 5:
- `SpectralRolloff` (`feat.zig:310`) → `Scalar(f32)` — 0.85-energy rolloff bin.
- `SpectralFlatness` (`feat.zig:351`) → `Scalar(f32)` — Wiener entropy (geo/arith mean), clamped [0,1].
- `SpectralEntropy` (`feat.zig:391`) → `Scalar(f32)` — normalized Shannon entropy of the spectral PMF.
- `SpectralSpread` (`feat.zig:430`) → `Scalar(f32)` — power-weighted std about the centroid (bin units).
- `SpectralSkewness` (`feat.zig:468`) → `Scalar(f32)` — 3rd standardized moment.
- `SpectralKurtosis` (`feat.zig:490`) → `Scalar(f32)` — 4th standardized moment (RAW, ≈3 for Gaussian).
  - both share the comptime-free helper `standardizedMoment` (`feat.zig:509`).
- `SpectralCrest` (`feat.zig:541`) → `Scalar(f32)` — max/mean power (peakiness).
- `Hfc` (`feat.zig:575`) → `Scalar(f32)` — Masri high-frequency content `Σ k·power[k]`.
- `Chroma` (`feat.zig:607`) → `FeatureFrame(12)` — 12-bin pitch-class profile, comptime bin→class map
  (baked sr=48000, fft_size=2·(bins−1), 440 Hz ref, 20 Hz floor), max-normalized.
- `SpectralContrast` (`feat.zig:676`) → `FeatureFrame(n_bands)` — per-octave-band `ln(peak)−ln(valley)`,
  comptime geometric band edges `e[b]=round((bins−1)^(b/n_bands))`.
- `DominantBandHysteresis` (`feat.zig:760`) → `Scalar(u16)` — **the principled, flicker-free viz COLOR
  channel.** Stateful: leaky-integrated spectrum (λ=0.7) + a (1+margin=1.5) switch threshold; held band
  only changes when a challenger decisively wins. Replaces the jittery stateless `DominantBand` for viz.

Time-domain Maps (`[]const spectral.TimeFrame(T,FRAME)` from `Framer`, float lane; one value per hop, so
rate-aligned with the spectral branch):
- `Zcr` (`feat.zig:809`) → `Scalar(f32)` — zero-crossing rate over the frame (frame-local).
- `TeoMean` (`feat.zig:847`) → `Scalar(f32)` — mean Teager-Kaiser energy `s[n]²−s[n−1]·s[n+1]` (interior).
- `BallisticEnvelope` (`feat.zig:892`) → `Scalar(f32)` — **the principled viz AMPLITUDE channel.** Stateful:
  per-frame peak |s| through an inter-frame attack/release one-pole (attack=0.6, release=0.05), clamped
  [0,1]. One float of state, no overlap hazard (operates on the per-frame peak, smooths across frames).

**The open P9 boundary §4.1 is CLOSED.** `tests/negative/concat_type_mismatch.zig` wires a `Scalar(f32)`
producer into a `Concat` column typed `FeatureFrame(13)`; `build.zig` (the `neg_concat` step, after the
P8 `neg` step) asserts a non-zero `zig build-obj` exit. The connect element-type `@compileError`
(`src/graph.zig:340`) now has an ACTIVE must-fail fixture, alongside the P8 missing-Rate one. `neg-compile`
runs both. (P9 boundary §4.2 — a literal `PullRoot` struct — was decided cosmetic and left as-is.)

**Worked analysis graph** (`tests/analysis_buildout_test.zig`, 3 tests):
1. `LpcmSource → Stft → PowerSpectrum → {DominantBandHysteresis, Rms, SpectralRolloff, SpectralFlatness,
   SpectralEntropy, SpectralContrast} → Concat → FeatureCollectorSink`, run off-RT via input-exhaustion;
   asserts the column-major `f32` matrix carries the `notes/1.md` schema (dominant→COLOR col 0,
   rms→AMPLITUDE col 1) and per-row viz invariants (band < bins, flatness/entropy ∈ [0,1]).
2. The flicker-free COLOR channel holds steady on a stationary tone (the hysteresis upgrade, proven).
3. The AMPLITUDE channel: `Framer → BallisticEnvelope` tracks a swell monotonically up, stays in [0,1].

**Yoneda dispatch (Rule 14):** three autonomous `yoneda-test-writer`s (each loaded `zig-0-16`, verified by
compiling), given the blocks + documented formulas + instructed to write independent hermetic oracles
(never the tests). **94 tests, all green, ZERO bugs** — the new blocks agree with their documented formulas
(unlike P9's Concat, which the dispatch caught; here it confirmed correctness):
- `tests/feat_spectral_shape_yoneda_test.zig` (42) — the 8 moment/shape descriptors.
- `tests/feat_chroma_contrast_yoneda_test.zig` (23) — chroma fold/octave-collapse/normalize; contrast
  band edges + ε floor + empty-band; `DominantBandHysteresis` switch/hold frontier + S6 state-split.
- `tests/feat_timedomain_yoneda_test.zig` (29) — ZCR/TEO patterns; ballistic recursion + S6 + field overrides.
All four new harnesses registered in `build.zig` (the `harnesses` list, after `analysis_yoneda_test.zig`).

## 2. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build smoke ; zig build cross-linux ; zig build fmt-check
zig build neg-compile                   # NOW two must-fail fixtures (missing-Rate + Concat-type-mismatch)
zig build bench -Dbench-gate
```
All exit 0. Carried cosmetic noise (unchanged, pre-existing): `aliasing_message_test`/`comparator_test`
drive reject paths with `std.debug.print` ("divergence", "allclose fail"); the suite still exits 0. The
two `neg-compile` fixtures print their `@compileError` + "failed command" — that is the gate WORKING
(they must fail to compile); the step exits 0.

Single harness standalone (fastest iteration):
```sh
zig test --dep pan -Mroot=tests/feat_spectral_shape_yoneda_test.zig -Mpan=src/root.zig \
  -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -lc
```

## 3. Design decisions / deviations (surfaced, Rule 12)
- **Rate model.** A `Map` is strictly rate-1:1 over its input ELEMENT. The spectral branch is already
  hop-rate (`Stft` frames internally), so spectrum-consuming Maps are hop-rate and Concat-ready. Time-domain
  features get hop-rate by consuming `TimeFrame(T,FRAME)` from `Framer` (also 1:HOP). Frame-local stats
  (ZCR, TEO) are clean per-frame statistics — the `Framer`'s frame overlap is the standard STFT-style
  overlap and is correct for them. `BallisticEnvelope` sidesteps the overlap hazard of a true per-sample
  follower by smoothing the per-FRAME peak across frames (one-float state) — the principled meter-style
  envelope at frame rate.
- **`num.Lane` baking.** Like `Mfcc`, `Chroma` bakes `sample_rate = 48000` / `fft_size = 2·(bins−1)` at
  comptime (`analysis_sample_rate`, `feat.zig:32`) — a block can't read the runtime `Config` rate; a
  different-rate graph re-instantiates against a matching constant. Surfaced, not hidden.
- **Worked-graph branch separation.** The worked matrix graph (test 1) is spectrum-only — matching the
  mission's stated shape `file → Stft → PowerSpectrum → {extractors} → Concat`. The time-domain AMPLITUDE
  channel is demonstrated on its own `Framer` branch (test 3), NOT fused into the same Concat row. Fusing
  the time + spectral branches into ONE matrix requires fanning the source to BOTH `Stft` and `Framer`
  (two 1:HOP Rate blocks, equal latency) — a same-source multi-Rate fan-out that is rate-seam territory
  (P8). It is plausibly already supported (equal `out_per_in`/latency), but I did NOT verify it under
  commit/PDC, so I left it as the obvious next integration step rather than claim it untested. See §4.

## 4. What's deferred / next (honest backlog, with rationale)
- **Combined time+spectral matrix.** Fan one `LpcmSource` to `Stft` AND `Framer`, Concat the spectral +
  time columns into one row. Cheap if the multi-Rate fan-out commits cleanly; verify PDC aligns the two
  1:HOP branches. This is the one integration not yet exercised end-to-end.
- **BS.1770 / EBU R128 gated loudness — DEFERRED with rationale.** This is the one Tier-B item I did NOT
  ship. Faithful LUFS needs per-SAMPLE K-weighting biquads (stateful) + a 400 ms gated sliding mean-square
  — i.e. sample-rate processing with cross-frame biquad state, which a per-frame `TimeFrame` Map would
  double-apply over the `Framer` overlap. The correct home is a **`Rate` decimator** (`out_per_in=1:HOP`,
  `pull` consuming HOP samples, emitting one LUFS value), not a `Map`. I chose NOT to ship a per-frame
  mean-square stub mislabeled "loudness" (it would duplicate `Rms` and mislead). Build it as a Rate block.
- **Tier C/D (research backlog, `handoff_for_P9_feature_buildout.md` §3).** LPC/PARCOR/formants/LPCC
  (consume `TimeFrame`, Levinson-Durbin → `FeatureFrame(order)` or `Bounded(f32,Fmax)`); pitch (YIN/
  autocorrelation → `Scalar(f32)`); PNCC (cross-frame medium-time norm); modulation spectrum; onset/beat
  (hypothesis tracking, likely a new `src/detect.zig`); VAD (adaptive-threshold FSM). All graph-shape-
  identical to the landed blocks; the plug-in recipe in that handoff §2 still applies verbatim.
- **GFCC** (gammatone/ERB cepstra) — a `Mfcc` variant swapping the mel bank for an ERB/gammatone bank;
  trivial extension of the `Mfcc` comptime-table pattern. Skewness/kurtosis higher orders, spectral
  flux variants — incremental.
- **Skew/kurtosis are RAW (not excess); contrast peak/valley are max/min** (not α-quantile means as in the
  fuller Jiang OBSC). Both are documented as such in their doc-comments; a quantile-mean contrast is a
  refinement if a downstream consumer needs the smoother variant.

## 5. Conventions honored (Rule 11)
Self-contained code docs (no `spec §`/`research/…` refs in `src/`); ≈ tolerance oracles for numerics
(hermetic, scipy-free); the four-mode matrix + fmt + neg-compile + bench-gate all green; comptime tables
(`Chroma` bin→class, `SpectralContrast` band edges) baked into `.rodata` like `Mfcc`; per-hop S6 state
granularity for the stateful blocks (`DominantBandHysteresis`, `BallisticEnvelope`) — Yoneda-verified via
sub-block-split equivalence. No `src/feat.zig` block reaches outside the blessed element set.
