# Numerical Considerations for Fixed-Point and Floating-Point Audio DSP

## Abstract

Audio algorithms intended for embedded targets must survive coefficient quantization, limited dynamic range, rounding modes, and the absence of full IEEE-754 support on many MCUs and DSPs. This note derives the numerical pathologies that appear in IIR filters (limit cycles, overflow oscillation), FFT scaling and twiddle quantization, fixed-point STFT / MFCC pipelines, and the phase-preservation requirements of overlap-add reconstruction. It provides concrete recipes for Q-format selection, block-floating scaling, convergent rounding, and the arithmetic intensity / precision trade-offs that directly affect memory traffic (wider types move more bytes; double-buffering strategies change when you can afford float32 vs. int16). All recommendations are grounded in the requirement that the implementation remain deterministic and that the memory-hierarchy optimizations described in the companion note remain valid.

Cross-references: [`./memory-hierarchy-minimization-for-real-time-dsp.md`](./memory-hierarchy-minimization-for-real-time-dsp.md), [`../transforms/discrete-fourier-transform.md`](../transforms/discrete-fourier-transform.md), [`../transforms/short-time-fourier-transform.md`](../transforms/short-time-fourier-transform.md), [`../transforms/integer-lapped-transforms-intmdct-and-lifting.md`](../transforms/integer-lapped-transforms-intmdct-and-lifting.md) (rounding consistency for PR in lifting, dyadic approx, Q scaling through rotations), [`../transforms/sliding-dft-and-recursive-spectrum-updates.md`](../transforms/sliding-dft-and-recursive-spectrum-updates.md) (fixed-point stability, LSB fix, oSDFT error behavior identical to FFT), [`../features/mel-frequency-cepstral-coefficients.md`](../features/mel-frequency-cepstral-coefficients.md), [`../optimization/fast-approximations-lut-cordic-minimax-and-clz-for-embedded-audio-features.md`](../optimization/fast-approximations-lut-cordic-minimax-and-clz-for-embedded-audio-features.md), [`../data_structures/audio-rings-fractional-delays-and-sparse-representations.md`](../data_structures/audio-rings-fractional-delays-and-sparse-representations.md).

> **Provenance.** Formulas for limit-cycle bounds, scaling, and quantization noise are standard (Oppenheim & Schafer, Jackson, Mullis & Roberts) and re-derived here for the embedded context. Concrete bit-exact behaviors are verified against CMSIS-DSP and common DSP compiler documentation.

---

## 1. Fixed-Point Formats Used in Audio

The dominant formats on embedded audio silicon:

- **Q15 / int16**: 1 sign bit + 15 fractional. Range ≈ [−1, 1). Most common for 16-bit ADC/DAC codecs. One sample = 2 bytes.
- **Q31 / int32**: 1 + 31 fractional. Range [−1, 1). Workhorse for accumulators and filter state on Cortex-M4/M7 (DSP extension has 32×32→64 MAC in one cycle).
- **Q7 / int8**: rare for signal paths (too little headroom) but appears in tinyML weights or packed tables.
- **Block floating point**: an exponent shared by a block of samples or FFT bins; mantissas stay in Q15/Q31. Used in many commercial FFT libraries (including older TI DSPLIB and some CMSIS paths) to extract near-float dynamic range while keeping 16-bit data movement.

**Traffic implication [derived].** Moving from int16 to float32 doubles the bytes per sample (2 B → 4 B). For an STFT buffer of N=512 complex, int16 complex is 2 KiB; float32 complex is 4 KiB. The difference is often decisive for fitting in DTCM. Hence the persistent preference for fixed-point or block-floating pipelines on the smallest MCUs even when the core could execute float.

---

## 2. IIR Filters: Limit Cycles and Overflow

A direct-form II biquad in fixed-point is a classic source of **zero-input limit cycles** (small oscillations that persist after the input has gone to zero) and **overflow oscillations** (large-amplitude, often square-wave, behavior when an adder wraps).

### 2.1 Limit cycles (granular)

After the input is removed, the two state variables (w1, w2 in DF-II) are updated by

w1(n) = −a1·w(n) + w2(n)   (in Q format)
...

Because multiplication by a quantized coefficient a1 followed by rounding is a **nonlinear** operation, the only fixed point of the autonomous system may be a small periodic orbit rather than (0,0).

