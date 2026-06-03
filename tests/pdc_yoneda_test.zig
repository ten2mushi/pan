//! pdc_yoneda_test — "tests as definition" for the Phase-8 additions to the commit
//! pass (`src/commit.zig`): per-rate-domain plugin-delay-compensation (`insertPdc`),
//! want-keyed buffer sizing, the multi-input mixed-rate pull rule, and the
//! bypass-preserves-latency split between `commitGraph` (raw) and `commitRuntime`
//! (PDC-compensated). It rests on the graph IR (`src/graph.zig`) and the Rate/Map
//! port machinery (`src/port.zig`).
//!
//! THE YONEDA FRAMING: the commit pass is fully observed through the morphisms its
//! consumers depend on — the `Plan` it produces (`op_count`, `footprint_bytes`,
//! `pool_buffer_count`, `pool_bytes`, `buffer_byte_len[id]`, per-op `n_or_pull_spec`)
//! and the `CommitError`s it raises at each boundary, PLUS the topology `insertPdc`
//! rewrites (node_count, the `is_pdc`/`is_delay`/`delay_len`/`pdc_compensated` flags
//! on the inserted comp-delays). Pin every one and any implementation passing these
//! is functionally equivalent on what the Phase-8 commit pass is *for*.
//!
//! COMPARISON: the commit pass is pan-vs-itself ⇒ EXACT integers (`expectEqual`) on
//! `Plan` fields and node counts; `expectError` for the `CommitError`s. NO oracle,
//! NO tolerance (a `Plan` carries no floats). Reject diagnostics use `std.debug.print`.
//!
//! Where it does NOT overlap `tests/pdc_test.zig`: that file owns the real-Stft
//! diamond's RENDER alignment and the impulse-through-Executor path; here we own the
//! COMMIT-PASS observations — want-keyed pool layout (exact bytes per class), the
//! per-rate-domain unit-conversion arithmetic isolated with stub Rate blocks AND
//! confirmed on the real Stft/iStft diamond, the latency-DP edge cases (equal
//! latency, deeper chains, the SHORTER branch carrying the delay), and the
//! bypass-latency commitGraph-vs-commitRuntime split. The whole pass runs at
//! COMPTIME (graphs built in `comptime` blocks, committed with `comptime try`,
//! `insertPdc` run in `comptime`).
//!
//! Verified against zig 0.16.0 (zig-0-16 skill loaded per Rules 13/14).

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const commit = pan.commit;
const port = pan.port;
const Sample = pan.Sample;

const f32num = pan.numericFor(.f32, .{});

// ---------------------------------------------------------------------------
// Shared synthetic block idioms. Every graph is SOURCE-ROOTED (a zero-input
// generator path head) or commit returns UnrootedPath.
// ---------------------------------------------------------------------------

/// A Source over Sample(f32): zero sample inputs ⇒ legal path head.
const Src = struct {
    const Self = @This();
    pub fn process(self: *Self, out: []Sample(f32)) void {
        _ = self;
        _ = out;
    }
};

/// A rate-1:1 map over Sample(f32) (1 in, 1 out).
const Map1 = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// A sink over Sample(f32): input only, no output port.
const Sink = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        _ = self;
        _ = in;
    }
};

