//! fusion_differential_test — the Yoneda characterization of the AUTOMATIC comptime
//! loop-fusion pass (`src/fusion.zig` + `engine.FusedExecutor`). Two observable laws,
//! both pinned against an oracle that is ALSO pan code (so a divergence is a fusion-
//! rewrite / scatter-seed bug, never an external-numerics disagreement):
//!
//!   (1) FUSED ≡ UNFUSED, BIT-EXACT (the soundness gate). For the SAME author graph +
//!       SAME per-node seeds + SAME input, the `FusedExecutor` (which folds adjacent
//!       rate-1:1 type-stable single-consumer Map chains into one block-size-1
//!       `Subgraph` pass each) and the plain unfused `ExecutorMode` MUST produce a
//!       BYTE-IDENTICAL sink output — under both `.colored` and `.per_edge`. Fusion is
//!       composition of morphisms: `(g ∘ f)(x) = g(f(x))` holds sample-for-sample, so
//!       an "almost" is a failure, never a pass (pan must not disagree with itself).
//!       A `ParanoidFusedExecutor` / paranoid-unfused pair additionally asserts NO NaN
//!       reaches the sink (the active net for a fused-pool reuse bug).
//!
//!   (2) FUSION ACTUALLY FIRES / IS WITHHELD (the optimization is real AND bounded).
//!       A long param-free linear Map chain fuses — its FUSED plan `op_count` drops vs
//!       the unfused plan. A fan-out value (a Map whose output feeds TWO consumers) is
//!       NOT fused across the fork (op_count unchanged at that node). A `params`-bearing
//!       Map is a fusion boundary; a delay-guarded feedback cycle's feedback nodes are
//!       never folded (z⁻¹ must stay scheduler-visible).
//!
//! Verified against zig 0.16.0 (the `zig-0-16` skill was loaded before authoring, per
//! project Rules 13/14). No `std.log.err` — the 0.16 test runner counts logged errors
//! as failures. Every check is pan-vs-pan ⇒ bit-exact, or exact-integer equality on
//! plan figures.

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const port = pan.port;
const engine = pan.engine;
const numeric = pan.numeric;
const filters = pan.filters;
const fx = pan.fx;

const Sample = pan.Sample(f32);
const num = numeric.numericFor(.f32, .{});

const Gain = filters.Gain(num); // aliasing_safe, param-free, rate-1:1 Map
const SoftClip = fx.SoftClip(num); // aliasing_safe, param-free, rate-1:1 Map
const Trim = fx.Trim(num); // aliasing_safe, param-free, rate-1:1 Map
const OnePole = filters.OnePole(num); // param-bearing (cutoff) — a fusion boundary
const DelayLine = pan.DelayLine(Sample, 4); // delay element — never fused
const Summer = struct {
    g: f32 = 0.5,
    pub fn process(self: *@This(), dry: []const Sample, wet: []const Sample, out: []Sample) void {
        for (dry, wet, out) |d, w, *y| y.ch[0] = d.ch[0] + self.g * w.ch[0];
    }
};

// ===========================================================================
// Boundary blocks (a Source has zero sample inputs; a Sink has zero outputs).
// ===========================================================================

const MonoSource = struct {
    data: [*]const Sample = undefined,
    pub fn process(self: *@This(), out: []Sample) void {
        @memcpy(out, self.data[0..out.len]);
    }
};

const MonoSink = struct {
    dest: [*]Sample = undefined,
    pub fn process(self: *@This(), in: []const Sample) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

// ===========================================================================
// Helpers (mirroring tests/inplace_coalescing_test.zig).
// ===========================================================================

fn fillNoise(buf: []Sample, seed: u64) void {
    var s = seed | 1;
    for (buf) |*frame| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        const u: u32 = @truncate(s);
        frame.ch[0] = @as(f32, @floatFromInt(u % 2_000_001)) / 1_000_000.0 - 1.0;
    }
}

fn lanes(frames: []const Sample) []const f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(frames)));
}

fn bitExact(got: []const f32, ref: []const f32) !void {
    try std.testing.expectEqualSlices(f32, ref, got);
}

fn anyNaN(frames: []const Sample) bool {
    for (frames) |s| if (std.math.isNan(s.ch[0])) return true;
    return false;
}

// ===========================================================================
// CORPUS 1 — a long linear param-free Map chain MUST fuse, bit-exactly.
//   Source → Gain → SoftClip → Trim → Gain → Sink
// The interior Gain→SoftClip→Trim→Gain is one maximal fusable chain (length 4)
// folded into ONE Subgraph node.
// ===========================================================================

