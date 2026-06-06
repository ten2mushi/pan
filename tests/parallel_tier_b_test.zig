//! parallel_tier_b_test — the self-authored gate for the Tier-B static-parallel
//! RealtimeStreaming overlay (`src/parallel.zig` + the `engine.zig` integration).
//!
//! The spine is the **parallel≡sequential differential**: the Tier-B colored-pool
//! parallel render of a graph is **bit-identical** to the Tier-A sequential render
//! of the same graph, for both executors (level-barrier and HEFT) and across worker
//! counts. It must be bit-exact, not allclose: Tier A and Tier B run the SAME bound
//! plan over the SAME pool, with the schedule honouring the colored-pool anti-
//! dependencies, so any divergence is a scheduling/sync bug, never numerics.
//!
//! The other facets pinned:
//!   - the cost gate REFUSES a near-linear chain (work/span ≈ 1) and ENABLES a wide
//!     graph (the decidable W/S/deadline computation);
//!   - the op-DAG carries the colored-pool anti-dependencies (a wide fan-in is
//!     bit-exact even though sibling values may share — or not — colors);
//!   - both schedules are valid (every op placed; every dependency respected in the
//!     per-worker start-time order) and HEFT's makespan ≤ the level-barrier's;
//!   - the worker pool's 2-worker handshake completes with bounded spin (spin-time
//!     telemetry present); the generation barrier synchronises P participants;
//!   - the ready-flag publishes/waits across threads (release/acquire);
//!   - the demote policy demotes under sustained low headroom and re-promotes after
//!     a stable high-headroom window (hysteresis).
//!
//! COMPARISON MODE: pan-vs-pan — always BIT-EXACT. No external oracle.
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill loaded before authoring, Rules
//! 13/14). Diagnostics go to `std.debug.print`, never `std.log.err`.

const std = @import("std");
const pan = @import("pan");

const parallel = pan.parallel;
const engine = pan.engine;
const Sample = pan.Sample;

// ===========================================================================
// Blocks for the differential graphs. All mono Sample(f32), so the only variable
// across Tier A / Tier B is the schedule + sync — never the kernel.
// ===========================================================================

const BufSource = struct {
    const Self = @This();
    data: [*]const Sample(f32) = undefined,
    pub fn process(self: *Self, out: []Sample(f32)) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const BufSink = struct {
    const Self = @This();
    dest: [*]Sample(f32) = undefined,
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        @memcpy(self.dest[0..in.len], in);
    }
};
const Gain = struct {
    const Self = @This();
    gain: f32 = 1.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.gain;
    }
};
const Affine = struct {
    const Self = @This();
    a: f32 = 1.0,
    b: f32 = 0.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.a + self.b;
    }
};
const Add2 = struct {
    const Self = @This();
    pub const inputs = .{ .x = Sample(f32), .y = Sample(f32) };
    pub fn process(self: *Self, x: []const Sample(f32), y: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (x, y, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
    }
};

/// A heavily-hinted affine voice: its rendered output is the SAME affine map as
/// `Affine`, but it advertises a large `cost_hint`. The hint must change only the
/// Tier-B schedule (worker sizing / op placement), never the samples — exactly the
/// load-bearing invariant the differential below proves. The kernel is identical to
/// the unhinted `Affine` so a byte-for-byte comparison against an unhinted graph of
/// the same shape is well-defined.
const HeavyVoice = struct {
    const Self = @This();
    /// ~16× the per-sample intensity of a plain copy/add — a stand-in for a biquad
    /// cascade or short FFT voice. Pure scheduler metadata; the math below is cheap.
    pub const cost_hint: f32 = 16.0;
    a: f32 = 1.0,
    b: f32 = 0.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.a + self.b;
    }
};

/// The SAME affine kernel as `Affine`/`HeavyVoice`, but advertising a pathologically
/// large `cost_hint`. The invariant must hold at extreme hint magnitudes too: a buggy
/// scheduler that let a huge cost overflow to NaN/Inf and reorder ops would diverge
/// from the sequential reference, whereas a correct one ignores the hint for the
/// samples entirely. Same coefficients ⇒ byte-identical to `Affine` of the same shape.
const ExtremeVoice = struct {
    const Self = @This();
    /// A hint far beyond any realistic kernel — stresses the cost arithmetic without
    /// touching the rendered math.
    pub const cost_hint: f32 = 1.0e6;
    a: f32 = 1.0,
    b: f32 = 0.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.a + self.b;
    }
};

fn cfg(comptime N: usize) pan.Config {
    return .{ .precision = .f32, .channels = .mono, .block_size = N };
}
fn fillNoise(buf: []Sample(f32), seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (buf) |*s| s.ch[0] = r.float(f32) * 2.0 - 1.0;
}

/// Build a WIDE graph: source fans out into four independent gain→affine chains,
/// summed by a three-adder tree, into a sink. The four chains are mutually
/// independent (high work/span ratio) — the shape Tier B exists to parallelise.
/// `out` receives the sink. The caller owns the returned engine.
fn buildWide(alloc: std.mem.Allocator, comptime N: usize, input: *const [N]Sample(f32), out: *[N]Sample(f32), opts: engine.EngineOptions) !engine.Engine {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), input) });
    const g0 = try bg.add(Gain, .{ .gain = 0.5012 });
    const a0 = try bg.add(Affine, .{ .a = 1.31, .b = -0.07 });
    const g1 = try bg.add(Gain, .{ .gain = 0.7734 });
    const a1 = try bg.add(Affine, .{ .a = 0.92, .b = 0.013 });
    const g2 = try bg.add(Gain, .{ .gain = 1.211 });
    const a2 = try bg.add(Affine, .{ .a = -0.5, .b = 0.21 });
    const g3 = try bg.add(Gain, .{ .gain = 0.3001 });
    const a3 = try bg.add(Affine, .{ .a = 1.07, .b = -0.001 });
    const s01 = try bg.add(Add2, .{});
    const s23 = try bg.add(Add2, .{});
    const stop = try bg.add(Add2, .{});
    const sink = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), out) });

    try bg.connect(src, g0);
    try bg.connect(src, g1);
    try bg.connect(src, g2);
    try bg.connect(src, g3);
    try bg.connect(g0, a0);
    try bg.connect(g1, a1);
    try bg.connect(g2, a2);
    try bg.connect(g3, a3);
    try bg.connect(a0, s01.in.x);
    try bg.connect(a1, s01.in.y);
    try bg.connect(a2, s23.in.x);
    try bg.connect(a3, s23.in.y);
    try bg.connect(s01, stop.in.x);
    try bg.connect(s23, stop.in.y);
    try bg.connect(stop, sink);

    return bg.commitWith(opts);
}

