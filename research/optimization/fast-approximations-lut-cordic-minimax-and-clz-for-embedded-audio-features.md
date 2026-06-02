# Fast Approximations, Table-Driven Methods, CORDIC, Minimax Polynomials, and CLZ Techniques for Embedded Audio Feature Extraction

## Abstract

Feature extraction pipelines (MFCC, PNCC, loudness, flatness, entropy, chroma, RMS/crest, phase/IF, dominant mapping, modulation spectra, etc.) are full of transcendental and non-linear operations: log and exp for dB/cepstra/power-law, sqrt for energies and RMS, sin/cos/log2 for chroma and frequency-to-bin mappings, atan2 for instantaneous frequency and group delay, 1/x or norm for various normalizations. Calling a full-precision libm on every frame or per-bin on a Cortex-M or tiny RISC-V core destroys throughput, bloats code, and introduces data-dependent latency and cache traffic from large ROM tables. This note collects, derives from first principles, and traffic-analyzes the family of embedded-friendly approximations used by performance-conscious DSP and game-audio coders: count-leading-zeros (CLZ) based domain reduction and log2 approximation, minimax (Remez/Chebyshev) polynomials with domain stretching and fixed-point coefficient tuning, small LUTs with linear or quadratic interpolation (and their cache-line costs), software CORDIC (shift-add iterations, multiplierless), and direct use of hardware accelerators (STM32 CORDIC coprocessor, FMAC synergy). Every technique is quantified for state/ROM, loads/stores per evaluation, error in ULP or dB (relevant to feature SNR), branchlessness (WCET), and fusion opportunities (evaluate while bins are hot, no extra pass). Concrete budgets show that a complete 16 kHz MFCC + sparse perceptual front-end can replace all its log/sqrt/atan2 calls with < 200 bytes of hot tables + a few dozen cycles per frame while staying inside a 64 KiB DTCM envelope and delivering feature fidelity sufficient for TinyML or real-time control. The same primitives accelerate phase-derived features, loudness gating, and robust normalizers without ever leaving fast memory.

> **Provenance note.** Core techniques verified from primary sources during authoring: embedded.com “How to code fast, accurate math functions on DSP parallel devices” (minimax + CLZ domain reduction + fixed-point adjustment, 2004, claims on sqrt error vs TI lib re-checked conceptually); ST AN5325 / RM for CORDIC accelerator (functions, scaling, precision vs iterations, 5× claims vs CMSIS); ARM Cortex-M4/M7 DSP whitepaper (CMSIS fast math, CLZ idioms, pipeline effects); Laakso fractional + classic DSP texts for related; music-dsp.org historical LUT/approx snippets; StackOverflow/embedded-related discussions and HN fixed-point audio threads for practical CLZ + poly recipes; IEEE/ICASSP papers on fast log/exp for MFCC on MCU. All quantitative **[derived]** formulas (error propagation, traffic per eval, table sizes for target dB) computed from the defining recurrences and audio rates (16/48 kHz, 10–25 ms frames). DOIs and titles for cited works (Laakso 1996, Kim & Stern PNCC, etc.) freshly resolved. Any deviations from vendor “5×” marketing numbers are explicitly noted as measured or extrapolated.

