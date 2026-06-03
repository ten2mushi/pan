//! B≡C differential — through the bound executor.
//!
//! The commit pass assigns buffer ids two ways: `.per_edge` (Mode B — one private
//! buffer per produced value, the obviously-correct baseline) and `.colored`
//! (Mode C — the shipped pool that reuses a buffer the moment its last reader has
//! run). The executor binds the SAME kernels and instances over either plan, so
//! rendering a chain under both modes must produce **bit-identical** output: the
//! colored pool is only a storage optimization, never a change in what is
//! computed. A divergence is a colorer / pool-layout bug, not numerics — so the
//! comparison is bit-exact, never allclose.
//!
//! This is the executor-level B≡C (the P3 commit pass already differenced the two
//! footprints/buffer maps; here the two plans actually RUN and are compared at the
//! sink). Verified against zig 0.16.0 with the zig-0-16 skill loaded.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const num = pan.numericFor(.f32, .{});
const Sample = pan.Sample(f32);
const Stereo = pan.types.Frame(f32, .stereo);

const Gain = pan.filters.Gain(num);
const Biquad = pan.filters.Biquad(num);
const Pan = pan.spatial.ConstantPowerPan(num);

const BufSource = struct {
    data: [*]const Sample = undefined,
    pub fn process(self: *@This(), out: []Sample) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const StereoSink = struct {
    dest: [*]Stereo = undefined,
    pub fn process(self: *@This(), in: []const Stereo) void {
        @memcpy(self.dest[0..in.len], in);
    }
};
const MonoSink = struct {
    dest: [*]Sample = undefined,
    pub fn process(self: *@This(), in: []const Sample) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

fn chainGraph(comptime N: usize) pan.graph.Graph {
    var gg = pan.graph.Graph.empty;
    gg.block_size = N;
    const src = gg.add(BufSource);
    const gain = gg.add(Gain);
    const biquad = gg.add(Biquad);
    const panner = gg.add(Pan);
    const sink = gg.add(StereoSink);
    gg.connect(pan.port.MapOutPort(BufSource), src, 0, pan.port.MapInPort(Gain), gain, 0);
    gg.connect(pan.port.MapOutPort(Gain), gain, 0, pan.port.MapInPort(Biquad), biquad, 0);
    gg.connect(pan.port.MapOutPort(Biquad), biquad, 0, pan.port.MapInPort(Pan), panner, 0);
    gg.connect(pan.port.MapOutPort(Pan), panner, 0, pan.port.MapInPort(StereoSink), sink, 0);
    return gg;
}

fn viewBits(frames: []const Stereo) []const f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(frames)));
}

test "B≡C: colored pool ≡ per-edge baseline through the executor, bit-exact (gain→biquad→pan)" {
    const N = 64;
    const g = comptime chainGraph(N);

    var input: [N]Sample = undefined;
    h.fillNoise(&input, 0xBEEF);

    const Colored = pan.engine.ExecutorMode(g, &.{ BufSource, Gain, Biquad, Pan, StereoSink }, .colored);
    const PerEdge = pan.engine.ExecutorMode(g, &.{ BufSource, Gain, Biquad, Pan, StereoSink }, .per_edge);

    // Identical instance configuration for both modes.
    const gain_coef: f32 = 0.7;
    const bq = pan.filters.Coeffs(f32){ .b0 = 0.3, .b1 = 0.1, .a1 = -0.5 };
    const pan_pos: f32 = 0.3;

    var out_c: [N]Stereo = undefined;
    var out_b: [N]Stereo = undefined;

    var colored: Colored = .{ .instances = .{
        .{ .data = &input }, .{ .gain = gain_coef }, .{ .coeffs = bq }, .{ .pan = pan_pos }, .{ .dest = &out_c },
    } };
    var per_edge: PerEdge = .{ .instances = .{
        .{ .data = &input }, .{ .gain = gain_coef }, .{ .coeffs = bq }, .{ .pan = pan_pos }, .{ .dest = &out_b },
    } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    colored.render(token);
    per_edge.render(token);

    // The two plans differ only in buffer assignment; the sink output must match
    // to the bit.
    try h.bitExact(f32, viewBits(&out_c), viewBits(&out_b));

    // And the colored pool is no larger than the per-edge baseline (the point of
    // coloring) — a structural sanity check on the differential.
    try std.testing.expect(Colored.committed.footprint_bytes <= PerEdge.committed.footprint_bytes);
}

test "B≡C: a 5-stage mono chain ≡ across modes, and colored reuses buffers" {
    const N = 32;
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(BufSource);
        const a = gg.add(Gain);
        const b = gg.add(Gain);
        const c = gg.add(Gain);
        const sink = gg.add(MonoSink);
        gg.connect(pan.port.MapOutPort(BufSource), src, 0, pan.port.MapInPort(Gain), a, 0);
        gg.connect(pan.port.MapOutPort(Gain), a, 0, pan.port.MapInPort(Gain), b, 0);
        gg.connect(pan.port.MapOutPort(Gain), b, 0, pan.port.MapInPort(Gain), c, 0);
        gg.connect(pan.port.MapOutPort(Gain), c, 0, pan.port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };

    var input: [N]Sample = undefined;
    h.fillNoise(&input, 7);
    var out_c: [N]Sample = undefined;
    var out_b: [N]Sample = undefined;

    const Colored = pan.engine.ExecutorMode(g, &.{ BufSource, Gain, Gain, Gain, MonoSink }, .colored);
    const PerEdge = pan.engine.ExecutorMode(g, &.{ BufSource, Gain, Gain, Gain, MonoSink }, .per_edge);
    var colored: Colored = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.9 }, .{ .gain = 0.8 }, .{ .gain = 1.1 }, .{ .dest = &out_c } } };
    var per_edge: PerEdge = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.9 }, .{ .gain = 0.8 }, .{ .gain = 1.1 }, .{ .dest = &out_b } } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    colored.render(token);
    per_edge.render(token);

    try h.bitExact(f32, h.sampleValues(&out_c), h.sampleValues(&out_b));
    // Colored ping-pongs (2 buffers) where per-edge keeps all 4 mono values live.
    try std.testing.expect(Colored.committed.pool_buffer_count < PerEdge.committed.pool_buffer_count);
}