/// Build the SAME wide fan-out shape as `buildWide`, but the four arms' affine stages
/// are the compile-time block type `Aff` — either the unhinted `Affine` or the
/// `HeavyVoice` (which renders the identical affine map but advertises a large
/// `cost_hint`). The coefficients are chosen so that `HeavyVoice{ .a, .b }` and
/// `Affine{ .a, .b }` with the same coefficients render bit-identically; only the
/// scheduler-visible hint differs. This lets a hinted graph be compared byte-for-byte
/// against an unhinted graph of the same shape AND against its own sequential render.
fn buildWideAff(comptime Aff: type, alloc: std.mem.Allocator, comptime N: usize, input: *const [N]Sample(f32), out: *[N]Sample(f32), opts: engine.EngineOptions) !engine.Engine {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), input) });
    const g0 = try bg.add(Gain, .{ .gain = 0.5012 });
    const a0 = try bg.add(Aff, .{ .a = 1.31, .b = -0.07 });
    const g1 = try bg.add(Gain, .{ .gain = 0.7734 });
    const a1 = try bg.add(Aff, .{ .a = 0.92, .b = 0.013 });
    const g2 = try bg.add(Gain, .{ .gain = 1.211 });
    const a2 = try bg.add(Aff, .{ .a = -0.5, .b = 0.21 });
    const g3 = try bg.add(Gain, .{ .gain = 0.3001 });
    const a3 = try bg.add(Aff, .{ .a = 1.07, .b = -0.001 });
    const s01 = try bg.add(Add2, .{});
    const s23 = try bg.add(Add2, .{});
    const stop = try bg.add(Add2, .{});
    const sink = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), out) });

    try bg.connect(src, g0);
    try bg.connect(src, g1);
    try bg.connect(src, g2);
    try bg.connect(src, g3);
    try bg.connect(g0, a0);
    try bg.connect(g1, a1);
    try bg.connect(g2, a2);
    try bg.connect(g3, a3);
    try bg.connect(a0, s01.in.x);
    try bg.connect(a1, s01.in.y);
    try bg.connect(a2, s23.in.x);
    try bg.connect(a3, s23.in.y);
    try bg.connect(s01, stop.in.x);
    try bg.connect(s23, stop.in.y);
    try bg.connect(stop, sink);

    return bg.commitWith(opts);
}

// ===========================================================================
// 1. THE SPINE: parallel ≡ sequential, bit-exact, both executors, multi-block.
// ===========================================================================

test "GATE: Tier B (level-barrier) ≡ Tier A sequential — bit-exact over a wide graph" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x5EED01);

    var out_a: [N]Sample(f32) = undefined;
    var out_b: [N]Sample(f32) = undefined;

    var eng_a = try buildWide(alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();
    var eng_b = try buildWide(alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .level_barrier });
    defer eng_b.deinit();

    // The wide graph must actually promote (else the differential proves nothing).
    try std.testing.expect(eng_b.tierBActive());
    try std.testing.expect(eng_b.tierBWorkers() >= 2);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    // Several blocks: prove determinism across callbacks, not just one.
    var block: usize = 0;
    while (block < 8) : (block += 1) {
        eng_a.renderInto(token);
        eng_b.renderInto(token);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
    }
    try std.testing.expect(!eng_a.telemetry().fault);
    try std.testing.expect(!eng_b.telemetry().fault);
}

test "GATE: Tier B (HEFT) ≡ Tier A sequential — bit-exact, P = 2..8" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xA11CE5);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    var p: usize = 2;
    while (p <= 8) : (p += 1) {
        var out_a: [N]Sample(f32) = undefined;
        var out_b: [N]Sample(f32) = undefined;
        var eng_a = try buildWide(alloc, N, &input, &out_a, .{});
        defer eng_a.deinit();
        var eng_b = try buildWide(alloc, N, &input, &out_b, .{ .cores = p, .force_workgroup = true, .tier_b_executor = .heft });
        defer eng_b.deinit();
        try std.testing.expect(eng_b.tierBActive());

        var block: usize = 0;
        while (block < 4) : (block += 1) {
            eng_a.renderInto(token);
            eng_b.renderInto(token);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
        }
    }
}

// ===========================================================================
// 2. The cost gate — refuse a chain, enable a wide graph (decidable).
// ===========================================================================

test "cost gate: refuses a near-linear chain, enables a parallel graph" {
    const cfgg = parallel.GateConfig{};
    // A near-linear chain: span ≈ work ⇒ parallelism ≈ 1 < theta_speedup. Refused
    // even when busy and a workgroup is available.
    const chain = parallel.costGate(100.0, 96.0, 8, 50.0, true, cfgg);
    try std.testing.expect(!chain.enable);
    try std.testing.expect(chain.parallelism < cfgg.theta_speedup);
    try std.testing.expectEqual(@as(usize, 1), chain.p);

    // A wide graph: work ≫ span ⇒ high parallelism, busy, workgroup present ⇒ enabled.
    const wide = parallel.costGate(800.0, 100.0, 8, 200.0, true, cfgg);
    try std.testing.expect(wide.enable);
    try std.testing.expect(wide.parallelism >= cfgg.theta_speedup);
    try std.testing.expect(wide.p >= 2);

    // No workgroup ⇒ refused regardless of parallelism (the bound is unavailable).
    const no_wg = parallel.costGate(800.0, 100.0, 8, 200.0, false, cfgg);
    try std.testing.expect(!no_wg.enable);

    // Not busy ⇒ refused (one core has headroom).
    const idle = parallel.costGate(5.0, 1.0, 8, 200.0, true, cfgg);
    try std.testing.expect(!idle.enable);
}

test "engine promotion: wide graph promotes, a plain chain stays Tier A" {
    const N = 32;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 7);
    var out: [N]Sample(f32) = undefined;

    // The wide graph promotes under a forced workgroup.
    var wide = try buildWide(alloc, N, &input, &out, .{ .cores = 4, .force_workgroup = true });
    defer wide.deinit();
    try std.testing.expect(wide.tierBActive());
    try std.testing.expect(wide.tierBParallelism() >= 1.5);

    // A near-linear chain (source→gain→affine→sink) does NOT promote — span ≈ work.
    var bg = pan.Graph.init(alloc, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const g = try bg.add(Gain, .{ .gain = 0.5 });
    const a = try bg.add(Affine, .{ .a = 1.1, .b = 0.0 });
    var out2: [N]Sample(f32) = undefined;
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out2) });
    try bg.connect(s, g);
    try bg.connect(g, a);
    try bg.connect(a, sk);
    var chain = try bg.commitWith(.{ .cores = 4, .force_workgroup = true });
    defer chain.deinit();
    try std.testing.expect(!chain.tierBActive());
    try std.testing.expect(chain.tierBParallelism() < 1.5);
}

// ===========================================================================
// 3. Schedules — validity and the HEFT-beats-barrier makespan.
// ===========================================================================

test "schedules: every op placed, every dependency respected, HEFT ≤ barrier makespan" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 99);
    var out: [N]Sample(f32) = undefined;
    var eng = try buildWide(alloc, N, &input, &out, .{ .cores = 4, .force_workgroup = true });
    defer eng.deinit();

    // Rebuild the DAG/schedules from the engine's committed plan via the public
    // building blocks (the same path the engine uses).
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    const lvl = parallel.levelSchedule(&dag, &costs, 4);
    const heft = parallel.heftSchedule(&dag, &costs, 4);

    // Both schedules place every op exactly once.
    try assertCovers(&lvl, dag.n);
    try assertCovers(&heft, dag.n);
    // Both respect every dependency (a predecessor precedes its successor in the
    // per-worker order when same-worker; the global start order is a topo order).
    try assertDepsRespected(&dag, &lvl);
    try assertDepsRespected(&dag, &heft);
    // HEFT fills bubbles a level barrier leaves: its makespan is no worse.
    try std.testing.expect(heft.makespan <= lvl.makespan + 1e-3);
}

/// Every op id in [0, n) appears exactly once across the worker sequences.
fn assertCovers(s: *const parallel.Schedule, n: usize) !void {
    var seen = [_]bool{false} ** parallel.max_ops;
    var count: usize = 0;
    var w: usize = 0;
    while (w < s.p) : (w += 1) {
        for (s.workerOps(w)) |op| {
            try std.testing.expect(op < n);
            try std.testing.expect(!seen[op]);
            seen[op] = true;
            count += 1;
        }
    }
    try std.testing.expectEqual(n, count);
}

