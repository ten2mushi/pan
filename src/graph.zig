//! The low-level graph IR — nodes (block instances) and edges (output port →
//! input port wirings). `connect` type-checks `PortId` element types and emits a
//! NAMED `@compileError` on a mismatch. A feedback edge is explicitly declared:
//! the back-edge is removed before the topological sort and its cycle must
//! contain a delay element to be causal.
//!
//! The graph is comptime-evaluable so the commit pass can run at `comptime` on
//! embedded targets: it uses a fixed-capacity array, not a heap list.

const std = @import("std");
const port = @import("port.zig");

/// A node: a block instance identified by a comptime index and its class.
pub const Node = struct {
    /// Comptime-stable identity (also the topological-sort key seed).
    id: usize,
    class: port.BlockClass,
    /// `@typeName` of the block type, for diagnostics / op-list emission.
    type_name: []const u8,
    /// `@sizeOf` of one element on this node's output port — drives the pool
    /// class key `(element_type, element_count)` and the footprint formula.
    out_elem_size: usize,
    /// `@typeName` of the output element type — the pool class discriminator.
    out_elem_name: []const u8,
};

/// An edge: a wiring from `(from_node, from_port)` to `(to_node, to_port)`.
pub const Edge = struct {
    from_node: usize,
    from_port: port.PortIndex,
    to_node: usize,
    to_port: port.PortIndex,
    /// Explicitly-declared feedback edge. Removed before the
    /// topological sort; its SCC must contain a delay (else error.DelayFreeLoop).
    feedback: bool,
    /// `@sizeOf` of the element carried on this edge (pool sizing).
    elem_size: usize,
    /// `@typeName` of the element type carried (pool class discriminator).
    elem_name: []const u8,
};

/// Fixed capacities keep the graph comptime-evaluable (no allocator) so the
/// whole commit pass can run at `comptime` on embedded targets.
pub const max_nodes = 64;
pub const max_edges = 128;

/// The output element type of a block, by class. In a comptime `if` on a
/// comptime-known class, only the taken branch is analyzed — so a Map never
/// touches `Block.pull` and a Rate never touches `Block.process`.
fn outElemOf(comptime Block: type) type {
    if (port.classify(Block) == .Map) return port.MapOutElem(Block);
    // Rate: pull(self, want, out: []Out) — `out` is param 2.
    const f = @typeInfo(@TypeOf(Block.pull)).@"fn";
    return @typeInfo(f.params[2].type.?).pointer.child;
}

