# pan — Catalog (the single source of truth: semantics, terms, and laws)

> **Status: LOCKED** (2026-06-02). This document is the **single source of truth** the brief
> demands: every term used anywhere in the `specifications/` corpus is defined here, and every
> correctness-bearing claim is classified on the proven / tested / conventional spectrum. The six
> companion documents *refer to* this catalog; where a companion and this catalog disagree, **this
> catalog wins** and the companion is in error. Change-control: edits to a definition or a law here
> are breaking changes to the corpus and must be propagated to every citing section in the same
> commit.
>
> **Reading order:** see [`SPEC_INDEX.md`](SPEC_INDEX.md). This catalog is read **first**, then the
> hub [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md), then its five
> siblings.

---

## 0. Method: direction of truth, and the correctness-tier convention

### 0.1 The spec is the source of truth — code realises it (not the converse)

pan does not yet exist as code. This corpus is **prior to** the implementation: it states the
mathematical object and the obligations a conforming implementation must satisfy. Where an earlier
draft read as *reverse-engineered from* the ZigRadio source tree
(`/Users/komorebi/Documents/projects/tools/rf/zigradio/`), that direction is **inverted here**:
ZigRadio is cited only as **prior art establishing feasibility** — evidence that a comptime
type-signature port surface and a `SampleMux` seam *can* be built in Zig — never as the thing being
specified. Every claim that previously read "ZigRadio does X, so pan inherits X" is restated as the
obligation **"a conforming pan implementation must provide X"**, with ZigRadio noted as a feasibility
witness, not a definition. The brief is explicit: the category-theory specs are the single source of
truth from which code is generated; this catalog is that source.

Likewise the SciPy/NumPy oracle is an **external truth for DSP numerics** used to *test* an
implementation; it is not the definition of any pan block. The definitions are here.

### 0.2 The correctness-tier convention (used corpus-wide)

Following the rigor audit ([`../notes/pan_spec_audit_mathematical_rigor.md`](../notes/pan_spec_audit_mathematical_rigor.md)),
every correctness-bearing claim carries exactly one of three markers. **The corpus must use these
markers and must not call a tested claim "proven".**

| Marker | Tier | Meaning | Discharge method |
|---|---|---|---|
| **⊢** | **proven-by-construction / decidable-static** | Guaranteed before any code runs. | Zig's type system, a `@compileError`, or a decidable comptime/commit-time check. |
| **≈** | **tested (empirical)** | Correctness rests on running code against an oracle or a differential check. Shows *presence* of bugs, never *absence* (Dijkstra). | Gold-vector oracle, B≡C differential test, dual-mux test, latency-contract test, property-based test. |
| **▷** | **conventional (authoring obligation)** | Correctness rests on the author obeying a rule the system cannot enforce. | Documentation, tutorial, review; partially caught retrospectively by a ≈ test. |

> **Honesty rule (Rule 12 applied to vocabulary).** A ≈ test is **evidence**, not a proof. The phrase
> "the test *is* the proof" is a category error and is **banned** from the corpus. The correct phrasings
> are: "*proven* ⊢ at comptime/commit", "the *primary correctness check* ≈ is the B≡C differential
> test", "a *conventional obligation* ▷ tested by …". The full ledger is §12.

### 0.3 What is load-bearing categorical content vs framing

Category theory enters pan in two registers, and the corpus must keep them distinct (Rule 7):

- **Load-bearing** — a categorical concept that *generates a checkable obligation* (a law, a decidable
  check, or a proof strategy that determines what must be tested). These earn their place: the
  **trace / SCC-has-delay** causality law (§5), the **Yoneda probe ⇒ dual-mux** test strategy (§4), the
  **interval-coloring optimality** theorem (§7), and **Format negotiation as unification making the
  diagram commute** (§6).
- **Framing** — a categorical name that organises intuition but constructs no proof. These are kept as
  *vocabulary*, explicitly labelled, never dressed as theorems: the **terminal-object** reading of
  analysis roots (§8.3), and the **functor** reading of `ChannelMap` (§4.4, functoriality is an
  obligation, not a constructed proof).

---

## 1. The category **Stream** — objects

### 1.1 Objects: typed, format-indexed sample-streams

The objects of **Stream** are **typed sample-streams**. Denotationally, a stream of element type `A`
is a function

```
s : ℕ → A           -- an infinite, discrete-time sequence of samples/frames of type A
```

carrying a **Format** index (§1.2). We write the object as `Stream(A)@F`, or `Stream_F(A)`. A pan
**edge** at runtime realises a finite prefix of such a stream, presented one render call at a time as
a slice `[]A` (or `[]const A`). The object is the *whole* stream; the slice is the *per-call window*
onto it.

> **Why ℕ→A and not a finite buffer.** The denotational object is infinite so that the *laws* of Map
> and Rate (§2) are stated independently of block size `N`; `N` is a runtime windowing of the stream,
> not part of the stream's identity. This is the formal content behind "N is a runtime slice length"
> (§9.2).

### 1.2 The Format product object

`Format` is a **product object** — a tuple of independent indices:

```
Format = sample_rate × precision(T) × channel_layout(C) × block_size_regime(N) × port_element(A) × out_per_in
```

| Axis | Symbol | Domain | Binding | Defined in |
|---|---|---|---|---|
| sample rate | `Fs` | 8k, 16k, 24k, 48k, 96k, … (Hz) | runtime (device/config) | §6, [type §2](pan_type_and_numeric_model.md) |
| precision | `T` | f32, f64, i8, i16, i32, i64, q15, q31, … | **comptime** (§9.1) | §9, [type §3](pan_type_and_numeric_model.md) |
| channel layout | `C` | mono, stereo, …, ambisonic order | rides in element `A` via `Frame(Lane,C)` | §1.3, [type §2.1](pan_type_and_numeric_model.md) |
| block-size regime | `N` | runtime-`N` (stream ports) or comptime-`N=K` (fixed-K ports) | per regime (§9.2) | §9, [exec §4.2](pan_execution_model.md) |
| port element | `A` | the canonical element set, §1.3 | comptime | §1.3 |
| rate ratio | `out_per_in` | `1:1` (Map) or rational `p:q` (Rate) | comptime | §2 |

**Format negotiation (§6)** is unification over this product. The **pool class key** (§7.2) is the
sub-tuple `(A, element_count)` — precision and channels are *inside* `A`, so the pool keys off the
element type directly.

### 1.3 Canonical port elements (the element types `A`)

The blessed element set. **Every edge in any pan graph carries one of these as its `A`.** A
non-primitive element must expose a `typeName()` getter (the feasibility constraint witnessed by
ZigRadio's `types.zig` type-name map; a *bare* `[K]f32` has none and is rejected — hence the named
struct wrappers below). All multi-element forms are **planar** internally (§9.3, LOCKED).

