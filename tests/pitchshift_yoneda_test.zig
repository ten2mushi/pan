//! pitchshift_yoneda_test — the Yoneda behavioural specification of
//! `PitchShift(num, FRAME)` in `src/spectral.zig`. A block is defined by its
//! action under ALL observations, so this suite enumerates the morphisms that
//! pin PitchShift's contract end to end, rather than spot-checking one path.
//!
//! WHAT PitchShift IS (restated inline so this file is self-contained):
//!   It shifts pitch WITHOUT changing duration, by composing two variable-rate
//!   stages: (1) a TimeStretch by the pitch factor P — same pitch, P× longer —
//!   then (2) a linear resample by 1/P (read the stretched stream at a step of
//!   P input-samples-per-output), which slides the pitch UP by P and returns
//!   the stream to its original length. Net out:in is exactly 1:1, so the
//!   COMPOSITE is rate-preserving: it is a `Map` SOURCE (process takes only an
//!   `out` buffer; the asset is a borrowed field, not an input port), even
//!   though it is built from two VariRate stages internally.
//!
//! THE QUALITY BOUNDARY (asserted honestly, not papered over):
//!   PitchShift inherits the plain overlap-add (OLA) TimeStretch tier, which
//!   phase-blurs strongly tonal material. So for sinusoids we assert the pitch
//!   TREND — dominant period scaling (via zero-crossing count and normalized
//!   cross-correlation), preserved energy, preserved duration — NOT waveform
//!   bit-fidelity. We do NOT assert clean sinusoids out. Two properties ARE
//!   exact and are asserted exactly: DC/constant preservation (both stages are
//!   unity-gain on a constant), and chunked≡whole resumability (same block run
//!   two ways must be bit-identical — the inner TimeStretch cursor + the
//!   resample phase are pure state machines).
//!
//! COMPARISON DISCIPLINE (the harness law):
//!   - pan-vs-pan (the SAME block run two ways: chunked vs one big process) is
//!     **bit-exact** — a float "almost match" between two pan runs is a FAILURE,
//!     because both paths run identical kernels on identical inputs; a
//!     divergence is a state-resumption bug, never numerics.
//!   - shape/trend checks against an analytic asset (period scaling, energy,
//!     correlation) use tolerances with a STATED rationale, because OLA blur
//!     makes bit-fidelity meaningless for tonal material.
//!
//! Reject diagnostics use std.debug.print (never std.log.err — the 0.16 test
//! runner counts logged errors and flips the suite to a non-zero exit).
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14): no @Type, no managed ArrayList, every fixed buffer is a
//! comptime-sized array, std.testing.allocator owns the one heap buffer
//! (leak-checked). PitchShift owns no heap; the suite is mostly stack arrays.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.Sample;
const f32num = pan.numericFor(.f32, .{});
const FRAME = 64;
const PS = pan.PitchShift(f32num, FRAME);

// --- local observation helpers ---------------------------------------------

/// Index of the LAST sample whose magnitude exceeds `thr`, or 0 if all silent.
/// This is the observable "duration" of a finite asset's pitch-shifted output:
/// once the inner TimeStretch has consumed the whole asset it emits silence,
/// and the resampler maps that boundary back to ≈ the asset length regardless
/// of pitch. The constant-duration contract is exactly this index being ≈ L.
fn lastAbove(out: []const Sample(f32), thr: f32) usize {
    var last: usize = 0;
    for (out, 0..) |s, i| {
        if (@abs(s.ch[0]) > thr) last = i;
    }
    return last;
}

/// Normalized cross-correlation of `out[lo..hi]` against `asset` shifted back
/// by `lag` (Pearson-style, in [-1, 1]). At pitch=1 the output is a near-exact
/// (lag-0) copy of the asset — the only nonlinearity is the unity-gain Hann OLA
/// — so this approaches 1.0. At pitch≠1 the spectral content has slid, so the
/// lag-0 correlation against the ORIGINAL asset is much weaker. That contrast
/// is the discriminating identity test.
fn ncorrLag(out: []const Sample(f32), asset: []const f32, lo: usize, hi: usize, lag: usize) f32 {
    var num: f32 = 0;
    var eo: f32 = 0;
    var ea: f32 = 0;
    var i = lo;
    while (i < hi) : (i += 1) {
        const x = out[i].ch[0];
        const y = asset[i - lag];
        num += x * y;
        eo += x * x;
        ea += y * y;
    }
    return num / @sqrt(eo * ea + 1e-12);
}

