//! Benchmark: feedback primitives — the P6 measurement set.
//!
//! Measures (never asserts an oracle — correctness lives in `tests/`):
//!   (a) the persistent/feedback FOOTPRINT term: the delay-line bytes a graph-level
//!       `DelayLine`-in-a-cycle adds (the comptime `footprint_bytes` +
//!       `persistent_bytes` split);
//!   (b) THROUGHPUT of the two feedback idioms — the fused tight-feedback `Comb`
//!       kernel (one `Map`, sample-accurate internal loop) vs the graph-level
//!       `DelayLine`-in-a-cycle rendered through the `Executor` (block-granular z⁻¹);
//!   (c) the FTZ denormal CPU-spike avoidance: a decaying comb tail driven into
//!       subnormal magnitudes, timed WITH flush-to-zero set (the realtime token)
//!       vs WITHOUT (the default gradual-underflow environment) — the denormal
//!       stall the `enterRealtimeThread` token exists to prevent.
//!
//! Build/run: `zig build bench` (ReleaseFast). No `-Dbench-gate` baseline is added
//! here: (a) is deterministic but not the gated chain, and (b)/(c) are timings.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.types.Sample;
const f32num = pan.numericFor(.f32, .{});

const warm = 1000;
const iters = 100_000;

/// A mono source over a preloaded buffer (a Map Source).
const NoiseSource = struct {
    data: []const Sample(f32),
    cursor: usize = 0,
    pub fn process(self: *@This(), out: []Sample(f32)) void {
        for (out) |*o| {
            o.* = self.data[self.cursor];
            self.cursor += 1;
            if (self.cursor >= self.data.len) self.cursor = 0;
        }
    }
};

/// A two-input summer: out = dry + wet (the feedback injection point).
const Sum2 = struct {
    pub fn process(self: *@This(), dry: []const Sample(f32), wet: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (dry, wet, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
    }
};

const MonoSink = struct {
    checksum: f32 = 0,
    pub fn process(self: *@This(), in: []const Sample(f32)) void {
        var acc: f32 = self.checksum;
        for (in) |f| acc += f.ch[0];
        self.checksum = acc;
    }
};

const N = 512;
const D = 480; // delay length (samples)

/// (a) The persistent/feedback footprint of a graph-level comb (worked example B
/// shape): source → Sum → DelayLine(D) → Gain → sink, with Gain → Sum feedback.
fn reportFeedbackFootprint() void {
    const Gain = pan.filters.Gain(f32num);
    const Delay = pan.DelayLine(Sample(f32), D);
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(NoiseSource);
        const sum = gg.add(Sum2);
        const dly = gg.add(Delay);
        const gain = gg.add(Gain);
        const snk = gg.add(MonoSink);
        gg.connect(pan.port.MapOutPort(NoiseSource), src, 0, pan.port.MapInPortAt(Sum2, 0), sum, 0);
        gg.connect(pan.port.MapOutPort(Sum2), sum, 0, pan.port.MapInPort(Delay), dly, 0);
        gg.connect(pan.port.MapOutPort(Delay), dly, 0, pan.port.MapInPort(Gain), gain, 0);
        gg.connect(pan.port.MapOutPort(Gain), gain, 0, pan.port.MapInPort(MonoSink), snk, 0);
        gg.connectFeedback(pan.port.MapOutPort(Gain), gain, 0, pan.port.MapInPortAt(Sum2, 1), sum, 1);
        break :blk gg;
    };
    const plan = comptime pan.commitComptime(g) catch unreachable;
    // The H2 figure counts the delay ring; the executor pool holds the persistent
    // z⁻¹ tail separately (one block of N per feedback edge).
    std.debug.print(
        "  feedback footprint: H2 footprint_bytes={d}B  (pool_bytes={d}B + persistent z\u{207b}\u{00b9} tail={d}B)\n" ++
            "    DelayLine(D={d}) ring term = {d}B; the feedback edge adds the {d}B persistent tail, NOT the H2 figure\n",
        .{ plan.footprint_bytes, plan.pool_bytes, plan.persistent_bytes, D, D * @sizeOf(Sample(f32)), plan.persistent_bytes },
    );
}

/// (b) Fused tight-feedback `Comb` throughput (the sample-accurate idiom).
fn benchFusedComb(io: std.Io, noise: []const Sample(f32)) void {
    var comb = pan.Comb(f32num, D){ .delay = D, .feedback = 0.5 };
    var out: [N]Sample(f32) = undefined;
    const in = noise[0..N];
    for (0..warm) |_| comb.process(in, &out);
    var timer = h.Timer.start(io);
    for (0..iters) |_| comb.process(in, &out);
    const ns = timer.read();
    h.consume(out[0].ch[0]);
    const ns_per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters));
    std.debug.print("  fused Comb (sample-accurate, one Map): {d:.1} ns/render  {d:.2}M frames/s\n", .{ ns_per, @as(f64, N) / (ns_per / 1e9) / 1e6 });
}

