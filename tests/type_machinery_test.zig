//! Yoneda "tests as definition" suite for the pan core type machinery.
//!
//! These tests CHARACTERIZE `src/types.zig` and `src/numeric.zig` by every
//! observable morphism the rest of the system uses on them: the canonical type
//! identities, the channel-layout arithmetic, the element-type distinctness
//! matrix (on which `connect`'s mismatch rejection depends), the `typeName()`
//! uniqueness contract, the planar `@sizeOf` law, and the `numericFor`
//! precision-trait laws.
//!
//! COMPARISON MODE: ⊢ decidable-static. The assertions are compile-time
//! type-identity / exact-value checks; the laws stated in the catalog ARE the
//! oracle. No external reference output is consulted.
//!
//! Verified against zig 0.16.0. Per project Rule 13/14 the zig-0-16 skill was
//! loaded before authoring.
//!
//! Imports go through the `pan` library module (wired in build.zig), which
//! re-exports `types` and `numeric` — Zig 0.16 forbids a harness module from
//! `@import`-ing a `../src` path that escapes its own root directory.

const std = @import("std");
const pan = @import("pan");
const types = pan.types;
const numeric = pan.numeric;

const ChannelLayout = types.ChannelLayout;
const Frame = types.Frame;
const Sample = types.Sample;
const Complex = types.Complex;
const FeatureFrame = types.FeatureFrame;
const Scalar = types.Scalar;
const Bounded = types.Bounded;

const Precision = numeric.Precision;
const Numeric = numeric.Numeric;
const numericFor = numeric.numericFor;
const widthFor = numeric.widthFor;

// =====================================================================
// §1.3 — The canonical identity  Sample(T) == Frame(T, .mono)
//
// Load-bearing because `connect` compares element TYPES: a mono kernel must
// type-check against a `Frame(_,.mono)` kernel. The identity must hold by
// construction for every lane, and must NOT collapse a non-mono layout into it.
// =====================================================================

test "Sample(T) == Frame(T,.mono) identity holds for f32 (catalog §1.3, ⊢ A6)" {
    try std.testing.expect(Sample(f32) == Frame(f32, .mono));
}

test "Sample(T) == Frame(T,.mono) identity holds for f64 (catalog §1.3, ⊢ A6)" {
    try std.testing.expect(Sample(f64) == Frame(f64, .mono));
}

test "Sample(T) == Frame(T,.mono) identity holds for i16 (catalog §1.3, ⊢ A6)" {
    try std.testing.expect(Sample(i16) == Frame(i16, .mono));
}

test "Sample(T) == Frame(T,.mono) identity holds for i32 (catalog §1.3, ⊢ A6)" {
    try std.testing.expect(Sample(i32) == Frame(i32, .mono));
}

test "Sample(T) != Frame(T,.stereo): mono is not the 2-channel frame (catalog §1.3, ⊢ A6)" {
    // If this collapsed, a mono kernel would silently wire to a stereo edge.
    try std.testing.expect(Sample(f32) != Frame(f32, .stereo));
    try std.testing.expect(Sample(i16) != Frame(i16, .stereo));
}

test "Sample(T) != Frame(T,.discrete=1): mono identity is positional, not count-only (catalog §1.3, ⊢ A6)" {
    // `.mono` (positional) and `.discrete=1` (anonymous) both have count 1, but
    // they are DISTINCT layout identities, so the Frame types must differ even
    // though their storage is byte-identical.
    try std.testing.expect(Sample(f32) != Frame(f32, .{ .discrete = 1 }));
}

// =====================================================================
// §ChannelLayout.count() — the channel-count arithmetic oracle.
//   mono=1, stereo=2, surround_5_1=6, surround_7_1=8,
//   ambisonic order o => (o+1)^2, discrete(N)=N, custom{count}=count.
// =====================================================================

test "ChannelLayout.count(): mono == 1 (⊢ count law)" {
    try std.testing.expectEqual(@as(u16, 1), (@as(ChannelLayout, .mono)).count());
}

test "ChannelLayout.count(): stereo == 2 (⊢ count law)" {
    try std.testing.expectEqual(@as(u16, 2), (@as(ChannelLayout, .stereo)).count());
}

test "ChannelLayout.count(): surround_5_1 == 6 (⊢ count law)" {
    try std.testing.expectEqual(@as(u16, 6), (@as(ChannelLayout, .surround_5_1)).count());
}

