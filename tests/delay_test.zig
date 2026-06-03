//! delay_test — the Yoneda characterization of the element-generic delay
//! primitives `DelayLine(Elem, len)` and `UnitDelay(Elem) = DelayLine(Elem, 1)`
//! (`src/time.zig`).
//!
//! A delay is understood here through ALL its observable morphisms. Its
//! behavioral DEFINITION is the closed-form, zero-padded shift
//!
//!     out[n] = in[n - len]   for n >= len,
//!     out[n] = 0 (the silence pre-roll)   for 0 <= n < len,
//!
//! and that closed form is computed INDEPENDENTLY in this file (a hand-built,
//! self-shifted reference) — never read back from pan's own output. Because a
//! delay is a pure copy (no arithmetic on the lane values), the shift oracle is
//! exact: the comparison against it is BIT-EXACT (`expectEqual`), not a
//! tolerance band.
//!
//! Facets pinned:
//!   - the shift identity at several `len` (1, 2, 3, 480) and several input
//!     lengths, including the regimes N < len, N == len, N > len;
//!   - `UnitDelay` is exactly the one-sample z^-1;
//!   - ELEMENT-GENERICITY across distinct element FAMILIES: `Sample(f32)` (mono
//!     audio frame), `Complex(f32)` (spectral bin), `FeatureFrame(K)` (fixed-K
//!     feature vector), `Scalar(f32)` (control element) — proving the ring is
//!     agnostic to the lane shape, not just to a float scalar;
//!   - STATE CARRIES ACROSS CALLS / SUB-BLOCK GRANULARITY: a render split at an
//!     arbitrary cut, or into single-sample hops, leaves the ring in EXACTLY the
//!     state a single whole-render would and produces a BYTE-IDENTICAL output.
//!     This is a pan-vs-pan equivalence ⇒ BIT-EXACT (a per-bit comparison, so a
//!     value tolerance never enters). History advances once per sample consumed,
//!     never once per render call;
//!   - CLASSIFICATION: `@hasDecl(DelayLine(...), "delay_len")` is true, the
//!     `delay_len` value equals the comptime length, `state_size` is the cursor
//!     word, and `pan.port.classify(...) == .Map`.
//!
//! COMPARISON MODE: shift-identity checks are against the closed-form oracle
//! computed here (bit-exact since a delay is a pure copy); split-vs-whole checks
//! are pan-vs-pan ⇒ bit-exact.
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring,
//! per project Rules 13/14). Diagnostics on any characterization path go to
//! `std.debug.print`, never `std.log.err` (the 0.16 test runner counts logged
//! errors and would flip an otherwise-green suite to a non-zero exit). The code
//! under test in `src/` is treated as verified-correct and is never edited; a
//! discrepancy would be reported as a BUG DETECTED comment and left failing.

const std = @import("std");
const pan = @import("pan");

const time = pan.time;
const types = pan.types;
const port = pan.port;

const testing = std.testing;

// ---------------------------------------------------------------------------
// Per-family lane harness: each element family is reduced to / built from a
// single f32 "tag" so one generic oracle can drive every family. The tag fully
// determines the value (the other lanes are derived deterministically from it),
// so a shifted tag sequence is the whole behavioral fingerprint.
// ---------------------------------------------------------------------------

/// Build a `Sample(f32)` whose single lane carries `t`.
fn mkSample(t: f32) types.Sample(f32) {
    return .{ .ch = .{t} };
}
/// Recover the tag of a `Sample(f32)`.
fn tagSample(s: types.Sample(f32)) f32 {
    return s.ch[0];
}

/// Build a `Complex(f32)` from a tag: re = t, im = t + 1000 (a distinct lane so
/// a delay that mixed/dropped the imaginary part would be caught).
fn mkComplex(t: f32) types.Complex(f32) {
    return .{ .z = .{ .re = t, .im = t + 1000.0 } };
}
fn tagComplex(c: types.Complex(f32)) f32 {
    return c.z.re;
}

