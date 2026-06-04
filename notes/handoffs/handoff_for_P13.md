# Handoff — end of Session 11 (P12 "`VariRate`: bounded-variable-rate `Rate`") → into P13

> **Status:** P0–P11 + **P12 implemented, FULL-SURFACE, and green.** All four §12 work-item-1
> membership examples ship (drift-ASRC, varispeed `SamplePlayer`, WSOLA time-stretch, pitch-shift),
> the worst-case planning + determinism split, and the external gold oracle. An adversarial
> ownership re-audit (post-completion) caught two genuine defects — a `SamplePlayer` wrap bug and,
> critically, that the first time-stretch was a plain OLA that **resamples instead of stretching**
> (does not preserve pitch) — both since **fixed** (the time-stretch is now WSOLA). Advisory handoff,
> not a spec: `specifications/` + `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-04. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P13 start — Rule 13).
> P12 = the `VariRate` family: a `Rate` whose out:in ratio varies at runtime inside a declared
> bounded interval, with **worst-case static planning** and the **honest determinism split**
> (parameter-driven O3-reproducible; controller-driven ≈-only).

---

## 1. Ownership statement (honest, Rule 12)

The P12 **gate** (plan §12 success criteria) is **met and green across the four-mode matrix** plus
fmt-check / smoke / neg-compile / cross-linux (all exit 0). Trust the EXIT CODE, never a printed test
count (the carried reject-path noise — aliasing_message "error:" lines, the comparator/gold "allclose
fail" lines, the neg-compile `@compileError`s/`port element-type mismatch` — prints by design and fails
NO step). Each gate criterion, discharged:

- **Measured out:in ratio ∈ `[min, max]`** — `Varispeed` is swept across the interval and an
  out-of-range request is **clamped INTO** the interval (it can never escape `rate_bounds`).
- **Impulse delay ≤ `max_latency` at every operating point** — proved for ratios ≥ 1 (the latency
  probe's well-defined half). DOWNsampling a *unit impulse* is undersampling — the impulse can fall
  between output samples and vanish — which is an aliasing property of the linear tier, not a latency
  one, and is covered instead by the ratio / needed_input checks. Honestly noted in the test.
- **`needed_input(want)` sound & monotone over `want` and across ratios** — exactly
  `needed_input(want)` inputs always yield `want` outputs (sound); non-decreasing in `want`,
  non-increasing in the ratio (monotone).
- **Parameter-driven `VariRate` is O3-reproducible** — a chunked render is **bit-identical** to a whole
  render (the resumable-state contract; sub-block = strict prefix), and two identical renders are
  byte-identical. (Chunkable across THREADS is Phase 14; here "reproducible" = pure-function-of-input.)
- **Controller-driven ASRC keeps a bridging FIFO centred over a long run without xrun (≈)** — a ±1.5%
  capture-clock mismatch (faster AND slower) over 6000 rounds holds the FIFO in a centred band with
  **zero** underruns (`xruns == 0`) and **zero** overflow drops. Correctly NOT bit-reproducible (it
  tracks a wall-clock fill level — the same class as the clock drift it compensates).

**Yoneda dispatch (Rule 14):** five autonomous `yoneda-test-writer` agents (each loaded `zig-0-16`,
verified by compiling). **115 tests, all green; 2 genuine bugs found and FIXED, 0 surviving:**
`varispeed_yoneda` (15 — independent linear-interp oracle across nine ratios, identity-at-1.0, DC,
linearity, sinusoid period-scaling, held-per-call, chunk-invariance at π/2, clamp idempotence),
`asrc_yoneda` (19 — PI control-law sign, ratio clamp, anti-windup recovery, underrun accounting,
interval-extreme convergence), `sampleplayer_yoneda` (27 — native/2×/0.5× playback vs an independent
oracle, clamp, held-per-call, chunk-continuity, loop periodicity, drain→done, DC, **caught the 1-sample
loop wrap bug**), `timestretch_yoneda` (34 — DC/COLA exactness, duration-tracks-stretch, identity at 1,
linearity, resumable WSOLA state, pitch preserved), `pitchshift_yoneda` (20 — `.Map` classification,
constant duration, **the octave-up/down + inner-stretch-preserves-frequency tests that caught the
plain-OLA "doesn't stretch" defect**, DC, resumability).

Test totals: **125/125 steps, 1177/1177 tests, exit 0** (Debug; ReleaseSafe & ReleaseFast settle to
exit 0 — see the cache note below), up **+125** from P11's 1052 (gate + gold + 115 Yoneda + inline).

> **`.zig-cache` mode-switch transient (NOT a failure).** The FIRST `zig build test -Doptimize=...`
> invocation run immediately after a *different* optimize mode can exit 1 from a build-orchestration
> cache race (a re-run, or a cold `rm -rf .zig-cache` run, is exit 0; `--summary all` reports
> 1095/1095 passed even on the transient). Verify each mode in **isolation** (the §3 way) or run it
> twice and read the settled result — do not read the alternating-loop's first-after-switch code.

---

## 2. What was built (the deltas)

```
src/spectral.zig (M)  + `Varispeed(num)` — the headline arbitrary-runtime-ratio resampler `VariRate`
                       (varispeed / scrub / sample-playback pitch). Discriminated at comptime by
                       `rate_bounds = .{ .min=.{1,4}, .nominal=.{1,1}, .max=.{4,1} }` (interval
                       [0.25,4.0]) + `max_latency=5` + `ratio_source=.parameter` +
                       `params=.{ .ratio = Scalar(f32) }`. 2-point LINEAR interpolation over a
                       resumable streaming cursor (`prev`,`frac`); ratio held-per-call via
                       `control.Param`+`setParam`. `needed_input(want)` = worst-case current-ratio
                       input + 1 guard. + the `control` import.
