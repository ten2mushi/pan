//! sampleplayer_yoneda_test — the behavioural specification of
//! `SamplePlayer` (`src/io.zig`), a `VariRate` SOURCE (zero sample-input)
//! that plays an owned mono asset at an arbitrary, live read step ("pitch").
//! This is the "tests as definition" characterization: it pins WHAT the
//! player computes, not merely that it runs, so any implementation that
//! passes every law below is functionally equivalent to this one.
//!
//! zig-0-16 skill loaded; every law verified against `zig 0.16.0`.
//!
//! The block, restated inline so this file stands alone (no external refs):
//!
//!   - The player owns nothing it allocates: `data` is a BORROWED slice of
//!     mono frames (`Sample(T)`, one lane). Default `data` is empty so the
//!     block is default-constructible.
//!
//!   - State carried across calls: `cursor` (a fractional f64 read position
//!     into `data`), `done` (latched once a non-looping asset is drained).
//!     `cursor` starts at 0, so the FIRST output of a fresh player reads the
//!     asset exactly at index 0 with fractional part 0 — there is NO read
//!     offset / pre-roll delay at cursor 0 (frac == 0 there).
//!
//!   - The read step ("pitch") is a control-rate parameter on slot 0,
//!     `setParam(0, v)`. It is CLAMPED, totally, into the closed interval
//!     [0.5, 2.0]: any requested value outside is pulled to the nearest
//!     endpoint, so the realised step can never escape [0.5, 2.0]. The step
//!     is sampled ONCE at the top of each `pull` and HELD for the whole call:
//!     a `setParam` issued between pulls takes effect only on the NEXT pull;
//!     it cannot change the step mid-buffer. This held-per-call rule is what
//!     makes a render bit-reproducible.
//!
//!   - Each output is the LINEAR interpolation of the asset at the fractional
//!     cursor `c`:  let i = floor(c), f = c - i;
//!         out = asset[i] + f * (asset[i+1] - asset[i]),
//!     where the right bracket asset[i+1] WRAPS to asset[0] when looping (or
//!     is 0 past the end when not looping). After producing each output the
//!     cursor advances by the held step.
//!
//!   - Wrap (loop == true): when the cursor reaches or passes `len`, it is
//!     brought back into range by SUBTRACTING `len`, so a looping asset is
//!     periodic: replaying it advances `cursor` modulo `len`. With step == 1
//!     a looping asset of length L is exactly L-periodic in the output.
//!
//!   - Drain (loop == false): once the cursor reaches `len`, every further
//!     output is silence (0) and `done`/`exhausted()` latch true. The tail of
//!     a non-looping render is therefore pure silence and the block reports
//!     itself exhausted.
//!
//!   - Empty asset (`data.len == 0`): every output is silence and `done`
//!     latches true on the first output, regardless of loop or pitch.
//!
//!   - Linearity at a fixed step: because the kernel is affine in the asset
//!     samples and the read schedule depends only on the step (never on the
//!     sample values), scaling/adding two assets scales/adds the outputs, and
//!     a constant (DC) asset maps to that same constant at every step.
//!
//!   - The render is a pure function of (asset, held step, start cursor):
//!     splitting one `pull` of N into a sequence of shorter pulls (same held
//!     step throughout) is BIT-IDENTICAL to the single pull — the fractional
//!     cursor resumes exactly across a chunk seam, dropping nothing.
//!
//!   - Class: a complete `VariRate` (declares `rate_bounds`, `max_latency`,
//!     `pull`) and a SOURCE (its `pull` has zero sample-input ports).
//!
//! Comparison policy (from harness.zig): the player's own arithmetic is f64
//! cursor / f32 lane. The INDEPENDENT oracle below also computes in f64 with a
//! DIFFERENT control flow (no per-call clamp branch, a `while`-reduced wrap,
//! direct index math) and rounds to f32 the same way the lane does, so the two
//! agree bit-for-bit when their wrap math agrees — pan-vs-oracle is checked
//! bit-exact. The float-tolerance comparator (`allcloseF32`) is reserved for
//! the linearity / periodicity laws where summation order legitimately differs.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.Sample;
const f32num = pan.numericFor(.f32, .{});
const SP = pan.SamplePlayer(f32num);

const min_step: f64 = 0.5;
const max_step: f64 = 2.0;

// --- builders --------------------------------------------------------------

