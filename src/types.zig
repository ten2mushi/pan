//! Canonical port elements (catalog §1.3, type-model §1).
//!
//! Every edge in a pan graph carries one of these as its element type `A`.
//! Non-primitive elements expose a `typeName()` getter (the feasibility
//! constraint witnessed by ZigRadio's `types.zig`: a *bare* `[K]f32` has no
//! type name and is rejected; hence the named-struct wrappers below).
//!
//! All multi-element forms are PLANAR internally (catalog §9.3, LOCKED).

const std = @import("std");

/// `Sample(T)` — one audio sample of precision `T`.
///
/// Per catalog §1.3, `Sample(T)` is the `C == 1` case of `Frame`, and the
/// identity `Sample(T) == Frame(Lane, 1)` must hold. We therefore *define*
/// `Sample(T)` as exactly `Frame(T, 1)` rather than as a separate struct, so
/// the identity is true by construction (⊢) — see the test at the bottom of
/// this file. A `Sample` is thus a named struct `{ ch: [1]T }` and carries a
/// `typeName()`, satisfying the §1.3 convention for every element.
pub fn Sample(comptime T: type) type {
    return Frame(T, 1);
}

/// `Frame(Lane, C)` — one `C`-channel audio frame, planar (catalog §1.3).
///
/// Named struct `{ ch: [C]Lane }` so it carries a `typeName()`. `C` is comptime
/// in the type, so a channel-changing block is one whose in/out `Frame` differ
/// in `C` only; a channel-count mismatch between wired ports is a type error
/// (⊢ via the typed `PortId`).
pub fn Frame(comptime Lane: type, comptime C: usize) type {
    return struct {
        ch: [C]Lane,

        const Self = @This();

        /// The channel count is part of the element identity (pool class key
        /// `(Frame(Lane,C), N)`); exposed for the commit pass / pool keying.
        pub const channel_count = C;
        pub const lane = Lane;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Frame({s},{d})", .{ @typeName(Lane), C });
        }
    };
}

/// `Complex(T)` — one spectral bin (catalog §1.3). `std.math.Complex(T)` has no
/// `typeName()` of its own, so we wrap it in a named struct carrying one. Pool
/// class key `(Complex(T), N/2+1)`.
pub fn Complex(comptime T: type) type {
    return struct {
        z: std.math.Complex(T),

        const Self = @This();
        pub const lane = T;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Complex({s})", .{@typeName(T)});
        }
    };
}

/// `FeatureFrame(K)` — a fixed-`K` feature vector (catalog §1.3). Named struct
/// `{ v: [K]f32 }` (a bare `[K]f32` has no `typeName()` and is rejected). Pool
/// class key `(FeatureFrame(K), 1)`.
pub fn FeatureFrame(comptime K: usize) type {
    return struct {
        v: [K]f32,

        const Self = @This();
        pub const feature_count = K;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("FeatureFrame({d})", .{K});
        }
    };
}

/// `Scalar(T)` — one scalar feature (centroid, flux, RMS, …). Named struct so
/// it carries a `typeName()`. Pool class key `(Scalar(T), 1)`.
pub fn Scalar(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();
        pub const lane = T;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Scalar({s})", .{@typeName(T)});
        }
    };
}

/// `Bounded(T, Kmax)` — a ragged list with fixed capacity `Kmax` and variable
/// `len` (catalog §1.3). Liveness is over the fixed `[Kmax]` storage, so
/// coloring is unaffected by `len`; correctness is the consumer respecting
/// `len`. Pool class key `(Bounded(T,Kmax), 1)`.
pub fn Bounded(comptime T: type, comptime Kmax: usize) type {
    return struct {
        items: [Kmax]T,
        len: u16,

        const Self = @This();
        pub const capacity = Kmax;
        pub const lane = T;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Bounded({s},{d})", .{ @typeName(T), Kmax });
        }
    };
}

test "Sample(T) == Frame(Lane,1) — the canonical identity (catalog §1.3, ⊢)" {
    // This is the load-bearing identity from §1.3: a mono kernel and a
    // Frame(Lane,1) kernel are the *same thing*. Asserting type identity here
    // discharges it by construction.
    try std.testing.expect(Sample(f32) == Frame(f32, 1));
    try std.testing.expect(Sample(i16) == Frame(i16, 1));
}

test "every non-primitive element carries a typeName() (catalog §1.3 convention)" {
    try std.testing.expectEqualStrings("Frame(f32,2)", Frame(f32, 2).typeName());
    try std.testing.expectEqualStrings("FeatureFrame(13)", FeatureFrame(13).typeName());
    try std.testing.expectEqualStrings("Scalar(f32)", Scalar(f32).typeName());
    try std.testing.expectEqualStrings("Bounded(f32,8)", Bounded(f32, 8).typeName());
    try std.testing.expectEqualStrings("Complex(f32)", Complex(f32).typeName());
}

// === Yoneda coverage additions =========================================
// We characterize each canonical element by ALL the morphisms the commit
// pass + connect-checker observe on it: type identity (the §1.3 equalities
// that drive type-checking), the pool-class-key decls (`channel_count`,
// `lane`, `feature_count`, `capacity`), `typeName()` across lanes, the
// memory layout (`@sizeOf`, planar storage), and TYPE DISTINCTNESS — because
// `connect` rejects a mismatch purely on `Elem != Elem` (graph.zig §6), two
// elements that *should* be different must compile to different types.

