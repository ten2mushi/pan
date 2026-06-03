//! paranoid_poison_test — the active paranoid NaN-poison net over the colored
//! executor (`src/engine.zig ParanoidExecutor` + `src/commit.zig buffer_last_use`).
//!
//! Paranoid mode fills every POOL buffer with a NaN bit pattern the instant its
//! live range ends, so a colorer / in-place-coalescing bug that reads a buffer past
//! its last legitimate reader surfaces as a NaN propagating to the sink instead of
//! as silently-stale audio. The success criterion (catalog §7.5 / memory-model §9)
//! is the converse: a CORRECT graph renders with NO NaN reaching the sink. We pin:
//!
//!   1. a deep in-place-COALESCING chain (single-consumer `aliasing_safe` gains,
//!      which the colorer collapses onto one buffer) renders under paranoid mode
//!      bit-identically to the per-edge baseline, with a finite (NaN-free) sink —
//!      the poison of retired buffers never corrupts a live read;
//!   2. a graph-level FEEDBACK comb renders under paranoid mode with a finite sink
//!      AND a tail that still carries energy many blocks later — proving the
//!      persistent feedback `z⁻¹` buffer (pool tail) is NEVER poisoned (its
//!      `buffer_last_use` sentinel is `-1`), so the loop survives the callback.
//!
//! COMPARISON MODE: (1) is pan-vs-pan ⇒ BIT-EXACT (paranoid-colored ≡ per-edge);
//! (2) is ≈ behavioural (finiteness + a surviving tail). Verified against zig
//! 0.16.0 (zig-0-16 skill loaded per Rules 13/14).

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const port = pan.port;
const types = pan.types;
const numeric = pan.numeric;
const filters = pan.filters;

const Sample = types.Sample;
const f32num = numeric.numericFor(.f32, .{});

const N = 16;

const MonoSource = struct {
    const Self = @This();
    data: [*]const Sample(f32) = undefined,
    pub fn process(self: *Self, out: []Sample(f32)) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const MonoSink = struct {
    const Self = @This();
    dest: [*]Sample(f32) = undefined,
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

const Gain = filters.Gain(f32num);

fn anyNaN(buf: []const Sample(f32)) bool {
    for (buf) |s| if (!std.math.isFinite(s.ch[0])) return true;
    return false;
}

test "paranoid mode: a coalescing gain chain renders NaN-free and ≡ the per-edge baseline" {
    // source → g0 → g1 → g2 → sink. The three single-consumer aliasing_safe gains
    // coalesce onto ONE pool buffer; paranoid poison fills it with NaN when it
    // retires, so a premature-poison or reuse bug would surface as a NaN sink.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const a = gg.add(Gain);
        const b = gg.add(Gain);
        const c = gg.add(Gain);
        const snk = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), a, 0);
        gg.connect(port.MapOutPort(Gain), a, 0, port.MapInPort(Gain), b, 0);
        gg.connect(port.MapOutPort(Gain), b, 0, port.MapInPort(Gain), c, 0);
        gg.connect(port.MapOutPort(Gain), c, 0, port.MapInPort(MonoSink), snk, 0);
        break :blk gg;
    };

    var input: [N]Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @as(f32, @floatFromInt(i)) - 7.5; // signed ramp

    const blocks = [_]type{ MonoSource, Gain, Gain, Gain, MonoSink };

    // Paranoid + colored.
    var paranoid_out: [N]Sample(f32) = undefined;
    const Paranoid = pan.ParanoidExecutor(g, &blocks, .colored);
    var pexec: Paranoid = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = 0.5 },
        .{ .gain = 0.5 },
        .{ .gain = 0.5 },
        .{ .dest = &paranoid_out },
    } };

    // Per-edge baseline (no coalescing, no poison) — the obviously-correct oracle.
    var baseline_out: [N]Sample(f32) = undefined;
    const Baseline = pan.ExecutorMode(g, &blocks, .per_edge);
    var bexec: Baseline = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = 0.5 },
        .{ .gain = 0.5 },
        .{ .gain = 0.5 },
        .{ .dest = &baseline_out },
    } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    // Render a few times so a poisoned buffer reused across renders would surface.
    for (0..4) |_| {
        pexec.render(token);
        bexec.render(token);
    }

    // No NaN reaches the sink under paranoid mode.
    try std.testing.expect(!anyNaN(&paranoid_out));
    // Paranoid-colored ≡ per-edge baseline, bit-exact (the colorer is faithful).
    for (paranoid_out, baseline_out) |p, b| try std.testing.expectEqual(b.ch[0], p.ch[0]);
    // And the value is the expected triple-gained ramp (× 0.125).
    for (paranoid_out, input) |p, x| try std.testing.expectApproxEqAbs(x.ch[0] * 0.125, p.ch[0], 1e-6);
}

// --- feedback graph: the persistent z⁻¹ buffer must NOT be poisoned -----------

/// An impulse source: a unit impulse on the first render, silence after.
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

/// A two-input summer: out = dry + wet (the feedback injection point).
const Sum2 = struct {
    const Self = @This();
    pub fn process(self: *Self, dry: []const Sample(f32), wet: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (dry, wet, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
    }
};

const FbDelay = pan.DelayLine(Sample(f32), 24);

const EnergySink = struct {
    const Self = @This();
    energy: f32 = 0,
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        var e: f32 = 0;
        for (in) |x| e += x.ch[0] * x.ch[0];
        self.energy = e;
    }
};

test "paranoid mode: a feedback comb's persistent z⁻¹ tail survives (never poisoned)" {
    // impulse → Sum → Delay → Gain → sink, with Gain → Sum feedback. The Gain
    // output feeds the feedback read-side, so it is a PERSISTENT (pool-excluded)
    // value with buffer_last_use = -1 — paranoid mode must leave it intact across
    // callbacks, or the decaying tail would turn to NaN / die.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(ImpulseSource);
        const sum = gg.add(Sum2);
        const dly = gg.add(FbDelay);
        const gain = gg.add(Gain);
        const snk = gg.add(EnergySink);
        gg.connect(port.MapOutPort(ImpulseSource), src, 0, port.MapInPortAt(Sum2, 0), sum, 0);
        gg.connect(port.MapOutPort(Sum2), sum, 0, port.MapInPort(FbDelay), dly, 0);
        gg.connect(port.MapOutPort(FbDelay), dly, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(EnergySink), snk, 0);
        gg.connectFeedback(port.MapOutPort(Gain), gain, 0, port.MapInPortAt(Sum2, 1), sum, 1);
        break :blk gg;
    };

    const Paranoid = pan.ParanoidExecutor(g, &.{ ImpulseSource, Sum2, FbDelay, Gain, EnergySink }, .colored);
    // The persistent feedback tail is a real pool-tail buffer.
    try std.testing.expect(Paranoid.committed.persistent_bytes > 0);

    var exec: Paranoid = .{ .instances = .{ .{}, .{}, .{}, .{ .gain = 0.8 }, .{} } };
    const token = pan.enterRealtimeThread();
    defer token.leave();

    const blocks = 32;
    var energy: [blocks]f32 = undefined;
    for (0..blocks) |b| {
        exec.render(token);
        energy[b] = exec.instances[4].energy;
        try std.testing.expect(std.math.isFinite(energy[b])); // no NaN from poison
    }

    // The feedback actually recirculates: energy appears AFTER the first echo
    // emerges (proving the persistent z⁻¹ buffer carried the loop, un-poisoned).
    var tail_energy: f32 = 0;
    for (energy[2..]) |e| tail_energy += e;
    try std.testing.expect(tail_energy > 0);
}
