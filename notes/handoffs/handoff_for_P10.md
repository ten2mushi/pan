# Handoff — end of Session 8 (P9 "Analysis pull root") → into P10

> **Status:** P0–P8 + **P9 implemented, full-surface, and green.** Advisory handoff, not a spec:
> `specifications/` + `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-04. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P10 start — Rule 13).
> P9 = roadmap step 6: the Analyzer graph shape — a non-RT pull root driving file→features→collector.

---

## 0. Update (post-Session-8) — P9 feature buildout + doc scrub landed, still green

Two follow-on passes shipped ON TOP of the P9 gate below (everything in §1–§5 still holds; this section
records what changed). Full detail: `notes/handoffs/handoff_for_P9_feature_buildout_followup.md`. Memory:
`pan-p9-feature-buildout`.

- **Feature-extraction buildout (first wave).** 14 new `src/feat.zig` blocks, all rate-1:1 `Map`s, each
  with its exact formula in the doc-comment (the oracle spec): the spectral shape descriptors
  (`SpectralRolloff`/`Flatness`/`Entropy`/`Spread`/`Skewness`/`Kurtosis`/`Crest`, `Hfc`), `Chroma`→
  `FeatureFrame(12)`, `SpectralContrast`→`FeatureFrame(n_bands)`, the flicker-free `DominantBandHysteresis`
  (stateful COLOR descriptor), and the time-domain `Zcr`/`TeoMean`/`BallisticEnvelope` (over
  `spectral.TimeFrame` from `Framer`; `BallisticEnvelope` is the smoothed [0,1] AMPLITUDE descriptor).
- **Open P9 boundary §4.1 CLOSED.** `tests/negative/concat_type_mismatch.zig` + a second `neg-compile`
  build step (`build.zig` `neg_concat`) make the Concat wrong-element-type `@compileError`
  (`src/graph.zig:340`) an ACTIVE must-fail fixture.
- **Worked graph.** `tests/analysis_buildout_test.zig` (3 tests): `LpcmSource → Stft → PowerSpectrum →
  {extractors} → Concat → FeatureCollectorSink → encoded matrix`, proving the column-major `f32` layout end
  to end + the flicker-free color and ballistic amplitude descriptors.
- **Yoneda dispatch (Rule 14).** 3 autonomous writers, **94 tests, all green, ZERO bugs**:
  `tests/feat_spectral_shape_yoneda_test.zig` (42), `tests/feat_chroma_contrast_yoneda_test.zig` (23),
  `tests/feat_timedomain_yoneda_test.zig` (29). All 4 new harnesses registered in `build.zig`.
- **§0.2 code-documentation pass.** All `src/` doc-comments are now self-contained: spec-`.md` citations
  (`catalog §x`, `*.md §y`, "the spec's …") and project-grounding ("viz", `notes/1.md`, "the Python side",
  "60 fps", `examples/`) were removed/rephrased into agnostic prose; conceptual content preserved. Spec
  citations remain only in test names (§0.4-sanctioned).
- **Deferred (rationale in the followup handoff §4):** BS.1770/EBU-R128 gated loudness (wants a `Rate`
  decimator with per-sample K-weighting, not a per-frame `Map`); the combined time+spectral single-matrix
  fan-out (multi-Rate same-source fan-out, unverified under commit/PDC); Tier C/D (LPC/formants/pitch/PNCC/
  onset/VAD → likely `src/detect.zig`); GFCC. None gate P10.

---

## 1. Ownership statement (honest, Rule 12)

The P9 gate (`pan_implementation_plan.md` §9 success criteria) is **met and green across the four-mode
matrix** plus smoke / cross-linux / fmt-check / neg-compile / bench-gate (all exit 0):
- A per-hop feature matrix is collected on a non-RT analysis root with **no effect on a concurrent
  audio root's deadline** (the analysis engine is a *separate* `Engine` with its own pool, driven by
  `runToCompletion`, never the device callback — structural isolation; demonstrated by a test asserting
  a separate audio engine's telemetry is untouched while an analysis run completes).
- `Concat` field order **is** the column order, wired **by name** (`node.in.<name>`); a wrong element
  type on a named input is a `@compileError` naming the port.
- A `FeatureCollectorSink` on a realtime root is a **commit error** (`error.GrowableSinkOnRealtimeRoot`,
  law A8); the same graph commits via `commitAnalysis`.
- The collected matrix flattens to the `notes/1.md` viz column layout (dominant→color, rms→amplitude,
  row→emission time).

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents (each loaded `zig-0-16`,
verified by compiling). The analysis-surface writer **caught a real bug** (Rule 14 working as intended,
like P8's Framer bug) and correctly left its tests red — see §4. The feature-block writer found no bugs
(24 oracle tests green).

---

## 2. What was built (the deltas)

```
src/feat.zig    (NEW)  Five rate-1:1 Map feature blocks over a power spectrum (FeatureFrame(bins)):
                       Rms / SpectralCentroid / SpectralFlux(stateful prev) / DominantBand(→Scalar(u16))
                       / Mfcc(comptime mel filterbank + DCT-II tables, baked sr=48000/n_mels=26).
                       Each block's doc-comment states its EXACT formula (the oracle spec).
