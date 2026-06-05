//! Tier B — the static-parallel RealtimeStreaming executor.
//!
//! Tier A is the frozen ground truth: one worker replays the committed op-list
//! sequentially in the audio callback, wait-free, never spinning. Tier B is an
//! opt-in, measured *overlay* that spreads the same op-list across `P` cores under
//! a commit-time schedule, and **auto-demotes back to Tier A** the moment it stops
//! paying off. Nothing here replaces Tier A; the gate (`costGate`) and the demote
//! policy (`DemotePolicy`) keep the worst observed outcome at "runs as Tier A,"
//! never "xruns."
//!
//! The load-bearing correctness claim: **Tier B output is bit-identical to Tier
//! A.** Two facts secure it.
//!   1. The schedule places *whole ops* — it never splits a single fan-in /
//!      reduction across workers — so every op still reads its input buffer-ids in
//!      fixed port order regardless of which worker produced them. The
//!      floating-point reduction order is therefore a property of the op, not of
//!      the schedule.
//!   2. Tier B replays the *same* committed (colored) plan over the *same* pool as
//!      Tier A. The op-DAG built here adds, on top of the true producer→consumer
//!      (read-after-write) edges, the **anti-dependencies** that the colored pool's
//!      buffer reuse implies: a write-after-read edge (a later op overwrites a
//!      colored buffer a prior op still reads) and a write-after-write edge (two
//!      ops reuse one colored buffer in sequence). Honouring those edges makes the
//!      existing sequential coloring a *valid concurrent schedule*: no two ops that
//!      touch the same pool buffer ever run at once, so the shared pool is never
//!      torn. Because the buffers, kernels, and reduction order are identical to
//!      the sequential replay, the result is identical bit-for-bit. (A genuinely
//!      wide graph — many parallel voices feeding a mix — gives each concurrent
//!      sibling its own color anyway, since their live ranges overlap, so the
//!      anti-dependencies only re-serialize what was already a sequential chain and
//!      do not cost the parallelism Tier B exists to capture.)
//!
//! Because Tier A and Tier B run the identical bound plan over the identical pool,
//! the persistent feedback tail (the z⁻¹ state that survives a callback) is shared,
//! so auto-demote is a single branch at the callback boundary — not a plan swap —
//! and it is click-free across the switch.
//!
//! Two executors ship on one foundation:
//!   * the **level-barrier** fork-join (ASAP levels, an atomic-countdown barrier
//!     between levels) — deadlock-free by construction, the safe default;
//!   * the **HEFT** list-schedule with **point-to-point release/acquire ready
//!     flags** — finer-grained, fills bubbles a barrier cannot, the committed
//!     low-latency default once proven.
//!
//! The bounded-spin claim (a consumer worker spins on a producer's ready flag only
//! as long as the producer is running, never longer) rests on the platform
//! co-scheduling the workers — the Render-Workgroup HAL below. pan cannot *prove*
//! the OS honours co-scheduling (the same honesty class as the flush-to-zero
//! token); if a workgroup is unavailable the gate keeps the engine on Tier A, and
//! the demote policy catches any breach in practice via per-worker spin telemetry.

const std = @import("std");
const builtin = @import("builtin");
const commit = @import("commit.zig");
const graph = @import("graph.zig");
const port = @import("port.zig");
const engine = @import("engine.zig");

/// Upper bound on ops in a schedule — one op per graph node.
pub const max_ops = graph.max_nodes;
/// Upper bound on render workers. A predecessor bitset is one `u64`, so the op
/// count is already capped at 64 by `graph.max_nodes`; workers are capped well
/// below the op count for any real graph.
pub const max_workers = 64;

// ===========================================================================
// 1. The Render-Workgroup HAL — { create, join(token), leave }
// ===========================================================================

/// The third HAL concern (alongside the Compute HAL and the I/O HAL): the
/// co-scheduling contract that bounds the cross-worker spin. A thin, target-mapped
/// interface. `available` is the **feasibility witness** the cost gate consumes —
/// not a proof. When false, the gate keeps the engine on Tier A.
///
///   * macOS (the dev M3): the CoreAudio device's `os_workgroup`
///     (`kAudioDevicePropertyIOThreadOSWorkgroup`); workers join it before their
///     first render and leave at teardown. The OS co-schedules members under the
///     audio deadline and does not deschedule one while a peer runs.
///   * Linux: SCHED_FIFO/SCHED_DEADLINE RT worker threads plus CPU affinity /
///     isolcpus / cpusets — the userland core isolation macOS lacks.
///   * embedded: N/A — single core, or a fixed second-core static partition.
///
/// The exact `os_workgroup` C surface is an implementation detail to confirm on the
/// target (C-interop via `extern`); what is committed is the *decision* that
/// workers are co-scheduled members of the device's RT workgroup. This struct
/// carries an opaque platform handle so a real device workgroup can be threaded in
/// without changing the worker-pool code; with no handle it reports unavailable.
pub const Workgroup = struct {
    /// Whether co-scheduling is available on this target/handle. The honest bound:
    /// true only when a real workgroup (macOS device handle) or the RT-scheduling
    /// mechanism (Linux SCHED_FIFO + affinity) backs it.
    available: bool = false,
    /// Opaque platform handle (an `os_workgroup_t` on macOS). Null ⇒ no device
    /// workgroup; on macOS join/leave are no-ops and `available` is false (unless a
    /// handle is bound via `withHandle`).
    handle: ?*anyopaque = null,

    /// A per-worker join token. On macOS it holds the `os_workgroup_join_token_s`
    /// the join fills and the leave consumes (it lives on the worker's stack for the
    /// worker's whole lifetime). Unused on other targets. Sized generously past the
    /// ~56-byte SDK struct.
    pub const Token = extern struct { bytes: [64]u8 align(16) = undefined };

    /// Probe the platform for the co-scheduling mechanism.
    ///   * Linux: SCHED_FIFO + CPU affinity is the documented bound and the
    ///     mechanism is always present, so `available = true` (whether the *process*
    ///     has the RT-scheduling privilege is a best-effort runtime detail applied at
    ///     join — an unprivileged process simply runs the workers at normal priority,
    ///     a weaker but still-functional bound).
    ///   * macOS / embedded / other: no mechanism without a real device workgroup
    ///     handle, so `available = false` until one is bound via `withHandle`.
    pub fn detect() Workgroup {
        return switch (builtin.os.tag) {
            .linux => .{ .available = true, .handle = null },
            else => .{ .available = false, .handle = null },
        };
    }

    /// Bind a real platform workgroup handle (e.g. the CoreAudio device's
    /// `os_workgroup_t` from `kAudioDevicePropertyIOThreadOSWorkgroup`). Marks the
    /// workgroup available so the gate may promote and the workers join it.
    pub fn withHandle(handle: *anyopaque) Workgroup {
        return .{ .available = true, .handle = handle };
    }

    /// A worker joins the co-scheduling group before its first render, recording any
    /// platform token into `token` (for the matching `leaveThread`). Requires the
    /// realtime token (the per-thread FTZ proof) so a worker cannot join — and then
    /// render — without having entered realtime mode. `wid` is the worker index, used
    /// to spread the workers across cores (Linux affinity).
    ///   * macOS: `os_workgroup_join(handle, &token)` if a device handle is bound.
    ///   * Linux: best-effort SCHED_FIFO at a low RT priority + pin to CPU `wid`.
    ///   * else: no-op.
    pub fn joinThread(self: Workgroup, token: *Token, wid: usize, rt: engine.RealtimeToken) void {
        _ = rt; // holding it is the contract
        switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => {
                if (self.handle) |h| _ = os_workgroup_join(h, @ptrCast(token));
            },
            .linux => setLinuxRtScheduling(wid),
            else => {},
        }
    }

    /// A worker leaves the co-scheduling group at teardown, consuming the token the
    /// join recorded. No-op without a real handle / on non-macOS.
    pub fn leaveThread(self: Workgroup, token: *Token) void {
        switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => {
                if (self.handle) |h| os_workgroup_leave(h, @ptrCast(token));
            },
            else => {},
        }
    }
};

