//! Behavioural specification for the thin unified entry façade (`src/facade.zig`,
//! re-exported as `pan.render` / `pan.renderJobs` / `pan.RenderOptions`).
//!
//! The façade's whole job is *routing*: one `render(...)` call dispatched by an
//! `intent` to the existing execution tiers (the comptime Tier-A executor for
//! `.realtime`, the Tier-C `OfflineBatch` for `.offline`), with `renderJobs`
//! fanning a batch out file-level. The façade adds NO new arithmetic — it
//! constructs an existing executor and delegates. So its correctness contract is
//! purely an EQUIVALENCE one, and every check below is bit-exact (pan-vs-pan: a
//! façade that routed correctly must produce byte-identical output to the tier it
//! routed to; tolerance never forgives a router disagreeing with its target):
//!
//!   1. SAME GRAPH, BOTH INTENTS MATCH.
//!      `render(.{.intent=.offline})` == `render(.{.intent=.realtime,.cores=1})`,
//!      bit-for-bit, over a noise corpus. This is the load-bearing claim: the two
//!      tiers are two schedulings of the *same* dataflow over the *same*
//!      endpoint graph, so a uniform `[]const f32 -> []f32` is meaningful and the
//!      façade's two routes are interchangeable on output.
//!
//!   2. FUSION IS TRANSPARENT THROUGH THE FAÇADE.
//!      `render(.{.realtime,.fuse=true})` == `render(.{.realtime,.fuse=false})`,
//!      bit-for-bit. Automatic loop-fusion changes only memory traffic, never the
//!      result; the façade's `fuse` knob must inherit that bit-transparency. (The
//!      fused path goes through `FusedExecutor`; the unfused through the unfused
//!      `Executor` via `OfflineBatch.renderSequential`. Equality proves the
//!      façade wires both to the same denotation.)
//!
//!   3. FILE-LEVEL BATCH == K SERIAL SINGLE RENDERS.
//!      `renderJobs` over K jobs produces, per job, output bit-identical to K
//!      individual `render(.{.intent=.offline})` calls. Batch parallelism changes
//!      only scheduling; each job is an isolated render, so the per-job arithmetic
//!      is untouched. (Cross-cores: K=1, K=2, K=many, K>jobs.)
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring,
//! per project Rules 13/14). All diagnostics go to `std.debug.print`, never
//! `std.log.err` (the 0.16 test runner counts logged errors and would flip an
//! otherwise-green suite to a non-zero exit). No external oracle: every check is
//! pan-vs-pan ⇒ bit-exact.

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const port = pan.port;
const Sample = pan.Sample(f32);
const Source = pan.offline.Source;
const Sink = pan.offline.Sink;
const testing = std.testing;

// ===========================================================================
// Test DSP blocks — param-free, fusable single-consumer unary Maps. Each is a
// stateless rate-1:1 type-stable Map (the shape automatic fusion folds), so the
// fused and unfused realtime paths exercise a chain that genuinely fuses.
// ===========================================================================

/// A stateless per-sample gain by a comptime coefficient. `aliasing_safe` (it may
/// write in place) and fusable. Declares `warmup_samples = 0` so the graph is
/// also `OfflineBatch`-chunkable (the offline route may chunk it).
fn Gain(comptime k: f32) type {
    return struct {
        const Self = @This();
        pub const aliasing_safe = true;
        pub const warmup_samples: usize = 0;
        pub const warmup_exact: bool = true;
        pub fn process(self: *Self, in: []const Sample, out: []Sample) void {
            _ = self;
            for (in, out) |x, *y| y.ch[0] = x.ch[0] * k;
        }
    };
}

/// A stateless cubic soft-clipper (a nonlinear, fusable, aliasing-safe Map). Its
/// nonlinearity makes the chain order observable: a coalescing/fusion layout bug
/// would surface as a bit divergence, not as silence.
const SoftClip = struct {
    const Self = @This();
    pub const aliasing_safe = true;
    pub const warmup_samples: usize = 0;
    pub const warmup_exact: bool = true;
    pub fn process(self: *Self, in: []const Sample, out: []Sample) void {
        _ = self;
        for (in, out) |x, *y| {
            const v = std.math.clamp(x.ch[0], -1.0, 1.0);
            y.ch[0] = v - (v * v * v) / 3.0;
        }
    }
};

// ===========================================================================
// The graph under test: offline.Source -> Gain -> SoftClip -> Gain -> offline.Sink.
// A param-free linear chain of fusable Maps between the offline endpoints — the
// canonical façade shape, with a fusable interior so gate 2 is non-trivial.
// ===========================================================================

const G = blk: {
    var g = graph.Graph.empty;
    g.block_size = 64;
    const s = g.add(Source);
    const g0 = g.add(Gain(0.8));
    const sc = g.add(SoftClip);
    const g1 = g.add(Gain(1.3));
    const k = g.add(Sink);
    g.connect(port.MapOutPort(Source), s, 0, port.MapInPort(Gain(0.8)), g0, 0);
    g.connect(port.MapOutPort(Gain(0.8)), g0, 0, port.MapInPort(SoftClip), sc, 0);
    g.connect(port.MapOutPort(SoftClip), sc, 0, port.MapInPort(Gain(1.3)), g1, 0);
    g.connect(port.MapOutPort(Gain(1.3)), g1, 0, port.MapInPort(Sink), k, 0);
    break :blk g;
};

const NODE_BLOCKS: []const type = &.{ Source, Gain(0.8), SoftClip, Gain(1.3), Sink };

/// The configured per-node template (the Source/Sink instances are overridden by
/// the façade with the actual input/output buffers).
fn template() std.meta.Tuple(NODE_BLOCKS) {
    return .{ Source{}, Gain(0.8){}, SoftClip{}, Gain(1.3){}, Sink{} };
}