pub const Graph = struct {
    nodes: [max_nodes]Node = undefined,
    node_count: usize = 0,
    edges: [max_edges]Edge = undefined,
    edge_count: usize = 0,

    const Self = @This();

    pub const empty: Self = .{};

    /// Add a block instance. Returns the node id. The output element size/name
    /// are read from the block's `process` signature (Map) for pool keying;
    /// Rate blocks report their `pull` output element.
    pub fn add(self: *Self, comptime Block: type) usize {
        const class = comptime port.classify(Block);
        // Derive the output element type in a comptime context so the unused
        // switch prong (which references `Block.pull` for a Map, or
        // `Block.process` for a Rate) is never analyzed for the wrong class.
        const OutElem = comptime outElemOf(Block);
        const id = self.node_count;
        self.nodes[id] = .{
            .id = id,
            .class = class,
            .type_name = @typeName(Block),
            .out_elem_size = @sizeOf(OutElem),
            .out_elem_name = @typeName(OutElem),
        };
        self.node_count += 1;
        return id;
    }

    /// Connect an output `PortId` to an input `PortId`. Type-checks element
    /// types at comptime and emits a NAMED `@compileError` on a mismatch:
    /// element type, direction, and channel layout — the layout rides inside
    /// the `Frame(Lane,L)` element type, so a layout mismatch is just an
    /// element-type mismatch.
    pub fn connect(
        self: *Self,
        comptime OutPort: type,
        out_node: usize,
        out_idx: port.PortIndex,
        comptime InPort: type,
        in_node: usize,
        in_idx: port.PortIndex,
    ) void {
        typeCheckConnect(OutPort, InPort);
        self.addEdge(out_node, out_idx, in_node, in_idx, OutPort.Elem, false);
    }

    /// Connect a declared feedback (back) edge. Same type check;
    /// flagged so the commit pass removes it before the topological sort and
    /// requires its SCC to contain a delay.
    pub fn connectFeedback(
        self: *Self,
        comptime OutPort: type,
        out_node: usize,
        out_idx: port.PortIndex,
        comptime InPort: type,
        in_node: usize,
        in_idx: port.PortIndex,
    ) void {
        typeCheckConnect(OutPort, InPort);
        self.addEdge(out_node, out_idx, in_node, in_idx, OutPort.Elem, true);
    }

    fn typeCheckConnect(comptime OutPort: type, comptime InPort: type) void {
        if (comptime (!port.isPortId(OutPort) or !port.isPortId(InPort)))
            @compileError("pan: connect requires two PortId handles");
        if (OutPort.direction != .out)
            @compileError("pan: connect source must be an output PortId, got " ++
                @typeName(OutPort));
        if (InPort.direction != .in)
            @compileError("pan: connect destination must be an input PortId, got " ++
                @typeName(InPort));
        if (OutPort.Elem != InPort.Elem)
            @compileError("pan: port element-type mismatch on connect: source " ++
                @typeName(OutPort.Node) ++ ".out is " ++ @typeName(OutPort.Elem) ++
                " but destination " ++ @typeName(InPort.Node) ++ ".in expects " ++
                @typeName(InPort.Elem));
    }

    fn addEdge(
        self: *Self,
        out_node: usize,
        out_idx: port.PortIndex,
        in_node: usize,
        in_idx: port.PortIndex,
        comptime Elem: type,
        feedback: bool,
    ) void {
        const e = self.edge_count;
        self.edges[e] = .{
            .from_node = out_node,
            .from_port = out_idx,
            .to_node = in_node,
            .to_port = in_idx,
            .feedback = feedback,
            .elem_size = @sizeOf(Elem),
            .elem_name = @typeName(Elem),
        };
        self.edge_count += 1;
    }
};

test "connect type-checks matching PortIds; graph records the edge" {
    const types = @import("types.zig");
    const Gain = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    var g = Graph.empty;
    const a = g.add(Gain);
    const b = g.add(Gain);
    g.connect(port.MapOutPort(Gain), a, 0, port.MapInPort(Gain), b, 0);
    try std.testing.expectEqual(@as(usize, 2), g.node_count);
    try std.testing.expectEqual(@as(usize, 1), g.edge_count);
    try std.testing.expect(!g.edges[0].feedback);
    try std.testing.expectEqual(@sizeOf(types.Sample(f32)), g.edges[0].elem_size);
}

test "feedback edge is explicitly flagged (catalog §5.2)" {
    const types = @import("types.zig");
    const Gain = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    var g = Graph.empty;
    const a = g.add(Gain);
    g.connectFeedback(port.MapOutPort(Gain), a, 0, port.MapInPort(Gain), a, 0);
    try std.testing.expect(g.edges[0].feedback);
}

// === Yoneda coverage additions =========================================
// The graph is observed by the commit pass through the {node, edge} records
// it accumulates: `add` mints node identity + the pool-class key fields
// (out_elem_size/out_elem_name/class), and `connect`/`connectFeedback` record
// the edge endpoints, the feedback flag, and the carried element size/name —
// AFTER a comptime type-check that rejects mismatches by name. We pin the
// record contents exactly (they drive footprint + coloring), the id sequence,
// the Rate-node path through `add`, and DOCUMENT the negative @compileError
// cases (which cannot run as live tests) as disabled stubs.

