# Handoff — Complete P9 + full feature-extraction buildout

> **Mission of the next session:** finish P9 to its *complete* surface AND build out the broader
> **feature-extraction catalog** from `research/` — every analysis primitive that plugs into the
> existing pan infrastructure with little/no new machinery (these are NOT in `pan_implementation_plan.md`
> but are explicitly in scope for this work).
> **Status going in:** P0–P8 done; **P9 gate + all enumerated work items DONE and green**; this session
> extends, it does not repair. Advisory handoff, not a spec — `specifications/` + the plan remain the
> source of truth.
> **Date:** 2026-06-04. **Toolchain:** `zig 0.16.0` exactly (re-run `zig version` first — Rule 13).
> **Rule 13 is load-bearing:** load the `zig-0-16` skill before writing/reviewing ANY Zig; tell every
> dispatched subagent to load it too. **Rule 14:** dispatch autonomous `yoneda-test-writer`s at each
> feature gate (give them the code + oracle, never the tests).

---

## 0. Fast orientation — read these first (in order), with anchors

| What | Where | Why |
|---|---|---|
| Project north star | `notes/brief.md:4-12` (core reqs), `:30` (examples/ viz goal) | maximize throughput / min latency / min memory; analysis drives `notes/1.md` |
| The viz data schema | `notes/1.md:8-24` (COLOR=dominant band, AMPLITUDE 0–1=rms, LIFETIME, EMISSION TIME) | what the feature matrix must carry |
| **Phase 9 plan** | `pan_implementation_plan.md:726-768` (Goal/Work 1-4/gate/Yoneda/Bench) | the enumerated P9 surface |
| Plan testing conventions | `:36-48` (§0.2 self-contained code docs — NO spec refs in code), `:80-87` (§0.5 comparison modes), `:88-102` (§0.6 four-mode CI matrix), `:64-79` (§0.4 Yoneda dispatch) | the obligations every block inherits |
| Exec model for roots | `specifications/pan_execution_model.md` §6 (clock-driven pull roots; SPSC taps; A8) | the analysis-root contract |
| Feature ports & Concat | `specifications/pan_type_and_numeric_model.md` §1, §3.1 (comptime-K) | typed feature edges; named limit |
| Element types & laws | `specifications/catalog.md` §1.3 (FeatureFrame/Scalar/Bounded), §4.3 (Concat), §4.4 (ChannelMap functor), §8.3/§8.13 (pull roots/Analyzer), A8 + C5 | the blessed element set + the named laws |
| Growable-sink rule | `specifications/pan_categorical_bridge_and_roadmap.md` §2 (capacity_hint + ×2; contained-H1) | FeatureCollectorSink growth + chain taxonomy |
| Illustrative DX target | `specifications/pan_developer_experience.md:533-627` (the analysis worked example) | the surface, marked "Illustrative/PLAUSIBLE" |
| **Independent coverage audit** | `notes/p9_coverage_audit.md` | a skeptical, line-referenced verdict on exactly what P9 already covers |
| Research index | `research/INDEX.md` (themed quick-links), `research/gaps-feature-extraction-algorithms-2026.md` | the feature-extraction catalog map |

**Verify green at any point (from repo root):**
```sh
zig build test                          # Debug (EXIT 0; aliasing_message_test/comparator_test print
zig build test -Doptimize=ReleaseSafe   #   expected reject-path diagnostics but the suite exits 0)
zig build test -Doptimize=ReleaseFast
zig build smoke ; zig build cross-linux ; zig build fmt-check ; zig build neg-compile
zig build bench -Dbench-gate            # footprint baseline held
```
Run a single harness standalone (fastest iteration):
```sh
zig test --dep pan -Mroot=tests/<name>_test.zig -Mpan=src/root.zig \
  -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -lc
```

---

## 1. What P9 already provides (do NOT rebuild — build ON)

The analysis infrastructure is complete and the plug-in points are stable. Anchors:

- **Element types** (`src/types.zig`): `FeatureFrame(K)` `:205` (the `{v:[K]f32}` feature vector, also the
  power-spectrum carrier), `Scalar(T)` `:220` (`{value:T}`), `Bounded(T,Kmax)` `:237` (`{items:[Kmax]T,
  len:u16}` — the ragged list for peak/formant/beat hypotheses), `Complex(T)` `:189`, `Sample(T)` `:107`,
  `Frame(Lane,L)` `:85`. Non-primitive elements expose `typeName()`; a bare array is rejected at comptime.
