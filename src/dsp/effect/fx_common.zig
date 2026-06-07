//! Shared helpers for the fused-kernel / dynamics block families (the `fx_*`
//! files that `fx.zig` re-exports). These primitives are used by blocks that now
//! live in more than one family file, so they are factored here rather than
//! duplicated.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;
const numeric = core.numeric;

pub fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

/// View a mono `Sample(T)` slice as its underlying scalar `[]T` — `Sample(T)` is
/// `Frame(T,.mono)`, layout-identical to a bare `T`, so the reinterpret is exact.
pub fn scalarsConst(comptime T: type, frames: []const types.Sample(T)) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}
pub fn scalars(comptime T: type, frames: []types.Sample(T)) []T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}

pub fn requireFloat(comptime T: type) void {
    if (!isFloat(T))
        @compileError("pan: fixed-point feedback kernels are not yet supported — limit" ++
            " cycles + coefficient scaling need the per-kernel DF1/wide-accumulator" ++
            " treatment now applied to the fixed-point Biquad (filters.zig); it has" ++
            " not yet been ported to these reverb/synthesis kernels. Use f32/f64.");
}
