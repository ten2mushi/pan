//! "Tests as definition" (Yoneda) — the SPECTRAL LIBRARY blocks.
//!
//! These tests pin the *observable behaviour* of `PartitionedConvolution`,
//! `SpectralGate` and `SpectralEq` against INDEPENDENT oracles — references
//! derived from the mathematical definition of the operation, never from the
//! block's own code path. By the representability (Yoneda) argument a block is
//! determined by its action under the family of muxes / inputs we probe it with,
//! so a complete enough probe set *is* the block's specification: any reimpl that
//! passes all of these is behaviourally equivalent to the one under test.
//!
//! This file ADDS the definitional / edge coverage the in-`spectral.zig` unit
//! tests lack; it does not duplicate them. The in-file tests already pin: class
//! (Rate / Map), unit-impulse identity, a single naive O(N·M) convolution match,
//! one HOP∤chunk split, the |3+4i|=5 gate boundary, zero-threshold gate identity,
//! a known EQ gain curve, and unity-EQ identity. Here we add: the 1:1 demand
//! contract, the unset-IR-is-silence LIMIT, linearity, IR-budget truncation, a
//! delayed-impulse IR's group delay, sample-at-a-time pull, multi-frame batching,
//! the strict-below / sign-independent gate boundary, threshold re-set & wrong-slot,
//! negative / zero EQ gains (the exact component-wise law, and where "zero-phase"
//! breaks), EQ composition (functoriality), and phase preservation.
//!
//! Oracles are computed in this file from first principles:
//!   - convolution: schoolbook y[n] = Σ_m h[m]·x[n−m] in the time domain;
//!   - gate: hand-classified |z| vs threshold per bin;
//!   - EQ: hand-multiplied (re·g, im·g) per bin, and atan2 phase.
//! FFT round-off is the only tolerance, applied ONLY to the FFT-path convolution
//! comparisons; the Map blocks (gate, EQ) do no FFT and are checked tight/exact.
//!
//! Verified against zig 0.16.0; the `zig-0-16` skill was loaded before authoring
//! (Rule 13). Self-verify: exit code of the standalone `zig test` run is the only
//! truth (Rule 12) — a compile-dropped target still prints "X/X passed".

const std = @import("std");
const pan = @import("pan");

const f32num = pan.numericFor(.f32, .{});

// ---------------------------------------------------------------------------
// Local helpers — kept self-contained so this file imports only `pan` and can
// be compiled standalone (no harness module dependency).
// ---------------------------------------------------------------------------

const Sample = pan.Sample(f32);

fn fillNoise(comptime N: usize, seed: u64) [N]Sample {
    var s: [N]Sample = undefined;
    var rng = std.Random.DefaultPrng.init(seed);
    for (&s) |*o| o.ch[0] = rng.random().float(f32) * 2 - 1;
    return s;
}

/// Schoolbook linear convolution y[n] = Σ_m h[m]·x[n−m], the independent oracle
/// for every PartitionedConvolution comparison. Shares ONLY the definition of
/// convolution with the FFT path, not the algorithm.
fn naiveConv(comptime N: usize, x: []const f32, h: []const f32) [N]f32 {
    var y: [N]f32 = [_]f32{0} ** N;
    for (0..N) |n| {
        var acc: f32 = 0;
        for (0..h.len) |m| if (m <= n) {
            acc += h[m] * x[n - m];
        };
        y[n] = acc;
    }
    return y;
}

fn mag(re: f32, im: f32) f32 {
    return @sqrt(re * re + im * im);
}

// ===========================================================================
// PartitionedConvolution — Rate block, FFT overlap-add convolution.
// ===========================================================================

