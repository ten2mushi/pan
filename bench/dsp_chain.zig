//! Benchmark: the P4 vertical-slice DSP chain and its blocks.
//!
//! Measures (never asserts an oracle): per-block ns/iter → frames/s + MB/s for
//! gain / biquad / pan; the gain→biquad→pan chain per-render time vs the N/Fs
//! deadline (the sub-5 ms / zero-xrun target as tracked numbers), cross-checked
//! against the engine's own `telemetry().deadline_headroom`; the static
//! `footprint_bytes` and byte-displacement-per-render; a **stress-mode** deep
//! chain; swept over precision (f32/f64) × block size. Build/run: `zig build
//! bench` (ReleaseFast). With `-Dbench-gate` it also asserts the committed
//! footprint baseline (a regression fails hard — footprint is deterministic).

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");
const build_options = @import("build_options");

const baseline_json = @embedFile("baselines/dsp_chain.json");

fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

/// A mono noise source over a preloaded buffer (a Map Source).
fn NoiseSource(comptime T: type) type {
    return struct {
        data: []const pan.types.Sample(T),
        cursor: usize = 0,
        pub fn process(self: *@This(), out: []pan.types.Sample(T)) void {
            for (out) |*o| {
                o.* = self.data[self.cursor];
                self.cursor += 1;
                if (self.cursor >= self.data.len) self.cursor = 0;
            }
        }
    };
}

/// Stereo discard sink: folds output into a checksum (defeats DCE), no device I/O.
/// Reads the stereo buffer through the planar view (L-plane, R-plane).
fn StereoSink(comptime T: type) type {
    return struct {
        checksum: T = 0,
        pub fn process(self: *@This(), in: pan.types.PlanarConst(T, .stereo)) void {
            var acc: T = self.checksum;
            for (in.plane(0), in.plane(1)) |l, r| acc += l + r;
            self.checksum = acc;
        }
    };
}
fn MonoSink(comptime T: type) type {
    return struct {
        checksum: T = 0,
        pub fn process(self: *@This(), in: []const pan.types.Sample(T)) void {
            var acc: T = self.checksum;
            for (in) |f| acc += f.ch[0];
            self.checksum = acc;
        }
    };
}

const warm = 1000;
const iters = 100_000;

/// Time a single Map block's `process` over an N-frame buffer; report ns/iter.
fn benchBlock(io: std.Io, comptime label: []const u8, comptime Block: type, blk: *Block, in: anytype, out: anytype) void {
    for (0..warm) |_| blk.process(in, out);
    var timer = h.Timer.start(io);
    for (0..iters) |_| blk.process(in, out);
    const ns = timer.read();
    h.consume(out.ptr);
    const ns_per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters));
    const fps = @as(f64, @floatFromInt(in.len)) / (ns_per / 1e9);
    std.debug.print("  {s}: {d:.1} ns/iter  {d:.2}M frames/s\n", .{ label, ns_per, fps / 1e6 });
}

fn benchChain(io: std.Io, comptime T: type, comptime N: usize) usize {
    const num = pan.numericFor(switch (T) {
        f32 => .f32,
        f64 => .f64,
        else => @compileError("bench: float precision only"),
    }, .{});
    const Src = NoiseSource(T);
    const Gain = pan.filters.Gain(num);
    const Biquad = pan.filters.Biquad(num);
    const Pan = pan.spatial.ConstantPowerPan(num);
    const Sink = StereoSink(T);

    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Src);
        const gain = gg.add(Gain);
        const biquad = gg.add(Biquad);
        const panner = gg.add(Pan);
        const sink = gg.add(Sink);
        gg.connect(pan.port.MapOutPort(Src), src, 0, pan.port.MapInPort(Gain), gain, 0);
        gg.connect(pan.port.MapOutPort(Gain), gain, 0, pan.port.MapInPort(Biquad), biquad, 0);
        gg.connect(pan.port.MapOutPort(Biquad), biquad, 0, pan.port.MapInPort(Pan), panner, 0);
        gg.connect(pan.port.MapOutPort(Pan), panner, 0, pan.port.MapInPort(Sink), sink, 0);
        break :blk gg;
    };

    var noise: [N]pan.types.Sample(T) = undefined;
    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    for (&noise) |*s| s.ch[0] = @floatCast(rng.random().float(f32) * 2.0 - 1.0);

    const Exec = pan.Executor(g, &.{ Src, Gain, Biquad, Pan, Sink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &noise },
        .{ .gain = 0.5 },
        .{ .coeffs = .{ .b0 = 0.2, .a1 = -0.8 } },
        .{ .pan = 0.25 },
        .{},
    } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    for (0..warm) |_| exec.render(token);
    var timer = h.Timer.start(io);
    for (0..iters) |_| exec.render(token);
    const ns = timer.read();
    h.consume(exec.instances[4].checksum);

    // Cross-check: feed the measured per-render time to the engine telemetry and
    // confirm its headroom agrees with the bench's own computation.
    const ns_per: u64 = ns / iters;
    exec.recordTiming(ns_per);
    const tele = exec.telemetry();

    const label = std.fmt.comptimePrint("gain→biquad→pan {s} N={d}", .{ @typeName(T), N });
    h.reportRender(label, ns, iters, N, 2, @sizeOf(T), 48_000, Exec.committed.footprint_bytes, h.byteDisplacement(g.node_count, &Exec.committed));
    std.debug.print("    telemetry: deadline_headroom={d:.1}%  per_block_cpu={d:.2}%  xruns={d}  guards_compiled_out={}\n", .{ tele.deadline_headroom * 100, tele.per_block_cpu * 100, tele.xrun_count, tele.guards_compiled_out });
    return Exec.committed.footprint_bytes;
}