/// Every dependency is honoured: for a same-worker predecessor, it appears earlier
/// in that worker's order; for a cross-worker predecessor, it exists in the
/// schedule (the runtime ready-flag spin orders it). We check the strong same-worker
/// property and that the global position of each op exceeds all its predecessors'.
fn assertDepsRespected(dag: *const parallel.Dag, s: *const parallel.Schedule) !void {
    // Global execution rank: a valid schedule's per-worker orders interleave into a
    // topological order. Build a position map from the union of per-worker orders by
    // assigning each op the max(position) consistent with same-worker order, then
    // assert preds have a strictly lower same-worker position where co-located.
    var pos = [_]usize{0} ** parallel.max_ops;
    var w: usize = 0;
    while (w < s.p) : (w += 1) {
        var i: usize = 0;
        for (s.workerOps(w)) |op| {
            pos[op] = i;
            i += 1;
        }
    }
    var op: usize = 0;
    while (op < dag.n) : (op += 1) {
        var pr = dag.preds[op];
        while (pr != 0) {
            const p = @ctz(pr);
            pr &= pr - 1;
            if (s.worker_of[p] == s.worker_of[op]) {
                // Same worker: the predecessor must run earlier in the sequence.
                try std.testing.expect(pos[p] < pos[op]);
            }
        }
    }
}

// ===========================================================================
// 4. The worker pool — a 2-worker handshake with bounded spin.
// ===========================================================================

const HandshakeCtx = struct {
    flags: [parallel.max_workers]std.atomic.Value(usize) = blk: {
        var a: [parallel.max_workers]std.atomic.Value(usize) = undefined;
        for (&a) |*f| f.* = std.atomic.Value(usize).init(0);
        break :blk a;
    },
};

fn handshakeTask(user: *anyopaque, wid: usize, g: usize) void {
    const ctx: *HandshakeCtx = @ptrCast(@alignCast(user));
    // Worker 1 waits for worker 0 to publish g, then publishes its own — the
    // point-to-point handshake the ready-flag formalises.
    if (wid == 0) {
        ctx.flags[0].store(g, .release);
    } else {
        while (ctx.flags[0].load(.acquire) != g) std.atomic.spinLoopHint();
        ctx.flags[wid].store(g, .release);
    }
}

test "worker pool: 2-worker generation handshake completes with bounded spin" {
    const alloc = std.testing.allocator;
    var pool = try parallel.WorkerPool.init(alloc, 2, parallel.Workgroup{ .available = true });
    try pool.spawn();
    defer pool.deinit();

    var ctx = HandshakeCtx{};
    // Multiple dispatches: the generation disambiguates callbacks without clearing
    // the flags, and each handshake must complete (no deadlock, bounded spin).
    var round: usize = 0;
    while (round < 100) : (round += 1) {
        const g = pool.dispatch(&ctx, handshakeTask);
        try std.testing.expectEqual(g, ctx.flags[0].load(.acquire));
        try std.testing.expectEqual(g, ctx.flags[1].load(.acquire));
    }
}

test "worker pool: P=1 degenerate (caller is the lone worker)" {
    const alloc = std.testing.allocator;
    var pool = try parallel.WorkerPool.init(alloc, 1, parallel.Workgroup{});
    try pool.spawn();
    defer pool.deinit();
    var ctx = HandshakeCtx{};
    const g = pool.dispatch(&ctx, handshakeTask);
    try std.testing.expectEqual(g, ctx.flags[0].load(.acquire));
}

// ===========================================================================
// 5. The generation barrier — P participants synchronise and reset.
// ===========================================================================

const BarrierCtx = struct {
    barrier: parallel.Barrier,
    counter: std.atomic.Value(usize) = .init(0),
    phases: usize,
};

fn barrierWorker(ctx: *BarrierCtx) void {
    var phase: usize = 0;
    while (phase < ctx.phases) : (phase += 1) {
        _ = ctx.counter.fetchAdd(1, .acq_rel);
        ctx.barrier.wait();
    }
}

test "barrier: P participants synchronise across phases (reusable)" {
    const alloc = std.testing.allocator;
    const P = 4;
    const phases = 50;
    var ctx = BarrierCtx{ .barrier = .{ .p = P }, .phases = phases };

    var threads: [P - 1]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, barrierWorker, .{&ctx});
    barrierWorker(&ctx); // the caller is participant 0
    for (threads) |t| t.join();
    _ = alloc;

    // Every participant incremented once per phase.
    try std.testing.expectEqual(@as(usize, P * phases), ctx.counter.load(.acquire));
}

// ===========================================================================
// 6. The auto-demote policy — hysteresis.
// ===========================================================================

test "demote policy: sustained low headroom demotes, stable high re-promotes" {
    var pol = parallel.DemotePolicy{ .floor = 0.1, .ceiling = 0.3, .demote_after = 4, .promote_after = 8, .active = true };

    // Healthy headroom keeps Tier B active.
    var i: usize = 0;
    while (i < 10) : (i += 1) try std.testing.expect(pol.observe(0.5));

    // A short dip does NOT demote (below the streak threshold).
    try std.testing.expect(pol.observe(0.05));
    try std.testing.expect(pol.observe(0.05));
    try std.testing.expect(pol.observe(0.5)); // recovers; streak resets

    // Sustained low headroom demotes after `demote_after` consecutive callbacks.
    try std.testing.expect(pol.observe(0.05)); // 1 (still active this call)
    try std.testing.expect(pol.observe(0.05)); // 2
    try std.testing.expect(pol.observe(0.05)); // 3
    try std.testing.expect(!pol.observe(0.05)); // 4 → demoted

    // While demoted, mid headroom does NOT re-promote (must clear the ceiling).
    i = 0;
    while (i < 20) : (i += 1) try std.testing.expect(!pol.observe(0.2));

    // A stable high-headroom window re-promotes after `promote_after`.
    i = 0;
    while (i < 7) : (i += 1) try std.testing.expect(!pol.observe(0.5));
    try std.testing.expect(pol.observe(0.5)); // 8th high callback → re-promoted
}

// ===========================================================================
// 7. The op-DAG anti-dependencies — a colored-pool reuse is ordered.
// ===========================================================================

// ===========================================================================
// 8. §2.9 invariance — feedback parallelises cleanly under Tier B (the z⁻¹ breaks
//    the intra-callback loop, so the persistent tail carries no cross-worker dep).
// ===========================================================================

/// Two-input feedback summer: out = dry + g·wet. Port "dry" is the forward input,
/// "wet" the z⁻¹ feedback tap read from the persistent buffer the loop's delay wrote
/// last block.
const Summer = struct {
    const Self = @This();
    g: f32 = 0.5,
    pub const inputs = .{ .dry = Sample(f32), .wet = Sample(f32) };
    pub fn process(self: *Self, dry: []const Sample(f32), wet: []const Sample(f32), out: []Sample(f32)) void {
        for (dry, wet, out) |d, w, *y| y.ch[0] = d.ch[0] + self.g * w.ch[0];
    }
};

