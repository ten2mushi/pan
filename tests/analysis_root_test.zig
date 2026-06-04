//! Phase 9 gate — the analysis pull root.
//!
//! Proves the Analyzer graph shape end to end: a non-RT pull root driven by input
//! exhaustion, typed feature ports, a named `Concat` whose field order is the
//! column order, off-RT collection into a growable `FeatureCollectorSink`, the
//! `notes/1.md` matrix layout, and the law-A8 rejection of a growable sink on a
//! realtime root. The deadline-isolation property (C5) is demonstrated structurally:
//! the analysis root is a *separate* engine driven by `runToCompletion`, never the
//! audio device callback, so it cannot steal an audio deadline.
//!
//! These are pan-vs-oracle checks on the feature numerics (deterministic spectra →
//! known features) and ⊢ checks on the commit-time A8 rejection.

const std = @import("std");
const pan = @import("pan");
const testing = std.testing;

const Num = pan.numericFor(.f32, .{});
const BINS = 8;
const NCO = 4; // MFCC coefficient count

/// The Concat row used throughout: the canonical `notes/1.md` column set, in the
/// order `mfcc[NCO], centroid, flux, dominant, rms`.
const Spec = .{
    .mfcc = pan.FeatureFrame(NCO),
    .centroid = pan.Scalar(f32),
    .flux = pan.Scalar(f32),
    .dominant = pan.Scalar(u16),
    .rms = pan.Scalar(f32),
};
const Collect = pan.combinators.Concat(Spec);
const Row = pan.port.ConcatOut(Spec);

/// A zero-sample-input Map *source* that streams a fixed list of power spectra
/// (`FeatureFrame(BINS)`), then zero-pads and reports exhausted — the analysis
/// pull root's input-exhaustion head, standing in for `LpcmSource → Stft → power`
/// so the core P9 surface is tested without the rate seam.
const SpectrumSource = struct {
    const Self = @This();
    spectra: []const pan.FeatureFrame(BINS) = &.{},
    cursor: usize = 0,
    done: bool = false,

    pub fn process(self: *Self, out: []pan.FeatureFrame(BINS)) void {
        for (out) |*o| {
            if (self.cursor >= self.spectra.len) {
                self.done = true;
                o.* = .{ .v = @splat(0) };
                continue;
            }
            o.* = self.spectra[self.cursor];
            self.cursor += 1;
        }
    }
    pub fn exhausted(self: *Self) bool {
        return self.done;
    }
};

/// Build `n` deterministic power spectra: spectrum `i` has its peak at bin `i %
/// BINS` (value 9) and 1 elsewhere — so `DominantBand(i) == i % BINS`, and the RMS
/// is constant `sqrt((9 + (BINS-1))/BINS)`.
fn makeSpectra(buf: []pan.FeatureFrame(BINS)) void {
    for (buf, 0..) |*f, i| {
        f.* = .{ .v = @splat(1.0) };
        f.v[i % BINS] = 9.0;
    }
}

fn addFeatureChain(g: *pan.Graph, source: anytype) !pan.NodeHandle(Collect) {
    const mfcc = try g.add(pan.feat.Mfcc(Num, BINS, NCO), .{});
    const centroid = try g.add(pan.feat.SpectralCentroid(Num, BINS), .{});
    const flux = try g.add(pan.feat.SpectralFlux(Num, BINS), .{});
    const dominant = try g.add(pan.feat.DominantBand(Num, BINS), .{});
    const rms = try g.add(pan.feat.Rms(Num, BINS), .{});
    const collect = try g.add(Collect, .{});
    // fan-out the spectrum to all five extractors (same-rate fan-out)
    inline for (.{ mfcc, centroid, flux, dominant, rms }) |node| try g.connect(source, node);
    // wire each extractor to its NAMED Concat column
    try g.connect(mfcc, collect.in.mfcc);
    try g.connect(centroid, collect.in.centroid);
    try g.connect(flux, collect.in.flux);
    try g.connect(dominant, collect.in.dominant);
    try g.connect(rms, collect.in.rms);
    return collect;
}

test "analysis root: input-exhaustion run collects a per-hop feature matrix" {
    const gpa = testing.allocator;
    var spectra: [50]pan.FeatureFrame(BINS) = undefined;
    makeSpectra(&spectra);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 16 });
    defer g.deinit();

    const src = try g.add(SpectrumSource, .{ .spectra = &spectra });
    const collect = try addFeatureChain(&g, src);
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 64 });
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();

    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    // Every real spectrum produced a row (plus a zero-padded tail to the block edge).
    try testing.expect(rows.len >= spectra.len);
    try testing.expect(!sink.instance().overflowed);

    // The dominant-band column reproduces the planted peak pattern for the real hops.
    for (0..spectra.len) |i| {
        try testing.expectEqual(@as(u16, @intCast(i % BINS)), rows[i].dominant.value);
    }
    // RMS is the constant spectral level sqrt((9 + 7)/8) = sqrt(2) for every real hop.
    const want_rms: f32 = @sqrt((9.0 + @as(f32, BINS - 1)) / @as(f32, BINS));
    for (0..spectra.len) |i| {
        try testing.expectApproxEqAbs(want_rms, rows[i].rms.value, 1e-5);
    }
}

