//! The Compute HAL — portable, dependency-free vector kernels over
//! `@Vector(W, T)` with a scalar tail.
//!
//! `W` is the build target's SIMD width for the lane `T`, resolved by the
//! Numeric trait (`std.simd.suggestVectorLength`): the Zig compiler lowers the
//! `@Vector(W, T)` to NEON on Apple Silicon, AVX2/AVX-512 on x86, Helium on
//! Cortex-M55, and scalarizes (still correct) when the target has no vector unit
//! for the lane (then `W == 1` and only the tail loop runs). This is the primary
//! compute path; a runtime-discovered accelerated slot (vDSP/FFTW for FFT and
//! large convolution) is a later, optional hook layered above this, never a
//! dependency of the core.

const std = @import("std");

/// `dst[i] = src[i] * k` for a float lane, vectorized `W` lanes at a time with a
/// scalar tail for the `len % W` remainder. Equal lengths required. The two
/// slices may be the same backing buffer (in-place): each output element is
/// written only from the corresponding input element, with no cross-lane
/// dependency, so an aliased `dst == src` is value-correct.
pub fn scaleFloat(comptime T: type, comptime W: comptime_int, dst: []T, src: []const T, k: T) void {
    std.debug.assert(dst.len == src.len);
    var i: usize = 0;
    if (W > 1) {
        const V = @Vector(W, T);
        const kv: V = @splat(k);
        while (i + W <= src.len) : (i += W) {
            const v: V = src[i..][0..W].*;
            dst[i..][0..W].* = v * kv;
        }
    }
    while (i < src.len) : (i += 1) dst[i] = src[i] * k;
}

/// Round-half-away-from-zero division of a fixed-point product by `2^frac`, then
/// saturate to the lane range — the integer/fixed-point multiply-store step. The
/// product is formed in the wider accumulator `Acc`; the bias `2^(frac-1)` makes
/// the right shift round to nearest (matching the gold-vector generator's
/// `np.rint`-then-clip convention so the lane is bit-exact, not approximate).
pub fn qMulStore(comptime T: type, comptime Acc: type, x: T, coeff: T, comptime frac: comptime_int) T {
    const prod: Acc = @as(Acc, x) * @as(Acc, coeff);
    const bias: Acc = if (frac > 0) (@as(Acc, 1) << (frac - 1)) else 0;
    const shifted: Acc = (prod + bias) >> frac;
    const lo: Acc = std.math.minInt(T);
    const hi: Acc = std.math.maxInt(T);
    const clamped: Acc = @min(@max(shifted, lo), hi);
    return @intCast(clamped);
}

test "scaleFloat matches a scalar reference incl. the tail" {
    const W = 4;
    var src: [10]f32 = undefined;
    for (&src, 0..) |*s, i| s.* = @floatFromInt(i);
    var dst: [10]f32 = undefined;
    scaleFloat(f32, W, &dst, &src, 0.5);
    for (src, dst) |s, d| try std.testing.expectEqual(s * 0.5, d);
}

test "scaleFloat in place (dst == src) is value-correct" {
    var buf: [7]f32 = .{ 1, 2, 3, 4, 5, 6, 7 };
    scaleFloat(f32, 4, &buf, &buf, 2.0);
    try std.testing.expectEqualSlices(f32, &.{ 2, 4, 6, 8, 10, 12, 14 }, &buf);
}

test "qMulStore rounds to nearest" {
    // q15: coeff 0.5 = 16384. round(0.5 · 32767) = 16384.
    try std.testing.expectEqual(@as(i16, 16384), qMulStore(i16, i32, 32767, 16384, 15));
    // Full-scale × full-scale in q15 is (1−2⁻¹⁵)² ≈ 0.99994 → 32766 (just under
    // unity), NOT saturated: a q15 coefficient cannot represent a gain ≥ 1.
    try std.testing.expectEqual(@as(i16, 32766), qMulStore(i16, i32, 32767, 32767, 15));
}

test "qMulStore saturates an out-of-range product at the lane bound" {
    // i8, frac 0: 127·127 = 16129 ≫ 127, clamps to the i8 max (never wraps).
    try std.testing.expectEqual(@as(i8, 127), qMulStore(i8, i16, 127, 127, 0));
    // Negative overflow clamps to the i8 min.
    try std.testing.expectEqual(@as(i8, -128), qMulStore(i8, i16, 127, -127, 0));
}
