//! planar_conformance_test — the P-2 conformance gate (catalog §9.3).
//!
//! The internal channel form is LOCKED PLANAR and STRICTLY ENFORCED: a
//! multi-channel stream buffer of `N` frames on layout `L` (count `C`) is stored
//! as `C` contiguous `N`-sample channel PLANES, plane-major
//! (`[ch0_0…ch0_{N-1}][ch1_0…ch1_{N-1}]…`), and a block accesses each channel as
//! its own contiguous `[]Lane` plane. This harness is the gate that makes an
//! array-of-structs (interleaved) regression fail LOUD: it asserts, at comptime
//! and at runtime, that the planar buffer/port view exists, that its planes are
//! plane-major over the same byte footprint an interleaved buffer would occupy,
//! and that the real multi-channel block (`ConstantPowerPan`) writes plane-major.
//!
//! These assertions are against INDEPENDENT structural truth (sizes, byte
//! offsets, the analytic pan gains) — never against pan's own output for the
//! layout claim. The one pan-vs-oracle numeric check uses the f64 analytic gains.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring.
//! Reject-path diagnostics (none here) would go to stderr via std.debug.print.

const std = @import("std");
const pan = @import("pan");

const types = pan.types;
const Frame = pan.Frame;
const Sample = pan.Sample;
const Planar = pan.Planar;
const PlanarConst = pan.PlanarConst;

// ===========================================================================
// 1. The planar view EXISTS and is recognized by the port machinery.
//    Without a planar view the whole enforcement is vacuous, so pin it first.
// ===========================================================================

test "a planar view type exists and is recognized; a Frame/slice is not a view (catalog §9.3 P-2)" {
    try std.testing.expect(pan.isPlanarView(Planar(f32, .stereo)));
    try std.testing.expect(pan.isPlanarView(PlanarConst(f32, .stereo)));
    try std.testing.expect(pan.isPlanarView(Planar(f32, .surround_5_1)));
    try std.testing.expect(pan.isPlanarView(Planar(i16, .stereo)));
    // The element-identity Frame is NOT a buffer view (it is one frame value).
    try std.testing.expect(!pan.isPlanarView(Frame(f32, .stereo)));
    try std.testing.expect(!pan.isPlanarView(Sample(f32)));
    // A bare slice is not a view either.
    try std.testing.expect(!pan.isPlanarView([]Frame(f32, .stereo)));
}

// ===========================================================================
// 2. The view exposes PER-CHANNEL []Lane planes (not interleaved frames).
//    The defining access shape: plane(c) is a contiguous run of N lanes.
// ===========================================================================

test "the view exposes C contiguous []Lane planes; channel access is per-plane (catalog §9.3 P-1)" {
    const V = Planar(f32, .stereo);
    try std.testing.expectEqual(@as(usize, 2), V.channel_count);
    // plane(c) returns a []f32 / []const f32 — a whole channel, contiguous.
    const PlaneT = @TypeOf(@as(V, undefined).plane(0));
    try std.testing.expect(PlaneT == []f32);
    const CV = PlanarConst(f32, .stereo);
    const CPlaneT = @TypeOf(@as(CV, undefined).plane(0));
    try std.testing.expect(CPlaneT == []const f32);
    // A 6.1-style layout exposes its full channel count as planes.
    try std.testing.expectEqual(@as(usize, 6), Planar(f32, .surround_5_1).channel_count);
}

// ===========================================================================
// 3. PLANE-MAJOR byte layout: a buffer of N frames is [plane0][plane1]…, so
//    plane c begins at lane offset c·N (NOT interleaved c at every C-th lane).
//    This is the assertion an AoS regression fails: were the buffer interleaved,
//    plane(1)[0] would be backing lane 1, not backing lane N.
// ===========================================================================

