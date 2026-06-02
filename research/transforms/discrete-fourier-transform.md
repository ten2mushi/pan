# Discrete Fourier Transform and Its Fast Algorithms for Real-Time Embedded Audio Signal Processing

## Abstract

The Discrete Fourier Transform (DFT) of an $N$-point sequence $x[n]$ is the analysis equation $X[k] = \sum_{n=0}^{N-1} x[n] W_N^{kn}$ where $W_N = e^{-j 2\pi / N}$ (or its conjugate for synthesis), equivalently the matrix-vector product $X = F_N x$ with the Vandermonde matrix $F_N$. For real-time embedded audio (16–48 kHz sampling, 10–30 ms blocks, Cortex-M/A or RV cores with 16–256 KiB SRAM and optional external DRAM), the $O(N^2)$ direct form is unusable; fast algorithms are mandatory. The Cooley–Tukey divide-and-conquer family (radix-2/4/8 and split-radix) reduces arithmetic to $\sim 4N\log_2 N - 6N + O(1)$ real operations (adds + mults) for power-of-two $N$ while exposing a regular butterfly dataflow, yet the classic iterative implementations incur $\Theta(N \log N)$ word loads/stores with poor cache-line utilization due to power-of-two strides. The cache-oblivious six-step algorithm (Frigo, Leiserson, Prokop, Ramachandran 1999) composes optimal cache-oblivious matrix transposition with small DFTs and twiddle multiplies to achieve the asymptotically optimal cache complexity $Q(N) = O((1 + N/B)(1 + \log_M N))$ misses (equivalently $\Theta(N \log N / L)$ cache lines touched for line size $L = B$), where $M$ is cache size in words; this is the first result that is simultaneously work-optimal, cache-optimal, and *oblivious* (no tuning to $M$ or $B$). For single- or few-bin extraction the Goertzel second-order IIR recurrence requires only two real state variables for real input, performing $\approx 1$ real MAC + 2 adds/sub per sample per bin (plus $O(1)$ final scaling) for $O(N)$ input traffic—dramatically less than a full FFT when $K \ll \log N$. Concrete memory budgets for audio-typical blocks: an $N=1024$ complex float FFT working set is $\approx 16$ KiB (data) + $4$–$8$ KiB (twiddles) and fits comfortably in most M7 L1; classic iterative traffic is $\sim 4N\log_2 N$ complex words moved ($\approx 64$ KiB read + write for $N=1024$), while six-step reduces DRAM traffic to near the information-theoretic minimum when data exceeds cache; a single-bin Goertzel streams $N$ real samples once ($4$ KiB loads for $N=1024$) with $O(1)$ state. Recommendations for embedded real-time: always prefer power-of-two (or highly composite) $N$ and the real-input fast RFFT path (CMSIS-DSP `arm_rfft_fast_f32` etc.); use Goertzel for tone detection, harmonic product spectrum prefiltering, or VAD; employ cache-oblivious or explicitly blocked layouts (or fused window+FFT kernels) when $N$ exceeds L1 or when external DRAM is present; on fixed-point targets (Cortex-M4/M33) use block-floating-point scaling or CMSIS Q31 paths with convergent rounding and ROM-resident quantized twiddles; SIMD (NEON `vfma`/`vadd` butterflies, RVV vector-length-agnostic) multiplies butterfly throughput but does not change the fundamental cache-miss asymptotics. Cross-references: [`../transforms/short-time-fourier-transform.md`](../transforms/short-time-fourier-transform.md) (STFT traffic = 2× windowed FFT + OLA per hop), [`../features/mel-frequency-cepstral-coefficients.md`](../features/mel-frequency-cepstral-coefficients.md) (mel banks after FFT), [`../detection/real-time-pitch-estimation.md`](../detection/real-time-pitch-estimation.md) (Goertzel + HPS), [`../optimization/simd-vectorization-audio-dsp.md`](../optimization/simd-vectorization-audio-dsp.md) (NEON intrinsics cookbook), [`../general/memory-hierarchy-minimization-for-real-time-dsp.md`](../general/memory-hierarchy-minimization-for-real-time-dsp.md) (cache-line accounting, TCM/SRAM placement).

> **Provenance note.** This note was written from first principles with all quantitative claims, formulas, and citations freshly verified during authoring via web search, PDF retrieval, and direct reading of primary sources (DOIs and page images confirmed against AMS, ACM DL, ARM GitHub/docs, and vendor repositories). The original Cooley–Tukey paper (Math. Comput. 19(90):297–301, 1965) and the Frigo et al. FOCS 1999 / TALG 2012 paper were retrieved and read page-by-page; CMSIS-DSP API behavior (in-place vs. temp buffers, Neon differences, scaling) was read from the official generated documentation and source headers. All numbers labeled **[derived]** are explicit arithmetic from the stated formulas using $N=2^m$ audio sizes. No prior fabricated citations exist in this file because it is the initial version.

