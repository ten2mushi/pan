//! varirate_latency_test — the `VariRate` interval contract gate (`src/spectral.zig`
//! `Varispeed`, `src/io.zig` `Asrc`). A `VariRate` is a `Rate` whose out:in ratio
//! varies at runtime inside a declared bounded interval; this file is its
//! latency/demand + determinism gate:
//!
//!   1. measured out:in ratio lies in `[min, max]` across the interval (and an
//!      out-of-range request is clamped INTO the interval — it can never escape);
//!   2. an impulse's group delay is ≤ the declared `max_latency` at every operating
//!      ratio (the latency-contract, promoted from a point to a swept property);
//!   3. `needed_input(want)` is SOUND (enough input to make `want` outputs) and
//!      MONOTONE — non-decreasing in `want`, non-increasing in the ratio;
//!   4. the parameter-driven render is REPRODUCIBLE — chunked ≡ whole, bit-exact,
//!      and two identical renders are byte-identical (the deterministic class);
//!   5. the controller-driven drift-`Asrc` keeps its bridging FIFO centred over a
//!      long run with NO xrun — exercised ≈-only (it tracks a wall-clock fill level,
//!      so it is inherently NOT bit-reproducible, the honest determinism split).
//!
//! WHY these checks (Rule 9): they encode the laws that make worst-case STATIC
//! planning safe for a LIVE ratio — sizing on the `min` ratio (the most input ever
//! needed) and compensating on `max_latency` (the worst delay) — so a varispeed seam
//! can neither under-size its pull nor mis-align a fan-in, however the ratio moves.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14). Reject diagnostics use std.debug.print, never std.log.err.

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const Sample = pan.Sample;
const f32num = pan.numericFor(.f32, .{});
const VS = pan.Varispeed(f32num);
const eps: f32 = 1e-6;

// The declared interval, mirrored from the block for the assertions.
const min_ratio: f32 = 0.25;
const max_ratio: f32 = 4.0;

/// Drive a fresh `Varispeed` at `ratio` over `lin` input samples with an unbounded
/// `want`, so it emits every output the input affords: `produced/lin ≈ ratio`.
fn measuredRatio(ratio: f32, lin: usize) !f32 {
    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), lin);
    defer gpa.free(in);
    const out = try gpa.alloc(Sample(f32), lin * 5 + 8); // headroom for up to 4× + slack
    defer gpa.free(out);
    h.fillNoise(in, 7);
    var vs = VS{};
    vs.setParam(0, ratio);
    const produced = vs.pull(in, out.len, out);
    return @as(f32, @floatFromInt(produced)) / @as(f32, @floatFromInt(lin));
}

test "VariRate ratio: measured out:in tracks the request and stays inside [min,max]" {
    // In-range ratios: the measured ratio matches the request (steady-state, large L).
    for ([_]f32{ 0.25, 0.5, 0.8, 1.0, 1.5, 2.0, 3.0, 4.0 }) |r| {
        const m = try measuredRatio(r, 4000);
        try std.testing.expect(m >= min_ratio - 0.02 and m <= max_ratio + 0.02);
        // Within ~1% of the requested ratio at this length.
        try std.testing.expectApproxEqAbs(r, m, 0.03);
    }
}

test "VariRate ratio: an out-of-interval request is CLAMPED into [min,max]" {
    // 8× requested → clamped to max (4×); 1/16× requested → clamped to min (1/4×).
    const fast = try measuredRatio(8.0, 4000);
    try std.testing.expect(fast <= max_ratio + 0.05);
    try std.testing.expectApproxEqAbs(max_ratio, fast, 0.05);
    const slow = try measuredRatio(1.0 / 16.0, 4000);
    try std.testing.expect(slow >= min_ratio - 0.05);
    try std.testing.expectApproxEqAbs(min_ratio, slow, 0.05);
}

test "VariRate latency-contract: impulse group delay ≤ max_latency at every ratio ≥ 1" {
    // The latency probe sweeps the UPsampling / unity half of the interval, where a
    // unit-impulse input is faithfully represented in the output and its delay is
    // well-defined. (DOWNsampling a single-sample impulse is undersampling — the
    // impulse can fall between output samples and vanish; that is an aliasing
    // property, not a latency one, and is covered by the ratio / needed_input
    // checks. A band-limited resampler would low-pass first; this linear tier does
    // not, the honest quality boundary.)
    const N = 64;
    inline for (.{ 1.0, 1.5, 2.0, 3.0, 4.0 }) |r| {
        var in: [N]Sample(f32) = undefined;
        var out: [N]Sample(f32) = undefined;
        h.fillImpulse(&in);
        var vs = VS{};
        vs.setParam(0, r);
        _ = vs.pull(&in, N, &out);
        const delay = h.measuredGroupDelay(h.sampleValues(&out), eps) orelse
            return error.NoResponse;
        try std.testing.expect(delay <= VS.max_latency);
    }
}

test "VariRate needed_input: SOUND — exactly needed_input(want) inputs yield `want` outputs" {
    inline for (.{ 0.25, 0.5, 1.0, 2.0, 4.0 }) |r| {
        const want: usize = 200;
        var vs = VS{};
        vs.setParam(0, r);
        const ni = vs.needed_input(want);
        const gpa = std.testing.allocator;
        const in = try gpa.alloc(Sample(f32), ni);
        defer gpa.free(in);
        const out = try gpa.alloc(Sample(f32), want);
        defer gpa.free(out);
        h.fillNoise(in, 13);
        const produced = vs.pull(in, want, out);
        try std.testing.expectEqual(want, produced); // sound: never under-fed
    }
}

