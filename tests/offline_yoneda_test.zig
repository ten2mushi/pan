//! Yoneda-style behavioural specification for `pan.offline` — the OfflineBatch
//! (Tier C / push-throughput) execution mode.
//!
//! These tests DEFINE the offline executor's contract by exercising it through
//! every morphism that matters: sequential vs chunked vs pipeline; K=1 vs
//! K=many; exact-warmup (FIR) vs tolerance-warmup (IIR); stateless vs stateful;
//! a timeline length divisible by the block size and one that is not; a timeline
//! shorter than the warm-up lead-in; the degenerate empty render; and repeated
//! runs (determinism). The governing laws are the offline invariants O1–O3
//! (§11.1b) and the `warmup_samples` chunking contract W1–W3 (§2.5), discharged
//! here as the §5.7d offline differential.
//!
//! Independence of the oracle (Rule 9): wherever a test asserts an absolute
//! numeric truth (not merely pan-vs-pan agreement) it computes a hand-rolled
//! whole-timeline reference render in-test, so the assertion can fail when the
//! implementation's behaviour changes — a tautological "compare pan to itself"
//! oracle is avoided for the value-level claims.

const std = @import("std");
const pan = @import("pan");

const Sample = pan.Sample;
const Source = pan.offline.Source;
const Sink = pan.offline.Sink;
const OfflineBatch = pan.OfflineBatch;
const testing = std.testing;

// ===========================================================================
// Test DSP blocks (our own, per the task — the reference blocks in src are read
// but not reused).
// ===========================================================================

/// A moving-average FIR over `taps` samples. Finite memory ⇒ its warm-up is
/// EXACT: feeding `taps − 1` prior input samples bit-exactly reconstructs the
/// filter's boundary state, so a chunked render is bit-identical to sequential.
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

/// A stateless per-sample gain. No cross-sample state ⇒ `warmup_samples = 0`
/// (W1: a pure Map declares zero, so it never blocks chunkability and is
/// embarrassingly parallel — every chunk reconstructs trivially).
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

/// A one-pole IIR low-pass: y[n] = (1−a)·x[n] + a·y[n−1]. Infinite memory ⇒ no
/// finite warm-up is exact; `warmup_exact = false` means the chunked merge is
/// allclose-within-tolerance, never bit-exact. `warmup_samples` is the
/// decay-to-tolerance length.
const Iir = struct {
    y1: f32 = 0,
    a: f32 = 0.9,
    const Self = @This();
    pub const warmup_samples: usize = 256;
    pub const warmup_exact: bool = false;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| {
            self.y1 = (1 - self.a) * x.ch[0] + self.a * self.y1;
            y.ch[0] = self.y1;
        }
    }
};

/// A stateful block that declares NO `warmup_samples` (a single-sample delay
/// kept around its boundary state). Used only as a comptime witness that such a
/// graph reports `chunkable == false` (W1: presence gates chunkability).
const UnchunkableDelay = struct {
    z1: f32 = 0,
    const Self = @This();
    // Deliberately NO `warmup_samples` decl.
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| {
            y.ch[0] = self.z1;
            self.z1 = x.ch[0];
        }
    }
};

// ===========================================================================
// Comptime graph builders (low-level IR — the same shape the src tests use).
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

fn iirGraph() pan.graph.Graph {
    var g = pan.graph.Graph.empty;
    g.block_size = 64;
    const s = g.add(Source);
    const f = g.add(Iir);
    const k = g.add(Sink);
    g.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(Iir), f, 0);
    g.connect(pan.port.MapOutPort(Iir), f, 0, pan.port.MapInPort(Sink), k, 0);
    return g;
}

fn gainGraph(comptime gain: f32) pan.graph.Graph {
    var g = pan.graph.Graph.empty;
    g.block_size = 64;
    const s = g.add(Source);
    const m = g.add(Gain(gain));
    const k = g.add(Sink);
    g.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(Gain(gain)), m, 0);
    g.connect(pan.port.MapOutPort(Gain(gain)), m, 0, pan.port.MapInPort(Sink), k, 0);
    return g;
}

