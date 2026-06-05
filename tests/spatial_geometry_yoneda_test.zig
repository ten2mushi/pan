//! spatial_geometry_yoneda_test — the behavioral SPECIFICATION of the spatial
//! GEOMETRY blocks in src/spatial.zig: `Vbap` (2-D vector base amplitude
//! panning, mono → speaker layout), `AmbisonicEncode` (mono+azimuth/elevation →
//! B-format, ACN/SN3D, orders 0–2) and `AmbisonicDecode` (B-format → speaker
//! layout). Written the Yoneda way — characterize each block through every
//! morphism that matters and pin each against an INDEPENDENT oracle (a hand-coded
//! SH formula, the constant-power identity Σg²=1, the encoder-transpose decode
//! law), never against pan's own output.
//!
//! These tests are ADDITIVE to the unit tests already in src/spatial.zig: that
//! file already pins one VBAP-on-speaker case (5.1), one VBAP arc sweep (5.1),
//! the stereo centre, the order-1 W/Y/Z/X formula, W direction-independence, the
//! pure-W decode (5.1) and one encode→decode argmax (5.1). This file adds the
//! coverage they lack: VBAP on stereo and 7.1 (power, on-speaker, LFE, custom
//! ring), the order-2 SN3D coefficients vs the explicit formulas, order-0,
//! encode linearity/elementwise, decode on stereo/7.1, the 1/N decode-gain
//! identity, and the documented LIMITS (2-D VBAP, orders 0–2, planar decode).
//!
//! Why these matter (Rule 9 — intent, not behavior):
//!   - VBAP's WHOLE point is constant power across the ring with ≤2 active
//!     speakers; a regression to a naive nearest-speaker or all-speakers law
//!     keeps "loud near the right speaker" but breaks Σg²=1 and the ≤2 bound.
//!   - The order-2 SN3D coefficients are the contract a downstream renderer/decode
//!     relies on; a transposed ACN index or a wrong √3/2 normalization still
//!     "produces 9 channels" — only the per-coefficient formula check catches it.
//!   - The basic decode is the SN3D encoder transpose scaled by 1/N; encode→decode
//!     MUST concentrate on the on-axis speaker — the property that makes the round
//!     trip a soundfield, not noise.
//!
//! COMPARISON MODE: `expectApproxEqAbs` against an independently-derived value
//! (hand-coded trig / the closed-form SH / the 1/N identity) in f64 working
//! precision; tolerance forgives the f32-vs-f64 gap of a single product, never
//! pan disagreeing with itself.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rule 13/14).

const std = @import("std");
const pan = @import("pan");

const Sample = pan.Sample;
const Frame = pan.Frame;
const types = pan.types;
const port = pan.port;

const num = pan.numericFor(.f32, .{});

const deg2rad = std.math.pi / 180.0;

/// Tolerance that admits the f32-vs-f64 gap of a single trig product.
const abs_tol: f32 = 1e-5;

// The ambisonic layouts, written once.
fn amb(comptime order: u8) types.ChannelLayout {
    return .{ .ambisonic = .{ .order = order, .ordering = .acn, .norm = .sn3d } };
}
/// The channel count of a layout as a comptime `usize` (array-length friendly).
fn ccount(comptime L: types.ChannelLayout) usize {
    return L.count();
}

// ===========================================================================
// VBAP — independent constant-power / bracketing-pair oracle.
//
// The expected outcome of 2-D VBAP at a node is a PROPERTY (Σg²=1, ≤2 active
// speakers, on-speaker collapses to unit gain there, LFE silent), not a
// re-derivation of pan's 2×2 solver. We assert the property across whole sweeps.
// ===========================================================================

/// Run the real block once over a unit mono impulse at `azimuth` (degrees) and
/// return the per-speaker gain vector.
fn vbapGains(comptime L: types.ChannelLayout, azimuth: f32) [ccount(L)]f32 {
    const C = comptime ccount(L);
    const V = pan.Vbap(num, L);
    var blk = V{ .azimuth = azimuth };
    var in: [1]Sample(f32) = .{.{ .ch = .{1} }};
    var out_buf: [C]f32 = undefined;
    const out = pan.Planar(f32, L).fromBase(&out_buf, 1);
    blk.process(&in, out);
    var g: [C]f32 = undefined;
    for (0..C) |c| g[c] = out.plane(c)[0];
    return g;
}

