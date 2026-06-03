//! spectral_yoneda_test — the Yoneda characterization of the rate-elastic seam
//! `Rate` blocks in `src/spectral.zig`. The companion `spectral_test.zig` pins the
//! gate-level checks (one dual-mux, one latency probe, one reconstruction); THIS
//! suite exhausts the behaviour: a block is defined by its action under ALL
//! observations, so we enumerate the morphisms — every rate/latency declaration,
//! every chunking, every primed-from-silence transient, the half-spectrum width,
//! FFT conjugate symmetry / linearity, the `needed_input` companion, the COLA
//! identity for several `(FRAME,HOP)`, the resampler's L:M length ratio and group
//! delay, the `Spectrum`/`TimeFrame` element contracts, and the classifier facts.
//!
//! COMPARISON DISCIPLINE (the harness law):
//!   - pan-vs-pan (same block two ways: chunked≡whole, push≡pull, frame-by-frame
//!     ≡ batched, history-carry) is **bit-exact** (`firstBitDivergence` /
//!     `expectEqual`). A float "almost match" between two pan runs is a FAILURE.
//!   - oracle / reconstruction checks (FFT vs a hand oracle, `iStft∘Stft` ≈ delayed
//!     identity, resampler reconstructs a low-frequency sinusoid) use `allcloseF32`
//!     / `expectApproxEqAbs` with a stated tolerance — the FFT round-trip is the
//!     oracle of itself.
//!
//! Reject diagnostics use std.debug.print (never std.log.err — the 0.16 test
//! runner counts logged errors and flips the suite to non-zero exit).
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14): no @Type, no managed ArrayList, spectra are fixed comptime-sized
//! arrays, std.testing.allocator owns every heap buffer (leak-checked).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const f32num = pan.numericFor(.f32, .{});
const Sample = pan.Sample;
const eps: f32 = 1e-6;

// A pan-vs-pan bit-exact assertion over two element buffers, viewed as their raw
// f32 storage. `Spectrum`/`TimeFrame`/`Sample` are all POD arrays of f32, so the
// byte view is total. A divergence is a storage/ordering bug, never numerics.
fn expectBitExactElems(comptime T: type, a: []const T, b: []const T, what: []const u8) !void {
    const af = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(a));
    const bf = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(b));
    if (af.len != bf.len) {
        std.debug.print("{s}: length mismatch {d} vs {d}\n", .{ what, af.len, bf.len });
        return error.LengthMismatch;
    }
    if (h.firstBitDivergence(af, bf)) |idx| {
        std.debug.print("{s}: pan-vs-pan bit divergence at f32 index {d} ({d} vs {d})\n", .{ what, idx, af[idx], bf[idx] });
        return error.PanDivergence;
    }
}

// ===========================================================================
// Rate / latency declaration contract — the two orthogonal facts each block
// declares (the commit pass reads these; the type system cannot infer them).
// ===========================================================================

test "rate facts: Framer/Stft declare out_per_in=1:HOP and latency=FRAME/HOP-1; iStft is HOP:1 with zero latency" {
    inline for (.{ .{ 64, 32 }, .{ 64, 16 }, .{ 128, 64 }, .{ 256, 64 }, .{ 32, 32 } }) |fh| {
        const FRAME = fh[0];
        const HOP = fh[1];
        const F = pan.Framer(f32num, FRAME, HOP);
        const S = pan.Stft(f32num, FRAME, HOP);
        const I = pan.iStft(f32num, FRAME, HOP);

        // Analysis blocks: one frame per HOP samples in; priming latency in frames.
        try std.testing.expectEqual(@as(usize, 1), F.out_per_in[0]);
        try std.testing.expectEqual(@as(usize, HOP), F.out_per_in[1]);
        try std.testing.expectEqual(@as(usize, FRAME / HOP - 1), F.algorithmic_latency);
        try std.testing.expectEqual(@as(usize, 1), S.out_per_in[0]);
        try std.testing.expectEqual(@as(usize, HOP), S.out_per_in[1]);
        try std.testing.expectEqual(F.algorithmic_latency, S.algorithmic_latency);

        // The latency in OUTPUT frames times HOP is the FRAME-HOP audio-sample
        // round-trip delay — the identity the PDC pass compensates.
        try std.testing.expectEqual(@as(usize, FRAME - HOP), S.algorithmic_latency * HOP);

        // Synthesis: HOP samples per frame in, declares ZERO group delay (the whole
        // round-trip delay lives on the analysis side).
        try std.testing.expectEqual(@as(usize, HOP), I.out_per_in[0]);
        try std.testing.expectEqual(@as(usize, 1), I.out_per_in[1]);
        try std.testing.expectEqual(@as(usize, 0), I.algorithmic_latency);
    }
}

test "rate facts: Resampler declares out_per_in=L:M and group delay HALF/M (HALF for L=M=1)" {
    inline for (.{ .{ 1, 1, 8 }, .{ 2, 1, 8 }, .{ 1, 2, 8 }, .{ 2, 3, 6 }, .{ 3, 2, 12 } }) |lmh| {
        const L = lmh[0];
        const M = lmh[1];
        const HALF = lmh[2];
        const R = pan.Resampler(f32num, L, M, HALF);
        try std.testing.expectEqual(@as(usize, L), R.out_per_in[0]);
        try std.testing.expectEqual(@as(usize, M), R.out_per_in[1]);
        try std.testing.expectEqual(@as(usize, HALF / M), R.algorithmic_latency);
    }
    // The L=M=1 probe: group delay is exactly HALF.
    try std.testing.expectEqual(@as(usize, 8), pan.Resampler(f32num, 1, 1, 8).algorithmic_latency);
}

