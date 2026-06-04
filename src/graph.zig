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
///
/// Beyond identity, a node carries the small set of block-derived facts the
/// commit pass reads: the rate ratio and group delay (for scheduling and the
/// later plugin-delay pass), the persistent-state sizes (for the footprint), and
/// the two structural flags the validation stages key off — whether the block is
/// a SOURCE (a zero-sample-input generator whose output length comes from the
/// pull demand, so it may legally sit at the head of a path) and whether it is a
/// DELAY element (so a feedback cycle through it is causal). Every field is read
/// off the block type once, at `add`, so the commit pass never re-reflects.
pub const Node = struct {
    /// Comptime-stable identity (also the topological-sort key seed).
    id: usize,
    class: port.BlockClass,
    /// `@typeName` of the block type, for diagnostics / op-list emission.
    type_name: []const u8,
    /// `@sizeOf` of one element on this node's output port — drives the pool
    /// class key `(element_type, element_count)` and the footprint formula. Zero
    /// for a sink (no output port).
    out_elem_size: usize,
    /// `@typeName` of the output element type — the pool class discriminator.
    /// `"(sink)"` for a block with no output port.
    out_elem_name: []const u8,
    /// True iff the block has zero sample-input ports: a generator (oscillator,
    /// noise, file/stream source) whose output length is set by the pull demand,
    /// not by an input slice. A path head must be a source (or a persistent
    /// generator) — otherwise it has no producer for its inputs (the
    /// source-rooted rule).
    is_source: bool,
    /// True iff the block is a delay element (a unit delay / delay line, or a
    /// fused tight-feedback kernel with a declared internal one-block delay). A
    /// feedback cycle is causal only if it contains at least one such element,
    /// because this block's output must then depend solely on a *previous*
    /// block's looped value.
    is_delay: bool,
    /// The persistent ring length (in elements) of a delay element; 0 otherwise.
    /// This is pool-excluded state (its live range spans every callback), and it
    /// contributes the feedback/persistent term of the footprint.
    delay_len: usize,
    /// Worst-case group delay introduced by the block, in samples of its own
    /// rate domain. 0 for a pure rate-1:1 map. Read by the plugin-delay pass.
    algorithmic_latency: usize,
    /// The output:input rate ratio `p:q` (1:1 for a map). Read by the rate
    /// scheduler when propagating demand upstream.
    out_per_in_p: usize,
    out_per_in_q: usize,
    /// The author's M4 assertion that the block reads each input fully before
    /// writing the aliased output, so its single output edge may share the input
    /// buffer (in-place). Consumed by the in-place coalescing gate (a later
    /// phase); recorded here so the gate has it.
    aliasing_safe: bool,
    /// Per-block persistent state bytes (coefficients, window tables, …) — the
    /// per-block term of the footprint. 0 unless the block declares it.
    state_size: usize,
    /// Which clock grid this node's I/O lives on. A single audio domain (0) for
    /// every graph until rate-elastic blocks introduce a second grid; carried so
    /// the per-rate-domain delay pass has it.
    rate_domain: usize,
    /// This node's I/O sample rate (Hz). Uniform across a graph until rate
    /// conversion is introduced; the negotiate pass compares a producer's and
    /// consumer's rate to decide whether a resampler coercion is required.
    sample_rate: u32,
    /// Bitset over parameter-slot indices marked as driven by an external
    /// `set`/`schedule` (bit i ⇒ slot i is set-driven). The one-source check
    /// rejects a slot that is ALSO fed by a wired parameter edge. `set`/`schedule`
    /// populate this in a later phase; the commit-time check lives here now.
    set_param_slots: u8,
    /// True iff this node was synthesized by the negotiation pass as a COERCION
    /// (a resampler on a sample-rate mismatch, a cast, a ramp/hold) inserted to
    /// make the diagram commute — not an author node. The runtime engine binds a
    /// built-in coercion kernel for it rather than looking it up in the author's
    /// bound-instance set.
    is_coercion: bool = false,
    /// True iff this node is BYPASSED. The bypass-preserves-latency law: a bypassed
    /// block with `algorithmic_latency > 0` must still delay its signal by exactly
    /// that latency (else bypassing shifts timing and breaks alignment on parallel
    /// paths). The plugin-delay-compensation pass (`insertPdc`) routes a
    /// compensating delay for it and sets `pdc_compensated`; an UNcompensated
    /// bypassed latent block (a commit on the raw graph, before `insertPdc`) is
    /// rejected loudly rather than silently shifting timing.
    bypassed: bool = false,
    /// Set by the plugin-delay-compensation pass when it has routed a compensating
    /// delay for this node's latency (a bypassed latent block, or a comp-delay
    /// inserted on a shorter fan-in branch). Clears the bypass-uncompensated reject.
    pdc_compensated: bool = false,
    /// True iff this node is a PDC compensating delay synthesized by `insertPdc`
    /// (a `DelayLine` on a shorter fan-in branch / a bypass passthrough delay). The
    /// runtime engine binds a built-in delay kernel for it, like a coercion node.
    is_pdc: bool = false,
    /// True iff this node is a GROWABLE sink (a `FeatureCollectorSink`, declaring
    /// `growable_sink`): a sink that may `realloc` past its capacity hint. That is
    /// legal only on a non-RT pull root — the contained H1 exception. Committing a
    /// graph containing one for a realtime root is rejected (law A8): a growable
    /// realloc cannot sit on the audio deadline.
    is_growable_sink: bool = false,
};

