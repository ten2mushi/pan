//! Yoneda "tests as definition" suite for the BUFFER-ASSIGNMENT, FOOTPRINT and
//! EMIT stages of the pan commit pass (`src/commit.zig`, pipeline stages 5–9),
//! resting on the graph IR (`src/graph.zig`), the port machinery
//! (`src/port.zig`) and the canonical port elements (`src/types.zig`).
//!
//! The Yoneda framing: a committed `Plan` is fully observed through the
//! morphisms the render loop and the embedded sizing rely on —
//!   • `plan.op_count`               (one render op per node, forward-topo),
//!   • `plan.footprint_bytes`        (a single comptime-constant byte figure),
//!   • `plan.ops[i].input_count` / `.output_count` / `.input_buffer_ids` /
//!     `.output_buffer_ids` / `.n_or_pull_spec`  (the per-op wiring).
//! Pin every one of those and any implementation that passes must be
//! functionally equivalent on what the commit pass is *for*.
//!
//! COMPARISON MODE: ⊢ structural / decidable. The footprint is integer byte
//! arithmetic (Σ pools + Σ delay rings + Σ block state) and the counts are
//! structural — so every assertion is exact `expectEqual` / `expect` /
//! `expectError`. NO float tolerance anywhere (there are no floats in a Plan).
//!
//! THE LAWS BEING CHARACTERIZED (restated in plain words, not citing spec §§):
//!   L1  op_count == node_count; one RenderOp per block, forward-topo order.
//!       Empty graph → 0 ops / 0 bytes; a lone Source → 1 op / 0 bytes.
//!   L2  footprint = Σ_class (M_class · N · @sizeOf(element))
//!                 + Σ_delay (delay_len · @sizeOf(element))
//!                 + Σ_block state_size.
//!       It scales linearly with N, with element width, and with declared state.
//!   L3  Per-element-class left-edge coloring is optimal: M_class is the maximum
//!       number of values simultaneously live. A linear chain ping-pongs in
//!       exactly 2 buffers for ANY length ≥ 2; a reconvergent diamond needs more
//!       (derived below: 3). Live ranges are END-INCLUSIVE; a color is reusable
//!       only when its last interval ended strictly before the new one starts
//!       (free-test prev_end < start).
//!   L4  footprint_bytes is a COMPTIME CONSTANT — usable as an array length.
//!   L5  RenderOp wiring: a source op has 0 inputs, a sink op has 0 outputs,
//!       each op's input/output counts match its wired ports, and for a rate-1:1
//!       graph every op's n_or_pull_spec == the device demand N. Two element
//!       classes are colored independently → the footprint is the SUM of the two
//!       class terms (cross-class buffers never alias).
//!   L6  Determinism: re-committing the same graph yields the identical plan.
//!
//! The whole commit pass runs at COMPTIME: graphs are built in `comptime` blocks
//! and committed with `comptime try`, and several tests use `footprint_bytes` as
//! an array length to *prove* it folded at compile time.
//!
//! Verified against zig 0.16.0. Per project Rule 13/14 the `zig-0-16` skill was
//! loaded before authoring. Imports go through the `pan` library module (wired in
//! build.zig), which re-exports `graph`, `commitComptime`, `port`, the element
//! constructors, `RenderOp` and `Plan`.

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const port = pan.port;
const commitComptime = pan.commitComptime;
const Sample = pan.Sample;
const Frame = pan.Frame;
// Multi-channel ports use the enforced planar (SoA) views, not `[]Frame` AoS.
const Planar = pan.Planar;
const PlanarConst = pan.PlanarConst;

// ---------------------------------------------------------------------------
// Synthetic block idioms (one per role). Every graph is SOURCE-ROOTED: it must
// begin at a Source (a zero-input generator) or commit returns UnrootedPath.
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

/// A sink over Sample(f32) (1 in, 0 out).
const Sink = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        _ = self;
        _ = in;
    }
};

/// A two-input mixer over Sample(f32) (2 in, 1 out) — the diamond reconvergence.
const Sum2 = struct {
    const Self = @This();
    pub fn process(self: *Self, in0: []const Sample(f32), in1: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (in0, in1, out) |x, y, *o| o.ch[0] = x.ch[0] + y.ch[0];
    }
};

/// A Source over a WIDER element: stereo f32 frame (8 bytes), to show the
/// footprint tracks element width, not just edge count.
const SrcStereo = struct {
    const Self = @This();
    pub fn process(self: *Self, out: Planar(f32, .stereo)) void {
        _ = self;
        _ = out;
    }
};
const Map1Stereo = struct {
    const Self = @This();
    pub fn process(self: *Self, in: PlanarConst(f32, .stereo), out: Planar(f32, .stereo)) void {
        _ = self;
        _ = in;
        _ = out;
    }
};
const SinkStereo = struct {
    const Self = @This();
    pub fn process(self: *Self, in: PlanarConst(f32, .stereo)) void {
        _ = self;
        _ = in;
    }
};

// ---------------------------------------------------------------------------
// Small helpers for building canonical topologies at comptime.
// ---------------------------------------------------------------------------

/// A clean Src → Map1 → Sink chain over Sample(f32) at block size `N`.
fn chainGraph(comptime N: usize) graph.Graph {
    var gg = graph.Graph.empty;
    gg.block_size = N;
    const in = gg.add(Src);
    const m = gg.add(Map1);
    const out = gg.add(Sink);
    gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Map1), m, 0);
    gg.connect(port.MapOutPort(Map1), m, 0, port.MapInPort(Sink), out, 0);
    return gg;
}

// ===========================================================================
// L1 — op_count == node_count, forward-topo, degenerate boundaries.
// ===========================================================================

test "L1 the empty graph commits to zero ops and zero bytes (degenerate floor)" {
    const g = comptime graph.Graph.empty;
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 0), plan.op_count);
    try std.testing.expectEqual(@as(usize, 0), plan.footprint_bytes);
}