// ===========================================================================
// needed_input companion — the upstream demand the rate scheduler compiles.
// ===========================================================================

test "needed_input: Framer/Stft demand want*HOP samples; exact and monotone" {
    const FRAME = 64;
    const HOP = 32;
    var f = pan.Framer(f32num, FRAME, HOP){};
    var s = pan.Stft(f32num, FRAME, HOP){};
    inline for (.{ 0, 1, 2, 5, 17 }) |want| {
        try std.testing.expectEqual(@as(usize, want * HOP), f.needed_input(want));
        try std.testing.expectEqual(@as(usize, want * HOP), s.needed_input(want));
    }
}

test "needed_input: iStft demands ceil(want/HOP) frames to cover want output samples" {
    const FRAME = 64;
    const HOP = 32;
    var i = pan.iStft(f32num, FRAME, HOP){};
    try std.testing.expectEqual(@as(usize, 0), i.needed_input(0));
    try std.testing.expectEqual(@as(usize, 1), i.needed_input(1));
    try std.testing.expectEqual(@as(usize, 1), i.needed_input(HOP));
    try std.testing.expectEqual(@as(usize, 2), i.needed_input(HOP + 1));
    try std.testing.expectEqual(@as(usize, 2), i.needed_input(2 * HOP));
    try std.testing.expectEqual(@as(usize, 3), i.needed_input(2 * HOP + 1));
}

test "needed_input: Resampler demands ceil(want*M/L) input samples" {
    inline for (.{ .{ 1, 1, 8 }, .{ 2, 1, 8 }, .{ 1, 2, 8 }, .{ 2, 3, 6 } }) |lmh| {
        const L = lmh[0];
        const M = lmh[1];
        const HALF = lmh[2];
        var r = pan.Resampler(f32num, L, M, HALF){};
        inline for (.{ 0, 1, 3, 10, 31 }) |want| {
            const expected = (want * M + L - 1) / L; // ceil(want*M/L)
            try std.testing.expectEqual(@as(usize, expected), r.needed_input(want));
        }
    }
}

// ===========================================================================
// Element-type contracts: Spectrum(T,bins) and TimeFrame(T,FRAME).
// ===========================================================================

test "Spectrum element: half-spectrum width FRAME/2+1, sizeof, typeName, zero default" {
    inline for (.{ 32, 64, 128, 256 }) |FRAME| {
        const BINS = FRAME / 2 + 1;
        const Spec = pan.Spectrum(f32, BINS);
        try std.testing.expectEqual(@as(usize, BINS), Spec.bin_count);
        try std.testing.expect(Spec.lane == f32);
        // @sizeOf is bins * 2 * @sizeOf(T) (each bin is a Complex(f32)).
        try std.testing.expectEqual(@as(usize, BINS * 2 * @sizeOf(f32)), @sizeOf(Spec));
        const z = Spec{};
        for (z.bin) |c| {
            try std.testing.expectEqual(@as(f32, 0), c.re);
            try std.testing.expectEqual(@as(f32, 0), c.im);
        }
    }
    try std.testing.expectEqualStrings("Spectrum(f32,33)", pan.Spectrum(f32, 33).typeName());
}

test "Spectrum/TimeFrame: distinct (T,bins)/(T,FRAME) are distinct types" {
    try std.testing.expect(pan.Spectrum(f32, 33) != pan.Spectrum(f32, 17));
    try std.testing.expect(pan.Spectrum(f32, 33) != pan.Spectrum(f64, 33));
    try std.testing.expect(pan.spectral.TimeFrame(f32, 64) != pan.spectral.TimeFrame(f32, 128));
}

test "TimeFrame element: frame_len, sizeof FRAME*sizeof(T), typeName, zero default" {
    inline for (.{ 32, 64, 128 }) |FRAME| {
        const TF = pan.spectral.TimeFrame(f32, FRAME);
        try std.testing.expectEqual(@as(usize, FRAME), TF.frame_len);
        try std.testing.expect(TF.lane == f32);
        try std.testing.expectEqual(@as(usize, FRAME * @sizeOf(f32)), @sizeOf(TF));
        const z = TF{};
        for (z.s) |x| try std.testing.expectEqual(@as(f32, 0), x);
    }
    try std.testing.expectEqualStrings("TimeFrame(f32,128)", pan.spectral.TimeFrame(f32, 128).typeName());
}

// ===========================================================================
// Classification: the seam blocks are .Rate (PowerSpectrum is .Map). The Rate
// in/out elements are mintable from pull's signature.
// ===========================================================================

test "classify: Stft/iStft/Framer/Resampler are Rate; PowerSpectrum is Map" {
    try std.testing.expect(pan.classify(pan.Stft(f32num, 64, 32)) == .Rate);
    try std.testing.expect(pan.classify(pan.iStft(f32num, 64, 32)) == .Rate);
    try std.testing.expect(pan.classify(pan.Framer(f32num, 64, 32)) == .Rate);
    try std.testing.expect(pan.classify(pan.Resampler(f32num, 1, 1, 8)) == .Rate);
    try std.testing.expect(pan.classify(pan.Resampler(f32num, 2, 3, 6)) == .Rate);
    try std.testing.expect(pan.classify(pan.PowerSpectrum(f32num, 33)) == .Map);
}

