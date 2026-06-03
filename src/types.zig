//! Canonical port elements — the blessed set of types `A` that may ride on a
//! pan graph edge.
//!
//! Every edge carries exactly one of these as its element type. A non-primitive
//! element must expose a `typeName()` getter: the type-name machinery the graph
//! uses for pool-class diagnostics cannot name a bare array (`[K]f32` has no
//! name), so feature vectors and the like are wrapped in named structs that
//! carry one. This is a one-line convention, and it makes the pool class key
//! explicit. All multi-element forms are stored PLANAR (each channel/lane in
//! its own contiguous run), which is friendlier to vector kernels; planar ↔
//! interleaved conversion happens only at the I/O boundary.

const std = @import("std");

/// Ambisonic channel ordering convention (e.g. ACN). Carried so two ambisonic
/// layouts of the same order but different ordering are distinct identities.
pub const AmbiOrdering = enum { acn, fuma };

/// Ambisonic normalization convention (e.g. SN3D, N3D). Part of layout identity.
pub const AmbiNorm = enum { sn3d, n3d, fuma };

/// An opaque identifier for a custom speaker-position set. Two `.custom`
/// layouts are the same identity iff their `id` (and count) match.
pub const PositionSetId = u32;

/// `ChannelLayout` — the channel-layout descriptor `L` carried in the type.
///
/// Layout IDENTITY — channel count, positional tags, and canonical channel
/// order — lives in the type, so a mismatch in any of those between two wired
/// ports is a compile/commit-time type error (the same way a channel-count
/// mismatch is). Layout GEOMETRY — speaker azimuth/elevation, panning law, VBAP
/// triangulation, ambisonic decode coefficients — is block configuration, never
/// the stream type; this mirrors precision exactly (the lane is in the type,
/// the numeric behaviour is in the Numeric trait). `.discrete(N)` is an
/// anonymous N-channel bus with no positional identity: it opts out of the
/// positional check and matches on count alone.
pub const ChannelLayout = union(enum) {
    mono,
    stereo,
    surround_5_1,
    surround_7_1,
    ambisonic: struct { order: u8, ordering: AmbiOrdering, norm: AmbiNorm },
    /// N anonymous channels, no positional identity (count-only matching).
    discrete: u16,
    custom: struct { count: u16, id: PositionSetId },

    /// The number of channels in this layout. For ambisonic, an order-`o`
    /// soundfield has `(o+1)²` channels.
    pub fn count(self: ChannelLayout) u16 {
        return switch (self) {
            .mono => 1,
            .stereo => 2,
            .surround_5_1 => 6,
            .surround_7_1 => 8,
            .ambisonic => |a| (@as(u16, a.order) + 1) * (@as(u16, a.order) + 1),
            .discrete => |n| n,
            .custom => |c| c.count,
        };
    }

    /// A stable, self-describing name for this layout, used to build a unique
    /// `typeName()` for a `Frame`. `comptime self` because it composes
    /// compile-time strings for the parameterized variants.
    pub fn name(comptime self: ChannelLayout) []const u8 {
        return switch (self) {
            .mono => "mono",
            .stereo => "stereo",
            .surround_5_1 => "5_1",
            .surround_7_1 => "7_1",
            .ambisonic => |a| std.fmt.comptimePrint("ambisonic{d}", .{a.order}),
            .discrete => |n| std.fmt.comptimePrint("discrete{d}", .{n}),
            .custom => |c| std.fmt.comptimePrint("custom{d}_{d}", .{ c.count, c.id }),
        };
    }
};

/// `Frame(Lane, L)` — one audio frame on channel layout `L`, planar.
///
/// A named struct `{ ch: [L.count()]Lane }`, so it carries a `typeName()`. The
/// layout `L` rides in the type, so a channel/layout-changing block is simply
/// one whose input and output `Frame` differ in `L`, and a layout mismatch on a
/// wired edge is a type error. The pool class key is `(Frame(Lane,L), N)`: the
/// layout is part of the element identity, so the buffer pool keys off it
/// automatically.
pub fn Frame(comptime Lane: type, comptime L: ChannelLayout) type {
    return struct {
        ch: [L.count()]Lane,

        /// The channel count, part of the pool class key and exposed for the
        /// commit pass.
        pub const channel_count: usize = L.count();
        /// The element lane, the other half of the pool class key.
        pub const lane = Lane;
        /// The layout descriptor, for layout-aware blocks and negotiation.
        pub const layout = L;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Frame({s},{s})", .{ @typeName(Lane), comptime L.name() });
        }
    };
}

/// `Sample(T)` — one audio sample of precision `T`. Defined as exactly the mono
/// case of `Frame`, so the identity `Sample(T) == Frame(T, .mono)` holds by
/// construction: a mono kernel and a `Frame(T,.mono)` kernel are the same type,
/// and `connect` (which compares element types) accepts wiring one to the other.
pub fn Sample(comptime T: type) type {
    return Frame(T, .mono);
}