/// Best normalized cross-correlation over candidate lags `0..=maxlag`.
fn bestNcorr(out: []const Sample(f32), asset: []const f32, lo: usize, hi: usize, maxlag: usize) f32 {
    var best: f32 = -2;
    var lag: usize = 0;
    while (lag <= maxlag) : (lag += 1) {
        const c = ncorrLag(out, asset, lo, hi, lag);
        if (c > best) best = c;
    }
    return best;
}

/// Goertzel-style single-bin DFT magnitude of `out[lo..hi]` at normalized
/// angular frequency `w` (rad/sample) — a clean, aliasing-robust measure of how
/// much energy sits at a given frequency. Unlike the zero-crossing proxy (which
/// OLA harmonic-fold artifacts inflate at higher fundamentals), this reads the
/// true spectral content, so it is the trustworthy instrument for the pitch
/// DIRECTION claim.
fn dftMag(out: []const Sample(f32), lo: usize, hi: usize, w: f32) f32 {
    var re: f32 = 0;
    var im: f32 = 0;
    var i = lo;
    while (i < hi) : (i += 1) {
        const a = w * @as(f32, @floatFromInt(i));
        re += out[i].ch[0] * @cos(a);
        im += out[i].ch[0] * @sin(a);
    }
    return @sqrt(re * re + im * im);
}

/// The dominant normalized angular frequency in `out[lo..hi]`, found by scanning
/// a fine grid of `dftMag` (the spectral peak). Used to characterize the ACTUAL
/// pitch the block emits versus the pitch the parameter requested.
fn dominantFreq(out: []const Sample(f32), lo: usize, hi: usize) f32 {
    var bestf: f32 = 0;
    var bestm: f32 = -1;
    var k: usize = 1;
    while (k < 300) : (k += 1) {
        const f = @as(f32, @floatFromInt(k)) * 0.005; // grid 0.005 rad up to ~1.5
        const m = dftMag(out, lo, hi, f);
        if (m > bestm) {
            bestm = m;
            bestf = f;
        }
    }
    return bestf;
}

/// Mean-square energy over a window — the duration-preserving stages are
/// unity-gain, so a settled window of the pitch-shifted sinusoid carries ≈ the
/// same energy regardless of pitch (the resampler is linear interpolation, a
/// mild low-pass, so we allow a generous band rather than an equality).
fn meanSquare(out: []const Sample(f32), lo: usize, hi: usize) f32 {
    var e: f32 = 0;
    var i = lo;
    while (i < hi) : (i += 1) e += out[i].ch[0] * out[i].ch[0];
    return e / @as(f32, @floatFromInt(hi - lo));
}

/// Fill a stack asset with a sinusoid of angular increment `w` (rad/sample).
fn sineAsset(comptime L: usize, asset: *[L]Sample(f32), w: f32) void {
    var ph: f32 = 0;
    for (asset) |*s| {
        s.ch[0] = @sin(ph);
        ph += w;
    }
}

// ===========================================================================
// 1. Structural identity — the classifier facts (Yoneda: WHAT category object)
// ===========================================================================

test "PitchShift classifies as a Map, not a VariRate" {
    // The composite's net out:in is exactly 1:1 (duration is preserved), so it
    // is rate-preserving and must NOT declare `rate_bounds` (that would make it
    // a VariRate and demand a static rate plan it does not have). It exposes a
    // plain `process`, hence `.Map`. This is the load-bearing structural claim:
    // the whole point of PitchShift is that the two VariRate stages cancel.
    try std.testing.expectEqual(pan.BlockClass.Map, pan.classify(PS));
}

