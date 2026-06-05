//! The rate-elastic seam — `Rate` blocks where output-elements-per-input differ
//! from the algorithmic latency, and the element type changes across the seam.
//!
//! A `Map` is rate-1:1 (`out.len == in.len`); these blocks are NOT. A `Framer`
//! emits one windowed frame every `HOP` input samples (`out_per_in = 1:HOP`); an
//! `Stft` emits one spectral frame per hop and an `iStft` reconstructs `HOP`
//! samples per spectral frame; a `Resampler` emits `L` samples per `M` input
//! samples. Each owns an internal clocked ring (the overlap/history buffer), so
//! it is not a pure function of its current input slice — that ring is the
//! defining `Rate` smell. Each declares the two orthogonal rate facts the commit
//! pass needs and the type system cannot infer: the **rate ratio** `out_per_in`
//! and the **group delay** `algorithmic_latency` (measured in the block's own
//! OUTPUT elements). Declaring either without the other is a build error.
//!
//! The pull contract is `pull(self, in, want, out) -> produced`: given `want`
//! output elements demanded and the upstream-produced `in` slice, the block emits
//! up to `want` outputs into `out` and returns the count produced (the executor
//! zero-fills any unproduced tail during latency priming). A `needed_input(want)`
//! companion reports how many input elements `want` outputs require, which the
//! rate scheduler compiles into the upstream demand. The internal ring absorbs
//! any hop-vs-buffer (`HOP ∤ N`) misalignment across calls, so the scheduler never
//! assumes the hop divides the device block.
//!
//! **COLA reconstruction.** `Stft` applies a Hann analysis window; at 50% overlap
//! (`HOP = FRAME/2`) the Hann window satisfies the constant-overlap-add condition
//! `Σ_k w[n − kH] = 1`, so `iStft` reconstructs by plain overlap-add (no synthesis
//! window, no normalization) and `iStft ∘ Stft` is the input delayed by `FRAME −
//! HOP` samples, exact up to FFT round-off. That whole round-trip group delay is
//! the analysis framing's (`Stft.algorithmic_latency`); synthesis adds none
//! (`iStft.algorithmic_latency = 0`). The `FRAME − HOP` delay is what the dry/wet
//! diamond's PDC compensates on the parallel dry path.
//!
//! **Float-only.** The FFT and windowed overlap-add need real arithmetic; the
//! fixed-point spectral path (block-floating-point scaling, accumulator headroom)
//! is the embedded-precision phase, so the integer lane fails loud here, exactly
//! as the fused feedback kernels and `Biquad` do.
//!
//! **Denormal hygiene.** A decaying STFT tail / resampler ringing slips toward
//! subnormal magnitudes; the realtime token's flush-to-zero (set on the audio
//! thread by `enterRealtimeThread`) collapses those so the seam does not provoke
//! the denormal CPU stall — the same protection the feedback kernels rely on.

const std = @import("std");
const types = @import("types.zig");
const numeric = @import("numeric.zig");
const control = @import("control.zig");

fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

fn requireFloat(comptime T: type) void {
    if (!isFloat(T))
        @compileError("pan: the spectral / resampler Rate blocks are float-only — the" ++
            " fixed-point (block-floating-point) spectral path is the embedded-precision" ++
            " phase. Use f32/f64.");
}

fn isPow2(comptime n: usize) bool {
    return n != 0 and (n & (n - 1)) == 0;
}

/// View a mono `Sample(T)` slice as its underlying scalar `[]T` — `Sample(T)` is
/// `Frame(T,.mono)`, layout-identical to a bare `T`, so the reinterpret is exact.
fn scalarsConst(comptime T: type, frames: []const types.Sample(T)) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}
fn scalars(comptime T: type, frames: []types.Sample(T)) []T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}

// ===========================================================================
// Spectral / time-frame port elements
// ===========================================================================

/// `Spectrum(T, bins)` — one spectral frame of `bins` complex bins (the rfft of a
/// real frame keeps `FRAME/2 + 1` non-redundant bins). A named struct carrying a
/// `typeName()`, so it is a legal port element and a pool-class key
/// `(Spectrum(T,bins), want)`; `@sizeOf` is `bins · 2·@sizeOf(T)`.
pub fn Spectrum(comptime T: type, comptime bins: usize) type {
    return struct {
        bin: [bins]std.math.Complex(T) = [_]std.math.Complex(T){.{ .re = 0, .im = 0 }} ** bins,

        pub const lane = T;
        pub const bin_count = bins;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Spectrum({s},{d})", .{ @typeName(T), bins });
        }
    };
}

/// `TimeFrame(T, FRAME)` — one windowed time-domain analysis frame of `FRAME`
/// samples (the `Framer`'s output element). Named struct with a `typeName()`.
pub fn TimeFrame(comptime T: type, comptime FRAME: usize) type {
    return struct {
        s: [FRAME]T = [_]T{0} ** FRAME,

        pub const lane = T;
        pub const frame_len = FRAME;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("TimeFrame({s},{d})", .{ @typeName(T), FRAME });
        }
    };
}

// ===========================================================================
// Split-radix FFT (in place) — the spectral kernel
// ===========================================================================

/// Comptime split-radix twiddle table for an N-point recursion node, stored as
/// planar (struct-of-arrays) real and imaginary lanes so the combine butterfly
/// can vector-load them straight into `@Vector` registers with no per-element
/// deinterleave. `W_N = exp(s·i·2π/N)` with `s = +1` for the inverse transform
/// and `s = -1` for the forward; the node needs `W_N^k` and `W_N^{3k}` for the
/// quarter-range `k ∈ [0, N/4)` (the two odd sub-spectra's twiddles). Computed at
/// compile time, so the table lives in read-only data at zero runtime cost — and
/// because every twiddle is evaluated directly from its own angle (not advanced
/// by a per-step complex rotation), there is no accumulated rotation round-off.
fn SrTwiddle(comptime T: type, comptime N: usize) type {
    const q = N / 4;
    return struct {
        w1_re: [q]T,
        w1_im: [q]T,
        w3_re: [q]T,
        w3_im: [q]T,
    };
}

fn srTwiddle(comptime T: type, comptime N: usize, comptime inverse: bool) SrTwiddle(T, N) {
    const q = N / 4;
    var t: SrTwiddle(T, N) = undefined;
    const sign: T = if (inverse) 1.0 else -1.0;
    var k: usize = 0;
    while (k < q) : (k += 1) {
        const a1: T = sign * 2.0 * std.math.pi * @as(T, @floatFromInt(k)) / @as(T, @floatFromInt(N));
        const a3: T = sign * 2.0 * std.math.pi * @as(T, @floatFromInt(3 * k)) / @as(T, @floatFromInt(N));
        t.w1_re[k] = @cos(a1);
        t.w1_im[k] = @sin(a1);
        t.w3_re[k] = @cos(a3);
        t.w3_im[k] = @sin(a3);
    }
    return t;
}