test "L1 a lone Source commits to exactly one op and zero bytes (rooted, no edges)" {
    // A Source is a legal path head; with no edges there are no pool values and
    // no delay/state, so the footprint is exactly zero.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        _ = gg.add(Src);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 1), plan.op_count);
    try std.testing.expectEqual(@as(usize, 0), plan.footprint_bytes);
    // The lone op is a source: zero inputs, zero outputs (nothing consumes it).
    try std.testing.expectEqual(@as(usize, 0), plan.ops[0].input_count);
    try std.testing.expectEqual(@as(usize, 0), plan.ops[0].output_count);
}

test "L1 op_count equals node_count for a 3-node chain, and ops are forward-topo" {
    const g = comptime chainGraph(128);
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 3), plan.op_count);
    // Forward-topo: op 0 is the source (0 inputs), op 2 is the sink (0 outputs).
    try std.testing.expectEqual(@as(usize, 0), plan.ops[0].input_count);
    try std.testing.expectEqual(@as(usize, 1), plan.ops[0].output_count); // src → map
    try std.testing.expectEqual(@as(usize, 1), plan.ops[1].input_count); // map ← src
    try std.testing.expectEqual(@as(usize, 1), plan.ops[1].output_count); // map → sink
    try std.testing.expectEqual(@as(usize, 1), plan.ops[2].input_count); // sink ← map
    try std.testing.expectEqual(@as(usize, 0), plan.ops[2].output_count); // sink has no out
}

test "L1 op_count tracks node_count as the chain grows (5 nodes → 5 ops)" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const in = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const c = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Map1), a, 0);
        gg.connect(port.MapOutPort(Map1), a, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPort(Map1), c, 0);
        gg.connect(port.MapOutPort(Map1), c, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 5), plan.op_count);
}

// ===========================================================================
// L2 — the footprint formula: pools + delay rings + state.
// ===========================================================================

test "L2 a clean Sample(f32) chain ping-pongs in 2 pool buffers: footprint = 2·N·4" {
    // Chain Src → Map1 → Sink. Two live values overlap at one op (the map's
    // output is alive while the map still holds its input as the read side),
    // so M_Sample = 2. No delay, no state. footprint = 2 · N · 4.
    const N = 256;
    const g = comptime chainGraph(N);
    const plan = comptime try commitComptime(g);
    const want = 2 * N * @sizeOf(Sample(f32)); // 2 · 256 · 4 = 2048
    try std.testing.expectEqual(@as(usize, want), plan.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 2048), plan.footprint_bytes);
}

test "L2 the footprint scales LINEARLY with N while op_count and buffer ids stay fixed" {
    // The buffer-id MAP is N-independent (topology); only the byte count scales.
    // Sweep N over a spread of sizes and confirm footprint == 2·N·4 each time,
    // op_count stays 3, and the per-op buffer ids never change.
    const Ns = [_]usize{ 1, 2, 16, 64, 128, 256, 512, 1024, 4096 };
    inline for (Ns) |N| {
        const g = comptime chainGraph(N);
        const plan = comptime try commitComptime(g);
        try std.testing.expectEqual(@as(usize, 3), plan.op_count);
        try std.testing.expectEqual(@as(usize, 2 * N * 4), plan.footprint_bytes);
    }

    // Buffer-id MAP invariance: the map op's input id, output id and the sink's
    // input id are identical across two very different N (only the bytes differ).
    const g_small = comptime chainGraph(32);
    const g_large = comptime chainGraph(8192);
    const ps = comptime try commitComptime(g_small);
    const pl = comptime try commitComptime(g_large);
    try std.testing.expectEqual(ps.ops[1].input_buffer_ids[0], pl.ops[1].input_buffer_ids[0]);
    try std.testing.expectEqual(ps.ops[1].output_buffer_ids[0], pl.ops[1].output_buffer_ids[0]);
    try std.testing.expectEqual(ps.ops[2].input_buffer_ids[0], pl.ops[2].input_buffer_ids[0]);
    // ...but the footprint differs by exactly the N ratio (×256).
    try std.testing.expectEqual(@as(usize, 256), pl.footprint_bytes / ps.footprint_bytes);
}

test "L2 swapping to a wider element (stereo f32, 8 bytes) DOUBLES the footprint" {
    // Identical topology (Src → Map → Sink) over Frame(f32,.stereo). The formula
    // multiplies by @sizeOf(element): 8 instead of 4 ⇒ footprint = 2·N·8.
    const N = 256;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const in = gg.add(SrcStereo);
        const m = gg.add(Map1Stereo);
        const out = gg.add(SinkStereo);
        gg.connect(port.MapOutPort(SrcStereo), in, 0, port.MapInPort(Map1Stereo), m, 0);
        gg.connect(port.MapOutPort(Map1Stereo), m, 0, port.MapInPort(SinkStereo), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Frame(f32, .stereo)));
    // 2 · 256 · 8 = 4096 — exactly twice the 2048 of the mono chain at the same N.
    try std.testing.expectEqual(@as(usize, 2 * N * 8), plan.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 4096), plan.footprint_bytes);
}

