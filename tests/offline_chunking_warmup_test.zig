//! Behavioural specification for the single-file timeline-chunking lever
//! (`OfflineBatch.renderChunked`) driven by per-block `warmup_samples`
//! declarations — Workstream E.
//!
//! What this proves:
//!   * A CHUNKABLE LINEAR ALL-MAP CHAIN (every node declares `warmup_samples`)
//!     renders `renderChunked(K=ncores)` equal to `renderSequential`:
//!       - **bit-exact** when every block declares `warmup_exact = true`
//!         (finite-memory state fully reconstructed by the lead-in);
//!       - **allclose within the declared tolerance** when an IIR-style block
//!         declares `warmup_exact = false` (the boundary state only decays over
//!         the lead-in, it is not reconstructed).
//!   * The presence of `warmup_samples` is what GATES chunkability: a chain
//!     containing a block that declares none reports `chunkable == false`
//!     (comptime witness), so the executor routes it to the always-available
//!     sequential/pipeline path instead of partitioning the timeline. We assert
//!     the `chunkable` decl is false WITHOUT calling `renderChunked` on it (which
//!     would be a `@compileError`).
//!   * The three real stateful per-HOP feature Maps in `src/feat.zig`
//!     (`SpectralFlux`, `DominantBandHysteresis`, `BallisticEnvelope`) now carry
//!     warm-up declarations, with the expected exact/tolerance classification.
//!
//! HONEST LIMITATION (surfaced, not papered over): timeline chunking is unlocked
//! ONLY for linear, all-Map (sample- or hop-domain) chains where EVERY node
//! declares `warmup_samples`. A realistic analysis graph contains Rate blocks
//! (Stft / Framer — frame-rate re-blockers, NOT in the per-sample/per-hop
//! Map-warmup model) and fan-out DAGs (a linear-chain test fails for those), so
//! the full fan-out analysis DAG stays sequential-or-file-level until a
//! frame-domain chunking pass exists. These tests therefore exercise the lever on
//! a deliberately-constructed chunkable linear chain; the feature blocks' value
//! is that they now CAN participate in such a chain when wired as a hop-domain
//! linear stage.

const std = @import("std");
const pan = @import("pan");

const Sample = pan.Sample;
const Source = pan.offline.Source;
const Sink = pan.offline.Sink;
const OfflineBatch = pan.OfflineBatch;
const testing = std.testing;

// ===========================================================================
// Test-local chunkable Maps over Sample(f32).
//
// The real feat blocks consume FeatureFrame(bins)/TimeFrame, while offline
// Source/Sink emit Sample(f32); to form a clean source-rooted chunkable LINEAR
// chain we use these Sample(f32) stateful Maps that declare warm-up exactly as
// the feat blocks now do. They model the two warm-up regimes the feat decls span:
// finite-memory exact (FIR) and IIR tolerance-bounded.
// ===========================================================================

/// A moving-average FIR — finite memory ⇒ EXACT warm-up: feeding `taps − 1`
/// prior frames bit-exactly reconstructs the state, mirroring `SpectralFlux`'s
/// exact one-frame lead-in (a finite, fully-reconstructible carry).
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

/// A leaky-integrator one-pole IIR `s ← λ·s + (1−λ)·x` — infinite memory ⇒
/// TOLERANCE-bounded warm-up, exactly the regime `DominantBandHysteresis`
/// (λ = 0.7) and `BallisticEnvelope` (release pole) live in: a boundary error
/// decays by λ each frame but is never exactly reconstructed, so chunking is
/// allclose, never bit-exact. `warmup_samples` is the decay-to-tolerance length:
/// for λ = 0.7, 0.7^13 ≈ 9.7e-3 — the same 13-frame constant as
/// DominantBandHysteresis.
const LeakyIir = struct {
    s: f32 = 0,
    const lambda: f32 = 0.7;
    const Self = @This();
    pub const warmup_samples: usize = 13;
    pub const warmup_exact: bool = false;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| {
            self.s = lambda * self.s + (1 - lambda) * x.ch[0];
            y.ch[0] = self.s;
        }
    }
};

/// A stateful Map that declares NO `warmup_samples` — its presence in a graph
/// makes that graph `chunkable == false`. Models a Rate/un-modelled block that
/// is not in the Map-warmup contract.
const NoWarmup = struct {
    z1: f32 = 0,
    const Self = @This();
    // Deliberately NO warmup_samples decl.
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| {
            y.ch[0] = self.z1;
            self.z1 = x.ch[0];
        }
    }
};

// ===========================================================================
// Comptime graph builders — linear Source → Map → Sink chains.
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

/// Source → FIR → LeakyIir → Sink — a linear chain mixing an exact-warmup and a
/// tolerance-warmup block, so the chain is chunkable but NOT bit-exact (one
/// block is `warmup_exact = false`).
fn firThenIirGraph(comptime taps: usize) pan.graph.Graph {
    var g = pan.graph.Graph.empty;
    g.block_size = 64;
    const s = g.add(Source);
    const f = g.add(Fir(taps));
    const m = g.add(LeakyIir);
    const k = g.add(Sink);
    g.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(Fir(taps)), f, 0);
    g.connect(pan.port.MapOutPort(Fir(taps)), f, 0, pan.port.MapInPort(LeakyIir), m, 0);
    g.connect(pan.port.MapOutPort(LeakyIir), m, 0, pan.port.MapInPort(Sink), k, 0);
    return g;
}

