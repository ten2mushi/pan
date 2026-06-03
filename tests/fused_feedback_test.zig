//! fused_feedback_test — the Yoneda characterization of the fused tight-feedback
//! kernels (`src/fx.zig`): `Comb`, `Allpass`, `KarplusStrong`.
//!
//! Each kernel is understood here through ALL its observable morphisms — every
//! way an input maps to an output — so that the tests *define* the block's
//! behavior rather than merely sampling it. Three independent oracle families
//! pin the full matrix:
//!
//!   1. ANALYTIC ORACLE (impulse response vs closed form). A kernel's response
//!      to a unit impulse is the kernel: knowing it is knowing every linear
//!      morphism. We derive the closed form by hand from the recurrence and
//!      compare with `expectApproxEqAbs` (a float oracle ⇒ allclose, tol 1e-6).
//!        * Comb:    y[k·D] = g^k, zero on every off-echo sample.
//!        * Allpass: y[0] = -g, then y[k·D] = g^(k-1)·(1-g²); a dispersive
//!                   all-pass (NOT a pure delay), energy bounded.
//!        * KS:      hand-rolled recurrence (two-tap loop low-pass); sustains.
//!
//!   2. STRUCTURAL ORACLE (pan-vs-pan, BIT-EXACT). The internal z⁻¹ is
//!      sample-accurate and persistent, so two pan runs that *must* agree are
//!      compared with `std.testing.expectEqual` (an "almost" is a failure):
//!        * state carries across `process` calls — recirculating echoes emerge
//!          on LATER zero-input blocks;
//!        * a split render [0,k)+[k,N) is byte-identical to a whole [0,N) render.
//!
//!   3. STABILITY / FINITENESS ORACLE. For |g|<1 the tail is non-growing and
//!      every output sample is finite (`std.math.isFinite`).
//!
//! Plus the classification facet (each is a `.Map`, declares `delay_len`, does
//! NOT declare `aliasing_safe`) and the optional flush-to-zero facet (a tail
//! driven subnormal flushes to exactly 0 after `enterRealtimeThread`, gated on
//! the live FP control word so it is platform-tolerant).
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring,
//! per project Rules 13/14). Diagnostics go to `std.debug.print`, never
//! `std.log.err` (the 0.16 test runner counts logged errors as failures).
//!
//! COMPARISON MODE: analytic-oracle checks ⇒ float allclose (`expectApproxEqAbs`,
//! tol 1e-6). State-carry and split≡whole ⇒ pan-vs-pan BIT-EXACT (`expectEqual`).

const std = @import("std");
const builtin = @import("builtin");
const pan = @import("pan");

const numeric = pan.numeric;
const port = pan.port;
const fx = pan.fx;
const Sample = pan.Sample;
const Comb = pan.Comb;
const Allpass = pan.Allpass;
const KarplusStrong = pan.KarplusStrong;
const enterRealtimeThread = pan.enterRealtimeThread;

const testing = std.testing;
const num_f32 = numeric.numericFor(.f32, .{});
const num_f64 = numeric.numericFor(.f64, .{});

const TOL: f32 = 1e-6;

// ---------------------------------------------------------------------------
// Small helpers — build mono Sample(f32) buffers and read scalars back out.
// ---------------------------------------------------------------------------

fn S(x: f32) Sample(f32) {
    return .{ .ch = .{x} };
}

/// A length-N buffer of silence with a unit impulse at index 0.
fn impulse(comptime N: usize) [N]Sample(f32) {
    var b: [N]Sample(f32) = @splat(S(0));
    b[0] = S(1);
    return b;
}

fn silence(comptime N: usize) [N]Sample(f32) {
    return @splat(S(0));
}

/// Extract the scalar channel-0 values of a frame slice into a plain `[]f32`.
fn vals(comptime N: usize, frames: []const Sample(f32)) [N]f32 {
    var out: [N]f32 = undefined;
    for (frames, 0..) |f, i| out[i] = f.ch[0];
    return out;
}

// ===========================================================================
// COMB — analytic oracle: unit impulse ⇒ a decaying echo train g^k at k·D.
// ===========================================================================

