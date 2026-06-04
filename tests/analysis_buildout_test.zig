//! analysis_buildout_test — the WORKED analysis graph for the extended feature
//! catalog (Phase 9 feature buildout).
//!
//! Proves the new spectral extractors run end to end in the canonical Analyzer
//! shape — `LpcmSource → Stft → PowerSpectrum → {N extractors} → Concat →
//! FeatureCollectorSink` — driven off-RT by input exhaustion, and that the
//! collected matrix flattens to the column-major `f32` layout carrying the
//! `notes/1.md` viz schema (the flicker-free `DominantBandHysteresis` → COLOR,
//! `Rms` → AMPLITUDE, row index → emission time). It also exercises the principled
//! time-domain AMPLITUDE channel (`BallisticEnvelope`) on the parallel `Framer`
//! branch.
//!
//! These are STRUCTURAL/invariant checks on the integrated graph (column count and
//! order, value ranges, no overflow) — not numeric oracles; the per-block numeric
//! ≈-oracle checks live in `tests/feat_buildout_yoneda_test.zig`.

const std = @import("std");
const pan = @import("pan");
const testing = std.testing;

const Num = pan.numericFor(.f32, .{});
const FRAME = 32;
const HOP = 16;
const BINS = FRAME / 2 + 1; // real-FFT bins
const NB = 4; // spectral-contrast bands

/// The worked viz column set, in canonical order: the flicker-free dominant band
/// (COLOR), the spectral amplitude (AMPLITUDE), and a few shape descriptors.
const Spec = .{
    .dominant = pan.Scalar(u16),
    .rms = pan.Scalar(f32),
    .rolloff = pan.Scalar(f32),
    .flatness = pan.Scalar(f32),
    .entropy = pan.Scalar(f32),
    .contrast = pan.FeatureFrame(NB),
};
const Collect = pan.combinators.Concat(Spec);
const Row = pan.port.ConcatOut(Spec);

/// A deterministic non-looping signal: a low-frequency tone with a slow amplitude
/// swell, drained once (input-exhaustion head). The swell gives the amplitude
/// channel something to track; the tone gives the spectrum a stable dominant band.
fn makeSignal(buf: []pan.Sample(f32)) void {
    for (buf, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        const env = 0.2 + 0.8 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(buf.len));
        s.ch[0] = env * @sin(t * 0.4);
    }
}

test "buildout: Stft → power → {dominant-hysteresis, rms, shape...} → Concat → matrix" {
    const gpa = testing.allocator;
    var samples: [1024]pan.Sample(f32) = undefined;
    makeSignal(&samples);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = HOP });
    defer g.deinit();

    const src = try g.add(pan.io.LpcmSource(Num), .{ .data = &samples, .loop = false });
    const stft = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const power = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});

    const dominant = try g.add(pan.feat.DominantBandHysteresis(Num, BINS), .{});
    const rms = try g.add(pan.feat.Rms(Num, BINS), .{});
    const rolloff = try g.add(pan.feat.SpectralRolloff(Num, BINS), .{});
    const flatness = try g.add(pan.feat.SpectralFlatness(Num, BINS), .{});
    const entropy = try g.add(pan.feat.SpectralEntropy(Num, BINS), .{});
    const contrast = try g.add(pan.feat.SpectralContrast(Num, BINS, NB), .{});
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 128 });

    try g.connect(src, stft);
    try g.connect(stft, power);
    // fan the power spectrum out to every extractor (same-rate fan-out)
    inline for (.{ dominant, rms, rolloff, flatness, entropy, contrast }) |node| {
        try g.connect(power, node);
    }
    try g.connect(dominant, collect.in.dominant);
    try g.connect(rms, collect.in.rms);
    try g.connect(rolloff, collect.in.rolloff);
    try g.connect(flatness, collect.in.flatness);
    try g.connect(entropy, collect.in.entropy);
    try g.connect(contrast, collect.in.contrast);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    try testing.expect(rows.len > 0);
    try testing.expect(!sink.instance().overflowed);

    // The matrix flattens to the canonical column-major layout: column count is the
    // sum of the per-column widths (5 scalars widen to 1 each + the NB-wide contrast).
    const matrix = try pan.io.encodeFeatureMatrix(gpa, rows);
    defer gpa.free(matrix);
    const cols = comptime pan.featureMatrixColumns(Row);
    try testing.expectEqual(@as(usize, 5 + NB), cols);
    try testing.expectEqual(rows.len * cols, matrix.len);

    // Per-row invariants the viz relies on:
    //   - the COLOR band index is a valid bin (< BINS),
    //   - the AMPLITUDE (rms) is finite and non-negative,
    //   - flatness and normalized entropy live in [0, 1].
    for (rows) |row| {
        try testing.expect(row.dominant.value < BINS);
        try testing.expect(row.rms.value >= 0 and std.math.isFinite(row.rms.value));
        try testing.expect(row.flatness.value >= 0 and row.flatness.value <= 1.0001);
        try testing.expect(row.entropy.value >= 0 and row.entropy.value <= 1.0001);
    }

    // Column order == Concat field order: dominant is column 0, rms column 1.
    // Spot-check the encoded matrix agrees with the row structs.
    for (rows, 0..) |row, i| {
        const base = i * cols;
        try testing.expectEqual(@as(f32, @floatFromInt(row.dominant.value)), matrix[base + 0]);
        try testing.expectEqual(row.rms.value, matrix[base + 1]);
    }
}

