//! dynamics_yoneda_test — the INDEPENDENT-ORACLE ("tests as definition") suite for
//! Phase-11's modulation-applier / adaptive-dynamics blocks in `src/fx.zig`:
//! `Vca`, `Agc`, `AgcController`, `PowerGate`. The Yoneda discipline: a block is
//! defined by its action under ALL observations, so each is characterised by every
//! morphism — silence, DC, edges (n=1, single block), state carry-over across calls,
//! the per-sample ramp SHAPE, the one-pole adaptation recurrence, hysteresis around
//! the open/close thresholds, classification + control-element identity, determinism,
//! and the bit-exactness of the wired-vs-set gain glide.
//!
//! Oracle strategy (Rule 9, hermetic — no SciPy, no disk): every expectation is
//! recomputed in-test by a DIRECT, INDEPENDENT reimplementation of the doc-comment
//! formula, sharing only the *definition* with pan's block, never its loop or
//! accumulation order:
//!   - RMS/power is summed in a DIFFERENT order (descending index) than fx.zig's
//!     ascending `blockPower`.
//!   - the linear glide is reproduced with a SEPARATE accumulator (`v + (i+1)*inc`,
//!     `inc = (tgt - v0)/n`), not by reading pan's ramp state.
//!   - the one-pole `g += rate*(desired - g)` recurrence is iterated independently
//!     across blocks.
//! pan and the oracle agree only if both independently compute the documented value.
//!
//! COMPARISON DISCIPLINE:
//!   - pan-vs-pan (determinism: same input twice; wired-vs-set: identical target
//!     sequence through the SAME Param/Ramp) is BIT-EXACT (`expectEqual`).
//!   - oracle checks that reproduce the SAME f32 ops in the SAME order the block uses
//!     are expected bit-exact (`expectEqual`); where summation order differs (RMS) we
//!     use a small tolerance via `expectApproxEqAbs` and SAY SO at the call site.
//!
//! Reject diagnostics use std.debug.print (never std.log.err — the 0.16 test runner
//! counts logged errors and flips the suite to non-zero exit).
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14): no @Type, no managed ArrayList, all buffers are fixed comptime
//! arrays (no allocator needed), atomics via control.Param's std.atomic.Value.

const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});

// `Sample(f32)` is `Frame(f32,.mono)` == `struct{ ch:[1]f32 }`; build/read mono.
fn S(x: f32) pan.Sample(f32) {
    return .{ .ch = .{x} };
}

// ===========================================================================
// Independent oracles (naive reimplementations; never share pan's loop order).
// ===========================================================================

/// Block mean-square, summed DESCENDING (fx.zig's `blockPower` sums ascending).
fn powerOracle(xs: []const f32) f32 {
    if (xs.len == 0) return 0;
    var acc: f32 = 0;
    var k: usize = xs.len;
    while (k > 0) {
        k -= 1;
        acc += xs[k] * xs[k];
    }
    return acc / @as(f32, @floatFromInt(xs.len));
}

fn rmsOracle(xs: []const f32) f32 {
    return @sqrt(powerOracle(xs));
}

/// Reproduce the per-sample linear glide EXACTLY as fx.zig writes it:
/// inc = (tgt - v0)/n ; y_i = x_i * (v0 + (i+1)*inc). Bit-for-bit op order.
fn glideOracle(v0: f32, tgt: f32, xs: []const f32, ys: []f32) void {
    const n = xs.len;
    const inc: f32 = if (n == 0) 0 else (tgt - v0) / @as(f32, @floatFromInt(n));
    for (xs, ys, 0..) |x, *y, i| {
        const g: f32 = v0 + @as(f32, @floatFromInt(i + 1)) * inc;
        y.* = x * g;
    }
}

// ===========================================================================
// Object identity — a block IS its class and its control element (Yoneda: the
// classifier + element type are the first morphisms we observe).
// ===========================================================================