test "PitchShift is a Map SOURCE — process has zero sample-input ports" {
    // A Source's output length is set by the pull demand (out.len), not by an
    // input slice; the asset is a borrowed FIELD, not a port. `isSource` counts
    // the input slices on `process` after `self` and must find zero.
    try std.testing.expect(comptime pan.isSource(PS));
}

test "PitchShift exposes exactly the pitch param and no rate machinery" {
    // The param surface is `.{ .pitch = Scalar(f32) }` and nothing else; it is a
    // pure Map, so it must NOT carry the VariRate/Rate decls.
    try std.testing.expect(@hasField(@TypeOf(PS.params), "pitch"));
    try std.testing.expect(!@hasDecl(PS, "rate_bounds"));
    try std.testing.expect(!@hasDecl(PS, "out_per_in"));
    try std.testing.expect(!@hasDecl(PS, "pull"));
    try std.testing.expect(@hasDecl(PS, "process"));
}

// ===========================================================================
// 2. Constant duration — the defining property of a pitch shifter
// ===========================================================================

test "producing N output samples consumes about N asset samples at every pitch" {
    // The inner TimeStretch by P makes a P×-longer stream; the resample by 1/P
    // gives it back. So the output stays non-silent for ≈ the asset length L,
    // independent of pitch. We assert the observable duration (last sample above
    // a noise floor) lands within a small grain-sized band of L for pitch in
    // {0.5, 1, 2}. If duration tracked pitch (a TimeStretch bug, no resample),
    // pitch=0.5 would end at ≈ 2L and pitch=2 at ≈ L/2 — far outside the band.
    const L = 4000;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, 0.2);

    const N = 6000; // longer than L so the silence tail is observable
    inline for (.{ 0.5, 1.0, 2.0 }) |p| {
        var ps = PS{ .data = &asset };
        ps.setParam(0, p);
        var out: [N]Sample(f32) = undefined;
        ps.process(&out);

        const last = lastAbove(&out, 1e-4);
        // Tolerance = a couple of FRAMEs of OLA edge slop around L. The whole
        // discrimination is that `last` is near L (4000), not near 2L or L/2.
        if (last < L - 4 * FRAME or last > L + 4 * FRAME) {
            std.debug.print(
                "duration not preserved at pitch={d}: last non-silent idx {} not within {} of asset length {}\n",
                .{ p, last, 4 * FRAME, L },
            );
            return error.DurationNotConstant;
        }
    }
}

test "energy of a settled window is comparable across pitches (unity-gain stages)" {
    // Both stages are unity-gain (Hann 50% OLA is COLA-exact; linear resample is
    // gain 1 at DC, a mild low-pass at the top). A settled mid window of the
    // pitch-shifted sinusoid therefore carries comparable energy at every pitch
    // — duration AND amplitude are preserved, only the period changes. We assert
    // each pitch's mean-square is within 2× of the pitch=1 reference (the band is
    // wide on purpose: the resampler's interpolation low-pass attenuates the
    // up-shifted pitch=2 content somewhat — that is expected, not a bug).
    const L = 4000;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, 0.12);
    const N = 3000;

    var refms: f32 = 0;
    inline for (.{ 1.0, 0.5, 2.0 }) |p| {
        var ps = PS{ .data = &asset };
        ps.setParam(0, p);
        var out: [N]Sample(f32) = undefined;
        ps.process(&out);
        const ms = meanSquare(&out, 500, 2500);
        if (p == 1.0) {
            refms = ms;
            // A pure sinusoid has mean-square 0.5; OLA preserves that closely.
            try std.testing.expect(ms > 0.3 and ms < 0.6);
        } else {
            if (ms < 0.4 * refms or ms > 2.0 * refms) {
                std.debug.print(
                    "energy at pitch={d} ({d:.4}) escaped [0.4,2.0]× the pitch=1 reference ({d:.4})\n",
                    .{ p, ms, refms },
                );
                return error.EnergyNotPreserved;
            }
        }
    }
}

