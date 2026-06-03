# pan — Memory Model

> **Status: LOCKED** (2026-06-02; **amended 2026-06-03** — element-generic `UnitDelay`/FDN (§6),
parameter ramp/hold state as persistent, parameter edges colored on control-element pools; **then §8a
concurrency-aware coloring** for the COMMITTED Tier-B parallel executor + footprint addendum — see
[`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md) and catalog §8.11/§15). Change-control: conforms to [`catalog.md`](catalog.md); an edit
that changes a definition or law must update catalog.md and every citing section in the same commit.
> Support document for [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md)
> (the hub). Siblings: [`pan_execution_model.md`](pan_execution_model.md) ·
> [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md) ·
> [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md) ·
> [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).
>
> Scope: the **per-element-class colored buffer pool**, liveness, in-place coalescing, **feedback /
> `z⁻¹` / persistent state**, **PDC**, dynamic-edit handling, and the differential-test correctness
> obligation. Realises commitment **C3** and tensions **T2, T3** of the hub.

---

## 1. Framing: per-callback execution *is* register allocation

The pull graph is a DAG executed in a known order per callback ([exec §4](pan_execution_model.md)),
so buffer lifetimes are statically analyzable:

| Compiler concept | pan analogue |
|---|---|
| virtual register | a graph **edge** (one producer output → one or more consumers) |
| physical register | a **block-sized buffer** drawn from a pool |
| instruction order | the **render schedule** (topological order) |
| live range | `[producer writes … last consumer reads]` |
| register count | **M** = max simultaneously-live edges |

For near-linear audio chains M is *tiny* (often 3–6) versus the edge count. A 30-edge graph at N=256
f32: naïve per-edge double-buffer ≈ 60·256·4 ≈ **61 KB**; colored pool with M=5 ≈ **5 KB**. On a
256 KB-SRAM MCU that is the difference between fitting and not.

---

## 2. The key refinement: one pool per element-type-class

The ideation assumed a *uniform* register model (`M·N·sizeof(T)`). But the feature corpus puts
wildly different element sizes on edges in the same graph: an `N=512` audio frame, a
`[N/2+1]Complex(f32)` spectrum, a `[40]f32` mel vector, a scalar. **Coloring intervals of
heterogeneous size is interval bin-packing (Dynamic Storage Allocation) — NP-hard**, not the
linear-scan interval coloring the ideation assumed.

**Decision (resolves audit S1 buffer-sizing + the systems-design "(b)" objection):** maintain **one
pool per element-type-class** (canonical definition: [`catalog.md` §7.2](catalog.md)).

```
Pool(class)  where class = (element_type, element_count)
   e.g.  Pool(Sample(f32), N=512)
         Pool(Frame(Lane, L), N)          // layout-L frame, count C := L.count(); Sample(T) == Frame(Lane,.mono)
         Pool(Complex(f32), 257)
         Pool(FeatureFrame, 40)
         Pool(Scalar(f32), 1)
```

- Within a class **all buffers are identical size** → **linear-scan interval coloring is optimal and
  linear-time** (interval graphs are optimally k-colorable in linear time; this is the classic
  left-edge algorithm).
- Across classes **there is no interference** (different element types can never alias).
- The channel **layout `L`** ([`catalog.md` §1.3](catalog.md)) rides *inside* the element type
  `A = Frame(Lane, L)`, so the pool key `(Frame(Lane,L), N)` and the coloring are **unchanged** — a
  layout difference is already a distinct element type (a distinct class), exactly as a count
  difference was. ⊢.
- Pool sizing falls out as `M_class · element_count · @sizeOf(element_type)` — exactly the audit's
  demand to size by `element_count · sizeof(elem)`, not `N · sizeof(T)`.
- For the few graphs where one class still has heterogeneous *counts* (rare), M is so small (≤ ~8)
  that brute-force / first-fit-decreasing at commit time is optimal-enough and costs **zero** hot
  path.

> This single refinement does double duty: it makes coloring tractable **and** it unifies "typed
> ports" with "the buffer pool" into one mechanism (the element-type *is* the pool key). See
> [`pan_type_and_numeric_model.md` §1](pan_type_and_numeric_model.md) for the typed-port catalog.

**Parameter edges** ([`catalog.md` §2.4](catalog.md)) carry `Scalar`/`FeatureFrame` control elements
and are colored on those **same** per-class pools — a parameter edge is an ordinary edge for coloring,
scheduling, and the SCC-has-delay check (catalog §2.4 P4); only its *ramp/hold state* is persistent
(§6.2).

---

## 3. In-place coalescing (the alias optimization)

For a unary `Map` block whose input edge is **single-consumer and last-used here**, assign the output
the *same* physical buffer — eliding the copy. Verified feasible against the real source: the wrapper
makes no aliasing assumption ([hub §2](pan_architecture_formalisation.md)).

**Gated, never inferred** (a block reading `in[i+1]` while writing `out[i]` would corrupt):
```zig
/// The author asserts the kernel is free of intra-call read-after-write aliasing hazards
/// (process() never reads an input element after the corresponding output element was written).
pub const aliasing_safe = true;
```
The colorer treats this as a **hint it may honor**, and only when the validator proves: (i) single
consumer, (ii) identical element type & count in==out, (iii) the consumer reads before any other
producer overwrites. `noalias` (skill ch.04) is applied **only** on the proven-non-aliased path;
`aliasing_safe` kernels alias by definition. (The name telegraphs the *contract*, not a speed knob:
forgetting it costs a memcpy — safe; asserting it falsely is caught by the §9 B≡C / paranoid-mode
differential test, which quotes the assertion back.)

---

## 4. Fan-out and fan-in

- **Fan-out** extends a buffer's live range to its *last* reader and **forbids in-place** by the
  first reader (a multi-reader buffer cannot be overwritten until all have read). This is exactly
  what the corpus's "one spectrum → 8 parallel reductions" needs: the colorer pins the spectrum
  buffer for the span of the parallel branch; no per-reader copy because feature readers are
  non-mutating. (Holds modulo the fusion tension T2, §5.)
- **Fan-in** (summing mixers, `Concat`): the colorer either gives one mutating consumer a private
  copy (a memcpy) or pins a buffer longer — a commit-time cost-model choice. Additive summing into a
  destination buffer (à la Web Audio's unity-gain summing junction) is the default for audio mix.

---

## 5. Tension T2 — clean dataflow vs the corpus's fused single-pass ideal

The feature corpus's prime directive is *compute the whole reduction family in one pass over the hot
spectrum with ~zero marginal memory traffic*. A clean graph with 8 separate extractor nodes re-reads
the `[N/2+1]f32` power buffer 8 times — on embedded that is 8× the L1 traffic the corpus spent its
whole design avoiding.

**Decision (pick a side):** **clean dataflow is the *semantic* model; fusion is a commit-time
optimization, never an API contract.** Authors write separate, testable `Map` blocks (Rule 2/3).
The committer is *allowed* to **fuse adjacent `Map` blocks that share an input buffer** (provably
semantics-preserving for rate-1:1 type-stable maps) to recover the single-pass win. Fusion is never
exposed. For embedded today, a hand-fused "perceptual-sparse" multi-reduction composite written as
*one block* is also legitimate (and matches the corpus's own framing). The automatic loop-fusion
pass is a **measured optimization**, deferred — not core.

---

## 6. Feedback, cycles, and persistent state

### 6.1 The `z⁻¹` rule (universal across Web Audio / Max / Pd / JUCE)
A back-edge is legal **iff** its cycle (SCC) contains ≥1 delay element. Split a feedback edge into a
**write side** (produced this block) and a **read side** (value from the *previous* block). The
topological sort runs on the DAG-minus-feedback-edges (cleanly resolving ZigRadio's
`CyclicDependency`). The graph-commit pass **verifies every SCC contains a delay**, else
`error.DelayFreeLoop` (Rule 12). Default feedback latency = one block (the graph-level
`DelayLine`-in-a-cycle idiom: one-block-latency but fully composable / scheduler-visible).

**Blessed idiom for tight (sample-accurate) feedback — the fused single-`Map` kernel.** Where a
back-edge's one-block latency is too coarse (ladder filters, Karplus-Strong, comb), the tight loop
is authored as a **single rate-1:1 `Map` block whose `process` runs the per-sample feedback loop
internally** over fixed persistent state (§6.2). The `z⁻¹` lives *inside* the kernel, per-sample,
not across the colorer's block granularity — so the feedback is **sample-accurate**. The trade is
explicit: you **forfeit scheduler-visibility** (the loop is opaque to the colorer — it cannot be
fused/split across the loop) **in exchange for sample-accuracy**. This is distinct from the
graph-level `DelayLine`-in-a-cycle idiom above (one-block-latency but composable). Such fused
kernels are typically **not** `aliasing_safe` (state-dependent read/write ordering makes aliasing
unsafe), so they must not declare it. pan ships **ladder / Karplus-Strong / comb** as fused
single-block library kernels on this pattern
([`pan_categorical_bridge_and_roadmap.md` §2](pan_categorical_bridge_and_roadmap.md)); a
block-size-1 *subgraph* combinator (composing tight feedback from sub-blocks) is **explicitly
deferred** as a layered library subject to a real use case (Rule 2).

### 6.2 Persistent buffers are *state*, not scratch
The delay buffer for a feedback edge — and a `Framer`'s overlap ring, and any cross-frame history
(delta cepstra, flux previous-spectrum, leaky maxes, tempo hypotheses) — has a live range **spanning
callbacks**. These are a **distinct, pool-excluded category**: allocated once at `initialize`,
persisting across the hot path. The library ships a canonical **element-generic** `UnitDelay(z⁻¹)` /
`DelayLine(len)` primitive — over `Sample`/`Frame`/`Complex`/`FeatureFrame` ([`catalog.md` §5.5](catalog.md))
— so reverbs (comb/all-pass; **FDN = N delay lines + a matrix-mix `Map` over `Frame(Lane,.discrete(N))`**),
Karplus-Strong, feedback IIR, and **frame-/spectrum-granular feedback** (`UnitDelay(Complex)` /
`UnitDelay(Frame(Lane,L))`) are expressible *and* safe. *(Symbol note: in `Frame(Lane, L)` the second
parameter is the channel **layout** §1.3; in `DelayLine(len)` it is the delay **length** — distinct
local bindings.)* Synth **voice pools** (`PolyVoice`, [`catalog.md` §8.12](catalog.md)) and instrument
**assets** (wavetables, sample sets, impulse responses) are likewise persistent (pool-excluded) —
allocated once at `initialize`, sized by a comptime capacity. A **parameter port's ramp/hold state**
(the previous/target value smoothed across the buffer, [`catalog.md` §2.4 P3](catalog.md)) is likewise
persistent (pool-excluded), allocated once at `initialize`.

### 6.3 State-update granularity (audit S6)
When a block is rendered in two sub-blocks per hop (events, §[exec 4.2](pan_execution_model.md)),
"one frame of history" must update once per **hop/frame**, not once per **render call**. Spec
obligation + a Yoneda test: *"delta history updates once per hop regardless of sub-block count."*

---

## 7. Plugin-delay-compensation (PDC), folded into the same pass

Each block declares `algorithmic_latency` (0 for pure `Map`). The commit pass does a longest-path DP
over the DAG: `latency[node] = max over inputs(latency[src] + edge_delay)`; at each fan-in it inserts
a compensating `DelayLine` on the shorter paths so signals re-align sample-accurately. Following
JUCE, this **folds into the buffer-assignment pass** (the `needsDelay` flag): the compensating delay
lines are allocated from the persistent category (§6.2) and baked into the op-list. PDC must operate
**per rate-domain** (audit S7): a diamond fan-in whose branches are a time-domain ZCR path and an
FFT-latency spectral path aligns in the *feature-frame* rate domain, not just the audio domain.
Requires a **static** reported latency per block (DAWs disagree on variable-latency plugins; pan
mandates static — a `Rate` block reports worst case).

**Bypass is a PDC-relevant state change.** Per the *bypass-preserves-latency* law
([`pan_io_realtime_and_pipeline.md` §7](pan_io_realtime_and_pipeline.md)), bypassing a latent block
must **keep its compensating delay active** — a bypassed block with `algorithmic_latency > 0` must
still delay its signal by exactly that latency (routing through the compensating `DelayLine` PDC
already allocated in the persistent category), else bypassing shifts timing and breaks alignment on
parallel paths. Built-in bypass honours this automatically; a custom bypass author must route
through the compensating delay.

---

## 8. Dynamic edits vs static coloring (T3)

- **Static within an epoch.** No incremental re-coloring on the hot path (would need allocation /
  re-analysis under the deadline — violates H2).
- **An edit builds a new committed plan off-thread** (new schedule, coloring, memory block), then
  the executor **atomic-swaps the plan pointer at a buffer boundary** (RCU); delay-line state is
  copied/ramped across the swap to avoid clicks ([exec §4.3](pan_execution_model.md)).
- **Pre-allocate to a configured max-M ceiling** so edits never *grow* the allocation; on heap-less
  embedded, declare the worst-case graph at init (no runtime epochs at all).
- **Parameter changes are live** (not topology) — handled by the control plane
  ([`pan_io_realtime_and_pipeline.md` §7](pan_io_realtime_and_pipeline.md)).
- **Device reconfiguration** (route switch changes N) re-sizes the *backing bytes* of each pool to
  the new max-N; the *assignment map* (which edge → which buffer id) is N-independent topology and is
  unchanged ([`pan_io_realtime_and_pipeline.md` §8](pan_io_realtime_and_pipeline.md)).

## 8a. Concurrency-aware coloring under the Tier-B parallel executor (COMMITTED 2026-06-03)

The locked text above warned that the parallel tier "contaminates the colorer (per-worker
privatization)." For a **static** Tier-B schedule (commit-time HEFT, [`catalog.md` §8.10](catalog.md))
this is **overstated** (Rule 7 — surfaced disagreement): with each op's start/finish fixed by the
schedule,

> two edges interfere **iff their producing/consuming ops' execution intervals overlap in the static
> schedule** — an **interval graph on the schedule-time axis**, so the §2 / [`catalog.md`
> §7.2](catalog.md) optimal linear-time left-edge coloring **still applies** (only the time axis changes
> from sequential topological order to scheduled wall-time).

Consequences ([`catalog.md` §8.11](catalog.md)):
- **`M_class` grows** to the peak *concurrent* live-edge count (a whole parallel span, not the 3–6 of a
  near-linear chain) → larger but **statically bounded** pools (H2 holds).
- **In-place coalescing (§3) gains a fourth condition: (iv) producer and consumer are not concurrently
  scheduled.** The `aliasing_safe` alias is honoured only for non-overlapping ops. ⊢ (decidable from
  the schedule).
- **Per-worker scratch.** Buffers internal to one op (a fused sub-chain's transients) are worker-local
  pools (`P` copies) — the `+ Σ_worker scratch(worker)` term in the footprint formula (§10).
- **The B≡C differential test (§9) extends to the parallel schedule** (the **parallel≡sequential
  differential test**, [`catalog.md` §8.10](catalog.md)): the colored pool under the concurrency-aware
  interference graph must produce output **bit-identical** to the per-edge double-buffer baseline *and*
  to Tier A (op-granular scheduling preserves per-op reduction order). Paranoid mode (NaN-poison
  released buffers) extends to catch a buffer reused before its last reader across the concurrency-aware
  graph. The **offline** colorer/footprint (rings + per-chunk pools, O2) is separate:
  [`pan_parallel_and_offline_execution.md` §3.6](pan_parallel_and_offline_execution.md).

---

## 9. Phasing and the differential-test correctness obligation

**Phasing (Rule 2):** ship the **simple per-edge double-buffer (mode B)** first as the correctness
baseline; turn on **coloring (mode C)** behind the *same* `getBuffer(edge)` interface once the graph
builder is solid — C is a drop-in optimization, not a rewrite.

**Correctness obligation (Rule 9):** in Debug/ReleaseSafe, a **paranoid mode** gives every edge its own
buffer and poisons released buffers to NaN; a **differential test** asserts B and C produce
**bit-identical** output. *The differential test is the PRIMARY CORRECTNESS CHECK for the colorer
implementation* — empirical evidence (it encodes *why* the optimization is sound), NOT a proof. The
coloring OPTIMALITY itself is a proven theorem (interval graphs are optimally colorable in linear
time; [`catalog.md` §7.2](catalog.md)); the B≡C test verifies the Zig implementation is faithful to
it ([`catalog.md` §7.5](catalog.md)). Add **aliasing tests** (in-place vs
non-aliased mux) and **B-vs-C** tests at the coloring gate; dispatch Yoneda test writers (Rule 14)
loading the `zig-0-16` skill (Rule 13). See
[`pan_categorical_bridge_and_roadmap.md` §3](pan_categorical_bridge_and_roadmap.md).

**Failure-message contract (the `aliasing_safe` enforcement, §3).** When the B≡C differential test
or paranoid mode catches a divergence on a block that declared `aliasing_safe = true`, the message
**names the assertion and quotes it back**, identifies the first divergent sample, and states the
fix — so a false safety claim reads as a falsified contract, not an opaque mismatch:

```text
error: aliasing hazard in block 'Gain(f32)' — output differs between pooled (mode C) and
       double-buffered (mode B) execution when in/out buffers are aliased.
   This block declared `pub const aliasing_safe = true`, asserting process() never reads an
   input element after the corresponding output element was written. That assertion is FALSE.
   first divergent sample: index 1024  (mode B = 0.5000, mode C = NaN under paranoid poison)
   fix: remove `aliasing_safe` (forfeits in-place coalescing) OR restructure the kernel so reads
        precede writes per lane.  see pan_memory_model.md §3.
```

---

## 10. Footprint formula (the H2 guarantee)

```
render_memory =  Σ_class  M_class · element_count_class · @sizeOf(element_type_class)   // pools
               + Σ_feedback  delay_length · @sizeOf(elem)                                // persistent
               + Σ_block  state_size                                                     // per-block
               + Σ_pdc  comp_delay_length · @sizeOf(elem)                                // PDC delays
```
All terms known at commit (at `comptime` on embedded) → **one up-front allocation, zero hot-path
alloc**. On heap-less MCUs this is a `comptime`-sized `[render_memory]u8` in `.bss` behind a
`FixedBufferAllocator` (skill ch.05). This is the concrete realization of hub invariant **H2**.

**Tier-B addendum (§8a).** Under the static-parallel executor, `M_class` is the peak *concurrent*
live-edge count and a per-worker scratch term is added: `+ Σ_worker scratch(worker)`. Both stay
commit-known and statically bounded → H2 holds. **OfflineBatch (O2)** uses a separate, larger-but-
pre-sized footprint (rings + per-chunk pools):
[`pan_parallel_and_offline_execution.md` §3.6](pan_parallel_and_offline_execution.md).

---

## 11. What the spec must pin down here

- The `Pool(class)` data structure and the linear-scan coloring algorithm, with the proof that
  per-class intervals form an interval graph (optimal linear-time coloring).
- The `aliasing_safe` validator's three conditions and the `noalias` placement rule.
- The `z⁻¹` split, the SCC-has-delay validator (`error.DelayFreeLoop`), and the persistent-buffer
  category boundary.
- The PDC longest-path DP and its per-rate-domain operation.
- The B≡C differential-test contract as the colorer implementation's PRIMARY correctness check
  (empirical; catalog §7.5).