/// Recursive conjugate-pair split-radix FFT, decimation-in-time, written
/// out-of-place: it computes the `N`-point DFT of the input read at stride `s`
/// (`in[0], in[s], in[2s], …`) and writes the `N` outputs contiguously into
/// `out[0..N]`. Split-radix is the fewest-real-multiply power-of-two FFT: it
/// recurses ONE length-N/2 DFT over the even input samples and TWO length-N/4
/// DFTs over the odd samples split by the L-shaped 4k+1 / 4k+3 decimation, then
/// recombines with the W twiddles. The recombination, for `k ∈ [0, N/4)`, with
/// `E` the even sub-DFT, `O1`/`O3` the two odd sub-DFTs, and `Z1 = W_N^k·O1[k]`,
/// `Z3 = W_N^{3k}·O3[k]`:
///   X[k]       = E[k]      + (Z1 + Z3)
///   X[k+N/2]   = E[k]      − (Z1 + Z3)
///   X[k+N/4]   = E[k+N/4]  − (i·s)·(Z1 − Z3)
///   X[k+3N/4]  = E[k+N/4]  + (i·s)·(Z1 − Z3)
/// where `s = -1` forward / `+1` inverse selects the rotation direction. The even
/// sub-DFT lands in `out[0..N/2]` and the two odd sub-DFTs in `out[N/2..3N/4]`
/// and `out[3N/4..N]`, so the four combine operands `E[k]`, `E[k+N/4]`, `O1[k]`,
/// `O3[k]` are four contiguous quarter-length runs — read planar into vectors,
/// combined, written back, with no strided gather.
fn srfft(
    comptime T: type,
    comptime N: usize,
    comptime inverse: bool,
    out: [*]std.math.Complex(T),
    in: [*]const std.math.Complex(T),
    comptime s: usize,
) void {
    const C = std.math.Complex(T);
    if (N == 1) {
        out[0] = in[0];
        return;
    }
    if (N == 2) {
        // The single radix-2 butterfly: X[0]=x[0]+x[1], X[1]=x[0]−x[1].
        const a = in[0];
        const b = in[s];
        out[0] = .{ .re = a.re + b.re, .im = a.im + b.im };
        out[1] = .{ .re = a.re - b.re, .im = a.im - b.im };
        return;
    }

    const q = N / 4;
    srfft(T, N / 2, inverse, out, in, s * 2); // even samples → out[0..N/2]
    srfft(T, N / 4, inverse, out + N / 2, in + s, s * 4); // odd 4k+1 → out[N/2..3N/4]
    srfft(T, N / 4, inverse, out + 3 * N / 4, in + s * 3, s * 4); // odd 4k+3 → out[3N/4..N]

    const tw = comptime srTwiddle(T, N, inverse);
    const sign: T = if (inverse) 1.0 else -1.0;

    // Vectorize the combine across `k`. The four operand groups are contiguous
    // quarter-length runs (E[0..q] at out[0..q], E[q..2q] at out[q..2q], O1[0..q]
    // at out[2q..3q], O3[0..q] at out[3q..4q]); each is loaded planar (re lanes,
    // im lanes) so the complex multiplies and the L-butterfly add/subtracts are
    // plain lane-wise vector arithmetic. `@Vector` lowers this to NEON/AVX where
    // present and scalarizes correctly where there is none (embedded), so the
    // kernel keeps its no-HAL, runs-on-every-target property. A scalar tail
    // mops up when `q` is not a whole multiple of the vector width.
    const lanes = comptime blk: {
        const w = std.simd.suggestVectorLength(T) orelse 4;
        break :blk if (w <= q) w else q;
    };
    const V = @Vector(lanes, T);

    var k: usize = 0;
    while (k + lanes <= q) : (k += lanes) {
        // Planar deinterleave of the four contiguous complex runs.
        var u_re: V = undefined;
        var u_im: V = undefined;
        var uh_re: V = undefined;
        var uh_im: V = undefined;
        var o1_re: V = undefined;
        var o1_im: V = undefined;
        var o3_re: V = undefined;
        var o3_im: V = undefined;
        var w1_re: V = undefined;
        var w1_im: V = undefined;
        var w3_re: V = undefined;
        var w3_im: V = undefined;
        inline for (0..lanes) |l| {
            u_re[l] = out[k + l].re;
            u_im[l] = out[k + l].im;
            uh_re[l] = out[k + q + l].re;
            uh_im[l] = out[k + q + l].im;
            o1_re[l] = out[k + 2 * q + l].re;
            o1_im[l] = out[k + 2 * q + l].im;
            o3_re[l] = out[k + 3 * q + l].re;
            o3_im[l] = out[k + 3 * q + l].im;
            w1_re[l] = tw.w1_re[k + l];
            w1_im[l] = tw.w1_im[k + l];
            w3_re[l] = tw.w3_re[k + l];
            w3_im[l] = tw.w3_im[k + l];
        }
        // Z1 = W^k·O1, Z3 = W^{3k}·O3 (lane-wise complex multiply).
        const z1_re = o1_re * w1_re - o1_im * w1_im;
        const z1_im = o1_re * w1_im + o1_im * w1_re;
        const z3_re = o3_re * w3_re - o3_im * w3_im;
        const z3_im = o3_re * w3_im + o3_im * w3_re;
        const sp_re = z1_re + z3_re;
        const sp_im = z1_im + z3_im;
        const dm_re = z1_re - z3_re;
        const dm_im = z1_im - z3_im;
        // (i·s)·(Z1−Z3): multiply by i flips/swaps components, s picks direction.
        const sv: V = @splat(sign);
        const idm_re = sv * dm_im;
        const idm_im = -sv * dm_re;
        const x0_re = u_re + sp_re;
        const x0_im = u_im + sp_im;
        const x2_re = u_re - sp_re;
        const x2_im = u_im - sp_im;
        const x1_re = uh_re - idm_re;
        const x1_im = uh_im - idm_im;
        const x3_re = uh_re + idm_re;
        const x3_im = uh_im + idm_im;
        inline for (0..lanes) |l| {
            out[k + l] = .{ .re = x0_re[l], .im = x0_im[l] };
            out[k + 2 * q + l] = .{ .re = x2_re[l], .im = x2_im[l] };
            out[k + q + l] = .{ .re = x1_re[l], .im = x1_im[l] };
            out[k + 3 * q + l] = .{ .re = x3_re[l], .im = x3_im[l] };
        }
    }
    // Scalar tail.
    while (k < q) : (k += 1) {
        const u = out[k];
        const uh = out[k + q];
        const o1 = out[k + 2 * q];
        const o3 = out[k + 3 * q];
        const z1 = C{
            .re = o1.re * tw.w1_re[k] - o1.im * tw.w1_im[k],
            .im = o1.re * tw.w1_im[k] + o1.im * tw.w1_re[k],
        };
        const z3 = C{
            .re = o3.re * tw.w3_re[k] - o3.im * tw.w3_im[k],
            .im = o3.re * tw.w3_im[k] + o3.im * tw.w3_re[k],
        };
        const sp = C{ .re = z1.re + z3.re, .im = z1.im + z3.im };
        const dm = C{ .re = z1.re - z3.re, .im = z1.im - z3.im };
        const idm = C{ .re = sign * dm.im, .im = -sign * dm.re };
        out[k] = .{ .re = u.re + sp.re, .im = u.im + sp.im };
        out[k + 2 * q] = .{ .re = u.re - sp.re, .im = u.im - sp.im };
        out[k + q] = .{ .re = uh.re - idm.re, .im = uh.im - idm.im };
        out[k + 3 * q] = .{ .re = uh.re + idm.re, .im = uh.im + idm.im };
    }
}

/// In-place split-radix Cooley-Tukey FFT over `N` (a power of two) complex
/// samples. `inverse = false` is the forward transform; `inverse = true` is the
/// inverse (scaled by `1/N`). The recursive split-radix kernel is naturally
/// out-of-place, so a single stack scratch buffer holds its result and is copied
/// back — the routine allocates nothing on the heap, takes `N` as a compile-time
/// constant, and (the split-radix recursion and the `@Vector` combine both lower
/// to scalar where there is no vector unit) runs on every target including the
/// freestanding embedded one.
pub fn fftInPlace(comptime T: type, comptime N: usize, data: *[N]std.math.Complex(T), comptime inverse: bool) void {
    comptime std.debug.assert(isPow2(N));
    const C = std.math.Complex(T);

    var scratch: [N]C = undefined;
    srfft(T, N, inverse, &scratch, data, 1);

    if (inverse) {
        const inv_n: T = 1.0 / @as(T, @floatFromInt(N));
        for (data, &scratch) |*d, c| d.* = .{ .re = c.re * inv_n, .im = c.im * inv_n };
    } else {
        @memcpy(data, &scratch);
    }
}

/// Forward REAL-input FFT: `N` real samples → the `N/2 + 1` non-redundant complex
/// bins (the rest are the conjugate mirror). Computed via a single half-length
/// (`N/2`) complex FFT plus an `O(N)` untangle — ~2× cheaper in BOTH compute and
/// working memory than a full complex FFT on real input, and pure scalar
/// arithmetic (no SIMD / no HAL dependency, so it runs on every target including
/// the freestanding embedded one). Pack `z[k] = x[2k] + i·x[2k+1]`, FFT `z`, then
/// recombine the even/odd sub-spectra with the `W_N^k` twiddle.
pub fn rfftForward(comptime T: type, comptime N: usize, re: *const [N]T, out: *[N / 2 + 1]std.math.Complex(T)) void {
    comptime std.debug.assert(N >= 2 and isPow2(N));
    const C = std.math.Complex(T);
    const M = N / 2;
    var z: [M]C = undefined;
    for (0..M) |k| z[k] = .{ .re = re[2 * k], .im = re[2 * k + 1] };
    fftInPlace(T, M, &z, false);
    // W = exp(-i·2π/N); `w` = W^k advanced by a per-step rotation (capture the old
    // components before reassigning — the result-location aliasing footgun).
    const ang: T = -2.0 * std.math.pi / @as(T, @floatFromInt(N));
    const wstep = C{ .re = @cos(ang), .im = @sin(ang) };
    var w = C{ .re = 1, .im = 0 };
    for (0..M + 1) |k| {
        const zk = z[k % M];
        const zm = z[(M - k) % M];
        const zm_c = C{ .re = zm.re, .im = -zm.im }; // conj(z[M-k])
        // Xe = ½(zk + conj(z[M-k])) ; Xo = −½·i·(zk − conj(z[M-k]))
        const xe = C{ .re = 0.5 * (zk.re + zm_c.re), .im = 0.5 * (zk.im + zm_c.im) };
        const d = C{ .re = zk.re - zm_c.re, .im = zk.im - zm_c.im };
        const xo = C{ .re = 0.5 * d.im, .im = -0.5 * d.re };
        const wxo = C{ .re = w.re * xo.re - w.im * xo.im, .im = w.re * xo.im + w.im * xo.re };
        out[k] = .{ .re = xe.re + wxo.re, .im = xe.im + wxo.im };
        const nw_re = w.re * wstep.re - w.im * wstep.im;
        const nw_im = w.re * wstep.im + w.im * wstep.re;
        w = .{ .re = nw_re, .im = nw_im };
    }
}

/// Inverse REAL FFT: the `N/2 + 1` bins → `N` real samples (the exact inverse of
/// `rfftForward`, again via a single `N/2` complex IFFT + an `O(N)` retangle).
fn rfftInverse(comptime T: type, comptime N: usize, bins: *const [N / 2 + 1]std.math.Complex(T), out: *[N]T) void {
    comptime std.debug.assert(N >= 2 and isPow2(N));
    const C = std.math.Complex(T);
    const M = N / 2;
    // W^{-k}: advance by exp(+i·2π/N).
    const ang: T = 2.0 * std.math.pi / @as(T, @floatFromInt(N));
    const wstep = C{ .re = @cos(ang), .im = @sin(ang) };
    var w = C{ .re = 1, .im = 0 };
    var z: [M]C = undefined;
    for (0..M) |k| {
        const xk = bins[k];
        const xm = bins[M - k];
        const xm_c = C{ .re = xm.re, .im = -xm.im }; // conj(X[M-k])
        const xe = C{ .re = 0.5 * (xk.re + xm_c.re), .im = 0.5 * (xk.im + xm_c.im) };
        const d = C{ .re = 0.5 * (xk.re - xm_c.re), .im = 0.5 * (xk.im - xm_c.im) };
        const xo = C{ .re = d.re * w.re - d.im * w.im, .im = d.re * w.im + d.im * w.re }; // W^{-k}·d
        z[k] = .{ .re = xe.re - xo.im, .im = xe.im + xo.re }; // Xe + i·Xo
        const nw_re = w.re * wstep.re - w.im * wstep.im;
        const nw_im = w.re * wstep.im + w.im * wstep.re;
        w = .{ .re = nw_re, .im = nw_im };
    }
    fftInPlace(T, M, &z, true); // inverse (÷M)
    for (0..M) |k| {
        out[2 * k] = z[k].re;
        out[2 * k + 1] = z[k].im;
    }
}

/// The periodic Hann window of length `FRAME`, comptime-computed. Periodic (not
/// symmetric): `w[n] = 0.5·(1 − cos(2π n / FRAME))`, which satisfies the
/// constant-overlap-add identity `Σ_k w[n − k·(FRAME/2)] = 1` at 50% overlap, the
/// property that makes `iStft ∘ Stft` an exact (delayed) identity by plain OLA.
fn hannWindow(comptime T: type, comptime FRAME: usize) [FRAME]T {
    // Generous headroom (× 64, like the sinc-prototype builder): `@setEvalBranchQuota`
    // raises a single global counter for the whole comptime evaluation, so when this
    // window is built deep inside a larger comptime chain (e.g. a pitch-shifter that
    // instantiates a time-stretch that builds this window at a large FRAME) a tight
    // quota would trip the default branch limit. A large FRAME (e.g. 1024) must clear
    // it comfortably.
    @setEvalBranchQuota(FRAME * 64);
    var w: [FRAME]T = undefined;
    for (&w, 0..) |*x, n| {
        const phase = 2.0 * std.math.pi * @as(T, @floatFromInt(n)) / @as(T, @floatFromInt(FRAME));
        x.* = 0.5 * (1.0 - @cos(phase));
    }
    return w;
}

