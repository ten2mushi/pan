//! Yoneda "tests as definition" for the mix/routing blocks — `SummingMixer`,
//! `Splitter`, `MatrixRouter`, `DryWet` (src/dsp_mix.zig).
//!
//! Every block here is a rate-1:1 `Map`. The discipline (catalog §1.4 Numeric
//! trait; testing contract §1.1 float=allclose, integer=bit-exact):
//!
//!   - The oracle is INDEPENDENT (Rule 9): a hand-written sum / hand-computed
//!     weighted-sum / hand-computed crossfade, sharing none of the block's
//!     plane/skip-zero/switch-arity machinery — only the defining law.
//!   - Integer paths are bit-exact (the wide-accumulator headroom + saturating
//!     store for SummingMixer; the q(frac) multiply→shift→saturate for
//!     MatrixRouter). Saturation and wrap-vs-clamp are pinned with values chosen
//!     to overflow the lane so a missing clamp (silent wrap) FAILS loudly.
//!   - MatrixRouter index orientation is pinned so a TRANSPOSE fails.
//!   - DryWet crossfade anchors (mix=0/0.5/1) + clamp are pinned, plus the
//!     midpoint that distinguishes a LINEAR from an equal-power law.
//!   - Port classification (.Map), port counts, and element types are checked so
//!     a mis-declared arity is caught at the type level.
//!
//! These add the definitional/edge coverage the in-file unit tests lack: higher
//! arities (1,5,8 fan-in/out), integer MatrixRouter, MatrixRouter saturation,
//! non-square routing shapes, DryWet linearity vs equal-power, and the f64
//! monomorph. The in-file tests already cover the 2/3-input f32 happy path,
//! the 2x2 hand-check, and the DryWet anchors — those are not duplicated.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rule 13/14). Run standalone:
//!   zig test --dep pan -Mroot=tests/mix_routing_yoneda_test.zig -Mpan=src/root.zig

const std = @import("std");
const testing = std.testing;
const pan = @import("pan");

const types = pan.types;
const port = pan.port;

const f32num = pan.numericFor(.f32, .{});
const f64num = pan.numericFor(.f64, .{});
const i16num = pan.numericFor(.i16, .{});
const i8num = pan.numericFor(.i8, .{});

fn sf(comptime T: type, v: T) types.Sample(T) {
    return .{ .ch = .{v} };
}

// ===========================================================================
// SummingMixer — additive fan-in.
// ===========================================================================

test "SummingMixer arity 1 is a pass-through Map (n_in=1, the degenerate sum)" {
    // WHY: the 1-input prong has its own body (a plain copy, no Acc); it must
    // still classify as a 1-in/1-out Map and pass the input through unchanged.
    const M1 = pan.SummingMixer(f32num, 1);
    try testing.expect(port.classify(M1) == .Map);
    try testing.expectEqual(@as(comptime_int, 1), port.mapInputCount(M1));
    try testing.expectEqual(@as(comptime_int, 1), port.mapOutputCount(M1));
    var m = M1{};
    const a = [_]types.Sample(f32){ sf(f32, 1.5), sf(f32, -2.5) };
    var out: [2]types.Sample(f32) = undefined;
    m.process(&a, &out);
    try testing.expectEqual(@as(f32, 1.5), out[0].ch[0]);
    try testing.expectEqual(@as(f32, -2.5), out[1].ch[0]);
}

test "SummingMixer arity 8 sums all inputs against an independent loop (the fan-in ceiling)" {
    // WHY: the highest legal arity uses an index-based body distinct from the
    // small-arity capture-loops; pin it against an independent column-sum so an
    // off-by-one in the 8-way add (a dropped or doubled input) fails.
    const M8 = pan.SummingMixer(f32num, 8);
    try testing.expectEqual(@as(comptime_int, 8), port.mapInputCount(M8));
    try testing.expectEqual(@as(comptime_int, 1), port.mapOutputCount(M8));
    var m = M8{};
    const n = 3;
    var cols: [8][n]types.Sample(f32) = undefined;
    for (0..8) |c| for (0..n) |k| {
        cols[c][k] = sf(f32, @floatFromInt(@as(i32, @intCast(c)) - 3 + @as(i32, @intCast(k))));
    };
    var out: [n]types.Sample(f32) = undefined;
    m.process(&cols[0], &cols[1], &cols[2], &cols[3], &cols[4], &cols[5], &cols[6], &cols[7], &out);
    for (0..n) |k| {
        var want: f32 = 0;
        for (0..8) |c| want += cols[c][k].ch[0];
        try testing.expectApproxEqAbs(want, out[k].ch[0], 1e-5);
    }
}