const Chain = struct {
    pub const blocks = .{ MonoSource, Gain, SoftClip, Trim, Gain, MonoSink };
    pub fn build(comptime N: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const g1 = gg.add(Gain);
        const sc = gg.add(SoftClip);
        const tr = gg.add(Trim);
        const g2 = gg.add(Gain);
        const snk = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), g1, 0);
        gg.connect(port.MapOutPort(Gain), g1, 0, port.MapInPort(SoftClip), sc, 0);
        gg.connect(port.MapOutPort(SoftClip), sc, 0, port.MapInPort(Trim), tr, 0);
        gg.connect(port.MapOutPort(Trim), tr, 0, port.MapInPort(Gain), g2, 0);
        gg.connect(port.MapOutPort(Gain), g2, 0, port.MapInPort(MonoSink), snk, 0);
        return gg;
    }
};

fn seedChain(out: *[64]Sample, input: *const [64]Sample) std.meta.Tuple(&.{ MonoSource, Gain, SoftClip, Trim, Gain, MonoSink }) {
    return .{
        .{ .data = input },
        .{ .gain = 0.7012 },
        .{ .drive = 1.9 },
        .{ .gain_db = -3.5 },
        .{ .gain = 1.31 },
        .{ .dest = out },
    };
}

test "catalog §11.3: a long param-free Map chain fuses and is bit-exact to unfused (.colored)" {
    const N = 64;
    const g = comptime Chain.build(N);
    const blocks = comptime &Chain.blocks;

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xFA5E);
    var out_fused: [N]Sample = undefined;
    var out_unfused: [N]Sample = undefined;

    const Fused = engine.FusedExecutorModeOnly(g, blocks, .colored);
    const Unfused = engine.ExecutorMode(g, blocks, .colored);

    var fused = Fused.init(seedChain(&out_fused, &input));
    var unfused: Unfused = .{ .instances = seedChain(&out_unfused, &input) };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    fused.render(token);
    unfused.render(token);

    try bitExact(lanes(&out_fused), lanes(&out_unfused));

    // The optimization is REAL: folding the interior 4-Map chain into one Subgraph
    // drops the top-level op count. Unfused: source + 4 maps + sink = 6 ops; fused:
    // source + 1 fused Subgraph + sink = 3 ops.
    try std.testing.expect(Fused.committed.op_count < Unfused.committed.op_count);
    try std.testing.expectEqual(@as(usize, 6), Unfused.committed.op_count);
    try std.testing.expectEqual(@as(usize, 3), Fused.committed.op_count);
}

test "catalog §11.3: the same chain is bit-exact under .per_edge too" {
    const N = 64;
    const g = comptime Chain.build(N);
    const blocks = comptime &Chain.blocks;

    var input: [N]Sample = undefined;
    fillNoise(&input, 0x1234ABCD);
    var out_fused: [N]Sample = undefined;
    var out_unfused: [N]Sample = undefined;

    const Fused = engine.FusedExecutorModeOnly(g, blocks, .per_edge);
    const Unfused = engine.ExecutorMode(g, blocks, .per_edge);

    var fused = Fused.init(seedChain(&out_fused, &input));
    var unfused: Unfused = .{ .instances = seedChain(&out_unfused, &input) };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    fused.render(token);
    unfused.render(token);

    try bitExact(lanes(&out_fused), lanes(&out_unfused));
}

test "catalog §11.3: paranoid fused≡paranoid unfused, no NaN reaches the sink" {
    const N = 64;
    const g = comptime Chain.build(N);
    const blocks = comptime &Chain.blocks;

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xDEADBEEF);
    var out_fused: [N]Sample = undefined;
    var out_unfused: [N]Sample = undefined;

    const Fused = engine.ParanoidFusedExecutor(g, blocks, .colored);
    const Unfused = engine.ParanoidExecutor(g, blocks, .colored);

    var fused = Fused.init(seedChain(&out_fused, &input));
    var unfused: Unfused = .{ .instances = seedChain(&out_unfused, &input) };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    fused.render(token);
    unfused.render(token);

    try bitExact(lanes(&out_fused), lanes(&out_unfused));
    try std.testing.expect(!anyNaN(&out_fused));
    try std.testing.expect(!anyNaN(&out_unfused));
}

// ===========================================================================
// CORPUS 2 — a FAN-OUT value must NOT be fused across the fork.
//   Source → Gain(=fork) → SoftClip → SinkA
//                       └→ Trim     → SinkB
// The fork Gain has TWO consumers, so it can never fold into either downstream
// branch (folding would strand the other reader). Its op stays a top-level op.
// ===========================================================================

