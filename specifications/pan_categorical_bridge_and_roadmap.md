# pan — Categorical Bridge, Block Taxonomy & Roadmap

> **Status: LOCKED** (2026-06-02; **amended 2026-06-03** — parameter ports in the bridge table (§1) &
> taxonomy (§2); §4 item 7 records the assessment-§4 gap resolutions; roadmap step 6c; **then parallel
> & offline execution COMMITTED** — §1 Executor row, §4 item 8, §5 steps 7→8–12, §6 risk register;
> **then dual-purpose / synthesis platform COMMITTED** — pan is restated as a purpose-agnostic
> real-time audio DSP graph engine serving two canonical graph shapes, **Analyzer** & **Instrument**,
> from one core: §1 bridge rows for `ChannelLayout`/`VariRate`/Source/event-lane/`PolyVoice`/shapes,
> §2 taxonomy (sources, layout-aware spatial, `VoiceMap`), §5 step 6d Instrument slice, §6 risk
> register, §7 takeaway; see catalog §1.3/§2.6/§2.7/§8.6/§8.12/§8.13/§11.2 C8/§12, catalog §15).
> Change-control: conforms to [`catalog.md`](catalog.md); an edit
> that changes a definition or law must update catalog.md and every citing section in the same commit.
> Support document for [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md)
> (the hub). Siblings: [`pan_execution_model.md`](pan_execution_model.md) ·
> [`pan_memory_model.md`](pan_memory_model.md) ·
> [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md) ·
> [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md).
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).
>
> Scope: the bridge into the category-theory `specifications/` phase, the block/library catalog
> (what is core vs layered), open questions, and the de-risking prototype plan with success criteria.

---

## 1. Bridge to the categorical `specifications/`

The brief mandates category-theory specs as the single source of truth. The architecture maps to
real mathematical content (each mapping is a concrete, testable code obligation, not decoration):