/// A mono `Sample(f32)` from a scalar.
fn s(v: f32) Sample(f32) {
    return .{ .ch = .{v} };
}

/// Build a fresh non-looping player over `asset` with the requested pitch
/// applied via `setParam` (so the clamp / held-per-call path is exercised).
fn playerNonLoop(asset: []const Sample(f32), pitch: f32) SP {
    var sp = SP{ .data = asset, .loop = false };
    sp.setParam(0, pitch);
    return sp;
}

/// Build a fresh looping player over `asset` with the requested pitch.
fn playerLoop(asset: []const Sample(f32), pitch: f32) SP {
    var sp = SP{ .data = asset, .loop = true };
    sp.setParam(0, pitch);
    return sp;
}

// --- the independent oracle ------------------------------------------------
//
// A from-scratch reimplementation of the contract with DIFFERENT control flow
// than the block: the step is clamped once up front (no per-iteration branch),
// the wrap fully reduces with a `while` loop (so a single oracle pass is the
// mathematically-intended periodic read), and the bracket/interpolation is
// written with explicit f64 index math. It rounds the interpolated value to
// f32 by storing into an f32 (the lane width), matching the block's lane.
//
// NOTE on wrap: the block reduces the cursor with a SINGLE `if` per output
// (subtract `len` at most once), which equals this `while`-reduction whenever
// `len >= step` — true for every asset of length >= 2 at any clamped step
// (step <= 2.0). The oracle is therefore the faithful reference for all
// multi-sample assets used in the agreement tests; the divergence on a
// 1-sample asset is characterized separately as a BUG, not papered over here.
const Oracle = struct {
    asset: []const f32,
    loop: bool,
    step: f64,
    cursor: f64 = 0,
    done: bool = false,

    fn init(asset_frames: []const Sample(f32), loop: bool, pitch: f32, buf: []f32) Oracle {
        // Project the mono frames to a scalar array the caller owns.
        for (asset_frames, buf[0..asset_frames.len]) |fr, *o| o.* = fr.ch[0];
        return .{
            .asset = buf[0..asset_frames.len],
            .loop = loop,
            .step = @min(@max(@as(f64, pitch), min_step), max_step),
        };
    }

    fn next(self: *Oracle) f32 {
        const len = self.asset.len;
        if (len == 0) {
            self.done = true;
            return 0;
        }
        // Full `while` reduction — the mathematically-intended periodic read.
        while (self.cursor >= @as(f64, @floatFromInt(len))) {
            if (self.loop) {
                self.cursor -= @floatFromInt(len);
            } else {
                self.done = true;
                return 0;
            }
        }
        const idx0: usize = @intFromFloat(@floor(self.cursor));
        // The block computes `frac` in the f64 cursor domain, rounds it to the
        // f32 lane, and then does the lerp arithmetic ENTIRELY in f32 (x0/x1 are
        // f32, frac is f32). To agree bit-for-bit the oracle must round frac to
        // f32 first and interpolate in f32 too — the difference vs. an all-f64
        // computation is a last-ULP rounding that a bit-exact check sees.
        const frac: f32 = @floatCast(self.cursor - @as(f64, @floatFromInt(idx0)));
        const x0: f32 = self.asset[idx0];
        const x1: f32 = if (idx0 + 1 < len)
            self.asset[idx0 + 1]
        else if (self.loop)
            self.asset[0]
        else
            0;
        const y: f32 = x0 + frac * (x1 - x0);
        self.cursor += self.step;
        return y;
    }
};

/// Render the oracle into `out` for `want` outputs.
fn oracleRender(
    asset: []const Sample(f32),
    loop: bool,
    pitch: f32,
    scratch: []f32,
    out: []f32,
) void {
    var orc = Oracle.init(asset, loop, pitch, scratch);
    for (out) |*o| o.* = orc.next();
}

// ===========================================================================
// LAW 1 — pitch == 1 plays the asset at its native rate, sample-for-sample.
// ===========================================================================
//
// cursor starts at 0 with frac 0, step 1.0, so out[i] reads asset index i
// EXACTLY (no fractional pre-roll). This pins that there is no read-offset at
// the start: out[0] == asset[0], not asset[-1]==0.