// ===========================================================================
// Helpers — deterministic noise + bit-exact compare (mirrors the suite house
// style; pan-vs-pan ⇒ ALWAYS bit-exact, never allclose).
// ===========================================================================

fn fillNoise(buf: []f32, seed: u64) void {
    var s = seed | 1;
    for (buf) |*x| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        const u: u32 = @truncate(s);
        // Awkward fractional bits in roughly [-1, 1), so a layout bug diverges.
        x.* = @as(f32, @floatFromInt(u % 2_000_001)) / 1_000_000.0 - 1.0;
    }
}

fn bitExact(got: []const f32, ref: []const f32) !void {
    try testing.expectEqualSlices(f32, ref, got);
}

// ===========================================================================
// 1. SAME GRAPH, BOTH INTENTS MATCH — the load-bearing equivalence.
// ===========================================================================

test "facade: render(.offline) == render(.realtime, cores=1), bit-for-bit" {
    const alloc = testing.allocator;
    const T = 1000; // non-block-multiple length (exercises the partial final block)
    var input: [T]f32 = undefined;
    fillNoise(&input, 0xFACADE01);

    var rt: [T]f32 = undefined;
    var off: [T]f32 = undefined;

    try pan.render(G, NODE_BLOCKS, alloc, template(), &input, &rt, .{ .intent = .realtime, .cores = 1 });
    try pan.render(G, NODE_BLOCKS, alloc, template(), &input, &off, .{ .intent = .offline });

    try bitExact(&rt, &off);
}

test "facade: realtime and offline agree across several noise inputs and lengths" {
    const alloc = testing.allocator;
    const seeds = [_]u64{ 1, 2, 0xDEADBEEF, 0x12345, 99 };
    const lengths = [_]usize{ 64, 65, 127, 512, 777 };
    for (seeds, lengths) |seed, T| {
        const input = try alloc.alloc(f32, T);
        defer alloc.free(input);
        const rt = try alloc.alloc(f32, T);
        defer alloc.free(rt);
        const off = try alloc.alloc(f32, T);
        defer alloc.free(off);
        fillNoise(input, seed);
        try pan.render(G, NODE_BLOCKS, alloc, template(), input, rt, .{ .intent = .realtime });
        try pan.render(G, NODE_BLOCKS, alloc, template(), input, off, .{ .intent = .offline });
        try bitExact(rt, off);
    }
}

// ===========================================================================
// 2. FUSION IS TRANSPARENT THROUGH THE FAÇADE.
// ===========================================================================

test "facade: realtime fuse=true == fuse=false, bit-for-bit (fusion transparent)" {
    const alloc = testing.allocator;
    const T = 853;
    var input: [T]f32 = undefined;
    fillNoise(&input, 0xF00D);

    var fused: [T]f32 = undefined;
    var unfused: [T]f32 = undefined;

    try pan.render(G, NODE_BLOCKS, alloc, template(), &input, &fused, .{ .intent = .realtime, .fuse = true });
    try pan.render(G, NODE_BLOCKS, alloc, template(), &input, &unfused, .{ .intent = .realtime, .fuse = false });

    try bitExact(&fused, &unfused);
}

// ===========================================================================
// 2b. cores>1 realtime is honest: it runs the single-core Tier-A path (no device
// loop to engage true Tier-B), so it must match cores=1 bit-for-bit — NOT a
// different, "parallelised" result.
// ===========================================================================

test "facade: realtime cores>1 falls back to single-core path, bit-identical to cores=1" {
    const alloc = testing.allocator;
    const T = 640;
    var input: [T]f32 = undefined;
    fillNoise(&input, 0xC0DE);

    var c1: [T]f32 = undefined;
    var c4: [T]f32 = undefined;

    try pan.render(G, NODE_BLOCKS, alloc, template(), &input, &c1, .{ .intent = .realtime, .cores = 1 });
    try pan.render(G, NODE_BLOCKS, alloc, template(), &input, &c4, .{ .intent = .realtime, .cores = 4 });

    try bitExact(&c4, &c1);
}

// ===========================================================================
// 3. FILE-LEVEL BATCH == K SERIAL SINGLE RENDERS.
// ===========================================================================

const OB = pan.OfflineBatch(G, NODE_BLOCKS);

test "facade: renderJobs over K jobs == K serial render(.offline), bit-for-bit" {
    const alloc = testing.allocator;
    const K = 7;
    const T = 600;

    // K independent jobs, each with a distinct noise input.
    var inputs: [K][T]f32 = undefined;
    var batch_out: [K][T]f32 = undefined;
    var serial_out: [K][T]f32 = undefined;
    for (0..K) |j| fillNoise(&inputs[j], 0x5EED +% j);

    // Reference: each job rendered alone through the offline façade route.
    for (0..K) |j| {
        try pan.render(G, NODE_BLOCKS, alloc, template(), &inputs[j], &serial_out[j], .{ .intent = .offline });
    }

    // Across several core counts (serial fast path, 2, more cores than jobs).
    for ([_]usize{ 1, 2, 4, K + 3 }) |cores| {
        var jobs: [K]OB.Job = undefined;
        for (0..K) |j| jobs[j] = .{ .input = &inputs[j], .output = &batch_out[j] };
        try pan.renderJobs(G, NODE_BLOCKS, alloc, template(), &jobs, .{ .intent = .offline, .cores = cores });
        for (0..K) |j| try bitExact(&batch_out[j], &serial_out[j]);
    }
}

test "facade: renderJobs with an empty job list is a no-op" {
    const alloc = testing.allocator;
    const empty: []const OB.Job = &.{};
    try pan.renderJobs(G, NODE_BLOCKS, alloc, template(), empty, .{ .intent = .offline, .cores = 4 });
}
