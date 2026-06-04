# Handoff — end of Session 12 (P13 "Sources, typed event lane, NoteEvent, PolyVoice, Instrument") → into P14

> **Status:** P0–P12 + **P13 implemented and green.** The Instrument graph shape ships end-to-end:
> audio-rate Source oscillators, the typed `EventLane(Event)` + blessed `NoteEvent`, fixed-capacity
> intra-block `PolyVoice` (fused + replicated), a `Transport`, the engine's out-of-band event delivery
> (`sendEvent` → per-block drain → `EventLane`), and a `MidiEventSource` ingestion adapter. The §5.7g
> (generators + anti-aliasing) and §5.7h (events + PolyVoice) Yoneda gates pass. Advisory handoff, not a
> spec: `specifications/` + `pan_implementation_plan.md` remain the source of truth.
> **Date:** 2026-06-05. **Toolchain:** `zig 0.16.0` (re-run `zig version` at P14 start — Rule 13).

---

## 1. Ownership statement (honest, Rule 12)

The P13 **gate** (plan §13 success criteria) is **met and green across the four-mode matrix** plus
fmt-check / smoke / neg-compile / cross-linux (all exit 0; 3 repeated `zig build test` runs deterministic).
Trust the EXIT CODE, never a printed count (the carried reject-path noise — gold "allclose fail" lines,
the aliasing quote-back `error:` lines, the dual-mux/comparator "expected this output" diffs, the
neg-compile `@compileError`s — all print by design and fail NO step).

Each gate criterion, discharged:
- **Held-then-released MIDI chord renders `Vmax`-bounded polyphony; no audio-thread malloc/lock** — the
  `PolyVoice` voice pool is `Vmax` comptime persistent state (one static op, Y1); the engine event
  delivery is a bounded SPSC drain + a stack-local lane build (no alloc, no lock). Proven in
  `instrument_engine_test.zig` (a 3-note chord sounds, then releases to **bit-exact** silence) and
  `polyvoice_behaviour_test.zig` (Vmax-bounded under stealing).
- **Each note onset lands sample-accurately (vs an offset-tagged oracle)** — a `note_on` at offset `k`
  yields **bit-exact** silence on `[0,k)` and sound on `[k,N)`, AND a whole-block render is **bit-identical**
  to a hand-split-and-concatenated render at the event offsets (the §5.6 state-granularity property). The
  sub-block split is **internal to `PolyVoice`** (a fused opaque loop), so the static op-list is untouched.
  Proven both block-level (§5.7h) and through the runtime engine (`instrument_engine_test`).
- **Voice-stealing past `Vmax` is click-free** — a steal **retriggers the oldest voice in place** (envelope
  attacks from its current level, oscillator phase left running), so there is no amplitude/phase
  discontinuity. Proven by a discriminating max-adjacent-delta measure at a phase-peak steal instant
  (continuous ≈ 0.13 vs a hard-reset contrast ≈ 0.99).
- **Panner output carries the declared layout `L` (mismatch = commit error)** — unchanged from P4/P4.5
  (`ConstantPowerPan` is `.mono → .stereo`, layout-identity-checked at `connect`); the instrument slice
  composes it (`PolyVoice → ConstantPowerPan → sink`) and the layout check is the existing ⊢ `connect` law.
- **Oscillator numerics match a band-limited (PolyBLEP) oracle within tolerance** — §5.7g compares pan's
  `PolyBlepSaw`/`PolyBlepSquare` against inline NAIVE references via a DFT upper-band (12–24 kHz @ 48 kHz)
  energy measure: PolyBLEP cuts that band to ratio **0.327** (saw) / **0.156** (square) while the
  fundamental survives — proving it materially band-limits where a naive ramp (ratio ≈ 1) aliases.
- **Footprint is a `Vmax`-comptime constant** — `PolyVoice(Voice, Vmax)` is `[Vmax]Voice` persistent state;
  `@sizeOf` is a comptime constant in `Vmax` by construction (no dynamic node, no audio-thread alloc, Y1/Y4).