/// A two-input audio-domain sum (the dry/wet/crossover fan-in).
const Sum2 = struct {
    const Self = @This();
    pub fn process(self: *Self, in0: []const Sample(f32), in1: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (in0, in1, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
    }
};

/// A latency-only Map: rate-1:1, but declares `algorithmic_latency = L`. A pure
/// passthrough whose declared group delay is what the PDC longest-path DP reads.
fn Latent(comptime L: usize) type {
    return struct {
        const Self = @This();
        pub const algorithmic_latency: usize = L;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
}

const esz = @sizeOf(Sample(f32));

// Helper: how many PDC comp-delays does a graph carry, and the (last) one's length.
fn pdcStats(comptime g: graph.Graph) struct { count: usize, last_len: usize } {
    var count: usize = 0;
    var last_len: usize = 0;
    for (g.nodes[0..g.node_count]) |n| if (n.is_pdc) {
        count += 1;
        last_len = n.delay_len;
        // A PDC node is BOTH a delay element and tagged is_pdc (so the footprint's
        // delay-ring term counts it and the runtime binds a delay kernel).
        std.debug.assert(n.is_delay);
    };
    return .{ .count = count, .last_len = last_len };
}

// ===========================================================================
// 1. PER-RATE-DOMAIN PDC — the longest-path latency DP and DelayLine insertion
// ===========================================================================

test "PDC: a latency-mismatched audio fan-in delays the SHORTER branch by the deficit" {
    // src → a(latent L) → mix.in0 ; src → b(latent 0) → mix.in1. The DP gives
    // branch-a latency L (audio samples), branch-b 0. The SHORTER branch (b) gets a
    // comp-delay of exactly L; branch a (the longest) gets none.
    const L = 73; // a deliberately non-round latency
    const A = Latent(L);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 256;
        const src = gg.add(Src);
        const a = gg.add(A); // latent branch
        const b = gg.add(Map1); // zero-latency branch (the SHORTER one)
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(A), a, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(A), a, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const g2 = comptime pan.insertPdc(g);
    const s = comptime pdcStats(g2);
    try std.testing.expectEqual(@as(usize, 1), s.count); // exactly one comp-delay
    try std.testing.expectEqual(@as(usize, L), s.last_len); // = the deficit Lmax-Lmin
    try std.testing.expectEqual(@as(usize, g.node_count + 1), g2.node_count);
    // The compensated graph commits cleanly and the comp-delay ring is footprinted:
    // pools + the inserted DelayLine ring (L · element_size) + the PDC node's ring-
    // cursor state (one usize). Pools are 3 Sample colors (the diamond needs 3
    // simultaneously-live audio values) over N=256.
    const plan = comptime try commit.commitGraph(g2, .colored);
    try std.testing.expectEqual(
        @as(usize, 3 * 256 * esz + L * esz + @sizeOf(usize)),
        plan.footprint_bytes,
    );
}

test "PDC: a latency-EQUAL fan-in inserts nothing (no deficit to compensate)" {
    // Both branches carry the SAME latency L. Lmax == each Lᵢ ⇒ no shorter input ⇒
    // no comp-delay; node_count is unchanged.
    const L = 40;
    const A = Latent(L);
    const B = Latent(L);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const a = gg.add(A);
        const b = gg.add(B);
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(A), a, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(B), b, 0);
        gg.connect(port.MapOutPort(A), a, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(B), b, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const g2 = comptime pan.insertPdc(g);
    try std.testing.expectEqual(g.node_count, g2.node_count); // unchanged
    try std.testing.expectEqual(@as(usize, 0), comptime pdcStats(g2).count);
}

test "PDC: latency ACCUMULATES along a branch — the DP is longest-path, not per-node" {
    // src → a(L1) → b(L2) → mix.in0 ; src → c(0) → mix.in1. The deep branch's
    // latency is L1+L2 (the path sum), so the shorter branch's comp-delay is L1+L2,
    // proving the DP propagates accumulated latency, not just an immediate edge.
    const L1 = 30;
    const L2 = 50;
    const A = Latent(L1);
    const B = Latent(L2);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const a = gg.add(A);
        const b = gg.add(B);
        const c = gg.add(Map1); // shorter branch
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(A), a, 0);
        gg.connect(port.MapOutPort(A), a, 0, port.MapInPort(B), b, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), c, 0);
        gg.connect(port.MapOutPort(B), b, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(Map1), c, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const g2 = comptime pan.insertPdc(g);
    const s = comptime pdcStats(g2);
    try std.testing.expectEqual(@as(usize, 1), s.count);
    try std.testing.expectEqual(@as(usize, L1 + L2), s.last_len);
}

test "PDC: a plain source→map→sink chain (no fan-in) is returned unchanged" {
    // No latency-mismatched fan-in exists, so insertPdc is the identity on topology.
    const A = Latent(99); // even a latent block in a chain needs no compensation
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const a = gg.add(A);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(A), a, 0);
        gg.connect(port.MapOutPort(A), a, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const g2 = comptime pan.insertPdc(g);
    try std.testing.expectEqual(g.node_count, g2.node_count);
    try std.testing.expectEqual(@as(usize, 0), comptime pdcStats(g2).count);
}

test "PDC per-rate-domain: a REAL Stft→iStft diamond compensates FRAME-HOP audio samples" {
    // The hallmark per-rate-domain case (audit S7): the wet branch's latency lives
    // on the HOP grid (Stft.algorithmic_latency = FRAME/HOP - 1, in output frames),
    // and the DP converts it to the audio-sample domain via the rate ratio BEFORE
    // the fan-in max. apa(Stft) = HOP audio-samples/frame, so the wet latency in
    // audio samples is (FRAME/HOP - 1)·HOP = FRAME - HOP; the iStft brings the
    // domain back to audio, so the dry branch's comp-delay is FRAME-HOP audio samples.
    const FRAME = 64;
    const HOP = 16; // FRAME/HOP = 4 ⇒ latency 3 frames; check the conversion isn't trivial
    const StftB = pan.Stft(f32num, FRAME, HOP);
    const IstftB = pan.iStft(f32num, FRAME, HOP);
    const Spec = pan.Spectrum(f32, FRAME / 2 + 1);
    const SpecGain = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const Spec, out: []Spec) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 256;
        const src = gg.add(Src);
        const dry = gg.add(Map1); // dry branch, audio domain, latency 0 (the SHORTER)
        const stft = gg.add(StftB); // wet: analysis (1:HOP, latency FRAME/HOP-1 frames)
        const spec = gg.add(SpecGain);
        const istft = gg.add(IstftB); // synthesis (HOP:1, latency 0)
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), dry, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.RateInPort(StftB), stft, 0);
        gg.connect(port.RateOutPort(StftB), stft, 0, port.MapInPort(SpecGain), spec, 0);
        gg.connect(port.MapOutPort(SpecGain), spec, 0, port.RateInPort(IstftB), istft, 0);
        gg.connect(port.RateOutPort(IstftB), istft, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Map1), dry, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const g2 = comptime pan.insertPdc(g);
    const s = comptime pdcStats(g2);
    try std.testing.expectEqual(@as(usize, 1), s.count);
    // The per-rate-domain conversion: 3 frames · HOP = FRAME - HOP audio samples.
    try std.testing.expectEqual(@as(usize, FRAME - HOP), s.last_len);
    try std.testing.expectEqual(@as(usize, g.node_count + 1), g2.node_count);
    // And the compensated diamond commits cleanly.
    const plan = comptime try commit.commitGraph(g2, .colored);
    try std.testing.expect(plan.footprint_bytes > 0);
}