/// A forward edge: a wiring from `(from_node, from_port)` to `(to_node, to_port)`.
/// Feedback (back) edges live in a separate `FeedbackEdge` list (the z⁻¹ split),
/// so the topological sort sees only the DAG and the SCC check unions both.
pub const Edge = struct {
    from_node: usize,
    from_port: port.PortIndex,
    to_node: usize,
    to_port: port.PortIndex,
    /// Vestigial on a forward edge (always false); kept so hand-built edge
    /// literals that set it still compile. Declared feedback rides in the
    /// `FeedbackEdge` list, not here.
    feedback: bool = false,
    /// `@sizeOf` of the element carried on this edge (pool sizing).
    elem_size: usize,
    /// `@typeName` of the element type carried (pool class discriminator).
    elem_name: []const u8,
    /// True iff this is a wired PARAMETER (control) edge — a side input carrying
    /// one coefficient per render call, exempt from the rate-1:1 law and subject
    /// to the one-source rule (a slot driven by both a wire and `set` is a commit
    /// error). False for an ordinary sample/stream edge.
    is_param: bool = false,
    /// Channel count of the carried element (1 for a non-`Frame` element). Lets
    /// the negotiate pass reason about channel up/down-mix coercion without
    /// re-parsing the element name.
    channels: u16 = 1,
};

/// A declared feedback (back) edge — the z⁻¹ write/read split. Its **write side**
/// is produced THIS block; its **read side** is satisfied from the persistent
/// value produced LAST block, so the edge imposes no scheduling order (it is
/// removed from the topological sort) but DOES close a cycle for the
/// SCC-has-delay check. Same direction as a forward edge (producer → consumer)
/// for reachability.
pub const FeedbackEdge = struct {
    /// Producer side (this block's output that feeds back).
    write_node: usize,
    write_port: port.PortIndex,
    /// Consumer side (where the previous block's value is read in).
    read_node: usize,
    read_port: port.PortIndex,
    elem_size: usize,
    elem_name: []const u8,
};

/// Fixed capacities keep the graph comptime-evaluable (no allocator) so the
/// whole commit pass can run at `comptime` on embedded targets.
pub const max_nodes = 64;
pub const max_edges = 128;

/// Upper bound on distinct buffer ids a plan can mint: one per pool color
/// (≤ one per produced value, itself ≤ `max_edges`) PLUS one persistent z⁻¹
/// buffer per feedback edge (≤ `max_edges`). The buffer-id → byte-window
/// tables are sized to this so a persistent id `pool_count + fi` never indexes
/// out of bounds even in the per-edge baseline (no coloring, every value its
/// own buffer) of a maximally-feedback graph.
pub const max_buffers = max_edges * 2;

/// Does the block have a sample output port? A `Map` sink (input only) has none;
/// a `Rate`/`VariRate` always produces through `pull`.
fn hasOutput(comptime Block: type) bool {
    return switch (port.classify(Block)) {
        .Map => port.mapOutputCount(Block) > 0,
        .Rate, .VariRate => true,
    };
}

