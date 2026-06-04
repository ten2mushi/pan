//! feat_spectral_shape_yoneda_test — the INDEPENDENT-ORACLE (≈) check for the
//! eight spectrum-consuming spectral-SHAPE feature blocks of `src/feat.zig`:
//! SpectralRolloff, SpectralFlatness, SpectralEntropy, SpectralSpread,
//! SpectralSkewness, SpectralKurtosis, SpectralCrest and Hfc. The Yoneda
//! "tests as definition" discipline: each block is characterised by ALL its
//! morphisms — silence / flat / single-peak / monotone / tie / boundary-bins
//! inputs, the documented edge-case conventions (0 on silence, 0 when σ=0,
//! flatness & entropy clamped to [0,1], raw-kurtosis≈3 for a Gaussian-like
//! shape), batch one-for-one mapping, and every invariant the doc-comment
//! promises.
//!
//! Oracle strategy (Rule 9, hermetic — no SciPy/librosa/numpy, no disk, no net):
//! every expectation is recomputed in-test by an INDEPENDENT reimplementation
//! of the doc-comment formula. The oracle shares only the *definition* with
//! pan's block — never its loop/accumulation order. Concretely the oracles sum
//! in a DIFFERENT order than pan (e.g. descending-index accumulation, or a
//! pairwise/two-pass split), use different intermediates, and never call
//! pan's `standardizedMoment`/`process`. pan and the oracle agree only if both
//! independently arrive at the documented value. Tolerances are external-oracle
//! ≈ checks (never bit-exact): 1e-4..1e-5 for f32-output features, looser only
//! where catastrophic cancellation in the central moments warrants it.
//!
//! The doc-comment of each block in src/feat.zig is the authoritative spec; the
//! oracles below encode exactly those prose formulas.
//!
//! Verified against zig 0.16.0 (zig-0-16 skill loaded, Rules 13/14).

const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});

fn frameOf(comptime bins: usize, vals: [bins]f32) pan.FeatureFrame(bins) {
    return .{ .v = vals };
}

// ===========================================================================
// Comptime classification + element-type surface (Yoneda "object identity":
// a block IS its port class and its output element type). All eight are
// rate-1:1 Maps emitting Scalar(f32).
// ===========================================================================

test "spectral-shape: all eight blocks classify as Map emitting Scalar(f32)" {
    const B = 8;
    try std.testing.expect(pan.port.classify(pan.feat.SpectralRolloff(Num, B)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.SpectralFlatness(Num, B)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.SpectralEntropy(Num, B)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.SpectralSpread(Num, B)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.SpectralSkewness(Num, B)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.SpectralKurtosis(Num, B)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.SpectralCrest(Num, B)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.Hfc(Num, B)) == .Map);

    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralRolloff(Num, B)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralFlatness(Num, B)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralEntropy(Num, B)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralSpread(Num, B)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralSkewness(Num, B)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralKurtosis(Num, B)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralCrest(Num, B)).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.Hfc(Num, B)).Elem == pan.Scalar(f32));
}

// ===========================================================================
// SpectralRolloff — smallest k with Σ_{j≤k} power[j] ≥ 0.85·total; 0 if all-zero.
// ===========================================================================

const ROLLOFF_FRACTION: f64 = 0.85;

/// Independent rolloff: build the full cumulative-power vector FIRST (a
/// different intermediate than pan's running break-on-threshold loop), compute
/// total separately by descending-index summation, then scan for the first
/// index whose cumulative reaches the threshold. Returns 0 on all-zero.
fn rolloffOracle(comptime bins: usize, v: [bins]f32) u16 {
    var total: f64 = 0;
    var k: usize = bins;
    while (k > 0) {
        k -= 1;
        total += @as(f64, v[k]);
    }
    if (total <= 0) return 0;
    const thresh = ROLLOFF_FRACTION * total;
    var cum: [bins]f64 = undefined;
    var acc: f64 = 0;
    for (v, 0..) |p, i| {
        acc += @as(f64, p);
        cum[i] = acc;
    }
    for (cum, 0..) |c, i| {
        if (c >= thresh) return @intCast(i);
    }
    // Σ over all bins == total ≥ 0.85·total always, so last bin is the fallback.
    return @intCast(bins - 1);
}

