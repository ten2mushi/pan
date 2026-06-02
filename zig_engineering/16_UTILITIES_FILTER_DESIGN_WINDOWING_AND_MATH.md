# 16: Utilities — Filter Design, Windowing, Math, and Sample Format

`src/utils/` (re-exported as `radio.utils` via `src/utils/index.zig`) holds the
"pure math" helpers that blocks are built on. `index.zig` exposes four submodules —
`math`, `window`, `filter`, and `sample_format` — and pulls every utility's tests in
with `refAllDecls(@This())`. Each utility file has a sibling vector file under
`src/vectors/utils/` whose oracles are produced by `generate.py` from NumPy/SciPy.

## filter.zig (213 lines) — FIR design

All functions are comptime-`N` generic and return fixed-size arrays. There is **no
IIR design code in this file** — these are FIR helpers only.

Low-level truncated-ideal-filter taps (sinc-derived):

- `firLowpass(comptime N, cutoff: f32) [N]f32`
- `firHighpass(comptime N, cutoff: f32) [N]f32` — asserts `N` is odd
- `firBandpass(comptime N, cutoffs: struct { f32, f32 }) [N]f32` — asserts `N` is odd
- `firBandstop(comptime N, cutoffs: struct { f32, f32 }) [N]f32` — asserts `N` is odd

`cutoff`/`cutoffs` are normalized to Nyquist (1.0). Each builds the ideal impulse
response `sin(pi*cutoff*arg) / (pi*arg)` with `arg = i - (N-1)/2`, special-casing the
center tap. (`firLowpass` handles even/odd `N`; the other three require odd `N`.)

Windowing layer:

- `firwin(comptime N, h: [N]f32, window_func: WindowFunction, scale_freq: f32) [N]f32`
  — multiplies taps `h` by the (symmetric) window, then normalizes the magnitude
  response at `scale_freq` so the gain there is unity.
- `complexFirwin(comptime N, h: [N]f32, center_freq: f32, window_func, scale_freq) [N]std.math.Complex(f32)`
  — frequency-translates a real prototype to `center_freq`, windows it, and normalizes
  at `scale_freq`.

Top-level convenience designers (truncated taps + window + appropriate scaling
frequency):

- `firwinLowpass(N, cutoff, window_func) [N]f32` — scaled at DC (0.0)
- `firwinHighpass(N, cutoff, window_func) [N]f32` — scaled at Nyquist (1.0)
- `firwinBandpass(N, cutoffs, window_func) [N]f32` — scaled at band center
- `firwinBandstop(N, cutoffs, window_func) [N]f32` — scaled at DC
- `firwinComplexBandpass(N, cutoffs, window_func) [N]std.math.Complex(f32)`
- `firwinComplexBandstop(N, cutoffs, window_func) [N]std.math.Complex(f32)`

These are what `LowpassFilterBlock`, `BandpassFilterBlock`, etc. call at init time.
The reference vectors in `src/vectors/utils/filter.zig` are generated with
`scipy.signal.firwin` (and a hand-written `firwin_complex_*` recipe), so the Zig
implementation must match within the `1e-6` epsilon used by the `"firwin"` /
`"complexFirwin"` tests.

## window.zig (65 lines)

```zig
pub const WindowFunction = enum {
    Rectangular,
    Hamming,
    Hanning,
    Bartlett,
    Blackman,
};

pub fn window(comptime N: comptime_int, func: WindowFunction, periodic: bool) [N]f32
```

There is a single generator, `window(N, func, periodic)`, returning `[N]f32`. Note the
enum member is spelled **`Hanning`** (not `Hann`). "Periodic vs symmetric" is the
`periodic: bool` parameter, not separate functions: it sets the divisor to `N+1`
(periodic, for spectral/FFT use) or `N` (symmetric, for filter design). The formulas
are the standard cosine-sum windows (Hamming `0.54/0.46`, Hanning `0.5/0.5`, Blackman
`0.42/0.5/0.08`), a triangular Bartlett, and a constant `1.0` Rectangular. Vectors are
checked against `scipy.signal.get_window` for both `periodic` values at `1e-6`.

## math.zig (96 lines)

These are small type-dispatching helpers over `f32` and `std.math.Complex(f32)` (each
branches on `T` at comptime and is `unreachable` for other types) — not trig
approximations or demod math:

- `zero(comptime T) T` — additive identity for the type
- `add(comptime T, x, y) T`
- `sub(comptime T, x, y) T`
- `scalarMul(comptime T, x: T, scalar: f32) T` — scale by a real scalar
- `scalarDiv(comptime T, x: T, scalar: f32) T` — divide by a real scalar
- `innerProduct(comptime T, comptime U, x: []const T, y: []const U) T` — dot product;
  supports `(Complex, Complex)`, `(Complex, f32)`, and `(f32, f32)` operand pairings
  and asserts `x.len == y.len`. This is the workhorse used by the FIR filter blocks.

(Other math used by blocks — frequency discriminators, magnitude, etc. — lives in the
blocks themselves and in `std.math.Complex`, not here.)

## sample_format.zig (273 lines)

Conversion between interleaved raw bytes and native `f32` / `std.math.Complex(f32)`
samples. The `SampleFormat` enum enumerates 14 formats — `s8`, `u8`, `{u,s}{16,32}{le,be}`,
and `{f32,f64}{le,be}` — and `SampleFormat.info()` returns each format's backing
`data_type`, `endianness`, `offset`, and `scale`. A comptime `_generate()` builds, per
format, a `Converter` struct of six function pointers:

- `bytesToComplex` / `complexToBytes`
- `bytesToReal` / `realToBytes`
- `bytesToInterleavedReal` / `interleavedRealToBytes`

plus an `ELEMENT_SIZE`. Conversion is `(raw - offset) / scale` going in and
`raw * scale + offset` going out, with byte-swapping applied only when the format's
endianness differs from the host. Each converter has its own generated vector tests
(round-tripping every format through `bytes_*`/`samples_*` oracles).

These utilities are deliberately kept small and dependency-free (libc is only needed
elsewhere, for the dynamic I/O sinks/sources). They are the "standard library" for
block authors.