/// Σ over the gain vector of g²; the constant-power invariant says this is 1 for
/// any azimuth a bracketing pair encloses.
fn power(g: []const f32) f64 {
    var p: f64 = 0;
    for (g) |x| p += @as(f64, x) * x;
    return p;
}

fn activeCount(g: []const f32) usize {
    var n: usize = 0;
    for (g) |x| if (@abs(x) > 1e-6) {
        n += 1;
    };
    return n;
}

test "Vbap stereo: constant power Σg²=1 and ≤2 active speakers across the ±30° arc" {
    // Independent oracle: VBAP holds Σg²=1 for every azimuth the speaker pair
    // brackets — including the two endpoints, which sit exactly on a speaker (a
    // source on a speaker is a degenerate bracketing case: the partner gain is 0
    // and the on-speaker gain is 1, Σg²=1 still).
    //
    // BUG DETECTED (src/spatial.zig, Vbap.gains, lines ~432-434): a source sitting
    // EXACTLY on a stereo speaker (az = ±30°) returns an all-ZERO gain vector
    // (silence, Σg²=0) instead of unit gain at that speaker. Root cause: the source
    // direction px/py is computed in f32 (`const px = @cos(src)`, src:f32) and then
    // widened to f64 in the 2×2 gain solve, while the speaker base vectors are
    // computed in f64. At a source on a speaker the f32 rounding of the direction
    // (~1e-7) drives the PARTNER gain to ≈ -8.97e-9, which is past the `-1e-9`
    // non-negativity acceptance threshold, so the only bracketing pair is REJECTED
    // and `found` stays false → the block emits silence.
    //   Expected (per the block's own doc-comment): "a source sitting exactly on a
    //   speaker resolves to a single speaker at unit power: the partner gain comes
    //   out ≈0 and constant-power normalization leaves the on-speaker gain at 1."
    //   Actual: all gains 0 (no bracketing pair found) at az = ±30°.
    //   Repro: Vbap(f32num,.stereo){ .azimuth = 30 } over a unit impulse → L=0,R=0.
    // Fix candidates (NOT applied — diagnosis only): compute px/py in f64, or widen
    // the acceptance epsilon to absorb the f32-direction residual (e.g. -1e-6).
    // (The interior of the arc, az ∈ (-30,30), is correct: Σg²=1, ≤2 active.)
    const L: types.ChannelLayout = .stereo;
    var a: f32 = -30;
    while (a <= 30) : (a += 2) {
        const g = vbapGains(L, a);
        std.testing.expectApproxEqAbs(@as(f64, 1.0), power(&g), 1e-5) catch |e| {
            std.debug.print("vbap stereo power != 1 @ az={d}: power={d}\n", .{ a, power(&g) });
            return e;
        };
        try std.testing.expect(activeCount(&g) <= 2);
        // Both gains are non-negative (the bracketing pair, never an out-of-arc
        // negative leak).
        for (g) |x| try std.testing.expect(x >= -1e-6);
    }
}

test "Vbap stereo: a source on a speaker azimuth collapses to unit gain there, silence elsewhere" {
    // Independent oracle: a source sitting EXACTLY on a speaker is rendered by
    // that single speaker at unit power (the partner gain falls to 0). Stereo
    // speakers are at +30 (L, plane 0) and -30 (R, plane 1).
    //
    // BUG DETECTED (src/spatial.zig, Vbap.gains): see the constant-power test
    // above for the full diagnosis. At az = ±30° the only bracketing pair is
    // rejected because the f32-computed source direction drives the partner gain
    // to ≈ -8.97e-9 (past the `-1e-9` threshold), so the block returns silence.
    //   Expected: az=+30 → L=1, R=0; az=-30 → L=0, R=1.
    //   Actual:   az=+30 → L=0, R=0; az=-30 → L=0, R=0.
    const onL = vbapGains(.stereo, 30);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), onL[0], abs_tol);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), onL[1], abs_tol);
    const onR = vbapGains(.stereo, -30);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), onR[0], abs_tol);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), onR[1], abs_tol);
}

