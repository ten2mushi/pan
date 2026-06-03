# pan — Execution Model

> **Status: LOCKED** (2026-06-02; **amended 2026-06-03** — parameter ports exempt from M1 (§2.1);
> `out_per_in` single-rate (§2.2); multi-input pull rule (§2.3); data-gating-only; **then §5 tiers B/C
> COMMITTED (phased)** under two execution modes — see [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md)
> and catalog §8.10/§15; **then the source/variable-rate/event amendment** — the zero-sample-input
> Source contract SR1–SR3 (§2.1/§2.2/§6), `VariRate` bounded-rate `Rate` (§2.2.1), the typed
> `EventLane(Event)` + blessed `NoteEvent` (§4.4), and the Analyzer/Instrument graph shapes (§6) —
> catalog §2.6/§2.7/§8.6/§8.12/§8.13).
> Change-control: conforms to [`catalog.md`](catalog.md); an edit
> that changes a definition or law must update catalog.md and every citing section in the same commit.
> Support document for [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md)
> (the hub). Siblings: [`pan_memory_model.md`](pan_memory_model.md) ·
> [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md) ·
> [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md) ·
> [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).
>
> Scope: the **two block contracts**, the **pull scheduler / render op-list**, the **`PullSampleMux`
> seam**, the **scheduler-tier disposition**, and **clock-driven pull roots**. Realises commitments
> **C1, C2, C5** of the hub.

---

## 1. The callback contract and the latency theorems

The audio device hands you an output buffer of exactly **N frames** with a deadline of **N / Fs**
seconds and demands it filled. A missed deadline is an **xrun** — an audible click. From this, three
non-negotiables (hub invariant **H1**):

1. **No unbounded blocking on the audio thread** — no contended mutex, condvar, malloc, syscall,
   page fault. ZigRadio's wakeup model is disallowed here.
2. **Latency floor = one device block; every buffering stage adds to it.** A ring per edge costs
   ≥ one block-period *per hop*.
3. **"What's available" is meaningless** — the contract is *pull*: "render **exactly these N
   frames** into **this exact buffer**, now."

Latency budget (mono f32 @ 48 kHz):

| Construct | Time held | Verdict |
|---|---|---|
| ZigRadio 8 MiB ring | ~45 s | Absurd. |
| One 128-frame block | 2.67 ms | Target granularity. |
| 10-block chain, ring-per-hop | ~27 ms + jitter | Fails sub-10 ms. |
| 10-block chain, pull in one callback | 2.67 ms | Meets sub-5 ms with margin. |

The compute budget at 48 kHz / 64–128 frames is ~1.3–2.7 ms per callback — *ample* for a single
performance core (this is why Tier B is not core; §5).

---

## 2. The two block contracts (C1) (canonical laws: [`catalog.md` §2](catalog.md))

The ideation's "one unified surface, two execution interpretations" is **rejected** as stated: it
leaks precisely at the rate-elastic seam, and the feature corpus
([audit §2–§3](../notes/architecture_audit_feature_extraction.md)) hits that seam everywhere (framing/STFT,
decimation, resampling). There are **two morphism kinds**, discriminated at comptime by whether the
output length is forced equal to the input length.

### 2.1 `Map` — synchronous, rate-1:1, possibly type-changing
```zig
// Pure over its input slice. out.len == in.len enforced by the contract.
pub fn process(self: *Self, in: []const In, out: []Out) void;
```
- ~80 % of audio (gain, EQ, pan, mix, waveshaper) **and** the type-changing feature maps
  (power-spectrum, mel filterbank, log, DCT-II).
- **Schedule-agnostic** (Tier A/B/C drive identical code via different muxes), **colorable**, and
  **sub-block-splittable for free** (a shorter `N` twice — see §4.2). May change *element type*
  (`[]const Complex(f32) → []f32`) but **not rate**.
- May declare `pub const aliasing_safe = true` when the author asserts the kernel is free of
  intra-call read-after-write aliasing hazards and input is single-consumer & last-use here (the
  colorer may then alias `in` and `out`; see [`pan_memory_model.md` §3](pan_memory_model.md)).
