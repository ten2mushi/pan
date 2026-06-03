//! The render engine surface.
//!
//! `enterRealtimeThread()` returns a `RealtimeToken` whose construction sets
//! FTZ/DAZ on the calling thread (the ARM64 FPCR `FZ` bit is per-thread and not
//! inherited, so it must be set on the audio thread itself). `renderInto`
//! REQUIRES the token in its signature — it will not compile without one, a
//! structural nudge that DSP only runs on a thread that has entered realtime
//! mode.
//!
//! The `Engine` is the frozen, runnable result of committing a graph: it owns
//! the render op-list and is driven by a pull root (the device callback, an
//! analysis clock). Most methods here are STUBS pinning the surface — the
//! wait-free executor, the lock-free control plane, and the offline runner are
//! implemented in their own phases. The bodies do nothing yet; the signatures
//! type-check the authoring arc.

const std = @import("std");
const commit = @import("commit.zig");
const mux = @import("mux.zig");

/// The realtime token. Holding one is the proof-of-entry that FTZ/DAZ were set
/// on *this* thread. No-op body on this skeleton and on fixed-point targets; the
/// API shape is uniform across targets.
pub const RealtimeToken = struct {
    _entered: bool = true,
};

/// Enter the realtime thread. On a real target this sets the FPCR `FZ`/`AH`
/// bits (ARM64) or MXCSR (x86) so denormals flush to zero — denormals cause
/// 10–100× slowdowns in decaying feedback paths. No-op here.
pub fn enterRealtimeThread() RealtimeToken {
    return .{};
}

/// Replay a committed plan's op-list. REQUIRES a `RealtimeToken` — the signature
/// will not type-check without it. `n_ops` is comptime so a comptime plan
/// inlines fully on embedded.
pub fn renderInto(
    comptime n_ops: usize,
    token: RealtimeToken,
    plan: *const commit.Plan(n_ops),
    sample_mux: mux.SampleMux,
) void {
    _ = token; // holding it is the contract; the body uses it as a witness only
    for (plan.ops[0..plan.op_count]) |op| {
        if (op.fn_ptr == null) continue; // empty/stub kernel — skip (skeleton)
        _ = sample_mux;
    }
}

/// Which executor drives the committed graph. Chosen at engine instantiation;
/// the graph and its blocks are mode-invariant (the same `process`/`pull`
/// signatures run under either).
pub const ExecutionMode = enum {
    /// Pull/clock-driven, hard N/Fs deadline (Tier A single-core or Tier B
    /// multicore). Wait-free on the audio thread.
    realtime_streaming,
    /// Push/input-exhaustion-driven, no deadline, throughput-first, bit-
    /// reproducible across thread count (Tier C).
    offline_batch,
};

/// Worker-thread budget for a parallel executor.
pub const Threads = union(enum) {
    /// One worker (Tier A in realtime, single-threaded offline).
    single,
    /// Use all available cores.
    auto,
    /// A fixed worker count.
    count: usize,
};

/// Engine instantiation options. `mode` picks the executor; `threads` the
/// worker budget for a parallel tier.
pub const EngineOptions = struct {
    mode: ExecutionMode = .realtime_streaming,
    threads: Threads = .single,
};

/// What a committed graph reports to the engine: the static op count and the
/// static pool footprint. (The full plan/op-list is threaded through here once
/// the runtime commit pass lands.)
pub const Summary = struct {
    op_count: usize,
    footprint_bytes: usize,
};

/// Telemetry surfaced from a running engine. `guards_compiled_out` reports
/// whether the NaN/safety guards were stripped for this build mode, so a release
/// build can never *silently* drop a safety net.
pub const Telemetry = struct {
    xrun_count: u64 = 0,
    deadline_headroom: f32 = 0,
    guards_compiled_out: bool = false,
    per_block_cpu: f32 = 0,
    spin_time: f32 = 0,
};

