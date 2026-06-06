const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});
const Sample = pan.Sample(f32);
const FRAME = 2048;
const HOP = 735;
const BINS = FRAME / 2 + 1;
const NB = 6;
const SampleRate = 44100;

// The structure of the extracted features per frame
const Spec = .{
    .dominant = pan.Scalar(u16),
    .amplitude = pan.Scalar(f32),
    .rms = pan.Scalar(f32),
    .centroid = pan.Scalar(f32),
    .rolloff = pan.Scalar(f32),
    .flux = pan.Scalar(f32),
    .flatness = pan.Scalar(f32),
    .contrast = pan.FeatureFrame(NB),
};
const Collect = pan.combinators.Concat(Spec);
const Row = pan.port.ConcatOut(Spec);

// The custom resynthesizer node that turns extracted features back into a spectrum
const GhostResynthesizer = struct {
    const Self = @This();

    pub const in_elem = Row;
    pub const out_elem = pan.Spectrum(f32, BINS);

    prng: std.Random.DefaultPrng = undefined,
    phases: [BINS]f32 = [_]f32{0} ** BINS,

    pub fn initialize(self: *Self, alloc: std.mem.Allocator) !void {
        _ = alloc;
        self.prng = std.Random.DefaultPrng.init(1337);
        var random = self.prng.random();
        for (&self.phases) |*p| {
            p.* = random.float(f32) * 2.0 * std.math.pi;
        }
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn process(self: *Self, in: []const Row, out: []pan.Spectrum(f32, BINS)) void {
        var random = self.prng.random();

        for (out, in) |*spec, row| {
            @memset(&spec.bin, .{ .re = 0, .im = 0 });

            // Extract the feature vector
            const dominant_bin = row.dominant.value;
            const amplitude = row.amplitude.value;
            const flatness = row.flatness.value;
            const centroid_bin = @as(usize, @intFromFloat(row.centroid.value));

            // Build a magnitude spectrum from scratch
            var mags = [_]f32{0} ** BINS;

            // 1. Tonal Component (Gaussian bump at dominant frequency)
            // The more "flat" the sound, the less pronounced the tonal component is.
            const tonal_strength = (1.0 - flatness) * amplitude * 1500.0;
            if (dominant_bin > 0 and dominant_bin < BINS) {
                // Spread the energy slightly around the dominant bin
                for (0..BINS) |i| {
                    const dist = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(dominant_bin));
                    mags[i] += tonal_strength * @exp(-(dist * dist) / 4.0);
                }
            }

            // 2. Noise Component (Broadband noise weighted by flatness and tilted by centroid)
            // A centroid higher up means we tilt the noise to the high end.
            const noise_strength = flatness * amplitude * 50.0;
            for (0..BINS) |i| {
                const raw_noise = random.float(f32) * noise_strength;
                // Simple tilt based on distance from centroid
                const dist_c = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(centroid_bin));
                // A very wide gaussian around the centroid to act as a bandpass/tilt
                const tilt = @exp(-(dist_c * dist_c) / 10000.0);
                mags[i] += raw_noise * tilt;
            }

            // 3. Reconstruct complex bins with Phase Vocoding
            for (0..BINS) |i| {
                const mag = mags[i];
                if (mag < 0.0001) continue;

                // Advance the phase for this bin's expected frequency
                const phase_advance = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) * (@as(f32, @floatFromInt(HOP)) / @as(f32, @floatFromInt(FRAME)));
                self.phases[i] += phase_advance;

                // Add random phase jitter to bins that are noise-dominated
                // If it's a pure tone, we want stable phase; if noise, random phase.
                if (flatness > 0.5) {
                    self.phases[i] += (random.float(f32) - 0.5) * std.math.pi * flatness;
                }

                self.phases[i] = @mod(self.phases[i], 2.0 * std.math.pi);
                const phase = self.phases[i];

                const re = mag * @cos(phase);
                const im = mag * @sin(phase);

                // 4. Frequency-domain Hann window convolution to prevent time-domain frame-edge clicks
                if (i > 0 and i < BINS - 1) {
                    spec.bin[i].re += 0.5 * re;
                    spec.bin[i].im += 0.5 * im;
                    spec.bin[i - 1].re -= 0.25 * re;
                    spec.bin[i - 1].im -= 0.25 * im;
                    spec.bin[i + 1].re -= 0.25 * re;
                    spec.bin[i + 1].im -= 0.25 * im;
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
    const io = init.io;
    const gpa = init.gpa;

    var args = std.process.Args.iterate(init.minimal.args);
    _ = args.next(); // skip program name

    const in_path = args.next() orelse {
        std.debug.print("Usage: example-ghost_autoencoder <in.raw> <out.raw>\n", .{});
        return error.Usage;
    };

    const out_path = args.next() orelse {
        std.debug.print("Usage: example-ghost_autoencoder <in.raw> <out.raw>\n", .{});
        return error.Usage;
    };

    // Load LPCM
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        in_path,
        gpa,
        .unlimited,
        comptime .of(pan.Sample(f32)),
        null,
    );
    defer gpa.free(bytes);
    const samples = std.mem.bytesAsSlice(pan.Sample(f32), bytes);

    std.debug.print("ghost_autoencoder: processing {s} ({d} samples)...\n", .{ in_path, samples.len });

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = HOP, .sample_rate = SampleRate });
    defer g.deinit();

    // 1. Feature Extraction Branch
    const src = try g.add(pan.io.LpcmSource(Num), .{ .data = samples, .loop = false });
    const stft = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const power = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});
    const dominant = try g.add(pan.feat.DominantBandHysteresis(Num, BINS), .{});
    const rms = try g.add(pan.feat.Rms(Num, BINS), .{});
    const centroid = try g.add(pan.feat.SpectralCentroid(Num, BINS), .{});
    const rolloff = try g.add(pan.feat.SpectralRolloff(Num, BINS), .{});
    const flux = try g.add(pan.feat.SpectralFlux(Num, BINS), .{});
    const flatness = try g.add(pan.feat.SpectralFlatness(Num, BINS), .{});
    const contrast = try g.add(pan.feat.SpectralContrast(Num, BINS, NB), .{});

    const framer = try g.add(pan.spectral.Framer(Num, FRAME, HOP), .{});
    const envelope = try g.add(pan.feat.BallisticEnvelope(Num, FRAME), .{});

    // Bottleneck: Combine all features
    const collect = try g.add(Collect, .{});

    // 2. Synthesis Branch
    const synth = try g.add(GhostResynthesizer, .{});
    const istft = try g.add(pan.spectral.iStft(Num, FRAME, HOP), .{});
    const sink = try g.add(MemSink, .{ .capacity_hint = samples.len });

    // WIRING
    try g.connect(src, stft);
    try g.connect(stft, power);
    inline for (.{ dominant, rms, centroid, rolloff, flux, flatness, contrast }) |node| {
        try g.connect(power, node);
    }
    try g.connect(src, framer);
    try g.connect(framer, envelope);

    // Wire to Concat
    try g.connect(dominant, collect.in.dominant);
    try g.connect(envelope, collect.in.amplitude);
    try g.connect(rms, collect.in.rms);
    try g.connect(centroid, collect.in.centroid);
    try g.connect(rolloff, collect.in.rolloff);
    try g.connect(flux, collect.in.flux);
    try g.connect(flatness, collect.in.flatness);
    try g.connect(contrast, collect.in.contrast);

    // Wire Concat to Resynthesizer, then to iStft, then out
    try g.connect(collect, synth);
    try g.connect(synth, istft);
    try g.connect(istft, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();

    // Run until exhaustion of the input LPCM source
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const output_bytes = std.mem.sliceAsBytes(sink.instance().frames());
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = output_bytes,
    });

    std.debug.print("Wrote ghost sonification to {s}\n", .{out_path});
}