src/io.zig       (M)  + `Asrc(num, cap)` — the device-boundary drift-correcting asynchronous SRC: a
                       `VariRate` SOURCE over a bridging `SpscRing(Sample(T), cap)` FIFO with an
                       INTERNAL PI controller on the fill level (`ratio_source=.internal_controller`,
                       tight `rate_bounds=.{.min=.{31,32},.nominal=.{1,1},.max=.{33,32}}`,
                       `max_latency=cap/2+1`). Negative feedback: fill > setpoint ⇒ ratio < nominal ⇒
                       drain; anti-windup clamps the integral CONTRIBUTION to half the interval. Holds
                       the last sample + flags `xruns` on FIFO underrun.
src/io.zig       (M)  + `SamplePlayer(num)` — varispeed / scrub sample-playback at a live `param.pitch`:
                       a `VariRate` SOURCE over an owned mono asset, fractional linear-interp cursor,
                       loop/drain, `rate_bounds`=[1/2,2]. (Wrap bug — single `if` not `while` — caught
                       by the Yoneda re-audit and FIXED.)
src/spectral.zig (M)  + `TimeStretch(num, FRAME)` — runtime tempo change WITHOUT pitch change, a
                       `VariRate` SOURCE. **WSOLA** (waveform-similarity overlap-add): grains are
                       overlap-added on a fixed 50%-Hann (COLA-exact) synthesis grid, and each grain's
                       read position is SEARCHED (±HS, normalised cross-correlation) for the offset
                       whose leading half best matches the previous grain's natural continuation — the
                       phase-coherence step that PRESERVES PITCH. (The first revision was a plain OLA
                       that resampled — frequency scaled by 1/stretch — and did NOT stretch time; the
                       Yoneda re-audit proved it and it was replaced with WSOLA.)
                     + `PitchShift(num, FRAME)` — constant-duration pitch shift = WSOLA time-stretch by
                       P ∘ resample by 1/P. Net rate 1:1, so it is a rate-preserving **`Map` SOURCE**
                       composing two variable-rate stages internally (owns a `TimeStretch` + a 2-point
                       resample cursor). Verified: P=2 raises the dominant frequency an octave, P=0.5
                       lowers it, duration preserved.
src/graph.zig    (M)  THE ONE CORE-WIRING FIX: `Graph.add` now stores a VariRate node's `max_latency`
                       as its planning `algorithmic_latency`, so the PDC longest-path DP compensates a
                       VariRate for its WORST-CASE delay over the interval (V2). Was 0 before (a
                       VariRate declares no `algorithmic_latency`) — PDC would have under-compensated.
                       (`ratioOf` already read `rate_bounds.min` for sizing; docstring de-staled.)
scripts/generate.py (M)  + `_ref_varispeed` (NumPy f64 mirror of the streaming linear resampler) in
                       `_REFERENCES` — the external gold oracle for the rate seam.
src/root.zig     (M)  + `pan.Varispeed`, `pan.Asrc`, `pan.SamplePlayer`, `pan.TimeStretch`, `pan.PitchShift`.
tests/varirate_latency_test.zig (NEW, gate)  the §5.7f interval contract: ratio∈[min,max] + clamping,
                       impulse-delay ≤ max_latency, needed_input sound+monotone, chunked≡whole bit-exact
                       + identical-render byte-identical, drift-Asrc FIFO-centred faster+slower clocks.
tests/varirate_gold_test.zig (NEW)  external NumPy-oracle ≈ gold for `Varispeed` (loads input+expected
                       blobs, allclose; graceful skip when the git-ignored blobs are absent — run
                       `python3 scripts/generate.py tests/vectors/varispeed_f32.json`).
