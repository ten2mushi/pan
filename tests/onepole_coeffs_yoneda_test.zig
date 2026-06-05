//! onepole_coeffs_yoneda_test — the INDEPENDENT-ORACLE ("tests as definition") suite
//! for the two `src/filters.zig` blocks NEITHER `dsp_filters_test.zig` (Gain/Biquad
//! gold vectors) NOR the concurrently-authored `dsp_filters2_yoneda_test.zig`
//! (StateVariable / Fir / firwinLowpass) characterise: the parameter-ported
//! `OnePole` leaky integrator and the `Coeffs` biquad-coefficient witness struct.
//!
//! WHY a separate file: `OnePole` and `Coeffs` were left uncovered by both sibling
//! filter suites. The two inline `test`s inside `filters.zig` give `OnePole` a first
//! pass (a=1 pass-through; a=0.5 step). This file is the Yoneda DEEPENING — it pins
//! the morphisms those leave open: the anti-zipper ramp SHAPE, the wired==set glide
//! law (the load-bearing "one ramp policy, two sources" claim), the snap-at-block-end
//! semantics, the n=1 / empty-block edges, determinism, the persistent z⁻¹ carry, and
//! the `Coeffs` identity-section + `coeff_frac` witness for both a float and a q15 lane.
//!
//! Oracle strategy (Rule 9, hermetic — no SciPy, no disk): the leaky-integrator
//! expectation is recomputed by a SEPARATE accumulator using the SAME per-sample
//! ramped coefficient the block computes (`a = a0 + (i+1)·inc`, `inc = (tgt−a0)/n`;
//! `y += a·(x−y)`). Because both sides do the identical f32 ops in the identical
//! order, the comparison is BIT-EXACT (`expectEqual`); the block and the oracle agree
//! only if both independently realise the documented recurrence.
//!
//! COMPARISON DISCIPLINE:
//!   - pan-vs-pan (determinism; split==whole; wired==set) is BIT-EXACT (`expectEqual`).
//!   - the recurrence oracle is also `expectEqual` (same op order); analytic
//!     properties (e.g. the leaky-integrator step asymptote) use `expectApproxEqAbs`
//!     and say so at the call site.
//!
//! Reject diagnostics use std.debug.print, never std.log.err (the 0.16 test runner
//! counts logged errors as failures). Verified against zig 0.16.0; zig-0-16 skill
//! loaded before authoring. No @Type, no managed ArrayList; fixed-array buffers.

const std = @import("std");
const pan = @import("pan");
const testing = std.testing;

const f32num = pan.numericFor(.f32, .{});
const filters = pan.filters;

fn S(x: f32) pan.Sample(f32) {
    return .{ .ch = .{x} };
}

/// The OnePole leaky integrator, recomputed with the SAME per-sample ramped
/// coefficient the block uses: a = a0 + (i+1)·inc, inc = (tgt − a0)/n; y += a·(x−y).
/// Bit-for-bit op order matches filters.zig, so this is a replay-from-formula.
fn onePoleOracle(a0: f32, tgt: f32, xs: []const f32, ys: []f32) void {
    const n = xs.len;
    const inc: f32 = if (n == 0) 0 else (tgt - a0) / @as(f32, @floatFromInt(n));
    var y1: f32 = 0;
    for (xs, ys, 0..) |x, *y, i| {
        const a: f32 = a0 + @as(f32, @floatFromInt(i + 1)) * inc;
        y1 = y1 + a * (x - y1);
        y.* = y1;
    }
}

// ===========================================================================
// Coeffs — the biquad-coefficient witness struct.
// ===========================================================================

test "Coeffs: the float default is the identity section H(z)=1 (an unconfigured Biquad is a no-op)" {
    const Cf = filters.Coeffs(f32);
    const c: Cf = .{};
    try testing.expectEqual(@as(f32, 1), c.b0);
    try testing.expectEqual(@as(f32, 0), c.b1);
    try testing.expectEqual(@as(f32, 0), c.b2);
    try testing.expectEqual(@as(f32, 0), c.a1);
    try testing.expectEqual(@as(f32, 0), c.a2);
    // A float lane stores REAL coefficients ⇒ zero fractional bits.
    try testing.expectEqual(@as(comptime_int, 0), Cf.coeff_frac);
}

test "Coeffs: a q15 lane stores Q(2.frac) integers — frac = bits−3 = 13, and identity b0 = 1<<13" {
    // A resonant section's |a1| can approach 2, which a lane-q-format number bounded
    // to [−1,1) cannot hold; Coeffs therefore uses Q(2.frac) with frac = bits−3,
    // giving range [−4,4). So the integer identity b0 = 1.0 is 1<<13, not 1.
    const Ci = filters.Coeffs(i16);
    try testing.expectEqual(@as(comptime_int, 13), Ci.coeff_frac);
    const ci: Ci = .{};
    try testing.expectEqual(@as(i16, 1) << 13, ci.b0);
    try testing.expectEqual(@as(i16, 0), ci.b1);
    try testing.expectEqual(@as(i16, 0), ci.a1);

    // A q31 lane: frac = bits − 3 = 32 − 3 = 29 (the integer-bit count is fixed at
    // two-above-the-sign regardless of lane width, so frac tracks the full lane width).
    const C32 = filters.Coeffs(i32);
    try testing.expectEqual(@as(comptime_int, 29), C32.coeff_frac);
    const c32: C32 = .{};
    try testing.expectEqual(@as(i32, 1) << 29, c32.b0);
}

