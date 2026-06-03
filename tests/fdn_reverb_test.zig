//! fdn_reverb_test — a Feedback Delay Network assembled graph-level from the
//! stated primitives (`src/fx.zig FdnMatrix` + `src/time.zig PlanarDelayLine` +
//! declared feedback edges) and rendered end-to-end through the Tier-A `Executor`.
//!
//! Topology (catalog §5.5 "N DelayLine nodes + a matrix-mix Map over
//! Frame(.discrete(N)) + feedback edges"):
//!
//!   source → FdnMatrix ─in0          out→ PlanarDelayLine ─┬→ sink
//!                       └in1 ←── (feedback z⁻¹) ───────────┘
//!
//! The mixing matrix lives inside the trace; the SCC `{FdnMatrix, PlanarDelayLine}`
//! contains the delay element, so the loop is causal (`error.DelayFreeLoop` passes).
//! The default `FdnMatrix` is an orthogonal Hadamard scaled by `decay = 0.85`, so
//! the loop is energy-preserving-then-damped: an impulse excites a STABLE,
//! DECAYING, diffuse tail.
//!
//! What is checked:
//!   - the FDN COMMITS (SCC-has-delay accepts it; footprint > 0; a persistent
//!     feedback tail exists for the `discrete(4)` bus);
//!   - the dual: an FDN with NO delay in the loop is rejected `error.DelayFreeLoop`;
//!   - rendered through the executor, the impulse response is FINITE and the
//!     block-energy tail DECAYS (a real reverb tail, not a divergence).
//!
//! COMPARISON MODE: the decay/finiteness checks are ≈ behavioural (an analytic
//! property of a sub-unitary feedback loop), asserted with `expect`/inequalities,
//! not against a bit-exact oracle (there is no second pan path here). The commit
//! acceptance/rejection is ⊢ (`expectError`).
//!
//! Verified against zig 0.16.0 (zig-0-16 skill loaded per Rules 13/14); reject-path
//! diagnostics would use `std.debug.print`, never `std.log.err`.

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const commit = pan.commit;
const port = pan.port;
const types = pan.types;
const numeric = pan.numeric;

const f32num = numeric.numericFor(.f32, .{});

const N_FDN = 4; // FDN order (power of two for the Hadamard mixing matrix)
const L: types.ChannelLayout = .{ .discrete = N_FDN };
const BLOCK = 128; // device block size N
const DELAY = 53; // per-channel delay length (< BLOCK, prime-ish for diffusion)

const Bus = types.Frame(f32, L);
const FdnMatrix = pan.FdnMatrix(f32num, N_FDN);
const FdnDelay = pan.PlanarDelayLine(f32, L, DELAY);

/// An impulse source on the `discrete(4)` bus: fires a unit impulse into channel 0
/// at sample 0 of its FIRST render, silence forever after. A zero-sample-input
/// planar-output Map ⇒ a Source.
const ImpulseSource = struct {
    const Self = @This();
    fired: bool = false,
    pub fn process(self: *Self, out: types.Planar(f32, L)) void {
        inline for (0..N_FDN) |c| @memset(out.plane(c), 0);
        if (!self.fired) {
            out.plane(0)[0] = 1.0;
            self.fired = true;
        }
    }
};

/// A bus sink that records the per-render energy (Σ x² across all channels) of its
/// input, so the test can watch the reverb tail decay block by block.
const EnergySink = struct {
    const Self = @This();
    energy: f32 = 0,
    pub fn process(self: *Self, in: types.PlanarConst(f32, L)) void {
        var e: f32 = 0;
        inline for (0..N_FDN) |c| {
            for (in.plane(c)) |x| e += x * x;
        }
        self.energy = e;
    }
};