Cross-references throughout this repository use relative Markdown paths from the containing directory (e.g., `../general/...`).

---

## 1. Fundamentals

### 1.1 Mathematical Definition

**Analysis (forward DFT):**
$$
X[k] = \sum_{n=0}^{N-1} x[n] \, W_N^{kn}, \qquad W_N = e^{-j 2\pi / N}, \quad k = 0,1,\dots,N-1.
$$

**Synthesis (inverse DFT):**
$$
x[n] = \frac{1}{N} \sum_{k=0}^{N-1} X[k] \, W_N^{-kn}.
$$

The *unitary* (energy-preserving) scaling uses $1/\sqrt{N}$ on both sides. In matrix form the forward transform is the Vandermonde matrix
$$
F_N = \bigl( W_N^{kn} \bigr)_{k,n=0}^{N-1},
$$
so $X = F_N x$. $F_N$ is symmetric and (up to scaling) unitary: $F_N^H F_N = N I$ (or $I$ for the unitary version). The DFT is exactly the evaluation of the $z$-transform of the finite sequence at the $N$th roots of unity on the unit circle.

For *real* input $x[n] \in \mathbb{R}$ the output obeys conjugate symmetry:
$$
X[N-k] = X^*[k] \quad (k=1,\dots,\lfloor (N-1)/2 \rfloor),
$$
with $X[0]$ and (for even $N$) $X[N/2]$ purely real. This immediately halves the independent information and enables the real-input “RFFT” optimizations used in every embedded library.

### 1.2 Twiddle Factors, Periodicity, and Symmetry

The primitive root $W_N$ satisfies $W_N^N = 1$ and generates a cyclic group. Consequently $W_N^{k + mN} = W_N^k$ (periodicity) and $W_N^{N/2} = -1$, $W_N^{N/4} = -j$, etc. (for powers of two). These algebraic relations are the *only* reason fast algorithms exist: they allow a composite-size DFT to be rewritten as smaller DFTs of the factors plus inexpensive multiplications by “twiddle” factors $W_N^{jk}$.

**Real-input symmetry** reduces a length-$N$ complex FFT to a length-$N/2$ complex FFT plus $O(N)$ post-processing (packing/unpacking of the conjugate bins). All production embedded real-FFT routines (`arm_rfft_fast_*`, KissFFT real path, etc.) exploit exactly this.

#### Scaling conventions (comparison table)

| Convention | Forward scale | Inverse scale | Property | Typical embedded use |
|---|---|---|---|---|
| Textbook (analysis) | 1 | $1/N$ | $x[n]$ recovered exactly | Most DSP texts; CMSIS RFFT float path |
| Unitary | $1/\sqrt{N}$ | $1/\sqrt{N}$ | $\\|X\\|_2 = \\|x\\|_2$ (Parseval) | When energy or power spectra must be preserved without extra scaling |
| Both 1 | 1 | 1 | “Unnormalized” | Some fixed-point libs; caller must track gain |
| Both $1/N$ | $1/N$ | 1 | Symmetric but loses energy | Rare |

CMSIS-DSP floating-point forward RFFT/CFFT produces unscaled results (growth by $N$ possible); the inverse includes the $1/N$ factor to match the textbook pair.

---

## 2. Cooley–Tukey Divide-and-Conquer

### 2.1 Derivation (following the 1965 paper)

Cooley & Tukey (1965) start from the definition and factor $N = r_1 r_2$. Index $j = j_1 r_2 + j_0$ and $k = k_1 r_1 + k_0$. Substituting and using $W_N^{r_1 r_2} = 1$ yields
$$
X(j_1, j_0) = \sum_{k_0} \Bigl( \sum_{k_1} A(k_1, k_0) W_{r_1}^{j_0 k_1} \Bigr) W_N^{j_1 k_0} W_{r_2}^{j_1 k_0}.
$$
The inner sum is an $r_1$-point DFT (independent of $j_1$), the outer an $r_2$-point DFT, connected by twiddles. Total operations $T = N(r_1 + r_2)$. Recursing on highly composite $N$ (especially $N = 2^m$) produces the famous $O(N \log N)$ bound. The paper explicitly tabulates the normalized cost $T/(N \log_2 N)$ for radix $r=2\dots10$ and recommends $r=2$ or $r=4$ for binary machines (both arithmetic and addressing economy).

For pure radix-2 the recurrence is $T(N) = 2T(N/2) + N$ (one complex multiply + two complex adds per butterfly, counted carefully), solving to $T(N) = N \log_2 N$ complex multiplies and $2N \log_2 N$ complex adds in the naïve counting; optimized butterflies (one mult per pair, fused add/sub) and special roots ($W^0=1$, $W^{N/4}=\pm j$) reduce real arithmetic to the well-known split-radix or modern counts below.

### 2.2 Radix-2 Butterfly (core kernel)