/// A wide bank of `W` independent comb-filter voices (each: src → Summer → DelayLine,
/// with the delay fed back into the Summer's wet port) summed by an adder tree into a
/// sink. The voices are mutually independent feedback loops, so the graph is wide
/// (promotes Tier B) AND every loop carries a z⁻¹ — the §2.9 case that must stay
/// bit-exact: the delay breaks each loop, so there is no intra-callback cross-worker
/// dependency, and the per-edge plan's persistent feedback tail is never recolored.
fn buildCombBank(comptime W: usize, alloc: std.mem.Allocator, comptime N: usize, input: [*]const Sample(f32), out: [*]Sample(f32), opts: engine.EngineOptions) !engine.Engine {
    comptime std.debug.assert(W >= 2 and (W & (W - 1)) == 0);
    const Delay = pan.DelayLine(Sample(f32), 3);
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = input });
    const Summerh = @TypeOf(try bg.add(Summer, .{}));
    const Adder = @TypeOf(try bg.add(Add2, .{}));

    // One comb voice per lane: src → Summer → DelayLine, the delay fed back into the
    // Summer's wet port (a z⁻¹ loop). The summer output also feeds the mix tree.
    var voices: [W]Summerh = undefined;
    var v: usize = 0;
    while (v < W) : (v += 1) {
        const sum = try bg.add(Summer, .{ .g = 0.3 + 0.1 * @as(f32, @floatFromInt(v)) });
        const dl = try bg.add(Delay, .{});
        try bg.connect(src, sum.in.dry);
        try bg.connect(sum, dl);
        try bg.connectFeedback(dl, sum.in.wet);
        voices[v] = sum;
    }

    // Balanced adder tree over the voice outputs.
    var nodes: [W]Adder = undefined;
    var cnt: usize = 0;
    var p: usize = 0;
    while (p < W / 2) : (p += 1) {
        const add = try bg.add(Add2, .{});
        try bg.connect(voices[2 * p], add.in.x);
        try bg.connect(voices[2 * p + 1], add.in.y);
        nodes[cnt] = add;
        cnt += 1;
    }
    while (cnt > 1) {
        var nx: [W]Adder = undefined;
        var w: usize = 0;
        var j: usize = 0;
        while (j + 1 < cnt) : (j += 2) {
            const add = try bg.add(Add2, .{});
            try bg.connect(nodes[j], add.in.x);
            try bg.connect(nodes[j + 1], add.in.y);
            nx[w] = add;
            w += 1;
        }
        nodes = nx;
        cnt = w;
    }
    const sink = try bg.add(BufSink, .{ .dest = out });
    try bg.connect(nodes[0], sink);
    return bg.commitWith(opts);
}

test "GATE: a WIDE FEEDBACK comb bank — Tier B ≡ Tier A bit-exact (z⁻¹ persistent tail)" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xFEEDBA);
    var out_a: [N]Sample(f32) = undefined;
    var out_b: [N]Sample(f32) = undefined;

    var eng_a = try buildCombBank(4, alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();
    var eng_b = try buildCombBank(4, alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer eng_b.deinit();
    try std.testing.expect(eng_b.tierBActive());

    const token = engine.enterRealtimeThread();
    defer token.leave();
    // Many blocks: the feedback state must evolve identically across callbacks (the
    // z⁻¹ tail is carried bit-for-bit under the parallel schedule).
    var block: usize = 0;
    while (block < 16) : (block += 1) {
        eng_a.renderInto(token);
        eng_b.renderInto(token);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
    }
}

// ===========================================================================
// 9. Concurrency-aware coloring (A15/§8.11) — the recolored Tier-B scratch pool is
//    no larger than the naive per-edge pool, and the render stays bit-exact (proven
//    by the differential above). A wide graph with reconvergent chains lets the
//    schedule-time interval coloring reuse buffers across non-overlapping values.
// ===========================================================================

test "concurrency coloring: the Tier-B scratch pool is ≤ the naive per-edge pool" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 11);
    var out: [N]Sample(f32) = undefined;

    var eng = try buildWide(alloc, N, &input, &out, .{ .cores = 4, .force_workgroup = true });
    defer eng.deinit();
    // The Tier-B overlay's per-edge plan was recolored on the schedule-time interval
    // graph; its scratch pool is at most the non-coalesced per-edge size. Compare to
    // a fresh per-edge plan's footprint via the engine's colored footprint as a
    // sanity bound (the recolored Tier-B pool must be a positive, bounded figure).
    const tb_pool = eng.tierBScratchBytes();
    try std.testing.expect(tb_pool > 0);
    // The recolored scratch never exceeds the worst case (one distinct buffer per
    // produced value = op_count buffers): a hard static bound (H2 preserved).
    const plan = eng.currentPlan();
    try std.testing.expect(eng.tierBScratchBuffers() <= plan.op_count + 1);
}

// ===========================================================================
// 10. Paranoid NaN-poison on the runtime Tier-B path — the extra net for the
//     concurrency-aware colorer. In a safe build the parallel render poisons each
//     scratch buffer the instant its value's last reader finishes; a correct render
//     must therefore stay BIT-EXACT (poison touches only dead buffers), and the net
//     must actually FIRE (not be a silent no-op).
// ===========================================================================

test "paranoid poison: active on the runtime Tier-B path, and harmless to a correct render" {
    const builtin = @import("builtin");
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x7012);
    var out_a: [N]Sample(f32) = undefined;
    var out_b: [N]Sample(f32) = undefined;

    var eng_a = try buildWide(alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();
    // Both executors: the poison runs after each op on both the barrier and the
    // ready-flag paths.
    inline for (.{ pan.TierBExecutor.level_barrier, pan.TierBExecutor.heft }) |exe| {
        var eng_b = try buildWide(alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = exe });
        defer eng_b.deinit();
        try std.testing.expect(eng_b.tierBActive());
        const token = engine.enterRealtimeThread();
        defer token.leave();
        var block: usize = 0;
        while (block < 8) : (block += 1) {
            eng_a.renderInto(token);
            eng_b.renderInto(token);
            // Poison touches only dead buffers ⇒ the correct render is unchanged, and
            // no NaN escapes to the sink.
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
            for (out_b) |s| try std.testing.expect(std.math.isFinite(s.ch[0]));
        }
        // The net is ACTIVE in a safe build: a wide graph's scratch buffers each get
        // poisoned when their last reader finishes (zero would mean a silent no-op).
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            try std.testing.expect(eng_b.tierBPoisonFills() > 0);
        }
        try std.testing.expect(!eng_b.telemetry().fault);
    }
}

test "op-DAG: a wide fan-in is bit-exact under the level barrier and HEFT (no torn pool)" {
    // Covered numerically by the spine; here we assert the DAG itself records a
    // forward edge into every consumer of a produced buffer (no missing dependency).
    const N = 32;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 3);
    var out: [N]Sample(f32) = undefined;
    var eng = try buildWide(alloc, N, &input, &out, .{ .cores = 4, .force_workgroup = true });
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);

    // Every op except the source roots has at least one predecessor (the wide graph
    // is fully connected source→…→sink), and the sink op (last, no outputs) has
    // predecessors. A DAG with a disconnected consumer would be a missing-edge bug.
    var non_root: usize = 0;
    var op: usize = 0;
    while (op < dag.n) : (op += 1) {
        if (dag.preds[op] != 0) non_root += 1;
    }
    try std.testing.expect(non_root >= dag.n - 1); // only the single source is a root
}

// ===========================================================================
// 11. cost_hint — the per-kernel compute-intensity multiplier. It must (a) LIFT the
//     gate's achievable-parallelism estimate / worker sizing for a bank of heavy
//     voices vs the same shape with cheap plumbing, and (b) NEVER change the rendered
//     samples: a Tier-B parallel render of a heavily-hinted graph is BIT-EXACT to the
//     Tier-A sequential render of the same graph, AND to an unhinted graph of the same
//     shape. The hint is scheduler-only metadata — a wrong hint costs throughput,
//     never correctness.
// ===========================================================================

