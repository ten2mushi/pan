# pan — Specification ⇄ Algorithm Coverage Assessment

> **Status: assessment note (NON-LOCKED).** 2026-06-03. Defers to the locked
> `specifications/` corpus and `catalog.md` (the single source of truth); never
> overrides them. Author: Claude (Opus 4.8) via Claude Code, with the `zig-0-16`
> skill loaded for all Zig-form claims.
>
> **★ UPDATE 2026-06-03 — all five §4 gaps RESOLVED and folded into the locked corpus.**
> Per locked decisions (AskUserQuestion 2026-06-03): **§4.A/§4.D-param → parameter
> ports** (new catalog §2.4); **§4.C → permanent data-gating only** (catalog §8.9);
> **§4.B → `out_per_in` single-rate / filterbanks decompose** (catalog §2.2 R5);
> **§4.D-sample → multi-input pull rule** (catalog §8.8); **§4.E → element-generic
> `UnitDelay` / FDN** (catalog §5.5). Applied **in place** across the corpus (catalog
> §15 change log + every citing sibling re-dated). §4 below is retained as the
> rationale of record; each item now carries its **RESOLVED** disposition inline.
>
> **Question answered (from the task brief):** *Does the locked specification set
> allow and specify for the different audio-processing algorithms researched in
> `research/`? Prove the answer — e.g. by checking whether the spec'd architecture,
> once implemented, can produce the desired output of [`1.md`](1.md). If features
> are missing, list them thoroughly.*
>
> **Inputs read:** all 11 `specifications/` docs (catalog + hub + 9 siblings,
> corpus LOCKED 2026-06-02); the 8 skeleton `src/*.zig` files + `build.zig`;
> the `research/` corpus (43 notes, surveyed for structural/dataflow stressors);
> [`brief.md`](brief.md) and [`1.md`](1.md).

---

## 0. Verdict (one paragraph)

**The specification set is sufficient.** The locked architecture can express and
host essentially the entire researched algorithm corpus, and it can produce the
[`1.md`](1.md) 60 fps audio-reactive visualization output in full (§2 proves this
stage-by-stage). Every structural stressor the corpus exhibits — rate-elasticity,
feedback, spectral bins, fixed-K feature vectors, ragged/sparse peak lists,
cross-frame history, fan-out/fan-in, multi-input, control-rate analysis, multiple
clock domains — maps onto a construct the spec already commits to (§3). The
**material gap is implementation, not specification**: the DSP library blocks are
stubs/absent and two commit-pass stages (interval-coloring, PDC) are unimplemented
(§5). At the *spec* level only **five genuine under-specifications** remain (§4);
all five are either decomposable into already-specified primitives, deferrable as
performance-only, or documentation gaps — **none blocks the corpus or `1.md`.** The
single one worth a dedicated spec addition is **intra-graph control-rate parameter
edges** (§4.A): the spec resolves coefficient-modulation only by "fuse it into one
opaque block," which is coherent for the corpus's adaptive effects but leaves
*decoupled* modulation unanswered.

---

## 1. Method

1. Read the full locked corpus; extracted what each construct guarantees and at
   which correctness tier (⊢ proven / ≈ tested / ▷ conventional, per `catalog.md` §0.2).
2. Inventoried `research/` for *structural* demands (not DSP detail): every
   algorithm tagged with the architectural stressor(s) it imposes (RATE, FEEDBACK,
   CONTROL-RATE, CROSS-FRAME-STATE, SPECTRAL, FAN-OUT/IN, RAGGED, FEATURE-VECTOR,
   MULTI-INPUT, ADAPTIVE, etc.).
3. For each stressor, located the hosting spec construct, or recorded its absence.
4. **Proof obligation:** walked the `1.md` pipeline end-to-end against the spec,
   stage-by-stage and attribute-by-attribute, to demonstrate constructibility
   (§2) rather than assert it.
5. Separated **spec gaps** (§4) from **implementation gaps** (§5) — per Rule 12,
   "compiles" is not "complete", and conflating the two would hide the real status.

---

## 2. Proof by construction — `1.md` is fully expressible