- May declare **parameter ports** via `pub const params = .{ ... }` (control-rate side inputs —
  `Scalar`/`FeatureFrame` coefficients exposed as `node.param.<name>`). Parameter ports are **exempt
  from the rate-1:1 law** (M1's `out.len == in.len` ranges over sample ports only) and are the
  in-graph analogue of `set` — see [`catalog.md` §2.4](catalog.md),
  [`pan_type_and_numeric_model.md` §1.1](pan_type_and_numeric_model.md).
- **Source refinement (zero sample-input, SR1; [`catalog.md` §2.7](catalog.md)).** A **pure generator**
  (oscillator, noise, wavetable, constant) is a `Map` with **zero sample-input ports**: M1 is **vacuous**
  over the empty `in`, and the complementary rule sets **`out.len` = the pull demand `N`** delivered by
  the mux's `getOutputBuffer` (§3). Its phase / RNG / table-cursor is ordinary per-sample Mealy state
  advanced by `N`; it is driven only by parameter ports and the event lane (§4.4). The classifier reads
  *zero sample-input ⇒ length from the pull, not from `in.len`*.

```zig
// illustrative — Zig 0.16: pure generator = Map, zero sample-input
const Oscillator = struct {
    phase: f32 = 0,                                // internal Mealy state
    pub const params = .{ .freq = Scalar(f32), .shape = Scalar(f32) };
    pub fn process(self: *@This(), out: []Sample(f32)) void { _ = self; _ = out; } // out.len == pull N
};
```

### 2.2 `Rate` — rate-elastic transducer
```zig
pub const out_per_in: Ratio;            // rational, e.g. 1:H for a hop-H framer; D:1 decimator
pub const algorithmic_latency: usize;   // samples; DISTINCT from the rate ratio
pub fn needed_input(self: *Self, want: usize) usize;        // how many in-samples to produce `want` out
pub fn pull(self: *Self, want: usize, out: []Out) usize;    // returns produced (may be 0 or many)
```
- Owns **internal clocked state** (a ring of pending samples) → not a pure function of `(in)`.
- May emit **zero** outputs (accumulating) or **many** (hop < buffer). Output port may differ in
  rate *and* element type.
- **`out_per_in` and `algorithmic_latency` are orthogonal** — latency ≠ decimation. Conflating them
  was the audit's S2. A `Rate` block that fails to declare *both* is a **build error** (Rule 12).
- Members: `Framer(N,H,window)`, decimator/interpolator, rational/arbitrary resampler (including the
  drift-ASRC of [`pan_io_realtime_and_pipeline.md` §1](pan_io_realtime_and_pipeline.md)),
  STFT/iSTFT, partitioned-convolution.
- **`out_per_in` is single-rate per block** ([`catalog.md` §2.2 R5](catalog.md)): a processor whose
  outputs run at *different* rates (wavelet/octave decomposition, multi-rate CQT) is **not** one
  `Rate` block — it decomposes into a cascade/bank of uniform-rate `Rate` stages (each stage's outputs
  share one rate). This keeps the `pull`/`needed_input` recursion (§2.3) decidable.
- **Stream / sample source = `Rate` (or `VariRate`) source, zero sample-input** (SR2;
  [`catalog.md` §2.7](catalog.md)). A source over a backing store / prefetch FIFO owns a read cursor and
  `pull(want, out)`s from it; the off-thread prefetch source
  ([`pan_io_realtime_and_pipeline.md` §5](pan_io_realtime_and_pipeline.md)) is this kind.
  **Sample playback at arbitrary pitch is `VariRate`** (`param.pitch`). **Every non-feedback path must
  be source-rooted** (SR3): a path whose head is neither a Source nor a persistent generator
  ([`pan_memory_model.md` §6](pan_memory_model.md)) is empty — a commit error.

#### 2.2.1 `VariRate` — bounded-variable-rate `Rate` ([`catalog.md` §2.6](catalog.md))
A `Rate` whose actual out:in ratio **varies at runtime** declares a **bounded interval** instead of a
point ratio, discriminated **at comptime by field presence** (`rate_bounds` **xor** `out_per_in`),
exactly as Map-vs-Rate is discriminated. The pull contract (`pull(want, out) → produced`, §2.2) is
*already* rate-elastic, so the **operational path is unchanged**; only the **static-planning** quantities
generalise from a point ratio to an interval. This is **additive** — fixed-`out_per_in` blocks are
unaffected.
```zig
// illustrative — Zig 0.16
pub const RatioInterval = struct { min: Ratio, nominal: Ratio, max: Ratio };
pub const rate_bounds: RatioInterval = .{ .min = ..., .nominal = ..., .max = ... };
pub const max_latency: usize = 2048;                              // worst case over the interval — for PDC
pub const ratio_source: enum { parameter, internal_controller }; // .parameter ⇒ in-graph operating point (param port, §2.1)
```
- **Worst-case static planning.** Buffer sizing and `needed_input(want)` use the **`min` ratio** (the most
  input ever needed); PDC ([`pan_memory_model.md` §7](pan_memory_model.md)) uses **`max_latency`**. The
  scheduler recursion (§2.3) plans on the interval's worst-case endpoints, keeping H2 footprint bounded.
- **Ratio held per call** — sampled **once per render call** (held across the buffer like any parameter,
  §2.1), never mid-call, preserving per-call reduction order and sub-block determinism.
- **Determinism class.** A **parameter-driven** ratio (deterministic automation) is **O3-reproducible**; a
  **controller-driven** ratio (the drift-PI ASRC on a wall-clock FIFO) is **≈ only** — the same class as
  clock drift, not a defect.
- **Membership.** The device-boundary **adaptive drift-ASRC** (`ratio_source = .internal_controller`);
  **varispeed / scrub sample-playback**; **runtime-stretch TSM / phase-vocoder** (STFT/iSTFT stay
  fixed-rate; the *variable synthesis hop* is the `VariRate` seam) and **pitch-shift** (TSM ∘ resample)
  compose from it. A *fixed* stretch factor needs none of this — it is an ordinary fixed-`out_per_in`
  cascade.

> **One struct shape, two trait obligations.** The comptime port machinery (verified to read
> `.pointer.child` of each `process`/`pull` param — see [hub §2](pan_architecture_formalisation.md))
> classifies a block by the presence of `out_per_in`/`pull`. The categorical reading: `Map` and
> `Rate` are two morphism classes; the rate-elastic adapter is where the push↔pull natural
> transformation is non-trivial (it carries the latency obligation). See
> [`pan_categorical_bridge_and_roadmap.md` §1](pan_categorical_bridge_and_roadmap.md).

### 2.3 Why `Rate` cannot be folded into `Map` (T4, T5)
A pull scheduler that assumes "one pull of the root pulls exactly N from every leaf" is **wrong** the
moment a `Rate` block sits mid-graph: the block may need `needed_input(want)` upstream samples to
produce `want`, and may buffer the remainder. The scheduler asks each input edge for
`producer.needed_input(want)` and recurses; a `Rate` block absorbs `H ∤ N` misalignment in its own
ring. Forcing `N ≡ 0 (mod H)` (the tempting alternative) would couple the device buffer size to an
algorithm's internal hop and break on every route switch — **rejected**.

**Multi-input pull rule (catalog §8.8).** Each input edge is satisfied **independently** via its
producer's `needed_input(want)`. **Same-rate** multi-input (AEC mic+reference, sidechain, crossover
sum, summing mixer) is ordinary; latency across inputs is aligned by PDC
([`pan_memory_model.md` §7](pan_memory_model.md)). **Mixed-rate *sample* inputs require an explicit
rate adapter** (resampler/framer) — no implicit reconciliation. The only auto-reconciled cross-rate
input is a **parameter port** ([`catalog.md` §2.4](catalog.md)), via ramp/hold coercion.