test "PartitionedConvolution: needed_input(want) == want (the 1:1 demand contract)" {
    // ORACLE: a rate-preserving (out:in = 1:1) block must demand exactly `want`
    // input samples for `want` outputs — independent of internal buffering. The
    // scheduler compiles this into upstream demand; a wrong value would starve or
    // over-pull. Checked across a `want` range incl. sub-HOP, exactly-HOP, and
    // multi-block.
    var conv = pan.PartitionedConvolution(f32num, 16, 8, 4){};
    for ([_]usize{ 0, 1, 7, 8, 9, 16, 100, 4096 }) |want| {
        try std.testing.expectEqual(want, conv.needed_input(want));
    }
}

test "PartitionedConvolution: classification re-derived (Rate, latency 0, ratio 1:1)" {
    // ORACLE: re-derive the classifier's own structural rule independently — a Rate
    // declares out_per_in + pull + algorithmic_latency; a Map would only have
    // `process`. We assert the decl surface directly rather than reuse port.zig.
    const Conv = pan.PartitionedConvolution(f32num, 16, 8, 4);
    try std.testing.expect(@hasDecl(Conv, "out_per_in"));
    try std.testing.expect(@hasDecl(Conv, "pull"));
    try std.testing.expect(@hasDecl(Conv, "algorithmic_latency"));
    try std.testing.expect(!@hasDecl(Conv, "process")); // not a Map
    try std.testing.expect(!@hasDecl(Conv, "rate_bounds")); // not a VariRate
    try std.testing.expectEqual(@as(usize, 0), Conv.algorithmic_latency);
    try std.testing.expectEqual(@as(usize, 1), Conv.out_per_in[0]);
    try std.testing.expectEqual(@as(usize, 1), Conv.out_per_in[1]);
}

test "PartitionedConvolution: UNSET IR convolves with silence (documented LIMIT)" {
    // ORACLE: the doc-comment states "an unset IR convolves with silence (all-zero
    // spectra ⇒ silent output)". With no initialize() call the IR spectra are all
    // zero, so EVERY output sample must be exactly 0 regardless of input. This pins
    // a surfaced limit, not an accident: a buggy default-unity IR would echo input.
    const FRAME = 16;
    const HOP = 8;
    const NP = 4;
    var conv = pan.PartitionedConvolution(f32num, FRAME, HOP, NP){};
    // deliberately NO conv.initialize(...)
    const N = 64;
    var in = fillNoise(N, 99);
    var out: [N]Sample = undefined;
    const got = conv.pull(&in, N, &out);
    try std.testing.expectEqual(@as(usize, N), got);
    for (out) |o| try std.testing.expectEqual(@as(f32, 0), o.ch[0]);
}

test "PartitionedConvolution: linearity — conv(a·x + b·y) = a·conv(x) + b·conv(y)" {
    // ORACLE: convolution is a LINEAR operator. Run the same (stateful) block on
    // x, on y, and on (a·x + b·y) from fresh state each time; the combined run must
    // equal the linear combination of the separate runs, sample-for-sample (up to
    // FFT round-off). This is an algebraic invariant the naive-conv test cannot see
    // — it would catch a stray nonlinearity / clipping / DC offset in the path.
    const FRAME = 32;
    const HOP = 8;
    const NP = 4;
    var ir: [20]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(7);
    for (&ir) |*h| h.* = rng.random().float(f32) * 2 - 1;

    const N = 96;
    var x = fillNoise(N, 1);
    var y = fillNoise(N, 2);
    const a: f32 = 1.7;
    const b: f32 = -0.4;

    var combined: [N]Sample = undefined;
    for (&combined, x, y) |*c, xv, yv| c.ch[0] = a * xv.ch[0] + b * yv.ch[0];

    var cx = pan.PartitionedConvolution(f32num, FRAME, HOP, NP){};
    cx.initialize(&ir);
    var ox: [N]Sample = undefined;
    _ = cx.pull(&x, N, &ox);

    var cy = pan.PartitionedConvolution(f32num, FRAME, HOP, NP){};
    cy.initialize(&ir);
    var oy: [N]Sample = undefined;
    _ = cy.pull(&y, N, &oy);

    var cc = pan.PartitionedConvolution(f32num, FRAME, HOP, NP){};
    cc.initialize(&ir);
    var oc: [N]Sample = undefined;
    _ = cc.pull(&combined, N, &oc);

    for (0..N) |n| {
        const expect = a * ox[n].ch[0] + b * oy[n].ch[0];
        try std.testing.expectApproxEqAbs(expect, oc[n].ch[0], 1e-3);
    }
}