// ===========================================================================
// 3. Pitch direction — the dominant frequency should scale BY P (it does NOT)
// ===========================================================================
//
// This is the heart of a pitch shifter: with pitch=P, a sinusoid of frequency w
// must come out dominated by w·P (an octave up for P=2, an octave down for
// P=0.5). We measure the ACTUAL dominant frequency spectrally (dftMag, which is
// robust to the OLA harmonic-fold artifacts that fool a zero-crossing proxy).
//
// --------------------------------------------------------------------------
// The pitch-shift contract: the output's dominant frequency is w·P (the input
// fundamental scaled by the pitch factor), while the DURATION is preserved.
//
//   Measured dominant frequency of the OUTPUT for an asset at w = 0.100:
//       pitch=0.5 → ~0.050   (an octave DOWN)
//       pitch=1.0 → ~0.100   (unchanged)
//       pitch=2.0 → ~0.200   (an octave UP)
//
//   This works because the inner `TimeStretch` is a WSOLA stage that PRESERVES
//   frequency (it searches each grain's read position for the waveform-coherent
//   alignment, so the period is unchanged and only the duration moves), and the
//   outer resample-by-P then slides the frequency to w·P at constant duration.
//   (A naive overlap-add WITHOUT the similarity search would instead re-time the
//   period by 1/stretch — behaving as a resampler — and the outer resample would
//   cancel it to a no-op; the WSOLA search is exactly what avoids that.)
// --------------------------------------------------------------------------

test "pitch=2 raises the dominant frequency by an octave" {
    // Low fundamental (w=0.1) keeps both w and 2w well inside band, so the
    // spectral peak is unambiguous and OLA harmonic-fold cannot manufacture a
    // false octave. A correct pitch=2 must move the peak to ~0.2.
    const L = 4000;
    const w: f32 = 0.1;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, w);
    const N = 3000;

    var ps = PS{ .data = &asset };
    ps.setParam(0, 2.0);
    var out: [N]Sample(f32) = undefined;
    ps.process(&out);

    const dom = dominantFreq(&out, 500, 2500);
    const want = w * 2.0;
    if (@abs(dom - want) > 0.02) {
        std.debug.print(
            "BUG: pitch=2 output dominant freq {d:.3}, expected {d:.3} (=2w). " ++
                "Energy at w ({d:.0}) still dominates 2w ({d:.0}) — pitch not shifted up.\n",
            .{ dom, want, dftMag(&out, 500, 2500, w), dftMag(&out, 500, 2500, want) },
        );
        return error.PitchNotShiftedUp;
    }
}

test "pitch=0.5 lowers the dominant frequency by an octave" {
    // w=0.1 so the expected octave-down target w/2=0.05 is well resolved AND does
    // NOT coincide with any artifact frequency — this avoids the false pass at
    // w=0.2 where w/2=0.1 happens to land on where the (unshifted) output sits.
    const L = 4000;
    const w: f32 = 0.1;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, w);
    const N = 3000;

    var ps = PS{ .data = &asset };
    ps.setParam(0, 0.5);
    var out: [N]Sample(f32) = undefined;
    ps.process(&out);

    const dom = dominantFreq(&out, 500, 2500);
    const want = w * 0.5;
    if (@abs(dom - want) > 0.02) {
        std.debug.print(
            "BUG: pitch=0.5 output dominant freq {d:.3}, expected {d:.3} (=w/2) — pitch not shifted down.\n",
            .{ dom, want },
        );
        return error.PitchNotShiftedDown;
    }
}

