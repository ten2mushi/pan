//! fusion_yoneda_test — INDEPENDENT adversarial characterization of the automatic
//! comptime loop-fusion pass (`src/fusion.zig` + `engine.FusedExecutor`),
//! complementary to `tests/fusion_differential_test.zig` (the gate). These pin the
//! rewrite's invariants on graph SHAPES the gate does not cover, chosen autonomously:
//!
//!   - DIAMOND (fan-out then re-converge): Source → A → {B, C} → D. A's value fans
//!     out (never folded across the fork); D has TWO sample inputs (a join, not a
//!     single-input Map) so nothing folds into D. fused ≡ unfused bit-exact, under
//!     BOTH `.colored` and `.per_edge`.
//!   - TWO INDEPENDENT CHAINS in one graph: each linear param-free run fuses on its
//!     own; the rewrite handles disjoint components.
//!   - HEAD/TAIL ADJACENCY: a 2-Map run sitting directly against the Source (head)
//!     and against the Sink (tail) fuses — the Source (zero sample inputs) is never
//!     folded into the run and the Sink (zero outputs) is never folded into it,
//!     but the two interior Maps do fold.
//!   - ROUTE-MAP SEEDING CORRECTNESS (the sharp one): every Map in a long chain is
//!     seeded with a DISTINCT parameter, so a misrouted seed (an instance scattered
//!     to the wrong inner body slot) would change the output. fused ≡ unfused then
//!     proves the route table lands each seed exactly where fusion moved its node.
//!   - MID-CHAIN FEEDBACK TAP: an otherwise-linear chain where one interior Map's
//!     output ALSO feeds a delay→feedback. That Map is a fusion boundary (its z⁻¹
//!     consumer must stay scheduler-visible); the runs on either side still fuse.
//!   - OP-COUNT MONOTONICITY: across the whole corpus the fused plan's op_count is
//!     never greater than the unfused plan's (fusion only contracts).
//!
//! Every check is pan-vs-pan ⇒ BIT-EXACT (`expectEqualSlices`), with op_count an
//! exact-integer equality — a divergence is a fusion-rewrite / scatter-seed bug,
//! never an external-numerics disagreement (pan must not disagree with itself).
//!
//! Verified against zig 0.16.0 (the `zig-0-16` skill was loaded before authoring,
//! per project Rules 13/14). No `std.log.err` — the 0.16 runner counts logs as fails.

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const port = pan.port;
const engine = pan.engine;
const numeric = pan.numeric;

const num = numeric.numericFor(.f32, .{});
const S = pan.Sample(f32);

const Gain = pan.filters.Gain(num);
const SoftClip = pan.fx.SoftClip(num);
const Trim = pan.fx.Trim(num);
const DelayLine = pan.DelayLine(S, 4);

const enterRealtimeThread = pan.enterRealtimeThread;

// ===========================================================================
// Boundary + join blocks.
// ===========================================================================

const MonoSource = struct {
    data: [*]const S = undefined,
    pub fn process(self: *@This(), out: []S) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const MonoSink = struct {
    dest: [*]S = undefined,
    pub fn process(self: *@This(), in: []const S) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

/// A 2-input join: out = a + b. Two sample inputs ⇒ never a fold target (a fold
/// target must have exactly one sample input, the chain edge).
const Mix2 = struct {
    pub fn process(_: *@This(), a: []const S, b: []const S, out: []S) void {
        for (a, b, out) |x, y, *o| o.ch[0] = x.ch[0] + y.ch[0];
    }
};

/// Feedback summer: out = dry + g·wet. Port 0 forward, port 1 feedback tap.
const Summer = struct {
    g: f32 = 0.5,
    pub fn process(self: *@This(), dry: []const S, wet: []const S, out: []S) void {
        for (dry, wet, out) |d, w, *y| y.ch[0] = d.ch[0] + self.g * w.ch[0];
    }
};

// ===========================================================================
// Helpers.
// ===========================================================================

fn fillNoise(buf: []S, seed: u64) void {
    var s = seed | 1;
    for (buf) |*frame| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        const u: u32 = @truncate(s);
        frame.ch[0] = @as(f32, @floatFromInt(u % 2_000_001)) / 1_000_000.0 - 1.0;
    }
}
fn lanes(frames: []const S) []const f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(frames)));
}