/// Stress mode: a deep mono chain of `K` gains — worst-case op-list length and
/// sustained back-to-back renders.
fn benchStress(io: std.Io, comptime K: usize, comptime N: usize) void {
    const num = pan.numericFor(.f32, .{});
    const Src = NoiseSource(f32);
    const Gain = pan.filters.Gain(num);
    const Sink = MonoSink(f32);

    const gg2 = comptime blk: {
        @setEvalBranchQuota(100_000);
        var x = pan.graph.Graph.empty;
        x.block_size = N;
        const src = x.add(Src);
        var ids: [K]usize = undefined;
        for (0..K) |i| ids[i] = x.add(Gain);
        const sink = x.add(Sink);
        x.connect(pan.port.MapOutPort(Src), src, 0, pan.port.MapInPort(Gain), ids[0], 0);
        for (1..K) |i| x.connect(pan.port.MapOutPort(Gain), ids[i - 1], 0, pan.port.MapInPort(Gain), ids[i], 0);
        x.connect(pan.port.MapOutPort(Gain), ids[K - 1], 0, pan.port.MapInPort(Sink), sink, 0);
        break :blk x;
    };
    const types2 = comptime [_]type{Src} ++ ([_]type{Gain} ** K) ++ [_]type{Sink};

    var noise: [N]pan.types.Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(1);
    for (&noise) |*s| s.ch[0] = rng.random().float(f32) * 2.0 - 1.0;

    const Exec = pan.Executor(gg2, &types2);
    var exec: Exec = undefined;
    exec.instances[0] = .{ .data = &noise };
    inline for (1..K + 1) |i| exec.instances[i] = .{ .gain = 0.999 };
    exec.instances[K + 1] = .{};
    exec.tele = .{ .guards_compiled_out = !std.debug.runtime_safety };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    for (0..warm) |_| exec.render(token);
    var timer = h.Timer.start(io);
    for (0..iters) |_| exec.render(token);
    const ns = timer.read();
    h.consume(exec.instances[K + 1].checksum);
    const label = std.fmt.comptimePrint("STRESS deep chain K={d} gains N={d}", .{ K, N });
    h.reportRender(label, ns, iters, N, 1, @sizeOf(f32), 48_000, Exec.committed.footprint_bytes, h.byteDisplacement(gg2.node_count, &Exec.committed));
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("pan bench: DSP blocks + chain, Fs=48k\n", .{});

    // Per-block ns/iter (f32, N=512).
    const N = 512;
    const num = pan.numericFor(.f32, .{});
    var in: [N]pan.types.Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(2);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2.0 - 1.0;
    var out: [N]pan.types.Sample(f32) = undefined;
    // Plane-major stereo backing: an L-plane of N then an R-plane of N.
    var stereo_planes: [2 * N]f32 = undefined;
    const stereo_view = pan.types.Planar(f32, .stereo).fromBase(&stereo_planes, N);
    std.debug.print("per-block (f32, N={d}):\n", .{N});
    var gain = pan.filters.Gain(num){ .gain = 0.5 };
    benchBlock(io, "gain", pan.filters.Gain(num), &gain, @as([]const pan.types.Sample(f32), &in), @as([]pan.types.Sample(f32), &out));
    var biquad = pan.filters.Biquad(num){ .coeffs = .{ .b0 = 0.2, .a1 = -0.8 } };
    benchBlock(io, "biquad", pan.filters.Biquad(num), &biquad, @as([]const pan.types.Sample(f32), &in), @as([]pan.types.Sample(f32), &out));
    // Pan writes a planar stereo view, so time it directly (benchBlock's report
    // helpers assume an element slice with .len/.ptr; the view has neither).
    var panner = pan.spatial.ConstantPowerPan(num){ .pan = 0.25 };
    {
        const in_slice = @as([]const pan.types.Sample(f32), &in);
        for (0..warm) |_| panner.process(in_slice, stereo_view);
        var timer = h.Timer.start(io);
        for (0..iters) |_| panner.process(in_slice, stereo_view);
        const ns = timer.read();
        h.consume(stereo_view.plane(0).ptr);
        const ns_per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters));
        const fps = @as(f64, @floatFromInt(N)) / (ns_per / 1e9);
        std.debug.print("  {s}: {d:.1} ns/iter  {d:.2}M frames/s\n", .{ "pan", ns_per, fps / 1e6 });
    }

    // The chain, swept over precision × block size, with the telemetry cross-check.
    std.debug.print("chain (per-render vs deadline):\n", .{});
    var fp512: usize = 0;
    inline for (.{ 128, 256, 512, 1024 }) |bn| {
        _ = benchChain(io, f32, bn);
        if (bn == 512) fp512 = benchChain(io, f32, 512);
    }
    _ = benchChain(io, f64, 512);

    // Stress mode.
    // Deep chains, bounded by the comptime graph's max_nodes (src + K + sink ≤ 64).
    std.debug.print("stress:\n", .{});
    benchStress(io, 32, 512);
    benchStress(io, 60, 256);

    // Opt-in footprint gate: a deterministic regression fails the run.
    if (build_options.bench_gate) {
        const dyn = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, baseline_json, .{});
        defer dyn.deinit();
        const want: usize = @intCast(dyn.value.object.get("chain_f32_n512_footprint_bytes").?.integer);
        std.debug.print("bench-gate: chain f32 N=512 footprint {d}B (baseline {d}B)\n", .{ fp512, want });
        if (fp512 != want) {
            std.debug.print("BENCH-GATE FAIL: footprint regressed ({d} != baseline {d})\n", .{ fp512, want });
            std.process.exit(1);
        }
        std.debug.print("bench-gate: footprint baseline OK\n", .{});
    }
}
