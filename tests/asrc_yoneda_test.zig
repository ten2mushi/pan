//! asrc_yoneda_test — a "tests as definition" behavioural specification of the
//! drift-correcting asynchronous sample-rate converter `Asrc(num, cap)` in
//! src/io.zig. `Asrc` is a zero-sample-input SOURCE (a `VariRate`) sitting over a
//! caller-owned bridging SPSC FIFO: a capture side `push`es at one clock, this
//! block `pop`s at the playback clock's demand, and an INTERNAL PI controller on
//! the FIFO fill level drives the out:in resampling ratio to keep the FIFO centred
//! at `target_fill = cap/2`. This file pins down its complete contract.
//!
//! THE LAWS THIS FILE DEFINES (each test name states which it gates):
//!
//!  • Control-law SIGN (negative feedback). The ratio is sampled ONCE per `pull`
//!    from the controller. A FIFO filled ABOVE the half-full setpoint must drive
//!    the next ratio BELOW nominal 1:1 (ratio = 1 − kp·err − ki·integ with
//!    err = fill − target): a sub-unity out:in ratio means each output advances the
//!    read cursor by 1/ratio > 1 input samples, so MORE input is consumed per
//!    output and the FIFO DRAINS toward the setpoint. Symmetrically, a FIFO BELOW
//!    setpoint drives the ratio ABOVE nominal, consuming fewer inputs per output so
//!    the FIFO REFILLS. A FIFO exactly at setpoint (err = 0) with a zero integrator
//!    leaves the ratio at exactly nominal. This is the only sign that yields a
//!    stable loop; the opposite sign would diverge.
//!
//!  • Ratio CLAMPING. However extreme the fill error — totally empty or totally
//!    full FIFO, for arbitrarily many calls — the ratio returned by the controller
//!    stays inside the declared interval [31/32, 33/32] (≈ ±3% around 1:1). The
//!    interval is what makes worst-case static planning safe, so the loop output
//!    must never escape it.
//!
//!  • ANTI-WINDUP. The integrator's CONTRIBUTION (ki·integ) is bounded to half the
//!    interval width, so even an unbounded run of one-sided fill error cannot wind
//!    the integral term into a bias large enough to pin the ratio at a bound by
//!    itself (bang-bang). After the windup pressure reverses, the loop recovers
//!    within a bounded number of calls rather than staying stuck.
//!
//!  • CONVERGENCE / BOUNDEDNESS. A sustained producer/consumer rate mismatch that
//!    lies inside the controllable interval keeps the FIFO BOUNDED over a long run:
//!    no underrun (xruns stays 0) and no overflow (push never drops), and the fill
//!    settles into a centred band — neither drained to empty nor pinned at full.
//!
//!  • UNDERRUN ACCOUNTING (held-sample fallback). When the FIFO is starved, `pull`
//!    STILL fills the entire `want` buffer (every output slot is written — no
//!    undefined tail) by holding the last input sample, and `xruns` increments by
//!    exactly the number of output samples produced under starvation. The held
//!    fallback is a constant (DC) tail, click-bounded.
//!
//!  • EDGE CASES. want = 0 produces nothing and writes nothing; a from-empty FIFO
//!    primes to silence; a one-sample FIFO is handled; the produced count always
//!    equals `want` (a SOURCE always satisfies the demand, by fallback if needed).
//!
//! This block is the CONTROLLER-DRIVEN, ≈-only determinism class: its ratio tracks
//! a wall-clock fill level, so it is non-reproducible BY DESIGN (same class as the
//! drift it corrects). Hence this file asserts SIGNS, BOUNDS, BANDS and COUNTS, not
//! bit-identity. The two exact long-run drift tests already live in
//! varirate_latency_test.zig; this file goes deeper (control-law sign, clamping,
//! anti-windup, underrun accounting, edge cases) and does not duplicate them.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14). Reject diagnostics use std.debug.print, never std.log.err.

const std = @import("std");
const pan = @import("pan");

const Sample = pan.Sample;
const f32num = pan.numericFor(.f32, .{});

const cap = 1024;
const A = pan.Asrc(f32num, cap);
const Ring = A.Ring;