/// A three-stage chain: Source → FIR(taps) → Gain(gain) → Sink (two interior
/// Map stages, the multi-stage pipeline/chunk shape).
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

/// Deterministic pseudo-noise in [-1, 1) (a linear-congruential bit-mixer) — the
/// same generator the src tests use so fixtures are comparable.
fn fillNoise(buf: []f32, seed: u64) void {
    var s = seed;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = @as(f32, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(s >> 16)))))) / 2.147483648e9;
    }
}

/// An INDEPENDENT whole-timeline FIR reference (the oracle for value-level
/// bit-exactness): a direct convolution of the moving average over the input,
/// computed with no reference to the executor. Pre-roll history is zero (matches
/// a fresh block at t=0). Used so the bit-exact claims can FAIL if the executor
/// produces a different stream, not merely if it disagrees with itself.
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

// ===========================================================================
// O3 / §5.7d — the offline differential for EXACT-warmup (FIR) chunking.
// ===========================================================================

test "renderSequential reproduces an independent FIR convolution oracle (ground truth, O3 baseline)" {
    // The sequential render is the offline ground truth (§11.1b). Pin it to an
    // EXTERNAL oracle so a regression in the K=1 path itself is caught — every
    // other test trusts renderSequential, so it must be anchored to truth.
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 1000;
    var input: [T]f32 = undefined;
    fillNoise(&input, 101);
    var got: [T]f32 = undefined;
    var ref: [T]f32 = undefined;
    OB.renderSequential(.{ Source{}, Fir(taps){}, Sink{} }, &input, &got);
    firReference(taps, &input, &ref);
    try testing.expectEqualSlices(f32, &ref, &got);
}

test "chunked K=ncores is bit-identical to sequential for exact-warmup FIR (O3, §5.7d)" {
    // W2: warmup_exact=true ⇒ the discarded lead-in exactly reconstructs the
    // boundary state, so the chunked merge is bit-identical to sequential. This
    // is the central O3 claim for finite-memory blocks.
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    try testing.expect(OB.chunkable);
    try testing.expect(OB.warmup_exact);
    try testing.expectEqual(@as(usize, taps - 1), OB.total_warmup);

    const T = 4096;
    var input: [T]f32 = undefined;
    fillNoise(&input, 103);
    var seq: [T]f32 = undefined;
    var par: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    const k = std.Thread.getCpuCount() catch 4;
    try OB.renderChunked(testing.allocator, tmpl, &input, &par, k);
    try testing.expectEqualSlices(f32, &seq, &par); // bit-exact, not allclose
}

test "exact-warmup chunked render matches the external FIR oracle, not just itself (O3 anchored)" {
    // Anchor the chunked path to the INDEPENDENT oracle too, so O3 is a claim
    // about correctness, not just pan-self-consistency (Rule 9).
    const taps = 6;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 2000;
    var input: [T]f32 = undefined;
    fillNoise(&input, 107);
    var par: [T]f32 = undefined;
    var ref: [T]f32 = undefined;
    try OB.renderChunked(testing.allocator, .{ Source{}, Fir(taps){}, Sink{} }, &input, &par, 7);
    firReference(taps, &input, &ref);
    try testing.expectEqualSlices(f32, &ref, &par);
}

test "the timeline partition is invisible: every chunk count K gives the identical FIR result (O3)" {
    // The defining property of the ordered merge (O3): the output is INDEPENDENT
    // of how the timeline was partitioned. Sweep many K — including K not
    // dividing T, K=1, K=T, and K>cores — all must be byte-identical to
    // sequential for an exact-warmup block.
    const taps = 5;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 333; // prime-ish, so most K do NOT divide it
    var input: [T]f32 = undefined;
    fillNoise(&input, 109);
    var seq: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);

    const ks = [_]usize{ 1, 2, 3, 5, 7, 8, 16, 64, T, T + 5 };
    for (ks) |k| {
        var par: [T]f32 = undefined;
        try OB.renderChunked(testing.allocator, tmpl, &input, &par, k);
        testing.expectEqualSlices(f32, &seq, &par) catch |e| {
            std.log.err("partition NOT invisible at K={d}", .{k});
            return e;
        };
    }
}

