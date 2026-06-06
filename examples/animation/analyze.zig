//! examples/analyze.zig — the Phase-17 end-to-end Analyzer demonstrator.
//!
//! Builds the canonical pan Analyzer pull graph over a decoded mono LPCM file and
//! emits the per-frame feature matrix the Python 3-D particle renderer consumes.
//! This is the brief's "use the pan library to produce the visualization data":
//! ALL feature extraction happens here, in the library; Python only draws.
//!
//! The graph shape (one row of features per analysis hop):
//!
//!     LpcmSource ──┬─► Stft ─► PowerSpectrum ─► { dominant-band (COLOR),
//!                  │                              rms, centroid, rolloff,
//!                  │                              flux, flatness, contrast }
//!                  └─► Framer ─► BallisticEnvelope (the principled 0..1 AMPLITUDE)
//!                                          │
//!     all feature streams ────────────────┴─► Concat ─► FeatureCollectorSink
//!
//! The hop is chosen so one analysis frame lands every 1/60 s at the analysis
//! sample rate, i.e. the 60 fps cadence the visualization animates at:
//! `HOP = round(analysis_rate / 60)`. With the canonical 44.1 kHz analysis rate
//! (the rate the scripts/decoder resamples every input to) that is exactly 735
//! samples per hop, 60 hops per second.
//!
//! The collected rows flatten to a native-endian, row-major `f32` matrix
//! (`writeFeatureMatrix`): one row per hop (the row index is emission order in
//! time), columns in `Concat` field-declaration order. A companion JSON sidecar
//! records the analysis parameters (sample rate, frame, hop, bins) and the column
//! layout so the renderer is self-describing — it needs no in-band header.
//!
//! Usage:  analyze <input.f32> <sample_rate> <out_prefix>
//!   input.f32   — raw native-endian f32 mono samples (the scripts/ decoder output)
//!   sample_rate — the analysis sample rate the file was decoded at (for Hz mapping)
//!   out_prefix  — writes <out_prefix>.f32 (matrix) and <out_prefix>.json (sidecar)

const std = @import("std");
const pan = @import("pan");

// --- analysis configuration (comptime — the STFT hop/frame are comptime params) -

/// f32 analysis precision (feature accuracy over the embedded fixed-point path).
const Num = pan.numericFor(.f32, .{});
/// The FFT window length (a power of two — the radix-2 STFT requires it). 2048 at
/// 44.1 kHz is ~46 ms — a standard music-analysis window with ~21.5 Hz/bin.
const FRAME = 2048;
/// One analysis frame every `HOP` input samples. 44100/60 = 735 ⇒ exactly 60
/// feature frames per second of audio (the visualization's frame cadence).
const HOP = 735;
/// Non-redundant real-FFT bins.
const BINS = FRAME / 2 + 1;
/// Octave-band spectral-contrast bands.
const NB = 6;
/// Analysis rows produced per render block — only a buffer-pool sizing knob (the
/// run pulls many such blocks to exhaustion). Bigger = fewer, larger blocks.
const BLOCK = 64;
/// The analysis sample rate the scripts/ decoder resamples every input to, and the
/// rate `HOP` is tuned against. A mismatched `sample_rate` arg only rescales the
/// per-bin Hz mapping in the sidecar; the hop cadence stays 60 frames/sec at this.
const ANALYSIS_RATE = 44_100;