test "buildout: a flicker-free dominant band holds steady on a stationary tone" {
    // A stationary tone should not flicker the COLOR channel: once the
    // hysteresis tracker settles, the reported band is constant for the tail.
    const gpa = testing.allocator;
    var samples: [2048]pan.Sample(f32) = undefined;
    for (&samples, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.ch[0] = @sin(t * 0.6); // one fixed frequency, constant amplitude
    }

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = HOP });
    defer g.deinit();
    const src = try g.add(pan.io.LpcmSource(Num), .{ .data = &samples, .loop = false });
    const stft = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const power = try g.add(pan.spectral.PowerSpectrum(Num, BINS), .{});
    const dominant = try g.add(pan.feat.DominantBandHysteresis(Num, BINS), .{});
    const Spec1 = .{ .dominant = pan.Scalar(u16) };
    const Collect1 = pan.combinators.Concat(Spec1);
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

    const rows = sink.instance().frames();
    try testing.expect(rows.len > 8);
    // The dominant band over the last half of the run is constant (no flicker).
    const tail_start = rows.len / 2;
    const settled = rows[tail_start].dominant.value;
    for (rows[tail_start..]) |row| {
        try testing.expectEqual(settled, row.dominant.value);
    }
}

test "buildout: the time-domain ballistic envelope tracks a swell on the Framer branch" {
    // The principled AMPLITUDE channel: Framer → BallisticEnvelope. A signal that
    // swells from quiet to loud must drive the [0,1] envelope monotonically upward
    // (fast attack, slow release — here a pure swell, so it only rises).
    const gpa = testing.allocator;
    var samples: [2048]pan.Sample(f32) = undefined;
    for (&samples, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        const env = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples.len)); // 0 → 1 swell
        s.ch[0] = env * @sin(t * 0.5);
    }

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = HOP });
    defer g.deinit();
    const src = try g.add(pan.io.LpcmSource(Num), .{ .data = &samples, .loop = false });
    const framer = try g.add(pan.spectral.Framer(Num, FRAME, HOP), .{});
    const env = try g.add(pan.feat.BallisticEnvelope(Num, FRAME), .{});
    const Spec1 = .{ .amplitude = pan.Scalar(f32) };
    const Collect1 = pan.combinators.Concat(Spec1);
    const collect = try g.add(Collect1, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(pan.port.ConcatOut(Spec1)), .{ .capacity_hint = 256 });

    try g.connect(src, framer);
    try g.connect(framer, env);
    try g.connect(env, collect.in.amplitude);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    try testing.expect(rows.len > 8);
    // The envelope stays in [0, 1] and the late frames are louder than the early
    // ones (the swell drove it up).
    for (rows) |row| {
        try testing.expect(row.amplitude.value >= 0 and row.amplitude.value <= 1.0);
    }
    const early = rows[rows.len / 8].amplitude.value;
    const late = rows[rows.len - 1 - rows.len / 8].amplitude.value;
    try testing.expect(late > early);
}