`1.md` describes a custom generative pipeline: STFT spectral analysis → per-frame
{amplitude∈[0,1], dominant frequency band 2 kHz–8 kHz → colour, temporal features}
→ a streaming particle/point-cloud with per-point {colour/frequency, amplitude,
lifetime, emission time} at 60 fps. Mapping each stage to a spec construct:

| `1.md` stage | Spec construct that hosts it | Where |
|---|---|---|
| Audio capture / DMA ring | `PullRoot` driven by `AudioDeviceCallback` (RT) or `InputExhaustion` (file) | exec §6; cat §8.3 |
| (opt.) resample to analysis rate | `Rate` block (polyphase resampler), auto-inserted by format negotiation on a rate-mismatched edge | exec §2; type §2; io §2 |
| Framer / window / hop | `Framer(N, H, window)` — a **core** `Rate` primitive (the shared STFT ring; T4 absorbs `H ∤ N`) | bridge §2; cat §9.3 |
| FFT → spectrum | STFT `Rate` block emitting `Complex(T)` port elements; pool key `(Complex(T), N/2+1)` | cat §1.3, §2.2; type §1 |
| Amplitude → [0,1] | power/RMS `Map` (`Complex→Scalar`) → envelope follower (`Map` w/ per-sample `z⁻¹`) → AGC/[0,1] scaler (dynamics library block); out `Scalar(f32)` | cat §1.3, §2.1; bridge §2 |
| Dominant band 2 k–8 kHz → colour | argmax `Map` (`Complex→Scalar(u16)`) + bin→Hz→colour `Map` + leaky/hysteresis tracker as block-internal persistent state | cat §1.3 (`Scalar`=dominant band), §5.3 ("leaky maxes"); research `features/real-time-dominant-frequency-band-tracking…` (explicit "2 kHz–8 kHz colour stops") |
| Temporal features (flux/onset) | flux `Map` (`Complex→Scalar`) with **previous-spectrum** persistent state | cat §5.3 (names "flux previous-spectrum" as persistent/pool-excluded) |
| Feature-vector assembly | `Concat(.{ .amplitude=Scalar(f32), .dominant=Scalar(u16), .flux=Scalar(f32) })` (named-product fan-in; field order = column order) | type §1; cat §4.3 (worked example is nearly verbatim) |
| 60 fps control-rate emission | analysis `PullRoot` driven by `WallClockTimer(60 Hz)` on a **non-RT** thread, fed from the audio graph via an SPSC tap; never slaved to the audio deadline | exec §6; cat §8.3 |
| Particle emission / lifetime collection | `FeatureCollectorSink` (non-RT root, geometric `realloc` past `capacity_hint` — the *blessed* contained H1 exception) drains per-frame rows; the particle system itself is the `examples/` app layer | bridge §2; exec §6 |

**"Data for every point" (the `1.md` per-point schema):**

| Attribute | Source construct |
|---|---|
| COLOUR / FREQUENCY (most active band at emission) | dominant-band tracker → colour map (`Scalar(u16)→Scalar(colour)`) |
| SIGNAL AMPLITUDE [0,1] | envelope + AGC/[0,1] scaler (`Scalar(f32)`) |
| LIFETIME (animated from emission) | `examples/` app layer over the emitted feature stream (particle pool) |
| EMISSION TIME | transport / event-lane timestamp against the play position | transport: io §9; events: io §6 |

**Conclusion:** Every stage and every per-point attribute of `1.md` lands on a
construct the spec already commits to. The constructs the pipeline *requires* —
`Rate` (Framer/STFT), `Complex`/`Scalar`/`FeatureFrame` elements, fan-out from one
spectrum, `Concat` fan-in, persistent state for flux/hysteresis, a second non-RT
60 Hz clock-driven pull root, and `FeatureCollectorSink` — are all specified. The
spec even names `1.md` as the motivating target for `FeatureCollectorSink` and the
analysis pull root (exec §6; bridge §2). Once the (currently stubbed) library
blocks exist, `1.md` is producible. **The barrier to `1.md` is implementation, not
specification.**

