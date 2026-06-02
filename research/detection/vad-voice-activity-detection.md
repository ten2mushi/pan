# Voice Activity Detection (VAD)

## Abstract

A real-time voice activity detector decides, on a per-sample or per-block basis, whether the incoming audio contains speech (or other desired signal) versus noise/silence. The classic low-state combination — short-term energy, zero-crossing rate (ZCR) with hysteresis, spectral flux or high-frequency content, and harmonicity (from SDFT or Goertzel bins) — feeds a statistical likelihood ratio test or a simple rule-based state machine with hangover and adaptive threshold. Total extra state is typically < 100 bytes (a few smoothed energies, counters, and recent harmonicity/flux scalars). Because the required features are already being computed for pitch, dominant-frequency, and sparse perceptual features, the incremental traffic for VAD is essentially zero when the front-end is already running. The single most valuable property for byte-displacement minimization is that the VAD output can explicitly gate downstream processing (MFCC computation, detailed pitch tracking, AEC adaptation, feature transmission) so that large amounts of work and memory traffic are simply not performed when there is nothing of interest to process.

> **Provenance note.** Energy + ZCR + harmonicity + LRT-style and hangover FSM VADs are standard in the literature (Sohn et al., Ramirez et al., ITU-T G.729 annex B and similar embedded standards). Integration with the sparse/SDFT features, ballistics, and explicit gating philosophy of this corpus was freshly verified during the 2026 remediation sweep via web_search "Sohn VAD" "Ramirez VAD LRT" "ITU G.729 VAD" + cross to SDFT/sparse/dynamics notes (tool-grounded). State/traffic **[derived]**. Re-verified.

Cross-references: [`../detection/real-time-pitch-estimation.md`](../detection/real-time-pitch-estimation.md), [`../features/perceptual-sparse-and-ultra-low-compute-features.md`](../features/perceptual-sparse-and-ultra-low-compute-features.md), [`../transforms/sliding-dft-and-recursive-spectrum-updates.md`](../transforms/sliding-dft-and-recursive-spectrum-updates.md), [`../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md`](../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md), [`../optimization/branchless-bit-twiddling-hacks-for-embedded-audio-dsp.md`](../optimization/branchless-bit-twiddling-hacks-for-embedded-audio-dsp.md), and [`../general/end-to-end-pipeline-budgets-and-worked-examples.md`](../general/end-to-end-pipeline-budgets-and-worked-examples.md).

---

## 1. Realization

A minimal embedded VAD typically maintains:

- Short-term energy (or RMS) with fast attack / slow release.
- ZCR computed with hysteresis (Schmitt-trigger style) to avoid chatter — easily made branchless.
- Harmonicity or spectral flatness from a small number of SDFT/Goertzel bins (already present for pitch or dominant tracking).
- A smoothed noise floor estimate updated only on frames classified as noise.
- A state machine with hangover (continue "speech" for a few frames after the raw decision drops) and an adaptive threshold that slowly tracks the noise floor.

The final decision is usually a combination of "energy above noise + (ZCR in speech range or harmonicity high)" plus temporal smoothing.

---

## 2. Data Motion Analysis — Bytes Moved

**Extra state [derived]:**

- 4–6 scalar values (smoothed energy, noise floor, ZCR accumulator, recent harmonicity, hangover counter, threshold).
- Total: well under 100 bytes even in float32.

**Per-sample or per-block traffic [derived]:**

- The energy, ZCR, and harmonicity numbers are produced as side-effects of stages that are already running (envelope followers, branchless ZCR from the bithacks note, SDFT/Goertzel for pitch or dominant frequency).
- Updating the noise floor and state machine: a few loads/stores and comparisons per decision point (often every 10–20 ms).
- Net incremental DRAM traffic when the rest of the front-end is active: effectively zero.

The real saving appears downstream: when VAD says "noise", the pipeline can skip or heavily decimate MFCC computation, detailed pitch, full AEC adaptation, feature transmission, etc. This directly reduces bytes moved through the memory hierarchy and through any radio or bus.

---

## 3. State Machine / Dataflow

```mermaid
stateDiagram-v2
    [*] --> ComputeFeatures: energy, branchless ZCR, harmonicity (from SDFT/Goertzel), flux
    ComputeFeatures --> UpdateStats: smooth energy; update noise floor only on "noise" decisions
    UpdateStats --> Decide: likelihood or rule (energy > noise AND (ZCR speech-range OR harmonicity high))
    Decide --> Hangover: if speech, start/refresh hangover counter; else decrement
    Hangover --> Gate: output final VAD flag + "speech probability"
    Gate --> SkipOrRun: if noise, skip MFCC / detailed pitch / AEC update / feature send
    SkipOrRun --> ComputeFeatures
```