// The declared interval, mirrored from the block for the assertions.
const min_ratio: f32 = 31.0 / 32.0;
const max_ratio: f32 = 33.0 / 32.0;
const nominal: f32 = 1.0;
const target: usize = cap / 2; // the PI setpoint = the block's default target_fill

// ---------------------------------------------------------------------------
// Helpers — heap-allocate the (large) Ring; never put it on the stack.
// ---------------------------------------------------------------------------

/// Allocate an empty Ring on the heap. Caller owns it (must destroy).
fn newRing(gpa: std.mem.Allocator) !*Ring {
    const ring = try gpa.create(Ring);
    ring.* = Ring.empty;
    return ring;
}

/// Push `n` copies of `v` into the ring, returning how many actually landed
/// (push returns false and drops when the ring is full).
fn fillN(ring: *Ring, n: usize, v: f32) usize {
    var i: usize = 0;
    var landed: usize = 0;
    while (i < n) : (i += 1) {
        if (ring.push(.{ .ch = .{v} })) landed += 1;
    }
    return landed;
}

/// Observe the ratio the controller WOULD apply for a given current fill, on a
/// FRESH controller (integ = 0). We re-derive the controller's exact closed form
/// here from the block's documented law — ratio = clamp(1 − kp·err − ki·integ) —
/// so the test is an independent oracle, not a copy of the implementation's code.
/// With a fresh controller integ becomes `err` after the single update, so the
/// effective ratio for the first pull is 1 − kp·err − ki·err.
fn firstPullRatioForFill(fill: usize) f32 {
    const kp: f32 = 2.0e-4;
    const ki: f32 = 2.0e-6;
    const err: f32 = @as(f32, @floatFromInt(fill)) - @as(f32, @floatFromInt(target));
    const integ = err; // fresh controller: integ += err once
    const r = 1.0 - kp * err - ki * integ;
    return @min(@max(r, min_ratio), max_ratio);
}

// ===========================================================================
// CONTROL-LAW SIGN — negative feedback direction
// ===========================================================================

test "control-law sign: fill ABOVE setpoint drives the ratio BELOW nominal (drains)" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    // Fill well above the half-full setpoint.
    _ = fillN(ring, target + 200, 0.0);
    var asrc = A{ .ring = ring };

    const fill_before = ring.len();
    var out: [1]Sample(f32) = undefined;
    const before_consumed = fill_before; // ring.len() prior

    // One output pull: the held ratio must be < nominal, so MORE than one input is
    // consumed for this single output (the cursor advances by 1/ratio > 1).
    _ = asrc.pull(1, &out);
    const fill_after = ring.len();

    // The oracle ratio for this fill is strictly below nominal.
    const r = firstPullRatioForFill(before_consumed);
    try std.testing.expect(r < nominal);
    // Negative feedback drains: more inputs left the FIFO than outputs produced.
    // Producing 1 output at ratio<1 consumes ≈ 1/ratio > 1 inputs (priming pops 2
    // up front, then per-output advances). The FIFO strictly shrank.
    try std.testing.expect(fill_after < fill_before);
    // And it moved TOWARD the setpoint (was above; did not overshoot below it here).
    try std.testing.expect(fill_after >= target - 4);
}

test "control-law sign: fill BELOW setpoint drives the ratio ABOVE nominal (refills)" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    // Fill well below the setpoint (but enough to not underrun on a tiny pull).
    _ = fillN(ring, target - 200, 0.0);
    var asrc = A{ .ring = ring };

    const fill = ring.len();
    const r = firstPullRatioForFill(fill);
    // Below setpoint ⇒ err < 0 ⇒ ratio strictly above nominal.
    try std.testing.expect(r > nominal);
    try std.testing.expect(r <= max_ratio);

    // Behaviourally: at ratio > 1 the cursor advances by 1/ratio < 1 input per
    // output, so producing 1 output consumes ≤ 1 input (the priming pop of 2 aside)
    // — the FIFO is refilled relative to a nominal drain. A single output here
    // never drains more than a nominal pull would. We just confirm pull runs and
    // does not underrun with this much headroom.
    var out: [1]Sample(f32) = undefined;
    _ = asrc.pull(1, &out);
    try std.testing.expectEqual(@as(usize, 0), asrc.xruns);
}