// ===========================================================================
// Framer — Sample -> windowed TimeFrame (Rate, 1:HOP)
// ===========================================================================

/// `Framer(num, FRAME, HOP)` — slice the input stream into overlapping windowed
/// frames: one `TimeFrame(FRAME)` every `HOP` samples (`out_per_in = 1:HOP`). The
/// `FRAME − HOP`-sample overlap lives in an internal history buffer (the ring),
/// so the first frames are partially primed from silence — the `FRAME/HOP − 1`
/// frames of `algorithmic_latency` (measured in output frames).
pub fn Framer(comptime num: numeric.Numeric, comptime FRAME: usize, comptime HOP: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (!isPow2(FRAME)) @compileError("pan: Framer FRAME must be a power of two");
    if (HOP == 0 or HOP > FRAME) @compileError("pan: Framer HOP must satisfy 1 <= HOP <= FRAME");
    const Out = TimeFrame(T, FRAME);
    const window = hannWindow(T, FRAME);
    return struct {
        const Self = @This();

        /// One frame produced per `HOP` input samples.
        pub const out_per_in = .{ 1, HOP };
        /// Group delay in OUTPUT frames: a frame is fully primed only after
        /// `FRAME` samples = `FRAME/HOP` hops, so the first `FRAME/HOP − 1` frames
        /// are partial — that is the analysis latency.
        pub const algorithmic_latency: usize = FRAME / HOP - 1;
        pub const state_size: usize = @sizeOf([FRAME]T) + 2 * @sizeOf(usize);

        /// Circular history of the most-recent `FRAME` samples, zero-primed. The
        /// slot at `cursor` is the OLDEST sample (the next to be overwritten).
        history: [FRAME]T = [_]T{0} ** FRAME,
        /// Write cursor into the circular history.
        cursor: usize = 0,
        /// Samples consumed since the last frame emission (0..HOP). Carries the
        /// sub-`HOP` remainder of a chunk across `pull` calls, so the ring absorbs
        /// `HOP ∤ chunk` misalignment — no input is ever dropped.
        phase: usize = 0,

        /// How many input samples `want` output frames consume: one hop each.
        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return want * HOP;
        }

        pub fn pull(self: *Self, in: []const types.Sample(T), want: usize, out: []Out) usize {
            const xs = scalarsConst(T, in);
            var produced: usize = 0;
            for (xs) |x| {
                self.history[self.cursor] = x;
                self.cursor += 1;
                if (self.cursor == FRAME) self.cursor = 0;
                self.phase += 1;
                if (self.phase == HOP) {
                    self.phase = 0;
                    if (produced < want) {
                        // Gather the FRAME-sample window oldest-first from `cursor`.
                        var c = self.cursor;
                        for (&out[produced].s, window) |*o, w| {
                            o.* = self.history[c] * w;
                            c += 1;
                            if (c == FRAME) c = 0;
                        }
                        produced += 1;
                    }
                }
            }
            return produced;
        }
    };
}

// ===========================================================================
// STFT / iSTFT — the spectral analysis/synthesis Rate pair
// ===========================================================================

/// `Stft(num, FRAME, HOP)` — short-time Fourier transform: one `Spectrum` frame of
/// `FRAME/2 + 1` bins per `HOP` input samples (`out_per_in = 1:HOP`). Applies a
/// Hann analysis window then a radix-2 FFT, keeping the non-redundant half-spectrum
/// of the real input. Paired with `iStft` (matched `FRAME`/`HOP`) it reconstructs
/// the input delayed by `FRAME` samples.
pub fn Stft(comptime num: numeric.Numeric, comptime FRAME: usize, comptime HOP: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (!isPow2(FRAME)) @compileError("pan: Stft FRAME must be a power of two");
    if (HOP == 0 or HOP > FRAME) @compileError("pan: Stft HOP must satisfy 1 <= HOP <= FRAME");
    const BINS = FRAME / 2 + 1;
    const Out = Spectrum(T, BINS);
    const window = hannWindow(T, FRAME);
    return struct {
        const Self = @This();

        pub const out_per_in = .{ 1, HOP };
        /// Analysis priming latency, in OUTPUT frames (`FRAME/HOP − 1`). Times the
        /// per-frame stride `HOP` this is `FRAME − HOP` audio samples — the entire
        /// `Stft → iStft` round-trip group delay (the synthesis adds none).
        pub const algorithmic_latency: usize = FRAME / HOP - 1;
        pub const state_size: usize = @sizeOf([FRAME]T) + 2 * @sizeOf(usize);

        /// Circular history (slot `cursor` = oldest), `phase` carries the sub-`HOP`
        /// remainder across calls so no input is dropped on a `HOP ∤ chunk` pull.
        history: [FRAME]T = [_]T{0} ** FRAME,
        cursor: usize = 0,
        phase: usize = 0,

        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return want * HOP;
        }

        pub fn pull(self: *Self, in: []const types.Sample(T), want: usize, out: []Out) usize {
            const xs = scalarsConst(T, in);
            var produced: usize = 0;
            for (xs) |x| {
                self.history[self.cursor] = x;
                self.cursor += 1;
                if (self.cursor == FRAME) self.cursor = 0;
                self.phase += 1;
                if (self.phase == HOP) {
                    self.phase = 0;
                    if (produced < want) {
                        // Gather the windowed FRAME-sample window (oldest-first) as
                        // REAL samples, then take its real-input FFT (half-spectrum).
                        var frame: [FRAME]T = undefined;
                        var c = self.cursor;
                        for (&frame, window) |*f, w| {
                            f.* = self.history[c] * w;
                            c += 1;
                            if (c == FRAME) c = 0;
                        }
                        rfftForward(T, FRAME, &frame, &out[produced].bin);
                        produced += 1;
                    }
                }
            }
            return produced;
        }
    };
}

/// `iStft(num, FRAME, HOP)` — inverse STFT: reconstruct `HOP` samples per input
/// `Spectrum` frame by mirroring the half-spectrum to a full conjugate-symmetric
/// spectrum, inverse FFT, and overlap-add (`out_per_in = HOP:1`). No synthesis
/// window is needed: the Hann analysis at 50% overlap is constant-overlap-add, so
/// plain OLA reconstructs exactly. The `HOP`-sample synthesis latency plus `Stft`'s
/// `FRAME − HOP` analysis latency gives the `FRAME`-sample round-trip group delay.
pub fn iStft(comptime num: numeric.Numeric, comptime FRAME: usize, comptime HOP: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (!isPow2(FRAME)) @compileError("pan: iStft FRAME must be a power of two");
    if (HOP == 0 or HOP > FRAME) @compileError("pan: iStft HOP must satisfy 1 <= HOP <= FRAME");
    const BINS = FRAME / 2 + 1;
    const In = Spectrum(T, BINS);
    return struct {
        const Self = @This();

        pub const out_per_in = .{ HOP, 1 };
        /// Synthesis adds NO further group delay: frame `k` is overlap-added at
        /// output position `k·HOP` and its earliest `HOP` samples are emitted
        /// immediately, so the whole round-trip delay (`FRAME − HOP`) is the
        /// analysis framing's, carried by `Stft.algorithmic_latency`. (A Rate block
        /// is free to declare zero group delay — latency is orthogonal to the rate
        /// ratio; declaring it, even as 0, is the contract.)
        pub const algorithmic_latency: usize = 0;
        pub const state_size: usize = @sizeOf([FRAME]T) + @sizeOf(usize);

        /// Overlap-add accumulator: the next `FRAME` reconstructed samples.
        overlap: [FRAME]T = [_]T{0} ** FRAME,

        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return (want + HOP - 1) / HOP; // frames needed to cover `want` samples
        }

        pub fn pull(self: *Self, in: []const In, want: usize, out: []types.Sample(T)) usize {
            const ys = scalars(T, out);
            const frames = @min(in.len, want / HOP);
            var k: usize = 0;
            while (k < frames) : (k += 1) {
                // Inverse real FFT of the half-spectrum → FRAME real samples.
                var frame: [FRAME]T = undefined;
                rfftInverse(T, FRAME, &in[k].bin, &frame);
                // Overlap-add: accumulate into the running buffer.
                for (&self.overlap, frame) |*acc, s| acc.* += s;
                // Emit the first HOP samples; shift the accumulator down by HOP.
                @memcpy(ys[k * HOP ..][0..HOP], self.overlap[0..HOP]);
                std.mem.copyForwards(T, self.overlap[0 .. FRAME - HOP], self.overlap[HOP..FRAME]);
                @memset(self.overlap[FRAME - HOP .. FRAME], 0);
            }
            return frames * HOP;
        }
    };
}

// ===========================================================================
// PowerSpectrum — Spectrum -> magnitudes (a rate-1:1 Map, type-changing)
// ===========================================================================

/// `PowerSpectrum(num, bins)` — `|z|²` per bin: a rate-1:1 `Map` from a
/// `Spectrum(bins)` frame to a real `FeatureFrame(bins)` of power values. Element
/// type changes (`Spectrum → FeatureFrame`) but the rate does not, so it is a
/// `Map`, not a `Rate` (the canonical "type-changing feature Map" of the audit).
pub fn PowerSpectrum(comptime num: numeric.Numeric, comptime bins: usize) type {
    const T = num.Lane;
    requireFloat(T);
    const In = Spectrum(T, bins);
    return struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const In, out: []types.FeatureFrame(bins)) void {
            _ = self;
            for (in, out) |frame, *o| {
                for (&o.v, frame.bin) |*p, z| p.* = @floatCast(z.re * z.re + z.im * z.im);
            }
        }
    };
}

// ===========================================================================
// Resampler — rational L:M windowed-sinc resampler (Rate)
// ===========================================================================

