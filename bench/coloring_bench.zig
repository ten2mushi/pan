//! Benchmark: Mode-B (per-edge) vs Mode-C (colored pool) — the P7 flagship memory
//! bench, behind the same commit interface (`commitComptimeMode`).
//!
//! Measures (never asserts an oracle):
//!   - the static FOOTPRINT reduction %: Mode-B gives every produced value its own
//!     buffer; Mode-C colors per element-class (reuse a buffer once its last reader
//!     has run) and in-place-coalesces single-consumer `aliasing_safe` maps. The
//!     reduction is the working-set the H2 figure reports;
//!   - the per-render DISTINCT WORKING SET reduction %: the number of distinct pool
//!     bytes an op-list touches per render. (Raw byte-DISPLACEMENT — Σ over ops of
//!     bytes read+written — is coloring-INVARIANT: coloring changes which buffer an
//!     op touches, not how many touches occur. The win coloring delivers is a
//!     smaller DISTINCT footprint, so the same traffic lands in a cache-resident
//!     pool; we report that distinct-working-set figure, which IS what shrinks.)
//!
//! Footprint is deterministic, so the numbers are reproducible. Build/run:
//! `zig build bench` (ReleaseFast).

const std = @import("std");
const pan = @import("pan");

const Sample = pan.types.Sample;
const f32num = pan.numericFor(.f32, .{});

const N = 512;

const NoiseSource = struct {
    data: []const Sample(f32) = &.{},
    cursor: usize = 0,
    pub fn process(self: *@This(), out: []Sample(f32)) void {
        _ = self;
        _ = out;
    }
};
const MonoSink = struct {
    pub fn process(self: *@This(), in: []const Sample(f32)) void {
        _ = self;
        _ = in;
    }
};

/// The distinct pool working set touched per render: Σ byte_len over the set of
/// DISTINCT buffer ids referenced across the whole op-list (inputs + outputs). This
/// is the cache-resident footprint the op-list actually walks each render — the
/// figure coloring shrinks (vs the raw, coloring-invariant displacement sum).
fn distinctWorkingSet(comptime n_ops: usize, plan: *const pan.commit.Plan(n_ops)) usize {
    var seen = [_]bool{false} ** pan.graph.max_buffers;
    var total: usize = 0;
    for (plan.ops[0..plan.op_count]) |op| {
        for (op.input_buffer_ids[0..op.input_count]) |id| {
            if (!seen[id]) {
                seen[id] = true;
                total += plan.buffer_byte_len[id];
            }
        }
        for (op.output_buffer_ids[0..op.output_count]) |id| {
            if (!seen[id]) {
                seen[id] = true;
                total += plan.buffer_byte_len[id];
            }
        }
    }
    return total;
}

fn pct(b: usize, c: usize) f64 {
    if (b == 0) return 0;
    return (1.0 - @as(f64, @floatFromInt(c)) / @as(f64, @floatFromInt(b))) * 100.0;
}

/// Report Mode-B vs Mode-C for one comptime graph `g` under a label.
fn reportModes(comptime label: []const u8, comptime g: pan.graph.Graph) void {
    const mode_b = comptime pan.commitComptimeMode(g, .per_edge) catch unreachable;
    const mode_c = comptime pan.commitComptimeMode(g, .colored) catch unreachable;
    const ws_b = distinctWorkingSet(g.node_count, &mode_b);
    const ws_c = distinctWorkingSet(g.node_count, &mode_c);
    std.debug.print(
        "  {s}:\n" ++
            "    footprint:      Mode-B {d}B  →  Mode-C {d}B   ({d:.1}% reduction, {d}→{d} pool buffers)\n" ++
            "    working set/render: Mode-B {d}B  →  Mode-C {d}B   ({d:.1}% reduction)\n",
        .{ label, mode_b.footprint_bytes, mode_c.footprint_bytes, pct(mode_b.footprint_bytes, mode_c.footprint_bytes), mode_b.pool_buffer_count, mode_c.pool_buffer_count, ws_b, ws_c, pct(ws_b, ws_c) },
    );
}

/// A deep chain of K non-aliasing-safe biquads (ping-pong): Mode-C collapses K+1
/// values to 2 colors; Mode-B keeps all K+1.
fn biquadChain(comptime K: usize) pan.graph.Graph {
    const Biquad = pan.filters.Biquad(f32num);
    @setEvalBranchQuota(100_000);
    var g = pan.graph.Graph.empty;
    g.block_size = N;
    const src = g.add(NoiseSource);
    var ids: [K]usize = undefined;
    for (0..K) |i| ids[i] = g.add(Biquad);
    const snk = g.add(MonoSink);
    g.connect(pan.port.MapOutPort(NoiseSource), src, 0, pan.port.MapInPort(Biquad), ids[0], 0);
    for (1..K) |i| g.connect(pan.port.MapOutPort(Biquad), ids[i - 1], 0, pan.port.MapInPort(Biquad), ids[i], 0);
    g.connect(pan.port.MapOutPort(Biquad), ids[K - 1], 0, pan.port.MapInPort(MonoSink), snk, 0);
    return g;
}

/// A deep chain of K aliasing-safe gains: Mode-C in-place-coalesces them ALL onto a
/// single buffer; Mode-B keeps all K+1.
fn gainChain(comptime K: usize) pan.graph.Graph {
    const Gain = pan.filters.Gain(f32num);
    @setEvalBranchQuota(100_000);
    var g = pan.graph.Graph.empty;
    g.block_size = N;
    const src = g.add(NoiseSource);
    var ids: [K]usize = undefined;
    for (0..K) |i| ids[i] = g.add(Gain);
    const snk = g.add(MonoSink);
    g.connect(pan.port.MapOutPort(NoiseSource), src, 0, pan.port.MapInPort(Gain), ids[0], 0);
    for (1..K) |i| g.connect(pan.port.MapOutPort(Gain), ids[i - 1], 0, pan.port.MapInPort(Gain), ids[i], 0);
    g.connect(pan.port.MapOutPort(Gain), ids[K - 1], 0, pan.port.MapInPort(MonoSink), snk, 0);
    return g;
}

pub fn main() !void {
    std.debug.print("pan bench: Mode-B (per-edge) vs Mode-C (colored) memory, N={d} f32\n", .{N});
    reportModes("biquad ping-pong chain (K=8, not aliasing_safe)", comptime biquadChain(8));
    reportModes("biquad ping-pong chain (K=16)", comptime biquadChain(16));
    reportModes("gain chain (K=16, aliasing_safe → in-place coalesced)", comptime gainChain(16));
    reportModes("gain chain (K=32)", comptime gainChain(32));
}
