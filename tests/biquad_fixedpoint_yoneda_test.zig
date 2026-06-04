//! Fixed-point Biquad — the behavioral DEFINITION of `BiquadFixed` in
//! `src/filters.zig`, written the Yoneda way: characterize the kernel by every
//! morphism that pins its meaning (the DF1 recurrence, the wide MAC, the
//! round-to-nearest store, saturation, supra-unity feedback, per-sample state),
//! so any implementation passing all of these is functionally equivalent to the
//! one under test.
//!
//! COMPARISON DISCIPLINE: an integer / fixed-point lane is ALWAYS compared
//! BIT-EXACT, never under tolerance. The defining oracle is an INDEPENDENT
//! integer DF1 reference (`refBiquad` below) re-derived in pure Zig from the
//! documented spec: coefficients in Q(2.cf) with cf = bits-3; the five-term MAC
//! summed in an unbounded-headroom wide signed integer; a round-to-nearest
//! (round-half-up via a `+2^(cf-1)` bias then a floor/arithmetic right shift by
//! cf); saturate-to-lane on store; DF1 state x1,x2,y1,y2 at the lane q-format.
//! The reference is NOT pan's kernel re-run — it is a separate re-derivation of
//! the SAME spec-defined arithmetic, which is exactly what "bit-exact for
//! fixed-point" means (Rule 9 / catalog §0.1).
//!
//! To keep the reference a genuine cross-check rather than a transcription of
//! the kernel's exact expression, the floor right-shift is computed WITHOUT a
//! native arithmetic `>>`: `refShiftRound` derives floor(q / 2^cf) from an
//! unsigned magnitude divide with a sign-aware correction, so a kernel bug in
//! the shift/round/sign handling cannot be masked by sharing the same idiom.
//!
//! Verified against zig 0.16.0 with the `zig-0-16` skill loaded (project Rules
//! 13/14). Diagnostics on a deliberate mismatch path are not used here — every
//! assertion is a hard bit-exact equality.

const std = @import("std");
const pan = @import("pan");
const testing = std.testing;

// ===========================================================================
// Independent integer DF1 reference (the oracle). Pure Zig, re-derived from the
// spec — deliberately NOT structured like the kernel's expression.
// ===========================================================================

/// The coefficient fractional-bit count for an integer lane `T`: Q(2.cf) with
/// two integer bits above the sign, cf = bits-3 (q15 → Q2.13). Re-derived here
/// from the documented convention, not imported from the kernel.
fn refCoeffFrac(comptime T: type) comptime_int {
    return @typeInfo(T).int.bits - 3;
}

/// floor(q / 2^cf) computed WITHOUT a signed arithmetic right shift, so the
/// reference does not merely echo the kernel's `>>`. For non-negative q it is a
/// plain logical shift; for negative q it is the magnitude shift rounded toward
/// −∞ (floor), which equals `-ceil(|q| / 2^cf) = -((|q| + 2^cf - 1) >> cf)`.
/// This reproduces Zig's signed `>>` (an arithmetic, floor-rounding shift) by an
/// independent route, so a sign-handling bug in either side is exposed.
fn refShiftRound(comptime Wide: type, q: Wide, comptime cf: comptime_int) Wide {
    const U = std.meta.Int(.unsigned, @typeInfo(Wide).int.bits);
    if (q >= 0) {
        const mag: U = @intCast(q);
        return @intCast(mag >> cf);
    }
    // q < 0: floor toward −∞. magnitude = -q (safe: |minInt| fits because Wide
    // has guard bits well beyond any value reachable here).
    const mag: U = @intCast(-q);
    const step: U = @as(U, 1) << cf;
    const ceil_div: U = (mag + step - 1) >> cf;
    const res: Wide = @intCast(ceil_div);
    return -res;
}

