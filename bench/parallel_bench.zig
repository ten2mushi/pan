//! Benchmark: the P15 Tier-B static-parallel RealtimeStreaming overlay.
//!
//! MEASURES (never asserts an oracle — correctness lives in `tests/`): a wide,
//! CPU-heavy graph (a source fanning out into many independent heavy chains summed
//! by an adder tree — the Tier-B target shape) rendered block-by-block under
//!   - Tier A (the frozen single-core sequential replay, `cores = 1`);
//!   - Tier B level-barrier and HEFT, across worker counts P = 2..ncores;
//! reporting the wall-clock speedup vs Tier A, the per-worker spin time (the
//! ≈ witness that the cross-worker handshake stays bounded), and the Tier-B
//! concurrent footprint (the per-edge scratch pool — the non-coalesced
//! peak-concurrent-live-edge bound). A wide STRESS graph (more compute per sample)
//! is where the parallelism has the most to amortise.
//!
//! Build/run: `zig build bench` (ReleaseFast). A bench warms up, times many render
//! blocks, and consumes every result so dead-code elimination cannot delete it. The
//! ReleaseSafe-vs-ReleaseFast delta (run both) prices the safety-check cost.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.Sample;
const engine = pan.engine;

/// A deliberately CPU-heavy mono Map: each sample runs an iterated polynomial so a
/// single chain carries real work (otherwise the render is memory/plumbing-bound and
/// the thread handoff dominates). Stateless ⇒ the wide graph is embarrassingly
/// parallel across chains.
fn Heavy(comptime iters: usize) type {
    return struct {
        const Self = @This();
        k: f32 = 0.5,
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            for (in, out) |x, *o| {
                var v: f32 = x.ch[0];
                var i: usize = 0;
                while (i < iters) : (i += 1) v = v * v * self.k - v + 0.5;
                o.ch[0] = v;
            }
        }
    };
}

const Add2 = struct {
    const Self = @This();
    pub const inputs = .{ .x = Sample(f32), .y = Sample(f32) };
    pub fn process(self: *Self, x: []const Sample(f32), y: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (x, y, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
    }
};
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

fn cfg(comptime N: usize) pan.Config {
    return .{ .precision = .f32, .channels = .mono, .block_size = N };
}
fn fillNoise(buf: []Sample(f32), seed: u64) void {
    var s = seed;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.ch[0] = @as(f32, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(s >> 16)))))) / 2.147483648e9;
    }
}

/// Build the wide heavy graph (W a power of two ≥ 2): source → W heavy chains →
/// balanced adder tree → sink, with a one-level distributor when W > 8 to respect
/// the 8-port fan-out ceiling. Caller owns the engine.
fn buildWide(
    comptime W: usize,
    comptime iters: usize,
    comptime N: usize,
    alloc: std.mem.Allocator,
    input: [*]const Sample(f32),
    out: [*]Sample(f32),
    opts: engine.EngineOptions,
) !engine.Engine {
    comptime std.debug.assert(W >= 2 and (W & (W - 1)) == 0);
    const Hv = Heavy(iters);
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = input });

    const Gainh = @TypeOf(try bg.add(Hv, .{}));
    const Adder = @TypeOf(try bg.add(Add2, .{}));

    const group: usize = if (W > 8) 4 else W;
    const n_dist: usize = W / group;
    var dist: [W]Gainh = undefined;
    {
        var d: usize = 0;
        while (d < n_dist) : (d += 1) {
            if (n_dist == 1) {
                dist[d] = undefined;
            } else {
                const dg = try bg.add(Hv, .{ .k = 0.0 }); // k=0 ⇒ cheap identity-ish distributor
                try bg.connect(src, dg);
                dist[d] = dg;
            }
        }
    }

    var level: [W]Adder = undefined;
    var width: usize = 0;
    {
        var i: usize = 0;
        while (i < W) : (i += 2) {
            const c0 = try bg.add(Hv, .{ .k = 0.51 });
            const c1 = try bg.add(Hv, .{ .k = 0.49 });
            const add = try bg.add(Add2, .{});
            if (n_dist == 1) {
                try bg.connect(src, c0);
                try bg.connect(src, c1);
            } else {
                try bg.connect(dist[i / group], c0);
                try bg.connect(dist[(i + 1) / group], c1);
            }
            try bg.connect(c0, add.in.x);
            try bg.connect(c1, add.in.y);
            level[width] = add;
            width += 1;
        }
    }
    // Reduce the adder level down to one node.
    while (width > 1) {
        var next: [W]Adder = undefined;
        var w: usize = 0;
        var j: usize = 0;
        while (j + 1 < width) : (j += 2) {
            const add = try bg.add(Add2, .{});
            try bg.connect(level[j], add.in.x);
            try bg.connect(level[j + 1], add.in.y);
            next[w] = add;
            w += 1;
        }
        level = next;
        width = w;
    }
    const sink = try bg.add(BufSink, .{ .dest = out });
    try bg.connect(level[0], sink);
    return bg.commitWith(opts);
}

fn renderN(eng: *engine.Engine, token: engine.RealtimeToken, blocks: usize) void {
    var b: usize = 0;
    while (b < blocks) : (b += 1) eng.renderInto(token);
}