> **Decision rule (newcomer sidebar — "do I need a `Map` or a `Rate`?").** The biggest newcomer
> hazard is psychological: people reach for *"a `Map` with state."* The rule:
> - **`Map`** — if `out.len` is **always** `in.len` and your output depends only on the current input
>   slice. **Per-sample state is still a `Map`.** A biquad/IIR carries per-sample `z⁻¹` state and is
>   *rate-1:1* → it is a `Map` (the tight-feedback fused kernel of
>   [`pan_memory_model.md` §6.1](pan_memory_model.md) is also a `Map`).
> - **`Rate`** — if you **accumulate across calls**, emit a **different number** of samples than you
>   consume, or **buffer until you have enough**. A ring / overlap buffer is the `Rate` smell. A
>   `Framer` buffers `FRAME` samples and emits one window every `HOP` → `Rate`.
>
> The load-bearing distinction is **biquad vs `Framer`**: both have "state," but the biquad's state is
> *per-sample* (rate-1:1, `Map`) while the `Framer`'s is a *cross-call accumulation buffer* with a
> different out-vs-in count (`Rate`). The type system **cannot** auto-detect the "`Map` with hidden
> accumulator" mistake (a `Map` is *allowed* per-sample state), so this is a documentation/tutorial
> obligation, not a build error — ship the rule and a tutorial chapter alongside the existing
> `algorithmic_latency`/`out_per_in` build error. See
> [`pan_categorical_bridge_and_roadmap.md` §2](pan_categorical_bridge_and_roadmap.md).

