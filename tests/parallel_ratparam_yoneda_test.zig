//! parallel_ratparam_yoneda_test — the LAST coverage gaps of the Tier-B static-
//! parallel executor (`src/parallel.zig` + the `engine.zig` overlay): the "no NEW
//! hazard under parallelism" laws for the two graph features the existing gates do
//! not pin, plus the cold-worker futex park.
//!
//! It DEEPENS `parallel_tier_b_test.zig` / `parallel_concurrent_yoneda_test.zig`
//! (which already pin pure-Map wide graphs, the feedback comb bank, the worker-pool
//! generation handshake, the barrier, ReadyFlags, replay, demote hysteresis, and the
//! recommit/reconfigure RCU swap) — it does NOT duplicate them. The three new facets:
//!
//!   (R) A `Rate` block (a windowed-sinc `Resampler`, a real rational p:q rate seam)
//!       inside a WIDE graph parallelises with NO new hazard. The law: the static
//!       schedule assigns each op to exactly ONE worker per callback, so a Rate
//!       block's internal clocked state (its FIR history / phase) is never touched by
//!       two workers in the same callback. Each voice resamples up p:q then back q:p,
//!       returning to the source rate so the voice outputs are summable at the mix
//!       with no per-voice rate excursion at the adder tree. Proof: Tier B is
//!       BIT-IDENTICAL to the Tier-A sequential render over many blocks. Both run the
//!       SAME bound kernels over the SAME pool, so any divergence is a scheduling /
//!       sync bug, never numerics — hence bit-exact, not allclose.
//!
//!   (P) A wired PARAMETER edge (a control-rate side input,
//!       `connect(producer, consumer.param.<slot>)`) inside a WIDE graph parallelises
//!       with NO new hazard. The law: a parameter edge is ORDINARY in-graph dataflow
//!       for scheduling — it is carried in the op as a parameter-input buffer and the
//!       cross-worker ready-flag treats it identically to a sample edge. Each voice's
//!       one-pole cutoff is driven by its OWN `Lfo` through a wired `param.cutoff`
//!       edge, so the producer→consumer ordering must be honoured per worker exactly
//!       as a sample edge is. Proof: Tier B ≡ Tier A bit-exact over many blocks, with
//!       the modulation genuinely moving (a degenerate constant would make the
//!       differential vacuous).
//!
//!   (K) The cold-worker futex PARK is correct. `WorkerPool` bounded-spins
//!       (`spin_threshold`) then PARKS an idle worker on a futex; a dispatch unparks
//!       it. The law: after a worker has actually parked, a subsequent dispatch still
//!       completes (the worker unparks, runs the task, signals done); MANY dispatches
//!       each separated by a real park all complete; and `deinit` cleanly joins a
//!       PARKED worker (the teardown wake reaches a futex-blocked thread — no hang).
//!       We drive the park DETERMINISTICALLY: a tiny `spin_threshold` plus a spin
//!       until the pool's observable `parked` count reaches `P − 1` (every spawned
//!       worker blocked on the futex) BEFORE dispatching — no sleeps, no flakiness.
//!
//! COMPARISON MODE: pan-vs-pan — always BIT-EXACT. No external oracle. A tolerance
//! would be wrong here: Tier A and Tier B execute the identical plan kernels in the
//! identical reduction order, so equality is exact or there is a bug.
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill loaded before authoring, Rules
//! 13/14). Diagnostics go to `std.debug.print`, never `std.log.err` (a logged error
//! trips a non-zero runner exit). Every test uses `std.testing.allocator`
//! (leak-checked); engines are deinit'd LIFO before their graphs (engine deinit joins
//! the worker pool, so order matters).

const std = @import("std");
const pan = @import("pan");

const parallel = pan.parallel;
const engine = pan.engine;
const Sample = pan.Sample;
const Num = pan.numericFor(.f32, .{});