test "Comb: impulse response is the closed-form echo train g^k at k·D, silent elsewhere" {
    // y[n] = x[n] + g·y[n-D]. With a unit impulse the only non-zero outputs are
    // at n = k·D with gain g^k; EVERY other sample is identically zero. We pin
    // both the echo gains and the off-echo silence — a kernel that leaked energy
    // into the gaps, or used the wrong D, would be caught.
    const D = 5;
    const g: f32 = 0.6;
    var comb = Comb(num_f32, 16){ .delay = D, .feedback = g };

    var in = impulse(40);
    var out: [40]Sample(f32) = undefined;
    comb.process(&in, &out);

    var expected_gain: f32 = 1.0; // g^0
    var n: usize = 0;
    while (n < out.len) : (n += 1) {
        if (n % D == 0) {
            try testing.expectApproxEqAbs(expected_gain, out[n].ch[0], TOL);
            expected_gain *= g; // next echo is g× the previous
        } else {
            // Off-echo samples are exactly silent (not "approximately").
            try testing.expectEqual(@as(f32, 0.0), out[n].ch[0]);
        }
    }
}

test "Comb: D == max_delay (default) still produces the echo train at the ring length" {
    // The default `delay = max_delay` exercises the wrap at the ring boundary.
    const D = 4;
    const g: f32 = 0.5;
    var comb = Comb(num_f32, D){ .feedback = g }; // delay defaults to max_delay
    try testing.expectEqual(@as(usize, D), comb.delay);

    var in = impulse(13);
    var out: [13]Sample(f32) = undefined;
    comb.process(&in, &out);

    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[4].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[8].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, 0.125), out[12].ch[0], TOL);
    try testing.expectEqual(@as(f32, 0.0), out[1].ch[0]);
    try testing.expectEqual(@as(f32, 0.0), out[7].ch[0]);
}

test "Comb: g = 0 is a pure pass-through (no echoes at all)" {
    // Degenerate feedback: the recurrence collapses to y[n] = x[n].
    var comb = Comb(num_f32, 8){ .delay = 3, .feedback = 0.0 };
    var in = impulse(12);
    var out: [12]Sample(f32) = undefined;
    comb.process(&in, &out);
    try testing.expectEqual(@as(f32, 1.0), out[0].ch[0]);
    for (out[1..]) |s| try testing.expectEqual(@as(f32, 0.0), s.ch[0]);
}

test "Comb: negative g alternates the echo sign (g^k carries the sign)" {
    const D = 3;
    const g: f32 = -0.5;
    var comb = Comb(num_f32, 8){ .delay = D, .feedback = g };
    var in = impulse(13);
    var out: [13]Sample(f32) = undefined;
    comb.process(&in, &out);
    // g^k: 1, -0.5, +0.25, -0.125 at n = 0,3,6,9.
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[3].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[6].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, -0.125), out[9].ch[0], TOL);
}

test "Comb: scaled impulse scales the whole response linearly (a·g^k)" {
    // Linearity in the input amplitude: the impulse response is the kernel.
    const D = 4;
    const g: f32 = 0.5;
    const a: f32 = 3.0;
    var comb = Comb(num_f32, 8){ .delay = D, .feedback = g };
    var in = silence(13);
    in[0] = S(a);
    var out: [13]Sample(f32) = undefined;
    comb.process(&in, &out);
    var expected: f32 = a;
    var n: usize = 0;
    while (n < out.len) : (n += D) {
        try testing.expectApproxEqAbs(expected, out[n].ch[0], TOL);
        expected *= g;
    }
}

test "Comb: |g| < 1 tail is non-growing and every output is finite (stability)" {
    const D = 7;
    const g: f32 = 0.85;
    var comb = Comb(num_f32, 16){ .delay = D, .feedback = g };
    var in = impulse(256);
    var out: [256]Sample(f32) = undefined;
    comb.process(&in, &out);

    // Each successive echo magnitude must be <= the previous (monotone decay).
    var prev_peak: f32 = std.math.inf(f32);
    var n: usize = 0;
    while (n < out.len) : (n += D) {
        const mag = @abs(out[n].ch[0]);
        try testing.expect(mag <= prev_peak + TOL);
        prev_peak = mag;
    }
    // Finiteness everywhere.
    for (out) |s| try testing.expect(std.math.isFinite(s.ch[0]));
}