test "PDC: insertPdc is comptime-evaluable — its rewritten node_count is an array length" {
    const A = Latent(48);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const a = gg.add(A);
        const b = gg.add(Map1);
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(A), a, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(A), a, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const g2 = comptime pan.insertPdc(g);
    // Legal only because g2.node_count folded at comptime.
    const proof: [g2.node_count]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), proof.len); // 5 + 1 comp-delay
}

// ===========================================================================
// 2. WANT-KEYED BUFFER SIZING — a value's pool buffer is sized by its producer's
//    per-callback output count `want`, not uniformly by the device N.
// ===========================================================================

test "want-keyed sizing: a rate-1:1 graph sizes every buffer by N (backward compatible)" {
    // For a rate-1:1 chain every want == N, so the pool layout is byte-identical to
    // the pre-P8 uniform-N pools: one Sample class, M=2 ping-pong colors, each N·esz.
    const N = 128;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Src);
        const a = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), a, 0);
        gg.connect(port.MapOutPort(Map1), a, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);
    try std.testing.expectEqual(@as(usize, 2), plan.pool_buffer_count);
    try std.testing.expectEqual(@as(usize, 2 * N * esz), plan.pool_bytes);
    try std.testing.expectEqual(@as(usize, 0), plan.persistent_bytes);
    // Every pool buffer is exactly N·esz wide.
    try std.testing.expectEqual(@as(usize, N * esz), plan.buffer_byte_len[0]);
    try std.testing.expectEqual(@as(usize, N * esz), plan.buffer_byte_len[1]);
    // Every op pulls the device demand N.
    try std.testing.expectEqual(@as(usize, N), plan.ops[0].n_or_pull_spec);
    try std.testing.expectEqual(@as(usize, N), plan.ops[1].n_or_pull_spec);
    try std.testing.expectEqual(@as(usize, N), plan.ops[2].n_or_pull_spec);
}

