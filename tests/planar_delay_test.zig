//! planar_delay_test — the Yoneda characterization of the multi-channel (planar)
//! delay primitives `PlanarDelayLine(Lane, L, len)` and
//! `PlanarUnitDelay(Lane, L) = PlanarDelayLine(Lane, L, 1)` (`src/time.zig`).
//!
//! These are the multi-channel siblings of the scalar `DelayLine`: a
//! `process(in: PlanarConst(Lane,L), out: Planar(Lane,L))` that delays EACH
//! channel plane of a planar `Frame(Lane, L)` stream independently by `len`
//! samples. The block is understood here through ALL its observable morphisms.
//! Its behavioral DEFINITION is the per-plane, closed-form, zero-padded shift
//!
//!     out.plane(c)[n] = in.plane(c)[n - len]   for n >= len,      (the shift)
//!     out.plane(c)[n] = 0  (the silence pre-roll)   for 0 <= n < len,
//!
//! applied to every channel `c in 0..C` (C := L.count()) INDEPENDENTLY — no
//! cross-plane bleed. That closed form is computed in this file (a hand-built,
//! self-shifted reference), one independent tag stream PER CHANNEL — never read
//! back from pan's own output. Because a delay is a pure copy (no arithmetic on
//! the lane values), the shift oracle is EXACT: the comparison against it is
//! BIT-EXACT (`expectEqual` / `expectEqualSlices`), not a tolerance band.
//!
//! Facets pinned:
//!   - PER-PLANE INDEPENDENCE: each channel carries a distinct, all-different tag
//!     stream; the per-plane oracle proves channel `i` never sees channel `j`'s
//!     data — a cross-plane mix, a wrong `base = c*len` offset, or a shared cursor
//!     that desynced a plane would diverge.
//!   - the per-plane shift identity at several `len` (1, 2, 3, 64) and several
//!     stream lengths, spanning N < len, N == len, N > len (the wrap regime).
//!   - `PlanarUnitDelay` is exactly the per-plane one-sample z^-1, and is the
//!     TYPE identity `PlanarDelayLine(Lane, L, 1)`.
//!   - GENERIC OVER LAYOUTS: `.discrete(N)` for several N, `.stereo`, and the
//!     6-channel `.surround_5_1` — the ring's plane-major sectioning must hold
//!     across channel counts.
//!   - GENERIC OVER LANE TYPE: f32 and f64 (a delay is lane-shape agnostic).
//!   - STATE CARRIES ACROSS CALLS / SUB-BLOCK GRANULARITY (S6): a render split at
//!     an arbitrary cut k, or into single-sample hops, leaves the ring — cursor
//!     AND contents, per channel — in EXACTLY the state a single whole-render
//!     would, and emits a BYTE-IDENTICAL output. Pan-vs-pan ⇒ BIT-EXACT. History
//!     advances once per sample consumed, never once per render call.
//!   - the pre-roll is genuine zero (silence before the stream): the first `len`
//!     samples of every plane are the byte-exact zero lane.
//!   - CLASSIFICATION / declared markers: `classify(...) == .Map`, it is NOT a
//!     Source, `@hasDecl(...,"delay_len")` and its value equals the comptime
//!     length, `state_size` is the cursor word, and `MapOutPort(...).Elem ==
//!     Frame(Lane, L)` (the planar view's layout-identity element).
//!
//! COMPARISON MODE: per-plane shift-identity checks are against the closed-form
//! oracle computed here (bit-exact, since a planar delay is a pure per-plane
//! copy); split-vs-whole and hop-vs-whole checks are pan-vs-pan ⇒ bit-exact.
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
// Plane-major backing + the closed-form oracle. A planar buffer of `N` frames on
// a `C`-channel layout is `C` contiguous `N`-sample planes laid out plane-major
// in a flat `[C*N]Lane` block (`[ch0_0..ch0_{N-1}][ch1_0..]..`). Every test below
// builds exactly that storage form and wraps it with `Planar/PlanarConst.fromBase`,
// so `process` is driven with the same plane-major buffer the executor hands a
// block. `channelTag(c,i)` mints an all-distinct per-channel stream (no value is
// shared between channels at any index) and `expectedPlaneTag` is the per-plane
// shift DEFINITION computed independently of pan.
// ---------------------------------------------------------------------------