test "dynamics: classification + control-element identity for all four blocks" {
    const V = pan.fx.Vca(Num);
    const A = pan.fx.Agc(Num);
    const C = pan.fx.AgcController(Num);
    const G = pan.fx.PowerGate(Num);

    // All four are rate-1:1 process blocks → Map.
    try std.testing.expect(pan.port.classify(V) == .Map);
    try std.testing.expect(pan.port.classify(A) == .Map);
    try std.testing.expect(pan.port.classify(C) == .Map);
    try std.testing.expect(pan.port.classify(G) == .Map);

    // Vca consumes a gain PARAMETER port carrying Scalar(f32).
    try std.testing.expect(pan.port.ParamPort(V, "gain").Elem == pan.Scalar(f32));

    // The control PRODUCERS emit Scalar(f32) on their out port; Agc/Vca apply audio.
    try std.testing.expect(pan.port.MapOutPort(C).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(G).Elem == pan.Scalar(f32));
    try std.testing.expect(pan.port.MapOutPort(A).Elem == pan.Sample(f32));
    try std.testing.expect(pan.port.MapOutPort(V).Elem == pan.Sample(f32));

    // None is a Source: AgcController & PowerGate READ audio to produce control;
    // Vca/Agc read audio. (A control SOURCE would have no audio in port.)
    try std.testing.expect(!comptime pan.port.isSource(C));
    try std.testing.expect(!comptime pan.port.isSource(G));
    try std.testing.expect(!comptime pan.port.isSource(V));
    try std.testing.expect(!comptime pan.port.isSource(A));
}

// ===========================================================================
// Vca — y = x * g, g linearly glided from the live ramp value to the target read
// once per block; ramp snaps to target at block end (persistent across blocks).
// ===========================================================================

test "Vca: default unity gain is a pass-through when target is never set" {
    var v: pan.fx.Vca(Num) = .{};
    var in: [8]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@floatFromInt(i)); // 0..7
    var out: [8]pan.Sample(f32) = undefined;
    v.process(&in, &out);
    // ramp.value=1, target=1 → inc=0 → every g==1 → identity.
    for (in, out) |x, y| try std.testing.expectEqual(x.ch[0], y.ch[0]);
    try std.testing.expectEqual(@as(f32, 1.0), v.ramp.value);
}

test "Vca: silence stays exactly silent regardless of gain target" {
    var v: pan.fx.Vca(Num) = .{};
    v.setParam(0, 5.0); // big gain
    var in: [16]pan.Sample(f32) = @splat(S(0));
    var out: [16]pan.Sample(f32) = undefined;
    v.process(&in, &out);
    for (out) |s| try std.testing.expectEqual(@as(f32, 0), s.ch[0]);
    // The ramp still advanced to the target even though audio was zero.
    try std.testing.expectEqual(@as(f32, 5.0), v.ramp.value);
}

test "Vca: per-sample glide matches the independent linear-glide oracle (bit-exact)" {
    var v: pan.fx.Vca(Num) = .{};
    v.setParam(0, 0.0); // glide 1 → 0
    var in: [4]pan.Sample(f32) = @splat(S(1));
    var out: [4]pan.Sample(f32) = undefined;
    v.process(&in, &out);

    var xs: [4]f32 = .{ 1, 1, 1, 1 };
    var oracle: [4]f32 = undefined;
    glideOracle(1.0, 0.0, &xs, &oracle); // {0.75,0.5,0.25,0.0}

    for (out, oracle) |y, o| try std.testing.expectEqual(o, y.ch[0]);
    // Snapped to the exact target (defeats the per-sample rounding accumulation).
    try std.testing.expectEqual(@as(f32, 0.0), v.ramp.value);
}

test "Vca: target is read ONCE per block — a new setParam takes effect next block" {
    var v: pan.fx.Vca(Num) = .{};
    // Block 1 glides 1 → 2 over 4 samples; the live value starts at 1.
    v.setParam(0, 2.0);
    var in: [4]pan.Sample(f32) = @splat(S(1));
    var out1: [4]pan.Sample(f32) = undefined;
    v.process(&in, &out1);
    var xs: [4]f32 = .{ 1, 1, 1, 1 };
    var oracle1: [4]f32 = undefined;
    glideOracle(1.0, 2.0, &xs, &oracle1);
    for (out1, oracle1) |y, o| try std.testing.expectEqual(o, y.ch[0]);
    try std.testing.expectEqual(@as(f32, 2.0), v.ramp.value);

    // Block 2: NEW target 0.5; live value carried over is exactly 2.0 (snapped).
    v.setParam(0, 0.5);
    var out2: [4]pan.Sample(f32) = undefined;
    v.process(&in, &out2);
    var oracle2: [4]f32 = undefined;
    glideOracle(2.0, 0.5, &xs, &oracle2);
    for (out2, oracle2) |y, o| try std.testing.expectEqual(o, y.ch[0]);
    try std.testing.expectEqual(@as(f32, 0.5), v.ramp.value);
}