| Architecture concept | Categorical formalisation | Proof / code obligation |
|---|---|---|
| Typed sample-streams | **Objects** of a category, indexed by `Format = (rate × T × channels × N × elem × out_per_in)` (the product object of [`pan_type_and_numeric_model.md` §2](pan_type_and_numeric_model.md)). | Format negotiation = constraint/unification over the product. |
| `Map` block (rate-1:1) | **Morphism** preserving the rate index; composites = composition; the flowgraph = a finite diagram; flattening = its normal form. | `out.len == in.len`; **≈ tested** (empirical) under both push and pull mux — a check, not a proof. |
| `Rate` block | **Rate-changing morphism** carrying an explicit `out_per_in` and a latency obligation. The push↔pull schedulers are **two functorial interpretations** of the block functor; the rate-elastic adapter is where that natural transformation is **non-trivial**. | `PullTestSampleMux` vs `TestSampleMux` **≈ agree** modulo declared latency (empirical check, not a proof). |
| `SampleMux` vtable | **Representable probe / Yoneda embedding** — a block is determined by its action on the buffers a mux presents. `TestSampleMux` *defines* behavior; real muxes *execute* it. | This is a **load-bearing test strategy**, not a constructed natural-isomorphism proof: the representable reading determines **what to test** (the dual mux family = push + pull) and **why testing each block under that family suffices**. The probe is the justification for "tests as definition" (Rule 14; [`catalog.md` §4.2](catalog.md)). |
| Feedback / `z⁻¹` | **Trace / fixpoint** in a traced monoidal category, well-defined only with the delay guaranteeing causality. | SCC-has-a-delay law → `error.DelayFreeLoop`: genuinely **PROVEN** (a decidable commit check) ([`catalog.md` §5.2](catalog.md)). |
| Liveness/coloring | **Interference-graph coloring** (per-element-class, interval-optimal). | The interval-coloring **OPTIMALITY is a proven theorem** ([`catalog.md` §7.2](catalog.md)); the implementation's **faithfulness** to it is the **PRIMARY CORRECTNESS CHECK** via the **B≡C differential test** (colored ≡ uncolored output) — **empirical evidence, NOT a proof** ([`catalog.md` §7.5](catalog.md)). |
| `ChannelMap(Sub, C)` | A **functor** `C^(·)` (the C-fold product) on subgraphs. | Replicated subgraph; pool sizes scale by C. Functoriality is an **obligation (≈ tested)** — framing / design vocabulary, not a constructed proof ([`catalog.md` §4.4](catalog.md)). |
| `Concat`/`Vectorize` fan-in | A **named (labelled) product** — a *limit* whose projections are **named** (a record, not an ordered tuple): the comptime spec is a struct-of-(name → element-type), and the product object's field order is the canonical column order. | Heterogeneous typed inputs wired by name via typed `PortId`s (verified expressible); output-struct field order pins the feature-matrix layout. |
| Parameter (control) port | A **control-rate side input** — the in-graph analogue of `set`; a port *kind*, not a third morphism class. The same control element (`Scalar`/`FeatureFrame`) on a control-rate edge consumed as a coefficient. | `node.param.<name>` minted at comptime; exempt from M1; one-source `set`/`schedule`-xor-edge (⊢); ramp/hold coercion (≈); SCC-has-delay applies (⊢). Port-kind machinery core, modulation blocks library ([`catalog.md` §2.4](catalog.md)). |
| Analysis pull roots | Additional clock-driven demand sources (**"terminal objects"** is **DECORATIVE NAMING only** — multiple clocked roots are not literally terminal objects; the engineering content stands). | Independent demand sources; non-RT root fed via SPSC tap ([exec §6](pan_execution_model.md); [`catalog.md` §8.3](catalog.md)). |
| Execution mode / Executor | The **Yoneda mode-invariance** made operational: the graph is one diagram; the **Executor** `(Schedule, Driver, MemoryPlan)` is a *choice of interpretation* (RealtimeStreaming Tier A/B ‖ OfflineBatch Tier C), not a graph property. | Blocks unchanged across modes; each executor discharges its mode's invariants (H1–H3 ‖ O1–O3); Tier B coloring stays interval-optimal on the schedule-time axis ([`catalog.md` §8.10–§8.11](catalog.md); [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md)). |
| `ChannelLayout` in `Frame(Lane, L)` | **Layout identity in the object** — `L : ChannelLayout` (count + positional tags + canonical channel order) is part of the `Format` index, so a layout mismatch is a typed equality failure on the object exactly as a channel-count mismatch is (it *generalises* the count check). Layout **geometry** (speaker azimuth/elevation, panning law, VBAP triangulation, ambisonic decode) is **block data**, never the stream type (mirrors `T`-in-type / behaviour-in-Numeric). | A wired layout mismatch is a **PROVEN** commit error (L1 ⊢, the count facet is A6, the identity facet A21); negotiation auto-inserts an up/down-mix matrix **only** for a *registered* layout pair, an unregistered pair is a hard mismatch (L2 ⊢, A22); the up/down-mix matrix **numerics are ≈ tested** (gold-vector, L3/B14); geometry correctness is an **authoring obligation** (▷, C14) ([`catalog.md` §1.3](catalog.md)). |
| `VariRate` block | A **bounded-interval rate morphism** — a `Rate` declaring `rate_bounds` (a `[min, nominal, max]` ratio interval) + `max_latency` instead of a point `out_per_in`, discriminated ⊢ by field presence. The pull contract is already rate-elastic, so the operational path is unchanged; only the static-planning quantities generalise from a point to an interval. | Field presence + worst-case static planning (size on `min`, PDC on `max_latency`) are **PROVEN/decidable** (V1/V2 ⊢, A23; single interval per block V5/A24); the block honouring the bound and its numerics are **≈ tested** (latency-contract, V1/B15); the determinism split is **honest** — parameter-driven ratio is O3-reproducible, controller-driven is ≈-only (V4/B16), with controller stability + ratio-held-per-call an authoring obligation (▷, V3/C15) ([`catalog.md` §2.6](catalog.md)). |
| Source / generator (zero sample-input) | A **`Map` or `Rate` whose `in` side is empty** — not a new morphism class. A **pure generator** (osc/noise/wavetable/constant) is a `Map` whose `out.len` is set by the pull demand `N` (SR1); a **stream/sample source** is a `Rate`/`VariRate` over a backing store (SR2); every non-feedback path is **source-rooted** (SR3). | The zero-sample-input classifier (length from the pull, not from `in.len`) is **PROVEN/decidable** (SR1 ⊢, A25); source-rootedness of every non-feedback path is a decidable graph check (SR3 ⊢, A26); sample-source field presence is ⊢ and its numerics ≈ (SR2); generator numerics (oscillator anti-aliasing vs a bandlimited oracle) are **≈ tested** (B17) and an **authoring obligation** (▷, C16) ([`catalog.md` §2.7](catalog.md)). |
| Typed event lane | **`EventLane(Event)`** — an event lane parallel to the sample lanes, parameterised by a comptime `Event` type the consuming block chooses (event-type-**generic**, exactly as ports are element-generic); time-sorted `(sample_offset, event)` driving the sub-block split. pan ships a blessed **`NoteEvent`** *library* union (pitch in Hz; note_on/off, pressure, MPE expression, CC, bend, program). | The sample-accurate sub-block split is **PROVEN** generic over any `Event` (the split keys only on `sample_offset`, EV1 ⊢, A27); onset accuracy is ⊢ mechanism / ≈ response (EV3); `note_id`→MPE voice routing is **▷/≈** (EV2). The lane mechanism is **core**; `NoteEvent` and note#→Hz tuning are **library** ([`catalog.md` §8.6](catalog.md)). |
| `Voice` / `PolyVoice(Voice, Vmax)` | **Intra-block, fixed-capacity polyphony** — a `Voice` is a **composite block** (a flattened `osc→env→filter→VCA` subgraph); `PolyVoice` is the **`ChannelMap` functor applied over *voices*** (a `VoiceMap(Voice, Vmax)`) + a note→slot allocator (steal oldest/quietest) + a summing mixer. Two realisations: a fused block that **internally skips** inactive voices (loop, not graph-op skip) **xor** replicated voice-nodes that all run. **No dynamic graph nodes.** | One static op, `Vmax`-comptime-bounded footprint, no dynamic node / no conditional graph op are **PROVEN** (Y1/Y4 ⊢, A28, by the C2 static-op-list); sample-accurate onsets are ⊢ mechanism / ≈ response (Y2); voice-stealing & MPE routing are **≈ tested** (B18) and voice-stealing/click-free-release/tuning are **authoring obligations** (▷, Y3/C17/C18) ([`catalog.md` §8.12](catalog.md)). |
| Analyzer / Instrument graph shapes | The **Yoneda mode-invariance read across *direction***: the core renders the same diagram whether a stream originates at a mic/file or an oscillator and terminates at a feature collector or a loudspeaker. **Analyzer** (analysis root, device/file source, `FeatureCollectorSink`) and **Instrument** (audio-device RT root, generators + MIDI/event source, device sink) are the two canonical applications of one purpose-agnostic core (C8). | **Framing, not theorem** (▷; Rule 7, §0.3) — it names the two uses the one core serves, constructing no proof; it composes from the load-bearing rows above (`ChannelLayout`, `VariRate`, Source, event lane, `PolyVoice`) and is orthogonal to the execution modes (an Instrument streams live or bounces O3-reproducibly) ([`catalog.md` §8.13](catalog.md), §11.2 C8). |

