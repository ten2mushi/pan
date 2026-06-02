# Architecture Audit — Does the Ideation Cleanly Hold the Feature-Extraction Corpus?

> **Status:** adversarial design audit. Tests `notes/architecture_ideation.md` against the
> *actual* algorithm classes in `research/`. Not a spec. Inputs: `notes/brief.md`,
> the `research/` corpus (sampled: STFT, MFCC, perceptual-sparse, onset/beat, dominant-band,
> resampling, gaps doc, end-to-end budgets), the `zig-0-16` skill (comptime generics,
> `@Vector`, the `ptr+vtable` idiom, slice/Complex types — verified against 0.16 semantics).
> Zig sketches below are illustrative and target 0.16.0 conventions.

---

## 1. Verdict

**Grade: B / B+. The architecture holds the *audio-effect* graph elegantly and holds the
*sequential* feature chain (MFCC) almost for free. It strains on three structural axes that the
feature corpus demands pervasively and the ideation barely mentions: (a) heterogeneous,
non-audio, multi-rate port data; (b) analysis-only sinks under a demand-driven pull scheduler;
and (c) per-channel subgraph replication.**

The ideation was written from the SDR→audio-*effects* delta (gain, EQ, pan, reverb, the literal
"pan"). Its three core decisions (pull scheduler §5.1, precision-comptime/N-runtime §5.2, colored
buffer pool §5.3) are sound and, in fact, *better* for feature extraction than they are for
effects in one respect: sub-block rendering (§6.1) makes hop-aligned framing trivial. But the
feature corpus is dominated by a different shape than effects: **one framed signal fans out to a
dozen parallel reductions that each emit a tiny per-hop vector, which fan in to one feature
frame, often replicated per channel, terminating at a collecting sink that never feeds audio
out.** Three primitives the ideation does not name are load-bearing for that shape:

