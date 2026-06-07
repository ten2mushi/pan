//! examples/animation/analyze.zig — the pan Analyzer that feeds the 3-D viewer.
//!
//! Builds the canonical pan Analyzer pull graph over a decoded LPCM file and emits
//! the per-frame feature matrix the WebGL viewer consumes. ALL feature extraction
//! happens here, in the library; the browser only draws.
//!
//! MONO graph (one row of features per analysis hop):
//!
//!     LpcmSource ──┬─► Stft ─► PowerSpectrum ─► { dominant-band (COLOR),
//!                  │                              rms, centroid, rolloff, flux }
//!                  │                            + the full power spectrum
//!                  └─► Framer ─► BallisticEnvelope (the principled 0..1 AMPLITUDE)
//!                                          │
//!     all feature streams ────────────────┴─► Concat ─► FeatureCollectorSink
//!
//! STEREO graph (--stereo): two independent same-rate STFT branches off a left and a
//! right LPCM source, so the matrix carries BOTH per-bin power spectra
//! (full_spectrum_l / full_spectrum_r). The viewer recovers a mono spectrum (L+R)
//! for peak detection and, for each spectral peak, its stereo pan position
//! (|L|−|R|)/(|L|+|R|) — placing every harmonic where it actually sits in the stereo
//! field. The scalar descriptors (dominant / amplitude / centroid / rolloff / flux)
//! are taken off the left channel.
//!
//! The hop is chosen so one analysis frame lands every 1/60 s at the canonical
//! 44.1 kHz analysis rate the decoder resamples every input to: 44100/60 = 735
//! samples per hop, 60 hops per second — the visualization's frame cadence.
//!
//! DYNAMIC GRANULARITY. The FFT window length (`frame`) is a runtime argument,
//! selected from a fixed comptime set {1024, 2048, 4096, 8192}. A larger window
//! gives finer frequency resolution at the cost of coarser time resolution and a
//! bigger feature matrix. Because the window is a comptime parameter of the
//! STFT/Framer blocks, the analysis body is a generic function instantiated once
//! per allowed window size and dispatched on the runtime argument.
//!
//! The collected rows flatten to a native-endian, row-major `f32` matrix: one row
//! per hop, columns in `Concat` field-declaration order. A companion JSON sidecar
//! records the parameters and column layout so the viewer reshapes the headerless
//! matrix without any in-band header.
//!
//! Usage:
//!   analyze <input.f32> <sample_rate> <out_prefix> [frame]
//!   analyze --stereo <left.f32> <right.f32> <sample_rate> <out_prefix> [frame]

const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});
/// One analysis frame every `HOP` input samples. 44100/60 = 735 ⇒ exactly 60
/// feature frames per second of audio (the visualization's frame cadence).
const HOP = 735;
/// Analysis rows produced per render block — only a buffer-pool sizing knob.
const BLOCK = 64;
/// The analysis sample rate the scripts/ decoder resamples every input to.
const ANALYSIS_RATE = 44_100;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = std.process.Args.iterate(init.minimal.args);
    _ = args.next(); // program name
    const a0 = args.next() orelse return usage();

    if (std.mem.eql(u8, a0, "--stereo")) {
        const l_path = args.next() orelse return usage();
        const r_path = args.next() orelse return usage();
        const rate_arg = args.next() orelse return usage();
        const out_prefix = args.next() orelse return usage();
        const sample_rate = std.fmt.parseInt(u32, rate_arg, 10) catch return usage();
        const frame = parseFrame(&args) orelse return usage();
        switch (frame) {
            1024 => try runStereo(1024, io, gpa, l_path, r_path, out_prefix, sample_rate),
            2048 => try runStereo(2048, io, gpa, l_path, r_path, out_prefix, sample_rate),
            4096 => try runStereo(4096, io, gpa, l_path, r_path, out_prefix, sample_rate),
            8192 => try runStereo(8192, io, gpa, l_path, r_path, out_prefix, sample_rate),
            else => return badFrame(frame),
        }
    } else {
        const in_path = a0;
        const rate_arg = args.next() orelse return usage();
        const out_prefix = args.next() orelse return usage();
        const sample_rate = std.fmt.parseInt(u32, rate_arg, 10) catch return usage();
        const frame = parseFrame(&args) orelse return usage();
        switch (frame) {
            1024 => try runMono(1024, io, gpa, in_path, out_prefix, sample_rate),
            2048 => try runMono(2048, io, gpa, in_path, out_prefix, sample_rate),
            4096 => try runMono(4096, io, gpa, in_path, out_prefix, sample_rate),
            8192 => try runMono(8192, io, gpa, in_path, out_prefix, sample_rate),
            else => return badFrame(frame),
        }
    }
}

