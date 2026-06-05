//! examples_analysis_smoke_test — the Phase-17 end-to-end Analyzer smoke test.
//!
//! The `examples/analyze.zig` demonstrator wires a graph shape that no other test
//! exercises as a whole: ONE `LpcmSource` fans out to TWO different rate consumers
//! at once —
//!
//!     LpcmSource ──┬─► Stft ─► PowerSpectrum ─► { dominant-band, rms, centroid,
//!                  │                              rolloff, flux, flatness, contrast }
//!                  └─► Framer ─► BallisticEnvelope (the 0..1 amplitude)
//!                                          │
//!     all feature streams ────────────────┴─► Concat ─► FeatureCollectorSink
//!
//! The existing analysis-buildout suite tests the spectral branch and the
//! time-domain branch SEPARATELY. The load-bearing property proved here is that
//! the SAME source driving two distinct rate branches commits, runs to input
//! exhaustion, and stays frame-aligned: both branches share the source and the
//! hop, so every collected row carries one spectral feature set and one envelope
//! sample for the SAME hop — and there is exactly one row per hop emitted (the two
//! branches produce the same number of rows, by construction of the shared hop).
//!
//! These are STRUCTURAL/invariant checks on the integrated example graph (it
//! commits; it terminates; the matrix has the right shape; per-column ranges hold)
//! — not numeric oracles. Small comptime sizes and a short synthetic signal keep
//! the run fast; the example's real 2048/735 sizes are deliberately NOT used here.

const std = @import("std");
const pan = @import("pan");
const testing = std.testing;

// Small analysis parameters mirroring the example's SHAPE, not its sizes. A
// power-of-two frame is required by the radix-2 STFT; the hop is half the frame.
const Num = pan.numericFor(.f32, .{});
const FRAME = 32;
const HOP = 16;
const BINS = FRAME / 2 + 1; // non-redundant real-FFT bins
const NB = 4; // octave-band spectral-contrast bands

// The exact `Spec` column set the example declares (same fields, same order). The
// field-declaration order IS the canonical feature-matrix column order, so the
// column-offset assertions below depend on it.
const Spec = .{
    .dominant = pan.Scalar(u16), // COLOR — flicker-free dominant frequency bin
    .amplitude = pan.Scalar(f32), // AMPLITUDE — ballistic envelope, 0..1
    .rms = pan.Scalar(f32),
    .centroid = pan.Scalar(f32),
    .rolloff = pan.Scalar(f32),
    .flux = pan.Scalar(f32),
    .flatness = pan.Scalar(f32),
    .contrast = pan.FeatureFrame(NB),
};
const Collect = pan.combinators.Concat(Spec);
const Row = pan.port.ConcatOut(Spec);

/// A deterministic non-looping signal: a low-frequency tone under a slow amplitude
/// swell. The tone gives the spectral branch a stable dominant band; the swell
/// gives the time-domain envelope branch something monotone to track. Drained once
/// (input-exhaustion head).
fn makeSignal(buf: []pan.Sample(f32)) void {
    for (buf, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        const env = 0.2 + 0.8 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(buf.len));
        s.ch[0] = env * @sin(t * 0.4);
    }
}

/// Build the example's exact graph (shrunk parameters) and run it to exhaustion,
/// returning the committed engine plus the sink node handle. The caller owns the
/// graph and engine and must `deinit` both; the returned handles borrow `g`.
const Sink = pan.io.FeatureCollectorSink(Row);