test "Comb: f64 lane characterizes identically (precision is a free parameter)" {
    // The kernel is monomorphized per precision; the closed form is precision-
    // independent, so the f64 monomorph must reproduce the same echo train.
    const D = 3;
    const g: f64 = 0.5;
    var comb = Comb(num_f64, 8){ .delay = D, .feedback = g };
    var in: [13]pan.Sample(f64) = @splat(.{ .ch = .{0} });
    in[0] = .{ .ch = .{1} };
    var out: [13]pan.Sample(f64) = undefined;
    comb.process(&in, &out);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[0].ch[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), out[3].ch[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), out[6].ch[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.125), out[9].ch[0], 1e-12);
}

// ===========================================================================
// COMB — structural oracle: state persistence + split ≡ whole (BIT-EXACT).
// ===========================================================================

test "Comb: state carries across process calls — echoes emerge on LATER blocks" {
    // The internal z⁻¹ persists between calls. Render the impulse in a block too
    // SHORT to contain the first echo, then a zero-input block: the recirculating
    // echo must appear in the SECOND call. This proves the ring + cursor survive.
    const D = 6;
    const g: f32 = 0.7;
    var comb = Comb(num_f32, 8){ .delay = D, .feedback = g };

    var in1 = impulse(4); // shorter than D ⇒ no echo yet
    var out1: [4]Sample(f32) = undefined;
    comb.process(&in1, &out1);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out1[0].ch[0], TOL); // the direct hit
    for (out1[1..]) |s| try testing.expectEqual(@as(f32, 0.0), s.ch[0]); // nothing yet

    var in2 = silence(12);
    var out2: [12]Sample(f32) = undefined;
    comb.process(&in2, &out2);
    // Absolute time n=6 is index (6-4)=2 in the second block ⇒ g^1 = 0.7.
    try testing.expectApproxEqAbs(g, out2[2].ch[0], TOL);
    // Absolute time n=12 is index (12-4)=8 ⇒ g^2 = 0.49.
    try testing.expectApproxEqAbs(g * g, out2[8].ch[0], TOL);
}

test "Comb: split render [0,k)+[k,N) is BIT-EXACT to a whole [0,N) render" {
    // Block boundaries must be invisible: the per-sample state makes a split at an
    // arbitrary k indistinguishable from a single pass. pan-vs-pan ⇒ expectEqual.
    const N = 64;
    const k = 23; // an arbitrary, non-D-aligned split
    const D = 5;
    const g: f32 = 0.66;

    const whole = blk: {
        var c = Comb(num_f32, 16){ .delay = D, .feedback = g };
        var in = impulse(N);
        var out: [N]Sample(f32) = undefined;
        c.process(&in, &out);
        break :blk vals(N, &out);
    };

    const split = blk: {
        var c = Comb(num_f32, 16){ .delay = D, .feedback = g };
        var in = impulse(N);
        var out: [N]Sample(f32) = undefined;
        c.process(in[0..k], out[0..k]);
        c.process(in[k..], out[k..]);
        break :blk vals(N, &out);
    };

    try testing.expectEqual(whole, split);
}

test "Comb: three-way split is BIT-EXACT to whole (boundaries are invisible)" {
    const N = 48;
    const D = 7;
    const g: f32 = 0.5;
    const a = 11;
    const b = 30;

    var whole: [N]f32 = undefined;
    {
        var c = Comb(num_f32, 16){ .delay = D, .feedback = g };
        var in = impulse(N);
        var out: [N]Sample(f32) = undefined;
        c.process(&in, &out);
        whole = vals(N, &out);
    }
    var split: [N]f32 = undefined;
    {
        var c = Comb(num_f32, 16){ .delay = D, .feedback = g };
        var in = impulse(N);
        var out: [N]Sample(f32) = undefined;
        c.process(in[0..a], out[0..a]);
        c.process(in[a..b], out[a..b]);
        c.process(in[b..], out[b..]);
        split = vals(N, &out);
    }
    try testing.expectEqual(whole, split);
}

// ===========================================================================
// ALLPASS — analytic oracle, hand-derived from the recurrence.
//   v = ring[p];  y = -g·x + v;  ring[p] = x + g·y
// For an impulse x[0]=1, D=2, g=0.5 the hand trace gives:
//   y[0] = -g,  y[2] = 1-g²,  y[4] = g·(1-g²),  y[6] = g²·(1-g²), ...
// i.e. an immediate through term -g then a delayed train (1-g²)·g^(k-1) at k·D.
// ===========================================================================