- **Spectral front-end** (`src/spectral.zig`): `Framer(num,FRAME,HOP)` `:258` (Rate → `TimeFrame`),
  `Stft(num,FRAME,HOP)` `:328` (Rate → `Spectrum(T,FRAME/2+1)` complex, frames internally — no separate
  Framer needed), `PowerSpectrum(num,bins)` `:449` (Map `[]Spectrum → []FeatureFrame(bins)`, `v[k]=|bin k|²`).
- **The five feature blocks** (`src/feat.zig`): `Rms` `:37`, `DominantBand` `:65`, `SpectralCentroid` `:99`,
  `SpectralFlux` `:137` (stateful `prev`), `Mfcc` `:192` (comptime mel bank + DCT-II; bakes sr=48000/
  n_mels=26 at `:170-171`). **Each doc-comment states its exact formula — that IS the oracle spec.**
- **Named fan-in** (`src/combinators.zig`): `Concat(spec)` `:45` (arity 1-8 explicit `process` variants,
  8-port ceiling; output `port.ConcatOut(spec)` field order = column order), `ChannelMap(Sub,C)` `:240`
  (single-mono-Map functor). Concat columns are NAME-keyed (the emit pass places inputs by `to_port` —
  `src/commit.zig:1009` forward / `:1032` feedback-read — this was a bug Yoneda caught; see §4).
- **Collector + matrix** (`src/io.zig`): `FeatureCollectorSink(Row)` `:510` (growable, non-RT-only:
  `growable_sink` marker, `initialize`/`deinit` lifecycle, `frames()`, `overflowed`),
  `encodeFeatureMatrix(alloc,matrix)` / `featureMatrixColumns(Row)` / `writeFeatureMatrix(path,matrix)`
  (row-major f32, column order = Row field order, int scalars widen).
- **Cross-root tap** (`src/control.zig` `SpscRing(Elem,cap)`; `src/io.zig` `Tap` `:562` / `TapSource` `:579`):
  publish a shared upstream once on one root, consume on another via a wait-free SPSC ring.
- **Drive + roots** (`src/engine.zig`): `ClockSource` `:955` (audio_device_callback / wall_clock_timer /
  input_exhaustion), `RunOptions`, `runToCompletion(opts)` `:1475` (off-RT block loop until exhaustion;
  `error.NoExhaustibleSource`), `BoundNode.exhausted` + `exhaustThunkFor`, the A8 reject in `bind`
  (`:1032`, `error.GrowableSinkOnRealtimeRoot` keyed off `graph.zig:267`).
