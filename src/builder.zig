//! The graph builder — the developer-facing authoring surface.
//!
//! You `init` a graph from a `Config`, `add` block instances (each returns a
//! typed node handle), `connect` handles or their typed ports, then `commit` to
//! a frozen `Engine`. Wiring is type-checked at compile time: a port carries its
//! node identity, direction, and element type, so a layout/precision/element
//! mismatch on an edge is a compile error naming the port — not a runtime
//! surprise.
//!
//! This builder accumulates into the comptime-evaluable graph IR and forwards to
//! the existing commit pass. The runtime arena, the full runtime commit, and the
//! live control plane are wired in later phases; here the surface is pinned and
//! the four-verb `add → connect → commit → start` arc type-checks.

const std = @import("std");
const graph = @import("graph.zig");
const port = @import("port.zig");
const engine = @import("engine.zig");
const config = @import("config.zig");

/// A connect endpoint: a typed port (`Port`) plus the runtime node id and port
/// index it names. `connect` reads `Port` (comptime) to type-check the edge and
/// the id/index (runtime) to record it.
pub fn Endpoint(comptime PortT: type) type {
    return struct {
        node_id: usize = 0, // set at handle creation; default keeps `.{}` valid
        index: port.PortIndex = 0,
        pub const Port = PortT;
        pub const is_endpoint = true;
    };
}

/// The output port of a block, as a `PortId` type. A `Map` reads its `process`
/// output; a `Rate`/`VariRate` reads its `pull` output.
fn OutPortType(comptime Block: type) type {
    return switch (port.classify(Block)) {
        .Map => port.MapOutPort(Block),
        .Rate, .VariRate => port.PortId(Block, .out, port.RateOutElem(Block)),
    };
}

/// Does the block have an output port? (A sink does not.)
fn hasOutput(comptime Block: type) bool {
    return switch (port.classify(Block)) {
        .Map => port.mapOutputCount(Block) > 0,
        .Rate, .VariRate => true,
    };
}

/// The type of a handle's `out` field: an output `Endpoint` when the block has
/// an output, otherwise an empty marker (so a sink handle still has the field).
fn OutAccessor(comptime Block: type) type {
    if (hasOutput(Block)) return Endpoint(OutPortType(Block));
    return struct {};
}

fn buildOutAccessor(comptime Block: type, id: usize) OutAccessor(Block) {
    if (comptime hasOutput(Block)) return .{ .node_id = id, .index = 0 };
    return .{};
}

/// Which port to mint for a named accessor field.
const MintKind = enum { param, named_input };

fn mintPortFor(comptime Block: type, comptime name: []const u8, comptime kind: MintKind) type {
    return switch (kind) {
        .param => port.ParamPort(Block, name),
        .named_input => port.NamedInPort(Block, name),
    };
}

