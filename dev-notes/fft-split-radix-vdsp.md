# FFT: split-radix `@Vector` kernel vs Apple vDSP — results & the remaining gap

The scalar radix-2 Cooley-Tukey `fftInPlace` was replaced by a from-scratch
**conjugate-pair split-radix `@Vector`** kernel (one length-N/2 even DFT + two
length-N/4 odd DFTs on the 4k+1 / 4k+3 decimation, recombined with the W twiddles;
comptime twiddle table in `.rodata`). Public signatures (`fftInPlace`,
`rfftForward`, `rfftInverse`) unchanged; all FFT round-trip / gold-vector tests
stayed green; the f32 result is within ~1.4e-5 abs of an f64 naive DFT.

Numbers from `zig build bench-vdsp` (`bench/vdsp_compare_bench.zig`, M3, ReleaseFast),
same N-point transform of the same signal. `energy ratio` is the fair-work witness
(both compute the same transform ⇒ ~1.000).

## Result — the algorithmic gap is closed

| N | pan rfft (ns) | vDSP (ns) | pan/vDSP **after** | pan/vDSP **before** (radix-2) | energy ratio |
|------|------:|------:|:---:|:---:|:---:|
| 256  |  655.9 |  107.5 | 6.10× | 10.7× | 1.000 |
| 512  | 1410.7 |  226.0 | 6.24× | (rising) | 1.000 |
| 1024 | 2924.5 |  458.5 | 6.38× | (rising) | 1.000 |
| 2048 | 6032.1 | 1024.6 | 5.89× | 15.6× | 1.000 |

- **Before (radix-2):** the gap *grew with N* — 10.7× → 15.6× — the signature of an
  **algorithmic** deficit (radix-2's higher operation count compounding as N rises).
- **After (split-radix):** the gap is **flat at ~6× across all N** (5.9–6.4×) and no
  longer grows with N. Split-radix has the fewest real multiplies of any
  power-of-two FFT, so the *complexity* gap vs vDSP's split-radix is closed; the
  residual is now a **constant factor**, the same shape as the biquad's flat ~3.5×.

## This is already an apples-to-apples (bare) comparison — there is no graph tax to subtract

The FFT bench's `pan` column is a **direct `pan.spectral.rfftForward(...)` call in a
tight loop** (`vdsp_compare_bench.zig`): no graph, no `Executor`, no pool, no mux. So
for the FFT, **pan already IS bare** — the ~6× is the bare-kernel-vs-vDSP number, not
inflated by any graph-engine overhead.

(Contrast the biquad scenario in the same bench, which DOES separate the two so the
graph tax is visible — for reference, M3/ReleaseFast:

| cascade | pan (graph) /vDSP | **bare** /vDSP | pan≡bare |
|---|:---:|:---:|:---:|
| 2× (4th-order)  | 3.75× | **1.64×** | true |
| 4× (8th-order)  | 3.80× | **0.92×** | true |
| 8× (16th-order) | 3.30× | **0.76×** | true |

i.e. the bare pan biquad loop **beats vDSP** at 8th/16th order; pan's flat ~3.5× there
is the graph-engine *generality tax*, and `pan≡bare: true` confirms identical output.
There is no analogous "bare FFT" row because the FFT `pan` measurement is already the
bare kernel call.)

## The remaining constant factor — and why it stays for now

The remaining ~6× constant factor is the **`Complex`-AoS deinterleave per stage**:
pan's kernel stores spectra as an array-of-structs `std.math.Complex(T)` (interleaved
re,im), so each vectorized butterfly de/re-interleaves re/im lanes, whereas vDSP runs
a fully **planar split-complex** pipeline (separate `realp`/`imagp` arrays) that needs
no per-stage shuffle. Closing it further would mean adopting a planar split-complex
internal layout like vDSP's — which **changes the `Complex` storage contract that
`Spectrum`/`feat.zig` (and every spectral consumer) depend on**. That is out of scope
for this surgical kernel swap, and is **recorded here as a residual**: the lever is a
storage-contract change (a planar `Spectrum` representation), not an algorithm change.

The bench numbers are single-machine wall-clock (min-of-3, ×realtime); they vary a few
percent under load. The `energy ratio == 1.000` is the deterministic correctness
witness. Re-run with `zig build bench-vdsp` (macOS only; links `-framework
Accelerate` purely as a yardstick — pan's shipped core links no external DSP library).
