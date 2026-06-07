//! The Numeric trait and the comptime `numericFor` precision switch.
//!
//! Precision is bound at COMPTIME, not at runtime. A kernel is monomorphized
//! per precision because the choice of lane changes the machine code: the SIMD
//! lane type, instruction selection, the accumulator width, and whether
//! integer ops saturate. `numericFor` is therefore a comptime switch and the
//! call site uses the `comptime` keyword to make that loud. The consequence is
//! deliberate: a desktop precision change requires a recommit (it re-selects a
//! monomorph); there is no live runtime precision switch.
//!
//! Precision is more than a bare lane type because integer/fixed-point lanes —
//! the common path on FPU-less MCUs — change overflow, accumulation, and
//! rounding. So `Acc` (the multiply-accumulate width) and `saturate` (clamp vs
//! wrap) are CORE fields of the trait, not an afterthought: a biquad over i16
//! accumulates i16×i16 into i32 and saturates on store, while over f32 it
//! accumulates in f32 and never saturates.

const std = @import("std");

/// The Numeric trait — the fully-resolved numeric behaviour for one precision.
pub const Numeric = struct {
    /// The element lane: f32, f64, i8, i16 (q15), i32 (q31), i64.
    Lane: type,
    /// The multiply-accumulate width. An integer MAC must accumulate into a
    /// strictly wider type or a sum of products overflows; floats accumulate in
    /// their own width. Convention: integer Acc is twice the lane width.
    Acc: type,
    /// Integer ops saturate (`+| -| *|`, clamp at the bound) rather than wrap.
    /// Always false for float lanes (floats have their own overflow semantics).
    saturate: bool,
    /// The SIMD width (lanes per vector) for `Lane` on the build target,
    /// resolved by the Compute HAL. 1 when the target has no SIMD for `Lane`.
    W: comptime_int,
};

/// A precision tag. The set is explicit and the `numericFor` switch is
/// exhaustive over it: adding a precision is a one-line edit here plus a switch
/// prong below. Integer tags name their lane; i16 carries q15 fixed-point
/// semantics and i32 carries q31 (the fixed-point format is the lane's
/// interpretation, not a separate type).
pub const Precision = enum {
    f32,
    f64,
    i8,
    i16,
    i32,
    i64,
};

/// The explicit active-precision list. A build that wants a smaller binary
/// (embedded) narrows this; desktop carries the full set. Exposed so a build
/// step can report how many monomorphs the active set will generate (a
/// precision change must never silently inflate the binary).
pub const active: []const Precision = &.{ .f32, .f64, .i8, .i16, .i32, .i64 };

/// The number of distinct precision monomorphs the active set will generate per
/// kernel. A build step prints this so precision creep is never silent: the
/// binary cost of a pipeline scales with this count.
pub const monomorph_count: usize = active.len;

/// Knobs for `numericFor`. Kept as an options struct (rather than extra
/// positional args) so the call site reads `numericFor(p, .{})` and future
/// target hints are additive without breaking callers.
pub const NumericOptions = struct {
    /// Override the HAL-resolved SIMD width. `null` uses the Compute HAL's
    /// suggestion for the lane; a value pins the width (e.g. force scalar `1`
    /// on a target with no vector unit, or fix a width for a differential test).
    width_override: ?comptime_int = null,
};

/// Resolve the SIMD width for `Lane` on the build target via the Compute HAL.
/// `std.simd.suggestVectorLength` returns null when there is no vector unit for
/// `Lane` (e.g. a freestanding fixed-point target); then the width is 1, which
/// drives a correct scalar fallback.
pub fn widthFor(comptime Lane: type) comptime_int {
    return std.simd.suggestVectorLength(Lane) orelse 1;
}

/// COMPTIME switch from a precision tag (and options) to a fully-resolved
/// Numeric trait. Call with the `comptime` keyword at the use site so the
/// comptime binding is visible. Integer lanes get a 2×-width saturating
/// accumulator; float lanes accumulate in their own width and never saturate.
/// `opts.width_override` pins the SIMD width when set.
pub fn numericFor(comptime p: Precision, comptime opts: NumericOptions) Numeric {
    const base: Numeric = switch (p) {
        .f32 => .{ .Lane = f32, .Acc = f32, .saturate = false, .W = widthFor(f32) },
        .f64 => .{ .Lane = f64, .Acc = f64, .saturate = false, .W = widthFor(f64) },
        .i8 => .{ .Lane = i8, .Acc = i16, .saturate = true, .W = widthFor(i8) },
        .i16 => .{ .Lane = i16, .Acc = i32, .saturate = true, .W = widthFor(i16) },
        .i32 => .{ .Lane = i32, .Acc = i64, .saturate = true, .W = widthFor(i32) },
        .i64 => .{ .Lane = i64, .Acc = i128, .saturate = true, .W = widthFor(i64) },
    };
    return .{
        .Lane = base.Lane,
        .Acc = base.Acc,
        .saturate = base.saturate,
        .W = opts.width_override orelse base.W,
    };
}

test "numericFor f32: float lane, same-width accumulator, no saturation" {
    const num = comptime numericFor(.f32, .{});
    try std.testing.expect(num.Lane == f32);
    try std.testing.expect(num.Acc == f32);
    try std.testing.expect(num.saturate == false);
    try std.testing.expect(num.W >= 1);
}

test "numericFor i16 (q15): i32 accumulator, saturating — the embedded path" {
    const num = comptime numericFor(.i16, .{});
    try std.testing.expect(num.Lane == i16);
    try std.testing.expect(num.Acc == i32);
    try std.testing.expect(num.saturate == true);
    try std.testing.expect(num.W >= 1);
}

test "numericFor width_override pins the SIMD width" {
    const num = comptime numericFor(.f32, .{ .width_override = 1 });
    try std.testing.expectEqual(@as(comptime_int, 1), num.W);
}
