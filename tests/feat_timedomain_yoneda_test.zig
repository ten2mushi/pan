//! feat_timedomain_yoneda_test — the INDEPENDENT-ORACLE (≈) check for the three
//! TIME-DOMAIN feature-extraction blocks of `src/feat.zig` (Zcr, TeoMean,
//! BallisticEnvelope). The Yoneda "tests as definition" discipline: each block is
//! characterised by ALL its morphisms — every all-positive / strict-alternating /
//! zero-tie / DC / pure-tone / boundary-FRAME input, and (for the stateful
//! envelope) the attack/release recursion's state carry across calls AND across
//! frames within one call.
//!
//! Oracle strategy (Rule 9, hermetic — no SciPy/librosa/numpy, no disk):
//! every expectation is recomputed in-test by a DIRECT, INDEPENDENT
//! reimplementation of the doc-comment formula (different loop / accumulation
//! order where possible), sharing only the *definition* with pan's block, never
//! its code path. pan and the oracle agree only if both independently compute the
//! documented value. Tolerance-based throughout (expectApproxEq*, never bit-exact)
//! since the blocks accumulate in f64 and the oracle in a different order.
//!
//! Input element is `pan.spectral.TimeFrame(f32, FRAME)` = struct `{ s: [FRAME]f32 }`.
//! Blocks reached as `pan.feat.Zcr(Num, FRAME)` etc., matching the house style of
//! `tests/feat_yoneda_test.zig`.
//!
//! The Yoneda point for BallisticEnvelope (the stateful block): the envelope's
//! ENTIRE identity is its state-evolution under the attack/release recursion. We
//! pin that recursion sample-for-sample, assert fast-rise / slow-decay asymmetry,
//! [0,1] containment, custom attack/release overrides, and the S6 granularity law
//! (one process call ≡ the same sequence split across two calls on ONE instance).
//!
//! Verified against zig 0.16.0 (zig-0-16 skill loaded, Rules 13/14).

const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});

/// Construct the input element — a `TimeFrame(f32, FRAME)` from a raw sample array.
fn frameOf(comptime FRAME: usize, samples: [FRAME]f32) pan.spectral.TimeFrame(f32, FRAME) {
    return .{ .s = samples };
}

// ===========================================================================
// Zcr — zero-crossing rate over a time-domain frame.
//   count of adjacent pairs with (s[k-1] < 0) != (s[k] < 0)  /  (FRAME - 1)
//   zero is treated as non-negative (predicate is strictly `s < 0`).
// ===========================================================================

/// Independent ZCR oracle. Loops front-to-back (matching the definition direction)
/// but recomputes the sign predicate and the count from scratch in f64 — it shares
/// only the documented formula, not pan's `prev_neg` rolling state.
fn zcrOracle(comptime FRAME: usize, s: [FRAME]f32) f64 {
    var count: usize = 0;
    var k: usize = 1;
    while (k < FRAME) : (k += 1) {
        const a_neg: bool = s[k - 1] < 0.0;
        const b_neg: bool = s[k] < 0.0;
        if (a_neg != b_neg) count += 1;
    }
    return @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(FRAME - 1));
}

test "Zcr: classifies as Map minting Scalar(f32)" {
    try std.testing.expect(pan.port.classify(pan.feat.Zcr(Num, 8)) == .Map);
    try std.testing.expect(pan.port.MapOutPort(pan.feat.Zcr(Num, 8)).Elem == pan.Scalar(f32));
}

