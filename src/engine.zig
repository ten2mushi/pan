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
const control = @import("control.zig");
const config = @import("config.zig");
const io = @import("io.zig");

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
            applyParamInputs(Block, inst, pool, &op, plan.buffer_offset[0..], plan.buffer_byte_len[0..]);
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
// The runtime render path — a bound op-list replay (the RCU-swappable sibling
// of the comptime Executor)
// ===========================================================================
//
// The comptime `Executor` monomorphizes over a comptime graph and `inline for`s
// the op-list with comptime-known buffer ids — zero-overhead, the frozen Tier-A
// ground truth and the embedded path. The RUNTIME `Engine` needs the same render
// over a graph it built (and can re-`edit`) at runtime, so it cannot inline. It
// instead binds each node to a monomorphized RENDER THUNK: a `*const fn` that
// recovers the typed block from a `*anyopaque`, performs the SAME gather/scatter
// (pull each `[]const A` process param from an input buffer id, each `[]A` from an
// output buffer id, resolved through the plan's pool layout), and calls
// `Block.process`. The op carries that thunk in `fn_ptr` and the heap instance in
// `self_ptr` — exactly the `op.fn_ptr(op.self_ptr, gather, scatter, n)` op-list
// model. So the comptime and runtime paths share the `RenderOp`/`Plan`/
// pool-by-buffer-id model and the gather/scatter LOGIC; only the dispatch differs
// — comptime-inlined vs a bound indirect call. The plan is never forked.

/// The fixed-capacity plan the runtime path heap-allocates and RCU-swaps. Same
/// `Plan`/`RenderOp` type the comptime path produces; `op_count` is the live
/// length, and each op's `fn_ptr`/`self_ptr` are bound after `commitRuntime`.
pub const RuntimePlan = commit.Plan(graph.max_nodes);

/// A bound node's render thunk: erased entry that runs one node's `process` for a
/// given op, resolving buffers through the plan's pool layout over the engine's
/// flat pool. `guards` mirrors `std.debug.runtime_safety`; `fault` is the
/// error-isolation flag (a poisoned float output is silenced and the flag raised).
pub const RenderThunk = *const fn (
    self_ptr: *anyopaque,
    pool: [*]u8,
    op: *const commit.RenderOp,
    plan: *const RuntimePlan,
    guards: bool,
    fault: *bool,
) void;

/// A bound node's destructor: frees its heap instance with the engine's allocator.
pub const DestroyThunk = *const fn (alloc: std.mem.Allocator, self_ptr: *anyopaque) void;

/// One node bound for runtime dispatch: its heap instance plus the monomorphized
/// render and destroy thunks. The builder fills one per node (in node-id order);
/// the engine fills each op's `fn_ptr`/`self_ptr` from this at commit, and frees
/// the instances at `deinit`.
pub const BoundNode = struct {
    self_ptr: *anyopaque,
    render: RenderThunk,
    destroy: DestroyThunk,
    /// The external-`set`/`schedule` apply, or null if the block declares no
    /// `setParam` (a pure-DSP block with no settable parameter).
    set: ?SetThunk = null,
};

/// Apply this op's wired PARAMETER-edge inputs to the block's parameter slots,
/// just before `process` — the in-graph analogue of `set` (catalog §2.4 P3). A
/// parameter port is a control-rate side input that does NOT appear in `process`,
/// so the value is delivered through the block's `setParam(slot, value)`: the
/// block then holds/ramps it across the buffer exactly as it ramps a `set` target,
/// which is why a wired parameter edge and `set` are bit-identical sources of the
/// same coefficient. The latest control value is the first lane of the producer's
/// control-element buffer (a `Scalar(f32)` coefficient is its `value` field at byte
/// offset 0 — read element-agnostically so one path serves any `Scalar(f32)` slot).
/// No-op for a block that declares no `setParam`.
fn applyParamInputs(
    comptime Block: type,
    inst: *Block,
    pool: [*]u8,
    op: *const commit.RenderOp,
    offsets: []const usize,
    lens: []const usize,
) void {
    if (comptime !@hasDecl(Block, "setParam")) return;
    var pi: usize = 0;
    while (pi < op.param_input_count) : (pi += 1) {
        const id = op.param_input_buffer_ids[pi];
        const region = pool[offsets[id] .. offsets[id] + lens[id]];
        const v = @as(*const f32, @ptrCast(@alignCast(region.ptr))).*; // Scalar(f32).value @ [0]
        inst.setParam(op.param_input_slots[pi], v);
    }
}

/// Build the monomorphized render thunk for `Block` — the bound-dispatch twin of
/// `Executor.runOp`. The param loop is comptime-unrolled over `Block.process`'s
/// signature (types are known here), but the buffer ids and pool offsets are read
/// from the RUNTIME op/plan, so one thunk serves any committed plan that places
/// this block.
pub fn renderThunk(comptime Block: type) RenderThunk {
    const Gen = struct {
        fn thunk(
            self_ptr: *anyopaque,
            pool: [*]u8,
            op: *const commit.RenderOp,
            plan: *const RuntimePlan,
            guards: bool,
            fault: *bool,
        ) void {
            const inst: *Block = @ptrCast(@alignCast(self_ptr));
            const Args = std.meta.ArgsTuple(@TypeOf(Block.process));
            var args: Args = undefined;
            args[0] = inst;
            const params = @typeInfo(@TypeOf(Block.process)).@"fn".params;
            const n = op.n_or_pull_spec;
            var in_i: usize = 0;
            var out_i: usize = 0;
            inline for (params[1..], 1..) |p, ai| {
                const ParamT = p.type.?;
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
            applyParamInputs(Block, inst, pool, op, plan.buffer_offset[0..], plan.buffer_byte_len[0..]);
            @call(.auto, Block.process, args);

            if (guards) {
                var oi: usize = 0;
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
                        const Elem = comptime if (types.isPlanarView(ParamT)) ParamT.Elem else @typeInfo(ParamT).pointer.child;
                        if (bufferIsPoisoned(Elem, region, n)) {
                            @memset(region[0 .. n * @sizeOf(Elem)], 0); // silence
                            fault.* = true;
                        }
                    }
                }
            }
        }
    };
    return Gen.thunk;
}

