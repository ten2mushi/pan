# pan — Parallel & Offline Execution (the two execution modes)

> **Status: COMMITTED (phased) — 2026-06-03.** Promotes the previously-deferred scheduler Tiers B
> and C ([`catalog.md` §8.4](catalog.md)) to committed design under two dev-facing **execution
> modes**: **RealtimeStreaming** (Tier A single-core *and* Tier B static-parallel multicore) and
> **OfflineBatch** (Tier C throughput). Change-control: conforms to [`catalog.md`](catalog.md); an
> edit that changes a definition or law must update `catalog.md` and every citing section in the same
> commit. Support document for [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md)
> (the hub). Siblings: [`pan_execution_model.md`](pan_execution_model.md) ·
> [`pan_memory_model.md`](pan_memory_model.md) ·
> [`pan_concurrency_and_memory_ordering.md`](pan_concurrency_and_memory_ordering.md) ·
> [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md) ·
> [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).
>
> **Scope:** the **Executor** abstraction, the two execution modes, the **Tier B static-parallel RT
> executor** (commit-time HEFT schedule + point-to-point cross-worker sync + OS audio workgroup +
> concurrency-aware coloring + cost-model gate + auto-demote), and the **Tier C OfflineBatch path**
> (pipeline parallelism + data-parallel timeline chunking with `warmup_samples`). Realises new
> commitments **C6** (dual execution modes) and **C7** (static-parallel RT executor) of the hub, and
> the new **offline invariant set O1–O3**.
>
> **Decision provenance (AskUserQuestion 2026-06-03):** RT executor = static **HEFT + point-to-point
> ready-flags + audio workgroup** (Tier B level-barrier fork-join retained as the simpler evolution
> stage on the *same* foundation); offline = **pipeline parallelism *and* data-parallel chunking**;
> determinism = **bit-exact where the math allows** (Tier B ≡ Tier A bit-for-bit; offline pipeline
> bit-exact; offline chunking bit-exact for exact-warmup blocks, allclose within declared tolerance for
> IIR-chunked blocks); encoding = **new doc + coherent core amendment, committed & phased**.

---

## 0. Two execution modes — the dev-facing surface (C6)

A pan graph (the finite diagram in **Stream**, [`catalog.md` §3](catalog.md)) and its blocks are
**execution-agnostic by construction** — this is the operational payoff of the Yoneda/`SampleMux`
probe ([`catalog.md` §4.2](catalog.md)): a block is determined by its action on the buffers a mux
presents and **never knows which executor drives it.** The *same* graph definition therefore runs
under either of two **execution modes**, chosen once at engine instantiation:

| Mode | Driver | Deadline? | Invariants | Tiers | When |
|---|---|---|---|---|---|
| **RealtimeStreaming** | pull (clock-driven, [`catalog.md` §8.3](catalog.md)) | hard `N/Fs` | **H1–H3** | **A** (1 core) · **B** (P cores) | live audio, instruments, monitoring |
| **OfflineBatch** | push / input-exhaustion | none — throughput rules | **O1–O3** (§1) | **C** | file→file render, batch analysis, bounce |

The choice of mode and tier is the **Executor**, a triple computed entirely at commit:

```
Executor = (Schedule, Driver, MemoryPlan)

  Tier A  = (sequential,          pull/deadline,      sequential interval coloring)   — RealtimeStreaming, 1 core
  Tier B  = (static-parallel(P),  pull/deadline,      concurrency-aware coloring §2.5) — RealtimeStreaming, P cores
  Tier C  = (pipeline | chunked,  push/throughput,    per-stage rings | per-chunk pools) — OfflineBatch
```

**The mux family *is* the mode selector** ([`catalog.md` §4.1](catalog.md)). `PullSampleMux` (± the
parallel executor) realises RealtimeStreaming; `RingSampleMux` realises OfflineBatch. No block, no
`process`/`pull`, and no port type changes between modes. *Illustrative — Zig 0.16:*

```zig
// Same graph `g` built once; the MODE is an instantiation choice, not a graph property.
var rt  = try pan.Engine.init(gpa, g, .{ .mode = .realtime_streaming, .cores = .auto });   // Tier A or B
var off = try pan.Engine.init(gpa, g, .{ .mode = .offline_batch,      .threads = .auto }); // Tier C
```