test "Zcr: an all-positive frame never crosses ⇒ rate 0" {
    const FRAME = 8;
    var b: pan.feat.Zcr(Num, FRAME) = .{};
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, .{ 1, 2, 3, 4, 5, 6, 7, 8 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "Zcr: a strict alternating-sign frame crosses on EVERY pair ⇒ rate 1.0" {
    const FRAME = 8;
    var b: pan.feat.Zcr(Num, FRAME) = .{};
    // +,-,+,-,... — every adjacent pair flips sign ⇒ (FRAME-1)/(FRAME-1) = 1.
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, .{ 1, -1, 1, -1, 1, -1, 1, -1 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0].value, 1e-6);
    try std.testing.expectApproxEqAbs(zcrOracle(FRAME, in[0].s), @as(f64, out[0].value), 1e-9);
}

test "Zcr: zero is treated as NON-negative (the tie convention)" {
    const FRAME = 6;
    var b: pan.feat.Zcr(Num, FRAME) = .{};
    // The predicate is `s < 0`, so 0 groups with the positives.
    // Sequence:  +  0  -   +   0   -
    // sign(<0):  F  F  T   F   F   T
    // pairs:      F=F  F!=T  T!=F  F=F  F!=T  → crossings at (0|-), (-|+), (0|-)=3.
    // Wait: pairs are (idx0,1)(1,2)(2,3)(3,4)(4,5):
    //   (+,0): F,F  no    (0,-): F,T  YES   (-,+): T,F  YES
    //   (+,0): F,F  no    (0,-): F,T  YES                       → 3 crossings / 5.
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, .{ 0.5, 0.0, -0.5, 0.5, 0.0, -0.5 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    // The block stores the rate as f32, so compare at f32 precision (~1e-6), not
    // f64 — the value itself is exact, only the storage width limits the match.
    try std.testing.expectApproxEqAbs(@as(f64, 3.0) / 5.0, @as(f64, out[0].value), 1e-6);
    try std.testing.expectApproxEqAbs(zcrOracle(FRAME, in[0].s), @as(f64, out[0].value), 1e-6);
}

test "Zcr: an all-zero frame has no sign changes (zero≡non-negative) ⇒ rate 0" {
    const FRAME = 8;
    var b: pan.feat.Zcr(Num, FRAME) = .{};
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 7 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "Zcr: a single sign change yields exactly 1/(FRAME-1)" {
    const FRAME = 5;
    var b: pan.feat.Zcr(Num, FRAME) = .{};
    // One flip somewhere in the middle: +,+,-,-,- ⇒ exactly one crossing.
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, .{ 1, 1, -1, -1, -1 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0) / 4.0, @as(f64, out[0].value), 1e-9);
}

test "Zcr: the minimal boundary FRAME=2 — one pair, rate is 0 or 1" {
    const FRAME = 2;
    var b: pan.feat.Zcr(Num, FRAME) = .{};
    // same sign ⇒ 0 ; opposite sign ⇒ 1/(2-1) = 1.
    const same = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, .{ 0.3, 0.9 })};
    const diff = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, .{ 0.3, -0.9 })};
    var o0 = [_]pan.Scalar(f32){.{ .value = -1 }};
    var o1 = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&same, &o0);
    b.process(&diff, &o1);
    try std.testing.expectEqual(@as(f32, 0), o0[0].value);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), o1[0].value, 1e-9);
}

test "Zcr: a batch of frames maps one-for-one, statelessly (frame-local)" {
    const FRAME = 4;
    var b: pan.feat.Zcr(Num, FRAME) = .{};
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){
        frameOf(FRAME, .{ 1, 1, 1, 1 }), // 0 crossings ⇒ 0
        frameOf(FRAME, .{ 1, -1, 1, -1 }), // 3 crossings ⇒ 1.0
        frameOf(FRAME, .{ -1, -1, 1, 1 }), // 1 crossing ⇒ 1/3
    };
    var out: [3]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    // Frame-local: the answer for frame i must equal zcrOracle(frame i) with no
    // dependence on the others (stateless). Re-run each in isolation to prove it.
    for (in, out) |f, o| {
        try std.testing.expectApproxEqAbs(zcrOracle(FRAME, f.s), @as(f64, o.value), 1e-6);
        var solo = pan.feat.Zcr(Num, FRAME){};
        const one = [_]pan.spectral.TimeFrame(f32, FRAME){f};
        var so = [_]pan.Scalar(f32){.{ .value = -1 }};
        solo.process(&one, &so);
        try std.testing.expectEqual(o.value, so[0].value);
    }
}