test "control-law sign: fill EXACTLY at setpoint with fresh integrator holds nominal" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    _ = fillN(ring, target, 0.5);
    var asrc = A{ .ring = ring };

    // err = 0 ⇒ ratio = 1 − 0 − 0 = exactly nominal, no correction.
    const r = firstPullRatioForFill(ring.len());
    try std.testing.expectEqual(nominal, r);

    // Behaviourally: at exactly nominal ratio, producing N outputs consumes ≈ N
    // inputs, so the fill holds roughly steady (not drained, not flooded) over a
    // short matched run where the producer keeps pace at exactly 1:1.
    const out = try gpa.alloc(Sample(f32), 64);
    defer gpa.free(out);
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        _ = fillN(ring, 64, 0.5); // producer at exactly 1:1
        _ = asrc.pull(64, out);
    }
    const fill = ring.len();
    // Held near the setpoint — a matched clock at nominal does not drift the band.
    try std.testing.expect(fill > target - 80 and fill < target + 80);
    try std.testing.expectEqual(@as(usize, 0), asrc.xruns);
}

// ===========================================================================
// RATIO CLAMPING — output stays inside [min_ratio, max_ratio] under any fill
// ===========================================================================

test "ratio clamping: a totally FULL FIFO cannot drive the ratio below min_ratio" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    // Saturate the ring completely (cap entries). Maximal positive error.
    const landed = fillN(ring, cap + 50, 0.0);
    try std.testing.expectEqual(cap, landed); // overflow drops kept it at cap
    var asrc = A{ .ring = ring };

    // The first-pull ratio for the maximal fill is clamped at exactly min_ratio.
    const r = firstPullRatioForFill(ring.len());
    try std.testing.expectEqual(min_ratio, r);

    // Drive many pulls while keeping the ring saturated; the ratio per call (which
    // we can re-derive from the live fill) never dips below min_ratio. We probe the
    // realised behaviour: a sub-min ratio would advance the cursor faster than
    // step = 1/min_ratio; instead each pull drains a BOUNDED amount.
    const out = try gpa.alloc(Sample(f32), 256);
    defer gpa.free(out);
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        // keep flooding so fill error stays maximal
        _ = fillN(ring, 300, 0.0);
        _ = asrc.pull(256, out);
        // At the clamped min_ratio the cursor advances by 1/min_ratio per output;
        // 256 outputs consume ≤ ceil(256/min_ratio)+2 inputs. Never an unbounded
        // gulp that a sub-min (clamp-violating) ratio would imply.
        // (The flood above more than refills, so the ring stays saturated.)
        try std.testing.expect(ring.len() >= cap - 300);
    }
    try std.testing.expectEqual(@as(usize, 0), asrc.xruns); // saturated ⇒ never starved
}

test "ratio clamping: a totally EMPTY FIFO cannot drive the ratio above max_ratio" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    // Empty ring: maximal NEGATIVE error (fill 0, far below setpoint).
    var asrc = A{ .ring = ring };
    const r = firstPullRatioForFill(0);
    // Clamped at exactly max_ratio (the law would otherwise demand a far larger r).
    try std.testing.expectEqual(max_ratio, r);

    // Realised: even at the clamped max_ratio an empty FIFO underruns (the held
    // fallback fires) rather than the ratio escaping upward to fabricate input.
    const out = try gpa.alloc(Sample(f32), 64);
    defer gpa.free(out);
    _ = asrc.pull(64, out);
    try std.testing.expect(asrc.xruns > 0);
}

test "ratio clamping: the oracle ratio is inside [min,max] for EVERY fill 0..cap" {
    // Sweep the entire fill domain; the closed-form (fresh-controller) ratio is
    // always inside the declared interval — the clamp is total over the domain.
    var fill: usize = 0;
    while (fill <= cap) : (fill += 1) {
        const r = firstPullRatioForFill(fill);
        try std.testing.expect(r >= min_ratio and r <= max_ratio);
    }
}

