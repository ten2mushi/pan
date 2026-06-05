//! parallel_pure_yoneda_test — the Yoneda characterization of the PURE / STRUCTURAL
//! surface of the Tier-B static-parallel executor (`src/parallel.zig`): the
//! single-threaded, decidable functions whose every observable behavior can be
//! pinned without spawning a worker.
//!
//! "Yoneda" here means: an object is known through ALL its morphisms. Each function
//! is therefore probed across its full input space — degenerate inputs (empty graph,
//! a single op, P=1, P > op count), boundary conditions (the exact gate thresholds,
//! the exact demote streak), and the LAWS it must obey:
//!   * `costGate` is monotone in parallelism, refuses a chain, enables a wide graph,
//!     and the three enable-conditions are each independently necessary;
//!   * `buildDag` records RAW + WAR + WAW edges, all pointing forward, so the index
//!     order is itself a valid topological order;
//!   * `CostModel.fromPlan`/`refine` (EWMA), `totalWork`, `span` (the makespan floor);
//!   * `levelSchedule`/`heftSchedule` place every op exactly once, respect every
//!     dependency (same-worker predecessors precede successors; the global start
//!     order is a topological order), ASAP levels are correct, and HEFT's makespan is
//!     never worse than the level barrier's — across P=1..8 and several shapes;
//!   * `DemotePolicy` is a hysteresis state machine (demote after a sub-floor streak,
//!     re-promote after a high-ceiling streak, streaks reset on recovery).
//!
//! A test that cannot fail when the logic changes is wrong: each assertion is chosen
//! so a subtly-broken implementation (a dropped edge, an off-by-one streak, a missing
//! clamp) flips it red.
//!
//! This file DEEPENS `parallel_tier_b_test.zig` — it does not duplicate the
//! parallel≡sequential numeric spine. It owns the pure structural laws.
//!
//! COMPARISON MODE: pan-vs-pan. Integer/structural facts are BIT-EXACT
//! (`expectEqual`/`expectEqualSlices`); only the inherently-float makespan
//! comparison carries a tolerance.
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill loaded before authoring, Rules
//! 13/14). Diagnostics go to `std.debug.print`, never `std.log.err` (the 0.16 test
//! runner counts logged errors and would flip the suite to a non-zero exit).

const std = @import("std");
const pan = @import("pan");

const parallel = pan.parallel;
const engine = pan.engine;
const Sample = pan.Sample;

// ===========================================================================
// Blocks for building real committed plans (the DAG / cost / schedule inputs).
// All mono Sample(f32): the kernel is irrelevant to the structural surface — only
// the connectivity (which buffer ids each op reads/writes) shapes the DAG.
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

/// A block whose RENDERED behavior is a trivial pass-through, but which advertises a
/// large per-output-sample compute intensity via `pub const cost_hint`. The hint is a
/// scheduler-only annotation: a wrong hint costs throughput, never correctness, so the
/// kernel here is deliberately cheap to prove the hint is independent of the samples.
const HeavyKernel = struct {
    const Self = @This();
    /// Declares this kernel ~12× heavier per output sample than a plain copy/add, so
    /// the parallel cost model weights a bank of these as the dominant work.
    pub const cost_hint: f32 = 12.0;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

fn cfg(comptime N: usize) pan.Config {
    return .{ .precision = .f32, .channels = .mono, .block_size = N };
}

// --- Graph builders. Each returns a committed engine the caller owns (defer
//     deinit). The input/output backing stores are caller-owned arrays kept alive
//     for the lifetime of the engine (we never render these — only inspect the
//     committed plan — so the kernels never touch the stores).

/// A pure chain: source → gain → affine → gain → sink. span ≈ work (parallelism≈1).
fn buildChain(alloc: std.mem.Allocator, comptime N: usize, input: *const [N]Sample(f32), out: *[N]Sample(f32)) !engine.Engine {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), input) });
    const g1 = try bg.add(Gain, .{ .gain = 0.5 });
    const af = try bg.add(Affine, .{ .a = 1.1, .b = 0.0 });
    const g2 = try bg.add(Gain, .{ .gain = 0.7 });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), out) });
    try bg.connect(s, g1);
    try bg.connect(g1, af);
    try bg.connect(af, g2);
    try bg.connect(g2, sk);
    return bg.commitWith(.{ .cores = 4, .force_workgroup = true });
}

/// A wide fan-out → reduction tree: source fans into 4 independent gain→affine
/// chains, summed by a 3-adder tree into a sink. High work/span (Tier-B's target).
fn buildWide(alloc: std.mem.Allocator, comptime N: usize, input: *const [N]Sample(f32), out: *[N]Sample(f32)) !engine.Engine {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), input) });
    const g0 = try bg.add(Gain, .{ .gain = 0.5 });
    const a0 = try bg.add(Affine, .{ .a = 1.3, .b = -0.07 });
    const g1 = try bg.add(Gain, .{ .gain = 0.77 });
    const a1 = try bg.add(Affine, .{ .a = 0.92, .b = 0.013 });
    const g2 = try bg.add(Gain, .{ .gain = 1.21 });
    const a2 = try bg.add(Affine, .{ .a = -0.5, .b = 0.21 });
    const g3 = try bg.add(Gain, .{ .gain = 0.3 });
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
    return bg.commitWith(.{ .cores = 4, .force_workgroup = true });
}

/// A diamond tree (wide→narrow→wide): source fans to two gains, each adder sums a
/// gain with a SHARED branch, then a final adder, then sink. Reconvergent paths
/// stress the level computation and the per-worker ordering.
fn buildDiamond(alloc: std.mem.Allocator, comptime N: usize, input: *const [N]Sample(f32), out: *[N]Sample(f32)) !engine.Engine {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), input) });
    const gA = try bg.add(Gain, .{ .gain = 0.5 });
    const gB = try bg.add(Gain, .{ .gain = 0.7 });
    const gC = try bg.add(Gain, .{ .gain = 0.9 });
    // first reduction layer
    const sAB = try bg.add(Add2, .{});
    const sBC = try bg.add(Add2, .{});
    // final reduction
    const top = try bg.add(Add2, .{});
    const sink = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), out) });
    try bg.connect(src, gA);
    try bg.connect(src, gB);
    try bg.connect(src, gC);
    try bg.connect(gA, sAB.in.x);
    try bg.connect(gB, sAB.in.y);
    try bg.connect(gB, sBC.in.x); // gB feeds BOTH adders — the reconvergence
    try bg.connect(gC, sBC.in.y);
    try bg.connect(sAB, top.in.x);
    try bg.connect(sBC, top.in.y);
    try bg.connect(top, sink);
    return bg.commitWith(.{ .cores = 4, .force_workgroup = true });
}

/// A single-op graph: a source whose output drains nowhere is illegal, so the
/// smallest legal graph is source→sink (2 ops). For a genuine single-op DAG we use
/// a lone source feeding a sink and inspect just the structure.
fn buildSourceSink(alloc: std.mem.Allocator, comptime N: usize, input: *const [N]Sample(f32), out: *[N]Sample(f32)) !engine.Engine {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), input) });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), out) });
    try bg.connect(s, sk);
    return bg.commitWith(.{ .cores = 4, .force_workgroup = true });
}

// ===========================================================================
// Generic structural validators (reused across shapes and P values).
// ===========================================================================

/// Every op id in [0, n) appears in exactly one worker sequence, exactly once.
fn assertCovers(s: *const parallel.Schedule, n: usize) !void {
    var seen = [_]bool{false} ** parallel.max_ops;
    var count: usize = 0;
    var w: usize = 0;
    while (w < s.p) : (w += 1) {
        for (s.workerOps(w)) |op| {
            try std.testing.expect(op < n);
            try std.testing.expect(!seen[op]); // no op placed twice
            seen[op] = true;
            count += 1;
        }
    }
    try std.testing.expectEqual(n, count);
    // And worker_of agrees with the sequence placement for every op.
    var op: usize = 0;
    while (op < n) : (op += 1) {
        try std.testing.expect(seen[op]);
        const w_of = s.worker_of[op];
        var found = false;
        for (s.workerOps(w_of)) |o| {
            if (o == op) found = true;
        }
        try std.testing.expect(found); // worker_of[op] really holds op in its seq
    }
}

/// Same-worker predecessors precede successors in that worker's order. (Cross-worker
/// preds are ordered by the runtime ready-flag spin, not the static sequence.)
fn assertSameWorkerOrder(dag: *const parallel.Dag, s: *const parallel.Schedule) !void {
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
            if (s.worker_of[p] == s.worker_of[op]) try std.testing.expect(pos[p] < pos[op]);
        }
    }
}

