//! The render engine skeleton (catalog §8, §10).
//!
//! `enterRealtimeThread()` returns a `RealtimeToken` whose construction sets
//! FTZ/DAZ on the calling thread (catalog §10; no-op body here). `renderInto`
//! REQUIRES the token in its signature — it will not compile without one ⊢
//! (the structural nudge of H3/§10). It replays the op-list (empty kernels OK).

const std = @import("std");
const commit = @import("commit.zig");
const mux = @import("mux.zig");

/// The realtime token (catalog §10). Holding one is the proof-of-entry that
/// FTZ/DAZ were set on *this* thread (the ARM64 FPCR `FZ` bit is per-thread).
/// No-op body on this skeleton / on fixed-point targets; uniform API shape.
pub const RealtimeToken = struct {
    /// Opaque marker; presence in a signature is the load-bearing part.
    _entered: bool = true,
};

/// Enter the realtime thread (catalog §10). On a real target this sets the
/// FPCR `FZ`/`AH` bits (FTZ/DAZ). Here it is a no-op returning the token.
pub fn enterRealtimeThread() RealtimeToken {
    // TODO: set FPCR FTZ/DAZ (ARM64) / MXCSR (x86) here on a real build.
    return .{};
}

/// Replay a committed plan's op-list (catalog §8.2 hot path). REQUIRES a
/// `RealtimeToken` — the signature won't type-check without it (⊢, catalog §10:
/// "renderInto requires the token — it won't compile without it").
///
/// `n_ops` is comptime so a comptime plan inlines fully on embedded.
pub fn renderInto(
    comptime n_ops: usize,
    token: RealtimeToken,
    plan: *const commit.Plan(n_ops),
    sample_mux: mux.SampleMux,
) void {
    _ = token; // holding it is the contract; body uses it as a witness only
    // Hot path: for op in plan.ops: op.fn_ptr(op.self_ptr, gather, scatter, n).
    for (plan.ops[0..plan.op_count]) |op| {
        if (op.fn_ptr == null) continue; // empty/stub kernel — skip (skeleton)
        // A real kernel call would gather inputs / scatter outputs via the mux.
        _ = sample_mux;
    }
}

test "renderInto requires a token and replays an (empty-kernel) op-list" {
    const types = @import("types.zig");
    const graph = @import("graph.zig");
    const port = @import("port.zig");
    const Gain = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Gain);
        const b = gg.add(Gain);
        gg.connect(port.MapOutPort(Gain), a, 0, port.MapInPort(Gain), b, 0);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);

    var in_bytes = [_]u8{0} ** 16;
    var out_bytes = [_]u8{0} ** 16;
    var pm = mux.PullSampleMux{ .in_buf = &in_bytes, .out_buf = &out_bytes };

    const token = enterRealtimeThread();
    renderInto(g.edge_count, token, &plan, pm.sampleMux());
    // No crash, empty kernels skipped.
    try std.testing.expect(token._entered);
}