test "K=1 chunked equals K=ncores chunked, bit-for-bit, and equals renderSequential (O3 transitivity)" {
    // Three equalities at once: renderSequential ≡ K=1 chunked ≡ K=ncores
    // chunked. K=1 chunked has its OWN code path (one chunk, no warm-up lead-in
    // for chunk 0) so it is not trivially renderSequential — assert all three.
    const taps = 5;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 777;
    var input: [T]f32 = undefined;
    fillNoise(&input, 17);
    var seq: [T]f32 = undefined;
    var k1: [T]f32 = undefined;
    var kn: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderChunked(testing.allocator, tmpl, &input, &k1, 1);
    try OB.renderChunked(testing.allocator, tmpl, &input, &kn, 8);
    try testing.expectEqualSlices(f32, &seq, &k1);
    try testing.expectEqualSlices(f32, &k1, &kn);
}

// ===========================================================================
// O3 / §5.7d — IIR (tolerance-warmup) chunking is allclose, NOT bit-exact.
// ===========================================================================

test "IIR chunked render is allclose to sequential within the declared tolerance (W2, NOT bit-exact)" {
    // W2: warmup_exact=false ⇒ the boundary state has only DECAYED over
    // warmup_samples, not been reconstructed. The merge is allclose, and the
    // chunks past the first generally differ from sequential at the bit level
    // (the whole point of declaring warmup_exact=false).
    const g = comptime iirGraph();
    const OB = OfflineBatch(g, &.{ Source, Iir, Sink });
    try testing.expect(OB.chunkable);
    try testing.expect(!OB.warmup_exact);
    try testing.expectEqual(@as(usize, 256), OB.total_warmup);

    const T = 4000;
    var input: [T]f32 = undefined;
    fillNoise(&input, 13);
    var seq: [T]f32 = undefined;
    var par: [T]f32 = undefined;
    const tmpl = .{ Source{}, Iir{}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderChunked(testing.allocator, tmpl, &input, &par, 4);

    var max_abs_err: f32 = 0;
    for (seq, par) |a, b| max_abs_err = @max(max_abs_err, @abs(a - b));
    // Allclose within the block's declared tolerance (the 256-sample decay of an
    // a=0.9 one-pole drives the boundary mismatch well below 1e-4).
    try testing.expect(max_abs_err <= 1e-4);
}

test "IIR K=1 chunked is bit-identical to sequential (no boundary to decay across)" {
    // Even for a tolerance-warmup block, K=1 has a single chunk with NO interior
    // boundary, so its render must be EXACT — the tolerance only buys the
    // inter-chunk seams, and there are none. A subtly-buggy K=1 path that ran a
    // spurious warm-up would fail this.
    const g = comptime iirGraph();
    const OB = OfflineBatch(g, &.{ Source, Iir, Sink });
    const T = 1500;
    var input: [T]f32 = undefined;
    fillNoise(&input, 131);
    var seq: [T]f32 = undefined;
    var k1: [T]f32 = undefined;
    const tmpl = .{ Source{}, Iir{}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderChunked(testing.allocator, tmpl, &input, &k1, 1);
    try testing.expectEqualSlices(f32, &seq, &k1);
}

// ===========================================================================
// Pipeline parallelism — exact and bit-reproducible by construction.
// ===========================================================================

test "renderPipeline is bit-identical to sequential for a linear Map chain (O3 pipeline path)" {
    // Pipeline parallelism flows the same data through the same stages in the
    // same order ⇒ bit-identical to sequential by construction, regardless of
    // exact/tolerance warm-up (no timeline partition is involved).
    const taps = 4;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 640;
    var input: [T]f32 = undefined;
    fillNoise(&input, 19);
    var seq: [T]f32 = undefined;
    var pipe: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderPipeline(testing.allocator, tmpl, &input, &pipe);
    try testing.expectEqualSlices(f32, &seq, &pipe);
}

test "renderPipeline is bit-identical to sequential even when T is not a block-size multiple (clamping)" {
    // The source zero-pads past the timeline and the sink clamps at its end, so
    // a non-block-multiple length must need no special case — the final partial
    // block must be written correctly.
    const taps = 4;
    const g = comptime firGraph(taps); // block_size = 64
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 64 * 3 + 17; // 209 — last block is partial
    var input: [T]f32 = undefined;
    fillNoise(&input, 23);
    var seq: [T]f32 = undefined;
    var pipe: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderPipeline(testing.allocator, tmpl, &input, &pipe);
    try testing.expectEqualSlices(f32, &seq, &pipe);
}

test "renderPipeline on a multi-stage chain (Source→FIR→Gain→Sink) equals sequential bit-for-bit" {
    // Two interior Map stages exercise the full ring topology (S−1 rings, every
    // worker an in/out stage). Pipeline must still be exact.
    const taps = 4;
    const gain = 0.5;
    const g = comptime firThenGainGraph(taps, gain);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Gain(gain), Sink });
    const T = 700;
    var input: [T]f32 = undefined;
    fillNoise(&input, 29);
    var seq: [T]f32 = undefined;
    var pipe: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Gain(gain){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderPipeline(testing.allocator, tmpl, &input, &pipe);
    try testing.expectEqualSlices(f32, &seq, &pipe);
}

test "renderPipeline rejects a non-terminal-endpoint / non-linear shape with error.NotLinearChain" {
    // The pipeline path serves ONLY a linear Source(node 0)→…→Sink(node S−1)
    // chain. Put the Source NOT at node 0 and assert it routes elsewhere via the
    // declared error (the ⊢ adjunct of the pipeline contract). Here Sink is
    // added first (node 0), so source_id != 0.
    const taps = 4;
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = 64;
        const k = gg.add(Sink); // node 0 is the SINK — breaks the linear-chain endpoint test
        const f = gg.add(Fir(taps));
        const s = gg.add(Source); // node 2 is the SOURCE
        gg.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(Fir(taps)), f, 0);
        gg.connect(pan.port.MapOutPort(Fir(taps)), f, 0, pan.port.MapInPort(Sink), k, 0);
        break :blk gg;
    };
    const OB = OfflineBatch(g, &.{ Sink, Fir(taps), Source });
    const T = 128;
    var input: [T]f32 = undefined;
    fillNoise(&input, 31);
    var out: [T]f32 = undefined;
    const tmpl = .{ Sink{}, Fir(taps){}, Source{} };
    try testing.expectError(error.NotLinearChain, OB.renderPipeline(testing.allocator, tmpl, &input, &out));
}