test "Vca: a multi-block sweep is bit-identical to the same target sequence (wired==set)" {
    // The Phase-11 gate: a wired modulation edge and an external `set` both arrive
    // through `setParam` → the SAME Param/Ramp, so the audible glide is identical.
    // We drive ONE Vca with a target sequence; the oracle independently iterates the
    // glide with its own accumulator, carrying the snapped value across blocks.
    const targets = [_]f32{ 0.0, 1.5, 0.25, 0.25, 3.0, -1.0 };
    var v: pan.fx.Vca(Num) = .{};
    var live: f32 = 1.0; // oracle's separate carry of the snapped ramp value

    const N = 5;
    var xs: [N]f32 = undefined;
    for (&xs, 0..) |*x, i| x.* = 0.5 + @as(f32, @floatFromInt(i)) * 0.1; // varied input

    for (targets) |tgt| {
        var in: [N]pan.Sample(f32) = undefined;
        for (&in, xs) |*s, x| s.* = S(x);
        var out: [N]pan.Sample(f32) = undefined;
        v.setParam(0, tgt);
        v.process(&in, &out);

        var oracle: [N]f32 = undefined;
        glideOracle(live, tgt, &xs, &oracle);
        for (out, oracle) |y, o| try std.testing.expectEqual(o, y.ch[0]);

        live = tgt; // independent snap, mirroring ramp.finish(tgt)
        try std.testing.expectEqual(live, v.ramp.value);
    }
}

test "Vca: a single-sample block (n=1) reaches the target immediately" {
    var v: pan.fx.Vca(Num) = .{};
    v.setParam(0, 0.3);
    var in: [1]pan.Sample(f32) = .{S(1)};
    var out: [1]pan.Sample(f32) = undefined;
    v.process(&in, &out);
    // inc = (0.3 - 1)/1 ; g_0 = 1 + 1*inc = 0.3 exactly.
    try std.testing.expectEqual(@as(f32, 0.3), out[0].ch[0]);
    try std.testing.expectEqual(@as(f32, 0.3), v.ramp.value);
}

test "Vca: determinism — identical input + target gives bit-identical output" {
    var in: [12]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@sin(@as(f32, @floatFromInt(i))));
    var a: pan.fx.Vca(Num) = .{};
    var b: pan.fx.Vca(Num) = .{};
    a.setParam(0, 0.7);
    b.setParam(0, 0.7);
    var oa: [12]pan.Sample(f32) = undefined;
    var ob: [12]pan.Sample(f32) = undefined;
    a.process(&in, &oa);
    b.process(&in, &ob);
    for (oa, ob) |x, y| try std.testing.expectEqual(x.ch[0], y.ch[0]);
}

// ===========================================================================
// Agc — fused: rms → desired=min(target/max(rms,1e-9),max_gain) → one-pole
// smoothing toward desired → per-sample ramp → apply → snap to smoothed.
// ===========================================================================

/// Independent fused oracle: returns the smoothed gain after the block, fills `ys`.
fn agcOracle(target: f32, rate: f32, max_gain: f32, ramp0: f32, xs: []const f32, ys: []f32) f32 {
    const rms = rmsOracle(xs);
    const desired = @min(target / @max(rms, 1e-9), max_gain);
    const smoothed = ramp0 + rate * (desired - ramp0);
    glideOracle(ramp0, smoothed, xs, ys);
    return smoothed;
}

test "Agc: a hot block with instant adaptation pulls the gain to target/rms" {
    var agc: pan.fx.Agc(Num) = .{ .target = 0.25, .rate = 1.0, .max_gain = 8.0 };
    var in: [64]pan.Sample(f32) = @splat(S(1)); // rms 1.0
    var out: [64]pan.Sample(f32) = undefined;
    agc.process(&in, &out);
    // rate=1 → smoothed == desired == min(0.25/1, 8) = 0.25.
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), agc.ramp.value, 1e-6);

    // Oracle reproduces the whole per-sample fused path; rms summation order differs
    // (descending) so the gain match is to a small tolerance.
    var xs: [64]f32 = @splat(1.0);
    var oracle: [64]f32 = undefined;
    const sm = agcOracle(0.25, 1.0, 8.0, 1.0, &xs, &oracle);
    for (out, oracle) |y, o| try std.testing.expectApproxEqAbs(o, y.ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(sm, agc.ramp.value, 1e-6);
}