test "SpectralRolloff: silent spectrum yields bin 0 by convention" {
    const BINS = 8;
    var b: pan.feat.SpectralRolloff(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 7 }}; // sentinel
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "SpectralRolloff: a lone peak puts the rolloff exactly on that bin" {
    const BINS = 16;
    var b: pan.feat.SpectralRolloff(Num, BINS) = .{};
    // All energy at one bin ⇒ cumulative reaches 100% ( ≥ 85% ) exactly there.
    inline for (.{ 0, 1, 7, 9, 15 }) |peak| {
        var v: [BINS]f32 = @splat(0.0);
        v[peak] = 33.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectEqual(@as(f32, @floatFromInt(peak)), out[0].value);
        try std.testing.expectEqual(rolloffOracle(BINS, v), @as(u16, @intFromFloat(out[0].value)));
    }
}

test "SpectralRolloff: flat spectrum hits 0.85 at ceil(0.85·bins)-1" {
    const BINS = 20;
    var b: pan.feat.SpectralRolloff(Num, BINS) = .{};
    // Uniform power: cumulative after bin k is (k+1)/bins of the total. The first
    // k with (k+1)/20 ≥ 0.85 is k+1 ≥ 17 ⇒ k = 16.
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(2.0))};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 16), out[0].value);
    try std.testing.expectEqual(rolloffOracle(BINS, in[0].v), @as(u16, @intFromFloat(out[0].value)));
}

test "SpectralRolloff: threshold is inclusive (≥, not >) at an exact boundary" {
    const BINS = 4;
    var b: pan.feat.SpectralRolloff(Num, BINS) = .{};
    // total = 100; 0.85·total = 85. Cumulative: 50, 85, 90, 100.
    // Bin 1 reaches EXACTLY 85, and the ≥ test must accept it (not skip to bin 2).
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 50, 35, 5, 10 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 1), out[0].value);
    try std.testing.expectEqual(rolloffOracle(BINS, in[0].v), @as(u16, 1));
}

test "SpectralRolloff: matches the independent cumulative oracle on noisy spectra" {
    const BINS = 24;
    var b: pan.feat.SpectralRolloff(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0x12340987);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 40) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = rnd.float(f32) * 9.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectEqual(rolloffOracle(BINS, v), @as(u16, @intFromFloat(out[0].value)));
    }
}

test "SpectralRolloff: batch of frames mapped one-for-one, statelessly" {
    const BINS = 6;
    var b: pan.feat.SpectralRolloff(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, @splat(0)), // silent ⇒ 0
        frameOf(BINS, .{ 0, 0, 0, 0, 0, 10 }), // all at last ⇒ 5
        frameOf(BINS, .{ 100, 0, 0, 0, 0, 0 }), // all at first ⇒ 0
    };
    var out: [3]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
    try std.testing.expectEqual(@as(f32, 5), out[1].value);
    try std.testing.expectEqual(@as(f32, 0), out[2].value);
}

// ===========================================================================
// SpectralFlatness — geomean/arithmean (Wiener entropy), ε=1e-20 log floor,
// clamped to [0,1]; 0 when arithmetic mean is 0.
// ===========================================================================

/// Independent flatness: compute the arithmetic mean by descending-index sum and
/// the geometric mean as a PRODUCT of nth-roots (per_bin = max(p,ε)^(1/bins))
/// rather than pan's sum-of-logs/exp — a genuinely different intermediate that
/// nonetheless realizes the same exp((1/bins)Σln) definition. Clamp to [0,1].
fn flatnessOracle(comptime bins: usize, v: [bins]f32) f64 {
    const nf: f64 = @floatFromInt(bins);
    var sum: f64 = 0;
    var k: usize = bins;
    while (k > 0) {
        k -= 1;
        sum += @as(f64, v[k]);
    }
    const arith = sum / nf;
    if (arith <= 0) return 0;
    var geo: f64 = 1;
    for (v) |p| {
        const floored = @max(@as(f64, p), 1e-20);
        geo *= std.math.pow(f64, floored, 1.0 / nf);
    }
    return std.math.clamp(geo / arith, 0.0, 1.0);
}

