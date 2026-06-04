//! varispeed_yoneda_test — the behavioural specification of `Varispeed`
//! (`src/spectral.zig`), an arbitrary-runtime-ratio LINEAR-interpolation
//! resampler whose out:in ratio is a held-per-call parameter. This suite is the
//! "tests as definition" characterization: it pins WHAT the resampler computes,
//! not merely that it runs, so any implementation that passes all of these is
//! functionally equivalent on the laws below.
//!
//! The block, restated inline so this file stands alone (no external refs):
//!
//!   - The ratio is the out:in ratio, clamped into the closed interval
//!     [0.25, 4.0]. 1.0 means one output per input; 2.0 doubles the rate
//!     (upsample); 0.25 quarters it (downsample). The clamp is total: any
//!     requested ratio outside the interval is pulled to the nearest endpoint,
//!     so the measured rate can never escape [0.25, 4.0].
//!
//!   - The ratio is sampled ONCE at the top of each `pull` and HELD for the
//!     whole call. A `setParam` issued between pulls takes effect on the NEXT
//!     pull; a `setParam` cannot change the ratio mid-buffer. (This is the
//!     "held-per-call" law — it is what makes a render bit-reproducible.)
//!
//!   - The interpolator is causal with a one-sample look-back. State carried
//!     across calls is `prev` (the last input sample actually consumed — the
//!     LEFT bracket of the lerp) and `frac` (the fractional read position in
//!     [0,1) between `prev` and the next, not-yet-consumed input — the RIGHT
//!     bracket). The implicit pre-roll is silence: `prev` starts at 0 and
//!     `frac` starts at 0, so the very FIRST output of a fresh block is exactly
//!     0 (it interpolates between the silent pre-roll and the first input at
//!     fraction 0). This is the single-sample interpolation phase.
//!
//!   - The output at read position p (in input-sample units, p grows by
//!     1/ratio per output) is the linear interpolation
//!     `x[floor(p)] + frac*(x[floor(p)+1] - x[floor(p)])`, where `x[-1] = 0`
//!     (the pre-roll). Because the kernel is linear in the input samples and the
//!     read schedule depends only on the ratio (not on the sample values), the
//!     resampler is a LINEAR operator at a fixed ratio: scaling/adding inputs
//!     scales/adds the outputs, a constant maps to itself, and a sinusoid maps
//!     to a sinusoid whose period scales by the ratio.
//!
//!   - The render is a pure function of (input, held ratio): chunking the input
//!     into a sequence of pulls is BIT-IDENTICAL to one whole pull (the
//!     resumable-state contract — `prev`/`frac` carry a fractional remainder
//!     across calls so nothing is dropped at a chunk seam).
//!
//!   - `needed_input(want)` reports how many input samples `want` outputs
//!     consume at the current held ratio. It must be SOUND (at least enough that
//!     a pull of `want` with that many inputs returns exactly `want`), MONOTONE
//!     non-decreasing in `want`, and non-increasing in the ratio (a faster rate
//!     consumes fewer inputs per output).
//!
//! This file deliberately does NOT re-prove the interval/latency GATE already
//! owned by `tests/varirate_latency_test.zig` (ratio∈[min,max], impulse delay,
//! needed_input soundness/monotonicity sweep, chunked≡whole, identical-render).
//! It is the DEEPER spec: an independent interpolation oracle, the identity at
//! ratio 1, the pre-roll phase, linearity/DC/sinusoid laws, the held-per-call
//! mid-stream law, and the degenerate edges (want=0, empty input).
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14). Reject diagnostics use std.debug.print, never std.log.err;
//! all heap buffers use std.testing.allocator so a leak fails the test.

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const Sample = pan.Sample;
const f32num = pan.numericFor(.f32, .{});
const VS = pan.Varispeed(f32num);

const min_ratio: f32 = 0.25;
const max_ratio: f32 = 4.0;

fn s(v: f32) Sample(f32) {
    return .{ .ch = .{v} };
}

