//! Small, genuinely-shared DSP arithmetic primitives — the handful of expressions
//! that several blocks compute identically. Each helper reproduces its callers'
//! expression in the SAME operand order so the numeric result is bit-identical to
//! the inlined original; do not reassociate the arithmetic here.

const std = @import("std");

/// Wrap a phase into the half-open unit interval `[0, 1)` by subtracting its floor.
/// For a non-negative `p` this returns the fractional part `p − floor(p)`.
pub fn wrapPhase(p: f32) f32 {
    return p - @floor(p);
}

/// Advance a normalized phase by `increment` and wrap into `[0, 1)`. The sum and the
/// floor are taken over the SAME `(phase + increment)` value, in that order, so the
/// result is bit-identical to computing
/// `phase + increment - @floor(phase + increment)` inline.
pub fn advancePhase(phase: f32, increment: f32) f32 {
    return wrapPhase(phase + increment);
}

/// Apply a per-sample-ramped gain to `xs`, writing `ys`: begin a ramp toward
/// `target` over `xs.len` samples, then for sample `i` multiply by the gain
/// `ramp.value + (i+1)·inc` (cast to `T`), and finally snap the ramp to `target`.
/// The per-sample gain and the multiply are evaluated in this exact order so the
/// output matches the inlined loop bit-for-bit. `ramp` is a `*control.Ramp` (taken
/// as `anytype` to avoid importing the control type here).
pub fn applyRampedGain(comptime T: type, ramp: anytype, target: f32, xs: []const T, ys: []T) void {
    const inc = ramp.begin(target, xs.len);
    for (xs, ys, 0..) |x, *y, i| {
        const g: T = @floatCast(ramp.value + @as(f32, @floatFromInt(i + 1)) * inc);
        y.* = x * g;
    }
    ramp.finish(target);
}

test "wrapPhase / advancePhase match the inline expressions bit-for-bit" {
    const phase: f32 = 0.7;
    const increment: f32 = 0.6;
    // advancePhase must equal the original `phase + increment - @floor(...)`.
    const inline_expr = phase + increment - @floor(phase + increment);
    try std.testing.expectEqual(inline_expr, advancePhase(phase, increment));
    // wrapPhase must equal `p - @floor(p)`.
    const p: f32 = 3.25;
    try std.testing.expectEqual(p - @floor(p), wrapPhase(p));
}

// ===========================================================================
// Yoneda specification suite — characterise the three helpers through all the
// morphisms (inputs, states, algebraic laws) their callers depend on. The point
// is not to re-check `p - @floor(p)`, but to PIN the contracts the oscillators
// (gen.zig: Lfo/Sine/PolyBlepSaw/PolyBlepSquare/Wavetable) and dynamics blocks
// (fx_dynamics.zig: Vca/Agc) silently rely on, so that any future edit that
// changes the numeric meaning is caught here rather than as an audible glitch.
// ===========================================================================

const Ramp = @import("pan_core").control.Ramp;

// --- wrapPhase: the [0,1) fractional-part contract -------------------------

test "wrapPhase: is the identity on the half-open unit interval [0,1)" {
    // The oscillators store `phase ∈ [0,1)` and re-wrap it every block; wrapping a
    // value already in range must NOT perturb it, or a steady tone would drift.
    // Bit-exact identity is required (not approx) — these are stored Mealy state.
    const xs = [_]f32{ 0.0, 1e-7, 0.25, 0.5, 0.7, 0.9999999 };
    for (xs) |x| try std.testing.expectEqual(x, wrapPhase(x));
}

test "wrapPhase: maps every nonnegative integer to exactly 0" {
    // A phase that lands on a whole cycle is the start of the next cycle: 0.
    for ([_]f32{ 0, 1, 2, 5, 1000, 8.388608e6 }) |n|
        try std.testing.expectEqual(@as(f32, 0), wrapPhase(n));
}

test "wrapPhase: result lies in [0,1) for in-range and typical out-of-range inputs" {
    // The range invariant the callers depend on. NOTE: this is NOT universally
    // true for f32 — see the dedicated 'rounds up to exactly 1.0' test below for
    // the inputs where `p - @floor(p)` rounds to 1.0. Here we assert the contract
    // holds for the inputs the oscillators actually produce (small positive
    // fractional advances of an in-range phase).
    var p: f32 = 0;
    const inc: f32 = 0.3173828125; // an exact dyadic step, no accumulation error
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        p = advancePhase(p, inc);
        try std.testing.expect(p >= 0.0 and p < 1.0);
    }
}

