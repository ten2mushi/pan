//! examples/spectrogram.zig — emit the per-hop power spectrogram + MFCC matrix.
//!
//! A second Phase-17 analysis demonstrator: over a decoded mono LPCM file it builds
//! a pan Analyzer graph that collects, per analysis hop, BOTH the full power
//! spectrum (one spectrogram column) AND the mel-frequency cepstral coefficients —
//! all computed by the library (`Stft → PowerSpectrum` and `feat.Mfcc`). The
//! collected rows flatten to a native-endian row-major `f32` matrix whose first
//! `BINS` columns are the spectrogram and whose last `K` columns are the MFCCs; the
//! Python `render_spectrogram.py` turns each into a heatmap PNG.
//!
//!     LpcmSource ─► Stft ─► PowerSpectrum ─┬─────────────────────► spectrum (BINS)
//!                                          └─► Mfcc(K) ──────────► mfcc (K)
//!                                                      Concat ─► FeatureCollectorSink
//!
//! Usage:  spectrogram <input.f32> <sample_rate> <out_prefix>
//!   writes <out_prefix>.f32 (matrix: n_frames × (BINS + K)) and <out_prefix>.json.

const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});
/// FFT window (power of two). 2048 @ 44.1 kHz ≈ 46 ms, ~21.5 Hz/bin — a standard
/// music-analysis spectrogram resolution.
const FRAME = 2048;
/// Hop between columns. 1024 (50% overlap) ≈ 43 columns/second — a smooth
/// spectrogram time axis over the whole track.
const HOP = 1024;
const BINS = FRAME / 2 + 1; // 1025 real-FFT bins
/// MFCC coefficients kept (≤ 26 mel bands). 20 is a common timbre-summary width.
const K = 20;
const BLOCK = 64; // analysis rows per render block (pool sizing)

const Spec = .{
    .spectrum = pan.FeatureFrame(BINS), // one spectrogram column (power per bin)
    .mfcc = pan.FeatureFrame(K), // the hop's mel-cepstral coefficients
};
const Collect = pan.combinators.Concat(Spec);
const Row = pan.port.ConcatOut(Spec);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = std.process.Args.iterate(init.minimal.args);
    _ = args.next();
    const in_path = args.next() orelse return usage();
    const rate_arg = args.next() orelse return usage();
    const out_prefix = args.next() orelse return usage();
    const sample_rate = std.fmt.parseInt(u32, rate_arg, 10) catch return usage();

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
    std.debug.print("spectrogram: {s} — {d} samples ({d:.1} s @ {d} Hz)\n", .{
        in_path, samples.len, @as(f64, @floatFromInt(samples.len)) / @as(f64, @floatFromInt(sample_rate)), sample_rate,
    });

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = BLOCK });
    defer g.deinit();

    const src = try g.add(pan.io.LpcmSource(Num), .{ .data = samples, .loop = false });
    const stft = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const power = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});
    const mfcc = try g.add(pan.feat.Mfcc(Num, BINS, K), .{});
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 1 + samples.len / HOP });

    try g.connect(src, stft);
    try g.connect(stft, power);
    try g.connect(power, mfcc);
    try g.connect(power, collect.in.spectrum); // the spectrogram column
    try g.connect(mfcc, collect.in.mfcc);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    if (sink.instance().overflowed) return error.FeatureSinkOverflowed;
    const cols = comptime pan.featureMatrixColumns(Row);
    std.debug.print("spectrogram: {d} frames × {d} columns ({d} spectrum + {d} mfcc)\n", .{ rows.len, cols, BINS, K });

    const matrix_path = try std.fmt.allocPrint(gpa, "{s}.f32", .{out_prefix});
    defer gpa.free(matrix_path);
    try pan.writeFeatureMatrix(matrix_path, rows);

    const sidecar_path = try std.fmt.allocPrint(gpa, "{s}.json", .{out_prefix});
    defer gpa.free(sidecar_path);
    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "schema": "pan.spectrogram.v1",
        \\  "sample_rate": {d},
        \\  "frame_size": {d},
        \\  "hop_size": {d},
        \\  "bins": {d},
        \\  "n_mfcc": {d},
        \\  "n_frames": {d},
        \\  "n_cols": {d},
        \\  "hz_per_bin": {d},
        \\  "sec_per_hop": {d},
        \\  "spectrum_offset": 0,
        \\  "mfcc_offset": {d}
        \\}}
        \\
    , .{
        sample_rate,                                                           FRAME,                                                               HOP,  BINS, K, rows.len, cols,
        @as(f64, @floatFromInt(sample_rate)) / @as(f64, @floatFromInt(FRAME)), @as(f64, @floatFromInt(HOP)) / @as(f64, @floatFromInt(sample_rate)), BINS,
    });
    defer gpa.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sidecar_path, .data = json });

    std.debug.print("spectrogram: wrote {s} + {s}\n", .{ matrix_path, sidecar_path });
}

fn usage() error{Usage} {
    std.debug.print("usage: spectrogram <input.f32> <sample_rate> <out_prefix>\n", .{});
    return error.Usage;
}
