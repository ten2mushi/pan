# End-to-End Audio Pipeline Requirements (beyond block-level processing)

> **Status:** ideation / discussion capture. Companion to `notes/architecture_ideation.md`
> and `notes/architecture_audit_feature_extraction.md`. Input for the `specifications/` phase.
> **Scope:** "end-to-end" = **source (device / file / network) → processing graph → sink
> (device / file / network)**. The processing core (latency, throughput, memory, channels,
> events, feedback, PDC) is covered in the ideation doc. This file enumerates what the *whole
> path* additionally demands — the I/O-boundary, time-reconciliation, audio-quality, and
> control/observability requirements that block-level DSP does not surface.
> Ordered roughly by "most likely to bite in production AND least covered so far."

The requirements cluster into three groups:
- **A. I/O boundary & time reconciliation** (§1, §2, §5, §8) — the genuinely *new* layer vs.
  "a graph of DSP blocks." This is what separates "a DSP graph that runs" from "a pipeline
  that survives a long session."
- **B. Audio-quality correctness** (§3, §4, §6) — invisible until it isn't.
- **C. Control & visibility** (§7, §9).

---

## §1. Clocking, clock domains & drift — the highest-leverage gap
The moment input and output are separate devices (or even the same device's capture vs.
playback path), they run on **independent crystal clocks**. Nominal 48 kHz is really
48000.01 Hz on one and 47999.98 Hz on the other. Over minutes, that drift slowly fills or
drains any bridging buffer → guaranteed eventual xrun or overflow.

