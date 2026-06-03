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

/// Five normalized biquad coefficients (`a0` divided out): the transfer function
/// `H(z) = (b0 + b1 z⁻¹ + b2 z⁻²) / (1 + a1 z⁻¹ + a2 z⁻²)`. Defaults to the
/// identity (pass-through) section so an un-configured `Biquad` is a no-op.
pub fn Coeffs(comptime T: type) type {
    return struct {
        b0: T = 1,
        b1: T = 0,
        b2: T = 0,
        a1: T = 0,
        a2: T = 0,
    };
}

/// `Biquad(num)` — one second-order IIR section in transposed direct form II.
/// The per-sample recurrence carries two state words across calls (so a render
/// split into sub-blocks is seamless only because the state persists), which is
/// exactly `scipy.signal.lfilter([b0,b1,b2],[1,a1,a2], x)`:
///
///     y   = b0·x + z1
///     z1  = b1·x + z2 − a1·y
///     z2  = b2·x        − a2·y
///
/// Rate-1:1 with per-sample state ⇒ a `Map` (not a `Rate`: it neither buffers
/// across calls nor changes the sample count). The recurrence is sequential, so
/// it neither vectorizes across time nor is `aliasing_safe`.
pub fn Biquad(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    return struct {
        const Self = @This();
        coeffs: Coeffs(T) = .{},
        z1: T = 0,
        z2: T = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const c = self.coeffs;
            if (comptime isFloat(T)) {
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
            } else {
                // A correct fixed-point biquad is NOT a straight q(frac) port:
                // feedback coefficients routinely exceed unity (|a1| can approach
                // 2), so they need a wider coefficient Q-format, intermediate-
                // accumulator headroom, and a scaling/guard-bit scheme that the
                // float path does not. Designing and validating that (bit-exact
                // against a fixed-point oracle) is the embedded-precision phase;
                // shipping a naive q(frac) version here would compute wrong audio
                // for ordinary filters. Fail loud rather than silently wrong.
                @compileError("pan: fixed-point Biquad is not yet supported — a q-format" ++
                    " biquad needs wider coefficient scaling + accumulator headroom" ++
                    " (the embedded-precision phase). Use a float precision (f32/f64).");
            }
        }
    };
}

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

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
    try testing.expect(Gain(f32num).aliasing_safe);
    try testing.expect(!@hasDecl(Biquad(f32num), "aliasing_safe"));
}