test "want-keyed sizing: a rate-changing seam sizes the spectral edge by frames/callback" {
    // src → Framer(1:HOP) → sink. To deliver N frames the Framer needs N·HOP input
    // samples — so the SOURCE's Sample buffer is want=N·HOP wide, while the Framer's
    // TimeFrame buffer is want=N. Two DISTINCT classes (Sample vs TimeFrame), each
    // sized by its own producer's `want`, NOT uniformly by N.
    const FRAME = 8;
    const HOP = 3; // HOP does NOT divide N — the source absorbs the ceil remainder
    const N = 16;
    const FramerB = pan.Framer(f32num, FRAME, HOP);
    const TF = pan.TimeFrame(f32, FRAME);
    const TFSink = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const TF) void {
            _ = self;
            _ = in;
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Src);
        const fr = gg.add(FramerB);
        const out = gg.add(TFSink);
        gg.connect(port.MapOutPort(Src), src, 0, port.RateInPort(FramerB), fr, 0);
        gg.connect(port.RateOutPort(FramerB), fr, 0, port.MapInPort(TFSink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);
    // Two pool buffers: the Sample edge (src→framer) and the TimeFrame edge
    // (framer→sink) are different element classes, never coalesced/aliased.
    try std.testing.expectEqual(@as(usize, 2), plan.pool_buffer_count);
    // The source op must produce ceil(N·HOP/1) = N·HOP samples to feed the framer.
    try std.testing.expectEqual(@as(usize, N * HOP), plan.ops[0].n_or_pull_spec);
    // The framer produces the device demand N frames.
    try std.testing.expectEqual(@as(usize, N), plan.ops[1].n_or_pull_spec);
    // Pool bytes = the Sample buffer (N·HOP · esz) + the TimeFrame buffer (N · sizeof TF):
    // each value sized by its OWN producer's want, NOT uniformly by N.
    const want_pool = N * HOP * esz + N * @sizeOf(TF);
    try std.testing.expectEqual(want_pool, plan.pool_bytes);
    try std.testing.expectEqual(@as(usize, 0), plan.persistent_bytes); // no feedback
    // The two pool buffers carry their distinct byte windows (Sample N·HOP, then TimeFrame N).
    try std.testing.expectEqual(@as(usize, N * HOP * esz), plan.buffer_byte_len[0]);
    try std.testing.expectEqual(@as(usize, N * @sizeOf(TF)), plan.buffer_byte_len[1]);
}

test "want-keyed sizing: same element type, DIFFERENT want ⇒ DISTINCT colored classes" {
    // src → Decim(1:2) → sink, AND a parallel direct src → sink2 — both edges carry
    // Sample(f32), but their producers' `want` differ (the decimator's INPUT side
    // wants 2N; the post-decimator and direct edges want N). The pool class key is
    // (elem_name, want), so a Sample value of want=2N is a DIFFERENT class than a
    // Sample value of want=N, and the two are never colored into the same buffer.
    const N = 32;
    const Decim = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 2 }; // half-rate
        pub const algorithmic_latency: usize = 0;
        pub fn pull(self: *Self, in: []const Sample(f32), want: usize, out: []Sample(f32)) usize {
            _ = self;
            _ = in;
            _ = out;
            return want;
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Src);
        const dec = gg.add(Decim);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.RateInPort(Decim), dec, 0);
        gg.connect(port.RateOutPort(Decim), dec, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);
    // The src→dec Sample value has want = ceil(N·2/1) = 2N; the dec→sink Sample
    // value has want = N. Same type name, different want ⇒ two classes ⇒ two buffers,
    // neither reused for the other.
    try std.testing.expectEqual(@as(usize, 2), plan.pool_buffer_count);
    // n_or_pull_spec is an element COUNT: src feeds 2N samples, dec produces N.
    try std.testing.expectEqual(@as(usize, 2 * N), plan.ops[0].n_or_pull_spec);
    try std.testing.expectEqual(@as(usize, N), plan.ops[1].n_or_pull_spec);
    // Pool = the want=2N Sample buffer + the want=N Sample buffer.
    try std.testing.expectEqual(@as(usize, 2 * N * esz + N * esz), plan.pool_bytes);
    // The two buffers carry their distinct byte windows.
    try std.testing.expectEqual(@as(usize, 2 * N * esz), plan.buffer_byte_len[0]);
    try std.testing.expectEqual(@as(usize, N * esz), plan.buffer_byte_len[1]);
}

// ===========================================================================
// 3. MULTI-INPUT PULL RULE — error.MixedRateInputs vs accepted same-rate fan-in
// ===========================================================================

test "multi-input rule: a SAME-rate audio diamond fan-in is accepted" {
    // Both branches stay in the source's rate domain (apa = 1/1 on each), so the
    // fan-in is ordinary and commits — no MixedRateInputs.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), a, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(Map1), a, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);
    try std.testing.expectEqual(@as(usize, 5), plan.op_count);
}