---

## 3. Coverage matrix — every researched stressor has a host

| Stressor (from `research/`) | Representative algorithms | Hosting spec construct | Tier |
|---|---|---|---|
| RATE (frame/hop/decimate/resample) | STFT, Framer, decimator, polyphase/Farrow/CIC, WSOLA, phase vocoder, MDCT | **`Rate`** contract (`out_per_in`, `algorithmic_latency`, `needed_input`, `pull`); `Framer` core primitive | C1; cat §2.2 |
| FEEDBACK (IIR/comb/recursive) | biquad, lattice, SVF, WDF, combs, Goertzel/SDFT | **graph-level**: trace + SCC-has-delay law (`error.DelayFreeLoop`) over `UnitDelay`/`DelayLine`; **per-sample**: fused tight-feedback `Map` kernel | cat §5; ⊢ on SCC-has-delay |
| CROSS-FRAME STATE / HISTORY | flux (prev spectrum), MFCC deltas, tempo hypotheses, noise tracking, adaptive thresholds, running norm | **persistent / pool-excluded state category** (allocated once at `initialize`); explicitly enumerates these examples | cat §5.3 |
| SPECTRAL (complex bins) | DFT/STFT/CQT/SDFT, MFCC, HPSS, spectral subtraction | `Complex(T)` port element + pool class | cat §1.3 |
| FEATURE-VECTOR (fixed-K) | mel, MFCC, chroma, GFCC, contrast, PNCC | `FeatureFrame(K)` element; comptime-N regime kills scalar tail | cat §1.3; type §3.1 |
| RAGGED / SPARSE (variable cardinality) | pitch peaks, onset events, formant tracks, beat/tempo hypotheses, sparse bins | **`Bounded(T, Kmax)`** (static storage, variable `len`); consumer-respects-`len` | cat §1.3 (closes audit S9) |
| FAN-OUT / FAN-IN | one spectrum → N reductions; `Concat` feature record; crossovers | fan-out pins buffer to last reader; `Concat` named-product; mixers fan-in | mem §7.3; cat §4.3 |
| MULTI-INPUT (sidechain/AEC/crossover-sum) | AEC (mic+ref), de-esser/ducking, FDN matrix | heterogeneous typed input ports (≤8/direction, `u3` ceiling); the "open feasibility question, answered yes" | hub §2; type §1 |
| CONTROL-RATE / MULTI-RATE analysis | dominant-band, VAD, onset, dynamics, loudness, 60 fps viz | second `Rate` stage + independent non-RT clock-driven `PullRoot` | C5; exec §6 |
| ADAPTIVE / ASRC | drift resampler, AGC | adaptive `Rate` + PI controller at device boundary; AGC as a library block | io §1; bridge §2 |
| FUSED single-pass kernels (min-traffic) | STFT+features fused | clean dataflow = semantic model; **fusion = commit-time optimization**; hand-fused composites shipped for embedded | T2; mem §5 |
| PDC / latency alignment (dry/wet diamonds) | parallel FFT-vs-time paths | longest-path DP per rate-domain, compensating `DelayLine` insertion | cat §7.7 |

The corpus is dominated by FEEDBACK and CROSS-FRAME-STATE; both fit the
delay+persistent-state model precisely (the spec's §5.3 list of persistent-state
examples reads like a checklist of the research notes). **No researched algorithm
is flatly inexpressible.** The remaining friction is in §4.

---

## 4. Genuine specification-level gaps (thorough list)

> **All five RESOLVED 2026-06-03** and folded into the locked corpus (catalog §15). The dispositions:
> §4.A → **parameter ports** (catalog §2.4); §4.B → **R5 single-rate `out_per_in`** + decomposition
> (catalog §2.2); §4.C → **permanent data-gating only** (catalog §8.9); §4.D → **parameter ports
> (param-side) + multi-input pull rule** (catalog §2.4, §8.8); §4.E → **element-generic `UnitDelay` /
> FDN** (catalog §5.5). The text below is the rationale of record.

Each gap: *what it is · which algorithms hit it · the in-spec workaround · severity
· proposed resolution and where it attaches.* Ranked by how much it actually bites.

