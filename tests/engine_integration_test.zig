//! Engine ↔ DSP-library integration tests.
//!
//! These end-to-end tests bind the comptime `Executor` over graphs that contain
//! real DSP-library blocks (`filters.Gain`, `time.DelayLine`). The engine itself
//! lives in the DSP-agnostic core module and therefore cannot import the node
//! libraries; these integration checks live here in the test harness, which sees
//! both halves through the `pan` umbrella, so the engine ↔ library coupling is
//! exercised without a core → dsp edge.

const std = @import("std");
const pan = @import("pan");

const types = pan.types;
const graph = pan.graph;
const port = pan.port;
const commit = pan.commit;
const Executor = pan.Executor;
const enterRealtimeThread = pan.enterRealtimeThread;

test "Executor binds kernels and renders a source→gain→sink chain end-to-end" {
    const filters = pan.filters;
    const numeric = pan.numeric;
    const num = comptime numeric.numericFor(.f32, .{});

    // A source that fills its output from a preloaded buffer (a Map Source).
    const BufSource = struct {
        const Self = @This();
        data: [*]const types.Sample(f32) = undefined,
        pub fn process(self: *Self, out: []types.Sample(f32)) void {
            @memcpy(out, self.data[0..out.len]);
        }
    };
    // A sink that copies its input to a destination buffer.
    const BufSink = struct {
        const Self = @This();
        dest: [*]types.Sample(f32) = undefined,
        pub fn process(self: *Self, in: []const types.Sample(f32)) void {
            @memcpy(self.dest[0..in.len], in);
        }
    };
    const Gain = filters.Gain(num);

    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 8;
        const src = gg.add(BufSource);
        const gain = gg.add(Gain);
        const sink = gg.add(BufSink);
        gg.connect(port.MapOutPort(BufSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(BufSink), sink, 0);
        break :blk gg;
    };

    var input: [8]types.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var output: [8]types.Sample(f32) = undefined;

    const Exec = Executor(g, &.{ BufSource, Gain, BufSink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = 0.5 },
        .{ .dest = &output },
    } };

    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    for (input, output) |x, y| try std.testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
    try std.testing.expect(!exec.telemetry().fault);
}

// ===========================================================================
// Graph-level feedback execution (P6): a DelayLine-in-a-cycle runs through the
// comptime Executor over the persistent z⁻¹ tail, decays, and stays finite.
// ===========================================================================

const FbSample = types.Sample(f32);

/// Mono source that copies a backing store into its output (a zero-input Map).
const FbSource = struct {
    data: [*]const FbSample = undefined,
    pub fn process(self: *@This(), out: []FbSample) void {
        @memcpy(out, self.data[0..out.len]);
    }
};

/// Two-input feedback summer: `out = dry + g·wet`. The first port is the forward
/// (dry) input; the second is the feedback (wet) z⁻¹ value, read from the
/// persistent buffer the loop's delay element wrote last block.
const FbSum = struct {
    g: f32 = 0.5,
    pub fn process(self: *@This(), dry: []const FbSample, wet: []const FbSample, out: []FbSample) void {
        for (dry, wet, out) |d, w, *y| y.ch[0] = d.ch[0] + self.g * w.ch[0];
    }
};

const FbSink = struct {
    dest: [*]FbSample = undefined,
    pub fn process(self: *@This(), in: []const FbSample) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

test "graph-level feedback: a DelayLine-in-a-cycle decays through the persistent z⁻¹ tail" {
    const tmod = pan.time;
    const N = 4;
    const Delay = tmod.DelayLine(FbSample, N); // one-block delay element in the loop

    // Topology: src → sum.in0 ; sum → {delay, sink} ; delay → sum.in1 (feedback).
    // The summer's output is the wet tap (to sink) AND the loop signal (to delay);
    // the delay's output feeds back into the summer's second input. The delay's
    // value feeds only the feedback, so it is a persistent (pool-excluded) buffer.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(FbSource);
        const sum = gg.add(FbSum);
        const delay = gg.add(Delay);
        const sink = gg.add(FbSink);
        gg.connect(port.MapOutPort(FbSource), src, 0, port.MapInPortAt(FbSum, 0), sum, 0);
        gg.connect(port.MapOutPort(FbSum), sum, 0, port.MapInPort(Delay), delay, 0);
        gg.connect(port.MapOutPort(FbSum), sum, 0, port.MapInPort(FbSink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Delay), delay, 0, port.MapInPortAt(FbSum, 1), sum, 1);
        break :blk gg;
    };

    // The SCC {sum, delay} contains the delay element ⇒ commits (not DelayFreeLoop).
    const plan = comptime try commit.commitComptime(g);
    try std.testing.expect(plan.persistent_bytes >= N * @sizeOf(FbSample)); // a z⁻¹ tail exists
    try std.testing.expect(plan.persistent_bytes > 0);

    const Exec = Executor(g, &.{ FbSource, FbSum, Delay, FbSink });
    var impulse: [N]FbSample = @splat(.{ .ch = .{0} });
    impulse[0] = .{ .ch = .{1} }; // unit impulse on block 0
    var silence: [N]FbSample = @splat(.{ .ch = .{0} });
    var out: [N]FbSample = undefined;

    var exec: Exec = .{ .instances = .{
        .{ .data = &impulse },
        .{ .g = 0.5 },
        .{},
        .{ .dest = &out },
    } };
    const token = enterRealtimeThread();
    defer token.leave();

    // Block 0: the impulse appears immediately (the dry path); the loop has not
    // recirculated yet (the persistent z⁻¹ tail started silent).
    exec.render(token);
    try std.testing.expectEqual(@as(f32, 1), out[0].ch[0]);
    try std.testing.expect(!exec.telemetry().fault);

    // Switch the source to silence and keep rendering: the loop must keep echoing
    // (the persistent tail carries the recirculating signal across callbacks) and
    // the energy must DECAY (|g|<1, stable) and stay finite.
    exec.instances[0].data = &silence;
    var prev_peak: f32 = 1;
    var saw_echo = false;
    for (0..8) |_| {
        exec.render(token);
        var peak: f32 = 0;
        for (out) |s| {
            try std.testing.expect(std.math.isFinite(s.ch[0]));
            peak = @max(peak, @abs(s.ch[0]));
        }
        if (peak > 0) saw_echo = true;
        try std.testing.expect(peak <= prev_peak + 1e-6); // non-growing (stable)
        if (peak > 0) prev_peak = peak;
    }
    try std.testing.expect(saw_echo); // the feedback path actually carried signal
    try std.testing.expect(!exec.telemetry().fault);
}