/// The expected lane value at output index `n` of a plane, for a per-plane delay
/// of `len`, given that plane's input stream. This is the DEFINITION, hand derived
/// here, NOT pan's output: silence (the zero lane) for the first `len` outputs of
/// the plane, then that plane's input shifted back by `len`. Lane-generic so the
/// same oracle drives f32 and f64. Evaluated INDEPENDENTLY per channel against
/// that channel's own stream — which is exactly the per-plane-independence claim.
fn expectedPlaneTag(comptime Lane: type, plane_in: []const Lane, len: usize, n: usize) Lane {
    if (n < len) return 0.0; // the zero pre-roll (silence before the stream)
    return plane_in[n - len];
}

/// A deterministic, all-distinct tag for channel `c`, sample `i`. Channels are
/// offset by a large multiple of `i`'s span so NO tag value is shared between any
/// two channels at any index — a single cross-plane leak therefore changes a tag
/// and is caught. The `*1.25 - 7.0` shaping injects negatives and fractions so a
/// sign- or rounding-sensitive bug shows up too.
fn channelTag(c: usize, i: usize) f32 {
    const cc: f32 = @floatFromInt(c);
    const ii: f32 = @floatFromInt(i);
    return cc * 1000.0 + (ii * 1.25 - 7.0);
}

// ===========================================================================
// 1. The per-plane shift identity against the closed-form oracle (bit-exact),
//    generic over (Lane, layout, len). A small comptime-generic driver writes an
//    INDEPENDENT tag stream per channel, runs one whole-buffer planar render,
//    then asserts every output sample of every plane equals the hand-computed
//    per-plane zero-padded shift of THAT plane's own stream — so both the shift
//    identity and per-plane independence are proven at once.
// ===========================================================================

fn ShiftCheck(comptime Lane: type, comptime L: types.ChannelLayout) type {
    const C = L.count();
    return struct {
        /// Drive a whole-buffer delay-by-`len` over `N` frames and check the
        /// per-plane oracle bit-exactly. `N` must be <= cap so the stack buffers fit.
        fn run(comptime len: usize, comptime N: usize) !void {
            const cap = 64;
            comptime std.debug.assert(N <= cap);

            // Per-channel independent tag streams (host-side reference).
            var in_tags: [C][N]Lane = undefined;
            inline for (0..C) |c| {
                inline for (0..N) |i| in_tags[c][i] = @floatCast(channelTag(c, i));
            }

            // Plane-major backing for the typed views.
            var in_buf: [C * cap]Lane = undefined;
            var out_buf: [C * cap]Lane = undefined;
            inline for (0..C) |c| {
                inline for (0..N) |i| in_buf[c * N + i] = in_tags[c][i];
            }

            var dl = time.PlanarDelayLine(Lane, L, len){};
            const in = types.PlanarConst(Lane, L).fromBase(&in_buf, N);
            const out = types.Planar(Lane, L).fromBase(&out_buf, N);
            dl.process(in, out);

            // Every plane, every sample, against THAT plane's own oracle.
            inline for (0..C) |c| {
                const ys = out.plane(c);
                for (0..N) |n| {
                    const want = expectedPlaneTag(Lane, &in_tags[c], len, n);
                    try testing.expectEqual(want, ys[n]);
                }
            }
        }
    };
}

test "PlanarDelayLine realizes the per-plane shift out.plane(c)[n]=in.plane(c)[n-len] (stereo, f32)" {
    const Check = ShiftCheck(f32, .stereo);
    // N > len (the ordinary regime): every tail sample is that plane's input
    // shifted back; the two planes carry disjoint streams and must not bleed.
    try Check.run(2, 7);
    try Check.run(3, 10);
    try Check.run(1, 9);
    // N == len: output is pure pre-roll, the input has not yet emerged.
    try Check.run(4, 4);
    // N < len: still pure pre-roll (the stream is shorter than the delay).
    try Check.run(5, 3);
}

