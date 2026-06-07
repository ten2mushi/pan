//! Element-generic delay primitives — `UnitDelay` and `DelayLine`.
//!
//! A delay is the one piece of state a feedback loop is built on: a cycle is
//! causal only if it contains a delay, because this block's output may then
//! depend solely on a *previous* block's looped value (the delay-free-loop rule).
//! These blocks declare `delay_len` (their persistent ring length), which marks
//! them as **delay elements** so the commit pass's SCC-has-delay check accepts a
//! feedback cycle that contains one.
//!
//! They are `Map` morphisms (rate-1:1, `out.len == in.len`) and **element-generic**
//! over any single-plane element type — `Sample(T)` (mono audio), `Complex(T)`
//! (spectral / phase-vocoder feedback), `FeatureFrame`, `Scalar(T)` — so the same
//! ring works for a reverb tail, a spectral-flux history, or a control z⁻¹.
//!
//! A multi-channel `Frame(Lane, L)` with `C := L.count() > 1` cannot ride a plain
//! `[]Frame` slice (a multi-channel sample buffer is enforced PLANAR — `C`
//! plane-major channel planes — so an array-of-structs port is a compile error,
//! see `port.portOfParam`). Its delay is therefore the planar variant
//! `PlanarDelayLine(Lane, L, len)` / `PlanarUnitDelay(Lane, L)` below: a
//! `process(in: PlanarConst, out: Planar)` that delays each channel plane through
//! its own ring section, so an FDN's vector feedback edge — `Frame(Lane,.discrete(N))`
//! — and a true stereo/surround delay are covered by the same primitive. Together
//! the single-plane `DelayLine` and the planar `PlanarDelayLine` cover all four
//! canonical element families (`Sample`/`Frame`/`Complex`/`FeatureFrame`).
//!
//! **Where the ring lives.** The ring is the block instance's own field, allocated
//! once at construction (`initialize`) — the persistent, pool-excluded category:
//! its live range spans every callback, so it is never colored and never zeroed
//! mid-stream. The commit pass counts it (`delay_len · @sizeOf(elem)`) in the H2
//! footprint figure but it does NOT sit in the executor's scratch pool.
//!
//! **State-update granularity.** The ring advances once per sample consumed,
//! regardless of how a callback is split into sub-blocks — a render of `[0,k)`
//! then `[k,N)` leaves the ring in exactly the state a single render of `[0,N)`
//! would (the cursor and contents carry across calls), so history updates once per
//! hop, never once per render call.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;

/// `DelayLine(Elem, len)` — a pure `len`-sample delay: `out[n] = in[n − len]`,
/// with the first `len` outputs drawn from the zero-initialized ring (silence
/// before the stream began). Implemented as a circular buffer whose read and
/// write cursor coincide: the slot about to be overwritten holds the sample
/// written `len` iterations ago, which is exactly `in[n − len]`.
pub fn DelayLine(comptime Elem: type, comptime len: usize) type {
    if (len == 0) @compileError("pan: DelayLine length must be >= 1 (use a wire for a zero delay)");
    return struct {
        const Self = @This();

        /// The persistent ring length, in elements. Declaring this marks the block
        /// as a delay element (the SCC-has-delay check looks for it) and sizes the
        /// footprint's persistent term.
        pub const delay_len: usize = len;
        /// The per-block state beyond the ring: just the write cursor.
        pub const state_size: usize = @sizeOf(usize);

        /// The delay ring, zero-filled at construction (silence before the stream).
        ring: [len]Elem = @splat(std.mem.zeroes(Elem)),
        /// The circular read/write cursor.
        pos: usize = 0,

        pub fn process(self: *Self, in: []const Elem, out: []Elem) void {
            var p = self.pos;
            for (in, out) |x, *y| {
                y.* = self.ring[p]; // the sample written `len` ago = in[n-len]
                self.ring[p] = x; // overwrite the oldest slot with the newest in
                p += 1;
                if (p == len) p = 0;
            }
            self.pos = p;
        }
    };
}

/// `UnitDelay(Elem)` — the one-sample `z⁻¹`: `out[n] = in[n − 1]`. The smallest
/// delay element, and the canonical building block of a sample-accurate feedback
/// loop. It is exactly `DelayLine(Elem, 1)`.
pub fn UnitDelay(comptime Elem: type) type {
    return DelayLine(Elem, 1);
}