test "SpectralFlatness: silent spectrum yields 0 by convention (mean 0)" {
    const BINS = 8;
    var b: pan.feat.SpectralFlatness(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 0.5 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "SpectralFlatness: a perfectly flat (constant) spectrum is exactly 1" {
    const BINS = 16;
    var b: pan.feat.SpectralFlatness(Num, BINS) = .{};
    // geomean == arithmean == c for any constant c>0 ⇒ ratio 1.
    inline for (.{ 0.25, 1.0, 7.5, 1000.0 }) |c| {
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(c))};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(@as(f32, 1), out[0].value, 1e-5);
        try std.testing.expectApproxEqAbs(flatnessOracle(BINS, in[0].v), @as(f64, out[0].value), 1e-5);
    }
}

test "SpectralFlatness: a single peak (one huge bin, rest tiny) is near 0 (tonal)" {
    const BINS = 32;
    var b: pan.feat.SpectralFlatness(Num, BINS) = .{};
    // One dominant bin pulls arithmean up while geomean stays low ⇒ ratio ≈ 0.
    var v: [BINS]f32 = @splat(1e-6);
    v[5] = 1000.0;
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expect(out[0].value < 0.05);
    try std.testing.expectApproxEqAbs(flatnessOracle(BINS, v), @as(f64, out[0].value), 1e-4);
}

test "SpectralFlatness: output stays inside [0,1] for many random spectra" {
    const BINS = 24;
    var b: pan.feat.SpectralFlatness(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0xF1A7_FACE);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 60) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        // Mix of scales so the AM/GM ratio sweeps the whole [0,1] band.
        for (&v) |*x| x.* = std.math.pow(f32, 10.0, rnd.float(f32) * 6.0 - 3.0);
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expect(out[0].value >= 0.0 and out[0].value <= 1.0);
        try std.testing.expectApproxEqRel(flatnessOracle(BINS, v), @as(f64, out[0].value), 1e-4);
    }
}

test "SpectralFlatness: a zero bin is log-floored (ε), not -inf — finite result" {
    const BINS = 4;
    var b: pan.feat.SpectralFlatness(Num, BINS) = .{};
    // bin 0 is exactly 0: ln floored at 1e-20 keeps log_sum finite; arithmean>0
    // so the block must emit a finite, oracle-matching value (not NaN/0).
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 0, 4, 4, 4 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expect(std.math.isFinite(out[0].value));
    try std.testing.expectApproxEqRel(flatnessOracle(BINS, in[0].v), @as(f64, out[0].value), 1e-4);
}

// ===========================================================================
// SpectralEntropy — (−Σ q ln q)/ln(bins), q=power/total; clamped to [0,1]; 0 if
// all-zero. Requires bins ≥ 2 (compile guard).
// ===========================================================================

/// Independent entropy: build the probability vector q FIRST (two-pass: total by
/// descending sum, then q), accumulate −Σ q ln q in a separate pass, divide by
/// ln(bins). Different ordering/intermediate from pan's single fused pass.
fn entropyOracle(comptime bins: usize, v: [bins]f32) f64 {
    var total: f64 = 0;
    var k: usize = bins;
    while (k > 0) {
        k -= 1;
        total += @as(f64, v[k]);
    }
    if (total <= 0) return 0;
    var q: [bins]f64 = undefined;
    for (v, 0..) |p, i| q[i] = @as(f64, p) / total;
    var h: f64 = 0;
    for (q) |qi| {
        if (qi > 0) h -= qi * @log(qi);
    }
    return h / @log(@as(f64, @floatFromInt(bins)));
}

test "SpectralEntropy: silent spectrum yields 0 by convention" {
    const BINS = 8;
    var b: pan.feat.SpectralEntropy(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 0.5 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "SpectralEntropy: a uniform spectrum saturates the normalizer at exactly 1" {
    const BINS = 13;
    var b: pan.feat.SpectralEntropy(Num, BINS) = .{};
    // q_k = 1/bins ⇒ H = ln(bins); divided by ln(bins) ⇒ 1 (the maximum).
    inline for (.{ 0.7, 5.0, 250.0 }) |c| {
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(c))};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(@as(f32, 1), out[0].value, 1e-5);
        try std.testing.expectApproxEqAbs(entropyOracle(BINS, in[0].v), @as(f64, out[0].value), 1e-5);
    }
}