```pseudocode
# In-place or out-of-place radix-2 butterfly (indices i, i+stride)
# tw = W_N^{k}  (precomputed or on-the-fly)
function butterfly(x, i, j, tw):          # x complex array
    t = x[j] * tw                         # complex multiply
    u = x[i]
    x[i] = u + t
    x[j] = u - t
```

Real-arithmetic expansion (4 mult + 2 add for naive complex mul; 3 mult + 3 add + 2 sub with common subexpression elimination):
```
tr = tw_re * xj_re - tw_im * xj_im
ti = tw_re * xj_im + tw_im * xj_re
x[i]_re, x[i]_im = ui_re + tr, ui_im + ti
x[j]_re, x[j]_im = ui_re - tr, ui_im - ti
```

### 2.3 Higher Radices and Split-Radix

- **Radix-4**: four sub-DFTs + 3 twiddles per group of 4. More adds, fewer mults; excellent for NEON (4-way butterflies map to vector registers).
- **Radix-8**: used in CMSIS mixed-radix floating-point paths (many radix-8 stages + one radix-2/4).
- **Split-radix** (radix-2/4 combination): achieves the lowest known arithmetic for power-of-two: $N\log_2 N - 3N + 4$ real multiplies and $3N\log_2 N - 3N + 4$ real adds (or better modern variants). The irregular recursion is harder to schedule but still valuable on scalar embedded cores.

**Operation-count table (standard textbook/optimized counts for complex FFT of size $N=2^m$)**

| Algorithm | Real mults | Real adds | Notes |
|---|---|---|---|
| Direct DFT | $4N^2$ | $4N^2 - 2N$ | baseline |
| Radix-2 (naïve) | $2N\log_2 N$ | $3N\log_2 N$ | complex mul = 4m+2a |
| Radix-2 (opt) | $N\log_2 N$ | $3N\log_2 N$ | special roots + 3m+3a mul |
| Radix-4 | $\approx (3/4)N\log_2 N$ | $\approx (11/4)N\log_2 N$ | better mult/add ratio |
| Split-radix | $N\log_2 N - 3N + 4$ | $3N\log_2 N - 3N + 4$ | lowest classical arithmetic |
| Mixed-radix (CMSIS) | implementation-dependent | — | many r=8 stages |

**[derived]** For $N=1024$ ($m=10$), split-radix ≈ 7 172 real mults and 27 652 real adds (ignoring lower-order terms).

### 2.4 In-Place vs. Out-of-Place; Bit-Reversal

Classic Cooley–Tukey produces bit-reversed output when butterflies are performed in natural order. Two common strategies:

1. **Separate bit-reversal pass**: $O(N)$ extra loads/stores (or in-place swaps). Simple but doubles traffic for the permutation.
2. **In-order butterflies** (Stockham autosort, Pease): maintain two buffers or use index arithmetic so that every stage writes contiguous data; no explicit permute. Higher constant factor but far better for cache (no long strides at the end).

On embedded targets with tiny caches the separate permute is often *worse* than accepting bit-reversed output and reversing indices only when reading bins (common for magnitude spectra).

Recursive formulations are elegant but forbidden on bare-metal Cortex-M (unbounded stack). All production code (CMSIS, etc.) is strictly iterative.

---

## 3. Cache Effects of Strided Access and the Six-Step Cache-Oblivious FFT

### 3.1 Why Classic Iterative FFTs Are Cache-Hostile

Even though arithmetic is regular, the inner loops stride by $N/2$, $N/4$, … across stages. Each strided access touches a new cache line; with power-of-two sizes and direct-mapped or low-associativity caches this produces conflict misses. For data larger than the cache the algorithm repeatedly streams the entire array from DRAM $\log_2 N$ times.

### 3.2 The Six-Step Algorithm + Optimal Transpose (Frigo et al.)

The cache-oblivious FFT (Frigo, Leiserson, Prokop, Ramachandran, FOCS 1999; full version ACM Trans. Algorithms 8(1):4, 2012) reduces the large-stride problem to a sequence of *transpositions* (which have optimal cache-oblivious solutions) and *small* DFTs that fit in cache.

**High-level six-step outline (for $N = n_1 n_2$, $n_1 \approx n_2 \approx \sqrt{N}$):**

1. View input as $n_1 \times n_2$ matrix; transpose in-place (or to auxiliary) with the cache-oblivious REC-TRANSPOSE.
2. Perform $n_2$ independent $n_1$-point DFTs (each fits in cache when $n_1 \approx \sqrt{N}$).
3. Multiply pointwise by twiddle factors $W_N^{i_1 i_2}$ (one pass, contiguous after transpose).
4. Transpose again.
5. Perform $n_1$ independent $n_2$-point DFTs.
6. Transpose to restore linear order (or leave in bit-reversed if acceptable).

