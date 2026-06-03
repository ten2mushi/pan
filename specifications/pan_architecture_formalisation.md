# pan — Architecture Formalisation (scope-narrowing for the spec phase)

> **Status: LOCKED** (2026-06-02; **amended 2026-06-03** — C1 gains *parameter ports* (catalog §2.4);
> **then commitments C6/C7 added** (two execution modes + static-parallel RT executor) and invariants
> H1–H3 paired with offline O1–O3 — scheduler Tiers B/C COMMITTED (phased); see
> [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md), catalog §15 change
> log). This is the **hub** document. It commits the
> decisions that the category-theory `specifications/` will formalise as the single source of
> truth. Where the earlier ideation left options open, this document *picks one and says why*
> (CLAUDE.md Rule 7). Change-control: this hub conforms to [`catalog.md`](catalog.md), the single
> source of truth; definition/law edits propagate there in the same commit.
>
> **Supersedes the open parts of** [`architecture_ideation.md`](../notes/architecture_ideation.md) and
> [`architecture_audit_feature_extraction.md`](../notes/architecture_audit_feature_extraction.md), and
> folds in [`end_to_end_pipeline_requirements.md`](../notes/end_to_end_pipeline_requirements.md).
>
> **Grounded by:** (1) the **actual ZigRadio source** at
> `/Users/komorebi/Documents/projects/tools/rf/zigradio/` (verified — see §2); (2) a SOTA survey
> of JUCE / Web Audio / GNU Radio / SOUL·Cmajor / Faust / CLAP·VST3 / Bela·Teensy·CMSIS-DSP;
> (3) a systems-design stress-test of the three core decisions; (4) the `zig-0-16` skill.
>
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).
>
> **Companion documents (read in this order):**
> 0. [`catalog.md`](catalog.md) — the single source of truth: objects, morphisms, laws, tiers,
>    glossary (read before everything).
> 1. [`pan_execution_model.md`](pan_execution_model.md) — the `Map`/`Rate` contracts, the pull
>    scheduler, the render op-list, clock-driven pull roots, scheduler tiers.
> 2. [`pan_memory_model.md`](pan_memory_model.md) — per-element-class colored buffer pools,
>    liveness, in-place, feedback/persistent state, PDC.
> 3. [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md) — typed ports, the Numeric
>    trait, the precision/N/W asymmetry, format negotiation.
> 4. [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md) — I/O HAL, clock-domain
>    drift / ASRC, off-thread prefetch, denormals/NaN/dither, click-free transitions, device
>    reconfiguration, observability, transport.
> 5. [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md) — mapping to
>    the categorical spec, block taxonomy & combinators, open questions, prototype plan, success
>    criteria.
>
> **Implementation specs (LOCKED — the sprint-zero layer that pins the above to code):**
> - [`pan_concurrency_and_memory_ordering.md`](pan_concurrency_and_memory_ordering.md) — the
>   lock-free control plane at exact Zig 0.16 atomic-ordering precision (SPSC ring, atomic scalars,
>   RCU plan swap, the H1 wait-freedom argument).
> - [`pan_commit_pass_algorithms.md`](pan_commit_pass_algorithms.md) — the graph-commit pass to
>   pseudocode precision (topo / liveness / interval-coloring / SCC-has-delay / PDC) with worked
>   examples and footprint arithmetic.
> - [`pan_testing_and_vector_contract.md`](pan_testing_and_vector_contract.md) — the gold-vector
>   contract, tolerance policy, the dual-mux / B≡C / latency-contract harnesses, and the Yoneda
>   test-writer plug-in contract.
>
> Full index and reading order: [`SPEC_INDEX.md`](SPEC_INDEX.md).

---

## 0. Thesis (one paragraph)