test "the inner TimeStretch preserves frequency (pitch unchanged, only duration)" {
    // The WSOLA time-stretch keeps the dominant frequency at w for every stretch
    // factor — only the DURATION changes. (A naive overlap-add would instead report
    // w/stretch, behaving as a resampler; the similarity search is what preserves
    // the period.) This isolates the pitch-preservation property the pitch shift
    // composes on top of.
    const TS = pan.TimeStretch(f32num, FRAME);
    const L = 4000;
    const w: f32 = 0.1;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, w);

    inline for (.{ 0.5, 1.0, 2.0 }) |s| {
        var ts = TS{ .data = &asset };
        ts.setParam(0, s);
        var out: [6000]Sample(f32) = undefined;
        _ = ts.pull(6000, &out);
        const dom = dominantFreq(&out, 500, 4500);
        if (@abs(dom - w) > 0.02) {
            std.debug.print(
                "BUG: TimeStretch(stretch={d}) dominant freq {d:.3}, expected {d:.3} (=w, unchanged); " ++
                    "got ~w/stretch={d:.3} — it is resampling, not pitch-preserving stretching.\n",
                .{ s, dom, w, w / s },
            );
            return error.StretchChangesPitch;
        }
    }
}

// ===========================================================================
// 4. pitch=1 ≈ identity — composing stretch=1 with resample=1
// ===========================================================================

test "pitch=1 reproduces the asset shape with near-unity correlation" {
    // At P=1 the inner stretch is 1 (analysis hop == synthesis hop, the OLA is a
    // perfect reconstruction) and the resample step is 1 (pass-through). The
    // output is therefore a near-exact copy of the asset. We assert lag-0
    // normalized correlation > 0.99 over a settled window — far above what any
    // pitch-shifted (period-altered) output could reach against the ORIGINAL
    // asset, which the next assertion confirms.
    const L = 2000;
    var assetS: [L]Sample(f32) = undefined;
    var assetV: [L]f32 = undefined;
    var ph: f32 = 0;
    for (&assetS, &assetV) |*s, *v| {
        v.* = @sin(ph);
        s.ch[0] = v.*;
        ph += 0.1;
    }
    var ps = PS{ .data = &assetS };
    ps.setParam(0, 1.0);
    var out: [1500]Sample(f32) = undefined;
    ps.process(&out);

    const c = ncorrLag(&out, &assetV, 200, 1000, 0);
    if (c < 0.99) {
        std.debug.print("pitch=1 lag-0 correlation {d:.4} below 0.99 — not the identity\n", .{c});
        return error.IdentityBroken;
    }
}

test "pitch!=1 is not a clean copy of the asset (discriminates the identity test)" {
    // The discriminating counterexample to the identity test: at pitch=0.5 the
    // best lag-0..96 correlation against the asset is markedly lower than the
    // pitch=1 case, so the near-unity pitch=1 correlation is a REAL identity
    // signal, not the trivial "any sinusoid correlates with any sinusoid".
    //
    // NOTE on interpretation (see section 3's BUG): the decorrelation here is
    // driven by the off-unity OLA's phase/amplitude mangling, NOT by a genuine
    // octave-down pitch change — the down-shift does not actually occur. This
    // test therefore claims only "pitch=0.5 output is not a clean asset copy",
    // which is true and is all that is needed to make the identity test
    // non-vacuous. It deliberately does NOT assert that the pitch shifted.
    const L = 2000;
    var assetS: [L]Sample(f32) = undefined;
    var assetV: [L]f32 = undefined;
    var ph: f32 = 0;
    for (&assetS, &assetV) |*s, *v| {
        v.* = @sin(ph);
        s.ch[0] = v.*;
        ph += 0.1;
    }
    var ps1 = PS{ .data = &assetS };
    ps1.setParam(0, 1.0);
    var o1: [1500]Sample(f32) = undefined;
    ps1.process(&o1);
    const c1 = bestNcorr(&o1, &assetV, 200, 1000, 96);

    var psd = PS{ .data = &assetS };
    psd.setParam(0, 0.5);
    var od: [1500]Sample(f32) = undefined;
    psd.process(&od);
    const cd = bestNcorr(&od, &assetV, 200, 1000, 96);

    if (!(cd < c1 - 0.1)) {
        std.debug.print(
            "pitch=0.5 best-lag correlation {d:.3} not clearly below pitch=1 {d:.3} — pitch may not be shifting\n",
            .{ cd, c1 },
        );
        return error.PitchNotShifting;
    }
}

// ===========================================================================
// 5. DC / constant preservation — exact, at every pitch (both stages unity)
// ===========================================================================