---

## 3. The `PullSampleMux` seam (C2)

ZigRadio's `SampleMux` is exactly 10 vtable methods (verified, `sample_mux.zig:14-29`; see
[`05_SAMPLE_MUX_DATAFLOW_AND_BUFFERING.md`](../zig_engineering/05_SAMPLE_MUX_DATAFLOW_AND_BUFFERING.md)).
A third implementation, `PullSampleMux`, satisfies the *same* interface with pull semantics:

| vtable method | Push (ring) semantics | **Pull semantics** |
|---|---|---|
| `waitInputAvailable(i, n)` | block on condvar until ring has n | **return immediately** — the scheduler rendered upstream first, so exactly N is present |
| `getInputBuffer(i)` | slice into the ring | slice into the **pool buffer** assigned to that edge ([mem §2](pan_memory_model.md)) |
| `getOutputBuffer(i)` | slice into the ring | slice into the pool buffer assigned to this output edge |
| `updateInputBuffer(i, n)` | advance reader cursor | **no-op** (single-shot render; liveness already known) |
| `updateOutputBuffer(i, n)` | advance writer, broadcast | **no-op commit** (no readers to wake) |
| `setEOS` | propagate both directions | offline/transport only |

> The block never knows whether its `out` slice is a private double-buffer, a coalesced pool buffer,
> or (offline) a ring. The `SampleMux` abstraction — ZigRadio's single best idea — pays off a third
> time. Because `wrapProcessFunction` makes **no aliasing assumption** (verified, `block.zig:60-78`),
> the in-place path needs no wrapper change.

---

## 4. The render op-list (compile once, replay every callback)

Following JUCE `AudioProcessorGraph`: the per-callback hot path must do **zero** graph walking.

### 4.1 Commit-time compilation (off the audio thread; at `comptime` on embedded)
The graph-commit pass ([hub §5 item 6](pan_architecture_formalisation.md)) produces an **ordered,
flat list of render ops**:
```
op := { fn_ptr (monomorphized Map/Rate kernel),
        self_ptr,
        input_buffer_ids[],   // indices into the per-element-class pools
        output_buffer_ids[],
        n_or_pull_spec }
```
Pipeline: topological sort (on the DAG with feedback edges removed) → liveness → per-element-class
coloring → SCC-has-delay check → PDC delay-line insertion → buffer-id assignment → emit op-list +
total static memory figure. All of this is detailed in [`pan_memory_model.md`](pan_memory_model.md).
This whole pass **must be comptime-evaluable** so embedded can run it at `comptime` — a CI smoke
gate calls `commitComptime()` inside a `comptime` block in a `ReleaseSmall` embedded build to exercise
it (the build compiling is the **discharge of the obligation for the smoke graph** — not a proof for
arbitrary graphs; failing to compile is the loud failure, [`catalog.md` §8.5](catalog.md)), and a
non-comptime-evaluable block is rejected with the pan-level
`comptime_commit_safe` error rather than a raw Zig trace
([`pan_categorical_bridge_and_roadmap.md` §5](pan_categorical_bridge_and_roadmap.md),
[hub §5 item 6](pan_architecture_formalisation.md)).