test "SummingMixer(i16) saturates at BOTH the positive and negative bound (no wrap)" {
    // WHY: the wide-Acc + clamp contract must hold on BOTH ends. Three i16 maxima
    // sum to 98301, which wraps to a small/negative i16 if added in-lane; the
    // clamp must pin maxInt. Symmetrically, three minima must pin minInt(i16) =
    // −32768, not wrap positive. A signed-clamp-only-one-side bug fails here.
    const M3 = pan.SummingMixer(i16num, 3);
    var m = M3{};
    const hi = std.math.maxInt(i16); // 32767
    const lo = std.math.minInt(i16); // -32768
    const a = [_]types.Sample(i16){ sf(i16, hi), sf(i16, lo) };
    const b = [_]types.Sample(i16){ sf(i16, hi), sf(i16, lo) };
    const c = [_]types.Sample(i16){ sf(i16, hi), sf(i16, lo) };
    var out: [2]types.Sample(i16) = undefined;
    m.process(&a, &b, &c, &out);
    try testing.expectEqual(@as(i16, hi), out[0].ch[0]); // +98301 → clamp to +max
    try testing.expectEqual(@as(i16, lo), out[1].ch[0]); // −98304 → clamp to −min
}

test "SummingMixer(i8) keeps full headroom in Acc before the final saturating store" {
    // WHY: i8 lane, i16 Acc. 100 + 100 = 200 overflows i8 (wraps to −56) but fits
    // i16; the result must be the SATURATED 127, proving the sum lived in the wide
    // Acc and only the store clamped. An exactly-in-range pair stays exact.
    const M2 = pan.SummingMixer(i8num, 2);
    var m = M2{};
    const a = [_]types.Sample(i8){ sf(i8, 100), sf(i8, 50) };
    const b = [_]types.Sample(i8){ sf(i8, 100), sf(i8, -20) };
    var out: [2]types.Sample(i8) = undefined;
    m.process(&a, &b, &out);
    try testing.expectEqual(@as(i8, 127), out[0].ch[0]); // 200 saturates to maxInt(i8)
    try testing.expectEqual(@as(i8, 30), out[1].ch[0]); // 30 is exact
}

test "SummingMixer(i16) in-range sum is exact and order-independent" {
    // WHY: addition is commutative; when nothing saturates the sum must be exact
    // regardless of which inputs hold which values. Pins that the integer path is
    // a faithful add, not a lossy one.
    const M3 = pan.SummingMixer(i16num, 3);
    var m = M3{};
    const a = [_]types.Sample(i16){sf(i16, 1000)};
    const b = [_]types.Sample(i16){sf(i16, -2500)};
    const c = [_]types.Sample(i16){sf(i16, 700)};
    var out: [1]types.Sample(i16) = undefined;
    m.process(&a, &b, &c, &out);
    try testing.expectEqual(@as(i16, 1000 - 2500 + 700), out[0].ch[0]); // -800
}

// ===========================================================================
// Splitter — fan-out.
// ===========================================================================

