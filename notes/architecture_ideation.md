# Architecture Ideation — A Real-Time Audio Processing Library on a ZigRadio-Inspired Foundation

> **Status:** ideation / pre-specification. Not a spec, not a commitment. Input for the
> category-theory specification documents (`specifications/`) that will become the single
> source of truth.
> **Inputs digested:** `notes/brief.md`; the full `zig_engineering/` corpus (ZigRadio
> reverse-engineered design, incl. the engineering audit `18` and limitations `14`);
> the `zig-0-16` skill; a structured trade-off analysis from a systems-design pass.
> **Language bias:** Zig 0.16.0 (the corpus, the skill, and CLAUDE.md Rule 13 all point here),
> though C/Rust remain nominally open per the brief.

---

## 0. Thesis in one paragraph

ZigRadio is an **A−-grade streaming DSP framework for soft-real-time SDR**, and its
*authoring* model is close to perfect: a block is a plain Zig struct with a
`process(self, in: []const T, out: []T)` method, from which the framework extracts the
entire port contract at comptime and generates zero-overhead, type-erased dispatch. Its
*execution* model — one OS thread per block, condvar wakeups, one fixed **8 MiB ring per
edge** — is exactly wrong for audio: it is structurally **latency-unbounded** and would put
seconds of buffering and unbounded scheduler jitter between a guitar and its amp. The
opportunity is to **keep ZigRadio's authoring surface and testing methodology verbatim,
and replace its transport and execution layer** with a latency-domain design: a synchronous
*pull* scheduler that renders the whole graph inside the audio device callback on
device-sized buffers, a colored buffer pool instead of per-edge rings, a lock-free control
plane, and first-class support for the things audio needs that SDR didn't (multichannel/
spatialization — the literal "pan", sample-accurate events, feedback loops, latency
compensation). The crucial enabler already exists in ZigRadio: the **`SampleMux` vtable**,
which lets the *same block code* run against a test fixture or real rings, is precisely the
seam at which we slot in a third "mux" with pull semantics. We spend that abstraction one
more time and most of the library comes along for free.

---

## 1. What we inherit unchanged (the elegant core)

These are load-bearing and excellent. Keep them; do not re-litigate.

| Inherited idea | Where it lives in ZigRadio | Why it survives the move to audio |
|---|---|---|
| **Type signature *is* the API** — `[]const T` ⇒ input, `[]T` ⇒ output, extracted from `process` at comptime | `block.zig` `Block.init`, `types.zig` `ComptimeTypeSignature` | Zero-boilerplate, zero-overhead, fully type-safe wiring. Nothing about it is SDR-specific. |
| **Zero-overhead dispatch** via `@fieldParentPtr` + `@call` | `wrapProcessFunction` | One indirect call per *buffer* (not per sample) is free; the compiler can often devirtualize. |
| **The `SampleMux` vtable** decoupling blocks from transport (TestSampleMux vs. real rings) | `sample_mux.zig` | **The single most important inheritance.** It is the seam where a *pull* scheduler plugs in (§5.1). |
| **Front-loaded allocation; zero malloc in `process`** | `initialize(allocator)` everywhere; `ProcessResult` is stack-only `[8]usize` | Non-negotiable for real-time audio. Already correct. |
| **Gold-vector testing against a NumPy/SciPy oracle** | `generate.py` + `vectors/` + `BlockTester` | Tests against an independent mathematical truth, not the implementation's assumptions. Directly serves CLAUDE.md Rule 9 + the Yoneda-test discipline (Rule 14). |
| **Composites that flatten to leaves at build time** | `composite.zig`, `_connect` alias crawl | Effect racks, busses, multiband splits = composites. Zero runtime cost after flattening. |
| **EOS / stream termination as a first-class dataflow signal** | `setEOS`, `EndOfStream`/`BrokenStream` | Clean shutdown of offline renders and stream ends; reused as-is on the offline path. |
| **Double-mapped contiguous ring trick** | `MappedMemoryImpl` (memfd + double mmap) | Retained — but demoted to *one buffer strategy among several*, and used mainly on the **offline/throughput** path (§5.3). Needs a macOS `vm_remap`/Mach path the audit flags as missing. |
| **Optional, runtime-discovered acceleration with pure fallback** | `platform.zig` DynLib + `catch null` | The right posture for a HAL — but for audio the primary accelerator is **portable `@Vector` SIMD compiled in**, with Accelerate/vDSP optional for FFT (§7). |