**Yoneda dispatch (Rule 14):** two autonomous `yoneda-test-writer` agents (each loaded `zig-0-16`,
verified by compiling). **38 tests, all green; 0 surviving bugs (0 src defects found):**
`generator_gold_vector_test` (20 — analytic-sine/LCG-noise/wavetable oracles, the PolyBLEP-vs-naive
anti-aliasing discriminator, phase-carry block-split ≡ whole, pull-length invariant) and
`polyvoice_behaviour_test` (18 — bit-exact onset split, whole≡hand-split, click-free steal at a
phase-peak, `note_id`/MPE routing to the owning slot, `VoiceMap ≡ PolyVoice` bit-exact, `EventLane(E)`
genericity over a non-NoteEvent `E`). Plus 4 engine-integration tests (`instrument_engine_test`) I wrote
to prove the `sendEvent` wiring, and the inline unit tests in `gen.zig`/`synth.zig`/`io.zig`.

Test totals: **133/133 steps, 1241/1241 tests, exit 0** (Debug; ReleaseSafe & ReleaseFast exit 0;
3 repeated runs deterministic), up **+61** from P12's 1177.

> **Post-completion ownership re-audit (Rule 12 in action).** An adversarial "do you take full
> ownership of the WHOLE §13 surface?" re-read of the plan + specs caught **5 genuine scope items** the
> first pass had cut or hand-waved — all now **closed**: (1) the **off-thread prefetch streaming source**
> (`io.PrefetchSource`, a named library block in bridge §2 + the long-standing `io.zig` "lands with the
> streaming phase" TODO comment); (2) the **`ChannelMap` functoriality ≈-test** (a plan §13 / prior-handoff
> residual); (3) the **Instrument slice through `ConstantPowerPan`** (the gate's "panner carries layout
> L" — previously only `PolyVoice → mono sink` was tested); (4) the Voice's **filter stage** (the plan's
> Voice is `osc→env→filter→VCA`; the first `SawVoice` was `osc→env→VCA` — a one-pole lowpass tone filter
> was added); (5) the **footprint-is-`Vmax`-comptime-constant** assertion. This is the same class of cut
> the P12 re-audit caught — surfaced and fixed rather than rationalised.
>
> **A second, INDEPENDENT audit** (a fresh agent that read the brief/plan/specs itself and hunted for
> bugs) then found two more line-items + low-severity contract nits — **A, C, D now fixed** (see
> `dev-notes/p13-generation-pipeline-residuals.md`): **(A)** Transport↔event-dispatch wired via a second
> **timeline ring** + `engine.scheduleEventAt(node, abs_sample, event)` (absolute-transport events
> delivered in their block at the right offset; merged with live `sendEvent` events and **stably
> offset-sorted** — §9); **(C)** `PolyVoice` routes `note_off`/expression to the **single** owning slot
> (`findOwningSlot`), never fanning out across duplicate `note_id`s; **(D)** the per-block sort makes
> out-of-order events safe and the previously-misleading "sorted" comments now accurate. **Still open: (B)**
> the Phase-13 **bench** (`bench/synth_bench.zig`); **(E)** the §5.7h dual-mux methodology deviation; the
> f32-mono/hardware scope tiers.

---

## 2. What was built (the deltas)

