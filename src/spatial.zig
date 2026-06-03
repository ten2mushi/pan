//! Spatial blocks — `ConstantPowerPan`.
//!
//! `ConstantPowerPan` is the canonical layout-changing `Map`: its input is a
//! mono `Sample(T)` and its output is a stereo `Frame(T,.stereo)`, so the
//! channel layout `L` differs between the input and output ports — a layout
//! change is exactly a morphism whose `Frame`s differ in `L`, type-checked at
//! `connect`. Rate-1:1, stateless ⇒ a `Map`.
//!
//! The stereo output is written through a PLANAR view: the buffer is two
//! contiguous channel planes (an L-plane of N samples followed by an R-plane of
//! N samples), plane-major, not interleaved L,R,L,R frames. The kernel writes
//! the whole L-plane and the whole R-plane directly — each plane is a contiguous
//! `[]T` a per-channel vector loop walks straight through. (Mono input is one
//! plane, so it keeps a plain `[]const Sample(T)` slice port.)
//!
//! The pan law is **constant power**: for a pan position `p ∈ [-1, 1]`
//! (−1 hard-left, 0 center, +1 hard-right), the per-channel gains are
//! `L = cos θ`, `R = sin θ` with `θ = (p + 1)·π/4`, so `L² + R² = 1` for every
//! `p` — the perceived loudness is constant as the source pans (unlike a linear
//! law, which dips ~3 dB at center). Center (`p = 0`) gives `L = R = cos(π/4) =
//! √½ ≈ 0.7071`.

const std = @import("std");
const types = @import("types.zig");
const numeric = @import("numeric.zig");
const simd = @import("simd.zig");

fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}
fn fracBits(comptime T: type) comptime_int {
    return @typeInfo(T).int.bits - 1;
}

/// View a mono `Sample(T)` slice as its underlying scalar `[]T`.
fn scalarsConst(comptime T: type, frames: []const types.Sample(T)) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}

/// `ConstantPowerPan(num)` — mono → stereo constant-power panner. `pan` is the
/// position in `[-1, 1]`; it is recomputed into the two channel gains each
/// render call (held across the buffer, the parameter/control-rate convention),
/// so a future wired `param.pan` or `set(.pan, …)` ramps without a kernel change.
pub fn ConstantPowerPan(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    return struct {
        const Self = @This();
        /// Pan position in [-1, 1]; held across the render buffer. Used to derive
        /// the channel gains unless `gains_q` overrides them.
        pan: f32 = 0,
        /// Optional PRE-QUANTIZED channel gains `[L, R]` in the lane's q-format,
        /// used by the integer path INSTEAD of computing `cos/sin(pan)` at render
        /// time. This is the embedded path (an MCU precomputes the pan gains — no
        /// runtime trig) and the bit-exact-testable path: the kernel applies the
        /// exact integer coefficients given, so an oracle holding the same integers
        /// matches to the bit (a runtime `cos` would differ by ~1 ULP between f32
        /// and an f64 oracle and shift every output sample). Ignored on the float
        /// path, which derives the gains from `pan` directly.
        gains_q: ?[2]T = null,

        pub const params = .{ .pan = types.Scalar(f32) };

        pub fn process(self: *Self, in: []const types.Sample(T), out: types.Planar(T, .stereo)) void {
            std.debug.assert(in.len == out.frames);
            const xs = scalarsConst(T, in);
            // The two output channel planes — each a contiguous []T over the
            // whole buffer (L-plane then R-plane in the plane-major buffer).
            const left = out.plane(0);
            const right = out.plane(1);
            if (comptime isFloat(T)) {
                // Constant-power gains: θ = (p+1)·π/4, L = cos θ, R = sin θ.
                const p = std.math.clamp(self.pan, -1.0, 1.0);
                const theta = (p + 1.0) * (std.math.pi / 4.0);
                const lcoef: T = @floatCast(@cos(theta));
                const rcoef: T = @floatCast(@sin(theta));
                for (xs, left, right) |x, *l, *r| {
                    l.* = x * lcoef;
                    r.* = x * rcoef;
                }
            } else {
                const frac = comptime fracBits(T);
                // Use the supplied q-format gains, else quantize cos/sin(pan).
                const lq: T, const rq: T = if (self.gains_q) |g| .{ g[0], g[1] } else blk: {
                    const p = std.math.clamp(self.pan, -1.0, 1.0);
                    const theta = (p + 1.0) * (std.math.pi / 4.0);
                    const scale: f32 = @floatFromInt(@as(i64, 1) << frac);
                    break :blk .{ @intFromFloat(@round(@cos(theta) * scale)), @intFromFloat(@round(@sin(theta) * scale)) };
                };
                for (xs, left, right) |x, *l, *r| {
                    l.* = simd.qMulStore(T, num.Acc, x, lq, frac);
                    r.* = simd.qMulStore(T, num.Acc, x, rq, frac);
                }
            }
        }
    };
}

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

test "ConstantPowerPan centers to equal √½ gains and is layout-changing mono→stereo" {
    const port = @import("port.zig");
    const Pan = ConstantPowerPan(f32num);
    try testing.expect(port.classify(Pan) == .Map);
    try testing.expect(port.MapInPort(Pan).Elem == types.Sample(f32));
    // The output port's element identity remains the stereo Frame even though
    // the buffer is written through a planar view.
    try testing.expect(port.MapOutPort(Pan).Elem == types.Frame(f32, .stereo));

    var pan = Pan{ .pan = 0 };
    var in: [3]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{0.5} }, .{ .ch = .{-1} } };
    // Plane-major stereo backing: [L0,L1,L2][R0,R1,R2].
    var out_buf: [6]f32 = undefined;
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, 3);
    pan.process(&in, out);
    const root_half: f32 = @sqrt(0.5);
    for (in, out.plane(0), out.plane(1)) |x, l, r| {
        try testing.expectApproxEqAbs(x.ch[0] * root_half, l, 1e-6);
        try testing.expectApproxEqAbs(x.ch[0] * root_half, r, 1e-6);
    }
}

test "ConstantPowerPan preserves power L²+R² across the pan sweep" {
    const Pan = ConstantPowerPan(f32num);
    var pos: f32 = -1.0;
    while (pos <= 1.0) : (pos += 0.25) {
        var pan = Pan{ .pan = pos };
        var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
        var out_buf: [2]f32 = undefined;
        const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
        pan.process(&in, out);
        const lv = out.plane(0)[0];
        const rv = out.plane(1)[0];
        const power = lv * lv + rv * rv;
        try testing.expectApproxEqAbs(@as(f32, 1.0), power, 1e-6);
    }
}

test "hard-left puts all signal in L, hard-right all in R" {
    const Pan = ConstantPowerPan(f32num);
    var left = Pan{ .pan = -1 };
    var right = Pan{ .pan = 1 };
    var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
    var ol_buf: [2]f32 = undefined;
    var orr_buf: [2]f32 = undefined;
    const ol = types.Planar(f32, .stereo).fromBase(&ol_buf, 1);
    const orr = types.Planar(f32, .stereo).fromBase(&orr_buf, 1);
    left.process(&in, ol);
    right.process(&in, orr);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ol.plane(0)[0], 1e-6); // L = cos(0) = 1
    try testing.expectApproxEqAbs(@as(f32, 0.0), ol.plane(1)[0], 1e-6); // R = sin(0) = 0
    try testing.expectApproxEqAbs(@as(f32, 0.0), orr.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), orr.plane(1)[0], 1e-6);
}