test "Agc: silence cannot blow up — desired clamps to max_gain but x=0 → out=0" {
    var agc: pan.fx.Agc(Num) = .{ .target = 0.25, .rate = 1.0, .max_gain = 8.0 };
    var sil: [32]pan.Sample(f32) = @splat(S(0));
    var out: [32]pan.Sample(f32) = undefined;
    agc.process(&sil, &out);
    for (out) |s| try std.testing.expectEqual(@as(f32, 0), s.ch[0]);
    // The gain itself rode up to max_gain (clamp engaged), proving the clamp — not a
    // silent output — is what prevents the blow-up.
    try std.testing.expectEqual(@as(f32, 8.0), agc.ramp.value);
}

test "Agc: partial rate is a one-pole — gain moves a FRACTION toward desired, carries over" {
    var agc: pan.fx.Agc(Num) = .{ .target = 0.5, .rate = 0.25, .max_gain = 8.0 };
    var live: f32 = 1.0;
    var xs: [16]f32 = @splat(0.5); // rms 0.5 → desired min(0.5/0.5,8)=1.0
    // Block 1: smoothed = 1 + 0.25*(1-1) = 1.0 (already at desired).
    var in: [16]pan.Sample(f32) = undefined;
    for (&in, xs) |*s, x| s.* = S(x);
    var out: [16]pan.Sample(f32) = undefined;
    agc.process(&in, &out);
    var oracle: [16]f32 = undefined;
    live = agcOracle(0.5, 0.25, 8.0, live, &xs, &oracle);
    for (out, oracle) |y, o| try std.testing.expectApproxEqAbs(o, y.ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(live, agc.ramp.value, 1e-6);

    // Block 2: now a LOUDER block (rms 2.0 → desired 0.25); gain eases 1 → 0.8125.
    var xs2: [16]f32 = @splat(2.0);
    var in2: [16]pan.Sample(f32) = undefined;
    for (&in2, xs2) |*s, x| s.* = S(x);
    var out2: [16]pan.Sample(f32) = undefined;
    agc.process(&in2, &out2);
    var oracle2: [16]f32 = undefined;
    const sm2 = agcOracle(0.5, 0.25, 8.0, live, &xs2, &oracle2);
    for (out2, oracle2) |y, o| try std.testing.expectApproxEqAbs(o, y.ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(sm2, agc.ramp.value, 1e-6);
    // It only moved a quarter of the way: 1 + 0.25*(0.25-1) = 0.8125.
    try std.testing.expectApproxEqAbs(@as(f32, 0.8125), agc.ramp.value, 1e-6);
}

test "Agc: a DC block reaches its desired gain in one instant step" {
    // DC at amplitude 0.5 over a 1-sample block reaches desired instantly (rate=1).
    var agc: pan.fx.Agc(Num) = .{ .target = 0.5, .rate = 1.0, .max_gain = 8.0 };
    var in: [1]pan.Sample(f32) = .{S(0.5)};
    var out: [1]pan.Sample(f32) = undefined;
    agc.process(&in, &out);
    // rms=0.5 → desired=1.0 → smoothed=1.0 ; single sample g = 1.0 → out=0.5.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0].ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), agc.ramp.value, 1e-6);
}

test "Agc: determinism across two independent instances" {
    var in: [40]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.2));
    var a: pan.fx.Agc(Num) = .{};
    var b: pan.fx.Agc(Num) = .{};
    var oa: [40]pan.Sample(f32) = undefined;
    var ob: [40]pan.Sample(f32) = undefined;
    a.process(&in, &oa);
    b.process(&in, &ob);
    for (oa, ob) |x, y| try std.testing.expectEqual(x.ch[0], y.ch[0]);
    try std.testing.expectEqual(a.ramp.value, b.ramp.value);
}

// ===========================================================================
// AgcController — decoupled: same rms/desired, gain += rate*(desired-gain),
// then broadcast the single control value to EVERY out lane (one value per call).
// ===========================================================================