test "wrapPhase: negative inputs wrap UP into [0,1) (floor rounds toward -inf)" {
    // Decreasing-phase consumers (e.g. a negative increment) rely on @floor going
    // toward −∞, so −0.25 becomes +0.75, not −0.25 and not +0.25. Use exactly
    // representable (dyadic) inputs for bit-exact assertions.
    try std.testing.expectEqual(@as(f32, 0.75), wrapPhase(-0.25));
    try std.testing.expectEqual(@as(f32, 0.5), wrapPhase(-1.5));
    try std.testing.expectEqual(@as(f32, 0.625), wrapPhase(-3.375));
    // A non-dyadic input (-2.1 has no exact f32) still wraps to ≈0.9; the binding
    // contract is bit-equality with the inline `p - @floor(p)`, which f32 rounding
    // makes 0.9000001 — so assert the inline oracle exactly AND the range invariant.
    const non_dyadic: f32 = -2.1;
    try std.testing.expectEqual(non_dyadic - @floor(non_dyadic), wrapPhase(non_dyadic));
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), wrapPhase(non_dyadic), 1e-6);
}

test "wrapPhase: is idempotent — wrapPhase∘wrapPhase == wrapPhase" {
    // Re-wrapping an already-wrapped phase is a no-op; the oscillators wrap once
    // per block and per sample without compounding error.
    for ([_]f32{ -2.1, -0.25, 0.0, 0.7, 3.25, 100.6, 1.9999999 }) |x| {
        const once = wrapPhase(x);
        try std.testing.expectEqual(once, wrapPhase(once));
    }
}

test "wrapPhase: exact dyadic fractions are preserved bit-for-bit" {
    // Wavetable/PolyBLEP read the wrapped phase directly; powers-of-two fractions
    // must survive the subtraction exactly (they are representable).
    try std.testing.expectEqual(@as(f32, 0.25), wrapPhase(4.25));
    try std.testing.expectEqual(@as(f32, 0.5), wrapPhase(7.5));
    try std.testing.expectEqual(@as(f32, 0.125), wrapPhase(2.125));
}

test "wrapPhase: a tiny negative input rounds UP to exactly 1.0 (documented edge)" {
    // This DOCUMENTS a real float boundary, not a bug: for a tiny negative `p`,
    // @floor(p) == -1, and `p - (-1)` rounds to exactly 1.0 — outside [0,1). The
    // callers never feed wrapPhase a negative value this small (phase advances are
    // small POSITIVE steps of an in-range phase), so the [0,1) invariant is
    // preserved in practice; this test pins the boundary so a future caller that
    // *could* hit it is warned by reading the spec.
    const tiny: f32 = -1e-30;
    try std.testing.expectEqual(@as(f32, 1.0), wrapPhase(tiny));
}

// --- advancePhase: wrap-of-sum, the oscillator phase accumulator ------------

test "advancePhase: equals wrapPhase(phase+increment) bit-for-bit" {
    // The definitional law. Sine.tick/PolyBlep*/Wavetable all advance via this; if
    // it ever diverged from wrap-of-sum the pitch would be wrong.
    const cases = [_][2]f32{
        .{ 0.0, 0.01 }, .{ 0.7, 0.6 },     .{ 0.5, 0.5 },
        .{ 0.9, 0.2 },  .{ 0.123, 0.877 }, .{ 0.25, -0.5 },
    };
    for (cases) |c| {
        const phase = c[0];
        const inc = c[1];
        try std.testing.expectEqual(wrapPhase(phase + inc), advancePhase(phase, inc));
        // And bit-identical to the fully-inlined original expression.
        try std.testing.expectEqual(
            phase + inc - @floor(phase + inc),
            advancePhase(phase, inc),
        );
    }
}

test "advancePhase: a zero increment is the identity on an in-range phase" {
    // A silent / DC oscillator (increment 0) must hold its phase exactly.
    for ([_]f32{ 0.0, 0.25, 0.5, 0.7, 0.9999999 }) |p|
        try std.testing.expectEqual(p, advancePhase(p, 0.0));
}

test "advancePhase: a full-cycle increment returns to the same phase" {
    // Advancing by an integer number of cycles is a no-op on the fractional phase.
    try std.testing.expectEqual(@as(f32, 0.25), advancePhase(0.25, 1.0));
    try std.testing.expectEqual(@as(f32, 0.25), advancePhase(0.25, 3.0));
    try std.testing.expectEqual(@as(f32, 0.0), advancePhase(0.0, 5.0));
}