test "classify: the Rate ports mint the seam element types from pull()" {
    const S = pan.Stft(f32num, 64, 32);
    try std.testing.expect(pan.port.RateInElem(S) == pan.Sample(f32));
    try std.testing.expect(pan.port.RateOutElem(S) == pan.Spectrum(f32, 33));

    const I = pan.iStft(f32num, 64, 32);
    try std.testing.expect(pan.port.RateInElem(I) == pan.Spectrum(f32, 33));
    try std.testing.expect(pan.port.RateOutElem(I) == pan.Sample(f32));

    const F = pan.Framer(f32num, 64, 32);
    try std.testing.expect(pan.port.RateInElem(F) == pan.Sample(f32));
    try std.testing.expect(pan.port.RateOutElem(F) == pan.spectral.TimeFrame(f32, 64));

    const R = pan.Resampler(f32num, 2, 3, 6);
    try std.testing.expect(pan.port.RateInElem(R) == pan.Sample(f32));
    try std.testing.expect(pan.port.RateOutElem(R) == pan.Sample(f32));
}

// ===========================================================================
// pull contract: produced count, hop-vs-buffer (HOP ∤ N) misalignment, the
// want clamp, and the empty-input degenerate.
// ===========================================================================

test "pull count: Framer produces min(want, floor(in/HOP)) frames; clamps on want and on input" {
    const FRAME = 64;
    const HOP = 32;
    const F = pan.Framer(f32num, FRAME, HOP);
    const TF = pan.spectral.TimeFrame(f32, FRAME);

    var in: [10 * HOP]Sample(f32) = undefined;
    h.fillNoise(&in, 1);
    var out: [32]TF = undefined;

    // Plenty of input, small want: clamped to want.
    {
        var f = F{};
        try std.testing.expectEqual(@as(usize, 3), f.pull(&in, 3, &out));
    }
    // Plenty of want, limited input: clamped to floor(in/HOP) = 10.
    {
        var f = F{};
        try std.testing.expectEqual(@as(usize, 10), f.pull(&in, 100, &out));
    }
    // Input not a multiple of HOP: floor divides — the leftover < HOP never
    // produces a partial frame on this call.
    {
        var f = F{};
        const ragged = in[0 .. 5 * HOP + 7]; // 5 full hops + 7 stragglers
        try std.testing.expectEqual(@as(usize, 5), f.pull(ragged, 100, &out));
    }
    // Empty input: zero frames, no crash.
    {
        var f = F{};
        try std.testing.expectEqual(@as(usize, 0), f.pull(in[0..0], 100, &out));
    }
}

test "pull count: iStft returns frames*HOP samples and clamps to floor(want/HOP) frames" {
    const FRAME = 64;
    const HOP = 32;
    const I = pan.iStft(f32num, FRAME, HOP);
    const Spec = pan.Spectrum(f32, FRAME / 2 + 1);

    var spec: [8]Spec = [_]Spec{.{}} ** 8;
    var out: [16 * HOP]Sample(f32) = undefined;

    var i = I{};
    // want = 5*HOP -> floor = 5 frames -> 5*HOP samples.
    try std.testing.expectEqual(@as(usize, 5 * HOP), i.pull(&spec, 5 * HOP, &out));
    // want not a multiple of HOP floors down: want = 3*HOP+1 -> 3 frames.
    var j = I{};
    try std.testing.expectEqual(@as(usize, 3 * HOP), j.pull(&spec, 3 * HOP + 1, &out));
    // Limited by available frames: 8 frames, huge want -> 8*HOP.
    var k = I{};
    try std.testing.expectEqual(@as(usize, 8 * HOP), k.pull(&spec, 100 * HOP, &out));
}

// ===========================================================================
// Sub-block / chunking invariance — the DEFINING Rate property: the same block
// instance, driven in any input chunking, yields the identical total output
// (the internal ring absorbs HOP∤N misalignment). Bit-exact (pan-vs-pan).
// ===========================================================================

test "chunking invariance: Framer output is bit-identical across HOP-multiple chunk sizes (push & pull)" {
    // The genuine invariant the implementation satisfies: when every input chunk is
    // a whole number of hops, the same Framer instance produces bit-identical
    // frames whether driven whole-stream, in big chunks, or one hop at a time. (The
    // sub-HOP-remainder case is characterized separately below — it is NOT
    // invariant, contrary to the module doc; see "BUG DETECTED".)
    const FRAME = 64;
    const HOP = 32;
    const N = 1024;
    const F = pan.Framer(f32num, FRAME, HOP);
    const TF = pan.spectral.TimeFrame(f32, FRAME);
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 31);

    const ref = try gpa.alloc(TF, n_frames);
    defer gpa.free(ref);
    const cand = try gpa.alloc(TF, n_frames);
    defer gpa.free(cand);

    // Reference: whole stream in one pull.
    {
        var b = F{};
        const made = b.pull(in, n_frames, ref);
        try std.testing.expectEqual(n_frames, made);
    }

    inline for (.{ HOP, 2 * HOP, 3 * HOP, FRAME, 8 * HOP }) |chunk| {
        @memset(std.mem.sliceAsBytes(cand), 0xAA); // dirty so a short write shows
        var bp = F{};
        const mp = h.renderRatePush(F, Sample(f32), TF, &bp, in, cand, chunk);
        try std.testing.expectEqual(n_frames, mp);
        try expectBitExactElems(TF, ref, cand, "Framer push chunk");

        @memset(std.mem.sliceAsBytes(cand), 0xBB);
        var bq = F{};
        const mq = h.renderRatePull(F, Sample(f32), TF, &bq, in, cand, chunk);
        try std.testing.expectEqual(n_frames, mq);
        try expectBitExactElems(TF, ref, cand, "Framer pull chunk");
    }
}