- Designate a **master clock**; reconcile the others via either an **adaptive / asynchronous
  resampler** on each slave path (continuously nudges the resample ratio to hold the bridging
  buffer's fill level near a target) or a drift-compensating FIFO.
- **Mandatory** for full-duplex (live monitoring, effects on live input).
- Classic "works in the demo, fails after 20 minutes" failure. **Not addressed** in the brief
  or the ideation. If only one thing here gets prioritized, it should be this.

## §2. Sample-rate conversion as a first-class boundary citizen
Device gives 44.1k, pipeline runs 48k, the file is 96k. **Resampling is core, not optional** —
needed at every format boundary *and* for the §1 drift problem.

- Real tradeoff: linear (cheap, ugly) → polyphase sinc (clean, costs CPU + adds latency).
- It is the headline **rate-elastic** case (ideation §5.1 / §6) — declares latency, owns
  internal state. Needs a proper **polyphase resampler primitive**, not an afterthought, plus
  the *adaptive* variant for §1.
- Connects to the brief's config-driven sample rate: the negotiation pass (ideation §6.5)
  inserts resamplers where wired rates disagree.

## §3. Denormals & NaN/Inf safety — audio-specific, cheap to forget
- **Denormals:** in any decaying feedback path (reverb tails, IIR ringing toward silence),
  floats slip into denormal range; some CPUs handle them **10–100× slower** → sudden CPU spike
  → xrun, *while the signal is inaudibly quiet*. Fix: set **FTZ/DAZ** (flush-to-zero /
  denormals-are-zero) on the audio thread, or inject tiny DC / dither noise. **Directly in
  scope now** that the ideation added feedback loops (§6.3).
- **NaN/Inf poisoning:** one NaN (divide-by-zero in a filter, a bad coefficient) propagates
  through the entire graph; the whole output goes silent/garbage *permanently*. Need a NaN
  guard/sanitizer policy (at least in Debug/ReleaseSafe), and per-block error isolation
  (ideation §6.4) should treat NaN as a fault condition.

## §4. Dither & gain staging at the integer boundary
Internal processing is f32 (huge headroom); LPCM output is often i16/i24.

- Truncating f32 → i16 **without dither** adds correlated quantization distortion — audible on
  quiet fades and reverb tails. **Dither (+ optional noise shaping)** on any down-bit
  conversion is a genuine quality requirement.
- Define **clip/saturation behaviour** at the boundary (hard clip vs. soft) and headroom
  policy.
- Lives in the `sample_format` converters (ideation §6.7) but must be called out explicitly,
  not left implicit in the cast.

## §5. Off-thread I/O prefetch for non-RT sources
File and network sources are **bursty and unbounded** — a disk seek or a TCP stall can take
arbitrarily long, so they can **never** run on the audio thread.

- Requires a **background I/O thread + a lock-free FIFO** that prefetches ahead so the RT graph
  always finds data ready. The RT path pulls from the buffer; a separate thread keeps it full.
- This is the brief's "minimize disk / latency" meeting reality. Distinct from the offline
  push path (where throughput rules and blocking is fine).
- Interacts with §1 (the prefetch FIFO is also where capture↔playback drift is absorbed).

## §6. Click-free transitions everywhere
A hard jump from signal to zero is an audible **click**. So start/stop, graph swaps,
**bypass/mute/solo**, and abrupt parameter changes must **ramp/fade**.

- A **bypassed block that has latency must still delay** its signal — otherwise bypassing it
  shifts timing and breaks PDC alignment on parallel paths (ideation §6.6).
- Generalizes the ideation's per-block parameter smoothing (§6.2) into a **pipeline-wide
  transition policy**: transitions are ramped, never stepped.

## §7. Transport / timeline / position
Anything musical or seekable needs a **transport**: sample-accurate play position, seek, loop
points, tempo/PPQ, and a clock that events reference.

- Offline render also needs a deterministic timeline ("render samples 0..N", bit-reproducible
  regardless of wall-clock timing).
- The event lane (ideation §6.1) needs a **position** to timestamp against; transport provides
  it. Optional external sync (MIDI clock, Ableton Link) sits here.

## §8. Device-reconfiguration resilience
At runtime the OS can change the **sample rate or buffer size** (route switch: speakers →
Bluetooth), or the device can disappear.

- The engine must survive this: re-negotiate format, re-allocate the (max-N-sized) buffer pool,
  possibly rebuild the graph — **without crashing or wedging the audio thread.**
- Connects to the dynamic-edit / atomic-republish story (ideation §5.3 risk 2 + §5.4 tension 3),
  but is *forced by the hardware*, not initiated by the user. The pool's "size to max-N"
  decision (§5.4 tension 2) is partly motivated by this.

## §9. Observability / telemetry
You cannot run a real pipeline blind. Core signals:

- **xrun / deadline-miss counters** (first-class, also the gate for enabling the parallel
  scheduler tier — ideation §5.1 Tier B).
- **Per-block CPU / total deadline headroom** ("am I at 30% or 95% of budget?") — essential
  for tuning the latency-vs-safety knob (block size).
- **Level metering + the visualization tap** the brief already wants (analysis sinks,
  audit S3). Cheap to add; essential for tuning.

---

## How they map to the existing ideation

| Requirement | Status in current material | Where it attaches |
|---|---|---|
| §1 Clock domains / drift | **Missing** (highest-leverage gap) | new — I/O HAL + async resampler |
| §2 Sample-rate conversion | Implied (rate-elastic) but not first-class | ideation §5.1 / §6.5 |
| §3 Denormals / NaN | **Missing**; now in-scope via feedback | ideation §6.3 / §6.4, audio thread setup |
| §4 Dither / gain staging | Implicit in casts; not called out | ideation §6.7 (`sample_format`) |
| §5 Off-thread I/O prefetch | Partially (two-domain idea) but not the FIFO | new — I/O HAL |
| §6 Click-free transitions | Partially (param smoothing) | generalize ideation §6.2 + §6.6 |
| §7 Transport / timeline | **Missing** | new — needed by event lane §6.1 |
| §8 Device reconfiguration | Partially (dynamic edit) | ideation §5.3 / §5.4 |
| §9 Observability | Partially (xrun counter mentioned) | extend across the engine |

---

## One-line takeaway
The processing graph is the *visible* half of an audio pipeline; the **I/O boundary and time
reconciliation** (clock drift / async resampling, off-thread prefetch, device reconfig) plus
**audio-quality hygiene** (denormals, NaN, dither, click-free transitions) are the *invisible*
half that decides whether the pipeline merely runs or actually survives a long real-world
session. The single most underweighted item for the stated goal (a real input→output pipeline
on M3 / Linux / embedded) is **§1 — clock-domain/drift handling with an adaptive resampler.**
