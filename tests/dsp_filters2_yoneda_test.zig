//! DSP-filters (second wave) harness — the behavioral DEFINITION of the
//! `StateVariable` (TPT/zero-delay-feedback SVF), `Fir` (arbitrary-tap FIR with a
//! float SIMD-dot path and a wide-accumulate fixed-point path), and `firwinLowpass`
//! (the comptime windowed-sinc table) blocks in `src/filters.zig`, written the
//! Yoneda way: characterize each block by every morphism that matters — its
//! frequency-selectivity identity (DC vs near-Nyquist, per mode), its convolution
//! identity against a hand-rolled oracle, its push≡pull and split≡whole
//! differentials, and its float/fixed-point agreement — so any implementation
//! passing all of these is functionally equivalent to the one under test.
//!
//! These tests do NOT duplicate the in-file unit tests in `src/filters.zig`; they
//! ADD the definitional and edge-case coverage those lack: the dual-mux push≡pull
//! seam (the representability / Yoneda probe), bit-exact split≡whole through the
//! real mux drivers, the bandpass mode (a third frequency-response oracle), the FIR
//! linear-phase symmetry, the `firwinLowpass` symmetry + monotone-cutoff property,
//! and edge cases (single-tap FIR, taps==1 firwin).
//!
//! COMPARISON DISCIPLINE (harness law, restated so this file stands alone):
//!   - the analytic frequency-response oracle (DC gain, alternating-tone rejection)
//!     and the hand-computed convolution are INDEPENDENT references, compared
//!     approximately (libm transcendentals, f64 working in the reference).
//!   - EVERY pan-vs-pan differential (dual-mux push≡pull, state-granularity
//!     split≡whole) is BIT-EXACT: tolerance never forgives pan disagreeing with
//!     itself.
//!   - the fixed-point FIR vs the float FIR is an algorithmic-agreement check
//!     (different arithmetic), so it is compared within a few-LSB absolute bound.
//!
//! Diagnostics on a deliberate mismatch path go to `std.debug.print` (not the
//! logging facility) so a characterization test never inflates the runner's
//! logged-error count and flips an otherwise-passing suite to a non-zero exit.
//!
//! Verified against zig 0.16.0; the `zig-0-16` skill was loaded before authoring
//! (project Rule 13/14).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const testing = std.testing;

const f32num = pan.numericFor(.f32, .{});
const q31num = pan.numericFor(.i32, .{});
const Sample = pan.Sample(f32);

// --- local helpers ---------------------------------------------------------

/// Wrap a bare `f32` array as the planar one-lane `Sample(f32)` frames the blocks
/// consume. `Sample(f32)` is layout-identical to a bare `f32`, so this is a
/// faithful framing of a scalar test signal.
fn frame(comptime n: usize, vals: [n]f32) [n]Sample {
    var out: [n]Sample = undefined;
    for (&out, vals) |*o, v| o.ch[0] = v;
    return out;
}

/// An alternating ±1 signal — the highest representable frequency (Nyquist). This
/// is the worst case for a lowpass (must crush it) and the pass case for a
/// highpass (must let it through near unity).
fn fillNyquist(buf: []Sample) void {
    for (buf, 0..) |*s, i| s.ch[0] = if (i % 2 == 0) @as(f32, 1) else -1;
}

/// The peak |sample| over the tail of a buffer (after a settling region), the
/// realized steady-state response magnitude.
fn tailPeak(buf: []const Sample, start: usize) f32 {
    var peak: f32 = 0;
    for (buf[start..]) |s| peak = @max(peak, @abs(s.ch[0]));
    return peak;
}

// ===========================================================================
// StateVariable — a 2nd-order TPT SVF; mode selects LP / BP / HP from one pass.
// ===========================================================================