### 4.A — Intra-graph control-rate **parameter / modulation edges** (the one worth adding)

**What.** The spec's control plane is exactly three verbs — `set` / `schedule` /
`edit` (cat §10; io §7) — and all three are **external-thread** mechanisms
(UI/automation → audio thread). There is **no first-class way to wire one DSP
node's output to *modulate another node's coefficient/parameter*** as a graph edge.
A node's data inputs are sample/feature *streams* consumed by `process`/`pull`, not
control parameters.

**Who hits it.** Every *decoupled* modulation pattern: an LFO node modulating a
separate filter's cutoff; a dominant-band/pitch node retuning a separate notch;
adaptive feedback/howl suppression where the peak tracker and the notch filter are
distinct nodes; online feature-normalization driving a downstream scaler; any
"modulation matrix." Also the *adaptive* family (AEC NLMS/FDAF, AGC, spectral-
subtraction noise tracking) *if authored as separate analysis + apply nodes*.

**In-spec workaround.** Fuse the modulator and the modulated stage into **one
block** (or one composite). The block taxonomy already does exactly this:
compressor/AGC/de-esser/ducking, AEC, FDN reverb, chorus/flanger, howl suppression
are all listed as single library blocks/composites (bridge §2). Coefficient updates
happen *inside*; an external key signal (sidechain) arrives as an ordinary
multi-input port. This is coherent and sufficient for the **research corpus**,
which contains no decoupled modulation matrix.

**Why it's still a gap.** (i) It contradicts the clean-dataflow ethos (T2) for the
decoupled case — the modulator becomes invisible to the scheduler/colorer. (ii)
"A control-rate signal as a graph citizen that targets a parameter" is simply
unanswered: is a coefficient a `Scalar`/`FeatureFrame` edge into a special control
port, applied per-block with the same ramp policy as `set`? The spec doesn't say.
(iii) It is adjacent to §4.D (cross-rate multi-input).

**Severity: medium** (low for the current corpus; medium for the library's stated
ambition — synths, modulation, DAW-style effects).

**Proposed resolution (Rule 7 — pick a side).** Add a **control-port / parameter-
edge** concept to `catalog.md` as a *layered* construct (it touches none of H1–H3
on the RT path if it reuses the per-block ramp): a node may declare typed
**parameter ports** (distinct from sample ports) accepting `Scalar(T)`/`FeatureFrame(K)`
at *control rate* (one value per block, ramped exactly as `set`). Wiring a feature
node into a parameter port is the in-graph analogue of `set`; it is colored on the
control-rate pool, scheduled before the consuming block, and is **forbidden from
feedback-without-delay** like any edge. Attaches at cat §10 (control plane) + a new
row in the §2 morphism discussion (a `Map` may take parameter ports that do *not*
participate in the M1 `out.len == in.len` law). Until then, **document the
"fuse into one block" pattern as the official answer** so authors don't reach for a
parameter edge that doesn't exist (Rule 12 — surface it, don't let it be discovered
at the keyboard).

### 4.B — `Rate` with **multiple output ports at heterogeneous rates**

**What.** The `Rate` contract is single-valued: one `out_per_in: Ratio`, one
`pull(self, want, out)`. A block whose *several outputs run at different rates*
(a wavelet/octave decomposition emitting subband 0 @ Fs/2, subband 1 @ Fs/4, …; a
multi-rate CQT) is not expressible as one `Rate` block.

**Who hits it.** DWT (Mallat/lifting) octave trees, CQT/NSGT with per-band hops,
gammatone banks with per-band decimation.

**In-spec workaround.** **Decompose** into a cascade/bank of *uniform-rate* `Rate`
nodes: a 2-band analysis stage is `1→2` with **both** outputs decimated-by-2 (same
rate within the stage); the octave heterogeneity emerges from the *cascade*, not
from any single block. CQT bands become a bank of independent single-rate blocks.
This works and is the natural multi-rate-filterbank construction.

**Severity: low** (fully decomposable).