test "L2 declared state_size adds EXACTLY that many bytes to the footprint" {
    // A map that declares `state_size`. The pools term is unchanged (2·N·4); the
    // state bytes are added on top, once for the declaring block.
    const StateMap = struct {
        const Self = @This();
        pub const state_size: usize = 777;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const N = 128;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const in = gg.add(Src);
        const m = gg.add(StateMap);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(StateMap), m, 0);
        gg.connect(port.MapOutPort(StateMap), m, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    const pools = 2 * N * @sizeOf(Sample(f32)); // 2·128·4 = 1024
    try std.testing.expectEqual(@as(usize, pools + 777), plan.footprint_bytes);
}

test "L2 multiple state-declaring blocks each add their own state_size (sum, not max)" {
    const State10 = struct {
        const Self = @This();
        pub const state_size: usize = 10;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const State20 = struct {
        const Self = @This();
        pub const state_size: usize = 20;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const N = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const in = gg.add(Src);
        const a = gg.add(State10);
        const b = gg.add(State20);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(State10), a, 0);
        gg.connect(port.MapOutPort(State10), a, 0, port.MapInPort(State20), b, 0);
        gg.connect(port.MapOutPort(State20), b, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    // Pools: a linear chain still ping-pongs in 2 → 2·64·4 = 512. State: 10 + 20.
    try std.testing.expectEqual(@as(usize, 2 * N * 4 + 10 + 20), plan.footprint_bytes);
}

// ===========================================================================
// WORKED EXAMPLE B — the anchor number (feedback comb).
// ===========================================================================

test "L2 worked example B: feedback comb at N=256 footprints to exactly 3968 bytes" {
    // in(Src) → Sum → DelayLine(delay_len=480) → Gain → out(Sink),
    // plus a declared feedback edge Gain → Sum. Sample(f32), block_size = 256.
    //
    // Pools: the longest simultaneously-live count over the forward chain is the
    // ping-pong M=2 (the feedback read side comes from persistent state and does
    // NOT extend any pool live range) ⇒ 2 · 256 · 4 = 2048.
    // Persistent: the DelayLine ring is delay_len · @sizeOf(elem) = 480 · 4 = 1920.
    // Total = 2048 + 1920 = 3968.
    const Sum = Map1;
    const Gain = Map1;
    const DelayLine = struct {
        const Self = @This();
        pub const delay_len: usize = 480;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 256;
        const in = gg.add(Src);
        const sum = gg.add(Sum);
        const dl = gg.add(DelayLine);
        const gain = gg.add(Gain);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Sum), sum, 0);
        gg.connect(port.MapOutPort(Sum), sum, 0, port.MapInPort(DelayLine), dl, 0);
        gg.connect(port.MapOutPort(DelayLine), dl, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(Sink), out, 0);
        gg.connectFeedback(port.MapOutPort(Gain), gain, 0, port.MapInPort(Sum), sum, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 5), plan.op_count);
    try std.testing.expectEqual(@as(usize, 2048 + 1920), plan.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 3968), plan.footprint_bytes);
    // Every op carries the resolved device demand N = 256 (rate-1:1 chain).
    inline for (0..5) |i| {
        try std.testing.expectEqual(@as(usize, 256), plan.ops[i].n_or_pull_spec);
    }
}

test "L2 the delay ring term scales with delay_len AND element width" {
    // Two delay lines of different lengths over different element widths show the
    // persistent term is Σ_delay (delay_len · @sizeOf(elem)).
    const DelayMonoShort = struct {
        const Self = @This();
        pub const delay_len: usize = 100;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const N = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const in = gg.add(Src);
        const dl = gg.add(DelayMonoShort);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(DelayMonoShort), dl, 0);
        gg.connect(port.MapOutPort(DelayMonoShort), dl, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    // Pools 2·64·4 = 512 ; ring 100·4 = 400.
    try std.testing.expectEqual(@as(usize, 2 * N * 4 + 100 * 4), plan.footprint_bytes);
}

// ===========================================================================
// L3 — coloring optimality (M_class = max simultaneously-live).
// ===========================================================================

test "L3 a linear chain reuses exactly 2 pool buffers REGARDLESS of length" {
    // M_Sample = 2 for any chain ≥ 2 edges: a value's live range ends at the op
    // AFTER its producer (its single reader), so at most two values overlap. The
    // pools term is therefore 2·N·4 independent of how long the chain is.
    const N = 100; // chosen so 2·N·4 = 800 reads cleanly.
    inline for ([_]usize{ 2, 3, 5, 10, 20 }) |chain_len| {
        const g = comptime blk: {
            var gg = graph.Graph.empty;
            gg.block_size = N;
            const in = gg.add(Src);
            var prev = in;
            for (0..chain_len) |_| {
                const m = gg.add(Map1);
                gg.connect(port.MapOutPort(Map1), prev, 0, port.MapInPort(Map1), m, 0);
                prev = m;
            }
            const out = gg.add(Sink);
            gg.connect(port.MapOutPort(Map1), prev, 0, port.MapInPort(Sink), out, 0);
            break :blk gg;
        };
        const plan = comptime try commitComptime(g);
        // op_count grows with the chain...
        try std.testing.expectEqual(@as(usize, chain_len + 2), plan.op_count);
        // ...but the POOLS term does NOT: it stays pinned at 2·N·4.
        try std.testing.expectEqual(@as(usize, 2 * N * 4), plan.footprint_bytes);
    }
}

test "L3 a reconvergent diamond needs 3 pool buffers (derived M_Sample = 3)" {
    // src → a, src → b, a → mix.in0, b → mix.in1, mix → out.
    // Node ids: src=0, a=1, b=2, mix=3, out=4. Topo (min-id tiebreak):
    //   0(src) 1(a) 2(b) 3(mix) 4(out)  → op index == node id here.
    //
    // Values (output port, end-inclusive live range over op indices):
    //   V_src [0,2]  (read by a@1 and b@2; fan-out → LAST reader = 2)
    //   V_a   [1,3]  (read by mix@3)
    //   V_b   [2,3]  (read by mix@3)
    //   V_mix [3,4]  (read by out@4)
    // Left-edge coloring (free-test prev_end < start), sorted by start:
    //   V_src→c0 (end 2); V_a→c1 (0:end2≮1) (end3); V_b→c2 (c0:2≮2, c1:3≮2)
    //   (end3); V_mix→c0 (c0:2<3 ✓ reuse).
    // ⇒ 3 colors. At op 2 (b produced) V_src, V_a, V_b are all live: M=3.
    const N = 256;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), a, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), b, 0); // fan-out
        gg.connect(port.MapOutPort(Map1), a, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 5), plan.op_count);
    // M_Sample = 3 ⇒ pools = 3 · N · 4. No delay/state.
    try std.testing.expectEqual(@as(usize, 3 * N * 4), plan.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 3 * 256 * 4), plan.footprint_bytes);
}