| Port element | Zig form | Meaning | Used by | Pool class key |
|---|---|---|---|---|
| `Sample(T)` | `T` (the `C=1` case of `Frame`) | one audio sample of precision `T` | audio frames | `(T, N)` |
| `Frame(Lane, C)` | named `struct { ch: [C]Lane }`, `C` comptime | one `C`-channel audio frame (planar) | panner, balance, width, upmix/downmix, VBAP, ambisonic | `(Frame(Lane,C), N)` |
| `Complex(T)` | `std.math.Complex(T)` | one spectral bin | STFT/iSTFT spectra | `(Complex(T), N/2+1)` |
| `FeatureFrame(K)` | named `struct { v: [K]f32 }`, `K` comptime | a fixed-`K` feature vector | mel / chroma / MFCC / DCT | `(FeatureFrame(K), 1)` |
| `Scalar(T)` | named struct wrapping `T` | one scalar feature | centroid, flux, RMS, dominant band | `(Scalar(T), 1)` |
| `Bounded(T, Kmax)` | `struct { items: [Kmax]T, len: u16 }` | a ragged list, fixed capacity, variable `len` | formant tracks, sparse peaks, beat hypotheses | `(Bounded(T,Kmax), 1)` |

**Canonical identities and rules:**
- **`Sample(T) ≡ Frame(Lane, 1)`** — a mono kernel and a `Frame(Lane,1)` kernel are *the same thing*.
  ⊢ (type identity).
- A **channel-changing** block is exactly a morphism whose in/out `Frame` differ in `C`
  (`process(in: []const Frame(Lane,1), out: []Frame(Lane,2))`). Channel-count mismatch between wired
  ports is therefore a **type error**. ⊢ ([type §1](pan_type_and_numeric_model.md), via `PortId` §3.2).
- **`Bounded(T, Kmax)` liveness** is over the fixed `[Kmax]` *storage*, so coloring is unaffected by
  `len`; correctness is the consumer respecting `len`. Storage colorability ⊢; `len`-respect ▷.
  **(LOCKED — closes open question §4.5 of the bridge: storage is static so coloring is fine; the
  consumer-respects-`len` contract is sufficient. Rationale: nothing on the hot path reads past `len`,
  and the only failure mode — a consumer ignoring `len` — is an ordinary block bug caught by the
  gold-vector oracle.)**

### 1.4 The precision detail of `A`: the Numeric trait

`A` does not carry a bare lane type; precision is a **Numeric trait** because integer/fixed-point
changes overflow, accumulation, and rounding — the *common* path on FPU-less MCUs, not a footnote:

```
Numeric = { Lane : type,        -- element lane: f32, f64, i16(q15), i32(q31), …
            Acc  : type,        -- accumulator width: f32→f32, i16→i32, i32→i64
            saturate : bool,    -- integer ops saturate (+| -| *|) vs wrap
            W : comptime_int }  -- SIMD width for this Lane on this target (from the HAL)
```

`Acc` and `saturate` are **core** trait fields (load-bearing on the embedded fixed-point path), not
optional. `W` is resolved comptime-per-target by the Compute HAL (`std.simd.suggestVectorLength`).
Detail: [type §4](pan_type_and_numeric_model.md).

---

## 2. Morphisms — the two classes `Map` and `Rate`

A pan **block** is a morphism of **Stream**. There are exactly **two** morphism classes,
discriminated **⊢ at comptime** by whether the block declares `out_per_in`/`pull` (Rate) or not (Map).
This dual contract is commitment **C1** of the hub; the "one unified surface" is rejected because it
leaks at the rate-elastic seam.

### 2.1 `Map` — rate-1:1, possibly type-changing

A `Map` is a **causal, length-preserving stream function** realised by a per-sample Mealy machine
`(state, step)`:

```
process(self, in: []const In, out: []Out) void
```

**Laws** (a conforming `Map` must satisfy all):

- **(M1) rate-1:1.** `out.len == in.len` on every call. ⊢ (enforced by the contract / classifier).
- **(M2) sub-block homomorphism.** For any split of a call's input slice `in = in₀ ++ in₁`, threading
  the internal state `q` through, `process(q, in) = process(q, in₀) ++ process(q′, in₁)` where `q′` is
  the state after `in₀`. I.e. the block is a one-step-per-sample Mealy machine. This is the formal
  content of **"sub-block splitting is free"** ([exec §4.2](pan_execution_model.md)) and of **"per-sample
  state is still a Map"** (a biquad's `z⁻¹` is the Mealy state `q`). ⊢ for built-ins by construction;
  ▷ for third-party authors (the "Map with a hidden cross-call accumulator" mistake is *not*
  type-detectable — §2.3); ≈ tested by the state-granularity test.
- **(M3) element type may change, rate may not.** `In` and `Out` may differ (`Complex(f32) → f32`);
  the *rate index* of the Format is preserved. ⊢ (the classifier forbids `out_per_in` on a Map).
- **(M4, optional) `aliasing_safe`.** The author may declare `pub const aliasing_safe = true`,
  asserting the `step` reads `in[i]` *before* (never after) writing the corresponding `out[i]` — no
  intra-call read-after-write aliasing hazard. This *permits* (does not force) the colorer to alias
  the input and output buffers (§7.4). The property is **▷ conventional** (the type system cannot
  check it) and **≈ tested** (B≡C / paranoid mode catches a false claim and quotes the assertion
  back, §7.6). Forgetting it costs a memcpy (safe); asserting it falsely is a falsified contract.

> **Membership.** ~80 % of audio (gain, EQ, pan, mix, waveshaper) and the type-changing feature maps
> (power-spectrum, mel filterbank, log, DCT-II). Also the **fused tight-feedback kernels** (ladder,
> Karplus-Strong, comb) whose per-sample feedback loop runs *inside* one rate-1:1 `process` over
> persistent state (§5.4) — these are typically **not** `aliasing_safe`.

### 2.2 `Rate` — rate-elastic transducer

A `Rate` is a **causal transducer**: a Mealy machine over an internal queue (a ring of pending
samples) with **bounded look-ahead**, declaring its rate ratio and latency:

```
out_per_in : Ratio              -- rational p:q, e.g. 1:H (hop-H framer), D:1 (decimator)
algorithmic_latency : usize     -- samples of group delay; DISTINCT from out_per_in
needed_input(self, want) usize  -- how many input samples to produce `want` outputs
pull(self, want, out) usize     -- produce up to `want`; returns count produced (may be 0 or many)
```

**Laws** (a conforming `Rate` must satisfy all):

- **(R1) both declarations present.** A `Rate` missing either `out_per_in` or `algorithmic_latency`
  is a **build error** (Rule 12). ⊢ (field presence is structurally checkable). Their *numerical
  accuracy* is **≈ tested** (latency-contract test; impulse-response delay measurement) — a lying
  `Decimator` declaring `algorithmic_latency = 0` is **not** caught by ⊢ (audit C7).