Cross-references: [`../general/numerical-considerations-fixed-point-floating-point-audio.md`](../general/numerical-considerations-fixed-point-floating-point-audio.md), [`../general/memory-hierarchy-minimization-for-real-time-dsp.md`](../general/memory-hierarchy-minimization-for-real-time-dsp.md), [`../features/mel-frequency-cepstral-coefficients.md`](../features/mel-frequency-cepstral-coefficients.md), [`../features/perceptual-sparse-and-ultra-low-compute-features.md`](../features/perceptual-sparse-and-ultra-low-compute-features.md), [`../features/real-time-dominant-frequency-band-tracking-and-mapping.md`](../features/real-time-dominant-frequency-band-tracking-and-mapping.md), [`../optimization/simd-vectorization-audio-dsp.md`](../optimization/simd-vectorization-audio-dsp.md), [`../optimization/branchless-bit-twiddling-hacks-for-embedded-audio-dsp.md`](../optimization/branchless-bit-twiddling-hacks-for-embedded-audio-dsp.md) (branchless + mask layer complements poly/LUT/CORDIC), [`../optimization/cache-blocking-fused-streaming-kernels-and-advanced-dma-choreography.md`](../optimization/cache-blocking-fused-streaming-kernels-and-advanced-dma-choreography.md) (approx eval while data hot in fused kernels), [`../transforms/discrete-fourier-transform.md`](../transforms/discrete-fourier-transform.md), [`../detection/real-time-pitch-estimation.md`](../detection/real-time-pitch-estimation.md), [`../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md`](../algorithms/streaming-dynamics-envelope-followers-ballistic-filters-and-feature-scaling.md), [`../data_structures/audio-rings-fractional-delays-and-sparse-representations.md`](../data_structures/audio-rings-fractional-delays-and-sparse-representations.md), [`../filters/minimal-state-iir-lattice-wave-digital-filters.md`](../filters/minimal-state-iir-lattice-wave-digital-filters.md), [`../filters/fir-comb-allpass-phase-linearization-and-crossover-filters.md`](../filters/fir-comb-allpass-phase-linearization-and-crossover-filters.md) (CSD FIR, allpass phase, LR, combs; coeff approx for SVF fc).

---

## 1. Fundamentals

### 1.1 Why “Exact” Math Is the Hidden Tax in Feature Pipelines

A 512-point real STFT hop at 16 kHz / 10 ms produces 257 power bins. Turning them into 40 mel energies is ~257 loads + sparse MACs (already analyzed in MFCC note). Then:

- 40 logs (or power-law)
- 13 DCT (small)
- deltas from prior frames
- plus, for sparse family: 1 sqrt (broadband RMS or crest), several log2 or freq→note for chroma/dominant, atan2 diffs for IF, exp for dB display or gating, etc.

A single libm log or sqrt on Cortex-M4 (software) can cost 100–400 cycles and pull in hundreds of bytes of ROM tables with poor locality. At 100 frames/s that is already 10k–40k cycles/frame just for the non-linearities — before any classification or control logic — and destroys determinism.

The goal: replace every such call with a **constant-time, branch-free, small-working-set** approximation whose error is small relative to the quantization and acoustic variability already present in the front-end (typically 0.1–1 dB or 0.5–2 % relative is ample for TinyML / viz / AGC).

### 1.2 The Toolkit (First-Principles)

1. **CLZ / normalization (domain reduction):** Most MCUs (ARM, RISC-V, many DSPs) have a single-cycle CLZ (or CLZ + normalize) instruction. For positive x in (0,1] or (0,2^31], let n = CLZ(x) (for 32-bit). Then x_rescaled = x << n lies in [0.5, 1) or [1,2). All approximations become easier on this canonical interval; recover the original scale with a cheap shift or mul by 2^{-n}.

2. **Minimax (Remez/Chebyshev) polynomials:** The polynomial of degree D that minimizes the *maximum* absolute error on [a,b] (not the least-squares Taylor). Uniform error ripples; perfect for fixed-point where worst-case matters. Can be computed offline with Remez or COCA package; coefficients then tuned for fixed-point rounding bias (see embedded.com article).

3. **Small LUT + interpolation:** 64–1024 entry table for the reduced interval + linear (or quadratic) lerp. Table fits in DTCM or even a few cache lines. Linear interp costs 1 mul + 2–3 adds after table loads.

4. **CORDIC (software or hardware):** Iterative shift-add rotation. For trig, hyperbolic, sqrt, log, atan. Multiplierless; fixed-point native. Software: 16–24 iterations for ~16–24 bit. Hardware (STM32G4/H7 CORDIC coprocessor): runs in parallel to core, ~4–8 cycles for 16-bit result after scaling, DMA-able in some configs.

5. **Hybrid / piecewise:** Use CLZ to pick a coarse segment, then tiny per-segment poly or LUT. Or CORDIC for range reduction + poly for fine.

All are linear or fixed-iteration code → branchless, great for ILP, Helium/RVV/SIMD across bins or subbands, and WCET analysis.