test "SpectralEntropy: a single occupied bin is exactly 0 (all mass on one q)" {
    const BINS = 16;
    var b: pan.feat.SpectralEntropy(Num, BINS) = .{};
    // q = 1 at the peak, 0 elsewhere ⇒ −1·ln(1) − 0·… = 0.
    inline for (.{ 0, 3, 15 }) |peak| {
        var v: [BINS]f32 = @splat(0.0);
        v[peak] = 42.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].value, 1e-6);
    }
}

test "SpectralEntropy: two equal bins give ln(2)/ln(bins)" {
    const BINS = 8;
    var b: pan.feat.SpectralEntropy(Num, BINS) = .{};
    // Mass split equally over two bins ⇒ H = ln 2; normalized by ln 8.
    var v: [BINS]f32 = @splat(0.0);
    v[1] = 5.0;
    v[6] = 5.0;
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    const want: f32 = @floatCast(@log(@as(f64, 2)) / @log(@as(f64, 8)));
    try std.testing.expectApproxEqAbs(want, out[0].value, 1e-5);
    try std.testing.expectApproxEqAbs(entropyOracle(BINS, v), @as(f64, out[0].value), 1e-5);
}

test "SpectralEntropy: stays in [0,1] and matches the oracle on random spectra" {
    const BINS = 20;
    var b: pan.feat.SpectralEntropy(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0xE17120BB);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 60) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = rnd.float(f32) * 100.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expect(out[0].value >= -1e-6 and out[0].value <= 1.0 + 1e-6);
        try std.testing.expectApproxEqAbs(entropyOracle(BINS, v), @as(f64, out[0].value), 1e-5);
    }
}

// ===========================================================================
// SpectralSpread — sqrt( Σ (k−c)²·power / total ), c the centroid; 0 if all-zero.
// ===========================================================================

/// Independent spread: compute centroid and total with descending-index sums,
/// then the variance with a fresh pass; sqrt at the end. (pan accumulates total
/// and c_num together in one ascending pass; this oracle separates concerns.)
fn spreadOracle(comptime bins: usize, v: [bins]f32) f64 {
    var total: f64 = 0;
    var c_num: f64 = 0;
    var k: usize = bins;
    while (k > 0) {
        k -= 1;
        total += @as(f64, v[k]);
        c_num += @as(f64, @floatFromInt(k)) * @as(f64, v[k]);
    }
    if (total <= 0) return 0;
    const c = c_num / total;
    var var_acc: f64 = 0;
    for (v, 0..) |p, i| {
        const d = @as(f64, @floatFromInt(i)) - c;
        var_acc += d * d * @as(f64, p);
    }
    return @sqrt(var_acc / total);
}

test "SpectralSpread: silent spectrum yields 0 by convention" {
    const BINS = 8;
    var b: pan.feat.SpectralSpread(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 9 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "SpectralSpread: a lone peak has exactly zero spread (σ=0)" {
    const BINS = 12;
    var b: pan.feat.SpectralSpread(Num, BINS) = .{};
    inline for (.{ 0, 4, 11 }) |peak| {
        var v: [BINS]f32 = @splat(0.0);
        v[peak] = 17.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].value, 1e-6);
    }
}

test "SpectralSpread: a symmetric two-bin pair has spread = half their gap" {
    const BINS = 8;
    var b: pan.feat.SpectralSpread(Num, BINS) = .{};
    // Equal mass at bins 2 and 6 ⇒ centroid 4, each |k−c| = 2 ⇒ σ = 2.
    var v: [BINS]f32 = @splat(0.0);
    v[2] = 3.0;
    v[6] = 3.0;
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 2), out[0].value, 1e-5);
    try std.testing.expectApproxEqAbs(spreadOracle(BINS, v), @as(f64, out[0].value), 1e-5);
}