**Bound.** For a second-order section with poles inside the unit circle, the maximum limit-cycle amplitude is on the order of the quantization step (2^{-b} for b fractional bits) divided by (1−|p|), where p is the dominant pole radius. In practice for audio coefficients (typical |p| < 0.99 for low-frequency shelving or resonator), a Q15 state can sustain a limit cycle of several LSBs — audible as a low-level tone or "idle channel noise" that does not decay.

**Mitigations (in order of preference for embedded):**

- Use **double-length accumulation** (Q31 state updated with 64-bit MAC, then rounded once to Q15/Q31 at the end of the section). CMSIS-DSP `arm_biquad_cascade_df1_q31` etc. document their internal widths.
- **Lattice or normalized ladder structures** — inherently lower sensitivity; state variables have bounded energy.
- **Random rounding** or dithered rounding (adds 1 LSB noise, breaks the deterministic cycle).
- **Coupled-form** (state-space rotation) for complex-conjugate poles — the rotation matrix can be implemented with only shifts + adds in some cases, eliminating the multiplier that creates the nonlinearity.

### 2.2 Overflow oscillation

When two's-complement wrap-around occurs inside a feedback loop, a large stable oscillation at Nyquist or at the pole angle can be entered from a transient overload and never leave, even after the input returns to normal range.

**Prevention:**

- **Saturation arithmetic** on every adder that feeds a state variable (the `SSAT` instruction on ARM, `saturate` intrinsics). This turns potential wrap into clipping, which is stable.
- **Headroom scaling**: keep filter coefficients and signals scaled so that the worst-case gain through the section (||H||_∞ or L2 norm of impulse response) leaves at least 1–2 guard bits. For a biquad this is usually a 2-bit shift before the recursive part.
- **DF-II transposed** is often preferred over DF-I for state-variable count (2 vs 4) but has different overflow characteristics; choose per filter.

---

## 3. FFT Scaling and Quantization

### 3.1 Twiddle factor quantization

A length-N radix-2 FFT requires N/2 distinct complex twiddles W^k = exp(−j2π k/N). In Q15 these are rounded to 16-bit real/imag. The error per twiddle is ≤ 2^{-16}/√2 in each component.

Error analysis (classic): each butterfly introduces a small perturbation that propagates through log N stages. The total noise power at the output is roughly (log N) × (quantization variance) × (signal power). For N=1024, log2 N = 10; the degradation is a few tenths of a dB in SNR for typical audio signals if twiddles are Q15 and data path uses Q15 with proper scaling.

**Practical rule.** Many embedded FFTs (CMSIS, KISS-FFT in fixed mode, TI) use **Q15 twiddles with Q15 or block-floating data**. The tables are 2×(N/2)×2 bytes = 2N bytes for N-point real FFT (half-size). For N=1024 this is 2 KiB — easily ROM-resident and cacheable.

### 3.2 Scaling strategies to avoid overflow

- **Unconditional scaling**: divide by 2 at each of the log N stages (right-shift or multiply by 0.5). Guarantees no overflow for full-scale input but costs log N bits of precision (≈ 3 dB per stage for N=1024 → 30 dB loss — unacceptable for 16-bit audio).
- **Block floating point**: after each stage or after the whole transform, compute the maximum magnitude in the array, determine a common exponent e, and shift the entire block left or right so that the largest value uses the full word width. Only the exponent travels with the block (or with each FFT bin if per-bin). Data movement is still 16-bit; dynamic range approaches float32 for the mantissa width.
- **Per-butterfly or "convergent" scaling**: scale only when a value would overflow on the next operation. Requires extra compares and conditional shifts; branchy and bad for SIMD. Rarely used in hot paths.
- **Floating-point FFT**: on cores with hardware float (Cortex-M4F/M7F, most A-series, RISC-V with F/D), simply use float32. The exponent gives 8 bits of extra range "for free"; rounding is to 24-bit mantissa. Cost: 2× data movement vs Q15, plus float units may have lower throughput than the DSP MAC on some M4/M7 parts.

CMSIS-DSP explicitly documents the scaling behavior of its `arm_cfft_q15`, `arm_rfft_fast_f32`, etc., and warns that some NEON variants are not in-place and require an extra temporary buffer (increasing peak memory traffic during the transform).

---

## 4. STFT / OLA Numerical Requirements

For perfect reconstruction (or near-perfect after modification) via overlap-add:

