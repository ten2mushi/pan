//! Gate for automatic loop-fusion wired into the Tier-C `OfflineBatch`
//! (`pan.OfflineBatchFused`). Fusing adjacent rate-1:1, type-stable,
//! single-consumer, param-free `Map`s into one block-size-1 `Subgraph` pass is
//! denotationally identity — `(h ∘ g ∘ f)(x) = h(g(f(x)))` sample for sample — so
//! the fused offline render MUST be BIT-EXACT to the unfused offline render. These
//! tests pin that law on a param-free linear offline-endpoint chain
//! (`offline.Source → Gain → SoftClip → Trim → offline.Sink`), and prove fusion
//! actually fired by asserting the fused graph's committed op_count drops below the
//! unfused graph's (the fused chain collapses to one top-level op).
//!
//! Independence of the oracle (Rule 9): the bit-exact claim compares against the
//! UNFUSED `OfflineBatch.renderSequential`, the established ground truth — fusion
//! is required to reproduce it to the bit, so any value-level deviation introduced
//! by the fold fails the test. The op_count assertion is an absolute structural
//! truth (fewer ops on the fused plan), not a pan-vs-pan tautology.

const std = @import("std");
const pan = @import("pan");

const Sample = pan.Sample;
const Source = pan.offline.Source;
const Sink = pan.offline.Sink;
const OfflineBatch = pan.OfflineBatch;
const OfflineBatchFused = pan.OfflineBatchFused;
const graph = pan.graph;
const port = pan.port;
const testing = std.testing;

// ===========================================================================
// Param-free, single-in/single-out, rate-1:1, type-stable Map blocks — the
// fusion-eligible shape. Each carries cross-sample-free per-sample arithmetic, so
// fusing the run is a pure composition of morphisms.
// ===========================================================================

/// A stateless per-sample gain.
fn Gain(comptime g: f32) type {
    return struct {
        const Self = @This();
        pub const warmup_samples: usize = 0;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            for (in, out) |x, *y| y.ch[0] = x.ch[0] * g;
        }
    };
}

/// A stateless tanh-style soft clipper.
const SoftClip = struct {
    const Self = @This();
    pub const warmup_samples: usize = 0;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (in, out) |x, *y| {
            const v = x.ch[0];
            // A cheap odd-symmetric saturator: v - v^3/3, hard-limited at ±1.
            const shaped = v - (v * v * v) / 3.0;
            y.ch[0] = std.math.clamp(shaped, -1.0, 1.0);
        }
    }
};

/// A stateless hard trim (linear gain), distinct type from `Gain` so the chain has
/// three folded members.
fn Trim(comptime t: f32) type {
    return struct {
        const Self = @This();
        pub const warmup_samples: usize = 0;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            for (in, out) |x, *y| y.ch[0] = x.ch[0] * t;
        }
    };
}

// ===========================================================================
// Graph + helpers
// ===========================================================================

const G = Gain(1.7);
const Tr = Trim(0.6);

/// `offline.Source → Gain → SoftClip → Trim → offline.Sink` — a param-free linear
/// endpoint chain. The three interior Maps are the maximal fusable run.
fn buildGraph() graph.Graph {
    var g = graph.Graph.empty;
    g.block_size = 64;
    const s = g.add(Source);
    const a = g.add(G);
    const b = g.add(SoftClip);
    const c = g.add(Tr);
    const k = g.add(Sink);
    g.connect(port.MapOutPort(Source), s, 0, port.MapInPort(G), a, 0);
    g.connect(port.MapOutPort(G), a, 0, port.MapInPort(SoftClip), b, 0);
    g.connect(port.MapOutPort(SoftClip), b, 0, port.MapInPort(Tr), c, 0);
    g.connect(port.MapOutPort(Tr), c, 0, port.MapInPort(Sink), k, 0);
    return g;
}

const node_blocks = [_]type{ Source, G, SoftClip, Tr, Sink };

fn fillNoise(buf: []f32, seed: u64) void {
    var s = seed;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = @as(f32, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(s >> 16)))))) / 2.147483648e9;
    }
}

fn template() OfflineBatch(buildGraph(), &node_blocks).InstanceTuple {
    return .{ Source{}, G{}, SoftClip{}, Tr{}, Sink{} };
}

// ===========================================================================
// Tests
// ===========================================================================

test "fused offline renderSequential is bit-identical to unfused (param-free linear chain)" {
    const g = comptime buildGraph();
    const Plain = OfflineBatch(g, &node_blocks);
    const Fzd = OfflineBatchFused(g, &node_blocks);

    const T = 1000;
    var input: [T]f32 = undefined;
    fillNoise(&input, 31);
    var unfused: [T]f32 = undefined;
    var fused: [T]f32 = undefined;

    Plain.renderSequential(template(), &input, &unfused);
    Fzd.renderSequential(.{ Source{}, G{}, SoftClip{}, Tr{}, Sink{} }, &input, &fused);

    try testing.expectEqualSlices(f32, &unfused, &fused);
}

test "fused offline render() (auto-route) is bit-identical to unfused renderSequential" {
    const g = comptime buildGraph();
    const Plain = OfflineBatch(g, &node_blocks);
    const Fzd = OfflineBatchFused(g, &node_blocks);

    const T = 900; // not a block multiple — exercises the final partial block
    var input: [T]f32 = undefined;
    fillNoise(&input, 37);
    var unfused: [T]f32 = undefined;
    var fused: [T]f32 = undefined;

    Plain.renderSequential(template(), &input, &unfused);
    try Fzd.render(testing.allocator, .{ Source{}, G{}, SoftClip{}, Tr{}, Sink{} }, &input, &fused);

    try testing.expectEqualSlices(f32, &unfused, &fused);
}

test "fusion actually fired: the fused plan has strictly fewer ops than the unfused plan" {
    const g = comptime buildGraph();
    const Plain = OfflineBatch(g, &node_blocks);
    const Fzd = OfflineBatchFused(g, &node_blocks);

    // The unfused plan schedules each of Gain/SoftClip/Trim as its own op; the
    // fused plan collapses that run into one Subgraph op, so the fused op_count is
    // strictly smaller. A bare inequality (not an exact count) keeps the proof
    // robust to scheduler-internal bookkeeping ops.
    try testing.expect(Fzd.committed.op_count < Plain.committed.op_count);
}

test "fused offline render is empty-safe and deterministic across repeats" {
    const g = comptime buildGraph();
    const Fzd = OfflineBatchFused(g, &node_blocks);

    // Empty timeline is a no-op (no crash, no write).
    {
        var empty_in: [0]f32 = undefined;
        var empty_out: [0]f32 = undefined;
        try Fzd.render(testing.allocator, .{ Source{}, G{}, SoftClip{}, Tr{}, Sink{} }, &empty_in, &empty_out);
    }

    const T = 333;
    var input: [T]f32 = undefined;
    fillNoise(&input, 41);
    var a: [T]f32 = undefined;
    var b: [T]f32 = undefined;
    Fzd.renderSequential(.{ Source{}, G{}, SoftClip{}, Tr{}, Sink{} }, &input, &a);
    Fzd.renderSequential(.{ Source{}, G{}, SoftClip{}, Tr{}, Sink{} }, &input, &b);
    try testing.expectEqualSlices(f32, &a, &b);
}