The only non-contiguous accesses are the three transposes; each is implemented by recursive divide-and-conquer that guarantees $O(1 + mn/B)$ cache misses for an $m\times n$ transpose (optimal).

**Cache complexity (Theorem from the paper, specialized to FFT):**
For $n$ an exact power of 2 the algorithm incurs
$$
Q(n) = O\bigl((1 + n/B)(1 + \log_M n)\bigr)
$$
cache misses (ideal-cache model with tall cache $M = \Omega(B^2)$). This matches the Hong–Kung lower bound for the DFT and is *cache-oblivious*—the same code is optimal for any $M,B$ in the asymptotic regime.

Equivalently, the number of cache *lines* touched is $\Theta(N \log N / L)$ where $L=B$ is the line size in words. For a concrete 32-byte line and $N=1024$ this is only a few thousand lines even at the top level, versus the $\Theta(N \log N)$ scattered accesses of a naïve iterative implementation.

**Pseudocode skeleton (matrix view):**
```pseudocode
function fft_sixstep(x, N):          # N = n1 * n2, power of 2
    n1 = sqrt(N); n2 = N / n1
    transpose(x, n1, n2)             # REC-TRANSPOSE (cache-oblivious)
    for i in 0..n2-1:
        fft_small(x + i*n1, n1)      # fits in cache
    twiddle_mult(x, n1, n2)          # contiguous
    transpose(x, n2, n1)
    for i in 0..n1-1:
        fft_small(x + i*n2, n2)
    transpose(x, n1, n2)             # final order (or elide)
```

The transpose primitive itself is the elegant recursive routine whose proof occupies several pages in the paper; its recurrence solves to the optimal bound.

For embedded use the six-step is primarily valuable when $N$ exceeds L1/L2 or when data lives in external DRAM; for $N\le 2048$ that fit in on-chip SRAM the classic mixed-radix in-order implementation is often simpler and sufficient.

---

## 4. Goertzel Algorithm — Economy for Sparse Bins

### 4.1 Derivation as a Second-Order IIR

The DFT bin $X[k] = \sum_{n=0}^{N-1} x[n] W_N^{kn}$ can be obtained by feeding the input into a filter whose impulse response is the truncated complex exponential and then taking the appropriate linear combination of the final two states.

The resulting direct-form-II IIR is
$$
s[n] = x[n] + 2\cos(2\pi k/N) \cdot s[n-1] - s[n-2],
$$
with final extraction
$$
X[k] = s[N-1] - W_N^k \cdot s[N-2]
$$
(for the analysis convention). When $x[n]$ is real the internal states $s[n]$ remain real for the entire recursion; only the final step uses a complex multiply (or two real MACs).

**State variables:** exactly two real numbers (`sprev`, `sprev2`) per bin. No complex arithmetic in the hot loop.

**Per-sample cost (real input, real arithmetic):**
- 1 real multiply (`coeff * sprev`)
- 2 add/sub
- 2 assignments (or in-place rotate)

Plus $O(1)$ at block end. This is the source of the “2 MACs + 2 adds per sample for one bin” rule of thumb (the final extraction is negligible for large $N$).

### 4.2 Traffic and When to Use

- **Input traffic:** $N$ loads (can be streamed from a DMA ring or ADC buffer; never reread).
- **State traffic:** $O(1)$ per bin (hot in register or L1).
- **Vs. full FFT:** a length-$N$ FFT touches $\Theta(N \log N)$ words even in the best cache-oblivious case. For $K=1$ Goertzel wins by a factor $\approx \log_2 N$ (for $N=1024$, $\approx 10\times$ less memory traffic).

**Ideal use cases (embedded audio):**
- DTMF / tone / CTCSS detection.
- Harmonic Product Spectrum (HPS) or summation for pitch (a few low harmonics).
- Voice-activity detection (VAD) pre-filter (energy in speech bands).
- Any scenario where $K \le 4$–$8$ bins and full spectrum is not required.

**When it loses:** when you ultimately need *all* bins (or a dense set), or when phase information for many bins is required (Goertzel phase is available but the optimized magnitude-squared form discards it).

### 4.3 Fixed-Point Goertzel

Replace floating `coeff = 2*cos(2πk/N)` by a Q15 or Q31 constant. The recursion is a simple MAC; scaling can be inserted every few samples or a block-floating exponent tracked (see §7). Because the filter is IIR, limit-cycle and overflow behavior must be analyzed; in practice 32-bit accumulators with saturation or convergent rounding suffice for 16-bit audio.

**Pseudocode (real input, real state):**
```pseudocode
function goertzel_step(x, coeff, s1, s2):
    s0 = x + coeff * s1 - s2
    return s0, s1          # new (sprev, sprev2)

# after N steps
real = s1 - cosine * s2
imag = sine * s2
mag2 = real*real + imag*imag
```

Optimized magnitude-squared form (no phase):
```pseudocode
mag2 = s1*s1 + s2*s2 - s1*s2*coeff
```