- **Builder DX** (`src/builder.zig`): `g.add(Block, params)` (calls `inst.initialize(alloc)` if declared,
  binds exhaust thunk), `g.connect(a, b)` / `g.connect(a, node.in.<name>)`, `commit()` (realtime) /
  `commitAnalysis()` (non-RT; the only commit accepting a growable sink), `NodeHandle.instance()` (read a
  sink's `frames()`), Rate-aware `in(i)`.
- **Tests / harnesses** (registered `build.zig:102-104`): `tests/analysis_root_test.zig` (7 gate tests incl.
  cross-root tap + full Stft chain), `tests/feat_yoneda_test.zig` (24, hermetic in-test oracles),
  `tests/analysis_yoneda_test.zig` (21). `src/root.zig:193` `feat`, `:201` `combinators`, `:208`
  `FeatureCollectorSink`, `:106` `SpscRing`.

---

## 2. THE PLUG-IN ARCHITECTURE — how a new feature extractor is added (the load-bearing how-to)

A feature extractor is just a **block** the analysis graph fans the right edge into and `Concat` collects.
The infra above already routes any number of them. To add one:

1. **Pick the input element** (this decides where it connects):
   - **Power spectrum** `[]const FeatureFrame(bins)` (from `PowerSpectrum`, `bins = FRAME/2+1`) — for
     rolloff/flatness/entropy/centroid/contrast/chroma/HFC/GFCC/PNCC/dominant. **Easiest** — identical
     shape to the 5 existing blocks (`feat.zig:37-167`).
   - **Complex spectrum** `[]const Spectrum(T,bins)` (from `Stft`, BEFORE PowerSpectrum) — for phase /
     complex-domain onset / instantaneous-frequency / group-delay features.
   - **Time samples** `[]const Sample(T)` (tap the source directly, parallel to the Stft branch) — for
     ZCR / TEO-TKEO / time-RMS / envelope followers / ballistic AGC / crest. **Easy** (one input port).
   - **Time frame** `[]const TimeFrame(T,FRAME)` (from `Framer`, `spectral.zig:258`) — for LPC / PARCOR /
     formants / autocorrelation-pitch (need the windowed frame for the autocorrelation).
2. **Pick the output element**: `Scalar(f32)` (scalar feature), `Scalar(u16)` (a band index),
   `FeatureFrame(K)` (a fixed-K vector: chroma=12, contrast=n_bands, GFCC/PNCC=n_coeffs), or
   `Bounded(T,Kmax)` (a ragged list: sparse peaks, formant tracks, beat hypotheses — `types.zig:237`).
3. **Write the block** as a rate-1:1 `Map`: `pub fn process(self:*Self, in:[]const InElem, out:[]OutElem)
   void`. Stateful features (flux/envelope/hysteresis/PNCC medium-time/onset peak-pick) carry per-instance
   fields with defaults (`prev: [bins]f32 = @splat(0)` — see `SpectralFlux` `feat.zig:137`); state advances
   once per processed frame (the S6 per-hop granularity — a sub-block split must leave state identical).
   **Comptime tables** (mel/DCT/chroma maps/gammatone coeffs) build once at comptime like `Mfcc`'s
   `filt`/`dct` (`feat.zig:202-247`) — bake into `.rodata`, zero runtime cost (skill ch.04).
4. **Doc-comment the EXACT formula in plain prose** (§0.2 — code must be self-contained, NO `spec §x`/
   `research/…` refs in the source; restate the law inline). That doc-comment is the oracle spec.
5. **Default-construct rule:** every field must have a default so `add` can build `Block{}` then override
   (`builder.zig:256`). Source-like blocks needing exhaustion declare `pub fn exhausted(self)bool`.
6. **Wire it** in a graph: `g.connect(power, myfeat); g.connect(myfeat, collect.in.<name>)`. Add its column
   to the `Concat(.{…})` spec — the field name IS the matrix column, in declaration order.
7. **Yoneda-dispatch its test** (Rule 14): a `yoneda-test-writer` (loads `zig-0-16`), given the block +
   the documented formula, writes a hermetic in-test oracle (an independent recomputation — NOT pan's own
   code; tolerance via `expectApproxEqAbs`, never bit-exact for numerics — §0.5). Model on
   `tests/feat_yoneda_test.zig` (its oracles sum in a different order than the block, on purpose). Register
   the new test file in `build.zig:102` harnesses list.

Heterogeneous fan-in works because `Concat` columns are name-keyed and the executor places inputs by port
index — a 5-name row of `FeatureFrame(13)+Scalar(f32)×3+Scalar(u16)` collects correctly (see
`tests/analysis_root_test.zig` `addFeatureChain`). The whole graph commits via `commitAnalysis()` and runs
via `runToCompletion(.{ .clock = .input_exhaustion })`.

---

## 3. THE FEATURE-EXTRACTION BACKLOG (from research/, prioritized by plug-in ease)

Every item below has a deep/scaffold research note (the algorithm + traffic + fixed-point + citations).
Verdicts: **EASY** = Map over an existing element, no new infra; **MOD** = needs a small new input branch or
nontrivial state; **HARD** = needs new structure (hypothesis tracking / nested transform). Suggested home:
extend `src/feat.zig` (spectrum/time Maps) or a new `src/detect.zig` (onset/VAD/pitch). All ≈-tested vs an
independent oracle (librosa/numpy or in-test reimplementation).

### Tier A — spectrum-consuming Maps (EASY; identical shape to the 5 done blocks)
- **Spectral rolloff, flatness, entropy, spread, skewness, kurtosis, HFC** → `Scalar(f32)`.
  `research/features/perceptual-sparse-and-ultra-low-compute-features.md`. One pass over `FeatureFrame(bins)`.
- **Chroma / PCP** → `FeatureFrame(12)`. Fold bins to 12 pitch classes (comptime bin→class map from
  sr/fft_size). Same note + CQT cross-ref.
- **Spectral contrast (octave-band peak/valley)** → `FeatureFrame(n_bands)`.
  `research/features/spectral-contrast-octave-based-and-timbre-shape-features.md` (Jiang 2002 OBSC).
- **Dominant-band tracking w/ hysteresis + leaky integration** → `Scalar(u16)` (flicker-free viz color).
  `research/features/real-time-dominant-frequency-band-tracking-and-mapping.md`. Stateful extension of
  `DominantBand` (`feat.zig:65`). **Directly improves the `notes/1.md` color channel.**
- **GFCC / gammatone-ERB cepstra** → `FeatureFrame(n_coeffs)`. A `Mfcc` variant with an ERB/gammatone bank
  instead of mel. `research/features/gammatone-erb-filterbanks-gfcc-and-auditory-cepstral-features.md`.
- **HPS / HSS (harmonic product/sum)** → `Scalar(f32)` (pitch salience). `detection/real-time-pitch-estimation.md`.

### Tier B — time-domain Maps (EASY-MOD; new input = tap `Sample(T)` parallel to the Stft branch)
- **ZCR with Schmitt hysteresis** → `Scalar(f32)`. `features/perceptual-sparse…` + `detection/vad…`.
- **Teager-Kaiser energy (TEO/TKEO) + DESA** (AM/FM/onset) → `Scalar(f32)`. 3-sample kernel, tiny state.
- **Envelope followers (peak/RMS), dual-time-constant ballistic (attack/release), crest factor, AGC →
   [0,1] amplitude scaling** → `Scalar(f32)`.
  `research/algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md`.
  **This is the principled `rms`→amplitude[0,1] channel for the viz** (currently `Rms` is spectral-energy).
- **Perceptual loudness — ITU-R BS.1770 / EBU R128 gated LUFS** → `Scalar(f32)`. K-weighting biquads +
  gated mean-square. `research/features/perceptual-loudness-itu-bs1770-ebu-r128-streaming-measurement.md`.
  A single stateful Map holding the K-weighting state + the gating window. (MOD.)

### Tier C — framed / parametric (MOD; consume `TimeFrame` from `Framer`, or carry cross-frame state)
- **LPC / PARCOR (reflection coeffs) / formants / LPCC** → `FeatureFrame(order)` or `Bounded(f32,Fmax)`
  (formants). Autocorrelation over a `TimeFrame` → Levinson-Durbin or lattice.
  `research/features/linear-predictive-coding-lpc-reflection-coefficients-formants-and-lpcc.md`.
- **Pitch (YIN / pYIN / autocorrelation)** → `Scalar(f32)` Hz. `detection/real-time-pitch-estimation.md`.
- **PNCC robust front-end** (power-law + medium-time norm + asymmetric masking) → `FeatureFrame(K)`.
  `research/features/power-normalized-cepstral-coefficients-pncc-and-robust-front-ends.md`. Cross-frame state.
- **Modulation spectrum / subband envelopes (rhythmic texture)** → `FeatureFrame(K)`. Envelope followers +
  low-rate FFT. `research/features/modulation-spectrum-subband-envelopes-and-rhythmic-texture-features.md`.

### Tier D — detection / hypothesis-tracking (HARD; new state structures, likely `src/detect.zig`)
- **Onset / beat / transient** → onset: `Scalar(f32)` (flux/HFC/complex-domain), beat: `Bounded` tempo
  hypotheses + peak-picking FSM. `research/detection/onset-beat-and-transient.md`. Complex-domain onset
  consumes `Spectrum(T,bins)` (phase).
- **VAD** → `Scalar(f32)`/bool gate, adaptive-threshold FSM + hangover.
  `research/detection/vad-voice-activity-detection.md`. Tiny state (<100 B); gates downstream traffic.

### Cross-cutting (research/optimization — apply, don't add as blocks)
- SIMD/branchless/fast-approx (`research/optimization/simd-…`, `…branchless-bit-twiddling…`,
  `…fast-approximations-lut-cordic…`) and cache-blocking/fused single-pass
  (`…cache-blocking-fused-streaming-kernels…`) are *implementation techniques* for the hot kernels (skill
  ch.04). The brief's throughput/memory axes reward fusing several reductions while the spectrum is hot.
- `research/data_structures/audio-rings-fractional-delays-and-sparse-representations.md` — `Bounded(T,Kmax)`
  IS the fixed-K sparse peak list; use it for dominant-multi-peak / formant / beat-hypothesis outputs.

**Suggested first wave (highest ROI, all EASY, directly improve the viz + KWS/music use cases):** spectral
rolloff/flatness/entropy/spread, chroma(12), spectral-contrast, dominant-band-with-hysteresis, ZCR,
TEO, ballistic envelope→[0,1] amplitude, BS.1770 loudness. Each is ~30-80 LOC + a Yoneda oracle test.

---

## 4. Open P9 boundaries to close

1. **Concat wrong-element-type rejection has no must-fail fixture.** The guarantee is ⊢-by-construction
   (the `port.NamedInPort` type-check, `src/port.zig:367-372`, and `graph.zig:333` connect mismatch
   `@compileError`), but unlike the missing-latency case (`tests/negative/missing_latency.zig` +
   `build.zig:131` `neg-compile` step) there is no ACTIVE negative-compile fixture. **Add**
   `tests/negative/concat_type_mismatch.zig` (wire a `Scalar(f32)` producer into a `Concat` column typed
   `FeatureFrame(13)`) and a second `neg-compile` dep asserting non-zero exit. Cheap; closes the ⊢ claim.
2. **No literal `PullRoot{…}` struct.** Exec §6 writes `PullRoot := {clock_source, sink_set,
   owned_subplan}`; pan realizes it behaviorally as `commitAnalysis` + `runToCompletion` on the existing
   `Engine`, not a named type. If the next session wants the named type for readability, introduce
   `engine.PullRoot` as a thin wrapper; purely cosmetic, no behavior change.

---

## 5. Conventions every new block/test MUST honor (Rule 11 — conform, don't fork)
- **Code docs self-contained** (§0.2, plan `:36-48`): restate the formula/law in prose; **no** `spec §`,
  `catalog §`, `research/…`, or filename refs in `src/`. The spec/research citations live HERE and in
  test names, not in the kernels.
- **Comparison modes** (§0.5, plan `:80-87`): feature numerics vs an external/independent oracle =
  tolerance (`expectApproxEqAbs/Rel`); any pan-vs-pan structural check = bit-exact. Hermetic — `zig build
  test` stays scipy-free (in-test oracle; optional on-demand scipy cross-check under `scripts/` like P8's
  `scripts/xcheck_rfft.*`).
- **Four-mode matrix** (§0.6, plan `:88-102`): every harness green in Debug + ReleaseSafe + ReleaseFast +
  (freestanding ReleaseSmall smoke). Run `fmt-check` + `neg-compile` + `bench-gate` too.
- **Correctness tiers** (§0.3): mark claims ⊢ proven-by-construction / ≈ tested / ▷ conventional. "The
  test is the proof" is banned — features are ≈ (tested), the type-checks are ⊢.
- **Yoneda at each gate** (Rule 14): autonomous test-writers, given code+oracle, not tests. They caught a
  REAL bug in P9 (named Concat was connect-order-keyed not name-keyed; fixed at `commit.zig:1009/1032`) —
  this dispatch is not ceremony, it finds defects. Keep it.
- **Mfcc-style comptime tables** for any filterbank/DCT/chroma-map; **planar** for any C>1 element
  (`catalog.md` §9.3 P-1/P-2 — multi-channel is plane-major, enforced).

## 6. What "complete" means for this session (definition of done)
- The open P9 boundary §4.1 (Concat neg-compile fixture) closed; §4.2 done per decision (cosmetic).
- The Tier-A first-wave feature blocks (§3) implemented in `src/feat.zig`, each with a Yoneda oracle test,
  each registered in `build.zig`, four-mode green; the `notes/1.md` color (dominant-w/-hysteresis) and
  amplitude (ballistic [0,1]) channels upgraded to their principled forms.
- As many Tier-B/C/D items as scope allows, each landed with its oracle test and surfaced honestly in a
  follow-up handoff (Rule 12 — name what's done, partial, with `file:line`).
- A worked analysis graph (file → `Stft` → `PowerSpectrum` → {N extractors} → `Concat` → collector →
  `writeFeatureMatrix`) producing the column-major `f32` matrix that carries the `notes/1.md` schema
  (dominant→color, rms/loudness→amplitude, row→emission time) — proving the extractor set end to end.
- Updated `notes/p9_coverage_audit.md` (or a successor) + a memory note, with every item's verdict and anchor.