/// Independent DF1 over one mono lane stream. `Wide` is chosen with ample
/// headroom (matching the kernel's 2*bits+4) so the MAC never overflows; the
/// per-sample store rounds half-up (bias) then floor-shifts by cf, then
/// saturates to [minInt(T), maxInt(T)]. Re-derived from the spec text, not the
/// kernel source.
fn refBiquad(
    comptime T: type,
    b0: T,
    b1: T,
    b2: T,
    a1: T,
    a2: T,
    xs: []const T,
    ys: []T,
) void {
    const cf = comptime refCoeffFrac(T);
    const Wide = std.meta.Int(.signed, 2 * @typeInfo(T).int.bits + 4);
    const bias: Wide = @as(Wide, 1) << (cf - 1);
    const lo: Wide = std.math.minInt(T);
    const hi: Wide = std.math.maxInt(T);

    var x1: Wide = 0;
    var x2: Wide = 0;
    var y1: Wide = 0;
    var y2: Wide = 0;

    for (xs, ys) |x, *y| {
        const xn: Wide = x;
        // Forward (zeros) plus feedback (poles). a-terms subtract — the
        // normalized H(z) = (b0 + b1 z⁻¹ + b2 z⁻²)/(1 + a1 z⁻¹ + a2 z⁻²).
        const fwd: Wide = @as(Wide, b0) * xn + @as(Wide, b1) * x1 + @as(Wide, b2) * x2;
        const fb: Wide = @as(Wide, a1) * y1 + @as(Wide, a2) * y2;
        const acc: Wide = fwd - fb;
        const rounded: Wide = refShiftRound(Wide, acc + bias, cf);
        const sat: Wide = if (rounded < lo) lo else if (rounded > hi) hi else rounded;
        const yv: T = @intCast(sat);
        x2 = x1;
        x1 = xn;
        y2 = y1;
        y1 = yv;
        y.* = yv;
    }
}

// ===========================================================================
// Test scaffolding — frame the scalar lanes and run pan's real kernel.
// ===========================================================================

fn S(comptime T: type, v: T) pan.types.Sample(T) {
    return .{ .ch = .{v} };
}

/// Run pan's `Biquad(numericFor(p))` over `xs` with the given Q(2.cf) coeffs,
/// returning the raw lane outputs into `got`. The block is run as a single
/// whole-buffer render (unless a test deliberately splits).
fn runKernel(
    comptime p: pan.Precision,
    comptime T: type,
    b0: T,
    b1: T,
    b2: T,
    a1: T,
    a2: T,
    xs: []const T,
    got: []T,
) void {
    const num = comptime pan.numericFor(p, .{});
    const Bq = pan.filters.Biquad(num);
    const allocator = testing.allocator;
    const in = allocator.alloc(pan.types.Sample(T), xs.len) catch unreachable;
    defer allocator.free(in);
    const out = allocator.alloc(pan.types.Sample(T), xs.len) catch unreachable;
    defer allocator.free(out);
    for (xs, in) |v, *s| s.* = S(T, v);
    var bq = Bq{ .coeffs = .{ .b0 = b0, .b1 = b1, .b2 = b2, .a1 = a1, .a2 = a2 } };
    bq.process(in, out);
    for (out, got) |s, *g| g.* = s.ch[0];
}

/// The central bit-exact check: pan's kernel over `xs` (q15 lane) equals the
/// independent integer DF1 reference, sample-for-sample.
fn expectKernelMatchesRef(
    comptime p: pan.Precision,
    comptime T: type,
    b0: T,
    b1: T,
    b2: T,
    a1: T,
    a2: T,
    xs: []const T,
) !void {
    const allocator = testing.allocator;
    const got = try allocator.alloc(T, xs.len);
    defer allocator.free(got);
    const want = try allocator.alloc(T, xs.len);
    defer allocator.free(want);
    runKernel(p, T, b0, b1, b2, a1, a2, xs, got);
    refBiquad(T, b0, b1, b2, a1, a2, xs, want);
    try testing.expectEqualSlices(T, want, got);
}

/// A deterministic pseudo-random q15 signal in [minInt, maxInt] (xorshift, no
/// allocator). Full lane range so the MAC and saturation paths are exercised.
fn fillNoiseQ15(buf: []i16, seed: u64) void {
    var s: u64 = seed | 1;
    for (buf) |*v| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        v.* = @bitCast(@as(u16, @truncate(s)));
    }
}

const q15 = pan.numericFor(.i16, .{});
const Q15Coeffs = pan.filters.Coeffs(i16);

// ===========================================================================
// 1. The Coeffs trait — defaults and the lane-aware fractional format.
// ===========================================================================

