# pan — Session Bundling (how to batch the implementation-plan phases)

> **Status:** advisory companion to [`../pan_implementation_plan.md`](../pan_implementation_plan.md).
> It does **not** change the plan's phases, gates, or spec citations — it only recommends how to batch
> them into working sessions. The plan and the `specifications/` corpus remain the source of truth.
> **Date:** 2026-06-03.

## Governing constraints

- **Token budget (project Rule 6):** ≈120,000 tokens per session, 40,000 per task. So **never pair two
  heavy (L/XL) phases**; bundle two M phases, or M+S.
- **End on green:** every session must finish on a compilable, gated, tested state (the plan's
  per-phase success criterion).
- **Fan out wide buildout:** *wide-not-deep* phases (many independent blocks) are better dispatched as
  a **subagent fleet** (one block ≈ one gold-vector + dual-mux task) than crammed into one linear
  session.

## Phase weight (the input to bundling)

| Weight | Phases |
|---|---|
| **S–M** (pairable) | P0, P1, P11, P17-scripts |
| **M–L** (pair only with an S) | P2, P6, P10, P17 |
| **L** (usually solo) | P5, P7, P8, P9, P12, P14, P18 |
| **XL** (solo, sometimes split) | P3, P4, P13, P15, P16, P19 |

## Recommended session map

| Session | Phases | Mode | Gate (finish-on-green) |
|---|---|---|---|
| 1 | **P0 + P1** | bundle | green `zig build` + comptime classifier/PortId/layout-identity tests + freestanding `ReleaseSmall` compiles |
| 2 | **P2** (+ optional `scripts/` decoders) | solo | mux + 6 harness drivers + `generate.py` run green on the passthrough block; generator determinism |
| 3 | **P3** | solo (XL) | worked examples B/C reproduce; smoke gate compiles at comptime |
| 4 | **P4** | solo (XL; split 4a/4b if budget bites) | roadmap step 1: sub-5 ms, zero xruns 10 min, oracle match, B≡C, Linux ALSA cross-compiles |
| 5 | **P5 + P11** | bundle (reorder P11 forward) | param edge ≡ `set`, zipper-free; ThreadSanitizer-clean SPSC/RCU |
| 6 | **P6 + P7** | bundle | memory model done + B≡C green; `error.DelayFreeLoop`; reverb tail stable |
| 7 | **P8** | solo (L) | dry/wet diamond re-aligns (PDC); dual-mux + latency-contract pass |
| 8 | **P9** | solo (L; fan out feature chains) | per-hop feature matrix collected with no audio-deadline impact; `Concat` named-wiring; RT-root collector = commit error |
| 9 | **P10** | solo (M–L) | freestanding q15 chain bit-exact; footprint comptime constant; render inlines |
| 10 | **P12** | solo (L) | out:in ∈ `[min,max]`; delay ≤ `max_latency`; determinism split honored |
| 11 | **P13** | solo (XL; fan out oscillators/voices) | roadmap step 6d: `Vmax`-bounded polyphony, sample-accurate onsets, click-free stealing |
| 12 | **P14** | solo (L) | file→file bit-identical to Tier A; `K=ncores`≡`K=1` (exact/allclose); chunk-without-warmup = commit error |
| 13 | **P15** | solo (XL; internally 2 stages) | parallel≡sequential bit-exact; cost-gate refuses near-linear chain; auto-demote triggers |
| — | **P16** | **fan out** (subagent fleet) | per-block gold-vector + dual-mux; layout negotiation (registered matrix / codec round-trip / unregistered-pair rejection) |
| 14 | **P17** | solo (M–L; lighter if decoders moved to S2) | decoders vs independent oracle (`scipy.io.wavfile`); Analyzer example drives the viz; Instrument bounce |
| 15 | **P18** ⚠️ | bundle (beyond-spec) | fused≡unfused bit-identical; subgraph-combinator≡fused-kernel — **spec amendment first** |
| 16 | **P19** ⚠️ | **split by artifact** (beyond-spec) | MCU on-device q15 bit-exact; property harness; TLA+ checks; Lean coloring proof; Flocq biquad bound — **spec amendment first** |

