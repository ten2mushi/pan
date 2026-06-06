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
const graph = @import("graph.zig");
const engine = @import("engine.zig");

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

// ===========================================================================
// Subgraph — the block-size-1 subgraph combinator (single-pass loop fusion +
// sample-accurate tight feedback)
// ===========================================================================
//
// A `Map` block exposes only a per-WINDOW kernel `process(self, in, out)` — there
// is no per-sample kernel. So the only way to make a chain of Maps run as a SINGLE
// fused pass (the intermediate value never round-trips memory) is to drive the
// inner blocks one sample at a time: at window length 1, each inner kernel's loop
// degenerates to one iteration, and the comptime-monomorphized inner replay inlines
// into the outer per-sample loop, so adjacent maps `g ∘ f` compose into one pass
// with bit-identical output. This realizes categorical composition concretely:
// fusion is just composition of rate-1:1 type-stable morphisms, and the law it must
// honour is `(g ∘ f)(x) = g(f(x))` sample-for-sample.
//
// Driving at window length 1 also makes feedback SAMPLE-ACCURATE for free. The
// commit pass satisfies a declared feedback (back-)edge from LAST render call's
// persistent z⁻¹ buffer; at window length 1 one render call IS one sample, so a
// feedback edge carries EXACTLY one sample of latency. A delay-guarded cycle inside
// the sub-graph therefore reproduces a hand-fused tight-feedback recurrence (e.g.
// `y[n] = x[n] + g·y[n−D]`) exactly, with the loop closed at the sample, not the
// block.
//
// Realization (reuse-maximizing): the wrapped sub-graph is committed and run by the
// frozen Tier-A `engine.Executor` at `block_size = 1`. The combinator instance HOLDS
// that inner executor; its pool (the colored scratch prefix + the persistent z⁻¹
// tail) lives inside the instance, so feedback state persists across outer samples
// AND across outer `process` calls exactly as a hand-fused kernel's ring does. Per
// outer sample i: poke the inner `Inlet` source's current cell with `in[i]`, replay
// the inner op-list once, read the inner `Outlet` sink's captured cell into `out[i]`.

/// `Inlet(Elem)` — the sub-graph's single-sample input endpoint: a zero-sample-input
/// source `Map` whose `process(out)` writes its one stored `sample` into the (length-1)
/// output window. The `Subgraph` driver sets `sample` to the current outer input
/// sample before each inner render. Author wires it as the head of the inner graph
/// (`Inlet → … → Outlet`) so the inner graph is source-rooted. Located inside the
/// inner block list by the `is_subgraph_inlet` marker, mirroring how the offline
/// executor finds its source by `is_offline_source`.
pub fn Inlet(comptime Elem: type) type {
    return struct {
        const Self = @This();
        /// The current sample to emit on the next inner render (set by the driver).
        sample: Elem = std.mem.zeroes(Elem),
        /// Marker so `Subgraph` can locate the unique injection node at comptime.
        pub const is_subgraph_inlet = true;

        pub fn process(self: *Self, out: []Elem) void {
            // Driven at window length 1: emit the one stored sample. (Defensive over
            // a longer window: the same sample fills it — never exercised at N=1.)
            for (out) |*o| o.* = self.sample;
        }
    };
}

/// `Outlet(Elem)` — the sub-graph's single-sample output endpoint: an output-only
/// `Map` (a sink) whose `process(in)` captures the last sample of its (length-1)
/// input window into its `sample` cell. The `Subgraph` driver reads `sample` after
/// each inner render. Located by the `is_subgraph_outlet` marker.
pub fn Outlet(comptime Elem: type) type {
    return struct {
        const Self = @This();
        /// The sample captured on the most recent inner render (read by the driver).
        sample: Elem = std.mem.zeroes(Elem),
        pub const is_subgraph_outlet = true;

        pub fn process(self: *Self, in: []const Elem) void {
            // At window length 1 this captures the single rendered sample; over a
            // longer window the last sample wins (never exercised at N=1).
            for (in) |x| self.sample = x;
        }
    };
}

/// Find the node id of the unique block in `sub_blocks` carrying the marker decl
/// `marker` (`is_subgraph_inlet` / `is_subgraph_outlet`). Exactly one is required;
/// zero or many is a loud compile error naming the violated contract.
fn endpointNode(comptime sub_blocks: []const type, comptime marker: []const u8, comptime which: []const u8) usize {
    comptime {
        var found: ?usize = null;
        for (sub_blocks, 0..) |Block, i| {
            if (@hasDecl(Block, marker)) {
                if (found != null)
                    @compileError("pan: Subgraph sub-graph declares more than one " ++ which ++
                        " — wrap the body with exactly one Inlet and one Outlet");
                found = i;
            }
        }
        if (found) |id| return id;
        @compileError("pan: Subgraph sub-graph declares no " ++ which ++
            " — the body must be wrapped Inlet → … → Outlet (an " ++ which ++
            " roots/terminates the single-sample driver)");
    }
}