test "chunking invariance: Stft spectra are bit-identical across HOP-multiple chunk sizes (push & pull)" {
    const FRAME = 64;
    const HOP = 32;
    const N = 512;
    const S = pan.Stft(f32num, FRAME, HOP);
    const Spec = pan.Spectrum(f32, FRAME / 2 + 1);
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 32);

    const ref = try gpa.alloc(Spec, n_frames);
    defer gpa.free(ref);
    const cand = try gpa.alloc(Spec, n_frames);
    defer gpa.free(cand);

    {
        var b = S{};
        const made = b.pull(in, n_frames, ref);
        try std.testing.expectEqual(n_frames, made);
    }
    inline for (.{ HOP, 2 * HOP, FRAME, 3 * HOP }) |chunk| {
        @memset(std.mem.sliceAsBytes(cand), 0xAA);
        var bp = S{};
        const mp = h.renderRatePush(S, Sample(f32), Spec, &bp, in, cand, chunk);
        try std.testing.expectEqual(n_frames, mp);
        try expectBitExactElems(Spec, ref, cand, "Stft push chunk");

        @memset(std.mem.sliceAsBytes(cand), 0xBB);
        var bq = S{};
        const mq = h.renderRatePull(S, Sample(f32), Spec, &bq, in, cand, chunk);
        try std.testing.expectEqual(n_frames, mq);
        try expectBitExactElems(Spec, ref, cand, "Stft pull chunk");
    }
}

test "chunking invariance: a Framer driven in sub-HOP-remainder chunks must NOT drop input (module-doc contract)" {
    // The module doc (src/spectral.zig lines ~19-22) asserts:
    //   "The internal ring absorbs any hop-vs-buffer (HOP ∤ N) misalignment across
    //    calls, so the scheduler never assumes the hop divides the device block."
    // i.e. a Framer fed in chunks that are NOT whole multiples of HOP must still
    // produce the same total frames as a whole-stream pull — the un-consumed sub-HOP
    // tail of each chunk should be RETAINED and joined with the next chunk's head.
    //
    // BUG DETECTED: this contract is FALSE for the current implementation.
    //   Framer.pull (and Stft.pull, identically) compute frames = floor(in.len/HOP)
    //   and then ADVANCE the input by frames*HOP, never storing the leftover
    //   `in.len mod HOP` samples. The `history` ring holds windowed-output OVERLAP
    //   context, not un-consumed INPUT, so there is no input-remainder buffer.
    //   Expected (per doc): chunk=100 over N=1024 (HOP=32) -> 32 frames (whole).
    //   Actual:             each 100-sample chunk yields floor(100/32)=3 frames and
    //                       silently drops 4 samples; 10 such chunks + a 24-tail
    //                       -> 30 frames, 40 input samples lost.
    // The test asserts the DOCUMENTED contract and therefore FAILS until the
    // implementation retains the sub-HOP input remainder across calls (or the doc
    // is corrected to require HOP-multiple chunks). Diagnosis only — do not fix here.
    const FRAME = 64;
    const HOP = 32;
    const N = 1024;
    const F = pan.Framer(f32num, FRAME, HOP);
    const TF = pan.spectral.TimeFrame(f32, FRAME);
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 131);
    const cand = try gpa.alloc(TF, n_frames);
    defer gpa.free(cand);

    // chunk = 100 is 3 hops + 4 leftover — the misaligned (HOP ∤ chunk) case.
    var b = F{};
    const produced = h.renderRatePush(F, Sample(f32), TF, &b, in, cand, 100);
    if (produced != n_frames) {
        std.debug.print(
            "BUG: Framer dropped sub-HOP remainder across chunks: produced {d} frames, expected {d} (doc claims the ring absorbs HOP-misalignment)\n",
            .{ produced, n_frames },
        );
    }
    try std.testing.expectEqual(n_frames, produced);
}

test "history carry: a Framer driven frame-by-frame across calls equals one batched pull (bit-exact)" {
    // The internal history ring is the Rate smell — it MUST persist across pull
    // calls. Drive one instance one hop at a time and compare to a single batched
    // pull on a fresh instance; they must be bit-identical. A stateless impl (or a
    // reset-each-call bug) would diverge from the second frame on.
    const FRAME = 128;
    const HOP = 64;
    const N = 512;
    const F = pan.Framer(f32num, FRAME, HOP);
    const TF = pan.spectral.TimeFrame(f32, FRAME);
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 33);
    const batched = try gpa.alloc(TF, n_frames);
    defer gpa.free(batched);
    const piecemeal = try gpa.alloc(TF, n_frames);
    defer gpa.free(piecemeal);

    var a = F{};
    _ = a.pull(in, n_frames, batched);

    var b = F{};
    var fi: usize = 0;
    while (fi < n_frames) : (fi += 1) {
        const made = b.pull(in[fi * HOP ..][0..HOP], 1, piecemeal[fi..][0..1]);
        try std.testing.expectEqual(@as(usize, 1), made);
    }
    try expectBitExactElems(TF, batched, piecemeal, "Framer history carry");
}

// ===========================================================================
// Stft windowing & FFT semantics — characterized against hand-computed oracles.
// ===========================================================================