test "fixed-point biquad: Coeffs(i16) defaults to the integer identity and exposes Q2.13 (catalog §1.4)" {
    const c = Q15Coeffs{};
    // The integer identity is b0 = 1<<coeff_frac (8192 in Q2.13), the rest 0 —
    // NOT b0 = 1 (which would be 2^-13, near-silence). This pins that the default
    // section is a true pass-through in the wider coefficient format.
    try testing.expectEqual(@as(comptime_int, 13), Q15Coeffs.coeff_frac);
    try testing.expectEqual(@as(i16, 8192), c.b0);
    try testing.expectEqual(@as(i16, 1) << 13, c.b0);
    try testing.expectEqual(@as(i16, 0), c.b1);
    try testing.expectEqual(@as(i16, 0), c.b2);
    try testing.expectEqual(@as(i16, 0), c.a1);
    try testing.expectEqual(@as(i16, 0), c.a2);
}

test "fixed-point biquad: Coeffs(i8) is Q2.5 and Coeffs(i32) is Q2.29 (the format scales with the lane)" {
    // cf = bits - 3: i8 → 5, i32 → 29. The identity b0 follows.
    try testing.expectEqual(@as(comptime_int, 5), pan.filters.Coeffs(i8).coeff_frac);
    try testing.expectEqual(@as(i8, 1) << 5, (pan.filters.Coeffs(i8){}).b0);
    try testing.expectEqual(@as(comptime_int, 29), pan.filters.Coeffs(i32).coeff_frac);
    try testing.expectEqual(@as(i32, 1) << 29, (pan.filters.Coeffs(i32){}).b0);
}

// ===========================================================================
// 2. Identity / pass-through — the b0 = 1<<cf section is a no-op.
// ===========================================================================

test "fixed-point biquad: identity coeffs pass the signal through unchanged, incl. lane bounds (catalog §1.4)" {
    // acc = 8192·x, +bias (4096), >>13 == x for every representable x (the bias
    // never tips an exact multiple of 8192 across a boundary). Includes both lane
    // extremes to prove the store does not clip the identity.
    const xs = [_]i16{ 0, 1, -1, 12345, -9000, 32767, -32768, 16384, -16384 };
    var got: [xs.len]i16 = undefined;
    runKernel(.i16, i16, 8192, 0, 0, 0, 0, &xs, &got);
    try testing.expectEqualSlices(i16, &xs, &got);
}

test "fixed-point biquad: identity equals the independent reference (definitional cross-check)" {
    var xs: [128]i16 = undefined;
    fillNoiseQ15(&xs, 0xA1);
    try expectKernelMatchesRef(.i16, i16, 8192, 0, 0, 0, 0, &xs);
}

// ===========================================================================
// 3. Pure feed-forward — degenerate sections pin the b-path independently.
// ===========================================================================

test "fixed-point biquad: pure b0 scale (no poles) equals a rounded q-multiply (catalog §1.3)" {
    // a1=a2=b1=b2=0 ⇒ y = round(b0·x / 2^cf). b0 = 4096 (=0.5 in Q2.13) halves
    // with round-half-up. Reference handles the rounding; we also spot-check the
    // exact half-way value 8191 → (8191*4096 + 4096)>>13 = floor(4096.5)=4096.
    const xs = [_]i16{ 0, 1, -1, 2, -2, 8191, -8191, 32767, -32768 };
    var got: [xs.len]i16 = undefined;
    runKernel(.i16, i16, 4096, 0, 0, 0, 0, &xs, &got);
    var want: [xs.len]i16 = undefined;
    refBiquad(i16, 4096, 0, 0, 0, 0, &xs, &want);
    try testing.expectEqualSlices(i16, &want, &got);
    // Independent closed-form spot-checks of the round-half-up store:
    // x=1: (4096 + 4096)>>13 = 1. x=-1: (-4096 + 4096)>>13 = 0 (half rounds up).
    try testing.expectEqual(@as(i16, 1), got[1]);
    try testing.expectEqual(@as(i16, 0), got[2]);
}

test "fixed-point biquad: feed-forward FIR (b0,b1,b2 only) matches the reference over full-scale noise" {
    var xs: [200]i16 = undefined;
    fillNoiseQ15(&xs, 0xBEEF);
    // A symmetric 3-tap FIR-ish set in Q2.13 (≈0.25, 0.5, 0.25), no feedback.
    try expectKernelMatchesRef(.i16, i16, 2048, 4096, 2048, 0, 0, &xs);
}

// ===========================================================================
// 4. Supra-unity feedback — the whole point of the Q(2.cf) coefficient format.
// ===========================================================================

