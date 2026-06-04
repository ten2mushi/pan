//! generator_gold_vector_test — the INDEPENDENT-ORACLE ("tests as definition,
//! the Yoneda way") characterization of the Phase-13 audio-rate Source
//! generators in `src/gen.zig`: `Sine`, `PolyBlepSaw`, `PolyBlepSquare`,
//! `Noise`, `Constant`, `Wavetable`. This is testing gate §5.7g — "Source
//! generators — generator gold-vectors & anti-aliasing".
//!
//! The Yoneda discipline: a block IS the totality of its observable morphisms,
//! so each generator is pinned by ALL of them — its comptime class + output
//! element type, its analytic gold vector vs an INDEPENDENT in-test oracle, the
//! pull-demand length invariant (`out.len == N`, bit-exact), the persistent
//! phase/RNG/cursor carry ACROSS calls, sub-block-split ≡ whole-block equality,
//! frequency-as-Hz conversion through `sample_rate`, and — the load-bearing
//! §5.7g check — that PolyBLEP MATERIALLY band-limits a swept tone, proven by a
//! NAIVE (non-PolyBLEP) saw/square written inline as the negative reference.
//!
//! ORACLE DISCIPLINE (Rule 9, hermetic — no SciPy/librosa, no disk, no blob
//! files): every numeric expectation is recomputed in-test by a DIRECT, NAIVE,
//! INDEPENDENT reimplementation of the documented formula, sharing only the
//! *definition* with pan's block — never its loop/accumulation order. The Sine
//! oracle evaluates the analytic `sin(2π·f·n/Fs)` from the closed-form sample
//! index n; the Noise oracle reaccumulates the 64-bit LCG recurrence by hand;
//! the Wavetable oracle runs an independent linear interpolation; the
//! anti-aliasing oracle measures spectral energy with a hand-rolled DFT.
//!
//! COMPARISON MODES (two-mode policy): float `allclose` (a tolerance helper)
//! for analytic-oracle agreement; BIT-EXACT (`expectEqual`) for the pull-length
//! invariant and for Noise determinism (same seed ⇒ byte-identical stream).

const std = @import("std");
const pan = @import("pan");

const gen = pan.gen;
const Sample = pan.types.Sample;
const Scalar = pan.types.Scalar;

// ===========================================================================
// Shared helpers — tolerance comparison and a hermetic DFT for the spectral
// anti-aliasing argument. None of these call pan's own code.
// ===========================================================================

/// Assert two f32 slices are close everywhere (the analytic `allclose`).
fn expectAllClose(actual: []const f32, expected: []const f32, tol: f32) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |a, e| {
        try std.testing.expectApproxEqAbs(e, a, tol);
    }
}

/// One bin of a naive DFT: the magnitude of the complex sum
/// Σ x[n]·exp(-j·2π·k·n/N), independent of any library FFT. Used to weigh
/// spectral energy at and away from the fundamental for the band-limiting proof.
fn dftMag(x: []const f32, k: usize) f64 {
    const N = x.len;
    var re: f64 = 0;
    var im: f64 = 0;
    var n: usize = 0;
    while (n < N) : (n += 1) {
        const ang = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) *
            @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(N));
        const xn: f64 = x[n];
        re += xn * @cos(ang);
        im += xn * @sin(ang);
    }
    return @sqrt(re * re + im * im);
}

/// Sum of squared magnitude over a bin range [lo, hi). A coarse "energy in this
/// band" measure built only from `dftMag`.
fn bandEnergy(x: []const f32, lo: usize, hi: usize) f64 {
    var e: f64 = 0;
    var k = lo;
    while (k < hi) : (k += 1) {
        const m = dftMag(x, k);
        e += m * m;
    }
    return e;
}

// ===========================================================================
// §5.7g — Comptime classification: each audio source is a zero-input
// Sample(f32) Map source (a path head). This is the morphism the executor's
// scheduler keys on; if it regressed, the generator would no longer root a path.
// ===========================================================================

test "§5.7g: audio sources classify as zero-input Sample(f32) Map sources" {
    inline for (.{
        gen.Sine,  gen.PolyBlepSaw, gen.PolyBlepSquare,
        gen.Noise, gen.Constant,    gen.Wavetable,
    }) |Osc| {
        try std.testing.expect(pan.port.classify(Osc) == .Map);
        try std.testing.expect(comptime pan.port.isSource(Osc));
        try std.testing.expect(pan.port.MapOutPort(Osc).Elem == Sample(f32));
    }
}

