//! spectral_test — the rate-elastic seam blocks (`src/spectral.zig`): the
//! latency-contract on the `Resampler`, the dual-mux (push ≡ pull) equivalence on
//! the stateful `Framer`/`Stft`, the `Stft → iStft` COLA reconstruction, and the
//! `PowerSpectrum` `Map`. These are the gate's "the Rate block passes both muxes +
//! the latency-contract" checks for the new `Rate` category.
//!
//! COMPARISON MODES:
//!   - latency-contract: measured impulse group delay == declared `algorithmic_latency` (≈).
//!   - dual-mux: chunked ≡ whole through the push/pull muxes — **bit-exact** (pan-vs-pan).
//!   - reconstruction: `iStft ∘ Stft` ≈ a delayed identity — `allclose` (the FFT
//!     round-trip is the oracle of its own reconstruction).
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14). Reject diagnostics use std.debug.print, never std.log.err.

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const f32num = pan.numericFor(.f32, .{});
const Sample = pan.Sample;
const eps: f32 = 1e-6;

// --- latency-contract (gate §5.5 / catalog §2.2 R1) ------------------------

test "latency-contract: a Resampler's measured group delay equals its declared latency" {
    // L = M = 1: a linear-phase low-pass FIR; the impulse response peaks at the
    // prototype centre = HALF, which is exactly the declared algorithmic_latency.
    inline for (.{ 4, 8, 16 }) |HALF| {
        const R = pan.Resampler(f32num, 1, 1, HALF);
        const N = 4 * HALF + 8;
        var in: [N]Sample(f32) = undefined;
        var out: [N]Sample(f32) = undefined;
        h.fillImpulse(&in);
        var rs = R{};
        _ = rs.pull(&in, N, &out);
        const measured = h.measuredGroupDelay(h.sampleValues(&out), eps) orelse return error.NoResponse;
        try std.testing.expectEqual(@as(usize, R.algorithmic_latency), measured);
        try std.testing.expectEqual(@as(usize, HALF), measured);
    }
}

test "latency-contract: an impulse through Stft→iStft has group delay == FRAME−HOP (declared)" {
    // The Framer/Stft latency is in OUTPUT frames (FRAME/HOP−1) — awkward to read
    // off a frame stream directly — so the meaningful impulse latency-contract is
    // the analysis/synthesis PAIR's group delay in audio samples: feed an impulse,
    // and the reconstructed impulse must land at exactly the declared round-trip
    // delay (Stft.algorithmic_latency·HOP + iStft.algorithmic_latency).
    inline for (.{ .{ 64, 32 }, .{ 128, 64 }, .{ 256, 64 } }) |cfg| {
        const FRAME = cfg[0];
        const HOP = cfg[1];
        const S = pan.Stft(f32num, FRAME, HOP);
        const I = pan.iStft(f32num, FRAME, HOP);
        const Spec = pan.Spectrum(f32, FRAME / 2 + 1);
        const N = 4 * FRAME;
        const n_frames = N / HOP;
        const gpa = std.testing.allocator;
        const in = try gpa.alloc(Sample(f32), N);
        defer gpa.free(in);
        const spec = try gpa.alloc(Spec, n_frames);
        defer gpa.free(spec);
        const out = try gpa.alloc(Sample(f32), N);
        defer gpa.free(out);
        h.fillImpulse(in);

        var an = S{};
        const made = an.pull(in, n_frames, spec);
        var sy = I{};
        _ = sy.pull(spec[0..made], N, out);

        const declared = S.algorithmic_latency * HOP + I.algorithmic_latency; // = FRAME−HOP
        const measured = h.measuredGroupDelay(h.sampleValues(out), 1e-3) orelse return error.NoResponse;
        try std.testing.expectEqual(@as(usize, FRAME - HOP), declared);
        try std.testing.expectEqual(declared, measured);
    }
}

// --- dual-mux: push ≡ pull on a stateful Rate transducer (gate §5.2) -------

test "dual-mux: the Framer's output is independent of input chunking (push ≡ pull, bit-exact)" {
    const FRAME = 64;
    const HOP = 32;
    const N = 1024; // a multiple of HOP
    const F = pan.spectral.Framer(f32num, FRAME, HOP);
    const TF = pan.spectral.TimeFrame(f32, FRAME);
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 21);
    const out_push = try gpa.alloc(TF, n_frames);
    defer gpa.free(out_push);
    const out_pull = try gpa.alloc(TF, n_frames);
    defer gpa.free(out_pull);

    var bp = F{};
    const made_push = h.renderRatePush(F, Sample(f32), TF, &bp, in, out_push, HOP); // one hop per chunk
    var bq = F{};
    const made_pull = h.renderRatePull(F, Sample(f32), TF, &bq, in, out_pull, N); // all at once

    try std.testing.expectEqual(n_frames, made_push);
    try std.testing.expectEqual(n_frames, made_pull);
    // Bit-exact across the two muxes (same kernel, same evolving ring state).
    const pf = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(out_push));
    const qf = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(out_pull));
    if (h.firstBitDivergence(pf, qf)) |idx| {
        std.debug.print("Framer push≠pull at f32 index {d}\n", .{idx});
        return error.PanDivergence;
    }
}

