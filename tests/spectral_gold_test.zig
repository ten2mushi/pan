//! spectral_gold_test — the INDEPENDENT-ORACLE (≈) check for the spectral seam,
//! the P8 analogue of the GoldVectorTester (testing spec §5.1, Rule 9).
//!
//! The plan's Yoneda dispatch names "Oracle = SciPy STFT/resampler." This file is
//! the HERMETIC, always-on realisation of that intent: the oracle is an
//! INDEPENDENT mathematical reference computed in-test, sharing only the
//! definition (not the algorithm) with pan's implementation, so it is a genuine
//! Rule-9 check with zero external dependency and zero disk (matching the
//! project's hermetic-oracle preference — cf. `harness.fillNoise`). The SciPy
//! cross-validation + on-demand gold-vector generation live in `scripts/generate.py`;
//! the core suite never imports SciPy.
//!
//!   - Stft oracle: a naive O(N²) DFT of the Hann-windowed analysis frame (a
//!     DIFFERENT algorithm from pan's radix-2 real-FFT — they agree only if both
//!     correctly compute the DFT). allclose.
//!   - Resampler oracle: an ANALYTIC pure sinusoid. A low-frequency sine resampled
//!     L:M must remain that sine at the new rate (within the FIR passband), an
//!     analytic ground truth independent of the resampler's filter. allclose.
//!
//! Verified against zig 0.16.0 (zig-0-16 skill loaded, Rules 13/14).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const f32num = pan.numericFor(.f32, .{});
const Sample = pan.Sample;

test "Stft oracle: pan's bins match an independent naive DFT of the windowed frame (≈)" {
    const FRAME = 64;
    const HOP = 32;
    const BINS = FRAME / 2 + 1;
    const N = 8 * FRAME;
    const S = pan.Stft(f32num, FRAME, HOP);
    const Spec = pan.Spectrum(f32, BINS);
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    const spec = try gpa.alloc(Spec, n_frames);
    defer gpa.free(spec);
    h.fillNoise(in, 4242);

    var an = S{};
    const made = an.pull(in, n_frames, spec);
    try std.testing.expectEqual(n_frames, made);

    // The periodic Hann window (the same definition pan uses, computed here
    // independently as the oracle's analysis window).
    var win: [FRAME]f64 = undefined;
    for (&win, 0..) |*w, n| {
        const ph = 2.0 * std.math.pi * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(FRAME));
        w.* = 0.5 * (1.0 - @cos(ph));
    }

    const xs = h.sampleValues(in);
    // Check a few FULLY-PRIMED frames (window covers FRAME real samples ⇒
    // f ≥ FRAME/HOP − 1). Frame f's window is input[(f+1)·HOP−FRAME .. (f+1)·HOP).
    inline for (.{ 3, 5, 7 }) |f| {
        const base: usize = (f + 1) * HOP - FRAME;
        for (0..BINS) |k| {
            var re: f64 = 0;
            var im: f64 = 0;
            for (0..FRAME) |n| {
                const xw = @as(f64, xs[base + n]) * win[n];
                const ang = -2.0 * std.math.pi * @as(f64, @floatFromInt(k * n)) / @as(f64, @floatFromInt(FRAME));
                re += xw * @cos(ang);
                im += xw * @sin(ang);
            }
            try std.testing.expectApproxEqAbs(re, @as(f64, spec[f].bin[k].re), 1e-3);
            try std.testing.expectApproxEqAbs(im, @as(f64, spec[f].bin[k].im), 1e-3);
        }
    }
}

test "Resampler oracle: a pure sinusoid resampled L:M stays that sinusoid (≈, analytic)" {
    // Independent analytic truth: resampling x[n]=sin(2π f0 n) (well below Nyquist
    // and inside the FIR passband) by L:M must yield sin(2π f0·(M/L)·m) — the same
    // continuous tone re-sampled at the new rate. We compare the resampler output
    // to that analytic sine (not to any FFT/DFT), away from the filter's edge
    // transient, under a tolerance that absorbs the windowed-sinc's finite ripple.
    inline for (.{ .{ 2, 1 }, .{ 1, 2 }, .{ 2, 3 } }) |lm| {
        const L = lm[0];
        const M = lm[1];
        const HALF = 24; // generous taps for a tight passband
        const R = pan.Resampler(f32num, L, M, HALF);
        const Nin = 512;
        const Nout = Nin * L / M;
        const gpa = std.testing.allocator;
        const in = try gpa.alloc(Sample(f32), Nin);
        defer gpa.free(in);
        const out = try gpa.alloc(Sample(f32), Nout);
        defer gpa.free(out);

        const f0: f64 = 0.02; // cycles/sample at the INPUT rate (deep in the passband)
        for (in, 0..) |*s, n| s.ch[0] = @floatCast(@sin(2.0 * std.math.pi * f0 * @as(f64, @floatFromInt(n))));
        var rs = R{};
        const produced = rs.pull(in, Nout, out);
        try std.testing.expectEqual(Nout, produced);

        // Output sample m corresponds to input position m·M/L; the group delay is
        // HALF/M output samples, so the tone is delayed by that.
        const gd: f64 = @floatFromInt(R.algorithmic_latency);
        const ys = h.sampleValues(out);
        var m: usize = HALF; // skip the leading filter transient
        while (m < Nout - HALF) : (m += 1) {
            const t_in: f64 = (@as(f64, @floatFromInt(m)) - gd) * @as(f64, M) / @as(f64, L);
            const want: f64 = @sin(2.0 * std.math.pi * f0 * t_in);
            try std.testing.expectApproxEqAbs(want, @as(f64, ys[m]), 5e-2);
        }
    }
}