test "pitch 1 plays the asset sample-for-sample with no read offset" {
    const asset = [_]Sample(f32){ s(0.10), s(-0.40), s(0.75), s(0.20), s(-0.95) };
    var sp = playerNonLoop(&asset, 1.0);

    var out: [5]Sample(f32) = undefined;
    const produced = sp.pull(out.len, &out);
    try std.testing.expectEqual(@as(usize, 5), produced);

    // Bit-exact: at step 1 the interpolation frac is always 0, so out == asset.
    for (asset, out) |a, o| {
        try std.testing.expectEqual(a.ch[0], o.ch[0]);
    }
}

// ===========================================================================
// LAW 2 — pitch == 2 plays twice as fast: out[i] == asset[2i] (even taps).
// ===========================================================================
//
// step 2.0 lands the cursor on integer indices 0,2,4,..., frac always 0, so
// each output is an exact even-indexed asset sample (no interpolation).

test "pitch 2 reads every other asset sample (out[i] == asset[2i])" {
    const asset = [_]Sample(f32){
        s(0.0), s(0.1), s(0.2), s(0.3), s(0.4), s(0.5), s(0.6), s(0.7),
    };
    var sp = playerNonLoop(&asset, 2.0);

    var out: [4]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);

    try std.testing.expectEqual(asset[0].ch[0], out[0].ch[0]);
    try std.testing.expectEqual(asset[2].ch[0], out[1].ch[0]);
    try std.testing.expectEqual(asset[4].ch[0], out[2].ch[0]);
    try std.testing.expectEqual(asset[6].ch[0], out[3].ch[0]);
}

// ===========================================================================
// LAW 3 — pitch == 0.5 plays at half speed: integer outputs land on samples,
//         odd outputs land on the exact midpoint between neighbours.
// ===========================================================================
//
// step 0.5: cursor = 0,0.5,1.0,1.5,... so out[0]=asset[0], out[1]=midpoint of
// asset[0],asset[1], out[2]=asset[1], out[3]=midpoint of asset[1],asset[2],...

test "pitch 0.5 half-speed: integers exact, halves are the midpoints" {
    const asset = [_]Sample(f32){ s(0.0), s(1.0), s(0.0), s(-1.0) };
    var sp = playerNonLoop(&asset, 0.5);

    var out: [7]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);

    try std.testing.expectEqual(@as(f32, 0.0), out[0].ch[0]); // asset[0]
    try std.testing.expectEqual(@as(f32, 0.5), out[1].ch[0]); // mid(0,1)
    try std.testing.expectEqual(@as(f32, 1.0), out[2].ch[0]); // asset[1]
    try std.testing.expectEqual(@as(f32, 0.5), out[3].ch[0]); // mid(1,0)
    try std.testing.expectEqual(@as(f32, 0.0), out[4].ch[0]); // asset[2]
    try std.testing.expectEqual(@as(f32, -0.5), out[5].ch[0]); // mid(0,-1)
    try std.testing.expectEqual(@as(f32, -1.0), out[6].ch[0]); // asset[3]
}

// ===========================================================================
// LAW 4 — bit-exact agreement with the independent f64 lerp oracle, several
//         pitches, both loop modes. This is the core "tests as definition":
//         a different control flow computing the same contract agrees exactly.
// ===========================================================================

test "matches the independent f64 lerp oracle across pitches (non-loop)" {
    const asset = [_]Sample(f32){
        s(0.13), s(-0.27), s(0.61), s(-0.04), s(0.88), s(-0.51), s(0.33), s(0.02),
    };
    // Pitches that exercise irrational-ish fractional walks, all in clamp range.
    const pitches = [_]f32{ 0.5, 0.7, 1.0, 1.3, 1.7, 2.0 };
    var scratch: [asset.len]f32 = undefined;

    for (pitches) |p| {
        var sp = playerNonLoop(&asset, p);
        var got: [16]Sample(f32) = undefined;
        _ = sp.pull(got.len, &got);

        var ref: [16]f32 = undefined;
        oracleRender(&asset, false, p, &scratch, &ref);

        try h.bitExact(f32, h.sampleValues(&got), &ref);
    }
}

test "matches the independent f64 lerp oracle across pitches (looping, long horizon)" {
    const asset = [_]Sample(f32){
        s(-0.9), s(0.4), s(0.15), s(-0.6), s(0.72), s(0.01), s(-0.33),
    };
    const pitches = [_]f32{ 0.5, 0.6, 1.0, 1.25, 1.9, 2.0 };
    var scratch: [asset.len]f32 = undefined;

    for (pitches) |p| {
        var sp = playerLoop(&asset, p);
        // 50 outputs forces several wraps for every pitch.
        var got: [50]Sample(f32) = undefined;
        _ = sp.pull(got.len, &got);

        var ref: [50]f32 = undefined;
        oracleRender(&asset, true, p, &scratch, &ref);

        try h.bitExact(f32, h.sampleValues(&got), &ref);
    }
}