pan **requires** three load-bearing properties — a comptime *type-signature-is-the-API* block
surface, a `SampleMux` vtable seam, and an external-oracle gold-vector testing discipline — and
**replaces the execution and transport layer** of any prior-art design with a latency-domain design
built for the hard real-time audio callback. ZigRadio is cited throughout as a **feasibility
witness** that these three properties are buildable in Zig, *not* as the definition of them. The replacement rests on five orthogonal commitments: (1) **two block
contracts**, `Map` (rate-1:1) and `Rate` (rate-elastic), not one leaky "unified surface";
(2) a **synchronous pull scheduler** that compiles the DAG once into a flat render op-list and
replays it inside the audio callback, wait-free; (3) a **per-element-class colored buffer pool**
sized at graph-commit, zero hot-path allocation; (4) **precision (`T`) comptime, block-size (`N`)
runtime, SIMD-width (`W`) comptime-per-target**, with a Numeric trait carrying accumulator and
saturation policy; (5) **clock-driven pull roots** so audio output and analysis sinks are
independent demand sources — plus two **committed-mode** commitments added 2026-06-03: (6) **two
execution modes** (RealtimeStreaming / OfflineBatch) over the mode-invariant graph, and (7) a
**static-parallel RT executor** (Tier B) for heavy graphs exceeding one core (§3 C6/C7). The embedded
profile is then a *strict comptime specialization* of the desktop core — every runtime degree of
freedom collapses to comptime or vanishes on an MCU (Tiers B/C simply do not exist there) — which
is the strongest evidence the core is factored correctly.

---

## 1. The invariants the core exists to guarantee

Everything below is judged against three hard invariants. They are *theorems forced by the audio
callback contract*, not preferences. (Detail and the latency-budget arithmetic:
[`pan_execution_model.md` §1](pan_execution_model.md).)

- **H1 — No unbounded blocking on the audio thread.** For the full duration of one callback the
  render path must be wait-free: no lock a non-RT thread can hold, no condvar, no `malloc`/`free`,
  no syscall, no page fault. ZigRadio's *entire* wakeup model (condvar rings, writer parks when
  full, mutex control plane) is categorically disallowed on this path.
- **H2 — Bounded, statically-known render memory.** All per-callback working memory is allocated
  once at graph-commit and never touched on the hot path. Forced independently by embedded
  (no heap) and by H1 (allocation can block / fault).
- **H3 — Port/graph correctness provable at comptime.** Mis-wiring (type, channel, rate mismatch)
  is a compile-time or commit-time error, never a runtime crash. This is the one inherited asset
  that pays for itself immediately.

> **H1–H3 are the *RealtimeStreaming* invariants.** The **OfflineBatch** mode (Tier C, C6) runs under
> a distinct, relaxed set **O1–O3** (blocking-legal / pre-sized bounded footprint / bit-reproducibility)
> — see [`catalog.md` §11.1b](catalog.md). Tier B (C7) discharges H1–H3, with H1's wait-freedom
> carrying a workgroup-conditional ▷/≈ bound on its bounded cross-worker spin (never weakening Tier A's
> structural ⊢).

> **Litmus test for "is it core?"** *A concept is core iff it must hold at comptime/commit for the
> render path to stay wait-free (H1), statically-bounded (H2), and type-correct (H3).* Anything
> expressible as "just another block + a `SampleMux` client + a HAL call" is a **layered library**,
> not core. This single test drives the split in §5.

---

## 2. What pan requires of the block/transport surface (ZigRadio witnesses feasibility)