test "PlanarDelayLine is generic over .discrete(N) layouts of several channel counts" {
    // discrete(1) degenerates to a single plane (the mono-like case);
    // discrete(3) and discrete(8) exercise odd and larger plane-major sectioning.
    try ShiftCheck(f32, .{ .discrete = 1 }).run(2, 6);
    try ShiftCheck(f32, .{ .discrete = 3 }).run(3, 11);
    try ShiftCheck(f32, .{ .discrete = 8 }).run(4, 12);
}

test "PlanarDelayLine is generic over a larger layout (surround_5_1, 6 channels)" {
    // The 6-channel ring is [c0..][c1..]..[c5..], each `len` long. A wrong base
    // offset for any of the six planes would corrupt that plane's oracle.
    try ShiftCheck(f32, .surround_5_1).run(2, 8);
    try ShiftCheck(f32, .surround_5_1).run(64 % 16 + 1, 16); // len=1, longer stream
}

test "PlanarDelayLine is lane-generic over f64 (delay is lane-shape agnostic)" {
    try ShiftCheck(f64, .stereo).run(3, 9);
    try ShiftCheck(f64, .{ .discrete = 4 }).run(2, 10);
    try ShiftCheck(f64, .surround_5_1).run(1, 7);
}

test "PlanarDelayLine handles a realistic delay length with a longer stream" {
    // len=64 (a ~1.3ms delay @ 48k) over N=64: output is exactly pure pre-roll
    // (N == len), and at N just past it the first real frame would emerge. Run
    // both regimes across a multi-channel bus.
    try ShiftCheck(f32, .{ .discrete = 3 }).run(64, 64);
    try ShiftCheck(f32, .stereo).run(33, 64); // N=64 > len=33: the wrap regime
}

// ===========================================================================
// 2. Per-plane independence, stated and proven directly. Two channels are fed
//    the SAME-shaped stream but with a large constant channel offset; the output
//    of each plane must equal the shift of its OWN input. We also confirm that
//    perturbing only channel 1's input leaves channel 0's output bit-identical —
//    the sharpest statement of "distinct data in different channels never bleeds".
// ===========================================================================

test "distinct per-channel data never bleeds across planes (discrete 4)" {
    const L = types.ChannelLayout{ .discrete = 4 };
    const C = comptime L.count();
    const N = 9;
    const len = 3;

    var in_buf: [C * N]f32 = undefined;
    var out_buf: [C * N]f32 = undefined;
    for (0..C) |c| {
        for (0..N) |i| in_buf[c * N + i] = channelTag(c, i);
    }
    var dl = time.PlanarDelayLine(f32, L, len){};
    const in = types.PlanarConst(f32, L).fromBase(&in_buf, N);
    const out = types.Planar(f32, L).fromBase(&out_buf, N);
    dl.process(in, out);

    for (0..C) |c| {
        const ys = out.plane(c);
        for (0..N) |n| {
            const want = if (n < len) @as(f32, 0) else channelTag(c, n - len);
            try testing.expectEqual(want, ys[n]);
        }
    }
}

test "perturbing one channel's input leaves the other channels' outputs unchanged" {
    const L = types.ChannelLayout{ .discrete = 3 };
    const C = comptime L.count();
    const N = 8;
    const len = 2;

    // Baseline render.
    var base_in: [C * N]f32 = undefined;
    var base_out: [C * N]f32 = undefined;
    for (0..C) |c| for (0..N) |i| {
        base_in[c * N + i] = channelTag(c, i);
    };
    var dl0 = time.PlanarDelayLine(f32, L, len){};
    dl0.process(
        types.PlanarConst(f32, L).fromBase(&base_in, N),
        types.Planar(f32, L).fromBase(&base_out, N),
    );

    // Perturbed render: rewrite ONLY channel 1's plane to garbage.
    var pert_in: [C * N]f32 = base_in;
    var pert_out: [C * N]f32 = undefined;
    for (0..N) |i| pert_in[1 * N + i] = -777.0 * @as(f32, @floatFromInt(i + 1));
    var dl1 = time.PlanarDelayLine(f32, L, len){};
    dl1.process(
        types.PlanarConst(f32, L).fromBase(&pert_in, N),
        types.Planar(f32, L).fromBase(&pert_out, N),
    );

    // Channels 0 and 2 must be byte-identical between the two renders; only
    // channel 1's output may differ.
    const base_view = types.Planar(f32, L).fromBase(&base_out, N);
    const pert_view = types.Planar(f32, L).fromBase(&pert_out, N);
    for ([_]usize{ 0, 2 }) |c| {
        try testing.expectEqualSlices(f32, base_view.plane(c), pert_view.plane(c));
    }
    // And channel 1 genuinely DID change (otherwise the perturbation was inert
    // and the independence claim would be vacuous). Its post-roll reflects the
    // garbage shifted by len.
    try testing.expectEqual(@as(f32, -777.0 * 1.0), pert_view.plane(1)[len]);
}