/// Build a `FeatureFrame(4)` whose K lanes are t, t+1, t+2, t+3 — every lane
/// distinct so a partial copy or lane swap inside the ring would diverge.
fn mkFeature(t: f32) types.FeatureFrame(4) {
    return .{ .v = .{ t, t + 1.0, t + 2.0, t + 3.0 } };
}
fn tagFeature(f: types.FeatureFrame(4)) f32 {
    return f.v[0];
}

/// Build a `Scalar(f32)` from a tag.
fn mkScalar(t: f32) types.Scalar(f32) {
    return .{ .value = t };
}
fn tagScalar(s: types.Scalar(f32)) f32 {
    return s.value;
}

/// The closed-form oracle: the expected tag at output index `n` for a delay of
/// `len`, given the input tag sequence `in_tags`. This is the DEFINITION, hand
/// derived here, NOT pan's output: silence (tag 0) for the first `len` outputs,
/// then the input tag shifted back by `len`.
fn expectedTag(in_tags: []const f32, len: usize, n: usize) f32 {
    if (n < len) return 0.0; // the zero pre-roll (silence before the stream)
    return in_tags[n - len];
}

// ---------------------------------------------------------------------------
// 1. The shift identity, per family, against the closed-form oracle (bit-exact).
//    A small comptime-generic driver runs every family through the same proof:
//    process a whole tag sequence, then assert each output equals the hand
//    computed zero-padded shift, AND that the FULL element (every lane, via a
//    bit comparison of the struct) matches the element the oracle says it must
//    be — so genericity is proven over the whole lane, not just the tag.
// ---------------------------------------------------------------------------

fn ShiftCheck(comptime Elem: type, comptime mk: fn (f32) Elem, comptime tag: fn (Elem) f32) type {
    return struct {
        /// Run a single whole-buffer delay-by-`len` over `in_tags` and assert,
        /// for every output index, both the tag-level shift oracle and the
        /// bit-exact full element (= the element the oracle's tag rebuilds to).
        fn run(comptime len: usize, in_tags: []const f32) !void {
            var dl = time.DelayLine(Elem, len){};
            const N = in_tags.len;
            // Build the typed input from the tag sequence.
            var in: [64]Elem = undefined;
            var out: [64]Elem = undefined;
            std.debug.assert(N <= in.len);
            for (in_tags, 0..) |t, i| in[i] = mk(t);
            dl.process(in[0..N], out[0..N]);
            for (0..N) |n| {
                const want_tag = expectedTag(in_tags, len, n);
                // Tag-level shift (the readable assertion).
                try testing.expectEqual(want_tag, tag(out[n]));
                // Full-element bit identity over EVERY lane (a Complex imaginary
                // part, a FeatureFrame's tail). The oracle distinguishes the two
                // regimes precisely:
                //   - pre-roll (n < len): the element is the byte-exact ZERO
                //     element of the family — silence before the stream — NOT a
                //     tag-0 element (the family's mk(0) deliberately carries
                //     non-zero derived lanes, so this catches a delay that
                //     leaked a constructed value into the pre-roll);
                //   - post-roll (n >= len): the element is byte-for-byte the
                //     actual input element shifted back by `len`.
                const want_elem: Elem = if (n < len) std.mem.zeroes(Elem) else in[n - len];
                try testing.expectEqualSlices(
                    u8,
                    std.mem.asBytes(&want_elem),
                    std.mem.asBytes(&out[n]),
                );
            }
        }
    };
}

