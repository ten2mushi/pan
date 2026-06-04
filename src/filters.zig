//! First DSP blocks — `Gain` and `Biquad`.
//!
//! Both are `Map` morphisms (rate-1:1, `out.len == in.len`), monomorphized over
//! a Numeric trait so the precision (lane, accumulator width, saturation, SIMD
//! width) is bound at comptime. A precision change re-selects a monomorph and
//! requires a recommit — there is no runtime precision switch.
//!
//!   - `Gain` is a stateless, per-element scale. It declares `aliasing_safe`:
//!     each output element is written solely from the corresponding input
//!     element, so the colorer may run it in place (output edge aliased onto the
//!     input buffer). Its float path is the `@Vector(W,T)` Compute-HAL kernel
//!     with a scalar tail; its integer path is a saturating fixed-point multiply.
//!   - `Biquad` carries per-sample `z⁻¹` Mealy state (two state words) and is a
//!     transposed-direct-form-II second-order section — the *same* recurrence as
//!     `scipy.signal.lfilter(b, a, x)`, so its float output matches that oracle
//!     within tolerance. Per-sample state keeps it rate-1:1, hence a `Map`, not a
//!     `Rate`; but the recurrence is sequential, so it is NOT `aliasing_safe`
//!     (and does not vectorize across time).

const std = @import("std");
const types = @import("types.zig");
const numeric = @import("numeric.zig");
const simd = @import("simd.zig");
const control = @import("control.zig");

/// Is this lane a floating-point type? Selects the float vs fixed-point kernel.
fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

/// The fixed-point fractional-bit count for an integer lane: i8→q7, i16→q15,
/// i32→q31, i64→q63 (the audio fixed-point convention — full-scale is one bit
/// below the sign). A coefficient `c` in this lane represents `c / 2^frac`.
fn fracBits(comptime T: type) comptime_int {
    return @typeInfo(T).int.bits - 1;
}

/// View a mono `Sample(T)` slice as its underlying scalar `[]T`. `Sample(T)` is
/// `Frame(T,.mono)` = `struct { ch: [1]T }`, layout-identical to a bare `T`, so
/// the reinterpret is exact (and `@alignCast` is safety-checked in Debug).
fn scalarsConst(comptime T: type, frames: []const types.Sample(T)) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}
fn scalars(comptime T: type, frames: []types.Sample(T)) []T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}

/// `Gain(num)` — a per-element scale. `gain` is the coefficient in the lane's
/// own domain: a linear multiplier for a float lane, a `q(frac)` fixed-point
/// coefficient for an integer lane (the author converts dB → the lane domain;
/// e.g. −6 dB → 0.5012 linear, or → round(0.5012·2^frac) for fixed-point).
pub fn Gain(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    return struct {
        const Self = @This();
        /// Coefficient in the lane domain (linear for float; q(frac) for int).
        gain: T = if (isFloat(T)) 1 else (@as(T, 1) << fracBits(T)),
        /// The kernel writes each output element from only the corresponding
        /// input element (no cross-lane read-after-write), so the colorer may
        /// alias the output edge onto the input buffer and run it in place.
        pub const aliasing_safe = true;

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            if (comptime isFloat(T)) {
                simd.scaleFloat(T, num.W, ys, xs, self.gain);
            } else {
                // Saturating fixed-point multiply: (x·coeff) >> frac, rounded to
                // nearest and clamped to the lane bound (never wraps).
                const frac = comptime fracBits(T);
                for (xs, ys) |x, *y| y.* = simd.qMulStore(T, num.Acc, x, self.gain, frac);
            }
        }
    };
}