test "a constant asset stays exactly that constant at every pitch" {
    // Both stages preserve DC EXACTLY: the Hann 50% OLA sums to unity, and linear
    // interpolation between two equal samples returns that value. So a constant
    // asset must come out as the SAME constant once primed — this is an exact
    // claim (tight tolerance), not a trend. A gain error in either stage, or a
    // resample-phase bug that mixed unequal neighbours, would perturb it.
    const L = 2000;
    const k: f32 = 0.37;
    var dc: [L]Sample(f32) = undefined;
    for (&dc) |*s| s.ch[0] = k;

    inline for (.{ 0.5, 1.0, 2.0 }) |p| {
        var ps = PS{ .data = &dc };
        ps.setParam(0, p);
        var out: [1500]Sample(f32) = undefined;
        ps.process(&out);
        // Skip the OLA prime-up region; the settled body must equal k tightly.
        for (out[FRAME..1200]) |s| {
            if (@abs(s.ch[0] - k) > 1e-5) {
                std.debug.print(
                    "DC not preserved at pitch={d}: got {d:.6}, expected {d:.6}\n",
                    .{ p, s.ch[0], k },
                );
                return error.DcNotPreserved;
            }
        }
    }
}

test "zero asset stays exactly zero (silence in, silence out)" {
    const L = 1000;
    var z: [L]Sample(f32) = undefined;
    for (&z) |*s| s.ch[0] = 0;
    var ps = PS{ .data = &z };
    ps.setParam(0, 1.7);
    var out: [800]Sample(f32) = undefined;
    ps.process(&out);
    for (out) |s| try std.testing.expectEqual(@as(f32, 0), s.ch[0]);
}

// ===========================================================================
// 6. Resumable state — chunked process ≡ one big process (bit-exact, pan-vs-pan)
// ===========================================================================

test "chunked process is bit-identical to one big process (cursor resumes)" {
    // The inner TimeStretch (in_pos, tail, obuf, ohead, done) and the resample
    // cursor (prev, cur, frac, primed) are pure state machines: splitting the
    // pull into arbitrary chunks must produce the SAME bytes as one call, or the
    // state did not carry across the seam. This is pan-vs-pan, so the bar is
    // BIT-EXACT — a float "close" here would be a state-resumption bug. We use
    // an irregular, prime-flavoured chunk schedule to stress odd seam offsets
    // (mid-grain, mid-resample-phase).
    const L = 2000;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, 0.1);
    const N = 1500;
    const pitch: f32 = 1.5;

    var whole = PS{ .data = &asset };
    whole.setParam(0, pitch);
    var ow: [N]Sample(f32) = undefined;
    whole.process(&ow);

    var chunk = PS{ .data = &asset };
    chunk.setParam(0, pitch);
    var oc: [N]Sample(f32) = undefined;
    const sizes = [_]usize{ 7, 1, 64, 100, 200, 3, 300, 500, 325 };
    var off: usize = 0;
    for (sizes) |sz| {
        chunk.process(oc[off .. off + sz]);
        off += sz;
    }
    try std.testing.expectEqual(N, off); // schedule must cover the whole buffer

    if (h.firstBitDivergence(h.sampleValues(&ow), h.sampleValues(&oc))) |i| {
        std.debug.print(
            "chunked != whole at sample {}: whole={d} chunked={d} — resample/stretch cursor did not resume\n",
            .{ i, ow[i].ch[0], oc[i].ch[0] },
        );
        return error.ChunkedDiverges;
    }
}

