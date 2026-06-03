# Handoff — end of Session 7 (P8 "rate-elastic seam + per-rate-domain PDC") → into P9

> **Status:** P0–P7 + **P8 implemented, full-surface, and green.** Advisory handoff, not a spec:
> `specifications/` + `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-03. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P9 start — Rule 13).
> P8 = roadmap step 5: the dual contract proven at the rate-elastic seam.

---

## 1. Ownership statement (honest, Rule 12)

Every P8 work item (`pan_implementation_plan.md` §8, items 1–3) is implemented and **green across the
four-mode matrix** plus smoke / cross-linux / fmt-check / bench-gate (all exit 0). The dry/wet FFT
diamond re-aligns sample-accurately; the `Rate` block passes both muxes (dual-mux) and the
latency-contract; a `Rate` missing a declaration is a build error; `error.UndeclaredCycle` vs
`error.DelayFreeLoop` (and the new `error.MixedRateInputs`) are distinguished.

**Two documented deviations from spec worked-example-A** (surfaced, not silent — see
`memory/p8-deviations.md`): (1) the spec's **14352 B footprint figure is internally inconsistent**
(257 bins ⟺ FRAME=512 but comp-delay 1024 ⟺ FRAME=1024 — can't both hold), so a self-consistent real
STFT is used and the actual numbers asserted; (2) the COLA round-trip latency is **`FRAME−HOP`** (the
analysis framing's), not `FRAME`. The plan's §8 gate is behavioral and names neither, so this is in-bounds.

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents (each loaded `zig-0-16`,
verified by compiling). The spectral-blocks writer **caught a real bug** — `Framer`/`Stft` dropped the
sub-`HOP` remainder of a chunk (T4 / catalog §9.3 violation) — and correctly left its test red rather
than weaken it; FIXED with a circular history ring + carried `phase` (frame-identical for HOP-aligned
input). No bugs found in the commit-pass / PDC code.

---

## 2. What was built (the deltas)

```
src/spectral.zig (NEW)  Radix-2 in-place FFT; Spectrum(T,bins)/TimeFrame(T,FRAME) elements;
                        Framer / Stft / iStft (Hann 50%-overlap COLA; iStft∘Stft = input delayed by
                        FRAME−HOP); PowerSpectrum (rate-1:1 type-changing Map); windowed-sinc rational
                        Resampler(L,M,HALF). Float-only. pull(self, in, want, out) -> produced (a
                        zero-input Rate source omits `in`). Framer/Stft carry the sub-HOP remainder
                        across calls (ring + phase); the Resampler is single-pull (no cross-call ring).
src/port.zig    (M)     RateOutElem scans pull for the first mutable port (both source & transducer
                        shapes); + RateInElem/RateInPort/RateOutPort/rateInputCount/isPortParam(pub).
                        isSource is now STRUCTURAL for Rate: a zero-input Rate IS a source (SR2).
src/engine.zig  (M)     Rate `pull` dispatch in runOp + renderThunk. Input-port slice len = its
                        buffer's element count (producer's want); output len = n; the want:usize param
                        gets n. Backward-compatible for rate-1:1 Maps.
src/commit.zig  (M)     want-keyed pools: class key (elem_name, want), stride want·elem_size (==N·size
                        for rate-1:1). want[] moved before coloring. insertPdc (computeApa rational
                        rate-domain scale + topoSort; longest-path DP; comp-delay DelayLine nodes tagged
                        is_pdc; bypass→comp-delay + pdc_compensated). commitRuntime = computePlan(
                        insertPdc(insertCoercions(g))). + error.MixedRateInputs (multi-input pull rule).
src/graph.zig   (M)     Node += is_pdc, pdc_compensated.
src/root.zig    (M)     pub const spectral + Spectrum/TimeFrame/Framer/Stft/iStft/PowerSpectrum/
                        Resampler/insertPdc.
build.zig       (M)     + spectral_test, pdc_test, spectral_yoneda_test, pdc_yoneda_test, spectral_bench.
tests/spectral_test.zig, tests/pdc_test.zig (gate), tests/{spectral,pdc}_yoneda_test.zig (autonomous).
bench/spectral_bench.zig (STFT/iSTFT/Resampler throughput + the dry/wet diamond ±PDC footprint).
```

The example_a_coloring_test (rate-1:1 stubs, footprint 18440) is UNCHANGED and still green — want-keying
is byte-identical for rate-1:1 graphs.

## 3. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build smoke                         # freestanding ReleaseSmall comptime-commit
zig build cross-linux                   # x86_64-linux-gnu ALSA seam
zig build fmt-check
zig build bench -Dbench-gate            # footprint baseline 8192 B held
```
Carried cosmetic noise (P2, unchanged): aliasing_message_test / comparator_test drive reject paths with
`std.debug.print`; the 0.16 runner echoes "failed command" but the suite exits 0.