/// An in-progress topology edit (the `edit → commit` control verb): mutations
/// are built off the audio thread and published with an RCU pointer swap at a
/// block boundary, so a live graph is rewired with no glitch. Stub: records
/// nothing yet; `add` returns a placeholder node id.
pub const Edit = struct {
    next_id: usize = 0,

    pub fn add(self: *Edit, comptime Block: type, params: anytype) !usize {
        _ = Block;
        _ = params;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn commit(self: *Edit) !void {
        _ = self;
    }
};

/// The frozen, runnable engine. Produced by `Graph.commit()` (realtime default)
/// or `Engine.init(alloc, graph, opts)` (explicit mode). The methods are the
/// pinned runner + control-plane surface; bodies are stubs until their phases.
pub const Engine = struct {
    alloc: std.mem.Allocator,
    mode: ExecutionMode,
    op_count: usize,
    footprint_bytes: usize,
    telemetry_state: Telemetry = .{},

    /// Commit `graph` (duck-typed: it must expose `summarize() Summary`) and
    /// build the engine for the requested execution mode.
    pub fn init(alloc: std.mem.Allocator, graph: anytype, opts: EngineOptions) !Engine {
        const s: Summary = graph.summarize();
        return .{
            .alloc = alloc,
            .mode = opts.mode,
            .op_count = s.op_count,
            .footprint_bytes = s.footprint_bytes,
            .telemetry_state = .{ .guards_compiled_out = !std.debug.runtime_safety },
        };
    }

    pub fn deinit(self: *Engine) void {
        _ = self;
    }

    /// Hand the op-list to the pull root (the device callback) and return
    /// immediately. Stub.
    pub fn start(self: *Engine) !void {
        _ = self;
    }

    pub fn stop(self: *Engine) void {
        _ = self;
    }

    /// Render one device block into `out`, scratch in `mem`, under a realtime
    /// token. Stub.
    pub fn renderInto(self: *Engine, token: RealtimeToken, mem: []u8, out: []u8) void {
        _ = self;
        _ = token;
        _ = mem;
        _ = out;
    }

    /// Render an offline graph (no deadline). Stub.
    pub fn renderOffline(self: *Engine) !void {
        _ = self;
    }

    /// Drive an offline render to input exhaustion (the OfflineBatch driver).
    /// Stub.
    pub fn renderToCompletion(self: *Engine, opts: anytype) !void {
        _ = self;
        _ = opts;
    }

    /// `schedule` control verb — sample-accurate parameter automation via the
    /// SPSC command ring. Stub (accepts the command shape).
    pub fn schedule(self: *Engine, cmd: anytype) void {
        _ = self;
        _ = cmd;
    }

    /// `sendEvent` — push onto the typed event lane (note onsets, MPE, CC).
    /// Stub.
    pub fn sendEvent(self: *Engine, event: anytype) void {
        _ = self;
        _ = event;
    }

    /// Begin an `edit → commit` topology change.
    pub fn beginEdit(self: *Engine) Edit {
        _ = self;
        return .{};
    }

    pub fn telemetry(self: *Engine) Telemetry {
        return self.telemetry_state;
    }
};

test "renderInto requires a token and replays an (empty-kernel) op-list" {
    const types = @import("types.zig");
    const graph = @import("graph.zig");
    const port = @import("port.zig");
    const Gain = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Gain);
        const b = gg.add(Gain);
        gg.connect(port.MapOutPort(Gain), a, 0, port.MapInPort(Gain), b, 0);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);

    var in_bytes = [_]u8{0} ** 16;
    var out_bytes = [_]u8{0} ** 16;
    var pm = mux.PullSampleMux{ .in_buf = &in_bytes, .out_buf = &out_bytes };

    const token = enterRealtimeThread();
    renderInto(g.edge_count, token, &plan, pm.sampleMux());
    try std.testing.expect(token._entered);
}

test "Engine.init from a duck-typed graph summary; telemetry tracks build mode" {
    const FakeGraph = struct {
        ops: usize,
        bytes: usize,
        pub fn summarize(self: @This()) Summary {
            return .{ .op_count = self.ops, .footprint_bytes = self.bytes };
        }
    };
    var eng = try Engine.init(std.testing.allocator, FakeGraph{ .ops = 3, .bytes = 24 }, .{ .mode = .offline_batch });
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 3), eng.op_count);
    try std.testing.expectEqual(ExecutionMode.offline_batch, eng.mode);
    // guards_compiled_out is the negation of runtime safety for this build.
    try std.testing.expectEqual(!std.debug.runtime_safety, eng.telemetry().guards_compiled_out);
    var edit = eng.beginEdit();
    _ = try edit.add(struct {}, .{});
    try edit.commit();
}