// CoreAudio/libdispatch render-workgroup C surface (always in libsystem on Darwin).
// Referenced only from the Darwin branch of `joinThread`/`leaveThread`, which is
// comptime-eliminated on other targets, so these never need to link elsewhere.
extern "c" fn os_workgroup_join(wg: ?*anyopaque, token: ?*anyopaque) c_int;
extern "c" fn os_workgroup_leave(wg: ?*anyopaque, token: ?*anyopaque) void;

/// Best-effort Linux RT scheduling for a render worker: SCHED_FIFO at a low static
/// priority plus affinity to CPU `cpu`. Errors (e.g. an unprivileged process) are
/// ignored — the worker then runs at normal priority, a weaker but functional bound.
fn setLinuxRtScheduling(cpu: usize) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    // A low SCHED_FIFO priority keeps the workers below the audio IO thread but above
    // ordinary threads; co-scheduling under load is what bounds the cross-worker spin.
    const param = linux.sched_param{ .priority = 1 };
    _ = linux.sched_setscheduler(0, .FIFO, &param); // 0 = the calling thread
    // Pin to one CPU so a worker is not migrated mid-render (the M3-migration hazard
    // macOS cannot prevent in userland — here we can).
    var set = std.mem.zeroes(linux.cpu_set_t);
    const bits = @bitSizeOf(usize);
    const c = cpu % (linux.CPU_SETSIZE);
    set[c / bits] |= @as(usize, 1) << @intCast(c % bits);
    linux.sched_setaffinity(0, &set) catch {};
}

// ===========================================================================
// 2. The cost-model gate — when to parallelize, and choosing P (decidable)
// ===========================================================================

/// Configured gate constants. Tunable; the defaults are conservative (parallelize
/// only a clearly-busy, clearly-parallel graph).
pub const GateConfig = struct {
    /// One core "cannot keep up" once total work exceeds this fraction of the
    /// callback deadline. Below it, Tier A has headroom — stay sequential.
    theta_busy: f32 = 0.6,
    /// Minimum achievable speedup (work / span-bounded makespan) to bother:
    /// a near-linear chain has parallelism ≈ 1 and is refused.
    theta_speedup: f32 = 1.5,
    /// Headroom target: size P to land single-core-equivalent load at this
    /// fraction of the deadline.
    target_headroom: f32 = 0.7,
};

/// The gate's verdict. `enable` is the decision; `p` the chosen worker count;
/// the two ratios are surfaced for telemetry and the differential/decision tests.
pub const GateDecision = struct {
    enable: bool,
    p: usize,
    /// work / max(span, work/p_max) — the achievable speedup ceiling.
    parallelism: f32,
    /// work / (deadline · target_headroom) — single-core load in deadline units.
    single_core_load: f32,
};

/// Decide whether to run Tier B and on how many workers. A decidable computation
/// over commit-known totals: `work` (Σ per-op WCET), `span` (the longest weighted
/// path through the DAG-minus-feedback — no schedule beats `max(span, work/P)`),
/// the available core budget, the callback deadline, and whether a workgroup
/// co-schedules the workers. Enable iff all three hold:
///   * the graph is *busy* — one core's worth of work exceeds θ_busy·deadline;
///   * the graph is *parallel* — the speedup ceiling clears θ_speedup (a chain,
///     where span ≈ work, is refused: parallelism buys nothing);
///   * a workgroup is *available* to bound the cross-worker spin.
/// `P` is the load divided across cores to hit the headroom target, clamped to the
/// core budget.
pub fn costGate(
    work: f32,
    span_len: f32,
    p_max: usize,
    deadline: f32,
    workgroup_available: bool,
    cfg: GateConfig,
) GateDecision {
    const pmaxf: f32 = @floatFromInt(@max(p_max, 1));
    const span_floor = @max(span_len, work / pmaxf);
    const parallelism: f32 = if (span_floor > 0) work / span_floor else 1.0;
    const denom = deadline * cfg.target_headroom;
    const single_core_load: f32 = if (denom > 0) work / denom else 0.0;

    const busy = work > deadline * cfg.theta_busy;
    const parallel = parallelism >= cfg.theta_speedup;
    const enable = busy and parallel and workgroup_available;

    // P sized so the per-core load meets the headroom target, clamped to budget.
    var p: usize = @intFromFloat(@ceil(single_core_load));
    if (p < 1) p = 1;
    if (p > p_max) p = p_max;
    if (!enable) p = 1;
    return .{
        .enable = enable,
        .p = p,
        .parallelism = parallelism,
        .single_core_load = single_core_load,
    };
}

// ===========================================================================
// 3. The op-DAG — true edges plus the colored-pool anti-dependencies
// ===========================================================================

/// The dependency DAG over a plan's op-list. `preds[i]` is the bitset of op indices
/// op `i` must wait on. All edges run from a lower op index to a higher one (the
/// op-list is forward-topo and every dependency — read-after-write, write-after-
/// read, write-after-write — points forward), so the index order is itself a valid
/// topological order. Feedback (z⁻¹) read sides carry no intra-block producer (they
/// read the previous block's value), so a feedback buffer contributes only the
/// write-after-read edge that orders this block's read before this block's write —
/// exactly what keeps the persistent tail uncorrupted.
pub const Dag = struct {
    n: usize = 0,
    preds: [max_ops]u64 = [_]u64{0} ** max_ops,
    /// Successor bitsets — the transpose, used by the scheduler's upward rank.
    succs: [max_ops]u64 = [_]u64{0} ** max_ops,

    pub fn predOf(self: *const Dag, op: usize) u64 {
        return self.preds[op];
    }
};

fn bitSet(mask: *u64, i: usize) void {
    mask.* |= (@as(u64, 1) << @intCast(i));
}

/// A topological order of the DAG by Kahn's algorithm (peel zero-indegree ops). The
/// op-DAG is acyclic — true dataflow edges respect topo order and the schedule-time
/// reuse anti-dependencies follow a total time order — so this always succeeds. The
/// schedulers walk this order rather than assuming op-index order, since a
/// concurrency-aware recolor can introduce edges that run high→low op index.
/// Ties (multiple ready ops) break by ascending op index for determinism. Returns
/// the count placed (== dag.n for an acyclic DAG).
fn topoOrder(dag: *const Dag, out: *[max_ops]usize) usize {
    var indeg: [max_ops]u32 = undefined;
    var done = [_]bool{false} ** max_ops;
    var i: usize = 0;
    while (i < dag.n) : (i += 1) indeg[i] = @popCount(dag.preds[i]);
    var placed: usize = 0;
    while (placed < dag.n) {
        // Pick the lowest-index ready (indegree 0, not placed) op.
        var pick: usize = max_ops;
        var c: usize = 0;
        while (c < dag.n) : (c += 1) {
            if (!done[c] and indeg[c] == 0) {
                pick = c;
                break;
            }
        }
        if (pick == max_ops) break; // cycle guard (should not happen)
        done[pick] = true;
        out[placed] = pick;
        placed += 1;
        var sc = dag.succs[pick];
        while (sc != 0) {
            const j = @ctz(sc);
            sc &= sc - 1;
            if (indeg[j] > 0) indeg[j] -= 1;
        }
    }
    return placed;
}

/// Build the op-DAG from a committed plan, walking the op-list in TOPO (op-index)
/// order — correct when the buffer value-sequence follows op-index order (the
/// per-edge plan, where each value has its own buffer). After a concurrency-aware
/// recolor (where a buffer's value-sequence follows SCHEDULE order, not op-index
/// order) use `buildDagOrdered` instead. Tracks per buffer its last writer and the
/// readers since that write: a consumer depends on the current writer
/// (read-after-write); a writer reusing a buffer depends on every reader of the
/// prior value (write-after-read) and on the prior writer (write-after-write).
/// Parameter-edge inputs participate identically.
pub fn buildDag(plan: anytype) Dag {
    var order: [max_ops]usize = undefined;
    var i: usize = 0;
    while (i < plan.op_count) : (i += 1) order[i] = i;
    return buildDagOrdered(plan, order[0..plan.op_count]);
}