test "Vbap 7.1: source on each ring speaker → unit gain there, all other channels (incl. LFE) silent" {
    // 7.1 canonical azimuths [FL,FR,FC,LFE,Lb,Rb,Ls,Rs] = [30,-30,0,NaN,150,-150,90,-90].
    // LFE (index 3) is off the ring and must always be silent. Pin every ring
    // speaker resolves to itself at unit gain — the on-speaker collapse on the
    // densest default ring (a case the in-file tests only cover for 5.1).
    const az = [_]f32{ 30, -30, 0, 150, -150, 90, -90 };
    const idx = [_]usize{ 0, 1, 2, 4, 5, 6, 7 };
    for (az, idx) |a, target| {
        const g = vbapGains(.surround_7_1, a);
        for (0..8) |c| {
            const want: f32 = if (c == target) 1.0 else 0.0;
            std.testing.expectApproxEqAbs(want, g[c], abs_tol) catch |e| {
                std.debug.print("vbap 7.1 az={d}: speaker {d} = {d}, want {d}\n", .{ a, c, g[c], want });
                return e;
            };
        }
        // LFE is index 3 and is silent above by construction; assert explicitly.
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), g[3], abs_tol);
    }
}

test "Vbap 7.1: constant power Σg²=1, ≤2 active, LFE silent across the FULL ring sweep" {
    // The densest default ring. A full-circle sweep exercises the obtuse-pair
    // bracketing search and the narrowest-arc tiebreak; the property holds on
    // every enclosed azimuth and LFE never lights up.
    var a: f32 = -180;
    while (a <= 180) : (a += 3) {
        const g = vbapGains(.surround_7_1, a);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), g[3], 1e-6); // LFE
        const p = power(&g);
        // A source may fall outside every speaker arc → no gain at all (power 0);
        // when ANY speaker is active the constant-power law must hold exactly.
        if (activeCount(&g) > 0) {
            std.testing.expectApproxEqAbs(@as(f64, 1.0), p, 1e-5) catch |e| {
                std.debug.print("vbap 7.1 power={d} != 1 @ az={d}\n", .{ p, a });
                return e;
            };
            try std.testing.expect(activeCount(&g) <= 2);
        }
    }
}

test "Vbap: the output scales linearly with the input sample (a gain bank)" {
    // VBAP fixes the gains from azimuth then multiplies the input; the output at
    // amplitude x must be x times the unit-impulse gains. An independent linearity
    // oracle (rules out a kernel that adds a position-dependent offset).
    const L: types.ChannelLayout = .surround_5_1;
    const unit = vbapGains(L, 17.0);
    const V = pan.Vbap(num, L);
    const amps = [_]f32{ 0.0, 0.5, -0.75, 2.0 };
    for (amps) |x| {
        var blk = V{ .azimuth = 17.0 };
        var in: [1]Sample(f32) = .{.{ .ch = .{x} }};
        var out_buf: [6]f32 = undefined;
        const out = pan.Planar(f32, L).fromBase(&out_buf, 1);
        blk.process(&in, out);
        for (0..6) |c| {
            try std.testing.expectApproxEqAbs(x * unit[c], out.plane(c)[0], abs_tol);
        }
    }
}

test "Vbap: a custom speaker ring overrides the default geometry (geometry is block data)" {
    // The speaker_az_deg field is overridable block data (L3: geometry in the
    // block, not the stream type). Re-position the 5.1 ring to a non-default
    // arrangement (a wide front cross) and verify the source resolves against the
    // OVERRIDDEN azimuths, not the defaults — pinning the geometry lives in the
    // instance. LFE (NaN) stays off the ring.
    const L: types.ChannelLayout = .surround_5_1;
    const V = pan.Vbap(num, L);
    const nan = std.math.nan(f32);
    // FL,FR,FC,LFE,Ls,Rs relocated: a source on the new FC azimuth (10°) collapses
    // to FC alone.
    const ring = [_]f32{ 60, -60, 10, nan, 140, -140 };
    var blk = V{ .azimuth = 10, .speaker_az_deg = ring };
    var in: [1]Sample(f32) = .{.{ .ch = .{1} }};
    var out_buf: [6]f32 = undefined;
    const out = pan.Planar(f32, L).fromBase(&out_buf, 1);
    blk.process(&in, out);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out.plane(2)[0], abs_tol); // FC (overridden to 10°)
    for ([_]usize{ 0, 1, 3, 4, 5 }) |c| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.plane(c)[0], abs_tol);
    }

    // A source halfway between the overridden FC (10°) and FL (60°) splits power
    // between exactly those two, Σg²=1 — the default 30°/0° ring would NOT bracket
    // it the same way, so this confirms the override took effect.
    var mid = V{ .azimuth = 35, .speaker_az_deg = ring };
    var out_buf2: [6]f32 = undefined;
    const out2 = pan.Planar(f32, L).fromBase(&out_buf2, 1);
    mid.process(&in, out2);
    var g: [6]f32 = undefined;
    for (0..6) |c| g[c] = out2.plane(c)[0];
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), power(&g), 1e-5);
    try std.testing.expect(activeCount(&g) == 2);
    try std.testing.expect(g[0] > 0 and g[2] > 0); // FL and FC bracket 35°
}