/// `OnePole(num)` — a one-pole low-pass whose **cutoff is a parameter port**
/// (`onepole.param.cutoff`): the canonical filter swept by an LFO or an envelope.
/// `cutoff` is the per-sample smoothing coefficient `a` in `[0, 1)` in the lane's
/// own domain — the author maps a cutoff frequency to it (e.g. `a = 1 −
/// exp(−2π·fc/Fs)`), the same "coefficients are block data, not the stream type"
/// convention `Gain` and `Biquad` follow. The recurrence is a leaky integrator
///
///     y[n] = y[n−1] + a·(x[n] − y[n−1]),
///
/// so `a → 1` passes the input and `a → 0` freezes the state (a lower cutoff). The
/// coefficient is **held between updates and per-block ramped** toward its target
/// (the anti-zipper "ramp, never step" policy): the latest target is snapped at
/// block end so a multi-block sweep stays continuous. Because a wired parameter edge
/// and an external `set` both deliver the target through `setParam` and drive the
/// SAME held-and-ramped coefficient, a wired LFO→cutoff sweep is **bit-identical** to
/// the same target sequence pushed via `set` (one ramp policy, two sources). It is
/// NOT `aliasing_safe`: the recurrence carries `z⁻¹` state, so the colorer must not
/// run it in place.
///
/// Float lanes only for now: a ramped fixed-point coefficient needs the wider
/// coefficient q-format and wide accumulator the fixed-point `Biquad` uses, which
/// has not been ported here, so the integer path fails loud (a compile error, never
/// silently-wrong audio).
pub fn OnePole(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    if (!isFloat(T))
        @compileError("pan: OnePole is float-only for now — a ramped fixed-point" ++
            " cutoff coefficient needs the q-format + wide-accumulator treatment the" ++
            " fixed-point Biquad uses, not yet ported here. Use f32/f64.");
    return struct {
        const Self = @This();

        /// The cutoff parameter port (control element `Scalar(f32)`). Slot 0.
        pub const params = .{ .cutoff = types.Scalar(f32) };

        /// Latest published target coefficient (atomic; set by the control thread OR
        /// by a wired parameter edge). Read once per block on the RT thread.
        cutoff: control.Param = control.Param.init(1.0),
        /// The live, audibly-applied coefficient, ramped across blocks (persistent).
        a: control.Ramp = control.Ramp.init(1.0),
        /// The one-pole `z⁻¹` state.
        y1: T = 0,

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.cutoff.set(value);
        }

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const tgt = self.cutoff.read();
            const inc = self.a.begin(tgt, xs.len);
            var y1 = self.y1;
            for (xs, ys, 0..) |x, *y, i| {
                const a: T = @floatCast(self.a.value + @as(f32, @floatFromInt(i + 1)) * inc);
                y1 = y1 + a * (x - y1);
                y.* = y1;
            }
            self.y1 = y1;
            self.a.finish(tgt); // snap to the exact target; next block ramps from it
        }
    };
}

/// The fractional-bit count a fixed-point biquad stores its coefficients in. A
/// resonant section's feedback coefficients exceed unity (|a1| can approach 2,
/// |a2| < 1) and the forward gain can exceed 1 too, so the coefficients CANNOT
/// ride in the lane's own q-format (a q15 lane number is bounded to [-1, 1) and
/// could not hold a1 = -1.9 at all). Coefficients instead use Q(2.frac) with two
/// integer bits above the sign — `frac = bits - 3` — giving the range [-4, 4),
/// which covers every stable second-order section with headroom. (This is why a
/// fixed-point biquad needs a wider coefficient format than `Gain`'s single
/// |coeff| ≤ 1 multiply.)
fn biquadCoeffFrac(comptime T: type) comptime_int {
    return @typeInfo(T).int.bits - 3;
}

/// Five normalized biquad coefficients (`a0` divided out): the transfer function
/// `H(z) = (b0 + b1 z⁻¹ + b2 z⁻²) / (1 + a1 z⁻¹ + a2 z⁻²)`. Defaults to the
/// identity (pass-through) section so an un-configured `Biquad` is a no-op.
///
/// For a float lane the fields ARE the real coefficients. For an integer lane the
/// fields are Q(`coeff_frac`) fixed-point integers (range [-4, 4)), so the
/// identity `b0 = 1.0` is the integer `1 << coeff_frac`, not `1`.
pub fn Coeffs(comptime T: type) type {
    const cf: comptime_int = if (isFloat(T)) 0 else biquadCoeffFrac(T);
    return struct {
        b0: T = if (isFloat(T)) 1 else (@as(T, 1) << biquadCoeffFrac(T)),
        b1: T = 0,
        b2: T = 0,
        a1: T = 0,
        a2: T = 0,
        /// The fractional bits the coefficient fields are stored in: 0 for a float
        /// lane (the fields are the real coefficients), `bits - 3` for an integer
        /// lane (the fields are Q(2.frac) fixed-point, range [-4, 4)).
        pub const coeff_frac = cf;
    };
}