These are pan's **obligations** on the block/transport surface, not behaviours inherited from prior
art. The actual ZigRadio tree (`src/core/{block,types,sample_mux}.zig`) is cited only as
**feasibility evidence** that each obligation is satisfiable in Zig. The one open feasibility
question that blocked the spec ("can the port machinery carry non-audio types and multiple typed
inputs?") is **answered yes** by that witness.

| Required property | Feasibility evidence (file) | Consequence for pan |
|---|---|---|
| **Type signature is the API** | `ComptimeTypeSignature.init` reads `@typeInfo(process).fn.params[1..]`, takes `.pointer.is_const` (input vs output) and `.pointer.child` (element type). `types.zig:11-37`. | pan **requires** this surface. Element type is *any* type, see next row. |
| **Arbitrary port element types** | Element type is just `.pointer.child`; `Complex(f32)` and user structs with a `typeName()` getter work (`types.zig:52-72`, `add.zig:38`). | **Unblocks typed ports** (spectra, feature frames). *Caveat:* a bare array element `[40]f32` has no `typeName()` → wrap as a named `FeatureFrame(K)` struct. A convention, not a barrier. See [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md). |
| **Multiple heterogeneous inputs** | `process(self, a:[]const u32, b:[]const u8, out:[]u32)` compiles; ports fixed `[8]` per direction (`block.zig:276-278`, `ProcessResult.[8]usize`). No type erasure — typed slices reconstructed via `bytesAsSlice` (`sample_mux.zig:90`). | **Unblocks fan-in / `Concat` blocks.** 8-port ceiling kept, but **enforced at comptime via the port-index type** (a typed `PortId` per node, index type `u3` → range 0..7) with a readable `@compileError` if a `process`/`pull` signature or a `Concat` spec declares more than 8 ports per direction — the magic `[8]` becomes a named comptime invariant. `connect` takes typed `PortId`s (carrying node identity + direction + element type), so out-of-range/wrong-type connects are compile errors. See [`pan_execution_model.md` §8](pan_execution_model.md), [`pan_type_and_numeric_model.md` §1](pan_type_and_numeric_model.md). Revisit the ceiling only if a real graph needs more. |
| **`SampleMux` vtable** | Exactly 10 methods: `wait/get{Input,Output}Available`, `get{Input,Output}Buffer`, `update{Input,Output}Buffer`, `getNumReadersForOutput`, `setEOS` (`sample_mux.zig:14-29`). `get()` computes min-available N and hands back typed slices; `update()` commits consumed/produced. | **The seam.** A `PullSampleMux` implements the same 10 methods with pull semantics. See [`pan_execution_model.md` §3](pan_execution_model.md). |
| **No aliasing constraint in the wrapper** | `wrapProcessFunction` (`block.zig:60-78`) passes input+output slices straight through; nothing assumes they are disjoint. | **In-place coalescing is feasible without a wrapper change** — gated by an explicit `aliasing_safe` declaration. See [`pan_memory_model.md` §3](pan_memory_model.md). |
| **Independent consumed/produced counts** | `ProcessResult{ samples_consumed:[8]usize, samples_produced:[8]usize }` (`block.zig`). Downsampler consumes 100 / produces 25 (`downsampler.zig:45-56`). | Rate-elasticity is *expressible*; but `get()`'s min-available logic is a **push** contract — pull needs the `Rate` contract (§3, [`pan_execution_model.md` §2](pan_execution_model.md)). |
| **Front-loaded allocation, zero malloc in `process`** | `ProcessResult` is stack-only `[8]usize`; allocation in `initialize`. | Satisfies H2 already; pan **requires** the discipline and extends it to the pool. |
| **Gold-vector testing vs a NumPy/SciPy oracle** | `generate.py` → `vectors/` → `BlockTester`; `TestSampleMux` feeds exact bytes, asserts exact bytes. | pan **requires** this discipline; extend (dual-mux, B≡C differential, latency-contract). See [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md). |

**What we deliberately demote:** thread-per-block execution, the 8 MiB per-edge ring, condvar
wakeups, and the mutex control plane all move to the **offline-only** path (Tier C) or are dropped.
The double-mapped contiguous ring survives only as an offline buffer strategy.

---

## 3. The eight core commitments (decision record)

Each entry: the decision, what it changes versus the ideation, and where it is formalised.

### C1 — Two block contracts: `Map` and `Rate` (not one unified surface)
The ideation's "one authoring surface, two execution interpretations" **leaks at the rate-elastic
seam** and the feature corpus hits that seam pervasively (framing/STFT, decimation, resampling).
Be honest: there are **two morphism kinds**, discriminated at comptime.
- **`Map`** — rate-1:1, `out.len == in.len`, may change element type. Pure over its input slice.
  ~80 % of audio blocks (gain, EQ, pan, mix, waveshaper) and the type-changing feature maps
  (power, mel, log, DCT). Schedule-agnostic; colorable; sub-block-splittable for free.
- **`Rate`** — rate-elastic transducer: owns an internal clock/ring, may emit 0 or many outputs per
  call, declares an explicit **`out_per_in` rate ratio** *and* an **`algorithmic_latency`** (the two
  are distinct — latency ≠ decimation). Framer/STFT, decimator/interpolator, resampler (incl. the
  drift-ASRC), partitioned convolution. A `Rate` block that fails to declare its ratio/latency is a
  **build error** (Rule 12).
- **Parameter ports (control ports)** *(refinement, LOCKED 2026-06-03)* — a port **kind** orthogonal
  to the two morphism classes: a control-rate side input carrying `Scalar`/`FeatureFrame` (a node's
  coefficient), **exempt from the rate-1:1 law**, ramped/held like `set`, and the **in-graph analogue
  of `set`** (one source per slot — `set`/`schedule` xor a wired edge). It lifts the control-rate
  modulation ceiling (decoupled LFO/feature → filter; adaptive coefficients as a graph edge)
  **without** adding a third morphism class. The port-kind machinery is core; modulation blocks are
  library. Canonical: [`catalog.md` §2.4](catalog.md).
> **Why this is the keystone:** it resolves the audit's S2 and the systems-design "(a)" objection
> at once, and it makes the pull scheduler's recursion arithmetic correct. Formalised in
> [`pan_execution_model.md` §2](pan_execution_model.md).

### C2 — Synchronous pull scheduler, compiled to a flat render op-list
Render the whole DAG to completion inside the audio callback, on device-sized buffers, wait-free.
Following JUCE's `AudioProcessorGraph`: **compile topology → an ordered list of render ops once**
(on graph change, off-thread), then the callback just **replays the op-list** — no graph walking or
pointer chasing on the hot path. A `PullSampleMux` satisfies the inherited 10-method vtable;
`waitInputAvailable` returns immediately because the scheduler renders upstream first; `update` is a
no-op commit. **Tier A (single-thread pull) remains the entire frozen core** and the always-available
fallback. Tier B (static-parallel RT) and Tier C (offline threaded push) are now **COMMITTED (phased)
layered libraries** (§5; promoted 2026-06-03) under two dev-facing **execution modes** (C6) — they
reuse the same blocks via different muxes and each **discharges its mode's invariants** (RealtimeStreaming
⇒ H1–H3; OfflineBatch ⇒ O1–O3). Formalised in [`pan_execution_model.md` §3–§5](pan_execution_model.md)
and [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md).

