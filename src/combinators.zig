//! Graph combinators — blocks whose job is structural, not numeric.
//!
//! `Concat` is the **named limit** (a record/labelled product): a comptime
//! struct-of-(name → element-type) spec mints one typed input port per name
//! (`node.in.<name>`) and a one-for-one output row whose field order *is* the
//! canonical feature-matrix column order. Because the column identity is the field
//! *name* (not an integer position), the wiring and the column order are pinned by
//! the same declaration — a transposed matrix is impossible, and a wrong element
//! type on `node.in.<name>` is a compile error naming the port.
//!
//! `ChannelMap` is the C-fold replication of a mono block across `C` channel
//! planes (the product functor `C^(·)` over a subgraph; here realized for a single
//! mono `Map` block — the achievable, useful case). The multi-node-subgraph form
//! is a combinators-phase extension; this file surfaces that boundary rather than
//! pretending the general functor exists.

const std = @import("std");
const types = @import("types.zig");
const port = @import("port.zig");

// ===========================================================================
// Concat — the named heterogeneous fan-in
// ===========================================================================

/// The element type of the `i`-th named input of a Concat `spec` (the spec field's
/// *value* is the element type, e.g. `.mfcc = FeatureFrame(13)`).
fn specElem(comptime spec: anytype, comptime i: usize) type {
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;
    return @field(spec, fields[i].name);
}

/// `Concat(spec)` — wire heterogeneous feature streams into one row by name.
///
/// `spec` is a struct-of-(name → element-type). The block declares those as named
/// inputs (`pub const inputs = spec`), so a downstream `connect(producer,
/// node.in.<name>)` type-checks against the named element type. Its output element
/// is `ConcatOut(spec)` — a struct with one field per name **in declaration order**,
/// which is the canonical column order of the emitted feature matrix. One output
/// row per input hop (a rate-1:1 `Map`).
///
/// The fan-in arity equals the number of named inputs and is bounded by the 8-port
/// per-direction ceiling (law A2). Each arity has an explicit `process` whose const
/// input slices arrive in field order (matching the named-port indices), so the
/// executor's left-to-right input-buffer assignment lines up with the column order.
pub fn Concat(comptime spec: anytype) type {
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;
    const k = fields.len;
    if (k == 0) @compileError("pan: Concat needs at least one named input");
    if (k > port.max_ports_per_direction)
        @compileError(std.fmt.comptimePrint(
            "pan: Concat has {d} inputs, exceeding the {d}-port fan-in ceiling (law A2)",
            .{ k, port.max_ports_per_direction },
        ));
    return switch (k) {
        1 => ConcatN(spec, 1),
        2 => ConcatN(spec, 2),
        3 => ConcatN(spec, 3),
        4 => ConcatN(spec, 4),
        5 => ConcatN(spec, 5),
        6 => ConcatN(spec, 6),
        7 => ConcatN(spec, 7),
        8 => ConcatN(spec, 8),
        else => unreachable,
    };
}