/// `Planar(Lane, L)` / `PlanarConst(Lane, L)` — the planar buffer VIEW a block
/// sees for layout `L` (channel count `C := L.count()`). It is the enforced
/// multi-channel storage form: a buffer of `N` frames is `C` contiguous
/// `N`-sample channel planes laid out plane-major (`[ch0_0…ch0_{N-1}][ch1_0…]…`),
/// NOT an array of interleaved frames. A block reads/writes each channel as its
/// own contiguous `[]Lane` plane via `plane(c)`, so a per-channel kernel
/// vectorizes over a whole plane.
///
/// The element IDENTITY for `connect`/`PortId` type-checking is `Frame(Lane, L)`
/// (exposed as `Elem`), which carries the channel count, positional tags, and
/// canonical order in `L`; the view does NOT change that identity, only the
/// physical arrangement and the access shape. Mono (`C = 1`) degenerates to a
/// single plane — `plane(0)` is the whole buffer as `[]Lane` — and is trivially
/// conformant, which is why mono blocks may equivalently keep a `[]Sample(T)`
/// slice port (one plane is contiguous either way).
///
/// `is_planar_view` is the marker the port machinery keys on to recover
/// `(Lane, L)` from a view parameter; `is_const_view` carries the direction
/// (a const view is an input port, a mutable view an output port).
fn PlanarView(comptime Lane: type, comptime L: ChannelLayout, comptime is_const: bool) type {
    const Ptr = if (is_const) [*]const Lane else [*]Lane;
    const PlaneSlice = if (is_const) []const Lane else []Lane;
    return struct {
        const Self = @This();
        /// The base of the plane-major region (plane 0, sample 0). The `c`-th
        /// plane starts at `base[c * frames]`.
        base: Ptr,
        /// The frame count `N` — the length of each channel plane.
        frames: usize,

        /// The element lane (the per-sample scalar type).
        pub const lane = Lane;
        /// The layout descriptor — count + positional tags + canonical order.
        pub const layout = L;
        /// The channel count `C := L.count()`, i.e. the number of planes.
        pub const channel_count: usize = L.count();
        /// The layout-identity element type for `connect`/`PortId` type-checking.
        pub const Elem = Frame(Lane, L);
        /// Marker: this type is a planar buffer view (read by the port machinery).
        pub const is_planar_view = true;
        /// Marker: a const view is an input port; a mutable view an output port.
        pub const is_const_view = is_const;

        /// The `c`-th channel plane as a contiguous `[]Lane` (or `[]const Lane`).
        /// `c` must be in `0..C`. The slice spans the whole `N`-sample plane.
        pub fn plane(self: Self, c: usize) PlaneSlice {
            return self.base[c * self.frames ..][0..self.frames];
        }

        /// Build a view over a plane-major region of `n` frames. The region holds
        /// exactly `C * n` lanes (`C * n * @sizeOf(Lane)` bytes), plane-major.
        pub fn fromBase(base: Ptr, n: usize) Self {
            return .{ .base = base, .frames = n };
        }
    };
}

/// A mutable planar view (an OUTPUT port): `C` writable `[]Lane` planes.
pub fn Planar(comptime Lane: type, comptime L: ChannelLayout) type {
    return PlanarView(Lane, L, false);
}

/// A const planar view (an INPUT port): `C` read-only `[]const Lane` planes.
pub fn PlanarConst(comptime Lane: type, comptime L: ChannelLayout) type {
    return PlanarView(Lane, L, true);
}

/// Is `T` a `Planar`/`PlanarConst` buffer view? Used by the port machinery to
/// recover `(Lane, L)` and the direction from a view parameter.
pub fn isPlanarView(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "is_planar_view")) return false;
    return T.is_planar_view;
}

/// `Complex(T)` — one spectral bin. Wraps `std.math.Complex(T)` (which has no
/// `typeName()` of its own) in a named struct carrying one. Pool class key
/// `(Complex(T), N/2+1)`.
pub fn Complex(comptime T: type) type {
    return struct {
        z: std.math.Complex(T),

        pub const lane = T;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Complex({s})", .{@typeName(T)});
        }
    };
}

/// `FeatureFrame(K)` — a fixed-`K` feature vector (mel/chroma/MFCC/DCT). A named
/// struct `{ v: [K]f32 }`; a bare `[K]f32` has no `typeName()` and is rejected.
/// `K` is comptime, so a feature-frame loop unrolls with no scalar tail. Pool
/// class key `(FeatureFrame(K), 1)`.
pub fn FeatureFrame(comptime K: usize) type {
    return struct {
        v: [K]f32,

        pub const feature_count = K;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("FeatureFrame({d})", .{K});
        }
    };
}

/// `Scalar(T)` — one scalar feature (centroid, flux, RMS, dominant band). A
/// named struct carrying a `typeName()`. Also serves as a control element for
/// parameter ports. Pool class key `(Scalar(T), 1)`.
pub fn Scalar(comptime T: type) type {
    return struct {
        value: T,

        pub const lane = T;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Scalar({s})", .{@typeName(T)});
        }
    };
}

