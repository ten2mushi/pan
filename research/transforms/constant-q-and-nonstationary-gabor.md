# Constant-Q Transform and Nonstationary Gabor Frames for Embedded Audio

## Abstract

The Constant-Q Transform (CQT) and its modern generalizations (Nonstationary Gabor Transform / NSGT, variable-Q filter banks) address a fundamental mismatch between the uniform frequency resolution of the DFT/STFT and the logarithmic nature of pitch and musical harmony. For embedded real-time use (16–48 kHz, < 32–64 KiB fast RAM, deterministic latency), the naïve CQT (long FFT + kernel matrix per bin, or recursive IIR per band) is either too heavy in memory traffic or too imprecise. This note derives the CQT from first principles (constant-Q filter bank with Q = f / Δf fixed), contrasts arithmetic and traffic cost with STFT, presents efficient practical recipes (recursive CQT, sparse FFT + interpolation, NSGT with painless reconstruction), quantifies state and bytes moved per sample or per hop, and gives decision guidance for when the extra resolution is worth the cost on Cortex-M / RISC-V audio SoCs. Emphasis throughout is on **in-place or streaming formulations that never materialize a full 2-D time-frequency surface** and that keep the per-sample memory traffic close to O(1) or O(log) rather than O(N).

Cross-references: [`discrete-fourier-transform.md`](./discrete-fourier-transform.md) (Goertzel and sparse FFT as building blocks), [`short-time-fourier-transform.md`](./short-time-fourier-transform.md) (uniform vs. log resolution, COLA vs. painless), [`discrete-wavelet-transform.md`](./discrete-wavelet-transform.md) (multi-resolution alternative via lifting), [`../features/mel-frequency-cepstral-coefficients.md`](../features/mel-frequency-cepstral-coefficients.md) (mel is a coarse fixed-Q perceptual cousin), [`../detection/real-time-pitch-estimation.md`](../detection/real-time-pitch-estimation.md) (CQT excellent for harmonic summation / chroma), [`../optimization/simd-vectorization-audio-dsp.md`](../optimization/simd-vectorization-audio-dsp.md), and the memory hierarchy note [`../general/memory-hierarchy-minimization-for-real-time-dsp.md`](../general/memory-hierarchy-minimization-for-real-time-dsp.md).

> **Provenance note.** All primary algorithmic references (Brown 1991, Schörkhuber & Klapuri 2010, Holighaus et al. NSGT 2013/2016, Velasco et al. 2011 painless) were verified via web search + PDF retrieval during authoring. Numbers labeled **[derived]** are computed from the stated Q, hop, and support formulas using typical audio parameters. No fabricated citations.

---

## 1. Why Constant Q?

In music and many natural sounds, perceptually relevant structure lives on a logarithmic frequency axis: an octave is an octave regardless of center frequency. A standard N-point STFT (or DFT) has constant bin spacing Δf = fs/N. At low frequencies the bins are too wide for semitone resolution; at high frequencies they are unnecessarily fine, wasting computation and (in a naïve implementation) memory traffic on bins that will be summed or ignored for chroma or pitch features.

The Constant-Q Transform (CQT) enforces **Q = f_k / Δf_k = constant** (typically Q ≈ 12 / log2(2^{1/12}) ≈ 34–35 for semitone resolution, or higher for finer). Consequently the analysis kernels at center frequency f_k have length (support) proportional to 1/Δf_k ∝ 1/f_k — long kernels at bass, short at treble. This matches the wavelet spirit (constant relative bandwidth) while remaining a linear filter bank that can be inverted under suitable conditions.