> **Litmus (extends [`catalog.md` §11.1](catalog.md)).** The *graph and blocks* are mode-invariant
> (core, ⊢ by the typed-port surface). The *executors* are layered libraries — but each must
> **discharge the invariant set of its mode** (RealtimeStreaming ⇒ H1–H3; OfflineBatch ⇒ O1–O3).
> Those discharge obligations are core; the executor code is library.

---

## 1. The invariant split — RT (H1–H3) vs Offline (O1–O3)

RealtimeStreaming keeps the frozen invariants **H1–H3** ([`catalog.md` §11.1](catalog.md)) unchanged;
Tier B discharges them through §2. OfflineBatch runs under a **distinct, relaxed** set — because there
is no deadline, blocking is legal and the memory bound is throughput-shaped rather than callback-shaped:

| | Statement | Tier |
|---|---|---|
| **O1** | **No deadline; blocking is legal.** Offline worker/stage threads may lock, allocate, and block on bounded rings — throughput, not latency, is the objective. The RT prohibition (H1) does **not** apply. | declared; the whole point of the mode |
| **O2** | **Bounded, pre-sized footprint** = `Σ ring_depth·elem + Σ_worker pool(worker) + Σ_block state`. Larger than H2's per-callback bound (rings + per-worker/per-chunk pools) but **still pre-allocated** at commit — no unbounded growth. | **⊢** that the figure is a commit constant given ring depths and thread/chunk counts; **▷/≈** that stages/blocks honour it |
| **O3** | **Bit-reproducibility.** Offline output is **independent of thread count and scheduling** (Q3). Bit-identical to sequential for pipeline parallelism and for exact-`warmup` data-parallel chunking; allclose within each block's declared tolerance for IIR-chunked blocks (§3.5). | **⊢** ordered merge + fixed reduction order are decidable; **≈** the per-block numeric equality is differential-tested |

> O3 is the offline analogue of, and is *stronger* than, the RT determinism story: where RT Tier B is
> bit-exact to Tier A *by op-granular scheduling* (§2.8), offline must additionally make the
> **timeline partition** invisible — handled by ordered merge and exact warm-up (§3.5).

---

## 2. RealtimeStreaming multicore — Tier B (static-parallel, HEFT + point-to-point) (C7)

The locked corpus deferred Tier B for one correct reason: a **spin barrier busy-waits the RT thread,
and on M3's asymmetric P/E clusters macOS migrates threads with no userland core isolation → unbounded
worst case** ([`catalog.md` §8.4](catalog.md), [exec §5](pan_execution_model.md)). That reasoning holds
*for a naïve barrier on unmanaged threads*. Tier B as committed here removes the premise: the workers
are **members of the platform RT workgroup** (§4), which co-schedules them under the audio deadline and
does **not** deschedule one member while a peer waits — bounding every spin to *the longest single op*,
which already lives inside the WCET budget.

### 2.1 The shared foundation (also the substrate for the simpler Tier-B fallback)

Common to the committed HEFT executor and to the retained level-barrier fallback (§2.10):

- **Pre-spawned worker pool.** `P−1` worker threads spawned **once at engine init** (spawning is a
  syscall → never per-callback). The **audio callback thread participates as worker 0**, so all `P`
  cores — including the one already running the callback — do render work (no oversubscription).
- **Wake without an RT syscall.** Between callbacks workers **bounded-spin on a generation counter,
  then park on a futex** if idle beyond a threshold. At 48 kHz/128 frames callbacks arrive every
  ~2.7 ms, so in steady state workers stay in the spin phase; the audio thread only **bumps the
  generation atomically (release)** at callback start — workers see it with an acquire load, **no
  syscall on the RT critical path**. A cold worker that parked needs one futex wake (a syscall, but
  off the steady-state path; tolerated only at start/stop).
- **Realtime token ×P.** Every worker takes the realtime token ([`catalog.md` §10](catalog.md),
  [io §3](pan_io_realtime_and_pipeline.md)) on entry — FTZ/DAZ is **per-thread** on ARM64 (the Mixxx
  FPCR footgun), so it must be set on *each* worker, not just the callback thread. `renderInto` /
  the worker render entry **won't compile without the token** ⊢.
- **Workgroup membership.** Every worker joins the render workgroup (§4) before its first render.

### 2.2 Commit-time scheduling — work, span, HEFT

At commit (off-RT; at `comptime` on embedded, where it collapses — but Tier B is desktop/multicore
only, §4), over the render op-list ([`catalog.md` §8.2](catalog.md)):