test "a different chunk schedule also matches whole (no chunk-size dependence)" {
    // Same property, a second schedule that crosses a grain boundary (HS=32) at
    // a different offset, so the equivalence is not an artifact of one schedule.
    const L = 1500;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, 0.07);
    const N = 1000;
    const pitch: f32 = 0.8;

    var whole = PS{ .data = &asset };
    whole.setParam(0, pitch);
    var ow: [N]Sample(f32) = undefined;
    whole.process(&ow);

    var chunk = PS{ .data = &asset };
    chunk.setParam(0, pitch);
    var oc: [N]Sample(f32) = undefined;
    const sizes = [_]usize{ 33, 31, 2, 128, 1, 256, 49, 500 };
    var off: usize = 0;
    for (sizes) |sz| {
        chunk.process(oc[off .. off + sz]);
        off += sz;
    }
    try std.testing.expectEqual(N, off);

    if (h.firstBitDivergence(h.sampleValues(&ow), h.sampleValues(&oc))) |i| {
        std.debug.print("chunked != whole (schedule 2) at sample {}\n", .{i});
        return error.ChunkedDiverges;
    }
}

// ===========================================================================
// 7. Pitch held per call — clamping and per-call latching
// ===========================================================================

test "pitch is clamped into [0.5, 2.0]" {
    // setParam stores the raw value; process clamps the READ to [0.5, 2.0] each
    // call. So an out-of-range pitch behaves like the nearest endpoint. We pin
    // this by comparing an over-the-top setting (4.0) to the clamped endpoint
    // (2.0): bit-identical output proves the clamp, not a softer "looks similar".
    const L = 2000;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, 0.12);
    const N = 1200;

    var clamped = PS{ .data = &asset };
    clamped.setParam(0, 2.0);
    var oc: [N]Sample(f32) = undefined;
    clamped.process(&oc);

    var over = PS{ .data = &asset };
    over.setParam(0, 4.0); // must clamp to 2.0
    var oo: [N]Sample(f32) = undefined;
    over.process(&oo);

    if (h.firstBitDivergence(h.sampleValues(&oc), h.sampleValues(&oo))) |i| {
        std.debug.print("pitch=4.0 not clamped to 2.0: diverges at sample {}\n", .{i});
        return error.ClampBroken;
    }

    // And the low end: 0.1 must clamp to 0.5.
    var lowClamp = PS{ .data = &asset };
    lowClamp.setParam(0, 0.5);
    var olc: [N]Sample(f32) = undefined;
    lowClamp.process(&olc);

    var under = PS{ .data = &asset };
    under.setParam(0, 0.1); // must clamp to 0.5
    var ou: [N]Sample(f32) = undefined;
    under.process(&ou);

    if (h.firstBitDivergence(h.sampleValues(&olc), h.sampleValues(&ou))) |i| {
        std.debug.print("pitch=0.1 not clamped to 0.5: diverges at sample {}\n", .{i});
        return error.ClampBroken;
    }
}

test "pitch is read per call — a mid-stream setParam changes subsequent output" {
    // The pitch is latched at the top of each `process` (`pitch.read()` clamped).
    // So a setParam between two process calls must take effect on the SECOND
    // call's samples. We run reference-A (pitch=1 throughout) and a switched run
    // (pitch=1 for the first half, then setParam(2.0) before the second half):
    // the first halves must be bit-identical (same param, resumed state), and the
    // second halves must DIFFER (the new pitch took hold). This pins "held per
    // call" from both sides — sticky within a call, re-read across calls.
    const L = 3000;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, 0.15);
    const half = 1000;

    var ref = PS{ .data = &asset };
    ref.setParam(0, 1.0);
    var ra: [half]Sample(f32) = undefined;
    var rb: [half]Sample(f32) = undefined;
    ref.process(&ra);
    ref.process(&rb);

    var sw = PS{ .data = &asset };
    sw.setParam(0, 1.0);
    var sa: [half]Sample(f32) = undefined;
    var sb: [half]Sample(f32) = undefined;
    sw.process(&sa);
    sw.setParam(0, 2.0); // change pitch between calls
    sw.process(&sb);

    // First halves: same param, same resumed state ⇒ bit-identical.
    if (h.firstBitDivergence(h.sampleValues(&ra), h.sampleValues(&sa))) |i| {
        std.debug.print("first halves differ at {} despite identical pitch up to that call\n", .{i});
        return error.FirstHalfShouldMatch;
    }
    // Second halves: the param changed ⇒ they must differ somewhere.
    if (h.firstBitDivergence(h.sampleValues(&rb), h.sampleValues(&sb)) == null) {
        std.debug.print("second half unchanged after setParam(2.0) — pitch is not re-read per call\n", .{});
        return error.PitchNotReReadPerCall;
    }
}