**Proposed resolution.** Document the decomposition pattern in the bridge's block
taxonomy (a "multi-rate filterbank = cascade of uniform `Rate` stages" note), and
explicitly state in cat §2.2 that `out_per_in` is **per-block, single-rate**, and a
block needing per-output rates must be split. No core change.

### 4.C — **Conditional / gated execution** (dynamic scheduling for power)

**What.** The render op-list is **static** (C2): the callback replays every op with
zero graph walking. There is no "skip these ops when VAD says silence" — no
conditional execution edge.

**Who hits it.** VAD/onset gating "to save downstream MFCC/pitch traffic"; any
power-gating the research notes describe.

**In-spec workaround.** Gate as **data**, not as scheduling: VAD produces a
`Scalar` gate that multiplies/freezes downstream output (compute-and-discard). The
*power* saving (not running the ops at all) is the only thing lost. On a non-RT
analysis root the wasted compute is acceptable; on the RT root the static path is a
feature (deterministic WCET — wait-freedom H1).

**Severity: low** (performance-only; never a correctness gap).

**Proposed resolution.** Note it as **deferred** alongside Tier B/C and auto-fusion:
a future "conditional sub-plan / gated op-group" optimization, gated behind the
same xrun/headroom cost model. State explicitly in exec §5 that gating is a
deferred optimization and the conformant pattern today is data-gating.

### 4.D — **Cross-rate multi-input** scheduling

**What.** The pull scheduler asks each input edge `producer.needed_input(want)`
(exec §2.3); the `Rate` contract is framed around *single-input* rate conversion. A
block consuming **two inputs at different rates** (audio-rate signal + control-rate
coefficient; or two streams to be rate-reconciled) is not fully specified — which
input's rate sets `want`? Same-rate multi-input (AEC mic+ref, sidechain, crossover
sum) is fine and PDC aligns their *latency*; the unspecified case is *heterogeneous
rates per input port*.

**Who hits it.** Tightly coupled to §4.A (a control-rate parameter feeding an
audio-rate block). Also any block mixing an audio stream with a slower analysis
stream.

**In-spec workaround.** Insert a rate adapter (resampler/sample-and-hold `Rate`
block) on the slower edge so all inputs share a rate before the consumer; or fuse.

**Severity: low–medium** (decomposable, but the scheduler's multi-input recursion
should be pinned).

**Proposed resolution.** Extend exec §2.3 / the commit-pass algorithms doc to state
the multi-input pull rule: each input edge is independently satisfied via its
producer's `needed_input`, and **mixed-rate inputs require an explicit adapter**
(no implicit reconciliation). Pin this when §4.A is specified — they share the
"control-rate edge into an audio-rate block" mechanism.

### 4.E — Worked **feedback beyond scalar `z⁻¹`** (FDN matrix; frame-granular delay)

**What.** The feedback law (cat §5) is stated for the general trace, but the only
worked idioms are scalar graph-level `DelayLine`-in-a-cycle and fused per-sample
kernels. Two corpus cases lack an explicit worked example: (i) **FDN reverb** —
an N×N feedback *matrix* in the loop (vector feedback, mixing transform inside the
trace), and (ii) **frame-granular feedback** — a `z⁻¹` on a `Complex`/`Frame` edge
(spectral/phase feedback).

**Who hits it.** FDN/Schroeder reverb; phase vocoder; any spectral feedback.

**In-spec workaround.** Both compose from stated primitives: FDN = N `DelayLine`
nodes + a matrix-mix `Map` over a `Frame(Lane,N)` element + feedback edges (SCC
contains the delays → legal); frame-granular feedback = an **element-generic**
`UnitDelay(Complex)`/`UnitDelay(Frame)` on the back-edge.

**Severity: very low** (documentation only).

**Proposed resolution.** Add two worked examples to the memory/feedback discussion:
an FDN (confirming a multichannel-delay + matrix SCC passes the `error.DelayFreeLoop`
check) and a spectral-feedback edge (confirming `UnitDelay` is element-generic over
`Complex`/`Frame`). No core change.

---

## 5. Implementation gaps (distinct from §4 — the real blocker for `1.md`)