fn noWarmupGraph() pan.graph.Graph {
    var g = pan.graph.Graph.empty;
    g.block_size = 64;
    const s = g.add(Source);
    const f = g.add(NoWarmup);
    const k = g.add(Sink);
    g.connect(pan.port.MapOutPort(Source), s, 0, pan.port.MapInPort(NoWarmup), f, 0);
    g.connect(pan.port.MapOutPort(NoWarmup), f, 0, pan.port.MapInPort(Sink), k, 0);
    return g;
}

// ===========================================================================
// Helpers.
// ===========================================================================

fn fillNoise(buf: []f32, seed: u64) void {
    var s = seed;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = @as(f32, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(s >> 16)))))) / 2.147483648e9;
    }
}

// ===========================================================================
// Exact-warmup chunking — bit-identical to sequential.
// ===========================================================================

test "chunkable linear all-Map chain (exact warm-up) renders renderChunked == renderSequential bit-for-bit" {
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    // The lever is unlocked: every node declares warmup_samples, and every
    // declaration is exact ⇒ the chunked merge is bit-exact.
    try testing.expect(OB.chunkable);
    try testing.expect(OB.warmup_exact);
    try testing.expectEqual(@as(usize, taps - 1), OB.total_warmup);

    const T = 4096;
    var input: [T]f32 = undefined;
    fillNoise(&input, 71);
    var seq: [T]f32 = undefined;
    var chunked: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    const k = std.Thread.getCpuCount() catch 4;
    try OB.renderChunked(testing.allocator, tmpl, &input, &chunked, k);
    try testing.expectEqualSlices(f32, &seq, &chunked); // bit-exact, not allclose
}

// ===========================================================================
// Tolerance-warmup chunking — allclose within the declared tolerance.
// ===========================================================================

test "chunkable linear chain with an IIR block (tolerance warm-up) renders renderChunked allclose to sequential" {
    const taps = 4;
    const g = comptime firThenIirGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), LeakyIir, Sink });
    // Chunkable (every node declares warmup), but NOT exact: the LeakyIir block
    // declares warmup_exact=false, so the whole chain's merge is allclose.
    try testing.expect(OB.chunkable);
    try testing.expect(!OB.warmup_exact);
    // total_warmup is the SUM of the per-block lead-ins: (taps-1) + 13.
    try testing.expectEqual(@as(usize, (taps - 1) + 13), OB.total_warmup);

    const T = 4000;
    var input: [T]f32 = undefined;
    fillNoise(&input, 73);
    var seq: [T]f32 = undefined;
    var chunked: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, LeakyIir{}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    const k = std.Thread.getCpuCount() catch 4;
    try OB.renderChunked(testing.allocator, tmpl, &input, &chunked, k);

    // Allclose within tolerance. The λ=0.7 integrator's 13-frame lead-in drives
    // any boundary mismatch to 0.7^13 ≈ 9.7e-3 of the input scale (inputs are in
    // [-1, 1)), comfortably under 1e-2.
    var max_abs_err: f32 = 0;
    for (seq, chunked) |a, b| max_abs_err = @max(max_abs_err, @abs(a - b));
    try testing.expect(max_abs_err <= 1e-2);
    // And it is genuinely a chunked render: K=1 (single chunk, no interior seam)
    // must be BIT-exact even for the tolerance block, proving the tolerance only
    // buys the inter-chunk boundaries.
    var k1: [T]f32 = undefined;
    try OB.renderChunked(testing.allocator, tmpl, &input, &k1, 1);
    try testing.expectEqualSlices(f32, &seq, &k1);
}

// ===========================================================================
// W1 — presence of `warmup_samples` GATES chunkability (comptime witness).
// ===========================================================================

test "a chain containing a non-warmup block is NOT chunkable (presence gates the lever; routes to sequential)" {
    // Comptime witness of the gate: a Source→NoWarmup→Sink chain has a node that
    // declares no warmup_samples ⇒ chunkable==false. We assert the decl WITHOUT
    // calling renderChunked (which would be a @compileError) — render() would
    // route it to the pipeline/sequential path instead.
    const g = comptime noWarmupGraph();
    const OB = OfflineBatch(g, &.{ Source, NoWarmup, Sink });
    try testing.expect(!OB.chunkable);
    try testing.expectEqual(@as(usize, 0), OB.total_warmup); // collapses for non-chunkable

    // The all-warmup sibling IS chunkable — the only difference is the decl.
    const fg = comptime firGraph(8);
    const FOB = OfflineBatch(fg, &.{ Source, Fir(8), Sink });
    try testing.expect(FOB.chunkable);
}

// ===========================================================================
// The three real feat blocks now declare warm-up with the right classification.
// ===========================================================================

test "feat.SpectralFlux declares an exact one-frame warm-up (finite prev-spectrum carry)" {
    const Num = pan.numeric.numericFor(.f32, .{});
    const Block = pan.feat.SpectralFlux(Num, 16);
    try testing.expectEqual(@as(usize, 1), Block.warmup_samples);
    try testing.expect(Block.warmup_exact);
}

test "feat.DominantBandHysteresis declares a ~13-frame tolerance warm-up (λ=0.7 decay; latched held)" {
    const Num = pan.numeric.numericFor(.f32, .{});
    const Block = pan.feat.DominantBandHysteresis(Num, 16);
    try testing.expectEqual(@as(usize, 13), Block.warmup_samples);
    try testing.expect(!Block.warmup_exact);
}

test "feat.BallisticEnvelope declares a release-tail-dominated tolerance warm-up" {
    const Num = pan.numeric.numericFor(.f32, .{});
    const Block = pan.feat.BallisticEnvelope(Num, 32);
    try testing.expectEqual(@as(usize, 128), Block.warmup_samples);
    try testing.expect(!Block.warmup_exact);
}