1. **Cost model.** Estimate each op's WCET `c(op)` from a static per-kernel model on first commit, then
   refine with a telemetry EWMA of measured per-op CPU ([io §10](pan_io_realtime_and_pipeline.md)).
   Per-core-type costs (`c_P(op)`, `c_E(op)`) capture P/E asymmetry.
2. **Work and span.** `W = Σ_op c(op)` (total work); `S = ` longest weighted path through the
   DAG-minus-feedback-edges (the **critical path / span**). These two numbers drive the gate (§2.3).
3. **HEFT schedule.** Rank ops by **upward rank** (critical-path weight to the sinks); greedily place
   each on the worker (P- or E-core) giving the **earliest finish time** given already-placed
   predecessors. Output: a per-worker ordered op sequence `seq[w]`, and for each op the set of
   **cross-worker predecessors** it must wait on. List-scheduling is a **(2 − 1/P)-approximation** of
   the optimal makespan (Graham); HEFT is the standard refinement and is empirically within ~5–20% of
   optimal. ⊢ that the schedule is produced by a decidable commit-time pass; ≈ that its makespan is
   adequate (deadline-headroom telemetry).

> **Span is the hard floor.** No schedule beats `max(S, W/P)` (Brent/Graham). A near-linear chain has
> `S ≈ W` → parallelism buys nothing and the gate (§2.3) **must refuse** it. The win lives in graphs
> with `W/S ≫ 1` (many parallel voices/channels/partitions feeding a mix).

### 2.3 The cost-model gate (when to parallelize; choosing P) — ⊢ decidable

Tier B is enabled **only** when it helps. At commit (and re-evaluated on each `edit→commit` and on a
telemetry trigger):

```
parallelism      = W / max(S, W/P_max)         // achievable speedup ceiling
single_core_load = W / (deadline · target_headroom)
enable_tier_B    = (W > deadline · θ_busy)      // one core cannot keep up
                 AND (parallelism ≥ θ_speedup)  // the graph IS parallel (not a chain)
                 AND workgroup_available        // §4; else stay Tier A
P                = clamp(⌈single_core_load⌉, 1, available_cores)
```

`θ_busy`, `θ_speedup`, `target_headroom` are configured constants. If `enable_tier_B` is false the
executor is **Tier A** — the always-correct ground truth. This is the concrete form of the spec's
promised *"xrun-counter / deadline-headroom cost model"* gate ([`catalog.md` §8.4](catalog.md),
[io §10](pan_io_realtime_and_pipeline.md)). ⊢ (a decidable computation over commit-known `W`, `S`,
core count, and config).

### 2.4 Point-to-point cross-worker synchronisation — exact orderings

Same-worker dependencies are implicit in `seq[w]` order (no sync). A **cross-worker** edge uses one
release/acquire flag per producing op, keyed by the per-callback **generation** `g` (§2.1):

```zig
// Producer worker, on finishing op `p` (one store; no CAS, no barrier):
ready[p].store(g, .release);     // PUBLISH: release so a consumer that sees g also sees p's output buffer

// Consumer worker, before starting op `c`, for each cross-worker predecessor `p` of `c`:
while (ready[p].load(.acquire) != g) std.atomic.spinLoopHint(); // bounded: workgroup co-schedules p to finish
```

- **Release/acquire pairing** is the same idiom as the RCU plan publish
  ([`pan_concurrency_and_memory_ordering.md` §4](pan_concurrency_and_memory_ordering.md)): the producer's
  `.release` store of `ready[p]` orders its prior **pool-buffer writes** before the consumer's
  `.acquire` load — so the consumer reads a fully-written input. No CAS anywhere (each `ready[p]` has a
  single writer — the worker that owns op `p` this callback).
- **Generation `g`** disambiguates callbacks without clearing the flag array: a flag still holding last
  callback's `g−1` reads as "not ready," so no per-callback memset. `g` is bumped once by worker 0 at
  callback start.
- **Bounded spin (the load-bearing claim).** Under workgroup co-scheduling (§4) the producer is not
  descheduled while the consumer spins, so the spin is bounded by `c(p)` — already inside the WCET
  budget. This is **▷/≈, not ⊢** (it depends on the OS honouring the workgroup; §2.6).

### 2.5 Concurrency-aware coloring — the colorer refinement (amends C3)

The locked memory model warned Tier B "contaminates the colorer (per-worker privatization)"
([exec §5](pan_execution_model.md)). For a **static** schedule this is **overstated** (Rule 7 —
surfaced disagreement): with op start/finish times fixed by HEFT (§2.2),