/// As `buildDag`, but walking the ops in the given execution `order` (op indices).
/// After a schedule-time recolor, the value occupying a reused buffer changes in
/// SCHEDULE order, so the reuse anti-dependencies must be derived in that order; pass
/// the schedule's global start-time order here so the consumer/writer dependencies
/// reflect the real buffer value-sequence (otherwise a reused buffer's reader could
/// be ordered after the next writer — a torn pool).
pub fn buildDagOrdered(plan: anytype, order: []const usize) Dag {
    var dag: Dag = .{ .n = plan.op_count };
    const none = std.math.maxInt(usize);
    var last_writer = [_]usize{none} ** graph.max_buffers;
    var readers = [_]u64{0} ** graph.max_buffers;

    for (order) |i| {
        const op = &plan.ops[i];
        // Inputs: sample edges then parameter edges. Each read depends on the
        // buffer's current writer and records itself as a reader.
        var k: usize = 0;
        while (k < op.input_count) : (k += 1) {
            const b = op.input_buffer_ids[k];
            if (b < graph.max_buffers) {
                if (last_writer[b] != none and last_writer[b] != i) {
                    bitSet(&dag.preds[i], last_writer[b]);
                    bitSet(&dag.succs[last_writer[b]], i);
                }
                bitSet(&readers[b], i);
            }
        }
        k = 0;
        while (k < op.param_input_count) : (k += 1) {
            const b = op.param_input_buffer_ids[k];
            if (b < graph.max_buffers) {
                if (last_writer[b] != none and last_writer[b] != i) {
                    bitSet(&dag.preds[i], last_writer[b]);
                    bitSet(&dag.succs[last_writer[b]], i);
                }
                bitSet(&readers[b], i);
            }
        }
        // Outputs: each write must follow every prior reader of the buffer
        // (write-after-read) and the prior writer (write-after-write), then becomes
        // the buffer's current writer with its reader set cleared.
        k = 0;
        while (k < op.output_count) : (k += 1) {
            const b = op.output_buffer_ids[k];
            if (b >= graph.max_buffers) continue;
            var rd = readers[b];
            while (rd != 0) {
                const r = @ctz(rd);
                rd &= rd - 1;
                if (r != i) {
                    bitSet(&dag.preds[i], r);
                    bitSet(&dag.succs[r], i);
                }
            }
            if (last_writer[b] != none and last_writer[b] != i) {
                bitSet(&dag.preds[i], last_writer[b]);
                bitSet(&dag.succs[last_writer[b]], i);
            }
            last_writer[b] = i;
            readers[b] = 0;
        }
    }
    return dag;
}

// ===========================================================================
// 4. Costs, work, and span
// ===========================================================================

/// Per-op WCET estimates the gate and HEFT consume. The static model is the data
/// volume an op produces (bytes written ≈ work); `refine` folds a measured CPU
/// sample into an EWMA so the estimate tracks reality over successive callbacks.
pub const CostModel = struct {
    /// The WCET estimate the gate and HEFT consume (a P-core / uniform estimate).
    cost: [max_ops]f32 = [_]f32{0} ** max_ops,
    /// The E-core (efficiency-core) WCET estimate — the P/E asymmetry an M3-class
    /// big.LITTLE machine exhibits. Seeded equal to `cost`; a core-type-aware HEFT
    /// placement consumes it once on-device topology tells which workers sit on E
    /// cores (a ≈ on-device refinement — there is no userland core-type control on
    /// macOS, and Linux affinity needs a topology probe — so the static seed is
    /// equal and the asymmetry is folded in by `refine` from per-core telemetry).
    cost_e: [max_ops]f32 = [_]f32{0} ** max_ops,
    n: usize = 0,

    /// Seed the model from a plan: cost(op) ∝ total output bytes, plus a small
    /// per-op constant so a zero-output sink/op still carries weight.
    pub fn fromPlan(plan: anytype) CostModel {
        var m: CostModel = .{ .n = plan.op_count };
        var i: usize = 0;
        while (i < plan.op_count) : (i += 1) {
            const op = &plan.ops[i];
            var bytes: usize = 0;
            var k: usize = 0;
            while (k < op.output_count) : (k += 1) {
                const b = op.output_buffer_ids[k];
                if (b < graph.max_buffers) bytes += plan.buffer_byte_len[b];
            }
            // A sink (no outputs) still consumes its inputs; weight it by input
            // volume so it is not free.
            if (op.output_count == 0) {
                k = 0;
                while (k < op.input_count) : (k += 1) {
                    const b = op.input_buffer_ids[k];
                    if (b < graph.max_buffers) bytes += plan.buffer_byte_len[b];
                }
            }
            // Per-kernel cost = data volume × the block's relative compute intensity
            // (`cost_hint`, 1.0 by default). Without it every op writing N samples
            // weighs the same, so a cheap adder inflates the critical path and the gate
            // under-estimates a compute-heavy graph's parallelism; the hint restores the
            // true work ratio (a biquad/FFT voice ≫ an adder) so P sizes correctly.
            m.cost[i] = (1.0 + @as(f32, @floatFromInt(bytes))) * op.cost_hint;
            m.cost_e[i] = m.cost[i];
        }
        return m;
    }

    /// Fold a measured per-op CPU time into the P-core EWMA estimate (α weights the
    /// new sample). Off the RT path — a commit-time / telemetry-trigger refinement.
    pub fn refine(self: *CostModel, op: usize, measured: f32, alpha: f32) void {
        if (op >= self.n) return;
        self.cost[op] = (1.0 - alpha) * self.cost[op] + alpha * measured;
    }

    /// Fold an E-core measured per-op CPU time into the E-core EWMA estimate.
    pub fn refineE(self: *CostModel, op: usize, measured: f32, alpha: f32) void {
        if (op >= self.n) return;
        self.cost_e[op] = (1.0 - alpha) * self.cost_e[op] + alpha * measured;
    }

    /// Recalibrate the whole model from a vector of measured per-op CPU samples (the
    /// EWMA telemetry feedback a non-RT telemetry pass applies, then re-runs the
    /// schedule on commit). `measured.len` may be ≤ `n`; the rest are untouched.
    pub fn refineAll(self: *CostModel, measured: []const f32, alpha: f32) void {
        for (measured, 0..) |s, op| self.refine(op, s, alpha);
    }
};

/// Total work `W = Σ_op cost(op)`.
pub fn totalWork(dag: *const Dag, costs: *const CostModel) f32 {
    var w: f32 = 0;
    var i: usize = 0;
    while (i < dag.n) : (i += 1) w += costs.cost[i];
    return w;
}

/// Critical-path length (span) `S` — the longest weighted path through the DAG.
/// Computed by a single reverse-index sweep (index order is reverse-topo for the
/// transpose), `down(op) = cost(op) + max over successors`. The span is the max
/// over all ops. This is the hard floor on makespan: no schedule beats
/// `max(S, W/P)`.
pub fn span(dag: *const Dag, costs: *const CostModel) f32 {
    var order: [max_ops]usize = undefined;
    const n = topoOrder(dag, &order);
    var down = [_]f32{0} ** max_ops;
    var s: f32 = 0;
    // Reverse topological order: a successor's `down` is final before its predecessor.
    var oi: usize = n;
    while (oi > 0) {
        oi -= 1;
        const ii = order[oi];
        var best: f32 = 0;
        var sc = dag.succs[ii];
        while (sc != 0) {
            const j = @ctz(sc);
            sc &= sc - 1;
            if (down[j] > best) best = down[j];
        }
        down[ii] = costs.cost[ii] + best;
        if (down[ii] > s) s = down[ii];
    }
    return s;
}

// ===========================================================================
// 5. Schedules — the level-barrier and the HEFT list schedule
// ===========================================================================

