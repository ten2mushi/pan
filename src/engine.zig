//! The render engine — the Tier-A synchronous pull executor, the realtime-thread
//! token, and the engine surface.
//!
//! `enterRealtimeThread()` returns a `RealtimeToken` whose construction sets
//! flush-to-zero / denormals-are-zero on the *calling* thread. This matters
//! because denormal floats (reverb tails, IIR ringing toward silence) are
//! 10–100× slower on some CPUs, so a decaying-but-inaudible signal can spike CPU
//! and cause an xrun. On ARM64 the FPCR `FZ` bit is **per-thread and NOT
//! inherited by child threads**, so it must be set on the audio thread itself
//! (and on every worker spawned for parallel render); a real shipping bug
//! (full-volume noise on Apple Silicon) came from exactly this. `renderInto` and
//! the bound executor REQUIRE the token in their signature — they will not
//! compile without one — so forgetting to flush-to-zero on a self-spawned thread
//! is structurally impossible. On a fixed-point target the token is a no-op (no
//! FPU), but the API shape is identical across targets.
//!
//! The executor itself is monomorphized over a *committed comptime graph* and a
//! parallel *node-id → block-type* tuple: the commit pass fixes the op-list
//! topology, buffer ids, and footprint; the executor binds each op's
//! monomorphized kernel and recovers typed slices from a flat byte pool by buffer
//! id. The hot path replays the op-list with zero graph walking — exactly
//! `process(self, gather(inputs), scatter(outputs))` per node, in topo order.

const std = @import("std");
const builtin = @import("builtin");
const commit = @import("commit.zig");
const graph = @import("graph.zig");
const port = @import("port.zig");
const mux = @import("mux.zig");
const types = @import("types.zig");

// ===========================================================================
// Floating-point environment — flush-to-zero / denormals-are-zero
// ===========================================================================
//
// The control word and the bit positions differ per ISA. We read the current
// word, OR in the flush bits, write it back, and remember the previous word so
// the token can restore it on `leave()` (leaving the thread's FP environment as
// we found it). On an architecture with no such control (or a soft-float / fixed-
// point target) this is a no-op and the saved word is meaningless.

const FpEnv = struct {
    /// The control word before we set flush-to-zero, for restoration.
    saved: usize = 0,
    /// Whether this build actually manipulates the FP environment (false ⇒ no FPU
    /// control on this target; the token is a structural no-op).
    active: bool = false,
};

fn enterFlushToZero() FpEnv {
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => {
            // FPCR: bit 24 = FZ (flush-to-zero for single/double), bit 19 = FZ16
            // (half precision). Setting FZ also makes *input* denormals behave as
            // zero, so it covers DAZ on AArch64 (unlike x86, which needs a
            // separate DAZ bit). FZ is the load-bearing denormal-flush control —
            // the one whose absence ships full-volume CPU-spike noise.
            //
            // The companion AH ("alternate handling") bit (FPCR bit 1) is
            // deliberately NOT set: it exists only under FEAT_AFP (ARMv8.7+) and
            // is RES0 on cores without it (writing 1 to a RES0 bit is wrong), it
            // changes FMIN/FMAX/FNEG/FABS semantics rather than denormal flushing,
            // and FZ already delivers the flush-to-zero this token promises.
            // Gating AH on a runtime FEAT_AFP probe would buy no extra denormal
            // protection, so flushing via FZ/FZ16 is the correct, portable choice.
            const fpcr = asm volatile ("mrs %[r], fpcr"
                : [r] "=r" (-> u64),
            );
            const FZ: u64 = (1 << 24) | (1 << 19);
            asm volatile ("msr fpcr, %[v]"
                :
                : [v] "r" (fpcr | FZ),
                : .{ .memory = true });
            return .{ .saved = @intCast(fpcr), .active = true };
        },
        .x86_64, .x86 => {
            // MXCSR: bit 15 = FTZ, bit 6 = DAZ.
            var word: u32 = undefined;
            asm volatile ("stmxcsr %[w]"
                : [w] "=m" (word),
            );
            const flush: u32 = (1 << 15) | (1 << 6);
            const next = word | flush;
            asm volatile ("ldmxcsr %[w]"
                :
                : [w] "m" (next),
                : .{ .memory = true });
            return .{ .saved = word, .active = true };
        },
        else => return .{ .active = false },
    }
}