```
src/gen.zig      (M)  + audio-rate Source generators (the existing file also hosts the control-rate `Lfo`):
                       `Sine`, `PolyBlepSaw`, `PolyBlepSquare`, `Noise`, `Constant`, `Wavetable` — each a
                       zero-sample-input `Map` source emitting `Sample(f32)`, `out.len` = pull `N`, with a
                       per-sample `tick()` core (so a `Voice` can drive it sample-by-sample) + a block
                       `process(out)`. Saw/square use PolyBLEP band-limiting; `freq` is a Hz parameter port
                       converted to a phase increment via `sample_rate`. `Noise` is a dependency-free
                       64-bit LCG (freestanding-safe + offline-reproducible). f32 only (see §4).
src/io.zig       (M)  + `PrefetchSource(num, cap)` — the off-thread-prefetch streaming file/network
                       source (SR2): a `Sample(T)` Map Source over a lock-free SPSC FIFO filled by a
                       background prefetch thread; the audio thread pops wait-free (no disk I/O on the
                       render path), glitch-free hold + `underruns` count on momentary underrun,
                       `signalEos` + drained ring ⇒ `exhausted()` for a non-RT input-exhaustion root.
src/synth.zig    (M)  + `SawVoice` gained the **filter** stage — it is now the canonical `osc → env →
                       filter → VCA` (a one-pole lowpass tone filter, `cutoff_hz`, default near-open so
                       the raw-saw character is preserved). Filter state carries on a steal (click-free).
src/synth.zig    (NEW) the synthesis library:
                       + `EventLane(Event)` (event-type-generic, a read-only view over a time-sorted
                         `[]const Timed(Event)`; `is_event_lane` marker), `Timed(Event)`, `NoteEvent`
                         union (pitch in Hz), `ExprAxis`.
                       + `requireVoice` (the Voice contract: `noteOn/noteOff/renderAdd/isActive` + optional
                         `setExpression/setPressure/levelProbe`), `SawVoice` (PolyBLEP osc → per-sample
                         ADSR → velocity VCA; retrigger attacks from current level, phase continuous).
                       + `PolyVoice(Voice, Vmax)` — **fused** intra-block polyphony as ONE static op:
                         note→slot allocator (free slot, else steal oldest/quietest **in place** =
                         click-free), `note_id` routing for note_off/pressure/expression, a summing mixer,
                         and the **internal sub-block split** (walk sorted events, render segments between
                         offsets). `Vmax` comptime ⇒ bounded footprint.
                       + `VoiceMap(Voice, Vmax)` — the **replicated** realisation (all `Vmax` render every
                         block); output bit-identical to the fused `PolyVoice`.
src/port.zig     (M)  + `isEventLaneParam` / `EventOf` / `isEventConsumer`; the Map port scanners
                       (`mapPortCounts`, `MapInElem`, `MapOutElem`, `MapInElemAt`) now SKIP an event-lane
                       param (the rate readers already skipped non-port params). So an event-consuming
                       block is still a zero-sample-input **Source** with its audio out port intact.
src/engine.zig   (M)  + `EventCommand` (node + at_sample + `NoteEvent`), `EventRing` (SPSC), `EventDispatch`
                       (the per-block drained view), `EvtCollector` (the drain consumer), `buildEventLane`
                       (filters the block events to a node, re-stamps the offset, into a stack buffer).
                       + the `RenderThunk` signature gained an `events: *const EventDispatch` param;
                       `renderThunk` + the comptime `Executor.runOp` arg loops gained an event-lane branch
                       (runtime: build the lane; comptime/embedded: an EMPTY lane — no runtime ring there).
                       + `replayBound` threads the dispatch; `renderCurrent` and the offline loop drain the
                       event ring per block and advance the `Transport`.
                       + `sendEvent(node, at_sample, NoteEvent)` (was a `schedule` alias) enqueues into the
                       event ring. `transport: io.Transport` field.
src/io.zig       (M)  + `Transport` (sample-accurate position, tempo, loop; offline timeline is a pure
                       function of it) + `MidiEventSource(Event)` (a fixed-capacity FIFO ingestion adapter:
                       `push`, `forward(eng, node)` → `sendEvent`, `lane()` for block-level use).
src/root.zig     (M)  + `pan.synth`, `pan.NoteEvent`, `pan.EventLane`, `pan.Timed`, `pan.ExprAxis`,
                       `pan.SawVoice`, `pan.PolyVoice`, `pan.VoiceMap`, `pan.Transport`, `pan.MidiEventSource`
                       (the audio oscillators are reached via `pan.gen.Sine` etc.).
tests/instrument_engine_test.zig (NEW)  the runtime-engine event-delivery gate (4 tests).
tests/generator_gold_vector_test.zig (NEW, §5.7g, 20 — Yoneda) · tests/polyvoice_behaviour_test.zig
                       (NEW, §5.7h, 18 — Yoneda).
build.zig        (M)  + the three new harnesses registered.
```

