//! feat_yoneda_test — the INDEPENDENT-ORACLE (≈) check for the five
//! feature-extraction blocks of `src/feat.zig` (Rms, DominantBand,
//! SpectralCentroid, SpectralFlux, Mfcc). The Yoneda "tests as definition"
//! discipline applied to the analysis side: each block is characterised by ALL
//! its morphisms — every silent / single-peak / flat / monotone-rise / decay /
//! tie input, the flux state carry across calls AND across frames within one
//! call, and the MFCC pipeline against a second, independent mel+DCT oracle.
//!
//! Oracle strategy (Rule 9, hermetic — no SciPy/librosa, no disk):
//! every expectation is recomputed in-test by a DIRECT, NAIVE reimplementation
//! of the doc-comment formula, sharing only the *definition* with pan's block
//! (never its loop/accumulation order). pan and the oracle agree only if both
//! independently compute the documented value. Matching the house style of
//! `tests/spectral_gold_test.zig`. The MFCC oracle rebuilds the mel filterbank
//! and the orthonormal DCT-II basis from the prose conventions (n_mels=26,
//! [0, 24000] Hz, sample_rate=48000, fft_size=2·(bins−1), ln floored at 1e-10).
//!
//! Verified against zig 0.16.0 (zig-0-16 skill loaded, Rules 13/14).

const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});

fn frameOf(comptime bins: usize, vals: [bins]f32) pan.FeatureFrame(bins) {
    return .{ .v = vals };
}

// ===========================================================================
// Comptime classification + element-type surface (the Yoneda "object identity"
// — a block IS its class and its output element).
// ===========================================================================

test "feat: all five blocks classify as Map with the documented output elements" {
    try std.testing.expect(pan.port.classify(pan.feat.Rms(Num, 8)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.DominantBand(Num, 8)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.SpectralCentroid(Num, 8)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.SpectralFlux(Num, 8)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.Mfcc(Num, 8, 4)) == .Map);

    try std.testing.expect(pan.port.MapOutPort(pan.feat.Rms(Num, 8)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.DominantBand(Num, 8)).Elem == pan.Scalar(u16));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralCentroid(Num, 8)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralFlux(Num, 8)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.Mfcc(Num, 8, 4)).Elem == pan.FeatureFrame(4));
}

// ===========================================================================
// Rms — sqrt( mean over bins of power[k] ).
// ===========================================================================

fn rmsOracle(comptime bins: usize, v: [bins]f32) f64 {
    // Independent: sum in a different order (descending) than pan's ascending
    // accumulation, then divide by bins and sqrt.
    var acc: f64 = 0;
    var k: usize = bins;
    while (k > 0) {
        k -= 1;
        acc += @as(f64, v[k]);
    }
    return @sqrt(acc / @as(f64, @floatFromInt(bins)));
}

test "Rms: silent spectrum yields exactly zero" {
    const BINS = 8;
    var b: pan.feat.Rms(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 1 }}; // non-zero sentinel
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "Rms: flat spectrum equals sqrt of the constant power level" {
    const BINS = 8;
    var b: pan.feat.Rms(Num, BINS) = .{};
    // power = 4 in every bin ⇒ mean = 4 ⇒ rms = 2.
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(4))};
    var out = [_]pan.Scalar(f32){.{ .value = 0 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 2), out[0].value, 1e-6);
    try std.testing.expectApproxEqAbs(rmsOracle(BINS, in[0].v), @as(f64, out[0].value), 1e-5);
}

test "Rms: arbitrary spectra match the independent mean-power oracle" {
    const BINS = 6;
    var b: pan.feat.Rms(Num, BINS) = .{};
    const cases = [_][BINS]f32{
        .{ 1, 2, 3, 4, 5, 6 },
        .{ 0, 0, 9, 0, 0, 0 },
        .{ 100, 0.001, 50, 25, 0, 7 },
        .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 },
    };
    for (cases) |c| {
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, c)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(rmsOracle(BINS, c), @as(f64, out[0].value), 1e-4);
    }
}

test "Rms: a batch of frames is mapped one-for-one, statelessly" {
    const BINS = 4;
    var b: pan.feat.Rms(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, .{ 0, 0, 0, 0 }),
        frameOf(BINS, .{ 4, 4, 4, 4 }),
        frameOf(BINS, .{ 1, 0, 0, 0 }),
    };
    var out: [3]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f64, 0), @as(f64, out[0].value), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2), @as(f64, out[1].value), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), @as(f64, out[2].value), 1e-6); // sqrt(1/4)
}