/// A committed schedule: the worker each op runs on, the per-worker ordered op
/// sequence, and (for the level-barrier) the ASAP level of each op. The HEFT path
/// uses `worker_of` + cross-worker predecessors (recovered from the DAG at run
/// time); the level path uses `level` + the barrier.
pub const Schedule = struct {
    p: usize = 1,
    n: usize = 0,
    /// Which worker runs each op.
    worker_of: [max_ops]usize = [_]usize{0} ** max_ops,
    /// Flat per-worker op order: `seq[seq_off[w] .. seq_off[w+1]]` are worker w's
    /// op indices, in execution order (start-time order — predecessors first).
    seq: [max_ops]usize = [_]usize{0} ** max_ops,
    seq_off: [max_workers + 1]usize = [_]usize{0} ** (max_workers + 1),
    /// ASAP level of each op (level-barrier path).
    level: [max_ops]usize = [_]usize{0} ** max_ops,
    max_level: usize = 0,
    /// The estimated makespan of this schedule — for the HEFT-beats-barrier test.
    makespan: f32 = 0,
    /// Each op's scheduled start/finish on its worker's timeline — the axis the
    /// concurrency-aware colorer reads (two values' buffers interfere iff their live
    /// intervals overlap here). For HEFT these are the real placed times; for the
    /// level barrier they bracket the op's level (`[level, level+1)`) so same-level
    /// ops always overlap (never share a buffer) and the barrier orders the rest.
    op_start: [max_ops]f32 = [_]f32{0} ** max_ops,
    op_finish: [max_ops]f32 = [_]f32{0} ** max_ops,
    /// Op indices in global schedule order (ascending start time, ties by index) —
    /// the order in which a reused buffer's value-sequence advances, so the DAG
    /// rebuilt after a concurrency-aware recolor must walk this order.
    global_order: [max_ops]usize = [_]usize{0} ** max_ops,

    pub fn workerOps(self: *const Schedule, w: usize) []const usize {
        return self.seq[self.seq_off[w]..self.seq_off[w + 1]];
    }
};

/// Fill `global_order` by sorting op indices by ascending scheduled start (ties by
/// op index). The order a reused buffer's occupants advance in.
fn fillGlobalOrder(s: *Schedule) void {
    var i: usize = 0;
    while (i < s.n) : (i += 1) s.global_order[i] = i;
    var a: usize = 0;
    while (a < s.n) : (a += 1) {
        var best = a;
        var b: usize = a + 1;
        while (b < s.n) : (b += 1) {
            const ib = s.global_order[b];
            const ibest = s.global_order[best];
            if (s.op_start[ib] < s.op_start[ibest] or (s.op_start[ib] == s.op_start[ibest] and ib < ibest)) best = b;
        }
        const tmp = s.global_order[a];
        s.global_order[a] = s.global_order[best];
        s.global_order[best] = tmp;
    }
}

/// The ASAP level of each op: `level(op) = 0` for a root, else `1 + max pred
/// level`. Two ops at the same level have no path between them, so they are
/// independent and safe to run concurrently with no inter-op sync — the property
/// the level-barrier relies on.
fn computeLevels(dag: *const Dag, out: *Schedule) void {
    var order: [max_ops]usize = undefined;
    const n = topoOrder(dag, &order);
    var max_l: usize = 0;
    var oi: usize = 0;
    while (oi < n) : (oi += 1) {
        const i = order[oi];
        var lvl: usize = 0;
        var pr = dag.preds[i];
        while (pr != 0) {
            const p = @ctz(pr);
            pr &= pr - 1;
            if (out.level[p] + 1 > lvl) lvl = out.level[p] + 1;
        }
        out.level[i] = lvl;
        if (lvl > max_l) max_l = lvl;
    }
    out.max_level = max_l;
}

/// Build a level-barrier schedule: ASAP levels, ops within a level round-robined
/// across workers by index (a cheap, deterministic balance). Deadlock-free by
/// construction — the only synchronisation is the barrier between levels, and
/// same-level ops are independent.
pub fn levelSchedule(dag: *const Dag, costs: *const CostModel, p_req: usize) Schedule {
    var s: Schedule = .{ .p = @max(p_req, 1), .n = dag.n };
    computeLevels(dag, &s);

    // Assign worker per op: round-robin within each level (independent ops), so the
    // assignment is balanced and deterministic.
    var per_level_counter = [_]usize{0} ** max_ops; // indexed by level
    var i: usize = 0;
    while (i < dag.n) : (i += 1) {
        const lvl = s.level[i];
        s.worker_of[i] = per_level_counter[lvl] % s.p;
        per_level_counter[lvl] += 1;
    }
    buildSeqByLevel(&s);
    s.makespan = estimateLevelMakespan(dag, costs, &s);
    // Schedule-time interval per op = its level bracket. Same-level ops share the
    // bracket [L, L+1) so they always overlap (never coalesced); a barrier between
    // levels orders the rest, so a buffer live only in level L may share storage with
    // one live only in level M ≠ L.
    var li: usize = 0;
    while (li < dag.n) : (li += 1) {
        s.op_start[li] = @floatFromInt(s.level[li]);
        s.op_finish[li] = @floatFromInt(s.level[li] + 1);
    }
    fillGlobalOrder(&s);
    return s;
}

/// Order each worker's ops by (level, op index): a worker runs all its level-0 ops,
/// then level-1, etc., matching the barrier phases. Within a level, index order.
fn buildSeqByLevel(s: *Schedule) void {
    var off: usize = 0;
    var w: usize = 0;
    while (w < s.p) : (w += 1) {
        s.seq_off[w] = off;
        var lvl: usize = 0;
        while (lvl <= s.max_level) : (lvl += 1) {
            var i: usize = 0;
            while (i < s.n) : (i += 1) {
                if (s.worker_of[i] == w and s.level[i] == lvl) {
                    s.seq[off] = i;
                    off += 1;
                }
            }
        }
    }
    s.seq_off[s.p] = off;
}

/// Estimate the level-barrier makespan: a barrier waits for the slowest worker per
/// level, so the makespan is `Σ_level max_worker (Σ ops on that worker at level)`.
fn estimateLevelMakespan(dag: *const Dag, costs: *const CostModel, s: *const Schedule) f32 {
    _ = dag;
    var total: f32 = 0;
    var lvl: usize = 0;
    while (lvl <= s.max_level) : (lvl += 1) {
        var per_worker = [_]f32{0} ** max_workers;
        var i: usize = 0;
        while (i < s.n) : (i += 1) {
            if (s.level[i] == lvl) per_worker[s.worker_of[i]] += costs.cost[i];
        }
        var mx: f32 = 0;
        var w: usize = 0;
        while (w < s.p) : (w += 1) if (per_worker[w] > mx) {
            mx = per_worker[w];
        };
        total += mx;
    }
    return total;
}

/// Build a HEFT list schedule: rank ops by upward rank (critical-path weight to the
/// sinks), then greedily place each — highest rank first — on the worker giving the
/// earliest finish time given its already-placed predecessors. Communication cost is
/// ~0 (workers share one pool, one address space), so the earliest finish is
/// `max(worker_available, max pred finish) + cost`. Because the schedule places whole
/// ops and honours every predecessor (including the colored-pool anti-dependencies),
/// it is bit-exact to the sequential replay; it fills the bubbles a level barrier
/// leaves between unequal levels.
pub fn heftSchedule(dag: *const Dag, costs: *const CostModel, p_req: usize) Schedule {
    var s: Schedule = .{ .p = @max(p_req, 1), .n = dag.n };
    computeLevels(dag, &s); // levels recorded too (telemetry / fallback parity)

    // Upward rank: down(op) = cost(op) + max successor down. Reverse topo sweep.
    var torder: [max_ops]usize = undefined;
    const tn = topoOrder(dag, &torder);
    var rank = [_]f32{0} ** max_ops;
    var ri: usize = tn;
    while (ri > 0) {
        ri -= 1;
        const ii = torder[ri];
        var best: f32 = 0;
        var sc = dag.succs[ii];
        while (sc != 0) {
            const j = @ctz(sc);
            sc &= sc - 1;
            if (rank[j] > best) best = rank[j];
        }
        rank[ii] = costs.cost[ii] + best;
    }

    // Placement order: descending upward rank, ties broken by ascending op index
    // (determinism). Selection sort over a small (≤64) set.
    var order = [_]usize{0} ** max_ops;
    var placed = [_]bool{false} ** max_ops;
    var oi: usize = 0;
    while (oi < dag.n) : (oi += 1) {
        var best_idx: usize = max_ops;
        var best_rank: f32 = -1;
        var c: usize = 0;
        while (c < dag.n) : (c += 1) {
            if (placed[c]) continue;
            if (rank[c] > best_rank or (rank[c] == best_rank and (best_idx == max_ops or c < best_idx))) {
                best_rank = rank[c];
                best_idx = c;
            }
        }
        order[oi] = best_idx;
        placed[best_idx] = true;
    }

    // Greedy earliest-finish placement.
    var worker_avail = [_]f32{0} ** max_workers;
    var finish = [_]f32{0} ** max_ops;
    var start = [_]f32{0} ** max_ops;
    oi = 0;
    while (oi < dag.n) : (oi += 1) {
        const op = order[oi];
        // Earliest time all predecessors are done.
        var ready_t: f32 = 0;
        var pr = dag.preds[op];
        while (pr != 0) {
            const pp = @ctz(pr);
            pr &= pr - 1;
            if (finish[pp] > ready_t) ready_t = finish[pp];
        }
        // Pick the worker with the earliest finish (lowest index breaks ties).
        var best_w: usize = 0;
        var best_finish: f32 = std.math.floatMax(f32);
        var best_start: f32 = 0;
        var w: usize = 0;
        while (w < s.p) : (w += 1) {
            const st = @max(worker_avail[w], ready_t);
            const fin = st + costs.cost[op];
            if (fin < best_finish) {
                best_finish = fin;
                best_w = w;
                best_start = st;
            }
        }
        s.worker_of[op] = best_w;
        worker_avail[best_w] = best_finish;
        finish[op] = best_finish;
        start[op] = best_start;
        s.op_start[op] = best_start;
        s.op_finish[op] = best_finish;
    }

    // Per-worker sequence ordered by start time (ties by op index) — a subsequence
    // of the global start-time order, itself a valid topological order, so a worker
    // never reaches an op before any predecessor's start time has passed.
    buildSeqByStart(&s, &start);

    // Makespan = max worker availability.
    var mk: f32 = 0;
    var w: usize = 0;
    while (w < s.p) : (w += 1) if (worker_avail[w] > mk) {
        mk = worker_avail[w];
    };
    s.makespan = mk;
    fillGlobalOrder(&s);
    return s;
}