## The three high-leverage bundles (rationale)

**Session 1 — P0 + P1 ("Foundations").** Tightly coupled: the pinned `src/root.zig` surface (P0)
*references* the `Numeric` / `ChannelLayout` / element / `PortId` / classifier machinery (P1). Splitting
them means stubbing the types twice. Both are compile-only / comptime, moderate scope. Ends green.

**Session 5 — P5 + P11 (control plane + its consuming blocks; small reorder).** P5 builds the
parameter-port machinery + the three control verbs; P11 builds the modulation *blocks* (LFO, ADSR,
feature→param, data-gating) that consume it. **P11 has no dependency on P10/embedded**, so pulling it
forward next to P5 is safe and yields one stronger roadmap-step-6c gate (param edge ≡ `set`,
zipper-free) instead of two thin ones. (This is the one deliberate reorder vs the plan's phase numbers.)

**Session 6 — P6 + P7 (the memory model, finished).** The two halves of commitment C3: P6 adds the
*persistent / pool-excluded* category (delay lines, history, fused tight-feedback kernels); P7 colors
the *non-persistent* edges. They share `commit.zig` liveness, the footprint formula, and the **B≡C
differential harness** — so they land one coherent "memory model done + B≡C green" gate. Roadmap steps
3 and 4 are adjacent.

## Immovable solos (do NOT bundle)

- **P3** commit pass — XL, the algorithmic centerpiece.
- **P4** vertical slice — XL + external CoreAudio dependency; *split* at the I/O seam (4a
  engine+token+blocks+vectors / 4b CoreAudio+Linux ALSA+LPCM codecs) before bundling with anything.
- **P13** Instrument slice — XL, many new constructs (sources, event lane, NoteEvent, PolyVoice).
- **P15** Tier B — XL, concurrency-critical; internally two stages (workgroup HAL + level-barrier
  fallback → then HEFT + point-to-point + cost-gate + auto-demote).

## Parallelize, don't bundle (subagent fan-out)

These are *wide, not deep* — serializing them wastes the natural parallelism:

- **P9 feature chains** — MFCC, centroid, flux, dominant-band, RMS, perceptual-sparse, onset are
  independent gold-vector blocks. Build the framework in the session, fan out the blocks.
- **P16 entire library** — the full block taxonomy + spatial core + layout matrices. A workflow /
  parallel dispatch (one block ≈ one gold-vector + dual-mux task) beats any linear session; keep
  layout-negotiation as its own gate.
- **P13 oscillators/voices** — once the event-lane + PolyVoice framework compiles, the individual
  generators fan out.

## Movable unit

- **`scripts/` audio-format → LPCM decoders** (part of P17) use the same scripts/decoder muscle as
  `generate.py` (P2) and have no hard dependency on the late game — they can ride with **Session 2**,
  shrinking P17 to just the Python viz + the Instrument bounce example. (Gold vectors are synthetic via
  `generate.py`, so the decoders aren't on the critical path until you want to ingest real audio files.)

## Net effect

The 20 phases collapse to roughly **13 implementation sessions** + **2 fan-out campaigns** (P9 feature
chains, P16 library) + the beyond-spec tail (P18 one session; P19 split by artifact). The three
high-leverage bundles are **P0+P1**, **P5+P11**, **P6+P7**; the immovable solos are **P3, P4, P13,
P15**; the two phases to *parallelize rather than bundle* are **P9's feature chains** and **P16**.

> **Discipline reminder (carried from the plan §0):** every session loads the `zig-0-16` skill (Rule
> 13), ends on its plan-defined gate, dispatches Yoneda test-writers at that gate (Rule 14, code-section
> not tests), and keeps in-code documentation self-contained (no `specifications/*.md` references from
> `src/`). The P5+P11 reorder is the only deviation from the plan's phase ordering; all gates and spec
> citations are unchanged.