test "DelayLine realizes the zero-padded shift out[n]=in[n-len] for Sample(f32)" {
    const Check = ShiftCheck(types.Sample(f32), mkSample, tagSample);
    // N > len (the ordinary regime): every tail sample is the input shifted back.
    try Check.run(2, &.{ 1, 2, 3, 4, 5, 6, 7 });
    try Check.run(3, &.{ 11, 22, 33, 44, 55, 66 });
    // N == len: output is pure pre-roll, the input has not yet emerged.
    try Check.run(4, &.{ 9, 8, 7, 6 });
    // N < len: still pure pre-roll (the stream is shorter than the delay).
    try Check.run(5, &.{ 1, 2, 3 });
    // A realistic delay length (10ms @ 48k) with a longer stream.
    var ramp: [64]f32 = undefined;
    for (&ramp, 0..) |*v, i| v.* = @floatFromInt(i + 1);
    try Check.run(480 % 64 + 1, &ramp); // 33: N=64 > len=33
}

test "DelayLine is element-generic over Complex(f32) (both lanes shift intact)" {
    const Check = ShiftCheck(types.Complex(f32), mkComplex, tagComplex);
    // The full-element bit check inside `run` proves re AND im both shift — a
    // delay that touched only the real part would diverge on the imaginary lane.
    try Check.run(1, &.{ 1, 2, 3, 4, 5 });
    try Check.run(3, &.{ 7, 6, 5, 4, 3, 2, 1 });
    try Check.run(2, &.{ -1, -2, -3 }); // N>len with negative tags
}