// ===========================================================================
// Stateless chains — embarrassingly parallel, bit-exact under any partition.
// ===========================================================================

test "a pure stateless gain chain (warmup 0) is bit-exact under chunking and equals g·x exactly (O3)" {
    // A warmup_samples=0 Map carries no cross-sample state ⇒ total_warmup is 0
    // and every chunk is independent. The chunked output must equal a direct
    // elementwise gain (external oracle) for ANY K.
    const gain = 0.25;
    const g = comptime gainGraph(gain);
    const OB = OfflineBatch(g, &.{ Source, Gain(gain), Sink });
    try testing.expect(OB.chunkable);
    try testing.expect(OB.warmup_exact);
    try testing.expectEqual(@as(usize, 0), OB.total_warmup);

    const T = 512;
    var input: [T]f32 = undefined;
    fillNoise(&input, 37);
    var ref: [T]f32 = undefined;
    for (input, &ref) |x, *r| r.* = gain * x; // independent oracle

    const tmpl = .{ Source{}, Gain(gain){}, Sink{} };
    const ks = [_]usize{ 1, 2, 4, 7, T };
    for (ks) |k| {
        var par: [T]f32 = undefined;
        try OB.renderChunked(testing.allocator, tmpl, &input, &par, k);
        testing.expectEqualSlices(f32, &ref, &par) catch |e| {
            std.log.err("stateless chunk mismatch at K={d}", .{k});
            return e;
        };
    }
}

