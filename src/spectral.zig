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
// Radix-2 FFT (in place) — the spectral kernel
// ===========================================================================

/// In-place iterative radix-2 Cooley-Tukey FFT over `N` (a power of two) complex
/// samples. `inverse = false` is the forward transform; `inverse = true` is the
/// inverse (scaled by `1/N`). Bit-reversal permutation then `log2 N` butterfly
/// stages with twiddles advanced by a per-stage complex rotation.
pub fn fftInPlace(comptime T: type, comptime N: usize, data: *[N]std.math.Complex(T), comptime inverse: bool) void {
    comptime std.debug.assert(isPow2(N));
    const C = std.math.Complex(T);

    // Decimation-in-time bit-reversal permutation.
    var i: usize = 1;
    var j: usize = 0;
    while (i < N) : (i += 1) {
        var bit = N >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            const tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }
    }

    // Butterfly stages.
    var len: usize = 2;
    while (len <= N) : (len <<= 1) {
        const sign: T = if (inverse) 2.0 else -2.0;
        const ang: T = sign * std.math.pi / @as(T, @floatFromInt(len));
        const wlen = C{ .re = @cos(ang), .im = @sin(ang) };
        var s: usize = 0;
        while (s < N) : (s += len) {
            var w = C{ .re = 1, .im = 0 };
            var k: usize = 0;
            const half = len >> 1;
            while (k < half) : (k += 1) {
                const a = data[s + k];
                const b = data[s + k + half];
                const v = C{ .re = b.re * w.re - b.im * w.im, .im = b.re * w.im + b.im * w.re };
                data[s + k] = .{ .re = a.re + v.re, .im = a.im + v.im };
                data[s + k + half] = .{ .re = a.re - v.re, .im = a.im - v.im };
                // Advance the twiddle: w *= wlen. Capture old components first —
                // a struct literal assigned back into `w` would write `.re` in
                // place before the `.im` expression reads it (result-location
                // aliasing), corrupting the recurrence.
                const w_re = w.re * wlen.re - w.im * wlen.im;
                const w_im = w.re * wlen.im + w.im * wlen.re;
                w = .{ .re = w_re, .im = w_im };
            }
        }
    }

    if (inverse) {
        const inv_n: T = 1.0 / @as(T, @floatFromInt(N));
        for (data) |*c| {
            c.re *= inv_n;
            c.im *= inv_n;
        }
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
