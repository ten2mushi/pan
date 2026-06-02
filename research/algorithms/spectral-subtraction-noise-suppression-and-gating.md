# Spectral Subtraction, Noise Suppression, and Gating

## Abstract

Spectral subtraction estimates a noise spectrum during noise-only frames (identified by VAD or similar) and subtracts a scaled version from the current magnitude spectrum, followed by half-wave rectification, spectral floor, and gain application to reduce musical noise. For streaming embedded the noise estimate is a running average or recursive update (ballistic filter) on the magnitude or mel energies; the subtraction and gain are applied on-the-fly to the current STFT, CQT, or sparse SDFT frame without ever storing a full 2-D spectrogram. State is the noise estimate vector (K bins or mel bands) plus a few smoothing / hangover counters — typically a few hundred bytes to low KiB. Traffic is the underlying spectral traffic (already paid by MFCC, sparse features, etc.) plus O(K) per frame for the estimate update and gain computation. When fused with perceptual-sparse or MFCC paths the extra cost is negligible. Explicit gating (time-domain or spectral) can further save downstream traffic by killing or attenuating entire frames or bands when VAD says noise.

> **Provenance note.** Classic Boll spectral subtraction and improvements (Berouti over-subtraction + floor, Ephraim & Malah MMSE-style, musical-noise mitigation) were verified via search and standard DSP references during the 2026 remediation sweep. Embedded streaming forms and fusion with VAD/gating were cross-checked against the VAD, sparse-features, and dynamics notes. Traffic and state numbers labeled **[derived]** are calculated from band count K and the fact that the heavy spectral work is already required. Re-verified 2026-06.

Cross-references: [`../features/mel-frequency-cepstral-coefficients.md`](../features/mel-frequency-cepstral-coefficients.md), [`../features/perceptual-sparse-and-ultra-low-compute-features.md`](../features/perceptual-sparse-and-ultra-low-compute-features.md), [`../detection/vad-voice-activity-detection.md`](../detection/vad-voice-activity-detection.md), [`../transforms/short-time-fourier-transform.md`](../transforms/short-time-fourier-transform.md), [`../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md`](../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md), and [`../optimization/simd-vectorization-audio-dsp.md`](../optimization/simd-vectorization-audio-dsp.md).

---

## 1. Realization

During frames classified as noise-only (by VAD, energy, or harmonicity):

noise_est = alpha * noise_est + (1-alpha) * current_mag   # or mel energies

During all frames:

gain = max( floor, (current_mag - beta * noise_est) / (current_mag + eps) )

Y = gain * current_mag   # phase from original

Additional musical-noise mitigation: over-subtraction factor that depends on SNR estimate, temporal smoothing of the gain, or substitution of a spectrally shaped floor.

Gating: when VAD or a simple energy/harmonicity test says "noise", the whole frame (or individual bands) can be attenuated or zeroed before downstream stages see it.

---

## 2. Data Motion Analysis — Bytes Moved

**State [derived]:**

- Noise estimate vector: K bins or mel bands (e.g. 512 bins × 4 B ≈ 2 KiB, or 40 mel bands ≈ 160 B).
- Smoothing counters / hangover: a few words.
- Total: a few hundred bytes (mel/sparse) to low KiB (full bin).

**Traffic [derived]:**

- The magnitude spectrum is already being produced by the STFT/mel/sparse stage.
- Noise update and gain computation: O(K) loads/stores + arithmetic per frame.
- When the gain is applied while the current spectrum is still hot in L1/registers, the only extra DRAM traffic is writing the cleaned spectrum (or the reduced features) — which would have been written anyway.

Gating adds the ability to skip the write (or the downstream computation) entirely for noise frames, directly saving bytes moved.

---

## 3. State Machine / Dataflow

```mermaid
stateDiagram-v2
    [*] --> Spectrum: current |X| or mel/sparse energies hot
    Spectrum --> VAD: energy / harmonicity / ZCR decision
    VAD -->|noise-only| UpdateNoise: noise_est = alpha*noise_est + (1-alpha)*current
    VAD -->|speech| ComputeGain: gain = max(floor, (current - beta*noise_est) / current)
    ComputeGain --> Apply: Y = gain * current (phase preserved)
    Apply --> Gate: if VAD noise, attenuate or zero whole frame/bands
    Gate --> Features: cleaned mel / sparse / MFCC coefficients
    Features --> [*]
```

```mermaid
graph TD
    A[Current spectrum hot] --> B[VAD / noise decision]
    B --> C{Noise frame?}
    C -->|Yes| D[Update noise estimate (recursive or running avg)]
    C -->|No| E[Compute gain from current vs. noise_est]
    D --> F[Apply light gain or pass through]
    E --> G[Apply gain + spectral floor]
    G --> H[Optional: additional temporal smoothing of gain]
    H --> I[Explicit gate: zero or heavily attenuate if VAD says noise]
    I --> J[Output cleaned spectrum or features]
    J --> K[Downstream stages see less work on noise]
    K --> A
```

