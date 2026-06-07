//! Adaptive-filter cancellers and memoryless waveshaping / trim.
//!
//! `Aec` and `HowlSuppressor` are adaptive-FIR processors (normalized least-mean-
//! squares): an echo canceller and a leaky feedback/howl canceller. For an adaptive
//! FIR the "coefficient" is a whole tap vector, so its decoupled (vector-parameter)
//! realisation is heavier than the scalar dynamics case; these ship in the canonical
//! fused form (the controller and the applied filter inside one block). `SoftClip`
//! and `Trim` are stateless, per-element, `aliasing_safe` maps (in-place legal):
//! a cubic soft-clip waveshaper and a dB-domain static gain trim. All float-only,
//! declared loud via `requireFloat`.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;
const numeric = core.numeric;

const fxc = @import("fx_common.zig");
const scalarsConst = fxc.scalarsConst;
const scalars = fxc.scalars;
const requireFloat = fxc.requireFloat;

/// `Aec(num, taps)` — a **fused** acoustic-echo canceller: a normalized least-mean-
/// squares (NLMS) adaptive FIR. The far-end **reference** `x` is filtered by the
/// adapting taps `w` to estimate the echo present in the **mic** signal `d`; the
/// output is the error `e = d − ŵ·x`, i.e. the mic with the estimated echo removed.
/// Each sample the taps adapt by `w += μ·e·x_hist / (‖x_hist‖² + ε)` — the
/// normalization makes the step size independent of the reference's level, so it
/// converges across loud and quiet far-end speech. The controller (the adaptation)
/// and the applied filter live in one block — the canonical fused adaptive processor.
pub fn Aec(comptime num: numeric.Numeric, comptime taps: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (taps == 0) @compileError("pan: Aec taps must be >= 1");
    return struct {
        const Self = @This();
        /// The adaptive FIR taps (the echo-path estimate), persistent across calls.
        w: [taps]f32 = @splat(0),
        /// The reference delay line, newest sample at index 0.
        xhist: [taps]f32 = @splat(0),
        /// NLMS step size in (0, 2) — larger converges faster but is less stable.
        mu: f32 = 0.5,
        /// Regularization, floors the denominator so silence cannot blow up the step.
        eps: f32 = 1e-6,

        pub fn process(
            self: *Self,
            mic: []const types.Sample(T),
            ref: []const types.Sample(T),
            out: []types.Sample(T),
        ) void {
            const ds = scalarsConst(T, mic);
            const xs = scalarsConst(T, ref);
            const es = scalars(T, out);
            for (ds, xs, es) |d, x, *e| {
                // Shift the newest reference sample into the history (index 0 = newest).
                var k: usize = taps - 1;
                while (k > 0) : (k -= 1) self.xhist[k] = self.xhist[k - 1];
                self.xhist[0] = @floatCast(x);
                // Estimate the echo and the reference energy in one pass.
                var yhat: f32 = 0;
                var norm: f32 = self.eps;
                for (self.w, self.xhist) |wk, xk| {
                    yhat += wk * xk;
                    norm += xk * xk;
                }
                const err = @as(f32, @floatCast(d)) - yhat;
                const g = self.mu * err / norm; // NLMS step
                for (&self.w, self.xhist) |*wk, xk| wk.* += g * xk;
                e.* = @floatCast(err);
            }
        }
    };
}

/// `HowlSuppressor(num, taps)` — a **fused** acoustic-feedback (howl) suppressor: a
/// **leaky** NLMS adaptive FIR feedback canceller. Structurally like `Aec` — the
/// loudspeaker feed `x` (the reference) is filtered to estimate the feedback present
/// in the in-loop `primary` signal `d`, and the output is the suppressed error `e`.
/// The distinction is the **leakage** term: each step the taps are shrunk toward
/// zero (`w := (1 − leak)·w + step`). In a closed feedback loop the reference is
/// *correlated* with the desired signal (unlike an echo canceller's independent
/// far-end), which biases a plain adaptive filter; the leakage trades a little
/// cancellation depth for stability against that bias, which is exactly what keeps a
/// feedback canceller from itself ringing. Lower `leak` cancels harder but risks the
/// bias; higher `leak` is safer.
pub fn HowlSuppressor(comptime num: numeric.Numeric, comptime taps: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (taps == 0) @compileError("pan: HowlSuppressor taps must be >= 1");
    return struct {
        const Self = @This();
        w: [taps]f32 = @splat(0),
        xhist: [taps]f32 = @splat(0),
        mu: f32 = 0.5,
        eps: f32 = 1e-6,
        /// Leakage in [0, 1): the per-step tap shrinkage that decorrelates the
        /// adaptation from a reference correlated with the desired signal.
        leak: f32 = 1e-3,

        pub fn process(
            self: *Self,
            primary: []const types.Sample(T),
            ref: []const types.Sample(T),
            out: []types.Sample(T),
        ) void {
            const ds = scalarsConst(T, primary);
            const xs = scalarsConst(T, ref);
            const es = scalars(T, out);
            const keep = 1.0 - self.leak;
            for (ds, xs, es) |d, x, *e| {
                var k: usize = taps - 1;
                while (k > 0) : (k -= 1) self.xhist[k] = self.xhist[k - 1];
                self.xhist[0] = @floatCast(x);
                var yhat: f32 = 0;
                var norm: f32 = self.eps;
                for (self.w, self.xhist) |wk, xk| {
                    yhat += wk * xk;
                    norm += xk * xk;
                }
                const err = @as(f32, @floatCast(d)) - yhat;
                const g = self.mu * err / norm;
                for (&self.w, self.xhist) |*wk, xk| wk.* = keep * wk.* + g * xk; // leaky NLMS
                e.* = @floatCast(err);
            }
        }
    };
}