/// `Resampler(num, L, M, HALF)` — a linear-phase windowed-sinc rational resampler:
/// `L` output samples per `M` input samples (`out_per_in = L:M`). The prototype is
/// a Hann-windowed sinc of `2·HALF + 1` taps at the upsampled rate, cutoff
/// `π/max(L,M)` (the anti-imaging / anti-aliasing band), with `HALF` taps of group
/// delay. The block keeps an input history ring so the FIR has its left context
/// across `pull` calls.
///
/// `L = M = 1` degenerates to a linear-phase low-pass FIR with a clean,
/// unambiguous group delay of `HALF` output samples — the latency-contract probe;
/// `L ≠ M` is a genuine rate change whose output length tracks the `L:M` ratio.
/// (A full polyphase-partitioned, arbitrary-ratio drift-ASRC is the `VariRate`
/// phase; this is the fixed-ratio polyphase primitive.)
pub fn Resampler(comptime num: numeric.Numeric, comptime L: usize, comptime M: usize, comptime HALF: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (L == 0 or M == 0) @compileError("pan: Resampler L and M must be >= 1");
    if (HALF == 0) @compileError("pan: Resampler HALF (taps each side) must be >= 1");
    const up = @max(L, M);
    const TAPS = 2 * HALF + 1;
    if (HALF % M != 0)
        @compileError("pan: Resampler HALF must be a multiple of M so the group delay is an integer number of output samples");
    const proto = sincProto(T, TAPS, HALF, up, L);
    return struct {
        const Self = @This();

        pub const out_per_in = .{ L, M };
        /// Group delay in OUTPUT samples. The linear-phase prototype delays by
        /// `HALF` taps at the upsampled grid; one output sample is `M` upsampled-grid
        /// steps, so the delay is `HALF/M` output samples (integer by the `HALF % M`
        /// check). For the `L = M = 1` probe this is exactly `HALF`.
        pub const algorithmic_latency: usize = HALF / M;
        pub const state_size: usize = @sizeOf(usize);

        // Stateless within a single whole-stream pull: the signal starts at zero,
        // so the FIR's left context is the implicit zero pre-roll. (Cross-call
        // streaming via an input-history ring is folded into the VariRate ASRC of
        // a later phase; this is the fixed-ratio polyphase primitive.)
        _unused: usize = 0,

        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return (want * M + L - 1) / L; // ceil(want·M/L)
        }

        pub fn pull(self: *Self, in: []const types.Sample(T), want: usize, out: []types.Sample(T)) usize {
            _ = self;
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            var j: usize = 0;
            while (j < want) : (j += 1) {
                // y[j] = Σ_tap proto[tap] · x_up[jM − tap], where the upsampled
                // stream x_up[m] = x[m/L] when L | m, else 0.
                var acc: T = 0;
                var tap: usize = 0;
                while (tap < TAPS) : (tap += 1) {
                    const m = @as(isize, @intCast(j * M)) - @as(isize, @intCast(tap));
                    if (m < 0) continue;
                    if (@mod(m, @as(isize, @intCast(L))) != 0) continue;
                    const in_idx: usize = @intCast(@divFloor(m, @as(isize, @intCast(L))));
                    if (in_idx >= xs.len) continue;
                    acc += proto[tap] * xs[in_idx];
                }
                ys[j] = acc;
            }
            return want;
        }
    };
}

/// Build the windowed-sinc prototype FIR (Hann-windowed, normalized to unity DC
/// gain after polyphase decimation). `up = max(L,M)` is the interpolation factor,
/// cutoff `π/up`; `gain` (= `L`) compensates the polyphase decimation so a DC input
/// passes at unity.
fn sincProto(comptime T: type, comptime TAPS: usize, comptime HALF: usize, comptime up: usize, comptime gain: usize) [TAPS]T {
    @setEvalBranchQuota(TAPS * 64);
    var h: [TAPS]T = undefined;
    const fc: T = 1.0 / @as(T, @floatFromInt(up)); // normalized cutoff (×π)
    var sum: T = 0;
    for (&h, 0..) |*c, i| {
        const n: T = @as(T, @floatFromInt(i)) - @as(T, @floatFromInt(HALF));
        const sinc: T = if (n == 0) fc else @sin(std.math.pi * fc * n) / (std.math.pi * n);
        const wphase = 2.0 * std.math.pi * @as(T, @floatFromInt(i)) / @as(T, @floatFromInt(TAPS - 1));
        const win: T = 0.5 * (1.0 - @cos(wphase));
        c.* = sinc * win;
        sum += sinc * win;
    }
    // Normalize to unity DC gain, then scale by the interpolation gain.
    const g: T = @as(T, @floatFromInt(gain)) / sum;
    for (&h) |*c| c.* *= g;
    return h;
}

// ===========================================================================
// Varispeed — arbitrary-runtime-ratio resampler (VariRate)
// ===========================================================================

/// `Varispeed(num)` — a variable-rate resampler whose out:in ratio is a **live
/// parameter**, not a compile-time constant: a varispeed / scrub / sample-playback
/// pitch control. It is the canonical `VariRate` block — discriminated at comptime
/// not by a point `out_per_in` but by a *bounded rate interval* `rate_bounds`
/// (`{ min, nominal, max }` as `{p, q}` tuples) plus a worst-case `max_latency`.
///
/// **What "bounded interval + worst-case planning" buys you.** The operating ratio
/// can move anywhere in `[min, max]` at runtime, but the static commit plan sizes
/// every buffer and the upstream's per-callback demand on the `min` ratio — the
/// *most* input ever needed to make a given number of outputs — so the footprint
/// stays bounded no matter where the live ratio sits. Latency compensation plans on
/// `max_latency`, the worst delay over the whole interval. Both numbers are fixed at
/// compile time, so a varispeed seam can never silently under-size its input pull.
///
/// **Ratio held per call (no zipper, deterministic sub-blocks).** The operating
/// ratio is sampled exactly **once at the top of each render call** and held across
/// the whole buffer, exactly as any parameter is held — never re-read mid-buffer.
/// That preserves per-call reduction order and makes a sub-block render a strict
/// prefix of a whole-block render. The ratio arrives through `setParam` (the wired
/// parameter edge or an external `set`), so a wired ratio source and a `set` ratio
/// are the same source of the same held value.
///
/// **Determinism.** Driven by a deterministic parameter (automation), the render is
/// a pure function of the input and the ratio schedule — bit-reproducible. (The
/// *other* determinism class — a ratio nudged by a wall-clock drift controller — is
/// inherently empirical and lives in the device-boundary drift resampler, not here.)
///
/// The interpolation is 2-point **linear** between the two bracketing input samples:
/// cheap, low-latency (≤ 1 input sample of lookback), and adequate for varispeed /
/// scrub. A windowed-sinc / cubic kernel is the higher-quality tier and is not
/// implemented here. Mono only (`Sample(T)` is one channel); a multi-channel
/// varispeed would resample each plane with a shared cursor.
pub fn Varispeed(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        // The bounded out:in interval: 1/4× (slowest, the MOST input per output —
        // the worst-case planning endpoint) up to 4× (fastest). Nominal is 1:1.
        pub const rate_bounds = .{ .min = .{ 1, 4 }, .nominal = .{ 1, 1 }, .max = .{ 4, 1 } };
        const min_ratio: f32 = 0.25;
        const max_ratio: f32 = 4.0;
        /// Worst-case group delay in OUTPUT samples over the whole interval. The
        /// linear interpolator looks back at most one input sample; one input sample
        /// is `ratio` output samples, so the worst case is `max_ratio` output samples
        /// rounded up, plus one sample of slack for the fractional bracket.
        pub const max_latency: usize = 5;
        /// The ratio is a deterministic parameter (automation), so the render is
        /// bit-reproducible — the parameter-driven determinism class.
        pub const ratio_source: enum { parameter, internal_controller } = .parameter;
        /// The operating out:in ratio, as a control-rate parameter port (slot 0).
        pub const params = .{ .ratio = types.Scalar(f32) };

        /// Latest published target ratio (atomic; set by the control thread OR the
        /// wired parameter edge). Read once per call on the RT thread (held-per-call).
        target: control.Param = control.Param.init(1.0),
        /// The previous input sample — the left bracket of the linear interpolation.
        /// Persists across calls so the resampler streams continuously; the implicit
        /// pre-roll is silence (`0`).
        prev: T = 0,
        /// Fractional read position in `[0, 1)` between `prev` and the next input
        /// sample. Persists across calls so a fractional remainder is never dropped.
        frac: f64 = 0,

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.target.set(value);
        }

        /// How many input samples `want` outputs consume at the current held ratio.
        /// One output advances the read cursor by `1/ratio` input samples; from the
        /// current fractional position that is `ceil(frac + want/ratio)`, plus one
        /// guard sample for the bracket so the pull can always fill `want`. Monotone
        /// non-decreasing in `want` and non-increasing in the ratio.
        pub fn needed_input(self: *Self, want: usize) usize {
            const r = clampRatio(self.target.read());
            const step = 1.0 / @as(f64, r);
            const span = self.frac + @as(f64, @floatFromInt(want)) * step;
            return @as(usize, @intFromFloat(@ceil(span))) + 1;
        }

        pub fn pull(self: *Self, in: []const types.Sample(T), want: usize, out: []types.Sample(T)) usize {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const r = clampRatio(self.target.read()); // sampled ONCE, held across the call
            const step = 1.0 / @as(f64, r);
            var produced: usize = 0;
            var i: usize = 0; // index of the next-unconsumed input (the right bracket)
            while (produced < want) {
                if (self.frac < 1.0) {
                    // Output reads inside [prev, xs[i]); linear-interpolate. The right
                    // bracket xs[i] is only PEEKED here, not consumed, so the state
                    // resumes cleanly across calls: `prev` is always the last input
                    // actually consumed.
                    if (i >= xs.len) break; // under-fed: stop short of `want`
                    const f: T = @floatCast(self.frac);
                    ys[produced] = self.prev + f * (xs[i] - self.prev);
                    produced += 1;
                    self.frac += step;
                } else {
                    // The read cursor crossed an input boundary: consume xs[i].
                    if (i >= xs.len) break;
                    self.prev = xs[i];
                    i += 1;
                    self.frac -= 1.0;
                }
            }
            return produced;
        }

        /// Clamp a requested ratio into the declared `rate_bounds` interval, so the
        /// measured out:in ratio can never leave `[min, max]` however the parameter
        /// is driven.
        fn clampRatio(v: f32) f32 {
            return @min(@max(v, min_ratio), max_ratio);
        }
    };
}

// ===========================================================================
// TimeStretch — WSOLA time-stretch with a runtime stretch factor (VariRate)
// ===========================================================================