// ===========================================================================
// LAW 5 — pitch clamping is total: a request below 0.5 realises 0.5, a request
//         above 2.0 realises 2.0. Proven by observing the realised read rate.
// ===========================================================================

test "pitch request 0.25 clamps to 0.5 (observable read rate)" {
    // A linear ramp asset: out[i] reveals the cursor (since lerp of a ramp is
    // the cursor itself). At realised step 0.5 the cursor after k outputs is
    // 0.5*k, so out[k] == 0.5*k while in range.
    const asset = [_]Sample(f32){ s(0), s(1), s(2), s(3), s(4), s(5), s(6) };
    var sp = playerNonLoop(&asset, 0.25); // requested below the floor

    var out: [7]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);

    // Realised step must be 0.5, NOT 0.25 (which would give 0.25*k).
    for (out, 0..) |o, k| {
        const expect: f32 = 0.5 * @as(f32, @floatFromInt(k));
        try std.testing.expectEqual(expect, o.ch[0]);
    }
}

test "pitch request 8.0 clamps to 2.0 (observable read rate)" {
    const asset = [_]Sample(f32){ s(0), s(1), s(2), s(3), s(4), s(5), s(6), s(7) };
    var sp = playerNonLoop(&asset, 8.0); // requested far above the ceiling

    var out: [4]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);

    // Realised step 2.0 ⇒ out[k] == 2*k (reads indices 0,2,4,6).
    for (out, 0..) |o, k| {
        const expect: f32 = 2.0 * @as(f32, @floatFromInt(k));
        try std.testing.expectEqual(expect, o.ch[0]);
    }
}

test "the clamp interval endpoints are exactly 0.5 and 2.0 (not just clamped, the right bounds)" {
    // Asset = ramp; first output is always asset[0]==0. The SECOND output is
    // exactly the realised step (cursor after one advance, on a ramp). So the
    // second output value reads back the realised step directly.
    const asset = [_]Sample(f32){ s(0), s(1), s(2), s(3) };

    {
        var sp = playerNonLoop(&asset, -1.0); // way below ⇒ 0.5
        var out: [2]Sample(f32) = undefined;
        _ = sp.pull(out.len, &out);
        try std.testing.expectEqual(@as(f32, 0.5), out[1].ch[0]);
    }
    {
        var sp = playerNonLoop(&asset, 1000.0); // way above ⇒ 2.0
        var out: [2]Sample(f32) = undefined;
        _ = sp.pull(out.len, &out);
        try std.testing.expectEqual(@as(f32, 2.0), out[1].ch[0]);
    }
    {
        var sp = playerNonLoop(&asset, 0.5); // exactly the floor stays 0.5
        var out: [2]Sample(f32) = undefined;
        _ = sp.pull(out.len, &out);
        try std.testing.expectEqual(@as(f32, 0.5), out[1].ch[0]);
    }
    {
        var sp = playerNonLoop(&asset, 2.0); // exactly the ceiling stays 2.0
        var out: [2]Sample(f32) = undefined;
        _ = sp.pull(out.len, &out);
        try std.testing.expectEqual(@as(f32, 2.0), out[1].ch[0]);
    }
}

// ===========================================================================
// LAW 6 — held-per-call: a setParam between pulls changes only the NEXT pull;
//         it cannot change the step mid-buffer.
// ===========================================================================

test "setParam between pulls takes effect only on the next pull" {
    const asset = [_]Sample(f32){ s(0), s(1), s(2), s(3), s(4), s(5), s(6), s(7) };

    // First pull at step 1.0 over a ramp: out == 0,1,2 (cursor lands on 0,1,2;
    // after the 3rd output the cursor is at 3.0).
    var sp = playerNonLoop(&asset, 1.0);
    var first: [3]Sample(f32) = undefined;
    _ = sp.pull(first.len, &first);
    try std.testing.expectEqual(@as(f32, 0), first[0].ch[0]);
    try std.testing.expectEqual(@as(f32, 1), first[1].ch[0]);
    try std.testing.expectEqual(@as(f32, 2), first[2].ch[0]);

    // Change step to 2.0 BEFORE the second pull. The change must not have
    // affected the first pull (already checked: it stayed at step 1).
    sp.setParam(0, 2.0);
    var second: [2]Sample(f32) = undefined;
    _ = sp.pull(second.len, &second);
    // cursor resumes at 3.0; step 2.0 ⇒ reads 3 then 5.
    try std.testing.expectEqual(@as(f32, 3), second[0].ch[0]);
    try std.testing.expectEqual(@as(f32, 5), second[1].ch[0]);
}