/// `Biquad(num)` — one second-order IIR section. Rate-1:1 with per-sample state
/// ⇒ a `Map` (not a `Rate`: it neither buffers across calls nor changes the
/// sample count). The recurrence is sequential, so it neither vectorizes across
/// time nor is `aliasing_safe`. The float and fixed-point lanes use different
/// canonical forms (DF2T vs DF1) — both monomorphized from this one function —
/// because the numerically-robust form differs by domain (see each below).
pub fn Biquad(comptime num: numeric.Numeric) type {
    return if (isFloat(num.Lane)) BiquadFloat(num.Lane) else BiquadFixed(num);
}

/// The float biquad — transposed direct form II, two state words. The per-sample
/// recurrence carries `z1`/`z2` across calls (so a render split into sub-blocks
/// is seamless only because the state persists), which is exactly
/// `scipy.signal.lfilter([b0,b1,b2],[1,a1,a2], x)`:
///
///     y   = b0·x + z1
///     z1  = b1·x + z2 − a1·y
///     z2  = b2·x        − a2·y
fn BiquadFloat(comptime T: type) type {
    return struct {
        const Self = @This();
        coeffs: Coeffs(T) = .{},
        z1: T = 0,
        z2: T = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const c = self.coeffs;
            var z1 = self.z1;
            var z2 = self.z2;
            for (xs, ys) |x, *y| {
                const yv = c.b0 * x + z1;
                z1 = c.b1 * x + z2 - c.a1 * yv;
                z2 = c.b2 * x - c.a2 * yv;
                y.* = yv;
            }
            self.z1 = z1;
            self.z2 = z2;
        }
    };
}

/// The fixed-point biquad — direct form I (DF1), four state words. This is the
/// embedded-precision path the dev-note flagged as deferred; it is now real.
///
/// Three things make a correct fixed-point biquad more than the "multiply,
/// `>>frac`, saturate" mould the `Gain`/`Pan` integer paths use, and each is
/// handled here:
///   1. **Supra-unity coefficients.** A resonant section has |a1| up to ~2, which
///      a plain lane-q-format number (bounded to [-1, 1)) cannot store. The
///      coefficients therefore ride in Q(2.`coeff_frac`) (range [-4, 4)) — a
///      WIDER coefficient format than the lane (`Coeffs` above).
///   2. **Accumulator headroom.** The five-term MAC is summed in a strictly wider
///      integer (`Wide`, ~2× the lane width plus guard bits — i64 for a q15
///      section) so the inter-term partial sums never overflow; a single rounding
///      right-shift + saturate happens only on store. A per-multiply `>>frac` (as
///      `Gain` does) would discard that headroom and compute wrong audio.
///   3. **State at the lane format, not the accumulator format.** DF1 keeps the
///      input history `x1`/`x2` and output history `y1`/`y2` as already-rounded
///      lane values, so the feedback path sees the clean quantized signal. (The
///      float path's DF2T intermediate states would, in fixed point, leak the
///      rounding into the loop and worsen limit-cycle behaviour — hence DF1 here.)
///
/// The accumulator is in Q(lane_frac + coeff_frac); the store shifts right by
/// `coeff_frac` (with a round-to-nearest bias) to land back in the lane's
/// q-format, then saturates. The arithmetic right-shift rounds toward −∞ after a
/// `+2^(coeff_frac−1)` bias (round half up), matching an independent integer
/// oracle bit-for-bit (the q15 gold-vector contract).
fn BiquadFixed(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    const cf = comptime biquadCoeffFrac(T);
    // The MAC accumulator: wide enough for five products of (lane × coeff) plus
    // the rounding bias with guard bits to spare. For i16/q15 this is i36, which
    // the backend lowers to i64 — exactly the "accumulate a q15 section in i64"
    // the fixed-point-IIR design requires.
    const Wide = std.meta.Int(.signed, 2 * @typeInfo(T).int.bits + 4);
    return struct {
        const Self = @This();
        coeffs: Coeffs(T) = .{},
        /// DF1 state: input history (x1, x2) and output history (y1, y2), all in
        /// the lane's own q-format (already rounded/saturated).
        x1: T = 0,
        x2: T = 0,
        y1: T = 0,
        y2: T = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const c = self.coeffs;
            const bias: Wide = comptime (@as(Wide, 1) << (cf - 1));
            const lo: Wide = std.math.minInt(T);
            const hi: Wide = std.math.maxInt(T);
            var x1 = self.x1;
            var x2 = self.x2;
            var y1 = self.y1;
            var y2 = self.y2;
            for (xs, ys) |x, *y| {
                const acc: Wide =
                    @as(Wide, c.b0) * @as(Wide, x) +
                    @as(Wide, c.b1) * @as(Wide, x1) +
                    @as(Wide, c.b2) * @as(Wide, x2) -
                    @as(Wide, c.a1) * @as(Wide, y1) -
                    @as(Wide, c.a2) * @as(Wide, y2);
                // Round to nearest (bias then arithmetic shift), then saturate to
                // the lane bound on store — never wraps.
                const yv: T = @intCast(std.math.clamp((acc + bias) >> cf, lo, hi));
                x2 = x1;
                x1 = x;
                y2 = y1;
                y1 = yv;
                y.* = yv;
            }
            self.x1 = x1;
            self.x2 = x2;
            self.y1 = y1;
            self.y2 = y2;
        }
    };
}

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