test "SpectralSpread: a flat spectrum has the discrete-uniform std deviation" {
    const BINS = 10;
    var b: pan.feat.SpectralSpread(Num, BINS) = .{};
    // Uniform weights over 0..N-1: variance = (N²−1)/12 ⇒ σ = sqrt((100−1)/12).
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(4.0))};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    const want: f32 = @floatCast(@sqrt((100.0 - 1.0) / 12.0));
    try std.testing.expectApproxEqAbs(want, out[0].value, 1e-4);
    try std.testing.expectApproxEqAbs(spreadOracle(BINS, in[0].v), @as(f64, out[0].value), 1e-4);
}

test "SpectralSpread: matches the independent variance oracle on random spectra" {
    const BINS = 32;
    var b: pan.feat.SpectralSpread(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0x59E3AD17);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 50) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = rnd.float(f32) * 50.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqRel(spreadOracle(BINS, v), @as(f64, out[0].value), 1e-4);
    }
}

// ===========================================================================
// SpectralSkewness — ( Σ (k−c)³·power/total ) / σ³; 0 when total=0 or σ=0.
// SpectralKurtosis — ( Σ (k−c)⁴·power/total ) / σ⁴; RAW kurtosis (≈3 Gaussian).
// Independent moment oracle: NEVER calls pan's standardizedMoment.
// ===========================================================================

/// Independent standardized moment of given order. Descending-index sums for
/// centroid/total; explicit pow via repeated multiplication of d (not std.pow)
/// to use a different intermediate path than pan. Returns 0 on total≤0 or σ=0.
fn momentOracle(comptime bins: usize, v: [bins]f32, comptime order: u32) f64 {
    var total: f64 = 0;
    var c_num: f64 = 0;
    var k: usize = bins;
    while (k > 0) {
        k -= 1;
        total += @as(f64, v[k]);
        c_num += @as(f64, @floatFromInt(k)) * @as(f64, v[k]);
    }
    if (total <= 0) return 0;
    const c = c_num / total;
    var var_acc: f64 = 0;
    var mom_acc: f64 = 0;
    for (v, 0..) |p, i| {
        const d = @as(f64, @floatFromInt(i)) - c;
        var dn: f64 = 1;
        comptime var e: u32 = 0;
        inline while (e < order) : (e += 1) dn *= d;
        var_acc += d * d * @as(f64, p);
        mom_acc += dn * @as(f64, p);
    }
    const variance = var_acc / total;
    if (variance <= 0) return 0;
    const sigma = @sqrt(variance);
    var sn: f64 = 1;
    comptime var e2: u32 = 0;
    inline while (e2 < order) : (e2 += 1) sn *= sigma;
    return (mom_acc / total) / sn;
}

test "SpectralSkewness: silent and single-peak spectra are 0 (total=0 / σ=0)" {
    const BINS = 12;
    var b: pan.feat.SpectralSkewness(Num, BINS) = .{};
    // silence
    {
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
        var out = [_]pan.Scalar(f32){.{ .value = 7 }};
        b.process(&in, &out);
        try std.testing.expectEqual(@as(f32, 0), out[0].value);
    }
    // lone peak ⇒ σ=0 ⇒ defined 0 (must NOT be NaN from a /0)
    {
        var v: [BINS]f32 = @splat(0.0);
        v[5] = 88.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = 7 }};
        b.process(&in, &out);
        try std.testing.expect(std.math.isFinite(out[0].value));
        try std.testing.expectEqual(@as(f32, 0), out[0].value);
    }
}

test "SpectralSkewness: a symmetric spectrum has zero skew" {
    const BINS = 9;
    var b: pan.feat.SpectralSkewness(Num, BINS) = .{};
    // Symmetric about bin 4: mirror-image weights ⇒ all odd central moments 0.
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 1, 2, 3, 4, 9, 4, 3, 2, 1 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].value, 1e-4);
    try std.testing.expectApproxEqAbs(momentOracle(BINS, in[0].v, 3), @as(f64, out[0].value), 1e-4);
}

