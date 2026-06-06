//! Behavioural specification for `OfflineBatch.renderBatch` — Tier-C file-level
//! parallelism (a list of fully independent renders fanned across worker threads).
//!
//! The governing law (offline O3, bit-reproducibility): a batch render changes
//! only SCHEDULING, never the per-job arithmetic. Each job is an isolated
//! `renderSequential` over its own freshly-seeded executor instance, so the
//! output of every job under `renderBatch(cores > 1)` is **bit-identical** to
//! running that same job alone through `renderSequential`. These tests pin that
//! by computing the serial reference per job and asserting `expectEqualSlices`
//! (bit-exact, not allclose) for K distinct noise inputs, across several core
//! counts, and against an INDEPENDENT FIR convolution oracle (Rule 9: the
//! bit-exact claim can fail when the implementation changes, not merely when pan
//! disagrees with itself). Edge cases: an empty job list, `cores <= 1` (the
//! serial fast path), more cores than jobs, and one core.
//!
//! This suite spawns threads but is OFFLINE (no Tier-B render workgroup / no
//! cross-worker spin), so it does NOT need the `parallel_` filename prefix that
//! serializes the Tier-B calibration suite — file-level workers are independent
//! and join cleanly.

const std = @import("std");
const pan = @import("pan");

const Sample = pan.Sample;
const Source = pan.offline.Source;
const Sink = pan.offline.Sink;
const OfflineBatch = pan.OfflineBatch;
const testing = std.testing;

// ===========================================================================
// Test DSP blocks.
// ===========================================================================

/// A moving-average FIR over `taps` samples — a stateful Map, so a batch worker
/// must give it a FRESH instance per job (state must not bleed across jobs).
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
                for (self.hist) |h| acc += h;
                y.ch[0] = acc / @as(f32, @floatFromInt(taps));
            }
        }
    };
}

/// A stateless per-sample gain.
fn Gain(comptime g: f32) type {
    return struct {
        const Self = @This();
        pub const warmup_samples: usize = 0;
        pub const warmup_exact: bool = true;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            for (in, out) |x, *y| y.ch[0] = g * x.ch[0];
        }
    };
}

// ===========================================================================
// Comptime graph builders.
// ===========================================================================

fn firGraph(comptime taps: usize) pan.graph.Graph {
    var g = pan.graph.Graph.empty;
    g.block_size = 64;
    const s = g.add(Source);
    const f = g.add(Fir(taps));
    const k = g.add(Sink);
    g.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(Fir(taps)), f, 0);
    g.connect(pan.port.MapOutPort(Fir(taps)), f, 0, pan.port.MapInPort(Sink), k, 0);
    return g;
}

/// Source → FIR → Gain → Sink — two interior Map stages (one stateful), so a
/// batch render exercises a non-trivial per-job chain.
fn firThenGainGraph(comptime taps: usize, comptime gain: f32) pan.graph.Graph {
    var g = pan.graph.Graph.empty;
    g.block_size = 64;
    const s = g.add(Source);
    const f = g.add(Fir(taps));
    const m = g.add(Gain(gain));
    const k = g.add(Sink);
    g.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(Fir(taps)), f, 0);
    g.connect(pan.port.MapOutPort(Fir(taps)), f, 0, pan.port.MapInPort(Gain(gain)), m, 0);
    g.connect(pan.port.MapOutPort(Gain(gain)), m, 0, pan.port.MapInPort(Sink), k, 0);
    return g;
}

// ===========================================================================
// Helpers.
// ===========================================================================

/// Deterministic pseudo-noise in [-1, 1) (a linear-congruential bit-mixer), the
/// same generator the offline src/Yoneda tests use so fixtures are comparable.
fn fillNoise(buf: []f32, seed: u64) void {
    var s = seed;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = @as(f32, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(s >> 16)))))) / 2.147483648e9;
    }
}

/// An INDEPENDENT whole-timeline FIR reference (a direct moving-average
/// convolution, zero pre-roll) so a bit-exact claim can FAIL on a real
/// behaviour change, not merely on pan-vs-pan disagreement.
fn firReference(comptime taps: usize, input: []const f32, out: []f32) void {
    std.debug.assert(input.len == out.len);
    for (out, 0..) |*y, n| {
        var acc: f32 = 0;
        var k: usize = 0;
        while (k < taps) : (k += 1) {
            const idx = @as(isize, @intCast(n)) - @as(isize, @intCast(k));
            const x: f32 = if (idx >= 0) input[@intCast(idx)] else 0;
            acc += x;
        }
        y.* = acc / @as(f32, @floatFromInt(taps));
    }
}