src/combinators.zig (NEW)  Concat(spec) — the REAL named fan-in (was a root.zig stub): arity 1..8
                       explicit `process` variants (a function param list can't be synthesized from a
                       comptime count) bounded by the 8-port ceiling; assembles one Out row per hop in
                       spec/field order. ChannelMap(Sub,C) — single-mono-Map replication over C planes.
src/io.zig      (M)    FeatureCollectorSink(Row) — growable non-RT sink (growable_sink marker,
                       capacity_hint pre-reserve at initialize, geometric ×2 in process, deinit, frames(),
                       overflowed). encodeFeatureMatrix/featureMatrixColumns/writeFeatureMatrix (row-major
                       f32, column order = Row field order; int scalars widen). LpcmSource += loop/done/
                       exhausted() (non-looping = input-exhaustion source) + data default (builder needs
                       Block{}).
src/engine.zig  (M)    ClockSource + RunOptions; runToCompletion(opts) (real — drives the bound op-list
                       block-by-block off-RT until input-exhaustion drains all sources; NoExhaustibleSource
                       if none); BoundNode.exhausted + exhaustThunkFor; destroyThunk calls a block's
                       deinit(alloc) when it declares initialize (heap-owning blocks); A8 reject in bind
                       (growable sink + realtime_streaming → error.GrowableSinkOnRealtimeRoot).