### 4.2 Hot path (inside the callback)
```
for op in plan.ops:  op.fn_ptr(op.self_ptr, gather(op.inputs), scatter(op.outputs), op.n)
```
One indirect call per *buffer* per block (free; the compiler often devirtualizes; on embedded the
whole plan inlines). **Sub-block rendering** (events, hop boundaries) is "just a shorter N over a
prefix of the same buffers" — see [`pan_io_realtime_and_pipeline.md` §6](pan_io_realtime_and_pipeline.md)
and §4.4 below for the event lane. This is a genuine *advantage* of pull over push: buffer granularity
never fights you.

### 4.4 The typed event lane ([`catalog.md` §8.6](catalog.md))
The **event lane** parallel to the sample lanes is **`EventLane(Event)`**, parameterised by a **comptime
`Event` type** the consuming block chooses (event-type-**generic**, exactly as ports are
element-generic). It carries a time-sorted `(sample_offset, event)` list; the scheduler renders in
**sub-blocks bounded by event offsets** — pull `[0,k)`, apply the event, pull `[k,N)`. Free for `Map`
by sub-block splitting (§4.2); `Rate` blocks quantize events to their hop grid.

- **(EV1) Event-generic mechanism.** Sample-accurate dispatch and the sub-block split hold for *any*
  `Event` — the split keys **only** on `sample_offset`, never on the payload — so an Analyzer (§6) may
  pick a trivial/automation `Event` and pay no music-model cost.
- **(EV2) `note_id` routing.** `note_id` enables per-note (MPE) routing to a specific voice in
  `PolyVoice` (intra-block fixed-capacity polyphony — [`catalog.md` §8.12](catalog.md)).
- **(EV3) onset accuracy.** Note onsets are sample-accurate via the sub-block split; `schedule`
  ([`pan_io_realtime_and_pipeline.md` §7](pan_io_realtime_and_pipeline.md)) remains the only
  sample-accurate *parameter* source.