## 3. Verify — reproduce green (from repo root)
```sh
zig build test                          # Debug — 133/133 steps, 1241/1241 tests, EXIT 0 (check the exit code!)
zig build test -Doptimize=ReleaseSafe   # exit 0
zig build test -Doptimize=ReleaseFast   # exit 0
zig build fmt-check                     # exit 0
zig build smoke                         # exit 0  (ReleaseSmall freestanding — Noise's LCG is freestanding-safe)
zig build neg-compile                   # exit 0
zig build cross-linux                   # exit 0
```

## 4. The load-bearing design decisions (Rule 7 / Rule 12) — surfaced deviations

- **The event lane is delivered OUT-OF-BAND, not as a colored pool edge.** `EventLane(Event)` is a
  `process`/`pull` parameter the executor supplies from the engine's per-node event store (the same way a
  `set` value arrives out-of-band), NOT a pooled graph edge. The port scanners skip it; `isSource` still
  sees zero *sample* inputs. **Why:** an event list is a variable-length, non-buffer thing; making it a
  colored edge would contaminate the pool and risk the static op-list. Out-of-band delivery keeps the
  op-list pure and unconditional (§8.9) — arguably *more* faithful than a pooled edge. **Consequence:**
  the dev-example authoring form `connect(notes, poly.events)` (a pooled event edge) is **not** wired;
  instead you `engine.sendEvent(polyNode, at_sample, event)` (or `MidiEventSource.forward(eng, polyNode)`).
  The `PolyVoice` is itself the event-rooted Source of the Instrument graph (`PolyVoice → Pan → sink`).
- **Sample-accurate onset is INTERNAL to the consuming block.** `PolyVoice.process` walks its sorted lane
  and renders sub-segments between offsets — a fused opaque loop, NOT an executor op-split. This is the
  §8.12 fused-`PolyVoice` discipline; it keeps one static op per node (Y1) and is the same shape as the
  §5.4 tight-feedback kernels.
- **The engine event store ships the blessed `NoteEvent` only.** The `EventLane(Event)` *mechanism* is
  fully event-generic (EV1) and dual-mux/block-tested for any `E`; engine *delivery* is specialised to
  `NoteEvent` (the instrument use). A block declaring a different `Event` gets an empty lane from the
  engine (its events arrive block-level / offline). A future general engine store would key per-node `E`.
- **Audio oscillators + voices are f32-only.** The control `Lfo`/`Adsr` and the audio sources/voices are
  `Sample(f32)` (the common audio precision and the PolyBLEP-oracle path). A `Num`-generic oscillator /
  fixed-point voice tier is the explicit quality upgrade, **not** implemented (the dev example writes
  `gen.PolyBlepSaw(Num)`/`SawVoice(Num)`; the shipped ones are non-generic — conform the example or add
  the generic tier in a future phase).
- **`Voice` is a duck-typed comptime contract**, not a vtable: `PolyVoice` calls `noteOn/noteOff/renderAdd/
  isActive` directly on its persistent `[Vmax]Voice` slots (optional `setExpression/setPressure/levelProbe`
  gated by `@hasDecl`). `requireVoice` gives a readable `@compileError` for a non-conforming voice.

## 5. Surface coverage audit (Rule 12 — plan §13 work items, honest verdict; post-re-audit)
- **Work item 1 (Sources)** — **FULLY DONE.** Oscillators/noise/wavetable/constant (`gen.zig`) PLUS the
  **off-thread-prefetch streaming source** (`io.PrefetchSource`, the SR2 file/network source the plan +
  bridge §2 name). `io.SamplePlayer` (varispeed/pitch) already shipped in P12; with `LpcmSource` (in-mem)
  and `PrefetchSource` (streaming FIFO) the SR2 surface is complete.