test "multi-input rule: a mixed-rate sample fan-in is rejected (error.MixedRateInputs)" {
    // One branch passes through a 1:2 decimating Rate (apa = 2/1 relative to source);
    // the other stays direct (apa = 1/1). The Sum2 node then has two SAMPLE inputs on
    // DIFFERENT rate domains with no adapter ⇒ rejected, never implicitly reconciled.
    const Decim = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 2 };
        pub const algorithmic_latency: usize = 0;
        pub fn pull(self: *Self, in: []const Sample(f32), want: usize, out: []Sample(f32)) usize {
            _ = self;
            _ = in;
            _ = out;
            return want;
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const dec = gg.add(Decim);
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.RateInPort(Decim), dec, 0);
        gg.connect(port.RateOutPort(Decim), dec, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    try std.testing.expectError(error.MixedRateInputs, comptime commit.commitComptime(g));
}

test "multi-input rule: a parameter port is EXEMPT — it auto-coerces across rates" {
    // A param edge from a different-rate-domain producer does NOT trip the mixed-rate
    // sample rule (the rule excludes is_param edges — a parameter ramp/hold-coerces).
    // A different-rate-domain Scalar stream drives a param slot of a downstream
    // filter while a same-rate sample feeds its sample input: the only SAMPLE input
    // is single-domain, so commit accepts.
    // A scalar source so the decimated stream can be wired to a Scalar param slot.
    const ScalarSrc = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []pan.Scalar(f32)) void {
            _ = self;
            _ = out;
        }
    };
    const ScalarDecim = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 2 };
        pub const algorithmic_latency: usize = 0;
        pub fn pull(self: *Self, in: []const pan.Scalar(f32), want: usize, out: []pan.Scalar(f32)) usize {
            _ = self;
            _ = in;
            _ = out;
            return want;
        }
    };
    const Filt = struct {
        const Self = @This();
        pub const params = .{ .cutoff = pan.Scalar(f32) };
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const psrc = gg.add(ScalarSrc);
        const pdec = gg.add(ScalarDecim); // a different-rate-domain PARAM driver
        const filt = gg.add(Filt);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Filt), filt, 0); // sample (apa 1/1)
        gg.connect(port.MapOutPort(ScalarSrc), psrc, 0, port.RateInPort(ScalarDecim), pdec, 0);
        gg.connect(port.RateOutPort(ScalarDecim), pdec, 0, port.ParamPort(Filt, "cutoff"), filt, 0); // param (exempt)
        gg.connect(port.MapOutPort(Filt), filt, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    // The filter's single SAMPLE input is one rate domain; the cross-rate edge is a
    // PARAMETER edge (exempt), so commit accepts (no MixedRateInputs).
    const plan = comptime try commit.commitComptime(g);
    try std.testing.expectEqual(@as(usize, 5), plan.op_count);
}

// ===========================================================================
// 4. BYPASS-PRESERVES-LATENCY — commitGraph rejects raw; commitRuntime compensates
// ===========================================================================

test "bypass: a bypassed latent block is rejected by commitGraph (raw, uncompensated)" {
    // A bypassed block with algorithmic_latency > 0 has no compensating delay on the
    // RAW graph, so bypassing it would shift timing and break alignment ⇒ rejected.
    const A = Latent(12);
    var g = graph.Graph.empty;
    const src = g.add(Src);
    const a = g.add(A);
    const out = g.add(Sink);
    g.connect(port.MapOutPort(Src), src, 0, port.MapInPort(A), a, 0);
    g.connect(port.MapOutPort(A), a, 0, port.MapInPort(Sink), out, 0);
    g.markBypassed(a);
    try std.testing.expectError(error.BypassLatencyUncompensated, commit.commitGraph(g, .colored));
}