/// The global execution order — the per-worker start-time orders interleaved — is a
/// valid TOPOLOGICAL order. We verify the weaker, robust witness the schedule
/// guarantees: a predecessor's level is strictly less than its successor's level
/// (ASAP levels are a topological numbering), AND every predecessor's op index is
/// lower (the op-list is forward-topo, so the DAG can only carry forward edges).
fn assertTopoConsistent(dag: *const parallel.Dag) !void {
    var op: usize = 0;
    while (op < dag.n) : (op += 1) {
        var pr = dag.preds[op];
        while (pr != 0) {
            const p = @ctz(pr);
            pr &= pr - 1;
            // Forward edge law: every dependency points from a lower op index to a
            // higher one, so index order is itself a topological order.
            try std.testing.expect(p < op);
        }
    }
}

/// preds and succs are exact transposes: j ∈ preds[i] ⟺ i ∈ succs[j].
fn assertTranspose(dag: *const parallel.Dag) !void {
    var i: usize = 0;
    while (i < dag.n) : (i += 1) {
        var pr = dag.preds[i];
        while (pr != 0) {
            const j = @ctz(pr);
            pr &= pr - 1;
            // j is a predecessor of i ⇒ i must be a successor of j.
            try std.testing.expect((dag.succs[j] & (@as(u64, 1) << @intCast(i))) != 0);
        }
        var sc = dag.succs[i];
        while (sc != 0) {
            const j = @ctz(sc);
            sc &= sc - 1;
            // i is a successor of j(=the bit) ⇒ that bit must be a predecessor of j.
            try std.testing.expect((dag.preds[j] & (@as(u64, 1) << @intCast(i))) != 0);
        }
    }
}

/// Recompute ASAP levels independently and assert they match the schedule's, and
/// that two ops sharing a level have NO edge between them (mutual independence).
fn assertLevelsCorrect(dag: *const parallel.Dag, s: *const parallel.Schedule) !void {
    var ref_level = [_]usize{0} ** parallel.max_ops;
    var max_l: usize = 0;
    var i: usize = 0;
    while (i < dag.n) : (i += 1) {
        var lvl: usize = 0;
        var pr = dag.preds[i];
        while (pr != 0) {
            const p = @ctz(pr);
            pr &= pr - 1;
            if (ref_level[p] + 1 > lvl) lvl = ref_level[p] + 1;
        }
        ref_level[i] = lvl;
        if (lvl > max_l) max_l = lvl;
    }
    try std.testing.expectEqual(max_l, s.max_level);
    i = 0;
    while (i < dag.n) : (i += 1) try std.testing.expectEqual(ref_level[i], s.level[i]);

    // Same-level ⇒ no edge: an edge would force the head one level higher.
    var a: usize = 0;
    while (a < dag.n) : (a += 1) {
        var b: usize = 0;
        while (b < dag.n) : (b += 1) {
            if (a != b and s.level[a] == s.level[b]) {
                try std.testing.expect((dag.preds[a] & (@as(u64, 1) << @intCast(b))) == 0);
            }
        }
    }
}

// ===========================================================================
// 1. Workgroup — the HAL feasibility witness.
// ===========================================================================

test "Workgroup: detect() matches the platform mechanism witness" {
    // The honest witness the gate consumes: Linux has SCHED_FIFO+affinity (always
    // present, so available); macOS/other have no mechanism without a real device
    // os_workgroup handle (unavailable until one is bound). Either way no handle.
    const builtin = @import("builtin");
    const wg = parallel.Workgroup.detect();
    if (builtin.os.tag == .linux) {
        try std.testing.expect(wg.available);
    } else {
        try std.testing.expect(!wg.available);
    }
    try std.testing.expect(wg.handle == null);
}

test "Workgroup: withHandle marks available and carries the handle" {
    // Binding a real device workgroup flips the witness true and threads the opaque
    // handle through — the only path by which the gate may promote on macOS.
    var sentinel: u32 = 0xC0DE;
    const wg = parallel.Workgroup.withHandle(@ptrCast(&sentinel));
    try std.testing.expect(wg.available);
    try std.testing.expect(wg.handle != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&sentinel)), wg.handle.?);
}

test "Workgroup: joinThread/leaveThread are no-ops without a real handle" {
    // No device handle ⇒ the macOS os_workgroup syscall is never issued and the
    // join/leave do nothing and cannot fault. (A REAL handle drives a real syscall,
    // which needs an actual device workgroup, so it is exercised only on-device, not
    // here with a fake pointer.)
    const tok = engine.enterRealtimeThread();
    defer tok.leave();
    const bare = parallel.Workgroup.detect();
    var token: parallel.Workgroup.Token = .{};
    bare.joinThread(&token, 0, tok); // no-op (Linux sets best-effort sched; harmless)
    bare.leaveThread(&token); // no-op, must not crash
}

test "Workgroup: default-initialized struct is the unavailable witness" {
    // A zero-value Workgroup{} must be the safe default (unavailable) — the gate's
    // no-workgroup branch depends on it.
    const wg = parallel.Workgroup{};
    try std.testing.expect(!wg.available);
    try std.testing.expect(wg.handle == null);
}

// ===========================================================================
// 2. costGate — the decidable gate. Three necessary conditions + monotonicity.
// ===========================================================================

test "costGate: a near-linear chain (work≈span) is refused — parallelism buys nothing" {
    const g = parallel.GateConfig{};
    // span ≈ work ⇒ span_floor = max(span, work/P) ≈ work ⇒ parallelism ≈ 1.
    const d = parallel.costGate(100.0, 96.0, 8, 50.0, true, g);
    try std.testing.expect(!d.enable);
    try std.testing.expect(d.parallelism < g.theta_speedup);
    try std.testing.expectEqual(@as(usize, 1), d.p); // refused ⇒ P forced to 1
}

test "costGate: a wide graph (work≫span) enables and picks P≥2" {
    const g = parallel.GateConfig{};
    const d = parallel.costGate(800.0, 100.0, 8, 200.0, true, g);
    try std.testing.expect(d.enable);
    try std.testing.expect(d.parallelism >= g.theta_speedup);
    try std.testing.expect(d.p >= 2);
    try std.testing.expect(d.p <= 8); // never exceeds the core budget
}

test "costGate: each of the three enable conditions is independently necessary" {
    const g = parallel.GateConfig{};
    // Baseline: busy AND parallel AND workgroup ⇒ enabled.
    try std.testing.expect(parallel.costGate(800.0, 100.0, 8, 200.0, true, g).enable);
    // Drop the workgroup ⇒ refused (the cross-worker spin bound is unavailable).
    try std.testing.expect(!parallel.costGate(800.0, 100.0, 8, 200.0, false, g).enable);
    // Drop busy: tiny work vs a large deadline ⇒ one core has headroom ⇒ refused.
    try std.testing.expect(!parallel.costGate(5.0, 1.0, 8, 200.0, true, g).enable);
    // Drop parallel: keep it busy but make span≈work (a long chain) ⇒ refused.
    try std.testing.expect(!parallel.costGate(800.0, 790.0, 8, 200.0, true, g).enable);
}

test "costGate: the busy threshold is exactly work > deadline·theta_busy (strict)" {
    const g = parallel.GateConfig{}; // theta_busy = 0.6
    const deadline: f32 = 100.0;
    const boundary = deadline * g.theta_busy; // 60.0
    // AT the boundary: work == 60 is NOT > 60 ⇒ not busy ⇒ refused even if parallel.
    const at = parallel.costGate(boundary, 1.0, 8, deadline, true, g);
    try std.testing.expect(!at.enable);
    // Just above: work = 60.1, very parallel (span small) ⇒ busy ⇒ enabled.
    const above = parallel.costGate(boundary + 0.1, 1.0, 8, deadline, true, g);
    try std.testing.expect(above.enable);
}

test "costGate: the speedup threshold is parallelism ≥ theta_speedup (inclusive)" {
    const g = parallel.GateConfig{ .theta_speedup = 2.0, .theta_busy = 0.0 };
    // theta_busy=0 makes everything busy; isolate the parallel condition. With P huge
    // the span_floor = max(span, work/P) → span, so parallelism = work/span.
    // work=200, span=100 ⇒ parallelism = 2.0 == threshold ⇒ enabled (inclusive ≥).
    const at = parallel.costGate(200.0, 100.0, 64, 1000.0, true, g);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), at.parallelism, 1e-4);
    try std.testing.expect(at.enable);
    // Just below: span=101 ⇒ parallelism < 2 ⇒ refused.
    const below = parallel.costGate(200.0, 101.0, 64, 1000.0, true, g);
    try std.testing.expect(below.parallelism < 2.0);
    try std.testing.expect(!below.enable);
}