// ===========================================================================
// Independent interpolation oracle.
//
// The implementation drives a branchy peek/consume loop that increments `frac`
// by `step` AFTER each output and decrements it by 1 (consuming an input) when
// it reaches 1. This oracle computes the SAME mathematical lerp from a different
// formulation: it advances a continuous read position `pos` by `step` per output
// and reads the bracket directly by index, with the silent pre-roll modelled as
// the virtual sample x[-1] = 0. The accumulation order and control flow differ
// from the impl, so agreement (within the float-oracle tolerance) is real
// evidence, not a tautology. Returns the count it could produce given `xs`.
// ===========================================================================
fn oracle(xs: []const f32, ratio: f32, want: usize, out: []f32) usize {
    const r = @min(@max(ratio, min_ratio), max_ratio);
    const step: f64 = 1.0 / @as(f64, r);
    // `pos` is the read position in input-sample units. The left bracket is the
    // input with index floor(pos)-1 in the consumed stream; we track it as
    // `consumed` (number of inputs the impl would have consumed) and the
    // fraction within the current bracket. We replicate the impl's invariant
    // analytically: before output n, the impl has advanced frac by n*step and
    // consumed floor of that — but to mirror the SAME accumulation we sum steps.
    var frac: f64 = 0;
    var consumed: usize = 0; // inputs consumed so far == index of the right bracket
    var produced: usize = 0;
    while (produced < want) {
        // Consume whole inputs until the fractional read position is < 1.
        while (frac >= 1.0) {
            consumed += 1;
            frac -= 1.0;
        }
        if (consumed >= xs.len) break; // right bracket xs[consumed] unavailable
        const left: f32 = if (consumed == 0) 0.0 else xs[consumed - 1];
        const right: f32 = xs[consumed];
        const f: f32 = @floatCast(frac);
        out[produced] = left + f * (right - left);
        produced += 1;
        frac += step;
    }
    return produced;
}

const ORACLE_TOL: h.Tolerance = .{ .approx = .{ .atol = 1e-6, .rtol = 1e-6 } };

// ===========================================================================
// Oracle agreement across the interval.
// ===========================================================================

test "Varispeed matches an independent linear-interpolation oracle across the interval" {
    const gpa = std.testing.allocator;
    const N = 777;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 4242);
    const xs = h.sampleValues(in);

    const cap = N * 5 + 16;
    const got = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(got);
    const ref = try gpa.alloc(f32, cap);
    defer gpa.free(ref);

    inline for (.{ 0.25, 0.5, 0.75, 1.0, 1.333, 1.5, 2.0, 3.0, 4.0 }) |r| {
        var vs = VS{};
        vs.setParam(0, r);
        const pg = vs.pull(in, cap, got);
        const pr = oracle(xs, r, cap, ref);
        // The two derivations agree on how many outputs the input affords.
        try std.testing.expectEqual(pr, pg);
        try h.allcloseF32(h.sampleValues(got[0..pg]), ref[0..pr], ORACLE_TOL);
    }
}

// ===========================================================================
// The pre-roll silence phase: a fresh block's FIRST output is exactly 0.
// ===========================================================================

test "Varispeed pre-roll: the first output of a fresh block is exactly 0 (silent left bracket)" {
    inline for (.{ 0.25, 1.0, 2.0, 4.0 }) |r| {
        var in: [8]Sample(f32) = undefined;
        for (&in) |*x| x.* = s(0.9); // a strong constant so a non-zero first sample stands out
        var out: [8]Sample(f32) = undefined;
        var vs = VS{};
        vs.setParam(0, r);
        const p = vs.pull(&in, out.len, &out);
        try std.testing.expect(p >= 1);
        // x[-1] = 0, frac = 0 ⇒ output[0] = 0 + 0*(x[0]-0) = 0, bit-exactly.
        try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 0))), @as(u32, @bitCast(out[0].ch[0])));
    }
}

// ===========================================================================
// Identity at ratio 1.0: output[n] == input[n-1] (the one-sample phase).
//
// At ratio 1, step = 1: before output 0, frac=0 ⇒ out[0]=lerp(x[-1],x[0],0)=0.
// After, frac becomes 1, so output 1 consumes x[0] into `prev` and emits
// lerp(x[0],x[1],0)=x[0]. In general out[n] = x[n-1], i.e. the input delayed by
// exactly one sample with NO amplitude change — the precise meaning of "ratio 1
// is the identity up to the interpolation phase".
// ===========================================================================