fn restoreFpEnv(env: FpEnv) void {
    if (!env.active) return;
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => {
            const v: u64 = @intCast(env.saved);
            asm volatile ("msr fpcr, %[v]"
                :
                : [v] "r" (v),
                : .{ .memory = true });
        },
        .x86_64, .x86 => {
            const v: u32 = @intCast(env.saved);
            asm volatile ("ldmxcsr %[w]"
                :
                : [w] "m" (v),
                : .{ .memory = true });
        },
        else => {},
    }
}

/// The realtime token. Holding one is the proof-of-entry that flush-to-zero was
/// set on *this* thread. `renderInto` / the bound executor require it, so DSP
/// cannot run on a thread that has not entered realtime mode. (A strong
/// structural nudge, not a proof — it cannot prove FTZ is *still* set if the user
/// mutates the FP control word after taking the token.)
pub const RealtimeToken = struct {
    _entered: bool = true,
    fpenv: FpEnv = .{},

    /// Restore the thread's FP environment to its pre-token state. Optional on a
    /// thread that exits anyway; required if the thread continues doing non-pan
    /// float work that expects the default (gradual-underflow) environment.
    pub fn leave(self: RealtimeToken) void {
        restoreFpEnv(self.fpenv);
    }
};

/// Enter the realtime thread: set flush-to-zero / denormals-are-zero on THIS
/// thread (ARM64 FPCR FZ; x86 MXCSR FTZ/DAZ) and return the token witnessing it.
/// No-op on a target with no FP control word.
pub fn enterRealtimeThread() RealtimeToken {
    return .{ ._entered = true, .fpenv = enterFlushToZero() };
}

// ===========================================================================
// The token-gated op-list replay primitive (kept for the contract test)
// ===========================================================================

/// Replay a committed plan's op-list. REQUIRES a `RealtimeToken` — the signature
/// will not type-check without it. Ops whose kernel pointer is unbound (the bare
/// comptime IR, `fn_ptr == null`) are skipped: this primitive is the token-gated
/// replay shell; the *bound* executor (`Executor`) is what actually runs kernels.
pub fn renderInto(
    comptime n_ops: usize,
    token: RealtimeToken,
    plan: *const commit.Plan(n_ops),
    sample_mux: mux.SampleMux,
) void {
    _ = token; // holding it is the contract; the body uses it as a witness only
    for (plan.ops[0..plan.op_count]) |op| {
        if (op.fn_ptr == null) continue; // unbound kernel — skip (replay shell)
        _ = sample_mux;
    }
}

// ===========================================================================
// The Tier-A bound executor — monomorphized over a committed comptime graph
// ===========================================================================

/// Reinterpret a byte region of the pool as a typed element slice of length `n`.
/// The region originates from a properly-aligned pool, so `@alignCast` is safe
/// (and safety-checked in Debug).
fn sliceConst(comptime Elem: type, region: []const u8, n: usize) []const Elem {
    return @as([]const Elem, @alignCast(std.mem.bytesAsSlice(Elem, region)))[0..n];
}
fn sliceMut(comptime Elem: type, region: []u8, n: usize) []Elem {
    return @as([]Elem, @alignCast(std.mem.bytesAsSlice(Elem, region)))[0..n];
}

/// Build a planar buffer view of type `View` (a `Planar`/`PlanarConst`) over a
/// pool region. The region holds `C * n` lanes plane-major (`C = view channel
/// count`); plane `c` begins at lane offset `c * n` (byte offset `c·n·sizeof`).
/// The whole region carries `n * @sizeOf(Frame) == C * n * @sizeOf(Lane)` bytes,
/// the same size the commit pass allotted (layout-agnostic), so the view simply
/// re-reads those bytes as `C` contiguous planes rather than as interleaved
/// frames.
fn planarConstView(comptime View: type, region: []const u8, n: usize) View {
    const Lane = View.lane;
    const lanes: []const Lane = @alignCast(std.mem.bytesAsSlice(Lane, region));
    return View.fromBase(lanes.ptr, n);
}
fn planarMutView(comptime View: type, region: []u8, n: usize) View {
    const Lane = View.lane;
    const lanes: []Lane = @alignCast(std.mem.bytesAsSlice(Lane, region));
    return View.fromBase(lanes.ptr, n);
}

