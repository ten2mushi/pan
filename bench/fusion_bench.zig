//! Benchmark: the Phase-18 automatic loop-fusion headline evidence.
//!
//! MEASURES (never asserts an oracle — fused≡unfused CORRECTNESS lives in the
//! differential tests under `tests/`): for a long param-free reduction chain and a
//! multi-reduction fan-out shape, the win that fusion buys, fuse OFF vs fuse ON:
//!
//!   - BYTE DISPLACEMENT per render — Σ over the op-list of the bytes each op reads
//!     (its input buffers) plus writes (its output buffers). This is the dynamic
//!     cache traffic, and it is fusion's PRIMARY performance lever: folding an
//!     adjacent rate-1:1 type-stable Map chain into one block-size-1 `Subgraph` pass
//!     keeps every intermediate in registers, so the round-trips through the pool
//!     between the folded Maps vanish from the traffic total.
//!   - the OP COUNT drop (each fused chain collapses to one top-level op).
//!   - a TIMED render of both, seeded with identical block instances and identical
//!     noise input (so the comparison is honest), over many iterations: ns/render,
//!     MB/s, and the fused/unfused speedup. Every output sample is consumed so DCE
//!     cannot delete the timed work.
//!
//! Build/run: `zig build bench` (ReleaseFast). A bench warms up, takes the min over
//! repetitions (one-shot timings are unreliable under load), and consumes results.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const graph = pan.graph;
const port = pan.port;
const engine = pan.engine;
const numeric = pan.numeric;

const num = numeric.numericFor(.f32, .{});
const S = pan.Sample(f32);

/// Outer render window. The interior of each corpus folds independently of N.
const N = 512;

const Gain = pan.filters.Gain(num); // param-free, rate-1:1, type-stable Map
const SoftClip = pan.fx.SoftClip(num); // param-free, rate-1:1, type-stable Map
const Trim = pan.fx.Trim(num); // param-free, rate-1:1, type-stable Map

// A Source has zero sample inputs; a Sink has zero sample outputs. Both are plain
// memcpy endpoints so the timed cost is the interior chain, not boundary work.
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

// ---------------------------------------------------------------------------
// Corpus 1: a long linear param-free Map chain. The whole interior folds into
// one Subgraph, so the intermediate pool round-trips collapse.
//   Source → Gain → SoftClip → Trim → Gain → SoftClip → Trim → Gain → Sink
// ---------------------------------------------------------------------------

const LongChain = struct {
    const blocks = .{ MonoSource, Gain, SoftClip, Trim, Gain, SoftClip, Trim, Gain, MonoSink };
    fn build(comptime BN: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = BN;
        const src = gg.add(MonoSource);
        const g1 = gg.add(Gain);
        const c1 = gg.add(SoftClip);
        const t1 = gg.add(Trim);
        const g2 = gg.add(Gain);
        const c2 = gg.add(SoftClip);
        const t2 = gg.add(Trim);
        const g3 = gg.add(Gain);
        const snk = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), g1, 0);
        gg.connect(port.MapOutPort(Gain), g1, 0, port.MapInPort(SoftClip), c1, 0);
        gg.connect(port.MapOutPort(SoftClip), c1, 0, port.MapInPort(Trim), t1, 0);
        gg.connect(port.MapOutPort(Trim), t1, 0, port.MapInPort(Gain), g2, 0);
        gg.connect(port.MapOutPort(Gain), g2, 0, port.MapInPort(SoftClip), c2, 0);
        gg.connect(port.MapOutPort(SoftClip), c2, 0, port.MapInPort(Trim), t2, 0);
        gg.connect(port.MapOutPort(Trim), t2, 0, port.MapInPort(Gain), g3, 0);
        gg.connect(port.MapOutPort(Gain), g3, 0, port.MapInPort(MonoSink), snk, 0);
        return gg;
    }
    fn seed(input: *const [N]S, out: *[N]S) std.meta.Tuple(&blocks) {
        return .{
            .{ .data = input },   .{ .gain = 0.71 }, .{ .drive = 1.9 },
            .{ .gain_db = -3.5 }, .{ .gain = 1.13 }, .{ .drive = 1.4 },
            .{ .gain_db = 2.0 },  .{ .gain = 0.9 },  .{ .dest = out },
        };
    }
};

// ---------------------------------------------------------------------------
// Corpus 2: a multi-reduction perceptual-sparse shape. One source fans out to
// three independent param-free reduction chains that each fuse on their own; the
// source's fan-out value is correctly NOT folded across the fork.
// ---------------------------------------------------------------------------