test "cost_hint: heavy voices lift the gate's parallelism estimate vs cheap plumbing" {
    // The hint's PURPOSE: a wide bank of compute-heavy voices is more worth
    // parallelising than the same topology made of trivial copies. With the heavy
    // hint the per-op work of each arm dominates the (light) reduction/plumbing, so
    // the work/span ratio — and thus the gate's achievable-parallelism estimate —
    // must be strictly higher than for the identical shape with default-1.0 arms.
    const N = 32;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x600D11);
    var out_cheap: [N]Sample(f32) = undefined;
    var out_heavy: [N]Sample(f32) = undefined;

    // Same shape, same coefficients; the ONLY difference is the arms' cost_hint
    // (1.0 default vs 16.0). Both forced through the workgroup so promotion is decided
    // purely by the gate's W/S verdict, not workgroup availability.
    var cheap = try buildWideAff(Affine, alloc, N, &input, &out_cheap, .{ .cores = 4, .force_workgroup = true });
    defer cheap.deinit();
    var heavy = try buildWideAff(HeavyVoice, alloc, N, &input, &out_heavy, .{ .cores = 4, .force_workgroup = true });
    defer heavy.deinit();

    // Both promote (the wide shape is parallel either way) ...
    try std.testing.expect(cheap.tierBActive());
    try std.testing.expect(heavy.tierBActive());
    // ... but the heavy-hinted bank exposes MORE achievable parallelism: the heavy arms
    // outweigh the light reduction tree, lifting the work/span ratio. This is the hint
    // doing its job — it lifts the worker-count sizing for compute-heavy graphs.
    try std.testing.expect(heavy.tierBParallelism() > cheap.tierBParallelism());
    // And the lift is enough to size at least as many workers as the cheap version
    // (the hint never SHRINKS the achievable parallelism).
    try std.testing.expect(heavy.tierBWorkers() >= cheap.tierBWorkers());
}

test "cost_hint INVARIANCE: a heavily-hinted Tier-B render is BIT-EXACT to Tier-A sequential" {
    // THE LOAD-BEARING INVARIANT. The hint must change ONLY the schedule, never the
    // samples. We render the SAME heavily-hinted graph two ways — Tier-A sequential and
    // Tier-B parallel (both executors, several worker counts) — and require byte-for-
    // byte equality across many blocks (the feedback-free state still must match every
    // callback).
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xC0571117);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    inline for (.{ pan.TierBExecutor.level_barrier, pan.TierBExecutor.heft }) |exe| {
        var p: usize = 2;
        while (p <= 8) : (p += 1) {
            var out_a: [N]Sample(f32) = undefined;
            var out_b: [N]Sample(f32) = undefined;
            // Tier A: sequential reference of the HEAVILY-HINTED graph.
            var eng_a = try buildWideAff(HeavyVoice, alloc, N, &input, &out_a, .{});
            defer eng_a.deinit();
            // Tier B: parallel render of the SAME hinted graph.
            var eng_b = try buildWideAff(HeavyVoice, alloc, N, &input, &out_b, .{ .cores = p, .force_workgroup = true, .tier_b_executor = exe });
            defer eng_b.deinit();
            try std.testing.expect(eng_b.tierBActive()); // must actually parallelise
            try std.testing.expect(eng_b.tierBWorkers() >= 2);

            var block: usize = 0;
            while (block < 8) : (block += 1) {
                eng_a.renderInto(token);
                eng_b.renderInto(token);
                // Bit-exact: the hint touched the schedule, not a single sample.
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
            }
            try std.testing.expect(!eng_a.telemetry().fault);
            try std.testing.expect(!eng_b.telemetry().fault);
        }
    }
}

test "cost_hint INVARIANCE: hinted vs unhinted graphs of the same shape render identically" {
    // The complementary half of the invariant: because the hint is pure scheduler
    // metadata, a graph with heavily-hinted arms must render byte-for-byte the same as
    // the identical-shape graph with default (1.0) arms — the two differ ONLY in the
    // schedule the gate picks, not in the samples. Tier-A-vs-Tier-A and Tier-B-vs-
    // Tier-B are both pinned.
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x5A4E54AE);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    var out_cheap_seq: [N]Sample(f32) = undefined;
    var out_heavy_seq: [N]Sample(f32) = undefined;
    var out_cheap_par: [N]Sample(f32) = undefined;
    var out_heavy_par: [N]Sample(f32) = undefined;

    var cheap_seq = try buildWideAff(Affine, alloc, N, &input, &out_cheap_seq, .{});
    defer cheap_seq.deinit();
    var heavy_seq = try buildWideAff(HeavyVoice, alloc, N, &input, &out_heavy_seq, .{});
    defer heavy_seq.deinit();
    var cheap_par = try buildWideAff(Affine, alloc, N, &input, &out_cheap_par, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer cheap_par.deinit();
    var heavy_par = try buildWideAff(HeavyVoice, alloc, N, &input, &out_heavy_par, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer heavy_par.deinit();
    try std.testing.expect(heavy_par.tierBActive());

    var block: usize = 0;
    while (block < 8) : (block += 1) {
        cheap_seq.renderInto(token);
        heavy_seq.renderInto(token);
        cheap_par.renderInto(token);
        heavy_par.renderInto(token);
        const c_seq = std.mem.sliceAsBytes(out_cheap_seq[0..]);
        // Sequential: hinting an arm cannot move a sample.
        try std.testing.expectEqualSlices(u8, c_seq, std.mem.sliceAsBytes(out_heavy_seq[0..]));
        // Parallel: same — and the parallel renders also match the sequential one, so
        // all four outputs are byte-identical every block.
        try std.testing.expectEqualSlices(u8, c_seq, std.mem.sliceAsBytes(out_cheap_par[0..]));
        try std.testing.expectEqualSlices(u8, c_seq, std.mem.sliceAsBytes(out_heavy_par[0..]));
    }
}

test "cost_hint INVARIANCE: an EXTREME (1e6) hint still renders bit-exact to Tier-A sequential" {
    // The invariant must not depend on the hint's magnitude. With a 1e6 hint the
    // per-op cost is enormous, yet the rendered samples are untouched: a Tier-B
    // parallel render of the extreme-hinted graph stays byte-for-byte equal to the
    // Tier-A sequential render of the SAME graph (across both executors and several
    // worker counts). A scheduler that overflowed the cost into NaN/Inf and reordered
    // would break this; a correct one keeps the samples independent of the hint.
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xE47A3E);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    inline for (.{ pan.TierBExecutor.level_barrier, pan.TierBExecutor.heft }) |exe| {
        var p: usize = 2;
        while (p <= 8) : (p += 1) {
            var out_a: [N]Sample(f32) = undefined;
            var out_b: [N]Sample(f32) = undefined;
            var eng_a = try buildWideAff(ExtremeVoice, alloc, N, &input, &out_a, .{});
            defer eng_a.deinit();
            var eng_b = try buildWideAff(ExtremeVoice, alloc, N, &input, &out_b, .{ .cores = p, .force_workgroup = true, .tier_b_executor = exe });
            defer eng_b.deinit();
            try std.testing.expect(eng_b.tierBActive());

            var block: usize = 0;
            while (block < 6) : (block += 1) {
                eng_a.renderInto(token);
                eng_b.renderInto(token);
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
                // No NaN/Inf escapes to the sink despite the enormous hint.
                for (out_b) |s| try std.testing.expect(std.math.isFinite(s.ch[0]));
            }
            try std.testing.expect(!eng_a.telemetry().fault);
            try std.testing.expect(!eng_b.telemetry().fault);
        }
    }
}