test "Zcr: matches the independent oracle on randomized frames (incl. exact zeros)" {
    const FRAME = 64;
    var b: pan.feat.Zcr(Num, FRAME) = .{};
    var prng = std.Random.DefaultPrng.init(0x2C8B17A9);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 48) : (trial += 1) {
        var s: [FRAME]f32 = undefined;
        for (&s) |*x| {
            // Mix in occasional exact zeros to stress the non-negative tie path.
            const r = rnd.float(f32);
            x.* = if (rnd.intRangeAtMost(u8, 0, 7) == 0) 0.0 else (r - 0.5) * 2.0;
        }
        const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, s)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(zcrOracle(FRAME, s), @as(f64, out[0].value), 1e-6);
        // Containment: a rate is always within [0, 1].
        try std.testing.expect(out[0].value >= 0.0 and out[0].value <= 1.0);
    }
}

// ===========================================================================
// TeoMean — mean Teager-Kaiser energy over a time-domain frame.
//   Ψ[n] = s[n]² − s[n-1]·s[n+1], averaged over interior n = 1 … FRAME-2,
//   divided by (FRAME-2). Accumulated in f64.
// ===========================================================================

/// Independent TKEO oracle. Accumulates the interior Ψ in REVERSE order (n high→low)
/// so the float summation order differs from pan's ascending loop; the documented
/// value is the only thing shared.
fn teoOracle(comptime FRAME: usize, s: [FRAME]f32) f64 {
    var acc: f64 = 0;
    var n: usize = FRAME - 1; // walk down; interior is 1..=FRAME-2
    while (n > 1) {
        n -= 1;
        const x: f64 = s[n];
        const xm: f64 = s[n - 1];
        const xp: f64 = s[n + 1];
        acc += x * x - xm * xp;
    }
    return acc / @as(f64, @floatFromInt(FRAME - 2));
}

test "TeoMean: classifies as Map minting Scalar(f32)" {
    try std.testing.expect(pan.port.classify(pan.feat.TeoMean(Num, 8)) == .Map);
    try std.testing.expect(pan.port.MapOutPort(pan.feat.TeoMean(Num, 8)).Elem == pan.Scalar(f32));
}

test "TeoMean: a DC (constant) frame has zero Teager energy" {
    const FRAME = 8;
    var b: pan.feat.TeoMean(Num, FRAME) = .{};
    // For constant c: Ψ = c² − c·c = 0 at every interior sample ⇒ mean 0.
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, @splat(0.7))};
    var out = [_]pan.Scalar(f32){.{ .value = 99 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].value, 1e-6);
    try std.testing.expectApproxEqAbs(teoOracle(FRAME, in[0].s), @as(f64, out[0].value), 1e-9);
}

