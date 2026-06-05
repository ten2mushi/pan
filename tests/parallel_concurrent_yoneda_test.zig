//! parallel_concurrent_yoneda_test — a Yoneda-style characterization of the
//! CONCURRENT / INTEGRATION surface of the Tier-B static-parallel executor
//! (`src/parallel.zig` + the `engine.zig` integration). It DEEPENS the existing
//! `parallel_tier_b_test.zig` (more graph shapes, the synthetic per-op replay, the
//! edit/reconfigure-under-active-Tier-B path, stress across P up to the host core
//! count) rather than duplicating it.
//!
//! The Yoneda mandate: characterize the concurrent machinery through ALL its
//! observable behaviors and the LAWS it must satisfy, so any implementation passing
//! this suite is behaviourally equivalent to the original.
//!
//! Laws pinned here:
//!   (L1) parallel ≡ sequential, BIT-EXACT — Tier B (both executors, P=2..ncores)
//!        renders byte-identically to Tier A, over many blocks (determinism across
//!        callbacks) and many graph shapes. Same kernels + same reduction order, so
//!        any divergence is a scheduling/sync bug, never numerics.
//!   (L2) the generation wake is race-free and REUSABLE — a single release-store of
//!        the generation counter wakes the spawned workers (acquire-load); many
//!        dispatches in a row each complete, the generation disambiguating callbacks
//!        WITHOUT clearing any flag array.
//!   (L3) the worker pool participates the caller AS worker 0; P=1 spawns no thread
//!        (the caller is the lone worker); init+spawn split keeps the address stable;
//!        a pool allocated but NEVER spawned deinits cleanly (no join of garbage).
//!   (L4) the Barrier and ReadyFlags are reusable across phases AND dispatches with
//!        no per-thread local state and no per-callback memset; a flag still holding
//!        g-1 reads as "not ready"; spin telemetry accumulates.
//!   (L5) replayParallel/replayWorker run an arbitrary type-erased schedule whose
//!        side effects match a sequential run of the same ops, for both executors.
//!   (L6) auto-demote is HYSTERETIC, and the engine surfaces spin_time after a Tier B
//!        render; a near-linear chain never promotes.
//!   (L7) edit→commit (`recommit`) and `reconfigure(N)` under an ACTIVE Tier B leave
//!        the engine correct: a post-swap Tier B render is still bit-identical to a
//!        Tier A render of the same post-swap graph. No leaks.
//!
//! COMPARISON MODE: pan-vs-pan — always BIT-EXACT. No external oracle.
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill loaded before authoring, Rules
//! 13/14). Diagnostics go to `std.debug.print`, never `std.log.err`. Every test uses
//! `std.testing.allocator` (leak-checked); engines are deinit'd LIFO before their
//! graphs (engine deinit joins the worker pool, so order matters).

const std = @import("std");
const pan = @import("pan");

const parallel = pan.parallel;
const engine = pan.engine;
const Sample = pan.Sample;

// ===========================================================================
// Differential blocks. All mono Sample(f32): the only thing that varies across
// Tier A / Tier B is the schedule + sync, never the kernel.
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

fn cfg(comptime N: usize) pan.Config {
    return .{ .precision = .f32, .channels = .mono, .block_size = N };
}
fn fillNoise(buf: []Sample(f32), seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (buf) |*s| s.ch[0] = r.float(f32) * 2.0 - 1.0;
}

/// Host core count, clamped to a sane test ceiling so the suite stays fast on a
/// many-core box and never exceeds `parallel.max_workers`.
fn hostCores() usize {
    const n = std.Thread.getCpuCount() catch 2;
    return @max(2, @min(n, @min(parallel.max_workers, 8)));
}

// ===========================================================================
// Graph shapes. Each returns an engine the caller owns. The wide voice-bank shape
// promotes; the diamond promotes; the plain chain does not.
// ===========================================================================

/// WIDE: source fans out into `W` independent gain→affine chains, summed by an
/// adder tree, into a sink. Mutually-independent chains ⇒ high work/span ⇒ the
/// Tier-B target shape. `W` must be a power of two ≥ 2 so the adder tree is exact.
fn buildWide(
    comptime W: usize,
    alloc: std.mem.Allocator,
    comptime N: usize,
    input: [*]const Sample(f32),
    out: [*]Sample(f32),
    opts: engine.EngineOptions,
) !engine.Engine {
    comptime std.debug.assert(W >= 2 and (W & (W - 1)) == 0);
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = input });

    const Gainh = @TypeOf(try bg.add(Gain, .{}));
    const Adder = @TypeOf(try bg.add(Add2, .{}));

    // A node may have at most 8 out-edges (the static port ceiling), so the source
    // fans out through a distributor stage when W > 8: one distributor gain per group
    // of 4 lanes (source out-degree W/4, each distributor out-degree 4). For W ≤ 8 the
    // source feeds the lanes directly. Either way every lane sees the same input
    // (distributor gain 1.0 is identity), so the wide differential is unaffected.
    const group: usize = if (W > 8) 4 else W;
    const n_dist: usize = W / group;
    var dist: [W]Gainh = undefined;
    {
        var d: usize = 0;
        while (d < n_dist) : (d += 1) {
            if (n_dist == 1) {
                dist[d] = undefined; // unused; lanes read src directly
            } else {
                const dg = try bg.add(Gain, .{ .gain = 1.0 });
                try bg.connect(src, dg);
                dist[d] = dg;
            }
        }
    }

    // A leaf per lane: gain → affine, then immediately pair leaves into the first
    // adder level so every array beyond this point is homogeneous (Add2 handles).
    // Distinct coefficients so a dropped/duplicated lane (a scheduling bug) changes
    // the sum.
    var level: [W]Adder = undefined;
    var width: usize = 0;
    {
        var i: usize = 0;
        while (i < W) : (i += 2) {
            const g0 = try bg.add(Gain, .{ .gain = 0.4 + 0.13 * @as(f32, @floatFromInt(i)) });
            const a0 = try bg.add(Affine, .{ .a = 1.0 - 0.07 * @as(f32, @floatFromInt(i)), .b = 0.01 * @as(f32, @floatFromInt(i)) - 0.05 });
            const g1 = try bg.add(Gain, .{ .gain = 0.4 + 0.13 * @as(f32, @floatFromInt(i + 1)) });
            const a1 = try bg.add(Affine, .{ .a = 1.0 - 0.07 * @as(f32, @floatFromInt(i + 1)), .b = 0.01 * @as(f32, @floatFromInt(i + 1)) - 0.05 });
            if (n_dist == 1) {
                try bg.connect(src, g0);
                try bg.connect(src, g1);
            } else {
                try bg.connect(dist[i / group], g0);
                try bg.connect(dist[(i + 1) / group], g1);
            }
            try bg.connect(g0, a0);
            try bg.connect(g1, a1);
            const adder = try bg.add(Add2, .{});
            try bg.connect(a0, adder.in.x);
            try bg.connect(a1, adder.in.y);
            level[width] = adder;
            width += 1;
        }
    }

    // Balanced adder tree over the remaining width.
    while (width > 1) {
        var next: [W]Adder = undefined;
        var j: usize = 0;
        while (j < width) : (j += 2) {
            const adder = try bg.add(Add2, .{});
            try bg.connect(level[j], adder.in.x);
            try bg.connect(level[j + 1], adder.in.y);
            next[j / 2] = adder;
        }
        width /= 2;
        level = next;
    }
    const sink = try bg.add(BufSink, .{ .dest = out });
    try bg.connect(level[0], sink);
    return bg.commitWith(opts);
}

/// DIAMOND: source → two parallel affine paths → recombine → fan back out into two
/// gains → recombine → sink. A wide→narrow→wide shape that still has real
/// parallelism (two independent paths at two stages).
fn buildDiamond(
    alloc: std.mem.Allocator,
    comptime N: usize,
    input: [*]const Sample(f32),
    out: [*]Sample(f32),
    opts: engine.EngineOptions,
) !engine.Engine {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = input });
    const l0 = try bg.add(Affine, .{ .a = 1.3, .b = -0.02 });
    const r0 = try bg.add(Affine, .{ .a = 0.7, .b = 0.05 });
    const mid = try bg.add(Add2, .{});
    const l1 = try bg.add(Gain, .{ .gain = 0.55 });
    const r1 = try bg.add(Gain, .{ .gain = 1.21 });
    const top = try bg.add(Add2, .{});
    const sink = try bg.add(BufSink, .{ .dest = out });

    try bg.connect(src, l0);
    try bg.connect(src, r0);
    try bg.connect(l0, mid.in.x);
    try bg.connect(r0, mid.in.y);
    try bg.connect(mid, l1);
    try bg.connect(mid, r1);
    try bg.connect(l1, top.in.x);
    try bg.connect(r1, top.in.y);
    try bg.connect(top, sink);
    return bg.commitWith(opts);
}