// ===========================================================================
// §5.7g — Sine: matches the analytic sin(2π·f·n/Fs) gold vector (≈), Hz→phase
// conversion via sample_rate, and phase carry across calls.
// ===========================================================================

test "§5.7g: Sine matches analytic sin(2π·f·n/Fs) gold vector (≈)" {
    const Fs: f32 = 48_000;
    const f: f32 = 997.0; // an odd, non-divisor frequency: no lucky phase grid
    var s: gen.Sine = .{ .sample_rate = Fs };
    s.setFrequency(f);

    var out: [512]Sample(f32) = undefined;
    s.process(&out);

    // INDEPENDENT oracle: closed-form analytic sine at sample index n. pan
    // accumulates `phase += increment` per sample; the oracle never does — it
    // evaluates sin(2π · f·n/Fs) directly. They agree only if pan's recurrence
    // tracks the closed form. (Float drift over 512 steps bounds the tol.)
    var expected: [512]f32 = undefined;
    for (&expected, 0..) |*e, n| {
        const arg = 2.0 * std.math.pi * @as(f64, f) *
            @as(f64, @floatFromInt(n)) / @as(f64, Fs);
        e.* = @floatCast(@sin(arg));
    }

    var actual: [512]f32 = undefined;
    for (&actual, out) |*a, o| a.* = o.ch[0];
    try expectAllClose(&actual, &expected, 1e-4);
}

test "§5.7g: Sine — setFrequency converts Hz to phase increment = hz/sample_rate" {
    // The doc-comment contract: increment = freq / sample_rate. Pin it directly
    // and indirectly: at Fs=4, f=1 ⇒ increment 0.25 ⇒ four samples per cycle,
    // sin grid {0, +1, 0, -1}, phase wraps exactly back to 0.
    var s: gen.Sine = .{ .sample_rate = 4 };
    s.setFrequency(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), s.increment, 1e-7);

    var out: [4]Sample(f32) = undefined;
    s.process(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[1].ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[2].ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), out[3].ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.phase, 1e-6);
}

test "§5.7g: Sine phase is persistent — block-split render ≡ one whole-block render" {
    const Fs: f32 = 44_100;
    const f: f32 = 440.0;

    // Whole block of 300 samples.
    var whole: gen.Sine = .{ .sample_rate = Fs };
    whole.setFrequency(f);
    var wbuf: [300]Sample(f32) = undefined;
    whole.process(&wbuf);

    // Same source rendered as 3 sub-blocks (100 + 73 + 127). The persistent
    // phase MUST carry across the calls so the stitched stream is identical.
    var split: gen.Sine = .{ .sample_rate = Fs };
    split.setFrequency(f);
    var sbuf: [300]Sample(f32) = undefined;
    split.process(sbuf[0..100]);
    split.process(sbuf[100..173]);
    split.process(sbuf[173..300]);

    for (wbuf, sbuf) |w, s| try std.testing.expectEqual(w.ch[0], s.ch[0]);
}

test "§5.7g: Sine — out.len drives the pull length (bit-exact length invariant)" {
    // The Source classifier sets output length from the pull demand N, not from
    // any input slice (there is none). Render into buffers of distinct lengths
    // and confirm every requested lane was written (none left ==1.0 sentinel)
    // and the count equals N exactly.
    inline for (.{ 1, 2, 7, 64, 333 }) |N| {
        var s: gen.Sine = .{ .sample_rate = 48_000 };
        s.setFrequency(1000.0);
        var buf: [N]Sample(f32) = undefined;
        for (&buf) |*b| b.ch[0] = std.math.nan(f32); // poison the buffer
        s.process(&buf);
        try std.testing.expectEqual(@as(usize, N), buf.len);
        for (buf) |b| try std.testing.expect(!std.math.isNan(b.ch[0]));
    }
}

// ===========================================================================
// §5.7g — Constant: emits exactly its level; param slot 0 sets level; length.
// ===========================================================================

test "§5.7g: Constant emits exactly its level for every pulled sample (bit-exact)" {
    inline for (.{ -1.0, 0.0, 0.5, 3.25 }) |lvl| {
        var c: gen.Constant = .{ .level = lvl };
        var out: [37]Sample(f32) = undefined;
        c.process(&out);
        for (out) |o| try std.testing.expectEqual(@as(f32, lvl), o.ch[0]);
    }
}