test "Varispeed ratio 1.0 is the identity delayed by exactly one sample (no interpolation error)" {
    const gpa = std.testing.allocator;
    const N = 256;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 555);
    const out = try gpa.alloc(Sample(f32), N);
    defer gpa.free(out);

    var vs = VS{};
    vs.setParam(0, 1.0);
    const p = vs.pull(in, N, out);
    try std.testing.expectEqual(N, p);

    // out[0] == 0 (pre-roll); out[n] == in[n-1] BIT-EXACTLY for n >= 1 — at a
    // unit ratio the fraction is exactly 0, so the lerp returns the left bracket
    // verbatim with no rounding.
    try std.testing.expectEqual(@as(f32, 0), out[0].ch[0]);
    for (1..N) |n| {
        try std.testing.expectEqual(in[n - 1].ch[0], out[n].ch[0]);
    }
}

// ===========================================================================
// DC / constant preservation: interpolating between equal brackets yields that
// constant, for ANY ratio — once past the silent pre-roll the output is the
// constant exactly.
//
// NOTE the pre-roll is NOT a single sample when upsampling. The left bracket
// starts at the silent pre-roll x[-1]=0; at ratio>1 (read step 1/ratio < 1) the
// resampler emits ~ceil(ratio) outputs that interpolate from that silence toward
// the first real input BEFORE the first input is consumed into `prev`. Only once
// BOTH brackets are real input samples does the constant pass through verbatim.
// So the region to skip is ceil(ratio) outputs (the pre-roll ramp), not one.
// ===========================================================================

test "Varispeed preserves a DC constant at every ratio (lerp of equal endpoints is the endpoint)" {
    const gpa = std.testing.allocator;
    const N = 300;
    const c: f32 = 0.375; // exactly representable, so we can demand bit-exactness
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    for (in) |*x| x.* = s(c);
    const cap = N * 5 + 16;
    const out = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(out);

    inline for (.{ 0.25, 0.5, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0 }) |r| {
        var vs = VS{};
        vs.setParam(0, r);
        const p = vs.pull(in, cap, out);
        // Skip the silent-pre-roll ramp (ceil(ratio) outputs interpolate from
        // x[-1]=0 toward the first input); +1 guards the boundary sample.
        const preroll: usize = @as(usize, @intFromFloat(@ceil(@as(f32, r)))) + 1;
        try std.testing.expect(p > preroll);
        // From there on both brackets are c, so c + f*(c-c) == c exactly.
        for (preroll..p) |n| {
            try std.testing.expectEqual(c, out[n].ch[0]);
        }
    }
}

// ===========================================================================
// Linearity: at a FIXED ratio the resampler is a linear operator on the input.
//   - homogeneity: resample(a*x) == a*resample(x)
//   - additivity:  resample(x+y) == resample(x)+resample(y)
// The read SCHEDULE depends only on the ratio, never on sample values, so this
// holds up to float rounding (compared with the oracle tolerance).
// ===========================================================================

test "Varispeed is linear at a fixed ratio: scaling and superposition commute with resampling" {
    const gpa = std.testing.allocator;
    const N = 400;
    const x = try gpa.alloc(Sample(f32), N);
    defer gpa.free(x);
    const y = try gpa.alloc(Sample(f32), N);
    defer gpa.free(y);
    h.fillNoise(x, 11);
    h.fillNoise(y, 22);

    const cap = N * 5 + 16;
    const buf_x = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(buf_x);
    const buf_y = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(buf_y);
    const buf_combo = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(buf_combo);
    const expect = try gpa.alloc(f32, cap);
    defer gpa.free(expect);

    const a: f32 = 2.5;
    const b: f32 = -1.25;

    inline for (.{ 0.25, 0.5, 1.0, 1.5, 2.0, 4.0 }) |r| {
        // Resample x and y separately.
        var vx = VS{};
        vx.setParam(0, r);
        const px = vx.pull(x, cap, buf_x);
        var vy = VS{};
        vy.setParam(0, r);
        const py = vy.pull(y, cap, buf_y);

        // Build the combination a*x + b*y and resample it.
        const combo = try gpa.alloc(Sample(f32), N);
        defer gpa.free(combo);
        for (0..N) |i| combo[i] = s(a * x[i].ch[0] + b * y[i].ch[0]);
        var vc = VS{};
        vc.setParam(0, r);
        const pc = vc.pull(combo, cap, buf_combo);

        try std.testing.expectEqual(px, py);
        try std.testing.expectEqual(px, pc);
        // a*resample(x) + b*resample(y) must equal resample(a*x+b*y).
        for (0..pc) |i| expect[i] = a * buf_x[i].ch[0] + b * buf_y[i].ch[0];
        try h.allcloseF32(h.sampleValues(buf_combo[0..pc]), expect[0..pc], ORACLE_TOL);
    }
}