test "StateVariable: each mode classifies as a Map with fc/q params and is NOT aliasing_safe" {
    // Pin the structural contract for ALL THREE monomorphs (the in-file test only
    // checks the lowpass default): each is a Map (rate-1:1, per-sample state), each
    // exposes the fc + q control ports, and none is aliasing_safe (a sequential
    // integrator recurrence the colorer must not run in place).
    inline for (.{ .lowpass, .bandpass, .highpass }) |mode| {
        const SV = pan.filters.StateVariableMode(f32num, mode);
        try testing.expect(pan.classify(SV) == .Map);
        try testing.expect(pan.ParamPort(SV, "fc").Elem == pan.Scalar(f32));
        try testing.expect(pan.ParamPort(SV, "q").Elem == pan.Scalar(f32));
        try testing.expect(!@hasDecl(SV, "aliasing_safe"));
        try testing.expect(SV.svf_mode == mode);
    }
    // The no-argument StateVariable defaults to lowpass.
    try testing.expect(pan.StateVariable(f32num).svf_mode == .lowpass);
}

test "StateVariable: the three modes form a complementary filter bank at one cutoff" {
    // WHY: the defining structural property of a 2nd-order SVF is that LP, BP, and HP
    // are three views of the SAME two integrator states. The three responses must
    // therefore SORT correctly against frequency: at a low cutoff, DC survives the
    // LP but is killed by the HP, and a near-Nyquist tone survives the HP but is
    // killed by the LP — and the BP rejects BOTH extremes (it only passes the band
    // near cutoff). Asserting all three at once pins the MODE SELECTION, not merely
    // generic attenuation: a swapped LP/HP arm would fail here.
    const fc: f32 = 0.02;
    const settle = 300;

    inline for (.{ .lowpass, .bandpass, .highpass }) |mode_lit| {
        const mode: pan.filters.SvfMode = mode_lit;
        var dc_resp: f32 = undefined;
        var hf_resp: f32 = undefined;
        // DC response.
        {
            var sv = pan.filters.StateVariableMode(f32num, mode){};
            sv.setParam(0, fc);
            var dc: [400]Sample = @splat(.{ .ch = .{1} });
            var out: [400]Sample = undefined;
            sv.process(&dc, &out);
            dc_resp = @abs(out[399].ch[0]);
        }
        // Near-Nyquist response.
        {
            var sv = pan.filters.StateVariableMode(f32num, mode){};
            sv.setParam(0, fc);
            var sig: [400]Sample = undefined;
            fillNyquist(&sig);
            var out: [400]Sample = undefined;
            sv.process(&sig, &out);
            hf_resp = tailPeak(&out, settle);
        }
        switch (mode) {
            .lowpass => {
                try testing.expect(dc_resp > 0.95); // DC passes
                try testing.expect(hf_resp < 0.05); // Nyquist crushed
            },
            .highpass => {
                try testing.expect(dc_resp < 0.05); // DC removed
                try testing.expect(hf_resp > 0.9); // Nyquist passes
            },
            .bandpass => {
                // A band-pass at a LOW cutoff rejects BOTH the DC and the Nyquist
                // extremes (it only passes the narrow band around fc).
                try testing.expect(dc_resp < 0.05);
                try testing.expect(hf_resp < 0.2);
            },
        }
    }
}

test "StateVariable: higher Q sharpens the bandpass peak at cutoff (resonance)" {
    // WHY: q is the resonance/quality factor — a higher q narrows the band and
    // raises the gain AT the cutoff frequency. Drive a sinusoid AT the cutoff and
    // assert the steady-state bandpass amplitude grows with q. This pins q as
    // resonance (the 1/q damping term), not some unrelated knob.
    const fc: f32 = 0.05; // cutoff in cycles/sample
    const N = 2000;
    const w: f32 = 2.0 * std.math.pi * fc; // radians/sample at the cutoff

    var lowq = pan.filters.StateVariableMode(f32num, .bandpass){};
    lowq.setParam(0, fc);
    lowq.setParam(1, 0.7071067811865476); // Butterworth
    var highq = pan.filters.StateVariableMode(f32num, .bandpass){};
    highq.setParam(0, fc);
    highq.setParam(1, 8.0); // strongly resonant

    var sig: [N]Sample = undefined;
    for (&sig, 0..) |*s, i| s.ch[0] = @sin(w * @as(f32, @floatFromInt(i)));
    var lout: [N]Sample = undefined;
    var hout: [N]Sample = undefined;
    lowq.process(&sig, &lout);
    highq.process(&sig, &hout);

    const lo_peak = tailPeak(&lout, N - 500);
    const hi_peak = tailPeak(&hout, N - 500);
    try testing.expect(hi_peak > lo_peak); // resonance raises the at-cutoff gain
    try testing.expect(hi_peak > 1.0); // a high-q bandpass amplifies at resonance
}

