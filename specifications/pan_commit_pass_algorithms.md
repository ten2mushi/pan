# pan — Commit-Pass Algorithms (the graph→op-list compiler, to implementation precision)

> **Status: LOCKED** (2026-06-03). Change-control: conforms to [`catalog.md`](catalog.md); an edit
> that changes a definition or law must update catalog.md and every citing section in the same commit.
> Support document for [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md)
> (the hub). Siblings: [`pan_execution_model.md`](pan_execution_model.md) ·
> [`pan_memory_model.md`](pan_memory_model.md) ·
> [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md) ·
> [`pan_io_realtime_and_pipeline.md`](pan_io_realtime_and_pipeline.md) ·
> [`pan_concurrency_and_memory_ordering.md`](pan_concurrency_and_memory_ordering.md) ·
> [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).
>
> Scope: the **graph-commit pass** rendered to pseudocode-precision — every stage of the pipeline
> ordering of [`catalog.md` §8.2](catalog.md), each with inputs / outputs / steps / complexity / tier,
> plus three fully-worked numerical examples (a dry/wet FFT diamond, a feedback comb, and a rejected
> delay-free loop) that exercise per-rate-domain PDC, per-class interval coloring, and the footprint
> formula together. This is the *how, to the algorithm* behind the conceptual passes of
> [`pan_memory_model.md`](pan_memory_model.md) (coloring, PDC, footprint) and
> [`pan_execution_model.md` §4](pan_execution_model.md) (the render op-list). The pipeline and its
> decisions are **already fixed** by the locked corpus; this document only renders them precisely. It
> does not re-decide anything.

---

## 0. The commit pass at a glance

The commit pass is the one-time, off-hot-path (at `comptime` on embedded — [`catalog.md` §8.5](catalog.md))
compilation of a *committed graph* into a flat **render op-list** + a **static footprint**. The hot path
then replays the op-list with zero graph walking ([`pan_execution_model.md` §4.2](pan_execution_model.md)).

The stage order is **fixed by [`catalog.md` §8.2](catalog.md)** and is not negotiable:

```
format-negotiate                         (§6 catalog — unification; coercion morphisms)
  → topo-sort (DAG minus feedback edges)  (§2 here)  ⊢
  → liveness                              (§3 here)  ⊢
  → per-element-class coloring            (§4 here)  ⊢ (optimality imported) / ≈ (impl: B≡C)
  → SCC-has-delay check (FULL graph)      (§5 here)  ⊢
  → PDC longest-path DP (per rate-domain) (§6 here)  ≈ (arithmetic) / ⊢ (insertion is decidable)
  → rate scheduling (needed_input → spec) (§7 here)  ⊢ (compilation) / ≈ (needed_input numerics)
  → buffer-id assignment + emit op-list   (§8 here)  ⊢
  → footprint                             (§9 here)  ⊢ (comptime constant for a comptime graph)
```

> **Ordering note (Rule 7).** [`catalog.md` §8.2](catalog.md) lists *PDC insertion* **before**
> buffer-id assignment, and SCC-check before PDC. We render exactly that order. PDC *inserts new
> nodes* (compensating `DelayLine`s from the persistent category), so liveness/coloring of the
> non-persistent edges is computed first on the user graph, then the persistent comp-delays are added
> to the footprint (they are pool-excluded — [`catalog.md` §5.3](catalog.md) — so they do not perturb
> the pool coloring already computed). Rate scheduling is the compilation of `needed_input` recursion
> into each op's `n_or_pull_spec`; it rides on the topo order and is finalized at emit. Where this
> sequencing matters numerically it is called out per stage.

---

## 1. INPUTS — the committed graph object

The pass consumes a **committed graph** (the output of `edit`→`commit`, [`catalog.md` §10](catalog.md)),
a finite diagram in **Stream** ([`catalog.md` §3](catalog.md)). Concretely:

```
CommittedGraph = {
  nodes      : []Node,         // in insertion order — the deterministic tie-break key (§2)
  edges      : []Edge,         // directed producer-port → consumer-port(s)
  feedback   : []FeedbackEdge, // EXPLICITLY declared back-edges (the z⁻¹ write/read split, §5)
}

Node = {
  id                  : NodeId,        // = insertion index
  kind                : Map | Rate,    // ⊢ comptime-classified (catalog §2)
  fn_ptr              : *const fn(...), // monomorphized kernel (precision-comptime, catalog §9.1)
  self_ptr            : *anyopaque,     // block state
  algorithmic_latency : usize,         // 0 for pure Map; worst-case for Rate (catalog §7.7)
  out_per_in          : Ratio,         // 1:1 for Map; rational p:q for Rate (catalog §2)
  rate_domain         : RateDomainId,  // which clock grid this node's I/O lives on (§6)
  aliasing_safe       : bool,          // M4 author assertion (catalog §2.1) — ▷/≈
  state_size          : usize,         // per-block persistent state bytes (footprint term)
}

Edge = {
  src : PortId,   // producer output port (carries element type A — catalog §1.3)
  dst : []PortId, // one-or-more consumer input ports (fan-out)
  class : ClassKey = (element_type, element_count),   // the POOL key (catalog §1.3 / §7.2)
}

FeedbackEdge = {                       // catalog §5.2 — the z⁻¹ split
  write_side : PortId,  // produced THIS block
  read_side  : PortId,  // value from the PREVIOUS block (persistent, pool-excluded — §5.3)
  // carries an in-cycle delay element (UnitDelay / DelayLine) — verified by §5
}
```