// ===========================================================================
// Determinism across runs — threads must not introduce nondeterminism (O3).
// ===========================================================================

test "repeated chunked renders are byte-identical run-to-run: threads add no nondeterminism (O3)" {
    // O3 demands the output be independent of SCHEDULING, not just thread count.
    // Render the same chunked job many times; every run must produce the exact
    // same bytes. A data race or completion-order dependence would surface here.
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 5000;
    var input: [T]f32 = undefined;
    fillNoise(&input, 41);
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    var first: [T]f32 = undefined;
    const k = std.Thread.getCpuCount() catch 4;
    try OB.renderChunked(testing.allocator, tmpl, &input, &first, k);

    var run: usize = 0;
    while (run < 16) : (run += 1) {
        var again: [T]f32 = undefined;
        try OB.renderChunked(testing.allocator, tmpl, &input, &again, k);
        testing.expectEqualSlices(f32, &first, &again) catch |e| {
            std.log.err("nondeterminism on run {d}", .{run});
            return e;
        };
    }
}

test "repeated pipeline renders are byte-identical run-to-run (O3 pipeline determinism)" {
    const taps = 6;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 2048;
    var input: [T]f32 = undefined;
    fillNoise(&input, 43);
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    var first: [T]f32 = undefined;
    try OB.renderPipeline(testing.allocator, tmpl, &input, &first);
    var run: usize = 0;
    while (run < 8) : (run += 1) {
        var again: [T]f32 = undefined;
        try OB.renderPipeline(testing.allocator, tmpl, &input, &again);
        try testing.expectEqualSlices(f32, &first, &again);
    }
}

// ===========================================================================
// Edge cases — boundary conditions of the partition arithmetic.
// ===========================================================================

test "empty timeline (T=0): chunked and pipeline are no-ops, sequential too (O2 degenerate)" {
    const taps = 4;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const input = [_]f32{};
    var output = [_]f32{};
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &output); // no panic
    // K clamps to [1, T]; with T=0 the early return must fire without allocating
    // a zero-length pool incorrectly.
    try OB.renderChunked(testing.allocator, tmpl, &input, &output, 4);
    try OB.renderPipeline(testing.allocator, tmpl, &input, &output);
}

test "T smaller than total_warmup: lead-in clamps at 0, output is still correct (O3 boundary)" {
    // When a chunk's begin < total_warmup, `start` clamps to 0 and `lead`
    // shrinks — the arithmetic must not underflow and the merge must still equal
    // sequential. Drive T < total_warmup with a real warm-up (FIR taps-1) and
    // many chunks so several chunks see begin < warmup.
    const taps = 16; // total_warmup = 15
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    try testing.expectEqual(@as(usize, taps - 1), OB.total_warmup);
    const T = 10; // strictly less than total_warmup (15)
    var input: [T]f32 = undefined;
    fillNoise(&input, 47);
    var seq: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    // K is clamped to T=10 internally even if we ask for more.
    const ks = [_]usize{ 1, 2, 3, 10, 100 };
    for (ks) |k| {
        var par: [T]f32 = undefined;
        try OB.renderChunked(testing.allocator, tmpl, &input, &par, k);
        testing.expectEqualSlices(f32, &seq, &par) catch |e| {
            std.log.err("small-T mismatch at K={d}", .{k});
            return e;
        };
    }
}

test "very small T (T=1) renders one sample correctly across sequential/chunked/pipeline (O3 floor)" {
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 1;
    const input = [_]f32{0.5};
    var seq: [T]f32 = undefined;
    var par: [T]f32 = undefined;
    var pipe: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderChunked(testing.allocator, tmpl, &input, &par, 4);
    try OB.renderPipeline(testing.allocator, tmpl, &input, &pipe);
    // One-sample FIR(8) of x=0.5: only hist[0]=0.5, rest zero ⇒ 0.5/8.
    const expect: f32 = 0.5 / 8.0;
    try testing.expectEqual(expect, seq[0]);
    try testing.expectEqualSlices(f32, &seq, &par);
    try testing.expectEqualSlices(f32, &seq, &pipe);
}