test "ChannelLayout.count(): surround_7_1 == 8 (⊢ count law)" {
    try std.testing.expectEqual(@as(u16, 8), (@as(ChannelLayout, .surround_7_1)).count());
}

test "ChannelLayout.count(): discrete(N) == N over several N (⊢ count law)" {
    try std.testing.expectEqual(@as(u16, 0), (ChannelLayout{ .discrete = 0 }).count());
    try std.testing.expectEqual(@as(u16, 1), (ChannelLayout{ .discrete = 1 }).count());
    try std.testing.expectEqual(@as(u16, 3), (ChannelLayout{ .discrete = 3 }).count());
    try std.testing.expectEqual(@as(u16, 64), (ChannelLayout{ .discrete = 64 }).count());
    try std.testing.expectEqual(@as(u16, 65535), (ChannelLayout{ .discrete = 65535 }).count());
}

test "ChannelLayout.count(): custom{count} == count, independent of id (⊢ count law)" {
    try std.testing.expectEqual(@as(u16, 12), (ChannelLayout{ .custom = .{ .count = 12, .id = 7 } }).count());
    // Same count, different id => same count (count does not read id).
    try std.testing.expectEqual(@as(u16, 12), (ChannelLayout{ .custom = .{ .count = 12, .id = 99 } }).count());
}

test "ChannelLayout.count(): ambisonic order o => (o+1)^2 over orders 0..7 (⊢ count law)" {
    // order 0 => 1, 1 => 4, 2 => 9, 3 => 16, ... the soundfield channel count.
    inline for (.{ 0, 1, 2, 3, 4, 5, 6, 7 }) |o| {
        const lay = ChannelLayout{ .ambisonic = .{ .order = o, .ordering = .acn, .norm = .sn3d } };
        const expected: u16 = (@as(u16, o) + 1) * (@as(u16, o) + 1);
        try std.testing.expectEqual(expected, lay.count());
    }
}

test "ChannelLayout.count(): ambisonic count is independent of ordering/norm (⊢ count law)" {
    const acn_sn3d = ChannelLayout{ .ambisonic = .{ .order = 3, .ordering = .acn, .norm = .sn3d } };
    const fuma_n3d = ChannelLayout{ .ambisonic = .{ .order = 3, .ordering = .fuma, .norm = .n3d } };
    try std.testing.expectEqual(@as(u16, 16), acn_sn3d.count());
    try std.testing.expectEqual(@as(u16, 16), fuma_n3d.count());
}

// =====================================================================
// §ChannelLayout.name() — the per-layout descriptive string used to build a
// unique Frame typeName(). Pinned exactly for every variant.
// =====================================================================

test "ChannelLayout.name(): exact strings for the fixed variants (⊢ name law)" {
    try std.testing.expectEqualStrings("mono", comptime (@as(ChannelLayout, .mono)).name());
    try std.testing.expectEqualStrings("stereo", comptime (@as(ChannelLayout, .stereo)).name());
    try std.testing.expectEqualStrings("5_1", comptime (@as(ChannelLayout, .surround_5_1)).name());
    try std.testing.expectEqualStrings("7_1", comptime (@as(ChannelLayout, .surround_7_1)).name());
}

test "ChannelLayout.name(): parameterized variants embed their parameters (⊢ name law)" {
    try std.testing.expectEqualStrings("ambisonic2", comptime (ChannelLayout{ .ambisonic = .{ .order = 2, .ordering = .acn, .norm = .sn3d } }).name());
    try std.testing.expectEqualStrings("discrete4", comptime (ChannelLayout{ .discrete = 4 }).name());
    try std.testing.expectEqualStrings("custom6_3", comptime (ChannelLayout{ .custom = .{ .count = 6, .id = 3 } }).name());
}

// =====================================================================
// §Frame — planar storage `{ ch: [L.count()]Lane }` and its decls
// (channel_count / lane / layout / typeName).
// =====================================================================