/// Render `g`+`blocks` both unfused and fused from a SHARED seed factory, asserting
/// bit-exact sink equality and returning the (unfused, fused) op counts. The seed
/// factory takes a `*[N]S` output pointer so each path writes its own sink buffer.
fn runUF(
    comptime g: graph.Graph,
    comptime blocks: []const type,
    comptime mode: pan.commit.BufferMode,
    seed_un: std.meta.Tuple(blocks),
    seed_fu: std.meta.Tuple(blocks),
) struct { un: usize, fu: usize } {
    const Unfused = engine.ExecutorMode(g, blocks, mode);
    const Fused = engine.FusedExecutorModeOnly(g, blocks, mode);
    var unfused: Unfused = .{ .instances = seed_un };
    var fused = Fused.init(seed_fu);
    const token = enterRealtimeThread();
    defer token.leave();
    unfused.render(token);
    fused.render(token);
    return .{ .un = Unfused.committed.op_count, .fu = Fused.committed.op_count };
}

// ===========================================================================
// (A) DIAMOND — Source → A → {B,C} → D(join) → Sink.
// ===========================================================================

const Diamond = struct {
    pub const blocks = .{ MonoSource, Gain, SoftClip, Trim, Mix2, MonoSink };
    pub fn build(comptime N: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const a = gg.add(Gain);
        const b = gg.add(SoftClip);
        const c = gg.add(Trim);
        const d = gg.add(Mix2);
        const snk = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), a, 0);
        gg.connect(port.MapOutPort(Gain), a, 0, port.MapInPort(SoftClip), b, 0); // fan-out 1
        gg.connect(port.MapOutPort(Gain), a, 0, port.MapInPort(Trim), c, 0); // fan-out 2
        gg.connect(port.MapOutPort(SoftClip), b, 0, port.MapInPortAt(Mix2, 0), d, 0);
        gg.connect(port.MapOutPort(Trim), c, 0, port.MapInPortAt(Mix2, 1), d, 1);
        gg.connect(port.MapOutPort(Mix2), d, 0, port.MapInPort(MonoSink), snk, 0);
        return gg;
    }
};

test "catalog §7.3: a diamond (fan-out then join) is bit-exact fused≡unfused, .colored AND .per_edge" {
    const N = 128;
    const g = comptime Diamond.build(N);
    const blocks = comptime &Diamond.blocks;

    var input: [N]S = undefined;
    fillNoise(&input, 0xD1A_0AD);

    inline for (.{ pan.commit.BufferMode.colored, pan.commit.BufferMode.per_edge }) |mode| {
        var ou: [N]S = undefined;
        var of: [N]S = undefined;
        const seed_un = .{ MonoSource{ .data = &input }, Gain{ .gain = 0.7 }, SoftClip{ .drive = 1.6 }, Trim{ .gain_db = -2.0 }, Mix2{}, MonoSink{ .dest = &ou } };
        const seed_fu = .{ MonoSource{ .data = &input }, Gain{ .gain = 0.7 }, SoftClip{ .drive = 1.6 }, Trim{ .gain_db = -2.0 }, Mix2{}, MonoSink{ .dest = &of } };
        const counts = runUF(g, blocks, mode, seed_un, seed_fu);
        try std.testing.expectEqualSlices(f32, lanes(&ou), lanes(&of));
        // A fans out (never folded), B/C each have only the fan-out producer upstream
        // (a fan-out value, not fold-into-able) and feed the 2-input join D (not a
        // single-input fold target), and D has two inputs. So NO pair fuses: op_count
        // is unchanged.
        try std.testing.expectEqual(counts.un, counts.fu);
    }
}

// ===========================================================================
// (B) TWO INDEPENDENT CHAINS in one graph — each fuses on its own.
//   SrcA → Gain → SoftClip → SinkA   ;   SrcB → Trim → Gain → SinkB
// ===========================================================================