const Fork = struct {
    pub const blocks = .{ MonoSource, Gain, SoftClip, Trim, MonoSink, MonoSink };
    pub fn build(comptime N: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const fork = gg.add(Gain);
        const sc = gg.add(SoftClip);
        const tr = gg.add(Trim);
        const sa = gg.add(MonoSink);
        const sb = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), fork, 0);
        gg.connect(port.MapOutPort(Gain), fork, 0, port.MapInPort(SoftClip), sc, 0);
        gg.connect(port.MapOutPort(Gain), fork, 0, port.MapInPort(Trim), tr, 0);
        gg.connect(port.MapOutPort(SoftClip), sc, 0, port.MapInPort(MonoSink), sa, 0);
        gg.connect(port.MapOutPort(Trim), tr, 0, port.MapInPort(MonoSink), sb, 0);
        return gg;
    }
};

test "catalog §7.3: a fan-out value is NOT fused across the fork (bit-exact + op_count unchanged)" {
    const N = 64;
    const g = comptime Fork.build(N);
    const blocks = comptime &Fork.blocks;

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xF0F0);
    var fa: [N]Sample = undefined;
    var fb: [N]Sample = undefined;
    var ua: [N]Sample = undefined;
    var ub: [N]Sample = undefined;

    const seedF = .{
        MonoSource{ .data = &input }, Gain{ .gain = 0.6 },     SoftClip{ .drive = 1.5 },
        Trim{ .gain_db = 2.0 },       MonoSink{ .dest = &fa }, MonoSink{ .dest = &fb },
    };
    const seedU = .{
        MonoSource{ .data = &input }, Gain{ .gain = 0.6 },     SoftClip{ .drive = 1.5 },
        Trim{ .gain_db = 2.0 },       MonoSink{ .dest = &ua }, MonoSink{ .dest = &ub },
    };

    const Fused = engine.FusedExecutorModeOnly(g, blocks, .colored);
    const Unfused = engine.ExecutorMode(g, blocks, .colored);

    var fused = Fused.init(seedF);
    var unfused: Unfused = .{ .instances = seedU };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    fused.render(token);
    unfused.render(token);

    try bitExact(lanes(&fa), lanes(&ua));
    try bitExact(lanes(&fb), lanes(&ub));

    // The fork Gain has two readers → never fused. The single-consumer SoftClip and
    // Trim each have only the fork upstream (a fan-out producer, not fusable into),
    // so NO pair fuses: the fused op count equals the unfused one.
    try std.testing.expectEqual(Unfused.committed.op_count, Fused.committed.op_count);
}

// ===========================================================================
// CORPUS 3 — a param-bearing Map is a fusion boundary; chains on either side may
// fuse, the param node stays. Source → Gain → SoftClip → OnePole(param) → Trim →
// Gain → Sink. The Gain→SoftClip run (before OnePole) is one fusable chain; the
// Trim→Gain run (after OnePole) is another; OnePole itself stays unfused.
// ===========================================================================

const Boundary = struct {
    pub const blocks = .{ MonoSource, Gain, SoftClip, OnePole, Trim, Gain, MonoSink };
    pub fn build(comptime N: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const g1 = gg.add(Gain);
        const sc = gg.add(SoftClip);
        const op = gg.add(OnePole);
        const tr = gg.add(Trim);
        const g2 = gg.add(Gain);
        const snk = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), g1, 0);
        gg.connect(port.MapOutPort(Gain), g1, 0, port.MapInPort(SoftClip), sc, 0);
        gg.connect(port.MapOutPort(SoftClip), sc, 0, port.MapInPort(OnePole), op, 0);
        gg.connect(port.MapOutPort(OnePole), op, 0, port.MapInPort(Trim), tr, 0);
        gg.connect(port.MapOutPort(Trim), tr, 0, port.MapInPort(Gain), g2, 0);
        gg.connect(port.MapOutPort(Gain), g2, 0, port.MapInPort(MonoSink), snk, 0);
        return gg;
    }
};