test "§5.7g: Constant — setParam slot 0 writes level; foreign slots are inert" {
    var c: gen.Constant = .{ .level = 0 };
    c.setParam(0, 2.5);
    try std.testing.expectEqual(@as(f32, 2.5), c.level);
    // A non-existent slot must not perturb the only param.
    c.setParam(7, 99.0);
    try std.testing.expectEqual(@as(f32, 2.5), c.level);
}

// ===========================================================================
// §5.7g — Noise: deterministic LCG (same seed ⇒ byte-identical stream),
// matches a hand-reaccumulated oracle, and is uniform in [-1, 1).
// ===========================================================================

test "§5.7g: Noise matches an independent 64-bit LCG oracle and is in [-1,1)" {
    const seed: u64 = 0xDEADBEEFCAFEBABE;
    var ns: gen.Noise = .{ .state = seed };

    // INDEPENDENT oracle: re-run the documented recurrence by hand —
    // state = state*6364136223846793005 + 1442695040888963407 (wrapping), then
    // word = high 32 bits, value = word·(2/2^32) − 1. Shares only the constants
    // and the definition, not pan's call frame.
    var ostate: u64 = seed;
    var k: usize = 0;
    while (k < 256) : (k += 1) {
        ostate = ostate *% 6364136223846793005 +% 1442695040888963407;
        const word: u32 = @truncate(ostate >> 32);
        const expected = @as(f32, @floatFromInt(word)) * (2.0 / 4294967296.0) - 1.0;
        const got = ns.tick();
        try std.testing.expectEqual(expected, got); // bit-exact to the oracle
        try std.testing.expect(got >= -1.0 and got < 1.0); // uniform range
    }
}

test "§5.7g: Noise determinism — same seed ⇒ byte-identical stream (bit-exact)" {
    var a: gen.Noise = .{ .state = 0xABCDEF0123456789 };
    var b: gen.Noise = .{ .state = 0xABCDEF0123456789 };
    var abuf: [128]Sample(f32) = undefined;
    var bbuf: [128]Sample(f32) = undefined;
    a.process(&abuf);
    b.process(&bbuf);
    // Compare the raw IEEE-754 bit patterns: stronger than float-equal, this is
    // the reproducibility guarantee the offline timeline relies on.
    for (abuf, bbuf) |x, y| {
        try std.testing.expectEqual(@as(u32, @bitCast(x.ch[0])), @as(u32, @bitCast(y.ch[0])));
    }
}

test "§5.7g: Noise — a different seed yields a different stream" {
    // Determinism is only meaningful if the seed actually steers the stream.
    var a: gen.Noise = .{ .state = 1 };
    var b: gen.Noise = .{ .state = 2 };
    var differ = false;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        if (a.tick() != b.tick()) differ = true;
    }
    try std.testing.expect(differ);
}

test "§5.7g: Noise — block-split render ≡ whole-block render (state carry)" {
    var whole: gen.Noise = .{ .state = 777 };
    var wbuf: [200]Sample(f32) = undefined;
    whole.process(&wbuf);

    var split: gen.Noise = .{ .state = 777 };
    var sbuf: [200]Sample(f32) = undefined;
    split.process(sbuf[0..50]);
    split.process(sbuf[50..200]);

    for (wbuf, sbuf) |w, s| {
        try std.testing.expectEqual(@as(u32, @bitCast(w.ch[0])), @as(u32, @bitCast(s.ch[0])));
    }
}

// ===========================================================================
// §5.7g — Wavetable: independent linear-interpolation oracle, exact-grid read,
// Hz conversion, and phase carry.
// ===========================================================================

test "§5.7g: Wavetable matches an independent linear-interpolation oracle (≈)" {
    // A non-trivial 8-entry single cycle (asymmetric so interpolation matters).
    const table = [_]f32{ 0.0, 1.0, 0.5, -0.5, -1.0, -0.25, 0.25, 0.75 };
    const Fs: f32 = 48_000;
    const f: f32 = 1234.5; // arbitrary Hz ⇒ non-integer table strides

    var wt: gen.Wavetable = .{ .table = &table, .sample_rate = Fs };
    wt.setFrequency(f);
    try std.testing.expectApproxEqAbs(f / Fs, wt.increment, 1e-7);

    var out: [256]Sample(f32) = undefined;
    wt.process(&out);

    // INDEPENDENT oracle: replay the phase recurrence and the documented linear
    // interpolation read — pos = phase·len, idx = floor(pos), frac = pos−idx,
    // v = table[idx%len] + (table[(idx+1)%len] − table[idx%len])·frac — in a
    // separate loop with its own phase accumulator.
    const len = table.len;
    var ophase: f32 = 0;
    const inc = f / Fs;
    var expected: [256]f32 = undefined;
    for (&expected) |*e| {
        const pos = ophase * @as(f32, @floatFromInt(len));
        const idx: usize = @intFromFloat(pos);
        const frac = pos - @floor(pos);
        const a = table[idx % len];
        const b = table[(idx + 1) % len];
        e.* = a + (b - a) * frac;
        ophase = ophase + inc - @floor(ophase + inc);
    }

    var actual: [256]f32 = undefined;
    for (&actual, out) |*a, o| a.* = o.ch[0];
    try expectAllClose(&actual, &expected, 1e-5);
}