test "OnePole(f32) classifies as a Map with a cutoff param; a=1 passes the signal" {
    const port = @import("port.zig");
    const OP = OnePole(f32num);
    try testing.expect(port.classify(OP) == .Map);
    try testing.expect(port.ParamPort(OP, "cutoff").Elem == types.Scalar(f32));
    try testing.expect(!@hasDecl(OP, "aliasing_safe")); // stateful recurrence

    // cutoff coefficient a = 1 (the default) → y[n] = y[n-1] + 1·(x - y[n-1]) = x.
    var op = OP{};
    var in: [4]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{-2} }, .{ .ch = .{3} }, .{ .ch = .{0.5} } };
    var out: [4]types.Sample(f32) = undefined;
    op.process(&in, &out);
    for (in, out) |x, y| try testing.expectApproxEqAbs(x.ch[0], y.ch[0], 1e-6);
}

test "OnePole(f32) a=0.5 step response matches the hand-rolled leaky integrator" {
    const OP = OnePole(f32num);
    var op = OP{};
    op.setParam(0, 0.5); // target coefficient 0.5
    // A unit step; with the per-block ramp a glides 1.0 → 0.5 across the block, so
    // re-derive the SAME ramped recurrence independently and compare bit-for-bit.
    const N = 6;
    var in: [N]types.Sample(f32) = @splat(.{ .ch = .{1} });
    var out: [N]types.Sample(f32) = undefined;
    op.process(&in, &out);

    var ry1: f32 = 0;
    const inc: f32 = (0.5 - 1.0) / @as(f32, N);
    for (out, 0..) |y, i| {
        const a: f32 = 1.0 + @as(f32, @floatFromInt(i + 1)) * inc;
        ry1 = ry1 + a * (1.0 - ry1);
        try testing.expectEqual(ry1, y.ch[0]); // bit-exact vs the independent recurrence
    }
}

test "Gain(f32) scales by its linear coefficient (and defaults to unity)" {
    var unity = Gain(f32num){};
    var in: [5]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{2} }, .{ .ch = .{3} }, .{ .ch = .{4} }, .{ .ch = .{5} } };
    var out: [5]types.Sample(f32) = undefined;
    unity.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);

    var half = Gain(f32num){ .gain = 0.5 };
    half.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
}

