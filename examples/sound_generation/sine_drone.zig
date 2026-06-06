const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});
const Sample = pan.Sample(f32);
const BlockSize = 64;
const SampleRate = 48000;
const DurationSecs = 5;

// Memory sink to collect raw f32 samples to memory and then save them
const MemSink = struct {
    const Self = @This();
    pub const growable_sink: bool = true;

    capacity_hint: usize = 0,
    samples: std.ArrayList(Sample) = .empty,
    gpa: std.mem.Allocator = undefined,

    pub fn initialize(self: *Self, alloc: std.mem.Allocator) !void {
        self.gpa = alloc;
        try self.samples.ensureTotalCapacity(alloc, self.capacity_hint);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.samples.deinit(alloc);
    }

    pub fn process(self: *Self, in: []const Sample) void {
        self.samples.appendSlice(self.gpa, in) catch unreachable;
    }

    pub fn frames(self: *const Self) []const Sample {
        return self.samples.items;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = std.process.Args.iterate(init.minimal.args);
    _ = args.next(); // skip program name
    const out_path = args.next() orelse {
        std.debug.print("Usage: example-sine_drone <out.raw>\n", .{});
        return error.Usage;
    };

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = BlockSize, .sample_rate = SampleRate });
    defer g.deinit();

    const osc = try g.add(pan.gen.Sine, .{ .sample_rate = SampleRate });

    // An LFO to modulate the frequency (vibrato)
    const lfo = try g.add(pan.gen.Lfo, .{
        .increment = 2.0 / 48000.0, // 2.0 Hz sweep
        .amplitude = 10,
        .offset = 440,
        .waveform = .sine,
    });

    const gain = try g.add(pan.filters.Gain(Num), .{ .gain = 0.5 });

    const total_blocks = (SampleRate * DurationSecs) / BlockSize;
    const sink = try g.add(MemSink, .{ .capacity_hint = total_blocks * BlockSize });

    try g.connect(lfo, osc.param.freq);
    try g.connect(osc, gain);
    try g.connect(gain, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();

    try eng.runToCompletion(.{ .clock = .{ .wall_clock_timer = 60 }, .max_blocks = total_blocks });

    const output_bytes = std.mem.sliceAsBytes(sink.instance().frames());
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = output_bytes,
    });

    std.debug.print("Wrote {s} ({d} seconds, {d} Hz)\n", .{ out_path, DurationSecs, SampleRate });
}
