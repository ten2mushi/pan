# pan — I/O Boundary, Real-Time Hygiene & End-to-End Pipeline

> **Status: LOCKED** (2026-06-02). Change-control: conforms to [`catalog.md`](catalog.md); an edit
> that changes a definition or law must update catalog.md and every citing section in the same commit.
>
> Support document for [`pan_architecture_formalisation.md`](pan_architecture_formalisation.md)
> (the hub). Siblings: [`pan_execution_model.md`](pan_execution_model.md) ·
> [`pan_memory_model.md`](pan_memory_model.md) ·
> [`pan_type_and_numeric_model.md`](pan_type_and_numeric_model.md) ·
> [`pan_categorical_bridge_and_roadmap.md`](pan_categorical_bridge_and_roadmap.md).
>
> Scope: everything the *whole path* (source → graph → sink) needs beyond block-level DSP — the
> I/O HAL, clock-domain drift, off-thread prefetch, audio-quality hygiene, the lock-free control
> plane, device-reconfiguration, transport, observability. Folds in
> [`end_to_end_pipeline_requirements.md`](../notes/end_to_end_pipeline_requirements.md). Most items here are
> **layered libraries** ([hub §5](pan_architecture_formalisation.md)), not frozen core — but they are
> what separates "a graph that runs" from "a pipeline that survives a long session."
>
> Defined terms resolve to [`catalog.md`](catalog.md) — the single source of truth (read first).

---

## 1. Clock-domain drift & asynchronous SRC — the highest-leverage gap

The moment input and output are **separate devices** (or capture vs playback on one device), they run
on independent crystals: nominal 48 kHz is really 48000.01 vs 47999.98 Hz. Over minutes the drift
fills or drains any bridging buffer → guaranteed eventual xrun/overflow. The classic "works in the
demo, fails after 20 minutes" bug; **unaddressed in the brief and ideation**.

**Design:** designate a **master clock**; on each slave path run an **adaptive (asynchronous)
resampler** — a `Rate` block ([exec §2](pan_execution_model.md)) whose ratio is nudged in real time
by a **slow, smoothed PI controller** on the bridging FIFO's fill level (keep it centered). Keep the
ratio in **wide fixed-point** (reference: XMOS lib_src uses Q4.60 with an adaptive polyphase FIR,
>130 dB SNR). Mandatory for full-duplex (live monitoring / effects on live input). **Bypass entirely
on a single full-duplex device** (one clock — detect and skip). Belongs at the *device boundary*, not
inside the graph.

## 2. Sample-rate conversion as a first-class boundary citizen

Device gives 44.1k, pipeline runs 48k, file is 96k → resampling is **core to the boundary**, not
optional. It is the headline `Rate` case: a **polyphase sinc resampler primitive** (declares latency,
owns state), plus the *adaptive* variant for §1. The format-negotiation pass
([`pan_type_and_numeric_model.md` §2](pan_type_and_numeric_model.md)) inserts resamplers where wired
rates disagree. Tradeoff surfaced explicitly: linear (cheap, ugly) → polyphase sinc (clean, costs
CPU + latency).

## 3. Denormals & NaN/Inf safety