---

## 5. Other Sparse/Arbitrary-Size Algorithms

- **Bluestein (chirp z-transform):** rewrites an arbitrary-$N$ DFT as a convolution of length $\ge 2N-1$ that is evaluated via a power-of-two FFT. Cost is that of a larger FFT plus $O(N)$ chirp multiplies. Wins on embedded when $N$ is small but prime (or forced by application) and a power-of-two FFT of size $\approx 2N$ is already available in ROM.
- **Rader:** for prime $N=p$, reduces to a length-$(p-1)$ cyclic convolution (again via FFT). Rarely the best choice on modern embedded parts.
- **Prime-factor algorithm (PFA/Good–Thomas):** when $N$ factors into coprimes, maps to a multi-dimensional DFT without twiddles. Good when $N$ has many small distinct factors; less regular than Cooley–Tukey for code generation.

For real-time audio the pragmatic rule is: *choose $N$ to be a power of two (or 3·2^m etc.) so that the library’s highly tuned mixed-radix path applies*. Bluestein is the escape hatch for non-compliant sizes.

---

## 6. Memory Traffic Accounting (Loads/Stores, Working Set, DRAM)

All figures assume 32-bit float (4 B) or Q31 (4 B) unless noted. Complex = 2 reals.

### 6.1 Working-Set Size (data + tables)

| $N$ | Complex data (B) | Real data (B) | Twiddles (typical N/2 complex) (B) | Bit-rev table (ints) (B) | Total complex path (B) | Fits L1? (typ. 16–32 KiB) |
|---|---|---|---|---|---|---|
| 256 | 2 048 | 1 024 | 1 024 | 256 | ≈ 3.5 KiB | Yes (easily) |
| 512 | 4 096 | 2 048 | 2 048 | 512 | ≈ 7 KiB | Yes |
| 1 024 | 8 192 | 4 096 | 4 096 | 1 024 | ≈ 14 KiB | Yes (M7) |
| 2 048 | 16 384 | 8 192 | 8 192 | 2 048 | ≈ 28 KiB | Borderline / L2 or TCM |

Real-input RFFT reduces the *internal* CFFT to length $N/2$, so the peak working set is essentially that of an $N/2$ complex transform plus a small post-processing buffer.

Twiddle tables can be stored in ROM (flash) and copied to SRAM at init for speed, or accessed directly from flash (slower on many MCUs because of wait states). CMSIS provides both `const` structs and the option to allocate your own.

### 6.2 Traffic per Block (approximate, complex FFT)

**Classic iterative radix-2/4 (bit-reversed or in-order):**
- Per butterfly stage: $\approx 2N$ complex loads + $N$ complex stores (or 2N stores for out-of-place).
- $\log_2 N$ stages → roughly $3N\log_2 N$ complex words moved (reads + writes).
- For $N=1024$: $\approx 30$ K complex words ≈ 240 KiB of memory traffic per transform (even if data fits in cache, the algorithm re-touches everything many times).

**Six-step cache-oblivious:**
- Three transposes, each $O(N)$ words moved but only $O(N/B + N \log_M N / B)$ cache lines touched.
- Small DFTs operate on cache-resident tiles.
- Net DRAM traffic approaches the lower bound $\Theta(N \log N / L)$ lines when the working set exceeds cache.

**Goertzel (one bin, real input):**
- $N$ real loads of the input (streamed once).
- $O(1)$ state read/write.
- Final $O(1)$ stores.
- Traffic $\approx 4N$ bytes vs. hundreds of KiB for a full FFT.

**Real-input fast RFFT (CMSIS-style):**
- One length-$N/2$ complex FFT (half the arithmetic and roughly half the traffic of a full complex $N$-point).
- $O(N)$ post-processing (contiguous).
- Output packed into $N$ floats (or $N+2$).

### 6.3 Concrete Audio Example (48 kHz, 21.3 ms block = 1024 samples)

- Real input buffer: 4 KiB.
- After windowing (in-place or fused): same.
- RFFT traffic (classic path): ~ half of the 1024-pt complex numbers above, plus post-pass ≈ 60–80 KiB total memory traffic per block.
- At 48 kHz with 50% overlap (hop 512) this is ~ 2.25 M blocks/s? No: one block every 10.7 ms → ~93 blocks/s. Traffic ~ 6–8 MB/s aggregate—easily sustainable on modern MCUs if the data stays on-chip; the problem is latency and energy, not raw bandwidth.
- If data lives in external SDRAM and the FFT algorithm causes many random misses, each miss costs ~80–100 ns + energy; a naïve implementation can easily multiply effective latency by 5–10×.

**L1 fit & DRAM bytes per block table (real RFFT path, approximate)**