- **Work item 2 (event lane + `NoteEvent` + `MidiEventSource` + transport)** — **DONE** (`synth.zig` +
  `io.zig`), with the out-of-band-delivery deviation in §4. External transport sync (MIDI clock / Ableton
  Link) is **deferred** (the `Transport` has the position/tempo/loop surface; sync hooks are future).
- **Work item 3 (`Voice` = `osc→env→filter→VCA` / `PolyVoice` both realisations + the Instrument slice)**
  — **DONE.** `SawVoice` is now the canonical 4-stage chain (osc → env → **one-pole lowpass** → velocity
  VCA); `PolyVoice` fused + `VoiceMap` replicated; the **Instrument slice `PolyVoice(SawVoice,16) →
  ConstantPowerPan(stereo) → stereo sink`** is rendered through the runtime `Engine` (both planes sound,
  centred = equal, the panner output carries the stereo layout `L` — the gate's panner-layout criterion).
- **Voice-stealing realisation (disclosure, Rule 7):** stealing **retriggers the oldest/quietest voice
  in place** (envelope attacks from its current level, oscillator phase + filter state left running) —
  genuinely click-free (Y3), and a legitimate alternative to the spec's illustrative "release-ramp the
  stolen voice." Both are click-free; the obligation (Y3) is met. `.oldest` and `.quietest` policies ship.
- **Gate items needing hardware — DEFERRED, honestly:** **live CoreAudio MIDI device input** (hardware)
  and the **on-device 10-min zero-xrun run** (no device in CI) — same deferral class as the P4 CoreAudio
  on-device gate. The event-delivery *wiring* is proven through the public `Engine` API (`sendEvent` →
  render); the *device* bring-up is the hardware step.

## 6. What P14 needs (from plan Phase 14) + carried obligations
P14 = **OfflineBatch (Tier C): pipeline parallelism + data-parallel chunking** (`warmup_samples`,
bit-reproducible ordered merge, invariants O1–O3). Read first: plan §14; `pan_parallel_and_offline_
execution.md` §3 (Tier C); `catalog.md` §8.10/§11.1b (OfflineBatch + O1–O3); `pan_testing_and_vector_
contract.md` §5.7d (offline differential `K=1` ≡ `K=ncores`). `RingSampleMux` is the push transport
(interface present since P2; body to fill). The P13 `Transport` + `sendEvent` already make an offline
**MIDI-timeline bounce** expressible (events have a deterministic within-block offset; the offline loop
drains them) — a P14 O3-reproducibility test could cover an offline instrument render.

**Carried obligations / residuals (surfaced for whoever schedules them) — after the re-audit:**
- ~~File/streaming source~~ **CLOSED** — `io.PrefetchSource` ships (the streaming-FIFO source over a
  background prefetch thread). The actual disk/network *decode loop* that fills the ring is the
  app/HAL's (the block is the audio-thread-side wait-free consumer + the SR2 contract).
- ~~`ChannelMap`-over-composite functoriality test~~ **CLOSED** — `tests/channelmap_functoriality_test.zig`
  (F(g∘f)=F(g)∘F(f), F(id)=id, per-plane independence; bit-exact).
- **`Num`-generic / fixed-point oscillator + voice tier**; **multi-channel (planar) voices** (the audio
  oscillators + `SawVoice`/`PolyVoice` are f32 mono today — a deliberate quality/scope tier).
- **Live MIDI device HAL + on-device 10-min zero-xrun run** (hardware, deferred — see §5); **external
  transport sync** (MIDI clock / Ableton Link).
- Optional: a `bench/synth_bench.zig` (Vmax-bounded polyphony throughput under a stress voice load; the
  per-block voice-loop + event-drain are the costs worth measuring).