src/builder.zig (M)    add: calls inst.initialize(alloc) (lifecycle hook) + binds exhaustThunk; NodeHandle
                       += inst/instance() (read a sink's frames()); commitAnalysis() (non-RT, .offline_batch);
                       in(i) is now Rate-aware (InPortTypeAt) so a bare-handle connect wires to a Rate
                       block (Stft) too.
src/graph.zig   (M)    Node += is_growable_sink (set from the growable_sink decl).
src/commit.zig  (M)    CommitError += GrowableSinkOnRealtimeRoot (law A8). **BUG FIX (see §4):** the emit
                       pass now places sample inputs BY PORT INDEX (e.to_port / f.read_port), not in
                       edge-insertion order — input_buffer_ids[p] is the buffer wired to port p.
src/root.zig    (M)    feat = @import("feat.zig"); combinators = @import("combinators.zig") (real);
                       FeatureCollectorSink/writeFeatureMatrix/encodeFeatureMatrix/featureMatrixColumns/
                       ClockSource/RunOptions re-exports. (Short block names NOT aliased at root — they'd
                       shadow DSP authors' locals; use pan.feat.Mfcc / pan.combinators.Concat.)
build.zig       (M)    + analysis_root_test, feat_yoneda_test, analysis_yoneda_test.
tests/analysis_root_test.zig (gate), tests/feat_yoneda_test.zig + tests/analysis_yoneda_test.zig (autonomous).
```

## 3. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build smoke                         # freestanding ReleaseSmall comptime-commit
zig build cross-linux                   # x86_64-linux-gnu ALSA seam
zig build fmt-check
zig build neg-compile                   # two must-fail fixtures: missing-Rate-decl + Concat-type-mismatch
zig build bench -Dbench-gate            # footprint baseline 8192 B held
```
Carried cosmetic noise (unchanged): aliasing_message_test / comparator_test drive reject paths with
`std.debug.print`; the 0.16 runner echoes "failed command" but the suite exits 0.

## 4. The bug the Yoneda dispatch caught (Rule 14) — FIXED
Named `Concat` fan-in was **connect-order-keyed, not name-keyed, at render time.** The commit emit pass
(`src/commit.zig` §8) gathered a node's forward `input_buffer_ids` in **edge-insertion order** and never
ordered them by `e.to_port`. `Concat.process` assigns columns positionally by port index, so whenever the
connect order differed from the spec declaration order the columns mis-routed (homogeneous: silently
wrong values; heterogeneous: a hard crash binding a wrong-size buffer). The existing gate test always
connected in declaration order, so it never surfaced. **FIX:** the emit pass now places each sample input
at `in_ids[e.to_port]` (forward) / `in_ids[f.read_port]` (feedback read), packing densely over ports
0..=max. This is strictly more correct for *every* multi-input node (it also de-fragilizes multi-feedback
fan-in like an FDN matrix); single-input/feedback graphs are byte-identical (port 0 → index 0). Re-verified
green across the full matrix (feedback / coloring / PDC / FDN suites all pass).

## 5. Surface coverage audit (Rule 12 — every §9 work item, honest verdict)
Work item 1 — **DONE.** `PullRoot`/`ClockSource` (the `ClockSource` union has all three variants);
non-RT analysis root (`commitAnalysis` + `runToCompletion`); `InputExhaustion` fully drives + terminates;
**cross-root SPSC-ring tap is built** — `control.SpscRing(Elem,cap)` (wait-free push/pop, the house
CommandRing ordering discipline) + `io.Tap` (publish, on the upstream root) + `io.TapSource` (consume, on
the tapping root): the shared upstream is rendered ONCE on its root and fanned to a second root through the
ring only (test: `cross-root tap (C5) …`). `WallClockTimer` drives a bounded analysis run (the tap test
uses it); its *live 60 fps sleep-to-deadline pacing* is the OfflineBatch transport, scheduled for Phase 14
(plan line 955, `InputExhaustion`/`WallClockTimer` deterministic timeline) — not a P9 gate item.
Work item 2 — **DONE (Concat) + bounded (ChannelMap).** `Concat` full (named, column-order, arity 1..8, the
port-order bug fixed). `ChannelMap` realizes the C-fold product functor for a single mono `Map` `Sub` (the
spec's block model, element `Frame(Lane,.discrete(C))`, pool scales by C). The functoriality OBLIGATION
over a *composite* `Sub` (catalog §4.4: "ChannelMap over a composite = composite of ChannelMaps", an
≈-tested law) needs composite-block machinery — that is **Phase 11**'s deliverable (`Voice` = "composite
block, flattened", plan §11), so the composite `Sub` and its functoriality ≈-test are genuinely
Phase-11-gated, not dropped. A non-single-Map `Sub` is a `@compileError` (fails loud).
Work item 3 — **DONE (gate set) + open library.** `FeatureCollectorSink` full; the five gate-named chains
(`Mfcc`/`SpectralCentroid`/`SpectralFlux`/`DominantBand`/`Rms`) done and oracle-tested (24 Yoneda tests).
`SpectralFlux` is the onset descriptor. The plan's "plus the perceptual-sparse/onset chains from
`research/`" points at an open 15-file `research/features/` + `research/detection/` catalog (spectral
contrast, LPC/formants, BS.1770 loudness, PNCC, GFCC, …) — an analysis-library buildout beyond the gate's
enumerated five, not a single-phase deliverable. Adding more is incremental and graph-shape-identical.
Work item 4 — **DONE.** `writeFeatureMatrix`/`encodeFeatureMatrix` (the Python `examples/` *buildout* is
explicitly Phase 18).

**Surface deviations from the illustrative DX example** (`pan_developer_experience.md` §6, marked
"Illustrative / PLAUSIBLE"): the analysis graph commits via `g.commitAnalysis()` (NOT `g.commit()` — the
A8 check needs the root kind at commit time; auto-inferring would be hidden behavior, against the Zig
no-hidden-control-flow grain), and the chain is `LpcmSource → Stft → PowerSpectrum` (Stft frames
internally; no separate `Framer` node). A sink's collected rows are read via `sink.instance().frames()`.
The `feat.Mfcc` mel filterbank bakes `sample_rate = 48000` / `n_mels = 26` at comptime (a graph block
can't read the runtime `Config` rate); a different-rate graph re-instantiates against a matching constant.

## 6. What P10 needs (from plan Phase 10)
P10 = roadmap step 6b: **embedded bring-up** — the embedded profile as a strict comptime specialization of
the desktop core. Full comptime graph + `commitComptime` end-to-end; q15 fixed-point Numeric
(`Numeric{ i16, i32, saturate=true, W }`); static `.bss` `[footprint_bytes]u8` behind a
`FixedBufferAllocator`; the `SampleMux` collapsing to a concrete comptime type (vtable vanishes, render
monomorphizes/inlines); I2S-DMA HAL (circular 2N buffer, HT/TC IRQ as the render callback). Read first:
plan §10; `catalog.md` §8.5 (comptime-commit smoke gate, already green since P3), §9 (precision/N/W;
q15 default; freestanding stub), §1.4 (Acc/saturate on the fixed-point path);
`pan_io_realtime_and_pipeline.md` §8/§11; **skill ch.02 (typed `@Struct`/`@Int` — `@Type` is REMOVED;
this phase is where it bites in the monomorphized op-type construction), ch.03 (saturating `+|`/`-|`/`*|`),
ch.06 (`resolveTargetQuery` freestanding, `callconv(.c)` ISR).** Known carry: the fixed-point BIQUAD kernel
is a `@compileError` today (q-format needs wider coeff scaling — `dev-notes/fixed-point-biquad.md`); P10
resolves it. The comptime `Executor` (frozen Tier-A ground truth) is the embedded render path.