test "Frame is planar { ch: [count]Lane }: @sizeOf == count * @sizeOf(Lane) (⊢ planar law)" {
    try std.testing.expectEqual(@as(usize, 1 * @sizeOf(f32)), @sizeOf(Frame(f32, .mono)));
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(f32)), @sizeOf(Frame(f32, .stereo)));
    try std.testing.expectEqual(@as(usize, 6 * @sizeOf(f32)), @sizeOf(Frame(f32, .surround_5_1)));
    try std.testing.expectEqual(@as(usize, 8 * @sizeOf(f32)), @sizeOf(Frame(f32, .surround_7_1)));
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(i16)), @sizeOf(Frame(i16, .stereo)));
    try std.testing.expectEqual(@as(usize, 6 * @sizeOf(f64)), @sizeOf(Frame(f64, .surround_5_1)));
    // ambisonic order 2 => 9 channels.
    try std.testing.expectEqual(@as(usize, 9 * @sizeOf(f32)), @sizeOf(Frame(f32, .{ .ambisonic = .{ .order = 2, .ordering = .acn, .norm = .sn3d } })));
}

test "Frame field `ch` is an array of exactly count() lanes (⊢ planar law)" {
    const F = Frame(f32, .surround_5_1);
    const info = @typeInfo(F).@"struct";
    // exactly one field, named `ch`.
    try std.testing.expectEqual(@as(usize, 1), info.fields.len);
    try std.testing.expectEqualStrings("ch", info.fields[0].name);
    const ch_info = @typeInfo(info.fields[0].type).array;
    try std.testing.expectEqual(@as(usize, 6), ch_info.len);
    try std.testing.expect(ch_info.child == f32);
}

test "Frame.channel_count decl equals the layout count (⊢ Frame decls)" {
    try std.testing.expectEqual(@as(usize, 1), Frame(f32, .mono).channel_count);
    try std.testing.expectEqual(@as(usize, 2), Frame(f32, .stereo).channel_count);
    try std.testing.expectEqual(@as(usize, 6), Frame(f32, .surround_5_1).channel_count);
    try std.testing.expectEqual(@as(usize, 9), Frame(f32, .{ .ambisonic = .{ .order = 2, .ordering = .acn, .norm = .sn3d } }).channel_count);
}

test "Frame.lane decl equals the Lane type argument (⊢ Frame decls)" {
    try std.testing.expect(Frame(f32, .stereo).lane == f32);
    try std.testing.expect(Frame(f64, .stereo).lane == f64);
    try std.testing.expect(Frame(i16, .mono).lane == i16);
    try std.testing.expect(Frame(i32, .surround_5_1).lane == i32);
}

test "Frame.layout decl round-trips the layout descriptor (⊢ Frame decls)" {
    try std.testing.expect(std.meta.eql(Frame(f32, .stereo).layout, ChannelLayout.stereo));
    try std.testing.expect(std.meta.eql(Frame(f32, .{ .discrete = 4 }).layout, ChannelLayout{ .discrete = 4 }));
    const amb = ChannelLayout{ .ambisonic = .{ .order = 1, .ordering = .fuma, .norm = .n3d } };
    try std.testing.expect(std.meta.eql(Frame(f64, amb).layout, amb));
}

test "Frame channels are independently addressable planar storage (⊢ planar law)" {
    var f: Frame(f32, .surround_5_1) = .{ .ch = .{ 0, 0, 0, 0, 0, 0 } };
    f.ch[0] = 1.0;
    f.ch[5] = 6.0;
    try std.testing.expectEqual(@as(f32, 1.0), f.ch[0]);
    try std.testing.expectEqual(@as(f32, 6.0), f.ch[5]);
    try std.testing.expectEqual(@as(f32, 0.0), f.ch[3]);
}

// =====================================================================
// §typeName() — unique per (lane, layout/family/arity); every non-primitive
// element exposes it. Exact-string pins.
// =====================================================================

test "typeName(): Frame variants are exact and lane/layout-qualified (⊢ typeName law)" {
    try std.testing.expectEqualStrings("Frame(f32,mono)", Frame(f32, .mono).typeName());
    try std.testing.expectEqualStrings("Frame(f64,mono)", Frame(f64, .mono).typeName());
    try std.testing.expectEqualStrings("Frame(i16,mono)", Frame(i16, .mono).typeName());
    try std.testing.expectEqualStrings("Frame(f32,stereo)", Frame(f32, .stereo).typeName());
    try std.testing.expectEqualStrings("Frame(f32,5_1)", Frame(f32, .surround_5_1).typeName());
    try std.testing.expectEqualStrings("Frame(f32,7_1)", Frame(f32, .surround_7_1).typeName());
    try std.testing.expectEqualStrings("Frame(i16,discrete4)", Frame(i16, .{ .discrete = 4 }).typeName());
    try std.testing.expectEqualStrings("Frame(f32,ambisonic2)", Frame(f32, .{ .ambisonic = .{ .order = 2, .ordering = .acn, .norm = .sn3d } }).typeName());
    try std.testing.expectEqualStrings("Frame(f32,custom6_3)", Frame(f32, .{ .custom = .{ .count = 6, .id = 3 } }).typeName());
}

