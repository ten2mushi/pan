//! schroeder_reverb_test — a classic Schroeder reverberator assembled GRAPH-LEVEL
//! from the fused tight-feedback kernels (`src/fx.zig`) and rendered end-to-end
//! through the Tier-A `Executor`.
//!
//! Topology (catalog §5.4 — a comb reverb runs):
//!
//!   source ─┬→ Comb(D0) ┐
//!           ├→ Comb(D1) ┤
//!           ├→ Comb(D2) ┼→ Sum4 → Allpass(Da) → Allpass(Db) → sink
//!           └→ Comb(D3) ┘
//!
//! a parallel bank of four feedback combs summed, then a series of two Schroeder
//! all-passes that smear the periodic echo train into a dense, colourless decay.
//!
//! Crucially, the feedback in these kernels is INTERNAL (each `Comb`/`Allpass` runs
//! its own per-sample `z⁻¹` loop inside `process`), so the GRAPH is a pure
//! feed-forward DAG — there are NO graph feedback edges. The kernels still declare
//! `delay_len` (they are delay elements), but since none sits in a graph cycle the
//! commit pass treats them as ordinary forward `Map`s; the reverb's recirculation
//! is wholly inside the blocks.
//!
//! What is checked: the assembled reverb COMMITS, and rendered through the executor
//! an impulse produces a FINITE, DECAYING tail (the combs' |g|<1 damps it; the
//! all-passes preserve energy but disperse) — "a comb reverb runs".
//!
//! COMPARISON MODE: ≈ behavioural (finiteness + decay of a sub-unitary network),
//! asserted with inequalities — not a bit-exact oracle. Verified against zig
//! 0.16.0 (zig-0-16 skill loaded per Rules 13/14).

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const commit = pan.commit;
const port = pan.port;
const types = pan.types;
const numeric = pan.numeric;

const Sample = types.Sample;
const f32num = numeric.numericFor(.f32, .{});

const BLOCK = 128;
const Comb = pan.Comb(f32num, 64);
const Allpass = pan.Allpass(f32num, 16);

/// Mono impulse source: a unit impulse at sample 0 of the first render, then
/// silence (so the response is the network's impulse response).
const ImpulseSource = struct {
    const Self = @This();
    fired: bool = false,
    pub fn process(self: *Self, out: []Sample(f32)) void {
        @memset(std.mem.sliceAsBytes(out), 0);
        if (!self.fired) {
            out[0] = .{ .ch = .{1.0} };
            self.fired = true;
        }
    }
};

/// The 4-way comb-bank summer: four `Sample` inputs → one `Sample` output.
const Sum4 = struct {
    const Self = @This();
    pub fn process(
        self: *Self,
        in0: []const Sample(f32),
        in1: []const Sample(f32),
        in2: []const Sample(f32),
        in3: []const Sample(f32),
        out: []Sample(f32),
    ) void {
        _ = self;
        for (in0, in1, in2, in3, out) |a, b, c, d, *o|
            o.ch[0] = a.ch[0] + b.ch[0] + c.ch[0] + d.ch[0];
    }
};

/// Mono energy sink: records Σ x² of its input per render so the test can watch
/// the reverb tail decay.
const EnergySink = struct {
    const Self = @This();
    energy: f32 = 0,
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        var e: f32 = 0;
        for (in) |x| e += x.ch[0] * x.ch[0];
        self.energy = e;
    }
};

/// Build the Schroeder reverb graph: impulse → 4 parallel combs → sum → 2 series
/// all-passes → energy sink.
fn schroederGraph() graph.Graph {
    var g = graph.Graph.empty;
    g.block_size = BLOCK;
    const src = g.add(ImpulseSource);
    const c0 = g.add(Comb);
    const c1 = g.add(Comb);
    const c2 = g.add(Comb);
    const c3 = g.add(Comb);
    const sum = g.add(Sum4);
    const a0 = g.add(Allpass);
    const a1 = g.add(Allpass);
    const snk = g.add(EnergySink);

    // Fan the impulse into the four combs.
    g.connect(port.MapOutPort(ImpulseSource), src, 0, port.MapInPort(Comb), c0, 0);
    g.connect(port.MapOutPort(ImpulseSource), src, 0, port.MapInPort(Comb), c1, 0);
    g.connect(port.MapOutPort(ImpulseSource), src, 0, port.MapInPort(Comb), c2, 0);
    g.connect(port.MapOutPort(ImpulseSource), src, 0, port.MapInPort(Comb), c3, 0);
    // Sum the comb outputs.
    g.connect(port.MapOutPort(Comb), c0, 0, port.MapInPortAt(Sum4, 0), sum, 0);
    g.connect(port.MapOutPort(Comb), c1, 0, port.MapInPortAt(Sum4, 1), sum, 1);
    g.connect(port.MapOutPort(Comb), c2, 0, port.MapInPortAt(Sum4, 2), sum, 2);
    g.connect(port.MapOutPort(Comb), c3, 0, port.MapInPortAt(Sum4, 3), sum, 3);
    // Series all-pass diffusion.
    g.connect(port.MapOutPort(Sum4), sum, 0, port.MapInPort(Allpass), a0, 0);
    g.connect(port.MapOutPort(Allpass), a0, 0, port.MapInPort(Allpass), a1, 0);
    g.connect(port.MapOutPort(Allpass), a1, 0, port.MapInPort(EnergySink), snk, 0);
    return g;
}

test "Schroeder reverb commits: a feed-forward DAG of fused delay-element kernels" {
    const g = comptime schroederGraph();
    const plan = comptime try commit.commitComptime(g);
    try std.testing.expectEqual(@as(usize, 9), plan.op_count);
    try std.testing.expect(plan.footprint_bytes > 0);
    // No graph feedback edge — the recirculation is internal to the kernels.
    try std.testing.expectEqual(@as(usize, 0), plan.persistent_bytes);
}

test "Schroeder reverb renders a finite, decaying tail through the executor" {
    const g = comptime schroederGraph();
    const Exec = pan.Executor(g, &.{ ImpulseSource, Comb, Comb, Comb, Comb, Sum4, Allpass, Allpass, EnergySink });
    // Distinct comb delays (mutually prime-ish) + feedback < 1 for a dense decay;
    // all-pass coefficient 0.5 for diffusion.
    var exec: Exec = .{ .instances = .{
        .{},
        .{ .delay = 29, .feedback = 0.7 },
        .{ .delay = 37, .feedback = 0.72 },
        .{ .delay = 43, .feedback = 0.69 },
        .{ .delay = 53, .feedback = 0.71 },
        .{},
        .{ .delay = 11, .feedback = 0.5 },
        .{ .delay = 7, .feedback = 0.5 },
        .{},
    } };

    const token = pan.enterRealtimeThread();
    defer token.leave();

    const blocks = 48;
    var energy: [blocks]f32 = undefined;
    for (0..blocks) |b| {
        exec.render(token);
        energy[b] = exec.instances[8].energy;
        try std.testing.expect(std.math.isFinite(energy[b])); // never diverges
    }

    // The impulse excites the network (block 0 carries the direct + early echoes).
    try std.testing.expect(energy[0] > 0);

    // The tail decays: total energy in the last quarter is well below the first.
    var first: f32 = 0;
    var last: f32 = 0;
    for (energy[0 .. blocks / 4]) |e| first += e;
    for (energy[blocks - blocks / 4 ..]) |e| last += e;
    try std.testing.expect(last < first); // a decaying reverb tail, not a sustain
    try std.testing.expect(last >= 0);
}
