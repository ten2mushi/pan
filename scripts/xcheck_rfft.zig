//! On-demand cross-validation: dump pan's rfftForward of a deterministic analytic
//! signal (re/im per line to stderr), compared to scipy.fft.rfft by xcheck_rfft.py.
//! NOT part of `zig build test` (the hermetic suite uses an in-test naive DFT).
const std = @import("std");
const pan = @import("pan");
pub fn main() void {
    const N = 1024;
    var x: [N]f32 = undefined;
    for (&x, 0..) |*v, n| {
        const t: f32 = @floatFromInt(n);
        v.* = @sin(2.0 * std.math.pi * 3.0 * t / N) + 0.5 * @sin(2.0 * std.math.pi * 7.0 * t / N);
    }
    var bins: [N / 2 + 1]std.math.Complex(f32) = undefined;
    pan.spectral.rfftForward(f32, N, &x, &bins);
    for (bins) |c| std.debug.print("{d} {d}\n", .{ c.re, c.im });
}