// ===========================================================================
// 3. PlanarUnitDelay: exactly the per-plane one-sample z^-1, and the TYPE
//    identity PlanarDelayLine(Lane, L, 1).
// ===========================================================================

test "PlanarUnitDelay is exactly PlanarDelayLine(Lane,L,1) as a type identity" {
    try testing.expect(time.PlanarUnitDelay(f32, .stereo) ==
        time.PlanarDelayLine(f32, .stereo, 1));
    try testing.expect(time.PlanarUnitDelay(f64, .surround_5_1) ==
        time.PlanarDelayLine(f64, .surround_5_1, 1));
    // The root re-exports resolve to the same types.
    try testing.expect(pan.PlanarUnitDelay(f32, .{ .discrete = 4 }) ==
        pan.PlanarDelayLine(f32, .{ .discrete = 4 }, 1));
}

test "PlanarUnitDelay realizes out.plane(c)[n]=in.plane(c)[n-1] with a single zero pre-roll" {
    const L: types.ChannelLayout = .stereo;
    const C = comptime L.count();
    const N = 6;
    var in_buf: [C * N]f32 = undefined;
    var out_buf: [C * N]f32 = undefined;
    for (0..C) |c| for (0..N) |i| {
        in_buf[c * N + i] = channelTag(c, i);
    };
    var ud = time.PlanarUnitDelay(f32, L){};
    ud.process(
        types.PlanarConst(f32, L).fromBase(&in_buf, N),
        types.Planar(f32, L).fromBase(&out_buf, N),
    );
    const out = types.Planar(f32, L).fromBase(&out_buf, N);
    for (0..C) |c| {
        // out.plane(c)[0] is the lone pre-roll zero; thereafter in shifted by 1.
        try testing.expectEqual(@as(f32, 0), out.plane(c)[0]);
        for (1..N) |n| {
            try testing.expectEqual(channelTag(c, n - 1), out.plane(c)[n]);
        }
    }
}

// ===========================================================================
// 4. State carries across calls (the closed-form oracle, addressed by GLOBAL
//    index, per channel). A multi-call render must reproduce a single long
//    render's per-plane shift: history advances once per sample, not per call.
// ===========================================================================

test "PlanarDelayLine carries ring state across successive process() calls (per plane)" {
    const L = types.ChannelLayout{ .discrete = 2 };
    const C = comptime L.count();
    const len = 3;
    const total = 10;

    // The global per-channel input streams.
    var stream: [C][total]f32 = undefined;
    for (0..C) |c| for (0..total) |i| {
        stream[c][i] = channelTag(c, i);
    };

    var dl = time.PlanarDelayLine(f32, L, len){};
    const cuts = [_]usize{ 0, 4, 7, total }; // uneven chunks [0,4) [4,7) [7,10)
    var got: [C][total]f32 = undefined;

    for (0..cuts.len - 1) |k| {
        const lo = cuts[k];
        const hi = cuts[k + 1];
        const m = hi - lo;
        // Build a plane-major sub-block of `m` frames for this call.
        var sub_in: [C * total]f32 = undefined;
        var sub_out: [C * total]f32 = undefined;
        for (0..C) |c| {
            for (0..m) |j| sub_in[c * m + j] = stream[c][lo + j];
        }
        dl.process(
            types.PlanarConst(f32, L).fromBase(&sub_in, m),
            types.Planar(f32, L).fromBase(&sub_out, m),
        );
        const sub_view = types.Planar(f32, L).fromBase(&sub_out, m);
        for (0..C) |c| {
            for (0..m) |j| got[c][lo + j] = sub_view.plane(c)[j];
        }
    }

    // Compare against the SINGLE-render oracle addressed by global index.
    for (0..C) |c| {
        for (0..total) |n| {
            try testing.expectEqual(expectedPlaneTag(f32, &stream[c], len, n), got[c][n]);
        }
    }
}