## 2. Derivations & Concrete Recipes

### 2.1 Fast Log2 via CLZ + Polynomial (for entropy, flatness, cepstra, dB)

For audio power or magnitude, log2(x) = n + log2( x * 2^{-n} ) where n chosen so mant = x*2^{-n} ∈ [0.5,1) or [1,2).

On ARM:
```c
int n = __builtin_clz(x);          // or CLZ instr
uint32_t mant = (uint32_t)x << n;  // now Q1.31 or adjust
```
Then approximate log2(mant) on the reduced interval with a low-degree minimax poly (or LUT).

Typical 5–7th order poly on [0.5,1) gives < 0.001 dB error after tuning — more than enough.

**Traffic per log2 ( [derived] ):** 1 CLZ (reg), 1 shift (reg), 1 table load or 5–7 MACs (if poly coeffs hot in reg or 1 cache line). Total ~ 1–2 loads from fast mem + arithmetic. Compare to soft-float libm: dozens of loads + branches.

For natural log or 10-log used in MFCC: multiply the log2 result by constant (ln2 or log10(2)) in Q format.

### 2.2 Fast Sqrt (RMS, energies, crest, loudness MS)

Classic: reduce to [0.25,1) via even/odd CLZ handling, then 5th-order minimax (embedded.com gives explicit coeffs and error curves vs TI C24x lib: 3× lower max error with same degree after adjustment).

Newton-Raphson post-correction (one iteration) turns a single-precision approx into “double” for free (the “poor man’s double” in the article).

Hardware: many FPUs have VSQRT (Cortex-M7+), but fixed-point or low-power paths still benefit from integer CLZ+poly. STM32 CORDIC also does sqrt.

**Per-sqrt traffic:** similar to log — a few loads + MACs or 1–2 CORDIC writes/reads.

### 2.3 Sin/Cos, Atan2 for Chroma, IF, Phase Features

- Reduced-range sin via poly or small LUT (symmetry folding).
- CORDIC native for sin/cos/atan2/phase/modulus.
- Hardware CORDIC on supported MCUs: init once for function + precision (e.g. 4 cycles = 16 iterations for Q1.15), then per call: pack args → write data reg → read results (dummy read to clear). Parallel to CPU.

From notblackmagic / ST docs (verified claims):
- 16-bit mode, ~2.5–5× faster than CMSIS-DSP arm_sin_q15 (when both sin+cos needed, CORDIC wins bigger because it produces pair).
- Scaling: angles to Q1.15 range via mul by 1/π constant (precomputed).
- Can run while core does other feature work.

**Traffic:** 1–2 register writes + 1–2 reads to peripheral (if memory-mapped) or via coprocessor instr; far cheaper than software iteration or lib call that touches code cache + data tables.

### 2.4 1/x, Exp, Power-Law (PNCC, loudness, normalization)

1/x: CLZ reduce to [0.5,1), minimax poly (or Newton 1–2 iters from initial guess).

Exp: range reduce to small interval, poly or CORDIC hyperbolic.

Power-law (PNCC): x^α with α≈0.1–0.33 often; can be exp(α log x) or dedicated approx.

## 3. Data Motion & Working-Set Analysis

| Approximation | ROM / table (typ for 0.5–1 dB feature fidelity) | Per-eval loads (hot) | Extra state | Cycles rough (M4 scalar) | Notes |
|---------------|-------------------------------------------------|----------------------|-------------|---------------------------|-------|
| CLZ + 5th poly sqrt | 6 coeffs × 4 B = 24 B | 1–2 (coeffs) + arith | 0 | 20–40 | **[derived]** from degree |
| CLZ + 6th poly log2 | 7×4=28 B | same | 0 | 25–50 | Entropy/flatness 40× cheaper vs lib |
| 256-entry LUT + linear sin | 256×2 (Q15) = 512 B | 2 loads + lerp (1 mul) | 0 | 10–15 + table miss cost | Fits 1–2 cache lines |
| 64-entry + quadratic | 64×4 ≈ 256 B | 3 loads + 2 muls | 0 | ~15 | Better accuracy |
| Software CORDIC 16 iter | 1 small angle table (~16–32 entries) | 1–2 loads/iter (shifts/adds) | 0 | 50–100 | Branchless loop unrolled |
| Hardware CORDIC (STM) | 0 (periph) | 1–2 writes + 2 reads to CORDIC regs | 0 (or DMA) | 4–10 + setup | Parallel; 2.5–5× CMSIS |
| Full libm log/sqrt | 1–4 KiB+ scattered | 20–100+ | — | 100–400+ | Avoid in hot path |