test "buffer is plane-major: plane c starts at lane offset c·N, the planes do not interleave" {
    const N = 4;
    // Backing lanes [0,1,2,3, 100,101,102,103] = L-plane then R-plane.
    var backing: [2 * N]f32 = .{ 0, 1, 2, 3, 100, 101, 102, 103 };
    const v = Planar(f32, .stereo).fromBase(&backing, N);

    const l = v.plane(0);
    const r = v.plane(1);
    // L-plane is the FIRST N lanes; R-plane is the NEXT N lanes (plane-major).
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 2, 3 }, l);
    try std.testing.expectEqualSlices(f32, &.{ 100, 101, 102, 103 }, r);

    // The two planes are disjoint contiguous runs: &r[0] is N lanes past &l[0].
    // (An interleaved AoS buffer would instead have r[0] one lane past l[0].)
    const l0: [*]const f32 = l.ptr;
    const r0: [*]const f32 = r.ptr;
    try std.testing.expectEqual(@intFromPtr(l0 + N), @intFromPtr(r0));
}

// ===========================================================================
// 4. LAYOUT-AGNOSTIC footprint: a planar stereo buffer occupies exactly the same
//    C·N·sizeof(Lane) bytes an interleaved one would — only the arrangement
//    differs. This is why the commit pass needs no change; pin it here so a size
//    drift surfaces.
// ===========================================================================

test "planar footprint == C·N·sizeof(Lane) == the interleaved AoS footprint (layout-agnostic)" {
    const N = 256;
    const C = 2;
    const planar_bytes = C * N * @sizeOf(f32);
    const aos_bytes = N * @sizeOf(Frame(f32, .stereo)); // N interleaved stereo frames
    try std.testing.expectEqual(planar_bytes, aos_bytes);
    // And the element identity used for the pool class key is the Frame, whose
    // size is C·sizeof(Lane) — independent of planar vs interleaved arrangement.
    try std.testing.expectEqual(@as(usize, C * @sizeOf(f32)), @sizeOf(Frame(f32, .stereo)));
    try std.testing.expectEqual(@as(usize, C * @sizeOf(i16)), @sizeOf(Frame(i16, .stereo)));
}

// ===========================================================================
// 5. The element IDENTITY is preserved: the view's `Elem` is `Frame(Lane,L)`,
//    so `connect`/PortId type-checking (count + positional tags + canonical
//    order in L) is unchanged by the layout switch.
// ===========================================================================

test "the planar view's element identity is Frame(Lane,L) — connect type-checking is unchanged" {
    try std.testing.expect(Planar(f32, .stereo).Elem == Frame(f32, .stereo));
    try std.testing.expect(PlanarConst(f32, .stereo).Elem == Frame(f32, .stereo));
    try std.testing.expect(Planar(i16, .stereo).Elem == Frame(i16, .stereo));
    // The output port the real pan block mints carries the Frame identity even
    // though the buffer is written through the planar view.
    const Pan = pan.spatial.ConstantPowerPan(pan.numericFor(.f32, .{}));
    try std.testing.expect(pan.port.MapOutPort(Pan).Elem == Frame(f32, .stereo));
}

// ===========================================================================
// 6. The REAL multi-channel block writes PLANE-MAJOR. End-to-end proof that the
//    enforcement holds for an actual block, not just the view in isolation:
//    ConstantPowerPan's stereo output, read as a plane-major buffer, matches the
//    f64 analytic constant-power gains in the L-plane and R-plane separately.
// ===========================================================================