const MultiReduce = struct {
    const blocks = .{
        MonoSource, Gain, SoftClip, Trim, // branch A
        SoftClip, Gain, Trim, // branch B
        Trim,     Gain,     SoftClip, // branch C
        MonoSink, MonoSink, MonoSink,
    };
    fn build(comptime BN: usize) graph.Graph {
        var gg = graph.Graph.empty;
        gg.block_size = BN;
        const src = gg.add(MonoSource);
        const a1 = gg.add(Gain);
        const a2 = gg.add(SoftClip);
        const a3 = gg.add(Trim);
        const b1 = gg.add(SoftClip);
        const b2 = gg.add(Gain);
        const b3 = gg.add(Trim);
        const c1 = gg.add(Trim);
        const c2 = gg.add(Gain);
        const c3 = gg.add(SoftClip);
        const sa = gg.add(MonoSink);
        const sb = gg.add(MonoSink);
        const sc = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), a1, 0);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(SoftClip), b1, 0);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Trim), c1, 0);
        gg.connect(port.MapOutPort(Gain), a1, 0, port.MapInPort(SoftClip), a2, 0);
        gg.connect(port.MapOutPort(SoftClip), a2, 0, port.MapInPort(Trim), a3, 0);
        gg.connect(port.MapOutPort(Trim), a3, 0, port.MapInPort(MonoSink), sa, 0);
        gg.connect(port.MapOutPort(SoftClip), b1, 0, port.MapInPort(Gain), b2, 0);
        gg.connect(port.MapOutPort(Gain), b2, 0, port.MapInPort(Trim), b3, 0);
        gg.connect(port.MapOutPort(Trim), b3, 0, port.MapInPort(MonoSink), sb, 0);
        gg.connect(port.MapOutPort(Trim), c1, 0, port.MapInPort(Gain), c2, 0);
        gg.connect(port.MapOutPort(Gain), c2, 0, port.MapInPort(SoftClip), c3, 0);
        gg.connect(port.MapOutPort(SoftClip), c3, 0, port.MapInPort(MonoSink), sc, 0);
        return gg;
    }
    fn seed(input: *const [N]S, oa: *[N]S, ob: *[N]S, oc: *[N]S) std.meta.Tuple(&blocks) {
        return .{
            .{ .data = input }, .{ .gain = 0.55 }, .{ .drive = 1.7 },   .{ .gain_db = -2.0 },
            .{ .drive = 1.5 },  .{ .gain = 1.2 },  .{ .gain_db = 1.0 }, .{ .gain_db = -1.0 },
            .{ .gain = 0.8 },   .{ .drive = 2.1 }, .{ .dest = oa },     .{ .dest = ob },
            .{ .dest = oc },
        };
    }
};

fn reportPair(
    label: []const u8,
    comptime UnNops: usize,
    un_plan: *const pan.commit.Plan(UnNops),
    comptime FuNops: usize,
    fu_plan: *const pan.commit.Plan(FuNops),
    ns_un: u64,
    ns_fu: u64,
    iters: usize,
) void {
    const disp_un = h.byteDisplacement(UnNops, un_plan);
    const disp_fu = h.byteDisplacement(FuNops, fu_plan);
    const disp_drop = (1.0 - @as(f64, @floatFromInt(disp_fu)) / @as(f64, @floatFromInt(disp_un))) * 100.0;
    const per_un = @as(f64, @floatFromInt(ns_un)) / @as(f64, @floatFromInt(iters));
    const per_fu = @as(f64, @floatFromInt(ns_fu)) / @as(f64, @floatFromInt(iters));
    const speedup = per_un / per_fu;
    const frames: f64 = @floatFromInt(N);
    const mbps_un = frames / (per_un / 1e9) * @as(f64, @floatFromInt(@sizeOf(f32))) / (1024.0 * 1024.0);
    const mbps_fu = frames / (per_fu / 1e9) * @as(f64, @floatFromInt(@sizeOf(f32))) / (1024.0 * 1024.0);
    std.debug.print(
        "{s} (N={d}):\n" ++
            "  fuse OFF: op_count {d:>2}  displacement {d:>5} B/render  {d:>7.1} ns/render  {d:>6.1} MB/s\n" ++
            "  fuse ON : op_count {d:>2}  displacement {d:>5} B/render  {d:>7.1} ns/render  {d:>6.1} MB/s\n" ++
            "  WIN     : op_count {d} → {d}   displacement {d} → {d} B  ({d:.1}% less traffic)   speedup {d:.2}x\n",
        .{
            label,
            N,
            un_plan.op_count,
            disp_un,
            per_un,
            mbps_un,
            fu_plan.op_count,
            disp_fu,
            per_fu,
            mbps_fu,
            un_plan.op_count,
            fu_plan.op_count,
            disp_un,
            disp_fu,
            disp_drop,
            speedup,
        },
    );
}