/// Order each worker's ops by ascending start time, ties broken by op index. A
/// stable selection over the worker's op set (≤64).
fn buildSeqByStart(s: *Schedule, start: *const [max_ops]f32) void {
    var off: usize = 0;
    var w: usize = 0;
    while (w < s.p) : (w += 1) {
        s.seq_off[w] = off;
        // Collect this worker's ops, then selection-sort by (start, index).
        const begin = off;
        var i: usize = 0;
        while (i < s.n) : (i += 1) {
            if (s.worker_of[i] == w) {
                s.seq[off] = i;
                off += 1;
            }
        }
        // Selection sort the slice [begin, off).
        var a = begin;
        while (a < off) : (a += 1) {
            var best = a;
            var b = a + 1;
            while (b < off) : (b += 1) {
                const ib = s.seq[b];
                const ibest = s.seq[best];
                if (start[ib] < start[ibest] or (start[ib] == start[ibest] and ib < ibest)) best = b;
            }
            const tmp = s.seq[a];
            s.seq[a] = s.seq[best];
            s.seq[best] = tmp;
        }
    }
    s.seq_off[s.p] = off;
}

// ===========================================================================
// 5b. Concurrency-aware coloring — the colorer refinement (A15/A16)
// ===========================================================================

/// Recolor a non-coalesced (per-edge) plan IN PLACE so scratch buffers are reused
/// across values whose live ranges do NOT overlap in the static schedule. Under a
/// fixed schedule, two values' buffers interfere iff their producing/consuming ops'
/// execution intervals overlap — an interval graph on the schedule-time axis — so
/// left-edge coloring is optimal. This shrinks `M_class` from the total edge count
/// (per-edge) to the **peak concurrent** live-edge count while preserving the
/// schedule's parallelism: two values get one buffer only when one's last reader
/// already finishes before the other's producer starts, so coalescing them adds no
/// constraint the schedule did not already have. (Rebuilding the op-DAG from the
/// recolored plan then materialises those reuse anti-dependencies as the
/// cross-worker ready-flags / barrier ordering — see the engine's two-pass build.)
///
/// Persistent feedback (z⁻¹) buffers — those living past `pool_bytes`, which survive
/// the callback boundary — are NEVER recolored; they are rebased to sit just past
/// the (now smaller) scratch region. Coloring is within same-byte-size classes only.
pub fn concurrencyColor(plan: anytype, sched: *const Schedule) void {
    const NB = graph.max_buffers;
    const none = std.math.maxInt(usize);
    const inf = std.math.floatMax(f32);

    var used = [_]bool{false} ** NB;
    var persistent = [_]bool{false} ** NB;
    var lo = [_]f32{inf} ** NB;
    var hi = [_]f32{-inf} ** NB;
    var size = [_]usize{0} ** NB;

    // Gather each buffer's live interval on the schedule-time axis and whether it is
    // a persistent feedback buffer (offset at/after the scratch region).
    var i: usize = 0;
    while (i < plan.op_count) : (i += 1) {
        const op = &plan.ops[i];
        const st = sched.op_start[op_pos(sched, i)];
        const fi = sched.op_finish[op_pos(sched, i)];
        touch(op.output_buffer_ids[0..op.output_count], plan, &used, &persistent, &lo, &hi, &size, st, fi);
        touch(op.input_buffer_ids[0..op.input_count], plan, &used, &persistent, &lo, &hi, &size, st, fi);
        touch(op.param_input_buffer_ids[0..op.param_input_count], plan, &used, &persistent, &lo, &hi, &size, st, fi);
    }

    // Collect the POOL (scratch) buffer ids and sort by live-interval start.
    var pool_ids: [NB]usize = undefined;
    var n_pool: usize = 0;
    var b: usize = 0;
    while (b < NB) : (b += 1) {
        if (used[b] and !persistent[b]) {
            pool_ids[n_pool] = b;
            n_pool += 1;
        }
    }
    sortByLo(pool_ids[0..n_pool], &lo);

    // Left-edge interval coloring within byte-size classes.
    var new_id = [_]usize{none} ** NB;
    var color_hi: [NB]f32 = undefined;
    var color_size: [NB]usize = undefined;
    var n_color: usize = 0;
    for (pool_ids[0..n_pool]) |id| {
        var chosen: usize = none;
        var c: usize = 0;
        while (c < n_color) : (c += 1) {
            if (color_size[c] == size[id] and color_hi[c] <= lo[id] + 1e-4) {
                chosen = c;
                break;
            }
        }
        if (chosen == none) {
            chosen = n_color;
            color_size[n_color] = size[id];
            n_color += 1;
        }
        color_hi[chosen] = hi[id];
        new_id[id] = chosen;
    }

    // Lay the colors out compactly; that is the new scratch region size.
    var color_off: [NB]usize = undefined;
    var off: usize = 0;
    var c2: usize = 0;
    while (c2 < n_color) : (c2 += 1) {
        color_off[c2] = off;
        off += color_size[c2];
    }
    const new_pool_bytes = off;

    // Persistent buffers keep their relative layout, rebased just past the new
    // scratch; they get fresh ids appended after the colors.
    var next_id: usize = n_color;
    b = 0;
    while (b < NB) : (b += 1) {
        if (used[b] and persistent[b]) {
            new_id[b] = next_id;
            next_id += 1;
        }
    }

    // Remap every op's buffer ids and rebuild the per-id offset/length tables.
    var new_offset = [_]usize{0} ** NB;
    var new_len = [_]usize{0} ** NB;
    var new_last = [_]isize{-1} ** NB;
    // Colors: compact offsets, never poisoned mid-render (last_use past the end).
    c2 = 0;
    while (c2 < n_color) : (c2 += 1) {
        new_offset[c2] = color_off[c2];
        new_len[c2] = color_size[c2];
        new_last[c2] = @intCast(plan.op_count);
    }
    b = 0;
    while (b < NB) : (b += 1) {
        if (used[b] and persistent[b]) {
            const nid = new_id[b];
            new_offset[nid] = new_pool_bytes + (plan.buffer_offset[b] - plan.pool_bytes);
            new_len[nid] = plan.buffer_byte_len[b];
            new_last[nid] = -1; // persistent: never poisoned
        }
    }
    i = 0;
    while (i < plan.op_count) : (i += 1) {
        const op = &plan.ops[i];
        remapIds(op.output_buffer_ids[0..op.output_count], &new_id);
        remapIds(op.input_buffer_ids[0..op.input_count], &new_id);
        remapIds(op.param_input_buffer_ids[0..op.param_input_count], &new_id);
    }
    plan.buffer_offset = new_offset;
    plan.buffer_byte_len = new_len;
    plan.buffer_last_use = new_last;
    plan.pool_bytes = new_pool_bytes;
    plan.pool_buffer_count = next_id;
}