test "ConstantPowerPan writes a plane-major stereo buffer (L-plane then R-plane)" {
    const Pan = pan.spatial.ConstantPowerPan(pan.numericFor(.f32, .{}));
    const N = 8;
    const pos: f32 = 0.37; // off-center so L ≠ R — a channel swap would be caught
    var in: [N]Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @as(f32, @floatFromInt(i)) * 0.1 - 0.3;

    var backing: [2 * N]f32 = undefined;
    const out = Planar(f32, .stereo).fromBase(&backing, N);
    var blk = Pan{ .pan = pos };
    blk.process(&in, out);

    // Independent f64 analytic oracle for the constant-power gains.
    const theta = (std.math.clamp(@as(f64, pos), -1.0, 1.0) + 1.0) * (std.math.pi / 4.0);
    const lg: f64 = @cos(theta);
    const rg: f64 = @sin(theta);

    // The L-plane (first N backing lanes) holds x·cos θ; the R-plane (next N)
    // holds x·sin θ. If the block had written interleaved AoS, backing[1] would
    // be R0 (≈ x0·sin θ) instead of L1 (≈ x1·cos θ) — this catches that.
    const lplane = out.plane(0);
    const rplane = out.plane(1);
    try std.testing.expectEqual(@intFromPtr(&backing[0]), @intFromPtr(lplane.ptr));
    try std.testing.expectEqual(@intFromPtr(&backing[N]), @intFromPtr(rplane.ptr));
    for (in, lplane, rplane) |x, l, r| {
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(@as(f64, x.ch[0]) * lg)), l, 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(@as(f64, x.ch[0]) * rg)), r, 1e-6);
    }
}

// ===========================================================================
// 7. The codec transposes at the boundary ONLY: interleaved device bytes ↔
//    planar internal buffer. Round-trip is the identity on the bytes (bit-exact),
//    and the intermediate planar buffer is genuinely plane-major.
// ===========================================================================

test "codec deinterleave→interleave is plane-major-conformant and round-trips bit-exact" {
    const io = pan.io;
    const L = types.ChannelLayout.stereo;
    const perm = try io.channelPermutation(2, io.canonicalOrder(L), &.{ .front_left, .front_right });

    // Three stereo frames as f32le interleaved on the wire: L,R,L,R,L,R.
    const wire_frames = [_]f32{ 0.1, -0.2, 0.3, -0.4, 0.5, -0.6 };
    var src: [wire_frames.len * 4]u8 = undefined;
    for (wire_frames, 0..) |x, i| std.mem.writeInt(u32, src[i * 4 ..][0..4], @bitCast(x), .little);

    // Decode into the INTERNAL planar buffer: [L0,L1,L2][R0,R1,R2].
    var planes: [6]f32 = undefined;
    const dst = Planar(f32, L).fromBase(&planes, 3);
    io.deinterleave(L, io.PcmFormat.f32le, perm, &src, dst);

    // The planar buffer is plane-major: the L-plane is the three L samples, the
    // R-plane the three R samples — NOT the interleaved wire order.
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.3, 0.5 }, dst.plane(0));
    try std.testing.expectEqualSlices(f32, &.{ -0.2, -0.4, -0.6 }, dst.plane(1));

    // Re-interleave (transpose back) and assert the bytes round-trip exactly.
    var out: [src.len]u8 = undefined;
    const csrc = PlanarConst(f32, L).fromBase(&planes, 3);
    io.interleave(L, io.PcmFormat.f32le, perm, null, csrc, &out);
    try std.testing.expectEqualSlices(u8, &src, &out);
}

// EXPECTED-@compileError (P-2 fails loud): a multi-channel port declared as an
// array-of-structs slice `[]Frame(Lane, L)` (C>1) is now a COMPILE ERROR — the
// port machinery rejects it and directs the author to the planar view. This
// cannot run as a live test (it aborts compilation), so it is pinned as a
// disabled stub; un-commenting it MUST turn the build red with the quoted
// diagnostic. (Mono `Sample(T)` = one plane stays a legal slice port.)
//
//   test "EXPECTED COMPILE ERROR: a C>1 []Frame AoS port is rejected" {
//       const AosStereo = struct {
//           const Self = @This();
//           pub fn process(_: *Self, _: []const pan.types.Frame(f32, .stereo),
//                          _: []pan.types.Frame(f32, .stereo)) void {}
//       };
//       _ = pan.port.MapOutPort(AosStereo);
//       // => "a multi-channel port must use a planar view Planar(Lane,L)/PlanarConst(Lane,L),
//       //     not a slice of ... (array-of-structs is interleaved for C>1 ...)"
//   }