/// Build the FDN graph: source → matrix → delay → sink, with the delay output fed
/// back to the matrix's second input (the vector feedback edge).
fn fdnGraph() graph.Graph {
    var g = graph.Graph.empty;
    g.block_size = BLOCK;
    const src = g.add(ImpulseSource);
    const mtx = g.add(FdnMatrix);
    const dly = g.add(FdnDelay);
    const snk = g.add(EnergySink);
    g.connect(port.MapOutPort(ImpulseSource), src, 0, port.MapInPortAt(FdnMatrix, 0), mtx, 0);
    g.connect(port.MapOutPort(FdnMatrix), mtx, 0, port.MapInPort(FdnDelay), dly, 0);
    g.connect(port.MapOutPort(FdnDelay), dly, 0, port.MapInPort(EnergySink), snk, 0);
    // The trace: the delayed bus feeds back into the matrix's feedback input.
    g.connectFeedback(port.MapOutPort(FdnDelay), dly, 0, port.MapInPortAt(FdnMatrix, 1), mtx, 1);
    return g;
}

test "FDN commits: SCC-has-delay accepts the matrix+delay trace; a persistent tail exists" {
    const g = comptime fdnGraph();
    const plan = comptime try commit.commitComptime(g);
    try std.testing.expectEqual(@as(usize, 4), plan.op_count);
    try std.testing.expect(plan.footprint_bytes > 0);
    // The feedback bus is one persistent z⁻¹ buffer of N·C·sizeof(f32) bytes.
    try std.testing.expectEqual(@as(usize, BLOCK * N_FDN * @sizeOf(f32)), plan.persistent_bytes);
}

test "FDN dual: the same matrix loop WITHOUT a delay is rejected (error.DelayFreeLoop)" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = BLOCK;
        const src = gg.add(ImpulseSource);
        const mtx = gg.add(FdnMatrix);
        const snk = gg.add(EnergySink);
        gg.connect(port.MapOutPort(ImpulseSource), src, 0, port.MapInPortAt(FdnMatrix, 0), mtx, 0);
        gg.connect(port.MapOutPort(FdnMatrix), mtx, 0, port.MapInPort(EnergySink), snk, 0);
        // Feed the matrix output straight back into itself — no delay in the SCC.
        gg.connectFeedback(port.MapOutPort(FdnMatrix), mtx, 0, port.MapInPortAt(FdnMatrix, 1), mtx, 1);
        break :blk gg;
    };
    try std.testing.expectError(error.DelayFreeLoop, comptime commit.commitComptime(g));
}

test "FDN renders a finite, decaying reverb tail through the executor" {
    const g = comptime fdnGraph();
    const Exec = pan.Executor(g, &.{ ImpulseSource, FdnMatrix, FdnDelay, EnergySink });
    var exec: Exec = .{ .instances = .{ .{}, .{}, .{}, .{} } };

    const token = pan.enterRealtimeThread();
    defer token.leave();

    // Render a long tail and record per-block sink energy.
    const blocks = 64;
    var energy: [blocks]f32 = undefined;
    for (0..blocks) |b| {
        exec.render(token);
        energy[b] = exec.instances[3].energy;
        // Every block's energy is finite — a sub-unitary loop never diverges.
        try std.testing.expect(std.math.isFinite(energy[b]));
    }

    // The impulse must actually excite the network: some block carries energy.
    var peak: f32 = 0;
    var peak_block: usize = 0;
    for (energy, 0..) |e, b| {
        if (e > peak) {
            peak = e;
            peak_block = b;
        }
    }
    try std.testing.expect(peak > 0);

    // The tail DECAYS: averaged energy late in the response is well below the peak
    // (the 0.85 per-trip gain damps it). Compare an early window to a late window
    // after the peak so the comparison is robust to the bus's diffusion ripple.
    var early: f32 = 0;
    var late: f32 = 0;
    for (energy[peak_block .. peak_block + 4]) |e| early += e;
    for (energy[blocks - 8 .. blocks]) |e| late += e / 2.0; // 8 blocks vs 4 → halve
    try std.testing.expect(late < early); // strictly decaying tail
}