fn op_pos(sched: *const Schedule, op_index: usize) usize {
    _ = sched;
    return op_index; // op_start/op_finish are indexed by op index
}

fn touch(ids: []const usize, plan: anytype, used: []bool, persistent: []bool, lo: []f32, hi: []f32, size: []usize, st: f32, fi: f32) void {
    for (ids) |id| {
        if (id >= graph.max_buffers) continue;
        used[id] = true;
        size[id] = plan.buffer_byte_len[id];
        if (plan.buffer_offset[id] >= plan.pool_bytes) persistent[id] = true;
        if (st < lo[id]) lo[id] = st;
        if (fi > hi[id]) hi[id] = fi;
    }
}

fn sortByLo(ids: []usize, lo: []const f32) void {
    var a: usize = 0;
    while (a < ids.len) : (a += 1) {
        var best = a;
        var b: usize = a + 1;
        while (b < ids.len) : (b += 1) {
            if (lo[ids[b]] < lo[ids[best]] or (lo[ids[b]] == lo[ids[best]] and ids[b] < ids[best])) best = b;
        }
        const tmp = ids[a];
        ids[a] = ids[best];
        ids[best] = tmp;
    }
}

fn remapIds(ids: []usize, new_id: []const usize) void {
    for (ids) |*id| {
        if (id.* < graph.max_buffers and new_id[id.*] != std.math.maxInt(usize)) id.* = new_id[id.*];
    }
}

// ===========================================================================
// 5c. Paranoid NaN-poison plan — the extra safety net for the parallel colorer
// ===========================================================================

/// The per-op output-port reader counts a paranoid Tier-B render uses to NaN-poison
/// a scratch buffer the instant its CURRENT value's last reader FINISHES — so a
/// colorer/scheduling bug that reads a buffer past its last legitimate reader (or a
/// cross-worker buffer reused before its last reader) surfaces as a loud NaN at the
/// sink instead of silently-stale audio. `out_reader_count[op][port]` is how many ops
/// read the value op produces on that output port before the buffer's NEXT writer.
///
/// Why a per-buffer reader-completion COUNTER and not "poison after the last reader":
/// under a static parallel schedule, concurrent readers of one buffer have no mutual
/// finish-order, so poisoning after the schedule-last reader could fire while a peer
/// reader is still reading (a false NaN). The runtime instead has the producer store
/// the reader count, each reader atomically decrement after reading, and the reader
/// that brings the count to zero (the last to FINISH) poison — race-free for any
/// interleaving. Persistent feedback buffers are never tracked or poisoned (they
/// carry state across the callback).
pub const PoisonPlan = struct {
    out_reader_count: [max_ops][port.max_ports_per_direction]u32 =
        [_][port.max_ports_per_direction]u32{[_]u32{0} ** port.max_ports_per_direction} ** max_ops,
    n: usize = 0,
};

/// Compute the poison plan from a recolored plan + its final schedule: walk the ops
/// in schedule order, counting the readers of each buffer's current value, and
/// attribute that count to the value's writer op + output port. Off-RT.
pub fn computePoison(plan: anytype, sched: *const Schedule) PoisonPlan {
    var pp: PoisonPlan = .{ .n = plan.op_count };
    const none = std.math.maxInt(usize);
    // Per buffer: the op + output-port index of its current writer, and the reader
    // count accumulated since that write.
    var writer_op = [_]usize{none} ** graph.max_buffers;
    var writer_port = [_]usize{0} ** graph.max_buffers;
    var count = [_]u32{0} ** graph.max_buffers;

    for (sched.global_order[0..plan.op_count]) |i| {
        const op = &plan.ops[i];
        // Reads (sample then param) bump the current value's reader count.
        var k: usize = 0;
        while (k < op.input_count) : (k += 1) {
            const b = op.input_buffer_ids[k];
            if (b < graph.max_buffers and writer_op[b] != none) count[b] += 1;
        }
        k = 0;
        while (k < op.param_input_count) : (k += 1) {
            const b = op.param_input_buffer_ids[k];
            if (b < graph.max_buffers and writer_op[b] != none) count[b] += 1;
        }
        // Writes finalize the previous value's reader count (attributed to its writer)
        // and open a new value with a fresh count.
        k = 0;
        while (k < op.output_count) : (k += 1) {
            const b = op.output_buffer_ids[k];
            if (b >= graph.max_buffers) continue;
            if (writer_op[b] != none) pp.out_reader_count[writer_op[b]][writer_port[b]] = count[b];
            writer_op[b] = i;
            writer_port[b] = k;
            count[b] = 0;
        }
    }
    // Finalize every still-open value (its writer's last segment this callback).
    var b: usize = 0;
    while (b < graph.max_buffers) : (b += 1) {
        if (writer_op[b] != none) pp.out_reader_count[writer_op[b]][writer_port[b]] = count[b];
    }
    return pp;
}

// ===========================================================================
// 6. Point-to-point ready flags — the cross-worker handshake
// ===========================================================================

/// One release/acquire flag per producing op, keyed by the per-callback generation.
/// The producer publishes (RF-W): a release store of `g` orders its pool-buffer
/// writes before any acquirer that reads `g`. The consumer waits (RF-R): an acquire
/// spin until the flag reads `g`, so its plain reads of the producer's output buffer
/// are not a race. Each flag has exactly one writer per callback (the worker that
/// owns that op), so a plain store suffices — no CAS anywhere. The generation
/// disambiguates callbacks without clearing the array: a flag still holding `g−1`
/// reads as "not ready," so there is no per-callback memset.
/// Spin count after which a cross-worker wait YIELDS instead of pure-spinning. Without a
/// real render workgroup co-scheduling the workers, a producer can be descheduled — e.g.
/// under core oversubscription (several Tier-B graphs running at once) — and an unbounded
/// spin would livelock the core, never letting the producer finish. Yielding past the
/// threshold lets it run. Under a real workgroup the producer is co-scheduled and a
/// cross-worker wait resolves in a few hundred spins, far below this, so the steady-state
/// path stays a pure spin. ~16k spins ≈ tens of microseconds — well inside a callback.
const spin_yield_threshold: u32 = 1 << 14;

/// One iteration of a bounded spin: a spin-loop hint until `local` crosses the threshold,
/// then a yield (so a descheduled peer can run) and reset. The slow (yield) branch is
/// reached only when no workgroup bounds the wait.
fn spinOrYield(local: *u32) void {
    local.* += 1;
    if (local.* < spin_yield_threshold) {
        std.atomic.spinLoopHint();
    } else {
        std.Thread.yield() catch std.atomic.spinLoopHint();
        local.* = 0;
    }
}

pub const ReadyFlags = struct {
    flags: [max_ops]std.atomic.Value(usize) = blk: {
        var a: [max_ops]std.atomic.Value(usize) = undefined;
        for (&a) |*f| f.* = std.atomic.Value(usize).init(0);
        break :blk a;
    },

    /// RF-W — publish op `p`'s completion at generation `g` (release).
    pub fn publish(self: *ReadyFlags, p: usize, g: usize) void {
        self.flags[p].store(g, .release);
    }

    /// RF-R — wait until op `p` has published generation `g` (acquire spin). The
    /// spin count is accumulated into `spins` (the per-worker spin-time witness; a
    /// budget breach is what trips auto-demote). Bounded only while the workgroup
    /// co-schedules the producer; that bound is ▷/≈, not ⊢.
    pub fn wait(self: *ReadyFlags, p: usize, g: usize, spins: *u64) void {
        var local: u32 = 0;
        while (self.flags[p].load(.acquire) != g) {
            spins.* += 1;
            spinOrYield(&local);
        }
    }
};

// ===========================================================================
// 7. The worker pool — generation-wake, token ×P, workgroup membership
// ===========================================================================

/// The render-worker task: run worker `wid`'s share of the dispatch at generation
/// `g`. The pool passes a type-erased user pointer the task casts back.
pub const WorkerFn = *const fn (user: *anyopaque, wid: usize, g: usize) void;

// Private OS futex/ulock surface for the cold-worker park (the steady-state RT path
// never parks — workers spin between the ~2.7 ms callbacks — so these are off the
// hot path; they only stop an idle/stopped engine's workers burning a core).
extern "c" fn __ulock_wait(operation: u32, addr: ?*anyopaque, value: u64, timeout_us: u32) c_int;
extern "c" fn __ulock_wake(operation: u32, addr: ?*anyopaque, wake_value: u64) c_int;