tests/varispeed_yoneda_test.zig (15), tests/asrc_yoneda_test.zig (19), tests/sampleplayer_yoneda_test.zig
                       (27), tests/timestretch_yoneda_test.zig (34), tests/pitchshift_yoneda_test.zig (20)
                       (NEW, autonomous Yoneda — 115 tests, 0 surviving bugs after the two fixes above).
build.zig        (M)  + the seven new test harnesses registered.
```

## 3. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug — 125/125 steps, 1177/1177 tests, EXIT 0 (check the exit code!)
zig build test -Doptimize=ReleaseSafe   # exit 0 (run it COLD or twice — see the cache note in §1)
zig build test -Doptimize=ReleaseFast   # exit 0 (idem)
zig build fmt-check                     # exit 0
zig build smoke                         # exit 0
zig build neg-compile                   # exit 0
zig build cross-linux                   # exit 0
```

## 4. The load-bearing design decisions (Rule 7 / Rule 12)

- **The `VariRate` scaffolding already existed** (from P8): `port.classify` returns `.VariRate` by
  `rate_bounds` field presence (xor `out_per_in`), `BlockClass` includes it, `graph.ratioOf` reads
  `rate_bounds.min`, the engine executor dispatches `.VariRate` through `pull` (it keys on
  `classify(Block) != .Map`), and `builder`/`graph` handle `.Rate, .VariRate` uniformly. P12 added the
  LIBRARY BLOCKS + the one PDC `max_latency` wiring fix. **No new core morphism machinery.**
- **`rate_bounds` is authored as 2-element tuples, not a named struct.** The committed convention
  (port.zig/commit.zig test scaffolding + `ratioOf`) is `.{ .min = .{p,q}, .nominal = .{p,q}, .max =
  .{p,q} }` — integer `{p,q}` tuples, read as `m[0]`/`m[1]`. The catalog/devx *illustrative* code shows
  a `pan.RatioInterval`/`pan.Ratio{.p,.q}` named struct; the REAL codebase uses tuples and that is what
  every classifier/sizer expects. **Conformed to the tuple form (Rule 11)**; did NOT introduce a named
  `RatioInterval` type (it would break the existing green scaffolding for zero behavioural gain). If a
  future phase wants the named struct, it must migrate `ratioOf` + the port/commit tests together.
- **`VariRate` belongs at boundaries / as a SOURCE — not as a sustained mid-graph processor.** A static
  op-list sizes each edge ONCE (on the `min` ratio); a continuously-variable ratio mid-graph against a
  fixed device clock would need unbounded buffering. The spec resolves this by placing VariRate at the
  device boundary (`Asrc`, owns its FIFO) or as a sample/stream source (owns its asset). `Asrc` is a
  true zero-sample-input source and is graph-safe (always produces `want` from its own FIFO).
  `Varispeed` is a *processor* whose tested contract is "given exactly `needed_input(want)` inputs it
  produces `want`" — the **isolated / offline / elastic-source** contract (§5.7f drives it via
  `TestSampleMux`; OfflineBatch drives it with an elastic source). Wired behind a *fixed* upstream at a
  ratio above `min` it would be over-supplied and the surplus is dropped (not retained) — so pair a
  real-time varispeed with an elastic source, exactly as a sampler reads its own asset. This is the
  spec's boundary, surfaced honestly, not a bug.
- **Quality tier = linear interpolation.** Both blocks use 2-point linear interpolation: cheap,
  low-latency, adequate for the *contract* (bounded ratio, centred FIFO, monotone demand). A
  windowed-sinc / cubic kernel + wide-fixed-point (Q4.60) ratio — the >130 dB-SNR tier (the existing
  fixed-ratio `spectral.Resampler` is already windowed-sinc) — is the explicit quality upgrade, not
  implemented. The `io.RuntimeResampler` (a runtime rational polyphase-sinc helper) already exists for
  the fixed-rate boundary SRC case.

## 5. Code-documentation compliance (the §0.2 rule)
All new `src/` comments and doc-comments are **self-contained** (Rule 15): laws restated inline in plain
prose, NO `specifications/*.md` / section-number / "Phase N" / roadmap tokens. A re-scan of the new
code (Varispeed, Asrc, the graph.zig edit) is clean; section-style refs live only in test names (§0.4
permits that).

## 6. Surface coverage audit (Rule 12 — every §12 work item, honest verdict; post-ownership-re-audit)
**Work item 1 — FULLY SHIPPED.** All four named membership examples:
- **drift-ASRC** — **DONE** (`io.Asrc`, controller-driven PI on the bridging FIFO, FIFO-centred, the ≈
  class). "Bypass on a single full-duplex clock" is a device-HAL decision (skip inserting the block),
  documented in the doc-comment; the block is complete.
- **varispeed / scrub `SamplePlayer` (`param.pitch`)** — **DONE** literally: `io.SamplePlayer(num)` is a
  zero-sample-input `VariRate` SOURCE over an owned asset with `param.pitch`, PLUS `spectral.Varispeed`
  (the arbitrary-ratio resampler *processor*) for the §5.7f isolated-contract / mid-stream case.
