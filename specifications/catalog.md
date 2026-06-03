# pan — Catalog (the single source of truth: semantics, terms, and laws)

> **Status: LOCKED** (2026-06-02; **amended 2026-06-03** — added §2.4 *parameter ports*; refined M1
> to range over sample ports; pinned `out_per_in` single-rate (§2.2 R5), the multi-input pull rule
> (§8.8), data-gating-only (§8.9), and element-generic `UnitDelay`/FDN (§5.5); **then committed
> parallel & offline execution** — Tiers B/C → COMMITTED (phased), two execution modes (§8.10), §2.5
> `warmup_samples`, §8.11 concurrency-aware coloring, O1–O3 (§11.1b), C6/C7; **then dual-purpose
> (synthesis platform)** — `ChannelLayout` identity (§1.3), `VariRate` (§2.6), the Source contract
> (§2.7), the typed event lane + `NoteEvent` (§8.6), intra-block `PolyVoice` (§8.12), the
> Analyzer/Instrument graph shapes (§8.13), C8. Full change log: §15).
> This document is the **single source of truth** the brief
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
Format = sample_rate × precision(T) × channel_layout(L) × block_size_regime(N) × port_element(A) × rate(out_per_in | rate_bounds)
```

| Axis | Symbol | Domain | Binding | Defined in |
|---|---|---|---|---|
| sample rate | `Fs` | 8k, 16k, 24k, 48k, 96k, … (Hz) | runtime (device/config) | §6, [type §2](pan_type_and_numeric_model.md) |
| precision | `T` | f32, f64, i8, i16, i32, i64, q15, q31, … | **comptime** (§9.1) | §9, [type §3](pan_type_and_numeric_model.md) |
| channel layout | `L` | a `ChannelLayout` value — count **+** positional identity **+** canonical channel order (`.mono`, `.stereo`, `.surround_5_1`, `.surround_7_1`, `.ambisonic{order,…}`, `.discrete(N)`, `.custom{count,id}`) | **comptime**, rides in element `A` via `Frame(Lane,L)` | §1.3, [type §2.1](pan_type_and_numeric_model.md) |
| block-size regime | `N` | runtime-`N` (stream ports) or comptime-`N=K` (fixed-K ports) | per regime (§9.2) | §9, [exec §4.2](pan_execution_model.md) |
| port element | `A` | the canonical element set, §1.3 | comptime | §1.3 |
| rate ratio | `out_per_in` / `rate_bounds` | `1:1` (Map), rational `p:q` (fixed-rate `Rate`), or a bounded interval `[p_min:q .. p_max:q]` (variable-rate `Rate`, §2.6) | comptime | §2 |

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
| `Frame(Lane, L)` | named `struct { ch: [L.count()]Lane }`, `L : ChannelLayout` comptime | one audio frame on layout `L` (planar); channel **count** `C := L.count()` | panner, balance, width, upmix/downmix, VBAP, ambisonic | `(Frame(Lane,L), N)` |
| `Complex(T)` | `std.math.Complex(T)` | one spectral bin | STFT/iSTFT spectra | `(Complex(T), N/2+1)` |
| `FeatureFrame(K)` | named `struct { v: [K]f32 }`, `K` comptime | a fixed-`K` feature vector | mel / chroma / MFCC / DCT | `(FeatureFrame(K), 1)` |
| `Scalar(T)` | named struct wrapping `T` | one scalar feature | centroid, flux, RMS, dominant band | `(Scalar(T), 1)` |
| `Bounded(T, Kmax)` | `struct { items: [Kmax]T, len: u16 }` | a ragged list, fixed capacity, variable `len` | formant tracks, sparse peaks, beat hypotheses | `(Bounded(T,Kmax), 1)` |

**Canonical identities and rules:**
- **Buffer layout is PLANAR (strictly enforced — §9.3).** `Frame(Lane, L)` names an element's **layout
  identity** for `connect` type-checking; a multi-channel stream *buffer* is stored **plane-major**
  (`C` contiguous `N`-sample planes), never as `[]Frame` interleaved at the buffer level. AoS for
  `C > 1` is non-conformant (§9.3 P-1); a conformance gate enforces it (§9.3 P-2). Mono is trivially
  planar.
- **`Sample(T) ≡ Frame(Lane, .mono)`** — a mono kernel and a `Frame(Lane,.mono)` kernel are *the same
  thing*. ⊢ (type identity). Where a law quantifies over "channel count `C`", read `C := L.count()`.
- A **channel/layout-changing** block is exactly a morphism whose in/out `Frame` differ in `L`
  (`process(in: []const Frame(Lane,.mono), out: []Frame(Lane,.stereo))`). A mismatch in **count,
  positional identity, *or* channel order** between wired ports is therefore a **type error** (law L1).
  ⊢ ([type §1](pan_type_and_numeric_model.md), via `PortId` §3.2).
- **`ChannelLayout` — layout identity vs geometry (LOCKED 2026-06-03; closes audit finding #1).** `L`
  carries **count + positional tags + canonical channel order**, all comptime. **Laws:**
  - **(L1) identity matched at every wired edge.** A mismatch in count, positional identity, *or*
    channel order is a ⊢ type error — generalising the channel-count check (A6), not replacing it.
  - **(L2) registered-coercion-or-hard-mismatch.** Negotiation (§6) auto-inserts a canonical up/down-mix
    matrix **only** for a *registered* layout pair; an unregistered pair is a **hard mismatch** requiring
    an explicit spatial block. ⊢ that the pair is registered-or-rejected; ≈ the matrix numerics.
  - **(L3) identity in the type, geometry in the block.** Layout *geometry* — speaker azimuth/elevation,
    panning law, VBAP triangulation, ambisonic decode coefficients — is block configuration / parameter
    data, **never the stream type** (mirrors precision: `T` in the type, behaviour in the Numeric trait +
    kernel). ▷/≈.

  Canonical values: `.mono`, `.stereo`, `.surround_5_1`, `.surround_7_1`,
  `.ambisonic{order,ordering,norm}` (count `=(order+1)²`), `.discrete(N)` (anonymous N-channel bus,
  *no* positional identity — opts out of L1's identity check, count only), `.custom{count,id}` (arbitrary
  array). The pool keys off `L` automatically (it is inside `A`, so coloring is unchanged).

  ```zig
  // illustrative — Zig 0.16
  pub const ChannelLayout = union(enum) {
      mono, stereo, surround_5_1, surround_7_1,
      ambisonic: struct { order: u8, ordering: AmbiOrdering, norm: AmbiNorm },
      discrete: u16,                              // N anonymous channels, no positional identity
      custom:   struct { count: u16, id: PositionSetId },
      pub fn count(self: ChannelLayout) u16 { /* (order+1)^2 for ambisonic, etc. */ }
  };
  pub fn Frame(comptime Lane: type, comptime L: ChannelLayout) type {
      return struct { ch: [L.count()]Lane };      // element layout-identity; the BUFFER is
  }                                               // PLANAR per §9.3 (C planes), not []Frame for C>1
  ```
- **`Bounded(T, Kmax)` liveness** is over the fixed `[Kmax]` *storage*, so coloring is unaffected by
  `len`; correctness is the consumer respecting `len`. Storage colorability ⊢; `len`-respect ▷.
  **(LOCKED — closes open question §4.5 of the bridge: storage is static so coloring is fine; the
  consumer-respects-`len` contract is sufficient. Rationale: nothing on the hot path reads past `len`,
  and the only failure mode — a consumer ignoring `len` — is an ordinary block bug caught by the
  gold-vector oracle.)**
- **Control elements.** `Scalar(T)` and `FeatureFrame(K)` double as the element types of **parameter
  ports** (§2.4): the *same* typed element carried on a **control-rate** edge and consumed as a
  *coefficient* rather than a sample stream. ⊢ (type identity — a parameter port is a port *kind*, not
  a new element type).

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

- **(M1) rate-1:1.** `out.len == in.len` on every call, where `in` ranges over the block's **sample
  (stream) input ports only**. **Parameter ports** (§2.4) are side inputs **exempt from M1** — they
  deliver one control value per call, not a length-`N` window. ⊢ (enforced by the contract /
  classifier, which excludes `node.param.*` from the rate-1:1 law). For a **Source** (a block with
  *zero* sample-input ports, §2.7) M1 is **vacuous** and `out.len` is set instead by the pull demand
  `N` (SR1).
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
- **(R5) single-rate per block.** `out_per_in` is **one ratio for the whole block**, not per-output-
  port. A processor whose several outputs run at *different* rates (a wavelet/octave decomposition, a
  multi-rate CQT) is **not** one `Rate` block; it **decomposes** into a cascade/bank of uniform-rate
  `Rate` stages (each stage's outputs share one rate — e.g. a 2-band analysis stage is `1→2` with
  both outputs decimated-by-2). ⊢ (the contract carries a single ratio). *Rationale: a single-ratio
  `pull`/`needed_input` keeps the scheduler recursion (§8) decidable; a per-output-port-rate contract
  would reintroduce exactly the multi-rate scheduling complexity C1 exists to contain.* (Closes
  assessment §4.B.)

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

### 2.4 Parameter ports (control ports) — control-rate side inputs (C1 refinement; LOCKED 2026-06-03)

A **parameter port** (control port) is a **port *kind* distinct from a sample/stream port** — not a
third morphism class. A sample port carries a per-call window `[]A` of a stream (length `N`, one
element per sample/frame); a **parameter port carries one value per render call** of a *control
element* (`Scalar(T)` or `FeatureFrame(K)`, §1.3) — a node's **coefficient**, not a stream to
process. A parameter port is the **in-graph analogue of `set`** (§10): a parameter slot is driven by
**either** an external `set`/`schedule` **or** a wired parameter edge from another node's output, the
two being **two sources of the same per-block-ramped coefficient**.

A parameter port is declared as a **comptime struct-of-(name → control-element-type)** (mirroring
`Concat`, §4.3), minting a typed `PortId` per field exposed as `node.param.<name>`; `connect`
type-checks it and a wrong element type is a ⊢ compile error naming the port. Sample ports stay in the
`process`/`pull` signature, so M1 (§2.1) visibly ranges over slices only.

**Laws** (a conforming parameter port satisfies all):

- **(P1) exempt from M1.** A parameter port does **not** constrain `out.len`; it is a side input. ⊢
  (the classifier excludes `node.param.*` from the rate-1:1 law).
- **(P2) one source.** A parameter slot has **at most one** driver — `set`/`schedule` **xor** a wired
  parameter edge, **never both**; both is a commit error. ⊢ (decidable at commit). *Rationale: a
  base-plus-modulation-offset "modulation matrix" is a deliberate Rule-2 deferral; one source keeps
  the semantics unambiguous.*
- **(P3) ramp/hold by the same policy as `set`.** The consumer applies the per-block ramp of §10: the
  latest control value is **held** between updates (the producer may emit at any rate ≤ the
  consumer's; a `Rate` producer emitting 0 this call → hold previous) and **ramped** target→target
  across the buffer (continuous params), or switched at a sub-block boundary (stepped params, via the
  event lane §8.6). **NOT sample-accurate by contract** unless the value arrives via `schedule` (§10).
  ▷ that the author treats the port as a coefficient (not smuggling samples through it); ≈ that the
  ramp/hold is zipper-free.
- **(P4) ordinary edge otherwise.** A parameter edge is a real graph edge: **colored** on its
  control-element pool (§7.2), **scheduled** before its consumer (a normal dependency in the topo
  sort, §8.2), and **subject to SCC-has-delay** (§5.2) — a delay-free parameter feedback loop is
  rejected by `error.DelayFreeLoop` like any edge. ⊢.

**Rate reconciliation (closes the parameter side of the cross-rate-input question, assessment §4.D).**
A control-rate parameter edge entering a faster consumer is reconciled by the **ramp/hold coercion**
the negotiation pass inserts (§6) — the parameter analogue of a resampler on a sample-rate-mismatched
edge. *Genuine cross-rate **sample** inputs* (two stream ports at different rates into one block) are
**not** auto-reconciled; they require an explicit rate adapter (resampler/framer) — only parameter
ports auto-coerce (multi-input rule, §8.8).

**Core vs library.** The **port-kind machinery** (declaring, typing, sizing, classifying parameter
ports; the ramp/hold coercion insertion) is a **small core refinement** of the port system (it must
hold at comptime/commit — H2/H3). The **modulation blocks** that consume parameters (LFOs,
adaptive-coefficient drivers, feature→param maps) are **layered library**. *Illustrative — Zig 0.16:*

```zig
const Biquad = struct {
    // sample ports — classified from process(); M1 ranges over THESE
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void { ... }
    // parameter ports — struct-of-(name → control element); minted as node.param.<name>
    pub const params = .{ .cutoff = Scalar(f32), .q = Scalar(f32) };
};