**Categorical framing (for the `specifications/` work).** A block is a *morphism* on typed
sample-streams. `SampleMux` is a **representable probe**: a block is fully determined by how
it transforms the buffers a mux hands it — the Yoneda intuition that "an object is determined
by its maps into it" is exactly why TestSampleMux can *define* a block's behavior and the real
mux can *execute* it. The push scheduler and the pull scheduler are then **two interpretations
(natural transformations) of the same block functor into two execution categories** — this is
the formal statement of "one authoring surface, two execution contracts" (§5).

---

## 2. Why SDR ≠ Audio: the requirement delta

The brief's priorities are *minimize latency, maximize throughput, minimize memory, minimize
disk*, with a HAL across Apple Silicon / Linux / embedded and config-driven precision, sample
rate, and block size. The decisive difference from SDR is the **hard-real-time callback
contract**:

> The audio device hands you an output buffer of exactly **N frames** and a deadline of
> **N / Fs** seconds. You **must** return with it filled. There is no "later." A missed
> deadline = **xrun** = an audible click.

Consequences that are *theorems, not preferences*:

1. **No unbounded blocking on the audio thread** — no mutex contended with a non-RT thread,
   no condvar, no malloc, no syscall, no page fault. ZigRadio's *entire* wakeup model
   (condvars in rings, writer parks when full) is categorically disallowed here.
2. **Latency floor = one device block; every buffering stage adds to it.** A ring between
   every block costs ≥ one block-period *per hop*. A 10-block chain at 128 frames already
   structurally buffers ~26.7 ms before jitter. The pull model collapses inter-block latency
   to **zero** — the whole chain runs in one callback on one buffer generation.
3. **"What's available" is meaningless on the RT path.** ZigRadio's `process` is *push*
   ("here's what happened to be available; report what you consumed/produced") because a ring
   sits upstream. With no ring, the contract is *pull*: "render **exactly these N frames** into
   **this exact buffer**, now." This is the GNU-Radio-vs-JUCE split, and it falls out of the
   latency constraint rather than taste.

Latency budget illustration (mono f32 @ 48 kHz):

| Buffering construct | Time held | Verdict for interactive audio |
|---|---|---|
| ZigRadio 8 MiB ring | ~45 s | Absurd. |
| One 128-frame block | 2.67 ms | The target granularity. |
| 10-block chain, ring-per-hop | ~27 ms + jitter | Fails sub-10 ms; jitter risks xruns. |
| 10-block chain, pull in one callback | 2.67 ms (one block) | Meets sub-5 ms with margin. |

---

## 3. The audit's ceilings, triaged for audio

Reframing `zig_engineering/18` + `14` against the audio target. **Fatal** must change before
anything works; **fine** can stay (mostly on the offline path).

| Audit ceiling | For SDR | For audio | Disposition |
|---|---|---|---|
| Thread-per-block + condvar wakeups | Acceptable | **Fatal** (unbounded jitter on RT thread) | Replace with synchronous pull scheduler on RT path (§5.1). |
| Fixed 8 MiB ring per edge | Fine (jitter absorption) | **Fatal** (seconds of latency, huge memory) | Replace with colored block-buffer pool (§5.3); keep rings only offline. |
| Mutex control plane (`flowgraph.call`) | Acceptable | **Fatal** (priority inversion on RT thread) | Lock-free publish (SPSC command ring + atomic snapshot) (§6.2). |
| Linux-only zero-copy ring | Gap | Minor (rings are offline-only now) | Add macOS `vm_remap` path *if/when* offline zero-copy matters; not on the RT critical path. |
| Collapse-on-error, post-mortem | Weak for long-running | **Important** (a live audio engine must not die on one bad block) | Per-block error isolation: a faulting block emits silence + flags, graph stays up (§6.4). |
| No events/tags with samples | Limitation | **Fatal** (no MIDI/automation/sample-accurate control) | First-class event lane + sub-block rendering (§6.1). |
| No cycles (topological sort errors) | Fine | **Fatal** (no reverb/comb/IIR feedback) | Allow cycles iff every SCC contains a `z⁻¹` delay (§5.3, §6.3). |
| No channel model (one port = one mono stream) | Fine | **Fatal** (audio is multichannel; the project is *pan*) | First-class channel model: planar/interleaved, channel count in the format (§6.5). |
| No latency reporting/compensation | Fine | **Important** (FFT/convolution blocks add latency; parallel paths must align) | Latency accounting + PDC at graph build (§6.6). |
| Fixed `[8]` ports, max 8 readers | Fine | Fine | Keep; revisit only if a real graph needs more. |