- **Denormals:** in any decaying feedback path (reverb tails, IIR ringing toward silence), floats
  slip into subnormal range; some CPUs are **10–100× slower** there → sudden CPU spike → xrun *while
  the signal is inaudibly quiet*. Fix: set **FTZ/DAZ** (flush-to-zero / denormals-are-zero) on the
  audio thread.
  > **M3 footgun (concrete, cost real shipping bugs):** on ARM64 the FPCR **FZ** bit is **per-thread
  > and NOT inherited by child threads** (unlike x86 MXCSR via `pthread_create`). pan **must set
  > flush-to-zero on the audio thread itself**, and again on any worker it spawns. Mixxx shipped
  > full-volume noise on Apple Silicon from exactly this bug.
  >
  > **Required realtime-thread token (the blessed entry point).** Running pan DSP on a thread
  > **requires holding a token** whose construction sets FTZ/DAZ on the *calling* thread:
  > `enterRealtimeThread()` returns the token, and `renderInto` / any custom-worker render entry
  > **requires the token — it won't compile without it**, so FTZ-on-a-self-spawned-thread is
  > structurally impossible to forget (the Mixxx-class footgun is closed at compile time). The audio
  > HAL mints the token for its own callback; a user who spawns a worker must call
  > `enterRealtimeThread()`. On **fixed-point (`i16/q15`) targets it is a no-op token** (no FPU, no
  > FTZ) — but the API shape is **identical across all targets**, preserving the
  > same-code-everywhere property. *Illustrative — Zig 0.16:*
  > ```zig
  > const rt = pan.realtime.enterRealtimeThread(); // sets FPCR FZ/DAZ on THIS thread; returns a token
  > defer rt.leave();
  > engine.renderInto(rt, &scratch, dma_half);     // requires the token => won't compile without it
  > ```
  > (Caveat: the token is a strong structural nudge, not a proof — H3 cannot prove FTZ is *still* set
  > if a user mutates FPCR after taking the token.)
- **NaN/Inf poisoning:** one NaN (divide-by-zero, bad coefficient) propagates through the whole
  summing graph and persists in feedback state *permanently*. Policy: NaN guard/sanitizer at block
  outputs in Debug/ReleaseSafe (compiled out in release); per-block error isolation
  ([exec §7](pan_execution_model.md)) treats NaN as a fault → silence + flag.

## 4. Dither & gain staging at the integer boundary

Internal processing is f32 (huge headroom); LPCM output is often i16/i24. Truncating f32→i16 **without
dither** adds correlated quantization distortion — audible on quiet fades / reverb tails. **Dither
(+ optional noise shaping)** on any down-bit conversion is a genuine quality requirement; define
**clip/saturation behaviour** (hard vs soft) and headroom policy at the boundary. Lives in the LPCM
converters (§5) but must be *called out*, not left implicit in the cast.

## 5. Streaming LPCM I/O + off-thread prefetch

- **LPCM codecs:** keep ZigRadio's `sample_format.zig` converters (14 PCM formats, byte↔native,
  endianness, offset/scale) as the **I/O-boundary codecs**: convert interleaved device/LPCM bytes ↔
  the internal **planar** representation once, at the edge. The *library* speaks only LPCM and stays
  codec-free; WAV/FLAC/MP3 → raw-LPCM decoders live in `scripts/` (an app concern; keeps the core
  small and disk-light, per the brief).
- **Off-thread prefetch:** file/network sources are bursty and unbounded (a disk seek or TCP stall
  can take arbitrarily long) → they can **never** run on the audio thread. A **background I/O thread +
  lock-free SPSC FIFO** prefetches ahead; the RT graph pulls from the FIFO (a `Rate` source block over
  the ring). This FIFO is also where capture↔playback drift (§1) is absorbed. Distinct from the
  offline push path (Tier C), where blocking is fine.

## 6. Sample-accurate events + sub-block rendering

An **event lane** parallel to the sample lanes carries a time-sorted list of `(sample_offset, event)`
for the current block (MIDI, automation). The pull scheduler renders in **sub-blocks bounded by event
offsets** — pull `[0,k)`, apply the event, pull `[k,N)`. Because `Map` blocks are pure over their
input slice, sub-block splitting is **free** (a shorter N twice) — a real advantage of pull over
push. FFT/hop-grid `Rate` blocks declare their own granularity; events to them quantize to the hop.
Model events as `(sample_offset, value)` (VST3/CLAP shape) so sample-accurate automation is a later
upgrade, not a rewrite.

## 7. Lock-free control plane

Replace ZigRadio's mutex `flowgraph.call` with three real-time-safe mechanisms (none the audio thread
can block on):
- **SPSC command ring** (UI/automation thread → audio thread) drained at each callback boundary, for
  *sequences* (graph edits, MIDI, parameter events).