test "SpectralSkewness: a high-bin tail gives positive skew, a low-bin tail negative" {
    const BINS = 16;
    var b: pan.feat.SpectralSkewness(Num, BINS) = .{};
    // Mass clustered low with a long thin high-bin tail ⇒ tail toward higher
    // bins ⇒ positive skew (doc-comment's sign convention).
    var hi: [BINS]f32 = @splat(0.0);
    hi[0] = 50;
    hi[1] = 30;
    hi[2] = 10;
    hi[12] = 2;
    hi[15] = 1;
    {
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, hi)};
        var out = [_]pan.Scalar(f32){.{ .value = 0 }};
        b.process(&in, &out);
        try std.testing.expect(out[0].value > 0);
        try std.testing.expectApproxEqRel(momentOracle(BINS, hi, 3), @as(f64, out[0].value), 1e-3);
    }
    // Mirror it: tail toward LOWER bins ⇒ negative skew of the same magnitude.
    var lo: [BINS]f32 = undefined;
    for (0..BINS) |i| lo[i] = hi[BINS - 1 - i];
    {
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, lo)};
        var out = [_]pan.Scalar(f32){.{ .value = 0 }};
        b.process(&in, &out);
        try std.testing.expect(out[0].value < 0);
        try std.testing.expectApproxEqRel(momentOracle(BINS, lo, 3), @as(f64, out[0].value), 1e-3);
    }
}

test "SpectralSkewness: matches the independent 3rd-moment oracle on random spectra" {
    const BINS = 28;
    var b: pan.feat.SpectralSkewness(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0x5E3012AA);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 50) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = rnd.float(f32) * 40.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(momentOracle(BINS, v, 3), @as(f64, out[0].value), 1e-3);
    }
}

test "SpectralKurtosis: silent and single-peak spectra are 0 (total=0 / σ=0)" {
    const BINS = 12;
    var b: pan.feat.SpectralKurtosis(Num, BINS) = .{};
    {
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
        var out = [_]pan.Scalar(f32){.{ .value = 7 }};
        b.process(&in, &out);
        try std.testing.expectEqual(@as(f32, 0), out[0].value);
    }
    {
        var v: [BINS]f32 = @splat(0.0);
        v[3] = 5.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = 7 }};
        b.process(&in, &out);
        try std.testing.expect(std.math.isFinite(out[0].value));
        try std.testing.expectEqual(@as(f32, 0), out[0].value);
    }
}

test "SpectralKurtosis: two equal bins give the minimum raw kurtosis of 1" {
    const BINS = 8;
    var b: pan.feat.SpectralKurtosis(Num, BINS) = .{};
    // A symmetric two-point distribution: each |k−c| = σ, so (k−c)⁴ = σ⁴ for both
    // ⇒ Σ(k−c)⁴·p/total = σ⁴ ⇒ raw kurtosis = 1 (the theoretical minimum).
    var v: [BINS]f32 = @splat(0.0);
    v[1] = 6.0;
    v[5] = 6.0;
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[0].value, 1e-4);
    try std.testing.expectApproxEqAbs(momentOracle(BINS, v, 4), @as(f64, out[0].value), 1e-4);
}

test "SpectralKurtosis: a discretized Gaussian shape gives RAW kurtosis ≈ 3" {
    // The doc-comment's load-bearing promise: RAW (not excess) kurtosis ⇒ a
    // Gaussian-shaped distribution gives ≈3. We sample a wide Gaussian over a
    // large bin range so the discrete moment closely tracks the continuous 3.
    const BINS = 257;
    var b: pan.feat.SpectralKurtosis(Num, BINS) = .{};
    const center: f64 = 128.0;
    const sd: f64 = 28.0;
    var v: [BINS]f32 = undefined;
    for (&v, 0..) |*x, k| {
        const z = (@as(f64, @floatFromInt(k)) - center) / sd;
        x.* = @floatCast(@exp(-0.5 * z * z));
    }
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    // Continuous Gaussian raw kurtosis is exactly 3; the discrete approximation
    // with sd=28 over 257 bins lands within a couple percent.
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), out[0].value, 0.1);
    // And it agrees tightly with our independent 4th-moment oracle either way.
    try std.testing.expectApproxEqRel(momentOracle(BINS, v, 4), @as(f64, out[0].value), 1e-4);
}

test "SpectralKurtosis: matches the independent 4th-moment oracle on random spectra" {
    const BINS = 28;
    var b: pan.feat.SpectralKurtosis(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0x4D7705AA);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 50) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = rnd.float(f32) * 40.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqRel(momentOracle(BINS, v, 4), @as(f64, out[0].value), 1e-3);
    }
}