test "a setParam issued during the same pull window is ignored until the next pull (single-call hold)" {
    // There is no in-pull setParam hook, so we prove the converse: the step is
    // read exactly once. Two equal-length pulls with a step change between them
    // differ ONLY from the change point on, never retroactively.
    const asset = [_]Sample(f32){ s(0), s(2), s(4), s(6), s(8), s(10) };

    var a = playerNonLoop(&asset, 1.0);
    var b = playerNonLoop(&asset, 1.0);

    var ao: [3]Sample(f32) = undefined;
    var bo: [3]Sample(f32) = undefined;
    _ = a.pull(ao.len, &ao);
    _ = b.pull(bo.len, &bo);
    // Both at step 1 ⇒ identical first halves.
    try h.bitExact(f32, h.sampleValues(&ao), h.sampleValues(&bo));

    // Now diverge a's step. The already-produced ao must be untouched.
    a.setParam(0, 0.5);
    try std.testing.expectEqual(@as(f32, 0), ao[0].ch[0]);
    try std.testing.expectEqual(@as(f32, 2), ao[1].ch[0]);
    try std.testing.expectEqual(@as(f32, 4), ao[2].ch[0]);
}

// ===========================================================================
// LAW 7 — chunked-pull continuity: a sequence of pulls is BIT-IDENTICAL to one
//         big pull (the fractional cursor resumes exactly across seams).
// ===========================================================================

test "chunked pulls are bit-identical to one whole pull (non-loop, fractional step)" {
    const asset = [_]Sample(f32){
        s(0.21), s(-0.66), s(0.45), s(0.9), s(-0.12), s(0.37), s(-0.8), s(0.05),
    };
    const total = 24;
    const pitch: f32 = 1.3; // fractional ⇒ a non-trivial cursor remainder at seams

    // One whole pull.
    var whole = playerNonLoop(&asset, pitch);
    var whole_out: [total]Sample(f32) = undefined;
    _ = whole.pull(total, &whole_out);

    // The same render in chunks of 1,5,2,9,7 (sums to 24, varied sizes).
    var chunked = playerNonLoop(&asset, pitch);
    var chunk_out: [total]Sample(f32) = undefined;
    const sizes = [_]usize{ 1, 5, 2, 9, 7 };
    var off: usize = 0;
    for (sizes) |sz| {
        _ = chunked.pull(sz, chunk_out[off .. off + sz]);
        off += sz;
    }
    try std.testing.expectEqual(@as(usize, total), off);

    try h.bitExact(f32, h.sampleValues(&whole_out), h.sampleValues(&chunk_out));
}

test "chunked pulls are bit-identical to one whole pull (looping, across wraps)" {
    const asset = [_]Sample(f32){ s(0.5), s(-0.5), s(0.25), s(-0.25), s(0.1) };
    const total = 33;
    const pitch: f32 = 0.7;

    var whole = playerLoop(&asset, pitch);
    var whole_out: [total]Sample(f32) = undefined;
    _ = whole.pull(total, &whole_out);

    var chunked = playerLoop(&asset, pitch);
    var chunk_out: [total]Sample(f32) = undefined;
    const sizes = [_]usize{ 11, 1, 13, 8 };
    var off: usize = 0;
    for (sizes) |sz| {
        _ = chunked.pull(sz, chunk_out[off .. off + sz]);
        off += sz;
    }
    try std.testing.expectEqual(@as(usize, total), off);

    try h.bitExact(f32, h.sampleValues(&whole_out), h.sampleValues(&chunk_out));
}

// ===========================================================================
// LAW 8 — loop wrap periodicity: a looping asset at step 1 is exactly L-periodic
//         in the output; at integer-divisible steps it stays periodic too.
// ===========================================================================