/// Independent controller oracle: advance the persistent gain one one-pole step.
fn ctrlStep(target: f32, rate: f32, max_gain: f32, gain0: f32, xs: []const f32) f32 {
    const rms = rmsOracle(xs);
    const desired = @min(target / @max(rms, 1e-9), max_gain);
    return gain0 + rate * (desired - gain0);
}

test "AgcController: emits the make-up gain, broadcast identically to all lanes" {
    var c: pan.fx.AgcController(Num) = .{ .target = 0.5, .rate = 1.0 };
    var in: [16]pan.Sample(f32) = @splat(S(0.25)); // rms 0.25 → desired 2.0
    var out: [16]pan.Scalar(f32) = undefined;
    c.process(&in, &out);
    const xs = [_]f32{0.25} ** 16;
    const expected = ctrlStep(0.5, 1.0, 8.0, 1.0, &xs);
    for (out) |o| try std.testing.expectApproxEqAbs(expected, o.value, 1e-6);
    // Every lane carries the SAME value (broadcast, not per-sample) — bit-identical.
    for (out) |o| try std.testing.expectEqual(out[0].value, o.value);
    try std.testing.expectEqual(out[0].value, c.gain);
}

test "AgcController: the persistent gain converges over repeated blocks (one-pole)" {
    var c: pan.fx.AgcController(Num) = .{ .target = 0.25, .rate = 0.3, .max_gain = 8.0 };
    var gain: f32 = 1.0; // independent carry
    const xs = [_]f32{0.5} ** 8; // rms 0.5 → desired 0.5
    var in: [8]pan.Sample(f32) = @splat(S(0.5));
    var out: [8]pan.Scalar(f32) = undefined;
    var blk: usize = 0;
    while (blk < 6) : (blk += 1) {
        c.process(&in, &out);
        gain = ctrlStep(0.25, 0.3, 8.0, gain, &xs);
        for (out) |o| try std.testing.expectApproxEqAbs(gain, o.value, 1e-6);
        try std.testing.expectApproxEqAbs(gain, c.gain, 1e-6);
    }
    // After several steps the gain has eased most of the way 1 → 0.5.
    try std.testing.expect(c.gain > 0.5 and c.gain < 1.0);
}

test "AgcController: silence drives the gain toward max_gain (clamp, not infinity)" {
    var c: pan.fx.AgcController(Num) = .{ .target = 0.25, .rate = 1.0, .max_gain = 4.0 };
    var in: [8]pan.Sample(f32) = @splat(S(0)); // rms 0 → 1e-9 floor → huge, clamps
    var out: [8]pan.Scalar(f32) = undefined;
    c.process(&in, &out);
    // desired = min(0.25/1e-9, 4) = 4 ; rate=1 → gain = 4 exactly.
    try std.testing.expectEqual(@as(f32, 4.0), c.gain);
    for (out) |o| try std.testing.expectEqual(@as(f32, 4.0), o.value);
}

test "AgcController: a single-lane out buffer still gets the broadcast value" {
    var c: pan.fx.AgcController(Num) = .{ .target = 0.5, .rate = 1.0 };
    var in: [4]pan.Sample(f32) = @splat(S(0.5)); // rms .5 → desired 1.0
    var out: [1]pan.Scalar(f32) = undefined; // fewer out lanes than in frames
    c.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0].value, 1e-6);
    try std.testing.expectEqual(c.gain, out[0].value);
}

// ===========================================================================
// PowerGate — data-gating with hysteresis: power=mean(x^2); open when
// power>open_threshold, close when power<close_threshold; emit {0,1} broadcast.
// ===========================================================================