test "T equal to total_warmup exactly: the boundary case neither over- nor under-reads (O3)" {
    // begin == total_warmup for the boundary chunk: start = begin - warmup = 0,
    // lead = warmup. An off-by-one in the `begin > total_warmup` guard would
    // skew the lead-in here.
    const taps = 8; // total_warmup = 7
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = OB.total_warmup * 4; // multiple of warmup, lots of chunks near it
    var input: [T]f32 = undefined;
    fillNoise(&input, 53);
    var seq: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    var par: [T]f32 = undefined;
    try OB.renderChunked(testing.allocator, tmpl, &input, &par, 4);
    try testing.expectEqualSlices(f32, &seq, &par);
}

test "T a clean multiple of block_size chunks identically to a non-multiple (partition independence)" {
    // Pair a divisible length with an indivisible one; both must equal their own
    // sequential render. Guards against a hidden assumption that T % N == 0.
    const taps = 5;
    const g = comptime firGraph(taps); // N = 64
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };

    inline for (.{ 64 * 6, 64 * 6 + 1, 64 * 6 - 1 }) |T| {
        var input: [T]f32 = undefined;
        fillNoise(&input, 59 + T);
        var seq: [T]f32 = undefined;
        var par: [T]f32 = undefined;
        OB.renderSequential(tmpl, &input, &seq);
        try OB.renderChunked(testing.allocator, tmpl, &input, &par, 5);
        try testing.expectEqualSlices(f32, &seq, &par);
    }
}

// ===========================================================================
// W1 — presence of `warmup_samples` gates chunkability (comptime contract).
// ===========================================================================

test "chunkable is true iff every block declares warmup_samples (W1 presence gate)" {
    // A graph whose every node declares warmup_samples is chunkable; one with a
    // stateful block that omits it is NOT. `chunkable` is a comptime decl, so
    // this is the build-time witness of W1 (the renderChunked compile-error is
    // the runtime adjunct, not directly testable without a failed build).
    const taps = 8;
    const fg = comptime firGraph(taps);
    const ChunkableOB = OfflineBatch(fg, &.{ Source, Fir(taps), Sink });
    try testing.expect(ChunkableOB.chunkable);

    const ug = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = 64;
        const s = gg.add(Source);
        const d = gg.add(UnchunkableDelay);
        const k = gg.add(Sink);
        gg.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(UnchunkableDelay), d, 0);
        gg.connect(pan.port.MapOutPort(UnchunkableDelay), d, 0, pan.port.MapInPort(Sink), k, 0);
        break :blk gg;
    };
    const UnchunkableOB = OfflineBatch(ug, &.{ Source, UnchunkableDelay, Sink });
    // The stateful UnchunkableDelay declares no warmup_samples ⇒ NOT chunkable.
    try testing.expect(!UnchunkableOB.chunkable);
    // total_warmup collapses to 0 for a non-chunkable graph (the meta guard).
    try testing.expectEqual(@as(usize, 0), UnchunkableOB.total_warmup);
}

test "total_warmup is the SUM of per-block warm-ups (conservative bound, O3 correctness margin)" {
    // For Source(0) → FIR(taps-1) → Gain(0) → Sink(0) the timeline lead-in is the
    // sum = taps-1. The bound being a sum (≥ the longest path) is what keeps the
    // merge exact: more lead-in is always still exact, never less.
    const taps = 12;
    const gain = 0.7;
    const g = comptime firThenGainGraph(taps, gain);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Gain(gain), Sink });
    try testing.expectEqual(@as(usize, taps - 1), OB.total_warmup);
    try testing.expect(OB.warmup_exact);

    // And it still renders bit-exactly through that summed lead-in.
    const T = 1500;
    var input: [T]f32 = undefined;
    fillNoise(&input, 61);
    var seq: [T]f32 = undefined;
    var par: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Gain(gain){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderChunked(testing.allocator, tmpl, &input, &par, 8);
    try testing.expectEqualSlices(f32, &seq, &par);
}