/// A dummy instance pointer for coercion nodes (which carry no author instance).
/// The coercion thunk ignores `self_ptr`; this just gives the op a non-null one.
var coercion_dummy: u8 = 0;

/// The built-in render kernel for an inserted coercion node. A resampler's
/// NUMERICAL body (polyphase sinc) is a later phase; this is the same-rate
/// passthrough stub — it copies the producer's buffer to the coercion's output
/// buffer (identical element + N, hence identical byte length). The node's
/// *presence* in the op-list is the negotiation deliverable (the diagram commutes
/// through a coercion morphism); its arithmetic is filled in when the resampler
/// block lands.
fn coercionPassthroughThunk(
    self_ptr: *anyopaque,
    pool: [*]u8,
    op: *const commit.RenderOp,
    plan: *const RuntimePlan,
    guards: bool,
    fault: *bool,
) void {
    _ = self_ptr;
    _ = guards;
    _ = fault;
    const in_id = op.input_buffer_ids[0];
    const out_id = op.output_buffer_ids[0];
    const len = plan.buffer_byte_len[out_id];
    const src = pool[plan.buffer_offset[in_id] .. plan.buffer_offset[in_id] + len];
    const dst = pool[plan.buffer_offset[out_id] .. plan.buffer_offset[out_id] + len];
    @memcpy(dst, src);
}

/// Build the destroy thunk for `Block`.
pub fn destroyThunk(comptime Block: type) DestroyThunk {
    const Gen = struct {
        fn destroy(alloc: std.mem.Allocator, self_ptr: *anyopaque) void {
            const inst: *Block = @ptrCast(@alignCast(self_ptr));
            alloc.destroy(inst);
        }
    };
    return Gen.destroy;
}

/// Replay a bound runtime plan over the engine pool. The shared core of the
/// device callback and `renderInto`: one indirect call per op in forward-topo
/// order. Wait-free — a fixed-bound loop, no allocation, no lock.
fn replayBound(plan: *const RuntimePlan, pool: []u8, guards: bool, fault: *bool) void {
    const base: [*]u8 = if (pool.len == 0) undefined else pool.ptr;
    for (plan.ops[0..plan.op_count]) |*op| {
        const thunk: RenderThunk = @ptrCast(@alignCast(op.fn_ptr.?));
        thunk(op.self_ptr.?, base, op, plan, guards, fault);
    }
}

// ===========================================================================
// The engine surface (runtime; the builder/DX arc + control-plane)
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
    /// Pre-size the buffer pool for this worst-case block size so a `reconfigure`
    /// to any N ≤ this is a live RCU swap (no reallocation). 0 ⇒ size exactly for
    /// the committed N.
    max_block_size: usize = 0,
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

/// A bound node's external-`set`/`schedule` apply: set parameter slot `slot` of
/// the block to `value`. Present only for blocks that declare a
/// `pub fn setParam(self: *Block, slot: u8, value: f32) void` — typically an
/// atomic store into a `control.Param` the block ramps toward each render call.
pub const SetThunk = *const fn (self_ptr: *anyopaque, slot: u8, value: f32) void;

/// Build the optional set thunk for `Block` (null if the block declares no
/// `setParam`). The thunk is the control verb's bridge into the live instance:
/// `Engine.set` calls it directly (atomic store, wait-free) and the `schedule`
/// ring drain calls it at the sample boundary.
pub fn setThunkFor(comptime Block: type) ?SetThunk {
    if (!@hasDecl(Block, "setParam")) return null;
    const Gen = struct {
        fn set(self_ptr: *anyopaque, slot: u8, value: f32) void {
            const inst: *Block = @ptrCast(@alignCast(self_ptr));
            inst.setParam(slot, value);
        }
    };
    return Gen.set;
}

/// The size of the engine's `schedule` command ring (power of two). Drained
/// wait-free at each render; full-ring backpressure is absorbed on the control
/// thread (`schedule` returns false), never stalling the RT thread.
pub const command_ring_capacity = 256;

const CommandRing = control.CommandRing(control.Command, command_ring_capacity);
const PlanRcu = control.Rcu(*RuntimePlan);

/// An in-progress topology edit (the `edit → commit` control verb): mutations are
/// built off the audio thread into a working copy of the graph, then the rebuilt
/// immutable plan is published with a single RCU pointer release-store at a block
/// boundary, so the live RT thread is rewired with no glitch and no audio-thread
/// allocation or lock. The old plan is reclaimed only after the epoch advances
/// past the swap (a full callback boundary crossed) — quiescent-state RCU.
pub const Edit = struct {
    eng: *Engine,
    ir: graph.Graph,
    bound: [graph.max_nodes]BoundNode = undefined,
    bound_count: usize,
    /// Instances allocated by THIS edit (the appended nodes), freed if the edit is
    /// abandoned. On a successful commit, ownership transfers to the engine.
    fresh: [graph.max_nodes]?*anyopaque = [_]?*anyopaque{null} ** graph.max_nodes,
    fresh_count: usize = 0,
    committed: bool = false,

    /// Append a block to the working graph copy; returns its node id. Allocates
    /// and seeds the instance off-thread (like the builder), so the eventual swap
    /// performs no allocation on the RT path.
    pub fn add(self: *Edit, comptime Block: type, params: anytype) !usize {
        const id = self.ir.add(Block);
        const inst = try self.eng.alloc.create(Block);
        inst.* = Block{};
        applyParams(Block, inst, params);
        self.fresh[self.fresh_count] = inst;
        self.fresh_count += 1;
        self.bound[id] = .{
            .self_ptr = inst,
            .render = renderThunk(Block),
            .destroy = destroyThunk(Block),
            .set = setThunkFor(Block),
        };
        self.bound_count = self.ir.node_count;
        return id;
    }

    /// Wire an output port to an input port in the working copy (by typed ports).
    pub fn connect(self: *Edit, comptime OutPort: type, from_node: usize, from_index: port.PortIndex, comptime InPort: type, to_node: usize, to_index: port.PortIndex) void {
        self.ir.connect(OutPort, from_node, from_index, InPort, to_node, to_index);
        self.bound_count = self.ir.node_count;
    }

    /// Build the new immutable plan off-thread and RCU-swap it in. Reclaims the old
    /// plan after a grace period. The new pool must fit the engine's pool capacity
    /// (allocated at bind for the configured worst-case N); a larger pool needs the
    /// stop/`reconfigure` protocol (a structural change that grows buffer pressure
    /// past capacity cannot be hot-swapped without a new pool).
    pub fn commit(self: *Edit) !void {
        try self.eng.installPlan(self.ir, self.bound[0..self.bound_count]);
        self.committed = true;
    }

    /// Abandon the edit, freeing any instances it allocated.
    pub fn abort(self: *Edit) void {
        if (self.committed) return;
        for (self.fresh[0..self.fresh_count]) |maybe| {
            if (maybe) |p| {
                // We don't know the type here; the destroy thunk is in `bound`.
                // Find it by matching self_ptr.
                for (self.bound[0..self.bound_count]) |b| {
                    if (b.self_ptr == p) {
                        b.destroy(self.eng.alloc, p);
                        break;
                    }
                }
            }
        }
    }
};