test "§5.7g: Wavetable — integer-grid phase reads table entries exactly" {
    // With Fs = len and f = 1, increment = 1/len ⇒ each tick lands on an exact
    // table index (frac = 0), so the read is the bare table value, no interp.
    const table = [_]f32{ 10, 20, 30, 40 };
    var wt: gen.Wavetable = .{ .table = &table, .sample_rate = @floatFromInt(table.len) };
    wt.setFrequency(1.0); // increment = 1/4
    var out: [4]Sample(f32) = undefined;
    wt.process(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 10), out[0].ch[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 20), out[1].ch[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 30), out[2].ch[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 40), out[3].ch[0], 1e-5);
}

test "§5.7g: Wavetable — block-split render ≡ whole-block render (phase carry)" {
    const table = [_]f32{ 0.0, 0.3, 0.9, -0.2, -0.7, 0.1 };
    const Fs: f32 = 44_100;
    const f: f32 = 523.25;

    var whole: gen.Wavetable = .{ .table = &table, .sample_rate = Fs };
    whole.setFrequency(f);
    var wbuf: [180]Sample(f32) = undefined;
    whole.process(&wbuf);

    var split: gen.Wavetable = .{ .table = &table, .sample_rate = Fs };
    split.setFrequency(f);
    var sbuf: [180]Sample(f32) = undefined;
    split.process(sbuf[0..40]);
    split.process(sbuf[40..91]);
    split.process(sbuf[91..180]);

    for (wbuf, sbuf) |w, s| try std.testing.expectEqual(w.ch[0], s.ch[0]);
}

// ===========================================================================
// §5.7g — THE LOAD-BEARING ANTI-ALIASING CHECK.
//
// A naive sawtooth `2·phase − 1` jumps a full amplitude in one sample at every
// period reset; that discontinuity injects energy at high harmonics that fold
// (alias) back below the fundamental. PolyBLEP smears the jump so those high
// harmonics are materially attenuated. We render a HIGH-frequency saw both ways
// (naive inline reference vs pan's PolyBlepSaw) and prove pan puts MATERIALLY
// less energy in the aliased band (below the fundamental bin) than the naive
// reference. Same argument for the square (two discontinuities per period).
// ===========================================================================

/// Inline NEGATIVE reference: a NAIVE (non-band-limited) sawtooth, the exact
/// failure mode PolyBLEP corrects. Phase recurrence identical to pan's so the
/// ONLY difference under test is the PolyBLEP residual subtraction.
fn naiveSaw(buf: []f32, increment: f32) void {
    var phase: f32 = 0;
    for (buf) |*o| {
        o.* = 2.0 * phase - 1.0;
        phase = phase + increment - @floor(phase + increment);
    }
}

/// Inline NEGATIVE reference: a NAIVE square in {+1, -1} with no edge
/// correction — the aliasing failure mode for the square.
fn naiveSquare(buf: []f32, increment: f32) void {
    var phase: f32 = 0;
    for (buf) |*o| {
        o.* = if (phase < 0.5) @as(f32, 1) else @as(f32, -1);
        phase = phase + increment - @floor(phase + increment);
    }
}