1. A **`FeatureFrame`/typed non-audio port** story (the corpus emits `[]const Complex(T)`,
   `[K]f32` mel/chroma vectors, scalars, and structured records like PARCOR/formant sets —
   the ideation's `process(self, in:[]const T, out:[]T)` is mono-typed audio sample slices).
2. A **multi-rate / hop-rate port contract** (features arrive once per H samples, with
   hop < window overlap — the ideation has a "rate-elastic" escape hatch but no first-class
   "1 frame per H samples" port semantics or framing primitive).
3. An **analysis-sink pull-root** + a **channel-map combinator** (the corpus wants the same
   subgraph mapped over N channels and pulled by feature demand, not audio-output demand).

None of these is fatal; (1) and (2) are *missing core mechanisms* the spec must add, (3) is a
*library combinator* that should be designed now to avoid per-channel boilerplate. Details and a
graded list in §4.

**Top 3 strain points (expanded in §4):**

- **S1 — The port type is too narrow (CORE primitive needed).** `[]const T`/`[]T` with one `T`
  cannot carry the spectra, fixed-K vectors, scalars, and ragged/structured descriptors the
  corpus produces. The comptime "type signature *is* the API" machinery *can* carry richer types,
  but the ideation never commits to it, and the buffer-pool coloring (§5.3) and format
  negotiation (§6.5) are written assuming audio frames.
- **S2 — Hop-rate / overlapped framing is not a first-class port contract (CORE primitive
  needed).** Features fire once per hop with window > hop (overlap-add framing). The ideation
  folds *all* rate mismatch into "rate-elastic blocks declare `algorithmic_latency`", which
  conflates *latency* with *decimation/rate ratio*. A `Framer` primitive and an explicit
  output-rate-ratio in the format are needed; otherwise every feature author re-implements the
  STFT ring and the scheduler cannot reason about feature-frame demand.
- **S3 — Analysis-only sinks fight the demand-driven pull root (CORE clarification needed).**
  The pull scheduler is driven by the audio output's demand (§5.1). Most features are *taps*
  (the corpus calls them sidechains/analysis; ideation §8 lists them as "taps, not in the audio
  path's critical latency"). A pure-analysis graph (file → features → collector, the brief's
  visualization use case) has **no audio output to pull from**. The ideation has no pull root for
  analysis sinks.

---

## 2. What the Research Corpus Actually Demands

Sampling across the corpus, the recurring computational shapes — and the files that drive each
conclusion — are:

**Framing / windowing / overlap is the universal front-end.** Every spectral feature is built on
the STFT framing ring with **window length N and hop H, H < N (overlap)**:
`research/transforms/short-time-fourier-transform.md` (§1.1 analysis equation `x(n+lH)·w(n)`;
§3 hop-size table where 50%/75% overlap means H = N/2, N/4; §4.1 the persistent ring + write
index; §13 state machine "Accum → NewFrame when accum ≥ HOP"). MFCC's step 2 explicitly says
"framing ring is shared with any STFT-based sibling algorithms"
(`research/features/mel-frequency-cepstral-coefficients.md` §2). **Implication:** framing is a
*shared, stateful, rate-changing* node that one signal feeds and many features consume — exactly
a fanout point — and it is overlapped, so it is not a clean N-in/N-out block.

**Long sequential chains with type changes at each stage.** MFCC is the archetype:
pre-emphasis → frame/window → real-FFT (→ `Complex`) → power spectrum (→ real) → mel filterbank
(→ `[40]f32`) → log → DCT-II (→ `[13]f32`) → delta/delta-delta (cross-frame)
(`research/features/.../mel-frequency-cepstral-coefficients.md` §2, pseudocode §10, mermaid §11).
**Every arrow changes the data type and several change the rate or dimension.**

**Massive fanout: one frame → many parallel reductions → one vector (fanin).** This is the
single most common shape and the corpus is emphatic about it:
`research/features/perceptual-sparse-and-ultra-low-compute-features.md` (§1: "compute while the
current frame is hot, write only the final scalar/small vector"; §3 lists centroid, rolloff,
flatness, flux, entropy, skew/kurtosis, HFC as parallel reductions over the *same* magnitude
spectrum; §9 mermaid shows `FrameOrBinsHot` fanning to ChromaFold, ShapeReductions, FluxUpdate,
TEOZCR, all converging to `SparseVector`). The end-to-end viz front-end
(`research/general/end-to-end-pipeline-budgets-and-worked-examples.md` §2) emits "a small 60 fps
control vector (a few dozen scalars)" assembled from mel + dominant + flux + loudness + envelopes.
**Critical nuance:** the corpus *prefers to FUSE the fanout into one pass* for memory-traffic
reasons ("the marginal cost of the whole perceptual-sparse family is a few dozen extra
adds...with only the compulsory loads of the bins" — perceptual-sparse §13). This is in direct
tension with a clean dataflow-graph fanout, where each extractor is a separate node re-reading the
buffer. See §4 (S5).

**Cross-frame state / history everywhere.** Deltas need 1–2 prior cepstral frames (MFCC §2 step 7,
~100–200 B). Spectral flux needs the previous magnitude spectrum or a leaky average
(perceptual-sparse §3, §7). Onset/beat needs a W-frame flux history + tempo hypotheses
(`research/detection/onset-beat-and-transient.md` §2: "W frames × B bands... 8–16 hypotheses").
Dominant-band needs a leaky max + hysteresis state
(`research/features/real-time-dominant-frequency-band-tracking-and-mapping.md` §3). Running
normalizers/AGC need envelope state (`research/algorithms/streaming-dynamics-...md`, referenced).
**Implication:** front-loaded `initialize` + per-block state (which the ideation already mandates,
§1) is the right model — *but* it interacts with sub-block rendering (§6.1) and the buffer pool in
ways the ideation hasn't checked (see S6).

**Multi-rate / hop-rate outputs are the norm, not the exception.** Features emit one frame per H
input samples (e.g. 1 per 512 at 16 kHz / ~31 Hz; control vectors at 50–100 Hz / 60 fps). STFT
§9, MFCC §6 (100 frames/s), dominant §1 ("control rate 50–100 Hz"), modulation-spectrum and
end-to-end budgets all assume **decimated output rates**. Resampling is explicitly rate-changing
(`research/resampling/polyphase-farrow-cic-lagrange-efficient-streaming.md` §2: "all arithmetic
happens at the low rate", commutator decimates by D). **Implication:** the port contract must
express "K outputs per M inputs", with K<M (hop decimation) or K>M (interpolation), distinct from
*latency*.

**Heterogeneous and structured (non-audio) data on edges.** Beyond scalars and fixed-K vectors:
complex spectra (`[]Complex(T)`, STFT §1.1/§7), and **structured records**: LPC produces a set of
PARCOR/reflection coefficients + residual energy + tracked formants with birth/death continuity
(`research/gaps-...md` §1, §"Formant tracking with continuity": "3–5 formant tracks with
birth/death" — ragged/variable cardinality); sparse peak lists for howl/onset
(`research/data_structures/audio-rings-...md`, referenced — "fixed-K sparse peak lists"); beat
trackers emit BPM + confidence + phase (onset §3). **Implication:** edges carry struct-of-features
and occasionally variable-cardinality data, not just `[]f32`.

**Per-channel processing.** The brief and ideation §6.5 make channels first-class ("pan").
The STFT note discusses planar multi-channel (§4.3, §6); the memory-hierarchy note (referenced)
treats planar vs interleaved. A multichannel analysis runs the *same* feature subgraph per
channel, then stacks/merges (e.g. per-channel loudness → downmix-aware integrated loudness;
per-channel MFCC for spatial classification). **Implication:** "map a subgraph over channels" is a
real, recurring need.

**Analysis sinks that never feed audio out.** The corpus is built around features as *taps* that
gate or drive control, visualization, or classification — not audio (perceptual-sparse §1 "gate
heavier processing"; onset §"Gate"; end-to-end §1/§2 emit feature vectors / KWS decisions /
60 fps viz drivers; the brief's whole `examples/` goal is "collecting output... for the
visualization"). The ideation acknowledges this once (§8 "Analysis (sidechain/metering)... taps")
but its scheduler is demand-driven from the audio output (§5.1).

---

## 3. Worked Examples

I walk three topologies through the architecture exactly as a library author would, naming the
blocks, ports, types, and rates, and flagging where it strains.

### 3.1 MFCC sequential chain (sequential + type changes + cross-frame + hop rate)

Target chain (from MFCC §2):
`PreEmph → Framer(N,H,window) → RFFT → Power → MelBank(40) → Log → DCT(13) → Delta`.

| Node | In port type | Out port type | Rate | State | Strain |
|---|---|---|---|---|---|
| PreEmph | `[]const f32` | `[]f32` | 1:1 | 1 sample | none — textbook ideation block |
| Framer | `[]const f32` | `[]const [N]f32` (windowed frame) **once per H** | **H:1 in, 1:H out, overlap N>H** | ring N+H, write idx | **S2** — overlapped, decimating, stateful. Not N-in/N-out. |
| RFFT | `[N]f32` frame | `[N/2+1]Complex(f32)` | 1:1 (frame rate) | twiddles (ROM) | **S1** — output is complex, not `[]T`. Declares `algorithmic_latency`. |
| Power | `[]const Complex(f32)` | `[N/2+1]f32` | 1:1 | none | **S1** — Complex→real type change |
| MelBank | `[N/2+1]f32` | `[40]f32` | 1:1 | sparse table (ROM) | **S1** — fixed-K vector out, dimension change |
| Log | `[40]f32` | `[40]f32` | 1:1 | none | clean (vector map) |
| DCT | `[40]f32` | `[13]f32` | 1:1 | matrix (ROM) | **S1** — dimension change |
| Delta | `[13]f32` | `[39]f32` (c, Δ, ΔΔ) | 1:1 | 1–2 prior frames | cross-frame state — fine if framed correctly (S6) |

**Where it holds:** Once you accept hop-rate frames as the unit, the *sequential* composition is
exactly ZigRadio composites flattening to leaves (ideation §1). The pull model renders the chain
in one callback with **zero inter-stage buffering** — strictly better than a ring-per-edge push
model that would add a hop of latency per stage. Front-loaded `initialize` holds the ROM tables
and the delta history cleanly. The `algorithmic_latency` declaration on RFFT/Framer is the right
hook for PDC (§6.6).

**Where it strains:**
- **S1 (types):** seven of eight edges are non-`[]f32`. The comptime port extraction
  (`ComptimeTypeSignature`) can in principle read `process(self, in: []const Complex(f32),
  out: []f32)` and wire it — Zig slices of `Complex(T)` / `[K]T` are ordinary types. But the
  ideation's coloring (§5.3, "M·N·sizeof(T)"), format negotiation (§6.5, over rate×precision×
  channels×blocksize), and in-place rules are all written for audio frames of `T`. A `[40]f32`
  mel vector is a *frame* in the coloring sense but its "block size" is 40, decoupled from the
  device N. **The spec must generalize "buffer" from `N·sizeof(T)` to `port_element_count ·
  sizeof(PortElem)`** and let the negotiated format carry the element type.
- **S2 (framing/rate):** `Framer` is the crux. It is decimating (1 frame per H samples) AND
  overlapped (each output frame re-reads N>H samples of history). The ideation's only tool here
  is "rate-elastic block declares `algorithmic_latency`" — but latency ≠ rate ratio. A Framer at
  H=160 emits 1/160th the frames; the pull scheduler must know to pull the *upstream* 160 samples
  to produce 1 frame, and downstream nodes run at frame rate. This needs an **explicit output:input
  rate ratio in the port contract**, not just a latency number. Folding it into the rate-elastic
  accumulator (as the ideation suggests for STFT) *works* but pushes the entire ring + overlap +
  hop state machine into every spectral block author, re-deriving STFT §4 by hand. **Framing
  should be a provided primitive** (`Framer(N, H, window)`), and the spectral block should consume
  framed input.

**Verdict on MFCC:** holds with two added mechanisms (typed ports, framing/rate primitive).
Without them, expressible but leaky and verbose.

### 3.2 Multi-feature fanout / fanin (the dominant shape)

Target (perceptual-sparse §9, end-to-end §2):
`Framer → RFFT → Power → {Centroid, Rolloff, Flatness, Flux, ZCR(time-domain!), RMS, MelBank→…→MFCC,
ChromaFold, Dominant} → VectorConcat → FeatureSink`.

**Fanout:** Power's `[N/2+1]f32` buffer feeds ~8 parallel readers. The ideation handles fanout in
§5.3(3): "fan-out extends a buffer's live range to its last reader and forbids in-place." Good —
the colored pool keeps the power buffer alive until the last extractor reads it, M (live buffers)
grows modestly. **This is exactly what the buffer pool is for, and it works.** Under heavy fanout
the pool simply pins the spectrum buffer for the span of the parallel branch; no per-reader copy
needed because the readers are non-mutating (S5 caveat: the corpus would rather *fuse* them).

**Fanin:** `VectorConcat` takes 8 heterogeneous inputs (`f32`, `f32`, …, `[13]f32`, `[12]f32`,
`u16` band index) and emits one `FeatureFrame`. **This is a new kind of block the ideation does
not have:** a multi-input, heterogeneous-arity, type-concatenating node. The ideation's port model
is `[8]` fixed ports of a single `T` each. Concatenating `[13]f32 ++ [12]f32 ++ f32 ++ …` into a
struct or a flat `[K]f32` is a comptime tuple/struct-build (very natural in Zig 0.16:
`@Struct`/tuple of the input element types, or a flat copy with comptime offsets), but it is **not
expressible as `process(self, in:[]const T, out:[]T)`** — it needs `in: anytype` / a tuple of
typed input ports. **This is S1 + a `Vectorize`/`Concat` library block with a comptime-built
output type.**

**Mixed-domain inputs:** note ZCR and TEO are **time-domain** (perceptual-sparse §4, §5: "run on
the raw input ring before any FFT") while centroid/flux are **frequency-domain**. So the fanout
is not from a single point — it is a *diamond*: the framed/time signal feeds ZCR directly AND
feeds RFFT, whose output feeds the spectral extractors; both reconverge at VectorConcat. The
**latencies differ** (RFFT path has FFT latency; ZCR path has none), so the fanin needs PDC
(§6.6) to align them. The ideation's PDC story covers this *if* feature frames carry latency, but
the dominant-band/ZCR scalars are at frame rate with their own latency — PDC must operate in the
**feature-frame rate domain**, which the ideation never considers (it discusses PDC for audio
dry/wet alignment).

**Where it holds:** fanout via the pool, diamond reconvergence, and composites all express this.
The pull scheduler renders the whole fanout in one pass.

**Where it strains:** (a) the fanin/concat block type (S1, needs heterogeneous typed inputs);
(b) PDC in the feature-frame domain (extension of §6.6); (c) **the fusion tension (S5):** the
corpus's central performance claim is that these extractors share *one* pass over the hot
spectrum with ~zero marginal traffic. A clean graph with 8 separate nodes each re-reads the
`[N/2+1]f32` power buffer 8 times. On embedded (the brief's target), that is 8× the L1 traffic the
corpus spent the whole note avoiding. The graph is *correct* but defeats the corpus's prime
directive. **Resolution options** (none in the ideation): a fused "multi-reduction" composite that
the author writes as one block (loses graph composability), or a scheduler/comptime
**loop-fusion** pass that fuses adjacent map/reduce nodes sharing an input buffer (a real core
feature, hard), or accept the re-read cost on desktop and fuse by hand on embedded. The ideation
must pick one and say so (Rule 7: surface, don't average).

### 3.3 Per-channel replication (channel-map)

Target: stereo input; run the §3.2 feature subgraph independently on L and R; then merge
(stack into a 2×K matrix, or compute a cross-channel feature like balance/width, or downmix to a
single integrated-loudness value per ITU BS.1770 referenced in gaps §4).

The ideation's channel model (§6.5) carries channel count *in the format*: a block is
`process(in: []const Frame(C_in), out: []Frame(C_out))`. That is elegant for **channel-agnostic
audio blocks** (a gain or biquad applies per channel trivially; a panner changes C). **But a
feature subgraph is not channel-agnostic in that way** — you want N *independent copies of the
whole subgraph*, each producing its own feature frame, then a merge. Two ways to express it:

1. **Manual split → per-channel subgraph → merge.** Insert a `ChannelSplit` (1 stereo port → 2
   mono ports), instantiate the §3.2 subgraph twice, then `ChannelMerge`/stack. For C=2 and a
   6-feature graph this is ~2× (8 nodes) + split + merge ≈ 18 nodes hand-wired. For 5.1 it is
   6× — clearly a boilerplate smell. The ideation supports it (composites + split/merge blocks
   exist in the taxonomy §8 "splitter/fan-out, matrix router") but offers **no `mapChannels`
   combinator**, so the user writes the replication by hand.

2. **A `ChannelMap(subgraph)` combinator (MISSING).** A construct that takes a mono subgraph and a
   channel count and produces the replicated graph + a stacked output port. In Zig 0.16 this is a
   comptime function returning a composite (`fn ChannelMap(comptime Sub: type, comptime C:
   usize) type`), instantiating `C` copies and wiring a stacking fanin. **This is the clean
   answer and it is absent from the ideation.** It is a *library combinator*, not a new transport
   primitive — but it must be designed alongside the channel model so the format negotiation and
   coloring understand replicated subgraphs (M scales by C; the pool must size for C copies).

**Where it strains:** without (2), per-channel feature graphs are verbose and error-prone; the
"channel rides in the format" model (great for effects) does **not** automatically give you
subgraph replication for analysis. This is the per-channel question the user asked, and the honest
answer is: **expressible, but currently manual and verbose — a `ChannelMap` combinator is the
elegant fix and it is missing.**

---

## 4. Where It Holds Elegantly vs. Where It Strains

### Holds elegantly

- **Sequential chains** flatten to leaf composites with zero inter-stage latency under pull
  (MFCC §3.1). Strictly better than ring-per-edge push.
- **Fanout via the colored pool** (§5.3(3)): multi-reader buffers with extended live ranges are
  exactly right; under heavy fanout the pool pins the source buffer for the branch span — no
  per-reader copy because feature readers are non-mutating. *(Holds, modulo the fusion tension S5.)*
- **Sub-block rendering (§6.1) is a genuine gift to features:** hop-aligned and event-aligned
  splitting is "just a shorter N", which makes Framer hop boundaries and automation-to-feature
  alignment clean — better than a push/ring model.
- **Front-loaded `initialize` + per-block state** is the correct model for all the cross-frame
  state (deltas, flux history, tempo hypotheses, leaky maxes, envelopes). The corpus's "O(1)
  state, no hot-path alloc" mandate matches the ideation's non-negotiable (§1).
- **Precision-comptime / N-runtime (§5.2)** fits: features are precision-sensitive (Q15 vs f32
  tables, MFCC §4) and the device dictates N; the asymmetry is real.
- **Latency declaration + PDC (§6.6)** is the right hook for FFT-block latency and diamond
  reconvergence — *provided it is generalized to the feature-frame rate domain.*

### Strains or is missing primitives

| # | Strain | Needs | Severity |
|---|---|---|---|
| **S1** | Port type is a single audio `T` slice; corpus needs `Complex(T)`, fixed-K vectors, scalars, structs, ragged descriptors, and a heterogeneous-input concat/vectorize block. | **(a) New CORE mechanism**: generalize the port-type model + buffer-pool/format-negotiation from "audio frame of `T`" to "typed port element of arbitrary comptime type", plus a `Vectorize`/`Concat` block with comptime-built output type. | High |
| **S2** | Hop-rate, overlapped framing is folded into the "rate-elastic + latency" escape hatch; latency ≠ rate ratio; every spectral author re-implements the STFT ring. | **(a) New CORE mechanism**: an explicit output:input rate ratio in the port contract, AND **(b) a provided `Framer(N,H,window)` primitive** (library composite over the ring). | High |
| **S3** | Pull scheduler is demand-driven from the audio output; pure-analysis graphs (file→features→collector, the brief's viz case) have no audio output to pull. | **(a) CORE clarification**: an **analysis-sink pull root** — feature sinks are pull roots in their own right (clock-driven or input-exhaustion-driven), not slaved to an audio device callback. | High |
| **S4** | No `ChannelMap` combinator; per-channel feature subgraphs are hand-replicated (2× for stereo, 6× for 5.1). | **(b) Library combinator** `ChannelMap(Sub, C)` returning a composite; coloring/negotiation must understand replication (M scales by C). | Medium |
| **S5** | Clean graph fanout makes N extractors re-read the hot spectrum N times, defeating the corpus's whole min-traffic premise (fused single-pass). | **(c) Genuinely awkward — ideation should decide:** either accept re-reads (desktop) + hand-fused composites (embedded), or add a comptime **map/reduce loop-fusion** pass (hard core feature). Must be surfaced, not averaged. | Medium–High |
| **S6** | Cross-frame feature state (deltas, flux, leaky max) interacts with sub-block rendering (§6.1) and the pool: if a block is rendered in two sub-blocks per hop, "one frame of history" must update once per *hop*, not once per *sub-block*. | **(b) Convention**: state-update granularity must be defined relative to the *frame/hop*, not the render call. Spec obligation + a test (Rule 9). | Medium |
| **S7** | PDC (§6.6) is specified for audio dry/wet alignment; the diamond fanin in §3.2 needs alignment in the *feature-frame* rate domain (time-domain ZCR vs FFT-latency spectral path). | **(b) Convention/extension**: PDC must operate per rate-domain. | Low–Medium |
| **S8** | Output collection: the brief wants per-hop feature vectors collected for visualization (matrix / time-series). The sink model (§8 "metering taps") is mentioned but a *feature-collecting sink* (append per-hop vector → growable matrix, off-RT) is unspecified. | **(b) Library**: a `FeatureCollectorSink` (ring or off-thread drain to a `[]FeatureFrame`), distinct from the RT silence-on-fault sinks. | Low–Medium |
| **S9** | Ragged/variable-cardinality outputs (formant birth/death tracks, sparse peak lists, beat hypotheses) don't fit fixed-K port buffers. | **(b) Convention**: carry as fixed-capacity + count (`struct { items: [Kmax]T, len: u8 }`) — standard in the corpus (data_structures "fixed-K sparse peak lists"). Spec should bless the pattern; not a new transport primitive. | Low |

---

## 5. Concrete Recommendations (prioritized)

**P0 — add before the spec freezes the port contract (these are CORE):**

1. **Generalize the port element type (S1).** Make the comptime "type signature is the API" carry
   *any* comptime port-element type, not just an audio `T`. The format-negotiation product
   (§6.5) becomes `(rate × precision × channels × block_size × port_element_type)`; the buffer
   pool sizes by `element_count · @sizeOf(PortElem)`. Bless a small set of canonical port elems in
   `specifications/catalog.md`: `Sample(T)`, `Complex(T)`, `FeatureFrame(K)` (= `[K]f32` or a named
   struct), `Scalar(T)`, and `Bounded(T, Kmax)` (= `{items:[Kmax]T, len}` for ragged). *(New core
   mechanism; comptime-cheap in Zig 0.16 — slices of these are ordinary types.)*

2. **First-class framing + output-rate ratio (S2).** Add to the port contract an explicit
   `out_per_in` rate ratio (rational), distinct from `algorithmic_latency`. Provide a `Framer(N, H,
   window)` library primitive (the STFT ring of `research/.../short-time-fourier-transform.md` §4)
   that consumes `Sample(T)` and emits `FeatureFrame(N)` at ratio `1:H` with `latency = N`. Spectral
   blocks consume framed input and never touch the ring. *(New core mechanism + library primitive.)*

3. **Analysis-sink pull roots (S3).** Define feature/analysis sinks as independent pull roots,
   driven by a clock or by input exhaustion (offline file→features→collector), not slaved to the
   audio device callback. A graph may have an audio-output pull root AND one or more analysis pull
   roots; the scheduler renders shared upstream once and fans the result to both. This directly
   serves the brief's visualization-data-collection goal. *(Core clarification to §5.1.)*

**P1 — design now to avoid boilerplate (library combinators / conventions):**

4. **`ChannelMap(Sub, C)` combinator (S4).** A comptime composite-builder that replicates a mono
   subgraph over C channels and stacks outputs into a `[C]FeatureFrame(K)` (or a 2-D matrix port).
   Make coloring/negotiation replication-aware (M and pool size scale by C). *(Library combinator;
   `fn ChannelMap(comptime Sub: type, comptime C: usize) type` returning a composite.)*

5. **`Vectorize`/`Concat` fanin block (S1/§3.2).** A heterogeneous-input block whose output type is
   a comptime tuple/struct (or flattened `[K]f32`) of its input element types. Pairs with (1).
   *(Library block; comptime output-type construction.)*

6. **`FeatureCollectorSink` (S8).** An analysis sink that drains per-hop `FeatureFrame`s off the RT
   thread into a growable time-series (matrix), for the `examples/` visualization pipeline.
   *(Library; off-RT drain via the §6.2 SPSC ring, not RT alloc.)*

**P2 — decide and document (do not leave averaged):**

7. **Fusion policy (S5).** Decide explicitly: (i) graph-of-nodes with accepted re-reads on desktop;
   (ii) hand-fused multi-reduction composites for embedded; or (iii) invest in a comptime
   map/reduce loop-fusion pass. State the choice and its rationale (Rule 7). My recommendation:
   ship (i)+(ii) now (a fused "perceptual-sparse" composite as one block is legitimate and matches
   the corpus's own framing), defer (iii) as a measured optimization. **This is the one place the
   architecture's clean dataflow ideal and the corpus's min-traffic ideal genuinely conflict.**

8. **State granularity convention (S6)** and **per-rate-domain PDC (S7)**: spec obligations +
   Yoneda tests (Rule 9/14): "delta history updates once per hop regardless of sub-block count";
   "a diamond fanin with unequal-latency branches aligns to the sample/frame".

**Mapping to the categorical spec (`specifications/`).** The ideation's §10 already frames blocks
as morphisms on typed sample-streams. The additions above extend the *object* category: objects
are now typed streams over `{Sample, Complex, FeatureFrame(K), Scalar, Bounded}` at a rate; a
`Framer` is a morphism that changes both the object type and the rate (a decimating, history-using
morphism); `ChannelMap` is a functor `C^(·)` (the C-fold product) on subgraphs; the fanin/concat is
a product/tupling morphism; analysis pull roots are additional terminal objects. This makes the
"two functorial interpretations" framing (§10) honest for features, not just audio.

---

## 6. Open Questions for the Spec Phase + What I Could Not Verify

**Open questions the spec must resolve:**

1. **Is the internal canonical type `f32` with typed feature ports layered on top, or are feature
   ports genuinely first-class in negotiation?** P0(1) assumes the latter; the ideation's open
   question §11.3 (precision policy) only considered audio precision, not feature element types.
2. **Does the colored buffer pool (§5.3) generalize to mixed-element-size buffers cleanly?** A graph
   with `Sample(f32)` frames of N=512 *and* `FeatureFrame(40)` *and* scalar ports has wildly
   different buffer sizes; linear-scan coloring across heterogeneous sizes is a bin-packing variant,
   not the uniform-register model the ideation assumes. Needs validation.
3. **How is the feature/control rate clocked relative to the audio block?** Hop H may not divide the
   device N (STFT §9 warns "block size must divide H for clean alignment"). The interaction of
   device-N-runtime (§5.2) with feature hop alignment is unspecified.
4. **Fusion (S5)** — the decision above must be made before the embedded budget claims in the brief
   can be honored.
5. **Ragged ports under static coloring (S9):** fixed-capacity `Bounded(T,Kmax)` solves storage, but
   does the *liveness* analysis handle a port whose useful `len` varies per frame? (Storage is
   static; correctness is fine; confirm.)

**What I could not verify from the available material:**

- **The actual ZigRadio source** is not in this repo path I read (the ideation §11 open-question 1
  flags this too: "only the reverse-engineered notes are" present). I could not confirm whether the
  wrapper-fn generation (`wrapProcessFunction`) actually supports non-`[]T` port element types or a
  variable number of typed input ports — both are *assumed available* by P0(1) and P1(5). This is
  the single biggest verification gap: **S1/S5's feasibility hinges on the real comptime port
  extraction, which I have only seen described.** *(I did not read `zig_engineering/` source; I read
  the ideation's claims about it.)*
- **No code exists yet** (pre-spec), so all "expressible / verbose" judgments are about the
  *proposed* model, not a running implementation. The B/B+ grade is a design-fit judgment.
- I **sampled** rather than exhaustively read the corpus (per instructions): I read STFT, MFCC,
  perceptual-sparse, onset/beat, dominant-band, resampling, the gaps doc, and end-to-end budgets in
  full or near-full, and surveyed the INDEX/README for the rest (LPC, GFCC, contrast, loudness,
  modulation, PNCC, VAD, pitch, the algorithms/ compositions). The structural conclusions (framing,
  fanout/fanin, cross-frame state, hop-rate, per-channel, heterogeneous types) are robustly
  attested across the files I read; a specific quantitative claim in an un-read file could refine
  but is unlikely to overturn them.

---

*End of audit. Companion to `notes/architecture_ideation.md`; feeds the `specifications/` phase.*