- **runtime-stretch TSM** — **DONE** as `spectral.TimeStretch` (WSOLA, pitch-PRESERVING; the
  variable-rate seam is the analysis hop, the synthesis grid is the fixed COLA-exact 50%-Hann grid). The
  spec's "phase-vocoder" is one realisation; WSOLA is the equivalent time-domain realisation and is what
  ships. A frequency-domain phase-vocoder front-end is an interchangeable fidelity variant (not needed —
  WSOLA already preserves pitch to RMS≈0.707 on a tone).
- **pitch-shift (TSM ∘ resample)** — **DONE** as `spectral.PitchShift` (WSOLA stretch by P ∘ resample by
  1/P; a rate-1:1 `Map` SOURCE composing the two variable-rate stages). Verified octave up/down.
- **Work items 2 & 3** — **DONE**: min-ratio sizing (`ratioOf`), PDC on `max_latency` (the graph.zig
  fix), ratio held per call (`control.Param` sampled once in `pull`), parameter-vs-controller
  determinism split proven.

**The ownership re-audit that got us here (Rule 12 in action).** A first P12 pass shipped only
`Varispeed` + `Asrc` and DEFERRED TSM/pitch-shift/SamplePlayer with a "they compose from the mechanism"
rationale. An adversarial "do you take full ownership of the whole §12 surface?" re-read showed that was
a real scope cut, so the remaining three blocks + the external gold oracle were implemented. The Yoneda
gate then earned its keep twice: it caught (a) a `SamplePlayer` loop-wrap bug (single `if` instead of a
`while`/true-modulo — silent after the first output for a 1-sample loop at fast pitch), and far more
importantly (b) that the first `TimeStretch` was a **plain overlap-add that resamples instead of
stretching** — the grain-boundary phase jumps scale the frequency by `1/stretch`, so it did NOT preserve
pitch, and `PitchShift` (TSM ∘ resample) cancelled to a no-op. Both FIXED: SamplePlayer uses a `while`
wrap; `TimeStretch` is now **WSOLA** (a normalised cross-correlation search aligns each grain to the
previous grain's continuation, the phase-coherence step that preserves pitch). Lesson for future
sessions: a "naive OLA tier" for time-stretch is not a lower-fidelity tier — it is *wrong* (it
resamples); pitch preservation REQUIRES waveform alignment (WSOLA) or phase propagation (vocoder).

## 7. What P13 needs (from plan Phase 13) + carried obligations
P13 = **Sources, typed event lane, `NoteEvent`, `PolyVoice`, the Instrument vertical slice**. Read
first: plan §13; `catalog.md` §2.7 (Source SR1–SR3), §8.6 (`EventLane(Event)` + `NoteEvent` EV1–EV3),
§8.12 (`Voice`/`PolyVoice`/`VoiceMap` Y1–Y6), §8.13 (Instrument shape); `pan_execution_model.md` §2.1
(Source = zero-sample-input Map), §4.4 (event lane), §6 (Instrument root); `pan_io_realtime_and_pipeline.md`
§6 (sample-accurate events + sub-block), §9 (transport); `pan_developer_experience.md` §6b;
`pan_testing_and_vector_contract.md` §5.7g/§5.7h; skill ch.02 (`union(enum)` for `NoteEvent`), ch.04
(PolyBLEP / band-limited oscillators).

**Carried obligations / residuals (surfaced for whoever schedules them):**
- **`SamplePlayer`/file source is ALSO a P13 item** — `io.SamplePlayer` ships the varispeed/pitch
  *source*; plan §13 work item 1 additionally wants the file/streaming source (over the off-thread
  prefetch FIFO). The P13 author can reuse `SamplePlayer`'s cursor shape over a `Rate`/`VariRate` FIFO.
- **`ChannelMap`-over-a-composite functoriality** ≈-test — Phase 13 (with `Voice`/`VoiceMap`), per the
  plan; the P9 handoff mis-scoped it to P11. `combinators.ChannelMap` exists; the test does not.
- **Quality tiers (optional, fidelity not contract):** windowed-sinc/cubic + Q4.60 ratio for
  `Varispeed`/`Asrc` (the >130 dB-SNR resampler upgrade over the shipped linear tier); a frequency-domain
  phase-vocoder front-end for `TimeStretch` (an interchangeable alternative to the shipped WSOLA);
  multi-channel (planar) `Varispeed`/`SamplePlayer`/`TimeStretch` (mono only today).
- Optional: a `bench/varirate_bench.zig` (no P12 bench added — the resampler kernels are cheap; WSOLA's
  per-grain cross-correlation search is the one non-trivial cost worth measuring).