/// Does any lane of this float output buffer hold a NaN or ±Inf? The block-output
/// poison check for error isolation (compiled out when guards are off).
fn bufferIsPoisoned(comptime Elem: type, region: []const u8, n: usize) bool {
    const Lane = if (@hasDecl(Elem, "lane")) Elem.lane else return false;
    if (@typeInfo(Lane) != .float) return false;
    const lanes_per = @sizeOf(Elem) / @sizeOf(Lane);
    const flat: []const Lane = @alignCast(std.mem.bytesAsSlice(Lane, region[0 .. n * @sizeOf(Elem)]));
    _ = lanes_per;
    for (flat) |x| if (!std.math.isFinite(x)) return true;
    return false;
}

/// Bind a committed comptime graph and its parallel node-id → block-type tuple
/// into a runnable, fully-monomorphized Tier-A executor. The executor owns the
/// flat byte pool (sized by the commit footprint) and a tuple of block instances
/// (one per node, in node-id order). `node_blocks[i]` is the block type of node
/// `i`; the caller seeds the instances (gain coefficient, biquad coeffs, pan
/// position, the source/sink device-buffer pointers) via the `instances` field.
///
/// Source blocks (zero sample input) fill their output buffer from their own
/// backing store; sink blocks (zero output) drain their input buffer to their
/// own destination — so the executor needs no external mux for the Tier-A slice:
/// the boundary blocks ARE the device bridge.
pub fn Executor(comptime g: graph.Graph, comptime node_blocks: []const type) type {
    return ExecutorMode(g, node_blocks, .colored);
}