const TwoChains = struct {
    pub const blocks = .{ MonoSource, Gain, SoftClip, MonoSink, MonoSource, Trim, Gain, MonoSink };
    pub fn build(comptime N: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const sa = gg.add(MonoSource);
        const g1 = gg.add(Gain);
        const c1 = gg.add(SoftClip);
        const ka = gg.add(MonoSink);
        const sb = gg.add(MonoSource);
        const t1 = gg.add(Trim);
        const g2 = gg.add(Gain);
        const kb = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), sa, 0, port.MapInPort(Gain), g1, 0);
        gg.connect(port.MapOutPort(Gain), g1, 0, port.MapInPort(SoftClip), c1, 0);
        gg.connect(port.MapOutPort(SoftClip), c1, 0, port.MapInPort(MonoSink), ka, 0);
        gg.connect(port.MapOutPort(MonoSource), sb, 0, port.MapInPort(Trim), t1, 0);
        gg.connect(port.MapOutPort(Trim), t1, 0, port.MapInPort(Gain), g2, 0);
        gg.connect(port.MapOutPort(Gain), g2, 0, port.MapInPort(MonoSink), kb, 0);
        return gg;
    }
};

test "catalog §11.3: two disjoint chains in one graph each fuse independently (bit-exact)" {
    const N = 96;
    const g = comptime TwoChains.build(N);
    const blocks = comptime &TwoChains.blocks;

    var ina: [N]S = undefined;
    var inb: [N]S = undefined;
    fillNoise(&ina, 0xAAAA);
    fillNoise(&inb, 0xBBBB);
    var ua: [N]S = undefined;
    var ub: [N]S = undefined;
    var fa: [N]S = undefined;
    var fb: [N]S = undefined;

    const seed_un = .{ MonoSource{ .data = &ina }, Gain{ .gain = 0.8 }, SoftClip{ .drive = 1.3 }, MonoSink{ .dest = &ua }, MonoSource{ .data = &inb }, Trim{ .gain_db = 1.5 }, Gain{ .gain = 1.1 }, MonoSink{ .dest = &ub } };
    const seed_fu = .{ MonoSource{ .data = &ina }, Gain{ .gain = 0.8 }, SoftClip{ .drive = 1.3 }, MonoSink{ .dest = &fa }, MonoSource{ .data = &inb }, Trim{ .gain_db = 1.5 }, Gain{ .gain = 1.1 }, MonoSink{ .dest = &fb } };
    const counts = runUF(g, blocks, .colored, seed_un, seed_fu);

    try std.testing.expectEqualSlices(f32, lanes(&ua), lanes(&fa));
    try std.testing.expectEqualSlices(f32, lanes(&ub), lanes(&fb));
    // Each chain's 2-Map run folds: 8 ops → 6 ops (each {2 Maps} → one fused op).
    try std.testing.expectEqual(@as(usize, 8), counts.un);
    try std.testing.expectEqual(@as(usize, 6), counts.fu);
}

// ===========================================================================
// (C) HEAD/TAIL ADJACENCY + ROUTE-MAP SEEDING — a long chain where every Map has a
// DISTINCT parameter, so a misrouted seed would change the output.
//   Source → Gain → Trim → SoftClip → Gain → Trim → Sink
// ===========================================================================

const SeededChain = struct {
    pub const blocks = .{ MonoSource, Gain, Trim, SoftClip, Gain, Trim, MonoSink };
    pub fn build(comptime N: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const n1 = gg.add(Gain);
        const n2 = gg.add(Trim);
        const n3 = gg.add(SoftClip);
        const n4 = gg.add(Gain);
        const n5 = gg.add(Trim);
        const snk = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), n1, 0);
        gg.connect(port.MapOutPort(Gain), n1, 0, port.MapInPort(Trim), n2, 0);
        gg.connect(port.MapOutPort(Trim), n2, 0, port.MapInPort(SoftClip), n3, 0);
        gg.connect(port.MapOutPort(SoftClip), n3, 0, port.MapInPort(Gain), n4, 0);
        gg.connect(port.MapOutPort(Gain), n4, 0, port.MapInPort(Trim), n5, 0);
        gg.connect(port.MapOutPort(Trim), n5, 0, port.MapInPort(MonoSink), snk, 0);
        return gg;
    }
};