test "typeName(): Sample(T) presents as the mono Frame name (⊢ typeName law + §1.3)" {
    // Because Sample(T) IS Frame(T,.mono), its typeName must read as such.
    try std.testing.expectEqualStrings("Frame(f32,mono)", Sample(f32).typeName());
    try std.testing.expectEqualStrings("Frame(i32,mono)", Sample(i32).typeName());
}

test "typeName(): Complex(T) is lane-qualified (⊢ typeName law)" {
    try std.testing.expectEqualStrings("Complex(f32)", Complex(f32).typeName());
    try std.testing.expectEqualStrings("Complex(f64)", Complex(f64).typeName());
}

test "typeName(): FeatureFrame(K) embeds K (⊢ typeName law)" {
    try std.testing.expectEqualStrings("FeatureFrame(13)", FeatureFrame(13).typeName());
    try std.testing.expectEqualStrings("FeatureFrame(40)", FeatureFrame(40).typeName());
    try std.testing.expectEqualStrings("FeatureFrame(1)", FeatureFrame(1).typeName());
}

test "typeName(): Scalar(T) is lane-qualified (⊢ typeName law)" {
    try std.testing.expectEqualStrings("Scalar(f32)", Scalar(f32).typeName());
    try std.testing.expectEqualStrings("Scalar(i16)", Scalar(i16).typeName());
}

test "typeName(): Bounded(T,Kmax) embeds lane and capacity (⊢ typeName law)" {
    try std.testing.expectEqualStrings("Bounded(f32,8)", Bounded(f32, 8).typeName());
    try std.testing.expectEqualStrings("Bounded(i16,32)", Bounded(i16, 32).typeName());
}