test "catalog §11.3: a param-bearing Map is a fusion boundary (both sides fuse, it stays)" {
    const N = 64;
    const g = comptime Boundary.build(N);
    const blocks = comptime &Boundary.blocks;

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xB0117);
    var of: [N]Sample = undefined;
    var ou: [N]Sample = undefined;

    const seedF = .{
        MonoSource{ .data = &input }, Gain{ .gain = 0.5 },    SoftClip{ .drive = 1.2 },
        OnePole{},                    Trim{ .gain_db = 1.0 }, Gain{ .gain = 0.9 },
        MonoSink{ .dest = &of },
    };
    const seedU = .{
        MonoSource{ .data = &input }, Gain{ .gain = 0.5 },    SoftClip{ .drive = 1.2 },
        OnePole{},                    Trim{ .gain_db = 1.0 }, Gain{ .gain = 0.9 },
        MonoSink{ .dest = &ou },
    };

    const Fused = engine.FusedExecutorModeOnly(g, blocks, .colored);
    const Unfused = engine.ExecutorMode(g, blocks, .colored);

    var fused = Fused.init(seedF);
    var unfused: Unfused = .{ .instances = seedU };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    fused.render(token);
    unfused.render(token);

    try bitExact(lanes(&of), lanes(&ou));

    // Unfused: source + 5 maps + sink = 7 ops. Fused: source + {Gain,SoftClip}-fused +
    // OnePole + {Trim,Gain}-fused + sink = 5 ops. OnePole (param) stayed its own op.
    try std.testing.expectEqual(@as(usize, 7), Unfused.committed.op_count);
    try std.testing.expectEqual(@as(usize, 5), Fused.committed.op_count);
}

// ===========================================================================
// CORPUS 4 — a delay-guarded feedback cycle: the feedback nodes are NOT fused; a
// surrounding linear run still fuses. Source → Gain → SoftClip → Summer(.0) →
// Sink ; Summer → DelayLine → Summer(.1) (feedback). The Gain→SoftClip run fuses;
// the Summer/DelayLine cycle (a feedback writer/reader + a delay element) is left
// intact so the z⁻¹ stays scheduler-visible.
// ===========================================================================

const Feedback = struct {
    pub const blocks = .{ MonoSource, Gain, SoftClip, Summer, DelayLine, MonoSink };
    pub fn build(comptime N: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const g1 = gg.add(Gain);
        const sc = gg.add(SoftClip);
        const sum = gg.add(Summer);
        const dly = gg.add(DelayLine);
        const snk = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), g1, 0);
        gg.connect(port.MapOutPort(Gain), g1, 0, port.MapInPort(SoftClip), sc, 0);
        gg.connect(port.MapOutPort(SoftClip), sc, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(MonoSink), snk, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(DelayLine), dly, 0);
        gg.connectFeedback(port.MapOutPort(DelayLine), dly, 0, port.MapInPortAt(Summer, 1), sum, 1);
        return gg;
    }
};

test "catalog §5.2: a delay-guarded feedback cycle is never fused; a linear run still fuses" {
    const N = 64;
    const g = comptime Feedback.build(N);
    const blocks = comptime &Feedback.blocks;

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xC0DEC0DE);
    var of: [N]Sample = undefined;
    var ou: [N]Sample = undefined;

    const seedF = .{
        MonoSource{ .data = &input }, Gain{ .gain = 0.8 }, SoftClip{ .drive = 1.4 },
        Summer{ .g = 0.6 },           DelayLine{},         MonoSink{ .dest = &of },
    };
    const seedU = .{
        MonoSource{ .data = &input }, Gain{ .gain = 0.8 }, SoftClip{ .drive = 1.4 },
        Summer{ .g = 0.6 },           DelayLine{},         MonoSink{ .dest = &ou },
    };

    const Fused = engine.FusedExecutorModeOnly(g, blocks, .colored);
    const Unfused = engine.ExecutorMode(g, blocks, .colored);

    var fused = Fused.init(seedF);
    var unfused: Unfused = .{ .instances = seedU };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    fused.render(token);
    unfused.render(token);

    try bitExact(lanes(&of), lanes(&ou));

    // The Summer (feedback writer + reader) and DelayLine (delay element) are never
    // fused. Only the Gain→SoftClip run folds: source + fused + Summer + DelayLine +
    // sink = 5 ops, down from 6 unfused.
    try std.testing.expectEqual(@as(usize, 6), Unfused.committed.op_count);
    try std.testing.expectEqual(@as(usize, 5), Fused.committed.op_count);
}

// ===========================================================================
// CORPUS 5 — a "perceptual-sparse" multi-reduction shape: one source feeding two
// param-free reduction chains that each fuse independently.
//   Source → (Gain→Trim → SinkA) and → (SoftClip→Gain → SinkB)
// The source value fans out (NOT fused across the fork); each branch's 2-Map run
// fuses on its own.
// ===========================================================================