const t = @import("types.zig");

const GainF32 = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const t.Sample(f32), out: []t.Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

test "add returns sequential ids and records node identity + pool-class key" {
    var g = Graph.empty;
    const a = g.add(GainF32);
    const b = g.add(GainF32);
    const c = g.add(GainF32);
    // Ids are the insertion order (the topo-sort key seed).
    try std.testing.expectEqual(@as(usize, 0), a);
    try std.testing.expectEqual(@as(usize, 1), b);
    try std.testing.expectEqual(@as(usize, 2), c);
    try std.testing.expectEqual(@as(usize, 3), g.node_count);
    // Each node carries its own id, its class, and the output-element pool key.
    try std.testing.expectEqual(@as(usize, 1), g.nodes[1].id);
    try std.testing.expect(g.nodes[1].class == .Map);
    try std.testing.expectEqual(@sizeOf(t.Sample(f32)), g.nodes[1].out_elem_size);
    try std.testing.expectEqualStrings("Frame(f32,mono)", t.Sample(f32).typeName());
    // out_elem_name is the @typeName of the output element (pool discriminator).
    try std.testing.expect(std.mem.indexOf(u8, g.nodes[1].out_elem_name, "Frame") != null);
}

test "Graph.empty starts with zero nodes and zero edges" {
    const g = Graph.empty;
    try std.testing.expectEqual(@as(usize, 0), g.node_count);
    try std.testing.expectEqual(@as(usize, 0), g.edge_count);
}

test "connect records BOTH endpoints (node ids + u3 port indices) faithfully" {
    var g = Graph.empty;
    const a = g.add(GainF32);
    const b = g.add(GainF32);
    g.connect(port.MapOutPort(GainF32), a, 0, port.MapInPort(GainF32), b, 0);
    const e = g.edges[0];
    try std.testing.expectEqual(@as(usize, 0), e.from_node);
    try std.testing.expectEqual(@as(port.PortIndex, 0), e.from_port);
    try std.testing.expectEqual(@as(usize, 1), e.to_node);
    try std.testing.expectEqual(@as(port.PortIndex, 0), e.to_port);
    try std.testing.expect(!e.feedback);
    // The edge carries the element size+name for pool sizing.
    try std.testing.expectEqual(@sizeOf(t.Sample(f32)), e.elem_size);
    try std.testing.expect(std.mem.indexOf(u8, e.elem_name, "Frame") != null);
}

test "multiple edges accumulate in order; edge_count tracks them" {
    var g = Graph.empty;
    const a = g.add(GainF32);
    const b = g.add(GainF32);
    const c = g.add(GainF32);
    g.connect(port.MapOutPort(GainF32), a, 0, port.MapInPort(GainF32), b, 0);
    g.connect(port.MapOutPort(GainF32), b, 0, port.MapInPort(GainF32), c, 0);
    try std.testing.expectEqual(@as(usize, 2), g.edge_count);
    try std.testing.expectEqual(@as(usize, 0), g.edges[0].from_node);
    try std.testing.expectEqual(@as(usize, 1), g.edges[1].from_node);
    try std.testing.expectEqual(@as(usize, 2), g.edges[1].to_node);
}

test "connectFeedback type-checks identically but flags the edge as feedback" {
    // Same element-type check as connect (a feedback edge is still typed); only
    // the `feedback` discriminator differs — that flag is what the commit pass
    // removes before the topological sort.
    var g = Graph.empty;
    const a = g.add(GainF32);
    const b = g.add(GainF32);
    g.connect(port.MapOutPort(GainF32), a, 0, port.MapInPort(GainF32), b, 0);
    g.connectFeedback(port.MapOutPort(GainF32), b, 0, port.MapInPort(GainF32), a, 0);
    try std.testing.expect(!g.edges[0].feedback);
    try std.testing.expect(g.edges[1].feedback);
    // Both edges still carry the correct element metadata.
    try std.testing.expectEqual(g.edges[0].elem_size, g.edges[1].elem_size);
}