test "Splitter arity 1 and arity 8 copy the input to EVERY output, byte-identical" {
    // WHY: fan-out duplicates; it never transforms. Cover the degenerate 1-out and
    // the 8-out ceiling (which uses an inline-for body) — every output plane must
    // be an exact copy. Use f32 with values that are bit-distinct.
    {
        const Sp1 = pan.Splitter(f32num, 1);
        try testing.expect(port.classify(Sp1) == .Map);
        try testing.expectEqual(@as(comptime_int, 1), port.mapOutputCount(Sp1));
        var sp = Sp1{};
        const in = [_]types.Sample(f32){ sf(f32, 0.1), sf(f32, 0.2) };
        var o0: [2]types.Sample(f32) = undefined;
        sp.process(&in, &o0);
        try testing.expectEqual(in[0].ch[0], o0[0].ch[0]);
        try testing.expectEqual(in[1].ch[0], o0[1].ch[0]);
    }
    {
        const Sp8 = pan.Splitter(f32num, 8);
        try testing.expectEqual(@as(comptime_int, 1), port.mapInputCount(Sp8));
        try testing.expectEqual(@as(comptime_int, 8), port.mapOutputCount(Sp8));
        var sp = Sp8{};
        const in = [_]types.Sample(f32){ sf(f32, -7.25), sf(f32, 3.5), sf(f32, 0.0) };
        var outs: [8][3]types.Sample(f32) = undefined;
        sp.process(&in, &outs[0], &outs[1], &outs[2], &outs[3], &outs[4], &outs[5], &outs[6], &outs[7]);
        for (0..8) |o| for (0..3) |k| {
            try testing.expectEqual(in[k].ch[0], outs[o][k].ch[0]);
        };
    }
}

test "Splitter outputs are independent copies, not aliases of one buffer" {
    // WHY: each output must be its OWN copy; mutating one afterwards must not be
    // visible in another (a bug that wrote the same backing slice twice would
    // alias them). The block @memcpys into distinct caller slices.
    const Sp3 = pan.Splitter(f32num, 3);
    var sp = Sp3{};
    const in = [_]types.Sample(f32){sf(f32, 5.0)};
    var o0: [1]types.Sample(f32) = undefined;
    var o1: [1]types.Sample(f32) = undefined;
    var o2: [1]types.Sample(f32) = undefined;
    sp.process(&in, &o0, &o1, &o2);
    o1[0].ch[0] = 99.0; // mutate one copy
    try testing.expectEqual(@as(f32, 5.0), o0[0].ch[0]); // others unaffected
    try testing.expectEqual(@as(f32, 5.0), o2[0].ch[0]);
}

// ===========================================================================
// MatrixRouter — weighted routing matrix.
// ===========================================================================

/// Independent oracle: out_j[r] = Σ_k coeff[j][k]·in_k[r], float linear path.
fn oracleRoute(
    comptime n_in: usize,
    comptime n_out: usize,
    coeff: [n_out][n_in]f32,
    ins: [n_in][]const f32,
    outs: [n_out][]f32,
) void {
    const n = outs[0].len;
    for (0..n) |r| {
        for (0..n_out) |j| {
            var acc: f32 = 0;
            for (0..n_in) |k| acc += coeff[j][k] * ins[k][r];
            outs[j][r] = acc;
        }
    }
}

test "MatrixRouter non-square 3→2 matches the independent weighted-sum oracle" {
    // WHY: the in-file test only covers 2x2. A rectangular shape exercises a
    // different switch prong and a different mixOne arity; pin it against an
    // independent triple-loop so a mis-shaped coeff index fails.
    const R = pan.MatrixRouter(f32num, 3, 2);
    try testing.expectEqual(@as(comptime_int, 3), port.mapInputCount(R));
    try testing.expectEqual(@as(comptime_int, 2), port.mapOutputCount(R));
    var r = R{};
    r.coeff = .{ .{ 0.5, -1.0, 2.0 }, .{ 1.0, 0.25, -0.5 } };
    const n = 2;
    var c0 = [_]types.Sample(f32){ sf(f32, 1), sf(f32, 4) };
    var c1 = [_]types.Sample(f32){ sf(f32, 2), sf(f32, 5) };
    var c2 = [_]types.Sample(f32){ sf(f32, 3), sf(f32, 6) };
    var o0: [n]types.Sample(f32) = undefined;
    var o1: [n]types.Sample(f32) = undefined;
    r.process(&c0, &c1, &c2, &o0, &o1);

    var ib0: [n]f32 = .{ 1, 4 };
    var ib1: [n]f32 = .{ 2, 5 };
    var ib2: [n]f32 = .{ 3, 6 };
    const ins: [3][]const f32 = .{ &ib0, &ib1, &ib2 };
    var ob0: [n]f32 = undefined;
    var ob1: [n]f32 = undefined;
    const outs: [2][]f32 = .{ &ob0, &ob1 };
    oracleRoute(3, 2, r.coeff, ins, outs);
    for (0..n) |k| {
        try testing.expectApproxEqAbs(ob0[k], o0[k].ch[0], 1e-5);
        try testing.expectApproxEqAbs(ob1[k], o1[k].ch[0], 1e-5);
    }
}