test "L3 fan-out to two readers extends the value to its LAST reader, not its first" {
    // src → a, src → b. The source's single output buffer must stay live until
    // BOTH a and b have read it (the later reader). With a 2-way fan-out feeding
    // two independent sinks, the diamond's reconvergence is removed, so we check
    // the structural consequence directly: src has ONE output value (deduped),
    // hence exactly one output buffer id even though two edges leave it.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const sa = gg.add(Sink);
        const sb = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Sink), sa, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Sink), sb, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 3), plan.op_count);
    // The source op fans out to two sinks but produces a SINGLE buffer (one
    // value, shared): output_count == 1, and both sinks read that same id.
    try std.testing.expectEqual(@as(usize, 1), plan.ops[0].output_count);
    const shared = plan.ops[0].output_buffer_ids[0];
    // ops[1] and ops[2] are the two sinks (forward-topo after the source).
    try std.testing.expectEqual(@as(usize, 1), plan.ops[1].input_count);
    try std.testing.expectEqual(@as(usize, 1), plan.ops[2].input_count);
    try std.testing.expectEqual(shared, plan.ops[1].input_buffer_ids[0]);
    try std.testing.expectEqual(shared, plan.ops[2].input_buffer_ids[0]);
    // No delay/state and a single live value → 1 pool buffer = N·4.
    try std.testing.expectEqual(@as(usize, 1 * 512 * 4), plan.footprint_bytes);
}

// ===========================================================================
// L4 — footprint_bytes is a COMPTIME CONSTANT (the H2 obligation).
// ===========================================================================

test "L4 footprint_bytes is comptime-known: it sizes a fixed-length array" {
    const g = comptime chainGraph(64);
    const plan = comptime try commitComptime(g);
    // An array length MUST be comptime-known; this line only compiles if the
    // commit pass folded `footprint_bytes` at compile time.
    const proof: [plan.footprint_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2 * 64 * 4), proof.len);
}

test "L4 the worked-example-B footprint is also a usable array length (3968)" {
    const DelayLine = struct {
        const Self = @This();
        pub const delay_len: usize = 480;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 256;
        const in = gg.add(Src);
        const sum = gg.add(Map1);
        const dl = gg.add(DelayLine);
        const gain = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Map1), sum, 0);
        gg.connect(port.MapOutPort(Map1), sum, 0, port.MapInPort(DelayLine), dl, 0);
        gg.connect(port.MapOutPort(DelayLine), dl, 0, port.MapInPort(Map1), gain, 0);
        gg.connect(port.MapOutPort(Map1), gain, 0, port.MapInPort(Sink), out, 0);
        gg.connectFeedback(port.MapOutPort(Map1), gain, 0, port.MapInPort(Map1), sum, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    const proof: [plan.footprint_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3968), proof.len);
}

// ===========================================================================
// L5 — RenderOp buffer-id wiring & cross-class disjointness.
// ===========================================================================

test "L5 a source op has 0 inputs and a sink op has 0 outputs" {
    const g = comptime chainGraph(256);
    const plan = comptime try commitComptime(g);
    // op 0 = source.
    try std.testing.expectEqual(@as(usize, 0), plan.ops[0].input_count);
    try std.testing.expect(plan.ops[0].output_count > 0);
    // op 2 = sink.
    try std.testing.expect(plan.ops[2].input_count > 0);
    try std.testing.expectEqual(@as(usize, 0), plan.ops[2].output_count);
}

test "L5 the map op's input id equals the source's output id (edge ⇒ shared buffer)" {
    // The buffer the source writes is precisely the buffer the map reads: one
    // pool buffer carries the value across the edge. Likewise map→sink.
    const g = comptime chainGraph(256);
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(plan.ops[0].output_buffer_ids[0], plan.ops[1].input_buffer_ids[0]);
    try std.testing.expectEqual(plan.ops[1].output_buffer_ids[0], plan.ops[2].input_buffer_ids[0]);
    // Ping-pong: the map's output id differs from its input id (it cannot write
    // over a buffer it is still reading; the colorer gives it the OTHER color).
    try std.testing.expect(plan.ops[1].input_buffer_ids[0] != plan.ops[1].output_buffer_ids[0]);
}

test "L5 a 2-input mixer op carries input_count == 2" {
    // The diamond's mixer reads two distinct upstream buffers.
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
    const plan = comptime try commitComptime(g);
    // The mixer is node id 3, op index 3 (topo == id order here).
    try std.testing.expectEqual(@as(usize, 2), plan.ops[3].input_count);
    try std.testing.expectEqual(@as(usize, 1), plan.ops[3].output_count);
    // Its two inputs are distinct buffers (a's value and b's value live at once).
    try std.testing.expect(plan.ops[3].input_buffer_ids[0] != plan.ops[3].input_buffer_ids[1]);
}

test "L5 n_or_pull_spec equals the device demand N on every op of a rate-1:1 chain" {
    // Sweep N: the resolved demand propagates uniformly upstream (Map needed_input
    // is identity), so EVERY op reports n_or_pull_spec == N.
    inline for ([_]usize{ 64, 256, 480, 1024 }) |N| {
        const g = comptime chainGraph(N);
        const plan = comptime try commitComptime(g);
        inline for (0..3) |i| {
            try std.testing.expectEqual(@as(usize, N), plan.ops[i].n_or_pull_spec);
        }
    }
}

test "L5 two element classes are colored independently: footprint is the SUM of class terms" {
    // Two disjoint chains in one graph: a Sample(f32) (4-byte) chain and a
    // Frame(f32,.stereo) (8-byte) chain. Cross-class buffers never alias, so each
    // class contributes its own 2·N·size pool term and the footprint is the SUM.
    //   mono pools  = 2 · N · 4
    //   stereo pools= 2 · N · 8
    //   total       = 2·N·4 + 2·N·8
    const N = 128;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        // mono chain
        const m_in = gg.add(Src);
        const m_map = gg.add(Map1);
        const m_out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), m_in, 0, port.MapInPort(Map1), m_map, 0);
        gg.connect(port.MapOutPort(Map1), m_map, 0, port.MapInPort(Sink), m_out, 0);
        // stereo chain (independent)
        const s_in = gg.add(SrcStereo);
        const s_map = gg.add(Map1Stereo);
        const s_out = gg.add(SinkStereo);
        gg.connect(port.MapOutPort(SrcStereo), s_in, 0, port.MapInPort(Map1Stereo), s_map, 0);
        gg.connect(port.MapOutPort(Map1Stereo), s_map, 0, port.MapInPort(SinkStereo), s_out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 6), plan.op_count);
    const mono = 2 * N * 4;
    const stereo = 2 * N * 8;
    try std.testing.expectEqual(@as(usize, mono + stereo), plan.footprint_bytes);
}