[`catalog.md`](catalog.md) DEFINES: the object category and its `Format` index; the two
morphism classes; the Yoneda/`SampleMux` probe; the traced-monoidal feedback law; the coloring
correctness obligation; and the converter-insertion ("make the diagram commute") rule. Defined terms
resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).

---

## 2. Block taxonomy & library combinators (core vs layered)

> **Map-vs-Rate decision rule (tutorial-grade — the load-bearing onboarding surface).** Newcomers
> repeatedly reach for *"a `Map` with state"*; the rule that resolves it:
> - **`Map`** if `out.len` is **always** `in.len` and your output depends only on the current input
>   slice. **Per-sample IIR/biquad state is still a `Map`** (rate-1:1) — having state does not make a
>   block a `Rate`.
> - **`Rate`** if you **accumulate across calls**, emit a **different number** of samples than you
>   consume, or **buffer until you have enough**. A ring / overlap buffer is the `Rate` smell.
>
> **Worked distinction — biquad vs `Framer`.** A **biquad** carries `z⁻¹` state but it is *per-sample*
> and rate-1:1 → **`Map`**. A **`Framer`** buffers `FRAME` samples and emits one window every `HOP`:
> cross-call accumulation + a different out-vs-in count + buffer-until-enough → **`Rate`**. The type
> system cannot auto-detect the "`Map` with a hidden accumulator" mistake (a `Map` is *allowed*
> per-sample state), so this rule ships as a tutorial chapter alongside the existing build error. See
> [`pan_execution_model.md` §2.3](pan_execution_model.md).