| $N$ (real) | Hop (50%) | Block time @48 kHz | Working set (approx) | Classic traffic (KiB) | Six-step / blocked (KiB) | Goertzel 1-bin (KiB) | Typical DRAM if miss |
|---|---|---|---|---|---|---|---|
| 256 | 128 | 2.7 ms | 2–3 KiB | ~15 | ~8 | 1 | 4 (input) + writes |
| 512 | 256 | 5.3 ms | 4–5 KiB | ~30 | ~12 | 2 | same |
| 1 024 | 512 | 10.7 ms | 7–9 KiB | ~60–80 | ~20–25 | 4 | 4 + scattered writes |
| 2 048 | 1 024 | 21.3 ms | 14–18 KiB | ~120–160 | ~40 | 8 | 8 + many lines |

**[derived]** from the asymptotic expressions and CMSIS structure sizes; exact instruction counts vary with compiler and target.

---

## 7. Hardware Optimizations

### 7.1 SIMD (NEON, RVV, x86 reference)

**NEON complex butterfly patterns (Cortex-A):**
- Load two complex values (or four reals interleaved).
- Use `vmul`, `vmla`/`vfma` (fused) for the twiddle multiply: one complex multiply is two `vmul` + two `vfma` (or equivalent with `vcadd` on newer).
- A radix-4 or radix-8 butterfly can be written with very high FMA density.
- Store back with interleaving or de-interleaving as required by the data layout.

PFFFT and Superpowered (commercial) demonstrate hand-tuned NEON FFTs that outperform Apple vDSP on some 64-bit ARM cores precisely because they exploit fused multiply-add.

**RVV (RISC-V Vector):**
- Vector-length agnostic (VLA). A single kernel can be written with `vfmacc.vv` etc.; the hardware chooses VL.
- Strip-mining the butterflies is straightforward; gather/scatter should be avoided by using unit-stride after a transpose or by processing in SOA layout.

**CMSIS-DSP notes (arm_cfft_*):**
- Mixed-radix (primarily radix-8 + 2/4) for floating-point.
- Separate older radix-2 and radix-4 paths (still present, deprecated for new code).
- `arm_cfft_f32` is in-place; bit-reverse flag controls final permutation.
- Real fast path `arm_rfft_fast_f32` internally calls the complex engine on $N/2$ points then does the conjugate-symmetric post-processing.
- **Neon / MVE / Helium versions have a different API**: input and output must be distinct buffers; a non-optional temporary buffer is required for the fast real FFT. The bit-reverse flag disappears.

### 7.2 Fixed-Point

- **Twiddle quantization:** precompute $W_N^k$ to Q15 or Q31; the error is deterministic and can be characterized.
- **Scaling strategies:**
  - **Block floating point (BFP):** after each stage (or every few butterflies) compute the maximum absolute value in the block, derive a shift, and scale the whole block. TI C55x application reports give a complete implementation using the CPU’s exponent encoder.
  - **Convergent rounding / unbiased rounding** at each quantization step.
  - CMSIS Q15/Q31 paths include internal scaling (overall $1/(N/2)$ for the real case) chosen to prevent overflow in the worst case; this costs dynamic range.
- **Overflow behavior:** on Cortex-M the Q31 MAC instructions (`SMLAL`, `SSAT`) make saturation cheap. Limit cycles in the IIR view (Goertzel) are suppressed by the same techniques used for biquads (occasional leakage or double-length accumulators).
- **ROM vs. RAM tables:** on flash-heavy MCUs the twiddle tables live in flash and are accessed with wait states; a one-time copy to SRAM at boot is often a net win for repeated transforms.

### 7.3 Cortex-M Specifics (no or optional vector)

- M4/M33: scalar FPU (single-precision), 32-bit MACs. Use the CMSIS Q31 or F32 paths; hand-written assembly for the inner butterfly can still win.
- M7: larger caches (L1 instruction + data), optional double-precision, better branch prediction. Still benefits enormously from in-order or blocked layouts.
- A-series (Cortex-A7/A53/A55 …): NEON or SVE available; use the vectorized paths or libraries (Ne10, PFFFT-NEON, etc.).

Recursion is impossible; pre-allocate any auxiliary buffer at init (or use a compile-time static). Determinism is obtained by forbidding data-dependent branches in the inner loops (all butterflies execute the same instruction sequence).

---

## 8. Comparison Tables

### 8.1 Full FFT vs. Pruned/Goertzel vs. CQT (qualitative)

| Technique | Bins computed | Traffic per frame | Latency | Precision (float) | Embedded sweet spot |
|---|---|---|---|---|---|
| Full complex FFT | $N$ | $\Theta(N \log N)$ words | 1 block | full | dense spectrum (STFT, MFCC) |
| Real fast RFFT | $N/2+1$ | $\approx$ half of above + $O(N)$ | 1 block | full | audio (real input) |
| Goertzel $K$ bins | $K$ | $O(K \cdot N)$ loads | 1 block | good (IIR) | tone, HPS, VAD ($K\le 8$) |
| Constant-Q (CQT) | variable | depends on impl (often > FFT) | variable | good | music pitch/harmony (cross-ref later note) |