- **(R2) `out_per_in` and `algorithmic_latency` are orthogonal.** Latency ≠ decimation; conflating
  them was the audit's S2. ⊢ (two distinct declarations).
- **(R3) `needed_input` is sound and monotone.** `needed_input(want)` is monotone non-decreasing,
  zero only at `want = 0`, and pulling `needed_input(want)` input samples eventually yields `≥ want`
  outputs (modulo the declared ratio). **≈ tested** — and the prime candidate for the deferred
  property-based harness (§13). An incorrect `needed_input` (returning `want` instead of `want·H` for
  a `Framer`) desyncs the graph silently until a latency-contract test catches it (audit C8). ▷+≈.
- **(R4) push↔pull agreement modulo latency.** The push and pull scheduler interpretations of a Rate
  block agree up to the declared `algorithmic_latency`. Categorically, the push↔pull schedulers are
  **two functorial interpretations** of the block functor, and the rate-elastic adapter is exactly
  where that natural transformation is **non-trivial** (it carries the latency obligation). **≈
  tested** by dual-mux + latency-contract tests; this is a *test strategy*, not a constructed
  natural-transformation proof.

> **Membership.** `Framer(N,H,window)`, decimator/interpolator, rational/arbitrary resampler
> (including the drift-ASRC), STFT/iSTFT, partitioned convolution. Owns internal clocked state → not
> a pure function of its current input slice.

### 2.3 The Map-vs-Rate decision rule (load-bearing onboarding — ▷)

The biggest newcomer hazard is psychological: reaching for *"a `Map` with state."* The rule, which
**must** ship as a tutorial chapter alongside the R1 build error (the "Map with hidden accumulator"
mistake is **not** ⊢-detectable — a Map is *allowed* per-sample state):

- **`Map`** — if `out.len` is **always** `in.len` and output depends only on the current input slice
  (threaded per-sample state allowed). **A biquad/IIR is a `Map`** (per-sample `z⁻¹`, rate-1:1).
- **`Rate`** — if you **accumulate across calls**, emit a **different count** than you consume, or
  **buffer until you have enough**. A ring / overlap buffer is the `Rate` smell. A **`Framer`** is a
  `Rate`.

The load-bearing example is **biquad (Map) vs `Framer` (Rate)**: both have "state", but the biquad's
is per-sample (rate-1:1) while the `Framer`'s is a cross-call accumulation buffer with a different
out-vs-in count.

---

## 3. Composition, identity, and flattening (the category laws)

- **Composition** `g ∘ f` is **wiring** an output port of `f` to an input port of `g`; it is defined
  **iff** the shared edge's Formats unify (§6). The **flowgraph is a finite diagram** in **Stream**.
- **Identity** `id_A : Stream(A) → Stream(A)` is the pass-through (a degenerate `Map`).
- **Associativity & identity laws** hold for the denotational stream-function model **by
  construction** (function composition is associative; `id` is neutral). The *implementation* realising
  these laws is **≈ tested** (a composite must behave as the composition of its parts — the Yoneda
  probe, §4, is exactly the justification that testing each block under the mux family suffices).
- **Flattening** a composite block = computing the **normal form** of its internal diagram (inlining
  sub-blocks into the parent op-list). A composite and its flattening must be observationally equal.
  **≈ tested** (dual-mux on the composite vs its flattening). Composites: [exec §4](pan_execution_model.md),
  [`09_COMPOSITE_BLOCKS…`](../zig_engineering/09_COMPOSITE_BLOCKS_AND_HIERARCHICAL_COMPOSITION.md).

---

## 4. The Yoneda / `SampleMux` probe

### 4.1 The seam

A **`SampleMux`** is the only coupling between a block and its transport: a fixed **10-method vtable**
(`wait/get{Input,Output}Available`, `get{Input,Output}Buffer`, `update{Input,Output}Buffer`,
`getNumReadersForOutput`, `setEOS`). A block's `process`/`pull` is handed slices *by a mux* and never
knows whether those slices are a private double-buffer, a coalesced pool buffer, or an offline ring.

The mux family (one interface, several realisations):

| Mux | Role | Tier |
|---|---|---|
| `TestSampleMux` | feeds exact oracle bytes, asserts exact output — **defines** behaviour | test |
| `PullTestSampleMux` | same, with pull semantics — the dual-mux partner | test |
| `PullSampleMux` | the synchronous-pull executor seam (renders upstream first; `update` is a no-op commit) | core |
| `RingSampleMux` | the offline push transport (Tier C) | deferred |

`PullSampleMux` semantics are the formal pull contract — see [exec §3](pan_execution_model.md).

### 4.2 The representable / Yoneda argument — what it is and is not

**Load-bearing (the test strategy).** A block's observable behaviour *is* its action on the buffers a
mux presents. By a Yoneda-style representability argument, a block is **determined by its action under
the family of muxes** — so `TestSampleMux` *defines* behaviour and any real mux merely *executes* it.
The operational consequence is the **dual-mux obligation**: testing every block under **both** push
(`TestSampleMux`) and pull (`PullTestSampleMux`) is not arbitrary coverage — it is the structural
check that the block's behaviour is mux-independent (it catches surface leaks at the `Map`/`Rate`
seam). This determines *what to test and why testing it suffices* (modulo the corpus). It is the
strongest genuine categorical content in pan, and it is the formal basis of "tests as definition"
(Rule 14).

**Honest bound (not a proof — ≈).** The corpus does **not** construct the natural isomorphism
`Hom(A, −) ≅` (the represented functor). The Yoneda lemma is invoked as a **proof *strategy*** that is
properly applied, not as a discharged proof. "Behaviour is determined by the mux probe" justifies the
dual-mux *test*; it does not certify correctness over untested inputs. Therefore: **load-bearing as a
test strategy (≈); ornamental as a proof.** The corpus must say "the Yoneda probe justifies dual-mux
testing", never "the Yoneda lemma proves the block correct".

### 4.3 `Concat`/`Vectorize` — the named (labelled) limit

The fan-in combinator `Concat(spec)` takes a **comptime struct-of-(name → element-type)** and emits
one output struct whose fields are those named element types. Categorically it is a **named product —
a *limit* whose projections are *named*** (a record, not an ordered tuple): the comptime spec is the
struct-of-(name → element-type), and the product object's **field order is the canonical feature-matrix
column order**. Inputs are wired by name (`node.in.<name>`) via typed `PortId`s (§3.2); a wrong name or
element type is a ⊢ compile error. Surface: [type §1](pan_type_and_numeric_model.md). It is a **library
block**, not a core primitive.

### 4.4 `ChannelMap` — a functor (framing, functoriality is an obligation)