**Core primitives** (frozen — needed for H1–H3): `UnitDelay(z⁻¹)` / `DelayLine(len)` (feedback &
PDC), `Framer(N, H, window)` (the shared STFT ring — resolves audit S2 so no spectral author
re-implements it), and the LPCM boundary codecs.

**Layered library blocks** (build on the core; ship incrementally):
- **I/O:** LPCM stream source/sink, device source/sink (per I/O HAL), file render sink,
  **off-thread prefetch source**, **`FeatureCollectorSink`** (drains per-hop frames off-RT into a
  growable time-series — the `examples/` viz pipeline, resolves audit S8). **Growth policy:**
  `capacity_hint` **pre-reserves** that many rows at `initialize` (one up-front allocation); growth
  past the hint is **geometric (×2)** via the unmanaged `std.ArrayList` per-call allocator —
  **explicitly allowed because this sink lives only on a non-RT pull root** (it can never sit on the
  audio deadline; cross-root hand-off is SPSC-tap only, [exec §6](pan_execution_model.md)). This is
  the one blessed place a `realloc` may happen — the contained H1 exception — and a
  `FeatureCollectorSink` wired onto an RT (audio) root is a **commit error**. *Illustrative — Zig
  0.16:*
  ```zig
  rows: std.ArrayList(Row) = .empty,
  pub fn initialize(self: *Self, a: std.mem.Allocator) !void {
      try self.rows.ensureTotalCapacity(a, self.capacity_hint); // one up-front reservation
  }
  pub fn push(self: *Self, a: std.mem.Allocator, row: Row) !void {
      try self.rows.append(a, row); // geometric growth past the hint — legal: non-RT root
  }
  ```
- **Gain/dynamics:** gain, trim, VCA, compressor/limiter/expander/gate, soft-clip/waveshaper.
- **Filters:** biquad (comptime order, runtime coefficients), state-variable, FIR (reuse `firwin*`),
  IIR (feedback).
- **Spatial — the "pan" core:** constant-power panner, balance, width, upmix/downmix matrix, VBAP,
  ambisonic encode/decode. These are **layout-aware** — they consume/produce `Frame(Lane, L)` on
  explicit layouts `L` (catalog §1.3), so a layout mismatch is a typed commit error and their geometry
  (speaker positions, panning law, decode coefficients) is block data, not the stream type.
- **Time/feedback:** delay, comb/all-pass, reverb (FDN), chorus/flanger. **Tight (sample-accurate)
  feedback primitives — ladder / Karplus-Strong / comb — ship as fused single-block `Map` kernels**
  (the per-sample feedback loop runs inside one rate-1:1 `Map`'s `process` over fixed persistent
  state, trading scheduler-visibility for sample-accuracy; distinct from the one-block-latency
  graph-level `DelayLine`-in-a-cycle idiom, and typically **not** `aliasing_safe`). The block-size-1
  *subgraph* combinator is **deferred** as a layered library subject to a real use case (Rule 2). See
  [`pan_memory_model.md` §6.1](pan_memory_model.md).
- **Spectral (`Rate`):** STFT/iSTFT, partitioned-convolution reverb, spectral gate/EQ — primary FFT-
  HAL consumers.
- **Rate (`Rate`):** decimator/interpolator, rational/arbitrary resampler, **adaptive drift-ASRC**.
  Multi-rate filterbanks (DWT octave trees, CQT) are **not** single `Rate` blocks (`out_per_in` is
  single-rate, catalog §2.2 R5) — they are a **cascade/bank of uniform-rate `Rate` stages**. The
  runtime-ratio family — **adaptive drift-ASRC, varispeed/scrub, runtime-stretch TSM/phase-vocoder, and
  pitch-shift (TSM ∘ resample)** — are **`VariRate`** (bounded `rate_bounds` + `max_latency`, catalog
  §2.6); a *fixed* stretch/resample factor needs none of this and stays an ordinary fixed-`out_per_in`
  cascade.
- **Mix/routing:** summing mixer, splitter/fan-out, matrix router, dry/wet (with PDC).
- **Sources (zero sample-input, catalog §2.7):** oscillators, noise, wavetable, constant are
  **zero-sample-input `Map` generators** (`out.len` set by the pull demand `N`, SR1); sampler / file
  source is a **`Rate`** (or **`VariRate`** when played at arbitrary pitch, SR2) over a backing store /
  prefetch FIFO. Both are driven only by parameter ports and the event lane.