test "advancePhase: a large multi-cycle increment wraps to the right fraction" {
    // High frequencies / block-rate LFO advances cross many cycles in one step;
    // only the fractional remainder must survive. 0.1 + 10.4 = 10.5 → 0.5.
    try std.testing.expectEqual(@as(f32, 0.5), advancePhase(0.1, 10.4));
    // The Lfo advances by increment·out.len; emulate a big block step.
    try std.testing.expectEqual(wrapPhase(0.3 + 1000.7), advancePhase(0.3, 1000.7));
}

test "advancePhase: a negative increment steps backward and wraps into [0,1)" {
    // A reverse-running phase (negative increment) must wrap up, never go negative.
    const r = advancePhase(0.2, -0.5); // 0.2 - 0.5 = -0.3 → 0.7
    try std.testing.expectEqual(@as(f32, 0.7), r);
    try std.testing.expect(r >= 0.0 and r < 1.0);
}

test "advancePhase: keeps a swept phase bounded over many steps (no escape)" {
    // The accumulator runs for the life of a voice; it must never wander out of
    // [0,1) for the small positive steps an oscillator uses, regardless of count.
    var p: f32 = 0.0;
    const inc: f32 = 1.0 / 3.0; // not dyadic → exercises rounding accumulation
    var k: usize = 0;
    while (k < 4096) : (k += 1) {
        p = advancePhase(p, inc);
        try std.testing.expect(p >= 0.0 and p < 1.0);
    }
}

// --- applyRampedGain: the per-sample anti-zipper multiply -------------------

test "applyRampedGain: ends with the live ramp value snapped exactly to target" {
    // The block-end snap (Ramp.finish) defeats per-sample float drift so the NEXT
    // block ramps from the exact target. Must hold for ANY length, including 0.
    var r = Ramp.init(0.5);
    var xs = [_]f32{ 1, 1, 1, 1 };
    var ys: [4]f32 = undefined;
    applyRampedGain(f32, &r, 2.0, &xs, &ys);
    try std.testing.expectEqual(@as(f32, 2.0), r.value);
}

test "applyRampedGain: each output is x · (start + (i+1)·inc) in that exact order" {
    // The per-sample gain law. A Vca/Agc relies on the gain being a clean linear
    // ramp from (start+inc) up to (start+len·inc)==target, applied as x*g.
    var r = Ramp.init(0.0);
    const start = r.value;
    const target: f32 = 1.0;
    const n: usize = 4;
    const inc = (target - start) / @as(f32, @floatFromInt(n)); // == r.begin(target,n)
    var xs = [_]f32{ 2, 2, 2, 2 };
    var ys: [4]f32 = undefined;
    applyRampedGain(f32, &r, target, &xs, &ys);
    for (xs, 0..) |x, i| {
        const g = start + @as(f32, @floatFromInt(i + 1)) * inc;
        try std.testing.expectEqual(x * g, ys[i]);
    }
}

test "applyRampedGain: the FINAL sample is multiplied by exactly the target gain" {
    // Because start + len·inc == target algebraically AND the increment was formed
    // as (target-start)/len, the last gain lands on target bit-exact. This is what
    // makes a Vca reach its set point by block end with no residual.
    var r = Ramp.init(0.25);
    const target: f32 = 3.0;
    var xs = [_]f32{ 5, 5, 5, 5, 5, 5, 5, 5 };
    var ys: [8]f32 = undefined;
    applyRampedGain(f32, &r, target, &xs, &ys);
    try std.testing.expectEqual(@as(f32, 5.0) * target, ys[ys.len - 1]);
}

test "applyRampedGain: bit-identical to the inlined loop it replaced (Vca contract)" {
    // The whole reason this helper exists is de-duplication WITHOUT a numeric
    // change. Recompute the original inlined expression and demand bit-equality;
    // any reassociation in the helper would surface here.
    const start: f32 = 0.8;
    const target: f32 = 0.1; // a gain DECREASE (fade-down) exercises sign too
    var xs = [_]f32{ 0.5, -0.5, 0.25, -1.0, 0.75 };

    // Reference: replay the exact inlined arithmetic from the pre-extraction code.
    var ref_ramp = Ramp.init(start);
    var ref: [5]f32 = undefined;
    {
        const inc = ref_ramp.begin(target, xs.len);
        for (xs, 0..) |x, i| {
            const g: f32 = @floatCast(ref_ramp.value + @as(f32, @floatFromInt(i + 1)) * inc);
            ref[i] = x * g;
        }
        ref_ramp.finish(target);
    }

    var r = Ramp.init(start);
    var ys: [5]f32 = undefined;
    applyRampedGain(f32, &r, target, &xs, &ys);

    for (ref, ys) |a, b| try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(ref_ramp.value, r.value);
}