### C3 — Per-element-class colored buffer pool
Per-callback execution of a known schedule = **register allocation**: edges=virtual registers,
buffers=physical registers, liveness=[producer … last consumer]. *Crucial refinement over the
ideation:* maintain **one pool per element-type-class** (audio `Sample(T)` frames, `Complex(T)`
spectra, `FeatureFrame(K)`, scalars). Within a class all buffers are the same size → **linear-scan
interval coloring is optimal and linear-time per class**; across classes there is no interference.
This converts the heterogeneous-size case (NP-hard dynamic-storage bin-packing) back into *k*
independent optimal colorings, and makes "typed ports" and "the buffer pool" the **same
mechanism**. In-place coalescing for unary single-consumer blocks gated on explicit `aliasing_safe=true`.
Feedback via `z⁻¹`: persistent buffers excluded from the pool; every SCC must contain a delay or the
graph is rejected. PDC delay-line insertion folds into the same pass (JUCE `needsDelay`). Formalised
in [`pan_memory_model.md`](pan_memory_model.md).

### C4 — Precision comptime, block-size runtime, SIMD-width comptime-per-target
`T` (precision) changes machine code (lane type, instruction selection, accumulator width) → it is a
**comptime kernel parameter**, bound once at config time via a monomorph function pointer (one
indirect call per *buffer* — free). `N` (block size) is **a runtime slice length** (the device
dictates it, it can change on a route switch) — and Zig's vectorization keys off the **comptime
width `W`** (`std.simd.suggestVectorLength`), *not* off comptime `N`, so a runtime-N loop with a
comptime-W body + scalar tail vectorizes fully. Therefore **no precision×block-size cross-product**.
*Refinement:* the comptime kernel parameter is a **Numeric trait `{ Lane, Acc, saturate, W }`**, not
just a lane type — fixed-point (`i16×i16→i32`, saturation) is the *common* embedded path, not a
footnote. Two N-regimes: **runtime N for stream ports, comptime N(=K) for fixed-K feature ports**
(kills the scalar tail, enables `inline for` unrolling) — the *same* distinction the pool already
makes. Formalised in [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md).