/// Reject a sub-block that would expose an unbound PARAMETER port or EVENT lane on
/// the OUTER `Subgraph` interface. v1 scope: the combinator forwards no control plane
/// — a sub-graph that declares parameter ports (`params`) or consumes an event lane
/// has external control inputs the outer `process(in, out)` cannot deliver, so fail
/// loud rather than silently drop them. (The two endpoint markers are exempt: they
/// are the driver's own injection/capture cells, not author-facing control.)
fn rejectControlPorts(comptime sub_blocks: []const type) void {
    comptime {
        for (sub_blocks) |Block| {
            if (@hasDecl(Block, "params"))
                @compileError("pan: Subgraph sub-block " ++ @typeName(Block) ++
                    " declares parameter ports — outer parameter forwarding is out of scope" ++
                    " (v1 wraps only param-free sample chains/cycles)");
            if (port.isEventConsumer(Block))
                @compileError("pan: Subgraph sub-block " ++ @typeName(Block) ++
                    " consumes an event lane — outer event forwarding is out of scope" ++
                    " (v1 wraps only event-free sample chains/cycles)");
        }
    }
}

/// Build the inner executor's all-default `instances` tuple (one block per node).
/// The `Executor` struct gives `instances` no aggregate default — it is a tuple of
/// arbitrary block types — so each node is default-constructed here; every sub-block
/// carries field defaults, and the `Subgraph` caller seeds coefficients afterward via
/// `inner.instances[id]`.
fn defaultInstances(comptime sub_blocks: []const type) std.meta.Tuple(sub_blocks) {
    var t: std.meta.Tuple(sub_blocks) = undefined;
    inline for (sub_blocks, 0..) |Block, i| t[i] = Block{};
    return t;
}

/// `Subgraph(sub_g, sub_blocks)` — wrap a committed inner sub-graph as ONE rate-1:1
/// `Map` that runs the sub-graph at window length 1 once per outer sample.
///
/// `sub_g` is the inner graph (one node per entry of `sub_blocks`, in node-id order,
/// the `Executor` contract) wrapped `Inlet → … → Outlet`: exactly one block declares
/// `is_subgraph_inlet` (the input endpoint) and exactly one declares
/// `is_subgraph_outlet` (the output endpoint). The outer block's input element is the
/// `Inlet`'s element and its output element is the `Outlet`'s element.
///
/// Semantics — for an outer window `in`/`out` of length L, for each i in 0..L:
/// set the inner `Inlet`'s current sample to `in[i]`, render the inner graph once
/// (window length 1), and read the inner `Outlet`'s captured sample into `out[i]`.
/// Inner persistent state (delay rings, feedback z⁻¹ tail) lives in the held inner
/// executor and threads across both samples and outer calls, so a delay-guarded
/// feedback cycle is closed at the sample with exactly one sample of latency.
pub fn Subgraph(comptime sub_g: graph.Graph, comptime sub_blocks: []const type) type {
    if (sub_blocks.len != sub_g.node_count)
        @compileError("pan: Subgraph needs exactly one block type per sub-graph node");
    rejectControlPorts(sub_blocks);

    const inlet_id = endpointNode(sub_blocks, "is_subgraph_inlet", "Inlet");
    const outlet_id = endpointNode(sub_blocks, "is_subgraph_outlet", "Outlet");

    const InElem = port.MapOutElem(sub_blocks[inlet_id]); // Inlet's emitted element
    const OutElem = port.MapInElem(sub_blocks[outlet_id]); // Outlet's captured element

    // Drive the inner graph one sample at a time: the only window length at which the
    // inner kernels' per-window loops collapse to a single iteration that inlines into
    // the outer loop (the fusion mechanism) and at which a feedback edge is exactly
    // one sample of latency (the tight-feedback mechanism).
    const inner_g = comptime blk: {
        var g2 = sub_g;
        g2.block_size = 1;
        break :blk g2;
    };
    const InnerExec = engine.Executor(inner_g, sub_blocks);

    return struct {
        const Self = @This();
        /// The inner Tier-A executor: its block instances (one per sub-graph node)
        /// and its flat pool (colored scratch + persistent z⁻¹ tail) live here, so
        /// the inner feedback/delay state persists across outer samples and calls.
        /// The caller may seed inner block coefficients via `inner.instances[id]`.
        /// The inner executor's `instances` tuple has no aggregate default (it is a
        /// tuple of the sub-block types), so each block is explicitly default-
        /// constructed here — every sub-block carries field defaults, so `.{}` per
        /// node is the all-default instance the caller then seeds.
        inner: InnerExec = .{ .instances = defaultInstances(sub_blocks) },

        pub fn process(self: *Self, in: []const InElem, out: []OutElem) void {
            // The realtime token is a witness-only value (the inner `render` consumes
            // it solely as proof flush-to-zero was set on the calling thread). The
            // outer `process` runs on whatever thread the outer executor already
            // entered; constructing the default token here adds no syscall and never
            // touches the FP control word — `enterRealtimeThread` is NOT called per
            // sample. The default fields are the entered witness.
            const token = engine.RealtimeToken{};
            for (in, out) |x, *y| {
                // Poke the inlet, render one inner sample, read the outlet. The inner
                // op-list is comptime-fixed, so this replay monomorphizes/inlines into
                // a single fused pass over the sub-graph's kernels.
                self.inner.instances[inlet_id].sample = x;
                self.inner.render(token);
                y.* = self.inner.instances[outlet_id].sample;
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