test "MatrixRouter index orientation is row=out/col=in — a transposed coeff gives a DIFFERENT result" {
    // WHY: pin the orientation so a transpose is detectable. With a non-symmetric
    // 2x2 routing the output of M differs from the output of Mᵀ; assert both the
    // correct value AND that the transpose would NOT match it.
    const R = pan.MatrixRouter(f32num, 2, 2);
    const M = [2][2]f32{ .{ 0.0, 1.0 }, .{ 1.0, 0.0 } }; // a SWAP: out0=in1, out1=in0
    const in0 = sf(f32, 3.0);
    const in1 = sf(f32, 8.0);

    var r = R{};
    r.coeff = M;
    var o0: [1]types.Sample(f32) = undefined;
    var o1: [1]types.Sample(f32) = undefined;
    r.process(&[_]types.Sample(f32){in0}, &[_]types.Sample(f32){in1}, &o0, &o1);
    try testing.expectEqual(@as(f32, 8.0), o0[0].ch[0]); // out0 = in1 (the swap)
    try testing.expectEqual(@as(f32, 3.0), o1[0].ch[0]); // out1 = in0

    // A non-symmetric matrix where M != Mᵀ proves orientation is load-bearing.
    const A = [2][2]f32{ .{ 2.0, 0.0 }, .{ 0.0, 0.0 } }; // out0 = 2·in0, out1 = 0
    var r2 = R{};
    r2.coeff = A;
    var p0: [1]types.Sample(f32) = undefined;
    var p1: [1]types.Sample(f32) = undefined;
    r2.process(&[_]types.Sample(f32){in0}, &[_]types.Sample(f32){in1}, &p0, &p1);
    try testing.expectEqual(@as(f32, 6.0), p0[0].ch[0]); // 2·in0
    try testing.expectEqual(@as(f32, 0.0), p1[0].ch[0]);
    // Under the transpose Aᵀ = {{2,0},{0,0}} (same here) — pick a genuinely
    // asymmetric one to be sure orientation matters:
    const B = [2][2]f32{ .{ 0.0, 5.0 }, .{ 0.0, 0.0 } }; // out0 = 5·in1
    var r3 = R{};
    r3.coeff = B;
    var q0: [1]types.Sample(f32) = undefined;
    var q1: [1]types.Sample(f32) = undefined;
    r3.process(&[_]types.Sample(f32){in0}, &[_]types.Sample(f32){in1}, &q0, &q1);
    try testing.expectEqual(@as(f32, 40.0), q0[0].ch[0]); // 5·in1 = 40 (row=out,col=in)
    // Bᵀ would give out0 = 5·in0 = 15; assert we are NOT that.
    try testing.expect(q0[0].ch[0] != 15.0);
}

test "MatrixRouter default diagonal passthrough holds for a non-square 3→3 and a 1→1" {
    // WHY: the documented default is coeff[j][k]=1 iff j==k. Verify the diagonal
    // routes input k→output k and zeros the off-diagonal, on shapes other than the
    // in-file 2x2. (For non-square the diagonal is the shared min(n_in,n_out).)
    const R = pan.MatrixRouter(f32num, 3, 3);
    var r = R{};
    const c0 = [_]types.Sample(f32){sf(f32, 10)};
    const c1 = [_]types.Sample(f32){sf(f32, 20)};
    const c2 = [_]types.Sample(f32){sf(f32, 30)};
    var o0: [1]types.Sample(f32) = undefined;
    var o1: [1]types.Sample(f32) = undefined;
    var o2: [1]types.Sample(f32) = undefined;
    r.process(&c0, &c1, &c2, &o0, &o1, &o2);
    try testing.expectEqual(@as(f32, 10), o0[0].ch[0]);
    try testing.expectEqual(@as(f32, 20), o1[0].ch[0]);
    try testing.expectEqual(@as(f32, 30), o2[0].ch[0]);
}