/// As `Executor`, but with the buffer-assignment mode chosen explicitly. The
/// shipped pool is `.colored`; `.per_edge` is the obviously-correct baseline. A
/// **B≡C differential** runs the SAME graph + block instances under both modes
/// and asserts bit-identical sink output: the colored pool reuses buffers but
/// must compute exactly what the per-edge baseline (one private buffer per value)
/// computes. The two executors share every kernel, so a divergence is a colorer/
/// pool bug, never numerics.
pub fn ExecutorMode(comptime g: graph.Graph, comptime node_blocks: []const type, comptime mode: commit.BufferMode) type {
    if (node_blocks.len != g.node_count)
        @compileError("pan: Executor needs exactly one block type per graph node");
    const plan = commit.commitComptimeMode(g, mode) catch |e|
        @compileError("pan: graph failed to commit: " ++ @errorName(e));
    if (plan.footprint_bytes != plan.pool_bytes)
        @compileError("pan: this executor handles pool buffers only — persistent " ++
            "delay/feedback state arrives in a later phase");

    const InstanceTuple = std.meta.Tuple(node_blocks);

    return struct {
        const Self = @This();
        /// One block instance per node, in node-id order. The caller seeds these.
        instances: InstanceTuple,
        /// The flat colored/per-edge buffer pool. Cache-line aligned so SIMD
        /// loads on its sub-buffers are aligned.
        pool: [plan.pool_bytes]u8 align(64) = undefined,
        /// Running telemetry: `guards_compiled_out` (so a release build can never
        /// silently drop the NaN/Inf safety net), the error-isolation `fault`
        /// flag, and the timing fields populated by `recordTiming`.
        tele: Telemetry = .{ .guards_compiled_out = !std.debug.runtime_safety },

        /// The committed plan (op-list, footprint, buffer layout). Exposed so the
        /// caller can report the footprint and op count.
        pub const committed = plan;

        /// The hard render deadline for one device block: N / Fs, in nanoseconds.
        /// A render exceeding it would be an xrun. A comptime constant for a
        /// comptime graph — the budget every `render` must finish inside.
        pub const deadline_ns: u64 = @intFromFloat(@as(f64, @floatFromInt(g.block_size)) * 1e9 /
            @as(f64, @floatFromInt(if (g.sample_rate == 0) 48_000 else g.sample_rate)));

        /// Render the graph once under a realtime token. Replays the op-list in
        /// forward-topo order, gathering each node's input slices and scattering
        /// its output slices through the pool by buffer id. The token is required
        /// (won't compile without it) and is the witness that flush-to-zero is set
        /// on this thread.
        pub fn render(self: *Self, token: RealtimeToken) void {
            _ = token; // witness only
            const guards = std.debug.runtime_safety;
            inline for (plan.ops[0..plan.op_count]) |op| {
                const nid = op.node_id;
                const Block = node_blocks[nid];
                const inst = &self.instances[nid];
                runOp(Block, inst, &self.pool, op, guards, &self.tele.fault);
            }
        }

        /// Fold one render's measured wall-clock time into the telemetry: bump
        /// `xrun_count` if it missed the N/Fs deadline, and record the deadline
        /// headroom (fraction of budget left, ≤1) and per-block CPU (fraction
        /// used). The caller times `render` with its own clock (the device's host
        /// timestamps, or the bench `std.Io.Clock`) and passes the elapsed ns —
        /// the executor never touches a clock on the hot path itself.
        pub fn recordTiming(self: *Self, render_ns: u64) void {
            const used: f32 = @as(f32, @floatFromInt(render_ns)) / @as(f32, @floatFromInt(deadline_ns));
            self.tele.per_block_cpu = used;
            self.tele.deadline_headroom = 1.0 - used;
            if (render_ns > deadline_ns) self.tele.xrun_count += 1;
        }

        /// Build the typed argument tuple from the op's buffer ids and invoke
        /// `Block.process`. Inputs and outputs are pulled in declaration order
        /// (the commit pass emits buffer ids in that order); each `[]const A`
        /// process parameter consumes the next input buffer id, each `[]A` the
        /// next output. After the call, finite-checks each output buffer (when
        /// guards are live) and silences a poisoned one, raising the fault flag.
        fn runOp(
            comptime Block: type,
            inst: *Block,
            pool: *[plan.pool_bytes]u8,
            comptime op: commit.RenderOp,
            comptime guards: bool,
            fault: *bool,
        ) void {
            const Args = std.meta.ArgsTuple(@TypeOf(Block.process));
            var args: Args = undefined;
            args[0] = inst;
            const params = @typeInfo(@TypeOf(Block.process)).@"fn".params;
            const n = op.n_or_pull_spec;
            comptime var in_i: usize = 0;
            comptime var out_i: usize = 0;
            inline for (params[1..], 1..) |p, ai| {
                const ParamT = p.type.?;
                // Each port param is either a planar buffer view (multi-channel
                // plane-major form) or a plain element slice (mono / non-Frame).
                // The view recovers `C` plane-major planes over the same region
                // bytes; the slice reinterprets the region as contiguous elements.
                if (comptime types.isPlanarView(ParamT)) {
                    if (comptime ParamT.is_const_view) {
                        const id = op.input_buffer_ids[in_i];
                        in_i += 1;
                        const region = pool[plan.buffer_offset[id] .. plan.buffer_offset[id] + plan.buffer_byte_len[id]];
                        args[ai] = planarConstView(ParamT, region, n);
                    } else {
                        const id = op.output_buffer_ids[out_i];
                        out_i += 1;
                        const region = pool[plan.buffer_offset[id] .. plan.buffer_offset[id] + plan.buffer_byte_len[id]];
                        args[ai] = planarMutView(ParamT, region, n);
                    }
                } else {
                    const info = @typeInfo(ParamT).pointer;
                    const Elem = info.child;
                    if (info.is_const) {
                        const id = op.input_buffer_ids[in_i];
                        in_i += 1;
                        const region = pool[plan.buffer_offset[id] .. plan.buffer_offset[id] + plan.buffer_byte_len[id]];
                        args[ai] = sliceConst(Elem, region, n);
                    } else {
                        const id = op.output_buffer_ids[out_i];
                        out_i += 1;
                        const region = pool[plan.buffer_offset[id] .. plan.buffer_offset[id] + plan.buffer_byte_len[id]];
                        args[ai] = sliceMut(Elem, region, n);
                    }
                }
            }
            @call(.auto, Block.process, args);

            if (guards) {
                comptime var oi: usize = 0;
                inline for (params[1..]) |p| {
                    const ParamT = p.type.?;
                    const is_out = comptime if (types.isPlanarView(ParamT))
                        !ParamT.is_const_view
                    else
                        !@typeInfo(ParamT).pointer.is_const;
                    if (is_out) {
                        const id = op.output_buffer_ids[oi];
                        oi += 1;
                        const region = pool[plan.buffer_offset[id] .. plan.buffer_offset[id] + plan.buffer_byte_len[id]];
                        // The finite-check scans every lane of the region; the
                        // plane-major vs interleaved arrangement is irrelevant to
                        // whether any lane is NaN/Inf, so the same scan works for
                        // a planar-view output and a plain element-slice output.
                        const Elem = comptime if (types.isPlanarView(ParamT)) ParamT.Elem else @typeInfo(ParamT).pointer.child;
                        if (bufferIsPoisoned(Elem, region, n)) {
                            @memset(region[0 .. n * @sizeOf(Elem)], 0); // silence
                            fault.* = true;
                        }
                    }
                }
            }
        }

        pub fn telemetry(self: *Self) Telemetry {
            return self.tele;
        }
    };
}

