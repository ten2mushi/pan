//! Benchmark: a **real `pan.filters.Biquad` cascade** through OfflineBatch —
//! representative ABSOLUTE throughput (unlike the synthetic FIR in
//! `offline_bench.zig`, whose naive O(taps) kernel exists only to manufacture a
//! compute-bound parallel workload). A cascade of N transposed-DF-II biquads is a
//! realistic EQ / crossover / Linkwitz-Riley filter (2·order = 2N), and the block
//! is the SAME one that ships in the RT engine — its kernel is lowered through the
//! Compute HAL (`@Vector` where the lane vectorizes; a biquad's per-sample
//! recurrence is scalar across samples but the block is the production code path).
//!
//! MEASURES (never asserts an oracle): per-sample cost, Msample/s, MB/s, and ×
//! realtime vs the 48 kHz deadline for `renderSequential` (the absolute number);
//! and `renderPipeline` speedup — a biquad cascade is the case the FIR bench
//! could NOT show, because its stages are BALANCED (every stage is one identical
//! biquad), so pipeline parallelism (throughput = 1/bottleneck-stage) scales with
//! the cascade depth. Biquads are IIR (no `warmup_samples`) ⇒ not chunkable, so
//! `render()` routes a cascade through pipeline — exactly the W1 fallback.
//! Build/run: `zig build bench` (ReleaseFast).

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.Sample;
const Source = pan.offline.Source;
const Sink = pan.offline.Sink;
const num = pan.numericFor(.f32, .{});
const Biquad = pan.filters.Biquad(num);

/// A stable 2nd-order section (complex-conjugate poles at |z| = √0.2 ≈ 0.45), so
/// the cascade stays bounded over the millions of samples a bench renders.
const coeffs: pan.filters.Coeffs(f32) = .{ .b0 = 0.15, .b1 = 0.3, .b2 = 0.15, .a1 = -0.5, .a2 = 0.2 };

/// Source → Biquad×D → Sink, built at comptime for a comptime cascade depth `D`.
fn cascadeGraph(comptime D: usize, comptime N: usize) pan.graph.Graph {
    var g = pan.graph.Graph.empty;
    g.block_size = N;
    const src = g.add(Source);
    var prev = src;
    var prev_source = true;
    inline for (0..D) |_| {
        const bq = g.add(Biquad);
        if (prev_source) {
            g.connect(pan.port.MapOutPort(Source), prev, 0, pan.port.MapInPort(Biquad), bq, 0);
        } else {
            g.connect(pan.port.MapOutPort(Biquad), prev, 0, pan.port.MapInPort(Biquad), bq, 0);
        }
        prev = bq;
        prev_source = false;
    }
    const sink = g.add(Sink);
    g.connect(pan.port.MapOutPort(Biquad), prev, 0, pan.port.MapInPort(Sink), sink, 0);
    return g;
}

fn cascadeNodes(comptime D: usize) [D + 2]type {
    var nb: [D + 2]type = undefined;
    nb[0] = Source;
    inline for (1..D + 1) |i| nb[i] = Biquad;
    nb[D + 1] = Sink;
    return nb;
}

fn fillNoise(buf: []f32, seed: u64) void {
    var s = seed;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = @as(f32, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(s >> 16)))))) / 2.147483648e9;
    }
}

fn scenario(comptime D: usize, comptime N: usize, io: std.Io, gpa: std.mem.Allocator, T: usize) !void {
    const g = comptime cascadeGraph(D, N);
    const node_blocks = comptime cascadeNodes(D);
    const OB = pan.OfflineBatch(g, &node_blocks);

    var tmpl: OB.InstanceTuple = undefined;
    tmpl[0] = Source{};
    inline for (1..D + 1) |i| tmpl[i] = Biquad{ .coeffs = coeffs };
    tmpl[D + 1] = Sink{};

    const input = try gpa.alloc(f32, T);
    defer gpa.free(input);
    const seq = try gpa.alloc(f32, T);
    defer gpa.free(seq);
    const pipe = try gpa.alloc(f32, T);
    defer gpa.free(pipe);
    fillNoise(input, 1);

    OB.renderSequential(tmpl, input, seq); // warm (prime the page cache)

    var ns_seq: u64 = std.math.maxInt(u64);
    var ns_pipe: u64 = std.math.maxInt(u64);
    var exact = true;
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        var t = h.Timer.start(io);
        OB.renderSequential(tmpl, input, seq);
        ns_seq = @min(ns_seq, t.read());
        h.consume(seq[T - 1]);

        t.reset();
        try OB.renderPipeline(gpa, tmpl, input, pipe);
        ns_pipe = @min(ns_pipe, t.read());
        exact = exact and std.mem.eql(u8, std.mem.sliceAsBytes(seq), std.mem.sliceAsBytes(pipe));
    }

    const tf: f64 = @floatFromInt(T);
    const ns_per_sample = @as(f64, @floatFromInt(ns_seq)) / tf;
    const msample_s = tf / (@as(f64, @floatFromInt(ns_seq)) / 1e9) / 1e6;
    const mb_s = tf * @sizeOf(f32) / (@as(f64, @floatFromInt(ns_seq)) / 1e9) / (1024.0 * 1024.0);
    const x_realtime = (tf / 48_000.0 * 1e9) / @as(f64, @floatFromInt(ns_seq));
    const pipe_speedup = @as(f64, @floatFromInt(ns_seq)) / @as(f64, @floatFromInt(ns_pipe));

    std.debug.print(
        "{d}x biquad cascade ({d}th-order, f32, T={d} ≈ {d}s @48k):\n" ++
            "  sequential : {d:>6.2} ns/sample  {d:>6.1} Msample/s  {d:>6.0} MB/s  {d:>7.0}x realtime  (footprint {d} B)\n" ++
            "  pipeline   : {d} balanced stages → speedup {d:.2}x  (bit-exact vs seq: {})\n",
        .{
            D,                            2 * D,     T,            T / 48000,
            ns_per_sample,                msample_s, mb_s,         x_realtime,
            OB.committed.footprint_bytes, D + 2,     pipe_speedup, exact,
        },
    );
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    std.debug.print("=== Biquad cascade (real pan.filters.Biquad) — representative throughput ===\n", .{});
    try scenario(2, 512, io, gpa, 1 << 22); // 4th-order
    try scenario(4, 512, io, gpa, 1 << 22); // 8th-order
    try scenario(8, 512, io, gpa, 1 << 22); // 16th-order — a deep, balanced pipeline
}