---

## 4. Design pillars (the shape of the thing)

```
┌──────────────────────────────────────────────────────────────────────────┐
│  User graph (blocks + composites)   — authored exactly like ZigRadio       │
├──────────────────────────────────────────────────────────────────────────┤
│  Block authoring surface (UNCHANGED): process(self, in:[]const T, out:[]T)  │
│  + audio extensions: channels, control ports, declared latency / in_place   │
├──────────────────────────────────────────────────────────────────────────┤
│  SampleMux probe (vtable)  ── TestSampleMux | PullSampleMux | RingSampleMux  │
├───────────────┬───────────────────────────┬──────────────────────────────┤
│  RT pull       │  RT static-parallel        │  Offline threaded push        │
│  scheduler     │  scheduler (opt-in, heavy) │  scheduler (ZigRadio-style)   │
│  (DEFAULT)     │                            │  file→file, throughput        │
├──────────────────────────────────────────────────────────────────────────┤
│  Buffer model: colored block-buffer pool (RT) | per-edge rings (offline)    │
│  Control plane: lock-free publish (RT) | mutex `call` (offline OK)           │
├──────────────────────────────────────────────────────────────────────────┤
│  Compute HAL: comptime @Vector SIMD (NEON/AVX) + optional vDSP/FFTW          │
│  I/O HAL: CoreAudio | ALSA/JACK/PipeWire | I2S-DMA ;  LPCM stream codecs     │
└──────────────────────────────────────────────────────────────────────────┘
```

The three core decisions (§5) define the middle layers; the audio-specific expansions (§6)
define what flows through them; the HAL (§7) grounds it on the three platforms.

---

## 5. The three core architectural decisions

These were stress-tested in a dedicated systems-design pass. Summarized with the recommended
path; full rationale below each.

### 5.1 Execution model — **tiered schedulers over one block surface**

**Decision:** one block-authoring surface; **three execution tiers**:

- **Tier A — synchronous single-thread pull (DEFAULT, RT).** Render the whole DAG to
  completion inside the audio callback, on device-sized buffers, **no locks, no condvars**.
  A `PullSampleMux` satisfies the *same vtable* as ZigRadio's mux but with pull semantics:
  `waitInputAvailable` always returns exactly N (the scheduler guarantees fullness by
  recursively rendering upstream first), buffers come from the pool, `update` is a no-op
  commit. For the ~80 % of audio blocks that are **1:1-rate, fixed-block, pure** (gain, EQ,
  pan, mix, waveshaper), the block source is **byte-identical** to the offline path.
- **Tier B — static-parallel sync (OPT-IN, heavy RT graphs).** Pre-spawned, RT-priority,
  pinned worker threads; a **compile-time level schedule** from the existing topological sort;
  a **bounded-spin barrier** per level — never park during a callback. The audio thread is
  worker 0. Enable only when a cost model says one core can't make the deadline and there are
  ≥2 performance cores; otherwise degrade to Tier A. **Not** a general work-stealing pool
  (unbounded tail latency; waking workers needs the forbidden futex).
- **Tier C — threaded push (OFFLINE).** ZigRadio's design kept *verbatim* for file→file /
  batch rendering, where latency is irrelevant and large rings + thread-per-block maximize
  throughput. This is where the inherited ring machinery earns its keep.

**The rate-elastic seam (the one place push ≠ pull).** Decimators, upsamplers, and
FFT/overlap-add/partitioned-convolution blocks cannot promise "N out for N in"; on the push
path a ring absorbed the mismatch, on the pull path there is no absorber. Resolution: such a
block **declares `pub const algorithmic_latency`** and owns its internal accumulator/hop grid.
The graph build does **latency accounting** and inserts compensating delays (§6.6). A
rate-elastic block that *fails to declare* latency is a **build error** (Rule 12: fail loud).
This is the only genuine divergence between the two worlds, and it is made explicit rather
than hidden.