- **Polyphony — `PolyVoice` (the blessed pattern, catalog §8.12):** the blessed way to do
  dynamic-cardinality polyphony **without** a dynamic graph. A `Voice` is a **composite block**
  (`osc→env→filter→VCA`); **`PolyVoice(Voice, Vmax)`** packages a fixed `Vmax` voice pool + a note→slot
  allocator + a summing mixer into **one static op** (Y1) — **no dynamic nodes** (Y4); the fused
  realisation **internally skips** inactive voices (catalog §8.9 intact).
- **Modulation / control (parameter-port consumers & producers):** LFOs, envelope generators, and
  feature→param maps that drive another node's coefficient via a **parameter edge** (catalog §2.4).
  Adaptive processors (AEC, AGC, noise tracking, feedback/howl suppression) may either **fuse** the
  controller + applied filter into one block (as before) **or** expose the coefficient as a parameter
  port driven by a separate controller node — both are now first-class. *Conditional/gated* execution
  is **not** offered; gating is **data-gating** (a `Scalar` gate the consumer applies — catalog §8.9).
- **Analysis (taps, non-RT root):** RMS/peak meter, FFT analyzer, the MFCC/perceptual-sparse/onset/
  dominant-band feature chains from `research/`, pitch/onset.

**Combinators** (comptime composite-builders, resolve audit S4 / §3.2):
- **`ChannelMap(comptime Sub: type, comptime C: usize) type`** — replicate a mono subgraph over C
  channels, stack outputs; coloring/negotiation replication-aware (M scales by C). **`VoiceMap(Voice,
  Vmax)` is the *same* `ChannelMap` functor applied over *voices*** (replication count `Vmax`) — the
  structural core of `PolyVoice` (allocator + summing mix layered on top, catalog §8.12).
- **`Vectorize`/`Concat`** — `Concat(comptime spec)` where `spec` is a **struct-of-(name →
  element-type)** (e.g. `.{ .mfcc = pan.FeatureFrame(13), .rms = pan.Scalar(f32) }`); inputs are
  wired **by name** (`node.in.<name>`) through the typed `PortId`s minted from the spec, and the
  output struct's **field order is the canonical feature-matrix column order** (no parallel
  positional list to keep in sync; wrong name or element type is a compile error). See
  [`pan_type_and_numeric_model.md` §1](pan_type_and_numeric_model.md).

**Fusion policy (audit S5, decided in [`pan_memory_model.md` §5](pan_memory_model.md)):** clean
dataflow is the semantic model; ship graph-of-nodes (desktop) + hand-fused multi-reduction composites
(embedded) now; defer the automatic comptime loop-fusion pass as a measured optimization.

---

## 3. Testing methodology (keep + extend) and the Yoneda gates

**Keep** the SciPy/NumPy gold-vector oracle (`generate.py` → `vectors/` → `GoldVectorTester`, pinned
in [`pan_testing_and_vector_contract.md`](pan_testing_and_vector_contract.md)) — it tests
intent against an independent mathematical truth (Rule 9). **Extend** with:
- **Dual-mux testing** — every block under push *and* pull (`PullTestSampleMux`); catches surface
  leaks at the `Map`/`Rate` seam.
- **B≡C differential tests** — per-edge vs colored pool produce bit-identical output (the PRIMARY
  correctness check for the colorer implementation; empirical evidence — [`catalog.md` §7.5](catalog.md)).
- **Aliasing tests** — in-place vs non-aliased mux.
- **Latency-contract tests** — a `Rate` block's declared `algorithmic_latency`/`out_per_in` is real.
- **State-granularity test** — history updates once per hop regardless of sub-block count (audit S6).
- **xrun/deadline-miss counters** as a first-class test signal.

- **Embedded comptime-commit smoke gate** — `commitComptime()` is evaluated inside a `comptime`
  block in a `ReleaseSmall` embedded build; the build **compiling is the DISCHARGE of the obligation
  FOR THE SMOKE GRAPH** (not a proof for arbitrary graphs), and failing to compile is the loud failure
  ([`catalog.md` §8.5](catalog.md)). Promotes the hub's "commit must be comptime-evaluable" mandate to
  a correctness obligation, discharged by this gate ([hub §5 item 6 / §7](pan_architecture_formalisation.md)).