test "PowerGate: defaults — opens above 1e-3, holds between, closes below 1e-4" {
    var g: pan.fx.PowerGate(Num) = .{}; // open=1e-3, close=1e-4, start closed
    var out: [4]pan.Scalar(f32) = undefined;

    // Start closed; a small block (power 4e-4, below open) stays shut.
    var below: [4]pan.Sample(f32) = @splat(S(0.02)); // power 4e-4 < 1e-3, > 1e-4
    g.process(&below, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value); // not enough to OPEN

    // A loud block (power 0.01 > 1e-3) opens.
    var loud: [4]pan.Sample(f32) = @splat(S(0.1)); // power 0.01
    g.process(&loud, &out);
    try std.testing.expectEqual(@as(f32, 1), out[0].value);

    // The SAME 4e-4 block now HOLDS open (between close 1e-4 and open 1e-3): the
    // defining property of hysteresis — the threshold depends on current state.
    g.process(&below, &out);
    try std.testing.expectEqual(@as(f32, 1), out[0].value);

    // Drop below close (power 2.5e-5 < 1e-4) → closes.
    var faint: [4]pan.Sample(f32) = @splat(S(0.005)); // power 2.5e-5
    g.process(&faint, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "PowerGate: silence holds the gate closed and the value is broadcast" {
    var g: pan.fx.PowerGate(Num) = .{};
    var sil: [8]pan.Sample(f32) = @splat(S(0));
    var out: [8]pan.Scalar(f32) = undefined;
    g.process(&sil, &out);
    for (out) |o| try std.testing.expectEqual(@as(f32, 0), o.value);
    try std.testing.expect(!g.open);
}

test "PowerGate: hysteresis prevents chatter at a single steady mid level" {
    // A level whose power sits BETWEEN close and open: from closed it never opens;
    // from open it never closes. Same input, opposite outputs — that IS hysteresis.
    var mid: [8]pan.Sample(f32) = @splat(S(0.02)); // power 4e-4 ∈ (1e-4, 1e-3)
    var out: [8]pan.Scalar(f32) = undefined;

    var closed: pan.fx.PowerGate(Num) = .{ .open = false };
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        closed.process(&mid, &out);
        try std.testing.expectEqual(@as(f32, 0), out[0].value); // stays shut
    }

    var open: pan.fx.PowerGate(Num) = .{ .open = true };
    k = 0;
    while (k < 5) : (k += 1) {
        open.process(&mid, &out);
        try std.testing.expectEqual(@as(f32, 1), out[0].value); // stays open
    }
}

test "PowerGate: emits ONLY {0,1} (never a partial), broadcast across the buffer" {
    var g: pan.fx.PowerGate(Num) = .{ .open_threshold = 0.05, .close_threshold = 0.005 };
    var out: [16]pan.Scalar(f32) = undefined;
    // Sweep a few levels; assert each emission is exactly 0 or 1 and uniform.
    const levels = [_]f32{ 0.0, 0.01, 0.3, 0.06, 0.0 };
    for (levels) |lvl| {
        var in: [16]pan.Sample(f32) = @splat(S(lvl));
        g.process(&in, &out);
        const v = out[0].value;
        try std.testing.expect(v == 0.0 or v == 1.0);
        for (out) |o| try std.testing.expectEqual(v, o.value);
    }
}

test "PowerGate: a power exactly AT open_threshold does NOT open (strict >)" {
    // The boundary morphism: open requires power STRICTLY greater than open_threshold.
    // A DC block at `lvl` has mean-square exactly `lvl*lvl` in f32.
    const lvl: f32 = 0.1;
    const thr: f32 = lvl * lvl; // power of a DC block at lvl == lvl^2 exactly
    var g: pan.fx.PowerGate(Num) = .{ .open_threshold = thr, .close_threshold = thr / 10.0 };
    var in: [8]pan.Sample(f32) = @splat(S(lvl));
    var out: [8]pan.Scalar(f32) = undefined;
    g.process(&in, &out);
    // power == open_threshold, and the test is `power > open_threshold` → stays shut.
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
    try std.testing.expect(!g.open);
}

test "PowerGate: power is mean-square — independent oracle agrees on the open decision" {
    // Drive a non-uniform block so the mean-square is non-trivial; the gate decision
    // must match the independent power oracle compared to the thresholds.
    var g: pan.fx.PowerGate(Num) = .{ .open_threshold = 0.1, .close_threshold = 0.01 };
    var xs: [8]f32 = .{ 0.5, -0.5, 0.5, -0.5, 0.5, -0.5, 0.5, -0.5 }; // power 0.25
    var in: [8]pan.Sample(f32) = undefined;
    for (&in, xs) |*s, x| s.* = S(x);
    var out: [8]pan.Scalar(f32) = undefined;
    g.process(&in, &out);
    const p = powerOracle(&xs); // 0.25 > 0.1 → should OPEN
    try std.testing.expect(p > g.open_threshold);
    try std.testing.expectEqual(@as(f32, 1), out[0].value);
}