const MultiReduce = struct {
    pub const blocks = .{ MonoSource, Gain, Trim, SoftClip, Gain, MonoSink, MonoSink };
    pub fn build(comptime N: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const a1 = gg.add(Gain);
        const a2 = gg.add(Trim);
        const b1 = gg.add(SoftClip);
        const b2 = gg.add(Gain);
        const sa = gg.add(MonoSink);
        const sb = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), a1, 0);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(SoftClip), b1, 0);
        gg.connect(port.MapOutPort(Gain), a1, 0, port.MapInPort(Trim), a2, 0);
        gg.connect(port.MapOutPort(Trim), a2, 0, port.MapInPort(MonoSink), sa, 0);
        gg.connect(port.MapOutPort(SoftClip), b1, 0, port.MapInPort(Gain), b2, 0);
        gg.connect(port.MapOutPort(Gain), b2, 0, port.MapInPort(MonoSink), sb, 0);
        return gg;
    }
};

test "catalog §7.4: a multi-reduction source fans out (unfused) while each branch fuses" {
    const N = 64;
    const g = comptime MultiReduce.build(N);
    const blocks = comptime &MultiReduce.blocks;

    var input: [N]Sample = undefined;
    fillNoise(&input, 0x5A5A5A5A);
    var fa: [N]Sample = undefined;
    var fb: [N]Sample = undefined;
    var ua: [N]Sample = undefined;
    var ub: [N]Sample = undefined;

    const seedF = .{
        MonoSource{ .data = &input }, Gain{ .gain = 0.55 }, Trim{ .gain_db = -2.0 },
        SoftClip{ .drive = 1.7 },     Gain{ .gain = 1.2 },  MonoSink{ .dest = &fa },
        MonoSink{ .dest = &fb },
    };
    const seedU = .{
        MonoSource{ .data = &input }, Gain{ .gain = 0.55 }, Trim{ .gain_db = -2.0 },
        SoftClip{ .drive = 1.7 },     Gain{ .gain = 1.2 },  MonoSink{ .dest = &ua },
        MonoSink{ .dest = &ub },
    };

    const Fused = engine.FusedExecutorModeOnly(g, blocks, .colored);
    const Unfused = engine.ExecutorMode(g, blocks, .colored);

    var fused = Fused.init(seedF);
    var unfused: Unfused = .{ .instances = seedU };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    fused.render(token);
    unfused.render(token);

    try bitExact(lanes(&fa), lanes(&ua));
    try bitExact(lanes(&fb), lanes(&ub));

    // Unfused: source + 4 maps + 2 sinks = 7 ops. Fused: source + 2 fused branches +
    // 2 sinks = 5 ops (the source's fan-out value is never folded into either branch).
    try std.testing.expectEqual(@as(usize, 7), Unfused.committed.op_count);
    try std.testing.expectEqual(@as(usize, 5), Fused.committed.op_count);
}

// ===========================================================================
// CORPUS 6 — a graph with NO fusable chain returns an isomorphic copy (all
// passthrough): a single Gain between source and sink can't pair with anything.
// ===========================================================================

test "catalog §11.3: a graph with no fusable chain is an isomorphic passthrough copy" {
    const N = 32;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const gn = gg.add(Gain);
        const snk = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), gn, 0);
        gg.connect(port.MapOutPort(Gain), gn, 0, port.MapInPort(MonoSink), snk, 0);
        break :blk gg;
    };
    const blocks = comptime &.{ MonoSource, Gain, MonoSink };

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xAB);
    var of: [N]Sample = undefined;
    var ou: [N]Sample = undefined;

    const Fused = engine.FusedExecutorModeOnly(g, blocks, .colored);
    const Unfused = engine.ExecutorMode(g, blocks, .colored);

    var fused = Fused.init(.{ MonoSource{ .data = &input }, Gain{ .gain = 0.5 }, MonoSink{ .dest = &of } });
    var unfused: Unfused = .{ .instances = .{ MonoSource{ .data = &input }, Gain{ .gain = 0.5 }, MonoSink{ .dest = &ou } } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    fused.render(token);
    unfused.render(token);

    try bitExact(lanes(&of), lanes(&ou));
    // No pair (a lone Gain has no fusable neighbour) ⇒ op_count unchanged, every
    // route is a passthrough.
    try std.testing.expectEqual(Unfused.committed.op_count, Fused.committed.op_count);
    inline for (Fused.route) |r| {
        try std.testing.expect(r == .passthrough);
    }
}