/// A futex word the cold workers block on and a dispatch/teardown wakes. `wait`
/// blocks while the word equals the captured value; `wake` bumps the word and wakes
/// all waiters. Linux uses the v1 futex syscall; Darwin uses `__ulock`; other targets
/// fall back to a yield (a busy idle, but those targets are not the RT deployment).
const ParkWord = struct {
    word: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    fn wait(self: *ParkWord, expect: u32) void {
        switch (builtin.os.tag) {
            .linux => {
                _ = std.os.linux.futex_4arg(&self.word.raw, .{ .cmd = .WAIT, .private = true }, expect, null);
            },
            .macos, .ios, .tvos, .watchos => {
                const UL_COMPARE_AND_WAIT: u32 = 1;
                _ = __ulock_wait(UL_COMPARE_AND_WAIT, @ptrCast(&self.word.raw), expect, 0);
            },
            else => std.Thread.yield() catch {},
        }
    }

    fn wake(self: *ParkWord) void {
        _ = self.word.fetchAdd(1, .release);
        switch (builtin.os.tag) {
            .linux => {
                _ = std.os.linux.futex_3arg(&self.word.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
            },
            .macos, .ios, .tvos, .watchos => {
                const UL_COMPARE_AND_WAIT: u32 = 1;
                const ULF_WAKE_ALL: u32 = 0x00000100;
                _ = __ulock_wake(UL_COMPARE_AND_WAIT | ULF_WAKE_ALL, @ptrCast(&self.word.raw), 0);
            },
            else => {},
        }
    }
};

/// A pre-spawned pool of `P` render workers. Worker 0 is the *calling* thread (the
/// audio callback thread participates, so all P cores render and there is no
/// oversubscription); workers 1..P-1 are spawned once at init (spawning is a
/// syscall — never per callback). Between dispatches the spawned workers bounded-
/// spin on a generation counter, then yield if idle beyond a threshold; the caller
/// only bumps the generation (a single release store) to wake them, so there is no
/// RT syscall on the steady-state path.
pub const WorkerPool = struct {
    alloc: std.mem.Allocator,
    p: usize,
    workgroup: Workgroup,
    threads: []std.Thread = &.{},
    /// The work generation. Bumped by `dispatch`; the spawned workers wake when it
    /// changes. Also the ready-flag generation `g`.
    gen: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    /// Count of spawned workers that finished the current dispatch. The caller waits
    /// for `p − 1`.
    done: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    /// Set to wake the workers into teardown.
    shutdown: std.atomic.Value(bool) = .init(false),
    /// The dispatch payload, published by the generation bump.
    user: ?*anyopaque = null,
    task: ?WorkerFn = null,
    /// Whether the worker threads are spawned and running (so `deinit` knows whether
    /// the handle slice holds live, joinable threads or merely reserved storage). A
    /// pool that is allocated but never promoted (the gate refused) frees its slice
    /// without joining uninitialised handles.
    live: bool = false,
    /// Bounded-spin budget before a cold worker parks (futex) between dispatches.
    /// In steady state (callbacks every ~2.7 ms) workers stay in the spin phase, so
    /// the park is reached only when the engine is idle/stopped.
    spin_threshold: u32 = 8192,
    /// The cold-worker park word + the count of currently-parked workers, so dispatch
    /// only issues a wake syscall when a worker might actually be parked (no RT-path
    /// syscall in steady state, where `parked == 0`).
    park: ParkWord = .{},
    parked: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    /// Spawn `P − 1` worker threads. `P == 1` spawns none (the caller is the lone
    /// worker — a Tier-A-shaped degenerate Tier B). Each worker enters realtime mode
    /// (FTZ is per-thread on ARM64 — it must be set on *every* worker, not just the
    /// callback thread) and joins the workgroup before its first render.
    pub fn init(alloc: std.mem.Allocator, p_req: usize, workgroup: Workgroup) !WorkerPool {
        const p = @max(p_req, 1);
        var pool = WorkerPool{ .alloc = alloc, .p = p, .workgroup = workgroup };
        if (p == 1) return pool;
        const threads = try alloc.alloc(std.Thread, p - 1);
        errdefer alloc.free(threads);
        // The pool must live at a stable address while workers reference it; the
        // caller stores it (the engine owns it by value). We spawn with a pointer to
        // the heap-stable WorkerPool the caller will hold — so init returns the pool
        // by value and the caller must call `spawn` once it is at its final address.
        pool.threads = threads;
        return pool;
    }

    /// Spawn the worker threads against the pool's final (stable) address. Split from
    /// `init` because the workers capture `self` and the pool is moved into its owner
    /// after `init` returns; call this once the pool sits at its lasting location.
    pub fn spawn(self: *WorkerPool) !void {
        if (self.p == 1) return;
        var i: usize = 0;
        errdefer {
            // Unwind any already-spawned workers on a mid-spawn failure.
            self.shutdown.store(true, .release);
            _ = self.gen.fetchAdd(1, .release);
            var j: usize = 0;
            while (j < i) : (j += 1) self.threads[j].join();
        }
        while (i < self.p - 1) : (i += 1) {
            self.threads[i] = try std.Thread.spawn(.{}, workerLoop, .{ self, i + 1 });
        }
        self.live = true;
    }

    /// The spawned-worker run loop. Waits for the generation to advance (bounded
    /// spin then yield), runs the published task for its worker id, signals done,
    /// repeats; exits when shutdown is observed.
    fn workerLoop(self: *WorkerPool, wid: usize) void {
        const tok = engine.enterRealtimeThread();
        defer tok.leave();
        var wg_token: Workgroup.Token = .{};
        self.workgroup.joinThread(&wg_token, wid, tok);
        defer self.workgroup.leaveThread(&wg_token);

        var last: usize = 0;
        while (true) {
            var spins: u32 = 0;
            while (true) {
                const g = self.gen.load(.acquire);
                if (g != last) break;
                if (self.shutdown.load(.acquire)) return;
                spins += 1;
                if (spins < self.spin_threshold) {
                    std.atomic.spinLoopHint();
                } else {
                    // Cold: park on the futex until a dispatch/teardown wakes us.
                    // Capture the park word BEFORE the final gen check so a wake that
                    // races the park returns immediately (no lost wakeup).
                    const w = self.park.word.load(.acquire);
                    _ = self.parked.fetchAdd(1, .acq_rel);
                    if (self.gen.load(.acquire) == last and !self.shutdown.load(.acquire)) {
                        self.park.wait(w);
                    }
                    _ = self.parked.fetchSub(1, .acq_rel);
                    spins = 0;
                }
            }
            if (self.shutdown.load(.acquire)) return;
            const g = self.gen.load(.acquire);
            last = g;
            if (self.task) |t| t(self.user.?, wid, g);
            _ = self.done.fetchAdd(1, .release);
        }
    }

    /// Wake any parked workers — but only issue the syscall if one is actually parked
    /// (steady state has none, so no wake syscall on the RT path).
    fn wakeWorkers(self: *WorkerPool) void {
        if (self.parked.load(.acquire) > 0) self.park.wake();
    }

    /// Run one dispatch: publish the task, bump the generation to wake the workers,
    /// run worker 0 inline on the caller, then spin-wait for the spawned workers to
    /// finish. Returns the generation used (the ready-flag `g`). Wait-free on the
    /// caller except the bounded join spin (bounded by the slowest worker's share,
    /// inside the WCET budget under co-scheduling).
    pub fn dispatch(self: *WorkerPool, user: *anyopaque, task: WorkerFn) usize {
        if (self.p == 1) {
            const g = self.gen.load(.monotonic) + 1;
            self.gen.store(g, .monotonic);
            task(user, 0, g);
            return g;
        }
        self.user = user;
        self.task = task;
        self.done.store(0, .release);
        const g = self.gen.load(.monotonic) + 1;
        self.gen.store(g, .release); // publish user/task/done-reset and wake spinners
        self.wakeWorkers(); // and unpark any cold workers (no syscall if none parked)
        task(user, 0, g); // worker 0 = the caller
        var jspin: u32 = 0;
        while (self.done.load(.acquire) != self.p - 1) spinOrYield(&jspin);
        return g;
    }

    pub fn deinit(self: *WorkerPool) void {
        if (self.p > 1) {
            if (self.live) {
                self.shutdown.store(true, .release);
                _ = self.gen.fetchAdd(1, .release); // wake spinning workers into teardown
                self.park.wake(); // and unpark any cold/parked workers
                for (self.threads) |t| t.join();
                self.live = false;
            }
            self.alloc.free(self.threads);
        }
    }
};

// ===========================================================================
// 8. An atomic-countdown barrier (the level-barrier sync)
// ===========================================================================

/// A reusable generation-based barrier for `P` participants. The last arrival
/// resets the count and bumps the barrier generation (release), waking the spinners
/// (acquire). No per-thread local state, so it is safe to reuse across levels and
/// across dispatches.
pub const Barrier = struct {
    arrived: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    gen: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    p: usize = 1,

    pub fn wait(self: *Barrier) void {
        if (self.p <= 1) return;
        const g = self.gen.load(.acquire);
        if (self.arrived.fetchAdd(1, .acq_rel) + 1 == self.p) {
            self.arrived.store(0, .monotonic);
            _ = self.gen.fetchAdd(1, .release);
        } else {
            var bspin: u32 = 0;
            while (self.gen.load(.acquire) == g) spinOrYield(&bspin);
        }
    }
};

// ===========================================================================
// 9. The parallel replay — engine-decoupled
// ===========================================================================

/// The per-op kernel runner the engine supplies: run op `op_index` of the plan over
/// the shared pool. Type-erased so this module stays free of engine internals — the
/// engine closes over (plan, pool, per-op counts, events, guards, fault).
pub const RunOp = *const fn (op_index: usize, user: *anyopaque) void;

/// Per-worker spin-time witnesses, indexed by worker id. The engine reads the max
/// across workers into its `spin_time` telemetry; a budget breach trips auto-demote.
pub const SpinTelemetry = struct {
    spins: [max_workers]u64 = [_]u64{0} ** max_workers,

    pub fn reset(self: *SpinTelemetry) void {
        self.spins = [_]u64{0} ** max_workers;
    }
    pub fn maxSpins(self: *const SpinTelemetry, p: usize) u64 {
        var m: u64 = 0;
        var w: usize = 0;
        while (w < p) : (w += 1) if (self.spins[w] > m) {
            m = self.spins[w];
        };
        return m;
    }
};

/// Which Tier B executor a replay uses.
pub const Executor = enum { level_barrier, heft };

/// The dispatch context the worker task casts back to. Holds the schedule, the
/// per-op runner, the cross-worker sync, and the spin telemetry. Constructed fresh
/// each callback on the caller's stack; the workers read it through the pool's
/// type-erased user pointer (published by the generation bump).
pub const ReplayCtx = struct {
    exec: Executor,
    sched: *const Schedule,
    dag: *const Dag,
    ready: *ReadyFlags,
    barrier: *Barrier,
    run_op: RunOp,
    run_user: *anyopaque,
    tele: *SpinTelemetry,
    /// When set, run the paranoid post-op (update the per-buffer reader-completion
    /// counters and NaN-poison any scratch buffer whose current value just lost its
    /// last reader). The engine supplies it; null ⇒ no poison (release builds).
    post_op: ?RunOp = null,
};

/// The worker task: run worker `wid`'s op sequence at generation `g`.
///   * level_barrier: run the worker's ops level by level, a barrier between
///     levels. No ready flags — same-level ops are independent, and the barrier
///     orders cross-level dependencies.
///   * heft: run the worker's ops in start-time order; before each, spin on every
///     cross-worker predecessor's ready flag; after each, publish the op's flag.
fn replayWorker(user: *anyopaque, wid: usize, g: usize) void {
    const ctx: *ReplayCtx = @ptrCast(@alignCast(user));
    // The pool may have more spawned workers than the schedule uses (the worker
    // count is the cost-gate's chosen P ≤ the core budget). A worker beyond the
    // schedule's width has no ops and does NOT participate in the (P-sized) barrier
    // — it simply returns (still counted toward the pool's done tally).
    if (wid >= ctx.sched.p) return;
    const ops = ctx.sched.workerOps(wid);
    switch (ctx.exec) {
        .level_barrier => {
            var lvl: usize = 0;
            while (lvl <= ctx.sched.max_level) : (lvl += 1) {
                for (ops) |op| {
                    if (ctx.sched.level[op] == lvl) {
                        ctx.run_op(op, ctx.run_user);
                        if (ctx.post_op) |po| po(op, ctx.run_user);
                    }
                }
                ctx.barrier.wait();
            }
        },
        .heft => {
            const spins = &ctx.tele.spins[wid];
            for (ops) |op| {
                // Wait on cross-worker predecessors (same-worker preds already ran,
                // earlier in this worker's start-time-ordered sequence).
                var pr = ctx.dag.preds[op];
                while (pr != 0) {
                    const p = @ctz(pr);
                    pr &= pr - 1;
                    if (ctx.sched.worker_of[p] != wid) ctx.ready.wait(p, g, spins);
                }
                ctx.run_op(op, ctx.run_user);
                // Paranoid poison runs BEFORE the publish, so the release store of the
                // ready flag orders the counter updates / poison fill ahead of any
                // consumer or reuse-writer that acquires this op.
                if (ctx.post_op) |po| po(op, ctx.run_user);
                ctx.ready.publish(op, g);
            }
        },
    }
}

/// Replay a plan in parallel over `pool` per `sched`, using `run_op` to run each op.
/// Bit-identical to the sequential replay of the same plan (same buffers, kernels,
/// reduction order). Returns the generation used.
pub fn replayParallel(
    pool: *WorkerPool,
    exec: Executor,
    sched: *const Schedule,
    dag: *const Dag,
    ready: *ReadyFlags,
    barrier: *Barrier,
    run_op: RunOp,
    run_user: *anyopaque,
    tele: *SpinTelemetry,
    post_op: ?RunOp,
) usize {
    tele.reset();
    barrier.p = sched.p;
    var ctx = ReplayCtx{
        .exec = exec,
        .sched = sched,
        .dag = dag,
        .ready = ready,
        .barrier = barrier,
        .run_op = run_op,
        .run_user = run_user,
        .tele = tele,
        .post_op = post_op,
    };
    return pool.dispatch(&ctx, replayWorker);
}

// ===========================================================================
// 10. Auto-demote policy — telemetry-gated, hysteresis
// ===========================================================================

/// The Tier B ↔ Tier A switch policy. The engine feeds it per-callback deadline
/// headroom (and the spin witness); it demotes to Tier A after `demote_after`
/// consecutive callbacks below the headroom floor, and re-promotes only after
/// `promote_after` consecutive callbacks back above a (higher) ceiling — the
/// hysteresis that stops it oscillating. Because Tier A and Tier B run the same plan
/// over the same pool, the switch is a branch at the callback boundary, not a plan
/// swap, and it is click-free.
pub const DemotePolicy = struct {
    /// Headroom (fraction of deadline remaining) below which Tier B is failing.
    floor: f32 = 0.1,
    /// Headroom above which it is safe to re-promote (> floor — the hysteresis gap).
    ceiling: f32 = 0.3,
    demote_after: u32 = 4,
    promote_after: u32 = 64,

    /// Whether Tier B is currently active. Starts from the gate decision.
    active: bool = false,
    low_streak: u32 = 0,
    high_streak: u32 = 0,

    pub fn init(gate_enabled: bool) DemotePolicy {
        return .{ .active = gate_enabled };
    }

    /// Observe one callback's headroom; return whether Tier B should run the *next*
    /// callback. Pure state machine — off the hot path's critical work (a few
    /// comparisons at the boundary).
    pub fn observe(self: *DemotePolicy, headroom: f32) bool {
        if (self.active) {
            if (headroom < self.floor) {
                self.low_streak += 1;
                self.high_streak = 0;
                if (self.low_streak >= self.demote_after) {
                    self.active = false;
                    self.low_streak = 0;
                }
            } else {
                self.low_streak = 0;
            }
        } else {
            if (headroom >= self.ceiling) {
                self.high_streak += 1;
                if (self.high_streak >= self.promote_after) {
                    self.active = true;
                    self.high_streak = 0;
                }
            } else {
                self.high_streak = 0;
            }
        }
        return self.active;
    }
};

test {
    std.testing.refAllDecls(@This());
}