The `class` key `(element_type, element_count)` is the sub-tuple of `Format` of
[`catalog.md` §1.2](catalog.md): precision `T` and channel count `C` are *inside* `element_type`
(`Sample(T)`, `Frame(Lane,C)`, `Complex(T)`, …), so the pool keys off the element type directly. The
`out_per_in`/`algorithmic_latency` field presence is the comptime `Map`/`Rate` discriminator (R1,
[`catalog.md` §2.2](catalog.md)) and is assumed already validated on entry.

**Pre-stage (format-negotiate).** Before topo-sort, the negotiation pass of
[`catalog.md` §6](catalog.md) has already unified Formats along every edge and **inserted coercion
morphisms** (resampler / channel-matrix / cast / framer) where the user wired compatible-but-coercible
Formats, so that the diagram commutes. After this pre-stage **every edge's two endpoints agree on
`class`** — element-type/direction/channel identity is a ⊢ type error if violated (A1/A6,
[`catalog.md` §6](catalog.md)). The algorithms below therefore assume a Format-consistent graph; the
inserted coercion nodes are ordinary `Map`/`Rate` nodes from here on.

---

## 2. TOPO — Kahn's algorithm on the DAG-minus-declared-feedback-edges  · ⊢ decidable

**Input:** `nodes`, `edges`, `feedback`.
**Output:** `topo : []NodeId` — a total order with op indices `0..nodes.len`, **deterministic**.

The schedule is computed on the **DAG with declared feedback edges removed** (the back-edge's *read
side* is satisfied from persistent state produced last block, so it imposes no scheduling order —
[`catalog.md` §5.2](catalog.md), [`pan_memory_model.md` §6.1](pan_memory_model.md)).

**Steps (Kahn):**

1. Build `indegree[v]` counting only **non-feedback** in-edges.
2. Seed a ready set with all `v` where `indegree[v] == 0`.
3. Repeatedly pop the ready node of **lowest `NodeId`** (= lowest insertion index), append to `topo`,
   and decrement `indegree` of its non-feedback successors; any successor reaching 0 enters the ready
   set.
4. If `topo.len < nodes.len` after the queue drains, a non-feedback cycle remains → this is an
   *undeclared* cycle (a wiring error distinct from a feedback loop) → `error.UndeclaredCycle`. (A
   *declared* feedback loop never reaches here because its back-edge was removed; its delay-freeness is
   checked in §5 on the full graph.)