test "Sample(T) == Frame(T,1) holds for every active lane (catalog §1.3, ⊢)" {
    // The identity is load-bearing: connect() compares element TYPES, so a
    // mono kernel wired to a Frame(_,1) kernel must type-check. Pin it across
    // the active-precision lanes plus f64 (a desktop lane).
    try std.testing.expect(Sample(f32) == Frame(f32, 1));
    try std.testing.expect(Sample(f64) == Frame(f64, 1));
    try std.testing.expect(Sample(i16) == Frame(i16, 1)); // q15 lane
    try std.testing.expect(Sample(i32) == Frame(i32, 1)); // q31 lane
    // The identity is exactly C==1: Sample is NOT Frame(_,2).
    try std.testing.expect(Sample(f32) != Frame(f32, 2));
}

test "element types are DISTINCT across lane/channel/family (so connect can reject)" {
    // A C-mismatch is an element-type mismatch (graph.zig §6): Frame(_,1) and
    // Frame(_,2) must be different types or the channel-count guard is vacuous.
    try std.testing.expect(Frame(f32, 1) != Frame(f32, 2));
    try std.testing.expect(Frame(f32, 2) != Frame(f32, 3));
    // A lane mismatch must also be a type mismatch.
    try std.testing.expect(Frame(f32, 2) != Frame(f64, 2));
    try std.testing.expect(Sample(f32) != Sample(f64));
    // Different families with the same arity must not collapse to one type.
    try std.testing.expect(Scalar(f32) != Sample(f32));
    try std.testing.expect(FeatureFrame(8) != FeatureFrame(16));
    try std.testing.expect(Bounded(f32, 8) != Bounded(f32, 16));
    try std.testing.expect(Complex(f32) != Complex(f64));
}

test "Frame exposes channel_count + lane as pool-class-key decls (catalog §1.3)" {
    try std.testing.expectEqual(@as(usize, 1), Sample(f32).channel_count);
    try std.testing.expectEqual(@as(usize, 2), Frame(f32, 2).channel_count);
    try std.testing.expectEqual(@as(usize, 7), Frame(i16, 7).channel_count);
    try std.testing.expect(Frame(f32, 4).lane == f32);
    try std.testing.expect(Frame(i16, 4).lane == i16); // q15 lane key
}

test "Frame is planar { ch: [C]Lane } with the expected @sizeOf (catalog §9.3)" {
    // Footprint sizing in commit.zig is driven by @sizeOf of the element; pin
    // the planar layout so a footprint regression surfaces here, not silently.
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Sample(f32)));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Frame(f32, 2)));
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Sample(i16))); // q15
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Sample(f64)));
    // Planar = a single [C]Lane array field named `ch` (no interleave padding
    // for these lanes). A round-trip through the field proves the layout.
    var f: Frame(f32, 2) = .{ .ch = .{ 1.0, 2.0 } };
    f.ch[1] = 9.0;
    try std.testing.expectEqual(@as(f32, 9.0), f.ch[1]);
}

test "typeName() reflects the lane, not just the family (catalog §1.3)" {
    // typeName feeds pool-class diagnostics; it must distinguish lanes/arity.
    try std.testing.expectEqualStrings("Frame(f32,1)", Sample(f32).typeName());
    try std.testing.expectEqualStrings("Frame(i16,1)", Sample(i16).typeName());
    try std.testing.expectEqualStrings("Frame(f64,2)", Frame(f64, 2).typeName());
    try std.testing.expectEqualStrings("Complex(f64)", Complex(f64).typeName());
    try std.testing.expectEqualStrings("Scalar(i16)", Scalar(i16).typeName());
    try std.testing.expectEqualStrings("Bounded(i32,4)", Bounded(i32, 4).typeName());
    try std.testing.expectEqualStrings("FeatureFrame(1)", FeatureFrame(1).typeName());
    // The Sample/Frame identity is visible in typeName too: a Sample names
    // itself as the Frame(_,1) it IS — no separate "Sample" string.
    try std.testing.expectEqualStrings(Frame(f32, 1).typeName(), Sample(f32).typeName());
}

test "FeatureFrame/Scalar/Bounded/Complex expose their class-key decls" {
    try std.testing.expectEqual(@as(usize, 13), FeatureFrame(13).feature_count);
    try std.testing.expectEqual(@as(usize, 32), Bounded(f32, 32).capacity);
    try std.testing.expect(Bounded(f32, 32).lane == f32);
    try std.testing.expect(Scalar(i16).lane == i16);
    try std.testing.expect(Complex(f32).lane == f32);
    // Bounded carries a runtime `len` distinct from its comptime capacity:
    // liveness keys on [Kmax] storage, correctness on `len` (catalog §1.3).
    const b: Bounded(f32, 4) = .{ .items = .{ 0, 0, 0, 0 }, .len = 2 };
    try std.testing.expectEqual(@as(u16, 2), b.len);
    try std.testing.expectEqual(@as(usize, 4), @TypeOf(b).capacity);
}