// ===========================================================================
// SpectralCrest — max_k power / ( (1/bins)·Σ power ); 0 if mean 0.
// ===========================================================================

/// Independent crest: descending-index sum for the mean, separate max scan.
fn crestOracle(comptime bins: usize, v: [bins]f32) f64 {
    const nf: f64 = @floatFromInt(bins);
    var sum: f64 = 0;
    var k: usize = bins;
    while (k > 0) {
        k -= 1;
        sum += @as(f64, v[k]);
    }
    const mean = sum / nf;
    if (mean <= 0) return 0;
    var peak: f64 = v[0];
    for (v) |p| {
        if (@as(f64, p) > peak) peak = @as(f64, p);
    }
    return peak / mean;
}

test "SpectralCrest: silent spectrum yields 0 by convention (mean 0)" {
    const BINS = 8;
    var b: pan.feat.SpectralCrest(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 5 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "SpectralCrest: a perfectly flat spectrum is exactly 1 (peak == mean)" {
    const BINS = 16;
    var b: pan.feat.SpectralCrest(Num, BINS) = .{};
    inline for (.{ 0.1, 1.0, 42.0 }) |c| {
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(c))};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(@as(f32, 1), out[0].value, 1e-5);
        try std.testing.expectApproxEqAbs(crestOracle(BINS, in[0].v), @as(f64, out[0].value), 1e-5);
    }
}

test "SpectralCrest: a lone peak gives the full crest factor = bins" {
    const BINS = 10;
    var b: pan.feat.SpectralCrest(Num, BINS) = .{};
    // One bin = P, rest 0 ⇒ mean = P/bins ⇒ crest = P/(P/bins) = bins.
    var v: [BINS]f32 = @splat(0.0);
    v[4] = 70.0;
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 10), out[0].value, 1e-5);
    try std.testing.expectApproxEqAbs(crestOracle(BINS, v), @as(f64, out[0].value), 1e-5);
}

test "SpectralCrest: matches the independent max/mean oracle on random spectra" {
    const BINS = 24;
    var b: pan.feat.SpectralCrest(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0xC3E57AAA);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 50) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = rnd.float(f32) * 100.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqRel(crestOracle(BINS, v), @as(f64, out[0].value), 1e-5);
    }
}

// ===========================================================================
// Hfc — Σ_k k·power[k] (Masri high-frequency content). 0 on silence and on DC.
// ===========================================================================

/// Independent HFC: descending-index accumulation (pan goes ascending).
fn hfcOracle(comptime bins: usize, v: [bins]f32) f64 {
    var acc: f64 = 0;
    var k: usize = bins;
    while (k > 0) {
        k -= 1;
        acc += @as(f64, @floatFromInt(k)) * @as(f64, v[k]);
    }
    return acc;
}

test "Hfc: silent spectrum yields exactly 0" {
    const BINS = 8;
    var b: pan.feat.Hfc(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 3 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "Hfc: all-DC (energy only at bin 0) yields 0 — bin 0 has weight 0" {
    const BINS = 8;
    var b: pan.feat.Hfc(Num, BINS) = .{};
    var v: [BINS]f32 = @splat(0.0);
    v[0] = 12345.0;
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "Hfc: a lone bin contributes exactly k·power" {
    const BINS = 12;
    var b: pan.feat.Hfc(Num, BINS) = .{};
    inline for (.{ 1, 5, 11 }) |peak| {
        var v: [BINS]f32 = @splat(0.0);
        v[peak] = 7.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(@as(f32, @as(f32, peak) * 7.0), out[0].value, 1e-4);
    }
}

test "Hfc: a flat spectrum equals c·Σk = c·bins(bins-1)/2" {
    const BINS = 10;
    var b: pan.feat.Hfc(Num, BINS) = .{};
    // Σ_{k=0}^{9} k = 45; with power c=3 each ⇒ 3·45 = 135.
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(3.0))};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 135), out[0].value, 1e-3);
    try std.testing.expectApproxEqAbs(hfcOracle(BINS, in[0].v), @as(f64, out[0].value), 1e-3);
}