fn parseFrame(args: anytype) ?usize {
    if (args.next()) |fa| return std.fmt.parseInt(usize, fa, 10) catch null;
    return 2048;
}

fn badFrame(frame: usize) error{Usage} {
    std.debug.print("frame must be one of 1024 / 2048 / 4096 / 8192 (got {d})\n", .{frame});
    return error.Usage;
}

/// Read a raw native-endian mono f32 LPCM file into bytes aligned for `Sample(f32)`
/// (so they reinterpret to `[]Sample(f32)` with no copy). The caller frees the
/// returned byte slice and reinterprets via `std.mem.bytesAsSlice`.
fn readBytes(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]align(@alignOf(pan.Sample(f32))) u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .unlimited,
        comptime .of(pan.Sample(f32)),
        null,
    );
}

// ===========================================================================
// MONO
// ===========================================================================

fn runMono(
    comptime FRAME: usize,
    io: std.Io,
    gpa: std.mem.Allocator,
    in_path: []const u8,
    out_prefix: []const u8,
    sample_rate: u32,
) !void {
    const BINS = FRAME / 2 + 1;

    const Spec = .{
        .full_spectrum = pan.FeatureFrame(BINS),
        .dominant = pan.Scalar(u16),
        .amplitude = pan.Scalar(f32),
        .rms = pan.Scalar(f32),
        .centroid = pan.Scalar(f32),
        .rolloff = pan.Scalar(f32),
        .flux = pan.Scalar(f32),
    };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.port.ConcatOut(Spec);

    const bytes = try readBytes(io, gpa, in_path);
    defer gpa.free(bytes);
    const samples = std.mem.bytesAsSlice(pan.Sample(f32), bytes);
    std.debug.print(
        "analyze: {s} — {d} samples ({d:.1} s @ {d} Hz), FRAME={d} HOP={d} BINS={d}\n",
        .{ in_path, samples.len, @as(f64, @floatFromInt(samples.len)) / @as(f64, @floatFromInt(sample_rate)), sample_rate, FRAME, HOP, BINS },
    );

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = BLOCK });
    defer g.deinit();

    const src = try g.add(pan.io.LpcmSource(Num), .{ .data = samples, .loop = false });
    const stft = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const power = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});
    const dominant = try g.add(pan.feat.DominantBandHysteresis(Num, BINS), .{});
    const rms = try g.add(pan.feat.Rms(Num, BINS), .{});
    const centroid = try g.add(pan.feat.SpectralCentroid(Num, BINS), .{});
    const rolloff = try g.add(pan.feat.SpectralRolloff(Num, BINS), .{});
    const flux = try g.add(pan.feat.SpectralFlux(Num, BINS), .{});
    const framer = try g.add(pan.spectral.Framer(Num, FRAME, HOP), .{});
    const envelope = try g.add(pan.feat.BallisticEnvelope(Num, FRAME), .{});
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 1 + samples.len / HOP });

    try g.connect(src, stft);
    try g.connect(stft, power);
    inline for (.{ dominant, rms, centroid, rolloff, flux }) |node| try g.connect(power, node);
    try g.connect(src, framer);
    try g.connect(framer, envelope);
    try g.connect(power, collect.in.full_spectrum);
    try g.connect(dominant, collect.in.dominant);
    try g.connect(envelope, collect.in.amplitude);
    try g.connect(rms, collect.in.rms);
    try g.connect(centroid, collect.in.centroid);
    try g.connect(rolloff, collect.in.rolloff);
    try g.connect(flux, collect.in.flux);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    if (sink.instance().overflowed) return error.FeatureSinkOverflowed;
    const cols = comptime pan.featureMatrixColumns(Row);
    std.debug.print("analyze: collected {d} feature frames × {d} columns\n", .{ rows.len, cols });

    try writeMatrixAndSidecar(io, gpa, out_prefix, rows, FRAME, BINS, cols, sample_rate, false);
}

// ===========================================================================
// STEREO — two same-rate STFT branches; the matrix carries both spectra.
// ===========================================================================