test "Vbap: a zero input produces silence on every speaker at every azimuth" {
    const L: types.ChannelLayout = .surround_5_1;
    const V = pan.Vbap(num, L);
    var a: f32 = -110;
    while (a <= 110) : (a += 20) {
        var blk = V{ .azimuth = a };
        var in: [1]Sample(f32) = .{.{ .ch = .{0} }};
        var out_buf: [6]f32 = undefined;
        const out = pan.Planar(f32, L).fromBase(&out_buf, 1);
        blk.process(&in, out);
        for (0..6) |c| try std.testing.expectEqual(@as(f32, 0.0), out.plane(c)[0]);
    }
}

test "Vbap: process is elementwise over the buffer (azimuth held, gains constant per call)" {
    // The block holds azimuth across the buffer; every output frame is the same
    // gain vector times its input sample. Pins no inter-sample state leaks.
    const L: types.ChannelLayout = .surround_5_1;
    const V = pan.Vbap(num, L);
    const n = 32;
    var in: [n]Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(7);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;
    var out_buf: [6 * n]f32 = undefined;
    const out = pan.Planar(f32, L).fromBase(&out_buf, n);
    var blk = V{ .azimuth = 55.0 };
    blk.process(&in, out);
    const unit = vbapGains(L, 55.0);
    for (0..6) |c| {
        const plane = out.plane(c);
        for (in, plane) |s, y| {
            try std.testing.expectApproxEqAbs(s.ch[0] * unit[c], y, abs_tol);
        }
    }
}

// ===========================================================================
// AmbisonicEncode — closed-form SN3D oracle for orders 0–2.
//
// Hand-coded the documented SN3D real-SH formulas, sharing none of the block's
// `sh()` switch. ACN order: W,Y,Z,X,V,T,R,S,U for k = 0..8.
// ===========================================================================

const sqrt3_2: f64 = 0.8660254037844386; // √3/2

/// Independent SN3D real-SH oracle, orders 0–2 (k=0..8), from the closed forms.
fn oracleSh(comptime N: usize, az_deg: f32, el_deg: f32) [N]f64 {
    const az = @as(f64, az_deg) * deg2rad;
    const el = @as(f64, el_deg) * deg2rad;
    const ce = @cos(el);
    const se = @sin(el);
    const all = [9]f64{
        1.0, // W
        @sin(az) * ce, // Y
        se, // Z
        @cos(az) * ce, // X
        sqrt3_2 * @sin(2.0 * az) * ce * ce, // V
        sqrt3_2 * @sin(az) * @sin(2.0 * el), // T
        0.5 * (3.0 * se * se - 1.0), // R
        sqrt3_2 * @cos(az) * @sin(2.0 * el), // S
        sqrt3_2 * @cos(2.0 * az) * ce * ce, // U
    };
    var out: [N]f64 = undefined;
    for (0..N) |k| out[k] = all[k];
    return out;
}

fn encodeOnce(comptime order: u8, az: f32, el: f32, x: f32) [ccount(amb(order))]f32 {
    const C = comptime ccount(amb(order));
    const E = pan.AmbisonicEncode(num, order);
    var blk = E{ .azimuth = az, .elevation = el };
    var in: [1]Sample(f32) = .{.{ .ch = .{x} }};
    var out_buf: [C]f32 = undefined;
    const out = pan.Planar(f32, amb(order)).fromBase(&out_buf, 1);
    blk.process(&in, out);
    var g: [C]f32 = undefined;
    for (0..C) |k| g[k] = out.plane(k)[0];
    return g;
}

test "AmbisonicEncode order-0 is the omni W channel only (single channel = the input)" {
    // Order 0 has exactly one channel, W=1, direction-independent. A degenerate
    // but documented case (the in-file tests start at order 1).
    try std.testing.expectEqual(@as(u16, 1), amb(0).count());
    const dirs = [_][2]f32{ .{ 0, 0 }, .{ 90, 45 }, .{ -123, -30 } };
    for (dirs) |dir| {
        const g = encodeOnce(0, dir[0], dir[1], 0.6);
        try std.testing.expectApproxEqAbs(@as(f32, 0.6), g[0], abs_tol);
    }
}