/// The arity-`K` Concat body. One explicit `process` per arity is required because
/// a function's parameter list cannot be synthesized from a comptime count — but
/// the *bodies* are uniform: assemble each output row field-by-field in spec order.
fn ConcatN(comptime spec: anytype, comptime K: usize) type {
    const Out = port.ConcatOut(spec);
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;

    return switch (K) {
        1 => struct {
            const Self = @This();
            pub const inputs = spec;
            pub fn process(self: *Self, a0: []const specElem(spec, 0), out: []Out) void {
                _ = self;
                for (out, 0..) |*o, r| @field(o.*, fields[0].name) = a0[r];
            }
        },
        2 => struct {
            const Self = @This();
            pub const inputs = spec;
            pub fn process(self: *Self, a0: []const specElem(spec, 0), a1: []const specElem(spec, 1), out: []Out) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    @field(o.*, fields[0].name) = a0[r];
                    @field(o.*, fields[1].name) = a1[r];
                }
            }
        },
        3 => struct {
            const Self = @This();
            pub const inputs = spec;
            pub fn process(self: *Self, a0: []const specElem(spec, 0), a1: []const specElem(spec, 1), a2: []const specElem(spec, 2), out: []Out) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    @field(o.*, fields[0].name) = a0[r];
                    @field(o.*, fields[1].name) = a1[r];
                    @field(o.*, fields[2].name) = a2[r];
                }
            }
        },
        4 => struct {
            const Self = @This();
            pub const inputs = spec;
            pub fn process(self: *Self, a0: []const specElem(spec, 0), a1: []const specElem(spec, 1), a2: []const specElem(spec, 2), a3: []const specElem(spec, 3), out: []Out) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    @field(o.*, fields[0].name) = a0[r];
                    @field(o.*, fields[1].name) = a1[r];
                    @field(o.*, fields[2].name) = a2[r];
                    @field(o.*, fields[3].name) = a3[r];
                }
            }
        },
        5 => struct {
            const Self = @This();
            pub const inputs = spec;
            pub fn process(self: *Self, a0: []const specElem(spec, 0), a1: []const specElem(spec, 1), a2: []const specElem(spec, 2), a3: []const specElem(spec, 3), a4: []const specElem(spec, 4), out: []Out) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    @field(o.*, fields[0].name) = a0[r];
                    @field(o.*, fields[1].name) = a1[r];
                    @field(o.*, fields[2].name) = a2[r];
                    @field(o.*, fields[3].name) = a3[r];
                    @field(o.*, fields[4].name) = a4[r];
                }
            }
        },
        6 => struct {
            const Self = @This();
            pub const inputs = spec;
            pub fn process(self: *Self, a0: []const specElem(spec, 0), a1: []const specElem(spec, 1), a2: []const specElem(spec, 2), a3: []const specElem(spec, 3), a4: []const specElem(spec, 4), a5: []const specElem(spec, 5), out: []Out) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    @field(o.*, fields[0].name) = a0[r];
                    @field(o.*, fields[1].name) = a1[r];
                    @field(o.*, fields[2].name) = a2[r];
                    @field(o.*, fields[3].name) = a3[r];
                    @field(o.*, fields[4].name) = a4[r];
                    @field(o.*, fields[5].name) = a5[r];
                }
            }
        },
        7 => struct {
            const Self = @This();
            pub const inputs = spec;
            pub fn process(self: *Self, a0: []const specElem(spec, 0), a1: []const specElem(spec, 1), a2: []const specElem(spec, 2), a3: []const specElem(spec, 3), a4: []const specElem(spec, 4), a5: []const specElem(spec, 5), a6: []const specElem(spec, 6), out: []Out) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    @field(o.*, fields[0].name) = a0[r];
                    @field(o.*, fields[1].name) = a1[r];
                    @field(o.*, fields[2].name) = a2[r];
                    @field(o.*, fields[3].name) = a3[r];
                    @field(o.*, fields[4].name) = a4[r];
                    @field(o.*, fields[5].name) = a5[r];
                    @field(o.*, fields[6].name) = a6[r];
                }
            }
        },
        8 => struct {
            const Self = @This();
            pub const inputs = spec;
            pub fn process(self: *Self, a0: []const specElem(spec, 0), a1: []const specElem(spec, 1), a2: []const specElem(spec, 2), a3: []const specElem(spec, 3), a4: []const specElem(spec, 4), a5: []const specElem(spec, 5), a6: []const specElem(spec, 6), a7: []const specElem(spec, 7), out: []Out) void {
                _ = self;
                for (out, 0..) |*o, r| {
                    @field(o.*, fields[0].name) = a0[r];
                    @field(o.*, fields[1].name) = a1[r];
                    @field(o.*, fields[2].name) = a2[r];
                    @field(o.*, fields[3].name) = a3[r];
                    @field(o.*, fields[4].name) = a4[r];
                    @field(o.*, fields[5].name) = a5[r];
                    @field(o.*, fields[6].name) = a6[r];
                    @field(o.*, fields[7].name) = a7[r];
                }
            }
        },
        else => unreachable,
    };
}

// ===========================================================================
// ChannelMap — replicate a mono block across C channels
// ===========================================================================