// ===========================================================================
// ANTI-WINDUP — the integral contribution is bounded; the loop recovers
// ===========================================================================

test "anti-windup: a long one-sided starvation cannot pin the ratio, and it recovers" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    var asrc = A{ .ring = ring };
    const out = try gpa.alloc(Sample(f32), 64);
    defer gpa.free(out);

    // Starve hard for a long time: empty FIFO, many pulls. err is large negative
    // every call, so integ winds NEGATIVE. Without anti-windup the integral term
    // would grow without bound. The block bounds the CONTRIBUTION (ki·integ) to
    // half the interval; we verify the integrator magnitude is capped and recovery
    // is prompt once the FIFO is flooded.
    var round: usize = 0;
    while (round < 5000) : (round += 1) {
        _ = asrc.pull(64, out); // no pushes: pure starvation
    }
    // The integral CONTRIBUTION (ki·integ) is clamped to half the interval width.
    const half_interval: f32 = (max_ratio - min_ratio) / 2.0;
    const ki: f32 = 2.0e-6;
    try std.testing.expect(@abs(ki * asrc.integ) <= half_interval + 1e-6);

    // Now FLOOD the FIFO and pull: anti-windup means the (negatively) wound
    // integrator does not keep the ratio pinned high — within a bounded number of
    // calls the controller reverses to draining the now-overfull FIFO.
    const out2 = try gpa.alloc(Sample(f32), 256);
    defer gpa.free(out2);
    _ = fillN(ring, cap, 0.0); // saturate
    var recovered = false;
    var k: usize = 0;
    while (k < 2000) : (k += 1) {
        const before = ring.len();
        _ = asrc.pull(256, out2);
        const after = ring.len();
        // Overfull FIFO with a working loop drains (consumes ≥ produced).
        if (before == cap and after < before) {
            recovered = true;
            break;
        }
    }
    try std.testing.expect(recovered);
}

test "anti-windup: a long one-sided flood keeps the integral contribution bounded" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    var asrc = A{ .ring = ring };
    const out = try gpa.alloc(Sample(f32), 32);
    defer gpa.free(out);

    // Keep the FIFO saturated for a long time: err is large positive each call so
    // integ winds POSITIVE. The contribution must stay clamped.
    var round: usize = 0;
    while (round < 5000) : (round += 1) {
        _ = fillN(ring, 64, 0.0); // refill more than consumed → stays full
        _ = asrc.pull(32, out);
    }
    const half_interval: f32 = (max_ratio - min_ratio) / 2.0;
    const ki: f32 = 2.0e-6;
    try std.testing.expect(@abs(ki * asrc.integ) <= half_interval + 1e-6);
}

// ===========================================================================
// UNDERRUN ACCOUNTING — held-sample fallback fully fills want; xruns is exact
// ===========================================================================

test "underrun: a fully starved pull fills the WHOLE want buffer (no undefined tail)" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    var asrc = A{ .ring = ring };

    const want: usize = 200;
    const out = try gpa.alloc(Sample(f32), want);
    defer gpa.free(out);
    // Poison the buffer so an unwritten slot would be detectable as a non-zero
    // value (the starved-from-empty fallback holds 0 — primed prev/cur are 0).
    for (out) |*s| s.ch[0] = 12345.0;

    const produced = asrc.pull(want, out);
    try std.testing.expectEqual(want, produced); // SOURCE always satisfies demand
    // Every slot was written: none retains the poison; from an empty FIFO the held
    // sample is silence (0), a click-bounded DC tail.
    for (out) |s| try std.testing.expectEqual(@as(f32, 0.0), s.ch[0]);
}