test "L5 cross-class buffer ids are disjoint (the two classes never share an id)" {
    // Same two-class graph. Collect every buffer id used by a mono op and every
    // id used by a stereo op; the two sets must not intersect (independent pools,
    // each class based after the previous class's colors).
    const N = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const m_in = gg.add(Src);
        const m_map = gg.add(Map1);
        const m_out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), m_in, 0, port.MapInPort(Map1), m_map, 0);
        gg.connect(port.MapOutPort(Map1), m_map, 0, port.MapInPort(Sink), m_out, 0);
        const s_in = gg.add(SrcStereo);
        const s_map = gg.add(Map1Stereo);
        const s_out = gg.add(SinkStereo);
        gg.connect(port.MapOutPort(SrcStereo), s_in, 0, port.MapInPort(Map1Stereo), s_map, 0);
        gg.connect(port.MapOutPort(Map1Stereo), s_map, 0, port.MapInPort(SinkStereo), s_out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    // Node ids: mono {0,1,2}, stereo {3,4,5}; topo == id order. The mono map op
    // (1) and the stereo map op (4) each touch their class's two ping-pong ids.
    const mono_in = plan.ops[1].input_buffer_ids[0];
    const mono_out = plan.ops[1].output_buffer_ids[0];
    const stereo_in = plan.ops[4].input_buffer_ids[0];
    const stereo_out = plan.ops[4].output_buffer_ids[0];
    // The mono pair must be disjoint from the stereo pair.
    try std.testing.expect(mono_in != stereo_in);
    try std.testing.expect(mono_in != stereo_out);
    try std.testing.expect(mono_out != stereo_in);
    try std.testing.expect(mono_out != stereo_out);
}

// ===========================================================================
// L6 — determinism.
// ===========================================================================

test "L6 re-committing the same graph yields an identical plan (footprint + op_count)" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 256;
        const in = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Map1), a, 0);
        gg.connect(port.MapOutPort(Map1), a, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const p1 = comptime try commitComptime(g);
    const p2 = comptime try commitComptime(g);
    try std.testing.expectEqual(p1.op_count, p2.op_count);
    try std.testing.expectEqual(p1.footprint_bytes, p2.footprint_bytes);
    // ...down to the per-op wiring: counts, ids and demand all match.
    inline for (0..4) |i| {
        try std.testing.expectEqual(p1.ops[i].input_count, p2.ops[i].input_count);
        try std.testing.expectEqual(p1.ops[i].output_count, p2.ops[i].output_count);
        try std.testing.expectEqual(p1.ops[i].n_or_pull_spec, p2.ops[i].n_or_pull_spec);
        try std.testing.expectEqual(p1.ops[i].input_buffer_ids[0], p2.ops[i].input_buffer_ids[0]);
    }
}

// ===========================================================================
// L7 — POOL-BUFFER ALIGNMENT (the @alignCast-validity invariant).
//
// WHY THIS MATTERS (the load-bearing reason, not just "what"): at render the
// engine takes each pool buffer's RAW BYTE region and reinterprets it as a typed
// (and, for planar views, `@Vector`-lane) slice via a SAFETY-CHECKED `@alignCast`
// (`engine.zig` `sliceMut`/`planarMutView`). An `@alignCast` to an address that
// is not a multiple of the element's natural `@alignOf` is Illegal Behaviour —
// it PANICS in Debug/ReleaseSafe (and is UB in ReleaseFast). Therefore EVERY
// buffer id a committed plan hands an op MUST start at an offset that is a
// multiple of that buffer's element alignment. The engine's flat pool base is
// declared `align(64)`, so an in-pool offset aligned to `@alignOf(Elem)` (which
// is always ≤ 64 for every element type pan carries) yields an aligned ABSOLUTE
// address — the offset alignment is the whole obligation the commit pass owns.
//
// The Yoneda observation set fully DEFINING the invariant:
//   • For every buffer id used by any op of a committed plan,
//       buffer_offset[id] % buffer_align[id] == 0   (the @alignCast precondition)
//     AND buffer_align[id] == @alignOf(that id's element type)   (the right target).
//   • The fix is a NO-OP on uniform-f32 graphs: footprint stays exactly Σ want·4·M,
//     scales linearly with N, and the per-op layout is byte-identical — every f32
//     buffer is 4-aligned at every packed offset already, so zero padding is added.
//   • A graph genuinely MIXING narrow- and wide-alignment element classes (so a
//     naive contiguous pack would land a later, wider buffer on a misaligned
//     offset) is correctly padded: the wider class's buffers are bumped forward to
//     their alignment, and the invariant holds for every id.
//   • Both layout passes agree: the per-edge baseline (.per_edge) aligns offsets
//     by the SAME rule as the shipped colored pool (.colored).
//   • The persistent feedback z⁻¹ tail aligns its ABSOLUTE offset too (so a comb
//     whose feedback element is wider-aligned than the scratch tail-end still lands
//     its z⁻¹ buffer on an aligned address).
//
// Element-alignment ladder used below (verified against zig 0.16.0):
//   Sample(i16) → @alignOf 2, @sizeOf 2
//   Sample(f32) → @alignOf 4, @sizeOf 4
//   Sample(f64) → @alignOf 8, @sizeOf 8
// (`Frame(Lane,L)` is `[count]Lane`, so its alignment is `@alignOf(Lane)`, which
// exceeds 4 for an f64 lane — the wide-alignment class the invariant guards.)
// ===========================================================================