/// `ChannelMap(Sub, C)` — run the mono `Map` block `Sub` independently on each of
/// `C` channel planes of a planar `Frame(Lane, .discrete(C))` stream: the product
/// functor `C^(Sub)`. The block owns `C` `Sub` instances (one per plane, so each
/// keeps its own state) and the pool naturally sizes by `C` because the element is
/// a `C`-channel frame.
///
/// `Sub` must be a mono `Map` with `process(self, in: []const Sample(Lane), out:
/// []Sample(Lane))` (the single-block case — the useful 80%). Replicating a
/// *multi-node* subgraph (the `MonoFeatureSub` wrap) is a combinators-phase
/// extension that needs IR-level expansion; it is deliberately **not** implemented
/// here, and a `Sub` that is not a single mono `Map` is a compile error rather than
/// a silent wrong result.
pub fn ChannelMap(comptime Sub: type, comptime C: usize) type {
    if (C == 0) @compileError("pan: ChannelMap needs C >= 1");
    if (port.classify(Sub) != .Map)
        @compileError("pan: ChannelMap(Sub, C) requires Sub to be a single mono Map block " ++
            "(the multi-node-subgraph functor is a combinators-phase extension)");
    const InElem = port.MapInElem(Sub);
    const Lane = InElem.lane;
    if (InElem != types.Sample(Lane) or port.MapOutElem(Sub) != types.Sample(Lane))
        @compileError("pan: ChannelMap(Sub, C) requires Sub to map Sample(Lane) → Sample(Lane)");
    const L: types.ChannelLayout = .{ .discrete = C };
    return struct {
        const Self = @This();
        subs: [C]Sub = [_]Sub{Sub{}} ** C,

        pub fn process(self: *Self, in: types.PlanarConst(Lane, L), out: types.Planar(Lane, L)) void {
            inline for (0..C) |c| {
                // A plane is `[]Lane`; Sample(Lane) = Frame(Lane,.mono) is layout-
                // identical to Lane (one channel), so the plane reinterprets to a
                // `[]Sample(Lane)` the mono Sub consumes.
                const xs: []const types.Sample(Lane) = @ptrCast(in.plane(c));
                const ys: []types.Sample(Lane) = @ptrCast(out.plane(c));
                self.subs[c].process(xs, ys);
            }
        }
    };
}

test "Concat: named fan-in mints ports, ConcatOut column order = declaration order" {
    const Collect = Concat(.{
        .mfcc = types.FeatureFrame(13),
        .centroid = types.Scalar(f32),
        .dominant = types.Scalar(u16),
    });
    try std.testing.expect(port.classify(Collect) == .Map);
    const Out = port.ConcatOut(.{
        .mfcc = types.FeatureFrame(13),
        .centroid = types.Scalar(f32),
        .dominant = types.Scalar(u16),
    });
    const f = @typeInfo(Out).@"struct".fields;
    try std.testing.expectEqualStrings("mfcc", f[0].name);
    try std.testing.expectEqualStrings("centroid", f[1].name);
    try std.testing.expectEqualStrings("dominant", f[2].name);
    // named-input element types are recovered from the spec
    try std.testing.expect(port.NamedInPort(Collect, "centroid").Elem == types.Scalar(f32));
}

test "Concat: assembling rows writes each column from its named input" {
    const Collect = Concat(.{ .a = types.Scalar(f32), .b = types.Scalar(u16) });
    var c: Collect = .{};
    const a = [_]types.Scalar(f32){ .{ .value = 1.5 }, .{ .value = 2.5 } };
    const b = [_]types.Scalar(u16){ .{ .value = 7 }, .{ .value = 9 } };
    var out: [2]port.ConcatOut(.{ .a = types.Scalar(f32), .b = types.Scalar(u16) }) = undefined;
    c.process(&a, &b, &out);
    try std.testing.expectEqual(@as(f32, 1.5), out[0].a.value);
    try std.testing.expectEqual(@as(u16, 7), out[0].b.value);
    try std.testing.expectEqual(@as(f32, 2.5), out[1].a.value);
    try std.testing.expectEqual(@as(u16, 9), out[1].b.value);
}