try g.connect(lfo.out, biquad.param.cutoff); // in-graph `set`; ⊢ error if lfo.Out != Scalar(f32)
// biquad.set(.cutoff, 1000.0);              // external source — MUTUALLY EXCLUSIVE with the wire (P2)
```

> **Why this resolution (Rule 7, adopted 2026-06-03 over "fuse-only").** The corpus's
> adaptive/modulated algorithms (AEC, AGC, dynamics, howl suppression, chorus) remain *fusable into
> one block* as before; parameter ports **additionally** make *decoupled* modulation (an LFO/feature
> node driving a separate filter) a first-class graph citizen **without a third morphism class**, and
> **unify** external `set` with in-graph modulation under one ramp policy. (Closes assessment §4.A.)

### 2.5 `warmup_samples` — the offline data-parallel chunking contract (COMMITTED 2026-06-03)

A block may declare an **optional** `warmup_samples` field, sibling to `algorithmic_latency`, used
**only** by the **OfflineBatch** mode's data-parallel timeline chunker (§8.10;
[`pan_parallel_and_offline_execution.md` §3.3](pan_parallel_and_offline_execution.md)). It has **no
effect on RealtimeStreaming** (which never partitions the timeline). A chunk rendered over `[t, t+L)`
is fed `[t − warmup_samples, t+L)` with the first `warmup_samples` outputs discarded, reconstructing
the block's boundary state:

```zig
pub const warmup_samples: usize;     // lead-in to reconstruct boundary state for a timeline chunk
pub const warmup_exact: bool = true; // true: warmup is exact (FIR/STFT) → bit-exact chunked merge;
                                     // false: tolerance-bounded (IIR/feedback) → allclose merge
```

**Laws:**
- **(W1) presence gates chunkability.** A stateful block **absent** `warmup_samples` is **not
  chunkable**; the chunker forces its path through pipeline parallelism (§8.10) instead, and chunking
  such a block is a commit/build error. ⊢ (A18). Pure stateless `Map`s are chunkable with
  `warmup_samples = 0`.
- **(W2) exactness class.** `warmup_exact = true` (FIR/STFT/finite-memory LTI; `warmup_samples` =
  impulse-response/window span) ⇒ the chunked render is **bit-identical** to sequential (O3).
  `warmup_exact = false` (IIR/FDN/long feedback; `warmup_samples` = decay-to-tolerance length) ⇒
  **allclose within the block's declared tolerance**. ≈ tested (B13, the offline differential test).
- **(W3) numerical accuracy is the author's claim.** That a declared `warmup_samples` actually achieves
  bit-exactness or the stated tolerance is **▷** (C11), discharged ≈ by the offline differential test
  (`K=1` ≡ `K=ncores`, §8.10; [`pan_parallel_and_offline_execution.md` §3.5](pan_parallel_and_offline_execution.md)).

### 2.6 `VariRate` — bounded-variable-rate `Rate` (COMMITTED 2026-06-03; closes audit finding #2)

A `Rate` whose actual out:in ratio varies at runtime declares a **bounded interval** instead of a point
ratio — discriminated **⊢ at comptime by field presence** (`rate_bounds` xor `out_per_in`), exactly as
Map-vs-Rate is discriminated. The pull contract (`pull(want, out) → produced`, §2.2) is *already*
rate-elastic, so the **operational** path is unchanged; only the **static-planning** quantities
generalise from a point ratio to an interval.

```zig
// illustrative — Zig 0.16
pub const Ratio = struct { p: u32, q: u32 };
pub const RatioInterval = struct { min: Ratio, nominal: Ratio, max: Ratio };

pub const rate_bounds: RatioInterval =
    .{ .min = .{ .p = 1, .q = 2 }, .nominal = .{ .p = 1, .q = 1 }, .max = .{ .p = 2, .q = 1 } };