/// `TimeStretch(num, FRAME)` — runtime time-stretching (tempo change WITHOUT pitch
/// change): a `VariRate` SOURCE over an owned mono asset whose output is `stretch`
/// times as long as the input, at a `stretch` factor that varies at runtime.
///
/// It is the **WSOLA** (waveform-similarity overlap-add) realisation. Analysis grains
/// are overlap-added on a fixed 50%-overlap synthesis grid (Hann window, COLA-exact:
/// `win[k] + win[k+FRAME/2] = 1`, so no amplitude normalisation). The variable-rate
/// seam is the *analysis* advance `Sa = (FRAME/2) / stretch`: a larger stretch reads
/// the asset more slowly while the synthesis grid stays fixed, so the output runs
/// longer. The crucial WSOLA step — and the reason this PRESERVES PITCH where a naive
/// overlap-add does not — is that each grain's read position is not taken at the bare
/// nominal advance but **searched within a small window for the offset whose leading
/// half best cross-correlates with the natural continuation of the previous grain**.
/// That alignment keeps the periodic waveform phase-coherent across the overlap, so
/// the output's frequency content is unchanged (only its duration moves). A plain OLA
/// without this search re-introduces a phase jump at every grain boundary and ends up
/// SCALING the frequency (acting as a resampler) instead of stretching time — which
/// is exactly the defect this search removes.
///
/// The stretch factor is a held-per-call `param.stretch` in the bounded interval
/// `[1/2, 2]` (out:in = the stretch), the parameter-driven (reproducible) class. For
/// good low-frequency behaviour `FRAME` should span at least two periods of the
/// lowest tone of interest. Mono.
pub fn TimeStretch(comptime num: numeric.Numeric, comptime FRAME: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (!isPow2(FRAME) or FRAME < 4)
        @compileError("pan: TimeStretch FRAME must be a power of two >= 4");
    const HS = FRAME / 2; // synthesis hop = 50% overlap (Hann COLA-exact)
    const DELTA: isize = @intCast(HS); // waveform-similarity search radius (± one hop)
    const win = hannWindow(T, FRAME);
    return struct {
        const Self = @This();

        // out:in == the stretch factor, in [1/2, 2]. The `min` endpoint (slowest
        // output per input = the most input per output) is the worst-case planner.
        pub const rate_bounds = .{ .min = .{ 1, 2 }, .nominal = .{ 1, 1 }, .max = .{ 2, 1 } };
        const min_stretch: f32 = 0.5;
        const max_stretch: f32 = 2.0;
        /// One full grain of overlap-add priming delay, in output samples.
        pub const max_latency: usize = FRAME;
        pub const ratio_source: enum { parameter, internal_controller } = .parameter;
        pub const params = .{ .stretch = types.Scalar(f32) };

        /// The owned mono asset (borrowed; set at `add`).
        data: []const types.Sample(T) = &.{},
        /// The nominal next analysis position (accumulates `Sa` per grain); the
        /// similarity search picks the actual read position near `round(nat_pos)`.
        nat_pos: f64 = 0,
        /// The last ACCEPTED integer analysis position (the search anchor — the next
        /// grain aligns to the continuation of the grain read here).
        prev_pos: usize = 0,
        /// False until the first grain has been read (the first grain reads at 0 with
        /// no search; subsequent grains search relative to `prev_pos`).
        started: bool = false,
        /// The second half of the previous grain — the overlap-add carry. Persists.
        tail: [HS]T = [_]T{0} ** HS,
        /// The current grain's finalised first-half output, awaiting emission.
        obuf: [HS]T = [_]T{0} ** HS,
        /// Read cursor into `obuf`; `== HS` means "empty, generate the next grain".
        ohead: usize = HS,
        /// Set once the asset has been fully consumed (further output is silence).
        done: bool = false,
        stretch: control.Param = control.Param.init(1.0),

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.stretch.set(value);
        }

        /// Worst-case input demand at the slowest stretch (1/2× ⇒ two input samples
        /// of asset per output). Documentation parity with the `VariRate` contract.
        pub fn needed_input(_: *Self, want: usize) usize {
            return want * 2;
        }

        /// One asset sample, zero outside the asset (the implicit silent pre/post-roll).
        fn at(self: *const Self, i: isize) T {
            if (i < 0) return 0;
            const u: usize = @intCast(i);
            return if (u < self.data.len) self.data[u].ch[0] else 0;
        }

        /// Normalised cross-correlation of the `HS`-sample segment at `a` against the
        /// target segment at `b` — the waveform-similarity score WSOLA maximises.
        fn similarity(self: *const Self, a: isize, b: isize) f64 {
            var dot: f64 = 0;
            var ea: f64 = 0;
            var eb: f64 = 0;
            var k: usize = 0;
            while (k < HS) : (k += 1) {
                const va: f64 = self.at(a + @as(isize, @intCast(k)));
                const vb: f64 = self.at(b + @as(isize, @intCast(k)));
                dot += va * vb;
                ea += va * va;
                eb += vb * vb;
            }
            const denom = @sqrt(ea * eb);
            return if (denom > 1e-20) dot / denom else 0;
        }

        /// Pick the read position near `center` whose leading half best matches the
        /// continuation of the previous grain (`asset[prev_pos+HS ..]`), searching
        /// `±DELTA`. This is the phase-coherence step that makes WSOLA pitch-preserving.
        fn searchPos(self: *const Self, center: isize) usize {
            const target: isize = @as(isize, @intCast(self.prev_pos)) + @as(isize, @intCast(HS));
            var best_delta: isize = 0;
            var best_score: f64 = -2;
            var delta: isize = -DELTA;
            while (delta <= DELTA) : (delta += 1) {
                const score = self.similarity(center + delta, target);
                if (score > best_score) {
                    best_score = score;
                    best_delta = delta;
                }
            }
            const pos = center + best_delta;
            return if (pos < 0) 0 else @intCast(pos);
        }

        /// Read one windowed analysis grain (at the WSOLA-aligned position), overlap-add
        /// its first half with the carried `tail` into `obuf`, stash its second half as
        /// the new `tail`, and advance the nominal analysis cursor by `Sa = HS/stretch`.
        fn genGrain(self: *Self, s: f32) void {
            const sa = @as(f64, HS) / @as(f64, @max(s, min_stretch));
            var pos: usize = 0;
            if (!self.started) {
                self.started = true;
                self.nat_pos = sa;
            } else {
                pos = self.searchPos(@intFromFloat(@round(self.nat_pos)));
                self.nat_pos += sa;
            }
            const p: isize = @intCast(pos);
            var k: usize = 0;
            while (k < HS) : (k += 1) {
                const head = win[k] * self.at(p + @as(isize, @intCast(k)));
                self.obuf[k] = self.tail[k] + head; // 50% Hann COLA: tail + head = unity
                self.tail[k] = win[HS + k] * self.at(p + @as(isize, @intCast(HS + k)));
            }
            self.prev_pos = pos;
            self.ohead = 0;
            if (pos + FRAME >= self.data.len) self.done = true;
        }

        pub fn pull(self: *Self, want: usize, out: []types.Sample(T)) usize {
            const s = @min(@max(self.stretch.read(), min_stretch), max_stretch); // held per call
            var produced: usize = 0;
            while (produced < want) : (produced += 1) {
                if (self.ohead >= HS) {
                    if (self.done) {
                        out[produced].ch[0] = 0;
                        continue;
                    }
                    self.genGrain(s);
                }
                out[produced].ch[0] = self.obuf[self.ohead];
                self.ohead += 1;
            }
            return produced;
        }

        pub fn exhausted(self: *Self) bool {
            return self.done and self.ohead >= HS;
        }
    };
}

// ===========================================================================
// PitchShift — constant-duration pitch shift (TSM ∘ resample)
// ===========================================================================

/// `PitchShift(num, FRAME)` — shift pitch WITHOUT changing duration, by composing the
/// two variable-rate primitives: time-stretch by the pitch factor `P` (longer, same
/// pitch) then resample by `1/P` (back to the original duration, which slides the
/// pitch up by `P`). Net effect: same length, pitch scaled by `P`.
///
/// Because the net out:in rate is exactly 1:1 (duration is preserved), the COMPOSITE
/// is itself rate-preserving — a `Map` SOURCE — even though it is built from two
/// `VariRate` stages internally (a `TimeStretch` and a linear resampler). It owns the
/// inner `TimeStretch` and a 2-point resampling cursor over its output. `param.pitch`
/// (held per call) is the spectral shift factor in `[1/2, 2]` (an octave down to an
/// octave up). Quality inherits the OLA `TimeStretch` tier (phase-blurring on tonal
/// material); a phase-vocoder front-end is the fidelity upgrade.
pub fn PitchShift(comptime num: numeric.Numeric, comptime FRAME: usize) type {
    const T = num.Lane;
    requireFloat(T);
    const Inner = TimeStretch(num, FRAME);
    return struct {
        const Self = @This();
        const min_pitch: f32 = 0.5;
        const max_pitch: f32 = 2.0;

        pub const params = .{ .pitch = types.Scalar(f32) };

        /// The owned mono asset (borrowed; set at `add`). Forwarded to the inner
        /// time-stretch on first use.
        data: []const types.Sample(T) = &.{},
        /// The time-stretch stage (stretches by the pitch factor).
        inner: Inner = .{},
        /// The resample-by-1/P stage's linear-interpolation brackets + phase. The
        /// resampler reads the stretched stream at a step of `P` input-per-output.
        prev: T = 0,
        cur: T = 0,
        frac: f64 = 0,
        primed: bool = false,
        pitch: control.Param = control.Param.init(1.0),

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.pitch.set(value);
        }

        /// Pull one sample from the inner time-stretch stage.
        fn innerOne(self: *Self) T {
            var tmp: [1]types.Sample(T) = undefined;
            _ = self.inner.pull(1, &tmp);
            return tmp[0].ch[0];
        }

        pub fn process(self: *Self, out: []types.Sample(T)) void {
            const p = @min(@max(self.pitch.read(), min_pitch), max_pitch); // held per call
            self.inner.data = self.data; // forward the asset (idempotent)
            self.inner.setParam(0, p); // time-stretch by P (longer, same pitch)
            if (!self.primed) {
                self.prev = self.innerOne();
                self.cur = self.innerOne();
                self.primed = true;
            }
            const step = @as(f64, p); // resample read step = P (slides pitch up by P)
            for (out) |*o| {
                while (self.frac >= 1.0) {
                    self.prev = self.cur;
                    self.cur = self.innerOne();
                    self.frac -= 1.0;
                }
                const f: T = @floatCast(self.frac);
                o.ch[0] = self.prev + f * (self.cur - self.prev);
                self.frac += step;
            }
        }
    };
}