/// `SoftClip(num)` — a memoryless cubic soft-clip waveshaper. With `drive ≥ 1` the
/// input is scaled, passed through the cubic transfer curve, then scaled back so the
/// nominal unity slope is preserved at small signals:
///
///     u      = clamp(drive·x, −1, 1)
///     shaped = u − u³/3                         // odd, monotonic on [−1, 1]
///     y      = shaped / drive                    // undo the pre-gain at small signals
///
/// The cubic `u − u³/3` is the classic soft saturator: odd-symmetric (`f(−u) =
/// −f(u)`), monotonically increasing on `[−1, 1]`, and bounded — its slope is `1 −
/// u²`, which is `1` at the origin and falls to `0` at the rails (a smooth knee, no
/// hard corner). Dividing the shaped value by `drive` undoes the pre-gain, so the
/// small-signal slope is `drive · 1 · (1/drive) = 1` (quiet signals pass at unity,
/// transparent) while the post-clamp ceiling is `±(2/3)/drive` (the flat `±2/3` of
/// the curve at the rails, scaled back). The output therefore never exceeds that
/// soft ceiling regardless of input level. Higher `drive` reaches the saturating
/// region sooner and lowers the ceiling (more harmonic warmth, more level reduction).
///
/// Stateless and per-element ⇒ a pure `Map` and `aliasing_safe` (each output is a
/// function of only the matching input, so the colorer may run it in place). The
/// hot loop is a branch-free `@Vector` kernel (the clamp is `@min`/`@max` on lanes)
/// with a scalar tail, since a memoryless waveshaper is an ideal SIMD candidate.
/// Float lanes only.
pub fn SoftClip(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// Per-element write from only the matching input element ⇒ in-place legal.
        pub const aliasing_safe = true;

        /// Pre-gain into the cubic curve (≥ 1 drives harder into saturation).
        drive: T = 1.0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const d = self.drive;
            // Undo the pre-gain so the small-signal slope is unity (drive·1·(1/drive)
            // = 1): quiet signals pass transparently, while the post-clamp ceiling is
            // ±(2/3)/drive — the flat rail value of the curve scaled back.
            const inv: T = 1.0 / d;

            const lanes = num.W;
            const V = @Vector(lanes, T);
            const one: V = @splat(@as(T, 1));
            const neg_one: V = @splat(@as(T, -1));
            const third: V = @splat(@as(T, 1.0 / 3.0));
            const dv: V = @splat(d);
            const invv: V = @splat(inv);

            var i: usize = 0;
            while (i + lanes <= xs.len) : (i += lanes) {
                const x: V = xs[i..][0..lanes].*;
                const u = @min(@max(x * dv, neg_one), one); // clamp(drive·x, −1, 1)
                const shaped = u - u * u * u * third; // u − u³/3
                ys[i..][0..lanes].* = shaped * invv;
            }
            // Scalar tail for the remainder (identical arithmetic, lane width 1).
            while (i < xs.len) : (i += 1) {
                const u = std.math.clamp(xs[i] * d, -1.0, 1.0);
                ys[i] = (u - u * u * u * (1.0 / 3.0)) * inv;
            }
        }
    };
}