/// (b) Graph-level DelayLine-in-a-cycle throughput (block-granular feedback),
/// rendered through the bound Executor (gather/scatter + the persistent z⁻¹ tail).
fn benchGraphComb(io: std.Io, noise: []Sample(f32)) void {
    const Gain = pan.filters.Gain(f32num);
    const Delay = pan.DelayLine(Sample(f32), D);
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(NoiseSource);
        const sum = gg.add(Sum2);
        const dly = gg.add(Delay);
        const gain = gg.add(Gain);
        const snk = gg.add(MonoSink);
        gg.connect(pan.port.MapOutPort(NoiseSource), src, 0, pan.port.MapInPortAt(Sum2, 0), sum, 0);
        gg.connect(pan.port.MapOutPort(Sum2), sum, 0, pan.port.MapInPort(Delay), dly, 0);
        gg.connect(pan.port.MapOutPort(Delay), dly, 0, pan.port.MapInPort(Gain), gain, 0);
        gg.connect(pan.port.MapOutPort(Gain), gain, 0, pan.port.MapInPort(MonoSink), snk, 0);
        gg.connectFeedback(pan.port.MapOutPort(Gain), gain, 0, pan.port.MapInPortAt(Sum2, 1), sum, 1);
        break :blk gg;
    };
    const Exec = pan.Executor(g, &.{ NoiseSource, Sum2, Delay, Gain, MonoSink });
    var exec: Exec = .{ .instances = .{ .{ .data = noise }, .{}, .{}, .{ .gain = 0.5 }, .{} } };
    const token = pan.enterRealtimeThread();
    defer token.leave();
    for (0..warm) |_| exec.render(token);
    var timer = h.Timer.start(io);
    for (0..iters) |_| exec.render(token);
    const ns = timer.read();
    h.consume(exec.instances[4].checksum);
    const ns_per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters));
    std.debug.print("  graph-level DelayLine-in-a-cycle (Executor, block z\u{207b}\u{00b9}): {d:.1} ns/render  {d:.2}M frames/s\n", .{ ns_per, @as(f64, N) / (ns_per / 1e9) / 1e6 });
}

/// (c) FTZ denormal avoidance: drive a comb tail into the subnormal range, then
/// time many zero-input renders WITH flush-to-zero vs WITHOUT. Without FTZ the
/// subnormal ring values incur the ~10–100× per-op denormal stall on affected CPUs.
fn benchDenormalFtz(io: std.Io) void {
    const reps = 200_000;
    // Build a comb whose ring is full of tiny subnormal-ish values: feed an impulse,
    // decay hard, then process silence so the state underflows toward subnormals.
    const Comb = pan.Comb(f32num, 64);

    // WITH FTZ (token sets flush-to-zero on this thread).
    const with_ns = blk: {
        var comb = Comb{ .delay = 64, .feedback = 0.5 };
        var imp: [N]Sample(f32) = @splat(.{ .ch = .{0} });
        imp[0] = .{ .ch = .{1e-20} }; // start already tiny → quickly subnormal
        var out: [N]Sample(f32) = undefined;
        const token = pan.enterRealtimeThread();
        comb.process(&imp, &out); // seed the ring
        var silence: [N]Sample(f32) = @splat(.{ .ch = .{0} });
        var timer = h.Timer.start(io);
        for (0..reps) |_| comb.process(&silence, &out);
        const ns = timer.read();
        h.consume(out[0].ch[0]);
        token.leave(); // restore the default (gradual-underflow) FP environment
        break :blk ns;
    };

    // WITHOUT FTZ (default gradual-underflow environment — token left/restored).
    const without_ns = blk: {
        var comb = Comb{ .delay = 64, .feedback = 0.5 };
        var imp: [N]Sample(f32) = @splat(.{ .ch = .{0} });
        imp[0] = .{ .ch = .{1e-20} };
        var out: [N]Sample(f32) = undefined;
        comb.process(&imp, &out);
        var silence: [N]Sample(f32) = @splat(.{ .ch = .{0} });
        var timer = h.Timer.start(io);
        for (0..reps) |_| comb.process(&silence, &out);
        const ns = timer.read();
        h.consume(out[0].ch[0]);
        break :blk ns;
    };

    const with_per = @as(f64, @floatFromInt(with_ns)) / @as(f64, @floatFromInt(reps));
    const without_per = @as(f64, @floatFromInt(without_ns)) / @as(f64, @floatFromInt(reps));
    std.debug.print(
        "  denormal tail: WITH FTZ {d:.1} ns/render  vs  WITHOUT FTZ {d:.1} ns/render  ({d:.2}x)\n" ++
            "    (a >1x ratio is the denormal CPU stall the realtime token's flush-to-zero prevents; ~1x ⇒ this CPU/build already flushes)\n",
        .{ with_per, without_per, without_per / with_per },
    );
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("pan bench: feedback primitives (P6), Fs=48k N={d}\n", .{N});

    var noise: [4096]Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(0xFEED);
    for (&noise) |*s| s.ch[0] = rng.random().float(f32) * 2.0 - 1.0;

    std.debug.print("footprint:\n", .{});
    reportFeedbackFootprint();

    std.debug.print("throughput (fused vs graph-level feedback idiom):\n", .{});
    benchFusedComb(io, &noise);
    benchGraphComb(io, &noise);

    std.debug.print("denormals (FTZ avoidance):\n", .{});
    benchDenormalFtz(io);
}
