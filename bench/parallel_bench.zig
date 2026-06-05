//! Benchmark: the P15 Tier-B static-parallel RealtimeStreaming overlay.
//!
//! MEASURES (never asserts an oracle — correctness lives in `tests/`): a wide
//! graph (a source fanning out into many independent voices summed by an adder
//! tree — the Tier-B target shape) rendered block-by-block under
//!   - Tier A (the frozen single-core sequential replay, `cores = 1`);
//!   - Tier B level-barrier and HEFT, across worker counts P = 2..ncores;
//! reporting, per config, the **min and median over N reps** of the wall-clock
//! ns/block, the speedup vs Tier A, the **×realtime headroom** (the 48 kHz block
//! deadline ÷ render time — density headroom, not just relative speedup), the
//! per-worker spin time (the ≈ witness the cross-worker handshake stays bounded),
//! and the Tier-B concurrent footprint.
//!
//! The voice kernels are **real DSP** — a biquad lowpass cascade (IIR, stateful,
//! exercises decaying tails → the FTZ/denormal path) and an FIR (M-tap boxcar,
//! compute+memory) — plus a synthetic polynomial for contrast. Real kernels matter
//! twice over: they are representative throughput, and a biquad/FIR genuinely costs
//! more per sample than the cheap adder/distributor plumbing — the per-kernel cost
//! asymmetry the static byte-cost model is blind to (the worker-count cap below).
//!
//! Build/run: `zig build bench` (ReleaseFast). The ReleaseSafe-vs-ReleaseFast delta
//! (run both) prices the safety-check cost.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.Sample;
const engine = pan.engine;

/// Reps per timed config; we report the MIN (the least-perturbed run — the machine's
/// true capability) and the MEDIAN (typical under this run's scheduling noise).
const Reps = 5;

// ===========================================================================
// Voice kernels — real DSP (and one synthetic), all mono Sample(f32) Maps.
// ===========================================================================

/// A cascade of `stages` 2nd-order Butterworth lowpass biquads (fc ≈ 0.1·Fs),
/// Direct-Form-II-transposed. Stable (poles well inside the unit circle, unity DC
/// gain). Internal z⁻¹ state only — no graph-level feedback edge, so the wide bank
/// stays embarrassingly parallel across voices. This is the canonical IIR voice.
fn BiquadCascade(comptime stages: usize) type {
    return struct {
        const Self = @This();
        // 2nd-order Butterworth LP, fc = 0.1·Fs (textbook-stable).
        const b0: f32 = 0.0675;
        const b1: f32 = 0.1349;
        const b2: f32 = 0.0675;
        const a1: f32 = -1.1430;
        const a2: f32 = 0.4128;
        z1: [stages]f32 = [_]f32{0} ** stages,
        z2: [stages]f32 = [_]f32{0} ** stages,
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            for (in, out) |x, *o| {
                var v: f32 = x.ch[0];
                var s: usize = 0;
                while (s < stages) : (s += 1) {
                    const y = b0 * v + self.z1[s];
                    self.z1[s] = b1 * v - a1 * y + self.z2[s];
                    self.z2[s] = b2 * v - a2 * y;
                    v = y;
                }
                o.ch[0] = v;
            }
        }
    };
}

/// An `taps`-tap FIR (boxcar moving average — definitionally stable). A ring of the
/// last `taps` inputs; per sample a length-`taps` dot product. Real compute + memory
/// stride, internal state only.
fn Fir(comptime taps: usize) type {
    return struct {
        const Self = @This();
        z: [taps]f32 = [_]f32{0} ** taps,
        pos: usize = 0,
        const coeff: f32 = 1.0 / @as(f32, @floatFromInt(taps));
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            for (in, out) |x, *o| {
                self.z[self.pos] = x.ch[0];
                var acc: f32 = 0;
                var k: usize = 0;
                var idx = self.pos;
                while (k < taps) : (k += 1) {
                    acc += coeff * self.z[idx];
                    idx = if (idx == 0) taps - 1 else idx - 1;
                }
                self.pos = if (self.pos + 1 == taps) 0 else self.pos + 1;
                o.ch[0] = acc;
            }
        }
    };
}