test "Allpass: immediate through term is -g·x[0] (it is NOT a pure delay)" {
    const g: f32 = 0.5;
    var ap = Allpass(num_f32, 4){ .delay = 2, .feedback = g };
    var in = impulse(8);
    var out: [8]Sample(f32) = undefined;
    ap.process(&in, &out);
    // The very first sample is the inverted through path, not zero — a pure delay
    // would have produced 0 here. This is the signature that distinguishes an
    // all-pass from a delay line.
    try testing.expectApproxEqAbs(-g, out[0].ch[0], TOL);
    try testing.expect(out[0].ch[0] != 0.0);
}

test "Allpass: full early impulse response matches the hand-derived recurrence" {
    const g: f32 = 0.5;
    const D = 2;
    var ap = Allpass(num_f32, 4){ .delay = D, .feedback = g };
    var in = impulse(8);
    var out: [8]Sample(f32) = undefined;
    ap.process(&in, &out);

    const one_minus_g2 = 1.0 - g * g; // 0.75
    // Hand-derived oracle (see header comment):
    try testing.expectApproxEqAbs(-g, out[0].ch[0], TOL); // -0.5
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[1].ch[0], TOL); // off-tap
    try testing.expectApproxEqAbs(one_minus_g2, out[2].ch[0], TOL); // 0.75
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[3].ch[0], TOL);
    try testing.expectApproxEqAbs(g * one_minus_g2, out[4].ch[0], TOL); // 0.375
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[5].ch[0], TOL);
    try testing.expectApproxEqAbs(g * g * one_minus_g2, out[6].ch[0], TOL); // 0.1875
}

test "Allpass: magnitude is flat — impulse-response energy equals the input energy" {
    // The defining property of a (lossless, |g|<1) all-pass: it preserves total
    // signal energy (Parseval). A unit impulse has energy 1; the full impulse
    // response must sum to 1 in the limit. Over a long-enough horizon the tail is
    // negligible, so the partial sum is ~1.
    const g: f32 = 0.7;
    const D = 13;
    var ap = Allpass(num_f32, 16){ .delay = D, .feedback = g };
    var in = impulse(4096);
    var out: [4096]Sample(f32) = undefined;
    ap.process(&in, &out);
    var energy: f64 = 0;
    for (out) |s| energy += @as(f64, s.ch[0]) * @as(f64, s.ch[0]);
    // Energy is conserved to within the truncated tail (a few 1e-3).
    try testing.expectApproxEqAbs(@as(f64, 1.0), energy, 1e-3);
}

test "Allpass: |g| < 1 tail is bounded and every output is finite (stability)" {
    const g: f32 = 0.9;
    var ap = Allpass(num_f32, 16){ .delay = 11, .feedback = g };
    var in = impulse(512);
    var out: [512]Sample(f32) = undefined;
    ap.process(&in, &out);
    for (out) |s| {
        try testing.expect(std.math.isFinite(s.ch[0]));
        try testing.expect(@abs(s.ch[0]) <= 1.0 + TOL); // never exceeds input peak
    }
}

test "Allpass: state carries across calls and split ≡ whole (BIT-EXACT)" {
    const N = 50;
    const k = 17;
    const D = 4;
    const g: f32 = 0.6;

    var whole: [N]f32 = undefined;
    {
        var ap = Allpass(num_f32, 8){ .delay = D, .feedback = g };
        var in = impulse(N);
        var out: [N]Sample(f32) = undefined;
        ap.process(&in, &out);
        whole = vals(N, &out);
    }
    var split: [N]f32 = undefined;
    {
        var ap = Allpass(num_f32, 8){ .delay = D, .feedback = g };
        var in = impulse(N);
        var out: [N]Sample(f32) = undefined;
        ap.process(in[0..k], out[0..k]);
        ap.process(in[k..], out[k..]);
        split = vals(N, &out);
    }
    try testing.expectEqual(whole, split);
}

// ===========================================================================
// KARPLUS-STRONG — analytic oracle (hand-rolled) + sustain characterization.
//   tap = ring[p];  filtered = 0.5·k·(tap + prev);  y = x + filtered;
//   ring[p] = y;  prev = tap
// For an impulse x[0]=1, D=2, damping=1.0 the hand trace gives:
//   y[0]=1, y[1]=0, y[2]=0.5, y[3]=0.5, y[4]=0.25, y[5]=0.5, ...
// ===========================================================================