// ===========================================================================
// PartitionedConvolution — uniform-partitioned overlap-add FFT convolution (Rate)
// ===========================================================================

/// `PartitionedConvolution(num, FRAME, HOP, n_partitions)` — uniform-partitioned
/// overlap-add (UPOLA) frequency-domain convolution of the mono input with an
/// impulse response of up to `n_partitions·HOP` taps. A `Sample → Sample`
/// transform whose out:in is exactly 1:1, but it is a `Rate` block (not a `Map`):
/// it owns an internal clocked ring — a frequency-domain delay line of the last
/// `n_partitions` input-block spectra plus a time-domain overlap-add accumulator —
/// so its output is not a pure function of the current input slice. That ring is
/// the defining Rate smell, and it carries `HOP` samples of group delay.
///
/// **How it partitions and why FRAME ≥ 2·HOP.** The IR is sliced into
/// `n_partitions` contiguous blocks of `HOP` taps each (zero-padded if the IR is
/// shorter); block `p` is zero-extended to `FRAME` samples and pre-transformed to
/// its half-spectrum `H[p]` once, at `initialize`. Input is buffered into blocks
/// of `HOP` samples; each full block is zero-extended to `FRAME` and forward-rfft'd
/// to `X`, then pushed into the spectral delay line. The output block's spectrum is
/// the per-bin complex multiply-accumulate `Y = Σ_p X[now−p]·H[p]`, inverse-rfft'd
/// to `FRAME` time samples and overlap-added into a running accumulator; the
/// accumulator's first `HOP` samples are emitted and it shifts down by `HOP`. The
/// linear convolution of one `HOP`-sample input block with one `HOP`-tap IR block
/// has length `2·HOP − 1`; the per-block FFT must be at least that long or the
/// result time-aliases (the circular convolution wraps the tail back over the
/// head), so `FRAME ≥ 2·HOP` is required and enforced. With that, each block
/// product is an exact linear (not circular) convolution and the overlap-add of
/// the `2·HOP − 1`-sample spreads reconstructs the full linear convolution.
///
/// **Latency.** Zero group delay. A block of `HOP` inputs is buffered before its
/// `HOP` outputs can be produced, but that buffering is throughput latency, not
/// group delay: the spectral delay line is indexed so partition `p`'s contribution
/// lands at the correct output sample, so output block `b` carries `Σ_p
/// x_block[b−p] ⊛ h_part[p]` aligned with input block `b`. Convolving with a
/// unit-impulse IR (`ir[0] = 1`, rest 0) therefore returns the input UNSHIFTED (the
/// convolution identity); a general IR's group delay is the IR's own, in its taps.
///
/// **Float-only**, mono. The IR is block data set via `initialize(ir)`; an unset
/// IR convolves with silence (all-zero spectra ⇒ silent output).
pub fn PartitionedConvolution(
    comptime num: numeric.Numeric,
    comptime FRAME: usize,
    comptime HOP: usize,
    comptime n_partitions: usize,
) type {
    const T = num.Lane;
    requireFloat(T);
    if (!isPow2(FRAME)) @compileError("pan: PartitionedConvolution FRAME must be a power of two");
    if (HOP == 0) @compileError("pan: PartitionedConvolution HOP must be >= 1");
    if (FRAME < 2 * HOP)
        @compileError("pan: PartitionedConvolution FRAME must be >= 2·HOP — a HOP-sample" ++
            " block convolved with a HOP-tap IR partition is 2·HOP−1 samples long, so a" ++
            " shorter FFT would time-alias (the circular tail wraps over the head)");
    if (n_partitions == 0) @compileError("pan: PartitionedConvolution n_partitions must be >= 1");
    const BINS = FRAME / 2 + 1;
    const C = std.math.Complex(T);
    return struct {
        const Self = @This();

        /// Same number of samples out as in — convolution is rate-preserving.
        pub const out_per_in = .{ 1, 1 };
        /// Zero group delay. A block of `HOP` inputs is buffered before its `HOP`
        /// outputs are produced, but that is throughput latency, not group delay:
        /// the spectral delay line is indexed so partition `p`'s contribution lands
        /// at the correct output sample, so output block `b` carries `Σ_p
        /// x_block[b−p] ⊛ h_part[p]` aligned with input block `b`. (A Rate block may
        /// declare zero group delay — latency is orthogonal to the rate ratio;
        /// declaring it, even as 0, is the contract.) Convolving with a unit-impulse
        /// IR therefore returns the input UNSHIFTED; a general IR's group delay is
        /// the IR's own, carried in its taps.
        pub const algorithmic_latency: usize = 0;
        pub const state_size: usize = @sizeOf([n_partitions]([BINS]C)) +
            @sizeOf([BINS]C) * n_partitions + @sizeOf([FRAME]T) + 2 * @sizeOf([HOP]T) + 4 * @sizeOf(usize);

        /// IR partition spectra: `ir_spec[p]` is the half-spectrum of IR block `p`
        /// (taps `[p·HOP, p·HOP+HOP)` zero-extended to `FRAME`). Zero until set.
        ir_spec: [n_partitions][BINS]C =
            [_][BINS]C{[_]C{.{ .re = 0, .im = 0 }} ** BINS} ** n_partitions,
        /// Frequency-domain delay line of the most-recent input-block spectra:
        /// `fdl[(head − p) mod n_partitions]` is `X[now − p]`, the input block `p`
        /// blocks ago. A circular buffer indexed by `head`.
        fdl: [n_partitions][BINS]C =
            [_][BINS]C{[_]C{.{ .re = 0, .im = 0 }} ** BINS} ** n_partitions,
        /// Write cursor into `fdl`: the slot holding the most-recently inserted
        /// input-block spectrum.
        head: usize = 0,
        /// Time-domain overlap-add accumulator for the inverse-FFT output spreads.
        overlap: [FRAME]T = [_]T{0} ** FRAME,
        /// The current partially-filled input block (the clocked ring): `fill`
        /// samples accumulated toward the next `HOP`-sample block.
        block: [HOP]T = [_]T{0} ** HOP,
        /// Count of samples in `block` (0..HOP); carries the sub-`HOP` remainder of
        /// a chunk across `pull` calls so no input is dropped on a `HOP ∤ chunk` pull.
        fill: usize = 0,
        /// Completed-but-not-yet-emitted output samples — a FIFO ring. A whole block
        /// produces `HOP` outputs at once; if the caller's `want` is not block-aligned
        /// the leftover is held here and drained on the next `pull`, so no output is
        /// ever lost on a `HOP ∤ want` pull. Capacity `FRAME` (≥ `2·HOP`) absorbs a
        /// sub-`HOP` carry plus one freshly-completed block. `oavail` samples remain,
        /// the oldest at `ohead`, wrapping modulo `FRAME`.
        obuf: [FRAME]T = [_]T{0} ** FRAME,
        ohead: usize = 0,
        oavail: usize = 0,

        /// Install the impulse response (up to `n_partitions·HOP` taps). Each
        /// `HOP`-tap partition is zero-extended to `FRAME` and pre-transformed to
        /// its half-spectrum, so the per-block hot path is a pure spectral MAC.
        /// Taps past `ir.len` (and the zero-extension to `FRAME`) are silence.
        pub fn initialize(self: *Self, ir: []const T) void {
            var p: usize = 0;
            while (p < n_partitions) : (p += 1) {
                var padded: [FRAME]T = [_]T{0} ** FRAME;
                var t: usize = 0;
                while (t < HOP) : (t += 1) {
                    const idx = p * HOP + t;
                    padded[t] = if (idx < ir.len) ir[idx] else 0;
                }
                rfftForward(T, FRAME, &padded, &self.ir_spec[p]);
            }
        }

        /// Out:in is 1:1, so `want` outputs need `want` inputs.
        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return want;
        }

        pub fn pull(self: *Self, in: []const types.Sample(T), want: usize, out: []types.Sample(T)) usize {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            var produced: usize = 0;

            // Drain any output left over from a prior non-block-aligned pull first.
            self.drain(ys, &produced, want);

            // Consume ALL provided input (never drop a sample): each input goes into
            // the block ring; a completed block is convolved and its HOP outputs are
            // appended to the output FIFO; we then drain up to the `want` ceiling.
            // Whatever the `want` budget could not take stays in the FIFO (and a
            // sub-HOP remainder stays in `block`) for the next call. With the 1:1 rate
            // and the scheduler's `needed_input(want) == want` supply, the FIFO holds
            // at most a sub-HOP carry plus one freshly-completed block (≤ FRAME).
            for (xs) |x| {
                self.block[self.fill] = x;
                self.fill += 1;
                if (self.fill < HOP) continue;
                self.fill = 0;

                // The completed input block, zero-extended to FRAME, forward-rfft'd
                // and inserted at the head of the frequency-domain delay line.
                var padded: [FRAME]T = [_]T{0} ** FRAME;
                @memcpy(padded[0..HOP], self.block[0..HOP]);
                self.head = (self.head + 1) % n_partitions;
                rfftForward(T, FRAME, &padded, &self.fdl[self.head]);

                // Y = Σ_p X[now−p]·H[p], a per-bin complex multiply-accumulate over
                // the delay line against the IR partition spectra.
                var acc: [BINS]C = [_]C{.{ .re = 0, .im = 0 }} ** BINS;
                var p: usize = 0;
                while (p < n_partitions) : (p += 1) {
                    const slot = (self.head + n_partitions - p) % n_partitions;
                    const xf = &self.fdl[slot];
                    const hf = &self.ir_spec[p];
                    var b: usize = 0;
                    while (b < BINS) : (b += 1) {
                        // (a+bi)(c+di) = (ac−bd) + (ad+bc)i
                        acc[b].re += xf[b].re * hf[b].re - xf[b].im * hf[b].im;
                        acc[b].im += xf[b].re * hf[b].im + xf[b].im * hf[b].re;
                    }
                }

                // Inverse-rfft to FRAME time samples, overlap-add into the running
                // accumulator. The first HOP samples are this block's finished output;
                // append them to the output FIFO, then shift the accumulator down by
                // HOP and zero the vacated tail.
                var tdom: [FRAME]T = undefined;
                rfftInverse(T, FRAME, &acc, &tdom);
                for (&self.overlap, tdom) |*o, s| o.* += s;
                var k: usize = 0;
                while (k < HOP) : (k += 1) {
                    const w = (self.ohead + self.oavail) % FRAME; // FIFO write index
                    self.obuf[w] = self.overlap[k];
                    self.oavail += 1;
                }
                std.mem.copyForwards(T, self.overlap[0 .. FRAME - HOP], self.overlap[HOP..FRAME]);
                @memset(self.overlap[FRAME - HOP .. FRAME], 0);

                self.drain(ys, &produced, want);
            }
            return produced;
        }

        /// Move buffered output into `ys` up to the `want` ceiling, advancing the
        /// FIFO read cursor; the remainder (if `want` is reached mid-block) stays in
        /// the FIFO for the next call so no output sample is lost.
        fn drain(self: *Self, ys: []T, produced: *usize, want: usize) void {
            while (self.oavail > 0 and produced.* < want) {
                ys[produced.*] = self.obuf[self.ohead];
                self.ohead = (self.ohead + 1) % FRAME;
                self.oavail -= 1;
                produced.* += 1;
            }
        }
    };
}