`ChannelMap(Sub, C)` replicates a mono subgraph `Sub` over `C` channels and stacks the outputs;
coloring/negotiation scale by `C`. It is **modelled as** the `C`-fold product functor `C^(·)` on
subgraphs. **Framing, not theorem:** the corpus constructs **no** functoriality proof (that the
combinator preserves composition and identity). Functoriality is therefore an **obligation** — **≈
tested** (a `ChannelMap` over a composite equals the composite of `ChannelMap`s on the parts) — and
must be labelled as design vocabulary, not a proven functor.

---

## 5. Feedback — a trace in a traced monoidal category

### 5.1 The monoidal structure

**Stream** with the **parallel-ports** tensor `⊗` (placing two edges side by side) is a symmetric
monoidal category. Sequential wiring is `∘` (§3); parallel wiring is `⊗`.

### 5.2 The trace and the causality (SCC-has-delay) law — load-bearing ⊢

A **feedback loop** is the **trace** `Tr(f)`: the fixpoint obtained by connecting an output port back
to an input port. In a traced monoidal category the trace is well-defined **only for a guarded
(contractive) map** — operationally, **only if the loop contains a delay** that guarantees causality
(this period's output depends only on *previous* periods' looped values). This is genuine,
load-bearing categorical content: the well-formedness condition of the trace **is** the engineering
rule.

**The `z⁻¹` law (universal across Web Audio / Max / Pd / JUCE):** a back-edge is legal **iff** its
strongly-connected component (SCC) contains ≥1 delay element. A feedback edge is split into a **write
side** (produced this block) and a **read side** (the value from the *previous* block); the
topological sort runs on the DAG-minus-feedback-edges. The graph-commit pass runs an SCC analysis and
rejects any delay-free cycle with **`error.DelayFreeLoop`**.

- **⊢ proven-by-construction:** *every cycle contains ≥1 declared delay at commit.* Decidable: SCC
  detection + delay-membership. (Audit A4.)
- **▷/≈ not proven:** that the declared delay is the *correct length* for the application's causality,
  nor that a fused tight-feedback kernel's internal delay is sample-accurate (it is opaque to the
  commit pass).

### 5.3 Persistent state — the pool-excluded category

A feedback delay buffer, a `Framer`'s overlap ring, and any cross-frame history (delta cepstra, flux
previous-spectrum, leaky maxes, tempo hypotheses) have a live range **spanning callbacks**. These are
a **distinct, pool-excluded category** (§7): allocated once at `initialize`, persisting across the hot
path. The library ships canonical `UnitDelay(z⁻¹)` / `DelayLine(L)` primitives.

### 5.4 The two feedback idioms

- **Graph-level `DelayLine`-in-a-cycle** — composable, scheduler-visible, **one-block latency**. The
  default; the delay is an ordinary node.
- **Fused single-`Map` tight-feedback kernel** — the per-sample feedback loop runs *inside* one
  rate-1:1 `Map.process` over fixed persistent state; the `z⁻¹` lives per-sample inside the kernel, so
  feedback is **sample-accurate**. The trade is explicit: **forfeit scheduler-visibility** (opaque to
  the colorer; cannot be fused/split across the loop) **for sample-accuracy**. pan ships **ladder /
  Karplus-Strong / comb** as such kernels. These are typically **not** `aliasing_safe`. A block-size-1
  *subgraph* combinator (composing tight feedback from sub-blocks) is **explicitly deferred** (Rule 2).

---

## 6. Format negotiation — unification making the diagram commute (⊢ structure, ≈ arithmetic)

At graph-commit, the negotiation pass propagates Formats (§1.2) along edges and solves a **unification
problem over the product object**: each wired edge imposes an equality constraint on the shared
Format. Where the user wired **incompatible-but-coercible** Formats, the pass **inserts a coercion
morphism** so the diagram **commutes**:

| Mismatched axis | Coercion morphism inserted |
|---|---|
| sample rate | resampler (polyphase sinc; adaptive drift-ASRC at device boundary) |
| channel layout | channel matrix (upmix/downmix) |
| precision `T` | precision cast (monomorphized seam converter) |
| rate ratio | framer / rate adapter |

- **⊢ proven-by-construction:** element-type, port-direction, and channel-count **identity at every
  wired edge** is a type error if violated (`connect` emits a `@compileError` naming the port; audit
  A1/A6). The negotiation pass itself **must be comptime-evaluable** (§8.5).