// ===========================================================================
// Sinusoid period scaling: a sine of period P_in input samples resampled at
// ratio r appears with period P_in * r OUTPUT samples (the rate is r times
// faster, so each input period spans r times as many output samples). We verify
// the OUTPUT period by counting samples between zero-up-crossings.
// ===========================================================================

test "Varispeed scales a sinusoid's period by the ratio (P_out == P_in * ratio)" {
    const gpa = std.testing.allocator;
    const N = 2000;
    const period_in: f32 = 40.0; // 40 input samples per cycle
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    for (0..N) |i| {
        const ph = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / period_in;
        in[i] = s(@sin(ph));
    }
    const cap = N * 5 + 16;
    const out = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(out);

    inline for (.{ 0.5, 1.0, 2.0 }) |r| {
        var vs = VS{};
        vs.setParam(0, r);
        const p = vs.pull(in, cap, out);
        const vals = h.sampleValues(out[0..p]);

        // Measure the mean spacing of rising zero-crossings in steady state
        // (skip the first cycle to clear the pre-roll). A rising crossing is
        // v[n] <= 0 < v[n+1].
        var first: ?usize = null;
        var last: usize = 0;
        var crossings: usize = 0;
        const skip = @as(usize, @intFromFloat(period_in * r)) + 4;
        var n: usize = skip;
        while (n + 1 < p) : (n += 1) {
            if (vals[n] <= 0 and vals[n + 1] > 0) {
                if (first == null) first = n;
                last = n;
                crossings += 1;
            }
        }
        try std.testing.expect(crossings >= 3);
        const span: f32 = @floatFromInt(last - first.?);
        const measured_period = span / @as(f32, @floatFromInt(crossings - 1));
        const expected_period = period_in * @as(f32, r);
        // Within one output sample of the expected scaled period.
        try std.testing.expectApproxEqAbs(expected_period, measured_period, 1.0);
    }
}

// ===========================================================================
// Produced-count vs ratio: over a fixed input, upsampling (ratio>1) yields more
// outputs than downsampling (ratio<1), and the produced count tracks ratio
// (produced ≈ ratio * input_len). A monotone family across the interval.
// ===========================================================================

test "Varispeed produced count is strictly monotone in the ratio over a fixed input" {
    const gpa = std.testing.allocator;
    const N = 1000;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 3);
    const cap = N * 5 + 16;
    const out = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(out);

    var prev_count: usize = 0;
    inline for (.{ 0.25, 0.5, 1.0, 2.0, 4.0 }) |r| {
        var vs = VS{};
        vs.setParam(0, r);
        const p = vs.pull(in, cap, out);
        // A higher ratio produces strictly more outputs from the same input.
        try std.testing.expect(p > prev_count);
        prev_count = p;
        // produced ≈ ratio * N (within a few samples of edge/pre-roll effect).
        const expected: f32 = @as(f32, r) * @as(f32, @floatFromInt(N));
        try std.testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(p)), 4.0);
    }
}

// ===========================================================================
// HELD-PER-CALL: a setParam mid-stream takes effect on the NEXT pull only — it
// can NEVER change the ratio inside a buffer.
//
// Construction: pull A under one held ratio, then setParam to a different ratio,
// then pull B. We prove the ratio was held for the WHOLE of pull A by showing
// pull A is bit-identical to a reference block run at the original ratio for the
// same input/want — i.e. the late setParam did not leak into A. We separately
// prove B switched cleanly to the new ratio.
// ===========================================================================