// ===========================================================================
// 5. Sub-block granularity, pan-vs-pan, BIT-EXACT. The DEFINITION restated: a
//    render of [0,k) then [k,N) must leave the ring — cursor and per-plane
//    contents — in exactly the state a single render of [0,N) would, and emit a
//    byte-identical output. We compare pan against pan at the byte level over
//    EVERY cut point k (including k=0 and k=N), and at single-sample granularity.
// ===========================================================================

/// Bit-exact compare two plane-major flat buffers (pan-vs-pan); on divergence,
/// print to stderr (not the log facility) and fail. Bytes are compared so a
/// signed-zero or NaN-poisoned lane is treated as the distinct pattern it is.
fn expectBufBitEqual(comptime Lane: type, whole: []const Lane, split: []const Lane) !void {
    if (whole.len != split.len) return error.LengthMismatch;
    const wb = std.mem.sliceAsBytes(whole);
    const sb = std.mem.sliceAsBytes(split);
    if (!std.mem.eql(u8, wb, sb)) {
        // Locate the first differing element for a useful diagnostic.
        for (whole, split, 0..) |w, s, i| {
            if (std.mem.asBytes(&w).len != std.mem.asBytes(&s).len or
                !std.mem.eql(u8, std.mem.asBytes(&w), std.mem.asBytes(&s)))
            {
                std.debug.print(
                    "pan-vs-pan planar delay divergence at lane {d}: whole vs split bytes differ\n",
                    .{i},
                );
                break;
            }
        }
        return error.PanDivergence;
    }
}

/// For a given `(Lane, L, len, N)`, assert that splitting the render at EVERY cut
/// k in 0..=N reproduces, byte-for-byte, the single whole render — and that the
/// rings end in the same state (probed by a follow-up render on both rings).
fn assertSplitEqualsWhole(
    comptime Lane: type,
    comptime L: types.ChannelLayout,
    comptime len: usize,
    comptime N: usize,
) !void {
    const C = comptime L.count();

    // Distinct per-channel input (plane-major).
    var in_buf: [C * N]Lane = undefined;
    inline for (0..C) |c| {
        inline for (0..N) |i| in_buf[c * N + i] = @floatCast(channelTag(c, i));
    }
    const in = types.PlanarConst(Lane, L).fromBase(&in_buf, N);

    // Reference: one whole-buffer render.
    var dl_whole = time.PlanarDelayLine(Lane, L, len){};
    var out_whole: [C * N]Lane = undefined;
    dl_whole.process(in, types.Planar(Lane, L).fromBase(&out_whole, N));

    // A second, fresh follow-up stream used to pin terminal ring state.
    var follow_buf: [C * N]Lane = undefined;
    inline for (0..C) |c| {
        inline for (0..N) |i| follow_buf[c * N + i] = @floatCast(channelTag(c, i) * 0.5 + 3.0);
    }
    const follow_in = types.PlanarConst(Lane, L).fromBase(&follow_buf, N);

    // The whole-ring's follow-up output (the terminal-state fingerprint).
    var dl_whole2 = time.PlanarDelayLine(Lane, L, len){};
    var scratch: [C * N]Lane = undefined;
    dl_whole2.process(in, types.Planar(Lane, L).fromBase(&scratch, N)); // re-establish state
    var follow_whole: [C * N]Lane = undefined;
    dl_whole2.process(follow_in, types.Planar(Lane, L).fromBase(&follow_whole, N));

    inline for (0..N + 1) |k| {
        // Split render: [0,k) then [k,N). Each call needs its own plane-major
        // sub-buffer because planes are NOT contiguous across a frame-count split.
        var dl = time.PlanarDelayLine(Lane, L, len){};
        var out_split: [C * N]Lane = undefined;

        renderSub(Lane, L, len, &dl, &in_buf, N, 0, k, &out_split);
        renderSub(Lane, L, len, &dl, &in_buf, N, k, N, &out_split);

        try expectBufBitEqual(Lane, &out_whole, &out_split);

        // Terminal ring-state pin: feed the SAME follow-up stream to the
        // split-rendered ring; identical output ⇒ same terminal state.
        var follow_split: [C * N]Lane = undefined;
        dl.process(follow_in, types.Planar(Lane, L).fromBase(&follow_split, N));
        try expectBufBitEqual(Lane, &follow_whole, &follow_split);
    }
}