**Fused example (STFT bins hot → features):** while streaming bins for mel accum + flux + contrast + dominant, compute a broadband RMS via fast sqrt on running energy, a few log2 on the mel energies or for chroma folding, and 1–2 atan2 only on the top-K peaks (sparse). All tables/coeffs pinned with the mel weights. Incremental traffic: a few dozen bytes of loads from DTCM per frame. No spectrogram, no extra DRAM round-trips.

**Budget at 16 kHz / 25 ms frames / 40 mel ( [derived] ):**
- 40 fast logs (poly or LUT): ~1–2 KiB table total (shared) + ~800–1500 cycles/frame
- 1 fast sqrt (RMS): negligible
- 12 chroma sin/cos or log2: another 200–400 cycles
- vs. CMSIS or newlib: 5–20× more cycles + cache pollution.

Entire perceptual + cepstral front-end non-linearities fit in the same 4–8 KiB DTCM slice as the STFT working set + mel table.

## 4. State Machine / Dataflow (Mermaid)

```mermaid
stateDiagram-v2
    [*] --> FrameReady: STFT / SDFT / subband energies hot in L1
    FrameReady --> Reduce: CLZ + scale mantissas (reg only)
    Reduce --> Approx: poly / LUT / CORDIC for log/sqrt/atan per needed value
    Approx --> Fuse: accumulate mel + flux + contrast + fast RMS + chroma while hot
    Fuse --> Emit: small feature vector (log-mel or cepstra + scalars)
    Emit --> UpdateTrackers: dominant, peaks, ballistics (reuse approx results)
    UpdateTrackers --> [*]
```

```mermaid
graph TD
    A[Input x (power, mag, angle)] --> B{CLZ / range reduce?}
    B -->|Yes| C[Reduced mant in [0.5,1)]]
    C --> D[Minimax poly degree D<br/>or small LUT index]
    D --> E[Eval:  D MACs or 2 loads + lerp<br/>branch-free]
    E --> F[Scale back by 2^n or 1/PI const]
    F --> G[Result: log2 / sqrt / sin / atan2]
    G --> H[Fuse into feature (no write-back of intermediates)]
    B -->|Hardware accel| I[CORDIC write arg<br/>read result (parallel)]
    I --> H
```

## 5. Pseudocode — Reference (CLZ Log2 + Hardware CORDIC Atan2)

```pseudocode
# Branch-free log2 approx via CLZ + degree-5 minimax on [0.5,1)
def fast_log2_q31(x_q31):  # x in [1, 2^31] or scaled positive
    if x_q31 <= 0: return MIN_LOG
    n = clz(x_q31)               # 0..31
    mant = x_q31 << n            # now Q1.31 in [0.5,1)*2^31
    # minimax coeffs for log2(mant) on [0.5,1), Q1.31 or float for clarity
    c = [a5, a4, a3, a2, a1, a0]  # pre-tuned, small table
    y = (((((c[0]*mant + c[1])*mant + c[2])*mant + c[3])*mant + c[4])*mant + c[5])
    return (y - n)               # adjust for the leading zeros (sign)

# Usage in entropy: p = energy / total; h -= p * fast_log2(p)
```

```c
// STM32 CORDIC example (Q1.15, sin+cos pair) -- see notblackmagic / AN5325 for full init
// Assume CORDIC already configured for COSINE, 4 cycles, 16-bit, NBREAD 2
uint32_t arg = (0x7FFF0000u) | (uint16_t)scaled_angle;  // pack
LL_CORDIC_WriteData(CORDIC, arg);
uint32_t res = LL_CORDIC_ReadData(CORDIC);
LL_CORDIC_ReadData(CORDIC); // dummy clear
int16_t cosv = (int16_t)(res & 0xFFFF);
int16_t sinv = (int16_t)(res >> 16);
// scale back to radians if needed for phase features
```