test "fixed-point biquad: |a1|>1 representable, DF1 recurrence bit-exact vs independent ref (catalog §1.4/§9.3)" {
    // a1 = -14000 in Q2.13 is ≈ -1.709 — below the q15 ±1.0 boundary (8192), a
    // value a plain q15 lane number CANNOT hold. The Q2.13 coefficient format
    // carries it, and the recurrence must be bit-exact against the independent
    // integer DF1 reference (which re-derives the same arithmetic).
    try testing.expect(-14000 < -(@as(i32, 1) << 13)); // |a1| > 1.0 in Q2.13
    var xs: [300]i16 = @splat(0);
    xs[0] = 20000; // impulse below full-scale (headroom)
    try expectKernelMatchesRef(.i16, i16, 50, 100, 50, -14000, 6500, &xs);
}

test "fixed-point biquad: supra-unity stable pole pair over full-scale noise is bit-exact (catalog §9.3)" {
    // Same supra-unity, stable section but driven by full-scale white noise — the
    // continuous excitation keeps the feedback state large, exercising every term
    // of the wide MAC every sample. Bit-exact vs the independent reference.
    var xs: [512]i16 = undefined;
    fillNoiseQ15(&xs, 0xC0DE);
    try expectKernelMatchesRef(.i16, i16, 600, 1200, 600, -14000, 6500, &xs);
}

test "fixed-point biquad: a stable supra-unity section's impulse response DECAYS (no runaway)" {
    // An independent qualitative invariant the recurrence must satisfy: with a
    // stable pole pair (|a2|<1, |a1|<1+a2 in real terms) the impulse tail decays
    // far below the early response — no sustained limit cycle / blow-up.
    const xs = blk: {
        var b: [400]i16 = @splat(0);
        b[0] = 20000;
        break :blk b;
    };
    var got: [400]i16 = undefined;
    runKernel(.i16, i16, 50, 100, 50, -14000, 6500, &xs, &got);
    var peak: i32 = 0;
    for (got[0..32]) |s| peak = @max(peak, @as(i32, @abs(s)));
    var tail: i32 = 0;
    for (got[350..]) |s| tail = @max(tail, @as(i32, @abs(s)));
    try testing.expect(peak > 0); // it responded
    try testing.expect(tail < peak); // and decayed
}

// ===========================================================================
// 5. Accumulator headroom & saturation — full-scale worst case never wraps.
// ===========================================================================

test "fixed-point biquad: full-scale input + max-magnitude coeffs SATURATE cleanly, never wrap (catalog §9.1)" {
    // Worst case for the MAC: every lane state at full-scale magnitude and every
    // coefficient near the Q2.13 max (≈3.999, raw 32767). The five-term sum is
    // ~5 * 32767 * 32767 ≈ 5.4e9, far beyond i32 — the i36/i64 wide accumulator
    // must hold it, and the store must saturate to the lane bound (never wrap to
    // a small or opposite-sign value). We assert the kernel equals the ref AND
    // that the saturated samples sit exactly at a lane extreme.
    var xs: [64]i16 = @splat(32767);
    // alternate sign to keep the feedback pumping toward both rails
    for (&xs, 0..) |*v, i| v.* = if (i % 2 == 0) 32767 else -32768;
    try expectKernelMatchesRef(.i16, i16, 32767, 32767, 32767, -32767, -32767, &xs);

    var got: [64]i16 = undefined;
    runKernel(.i16, i16, 32767, 32767, 32767, -32767, -32767, &xs, &got);
    // At least one output must be clamped to a rail (proving saturation engaged),
    // and NO output may be the wrap artifact a too-narrow accumulator would give.
    var saw_rail = false;
    for (got) |s| {
        if (s == 32767 or s == -32768) saw_rail = true;
    }
    try testing.expect(saw_rail);
}

test "fixed-point biquad: positive overflow clamps to maxInt, negative to minInt (store saturation)" {
    // A degenerate large feed-forward gain on a full-scale input overflows the
    // lane on store: b0 = 32767 (≈4.0), x = 32767 ⇒ acc ≈ 1.07e9, >>13 ≈ 131068,
    // clamps to +32767. With x = -32768 it clamps to -32768. No wrap.
    {
        const xs = [_]i16{32767};
        var got: [1]i16 = undefined;
        runKernel(.i16, i16, 32767, 0, 0, 0, 0, &xs, &got);
        try testing.expectEqual(@as(i16, 32767), got[0]);
    }
    {
        const xs = [_]i16{-32768};
        var got: [1]i16 = undefined;
        runKernel(.i16, i16, 32767, 0, 0, 0, 0, &xs, &got);
        try testing.expectEqual(@as(i16, -32768), got[0]);
    }
}