> two edges **interfere iff their producing/consuming ops' execution intervals overlap in the static
> schedule.** That is an **interval graph on the schedule-time axis** → still **optimally `k`-colorable
> in linear time** by the left-edge algorithm ([`catalog.md` §7.2](catalog.md)).

So the *imported optimality theorem still applies* — only the time axis changes (from sequential
topological order to scheduled wall-time). Concrete consequences:

- **`M_class` grows** to the peak *concurrent* live-edge count (a whole parallel span, not the 3–6 of a
  near-linear chain). Footprint grows but stays **statically bounded → H2 preserved** ([`catalog.md`
  §7.8](catalog.md)).
- **In-place coalescing (§7.4) is disabled between concurrently-scheduled ops** (the `aliasing_safe`
  alias is honoured only when the producer/consumer do **not** overlap in the schedule). The three
  structural conditions ([`catalog.md` §7.4](catalog.md)) gain a fourth: **(iv) producer and consumer
  are not concurrently scheduled.** ⊢ (decidable from the schedule).
- **Per-worker scratch.** Buffers strictly internal to one op (a fused sub-chain's transients) are
  **worker-local pools**, `P` copies — a small bounded additive term in the footprint formula
  ([`catalog.md` §7.8](catalog.md): add `Σ_worker scratch(worker)`).
- **The B≡C differential test ([`catalog.md` §7.5](catalog.md)) extends** to the parallel schedule:
  the colored pool under the concurrency-aware interference graph must produce output bit-identical to
  the per-edge double-buffer baseline (§2.8).

### 2.6 Wait-freedom — the honest bound

Tier B's RT-side cost per callback: one generation bump (single RMW), `seq[w]` op replay, and the
point-to-point spins (§2.4). There is **no CAS-retry loop on any worker** (each `ready[p]` is
single-writer). Therefore:

- **⊢ (structural):** every Tier B RT primitive is a single atomic op or a fixed-shape store/load; no
  worker runs a CAS-retry or an unbounded loop *by the shape of the code*.
- **▷/≈ (the workgroup dependence):** the point-to-point **spin is bounded only while the OS honours
  the workgroup co-scheduling** (§4). This is a strictly weaker claim than Tier A's structural
  wait-freedom — Tier A has no spin at all. It is the same class of honesty bound as FTZ
  ([`catalog.md` §10](catalog.md)): a strong structural nudge, not a proof. Backed ≈ by **per-worker
  spin-time and deadline-headroom telemetry** (§2.7, [io §10](pan_io_realtime_and_pipeline.md)).
- **▷ (per-worker discipline ×P):** no block body, no op on any worker, may lock/allocate/syscall —
  now an authoring obligation across `P` threads, not one.

> **Why Tier A stays the frozen ground truth.** Tier B trades a structural ⊢ wait-freedom for a
> workgroup-conditional ▷/≈ one, in exchange for cores. The gate (§2.3) and auto-demote (§2.7) mean a
> system that *can't* honour the bound falls back to the provably-correct Tier A rather than risking an
> xrun. **Tier A is never removed; Tier B is an opt-in, measured overlay.**

### 2.7 Auto-demote to Tier A (telemetry-gated)

The engine watches **per-worker spin time** and **deadline headroom**. If Tier B's measured headroom
drops below a configured floor for `k` consecutive callbacks (hysteresis), the engine **demotes to
Tier A** at the next callback boundary by switching to the sequential plan (both plans are pre-built;
the swap is the RCU pointer swap of [`pan_concurrency §4`](pan_concurrency_and_memory_ordering.md)). It
re-promotes only after a stable headroom window. Demote/promote are **▷/≈** (policy + measured), never
on the hot path. This makes Tier B's risk *self-correcting*: the worst observed outcome is "runs as
Tier A," not "xruns."

### 2.8 Bit-exactness (Tier B ≡ Tier A) and the parallel≡sequential differential test

Because HEFT schedules **whole ops** (it never splits a single fan-in/reduction across workers), every
op reads its input buffer-ids in **fixed port order regardless of which worker produced them** — so the
floating-point reduction order is a property of the *op*, not the schedule. Therefore (Q3):

> **Tier B output is bit-identical to Tier A.** ⊢ that op-granular scheduling preserves per-op
> reduction order; ≈ that the implementation is faithful — the **parallel≡sequential differential
> test** (Tier B colored-parallel output vs. Tier A sequential output, bit-for-bit), the direct
> analogue of the B≡C colorer test ([`catalog.md` §7.5](catalog.md)). Paranoid mode (NaN-poison
> released buffers) extends to detect a cross-worker buffer reused before its last reader across the
> concurrency-aware interference graph.

### 2.9 Feedback, `Rate`, and parameter ports under parallelism (no new hazard)

- **Feedback / `z⁻¹`** parallelises cleanly: a back-edge's read side is the *previous* block's value
  (persistent state, [`catalog.md` §5.3](catalog.md)), so the loop carries **no intra-callback
  cross-worker dependency** — the delay breaks it. The SCC-has-delay law ([`catalog.md` §5.2](catalog.md))
  is unchanged.
- **`Rate` blocks** own internal clocked state ([`catalog.md` §2.2](catalog.md)); each op runs on
  **exactly one worker** per callback (static schedule), so a `Rate` block's ring is **never touched by
  two workers** — no new synchronisation. Multi-input pull ([`catalog.md` §8.8](catalog.md)) is
  satisfied by the cross-worker ready-flags (§2.4).
- **Parameter ports / parameter edges** ([`catalog.md` §2.4](catalog.md)) are ordinary in-graph edges
  for scheduling and coloring; a parameter edge crossing workers uses the same ready-flag. `set`/
  `schedule` remain control-plane mechanisms read once per block (unchanged).

### 2.10 Retained simpler stage — Tier B level-barrier fallback

The **level-barrier fork-join** executor (compute the ASAP level schedule the corpus already kept;
run each level across workers; atomic-countdown barrier between levels) is **retained as a simpler
evolution stage on the identical foundation** (§2.1, §4) — same worker pool, workgroup, realtime
token, and the *level-axis* concurrency coloring (interfere iff `[write_level, last_read_level]` spans
overlap — also an interval graph, the smallest colorer delta). It is **strictly dominated on makespan**
by HEFT+point-to-point for irregular ("wide→narrow→wide") graphs (a barrier waits for the slowest op
per level and cannot fill bubbles across levels), so it is **not** the committed default — but it is a
legitimate first implementation: ship the barrier, then swap in HEFT+point-to-point with no change to
the pool, workgroup, gate, colorer-axis machinery, or auto-demote.

---

## 3. OfflineBatch — Tier C (push / throughput)

OfflineBatch reuses the **same `Map`/`Rate` blocks** ([`catalog.md` §2](catalog.md)) via a different
mux — the inherited ring machinery finally earns its keep ([exec §5](pan_execution_model.md)). Two
parallelism levers compose (Q2): **pipeline parallelism** (exact, always available) and **data-parallel
timeline chunking** (scales with cores, needs `warmup_samples`).

> **Framing (▷) — both graph shapes batch here ([`catalog.md` §8.13](catalog.md)).** OfflineBatch
> serves both canonical shapes: an **Analyzer** (batch feature extraction of a file) and an
> **Instrument** (bouncing a MIDI/event timeline to an audio file — **O3-reproducible** when the event
> timeline and parameter automation are deterministic). The mode is purpose-agnostic; the determinism
> story below applies identically to both.

### 3.1 Driver and transport

Driven by a non-realtime clock source — `InputExhaustion(file)` or `WallClockTimer` at max rate
([`catalog.md` §8.3](catalog.md)) — through `RingSampleMux` ([`catalog.md` §4.1](catalog.md)). The
**transport** ([io §9](pan_io_realtime_and_pipeline.md)) provides the deterministic timeline
("render samples `[0, T)`") that makes O3 bit-reproducibility well-defined regardless of wall-clock.
Offline `N` may be **large** (64k+ frames) — no per-edge latency concern, so big blocks amortise
per-call overhead and feed the vectorizer long runs.

### 3.2 Pipeline parallelism (stage-per-thread + rings) — exact, deterministic

Map the committed op-list to **stages**, each stage on its own thread, connected by **bounded SPSC
rings** (`RingSampleMux`, the ZigRadio-verbatim push transport). Throughput = `1 / max_stage_time`
(the bottleneck stage); latency = `Σ ring_depth` (irrelevant offline). Exact and **bit-reproducible by
construction** (the same data flows through the same stages in the same order). Scales with the number
of stages, not cores — the floor when a block forbids chunking (§3.3). This is the Tier C the corpus
already sketched ([exec §5](pan_execution_model.md)), now committed.

### 3.3 Data-parallel timeline chunking + `warmup_samples` — scales with cores

Partition `[0, T)` into `K` chunks; render chunks **concurrently across all cores**; merge in order.
The hazard is **stateful blocks** (IIR, feedback, `Framer`, history): a chunk starting at sample `t`
needs the state the block *would* have had at `t`. Solution — each chunk is rendered with a **warm-up
lead-in** of `warmup_samples` discarded samples before its real output:

```
render chunk [t, t+L):  feed [t − warmup, t+L) ;  discard the first `warmup` output samples
```

- **FIR / STFT / any finite-memory LTI block:** `warmup_samples = impulse_response_len − 1` (or one
  frame of overlap) makes the chunk **bit-exact** to sequential — the discarded lead-in exactly
  reconstructs the boundary state.
- **IIR / feedback (infinite memory):** no finite warm-up is exact; `warmup_samples` is chosen so the
  residual boundary error is below the block's **declared tolerance** (the state has decayed by
  `warmup` samples). Output is **allclose within that tolerance**, not bit-exact (Q3, O3).