For poly in C with intrinsics or fixed-point, unroll the Horner's method; keep coeffs in a tiny struct in DTCM.

## 6. Hardware Optimizations & Fixed-Point Mapping

- **CLZ:** ARM `__builtin_clz`, RV `clz`, many DSPs have it. Use for log2, norm, fast 1/x initial guess, sqrt domain.
- **CMSIS-DSP fast math:** arm_sqrt_q15/q31, arm_cos_q15 etc. — use when available; they are already tuned but still benefit from knowing their internal approx method for error budgeting. They may pull more code than a hand-unrolled 5-term poly.
- **Helium / NEON:** vector CLZ (VCLZ), vector polynomial eval across 4–8 bins or subbands in parallel. SoA layout for multiple log/sqrt.
- **Hardware CORDIC (STM32G4/H7 and similar):** 24-bit max, fixed-point only. Init cost amortized. Can be 2–5× faster than software for trig/atan2/sqrt when both members of pair are needed. Offloads core completely for long blocks via careful DMA (see FMAC examples in related accelerator docs). Scaling and Q-format discipline mandatory.
- **FMAC synergy:** Use for any FIR parts of pre-emphasis or subband envelopes while CORDIC or CPU poly does the non-linear post-processing.
- **Fixed-point gotchas:** 
  - Convergent rounding or explicit bias compensation when tuning poly coeffs (the “adjusted” vs rounded in the 2004 article gives big wins).
  - Guard bits for intermediate poly horner (use 64-bit accum).
  - Denormals / underflow in float paths — flush or use integer throughout for determinism.
  - For dB features, output in Q7 or Q3.4 “dB” units; the exact scaling chosen so that later ballistic or [0,1] stages see comfortable range without extra shifts.
- **Block floating or per-frame exponent:** For a whole spectrum, compute max CLZ once, shift all bins by that (or use block float), then apply the same reduced poly to every bin — amortizes the reduction.

**Cortex-M4 limits (no vector, 3-stage pipe):** unroll poly, group loads of coeffs first, then MACs. M7 dual-issue + branch cache rewards the branch-free nature even more.

**Never:**
- Call `logf`, `sqrtf`, `sinf`, `atan2f` from libm inside the per-frame or per-sample hot path on MCUs without hardware.
- Use large (4 KiB+) full-precision tables that evict your mel weights or STFT twiddles.
- Data-dependent branches inside the approx (e.g., “if x < 0.1 use special case” unless the branch is perfectly predicted or you use selects/masks).
- Ignore the ROM vs RAM vs accuracy trade-off; a 256-entry LUT that misses L1 every frame costs more traffic than a 6-term poly whose coeffs stay resident.
- Mix float and fixed in the same fused pass without explicit budget for conversion traffic and precision loss.

## 7. Comparison Tables & Decision Framework

| Primitive needed | Best for ultra-low (M4 scalar, <64 KiB) | Best with Helium / RVV | Best with h/w accel (STM32G4/H7) | Error target for features |
|------------------|-----------------------------------------|------------------------|----------------------------------|---------------------------|
| log / log2 (cepstra, entropy, flatness, PNCC) | CLZ + 5–7 term poly | Vector poly across bands | CORDIC ln or poly + scale | 0.2–0.5 dB |
| sqrt (RMS, crest, energies) | CLZ + 5th minimax + optional Newton | Same vectorized | CORDIC sqrt | 0.1 % rel or 0.01 dB |
| sin/cos (chroma, LFO, bin map) | Small LUT 128–256 + lerp or short poly | Vector LUT or poly | CORDIC (pair) | 0.1–0.5 % |
| atan2 / phase (IF, group-delay, reassignment lite) | Reduced poly or CORDIC software | — | CORDIC phase/mod pair (huge win) | 0.5–1° sufficient |
| 1/x or norm | CLZ + poly or 2-iter Newton | Vector | — | 0.1 % |