// ===========================================================================
// DominantBand — argmax_k power[k], first index on ties.
// ===========================================================================

test "DominantBand: single-peak spectra resolve to the peak bin for every bin" {
    const BINS = 12;
    var b: pan.feat.DominantBand(Num, BINS) = .{};
    // For each bin, build a spectrum whose only energy is at that bin and assert
    // it is reported. This exercises argmax exactness across the WHOLE index set.
    inline for (0..BINS) |peak| {
        var v: [BINS]f32 = @splat(0.0);
        v[peak] = 1.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(u16){.{ .value = 9999 }};
        b.process(&in, &out);
        try std.testing.expectEqual(@as(u16, @intCast(peak)), out[0].value);
    }
}

test "DominantBand: argmax with first-index tie-break (first max wins)" {
    const BINS = 6;
    var b: pan.feat.DominantBand(Num, BINS) = .{};
    // Two bins share the maximum; the FIRST (lower index) must win — pan uses a
    // strict `>` so a later equal value never displaces the earlier one.
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, .{ 0, 5, 0, 5, 0, 0 }), // tie at 1 and 3 → 1
        frameOf(BINS, .{ 7, 7, 7, 7, 7, 7 }), // all equal → 0
        frameOf(BINS, .{ 0, 0, 0, 0, 0, 3 }), // only the last → 5
    };
    var out: [3]pan.Scalar(u16) = undefined;
    b.process(&in, &out);
    try std.testing.expectEqual(@as(u16, 1), out[0].value);
    try std.testing.expectEqual(@as(u16, 0), out[1].value);
    try std.testing.expectEqual(@as(u16, 5), out[2].value);
}

test "DominantBand: all-zero (silent) spectrum reports bin 0 by convention" {
    const BINS = 8;
    var b: pan.feat.DominantBand(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.Scalar(u16){.{ .value = 9999 }};
    b.process(&in, &out);
    // A flat all-zero spectrum is an all-way tie ⇒ first index ⇒ 0.
    try std.testing.expectEqual(@as(u16, 0), out[0].value);
}

test "DominantBand: matches an independent first-argmax oracle on noisy spectra" {
    const BINS = 16;
    var b: pan.feat.DominantBand(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0xBADC0FFEE);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 32) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = @floatFromInt(rnd.intRangeAtMost(u8, 0, 20));
        // Independent first-argmax: scan, keep strictly-greater only.
        var oracle_k: u16 = 0;
        var best: f32 = v[0];
        for (v, 0..) |p, k| {
            if (p > best) {
                best = p;
                oracle_k = @intCast(k);
            }
        }
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(u16){.{ .value = 0 }};
        b.process(&in, &out);
        try std.testing.expectEqual(oracle_k, out[0].value);
    }
}

// ===========================================================================
// SpectralCentroid — (Σ k·power[k]) / (Σ power[k]); 0 if all-zero.
// ===========================================================================

fn centroidOracle(comptime bins: usize, v: [bins]f32) f64 {
    var numr: f64 = 0;
    var den: f64 = 0;
    for (v, 0..) |p, k| {
        numr += @as(f64, @floatFromInt(k)) * @as(f64, p);
        den += @as(f64, p);
    }
    return if (den > 0) numr / den else 0;
}

test "SpectralCentroid: silent spectrum yields exactly zero (no centroid)" {
    const BINS = 8;
    var b: pan.feat.SpectralCentroid(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 3.14 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "SpectralCentroid: a lone peak sits exactly on its bin index" {
    const BINS = 8;
    var b: pan.feat.SpectralCentroid(Num, BINS) = .{};
    inline for (.{ 0, 1, 5, 7 }) |peak| {
        var v: [BINS]f32 = @splat(0.0);
        v[peak] = 42.0; // magnitude is irrelevant — centroid is the index
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(peak)), out[0].value, 1e-6);
    }
}

test "SpectralCentroid: flat spectrum sits at the mean bin index (bins-1)/2" {
    const BINS = 8;
    var b: pan.feat.SpectralCentroid(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(2.0))};
    var out = [_]pan.Scalar(f32){.{ .value = 0 }};
    b.process(&in, &out);
    // Uniform weight ⇒ centroid = mean(0..bins-1) = (bins-1)/2 = 3.5.
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), out[0].value, 1e-5);
    try std.testing.expectApproxEqAbs(centroidOracle(BINS, in[0].v), @as(f64, out[0].value), 1e-5);
}

