//! Spectral / time-frame port elements and the STFT analysis/synthesis Rate pair.
//!
//! `Spectrum` and `TimeFrame` are the named port-element structs; `Framer`, `Stft`,
//! `iStft` are the framing/transform `Rate` blocks (each owns an internal clocked
//! ring — the overlap/history buffer — so it is not a pure function of its current
//! input slice); `PowerSpectrum` is the type-changing rate-1:1 `Map`. The shared
//! FFT kernel and Hann window live in `spectral_common.zig`.
//!
//! COLA reconstruction: `Stft` applies a Hann analysis window; at 50% overlap
//! (`HOP = FRAME/2`) the Hann window satisfies the constant-overlap-add condition
//! `Σ_k w[n − kH] = 1`, so `iStft` reconstructs by plain overlap-add (no synthesis
//! window, no normalization) and `iStft ∘ Stft` is the input delayed by `FRAME −
//! HOP` samples, exact up to FFT round-off. That whole round-trip group delay is
//! the analysis framing's (`Stft.algorithmic_latency`); synthesis adds none
//! (`iStft.algorithmic_latency = 0`).
//!
//! Float-only (the FFT and windowed overlap-add need real arithmetic), declared
//! loud via `requireFloat`.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;
const numeric = core.numeric;

const sc = @import("spectral_common.zig");
const requireFloat = sc.requireFloat;
const isPow2 = sc.isPow2;
const scalarsConst = sc.scalarsConst;
const scalars = sc.scalars;
const rfftForward = sc.rfftForward;
const rfftInverse = sc.rfftInverse;
const hannWindow = sc.hannWindow;

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
// Tests — basic behaviour of the FFT and the Rate pair (compile coverage of
// the generic over f32; the autonomous Yoneda suite owns the full matrix:
// dual-mux, latency-contract, sub-block granularity, reconstruction).
// ===========================================================================

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});
const fftInPlace = sc.fftInPlace;
const Resampler = @import("spectral_timepitch.zig").Resampler;

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
    const port = core.port;
    try testing.expect(port.classify(Stft(f32num, 64, 32)) == .Rate);
    try testing.expect(port.classify(iStft(f32num, 64, 32)) == .Rate);
    try testing.expect(port.classify(Framer(f32num, 64, 32)) == .Rate);
    try testing.expect(port.classify(Resampler(f32num, 1, 1, 8)) == .Rate);
    try testing.expect(port.classify(PowerSpectrum(f32num, 33)) == .Map);
    // The Rate output/input elements are mintable from `pull`.
    try testing.expect(port.RateInElem(Stft(f32num, 64, 32)) == types.Sample(f32));
    try testing.expect(port.RateOutElem(Stft(f32num, 64, 32)) == Spectrum(f32, 33));
}