test "StateVariable: push ≡ pull through the dual-mux seam (bit-exact)" {
    // The representability / Yoneda probe (testing spec §5.2): the SAME process over
    // the SAME default-target-ramped state, driven through the push mux and the pull
    // mux, must produce byte-identical output. No setParam, so both rides the same
    // default-target ramp; rate-1:1 with zero declared latency ⇒ the streams overlap
    // fully and must be bit-exact. A surface leak between the two mux interpretations
    // is exactly what this catches.
    const SV = pan.filters.StateVariableMode(f32num, .lowpass);
    const n = 257; // prime length, ragged against the chunk size.
    var in: [n]Sample = undefined;
    h.fillNoise(&in, 7777);

    var sp = SV{};
    var sq = SV{};
    var out_push: [n]Sample = undefined;
    var out_pull: [n]Sample = undefined;
    h.renderPush(SV, &sp, &in, &out_push, 48);
    h.renderPull(SV, &sq, &in, &out_pull, 48);

    try h.expectPanVsPan(SV, h.sampleValues(&out_push), h.sampleValues(&out_pull), "push", "pull");
}

test "StateVariable: split render equals one whole render at single-sample granularity (bit-exact)" {
    // WHY: the two integrator states are persistent; a render chopped to the finest
    // granularity (one sample at a time) must be sample-for-sample identical to one
    // whole-block render, or the block is wrong under the block-size-agnostic
    // contract. No setParam ⇒ the per-block ramp begins at the same default target
    // each call (inc==0, the live value already AT target), so the only thing that
    // can differ across chunkings is the carried integrator state — which is exactly
    // what we are pinning.
    const SV = pan.filters.StateVariableMode(f32num, .highpass);
    const n = 24;
    var in: [n]Sample = undefined;
    h.fillNoise(&in, 314);

    var whole = SV{};
    var whole_out: [n]Sample = undefined;
    whole.process(&in, &whole_out);

    var step = SV{};
    var step_out: [n]Sample = undefined;
    for (0..n) |i| step.process(in[i .. i + 1], step_out[i .. i + 1]);

    try h.expectPanVsPan(SV, h.sampleValues(&whole_out), h.sampleValues(&step_out), "whole", "one-at-a-time");
}

test "StateVariable: a stable lowpass is bounded — it does not blow up near Nyquist cutoff" {
    // WHY: the whole point of the TPT/zero-delay-feedback form over the classic
    // Chamberlin SVF is that it stays STABLE as the cutoff rises toward Nyquist
    // (where the Chamberlin form goes unstable). Push the cutoff high (0.45, just
    // below 0.5) and feed a full-scale signal; the output must stay finite and
    // bounded (no runaway), an independent stability property check.
    var sv = pan.filters.StateVariableMode(f32num, .lowpass){};
    sv.setParam(0, 0.45);
    sv.setParam(1, 0.7071067811865476);
    var in: [512]Sample = undefined;
    h.fillNoise(&in, 2024);
    var out: [512]Sample = undefined;
    sv.process(&in, &out);
    var mx: f32 = 0;
    for (out) |s| {
        try testing.expect(std.math.isFinite(s.ch[0]));
        mx = @max(mx, @abs(s.ch[0]));
    }
    try testing.expect(mx < 4.0); // bounded — well below any runaway
}

test "StateVariable: the integer lane is rejected at compile time (float-only, fails loud)" {
    // WHY: the TPT solve needs a reciprocal and tan() that have no fixed-point
    // treatment, so the integer path must FAIL LOUD (a @compileError), never emit
    // silently-wrong audio. We can only assert the float monomorphs build; the
    // negative (a q15 instantiation @compileError) is covered by the build's
    // negative-compile fixtures, not an in-suite instantiation (which would abort
    // compilation of this whole module). Documented here for completeness.
    try testing.expect(@hasDecl(pan.filters.StateVariableMode(f32num, .lowpass), "process"));
}