// ===========================================================================
// 6. Round-to-nearest at the half-way boundary — the bias/shift convention.
// ===========================================================================

test "fixed-point biquad: round-half-UP at the exact .5 boundary (positive and negative)" {
    // The store is (acc + 2^(cf-1)) >> cf with a FLOOR shift ⇒ round-half-toward
    // +∞ (not half-to-even, not toward-zero). Construct accs landing exactly on a
    // half-LSB and assert the documented direction, via b0 only (no feedback).
    //
    // cf = 13, bias = 4096. Choose b0 = 1 (Q2.13 value 2^-13) so acc = x.
    //   x = 4096  → (4096 + 4096) >> 13 = 8192>>13 = 1.   (+0.5 rounds UP to 1)
    //   x = -4096 → (-4096 + 4096) >> 13 = 0.             (-0.5 rounds UP to 0)
    //   x = 12288 → (12288 + 4096) >> 13 = 16384>>13 = 2. (+1.5 rounds UP to 2)
    //   x = -12288→ (-12288 + 4096) >> 13 = -8192>>13 = -1.(-1.5 rounds UP to -1)
    const xs = [_]i16{ 4096, -4096, 12288, -12288 };
    var got: [xs.len]i16 = undefined;
    runKernel(.i16, i16, 1, 0, 0, 0, 0, &xs, &got);
    try testing.expectEqualSlices(i16, &.{ 1, 0, 2, -1 }, &got);
    // And the independent reference must agree at these adversarial points.
    var want: [xs.len]i16 = undefined;
    refBiquad(i16, 1, 0, 0, 0, 0, &xs, &want);
    try testing.expectEqualSlices(i16, &want, &got);
}

test "fixed-point biquad: just-below and just-above the half boundary round correctly" {
    // b0 = 1 ⇒ acc = x. cf=13, bias=4096.
    //   x = 4095 → (4095+4096)>>13 = 8191>>13 = 0  (just under +0.5 → 0)
    //   x = 4097 → (4097+4096)>>13 = 8193>>13 = 1  (just over  +0.5 → 1)
    //   x = -4097→ (-4097+4096)>>13 = -1>>13 = -1 (floor) (just under -0.5 → -1)
    //   x = -4095→ (-4095+4096)>>13 = 1>>13 = 0   (just over  -0.5 → 0)
    const xs = [_]i16{ 4095, 4097, -4097, -4095 };
    var got: [xs.len]i16 = undefined;
    runKernel(.i16, i16, 1, 0, 0, 0, 0, &xs, &got);
    try testing.expectEqualSlices(i16, &.{ 0, 1, -1, 0 }, &got);
}

// ===========================================================================
// 7. Per-sample state persistence — split render ≡ whole render (bit-exact).
// ===========================================================================

test "fixed-point biquad: a split render equals a whole render, bit-exact (state persists across calls)" {
    const num = comptime pan.numericFor(.i16, .{});
    const Bq = pan.filters.Biquad(num);
    const c = Q15Coeffs{ .b0 = 600, .b1 = 1200, .b2 = 600, .a1 = -14000, .a2 = 6500 };

    var xs: [97]i16 = undefined; // prime length ⇒ ragged final chunk
    fillNoiseQ15(&xs, 0x5151);

    var in: [97]pan.types.Sample(i16) = undefined;
    for (xs, &in) |v, *s| s.* = S(i16, v);

    var whole = Bq{ .coeffs = c };
    var whole_out: [97]pan.types.Sample(i16) = undefined;
    whole.process(&in, &whole_out);

    // Ragged split boundaries (11, 29, then the rest) so carried state truly
    // spans irregular chunks — including the x/y history across the seams.
    var split = Bq{ .coeffs = c };
    var split_out: [97]pan.types.Sample(i16) = undefined;
    split.process(in[0..11], split_out[0..11]);
    split.process(in[11..40], split_out[11..40]);
    split.process(in[40..], split_out[40..]);

    for (whole_out, split_out) |a, b| try testing.expectEqual(a.ch[0], b.ch[0]);
}

