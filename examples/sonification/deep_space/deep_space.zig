const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});
const Sample = pan.Sample(f32);
const FRAME = 4096;
const HOP = 1024;
const BINS = FRAME / 2 + 1;
const SampleRate = 48000;

const START_BIN = 3;
const NUM_BINS = 83;
const TOTAL_COLS = 1000; // Expected number of columns from the preprocessed data

// 1. A Source block that outputs `Spectrum(f32, BINS)`.
const ImageSpectrumSource = struct {
    const Self = @This();

    // Rate properties
    pub const in_elem = void;
    pub const out_elem = pan.Spectrum(f32, BINS);
    pub const out_per_in = .{ 1, 0 }; // 1 out per 0 in
    pub const algorithmic_latency = 0;

    data: []const f32 = &.{},
    current_col: usize = 0,
    prng: std.Random.DefaultPrng = undefined,
    phases: [BINS]f32 = [_]f32{0} ** BINS,

    pub fn initialize(self: *Self, alloc: std.mem.Allocator) !void {
        _ = alloc;
        self.prng = std.Random.DefaultPrng.init(12345);
        var random = self.prng.random();
        for (&self.phases) |*p| {
            p.* = random.float(f32) * 2.0 * std.math.pi;
        }
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn pull(self: *Self, want: usize, out: []pan.Spectrum(f32, BINS)) void {
        _ = want;

        for (out) |*spec| {
            @memset(&spec.bin, .{ .re = 0, .im = 0 });

            if (self.current_col < TOTAL_COLS) {
                const start_idx = self.current_col * NUM_BINS;
                const end_idx = start_idx + NUM_BINS;
                if (end_idx <= self.data.len) {
                    const col_data = self.data[start_idx..end_idx];
                    for (col_data, 0..) |mag, i| {
                        const bin_idx = START_BIN + i;

                        // Phase vocoder fundamental: to maintain a continuous sinusoid
                        // across overlap-add frames, the phase must advance by the
                        // expected amount for this bin's frequency.
                        // expected advance = 2 * pi * k * HOP / FRAME
                        const phase_advance = 2.0 * std.math.pi * @as(f32, @floatFromInt(bin_idx)) * (@as(f32, @floatFromInt(HOP)) / @as(f32, @floatFromInt(FRAME)));
                        self.phases[bin_idx] += phase_advance;
                        // Use @mod to wrap phase correctly; phase_advance can be much larger than 2*pi
                        self.phases[bin_idx] = @mod(self.phases[bin_idx], 2.0 * std.math.pi);

                        const phase = self.phases[bin_idx];
                        const re = mag * @cos(phase) * 50.0;
                        const im = mag * @sin(phase) * 50.0;

                        // Apply a Hann window in the frequency domain (convolution with [-0.25, 0.5, -0.25]).
                        // Since iStft does not apply a synthesis window, synthesizing pure bins creates
                        // rectangular time-domain frames that cause step discontinuities when amplitude changes.
                        // This frequency-domain convolution tapers the time-domain frame to 0 at its edges!
                        spec.bin[bin_idx].re += 0.5 * re;
                        spec.bin[bin_idx].im += 0.5 * im;
                        spec.bin[bin_idx - 1].re -= 0.25 * re;
                        spec.bin[bin_idx - 1].im -= 0.25 * im;
                        spec.bin[bin_idx + 1].re -= 0.25 * re;
                        spec.bin[bin_idx + 1].im -= 0.25 * im;
                    }
                    self.current_col += 1;
                }
            }
        }
    }
};

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

    const in_path = args.next() orelse {
        std.debug.print("Usage: example-deep_space <in.raw> <out.raw>\n", .{});
        return error.Usage;
    };

    const out_path = args.next() orelse {
        std.debug.print("Usage: example-deep_space <in.raw> <out.raw>\n", .{});
        return error.Usage;
    };

    // Load preprocessed matrix into memory
    const data_bytes = try std.Io.Dir.cwd().readFileAllocOptions(
        init.io,
        in_path,
        gpa,
        .unlimited,
        comptime .of(f32),
        null,
    );
    defer gpa.free(data_bytes);
    const data = std.mem.bytesAsSlice(f32, data_bytes);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = HOP, .sample_rate = SampleRate });
    defer g.deinit();

    const src = try g.add(ImageSpectrumSource, .{ .data = data });
    const istft = try g.add(pan.spectral.iStft(Num, FRAME, HOP), .{});
    const sink = try g.add(MemSink, .{ .capacity_hint = TOTAL_COLS * HOP });

    try g.connect(src, istft);
    try g.connect(istft, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();

    try eng.runToCompletion(.{ .clock = .{ .wall_clock_timer = 60 }, .max_blocks = TOTAL_COLS });

    const output_bytes = std.mem.sliceAsBytes(sink.instance().frames());
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = output_bytes,
    });

    std.debug.print("Wrote sonification to {s}\n", .{out_path});
}