test "KarplusStrong: early impulse response matches the hand-derived two-tap loop" {
    const D = 2;
    const k: f32 = 1.0; // no damping ⇒ exact rational arithmetic
    var ks = KarplusStrong(num_f32, 4){ .delay = D, .damping = k };
    var in = impulse(6);
    var out: [6]Sample(f32) = undefined;
    ks.process(&in, &out);
    // Hand-derived oracle (see header comment):
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[1].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[2].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[3].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[4].ch[0], TOL);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[5].ch[0], TOL);
}

test "KarplusStrong: an excitation burst SUSTAINS into later zero-input renders" {
    // The plucked-string signature: energy keeps recirculating after the input
    // goes silent. Excite, then drive zeros — the loop must still be ringing.
    const D = 8;
    var ks = KarplusStrong(num_f32, 16){ .delay = D, .damping = 0.999 };

    var burst: [8]Sample(f32) = undefined;
    for (&burst, 0..) |*s, i| s.* = S(if (i % 2 == 0) @as(f32, 0.8) else -0.8);
    var bout: [8]Sample(f32) = undefined;
    ks.process(&burst, &bout);

    var zin = silence(64);
    var zout: [64]Sample(f32) = undefined;
    ks.process(&zin, &zout);

    var late_peak: f32 = 0;
    for (zout) |s| late_peak = @max(late_peak, @abs(s.ch[0]));
    // Still clearly sounding well after the burst ended.
    try testing.expect(late_peak > 0.1);
    for (zout) |s| try testing.expect(std.math.isFinite(s.ch[0]));
}

test "KarplusStrong: damping < 1 DECAYS — a later window is quieter than an earlier one" {
    // damping<1 darkens and shortens the tone. Compare the peak of an early
    // sustain window with a much later one: the later must be strictly smaller.
    const D = 8;
    var ks = KarplusStrong(num_f32, 16){ .delay = D, .damping = 0.95 };

    var burst: [8]Sample(f32) = @splat(S(1.0));
    var bout: [8]Sample(f32) = undefined;
    ks.process(&burst, &bout);

    var early: [64]Sample(f32) = @splat(S(0));
    var eout: [64]Sample(f32) = undefined;
    ks.process(&early, &eout);

    var late: [64]Sample(f32) = @splat(S(0));
    var lout: [64]Sample(f32) = undefined;
    ks.process(&late, &lout);

    var early_peak: f32 = 0;
    for (eout) |s| early_peak = @max(early_peak, @abs(s.ch[0]));
    var late_peak: f32 = 0;
    for (lout) |s| late_peak = @max(late_peak, @abs(s.ch[0]));

    try testing.expect(early_peak > 0);
    try testing.expect(late_peak < early_peak); // monotone energy loss
}

test "KarplusStrong: damping = 0 collapses to a pure pass-through (loop is muted)" {
    // With damping 0 the feedback term vanishes ⇒ y[n] = x[n].
    var ks = KarplusStrong(num_f32, 8){ .delay = 4, .damping = 0.0 };
    var in = impulse(12);
    var out: [12]Sample(f32) = undefined;
    ks.process(&in, &out);
    try testing.expectEqual(@as(f32, 1.0), out[0].ch[0]);
    for (out[1..]) |s| try testing.expectEqual(@as(f32, 0.0), s.ch[0]);
}

test "KarplusStrong: split render ≡ whole render including the prev-tap state (BIT-EXACT)" {
    // The kernel carries TWO pieces of state across calls: the ring cursor AND
    // `prev`. A split that landed mid-loop would diverge if `prev` were not saved.
    const N = 80;
    const k = 19;
    const D = 9;
    const damp: f32 = 0.97;

    var whole: [N]f32 = undefined;
    {
        var ks = KarplusStrong(num_f32, 16){ .delay = D, .damping = damp };
        var in = impulse(N);
        var out: [N]Sample(f32) = undefined;
        ks.process(&in, &out);
        whole = vals(N, &out);
    }
    var split: [N]f32 = undefined;
    {
        var ks = KarplusStrong(num_f32, 16){ .delay = D, .damping = damp };
        var in = impulse(N);
        var out: [N]Sample(f32) = undefined;
        ks.process(in[0..k], out[0..k]);
        ks.process(in[k..], out[k..]);
        split = vals(N, &out);
    }
    try testing.expectEqual(whole, split);
}

