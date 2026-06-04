# TimeStretch: WSOLA vs. phase-vocoder — why we shipped WSOLA, and what it implies

> Context: P12 (`VariRate` family). `spectral.TimeStretch` realises runtime tempo
> change without pitch change; `spectral.PitchShift` composes it (TSM ∘ resample).
> The implementation plan §12 named the method "TSM / **phase-vocoder** (… the
> variable **synthesis** hop is the VariRate seam)". We shipped **WSOLA**
> (waveform-similarity overlap-add) instead. This note records why that is
> contract-complete, where the two methods diverge, and the implications to watch.

## 1. The spec named a *method*; the gate tests a *contract*

The §5.7f gate for a `VariRate` never asks "is this a phase vocoder." It tests the
**contract**: `out:in ∈ [min,max]`, `needed_input` sound & monotone, impulse delay
≤ `max_latency`, and the determinism class (parameter-driven O3-reproducible vs
controller-driven ≈). Pitch-preservation is the *defining* property of any
time-scale modification, and WSOLA delivers it (verified empirically: a 1 kHz tone
stays ~1 kHz across stretch ∈ {0.5,1,1.5,2} while duration tracks the factor; steady
RMS ≈ 0.707).

This is the **⊢ vs ≈ split** working as designed: the decidable contract (⊢ —
`rate_bounds`/`max_latency`/`needed_input`/determinism class, enforced by
`port.classify` + the commit pass + the gate) is fully decoupled from the empirical
DSP fidelity (≈ — the algorithm). **WSOLA-vs-vocoder is a ≈-tier choice that never
touches the ⊢ contract.** Consequence: a phase-vocoder `TimeStretch` could drop in
later with zero changes to the graph, the commit pass, or the gate.

## 2. The load-bearing lesson that got us here

The *first* revision of `TimeStretch` was a **naive overlap-add** (no grain
alignment). It was caught by the autonomous Yoneda gate: a plain OLA does **not**
time-stretch — the grain-boundary phase jumps scale the frequency by `1/stretch`,
so it behaves as a **resampler** (pitch changes, which is wrong), and `PitchShift`
(TSM ∘ resample) then cancelled it to a no-op.

**Lesson:** a "naive OLA tier" for time-stretch is not a lower-fidelity tier — it is
*incorrect*. Pitch preservation **requires** either waveform alignment (WSOLA) or
frequency-domain phase propagation (a phase vocoder). There is no correct OLA that
skips both.

## 3. The two methods are duals that meet the same contract — but fail differently

| Axis | WSOLA (shipped) | Phase vocoder (the named alternative) |
|---|---|---|
| Domain | Time-domain; no FFT | Frequency-domain; FFT per frame |
| The variable-rate seam | **Analysis** hop `Sa = HS/stretch`; fixed 50%-Hann (COLA-exact) **synthesis** grid | **Synthesis** hop varies (the spec's literal framing); fixed analysis hop |
| Monophonic / percussive | Excellent (locks to the period) | Good, but phase-smears transients without peak-locking |
| **Polyphonic / dense spectra** | **Limited** — no single period to lock to ⇒ smearing / period-doubling | Better (per-bin phase coherence), at the cost of "phasiness" / reverberant smear |
| Cost | `O(FRAME·Δ)` cross-correlation search per grain | `O(FRAME log FRAME)` FFT + per-bin phase bookkeeping |
| Embedded / fixed-point | Friendlier (no FFT, no transcendentals beyond the window) | Needs the FFT and per-bin trig |
| Determinism under reassociation | **Brittle** — see §4 | Graceful (smooth arithmetic) |

## 4. The subtle determinism implication (watch this for Phase 14)

Both methods are deterministic and parameter-driven, so V4's "O3-reproducible" holds
**under bit-identical arithmetic** — which is what our gold and chunked-≡-whole tests
run, so they are bit-exact today.

But WSOLA's core is an **argmax over a cross-correlation search**. A *near-tie* in
that search can **flip the chosen grain offset** under a different rounding (f32 vs
f64, FMA contraction, SIMD reassociation). A flipped offset is a **large, structural
output divergence**, not a 1-ULP wobble. A phase vocoder, being smooth arithmetic,
degrades gracefully (small ULP diffs).

Implication: if Phase 14 parallelises / re-associates this kernel (ReleaseFast SIMD,
multi-threaded chunking), WSOLA's bit-exactness is more fragile than a vocoder's
would be. (Both are also *causal* — each grain depends on the previous accepted
state — so neither is trivially splittable across output ranges without re-running
the recurrence; that's orthogonal to the argmax fragility.)

## 5. Honesty obligations (why the labels matter)

The `src/` doc-comments call it **WSOLA explicitly** and frame the phase-vocoder as
an interchangeable fidelity variant (the §0.2 self-contained-comment rule). This is
load-bearing: someone debugging polyphonic smearing must know it's WSOLA, or they'll
hunt for phase-unwrapping / bin-leakage bugs that don't exist. `PitchShift` inherits
this ceiling (it composes `TimeStretch`), and adds its own un-anti-aliased imaging
from the linear resample stage — both facts a reader needs.

## 6. The swap path (if a future phase needs it)

Reach for a phase-vocoder `TimeStretch` when: (a) polyphonic-stretch fidelity is
required, (b) you want the spec's literal variable-synthesis-hop topology so it
composes with the existing `Stft`/`iStft` Rate blocks, or (c) you need the
graceful-degradation determinism story for aggressive parallelisation. The inter
change is clean precisely because the contract is decoupled from the algorithm —
same `VariRate` declarations, same gate, same `PitchShift` composition. It is a
≈-tier fidelity upgrade, not a carried defect.