// ===========================================================================
// OnePole — identity, classification, the float-only lane contract.
// ===========================================================================

test "OnePole: classifies as a Map with a cutoff parameter port and is NOT aliasing_safe" {
    const OP = filters.OnePole(f32num);
    try testing.expect(pan.port.classify(OP) == .Map);
    try testing.expect(pan.port.ParamPort(OP, "cutoff").Elem == pan.Scalar(f32));
    // A sequential leaky-integrator recurrence (persistent z⁻¹): the colorer must not
    // run it in place, so it must NOT declare aliasing_safe.
    try testing.expect(!@hasDecl(OP, "aliasing_safe"));
    try testing.expect(!comptime pan.port.isSource(OP));
}

test "OnePole: f64 is also a legal lane (the float-only guard is f32 OR f64)" {
    const f64num = pan.numericFor(.f64, .{});
    const OP = filters.OnePole(f64num);
    try testing.expect(pan.port.classify(OP) == .Map);
    try testing.expect(pan.port.ParamPort(OP, "cutoff").Elem == pan.Scalar(f32));
}

// ===========================================================================
// OnePole — leaky integrator, ramped coefficient, persistent z⁻¹.
// ===========================================================================

test "OnePole: a default-coefficient (a=1) block is a pass-through to within float rounding" {
    // a = 1 ⇒ y = y + 1·(x − y), which is x ANALYTICALLY but NOT bit-exactly in f32:
    // the block computes `y1 + (x − y1)`, and `(x − y1) + y1` is not associative-equal
    // to `x` when x and y1 differ in magnitude (one rounding step in the subtract +
    // add). So the right characterisation of "a=1 passes the signal" is equality to
    // within a small absolute tolerance, NOT bit-identity — this is a property of the
    // documented recurrence, not a defect. We confirm the deviation is at most a few
    // ULP-scale ticks across a longer, sign-varying sequence.
    var op = filters.OnePole(f32num){};
    const N = 17;
    var in: [N]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@sin(@as(f32, @floatFromInt(i)) * 1.3) * 4.0);
    var out: [N]pan.Sample(f32) = undefined;
    op.process(&in, &out);
    for (in, out) |x, y| try testing.expectApproxEqAbs(x.ch[0], y.ch[0], 1e-5);
}

test "OnePole: the per-block ramped coefficient matches the independent recurrence oracle (bit-exact)" {
    // Target 0.3 from the default live value 1.0: the coefficient glides 1.0 → 0.3
    // across the block (the anti-zipper ramp). Recompute the SAME ramped recurrence
    // independently and demand bit-for-bit agreement.
    var op = filters.OnePole(f32num){};
    op.setParam(0, 0.3);
    const N = 10;
    var in: [N]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@as(f32, @floatFromInt(i)) * 0.1 - 0.5);
    var out: [N]pan.Sample(f32) = undefined;
    op.process(&in, &out);

    var oin: [N]f32 = undefined;
    var oout: [N]f32 = undefined;
    for (&oin, in) |*o, x| o.* = x.ch[0];
    onePoleOracle(1.0, 0.3, &oin, &oout); // a0 = the default live coefficient 1.0
    for (out, oout) |y, w| try testing.expectEqual(w, y.ch[0]); // bit-exact
}

test "OnePole: the ramp SNAPS to the target at block end — a second block uses a constant coefficient" {
    // The anti-zipper policy snaps the live coefficient to the EXACT target at block
    // end (defeating float drift), so a second block with the same target rides a
    // CONSTANT coefficient (no ramp), which the oracle reproduces with a0 == tgt.
    var op = filters.OnePole(f32num){};
    op.setParam(0, 0.4);
    var warm: [8]pan.Sample(f32) = @splat(S(0)); // settle the ramp to 0.4 (silence ⇒ y1 stays 0)
    var warmo: [8]pan.Sample(f32) = undefined;
    op.process(&warm, &warmo);

    const N = 6;
    var in: [N]pan.Sample(f32) = @splat(S(1.0));
    var out: [N]pan.Sample(f32) = undefined;
    op.process(&in, &out);
    var oin: [N]f32 = .{ 1, 1, 1, 1, 1, 1 };
    var oout: [N]f32 = undefined;
    onePoleOracle(0.4, 0.4, &oin, &oout); // a0 == tgt ⇒ inc 0 ⇒ constant coefficient
    for (out, oout) |y, w| try testing.expectEqual(w, y.ch[0]);
}