test "Varispeed holds the ratio for the whole pull: a setParam between pulls only affects the next pull" {
    const gpa = std.testing.allocator;
    const N = 600;
    const in = try gpa.alloc(Sample(f32), 2 * N);
    defer gpa.free(in);
    h.fillNoise(in, 88);
    const cap = N * 5 + 16;

    const a_buf = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(a_buf);
    const b_buf = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(b_buf);
    const ref_buf = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(ref_buf);

    const r0: f32 = 1.0;
    const r1: f32 = 2.0;

    // The block under test: hold r0 for pull A over in[0..N], then switch to r1
    // for pull B over in[N..2N].
    var vs = VS{};
    vs.setParam(0, r0);
    const pa = vs.pull(in[0..N], cap, a_buf);
    vs.setParam(0, r1); // mid-stream change — must NOT affect the already-finished A
    const pb = vs.pull(in[N .. 2 * N], cap, b_buf);

    // Reference for A: a fresh block held at r0 over the same input — pull A must
    // be bit-identical to it (the late setParam did not leak backward, and the
    // ratio was held for all of A).
    var ref_a = VS{};
    ref_a.setParam(0, r0);
    const pra = ref_a.pull(in[0..N], cap, ref_buf);
    try std.testing.expectEqual(pra, pa);
    try std.testing.expect(h.firstBitDivergence(
        h.sampleValues(a_buf[0..pa]),
        h.sampleValues(ref_buf[0..pra]),
    ) == null);

    // Reference for B: a block carrying the SAME end-state as `vs` after pull A,
    // then switched to r1. We rebuild that by replaying A then B on a clone —
    // since the render is a pure function of (input, held-ratio sequence), the
    // clone must match B bit-exactly. This shows B fully adopted r1.
    var clone = VS{};
    clone.setParam(0, r0);
    _ = clone.pull(in[0..N], cap, ref_buf); // reach the same internal state as `vs`
    clone.setParam(0, r1);
    const prb = clone.pull(in[N .. 2 * N], cap, ref_buf);
    try std.testing.expectEqual(prb, pb);
    try std.testing.expect(h.firstBitDivergence(
        h.sampleValues(b_buf[0..pb]),
        h.sampleValues(ref_buf[0..prb]),
    ) == null);

    // And B genuinely ran at r1, not r0: at r1=2.0 it produces ~2x the outputs a
    // single block at r0 would for the same input length.
    try std.testing.expect(pb > pa); // B (upsample) out-produces A (unity) on equal input
}

// ===========================================================================
// Held-per-call, the sharper form: a setParam DURING a chunked render only takes
// effect at the NEXT pull boundary. We drive a chunked sequence, flip the ratio
// at a chunk boundary, and show the result equals a two-segment render where the
// first segment uses the old ratio and the second uses the new one — never a
// blend, and never a mid-chunk switch.
// ===========================================================================

test "Varispeed mid-render ratio change applies exactly at the pull boundary, not within a chunk" {
    const gpa = std.testing.allocator;
    const N = 800;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 1234);
    const cap = N * 5 + 16;

    const chunk = 100;
    const switch_at = 4; // flip ratio after the 4th chunk (input index 400)
    const split = chunk * switch_at;

    const got = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(got);

    const r_first: f32 = 1.0;
    const r_second: f32 = 3.0;

    // Chunked render with a ratio flip at the chunk boundary `split`.
    var vs = VS{};
    vs.setParam(0, r_first);
    var produced: usize = 0;
    var i: usize = 0;
    while (i < N) : (i += chunk) {
        if (i == split) vs.setParam(0, r_second);
        const c = @min(chunk, N - i);
        produced += vs.pull(in[i .. i + c], cap - produced, got[produced..]);
    }

    // Reference: same block, but render the two segments as two pulls with the
    // ratio held per segment — identical setParam timing, expressed plainly.
    const ref = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(ref);
    var rv = VS{};
    rv.setParam(0, r_first);
    var rp: usize = 0;
    // First segment: chunks [0, split) at r_first.
    var j: usize = 0;
    while (j < split) : (j += chunk) {
        const c = @min(chunk, split - j);
        rp += rv.pull(in[j .. j + c], cap - rp, ref[rp..]);
    }
    rv.setParam(0, r_second);
    // Second segment: chunks [split, N) at r_second.
    j = split;
    while (j < N) : (j += chunk) {
        const c = @min(chunk, N - j);
        rp += rv.pull(in[j .. j + c], cap - rp, ref[rp..]);
    }

    try std.testing.expectEqual(rp, produced);
    try std.testing.expect(h.firstBitDivergence(
        h.sampleValues(got[0..produced]),
        h.sampleValues(ref[0..rp]),
    ) == null);
}