fn buildExampleGraph(
    g: *pan.Graph,
    samples: []pan.Sample(f32),
) !struct {
    eng: pan.Engine,
    sink: pan.NodeHandle(Sink),
} {
    const src = try g.add(pan.io.LpcmSource(Num), .{ .data = samples, .loop = false });

    // spectral branch
    const stft = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const power = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});
    const dominant = try g.add(pan.feat.DominantBandHysteresis(Num, BINS), .{});
    const rms = try g.add(pan.feat.Rms(Num, BINS), .{});
    const centroid = try g.add(pan.feat.SpectralCentroid(Num, BINS), .{});
    const rolloff = try g.add(pan.feat.SpectralRolloff(Num, BINS), .{});
    const flux = try g.add(pan.feat.SpectralFlux(Num, BINS), .{});
    const flatness = try g.add(pan.feat.SpectralFlatness(Num, BINS), .{});
    const contrast = try g.add(pan.feat.SpectralContrast(Num, BINS, NB), .{});

    // time-domain amplitude branch
    const framer = try g.add(pan.spectral.Framer(Num, FRAME, HOP), .{});
    const envelope = try g.add(pan.feat.BallisticEnvelope(Num, FRAME), .{});

    // collection
    const collect = try g.add(Collect, .{});
    const sink = try g.add(Sink, .{ .capacity_hint = 256 });

    // wire the two branches off the one source (same-rate fan-out from src)
    try g.connect(src, stft);
    try g.connect(stft, power);
    inline for (.{ dominant, rms, centroid, rolloff, flux, flatness, contrast }) |node| {
        try g.connect(power, node);
    }
    try g.connect(src, framer);
    try g.connect(framer, envelope);

    // fan every feature into the named Concat columns
    try g.connect(dominant, collect.in.dominant);
    try g.connect(envelope, collect.in.amplitude);
    try g.connect(rms, collect.in.rms);
    try g.connect(centroid, collect.in.centroid);
    try g.connect(rolloff, collect.in.rolloff);
    try g.connect(flux, collect.in.flux);
    try g.connect(flatness, collect.in.flatness);
    try g.connect(contrast, collect.in.contrast);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    errdefer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    return .{ .eng = eng, .sink = sink };
}

test "example analyze graph: dual-branch fan-out commits, runs to exhaustion, and yields a well-shaped matrix" {
    const gpa = testing.allocator;
    var samples: [1024]pan.Sample(f32) = undefined;
    makeSignal(&samples);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = HOP });
    defer g.deinit();

    // The graph must commit without error and the analysis root must terminate on
    // input exhaustion (no infinite pull). If commit or the run errored, this
    // `try` propagates the failure — that IS the "commits and runs to completion"
    // assertion.
    var built = try buildExampleGraph(&g, &samples);
    defer built.eng.deinit();
    const sink = built.sink;

    const rows = sink.instance().frames();
    // A non-empty, non-overflowed collection: input exhaustion produced at least
    // one full hop and the sink's capacity was sufficient.
    try testing.expect(rows.len > 0);
    try testing.expect(!sink.instance().overflowed);

    // The flattened matrix is row-major: one row per hop, columns in Concat field
    // order. Column count is the sum of per-column widths: 7 scalars widen to 1
    // each, plus the NB-wide contrast feature frame.
    const matrix = try pan.io.encodeFeatureMatrix(gpa, rows);
    defer gpa.free(matrix);
    const cols = comptime pan.featureMatrixColumns(Row);
    try testing.expectEqual(@as(usize, 7 + NB), cols);

    // Row count is consistent with the encoded length: rows × cols == length. This
    // is the shape contract the headerless renderer reshapes against.
    try testing.expectEqual(rows.len * cols, matrix.len);

    // Per-column invariants the visualization relies on, per row:
    //   - the COLOR band index is a valid bin (< BINS),
    //   - the amplitude (ballistic envelope) is a unit value in [0, 1],
    //   - flatness is a normalized ratio in [0, 1],
    //   - every other scalar and every contrast lane is finite (no NaN/Inf).
    // A tiny epsilon tolerates the upper bound being touched by rounding.
    for (rows) |row| {
        try testing.expect(row.dominant.value < BINS);

        try testing.expect(row.amplitude.value >= 0 and row.amplitude.value <= 1.0001);
        try testing.expect(std.math.isFinite(row.amplitude.value));

        try testing.expect(row.flatness.value >= 0 and row.flatness.value <= 1.0001);

        try testing.expect(row.rms.value >= 0 and std.math.isFinite(row.rms.value));
        try testing.expect(std.math.isFinite(row.centroid.value));
        try testing.expect(std.math.isFinite(row.rolloff.value));
        try testing.expect(std.math.isFinite(row.flux.value));
        for (row.contrast.v) |c| try testing.expect(std.math.isFinite(c));
    }

    // Column order == Concat field order. Spot-check the encoded matrix agrees with
    // the row structs: dominant is column 0 (the integer bin widened to f32),
    // amplitude is column 1, rms is column 2, and the NB-wide contrast occupies the
    // last NB columns starting at offset 7.
    for (rows, 0..) |row, i| {
        const base = i * cols;
        try testing.expectEqual(@as(f32, @floatFromInt(row.dominant.value)), matrix[base + 0]);
        try testing.expectEqual(row.amplitude.value, matrix[base + 1]);
        try testing.expectEqual(row.rms.value, matrix[base + 2]);
        inline for (0..NB) |k| {
            try testing.expectEqual(row.contrast.v[k], matrix[base + 7 + k]);
        }
    }
}