test "§5.7g: PolyBlepSaw band-limits the wrap vs a naive saw (≈)" {
    const N = 2048;
    const Fs: f32 = 48_000;
    // A high fundamental (7 kHz) whose 2nd harmonic (14 kHz) is still below
    // Nyquist but whose 4th+ harmonics (28 kHz…) exceed it — so a naive ramp
    // FOLDS that energy back into the audible band: the aliasing failure mode.
    // 7000 does not divide the bin grid, so the fold lands as broadband spuria.
    const f: f32 = 7000.0;
    const inc = f / Fs;
    const k0: usize = @intFromFloat(@round(@as(f64, f) * @as(f64, N) / @as(f64, Fs)));

    // pan's band-limited saw.
    var saw: gen.PolyBlepSaw = .{ .sample_rate = Fs };
    saw.setFrequency(f);
    var sbuf: [N]Sample(f32) = undefined;
    saw.process(&sbuf);
    var poly: [N]f32 = undefined;
    for (&poly, sbuf) |*p, o| p.* = o.ch[0];

    // The naive inline reference (same phase recurrence, no PolyBLEP).
    var naive: [N]f32 = undefined;
    naiveSaw(&naive, inc);

    // The discriminating band = the upper quarter of the spectrum [N/4, N/2),
    // i.e. 12–24 kHz. A truly band-limited 7 kHz saw has very little energy up
    // there (only its few surviving harmonics rolled off); a NAIVE ramp dumps
    // its un-attenuated high harmonics and folded aliases there. So this band's
    // energy is the band-limiting signature.
    const energyNaive = bandEnergy(&naive, N / 4, N / 2);
    const energyPoly = bandEnergy(&poly, N / 4, N / 2);

    std.debug.print(
        "\n[saw §5.7g] k0={d} upper-spectrum energy: naive={d:.2} poly={d:.2} ratio={d:.4}\n",
        .{ k0, energyNaive, energyPoly, energyPoly / energyNaive },
    );

    // The band-limiting claim: PolyBLEP leaves MATERIALLY less energy in the
    // upper band. Require a generous margin (poly < 0.6·naive) so a regression
    // to a naive ramp (ratio ≈ 1) fails loudly, without over-fitting the exact
    // attenuation (~0.33 observed). The fundamental itself must survive.
    try std.testing.expect(energyPoly < 0.6 * energyNaive);
    try std.testing.expect(dftMag(&poly, k0) > 0.5 * dftMag(&naive, k0));
}

test "§5.7g: PolyBlepSquare band-limits its two edges vs a naive square (≈)" {
    const N = 2048;
    const Fs: f32 = 48_000;
    const f: f32 = 7000.0;
    const inc = f / Fs;
    const k0: usize = @intFromFloat(@round(@as(f64, f) * @as(f64, N) / @as(f64, Fs)));

    var sq: gen.PolyBlepSquare = .{ .sample_rate = Fs };
    sq.setFrequency(f);
    var sbuf: [N]Sample(f32) = undefined;
    sq.process(&sbuf);
    var poly: [N]f32 = undefined;
    for (&poly, sbuf) |*p, o| p.* = o.ch[0];

    var naive: [N]f32 = undefined;
    naiveSquare(&naive, inc);

    // The square has TWO discontinuities per period, so its naive high-harmonic
    // content (and folded aliasing) is even stronger; PolyBLEP corrects both
    // edges. Same upper-quarter energy discriminator as the saw.
    const energyNaive = bandEnergy(&naive, N / 4, N / 2);
    const energyPoly = bandEnergy(&poly, N / 4, N / 2);

    std.debug.print(
        "[square §5.7g] k0={d} upper-spectrum energy: naive={d:.2} poly={d:.2} ratio={d:.4}\n",
        .{ k0, energyNaive, energyPoly, energyPoly / energyNaive },
    );

    try std.testing.expect(energyPoly < 0.6 * energyNaive);
    try std.testing.expect(dftMag(&poly, k0) > 0.5 * dftMag(&naive, k0));
}

test "§5.7g: PolyBLEP residual is zero away from a discontinuity (saw mid-period ≡ naive)" {
    // PolyBLEP must be free except within ~increment of an edge: at a sample
    // strictly inside a period, the band-limited saw equals the naive ramp. We
    // render a single block at a low increment (wide flat region) and check that
    // the bulk of samples coincide with `2·phase−1`, isolating the correction to
    // the few edge samples. This pins "zero away from the discontinuity".
    const N = 512;
    const Fs: f32 = 48_000;
    const f: f32 = 200.0; // low ⇒ small increment ⇒ narrow edge band
    const inc = f / Fs;

    var saw: gen.PolyBlepSaw = .{ .sample_rate = Fs };
    saw.setFrequency(f);
    var sbuf: [N]Sample(f32) = undefined;
    saw.process(&sbuf);

    // Independent naive ramp at the same phases.
    var phase: f32 = 0;
    var edge_corrected: usize = 0;
    var total_interior: usize = 0;
    for (sbuf) |o| {
        const naive = 2.0 * phase - 1.0;
        // Interior = at least `inc` away from both 0 and 1 in phase.
        const interior = phase >= inc and phase <= 1.0 - inc;
        if (interior) {
            total_interior += 1;
            // Away from an edge the PolyBLEP residual is exactly 0 ⇒ identical.
            if (o.ch[0] != naive) edge_corrected += 1;
        }
        phase = phase + inc - @floor(phase + inc);
    }
    // Essentially all interior samples must be bit-identical to the naive ramp.
    try std.testing.expect(total_interior > 0);
    try std.testing.expectEqual(@as(usize, 0), edge_corrected);
}