test "fixed-point biquad: one-sample-at-a-time equals the whole render (finest state granularity)" {
    const num = comptime pan.numericFor(.i16, .{});
    const Bq = pan.filters.Biquad(num);
    const c = Q15Coeffs{ .b0 = 700, .b1 = 100, .a1 = -9000, .a2 = 5000 };

    var xs: [48]i16 = undefined;
    fillNoiseQ15(&xs, 0x1234);
    var in: [48]pan.types.Sample(i16) = undefined;
    for (xs, &in) |v, *s| s.* = S(i16, v);

    var whole = Bq{ .coeffs = c };
    var whole_out: [48]pan.types.Sample(i16) = undefined;
    whole.process(&in, &whole_out);

    var step = Bq{ .coeffs = c };
    var step_out: [48]pan.types.Sample(i16) = undefined;
    for (0..48) |i| step.process(in[i .. i + 1], step_out[i .. i + 1]);

    for (whole_out, step_out) |a, b| try testing.expectEqual(a.ch[0], b.ch[0]);
}

test "fixed-point biquad: empty input is a no-op and leaves state untouched" {
    const num = comptime pan.numericFor(.i16, .{});
    const Bq = pan.filters.Biquad(num);
    var bq = Bq{ .coeffs = .{ .b0 = 700, .a1 = -9000, .a2 = 5000 } };
    var empty_in: [0]pan.types.Sample(i16) = .{};
    var empty_out: [0]pan.types.Sample(i16) = .{};
    bq.process(&empty_in, &empty_out);
    // State words remain at their initial zero (no sample advanced the history).
    try testing.expectEqual(@as(i16, 0), bq.x1);
    try testing.expectEqual(@as(i16, 0), bq.y1);
}

// ===========================================================================
// 8. Other integer lanes — the kernel is generic over the lane (i8 / i32).
// ===========================================================================

test "fixed-point biquad: i8 lane (Q2.5 coeffs) matches the independent reference bit-exact" {
    // The kernel is generic over the lane: i8 → coeff_frac 5, Wide = i20. Identity
    // b0 = 1<<5 = 32, plus a small supra-unity feedback in Q2.5 (a1 = -40 ≈ -1.25,
    // |a1|>1 again), driven by an i8 impulse.
    var xs: [64]i8 = @splat(0);
    xs[0] = 100;
    xs[1] = -80;
    xs[2] = 60;
    try expectKernelMatchesRef(.i8, i8, 32, 0, 0, -40, 20, &xs);
}

test "fixed-point biquad: i8 full-scale saturation never wraps" {
    var xs: [40]i8 = undefined;
    var s: u64 = 0xF00D;
    for (&xs) |*v| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        v.* = @bitCast(@as(u8, @truncate(s)));
    }
    // Near-max Q2.5 coeffs (127 ≈ 3.97) on full-scale i8 input → heavy clipping.
    try expectKernelMatchesRef(.i8, i8, 127, 127, 127, -127, -127, &xs);
}

test "fixed-point biquad: i32 lane (Q2.29 coeffs) matches the independent reference bit-exact" {
    // i32 → coeff_frac 29, Wide = i68. Identity b0 = 1<<29, small feedback. The
    // accumulator headroom claim is most load-bearing here (products are ~2^61).
    var xs: [128]i32 = undefined;
    var s: u64 = 0xABCDEF;
    for (&xs) |*v| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        v.* = @bitCast(@as(u32, @truncate(s)));
    }
    const ident: i32 = @as(i32, 1) << 29;
    // a1 supra-unity in Q2.29: -(1<<29) - (1<<27) ≈ -1.25.
    const a1: i32 = -(@as(i32, 1) << 29) - (@as(i32, 1) << 27);
    const a2: i32 = @as(i32, 1) << 28; // ≈ 0.5
    try expectKernelMatchesRef(.i32, i32, ident, 0, 0, a1, a2, &xs);
}

// ===========================================================================
// 9. Port classification — fixed-point Biquad is a Map, not aliasing_safe.
// ===========================================================================

test "fixed-point biquad: classifies as a Map and is NOT aliasing_safe (sequential recurrence)" {
    const Bq = pan.filters.Biquad(q15);
    try testing.expect(pan.classify(Bq) == .Map);
    try testing.expect(!@hasDecl(Bq, "aliasing_safe"));
}
