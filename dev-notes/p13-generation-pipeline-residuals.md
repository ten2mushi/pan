# P13 generation-pipeline residuals — independent audit findings

> **Provenance.** These items come from an **independent, adversarial audit** of Phase 13 (Sources,
> typed event lane, `NoteEvent`, `PolyVoice`, the Instrument slice), run by a separate agent that read
> the brief + `pan_implementation_plan.md` §13 + the cited specs and explored the code on its own,
> deliberately *not* trusting the implementer's "done & green" claim. Recorded here (2026-06-05) per the
> instruction to collect P13 items that are **uniquely in the generation (synthesis / Instrument)
> pipeline and not the feature-extraction (Analyzer) pipeline**. The auditor's classification was
> explicit: **every gap/defect below falls in the generation pipeline** (some also touch shared/core
> engine API); **nothing falls in the feature-extraction pipeline**, and feat.zig / FeatureCollectorSink
> are out of P13 scope entirely.
>
> **Status (updated 2026-06-05):** items **A, C, D are now FIXED** (see the ✅ markers below; full suite
> 1241/1241, four-mode green). Items **B and E** and the disclosed scope tiers remain open. Severities and
> suggested actions are the auditor's (cross-checked).

## Audit verdict (independent)

P13's vertical slice and all numeric/behavioural gates are **genuinely covered and green** — Source
generators (incl. PolyBLEP anti-aliasing vs a real in-test DFT oracle), `EventLane`/`NoteEvent`, fused +
replicated `PolyVoice`/`VoiceMap` (allocation, click-free stealing with a discriminating counter-example,
MPE routing, bit-exact sample-accurate onset), and the Instrument slice through the real runtime `Engine`.
**No hard correctness defect** (no UAF / data race / OOB / overflow). All seven gates exit 0:
`zig build test` (Debug / ReleaseSafe / ReleaseFast), `smoke`, `neg-compile`, `cross-linux`, `fmt-check`.

But P13 is **not fully closed against the plan as written**: two plan line-items are absent (the
Phase-13 **benchmark**, and wiring the **Transport** into event scheduling). Both were disclosed as
"optional/deferred" in the P14 handoff, but the plan lists them as P13 items.

---

## A. ✅ RESOLVED — Transport ↔ event-dispatch is decoupled  ·  generation-pipeline (+ shared/core)

**Fixed 2026-06-05.** Added a second SPSC **timeline ring** (`Engine.timeline_ring`) + the verb
`engine.scheduleEventAt(node, abs_sample, event)` whose `at_sample` is an **absolute transport sample**.
Each block, `drainEvents` drains the live ring (within-block offsets) AND the timeline ring for the window
`[transport.position, position+block_size)` via `drainUntil`, converting each absolute timestamp to a
block-relative offset against the (per-render-advanced) transport position; the merged scratch is then
stably **offset-sorted**. So the transport timeline now drives the event lane (§9), and an offline render
of an absolutely-timed score is a pure function of the transport. Tests: `instrument_engine_test.zig`
("scheduleEventAt places an absolute-transport event in the right block", "live + timeline events merge
and sort within a block"). *Remaining (future):* event replay across a transport **seek/loop** (forward
playback only today); a long offline timeline beyond the ring capacity still wants the `MidiEventSource`
streaming feed.

*Original finding —* **Plan W2 / `pan_io_realtime_and_pipeline.md` §9.** `io.Transport` advances a sample-accurate position
(`seek`/`setLoop`/`setTempo`/`ppq`, deterministic `advance`) and is unit-tested, but **nothing converts a
transport-absolute event timestamp into the per-block `at_sample`** the lane consumes. `engine.sendEvent`
/ `EventCommand.at_sample` is a *within-block offset only*; there is no "schedule this `NoteEvent` at
transport position P" path that the per-block drain resolves against `transport.position`. So §9's "the
event lane timestamps against the transport position" and the "deterministic offline timeline" (render an
absolutely-timed `NoteEvent` score, bit-reproducibly) are **only half-wired** — the transport exists, the
binding to the event lane does not.

**Suggested action:** add a transport-aware scheduling path — e.g. `scheduleEventAt(node, abs_sample,
event)` that the per-block drain converts to `at_sample = abs_sample − block_start` (dropping/holding
events outside `[position, position+N)`), or a `MidiEventSource` mode that emits its buffered timeline
relative to `transport.position` each block. This also unlocks the P14 offline O3-reproducible MIDI bounce
cleanly.

## B. Open line-item — the Phase-13 benchmark is entirely missing  ·  generation-pipeline

**Plan §13 Benchmark line.** No `bench/synth_bench.zig`; no voice-pool **footprint baseline** in
`bench/baselines/`; the **zero-xrun-over-10-min** target is not captured as a tracked number anywhere. The
P14 handoff lists the bench only as "Optional."

**Suggested action:** add `bench/synth_bench.zig` — `Vmax`-bounded polyphony throughput under a **stress**
voice load (all `Vmax` sounding; deep event lanes), the voice-pool footprint as a `Vmax`-comptime constant
committed to `bench/baselines/`, and the per-`renderInto` headroom vs the `N/Fs` deadline as the proxy for
the 10-min-xrun target (the on-device 10-min run stays hardware-deferred, but the per-block headroom number
is measurable on M3 now). The benches measure (never assert an oracle), per §0.9.

---

## C. ✅ RESOLVED — duplicate `note_id` fans out to all matching slots  ·  generation-pipeline