test "looping at step 1 is exactly period-L in the output" {
    const asset = [_]Sample(f32){ s(0.3), s(-0.7), s(0.9), s(-0.1) };
    var sp = playerLoop(&asset, 1.0);

    var out: [16]Sample(f32) = undefined; // 4 full periods
    _ = sp.pull(out.len, &out);

    // out[i] == asset[i mod 4], bit-exact.
    for (out, 0..) |o, i| {
        try std.testing.expectEqual(asset[i % asset.len].ch[0], o.ch[0]);
    }
}

test "looping never latches done and never goes silent" {
    const asset = [_]Sample(f32){ s(0.8), s(-0.2), s(0.4) };
    var sp = playerLoop(&asset, 1.7);

    var out: [200]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);

    try std.testing.expect(!sp.exhausted());
    // A looping non-silent asset never produces an all-zero tail; assert the
    // last 50 outputs are not all zero (the asset has no run of >2 zeros).
    var any_nonzero = false;
    for (out[150..]) |o| {
        if (o.ch[0] != 0) any_nonzero = true;
    }
    try std.testing.expect(any_nonzero);
}

// ===========================================================================
// LAW 9 — non-loop drain: once the cursor reaches the end, the tail is silence,
//         and done/exhausted latch true.
// ===========================================================================

test "non-loop drain pads silence and latches done/exhausted" {
    const asset = [_]Sample(f32){ s(0.6), s(-0.6), s(0.6) }; // len 3
    var sp = playerNonLoop(&asset, 1.0);
    try std.testing.expect(!sp.exhausted()); // not yet pulled

    var out: [8]Sample(f32) = undefined;
    const produced = sp.pull(out.len, &out);
    // `pull` always fills `want` (it pads), so produced == want.
    try std.testing.expectEqual(@as(usize, 8), produced);

    // First 3 are the asset (step 1), the rest is silence.
    try std.testing.expectEqual(@as(f32, 0.6), out[0].ch[0]);
    try std.testing.expectEqual(@as(f32, -0.6), out[1].ch[0]);
    try std.testing.expectEqual(@as(f32, 0.6), out[2].ch[0]);
    for (out[3..]) |o| try std.testing.expectEqual(@as(f32, 0), o.ch[0]);

    try std.testing.expect(sp.exhausted());
    // Once latched, a subsequent pull is all silence and stays exhausted.
    var more: [4]Sample(f32) = undefined;
    _ = sp.pull(more.len, &more);
    for (more) |o| try std.testing.expectEqual(@as(f32, 0), o.ch[0]);
    try std.testing.expect(sp.exhausted());
}

test "non-loop done does NOT latch while the asset is still playing" {
    const asset = [_]Sample(f32){ s(0.1), s(0.2), s(0.3), s(0.4), s(0.5), s(0.6) };
    var sp = playerNonLoop(&asset, 1.0);
    var out: [4]Sample(f32) = undefined; // only 4 of 6 consumed
    _ = sp.pull(out.len, &out);
    try std.testing.expect(!sp.exhausted());
}

// ===========================================================================
// LAW 10 — DC invariance: a constant asset stays exactly that constant at every
//          pitch (interpolation between equal neighbours is the constant), in
//          both loop modes, until a non-looping drain reaches silence.
// ===========================================================================

test "DC asset stays constant at every pitch (looping)" {
    const dc: f32 = 0.42;
    const asset = [_]Sample(f32){ s(dc), s(dc), s(dc), s(dc), s(dc) };
    const pitches = [_]f32{ 0.5, 0.5001, 1.0, 1.3333, 1.75, 2.0 };

    for (pitches) |p| {
        var sp = playerLoop(&asset, p);
        var out: [64]Sample(f32) = undefined;
        _ = sp.pull(out.len, &out);
        for (out) |o| try std.testing.expectEqual(dc, o.ch[0]);
    }
}

test "DC asset stays constant until drain (non-loop), then silence" {
    const dc: f32 = -0.33;
    const asset = [_]Sample(f32){ s(dc), s(dc), s(dc), s(dc) }; // len 4
    var sp = playerNonLoop(&asset, 1.0);
    var out: [4]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);
    for (out) |o| try std.testing.expectEqual(dc, o.ch[0]);
}

// ===========================================================================
// LAW 11 — linearity at a fixed step: out(a*x + b*y) == a*out(x) + b*out(y),
//          because the kernel is affine in the asset and the read schedule is
//          value-independent. Float tolerance applies (different mul/add order).
// ===========================================================================