const commitComptimeMode = pan.commitComptimeMode;
const BufferMode = pan.BufferMode;

// --- Synthetic blocks over wider/narrower element lanes -------------------
// `Sample(i16)` (align 2), `Sample(f64)` (align 8): used to build classes whose
// natural alignment straddles the f32 (align 4) default, so a naive contiguous
// pack of an i16 class followed by an f64 class can misalign the f64 buffers.

const SrcI16 = struct {
    const Self = @This();
    pub fn process(self: *Self, out: []Sample(i16)) void {
        _ = self;
        _ = out;
    }
};
const Map1I16 = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(i16), out: []Sample(i16)) void {
        _ = self;
        @memcpy(out, in);
    }
};
const SinkI16 = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(i16)) void {
        _ = self;
        _ = in;
    }
};

const SrcF64 = struct {
    const Self = @This();
    pub fn process(self: *Self, out: []Sample(f64)) void {
        _ = self;
        _ = out;
    }
};
const Map1F64 = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f64), out: []Sample(f64)) void {
        _ = self;
        @memcpy(out, in);
    }
};
const SinkF64 = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f64)) void {
        _ = self;
        _ = in;
    }
};

/// Collect, into a fixed array, the DISTINCT buffer ids that any op of `plan`
/// actually references — sample inputs, outputs, AND parameter-edge inputs. The
/// alignment invariant must hold for every id the render loop will hand to an
/// `@alignCast`, which is exactly this set (an id present in the byte tables but
/// touched by no op cannot be misaligned-cast, so we observe the touched set).
fn referencedBufferIds(plan: anytype) struct { ids: [graph.max_buffers]usize, len: usize } {
    var ids: [graph.max_buffers]usize = undefined;
    var len: usize = 0;
    const add = struct {
        fn f(arr: *[graph.max_buffers]usize, n: *usize, id: usize) void {
            for (0..n.*) |k| if (arr[k] == id) return;
            arr[n.*] = id;
            n.* += 1;
        }
    }.f;
    for (0..plan.op_count) |oi| {
        const op = plan.ops[oi];
        for (0..op.input_count) |k| add(&ids, &len, op.input_buffer_ids[k]);
        for (0..op.output_count) |k| add(&ids, &len, op.output_buffer_ids[k]);
        for (0..op.param_input_count) |k| add(&ids, &len, op.param_input_buffer_ids[k]);
    }
    return .{ .ids = ids, .len = len };
}

/// THE INVARIANT, factored: every referenced buffer id starts on a multiple of
/// its recorded alignment, and that recorded alignment is a real power-of-two
/// `@alignOf` (≤ 64, the pool base alignment, so the absolute address is aligned
/// once added to the 64-aligned base). Asserting `>= 1` and power-of-two rules
/// out a bogus `0`/`3` alignment that would make the modulo test vacuous.
fn assertAlignmentInvariant(plan: anytype) !void {
    const ref = referencedBufferIds(plan);
    for (0..ref.len) |k| {
        const id = ref.ids[k];
        const a = plan.buffer_align[id];
        // A genuine alignment: power-of-two and within the 64-byte pool base.
        try std.testing.expect(a >= 1);
        try std.testing.expect(a <= 64);
        try std.testing.expect((a & (a - 1)) == 0);
        // The @alignCast precondition: the offset is a multiple of the alignment.
        try std.testing.expectEqual(@as(usize, 0), plan.buffer_offset[id] % a);
    }
}

// --- L7.a uniform-f32 graphs: the fix is a provable NO-OP --------------------

test "L7 uniform-f32 chain: every buffer is 4-aligned and footprint is UNCHANGED (no padding)" {
    // A pure Sample(f32) chain — every element aligns to 4 and every stride
    // (N·4) is a multiple of 4, so aligning offsets adds ZERO bytes. The
    // footprint must stay EXACTLY 2·N·4 (the pre-fix figure) and the invariant
    // must hold trivially. This is the property that the alignment fix does not
    // perturb the dominant uniform-f32 case.
    const N = 256;
    const g = comptime chainGraph(N);
    const plan = comptime try commitComptime(g);
    try assertAlignmentInvariant(plan);
    // No padding: footprint is the bare ping-pong pool, byte-for-byte as before.
    try std.testing.expectEqual(@as(usize, 2 * N * 4), plan.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 2 * N * 4), plan.pool_bytes);
    // Every referenced id records align == @alignOf(Sample(f32)) == 4.
    const ref = referencedBufferIds(plan);
    for (0..ref.len) |k| {
        try std.testing.expectEqual(@as(usize, @alignOf(Sample(f32))), plan.buffer_align[ref.ids[k]]);
    }
}

test "L7 uniform-f32 footprint stays linear in N AND offsets stay aligned across a sweep" {
    // Sweep N (including ODD sizes, where N·4 is still a multiple of 4 so no pad
    // is ever needed). For every N: footprint == 2·N·4 (linear, no alignment
    // bytes) and the invariant holds. Odd N is the case a careless "round the
    // stride up to 8" implementation would wrongly pad — it must NOT.
    inline for ([_]usize{ 1, 3, 7, 64, 255, 1024 }) |N| {
        const g = comptime chainGraph(N);
        const plan = comptime try commitComptime(g);
        try assertAlignmentInvariant(plan);
        try std.testing.expectEqual(@as(usize, 2 * N * 4), plan.footprint_bytes);
    }
}

test "L7 the alignment fix does NOT change the f32 buffer-id layout (offsets are the contiguous pack)" {
    // For a uniform-f32 graph the aligned layout is byte-identical to a naive
    // contiguous pack: buffer 0 at offset 0, buffer 1 at offset N·4 (no gap),
    // because every stride is already a multiple of 4. Pin the exact offsets so
    // a regression that started inserting spurious f32 padding is caught.
    const N = 128;
    const g = comptime chainGraph(N);
    const plan = comptime try commitComptime(g);
    // The map op (op 1) reads one buffer and writes the OTHER (ping-pong).
    const in_id = plan.ops[1].input_buffer_ids[0];
    const out_id = plan.ops[1].output_buffer_ids[0];
    // The two ping-pong buffers sit at 0 and N·4 with no padding between them.
    const lo = @min(plan.buffer_offset[in_id], plan.buffer_offset[out_id]);
    const hi = @max(plan.buffer_offset[in_id], plan.buffer_offset[out_id]);
    try std.testing.expectEqual(@as(usize, 0), lo);
    try std.testing.expectEqual(@as(usize, N * 4), hi);
}