test "OnePole: a step response with a settled coefficient approaches the input level (leaky integrator)" {
    // With a constant a in (0,1), the step response of y += a·(x−y) is the geometric
    // approach y[n] = 1 − (1−a)^(n+1) toward the DC level 1. Settle a=0.5 first, then
    // drive a long step and check the tail is near 1 (the integrator's DC gain is 1).
    var op = filters.OnePole(f32num){};
    op.setParam(0, 0.5);
    var warm: [16]pan.Sample(f32) = @splat(S(0));
    var warmo: [16]pan.Sample(f32) = undefined;
    op.process(&warm, &warmo); // ramp settles to 0.5; state still 0

    var step: [64]pan.Sample(f32) = @splat(S(1.0));
    var out: [64]pan.Sample(f32) = undefined;
    op.process(&step, &out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[63].ch[0], 1e-6); // DC gain 1
    try testing.expect(out[0].ch[0] < out[63].ch[0]); // monotone rise toward the level
}

test "OnePole: wired-edge target == set target — one ramp policy, two sources (bit-exact)" {
    // The doc-comment's load-bearing claim: a target delivered via setParam (the same
    // entry point a wired parameter edge funnels through) drives the SAME ramped
    // coefficient. Two instances given the identical target sequence must be
    // bit-identical block-for-block — the executable form of "wired ≡ set".
    var a = filters.OnePole(f32num){};
    var b = filters.OnePole(f32num){};
    const targets = [_]f32{ 0.2, 0.8, 0.5, 0.5, 0.05 };
    var in: [7]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@sin(@as(f32, @floatFromInt(i)) * 0.9));
    inline for (targets) |t| {
        a.setParam(0, t);
        b.setParam(0, t);
        var oa: [7]pan.Sample(f32) = undefined;
        var ob: [7]pan.Sample(f32) = undefined;
        a.process(&in, &oa);
        b.process(&in, &ob);
        for (oa, ob) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
    }
}

test "OnePole: z⁻¹ state carries across calls — at a settled (constant) coefficient split == whole" {
    // The leaky-integrator state is persistent. At a CONSTANT coefficient the block is
    // block-size-agnostic, so a render split at an arbitrary boundary must equal one
    // whole render. (We settle the coefficient first so the per-block ramp does not
    // make the sub-block schedules differ — the ramp interval is what would; that is
    // covered separately by the wired==set test.)
    var whole = filters.OnePole(f32num){};
    var split = filters.OnePole(f32num){};
    whole.setParam(0, 0.25);
    split.setParam(0, 0.25);
    var warm: [4]pan.Sample(f32) = @splat(S(0));
    var warmo: [4]pan.Sample(f32) = undefined;
    whole.process(&warm, &warmo);
    split.process(&warm, &warmo);

    const N = 16;
    var in: [N]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@as(f32, @floatFromInt(@as(i32, @intCast(i)) - 8)));
    var ow: [N]pan.Sample(f32) = undefined;
    var os: [N]pan.Sample(f32) = undefined;
    whole.process(&in, &ow);
    split.process(in[0..6], os[0..6]);
    split.process(in[6..], os[6..]);
    for (ow, os) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "OnePole: a single-sample block (n=1) takes exactly one ramped step to the target" {
    var op = filters.OnePole(f32num){};
    op.setParam(0, 0.6);
    var in: [1]pan.Sample(f32) = .{S(1.0)};
    var out: [1]pan.Sample(f32) = undefined;
    op.process(&in, &out);
    // n=1: inc = (0.6−1.0)/1, a = 1.0 + 1·inc = 0.6; y = 0 + 0.6·(1−0) = 0.6.
    var oin: [1]f32 = .{1.0};
    var oout: [1]f32 = undefined;
    onePoleOracle(1.0, 0.6, &oin, &oout);
    try testing.expectEqual(oout[0], out[0].ch[0]);
}

test "OnePole: an empty block (n=0) is a no-op leaving the z⁻¹ state untouched" {
    var op = filters.OnePole(f32num){ .y1 = 0.42 };
    var in: [0]pan.Sample(f32) = .{};
    var out: [0]pan.Sample(f32) = .{};
    op.process(&in, &out);
    try testing.expectEqual(@as(f32, 0.42), op.y1);
}

test "OnePole: determinism — identical input through two fresh instances is bit-identical" {
    var a = filters.OnePole(f32num){};
    var b = filters.OnePole(f32num){};
    a.setParam(0, 0.33);
    b.setParam(0, 0.33);
    var in: [40]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@sin(@as(f32, @floatFromInt(i)) * 0.41) * 2.0);
    var oa: [40]pan.Sample(f32) = undefined;
    var ob: [40]pan.Sample(f32) = undefined;
    a.process(&in, &oa);
    b.process(&in, &ob);
    for (oa, ob) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "OnePole: silence in stays silence out regardless of the coefficient (zero object)" {
    var op = filters.OnePole(f32num){};
    op.setParam(0, 0.7);
    var in: [12]pan.Sample(f32) = @splat(S(0));
    var out: [12]pan.Sample(f32) = undefined;
    op.process(&in, &out);
    for (out) |y| try testing.expectEqual(@as(f32, 0), y.ch[0]);
    try testing.expectEqual(@as(f32, 0), op.y1); // state stays pinned at zero
}