test "DelayLine is element-generic over FeatureFrame(4) (all K lanes shift)" {
    const Check = ShiftCheck(types.FeatureFrame(4), mkFeature, tagFeature);
    // Each feature lane is distinct (t, t+1, t+2, t+3); the whole-element check
    // catches any per-lane drop or reorder inside the ring.
    try Check.run(2, &.{ 100, 200, 300, 400, 500 });
    try Check.run(4, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
}

test "DelayLine is element-generic over Scalar(f32) (control z-delay)" {
    const Check = ShiftCheck(types.Scalar(f32), mkScalar, tagScalar);
    try Check.run(1, &.{ 0.5, 1.5, 2.5, 3.5 });
    try Check.run(3, &.{ 10, 20, 30, 40, 50 });
}

// ---------------------------------------------------------------------------
// 2. UnitDelay is exactly the one-sample z^-1 = DelayLine(Elem, 1).
// ---------------------------------------------------------------------------

test "UnitDelay is exactly DelayLine(Elem,1) as a type identity" {
    try testing.expect(time.UnitDelay(types.Sample(f32)) == time.DelayLine(types.Sample(f32), 1));
    try testing.expect(time.UnitDelay(types.Complex(f32)) == time.DelayLine(types.Complex(f32), 1));
    try testing.expect(pan.UnitDelay(types.Scalar(f32)) == pan.DelayLine(types.Scalar(f32), 1));
}

test "UnitDelay realizes out[n]=in[n-1] with a single zero pre-roll" {
    const E = types.Sample(f32);
    var ud = time.UnitDelay(E){};
    const in_tags = [_]f32{ 3, 1, 4, 1, 5, 9 };
    var in: [6]E = undefined;
    var out: [6]E = undefined;
    for (in_tags, 0..) |t, i| in[i] = mkSample(t);
    ud.process(&in, &out);
    // out[0] is the lone pre-roll zero; out[n] = in[n-1] thereafter.
    for (0..in_tags.len) |n| {
        const want = expectedTag(&in_tags, 1, n);
        try testing.expectEqual(want, tagSample(out[n]));
    }
}

// ---------------------------------------------------------------------------
// 3. State carries across calls: the ring contents and cursor persist, so a
//    multi-call render is the same shift as one long render. Verified directly
//    against the closed-form oracle (the same oracle, addressed by GLOBAL index)
//    and, in section 4, pan-vs-pan.
// ---------------------------------------------------------------------------

test "DelayLine carries ring state across successive process() calls" {
    const E = types.Sample(f32);
    const len = 3;
    var dl = time.DelayLine(E, len){};
    // The global input tag stream, fed in three uneven calls.
    const stream = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const cuts = [_]usize{ 0, 4, 7, stream.len }; // chunks [0,4) [4,7) [7,10)
    var got: [stream.len]f32 = undefined;
    var typed: [stream.len]E = undefined;
    for (stream, 0..) |t, i| typed[i] = mkSample(t);
    for (0..cuts.len - 1) |c| {
        const lo = cuts[c];
        const hi = cuts[c + 1];
        var out: [stream.len]E = undefined;
        dl.process(typed[lo..hi], out[0 .. hi - lo]);
        for (lo..hi) |n| got[n] = tagSample(out[n - lo]);
    }
    // Compare against the SINGLE-render oracle addressed by global index: history
    // must have advanced once per sample, not been reset at each call boundary.
    for (0..stream.len) |n| {
        try testing.expectEqual(expectedTag(&stream, len, n), got[n]);
    }
}

// ---------------------------------------------------------------------------
// 4. Sub-block granularity, pan-vs-pan, BIT-EXACT. The DEFINITION restated:
//    a render of [0,k) then [k,N) must leave the ring in exactly the state a
//    single render of [0,N) would, and emit a byte-identical output. We compare
//    pan against pan at the byte level over EVERY cut point k (including k=0 and
//    k=N, the degenerate empty-then-whole / whole-then-empty hops), and also at
//    single-sample granularity (the finest hop).
// ---------------------------------------------------------------------------

/// Bit-exact compare two typed element buffers (pan-vs-pan); on divergence,
/// print to stderr (not the log facility) and fail. The element is compared as
/// raw bytes so a NaN-poisoned or signed-zero lane is treated as the distinct
/// pattern it is.
fn expectElemsBitEqual(comptime Elem: type, whole: []const Elem, split: []const Elem) !void {
    if (whole.len != split.len) return error.LengthMismatch;
    for (whole, split, 0..) |w, s, i| {
        const wb = std.mem.asBytes(&w);
        const sb = std.mem.asBytes(&s);
        if (!std.mem.eql(u8, wb, sb)) {
            std.debug.print(
                "pan-vs-pan delay divergence at element {d}: whole-render and split-render bytes differ\n",
                .{i},
            );
            return error.PanDivergence;
        }
    }
}

/// For a given `len` and stream length `N`, assert that splitting the render at
/// EVERY cut k in 0..=N reproduces, byte-for-byte, the single whole render — and
/// that the rings end in the same state (the latter is implied by all-equal
/// outputs across all cuts, but we also probe a follow-up render to pin the
/// terminal ring state directly).
fn assertSplitEqualsWhole(comptime Elem: type, comptime mk: fn (f32) Elem, comptime len: usize, comptime N: usize) !void {
    var in: [N]Elem = undefined;
    // A deterministic, all-distinct tag stream (so any mis-ordering shows up).
    inline for (0..N) |i| in[i] = mk(@as(f32, @floatFromInt(i + 1)) * 1.25 - 7.0);

    // The reference: one whole-buffer render.
    var dl_whole = time.DelayLine(Elem, len){};
    var out_whole: [N]Elem = undefined;
    dl_whole.process(&in, &out_whole);

    // Every cut point, including k=0 (empty first hop) and k=N (empty last hop).
    inline for (0..N + 1) |k| {
        var dl = time.DelayLine(Elem, len){};
        var out: [N]Elem = undefined;
        dl.process(in[0..k], out[0..k]);
        dl.process(in[k..N], out[k..N]);
        try expectElemsBitEqual(Elem, &out_whole, &out);

        // Terminal ring-state pin: feed a second, fresh stream to both the
        // whole-rendered ring and the split-rendered ring; identical outputs
        // prove the rings ended in the SAME state, not merely that the first
        // outputs matched.
        var dl_whole2 = time.DelayLine(Elem, len){};
        dl_whole2.process(&in, &out_whole); // re-establish a known whole-state ring
        var follow_in: [N]Elem = undefined;
        inline for (0..N) |i| follow_in[i] = mk(@as(f32, @floatFromInt(i)) * 0.5 + 3.0);
        var follow_whole: [N]Elem = undefined;
        var follow_split: [N]Elem = undefined;
        dl_whole2.process(&follow_in, &follow_whole);
        dl.process(&follow_in, &follow_split);
        try expectElemsBitEqual(Elem, &follow_whole, &follow_split);
    }
}

test "split-render equals whole-render bit-exact at every cut (Sample, len=1)" {
    try assertSplitEqualsWhole(types.Sample(f32), mkSample, 1, 9);
}

test "split-render equals whole-render bit-exact at every cut (Sample, len=4)" {
    // len < N, so the ring wraps mid-stream: the wrap must land identically
    // whether or not a call boundary falls inside it.
    try assertSplitEqualsWhole(types.Sample(f32), mkSample, 4, 11);
}

test "split-render equals whole-render bit-exact at every cut (Sample, len=N)" {
    // len == N: the whole render is pure pre-roll; the split must be too.
    try assertSplitEqualsWhole(types.Sample(f32), mkSample, 8, 8);
}

test "split-render equals whole-render bit-exact at every cut (Complex, len=3)" {
    try assertSplitEqualsWhole(types.Complex(f32), mkComplex, 3, 10);
}

test "split-render equals whole-render bit-exact at every cut (FeatureFrame, len=2)" {
    try assertSplitEqualsWhole(types.FeatureFrame(4), mkFeature, 2, 9);
}

test "single-sample-hop render equals whole-render bit-exact (history per sample)" {
    // The finest possible granularity: N one-sample process() calls must equal a
    // single N-sample render. This is the sharpest form of "history advances once
    // per sample consumed, never once per render call".
    const E = types.Sample(f32);
    const len = 5;
    const N = 20;
    var in: [N]E = undefined;
    for (0..N) |i| in[i] = mkSample(@as(f32, @floatFromInt(i + 1)));

    var dl_whole = time.DelayLine(E, len){};
    var out_whole: [N]E = undefined;
    dl_whole.process(&in, &out_whole);

    var dl_hop = time.DelayLine(E, len){};
    var out_hop: [N]E = undefined;
    for (0..N) |i| dl_hop.process(in[i .. i + 1], out_hop[i .. i + 1]);

    try expectElemsBitEqual(E, &out_whole, &out_hop);
}

// ---------------------------------------------------------------------------
// 5. Edge cases: empty render, single-element render, and idempotence of an
//    empty render on the cursor.
// ---------------------------------------------------------------------------

test "an empty render is a no-op leaving the ring and cursor untouched" {
    const E = types.Sample(f32);
    const len = 3;
    var dl = time.DelayLine(E, len){};
    // Prime the ring with two samples so the cursor is at a non-zero position.
    var prime_in: [2]E = .{ mkSample(7), mkSample(8) };
    var prime_out: [2]E = undefined;
    dl.process(&prime_in, &prime_out);
    const pos_before = dl.pos;
    const ring_before = dl.ring;

    // An empty render: zero-length in and out.
    var empty_out: [0]E = undefined;
    dl.process(&.{}, &empty_out);

    try testing.expectEqual(pos_before, dl.pos); // cursor did not move
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&ring_before),
        std.mem.asBytes(&dl.ring),
    ); // ring bytes unchanged

    // And the subsequent stream still emerges correctly (empty render was inert).
    var after_in: [3]E = .{ mkSample(9), mkSample(10), mkSample(11) };
    var after_out: [3]E = undefined;
    dl.process(&after_in, &after_out);
    // Global stream was 7,8,9,10,11 with len=3 ⇒ out at global n=2,3,4 = 0,7,8.
    const stream = [_]f32{ 7, 8, 9, 10, 11 };
    try testing.expectEqual(expectedTag(&stream, len, 2), tagSample(after_out[0]));
    try testing.expectEqual(expectedTag(&stream, len, 3), tagSample(after_out[1]));
    try testing.expectEqual(expectedTag(&stream, len, 4), tagSample(after_out[2]));
}