test "Stft windowing: a fully-primed DC frame has DC bin c*FRAME/2 and zero imaginary part" {
    // Feed a pure DC signal of value c for exactly FRAME samples (FRAME/HOP hops),
    // so the last frame's history holds all-c. Bin 0 of the FFT is the SUM of the
    // windowed frame = c * Σ_n hann[n]. For a periodic Hann of length FRAME,
    // Σ hann = FRAME/2. So bin[0].re == c * FRAME/2, im == 0. Pins window + DC bin.
    const FRAME = 64;
    const HOP = 16; // FRAME/HOP = 4 hops to fully prime
    const S = pan.Stft(f32num, FRAME, HOP);
    const Spec = pan.Spectrum(f32, FRAME / 2 + 1);
    const c: f32 = 0.5;

    var in: [FRAME]Sample(f32) = undefined;
    for (&in) |*s| s.ch[0] = c;
    var spec: [FRAME / HOP]Spec = undefined;
    var s = S{};
    const made = s.pull(&in, FRAME / HOP, &spec);
    try std.testing.expectEqual(@as(usize, FRAME / HOP), made);

    const last = spec[FRAME / HOP - 1];
    try std.testing.expectApproxEqAbs(c * @as(f32, FRAME) / 2.0, last.bin[0].re, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), last.bin[0].im, 1e-3);
}

test "Stft FFT linearity: spectrum of (a*x + b*y) equals a*spectrum(x) + b*spectrum(y)" {
    // The windowed FFT is linear, so its action on a linear combination is the
    // linear combination of actions — a defining morphism property. Oracle-tier ≈
    // (two independent runs accumulate different round-off than one combined run).
    const FRAME = 64;
    const HOP = 32;
    const S = pan.Stft(f32num, FRAME, HOP);
    const BINS = FRAME / 2 + 1;
    const Spec = pan.Spectrum(f32, BINS);
    const N = 256;
    const n_frames = N / HOP;
    const a: f32 = 1.7;
    const b: f32 = -0.4;

    const gpa = std.testing.allocator;
    const x = try gpa.alloc(Sample(f32), N);
    defer gpa.free(x);
    const y = try gpa.alloc(Sample(f32), N);
    defer gpa.free(y);
    const comb = try gpa.alloc(Sample(f32), N);
    defer gpa.free(comb);
    h.fillNoise(x, 41);
    h.fillNoise(y, 42);
    for (comb, x, y) |*c, xi, yi| c.ch[0] = a * xi.ch[0] + b * yi.ch[0];

    const sx = try gpa.alloc(Spec, n_frames);
    defer gpa.free(sx);
    const sy = try gpa.alloc(Spec, n_frames);
    defer gpa.free(sy);
    const sc = try gpa.alloc(Spec, n_frames);
    defer gpa.free(sc);

    var bx = S{};
    _ = bx.pull(x, n_frames, sx);
    var by = S{};
    _ = by.pull(y, n_frames, sy);
    var bc = S{};
    _ = bc.pull(comb, n_frames, sc);

    for (sx, sy, sc, 0..) |fx, fy, fc, fi| {
        for (0..BINS) |bin| {
            const re = a * fx.bin[bin].re + b * fy.bin[bin].re;
            const im = a * fx.bin[bin].im + b * fy.bin[bin].im;
            std.testing.expectApproxEqAbs(re, fc.bin[bin].re, 1e-3) catch |e| {
                std.debug.print("linearity re mismatch frame {d} bin {d}\n", .{ fi, bin });
                return e;
            };
            std.testing.expectApproxEqAbs(im, fc.bin[bin].im, 1e-3) catch |e| {
                std.debug.print("linearity im mismatch frame {d} bin {d}\n", .{ fi, bin });
                return e;
            };
        }
    }
}

test "Stft half-spectrum: bin 0 and the Nyquist bin (FRAME/2) are real for real input" {
    // The rfft of a real frame has a real DC bin and a real Nyquist bin; the half
    // spectrum keeps both (bins 0..FRAME/2 inclusive = FRAME/2+1). A non-real DC or
    // Nyquist would mean the FFT or the half-slice is wrong.
    const FRAME = 64;
    const HOP = 32;
    const S = pan.Stft(f32num, FRAME, HOP);
    const BINS = FRAME / 2 + 1;
    const Spec = pan.Spectrum(f32, BINS);
    const N = 256;
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 43);
    const spec = try gpa.alloc(Spec, n_frames);
    defer gpa.free(spec);

    var s = S{};
    _ = s.pull(in, n_frames, spec);
    for (spec) |fr| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), fr.bin[0].im, 1e-4); // DC real
        try std.testing.expectApproxEqAbs(@as(f32, 0), fr.bin[BINS - 1].im, 1e-4); // Nyquist real
    }
}

test "Stft of a single windowed impulse has flat magnitude across all bins" {
    // Drive the Stft (HOP=FRAME so each frame is exactly the last FRAME inputs) so
    // the frame holds a single nonzero sample at the last position. The FFT of a
    // single windowed impulse at position p has MAGNITUDE flat across all bins =
    // w[p] — a defining FFT property surfaced through the seam.
    const FRAME = 64;
    const HOP = 64;
    const S = pan.Stft(f32num, FRAME, HOP);
    const BINS = FRAME / 2 + 1;
    const Spec = pan.Spectrum(f32, BINS);

    var in: [FRAME]Sample(f32) = undefined;
    for (&in) |*s| s.ch[0] = 0;
    in[FRAME - 1].ch[0] = 1.0; // impulse at the last position of the frame
    var spec: [1]Spec = undefined;
    var s = S{};
    _ = s.pull(&in, 1, &spec);

    const w_last: f32 = 0.5 * (1.0 - @cos(2.0 * std.math.pi * @as(f32, FRAME - 1) / @as(f32, FRAME)));
    for (spec[0].bin) |z| {
        const mag = @sqrt(z.re * z.re + z.im * z.im);
        try std.testing.expectApproxEqAbs(w_last, mag, 1e-4);
    }
}