The scheduler chunks a sub-path **only** if every stateful block on it declares `warmup_samples`;
otherwise that path runs via pipeline parallelism (§3.2). Feedforward (stateless) blocks need no
warm-up. ⊢ that the chunker refuses to chunk a stateful block lacking the declaration (build/commit
error); ≈ that a declared `warmup` actually achieves bit-exactness (FIR) or the tolerance (IIR) —
differential-tested against the sequential render.

> **`VariRate` chunkability — the determinism split ([`catalog.md` §2.6 V4](catalog.md)).** A
> **`VariRate`** block ([`catalog.md` §2.6](catalog.md)) splits by its `ratio_source`. A
> **parameter-driven** `VariRate` (`ratio_source = .parameter`, deterministic automation) is
> **O3-reproducible** like any block, so with a declared `warmup_samples` it is **chunked normally**.
> A **controller-driven** `VariRate` (`ratio_source = .internal_controller` — the drift-ASRC's PI loop
> on a wall-clock FIFO, §10) is **≈-only**, inherently **not** bit-reproducible (the same class as
> clock drift): its output depends on a non-deterministic controller trajectory, so it is **not
> chunkable** — the chunker forces its path through **pipeline parallelism (§3.2)**, exactly as it does
> a stateful block lacking `warmup_samples` ([`catalog.md` §2.5 W1](catalog.md)).