test "PartitionedConvolution: a delayed-impulse IR (ir[k]=1) shifts the input by k" {
    // ORACLE: convolving with δ[n−k] is a pure k-sample delay (group delay lives in
    // the IR's taps, per the doc). With ir = {0,0,0,1} (k=3), out[n] must equal
    // in[n−3] (0 for n<3). The reference is the raw input shifted by 3 — independent
    // of the block. This pins the "a general IR's group delay is the IR's own"
    // clause that the unit-impulse (k=0) in-file test cannot.
    const FRAME = 16;
    const HOP = 8;
    const NP = 2;
    const K = 3;
    var ir = [_]f32{0} ** (K + 1);
    ir[K] = 1.0;

    var conv = pan.PartitionedConvolution(f32num, FRAME, HOP, NP){};
    conv.initialize(&ir);

    const N = 64;
    var in = fillNoise(N, 314);
    var out: [N]Sample = undefined;
    _ = conv.pull(&in, N, &out);

    for (0..N) |n| {
        const expect: f32 = if (n >= K) in[n - K].ch[0] else 0;
        try std.testing.expectApproxEqAbs(expect, out[n].ch[0], 1e-4);
    }
}

test "PartitionedConvolution: IR longer than n_partitions·HOP is truncated to budget" {
    // ORACLE: the doc states the IR holds "up to n_partitions·HOP taps" and "taps
    // past ir.len ... are silence" — and initialize only reads taps [0, NP·HOP).
    // So an over-length IR must behave EXACTLY as its first NP·HOP taps. Reference:
    // naive convolution with the TRUNCATED IR. A bug that wrapped or read past the
    // budget would diverge from this.
    const FRAME = 16;
    const HOP = 8;
    const NP = 2; // budget = 16 taps
    const budget = NP * HOP;
    const M = 30; // longer than budget
    var ir: [M]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(909);
    for (&ir) |*h| h.* = rng.random().float(f32) * 2 - 1;

    var conv = pan.PartitionedConvolution(f32num, FRAME, HOP, NP){};
    conv.initialize(&ir);

    const N = 96;
    var inS = fillNoise(N, 17);
    var x: [N]f32 = undefined;
    for (&x, inS) |*v, s| v.* = s.ch[0];
    var out: [N]Sample = undefined;
    _ = conv.pull(&inS, N, &out);

    const ref = naiveConv(N, &x, ir[0..budget]); // ONLY the first `budget` taps
    for (0..N) |n| try std.testing.expectApproxEqAbs(ref[n], out[n].ch[0], 1e-3);
}

test "PartitionedConvolution: sample-at-a-time pull equals whole-stream pull" {
    // ORACLE: the extreme HOP∤chunk case — feeding ONE sample per pull must produce
    // the identical stream to one whole-stream pull (the block's ring carries the
    // sub-HOP remainder across every call and drops nothing). Reference: the
    // whole-stream run of the same block. Bit-exact: same machine code, same state,
    // only the call granularity differs — no FFT-vs-time comparison here.
    const FRAME = 16;
    const HOP = 8;
    const NP = 3;
    var ir: [18]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(2024);
    for (&ir) |*h| h.* = rng.random().float(f32) * 2 - 1;

    const N = 80;
    var in = fillNoise(N, 5);

    var whole = pan.PartitionedConvolution(f32num, FRAME, HOP, NP){};
    whole.initialize(&ir);
    var out_whole: [N]Sample = undefined;
    _ = whole.pull(&in, N, &out_whole);

    var drip = pan.PartitionedConvolution(f32num, FRAME, HOP, NP){};
    drip.initialize(&ir);
    var out_drip: [N]Sample = undefined;
    var done: usize = 0;
    for (0..N) |i| {
        done += drip.pull(in[i .. i + 1], 1, out_drip[done..N]);
    }
    // Both run the same whole blocks; the flushed prefix must match bit-exactly.
    for (0..done) |n| try std.testing.expectEqual(out_whole[n].ch[0], out_drip[n].ch[0]);
}