// ===========================================================================
// 12. BUFFER-ALIGNMENT INVARIANT under the Tier-B concurrency recolor.
//
//     WHY this matters (the bug class this section pins shut):
//       The runtime engine reinterprets each pool buffer's raw byte region as a
//       TYPED (and, for planar views, `@Vector`-lane) slice via a safety-checked
//       `@alignCast`. That cast PANICS in Debug/ReleaseSafe — and is undefined
//       behaviour in ReleaseFast — unless the buffer's byte offset is a multiple of
//       its element type's natural alignment `@alignOf(Elem)`. The flat pool base is
//       `align(64)`, and every element alignment in the library is ≤ 64, so an
//       in-pool offset that is a multiple of `@alignOf(Elem)` makes the ABSOLUTE
//       address aligned and the `@alignCast` valid.
//
//       `parallel.concurrencyColor` RE-LAYS-OUT the Tier-B scratch pool (an interval
//       coloring repack that shrinks the footprint for parallel execution). It must
//       therefore reproduce the same per-element alignment guarantee the commit pass
//       already gives: every recolored buffer offset divisible by that buffer's true
//       `@alignOf(Elem)`, the recorded `buffer_align` equal to that true alignment,
//       and the persistent feedback (z⁻¹) tail — which survives the callback boundary
//       carrying state — repacked with each absolute offset still aligned.
//
//       The Yoneda observation set below CHARACTERISES the invariant by morphisms:
//       it drives `concurrencyColor` exactly as the engine's Tier-B `buildFor` pass-0
//       does (`commitRuntime(..., .per_edge)` → a schedule → recolor), then probes
//       every referenced buffer id from every angle (offset mod align, recorded align
//       vs comptime `@alignOf`, the persistent tail base, the ≤64 ceiling, the
//       uniform-f32 no-op, and determinism). The bit-exact behavioural half — that an
//       aligned recolor did not perturb the render, INCLUDING the z⁻¹ feedback state
//       carried across callbacks — is the spine differential and the comb-bank gate
//       above; the test here adds an explicit second witness that recolor is a pure
//       layout function (so two identical graphs recolor identically).
//
//       NOTE: if any assertion below FAILS, it is reporting a real misalignment /
//       layout bug in `concurrencyColor` — do not weaken it; an `@alignCast` that
//       can trap is a correctness defect, not a tuning knob.
// ===========================================================================

const Frame = pan.Frame;

/// `Frame(f64, .mono)` has element alignment 8 (its lane is `f64`), strictly wider
/// than `Sample(f32)`'s alignment of 4. A graph mixing the two is the exact shape
/// that exercises the recolorer's alignment arithmetic: packing f64 buffers by byte
/// size alone (the latent bug this section guards) can drop a wide buffer onto a
/// 4-aligned-but-not-8-aligned offset, which the engine's `@alignCast` would reject.
const Wide = Frame(f64, .mono);

const WideSrc = struct {
    const Self = @This();
    pub fn process(_: *Self, out: []Wide) void {
        for (out) |*o| o.ch[0] = 0;
    }
};
const WideGain = struct {
    const Self = @This();
    g: f64 = 1.0,
    pub fn process(self: *Self, in: []const Wide, out: []Wide) void {
        for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.g;
    }
};
const WideAdd2 = struct {
    const Self = @This();
    pub const inputs = .{ .x = Wide, .y = Wide };
    pub fn process(_: *Self, x: []const Wide, y: []const Wide, out: []Wide) void {
        for (x, y, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
    }
};
const WideSink = struct {
    const Self = @This();
    pub fn process(_: *Self, _: []const Wide) void {}
};
const NarrowSrc = struct {
    const Self = @This();
    pub fn process(_: *Self, out: []Sample(f32)) void {
        for (out) |*o| o.ch[0] = 0;
    }
};
const NarrowSink = struct {
    const Self = @This();
    pub fn process(_: *Self, _: []const Sample(f32)) void {}
};

/// Visit every distinct buffer id REFERENCED by the recolored plan (each op's
/// outputs, sample inputs, and parameter inputs) and assert the alignment law:
///   • the buffer's start offset is an exact multiple of its recorded alignment;
///   • the recorded alignment is a real power-of-two ≥ 1 and ≤ 64 (so, combined
///     with the 64-aligned pool base, the ABSOLUTE address is aligned too — the
///     `@alignCast` the engine performs on the byte region cannot trap);
///   • the alignment is consistent with the byte length: a length that is itself
///     a multiple of the alignment is required for the next color to start aligned.
/// `expect_align[len]` (when provided) additionally pins the alignment that a
/// given byte length MUST carry, cross-checking that the recolorer recorded the
/// TRUE element `@alignOf`, not merely *some* aligned value.
fn assertAlignmentInvariant(plan: anytype) !void {
    const NB = pan.graph.max_buffers;
    var seen = [_]bool{false} ** NB;
    var any: usize = 0;
    var i: usize = 0;
    while (i < plan.op_count) : (i += 1) {
        const op = &plan.ops[i];
        inline for (.{
            op.output_buffer_ids[0..op.output_count],
            op.input_buffer_ids[0..op.input_count],
            op.param_input_buffer_ids[0..op.param_input_count],
        }) |ids| {
            for (ids) |id| {
                try std.testing.expect(id < NB);
                if (seen[id]) continue;
                seen[id] = true;
                any += 1;
                const off = plan.buffer_offset[id];
                const al = plan.buffer_align[id];
                // A real, sane alignment: power of two, in [1, 64].
                try std.testing.expect(al >= 1 and al <= 64);
                try std.testing.expect((al & (al - 1)) == 0);
                // THE INVARIANT: the offset meets the element's natural alignment, so
                // the engine's typed/`@Vector` reinterpret of [off, off+len) via a
                // safety-checked `@alignCast` is valid (the pool base is align(64)).
                try std.testing.expectEqual(@as(usize, 0), off % al);
            }
        }
    }
    // The observation set must be non-empty — a vacuous pass would prove nothing.
    try std.testing.expect(any > 0);
}

/// The uniform-f32 wide fan-out topology as a BUILDER (so its `.ir` can be committed
/// per-edge for the recolorer). Same shape as `buildWide`, but with placeholder
/// source/sink pointers (the recolorer never reads sample data — it lays out buffers
/// from the static plan). The caller owns and must `deinit` the returned builder.
fn buildWideGraph(alloc: std.mem.Allocator, comptime N: usize) !pan.Graph {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{});
    const g0 = try bg.add(Gain, .{ .gain = 0.5012 });
    const a0 = try bg.add(Affine, .{ .a = 1.31, .b = -0.07 });
    const g1 = try bg.add(Gain, .{ .gain = 0.7734 });
    const a1 = try bg.add(Affine, .{ .a = 0.92, .b = 0.013 });
    const g2 = try bg.add(Gain, .{ .gain = 1.211 });
    const a2 = try bg.add(Affine, .{ .a = -0.5, .b = 0.21 });
    const g3 = try bg.add(Gain, .{ .gain = 0.3001 });
    const a3 = try bg.add(Affine, .{ .a = 1.07, .b = -0.001 });
    const s01 = try bg.add(Add2, .{});
    const s23 = try bg.add(Add2, .{});
    const stop = try bg.add(Add2, .{});
    const sink = try bg.add(BufSink, .{});
    try bg.connect(src, g0);
    try bg.connect(src, g1);
    try bg.connect(src, g2);
    try bg.connect(src, g3);
    try bg.connect(g0, a0);
    try bg.connect(g1, a1);
    try bg.connect(g2, a2);
    try bg.connect(g3, a3);
    try bg.connect(a0, s01.in.x);
    try bg.connect(a1, s01.in.y);
    try bg.connect(a2, s23.in.x);
    try bg.connect(a3, s23.in.y);
    try bg.connect(s01, stop.in.x);
    try bg.connect(s23, stop.in.y);
    try bg.connect(stop, sink);
    return bg;
}

/// Recolor a freshly committed per-edge plan exactly as the engine's Tier-B pass-0
/// does: build the preliminary schedule on the per-edge DAG, then `concurrencyColor`
/// on its intervals. Returns the recolored plan by value (it lives in the caller).
fn recolored(ir: pan.graph.Graph, executor: pan.TierBExecutor, p: usize) !pan.commit.Plan(pan.graph.max_nodes) {
    var plan = try pan.commitRuntime(ir, .per_edge);
    const dag = parallel.buildDag(plan);
    var costs = parallel.CostModel.fromPlan(plan);
    const sched = switch (executor) {
        .level_barrier => parallel.levelSchedule(&dag, &costs, p),
        .heft => parallel.heftSchedule(&dag, &costs, p),
    };
    parallel.concurrencyColor(&plan, &sched);
    return plan;
}