test "VariRate needed_input: MONOTONE in want (non-decreasing) and ratio (non-increasing)" {
    // Non-decreasing in want at a fixed ratio.
    inline for (.{ 0.5, 1.0, 2.0 }) |r| {
        var vs = VS{};
        vs.setParam(0, r);
        var prev: usize = 0;
        var want: usize = 1;
        while (want <= 1000) : (want += 37) {
            const ni = vs.needed_input(want);
            try std.testing.expect(ni >= prev);
            prev = ni;
        }
    }
    // Non-increasing in ratio at a fixed want (more output per input ⇒ less input).
    const want: usize = 512;
    var prev: usize = std.math.maxInt(usize);
    inline for (.{ 0.25, 0.5, 1.0, 2.0, 4.0 }) |r| {
        var vs = VS{};
        vs.setParam(0, r);
        const ni = vs.needed_input(want);
        try std.testing.expect(ni <= prev);
        prev = ni;
    }
}

test "VariRate determinism: chunked ≡ whole, bit-exact (sub-block = prefix, chunkable)" {
    const N = 2000;
    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    const out_whole = try gpa.alloc(Sample(f32), N * 5);
    defer gpa.free(out_whole);
    const out_chunk = try gpa.alloc(Sample(f32), N * 5);
    defer gpa.free(out_chunk);
    h.fillNoise(in, 23);

    inline for (.{ 0.5, 1.0, 1.5, 2.0 }) |r| {
        var bw = VS{};
        bw.setParam(0, r);
        const pw = bw.pull(in, out_whole.len, out_whole);

        var bc = VS{};
        bc.setParam(0, r);
        const pc = h.renderRatePush(VS, Sample(f32), Sample(f32), &bc, in, out_chunk, 64);

        try std.testing.expectEqual(pw, pc);
        // Bit-exact: a varispeed render is a pure function of input + held ratio, so
        // the buffer chunking can never change a single bit.
        try std.testing.expect(h.firstBitDivergence(
            h.sampleValues(out_whole[0..pw]),
            h.sampleValues(out_chunk[0..pc]),
        ) == null);
    }
}

test "VariRate determinism: two identical renders are byte-identical" {
    const N = 1000;
    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    const a = try gpa.alloc(Sample(f32), N * 3);
    defer gpa.free(a);
    const b = try gpa.alloc(Sample(f32), N * 3);
    defer gpa.free(b);
    h.fillNoise(in, 99);
    var va = VS{};
    va.setParam(0, 1.5);
    const pa = va.pull(in, a.len, a);
    var vb = VS{};
    vb.setParam(0, 1.5);
    const pb = vb.pull(in, b.len, b);
    try std.testing.expectEqual(pa, pb);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a[0..pa]), std.mem.sliceAsBytes(b[0..pb]));
}

// ---------------------------------------------------------------------------
// The controller-driven drift-ASRC: bridging-FIFO centring over a long run (≈).
// ---------------------------------------------------------------------------

const cap = 1024;
const Asrc = pan.Asrc(f32num, cap);
const target: usize = cap / 2; // the PI setpoint = the block's default target_fill

/// Run a clock-mismatch simulation for `rounds` rounds. The capture side pushes at
/// `in_rate` samples/round (a fractional rate, dribbled in 0/1 at a time via an
/// accumulator so there is no large burst — a realistic device clock), the playback
/// side pulls `out_per_round` outputs/round. After `warmup`, records the fill band
/// and any overflow drops. Returns `.{ min_fill, max_fill, dropped }`.
fn runDrift(in_rate: f32, out_per_round: usize, rounds: usize, warmup: usize) !struct { min: usize, max: usize, dropped: usize, xruns: usize } {
    const gpa = std.testing.allocator;
    const ring = try gpa.create(Asrc.Ring);
    defer gpa.destroy(ring);
    ring.* = Asrc.Ring.empty;
    // Pre-fill to the setpoint so the loop starts centred.
    var i: usize = 0;
    while (i < target) : (i += 1) _ = ring.push(.{ .ch = .{0.5} });
    var asrc = Asrc{ .ring = ring };

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
            if (!ring.push(.{ .ch = .{0.5} })) dropped += 1; // FIFO full → drop (overflow)
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

test "VariRate drift-Asrc: a faster capture clock keeps the FIFO centred, no xrun" {
    // Capture clock ~1.5% fast (64.96 samples/round) vs a 64-output playback block:
    // without correction the FIFO would overflow. The PI controller lowers the ratio
    // (more input consumed per output) so the fill stays in a centred band. ≈ only —
    // the ratio tracks a wall-clock fill, so this is NOT bit-reproducible by nature.
    const r = try runDrift(64.0 * 1.015, 64, 6000, 500);
    try std.testing.expectEqual(@as(usize, 0), r.xruns); // never starved
    try std.testing.expectEqual(@as(usize, 0), r.dropped); // never overflowed
    // Stays in a centred band — neither drained toward empty nor pinned at full.
    try std.testing.expect(r.min > 100 and r.max < cap - 100);
}

test "VariRate drift-Asrc: a slower capture clock also stays bounded, no xrun" {
    // Capture clock ~1.5% slow (63.04/round): the FIFO would drain without
    // correction; the controller raises the ratio to consume fewer inputs per output.
    const r = try runDrift(64.0 * 0.985, 64, 6000, 500);
    try std.testing.expectEqual(@as(usize, 0), r.xruns);
    try std.testing.expectEqual(@as(usize, 0), r.dropped);
    try std.testing.expect(r.min > 100 and r.max < cap - 100);
}