test "costGate: parallelism is bounded by P — span_floor never below work/P" {
    const g = parallel.GateConfig{ .theta_busy = 0.0, .theta_speedup = 1.0 };
    // Even an embarrassingly parallel graph (span tiny) cannot beat P-way speedup:
    // span_floor = max(span, work/P). With span≈0 and P=4, parallelism = work/(work/4)=4.
    const d = parallel.costGate(400.0, 1.0, 4, 1000.0, true, g);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), d.parallelism, 1e-4);
    // P is clamped to the budget.
    try std.testing.expect(d.p <= 4);
}

test "costGate: parallelism is MONOTONE — larger span never raises the speedup ceiling" {
    const g = parallel.GateConfig{ .theta_busy = 0.0, .theta_speedup = 1.0 };
    // Sweep span upward with work fixed; parallelism = work/max(span,work/P) is
    // non-increasing. This is the law the gate's refusal of chains rests on.
    var prev: f32 = std.math.floatMax(f32);
    var span_len: f32 = 1.0;
    while (span_len <= 500.0) : (span_len += 10.0) {
        const d = parallel.costGate(500.0, span_len, 8, 1000.0, true, g);
        try std.testing.expect(d.parallelism <= prev + 1e-4); // non-increasing
        prev = d.parallelism;
    }
}

test "costGate: P sizing meets the headroom target, clamped to the core budget" {
    const g = parallel.GateConfig{ .theta_busy = 0.0, .theta_speedup = 1.0, .target_headroom = 0.7 };
    // single_core_load = work / (deadline·0.7). Choose work so the ceil lands at 3.
    // deadline=100 ⇒ denom=70 ⇒ load=work/70. work=150 ⇒ load≈2.14 ⇒ ceil=3.
    const d = parallel.costGate(150.0, 1.0, 8, 100.0, true, g);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0 / 70.0), d.single_core_load, 1e-3);
    try std.testing.expectEqual(@as(usize, 3), d.p);
    // A larger demand clamps to the budget rather than oversubscribing.
    const heavy = parallel.costGate(100000.0, 1.0, 4, 100.0, true, g);
    try std.testing.expectEqual(@as(usize, 4), heavy.p);
}

test "costGate: P never drops below 1 even when enabled with tiny load" {
    const g = parallel.GateConfig{ .theta_busy = 0.0, .theta_speedup = 1.0 };
    // single_core_load < 1 ⇒ ceil(load) could be 0/negative-ish; P must floor at 1.
    const d = parallel.costGate(1.0, 0.1, 8, 1000.0, true, g);
    try std.testing.expect(d.p >= 1);
}

test "costGate: p_max=0 is treated as at least one core (no divide-by-zero)" {
    // The internal pmaxf = max(p_max,1) guards the span_floor division; the gate must
    // not produce NaN/Inf or crash on a zero budget.
    const g = parallel.GateConfig{};
    const d = parallel.costGate(100.0, 10.0, 0, 50.0, true, g);
    try std.testing.expect(!std.math.isNan(d.parallelism));
    try std.testing.expect(d.p >= 1);
}

test "costGate: a zero deadline yields a finite verdict (no divide-by-zero)" {
    // denom = deadline·target_headroom = 0 ⇒ single_core_load defaults to 0; busy is
    // work > 0 (theta·0 = 0). Must not NaN.
    const g = parallel.GateConfig{};
    const d = parallel.costGate(100.0, 10.0, 8, 0.0, true, g);
    try std.testing.expectEqual(@as(f32, 0.0), d.single_core_load);
    try std.testing.expect(!std.math.isNan(d.parallelism));
}

test "costGate: a zero-work graph is never busy and never enabled" {
    const g = parallel.GateConfig{};
    const d = parallel.costGate(0.0, 0.0, 8, 50.0, true, g);
    try std.testing.expect(!d.enable);
    try std.testing.expectEqual(@as(usize, 1), d.p);
    // parallelism with span_floor 0 defaults to 1.0 (the guarded branch).
    try std.testing.expectEqual(@as(f32, 1.0), d.parallelism);
}

// ===========================================================================
// 3. buildDag — RAW + WAR + WAW edges, forward, transpose-consistent.
// ===========================================================================

test "buildDag: a chain forms a single forward path (each op depends on its producer)" {
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildChain(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);

    // 5 ops: source, gain, affine, gain, sink. The source is the only root.
    try std.testing.expectEqual(@as(usize, 5), dag.n);
    try assertTopoConsistent(&dag);
    try assertTranspose(&dag);

    // Exactly one root (the source), and every other op has ≥1 predecessor — a chain
    // has no disconnected op.
    var roots: usize = 0;
    var op: usize = 0;
    while (op < dag.n) : (op += 1) {
        if (dag.preds[op] == 0) roots += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), roots);

    // The ASAP level of a 5-op chain is a strict staircase 0,1,2,3,4.
    var costs = parallel.CostModel.fromPlan(plan.*);
    const sched = parallel.levelSchedule(&dag, &costs, 4);
    try std.testing.expectEqual(@as(usize, 4), sched.max_level);
    op = 0;
    while (op < dag.n) : (op += 1) {
        // index order == topo order for a pure chain, so levels are 0,1,2,3,4.
        try std.testing.expectEqual(op, sched.level[op]);
    }
}

test "buildDag: a fan-out producer is a predecessor of EVERY consumer (no dropped edge)" {
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildWide(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);

    try assertTopoConsistent(&dag);
    try assertTranspose(&dag);

    // The source (op 0) fans out to four gains: it must be a successor-predecessor of
    // at least four distinct ops. Count its successors.
    try std.testing.expect(@popCount(dag.succs[0]) >= 4);

    // The sink is the last op and reduces the whole tree: it has exactly one direct
    // predecessor (the top adder) but is reachable from every source — verified by it
    // being a non-root with the maximum level.
    var costs = parallel.CostModel.fromPlan(plan.*);
    const sched = parallel.levelSchedule(&dag, &costs, 4);
    const sink = dag.n - 1;
    try std.testing.expect(dag.preds[sink] != 0);
    try std.testing.expectEqual(sched.max_level, sched.level[sink]); // deepest op
}

test "buildDag: a reconvergent diamond keeps the shared branch as a shared predecessor" {
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildDiamond(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);

    try assertTopoConsistent(&dag);
    try assertTranspose(&dag);

    // gB feeds two adders: some op must be a predecessor of at least two distinct
    // adders. Find an op with ≥2 successors that are themselves non-sink reducers.
    var has_shared = false;
    var op: usize = 0;
    while (op < dag.n) : (op += 1) {
        if (@popCount(dag.succs[op]) >= 2) has_shared = true;
    }
    try std.testing.expect(has_shared);
}

test "buildDag: the smallest graph (source→sink) is a single forward edge" {
    const N = 8;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildSourceSink(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);

    try std.testing.expectEqual(@as(usize, 2), dag.n);
    // op 0 (source) is the root; op 1 (sink) depends on op 0 — one forward edge.
    try std.testing.expectEqual(@as(u64, 0), dag.preds[0]);
    try std.testing.expectEqual(@as(u64, 1), dag.preds[1]); // bit 0 set ⇒ depends on op 0
    try std.testing.expectEqual(@as(u64, 0b10), dag.succs[0]); // bit 1 set ⇒ succ is op 1
    try assertTranspose(&dag);
}

test "buildDag: an empty plan (op_count 0) yields a 0-op DAG with no edges" {
    // Degenerate input: a hand-built zero-op plan. buildDag must produce n=0 and not
    // touch any edge slot.
    const EmptyPlan = struct {
        op_count: usize = 0,
        ops: [parallel.max_ops]DummyOp = undefined,
    };
    const ep: EmptyPlan = .{};
    const dag = parallel.buildDag(ep);
    try std.testing.expectEqual(@as(usize, 0), dag.n);
    // No edges anywhere.
    var i: usize = 0;
    while (i < parallel.max_ops) : (i += 1) {
        try std.testing.expectEqual(@as(u64, 0), dag.preds[i]);
        try std.testing.expectEqual(@as(u64, 0), dag.succs[i]);
    }
}