/// `Trim(num)` — a static gain trim specified in **decibels**. Unlike `Vca` (whose
/// gain is a signal-controlled, ramped parameter port) the trim is a fixed mixing
/// offset the author sets once: `y = x · 10^(gain_db/20)`. It is the dB-domain face
/// of `filters.Gain` (which takes a raw linear/fixed-point coefficient): the *only*
/// difference is that `Trim` converts dB → linear for you, so 0 dB is unity, −6 dB ≈
/// 0.5012, +6 dB ≈ 1.995. Where you already have a linear coefficient (or need the
/// fixed-point lane), reach for `filters.Gain`; where you think in dB, reach for
/// `Trim`. (This overlap is deliberate and surfaced rather than duplicated — `Trim`
/// is float-only because the dB conversion is a float operation.)
///
/// Stateless and per-element ⇒ a `Map` and `aliasing_safe` (in-place legal).
pub fn Trim(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// Per-element write from only the matching input element ⇒ in-place legal.
        pub const aliasing_safe = true;

        /// The trim in decibels (0 = unity). Converted to a linear multiplier in
        /// `process`: linear = 10^(dB/20).
        gain_db: T = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            // dB → linear amplitude: a 20·log10 scale, so +6 dB ≈ ×2, −6 dB ≈ ÷2.
            const g: T = std.math.pow(T, 10.0, self.gain_db / 20.0);
            const lanes = num.W;
            const V = @Vector(lanes, T);
            const gv: V = @splat(g);
            var i: usize = 0;
            while (i + lanes <= xs.len) : (i += lanes) {
                const x: V = xs[i..][0..lanes].*;
                ys[i..][0..lanes].* = x * gv;
            }
            while (i < xs.len) : (i += 1) ys[i] = xs[i] * g;
        }
    };
}

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

fn S(x: f32) types.Sample(f32) {
    return .{ .ch = .{x} };
}

/// A deterministic broadband-ish reference for the adaptive-filter tests: a sum of
/// two incommensurate tones, rich enough for the NLMS to converge.
fn refSignal(n: usize) f32 {
    const t: f32 = @floatFromInt(n);
    return 0.5 * @sin(0.7 * t) + 0.5 * @sin(1.9 * t + 0.4);
}

test "Aec: NLMS converges — a delayed-echo mic is progressively cancelled" {
    var aec = Aec(f32num, 8){ .mu = 0.5 };
    // Echo path = the reference delayed by 2 samples, gain 0.8 (desired signal = 0,
    // so a perfect canceller drives the error to 0). Feed many blocks; the residual
    // error energy must fall sharply as the taps adapt.
    var ref_prev = [_]f32{0} ** 2;
    var first_energy: f32 = 0;
    var last_energy: f32 = 0;
    const blocks = 200;
    var b: usize = 0;
    var nidx: usize = 0;
    while (b < blocks) : (b += 1) {
        var mic: [16]types.Sample(f32) = undefined;
        var ref: [16]types.Sample(f32) = undefined;
        for (0..16) |i| {
            const x = refSignal(nidx);
            nidx += 1;
            ref[i] = S(x);
            mic[i] = S(0.8 * ref_prev[1]); // echo: ref delayed 2, scaled 0.8
            ref_prev[1] = ref_prev[0];
            ref_prev[0] = x;
        }
        var out: [16]types.Sample(f32) = undefined;
        aec.process(&mic, &ref, &out);
        var energy: f32 = 0;
        for (out) |e| energy += e.ch[0] * e.ch[0];
        if (b == 0) first_energy = energy;
        if (b == blocks - 1) last_energy = energy;
    }
    // The adaptive filter cancels the echo: late-block residual ≪ first-block.
    try testing.expect(last_energy < first_energy * 0.05);
}

test "HowlSuppressor: leaky NLMS converges and keeps the taps bounded" {
    var hs = HowlSuppressor(f32num, 8){ .mu = 0.5, .leak = 1e-3 };
    var ref_prev: f32 = 0;
    var first_energy: f32 = 0;
    var last_energy: f32 = 0;
    const blocks = 200;
    var b: usize = 0;
    var nidx: usize = 0;
    while (b < blocks) : (b += 1) {
        var primary: [16]types.Sample(f32) = undefined;
        var ref: [16]types.Sample(f32) = undefined;
        for (0..16) |i| {
            const x = refSignal(nidx);
            nidx += 1;
            ref[i] = S(x);
            primary[i] = S(0.7 * ref_prev); // feedback: ref delayed 1, scaled 0.7
            ref_prev = x;
        }
        var out: [16]types.Sample(f32) = undefined;
        hs.process(&primary, &ref, &out);
        var energy: f32 = 0;
        for (out) |e| energy += e.ch[0] * e.ch[0];
        if (b == 0) first_energy = energy;
        if (b == blocks - 1) last_energy = energy;
    }
    try testing.expect(last_energy < first_energy * 0.1); // suppressed (leakage caps depth)
    // Leakage keeps the taps finite/bounded — no runaway.
    var wmax: f32 = 0;
    for (hs.w) |wk| wmax = @max(wmax, @abs(wk));
    try testing.expect(wmax < 10.0 and std.math.isFinite(wmax));
}

// ---------------------------------------------------------------------------
// Waveshaping/trim gaps: SoftClip, Trim. Tests encode the defining guarantee of
// each block (Rule 9: WHY, not just WHAT) — the waveshaper's odd/monotone/bounded
// laws and the exact dB→linear conversion.
// ---------------------------------------------------------------------------