test "SpectralCentroid: two-point spectrum is the power-weighted barycentre" {
    const BINS = 8;
    var b: pan.feat.SpectralCentroid(Num, BINS) = .{};
    // power 1 at bin 2, power 3 at bin 6 ⇒ (1·2 + 3·6)/(1+3) = 20/4 = 5.
    var v: [BINS]f32 = @splat(0.0);
    v[2] = 1.0;
    v[6] = 3.0;
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out = [_]pan.Scalar(f32){.{ .value = 0 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), out[0].value, 1e-5);
}

test "SpectralCentroid: matches an independent weighted-mean oracle on noisy spectra" {
    const BINS = 20;
    var b: pan.feat.SpectralCentroid(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0x5EED1234);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 32) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = rnd.float(f32) * 10.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(centroidOracle(BINS, v), @as(f64, out[0].value), 1e-3);
    }
}

// ===========================================================================
// SpectralFlux — sqrt( Σ max(0, power[k]−prev[k])² ); stateful, prev starts 0.
// ===========================================================================

fn fluxOracle(comptime bins: usize, cur: [bins]f32, prev: [bins]f32) f64 {
    var acc: f64 = 0;
    for (cur, prev) |c, p| {
        const d = @as(f64, c) - @as(f64, p);
        if (d > 0) acc += d * d;
    }
    return @sqrt(acc);
}

test "SpectralFlux: silent stream yields zero flux on every hop" {
    const BINS = 8;
    var b: pan.feat.SpectralFlux(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, @splat(0)),
        frameOf(BINS, @splat(0)),
        frameOf(BINS, @splat(0)),
    };
    var out: [3]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    for (out) |o| try std.testing.expectEqual(@as(f32, 0), o.value);
}

test "SpectralFlux: first hop measures the rise from the implicit zero prev" {
    const BINS = 4;
    var b: pan.feat.SpectralFlux(Num, BINS) = .{};
    // prev starts at zero, so the first frame's flux is sqrt(Σ power²) for the
    // positive bins. Here power = {3,4,0,0} ⇒ sqrt(9+16) = 5.
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 3, 4, 0, 0 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), out[0].value, 1e-5);
}

test "SpectralFlux: decays are half-wave rectified to zero, rises are measured" {
    const BINS = 4;
    var b: pan.feat.SpectralFlux(Num, BINS) = .{};
    // hop 0: rise from 0 to {10,10,10,10} ⇒ sqrt(4·100)=20.
    // hop 1: full decay to all-zero ⇒ every diff negative ⇒ rectified to 0.
    // hop 2: partial — {0,0,5,0}; only bin2 rose (from 0) ⇒ sqrt(25)=5.
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, .{ 10, 10, 10, 10 }),
        frameOf(BINS, .{ 0, 0, 0, 0 }),
        frameOf(BINS, .{ 0, 0, 5, 0 }),
    };
    var out: [3]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), out[0].value, 1e-5);
    try std.testing.expectEqual(@as(f32, 0), out[1].value);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), out[2].value, 1e-5);
}

test "SpectralFlux: monotone-rising stream measures the per-hop increment only" {
    const BINS = 3;
    var b: pan.feat.SpectralFlux(Num, BINS) = .{};
    // Each hop adds a fixed increment to every bin; flux should reflect the
    // increment (not the absolute level), proving prev is subtracted each hop.
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, .{ 1, 1, 1 }), // rise from 0 ⇒ sqrt(3)
        frameOf(BINS, .{ 3, 3, 3 }), // +2 each ⇒ sqrt(3·4)=sqrt(12)
        frameOf(BINS, .{ 6, 6, 6 }), // +3 each ⇒ sqrt(3·9)=sqrt(27)
    };
    var out: [3]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f32, 3)), out[0].value, 1e-5);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f32, 12)), out[1].value, 1e-5);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f32, 27)), out[2].value, 1e-5);
}

test "SpectralFlux: state carries across separate process calls (per-instance prev)" {
    const BINS = 4;
    var b: pan.feat.SpectralFlux(Num, BINS) = .{};
    // Call 1 leaves prev = {5,5,5,5}. Call 2 must diff against THAT, not zero.
    const c1 = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 5, 5, 5, 5 })};
    var o1 = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&c1, &o1);

    const c2 = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 8, 5, 5, 5 })}; // only bin0 rose by 3
    var o2 = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&c2, &o2);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), o2[0].value, 1e-5);
}