/// The viz feature row. The field-declaration order IS the canonical feature-matrix
/// column order (un-transposable). The two `notes/1.md` essentials lead: the
/// flicker-free dominant band (COLOR / frequency) and the 0..1 amplitude; the rest
/// are spectral-shape descriptors the renderer uses to shape the oscillatory 3-D
/// spatial distribution.
const Spec = .{
    .full_spectrum = pan.FeatureFrame(BINS), // The full 1025-bin power spectrum
    .dominant = pan.Scalar(u16), // COLOR  — flicker-free dominant frequency bin
    .amplitude = pan.Scalar(f32), // AMPLITUDE — ballistic envelope, 0..1
    .rms = pan.Scalar(f32), // spectral broadband energy
    .centroid = pan.Scalar(f32), // brightness (centre-of-mass bin)
    .rolloff = pan.Scalar(f32), // 85%-energy roll-off bin
    .flux = pan.Scalar(f32), // spectral flux (onset / novelty)
};
const Collect = pan.combinators.Concat(Spec);
const Row = pan.port.ConcatOut(Spec);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // ---- parse args ----------------------------------------------------------
    var args = std.process.Args.iterate(init.minimal.args);
    _ = args.next(); // program name
    const in_path = args.next() orelse return usage();
    const rate_arg = args.next() orelse return usage();
    const out_prefix = args.next() orelse return usage();
    const sample_rate = std.fmt.parseInt(u32, rate_arg, 10) catch return usage();

    // ---- read the raw mono f32 LPCM file -------------------------------------
    // Read with f32 alignment so the bytes reinterpret straight to `Sample(f32)`
    // (mono frame == one f32) with no copy.
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
    std.debug.print(
        "analyze: {s} — {d} samples ({d:.1} s @ {d} Hz), FRAME={d} HOP={d}\n",
        .{ in_path, samples.len, @as(f64, @floatFromInt(samples.len)) / @as(f64, @floatFromInt(sample_rate)), sample_rate, FRAME, HOP },
    );

    // ---- build the Analyzer pull graph ---------------------------------------
    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = BLOCK });
    defer g.deinit();

    const src = try g.add(pan.io.LpcmSource(Num), .{ .data = samples, .loop = false });
    // spectral branch
    const stft = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const power = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});
    const dominant = try g.add(pan.feat.DominantBandHysteresis(Num, BINS), .{});
    const rms = try g.add(pan.feat.Rms(Num, BINS), .{});
    const centroid = try g.add(pan.feat.SpectralCentroid(Num, BINS), .{});
    const rolloff = try g.add(pan.feat.SpectralRolloff(Num, BINS), .{});
    const flux = try g.add(pan.feat.SpectralFlux(Num, BINS), .{});
    // time-domain amplitude branch
    const framer = try g.add(pan.spectral.Framer(Num, FRAME, HOP), .{});
    const envelope = try g.add(pan.feat.BallisticEnvelope(Num, FRAME), .{});
    // collection
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{
        .capacity_hint = 1 + samples.len / HOP,
    });

    // wire the two branches off the one source (same-rate fan-out)
    try g.connect(src, stft);
    try g.connect(stft, power);
    inline for (.{ dominant, rms, centroid, rolloff, flux }) |node| {
        try g.connect(power, node);
    }
    try g.connect(src, framer);
    try g.connect(framer, envelope);

    // fan every feature into the named Concat columns
    try g.connect(power, collect.in.full_spectrum);
    try g.connect(dominant, collect.in.dominant);
    try g.connect(envelope, collect.in.amplitude);
    try g.connect(rms, collect.in.rms);
    try g.connect(centroid, collect.in.centroid);
    try g.connect(rolloff, collect.in.rolloff);
    try g.connect(flux, collect.in.flux);
    try g.connect(collect, sink);

    // ---- drive the analysis root to input exhaustion -------------------------
    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    if (sink.instance().overflowed) return error.FeatureSinkOverflowed;
    const cols = comptime pan.featureMatrixColumns(Row);
    std.debug.print("analyze: collected {d} feature frames × {d} columns\n", .{ rows.len, cols });

    // ---- write the matrix + self-describing sidecar --------------------------
    const matrix_path = try std.fmt.allocPrint(gpa, "{s}.f32", .{out_prefix});
    defer gpa.free(matrix_path);
    try pan.writeFeatureMatrix(matrix_path, rows);

    const sidecar_path = try std.fmt.allocPrint(gpa, "{s}.json", .{out_prefix});
    defer gpa.free(sidecar_path);
    try writeSidecar(io, gpa, sidecar_path, rows.len, cols, sample_rate);

    std.debug.print("analyze: wrote {s} ({d} bytes) + {s}\n", .{
        matrix_path, rows.len * cols * @sizeOf(f32), sidecar_path,
    });
}

fn usage() error{Usage} {
    std.debug.print("usage: analyze <input.f32> <sample_rate> <out_prefix>\n", .{});
    return error.Usage;
}

/// Emit the JSON sidecar describing the analysis parameters and the column layout,
/// so the renderer reshapes and interprets the headerless `f32` matrix without any
/// hard-coded knowledge of this build's `Spec`.
fn writeSidecar(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    n_frames: usize,
    cols: usize,
    sample_rate: u32,
) !void {
    // The column descriptor mirrors `Spec` field order (offset, width). A scalar is
    // width 1; the contrast feature frame is width NB.
    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "schema": "pan.featuregram.v1",
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
        sample_rate,
        ANALYSIS_RATE,
        FRAME,
        HOP,
        BINS,
        @divTrunc(sample_rate + HOP / 2, HOP), // ~ frames per second at this rate
        n_frames,
        cols,
        @as(f64, @floatFromInt(sample_rate)) / @as(f64, @floatFromInt(FRAME)),
        BINS,
        BINS + 0,
        BINS + 1,
        BINS + 2,
        BINS + 3,
        BINS + 4,
        BINS + 5,
    });
    defer gpa.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}