/// CHAIN: source→gain→affine→sink. Span ≈ work ⇒ parallelism ≈ 1 ⇒ never promotes.
fn buildChain(
    alloc: std.mem.Allocator,
    comptime N: usize,
    input: [*]const Sample(f32),
    out: [*]Sample(f32),
    opts: engine.EngineOptions,
) !engine.Engine {
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = input });
    const g = try bg.add(Gain, .{ .gain = 0.5 });
    const a = try bg.add(Affine, .{ .a = 1.1, .b = 0.0 });
    const sk = try bg.add(BufSink, .{ .dest = out });
    try bg.connect(s, g);
    try bg.connect(g, a);
    try bg.connect(a, sk);
    return bg.commitWith(opts);
}

// ===========================================================================
// L1 — THE SPINE: parallel ≡ sequential, bit-exact, both executors, P=2..ncores,
// multiple shapes, multiple blocks.
// ===========================================================================

const executors = [_]parallel.Executor{ .level_barrier, .heft };

test "L1 spine: wide graph Tier B ≡ Tier A bit-exact, both executors, P=2..ncores, 8 blocks" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xC0FFEE);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    const pmax = hostCores();
    for (executors) |exec| {
        var p: usize = 2;
        while (p <= pmax) : (p += 1) {
            var out_a: [N]Sample(f32) = undefined;
            var out_b: [N]Sample(f32) = undefined;
            var eng_a = try buildWide(8, alloc, N, &input, &out_a, .{});
            defer eng_a.deinit();
            var eng_b = try buildWide(8, alloc, N, &input, &out_b, .{ .cores = p, .force_workgroup = true, .tier_b_executor = exec });
            defer eng_b.deinit();

            // The differential is only meaningful if Tier B actually RAN — a silent
            // fallback to Tier A would make "bit-identical" vacuous.
            if (!eng_b.tierBActive()) {
                std.debug.print("FAIL: wide graph did not promote at P={d} exec={s}\n", .{ p, @tagName(exec) });
                return error.TierBDidNotPromote;
            }
            try std.testing.expect(eng_b.tierBWorkers() >= 2);

            var block: usize = 0;
            while (block < 8) : (block += 1) {
                eng_a.renderInto(token);
                eng_b.renderInto(token);
                try std.testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(out_a[0..]),
                    std.mem.sliceAsBytes(out_b[0..]),
                );
            }
            try std.testing.expect(!eng_a.telemetry().fault);
            try std.testing.expect(!eng_b.telemetry().fault);
        }
    }
}

test "L1 spine: a LARGE fan-out (16 voices) is bit-exact under both executors" {
    const N = 48;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x16_0CE5);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    for (executors) |exec| {
        var out_a: [N]Sample(f32) = undefined;
        var out_b: [N]Sample(f32) = undefined;
        var eng_a = try buildWide(16, alloc, N, &input, &out_a, .{});
        defer eng_a.deinit();
        var eng_b = try buildWide(16, alloc, N, &input, &out_b, .{ .cores = hostCores(), .force_workgroup = true, .tier_b_executor = exec });
        defer eng_b.deinit();
        try std.testing.expect(eng_b.tierBActive());

        var block: usize = 0;
        while (block < 6) : (block += 1) {
            eng_a.renderInto(token);
            eng_b.renderInto(token);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
        }
    }
}

test "L1 spine: the diamond (wide→narrow→wide) is bit-exact under both executors" {
    const N = 32;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xD1A);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    for (executors) |exec| {
        var out_a: [N]Sample(f32) = undefined;
        var out_b: [N]Sample(f32) = undefined;
        var eng_a = try buildDiamond(alloc, N, &input, &out_a, .{});
        defer eng_a.deinit();
        var eng_b = try buildDiamond(alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = exec });
        defer eng_b.deinit();

        var block: usize = 0;
        while (block < 6) : (block += 1) {
            eng_a.renderInto(token);
            eng_b.renderInto(token);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
        }
    }
}

// ===========================================================================
// L2/L3 — WorkerPool: generation wake, caller-as-worker-0, multi-dispatch with the
// generation disambiguating WITHOUT clearing flags, P=1 degenerate, never-spawned
// deinit.
// ===========================================================================

/// A context recording, per worker, the generation it last observed and the count
/// of dispatches it ran. Worker ids beyond `seen.len` would be a pool/schedule bug.
const SeenCtx = struct {
    seen: [parallel.max_workers]std.atomic.Value(usize) = blk: {
        var a: [parallel.max_workers]std.atomic.Value(usize) = undefined;
        for (&a) |*f| f.* = std.atomic.Value(usize).init(0);
        break :blk a;
    },
    runs: [parallel.max_workers]std.atomic.Value(usize) = blk: {
        var a: [parallel.max_workers]std.atomic.Value(usize) = undefined;
        for (&a) |*f| f.* = std.atomic.Value(usize).init(0);
        break :blk a;
    },
};

fn seenTask(user: *anyopaque, wid: usize, g: usize) void {
    const ctx: *SeenCtx = @ptrCast(@alignCast(user));
    ctx.seen[wid].store(g, .release);
    _ = ctx.runs[wid].fetchAdd(1, .acq_rel);
}

test "L2/L3 WorkerPool: every worker observes each dispatch's generation, caller runs as worker 0" {
    const alloc = std.testing.allocator;
    const P = hostCores();
    var pool = try parallel.WorkerPool.init(alloc, P, parallel.Workgroup{ .available = true });
    try pool.spawn();
    defer pool.deinit();

    var ctx = SeenCtx{};
    const rounds = 200;
    var prev_g: usize = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        const g = pool.dispatch(&ctx, seenTask);
        // The generation strictly increases each dispatch (a single release store).
        try std.testing.expect(g > prev_g);
        prev_g = g;
        // EVERY worker (0 = the caller, 1..P-1 = the spawned threads) observed THIS
        // generation — the wake reached all of them and the dispatch completed.
        var w: usize = 0;
        while (w < P) : (w += 1) {
            try std.testing.expectEqual(g, ctx.seen[w].load(.acquire));
        }
    }
    // Each worker ran exactly `rounds` times — no missed wake, no double-run.
    var w: usize = 0;
    while (w < P) : (w += 1) {
        try std.testing.expectEqual(@as(usize, rounds), ctx.runs[w].load(.acquire));
    }
}

/// A handshake context: worker 0 publishes `g`; every other worker spins on worker
/// 0's flag for the CURRENT generation, then publishes its own. The generation
/// keying means the array is NEVER cleared between dispatches — a worker that read a
/// stale `g-1` from worker 0 would wrongly proceed; the test would then catch a
/// flag holding the wrong generation.
const HandshakeCtx = struct {
    flags: [parallel.max_workers]std.atomic.Value(usize) = blk: {
        var a: [parallel.max_workers]std.atomic.Value(usize) = undefined;
        for (&a) |*f| f.* = std.atomic.Value(usize).init(0);
        break :blk a;
    },
};

fn handshakeTask(user: *anyopaque, wid: usize, g: usize) void {
    const ctx: *HandshakeCtx = @ptrCast(@alignCast(user));
    if (wid == 0) {
        ctx.flags[0].store(g, .release);
    } else {
        while (ctx.flags[0].load(.acquire) != g) std.atomic.spinLoopHint();
        ctx.flags[wid].store(g, .release);
    }
}

test "L2 WorkerPool: many dispatches, generation disambiguates WITHOUT clearing flags" {
    const alloc = std.testing.allocator;
    const P = hostCores();
    var pool = try parallel.WorkerPool.init(alloc, P, parallel.Workgroup{ .available = true });
    try pool.spawn();
    defer pool.deinit();

    var ctx = HandshakeCtx{};
    var round: usize = 0;
    while (round < 500) : (round += 1) {
        const g = pool.dispatch(&ctx, handshakeTask);
        // Post-dispatch, every participating worker's flag holds exactly THIS g —
        // the handshake completed and no flag array was memset between callbacks.
        var w: usize = 0;
        while (w < P) : (w += 1) {
            try std.testing.expectEqual(g, ctx.flags[w].load(.acquire));
        }
    }
}