test "SpectralFlux: a sub-block split equals a whole-block render (S6 granularity)" {
    // The state note: prev advances exactly once per processed frame, so any
    // partition of the frame stream into sub-blocks must yield identical fluxes
    // AND leave prev in the identical state as one whole-block render.
    const BINS = 5;
    var prng = std.Random.DefaultPrng.init(0xF10F10F1);
    const rnd = prng.random();
    const N = 9;
    var frames: [N]pan.FeatureFrame(BINS) = undefined;
    for (&frames) |*f| {
        for (&f.v) |*x| x.* = rnd.float(f32) * 7.0;
    }

    // Whole-block render.
    var whole: pan.feat.SpectralFlux(Num, BINS) = .{};
    var out_whole: [N]pan.Scalar(f32) = undefined;
    whole.process(&frames, &out_whole);

    // Split render at an arbitrary seam (3 | 1 | 5) on a fresh instance.
    var split: pan.feat.SpectralFlux(Num, BINS) = .{};
    var out_split: [N]pan.Scalar(f32) = undefined;
    split.process(frames[0..3], out_split[0..3]);
    split.process(frames[3..4], out_split[3..4]);
    split.process(frames[4..N], out_split[4..N]);

    // 1) Identical outputs.
    for (out_whole, out_split) |w, s| {
        try std.testing.expectApproxEqAbs(@as(f64, w.value), @as(f64, s.value), 1e-6);
    }
    // 2) Identical residual `prev` state (the carry the doc-comment promises).
    for (whole.prev, split.prev) |w, s| {
        try std.testing.expectEqual(w, s);
    }
    // 3) And both match the independent oracle, stepping prev frame by frame.
    var oprev: [BINS]f32 = @splat(0);
    for (frames, out_whole) |f, o| {
        const want = fluxOracle(BINS, f.v, oprev);
        try std.testing.expectApproxEqAbs(want, @as(f64, o.value), 1e-4);
        oprev = f.v;
    }
}

// ===========================================================================
// Mfcc — mel filterbank (n_mels=26 over [0,24000] Hz, sr=48000,
// fft_size=2·(bins−1)) → ln(max(e,1e-10)) → orthonormal DCT-II → first n_coeffs.
//
// Oracle: rebuild the SAME conventions a second, independent way and run the
// pipeline naively. Shares only the documented definition, not the code path.
// ===========================================================================

const ORACLE_N_MELS: usize = 26;
const ORACLE_SR: f64 = 48_000.0;

fn oracleHzToMel(hz: f64) f64 {
    return 2595.0 * std.math.log10(1.0 + hz / 700.0);
}
fn oracleMelToHz(mel: f64) f64 {
    return 700.0 * (std.math.pow(f64, 10.0, mel / 2595.0) - 1.0);
}

fn mfccOracle(
    comptime bins: usize,
    comptime n_coeffs: usize,
    v: [bins]f32,
    out: *[n_coeffs]f64,
) void {
    const n_mels = ORACLE_N_MELS;
    const fft_size: f64 = @floatFromInt(2 * (bins - 1));
    const mel_max = oracleHzToMel(ORACLE_SR / 2.0);

    // Mel band edge points (n_mels+2 equally spaced in mel, mapped back to Hz).
    var pts: [n_mels + 2]f64 = undefined;
    for (&pts, 0..) |*p, i| {
        const mel = mel_max * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_mels + 1));
        p.* = oracleMelToHz(mel);
    }

    // Per-band triangular log energy.
    var log_e: [n_mels]f64 = undefined;
    for (0..n_mels) |m| {
        const lo = pts[m];
        const ce = pts[m + 1];
        const hi = pts[m + 2];
        var e: f64 = 0;
        for (0..bins) |k| {
            const f = @as(f64, @floatFromInt(k)) * ORACLE_SR / fft_size;
            var w: f64 = 0;
            if (f >= lo and f <= ce and ce > lo) {
                w = (f - lo) / (ce - lo);
            } else if (f > ce and f <= hi and hi > ce) {
                w = (hi - f) / (hi - ce);
            }
            e += @as(f64, v[k]) * w;
        }
        log_e[m] = std.math.log(f64, std.math.e, @max(e, 1e-10));
    }

    // Orthonormal DCT-II, keep first n_coeffs.
    const scale0 = std.math.sqrt(1.0 / @as(f64, @floatFromInt(n_mels)));
    const scalei = std.math.sqrt(2.0 / @as(f64, @floatFromInt(n_mels)));
    for (0..n_coeffs) |c| {
        const s = if (c == 0) scale0 else scalei;
        var acc: f64 = 0;
        for (0..n_mels) |m| {
            const arg = std.math.pi * @as(f64, @floatFromInt(c)) *
                (@as(f64, @floatFromInt(m)) + 0.5) / @as(f64, @floatFromInt(n_mels));
            acc += s * @cos(arg) * log_e[m];
        }
        out[c] = acc;
    }
}