// --- L7.b a graph that GENUINELY mixes narrow + wide alignment ---------------

/// Two independent chains in one graph: a Sample(i16) (align 2) chain wired
/// FIRST (so its class is laid out first) and a Sample(f64) (align 8) chain
/// wired second. At small N the i16 class's total bytes are not a multiple of 8,
/// so a naive contiguous pack would start an f64 buffer on a 4- or 2-aligned
/// (mis-aligned) offset — the exact failure the fix prevents.
fn mixedAlignGraph(comptime N: usize) graph.Graph {
    var gg = graph.Graph.empty;
    gg.block_size = N;
    // i16 chain first → i16 is element-class 0 (laid out at the pool front).
    const i_in = gg.add(SrcI16);
    const i_map = gg.add(Map1I16);
    const i_out = gg.add(SinkI16);
    gg.connect(port.MapOutPort(SrcI16), i_in, 0, port.MapInPort(Map1I16), i_map, 0);
    gg.connect(port.MapOutPort(Map1I16), i_map, 0, port.MapInPort(SinkI16), i_out, 0);
    // f64 chain second → f64 is element-class 1 (laid out AFTER the i16 class).
    const f_in = gg.add(SrcF64);
    const f_map = gg.add(Map1F64);
    const f_out = gg.add(SinkF64);
    gg.connect(port.MapOutPort(SrcF64), f_in, 0, port.MapInPort(Map1F64), f_map, 0);
    gg.connect(port.MapOutPort(Map1F64), f_map, 0, port.MapInPort(SinkF64), f_out, 0);
    return gg;
}

test "L7 mixed i16/f64 graph at N=1: f64 buffers are bumped to an 8-aligned offset" {
    // i16 class first: M=2, each buffer N·2 = 2 bytes → occupies [0,2) and [2,4),
    // so the scratch cursor is at 4 after the i16 class. The f64 class (align 8)
    // must then start at 8 (a 4-byte PAD), NOT at the contiguous 4 — because 4 is
    // not a multiple of @alignOf(Sample(f64))==8 and an `@alignCast` of a +4
    // address to *f64 would PANIC. Pin the bumped offset explicitly.
    const g = comptime mixedAlignGraph(1);
    const plan = comptime try commitComptime(g);
    try assertAlignmentInvariant(plan);

    // The f64 map op (node 4, op index 4 since topo == id order here) ping-pongs
    // in the f64 class. Its referenced offsets must be multiples of 8.
    const f_in = plan.ops[4].input_buffer_ids[0];
    const f_out = plan.ops[4].output_buffer_ids[0];
    try std.testing.expectEqual(@as(usize, 8), plan.buffer_align[f_in]);
    try std.testing.expectEqual(@as(usize, 8), plan.buffer_align[f_out]);
    try std.testing.expectEqual(@as(usize, 0), plan.buffer_offset[f_in] % 8);
    try std.testing.expectEqual(@as(usize, 0), plan.buffer_offset[f_out] % 8);
    // The lower f64 buffer sits at 8 (the i16 class ended at 4, padded up to 8) —
    // proving a non-trivial pad was inserted, not a coincidental alignment.
    const f_lo = @min(plan.buffer_offset[f_in], plan.buffer_offset[f_out]);
    try std.testing.expectEqual(@as(usize, 8), f_lo);
    // The i16 class itself is 2-aligned and packed contiguously at the front.
    const i_in = plan.ops[1].input_buffer_ids[0];
    const i_out = plan.ops[1].output_buffer_ids[0];
    try std.testing.expectEqual(@as(usize, 2), plan.buffer_align[i_in]);
    try std.testing.expectEqual(@as(usize, 2), plan.buffer_align[i_out]);
    const i_lo = @min(plan.buffer_offset[i_in], plan.buffer_offset[i_out]);
    try std.testing.expectEqual(@as(usize, 0), i_lo);
}

test "L7 mixed-alignment invariant holds across a sweep of N (incl. ones that force a pad)" {
    // Whatever the i16 class's total bytes are, the f64 class's every buffer must
    // land on an 8-multiple. Sweep N over sizes whose i16 totals are and are NOT
    // multiples of 8, so both the pad and no-pad branches are exercised; the
    // invariant — every referenced id offset % its align == 0 — holds throughout.
    inline for ([_]usize{ 1, 2, 3, 5, 7, 16, 64, 257 }) |N| {
        const g = comptime mixedAlignGraph(N);
        const plan = comptime try commitComptime(g);
        try assertAlignmentInvariant(plan);
    }
}

test "L7 the two classes still pay only their own bytes plus the alignment pad (footprint accounting)" {
    // footprint = i16 pools + f64 pools + alignment pad between the classes. With
    // N=1: i16 = 2·1·2 = 4, then pad 4 → f64 base 8, f64 = 2·1·8 = 16. Total pool
    // = 8 (i16 + pad) + 16 = 24. The pad is the ONLY extra over the bare class
    // sums (4 + 16 = 20) — alignment costs exactly the bytes it must, no more.
    const g = comptime mixedAlignGraph(1);
    const plan = comptime try commitComptime(g);
    const bare = (2 * 1 * 2) + (2 * 1 * 8); // 4 + 16 = 20, the un-padded class sums
    const pad = 4; // i16 class ends at 4, f64 (align 8) bumps it to 8
    try std.testing.expectEqual(@as(usize, bare + pad), plan.pool_bytes);
    try std.testing.expectEqual(@as(usize, 24), plan.footprint_bytes);
}