test "bypass: commitRuntime runs insertPdc → compensates the bypass and commits" {
    // The SAME bypassed-latent graph: commitRuntime runs insertPdc, which routes a
    // comp-delay on the bypassed block's output and marks it pdc_compensated, clearing
    // the reject. The plan then commits with a positive footprint.
    const A = Latent(12);
    var g = graph.Graph.empty;
    const src = g.add(Src);
    const a = g.add(A);
    const out = g.add(Sink);
    g.connect(port.MapOutPort(Src), src, 0, port.MapInPort(A), a, 0);
    g.connect(port.MapOutPort(A), a, 0, port.MapInPort(Sink), out, 0);
    g.markBypassed(a);
    const plan = try commit.commitRuntime(g, .colored);
    try std.testing.expect(plan.footprint_bytes > 0);
    // insertPdc inserted exactly one comp-delay (on the bypassed block's output) of
    // the block's latency, and marked the node compensated.
    const g2 = pan.insertPdc(g);
    try std.testing.expectEqual(@as(usize, g.node_count + 1), g2.node_count);
    var found_pdc = false;
    var pdc_len: usize = 0;
    for (g2.nodes[0..g2.node_count]) |n| if (n.is_pdc) {
        found_pdc = true;
        pdc_len = n.delay_len;
    };
    try std.testing.expect(found_pdc);
    try std.testing.expectEqual(@as(usize, 12), pdc_len); // = the bypassed block's latency
    try std.testing.expect(g2.nodes[a].pdc_compensated);
}

test "bypass: a bypassed ZERO-latency block needs no compensation either way" {
    // Nothing to compensate ⇒ commitGraph accepts the raw graph directly.
    var g = graph.Graph.empty;
    const src = g.add(Src);
    const a = g.add(Map1); // zero latency
    const out = g.add(Sink);
    g.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), a, 0);
    g.connect(port.MapOutPort(Map1), a, 0, port.MapInPort(Sink), out, 0);
    g.markBypassed(a);
    const plan = try commit.commitGraph(g, .colored);
    try std.testing.expectEqual(@as(usize, 3), plan.op_count);
    // No comp-delay inserted by the PDC pass (no latency to preserve).
    const g2 = pan.insertPdc(g);
    try std.testing.expectEqual(g.node_count, g2.node_count);
}

// ===========================================================================
// 5. ERROR DISTINCTIONS — UndeclaredCycle (plain back-edge) vs DelayFreeLoop
//    (declared feedback, no delay in the cycle).
// ===========================================================================

test "cycle distinction: a plain back-edge is error.UndeclaredCycle" {
    // src → b → c → sink, plus a PLAIN (non-feedback) edge c → b closing a forward
    // cycle: it survives the Kahn topo sort ⇒ UndeclaredCycle (the author wired a
    // loop without declaring it feedback).
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const b = gg.add(Map1);
        const c = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPort(Map1), c, 0);
        gg.connect(port.MapOutPort(Map1), c, 0, port.MapInPort(Sink), out, 0);
        gg.connect(port.MapOutPort(Map1), c, 0, port.MapInPort(Map1), b, 0); // PLAIN back-edge
        break :blk gg;
    };
    try std.testing.expectError(error.UndeclaredCycle, comptime commit.commitComptime(g));
}

test "cycle distinction: a DECLARED feedback loop with no delay is error.DelayFreeLoop" {
    // The same loop, but the back-edge is a DECLARED feedback (z⁻¹) edge: topo
    // succeeds (feedback is excluded), but the SCC over forward∪feedback contains no
    // delay element ⇒ DelayFreeLoop (the output would depend on itself this block).
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const sum = gg.add(Map1);
        const gain = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), sum, 0);
        gg.connect(port.MapOutPort(Map1), sum, 0, port.MapInPort(Map1), gain, 0);
        gg.connect(port.MapOutPort(Map1), gain, 0, port.MapInPort(Sink), out, 0);
        gg.connectFeedback(port.MapOutPort(Map1), gain, 0, port.MapInPort(Map1), sum, 0);
        break :blk gg;
    };
    try std.testing.expectError(error.DelayFreeLoop, comptime commit.commitComptime(g));
}

test "cycle distinction: a DECLARED feedback loop WITH a delay element is accepted" {
    // The dual of DelayFreeLoop: inserting a delay in the cycle makes it causal, so
    // commit accepts and footprints the persistent delay ring.
    const DelayLineB = struct {
        const Self = @This();
        pub const delay_len: usize = 32;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const sum = gg.add(Map1);
        const dl = gg.add(DelayLineB);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), sum, 0);
        gg.connect(port.MapOutPort(Map1), sum, 0, port.MapInPort(DelayLineB), dl, 0);
        gg.connect(port.MapOutPort(DelayLineB), dl, 0, port.MapInPort(Sink), out, 0);
        gg.connectFeedback(port.MapOutPort(DelayLineB), dl, 0, port.MapInPort(Map1), sum, 0);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);
    try std.testing.expect(plan.footprint_bytes > 0);
    try std.testing.expect(plan.persistent_bytes > 0); // the z⁻¹ feedback buffer
}