// ===========================================================================
// CLASSIFICATION — each kernel is a `.Map`, declares `delay_len`, and does NOT
// declare `aliasing_safe`. This is the structural contract the colorer relies
// on: delay element (SCC-has-delay), opaque to fusion, never aliased in place.
// ===========================================================================

test "fused kernels classify as .Map across precisions and delay sizes" {
    try testing.expectEqual(port.BlockClass.Map, port.classify(Comb(num_f32, 64)));
    try testing.expectEqual(port.BlockClass.Map, port.classify(Allpass(num_f32, 64)));
    try testing.expectEqual(port.BlockClass.Map, port.classify(KarplusStrong(num_f32, 64)));
    try testing.expectEqual(port.BlockClass.Map, port.classify(Comb(num_f64, 7)));
    try testing.expectEqual(port.BlockClass.Map, port.classify(Allpass(num_f64, 3)));
    try testing.expectEqual(port.BlockClass.Map, port.classify(KarplusStrong(num_f64, 2)));
}

test "fused kernels declare delay_len equal to max_delay (they are delay elements)" {
    try testing.expectEqual(@as(usize, 64), Comb(num_f32, 64).delay_len);
    try testing.expectEqual(@as(usize, 33), Allpass(num_f32, 33).delay_len);
    try testing.expectEqual(@as(usize, 9), KarplusStrong(num_f32, 9).delay_len);
    try testing.expect(@hasDecl(Comb(num_f32, 64), "delay_len"));
    try testing.expect(@hasDecl(Allpass(num_f32, 64), "delay_len"));
    try testing.expect(@hasDecl(KarplusStrong(num_f32, 64), "delay_len"));
}

test "fused kernels deliberately do NOT declare aliasing_safe (no in-place output)" {
    // The state-dependent read-before-write would corrupt an in-place output, so
    // the absence of this decl is load-bearing — the colorer never aliases them.
    try testing.expect(!@hasDecl(Comb(num_f32, 64), "aliasing_safe"));
    try testing.expect(!@hasDecl(Allpass(num_f32, 64), "aliasing_safe"));
    try testing.expect(!@hasDecl(KarplusStrong(num_f32, 64), "aliasing_safe"));
}

// ===========================================================================
// DENORMAL / FLUSH-TO-ZERO — optional, platform-tolerant. After
// `enterRealtimeThread()` a long decaying Comb tail driven to subnormal
// magnitude must flush to EXACTLY 0 (the realtime token's FTZ guard) rather
// than lingering as a denormal. Gated on the live FP control word so the test
// is a no-op where FTZ is unavailable.
// ===========================================================================

test "Comb: a subnormal-magnitude tail flushes to exactly 0 under realtime FTZ" {
    const token = enterRealtimeThread();
    defer token.leave();

    if (!token.fpenv.active) {
        std.debug.print(
            "skip FTZ check: no FP control word on {s}\n",
            .{@tagName(builtin.cpu.arch)},
        );
        return;
    }

    // Seed the ring with a subnormal value and recirculate it through a stable
    // comb. Each pass multiplies by g<1, driving the state strictly deeper into
    // the subnormal range; the FTZ guard collapses every such result to 0, so the
    // whole tail must read EXACTLY zero (a non-FTZ env would keep tiny denormals).
    const tiny: f32 = std.math.floatMin(f32) / 4.0; // a subnormal
    var comb = Comb(num_f32, 4){ .delay = 1, .feedback = 0.5 };
    comb.ring[0] = tiny; // prime the recurrence directly into the subnormal band

    var in = silence(64);
    var out: [64]Sample(f32) = undefined;
    // Defeat constant folding so the multiplies run in the live FP environment.
    std.mem.doNotOptimizeAway(&comb);
    comb.process(&in, &out);
    std.mem.doNotOptimizeAway(&out);

    // With FTZ live, the very first feedback product (0.5·subnormal) underflows to
    // exactly 0 and stays there — no lingering denormal in the entire tail.
    for (out) |s| try testing.expectEqual(@as(f32, 0.0), s.ch[0]);
}