/// The output element type of a block, by class. In a comptime `if` on a
/// comptime-known class, only the taken branch is analyzed — so a Map never
/// touches `Block.pull` and a Rate never touches `Block.process`. Caller must
/// have checked `hasOutput(Block)` first (a sink has no output element).
fn outElemOf(comptime Block: type) type {
    if (port.classify(Block) == .Map) return port.MapOutElem(Block);
    // Rate: pull(self, want, out) — `out` is param 2 (a slice or planar view).
    return port.RateOutElem(Block);
}

/// Read the block's rate ratio `p:q`. A `Map` is rate-1:1; a `Rate` declares
/// `out_per_in = .{ p, q }`. (A `VariRate`'s scheduling uses its `rate_bounds`
/// min endpoint — wired in with the rate-elastic blocks; here it falls back to
/// 1:1, which no committed graph yet exercises.)
fn ratioOf(comptime Block: type) struct { p: usize, q: usize } {
    if (@hasDecl(Block, "out_per_in")) {
        const r = Block.out_per_in;
        return .{ .p = r[0], .q = r[1] };
    }
    // A VariRate plans on its WORST-CASE (min) ratio endpoint — the most input
    // ever needed for a given demand (rate_bounds.min). Falls back to 1:1.
    if (@hasDecl(Block, "rate_bounds")) {
        const m = Block.rate_bounds.min;
        return .{ .p = m[0], .q = m[1] };
    }
    return .{ .p = 1, .q = 1 };
}

/// Channel count carried on an element type — `Frame`/`Sample` expose
/// `channel_count`; every other element is single-channel for negotiation.
fn channelsOf(comptime Elem: type) u16 {
    if (@hasDecl(Elem, "channel_count")) return @intCast(Elem.channel_count);
    return 1;
}

pub const Graph = struct {
    nodes: [max_nodes]Node = undefined,
    node_count: usize = 0,
    /// Forward (DAG) edges. Declared feedback edges live in `feedback`.
    edges: [max_edges]Edge = undefined,
    edge_count: usize = 0,
    /// Declared feedback (back) edges — the z⁻¹ split, kept separate so topo sees
    /// the DAG and SCC-has-delay unions both.
    feedback: [max_edges]FeedbackEdge = undefined,
    feedback_count: usize = 0,
    /// The device block size N this graph is committed for, in frames. Pool
    /// buffers hold N elements, so the footprint scales with it; the buffer-id
    /// *map* does not (an N change resizes the backing bytes, not the topology).
    /// On embedded N is comptime-fixed, so the footprint is a comptime constant.
    block_size: usize = 512,
    /// The pipeline sample rate (Hz) every node inherits at `add`. The negotiate
    /// pass compares producer/consumer rates to decide resampler coercion.
    sample_rate: u32 = 48_000,

    const Self = @This();

    pub const empty: Self = .{};

    /// Add a block instance. Returns the node id. Reads, once, every
    /// block-derived fact the commit pass needs: the output element (pool key),
    /// the source/delay structural flags, the rate ratio, the group delay, and
    /// the persistent-state sizes. A sink (no output port) records a zero/`(sink)`
    /// output element.
    pub fn add(self: *Self, comptime Block: type) usize {
        const class = comptime port.classify(Block);
        // Derive the output element type in a comptime context so the unused
        // branch (which references `Block.pull` for a Map, or `Block.process`
        // for a Rate, or the output port of a sink) is never analyzed wrongly.
        const out_size = comptime if (hasOutput(Block)) @sizeOf(outElemOf(Block)) else 0;
        const out_name = comptime if (hasOutput(Block)) @typeName(outElemOf(Block)) else "(sink)";
        const ratio = comptime ratioOf(Block);
        const id = self.node_count;
        self.nodes[id] = .{
            .id = id,
            .class = class,
            .type_name = @typeName(Block),
            .out_elem_size = out_size,
            .out_elem_name = out_name,
            .is_source = comptime port.isSource(Block),
            // A delay element is marked by a `delay_len` decl (its persistent
            // ring length): a unit delay declares 1, a delay line declares L.
            .is_delay = comptime @hasDecl(Block, "delay_len"),
            .delay_len = comptime if (@hasDecl(Block, "delay_len")) Block.delay_len else 0,
            .algorithmic_latency = comptime if (@hasDecl(Block, "algorithmic_latency")) Block.algorithmic_latency else 0,
            .out_per_in_p = ratio.p,
            .out_per_in_q = ratio.q,
            .aliasing_safe = comptime @hasDecl(Block, "aliasing_safe") and Block.aliasing_safe,
            .state_size = comptime if (@hasDecl(Block, "state_size")) Block.state_size else 0,
            .rate_domain = 0,
            .sample_rate = self.sample_rate,
            .set_param_slots = 0,
            .is_growable_sink = comptime @hasDecl(Block, "growable_sink") and Block.growable_sink,
        };
        self.node_count += 1;
        return id;
    }

    /// Mark parameter slot `slot` of node `node_id` as driven by an external
    /// `set`/`schedule`. The one-source check then rejects the commit if that
    /// same slot is also fed by a wired parameter edge (P2). (`set`/`schedule`
    /// call this in a later phase; exposed now so the check is real and testable.)
    pub fn markSetParam(self: *Self, node_id: usize, slot: port.PortIndex) void {
        self.nodes[node_id].set_param_slots |= (@as(u8, 1) << slot);
    }

    /// Mark a node as bypassed. The commit then enforces the bypass-preserves-
    /// latency law: a bypassed block with latency must route through a compensating
    /// delay, else it is rejected (see `Node.bypassed`).
    pub fn markBypassed(self: *Self, node_id: usize) void {
        self.nodes[node_id].bypassed = true;
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
        self.addEdge(out_node, out_idx, in_node, in_idx, OutPort.Elem, comptime port.isParamPort(InPort));
    }

    /// Connect a declared feedback (back) edge. Same type check; recorded in the
    /// separate `feedback` list (the z⁻¹ split) so it is absent from the
    /// topological sort and present in the SCC-has-delay check.
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
        const f = self.feedback_count;
        self.feedback[f] = .{
            .write_node = out_node,
            .write_port = out_idx,
            .read_node = in_node,
            .read_port = in_idx,
            .elem_size = @sizeOf(OutPort.Elem),
            .elem_name = @typeName(OutPort.Elem),
        };
        self.feedback_count += 1;
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
        comptime is_param: bool,
    ) void {
        const e = self.edge_count;
        self.edges[e] = .{
            .from_node = out_node,
            .from_port = out_idx,
            .to_node = in_node,
            .to_port = in_idx,
            .feedback = false,
            .elem_size = @sizeOf(Elem),
            .elem_name = @typeName(Elem),
            .is_param = is_param,
            .channels = channelsOf(Elem),
        };
        self.edge_count += 1;
    }
};