test "dual-mux: the Stft's spectra are chunking-independent (push ≡ pull, bit-exact)" {
    const FRAME = 64;
    const HOP = 32;
    const N = 512;
    const S = pan.Stft(f32num, FRAME, HOP);
    const Spec = pan.Spectrum(f32, FRAME / 2 + 1);
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 22);
    const out_push = try gpa.alloc(Spec, n_frames);
    defer gpa.free(out_push);
    const out_pull = try gpa.alloc(Spec, n_frames);
    defer gpa.free(out_pull);

    var bp = S{};
    _ = h.renderRatePush(S, Sample(f32), Spec, &bp, in, out_push, 2 * HOP); // two hops per chunk
    var bq = S{};
    _ = h.renderRatePull(S, Sample(f32), Spec, &bq, in, out_pull, N);

    const pf = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(out_push));
    const qf = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(out_pull));
    if (h.firstBitDivergence(pf, qf)) |idx| {
        std.debug.print("Stft push≠pull at f32 index {d}\n", .{idx});
        return error.PanDivergence;
    }
}

// --- reconstruction: the Stft/iStft Rate pair round-trips (≈) --------------

test "reconstruction: iStft ∘ Stft is the input delayed by FRAME−HOP (Hann COLA)" {
    const FRAME = 128;
    const HOP = 64;
    const N = 1024;
    const S = pan.Stft(f32num, FRAME, HOP);
    const I = pan.iStft(f32num, FRAME, HOP);
    const Spec = pan.Spectrum(f32, FRAME / 2 + 1);
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 23);
    const spec = try gpa.alloc(Spec, n_frames);
    defer gpa.free(spec);
    const out = try gpa.alloc(Sample(f32), N);
    defer gpa.free(out);

    var an = S{};
    const made = an.pull(in, n_frames, spec);
    var sy = I{};
    _ = sy.pull(spec[0..made], N, out);

    // The declared round-trip group delay is the Stft's analysis latency (frames)
    // × HOP = FRAME − HOP. Past it, the Hann-COLA overlap-add reconstructs exactly.
    const delay = FRAME - HOP;
    try std.testing.expectEqual(@as(usize, delay), @as(usize, S.algorithmic_latency * HOP));
    const xs = h.sampleValues(in);
    const ys = h.sampleValues(out);
    try h.allcloseF32(ys[FRAME..N], xs[FRAME - delay .. N - delay], .{ .approx = .{ .atol = 1e-4, .rtol = 1e-4 } });
}

// --- PowerSpectrum: a rate-1:1 type-changing Map ---------------------------

test "PowerSpectrum maps a Spectrum frame to its per-bin power |z|^2 (Map)" {
    const PS = pan.PowerSpectrum(f32num, 4);
    const Spec = pan.Spectrum(f32, 4);
    try std.testing.expect(pan.classify(PS) == .Map);
    var in = [_]Spec{.{
        .bin = .{
            .{ .re = 3, .im = 4 }, // 25
            .{ .re = 1, .im = 0 }, // 1
            .{ .re = 0, .im = 2 }, // 4
            .{ .re = 0, .im = 0 }, // 0
        },
    }};
    var out: [1]pan.FeatureFrame(4) = undefined;
    var ps = PS{};
    ps.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 25), out[0].v[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[0].v[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4), out[0].v[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].v[3], 1e-5);
}

// --- classifier / build-error contract -------------------------------------

test "the Rate seam blocks classify correctly; PowerSpectrum is a Map" {
    try std.testing.expect(pan.classify(pan.Stft(f32num, 64, 32)) == .Rate);
    try std.testing.expect(pan.classify(pan.iStft(f32num, 64, 32)) == .Rate);
    try std.testing.expect(pan.classify(pan.Framer(f32num, 64, 32)) == .Rate);
    try std.testing.expect(pan.classify(pan.Resampler(f32num, 2, 3, 6)) == .Rate);
    try std.testing.expect(pan.classify(pan.PowerSpectrum(f32num, 33)) == .Map);
}

// EXPECTED-@compileError (cannot run — they abort compilation), pinned as a
// disabled stub: a "Rate" declaring out_per_in but no algorithmic_latency is a
// build error (the orthogonal rate facts must BOTH be declared).
//
//   const Bad = struct {
//       pub const out_per_in = .{ 1, 2 };
//       pub fn pull(_: *@This(), _: []const Sample(f32), want: usize, _: []Sample(f32)) usize { return want; }
//   };
//   _ = pan.classify(Bad); // => "is a Rate but declares no algorithmic_latency"