pub const max_latency: usize = 2048;              // worst case over the interval — for PDC (§7.7)
pub const ratio_source: enum { parameter, internal_controller } = .parameter;
pub const params = .{ .ratio = Scalar(f32) };     // when .parameter: the in-graph operating point (§2.4)
```

**Laws** (a conforming `VariRate` satisfies all):
- **(V1) bounded interval + worst-case latency present.** `rate_bounds` (with `min ≤ nominal ≤ max`)
  and `max_latency` are both declared; missing either is a build error (the R1 analogue). ⊢ field
  presence; ≈ that the block honours the bound (latency-contract / `needed_input` tests).
- **(V2) worst-case static planning.** Buffer sizing and `needed_input(want)` use the `min` ratio (the
  most input ever needed); PDC (§7.7) uses `max_latency`. ⊢ (decidable from the declaration) → H2 stays
  bounded.
- **(V3) ratio held per call.** The operating ratio is sampled **once per render call** (held across the
  buffer like any parameter, §2.4 P3) — never mid-call, preserving per-call reduction order and
  sub-block determinism. ⊢ structural (sample-once); ▷ the controller mutates only at call boundaries.
- **(V4) determinism class — the honest split.** A **parameter-driven** ratio (deterministic automation)
  ⇒ **O3-reproducible** (§11.1b). A **controller-driven** ratio (drift PI on a wall-clock FIFO) ⇒ **≈
  only**, inherently empirical — the *same class as clock drift* (the §10 ASRC bound). Correct, not a
  defect: drift compensation cannot be bit-reproducible.
- **(V5) single interval per block.** One `rate_bounds` for the whole block (the R5 single-rate
  analogue), keeping the scheduler recursion (§8) decidable on interval endpoints. ⊢.

> **Membership.** The device-boundary **adaptive drift-ASRC** (§10) *is* a `VariRate`
> (`ratio_source = .internal_controller`, tight interval around nominal); **varispeed / scrub
> sample-playback** (`param.ratio ∈ [0.5, 2]`); **runtime-stretch TSM / phase-vocoder** (the STFT/iSTFT
> stay fixed-rate; the *variable synthesis hop* is the `VariRate` seam) and **pitch-shift**
> (TSM ∘ resample) compose from it. A **fixed** stretch factor needs none of this — it is an ordinary
> fixed-`out_per_in` cascade.

### 2.7 Sources — the zero-sample-input contract (LOCKED 2026-06-03; closes audit finding #3)

A **Source** is any block with **zero sample-input ports** (it may still carry parameter ports §2.4 and
read the event lane §8.6). It is **not** a new morphism class — it is a `Map` or `Rate` whose `in` side
is empty:

- **(SR1) pure generator = `Map`, zero sample-input.** Oscillator, noise, wavetable, constant. M1
  (§2.1) is vacuous over the empty sample-input ports; the complementary rule sets **`out.len` = the
  pull demand `N`** delivered by the mux's `getOutputBuffer` (§4.1). Its phase / RNG / table-cursor is
  ordinary per-sample Mealy state advanced by `N`. ⊢ (the classifier: zero sample-input ⇒ length from
  the pull, not from `in.len`). Driven only by parameter ports and the event lane.
- **(SR2) stream / sample source = `Rate` (or `VariRate` §2.6) source.** Owns a read cursor over a
  backing store / prefetch FIFO; `pull(want, out)` produces from it. **Sample playback at arbitrary
  pitch is `VariRate`** (`param.pitch`). The off-thread prefetch source
  ([io §5](pan_io_realtime_and_pipeline.md)) is this kind. ⊢ field presence; ≈ numerics.
- **(SR3) every non-feedback path is source-rooted.** A path whose head is neither a Source nor a
  persistent generator (§5.3) is empty — a commit error. ⊢ (decidable graph check).

```zig
// illustrative — Zig 0.16
const Oscillator = struct {                        // pure generator: Map, zero sample-input
    phase: f32 = 0,                                // internal Mealy state
    pub const params = .{ .freq = Scalar(f32), .shape = Scalar(f32) };
    pub fn process(self: *@This(), out: []Sample(f32)) void { _ = self; _ = out; } // out.len == pull N
};
```

---

## 3. Composition, identity, and flattening (the category laws)

- **Composition** `g ∘ f` is **wiring** an output port of `f` to an input port of `g`; it is defined
  **iff** the shared edge's Formats unify (§6). The **flowgraph is a finite diagram** in **Stream**.
  Wiring may target a **sample port** or a **parameter port** (§2.4); both are edges of the diagram
  (a parameter edge is exempt from the rate-1:1 law but is otherwise an ordinary edge — §2.4 P4).
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
| `RingSampleMux` | the offline push transport (Tier C / OfflineBatch) | **COMMITTED (phased)** §8.10 |

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
path. The library ships canonical `UnitDelay(z⁻¹)` / `DelayLine(len)` primitives. Synth **voice pools**
(§8.12) and instrument **assets** (wavetables, sample sets, impulse responses) are likewise persistent
— allocated once at `initialize`, sized by a comptime capacity. *(Symbol note: in `Frame(Lane, L)` the
second parameter is the channel **layout** §1.3; in `DelayLine(len)` it is the delay **length** —
distinct local bindings.)*

### 5.4 The two feedback idioms

- **Graph-level `DelayLine`-in-a-cycle** — composable, scheduler-visible, **one-block latency**. The
  default; the delay is an ordinary node.
- **Fused single-`Map` tight-feedback kernel** — the per-sample feedback loop runs *inside* one
  rate-1:1 `Map.process` over fixed persistent state; the `z⁻¹` lives per-sample inside the kernel, so
  feedback is **sample-accurate**. The trade is explicit: **forfeit scheduler-visibility** (opaque to
  the colorer; cannot be fused/split across the loop) **for sample-accuracy**. pan ships **ladder /
  Karplus-Strong / comb** as such kernels. These are typically **not** `aliasing_safe`. A block-size-1
  *subgraph* combinator (composing tight feedback from sub-blocks) is **explicitly deferred** (Rule 2).

### 5.5 Beyond scalar `z⁻¹` — element-generic delay & matrix feedback (LOCKED 2026-06-03)

The `z⁻¹` law (§5.2) is element-agnostic, and so is its primitive: **`UnitDelay`/`DelayLine` are
element-generic** over the canonical set (§1.3) — `UnitDelay(Sample(T))`, `UnitDelay(Frame(Lane,L))`,
`UnitDelay(Complex(T))`, `UnitDelay(FeatureFrame(K))`. Two corpus idioms follow with **no new core
construct**:

- **Frame-/spectrum-granular feedback** (phase-vocoder phase accumulation, spectral feedback, or
  "flux vs the previous spectrum" expressed as a graph edge rather than block-internal state) is a
  back-edge whose delay element is a `UnitDelay(Complex)` / `UnitDelay(Frame)` — the *unit of delay is
  a frame*, not a sample; the SCC-has-delay check (§5.2) applies unchanged.
- **FDN / matrix feedback** (Schroeder/FDN reverb) = **N `DelayLine` nodes + a matrix-mix `Map` over
  `Frame(Lane,.discrete(N))` + feedback edges** (`N` = FDN order); the mixing transform lives *inside*
  the trace and the SCC contains the delay lines, so the loop is legal (⊢ `error.DelayFreeLoop`
  passes). A "vector feedback edge" is just an edge carrying `Frame(Lane,.discrete(N))` (or `N` scalar
  back-edges).

(Closes assessment §4.E — composes from stated primitives.)

---

## 6. Format negotiation — unification making the diagram commute (⊢ structure, ≈ arithmetic)

At graph-commit, the negotiation pass propagates Formats (§1.2) along edges and solves a **unification
problem over the product object**: each wired edge imposes an equality constraint on the shared
Format. Where the user wired **incompatible-but-coercible** Formats, the pass **inserts a coercion
morphism** so the diagram **commutes**:

| Mismatched axis | Coercion morphism inserted |
|---|---|
| sample rate | resampler (polyphase sinc; adaptive drift-ASRC at device boundary) |
| channel layout `L` | a **registered** canonical up/down-mix matrix (e.g. `.stereo → .surround_5_1`); an **unregistered** pair (`.custom → .ambisonic`) is a **hard mismatch** requiring an explicit spatial block, not an auto-coercion (L2 §1.3) |
| precision `T` | precision cast (monomorphized seam converter) |
| rate ratio | framer / rate adapter |
| **parameter (control) edge rate** | **ramp** (continuous params) / **hold** (stepped params) coercion — the parameter analogue of a resampler, reconciling a control-rate parameter edge (§2.4) to the consumer's render rate (P3). Applies **only** to parameter ports; mismatched *sample* edges need an explicit adapter (§8.8). |

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
*feature-frame* rate domain). Requires a **static** reported latency per block (a fixed-rate `Rate`
block reports worst case; a `VariRate` block §2.6 reports its `max_latency` over the interval, V2).
Compensating delays come from the persistent category (§5.3). **≈ tested** (a dry/wet diamond around an
FFT path re-aligns sample-accurately).

### 7.8 The footprint formula (the H2 guarantee)

```
render_memory =  Σ_class  M_class · element_count_class · @sizeOf(element_type_class)   -- pools
               + Σ_feedback  delay_length · @sizeOf(elem)                                -- persistent
               + Σ_block  state_size                                                     -- per-block
               + Σ_pdc  comp_delay_length · @sizeOf(elem)                                -- PDC delays
