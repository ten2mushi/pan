# Phase 9 coverage audit — Analysis pull root, typed feature ports, Concat, FeatureCollectorSink, feature chains

- **Date:** 2026-06-04
- **Toolchain:** `zig 0.16.0` (verified via `zig version`)
- **Auditor:** independent read-only audit (evidence is `path:line`, trusting code over claims)
- **Repo root:** `/Users/komorebi/Documents/projects/tools/audio/pan/`

## Summary verdict

**Phase 9 is substantially IMPLEMENTED and green.** Every numbered work item, every gate success
criterion, and the full Yoneda dispatch are present in `src/` and exercised by three landed,
build-registered test harnesses; `zig build test` exits 0 and the analysis harness passes 7/7. The
only genuine shortfalls are additive-by-wording, not gate items: (a) the "plus the
perceptual-sparse/onset chains from `research/`" mention in work item 3 is **NOT** implemented (the
five named chains are; the research-derived extras are absent), (b) `ChannelMap` is a single-mono-`Map`
form with the composite-subgraph functor explicitly deferred and surfaced, and (c) the `examples/`
consumer and the isolation **Benchmark** are deferred (examples to Phase 18 per the plan; the named
analysis-isolation bench is not stood up).

## Checklist

| # | Item | Verdict | Evidence `path:line` | Note |
|---|------|---------|----------------------|------|
| 1a | `ClockSource` union — 3 variants (AudioDeviceCallback / WallClockTimer / InputExhaustion) | IMPLEMENTED | `src/engine.zig:955-964` (`audio_device_callback`, `wall_clock_timer: u32`, `input_exhaustion`) | All three variants present; matches spec §6 `ClockSource ∈ {…}`. |
| 1b | `PullRoot` abstraction (non-RT analysis root) | IMPLEMENTED (as commit-mode, not a named struct) | `src/builder.zig:349` `commitAnalysis` → `.mode=.offline_batch`; `src/engine.zig:1475` `runToCompletion` | No literal `PullRoot{ clock, sink_set, owned_subplan }` struct; the abstraction is realised as the analysis commit + drive path. The "root" is the committed Engine. |
| 1c | `runToCompletion` drive (input-exhaustion + max_blocks) | IMPLEMENTED | `src/engine.zig:1475-1503`; `RunOptions` `src/engine.zig:966-973`; alias `renderToCompletion` 1505 | Pulls until every `exhausted` probe drains; `NoExhaustibleSource` guard at 1486. |
| 1d | Exhaustion probe on the source | IMPLEMENTED | `src/io.zig:483` `LpcmSource.exhausted`; engine poll `src/engine.zig:1494-1500` | Non-looping source reports drained; looping never does. |
| 2a | Cross-root SPSC-ring tap (`Tap`/`TapSource`) | IMPLEMENTED | `src/io.zig:562` `Tap`, `src/io.zig:579` `TapSource`; ring `src/control.zig:165` `SpscRing` | Wait-free push, drop-on-full, zero-on-empty; cross-root coupling is the ring only. |
| 2b | "shared upstream rendered once and fanned to a second root" | IMPLEMENTED + tested | test `tests/analysis_root_test.zig:262-307` | RT root renders ramp once → ring; non-RT root reads exactly K·N samples in order. |
| 3a | `Concat(spec)` named fan-in; `node.in.<name>` wiring | IMPLEMENTED | `src/combinators.zig:45` `Concat`, `:70` `ConcatN`; `pub const inputs = spec`; named-port test `tests/analysis_yoneda_test.zig:198` | Arities 1–8, each an explicit `process`; wired by name in a committed run. |
| 3b | Output-struct field order = canonical column order | IMPLEMENTED + tested | `port.ConcatOut` (decl-order struct); tests `src/combinators.zig:228-246`, `tests/analysis_yoneda_test.zig:129`, `:303` | Field order = spec declaration order; permuting producers permutes columns. |
| 3c | Wrong element type on `node.in.<name>` = compile error | IMPLEMENTED (⊢ by construction) | `connect` type-check `@compileError` in `src/graph.zig:2-4` (doc), enforced in connect path | By-construction (can't be a runtime test — it wouldn't compile). No negative-compile fixture dedicated to Concat element-type (the P8 fixture only covers missing-Rate); the 8-port-ceiling overflow IS a `@compileError` at `src/combinators.zig:49`. |
| 4 | `ChannelMap(Sub, C)` — replicate over C, pool scales by C | PARTIAL (single mono `Map` only; composite deferred + surfaced) | `src/combinators.zig:201-226`; tests `tests/analysis_yoneda_test.zig:783`, `:821` | Holds `[C]Sub` (per-plane state), runs each plane; pool sizes by C via the C-channel frame element. Multi-node-subgraph functor is an explicit `@compileError`/deferral (`:204`), matching catalog §4.4 "achievable case". |
| 5 | `FeatureCollectorSink(Row)` — non-RT, `capacity_hint` pre-reserve + ×2 growth | IMPLEMENTED | `src/io.zig:510-547`; `ensureTotalCapacity(capacity_hint)` at `:526`; geometric append `:536` | Unmanaged `ArrayList`; `growable_sink=true` marker `:515`; OOM sets `overflowed` rather than panicking. |
| 6 | Law A8 — FeatureCollectorSink on RT root = commit error | IMPLEMENTED (⊢ check + ≈ test) | error variant `src/commit.zig:281-287` `GrowableSinkOnRealtimeRoot`; raise site `src/engine.zig:1030-1033` (in `bind`, gated `mode==.realtime_streaming`); node flag `src/graph.zig:107`,`:267`; tests `tests/analysis_root_test.zig:159`, `tests/analysis_yoneda_test.zig:488`,`:507`,`:528` | RT `commit()` rejects; same graph via `commitAnalysis` accepts; no false positive without a growable sink. |
| 7a | Feature chain: `Rms` (FeatureFrame→Scalar(f32), Map, oracle) | IMPLEMENTED | `src/feat.zig:37-52`; tests `tests/feat_yoneda_test.zig:64,73,84,101` | Spectral RMS in f64; oracle = independent mean-power. |
| 7b | `DominantBand` (FeatureFrame→Scalar(u16), Map, oracle) | IMPLEMENTED | `src/feat.zig:65-86`; tests `tests/feat_yoneda_test.zig:120,135,152,162` | First-index argmax; oracle + tie-break tests. |
| 7c | `SpectralCentroid` (→Scalar(f32), Map, oracle) | IMPLEMENTED | `src/feat.zig:99-118`; tests `tests/feat_yoneda_test.zig:201,210,223,234,247` | Power-weighted mean bin; 0 on silence; weighted-mean oracle. |
| 7d | `SpectralFlux` (history, →Scalar(f32), Map, oracle) | IMPLEMENTED | `src/feat.zig:137-158` (`prev:[bins]f32`); tests `tests/feat_yoneda_test.zig:276,289,300,318,335,349` | Half-wave-rectified L2; stateful-yet-rate-1:1; sub-block ≡ whole-block (S6) test at `:349`. |
| 7e | `Mfcc` (→FeatureFrame(n_coeffs), Map, oracle) | IMPLEMENTED | `src/feat.zig:192-275` (comptime mel filterbank + DCT-II); tests `tests/feat_yoneda_test.zig:461,483,514,535` | Oracle = independent mel+DCT; two geometries tested. Classify+element test `src/feat.zig:277`. |
| 8 | "perceptual-sparse/onset chains from `research/`" | MISSING (additive wording, not a gate item) | research notes exist (`research/features/perceptual-sparse-and-ultra-low-compute-features.md`, `research/detection/onset-beat-and-transient.md`) but **no** corresponding `feat.zig` block | `src/feat.zig` ships only the five named chains; the "plus … from research/" extras are absent. Not referenced by the gate criteria, so it does not block the gate. |
| 9a | `writeFeatureMatrix` + `encodeFeatureMatrix` | IMPLEMENTED | `src/io.zig:659` `writeFeatureMatrix`, `:643` `encodeFeatureMatrix`, `:598` `featureMatrixColumns`, `:622` `flattenRow`; tests `tests/analysis_yoneda_test.zig:687,701,747,756` | Row-major native-endian f32; int scalars widen to f32; column count/order tested. |
| 9b | Matrix matches `notes/1.md` viz schema (dominant→color, rms→amplitude, row→time) | IMPLEMENTED (schema mapping is doc-asserted; viz consumer deferred) | doc `src/io.zig:638-642` ("dominant→color, rms→amplitude, row index→emission time"); flatten test `tests/analysis_root_test.zig:122` | Column layout = Concat field order = viz column order. The actual Python 60 fps consumer + `examples/` buildout is **DEFERRED-BY-DESIGN** to Phase 18 (`pan_implementation_plan.md:754-755`, `:1096`). No `examples/` dir exists yet. |
| 10a | Gate: per-hop matrix collected, no effect on concurrent audio root's deadline | IMPLEMENTED + tested | test `tests/analysis_root_test.zig:199-260` (separate engines; audio telemetry unchanged) | Structural isolation: separate roots/pools; xrun_count & fault unchanged. |
| 10b | Gate: Concat field order = column order | IMPLEMENTED + tested | see #3b | — |
| 10c | Gate: FeatureCollectorSink-on-RT-root commit error | IMPLEMENTED + tested | see #6 | — |
| 10d | Gate: matrix drives the viz schema | IMPLEMENTED (mapping); consumer DEFERRED | see #9b | Schema-to-column mapping present and tested; the rendering example is Phase 18. |
| 11 | Yoneda dispatch (Rule 14): autonomous tests for feat blocks + Concat + A8 | IMPLEMENTED | `tests/feat_yoneda_test.zig` (feat, oracle), `tests/analysis_yoneda_test.zig` (Concat type-checks, A8 rejection, ChannelMap, collector, encode), `tests/analysis_root_test.zig` (root/tap/isolation) | Oracle-based (NumPy-equivalent) per §0.4/§0.5; A8 rejection ⊢ tested at `tests/analysis_yoneda_test.zig:488`. |
| 12 | New test files registered in build.zig; four-mode matrix wired | IMPLEMENTED | `build.zig:102-104` (all three harnesses in `harnesses`); modes via `standardOptimizeOption` `build.zig:6`, §0.6 matrix run per-mode by CI | Each harness built+run as a test artifact (`build.zig:106-116`); four-mode matrix is the `-Doptimize` sweep, not an in-build loop. |