// ===========================================================================
// Source / Sink endpoint behaviour (the timeline-in / timeline-out morphisms).
// ===========================================================================

test "Source/Sink round-trip the timeline unchanged through an identity chain (endpoint correctness)" {
    const Id = struct {
        const Self = @This();
        pub const warmup_samples: usize = 0;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            for (in, out) |x, *y| y.* = x;
        }
    };
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = 64;
        const s = gg.add(Source);
        const m = gg.add(Id);
        const k = gg.add(Sink);
        gg.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(Id), m, 0);
        gg.connect(pan.port.MapOutPort(Id), m, 0, pan.port.MapInPort(Sink), k, 0);
        break :blk gg;
    };
    const OB = OfflineBatch(g, &.{ Source, Id, Sink });
    const T = 500;
    var input: [T]f32 = undefined;
    var output: [T]f32 = undefined;
    fillNoise(&input, 7);
    OB.renderSequential(.{ Source{}, Id{}, Sink{} }, &input, &output);
    try testing.expectEqualSlices(f32, &input, &output);

    // Endpoint decls: both declare a zero warm-up (a source/sink carries no
    // cross-sample audio state).
    try testing.expectEqual(@as(usize, 0), Source.warmup_samples);
    try testing.expectEqual(@as(usize, 0), Sink.warmup_samples);
}

test "Source emits silence past its window; Sink clamps at its destination end (pad/clamp law)" {
    // Directly probe the two endpoint blocks: the Source zero-pads beyond its
    // window (the warm-up overshoot / final pad), and the Sink stops at dest.len
    // (a partial final block writes only the remainder). These two together are
    // why a non-block-multiple timeline needs no scalar-tail special case.
    var src: Source = .{};
    src.seek(&[_]f32{ 1, 2, 3 });
    var out: [5]Sample(f32) = @splat(.{ .ch = .{0} });
    src.process(&out);
    try testing.expectEqual(@as(f32, 1), out[0].ch[0]);
    try testing.expectEqual(@as(f32, 2), out[1].ch[0]);
    try testing.expectEqual(@as(f32, 3), out[2].ch[0]);
    try testing.expectEqual(@as(f32, 0), out[3].ch[0]); // past window ⇒ silence
    try testing.expectEqual(@as(f32, 0), out[4].ch[0]);

    var snk: Sink = .{};
    var dest: [2]f32 = .{ -1, -1 };
    snk.attach(&dest);
    const in = [_]Sample(f32){
        .{ .ch = .{9} }, .{ .ch = .{8} }, .{ .ch = .{7} }, // 3 in, dest holds 2
    };
    snk.process(&in);
    try testing.expectEqual(@as(f32, 9), dest[0]);
    try testing.expectEqual(@as(f32, 8), dest[1]); // third sample dropped (clamp)
}

// ===========================================================================
// Cross-mode equivalence — all three executors agree (the Yoneda closure).
// ===========================================================================

test "sequential ≡ chunked(K=ncores) ≡ pipeline for an exact-warmup chain (all three modes agree)" {
    // The complete O3 closure for finite-memory blocks: every execution mode is
    // bit-identical. If they all agree AND agree with the external oracle, the
    // executor's observable behaviour is fully pinned.
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 3000;
    var input: [T]f32 = undefined;
    fillNoise(&input, 67);
    var seq: [T]f32 = undefined;
    var chunk: [T]f32 = undefined;
    var pipe: [T]f32 = undefined;
    var ref: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    const k = std.Thread.getCpuCount() catch 4;
    try OB.renderChunked(testing.allocator, tmpl, &input, &chunk, k);
    try OB.renderPipeline(testing.allocator, tmpl, &input, &pipe);
    firReference(taps, &input, &ref);
    try testing.expectEqualSlices(f32, &ref, &seq);
    try testing.expectEqualSlices(f32, &seq, &chunk);
    try testing.expectEqualSlices(f32, &seq, &pipe);
}