Per Rule 12, "the skeleton compiles and tests pass" must not be read as "the
algorithms are hostable today." They are *spec-able* but not yet *built*. From the
skeleton map (`src/*.zig`, all `zig build` / `zig build test` green on 0.16.0):

- **Present & real:** the six port elements (`types.zig`), the `Numeric` trait
  (`numeric.zig`, but `Precision` enum carries only `.f32`/`.q15`), the Map/Rate
  comptime classifier + typed `PortId` + 8-port `u3` ceiling (`port.zig`), the
  10-method `SampleMux` vtable with `TestSampleMux`/`PullSampleMux` (`mux.zig`),
  graph add/connect with `@compileError` type-checking (`graph.zig`), and the
  comptime-commit smoke gate with a comptime-constant `footprint_bytes` (`pan.zig`,
  `commit.zig`).
- **Stubbed / missing — these block `1.md` and the corpus:**
  1. **Commit pass is partial** (`commit.zig`): SCC-has-delay (`error.DelayFreeLoop`)
     and buffer-id-as-MODE-B are real, but **topological ordering output, liveness,
     per-element-class interval coloring (left-edge), and PDC longest-path DP are
     absent** (MODE B is the placeholder; `element_count` hard-coded to 1). The
     coloring/PDC commitments C3/§7.7 are unrealized.
  2. **Zero real DSP blocks.** `Gain`/`I2sSource`/`I2sSink` are identity `@memcpy`
     stubs; `Gain.gain` is never applied. No `Framer`, STFT/FFT, RMS/envelope,
     dominant-band, flux, `Concat`, or `FeatureCollectorSink` exist — i.e. **none
     of the `1.md` chain (§2) is built.**
  3. **`renderInto` runs nothing** (`engine.zig`): every op `fn_ptr` is null and is
     skipped; the realtime token's FTZ/DAZ setting is a TODO (no-op).
  4. **Gold vectors unused:** `tests/vectors/gain_f32/*` exists but no code reads it;
     the gold-vector oracle harness, dual-mux, B≡C, and latency-contract tests
     (the ≈ tier of `catalog.md` §12.2) are not yet implemented.
  5. No second (non-RT) `PullRoot` / clock-source implementation; no SPSC tap.

These are exactly the items on the de-risking prototype plan (bridge §5, steps
1–6b) — i.e. the spec *anticipates* them as the build order. They are not spec
defects; they are unwritten code.

---

## 6. Recommendations

1. **Treat §4.A as the one spec addition worth making now** (control-rate parameter
   edges) — it is the only recurring pattern the spec answers only by "fuse it,"
   and pinning it (even as "fuse it is the official answer, here's why") closes a
   real authoring ambiguity. Surface it loudly (Rule 12) rather than letting an
   author discover the missing parameter edge.
2. **Fold §4.B/§4.D/§4.E into the next documentation pass** (decomposition patterns
   + multi-input pull rule + two feedback worked examples). No core changes; these
   are clarifications the locked corpus can absorb via `catalog.md` change-control.
3. **§4.C: record gating as a deferred optimization** next to Tier B/C and
   auto-fusion, with data-gating as the conformant pattern today.
4. **The critical path to `1.md` is §5, not §4.** Build, in the spec's own
   de-risking order: the coloring/PDC commit stages (C3, §7.7), then the `Framer`
   + STFT `Rate` blocks, the perceptual `Map` reductions (RMS/envelope/dominant-
   band/flux), `Concat`, the non-RT 60 Hz `PullRoot`, and `FeatureCollectorSink` —
   each behind a gold-vector + dual-mux gate, with a Yoneda test-writer dispatched
   per Rule 14 (instructed to load the `zig-0-16` skill per Rule 13).

---

## 7. One-line answer

**Yes — the locked spec set allows and specifies for the researched algorithms and
can produce the `1.md` output; the only spec-level item worth adding is intra-graph
control-rate parameter edges (§4.A), and the actual work remaining is implementation
(§5: coloring/PDC + the DSP library blocks), not specification.**

*Assessment note 2026-06-03.*