test "TeoMean: an all-zero frame yields exactly zero" {
    const FRAME = 5;
    var b: pan.feat.TeoMean(Num, FRAME) = .{};
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, @splat(0))};
    var out = [_]pan.Scalar(f32){.{ .value = 99 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "TeoMean: a hand-computed interior matches the closed-form mean" {
    const FRAME = 5;
    var b: pan.feat.TeoMean(Num, FRAME) = .{};
    // s = {1, 2, 3, 2, 1}; interior n=1,2,3:
    //   n=1: 2² − 1·3 = 4 − 3 = 1
    //   n=2: 3² − 2·2 = 9 − 4 = 5
    //   n=3: 2² − 3·1 = 4 − 3 = 1
    //   sum = 7 ; /(FRAME-2)=3 ⇒ 7/3.
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, .{ 1, 2, 3, 2, 1 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0) / 3.0, @as(f64, out[0].value), 1e-6);
    // f32 storage precision (the value 7/3 is exact in f64 but rounded on store).
    try std.testing.expectApproxEqAbs(teoOracle(FRAME, in[0].s), @as(f64, out[0].value), 1e-6);
}

test "TeoMean: a pure tone matches the independent Ψ recomputation" {
    const FRAME = 128;
    var b: pan.feat.TeoMean(Num, FRAME) = .{};
    // s[n] = A·sin(ω n + φ). The TKEO of a clean sinusoid is ≈ A²·sin²(ω),
    // constant across n; we don't hardcode that — we assert pan ≈ the independent
    // per-sample Ψ mean, which is the whole point.
    const A: f32 = 0.8;
    const omega: f32 = 0.37;
    const phi: f32 = 1.1;
    var s: [FRAME]f32 = undefined;
    for (&s, 0..) |*x, n| {
        x.* = A * @sin(omega * @as(f32, @floatFromInt(n)) + phi);
    }
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, s)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    const want = teoOracle(FRAME, s);
    try std.testing.expectApproxEqAbs(want, @as(f64, out[0].value), 1e-5);
    // Sanity: a real tone has positive Teager energy.
    try std.testing.expect(out[0].value > 0.0);
    // And it should sit near the analytic A²·sin²(ω) (loose tol — boundary effects).
    const analytic: f64 = @as(f64, A) * @as(f64, A) * @as(f64, @sin(omega)) * @as(f64, @sin(omega));
    try std.testing.expectApproxEqAbs(analytic, @as(f64, out[0].value), 5e-3);
}

test "TeoMean: the minimal boundary FRAME=3 is a single interior sample" {
    const FRAME = 3;
    var b: pan.feat.TeoMean(Num, FRAME) = .{};
    // Only n=1 is interior: Ψ = s1² − s0·s2 ; /(FRAME-2)=1.
    // s = {2, 5, 3}: 25 − 2·3 = 25 − 6 = 19.
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, .{ 2, 5, 3 })};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 19.0), out[0].value, 1e-5);
    try std.testing.expectApproxEqAbs(teoOracle(FRAME, in[0].s), @as(f64, out[0].value), 1e-9);
}

test "TeoMean: negative Ψ is allowed (energy operator is not sign-definite)" {
    const FRAME = 3;
    var b: pan.feat.TeoMean(Num, FRAME) = .{};
    // s = {3, 0, 3}: Ψ = 0 − 3·3 = −9. The TKEO can be negative for some inputs.
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, .{ 3, 0, 3 })};
    var out = [_]pan.Scalar(f32){.{ .value = 0 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, -9.0), out[0].value, 1e-5);
}

test "TeoMean: a batch maps one-for-one, statelessly" {
    const FRAME = 5;
    var b: pan.feat.TeoMean(Num, FRAME) = .{};
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){
        frameOf(FRAME, .{ 0, 0, 0, 0, 0 }),
        frameOf(FRAME, .{ 1, 2, 3, 2, 1 }),
        frameOf(FRAME, .{ 0.5, 0.5, 0.5, 0.5, 0.5 }),
    };
    var out: [3]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    for (in, out) |f, o| {
        try std.testing.expectApproxEqAbs(teoOracle(FRAME, f.s), @as(f64, o.value), 1e-6);
        // statelessness: solo run on a fresh instance is identical.
        var solo = pan.feat.TeoMean(Num, FRAME){};
        const one = [_]pan.spectral.TimeFrame(f32, FRAME){f};
        var so = [_]pan.Scalar(f32){.{ .value = -1 }};
        solo.process(&one, &so);
        try std.testing.expectEqual(o.value, so[0].value);
    }
}

test "TeoMean: matches the independent oracle on randomized frames" {
    const FRAME = 96;
    var b: pan.feat.TeoMean(Num, FRAME) = .{};
    var prng = std.Random.DefaultPrng.init(0x77A1FE0D);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 48) : (trial += 1) {
        var s: [FRAME]f32 = undefined;
        for (&s) |*x| x.* = (rnd.float(f32) - 0.5) * 2.0;
        const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, s)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expectApproxEqAbs(teoOracle(FRAME, s), @as(f64, out[0].value), 1e-5);
    }
}

