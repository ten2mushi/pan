//! Shared spectral primitives for the `spectral_*` family files that `spectral.zig`
//! re-exports: the float guard, power-of-two check, mono-slice scalar view, the
//! from-scratch split-radix FFT kernel (`fftInPlace`, `rfftForward`, `rfftInverse`),
//! and the periodic Hann window. These are used by blocks that now live in more
//! than one family file, so they are factored here rather than duplicated.
//!
//! Float-only: the FFT and windowed overlap-add need real arithmetic; the
//! fixed-point (block-floating-point) spectral path is the embedded-precision
//! phase, so the integer lane fails loud via `requireFloat`.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;

pub fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

pub fn requireFloat(comptime T: type) void {
    if (!isFloat(T))
        @compileError("pan: the spectral / resampler Rate blocks are float-only — the" ++
            " fixed-point (block-floating-point) spectral path is the embedded-precision" ++
            " phase. Use f32/f64.");
}

pub fn isPow2(comptime n: usize) bool {
    return n != 0 and (n & (n - 1)) == 0;
}

/// View a mono `Sample(T)` slice as its underlying scalar `[]T` — `Sample(T)` is
/// `Frame(T,.mono)`, layout-identical to a bare `T`, so the reinterpret is exact.
pub fn scalarsConst(comptime T: type, frames: []const types.Sample(T)) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}
pub fn scalars(comptime T: type, frames: []types.Sample(T)) []T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
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
    // The table loop runs N/4 iterations at compile time; the default 1000
    // backwards-branch quota only covers up to a 2048-point node. Raise it so
    // larger windows (4096, 8192, …) can build their twiddle tables. Comptime
    // only — no runtime cost.
    @setEvalBranchQuota(@max(1000, N * 8));
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
pub fn rfftInverse(comptime T: type, comptime N: usize, bins: *const [N / 2 + 1]std.math.Complex(T), out: *[N]T) void {
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
pub fn hannWindow(comptime T: type, comptime FRAME: usize) [FRAME]T {
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