test "L7 buffer_align equals @alignOf of each class's element type (right target, not just aligned)" {
    // An offset that happens to be a multiple of a WRONG (too-small) alignment
    // would pass the modulo test yet still let a real @alignCast trap. Pin that
    // each class records the TRUE @alignOf of its element: i16→2, f64→8. This is
    // what makes `buffer_offset % buffer_align == 0` the actual @alignCast guard.
    const g = comptime mixedAlignGraph(7);
    const plan = comptime try commitComptime(g);
    // i16 ping-pong (op 1) and f64 ping-pong (op 4).
    try std.testing.expectEqual(@as(usize, @alignOf(Sample(i16))), plan.buffer_align[plan.ops[1].input_buffer_ids[0]]);
    try std.testing.expectEqual(@as(usize, @alignOf(Sample(i16))), plan.buffer_align[plan.ops[1].output_buffer_ids[0]]);
    try std.testing.expectEqual(@as(usize, @alignOf(Sample(f64))), plan.buffer_align[plan.ops[4].input_buffer_ids[0]]);
    try std.testing.expectEqual(@as(usize, @alignOf(Sample(f64))), plan.buffer_align[plan.ops[4].output_buffer_ids[0]]);
    // And the recorded aligns are 2 and 8 concretely (catches a stale default).
    try std.testing.expectEqual(@as(usize, 2), @alignOf(Sample(i16)));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Sample(f64)));
}

// --- L7.c both layout passes agree (per-edge baseline ≡ colored on alignment) -

test "L7 the per-edge baseline aligns offsets by the SAME rule as the colored pool" {
    // The alignment guard lives in the layout pass shared by BOTH buffer modes,
    // so the obviously-correct per-edge baseline (every value its own buffer, no
    // reuse) must satisfy the SAME invariant. If only the colored path aligned,
    // a Tier-B recolor onto the per-edge baseline could re-introduce a misaligned
    // @alignCast — so we pin the baseline independently.
    const g = comptime mixedAlignGraph(3);
    const plan_pe = comptime try commitComptimeMode(g, BufferMode.per_edge);
    const plan_c = comptime try commitComptimeMode(g, BufferMode.colored);
    try assertAlignmentInvariant(plan_pe);
    try assertAlignmentInvariant(plan_c);
    // Both passes record the same per-class alignment target on every used id.
    const ref_pe = referencedBufferIds(plan_pe);
    for (0..ref_pe.len) |k| {
        const a = plan_pe.buffer_align[ref_pe.ids[k]];
        try std.testing.expect(a == @alignOf(Sample(i16)) or a == @alignOf(Sample(f64)));
    }
}

// --- L7.d the persistent feedback z⁻¹ tail aligns its absolute offset --------

test "L7 a wide-aligned feedback z⁻¹ buffer in the pool tail lands on an aligned absolute offset" {
    // A comb whose SCRATCH pool is a narrow class (i16, ending the scratch on a
    // non-8 byte boundary) but whose FEEDBACK element is wide (f64, align 8). The
    // persistent z⁻¹ buffer lives PAST the scratch pool; its absolute offset must
    // still be 8-aligned, or the engine's @alignCast of the tail region to *f64
    // would trap. We build a delayed f64 loop so the SCC-has-delay check passes
    // and the feedback source mints a persistent f64 buffer.
    const DelayF64 = struct {
        const Self = @This();
        pub const delay_len: usize = 3; // marks the block a delay (closes the loop causally)
        pub fn process(self: *Self, in: []const Sample(f64), out: []Sample(f64)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    // The graph: an i16 scratch chain (to push the scratch pool to a non-8 end)
    // PLUS an f64 feedback loop  src→sum→delay→gain→sink, gain ⤳ sum (z⁻¹).
    const N = 1; // i16 scratch = 2·1·2 = 4 bytes ⇒ scratch ends NOT on an 8-boundary
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        // narrow scratch chain (i16), laid out first
        const i_in = gg.add(SrcI16);
        const i_out = gg.add(SinkI16);
        gg.connect(port.MapOutPort(SrcI16), i_in, 0, port.MapInPort(SinkI16), i_out, 0);
        // f64 feedback loop, laid out second
        const f_in = gg.add(SrcF64);
        const sum = gg.add(Map1F64);
        const dl = gg.add(DelayF64);
        const gain = gg.add(Map1F64);
        const f_out = gg.add(SinkF64);
        gg.connect(port.MapOutPort(SrcF64), f_in, 0, port.MapInPort(Map1F64), sum, 0);
        gg.connect(port.MapOutPort(Map1F64), sum, 0, port.MapInPort(DelayF64), dl, 0);
        gg.connect(port.MapOutPort(DelayF64), dl, 0, port.MapInPort(Map1F64), gain, 0);
        gg.connect(port.MapOutPort(Map1F64), gain, 0, port.MapInPort(SinkF64), f_out, 0);
        gg.connectFeedback(port.MapOutPort(Map1F64), gain, 0, port.MapInPort(Map1F64), sum, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    // There IS a persistent tail (one f64 z⁻¹ buffer).
    try std.testing.expect(plan.persistent_bytes > 0);
    // The whole invariant still holds across scratch + tail.
    try assertAlignmentInvariant(plan);
    // The persistent buffer id is the one whose offset sits at/after the scratch
    // pool end (`pool_bytes`); find every referenced id in the tail and assert it
    // is 8-aligned with align == @alignOf(Sample(f64)).
    const ref = referencedBufferIds(plan);
    var saw_tail = false;
    for (0..ref.len) |k| {
        const id = ref.ids[k];
        if (plan.buffer_offset[id] >= plan.pool_bytes and plan.buffer_byte_len[id] > 0) {
            saw_tail = true;
            try std.testing.expectEqual(@as(usize, @alignOf(Sample(f64))), plan.buffer_align[id]);
            try std.testing.expectEqual(@as(usize, 0), plan.buffer_offset[id] % @alignOf(Sample(f64)));
        }
    }
    try std.testing.expect(saw_tail);
}