// ===========================================================================
// COLA reconstruction: iStft ∘ Stft = input delayed by FRAME-HOP, exact up to
// FFT round-off, for several (FRAME,HOP) at 50% overlap.
// ===========================================================================

test "COLA reconstruction: iStft∘Stft is the input delayed by FRAME-HOP at 50% overlap" {
    inline for (.{ .{ 64, 32 }, .{ 128, 64 }, .{ 256, 128 } }) |fh| {
        const FRAME = fh[0];
        const HOP = fh[1];
        const S = pan.Stft(f32num, FRAME, HOP);
        const I = pan.iStft(f32num, FRAME, HOP);
        const Spec = pan.Spectrum(f32, FRAME / 2 + 1);
        const N = 2048;
        const n_frames = N / HOP;

        const gpa = std.testing.allocator;
        const in = try gpa.alloc(Sample(f32), N);
        defer gpa.free(in);
        h.fillNoise(in, 50 + FRAME);
        const spec = try gpa.alloc(Spec, n_frames);
        defer gpa.free(spec);
        const out = try gpa.alloc(Sample(f32), N);
        defer gpa.free(out);

        var an = S{};
        const made = an.pull(in, n_frames, spec);
        var sy = I{};
        _ = sy.pull(spec[0..made], N, out);

        const delay = FRAME - HOP;
        const xs = h.sampleValues(in);
        const ys = h.sampleValues(out);
        // Steady state from n=FRAME (both overlapping frames primed). Tolerance is
        // the FFT round-off of two transforms in f32.
        try h.allcloseF32(ys[FRAME..N], xs[FRAME - delay .. N - delay], .{ .approx = .{ .atol = 2e-4, .rtol = 2e-4 } });
    }
}

test "COLA reconstruction: the round-trip is bit-identical regardless of how the seam is chunked" {
    // Two pan runs of the SAME (Stft -> iStft) chain: one whole-stream, one with
    // the analysis driven in odd 3-hop chunks via the push driver. Both the
    // intermediate spectra and the reconstructed output must be BIT-identical
    // (pan-vs-pan), not merely close — the ring state makes the seam chunking-
    // invariant end-to-end.
    const FRAME = 64;
    const HOP = 32;
    const S = pan.Stft(f32num, FRAME, HOP);
    const I = pan.iStft(f32num, FRAME, HOP);
    const Spec = pan.Spectrum(f32, FRAME / 2 + 1);
    const N = 1024;
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 60);

    const spec_a = try gpa.alloc(Spec, n_frames);
    defer gpa.free(spec_a);
    const spec_b = try gpa.alloc(Spec, n_frames);
    defer gpa.free(spec_b);
    const out_a = try gpa.alloc(Sample(f32), N);
    defer gpa.free(out_a);
    const out_b = try gpa.alloc(Sample(f32), N);
    defer gpa.free(out_b);

    var an_a = S{};
    var sy_a = I{};
    _ = an_a.pull(in, n_frames, spec_a);
    _ = sy_a.pull(spec_a, N, out_a);

    var an_b = S{};
    _ = h.renderRatePush(S, Sample(f32), Spec, &an_b, in, spec_b, 3 * HOP);
    var sy_b = I{};
    _ = sy_b.pull(spec_b, N, out_b);

    try expectBitExactElems(Spec, spec_a, spec_b, "round-trip analysis chunked");
    try expectBitExactElems(Sample(f32), out_a, out_b, "round-trip output chunked");
}

// ===========================================================================
// PowerSpectrum — a rate-1:1 type-changing Map (NOT a Rate). |z|^2 per bin.
// ===========================================================================

test "PowerSpectrum: |z|^2 per bin over a batch (rate-1:1)" {
    const PS = pan.PowerSpectrum(f32num, 4);
    const Spec = pan.Spectrum(f32, 4);
    var in = [_]Spec{
        .{ .bin = .{ .{ .re = 3, .im = 4 }, .{ .re = 1, .im = 0 }, .{ .re = 0, .im = 2 }, .{ .re = 0, .im = 0 } } },
        .{ .bin = .{ .{ .re = -1, .im = -1 }, .{ .re = 5, .im = 0 }, .{ .re = 0, .im = -3 }, .{ .re = 2, .im = 2 } } },
    };
    var out: [2]pan.FeatureFrame(4) = undefined;
    var ps = PS{};
    ps.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 25), out[0].v[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[0].v[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4), out[0].v[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].v[3], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), out[1].v[0], 1e-5); // 1+1
    try std.testing.expectApproxEqAbs(@as(f32, 25), out[1].v[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9), out[1].v[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 8), out[1].v[3], 1e-5); // 4+4
}