/// `Bounded(T, Kmax)` — a ragged list with fixed capacity `Kmax` and a variable
/// `len` (formant tracks, sparse peak lists, beat hypotheses). Liveness is over
/// the fixed `[Kmax]` storage, so buffer coloring is unaffected by `len`;
/// correctness is the consumer respecting `len`. Pool class key
/// `(Bounded(T,Kmax), 1)`.
pub fn Bounded(comptime T: type, comptime Kmax: usize) type {
    return struct {
        items: [Kmax]T,
        len: u16,

        pub const capacity = Kmax;
        pub const lane = T;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Bounded({s},{d})", .{ @typeName(T), Kmax });
        }
    };
}

test "Sample(T) is the mono Frame by construction" {
    try std.testing.expect(Sample(f32) == Frame(f32, .mono));
    try std.testing.expect(Sample(i16) == Frame(i16, .mono));
    try std.testing.expect(Sample(f32) != Frame(f32, .stereo));
}

test "ChannelLayout.count over the canonical values" {
    try std.testing.expectEqual(@as(u16, 1), (@as(ChannelLayout, .mono)).count());
    try std.testing.expectEqual(@as(u16, 2), (@as(ChannelLayout, .stereo)).count());
    try std.testing.expectEqual(@as(u16, 6), (@as(ChannelLayout, .surround_5_1)).count());
    try std.testing.expectEqual(@as(u16, 8), (@as(ChannelLayout, .surround_7_1)).count());
    try std.testing.expectEqual(@as(u16, 4), (ChannelLayout{ .discrete = 4 }).count());
    const amb = ChannelLayout{ .ambisonic = .{ .order = 2, .ordering = .acn, .norm = .sn3d } };
    try std.testing.expectEqual(@as(u16, 9), amb.count()); // (2+1)^2
}

test "Frame planar layout and @sizeOf" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Sample(f32)));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Frame(f32, .stereo)));
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Sample(i16)));
    var f: Frame(f32, .stereo) = .{ .ch = .{ 1.0, 2.0 } };
    f.ch[1] = 9.0;
    try std.testing.expectEqual(@as(f32, 9.0), f.ch[1]);
}

test "every non-primitive element carries a typeName()" {
    try std.testing.expectEqualStrings("Frame(f32,mono)", Sample(f32).typeName());
    try std.testing.expectEqualStrings("Frame(f32,stereo)", Frame(f32, .stereo).typeName());
    try std.testing.expectEqualStrings("Frame(i16,discrete4)", Frame(i16, .{ .discrete = 4 }).typeName());
    try std.testing.expectEqualStrings("Complex(f32)", Complex(f32).typeName());
    try std.testing.expectEqualStrings("FeatureFrame(13)", FeatureFrame(13).typeName());
    try std.testing.expectEqualStrings("Scalar(f32)", Scalar(f32).typeName());
    try std.testing.expectEqualStrings("Bounded(f32,8)", Bounded(f32, 8).typeName());
}

test "Planar view exposes C plane-major []Lane planes and the Frame identity" {
    // Plane-major: [L0,L1,L2][R0,R1,R2], NOT interleaved [L0,R0,L1,R1,L2,R2].
    var buf: [6]f32 = .{ 1, 2, 3, 10, 20, 30 };
    const v = Planar(f32, .stereo).fromBase(&buf, 3);
    try std.testing.expect(isPlanarView(Planar(f32, .stereo)));
    try std.testing.expect(isPlanarView(PlanarConst(f32, .stereo)));
    try std.testing.expect(!isPlanarView(Frame(f32, .stereo)));
    try std.testing.expectEqual(@as(usize, 2), Planar(f32, .stereo).channel_count);
    // The view's element identity is the Frame — that is what connect checks.
    try std.testing.expect(Planar(f32, .stereo).Elem == Frame(f32, .stereo));
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, v.plane(0));
    try std.testing.expectEqualSlices(f32, &.{ 10, 20, 30 }, v.plane(1));
    // Mutable plane writes through to the backing buffer.
    v.plane(1)[0] = 99;
    try std.testing.expectEqual(@as(f32, 99), buf[3]);
    // Mono degenerates to one plane spanning the whole buffer.
    var mono: [4]f32 = .{ 5, 6, 7, 8 };
    const mv = Planar(f32, .mono).fromBase(&mono, 4);
    try std.testing.expectEqual(@as(usize, 1), Planar(f32, .mono).channel_count);
    try std.testing.expectEqualSlices(f32, &.{ 5, 6, 7, 8 }, mv.plane(0));
}

test "elements are distinct types across lane/layout/family so connect can reject" {
    try std.testing.expect(Frame(f32, .mono) != Frame(f32, .stereo));
    try std.testing.expect(Frame(f32, .stereo) != Frame(f64, .stereo));
    try std.testing.expect(Sample(f32) != Scalar(f32));
    try std.testing.expect(FeatureFrame(8) != FeatureFrame(16));
    // Two .discrete layouts of different count are different identities.
    try std.testing.expect(Frame(f32, .{ .discrete = 3 }) != Frame(f32, .{ .discrete = 4 }));
}