## Honest gaps / boundaries

- **No literal `PullRoot` struct.** The spec writes `PullRoot := { clock_source, sink_set, owned_subplan }`
  (`pan_execution_model.md:314`). The implementation realises this as a *commit mode* + drive path
  (`commitAnalysis` → `runToCompletion`) on the existing `Engine`, not a distinct `PullRoot` type. This
  is a faithful realisation (the Engine owns its subplan/pool; the clock is `ClockSource`), but a reader
  expecting a named type will not find one. Verdict kept IMPLEMENTED because every behaviour the abstraction
  promises is present and tested.
- **`ChannelMap` is single-mono-`Map` only (PARTIAL).** The composite-subgraph (multi-node) functor is a
  hard `@compileError` (`src/combinators.zig:204`) and documented as a combinators-phase extension. Catalog
  §4.4 frames functoriality as an ≈-tested *obligation*; the landed test (`tests/analysis_yoneda_test.zig:783`)
  checks per-plane independence but not the "ChannelMap over a composite = composite of ChannelMaps"
  functoriality law (it can't, since composites aren't supported). This matches the file's own surfaced
  boundary and is the achievable case, but the functoriality obligation is only partially discharged.
- **"perceptual-sparse/onset chains from research/" not implemented (MISSING).** Work item 3 lists these as
  "plus the … chains from `research/`". `src/feat.zig` ships only Rms/DominantBand/SpectralCentroid/
  SpectralFlux/Mfcc. The research notes exist but no block does. Not a gate criterion, so the gate still
  passes; flagged because the plan text names them.