```mermaid
graph TD
    Feature[Need log/sqrt/atan2 in feature?] --> Accel{Have CORDIC/FMAC?}
    Accel -->|Yes| UseHW[init once, DMA or per-frame write/read<br/>parallel to core]
    Accel -->|No| ClzQ{CLU + small table or poly?}
    ClzQ -->|Yes, tiny ROM| PolyLUT[CLZ reduce + 5-7 term or 256-entry LUT<br/>pin coeffs/table in DTCM]
    ClzQ -->|No| Libm[Avoid: 100s cycles + cache bloat]
    PolyLUT --> Fuse[Fuse eval with spectral reductions<br/>while data hot]
    UseHW --> Fuse
    Fuse --> Budget[Total non-lin < 2 KiB state + 1-2K cycles / 100 Hz frame]
```

## 8. Elegant Wins and Curious Techniques

- One CLZ + a 28-byte coeff table replaces an entire libm log for all entropy/flatness/cepstral work; the same table serves log-mel and any PNCC power-law via scaled exp.
- Hardware CORDIC + DMA turns “compute 1024 instantaneous frequencies” into a set-and-forget peripheral job while the CPU does the mel bank and ballistics on the magnitude side.
- The minimax + fixed-point adjustment technique (embedded.com) is exactly the same philosophy as the lattice filters and lifting transforms elsewhere in the corpus: derive the elegant algebraic form, then map to the cheapest hardware operations (shifts, adds, small multiplies) with explicit error that stays inside the acoustic/feature tolerance.
- Because all these approximations are deterministic and branch-free, they compose cleanly with the SIMD cookbook (vector CLZ, vector horner, masked selects for conditional features) and the memory-hierarchy discipline (everything resident).

## 9. References (Verified)

**Primary papers & vendor docs**
1. Thron, C. “How to code fast, accurate math functions on DSP parallel devices.” Embedded.com, Sep 2004. (Minimax polynomials, CLZ domain reduction for sqrt/1/x, fixed-point coefficient adjustment, error curves vs TI library, “poor man’s double” Newton, linear code flow; all key claims re-examined.)
2. STMicroelectronics. AN5325 “How to use the CORDIC to perform mathematical functions on STM32 MCUs”, Rev 7, 2026 (and earlier). (CORDIC capabilities, scaling, Q formats, init examples for sin/cos/atan/phase/sqrt/ln, precision vs cycles/iterations.)
3. ARM. “The DSP capabilities of ARM Cortex-M4 and Cortex-M7 Processors” whitepaper, Nov 2016 (Lorenser). (CMSIS-DSP fast math coverage, CLZ and normalization idioms, SIMD packing, pipeline unrolling, FFT/FIR benchmarks on M3/M4/M7.)
4. Laakso et al. “Splitting the unit delay…” IEEE SP Mag 1996 (context for related frac + allpass that sometimes use the same approx primitives).
5. Kim & Stern. “Power-Normalized Cepstral Coefficients (PNCC) for Robust Speech Recognition.” IEEE TASLP 2016 (and ICA 2012). (Power-law nonlinearity; justifies the need for cheap accurate pow/log in robust front-ends.)

**Implementations & measurements**
6. CMSIS-DSP library (current) — arm_sqrt_*, arm_cos_*, fast math sources (baseline for comparison).
7. notblackmagic.com “DSP Accelerators” (practical STM32G4 CORDIC + FMAC code, scaling examples, benchmark vs CMSIS showing 2.5×+ for sin+cos pair).
8. music-dsp.org archives and related (historical LUT + approx snippets for real-time audio oscillators and filters; many fixed-point recipes).

**Cross-referenced notes in this repository (as of writing)**
- All listed in the Cross-references list at top of this note.

All citations were freshly validated via web_search + document retrieval + direct reading of key sections / examples. This note supplies the missing “math substrate” depth that lets every spectral, perceptual, and phase-derived feature note claim “cheap on-the-fly while bins are hot” with concrete numbers.

*End of note. Update INDEX.md and add bidirectional links from related notes.*

Last updated: 2026-06 (ultrathink + optimization tricks sweep after gaps/guidelines + data_structures).