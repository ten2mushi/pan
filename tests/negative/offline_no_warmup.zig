//! NEGATIVE-COMPILE fixture: asking the OfflineBatch data-parallel chunker to
//! partition a graph that contains a **stateful block declaring no
//! `warmup_samples`** is a commit-time error.
//!
//! The presence of the `warmup_samples` field is what authorises partitioning the
//! render timeline through a block: it is the lead-in that reconstructs the
//! block's boundary state at a chunk start. A block that does not declare it
//! cannot have its state reconstructed, so the chunker MUST refuse — and because
//! the graph is comptime, that refusal is a `@compileError` inside
//! `OfflineBatch.renderChunked` ("presence gates chunkability"). This fixture
//! builds a `Source → one-pole IIR (no warmup_samples) → Sink` graph and
//! references `renderChunked`; the `neg-compile` build step asserts THIS FILE
//! FAILS to compile (expects a non-zero `zig build-obj` exit). If chunking such a
//! graph ever compiles, the presence-gates-chunkability guarantee regressed.
const std = @import("std");
const pan = @import("pan");

const Sample = pan.Sample;

/// A stateful one-pole IIR that deliberately declares NO `warmup_samples` — so it
/// is not chunkable. (A real chunkable IIR would declare a decay-to-tolerance
/// `warmup_samples` with `warmup_exact = false`.)
const StatefulNoWarmup = struct {
    y1: f32 = 0,
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| {
            self.y1 = 0.1 * x.ch[0] + 0.9 * self.y1;
            y.ch[0] = self.y1;
        }
    }
};

fn badGraph() pan.graph.Graph {
    var gg = pan.graph.Graph.empty;
    gg.block_size = 64;
    const s = gg.add(pan.offline.Source);
    const f = gg.add(StatefulNoWarmup);
    const k = gg.add(pan.offline.Sink);
    gg.connect(pan.port.MapOutPort(pan.offline.Source), s, 0, pan.port.MapInPort(StatefulNoWarmup), f, 0);
    gg.connect(pan.port.MapOutPort(StatefulNoWarmup), f, 0, pan.port.MapInPort(pan.offline.Sink), k, 0);
    return gg;
}

const g = badGraph();
const OB = pan.OfflineBatch(g, &.{ pan.offline.Source, StatefulNoWarmup, pan.offline.Sink });

/// Referencing `renderChunked` forces its body's `comptime` chunkability guard to
/// be analysed, which fires the `@compileError`.
pub fn forceCompileError(alloc: std.mem.Allocator, in: []const f32, out: []f32) void {
    OB.renderChunked(alloc, .{ pan.offline.Source{}, StatefulNoWarmup{}, pan.offline.Sink{} }, in, out, 4) catch {};
}

comptime {
    _ = &forceCompileError;
}