test "§5.7g: PolyBlepSaw / PolyBlepSquare — DC freq (increment 0) has no correction" {
    // polyBlep returns 0 for dt ≤ 0, so a 0 Hz oscillator is the static naive
    // value with no edge smear: the saw sits at 2·0−1 = −1, the square at +1
    // (phase 0 < 0.5). Pins the dt ≤ 0 guard.
    var saw: gen.PolyBlepSaw = .{ .sample_rate = 48_000 };
    saw.setFrequency(0.0);
    var sbuf: [8]Sample(f32) = undefined;
    saw.process(&sbuf);
    for (sbuf) |o| try std.testing.expectEqual(@as(f32, -1), o.ch[0]);

    var sq: gen.PolyBlepSquare = .{ .sample_rate = 48_000 };
    sq.setFrequency(0.0);
    var qbuf: [8]Sample(f32) = undefined;
    sq.process(&qbuf);
    for (qbuf) |o| try std.testing.expectEqual(@as(f32, 1), o.ch[0]);
}

test "§5.7g: PolyBlepSaw / PolyBlepSquare — block-split ≡ whole-block (phase carry)" {
    const Fs: f32 = 44_100;
    const f: f32 = 880.0;

    inline for (.{ gen.PolyBlepSaw, gen.PolyBlepSquare }) |Osc| {
        var whole: Osc = .{ .sample_rate = Fs };
        whole.setFrequency(f);
        var wbuf: [240]Sample(f32) = undefined;
        whole.process(&wbuf);

        var split: Osc = .{ .sample_rate = Fs };
        split.setFrequency(f);
        var sbuf: [240]Sample(f32) = undefined;
        split.process(sbuf[0..60]);
        split.process(sbuf[60..137]);
        split.process(sbuf[137..240]);

        for (wbuf, sbuf) |w, s| try std.testing.expectEqual(w.ch[0], s.ch[0]);
    }
}

test "§5.7g: every audio source fills the whole pull buffer (no undefined lanes)" {
    // The Source classifier sizes output from the pull demand and the executor's
    // poison guard requires every lane finite. Poison each buffer, render, and
    // confirm no lane was left as the NaN sentinel — across ALL six generators.
    const table = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    inline for (.{ 3, 16, 129 }) |N| {
        var sine: gen.Sine = .{ .sample_rate = 48_000 };
        sine.setFrequency(440);
        var saw: gen.PolyBlepSaw = .{ .sample_rate = 48_000 };
        saw.setFrequency(440);
        var sq: gen.PolyBlepSquare = .{ .sample_rate = 48_000 };
        sq.setFrequency(440);
        var ns: gen.Noise = .{ .state = 99 };
        var dc: gen.Constant = .{ .level = 0.25 };
        var wt: gen.Wavetable = .{ .table = &table, .sample_rate = 48_000 };
        wt.setFrequency(440);

        var sbuf: [N]Sample(f32) = undefined;
        var awbuf: [N]Sample(f32) = undefined;
        var qbuf: [N]Sample(f32) = undefined;
        var nbuf: [N]Sample(f32) = undefined;
        var cbuf: [N]Sample(f32) = undefined;
        var tbuf: [N]Sample(f32) = undefined;

        for ([_][]Sample(f32){ &sbuf, &awbuf, &qbuf, &nbuf, &cbuf, &tbuf }) |b| {
            for (b) |*x| x.ch[0] = std.math.nan(f32);
        }

        sine.process(&sbuf);
        saw.process(&awbuf);
        sq.process(&qbuf);
        ns.process(&nbuf);
        dc.process(&cbuf);
        wt.process(&tbuf);

        for ([_][]Sample(f32){ &sbuf, &awbuf, &qbuf, &nbuf, &cbuf, &tbuf }) |b| {
            try std.testing.expectEqual(@as(usize, N), b.len);
            for (b) |x| try std.testing.expect(!std.math.isNan(x.ch[0]));
        }
    }
}