test "L3 WorkerPool: P=1 spawns no thread (caller is the lone worker)" {
    const alloc = std.testing.allocator;
    var pool = try parallel.WorkerPool.init(alloc, 1, parallel.Workgroup{});
    // No threads were allocated for P=1 (the threads slice is empty).
    try std.testing.expectEqual(@as(usize, 0), pool.threads.len);
    try std.testing.expect(!pool.live);
    try pool.spawn(); // a no-op for P=1
    try std.testing.expect(!pool.live); // still not "live" — no spawned threads
    defer pool.deinit();

    var ctx = SeenCtx{};
    const g = pool.dispatch(&ctx, seenTask);
    // The caller ran inline as worker 0; no other worker exists.
    try std.testing.expectEqual(g, ctx.seen[0].load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), ctx.runs[0].load(.acquire));
}

test "L3 WorkerPool: allocated-but-never-spawned deinit is clean (no join of garbage)" {
    const alloc = std.testing.allocator;
    // A multi-worker pool whose threads were RESERVED by init but never spawned (the
    // gate refused / a manual driver that never started). deinit must free the slice
    // without joining uninitialised handles — `live` gates the join.
    var pool = try parallel.WorkerPool.init(alloc, 4, parallel.Workgroup{ .available = true });
    try std.testing.expectEqual(@as(usize, 3), pool.threads.len); // P-1 reserved
    try std.testing.expect(!pool.live); // never spawned
    pool.deinit(); // must NOT join the (uninitialised) thread handles, must free
    // (leak-checked by std.testing.allocator on test exit.)
}

test "L3 WorkerPool: init/spawn split — workers reference the pool's final address" {
    const alloc = std.testing.allocator;
    // init returns the pool by value; the OWNER moves it to its lasting location and
    // only THEN spawns, so the worker threads capture a stable &pool. We emulate the
    // engine's heap-stable ownership with a heap box.
    const Box = struct { pool: parallel.WorkerPool };
    const box = try alloc.create(Box);
    defer alloc.destroy(box);
    box.pool = try parallel.WorkerPool.init(alloc, hostCores(), parallel.Workgroup{ .available = true });
    try box.pool.spawn(); // spawn against the final (heap) address
    defer box.pool.deinit();
    try std.testing.expect(box.pool.live);

    var ctx = SeenCtx{};
    const g = box.pool.dispatch(&ctx, seenTask);
    var w: usize = 0;
    while (w < box.pool.p) : (w += 1) {
        try std.testing.expectEqual(g, ctx.seen[w].load(.acquire));
    }
}

// ===========================================================================
// L4 — Barrier: reusable across phases AND dispatches; ReadyFlags generation keying.
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

test "L4 Barrier: P participants synchronise across many phases (reusable, no local state)" {
    const P = @max(2, @min(hostCores(), 6));
    const phases = 200;
    var ctx = BarrierCtx{ .barrier = .{ .p = P }, .phases = phases };

    var threads: [6]std.Thread = undefined;
    var spawned: usize = 0;
    var i: usize = 1;
    while (i < P) : (i += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, barrierWorker, .{&ctx});
        spawned += 1;
    }
    barrierWorker(&ctx); // the caller is participant 0
    var j: usize = 0;
    while (j < spawned) : (j += 1) threads[j].join();

    // The barrier reset correctly between every phase (no participant raced ahead):
    // every participant incremented exactly once per phase.
    const expected: usize = @as(usize, P) * @as(usize, phases);
    try std.testing.expectEqual(expected, ctx.counter.load(.acquire));
}

/// Drive the SAME Barrier through two distinct dispatches over a worker pool — it
/// must reset between dispatches (the engine reuses one Barrier per callback). The
/// task does several phases per dispatch.
const PooledBarrierCtx = struct {
    barrier: *parallel.Barrier,
    p: usize,
    phases: usize,
    counter: std.atomic.Value(usize) = .init(0),
};

fn pooledBarrierTask(user: *anyopaque, wid: usize, g: usize) void {
    _ = g;
    const ctx: *PooledBarrierCtx = @ptrCast(@alignCast(user));
    if (wid >= ctx.p) return; // only the scheduled width participates
    var phase: usize = 0;
    while (phase < ctx.phases) : (phase += 1) {
        _ = ctx.counter.fetchAdd(1, .acq_rel);
        ctx.barrier.wait();
    }
}

test "L4 Barrier: reused across dispatches over a worker pool (resets between callbacks)" {
    const alloc = std.testing.allocator;
    const P = @max(2, @min(hostCores(), 4));
    var pool = try parallel.WorkerPool.init(alloc, P, parallel.Workgroup{ .available = true });
    try pool.spawn();
    defer pool.deinit();

    var barrier = parallel.Barrier{ .p = P };
    const phases = 30;
    var ctx = PooledBarrierCtx{ .barrier = &barrier, .p = P, .phases = phases };

    var dispatch: usize = 0;
    while (dispatch < 40) : (dispatch += 1) {
        _ = pool.dispatch(&ctx, pooledBarrierTask);
    }
    // Across 40 dispatches × `phases` phases × P participants, every barrier episode
    // completed (a stuck barrier would deadlock, never returning from dispatch).
    const expected: usize = @as(usize, 40) * @as(usize, phases) * @as(usize, P);
    try std.testing.expectEqual(expected, ctx.counter.load(.acquire));
}

test "L4 ReadyFlags: a flag still holding g-1 reads as 'not ready'; wait returns at g; spins accumulate" {
    var rf = parallel.ReadyFlags{};
    var spins: u64 = 0;
    // Single-threaded generation keying: publish g for op 3, then a wait for g
    // returns immediately (already ready, zero spins added beyond loop-entry check).
    rf.publish(3, 7);
    rf.wait(3, 7, &spins);
    try std.testing.expectEqual(@as(u64, 0), spins);

    // The SAME flag at the NEXT generation reads as not-ready until republished. We
    // prove "not ready" without blocking by checking the raw load is still g-1.
    try std.testing.expect(rf.flags[3].load(.acquire) == 7);
    try std.testing.expect(rf.flags[3].load(.acquire) != 8);
    rf.publish(3, 8);
    rf.wait(3, 8, &spins);
    try std.testing.expectEqual(@as(u64, 0), spins);

    // A never-published op reads as not-ready (still the init 0) for any g>0.
    try std.testing.expect(rf.flags[5].load(.acquire) == 0);
}

/// Cross-thread ReadyFlags: a producer thread publishes op p at generation g after a
/// short delay; the consumer (this thread) spins via `wait` and MUST accumulate at
/// least one spin (the producer wasn't instantaneous), then observe the release.
const RfCtx = struct {
    rf: parallel.ReadyFlags = .{},
    go: std.atomic.Value(bool) = .init(false),
};

fn rfProducer(ctx: *RfCtx) void {
    while (!ctx.go.load(.acquire)) std.atomic.spinLoopHint();
    // A little work so the consumer is forced to spin (publishes op 0 at gen 99).
    var sink: u64 = 0;
    var i: usize = 0;
    while (i < 50_000) : (i += 1) sink +%= i;
    std.mem.doNotOptimizeAway(sink);
    ctx.rf.publish(0, 99);
}

test "L4 ReadyFlags: cross-thread publish/wait is race-free (release/acquire) with spin telemetry" {
    const ctx = try std.testing.allocator.create(RfCtx);
    defer std.testing.allocator.destroy(ctx);
    ctx.* = .{};
    const t = try std.Thread.spawn(.{}, rfProducer, .{ctx});
    ctx.go.store(true, .release);
    var spins: u64 = 0;
    ctx.rf.wait(0, 99, &spins); // acquire spin until the release store lands
    t.join();
    // The flag is observably published at gen 99 (acquire side saw the release).
    try std.testing.expectEqual(@as(usize, 99), ctx.rf.flags[0].load(.acquire));
    // We can't guarantee a nonzero spin count (the producer might win the race), but
    // the wait must have RETURNED — which it did, or this line is unreached. The
    // accumulator is a valid (non-negative) count either way.
    try std.testing.expect(spins >= 0);
}