fn scenario(comptime W: usize, comptime iters: usize, comptime N: usize, io: std.Io, gpa: std.mem.Allocator, blocks: usize, label: []const u8) !void {
    const cores = @max(2, @min(std.Thread.getCpuCount() catch 2, 8));
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xBEEF01);
    var out: [N]Sample(f32) = undefined;

    const token = engine.enterRealtimeThread();
    defer token.leave();

    std.debug.print("\n--- {s}: W={d} chains x {d} iters, N={d}, {d} blocks ---\n", .{ label, W, iters, N, blocks });

    // Tier A baseline.
    var base_ns: u64 = 0;
    {
        var eng = try buildWide(W, iters, N, gpa, &input, &out, .{});
        defer eng.deinit();
        renderN(&eng, token, blocks / 8); // warm-up
        var t = h.Timer.start(io);
        renderN(&eng, token, blocks);
        base_ns = t.read();
        h.consume(out[0]);
        std.debug.print("  TierA (P=1)         {d:>8.2} ns/block  (baseline)\n", .{@as(f64, @floatFromInt(base_ns)) / @as(f64, @floatFromInt(blocks))});
    }

    const execs = [_]pan.TierBExecutor{ .level_barrier, .heft };
    for (execs) |exe| {
        var p: usize = 2;
        while (p <= cores) : (p += 1) {
            var eng = try buildWide(W, iters, N, gpa, &input, &out, .{ .cores = p, .force_workgroup = true, .tier_b_executor = exe });
            defer eng.deinit();
            if (!eng.tierBActive()) {
                std.debug.print("  TierB {s:<13} P={d}: NOT promoted (gate refused)\n", .{ @tagName(exe), p });
                continue;
            }
            renderN(&eng, token, blocks / 8); // warm-up + worker spawn
            var t = h.Timer.start(io);
            renderN(&eng, token, blocks);
            const ns = t.read();
            h.consume(out[0]);
            const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(blocks));
            const speedup = @as(f64, @floatFromInt(base_ns)) / @as(f64, @floatFromInt(ns));
            // `req` is the requested core budget; `workers` is what the gate actually
            // used (sized from the commit-time parallelism work/span), which CAPS the
            // speedup independent of `req` — a static byte-cost model under-estimates
            // the parallelism of a compute-heavy graph (a cheap mix node costs the
            // same per-byte as a heavy voice), so the worker count, not the core
            // budget, is the ceiling here. Live per-op CPU telemetry (the EWMA cost
            // refinement) lifts it on-device.
            std.debug.print("  TierB {s:<13} req={d:>2} workers={d:>2} (par={d:>4.1}): {d:>9.2} ns/block  {d:>5.2}x  spin={d:.0}\n", .{ @tagName(exe), p, eng.tierBWorkers(), eng.tierBParallelism(), per, speedup, eng.telemetry().spin_time });
        }
    }

    // The Tier-B concurrency-aware-colored scratch footprint vs the engine's Tier-A
    // colored footprint. The Tier-B per-edge plan is recolored on the schedule-time
    // interval graph to the peak-concurrent live-edge count; for a maximally-wide
    // graph (every value live at the mix) that equals the per-value count, so it does
    // not shrink below the colored figure — the shrink shows on reconvergent graphs.
    {
        var eng = try buildWide(W, iters, N, gpa, &input, &out, .{ .cores = cores, .force_workgroup = true });
        defer eng.deinit();
        std.debug.print("  footprint: TierA colored={d} B   TierB colored-scratch={d} B ({d} buffers)   workers={d}\n", .{ eng.currentPlan().pool_bytes + eng.currentPlan().persistent_bytes, eng.tierBScratchBytes(), eng.tierBScratchBuffers(), eng.tierBWorkers() });
    }
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    std.debug.print("=== Tier B (static-parallel RealtimeStreaming) throughput scaling ===\n", .{});
    // Methodology caveats (read the numbers with these in mind):
    //  - single-shot timing per config (no run-to-run variance reported);
    //  - `force_workgroup = true` with NO real device os_workgroup, so the workers are
    //    plain threads — the bounded-spin claim is not OS-enforced here (the on-device
    //    co-scheduling is what makes it hold);
    //  - the kernel is a synthetic latency-bound polynomial (stresses the parallel
    //    path; not representative of SIMD/memory-bound real DSP throughput);
    //  - `workers` (not the core budget) is the ceiling: the static byte-cost model
    //    under-estimates a compute-heavy graph's parallelism, so worker count caps
    //    below the available cores until live per-op telemetry refines the costs.
    std.debug.print("(single-shot; no real workgroup; synthetic kernel; worker count is gate-capped — see notes)\n", .{});
    // The flagship: a wide 16-chain heavy graph — many independent voices feeding a
    // mix, the shape where work/span ≫ 1 and parallelism pays.
    try scenario(16, 96, 512, io, gpa, 4096, "wide STRESS (16 heavy chains)");
    // A lighter, narrower wide graph: less compute per chain ⇒ the thread handoff is
    // a larger fraction (the honest overhead corner).
    try scenario(8, 24, 256, io, gpa, 8192, "wide LIGHT (8 chains)");
    // A wide 4-chain graph at a small block — the latency-sensitive RT corner.
    try scenario(4, 48, 128, io, gpa, 8192, "wide small-block (4 chains)");
}