**Dispatch Yoneda test writers (Rule 14) at each gate**, instructing them to load the `zig-0-16`
skill (Rule 13). Highest-value gates: the liveness/coloring allocator, the `aliasing_safe` legality
check, the feedback-SCC validator, the format-negotiation pass, the `PullSampleMux`, the `Framer`,
and the embedded comptime-commit smoke gate. Give them the *code section to test*, not the tests to
write.

---

## 4. Open questions — RESOLVED (locked 2026-06-02)

1. **Internal canonical type:** LOCKED — **f32-internal default, per-block opt-in** (typed feature
   ports layered on top; not genuinely per-block precision in negotiation) ([`catalog.md` §9.3](catalog.md);
   [`pan_type_and_numeric_model.md` §4](pan_type_and_numeric_model.md)).
2. **Planar vs interleaved internal form:** LOCKED — **PLANAR** (SIMD-friendly; conversion confined to
   the I/O boundary) ([`catalog.md` §9.3](catalog.md)).
3. **Feature/control rate clocking vs device N (H ∤ N):** LOCKED — the **`Rate`/`Framer` ring absorbs
   it** (T4); the alignment story holds end-to-end ([`catalog.md` §9.3](catalog.md)).
4. **Heterogeneous-count coloring within a class:** LOCKED — **brute-force/FFD at M≤8 is
   optimal-enough** ([`catalog.md` §7.2](catalog.md)).
5. **`Bounded(T,Kmax)` liveness:** LOCKED — storage is static so colorable; the **consumer-respects-
   `len` contract suffices** ([`catalog.md` §1.3](catalog.md)).
6. **Embedded MCU class:** LOCKED — **target-generic / deferred**; the SRAM budget is a **build
   constant**; **q15 fixed-point is the first-class default**, f32 conditional; a **freestanding stub**
   serves the smoke gate ([`catalog.md` §9.3](catalog.md)).
7. **Algorithm-coverage gaps (assessment §4):** RESOLVED — locked 2026-06-03 (catalog §15). §4.A/§4.D-
   param → **parameter ports** (catalog §2.4); §4.B → `out_per_in` single-rate, filterbanks decompose
   (R5); §4.C → **data-gating only**, conditional execution out of scope (catalog §8.9); §4.D-sample →
   multi-input pull rule (catalog §8.8); §4.E → element-generic `UnitDelay`/FDN (catalog §5.5). See
   [`../notes/pan_spec_algorithm_coverage_assessment.md`](../notes/pan_spec_algorithm_coverage_assessment.md).
8. **Multicore RT (heavy graph > 1 core) & offline batch throughput:** RESOLVED — COMMITTED (phased)
   2026-06-03 (catalog §15). Two execution modes (catalog §8.10): **RealtimeStreaming** Tier B (HEFT +
   point-to-point + audio workgroup + concurrency-aware coloring, cost-gated, auto-demote) and
   **OfflineBatch** Tier C (pipeline parallelism + data-parallel chunking via `warmup_samples`).
   Determinism: Tier B bit-exact to Tier A; offline bit-reproducible (O3). Full design:
   [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md).

---

## 5. Prototype plan (de-risk the most-uncertain pieces first)

Ordered so each step proves a load-bearing claim before the next depends on it. Each has a **success
criterion** (Rule 4) strong enough to loop on independently.