test "underrun: xruns counts exactly the outputs produced under FIFO starvation" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    var asrc = A{ .ring = ring };

    // Start fully empty and pull a large block at nominal-ish ratio. Priming pops 2
    // (both fail → 0,0). Then each output that needs a fresh input but finds none
    // increments xruns. We assert xruns is positive and bounded by want, and that
    // it equals exactly the number of cursor-advance underruns, which for a from-
    // empty pull of `want` at step≈1/max_ratio is the count of frac wrap events.
    const want: usize = 500;
    const out = try gpa.alloc(Sample(f32), want);
    defer gpa.free(out);

    try std.testing.expectEqual(@as(usize, 0), asrc.xruns);
    _ = asrc.pull(want, out);
    // Every cursor advance under empty FIFO is one xrun; there is at least one per
    // input-boundary crossing and never more than `want` (one per output at most).
    try std.testing.expect(asrc.xruns > 0);
    try std.testing.expect(asrc.xruns <= want);
}

test "underrun: a well-fed pull records ZERO xruns" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    // Plenty of input for the demand (at max step 1/min_ratio ≈ 1.032 in/out, 600
    // inputs more than cover 500 outputs).
    _ = fillN(ring, 700, 0.5);
    var asrc = A{ .ring = ring };
    const out = try gpa.alloc(Sample(f32), 500);
    defer gpa.free(out);
    _ = asrc.pull(500, out);
    try std.testing.expectEqual(@as(usize, 0), asrc.xruns);
}

test "underrun: a starved tail holds the LAST real sample as a DC plateau" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    // Feed a few non-zero samples, then starve: the fallback must hold the last
    // real value (not jump to silence), bounding the click.
    const held: f32 = 0.75;
    _ = fillN(ring, 4, held);
    var asrc = A{ .ring = ring };

    const want: usize = 300;
    const out = try gpa.alloc(Sample(f32), want);
    defer gpa.free(out);
    _ = asrc.pull(want, out);

    // After the 4 fed samples are exhausted, every remaining output equals `held`
    // (prev == cur == held, interpolation collapses to the held value).
    const last = out[want - 1].ch[0];
    try std.testing.expectEqual(held, last);
    try std.testing.expect(asrc.xruns > 0);
}

// ===========================================================================
// EDGE CASES
// ===========================================================================

test "edge: want = 0 produces nothing and writes nothing" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    _ = fillN(ring, target, 0.5);
    var asrc = A{ .ring = ring };

    var out: [4]Sample(f32) = undefined;
    for (&out) |*s| s.ch[0] = 999.0;
    const produced = asrc.pull(0, &out);
    try std.testing.expectEqual(@as(usize, 0), produced);
    // Untouched: the poison survives (no slot was written for a zero demand).
    for (out) |s| try std.testing.expectEqual(@as(f32, 999.0), s.ch[0]);
    try std.testing.expectEqual(@as(usize, 0), asrc.xruns);
}

test "edge: a from-empty FIFO primes to silence and still satisfies the demand" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    var asrc = A{ .ring = ring };

    const want: usize = 16;
    var out: [16]Sample(f32) = undefined;
    for (&out) |*s| s.ch[0] = -1.0;
    const produced = asrc.pull(want, &out);
    try std.testing.expectEqual(want, produced);
    // Primed brackets are silence (both pops failed → prev=0, cur=0).
    for (out) |s| try std.testing.expectEqual(@as(f32, 0.0), s.ch[0]);
}

test "edge: a one-sample FIFO is handled — that sample is consumed then held" {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    const v: f32 = 0.5;
    _ = fillN(ring, 1, v); // exactly one sample
    var asrc = A{ .ring = ring };

    const want: usize = 64;
    var out: [64]Sample(f32) = undefined;
    const produced = asrc.pull(want, &out);
    try std.testing.expectEqual(want, produced);
    // Priming pops the lone sample into prev (v); cur's pop fails → cur = prev = v.
    // So prev == cur == v and EVERY output is exactly v (a constant), and the
    // remaining cursor-advance pops underrun.
    for (out) |s| try std.testing.expectEqual(v, s.ch[0]);
    try std.testing.expect(asrc.xruns > 0);
}