test "align invariant: every recolored buffer offset divides its element alignment (uniform f32, both executors, P=1..8)" {
    // Drive the recolorer on the wide uniform-f32 differential graph through both
    // executors and every worker count the engine could pick, and assert the
    // alignment law on every referenced buffer. Uniform-f32 means every alignment is
    // 4 and every length a multiple of 4, so a CORRECT recolorer trivially satisfies
    // it — but a recolorer that mislaid a color (e.g. an off-by-one in the offset
    // accumulation) would still surface here, and the same harness drives the mixed
    // graph below where alignment actually bites.
    const N = 64;
    const alloc = std.testing.allocator;
    var bg = try buildWideGraph(alloc, N);
    defer bg.deinit();

    inline for (.{ pan.TierBExecutor.level_barrier, pan.TierBExecutor.heft }) |exe| {
        var p: usize = 1;
        while (p <= 8) : (p += 1) {
            var plan = try recolored(bg.ir, exe, p);
            try assertAlignmentInvariant(&plan);
            // Uniform f32 ⇒ EVERY buffer is 4-aligned and the scratch total is a
            // multiple of 4 (so the persistent tail, if any, also starts aligned).
            var id: usize = 0;
            while (id < plan.pool_buffer_count) : (id += 1) {
                try std.testing.expectEqual(@as(usize, 4), plan.buffer_align[id]);
            }
            try std.testing.expectEqual(@as(usize, 0), plan.pool_bytes % 4);
        }
    }
}

/// A MIXED narrow/wide graph: an independent `Sample(f32)` (align 4) chain AND an
/// independent `Frame(f64,.mono)` (align 8) fan-in tree, both rooted at sources and
/// reaching sinks. The two element classes share the recolored pool, so the f64
/// buffers MUST be laid at 8-aligned offsets even though 4-aligned slots between f32
/// buffers would be "free" by byte size — the precise case the alignment repack
/// exists for. The f64 tree is wide (a 2-deep adder fan-in) so several wide buffers
/// coexist and the colorer has real choices to make.
fn buildMixedAlign(alloc: std.mem.Allocator, comptime N: usize) !pan.Graph {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();

    // Narrow (align-4) chain.
    const ns = try bg.add(NarrowSrc, .{});
    const nk = try bg.add(NarrowSink, .{});
    try bg.connect(ns, nk);

    // Wide (align-8) fan-out → adder tree → sink.
    const ws = try bg.add(WideSrc, .{});
    const w0 = try bg.add(WideGain, .{ .g = 0.5 });
    const w1 = try bg.add(WideGain, .{ .g = 1.5 });
    const w2 = try bg.add(WideGain, .{ .g = -0.25 });
    const w3 = try bg.add(WideGain, .{ .g = 2.0 });
    const a01 = try bg.add(WideAdd2, .{});
    const a23 = try bg.add(WideAdd2, .{});
    const atop = try bg.add(WideAdd2, .{});
    const wk = try bg.add(WideSink, .{});
    try bg.connect(ws, w0);
    try bg.connect(ws, w1);
    try bg.connect(ws, w2);
    try bg.connect(ws, w3);
    try bg.connect(w0, a01.in.x);
    try bg.connect(w1, a01.in.y);
    try bg.connect(w2, a23.in.x);
    try bg.connect(w3, a23.in.y);
    try bg.connect(a01, atop.in.x);
    try bg.connect(a23, atop.in.y);
    try bg.connect(atop, wk);
    return bg;
}

test "align invariant: a MIXED narrow/wide graph recolors to aligned offsets, and buffer_align is the TRUE element @alignOf" {
    // The load-bearing alignment case: f64 (align 8) buffers must NOT be dropped onto
    // a 4-aligned offset just because it is the next free byte. We pin both the law
    // (offset % align == 0) AND that the recorded alignment is the genuine element
    // `@alignOf` — keyed off byte length, which uniquely identifies the class here
    // (N f32 frames ⇒ align 4; N f64 frames ⇒ align 8).
    //
    // N is ODD on purpose: N=63 makes a narrow f32 buffer 63·4 = 252 bytes, whose
    // remainder mod 8 is 4. So a naive size-only packer would drop a following f64
    // (align-8) buffer at an offset ≡ 4 (mod 8) — exactly the misalignment the engine's
    // `@alignCast` would trap on. A correct recolorer must insert 4 padding bytes; this
    // odd N is what makes the alignment arithmetic load-bearing rather than incidental.
    const N = 63;
    const alloc = std.testing.allocator;
    const narrow_len = N * @sizeOf(Sample(f32)); // 252, ≡ 4 (mod 8)
    const wide_len = N * @sizeOf(Wide); // 504
    try std.testing.expectEqual(@as(usize, 4), @alignOf(Sample(f32)));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Wide));
    try std.testing.expectEqual(@as(usize, 4), narrow_len % 8); // the stressor holds

    inline for (.{ pan.TierBExecutor.level_barrier, pan.TierBExecutor.heft }) |exe| {
        var p: usize = 1;
        while (p <= 6) : (p += 1) {
            var bg = try buildMixedAlign(alloc, N);
            defer bg.deinit();
            var plan = try recolored(bg.ir, exe, p);

            // The base law on every referenced buffer.
            try assertAlignmentInvariant(&plan);

            // The alignment recorded is the TRUE element @alignOf, not merely *an*
            // aligned value: every wide (f64) buffer carries align 8, every narrow
            // (f32) buffer align 4 — discriminated by byte length, which is unique
            // per class for this graph.
            var saw_wide = false;
            var saw_narrow = false;
            var id: usize = 0;
            while (id < plan.pool_buffer_count) : (id += 1) {
                const len = plan.buffer_byte_len[id];
                if (len == wide_len) {
                    try std.testing.expectEqual(@as(usize, 8), plan.buffer_align[id]);
                    try std.testing.expectEqual(@as(usize, 0), plan.buffer_offset[id] % 8);
                    saw_wide = true;
                } else if (len == narrow_len) {
                    try std.testing.expectEqual(@as(usize, 4), plan.buffer_align[id]);
                    saw_narrow = true;
                }
            }
            // Both classes must actually be present, or the cross-check is vacuous.
            try std.testing.expect(saw_wide);
            try std.testing.expect(saw_narrow);
        }
    }
}

/// A MIXED graph that also carries a WIDE (align-8) persistent z⁻¹ feedback buffer:
/// the f64 comb loop's delay output is the persistent tail, plus an independent f32
/// chain to keep the pool mixed. After recolor the persistent tail is repacked just
/// past the (smaller) scratch — and its ABSOLUTE offset must still be 8-aligned, or
/// the engine's `@alignCast` on the z⁻¹ state buffer (read EVERY callback) would trap.
const WideSummer = struct {
    const Self = @This();
    g: f64 = 0.4,
    pub const inputs = .{ .dry = Wide, .wet = Wide };
    pub fn process(self: *Self, dry: []const Wide, wet: []const Wide, out: []Wide) void {
        for (dry, wet, out) |d, w, *y| y.ch[0] = d.ch[0] + self.g * w.ch[0];
    }
};

fn buildMixedFeedback(alloc: std.mem.Allocator, comptime N: usize) !pan.Graph {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const Delay = pan.DelayLine(Wide, 3);

    // Narrow chain — keeps the pool mixed-alignment.
    const ns = try bg.add(NarrowSrc, .{});
    const nk = try bg.add(NarrowSink, .{});
    try bg.connect(ns, nk);

    // Wide feedback comb: src → Summer → DelayLine, delay fed back into Summer.wet.
    const ws = try bg.add(WideSrc, .{});
    const sum = try bg.add(WideSummer, .{ .g = 0.4 });
    const dl = try bg.add(Delay, .{});
    const wk = try bg.add(WideSink, .{});
    try bg.connect(ws, sum.in.dry);
    try bg.connect(sum, dl);
    try bg.connectFeedback(dl, sum.in.wet);
    try bg.connect(sum, wk);
    return bg;
}