| # | Prototype | Proves | Success criterion |
|---|---|---|---|
| 1 | **Vertical slice:** CoreAudio sink + LPCM source + a 3-block pure `Map` chain (gain → biquad → pan) on **Tier A + pool mode B**. | The `PullSampleMux` + the callback render path. | Sub-5 ms measured round-trip on M3; zero xruns over 10 min; output **matches the SciPy oracle within the declared tolerance** (bit-exact for fixed-point) — see [`pan_testing_and_vector_contract.md`](pan_testing_and_vector_contract.md). |
| 2 | **Format negotiation** (rate/precision/channels/N) + **lock-free control plane** with one ramped parameter. | Negotiation/coercion insertion + RT-safe parameter update. | A wired rate-mismatch auto-inserts a resampler; a parameter sweep is zipper-free; no audio-thread lock. |
| 3 | **Feedback primitive** (delay → comb reverb). | The `z⁻¹` split, SCC-has-delay validator, persistent buffers. | A delay-free loop is rejected at commit (`error.DelayFreeLoop`); the reverb tail is stable; denormals don't spike CPU (FTZ set). |
| 4 | **Pool mode C (coloring)** behind the same `getBuffer` interface; **B≡C differential test**. | The colorer is correct and a drop-in optimization. | C output is bit-identical to B across the corpus; pool size = max-live-edges; paranoid mode finds no aliasing. |
| 5 | **A `Rate` block** (`Framer`+STFT or a polyphase resampler) + **latency accounting / PDC**. | The dual contract, `out_per_in` ≠ latency, dual-mux + latency-contract tests. | A dry/wet diamond around the FFT path re-aligns sample-accurately; the block passes both muxes. |
| 6 | **Analysis pull root** (file → MFCC/perceptual-sparse → `FeatureCollectorSink`) feeding the [`1.md`](../notes/1.md) viz. | Clock-driven roots (C5), typed feature ports, off-RT collection. | Per-hop feature matrix collected with no effect on a concurrent audio root's deadline. |
| 6b | **Embedded comptime-commit smoke gate:** call `commitComptime()` inside a `comptime` block in a `ReleaseSmall` embedded build on a minimal graph (I2S source → gain → I2S sink). | That the commit/coloring pass is genuinely comptime-evaluable end-to-end — the embedded "same code, specialized not forked" claim ([hub §7](pan_architecture_formalisation.md)). | The smoke graph **compiles** (compiling discharges the obligation **for the smoke graph** — not a proof for arbitrary graphs; [`catalog.md` §8.5](catalog.md)); `footprint_bytes` is a comptime constant. (Target may be stubbed `freestanding` until the SRAM-budget target is chosen, §4 item 6.) |
| 6c | **Parameter ports / modulation** (catalog §2.4): wire a control-rate producer (LFO or a feature node) into a filter's `param.cutoff`; one-source `set`-xor-edge enforcement; ramp/hold coercion. | The control-port kind, the in-graph `set` analogue, and that decoupled modulation needs no third morphism class. | An LFO→cutoff sweep is zipper-free and matches the same sweep via `set`; wiring a param edge **and** calling `set` on the same slot is a commit error; a delay-free param loop is rejected (`error.DelayFreeLoop`). |
| 6d | **Instrument vertical slice** (the synthesis mirror of step 6): `MIDI/event source → PolyVoice(osc → ADSR → ladder, Vmax) → pan(layout) → device sink` on **Tier A + RealtimeStreaming**. | The **Source** zero-sample-input contract (SR1, the generator at the root), the **typed event lane** (`EventLane(NoteEvent)`, sample-accurate dispatch), the fixed-`Vmax` **voice pool** + allocator (`PolyVoice`, one static op), **layout-typed** `Frame(Lane, L)` output through the panner, and **sample-accurate note onsets** — i.e. the **Instrument** graph shape (C8) end-to-end. | A held-then-released MIDI chord renders the expected `Vmax`-bounded polyphony with **zero xruns over 10 min** and no audio-thread malloc/lock (H1); each **note onset lands on its sample-accurate offset** (verified against an offset-tagged oracle — the sub-block split, EV3/Y2); **voice-stealing past `Vmax` is click-free** (gold-vector/behavioural, Y3); the panner output **carries the declared layout `L`** and a wired layout mismatch is a commit error (L1); the generator (osc) numerics **match a bandlimited oracle within tolerance** (B17); footprint is a `Vmax`-comptime constant (H2). |
| 7 | *(superseded — now COMMITTED & expanded into steps 8–12)* Offline **Tier C** push path + **Tier B** parallel RT. | The reused-block claim for offline; the parallel RT tier. | See steps 8–12 in [`pan_parallel_and_offline_execution.md` §6](pan_parallel_and_offline_execution.md). |

> **Steps 8–12 (COMMITTED 2026-06-03)** detail the two execution modes — OfflineBatch pipeline (8),
> data-parallel chunking + `warmup_samples` (9), render-workgroup HAL (10), Tier-B level-barrier
> fallback (11), and Tier-B HEFT + point-to-point default (12) — with success criteria, in
> [`pan_parallel_and_offline_execution.md` §6](pan_parallel_and_offline_execution.md).