// ===========================================================================
// Differential backbone. All mono Sample(f32): the only thing that varies across
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
/// A unity-gain passthrough — used only as a fan-out distributor to keep the source's
/// out-degree under the static 8-port ceiling when a bank has many voices. Gain 1.0 is
/// the identity, so every lane still sees the exact source signal.
const Gain = struct {
    const Self = @This();
    gain: f32 = 1.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.gain;
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
fn fillSine(buf: []Sample(f32), phase0: f32) void {
    // A varying, non-trivial input so every Rate FIR / one-pole state genuinely
    // evolves and any divergence is a scheduling/binding bug, not a degenerate zero.
    for (buf, 0..) |*s, i| s.ch[0] = @sin(phase0 + 0.07 * @as(f32, @floatFromInt(i)));
}

/// Host core count clamped to a sane test ceiling — never exceeds `parallel.max_workers`.
fn hostCores() usize {
    const n = std.Thread.getCpuCount() catch 2;
    return @max(2, @min(n, @min(parallel.max_workers, 8)));
}

const executors = [_]parallel.Executor{ .level_barrier, .heft };

// ===========================================================================
// (R) THE RATE CASE — a WIDE bank of resampler voices, summable at the source rate.
// ===========================================================================

/// A WIDE graph of `W` independent rate voices: each voice is
/// `src → Resampler(p:q) → Resampler(q:p) → leaf`, an up-then-down windowed-sinc
/// round-trip that RETURNS to the source rate, so the per-voice output is one sample
/// per source sample and the voices are summable by a plain adder tree (no rate
/// excursion at the mix). The voices are mutually independent (high work/span), so the
/// graph promotes Tier B AND every chain owns a clocked `Rate` block — the §-"no new
/// hazard" case: the static schedule places each Resampler op on exactly one worker
/// per callback, so its FIR history / phase is never two-worker-shared.
///
/// `W` must be a power of two ≥ 2 so the adder tree is exact. `out` receives the sink.
/// The caller owns the returned engine.
fn buildWideRate(
    comptime W: usize,
    alloc: std.mem.Allocator,
    comptime N: usize,
    input: [*]const Sample(f32),
    out: [*]Sample(f32),
    opts: engine.EngineOptions,
) !engine.Engine {
    comptime std.debug.assert(W >= 2 and (W & (W - 1)) == 0);
    // A genuine rational rate change (2:3 then 3:2 back to unity). HALF=6 taps each
    // side is a multiple of M for both directions, so each declares an integer group
    // delay; the commit pass treats both as `Rate` blocks.
    const Up = pan.Resampler(Num, 2, 3, 6);
    const Dn = pan.Resampler(Num, 3, 2, 6);

    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = input });
    const Gainh = @TypeOf(try bg.add(Gain, .{}));
    const Adder = @TypeOf(try bg.add(Add2, .{}));

    // A node may have at most 8 out-edges (the static port ceiling). Each voice draws
    // ONE edge from its rate-source, so when W > 8 the source fans out through unity
    // distributors (one per group of 4 voices) instead of W edges directly. Every lane
    // still reads the identical source signal (gain 1.0), so the differential is
    // unaffected. `feedFrom(v)` returns the node that lane v reads from.
    const group: usize = if (W > 8) 4 else W;
    const n_dist: usize = W / group;
    var dist: [W]Gainh = undefined;
    {
        var d: usize = 0;
        while (d < n_dist) : (d += 1) {
            if (n_dist == 1) {
                dist[d] = undefined; // lanes read src directly
            } else {
                const dg = try bg.add(Gain, .{ .gain = 1.0 });
                try bg.connect(src, dg);
                dist[d] = dg;
            }
        }
    }
    const Feeder = struct {
        fn feed(bgp: *pan.Graph, single: bool, src_node: anytype, dist_node: anytype, target: anytype) !void {
            if (single) try bgp.connect(src_node, target) else try bgp.connect(dist_node, target);
        }
    };

    // One voice per lane, paired straight into the first adder level so every array
    // beyond here is homogeneous Adder handles.
    var level: [W]Adder = undefined;
    var width: usize = 0;
    var i: usize = 0;
    while (i < W) : (i += 2) {
        const up_a = try bg.add(Up, .{});
        const dn_a = try bg.add(Dn, .{});
        const up_b = try bg.add(Up, .{});
        const dn_b = try bg.add(Dn, .{});
        try Feeder.feed(&bg, n_dist == 1, src, dist[i / group], up_a);
        try bg.connect(up_a, dn_a);
        try Feeder.feed(&bg, n_dist == 1, src, dist[(i + 1) / group], up_b);
        try bg.connect(up_b, dn_b);
        const adder = try bg.add(Add2, .{});
        try bg.connect(dn_a, adder.in.x);
        try bg.connect(dn_b, adder.in.y);
        level[width] = adder;
        width += 1;
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

test "R: a WIDE Resampler bank PROMOTES Tier B and renders bit-exact to Tier A (both executors, P=2..ncores)" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillSine(&input, 0.31);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    const pmax = hostCores();
    for (executors) |exec| {
        var p: usize = 2;
        while (p <= pmax) : (p += 1) {
            var out_a: [N]Sample(f32) = undefined;
            var out_b: [N]Sample(f32) = undefined;
            var eng_a = try buildWideRate(8, alloc, N, &input, &out_a, .{});
            defer eng_a.deinit();
            var eng_b = try buildWideRate(8, alloc, N, &input, &out_b, .{ .cores = p, .force_workgroup = true, .tier_b_executor = exec });
            defer eng_b.deinit();

            // The differential is only meaningful if Tier B actually RAN: a silent
            // fallback to Tier A would make "bit-identical" vacuous. The wide rate bank
            // MUST promote — that is the whole point of choosing a summable rate graph.
            if (!eng_b.tierBActive()) {
                std.debug.print("FAIL: wide Resampler bank did not promote at P={d} exec={s}\n", .{ p, @tagName(exec) });
                return error.TierBDidNotPromote;
            }
            try std.testing.expect(eng_b.tierBWorkers() >= 2);

            // Several blocks: prove the Rate blocks' clocked state evolves IDENTICALLY
            // under the parallel schedule across callbacks, not merely on block 0.
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

test "R: a LARGE Resampler bank (16 voices) is bit-exact under both executors" {
    const N = 48;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillSine(&input, 1.17);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    for (executors) |exec| {
        var out_a: [N]Sample(f32) = undefined;
        var out_b: [N]Sample(f32) = undefined;
        var eng_a = try buildWideRate(16, alloc, N, &input, &out_a, .{});
        defer eng_a.deinit();
        var eng_b = try buildWideRate(16, alloc, N, &input, &out_b, .{ .cores = hostCores(), .force_workgroup = true, .tier_b_executor = exec });
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

test "R: the Resampler bank output is a NON-trivial signal (the differential is not vacuous)" {
    // Guard: if both renders produced silence, "bit-identical" would pass trivially.
    // Assert the bank's output is a real, varying, finite signal so the bit-exact
    // checks above are pinning genuine rate-block arithmetic.
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillSine(&input, 0.5);
    var out: [N]Sample(f32) = undefined;

    var eng = try buildWideRate(8, alloc, N, &input, &out, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .heft });
    defer eng.deinit();
    try std.testing.expect(eng.tierBActive());

    const token = engine.enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    var any_nonzero = false;
    var all_equal = true;
    const first = out[0].ch[0];
    for (out) |y| {
        try std.testing.expect(std.math.isFinite(y.ch[0]));
        if (y.ch[0] != 0) any_nonzero = true;
        if (y.ch[0] != first) all_equal = false;
    }
    try std.testing.expect(any_nonzero); // the rate bank actually produced signal
    try std.testing.expect(!all_equal); // and it varies across the block (real audio)
}

// ===========================================================================
// (P) THE WIRED-PARAMETER-EDGE CASE — a WIDE bank whose each voice's cutoff is driven
//     by its OWN Lfo through a wired param edge.
// ===========================================================================

/// A WIDE graph of `W` independent filter voices: each voice is a `OnePole` whose
/// `param.cutoff` is driven by its OWN `Lfo` through a WIRED parameter edge
/// (`connect(lfo, filter.param.cutoff)`), the voices summed by an adder tree into a
/// sink. The voices are mutually independent (high work/span ⇒ promotes Tier B) AND
/// every voice carries a control-rate side input — the "no new hazard" case for a
/// parameter edge: the edge is ordinary dataflow, so the producer (the Lfo) must be
/// ordered before the consumer (the filter) per worker exactly as a sample edge is.
///
/// Distinct Lfo increments per voice so a dropped/duplicated/mis-ordered param edge
/// (a scheduling bug) changes the sum. `W` must be a power of two ≥ 2.
fn buildWideParam(
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
    const Adder = @TypeOf(try bg.add(Add2, .{}));

    var level: [W]Adder = undefined;
    var width: usize = 0;
    var i: usize = 0;
    while (i < W) : (i += 2) {
        // Each filter's cutoff swings in (0.2, 0.9) ⊂ (0,1) — a valid one-pole coeff —
        // at a voice-specific rate so the bank genuinely modulates.
        const f0 = try bg.add(pan.OnePole(Num), .{});
        const lf0 = try bg.add(pan.Lfo, .{ .increment = 0.013 + 0.0017 * @as(f32, @floatFromInt(i)), .amplitude = 0.35, .offset = 0.55, .waveform = .sine });
        const f1 = try bg.add(pan.OnePole(Num), .{});
        const lf1 = try bg.add(pan.Lfo, .{ .increment = 0.013 + 0.0017 * @as(f32, @floatFromInt(i + 1)), .amplitude = 0.35, .offset = 0.55, .waveform = .sine });
        try bg.connect(src, f0); // audio: source → filter sample input
        try bg.connect(lf0, f0.param.cutoff); // modulation: WIRED param edge
        try bg.connect(src, f1);
        try bg.connect(lf1, f1.param.cutoff);
        const adder = try bg.add(Add2, .{});
        try bg.connect(f0, adder.in.x);
        try bg.connect(f1, adder.in.y);
        level[width] = adder;
        width += 1;
    }

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

test "P: a WIDE wired-param-edge bank PROMOTES Tier B and renders bit-exact to Tier A (both executors, P=2..ncores)" {
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillSine(&input, 0.91);

    const token = engine.enterRealtimeThread();
    defer token.leave();

    const pmax = hostCores();
    for (executors) |exec| {
        var p: usize = 2;
        while (p <= pmax) : (p += 1) {
            var out_a: [N]Sample(f32) = undefined;
            var out_b: [N]Sample(f32) = undefined;
            var eng_a = try buildWideParam(8, alloc, N, &input, &out_a, .{});
            defer eng_a.deinit();
            var eng_b = try buildWideParam(8, alloc, N, &input, &out_b, .{ .cores = p, .force_workgroup = true, .tier_b_executor = exec });
            defer eng_b.deinit();

            if (!eng_b.tierBActive()) {
                std.debug.print("FAIL: wide param-edge bank did not promote at P={d} exec={s}\n", .{ p, @tagName(exec) });
                return error.TierBDidNotPromote;
            }
            try std.testing.expect(eng_b.tierBWorkers() >= 2);

            // Many blocks: the Lfo state on each producer must advance identically
            // under the parallel schedule, and the param edge must stay correctly
            // ordered ahead of its consumer filter every callback.
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

test "P: the wired-param bank GENUINELY modulates (the differential is not a constant)" {
    // If the cutoff never moved, the bit-equality above would be a trivial constant.
    // Snapshot block 0, render many more blocks (the Lfos sweep the cutoffs across
    // callbacks), and assert the live output evolved away from block 0 — proving the
    // param edge delivers a real, changing value that is correctly scheduled.
    const N = 64;
    const alloc = std.testing.allocator;
    var input: [N]Sample(f32) = undefined;
    fillSine(&input, 0.0);
    var live: [N]Sample(f32) = undefined; // the sink's fixed destination

    var eng = try buildWideParam(8, alloc, N, &input, &live, .{ .cores = 4, .force_workgroup = true, .tier_b_executor = .level_barrier });
    defer eng.deinit();
    try std.testing.expect(eng.tierBActive());

    const token = engine.enterRealtimeThread();
    defer token.leave();

    eng.renderInto(token); // block 0
    var block0: [N]Sample(f32) = undefined;
    @memcpy(block0[0..], live[0..]); // preserve block 0 before it is overwritten

    // The sink's `dest` is fixed at &live, so each block overwrites it; after many
    // blocks `live` holds a LATE block whose cutoffs the Lfos have swept.
    var b: usize = 0;
    while (b < 24) : (b += 1) eng.renderInto(token);

    var differs = false;
    for (block0, live) |first, late| {
        if (first.ch[0] != late.ch[0]) differs = true;
        try std.testing.expect(std.math.isFinite(late.ch[0]));
    }
    try std.testing.expect(differs); // the sweep genuinely moved the bank's output
    try std.testing.expect(!eng.telemetry().fault);
}

// ===========================================================================
// (K) THE COLD-WORKER PARK — a worker that has ACTUALLY parked on the futex unparks on
//     the next dispatch and runs; many parked dispatches all complete; deinit joins a
//     parked worker without hanging.
// ===========================================================================

/// Per-worker record of the last generation observed and the run count, so a missed
/// wake (a lost futex unpark) or a double-run is caught.
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

/// Spin until every spawned worker (P − 1 of them) is blocked on the futex, i.e. the
/// pool's observable `parked` count reaches P − 1. This makes the park DETERMINISTIC:
/// the subsequent dispatch is guaranteed to wake genuinely-parked workers, not merely
/// spinning ones — so the test pins the futex unpark handshake, not a lucky spin.
fn waitUntilAllParked(pool: *parallel.WorkerPool) void {
    while (pool.parked.load(.acquire) != pool.p - 1) std.atomic.spinLoopHint();
}

test "K: a worker that PARKED on the futex unparks on the next dispatch and runs it (many rounds)" {
    const alloc = std.testing.allocator;
    const P: usize = @max(2, @min(hostCores(), 4));
    var pool = try parallel.WorkerPool.init(alloc, P, parallel.Workgroup{ .available = true });
    // A tiny spin budget so an idle worker reaches the futex park almost immediately;
    // the steady-state RT path never parks, but an idle/stopped engine must.
    pool.spin_threshold = 4;
    try pool.spawn();
    defer pool.deinit(); // must cleanly join PARKED workers (teardown wake → futex)

    var ctx = SeenCtx{};
    var prev_g: usize = 0;
    const rounds = 30;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        // Force a genuine cold park BEFORE dispatching: every spawned worker is now
        // blocked on the futex, so this dispatch exercises the real unpark path.
        waitUntilAllParked(&pool);
        const g = pool.dispatch(&ctx, seenTask);
        // The generation strictly advances (a single release store per dispatch).
        try std.testing.expect(g > prev_g);
        prev_g = g;
        // EVERY worker (0 = the caller, 1..P-1 = the unparked spawned threads) observed
        // THIS generation — the futex wake reached all parked workers and they ran.
        var w: usize = 0;
        while (w < P) : (w += 1) {
            try std.testing.expectEqual(g, ctx.seen[w].load(.acquire));
        }
    }
    // No missed wake, no double-run: each worker ran exactly `rounds` times.
    var w: usize = 0;
    while (w < P) : (w += 1) {
        try std.testing.expectEqual(@as(usize, rounds), ctx.runs[w].load(.acquire));
    }
}

test "K: deinit cleanly joins PARKED workers (the teardown wake reaches a futex-blocked thread, no hang)" {
    const alloc = std.testing.allocator;
    const P: usize = @max(2, @min(hostCores(), 4));
    var pool = try parallel.WorkerPool.init(alloc, P, parallel.Workgroup{ .available = true });
    pool.spin_threshold = 2; // park as fast as possible
    try pool.spawn();

    // Run one dispatch so the workers loop back to the spin/park wait, then let them
    // ALL park on the futex.
    var ctx = SeenCtx{};
    _ = pool.dispatch(&ctx, seenTask);
    waitUntilAllParked(&pool);

    // deinit must wake the futex-blocked workers into teardown and join them. If the
    // teardown wake failed to reach a parked worker, this would HANG (the test would
    // time out) rather than return — a hang is the failure mode we are ruling out.
    pool.deinit();
    // Reaching here proves every parked worker unparked, observed shutdown, and joined.
    try std.testing.expect(true);
}

test "K: alternating spin and park dispatches all complete (the park/wake handshake is reusable)" {
    // Interleave dispatches that hit a cold park with dispatches that are warm (no
    // wait), proving the same pool transitions park→run→spin→run repeatedly with no
    // lost wakeup in either direction.
    const alloc = std.testing.allocator;
    const P: usize = @max(2, @min(hostCores(), 4));
    var pool = try parallel.WorkerPool.init(alloc, P, parallel.Workgroup{ .available = true });
    pool.spin_threshold = 8;
    try pool.spawn();
    defer pool.deinit();

    var ctx = SeenCtx{};
    var prev_g: usize = 0;
    var round: usize = 0;
    while (round < 40) : (round += 1) {
        // Even rounds: force a full cold park first; odd rounds: dispatch immediately
        // (warm — the workers are still spinning from the previous dispatch).
        if (round % 2 == 0) waitUntilAllParked(&pool);
        const g = pool.dispatch(&ctx, seenTask);
        try std.testing.expect(g > prev_g);
        prev_g = g;
        var w: usize = 0;
        while (w < P) : (w += 1) try std.testing.expectEqual(g, ctx.seen[w].load(.acquire));
    }
    var w: usize = 0;
    while (w < P) : (w += 1) {
        try std.testing.expectEqual(@as(usize, 40), ctx.runs[w].load(.acquire));
    }
}