- The analysis and synthesis windows must satisfy the COLA condition in exact arithmetic.
- In fixed-point the window coefficients are quantized; the sum-over-laps therefore has a small ripple. For 50 % Hann in Q15 the ripple is usually << −80 dB — inaudible for most purposes — but must be verified for the exact Q format and hop.
- Phase must be preserved to within a fraction of a bin for clean ISTFT. This argues for keeping at least 16–20 bits through the complex FFT path when modification (pitch shift, time stretch, denoising) is performed. For pure analysis features (mel energies, flux) the phase can be discarded immediately after the magnitude, allowing a real-only or power-only FFT path that halves some of the data motion.

**Fused fixed-point STFT feature path (recommended for tiniest MCUs):**

1. Input ring in Q15 (or the native ADC width).
2. Apply window (Q15 × Q15 → Q31 MAC, round to Q15 or keep Q31 for this frame).
3. Real FFT or complex FFT on the windowed block, scaling chosen so largest bin uses full width (block float or static headroom).
4. Compute power (real^2 + imag^2) → Q31 or scaled.
5. Mel binning: weighted sum of powers into 26–40 accumulators (Q31). Only 40 values ever written to "RAM" for the frame.
6. Log (table lookup or polynomial in fixed-point) → Q15 or Q7 per mel band.
7. Optional small DCT (13–20 points) in Q15.
8. Deltas: simple (c[t] − c[t−2]) or regression over 3–5 frames; keep 1–2 previous cepstral vectors (tiny).

Total mutable state after the FFT buffer itself: a few hundred bytes. The FFT buffer can be overwritten by the power/mel stage in place if careful (real part only needed after mag^2).

---

## 5. MFCC-Specific Numerics

The mel filterbank weights are positive and sum (per band) to roughly 1.0 after normalization. In Q15 they can be stored with a per-band shift or as true fractions.

Log compression: the range of mel energies after a 16-bit or float32 FFT is large. A common embedded trick is **log2 via leading-zero count + mantissa table** (very cheap on ARM with CLZ), then convert to natural or base-10 log if the downstream (GMM, DNN) was trained on that. The error of a 256-entry log table is usually < 0.1 dB — negligible compared with the quantization of the filterbank itself.

DCT-II for cepstra: the matrix is fixed. A 13-point DCT can be implemented with 13×13/2 ≈ 85 multiplies or via a fast DCT (Chen, Loeffler) with far fewer. In Q15 the coefficient quantization is the dominant error; the transform is well-conditioned.

---

## 6. When to Use Float vs. Fixed — A Traffic-Aware Decision

| Criterion | Prefer float32 | Prefer Q15/Q31 + block float |
|-----------|----------------|------------------------------|
| Core has fast FPU + enough DTCM/L1 for 2× data | yes (simpler code, better dynamic range) | — |
| Must fit 4–8 channels + 1024-pt STFT + features in 32 KiB SRAM | — | yes (half the buffer sizes) |
| Phase vocoder or high-quality ISTFT with many modifications | yes (phase sensitivity) | only with heroic block-float tracking |
| Battery / always-on VAD + pitch front-end on Cortex-M0+/M3 (no FPU) | impossible | mandatory |
| TinyML accelerator expects int8/int16 features | — | yes (quantize at the end) |

In practice, a hybrid is common: the front-end (filters, STFT, mel) runs in the narrowest fixed-point format that meets SNR requirements; any subsequent DNN or statistics are done in float or in the accelerator's native format after a small conversion stage.

---

## 7. References and Further Reading

- Oppenheim, A. V. & Schafer, R. W. *Discrete-Time Signal Processing* (any edition) — chapters on quantization effects, FFT, filter structures.
- Jackson, L. B. (1970). "On the interaction of roundoff noise and dynamic range in digital filters." *Bell System Tech. J.*
- Mullis, C. T. & Roberts, R. A. (1976). "Synthesis of minimum roundoff noise fixed point digital filters." *IEEE Trans. Circuits Syst.*
- CMSIS-DSP source and documentation (explicit comments on internal word widths, scaling, and temporary buffer sizes for q15/q31/f32 variants).
- Manufacturer application notes on "fixed-point DSP programming" and "block floating point FFT".

Numerical verification (bit-exact limit cycle reproduction, SNR after quantized FFT, COLA ripple in Q15) should be part of any production validation suite for an embedded audio pipeline.

---

*Update this note whenever a new silicon generation changes the cost of float vs. integer (e.g., RISC-V cores with fast FP or new vector FP units).*