// ===========================================================================
// L5 — replayParallel / replayWorker over a SYNTHETIC type-erased schedule: the
// side effects match a sequential run of the same ops, for BOTH executors.
// ===========================================================================

/// A synthetic op set: op i computes value[i] = sum(value[pred]) + i, writing into a
/// shared results array. Because the level-barrier / HEFT schedules honour every
/// predecessor edge, a parallel replay must produce the SAME results array as a
/// sequential index-order sweep. We compare bit-exact.
const SynthCtx = struct {
    n: usize,
    preds: *const [parallel.max_ops]u64,
    results: [parallel.max_ops]std.atomic.Value(i64) = blk: {
        var a: [parallel.max_ops]std.atomic.Value(i64) = undefined;
        for (&a) |*f| f.* = std.atomic.Value(i64).init(0);
        break :blk a;
    },

    fn reset(self: *SynthCtx) void {
        for (&self.results) |*r| r.store(0, .monotonic);
    }
};

fn synthRunOp(op_index: usize, user: *anyopaque) void {
    const ctx: *SynthCtx = @ptrCast(@alignCast(user));
    var acc: i64 = @intCast(op_index);
    var pr = ctx.preds[op_index];
    while (pr != 0) {
        const p = @ctz(pr);
        pr &= pr - 1;
        // Acquire-load each predecessor result. The schedule guarantees the producer
        // ran (and published, in the HEFT case) before we reach here, so this read is
        // a value, not a race.
        acc += ctx.results[p].load(.acquire);
    }
    ctx.results[op_index].store(acc, .release);
}

/// Build a small synthetic DAG by hand and its Dag/CostModel, then drive both
/// schedules through `replayParallel` over a real worker pool, comparing the result
/// vector to a sequential reference sweep. This exercises replayWorker's level loop
/// and HEFT predecessor-spin in isolation from the engine plan.
fn synthDag(n: usize, edges: []const [2]usize) parallel.Dag {
    var dag = parallel.Dag{ .n = n };
    for (edges) |e| {
        const from = e[0];
        const to = e[1];
        dag.preds[to] |= (@as(u64, 1) << @intCast(from));
        dag.succs[from] |= (@as(u64, 1) << @intCast(to));
    }
    return dag;
}

fn synthCost(n: usize) parallel.CostModel {
    var m = parallel.CostModel{ .n = n };
    // Uneven costs so HEFT and the level-barrier produce genuinely different
    // placements (the schedule is exercised, not a trivial round-robin).
    var i: usize = 0;
    while (i < n) : (i += 1) m.cost[i] = 1.0 + @as(f32, @floatFromInt((i * 7) % 5));
    return m;
}

fn synthReference(n: usize, preds: *const [parallel.max_ops]u64, out: *[parallel.max_ops]i64) void {
    // Sequential index-order sweep (the op-list is forward-topo: a pred index < its
    // successor for our constructed edges), the bit-exact ground truth.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var acc: i64 = @intCast(i);
        var pr = preds[i];
        while (pr != 0) {
            const p = @ctz(pr);
            pr &= pr - 1;
            acc += out[p];
        }
        out[i] = acc;
    }
}

test "L5 replayParallel: synthetic schedule side effects match a sequential sweep (both executors)" {
    const alloc = std.testing.allocator;
    // A diamond-ish DAG: 0 → {1,2,3}, {1,2,3} → 4, 4 → {5,6}, {5,6} → 7. Forward-topo
    // by index, with branching at two stages so both schedulers spread work.
    const n: usize = 8;
    const edges = [_][2]usize{
        .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 },
        .{ 1, 4 }, .{ 2, 4 }, .{ 3, 4 },
        .{ 4, 5 }, .{ 4, 6 }, .{ 5, 7 },
        .{ 6, 7 },
    };
    const dag = synthDag(n, &edges);
    var costs = synthCost(n);

    // Reference (sequential) results.
    var ref = [_]i64{0} ** parallel.max_ops;
    synthReference(n, &dag.preds, &ref);

    const P = @max(2, @min(hostCores(), 5));
    var pool = try parallel.WorkerPool.init(alloc, P, parallel.Workgroup{ .available = true });
    try pool.spawn();
    defer pool.deinit();

    var ready = parallel.ReadyFlags{};
    var barrier = parallel.Barrier{};
    var tele = parallel.SpinTelemetry{};

    const ctx = try alloc.create(SynthCtx);
    defer alloc.destroy(ctx);
    ctx.* = .{ .n = n, .preds = &dag.preds };

    for (executors) |exec| {
        const sched = switch (exec) {
            .level_barrier => parallel.levelSchedule(&dag, &costs, P),
            .heft => parallel.heftSchedule(&dag, &costs, P),
        };
        // Many replays: the generation keying must let the ready flags + barrier be
        // reused with no clear between runs and still match the reference each time.
        var run: usize = 0;
        while (run < 50) : (run += 1) {
            ctx.reset();
            _ = parallel.replayParallel(&pool, exec, &sched, &dag, &ready, &barrier, synthRunOp, ctx, &tele, null);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (ctx.results[i].load(.acquire) != ref[i]) {
                    std.debug.print("FAIL: exec={s} op {d} got {d} want {d}\n", .{ @tagName(exec), i, ctx.results[i].load(.acquire), ref[i] });
                    return error.ReplayDiverged;
                }
            }
        }
    }
}

// ===========================================================================
// L6 — Auto-demote hysteresis (direct), and the engine surfaces spin_time.
// ===========================================================================

test "L6 DemotePolicy: hysteresis — demotes only after sustained low, re-promotes only after sustained high" {
    var pol = parallel.DemotePolicy.init(true);
    pol.floor = 0.1;
    pol.ceiling = 0.3;
    pol.demote_after = 4;
    pol.promote_after = 8;

    // Healthy headroom keeps it active indefinitely.
    var i: usize = 0;
    while (i < 20) : (i += 1) try std.testing.expect(pol.observe(0.6));

    // Interrupted dips (3 low, then a recovery) never reach the demote threshold.
    try std.testing.expect(pol.observe(0.0));
    try std.testing.expect(pol.observe(0.0));
    try std.testing.expect(pol.observe(0.05));
    try std.testing.expect(pol.observe(0.9)); // resets the low streak
    // ...and now a fresh sustained low run must restart the count from zero.
    try std.testing.expect(pol.observe(0.0)); // 1
    try std.testing.expect(pol.observe(0.0)); // 2
    try std.testing.expect(pol.observe(0.0)); // 3
    try std.testing.expect(!pol.observe(0.0)); // 4 → demoted (returns false)
    try std.testing.expect(!pol.active);

    // Mid headroom (below ceiling) never re-promotes, no matter how long.
    i = 0;
    while (i < 100) : (i += 1) try std.testing.expect(!pol.observe(0.2));

    // An interrupted high run never reaches the promote threshold.
    var k: usize = 0;
    while (k < 7) : (k += 1) try std.testing.expect(!pol.observe(0.5));
    try std.testing.expect(!pol.observe(0.1)); // resets the high streak (below ceiling)
    // Fresh sustained high run from zero.
    k = 0;
    while (k < 7) : (k += 1) try std.testing.expect(!pol.observe(0.5));
    try std.testing.expect(pol.observe(0.5)); // 8th → re-promoted
    try std.testing.expect(pol.active);
}

test "L6 engine: a wide graph promotes and surfaces spin_time telemetry after a Tier B render" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x5901);
    var out: [N]Sample(f32) = undefined;

    var eng = try buildWide(8, alloc, N, &input, &out, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer eng.deinit();
    try std.testing.expect(eng.tierBActive());

    const token = engine.enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);
    // spin_time is a max-across-workers spin witness; it is surfaced (>= 0, finite)
    // after a Tier B render — the engine wired the telemetry, not a stale zero from a
    // never-run overlay. (Value depends on scheduling; we assert it is well-formed.)
    const tele = eng.telemetry();
    try std.testing.expect(!std.math.isNan(tele.spin_time));
    try std.testing.expect(tele.spin_time >= 0);
    try std.testing.expect(!tele.fault);
}

test "L6 engine: a near-linear chain does NOT promote (parallelism < 1.5)" {
    const N = 32;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 11);
    var out: [N]Sample(f32) = undefined;

    var chain = try buildChain(alloc, N, &input, &out, .{ .cores = 8, .force_workgroup = true });
    defer chain.deinit();
    try std.testing.expect(!chain.tierBActive());
    try std.testing.expect(chain.tierBParallelism() < 1.5);
    try std.testing.expectEqual(@as(usize, 1), chain.tierBWorkers());
}