// ===========================================================================
// BallisticEnvelope — STATEFUL attack/release one-pole on the frame peak.
//   level = clamp(max_n |s[n]|, 0, 1)
//   coeff = (level > env) ? attack : release
//   env  ← env + coeff·(level − env)        (env starts 0)
//   output = env, in [0, 1].   Defaults attack=0.6, release=0.05.
// ===========================================================================

/// Independent envelope oracle: steps the documented recursion across a sequence of
/// frames, returning the per-frame outputs and the residual env. Computes the peak
/// with a fresh reduce and the coefficient choice from the prose, sharing only the
/// definition. `attack`/`release` are parameters so we can mirror custom fields.
fn envOracle(
    comptime FRAME: usize,
    frames: []const pan.spectral.TimeFrame(f32, FRAME),
    attack: f32,
    release: f32,
    env0: f32,
    out: []f32,
) f32 {
    var env: f32 = env0;
    for (frames, 0..) |frame, i| {
        var peak: f32 = 0;
        for (frame.s) |x| {
            const a = @abs(x);
            if (a > peak) peak = a;
        }
        const level = std.math.clamp(peak, 0.0, 1.0);
        const coeff: f32 = if (level > env) attack else release;
        env = env + coeff * (level - env);
        out[i] = env;
    }
    return env;
}

/// Build a constant-peak frame: one sample carries `peak`, the rest are smaller.
fn constPeakFrame(comptime FRAME: usize, peak: f32) pan.spectral.TimeFrame(f32, FRAME) {
    var s: [FRAME]f32 = @splat(0);
    s[FRAME / 2] = peak; // place the peak in the interior, magnitude = |peak|
    return .{ .s = s };
}

test "BallisticEnvelope: classifies as Map minting Scalar(f32)" {
    try std.testing.expect(pan.port.classify(pan.feat.BallisticEnvelope(Num, 8)) == .Map);
    try std.testing.expect(pan.port.MapOutPort(pan.feat.BallisticEnvelope(Num, 8)).Elem == pan.Scalar(f32));
}

test "BallisticEnvelope: env starts at 0 and silence keeps it at 0" {
    const FRAME = 8;
    var b: pan.feat.BallisticEnvelope(Num, FRAME) = .{};
    try std.testing.expectEqual(@as(f32, 0), b.env);
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){
        frameOf(FRAME, @splat(0)),
        frameOf(FRAME, @splat(0)),
    };
    var out: [2]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    // level=0, env=0 ⇒ release branch, env stays 0.
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
    try std.testing.expectEqual(@as(f32, 0), out[1].value);
    try std.testing.expectEqual(@as(f32, 0), b.env);
}

test "BallisticEnvelope: first attack step is exactly attack·level from env=0" {
    const FRAME = 8;
    var b: pan.feat.BallisticEnvelope(Num, FRAME) = .{}; // attack=0.6, release=0.05
    // level rises from 0 to 1 ⇒ attack branch ⇒ env = 0 + 0.6·(1−0) = 0.6.
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){constPeakFrame(FRAME, 1.0)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), out[0].value, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), b.env, 1e-6);
}

test "BallisticEnvelope: peak is |s| — a deep negative sample drives the level" {
    const FRAME = 8;
    var b: pan.feat.BallisticEnvelope(Num, FRAME) = .{};
    // The loudest |sample| is a negative one ⇒ |−0.9| = 0.9 is the level.
    var s: [FRAME]f32 = @splat(0.1);
    s[3] = -0.9;
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, s)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    // env = 0 + 0.6·(0.9 − 0) = 0.54.
    try std.testing.expectApproxEqAbs(@as(f32, 0.54), out[0].value, 1e-6);
}