/// The committed graph the commit pass consumes is exactly this IR — a finite
/// diagram of nodes, forward edges, and the declared feedback (z⁻¹) edges. This
/// committed form is conventionally called a `CommittedGraph`; here it is the same value.
pub const CommittedGraph = Graph;

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
    // Feedback edges live in the separate z⁻¹ list, not in `edges`.
    try std.testing.expectEqual(@as(usize, 0), g.edge_count);
    try std.testing.expectEqual(@as(usize, 1), g.feedback_count);
    try std.testing.expectEqual(@as(usize, 0), g.feedback[0].write_node);
    try std.testing.expectEqual(@as(usize, 0), g.feedback[0].read_node);
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
    // The forward edge stays in `edges`; the back-edge goes to the z⁻¹ list with
    // the same element metadata and the producer→consumer (write→read) split.
    try std.testing.expectEqual(@as(usize, 1), g.edge_count);
    try std.testing.expectEqual(@as(usize, 1), g.feedback_count);
    try std.testing.expect(!g.edges[0].feedback);
    try std.testing.expectEqual(@as(usize, 1), g.feedback[0].write_node);
    try std.testing.expectEqual(@as(usize, 0), g.feedback[0].read_node);
    try std.testing.expectEqual(g.edges[0].elem_size, g.feedback[0].elem_size);
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
    // Multi-channel ports are PLANAR views (the enforced SoA form), not `[]Frame`
    // AoS slices. The element identity recovered from the view is still
    // `Frame(f32,.stereo)`, so the recorded edge `elem_size` stays 8 (two f32 lanes).
    const Stereo = struct {
        const Self = @This();
        pub fn process(self: *Self, in: t.PlanarConst(f32, .stereo), out: t.Planar(f32, .stereo)) void {
            _ = self;
            _ = in;
            _ = out;
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