test "PartitionedConvolution: state_size is declared and accounts for the rings" {
    // The Rate contract requires a declared state_size (the commit pass sizes the
    // node store from it). ORACLE: it must be at least the bytes the struct's own
    // ring buffers occupy (IR spectra + FDL + overlap + obuf), independently summed.
    const FRAME = 16;
    const HOP = 8;
    const NP = 4;
    const BINS = FRAME / 2 + 1;
    const C = std.math.Complex(f32);
    const Conv = pan.PartitionedConvolution(f32num, FRAME, HOP, NP);
    try std.testing.expect(@hasDecl(Conv, "state_size"));
    const min_ring_bytes = @sizeOf([NP][BINS]C) * 2 // ir_spec + fdl
    + @sizeOf([FRAME]f32) // overlap
    + @sizeOf([FRAME]f32); // obuf
    try std.testing.expect(Conv.state_size >= min_ring_bytes);
}

// ===========================================================================
// SpectralGate — Map over Spectrum(T,bins), per-bin magnitude noise gate.
// ===========================================================================

const Spec4 = pan.Spectrum(f32, 4);
const Spec3 = pan.Spectrum(f32, 3);

test "SpectralGate: classification re-derived (Map, has threshold param)" {
    // ORACLE: re-derive the classifier's rule — a Map has `process` and NO Rate
    // facts. Also assert the surfaced `threshold` parameter port exists.
    const Gate = pan.SpectralGate(f32num, 4);
    try std.testing.expect(@hasDecl(Gate, "process"));
    try std.testing.expect(!@hasDecl(Gate, "out_per_in"));
    try std.testing.expect(!@hasDecl(Gate, "pull"));
    try std.testing.expect(!@hasDecl(Gate, "rate_bounds"));
    try std.testing.expect(@hasDecl(Gate, "params"));
    try std.testing.expect(@hasField(@TypeOf(Gate.params), "threshold"));
    try std.testing.expect(Gate.params.threshold == pan.Scalar(f32));
}

test "SpectralGate: strict-below is zeroed, sign of components is irrelevant" {
    // ORACLE (independent, hand-classified): with threshold 5, the gate keeps a bin
    // iff |z| >= 5. We probe the boundary tightly and with NEGATIVE components to
    // prove magnitude (not raw component value) is the discriminant:
    //   |{-3,-4}| = 5      -> exactly at floor -> PASSES verbatim (incl. signs)
    //   |{4.9, 0}| = 4.9   -> just below       -> ZEROED
    //   |{0,-4.999}| ≈ 5⁻  -> just below       -> ZEROED
    //   |{0, 5.0001}|      -> just above       -> PASSES
    var gate = pan.SpectralGate(f32num, 4){};
    gate.setParam(0, 5.0);
    var in = [_]Spec4{.{ .bin = .{
        .{ .re = -3, .im = -4 },
        .{ .re = 4.9, .im = 0 },
        .{ .re = 0, .im = -4.999 },
        .{ .re = 0, .im = 5.0001 },
    } }};
    var out: [1]Spec4 = undefined;
    gate.process(&in, &out);

    // Bin 0: at threshold, passes verbatim with its negative signs intact.
    try std.testing.expectEqual(@as(f32, -3), out[0].bin[0].re);
    try std.testing.expectEqual(@as(f32, -4), out[0].bin[0].im);
    // Bins 1,2: strictly below -> zeroed.
    try std.testing.expectEqual(@as(f32, 0), out[0].bin[1].re);
    try std.testing.expectEqual(@as(f32, 0), out[0].bin[1].im);
    try std.testing.expectEqual(@as(f32, 0), out[0].bin[2].re);
    try std.testing.expectEqual(@as(f32, 0), out[0].bin[2].im);
    // Bin 3: above -> passes.
    try std.testing.expectApproxEqAbs(@as(f32, 5.0001), out[0].bin[3].im, 1e-6);
}