- **`atomic<T>`** for individual scalar parameters (lock-free on M3/x86/ARM).
- **Atomic-pointer RCU** to publish bulk state (pinned to exact orderings in [`pan_concurrency_and_memory_ordering.md` §4](pan_concurrency_and_memory_ordering.md): **single-pointer RCU + epoch-based reclamation** for the plan; a triple-buffer is the option for fixed-size parameter snapshots) — including a newly-compiled **render
  op-list** (graph edit, [exec §4.3](pan_execution_model.md)) or a parameter snapshot: build off-thread,
  swap one pointer at a block boundary.
Every continuous parameter (gain, cutoff) is **per-block smoothed/ramped** across the buffer to avoid
zipper noise (the control-rate vs audio-rate split). Generalize to a **pipeline-wide transition
policy** (§6 of the e2e doc): start/stop, graph swaps, bypass/mute/solo all **ramp, never step**.

**The public control API is exactly three verbs, bound 1:1 to the three mechanisms** (canonical:
[`catalog.md` §10](catalog.md)) — the *kind of change* selects the mechanism, and the mechanism is
named in the verb (never a guess):

| Intention | Verb | Mechanism | RT-safety / contract |
|---|---|---|---|
| "Move a knob" — continuous parameter | **`set`** | atomic scalar + per-block ramp | wait-free; click-free; **NOT sample-accurate by contract** (ramped to target by end of buffer) |
| "Automate at a point" — sample-accurate change | **`schedule`** | SPSC command ring, applied at a sub-block boundary | wait-free enqueue (drained at the boundary); **sample-accurate at a given sample offset** |
| "Rewire" — topology / bulk change | **`edit`→`commit`** | RCU plan swap built off-thread, published at a block boundary ([exec §4.3](pan_execution_model.md)) | wait-free atomic pointer swap; no audio glitch |

`set` **rejects sample-accuracy at the type level** — there is no `at_sample` parameter on `set`, so
"I expected `set()` to be sample-accurate" is a compile error of omission, not a silent wrong
behaviour; sample-accurate intent is only expressible on `schedule`. *Illustrative — Zig 0.16:*
```zig
gain.set(.gain, 0.5);                                              // (1) atomic + ramp; not sample-accurate
engine.schedule(.{ .at_sample = 64, .node = gain, .param = .gain, .value = 0.0 }); // (2) SPSC ring; sample-accurate
var edit = engine.beginEdit(); _ = try edit.add(pan.fx.Chorus(Num), .{}); try edit.commit(); // (3) RCU topology
```

> **Named law — *bypass preserves latency*.** A *bypassed* block that has latency
> (`algorithmic_latency > 0`) must **still delay** its signal by exactly that latency — otherwise
> bypassing shifts timing and breaks PDC alignment on parallel paths
> ([`pan_memory_model.md` §7](pan_memory_model.md)). Built-in bypass (a `set`-style ramped
> transition) **honours this automatically**, routing through the compensating `DelayLine` PDC
> already inserts. **Custom bypass authors who manipulate routing directly must route through the
> compensating delay**; where detectable at commit (a latent bypass-capable block with no
> compensating path) it is a **commit warning/error**.

## 8. Device-reconfiguration resilience & the embedded ISR mapping

- **Desktop:** the OS can change sample rate / buffer size (route switch: speakers → Bluetooth) or
  remove the device. The engine must **re-negotiate format, re-size the (max-N) pool backing bytes,
  rebuild + atomic-swap the plan — without crashing or wedging the audio thread**. The pool's
  "size to max-N" choice ([`pan_memory_model.md` §8](pan_memory_model.md)) is partly motivated by this.
- **Embedded:** the render callback **is** the I2S DMA ping-pong ISR. Configure DMA in **circular
  mode** over a `2N` buffer: the **half-transfer (HT) IRQ** → process/fill the first half while DMA
  streams the second; **transfer-complete (TC) IRQ** → process the second while DMA refills the first.
  "Fill before the deadline" = "finish before the next HT/TC IRQ." N is **comptime-known** here
  ([hub §7](pan_architecture_formalisation.md)). *Verify the known STM32-HAL circular-mode TC-callback
  suppression bug on the actual target.* Compute kernels use CMSIS-DSP (auto Helium/NEON). Bela proves
  2-sample buffers / sub-ms round-trips are viable, so keep block size a build/init parameter.