// ===========================================================================
// SpectralGate — per-bin spectral noise gate (Map, Spectrum -> Spectrum)
// ===========================================================================

/// `SpectralGate(num, bins)` — a spectral noise gate: zero every bin whose
/// magnitude is below the `threshold` parameter, pass the rest unchanged. A
/// per-bin rate-1:1 `Map` over the spectrum stream (`Spectrum → Spectrum`, element
/// type unchanged), so it is a `Map`, not a `Rate`.
///
/// The gate compares `|z|²` against `threshold²` to avoid a per-bin square root
/// (magnitude ≥ threshold ⟺ power ≥ threshold², for non-negative threshold). A bin
/// at exactly the threshold passes (the boundary is inclusive). Float-only.
pub fn SpectralGate(comptime num: numeric.Numeric, comptime bins: usize) type {
    const T = num.Lane;
    requireFloat(T);
    const In = Spectrum(T, bins);
    return struct {
        const Self = @This();

        /// The gate threshold, a magnitude floor. Bins with `|z| < threshold` are
        /// zeroed; `|z| >= threshold` passes unchanged.
        pub const params = .{ .threshold = types.Scalar(f32) };

        threshold: control.Param = control.Param.init(0.0),

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.threshold.set(value);
        }

        pub fn process(self: *Self, in: []const In, out: []In) void {
            const thr: T = @floatCast(self.threshold.read()); // held per call
            const thr2 = thr * thr;
            for (in, out) |frame, *o| {
                for (&o.bin, frame.bin) |*ob, z| {
                    const power = z.re * z.re + z.im * z.im;
                    ob.* = if (power >= thr2) z else .{ .re = 0, .im = 0 };
                }
            }
        }
    };
}

// ===========================================================================
// SpectralEq — per-bin real-gain spectral EQ (Map, Spectrum -> Spectrum)
// ===========================================================================

/// `SpectralEq(num, bins)` — a linear-phase spectral equalizer: multiply each bin
/// by a real (zero-phase) gain from a settable `[bins]f32` curve. A per-bin
/// rate-1:1 `Map` over the spectrum stream (`Spectrum → Spectrum`, element type
/// unchanged), so it is a `Map`, not a `Rate`.
///
/// The gains are REAL (not complex): each bin is multiplied component-wise by
/// `gain[b]`. For a NON-NEGATIVE gain this is zero-phase (it scales the magnitude by
/// `gain[b]` and leaves the phase untouched); a negative gain is exactly a magnitude
/// scale by `|gain[b]|` plus a π phase flip (multiplying by a negative real). The
/// default curve is unity (all gains 1), which is the identity. Float-only.
pub fn SpectralEq(comptime num: numeric.Numeric, comptime bins: usize) type {
    const T = num.Lane;
    requireFloat(T);
    const In = Spectrum(T, bins);
    return struct {
        const Self = @This();

        /// Per-bin real gain curve; unity (identity) until set via `initialize`.
        gain: [bins]f32 = [_]f32{1.0} ** bins,

        /// Install the gain curve. `curve.len` must equal `bins`.
        pub fn initialize(self: *Self, curve: []const f32) void {
            std.debug.assert(curve.len == bins);
            @memcpy(&self.gain, curve);
        }

        pub fn process(self: *Self, in: []const In, out: []In) void {
            for (in, out) |frame, *o| {
                for (&o.bin, frame.bin, self.gain) |*ob, z, g| {
                    const gg: T = @floatCast(g);
                    ob.* = .{ .re = z.re * gg, .im = z.im * gg };
                }
            }
        }
    };
}

// ===========================================================================
// Tests — basic behaviour of the FFT and the Rate pair (compile coverage of
// the generic over f32; the autonomous Yoneda suite owns the full matrix:
// dual-mux, latency-contract, sub-block granularity, reconstruction).
// ===========================================================================

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

test "fft round-trips an impulse and a constant" {
    const C = std.math.Complex(f32);
    // Forward FFT of a unit impulse is all-ones; inverse returns the impulse.
    var d: [8]C = undefined;
    for (&d, 0..) |*c, i| c.* = .{ .re = if (i == 0) 1 else 0, .im = 0 };
    fftInPlace(f32, 8, &d, false);
    for (d) |c| try testing.expectApproxEqAbs(@as(f32, 1), c.re, 1e-5);
    fftInPlace(f32, 8, &d, true);
    try testing.expectApproxEqAbs(@as(f32, 1), d[0].re, 1e-5);
    for (d[1..]) |c| try testing.expectApproxEqAbs(@as(f32, 0), c.re, 1e-5);
}

test "rfft matches a naive DFT and round-trips (irfft∘rfft == identity)" {
    const N = 16;
    var x: [N]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(99);
    for (&x) |*v| v.* = rng.random().float(f32) * 2 - 1;
    // rfft vs an independent naive O(N²) DFT (shares only the math, not the algo).
    var bins: [N / 2 + 1]std.math.Complex(f32) = undefined;
    rfftForward(f32, N, &x, &bins);
    for (0..N / 2 + 1) |k| {
        var re: f32 = 0;
        var im: f32 = 0;
        for (0..N) |n| {
            const ang = -2.0 * std.math.pi * @as(f32, @floatFromInt(k * n)) / @as(f32, @floatFromInt(N));
            re += x[n] * @cos(ang);
            im += x[n] * @sin(ang);
        }
        try testing.expectApproxEqAbs(re, bins[k].re, 1e-3);
        try testing.expectApproxEqAbs(im, bins[k].im, 1e-3);
    }
    // Round-trip.
    var back: [N]f32 = undefined;
    rfftInverse(f32, N, &bins, &back);
    for (x, back) |a, b| try testing.expectApproxEqAbs(a, b, 1e-5);
}

test "Stft -> iStft reconstructs the input delayed by FRAME (COLA, 50% overlap)" {
    const FRAME = 64;
    const HOP = 32;
    var an = Stft(f32num, FRAME, HOP){};
    var sy = iStft(f32num, FRAME, HOP){};

    const N = 512;
    var in: [N]types.Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(7);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;

    const n_frames = N / HOP;
    var spec: [n_frames]Spectrum(f32, FRAME / 2 + 1) = undefined;
    const made = an.pull(&in, n_frames, &spec);
    try testing.expectEqual(@as(usize, n_frames), made);

    var out: [N]types.Sample(f32) = undefined;
    const got = sy.pull(spec[0..made], N, &out);
    try testing.expectEqual(@as(usize, N), got);

    // The round-trip group delay is FRAME − HOP (the analysis framing); past it,
    // overlap-add of the Hann-windowed frames reconstructs exactly: out[n] ==
    // in[n − (FRAME − HOP)]. Check from n = FRAME to be safely in steady state.
    const delay = FRAME - HOP;
    try testing.expectEqual(@as(usize, delay), @as(usize, Stft(f32num, FRAME, HOP).algorithmic_latency * HOP));
    var n: usize = FRAME;
    while (n < N) : (n += 1) {
        try testing.expectApproxEqAbs(in[n - delay].ch[0], out[n].ch[0], 1e-4);
    }
}

test "Resampler L=M=1 is a linear-phase FIR with group delay HALF (latency probe)" {
    const HALF = 8;
    var rs = Resampler(f32num, 1, 1, HALF){};
    const N = 64;
    var in: [N]types.Sample(f32) = undefined;
    for (&in) |*s| s.ch[0] = 0;
    in[0].ch[0] = 1; // unit impulse
    var out: [N]types.Sample(f32) = undefined;
    _ = rs.pull(&in, N, &out);
    // The impulse response peaks at the prototype centre = HALF.
    var peak: usize = 0;
    var peak_v: f32 = 0;
    for (out, 0..) |s, i| {
        if (@abs(s.ch[0]) > peak_v) {
            peak_v = @abs(s.ch[0]);
            peak = i;
        }
    }
    try testing.expectEqual(@as(usize, HALF), peak);
    try testing.expectEqual(@as(usize, HALF), @as(usize, Resampler(f32num, 1, 1, HALF).algorithmic_latency));
}

test "PowerSpectrum is a rate-1:1 Map: |z|^2 per bin" {
    var ps = PowerSpectrum(f32num, 3){};
    var in = [_]Spectrum(f32, 3){.{ .bin = .{ .{ .re = 3, .im = 4 }, .{ .re = 0, .im = 0 }, .{ .re = 1, .im = 0 } } }};
    var out: [1]types.FeatureFrame(3) = undefined;
    ps.process(&in, &out);
    try testing.expectApproxEqAbs(@as(f32, 25), out[0].v[0], 1e-5); // 3²+4²
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].v[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), out[0].v[2], 1e-5);
}

test "the spectral Rate blocks declare both rate facts (classify as Rate)" {
    const port = @import("port.zig");
    try testing.expect(port.classify(Stft(f32num, 64, 32)) == .Rate);
    try testing.expect(port.classify(iStft(f32num, 64, 32)) == .Rate);
    try testing.expect(port.classify(Framer(f32num, 64, 32)) == .Rate);
    try testing.expect(port.classify(Resampler(f32num, 1, 1, 8)) == .Rate);
    try testing.expect(port.classify(PowerSpectrum(f32num, 33)) == .Map);
    // The Rate output/input elements are mintable from `pull`.
    try testing.expect(port.RateInElem(Stft(f32num, 64, 32)) == types.Sample(f32));
    try testing.expect(port.RateOutElem(Stft(f32num, 64, 32)) == Spectrum(f32, 33));
}

// --- PartitionedConvolution -------------------------------------------------