pan ships a blessed **`NoteEvent`** library union for instruments — **pitch is in Hz** (tuning-agnostic,
microtonal-friendly; a note#→Hz tuning block is library, not core):
```zig
// illustrative — Zig 0.16, LIBRARY type (not core)
pub const NoteEvent = union(enum) {
    note_on:    struct { note_id: u32, pitch_hz: f32, velocity: f32 },
    note_off:   struct { note_id: u32, velocity: f32 },
    pressure:   struct { note_id: u32, value: f32 },                 // poly AT / MPE pressure
    expression: struct { note_id: u32, axis: ExprAxis, value: f32 }, // MPE per-note bend / timbre
    control:    struct { cc: u16, value: f32 },
    pitch_bend: f32,
    program:    u16,
};
```

### 4.3 Installing a new plan (T3)
A graph edit builds a *new* plan off-thread, then publishes it by **atomic pointer swap (RCU)**
consumed at a callback boundary; delay-line state is handed off / ramped to avoid clicks. The audio
thread never blocks, never allocates. This RCU plan swap is the mechanism behind the user-facing
**`edit`→`commit`** verb of the unified control surface (the third of the three control verbs
`set`/`schedule`/`edit`; [`pan_io_realtime_and_pipeline.md` §7](pan_io_realtime_and_pipeline.md)).
Control-plane mechanics in
[`pan_io_realtime_and_pipeline.md` §7](pan_io_realtime_and_pipeline.md).

---

## 5. Scheduler tiers — disposition

| Tier | What | Status | Rationale |
|---|---|---|---|
| **A** | Single-thread synchronous pull in the callback | **CORE (frozen)** | Meets sub-5 ms; wait-free; the always-correct ground truth. |
| **B** | Static-parallel RT: pre-spawned workers (callback thread = worker 0) joined to the OS **audio workgroup**; commit-time **HEFT** schedule; **point-to-point** release/acquire ready-flags (no global barrier); concurrency-aware coloring; **cost-model-gated**; **auto-demotes to A** | **COMMITTED (phased)** | The deferral's premise — *a spin barrier busy-waits the RT thread; M3 P/E migration → unbounded* — is **removed by workgroup co-scheduling**, which bounds the cross-worker spin to one op (▷/≈, the FTZ honesty class). The gate enables B only when work/span and headroom justify it (a near-linear chain is refused); for a *single fat op*, algorithmic parallelism (SIMD, partitioned convolution) inside the op still applies — decompose it into per-partition ops to let B parallelize them. The colorer is **not** contaminated for a *static* schedule (interval coloring on the schedule-time axis — [`catalog.md` §8.11](catalog.md)). A naïve **level-barrier fork-join** is retained as the simpler evolution stage on the same foundation. Full design: [`pan_parallel_and_offline_execution.md` §2](pan_parallel_and_offline_execution.md). |
| **C** | Threaded push: thread-per-stage, large rings, condvars **+ data-parallel timeline chunking** (`warmup_samples`) | **COMMITTED (phased)** | The **OfflineBatch** mode. Offline file→file / batch; latency irrelevant, throughput rules. Reuses the same `Map`/`Rate` blocks via `RingSampleMux`. Runs under the offline invariants **O1–O3** ([`catalog.md` §11.1b](catalog.md)), not H1–H3. This is where the inherited ring machinery earns its keep. Full design: [`pan_parallel_and_offline_execution.md` §3](pan_parallel_and_offline_execution.md). |

> One authoring surface, two **execution modes** ([`catalog.md` §8.10](catalog.md)) over three
> execution contracts via the mux family: **RealtimeStreaming** = Tier A (1 core) or Tier B (P cores);
> **OfflineBatch** = Tier C. **Tier A remains the frozen ground truth and the always-available
> fallback** (the cost-gate and auto-demote fall back to it); Tiers B/C are committed, phased overlays
> that each discharge their mode's invariants. The graph and blocks are execution-mode-invariant
> (Yoneda probe, [`catalog.md` §4.2](catalog.md)).

---

## 6. Clock-driven pull roots (C5) — resolving T1

The pull graph is demand-driven. **The audio device callback is one demand source; it must not be
the only one.** Generalize:

```
PullRoot := { clock_source, sink_set, owned_subplan }
ClockSource ∈ { AudioDeviceCallback, WallClockTimer(rate), InputExhaustion(file) }
```

- The **audio output** is a `PullRoot` driven by `AudioDeviceCallback`, on the RT thread.
- An **analysis sink** (features → collector → visualization — the brief's `examples/` / 60 fps viz
  in [`1.md`](../notes/1.md)) is a *separate* `PullRoot` on a **non-RT thread**, driven by a timer or by
  input exhaustion. It is **never slaved to the audio deadline** — an expensive feature/viz path
  must not be able to cause an xrun.
- Each non-feedback path bottoms out at a **Source** (zero sample-input, §2.1/§2.2 — SR1/SR2): a pure
  generator's `out.len` and a stream source's `pull(want, …)` both take their length from the **pull
  demand** at the root, so a Source is itself a pull head. A **`VariRate`** block on the path plans on
  the rate interval's **worst-case endpoints** (the `min` ratio for input demand, `max_latency` for PDC —
  §2.2.1); cross-ref [`catalog.md` §2.6](catalog.md), [`catalog.md` §2.7](catalog.md).

> **Two canonical graph shapes ([`catalog.md` §8.13](catalog.md)).** These roots are
> direction-/purpose-agnostic by construction; the core serves two framing shapes from this one root
> machinery: an **Instrument** (generators SR1 + an event/MIDI source → the **audio-device sink = the RT
> callback root**, §1) and an **Analyzer** (a device/file audio source SR2 → `FeatureCollectorSink`/taps
> driven by a **non-RT analysis root**). The device-sink RT root drives an Instrument; the non-RT analysis
> roots drive an Analyzer. Both compose freely; the execution **modes** (§5) are orthogonal.
- **Shared upstream is rendered once** and fanned to both roots; cross-root hand-off is **only** via
  a lock-free SPSC ring (a tap), never via shared pool coloring (each root colors its own subplan).