**Guidance (embedded real-time, min bytes moved):**

1. Use mel or sparse bands for the noise estimate (much lower dimension and state than full FFT bins).
2. Fuse the subtraction/gain stage directly into the same pass that computes mel/sparse features. The spectrum is touched once.
3. Use the VAD decision (or a dedicated noise gate) to skip or freeze downstream computation (MFCC, pitch, AEC adaptation, uplink) on noise frames — this is the largest traffic saving.
4. Apply musical-noise mitigation (over-subtraction that varies with estimated SNR, spectral floor, gain smoothing) so that the suppressor does not introduce artifacts that downstream stages then have to clean up.
5. **Never** update the noise estimate during speech (speech leaks into the estimate and the suppressor starts removing the desired signal); never apply aggressive subtraction without a floor or smoothing (musical noise); never run full downstream features when the gate says the frame is uninteresting.

---

## 4. Pseudocode — Reference Implementation

```pseudocode
# Per frame, after magnitude computation
if is_noise_frame(vad, energy, harm):
    noise_est = alpha * noise_est + (1-alpha) * current_mag
gain = max(floor, (current_mag - beta * noise_est) / (current_mag + eps))
clean = gain * current_mag
if vad == noise:
    clean = clean * global_gate   # or zero
# pass clean + original phase downstream
```

---

## 5. Hardware Optimizations & Fixed-Point Mapping

- Vector subtract, max, and multiply for the gain stage — perfect for NEON/Helium.
- Fixed-point: use saturating arithmetic and a small positive floor to avoid negative magnitudes or denormals.
- The noise vector and gain vector easily live alongside other spectral feature state in DTCM.

---

## 6. Elegant Wins and Curious Techniques

- A noise suppressor that rides on the same spectral magnitudes already being computed for features, with explicit gating that turns suppression into a traffic-saving stage rather than just another consumer.
- When combined with VAD and sparse features, the suppressor + gate can dramatically reduce the average work and memory traffic of the entire downstream pipeline.

## 7. References (Verified)

> **Corrections / verification note.** Classic Boll 1979 spectral subtraction, Berouti over-sub + floor, Ephraim-Malah, musical noise mitigations verified via web_search + standard DSP refs (e.g. "spectral subtraction Boll" "Berouti spectral subtraction") during 2026 sweep; embedded streaming + VAD gating cross-checked vs VAD/sparse-features notes (tool-grounded). Traffic **[derived]** from K bands + already-paid spectrum. Re-verified.

**Primary papers (verified)**
1. S. F. Boll. "Suppression of acoustic noise in speech using spectral subtraction." IEEE Trans. ASSP, 1979. (Classic spectral subtraction.)
2. M. Berouti et al. "Enhancement of speech corrupted by acoustic noise." ICASSP 1979. (Over-subtraction + spectral floor for musical noise.)
3. Y. Ephraim & D. Malah. "Speech enhancement using a minimum mean-square error short-time spectral amplitude estimator." IEEE TASSP 1984. (MMSE-style improvements.)
4. Related musical-noise mitigation literature (smoothing, SNR-dependent factors).

**Implementations & vendor**
5. WebRTC / Speex / embedded NS modules (spectral subtract + VAD gate patterns).
6. CMSIS-DSP + ARM audio examples for vectorized gain apply.

**Cross-referenced notes in this repository (as of writing)**
- [`../features/mel-frequency-cepstral-coefficients.md`](../features/mel-frequency-cepstral-coefficients.md)
- [`../features/perceptual-sparse-and-ultra-low-compute-features.md`](../features/perceptual-sparse-and-ultra-low-compute-features.md)
- [`../detection/vad-voice-activity-detection.md`](../detection/vad-voice-activity-detection.md)
- [`../transforms/short-time-fourier-transform.md`](../transforms/short-time-fourier-transform.md)
- [`../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md`](../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md)
- [`../optimization/simd-vectorization-audio-dsp.md`](../optimization/simd-vectorization-audio-dsp.md)
- [`../algorithms/simple-dereverberation-primitives.md`](../algorithms/simple-dereverberation-primitives.md) (shared subtraction/gating for reverb tail)
- [`../general/end-to-end-pipeline-budgets-and-worked-examples.md`](../general/end-to-end-pipeline-budgets-and-worked-examples.md)

All citations obtained/validated with search tools per §4; self-contained.

*End of note. Update INDEX.md and add bidirectional links when sibling notes are written.*

Last updated: 2026-06 (remediation + full refs + explicit provenance + bidir).