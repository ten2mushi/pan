//! The Numeric trait (catalog §1.4, type-model §4) and the comptime
//! `numericFor` switch over the explicit active-precision list (§9.1).
//!
//! Precision `T` is a COMPTIME kernel parameter (C4): `numericFor` is a
//! comptime switch and the call site uses the `comptime` keyword. A desktop
//! precision change requires a recommit; pan offers no runtime precision
//! switching (catalog §9.1, ⊢ A9).

const std = @import("std");

/// The Numeric trait — precision is more than a bare lane type because
/// integer/fixed-point changes overflow, accumulation, and rounding (the
/// common path on FPU-less MCUs). `Acc` and `saturate` are CORE fields.
pub const Numeric = struct {
    /// element lane: f32, f64, i16(q15), i32(q31), …
    Lane: type,
    /// accumulator width: f32→f32, i16→i32, i32→i64
    Acc: type,
    /// integer ops saturate (+| -| *|) vs wrap
    saturate: bool,
    /// SIMD width for this Lane on this target (from the Compute HAL)
    W: comptime_int,
};

/// The explicit active-precision list (type-model §3). The comptime switch in
/// `numericFor` is exhaustive over this enum; adding a precision is a one-line
/// edit here plus a prong below — the build logs nothing implicitly.
pub const Precision = enum {
    /// f32-internal default (catalog §9.3: covers ~95% of audio).
    f32,
    /// q15 fixed-point — first-class embedded default
    /// ({Lane:i16, Acc:i32, saturate:true}); catalog §9.3.
    q15,
};

/// Resolve the SIMD width for `Lane` on this target via the Compute HAL.
/// `std.simd.suggestVectorLength` returns `null` when SIMD is unavailable
/// (e.g. a freestanding fixed-point target) — then `W = 1` (scalar).
pub fn widthFor(comptime Lane: type) comptime_int {
    return std.simd.suggestVectorLength(Lane) orelse 1;
}

/// COMPTIME switch from a precision tag to a fully-resolved `Numeric` trait.
/// Call with the `comptime` keyword at the use site to make the comptime
/// nature loud (type-model §3 callout).
pub fn numericFor(comptime p: Precision) Numeric {
    return switch (p) {
        .f32 => .{
            .Lane = f32,
            .Acc = f32,
            .saturate = false,
            .W = widthFor(f32),
        },
        .q15 => .{
            .Lane = i16,
            .Acc = i32,
            .saturate = true,
            .W = widthFor(i16),
        },
    };
}

test "numericFor f32 default (catalog §9.3)" {
    const num = comptime numericFor(.f32);
    try std.testing.expect(num.Lane == f32);
    try std.testing.expect(num.Acc == f32);
    try std.testing.expect(num.saturate == false);
    try std.testing.expect(num.W >= 1);
}

test "numericFor q15: Acc=i32, saturate=true (catalog §9.3 embedded default)" {
    const num = comptime numericFor(.q15);
    try std.testing.expect(num.Lane == i16);
    try std.testing.expect(num.Acc == i32);
    try std.testing.expect(num.saturate == true);
    try std.testing.expect(num.W >= 1);
}

// === Yoneda coverage additions =========================================
// `numericFor` is observed by kernels through the four Numeric fields it
// resolves; we characterize it by every observable consequence of the switch
// and by the two structural laws it must obey: EXHAUSTIVENESS over `Precision`
// (type-model §3) and that the float and fixed-point traits are genuinely
// distinct (so a kernel cannot accidentally treat q15 like f32).

test "numericFor is exhaustive over Precision (every tag resolves; type-model §3)" {
    // If a Precision tag were added without a switch prong, this loop would
    // fail to compile — pinning the "exhaustive switch" obligation. We also
    // assert each resolved trait has the field invariants a kernel relies on.
    inline for (std.meta.fields(Precision)) |field| {
        const p = @field(Precision, field.name);
        const num = comptime numericFor(p);
        // Acc must be at least as wide as Lane (accumulation never narrows).
        try std.testing.expect(@bitSizeOf(num.Acc) >= @bitSizeOf(num.Lane));
        // SIMD width is a positive scalar count (scalar fallback => 1).
        try std.testing.expect(num.W >= 1);
    }
}

test "float lanes never saturate; integer lanes do (catalog §1.4 the WHY)" {
    // saturate is the field that flips +|/-|/*| vs +/-/* in a kernel; getting
    // it wrong silently changes overflow behaviour. Pin the float-vs-int rule.
    const f = comptime numericFor(.f32);
    const q = comptime numericFor(.q15);
    try std.testing.expect(@typeInfo(f.Lane) == .float);
    try std.testing.expect(f.saturate == false);
    try std.testing.expect(@typeInfo(q.Lane) == .int);
    try std.testing.expect(q.saturate == true);
}

test "q15 accumulator is strictly wider than its lane (no MAC overflow; §1.4)" {
    // q15 MAC accumulates i16*i16 into i32; the Acc MUST be strictly wider than
    // the lane or a sum-of-products overflows. f32 keeps Acc == Lane.
    const q = comptime numericFor(.q15);
    try std.testing.expect(@bitSizeOf(q.Acc) > @bitSizeOf(q.Lane));
    try std.testing.expectEqual(@as(usize, 16), @bitSizeOf(q.Lane));
    try std.testing.expectEqual(@as(usize, 32), @bitSizeOf(q.Acc));
    const f = comptime numericFor(.f32);
    try std.testing.expect(f.Acc == f.Lane);
}

test "the f32 and q15 traits are distinct in every core field (§1.4)" {
    const f = comptime numericFor(.f32);
    const q = comptime numericFor(.q15);
    try std.testing.expect(f.Lane != q.Lane);
    try std.testing.expect(f.Acc != q.Acc);
    try std.testing.expect(f.saturate != q.saturate);
}

test "numericFor is a pure comptime function (idempotent / deterministic)" {
    // Two evaluations of the same tag resolve to identical types & flags — the
    // switch carries no hidden state (it is a deterministic transform, Rule 5).
    const a = comptime numericFor(.f32);
    const b = comptime numericFor(.f32);
    try std.testing.expect(a.Lane == b.Lane);
    try std.testing.expect(a.Acc == b.Acc);
    try std.testing.expectEqual(a.saturate, b.saturate);
    try std.testing.expectEqual(a.W, b.W);
}

test "widthFor returns a positive scalar width and matches the trait W" {
    // widthFor is the HAL seam: null (no SIMD) collapses to 1, never 0.
    try std.testing.expect(widthFor(f32) >= 1);
    try std.testing.expect(widthFor(i16) >= 1);
    try std.testing.expectEqual(widthFor(f32), (comptime numericFor(.f32)).W);
    try std.testing.expectEqual(widthFor(i16), (comptime numericFor(.q15)).W);
}