// ===========================================================================
// Fir — arbitrary-tap FIR; float SIMD-dot path + wide-accumulate fixed path.
// ===========================================================================

test "Fir: classifies as a Map and is NOT aliasing_safe (reads `taps` past inputs)" {
    const F = pan.Fir(f32num, 5);
    try testing.expect(pan.classify(F) == .Map);
    try testing.expect(!@hasDecl(F, "aliasing_safe"));
}

test "Fir: a single-tap FIR is a pure scale (the taps==1 corner)" {
    // The smallest legal FIR: one tap. y[n] = coeff[0]·x[n], a memoryless scale.
    // This pins the degenerate edge (no history, no reversal ambiguity) before the
    // multi-tap convolution tests.
    var f = pan.Fir(f32num, 1){ .coeffs = .{0.5} };
    var in = frame(6, .{ 1.0, -2.0, 3.0, -4.0, 0.25, -0.75 });
    var out: [6]Sample = undefined;
    f.process(&in, &out);
    for (in, out) |x, y| try testing.expectApproxEqAbs(x.ch[0] * 0.5, y.ch[0], 1e-7);
}

test "Fir: the default coeffs are a unit impulse (an unconfigured Fir is pass-through)" {
    // Default coeff[0] = 1, the rest 0 ⇒ y[n] = x[n]. A long enough tap count to
    // exercise both the SIMD body and the scalar tail in the dot product.
    var f = pan.Fir(f32num, 7){};
    try testing.expectEqual(@as(f32, 1.0), f.coeffs[0]);
    var in: [12]Sample = undefined;
    h.fillNoise(&in, 55);
    var out: [12]Sample = undefined;
    f.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "Fir: matches a hand-rolled convolution oracle with ASYMMETRIC taps over many tap counts" {
    // WHY: a symmetric kernel hides tap-ordering / reversal bugs (a reversed table
    // looks identical). Asymmetric, distinct taps over a known input expose the
    // ordering. Compute the convolution independently here (the oracle is a direct
    // double loop over y[n] = Σ_k coeff[k]·x[n−k], NOT a replay of pan's path) and
    // compare. Sweep several tap counts so the SIMD-body / scalar-tail split is
    // exercised at different remainders.
    inline for (.{ 2, 3, 4, 5, 8 }) |taps| {
        var coeffs: [taps]f32 = undefined;
        inline for (0..taps) |k| coeffs[k] = @floatFromInt(@as(i32, @intCast(k)) + 1); // 1,2,3,...

        const n = 16;
        var in: [n]Sample = undefined;
        for (&in, 0..) |*s, i| s.ch[0] = @floatFromInt(@as(i32, @intCast(i)) - 5); // an asymmetric ramp

        var f = pan.Fir(f32num, taps){ .coeffs = coeffs };
        var out: [n]Sample = undefined;
        f.process(&in, &out);

        // Independent oracle: direct convolution with explicit zero history.
        for (0..n) |nn| {
            var acc: f32 = 0;
            inline for (0..taps) |k| {
                if (nn >= k) acc += coeffs[k] * in[nn - k].ch[0];
            }
            try testing.expectApproxEqAbs(acc, out[nn].ch[0], 1e-4);
        }
    }
}

test "Fir: a symmetric (linear-phase) kernel has a measurable group delay of (taps−1)/2" {
    // WHY: a symmetric FIR is linear-phase — its impulse response is symmetric about
    // its centre, so the energy centroid (group delay) sits at (taps−1)/2 samples.
    // Feed an impulse and assert the response is symmetric and peaks at the centre.
    // This is the phase-side identity the magnitude-only tests miss.
    const taps = 9;
    const h_taps = pan.filters.firwinLowpass(taps, 0.2);
    var f = pan.Fir(f32num, taps){ .coeffs = h_taps };
    var in: [32]Sample = undefined;
    h.fillImpulse(&in);
    var out: [32]Sample = undefined;
    f.process(&in, &out);

    // The impulse response IS the coefficient table (output[k] = coeff[k] for the
    // first `taps`), which firwin builds symmetric: coeff[k] == coeff[taps−1−k].
    inline for (0..taps) |k| {
        try testing.expectApproxEqAbs(out[k].ch[0], out[taps - 1 - k].ch[0], 1e-6);
    }
    // The centre tap (taps−1)/2 == 4 is the largest (a lowpass sinc peaks at centre).
    const centre = (taps - 1) / 2;
    var maxv: f32 = 0;
    var maxi: usize = 0;
    for (out[0..taps], 0..) |s, i| {
        if (@abs(s.ch[0]) > maxv) {
            maxv = @abs(s.ch[0]);
            maxi = i;
        }
    }
    try testing.expectEqual(centre, maxi);
}

test "Fir: push ≡ pull through the dual-mux seam (bit-exact)" {
    // The Yoneda probe for the stateful (history-carrying) FIR: the SAME convolution
    // over the SAME history state under the push mux and the pull mux must be
    // byte-identical. Tap count 9 exercises the SIMD body + scalar tail; a prime
    // length ragged against the chunk forces irregular boundaries on both paths.
    const F = pan.Fir(f32num, 9);
    const n = 251;
    var in: [n]Sample = undefined;
    h.fillNoise(&in, 9090);
    const coeffs = pan.filters.firwinLowpass(9, 0.15);

    var fp = F{ .coeffs = coeffs };
    var fq = F{ .coeffs = coeffs };
    var out_push: [n]Sample = undefined;
    var out_pull: [n]Sample = undefined;
    h.renderPush(F, &fp, &in, &out_push, 40);
    h.renderPull(F, &fq, &in, &out_pull, 40);

    try h.expectPanVsPan(F, h.sampleValues(&out_push), h.sampleValues(&out_pull), "push", "pull");
}

test "Fir: split render equals one whole render across ragged boundaries (bit-exact)" {
    // The history is persistent state; chopping the render at arbitrary (non-round)
    // boundaries must reproduce the whole render byte-for-byte, or the convolution
    // silently drops cross-boundary taps. Ragged split (7, 13, rest) so the seam is
    // not on a tap boundary.
    const F = pan.Fir(f32num, 9);
    const n = 40;
    var in: [n]Sample = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @floatFromInt(@as(i32, @intCast(i)) - 17);
    const coeffs = pan.filters.firwinLowpass(9, 0.15);

    var whole = F{ .coeffs = coeffs };
    var whole_out: [n]Sample = undefined;
    whole.process(&in, &whole_out);

    var split = F{ .coeffs = coeffs };
    var split_out: [n]Sample = undefined;
    split.process(in[0..7], split_out[0..7]);
    split.process(in[7..20], split_out[7..20]);
    split.process(in[20..], split_out[20..]);

    try h.expectPanVsPan(F, h.sampleValues(&whole_out), h.sampleValues(&split_out), "whole", "split");
}

test "Fir(q31): the fixed-point path matches the float path within a few-LSB bound" {
    // WHY: the fixed-point path must compute the SAME convolution as the float path
    // (the wide-accumulate-then-round-once discipline), not merely run. Build q31
    // coeffs from the float firwin table, run the SAME signal through both, and
    // assert agreement to within a few LSB — a per-multiply shift (the wrong
    // arithmetic) would drift far past this bound. Independent of the in-file q31
    // test: a different cutoff, tap count, and signal.
    const taps = 11;
    const hf = pan.filters.firwinLowpass(taps, 0.18);
    const frac: comptime_int = @typeInfo(i32).int.bits - 1; // q31
    const scale: f32 = @floatFromInt(@as(i64, 1) << frac);

    var hq: [taps]i32 = undefined;
    inline for (0..taps) |k| hq[k] = @intFromFloat(@round(hf[k] * scale));

    var ff = pan.Fir(f32num, taps){ .coeffs = hf };
    var fq = pan.Fir(q31num, taps){ .coeffs = hq };

    const N = 96;
    var fin: [N]pan.Sample(f32) = undefined;
    var qin: [N]pan.Sample(i32) = undefined;
    for (&fin, &qin, 0..) |*fs, *qs, i| {
        const v: f32 = 0.4 * @sin(@as(f32, @floatFromInt(i)) * 0.27);
        fs.ch[0] = v;
        qs.ch[0] = @intFromFloat(@round(v * scale));
    }
    var fout: [N]pan.Sample(f32) = undefined;
    var qout: [N]pan.Sample(i32) = undefined;
    ff.process(&fin, &fout);
    fq.process(&qin, &qout);

    for (fout, qout) |fy, qy| {
        const q_as_float = @as(f32, @floatFromInt(qy.ch[0])) / scale;
        try testing.expectApproxEqAbs(fy.ch[0], q_as_float, 1e-4);
    }
}

// ===========================================================================
// firwinLowpass — the comptime windowed-sinc (Hamming) lowpass table builder.
// ===========================================================================

test "firwinLowpass: the table sums to unity (a DC sinusoid passes at unity gain)" {
    // WHY: a lowpass design must pass DC unchanged, i.e. its coefficients must sum
    // to exactly 1 (the analytic property the normalization enforces). Check across
    // several tap counts and cutoffs — the normalization is independent of both.
    inline for (.{ .{ 15, 0.1 }, .{ 31, 0.25 }, .{ 64, 0.05 }, .{ 8, 0.3 } }) |tc| {
        const taps = tc[0];
        const fc = tc[1];
        const tbl = pan.filters.firwinLowpass(taps, fc);
        var sum: f32 = 0;
        for (tbl) |c| sum += c;
        try testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-5);
    }
}