test "Biquad(f32) identity coeffs pass the signal through unchanged" {
    var bq = Biquad(f32num){};
    var in: [4]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{-1} }, .{ .ch = .{0.5} }, .{ .ch = .{0} } };
    var out: [4]types.Sample(f32) = undefined;
    bq.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "Biquad(f32) one-pole matches the hand-rolled lfilter recurrence" {
    // A one-pole low-pass: y[n] = b0 x[n] - a1 y[n-1].
    const b0: f32 = 0.2;
    const a1: f32 = -0.8;
    var bq = Biquad(f32num){ .coeffs = .{ .b0 = b0, .a1 = a1 } };
    var in: [6]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{0} }, .{ .ch = .{0} }, .{ .ch = .{0} }, .{ .ch = .{0} }, .{ .ch = .{0} } };
    var out: [6]types.Sample(f32) = undefined;
    bq.process(&in, &out);
    // The closed-form impulse response of this one-pole is the decaying
    // geometric series y[n] = b0 · (−a1)^n (the independent oracle here).
    for (out, 0..) |y, n| {
        const expected = b0 * std.math.pow(f32, -a1, @floatFromInt(n));
        try testing.expectApproxEqAbs(expected, y.ch[0], 1e-6);
    }
}

test "Biquad state carries across calls — a split render equals a whole render" {
    const c = Coeffs(f32){ .b0 = 0.5, .b1 = 0.5, .a1 = -0.3 };
    var whole = Biquad(f32num){ .coeffs = c };
    var split = Biquad(f32num){ .coeffs = c };
    var in: [8]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @floatFromInt(i);
    var ow: [8]types.Sample(f32) = undefined;
    var os: [8]types.Sample(f32) = undefined;
    whole.process(&in, &ow);
    split.process(in[0..3], os[0..3]);
    split.process(in[3..], os[3..]);
    for (ow, os) |a, b| try testing.expectEqual(a.ch[0], b.ch[0]);
}

test "Gain classifies as a Map and is aliasing_safe; Biquad is a Map that is not" {
    const port = @import("port.zig");
    try testing.expect(port.classify(Gain(f32num)) == .Map);
    try testing.expect(port.classify(Biquad(f32num)) == .Map);
    try testing.expect(port.classify(Biquad(q15num)) == .Map);
    try testing.expect(Gain(f32num).aliasing_safe);
    try testing.expect(!@hasDecl(Biquad(f32num), "aliasing_safe"));
    try testing.expect(!@hasDecl(Biquad(q15num), "aliasing_safe"));
}

const q15num = numeric.numericFor(.i16, .{});

test "Biquad(q15) identity coeffs pass the signal through unchanged" {
    // Default coeffs are the integer identity: b0 = 1<<coeff_frac (= 8192 in
    // Q2.13), the rest 0. acc = 8192·x, >>13 == x, so the lane is unchanged.
    var bq = Biquad(q15num){};
    var in: [4]types.Sample(i16) = .{ .{ .ch = .{12345} }, .{ .ch = .{-9000} }, .{ .ch = .{32767} }, .{ .ch = .{-32768} } };
    var out: [4]types.Sample(i16) = undefined;
    bq.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "Biquad(q15) feedback coefficient |a1|>1 is representable and the section is stable" {
    // A1 = -1.709 (raw -14000 in Q2.13) exceeds the lane's [-1,1) range — the very
    // thing a naive q15 biquad could not hold. With a stable pole pair (a2 < 1,
    // |a1| < 1 + a2) the impulse response must DECAY, not blow up. We assert the
    // tail magnitude shrinks below the early response (the limit-cycle/stability
    // sanity the fixed-point IIR needs), an independent property check (not pan's
    // own output replayed).
    var bq = Biquad(q15num){ .coeffs = .{ .b0 = 50, .b1 = 100, .b2 = 50, .a1 = -14000, .a2 = 6500 } };
    var in: [256]types.Sample(i16) = @splat(.{ .ch = .{0} });
    in[0] = .{ .ch = .{20000} }; // an impulse well below full-scale (headroom)
    var out: [256]types.Sample(i16) = undefined;
    bq.process(&in, &out);
    var peak: i32 = 0;
    for (out[0..16]) |s| peak = @max(peak, @as(i32, @abs(s.ch[0])));
    var tail: i32 = 0;
    for (out[200..]) |s| tail = @max(tail, @as(i32, @abs(s.ch[0])));
    try testing.expect(peak > 0); // it responded
    try testing.expect(tail < peak); // and decayed — no runaway / sustained limit cycle
}