**Fixed 2026-06-05.** `PolyVoice` now routes `note_off`/`pressure`/`expression` through a new
`findOwningSlot(note_id)` that returns the **single** owning slot (the most-recently-allocated active
match), so a duplicate `note_id` can never release or modulate an unrelated voice. Documented the
"`note_id` unique among sounding voices" MPE precondition on the helper. Test: `synth.zig` "a note_off
routes to ONE owning slot, not all duplicate note_ids".

*Original finding —* `src/synth.zig` `applyEvent` (`note_off` / `pressure` / `expression`) loops **all** voices and applies to
every slot whose `note_ids[i]` matches — so two simultaneous notes that share a `note_id` are both
released/modulated by a single targeted event. Spec EV2/Y5 says route to *the exact owning voice*.
Severity **low**: relies on the (reasonable, MPE-standard) invariant that a sounding `note_id` is unique;
the code neither documents that assumption nor enforces it.

**Suggested action:** either document the "one sounding voice per `note_id`" precondition on `PolyVoice`,
or route to the single most-recently-allocated matching slot (break after the first hit). Repro: two
`note_on{note_id=1}` into a 2-slot pool, one `note_off{note_id=1}` → both go idle.

## D. ✅ RESOLVED — out-of-order events + a misleading "sorted" comment  ·  generation (+ shared/core)

**Fixed 2026-06-05.** The per-block merge now **stably sorts the drained events by offset**
(`std.sort.insertion` + `lessByOffset`, bounded ≤ `max_events_per_block`, in-place, no allocation), so an
out-of-order live producer no longer silently mis-renders — the sub-block split always sees a correctly
time-ordered lane. The previously-misleading "drained-and-sorted" / "time-sorted" doc-comments are now
**accurate** (a sort really happens) and were reworded to say so; the `EvtCollector`/`EventDispatch` docs
now state the live ring need not be enqueued in order (only the timeline ring's window drain relies on
non-decreasing absolute order). Exercised by the A merge+sort test.

*Original finding —* The sub-block split (`synth.zig` `PolyVoice.process`) and the engine drain assume the producer enqueues
events in **non-decreasing `at_sample`** order — the cursor is monotonic (`if (off > cursor)`), so an
out-of-order event is placed without its leading segment (wrong onset). This is a *documented producer
obligation* (the same contract as the `schedule` command ring), so it is acceptable — **but it is
unchecked**, and two doc-comments overstate it: `engine.zig:936` ("drained-**and-sorted** event commands")
and `engine.zig:1102` ("the drained, **time-sorted** events") imply an active sort that does not happen
(only `engine.zig:952` correctly states "no sort on the audio thread"). Misleading, not wrong behaviour.

**Suggested action (quick):** reword the two comments to "drained, **producer-ordered** (non-decreasing
`at_sample`)" so the source doesn't claim a sort it doesn't do; optionally add a debug-only assertion that
`at_sample` is non-decreasing across the drained block (fail-loud on a misbehaving producer).

## E. Test-methodology deviation — §5.7h "dual-mux" realised as whole-vs-split  ·  generation-pipeline

`pan_testing_and_vector_contract.md` §5.7h literally specifies the **dual-mux** pair (`TestSampleMux` vs
`PullTestSampleMux`) over the same event-driven render. `tests/polyvoice_behaviour_test.zig` instead pins
the **whole-block ≡ hand-split-and-concatenate** (state-granularity, §5.6) bit-exact equivalence. Defensible
— `PolyVoice` is a zero-sample-input Source, so it has no sample-input edge to push/pull, and the engine
callback (push) path is covered separately in `instrument_engine_test.zig` — but it is a literal deviation
from the §5.7h wording worth noting.

---

## Disclosed scope tiers (NOT gaps — recorded for completeness)  ·  generation-pipeline

- **f32-mono only.** The audio oscillators (`gen.Sine`/`PolyBlepSaw`/…) and `SawVoice`/`PolyVoice` are
  concrete `Sample(f32)`, not `Num`-generic (the `pan_developer_experience.md` §6b example shows an
  illustrative `SawVoice(comptime Num)`; the example is explicitly illustrative, so this is a quality/scope
  tier, not a gate miss). A `Num`-generic / fixed-point + **multi-channel (planar)** voice tier is future.
- **Voice-stealing = in-place retrigger** (envelope/phase/filter continuous) rather than the spec's
  *illustrative* "release-ramp the stolen voice." Both are click-free; Y3 (click-free) is met. Design
  choice, disclosed (Rule 7).
- **Hardware-deferred:** live MIDI device HAL input and the on-device 10-min zero-xrun run (no device in
  CI — same class as the P4 CoreAudio on-device gate); **external transport sync** (MIDI clock / Ableton
  Link).

---

## Classification summary

| Item | Pipeline | Status |
|---|---|---|
| A — Transport↔event dispatch | generation (+ shared/core engine API) | ✅ fixed 2026-06-05 |
| B — missing synth benchmark | generation | open |
| C — duplicate note_id routing | generation | ✅ fixed 2026-06-05 |
| D — out-of-order events + "sorted" comments | generation (comment in shared/core engine.zig) | ✅ fixed 2026-06-05 |
| E — §5.7h dual-mux literal deviation | generation (test methodology) | open (defensible) |
| f32-mono / steal-strategy / hardware tiers | generation (disclosed tiers) | open (scope/hardware) |

**No item is in the feature-extraction (Analyzer) pipeline.** This is why they are collected here as a
self-contained generation-pipeline residual set.