test "SpectralGate: a re-set threshold re-gates; a wrong param slot is a no-op" {
    // ORACLE: the held-per-call threshold is what setParam(0,·) writes; slot != 0
    // must NOT change it (the doc: "if (slot == 0) ..."). We gate the SAME frame at
    // two thresholds and confirm both the change and the slot-guard, hand-deciding
    // which bins survive each time. Bin magnitudes: 1.0, 10.0.
    var gate = pan.SpectralGate(f32num, 3){};
    const frame = Spec3{
        .bin = .{
            .{ .re = 1, .im = 0 }, // |z| = 1
            .{ .re = 6, .im = 8 }, // |z| = 10
            .{ .re = 0, .im = 0 }, // |z| = 0
        },
    };

    // threshold 5: bin0 (1) zeroed, bin1 (10) passes, bin2 (0) zeroed.
    gate.setParam(0, 5.0);
    var in1 = [_]Spec3{frame};
    var out1: [1]Spec3 = undefined;
    gate.process(&in1, &out1);
    try std.testing.expectEqual(@as(f32, 0), out1[0].bin[0].re);
    try std.testing.expectEqual(@as(f32, 6), out1[0].bin[1].re);
    try std.testing.expectEqual(@as(f32, 0), out1[0].bin[2].re);

    // A wrong slot must not touch the threshold: still 5, identical result.
    gate.setParam(7, 0.0);
    var in_ns = [_]Spec3{frame};
    var out_ns: [1]Spec3 = undefined;
    gate.process(&in_ns, &out_ns);
    try std.testing.expectEqual(@as(f32, 0), out_ns[0].bin[0].re);
    try std.testing.expectEqual(@as(f32, 6), out_ns[0].bin[1].re);

    // Lower threshold to 0.5: now bin0 (1) survives too.
    gate.setParam(0, 0.5);
    var in2 = [_]Spec3{frame};
    var out2: [1]Spec3 = undefined;
    gate.process(&in2, &out2);
    try std.testing.expectEqual(@as(f32, 1), out2[0].bin[0].re);
    try std.testing.expectEqual(@as(f32, 6), out2[0].bin[1].re);
    try std.testing.expectEqual(@as(f32, 0), out2[0].bin[2].re); // |0| still < 0.5
}

test "SpectralGate: processes a multi-frame batch, each frame gated independently" {
    // ORACLE: a Map over a stream must gate every frame in the slice, not just the
    // first, using one held threshold. We build 3 frames whose per-bin survival is
    // hand-decided at threshold 2, and compare each output frame to its expected.
    var gate = pan.SpectralGate(f32num, 3){};
    gate.setParam(0, 2.0);
    var in = [_]Spec3{
        .{ .bin = .{ .{ .re = 3, .im = 0 }, .{ .re = 1, .im = 0 }, .{ .re = 0, .im = 0 } } }, // pass,zero,zero
        .{ .bin = .{ .{ .re = 0, .im = 0 }, .{ .re = 2, .im = 0 }, .{ .re = 1.9, .im = 0 } } }, // zero,pass,zero
        .{ .bin = .{ .{ .re = 5, .im = 0 }, .{ .re = -5, .im = 0 }, .{ .re = 0, .im = -2.0 } } }, // pass,pass,pass
    };
    const expect = [_][3]f32{
        .{ 3, 0, 0 },
        .{ 0, 2, 0 },
        .{ 5, -5, 0 }, // bin2 re is 0 but im is -2 (passes)
    };
    const expect_im2 = [_]f32{ 0, 0, -2.0 };
    var out: [3]Spec3 = undefined;
    gate.process(&in, &out);
    for (0..3) |f| {
        for (0..3) |bn| try std.testing.expectEqual(expect[f][bn], out[f].bin[bn].re);
        try std.testing.expectEqual(expect_im2[f], out[f].bin[2].im);
    }
}