test "PartitionedConvolution classifies as a (Sample->Sample) Rate, zero group delay" {
    const port = @import("port.zig");
    const Conv = PartitionedConvolution(f32num, 16, 8, 4);
    try testing.expect(port.classify(Conv) == .Rate);
    try testing.expect(port.RateInElem(Conv) == types.Sample(f32));
    try testing.expect(port.RateOutElem(Conv) == types.Sample(f32));
    // Zero group delay (the buffering is throughput, not group delay).
    try testing.expectEqual(@as(usize, 0), Conv.algorithmic_latency);
    // Rate ratio is 1:1 (convolution is rate-preserving).
    try testing.expectEqual(@as(usize, 1), Conv.out_per_in[0]);
    try testing.expectEqual(@as(usize, 1), Conv.out_per_in[1]);
}

test "PartitionedConvolution: unit-impulse IR returns the input unshifted (identity)" {
    // ORACLE: convolving with δ[n] is the identity; the block declares zero group
    // delay, so the output must equal the input sample-for-sample. The reference is
    // the raw input series, independent of the block's own path. (The block buffers
    // a HOP-sample block before emitting, so the last partial sub-HOP block of the
    // stream is not yet flushed — only whole blocks are checked.)
    const FRAME = 16;
    const HOP = 8;
    const NP = 4;
    var conv = PartitionedConvolution(f32num, FRAME, HOP, NP){};
    conv.initialize(&[_]f32{1.0}); // δ: only tap 0 is 1, all later taps 0

    const N = 96; // a whole number of HOP blocks
    var in: [N]types.Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(13);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;

    var out: [N]types.Sample(f32) = undefined;
    const got = conv.pull(&in, N, &out);
    try testing.expectEqual(@as(usize, N), got);

    var n: usize = 0;
    while (n < N) : (n += 1) try testing.expectApproxEqAbs(in[n].ch[0], out[n].ch[0], 1e-4);
}

test "PartitionedConvolution: matches a naive O(N·M) time-domain convolution" {
    // ORACLE: an independent, schoolbook linear convolution y[n] = Σ_m h[m]·x[n−m]
    // computed directly in the time domain (shares only the definition of
    // convolution with the FFT path, not the algorithm). The block's output is the
    // same series delayed by its declared HOP latency.
    const FRAME = 32;
    const HOP = 16;
    const NP = 3; // IR up to NP·HOP = 48 taps
    const M = 40; // an IR shorter than the full partition budget (last block partial)
    var ir: [M]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(2027);
    for (&ir) |*h| h.* = rng.random().float(f32) * 2 - 1;

    const N = 128;
    var x: [N]f32 = undefined;
    for (&x) |*v| v.* = rng.random().float(f32) * 2 - 1;

    // Independent naive convolution into a reference series of length N.
    var ref: [N]f32 = [_]f32{0} ** N;
    for (0..N) |n| {
        var acc: f32 = 0;
        for (0..M) |m| {
            if (m <= n) acc += ir[m] * x[n - m];
        }
        ref[n] = acc;
    }

    var conv = PartitionedConvolution(f32num, FRAME, HOP, NP){};
    conv.initialize(&ir);
    var in: [N]types.Sample(f32) = undefined;
    for (&in, x) |*s, v| s.ch[0] = v;
    var out: [N]types.Sample(f32) = undefined;
    _ = conv.pull(&in, N, &out);

    // Zero group delay: out[n] == ref[n] aligned (NP·HOP = 48 >= M = 40 taps, so
    // the whole IR is covered and no tail is dropped within the stream).
    var n: usize = 0;
    while (n < N) : (n += 1) {
        try testing.expectApproxEqAbs(ref[n], out[n].ch[0], 1e-3);
    }
}

test "PartitionedConvolution: HOP ∤ chunk misalignment drops no input (ring carries remainder)" {
    // Pulling in odd-sized chunks must equal one whole-stream pull: the internal
    // block ring carries the sub-HOP remainder across calls. ORACLE: the same
    // block fed the whole stream at once.
    const FRAME = 16;
    const HOP = 8;
    const NP = 2;
    var ir: [10]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(55);
    for (&ir) |*h| h.* = rng.random().float(f32) * 2 - 1;

    const N = 80;
    var in: [N]types.Sample(f32) = undefined;
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;

    var whole = PartitionedConvolution(f32num, FRAME, HOP, NP){};
    whole.initialize(&ir);
    var out_whole: [N]types.Sample(f32) = undefined;
    _ = whole.pull(&in, N, &out_whole);

    var split = PartitionedConvolution(f32num, FRAME, HOP, NP){};
    split.initialize(&ir);
    var out_split: [N]types.Sample(f32) = undefined;
    // Chunk sizes that are not multiples of HOP (5, 7, 5, …) exercise the remainder
    // ring. A Rate block under-produces a chunk until enough input accrues to fill a
    // block, so outputs are appended at the running `done` cursor, not per-chunk.
    var off: usize = 0; // input consumed
    var done: usize = 0; // outputs emitted so far
    const sizes = [_]usize{ 5, 7, 5, 11, 3, 9, 13, 27 };
    var si: usize = 0;
    while (off < N) {
        const want = @min(sizes[si % sizes.len], N - off);
        si += 1;
        const g = split.pull(in[off .. off + want], want, out_split[done..N]);
        try testing.expect(g <= want); // may under-produce; never over-produce
        off += want;
        done += g;
    }
    // Both paths flushed the same whole blocks; compare those.
    var n: usize = 0;
    while (n < done) : (n += 1) try testing.expectApproxEqAbs(out_whole[n].ch[0], out_split[n].ch[0], 1e-5);
}

// --- SpectralGate -----------------------------------------------------------

test "SpectralGate classifies as a (Spectrum->Spectrum) Map" {
    const port = @import("port.zig");
    const Gate = SpectralGate(f32num, 4);
    try testing.expect(port.classify(Gate) == .Map);
    try testing.expect(port.MapInElem(Gate) == Spectrum(f32, 4));
    try testing.expect(port.MapOutElem(Gate) == Spectrum(f32, 4));
}

test "SpectralGate: bins below threshold zero, bins at/above pass unchanged" {
    // ORACLE: a hand-classified expectation per bin. With threshold = 5, a bin of
    // magnitude 5 (|3+4i| = 5) sits exactly at the floor and PASSES; a bin of
    // magnitude < 5 is ZEROED; a large bin passes verbatim.
    var gate = SpectralGate(f32num, 4){};
    gate.setParam(0, 5.0);
    var in = [_]Spectrum(f32, 4){.{
        .bin = .{
            .{ .re = 3, .im = 4 }, // |z| = 5  -> at threshold, passes
            .{ .re = 1, .im = 0 }, // |z| = 1  -> below, zeroed
            .{ .re = 0, .im = 4 }, // |z| = 4  -> below, zeroed
            .{ .re = -10, .im = 0 }, // |z| = 10 -> above, passes
        },
    }};
    var out: [1]Spectrum(f32, 4) = undefined;
    gate.process(&in, &out);
    try testing.expectApproxEqAbs(@as(f32, 3), out[0].bin[0].re, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 4), out[0].bin[0].im, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].bin[1].re, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].bin[1].im, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].bin[2].im, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -10), out[0].bin[3].re, 1e-6);
}

test "SpectralGate: zero threshold is identity (every bin passes)" {
    // ORACLE: with threshold 0, |z| >= 0 is always true, so the gate is the
    // identity — output must equal input bin-for-bin.
    var gate = SpectralGate(f32num, 3){};
    // default threshold is already 0; assert that default is pass-through.
    var in = [_]Spectrum(f32, 3){.{ .bin = .{
        .{ .re = 0.001, .im = -0.002 },
        .{ .re = 7, .im = 8 },
        .{ .re = 0, .im = 0 },
    } }};
    var out: [1]Spectrum(f32, 3) = undefined;
    gate.process(&in, &out);
    for (out[0].bin, in[0].bin) |o, z| {
        try testing.expectApproxEqAbs(z.re, o.re, 1e-9);
        try testing.expectApproxEqAbs(z.im, o.im, 1e-9);
    }
}

// --- SpectralEq -------------------------------------------------------------

test "SpectralEq classifies as a (Spectrum->Spectrum) Map" {
    const port = @import("port.zig");
    const Eq = SpectralEq(f32num, 4);
    try testing.expect(port.classify(Eq) == .Map);
    try testing.expect(port.MapInElem(Eq) == Spectrum(f32, 4));
    try testing.expect(port.MapOutElem(Eq) == Spectrum(f32, 4));
}

test "SpectralEq: a known gain curve scales each bin's magnitude exactly" {
    // ORACLE: a real gain g[b] scales magnitude by g[b] and leaves phase intact, so
    // each output bin equals the input bin times g[b], component-wise. The
    // reference is the hand-multiplied (re·g, im·g), independent of the block.
    var eq = SpectralEq(f32num, 4){};
    eq.initialize(&[_]f32{ 2.0, 0.0, 0.5, 3.0 });
    var in = [_]Spectrum(f32, 4){.{ .bin = .{
        .{ .re = 1, .im = 2 },
        .{ .re = 5, .im = -5 },
        .{ .re = -4, .im = 8 },
        .{ .re = 0, .im = 1 },
    } }};
    var out: [1]Spectrum(f32, 4) = undefined;
    eq.process(&in, &out);
    const g = [_]f32{ 2.0, 0.0, 0.5, 3.0 };
    for (out[0].bin, in[0].bin, g) |o, z, gg| {
        try testing.expectApproxEqAbs(z.re * gg, o.re, 1e-6);
        try testing.expectApproxEqAbs(z.im * gg, o.im, 1e-6);
        // Magnitude scales by exactly gg.
        const mag_in = @sqrt(z.re * z.re + z.im * z.im);
        const mag_out = @sqrt(o.re * o.re + o.im * o.im);
        try testing.expectApproxEqAbs(mag_in * gg, mag_out, 1e-5);
    }
}

test "SpectralEq: a flat unity curve is the identity" {
    // ORACLE: the default curve is all-ones; identity output expected.
    var eq = SpectralEq(f32num, 3){};
    var in = [_]Spectrum(f32, 3){.{ .bin = .{
        .{ .re = 1.5, .im = -2.5 },
        .{ .re = 0, .im = 0 },
        .{ .re = 9, .im = 9 },
    } }};
    var out: [1]Spectrum(f32, 3) = undefined;
    eq.process(&in, &out);
    for (out[0].bin, in[0].bin) |o, z| {
        try testing.expectApproxEqAbs(z.re, o.re, 1e-9);
        try testing.expectApproxEqAbs(z.im, o.im, 1e-9);
    }
}