## 3b. Surface-closure pass (after an honest self-audit + an independent audit)
Both audits (one self, one independent general-purpose agent) agreed P8's gate is met and green; the
follow-up pass closed the flagged gaps except one documented sliver:
- **rfft ADOPTED.** `Stft`/`iStft` now use a real-input FFT (`rfftForward`/`rfftInverse`, src/spectral.zig
  — half-length complex FFT + untangle, pure scalar/no HAL). Validated vs a naive DFT AND cross-validated
  vs `scipy.fft.rfft` (`scripts/xcheck_rfft.{zig,py}`, on-demand venv; max_abs_err 1.5e-3). **Bench:
  1.74× faster + half the working memory** vs full-complex on 1024-pt real input. `fftInPlace` kept as the
  complex primitive rfft builds on.
- **Independent oracle ADDED** (`tests/spectral_gold_test.zig`, hermetic/always-on): Stft vs naive O(N²)
  DFT; Resampler vs analytic sinusoid. SciPy is on-demand generation/cross-validation tooling only
  (`scripts/generate.py` += resampler ref) → `zig build test` stays scipy-free (hermeticism preserved).
- **Framer/STFT impulse latency-contract ADDED** (spectral_test): impulse → `measuredGroupDelay == FRAME−HOP`.
- **Runtime-Engine PDC WIRED.** `engine.buildBoundPlan` now runs `insertPdc(insertCoercions(ir))` and binds
  a byte-generic delay kernel (`pdcDelayThunk`/`PdcDelayState`) for `is_pdc` nodes, with per-plan inserted
  state owned by the Engine (`inserted: []InsertedSlot`) freed at deinit + RCU grace. Tested through
  `Engine.bind` (impulse delayed by L, no leaks). No-op for non-PDC graphs ⇒ inert for all existing
  Engine/RCU/TSan tests (re-verified green).

## 3c. Full-closure pass (the SRC resampler coercion body + the negative-compile gate)
- **The mid-graph SRC resampler coercion is now REAL + drift-free** (was the last MISSING item). New:
  `io.RuntimeResampler` (streaming windowed-sinc polyphase, runtime ratio, per-channel history ring +
  phase; `needed_input(want) = (acc+want·q)/p` is PHASE-STATEFUL → the exact per-callback count, so a
  non-integer ratio like 160:147 does NOT drift; a static count provably would). `insertCoercions` sets
  the coercion's real `out_per_in = reduce(consumer,producer)` + group-delay latency; `computeApa`
  re-bases a source's apa to the pipeline clock (so apa = 1 downstream of a resampler — clean merge, PDC
  converts across the clock bridge; backward-compatible for same-rate). `engine.buildBoundPlan` binds the
  resampler (InsertedSlot); `engine.replayBound` computes a DYNAMIC per-callback count from the RCU plan
  (`RenderOp.is_resampler`/`resampler_producer_op`) — race-free, inert for resampler-free graphs. Tested:
  a 44.1k→48k coercion resamples a 1 kHz sine correctly through the runtime Engine (`pdc_test`).
- **Negative-compile gate ADDED:** `zig build neg-compile` (a `test` dep) compiles
  `tests/negative/missing_latency.zig` and asserts a non-zero exit — the "missing Rate declaration is a
  build error" criterion is now an ACTIVE check, not just a disabled stub. Gates now: test (×3 modes) /
  smoke / cross-linux / fmt-check / **neg-compile** / bench-gate, all green; TSan-clean RCU.

## 4. Honest gaps carried into P9+ (Rule 12)
- **Adaptive/drift ASRC** (runtime-VARYING resample ratio, `ratio_source = .internal_controller`) →
  **Phase 12** (`VariRate`), correctly NOT P8 — the FIXED-ratio resampler coercion above is the P8 piece.
- **FFT SIMD/`@Vector` + the vDSP/FFTW/CMSIS accel slot** → spec-DEFERRED (`pan_io_realtime_and_pipeline`
  §11). The rfft win (≈1.74× + ½ memory) is taken; further speed is the accel slot. ~200× RT headroom.
- **Fixed-point spectral path** → embedded-precision phase (float-only compile error today).
- **Persistent-state carry across an RCU swap**, **live device gate** → unchanged from prior handoffs.

## 5. What P9 needs (from plan Phase 9)
P9 = roadmap step 6: the **Analysis pull root** — a non-RT analysis `PullRoot` driving
file→features→collector (the `notes/1.md` viz), typed feature ports, named `Concat`,
`FeatureCollectorSink` (growable, non-RT-root-only), and feature chains. Read first: plan §9;
`pan_execution_model.md` §6 (clock-driven pull roots C5, the two canonical graph shapes);
`pan_categorical_bridge_and_roadmap.md` §2 (FeatureCollectorSink, the contained-H1 growable-sink rule).
Hooks P8 leaves: `PowerSpectrum`/`Spectrum`/`FeatureFrame` are the feature-edge element types; `Concat`
(named fan-in) already mints `node.in.<name>` + `ConcatOut` (port.zig); the Rate/pull executor binding
now runs type-changing analysis chains. The non-RT pull root + SPSC-ring cross-root tap are the new work.