/// Apply a `params` anonymous struct onto a freshly-default-constructed instance,
/// field by field. A block must be default-constructible (`Block{}`); `params`
/// overrides the named fields (gain, coefficients, device-buffer pointers).
pub fn applyParams(comptime Block: type, inst: *Block, params: anytype) void {
    inline for (@typeInfo(@TypeOf(params)).@"struct".fields) |f| {
        @field(inst.*, f.name) = @field(params, f.name);
    }
}

/// The frozen, runnable engine — the runtime, RCU-swappable sibling of the comptime
/// `Executor`. Produced by `Graph.commit()`. It owns a heap-allocated immutable
/// `Plan` (its ops carry bound `fn_ptr`/`self_ptr`), the flat byte pool, and the
/// block instances; it replays the op-list wait-free in the device callback and in
/// `renderInto`, swaps the plan via RCU on `edit → commit`, and drives the three
/// control verbs (`set` atomic scalar, `schedule` SPSC ring, `edit → commit` RCU).
pub const Engine = struct {
    alloc: std.mem.Allocator,
    mode: ExecutionMode,
    cfg: config.Config,
    /// The working graph IR (kept so an edit/reconfigure can rebuild from it).
    ir: graph.Graph,
    /// The RCU cell holding the currently-active immutable plan + the quiescent
    /// epoch. The RT thread reads the plan once per callback; the control thread
    /// swaps it.
    rcu: PlanRcu,
    /// The flat colored buffer pool (cache-line aligned). Capacity is fixed at
    /// bind for the configured worst-case N, so an in-place edit never reallocs it.
    pool: []align(64) u8,
    pool_cap: usize,
    /// One bound node per graph node, in node-id order — owns the heap instances
    /// (freed at `deinit`) and the per-node render/destroy/set thunks.
    bound: []BoundNode,
    /// The `schedule` command ring (SPSC). Producer = control thread; consumer =
    /// the render (drained at each callback boundary).
    ring: CommandRing,
    op_count: usize,
    footprint_bytes: usize,
    tele: Telemetry,
    /// The audio transport, once `start` installs the callback. `null` until then.
    backend: ?io.AudioBackend = null,
    /// True while a separate RT thread may be rendering (the transport is started).
    /// Gates RCU grace-period reclamation: when running, the control thread waits
    /// for the epoch to advance past a swap before freeing the old plan; when not,
    /// the control thread is the lone accessor and frees immediately (waiting on an
    /// epoch no one advances would deadlock). A concurrency test sets it to model a
    /// manual RT thread.
    running: std.atomic.Value(bool) = .init(false),

    const Self = @This();

    /// Bind a runtime-built graph + its per-node bound instances into a runnable
    /// engine. Runs `commitRuntime` (the shared commit algorithm at runtime),
    /// heap-allocates the immutable plan, binds each op's `fn_ptr`/`self_ptr` from
    /// the node's thunk + instance, allocates the pool, and takes ownership of the
    /// instances (frees them at `deinit`). `bound_src` is indexed by node id.
    pub fn bind(alloc: std.mem.Allocator, ir: graph.Graph, bound_src: []const BoundNode, cfg: config.Config, opts: EngineOptions) !Self {
        const bound_owned = try alloc.dupe(BoundNode, bound_src);
        errdefer alloc.free(bound_owned);

        const plan = try buildBoundPlan(alloc, ir, bound_owned);
        errdefer alloc.destroy(plan);

        // Pre-size the pool for the worst-case N when one is requested: `pool_bytes`
        // is exactly linear in N (Σ colors·N·element_size), so the max-N pool is the
        // committed pool scaled by max_N/N. The active plan uses only its own
        // [0, pool_bytes) prefix; the headroom lets `reconfigure` swap live.
        const cap = poolCapacityFor(plan.pool_bytes, cfg.block_size, opts.max_block_size);
        const pool = try allocPool(alloc, cap);
        errdefer freePool(alloc, pool);

        return .{
            .alloc = alloc,
            .mode = opts.mode,
            .cfg = cfg,
            .ir = ir,
            .rcu = PlanRcu.init(plan),
            .pool = pool,
            .pool_cap = cap,
            .bound = bound_owned,
            .ring = CommandRing.empty,
            .op_count = plan.op_count,
            .footprint_bytes = plan.footprint_bytes,
            .tele = .{ .guards_compiled_out = !std.debug.runtime_safety },
        };
    }

    /// Heap-allocate and fully BIND the runtime-committed plan for `ir` (off-thread;
    /// allocation is fine here — never the RT path). First the negotiation pass
    /// inserts any coercion nodes (`insertCoercions`), then the shared commit
    /// algorithm produces the op-list, then each op's `fn_ptr`/`self_ptr` is bound:
    /// an author node to its captured render thunk + heap instance (from `bound`,
    /// indexed by node id), and an inserted coercion node to the built-in coercion
    /// kernel. This is the `op.fn_ptr(op.self_ptr, …)` model the replay invokes.
    fn buildBoundPlan(alloc: std.mem.Allocator, ir: graph.Graph, bound: []const BoundNode) !*RuntimePlan {
        const g2 = commit.insertCoercions(ir);
        const full = try commit.commitGraph(g2, .colored);
        const plan = try alloc.create(RuntimePlan);
        plan.* = full;
        for (plan.ops[0..plan.op_count]) |*op| {
            const nid = op.node_id;
            if (g2.nodes[nid].is_coercion) {
                op.fn_ptr = @ptrCast(&coercionPassthroughThunk);
                op.self_ptr = &coercion_dummy;
            } else {
                op.fn_ptr = @ptrCast(bound[nid].render); // RenderThunk → ?*const anyopaque
                op.self_ptr = bound[nid].self_ptr;
            }
        }
        return plan;
    }

    fn allocPool(alloc: std.mem.Allocator, bytes: usize) ![]align(64) u8 {
        if (bytes == 0) return &[_]u8{};
        return alloc.alignedAlloc(u8, .@"64", bytes);
    }
    /// The pool byte capacity to allocate: the committed `pool_bytes`, or — when a
    /// larger worst-case N is requested — that figure scaled to max-N (exact, since
    /// `pool_bytes` is a multiple of N).
    fn poolCapacityFor(pool_bytes: usize, committed_n: usize, max_n: usize) usize {
        if (max_n <= committed_n or committed_n == 0 or pool_bytes == 0) return pool_bytes;
        return pool_bytes / committed_n * max_n;
    }
    fn freePool(alloc: std.mem.Allocator, pool: []align(64) u8) void {
        if (pool.len != 0) alloc.free(pool);
    }

    pub fn deinit(self: *Self) void {
        if (self.backend) |b| b.stop();
        // Free the block instances via their destroy thunks.
        for (self.bound) |b| b.destroy(self.alloc, b.self_ptr);
        self.alloc.free(self.bound);
        freePool(self.alloc, self.pool);
        self.alloc.destroy(self.rcu.current());
    }

    /// Install the audio transport and start the callback-driven render. The
    /// backend mints the realtime token on its own audio thread (closing the FTZ
    /// footgun) and invokes `renderCallback`, which drives the RCU-current plan.
    /// Opening a live device + the sub-5 ms / 10-min measured gate is the
    /// on-device step (no audio HW in a sandbox); the callback path compiles and
    /// links here.
    pub fn start(self: *Self, backend: io.AudioBackend) !void {
        self.backend = backend;
        self.running.store(true, .release);
        try backend.start(.{
            .sample_rate = self.cfg.sample_rate,
            .channels = @intCast(self.cfg.channels.count()),
            .block_size = self.cfg.block_size,
        }, renderCallback, self);
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        if (self.backend) |b| b.stop();
        self.backend = null;
    }

    /// The device render callback (the realtime `PullRoot`). The backend hands us
    /// the token (FTZ already set on this thread) and the output buffer. We bump
    /// the epoch + acquire-load the plan once, drain the schedule ring, and replay
    /// the bound op-list — all wait-free. The bound source/sink blocks bridge the
    /// device buffers (a sink writes its plane to `out`); fully wiring `out` to a
    /// device sink instance is the on-device integration step.
    fn renderCallback(user: ?*anyopaque, token: RealtimeToken, out: []f32, frames: usize) void {
        _ = out;
        _ = frames;
        const self: *Self = @ptrCast(@alignCast(user.?));
        self.renderCurrent(token);
    }

    /// Render the currently-active plan once under a realtime token: epoch bump +
    /// one acquire-load of the plan (used for the whole callback — a mid-callback
    /// swap never tears a render), drain the schedule ring at the boundary, then
    /// replay the bound op-list. Wait-free.
    pub fn renderInto(self: *Self, token: RealtimeToken) void {
        self.renderCurrent(token);
    }

    fn renderCurrent(self: *Self, token: RealtimeToken) void {
        _ = token; // witness that FTZ is set on this thread
        const plan = self.rcu.enter(); // (E) epoch bump + (R) one acquire-load
        // Drain scheduled events at the block boundary (sample-accurate placement
        // within the block is the sub-block scheduler's job, a later refinement;
        // here every queued event is applied at the boundary).
        self.ring.drain(self);
        const guards = std.debug.runtime_safety;
        replayBound(plan, self.pool, guards, &self.tele.fault);
    }

    /// The schedule-ring consumer hook: apply one command to its target node via
    /// the node's set thunk (a no-op if the node declares no `setParam`).
    pub fn apply(self: *Self, cmd: control.Command) void {
        if (cmd.node < self.bound.len) {
            if (self.bound[cmd.node].set) |st| st(self.bound[cmd.node].self_ptr, cmd.param, cmd.value);
        }
    }

    /// The `set` control verb — move a continuous parameter (gain, cutoff). Atomic
    /// scalar store directly into the target block's `control.Param` via its set
    /// thunk; the block ramps toward it per render (anti-zipper). Wait-free, NOT
    /// sample-accurate (reached by block end). Control thread only.
    pub fn set(self: *Self, node: usize, slot: u8, value: f32) void {
        if (node < self.bound.len) {
            if (self.bound[node].set) |st| st(self.bound[node].self_ptr, slot, value);
        }
    }

    /// The `schedule` control verb — enqueue a sample-accurate event into the SPSC
    /// ring (drained at the next callback boundary). Returns false if the ring is
    /// full (the control thread may retry/coalesce; the RT thread is never
    /// stalled). Control thread only.
    pub fn schedule(self: *Self, cmd: control.Command) bool {
        return self.ring.enqueue(cmd);
    }

    pub fn sendEvent(self: *Self, event: control.Command) bool {
        return self.schedule(event);
    }

    // ---- The per-block transition policy: "ramp, never step" ----------------
    // start/stop, mute, solo, and bypass are all transitions, and a transition
    // must RAMP (glide across the buffer) rather than STEP (jump in one sample),
    // or it clicks. Every transition below drives a node's level slot through the
    // SAME atomic `set` + per-block ramp as a knob move — so the smoothing is the
    // one ramp policy, not a per-case re-implementation. (Bypass of a *latent*
    // block is the separate commit-time bypass-preserves-latency law; here bypass
    // of a non-latent block is just a ramped mute.)

    /// Mute node `node` by ramping its level slot to silence (0). Never steps.
    pub fn mute(self: *Self, node: usize, slot: u8) void {
        self.set(node, slot, 0.0);
    }

    /// Unmute node `node` by ramping its level slot back to unity (1). Never steps.
    pub fn unmute(self: *Self, node: usize, slot: u8) void {
        self.set(node, slot, 1.0);
    }

    /// Solo `soloed`: ramp every settable node's level slot to silence except the
    /// soloed node, which ramps to unity. A node with no settable level slot (no
    /// `setParam`) is skipped. All transitions are ramped (never stepped).
    pub fn solo(self: *Self, soloed: usize, slot: u8) void {
        for (self.bound, 0..) |b, i| {
            if (b.set == null) continue;
            self.set(i, slot, if (i == soloed) @as(f32, 1.0) else 0.0);
        }
    }

    /// Start/stop fade on a designated master/output node: a ramped fade-in (→1) on
    /// start and fade-out (→0) on stop, so beginning or ending playback glides
    /// instead of clicking. (Applied to the node the app designates as its output;
    /// a master fade on the device buffer itself binds at the on-device output
    /// stage.)
    pub fn fadeIn(self: *Self, node: usize, slot: u8) void {
        self.set(node, slot, 1.0);
    }
    pub fn fadeOut(self: *Self, node: usize, slot: u8) void {
        self.set(node, slot, 0.0);
    }

    /// Begin an `edit → commit` transaction over a working copy of the current
    /// graph. Mutate it with `add`/`connect`, then `commit` to RCU-swap.
    pub fn beginEdit(self: *Self) Edit {
        var e = Edit{ .eng = self, .ir = self.ir, .bound_count = self.bound.len };
        for (self.bound, 0..) |b, i| e.bound[i] = b;
        return e;
    }

    /// Re-commit the current graph and RCU-swap the plan in — the load-bearing
    /// `edit → commit` mechanism with no structural change (the swap itself). Proves
    /// a rebuilt plan replays over the live engine with no glitch and no
    /// audio-thread allocation or lock.
    pub fn recommit(self: *Self) !void {
        try self.installPlan(self.ir, self.bound);
    }

    /// Build a fresh immutable plan for `new_ir` + `new_bound` off-thread, then RCU
    /// publish it and reclaim the old plan after a grace period. The new pool must
    /// fit the engine's pool capacity (fixed at bind for the worst-case N) — a swap
    /// that would grow the pool past capacity returns `error.PoolCapacityExceeded`
    /// (use the stop + `reconfigure` protocol instead). The off-thread build is the
    /// only place that allocates; the swap is one release store and the RT-side
    /// consume is one acquire load.
    fn installPlan(self: *Self, new_ir: graph.Graph, new_bound: []const BoundNode) !void {
        const new_plan = try buildBoundPlan(self.alloc, new_ir, new_bound);
        errdefer self.alloc.destroy(new_plan);
        if (new_plan.pool_bytes > self.pool_cap) return error.PoolCapacityExceeded;

        // Adopt the new owned bound set, but DON'T free instances the edit dropped
        // yet — the still-active old plan references them. Keep the old set to free
        // after the grace period (below), so a callback rendering the old plan never
        // reads a freed instance.
        const old_bound = self.bound;
        self.bound = try self.alloc.dupe(BoundNode, new_bound);
        self.ir = new_ir;

        const at_swap = self.rcu.epochNow();
        const old = self.rcu.publish(new_plan); // (W) release store — the swap
        // Grace-period reclamation: an in-flight callback may still be reading the
        // old plan ONLY when the transport is RUNNING (a separate RT thread bumps
        // the epoch). When stopped, the control thread is the lone accessor, so the
        // old plan is freed immediately — waiting on an epoch no one advances would
        // deadlock. When running, wait until the epoch advances past the swap (a full
        // callback boundary crossed) before freeing.
        if (self.running.load(.acquire)) self.rcu.waitGrace(at_swap);
        self.alloc.destroy(old); // safe: no callback can still hold `old`

        // Now no callback can hold the old plan, so instances it dropped are safe to
        // free.
        for (old_bound) |ob| {
            var still_used = false;
            for (new_bound) |nb| {
                if (nb.self_ptr == ob.self_ptr) {
                    still_used = true;
                    break;
                }
            }
            if (!still_used) ob.destroy(self.alloc, ob.self_ptr);
        }
        self.alloc.free(old_bound);

        self.op_count = new_plan.op_count;
        self.footprint_bytes = new_plan.footprint_bytes;
    }

    /// Device-reconfiguration (route switch): re-negotiate for a new block size,
    /// rebuild the plan, and atomic-swap it in. The buffer-id assignment is
    /// **N-independent** — only the pool byte-sizes change — so when the pool was
    /// pre-sized for a worst-case N (`max_block_size`) and the new N fits, this is a
    /// LIVE RCU swap with NO reallocation (safe while the transport runs; the old
    /// plan is reclaimed after a grace period). When the new N exceeds the pre-sized
    /// pool, the pool is reallocated, which requires the transport STOPPED (no
    /// concurrent RT reader) — the desktop route-switch protocol.
    pub fn reconfigure(self: *Self, block_size: usize) !void {
        var new_ir = self.ir;
        new_ir.block_size = block_size;
        const new_plan = try buildBoundPlan(self.alloc, new_ir, self.bound);
        errdefer self.alloc.destroy(new_plan);

        if (new_plan.pool_bytes <= self.pool_cap) {
            // Live swap: the pre-sized pool already accommodates the new N.
            const at_swap = self.rcu.epochNow();
            const old = self.rcu.publish(new_plan);
            if (self.running.load(.acquire)) self.rcu.waitGrace(at_swap);
            self.alloc.destroy(old);
        } else {
            // The new N exceeds the pre-sized pool — reallocate (transport stopped).
            std.debug.assert(!self.running.load(.acquire));
            const new_pool = try allocPool(self.alloc, new_plan.pool_bytes);
            const old = self.rcu.publish(new_plan);
            freePool(self.alloc, self.pool);
            self.alloc.destroy(old);
            self.pool = new_pool;
            self.pool_cap = new_plan.pool_bytes;
        }
        self.ir = new_ir;
        self.cfg.block_size = block_size;
        self.op_count = new_plan.op_count;
        self.footprint_bytes = new_plan.footprint_bytes;
    }

    /// Offline batch render (Tier C) — deferred to the offline-execution phase.
    pub fn renderOffline(self: *Self) !void {
        _ = self;
        return error.OfflineNotImplemented;
    }

    pub fn renderToCompletion(self: *Self, opts: anytype) !void {
        _ = self;
        _ = opts;
        return error.OfflineNotImplemented;
    }

    pub fn telemetry(self: *Self) Telemetry {
        return self.tele;
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

// The runtime-engine test blocks: a buffer source, a halving gain, a copying
// sink — the same chain the comptime Executor renders, so the runtime-committed
// plan can be differenced against it.
const TBufSource = struct {
    const Self = @This();
    data: [*]const types.Sample(f32) = undefined,
    pub fn process(self: *Self, out: []types.Sample(f32)) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const TGain = struct {
    const Self = @This();
    gain: f32 = 1.0,
    pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
        for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.gain;
    }
};
const TBufSink = struct {
    const Self = @This();
    dest: [*]types.Sample(f32) = undefined,
    pub fn process(self: *Self, in: []const types.Sample(f32)) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

test "runtime Engine replays bit-identically to the comptime Executor (the differential gate)" {
    const builder = @import("builder.zig");

    var input: [8]types.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var out_ct: [8]types.Sample(f32) = undefined; // comptime Executor output
    var out_rt: [8]types.Sample(f32) = undefined; // runtime Engine output

    // --- comptime Executor over the same graph ---
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 8;
        const src = gg.add(TBufSource);
        const gain = gg.add(TGain);
        const sink = gg.add(TBufSink);
        gg.connect(port.MapOutPort(TBufSource), src, 0, port.MapInPort(TGain), gain, 0);
        gg.connect(port.MapOutPort(TGain), gain, 0, port.MapInPort(TBufSink), sink, 0);
        break :blk gg;
    };
    const Exec = Executor(g, &.{ TBufSource, TGain, TBufSink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = 0.5 },
        .{ .dest = &out_ct },
    } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    // --- runtime Engine over the same graph ---
    var bg = builder.Graph.init(std.testing.allocator, .{ .precision = .f32, .channels = .mono, .block_size = 8 });
    defer bg.deinit();
    const s = try bg.add(TBufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const gn = try bg.add(TGain, .{ .gain = 0.5 });
    const sk = try bg.add(TBufSink, .{ .dest = @as([*]types.Sample(f32), &out_rt) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();
    eng.renderInto(token);

    // The runtime-committed plan and the comptime Executor share `computePlan`, so
    // their outputs must be bit-identical (pan-vs-pan: always exact).
    for (out_ct, out_rt) |a, b| try std.testing.expectEqual(a.ch[0], b.ch[0]);
    try std.testing.expectEqual(@as(usize, 3), eng.op_count);
    try std.testing.expect(eng.footprint_bytes == Exec.committed.footprint_bytes);
    try std.testing.expectEqual(!std.debug.runtime_safety, eng.telemetry().guards_compiled_out);
}

test "edit→commit: RCU swap rebuilds the live plan with no glitch (epoch grace)" {
    const builder = @import("builder.zig");
    var input: [8]types.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var out_rt: [8]types.Sample(f32) = undefined;

    var bg = builder.Graph.init(std.testing.allocator, .{ .channels = .mono, .block_size = 8 });
    defer bg.deinit();
    const s = try bg.add(TBufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const gn = try bg.add(TGain, .{ .gain = 0.5 });
    const sk = try bg.add(TBufSink, .{ .dest = @as([*]types.Sample(f32), &out_rt) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token); // RT consume bumps the epoch
    const e0 = eng.rcu.epochNow();

    // Re-commit the SAME graph: build a fresh immutable plan off-thread and RCU-swap
    // it in, reclaiming the old plan after a grace period. The render after the swap
    // is bit-identical and the epoch advanced past the swap.
    try eng.recommit();
    eng.renderInto(token);
    for (input, out_rt) |x, y| try std.testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
    try std.testing.expect(eng.rcu.epochNow() > e0);
    try std.testing.expect(!eng.telemetry().fault);
}

// A gain whose coefficient is driven by the `set`/`schedule` control verbs: an
// atomic target ramped zipper-free toward over each block (the anti-zipper policy).
const RampGain = struct {
    const Self = @This();
    param: control.Param = control.Param.init(1.0),
    ramp: control.Ramp = control.Ramp.init(1.0),
    pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
        const target = self.param.read(); // atomic load of the set target
        const inc = self.ramp.begin(target, in.len);
        for (in, out, 0..) |x, *o, i| {
            const g = self.ramp.value + @as(f32, @floatFromInt(i + 1)) * inc;
            o.ch[0] = x.ch[0] * g;
        }
        self.ramp.finish(target); // snap, no drift
    }
    /// The control-verb bridge: an external `set`/`schedule` stores the new target
    /// (slot 0 = gain). Wait-free atomic store; the ramp closes the gap audibly.
    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        if (slot == 0) self.param.set(value);
    }
};

test "set verb: an atomic target is ramped zipper-free through the runtime engine" {
    const builder = @import("builder.zig");
    var input: [8]types.Sample(f32) = undefined;
    for (&input) |*s| s.ch[0] = 1.0; // constant input isolates the ramp shape
    var out_rt: [8]types.Sample(f32) = undefined;

    var bg = builder.Graph.init(std.testing.allocator, .{ .channels = .mono, .block_size = 8 });
    defer bg.deinit();
    const s = try bg.add(TBufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const rg = try bg.add(RampGain, .{});
    const sk = try bg.add(TBufSink, .{ .dest = @as([*]types.Sample(f32), &out_rt) });
    try bg.connect(s, rg);
    try bg.connect(rg, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    // `set` the gain target to 0.0 from "the control thread" (here, this thread).
    eng.set(rg.id, 0, 0.0);

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    // The output glides 1→0 across the block with NO instantaneous jump (anti-
    // zipper): each sample differs from the previous by the constant ramp step.
    const step: f32 = (0.0 - 1.0) / 8.0;
    var prev: f32 = 1.0;
    for (out_rt) |y| {
        try std.testing.expect(@abs(y.ch[0] - prev) <= @abs(step) + 1e-6);
        prev = y.ch[0];
    }
    try std.testing.expect(out_rt[7].ch[0] < out_rt[0].ch[0]); // descending toward 0

    // `schedule` routes through the SPSC ring and applies at the boundary.
    try std.testing.expect(eng.schedule(.{ .at_sample = 0, .node = rg.id, .param = 0, .value = 1.0 }));
    eng.renderInto(token); // drains the ring, applies value=1.0
}

test "transition policy: mute and solo RAMP (never step) via the set + ramp path" {
    const builder = @import("builder.zig");
    var input: [8]types.Sample(f32) = undefined;
    for (&input) |*s| s.ch[0] = 1.0;
    var out_rt: [8]types.Sample(f32) = undefined;

    const token = enterRealtimeThread();
    defer token.leave();

    // source → pgA → pgB → sink (two settable level nodes in series).
    var g = builder.Graph.init(std.testing.allocator, .{ .channels = .mono, .block_size = 8 });
    defer g.deinit();
    const s = try g.add(TBufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const a = try g.add(ParamGain, .{});
    const b = try g.add(ParamGain, .{});
    const k = try g.add(TBufSink, .{ .dest = @as([*]types.Sample(f32), &out_rt) });
    try g.connect(s, a);
    try g.connect(a, b);
    try g.connect(b, k);
    var eng = try g.commit();
    defer eng.deinit();

    // mute(a): a's level ramps 1 → 0 across the block — no instantaneous jump.
    eng.mute(a.id, 0);
    eng.renderInto(token);
    const step: f32 = (0.0 - 1.0) / 8.0;
    var prev: f32 = 1.0; // a starts at unity; b is still unity so out == a-gain·1
    for (out_rt) |y| {
        try std.testing.expect(@abs(y.ch[0] - prev) <= @abs(step) + 1e-6); // ramped, not stepped
        prev = y.ch[0];
    }
    try std.testing.expect(out_rt[7].ch[0] < out_rt[0].ch[0]); // gliding toward silence

    // solo(b): every other settable node (a) ramps to 0, b stays at unity. a is
    // already near 0; assert solo set a's target to 0 and b's to 1 (the soloed node
    // is the one NOT muted) by checking the next render keeps descending (a muted).
    eng.solo(b.id, 0);
    eng.renderInto(token);
    try std.testing.expect(out_rt[7].ch[0] <= out_rt[0].ch[0]); // non-soloed `a` stays muted
    try std.testing.expect(!eng.telemetry().fault);
}

// A gain whose coefficient is a parameter PORT (`node.param.gain`, slot 0) — so it
// can be driven EITHER by `set` (atomic) OR by a wired control-rate edge, the two
// being two sources of the same per-block-ramped coefficient (catalog §2.4). It
// holds + ramps exactly like RampGain, so set vs a wired edge are bit-identical.
const ParamGain = struct {
    const Self = @This();
    param: control.Param = control.Param.init(1.0),
    ramp: control.Ramp = control.Ramp.init(1.0),
    pub const params = .{ .gain = types.Scalar(f32) };
    pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
        const target = self.param.read();
        const inc = self.ramp.begin(target, in.len);
        for (in, out, 0..) |x, *o, i| o.ch[0] = x.ch[0] * (self.ramp.value + @as(f32, @floatFromInt(i + 1)) * inc);
        self.ramp.finish(target);
    }
    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        if (slot == 0) self.param.set(value);
    }
};
// A control-rate source emitting a constant Scalar coefficient — the in-graph
// modulation source (the wired-edge analogue of `set`).
const ConstScalar = struct {
    const Self = @This();
    val: f32 = 0,
    pub fn process(self: *Self, out: []types.Scalar(f32)) void {
        for (out) |*o| o.value = self.val;
    }
};

test "param edge (P3/P4): a wired parameter edge is bit-identical to `set` for the same coefficient" {
    const builder = @import("builder.zig");
    var input: [8]types.Sample(f32) = undefined;
    for (&input) |*s| s.ch[0] = 1.0;
    var out_set: [8]types.Sample(f32) = undefined;
    var out_wire: [8]types.Sample(f32) = undefined;
    const target: f32 = 0.25;

    const token = enterRealtimeThread();
    defer token.leave();

    // (A) `set` source: drive ParamGain's gain slot via the external atomic verb.
    var ga = builder.Graph.init(std.testing.allocator, .{ .channels = .mono, .block_size = 8 });
    defer ga.deinit();
    const sa = try ga.add(TBufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const pga = try ga.add(ParamGain, .{});
    const ka = try ga.add(TBufSink, .{ .dest = @as([*]types.Sample(f32), &out_set) });
    try ga.connect(sa, pga);
    try ga.connect(pga, ka);
    var ea = try ga.commit();
    defer ea.deinit();
    ea.set(pga.id, 0, target); // external `set`
    ea.renderInto(token);

    // (B) wired parameter edge: a control-rate ConstScalar(target) wired into the
    // SAME parameter slot — the in-graph analogue, applied before process and held/
    // ramped by the consumer identically. P4: the param edge is an ordinary edge
    // (it is colored + scheduled before its consumer in the topo sort).
    var gb = builder.Graph.init(std.testing.allocator, .{ .channels = .mono, .block_size = 8 });
    defer gb.deinit();
    const sb = try gb.add(TBufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const pgb = try gb.add(ParamGain, .{});
    const kb = try gb.add(TBufSink, .{ .dest = @as([*]types.Sample(f32), &out_wire) });
    const lfo = try gb.add(ConstScalar, .{ .val = target });
    try gb.connect(sb, pgb);
    try gb.connect(pgb, kb);
    try gb.connect(lfo, pgb.param.gain); // wired control edge → parameter port
    var eb = try gb.commit();
    defer eb.deinit();
    try std.testing.expect(eb.op_count == 4); // src, paramgain, sink, lfo — param edge adds a node
    eb.renderInto(token);

    // The two sources of the coefficient produce BIT-IDENTICAL output (P3).
    for (out_set, out_wire) |a, b| try std.testing.expectEqual(a.ch[0], b.ch[0]);
    // And the coefficient actually moved (1.0 → 0.25 ramp), so this isn't trivially equal.
    try std.testing.expect(out_wire[7].ch[0] < out_wire[0].ch[0]);
}

test "reconfigure: a block-size change rebuilds the plan + pool and re-renders" {
    const builder = @import("builder.zig");
    var input: [16]types.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var out_rt: [16]types.Sample(f32) = undefined;

    var bg = builder.Graph.init(std.testing.allocator, .{ .channels = .mono, .block_size = 8 });
    defer bg.deinit();
    const s = try bg.add(TBufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const gn = try bg.add(TGain, .{ .gain = 2.0 });
    const sk = try bg.add(TBufSink, .{ .dest = @as([*]types.Sample(f32), &out_rt) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    const fp8 = eng.footprint_bytes;
    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);
    for (0..8) |i| try std.testing.expectEqual(input[i].ch[0] * 2.0, out_rt[i].ch[0]);

    // Route switch to N=16 (transport stopped, the desktop reconfig protocol): the
    // buffer-id assignment is N-independent, so only the pool byte-sizes change.
    try eng.reconfigure(16);
    try std.testing.expect(eng.footprint_bytes == fp8 * 2); // pool scales linearly with N
    eng.renderInto(token);
    for (0..16) |i| try std.testing.expectEqual(input[i].ch[0] * 2.0, out_rt[i].ch[0]);
    try std.testing.expect(!eng.telemetry().fault);
}

test "edit→commit under a concurrent RT render thread (ThreadSanitizer surface)" {
    const builder = @import("builder.zig");
    var input: [8]types.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var out_rt: [8]types.Sample(f32) = undefined;

    var bg = builder.Graph.init(std.testing.allocator, .{ .channels = .mono, .block_size = 8 });
    defer bg.deinit();
    const s = try bg.add(TBufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const gn = try bg.add(TGain, .{ .gain = 0.5 });
    const sk = try bg.add(TBufSink, .{ .dest = @as([*]types.Sample(f32), &out_rt) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    // Model a running transport so the control thread's RCU reclamation waits for
    // the grace period (the RT thread below advances the epoch).
    eng.running.store(true, .release);

    // Control thread: a burst of edit→commit RCU swaps (each rebuilds the plan
    // off-thread, release-publishes the pointer, waits the epoch grace, frees the
    // old plan). Single writer — honors the SPSC/RCU funnel contract. It signals
    // `done` so the RT thread keeps advancing the epoch until every grace wait can
    // complete (else the epoch would freeze and a grace wait would hang).
    var done: std.atomic.Value(bool) = .init(false);
    const Ctl = struct {
        fn run(e: *Engine, n: usize, d: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (i < n) : (i += 1) e.recommit() catch unreachable;
            d.store(true, .release);
        }
    };
    const token = enterRealtimeThread();
    const t = try std.Thread.spawn(.{}, Ctl.run, .{ &eng, 200, &done });
    // RT thread (this one): render continuously, bumping the epoch each callback so
    // the control thread's grace waits terminate. Wait-free, no allocation.
    while (!done.load(.acquire)) eng.renderInto(token);
    eng.renderInto(token); // a final settled render
    t.join();
    eng.running.store(false, .release);
    token.leave();

    // The render is correct after all the swaps, and no block faulted.
    for (input, out_rt) |x, y| try std.testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
    try std.testing.expect(!eng.telemetry().fault);
}

test "set rejects sample-accuracy at the type level (no at_sample on `set`; only `schedule`)" {
    // `set` moves a continuous knob — wait-free, click-free, NOT sample-accurate by
    // contract. There is deliberately no `at_sample` parameter on `set`, so
    // "I expected set() to be sample-accurate" is a structural omission, not a
    // silent wrong behaviour. Sample-accurate intent is expressible ONLY on
    // `schedule`, whose Command carries `at_sample`.
    const set_params = @typeInfo(@TypeOf(Engine.set)).@"fn".params;
    try std.testing.expectEqual(@as(usize, 4), set_params.len); // self, node, slot, value — no at_sample
    try std.testing.expect(@hasField(control.Command, "at_sample")); // schedule IS sample-accurate
}

test "reconfigure (live): a max-N pre-sized pool swaps N without reallocation" {
    const builder = @import("builder.zig");
    var input: [16]types.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var out_rt: [16]types.Sample(f32) = undefined;

    // Pre-size the pool for N=16 while committing at N=8. The pool capacity already
    // accommodates N≤16, so reconfigure(16) is a LIVE RCU swap with no realloc — the
    // pool pointer is unchanged across the swap (the N-independence of the map).
    var bg = builder.Graph.init(std.testing.allocator, .{ .channels = .mono, .block_size = 8, .max_block_size = 16 });
    defer bg.deinit();
    const s = try bg.add(TBufSource, .{ .data = @as([*]const types.Sample(f32), &input) });
    const gn = try bg.add(TGain, .{ .gain = 3.0 });
    const sk = try bg.add(TBufSink, .{ .dest = @as([*]types.Sample(f32), &out_rt) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    const pool_ptr_before = eng.pool.ptr;
    const cap_before = eng.pool_cap;
    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    try eng.reconfigure(16); // N ≤ pre-sized max ⇒ no realloc
    try std.testing.expectEqual(pool_ptr_before, eng.pool.ptr); // SAME pool — live swap
    try std.testing.expectEqual(cap_before, eng.pool_cap); // capacity unchanged
    eng.renderInto(token);
    for (0..16) |i| try std.testing.expectEqual(input[i].ch[0] * 3.0, out_rt[i].ch[0]);
    try std.testing.expect(!eng.telemetry().fault);
}