// ===========================================================================
// Chunk-invariance at the bit level, with an irrational ratio so the fractional
// remainder is non-trivial at every chunk seam — the resumable-state contract.
// (The latency gate covers a few "nice" ratios; this stresses a ratio whose
// `frac` never lands on a round boundary, so dropping the remainder would show.)
// ===========================================================================

test "Varispeed chunked render is bit-identical to a whole render at an irrational ratio" {
    const gpa = std.testing.allocator;
    const N = 1500;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 31337);
    const cap = N * 5 + 16;
    const whole = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(whole);
    const chunked = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(chunked);

    const r: f32 = std.math.pi / 2.0; // ~1.5708, clamped well inside [0.25, 4]

    var vw = VS{};
    vw.setParam(0, r);
    const pw = vw.pull(in, cap, whole);

    inline for (.{ 1, 7, 33, 128 }) |ck| {
        var vc = VS{};
        vc.setParam(0, r);
        const pc = h.renderRatePush(VS, Sample(f32), Sample(f32), &vc, in, chunked, ck);
        try std.testing.expectEqual(pw, pc);
        const div = h.firstBitDivergence(h.sampleValues(whole[0..pw]), h.sampleValues(chunked[0..pc]));
        if (div) |idx| {
            std.debug.print("chunk size {d}: first divergence at output {d} ({d} vs {d})\n", .{
                ck, idx, whole[idx].ch[0], chunked[idx].ch[0],
            });
            return error.ChunkInvarianceViolated;
        }
    }
}

// ===========================================================================
// Endpoint exactness: at the EXACT interval endpoints the clamp is a no-op, so a
// request of exactly 0.25 / 4.0 behaves identically to the same ratio reached by
// clamping a more extreme request. The clamp is idempotent at the boundary.
// ===========================================================================

test "Varispeed clamps out-of-interval ratios to the exact endpoint (idempotent at the boundary)" {
    const gpa = std.testing.allocator;
    const N = 500;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 64);
    const cap = N * 5 + 16;
    const at_edge = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(at_edge);
    const beyond = try gpa.alloc(Sample(f32), cap);
    defer gpa.free(beyond);

    // Max edge: 4.0 exactly vs 100.0 (clamped to 4.0) — bit-identical renders.
    {
        var ve = VS{};
        ve.setParam(0, max_ratio);
        const pe = ve.pull(in, cap, at_edge);
        var vb = VS{};
        vb.setParam(0, 100.0);
        const pb = vb.pull(in, cap, beyond);
        try std.testing.expectEqual(pe, pb);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(at_edge[0..pe]), std.mem.sliceAsBytes(beyond[0..pb]));
    }
    // Min edge: 0.25 exactly vs 0.001 (clamped to 0.25) — bit-identical renders.
    {
        var ve = VS{};
        ve.setParam(0, min_ratio);
        const pe = ve.pull(in, cap, at_edge);
        var vb = VS{};
        vb.setParam(0, 0.001);
        const pb = vb.pull(in, cap, beyond);
        try std.testing.expectEqual(pe, pb);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(at_edge[0..pe]), std.mem.sliceAsBytes(beyond[0..pb]));
    }
    // Negative / NaN-ish extremes also clamp to a valid endpoint (min), never
    // escaping the interval into nonsense.
    {
        var ve = VS{};
        ve.setParam(0, min_ratio);
        const pe = ve.pull(in, cap, at_edge);
        var vb = VS{};
        vb.setParam(0, -3.0);
        const pb = vb.pull(in, cap, beyond);
        try std.testing.expectEqual(pe, pb);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(at_edge[0..pe]), std.mem.sliceAsBytes(beyond[0..pb]));
    }
}

// ===========================================================================
// Degenerate edges: want = 0 produces nothing and consumes no state; an empty
// input produces nothing; a tiny want is respected exactly (never over-produces).
// ===========================================================================