### 3.4 The `warmup_samples` block contract (new field) — ⊢ presence, ≈/▷ accuracy

A new **optional** block declaration, sibling to `algorithmic_latency` ([`catalog.md` §2.2](catalog.md)):

```zig
pub const warmup_samples: usize;        // lead-in samples for exact (FIR/STFT) or tolerance-bounded
                                        // (IIR) data-parallel chunking. ABSENT ⇒ block is not chunkable.
pub const warmup_exact: bool = true;    // true: warmup reconstructs state exactly (bit-exact merge);
                                        // false: warmup is tolerance-bounded (IIR) — allclose merge.
```

- **Pure `Map` with no cross-sample state** (gain, waveshaper, per-frame feature maps): chunkable with
  `warmup_samples = 0`, `warmup_exact = true` — embarrassingly parallel.
- **`Map` with bounded memory** (FIR, biquad expressed as FIR, fused tight-feedback over `L` taps):
  `warmup_samples = L−1`, exact.
- **`Rate`** (`Framer`, resampler, STFT): `warmup_samples =` one analysis window / filter span, exact;
  declares `warmup_exact = true`.
- **IIR / FDN / long feedback:** `warmup_samples = ` decay-to-tolerance length, `warmup_exact = false`.
- **Absent:** the chunker treats the block as **not chunkable** (forces §3.2 pipeline on its path).

`warmup_samples` is **only meaningful in OfflineBatch** — it has no effect on RealtimeStreaming (which
never partitions the timeline). Presence/typing is ⊢; numerical accuracy of the declared value is a ▷
authoring obligation, ≈ differential-tested (§3.5).

### 3.5 Deterministic merge & O3

- **Ordered merge.** Chunks are written to their fixed timeline offsets and concatenated in **timeline
  order**, independent of completion order → the partition is invisible. ⊢ (ordered by sample index).
- **Fixed reduction order.** Fan-in/mix ops read inputs in fixed port order (as in §2.8) → no
  thread-order-dependent summation.