/// `PlanarDelayLine(Lane, L, len)` — the multi-channel `DelayLine`: a pure
/// `len`-sample delay applied **independently per channel plane** of a planar
/// `Frame(Lane, L)` stream. `out.plane(c)[n] = in.plane(c)[n − len]` for every
/// channel `c ∈ 0..C` (`C := L.count()`), with the first `len` outputs of each
/// plane drawn from its zero-initialized ring section.
///
/// The ring is one contiguous `[C·len]Lane` block, plane-major (channel `c`'s ring
/// occupies `ring[c*len .. (c+1)*len]`), mirroring the plane-major buffer the
/// executor hands the block. Every plane shares one circular cursor because all
/// planes advance by the same `N` samples each call, so the cursor after a render
/// of `[0,N)` is exactly where a render split into sub-blocks would leave it (the
/// per-hop S6 granularity, per channel).
///
/// `delay_len`/`state_size` are declared exactly as for the scalar `DelayLine`, so
/// it classifies as a delay element (the SCC-has-delay check accepts a feedback
/// cycle through it) and the footprint counts its `C·len·@sizeOf(Lane)` ring via
/// `delay_len · out_elem_size` (`out_elem_size = @sizeOf(Frame(Lane,L)) =
/// C·@sizeOf(Lane)`).
pub fn PlanarDelayLine(comptime Lane: type, comptime L: types.ChannelLayout, comptime len: usize) type {
    if (len == 0) @compileError("pan: PlanarDelayLine length must be >= 1 (use a wire for a zero delay)");
    const C = L.count();
    return struct {
        const Self = @This();

        /// The per-plane ring length, in samples. Declaring this marks the block as
        /// a delay element and sizes the footprint's persistent term (per channel).
        pub const delay_len: usize = len;
        /// Per-block state beyond the ring: the shared write cursor.
        pub const state_size: usize = @sizeOf(usize);

        /// `C` plane-major ring sections, each `len` samples, zero-filled at
        /// construction (silence before the stream began).
        ring: [C * len]Lane = @splat(std.mem.zeroes(Lane)),
        /// The circular read/write cursor, shared across planes.
        pos: usize = 0,

        pub fn process(self: *Self, in: types.PlanarConst(Lane, L), out: types.Planar(Lane, L)) void {
            // Every plane advances by the same N samples from the same starting
            // cursor, so they all end at the same `pos`; compute it once.
            var final_pos: usize = self.pos;
            inline for (0..C) |c| {
                const xs = in.plane(c);
                const ys = out.plane(c);
                const base = c * len;
                var p = self.pos;
                for (xs, ys) |x, *y| {
                    y.* = self.ring[base + p]; // the sample written `len` ago = in[n-len]
                    self.ring[base + p] = x; // overwrite the oldest slot in this plane
                    p += 1;
                    if (p == len) p = 0;
                }
                final_pos = p;
            }
            self.pos = final_pos;
        }
    };
}

/// `PlanarUnitDelay(Lane, L)` — the multi-channel one-sample `z⁻¹`, exactly
/// `PlanarDelayLine(Lane, L, 1)`: each channel plane delayed by one sample.
pub fn PlanarUnitDelay(comptime Lane: type, comptime L: types.ChannelLayout) type {
    return PlanarDelayLine(Lane, L, 1);
}

// ---------------------------------------------------------------------------
// Tests — behaviour is checked here only for compile-coverage of the generic
// over a couple of element types; the autonomous Yoneda suite owns the full
// matrix (all four element types, sub-block granularity, feedback assembly).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "DelayLine(Sample(f32), 2) delays by exactly two samples" {
    const E = types.Sample(f32);
    var dl = DelayLine(E, 2){};
    var in: [5]E = .{ .{ .ch = .{1} }, .{ .ch = .{2} }, .{ .ch = .{3} }, .{ .ch = .{4} }, .{ .ch = .{5} } };
    var out: [5]E = undefined;
    dl.process(&in, &out);
    // First two outputs are the zero pre-roll; then the input shifted by 2.
    const want = [_]f32{ 0, 0, 1, 2, 3 };
    for (out, want) |y, w| try testing.expectEqual(w, y.ch[0]);
}

