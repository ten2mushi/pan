//! Benchmark: Tier-C file-level parallelism (`OfflineBatch.renderBatch`).
//!
//! MEASURES (never asserts an oracle — bit-exactness lives in `tests/`): the
//! throughput of rendering a batch of K fully independent offline jobs across a
//! growing worker pool (cores ∈ {1,2,4,…,ncores}) vs a serial `renderSequential`
//! loop over the same jobs. File-level parallelism is embarrassingly parallel —
//! each job runs a complete isolated sequential render on its own freshly-seeded
//! engine, sharing nothing — so the expectation is near-linear speedup until the
//! machine's physical cores saturate. Reports wall-time, MB/s, and speedup-vs-serial
//! at each core count (min over repetitions; one-shot timings flake under load).
//!
//! A spot bit-exactness check (parallel job output == serial job output) is done
//! once for honesty, but the headline is the speedup table. Build/run:
//! `zig build bench` (ReleaseFast).

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.Sample;
const Source = pan.offline.Source;
const Sink = pan.offline.Sink;

/// A moving-average FIR — a real per-sample kernel so the parallelism has work to
/// amortise (a trivial copy would be plumbing-bound and hide the scaling).
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

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
fn speedup(a: u64, b: u64) f64 {
    return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
}
fn mbPerS(total_samples: usize, ns: u64) f64 {
    const bytes: f64 = @floatFromInt(total_samples * @sizeOf(f32));
    return bytes / (@as(f64, @floatFromInt(ns)) / 1e9) / (1024.0 * 1024.0);
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    const taps = 48;
    const N = 512;
    const K = 32; // jobs in the batch
    const T = 1 << 19; // samples per job (~11s @48k)

    const g = comptime firGraph(taps, N);
    const OB = pan.OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    // One shared input per job (different seed) + one output buffer per job.
    var inputs: [K][]f32 = undefined;
    var outs: [K][]f32 = undefined;
    var serial_ref: [K][]f32 = undefined;
    for (0..K) |j| {
        inputs[j] = try gpa.alloc(f32, T);
        outs[j] = try gpa.alloc(f32, T);
        serial_ref[j] = try gpa.alloc(f32, T);
        fillNoise(inputs[j], @as(u64, j) +% 1);
    }
    defer for (0..K) |j| {
        gpa.free(inputs[j]);
        gpa.free(outs[j]);
        gpa.free(serial_ref[j]);
    };

    var jobs: [K]OB.Job = undefined;
    for (0..K) |j| jobs[j] = .{ .input = inputs[j], .output = outs[j] };

    const cores = std.Thread.getCpuCount() catch 1;
    const reps = 3;
    const total_samples = K * T;

    std.debug.print(
        "=== Tier-C file-level parallelism (renderBatch over {d} jobs, {d} samples each ≈ {d}s @48k, FIR taps={d}) ===\n",
        .{ K, T, T / 48000, taps },
    );

    // Serial reference: a plain renderSequential loop over the jobs. This is also
    // the bit-exactness oracle (parallel must equal it job-for-job).
    var ns_serial: u64 = std.math.maxInt(u64);
    {
        var r: usize = 0;
        while (r < reps) : (r += 1) {
            var t = h.Timer.start(io);
            for (0..K) |j| OB.renderSequential(tmpl, inputs[j], serial_ref[j]);
            ns_serial = @min(ns_serial, t.read());
        }
        h.consume(serial_ref[K - 1][T - 1]);
    }
    std.debug.print(
        "  serial loop      : {d:>7.1} ms  {d:>6.0} MB/s  (1.00x baseline)\n",
        .{ ms(ns_serial), mbPerS(total_samples, ns_serial) },
    );

    // renderBatch at a growing worker pool. Cap at the machine's core count, plus
    // one oversubscribed point (4×cores) — oversubscription lets the OS balance the
    // asymmetric P/E cores when a straggler would otherwise bind equal-sized chunks.
    var c: usize = 1;
    var first_bitexact: ?bool = null;
    while (c <= cores) : (c *= 2) {
        var ns: u64 = std.math.maxInt(u64);
        var r: usize = 0;
        while (r < reps) : (r += 1) {
            var t = h.Timer.start(io);
            try OB.renderBatch(gpa, tmpl, &jobs, c);
            ns = @min(ns, t.read());
        }
        // Verify (once, at the first multi-core point) that the parallel batch is
        // byte-identical to the serial reference, job for job.
        if (first_bitexact == null and c >= 2) {
            var ok = true;
            for (0..K) |j| ok = ok and std.mem.eql(u8, std.mem.sliceAsBytes(serial_ref[j]), std.mem.sliceAsBytes(outs[j]));
            first_bitexact = ok;
        }
        std.debug.print(
            "  renderBatch c={d:<3}   : {d:>7.1} ms  {d:>6.0} MB/s  speedup {d:.2}x\n",
            .{ c, ms(ns), mbPerS(total_samples, ns), speedup(ns_serial, ns) },
        );
        h.consume(outs[K - 1][T - 1]);
    }
    // One oversubscribed point.
    {
        const c4 = 4 * cores;
        var ns: u64 = std.math.maxInt(u64);
        var r: usize = 0;
        while (r < reps) : (r += 1) {
            var t = h.Timer.start(io);
            try OB.renderBatch(gpa, tmpl, &jobs, c4);
            ns = @min(ns, t.read());
        }
        std.debug.print(
            "  renderBatch c={d:<3}   : {d:>7.1} ms  {d:>6.0} MB/s  speedup {d:.2}x  (oversubscribed)\n",
            .{ c4, ms(ns), mbPerS(total_samples, ns), speedup(ns_serial, ns) },
        );
        h.consume(outs[K - 1][T - 1]);
    }

    std.debug.print("  parallel == serial (bit-exact, job-for-job): {?}\n", .{first_bitexact});
}