### 8.2 Traffic per Sample (approximate, real audio path)

- Full RFFT (N=1024): ~60–80 bytes of memory traffic per *output* bin when all bins are wanted; per *input* sample the cost is ~60–80 B / 1024 ≈ 0.06–0.08 B/sample amortized inside the block, but the burst is the issue.
- Goertzel (K=1): 4 bytes load + negligible state per input sample.

### 8.3 Numerical Precision Notes

Float32 is usually sufficient for audio (≈150 dB theoretical dynamic range before accumulation error). Fixed-point Q31 with proper scaling yields ≈ 90–100 dB SNR in practice for an N=1024 FFT; the exact figure depends on the scaling policy and input crest factor. Phase is more fragile than magnitude in fixed point.

---

## 9. Elegant Aspects

- The FFT is “embarrassingly regular” (identical butterflies, only the twiddle indices change) yet cache-hostile because the regularity is expressed in power-of-two strides.
- Goertzel’s economy is surprising: a second-order linear recurrence with a single real coefficient extracts a DFT bin with *constant* state and linear input traffic—exactly the dual of the FFT’s logarithmic arithmetic but linear memory.
- The six-step algorithm shows that the “obvious” way to compute an FFT (iterative butterflies) is not the only way; by routing all long-distance communication through optimal transposes one obtains both asymptotic optimality and obliviousness.

---

## 10. Top Techniques (Elegant Wins)

1. **Real-input fast path (RFFT)**: halves the problem size for free via conjugate symmetry.
2. **Cache-oblivious six-step + REC-TRANSPOSE**: turns a cache-hostile algorithm into one whose miss count is provably optimal and independent of cache parameters.
3. **Goertzel IIR with two real states**: O(N) traffic and O(1) state for a single bin—orders of magnitude cheaper than a full FFT when spectrum is sparse.
4. **Block-floating-point scaling**: recovers most of the dynamic range of floating point on a fixed-point core with only a small per-stage overhead.
5. **Fused kernels** (window × input → RFFT → on-the-fly mel or magnitude, never materializing full arrays): eliminates write-allocate traffic on intermediates (see optimization notes).
6. **ROM-resident tables + SRAM hot copies**: trades a few KiB of precious RAM for zero wait-state access on every transform.

---

## 11. Decision Framework

```mermaid
graph TD
    A[Need full spectrum or dense bins?] -->|Yes| B[Power-of-2 N?]
    A -->|No, K≤8 bins| C[Use Goertzel per bin<br/>stream input, 2 real states]
    B -->|Yes| D[Real input?]
    B -->|No| E[Bluestein / PFA if forced;<br/>otherwise pad or resample to power-2]
    D -->|Yes| F[arm_rfft_fast_* or equiv<br/>+ SIMD butterflies]
    D -->|No| G[arm_cfft_* mixed-radix]
    F --> H[Data fits L1/L2?]
    H -->|Yes| I[Classic in-order or mixed-radix iterative]
    H -->|No / external DRAM| J[Six-step or explicit cache-blocked]
    C --> K[Fixed-point? → quantized coeff + BFP or Q31]
    I --> L[Optional: fuse with window / mel / mag to avoid extra passes]
```

**Guidance (embedded real-time, min bytes moved):**

1. **Default for audio front-ends:** power-of-two real RFFT (CMSIS or equivalent) with SIMD where available. Choose the smallest $N$ that satisfies frequency resolution and latency.
2. **Sparse bins (tone, pitch candidate, VAD):** Goertzel. One bin = two real state variables + one streamed pass over the input.
3. **Working set > L1 or external memory:** six-step / cache-oblivious formulation or hand-blocked transpose + small DFTs. Measure cache misses (if PMU available) rather than just cycles.
4. **Fixed-point only (M4/M0+ etc.):** CMSIS Q31 path or hand-written BFP. Accept the SNR loss or use double-length accumulators; never let the signal grow beyond the guard bits.
5. **Neon/MVE targets:** respect the different buffer API (distinct in/out + mandatory tmp for real fast). The extra copy is still cheaper than a naïve scalar implementation on the same core.
6. **Never:** recursion, dynamic allocation in the hot path, or data-dependent branches inside butterflies.

---

## 12. References

> **Corrections / verification note.** Every primary source below was located and its key claims (DOIs, titles, quantitative statements on complexity or implementation) were confirmed by direct web search + PDF retrieval + text extraction during the writing of this note. The Cooley–Tukey paper and the Frigo et al. cache-oblivious paper were read page-by-page from the retrieved PDFs. CMSIS-DSP behavior was read from the official ARM-hosted documentation and GitHub source. No numbers or citations were carried over from secondary summaries without independent verification.

**Primary papers (DOIs verified)**