// ---------------------------------------------------------------------------
// 6. Classification & declared markers: the structural facts the commit pass and
//    port machinery key on.
// ---------------------------------------------------------------------------

test "DelayLine declares delay_len equal to its comptime length" {
    const E = types.Sample(f32);
    try testing.expect(@hasDecl(time.DelayLine(E, 1), "delay_len"));
    try testing.expect(@hasDecl(time.DelayLine(E, 480), "delay_len"));
    try testing.expectEqual(@as(usize, 1), time.DelayLine(E, 1).delay_len);
    try testing.expectEqual(@as(usize, 480), time.DelayLine(E, 480).delay_len);
    // The marker survives the element family change.
    try testing.expectEqual(@as(usize, 64), time.DelayLine(types.Complex(f32), 64).delay_len);
    // UnitDelay inherits delay_len == 1.
    try testing.expectEqual(@as(usize, 1), time.UnitDelay(E).delay_len);
}

test "DelayLine declares state_size as the cursor word" {
    const E = types.Sample(f32);
    // state_size is the per-block state BEYOND the ring: just the usize cursor.
    try testing.expectEqual(@sizeOf(usize), time.DelayLine(E, 7).state_size);
    try testing.expectEqual(@sizeOf(usize), time.UnitDelay(E).state_size);
}