test "MatrixRouter(i16) default diagonal is a bit-exact identity passthrough (Q2 unity)" {
    // CONTRACT (the block's doc-comment): "an unset router routes input k to output
    // k at unity" — the default diagonal must be a true identity, out == in, with no
    // sign flip and no LSB loss. The integer weights use a Q2 fixed-point format
    // (two integer bits above the sign), in which +1.0 IS representable as
    // `1 << (bits-2)` (= 16384 for i16); `(unity·x) >> (bits-2) == x` exactly. The
    // q(bits-1) sample format CANNOT represent +1.0 (`1 << (bits-1)` is the sign bit
    // = −1.0), so a router that mixed in the sample format would invert — Q2 is why
    // it does not. This regression-guards that exact representability choice.
    const R = pan.MatrixRouter(i16num, 1, 1);
    var r = R{};
    const xin = [_]types.Sample(i16){ sf(i16, 12345), sf(i16, 100), sf(i16, -200) };
    var o0: [3]types.Sample(i16) = undefined;
    r.process(&xin, &o0);
    try testing.expectEqual(@as(i16, 12345), o0[0].ch[0]);
    try testing.expectEqual(@as(i16, 100), o0[1].ch[0]);
    try testing.expectEqual(@as(i16, -200), o0[2].ch[0]);
}

test "MatrixRouter(i16) applies a Q2.14 half-gain coeff (bit-exact, with the q-format shift)" {
    // WHY: the integer weights are Q2.14 (frac = bits-2 = 14 for i16), so 0.5 is
    // 1<<13 = 8192. out = (8192·x) >> 14 = x/2 (arithmetic shift, truncating toward
    // −∞). Pin the EXACT integer result so a wrong shift count or a
    // rounding-vs-truncation slip is caught bit-exactly.
    const R = pan.MatrixRouter(i16num, 1, 1);
    var r = R{};
    const half_q14: i16 = 1 << 13; // 8192 == 0.5 in Q2.14
    r.coeff = .{.{half_q14}};
    const xin = [_]types.Sample(i16){ sf(i16, 1000), sf(i16, 1001), sf(i16, -1001) };
    var o0: [3]types.Sample(i16) = undefined;
    r.process(&xin, &o0);
    // (8192*1000)>>14 = 8192000>>14 = 500 exactly.
    try testing.expectEqual(@as(i16, 500), o0[0].ch[0]);
    // (8192*1001)>>14 = 8200192>>14 = 500 (floor; .5 truncates down).
    try testing.expectEqual(@as(i16, 500), o0[1].ch[0]);
    // (8192*-1001)>>14: arithmetic shift floors toward −∞ → -501.
    try testing.expectEqual(@as(i16, -501), o0[2].ch[0]);
}

test "MatrixRouter(i16) saturates a sum that exceeds the lane bound (wide Acc + clamp)" {
    // WHY: each output is a Σ over inputs accumulated in the wide Acc, shifted back
    // by frac, then stored with saturation. Route two large (≈ full-scale Q2.14,
    // maxInt(i16)) gains over full-scale inputs into one output: the shifted sum far
    // exceeds the lane bound and MUST clamp to maxInt(i16) (and the negative side to
    // minInt) rather than wrapping. A missing/one-sided clamp fails loudly.
    const R = pan.MatrixRouter(i16num, 2, 1);
    var r = R{};
    const near_unity: i16 = std.math.maxInt(i16); // ≈ full-scale weight in Q2.14
    r.coeff = .{.{ near_unity, near_unity }};
    const hi = std.math.maxInt(i16);
    const lo = std.math.minInt(i16);
    const c0 = [_]types.Sample(i16){ sf(i16, hi), sf(i16, lo) };
    const c1 = [_]types.Sample(i16){ sf(i16, hi), sf(i16, lo) };
    var o0: [2]types.Sample(i16) = undefined;
    r.process(&c0, &c1, &o0);
    try testing.expectEqual(@as(i16, hi), o0[0].ch[0]); // ~2·max clamps to +max
    try testing.expectEqual(@as(i16, lo), o0[1].ch[0]); // ~2·min clamps to −min
}

