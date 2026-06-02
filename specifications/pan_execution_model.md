# pan — Execution Model

> **Status: LOCKED** (2026-06-02). Change-control: conforms to [`catalog.md`](catalog.md); an edit
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
for the event lane. This is a genuine *advantage* of pull over push: buffer granularity never fights
you.

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
| **B** | Static-parallel: pre-spawned RT-pinned workers, compile-time level schedule, bounded-spin barrier per level | **DEFERRED library, not core** | A spin barrier *busy-waits on the RT thread*; on M3's asymmetric P/E clusters (no userland core isolation, macOS migrates threads) its worst case is unbounded. The budget (1.3–2.7 ms) is ample single-core; *heavy* graphs are better served by **algorithmic** parallelism (partitioned convolution, SIMD, polyphase) inside one thread. It also contaminates the colorer (per-worker privatization). **Keep the level-schedule analysis; defer the executor.** |
| **C** | Threaded push (ZigRadio verbatim): thread-per-block, large rings, condvars | **DEFERRED library, not core** | Offline file→file / batch; latency irrelevant, throughput rules. Reuses the same `Map`/`Rate` blocks via `RingSampleMux`. Touches none of H1–H3 (no deadline), so it is off the freeze-critical path. This is where the inherited ring machinery earns its keep. |

> One authoring surface, three execution contracts via three muxes — but only **Tier A** is frozen.

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