test "SoftClip: classifies as an aliasing-safe Map" {
    const port = core.port;
    const SC = SoftClip(f32num);
    try testing.expect(port.classify(SC) == .Map);
    try testing.expect(SC.aliasing_safe);
}

test "SoftClip: odd-symmetric, monotonic, and bounded waveshaper" {
    var sc = SoftClip(f32num){ .drive = 1.0 };
    // A ramp from −2 to +2 (well past the rails) at drive 1.
    const n = 41;
    var in: [n]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(-2.0 + @as(f32, @floatFromInt(i)) * (4.0 / 40.0));
    var out: [n]types.Sample(f32) = undefined;
    sc.process(&in, &out);

    // Odd symmetry: f(−x) = −f(x). Pair index i with its mirror (n−1−i), which is
    // the negated input by construction of the symmetric ramp.
    for (0..n) |i| {
        const mirror = out[n - 1 - i].ch[0];
        try testing.expectApproxEqAbs(out[i].ch[0], -mirror, 1e-5);
    }
    // Monotonic non-decreasing: the cubic's slope 1−u² ≥ 0 on the clamped domain.
    for (1..n) |i| try testing.expect(out[i].ch[0] >= out[i - 1].ch[0] - 1e-6);
    // Bounded: the normalized soft ceiling is ±1 (at the rails u=±1, shaped=±2/3,
    // divided by 2/3 gives ±1); no output escapes it even for the ±2 overdrive.
    for (out) |s| try testing.expect(@abs(s.ch[0]) <= 1.0 + 1e-6);
    // Zero maps to zero (the curve passes through the origin): index 20 is the
    // midpoint of the −2..+2 ramp, i.e. exactly x = 0.
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[20].ch[0], 1e-6);
}

test "SoftClip: small signal is near-transparent; drive deepens saturation" {
    var sc = SoftClip(f32num){ .drive = 1.0 };
    // A small 0.05 input: slope ≈ 1 at the origin, so output ≈ input.
    var small: [8]types.Sample(f32) = @splat(S(0.05));
    var sout: [8]types.Sample(f32) = undefined;
    sc.process(&small, &sout);
    try testing.expectApproxEqAbs(@as(f32, 0.05), sout[0].ch[0], 2e-3);

    // Same mid-level input at higher drive saturates harder: the signal is pushed
    // deeper into the compressing region of the curve, so the applied gain
    // (output/input) is LOWER and the output level is reduced (the level-taming /
    // soft-ceiling effect of a waveshaper). drive 1: 0.6 − 0.6³/3 = 0.528; drive 3:
    // u clamps to 1, shaped 2/3, /3 = 0.222.
    var mid: [8]types.Sample(f32) = @splat(S(0.6));
    var m1: [8]types.Sample(f32) = undefined;
    sc.process(&mid, &m1);
    var sc2 = SoftClip(f32num){ .drive = 3.0 };
    var m2: [8]types.Sample(f32) = undefined;
    sc2.process(&mid, &m2);
    try testing.expect(m2[0].ch[0] < m1[0].ch[0]); // harder drive saturates → more gain reduction
    try testing.expectApproxEqAbs(@as(f32, 0.528), m1[0].ch[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0 / 3.0), m2[0].ch[0], 1e-5);
}

test "Trim: aliasing-safe Map applying the exact dB→linear gain" {
    const port = core.port;
    const Tr = Trim(f32num);
    try testing.expect(port.classify(Tr) == .Map);
    try testing.expect(Tr.aliasing_safe);

    // 0 dB is unity.
    var t0 = Trim(f32num){ .gain_db = 0 };
    var in: [16]types.Sample(f32) = @splat(S(0.5));
    var out: [16]types.Sample(f32) = undefined;
    t0.process(&in, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0].ch[0], 1e-6);

    // −6.0206 dB is exactly ×0.5 (20·log10(0.5)); +6.0206 dB is ×2.
    var tm6 = Trim(f32num){ .gain_db = -20.0 * std.math.log10(@as(f32, 2.0)) };
    tm6.process(&in, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0].ch[0], 1e-5); // 0.5 × 0.5
    var tp6 = Trim(f32num){ .gain_db = 20.0 * std.math.log10(@as(f32, 2.0)) };
    tp6.process(&in, &out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].ch[0], 1e-5); // 0.5 × 2
    // Verify the scalar tail path matches by using a non-multiple-of-W length.
    var odd: [13]types.Sample(f32) = @splat(S(1.0));
    var oout: [13]types.Sample(f32) = undefined;
    tp6.process(&odd, &oout);
    try testing.expectApproxEqAbs(@as(f32, 2.0), oout[12].ch[0], 1e-5);
}
