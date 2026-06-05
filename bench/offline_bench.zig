//! Benchmark: the P14 OfflineBatch (Tier C) throughput-scaling flagship.
//!
//! MEASURES (never asserts an oracle — correctness lives in `tests/`): the
//! file→file offline render of a long timeline through `OfflineBatch`, comparing
//!   - sequential (`K=1`) vs data-parallel chunked (`K=ncores`) — the near-linear
//!     speedup vs cores and the chunked MB/s throughput;
//!   - the pipeline (stage-per-thread + rings) throughput;
//!   - a STRESS workload (a heavier per-sample FIR kernel) where the parallelism
//!     has more work to amortise;
//! and prints the O2 pre-sized footprint (per-chunk pools + scratch; pipeline
//! rings). Build/run: `zig build bench` (ReleaseFast). A bench warms up, times
//! many samples of work, and consumes every result so DCE cannot delete it.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.Sample;
const Source = pan.offline.Source;
const Sink = pan.offline.Sink;

/// A moving-average FIR — finite memory ⇒ exact warm-up (chunkable, bit-exact).
fn Fir(comptime taps: usize) type {
    return struct {
        hist: [taps]f32 = @splat(0),
        const Self = @This();
        pub const warmup_samples: usize = taps - 1;
        pub const warmup_exact: bool = true;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            for (in, out) |x, *y| {
                var k: usize = taps - 1;
                while (k > 0) : (k -= 1) self.hist[k] = self.hist[k - 1];
                self.hist[0] = x.ch[0];
                var acc: f32 = 0;
                for (self.hist) |hh| acc += hh;
                y.ch[0] = acc / @as(f32, @floatFromInt(taps));
            }
        }
    };
}

fn firGraph(comptime taps: usize, comptime N: usize) pan.graph.Graph {
    var g = pan.graph.Graph.empty;
    g.block_size = N;
    const s = g.add(Source);
    const f = g.add(Fir(taps));
    const k = g.add(Sink);
    g.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(Fir(taps)), f, 0);
    g.connect(pan.port.MapOutPort(Fir(taps)), f, 0, pan.port.MapInPort(Sink), k, 0);
    return g;
}

fn fillNoise(buf: []f32, seed: u64) void {
    var s = seed;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = @as(f32, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(s >> 16)))))) / 2.147483648e9;
    }
}

fn mbPerS(samples: usize, ns: u64) f64 {
    const bytes: f64 = @floatFromInt(samples * @sizeOf(f32));
    return bytes / (@as(f64, @floatFromInt(ns)) / 1e9) / (1024.0 * 1024.0);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
fn speedup(a: u64, b: u64) f64 {
    return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
}

/// One scenario: a `taps`-tap FIR over `T` samples. Times sequential, chunked at
/// K=cores AND K=4·cores (oversubscription lets the OS balance the 12P/4E
/// asymmetry — equal `K=cores` chunks straggler-bind on the slow E-cores), and
/// pipeline; reports MB/s + speedup + footprint (min of 3 reps each — one-shot
/// timings are unreliable on an asymmetric machine). The chunk outputs are
/// bit-exactness-checked against the sequential reference.
fn scenario(comptime taps: usize, comptime N: usize, io: std.Io, gpa: std.mem.Allocator, T: usize, label: []const u8) !void {
    const g = comptime firGraph(taps, N);
    const OB = pan.OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    const input = try gpa.alloc(f32, T);
    defer gpa.free(input);
    const seq = try gpa.alloc(f32, T);
    defer gpa.free(seq);
    const par = try gpa.alloc(f32, T);
    defer gpa.free(par);
    const pipe = try gpa.alloc(f32, T);
    defer gpa.free(pipe);
    fillNoise(input, 1);

    const cores = std.Thread.getCpuCount() catch 1;
    const reps = 3;

    OB.renderSequential(tmpl, input, seq); // warm (also primes the page cache)

    var ns_seq: u64 = std.math.maxInt(u64);
    var ns_k1: u64 = std.math.maxInt(u64);
    var ns_k4: u64 = std.math.maxInt(u64);
    var ns_pipe: u64 = std.math.maxInt(u64);
    var exact1 = true;
    var exact4 = true;
    var r: usize = 0;
    while (r < reps) : (r += 1) {
        var t = h.Timer.start(io);
        OB.renderSequential(tmpl, input, seq);
        ns_seq = @min(ns_seq, t.read());
        h.consume(seq[T - 1]);

        t.reset();
        try OB.renderChunked(gpa, tmpl, input, par, cores);
        ns_k1 = @min(ns_k1, t.read());
        exact1 = exact1 and std.mem.eql(u8, std.mem.sliceAsBytes(seq), std.mem.sliceAsBytes(par));

        t.reset();
        try OB.renderChunked(gpa, tmpl, input, par, 4 * cores);
        ns_k4 = @min(ns_k4, t.read());
        exact4 = exact4 and std.mem.eql(u8, std.mem.sliceAsBytes(seq), std.mem.sliceAsBytes(par));

        t.reset();
        try OB.renderPipeline(gpa, tmpl, input, pipe);
        ns_pipe = @min(ns_pipe, t.read());
        h.consume(pipe[T - 1]);
    }

    std.debug.print(
        "{s} (taps={d}, T={d} samples ≈ {d}s @48k, cores={d} [12P+4E]):\n" ++
            "  sequential       : {d:>6.1} ms  {d:>6.0} MB/s\n" ++
            "  chunked K={d:<3}     : {d:>6.1} ms  {d:>6.0} MB/s  speedup {d:.2}x  (bit-exact: {})\n" ++
            "  chunked K={d:<3}     : {d:>6.1} ms  {d:>6.0} MB/s  speedup {d:.2}x  (bit-exact: {})\n" ++
            "  pipeline (3-stage): {d:>6.1} ms  {d:>6.0} MB/s  (bottleneck-bound: 1 stage = all work)\n" ++
            "  footprint        : chunked@K={d} {d} KiB   pipeline {d} B\n",
        .{
            label,                                       taps,                        T,           T / 48000,          cores,
            ms(ns_seq),                                  mbPerS(T, ns_seq),           cores,       ms(ns_k1),          mbPerS(T, ns_k1),
            speedup(ns_seq, ns_k1),                      exact1,                      4 * cores,   ms(ns_k4),          mbPerS(T, ns_k4),
            speedup(ns_seq, ns_k4),                      exact4,                      ms(ns_pipe), mbPerS(T, ns_pipe), 4 * cores,
            OB.chunkFootprintBytes(4 * cores, T) / 1024, OB.pipelineFootprintBytes(),
        },
    );
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    std.debug.print("=== OfflineBatch (Tier C) throughput scaling ===\n", .{});
    // A realistic offline file length (~6 min of 48k mono) is where the per-render
    // thread-spawn cost amortises and the chunker shows near-linear scaling.
    try scenario(64, 512, io, gpa, 1 << 24, "stress FIR (realistic file)");
    // A short render (~22s): per-render thread-spawn overhead is a large fraction,
    // so the speedup is overhead-bound — the honest small-T corner.
    try scenario(64, 512, io, gpa, 1 << 20, "stress FIR (short clip)");
    // A light kernel: less compute per sample ⇒ closer to the memory/plumbing bound.
    try scenario(8, 512, io, gpa, 1 << 23, "light FIR");
}