test "BallisticEnvelope: level is clamped to 1 — a >1 peak cannot push env past 1" {
    const FRAME = 8;
    var b: pan.feat.BallisticEnvelope(Num, FRAME) = .{};
    // peak |−3.5| = 3.5 clamps to level=1 ⇒ env = 0.6·1 = 0.6, not 0.6·3.5.
    var s: [FRAME]f32 = @splat(0);
    s[2] = -3.5;
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, s)};
    var out = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), out[0].value, 1e-6);
    try std.testing.expect(out[0].value <= 1.0);
}

test "BallisticEnvelope: fast attack on rise, SLOW release on fall (the asymmetry)" {
    const FRAME = 8;
    var b: pan.feat.BallisticEnvelope(Num, FRAME) = .{};
    // Frame 0: level 1 ⇒ env jumps to 0.6 (attack, fast).
    // Frame 1: level 0 ⇒ env = 0.6 + 0.05·(0−0.6) = 0.6 − 0.03 = 0.57 (release, slow).
    // The release fall (only −0.03) must be far smaller than the attack rise (+0.6),
    // which is the entire ballistic-meter point.
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){
        constPeakFrame(FRAME, 1.0),
        frameOf(FRAME, @splat(0)),
    };
    var out: [2]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), out[0].value, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.57), out[1].value, 1e-6);
    const rise = out[0].value - 0.0;
    const fall = out[0].value - out[1].value;
    try std.testing.expect(rise > fall * 10.0); // attack ≫ release granularity
}

test "BallisticEnvelope: follows the recursion sample-for-sample on a crafted sweep" {
    const FRAME = 16;
    var b: pan.feat.BallisticEnvelope(Num, FRAME) = .{};
    // A rise-then-hold-then-decay level sweep, expressed as per-frame peaks.
    const peaks = [_]f32{ 0.2, 0.5, 0.9, 1.0, 1.0, 0.3, 0.0, 0.0, 0.6, 0.6 };
    var frames: [peaks.len]pan.spectral.TimeFrame(f32, FRAME) = undefined;
    for (&frames, peaks) |*f, p| f.* = constPeakFrame(FRAME, p);

    var out: [peaks.len]pan.Scalar(f32) = undefined;
    b.process(&frames, &out);

    var want: [peaks.len]f32 = undefined;
    const final = envOracle(FRAME, &frames, 0.6, 0.05, 0.0, &want);
    for (out, want) |o, w| {
        try std.testing.expectApproxEqAbs(@as(f64, w), @as(f64, o.value), 1e-6);
        try std.testing.expect(o.value >= 0.0 and o.value <= 1.0); // containment
    }
    // Residual state matches the oracle's final env.
    try std.testing.expectApproxEqAbs(@as(f64, final), @as(f64, b.env), 1e-6);
}

test "BallisticEnvelope: custom attack/release fields override the recursion" {
    const FRAME = 8;
    // Pin entirely different ballistics and assert the recursion uses THEM.
    var b: pan.feat.BallisticEnvelope(Num, FRAME) = .{ .attack = 0.9, .release = 0.2 };
    try std.testing.expectEqual(@as(f32, 0.9), b.attack);
    try std.testing.expectEqual(@as(f32, 0.2), b.release);
    const in = [_]pan.spectral.TimeFrame(f32, FRAME){
        constPeakFrame(FRAME, 1.0), // attack: env = 0.9·1 = 0.9
        frameOf(FRAME, @splat(0)), // release: env = 0.9 + 0.2·(0−0.9) = 0.72
    };
    var out: [2]pan.Scalar(f32) = undefined;
    b.process(&in, &out);
    var want: [2]f32 = undefined;
    _ = envOracle(FRAME, &in, 0.9, 0.2, 0.0, &want);
    try std.testing.expectApproxEqAbs(@as(f64, want[0]), @as(f64, out[0].value), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, want[1]), @as(f64, out[1].value), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), out[0].value, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.72), out[1].value, 1e-6);
}

