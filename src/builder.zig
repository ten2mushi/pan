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

/// The `i`-th input port of a block as a `PortId` type — Rate-aware. A `Map` reads
/// its `i`-th `process` input; a `Rate`/`VariRate` reads its (single) `pull` sample
/// input. So a homogeneous-input handle's `node.in(i)` wires correctly to a Rate
/// block (an STFT/resampler) as well as a Map.
fn InPortTypeAt(comptime Block: type, comptime i: usize) type {
    return switch (port.classify(Block)) {
        .Map => port.MapInPortAt(Block, i),
        .Rate, .VariRate => port.RateInPort(Block),
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
            /// The heap block instance (owned by the engine after `commit`). Valid
            /// for the engine's lifetime on a non-RCU-swapped root (an analysis
            /// root); used to read a sink's collected output (`sink.instance()`).
            inst: *Block,

            const Self = @This();
            pub const B = Block;
            pub const is_node_handle = true;

            /// The live block instance — e.g. `collect.instance()` to read a sink.
            pub fn instance(self: Self) *Block {
                return self.inst;
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
    return struct {
        id: usize,
        out: OutAccessor(Block),
        param: ParamAccessor(Block),
        /// The heap block instance (owned by the engine after `commit`). Valid for
        /// the engine's lifetime on a non-RCU-swapped root; used to read a sink's
        /// collected output (`sink.instance().frames()`).
        inst: *Block,

        const Self = @This();
        pub const B = Block;
        pub const is_node_handle = true;

        /// The live block instance — e.g. `sink.instance().frames()`.
        pub fn instance(self: Self) *Block {
            return self.inst;
        }

        /// The block's `i`-th input port as a typed endpoint (`node.in(i)`).
        /// Rate-aware (a Rate block's single `pull` input wires here too). An
        /// out-of-range index is a compile error.
        pub fn in(self: Self, comptime i: usize) Endpoint(InPortTypeAt(Block, i)) {
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
    /// One bound node per `add`, in node-id order: the heap instance plus the
    /// monomorphized render/destroy/set thunks the runtime engine needs to replay
    /// the op-list by indirect call. The builder allocates the instances off-thread
    /// (so the eventual commit + RCU swap perform no allocation on the RT path) and
    /// transfers ownership to the engine on a successful `commit`.
    bound: [graph.max_nodes]engine.BoundNode = undefined,
    /// Whether ownership of the bound instances has passed to a committed engine. If
    /// not, `deinit` frees them (an abandoned or failed-to-commit graph leaks
    /// nothing).
    transferred: bool = false,

    const Self = @This();

    /// Create a graph for `cfg`. The allocator owns the block instances until a
    /// successful `commit` transfers them to the engine.
    pub fn init(alloc: std.mem.Allocator, cfg: config.Config) Self {
        var g = graph.Graph.empty;
        g.block_size = cfg.block_size;
        g.sample_rate = cfg.sample_rate;
        return .{ .ir = g, .alloc = alloc, .cfg = cfg };
    }

    pub fn deinit(self: *Self) void {
        if (self.transferred) return; // engine owns the instances now
        for (self.bound[0..self.ir.node_count]) |b| b.destroy(self.alloc, b.self_ptr);
    }

    /// Add a block instance; returns its typed node handle. `params` is an
    /// anonymous struct overriding the instance's named fields (gain, coefficients,
    /// device-buffer pointers) on top of `Block{}`. The instance is heap-allocated
    /// here and its render/destroy/set thunks captured, so commit binds them into
    /// the op-list with no further reflection.
    pub fn add(self: *Self, comptime Block: type, params: anytype) !NodeHandle(Block) {
        const id = self.ir.add(Block);
        const inst = try self.alloc.create(Block);
        errdefer self.alloc.destroy(inst);
        inst.* = Block{};
        engine.applyParams(Block, inst, params);
        // Lifecycle hook: a block owning heap state declares `initialize(alloc)`
        // (paired with `deinit(alloc)`, called by the destroy thunk). The growable
        // `FeatureCollectorSink` reserves its `capacity_hint` here. Done before the
        // bound slot is published so a failure leaves nothing half-registered.
        if (comptime @hasDecl(Block, "initialize")) {
            inst.initialize(self.alloc) catch |e| {
                inst.deinit(self.alloc);
                return e;
            };
        }
        self.bound[id] = .{
            .self_ptr = inst,
            .render = engine.renderThunk(Block),
            .destroy = engine.destroyThunk(Block),
            .set = engine.setThunkFor(Block),
            .exhausted = engine.exhaustThunkFor(Block),
        };

        var h: NodeHandle(Block) = undefined;
        h.id = id;
        h.inst = inst;
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

    /// Declare that parameter slot `slot` of node `node_id` is driven by an
    /// external `set`/`schedule` verb. The one-source rule then makes `commit`
    /// reject the graph (`error.ParameterMultiplyDriven`) if that same slot is
    /// ALSO fed by a wired parameter edge — a slot has exactly one source.
    pub fn markSet(self: *Self, node_id: usize, slot: port.PortIndex) void {
        self.ir.markSetParam(node_id, slot);
    }

    /// Commit the graph to a frozen, runnable engine (realtime default). Runs the
    /// runtime commit pass (negotiate → topo → SCC-has-delay → liveness → coloring
    /// → emit → footprint), binds each op's kernel + instance, and allocates the
    /// pool. Everything that can go wrong with the topology is reported here. On
    /// success, ownership of the block instances transfers to the returned engine.
    pub fn commit(self: *Self) !engine.Engine {
        const eng = try engine.Engine.bind(self.alloc, self.ir, self.bound[0..self.ir.node_count], self.cfg, .{
            .mode = .realtime_streaming,
            .max_block_size = self.cfg.max_block_size,
        });
        self.transferred = true;
        return eng;
    }

    /// Commit with explicit engine options — the entry for the Tier-B multicore
    /// overlay (`opts.cores > 1`, `opts.tier_b_executor`, `opts.force_workgroup`).
    /// `mode` defaults to realtime_streaming and `max_block_size` to the builder's
    /// config unless the caller overrides them. The frozen single-core Tier A is
    /// `opts.cores = 1` (the default `commit`).
    pub fn commitWith(self: *Self, opts: engine.EngineOptions) !engine.Engine {
        var o = opts;
        if (o.max_block_size == 0) o.max_block_size = self.cfg.max_block_size;
        const eng = try engine.Engine.bind(self.alloc, self.ir, self.bound[0..self.ir.node_count], self.cfg, o);
        self.transferred = true;
        return eng;
    }

    /// Commit the graph as a NON-RT **analysis** pull root (C5): the clock is a
    /// timer or input exhaustion, not the audio device callback, so the run is never
    /// slaved to an audio deadline. Drive the returned engine with `runToCompletion`.
    ///
    /// This is the only commit that accepts a growable `FeatureCollectorSink` — on a
    /// realtime root that sink is rejected by law A8 (`commit()` →
    /// `error.GrowableSinkOnRealtimeRoot`), because its geometric `realloc` cannot
    /// sit on the audio deadline. The contained H1 exception lives here.
    pub fn commitAnalysis(self: *Self) !engine.Engine {
        const eng = try engine.Engine.bind(self.alloc, self.ir, self.bound[0..self.ir.node_count], self.cfg, .{
            .mode = .offline_batch,
            .max_block_size = self.cfg.max_block_size,
        });
        self.transferred = true;
        return eng;
    }
};

test "DX arc: init → add → connect → commit → renderInto (runtime engine, real path)" {
    const types = @import("types.zig");
    const en = @import("engine.zig");
    // A source filling its output from a preloaded buffer, a halving gain, and a
    // sink copying its input to a destination — a runnable, source-rooted chain.
    const BufSource = struct {
        const Self = @This();
        data: [*]const types.Sample(f32) = undefined,
        pub fn process(self: *Self, out: []types.Sample(f32)) void {
            @memcpy(out, self.data[0..out.len]);
        }
    };
    const Gain = struct {
        const Self = @This();
        gain: f32 = 1.0,
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.gain;
        }
    };
    const BufSink = struct {
        const Self = @This();
        dest: [*]types.Sample(f32) = undefined,
        pub fn process(self: *Self, in: []const types.Sample(f32)) void {
            @memcpy(self.dest[0..in.len], in);
        }
    };

    var input: [8]types.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var output: [8]types.Sample(f32) = undefined;

    var g = Graph.init(std.testing.allocator, .{ .precision = .f32, .channels = .mono, .block_size = 8 });
    defer g.deinit();

    const src = try g.add(BufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const gain = try g.add(Gain, .{ .gain = 0.5 });
    const sink = try g.add(BufSink, .{ .dest = @as([*]types.Sample(f32), &output) });

    try g.connect(src, gain); // bare handle → handle (out 0 → in 0)
    try g.connect(gain, sink);

    var eng = try g.commit();
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 3), eng.op_count); // one op per node

    const token = en.enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    for (input, output) |x, y| try std.testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
    try std.testing.expect(!eng.telemetry().fault);
}

test "DX arc: parameter port endpoint node.param.<name> mints + records the edge" {
    // The named parameter accessor `node.param.<name>` mints a typed endpoint and
    // wiring it records a control edge. (Rendering a wired parameter edge through
    // the executor — the ramp/hold body and its persistent state — is reserved for
    // the feedback/persistent-state phase; here we verify the builder surface and
    // that the edge is recorded.)
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
    const ep = bq.param.cutoff;
    try std.testing.expect(@TypeOf(ep).Port.Elem == types.Scalar(f32)); // typed param endpoint
    try g.connect(lfo, ep); // output → named parameter endpoint
    try std.testing.expectEqual(@as(usize, 1), g.ir.edge_count);
}

test "one-source (P2): a slot driven by BOTH a wired edge and `set` is a commit error" {
    // A parameter slot has exactly one source: a wired parameter edge XOR an
    // external set/schedule. Declaring `set` on a slot that is ALSO wired must be
    // rejected at commit (the negotiate stage runs this check before topology, so
    // the one-source violation is reported regardless of rooting).
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
        pub const params = .{ .cutoff = types.Scalar(f32) };
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    var g = Graph.init(std.testing.allocator, .{});
    defer g.deinit();
    const lfo = try g.add(Lfo, .{});
    const bq = try g.add(Biquad, .{});
    g.markSet(bq.id, 0); // declare cutoff (slot 0) externally set
    try g.connect(lfo, bq.param.cutoff); // ALSO wire a parameter edge to slot 0
    try std.testing.expectError(error.ParameterMultiplyDriven, g.commit());
}

test "param edge is subject to SCC-has-delay (P4): a delay-free parameter loop is rejected" {
    // A parameter edge is an ordinary graph edge — colored, scheduled, AND subject
    // to the delay-free-loop rule. A cycle of parameter edges with no delay element
    // is not causal (this period's coefficient would depend on itself), so commit
    // rejects it exactly as it would a sample loop.
    const types = @import("types.zig");
    const ScalarNode = struct {
        const Self = @This();
        pub const params = .{ .x = types.Scalar(f32) };
        pub fn process(self: *Self, out: []types.Scalar(f32)) void {
            _ = self;
            _ = out;
        }
        pub fn setParam(self: *Self, slot: u8, v: f32) void {
            _ = self;
            _ = slot;
            _ = v;
        }
    };
    var g = Graph.init(std.testing.allocator, .{});
    defer g.deinit();
    const a = try g.add(ScalarNode, .{});
    const b = try g.add(ScalarNode, .{});
    try g.connect(a, b.param.x); // forward parameter edge a → b.x
    try g.connectFeedback(b, a.param.x); // back parameter edge b → a.x closes the cycle
    // The SCC {a, b} contains no delay element ⇒ delay-free parameter loop.
    try std.testing.expectError(error.DelayFreeLoop, g.commit());
}