fn runStereo(
    comptime FRAME: usize,
    io: std.Io,
    gpa: std.mem.Allocator,
    l_path: []const u8,
    r_path: []const u8,
    out_prefix: []const u8,
    sample_rate: u32,
) !void {
    const BINS = FRAME / 2 + 1;

    // Column order: both spectra lead, then the scalar descriptors (off the left
    // channel). The viewer detects stereo by the presence of the two spectrum
    // columns and computes pan = (|L|−|R|)/(|L|+|R|) per peak.
    const Spec = .{
        .full_spectrum_l = pan.FeatureFrame(BINS),
        .full_spectrum_r = pan.FeatureFrame(BINS),
        .dominant = pan.Scalar(u16),
        .amplitude = pan.Scalar(f32),
        .rms = pan.Scalar(f32),
        .centroid = pan.Scalar(f32),
        .rolloff = pan.Scalar(f32),
        .flux = pan.Scalar(f32),
    };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.port.ConcatOut(Spec);

    const l_bytes = try readBytes(io, gpa, l_path);
    defer gpa.free(l_bytes);
    const r_bytes = try readBytes(io, gpa, r_path);
    defer gpa.free(r_bytes);
    const l_all = std.mem.bytesAsSlice(pan.Sample(f32), l_bytes);
    const r_all = std.mem.bytesAsSlice(pan.Sample(f32), r_bytes);
    // Drive both branches over the common length so they exhaust together.
    const n = @min(l_all.len, r_all.len);
    const l_samples = l_all[0..n];
    const r_samples = r_all[0..n];
    std.debug.print(
        "analyze(stereo): L={s} R={s} — {d} samples ({d:.1} s @ {d} Hz), FRAME={d} HOP={d} BINS={d}\n",
        .{ l_path, r_path, n, @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(sample_rate)), sample_rate, FRAME, HOP, BINS },
    );

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = BLOCK });
    defer g.deinit();

    const src_l = try g.add(pan.io.LpcmSource(Num), .{ .data = l_samples, .loop = false });
    const src_r = try g.add(pan.io.LpcmSource(Num), .{ .data = r_samples, .loop = false });
    const stft_l = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const stft_r = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const power_l = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});
    const power_r = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});
    // scalar descriptors off the left channel
    const dominant = try g.add(pan.feat.DominantBandHysteresis(Num, BINS), .{});
    const rms = try g.add(pan.feat.Rms(Num, BINS), .{});
    const centroid = try g.add(pan.feat.SpectralCentroid(Num, BINS), .{});
    const rolloff = try g.add(pan.feat.SpectralRolloff(Num, BINS), .{});
    const flux = try g.add(pan.feat.SpectralFlux(Num, BINS), .{});
    const framer = try g.add(pan.spectral.Framer(Num, FRAME, HOP), .{});
    const envelope = try g.add(pan.feat.BallisticEnvelope(Num, FRAME), .{});
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 1 + n / HOP });

    try g.connect(src_l, stft_l);
    try g.connect(stft_l, power_l);
    try g.connect(src_r, stft_r);
    try g.connect(stft_r, power_r);
    inline for (.{ dominant, rms, centroid, rolloff, flux }) |node| try g.connect(power_l, node);
    try g.connect(src_l, framer);
    try g.connect(framer, envelope);
    try g.connect(power_l, collect.in.full_spectrum_l);
    try g.connect(power_r, collect.in.full_spectrum_r);
    try g.connect(dominant, collect.in.dominant);
    try g.connect(envelope, collect.in.amplitude);
    try g.connect(rms, collect.in.rms);
    try g.connect(centroid, collect.in.centroid);
    try g.connect(rolloff, collect.in.rolloff);
    try g.connect(flux, collect.in.flux);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    if (sink.instance().overflowed) return error.FeatureSinkOverflowed;
    const cols = comptime pan.featureMatrixColumns(Row);
    std.debug.print("analyze(stereo): collected {d} feature frames × {d} columns\n", .{ rows.len, cols });

    try writeMatrixAndSidecar(io, gpa, out_prefix, rows, FRAME, BINS, cols, sample_rate, true);
}

// ===========================================================================
// shared output
// ===========================================================================

fn writeMatrixAndSidecar(
    io: std.Io,
    gpa: std.mem.Allocator,
    out_prefix: []const u8,
    rows: anytype,
    frame: usize,
    bins: usize,
    cols: usize,
    sample_rate: u32,
    stereo: bool,
) !void {
    const matrix_path = try std.fmt.allocPrint(gpa, "{s}.f32", .{out_prefix});
    defer gpa.free(matrix_path);
    try pan.writeFeatureMatrix(matrix_path, rows);

    const sidecar_path = try std.fmt.allocPrint(gpa, "{s}.json", .{out_prefix});
    defer gpa.free(sidecar_path);
    if (stereo)
        try writeSidecarStereo(io, gpa, sidecar_path, frame, bins, rows.len, cols, sample_rate)
    else
        try writeSidecar(io, gpa, sidecar_path, frame, bins, rows.len, cols, sample_rate);

    std.debug.print("analyze: wrote {s} ({d} bytes) + {s}\n", .{ matrix_path, rows.len * cols * @sizeOf(f32), sidecar_path });
}