// ===========================================================================
// SpectralEq — Map over Spectrum(T,bins), per-bin real-gain EQ.
// ===========================================================================

test "SpectralEq: classification re-derived (Map, no params, settable curve)" {
    const Eq = pan.SpectralEq(f32num, 4);
    try std.testing.expect(@hasDecl(Eq, "process"));
    try std.testing.expect(@hasDecl(Eq, "initialize"));
    try std.testing.expect(!@hasDecl(Eq, "out_per_in"));
    try std.testing.expect(!@hasDecl(Eq, "pull"));
    try std.testing.expect(!@hasDecl(Eq, "rate_bounds"));
    // EQ exposes its curve via initialize(), not a control param port.
    try std.testing.expect(!@hasDecl(Eq, "params"));
}

test "SpectralEq: exact component-wise law incl. zero and NEGATIVE gains" {
    // ORACLE: the block's contract is out_bin = (re·g, im·g) component-wise. We pin
    // it exactly (these are plain float multiplies — NO FFT, so bit-exact, not
    // approx) across the interesting gains:
    //   g = 0   -> bin silenced
    //   g = 2   -> doubled
    //   g = -1  -> components negated (a π phase FLIP). NOTE: the doc bills the EQ
    //              "zero-phase / leaves phase untouched" — that holds only for
    //              g >= 0; a NEGATIVE real gain rotates phase by π. We pin the
    //              ACTUAL component-wise behaviour (the load-bearing contract) and
    //              record that the "phase untouched" wording is the non-negative
    //              case. This is a documentation nuance, NOT a code bug: a real
    //              multiply by a negative number is exactly a π rotation.
    //   g = 0.5 -> halved
    var eq = pan.SpectralEq(f32num, 4){};
    const g = [_]f32{ 0.0, 2.0, -1.0, 0.5 };
    eq.initialize(&g);
    var in = [_]Spec4{.{ .bin = .{
        .{ .re = 4, .im = -8 },
        .{ .re = 1.5, .im = 2.5 },
        .{ .re = 3, .im = -7 },
        .{ .re = -10, .im = 6 },
    } }};
    var out: [1]Spec4 = undefined;
    eq.process(&in, &out);
    for (0..4) |bn| {
        try std.testing.expectEqual(in[0].bin[bn].re * g[bn], out[0].bin[bn].re);
        try std.testing.expectEqual(in[0].bin[bn].im * g[bn], out[0].bin[bn].im);
    }
    // g=0 truly silences this bin.
    try std.testing.expectEqual(@as(f32, 0), out[0].bin[0].re);
    try std.testing.expectEqual(@as(f32, 0), out[0].bin[0].im);
    // g=-1 negates: a π phase flip, magnitude preserved.
    try std.testing.expectEqual(@as(f32, -3), out[0].bin[2].re);
    try std.testing.expectEqual(@as(f32, 7), out[0].bin[2].im);
}

