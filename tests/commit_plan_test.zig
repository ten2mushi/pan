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
    pub fn process(self: *Self, out: []Frame(f32, .stereo)) void {
        _ = self;
        _ = out;
    }
};
const Map1Stereo = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Frame(f32, .stereo), out: []Frame(f32, .stereo)) void {
        _ = self;
        @memcpy(out, in);
    }
};
const SinkStereo = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Frame(f32, .stereo)) void {
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