fn usage() error{Usage} {
    std.debug.print(
        "usage: analyze <input.f32> <sample_rate> <out_prefix> [frame]\n" ++
            "       analyze --stereo <left.f32> <right.f32> <sample_rate> <out_prefix> [frame]\n",
        .{},
    );
    return error.Usage;
}

fn fpsFor(sample_rate: u32) u32 {
    return @divTrunc(sample_rate + HOP / 2, HOP);
}

fn hzPerBin(sample_rate: u32, frame: usize) f64 {
    return @as(f64, @floatFromInt(sample_rate)) / @as(f64, @floatFromInt(frame));
}

fn writeSidecar(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    frame: usize,
    bins: usize,
    n_frames: usize,
    cols: usize,
    sample_rate: u32,
) !void {
    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "schema": "pan.featuregram.v1",
        \\  "stereo": false,
        \\  "sample_rate": {d},
        \\  "analysis_rate": {d},
        \\  "frame_size": {d},
        \\  "hop_size": {d},
        \\  "bins": {d},
        \\  "fps": {d},
        \\  "n_frames": {d},
        \\  "n_cols": {d},
        \\  "hz_per_bin": {d},
        \\  "columns": [
        \\    {{ "name": "full_spectrum", "offset": 0, "width": {d}, "kind": "vector" }},
        \\    {{ "name": "dominant",  "offset": {d}, "width": 1, "kind": "freq_bin" }},
        \\    {{ "name": "amplitude", "offset": {d}, "width": 1, "kind": "unit" }},
        \\    {{ "name": "rms",       "offset": {d}, "width": 1, "kind": "energy" }},
        \\    {{ "name": "centroid",  "offset": {d}, "width": 1, "kind": "freq_bin" }},
        \\    {{ "name": "rolloff",   "offset": {d}, "width": 1, "kind": "freq_bin" }},
        \\    {{ "name": "flux",      "offset": {d}, "width": 1, "kind": "energy" }}
        \\  ]
        \\}}
        \\
    , .{
        sample_rate, ANALYSIS_RATE, frame,                        HOP,      bins,     fpsFor(sample_rate),
        n_frames,    cols,          hzPerBin(sample_rate, frame), bins,     bins + 0, bins + 1,
        bins + 2,    bins + 3,      bins + 4,                     bins + 5,
    });
    defer gpa.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

fn writeSidecarStereo(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    frame: usize,
    bins: usize,
    n_frames: usize,
    cols: usize,
    sample_rate: u32,
) !void {
    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "schema": "pan.featuregram.v1",
        \\  "stereo": true,
        \\  "sample_rate": {d},
        \\  "analysis_rate": {d},
        \\  "frame_size": {d},
        \\  "hop_size": {d},
        \\  "bins": {d},
        \\  "fps": {d},
        \\  "n_frames": {d},
        \\  "n_cols": {d},
        \\  "hz_per_bin": {d},
        \\  "columns": [
        \\    {{ "name": "full_spectrum_l", "offset": 0, "width": {d}, "kind": "vector" }},
        \\    {{ "name": "full_spectrum_r", "offset": {d}, "width": {d}, "kind": "vector" }},
        \\    {{ "name": "dominant",  "offset": {d}, "width": 1, "kind": "freq_bin" }},
        \\    {{ "name": "amplitude", "offset": {d}, "width": 1, "kind": "unit" }},
        \\    {{ "name": "rms",       "offset": {d}, "width": 1, "kind": "energy" }},
        \\    {{ "name": "centroid",  "offset": {d}, "width": 1, "kind": "freq_bin" }},
        \\    {{ "name": "rolloff",   "offset": {d}, "width": 1, "kind": "freq_bin" }},
        \\    {{ "name": "flux",      "offset": {d}, "width": 1, "kind": "energy" }}
        \\  ]
        \\}}
        \\
    , .{
        sample_rate, ANALYSIS_RATE, frame,                        HOP, bins, fpsFor(sample_rate),
        n_frames,    cols,          hzPerBin(sample_rate, frame),
        bins, // full_spectrum_l width
        bins, bins, // full_spectrum_r offset, width
        2 * bins + 0, // dominant
        2 * bins + 1, // amplitude
        2 * bins + 2, // rms
        2 * bins + 3, // centroid
        2 * bins + 4, // rolloff
        2 * bins + 5, // flux
    });
    defer gpa.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}