test "AmbisonicEncode order-2: all 9 ACN/SN3D coefficients match the explicit closed forms" {
    // The decisive coefficient check: every channel k=0..8 vs the hand-coded SN3D
    // formula. A transposed ACN index, a missing √3/2, or an el-vs-az swap in any
    // higher term fails here even though the block still emits 9 channels.
    const order = 2;
    const C = comptime ccount(amb(order));
    try std.testing.expectEqual(@as(usize, 9), C);
    const dirs = [_][2]f32{
        .{ 0, 0 },   .{ 30, 0 },    .{ 90, 0 },    .{ 0, 45 },
        .{ 45, 30 }, .{ -60, -20 }, .{ 137, -22 }, .{ -88, 61 },
    };
    for (dirs) |dir| {
        const g = encodeOnce(order, dir[0], dir[1], 1.0);
        const want = oracleSh(C, dir[0], dir[1]);
        for (0..C) |k| {
            std.testing.expectApproxEqAbs(@as(f32, @floatCast(want[k])), g[k], abs_tol) catch |e| {
                std.debug.print("amb2 coeff k={d} @ az={d} el={d}: got {d}, want {d}\n", .{ k, dir[0], dir[1], g[k], want[k] });
                return e;
            };
        }
    }
}

test "AmbisonicEncode: the field is linear in the input sample (output = x · Y_k)" {
    // Encoding scales each SH coefficient by the input. Independent linearity
    // oracle: doubling x doubles every channel; x=0 silences the whole field.
    const order = 2;
    const C = comptime ccount(amb(order));
    const base = encodeOnce(order, 41, 17, 1.0);
    const amps = [_]f32{ 0.0, 0.5, -1.3, 2.5 };
    for (amps) |x| {
        const g = encodeOnce(order, 41, 17, x);
        for (0..C) |k| try std.testing.expectApproxEqAbs(x * base[k], g[k], abs_tol);
    }
}

test "AmbisonicEncode order-1: W is exactly the input regardless of direction (omni)" {
    // Re-pinning the W=Y_0=1 invariant at order 1 for several directions, with a
    // non-unit input, to assert it is the literal input value (not merely > 0).
    const dirs = [_][2]f32{ .{ 0, 0 }, .{ 200, 80 }, .{ -200, -80 } };
    for (dirs) |dir| {
        const g = encodeOnce(1, dir[0], dir[1], -0.31);
        try std.testing.expectApproxEqAbs(@as(f32, -0.31), g[0], abs_tol);
    }
}

test "AmbisonicEncode: process is elementwise over the buffer (direction held per call)" {
    const order = 1;
    const C = comptime ccount(amb(order));
    const E = pan.AmbisonicEncode(num, order);
    const n = 16;
    var in: [n]Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(3);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;
    var out_buf: [C * n]f32 = undefined;
    const out = pan.Planar(f32, amb(order)).fromBase(&out_buf, n);
    var blk = E{ .azimuth = 33, .elevation = 12 };
    blk.process(&in, out);
    const unit = encodeOnce(order, 33, 12, 1.0);
    for (0..C) |k| {
        for (in, out.plane(k)) |s, y| {
            try std.testing.expectApproxEqAbs(s.ch[0] * unit[k], y, abs_tol);
        }
    }
}

// ===========================================================================
// AmbisonicDecode — the encoder-transpose / 1/N projection law.
// ===========================================================================

test "AmbisonicDecode: pure-W field decodes to c/N on every ring speaker (stereo)" {
    // Independent oracle: Y_0=1 for all directions, so a W-only field of value c
    // lands as c/N on each speaker, N=(order+1)². Stereo has no LFE; both equal.
    inline for ([_]u8{ 0, 1, 2 }) |order| {
        const N = comptime ccount(amb(order));
        const D = pan.AmbisonicDecode(num, order, .stereo);
        var blk = D{};
        var in_buf: [N]f32 = [_]f32{0} ** N;
        in_buf[0] = 2.0; // pure W
        const in = pan.PlanarConst(f32, amb(order)).fromBase(&in_buf, 1);
        var out_buf: [2]f32 = undefined;
        const out = pan.Planar(f32, .stereo).fromBase(&out_buf, 1);
        blk.process(in, out);
        const want: f32 = 2.0 / @as(f32, @floatFromInt(N));
        try std.testing.expectApproxEqAbs(want, out.plane(0)[0], abs_tol);
        try std.testing.expectApproxEqAbs(want, out.plane(1)[0], abs_tol);
    }
}