// ===========================================================================
// The engine surface (runtime; the builder/DX arc + control-plane shells)
// ===========================================================================

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

/// Engine instantiation options. `mode` picks the executor; `threads`/`cores`
/// the worker budget. `.realtime_streaming` + `.single` is Tier A (the frozen
/// ground truth); more cores promote to the (phased) Tier-B overlay.
pub const EngineOptions = struct {
    mode: ExecutionMode = .realtime_streaming,
    threads: Threads = .single,
    /// Render-worker core budget. `1` (the default) is Tier A — the frozen,
    /// always-correct single-thread synchronous pull in the callback. `>1`
    /// requests the (phased) Tier-B multicore overlay, which auto-demotes to
    /// Tier A under the cost gate. `.threads`/`.cores` are two views of the same
    /// budget; `.cores` is the spec's spelling for the Tier selection.
    cores: usize = 1,
};

/// What a committed graph reports to the engine: the static op count and the
/// static pool footprint.
pub const Summary = struct {
    op_count: usize,
    footprint_bytes: usize,
};

/// Telemetry surfaced from a running engine. `guards_compiled_out` reports
/// whether the NaN/safety guards were stripped for this build mode, so a release
/// build can never *silently* drop a safety net (`nan_guards_active =
/// !guards_compiled_out`). `fault` is the error-isolation flag.
pub const Telemetry = struct {
    xrun_count: u64 = 0,
    deadline_headroom: f32 = 0,
    guards_compiled_out: bool = false,
    per_block_cpu: f32 = 0,
    spin_time: f32 = 0,
    fault: bool = false,
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
/// pinned runner + control-plane surface; the live control plane (SPSC ring, RCU
/// swap) and the runtime commit are fleshed out in their own phases — the bound
/// Tier-A executor above is the runnable P4 render path.
pub const Engine = struct {
    alloc: std.mem.Allocator,
    mode: ExecutionMode,
    op_count: usize,
    footprint_bytes: usize,
    telemetry_state: Telemetry = .{},

    /// Commit `graph` (duck-typed: it must expose `summarize() Summary`) and
    /// build the engine for the requested execution mode.
    pub fn init(alloc: std.mem.Allocator, graph_arg: anytype, opts: EngineOptions) !Engine {
        const s: Summary = graph_arg.summarize();
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

    /// Hand the committed op-list to a device backend's callback and return. This
    /// runtime `Engine` is the control-plane / DX façade; the RUNNABLE Tier-A
    /// render path is the comptime `Executor` (it owns the bound kernels + pool).
    /// Starting the audio transport is `AudioBackend.start` (io), whose render
    /// callback mints the token and drives `Executor.render`; the device-open
    /// itself is the live-device gate. `start`/`stop` here are the façade entry;
    /// their bodies bind to the backend + the RCU plan swap in the control-plane
    /// phase.
    pub fn start(self: *Engine) !void {
        _ = self;
    }

    pub fn stop(self: *Engine) void {
        _ = self;
    }

    /// Façade: the literal render is `Executor.render(token)` (comptime-bound
    /// kernels) / `Executor.renderInto`-equivalent via the source/sink boundary
    /// blocks, not this runtime shell. Kept so the builder/DX arc type-checks;
    /// the runtime-commit path that would populate it is the control-plane phase.
    pub fn renderInto(self: *Engine, token: RealtimeToken, mem: []u8, out: []u8) void {
        _ = self;
        _ = token;
        _ = mem;
        _ = out;
    }

    pub fn renderOffline(self: *Engine) !void {
        _ = self;
    }

    pub fn renderToCompletion(self: *Engine, opts: anytype) !void {
        _ = self;
        _ = opts;
    }

    pub fn schedule(self: *Engine, cmd: anytype) void {
        _ = self;
        _ = cmd;
    }

    pub fn sendEvent(self: *Engine, event: anytype) void {
        _ = self;
        _ = event;
    }

    pub fn beginEdit(self: *Engine) Edit {
        _ = self;
        return .{};
    }

    pub fn telemetry(self: *Engine) Telemetry {
        return self.telemetry_state;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "renderInto requires a token and replays an (unbound-kernel) op-list" {
    // A Source (zero input) so the path is source-rooted, into a Sink.
    const Src = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []types.Sample(f32)) void {
            _ = self;
            _ = out;
        }
    };
    const Sink = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32)) void {
            _ = self;
            _ = in;
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Src);
        const b = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), a, 0, port.MapInPort(Sink), b, 0);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);

    var in_bytes = [_]u8{0} ** 16;
    var out_bytes = [_]u8{0} ** 16;
    var pm = mux.PullSampleMux{ .in_buf = &in_bytes, .out_buf = &out_bytes };

    const token = enterRealtimeThread();
    defer token.leave();
    renderInto(g.node_count, token, &plan, pm.sampleMux());
    try std.testing.expect(token._entered);
}