test "MatrixRouter coeff override survives between renders (block data, not stream type)" {
    // WHY: coeff is a plain field, set between renders, held until changed — the
    // "coefficients are block data" convention. Set once, run twice with different
    // inputs, and both must use the same coeff.
    const R = pan.MatrixRouter(f32num, 1, 1);
    var r = R{};
    r.coeff = .{.{3.0}};
    const a = [_]types.Sample(f32){sf(f32, 2.0)};
    var oa: [1]types.Sample(f32) = undefined;
    r.process(&a, &oa);
    try testing.expectApproxEqAbs(@as(f32, 6.0), oa[0].ch[0], 1e-6);
    const b = [_]types.Sample(f32){sf(f32, -4.0)};
    var ob: [1]types.Sample(f32) = undefined;
    r.process(&b, &ob);
    try testing.expectApproxEqAbs(@as(f32, -12.0), ob[0].ch[0], 1e-6);
}

// ===========================================================================
// DryWet — linear crossfade.
// ===========================================================================

test "DryWet midpoint is the ARITHMETIC mean, not the equal-power value (linear law)" {
    // WHY: the documented law is LINEAR: out = (1−mix)·dry + mix·wet. At mix=0.5
    // a linear law gives (dry+wet)/2; an equal-power law would give .707·(dry+wet)
    // ≈ 1.414·avg for equal inputs. Pin the average AND assert we are NOT the
    // equal-power value — this is the one test that distinguishes the two laws.
    const D = pan.DryWet(f32num);
    var d = D{};
    d.setParam(0, 0.5);
    const dry = [_]types.Sample(f32){sf(f32, 4.0)};
    const wet = [_]types.Sample(f32){sf(f32, 4.0)};
    var out: [1]types.Sample(f32) = undefined;
    d.process(&dry, &wet, &out);
    try testing.expectApproxEqAbs(@as(f32, 4.0), out[0].ch[0], 1e-6); // (4+4)/2 linear
    // equal-power at 0.5 for equal 4.0 inputs would be .707·4 + .707·4 ≈ 5.657.
    try testing.expect(@abs(out[0].ch[0] - 5.657) > 1.0);
}

test "DryWet is the exact convex blend across a fine mix sweep (independent recompute)" {
    // WHY: pin the full crossfade curve, not just the three anchors, against an
    // independent (1−m)·dry + m·wet. A non-linear interpolation (e.g. squared mix)
    // would match at 0/0.5/1 but diverge in between — this catches that.
    const D = pan.DryWet(f32num);
    const dry: f32 = 3.0;
    const wet: f32 = -5.0;
    var mix: f32 = 0.0;
    while (mix <= 1.0 + 1e-9) : (mix += 0.05) {
        var d = D{};
        d.setParam(0, mix);
        var out: [1]types.Sample(f32) = undefined;
        d.process(&[_]types.Sample(f32){sf(f32, dry)}, &[_]types.Sample(f32){sf(f32, wet)}, &out);
        const want = (1.0 - mix) * dry + mix * wet;
        try testing.expectApproxEqAbs(want, out[0].ch[0], 1e-6);
    }
}

test "DryWet blends each frame of a multi-sample buffer (whole-buffer coverage)" {
    // WHY: the anchor tests use short buffers but the loop must touch every frame
    // with possibly different dry/wet values. Pin a per-frame blend so a kernel
    // that reused frame 0's value would fail.
    const D = pan.DryWet(f32num);
    var d = D{};
    d.setParam(0, 0.25);
    const n = 4;
    var dry: [n]types.Sample(f32) = undefined;
    var wet: [n]types.Sample(f32) = undefined;
    for (0..n) |k| {
        dry[k] = sf(f32, @floatFromInt(k + 1)); // 1,2,3,4
        wet[k] = sf(f32, @floatFromInt(10 * (k + 1))); // 10,20,30,40
    }
    var out: [n]types.Sample(f32) = undefined;
    d.process(&dry, &wet, &out);
    for (0..n) |k| {
        const want = 0.75 * dry[k].ch[0] + 0.25 * wet[k].ch[0];
        try testing.expectApproxEqAbs(want, out[k].ch[0], 1e-6);
    }
}