test "typeName(): is unique across the whole element catalog (⊢ typeName uniqueness)" {
    // Collect a representative spread of element names and assert pairwise
    // distinctness — the property `connect` relies on for pool-class keying.
    const names = [_][]const u8{
        Frame(f32, .mono).typeName(),
        Frame(f64, .mono).typeName(),
        Frame(i16, .mono).typeName(),
        Frame(f32, .stereo).typeName(),
        Frame(f32, .surround_5_1).typeName(),
        Frame(f32, .surround_7_1).typeName(),
        Frame(f32, .{ .discrete = 2 }).typeName(),
        Frame(f32, .{ .ambisonic = .{ .order = 1, .ordering = .acn, .norm = .sn3d } }).typeName(),
        Frame(f32, .{ .custom = .{ .count = 2, .id = 0 } }).typeName(),
        Complex(f32).typeName(),
        Complex(f64).typeName(),
        FeatureFrame(13).typeName(),
        FeatureFrame(40).typeName(),
        Scalar(f32).typeName(),
        Scalar(i16).typeName(),
        Bounded(f32, 8).typeName(),
        Bounded(i16, 8).typeName(),
    };
    for (names, 0..) |a, i| {
        for (names, 0..) |b, j| {
            if (i == j) continue;
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}

// =====================================================================
// §Distinctness matrix — two elements that should differ MUST compile to
// different Zig types, otherwise `connect`'s mismatch rejection is vacuous.
// =====================================================================

// ---- Lane distinctness (same layout/family, different lane) ----

test "distinct: Frame differs by lane (f32 vs f64 vs i16 vs i32), same layout (⊢ distinctness)" {
    try std.testing.expect(Frame(f32, .stereo) != Frame(f64, .stereo));
    try std.testing.expect(Frame(f32, .stereo) != Frame(i16, .stereo));
    try std.testing.expect(Frame(f32, .stereo) != Frame(i32, .stereo));
    try std.testing.expect(Frame(f64, .stereo) != Frame(i16, .stereo));
    try std.testing.expect(Frame(i16, .stereo) != Frame(i32, .stereo));
}

test "distinct: Complex/Scalar/Bounded differ by lane (⊢ distinctness)" {
    try std.testing.expect(Complex(f32) != Complex(f64));
    try std.testing.expect(Scalar(f32) != Scalar(i16));
    try std.testing.expect(Bounded(f32, 8) != Bounded(i16, 8));
}

// ---- Layout distinctness (same lane/family, different layout) ----
// The channel-layout-identity check GENERALISES the old channel-count check:
// it must reject not only different counts, but same-count different identities.

test "distinct: Frame differs across every canonical fixed layout (⊢ layout distinctness)" {
    try std.testing.expect(Frame(f32, .mono) != Frame(f32, .stereo));
    try std.testing.expect(Frame(f32, .mono) != Frame(f32, .surround_5_1));
    try std.testing.expect(Frame(f32, .stereo) != Frame(f32, .surround_5_1));
    try std.testing.expect(Frame(f32, .surround_5_1) != Frame(f32, .surround_7_1));
}

test "distinct: discrete layouts differ by count (⊢ layout distinctness)" {
    try std.testing.expect(Frame(f32, .{ .discrete = 3 }) != Frame(f32, .{ .discrete = 4 }));
}

test "distinct: SAME count but different layout identity are different types (⊢ generalised identity)" {
    // stereo and discrete=2 both have count 2 but distinct identity.
    try std.testing.expect(Frame(f32, .stereo) != Frame(f32, .{ .discrete = 2 }));
    // surround_5_1 and discrete=6 both have count 6.
    try std.testing.expect(Frame(f32, .surround_5_1) != Frame(f32, .{ .discrete = 6 }));
    // surround_7_1 and discrete=8 both have count 8.
    try std.testing.expect(Frame(f32, .surround_7_1) != Frame(f32, .{ .discrete = 8 }));
    // mono and discrete=1 both have count 1.
    try std.testing.expect(Frame(f32, .mono) != Frame(f32, .{ .discrete = 1 }));
    // ambisonic order 1 (4ch) and discrete=4 both have count 4.
    try std.testing.expect(Frame(f32, .{ .ambisonic = .{ .order = 1, .ordering = .acn, .norm = .sn3d } }) != Frame(f32, .{ .discrete = 4 }));
}

test "distinct: ambisonic identity includes order, ordering AND norm (⊢ ambisonic identity)" {
    const Base = Frame(f32, .{ .ambisonic = .{ .order = 1, .ordering = .acn, .norm = .sn3d } });
    // Different order => different type (and different count).
    try std.testing.expect(Base != Frame(f32, .{ .ambisonic = .{ .order = 2, .ordering = .acn, .norm = .sn3d } }));
    // Same order, different ordering => different identity (SAME count).
    try std.testing.expect(Base != Frame(f32, .{ .ambisonic = .{ .order = 1, .ordering = .fuma, .norm = .sn3d } }));
    // Same order, different norm => different identity (SAME count).
    try std.testing.expect(Base != Frame(f32, .{ .ambisonic = .{ .order = 1, .ordering = .acn, .norm = .n3d } }));
}

test "distinct: custom identity includes both count AND id (⊢ custom identity)" {
    const Base = Frame(f32, .{ .custom = .{ .count = 6, .id = 1 } });
    // Different count => different type.
    try std.testing.expect(Base != Frame(f32, .{ .custom = .{ .count = 8, .id = 1 } }));
    // Same count, different id => different identity (SAME count).
    try std.testing.expect(Base != Frame(f32, .{ .custom = .{ .count = 6, .id = 2 } }));
    // Same count, identical id => SAME type (sanity: identity is not over-fine).
    try std.testing.expect(Base == Frame(f32, .{ .custom = .{ .count = 6, .id = 1 } }));
}

// ---- Family distinctness (different element constructor) ----

test "distinct: different families never collide even at matching lane (⊢ family distinctness)" {
    try std.testing.expect(Sample(f32) != Scalar(f32));
    try std.testing.expect(Sample(f32) != Complex(f32));
    try std.testing.expect(Scalar(f32) != Complex(f32));
    try std.testing.expect(Scalar(f32) != Bounded(f32, 8));
    try std.testing.expect(Complex(f32) != Bounded(f32, 8));
    // FeatureFrame is f32-lane; it must not collide with a single-sample Frame.
    try std.testing.expect(FeatureFrame(1) != Sample(f32));
}

// ---- Arity / K / Kmax distinctness ----

test "distinct: FeatureFrame differs by K (⊢ arity distinctness)" {
    try std.testing.expect(FeatureFrame(8) != FeatureFrame(16));
    try std.testing.expect(FeatureFrame(1) != FeatureFrame(2));
    try std.testing.expect(FeatureFrame(13) != FeatureFrame(40));
}

test "distinct: Bounded differs by Kmax even at the same lane (⊢ Kmax distinctness)" {
    try std.testing.expect(Bounded(f32, 8) != Bounded(f32, 16));
    try std.testing.expect(Bounded(i16, 4) != Bounded(i16, 32));
}

// ---- Identity sanity: identical args => identical type (not over-fine) ----

test "identity: identical constructor args yield the SAME type (⊢ identity is exact)" {
    try std.testing.expect(Frame(f32, .stereo) == Frame(f32, .stereo));
    try std.testing.expect(Sample(f64) == Sample(f64));
    try std.testing.expect(Complex(f32) == Complex(f32));
    try std.testing.expect(FeatureFrame(13) == FeatureFrame(13));
    try std.testing.expect(Scalar(i16) == Scalar(i16));
    try std.testing.expect(Bounded(f32, 8) == Bounded(f32, 8));
    try std.testing.expect(Frame(f32, .{ .discrete = 4 }) == Frame(f32, .{ .discrete = 4 }));
}

// =====================================================================
// §Element decls beyond Frame — lane / capacity / feature_count getters that
// the pool-class machinery reads.
// =====================================================================

test "Complex.lane / Scalar.lane / Bounded.lane expose the lane type (⊢ element decls)" {
    try std.testing.expect(Complex(f32).lane == f32);
    try std.testing.expect(Complex(f64).lane == f64);
    try std.testing.expect(Scalar(f32).lane == f32);
    try std.testing.expect(Scalar(i32).lane == i32);
    try std.testing.expect(Bounded(f64, 8).lane == f64);
}

test "FeatureFrame.feature_count == K and Bounded.capacity == Kmax (⊢ element decls)" {
    try std.testing.expectEqual(@as(usize, 13), FeatureFrame(13).feature_count);
    try std.testing.expectEqual(@as(usize, 40), FeatureFrame(40).feature_count);
    try std.testing.expectEqual(@as(usize, 8), Bounded(f32, 8).capacity);
    try std.testing.expectEqual(@as(usize, 32), Bounded(i16, 32).capacity);
}

test "FeatureFrame storage is [K]f32 planar (⊢ FeatureFrame layout)" {
    const FF = FeatureFrame(13);
    try std.testing.expectEqual(@as(usize, 13 * @sizeOf(f32)), @sizeOf(FF));
    var ff: FF = .{ .v = [_]f32{0} ** 13 };
    ff.v[12] = 3.5;
    try std.testing.expectEqual(@as(f32, 3.5), ff.v[12]);
}

test "Bounded storage is [Kmax]T plus a len, liveness over fixed storage (⊢ Bounded layout)" {
    const B = Bounded(f32, 8);
    const info = @typeInfo(B).@"struct";
    // Two fields: items ([Kmax]T) and len.
    try std.testing.expectEqual(@as(usize, 2), info.fields.len);
    var b: B = .{ .items = [_]f32{0} ** 8, .len = 0 };
    b.items[7] = 1.0;
    b.len = 3;
    try std.testing.expectEqual(@as(u16, 3), b.len);
    try std.testing.expectEqual(@as(f32, 1.0), b.items[7]);
    // @sizeOf accounts for the full Kmax storage regardless of len.
    try std.testing.expect(@sizeOf(B) >= 8 * @sizeOf(f32));
}

test "Complex wraps std.math.Complex(T) (⊢ Complex storage)" {
    const C = Complex(f32);
    const c: C = .{ .z = std.math.Complex(f32).init(1.0, -2.0) };
    try std.testing.expectEqual(@as(f32, 1.0), c.z.re);
    try std.testing.expectEqual(@as(f32, -2.0), c.z.im);
}

// =====================================================================
// §numericFor — the precision-trait laws. EXHAUSTIVE over Precision via
// std.meta.fields; plus per-tag pins.
//
// Laws:
//  * integer lanes: Acc strictly wider than Lane, saturate == true
//  * float lanes:   Acc == Lane,                 saturate == false
//  * always:        W >= 1
//  * f32 vs an integer trait differ in every core field
//  * numericFor is pure/deterministic
// =====================================================================

/// True iff the precision tag names a float lane (the only two in the set).
fn isFloatTag(comptime p: Precision) bool {
    return p == .f32 or p == .f64;
}

test "numericFor: EXHAUSTIVE over Precision — core invariants per tag (⊢ numericFor law)" {
    @setEvalBranchQuota(10000);
    inline for (std.meta.fields(Precision)) |fld| {
        const p: Precision = @enumFromInt(fld.value);
        const num = comptime numericFor(p, .{});

        // W >= 1 for every tag (scalar fallback is the floor).
        try std.testing.expect(num.W >= 1);

        if (comptime isFloatTag(p)) {
            // Float: accumulate in own width, never saturate.
            try std.testing.expect(num.Acc == num.Lane);
            try std.testing.expect(num.saturate == false);
        } else {
            // Integer: accumulator STRICTLY wider, and saturating.
            try std.testing.expect(num.saturate == true);
            const lane_bits = @typeInfo(num.Lane).int.bits;
            const acc_bits = @typeInfo(num.Acc).int.bits;
            try std.testing.expect(acc_bits > lane_bits);
        }
    }
}

test "numericFor: every active precision is covered by the switch (⊢ active/numericFor coherence)" {
    // numericFor must resolve for every tag in `active` without compile error.
    inline for (numeric.active) |p| {
        const num = comptime numericFor(p, .{});
        try std.testing.expect(num.W >= 1);
    }
}

test "numericFor(.f32, .{}): float lane, same-width acc, no saturation (⊢ float trait)" {
    const num = comptime numericFor(.f32, .{});
    try std.testing.expect(num.Lane == f32);
    try std.testing.expect(num.Acc == f32);
    try std.testing.expect(num.saturate == false);
    try std.testing.expect(num.W >= 1);
}

test "numericFor(.f64, .{}): float lane, same-width acc, no saturation (⊢ float trait)" {
    const num = comptime numericFor(.f64, .{});
    try std.testing.expect(num.Lane == f64);
    try std.testing.expect(num.Acc == f64);
    try std.testing.expect(num.saturate == false);
    try std.testing.expect(num.W >= 1);
}

test "numericFor(.i8, .{}): i16 acc (2x), saturating (⊢ integer trait)" {
    const num = comptime numericFor(.i8, .{});
    try std.testing.expect(num.Lane == i8);
    try std.testing.expect(num.Acc == i16);
    try std.testing.expect(num.saturate == true);
    try std.testing.expect(num.W >= 1);
}

test "numericFor(.i16, q15, .{}): i32 acc (2x), saturating — the embedded path (⊢ integer trait)" {
    const num = comptime numericFor(.i16, .{});
    try std.testing.expect(num.Lane == i16);
    try std.testing.expect(num.Acc == i32);
    try std.testing.expect(num.saturate == true);
    try std.testing.expect(num.W >= 1);
}

test "numericFor(.i32, q31, .{}): i64 acc (2x), saturating (⊢ integer trait)" {
    const num = comptime numericFor(.i32, .{});
    try std.testing.expect(num.Lane == i32);
    try std.testing.expect(num.Acc == i64);
    try std.testing.expect(num.saturate == true);
    try std.testing.expect(num.W >= 1);
}

test "numericFor(.i64, .{}): i128 acc (2x), saturating (⊢ integer trait)" {
    const num = comptime numericFor(.i64, .{});
    try std.testing.expect(num.Lane == i64);
    try std.testing.expect(num.Acc == i128);
    try std.testing.expect(num.saturate == true);
    try std.testing.expect(num.W >= 1);
}

test "numericFor: integer Acc is exactly 2x the lane width (⊢ Acc convention)" {
    inline for (.{ Precision.i8, Precision.i16, Precision.i32, Precision.i64 }) |p| {
        const num = comptime numericFor(p, .{});
        const lane_bits = @typeInfo(num.Lane).int.bits;
        const acc_bits = @typeInfo(num.Acc).int.bits;
        try std.testing.expectEqual(lane_bits * 2, acc_bits);
    }
}

test "numericFor: the f32 trait differs from the i16 trait in EVERY core field (⊢ trait distinction)" {
    const f = comptime numericFor(.f32, .{});
    const i = comptime numericFor(.i16, .{});
    try std.testing.expect(f.Lane != i.Lane);
    try std.testing.expect(f.Acc != i.Acc);
    try std.testing.expect(f.saturate != i.saturate);
}

test "numericFor: distinct precisions resolve to distinct lanes (⊢ lane injectivity)" {
    // Each Precision tag maps to its own lane type — no two tags share a lane.
    inline for (std.meta.fields(Precision)) |fa| {
        inline for (std.meta.fields(Precision)) |fb| {
            if (fa.value == fb.value) continue;
            const a = comptime numericFor(@enumFromInt(fa.value), .{});
            const b = comptime numericFor(@enumFromInt(fb.value), .{});
            try std.testing.expect(a.Lane != b.Lane);
        }
    }
}

test "numericFor is deterministic/pure: repeated calls agree (⊢ purity)" {
    inline for (std.meta.fields(Precision)) |fld| {
        const p: Precision = @enumFromInt(fld.value);
        const a = comptime numericFor(p, .{});
        const b = comptime numericFor(p, .{});
        try std.testing.expect(a.Lane == b.Lane);
        try std.testing.expect(a.Acc == b.Acc);
        try std.testing.expect(a.saturate == b.saturate);
        try std.testing.expectEqual(a.W, b.W);
    }
}

test "widthFor: returns >= 1 for every lane (scalar fallback floor) (⊢ widthFor law)" {
    try std.testing.expect(comptime widthFor(f32) >= 1);
    try std.testing.expect(comptime widthFor(f64) >= 1);
    try std.testing.expect(comptime widthFor(i8) >= 1);
    try std.testing.expect(comptime widthFor(i16) >= 1);
    try std.testing.expect(comptime widthFor(i32) >= 1);
    try std.testing.expect(comptime widthFor(i64) >= 1);
}

test "numericFor.W agrees with widthFor on the resolved lane (⊢ W coherence)" {
    inline for (std.meta.fields(Precision)) |fld| {
        const p: Precision = @enumFromInt(fld.value);
        const num = comptime numericFor(p, .{});
        try std.testing.expectEqual(comptime widthFor(num.Lane), num.W);
    }
}

test "Precision/active coherence: `active` lists every Precision tag exactly once (⊢ active completeness)" {
    // The active set the build reports must cover the whole enum (no monomorph
    // silently dropped) and contain no duplicates.
    try std.testing.expectEqual(std.meta.fields(Precision).len, numeric.active.len);
    inline for (std.meta.fields(Precision)) |fld| {
        const p: Precision = @enumFromInt(fld.value);
        var seen: usize = 0;
        for (numeric.active) |a| {
            if (a == p) seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

// =====================================================================
// DISABLED negative-case stubs (⊢ @compileError — cannot run live).
//
// These document the rejection laws. Each, if un-commented, MUST abort
// compilation (the listed reason). They are intentionally NOT enabled, because
// a `@compileError` cannot be a passing runtime test — it would fail the whole
// build. They stand as executable-by-hand specifications of the negative space.
// =====================================================================

// DISABLED — un-commenting must produce a COMPILE ERROR.
// Law: a bare array element has no `typeName()`; only the named wrapper structs
// (FeatureFrame, Frame, ...) carry one. The graph's pool-class diagnostics
// cannot name a bare `[K]f32`, which is precisely why FeatureFrame exists.
// Expected failure: "no member named 'typeName' in '[13]f32'".
//
// test "DISABLED: bare [K]f32 has no typeName (⊢ named-wrapper requirement)" {
//     const BareArray = [13]f32;
//     _ = BareArray.typeName(); // <-- compile error: no such decl
// }

// DISABLED — un-commenting must produce a COMPILE ERROR.
// Law: `ChannelLayout.name()` takes `comptime self`; calling it on a runtime
// (non-comptime) layout value is illegal. Frame typeName composition therefore
// only works for comptime-known layouts (which all type-level layouts are).
// Expected failure: unable to evaluate comptime / runtime value used in comptime context.
//
// test "DISABLED: ChannelLayout.name() on a runtime value is rejected (⊢ comptime-self)" {
//     var runtime_layout: ChannelLayout = .mono;
//     runtime_layout = .stereo; // force it to be a runtime var
//     _ = runtime_layout.name(); // <-- compile error: comptime self required
// }

// DISABLED — un-commenting must produce a COMPILE ERROR.
// Law: `numericFor` is exhaustive over `Precision`; there is no prong for a
// non-member tag, and the enum has no such field, so referencing one is an
// error. (Documents that the precision set is closed.)
// Expected failure: "enum 'Precision' has no member named 'f16'".
//
// test "DISABLED: there is no Precision.f16 — the set is closed (⊢ exhaustive/closed set)" {
//     _ = numericFor(.f16, .{}); // <-- compile error: no such enum member
// }