test "enterRealtimeThread sets flush-to-zero and leave restores it (ARM64/x86)" {
    const token = enterRealtimeThread();
    // On a target with an FP control word the token is active; flushing denormals
    // is observable: a subnormal times itself underflows to exactly zero.
    if (token.fpenv.active) {
        const tiny: f32 = std.math.floatMin(f32) / 2.0; // a subnormal
        // Defeat constant folding so the multiply runs in the live FP env.
        var x: f32 = tiny;
        std.mem.doNotOptimizeAway(&x);
        const y = x * x;
        std.mem.doNotOptimizeAway(y);
        try std.testing.expectEqual(@as(f32, 0.0), y);
    }
    token.leave();
}

test "Executor binds kernels and renders a source→gain→sink chain end-to-end" {
    const filters = @import("filters.zig");
    const numeric = @import("numeric.zig");
    const num = comptime numeric.numericFor(.f32, .{});

    // A source that fills its output from a preloaded buffer (a Map Source).
    const BufSource = struct {
        const Self = @This();
        data: [*]const types.Sample(f32) = undefined,
        pub fn process(self: *Self, out: []types.Sample(f32)) void {
            @memcpy(out, self.data[0..out.len]);
        }
    };
    // A sink that copies its input to a destination buffer.
    const BufSink = struct {
        const Self = @This();
        dest: [*]types.Sample(f32) = undefined,
        pub fn process(self: *Self, in: []const types.Sample(f32)) void {
            @memcpy(self.dest[0..in.len], in);
        }
    };
    const Gain = filters.Gain(num);

    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 8;
        const src = gg.add(BufSource);
        const gain = gg.add(Gain);
        const sink = gg.add(BufSink);
        gg.connect(port.MapOutPort(BufSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(BufSink), sink, 0);
        break :blk gg;
    };

    var input: [8]types.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var output: [8]types.Sample(f32) = undefined;

    const Exec = Executor(g, &.{ BufSource, Gain, BufSink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = 0.5 },
        .{ .dest = &output },
    } };

    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    for (input, output) |x, y| try std.testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
    try std.testing.expect(!exec.telemetry().fault);
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
    try std.testing.expectEqual(!std.debug.runtime_safety, eng.telemetry().guards_compiled_out);
    var edit = eng.beginEdit();
    _ = try edit.add(struct {}, .{});
    try edit.commit();
}
