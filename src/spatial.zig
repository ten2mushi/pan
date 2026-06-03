//! Spatial blocks — `ConstantPowerPan`.
//!
//! `ConstantPowerPan` is the canonical layout-changing `Map`: its input is a
//! mono `Sample(T)` and its output is a stereo `Frame(T,.stereo)`, so the
//! channel layout `L` differs between the input and output ports — a layout
//! change is exactly a morphism whose `Frame`s differ in `L`, type-checked at
//! `connect`. Rate-1:1, stateless ⇒ a `Map`.
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
        /// Pan position in [-1, 1]; held across the render buffer.
        pan: f32 = 0,

        pub const params = .{ .pan = types.Scalar(f32) };

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Frame(T, .stereo)) void {
            std.debug.assert(in.len == out.len);
            const xs = scalarsConst(T, in);
            // Constant-power gains: θ = (p+1)·π/4, L = cos θ, R = sin θ.
            const p = std.math.clamp(self.pan, -1.0, 1.0);
            const theta = (p + 1.0) * (std.math.pi / 4.0);
            const gl = @cos(theta);
            const gr = @sin(theta);
            if (comptime isFloat(T)) {
                const lcoef: T = @floatCast(gl);
                const rcoef: T = @floatCast(gr);
                for (xs, out) |x, *o| {
                    o.ch[0] = x * lcoef;
                    o.ch[1] = x * rcoef;
                }
            } else {
                const frac = comptime fracBits(T);
                const scale: f32 = @floatFromInt(@as(i64, 1) << frac);
                const lq: T = @intFromFloat(@round(gl * scale));
                const rq: T = @intFromFloat(@round(gr * scale));
                for (xs, out) |x, *o| {
                    o.ch[0] = simd.qMulStore(T, num.Acc, x, lq, frac);
                    o.ch[1] = simd.qMulStore(T, num.Acc, x, rq, frac);
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
    try testing.expect(port.MapOutPort(Pan).Elem == types.Frame(f32, .stereo));

    var pan = Pan{ .pan = 0 };
    var in: [3]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{0.5} }, .{ .ch = .{-1} } };
    var out: [3]types.Frame(f32, .stereo) = undefined;
    pan.process(&in, &out);
    const root_half: f32 = @sqrt(0.5);
    for (in, out) |x, o| {
        try testing.expectApproxEqAbs(x.ch[0] * root_half, o.ch[0], 1e-6);
        try testing.expectApproxEqAbs(x.ch[0] * root_half, o.ch[1], 1e-6);
    }
}

test "ConstantPowerPan preserves power L²+R² across the pan sweep" {
    const Pan = ConstantPowerPan(f32num);
    var pos: f32 = -1.0;
    while (pos <= 1.0) : (pos += 0.25) {
        var pan = Pan{ .pan = pos };
        var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
        var out: [1]types.Frame(f32, .stereo) = undefined;
        pan.process(&in, &out);
        const power = out[0].ch[0] * out[0].ch[0] + out[0].ch[1] * out[0].ch[1];
        try testing.expectApproxEqAbs(@as(f32, 1.0), power, 1e-6);
    }
}

test "hard-left puts all signal in L, hard-right all in R" {
    const Pan = ConstantPowerPan(f32num);
    var left = Pan{ .pan = -1 };
    var right = Pan{ .pan = 1 };
    var in: [1]types.Sample(f32) = .{.{ .ch = .{1} }};
    var ol: [1]types.Frame(f32, .stereo) = undefined;
    var orr: [1]types.Frame(f32, .stereo) = undefined;
    left.process(&in, &ol);
    right.process(&in, &orr);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ol[0].ch[0], 1e-6); // L = cos(0) = 1
    try testing.expectApproxEqAbs(@as(f32, 0.0), ol[0].ch[1], 1e-6); // R = sin(0) = 0
    try testing.expectApproxEqAbs(@as(f32, 0.0), orr[0].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), orr[0].ch[1], 1e-6);
}