test "Hfc: matches the independent index-weighted-sum oracle on random spectra" {
    const BINS = 64;
    var b: pan.feat.Hfc(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0xFAC0DEAD);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 50) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = rnd.float(f32) * 25.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqRel(hfcOracle(BINS, v), @as(f64, out[0].value), 1e-5);
    }
}

// ===========================================================================
// Cross-cutting: a single batch is mapped frame-by-frame, statelessly. We feed
// a mixed batch to every block and check element i depends ONLY on frame i
// (each block carries no per-frame state — they're pure Maps).
// ===========================================================================

test "spectral-shape: every block maps a batch one-for-one with no cross-frame state" {
    const BINS = 8;
    const frames = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, @splat(0)), // silence
        frameOf(BINS, @splat(2)), // flat
        frameOf(BINS, .{ 0, 0, 0, 9, 0, 0, 0, 0 }), // single peak
        frameOf(BINS, .{ 1, 2, 3, 4, 5, 6, 7, 8 }), // ramp
    };

    inline for (.{
        pan.feat.SpectralRolloff(Num, BINS),
        pan.feat.SpectralFlatness(Num, BINS),
        pan.feat.SpectralEntropy(Num, BINS),
        pan.feat.SpectralSpread(Num, BINS),
        pan.feat.SpectralSkewness(Num, BINS),
        pan.feat.SpectralKurtosis(Num, BINS),
        pan.feat.SpectralCrest(Num, BINS),
        pan.feat.Hfc(Num, BINS),
    }) |Block| {
        // Whole-batch render.
        var batch: Block = .{};
        var out_batch: [frames.len]pan.Scalar(f32) = undefined;
        batch.process(&frames, &out_batch);

        // Per-frame render on a fresh instance for each frame.
        for (frames, 0..) |f, i| {
            var single: Block = .{};
            const one = [_]pan.FeatureFrame(BINS){f};
            var out_one = [_]pan.Scalar(f32){.{ .value = -123456 }};
            single.process(&one, &out_one);
            // Stateless ⇒ batch element i == isolated single render of frame i.
            try std.testing.expectEqual(out_batch[i].value, out_one[0].value);
        }
    }
}

// ===========================================================================
// Boundary bins: the smallest legal shapes. SpectralEntropy guards bins<2 at
// comptime, so its minimum is 2; the rest accept bins=1 (mostly degenerate but
// still well-defined by the formulas).
// ===========================================================================

test "spectral-shape: bins=2 is the entropy floor and behaves per the formula" {
    const BINS = 2;
    // Equal mass over both bins ⇒ H = ln2, normalized by ln2 ⇒ exactly 1.
    var e: pan.feat.SpectralEntropy(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 5, 5 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    e.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[0].value, 1e-5);
    try std.testing.expectApproxEqAbs(entropyOracle(BINS, in[0].v), @as(f64, out[0].value), 1e-5);
}

test "spectral-shape: bins=1 degenerate shapes follow the documented formulas" {
    const BINS = 1;
    // Crest: peak==mean ⇒ 1. Flatness: geomean==arithmean ⇒ 1. Spread: σ=0 (single
    // point, |k−c|=0). Hfc: 0 (bin 0 weight 0). Rolloff: bin 0.
    {
        var b: pan.feat.SpectralCrest(Num, BINS) = .{};
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{7})};
        var o = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &o);
        try std.testing.expectApproxEqAbs(@as(f32, 1), o[0].value, 1e-5);
    }
    {
        var b: pan.feat.SpectralFlatness(Num, BINS) = .{};
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{7})};
        var o = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &o);
        try std.testing.expectApproxEqAbs(@as(f32, 1), o[0].value, 1e-5);
    }
    {
        var b: pan.feat.SpectralSpread(Num, BINS) = .{};
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{7})};
        var o = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &o);
        try std.testing.expectApproxEqAbs(@as(f32, 0), o[0].value, 1e-6);
    }
    {
        var b: pan.feat.Hfc(Num, BINS) = .{};
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{7})};
        var o = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &o);
        try std.testing.expectEqual(@as(f32, 0), o[0].value);
    }
    {
        var b: pan.feat.SpectralRolloff(Num, BINS) = .{};
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{7})};
        var o = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &o);
        try std.testing.expectEqual(@as(f32, 0), o[0].value);
    }
}