/// Render the frame sub-range [lo,hi) of the plane-major buffer `src` (of `N`
/// frames) through `dl`, writing results into the same frame range of the
/// plane-major destination `dst`. Repacks because a plane-major slice of frames
/// [lo,hi) is not contiguous in the full-N buffer.
fn renderSub(
    comptime Lane: type,
    comptime L: types.ChannelLayout,
    comptime len: usize,
    dl: *time.PlanarDelayLine(Lane, L, len),
    src: []const Lane,
    comptime N: usize,
    lo: usize,
    hi: usize,
    dst: []Lane,
) void {
    const C = comptime L.count();
    const m = hi - lo;
    var sub_in: [C * N]Lane = undefined;
    var sub_out: [C * N]Lane = undefined;
    for (0..C) |c| {
        for (0..m) |j| sub_in[c * m + j] = src[c * N + (lo + j)];
    }
    dl.process(
        types.PlanarConst(Lane, L).fromBase(&sub_in, m),
        types.Planar(Lane, L).fromBase(&sub_out, m),
    );
    const sub_view = types.Planar(Lane, L).fromBase(&sub_out, m);
    const dst_view = types.Planar(Lane, L).fromBase(dst.ptr, N);
    for (0..C) |c| {
        for (0..m) |j| dst_view.plane(c)[lo + j] = sub_view.plane(c)[j];
    }
}

test "split-render equals whole-render bit-exact at every cut (stereo, len=1)" {
    try assertSplitEqualsWhole(f32, .stereo, 1, 9);
}

test "split-render equals whole-render bit-exact at every cut (stereo, len=4 wrap)" {
    // len < N, so each plane's ring wraps mid-stream: the wrap must land
    // identically whether or not a call boundary falls inside it.
    try assertSplitEqualsWhole(f32, .stereo, 4, 11);
}

test "split-render equals whole-render bit-exact at every cut (discrete4, len=N pre-roll)" {
    // len == N: the whole render is pure pre-roll; the split must be too.
    try assertSplitEqualsWhole(f32, .{ .discrete = 4 }, 8, 8);
}

test "split-render equals whole-render bit-exact at every cut (surround_5_1, len=3)" {
    try assertSplitEqualsWhole(f32, .surround_5_1, 3, 10);
}

test "split-render equals whole-render bit-exact at every cut (f64 stereo, len=2)" {
    try assertSplitEqualsWhole(f64, .stereo, 2, 9);
}

test "single-sample-hop render equals whole-render bit-exact (history per sample, surround_5_1)" {
    // The finest granularity: N one-sample planar renders must equal one
    // N-sample render. The sharpest form of "history advances once per sample
    // consumed, never once per render call", across a 6-channel bus.
    const L: types.ChannelLayout = .surround_5_1;
    const C = comptime L.count();
    const len = 5;
    const N = 20;

    var in_buf: [C * N]f32 = undefined;
    for (0..C) |c| for (0..N) |i| {
        in_buf[c * N + i] = channelTag(c, i);
    };

    var dl_whole = time.PlanarDelayLine(f32, L, len){};
    var out_whole: [C * N]f32 = undefined;
    dl_whole.process(
        types.PlanarConst(f32, L).fromBase(&in_buf, N),
        types.Planar(f32, L).fromBase(&out_whole, N),
    );

    var dl_hop = time.PlanarDelayLine(f32, L, len){};
    var out_hop: [C * N]f32 = undefined;
    const out_hop_view = types.Planar(f32, L).fromBase(&out_hop, N);
    for (0..N) |i| {
        // One frame across all channels: a plane-major [C*1] block.
        var one_in: [C]f32 = undefined;
        var one_out: [C]f32 = undefined;
        for (0..C) |c| one_in[c] = in_buf[c * N + i];
        dl_hop.process(
            types.PlanarConst(f32, L).fromBase(&one_in, 1),
            types.Planar(f32, L).fromBase(&one_out, 1),
        );
        const one_view = types.Planar(f32, L).fromBase(&one_out, 1);
        for (0..C) |c| out_hop_view.plane(c)[i] = one_view.plane(c)[0];
    }

    try expectBufBitEqual(f32, &out_whole, &out_hop);
}