```

All terms known at commit (at `comptime` on embedded) → one up-front allocation, zero hot-path alloc.
⊢ that the figure is a comptime constant for a comptime graph (the embedded smoke gate, §8.5).

**Tier-B addendum (§8.11).** Under the static-parallel executor, `M_class` is the peak *concurrent*
live-edge count (it grows vs. the sequential schedule), and a per-worker scratch term is added:
`+ Σ_worker scratch(worker)`. Both remain commit-known and statically bounded → H2 holds. **OfflineBatch
(O2)** uses a different, larger-but-pre-sized formula (rings + per-chunk pools):
[`pan_parallel_and_offline_execution.md` §3.6](pan_parallel_and_offline_execution.md).

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
| **B** | static-parallel RT: commit-time **HEFT** schedule + **point-to-point** release/acquire ready-flags (no global barrier) + OS **audio workgroup** + concurrency-aware coloring; cost-model gated; auto-demotes to A | **COMMITTED (phased)** | the spin-barrier objection (M3 P/E migration → unbounded) is removed by **workgroup co-scheduling** bounding the spin to one op; gate (§8.10) enables it only when `W/S` and headroom justify it. Detail: [`pan_parallel_and_offline_execution.md` §2](pan_parallel_and_offline_execution.md). A naïve **level-barrier fork-join** is retained as a simpler evolution stage on the *same* foundation. |
| **C** | threaded push (large rings, condvars) **+ data-parallel timeline chunking** | **COMMITTED (phased)** | offline file→file / batch; latency irrelevant, throughput rules. Reuses the same blocks via `RingSampleMux`; chunking uses `warmup_samples` (§2.5). Detail: [`pan_parallel_and_offline_execution.md` §3](pan_parallel_and_offline_execution.md). |

> **Tiers map onto two dev-facing execution modes (§8.10, C6):** **RealtimeStreaming** = Tier A (1
> core) *or* Tier B (P cores); **OfflineBatch** = Tier C. The graph and its blocks are
> **execution-mode-invariant** (the Yoneda probe, §4.2); the executor is chosen at engine instantiation.

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

### 8.6 Events & sub-block rendering — the typed event lane (refined 2026-06-03)

The **event lane** parallel to the sample lanes is **`EventLane(Event)`**, parameterised by a comptime
`Event` type the consuming block chooses (event-type-**generic**, exactly as ports are
element-generic). It carries a time-sorted `(sample_offset, event)` list. The pull scheduler renders in
**sub-blocks bounded by event offsets** — pull `[0,k)`, apply event, pull `[k,N)`. Free for `Map` by
(M2). `Rate` blocks quantize events to their hop grid.

pan ships a blessed **`NoteEvent`** library union for instruments — **pitch is in Hz** (tuning-agnostic,
microtonal-friendly; a note#→Hz tuning block is library):

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

**Laws:**
- **(EV1) Event-generic mechanism.** Sample-accurate dispatch + the sub-block split hold for *any*
  `Event`; an Analyzer (§8.13) picks a trivial/automation `Event` and pays no music-model cost. ⊢ (the
  split keys only on `sample_offset`, never on the payload).
- **(EV2) `note_id` routing.** `note_id` enables per-note (MPE) routing to a specific voice in
  `PolyVoice` (§8.12). ▷/≈.
- **(EV3) onset accuracy.** Note onsets are sample-accurate via the sub-block split; `schedule` (§10)
  remains the only sample-accurate *parameter* source. ⊢ mechanism; ≈ the block's response.

### 8.7 Error isolation

On the RT path a faulting block (NaN, domain error) **emits silence and raises a flag** consumed by the
control thread; the graph keeps running (contrast the offline path's deliberate collapse-on-error,
which is correct for batch). ▷/≈.

### 8.8 Multi-input pull rule (LOCKED 2026-06-03)

A block may have several input ports. The pull scheduler satisfies **each input edge independently**
via its producer's `needed_input(want)` (§2.2) and the topological order (§8.2). **Same-rate**
multi-input is the normal case (AEC mic+reference, sidechain compression, crossover sum, summing
mixers); latency *across* the inputs is aligned by **PDC** (§7.7). **Genuine mixed-rate *sample*
inputs require an explicit rate adapter** (resampler/framer) on the slower edge — there is **no
implicit sample-stream reconciliation**, and a wired sample-rate mismatch without an adapter is a
negotiation error (§6). The *only* auto-reconciled cross-rate input is a **parameter port** (§2.4),
whose ramp/hold coercion (§6) bridges control rate to render rate. ⊢ (the adapter is an ordinary
inserted coercion). (Closes the sample side of assessment §4.D.)

### 8.9 Conditional execution is out of scope — data-gating only (LOCKED 2026-06-03)

The render op-list (§8.2) is **static and unconditional**: every op runs every callback, with zero
graph walking — this is what makes the hot path deterministic, wait-free (H1), and WCET-analyzable.
pan therefore provides **no conditional/gated execution** (no "skip these ops when a VAD says
silence"). Gating — VAD/onset/power gating — is expressed as **data-gating**: the gate is a `Scalar`
control value the downstream block multiplies in or freezes on (typically via a parameter port,
§2.4), so the *output* is gated while the *schedule* is unchanged. This is the **permanent**
disposition (decided 2026-06-03): conditional execution is **not** a deferred optimization, it is
**out of scope**, keeping the C2 static-op-list invariant pure. (The cost is computing-then-discarding
on a gated branch; on the RT path determinism outweighs it, and an expensive feature/viz branch
belongs on a *non-RT analysis root* (§8.3) where its cost cannot cause an xrun regardless.) (Closes
assessment §4.C.)

### 8.10 Execution modes & the Executor triple (C6/C7; COMMITTED 2026-06-03)

The graph (the diagram in **Stream**, §3) and its blocks are **execution-mode-invariant** — the
operational consequence of the Yoneda/`SampleMux` probe (§4.2): a block is determined by its action on
the buffers a mux presents and never knows its executor. The *same* graph runs under one of **two
dev-facing execution modes**, chosen at engine instantiation; the **Executor** is a commit-computed
triple `(Schedule, Driver, MemoryPlan)`:

| Mode | Driver | Deadline | Invariants | Tiers (§8.4) |
|---|---|---|---|---|
| **RealtimeStreaming** | pull / clock-driven (§8.3) | hard `N/Fs` | **H1–H3** (§11.1) | **A** (sequential, 1 core) · **B** (static-parallel, P cores) |
| **OfflineBatch** | push / input-exhaustion | none (throughput) | **O1–O3** (§11.1b) | **C** (pipeline ‖ chunked) |

The mux family **is** the mode selector: `PullSampleMux` (± the Tier-B parallel executor) realises
RealtimeStreaming; `RingSampleMux` realises OfflineBatch. No `process`/`pull` signature or port type
changes between modes. Full spec: [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md).

**Tier B cost-model gate (⊢ decidable, A14).** Over the committed op-list the commit pass computes total
work `W = Σ_op c(op)` and span `S` (critical path of the DAG-minus-feedback-edges); Tier B is enabled
**iff** `W > deadline·θ_busy` (one core can't keep up) **and** `W/max(S, W/P) ≥ θ_speedup` (the graph is
genuinely parallel — a near-linear chain `S≈W` is refused) **and** the workgroup is available; worker
count `P = clamp(⌈W/(deadline·target_headroom)⌉, 1, cores)`. Otherwise the executor is **Tier A**. The
RT-side cross-worker handoff is a **single-writer release/acquire ready-flag** (no CAS); its spin is
bounded **only while the OS honours workgroup co-scheduling** (▷/≈, the same honesty class as FTZ §10) —
backed by spin-time/headroom telemetry (§10 of the I/O doc) and **auto-demote to Tier A** under
sustained low headroom. **Tier B output is bit-identical to Tier A** (op-granular scheduling preserves
per-op reduction order; A17) — verified by the **parallel≡sequential differential test** (B9).

### 8.11 Concurrency-aware coloring (Tier B) — the colorer refinement (⊢, A15/A16)

Under a **static** Tier-B schedule, two edges interfere **iff their producing/consuming ops' execution
intervals overlap in the schedule** — an **interval graph on the schedule-time axis**, so the §7.2
optimality theorem **still applies** (only the time axis changes; this corrects the earlier "Tier B
contaminates the colorer" pessimism). Consequences: `M_class` grows to the peak *concurrent* live-edge
count (footprint larger but still statically bounded → H2); in-place coalescing (§7.4) gains a **fourth
gating condition — (iv) producer and consumer are not concurrently scheduled** (A16); op-internal
transients become **per-worker scratch pools** (a bounded additive footprint term, §7.8). Detail:
[`pan_parallel_and_offline_execution.md` §2.5](pan_parallel_and_offline_execution.md).

### 8.12 Polyphony is intra-block, fixed-capacity — `Voice` / `PolyVoice` (LOCKED 2026-06-03; closes audit finding #4)

The render op-list is static and unconditional (C2, §8.9), so a note-on **cannot** spawn a graph node on
the audio thread. Dynamic-cardinality polyphony therefore lives **inside one fixed-capacity block**,
composed from persistent state (§5.3) + the event lane (§8.6) + data-gating (§8.9) — **no new core
construct**.

A **`Voice`** is a **composite block** (§3) — a packaged subgraph (`osc → env → filter → VCA`), flattened
to its normal form; its pitch/velocity/mod are parameter ports (§2.4) set per note. **`PolyVoice(Voice,
Vmax)`** is structurally the **`ChannelMap` functor (§4.4) applied over *voices*** (a `VoiceMap(Voice,
Vmax)`) + an **allocator** (note→slot, steal oldest/quietest when full, with a release ramp) + a
**summing mixer**. Two realisations (the §5.4 fused-vs-graph trade, applied to voices):

- **Fused `PolyVoice`** (one block, internal voice loop): may **internally skip** inactive voices — a
  block-internal `for active_voices` loop, *not* a graph-op skip, so §8.9's static op-list is intact
  (exactly as the §5.4 tight-feedback kernels run an opaque internal loop). Voices are persistent state
  (§5.3); `Vmax` comptime ⇒ footprint bounded (H2). **Preferred for large `Vmax`** (only sounding voices
  cost CPU).
- **Replicated voice-nodes** (`VoiceMap(Voice, Vmax)`, scheduler-visible): all `Vmax` run every callback
  (compute-and-discard, §8.9); simpler, good for a small fixed voice count.

```zig
// illustrative — Zig 0.16
pub fn PolyVoice(comptime Voice: type, comptime Vmax: usize) type {
    return struct {
        voices: [Vmax]Voice,                 // persistent state (§5.3), allocated at initialize
        // process(self, ev: EventLane(NoteEvent), out: []Frame(Lane, L)):
        //   note_on    -> alloc a free slot (steal oldest/quietest if full; release-ramp the stolen)
        //   expression -> route by note_id to the owning slot (MPE, EV2)
        //   render     -> sum active slots into `out`; inactive slots internally skipped (§8.9 intact)
    };
}
```

**Laws:**
- **(Y1) one static op, bounded footprint.** `Vmax` comptime ⇒ the voice pool is a commit/comptime
  constant (H2); the block is a single static op (C2/§8.9 preserved — no dynamic node, no conditional
  graph op). ⊢.
- **(Y2) sample-accurate onsets.** Note-on/off arrive via the event lane and apply at sub-block
  boundaries (§8.6 EV3). ⊢ mechanism; ≈ the block's response.
- **(Y3) voice-stealing & click-free release are authoring obligations.** Which voice to steal, and
  ramping a stolen voice (the §6/§10 click-free policy applied internally). ▷/≈ (gold-vector /
  behavioural test).
- **(Y4) dynamic voices-as-nodes is out of scope.** Per-note *graph* expansion would need a dynamic
  op-list — the very thing §8.9 rules out. A *fixed* small voice count as explicit nodes is already
  expressible via `VoiceMap`/`ChannelMap` static replication. ⊢ (by C2).
- **(Y5) per-note (MPE) routing.** Expression / pressure / bend events route by `note_id` to the owning
  voice slot (EV2 §8.6). ▷/≈.
- **(Y6) tuning, anti-aliasing & assets are authoring obligations.** Note→Hz tuning, oscillator
  anti-aliasing (PolyBLEP / band-limited wavetable vs a bandlimited oracle), and wavetable / sample /
  impulse-response assets loaded at `initialize` (persistent state §5.3) are the author's to get right.
  ▷/≈ (gold-vector).

### 8.13 The two canonical graph shapes — Analyzer and Instrument (framing; ▷)

pan's core (typed-stream objects §1, Map/Rate morphisms §2, the SampleMux/Yoneda probe §4, colored pools
§7, clock-driven pull roots §8.3) is **direction- and purpose-agnostic by construction**: the executor
renders the same diagram whether a stream originates at a microphone, a file, or an oscillator, and
whether it terminates at a feature collector or a loudspeaker. **Two canonical graph shapes** are
first-class applications of the one core:

| Shape | Pull root(s) | Sources | Sinks / leaves | Application |
|---|---|---|---|---|
| **Analyzer** | analysis pull root, non-RT (§8.3) + optional audio passthrough | device/file audio source (SR2) | `FeatureCollectorSink`, taps | feature extraction; the `1.md` viz |
| **Instrument** | audio-device sink = RT callback root (§8.1) | generators (SR1) + event/MIDI source | device sink (+ optional analysis tap) | synthesis; digital instruments |

Both compose freely (an instrument with a feature-reactive modulator; an analyzer that resynthesizes).
**Framing, not theorem** (Rule 7, §0.3): this is the Yoneda/`SampleMux` mode-invariance (§4.2) read
across *direction* as well as transport — it constructs no proof, it names the two uses the one core
serves. The execution **modes** (RealtimeStreaming / OfflineBatch, §8.10) are orthogonal: an Instrument
renders live (RealtimeStreaming) or bounces a MIDI timeline to file (OfflineBatch, O3-reproducible); an
Analyzer likewise streams or batch-processes a file.

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

- **Internal channel form: PLANAR** (LOCKED — **STRICTLY ENFORCED**). Planar internally (SIMD-friendly
  `@Vector` kernels); planar↔interleaved conversion happens **only at the I/O boundary**.
  *(Closes bridge §4.2.)*
  - **What planar means, precisely (the enforced law).** A multi-channel stream buffer of `N` frames on
    layout `L` (count `C := L.count()`) is stored as **`C` contiguous channel planes of `N` samples**,
    **plane-major** — `[ch0_0 … ch0_{N-1}][ch1_0 … ch1_{N-1}] …` — NOT as an array of interleaved
    frames. A block reads/writes each channel as its own contiguous `[]Lane` plane (so a per-channel
    kernel vectorizes over a whole plane). `Frame(Lane, L)` names the element's **layout identity** for
    `connect` type-checking (count + positional tags + canonical order ride in `L`); it does **not**
    mandate the physical buffer be an array-of-structs of it.
  - **(P-1) Non-conformant: array-of-structs.** A buffer typed `[]Frame(Lane, L)` with
    `Frame = struct { ch: [C]Lane }` is **interleaved** (`L,R,L,R,…`) at the buffer level for `C > 1`,
    which **violates** this lock. (Mono `C = 1` is trivially conformant — one plane.) The element struct
    is fine as a *single-frame value*; the **buffer/port representation for `C > 1` must be planar**.
  - **(P-2) Conformance gate (⊢/≈).** The implementation must provide a planar buffer/port view and a
    gate asserting multi-channel stream buffers are plane-major (a comptime/`test` check on the buffer
    layout + the per-channel `[]Lane` access), so a regression to AoS fails loud. This is a core
    throughput requirement (multi-channel SIMD), enforced now to prevent drift as multi-channel blocks
    proliferate (the spatial library) — not retrofitted later.
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

- **Parameter sources — `set`/`schedule` xor a wired parameter edge (§2.4).** A node's parameter slot
  is driven by **either** an external `set`/`schedule` **or** an in-graph **parameter edge** (another
  node's control-rate output wired into `node.param.<name>`) — the two are the *same* per-block-ramped
  coefficient from two sources, and declaring **both** for one slot is a commit error (§2.4 P2). A
  wired parameter edge is the **in-graph analogue of `set`** (continuous, ramped, not sample-accurate
  by contract); `schedule` remains the only sample-accurate source.
- **Bypass-preserves-latency (named law)** — a bypassed block with `algorithmic_latency > 0` must
  **still delay** its signal by exactly that latency (route through the compensating `DelayLine` PDC
  already inserts), else bypass shifts timing and breaks alignment on parallel paths. Built-in bypass
  honours it automatically ⊢; a custom bypass author must route through the compensating delay (▷; a
  commit warning/error *where detectable*).
- **Transport** — sample-accurate play position, seek, loop, tempo/PPQ; the event lane timestamps
  against it; offline render is bit-reproducible regardless of wall-clock.
- **Clock-domain drift / ASRC** — separate input/output crystals drift; an adaptive (asynchronous)
  resampler — a **`VariRate` block** (§2.6, `ratio_source = .internal_controller`) — nudged by a slow PI
  controller on the bridging FIFO fill keeps it centered; bypassed on a single full-duplex clock. At the
  **device boundary**, not inside the graph. Its non-reproducibility is the V4 ≈ class, not a defect.
- **HALs (two, distinct)** — **Compute HAL**: portable comptime `@Vector(W,T)` SIMD (NEON/Helium/AVX),
  optional runtime-discovered accel (vDSP/FFTW/CMSIS-DSP, chiefly FFT). **I/O HAL**: CoreAudio (macOS,
  first) / ALSA+JACK/PipeWire (Linux) / I2S-DMA ping-pong (embedded). LPCM codecs convert interleaved
  device bytes ↔ internal planar at the edge, **reconciling the device/file channel order to the
  layout's canonical order** (§1.3, `L`): the permutation is ⊢ total/bijective for a known `L`, the
  bytes ≈.

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
> Tier-B/Tier-C *executors* are layered, but each must **discharge the invariant set of its mode**
> (RealtimeStreaming ⇒ H1–H3; OfflineBatch ⇒ O1–O3, §11.1b) — those discharge obligations are core.

### 11.1b Offline invariants (the OfflineBatch mode, §8.10) — distinct from H1–H3

| | Statement | Tier |
|---|---|---|
| **O1** | **No deadline; blocking is legal.** Offline stage/worker threads may lock, allocate, and block on bounded rings — throughput, not latency, is the objective. H1 does **not** apply. | declared (the point of the mode) |
| **O2** | **Bounded, pre-sized footprint** (rings + per-chunk/per-worker pools + per-block state), larger than H2 but **pre-allocated at commit** — no unbounded growth. | **⊢** the figure is a commit constant given ring depths and chunk-worker count; **▷/≈** stages/blocks honour it |
| **O3** | **Bit-reproducibility:** output is independent of thread count/scheduling — bit-identical to sequential for pipeline parallelism and exact-`warmup` chunking; allclose within declared tolerance for IIR-chunked blocks (§2.5 W2). | **⊢** ordered merge + fixed reduction order; **≈** per-block numeric equality (offline differential test) |

### 11.2 Commitments

- **C1** two block contracts `Map`/`Rate` (§2) · **C2** synchronous pull scheduler + render op-list
  (§8.2) · **C3** per-element-class colored buffer pool (§7) · **C4** precision-comptime /
  N-runtime / W-comptime-per-target + Numeric trait (§9, §1.4) · **C5** clock-driven pull roots (§8.3)
  · **C6** two execution modes (RealtimeStreaming / OfflineBatch) via the mux family, graph
  mode-invariant (§8.10) · **C7** static-parallel RT executor — commit-time HEFT schedule +
  point-to-point ready-flags + audio workgroup + concurrency-aware coloring, cost-gated, auto-demoting
  to Tier A (§8.10–§8.11; [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md))
  · **C8** purpose-agnostic core — the **Analyzer** & **Instrument** graph shapes from one core (§8.13),
  supported by `ChannelLayout` identity (§1.3 L1/L2), `VariRate` (§2.6), the Source contract (§2.7), the
  typed event lane (§8.6), and intra-block `PolyVoice` (§8.12).

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
only) · A6 channel-count match (`L.count()` in `Frame(Lane,L)`; the count facet of A21) · A7 `set` rejects sample-accuracy at the type level
· A8 `FeatureCollectorSink`-on-RT-root commit rejection · A9 precision-as-comptime (no runtime switch)
· the three in-place structural conditions (§7.4) · across-class pool disjointness (§7.5) ·
interval-coloring optimality (imported theorem, §7.2) · A10 parameter-port type match & exclusion
from M1 (§2.4 P1) · A11 parameter slot one-source `set`/`schedule` xor edge (§2.4 P2) · A12 parameter
edge under SCC-has-delay (§2.4 P4) · A13 `out_per_in` single-rate-per-block (§2.2 R5) · A14 Tier-B
cost-model gate is a decidable commit computation over `W`/`S`/cores/config (§8.10) · A15
concurrency-aware coloring is interval coloring on the schedule-time axis (imported optimality, §8.11)
· A16 in-place coalescing's fourth condition "not concurrently scheduled" (§8.11) · A17 Tier-B
op-granular scheduling preserves per-op reduction order ⇒ bit-exactness eligible (§8.10) · A18
`warmup_samples` presence gates chunkability; chunking a stateful block without it is a commit/build
error (§2.5 W1) · A19 offline ordered merge + fixed reduction order ⇒ partition-invisible output (O3,
§11.1b) · A20 realtime-token required on every Tier-B worker (FTZ ×P won't compile without it,
[`pan_parallel_and_offline_execution.md` §2.1](pan_parallel_and_offline_execution.md)) · A21 channel-layout
identity (count + position + order) matched at every wired edge (L1, §1.3) · A22 layout coercion is
registered-canonical-or-hard-mismatch (L2, §6) · A23 `VariRate` field presence (`rate_bounds`+`max_latency`)
and worst-case static planning decidable (V1/V2, §2.6) · A24 `VariRate` single interval per block (V5) ·
A25 Source zero-sample-input ⇒ `out.len` from pull `N` (SR1, §2.7) · A26 every non-feedback path
source-rooted (SR3) · A27 event-lane sub-block split is `Event`-generic (EV1, §8.6) · A28 `PolyVoice` is
one static op, `Vmax`-bounded footprint, no dynamic node (Y1/Y4, §8.12).

### 12.2 ≈ Tested (empirical evidence — NOT proofs)
B1 DSP numeric correctness — **gold-vector oracle** (SciPy/NumPy; *empirical evidence, relabelled from
"the methodology" — it shows presence, not absence of bugs*) · B2 colorer implementation correctness —
**B≡C differential test** (*the primary correctness check, NOT "the proof"*; the optimality is the
⊢ theorem in §7.2, the implementation's faithfulness is tested) · B3 `aliasing_safe` truth — B≡C /
paranoid mode · B4 `Rate` numeric contract (`out_per_in`, `algorithmic_latency`) — latency-contract &
dual-mux tests · B5 RT hygiene in practice (FTZ honoured, denormal behaviour) · B6 PDC arithmetic
across topologies · B7 wait-free hot path in practice (xrun counters) · push↔pull agreement (R4,
dual-mux) · `Concat`/`ChannelMap` behavioural laws (§3, §4.4) · state-update granularity (§2.1 M2) ·
B8 parameter-edge ramp/hold zipper-free (§2.4 P3) · B9 **parallel≡sequential differential test**
(Tier B bit-identical to Tier A, §8.10) · B10 **offline differential test** (`K=1` ≡ `K=ncores`;
bit-exact for exact-warmup, allclose for IIR, §2.5/§11.1b O3) · B11 HEFT makespan adequacy /
deadline-headroom under Tier B (§8.10) · B12 the workgroup actually bounds the cross-worker spin in
practice (spin-time telemetry, xrun counters, §8.10) · B13 declared `warmup_samples` achieves
bit-exactness (FIR/STFT) or its tolerance (IIR) (§2.5 W2) · B14 layout up/down-mix matrix numerics
(gold-vector, L2) · B15 `VariRate` honours `rate_bounds` / `needed_input` / `max_latency`
(latency-contract, V1/V2) · B16 parameter-driven `VariRate` is O3-reproducible, controller-driven is
≈-only (V4) · B17 Source generator numerics (oscillator anti-aliasing vs a bandlimited oracle) · B18
`PolyVoice` voice-stealing / MPE-routing behaviour (Y2/Y3, EV2).

### 12.3 ▷ Conventional (authoring obligation the system cannot enforce)
C1 Map "no cross-call accumulation" discipline (§2.3) · C2 `aliasing_safe` authoring accuracy · C3
no-malloc/lock on the audio thread (H1) · C4 `comptime_commit_safe` self-declaration · C5 state-update
granularity authoring · C6 bypass-preserves-latency for custom bypass · C7 `algorithmic_latency`
numerical accuracy · C8 correct `needed_input` implementation (R3) · C9 parameter port carries a
coefficient, not smuggled samples (§2.4 P3) · C10 no-malloc/lock/syscall on **any** Tier-B worker (H1
discipline ×P, §8.10) · C11 `warmup_samples` numerical accuracy (§2.5 W3) · C12 the OS honours
workgroup co-scheduling (target-verified feasibility, not proven — §8.10,
[`pan_parallel_and_offline_execution.md` §4](pan_parallel_and_offline_execution.md)) · C13 offline
stages/blocks honour the O2 pre-sized footprint (§11.1b) · C14 layout *geometry* correctness — speaker
positions / panning law / ambisonic decode (block data, L3) · C15 `VariRate` controller stability &
ratio-held-per-call discipline (V3/V4) · C16 oscillator anti-aliasing authoring (Y6) · C17 voice-stealing
policy & click-free release (Y3) · C18 instrument tuning (note→Hz) & asset loading at `initialize` (Y6).

> **Ledger-marker labels (C-tier disambiguation).** The conventional-tier items C1–C13 in §12.3 are a
> *separate numbering* from the commitments C1–C7 of §11.2; context disambiguates (§12.3 = authoring
> obligations, §11.2 = architectural commitments).

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
- **coercion morphism** — a converter (resampler / channel matrix / cast / framer / parameter
  ramp-hold) inserted by negotiation to make the diagram commute. §6.
- **control port / parameter port** — a port *kind* carrying a control element (`Scalar`/`FeatureFrame`)
  at control rate, exempt from M1, ramped/held like `set`; the in-graph analogue of `set`, one source
  per slot (set/schedule xor edge). §2.4.
- **data-gating** — expressing VAD/onset/power gating as a `Scalar` gate the consumer multiplies/
  freezes on, leaving the static op-list unchanged; the **permanent** (not deferred) disposition of
  conditional execution. §8.9.
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
- **`Frame(Lane,L)`** — planar audio element on channel-layout `L : ChannelLayout` (count `C := L.count()`); `Sample(T) ≡ Frame(Lane,.mono)`. §1.3.
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
- **ramp/hold coercion** — negotiation-inserted reconciliation of a control-rate parameter edge to
  the consumer's render rate (ramp = continuous, hold = stepped); the parameter analogue of a
  resampler. §6, §2.4.
- **realtime token / `enterRealtimeThread()`** — FTZ-setting thread-entry token required by
  `renderInto`. §10.
- **render op-list** — the flat, replayed-per-callback schedule. §8.2.
- **`Sample(T)`** — one audio sample; `≡ Frame(Lane,.mono)`. §1.3.
- **`SampleMux`** — the 10-method block↔transport seam. §4.1.
- **`Scalar(T)`** — one scalar feature element. §1.3.
- **SCC** — strongly-connected component; must contain a delay (§5.2).
- **`set` / `schedule` / `edit`** — the three control verbs. §10.
- **`Stream`** — the category; objects are typed format-indexed streams `ℕ→A`. §1.
- **sub-block rendering** — splitting a render call at event offsets; free for `Map` (M2). §8.6.
- **Tier A / B / C** — sync-pull (CORE, frozen) / static-parallel RT (COMMITTED, phased — HEFT +
  point-to-point + workgroup) / threaded-push + chunking (COMMITTED, phased — OfflineBatch). §8.4,
  §8.10, [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md).
- **execution mode** — the dev-facing choice at engine instantiation: **RealtimeStreaming** (pull,
  hard deadline, H1–H3; Tier A or B) or **OfflineBatch** (push, throughput, O1–O3; Tier C). The graph
  is mode-invariant (Yoneda probe). §8.10 (C6).
- **Executor** — the commit-computed triple `(Schedule, Driver, MemoryPlan)` realising a mode/tier.
  §8.10.
- **HEFT** — Heterogeneous Earliest Finish Time; the commit-time list-scheduler mapping ops→workers
  (P/E-aware) for Tier B; a (2−1/P)-approximation of optimal makespan.
  [`pan_parallel_and_offline_execution.md` §2.2](pan_parallel_and_offline_execution.md).
- **cost-model gate** — the decidable commit check enabling Tier B iff `W>deadline·θ_busy` ∧
  `W/max(S,W/P)≥θ_speedup` ∧ workgroup available; picks `P`. ⊢ (A14). §8.10.
- **work / span (`W` / `S`)** — total op cost / critical-path length; the Brent/Graham makespan floor
  is `max(S, W/P)`. §8.10.
- **point-to-point ready-flag** — a single-writer release/acquire flag (keyed by per-callback
  generation) carrying a Tier-B cross-worker dependency; no CAS. §8.10,
  [`pan_parallel_and_offline_execution.md` §2.4](pan_parallel_and_offline_execution.md).
- **concurrency-aware coloring** — Tier-B coloring on the schedule-time axis (interfere iff scheduled
  intervals overlap); still an interval graph (optimal). §8.11 (A15/A16).
- **auto-demote** — telemetry-gated fallback from Tier B to Tier A under sustained low headroom (RCU
  plan swap, hysteresis). §8.10.
- **render-workgroup HAL** — the `{create, join, leave}` interface co-scheduling Tier-B workers: macOS
  `os_workgroup` / Linux SCHED_FIFO+affinity / embedded N/A; bounds the cross-worker spin (▷/≈, C12).
  [`pan_parallel_and_offline_execution.md` §4](pan_parallel_and_offline_execution.md).
- **`warmup_samples` / `warmup_exact`** — block declaration enabling OfflineBatch data-parallel
  chunking; lead-in to reconstruct boundary state (exact for FIR/STFT, tolerance-bounded for IIR).
  §2.5 (W1–W3).
- **O1 / O2 / O3** — the OfflineBatch invariants: blocking-legal / pre-sized bounded footprint /
  bit-reproducibility. §11.1b.
- **parallel≡sequential differential test** — Tier B output bit-identical to Tier A (≈ B9); **offline
  differential test** — `K=1` ≡ `K=ncores` render (≈ B10). §8.10, §2.5.
- **pipeline parallelism / data-parallel chunking** — the two OfflineBatch throughput levers:
  stage-per-thread+rings (exact) / timeline partition across cores (needs `warmup_samples`). §8.10,
  [`pan_parallel_and_offline_execution.md` §3](pan_parallel_and_offline_execution.md).
- **trace / traced monoidal** — the categorical model of feedback; well-defined only with a delay
  (load-bearing ⊢). §5.
- **transport** — sample-accurate timeline/position/tempo. §10.
- **`UnitDelay(z⁻¹)` / `DelayLine(len)`** — canonical persistent-state delay primitives (`len` = delay length, distinct from the channel-layout `L`); **element-generic**
  over the canonical set (`Sample`/`Frame`/`Complex`/`FeatureFrame`), enabling frame-granular feedback
  and FDN matrix feedback. §5.3, §5.5.
- **`Analyzer` / `Instrument`** — the two canonical graph shapes one core serves (analysis-rooted vs
  device-sink + generator-rooted); framing ▷. §8.13.
- **`ChannelLayout` / `L`** — comptime channel-layout *identity* (count + position tags + canonical
  order); layout mismatch is a ⊢ type error (L1); geometry is block data, not the type (L3). §1.3.
- **`EventLane(Event)`** — the comptime-`Event`-parameterised event lane; the sub-block split is
  `Event`-generic (EV1). §8.6.
- **`NoteEvent`** — blessed library instrument-event union (**pitch in Hz**): note_on/off, pressure,
  MPE expression, CC, pitch-bend, program. §8.6.
- **`PolyVoice` / `Voice` / `VoiceMap`** — intra-block fixed-capacity polyphony: a `Voice` is a composite
  block; `PolyVoice` = voice-replication + allocation + summing mix (Y1–Y4). §8.12.
- **`RatioInterval` / `rate_bounds`** — a `VariRate` block's bounded `{min, nominal, max}` rate interval.
  §2.6.
- **Source / generator** — a block with **zero sample-input ports**: pure generator = `Map` (`out.len`
  from pull `N`, SR1); sample/file source = `Rate`/`VariRate` (SR2); paths are source-rooted (SR3). §2.7.
- **`VariRate`** — bounded-variable-rate `Rate`; declares `rate_bounds` + `max_latency`, worst-case
  static planning, ratio held per call (V1–V5); the ASRC / varispeed / TSM seam. §2.6.
- **xrun** — a missed audio deadline (audible click). §8.1.
- **Yoneda probe** — the representability argument justifying dual-mux testing (load-bearing as a test
  strategy ≈, ornamental as a proof). §4.2.
- **`z⁻¹`** — a unit delay; required in every feedback SCC. §5.2.

---

---

## 15. Change log

- **2026-06-03 — amendment (dual-purpose / synthesis platform; findings #1–#7).** Restates pan as a
  **purpose-agnostic real-time audio DSP graph engine** serving two canonical graph shapes —
  **Analyzer** (feature extraction) and **Instrument** (synthesis) — from one core (§8.13, C8). Per
  locked decision (AskUserQuestion 2026-06-03): `NoteEvent` pitch in **Hz**.
  - **§1.2/§1.3 `ChannelLayout`** — `Frame(Lane, L)` carries comptime layout *identity* (count +
    position + order; L1/L2/L3); geometry is block data; negotiation auto-mixes only registered layout
    pairs (§6); the I/O codec reconciles channel order (§10). Closes finding #1.
  - **§2.6 `VariRate`** — bounded-variable-rate `Rate` (`rate_bounds` + `max_latency`; V1–V5); worst-case
    static planning in PDC (§7.7); the drift-ASRC restated as a `VariRate` (§10). Closes finding #2.
  - **§2.7 Sources** — the zero-sample-input contract (SR1 generator = `Map`; SR2 stream = `Rate`/
    `VariRate`; SR3 source-rooted paths); M1 refined for the source case (§2.1). Closes finding #3.
  - **§8.12 `Voice` / `PolyVoice`** — intra-block fixed-capacity polyphony (Y1–Y4) over persistent state
    (§5.3); no dynamic graph nodes (C2/§8.9 intact). Closes finding #4.
  - **§8.6 typed event lane** — `EventLane(Event)` + the blessed `NoteEvent` (EV1–EV3); MPE via
    `note_id`. Closes finding #5.
  - **§8.13 two graph shapes**, **§11.2 C8**, ledger §12 (+A21–A28, B14–B18, C14–C18), glossary §14.
    Propagated in the same commit to: type model (element/format/Numeric), execution model (§2 contracts,
    §8 events/source/scheduler), io (codecs, ASRC, transport, event lane), memory model (pool key `L`,
    persistent voices/assets), commit-pass (layout negotiation, worst-case PDC, source-rooted check),
    parallel/offline (V4 O3), testing (new gates), bridge (taxonomy, roadmap 6d, risk register),
    SPEC_INDEX (positioning).
- **2026-06-03 — amendment (parallel & offline execution; tiers B/C committed).** Promotes scheduler
  Tiers B and C from DEFERRED to **COMMITTED (phased)** under two dev-facing execution modes, per
  locked decisions (AskUserQuestion 2026-06-03): RT executor = **HEFT + point-to-point ready-flags +
  audio workgroup** (level-barrier fork-join retained as the simpler evolution stage on the same
  foundation); offline = **pipeline parallelism + data-parallel chunking** (`warmup_samples`);
  determinism = **bit-exact where the math allows** (Tier B ≡ Tier A; offline pipeline & exact-warmup
  chunking bit-exact; IIR-chunking allclose within declared tolerance); encoding = **new doc +
  coherent core amendment**.
  - **New companion** [`pan_parallel_and_offline_execution.md`](pan_parallel_and_offline_execution.md)
    (the full design: Executor triple, two modes, Tier-B foundation/HEFT/gate/sync/coloring/wait-
    freedom/auto-demote/bit-exactness, Tier-C pipeline+chunking, render-workgroup HAL).
  - **§8.4** tier dispositions B/C → COMMITTED; **§8.10** execution modes + Executor triple + Tier-B
    cost-model gate (C6/C7); **§8.11** concurrency-aware coloring (A15/A16).
  - **§2.5** `warmup_samples` block contract (W1–W3, A18); **§7.8** Tier-B footprint addendum;
    **§11.1/§11.1b** litmus extended + offline invariants O1–O3; **§11.2** commitments C6/C7.
  - **Ledger §12** (+A14–A20, B9–B13, C10–C13; C-marker disambiguation note); **glossary §14**
    (execution mode, Executor, HEFT, cost-model gate, work/span, point-to-point ready-flag,
    concurrency-aware coloring, auto-demote, render-workgroup HAL, `warmup_samples`, O1–O3, the two
    differential tests, pipeline/chunking). Propagated in the same commit to: execution model §5/§8;
    memory model (coloring/footprint); concurrency doc (worker-pool roles + point-to-point orderings);
    io doc (render-workgroup HAL + Tier-B telemetry); bridge/roadmap (taxonomy, open questions, risk
    register, roadmap 8–12); SPEC_INDEX.
- **2026-06-03 — amendment (parameter ports + gap resolutions).** Resolves the five gaps catalogued
  in [`../notes/pan_spec_algorithm_coverage_assessment.md`](../notes/pan_spec_algorithm_coverage_assessment.md) §4,
  per locked decisions (AskUserQuestion 2026-06-03): parameter ports for §4.A; permanent data-gating
  for §4.C; edit-in-place revision.
  - **§4.A / §4.D-param → §2.4 parameter ports** (new construct): control-rate side inputs, exempt
    from M1, one-source `set`/`schedule` xor edge, ramp/hold coercion (§6), ordinary edge for
    coloring/scheduling/SCC. M1 (§2.1) refined to range over sample ports; §10 unifies `set` with
    parameter edges; §3 admits parameter edges.
  - **§4.B → §2.2 R5:** `out_per_in` is single-rate-per-block; multi-rate filterbanks decompose into a
    cascade/bank of uniform-rate `Rate` stages.
  - **§4.C → §8.9:** conditional execution is **out of scope (permanent)**; gating = data-gating; the
    C2 static op-list stays pure. (No roadmap entry — decided permanent, not deferred.)
  - **§4.D-sample → §8.8:** multi-input pull rule — mixed-rate *sample* inputs need an explicit rate
    adapter; only parameter ports auto-coerce.
  - **§4.E → §5.5:** `UnitDelay`/`DelayLine` are element-generic; FDN = delays + matrix `Map`; both
    compose, no new construct.
  - Ledger §12 (+A10–A13, B8, C9), glossary §14 (control port, data-gating, ramp/hold coercion,
    element-generic delay) updated. Propagated in the same commit to: hub C1/§5; type model §1;
    execution model §2.1/§2.2/§2.3/§8.8/§8.9; io §7; memory model §5.5/§6; commit-pass; testing;
    bridge §1/§2/§5; SPEC_INDEX.

---

*Catalog locked 2026-06-02; **amended 2026-06-03** (§15). Author: Claude (Opus 4.8) via
Claude Code, with the `zig-0-16` skill consulted for all Zig-form claims.*