test "PowerSpectrum: phase-invariant (|z|^2 == |z*e^{iθ}|^2) and zero on the zero spectrum" {
    // Rotating every bin by the same phase leaves |z|^2 unchanged — the defining
    // observation of a power (vs a complex) feature.
    const PS = pan.PowerSpectrum(f32num, 3);
    const Spec = pan.Spectrum(f32, 3);
    const theta: f32 = 0.9;
    const co = @cos(theta);
    const si = @sin(theta);

    var base = [_]Spec{.{ .bin = .{ .{ .re = 2, .im = 1 }, .{ .re = -3, .im = 4 }, .{ .re = 0.5, .im = -0.5 } } }};
    var rot: [1]Spec = undefined;
    for (0..3) |bi| {
        const z = base[0].bin[bi];
        rot[0].bin[bi] = .{ .re = z.re * co - z.im * si, .im = z.re * si + z.im * co };
    }
    var ob: [1]pan.FeatureFrame(3) = undefined;
    var orr: [1]pan.FeatureFrame(3) = undefined;
    var ps = PS{};
    ps.process(&base, &ob);
    ps.process(&rot, &orr);
    for (0..3) |bi| try std.testing.expectApproxEqAbs(ob[0].v[bi], orr[0].v[bi], 1e-4);

    var zero = [_]Spec{.{}};
    var oz: [1]pan.FeatureFrame(3) = undefined;
    ps.process(&zero, &oz);
    for (oz[0].v) |p| try std.testing.expectEqual(@as(f32, 0), p);
}

test "PowerSpectrum: composed after Stft, the feature equals re^2+im^2 of each bin (bit-exact)" {
    // The seam composes: feed a real signal through Stft then PowerSpectrum; the
    // feature equals re^2+im^2 of each retained bin. PowerSpectrum is a
    // deterministic transform of the Stft bins, so this is pan-vs-pan bit-exact.
    const FRAME = 32;
    const HOP = 16;
    const BINS = FRAME / 2 + 1;
    const S = pan.Stft(f32num, FRAME, HOP);
    const PS = pan.PowerSpectrum(f32num, BINS);
    const Spec = pan.Spectrum(f32, BINS);
    const N = 128;
    const n_frames = N / HOP;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 70);
    const spec = try gpa.alloc(Spec, n_frames);
    defer gpa.free(spec);
    const feat = try gpa.alloc(pan.FeatureFrame(BINS), n_frames);
    defer gpa.free(feat);

    var s = S{};
    _ = s.pull(in, n_frames, spec);
    var ps = PS{};
    ps.process(spec, feat);

    for (spec, feat) |fr, ft| {
        for (0..BINS) |bi| {
            const expect: f32 = fr.bin[bi].re * fr.bin[bi].re + fr.bin[bi].im * fr.bin[bi].im;
            try std.testing.expectEqual(@as(u32, @bitCast(expect)), @as(u32, @bitCast(ft.v[bi])));
        }
    }
}

// ===========================================================================
// Resampler — windowed-sinc rational resampler.
// ===========================================================================

test "Resampler L=M=1: impulse response peaks at HALF and is symmetric (linear phase)" {
    inline for (.{ 2, 4, 8, 16 }) |HALF| {
        const R = pan.Resampler(f32num, 1, 1, HALF);
        const N = 4 * HALF + 8;
        var in: [N]Sample(f32) = undefined;
        var out: [N]Sample(f32) = undefined;
        h.fillImpulse(&in);
        var rs = R{};
        _ = rs.pull(&in, N, &out);
        const measured = h.measuredGroupDelay(h.sampleValues(&out), eps) orelse return error.NoResponse;
        try std.testing.expectEqual(@as(usize, HALF), measured);
        try std.testing.expectEqual(@as(usize, R.algorithmic_latency), measured);

        // Linear-phase symmetry: the impulse response is symmetric about HALF.
        const ys = h.sampleValues(&out);
        var k: usize = 1;
        while (k <= HALF) : (k += 1) {
            try std.testing.expectApproxEqAbs(ys[HALF - k], ys[HALF + k], 1e-5);
        }
    }
}

test "Resampler L=M=1: unity DC gain (a constant passes through at its value, past the transient)" {
    // The prototype is normalized to unity DC gain, so a DC input reconstructs to
    // the same DC value once the FIR is fully inside the signal.
    const HALF = 8;
    const R = pan.Resampler(f32num, 1, 1, HALF);
    const N = 8 * HALF;
    const c: f32 = 0.75;
    var in: [N]Sample(f32) = undefined;
    for (&in) |*s| s.ch[0] = c;
    var out: [N]Sample(f32) = undefined;
    var rs = R{};
    _ = rs.pull(&in, N, &out);
    const ys = h.sampleValues(&out);
    // Past 2*HALF the whole tap window sees only c; output == c (unity DC).
    var n: usize = 2 * HALF;
    while (n < N - 2 * HALF) : (n += 1) {
        try std.testing.expectApproxEqAbs(c, ys[n], 1e-3);
    }
}

test "Resampler: output-length ratio tracks L:M, pull returns want, needed_input is consistent" {
    inline for (.{ .{ 2, 1, 8 }, .{ 1, 2, 8 }, .{ 2, 3, 6 }, .{ 3, 2, 12 } }) |lmh| {
        const L = lmh[0];
        const M = lmh[1];
        const HALF = lmh[2];
        const R = pan.Resampler(f32num, L, M, HALF);
        const IN = 120; // input samples available
        const want = (IN * L) / M; // outputs the L:M ratio yields from IN inputs

        const gpa = std.testing.allocator;
        const in = try gpa.alloc(Sample(f32), IN);
        defer gpa.free(in);
        h.fillNoise(in, 80 + L * 10 + M);
        const out = try gpa.alloc(Sample(f32), want);
        defer gpa.free(out);

        var rs = R{};
        const produced = rs.pull(in, want, out);
        try std.testing.expectEqual(@as(usize, want), produced);

        // needed_input(want) must not exceed the inputs we supplied (ceil rounding).
        var probe = R{};
        try std.testing.expect(probe.needed_input(want) <= IN);
    }
}