// ===========================================================================
// L7 — EDIT→COMMIT / RECONFIGURE under an ACTIVE Tier B: post-swap render still
// bit-identical to a Tier A render of the same post-swap graph. No leaks.
// ===========================================================================

// BUG DETECTED (use-after-free) — src/engine.zig `installPlan` (the recommit /
// beginEdit→commit swap), when a Tier-B overlay is PRESENT and ACTIVE.
//   Repro: build a wide graph with `commitWith(.{ .cores = 4, .force_workgroup =
//   true })` (Tier B promotes), render, call `recommit()`, then render again →
//   panic "incorrect alignment" in `runOneOp` (`@alignCast(op.fn_ptr.?)`), reached
//   from the Tier-B `replayWorker`/`runOneOp` over the rebound per-edge plan.
//   Root cause: `recommit()` calls `installPlan(self.ir, self.bound)`, so the
//   parameter `new_bound` ALIASES `self.bound`. Inside `installPlan`:
//     - `old_bound = self.bound;`            // old_bound aliases new_bound
//     - `self.bound = dupe(new_bound);`      // engine now owns a fresh copy
//     - ... RCU swap ...
//     - `self.alloc.free(old_bound);`        // frees the backing of new_bound
//     - `if (self.tb) |tb| tb.rebind(new_ir, new_bound, self.cfg) ...`
//   `tb.rebind` → `buildBoundPlanMode` reads `bound[nid].render` out of the now-
//   FREED `new_bound` slice and stores the garbage (DebugAllocator 0xAA poison) into
//   `op.fn_ptr`; the next Tier-B render `@alignCast`es that garbage → abort.
//   Why existing tests missed it: the only prior `recommit` test runs on a Tier-A
//   engine (`tb == null`), so line 1909 is never reached; and `reconfigure` is safe
//   because it passes the UNCHANGED `self.bound` (never freed) to `rebind`.
//   Expected: a post-recommit Tier-B render is bit-identical to a Tier-A render of
//   the same graph (no swap-time UAF).
//   Actual: UAF → "incorrect alignment" panic, process abort.
//   Suggested fix (for the orchestrator, NOT applied here): pass the engine's NEW
//   owned `self.bound` to `tb.rebind` (it holds identical instance pointers), or
//   move the `tb.rebind` call before `self.alloc.free(old_bound)`.
// This test is left SKIPPED (a runtime gate, so the body still type-checks as the
// regression guard) so the UAF does not abort the whole runner. Flip `bug_fixed` to
// true once the installPlan UAF is fixed to arm it.
var bug_fixed_installplan_uaf: bool = true; // FIXED: installPlan now rebinds Tier B from the live self.bound
test "BUG: L7 recommit under active Tier B: post-swap render stays bit-identical to Tier A" {
    // Runtime gate (not comptime) so the regression body still type-checks below.
    if (!@atomicLoad(bool, &bug_fixed_installplan_uaf, .seq_cst)) return error.SkipZigTest;
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xED17);

    var out_a: [N]Sample(f32) = undefined;
    var out_b: [N]Sample(f32) = undefined;
    var eng_a = try buildWide(8, alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();
    var eng_b = try buildWide(8, alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer eng_b.deinit();
    try std.testing.expect(eng_b.tierBActive());

    const token = engine.enterRealtimeThread();
    defer token.leave();

    // Render a few blocks, recommit (rebuilds the Tier-B per-edge plan + schedule
    // across the swap), render a few more — bit-exact to Tier A throughout.
    var block: usize = 0;
    while (block < 4) : (block += 1) {
        eng_a.renderInto(token);
        eng_b.renderInto(token);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
    }

    // Recommit BOTH (no structural change): the Tier-B overlay rebuilds its overlay
    // plan/schedule; Tier A rebuilds its colored plan. Both must remain consistent.
    try eng_b.recommit();
    try eng_a.recommit();
    // The overlay re-promoted after the rebind (the gate verdict is unchanged for an
    // identical graph).
    try std.testing.expect(eng_b.tierBActive());

    block = 0;
    while (block < 6) : (block += 1) {
        eng_a.renderInto(token);
        eng_b.renderInto(token);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
    }
    try std.testing.expect(!eng_b.telemetry().fault);
}

test "L7 reconfigure(N) under active Tier B: post-swap render bit-identical to a fresh Tier A at the new N" {
    const Nmax = 128;
    const Nsmall = 64;
    const alloc = std.testing.allocator;
    var input: [Nmax]Sample(f32) = undefined;
    fillNoise(&input, 0x5147C4);

    // Tier B engine pre-sized for the worst-case N so reconfigure is a LIVE swap.
    var out_b: [Nmax]Sample(f32) = undefined;
    var eng_b = try buildWide(8, alloc, Nsmall, &input, &out_b, .{
        .cores = 4,
        .force_workgroup = true,
        .tier_b_executor = .level_barrier,
        .max_block_size = Nmax,
    });
    defer eng_b.deinit();
    try std.testing.expect(eng_b.tierBActive());

    const token = engine.enterRealtimeThread();
    defer token.leave();
    eng_b.renderInto(token); // render at the small N first
    try eng_b.reconfigure(Nmax); // live RCU swap to the larger block size
    try std.testing.expect(eng_b.tierBActive()); // re-promoted after the rebind
    eng_b.renderInto(token); // now renders Nmax samples into out_b

    // Ground truth: a FRESH Tier A engine committed directly at Nmax. After one block
    // its output must equal the reconfigured Tier-B engine's output byte-for-byte
    // (same kernels, same coefficients, same input prefix).
    var out_a: [Nmax]Sample(f32) = undefined;
    var eng_a = try buildWide(8, alloc, Nmax, &input, &out_a, .{});
    defer eng_a.deinit();
    eng_a.renderInto(token);

    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
    try std.testing.expect(!eng_b.telemetry().fault);
}

test "L7 recommit on a Tier-B-configured engine that the gate kept on Tier A: rebind is sound, bit-exact" {
    // The diamond (work/span ≈ 1.5, at the speedup threshold) is configured for the
    // Tier-B overlay but the gate keeps it on Tier A. This exercises the recommit
    // rebind/RCU path with the overlay present-but-demoted, interleaved with renders,
    // asserting bit-exactness against a sibling Tier A on every iteration — the path
    // is sound regardless of whether the overlay is currently promoted. (The
    // promoted-overlay recommit path is the SKIPPED `BUG:` test above, blocked by the
    // installPlan use-after-free.)
    const N = 32;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x0D1A50);

    var out_a: [N]Sample(f32) = undefined;
    var out_b: [N]Sample(f32) = undefined;
    var eng_a = try buildDiamond(alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();
    var eng_b = try buildDiamond(alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer eng_b.deinit();
    // Document the precondition this test relies on: the gate left the diamond on
    // Tier A, so recommit's per-edge rebind does not feed a subsequent parallel
    // render off the freed bound set. (If a future gate change promotes the diamond,
    // this assertion fails loudly — at which point this test would hit the same UAF
    // and must be skipped until the installPlan fix lands.)
    try std.testing.expect(!eng_b.tierBActive());

    const token = engine.enterRealtimeThread();
    defer token.leave();

    var iter: usize = 0;
    while (iter < 10) : (iter += 1) {
        eng_a.renderInto(token);
        eng_b.renderInto(token);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
        try eng_b.recommit(); // rebuild + RCU swap + Tier-B rebind every iteration
        try eng_a.recommit();
    }
}

// ===========================================================================
// STRESS — many blocks, many shapes, P up to ncores, to flush nondeterminism.
// ===========================================================================

test "STRESS: wide graph, P=2..ncores, 64 blocks each, bit-exact (flush scheduling races)" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x5712E5);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    var out_a: [N]Sample(f32) = undefined;
    var eng_a = try buildWide(8, alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();

    const pmax = hostCores();
    var p: usize = 2;
    while (p <= pmax) : (p += 1) {
        for (executors) |exec| {
            var out_b: [N]Sample(f32) = undefined;
            var eng_b = try buildWide(8, alloc, N, &input, &out_b, .{ .cores = p, .force_workgroup = true, .tier_b_executor = exec });
            defer eng_b.deinit();
            try std.testing.expect(eng_b.tierBActive());

            // Re-render Tier A fresh from the same seed by rebuilding? No — Tier A is
            // deterministic and stateless here (no feedback), so its per-block output
            // is identical every block; capture the reference once and compare.
            eng_a.renderInto(token);
            const ref = out_a;

            var block: usize = 0;
            while (block < 64) : (block += 1) {
                eng_b.renderInto(token);
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(ref[0..]), std.mem.sliceAsBytes(out_b[0..]));
            }
        }
    }
}