const JobBufs = struct {
    inputs: [][]f32,
    par_out: [][]f32,
    seq_out: [][]f32,

    fn init(alloc: std.mem.Allocator, k: usize, len: usize, seed0: u64) !JobBufs {
        const inputs = try alloc.alloc([]f32, k);
        const par_out = try alloc.alloc([]f32, k);
        const seq_out = try alloc.alloc([]f32, k);
        for (inputs, par_out, seq_out, 0..) |*in, *po, *so, i| {
            in.* = try alloc.alloc(f32, len);
            po.* = try alloc.alloc(f32, len);
            so.* = try alloc.alloc(f32, len);
            // Each job gets a DISTINCT input stream (different seed), so a worker
            // that crossed job state would visibly corrupt some output.
            fillNoise(in.*, seed0 + i * 1000 + 1);
        }
        return .{ .inputs = inputs, .par_out = par_out, .seq_out = seq_out };
    }

    fn deinit(self: JobBufs, alloc: std.mem.Allocator) void {
        for (self.inputs) |b| alloc.free(b);
        for (self.par_out) |b| alloc.free(b);
        for (self.seq_out) |b| alloc.free(b);
        alloc.free(self.inputs);
        alloc.free(self.par_out);
        alloc.free(self.seq_out);
    }
};

// ===========================================================================
// The file-level batch differential — bit-identical to a serial per-job loop.
// ===========================================================================

test "renderBatch(cores>1) is bit-identical to a serial renderSequential loop, per job (file-level O3)" {
    // The central claim: K distinct independent renders fanned across worker
    // threads produce, for EVERY job, exactly the bytes that job would produce
    // alone through renderSequential. Parallelism changes scheduling only.
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    const alloc = testing.allocator;
    const K = 11; // not a multiple of typical core counts ⇒ atomic claim self-balances
    const T = 1500;
    var bufs = try JobBufs.init(alloc, K, T, 200);
    defer bufs.deinit(alloc);

    // Serial reference: each job rendered alone.
    for (bufs.inputs, bufs.seq_out) |in, so| OB.renderSequential(tmpl, in, so);

    // Parallel batch.
    const jobs = try alloc.alloc(OB.Job, K);
    defer alloc.free(jobs);
    for (jobs, bufs.inputs, bufs.par_out) |*j, in, po| j.* = .{ .input = in, .output = po };

    const cores = std.Thread.getCpuCount() catch 4;
    try OB.renderBatch(alloc, tmpl, jobs, cores);

    for (bufs.seq_out, bufs.par_out, 0..) |so, po, i| {
        testing.expectEqualSlices(f32, so, po) catch |e| {
            std.log.err("renderBatch job {d} differs from serial renderSequential", .{i});
            return e;
        };
    }
}

test "renderBatch jobs match an INDEPENDENT FIR convolution oracle (not just pan-self-agreement)" {
    // Rule 9: anchor each job to an external oracle so the bit-exact claim is
    // about correctness, not pan-vs-pan tautology.
    const taps = 6;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    const alloc = testing.allocator;
    const K = 7;
    const T = 1024;
    var bufs = try JobBufs.init(alloc, K, T, 300);
    defer bufs.deinit(alloc);

    const jobs = try alloc.alloc(OB.Job, K);
    defer alloc.free(jobs);
    for (jobs, bufs.inputs, bufs.par_out) |*j, in, po| j.* = .{ .input = in, .output = po };

    try OB.renderBatch(alloc, tmpl, jobs, 4);

    const ref = try alloc.alloc(f32, T);
    defer alloc.free(ref);
    for (bufs.inputs, bufs.par_out, 0..) |in, po, i| {
        firReference(taps, in, ref);
        testing.expectEqualSlices(f32, ref, po) catch |e| {
            std.log.err("renderBatch job {d} differs from external FIR oracle", .{i});
            return e;
        };
    }
}