test "SpectralEq: a non-negative gain preserves bin PHASE, scales magnitude by g" {
    // ORACLE: for g >= 0 the EQ is genuinely zero-phase. We verify the documented
    // claim directly: atan2(im,re) is unchanged and |out| = g·|in|, computed
    // independently from the input bins. (g=0 is excluded — phase of the zero
    // vector is undefined.)
    var eq = pan.SpectralEq(f32num, 4){};
    const g = [_]f32{ 0.25, 1.0, 3.0, 7.5 };
    eq.initialize(&g);
    var in = [_]Spec4{.{ .bin = .{
        .{ .re = 1, .im = 1 },
        .{ .re = -2, .im = 3 },
        .{ .re = 4, .im = -1 },
        .{ .re = -5, .im = -5 },
    } }};
    var out: [1]Spec4 = undefined;
    eq.process(&in, &out);
    for (0..4) |bn| {
        const z = in[0].bin[bn];
        const o = out[0].bin[bn];
        const phase_in = std.math.atan2(z.im, z.re);
        const phase_out = std.math.atan2(o.im, o.re);
        try std.testing.expectApproxEqAbs(phase_in, phase_out, 1e-6);
        try std.testing.expectApproxEqAbs(g[bn] * mag(z.re, z.im), mag(o.re, o.im), 1e-5);
    }
}

test "SpectralEq: composition is functorial — EQ(g1) then EQ(g2) == EQ(g1·g2)" {
    // ORACLE: real per-bin gains compose by multiplication. Cascading two EQs must
    // equal a single EQ whose curve is the element-wise product — a structural
    // (functorial) law independent of the block: it would catch any per-bin state
    // or order dependence. Bit-exact within float assoc tolerance.
    const g1 = [_]f32{ 2.0, 0.5, -1.0, 4.0 };
    const g2 = [_]f32{ 0.25, 3.0, 2.0, -0.5 };
    var prod: [4]f32 = undefined;
    for (&prod, g1, g2) |*p, a, b| p.* = a * b;

    var in = [_]Spec4{.{ .bin = .{
        .{ .re = 1.1, .im = -2.2 },
        .{ .re = 3.3, .im = 4.4 },
        .{ .re = -5.5, .im = 6.6 },
        .{ .re = 7.7, .im = -8.8 },
    } }};

    // Cascade: EQ(g1) -> EQ(g2).
    var e1 = pan.SpectralEq(f32num, 4){};
    e1.initialize(&g1);
    var e2 = pan.SpectralEq(f32num, 4){};
    e2.initialize(&g2);
    var mid: [1]Spec4 = undefined;
    var casc: [1]Spec4 = undefined;
    e1.process(&in, &mid);
    e2.process(&mid, &casc);

    // Single fused EQ with the product curve.
    var ep = pan.SpectralEq(f32num, 4){};
    ep.initialize(&prod);
    var fused: [1]Spec4 = undefined;
    ep.process(&in, &fused);

    for (0..4) |bn| {
        try std.testing.expectApproxEqAbs(fused[0].bin[bn].re, casc[0].bin[bn].re, 1e-5);
        try std.testing.expectApproxEqAbs(fused[0].bin[bn].im, casc[0].bin[bn].im, 1e-5);
    }
}

test "SpectralEq: processes a multi-frame batch with one held curve" {
    // ORACLE: a Map applies its curve to every frame in the slice. Reference is the
    // hand-multiplied (re·g, im·g) per frame, per bin.
    var eq = pan.SpectralEq(f32num, 3){};
    const g = [_]f32{ 2.0, 0.0, -3.0 };
    eq.initialize(&g);
    var in = [_]Spec3{
        .{ .bin = .{ .{ .re = 1, .im = 1 }, .{ .re = 9, .im = 9 }, .{ .re = 2, .im = -1 } } },
        .{ .bin = .{ .{ .re = -4, .im = 2 }, .{ .re = 1, .im = 1 }, .{ .re = 0, .im = 5 } } },
    };
    var out: [2]Spec3 = undefined;
    eq.process(&in, &out);
    for (0..2) |f| {
        for (0..3) |bn| {
            try std.testing.expectEqual(in[f].bin[bn].re * g[bn], out[f].bin[bn].re);
            try std.testing.expectEqual(in[f].bin[bn].im * g[bn], out[f].bin[bn].im);
        }
    }
}