test "applyRampedGain: len 0 writes nothing yet still snaps the ramp to target" {
    // A zero-length block (legal pull demand) must not touch outputs but MUST still
    // advance the persistent ramp state to the target, matching Ramp.begin(.,0)==0
    // followed by finish — otherwise the next block would ramp from a stale value.
    var r = Ramp.init(0.3);
    const xs = [_]f32{};
    var ys = [_]f32{};
    applyRampedGain(f32, &r, 0.9, &xs, &ys);
    try std.testing.expectEqual(@as(f32, 0.9), r.value);
}

test "applyRampedGain: len 1 applies exactly the target gain (single-sample block)" {
    // For n==1, inc == target-start and the only gain is start + 1·inc == target.
    var r = Ramp.init(0.2);
    var xs = [_]f32{4.0};
    var ys: [1]f32 = undefined;
    applyRampedGain(f32, &r, 1.5, &xs, &ys);
    try std.testing.expectEqual(@as(f32, 4.0) * 1.5, ys[0]);
    try std.testing.expectEqual(@as(f32, 1.5), r.value);
}

test "applyRampedGain: a held target (start==target) is a constant unit-of-target gain" {
    // When the set point hasn't moved, every sample sees the same gain == target
    // (inc is 0), i.e. a plain scalar multiply — the steady-state Vca behaviour.
    var r = Ramp.init(2.0);
    var xs = [_]f32{ 1, -2, 3, -4 };
    var ys: [4]f32 = undefined;
    applyRampedGain(f32, &r, 2.0, &xs, &ys);
    for (xs, ys) |x, y| try std.testing.expectEqual(x * 2.0, y);
    try std.testing.expectEqual(@as(f32, 2.0), r.value);
}

test "applyRampedGain: continuity across consecutive blocks (persistent ramp)" {
    // The ramp persists across process() calls. Block 1 snaps to t1; block 2 must
    // ramp from t1 (not from the original init), so its first gain is t1+inc2.
    var r = Ramp.init(0.0);
    var xs = [_]f32{ 1, 1 };
    var ys: [2]f32 = undefined;

    applyRampedGain(f32, &r, 1.0, &xs, &ys); // ramp 0 → 1 over 2 samples
    try std.testing.expectEqual(@as(f32, 1.0), r.value);

    // Block 2 toward 0.0: inc = (0-1)/2 = -0.5; first gain = 1 + (-0.5) = 0.5.
    applyRampedGain(f32, &r, 0.0, &xs, &ys);
    try std.testing.expectEqual(@as(f32, 0.5), ys[0]); // 1 * 0.5
    try std.testing.expectEqual(@as(f32, 0.0), ys[1]); // last == target
    try std.testing.expectEqual(@as(f32, 0.0), r.value);
}

test "applyRampedGain: f64 lane path casts the f32 gain to T and multiplies in T" {
    // Vca/Agc are generic over the numeric lane; the helper casts the f32 ramp gain
    // to T via @floatCast before the multiply. Exercise the f64 instantiation so
    // the comptime-T branch is covered and the cast direction is pinned.
    var r = Ramp.init(0.0);
    var xs = [_]f64{ 1, 1, 1, 1 };
    var ys: [4]f64 = undefined;
    applyRampedGain(f64, &r, 1.0, &xs, &ys);
    // inc as f32 = 0.25; gains 0.25,0.5,0.75,1.0 each @floatCast to f64.
    const expect = [_]f64{ 0.25, 0.5, 0.75, 1.0 };
    for (expect, ys) |e, y| try std.testing.expectEqual(e, y);
    try std.testing.expectEqual(@as(f32, 1.0), r.value);
}

test "applyRampedGain: a fade to zero gain silences the tail sample exactly" {
    // PowerGate/Vca fade-out: ramping the gain to 0 must make the last output
    // exactly 0 regardless of the input there (gain·x with gain==0).
    var r = Ramp.init(1.0);
    var xs = [_]f32{ 7, 7, 7, 7 };
    var ys: [4]f32 = undefined;
    applyRampedGain(f32, &r, 0.0, &xs, &ys);
    try std.testing.expectEqual(@as(f32, 0.0), ys[ys.len - 1]);
    try std.testing.expectEqual(@as(f32, 0.0), r.value);
}