**Why not "reuse ZigRadio as-is, smaller rings"** — violates the no-unbounded-blocking
theorem; cannot meet the deadline at any ring size. **Why not two separate block contracts** —
doubles the library and test surface for the 80 % of blocks that are pure 1:1; the SampleMux
abstraction exists precisely to absorb this transport difference.

**Risks.** (1) The unified surface can *leak* at the rate-elastic seam — a block passing
TestSampleMux (push) may behave differently under pull. Mitigate with a **`PullTestSampleMux`**
so every block is tested under *both* contracts. (2) Tier B can introduce nondeterminism /
priority inversion under load — keep Tier A as the always-correct ground truth, gate B behind
a measured cost threshold and an xrun (deadline-miss) counter.

### 5.2 Config-driven precision & block size — **precision comptime, block size runtime**

**Key insight, grounded in Zig 0.16:** precision and block size are *asymmetric*. **Precision
(`T`)** changes machine code (SIMD lane type, instruction selection, accumulator width) and
must be comptime for zero-overhead kernels. **Block size (`N`)** is, for most kernels, just a
loop trip count — and Zig's SIMD vectorization keys off the **comptime vector width `W`
(`std.simd.suggestVectorLength(T)`), not off N being comptime**. A runtime-N loop with a
comptime-W vectorized body + scalar tail vectorizes perfectly. Therefore the feared
"comptime explosion" is driven almost entirely by the *precision* axis — **you never need the
precision × block-size cross-product.** And the audio device *dictates N at runtime* (it can
change on a route switch), so N-comptime is infeasible for the device-facing dimension anyway.

**Decision:**
- **Precision = comptime kernel parameter**, selected *once at pipeline-config time* by binding
  a concrete monomorph's function pointer (one indirect call per *buffer* — free). Supports
  per-block precision (an i16 input-decode block → f32 core → i24/i32 output block, with
  monomorphized conversion blocks at the seams).
- **Block size = runtime everywhere** (a slice length). A device block-size change is just a
  different length; no recompile.
- **SIMD width `W` = comptime per target, via the HAL** — NEON 4×f32 on Apple Silicon, AVX2
  8×f32 on x86 Linux, scalar/small on embedded. Runtime-selectable width only for x86 desktop
  fat-dispatch (AVX2/AVX-512/SSE); elsewhere build per target.
- **The set of precision monomorphs instantiated is itself comptime-gated by build config** —
  embedded compiles **only** its one precision and width (`ReleaseSmall`), keeping the binary
  tiny; desktop carries the configured runtime-reconfigurable set.
- **Intra-kernel algorithmic sizes** (filter order, FFT size) stay **comptime** where the block
  author fixes them (one instantiation per block type — no explosion; enables `inline for`
  unrolling for *short* kernels per skill §14). Only the *streaming/buffer* dimension is
  runtime.

**Risks.** (1) Monomorph-set creep on desktop (binary + compile-time bloat) — make the active
precision set an explicit comptime list, default to the 1–2 precisions actually in use, and
log the generated-monomorph count at build (Rule 12). (2) A few very-short FIR/biquad kernels
genuinely want comptime length — keep that *algorithmic* size comptime; it's independent of
device N and doesn't explode.

### 5.3 Memory model — **colored block-buffer pool + persistent feedback buffers**

**Framing:** the pull graph is a DAG executed in a known order per callback → buffer lifetimes
are statically analyzable. This is **register allocation**: edges = virtual registers,
block-sized buffers = physical registers, the schedule = instruction order, liveness =
[producer write … last consumer read]. Two edges whose live ranges don't overlap **share one
physical buffer**. The number of physical buffers `M` ≈ the **max simultaneously-live edges**,
which for near-linear audio chains is *tiny* (often 3–6) versus N edges.

**Decision:**
1. **Build-time liveness + linear-scan coloring** (after the topological sort, on the DAG with
   feedback edges removed). One linear pass; greedy free-list allocator; `M` = max live edges.