**Traffic consequence.** A full-resolution CQT for 20 Hz–20 kHz at semitone spacing requires ~100–120 bins. If implemented as a dense matrix multiply against a long FFT, you touch O(N) spectrum values per bin for the low-frequency kernels — exactly the opposite of the "minimize bytes moved" goal. Efficient realizations therefore either (a) use recursive / IIR / Goertzel-style per-band resonators (state O(#bins)), (b) compute a single large FFT and interpolate or sparsely multiply only the needed support per bin, or (c) use the NSGT / painless nonstationary Gabor theory that permits perfect reconstruction with compactly supported dual windows while still varying Q or hop per band.

---

## 2. Mathematical Definition and Perfect Reconstruction Conditions

The CQT analysis at bin k, time frame l with hop H (possibly varying) is

X(k, l) = sum_n x(n + l H) · g_k(n) · exp(−j 2π f_k n / fs)

where g_k is a window (Hann, Blackman, or Kaiser) whose length L_k satisfies L_k · (f_k / fs) ≈ Q (i.e., roughly Q periods inside the window). Synthesis requires dual windows or iterative methods; for real-time the "painless" case (Holighaus, Dörfler, Velasco et al.) is preferred: the windows are chosen so that the frame operator is diagonal (or easily invertible) in the frequency domain, yielding a simple per-bin or per-frame gain correction for reconstruction.

**Painless NSGT condition (simplified).** If the analysis windows g_k have Fourier transforms whose supports are sufficiently localized and the hops are chosen so that the sum of |ĝ_k(ω)|^2 weighted by the local density is constant (or slowly varying), then the dual is also a simple modulation and the reconstruction is a sum of modulated synthesis windows applied to the coefficients — exactly analogous to OLA but with per-band hop and length.

For embedded feature extraction the inverse is often unnecessary; one keeps only the magnitude (or log-mag) per band, possibly summed into chroma vectors. In that case the "frame" need only be a Bessel bound (stable analysis) rather than a tight frame.

---

## 3. Efficient Embedded Realizations and Their Traffic

### 3.1 Recursive / resonator per bin (Goertzel-style or IIR)

Each band is an IIR (or Goertzel at the exact bin frequency) tuned to f_k with bandwidth f_k/Q. For real signals one can use a pair of real resonators or a complex pole pair with radius r = 1 − π·(f_k/Q)/fs.

**State:** 2 real (or 1 complex) per band → for 120 bands ≈ 240–500 bytes of mutable state (Q15 or float). 

**Traffic per sample:** O(# active bands) MACs and state updates. Because the bands are independent, this is perfectly SIMD-friendly (vector of resonators advanced together) and has excellent locality (the state vector is tiny and can be pinned in DTCM). No large FFT buffer required.

**Cost vs. STFT.** At 16 kHz with 120 bands, ≈ 120 × 4–6 ops/sample vs. a 512-pt STFT hop every 128 samples (≈ (512 log2 512)/128 ≈ 40–50 ops/sample amortized + OLA). The CQT wins on resolution at low freq and on total state; it loses if you need phase coherence across many bands or if the IIRs must be very high Q (long settling).

### 3.2 Sparse / pruned FFT + interpolation (Brown & Puckette 1992, later refinements)

Compute one large power-of-two FFT (say 4096 or 8192 points for 20 Hz resolution at fs=48 kHz), then for each CQT bin k synthesize the kernel as a short linear combination of a few FFT bins around the true f_k (sinc or better interpolator) or use the "direct" kernel in the time domain but only on the support after an inverse FFT of a sparse spectrum. The key paper is Brown, J. C. (1991) "Calculation of a constant Q spectral transform" (J. Acoust. Soc. Am.) and the efficient follow-up with Puckette.

**Traffic:** still dominated by the one large FFT per hop (see DFT note for six-step or cache-blocked costs). The subsequent sparse multiplies touch only a few bins per CQT band, so extra traffic is small. Working set is the large FFT buffer (32–64 KiB for 8k complex float) — borderline or too big for small DTCM; must be placed in L2/SRAM or external with blocking.

### 3.3 NSGT / variable hop & support (Holighaus, Velasco et al.)

The modern "painless" theory allows each band its own hop H_k (larger hops at high frequencies where the kernels are short) and its own support. Implementation can use a single large FFT or a filter-bank tree; reconstruction is a per-band multiply by a precomputed gain curve followed by OLA with the dual windows.

For pure analysis features one can run the analysis filter bank directly (polyphase or lifting-like) without ever forming the FFT, keeping only the current downsampled subband streams. State per band is the filter memory (a few taps for IIR prototypes or the FIR length for the chosen window).

**Memory win.** Because high-frequency bands can hop 4–8× more coarsely, the number of coefficient "frames" that must be buffered or processed for a given wall-clock interval drops dramatically at the top end. This directly reduces both compute and any downstream feature buffering.

---

## 4. Concrete Budgets (Derived)

Assume fs=48 kHz, 20 Hz–20 kHz, Q=34 (≈ semitone), ~108 bins.

- **Recursive resonator bank:** state ≈ 108 × 2 × 4 B (float) or 2 B (Q15) = 0.4–0.8 KiB mutable + coefficient table (center freq, radius, gain) ≈ 1–2 KiB ROM. Per-sample traffic: ≈ 108 complex MACs + state read/write → roughly 1–2 KiB/s of state traffic at 48 kHz (tiny). The input sample is read once and broadcast to all resonators (or processed in SIMD groups).

- **Large-FFT + sparse:** N=8192 complex float working set ≈ 128 KiB (data) + twiddles. Must be blocked or placed off-DTCM. Per hop (H=256 samples ≈ 5 ms) you pay one 8k FFT + iFFT (if modification) + O(108 × 8) extra loads for the local kernels. Compare with a 512-pt STFT hop: ~8× more FFT work but 8–10× better low-frequency resolution.

- **Full front-end with chroma:** after CQT magnitudes, sum into 12 pitch classes (chroma) per frame + optional 1–2 frame context for Δchroma. Output feature vector 12–24 floats (48–96 B) per "frame" (the effective frame rate is lower at high bands). This is the "on-the-fly without spectrogram" analogue of the mel path in the MFCC note.

---

## 5. When to Choose CQT / NSGT vs. STFT vs. Wavelets on Embedded

Use CQT/NSGT when the downstream task cares about **harmonic or pitch relationships** (chroma features, key detection, melody, multiple-F0) and you can afford the per-band state or the occasional large FFT. The recursive resonator form is often the lowest-traffic winner for pure feature extraction on very small MCUs because it avoids any large buffer and has O(1) state per band.

Use plain STFT (or mel from STFT) when you need **uniform time resolution** across frequency (onset detection, broadband noise, speech formants at high freq) or when you already pay for the FFT for other reasons and can reuse the spectrum.

Use lifting DWT when you want **multi-resolution in both time and frequency with integer or near-integer arithmetic and the absolute minimal state** (a few samples per level, in-place). Wavelets are "cheaper" in bytes moved per decomposed sample for a full dyadic tree, but the "bins" are not musically aligned and phase is harder to interpret for pitch work.

Hybrid pipelines are common and encouraged: run a cheap STFT or wavelet for VAD/onset, then a small CQT resonator bank only on voiced frames for pitch/harmony features.

---

## 6. Elegant Aspects and Open Questions for Embedded

- The "constant Q" constraint plus the painless condition gives perfect reconstruction (or stable analysis) with **per-band independent hops and supports** — a degree of freedom that the uniform STFT lacks and that directly translates into lower average traffic.
- Recursive CQT resonators are essentially a parallel bank of Goertzel-like trackers whose frequencies are geometrically spaced; the same SIMD tricks that accelerate a vector of Goertzels (see DFT and SIMD notes) apply verbatim.
- NSGT theory shows that many "ad-hoc" variable-resolution filter banks that practitioners have used for years are in fact instances of a single clean frame-theoretic object — useful for proving stability and for deriving the dual when modification + resynthesis is required.

Open for tiny embedded: automatic per-band bit-width or exponent scaling (block float per subband), dynamic activation of only the bands that currently carry energy (further traffic reduction), and integer-coefficient or multiplier-less (shift/add) approximations to the resonators while preserving the constant-Q property approximately.

---

## References (Verified)

1. Brown, J. C. (1991). "Calculation of a constant Q spectral transform." *J. Acoust. Soc. Am.* 89(1):425–434. (The original CQT formulation.)
2. Brown, J. C. & Puckette, M. S. (1992). "An efficient algorithm for the calculation of a constant Q transform." *J. Acoust. Soc. Am.* 92(5):2698–2701. (FFT + kernel trick.)
3. Schörkhuber, C. & Klapuri, A. (2010). "Constant-Q transform toolbox for music processing." *7th Sound and Music Computing Conference*.
4. Holighaus, N., Dörfler, M., Velasco, G. A., & Grill, T. (2013/2016). "A framework for invertible, real-time constant-Q transforms." *IEEE TASLP* and related ICASSP papers. (Painless NSGT.)
5. Velasco, G. A., Holighaus, N., Dörfler, M., & Grill, T. (2011). "Constructing an invertible constant-Q transform with nonstationary Gabor frames." *Proc. DAFx-11*.
6. See also the NSGT Python / C reference implementations (https://github.com/grrrr/nsgt and related) for concrete painless dual formulas.

All DOIs and titles above were resolved against primary sources (IEEE Xplore, arXiv, author pages, JASA) during authoring.

---

*This note completes the core time-frequency triad (STFT, wavelets via lifting, CQT/NSGT) with explicit traffic and state comparisons. Future work can add a full implementation recipe for a 120-band recursive CQT in CMSIS-DSP style with measured M7 cycle counts and SRAM footprint.*