// ===========================================================================
// 6. Edge cases: empty render is an inert no-op on the shared cursor and the
//    whole ring, and the subsequent stream still emerges correctly.
// ===========================================================================

test "an empty planar render is a no-op leaving the ring and cursor untouched" {
    const L: types.ChannelLayout = .stereo;
    const C = comptime L.count();
    const len = 3;
    var dl = time.PlanarDelayLine(f32, L, len){};

    // Prime the ring with two frames so the cursor sits at a non-zero position.
    var prime_in: [C * 2]f32 = .{ 7, 8, 70, 80 }; // [L0,L1][R0,R1]
    var prime_out: [C * 2]f32 = undefined;
    dl.process(
        types.PlanarConst(f32, L).fromBase(&prime_in, 2),
        types.Planar(f32, L).fromBase(&prime_out, 2),
    );
    const pos_before = dl.pos;
    const ring_before = dl.ring;

    // An empty render: zero frames. The view's base is still valid; frames == 0.
    var empty_in: [C * 0]f32 = undefined;
    var empty_out: [C * 0]f32 = undefined;
    dl.process(
        types.PlanarConst(f32, L).fromBase(&empty_in, 0),
        types.Planar(f32, L).fromBase(&empty_out, 0),
    );

    try testing.expectEqual(pos_before, dl.pos); // cursor did not move
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&ring_before),
        std.mem.asBytes(&dl.ring),
    ); // ring bytes unchanged

    // The subsequent stream still emerges correctly (the empty render was inert).
    // Global per-channel streams: L = 7,8,9,10,11 ; R = 70,80,90,100,110.
    var after_in: [C * 3]f32 = .{ 9, 10, 11, 90, 100, 110 };
    var after_out: [C * 3]f32 = undefined;
    dl.process(
        types.PlanarConst(f32, L).fromBase(&after_in, 3),
        types.Planar(f32, L).fromBase(&after_out, 3),
    );
    const out = types.Planar(f32, L).fromBase(&after_out, 3);
    const stream_l = [_]f32{ 7, 8, 9, 10, 11 };
    const stream_r = [_]f32{ 70, 80, 90, 100, 110 };
    // At global n = 2,3,4 with len=3 ⇒ out = 0, stream[0], stream[1].
    inline for (0..3) |j| {
        const n = j + 2;
        try testing.expectEqual(expectedPlaneTag(f32, &stream_l, len, n), out.plane(0)[j]);
        try testing.expectEqual(expectedPlaneTag(f32, &stream_r, len, n), out.plane(1)[j]);
    }
}

// ===========================================================================
// 7. The pre-roll is the byte-exact zero lane (silence before the stream): the
//    first `len` samples of EVERY plane equal the family zero, and the (len)-th
//    sample of each plane is the first real input of that plane shifted in.
// ===========================================================================

test "the per-plane pre-roll is the byte-exact zero lane (multiple layouts)" {
    const layouts = [_]types.ChannelLayout{
        .stereo,
        .{ .discrete = 3 },
        .surround_5_1,
    };
    inline for (layouts) |L| {
        const C = comptime L.count();
        const len = 2;
        const N = 3;
        var in_buf: [C * N]f32 = undefined;
        inline for (0..C) |c| {
            inline for (0..N) |i| in_buf[c * N + i] = channelTag(c, i) + 1.0; // never 0
        }
        var dl = time.PlanarDelayLine(f32, L, len){};
        var out_buf: [C * N]f32 = undefined;
        dl.process(
            types.PlanarConst(f32, L).fromBase(&in_buf, N),
            types.Planar(f32, L).fromBase(&out_buf, N),
        );
        const out = types.Planar(f32, L).fromBase(&out_buf, N);
        const zero: f32 = std.mem.zeroes(f32);
        inline for (0..C) |c| {
            // First `len` samples of every plane are the byte-exact zero lane.
            inline for (0..len) |n| {
                try testing.expectEqualSlices(
                    u8,
                    std.mem.asBytes(&zero),
                    std.mem.asBytes(&out.plane(c)[n]),
                );
            }
            // Sample `len` is this plane's first real input shifted in.
            try testing.expectEqual(in_buf[c * N + 0], out.plane(c)[len]);
        }
    }
}