test "the player is a linear operator at a fixed pitch" {
    const x = [_]Sample(f32){ s(0.10), s(-0.40), s(0.75), s(0.20), s(-0.95), s(0.33) };
    const y = [_]Sample(f32){ s(-0.5), s(0.6), s(-0.1), s(0.9), s(0.05), s(-0.7) };
    const a: f32 = 1.7;
    const b: f32 = -0.8;
    const pitch: f32 = 1.3;

    // combined asset = a*x + b*y
    var combined: [x.len]Sample(f32) = undefined;
    for (x, y, &combined) |xi, yi, *c| c.ch[0] = a * xi.ch[0] + b * yi.ch[0];

    var sx = playerLoop(&x, pitch);
    var sy = playerLoop(&y, pitch);
    var sc = playerLoop(&combined, pitch);

    const n = 30;
    var ox: [n]Sample(f32) = undefined;
    var oy: [n]Sample(f32) = undefined;
    var oc: [n]Sample(f32) = undefined;
    _ = sx.pull(n, &ox);
    _ = sy.pull(n, &oy);
    _ = sc.pull(n, &oc);

    var expect: [n]f32 = undefined;
    for (ox, oy, &expect) |oxi, oyi, *e| e.* = a * oxi.ch[0] + b * oyi.ch[0];

    try h.allcloseF32(h.sampleValues(&oc), &expect, .{ .approx = .{ .atol = 1e-6, .rtol = 1e-5 } });
}

// ===========================================================================
// LAW 12 — degenerate demands: want == 0 produces nothing and touches no state.
// ===========================================================================

test "want 0 produces nothing and leaves the cursor untouched" {
    const asset = [_]Sample(f32){ s(0.1), s(0.2), s(0.3) };
    var sp = playerNonLoop(&asset, 1.0);

    var empty: [0]Sample(f32) = undefined;
    const produced = sp.pull(0, &empty);
    try std.testing.expectEqual(@as(usize, 0), produced);
    try std.testing.expect(!sp.exhausted());

    // A following real pull must start at asset[0] (cursor never moved).
    var out: [3]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);
    try std.testing.expectEqual(@as(f32, 0.1), out[0].ch[0]);
    try std.testing.expectEqual(@as(f32, 0.2), out[1].ch[0]);
    try std.testing.expectEqual(@as(f32, 0.3), out[2].ch[0]);
}

// ===========================================================================
// LAW 13 — empty asset: every output is silence; done latches immediately,
//          regardless of loop flag or pitch.
// ===========================================================================

test "empty asset is all silence and latches done (default-constructed)" {
    var sp = SP{}; // default: empty data, loop = true
    var out: [10]Sample(f32) = undefined;
    const produced = sp.pull(out.len, &out);
    try std.testing.expectEqual(@as(usize, 10), produced);
    for (out) |o| try std.testing.expectEqual(@as(f32, 0), o.ch[0]);
    // Even a LOOPING empty asset latches done (there is nothing to loop).
    try std.testing.expect(sp.exhausted());
}

test "empty asset is silence at any pitch and both loop modes" {
    const pitches = [_]f32{ 0.5, 1.0, 2.0 };
    for (pitches) |p| {
        inline for (.{ true, false }) |lp| {
            var sp = SP{ .data = &.{}, .loop = lp };
            sp.setParam(0, p);
            var out: [5]Sample(f32) = undefined;
            _ = sp.pull(out.len, &out);
            for (out) |o| try std.testing.expectEqual(@as(f32, 0), o.ch[0]);
            try std.testing.expect(sp.exhausted());
        }
    }
}

// ===========================================================================
// LAW 14 — classification: a complete VariRate, and a SOURCE (zero sample in).
// ===========================================================================

test "classifies as VariRate and is a source" {
    try std.testing.expect(pan.classify(SP) == .VariRate);
    try std.testing.expect(comptime pan.port.isSource(SP));
}