test "catalog §11.3: distinct per-Map seeds route correctly through fusion (misroute would diverge)" {
    const N = 256;
    const g = comptime SeededChain.build(N);
    const blocks = comptime &SeededChain.blocks;

    var input: [N]S = undefined;
    fillNoise(&input, 0x5EED_1234);
    var ou: [N]S = undefined;
    var of: [N]S = undefined;

    // Each Map carries a DISTINCT, non-commuting-with-its-neighbours parameter. If the
    // route table scattered any seed to the wrong inner body slot, the composed result
    // would differ (Gain×Trim×SoftClip do not commute in general).
    const seed_un = .{ MonoSource{ .data = &input }, Gain{ .gain = 0.37 }, Trim{ .gain_db = 4.2 }, SoftClip{ .drive = 2.7 }, Gain{ .gain = 1.9 }, Trim{ .gain_db = -5.1 }, MonoSink{ .dest = &ou } };
    const seed_fu = .{ MonoSource{ .data = &input }, Gain{ .gain = 0.37 }, Trim{ .gain_db = 4.2 }, SoftClip{ .drive = 2.7 }, Gain{ .gain = 1.9 }, Trim{ .gain_db = -5.1 }, MonoSink{ .dest = &of } };
    const counts = runUF(g, blocks, .colored, seed_un, seed_fu);

    try std.testing.expectEqualSlices(f32, lanes(&ou), lanes(&of));
    // The whole 5-Map interior folds into one Subgraph: 7 ops → 3 (src + fused + sink).
    try std.testing.expectEqual(@as(usize, 7), counts.un);
    try std.testing.expectEqual(@as(usize, 3), counts.fu);
}

// ===========================================================================
// (D) MID-CHAIN FEEDBACK TAP — a linear chain where an interior Map's output ALSO
// feeds a delay→feedback cycle. That Map is a fusion boundary; the runs around it
// still fuse.
//   Source → Gain → Summer(.0) → Trim → SoftClip → Sink
//                     Summer → DelayLine → Summer(.1)  (feedback)
// The Summer is a feedback writer+reader (never folded). The single Gain before it
// has no fusable partner (Summer is a boundary); the Trim→SoftClip run after it folds.
// ===========================================================================

const MidFeedback = struct {
    pub const blocks = .{ MonoSource, Gain, Summer, DelayLine, Trim, SoftClip, MonoSink };
    pub fn build(comptime N: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const gn = gg.add(Gain);
        const sum = gg.add(Summer);
        const dly = gg.add(DelayLine);
        const tr = gg.add(Trim);
        const sc = gg.add(SoftClip);
        const snk = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), gn, 0);
        gg.connect(port.MapOutPort(Gain), gn, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Trim), tr, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(DelayLine), dly, 0);
        gg.connect(port.MapOutPort(Trim), tr, 0, port.MapInPort(SoftClip), sc, 0);
        gg.connect(port.MapOutPort(SoftClip), sc, 0, port.MapInPort(MonoSink), snk, 0);
        gg.connectFeedback(port.MapOutPort(DelayLine), dly, 0, port.MapInPortAt(Summer, 1), sum, 1);
        return gg;
    }
};

test "catalog §5.2: a mid-chain feedback tap is a fusion boundary; the run after it still fuses" {
    const N = 128;
    const g = comptime MidFeedback.build(N);
    const blocks = comptime &MidFeedback.blocks;

    var input: [N]S = undefined;
    fillNoise(&input, 0xFEED_BAC0);
    var ou: [N]S = undefined;
    var of: [N]S = undefined;

    const seed_un = .{ MonoSource{ .data = &input }, Gain{ .gain = 0.6 }, Summer{ .g = 0.5 }, DelayLine{}, Trim{ .gain_db = 1.0 }, SoftClip{ .drive = 1.4 }, MonoSink{ .dest = &ou } };
    const seed_fu = .{ MonoSource{ .data = &input }, Gain{ .gain = 0.6 }, Summer{ .g = 0.5 }, DelayLine{}, Trim{ .gain_db = 1.0 }, SoftClip{ .drive = 1.4 }, MonoSink{ .dest = &of } };
    const counts = runUF(g, blocks, .colored, seed_un, seed_fu);

    try std.testing.expectEqualSlices(f32, lanes(&ou), lanes(&of));
    // The Summer output fans out (to Trim AND to the DelayLine) so the Gain→Summer
    // pair never folds, and the Summer/DelayLine feedback nodes never fold. Only the
    // Trim→SoftClip run folds: 7 ops → 6.
    try std.testing.expectEqual(@as(usize, 7), counts.un);
    try std.testing.expectEqual(@as(usize, 6), counts.fu);
    // Monotonic: fusion never grows the op count.
    try std.testing.expect(counts.fu <= counts.un);
}