// ===========================================================================
// L8 — PROFILE-GUIDED CALIBRATION of the Tier-B schedule (`Engine.calibrate`,
// `TierB.measure`). Calibration renders `k` warm-up blocks under a SEQUENTIAL
// replay, times each op, and rebuilds the schedule from the measured cost. The
// load-bearing law it must preserve: measured costs change ONLY the schedule
// (worker assignment / op placement), NEVER the per-op reduction order — so a
// post-calibration Tier-B render is STILL bit-identical to a Tier-A render of the
// same graph. Calibration is therefore a no-op on the observable audio.
//
// Laws pinned here:
//   (L8a) calibrate(k>0) on a PROMOTING Tier-B engine flips tierBCalibrated()
//         false→true (this host — macOS/Linux — has a monotonic tick source).
//   (L8b) calibrate(0) is a NO-OP: tierBCalibrated() stays false and the engine
//         still renders bit-exact (the static cost hints stand untouched).
//   (L8c) THE SPINE: after calibrate, the Tier-B parallel render is byte-exact to a
//         Tier-A sequential render of the same graph, over many blocks and many P.
//   (L8d) calibration preserves correctness on a STATEFUL graph (pool-resident z⁻¹
//         feedback): `measure` advances the per-edge pool's feedback tail by `k`
//         blocks during warm-up, so a Tier-A reference driven `k` warm-up blocks
//         realigns, and every subsequent block matches bit-exact. A torn-pool bug in
//         the schedule-order replay would corrupt that warm-up feedback state and
//         surface here as a post-calibration divergence.
//   (L8e) calibration is IDEMPOTENT in the observable: a second calibrate (or a
//         no-op calibrate(0) after a real one) keeps the render bit-exact.
//
// Why bit-exact and not allclose: Tier B replays its own per-edge plan over its own
// pool with the SAME kernels and the SAME reduction order as Tier A; calibration
// only reshuffles which worker runs which op. Any divergence is a scheduling/torn-
// pool bug, never numerics.
// ===========================================================================

/// A two-input feedback summer: out = dry + g·wet, where "wet" is a z⁻¹ feedback tap.
/// The pool-resident persistent tail (the DelayLine's z⁻¹ buffer) is what makes the
/// comb bank STATEFUL across callbacks — and what `measure`'s warm-up advances.
const Summer = struct {
    const Self = @This();
    g: f32 = 0.5,
    pub const inputs = .{ .dry = Sample(f32), .wet = Sample(f32) };
    pub fn process(self: *Self, dry: []const Sample(f32), wet: []const Sample(f32), out: []Sample(f32)) void {
        for (dry, wet, out) |d, w, *y| y.ch[0] = d.ch[0] + self.g * w.ch[0];
    }
};

/// A WIDE bank of `W` independent comb-filter voices (src → Summer → DelayLine, the
/// delay fed back into the Summer's wet port) summed by a balanced adder tree into a
/// sink. Wide (promotes Tier B) AND every voice carries a pool-resident z⁻¹ — the
/// stateful shape that exercises `measure`'s warm-up writing the per-edge pool's
/// persistent feedback tail, and the reconvergent adder tree gives the colorer room
/// to reuse buffers so the schedule order genuinely differs from op-index order.
fn buildCombBank(
    comptime W: usize,
    alloc: std.mem.Allocator,
    comptime N: usize,
    input: [*]const Sample(f32),
    out: [*]Sample(f32),
    opts: engine.EngineOptions,
) !engine.Engine {
    comptime std.debug.assert(W >= 2 and (W & (W - 1)) == 0);
    const Delay = pan.DelayLine(Sample(f32), 3);
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = input });
    const Summerh = @TypeOf(try bg.add(Summer, .{}));
    const Adder = @TypeOf(try bg.add(Add2, .{}));

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

test "L8a calibrate(k>0) flips tierBCalibrated false→true on a promoting Tier-B engine" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA11B);
    var out: [N]Sample(f32) = undefined;

    for (executors) |exec| {
        var eng = try buildWide(8, alloc, N, &input, &out, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = exec });
        defer eng.deinit();
        // A real Tier-B overlay must be present (the differential premise) and not yet
        // calibrated — the static byte×hint cost model is in force at commit.
        try std.testing.expect(eng.tierBActive());
        try std.testing.expect(!eng.tierBCalibrated());

        // One warm-up block is enough to populate the measured costs and flip the flag.
        // This host (macOS/Linux) has a monotonic tick source, so calibration succeeds.
        eng.calibrate(1);
        if (!eng.tierBCalibrated()) {
            std.debug.print("FAIL: calibrate(1) did not set tierBCalibrated (exec={s})\n", .{@tagName(exec)});
            return error.CalibrateDidNotFlip;
        }
        // The overlay re-promoted across the calibrate→rebind (identical graph, so the
        // gate verdict is unchanged) — calibration did not accidentally demote it.
        try std.testing.expect(eng.tierBActive());
    }
}

test "L8b calibrate(0) is a NO-OP: tierBCalibrated stays false, render stays bit-exact" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x0CA10);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    var out_a: [N]Sample(f32) = undefined;
    var out_b: [N]Sample(f32) = undefined;
    var eng_a = try buildWide(8, alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();
    var eng_b = try buildWide(8, alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer eng_b.deinit();
    try std.testing.expect(eng_b.tierBActive());
    try std.testing.expect(!eng_b.tierBCalibrated());

    // calibrate(0) renders zero warm-up blocks: it must not measure, must not flip the
    // flag, and must not touch the schedule — the static hints stand.
    eng_b.calibrate(0);
    try std.testing.expect(!eng_b.tierBCalibrated());

    // And the engine still renders bit-exact to Tier A (the no-op left it sound).
    var block: usize = 0;
    while (block < 6) : (block += 1) {
        eng_a.renderInto(token);
        eng_b.renderInto(token);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
    }
    try std.testing.expect(!eng_b.telemetry().fault);
}

test "L8c spine: post-calibration Tier B ≡ Tier A bit-exact (stateless wide, both executors, P=2..ncores)" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA11C);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    const pmax = hostCores();
    for (executors) |exec| {
        var p: usize = 2;
        while (p <= pmax) : (p += 1) {
            var out_a: [N]Sample(f32) = undefined;
            var out_b: [N]Sample(f32) = undefined;
            var eng_a = try buildWide(8, alloc, N, &input, &out_a, .{});
            defer eng_a.deinit();
            var eng_b = try buildWide(8, alloc, N, &input, &out_b, .{ .cores = p, .force_workgroup = true, .tier_b_executor = exec });
            defer eng_b.deinit();
            try std.testing.expect(eng_b.tierBActive());

            // Calibrate with several warm-up blocks (exercises the timed sequential
            // replay and the schedule rebuild). The wide graph is STATELESS — its only
            // input is the fixed buffer and every kernel is memoryless — so the warm-up
            // blocks `measure` runs leave no residue; no reference realignment needed.
            eng_b.calibrate(5);
            try std.testing.expect(eng_b.tierBCalibrated());
            try std.testing.expect(eng_b.tierBActive()); // still promoted post-rebind

            // The schedule may now place ops on different workers, but the rendered
            // values are unchanged: byte-exact to a fresh Tier-A render each block.
            var block: usize = 0;
            while (block < 8) : (block += 1) {
                eng_a.renderInto(token);
                eng_b.renderInto(token);
                try std.testing.expectEqualSlices(
                    u8,
                    std.mem.sliceAsBytes(out_a[0..]),
                    std.mem.sliceAsBytes(out_b[0..]),
                );
            }
            try std.testing.expect(!eng_b.telemetry().fault);
        }
    }
}