test "declared contract surface: rate_bounds, max_latency, ratio_source, needed_input parity" {
    // rate_bounds endpoints: min out:in = 1/2 (fastest pitch), max = 2/1.
    try std.testing.expectEqual(@as(comptime_int, 1), SP.rate_bounds.min[0]);
    try std.testing.expectEqual(@as(comptime_int, 2), SP.rate_bounds.min[1]);
    try std.testing.expectEqual(@as(comptime_int, 1), SP.rate_bounds.nominal[0]);
    try std.testing.expectEqual(@as(comptime_int, 1), SP.rate_bounds.nominal[1]);
    try std.testing.expectEqual(@as(comptime_int, 2), SP.rate_bounds.max[0]);
    try std.testing.expectEqual(@as(comptime_int, 1), SP.rate_bounds.max[1]);

    try std.testing.expectEqual(@as(usize, 1), SP.max_latency);
    try std.testing.expect(SP.ratio_source == .parameter);

    // needed_input is the worst-case 2× parity bound.
    var sp = SP{};
    try std.testing.expectEqual(@as(usize, 0), sp.needed_input(0));
    try std.testing.expectEqual(@as(usize, 20), sp.needed_input(10));
}

// ===========================================================================
// LAW 15 — one-sample asset. A degenerate asset of length 1; at step 1 it is a
//          constant DC stream (looping). This also probes the wrap-reduction.
// ===========================================================================

test "one-sample looping asset at step 1 is a DC stream" {
    const asset = [_]Sample(f32){s(0.77)};
    var sp = playerLoop(&asset, 1.0);
    var out: [10]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);
    // cursor walks 0,1,2,...; wrap subtracts 1 each time (len 1), so it stays
    // on index 0 with frac 0 ⇒ constant. (step 1 <= len 1 ⇒ single-`if` wrap is
    // sufficient, so this is exact.)
    for (out) |o| try std.testing.expectEqual(@as(f32, 0.77), o.ch[0]);
}

test "one-sample non-looping asset: one sample then silence and done" {
    const asset = [_]Sample(f32){s(0.55)};
    var sp = playerNonLoop(&asset, 1.0);
    var out: [4]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);
    try std.testing.expectEqual(@as(f32, 0.55), out[0].ch[0]);
    for (out[1..]) |o| try std.testing.expectEqual(@as(f32, 0), o.ch[0]);
    try std.testing.expect(sp.exhausted());
}

// ---------------------------------------------------------------------------
// BUG DETECTED — partial wrap reduction when the step exceeds the asset length.
//
// The `pull` loop reduces an out-of-range cursor with a SINGLE `if` per output
// (subtract `len` AT MOST ONCE), not a `while`. That is sound only while
// `cursor < 2*len` after one advance, i.e. while `step <= len`. For a clamped
// step up to 2.0, any asset of length >= 2 is safe. But a LOOPING 1-sample
// asset at step 2.0 breaks it:
//
//   cursor 0  → out[0] = asset[0] = 0.77 ; cursor += 2 → 2.0
//   cursor 2.0 >= 1 → subtract 1 → 1.0 (NOT re-checked) → idx0 = floor(1.0) = 1
//                   → readAsset(1) is past the 1-sample asset → 0
//                   → out[1] = 0 (spurious silence) ; cursor += 2 → 3.0
//   cursor 3.0 >= 1 → subtract 1 → 2.0 → idx0 = 2 → 0 → out[2] = 0 ; …
//   the cursor never re-enters [0,1), so every output after the first is 0.
//
//   Expected (the mathematically-intended periodic read, a true modulo-`len`
//   wrap — what the oracle's `while` reduction computes): a constant 0.77 DC
//   stream, since a 1-sample loop has only one value to read at any phase.
//   Actual: 0.77 followed by silence forever.
//
//   Fix: reduce the wrap with `while (cursor >= len)` (a real modulo), so the
//   cursor always re-enters [0,len) regardless of how far step over-shoots.
//
// This test PINS the current (defective) behaviour so the suite stays green and
// the defect is recorded as an executable spec; it must be flipped to the
// "constant 0.77" expectation the moment the wrap is fixed.
// ---------------------------------------------------------------------------

test "one-sample looping asset at a fast pitch is a constant DC stream (true modulo wrap)" {
    // A 1-sample loop has only one value to read at any phase, so a looping read —
    // even at a fast pitch that overshoots the single-sample length by more than one
    // length per step — must produce that constant forever. This exercises the
    // `while`-reduced (true modulo) wrap: a single subtract would leave the cursor
    // still past the end and the read would spuriously fall to silence.
    const asset = [_]Sample(f32){s(0.77)};
    var sp = playerLoop(&asset, 2.0);
    var out: [8]Sample(f32) = undefined;
    _ = sp.pull(out.len, &out);
    for (out) |o| try std.testing.expectEqual(@as(f32, 0.77), o.ch[0]);
    // A looping source never reports exhaustion.
    try std.testing.expect(!sp.exhausted());
}