```mermaid
graph TD
    A[Per-sample or per-block features already hot] --> B[Update short-term energy + ZCR (branchless)]
    B --> C[Harmonicity from existing SDFT/Goertzel bins]
    C --> D[Update noise floor estimate (only on current noise decision)]
    D --> E{Combined test + hangover?}
    E -->|Speech| F[Set VAD=1; refresh hangover]
    E -->|Noise| G[Decrement hangover; VAD=0 after timeout]
    F --> H[Run full downstream (MFCC, pitch, AEC adaptation)]
    G --> I[Gate: skip or freeze expensive stages]
    H --> J[Output features + VAD flag]
    I --> J
    J --> A
```

**Guidance (embedded real-time, min bytes moved):**

1. Treat VAD as the traffic police, not just another feature consumer. Its primary value is the explicit gate it provides to everything else.
2. Compute energy, ZCR, and harmonicity as by-products of stages that are already mandatory (envelopes, branchless ZCR hacks, SDFT for pitch/dominant). Do not add a second analysis pass.
3. Use a proper hangover (typically 200–500 ms) so that the ends of utterances are not clipped and so that downstream stages do not thrash on and off.
4. Update the noise floor only on frames the current decision (plus hangover) classifies as noise; otherwise speech leaks into the noise estimate and raises the threshold.
5. **Never:** (a) run full MFCC or detailed pitch or AEC adaptation when VAD is solidly noise; (b) forget to make ZCR branchless (the bithacks note has the mask technique); (c) use a fixed threshold without long-term adaptation on battery-powered devices; (d) let the tiny VAD state live anywhere except the hottest memory.

---

## 4. Pseudocode — Reference Implementation

```pseudocode
# Fused with existing per-sample / per-block work
energy = update_energy(x)
zcr = branchless_zcr(x, prev_x, hysteresis)
harm = harmonicity_from_sdft_bins(...)   # already computed for pitch

noise_floor = if (prev_vad == noise) then alpha*noise_floor + (1-alpha)*energy else noise_floor

speech = (energy > noise_floor * thresh) and ( (zcr in [low,high]) or (harm > h_thresh) )

hangover = if speech then max_hangover else max(0, hangover-1)
final_vad = (speech or hangover > 0)

if not final_vad:
    skip_mfcc()
    skip_detailed_pitch()
    freeze_aec_adaptation()
```

---

## 5. Hardware Optimizations & Fixed-Point Mapping

- All the scalar state fits in a handful of registers or a single cache line.
- Branchless ZCR and comparisons are friendly to in-order cores and deterministic WCET.
- The decision can be made every few milliseconds; the per-sample work is just the energy and ZCR updates (already required for other features).

---

## 6. Elegant Wins and Curious Techniques

- A 50-byte VAD can save megabytes per minute of memory traffic and radio bandwidth simply by turning other things off.
- Because it re-uses the exact same sparse harmonicity and envelope machinery already present for pitch and dynamics, adding robust VAD often costs almost nothing in the steady state.

## 7. References (Verified)

> **Corrections / verification note.** Sohn 1999 statistical VAD, Ramirez LRT VAD, ITU-T G.729B VAD, embedded standards verified via web_search during 2026; integration with SDFT/sparse gating from corpus notes (tool-verified). [derived] <100 B state. Re-verif pass.

**Primary papers**
1. J. Sohn, N.S. Kim, W. Sung. "A statistical model-based voice activity detection." IEEE Signal Processing Letters, 1999. (LRT VAD.)
2. J. Ramirez et al. "Efficient voice activity detection algorithms using long-term speech information." Speech Comm. 2004. (LRT improvements.)
3. ITU-T G.729 Annex B. "A silence compression scheme for G.729 optimized for terminals conforming to Recommendation V.70." (Embedded VAD standard with hangover/energy/ZCR/harmonicity.)
4. Related (e.g. ETSI AMR VAD).

**Cross-referenced notes**
- [`../detection/real-time-pitch-estimation.md`](../detection/real-time-pitch-estimation.md)
- [`../features/perceptual-sparse-and-ultra-low-compute-features.md`](../features/perceptual-sparse-and-ultra-low-compute-features.md)
- [`../transforms/sliding-dft-and-recursive-spectrum-updates.md`](../transforms/sliding-dft-and-recursive-spectrum-updates.md)
- [`../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md`](../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md)
- [`../optimization/branchless-bit-twiddling-hacks-for-embedded-audio-dsp.md`](../optimization/branchless-bit-twiddling-hacks-for-embedded-audio-dsp.md)
- [`../general/end-to-end-pipeline-budgets-and-worked-examples.md`](../general/end-to-end-pipeline-budgets-and-worked-examples.md)
- [`../transforms/short-time-fourier-transform.md`](../transforms/short-time-fourier-transform.md)
- [`../algorithms/spectral-subtraction-noise-suppression-and-gating.md`](../algorithms/spectral-subtraction-noise-suppression-and-gating.md) (VAD drives gate)

*End of note. Update INDEX.md and add bidirectional links when sibling notes are written.*

Last updated: 2026-06 (remediation + explicit searches + full refs 8+ + bidir).