test "example analyze graph: the spectral and time-domain branches stay frame-aligned (one row per shared hop)" {
    // The load-bearing dual-branch property. Both branches consume the SAME source
    // at the SAME hop, so they must emit the same number of feature frames — the
    // Concat collects one tuple per hop, never dropping or duplicating a branch.
    // We prove this by building the dual-branch graph and, independently, the two
    // single-branch graphs over the identical signal, then asserting all three
    // agree on row count. If the dual graph mis-aligned the branches (e.g. one
    // branch advanced a hop the other didn't), the Concat would stall or the row
    // counts would diverge.
    const gpa = testing.allocator;
    var samples: [1024]pan.Sample(f32) = undefined;
    makeSignal(&samples);

    // (a) the full dual-branch example graph
    const dual_rows = blk: {
        var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = HOP });
        defer g.deinit();
        var built = try buildExampleGraph(&g, &samples);
        defer built.eng.deinit();
        break :blk built.sink.instance().frames().len;
    };

    // (b) the spectral branch alone (one scalar column off the power spectrum)
    const spectral_rows = blk: {
        const Spec1 = .{ .dominant = pan.Scalar(u16) };
        const Collect1 = pan.combinators.Concat(Spec1);
        var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = HOP });
        defer g.deinit();
        const src = try g.add(pan.io.LpcmSource(Num), .{ .data = &samples, .loop = false });
        const stft = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
        const power = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});
        const dominant = try g.add(pan.feat.DominantBandHysteresis(Num, BINS), .{});
        const collect = try g.add(Collect1, .{});
        const sink = try g.add(pan.io.FeatureCollectorSink(pan.port.ConcatOut(Spec1)), .{ .capacity_hint = 256 });
        try g.connect(src, stft);
        try g.connect(stft, power);
        try g.connect(power, dominant);
        try g.connect(dominant, collect.in.dominant);
        try g.connect(collect, sink);
        var eng = try g.commitAnalysis();
        defer eng.deinit();
        try eng.runToCompletion(.{ .clock = .input_exhaustion });
        break :blk sink.instance().frames().len;
    };

    // (c) the time-domain branch alone (Framer → BallisticEnvelope)
    const time_rows = blk: {
        const Spec1 = .{ .amplitude = pan.Scalar(f32) };
        const Collect1 = pan.combinators.Concat(Spec1);
        var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = HOP });
        defer g.deinit();
        const src = try g.add(pan.io.LpcmSource(Num), .{ .data = &samples, .loop = false });
        const framer = try g.add(pan.spectral.Framer(Num, FRAME, HOP), .{});
        const envelope = try g.add(pan.feat.BallisticEnvelope(Num, FRAME), .{});
        const collect = try g.add(Collect1, .{});
        const sink = try g.add(pan.io.FeatureCollectorSink(pan.port.ConcatOut(Spec1)), .{ .capacity_hint = 256 });
        try g.connect(src, framer);
        try g.connect(framer, envelope);
        try g.connect(envelope, collect.in.amplitude);
        try g.connect(collect, sink);
        var eng = try g.commitAnalysis();
        defer eng.deinit();
        try eng.runToCompletion(.{ .clock = .input_exhaustion });
        break :blk sink.instance().frames().len;
    };

    // Both isolated branches produce the same number of hops over the same input
    // (they share the FRAME/HOP windowing), and the dual-branch graph produces
    // exactly that many rows — one per shared hop, with neither branch lost.
    try testing.expect(dual_rows > 0);
    try testing.expectEqual(spectral_rows, time_rows);
    try testing.expectEqual(spectral_rows, dual_rows);
}