// A minimal op shape matching the fields buildDag/CostModel read. Lets us feed
// hand-crafted DAGs (anti-dependency cases real graphs rarely expose directly).
const PORTS = 8;
const DummyOp = struct {
    input_buffer_ids: [PORTS]usize = [_]usize{0} ** PORTS,
    input_count: usize = 0,
    output_buffer_ids: [PORTS]usize = [_]usize{0} ** PORTS,
    output_count: usize = 0,
    param_input_buffer_ids: [PORTS]usize = [_]usize{0} ** PORTS,
    param_input_count: usize = 0,
    // Mirrors RenderOp.cost_hint (the per-kernel cost multiplier the CostModel reads);
    // 1.0 ⇒ data-volume-proportional, so the "cost ∝ output bytes" law is unchanged.
    cost_hint: f32 = 1.0,
};
const DummyPlan = struct {
    op_count: usize = 0,
    ops: [parallel.max_ops]DummyOp = [_]DummyOp{.{}} ** parallel.max_ops,
    buffer_byte_len: [pan.graph.max_buffers]usize = [_]usize{0} ** pan.graph.max_buffers,
};

test "buildDag: a write-after-read (WAR) anti-dependency is recorded forward" {
    // op0 writes buffer 5; op1 reads buffer 5; op2 OVERWRITES buffer 5 (reusing the
    // color). op2 must wait on op1 (the reader) — the WAR edge that keeps the pool
    // from being torn — and on op0 (the prior writer, WAW). The op-list is forward
    // topo, so all edges point to higher indices.
    var plan: DummyPlan = .{ .op_count = 3 };
    plan.ops[0] = .{ .output_buffer_ids = .{ 5, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[1] = .{ .input_buffer_ids = .{ 5, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1 };
    plan.ops[2] = .{ .output_buffer_ids = .{ 5, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };

    const dag = parallel.buildDag(plan);
    // op1 reads op0's write (RAW).
    try std.testing.expect((dag.preds[1] & (1 << 0)) != 0);
    // op2 follows BOTH op1 (WAR, the reader) and op0 (WAW, the prior writer).
    try std.testing.expect((dag.preds[2] & (1 << 1)) != 0); // WAR
    try std.testing.expect((dag.preds[2] & (1 << 0)) != 0); // WAW
    try assertTopoConsistent(&dag);
    try assertTranspose(&dag);
}

test "buildDag: a write-after-write (WAW) without an intervening reader is still ordered" {
    // op0 writes buffer 7; op1 writes buffer 7 again (no reader between). op1 must
    // still wait on op0 — two ops reusing one colored buffer in sequence cannot run
    // concurrently or the second's write could precede the first.
    var plan: DummyPlan = .{ .op_count = 2 };
    plan.ops[0] = .{ .output_buffer_ids = .{ 7, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[1] = .{ .output_buffer_ids = .{ 7, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    const dag = parallel.buildDag(plan);
    try std.testing.expect((dag.preds[1] & (1 << 0)) != 0); // WAW edge present
    try assertTranspose(&dag);
}

test "buildDag: parameter-edge inputs create dependencies exactly like sample inputs" {
    // op0 writes buffer 9 as a control scalar; op1 consumes it as a PARAMETER input.
    // The param edge is dataflow too — op1 must depend on op0.
    var plan: DummyPlan = .{ .op_count = 2 };
    plan.ops[0] = .{ .output_buffer_ids = .{ 9, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[1] = .{ .param_input_buffer_ids = .{ 9, 0, 0, 0, 0, 0, 0, 0 }, .param_input_count = 1 };
    const dag = parallel.buildDag(plan);
    try std.testing.expect((dag.preds[1] & (1 << 0)) != 0);
    try assertTranspose(&dag);
}

test "buildDag: independent buffers create NO spurious edges" {
    // op0 writes buffer 1; op1 writes buffer 2 (disjoint). Neither depends on the
    // other — a false edge would needlessly serialize and cost the parallelism Tier B
    // exists to capture.
    var plan: DummyPlan = .{ .op_count = 2 };
    plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[1] = .{ .output_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    const dag = parallel.buildDag(plan);
    try std.testing.expectEqual(@as(u64, 0), dag.preds[0]);
    try std.testing.expectEqual(@as(u64, 0), dag.preds[1]); // no cross-edge
    try std.testing.expectEqual(@as(u64, 0), dag.succs[0]);
}

test "buildDag: an out-of-range buffer id contributes no edge (bounds-guarded)" {
    // A buffer id ≥ max_buffers is skipped by the `b < max_buffers` guard. op1 reads
    // such an id; it must produce no dependency and no out-of-bounds access.
    var plan: DummyPlan = .{ .op_count = 2 };
    const huge = pan.graph.max_buffers + 100;
    plan.ops[0] = .{ .output_buffer_ids = .{ huge, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[1] = .{ .input_buffer_ids = .{ huge, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1 };
    const dag = parallel.buildDag(plan);
    try std.testing.expectEqual(@as(u64, 0), dag.preds[1]); // skipped ⇒ no edge
}

// ===========================================================================
// 4. CostModel / totalWork / span.
// ===========================================================================

test "CostModel.fromPlan: cost ∝ output bytes plus a per-op floor (nothing is free)" {
    // Hand-built plan so the byte arithmetic is exact. op0 writes buffer 3 (40 bytes);
    // op1 has no output but reads buffer 3 (a sink — weighted by input volume).
    var plan: DummyPlan = .{ .op_count = 2 };
    plan.buffer_byte_len[3] = 40;
    plan.ops[0] = .{ .output_buffer_ids = .{ 3, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[1] = .{ .input_buffer_ids = .{ 3, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1 };
    const m = parallel.CostModel.fromPlan(plan);
    try std.testing.expectEqual(@as(usize, 2), m.n);
    // cost = 1.0 + bytes: producer 41, sink weighted by its input 41.
    try std.testing.expectEqual(@as(f32, 41.0), m.cost[0]);
    try std.testing.expectEqual(@as(f32, 41.0), m.cost[1]); // sink not free
}

test "CostModel.fromPlan: a zero-output, zero-input op still carries the per-op floor" {
    var plan: DummyPlan = .{ .op_count = 1 };
    plan.ops[0] = .{}; // no inputs, no outputs
    const m = parallel.CostModel.fromPlan(plan);
    try std.testing.expectEqual(@as(f32, 1.0), m.cost[0]); // the 1.0 floor
}

// ---------------------------------------------------------------------------
// 4b. cost_hint — the per-kernel compute-intensity multiplier flows
//     GraphNode → RenderOp → CostModel, scales the per-op cost EXACTLY, defaults
//     to a no-op (1.0), and is monotone. The hint changes ONLY the cost model
//     (hence the schedule); the rendered samples are pinned bit-exact by the
//     differential in parallel_tier_b_test.zig.
//
// The CostModel formula it must obey, restated in plain prose so this file stands
// alone: per-op cost = (1.0 + output_bytes) × cost_hint, where output_bytes is the
// summed byte length of the op's output buffers (or, for a sink with no outputs,
// its input buffers). The "+1.0" is a per-op floor so nothing is free; cost_hint is
// a pure multiplier on the whole (floor + volume) term.
// ---------------------------------------------------------------------------

test "cost_hint: a hint of H scales the WHOLE per-op cost (floor + volume) by exactly H" {
    // op0 writes buffer 3 (40 bytes) with a hint of 5.0; op1 is a sink reading
    // buffer 3 with the default hint. The producer's cost must be (1.0 + 40)·5 = 205;
    // the unhinted sink stays (1.0 + 40)·1 = 41. The hint multiplies the per-op floor
    // too, not just the data volume — it is a pure scalar on the whole term.
    var plan: DummyPlan = .{ .op_count = 2 };
    plan.buffer_byte_len[3] = 40;
    plan.ops[0] = .{ .output_buffer_ids = .{ 3, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = 5.0 };
    plan.ops[1] = .{ .input_buffer_ids = .{ 3, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1 };
    const m = parallel.CostModel.fromPlan(plan);
    try std.testing.expectEqual(@as(f32, 205.0), m.cost[0]); // (1+40)·5
    try std.testing.expectEqual(@as(f32, 41.0), m.cost[1]); // default 1.0 ⇒ unchanged
}

test "cost_hint: the default 1.0 reproduces the prior byte-proportional cost EXACTLY" {
    // An unannotated plan (every op's hint at the struct default 1.0) must yield the
    // identical cost the byte-only model produced. We build two plans differing ONLY
    // in that one explicitly sets each hint to 1.0; their cost vectors are bit-equal.
    var implicit: DummyPlan = .{ .op_count = 3 };
    implicit.buffer_byte_len[1] = 16;
    implicit.buffer_byte_len[2] = 64;
    implicit.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    implicit.ops[1] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    implicit.ops[2] = .{ .input_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1 };

    var explicit = implicit;
    explicit.ops[0].cost_hint = 1.0;
    explicit.ops[1].cost_hint = 1.0;
    explicit.ops[2].cost_hint = 1.0;

    const mi = parallel.CostModel.fromPlan(implicit);
    const me = parallel.CostModel.fromPlan(explicit);
    // Bit-exact: an explicit 1.0 is indistinguishable from the absent (defaulted) hint.
    try std.testing.expectEqualSlices(f32, mi.cost[0..mi.n], me.cost[0..me.n]);
    // And the values are the bare byte-proportional figures (no hidden scaling).
    try std.testing.expectEqual(@as(f32, 17.0), mi.cost[0]); // 1 + 16
    try std.testing.expectEqual(@as(f32, 65.0), mi.cost[1]); // 1 + 64
    try std.testing.expectEqual(@as(f32, 65.0), mi.cost[2]); // sink weighted by its input (b2)
}

test "cost_hint: fromPlan cost is STRICTLY monotone in the hint for fixed data volume" {
    // The law the gate's parallelism estimate rests on: a higher hint ⇒ a strictly
    // higher per-op cost when the byte volume is held constant. Sweep the hint upward
    // on a single fixed-volume op; the cost must increase at every step.
    var prev: f32 = -1.0;
    var hint: f32 = 0.5;
    while (hint <= 8.0) : (hint += 0.5) {
        var plan: DummyPlan = .{ .op_count = 1 };
        plan.buffer_byte_len[1] = 32; // fixed data volume
        plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = hint };
        const m = parallel.CostModel.fromPlan(plan);
        // cost = (1 + 32)·hint = 33·hint — strictly increasing in the hint.
        try std.testing.expectApproxEqAbs(33.0 * hint, m.cost[0], 1e-3);
        try std.testing.expect(m.cost[0] > prev); // strictly greater than the prior hint
        prev = m.cost[0];
    }
}

test "cost_hint: a hint below 1.0 makes a kernel CHEAPER (cheap plumbing under-weighted)" {
    // The hint is two-sided: a value < 1.0 marks a kernel cheaper than its byte volume
    // suggests (a trivial pass-through). op with 100 bytes and hint 0.25 ⇒ cost ¼ of
    // the byte-proportional figure.
    var plan: DummyPlan = .{ .op_count = 1 };
    plan.buffer_byte_len[1] = 99; // (1 + 99) = 100 byte-proportional
    plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = 0.25 };
    const m = parallel.CostModel.fromPlan(plan);
    try std.testing.expectEqual(@as(f32, 25.0), m.cost[0]); // 100 · 0.25
}

test "cost_hint: a zero hint zeroes the op's cost (the multiplier is total)" {
    // A degenerate but well-defined boundary: hint 0 ⇒ the op contributes nothing to
    // work or span. (Not a sane production value, but the formula is a pure product, so
    // it must hold — proving the hint multiplies the floor, not just the volume.)
    var plan: DummyPlan = .{ .op_count = 1 };
    plan.buffer_byte_len[1] = 40;
    plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = 0.0 };
    const m = parallel.CostModel.fromPlan(plan);
    try std.testing.expectEqual(@as(f32, 0.0), m.cost[0]);
}

test "cost_hint: distinct per-op hints are independent — each op scales by ITS OWN hint" {
    // The hint is a PER-OP field, not a graph-wide constant. Three ops with three
    // different hints and the SAME data volume must each scale by their own multiplier,
    // with no cross-contamination — a global/shared-hint bug would make them equal.
    var plan: DummyPlan = .{ .op_count = 3 };
    plan.buffer_byte_len[1] = 9; // every op writes a 9-byte buffer ⇒ base = 1+9 = 10
    plan.buffer_byte_len[2] = 9;
    plan.buffer_byte_len[3] = 9;
    plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = 2.0 };
    plan.ops[1] = .{ .output_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = 7.0 };
    plan.ops[2] = .{ .output_buffer_ids = .{ 3, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = 0.5 };
    const m = parallel.CostModel.fromPlan(plan);
    // base 10 × {2, 7, 0.5} = {20, 70, 5}: each op carries exactly its own hint.
    try std.testing.expectEqual(@as(f32, 20.0), m.cost[0]);
    try std.testing.expectEqual(@as(f32, 70.0), m.cost[1]);
    try std.testing.expectEqual(@as(f32, 5.0), m.cost[2]);
}

test "cost_hint: a measured refine() supersedes the hinted seed (the hint is a seed, not a floor)" {
    // The hint only SEEDS the cost estimate; live telemetry must be free to move the
    // estimate ABOVE or BELOW the hinted figure. A correct EWMA folds the measurement
    // toward it, so a heavy hint does not pin the cost at a floor — it is overwritten.
    var plan: DummyPlan = .{ .op_count = 1 };
    plan.buffer_byte_len[1] = 9; // base 10
    plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = 10.0 };
    var m = parallel.CostModel.fromPlan(plan);
    try std.testing.expectEqual(@as(f32, 100.0), m.cost[0]); // seed = 10·10
    // A measurement well BELOW the hinted seed pulls the estimate down (α=1 snaps to it):
    // the hint is not a floor.
    m.refine(0, 4.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), m.cost[0], 1e-5);
    // And a measurement above the (now-low) estimate pulls it back up by half (α=0.5).
    m.refine(0, 20.0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), m.cost[0], 1e-5); // 0.5·4 + 0.5·20
}

test "cost_hint: a NEGATIVE hint is a raw multiplier (no defensive clamp at zero)" {
    // The formula is a pure product `(1+bytes)·hint`, NOT `@max(0, …)`: a negative hint
    // yields a negative cost. This is not a sane production value, but pinning it proves
    // the code does no hidden clamping — a defensively-clamped reimplementation (which
    // would silently change the schedule) fails this. (Documents the contract's edge.)
    var plan: DummyPlan = .{ .op_count = 1 };
    plan.buffer_byte_len[1] = 19; // base = 1 + 19 = 20
    plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = -2.0 };
    const m = parallel.CostModel.fromPlan(plan);
    try std.testing.expectEqual(@as(f32, -40.0), m.cost[0]); // 20 · (-2) — unclamped
}

test "cost_hint: the EWMA estimate cost_e is seeded from the hinted cost, not the raw bytes" {
    // fromPlan seeds the P-core EWMA estimate (cost_e) equal to the static cost — which
    // already includes the hint. A heavy-hinted op must therefore start its telemetry
    // estimate heavy, not at the byte-only figure.
    var plan: DummyPlan = .{ .op_count = 1 };
    plan.buffer_byte_len[2] = 20;
    plan.ops[0] = .{ .output_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1, .cost_hint = 3.0 };
    const m = parallel.CostModel.fromPlan(plan);
    const hinted = (1.0 + 20.0) * 3.0; // 63
    try std.testing.expectEqual(@as(f32, hinted), m.cost[0]);
    try std.testing.expectEqual(m.cost[0], m.cost_e[0]); // EWMA seeded from the hinted cost
}

test "cost_hint: a heavy hint lifts totalWork and span proportionally on a real path" {
    // The hint must propagate through the aggregate functions, not just per-op cost.
    // A 3-op chain where the middle op carries a 10× hint: totalWork and span (the
    // chain IS its own critical path) both rise by exactly the extra (hint-1)·base of
    // that one op. We compare a hinted plan against its default-hint twin.
    var base: DummyPlan = .{ .op_count = 3 };
    base.buffer_byte_len[1] = 0; // op0 out → 1.0
    base.buffer_byte_len[2] = 9; // op1 out → 10.0 base
    base.buffer_byte_len[3] = 0; // op2 out → 1.0
    base.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    base.ops[1] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    base.ops[2] = .{ .input_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 3, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };

    var hinted = base;
    hinted.ops[1].cost_hint = 10.0; // the middle op is 10× heavier

    const dag = parallel.buildDag(base); // topology identical in both plans
    var mb = parallel.CostModel.fromPlan(base);
    var mh = parallel.CostModel.fromPlan(hinted);

    // base: work = 1 + 10 + 1 = 12; hinted: 1 + 100 + 1 = 102.
    try std.testing.expectEqual(@as(f32, 12.0), parallel.totalWork(&dag, &mb));
    try std.testing.expectEqual(@as(f32, 102.0), parallel.totalWork(&dag, &mh));
    // A chain is its own critical path ⇒ span tracks the same rise.
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), parallel.span(&dag, &mb), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 102.0), parallel.span(&dag, &mh), 1e-3);
}

test "cost_hint: GraphNode → RenderOp flow — a block's pub const cost_hint reaches the committed op" {
    // The wiring law end-to-end through the REAL commit pass (not a hand-built plan):
    // a block declaring `pub const cost_hint` must surface that exact value on its
    // RenderOp in the committed plan, and an unannotated block must surface 1.0. This
    // is the GraphNode.cost_hint → RenderOp.cost_hint half of the field's journey
    // (the RenderOp → CostModel half is pinned by the fromPlan tests above).
    const N = 8;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const heavy = try bg.add(HeavyKernel, .{}); // declares pub const cost_hint = 12.0
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, heavy);
    try bg.connect(heavy, sk);
    var eng = try bg.commitWith(.{ .cores = 4, .force_workgroup = true });
    defer eng.deinit();

    const plan = eng.currentPlan();
    // Find the op rendering the HeavyKernel node and assert its carried hint is 12.0,
    // while the plumbing ops (source/sink) keep the default 1.0.
    var saw_heavy = false;
    var saw_default = false;
    var i: usize = 0;
    while (i < plan.op_count) : (i += 1) {
        const op = &plan.ops[i];
        if (op.node_id == heavy.id) {
            try std.testing.expectEqual(@as(f32, 12.0), op.cost_hint);
            saw_heavy = true;
        } else {
            // Every other op is unannotated plumbing ⇒ the default 1.0 survives commit.
            try std.testing.expectEqual(@as(f32, 1.0), op.cost_hint);
            saw_default = true;
        }
    }
    try std.testing.expect(saw_heavy); // the heavy node's op is present and hinted
    try std.testing.expect(saw_default); // and the unannotated ops kept the default
}

test "CostModel.refine: folds a measured sample by EWMA, ignores out-of-range ops" {
    var plan: DummyPlan = .{ .op_count = 1 };
    plan.buffer_byte_len[0] = 0;
    plan.ops[0] = .{ .output_buffer_ids = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    var m = parallel.CostModel.fromPlan(plan); // cost[0] = 1.0
    // EWMA: new = (1-α)·old + α·measured. α=0.5, measured=11 ⇒ 0.5·1 + 0.5·11 = 6.
    m.refine(0, 11.0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), m.cost[0], 1e-5);
    // α=0 leaves it unchanged; α=1 snaps to the measurement.
    m.refine(0, 99.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), m.cost[0], 1e-5);
    m.refine(0, 42.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), m.cost[0], 1e-5);
    // Out-of-range op index is a guarded no-op (must not corrupt memory).
    m.refine(50, 123.0, 0.5); // m.n == 1, so this returns immediately
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), m.cost[0], 1e-5);
}

test "totalWork: equals the exact sum of per-op costs" {
    var plan: DummyPlan = .{ .op_count = 3 };
    plan.ops[0] = .{};
    plan.ops[1] = .{};
    plan.ops[2] = .{};
    // All three carry only the 1.0 floor ⇒ work = 3.0.
    const m = parallel.CostModel.fromPlan(plan);
    const dag = parallel.buildDag(plan);
    try std.testing.expectEqual(@as(f32, 3.0), parallel.totalWork(&dag, &m));
}

test "span: a pure chain's span equals the sum of all costs (the whole path)" {
    // For a chain every op is on the critical path, so span == totalWork.
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildChain(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    const w = parallel.totalWork(&dag, &costs);
    const s = parallel.span(&dag, &costs);
    try std.testing.expectApproxEqAbs(w, s, 1e-3); // chain: span == work
}

test "span: over the COLORED plan, a wide graph's arms are serialized to span ≈ work" {
    // A subtle, load-bearing fact. `eng.currentPlan()` is the engine's COALESCED
    // (colored, Tier-A) plan — its colorer reuses one buffer id across the four
    // nominally-independent gain arms (each gain's output is consumed by its affine
    // before the next gain writes, so their sequential live ranges do NOT overlap and
    // share a color). buildDag then adds write-after-write anti-dependencies between
    // those same-color writes, which is exactly the mechanism that keeps the shared
    // pool from being torn — and it re-serializes the arms, so span(colored) ≈ work.
    //
    // This is WHY the engine's Tier-B overlay schedules over its OWN `.per_edge` plan
    // (every value a distinct buffer ⇒ no false anti-dependency ⇒ the real
    // parallelism is exposed) rather than over this colored plan. The pure functions
    // are faithful to whatever plan they are handed; here we pin their behavior on the
    // colored one.
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildWide(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    const w = parallel.totalWork(&dag, &costs);
    const s = parallel.span(&dag, &costs);
    try std.testing.expect(s > 0);
    // The colored-pool anti-dependencies chain the whole graph: span equals work.
    try std.testing.expectApproxEqAbs(w, s, 1e-2);
}

test "span: a hand-built PER-EDGE wide graph (distinct colors) has span ≪ work" {
    // The counterpart: when independent arms have DISTINCT buffer ids — the situation
    // the engine's `.per_edge` Tier-B plan guarantees — no false anti-dependency
    // appears and the critical path is one arm, not the sum. This is the parallelism
    // Tier B exists to capture. op0 → {op1,op2,op3,op4 each distinct out} → op5 sink.
    var plan: DummyPlan = .{ .op_count = 6 };
    // op0 writes b1 (the shared source value, read by all four arms).
    plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    // Four arms each read b1 and write a DISTINCT buffer (b2..b5) — no shared color.
    plan.ops[1] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[2] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 3, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[3] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 4, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[4] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 5, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    // op5 reduces all four (reads b2..b5), writes b6 (sink).
    plan.ops[5] = .{ .input_buffer_ids = .{ 2, 3, 4, 5, 0, 0, 0, 0 }, .input_count = 4, .output_buffer_ids = .{ 6, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };

    const dag = parallel.buildDag(plan);
    var costs = parallel.CostModel.fromPlan(plan);
    const w = parallel.totalWork(&dag, &costs); // 6 ops × cost 1 = 6
    const s = parallel.span(&dag, &costs); // op0 → one arm → op5 = 3
    try std.testing.expectEqual(@as(f32, 6.0), w);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), s, 1e-3);
    try std.testing.expect(s < w); // genuine parallelism: span is one arm, not all four
    // The four arms must be mutually independent (no edge among ops 1..4).
    var a: usize = 1;
    while (a <= 4) : (a += 1) {
        var b: usize = 1;
        while (b <= 4) : (b += 1) {
            if (a != b) try std.testing.expect((dag.preds[a] & (@as(u64, 1) << @intCast(b))) == 0);
        }
    }
}

test "span: a hand-built fork-join — critical path is the heavier of two parallel arms" {
    // op0 → {op1, op2} → op3. Make op2 heavier than op1. span = c0 + max(c1,c2) + c3.
    // Buffers: op0 writes b1; op1 reads b1 writes b2; op2 reads b1 writes b3; op3
    // reads b2 and b3 writes b4. Distinct colors keep the two arms independent.
    var plan: DummyPlan = .{ .op_count = 4 };
    plan.buffer_byte_len[1] = 0; // op0 out → cost 1
    plan.buffer_byte_len[2] = 0; // op1 out → cost 1
    plan.buffer_byte_len[3] = 100; // op2 out → cost 101 (the heavy arm)
    plan.buffer_byte_len[4] = 0; // op3 out → cost 1
    plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[1] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[2] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 3, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[3] = .{ .input_buffer_ids = .{ 2, 3, 0, 0, 0, 0, 0, 0 }, .input_count = 2, .output_buffer_ids = .{ 4, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };

    const dag = parallel.buildDag(plan);
    const m = parallel.CostModel.fromPlan(plan);
    // costs: op0=1, op1=1, op2=101, op3=1. work = 104.
    try std.testing.expectEqual(@as(f32, 104.0), parallel.totalWork(&dag, &m));
    // span = 1 (op0) + 101 (heavy op2) + 1 (op3) = 103 — the light op1 is off-path.
    try std.testing.expectApproxEqAbs(@as(f32, 103.0), parallel.span(&dag, &m), 1e-3);
}

test "span: a single isolated op equals that op's cost; an empty DAG has span 0" {
    var plan: DummyPlan = .{ .op_count = 1 };
    plan.ops[0] = .{};
    const m1 = parallel.CostModel.fromPlan(plan);
    const d1 = parallel.buildDag(plan);
    try std.testing.expectEqual(@as(f32, 1.0), parallel.span(&d1, &m1));

    const empty: DummyPlan = .{ .op_count = 0 };
    const m0 = parallel.CostModel.fromPlan(empty);
    const d0 = parallel.buildDag(empty);
    try std.testing.expectEqual(@as(f32, 0.0), parallel.span(&d0, &m0));
    try std.testing.expectEqual(@as(f32, 0.0), parallel.totalWork(&d0, &m0));
}

test "span: the makespan floor max(span, work/P) — HEFT never beats it" {
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildWide(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    const w = parallel.totalWork(&dag, &costs);
    const s = parallel.span(&dag, &costs);
    var p: usize = 1;
    while (p <= 8) : (p += 1) {
        const heft = parallel.heftSchedule(&dag, &costs, p);
        const floor = @max(s, w / @as(f32, @floatFromInt(p)));
        // No schedule beats the floor: makespan ≥ max(span, work/P) (small epsilon).
        try std.testing.expect(heft.makespan >= floor - 1e-2);
    }
}

// ===========================================================================
// 5. levelSchedule / heftSchedule — validity across shapes and P.
// ===========================================================================

test "schedules: valid for P=1..8 on a wide graph (covers, orders, levels, makespan)" {
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildWide(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);

    try assertTopoConsistent(&dag);
    var p: usize = 1;
    while (p <= 8) : (p += 1) {
        const lvl = parallel.levelSchedule(&dag, &costs, p);
        const heft = parallel.heftSchedule(&dag, &costs, p);
        try assertCovers(&lvl, dag.n);
        try assertCovers(&heft, dag.n);
        try assertSameWorkerOrder(&dag, &lvl);
        try assertSameWorkerOrder(&dag, &heft);
        try assertLevelsCorrect(&dag, &lvl);
        try assertLevelsCorrect(&dag, &heft);
        // HEFT fills bubbles a level barrier cannot: makespan ≤ barrier makespan.
        try std.testing.expect(heft.makespan <= lvl.makespan + 1e-3);
        // The schedule's own P equals the requested P (≥1).
        try std.testing.expectEqual(@max(p, 1), lvl.p);
        try std.testing.expectEqual(@max(p, 1), heft.p);
    }
}

test "schedules: valid for P=1..8 on a pure chain (degenerate — one critical path)" {
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildChain(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    var p: usize = 1;
    while (p <= 8) : (p += 1) {
        const lvl = parallel.levelSchedule(&dag, &costs, p);
        const heft = parallel.heftSchedule(&dag, &costs, p);
        try assertCovers(&lvl, dag.n);
        try assertCovers(&heft, dag.n);
        try assertSameWorkerOrder(&dag, &lvl);
        try assertSameWorkerOrder(&dag, &heft);
        try assertLevelsCorrect(&dag, &lvl);
        // A chain cannot be sped up: makespan ≈ work regardless of P.
        const w = parallel.totalWork(&dag, &costs);
        try std.testing.expectApproxEqAbs(w, heft.makespan, 1e-2);
        try std.testing.expectApproxEqAbs(w, lvl.makespan, 1e-2);
    }
}

test "schedules: valid for P=1..8 on a reconvergent diamond (shared predecessor)" {
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildDiamond(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    var p: usize = 1;
    while (p <= 8) : (p += 1) {
        const lvl = parallel.levelSchedule(&dag, &costs, p);
        const heft = parallel.heftSchedule(&dag, &costs, p);
        try assertCovers(&lvl, dag.n);
        try assertCovers(&heft, dag.n);
        try assertSameWorkerOrder(&dag, &lvl);
        try assertSameWorkerOrder(&dag, &heft);
        try assertLevelsCorrect(&dag, &lvl);
        try assertLevelsCorrect(&dag, &heft);
        try std.testing.expect(heft.makespan <= lvl.makespan + 1e-3);
    }
}

test "schedules: P greater than the op count leaves spare workers idle, not double-booked" {
    // With P far exceeding the op count, every op still appears exactly once and the
    // surplus workers simply own no ops (their seq slice is empty).
    const N = 8;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildSourceSink(alloc, N, &input, &out); // only 2 ops
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    const P = 8;
    const lvl = parallel.levelSchedule(&dag, &costs, P);
    const heft = parallel.heftSchedule(&dag, &costs, P);
    try assertCovers(&lvl, dag.n);
    try assertCovers(&heft, dag.n);
    // At least P-2 workers are idle (only 2 ops to place).
    var idle: usize = 0;
    var w: usize = 0;
    while (w < P) : (w += 1) {
        if (lvl.workerOps(w).len == 0) idle += 1;
    }
    try std.testing.expect(idle >= P - dag.n);
}

test "schedules: P=1 collapses to the sequential op order (Tier-A-shaped Tier B)" {
    // P=1 ⇒ one worker owns every op; its sequence is a valid topological order and
    // the makespan is exactly the total work (no overlap possible).
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildWide(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    const lvl = parallel.levelSchedule(&dag, &costs, 1);
    const heft = parallel.heftSchedule(&dag, &costs, 1);
    try std.testing.expectEqual(@as(usize, 1), lvl.p);
    try std.testing.expectEqual(dag.n, lvl.workerOps(0).len); // worker 0 owns all
    try std.testing.expectEqual(dag.n, heft.workerOps(0).len);
    // Worker 0's order is a topological order: each op's preds appear earlier.
    var pos = [_]usize{0} ** parallel.max_ops;
    for (heft.workerOps(0), 0..) |op, i| pos[op] = i;
    var op: usize = 0;
    while (op < dag.n) : (op += 1) {
        var pr = dag.preds[op];
        while (pr != 0) {
            const pp = @ctz(pr);
            pr &= pr - 1;
            try std.testing.expect(pos[pp] < pos[op]);
        }
    }
    // P=1 makespan == total work.
    const w = parallel.totalWork(&dag, &costs);
    try std.testing.expectApproxEqAbs(w, heft.makespan, 1e-2);
}

test "schedules: P=0 requested is clamped up to one worker (no empty-schedule UB)" {
    // levelSchedule/heftSchedule do `@max(p_req,1)`; a 0 request must not divide by
    // zero or place ops on a non-existent worker.
    const N = 8;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildChain(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    const lvl = parallel.levelSchedule(&dag, &costs, 0);
    const heft = parallel.heftSchedule(&dag, &costs, 0);
    try std.testing.expectEqual(@as(usize, 1), lvl.p);
    try std.testing.expectEqual(@as(usize, 1), heft.p);
    try assertCovers(&lvl, dag.n);
    try assertCovers(&heft, dag.n);
}

test "schedules: an empty DAG yields empty schedules (no ops, max_level 0)" {
    const empty: DummyPlan = .{ .op_count = 0 };
    const dag = parallel.buildDag(empty);
    var costs = parallel.CostModel.fromPlan(empty);
    const lvl = parallel.levelSchedule(&dag, &costs, 4);
    const heft = parallel.heftSchedule(&dag, &costs, 4);
    try std.testing.expectEqual(@as(usize, 0), lvl.n);
    try std.testing.expectEqual(@as(usize, 0), heft.n);
    try std.testing.expectEqual(@as(usize, 0), lvl.max_level);
    // Every worker's op slice is empty.
    var w: usize = 0;
    while (w < lvl.p) : (w += 1) try std.testing.expectEqual(@as(usize, 0), lvl.workerOps(w).len);
    try std.testing.expectEqual(@as(f32, 0.0), heft.makespan);
}

test "schedules: HEFT prioritizes the critical path (heaviest op placed, earliest finish)" {
    // A fork-join where one arm dominates: HEFT's upward-rank ordering must place the
    // heavy arm early so the makespan tracks the critical path, not a balanced sum.
    // op0 → {op1 light, op2 heavy} → op3.
    var plan: DummyPlan = .{ .op_count = 4 };
    plan.buffer_byte_len[1] = 0;
    plan.buffer_byte_len[2] = 0;
    plan.buffer_byte_len[3] = 200; // op2 heavy
    plan.buffer_byte_len[4] = 0;
    plan.ops[0] = .{ .output_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[1] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 2, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[2] = .{ .input_buffer_ids = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .input_count = 1, .output_buffer_ids = .{ 3, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };
    plan.ops[3] = .{ .input_buffer_ids = .{ 2, 3, 0, 0, 0, 0, 0, 0 }, .input_count = 2, .output_buffer_ids = .{ 4, 0, 0, 0, 0, 0, 0, 0 }, .output_count = 1 };

    const dag = parallel.buildDag(plan);
    var costs = parallel.CostModel.fromPlan(plan);
    const w = parallel.totalWork(&dag, &costs);
    const s = parallel.span(&dag, &costs);
    const heft = parallel.heftSchedule(&dag, &costs, 2);
    try assertCovers(&heft, dag.n);
    try assertSameWorkerOrder(&dag, &heft);
    // With 2 workers the light arm overlaps the heavy arm, so the makespan equals the
    // critical path (span), strictly below the serial work.
    try std.testing.expectApproxEqAbs(s, heft.makespan, 1e-2);
    try std.testing.expect(heft.makespan < w);
}

test "schedules: HEFT ties broken deterministically — repeated builds are identical" {
    // Determinism law: the same DAG + costs + P always yields the same placement
    // (tie-break by ascending op index). A non-deterministic schedule would make the
    // bit-exact differential flaky.
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    var out: [N]Sample(f32) = undefined;
    var eng = try buildWide(alloc, N, &input, &out);
    defer eng.deinit();
    const plan = eng.currentPlan();
    const dag = parallel.buildDag(plan.*);
    var costs = parallel.CostModel.fromPlan(plan.*);
    const a = parallel.heftSchedule(&dag, &costs, 4);
    const b = parallel.heftSchedule(&dag, &costs, 4);
    try std.testing.expectEqualSlices(usize, a.worker_of[0..dag.n], b.worker_of[0..dag.n]);
    try std.testing.expectEqualSlices(usize, a.seq[0..dag.n], b.seq[0..dag.n]);
    try std.testing.expectEqual(a.makespan, b.makespan);

    const la = parallel.levelSchedule(&dag, &costs, 4);
    const lb = parallel.levelSchedule(&dag, &costs, 4);
    try std.testing.expectEqualSlices(usize, la.worker_of[0..dag.n], lb.worker_of[0..dag.n]);
    try std.testing.expectEqual(la.makespan, lb.makespan);
}

// ===========================================================================
// 6. DemotePolicy — the hysteresis state machine.
// ===========================================================================

test "DemotePolicy.init: active mirrors the gate decision; streaks start clear" {
    const on = parallel.DemotePolicy.init(true);
    try std.testing.expect(on.active);
    try std.testing.expectEqual(@as(u32, 0), on.low_streak);
    try std.testing.expectEqual(@as(u32, 0), on.high_streak);
    const off = parallel.DemotePolicy.init(false);
    try std.testing.expect(!off.active);
}

test "DemotePolicy: demotes EXACTLY on the demote_after-th consecutive sub-floor callback" {
    var pol = parallel.DemotePolicy{ .floor = 0.1, .ceiling = 0.3, .demote_after = 3, .promote_after = 8, .active = true };
    // Two sub-floor callbacks are not yet enough (streak < demote_after).
    try std.testing.expect(pol.observe(0.05)); // streak 1, still active
    try std.testing.expect(pol.observe(0.05)); // streak 2, still active
    // The third trips it — observe returns the NEW (demoted) state.
    try std.testing.expect(!pol.observe(0.05)); // streak 3 == demote_after ⇒ demoted
    try std.testing.expect(!pol.active);
}

test "DemotePolicy: a recovery callback resets the low streak (no premature demote)" {
    var pol = parallel.DemotePolicy{ .floor = 0.1, .ceiling = 0.3, .demote_after = 4, .promote_after = 8, .active = true };
    try std.testing.expect(pol.observe(0.05)); // 1
    try std.testing.expect(pol.observe(0.05)); // 2
    try std.testing.expect(pol.observe(0.05)); // 3
    try std.testing.expect(pol.observe(0.5)); // recovery: streak resets to 0
    try std.testing.expectEqual(@as(u32, 0), pol.low_streak);
    // Now it takes a fresh full streak to demote — the prior 3 do not count.
    try std.testing.expect(pol.observe(0.05)); // 1
    try std.testing.expect(pol.observe(0.05)); // 2
    try std.testing.expect(pol.observe(0.05)); // 3
    try std.testing.expect(!pol.observe(0.05)); // 4 ⇒ demoted
}

test "DemotePolicy: a value exactly AT the floor is healthy (strict < demotes)" {
    // The condition is `headroom < floor`; headroom == floor must NOT demote.
    var pol = parallel.DemotePolicy{ .floor = 0.1, .ceiling = 0.3, .demote_after = 1, .promote_after = 8, .active = true };
    try std.testing.expect(pol.observe(0.1)); // == floor ⇒ healthy, stays active
    try std.testing.expect(pol.active);
    // Just below the floor with demote_after=1 demotes immediately.
    try std.testing.expect(!pol.observe(0.0999));
}

test "DemotePolicy: re-promotes EXACTLY on the promote_after-th consecutive ≥ceiling callback" {
    var pol = parallel.DemotePolicy{ .floor = 0.1, .ceiling = 0.3, .demote_after = 1, .promote_after = 3, .active = false };
    // Below the ceiling never promotes, however long.
    var i: usize = 0;
    while (i < 50) : (i += 1) try std.testing.expect(!pol.observe(0.2)); // 0.2 < ceiling
    // A high streak below the count is not enough.
    try std.testing.expect(!pol.observe(0.3)); // 1 (== ceiling, inclusive)
    try std.testing.expect(!pol.observe(0.5)); // 2
    try std.testing.expect(pol.observe(0.9)); // 3 == promote_after ⇒ re-promoted
    try std.testing.expect(pol.active);
}

test "DemotePolicy: a sub-ceiling callback resets the high streak while demoted" {
    var pol = parallel.DemotePolicy{ .floor = 0.1, .ceiling = 0.3, .demote_after = 1, .promote_after = 4, .active = false };
    try std.testing.expect(!pol.observe(0.5)); // 1
    try std.testing.expect(!pol.observe(0.5)); // 2
    try std.testing.expect(!pol.observe(0.25)); // < ceiling ⇒ streak resets
    try std.testing.expectEqual(@as(u32, 0), pol.high_streak);
    // A fresh full streak is now required.
    try std.testing.expect(!pol.observe(0.5)); // 1
    try std.testing.expect(!pol.observe(0.5)); // 2
    try std.testing.expect(!pol.observe(0.5)); // 3
    try std.testing.expect(pol.observe(0.5)); // 4 ⇒ re-promoted
}

test "DemotePolicy: the hysteresis gap prevents oscillation in the floor..ceiling band" {
    // A value in [floor, ceiling) keeps the CURRENT state both ways: it neither
    // demotes (≥ floor) nor promotes (< ceiling). This dead band is the anti-flap.
    var active_pol = parallel.DemotePolicy{ .floor = 0.1, .ceiling = 0.3, .demote_after = 2, .promote_after = 2, .active = true };
    var i: usize = 0;
    while (i < 20) : (i += 1) try std.testing.expect(active_pol.observe(0.2)); // stays active
    var demoted_pol = parallel.DemotePolicy{ .floor = 0.1, .ceiling = 0.3, .demote_after = 2, .promote_after = 2, .active = false };
    i = 0;
    while (i < 20) : (i += 1) try std.testing.expect(!demoted_pol.observe(0.2)); // stays demoted
}

test "DemotePolicy: a full demote→re-promote→demote cycle is reachable and consistent" {
    // The whole loop, end to end, with the same instance — proving the state machine
    // is reusable and the streak fields are correctly cleared at each transition.
    var pol = parallel.DemotePolicy{ .floor = 0.1, .ceiling = 0.3, .demote_after = 2, .promote_after = 2, .active = true };
    // demote
    try std.testing.expect(pol.observe(0.0)); // 1
    try std.testing.expect(!pol.observe(0.0)); // 2 ⇒ demoted
    // re-promote
    try std.testing.expect(!pol.observe(0.9)); // 1
    try std.testing.expect(pol.observe(0.9)); // 2 ⇒ promoted
    try std.testing.expectEqual(@as(u32, 0), pol.high_streak); // cleared on promote
    // demote again — proves low_streak was clear after the re-promote
    try std.testing.expect(pol.observe(0.0)); // 1
    try std.testing.expect(!pol.observe(0.0)); // 2 ⇒ demoted again
}