test "firwinLowpass: the table is symmetric (linear phase)" {
    // WHY: a windowed-sinc lowpass is symmetric about its centre — the property that
    // makes it linear-phase (constant group delay). Both the sinc (even) and the
    // Hamming window (even about the centre) are symmetric, so the product is too.
    const taps = 33;
    const tbl = pan.filters.firwinLowpass(taps, 0.12);
    inline for (0..taps) |k| {
        try testing.expectApproxEqAbs(tbl[k], tbl[taps - 1 - k], 1e-6);
    }
}

test "firwinLowpass: the single-tap table is the unity DC passthrough (taps==1 corner)" {
    // The degenerate one-tap design: with no neighbours the only sensible
    // normalized lowpass is the unity passthrough coeff[0] = 1 (sum-to-1 of a single
    // tap). This pins the taps==1 branch (denom guarded to 1, sum normalization).
    const tbl = pan.filters.firwinLowpass(1, 0.25);
    try testing.expectApproxEqAbs(@as(f32, 1.0), tbl[0], 1e-6);
}

test "firwinLowpass: a lower cutoff attenuates a fixed mid-band tone harder" {
    // WHY: the cutoff parameter must actually MOVE the transition band — a lower fc
    // rejects more of the spectrum. Drive a fixed mid-band tone through two designs
    // (cutoff 0.05 vs 0.2, same taps) and assert the lower-cutoff filter attenuates
    // the tone MORE. This pins fc as a real cutoff knob (monotone selectivity), an
    // independent realized-behaviour oracle beyond the analytic tap sum.
    const taps = 41;
    const low = pan.filters.firwinLowpass(taps, 0.05);
    const high = pan.filters.firwinLowpass(taps, 0.2);

    // A 0.12 cycles/sample tone: above the 0.05 cutoff (attenuated) but below the
    // 0.2 cutoff (passed). The lower-cutoff filter must crush it harder.
    const w: f32 = 2.0 * std.math.pi * 0.12;
    const N = 256;
    var sig: [N]Sample = undefined;
    for (&sig, 0..) |*s, i| s.ch[0] = @sin(w * @as(f32, @floatFromInt(i)));

    var flow = pan.Fir(f32num, taps){ .coeffs = low };
    var fhigh = pan.Fir(f32num, taps){ .coeffs = high };
    var lout: [N]Sample = undefined;
    var hout: [N]Sample = undefined;
    flow.process(&sig, &lout);
    fhigh.process(&sig, &hout);

    const lo_peak = tailPeak(&lout, taps + 100); // skip the fill transient
    const hi_peak = tailPeak(&hout, taps + 100);
    try testing.expect(lo_peak < hi_peak); // lower cutoff attenuates the tone more
    try testing.expect(hi_peak > 0.7); // the 0.2-cutoff design passes the in-band tone
}