## 9. Transport / timeline / position

Anything musical or seekable needs a **transport**: sample-accurate play position, seek, loop points,
tempo/PPQ, a clock events reference. Offline render needs a deterministic timeline ("render samples
0..N", bit-reproducible regardless of wall-clock). The event lane (§6) timestamps against the
transport position; optional external sync (MIDI clock, Ableton Link) sits here. **Missing from the
brief/ideation**; needed by the event lane.

## 10. Observability / telemetry

You cannot run a real pipeline blind:
- **xrun / deadline-miss counters** — first-class, and the gate that *would* enable a future Tier B
  ([exec §5](pan_execution_model.md)).
- **Per-block CPU / total deadline headroom** ("30 % or 95 % of budget?") — for tuning the
  latency-vs-safety knob (block size).
- **Level metering + the visualization tap** ([`1.md`](../notes/1.md)) — analysis sinks on their own pull root
  ([exec §6](pan_execution_model.md)); cheap, essential for tuning.
- **`guards_compiled_out: bool`** on the telemetry struct — `true` in `ReleaseFast`/`ReleaseSmall`,
  `false` in `Debug`/`ReleaseSafe`. A release build therefore cannot **silently** drop NaN/Inf
  guards (§3): a one-line telemetry read tells you whether they are live (`nan_guards_active =
  !guards_compiled_out`). *Illustrative:*
  ```zig
  const t = engine.telemetry();
  std.log.info("xruns={d} nan_guards_active={} headroom={d:.0}%",
      .{ t.xrun_count, !t.guards_compiled_out, t.deadline_headroom * 100 });
  ```

---

## 11. The HAL — two distinct HALs, don't conflate

**Compute HAL (vectorized kernels).** Primary path = portable comptime `@Vector(W,T)` SIMD (the Zig
compiler lowers to NEON on M3, Helium on Cortex-M55, AVX2/AVX-512 on x86; `W` from the HAL per
[`pan_type_and_numeric_model.md` §3](pan_type_and_numeric_model.md)). Dependency-free, compiled-in,
`ReleaseSmall`-friendly — a strict upgrade over ZigRadio's "load libvolk via DynLib." **Optional
accelerated paths** (runtime-discovered, ZigRadio-style) only for what `@Vector` doesn't cover well:
Accelerate/vDSP (FFT, large convolution) on Apple Silicon; FFTW on x86; CMSIS-DSP on Cortex-M. FFT is
the main reason to keep a runtime-discovered accel slot.

**I/O HAL (device transport).** Thin backend interface (`open/start/stop`, a callback handing N frames
+ a deadline): **macOS** CoreAudio/AudioUnit (dev machine — implement first); **Linux** ALSA baseline
+ JACK/PipeWire low-latency; **embedded** I2S + double-buffered DMA (§8).

---

## 12. What the spec must pin down here

- The `ClockSource`/master-clock model and the adaptive-resampler PI-control contract (§1).
- The LPCM ↔ planar boundary-codec contract and the dither/headroom policy (§4–§5).
- The event-lane `(offset, event)` format and sub-block-render rule (§6).
- The three control-plane primitives and the pipeline-wide ramp policy (§7), including the **unified
  parameter surface** — the three verbs `set`/`schedule`/`edit` bound 1:1 to atomic / SPSC ring / RCU,
  the `intention → mechanism → RT-safety` mapping table, and `set` rejecting sample-accuracy at the
  type level (§7).
- The *bypass-preserves-latency* named law and its commit-time check for custom bypass (§7).
- The **required realtime-thread token** (`enterRealtimeThread()` sets FTZ/DAZ; `renderInto` /
  custom-worker entry require it; no-op token on fixed-point, uniform API shape) and the
  `guards_compiled_out: bool` telemetry field (§3, §10).
- The device-reconfiguration / atomic-plan-swap protocol and the embedded ISR-as-callback mapping
  (§8) — explicitly noting which of these are desktop-only.