2. **In-place coalescing** for unary blocks whose input is *single-consumer & last-use here* —
   assign output the *same* buffer, eliding the copy. Gate on an explicit
   **`pub const in_place = true`** declaration (never inferred — a block reading `in[i+1]`
   while writing `out[i]` would corrupt). `noalias` (skill §9) is used **only** on the
   non-in-place path; in-place kernels alias by definition.
3. **Fan-out** extends a buffer's live range to its *last* reader and forbids in-place by the
   first reader (a multi-reader buffer can't be overwritten until all have read). The coloring
   cost-models "give one mutating consumer a private copy (a memcpy) vs. pin a buffer longer".
4. **Feedback / cycles** via the standard **`z⁻¹` rule**: split a feedback edge into a
   *write side* (produced this block) and a *read side* (value from the **previous** block).
   The topological sort runs on the DAG-minus-feedback-edges (cleanly resolving ZigRadio's
   `CyclicDependency`); the delay buffer is **persistent, one per feedback edge, excluded from
   the pool** (its live range spans callbacks — it's *state*, not scratch). Graph build verifies
   **every SCC contains ≥1 delay element**, else `error.DelayFreeLoop` (Rule 12).
5. **Footprint = M·N·sizeof(T) + Σ feedback_lengths·sizeof(T) + per-block state**, all known at
   `initialize` time → **one up-front allocation, zero hot-path alloc** (preserves ZigRadio's
   discipline). On embedded this is a **static, bounded high-water mark** — rendas via a
   `FixedBufferAllocator` on heap-less MCUs (skill §8).

**Sizing example (30-edge graph, N=256, f32):** simple per-edge double-buffer ≈ 60·256·4 ≈
**61 KB**; colored pool with M=5 ≈ **5 KB**. On a 256 KB-SRAM MCU that is the difference
between fitting and not. Since the brief explicitly prioritizes memory and targets embedded,
the coloring is worth its build-time complexity (it costs *code written once and tested*, not
runtime cycles or binary size).

**Phasing (Rule 2 — simplicity first):** ship the **simple per-edge double-buffer (mode B)**
first as the correctness baseline; turn on **coloring (mode C)** behind the *same*
`getBuffer(edge)` interface once the graph builder is solid — C is a drop-in optimization, not
a rewrite. In Debug/ReleaseSafe, run a **paranoid mode** that gives every edge its own buffer
and poisons released buffers to NaN — and **differentially test** that B and C produce
*bit-identical* output (Rule 9: the test encodes *why* the allocator is correct).

**Risks.** (1) Aliasing bugs (miscolor / wrong `in_place`) → intermittent audio corruption —
mitigate with explicit `in_place`, paranoid mode, and B-vs-C differential tests. (2) Dynamic
graph edits invalidate the static coloring — recompute **off** the audio thread, hot-swap the
pool atomically at a block boundary, or pre-allocate to a configured max-`M` ceiling so edits
never grow the allocation; on heap-less embedded, declare the worst-case graph at init.

### 5.4 How the three compose (cross-cutting)

- **Synergy:** the `PullSampleMux` (5.1) and the buffer pool (5.3) are the *same seam* — the
  block never knows whether its `out` slice is a private double-buffer, a coalesced pool
  buffer, or an offline ring. The SampleMux abstraction pays off a third time.
- **Tension 1 — pool complicates the unified surface at in-place/fan-out:** under pooled
  in-place, `in` and `out` *alias*; under offline rings they never do. Resolve by making
  aliasing an explicit declared property and testing every block under *both* an aliasing and a
  non-aliasing mux (extends 5.1's dual-mux testing). `noalias` only on the proven-non-aliased
  path.
- **Tension 2 — runtime N vs. pool sizing:** coloring (which buffers, `M`) is N-independent
  topology (comptime/build-time); buffer *byte size* is runtime (`max-N · T`). Size pooled
  buffers to the **maximum** N the device may present; a sub-block render (5.1 / §6.1) just
  uses a prefix. Re-allocate backing bytes only if device N grows; the assignment map is
  unchanged.
- **Tension 3 — RT-safe reconfiguration:** ZigRadio's process-loop-holds-mutex control plane is
  forbidden on the audio thread. All reconfiguration (recolor, re-bind precision monomorph,
  re-schedule) happens **off** the audio thread and is published via a single atomic pointer
  swap consumed at a block boundary (§6.2). A deliberate, forced divergence from ZigRadio.

---

## 6. Expansions audio demands that SDR didn't

These are the genuinely *new* subsystems — where we go beyond ZigRadio rather than adapt it.

### 6.1 Sample-accurate events (MIDI, automation) + sub-block rendering
Introduce an **event lane** parallel to the sample lanes: each render carries a time-sorted
list of `(sample_offset, event)` for the current block. The pull scheduler renders in
**sub-blocks bounded by event offsets** — pull `[0,k)`, apply the event, pull `[k,N)`. Because
pull blocks are pure over their input slice, sub-block splitting is **free** (it's just a
shorter N twice) — a real *advantage* of pull over the ring/push model, where buffer
granularity fights you. FFT/hop-grid blocks declare their own granularity and events to them
quantize to their hop. This is the categorical "tags travel with samples" the audit named,
made first-class and latency-correct.

### 6.2 Lock-free control plane (parameter automation)
Replace `flowgraph.call`'s mutex with: a **single-producer command ring** (UI/automation
thread → audio thread) drained at each callback boundary, plus **atomic snapshot publication**
for bulk parameter sets (build the new set off-thread, publish one pointer atomically). Every
continuous parameter (gain, cutoff) is **per-block smoothed/ramped** across the buffer to avoid
zipper noise — the de-facto control-rate-vs-audio-rate split. No lock the audio callback can
ever wait on.

### 6.3 Feedback / IIR / delay loops
Covered mechanically in §5.3(4). The **library** contribution: a canonical `UnitDelay(z⁻¹)` /
`DelayLine(L)` primitive, and the SCC-contains-a-delay validator, so reverbs (comb/all-pass/
FDN), Karplus-Strong, and feedback IIR are *expressible and safe*. This is the difference
between "DSP toy" and "can build a reverb".

### 6.4 Error isolation / resilience
A live engine must not die because one block faulted (NaN, domain error, device hiccup). On the
RT path, a faulting block **emits silence and raises a flag** consumed by the control thread;
the graph keeps running. (Contrast ZigRadio's deliberate collapse-on-error, which is correct
for batch but wrong for a long-running instrument.) The offline path keeps collapse semantics.

### 6.5 Channel model — *this is "pan"*
Audio is intrinsically multichannel and the project is literally named **pan**. Make channel
layout **part of the stream format**, negotiated alongside rate/precision/block-size:
- **Planar vs. interleaved** representation (planar is friendlier to `@Vector` kernels;
  interleaved is what most devices/LPCM files deliver — convert at the I/O boundary).
- **Channel count + layout** (mono, stereo, quad, 5.1, 7.1, ambisonic orders, arbitrary N).
- **Spatialization primitives** as first-class blocks: stereo/constant-power panners, balance,
  width, upmix/downmix matrices, VBAP/ambisonic encode-decode — the "pan" core. A panner is a
  block whose port format carries channel count; the type system extends naturally
  (`process(in: []const Frame(C_in), out: []Frame(C_out))` where channel count rides in the
  format negotiation).
- **Format negotiation pass:** generalize ZigRadio's `setRate` topological propagation into a
  full **(sample_rate × precision × channel_layout × block_size)** negotiation, validated at
  graph build with loud mismatches and explicit converter insertion (resamplers, channel
  matrices, precision casts) where the user wired incompatible formats.

### 6.6 Latency accounting & plugin-delay-compensation (PDC)
Each block declares its `algorithmic_latency` (0 for pure 1:1). Graph build sums latency along
every path; where parallel paths reconverge (e.g. a dry/wet mix around a convolution reverb),
insert compensating `DelayLine`s on the shorter paths so everything re-aligns sample-accurately.
Report total round-trip latency to the host. SDR didn't need this; audio mixing absolutely does.

### 6.7 Streaming LPCM I/O + stream codecs
The brief's "streaming LPCM in/out": keep ZigRadio's `sample_format.zig` converters (14 PCM
formats, byte↔native, endianness, offset/scale) — they are directly reusable as the **I/O
boundary codecs**. Add: chunked/ring-fed **stream sources/sinks** (stdin/socket/file/device)
that convert interleaved device/LPCM bytes ↔ the internal (planar) representation once, at the
edge. `scripts/` (per brief) hosts the WAV/FLAC/MP3 → raw-LPCM decoders for test data; the
*library* only speaks LPCM and stays codec-free (codecs are an app/script concern, keeping the
core small and disk-light).

---

## 7. The HAL — Apple Silicon / Linux / embedded

Two distinct HALs; don't conflate them.

**Compute HAL (vectorized kernels).** Prefer **portable comptime `@Vector` SIMD** as the
*primary* path — the Zig compiler lowers `@Vector(W, f32)` to NEON on Apple Silicon and
AVX2/AVX-512 on x86, with `W` from `std.simd.suggestVectorLength` per target. This is a strict
upgrade over ZigRadio's "load libvolk via DynLib" approach: it is dependency-free, compiled-in,
cross-platform, and `ReleaseSmall`-friendly for embedded. **Optional accelerated paths**
(discovered/linked, ZigRadio-style) for the few things `@Vector` doesn't cover well:
- **Apple Silicon:** Accelerate / **vDSP** for FFT and large convolutions (and AMX via
  Accelerate); NEON otherwise.
- **x86 Linux:** FFTW (optional) for FFT; AVX2/AVX-512 via `@Vector`.
- **Embedded (Cortex-M/-A):** CMSIS-DSP optional; scalar or small-NEON `@Vector` fallback;
  `ReleaseSmall`, single precision, single width compiled in.
FFT is the main reason to keep a runtime-discovered accel slot; vector math is mostly native.

**I/O HAL (audio device transport).** A thin backend interface (`open/start/stop`, a callback
that hands N frames + a deadline) implemented per platform:
- **macOS:** CoreAudio / AudioUnit (HAL output unit). Dev machine — implement first.
- **Linux:** ALSA (baseline), JACK / PipeWire (low-latency, pro).
- **Embedded:** I2S + double-buffered DMA; the "fill before deadline" contract maps to the
  DMA ping-pong ISR. (Embedded I2S/DMA specifics are platform-dependent and deferred per the
  brief — but the *buffer-footprint* and *single-precision* design above already accounts for
  it.)

---

## 8. Block taxonomy (audio-specific, to seed the library)
- **I/O:** LPCM stream source/sink, device source/sink (per I/O HAL), file render sink.
- **Gain/dynamics:** gain, trim, VCA, compressor/limiter/expander/gate, soft-clip/waveshaper.
- **Filters:** biquad (LP/HP/BP/notch/shelf/peak) — comptime order, runtime coefficients;
  state-variable filter; FIR (reuse `firwin*` designers from `utils/filter.zig`); IIR (needs
  feedback §6.3).
- **Spatial (the "pan" core):** constant-power panner, balance, width, upmix/downmix matrix,
  VBAP, ambisonic encode/decode.
- **Time/feedback:** delay line, comb/all-pass, reverb (FDN), chorus/flanger.
- **Spectral:** STFT/iSTFT (rate-elastic, declares latency), partitioned convolution reverb,
  spectral gate/EQ — primary consumers of the FFT accel HAL.
- **Rate:** decimator/interpolator, rational/arbitrary resampler (rate-elastic).
- **Mix/routing:** summing mixer, splitter/fan-out, matrix router, dry/wet (with PDC §6.6).
- **Sources:** oscillators (sine/saw/square/wavetable), noise, sampler/voice (event-driven §6.1).
- **Analysis (sidechain/metering):** RMS/peak meter, FFT analyzer, pitch/onset (taps, not in
  the audio path's critical latency).

---

## 9. Testing methodology (keep + extend)
- **Keep** the SciPy/NumPy gold-vector oracle (`generate.py` → `vectors/` → `BlockTester`). It
  is exemplary and satisfies Rule 9 (test intent against an independent mathematical truth).
- **Extend** with: **dual-mux testing** (every block under push *and* pull semantics — 5.1);
  **B-vs-C differential tests** (per-edge vs. colored pool produce bit-identical output — 5.3);
  **aliasing tests** (in-place vs. non-aliased — 5.4 Tension 1); **latency-contract tests**
  (rate-elastic blocks' declared latency is real — 5.1, 6.6); **xrun/deadline-miss counters**
  as a first-class test signal for the parallel tier (5.1 Tier B).
- Per CLAUDE.md Rule 14, **dispatch Yoneda test writers at each implementation gate** — the
  highest-value gates are: the liveness/coloring allocator, the in-place legality check, the
  feedback-SCC validator, the format-negotiation pass, and the `PullSampleMux`. Instruct those
  subagents to load the `zig-0-16` skill (Rule 13).

---

## 10. Connection to the `specifications/` (category-theory) workflow
The brief wants specs in categorical/mathematical form as the single source of truth. Natural
mappings to carry into `specifications/catalog.md`:
- **Blocks = morphisms** in a category of typed sample-streams; **composites = composition**;
  the flowgraph = a (finite) diagram; flattening = taking its colimit/normal form.
- **`SampleMux` = a representable probe / the Yoneda embedding** — a block is determined by its
  action on the buffers a mux presents; TestSampleMux *defines*, real muxes *execute*. This is
  the formal justification for "tests as definition" (Rule 14).
- **Push vs. pull schedulers = two functorial interpretations** of the block functor into two
  execution categories, related by a natural transformation; the **rate-elastic adapter** is
  where that transformation is non-trivial (carries the latency obligation).
- **Format negotiation = a constraint/unification problem** over the product object
  (rate × precision × channels × block-size); converter insertion = inserting coercion morphisms
  to make a diagram commute.
- **Feedback = a trace / fixpoint** in a traced monoidal category, well-defined only with the
  `z⁻¹` delay guaranteeing causality (the SCC-has-a-delay law).
- **Liveness/coloring = an interference-graph coloring**; correctness = the colored and
  uncolored interpretations are observationally equal (the differential test *is* the proof
  obligation).

These give the spec real mathematical content rather than decoration, and each maps to a
concrete, testable code obligation.

---

## 11. Risks, open questions, and what to prototype first

**Top risks** (carried from §5): unified-surface leak at the rate-elastic seam; aliasing bugs
from in-place coloring; Tier-B parallel nondeterminism; monomorph-set creep; dynamic-edit vs.
static-coloring. All are mitigated by *making implicit assumptions explicit and loudly tested*
(Rule 12) rather than averaged away (Rule 7).

**Open questions to resolve in the spec phase:**
1. Validate the in-place coalescing against ZigRadio's *actual* wrapper-fn generation — if it
   hard-assumes input/output are distinct allocations, in-place needs a wrapper change, not just
   a new mux. *(Needs reading the real ZigRadio source, which is not in this repo — only the
   reverse-engineered notes are.)*
2. Planar vs. interleaved as the *internal* canonical form (this analysis leans **planar** for
   SIMD; confirm against the spatialization math and conversion cost at the I/O boundary).
3. Precision policy default: f32 internal everywhere with int only at I/O seams (simplest,
   covers 95 % of audio) vs. genuinely per-block precision (more general, more converter seams).
4. Embedded scope: which MCU class is the real target (sets the SRAM budget that decides
   B-vs-C and the single-precision/width build).

**Recommended prototype order (de-risks the most-uncertain pieces first):**
1. **Vertical slice:** CoreAudio device sink + LPCM source + a 3-block pure chain (gain → biquad
   → pan) on **Tier A + mode B**, proving the `PullSampleMux` and sub-5 ms round trip on M3.
2. Add **format negotiation** (rate/precision/channels/block-size) + the **lock-free control
   plane** with one ramped parameter.
3. Add a **feedback** primitive (delay → comb reverb), proving the SCC-delay rule and persistent
   buffers.
4. Turn on **mode C (coloring)** behind the same buffer interface; differential-test B≡C.
5. Add a **rate-elastic** block (STFT or resampler) + **latency accounting/PDC**; prove the
   dual-mux + latency-contract tests.
6. Only then consider **Tier B (parallel)** and the **offline push** path.

---

## 12. One-line summary
**Keep ZigRadio's comptime block surface, SampleMux seam, and gold-vector testing verbatim;
replace its thread-per-block + 8 MiB-ring transport with a synchronous pull scheduler, a
colored block-buffer pool, a lock-free control plane, and first-class audio subsystems
(multichannel "pan", sample-accurate events, feedback, latency compensation) — precision
comptime, block size runtime, SIMD width comptime-per-target — so the same elegant authoring
model now serves hard-real-time audio at sub-5 ms latency and minimal, statically-bounded
memory.**