// ===========================================================================
// 8. Edges — empty asset, tiny asset, single-sample pull
// ===========================================================================

test "empty asset yields pure silence at any pitch (no out-of-bounds)" {
    inline for (.{ 0.5, 1.0, 2.0 }) |p| {
        var ps = PS{ .data = &.{} };
        ps.setParam(0, p);
        var out: [256]Sample(f32) = undefined;
        ps.process(&out);
        for (out) |s| try std.testing.expectEqual(@as(f32, 0), s.ch[0]);
    }
}

test "a tiny asset (shorter than FRAME) runs and decays to silence" {
    // The inner TimeStretch reads windowed grains via clamped/zero-padded asset
    // access (`assetAt` returns 0 past the end), so a 3-sample asset must not
    // crash, must produce SOME signal early, and must settle to silence once
    // consumed — it cannot ring forever. This stresses the boundary arithmetic
    // (base/frac near the asset end) at all three pitches.
    inline for (.{ 0.5, 1.0, 2.0 }) |p| {
        var tiny = [_]Sample(f32){
            .{ .ch = .{1} }, .{ .ch = .{1} }, .{ .ch = .{1} },
        };
        var ps = PS{ .data = &tiny };
        ps.setParam(0, p);
        var out: [512]Sample(f32) = undefined;
        ps.process(&out);
        // The tail must be silent — a tiny finite asset has finite output.
        for (out[256..]) |s| {
            if (@abs(s.ch[0]) > 1e-5) {
                std.debug.print("tiny asset did not decay at pitch={d}: tail sample {d}\n", .{ p, s.ch[0] });
                return error.TinyAssetRings;
            }
        }
    }
}

test "single-sample pulls accumulate to the same stream as a batch pull" {
    // The extreme chunk schedule: pull one sample at a time. Must be bit-identical
    // to a single batched pull — the most aggressive resumability stress (every
    // call re-enters at a fresh resample phase / grain offset). pan-vs-pan ⇒ exact.
    const L = 1000;
    var asset: [L]Sample(f32) = undefined;
    sineAsset(L, &asset, 0.2);
    const N = 600;
    const pitch: f32 = 1.3;

    var batch = PS{ .data = &asset };
    batch.setParam(0, pitch);
    var ob: [N]Sample(f32) = undefined;
    batch.process(&ob);

    var one = PS{ .data = &asset };
    one.setParam(0, pitch);
    var oo: [N]Sample(f32) = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) one.process(oo[i .. i + 1]);

    if (h.firstBitDivergence(h.sampleValues(&ob), h.sampleValues(&oo))) |idx| {
        std.debug.print("single-sample pulls diverge from batch at {}\n", .{idx});
        return error.SingleSampleDiverges;
    }
}

// ===========================================================================
// 9. Determinism + heap hygiene (the suite owns its one heap buffer)
// ===========================================================================

test "process is deterministic — same asset+pitch yields identical bytes" {
    // No hidden RNG / clock: two fresh instances on the same input must be
    // byte-identical. Uses std.testing.allocator so a leak fails the test.
    const a = std.testing.allocator;
    const L = 1500;
    const asset = try a.alloc(Sample(f32), L);
    defer a.free(asset);
    h.fillNoise(asset, 0xC0FFEE);

    const N = 1000;
    const o1 = try a.alloc(Sample(f32), N);
    defer a.free(o1);
    const o2 = try a.alloc(Sample(f32), N);
    defer a.free(o2);

    var p1 = PS{ .data = asset };
    p1.setParam(0, 1.4);
    p1.process(o1);

    var p2 = PS{ .data = asset };
    p2.setParam(0, 1.4);
    p2.process(o2);

    try std.testing.expect(h.firstBitDivergence(h.sampleValues(o1), h.sampleValues(o2)) == null);
}