test "DryWet param port and clamp: mix is held in [0,1] and exposes Scalar(f32)" {
    // WHY: the modulation contract — the param port is Scalar(f32) (so an edge
    // type-checks) and setParam clamps so a wired modulator can never push the
    // blend to extrapolate beyond dry/wet. (The in-file test checks the bare clamp;
    // this also pins the port element identity used by negotiation.)
    const D = pan.DryWet(f32num);
    const Mp = port.ParamPort(D, "mix");
    try testing.expect(Mp.Elem == types.Scalar(f32));
    try testing.expect(comptime port.isParamPort(Mp));
    var d = D{};
    d.setParam(0, 2.5);
    try testing.expectEqual(@as(f32, 1.0), d.mix);
    d.setParam(0, -0.5);
    try testing.expectEqual(@as(f32, 0.0), d.mix);
    // A non-zero slot is ignored (only slot 0 is the mix param).
    d.setParam(0, 0.5);
    d.setParam(7, 0.9);
    try testing.expectEqual(@as(f32, 0.5), d.mix);
}

// ===========================================================================
// Precision genericity — the f64 monomorph computes the same law.
// ===========================================================================

test "the float blocks are precision-generic: f64 SummingMixer/MatrixRouter/DryWet obey the same laws" {
    // WHY: every block is monomorphized over the Numeric trait. Re-running a
    // representative law in f64 (tighter tolerance) proves the kernel is not
    // accidentally f32-pinned and that the wide-Acc path for floats (Acc==Lane) is
    // a plain cast, not a clamp.
    {
        const M = pan.SummingMixer(f64num, 2);
        var m = M{};
        const a = [_]types.Sample(f64){sf(f64, 1.0e10)};
        const b = [_]types.Sample(f64){sf(f64, 2.0e10)};
        var out: [1]types.Sample(f64) = undefined;
        m.process(&a, &b, &out);
        try testing.expectApproxEqAbs(@as(f64, 3.0e10), out[0].ch[0], 1e-3); // no float "saturation"
    }
    {
        const R = pan.MatrixRouter(f64num, 2, 2);
        var r = R{};
        r.coeff = .{ .{ 1.0, 2.0 }, .{ 3.0, 4.0 } };
        const c0 = [_]types.Sample(f64){sf(f64, 1.0)};
        const c1 = [_]types.Sample(f64){sf(f64, 1.0)};
        var o0: [1]types.Sample(f64) = undefined;
        var o1: [1]types.Sample(f64) = undefined;
        r.process(&c0, &c1, &o0, &o1);
        try testing.expectApproxEqAbs(@as(f64, 3.0), o0[0].ch[0], 1e-12); // 1+2
        try testing.expectApproxEqAbs(@as(f64, 7.0), o1[0].ch[0], 1e-12); // 3+4
    }
    {
        const D = pan.DryWet(f64num);
        var d = D{};
        d.setParam(0, 0.3);
        var out: [1]types.Sample(f64) = undefined;
        d.process(&[_]types.Sample(f64){sf(f64, 1.0)}, &[_]types.Sample(f64){sf(f64, 11.0)}, &out);
        // mix is a Scalar(f32) PARAMETER by design, so the blend coefficient is the
        // f32-rounded 0.3 even on an f64 lane; the oracle must round mix through f32
        // too (else the "tight f64" expectation would falsely fail by ~1.2e-7). This
        // pins that the param precision is f32 regardless of the lane precision.
        const m: f64 = @as(f32, 0.3);
        try testing.expectApproxEqAbs((1.0 - m) * 1.0 + m * 11.0, out[0].ch[0], 1e-12);
    }
}