This resolves the audit's **S3** (pure-analysis graphs have no audio output to pull from) cleanly:
they have their *own* root. The `FeatureCollectorSink`
([`pan_categorical_bridge_and_roadmap.md` §2](pan_categorical_bridge_and_roadmap.md)) drains per-hop
feature frames off-RT into a growable time-series for the visualization pipeline. **Growable sinks
(geometric `realloc` past their `capacity_hint`) are legal *only* on a non-RT pull root** — this is
the contained H1 exception; wiring a `FeatureCollectorSink` onto an RT (audio) root is a **commit
error** ([`pan_categorical_bridge_and_roadmap.md` §2](pan_categorical_bridge_and_roadmap.md)).

---

## 7. Error isolation / resilience

A live engine must not die because one block faulted (NaN, domain error, device hiccup). On the RT
path a faulting block **emits silence and raises a flag** consumed by the control thread; the graph
keeps running (contrast ZigRadio's deliberate collapse-on-error, correct for batch, wrong for a
long-running instrument). The offline path (Tier C) keeps collapse semantics. NaN/denormal hygiene:
[`pan_io_realtime_and_pipeline.md` §3](pan_io_realtime_and_pipeline.md).

---

## 8. What the spec must pin down here

- The exact `Map`/`Rate` trait declarations and the comptime classifier that distinguishes them.
- The `PullSampleMux` 10-method semantics table (§3) as the formal pull contract, and a
  **`PullTestSampleMux`** so every block is tested under *both* push and pull (catches surface
  leaks).
- The render-op-list data structure and the commit-pass ordering (with
  [`pan_memory_model.md`](pan_memory_model.md)).
- The `PullRoot` / `ClockSource` abstraction and the rule that cross-root edges are SPSC-ring taps.
- The typed `PortId` derivation from the `process`/`pull` signature (and `Concat` spec) — carrying
  node identity + direction + element type — and the comptime 8-port-ceiling check (index type `u3`,
  a readable `@compileError` past 8 ports per direction). `connect` type-checks ports against it.
  See [`pan_type_and_numeric_model.md` §1](pan_type_and_numeric_model.md),
  [hub §2](pan_architecture_formalisation.md).
- The **parameter-port** classification (`node.param.*` exempt from M1, ramped/held, one-source
  `set`/`schedule`-xor-edge rule; [`catalog.md` §2.4](catalog.md)), the **multi-input pull rule**
  ([`catalog.md` §8.8](catalog.md): independent per-edge `needed_input`; explicit adapter for
  mixed-rate sample inputs), and **data-gating-only** ([`catalog.md` §8.9](catalog.md): the static
  op-list is **unconditional** — there is no conditional/gated execution; VAD/onset/power gating is a
  `Scalar` the consumer applies, never a skipped op).
- The **Source classifier** (zero sample-input ⇒ `out.len`/`pull` length from the demand `N`, not
  `in.len`; SR1/SR2 and the source-rooted-path check SR3; [`catalog.md` §2.7](catalog.md)) and the
  **`VariRate`** field-presence discrimination (`rate_bounds` xor `out_per_in`) with **worst-case static
  planning** on the interval endpoints ([`catalog.md` §2.6](catalog.md)).
- The **typed event lane** `EventLane(Event)` (comptime-`Event`-generic; sub-block split keys on
  `sample_offset` only) and the blessed Hz-pitched **`NoteEvent`** library union (§4.4;
  [`catalog.md` §8.6](catalog.md)), with **`PolyVoice(Voice, Vmax)`** intra-block fixed-capacity
  polyphony ([`catalog.md` §8.12](catalog.md)) and the two canonical graph shapes
  (Analyzer / Instrument; [`catalog.md` §8.13](catalog.md)).
