//! channelmap_functoriality_test — the functoriality obligation for the
//! `ChannelMap` combinator (`src/combinators.zig`).
//!
//! `ChannelMap(Sub, C)` is *modelled as* the C-fold product functor `C^(·)` on mono
//! blocks. The corpus constructs NO functoriality proof, so functoriality is an
//! **obligation, ≈ tested** (catalog §4.4): the combinator must preserve composition
//! and identity, i.e.
//!   - **F(g ∘ f) = F(g) ∘ F(f)** — a `ChannelMap` of a composite mono block equals
//!     the composite of the per-stage `ChannelMap`s; and
//!   - **F(id) = id** — a `ChannelMap` of the identity is the identity.
//! Because `ChannelMap` runs the mono `Sub` independently on each channel plane, both
//! laws hold by construction; this harness pins them **bit-exactly** (pan-vs-pan), so
//! a future refactor that broke per-plane independence would fail loud.
//!
//! COMPARISON MODE: pan-vs-pan — always BIT-EXACT (`std.testing.expectEqual`).
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring,
//! per project Rules 13/14).

const std = @import("std");
const pan = @import("pan");

const Sample = pan.Sample;

// Stateless mono Map stages (Sample(f32) → Sample(f32)).
const ScaleBy2 = struct { // f
    pub fn process(_: *@This(), in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| y.ch[0] = x.ch[0] * 2.0;
    }
};
const AddHalf = struct { // g
    pub fn process(_: *@This(), in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| y.ch[0] = x.ch[0] + 0.5;
    }
};
const ScaleThenAdd = struct { // g ∘ f, fused into one mono block: (x·2)+0.5
    pub fn process(_: *@This(), in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| y.ch[0] = x.ch[0] * 2.0 + 0.5;
    }
};
const Ident = struct {
    pub fn process(_: *@This(), in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| y.ch[0] = x.ch[0];
    }
};

const C = 4;
const N = 8;
const L: pan.types.ChannelLayout = .{ .discrete = C };

fn fillRamp(buf: *[C * N]f32) void {
    for (buf, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.123 - 1.0;
}

test "ChannelMap functoriality: F(g∘f) = F(g)∘F(f), bit-exact (catalog §4.4)" {
    const CmF = pan.combinators.ChannelMap(ScaleBy2, C);
    const CmG = pan.combinators.ChannelMap(AddHalf, C);
    const CmGF = pan.combinators.ChannelMap(ScaleThenAdd, C);

    var in_buf: [C * N]f32 = undefined;
    fillRamp(&in_buf);

    // Left side: F(g∘f) — one ChannelMap of the fused composite.
    var lhs_buf: [C * N]f32 = undefined;
    var cmgf: CmGF = .{};
    cmgf.process(
        pan.PlanarConst(f32, L).fromBase(@as([*]const f32, &in_buf), N),
        pan.Planar(f32, L).fromBase(@as([*]f32, &lhs_buf), N),
    );

    // Right side: F(g) ∘ F(f) — ChannelMap(f) then ChannelMap(g).
    var mid_buf: [C * N]f32 = undefined;
    var rhs_buf: [C * N]f32 = undefined;
    var cmf: CmF = .{};
    var cmg: CmG = .{};
    cmf.process(
        pan.PlanarConst(f32, L).fromBase(@as([*]const f32, &in_buf), N),
        pan.Planar(f32, L).fromBase(@as([*]f32, &mid_buf), N),
    );
    cmg.process(
        pan.PlanarConst(f32, L).fromBase(@as([*]const f32, &mid_buf), N),
        pan.Planar(f32, L).fromBase(@as([*]f32, &rhs_buf), N),
    );

    // Functoriality: the two whole plane-major buffers are bit-identical.
    for (lhs_buf, rhs_buf) |a, b| try std.testing.expectEqual(a, b);
}

test "ChannelMap functoriality: F(id) = id, bit-exact (catalog §4.4)" {
    const CmId = pan.combinators.ChannelMap(Ident, C);
    var in_buf: [C * N]f32 = undefined;
    fillRamp(&in_buf);
    var out_buf: [C * N]f32 = undefined;
    var cm: CmId = .{};
    cm.process(
        pan.PlanarConst(f32, L).fromBase(@as([*]const f32, &in_buf), N),
        pan.Planar(f32, L).fromBase(@as([*]f32, &out_buf), N),
    );
    for (in_buf, out_buf) |a, b| try std.testing.expectEqual(a, b); // identity preserved
}

test "ChannelMap: each plane is processed independently (per-channel state isolation)" {
    // F(f) applied to C distinct channel ramps gives, per plane, exactly the mono f
    // of that plane — no cross-plane bleed (the product functor's components are
    // independent). This is the structural premise the functoriality proof rests on.
    const CmF = pan.combinators.ChannelMap(ScaleBy2, C);
    var in_buf: [C * N]f32 = undefined;
    fillRamp(&in_buf);
    var out_buf: [C * N]f32 = undefined;
    var cm: CmF = .{};
    cm.process(
        pan.PlanarConst(f32, L).fromBase(@as([*]const f32, &in_buf), N),
        pan.Planar(f32, L).fromBase(@as([*]f32, &out_buf), N),
    );
    // Each plane c sample i must equal 2× the corresponding input — independently.
    for (0..C) |c| {
        for (0..N) |i| {
            const idx = c * N + i;
            try std.testing.expectEqual(in_buf[idx] * 2.0, out_buf[idx]);
        }
    }
}