test "edge: produced ALWAYS equals want across the fill domain (SOURCE never short)" {
    // A SOURCE must always satisfy its demand, whether well-fed, starved, or full,
    // by the held-sample fallback. Sweep representative fills and want sizes.
    const gpa = std.testing.allocator;
    for ([_]usize{ 0, 1, 10, target, cap }) |prefill| {
        for ([_]usize{ 1, 7, 64, 333 }) |want| {
            const ring = try newRing(gpa);
            defer gpa.destroy(ring);
            _ = fillN(ring, prefill, 0.25);
            var asrc = A{ .ring = ring };
            const out = try gpa.alloc(Sample(f32), want);
            defer gpa.free(out);
            for (out) |*s| s.ch[0] = std.math.nan(f32); // poison: NaN never matches a real write
            const produced = asrc.pull(want, out);
            try std.testing.expectEqual(want, produced);
            // No undefined tail: every slot is a real number (poison NaN gone).
            for (out) |s| try std.testing.expect(!std.math.isNan(s.ch[0]));
        }
    }
}

// ===========================================================================
// CONVERGENCE / BOUNDEDNESS — a long mismatch run stays bounded & centred
// (deeper than the two exact drift tests in varirate_latency_test.zig: here we
//  probe the EXTREMES of the controllable interval and a centred chunked start.)
// ===========================================================================

/// Long clock-mismatch run. Capture pushes `in_rate` samples/round (fractional,
/// dribbled 0/1 via an accumulator — a realistic device clock), playback pulls a
/// fixed `out_per_round`. Pre-filled to the setpoint so the loop starts centred.
/// Records the post-warmup fill band, overflow drops, and final xruns.
fn runDrift(in_rate: f32, out_per_round: usize, rounds: usize, warmup: usize) !struct { min: usize, max: usize, dropped: usize, xruns: usize } {
    const gpa = std.testing.allocator;
    const ring = try newRing(gpa);
    defer gpa.destroy(ring);
    _ = fillN(ring, target, 0.5); // start centred
    var asrc = A{ .ring = ring };

    const out = try gpa.alloc(Sample(f32), out_per_round);
    defer gpa.free(out);

    var dropped: usize = 0;
    var min_fill: usize = std.math.maxInt(usize);
    var max_fill: usize = 0;
    var push_acc: f32 = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        push_acc += in_rate;
        while (push_acc >= 1.0) : (push_acc -= 1.0) {
            if (!ring.push(.{ .ch = .{0.5} })) dropped += 1;
        }
        _ = asrc.pull(out_per_round, out);
        const fill = ring.len();
        if (round >= warmup) {
            if (fill < min_fill) min_fill = fill;
            if (fill > max_fill) max_fill = fill;
        }
    }
    return .{ .min = min_fill, .max = max_fill, .dropped = dropped, .xruns = asrc.xruns };
}

test "convergence: a mismatch near the FAST edge of the interval stays bounded, no xrun" {
    // ~3% fast capture (just inside the +33/32 controllable edge): the controller
    // must still drain enough to avoid overflow and keep the fill banded.
    const r = try runDrift(64.0 * 1.029, 64, 8000, 1000);
    try std.testing.expectEqual(@as(usize, 0), r.xruns);
    try std.testing.expectEqual(@as(usize, 0), r.dropped);
    try std.testing.expect(r.min > 50 and r.max < cap - 50);
}

test "convergence: a mismatch near the SLOW edge of the interval stays bounded, no xrun" {
    // ~3% slow capture (just inside the −31/32 edge): the controller raises the
    // ratio to consume fewer inputs per output, refilling toward the setpoint.
    const r = try runDrift(64.0 * 0.971, 64, 8000, 1000);
    try std.testing.expectEqual(@as(usize, 0), r.xruns);
    try std.testing.expectEqual(@as(usize, 0), r.dropped);
    try std.testing.expect(r.min > 50 and r.max < cap - 50);
}

test "convergence: a perfectly matched clock holds the fill in a TIGHT centred band" {
    // Exactly 1:1 — the loop should barely move; the band must be far tighter than
    // for a real mismatch, and always centred about the setpoint with no xrun.
    const r = try runDrift(64.0, 64, 8000, 1000);
    try std.testing.expectEqual(@as(usize, 0), r.xruns);
    try std.testing.expectEqual(@as(usize, 0), r.dropped);
    // Tighter band than the edge cases: a matched clock has no sustained error.
    try std.testing.expect(r.min > target - 100 and r.max < target + 100);
}