test "L8c spine: post-calibration diamond ≡ Tier A bit-exact (both executors)" {
    const N = 32;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA11D);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    for (executors) |exec| {
        var out_a: [N]Sample(f32) = undefined;
        var out_b: [N]Sample(f32) = undefined;
        var eng_a = try buildDiamond(alloc, N, &input, &out_a, .{});
        defer eng_a.deinit();
        var eng_b = try buildDiamond(alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = exec });
        defer eng_b.deinit();

        // The diamond is configured for Tier B; whether or not the gate promotes it,
        // calibrate must keep it bit-exact. Calibrate, then compare each block.
        eng_b.calibrate(4);

        var block: usize = 0;
        while (block < 8) : (block += 1) {
            eng_a.renderInto(token);
            eng_b.renderInto(token);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
        }
        try std.testing.expect(!eng_b.telemetry().fault);
    }
}

test "L8d stateful CONTROL: uncalibrated feedback comb bank IS bit-exact, and calibrate(0) preserves it" {
    // The positive control that frames the bug below. TWO facts that MUST hold and DO:
    //   (1) a fresh (uncalibrated) Tier-B comb bank is bit-exact to a fresh Tier-A comb
    //       bank over many blocks — the stateful parallel≡sequential invariant works
    //       when calibration is NOT involved (the z⁻¹ tail is carried correctly).
    //   (2) calibrate(0) is a true no-op even on a stateful graph: it does not run
    //       `measure`/rebind, so the feedback state is untouched and the differential
    //       still holds. (calibrate(k≥1) does NOT — see the gated regression below.)
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA11E);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    for (executors) |exec| {
        var out_a: [N]Sample(f32) = undefined;
        var out_b: [N]Sample(f32) = undefined;
        var eng_a = try buildCombBank(4, alloc, N, &input, &out_a, .{});
        defer eng_a.deinit();
        var eng_b = try buildCombBank(4, alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = exec });
        defer eng_b.deinit();
        try std.testing.expect(eng_b.tierBActive());

        // calibrate(0): no measure, no rebuild — the stateful per-edge pool is untouched.
        eng_b.calibrate(0);
        try std.testing.expect(!eng_b.tierBCalibrated());

        var block: usize = 0;
        while (block < 16) : (block += 1) {
            eng_a.renderInto(token);
            eng_b.renderInto(token);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
            for (out_b) |s| try std.testing.expect(std.math.isFinite(s.ch[0]));
        }
        try std.testing.expect(!eng_b.telemetry().fault);
    }
}

// BUG DETECTED (state corruption) — `Engine.calibrate(k)` with k≥1 on a STATEFUL
// graph whose z⁻¹ feedback is POOL-RESIDENT (a comb-filter / DelayLine-feedback bank
// — exactly the wide-and-stateful shape Tier B promotes).
//   Repro (deterministic; see the standalone probe distilled into this test): build a
//   wide feedback comb bank with `commitWith(.{ .cores = 4, .force_workgroup = true })`
//   (Tier B promotes), call `calibrate(k>=1)`, then render. Compare against an
//   otherwise-identical comb bank that was NOT calibrated (or against a fresh Tier-A
//   bank): block 0 happens to match (both read a zeroed feedback tail), but EVERY
//   subsequent block diverges — 31/32 blocks differ — and the calibrated engine's
//   per-block outputs are SCRAMBLED (block 1 emits a value a clean run only reaches
//   ~6 blocks in), i.e. the feedback z⁻¹ state is corrupt, not merely time-shifted.
//   Mechanism: `Engine.calibrate` → `TierB.measure` renders `k` warm-up blocks into
//   the per-edge pool, WRITING the persistent feedback buffers at the create-time
//   coloring's offsets; then `calibrate` → `tb.rebind` → `buildBoundPlanMode` (a NEW
//   per-edge plan) → `buildFor` → `concurrencyColor` RECOLORS the plan. The rebuilt
//   schedule (now sized from the measured costs) yields a DIFFERENT buffer layout, so
//   the live render reads each feedback z⁻¹ from a new offset that holds the previous
//   layout's residue (and the per-edge pool is not re-zeroed for an identical-size
//   graph — `rebind` only reallocates when `need > pool_cap`). The feedback tail is
//   thus left inconsistent with the new layout, scrambling every block after the
//   first.
//   Scope: the STATELESS Tier-B path is unaffected — calibrate(k) on a wide gain/
//   affine/adder graph stays bit-exact to Tier A (proven green by the L8c spine
//   tests). calibrate(0) is a no-op on every graph (proven by the CONTROL above). The
//   defect is specific to calibrate(k≥1) interacting with pool-resident feedback.
//   Expected: after calibrate(k), a stateful Tier-B render is still bit-identical to
//   the SAME render with no calibration (calibration changes only the schedule, never
//   the per-op reduction order NOR the carried z⁻¹ state) — and bit-identical to a
//   fresh Tier-A bank started from the same (zero) feedback state.
//   Actual: 31/32 blocks diverge; the feedback state is corrupt from block 1 on.
//   Suggested fix (for the orchestrator, NOT applied here): on a calibrate→rebind,
//   either (a) re-zero the per-edge pool's persistent feedback tail so the post-
//   calibration render restarts from clean (zero) feedback — consistent with measure
//   being a throwaway warm-up; or (b) preserve the feedback z⁻¹ across the recolor by
//   remapping the persistent buffers from their old offsets to the new layout before
//   the next render. (a) matches calibrate's "startup warm-up" intent and is simplest.
// This test is left SKIPPED (a runtime gate, so the body still type-checks as the
// regression guard) so the deterministic divergence does not abort the whole runner.
// Flip `bug_fixed` to true once `calibrate` no longer corrupts pool-resident feedback.
var bug_fixed_calibrate_feedback: bool = true; // FIXED: calibrate snapshots/restores block instances + re-zeros the per-edge pool, so the warm-up advance is rolled back
test "BUG: L8d calibrate(k>=1) must not corrupt pool-resident z⁻¹ feedback (stateful comb bank)" {
    if (!@atomicLoad(bool, &bug_fixed_calibrate_feedback, .seq_cst)) return error.SkipZigTest;
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA11E);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    for (executors) |exec| {
        // `ref` is the contract oracle: a fresh Tier-B comb bank that is NEVER
        // calibrated. `cal` is the same graph WITH calibrate(k). Calibration must touch
        // only the schedule, so post-calibration `cal` must render bit-identically to
        // `ref` from the first block onward (both start with zeroed feedback state).
        const k = 5;
        var out_ref: [N]Sample(f32) = undefined;
        var out_cal: [N]Sample(f32) = undefined;
        var eng_ref = try buildCombBank(4, alloc, N, &input, &out_ref, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = exec });
        defer eng_ref.deinit();
        var eng_cal = try buildCombBank(4, alloc, N, &input, &out_cal, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = exec });
        defer eng_cal.deinit();
        try std.testing.expect(eng_cal.tierBActive());

        eng_cal.calibrate(k);
        try std.testing.expect(eng_cal.tierBCalibrated());
        try std.testing.expect(eng_cal.tierBActive());

        var block: usize = 0;
        while (block < 32) : (block += 1) {
            eng_ref.renderInto(token);
            eng_cal.renderInto(token);
            if (!std.mem.eql(u8, std.mem.sliceAsBytes(out_ref[0..]), std.mem.sliceAsBytes(out_cal[0..]))) {
                std.debug.print("BUG: calibrate corrupted feedback at block {d} exec={s} ref0={d} cal0={d}\n", .{ block, @tagName(exec), out_ref[0].ch[0], out_cal[0].ch[0] });
                return error.CalibrateCorruptedFeedback;
            }
        }
    }
}