### C5 — Clock-driven pull roots (audio output is just one of them)
Generalize "the device callback pulls the audio root" to "**a clock source drives a pull root**."
The audio device is one clock source; a wall-clock timer or input-exhaustion is another. **Analysis
sinks** (features → collector → visualization — the brief's `examples/` goal) get their **own pull
root on a non-RT thread**, fed from the audio graph through an SPSC ring (a tap), never stealing the
audio deadline. Shared upstream is rendered once and fanned to both roots. Resolves the audit's S3.
Formalised in [`pan_execution_model.md` §6](pan_execution_model.md).

### C6 — Two execution modes via the mux family (COMMITTED 2026-06-03)
The graph is **execution-mode-invariant** (the Yoneda probe): one diagram, runnable under
**RealtimeStreaming** (pull, hard deadline, H1–H3; Tier A 1-core *or* Tier B P-core) or **OfflineBatch**
(push, throughput, O1–O3; Tier C). The mux family **is** the mode selector; no block changes between
modes. Formalised in [`catalog.md` §8.10](catalog.md),
[`pan_parallel_and_offline_execution.md` §0](pan_parallel_and_offline_execution.md).

### C7 — Static-parallel RT executor (Tier B) (COMMITTED 2026-06-03)
Heavy RT graphs exceeding one core are served by a **commit-time HEFT schedule + point-to-point
release/acquire ready-flags + OS audio workgroup + concurrency-aware interval coloring**, **cost-model
gated** (enabled only when work/span and headroom justify it) and **auto-demoting to Tier A**. Output is
**bit-identical to Tier A** (op-granular scheduling preserves per-op reduction order). The workgroup
removes the original deferral premise (M3 P/E migration → unbounded spin); the bounded-spin claim is
▷/≈ (workgroup-conditional, the FTZ honesty class), never weakening Tier A's structural ⊢. Formalised in
[`catalog.md` §8.10–§8.11](catalog.md),
[`pan_parallel_and_offline_execution.md` §2](pan_parallel_and_offline_execution.md).

### C8 — Purpose-agnostic core: two canonical graph shapes (COMMITTED 2026-06-03)
The core is **direction- and purpose-agnostic by construction** (the Yoneda/`SampleMux` probe read across
*direction* as well as transport): one executor serves an **Analyzer** (analysis-rooted feature
extraction; the `notes/1.md` viz) and an **Instrument** (audio-device-sink-rooted synthesis / digital
instruments) from one codebase. The supporting refinements are all small core additions or library
blessings, none weakening H1–H3: **`ChannelLayout` identity** in the element type
([`catalog.md` §1.3](catalog.md)), **`VariRate`** bounded-variable rate (§2.6), the **Source**
zero-sample-input contract (§2.7), the **typed event lane** `EventLane(Event)` + the blessed `NoteEvent`
(§8.6), and **intra-block fixed-capacity polyphony** `PolyVoice` (§8.12). Formalised in
[`catalog.md` §8.13 + §11.2 C8](catalog.md). *(pan was conceived for feature extraction; the locked
architecture is a genuine general-purpose audio DSP engine — synthesis is within scope and enumerated in
the block taxonomy, [`pan_categorical_bridge_and_roadmap.md` §2](pan_categorical_bridge_and_roadmap.md).)*

---

## 4. The shape of the thing

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  User graph (blocks + composites)   — authored exactly like ZigRadio            │
├───────────────────────────────────────────────────────────────────────────────┤
│  Authoring surface (INHERITED):  Map:  process(self, in:[]const In, out:[]Out)  │
│                                  Rate: pull(self, want, out)->produced;          │
│                                        needed_input(want); out_per_in; latency   │
│                                  + typed ports, channels, aliasing_safe, Numeric{T}│
├───────────────────────────────────────────────────────────────────────────────┤
│  SampleMux seam (INHERITED vtable):  TestSampleMux | PullSampleMux | RingMux      │
├──────────────────────────────┬───────────────────────────┬─────────────────────┤
│  Tier A — sync pull (CORE)    │  Tier B — static-parallel  │  Tier C — push       │
│  whole DAG in callback,       │  (DEFERRED library)        │  (DEFERRED library)  │
│  wait-free, render op-list    │  level schedule + barrier  │  offline file→file   │
├───────────────────────────────────────────────────────────────────────────────┤
│  Memory: per-element-class colored pool (CORE) | per-edge rings (offline only)   │
│  Control: lock-free SPSC command ring + atomic-RCU plan swap (CORE)              │
├───────────────────────────────────────────────────────────────────────────────┤
│  Compute HAL: comptime @Vector(W,T) SIMD (NEON/Helium/AVX) + optional vDSP/FFTW  │
│  I/O HAL: CoreAudio | ALSA/JACK/PipeWire | I2S-DMA ping-pong ;  LPCM codecs       │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Minimal frozen core vs layered libraries

**Freeze in the spec (each is orthogonal; removing any one breaks H1/H2/H3):**

1. **Two block contracts** `Map` / `Rate` with comptime-extracted typed ports carrying
   `{element_type, channels, out_per_in, algorithmic_latency, aliasing_safe}`, **plus parameter
   (control) ports** — a control-rate side-input port kind (catalog §2.4), exempt from the rate-1:1
   law, the in-graph analogue of `set` (port-kind machinery core; modulation blocks library).
2. **Numeric kernel trait** `{Lane, Acc, saturate, W}`, comptime, bound once via the HAL; N runtime
   for stream ports, comptime for fixed-K ports.
3. **The `SampleMux` seam** — the only coupling between blocks and transport.
4. **Tier A synchronous pull executor** + the compiled render op-list.
5. **Per-element-class colored buffer pool**, allocated once at commit; `aliasing_safe` as an honored hint.
6. **The graph-commit / validation pass**: type/format check → schedule → liveness → coloring →
   SCC-must-contain-delay → PDC → total static memory. After commit, the render path allocates
   nothing. *Must be comptime-evaluable, and this is enforced by a CI smoke gate* (roadmap
   [`pan_categorical_bridge_and_roadmap.md` §5](pan_categorical_bridge_and_roadmap.md)): the commit
   pass uses only comptime-safe primitives, and a non-comptime-evaluable block is rejected with a
   pan-level error (`comptime_commit_safe`), not a raw 40-frame Zig comptime trace (so embedded can
   run it at `comptime`).
7. **Persistent-state buffers** (delay lines, `z⁻¹`, framer rings) as a pool-excluded category.
8. **Generalized clock-driven pull roots** (one abstraction; the device callback is one instance).

**Committed (phased) layered libraries (build on the above; each discharges its mode's invariants —
H1–H3 for RT, O1–O3 for offline):** **Tier C (OfflineBatch — pipeline + data-parallel chunking via
`warmup_samples`)** and **Tier B (static-parallel RT — HEFT + point-to-point + audio workgroup +
concurrency-aware colorer, cost-gated, auto-demote)** are no longer deferred — promoted 2026-06-03 (C6/C7,
[`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md)); they remain *layered*
(not frozen core — Tier A is), so the litmus is unchanged. Other layered libraries: concrete DSP blocks
(biquad, FFT/STFT, oscillators, reverb), the adaptive **drift resampler** (a `Rate` block + a clock
comparator), **off-thread prefetch source** (a `Rate` source over an SPSC ring), click-free ramps /
NaN guards / FTZ-DAZ (FTZ/DAZ set via the **required realtime token** — `enterRealtimeThread()`,
a no-op token on fixed-point but a uniform API shape across targets, see
[`pan_io_realtime_and_pipeline.md` §3](pan_io_realtime_and_pipeline.md); NaN guards a build-mode
behaviour surfaced in telemetry),
**device-reconfiguration** (commit-and-atomic-swap protocol), the `ChannelMap`/`Vectorize`/`Concat`
combinators, and the `FeatureCollectorSink`. Catalogued in
[`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).

**Cut entirely as a *contract*:** the "single unified block surface" (it is two contracts, C1) and
**Tier-B's parallel executor *as frozen core*** — it stays a *layered* library, never on the frozen
RT-critical path, so Tier A remains the structural-⊢ ground truth. (The earlier rationale "busy-waits
the RT thread, unnecessary at budget" is **superseded for the *deferral***: the executor is now
COMMITTED as a cost-gated, workgroup-co-scheduled, auto-demoting overlay — the naïve unmanaged-spin
barrier is what was rejected, not parallelism per se. See
[`pan_execution_model.md` §5](pan_execution_model.md),
[`pan_parallel_and_offline_execution.md` §2](pan_parallel_and_offline_execution.md).)

---

## 6. Tensions resolved (pick a side, don't average — Rule 7)

| # | Tension | Decision | Where |
|---|---|---|---|
| T1 | Pull-purity vs analysis-sink roots | **Multiple pull roots, one clock arbiter.** Analysis sinks are non-RT roots fed via SPSC rings; never slaved to the audio deadline. | [exec §6](pan_execution_model.md) |
| T2 | Clean dataflow fanout vs the corpus's fused single-pass min-traffic ideal | **Clean dataflow is the *semantic* model; fusion is a commit-time optimization** the colorer may apply to adjacent `Map` blocks (provably semantics-preserving) — never exposed in the API. | [mem §5](pan_memory_model.md) |
| T3 | Static coloring vs dynamic graph edits | **Static within an epoch; edits build a new committed plan off-thread and atomic-swap it at a block boundary** (RCU). Parameter changes are live; topology is epochal. Embedded has *no* runtime epochs (comptime-fixed graph). | [mem §6](pan_memory_model.md) |
| T4 | Runtime-N vs hop-alignment when H ∤ N | **The `Rate`/`Framer` block owns an internal ring and absorbs the misalignment; the scheduler never assumes H \| N.** Forcing N≡0 (mod H) would wrongly couple device buffer size to algorithm internals. | [exec §2](pan_execution_model.md) |
| T5 | One unified block surface vs honesty | **Two contracts** (C1). One struct *shape*, two trait obligations, discriminated at comptime by whether `out.len` is forced `== in.len`. | [exec §2](pan_execution_model.md) |

---

## 7. Embedded reality check (the factoring proof)

On an STM32-class MCU with no heap and a DMA ping-pong ISR as the callback, the core holds **iff**
we treat the MCU as the constraint that *defines* the core:

- **Tier A only.** Tiers B/C do not exist on this target — and they are already non-core.
- **The DMA half-/full-transfer ISR *is* the `SampleMux` callback;** N = half the DMA buffer, which
  is **comptime-known** here — *strictly easier* than desktop (no scalar tail, full unrolling). The
  N-runtime/N-comptime split (C4) pays off directly.
- **Numeric = `{Lane:i16/q15, Acc:i32, saturate:true, W:1–2}`;** no FPU ⇒ `f64` banned, `f32`
  conditional, fixed-point default. This is why `Acc`/`saturate` are *in the core trait*.
- **All memory static** in `.bss`; the commit/coloring pass runs at **comptime**; topology is
  comptime-fixed (no runtime epochs; T3's atomic-swap is desktop-only). That the commit pass is
  genuinely comptime-evaluable end-to-end is a **correctness obligation, discharged by test
  (empirical)**, not an assertion: a CI embedded smoke gate calls `commitComptime()` inside a
  `comptime` block in a `ReleaseSmall` embedded build — the build compiling is the **discharge of
  the obligation FOR THE SMOKE GRAPH** (not a proof for arbitrary graphs); failing to compile is the
  loud failure ([`catalog.md` §8.5](catalog.md)). A non-comptime-evaluable block is rejected with
  the pan-level `comptime_commit_safe` error rather than a raw Zig trace
  ([`pan_categorical_bridge_and_roadmap.md` §5](pan_categorical_bridge_and_roadmap.md)).
- **No vtable on the hot path:** the embedded `SampleMux` is a comptime-known concrete type so the
  whole render monomorphizes and inlines; the *concept* stays, the *fat pointer* vanishes.
- **RT hygiene → HAL calls:** FTZ/DAZ set via the required realtime token at ISR/thread entry — a
  no-op token on fixed-point, but the token-gated entry API is identical to desktop; NaN guards
  compiled out in release (surfaced in telemetry as `guards_compiled_out`); no off-thread prefetch
  (file/network sources simply don't exist here).

> **The encouraging structural result:** the embedded profile is a *strict comptime specialization*
> of the desktop core, not a fork. Every desktop runtime degree of freedom (runtime N, runtime
> commit, vtable mux, extra tiers) is exactly the set of things that collapse to comptime or vanish
> on an MCU. That is the strongest evidence the core is factored correctly (Rule 11: one set of
> conventions, specialized, not forked). Detail in
> [`pan_io_realtime_and_pipeline.md` §8](pan_io_realtime_and_pipeline.md).

---

## 8. One-line summary

**Require a comptime block surface, a `SampleMux` seam, and external-oracle gold-vector testing — the
three properties ZigRadio witnesses are feasible in Zig (not inherited behaviours); replace the
thread-per-block + ring transport with a synchronous pull scheduler compiled to a render op-list, a
per-element-class colored buffer pool, and a lock-free control plane; commit to two honest block
contracts (`Map`/`Rate`), precision-comptime/N-runtime/W-comptime numerics, and clock-driven pull
roots — so the same elegant authoring model serves hard-real-time audio at sub-5 ms latency and
statically-bounded memory, with the embedded build a pure comptime specialization of the desktop
core.**