// ===========================================================================
// 8. Classification & declared markers: the structural facts the commit pass and
//    port machinery key on for the multi-channel delay.
// ===========================================================================

test "PlanarDelayLine declares delay_len equal to its comptime length (across layouts/lanes)" {
    try testing.expect(@hasDecl(time.PlanarDelayLine(f32, .stereo, 1), "delay_len"));
    try testing.expect(@hasDecl(time.PlanarDelayLine(f32, .surround_5_1, 480), "delay_len"));
    try testing.expectEqual(@as(usize, 1), time.PlanarDelayLine(f32, .stereo, 1).delay_len);
    try testing.expectEqual(@as(usize, 480), time.PlanarDelayLine(f32, .surround_5_1, 480).delay_len);
    // The marker is independent of channel count and lane type.
    try testing.expectEqual(@as(usize, 64), time.PlanarDelayLine(f64, .{ .discrete = 7 }, 64).delay_len);
    // PlanarUnitDelay inherits delay_len == 1.
    try testing.expectEqual(@as(usize, 1), time.PlanarUnitDelay(f32, .stereo).delay_len);
}

test "PlanarDelayLine declares state_size as the cursor word (one shared cursor)" {
    // state_size is the per-block state BEYOND the ring: just the usize cursor,
    // shared across all planes — it does NOT scale with channel count.
    try testing.expectEqual(@sizeOf(usize), time.PlanarDelayLine(f32, .stereo, 7).state_size);
    try testing.expectEqual(@sizeOf(usize), time.PlanarDelayLine(f32, .surround_5_1, 7).state_size);
    try testing.expectEqual(@sizeOf(usize), time.PlanarUnitDelay(f64, .{ .discrete = 4 }).state_size);
}

test "PlanarDelayLine classifies as a Map (rate-1:1, no rate decls)" {
    try testing.expect(port.classify(time.PlanarDelayLine(f32, .stereo, 8)) == .Map);
    try testing.expect(port.classify(time.PlanarUnitDelay(f32, .surround_5_1)) == .Map);
    try testing.expect(port.classify(time.PlanarDelayLine(f64, .{ .discrete = 6 }, 16)) == .Map);
}

test "PlanarDelayLine is not a Source (it has a planar sample input port)" {
    // process(self, in: PlanarConst, out: Planar) has a non-empty input side, so
    // it is a transformer, not a generator.
    try testing.expect(!comptime port.isSource(time.PlanarDelayLine(f32, .stereo, 4)));
    try testing.expect(!comptime port.isSource(time.PlanarUnitDelay(f32, .surround_5_1)));
}

test "PlanarDelayLine output port element identity is the multi-channel Frame" {
    // The planar view's layout-identity element (what connect/PortId checks) is
    // Frame(Lane, L) — carrying the channel count, positional tags, and order.
    const PD = time.PlanarDelayLine(f32, .{ .discrete = 4 }, 64);
    try testing.expect(port.MapOutPort(PD).Elem == types.Frame(f32, .{ .discrete = 4 }));
    try testing.expect(port.MapOutPort(PD).direction == .out);

    const PS = time.PlanarDelayLine(f32, .surround_5_1, 12);
    try testing.expect(port.MapOutPort(PS).Elem == types.Frame(f32, .surround_5_1));
    // And the input port carries the same Frame identity (in and out same layout).
    try testing.expect(port.MapInPort(PS).Elem == types.Frame(f32, .surround_5_1));
    try testing.expect(port.MapInPort(PS).direction == .in);
}