test "BallisticEnvelope: state carries across SEPARATE process calls (per-instance env)" {
    const FRAME = 8;
    var b: pan.feat.BallisticEnvelope(Num, FRAME) = .{};
    // Call 1 leaves env at attack·1 = 0.6.
    const c1 = [_]pan.spectral.TimeFrame(f32, FRAME){constPeakFrame(FRAME, 1.0)};
    var o1 = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&c1, &o1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), b.env, 1e-6);

    // Call 2 must release FROM 0.6, not from 0: env = 0.6 + 0.05·(0−0.6) = 0.57.
    const c2 = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, @splat(0))};
    var o2 = [_]pan.Scalar(f32){.{ .value = -1 }};
    b.process(&c2, &o2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.57), o2[0].value, 1e-6);
}

test "BallisticEnvelope: S6 granularity — one whole call ≡ the same stream split in two" {
    // The Yoneda heart of the stateful block: env advances exactly once per frame,
    // so ANY partition of the frame stream into sub-blocks on ONE instance must yield
    // identical outputs AND leave env in the identical state as one whole-block call.
    const FRAME = 12;
    const N = 11;
    var prng = std.Random.DefaultPrng.init(0xBA11157C);
    const rnd = prng.random();
    var frames: [N]pan.spectral.TimeFrame(f32, FRAME) = undefined;
    for (&frames) |*f| {
        for (&f.s) |*x| x.* = (rnd.float(f32) - 0.5) * 2.4; // some |peaks| exceed 1 ⇒ clamp
    }

    // Whole-block render on a fresh instance.
    var whole: pan.feat.BallisticEnvelope(Num, FRAME) = .{};
    var out_whole: [N]pan.Scalar(f32) = undefined;
    whole.process(&frames, &out_whole);

    // Split render at an arbitrary seam (4 | 4 | 3) on ONE fresh instance.
    var split: pan.feat.BallisticEnvelope(Num, FRAME) = .{};
    var out_split: [N]pan.Scalar(f32) = undefined;
    split.process(frames[0..4], out_split[0..4]);
    split.process(frames[4..8], out_split[4..8]);
    split.process(frames[8..N], out_split[8..N]);

    // 1) Identical per-frame outputs.
    for (out_whole, out_split) |w, s| {
        try std.testing.expectApproxEqAbs(@as(f64, w.value), @as(f64, s.value), 1e-7);
    }
    // 2) Identical residual env state.
    try std.testing.expectApproxEqAbs(@as(f64, whole.env), @as(f64, split.env), 1e-7);

    // 3) Both match the independent oracle stepping env frame by frame.
    var want: [N]f32 = undefined;
    const final = envOracle(FRAME, &frames, 0.6, 0.05, 0.0, &want);
    for (out_whole, want) |o, w| {
        try std.testing.expectApproxEqAbs(@as(f64, w), @as(f64, o.value), 1e-6);
        try std.testing.expect(o.value >= 0.0 and o.value <= 1.0);
    }
    try std.testing.expectApproxEqAbs(@as(f64, final), @as(f64, whole.env), 1e-6);
}

test "BallisticEnvelope: output stays in [0,1] under a long random storm" {
    const FRAME = 32;
    var b: pan.feat.BallisticEnvelope(Num, FRAME) = .{};
    var prng = std.Random.DefaultPrng.init(0x5101A1B2);
    const rnd = prng.random();
    var hop: usize = 0;
    while (hop < 200) : (hop += 1) {
        var s: [FRAME]f32 = undefined;
        for (&s) |*x| x.* = (rnd.float(f32) - 0.5) * 6.0; // wild, far outside [-1,1]
        const in = [_]pan.spectral.TimeFrame(f32, FRAME){frameOf(FRAME, s)};
        var out = [_]pan.Scalar(f32){.{ .value = -1 }};
        b.process(&in, &out);
        try std.testing.expect(out[0].value >= 0.0 and out[0].value <= 1.0);
    }
}