/// A synthetic CPU-heavy stateless Map (iterated polynomial) — kept for contrast with
/// the real kernels and continuity with the prior bench.
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

/// A cheap pass-through — the fan-out distributor (and a deliberately-light node so
/// the heavy voices dominate the work, the realistic cost asymmetry).
const Pass = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
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

/// Build the wide graph (W a power of two ≥ 2): source → W `Voice` chains → balanced
/// adder tree → sink, with a one-level cheap `Pass` distributor when W > 8 to respect
/// the 8-port fan-out ceiling. Caller owns the engine.
fn buildWide(
    comptime W: usize,
    comptime Voice: type,
    comptime N: usize,
    alloc: std.mem.Allocator,
    input: [*]const Sample(f32),
    out: [*]Sample(f32),
    opts: engine.EngineOptions,
) !engine.Engine {
    comptime std.debug.assert(W >= 2 and (W & (W - 1)) == 0);
    var bg = pan.Graph.init(alloc, cfg(N));
    errdefer bg.deinit();
    const src = try bg.add(BufSource, .{ .data = input });

    const Adder = @TypeOf(try bg.add(Add2, .{}));
    const Passh = @TypeOf(try bg.add(Pass, .{}));

    const group: usize = if (W > 8) 4 else W;
    const n_dist: usize = W / group;
    var dist: [W]Passh = undefined; // only the n_dist>1 slots are used
    {
        var d: usize = 0;
        while (d < n_dist) : (d += 1) {
            if (n_dist == 1) {
                dist[d] = undefined;
            } else {
                const dg = try bg.add(Pass, .{});
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
            const c0 = try bg.add(Voice, .{});
            const c1 = try bg.add(Voice, .{});
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

const Stat = struct { min: f64, med: f64 };

/// Warm up once (also spawns the worker pool), then time `Reps` passes and return the
/// min and median ns/block. Consumes the output each pass so DCE cannot delete it.
fn timeBest(eng: *engine.Engine, token: engine.RealtimeToken, io: std.Io, blocks: usize, out: []const Sample(f32)) Stat {
    renderN(eng, token, @max(blocks / 8, 1)); // warm-up + worker spawn
    var s: [Reps]f64 = undefined;
    var r: usize = 0;
    while (r < Reps) : (r += 1) {
        var t = h.Timer.start(io);
        renderN(eng, token, blocks);
        const ns = t.read();
        s[r] = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(blocks));
        h.consume(out[0]);
    }
    // Insertion sort (Reps is tiny) → min = s[0], median = s[Reps/2].
    var a: usize = 1;
    while (a < Reps) : (a += 1) {
        const key = s[a];
        var b: isize = @as(isize, @intCast(a)) - 1;
        while (b >= 0 and s[@intCast(b)] > key) : (b -= 1) s[@intCast(b + 1)] = s[@intCast(b)];
        s[@intCast(b + 1)] = key;
    }
    return .{ .min = s[0], .med = s[Reps / 2] };
}

fn scenario(comptime W: usize, comptime Voice: type, comptime N: usize, io: std.Io, gpa: std.mem.Allocator, blocks: usize, label: []const u8) !void {
    const cores = @max(2, @min(std.Thread.getCpuCount() catch 2, 8));
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xBEEF01);
    var out: [N]Sample(f32) = undefined;

    const token = engine.enterRealtimeThread();
    defer token.leave();

    // The hard RT deadline for one block at 48 kHz — the reference the ×RT headroom
    // is measured against (how many times realtime a single render fits the budget).
    const budget_ns: f64 = @as(f64, @floatFromInt(N)) / 48_000.0 * 1e9;

    std.debug.print("\n--- {s}: W={d}, N={d}, {d} blocks x {d} reps ---\n", .{ label, W, N, blocks, Reps });
    std.debug.print("  RT budget @48k: {d:.0} ns/block\n", .{budget_ns});

    // Tier A baseline.
    var base_min: f64 = 0;
    {
        var eng = try buildWide(W, Voice, N, gpa, &input, &out, .{});
        defer eng.deinit();
        const st = timeBest(&eng, token, io, blocks, &out);
        base_min = st.min;
        std.debug.print("  TierA (P=1)          min {d:>9.2}  med {d:>9.2} ns   {d:>5.2}x RT  (baseline)\n", .{ st.min, st.med, budget_ns / st.min });
    }

    const execs = [_]pan.TierBExecutor{ .level_barrier, .heft };
    for (execs) |exe| {
        var p: usize = 2;
        while (p <= cores) : (p += 1) {
            var eng = try buildWide(W, Voice, N, gpa, &input, &out, .{ .cores = p, .force_workgroup = true, .tier_b_executor = exe });
            defer eng.deinit();
            if (!eng.tierBActive()) {
                std.debug.print("  TierB {s:<13} P={d}: NOT promoted (gate refused)\n", .{ @tagName(exe), p });
                continue;
            }
            const st = timeBest(&eng, token, io, blocks, &out);
            const speedup = base_min / st.min;
            // `req` is the requested budget; `workers` is what the gate actually used,
            // sized from the commit-time parallelism (work/span over the static
            // byte-cost model). That model weighs a cheap adder/Pass the same per byte
            // as a heavy biquad voice, so it UNDER-estimates a compute-heavy graph's
            // parallelism → `workers` caps below the core budget. The cap, not the
            // runtime, is the ceiling here (per-kernel costs / live telemetry lift it).
            std.debug.print("  TierB {s:<13} req={d:>2} workers={d:>2} (par={d:>4.1}): min {d:>9.2} ns  {d:>5.2}x  {d:>5.2}x RT  spin={d:.0}\n", .{ @tagName(exe), p, eng.tierBWorkers(), eng.tierBParallelism(), st.min, speedup, budget_ns / st.min, eng.telemetry().spin_time });
        }
    }

    // The Tier-B concurrency-aware-colored scratch footprint vs the engine's Tier-A
    // colored footprint (peak-concurrent live edges; for a maximally-wide mix this
    // equals the per-value count, so it does not shrink below colored — the shrink
    // shows on reconvergent graphs).
    {
        var eng = try buildWide(W, Voice, N, gpa, &input, &out, .{ .cores = cores, .force_workgroup = true });
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
    // Methodology (read the numbers with these in mind):
    //  - min/median over N reps per config (NOT single-shot) — the min is the
    //    least-perturbed run; run on a quiesced machine for the cleanest figures;
    //  - REAL DSP voice kernels (biquad LP cascade, FIR) + one synthetic for contrast;
    //  - `force_workgroup = true` with NO real device os_workgroup, so workers are
    //    plain threads — the bounded-spin claim is not OS-enforced here (on-device
    //    co-scheduling is what makes it hold; watch the spin count past the worker peak);
    //  - `workers` (not the core budget) is the ceiling: the static byte-cost model
    //    under-estimates a compute-heavy graph's parallelism, so the worker count caps
    //    below the available cores until per-kernel costs / live telemetry refine it.
    std.debug.print("(min-of-{d} reps; real biquad/FIR kernels; no real workgroup; worker count is gate-capped — see notes)\n", .{Reps});

    // Real-kernel flagships: a wide bank of independent IIR / FIR voices feeding a mix
    // — the shape where work/span ≫ 1 and parallelism pays.
    try scenario(16, BiquadCascade(4), 512, io, gpa, 2048, "wide biquad x4 cascade (16 IIR voices)");
    try scenario(16, Fir(64), 512, io, gpa, 2048, "wide FIR 64-tap (16 voices)");
    // Synthetic, for contrast / continuity with the prior bench.
    try scenario(16, Heavy(96), 512, io, gpa, 2048, "wide synthetic poly (16 chains)");
    // Lighter / narrower corners.
    try scenario(8, BiquadCascade(2), 256, io, gpa, 4096, "wide biquad x2 (8 IIR voices)");
    try scenario(4, Fir(32), 128, io, gpa, 4096, "wide FIR 32-tap small-block (4 voices)");
}