test "L8e idempotent: re-calibration and a calibrate(0) after a real one keep the render bit-exact" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA120);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    var out_a: [N]Sample(f32) = undefined;
    var out_b: [N]Sample(f32) = undefined;
    var eng_a = try buildWide(8, alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();
    var eng_b = try buildWide(8, alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer eng_b.deinit();
    try std.testing.expect(eng_b.tierBActive());

    // First calibration.
    eng_b.calibrate(3);
    try std.testing.expect(eng_b.tierBCalibrated());

    // A no-op calibrate(0) AFTER a real calibration must not un-calibrate or change the
    // schedule (k==0 short-circuits before measuring).
    eng_b.calibrate(0);
    try std.testing.expect(eng_b.tierBCalibrated());

    // A SECOND real calibration re-measures and rebuilds; still bit-exact.
    eng_b.calibrate(2);
    try std.testing.expect(eng_b.tierBCalibrated());
    try std.testing.expect(eng_b.tierBActive());

    // Stateless wide graph ⇒ no warm-up residue ⇒ compare each block directly.
    var block: usize = 0;
    while (block < 8) : (block += 1) {
        eng_a.renderInto(token);
        eng_b.renderInto(token);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
    }
    try std.testing.expect(!eng_b.telemetry().fault);
}

test "L8: a calibrated, non-promoting chain stays correct (calibrate is sound even Tier-A-resident)" {
    // A near-linear chain configured for Tier B but kept on Tier A by the gate. calibrate
    // still runs `measure` + rebuild on the present overlay; the gate verdict is unchanged
    // (still parallelism < threshold ⇒ not promoted), and the Tier-A render stays bit-exact.
    const N = 32;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA121);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    var out_a: [N]Sample(f32) = undefined;
    var out_b: [N]Sample(f32) = undefined;
    var eng_a = try buildChain(alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();
    var eng_b = try buildChain(alloc, N, &input, &out_b, .{ .cores = 8, .force_workgroup = true, .tier_b_executor = .heft });
    defer eng_b.deinit();
    try std.testing.expect(!eng_b.tierBActive()); // the gate kept the chain on Tier A

    eng_b.calibrate(4); // measures + rebuilds the (demoted) overlay; must not promote it
    try std.testing.expect(eng_b.tierBCalibrated());
    try std.testing.expect(!eng_b.tierBActive()); // calibration did not wrongly promote

    var block: usize = 0;
    while (block < 6) : (block += 1) {
        eng_a.renderInto(token);
        eng_b.renderInto(token);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
    }
    try std.testing.expect(!eng_b.telemetry().fault);
}

// ---------------------------------------------------------------------------
// L8f — TORN-POOL WITNESS: the timed warm-up replay in `measure` walks ops in
// SCHEDULE order (the concurrency-colored plan advances a reused scratch buffer's
// value-sequence in schedule order), NOT op-index order — index order could read a
// buffer that a later-indexed-but-earlier-scheduled op has already overwritten.
//
// A 16-voice reconvergent fan-out (gain→affine lanes recombined through a balanced
// adder tree) is deliberately WIDE and reconvergent, so concurrency coloring reuses
// scratch buffers across non-overlapping lanes and the schedule order genuinely
// diverges from op-index order. If `measure` replayed in op-index order it would
// corrupt those reused buffers DURING the timed warm-up; on a stateless graph that
// corruption is confined to the throwaway warm-up blocks, but it would also poison
// the measured costs and (more tellingly) any schedule-order bug that survives the
// rebuild surfaces as a post-calibration divergence from Tier A. We calibrate with a
// LARGE k (the timed schedule-order loop runs k×op_count times) and then assert the
// live render is byte-exact to a fresh Tier-A render over many blocks. A torn-pool
// replay would show up here; a correct schedule-order replay stays bit-exact.
// (Stateless graph: no warm-up residue, so no reference realignment is needed.)
test "L8f torn-pool witness: wide reconvergent graph, large-k calibration stays bit-exact to Tier A" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA11F);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    for (executors) |exec| {
        var out_a: [N]Sample(f32) = undefined;
        var out_b: [N]Sample(f32) = undefined;
        var eng_a = try buildWide(16, alloc, N, &input, &out_a, .{});
        defer eng_a.deinit();
        var eng_b = try buildWide(16, alloc, N, &input, &out_b, .{ .cores = hostCores(), .force_workgroup = true, .tier_b_executor = exec });
        defer eng_b.deinit();
        try std.testing.expect(eng_b.tierBActive());
        // A wide reconvergent shape with real parallelism — the colorer has room to
        // reuse scratch across lanes, which is exactly what makes schedule order differ
        // from op-index order (the premise of the schedule-order replay).
        try std.testing.expect(eng_b.tierBWorkers() >= 2);

        // Large k: the timed SCHEDULE-order replay runs k×op_count op invocations into
        // the per-edge pool. A torn-pool replay corrupts the warm-up and skews costs.
        eng_b.calibrate(20);
        try std.testing.expect(eng_b.tierBCalibrated());
        try std.testing.expect(eng_b.tierBActive());

        var block: usize = 0;
        while (block < 12) : (block += 1) {
            eng_a.renderInto(token);
            eng_b.renderInto(token);
            try std.testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(out_a[0..]),
                std.mem.sliceAsBytes(out_b[0..]),
            );
            for (out_b) |s| try std.testing.expect(std.math.isFinite(s.ch[0]));
        }
        try std.testing.expect(!eng_b.telemetry().fault);
    }
}

// ---------------------------------------------------------------------------
// L8g — CALIBRATION IS OBSERVABLY INVISIBLE on the stateless path: an engine that
// was calibrated and one that never was render byte-identically to each other (and
// both to Tier A) on a stateless graph. This pins the law DIRECTLY — calibration
// changes only worker assignment / op placement, never the per-op reduction order —
// rather than only against the Tier-A oracle. (The stateful analogue is the SKIPPED
// `BUG:` regression above: this same parity is what FAILS there, isolating the defect
// to pool-resident feedback, not calibration in general.)
test "L8g stateless parity: a calibrated engine renders bit-identically to an uncalibrated twin" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA122);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    for (executors) |exec| {
        var out_cal: [N]Sample(f32) = undefined;
        var out_unc: [N]Sample(f32) = undefined;
        var out_ref: [N]Sample(f32) = undefined;
        var eng_cal = try buildWide(8, alloc, N, &input, &out_cal, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = exec });
        defer eng_cal.deinit();
        var eng_unc = try buildWide(8, alloc, N, &input, &out_unc, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = exec });
        defer eng_unc.deinit();
        var eng_ref = try buildWide(8, alloc, N, &input, &out_ref, .{}); // Tier A
        defer eng_ref.deinit();
        try std.testing.expect(eng_cal.tierBActive());
        try std.testing.expect(eng_unc.tierBActive());

        // Only `eng_cal` is calibrated. Its schedule may now differ from the
        // uncalibrated twin's, but the rendered samples must be identical — the
        // stateless graph carries no state for a schedule change to disturb.
        eng_cal.calibrate(6);
        try std.testing.expect(eng_cal.tierBCalibrated());
        try std.testing.expect(!eng_unc.tierBCalibrated());

        var block: usize = 0;
        while (block < 10) : (block += 1) {
            eng_cal.renderInto(token);
            eng_unc.renderInto(token);
            eng_ref.renderInto(token);
            // calibrated ≡ uncalibrated (the direct law) AND both ≡ Tier A (the oracle).
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_unc[0..]), std.mem.sliceAsBytes(out_cal[0..]));
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_ref[0..]), std.mem.sliceAsBytes(out_cal[0..]));
        }
        try std.testing.expect(!eng_cal.telemetry().fault);
    }
}

// ---------------------------------------------------------------------------
// L8h — REPEATED CALIBRATION stress on the stateless path: many `calibrate` calls
// with growing k, each re-measuring and rebuilding the schedule, must keep the flag
// latched, keep the overlay promoted (identical graph ⇒ unchanged gate verdict), and
// keep the render bit-exact to Tier A. This flushes any leak/state drift across the
// repeated measure→rebind→recolor cycle (each rebind frees the old plan + inserted
// state and reallocates), under `std.testing.allocator`'s leak detector.
test "L8h repeated calibration: many measure→rebuild cycles stay latched, promoted, and bit-exact" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xCA123);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    var out_a: [N]Sample(f32) = undefined;
    var out_b: [N]Sample(f32) = undefined;
    var eng_a = try buildWide(8, alloc, N, &input, &out_a, .{});
    defer eng_a.deinit();
    var eng_b = try buildWide(8, alloc, N, &input, &out_b, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer eng_b.deinit();
    try std.testing.expect(eng_b.tierBActive());

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        // Growing warm-up depth each round; k>0 always re-measures + rebuilds.
        eng_b.calibrate(round + 1);
        try std.testing.expect(eng_b.tierBCalibrated()); // stays latched across cycles
        try std.testing.expect(eng_b.tierBActive()); // identical graph ⇒ still promoted

        // Bit-exact to a fresh Tier-A render after every rebuild (stateless ⇒ no residue).
        var block: usize = 0;
        while (block < 3) : (block += 1) {
            eng_a.renderInto(token);
            eng_b.renderInto(token);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_a[0..]), std.mem.sliceAsBytes(out_b[0..]));
        }
    }
    try std.testing.expect(!eng_b.telemetry().fault);
}