- **`examples/` consumer + isolation Benchmark deferred.** No `examples/` directory exists; the plan defers
  the full `examples/` buildout to Phase 18 (`pan_implementation_plan.md:754-755`, `:1096`), so this is
  DEFERRED-BY-DESIGN. The Phase 9 "Benchmark" subsection (analysis-isolation, zero `deadline_headroom`
  effect — `pan_implementation_plan.md:766-767`) has **no** dedicated `bench/` file (`bench/` holds
  coloring/dsp/feedback/spectral only). Benchmarks are explicitly measurement-not-gate (§0.9), so this does
  not block the gate, but the named isolation bench is absent.
- **Wrong-element-type compile error has no dedicated negative-compile fixture.** It is ⊢ by construction
  (connect's `@compileError`, `src/graph.zig:2-4`); the only active negative-compile fixture in `build.zig`
  is the P8 missing-Rate one (`build.zig:124-133`). The Concat 8-port-ceiling overflow is itself a
  `@compileError` (`src/combinators.zig:49`) but is likewise not wired as a must-fail build fixture. The
  element-type rejection is therefore proven structurally but not pinned by an automated must-fail compile.

## Test-run result

- `zig version` → `0.16.0`
- `zig build test 2>/dev/null; echo EXIT=$?` → **`EXIT=0`** (full four-mode-capable suite green;
  `aliasing_message_test`/`comparator_test` print expected reject-path diagnostics, suite still exits 0).
- Direct analysis harness:
  `zig test --dep pan -Mroot=tests/analysis_root_test.zig -Mpan=src/root.zig -framework AudioToolbox -framework CoreAudio -framework CoreFoundation -lc`
  → **`All 7 tests passed.`** (input-exhaustion collection, viz flatten, A8 reject, no-source reject,
  deadline isolation, cross-root tap, full Stft→power→feature chain).

**Conclusion:** Phase 9's gate is met and green. The four numbered work items, all four success criteria,
and the Yoneda dispatch are implemented and tested at Zig 0.16.0. Outstanding items are additive
(research-derived chains), explicitly deferred (`examples/`, isolation bench → Phase 18 / §0.9), or a
surfaced design boundary (composite `ChannelMap`).