test "renderBatch result is independent of core count (1, 2, ncores, more-than-jobs all agree)" {
    // File-level parallelism must be scheduling-invariant: the per-job output is
    // identical whether served by one worker or many, and whether cores exceeds
    // the job count (n_threads clamps to jobs.len).
    const taps = 5;
    const gain = 0.5;
    const g = comptime firThenGainGraph(taps, gain);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Gain(gain), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Gain(gain){}, Sink{} };

    const alloc = testing.allocator;
    const K = 9;
    const T = 900;
    var bufs = try JobBufs.init(alloc, K, T, 400);
    defer bufs.deinit(alloc);

    // Ground truth via the cores<=1 serial fast path.
    const jobs_seq = try alloc.alloc(OB.Job, K);
    defer alloc.free(jobs_seq);
    for (jobs_seq, bufs.inputs, bufs.seq_out) |*j, in, so| j.* = .{ .input = in, .output = so };
    try OB.renderBatch(alloc, tmpl, jobs_seq, 1); // serial fast path

    const ncores = std.Thread.getCpuCount() catch 4;
    const core_counts = [_]usize{ 2, ncores, K + 100 };
    for (core_counts) |cores| {
        // Reuse par_out, repointing jobs at it each pass.
        const jobs = try alloc.alloc(OB.Job, K);
        defer alloc.free(jobs);
        for (jobs, bufs.inputs, bufs.par_out) |*j, in, po| {
            @memset(po, 0);
            j.* = .{ .input = in, .output = po };
        }
        try OB.renderBatch(alloc, tmpl, jobs, cores);
        for (bufs.seq_out, bufs.par_out, 0..) |so, po, i| {
            testing.expectEqualSlices(f32, so, po) catch |e| {
                std.log.err("renderBatch job {d} differs at cores={d}", .{ i, cores });
                return e;
            };
        }
    }
}

test "renderBatch repeated runs are byte-identical run-to-run (threads add no nondeterminism, O3)" {
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    const alloc = testing.allocator;
    const K = 13;
    const T = 700;
    var bufs = try JobBufs.init(alloc, K, T, 500);
    defer bufs.deinit(alloc);

    const jobs_first = try alloc.alloc(OB.Job, K);
    defer alloc.free(jobs_first);
    for (jobs_first, bufs.inputs, bufs.seq_out) |*j, in, fo| j.* = .{ .input = in, .output = fo };
    const cores = std.Thread.getCpuCount() catch 4;
    try OB.renderBatch(alloc, tmpl, jobs_first, cores);

    var run: usize = 0;
    while (run < 8) : (run += 1) {
        const jobs = try alloc.alloc(OB.Job, K);
        defer alloc.free(jobs);
        for (jobs, bufs.inputs, bufs.par_out) |*j, in, po| {
            @memset(po, 0);
            j.* = .{ .input = in, .output = po };
        }
        try OB.renderBatch(alloc, tmpl, jobs, cores);
        for (bufs.seq_out, bufs.par_out, 0..) |fo, po, i| {
            testing.expectEqualSlices(f32, fo, po) catch |e| {
                std.log.err("renderBatch nondeterminism on run {d}, job {d}", .{ run, i });
                return e;
            };
        }
    }
}

// ===========================================================================
// Degenerate cases.
// ===========================================================================

test "renderBatch with an empty job list is a no-op (no threads, no allocation)" {
    const taps = 4;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    const empty = [_]OB.Job{};
    // cores>1 with zero jobs must early-return without touching the allocator
    // (a failing allocator would surface a spurious error otherwise).
    try OB.renderBatch(testing.failing_allocator, tmpl, &empty, 8);
}

test "renderBatch cores<=1 runs the serial fast path (no allocation) and matches renderSequential" {
    const taps = 6;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    const alloc = testing.allocator;
    const K = 4;
    const T = 256;
    var bufs = try JobBufs.init(alloc, K, T, 600);
    defer bufs.deinit(alloc);

    for (bufs.inputs, bufs.seq_out) |in, so| OB.renderSequential(tmpl, in, so);

    const jobs = try alloc.alloc(OB.Job, K);
    defer alloc.free(jobs);
    for (jobs, bufs.inputs, bufs.par_out) |*j, in, po| j.* = .{ .input = in, .output = po };

    // cores=1 ⇒ serial fast path: must not allocate, so the failing allocator is
    // safe to pass and the outputs must still match the serial reference.
    inline for (.{ @as(usize, 0), @as(usize, 1) }) |cores| {
        for (bufs.par_out) |po| @memset(po, 0);
        try OB.renderBatch(testing.failing_allocator, tmpl, jobs, cores);
        for (bufs.seq_out, bufs.par_out, 0..) |so, po, i| {
            testing.expectEqualSlices(f32, so, po) catch |e| {
                std.log.err("serial fast path (cores={d}) mismatch at job {d}", .{ cores, i });
                return e;
            };
        }
    }
}

test "renderBatch with a single job equals renderSequential of that job" {
    const taps = 7;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    const T = 333;
    var input: [T]f32 = undefined;
    fillNoise(&input, 700);
    var seq: [T]f32 = undefined;
    var par: [T]f32 = undefined;
    OB.renderSequential(tmpl, &input, &seq);

    const jobs = [_]OB.Job{.{ .input = &input, .output = &par }};
    // cores>1 but a single job ⇒ n_threads clamps to 1 worker.
    try OB.renderBatch(testing.allocator, tmpl, &jobs, 8);
    try testing.expectEqualSlices(f32, &seq, &par);
}