test "AmbisonicDecode 7.1: pure-W decodes equally to all ring speakers, LFE silent" {
    const order = 2;
    const N = comptime ccount(amb(order));
    const D = pan.AmbisonicDecode(num, order, .surround_7_1);
    var blk = D{};
    var in_buf: [N]f32 = [_]f32{0} ** N;
    in_buf[0] = 5.0;
    const in = pan.PlanarConst(f32, amb(order)).fromBase(&in_buf, 1);
    var out_buf: [8]f32 = undefined;
    const out = pan.Planar(f32, .surround_7_1).fromBase(&out_buf, 1);
    blk.process(in, out);
    const want: f32 = 5.0 / @as(f32, @floatFromInt(N));
    for (0..8) |c| {
        if (c == 3) {
            try std.testing.expectApproxEqAbs(@as(f32, 0), out.plane(c)[0], 1e-6); // LFE
        } else {
            try std.testing.expectApproxEqAbs(want, out.plane(c)[0], abs_tol);
        }
    }
}

test "AmbisonicDecode: speaker coefficients are (1/N)·SN3D SH at the speaker direction (the transpose law)" {
    // Decode a SINGLE non-zero ambisonic channel (a unit basis field e_k) and read
    // each speaker — that recovers the speaker's decode coefficient for channel k,
    // which must equal (1/N)·Y_k(dir_s). Independent: probes the matrix entry by
    // entry against the closed-form SH, the transpose-of-encoder claim made literal.
    const order = 2;
    const N = comptime ccount(amb(order));
    const D = pan.AmbisonicDecode(num, order, .surround_5_1);
    // 5.1 ring (skip LFE at index 3): [FL,FR,FC,_,Ls,Rs] = [30,-30,0,_,110,-110].
    const spk_az = [_]f32{ 30, -30, 0, 110, -110 };
    const spk_idx = [_]usize{ 0, 1, 2, 4, 5 };
    inline for (0..N) |k| {
        var blk = D{};
        var in_buf: [N]f32 = [_]f32{0} ** N;
        in_buf[k] = 1.0; // unit basis field e_k
        const in = pan.PlanarConst(f32, amb(order)).fromBase(&in_buf, 1);
        var out_buf: [6]f32 = undefined;
        const out = pan.Planar(f32, .surround_5_1).fromBase(&out_buf, 1);
        blk.process(in, out);
        for (spk_az, spk_idx) |az, s| {
            const want = oracleSh(N, az, 0.0)[k] / @as(f64, @floatFromInt(N));
            std.testing.expectApproxEqAbs(@as(f32, @floatCast(want)), out.plane(s)[0], abs_tol) catch |e| {
                std.debug.print("decode coeff speaker {d} channel {d}: got {d}, want {d}\n", .{ s, k, out.plane(s)[0], want });
                return e;
            };
        }
        // LFE must be silent for any input channel.
        try std.testing.expectApproxEqAbs(@as(f32, 0), out.plane(3)[0], 1e-6);
    }
}

test "AmbisonicDecode: encode→decode concentrates energy at the on-axis speaker (stereo and 7.1)" {
    // The defining round-trip property on the rings the in-file test does NOT
    // cover (it pins 5.1 only). Encode at each speaker's azimuth, decode, and the
    // matching speaker must be the strict argmax.
    const layouts = [_]types.ChannelLayout{ .stereo, .surround_7_1 };
    inline for (layouts) |L| {
        const order = 2;
        const N = comptime ccount(amb(order));
        const C = comptime ccount(L);
        const E = pan.AmbisonicEncode(num, order);
        const D = pan.AmbisonicDecode(num, order, L);
        const defaults = comptime defaultRing(L);
        for (defaults.az, defaults.idx) |a, target| {
            var enc = E{ .azimuth = a, .elevation = 0 };
            var dec = D{};
            var in: [1]Sample(f32) = .{.{ .ch = .{1} }};
            var b_buf: [N]f32 = undefined;
            const b = pan.Planar(f32, amb(order)).fromBase(&b_buf, 1);
            enc.process(&in, b);
            const b_c = pan.PlanarConst(f32, amb(order)).fromBase(&b_buf, 1);
            var out_buf: [C]f32 = undefined;
            const out = pan.Planar(f32, L).fromBase(&out_buf, 1);
            dec.process(b_c, out);
            const on = out.plane(target)[0];
            try std.testing.expect(on > 0);
            for (0..C) |c| {
                if (c == target) continue;
                // skip LFE (NaN azimuth → 0, trivially below `on`)
                std.testing.expect(on > out.plane(c)[0]) catch |e| {
                    std.debug.print("decode argmax: speaker {d}={d} not < on-axis {d}={d}\n", .{ c, out.plane(c)[0], target, on });
                    return e;
                };
            }
        }
    }
}