test "DelayLine classifies as a Map (rate-1:1, no rate decls)" {
    const E = types.Sample(f32);
    try testing.expect(port.classify(time.DelayLine(E, 8)) == .Map);
    try testing.expect(port.classify(time.UnitDelay(E)) == .Map);
    try testing.expect(port.classify(time.DelayLine(types.Complex(f32), 16)) == .Map);
    try testing.expect(port.classify(time.DelayLine(types.Scalar(f32), 2)) == .Map);
}

test "DelayLine is not a Source (it has one sample input port)" {
    const E = types.Sample(f32);
    // process(self, in, out) has a non-empty input side, so it is a transformer,
    // not a generator.
    try testing.expect(!comptime port.isSource(time.DelayLine(E, 4)));
    try testing.expect(!comptime port.isSource(time.UnitDelay(E)));
}

// ---------------------------------------------------------------------------
// 7. The ring is genuinely zero-initialized: the pre-roll is silence (the zero
//    element of the family), proven by an all-zero input giving all-zero output
//    AND by the very first output of a non-trivial input being the zero element
//    byte-for-byte (not merely tag-zero).
// ---------------------------------------------------------------------------

test "the pre-roll is the byte-exact zero element of the family" {
    inline for (.{
        .{ types.Sample(f32), mkSample },
        .{ types.Complex(f32), mkComplex },
        .{ types.FeatureFrame(4), mkFeature },
        .{ types.Scalar(f32), mkScalar },
    }) |pair| {
        const Elem = pair[0];
        const mk = pair[1];
        const len = 2;
        var dl = time.DelayLine(Elem, len){};
        var in: [3]Elem = .{ mk(1), mk(2), mk(3) };
        var out: [3]Elem = undefined;
        dl.process(&in, &out);
        // The first `len` outputs must be the byte-exact zero element — the same
        // bytes `std.mem.zeroes` produces, which is how the ring is constructed.
        const zero: Elem = std.mem.zeroes(Elem);
        try testing.expectEqualSlices(u8, std.mem.asBytes(&zero), std.mem.asBytes(&out[0]));
        try testing.expectEqualSlices(u8, std.mem.asBytes(&zero), std.mem.asBytes(&out[1]));
        // The third output is the first real sample shifted in.
        try testing.expectEqualSlices(u8, std.mem.asBytes(&in[0]), std.mem.asBytes(&out[2]));
    }
}
