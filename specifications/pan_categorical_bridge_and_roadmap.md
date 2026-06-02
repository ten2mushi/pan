# pan — Categorical Bridge, Block Taxonomy & Roadmap

> **Status: LOCKED** (2026-06-02). Change-control: conforms to [`catalog.md`](catalog.md); an edit
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
| Analysis pull roots | Additional clock-driven demand sources (**"terminal objects"** is **DECORATIVE NAMING only** — multiple clocked roots are not literally terminal objects; the engineering content stands). | Independent demand sources; non-RT root fed via SPSC tap ([exec §6](pan_execution_model.md); [`catalog.md` §8.3](catalog.md)). |

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

**Core primitives** (frozen — needed for H1–H3): `UnitDelay(z⁻¹)` / `DelayLine(L)` (feedback &
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
  ambisonic encode/decode.
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
- **Mix/routing:** summing mixer, splitter/fan-out, matrix router, dry/wet (with PDC).
- **Sources:** oscillators, noise, sampler/voice (event-driven).
- **Analysis (taps, non-RT root):** RMS/peak meter, FFT analyzer, the MFCC/perceptual-sparse/onset/
  dominant-band feature chains from `research/`, pitch/onset.

**Combinators** (comptime composite-builders, resolve audit S4 / §3.2):
- **`ChannelMap(comptime Sub: type, comptime C: usize) type`** — replicate a mono subgraph over C
  channels, stack outputs; coloring/negotiation replication-aware (M scales by C).
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

**Keep** the SciPy/NumPy gold-vector oracle (`generate.py` → `vectors/` → `BlockTester`) — it tests
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

---

## 5. Prototype plan (de-risk the most-uncertain pieces first)

Ordered so each step proves a load-bearing claim before the next depends on it. Each has a **success
criterion** (Rule 4) strong enough to loop on independently.

| # | Prototype | Proves | Success criterion |
|---|---|---|---|
| 1 | **Vertical slice:** CoreAudio sink + LPCM source + a 3-block pure `Map` chain (gain → biquad → pan) on **Tier A + pool mode B**. | The `PullSampleMux` + the callback render path. | Sub-5 ms measured round-trip on M3; zero xruns over 10 min; output bit-matches the SciPy oracle. |
| 2 | **Format negotiation** (rate/precision/channels/N) + **lock-free control plane** with one ramped parameter. | Negotiation/coercion insertion + RT-safe parameter update. | A wired rate-mismatch auto-inserts a resampler; a parameter sweep is zipper-free; no audio-thread lock. |
| 3 | **Feedback primitive** (delay → comb reverb). | The `z⁻¹` split, SCC-has-delay validator, persistent buffers. | A delay-free loop is rejected at commit (`error.DelayFreeLoop`); the reverb tail is stable; denormals don't spike CPU (FTZ set). |
| 4 | **Pool mode C (coloring)** behind the same `getBuffer` interface; **B≡C differential test**. | The colorer is correct and a drop-in optimization. | C output is bit-identical to B across the corpus; pool size = max-live-edges; paranoid mode finds no aliasing. |
| 5 | **A `Rate` block** (`Framer`+STFT or a polyphase resampler) + **latency accounting / PDC**. | The dual contract, `out_per_in` ≠ latency, dual-mux + latency-contract tests. | A dry/wet diamond around the FFT path re-aligns sample-accurately; the block passes both muxes. |
| 6 | **Analysis pull root** (file → MFCC/perceptual-sparse → `FeatureCollectorSink`) feeding the [`1.md`](../notes/1.md) viz. | Clock-driven roots (C5), typed feature ports, off-RT collection. | Per-hop feature matrix collected with no effect on a concurrent audio root's deadline. |
| 6b | **Embedded comptime-commit smoke gate:** call `commitComptime()` inside a `comptime` block in a `ReleaseSmall` embedded build on a minimal graph (I2S source → gain → I2S sink). | That the commit/coloring pass is genuinely comptime-evaluable end-to-end — the embedded "same code, specialized not forked" claim ([hub §7](pan_architecture_formalisation.md)). | The smoke graph **compiles** (compiling discharges the obligation **for the smoke graph** — not a proof for arbitrary graphs; [`catalog.md` §8.5](catalog.md)); `footprint_bytes` is a comptime constant. (Target may be stubbed `freestanding` until the SRAM-budget target is chosen, §4 item 6.) |
| 7 | *(deferred)* Offline **Tier C** push path; then evaluate **Tier B** only if an xrun-counter-gated cost model demands it. | The reused-block claim for offline; the (deferred) parallel tier. | File→file render bit-reproducible; Tier B only enabled when measured headroom < threshold. |

---

## 6. Risk register (carried, all mitigated by *making assumptions explicit and loudly tested*)

| Risk | Mitigation |
|---|---|
| Surface leak at the `Map`/`Rate` seam | Two explicit contracts (C1) + dual-mux testing (every block under push & pull). |
| Aliasing bugs from in-place coloring | Explicit `aliasing_safe`, paranoid mode (NaN-poison released buffers), B≡C differential tests (whose failure message quotes the `aliasing_safe` assertion back). |
| Monomorph-set creep on desktop | Explicit comptime active-precision list; log generated-monomorph count at build (Rule 12). |
| Dynamic edit vs static coloring | Off-thread recompile + atomic-RCU plan swap; pre-allocate to max-M; no runtime epochs on embedded (T3). |
| Heterogeneous-size coloring NP-hardness | Per-element-class pools → k independent optimal interval colorings (C3). |
| Tier-B nondeterminism on M3 P/E clusters | Cut from core; Tier A is the always-correct ground truth; B is gated behind a measured cost threshold. |
| Clock drift after 20 min | Adaptive ASRC + drift FIFO at the device boundary (§1 of the I/O doc), bypassed on single full-duplex clock. |
| Denormal CPU spikes / NaN poisoning | FTZ/DAZ set *on the audio thread* (ARM64 FPCR per-thread footgun); NaN guards + error isolation. |

---

## 7. One-line takeaway

The architecture is **B+ → A− once five things are committed**: the `Map`/`Rate` dual contract,
per-element-class colored pools, the Numeric trait, clock-driven pull roots, and the
compile-once/replay render op-list — at which point the categorical spec has honest mathematical
content, the embedded build is a pure comptime specialization, and the de-risking order above can
proceed with strong, loopable success criteria.