fn benchLongChain(io: std.Io) void {
    const g = comptime LongChain.build(N);
    const blocks = comptime &LongChain.blocks;
    const Unfused = engine.Executor(g, blocks);
    const Fused = engine.FusedExecutor(g, blocks);

    var input: [N]S = undefined;
    fillNoise(&input, 0xFA5E);
    var out_un: [N]S = undefined;
    var out_fu: [N]S = undefined;

    var unfused: Unfused = .{ .instances = LongChain.seed(&input, &out_un) };
    var fused = Fused.init(LongChain.seed(&input, &out_fu));

    const token = pan.enterRealtimeThread();
    defer token.leave();

    // Warm.
    unfused.render(token);
    fused.render(token);

    const iters = 200_000;
    const reps = 3;
    var ns_un: u64 = std.math.maxInt(u64);
    var ns_fu: u64 = std.math.maxInt(u64);
    var r: usize = 0;
    while (r < reps) : (r += 1) {
        var t = h.Timer.start(io);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            unfused.render(token);
            h.consume(out_un[N - 1].ch[0]);
        }
        ns_un = @min(ns_un, t.read());

        t.reset();
        i = 0;
        while (i < iters) : (i += 1) {
            fused.render(token);
            h.consume(out_fu[N - 1].ch[0]);
        }
        ns_fu = @min(ns_fu, t.read());
    }

    reportPair(
        "linear chain  Source→(Gain SoftClip Trim Gain SoftClip Trim Gain)→Sink",
        Unfused.committed.ops.len,
        &Unfused.committed,
        Fused.committed.ops.len,
        &Fused.committed,
        ns_un,
        ns_fu,
        iters,
    );
}

fn benchMultiReduce(io: std.Io) void {
    const g = comptime MultiReduce.build(N);
    const blocks = comptime &MultiReduce.blocks;
    const Unfused = engine.Executor(g, blocks);
    const Fused = engine.FusedExecutor(g, blocks);

    var input: [N]S = undefined;
    fillNoise(&input, 0x5A5A5A5A);
    var ua: [N]S = undefined;
    var ub: [N]S = undefined;
    var uc: [N]S = undefined;
    var fa: [N]S = undefined;
    var fb: [N]S = undefined;
    var fc: [N]S = undefined;

    var unfused: Unfused = .{ .instances = MultiReduce.seed(&input, &ua, &ub, &uc) };
    var fused = Fused.init(MultiReduce.seed(&input, &fa, &fb, &fc));

    const token = pan.enterRealtimeThread();
    defer token.leave();

    unfused.render(token);
    fused.render(token);

    const iters = 200_000;
    const reps = 3;
    var ns_un: u64 = std.math.maxInt(u64);
    var ns_fu: u64 = std.math.maxInt(u64);
    var r: usize = 0;
    while (r < reps) : (r += 1) {
        var t = h.Timer.start(io);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            unfused.render(token);
            h.consume(ua[N - 1].ch[0]);
            h.consume(ub[N - 1].ch[0]);
            h.consume(uc[N - 1].ch[0]);
        }
        ns_un = @min(ns_un, t.read());

        t.reset();
        i = 0;
        while (i < iters) : (i += 1) {
            fused.render(token);
            h.consume(fa[N - 1].ch[0]);
            h.consume(fb[N - 1].ch[0]);
            h.consume(fc[N - 1].ch[0]);
        }
        ns_fu = @min(ns_fu, t.read());
    }

    reportPair(
        "multi-reduction  Source→{A,B,C 3-Map reductions}→3 Sinks (fan-out NOT fused)",
        Unfused.committed.ops.len,
        &Unfused.committed,
        Fused.committed.ops.len,
        &Fused.committed,
        ns_un,
        ns_fu,
        iters,
    );
}

pub fn main() void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("=== automatic loop-fusion: byte-displacement + timing (fuse OFF vs ON) ===\n", .{});
    benchLongChain(io);
    benchMultiReduce(io);
}