- **≈ tested:** the *numerical correctness* of an inserted coercion (e.g. the resampler's output) is
  empirical (gold-vector oracle). A wired rate-mismatch auto-inserting a resampler is a prototype
  success criterion ([bridge §5](pan_categorical_bridge_and_roadmap.md)).

The categorical reading is load-bearing: "make the diagram commute" is the *definition* of where a
coercion must go (any non-commuting square is a missing coercion or a hard mismatch).

---

## 7. Memory — coloring as interference-graph coloring

### 7.1 Per-callback execution *is* register allocation

| Compiler concept | pan analogue |
|---|---|
| virtual register | a graph **edge** (one producer output → one-or-more consumers) |
| physical register | a **buffer** drawn from a pool |
| instruction order | the **render schedule** (topological order) |
| live range | `[producer writes … last consumer reads]` |
| register count | **M** = max simultaneously-live edges |

### 7.2 One pool per element-type-class — the key refinement (C3)

Heterogeneous-size interval bin-packing (Dynamic Storage Allocation) is **NP-hard**. pan sidesteps it
by maintaining **one pool per element-type-class**, `Pool(class)` with `class = (element_type,
element_count)` (the pool key of §1.3):

- **Within a class** all buffers are identical size → live ranges are **intervals** → the interference
  graph is an **interval graph** → it is **optimally `k`-colorable in linear time** by the **left-edge
  algorithm**, with `k = M_class = max clique = max simultaneously-live edges`. This is an **imported
  graph-theory theorem** (⊢ about the *algorithm*; see the honesty note in §7.5).
- **Across classes** there is **no interference** (different element types can never alias). ⊢ (type
  disjointness).
- **Heterogeneous *counts* within one class** (rare) are handled by brute-force / first-fit-decreasing
  at commit; since `M ≤ ~8` this is optimal-enough at zero hot-path cost. **(LOCKED — closes open
  question §4.4 of the bridge. Rationale: at M≤8 the FFD result is provably within the trivial optimum
  for all realistic graphs, and the cost is paid once at commit.)**

Pool sizing: `M_class · element_count · @sizeOf(element_type)`.

### 7.3 Fan-out / fan-in

- **Fan-out** extends a buffer's live range to its *last* reader and **forbids in-place** by the first
  reader. (The "one spectrum → 8 reductions" case: pin the spectrum buffer for the parallel span.)
- **Fan-in** (summing mixers, `Concat`) either gives one mutating consumer a private copy (a memcpy)
  or pins a buffer longer — a commit-time cost-model choice. Additive summing into a destination is the
  audio-mix default.

### 7.4 In-place coalescing (the alias optimization) — gated, never inferred

For a unary `Map` whose input edge is single-consumer and last-used here, assign the output the *same*
physical buffer. **Honored only when the validator ⊢-proves all three:** (i) single consumer, (ii)
identical element type & count in==out, (iii) the consumer reads before any other producer overwrites
— **and** the block declares `aliasing_safe` (§2.1 M4). `noalias` is applied **only** on the
proven-non-aliased path. The `aliasing_safe` *assertion itself* is ▷/≈ (§2.1), the *three structural
conditions* are ⊢.

### 7.5 What is proven vs tested here — the honest split (Mission #2)

- **⊢ proven:** the interval-coloring **optimality** (imported theorem); across-class **disjointness**
  (types); the three structural conditions gating in-place (§7.4).
- **≈ tested (NOT proven):** that the Zig **implementation** of the colorer produces output identical
  to the uncolored baseline. This is the **B≡C differential test** (mode B = per-edge double buffers,
  obviously correct; mode C = colored pool), with a paranoid mode poisoning released buffers to NaN.
  **The B≡C test is the *primary correctness check* for the colorer implementation — it is empirical
  evidence, not a proof.** (Corrects the prior corpus language "the B≡C test *is* the proof", which was
  a category error: the optimality is mathematics, the implementation's faithfulness to it is tested.)

### 7.6 The `aliasing_safe` failure-message contract

When B≡C / paranoid mode catches a divergence on a block that declared `aliasing_safe = true`, the
message **names the assertion and quotes it back**, identifies the first divergent sample, and states
the fix — so a false safety claim reads as a *falsified contract*, not an opaque mismatch. (Exact
message: [mem §9](pan_memory_model.md).)

### 7.7 Plugin-delay-compensation (PDC) — folded into the same pass

Each block declares `algorithmic_latency` (0 for pure `Map`). The commit pass runs a **longest-path
dynamic program** over the DAG: `latency[node] = max over inputs(latency[src] + edge_delay)`, inserting
a compensating `DelayLine` on the shorter paths at each fan-in so signals re-align sample-accurately.
PDC operates **per rate-domain** (a time-domain path and an FFT-latency spectral path align in the
*feature-frame* rate domain). Requires a **static** reported latency per block (a `Rate` block reports
worst case). Compensating delays come from the persistent category (§5.3). **≈ tested** (a dry/wet
diamond around an FFT path re-aligns sample-accurately).

### 7.8 The footprint formula (the H2 guarantee)

```
render_memory =  Σ_class  M_class · element_count_class · @sizeOf(element_type_class)   -- pools
               + Σ_feedback  delay_length · @sizeOf(elem)                                -- persistent
               + Σ_block  state_size                                                     -- per-block
               + Σ_pdc  comp_delay_length · @sizeOf(elem)                                -- PDC delays
```

All terms known at commit (at `comptime` on embedded) → one up-front allocation, zero hot-path alloc.
⊢ that the figure is a comptime constant for a comptime graph (the embedded smoke gate, §8.5).

---

## 8. Execution — pull scheduler, render op-list, clock-driven roots

### 8.1 The callback contract

The audio device hands an output buffer of exactly **N frames** with a deadline of **N/Fs** seconds.
The contract is **pull**: "render exactly these N frames into this exact buffer, now." A missed
deadline is an **xrun** (audible click).

### 8.2 The render op-list (compile once, replay every callback) — C2

The graph-commit pass compiles the DAG into a flat, ordered **render op-list**:

```
op := { fn_ptr (monomorphized Map/Rate kernel), self_ptr,
        input_buffer_ids[], output_buffer_ids[], n_or_pull_spec }
```

The hot path replays it with **zero graph walking**:
`for op in plan.ops: op.fn_ptr(op.self_ptr, gather(inputs), scatter(outputs), n)`. **Commit-pass
order:** topological sort (DAG minus feedback edges) → liveness → per-element-class coloring (§7) →
SCC-has-delay check (§5.2) → PDC insertion (§7.7) → buffer-id assignment → emit op-list + footprint
(§7.8). Detail: [exec §4](pan_execution_model.md), [mem](pan_memory_model.md).

### 8.3 Clock-driven pull roots (C5) — resolving T1

```
PullRoot   := { clock_source, sink_set, owned_subplan }
ClockSource ∈ { AudioDeviceCallback, WallClockTimer(rate), InputExhaustion(file) }
```

The audio output is one `PullRoot` (driven by `AudioDeviceCallback`, on the RT thread). An **analysis
sink** is a *separate* `PullRoot` on a **non-RT thread**, never slaved to the audio deadline; shared
upstream is rendered once and fanned to both roots; **cross-root hand-off is only via a lock-free SPSC
ring (a tap)**. **Framing note:** analysis roots were once called "additional terminal objects" — this
is **decorative naming only** (terminal objects are unique up to unique iso; multiple clocked roots
are not). Keep the engineering content (independent demand sources); drop the terminal-object claim.

### 8.4 Scheduler tiers — disposition

| Tier | What | Status | Why |
|---|---|---|---|
| **A** | single-thread synchronous pull in the callback | **CORE (frozen)** | meets sub-5 ms; wait-free; the always-correct ground truth |
| **B** | static-parallel (level schedule + bounded-spin barrier) | **DEFERRED library** | a spin barrier busy-waits the RT thread; unbounded worst case on M3 P/E clusters. Keep the level-schedule analysis; defer the executor. |
| **C** | threaded push (large rings, condvars) | **DEFERRED library** | offline file→file; latency irrelevant. Reuses the same blocks via `RingSampleMux`. |

### 8.5 The comptime-commit obligation (embedded "same code, specialized")

The whole commit pass **must be comptime-evaluable** so embedded can run it at `comptime` (all memory
in `.bss`, topology comptime-fixed). This is enforced by a **CI smoke gate** that calls
`commitComptime()` inside a `comptime` block in a `ReleaseSmall` build (I2S source → gain → I2S sink):
**the build compiling ⊢ is the discharge; failing to compile is the loud failure.** A
non-comptime-evaluable block is rejected with the pan-level **`comptime_commit_safe`** error, not a raw
Zig trace. **Honest bound:** this proves the commit pass is comptime-evaluable **for the smoke graph**;
it is **not** a proof for arbitrary graphs (audit A5). The embedded build is then a **strict comptime
specialization** of the desktop core — every desktop runtime degree of freedom (runtime `N`, runtime
commit, vtable mux, Tiers B/C) is exactly what collapses to comptime or vanishes on an MCU.

### 8.6 Events & sub-block rendering

An **event lane** parallel to the sample lanes carries a time-sorted `(sample_offset, event)` list
(MIDI, automation; VST3/CLAP shape). The pull scheduler renders in **sub-blocks bounded by event
offsets** — pull `[0,k)`, apply event, pull `[k,N)`. Free for `Map` by (M2). `Rate` blocks quantize
events to their hop grid.

### 8.7 Error isolation

On the RT path a faulting block (NaN, domain error) **emits silence and raises a flag** consumed by the
control thread; the graph keeps running (contrast the offline path's deliberate collapse-on-error,
which is correct for batch). ▷/≈.

---

## 9. Numeric & precision model (defaults LOCKED)

### 9.1 The precision / block-size / width asymmetry (C4)

| Axis | Binding | Why |
|---|---|---|
| **precision `T`** | **comptime** kernel parameter | changes machine code (lane type, instruction selection, `Acc` width, saturation); bound once via a monomorph function pointer (one indirect call per *buffer* — free) |
| **block size `N`** | **runtime** (a slice length) | the device dictates `N`; Zig's vectorization keys off comptime `W`, not `N`, so a runtime-`N` loop + comptime-`W` body + scalar tail vectorizes fully |
| **SIMD width `W`** | **comptime per target** (HAL) | `std.simd.suggestVectorLength(T)` |

**Consequence:** no precision×block-size cross-product; the explosion is driven by precision alone.
`cfg.precision` is **comptime-known** (`numericFor` is a comptime switch over an explicit
active-precision list; the call site uses the `comptime` keyword). **A desktop precision change
requires a recommit; pan offers no runtime precision switching.** ⊢ (the `comptime` keyword;
audit A9).

### 9.2 Two N-regimes

- **runtime `N`** for stream ports (`Sample(T)`, `Complex(T)`) — device-driven, scalar tail accepted.
- **comptime `N = K`** for fixed-K feature ports (`FeatureFrame(K)`) — kills the scalar tail, enables
  `inline for` unrolling. Same port-kind distinction the pool already makes (§7) — free coherence.

### 9.3 Locked defaults (from the locking pass, 2026-06-02)

- **Internal channel form: PLANAR** (LOCKED). Planar internally (SIMD-friendly `@Vector` kernels);
  planar↔interleaved conversion happens **only at the I/O boundary**. *(Closes bridge §4.2.)*
- **Internal precision: f32-internal default, per-block opt-in** (LOCKED). f32 everywhere internally
  (covers ~95 % of audio), with genuine per-block precision available as opt-in (`i16` decode → `f32`
  core → `i24/i32` out via monomorphized seam converters). *(Closes bridge §4.1.)*
- **Embedded target: target-generic / deferred** (LOCKED). The SRAM budget is a **build constant**;
  **fixed-point q15 is the first-class embedded default** (`{Lane:i16, Acc:i32, saturate:true, W:1–2}`)
  with f32 conditional on an FPU; the comptime-commit smoke gate compiles against a stubbed
  `freestanding` target until a concrete MCU is chosen. *(Closes bridge §4.6.)*
- **Hop H ∤ device N alignment** (LOCKED, T4): the `Rate`/`Framer` block owns an internal ring and
  absorbs the misalignment; the scheduler never assumes `H | N`. *(Closes bridge §4.3. Rationale:
  forcing `N ≡ 0 (mod H)` would couple device buffer size to algorithm internals and break on every
  route switch.)*

---

## 10. Real-time hygiene, control plane, transport (terms)

- **Realtime token / `enterRealtimeThread()`** — running pan DSP on a thread **requires holding a
  token** whose construction sets **FTZ/DAZ** on the *calling* thread (the ARM64 FPCR `FZ` bit is
  per-thread and not inherited — the Mixxx footgun). `renderInto`/any custom-worker entry **requires
  the token — it won't compile without it** ⊢. No-op token on fixed-point; uniform API shape across
  targets. **Honest bound:** a strong structural nudge, not a proof (H3 cannot prove FTZ is *still* set
  if a user mutates FPCR afterwards). Whether the hardware honours FTZ is ≈.
- **Denormals / NaN-Inf** — denormals cause 10–100× CPU slowdowns in decaying feedback paths → set
  FTZ/DAZ. NaN guards at block outputs in Debug/ReleaseSafe (compiled out in release; surfaced via
  `guards_compiled_out: bool` telemetry so release cannot *silently* drop them). NaN → fault → silence
  + flag (§8.7).
- **Dither & gain staging** — f32→i16/i24 truncation without dither adds correlated distortion; dither
  (+ optional noise shaping) on any down-bit conversion; defined clip/saturation + headroom policy at
  the boundary.
- **Control plane — exactly three verbs**, bound 1:1 to three RT-safe mechanisms; the *kind of change*
  selects the mechanism, named in the verb:

  | Intention | Verb | Mechanism | Contract |
  |---|---|---|---|
  | move a knob (continuous) | **`set`** | atomic scalar + per-block ramp | wait-free, click-free; **NOT sample-accurate by contract** (no `at_sample` param — a ⊢ compile error of omission) |
  | automate at a point | **`schedule`** | SPSC command ring, applied at a sub-block boundary | wait-free enqueue; **sample-accurate** |
  | rewire (topology) | **`edit`→`commit`** | RCU plan swap built off-thread, published at a block boundary | wait-free atomic pointer swap |

- **Bypass-preserves-latency (named law)** — a bypassed block with `algorithmic_latency > 0` must
  **still delay** its signal by exactly that latency (route through the compensating `DelayLine` PDC
  already inserts), else bypass shifts timing and breaks alignment on parallel paths. Built-in bypass
  honours it automatically ⊢; a custom bypass author must route through the compensating delay (▷; a
  commit warning/error *where detectable*).
- **Transport** — sample-accurate play position, seek, loop, tempo/PPQ; the event lane timestamps
  against it; offline render is bit-reproducible regardless of wall-clock.
- **Clock-domain drift / ASRC** — separate input/output crystals drift; an adaptive (asynchronous)
  resampler (a `Rate` block) nudged by a slow PI controller on the bridging FIFO fill keeps it
  centered; bypassed on a single full-duplex clock. At the **device boundary**, not inside the graph.
- **HALs (two, distinct)** — **Compute HAL**: portable comptime `@Vector(W,T)` SIMD (NEON/Helium/AVX),
  optional runtime-discovered accel (vDSP/FFTW/CMSIS-DSP, chiefly FFT). **I/O HAL**: CoreAudio (macOS,
  first) / ALSA+JACK/PipeWire (Linux) / I2S-DMA ping-pong (embedded). LPCM codecs convert
  interleaved device bytes ↔ internal planar at the edge.

---

## 11. Invariants, commitments, tensions (canonical statements)

### 11.1 Invariants (the core exists to guarantee these)

| | Statement | Tier |
|---|---|---|
| **H1** | No unbounded blocking on the audio thread: for one callback the render path is wait-free (no lock, condvar, malloc/free, syscall, page fault). | declared invariant; **▷ conventional** (no Zig type forbids `malloc` in `process`) + **≈ tested** (xrun counters, instrumented allocators). Honestly: the architecture *exists to* guarantee H1; enforcement is discipline + tests, not ⊢. |
| **H2** | Bounded, statically-known render memory: all per-callback memory allocated once at commit (§7.8). | **⊢** that the footprint is a commit/comptime constant; **▷/≈** that every block actually pre-allocates and never allocates in `process`. |
| **H3** | Port/graph correctness provable at comptime/commit: mis-wiring (type, channel, rate, direction) is a compile/commit error, never a runtime crash. | **⊢** (the genuine Curry-Howard result of pan; §1.3, §3, §6). |

> **Litmus for "is it core?"** A concept is core **iff** it must hold at comptime/commit for the
> render path to stay wait-free (H1), statically-bounded (H2), and type-correct (H3). Anything
> expressible as "just another block + a `SampleMux` client + a HAL call" is a **layered library**.

### 11.2 Commitments

- **C1** two block contracts `Map`/`Rate` (§2) · **C2** synchronous pull scheduler + render op-list
  (§8.2) · **C3** per-element-class colored buffer pool (§7) · **C4** precision-comptime /
  N-runtime / W-comptime-per-target + Numeric trait (§9, §1.4) · **C5** clock-driven pull roots (§8.3).

### 11.3 Tensions (resolved — pick a side, Rule 7)

- **T1** pull-purity vs analysis sinks → multiple pull roots, one clock arbiter (§8.3).
- **T2** clean dataflow vs fused single-pass → clean dataflow is the *semantic* model; fusion is a
  commit-time optimization, never an API contract; automatic loop-fusion deferred (§7.3,
  [mem §5](pan_memory_model.md)).
- **T3** static coloring vs dynamic edits → static within an epoch; edits build a new plan off-thread
  and atomic-swap (RCU); embedded has no runtime epochs.
- **T4** runtime-N vs hop-alignment → the `Rate`/`Framer` ring absorbs `H ∤ N` (§9.3).
- **T5** one unified surface vs honesty → two contracts (C1).

---

## 12. The correctness ledger (the full proven / tested / conventional classification)

This is the canonical version of the audit's classification. The corpus must not contradict it.

### 12.1 ⊢ Proven-by-construction / decidable-static
A1 port element-type & direction match · A2 8-port-per-direction ceiling (`u3`) · A3 Map/Rate field
presence (R1) · A4 SCC-has-delay (`error.DelayFreeLoop`) · A5 comptime-commit smoke gate (smoke graph
only) · A6 channel-count match (`Frame(Lane,C)`) · A7 `set` rejects sample-accuracy at the type level
· A8 `FeatureCollectorSink`-on-RT-root commit rejection · A9 precision-as-comptime (no runtime switch)
· the three in-place structural conditions (§7.4) · across-class pool disjointness (§7.5) ·
interval-coloring optimality (imported theorem, §7.2).

### 12.2 ≈ Tested (empirical evidence — NOT proofs)
B1 DSP numeric correctness — **gold-vector oracle** (SciPy/NumPy; *empirical evidence, relabelled from
"the methodology" — it shows presence, not absence of bugs*) · B2 colorer implementation correctness —
**B≡C differential test** (*the primary correctness check, NOT "the proof"*; the optimality is the
⊢ theorem in §7.2, the implementation's faithfulness is tested) · B3 `aliasing_safe` truth — B≡C /
paranoid mode · B4 `Rate` numeric contract (`out_per_in`, `algorithmic_latency`) — latency-contract &
dual-mux tests · B5 RT hygiene in practice (FTZ honoured, denormal behaviour) · B6 PDC arithmetic
across topologies · B7 wait-free hot path in practice (xrun counters) · push↔pull agreement (R4,
dual-mux) · `Concat`/`ChannelMap` behavioural laws (§3, §4.4) · state-update granularity (§2.1 M2).

### 12.3 ▷ Conventional (authoring obligation the system cannot enforce)
C1 Map "no cross-call accumulation" discipline (§2.3) · C2 `aliasing_safe` authoring accuracy · C3
no-malloc/lock on the audio thread (H1) · C4 `comptime_commit_safe` self-declaration · C5 state-update
granularity authoring · C6 bypass-preserves-latency for custom bypass · C7 `algorithmic_latency`
numerical accuracy · C8 correct `needed_input` implementation (R3).

> **Balance (audit §1.4):** ~30 % ⊢ · ~40 % ≈ · ~30 % ▷ — typical of well-engineered systems
> software. The architecture is sound; the honesty fix is purely in *vocabulary* (§0.2), now applied
> corpus-wide.

---

## 13. Deferred formal work (out of scope for this locking pass — where it attaches)

These are **noted, not done** (per the locking-pass scope):

- **Property-based test harness** (audit rec #1) — attaches at §2.2 **R3** (`needed_input` monotonicity
  & soundness over a `want` range), §2.1 **M4** (`aliasing_safe` over randomized inputs), and §7.5
  (B≡C over randomized graph topologies, not just fixed vectors). Moves several ▷ claims toward ≈ with
  adequate coverage.
- **Machine-checked proofs (TLA+ / Lean)** (audit rec #3) — attach at the **pull scheduler** (§8.2:
  upstream-before-downstream, termination, wait-freedom — TLA+ model-checkable over bounded graphs) and
  the **colorer** (§7.2: the left-edge interval-coloring correctness has a direct CompCert-style
  register-allocation proof literature in Lean/Coq). These would turn §12.2 B2/B7 from primary evidence
  into a *sanity check* behind a real proof — the genuine Dijkstra "prove-before-run" move. Deferred.
- **Floating-point numeric proofs** (Flocq/Gappa for "the biquad matches its rational transfer
  function for all f32 inputs") — research-grade per algorithm; the gold-vector oracle (§12.2 B1) is
  the pragmatic substitute. Deferred.

---

## 14. Glossary — every cross-doc term resolves here

> Each entry: definition · tier where applicable · canonical section.

- **8-port ceiling** — ≤8 ports per direction per node; enforced ⊢ via the port-index type `u3`. §3.2,
  [hub §2](pan_architecture_formalisation.md).
- **`algorithmic_latency`** — declared samples of group delay of a `Rate` block; distinct from
  `out_per_in`. R1/R2 §2.2; accuracy ≈ (C7 §12.3).
- **`aliasing_safe`** — author's assertion (M4 §2.1) that a `Map` has no intra-call read-after-write
  hazard, permitting in-place coalescing. ▷/≈.
- **`Acc`** — accumulator-width field of the Numeric trait. §1.4.
- **ASRC / drift resampler** — adaptive asynchronous resampler at the device boundary; a `Rate` block
  nudged by a PI controller. §10.
- **B≡C differential test** — mode B (per-edge double buffers) vs mode C (colored pool) bit-identical
  output; the *primary correctness check ≈* for the colorer (NOT a proof). §7.5.
- **block / morphism** — a `Map` or `Rate` (§2); a morphism of **Stream** (§1).
- **`Bounded(T,Kmax)`** — fixed-capacity ragged-list element; static storage, variable `len`. §1.3.
- **`ChannelMap(Sub,C)`** — library combinator replicating a subgraph over `C` channels; modelled as a
  functor (framing, functoriality ≈). §4.4.
- **`ClockSource` / `PullRoot`** — a demand source driving a committed subplan; audio callback / wall
  timer / input-exhaustion. §8.3.
- **coercion morphism** — a converter (resampler / channel matrix / cast / framer) inserted by
  negotiation to make the diagram commute. §6.
- **colorer / coloring** — assignment of edges to pool buffers by interval coloring. §7.
- **commit / graph-commit pass** — the one-time off-hot-path (at `comptime` on embedded) compilation:
  negotiate → schedule → liveness → color → SCC-check → PDC → op-list + footprint. §8.2.
- **`comptime_commit_safe`** — a block's obligation/declaration that its commit-phase logic is
  comptime-evaluable; CI smoke gate §8.5. ▷ (C4 §12.3).
- **`Complex(T)`** — spectral-bin element. §1.3.
- **composite block** — a subgraph packaged as a block; flattens to a normal form. §3.
- **`Concat`/`Vectorize`** — named-product fan-in combinator (struct-of-(name→element-type)); output
  field order = canonical column order. §4.3.
- **`Config` / `numericFor`** — the single config struct (one flows through the pipeline);
  `cfg.precision` is comptime-known, `numericFor` a comptime switch. §9.1.
- **dual-mux testing** — testing every block under push (`TestSampleMux`) and pull
  (`PullTestSampleMux`); justified by the Yoneda probe. §4.2.
- **`error.DelayFreeLoop`** — commit rejection of a delay-free cycle. ⊢ §5.2.
- **event lane** — time-sorted `(sample_offset, event)` list driving sub-block rendering. §8.6.
- **`FeatureCollectorSink`** — non-RT growable time-series sink (pre-reserve `capacity_hint`, then
  geometric ×2 growth); legal **only** on a non-RT pull root; on an RT root it is an A8 commit error.
  §8.3, [bridge §2](pan_categorical_bridge_and_roadmap.md).
- **footprint formula / `render_memory`** — the H2 memory bound. §7.8.
- **`Format`** — the product-object index of a stream object. §1.2.
- **`Frame(Lane,C)`** — planar `C`-channel audio element; `Sample(T) ≡ Frame(Lane,1)`. §1.3.
- **FTZ/DAZ** — flush-to-zero / denormals-are-zero; set via the realtime token. §10.
- **fused tight-feedback kernel** — sample-accurate per-sample feedback loop inside one `Map`. §5.4.
- **gold-vector oracle** — SciPy/NumPy reference vectors for DSP numerics; ≈ empirical evidence (B1).
  §0.1, §12.2.
- **`guards_compiled_out`** — telemetry bool: true in ReleaseFast/Small. §10.
- **H1/H2/H3** — the three invariants. §11.1.
- **in-place coalescing** — aliasing input and output buffers for a unary `Map`. §7.4.
- **interval graph / left-edge algorithm** — the per-class coloring structure & optimal linear-time
  algorithm (imported ⊢ theorem). §7.2.
- **`Map`** — rate-1:1 morphism class. §2.1.
- **`M` / `M_class`** — max simultaneously-live edges (per class). §7.1.
- **Mealy machine** — the `(state, step)` realisation of a Map (M2) or Rate transducer. §2.
- **mode B / mode C / paranoid mode** — double-buffer baseline / colored pool / NaN-poison checker.
  §7.5.
- **monomorph / monomorphization** — a concrete-precision instantiation of a kernel; bound via a
  function pointer. §9.1.
- **`needed_input(want)`** — `Rate` input demand function; sound & monotone (R3). §2.2; ≈/▷ (C8).
- **Numeric trait** — `{Lane, Acc, saturate, W}`. §1.4.
- **`out_per_in`** — a `Rate` block's rational rate ratio. §2.2.
- **PDC** — plugin-delay-compensation; longest-path DP per rate-domain. §7.7.
- **persistent / pool-excluded state** — buffers whose live range spans callbacks (delay lines,
  overlap rings, history). §5.3.
- **planar** — internal channel layout (LOCKED). §9.3.
- **`Pool(class)`** — per-element-class buffer pool, `class = (element_type, element_count)`. §7.2.
- **`PortId`** — comptime handle carrying node identity + direction + element type; `connect`
  type-checks it. ⊢ §3.2 / [type §1](pan_type_and_numeric_model.md).
- **precision `T` / N / W** — the three asymmetric numeric axes. §9.1.
- **`process` / `pull`** — the Map / Rate entry points. §2.
- **`PullSampleMux` / `RingSampleMux` / `TestSampleMux` / `PullTestSampleMux`** — the mux family. §4.1.
- **realtime token / `enterRealtimeThread()`** — FTZ-setting thread-entry token required by
  `renderInto`. §10.
- **render op-list** — the flat, replayed-per-callback schedule. §8.2.
- **`Sample(T)`** — one audio sample; `≡ Frame(Lane,1)`. §1.3.
- **`SampleMux`** — the 10-method block↔transport seam. §4.1.
- **`Scalar(T)`** — one scalar feature element. §1.3.
- **SCC** — strongly-connected component; must contain a delay (§5.2).
- **`set` / `schedule` / `edit`** — the three control verbs. §10.
- **`Stream`** — the category; objects are typed format-indexed streams `ℕ→A`. §1.
- **sub-block rendering** — splitting a render call at event offsets; free for `Map` (M2). §8.6.
- **Tier A / B / C** — sync-pull (core) / static-parallel (deferred) / push (deferred). §8.4.
- **trace / traced monoidal** — the categorical model of feedback; well-defined only with a delay
  (load-bearing ⊢). §5.
- **transport** — sample-accurate timeline/position/tempo. §10.
- **`UnitDelay(z⁻¹)` / `DelayLine(L)`** — canonical persistent-state delay primitives. §5.3.
- **xrun** — a missed audio deadline (audible click). §8.1.
- **Yoneda probe** — the representability argument justifying dual-mux testing (load-bearing as a test
  strategy ≈, ornamental as a proof). §4.2.
- **`z⁻¹`** — a unit delay; required in every feedback SCC. §5.2.

---

*Catalog locked 2026-06-02 as part of the specification-locking pass. Author: Claude (Opus 4.8) via
Claude Code, with the `zig-0-16` skill consulted for all Zig-form claims.*