/// The non-LFE default ring of a positional layout (azimuths + channel indices),
/// computed at comptime for the round-trip test.
const Ring = struct { az: []const f32, idx: []const usize };
fn defaultRing(comptime L: types.ChannelLayout) Ring {
    return switch (L) {
        .stereo => .{ .az = &.{ 30, -30 }, .idx = &.{ 0, 1 } },
        .surround_5_1 => .{ .az = &.{ 30, -30, 0, 110, -110 }, .idx = &.{ 0, 1, 2, 4, 5 } },
        .surround_7_1 => .{ .az = &.{ 30, -30, 0, 150, -150, 90, -90 }, .idx = &.{ 0, 1, 2, 4, 5, 6, 7 } },
        else => @compileError("no default ring"),
    };
}

test "AmbisonicDecode: a multi-frame buffer is decoded frame-independently (no inter-sample state)" {
    // The decode is a per-frame matrix multiply; assert a 3-frame buffer matches
    // three single-frame decodes (no carry-over). Drive distinct W values.
    const order = 1;
    const N = comptime ccount(amb(order));
    const D = pan.AmbisonicDecode(num, order, .stereo);
    const n = 3;
    var in_buf: [N * n]f32 = [_]f32{0} ** (N * n);
    // W plane (channel 0) carries 1,2,3; others zero ⇒ omni, both speakers = w/N.
    in_buf[0] = 1;
    in_buf[1] = 2;
    in_buf[2] = 3;
    const in = pan.PlanarConst(f32, amb(order)).fromBase(&in_buf, n);
    var out_buf: [2 * n]f32 = undefined;
    const out = pan.Planar(f32, .stereo).fromBase(&out_buf, n);
    var blk = D{};
    blk.process(in, out);
    const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(N));
    for (0..n) |i| {
        const w: f32 = @floatFromInt(i + 1);
        try std.testing.expectApproxEqAbs(w * inv_n, out.plane(0)[i], abs_tol);
        try std.testing.expectApproxEqAbs(w * inv_n, out.plane(1)[i], abs_tol);
    }
}

// ===========================================================================
// Structural identities — the layout-changing morphisms at order 0/2 and 7.1,
// the cases the in-file tests (order 1 → stereo) leave uncovered.
// ===========================================================================

test "structural: AmbisonicEncode order-0/2 and Vbap 7.1 are layout-changing Maps with the right ports" {
    const E0 = pan.AmbisonicEncode(num, 0);
    const E2 = pan.AmbisonicEncode(num, 2);
    const V = pan.Vbap(num, .surround_7_1);
    const D2 = pan.AmbisonicDecode(num, 2, .surround_7_1);
    try std.testing.expect(port.classify(E0) == .Map);
    try std.testing.expect(port.classify(E2) == .Map);
    try std.testing.expect(port.classify(V) == .Map);
    try std.testing.expect(port.classify(D2) == .Map);
    try std.testing.expect(port.MapInPort(E2).Elem == Sample(f32));
    try std.testing.expect(port.MapOutPort(E2).Elem == Frame(f32, amb(2)));
    try std.testing.expect(port.MapInPort(V).Elem == Sample(f32));
    try std.testing.expect(port.MapOutPort(V).Elem == Frame(f32, .surround_7_1));
    try std.testing.expect(port.MapInPort(D2).Elem == Frame(f32, amb(2)));
    try std.testing.expect(port.MapOutPort(D2).Elem == Frame(f32, .surround_7_1));
    // The ambisonic order is part of the layout identity: order-1 and order-2
    // B-format frames are DISTINCT element types (connect would reject a mismatch).
    try std.testing.expect(Frame(f32, amb(1)) != Frame(f32, amb(2)));
}