test "analysis root: the collected matrix flattens to the viz column layout" {
    const gpa = testing.allocator;
    var spectra: [10]pan.FeatureFrame(BINS) = undefined;
    makeSpectra(&spectra);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 16 });
    defer g.deinit();
    const src = try g.add(SpectrumSource, .{ .spectra = &spectra });
    const collect = try addFeatureChain(&g, src);
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 16 });
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    const matrix = try pan.io.encodeFeatureMatrix(gpa, rows);
    defer gpa.free(matrix);

    // Column count is fixed by the Row layout: mfcc[NCO] + 4 scalars.
    const cols = comptime pan.featureMatrixColumns(Row);
    try testing.expectEqual(@as(usize, NCO + 4), cols);
    try testing.expectEqual(rows.len * cols, matrix.len);

    // Column order == Concat field order: [mfcc(NCO) | centroid | flux | dominant | rms].
    // The dominant column (index NCO+2) holds the widened u16 band index; the rms
    // column (index NCO+3) holds the constant level — exactly what the row carried.
    for (0..spectra.len) |i| {
        const base = i * cols;
        try testing.expectEqual(@as(f32, @floatFromInt(i % BINS)), matrix[base + NCO + 2]);
        try testing.expectApproxEqAbs(rows[i].rms.value, matrix[base + NCO + 3], 0);
        // the four mfcc columns are the row's mfcc vector
        inline for (0..NCO) |c| try testing.expectEqual(rows[i].mfcc.v[c], matrix[base + c]);
    }
}

test "law A8: a FeatureCollectorSink on a REALTIME root is a commit error" {
    const gpa = testing.allocator;
    var spectra: [4]pan.FeatureFrame(BINS) = undefined;
    makeSpectra(&spectra);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 16 });
    defer g.deinit();
    const src = try g.add(SpectrumSource, .{ .spectra = &spectra });
    const collect = try addFeatureChain(&g, src);
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 8 });
    try g.connect(collect, sink);

    // The realtime commit (`commit`, default `.realtime_streaming`) rejects the
    // growable sink — a geometric realloc may not sit on the audio deadline.
    try testing.expectError(pan.CommitError.GrowableSinkOnRealtimeRoot, g.commit());
}

test "analysis root: an input-exhaustion run with no drainable source is rejected" {
    const gpa = testing.allocator;
    // A looping spectrum source (never exhausts) — there is no exhaustion probe, so
    // an input-exhaustion run could never terminate and is rejected up front.
    const LoopingSource = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []pan.FeatureFrame(BINS)) void {
            _ = self;
            for (out) |*o| o.* = .{ .v = @splat(1.0) };
        }
    };
    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 16 });
    defer g.deinit();
    const src = try g.add(LoopingSource, .{});
    const collect = try addFeatureChain(&g, src);
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 8 });
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try testing.expectError(error.NoExhaustibleSource, eng.runToCompletion(.{ .clock = .input_exhaustion }));
}

test "deadline isolation (C5): an analysis run does not touch a separate audio engine" {
    const gpa = testing.allocator;

    // An ordinary realtime audio engine (gain passthrough), committed and idle.
    const BufSrc = struct {
        const Self = @This();
        data: [*]const pan.Sample(f32) = undefined,
        pub fn process(self: *Self, out: []pan.Sample(f32)) void {
            @memcpy(out, self.data[0..out.len]);
        }
    };
    const Gain = struct {
        const Self = @This();
        gain: f32 = 1.0,
        pub fn process(self: *Self, in: []const pan.Sample(f32), out: []pan.Sample(f32)) void {
            for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.gain;
        }
    };
    const Sink = struct {
        const Self = @This();
        dest: [*]pan.Sample(f32) = undefined,
        pub fn process(self: *Self, in: []const pan.Sample(f32)) void {
            @memcpy(self.dest[0..in.len], in);
        }
    };
    var input: [16]pan.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i);
    var output: [16]pan.Sample(f32) = undefined;

    var ag = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 16 });
    defer ag.deinit();
    const asrc = try ag.add(BufSrc, .{ .data = @as([*]const pan.Sample(f32), &input) });
    const again = try ag.add(Gain, .{ .gain = 2.0 });
    const asink = try ag.add(Sink, .{ .dest = @as([*]pan.Sample(f32), &output) });
    try ag.connect(asrc, again);
    try ag.connect(again, asink);
    var audio = try ag.commit();
    defer audio.deinit();
    const audio_tele_before = audio.telemetry();

    // A completely independent analysis root, with its own pool, runs to completion.
    var spectra: [40]pan.FeatureFrame(BINS) = undefined;
    makeSpectra(&spectra);
    var fg = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 16 });
    defer fg.deinit();
    const fsrc = try fg.add(SpectrumSource, .{ .spectra = &spectra });
    const collect = try addFeatureChain(&fg, fsrc);
    const sink = try fg.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 64 });
    try fg.connect(collect, sink);
    var analysis = try fg.commitAnalysis();
    defer analysis.deinit();
    try analysis.runToCompletion(.{ .clock = .input_exhaustion });

    // The analysis run collected its matrix...
    try testing.expect(sink.instance().frames().len >= spectra.len);
    // ...and the audio engine — a separate root, separate pool — was never rendered,
    // so its telemetry (xruns, fault) is exactly as it was: the analysis path
    // structurally cannot steal the audio deadline (C5).
    const audio_tele_after = audio.telemetry();
    try testing.expectEqual(audio_tele_before.xrun_count, audio_tele_after.xrun_count);
    try testing.expect(!audio_tele_after.fault);
}