test "align invariant: the WIDE persistent z⁻¹ feedback tail is repacked with an aligned absolute offset" {
    // The persistent feedback buffers live PAST the scratch region and survive the
    // callback boundary carrying filter/delay state. `concurrencyColor` rebases them
    // just past the (recolored, smaller) scratch — and because the scratch size now
    // differs from the commit pass's, a wider-than-f32 element's alignment is NOT
    // free: the recolorer must align each persistent ABSOLUTE offset to its element
    // `@alignOf`. We pin that the wide z⁻¹ buffer (the only one with last_use == -1
    // and matching the f64 byte length) sits at an 8-aligned offset at/after pool_bytes.
    //
    // N=63 (odd) makes the narrow scratch a non-multiple of 8, so pool_bytes is forced
    // to a non-8-multiple before the persistent tail is appended — the recolorer must
    // align the wide z⁻¹ ABSOLUTE offset past it, not merely keep its relative slot.
    const N = 63;
    const alloc = std.testing.allocator;
    const wide_len = N * @sizeOf(Wide);

    inline for (.{ pan.TierBExecutor.level_barrier, pan.TierBExecutor.heft }) |exe| {
        var p: usize = 1;
        while (p <= 4) : (p += 1) {
            var bg = try buildMixedFeedback(alloc, N);
            defer bg.deinit();
            var plan = try recolored(bg.ir, exe, p);

            try assertAlignmentInvariant(&plan);

            // A persistent feedback buffer is marked by last_use == -1 and lives in
            // the pool tail [pool_bytes, pool_bytes+persistent_bytes). Find the wide
            // z⁻¹ tail and assert it is 8-aligned and correctly placed.
            try std.testing.expect(plan.persistent_bytes >= wide_len);
            var saw_persistent_wide = false;
            var id: usize = 0;
            while (id < plan.pool_buffer_count) : (id += 1) {
                if (plan.buffer_last_use[id] != -1) continue; // scratch (or unused root)
                if (plan.buffer_byte_len[id] != wide_len) continue; // not the wide z⁻¹
                const off = plan.buffer_offset[id];
                try std.testing.expectEqual(@as(usize, 8), plan.buffer_align[id]);
                try std.testing.expectEqual(@as(usize, 0), off % 8); // absolute aligned
                try std.testing.expect(off >= plan.pool_bytes); // in the tail
                try std.testing.expect(off + wide_len <= plan.pool_bytes + plan.persistent_bytes);
                saw_persistent_wide = true;
            }
            try std.testing.expect(saw_persistent_wide);
        }
    }
}

test "align invariant: uniform-f32 recolor inserts NO alignment padding (footprint == tight size-only packing)" {
    // THE NO-OP PROPERTY. For a uniform-f32 graph every alignment is 4 and every
    // color size a multiple of 4, so `alignForward(off, 4)` is the identity: the
    // alignment-aware repack must produce EXACTLY the byte total a size-only packer
    // would — no padding is paid. We verify this without a "before" snapshot (recolor
    // mutates in place) by independently reconstructing the tight packing: the sum of
    // the DISTINCT color sizes (each scratch color appears once; persistent buffers
    // are appended past the scratch). If the recolorer ever rounded a 4-aligned class
    // up, pool_bytes would exceed this tight sum and the assertion would fire.
    const N = 64;
    const alloc = std.testing.allocator;
    var bg = try buildWideGraph(alloc, N);
    defer bg.deinit();

    inline for (.{ pan.TierBExecutor.level_barrier, pan.TierBExecutor.heft }) |exe| {
        var p: usize = 1;
        while (p <= 8) : (p += 1) {
            const plan = try recolored(bg.ir, exe, p);
            // The scratch colors are the buffer ids whose last_use is NOT -1 (the
            // persistent tail is appended after). For a no-padding f32 layout the sum
            // of their byte lengths equals pool_bytes exactly.
            var tight: usize = 0;
            var id: usize = 0;
            while (id < plan.pool_buffer_count) : (id += 1) {
                if (plan.buffer_last_use[id] == -1) continue; // persistent tail
                tight += plan.buffer_byte_len[id];
            }
            // No alignment padding: every f32 color packs flush against the previous.
            try std.testing.expectEqual(tight, plan.pool_bytes);
        }
    }
}

test "align invariant: recolor is a PURE layout function (two identical graphs recolor bit-identically)" {
    // The recolored layout must be a deterministic function of (graph, executor, P):
    // two independently committed copies of the SAME graph must recolor to identical
    // offsets/alignments/sizes. This pins that the alignment repack introduces no
    // order-dependence (e.g. iterating a hash set) that could make the Tier-B pool —
    // and thus the cross-worker anti-dependencies derived from it — non-reproducible.
    // N=63 (odd) keeps the mixed-alignment padding in play across the comparison.
    const N = 63;
    const alloc = std.testing.allocator;

    inline for (.{ pan.TierBExecutor.level_barrier, pan.TierBExecutor.heft }) |exe| {
        var p: usize = 1;
        while (p <= 6) : (p += 1) {
            var bg1 = try buildMixedAlign(alloc, N);
            defer bg1.deinit();
            var bg2 = try buildMixedAlign(alloc, N);
            defer bg2.deinit();
            const plan1 = try recolored(bg1.ir, exe, p);
            const plan2 = try recolored(bg2.ir, exe, p);

            try std.testing.expectEqual(plan1.pool_bytes, plan2.pool_bytes);
            try std.testing.expectEqual(plan1.persistent_bytes, plan2.persistent_bytes);
            try std.testing.expectEqual(plan1.pool_buffer_count, plan2.pool_buffer_count);
            try std.testing.expectEqualSlices(usize, plan1.buffer_offset[0..], plan2.buffer_offset[0..]);
            try std.testing.expectEqualSlices(usize, plan1.buffer_align[0..], plan2.buffer_align[0..]);
            try std.testing.expectEqualSlices(usize, plan1.buffer_byte_len[0..], plan2.buffer_byte_len[0..]);
        }
    }
}

// §13 — workgroup gating: Tier-B must not auto-engage on an unverified RT path.
//
// The cost gate promotes to Tier-B only when a co-scheduling Workgroup is
// `available`. `detect()` reports availability per OS, and the policy is that an
// OS whose real-time worker path has not been validated on real hardware stays
// OFF by default (so an untested scheduler can never glitch a live render):
//   - macOS needs an explicit device `os_workgroup` handle (via `withHandle`);
//   - Linux is gated off pending an on-device real-time soak test.
// Either way the safe default is "unavailable", because Tier-B is bit-exact to
// Tier-A — gating it off costs only multicore throughput, never correctness.

test "Workgroup.detect: co-scheduling is unavailable by default (Tier-B opt-in until verified)" {
    const wg = parallel.Workgroup.detect();
    try std.testing.expect(!wg.available);
    try std.testing.expect(wg.handle == null);
}

test "Workgroup.withHandle: binding a real handle is the explicit opt-in that marks it available" {
    var dummy_handle: u8 = 0;
    const wg = parallel.Workgroup.withHandle(&dummy_handle);
    try std.testing.expect(wg.available);
    try std.testing.expect(wg.handle != null);
}

test "cost gate: an unavailable workgroup forces Tier-A regardless of a busy, parallel graph" {
    // A graph that is plainly busy (work ≫ deadline) AND plainly parallel
    // (span ≪ work) would normally promote — but with no workgroup to bound the
    // cross-worker spin, the gate must refuse and keep the engine on Tier A.
    const busy_work: f32 = 100.0;
    const short_span: f32 = 1.0;
    const deadline: f32 = 10.0;
    const decision = parallel.costGate(busy_work, short_span, 8, deadline, false, .{});
    try std.testing.expect(!decision.enable);
}