test "add records a Rate node and its pull-output element as the pool key" {
    // `add` derives out_elem from `pull`'s param-2 for a Rate (graph.zig
    // outElemOf), NOT from `process` — proving the class-dependent branch.
    const Framer = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 64 };
        pub const algorithmic_latency: usize = 0;
        pub fn pull(self: *Self, want: usize, out: []t.FeatureFrame(64)) usize {
            _ = self;
            _ = out;
            return want;
        }
    };
    var g = Graph.empty;
    const id = g.add(Framer);
    try std.testing.expect(g.nodes[id].class == .Rate);
    try std.testing.expectEqual(@sizeOf(t.FeatureFrame(64)), g.nodes[id].out_elem_size);
    try std.testing.expect(std.mem.indexOf(u8, g.nodes[id].out_elem_name, "FeatureFrame") != null);
}

test "an edge carries the element size matching its lane/channel count" {
    // A wider element => a wider edge buffer. Pin that the recorded elem_size
    // tracks the actual element (stereo f32 is 8 bytes, mono i16 is 2).
    const Stereo = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const t.Frame(f32, .stereo), out: []t.Frame(f32, .stereo)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    var g = Graph.empty;
    const a = g.add(Stereo);
    const b = g.add(Stereo);
    g.connect(port.MapOutPort(Stereo), a, 0, port.MapInPort(Stereo), b, 0);
    try std.testing.expectEqual(@as(usize, 8), g.edges[0].elem_size);
}

// EXPECTED-@compileError cases of connect (a wired element-type mismatch is a
// compile error). These abort compilation and so cannot be runtime tests; they
// are pinned as DISABLED stubs. Un-commenting any one MUST turn the build red
// with the quoted NAMED diagnostic.
//
//   test "EXPECTED COMPILE ERROR: element-type mismatch on connect" {
//       const F32 = GainF32;
//       const I16 = struct {
//           const Self = @This();
//           pub fn process(_: *Self, _: []const t.Sample(i16), _: []t.Sample(i16)) void {}
//       };
//       var g = Graph.empty;
//       const a = g.add(F32);
//       const b = g.add(I16);
//       // source out = Frame(f32,1), dest in = Frame(i16,1) => mismatch:
//       g.connect(port.MapOutPort(F32), a, 0, port.MapInPort(I16), b, 0);
//       // => "port element-type mismatch on connect: ..."
//   }
//   test "EXPECTED COMPILE ERROR: channel-count mismatch (C differs)" {
//       const Mono = GainF32;
//       const Stereo = struct {
//           const Self = @This();
//           pub fn process(_: *Self, _: []const t.Frame(f32, 2), _: []t.Frame(f32, 2)) void {}
//       };
//       var g = Graph.empty;
//       const a = g.add(Mono);
//       const b = g.add(Stereo);
//       // Frame(f32,1) -> Frame(f32,2): a C-mismatch IS an element mismatch:
//       g.connect(port.MapOutPort(Mono), a, 0, port.MapInPort(Stereo), b, 0);
//       // => "port element-type mismatch on connect"
//   }
//   test "EXPECTED COMPILE ERROR: swapped direction (in as source)" {
//       var g = Graph.empty;
//       const a = g.add(GainF32);
//       const b = g.add(GainF32);
//       // Passing an INPUT PortId as the source:
//       g.connect(port.MapInPort(GainF32), a, 0, port.MapInPort(GainF32), b, 0);
//       // => "connect source must be an output PortId"
//   }
//   test "EXPECTED COMPILE ERROR: a non-PortId handle" {
//       var g = Graph.empty;
//       const a = g.add(GainF32);
//       const b = g.add(GainF32);
//       g.connect(u32, a, 0, port.MapInPort(GainF32), b, 0);
//       // => "connect requires two PortId handles"
//   }