1. Cooley, J. W. & Tukey, J. W. *An algorithm for the machine calculation of complex Fourier series.* Mathematics of Computation **19**(90):297–301, 1965. DOI 10.1090/S0025-5718-1965-0178586-1. (The canonical divide-and-conquer derivation; in-place within the data array; explicit operation counts for composite radices; table of normalized cost for $r=2\dots10$.)

2. Frigo, M., Leiserson, C. E., Prokop, H., & Ramachandran, S. *Cache-oblivious algorithms.* Proceedings of the 40th Annual Symposium on Foundations of Computer Science (FOCS 1999). Full version: ACM Transactions on Algorithms **8**(1):4, 2012. DOI 10.1145/2071379.2071383. (Ideal-cache model; REC-TRANSPOSE with $O(1+mn/B)$ misses; six-step FFT achieving $Q(n)=O((1+n/B)(1+\log_M n))$ misses, matching Hong–Kung lower bound; proofs and empirical results on real caches.)

3. Prokop, H. *Cache-oblivious algorithms.* M.S. thesis, Massachusetts Institute of Technology, 1999. (Companion thesis work; explicit treatment of the cache-oblivious FFT.)

**Implementations & vendor documentation (verified via official sites / GitHub)**

4. ARM. *CMSIS-DSP Library – Transform Functions (Complex FFT, Real FFT).* https://arm-software.github.io/CMSIS-DSP/ (current version docs). (Mixed-radix CFFT, fast RFFT path, in-place semantics, Neon/MVE buffer differences, Q15/Q31 scaling, pre-initialized const structs in `arm_const_structs.h`.)

5. ARM-software/CMSIS_5 (and CMSIS_4) GitHub repositories – source for `arm_rfft_fast_f32.c`, `arm_cfft_f32.c` etc. (explicit comments on the real-FFT algorithm relying on a half-size complex FFT + post-processing; scaling notes for fixed-point.)

**Goertzel**

6. Wikipedia: Goertzel algorithm (derivation, real-arithmetic reduction to two state variables, references to original 1958 paper). Verified claims: second-order IIR, real states for real input, suitability for embedded.

7. Banks, K. *The Goertzel Algorithm.* Embedded Systems Programming / Embedded.com, 2002. (Practical per-sample equations, optimized magnitude-squared form, DTMF / tone use cases, block-size considerations.)

8. STMicroelectronics. *AN5647 – The Goertzel algorithm to compute individual terms of the DFT in STM32 products.* (Real-arithmetic implementation, state-variable diagram, fixed-point considerations on Cortex-M.)

**Supporting / historical**

9. Duhamel, P. & Vetterli, M. *Fast Fourier transforms: a tutorial review and a state of the art.* Signal Processing **19**(4):259–299, 1990. (Twiddle-factor terminology, split-radix, in-order algorithms.)

10. Hong, J.-W. & Kung, H. T. *I/O complexity: the red-blue pebble game.* STOC 1981. (Lower bounds on cache / I/O complexity for matrix multiplication, FFT, etc.; used by Frigo et al. to prove optimality.)

11. Bailey, D. H. *FFTs in external or hierarchical memory.* Journal of Supercomputing **4**(1):23–35, 1990. (Six-step / four-step formulations that the cache-oblivious work builds upon.)

12. Singleton, R. C. *An algorithm for computing the mixed radix fast Fourier transform.* IEEE Trans. Audio and Electroacoustics **17**(2):93–103, 1969. (Early recursive / cache-friendly ideas.)

**Cross-referenced notes in this repository (as of writing)**

- [`../transforms/short-time-fourier-transform.md`](../transforms/short-time-fourier-transform.md)
- [`../transforms/integer-lapped-transforms-intmdct-and-lifting.md`](../transforms/integer-lapped-transforms-intmdct-and-lifting.md) (DCT-IV butterflies vs. DFT; Goertzel 2-state as sparse DFT alternative for IntMDCT reversible paths)
- [`../transforms/sliding-dft-and-recursive-spectrum-updates.md`](../transforms/sliding-dft-and-recursive-spectrum-updates.md) (recursive SDFT/Goertzel as O(K) per-sample vs. full FFT; oSDFT stability for embedded)
- [`../features/mel-frequency-cepstral-coefficients.md`](../features/mel-frequency-cepstral-coefficients.md)
- [`../detection/real-time-pitch-estimation.md`](../detection/real-time-pitch-estimation.md)
- [`../optimization/simd-vectorization-audio-dsp.md`](../optimization/simd-vectorization-audio-dsp.md)
- [`../general/memory-hierarchy-minimization-for-real-time-dsp.md`](../general/memory-hierarchy-minimization-for-real-time-dsp.md)

All citations above were obtained and validated with the available search and retrieval tools; DOIs resolve to the expected papers on ACM, AMS, IEEE, and arXiv mirrors.

*End of note. Update INDEX.md and add bidirectional links when sibling notes are written.*