test "Mfcc: silent spectrum is the all-floor log → a fixed DCT of a constant" {
    // Every band energy is 0 ⇒ floored to ln(1e-10), a constant vector. The
    // DCT-II of a constant vector is energy ONLY in coefficient 0, all higher
    // coefficients exactly zero — a sharp, falsifiable characterisation.
    const BINS = 257; // fft_size = 512
    const NCO = 13;
    var b: pan.feat.Mfcc(Num, BINS, NCO) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out: [1]pan.FeatureFrame(NCO) = undefined;
    b.process(&in, &out);

    var want: [NCO]f64 = undefined;
    mfccOracle(BINS, NCO, in[0].v, &want);
    for (0..NCO) |c| {
        try std.testing.expectApproxEqAbs(want[c], @as(f64, out[0].v[c]), 1e-4);
    }
    // c0 ≈ sqrt(1/26)·26·ln(1e-10) ; c>=1 ≈ 0.
    const c0 = std.math.sqrt(1.0 / 26.0) * 26.0 * std.math.log(f64, std.math.e, 1e-10);
    try std.testing.expectApproxEqAbs(c0, @as(f64, out[0].v[0]), 1e-3);
    for (1..NCO) |c| try std.testing.expectApproxEqAbs(@as(f64, 0), @as(f64, out[0].v[c]), 1e-3);
}

test "Mfcc: representative spectra match the independent mel+DCT oracle" {
    const BINS = 257; // fft_size = 512, the real-FFT convention
    const NCO = 13;
    var b: pan.feat.Mfcc(Num, BINS, NCO) = .{};

    // Case A: a single mid-frequency tone (one loud bin).
    var tone: [BINS]f32 = @splat(0.0);
    tone[40] = 1000.0;

    // Case B: broadband noise.
    var noise: [BINS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE99);
    const rnd = prng.random();
    for (&noise) |*x| x.* = rnd.float(f32) * 100.0;

    // Case C: a low-frequency emphasis ramp (decaying with bin index).
    var ramp: [BINS]f32 = undefined;
    for (&ramp, 0..) |*x, k| x.* = 50.0 / (@as(f32, @floatFromInt(k)) + 1.0);

    inline for (.{ tone, noise, ramp }) |v| {
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out: [1]pan.FeatureFrame(NCO) = undefined;
        b.process(&in, &out);
        var want: [NCO]f64 = undefined;
        mfccOracle(BINS, NCO, v, &want);
        for (0..NCO) |c| {
            try std.testing.expectApproxEqAbs(want[c], @as(f64, out[0].v[c]), 1e-3);
        }
    }
}

test "Mfcc: a different (bins, n_coeffs) geometry still matches the oracle" {
    // Smaller FFT (fft_size = 2·(33−1) = 64) and a non-default coefficient count,
    // exercising the comptime filterbank/DCT rebuild at another shape.
    const BINS = 33;
    const NCO = 8;
    var b: pan.feat.Mfcc(Num, BINS, NCO) = .{};
    var v: [BINS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(0xABCDEF12);
    const rnd = prng.random();
    for (&v) |*x| x.* = rnd.float(f32) * 30.0;

    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out: [1]pan.FeatureFrame(NCO) = undefined;
    b.process(&in, &out);
    var want: [NCO]f64 = undefined;
    mfccOracle(BINS, NCO, v, &want);
    for (0..NCO) |c| {
        try std.testing.expectApproxEqAbs(want[c], @as(f64, out[0].v[c]), 1e-3);
    }
}

test "Mfcc: batches multiple frames one-for-one (stateless)" {
    const BINS = 65; // fft_size = 128
    const NCO = 6;
    var b: pan.feat.Mfcc(Num, BINS, NCO) = .{};
    var f0: [BINS]f32 = @splat(0.0);
    f0[10] = 500.0;
    var f1: [BINS]f32 = @splat(0.0);
    f1[30] = 500.0;
    const in = [_]pan.FeatureFrame(BINS){ frameOf(BINS, f0), frameOf(BINS, f1) };
    var out: [2]pan.FeatureFrame(NCO) = undefined;
    b.process(&in, &out);

    inline for (.{ f0, f1 }, 0..) |v, i| {
        var want: [NCO]f64 = undefined;
        mfccOracle(BINS, NCO, v, &want);
        for (0..NCO) |c| {
            try std.testing.expectApproxEqAbs(want[c], @as(f64, out[i].v[c]), 1e-3);
        }
    }
}