---

## 6. Risk register (carried, all mitigated by *making assumptions explicit and loudly tested*)

| Risk | Mitigation |
|---|---|
| Surface leak at the `Map`/`Rate` seam | Two explicit contracts (C1) + dual-mux testing (every block under push & pull). |
| Aliasing bugs from in-place coloring | Explicit `aliasing_safe`, paranoid mode (NaN-poison released buffers), B≡C differential tests (whose failure message quotes the `aliasing_safe` assertion back). |
| Monomorph-set creep on desktop (now **layout × precision**, since `L` joins `T` in the type) | Bounded explicit comptime active-list — the cross-product of the registered active **layouts** × active **precisions**; log the generated-monomorph count at build (Rule 12). |
| Dynamic edit vs static coloring | Off-thread recompile + atomic-RCU plan swap; pre-allocate to max-M; no runtime epochs on embedded (T3). |
| Heterogeneous-size coloring NP-hardness | Per-element-class pools → k independent optimal interval colorings (C3). |
| Tier-B nondeterminism on M3 P/E clusters | **Resolved (COMMITTED 2026-06-03):** workers join the OS **audio workgroup** (`os_workgroup`) → co-scheduled, no mid-render descheduling → the cross-worker spin is bounded; static HEFT schedule keeps coloring an interval graph and output **bit-identical to Tier A**; the cost-gate enables B only when work/span + headroom justify it, and **auto-demote** falls back to Tier A under low headroom. Tier A remains the frozen ground truth. ([`pan_parallel_and_offline_execution.md` §2/§4](pan_parallel_and_offline_execution.md).) |
| Workgroup not honoured / Tier-B spin unbounded on an OS that ignores co-scheduling | Cost-gate refuses Tier B when no workgroup; per-worker spin-time telemetry trips **auto-demote to Tier A** (the worst observed outcome is "runs as Tier A," never an xrun); ▷/≈ honesty bound documented (C12). |
| Offline parallel output not reproducible (thread-order-dependent) | Ordered timeline merge + fixed per-op reduction order (O3); `warmup_samples` exactness class (bit-exact FIR/STFT, allclose IIR); offline differential test `K=1`≡`K=ncores` (B10). |
| Clock drift after 20 min | Adaptive ASRC + drift FIFO at the device boundary (§1 of the I/O doc), bypassed on single full-duplex clock. |
| Denormal CPU spikes / NaN poisoning | FTZ/DAZ set *on the audio thread* (ARM64 FPCR per-thread footgun); NaN guards + error isolation. |
| Synth voice-count CPU cost (every sounding voice is a full `osc→env→filter→VCA` chain) | **Fused `PolyVoice` internal skip** — the block runs a `for active_voices` loop so only *sounding* voices cost CPU, keeping the static op-list intact (catalog §8.9/§8.12 Y1); `Vmax` comptime bounds the worst case (H2). |
| Oscillator aliasing (naive generators alias at high pitch) | Gold-vector test **vs a bandlimited oracle** (B17); anti-aliasing is an explicit **authoring obligation** (▷, C16) surfaced to block authors, not silently assumed. |
| `VariRate` controller-driven ratio is non-reproducible | **Honest determinism split (V4):** a controller-driven ratio (drift PI on a wall-clock FIFO) is **≈-only** — the same class as clock drift, not a defect; a **parameter-driven** ratio (deterministic automation) is **O3-reproducible**. The class is documented and tested (B16), never papered over. |

---

## 7. One-line takeaway

pan is a **purpose-agnostic real-time audio DSP graph engine** — one core (typed-stream objects,
`Map`/`Rate` morphisms, the SampleMux/Yoneda probe, colored pools, clock-driven pull roots) serving
two canonical graph shapes from the *same* diagram: an **Analyzer** (feature extraction) and an
**Instrument** (synthesis), distinguished only by direction (C8, catalog §8.13). The architecture is
**B+ → A− once five things are committed**: the `Map`/`Rate` dual contract, per-element-class colored
pools, the Numeric trait, clock-driven pull roots, and the compile-once/replay render op-list — at
which point the categorical spec has honest mathematical content, the embedded build is a pure
comptime specialization, both shapes (Analyzer + Instrument) fall out of the one mode-invariant core,
and the de-risking order above can proceed with strong, loopable success criteria.