- **Bit-reproducibility (O3).** Pipeline (§3.2): bit-exact. Chunking (§3.3): bit-exact iff every
  block on the path is `warmup_exact = true`; otherwise allclose within the max declared tolerance on
  the path. The **offline differential test** asserts: *render with `K = 1` (sequential) ≡ render with
  `K = ncores` (chunked)* — bit-identical for exact paths, allclose for IIR paths. This is the offline
  sibling of the parallel≡sequential test (§2.8) and the B≡C test ([`catalog.md` §7.5](catalog.md)).

### 3.6 Offline footprint (O2)

```
offline_memory =  Σ_stage  ring_depth · element_count · @sizeOf(elem)     // pipeline rings (§3.2)
               +  Σ_chunkworker  pool(worker)                              // per-chunk render pools (§3.3)
               +  Σ_block  state_size · (concurrent_instances)            // per-active-chunk block state
```

All terms commit-known given ring depths, chunk-worker count `K`, and the graph — **pre-allocated, no
unbounded growth (O2)**. Larger than H2's per-callback bound by design (latency is free here); the
trade is throughput. Unlike RT, offline may use the heap freely (O1) — `RingSampleMux` rings and
per-chunk pools are ordinary allocations.

---

## 4. The render-workgroup HAL abstraction

Tier B's bounded-spin claim (§2.4, §2.6) rests on co-scheduling. This is exposed as a **third HAL
concern** alongside the Compute HAL and I/O HAL ([io §11](pan_io_realtime_and_pipeline.md)) — the
**Render-Workgroup HAL**, a thin target-mapped interface `{ create, join(token), leave }`:

| Target | Mapping | Bound source |
|---|---|---|
| **macOS (M3, dev)** | the CoreAudio device's `os_workgroup` (`kAudioDevicePropertyIOThreadOSWorkgroup`); workers `os_workgroup_join` it before first render, `os_workgroup_leave` at teardown | OS co-schedules workgroup members under the audio deadline; does not deschedule one while a peer runs |
| **Linux** | `SCHED_FIFO` (or `SCHED_DEADLINE`) RT-priority worker threads + CPU affinity / `isolcpus` / cpusets | the very userland core isolation macOS lacks — *safer* here |
| **embedded** | N/A — single core, or a fixed second-core static partition | no migration; partition is compile-time |