test "cross-root tap (C5): a shared upstream is rendered once and fanned via an SPSC ring" {
    const gpa = testing.allocator;
    const CAP = 256;
    const N = 16;
    const K = 8; // render K blocks → K*N samples through the ring

    // The shared SPSC ring — the ONLY coupling between the two roots.
    var ring: pan.SpscRing(pan.Sample(f32), CAP) = .empty;

    // A ramp so each sample is distinct (proves order is preserved end to end).
    var ramp: [K * N]pan.Sample(f32) = undefined;
    for (&ramp, 0..) |*s, i| s.ch[0] = @floatFromInt(i);

    // Root A — a REALTIME audio root: source → Tap. The upstream is rendered here,
    // once, and the Tap publishes each sample to the ring (wait-free, no alloc).
    var ag = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = N });
    defer ag.deinit();
    const asrc = try ag.add(pan.io.LpcmSource(Num), .{ .data = &ramp, .loop = true });
    const tap = try ag.add(pan.io.Tap(pan.Sample(f32), CAP), .{ .ring = &ring });
    try ag.connect(asrc, tap);
    var audio = try ag.commit(); // realtime: a Tap is a plain sink (not growable), so A8 does not fire
    defer audio.deinit();

    const token = pan.enterRealtimeThread();
    for (0..K) |_| audio.renderInto(token);
    token.leave();
    try testing.expect(!audio.telemetry().fault);

    // Root B — a separate, NON-RT analysis root: TapSource → collector. It NEVER
    // re-renders the upstream; it only reads the ring. Driven by a fixed-block clock
    // (a live tap has no input-exhaustion end).
    var fg = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = N });
    defer fg.deinit();
    const tsrc = try fg.add(pan.io.TapSource(pan.Sample(f32), CAP), .{ .ring = &ring });
    const sink = try fg.add(pan.io.FeatureCollectorSink(pan.Sample(f32)), .{ .capacity_hint = K * N });
    try fg.connect(tsrc, sink);
    var analysis = try fg.commitAnalysis();
    defer analysis.deinit();
    try analysis.runToCompletion(.{ .clock = .{ .wall_clock_timer = 60 }, .max_blocks = K });

    // The analysis root received EXACTLY the audio root's output, in order, through
    // the ring alone — the shared upstream was rendered once and fanned across roots.
    const got = sink.instance().frames();
    try testing.expectEqual(@as(usize, K * N), got.len);
    for (got, 0..) |s, i| try testing.expectEqual(@as(f32, @floatFromInt(i)), s.ch[0]);
}

test "analysis root: a full Stft → power → feature chain runs to exhaustion" {
    const gpa = testing.allocator;
    const FRAME = 16;
    const HOP = 8;
    const SBINS = FRAME / 2 + 1; // real-FFT bins

    // A non-looping LPCM source: a short sinusoid drained once.
    var samples: [256]pan.Sample(f32) = undefined;
    for (&samples, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.ch[0] = @sin(t * 0.3);
    }

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 8 });
    defer g.deinit();

    const src = try g.add(pan.io.LpcmSource(Num), .{ .data = &samples, .loop = false });
    const stft = try g.add(pan.spectral.Stft(Num, FRAME, HOP), .{});
    const power = try g.add(pan.spectral.PowerSpectrum(Num, SBINS), .{});
    const dominant = try g.add(pan.feat.DominantBand(Num, SBINS), .{});
    const rms = try g.add(pan.feat.Rms(Num, SBINS), .{});
    const Spec2 = .{ .dominant = pan.Scalar(u16), .rms = pan.Scalar(f32) };
    const Collect2 = pan.combinators.Concat(Spec2);
    const collect = try g.add(Collect2, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(pan.port.ConcatOut(Spec2)), .{ .capacity_hint = 128 });

    try g.connect(src, stft);
    try g.connect(stft, power);
    try g.connect(power, dominant);
    try g.connect(power, rms);
    try g.connect(dominant, collect.in.dominant);
    try g.connect(rms, collect.in.rms);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    // The rate chain produced and collected feature rows (one per hop), off-RT.
    try testing.expect(sink.instance().frames().len > 0);
    try testing.expect(!sink.instance().overflowed);
}