**Deterministic tie-break — load-bearing.** The ready set is a **min-priority queue keyed by
`NodeId`** (insertion order), not a plain FIFO. This makes the op-list **bit-reproducible**: the same
committed graph always yields byte-identical ops, hence byte-identical offline render output
([`catalog.md` §10](catalog.md), transport: "offline render is bit-reproducible regardless of
wall-clock"). Two valid topological orders that differ only in independent-node ordering would
otherwise produce two different (but equally correct) op-lists; pinning the tie-break removes that
freedom.

**Complexity:** `O(V + E)` time, `O(V)` extra space; the priority queue adds an `O(log V)` factor →
`O(V + E·log V)`, negligible at commit time. **Tier ⊢** — topological sortability and the cycle
rejection are decidable static facts.

---

## 3. LIVENESS — per-edge live ranges over op indices  · ⊢ decidable

**Input:** `topo`, `edges`, `feedback`; the op-index `idx(v)` of each node = its position in `topo`.
**Output:** for each **pool-eligible** edge an interval `[start, end]`; the **persistent**
(pool-excluded) set separately.

The compiler-analogy ([`catalog.md` §7.1](catalog.md), [`pan_memory_model.md` §1](pan_memory_model.md)):
an edge is a virtual register, its live range is `[producer writes … last consumer reads]`.

**Steps:**

1. **Pool-eligible edge** `e` with producer `p` and consumers `C`:
   ```
   start(e) = idx(p)
   end(e)   = max over c in C of idx(c)     // fan-out extends to the LAST reader (catalog §7.3)
   ```
   A fan-out edge (`|C| > 1`) therefore stays live across the whole parallel span and **forbids
   in-place** by the first reader ([`catalog.md` §7.3](catalog.md), [`pan_memory_model.md` §4](pan_memory_model.md)).
2. **Persistent / pool-excluded category** ([`catalog.md` §5.3](catalog.md),
   [`pan_memory_model.md` §6.2](pan_memory_model.md)) — live range is the **whole callback**, so these
   are never colored and never enter the interval set:
   - feedback **read-side** buffers (the `z⁻¹` value from the previous block);
   - `Framer` / STFT overlap **rings**;
   - cross-frame **history** (delta cepstra, flux previous-spectrum, leaky maxes, tempo hypotheses);
   - PDC **compensating delays** (added in §6 — also persistent).
   Each contributes to the footprint's persistent / PDC terms (§9), not to any pool's `M_class`.

**Interval convention (pinned).** Ends are **inclusive** op indices, and the coloring free-test (§4)
is `previous_end < this_start`. Consequence: an edge ending *at* op `k` and another starting *at* op
`k` **do overlap** (the producer of the second runs at op `k`, while the first is still being read at
op `k`) → they receive different buffers. This is the faithful single-shot-render semantics and is
what the worked examples (§10–§11) rely on.

**Complexity:** `O(E)` (one pass; `max` folds over each edge's consumer list). **Tier ⊢.**

---

## 4. PER-CLASS LEFT-EDGE INTERVAL COLORING  · ⊢ optimality (imported) / ≈ implementation (B≡C)

**Input:** the pool-eligible intervals from §3, each tagged with its `class` key.
**Output:** per edge a **buffer id (color)** within its class; per class `M_class` = colors used.

**Steps:**

1. **Group by class** `(element_type, element_count)` ([`catalog.md` §7.2](catalog.md)). Across-class
   interference is impossible — different element types can never alias — so each class is colored
   **independently**. This across-class disjointness is **⊢ by type**
   ([`catalog.md` §7.5](catalog.md)).
2. **Within a class, left-edge algorithm** (the classic interval-graph colorer):
   ```
   sort intervals by start (deterministic: ties broken by edge id, itself topo-derived)
   for iv in sorted:
       reuse the lowest color c whose last-assigned interval ended < iv.start  (a "free" color)
       else allocate a new color
       assign iv → c ;  record end(c) = iv.end
   M_class = number of colors allocated
   ```
   Buffers within a class are identical size, so the live ranges are **intervals**, the interference
   graph is an **interval graph**, and the left-edge algorithm colors it with exactly `M_class = max
   clique = max simultaneously-live edges` colors.

**Optimality theorem (⊢, imported — [`catalog.md` §7.2](catalog.md)).** An interval graph is
*perfect*; its chromatic number equals its maximum clique, and the left-edge / endpoint-sweep
algorithm achieves it in linear time. This is a graph-theory theorem about the *algorithm*; pan
imports it. **It is NOT a claim that the Zig implementation is bug-free** — that is the **B≡C
differential test** (≈, [`catalog.md` §7.5](catalog.md), [`pan_memory_model.md` §9](pan_memory_model.md)):
mode B (per-edge double buffers, obviously correct) vs mode C (colored pool) must produce bit-identical
output, with paranoid mode poisoning released buffers to NaN. The B≡C test is the *primary correctness
check* for the colorer implementation — empirical evidence, not a proof.

**Heterogeneous *counts* within one class (rare).** When one class holds buffers of differing
`element_count` (so they are not all the same size), the problem degrades toward heterogeneous interval
bin-packing. Because `M ≤ ~8` for all realistic graphs, the pass uses **first-fit-decreasing / brute
force at commit** — optimal-enough at zero hot-path cost ([`catalog.md` §7.2](catalog.md), LOCKED). The
common case (one count per class) is the pure linear left-edge above.

**In-place coalescing (gated, §7.4 catalog).** A unary `Map` edge may be assigned its input's buffer
**iff** the validator ⊢-proves (i) single consumer, (ii) identical element type & count in==out, (iii)
the consumer reads before any other producer overwrites — **and** the block declares `aliasing_safe`
([`catalog.md` §2.1](catalog.md) M4). The three structural conditions are ⊢; the `aliasing_safe`
assertion is ▷/≈. `noalias` is emitted **only** on the proven-non-aliased path. Forgetting
`aliasing_safe` costs a memcpy (safe); asserting it falsely is a falsified contract caught by B≡C with
the [`pan_memory_model.md` §9](pan_memory_model.md) quote-back message.

**Complexity:** `O(E·log E)` (sort) `+ O(E·M)` (linear scan with `M ≤ ~8`) per class → effectively
`O(E·log E)`. **Tier:** optimality ⊢ (imported); implementation faithfulness ≈ (B≡C).

> **Comptime note.** The colorer is comptime-evaluable: the loop is bounded by `intervals.len` (a
> comptime-known slice length for a comptime graph) and the color-tracking array is sized by the same
> bound; no allocator is involved (see §10's verified snippet). On the desktop runtime-commit path it
> runs at commit with a `FixedBufferAllocator`-backed scratch; the algorithm body is identical.

---

## 5. SCC-HAS-DELAY — Tarjan on the FULL graph  · ⊢ decidable ([`catalog.md` §5.2](catalog.md))

**Input:** `nodes`, `edges` **and** `feedback` — the **full** graph, feedback edges *included* (unlike
topo, §2, which removed them).
**Output:** accept, or `error.DelayFreeLoop` naming the cycle nodes.

The trace of a traced monoidal category is well-defined only for a guarded (contractive) map — i.e.
only if the loop contains a delay ([`catalog.md` §5.2](catalog.md)). Operationally: a back-edge is
legal **iff** its SCC contains ≥1 delay element.

**Steps (Tarjan's SCC):**

1. Run Tarjan over the **full** edge set (including each feedback edge's write→read closure) →
   strongly-connected components.
2. For each **nontrivial SCC** (≥2 nodes) **and** each **self-loop** (a node with a feedback edge onto
   itself): scan its member nodes for ≥1 **delay element** (a `UnitDelay(z⁻¹)` / `DelayLine(L)`, or a
   fused tight-feedback kernel whose internal `z⁻¹` is declared — [`catalog.md` §5.4](catalog.md)).
3. If a nontrivial SCC (or self-loop) has **no** delay member →
   `error.DelayFreeLoop` **naming the cycle nodes** (Rule 12: fail loud).

**What is ⊢ vs not** ([`catalog.md` §5.2](catalog.md)): *every cycle contains ≥1 declared delay at
commit* is **⊢** (decidable: SCC detection + delay-membership). That the declared delay is the
*correct length* for the application's causality, or that a fused kernel's internal delay is
sample-accurate, is **▷/≈** (opaque to the commit pass).

**Complexity:** `O(V + E)` (Tarjan) `+ O(V)` (delay-membership scan). **Tier ⊢.**

---

## 6. PDC — longest-path DP, per rate-domain  · ⊢ insertion decidable / ≈ arithmetic across topologies

**Input:** `topo`, the per-node `algorithmic_latency`, `out_per_in`, `rate_domain`; the per-edge
delay (`edge_delay`, 0 except where an explicit delay node sits on the edge).
**Output:** an augmented graph with **compensating `DelayLine`s** inserted on the shorter inputs of
each fan-in, so that signals re-align sample-accurately ([`catalog.md` §7.7](catalog.md),
[`pan_memory_model.md` §7](pan_memory_model.md)).

**Steps:**

1. **Longest-path DP in topo order.** For each node in `topo`:
   ```
   latency_in[node]  = max over input edges (src → node) of
                         ( latency_out[src] + edge_delay(src→node) )      // 0 if no inputs
   latency_out[node] = latency_in[node] + node.algorithmic_latency
   ```
   This is a single forward sweep (topo order guarantees all `src` are resolved before `node`).
2. **Per rate-domain operation (load-bearing — audit S7).** Latencies live in **samples of a specific
   rate domain**. When an input edge crosses a rate boundary (e.g. an STFT path's latency is expressed
   on the *feature-frame* hop grid while a sibling path is on the *audio* grid), convert each input's
   `latency_out[src]` **into the fan-in node's rate domain** before taking the `max`:
   ```
   latency_in[node] = max over inputs of
                        convert(latency_out[src], from = rate_domain[src], to = rate_domain[node])
                        + edge_delay
   ```
   `convert` scales by the rate ratio between the two domains (`out_per_in` accumulated along the
   path). A diamond whose branches are a time-domain path and an FFT-latency spectral path therefore
   aligns in the **correct** domain, not naively in the audio domain.
3. **Insert compensating delays at each fan-in.** For a node with inputs `i` of (converted) latency
   `Lᵢ` and `Lmax = max Lᵢ`, on **each shorter input** insert a `DelayLine` of length
   `(Lmax − Lᵢ)` **in that input's rate domain**. These comp-delays are allocated from the
   **persistent / pool-excluded category** ([`catalog.md` §5.3](catalog.md)) — they do not perturb the
   §4 pool coloring; they add a PDC term to the footprint (§9).
4. **Static only.** A `Rate` block reports a **static worst-case** `algorithmic_latency`
   ([`catalog.md` §7.7](catalog.md)); pan mandates static reported latency (variable-latency plugins
   are out). **Bypass-preserves-latency** ([`catalog.md` §10](catalog.md)): a bypassed block with
   `algorithmic_latency > 0` keeps routing through its already-allocated compensating `DelayLine`, so
   bypass never shifts timing on parallel paths. Built-in bypass honors this ⊢; custom bypass is ▷.

**Complexity:** `O(V + E)` for the DP `+ O(fan-in count)` insertions. **Tier:** the *insertion
decision* (where a comp-delay goes, and its length) is a decidable static computation; the *arithmetic
correctness across topologies* (that the chosen lengths actually re-align the signals) is **≈ tested**
(B6, the dry/wet-diamond latency test, [`catalog.md` §12.2](catalog.md)).

---

## 7. RATE SCHEDULING — compiling `needed_input` into op order + `n_or_pull_spec`  · ⊢ compilation / ≈ numerics

**Input:** `topo`, each node's kind, `out_per_in`, `needed_input` ([`catalog.md` §2.2](catalog.md)),
and the root demand `want = N` (the device callback's N frames — [`catalog.md` §8.1](catalog.md)).
**Output:** for each op, its `n_or_pull_spec` (how many samples it produces/consumes this callback),
in the finalized op order.

The pull contract is demand-driven ([`pan_execution_model.md` §2.3](pan_execution_model.md),
[`catalog.md` §8.3](catalog.md)): the root asks its sink for `N`; each node asks each input edge's
producer for `producer.needed_input(want)` and recurses upstream.

**Steps:**

1. **Demand propagation (reverse topo).** Starting from each `PullRoot`'s sink with `want = N`, walk
   **upstream** in reverse-topo order. For a `Map`, `needed_input(want) = want` (rate-1:1, M1). For a
   `Rate`, `needed_input(want)` is the block's declared function (e.g. a hop-`H` `Framer` needs
   `want·H` input samples — modulo its ring fill, R3). Record each edge's required count
   `want_edge`.
2. **Compile to op order.** Because the op-list executes **upstream-before-downstream**
   (forward-topo), each op's `n_or_pull_spec` is the `want` resolved for *its* output(s) in step 1.
   For a `Map` op the spec is simply the slice length `n` (`out.len == in.len`, M1). For a `Rate` op
   the spec is a **pull spec**: `pull(want, out)` driven by the downstream `want`, with the block's
   internal ring absorbing any surplus/deficit. The scheduler emits ops in forward-topo order so that
   when a `Rate` op runs, its inputs are already present in their pool buffers
   ([`pan_execution_model.md` §3](pan_execution_model.md): pull `updateInputBuffer` is a no-op because
   upstream rendered first).
3. **H ∤ N absorbed by the ring (T4, [`catalog.md` §9.3](catalog.md)).** The scheduler **never assumes
   `H | N`**. A `Framer`/`Rate` block owns an internal ring that absorbs hop-vs-device-buffer
   misalignment; across callbacks the ring carries the remainder. The scheduler simply forwards the
   downstream `want` and the declared `needed_input`; correctness of the absorption is the block's
   ring, not the scheduler's arithmetic. Forcing `N ≡ 0 (mod H)` is **rejected** (would couple device
   buffer size to algorithm internals).
4. **Sub-block rendering (events).** When the event lane ([`catalog.md` §8.6](catalog.md)) splits a
   callback at offsets `[0,k), [k,N)`, each sub-block is "just a shorter `n` over a prefix of the same
   buffers" — free for `Map` by M2; a `Rate` quantizes events to its hop grid. The `n_or_pull_spec`
   is parameterized by the sub-block length, not re-derived.

**Complexity:** `O(V + E)` (one reverse walk + one forward emit). **Tier:** the *compilation* of the
recursion into op order is ⊢ (deterministic, decidable); the *numerical soundness/monotonicity* of
each `needed_input` (R3) is **≈ tested** (latency-contract + dual-mux, B4/C8, [`catalog.md` §12](catalog.md)).

---

## 8. EMIT — buffer-id assignment + the render op-list  · ⊢

**Input:** `topo`, per-edge colors (§4), `n_or_pull_spec` (§7), node `fn_ptr`/`self_ptr`.
**Output:** `plan.ops : []RenderOp`.

**Buffer-id assignment.** Each pool-eligible edge's `(class, color)` pair maps to a concrete buffer id
= an index into `Pool(class)` ([`catalog.md` §8.2](catalog.md),
[`pan_execution_model.md` §4.1](pan_execution_model.md)). Persistent buffers (feedback read-sides,
rings, history, PDC comp-delays) get ids in the persistent region (pool-excluded). The
assignment map is **N-independent topology** — a device-N change resizes the *backing bytes* of each
pool but leaves the edge→buffer-id map unchanged ([`pan_memory_model.md` §8](pan_memory_model.md)).

**Emit, in forward-topo order:**

```
RenderOp = {
  fn_ptr            : *const fn(self,in,out,n) ,  // monomorphized Map/Rate kernel (catalog §9.1)
  self_ptr          : *anyopaque ,
  input_buffer_ids  : []BufferId ,                // indices into per-class pools (gather)
  output_buffer_ids : []BufferId ,                // (scatter)
  n_or_pull_spec    : NSpec ,                     // §7: slice length (Map) or pull spec (Rate)
}
```

The hot path is then exactly ([`pan_execution_model.md` §4.2](pan_execution_model.md)):

```
for op in plan.ops:
    op.fn_ptr(op.self_ptr, gather(op.input_buffer_ids), scatter(op.output_buffer_ids), op.n_or_pull_spec)
```

— zero graph walking, one indirect call per buffer per block (free; devirtualizes; fully inlined on
embedded). **Complexity:** `O(V + E)`. **Tier ⊢** (deterministic emission).

---

## 9. FOOTPRINT — the H2 static-memory figure  · ⊢ comptime constant for a comptime graph

**Input:** per-class `M_class` (§4), the persistent set (§3) and PDC comp-delays (§6), per-node
`state_size`.
**Output:** `render_memory : usize` — one number; for a comptime graph, a **comptime constant**.

The formula is verbatim [`catalog.md` §7.8](catalog.md) / [`pan_memory_model.md` §10](pan_memory_model.md):

```
render_memory =  Σ_class    M_class · element_count_class · @sizeOf(element_type_class)   // pools
               + Σ_feedback  delay_length · @sizeOf(elem)                                  // persistent
               + Σ_block     state_size                                                    // per-block
               + Σ_pdc       comp_delay_length · @sizeOf(elem)                             // PDC delays
```

All terms are known at commit (at `comptime` on embedded) → **one up-front allocation, zero hot-path
alloc** — a `comptime`-sized `[render_memory]u8` in `.bss` behind a `FixedBufferAllocator` on heap-less
MCUs. **Tier ⊢** that the figure is a commit/comptime constant for a comptime graph (the embedded smoke
gate, §8.5 catalog); **▷/≈** that every block actually pre-allocates and never allocates in `process`
(H2, [`catalog.md` §11.1](catalog.md)). **Complexity:** `O(classes + feedback + V + pdc)` — a single
sum.

---

## 10. WORKED EXAMPLE A — Dry/Wet FFT diamond (per-rate-domain PDC + interval coloring + footprint)

```
source → split ─┬─ dry:  Gain (algorithmic_latency 0)                          ─┐
                └─ wet:  STFT(frame=1024, hop=256) → SpectralGain → iSTFT       ─┴→ Mix → sink
```

**Parameters:** device `N = 512` audio frames, precision `f32`. `@sizeOf(f32) = 4`;
`@sizeOf(std.math.Complex(f32)) = 8` (verified against `zig 0.16.0`).

### 10.1 Format-negotiate + topo

All edges are Format-consistent after negotiation. Topo on the DAG (no feedback edges here) with the
insertion-order tie-break yields the op indices:

| op idx | node | rate domain |
|---|---|---|
| 0 | source | audio |
| 1 | split | audio |
| 2 | Gain (dry) | audio |
| 2 | STFT | feature-frame (hop 256) |
| 3 | SpectralGain | feature-frame |
| 4 | iSTFT | audio |
| 5 | *(PDC comp-delay on dry — inserted in §10.3)* | audio |
| 6 | Mix | audio |
| 7 | sink | audio |

(The two parallel branches at idx 2 are independent; the deterministic tie-break orders them by
insertion. We list both at "idx 2" for clarity; the linearized op-list assigns distinct positions, but
the *liveness intervals* below use the producer/last-consumer indices, which is what matters.)

### 10.2 The two element classes, live ranges, and `M_class`

Two classes appear (across-class disjoint, ⊢):

**Class `Sample(f32, 512)`** — `element_count = 512`, `@sizeOf = 4`. Pool-eligible intervals
(end-inclusive, §3):

| edge | producer→consumer | interval | left-edge color (buffer id) |
|---|---|---|---|
| src→split | 0→1 | [0,1] | 0 |
| split→Gain | 1→2 | [1,2] | 1 |
| Gain→compDelay | 2→3 | [2,3] | 0 |
| compDelay→Mix | 3→4 | [3,4] | 1 |
| iSTFT→Mix | 3→4 | [3,4] | 2 |
| Mix→sink | 4→5 | [4,5] | 0 |

Max overlap is at the Mix fan-in (op 3→4): the dry comp-delay output, the iSTFT output, **and** the
freshly-produced edges coexist → **`M_Sample = 3`**. (Verified by running the §4 left-edge algorithm
at comptime — see §10.5.)

**Class `Complex(f32, 257)`** — `element_count = N/2+1 = 257`, `@sizeOf = 8`. Spectral edges:

| edge | producer→consumer | interval | color |
|---|---|---|---|
| STFT→SpectralGain | 2→3 | [2,3] | 0 |
| SpectralGain→iSTFT | 3→4 | [3,4] | 1 |

End-inclusive overlap at op 3 (SpectralGain reads the STFT output at op 3 while producing its own
output at op 3) → **`M_Complex = 2`**.

### 10.3 PDC, per rate-domain

Longest-path DP (§6), latencies in **audio samples**:

- Dry path: `latency_out[Gain] = 0`.
- Wet path: STFT analysis adds the round-trip group delay of an STFT→iSTFT COLA pair = **one frame =
  1024 audio samples**. The spectral edges live on the **feature-frame** hop-256 domain; converting
  the wet branch's latency back into the **audio** domain at the iSTFT output gives `latency_out[iSTFT]
  = 1024` audio samples.
- At the **Mix** fan-in (audio domain): `Lmax = 1024`, dry input `L = 0`. Insert a compensating
  `DelayLine(1024)` on the **dry** input, in the **audio** rate domain (§6 step 2/3). It is
  **persistent / pool-excluded** ([`catalog.md` §5.3](catalog.md)) — it does **not** change
  `M_Sample`.

This is the dry/wet-diamond PDC test of [`catalog.md` §7.7](catalog.md) (B6, ≈): the dry path is
delayed by exactly the wet STFT+iSTFT algorithmic latency, aligned in the correct domain.

### 10.4 Footprint (the number)

```
pools:
  Sample(f32,512):  M=3 · 512 · 4  = 6144 bytes
  Complex(f32,257): M=2 · 257 · 8  = 4112 bytes
                                   ----------
                          pools  = 10256 bytes
PDC comp-delay (persistent):
  DelayLine(1024) Sample(f32): 1024 · 4 = 4096 bytes
per-block state:               Σ state_size  (STFT/iSTFT overlap rings + window tables — block-specific)
feedback persistent:           0 (no feedback edges)
                               ----------
render_memory (excl. per-block state) = 10256 + 4096 = 14352 bytes
```

**`render_memory = 14352 bytes + Σ_block state_size`** (the per-block term is the STFT/iSTFT ring &
window storage, which is block-implementation-specific and counted via each node's `state_size`). The
14352 figure is the pool + PDC contribution and is a **comptime constant** for this comptime graph.

### 10.5 Comptime-evaluability (verified)

The §4 left-edge colorer was run at `comptime` against `zig 0.16.0` on exactly the §10.2 intervals and
reproduced `M_Sample = 3`, `M_Complex = 2` and the color tables above. The loop is bounded by
`intervals.len` (comptime-known), the color-tracking array is sized by the same bound, and **no
allocator escapes comptime** — satisfying the [`catalog.md` §8.5](catalog.md) constraints. (Snippet
template in §12.)

---

## 11. WORKED EXAMPLE B — Feedback comb (SCC-has-delay + persistent buffer + coloring + footprint)

```
in → Sum → DelayLine(L) → Gain ──(declared feedback edge back into Sum)──→ out
```

**Parameters:** device `N = 256` audio frames, `f32`, delay length `L = 480` samples (a 10 ms comb at
48 kHz).

### 11.1 Topo (feedback edge removed) + SCC (full graph)

- **Topo** on the DAG-minus-feedback (§2): `in(0) → Sum(1) → DelayLine(2) → Gain(3) → out(4)`. The
  feedback edge `Gain → Sum` is removed for scheduling; its **read side** is satisfied from persistent
  state produced last block (the `z⁻¹` split, §5).
- **SCC on the FULL graph** (§5, Tarjan including the feedback edge): the back-edge closes the cycle
  `{Sum, DelayLine, Gain}` into one **nontrivial SCC**. Scanning its members for a delay element finds
  **`DelayLine(L)`** → the SCC contains ≥1 delay ⇒ **passes SCC-has-delay** (⊢, no
  `error.DelayFreeLoop`).

### 11.2 Liveness, coloring, persistent split

**Persistent (pool-excluded, §3/§5.3):** the `DelayLine(L)` storage — it *is* the feedback read-side
buffer; live range spans callbacks. **Not colored.**

**Class `Sample(f32, 256)`** pool-eligible edges (the forward chain):

| edge | producer→consumer | interval | color (buffer id) |
|---|---|---|---|
| in→Sum | 0→1 | [0,1] | 0 |
| Sum→DelayLine | 1→2 | [1,2] | 1 |
| DelayLine→Gain | 2→3 | [2,3] | 0 |
| Gain→out | 3→4 | [3,4] | 1 |

Chained single-consumer edges alternate two buffers → **`M_Sample = 2`** (the classic two-register
ping-pong; verified at comptime via §4). The feedback edge contributes **no** pool buffer (its read
side is the persistent `DelayLine`).

### 11.3 PDC

All forward nodes are rate-1:1; `DelayLine` is a deliberate signal delay, not algorithmic latency to
compensate. No fan-in of unequal-latency branches ⇒ **no compensating delays inserted**.

### 11.4 Footprint (the number)

```
pools:
  Sample(f32,256):  M=2 · 256 · 4  = 2048 bytes
feedback persistent:
  DelayLine(480) Sample(f32): 480 · 4 = 1920 bytes
PDC:                          0
per-block state:              Σ state_size (Sum/Gain coefficients — small)
                              ----------
render_memory (excl. per-block state) = 2048 + 1920 = 3968 bytes
```

**`render_memory = 3968 bytes + Σ_block state_size`.**

---

## 12. WORKED EXAMPLE C — Rejected delay-free loop (`error.DelayFreeLoop`)

```
in → Sum → Gain ──(declared feedback edge back into Sum)──→ out      // NO delay in the cycle
```

Same shape as Example B with the `DelayLine` removed from the loop.

- **Topo** (§2, feedback removed): `in → Sum → Gain → out` — succeeds (the DAG-minus-feedback is
  acyclic).
- **SCC on the FULL graph** (§5): the feedback edge closes the cycle `{Sum, Gain}` into a nontrivial
  SCC. Scanning members for a delay element finds **none** (neither `Sum` nor `Gain` is a delay, and no
  fused tight-feedback kernel declares an internal `z⁻¹`).
- **Reject (Rule 12, fail loud):**

```text
error.DelayFreeLoop: feedback cycle has no delay element.
   cycle nodes: [ Sum#1, Gain#2 ]   (strongly-connected component, full graph)
   a feedback edge is legal only if its cycle (SCC) contains >= 1 delay element
   (UnitDelay/DelayLine, or a fused tight-feedback kernel with a declared internal z^-1).
   fix: insert a DelayLine/UnitDelay into the loop, or author the loop as a fused
        tight-feedback Map kernel.  see catalog.md §5.2, pan_memory_model.md §6.1.
```

This is the ⊢-decidable causality law of [`catalog.md` §5.2](catalog.md) (A4): the well-formedness
condition of the categorical *trace* (a guarded/contractive map) **is** the engineering rule. The pass
never reaches coloring/PDC/emit for this graph; it halts at the SCC stage.

---

## 13. COMPTIME-EVALUABILITY (catalog §8.5) — constraints and the smoke gate

The whole pass **must be comptime-evaluable** so embedded runs it at `comptime` (topology
comptime-fixed, all memory in `.bss` — [`catalog.md` §8.5](catalog.md)). The constraints each stage
above respects:

- **No allocator escaping comptime.** Stage scratch (indegree arrays, the colorer's free-color table,
  the DP latency arrays) is **fixed-size**, sized by comptime-known `nodes.len` / `edges.len` —
  stack/`comptime var` arrays, never a runtime allocator. (On the desktop runtime-commit path the same
  bodies run with a `FixedBufferAllocator`; the algorithm is identical.)
- **Bounded comptime loops.** Every loop is bounded by a comptime-known graph dimension
  (`nodes.len`, `edges.len`, per-class interval count, `M ≤ ~8`). No data-dependent unbounded
  iteration (Kahn drains a finite queue; Tarjan visits each node once; the DP is one topo sweep). This
  stays under Zig's comptime branch-eval quota for any fixed graph.
- **Typed constructors only** (0.16.0): if a stage builds types (e.g. monomorphized op tuples) it uses
  `@Struct`/`@Int`/etc. — `@Type` is removed. The colorer and DP shown here build only values, not
  types, so this is not exercised by them.

**The embedded smoke gate** ([`catalog.md` §8.5](catalog.md)) calls `commitComptime()` inside a
`comptime` block in a `ReleaseSmall` build (I2S source → gain → I2S sink): **the build compiling ⊢ is
the discharge; failing to compile is the loud failure.** A non-comptime-evaluable block is rejected
with the pan-level `comptime_commit_safe` error, not a raw Zig trace. **Honest bound:** this proves
comptime-evaluability **for the smoke graph**, not for arbitrary graphs (A5).

**Verified.** The §4 left-edge colorer was compiled and executed at `comptime` against `zig 0.16.0`
(reproducing the §10.2 / §11.2 `M` values and color tables). The 0.16.0 constraint actually hit: the
free-color table must be a **fixed-size array sized by the comptime interval count** with an explicit
`-1` "never used" sentinel (an `isize` array), because a runtime-growable container (`std.ArrayList`,
now unmanaged and allocator-taking — skill cheat-sheet) cannot be used in the comptime body without an
allocator escaping comptime. Index/`@intCast` between the `usize` interval ends and the `isize`
sentinel array is required. With that shape the body is fully comptime-evaluable.

---

## 14. What the spec must pin down here

- The **`CommittedGraph` / `Node` / `Edge` / `FeedbackEdge`** data shapes (§1) and that the pass runs
  **after** format-negotiation (so every edge agrees on `class`).
- **Kahn with the insertion-order (`NodeId`) min-priority tie-break** (§2) and the resulting
  **bit-reproducible** op-list; `error.UndeclaredCycle` vs the §5 feedback path.
- The **liveness interval convention** (end-inclusive, free-test `prev_end < start`, fan-out → last
  reader) and the **persistent / pool-excluded** category boundary (§3).
- The **per-class left-edge colorer**, the **interval-graph optimality** import (⊢) vs the **B≡C**
  implementation check (≈), across-class disjointness (⊢ by type), the FFD fallback for heterogeneous
  counts at `M≤8`, and the **three-condition + `aliasing_safe`** in-place gate (§4).
- **Tarjan on the full graph** + delay-membership → `error.DelayFreeLoop` naming the cycle nodes (§5).
- The **PDC longest-path DP**, the **per-rate-domain conversion** before `max`, comp-delay insertion
  from the persistent category, static-latency mandate, and bypass-preserves-latency (§6).
- The compilation of **`needed_input` recursion** into op order + each op's `n_or_pull_spec`, and that
  the scheduler **never assumes `H | N`** (the ring absorbs it — T4) (§7).
- The **`RenderOp`** record, **N-independent** buffer-id assignment, and the hot-path replay loop (§8).
- The **footprint formula** as a single commit/comptime constant (§9), and the two worked totals
  (Example A `= 14352 B + Σ state`; Example B `= 3968 B + Σ state`).
- The **comptime-evaluability constraints** (no allocator escaping comptime, bounded comptime loops,
  typed constructors) and the smoke gate as their discharge for the smoke graph (§13).

---

*Locked 2026-06-03 as part of the specification-locking pass. Author: Claude (Opus 4.8) via Claude
Code, with the `zig-0-16` skill consulted and the §4 colorer compiled/executed at `comptime` against
`zig 0.16.0` to verify the worked-example `M` values and comptime-evaluability.*