**Honest bound (▷/≈, mirroring the FTZ token, [`catalog.md` §10](catalog.md)).** The workgroup is a
**feasibility witness to verify at implementation**, not a proof: pan cannot prove the OS honours
co-scheduling, exactly as it cannot prove FTZ is still set after a user mutates FPCR. If the workgroup
is unavailable, the cost-gate (§2.3) keeps the engine on **Tier A**. The exact CoreAudio/`os_workgroup`
API surface is an implementation detail (C-interop via `extern`), to be confirmed on the target — the
**spec decision** (workers must be co-scheduled members of the device's RT workgroup) is what is
committed here.

---

## 5. Correctness-tier ledger delta (for [`catalog.md` §12](catalog.md))

**⊢ proven-by-construction / decidable-static**
- A14 cost-model gate is a decidable commit-time computation over `W`, `S`, cores, config (§2.3).
- A15 concurrency-aware coloring is interval coloring on the schedule-time axis (imported optimality
  theorem, [`catalog.md` §7.2](catalog.md)) (§2.5).
- A16 in-place coalescing gains the fourth condition "not concurrently scheduled" (§2.5).
- A17 Tier B op-granular scheduling preserves per-op reduction order ⇒ bit-exactness *eligible* (§2.8).
- A18 `warmup_samples` presence gates chunkability; chunking a stateful block without it is a
  commit/build error (§3.3, §3.4).
- A19 offline ordered merge + fixed reduction order ⇒ partition-invisible output (O3) (§3.5).
- A20 realtime-token-required on every worker (FTZ ×P won't compile without it) (§2.1).

**≈ tested (empirical)**
- B9 **parallel≡sequential differential test** (Tier B bit-identical to Tier A) (§2.8).
- B10 **offline differential test** (`K=1` ≡ `K=ncores`; bit-exact for exact-warmup, allclose for IIR)
  (§3.5).
- B11 HEFT makespan adequacy / deadline-headroom under Tier B (§2.2, telemetry).
- B12 workgroup actually bounds the cross-worker spin in practice (spin-time telemetry, xrun counters)
  (§2.6, §4).
- B13 declared `warmup_samples` achieves bit-exactness (FIR/STFT) or its tolerance (IIR) (§3.4).

**▷ conventional (authoring obligation)**
- C10 no-malloc/lock/syscall on **any** Tier B worker (H1 discipline ×P) (§2.6).
- C11 `warmup_samples` numerical accuracy is the author's claim (§3.4).
- C12 the OS honours workgroup co-scheduling (target-verified, not proven) (§4).
- C13 offline stages/blocks honour the O2 pre-sized footprint (§3.6).

---

## 6. Roadmap & success criteria (extends [bridge §5](pan_categorical_bridge_and_roadmap.md))

Ordered so each step proves a load-bearing claim before the next depends on it (Rule 4):

| # | Prototype | Proves | Success criterion |
|---|---|---|---|
| 8 | **OfflineBatch pipeline** (file → 3-stage `Map` chain → file via `RingSampleMux`). | Tier C push path; mode-invariance of blocks. | File→file render **bit-identical** to the Tier A sequential render of the same graph; throughput ≥ bottleneck-stage bound. |
| 9 | **Data-parallel chunking** + `warmup_samples` on one FIR and one IIR block. | The chunker, warm-up exactness, ordered merge (O3). | `K=ncores` render **bit-identical** to `K=1` for the FIR path; **allclose within declared tolerance** for the IIR path; near-linear speedup vs. cores. |
| 10 | **Render-workgroup HAL** (macOS `os_workgroup` join; Linux SCHED_FIFO+affinity). | §4 feasibility; bounded spin in practice. | A 2-worker spin handshake shows bounded wait under load; spin-time telemetry present. |
| 11 | **Tier B level-barrier fallback** (§2.10) on a wide graph (e.g. 16-voice bank → mix). | Foundation: pool, workgroup, level-axis coloring, gate. | Measured speedup on the wide graph; **B≡C parallel** differential test passes; zero xruns over 10 min; auto-demote to Tier A triggers under induced overload. |
| 12 | **Tier B HEFT + point-to-point** (swap the executor on the same foundation). | §2.2–2.8 committed default. | Beats the level-barrier makespan on a "wide→narrow→wide" graph; **parallel≡sequential bit-exact** (§2.8); cost-gate refuses a near-linear chain (`W/S≈1`). |

> **Dispatch Yoneda test writers (Rule 14)** at gates 8–12, instructing them to load the `zig-0-16`
> skill (Rule 13). Highest-value targets: the chunker + warm-up merge, the concurrency-aware colorer,
> the point-to-point sync, the cost-gate, the parallel≡sequential and offline differential tests, and
> the render-workgroup HAL. Give them the **code section to test, not the tests to write**.

---

## 7. What the spec must pin down here

- The **Executor = (Schedule, Driver, MemoryPlan)** triple and the two **execution modes**
  (RealtimeStreaming / OfflineBatch), selected at engine instantiation; blocks mode-invariant (§0, C6).
- The **offline invariant set O1–O3** distinct from H1–H3 (§1).
- The **Tier B foundation** (worker pool, generation-wake without RT syscall, realtime token ×P,
  workgroup membership) (§2.1); the **commit-time HEFT schedule** with `W`/`S` (§2.2); the
  **cost-model gate** and `P` selection (§2.3); the **point-to-point release/acquire ready-flag**
  orderings (§2.4); the **concurrency-aware interval coloring** and the fourth in-place condition
  (§2.5); the **honest wait-freedom bound** (§2.6); **auto-demote** (§2.7); **bit-exactness + the
  parallel≡sequential differential test** (§2.8); feedback/`Rate`/param invariance (§2.9); and the
  **level-barrier fallback** on the same foundation (§2.10).
- The **Tier C OfflineBatch** path: pipeline parallelism (§3.2), **data-parallel chunking +
  `warmup_samples`** (§3.3–3.4), deterministic ordered merge (§3.5), offline footprint O2 (§3.6).
- The **Render-Workgroup HAL** (`{create, join, leave}`; macOS `os_workgroup` / Linux SCHED_FIFO+aff /
  embedded N/A) and its honest ▷/≈ bound (§4).
- The **ledger delta** A14–A20 / B9–B13 / C10–C13 (§5) and the **roadmap** steps 8–12 (§6).

---

*Committed (phased) 2026-06-03 under the parallel-and-offline execution decision (AskUserQuestion
2026-06-03). Author: Claude (Opus 4.8) via Claude Code, with the `zig-0-16` skill loaded; all Zig
forms (atomics/orderings, `std.atomic.Value`, `@Vector`, `extern` C-interop) consulted against
`zig 0.16.0`. `os_workgroup` is cited as a feasibility witness to verify on the target, per the
corpus honesty convention.*