test "Resampler L=2,M=1 reconstructs an upsampled low-frequency sinusoid (oracle ≈)" {
    // A sinusoid well below the cutoff passes through the anti-imaging filter; the
    // 2x-upsampled output, past the group delay, matches the same sinusoid sampled
    // at the output rate. Oracle-tier ≈ (a windowed-sinc approximates ideal
    // interpolation; a frequency well inside the passband reproduces to a few %).
    const L = 2;
    const M = 1;
    const HALF = 32; // a longer filter -> sharper passband
    const R = pan.Resampler(f32num, L, M, HALF);
    const IN = 256;
    const want = IN * L / M;

    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), IN);
    defer gpa.free(in);
    const out = try gpa.alloc(Sample(f32), want);
    defer gpa.free(out);

    const cycles: f32 = 4.0;
    const w_in: f32 = 2.0 * std.math.pi * cycles / @as(f32, IN);
    for (in, 0..) |*s, n| s.ch[0] = @sin(w_in * @as(f32, @floatFromInt(n)));

    var rs = R{};
    _ = rs.pull(in, want, out);

    const gd: usize = HALF / M;
    const w_out: f32 = w_in / @as(f32, L);
    const ys = h.sampleValues(out);
    var n: usize = gd + 4 * HALF;
    var max_err: f32 = 0;
    while (n < want - 4 * HALF) : (n += 1) {
        const phase = w_out * @as(f32, @floatFromInt(n - gd));
        const expect = @sin(phase);
        const e = @abs(ys[n] - expect);
        if (e > max_err) max_err = e;
    }
    if (max_err > 0.05) {
        std.debug.print("Resampler L=2 reconstruction max err {d} > 0.05\n", .{max_err});
        return error.ReconstructionTooFar;
    }
}

test "Resampler: a single whole-stream pull has no cross-call history (documented limitation)" {
    // Documented contract: the Resampler is stateless within a single whole-stream
    // pull (the left context is the implicit zero pre-roll) and carries NO input-
    // history ring across pull calls. So pulling the tail half on its own restarts
    // from a zero pre-roll and its first ~HALF samples differ from the whole-stream
    // run (which had real left context there). This PINS the limitation so a future
    // "added streaming history" change is caught as a behaviour change here.
    const HALF = 8;
    const R = pan.Resampler(f32num, 1, 1, HALF);
    const N = 64;
    const gpa = std.testing.allocator;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 90);

    const whole = try gpa.alloc(Sample(f32), N);
    defer gpa.free(whole);
    var rs = R{};
    _ = rs.pull(in, N, whole);

    const half = N / 2;
    const part2 = try gpa.alloc(Sample(f32), half);
    defer gpa.free(part2);
    var rs2 = R{};
    _ = rs2.pull(in[half..], half, part2);

    const ws = h.sampleValues(whole);
    const ps = h.sampleValues(part2);
    var diverges = false;
    var i: usize = 0;
    while (i < HALF) : (i += 1) {
        if (@abs(ws[half + i] - ps[i]) > 1e-4) diverges = true;
    }
    try std.testing.expect(diverges);
}

// ===========================================================================
// Lane-genericity: the blocks instantiate over f64 as well as f32.
// ===========================================================================

test "the generic instantiates and reconstructs over f64 (Lane-genericity)" {
    const f64num = pan.numericFor(.f64, .{});
    const FRAME = 64;
    const HOP = 32;
    const S = pan.Stft(f64num, FRAME, HOP);
    const I = pan.iStft(f64num, FRAME, HOP);
    const Spec = pan.Spectrum(f64, FRAME / 2 + 1);
    try std.testing.expectEqual(@as(usize, FRAME - HOP), S.algorithmic_latency * HOP);

    const N = 256;
    var in: [N]pan.Sample(f64) = undefined;
    var rng = std.Random.DefaultPrng.init(99);
    for (&in) |*s| s.ch[0] = rng.random().float(f64) * 2 - 1;
    var spec: [N / HOP]Spec = undefined;
    var out: [N]pan.Sample(f64) = undefined;
    var an = S{};
    const made = an.pull(&in, N / HOP, &spec);
    var sy = I{};
    _ = sy.pull(spec[0..made], N, &out);

    // f64 reconstruction is far tighter than f32; assert a much smaller tolerance.
    const delay = FRAME - HOP;
    var n: usize = FRAME;
    while (n < N) : (n += 1) {
        try std.testing.expectApproxEqAbs(in[n - delay].ch[0], out[n].ch[0], 1e-9);
    }
}

// NOTE — the float-only @compileError guard (src/spectral.zig `requireFloat`):
// instantiating any of these blocks with an integer numeric (e.g.
// `numericFor(.i16, .{})`) triggers
//   @compileError("pan: the spectral / resampler Rate blocks are float-only ...")
// which ABORTS compilation. A @compileError cannot be exercised from a running
// test (there is no negative-compilation harness this phase), so it is documented
// here as a disabled stub rather than run:
//
//   _ = pan.Stft(pan.numericFor(.i16, .{}), 64, 32);      // => float-only @compileError
//   _ = pan.Resampler(pan.numericFor(.i16, .{}), 1, 1, 8); // => float-only @compileError
//
// The positive side (f32 above, f64 in the preceding test) is covered exhaustively.