/// Build a struct type with one `Endpoint` field per named entry of `spec`,
/// minting each field's port per `kind`. Used for both the named parameter
/// accessor (`node.param.<name>`) and the named input accessor (`node.in.<name>`
/// on a fan-in block).
fn NamedAccessor(comptime Block: type, comptime spec: anytype, comptime kind: MintKind) type {
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;
    comptime var names: [fields.len][:0]const u8 = undefined;
    comptime var types_arr: [fields.len]type = undefined;
    comptime var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (fields, 0..) |f, i| {
        names[i] = f.name;
        types_arr[i] = Endpoint(mintPortFor(Block, f.name, kind));
        attrs[i] = .{};
    }
    const final_names = names;
    const final_types = types_arr;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

fn buildNamedAccessor(comptime Block: type, comptime spec: anytype, comptime kind: MintKind, id: usize) NamedAccessor(Block, spec, kind) {
    var acc: NamedAccessor(Block, spec, kind) = undefined;
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;
    inline for (fields, 0..) |f, i| {
        @field(acc, f.name) = .{ .node_id = id, .index = @intCast(i) };
    }
    return acc;
}

/// The named parameter accessor (`node.param.<name>`), or an empty marker when
/// the block declares no parameter ports.
fn ParamAccessor(comptime Block: type) type {
    if (!@hasDecl(Block, "params")) return struct {};
    return NamedAccessor(Block, Block.params, .param);
}

/// The named input accessor (`node.in.<name>`) for a fan-in block, or an empty
/// marker when the block declares no named inputs.
fn NamedInputAccessor(comptime Block: type) type {
    if (!@hasDecl(Block, "inputs")) return struct {};
    return NamedAccessor(Block, Block.inputs, .named_input);
}

/// A typed node handle returned by `add`. Exposes the block's ports as typed
/// connect endpoints. A block with named inputs (a fan-in) gets `in` as a named
/// accessor (`node.in.<name>`); every other block gets `in` as a homogeneous
/// indexed accessor (`node.in(i)`).
pub fn NodeHandle(comptime Block: type) type {
    if (@hasDecl(Block, "inputs")) {
        return struct {
            id: usize,
            out: OutAccessor(Block),
            in: NamedInputAccessor(Block),
            param: ParamAccessor(Block),

            const Self = @This();
            pub const B = Block;
            pub const is_node_handle = true;

            /// The `set` control verb — move a coefficient (lock-free atomic +
            /// per-block ramp). Stub.
            pub fn set(self: Self, comptime field: anytype, value: anytype) void {
                _ = self;
                _ = field;
                _ = value;
            }
        };
    }
    return struct {
        id: usize,
        out: OutAccessor(Block),
        param: ParamAccessor(Block),

        const Self = @This();
        pub const B = Block;
        pub const is_node_handle = true;

        /// The block's `i`-th input port as a typed endpoint (`node.in(i)`).
        /// An out-of-range index is a compile error.
        pub fn in(self: Self, comptime i: usize) Endpoint(port.MapInPortAt(Block, i)) {
            return .{ .node_id = self.id, .index = @intCast(i) };
        }

        /// The `set` control verb — move a coefficient (lock-free atomic +
        /// per-block ramp). Stub.
        pub fn set(self: Self, comptime field: anytype, value: anytype) void {
            _ = self;
            _ = field;
            _ = value;
        }
    };
}

/// Normalize a connect argument to an output endpoint: a bare handle yields its
/// output port; an endpoint passes through.
fn toOutEndpoint(x: anytype) blk: {
    const T = @TypeOf(x);
    if (@hasDecl(T, "is_endpoint")) break :blk T;
    if (@hasDecl(T, "is_node_handle")) break :blk @TypeOf(x.out);
    @compileError("pan: connect source must be a node handle or an output endpoint");
} {
    const T = @TypeOf(x);
    if (@hasDecl(T, "is_endpoint")) return x;
    return x.out;
}

/// Normalize a connect argument to an input endpoint: a bare handle yields its
/// input port 0 (homogeneous blocks only); an endpoint passes through. A fan-in
/// block must be wired by name (`node.in.<name>`), so a bare fan-in handle is a
/// compile error.
fn toInEndpoint(x: anytype) blk: {
    const T = @TypeOf(x);
    if (@hasDecl(T, "is_endpoint")) break :blk T;
    if (@hasDecl(T, "is_node_handle")) {
        if (@hasDecl(T, "in")) break :blk @TypeOf(x.in(0));
        @compileError("pan: this block has named inputs — wire it via node.in.<name>");
    }
    @compileError("pan: connect destination must be a node handle or an input endpoint");
} {
    const T = @TypeOf(x);
    if (@hasDecl(T, "is_endpoint")) return x;
    return x.in(0);
}

/// The developer-facing graph. Accumulates nodes/edges and commits to an
/// `Engine`.
pub const Graph = struct {
    ir: graph.Graph,
    alloc: std.mem.Allocator,
    cfg: config.Config,

    const Self = @This();

    /// Create a graph for `cfg`. The allocator backs the graph's arena (unused
    /// by this fixed-array stub; the real arena lands with the runtime commit).
    pub fn init(alloc: std.mem.Allocator, cfg: config.Config) Self {
        return .{ .ir = graph.Graph.empty, .alloc = alloc, .cfg = cfg };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Add a block instance; returns its typed node handle. `params` configures
    /// the instance (applied at `initialize` in a later phase).
    pub fn add(self: *Self, comptime Block: type, params: anytype) !NodeHandle(Block) {
        _ = params;
        const id = self.ir.add(Block);
        var h: NodeHandle(Block) = undefined;
        h.id = id;
        h.out = buildOutAccessor(Block, id);
        h.param = if (comptime @hasDecl(Block, "params"))
            buildNamedAccessor(Block, Block.params, .param, id)
        else
            .{};
        if (@hasDecl(Block, "inputs"))
            h.in = buildNamedAccessor(Block, Block.inputs, .named_input, id);
        return h;
    }

    /// Connect an output to an input. Both arguments may be a bare node handle
    /// (its default port) or a typed endpoint (`node.in(i)`, `node.out`,
    /// `node.param.<name>`). The element types are type-checked at compile time.
    pub fn connect(self: *Self, from: anytype, to: anytype) !void {
        const out_ep = toOutEndpoint(from);
        const in_ep = toInEndpoint(to);
        self.ir.connect(@TypeOf(out_ep).Port, out_ep.node_id, out_ep.index, @TypeOf(in_ep).Port, in_ep.node_id, in_ep.index);
    }

    /// Connect a declared feedback (back) edge: same type-check, flagged so the
    /// commit pass removes it before the topological sort and requires its
    /// cycle to contain a delay.
    pub fn connectFeedback(self: *Self, from: anytype, to: anytype) !void {
        const out_ep = toOutEndpoint(from);
        const in_ep = toInEndpoint(to);
        self.ir.connectFeedback(@TypeOf(out_ep).Port, out_ep.node_id, out_ep.index, @TypeOf(in_ep).Port, in_ep.node_id, in_ep.index);
    }

    /// Report the static op count and pool footprint to the engine. Stub
    /// footprint: the sum of edge element sizes (the obviously-correct per-edge
    /// baseline; the colored-pool footprint lands with the runtime commit pass).
    pub fn summarize(self: *const Self) engine.Summary {
        var bytes: usize = 0;
        for (self.ir.edges[0..self.ir.edge_count]) |e| bytes += e.elem_size;
        return .{ .op_count = self.ir.edge_count, .footprint_bytes = bytes };
    }

    /// Commit the graph to a frozen, runnable engine (realtime default).
    /// Everything that can go wrong with the topology is reported here.
    pub fn commit(self: *Self) !engine.Engine {
        return engine.Engine.init(self.alloc, self, .{ .mode = .realtime_streaming });
    }
};

test "DX arc: init → add → connect (handle + indexed) → commit → start" {
    const types = @import("types.zig");
    const Gain = struct {
        const Self = @This();
        gain: f32 = 1.0,
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const Sum2 = struct {
        const Self = @This();
        pub fn process(self: *Self, in0: []const types.Sample(f32), in1: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            for (in0, in1, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
        }
    };

    var g = Graph.init(std.testing.allocator, .{ .precision = .f32, .channels = .mono });
    defer g.deinit();

    const a = try g.add(Gain, .{ .gain = 0.8 });
    const b = try g.add(Gain, .{});
    const mixer = try g.add(Sum2, .{});

    try g.connect(a, b); // bare handle → handle (out port 0 → in port 0)
    try g.connect(a, mixer.in(0)); // handle → indexed input endpoint
    try g.connect(b, mixer.in(1));

    a.set(.gain, 0.5); // control verb stub

    var eng = try g.commit();
    defer eng.deinit();
    try eng.start();
    defer eng.stop();
    eng.schedule(.{ .at_sample = 64, .node = a, .value = 0.0 });
    try std.testing.expectEqual(@as(usize, 3), eng.op_count); // three edges
}

test "DX arc: parameter port endpoint node.param.<name>" {
    const types = @import("types.zig");
    const Lfo = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []types.Scalar(f32)) void {
            _ = self;
            _ = out;
        }
    };
    const Biquad = struct {
        const Self = @This();
        pub const params = .{ .cutoff = types.Scalar(f32), .q = types.Scalar(f32) };
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    var g = Graph.init(std.testing.allocator, .{});
    defer g.deinit();
    const lfo = try g.add(Lfo, .{});
    const bq = try g.add(Biquad, .{});
    try g.connect(lfo, bq.param.cutoff); // output → named parameter endpoint
    var eng = try g.commit();
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 1), eng.op_count);
}