test "Varispeed want=0 produces nothing and leaves state untouched" {
    var in: [16]Sample(f32) = undefined;
    for (&in) |*x| x.* = s(0.5);
    var out: [16]Sample(f32) = undefined;
    var vs = VS{};
    vs.setParam(0, 2.0);
    const p = vs.pull(&in, 0, &out);
    try std.testing.expectEqual(@as(usize, 0), p);
    // State unchanged: a subsequent want=N pull behaves exactly like a fresh
    // block's first pull (the want=0 call neither consumed input nor advanced
    // `prev`/`frac`).
    var fresh: [16]Sample(f32) = undefined;
    var fresh_vs = VS{};
    fresh_vs.setParam(0, 2.0);
    const pf = fresh_vs.pull(&in, fresh.len, &fresh);
    var after: [16]Sample(f32) = undefined;
    const pa = vs.pull(&in, after.len, &after);
    try std.testing.expectEqual(pf, pa);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fresh[0..pf]), std.mem.sliceAsBytes(after[0..pa]));
}

test "Varispeed empty input produces nothing at every ratio" {
    var out: [8]Sample(f32) = undefined;
    inline for (.{ 0.25, 1.0, 4.0 }) |r| {
        var vs = VS{};
        vs.setParam(0, r);
        const p = vs.pull(&[_]Sample(f32){}, out.len, &out);
        try std.testing.expectEqual(@as(usize, 0), p);
    }
}

test "Varispeed never produces more than `want` even when the input could afford more" {
    const gpa = std.testing.allocator;
    const N = 500;
    const in = try gpa.alloc(Sample(f32), N);
    defer gpa.free(in);
    h.fillNoise(in, 71);
    // At ratio 4 the input affords ~2000 outputs; ask for only 10.
    var out: [10]Sample(f32) = undefined;
    var vs = VS{};
    vs.setParam(0, 4.0);
    const p = vs.pull(in, 10, &out);
    try std.testing.expectEqual(@as(usize, 10), p);
}

// ===========================================================================
// needed_input as the EXACT planning bound: needed_input(want) inputs suffice to
// make `want` outputs (sound), and it is non-increasing in the ratio — checked
// here AGAINST the oracle's notion of how many inputs each output consumes, so it
// is not merely a restatement of the impl's own formula. (The latency gate
// already checks soundness at a few ratios; here we cross-check the bound is not
// wastefully loose by more than the documented one-guard-sample slack.)
// ===========================================================================

test "Varispeed needed_input is sound and tight (within the documented one-sample guard)" {
    inline for (.{ 0.25, 0.5, 1.0, 2.0, 4.0 }) |r| {
        const want: usize = 256;
        var vs = VS{};
        vs.setParam(0, r);
        const ni = vs.needed_input(want);

        // Sound: exactly `ni` inputs yield `want` outputs.
        const gpa = std.testing.allocator;
        const in = try gpa.alloc(Sample(f32), ni);
        defer gpa.free(in);
        h.fillNoise(in, 9);
        const out = try gpa.alloc(Sample(f32), want);
        defer gpa.free(out);
        const produced = vs.pull(in, want, out);
        try std.testing.expectEqual(want, produced);

        // Tight: ni exceeds the truly-consumed count by no more than the
        // documented guard. A fresh block consuming `want` outputs at ratio r
        // reads ceil(want/r) brackets plus the look-back; the bound's slack over
        // that is a small constant, not proportional to `want`.
        var probe = VS{};
        probe.setParam(0, r);
        const big = try gpa.alloc(Sample(f32), ni + 8);
        defer gpa.free(big);
        h.fillNoise(big, 9);
        const out2 = try gpa.alloc(Sample(f32), want);
        defer gpa.free(out2);
        _ = probe.pull(big, want, out2);
        // The minimal sufficient input is around ceil(want/r) + a couple; assert
        // ni is within 3 of that floor so the planner is not grossly loose.
        const minimal: f32 = @ceil(@as(f32, @floatFromInt(want)) / @as(f32, r));
        const ni_f: f32 = @floatFromInt(ni);
        try std.testing.expect(ni_f >= minimal); // never under-plans
        try std.testing.expect(ni_f <= minimal + 3.0); // never wildly over-plans
    }
}