test "UnitDelay is a one-sample z^-1 and carries state across calls" {
    const E = types.Sample(f32);
    var ud = UnitDelay(E){};
    var in1: [3]E = .{ .{ .ch = .{10} }, .{ .ch = .{20} }, .{ .ch = .{30} } };
    var out1: [3]E = undefined;
    ud.process(&in1, &out1);
    try testing.expectEqual(@as(f32, 0), out1[0].ch[0]); // pre-roll
    try testing.expectEqual(@as(f32, 10), out1[1].ch[0]);
    try testing.expectEqual(@as(f32, 20), out1[2].ch[0]);
    // The 30 written last call emerges first on the next call (state carried).
    var in2: [2]E = .{ .{ .ch = .{40} }, .{ .ch = .{50} } };
    var out2: [2]E = undefined;
    ud.process(&in2, &out2);
    try testing.expectEqual(@as(f32, 30), out2[0].ch[0]);
    try testing.expectEqual(@as(f32, 40), out2[1].ch[0]);
}

test "DelayLine is element-generic over Complex" {
    const C = types.Complex(f32);
    var dl = DelayLine(C, 1){};
    var in: [2]C = .{ .{ .z = .{ .re = 1, .im = 2 } }, .{ .z = .{ .re = 3, .im = 4 } } };
    var out: [2]C = undefined;
    dl.process(&in, &out);
    try testing.expectEqual(@as(f32, 0), out[0].z.re); // zero pre-roll
    try testing.expectEqual(@as(f32, 1), out[1].z.re);
    try testing.expectEqual(@as(f32, 2), out[1].z.im);
}

test "DelayLine declares delay_len so it classifies as a delay element" {
    const E = types.Sample(f32);
    try testing.expect(@hasDecl(DelayLine(E, 480), "delay_len"));
    try testing.expectEqual(@as(usize, 480), DelayLine(E, 480).delay_len);
}

test "PlanarDelayLine delays each channel plane independently by len" {
    // A 2-channel discrete bus, delayed by 2 samples per plane. The two planes
    // carry distinct data, proving they do not bleed into each other.
    var dl = PlanarDelayLine(f32, .{ .discrete = 2 }, 2){};
    // Plane-major backing: [ch0_0..ch0_2][ch1_0..ch1_2].
    var in_buf: [6]f32 = .{ 1, 2, 3, 10, 20, 30 };
    var out_buf: [6]f32 = undefined;
    const in = types.PlanarConst(f32, .{ .discrete = 2 }).fromBase(&in_buf, 3);
    const out = types.Planar(f32, .{ .discrete = 2 }).fromBase(&out_buf, 3);
    dl.process(in, out);
    // Each plane: two zero pre-roll samples, then the input shifted by 2.
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1 }, out.plane(0));
    try testing.expectEqualSlices(f32, &.{ 0, 0, 10 }, out.plane(1));
}

test "PlanarUnitDelay is a one-sample z^-1 over stereo and carries state across calls" {
    var ud = PlanarUnitDelay(f32, .stereo){};
    var in_buf: [4]f32 = .{ 5, 6, 50, 60 }; // [L0,L1][R0,R1]
    var out_buf: [4]f32 = undefined;
    const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 2);
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, 2);
    ud.process(in, out);
    try testing.expectEqualSlices(f32, &.{ 0, 5 }, out.plane(0)); // pre-roll then L0
    try testing.expectEqualSlices(f32, &.{ 0, 50 }, out.plane(1));
    // The last sample of each plane emerges first on the next call (state carried).
    var in2_buf: [4]f32 = .{ 7, 8, 70, 80 };
    var out2_buf: [4]f32 = undefined;
    const in2 = types.PlanarConst(f32, .stereo).fromBase(&in2_buf, 2);
    const out2 = types.Planar(f32, .stereo).fromBase(&out2_buf, 2);
    ud.process(in2, out2);
    try testing.expectEqualSlices(f32, &.{ 6, 7 }, out2.plane(0));
    try testing.expectEqualSlices(f32, &.{ 60, 70 }, out2.plane(1));
}

test "PlanarDelayLine declares delay_len and classifies as a delay element Map" {
    const port = core.port;
    const PD = PlanarDelayLine(f32, .{ .discrete = 4 }, 64);
    try testing.expect(port.classify(PD) == .Map);
    try testing.expect(@hasDecl(PD, "delay_len"));
    try testing.expectEqual(@as(usize, 64), PD.delay_len);
    // Its output element identity is the multi-channel Frame (planar view).
    try testing.expect(port.MapOutPort(PD).Elem == types.Frame(f32, .{ .discrete = 4 }));
}
