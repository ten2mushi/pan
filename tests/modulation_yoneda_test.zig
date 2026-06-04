//! modulation_yoneda_test — the INDEPENDENT-ORACLE ("tests as definition")
//! characterization of the Phase-11 modulation/control blocks in `src/gen.zig`
//! and `src/env.zig`: `gen.Lfo`, `env.Adsr`, `env.FeatureMap`.
//!
//! The Yoneda discipline: a block IS the totality of its observable morphisms,
//! so each block is pinned by ALL of them — its comptime class + output/param
//! element types, every waveform/segment shape, the silent and boundary inputs,
//! the persistent state carry ACROSS calls, the segment transitions that fall
//! mid-block, sub-block-split ≡ whole-block equality, determinism, and the
//! broadcast (every-lane-filled) storage contract the executor's poison guard
//! relies on.
//!
//! ORACLE DISCIPLINE (Rule 9, hermetic — no SciPy/librosa, no disk): every
//! numeric expectation is recomputed in-test by a DIRECT, NAIVE, INDEPENDENT
//! reimplementation of the doc-comment formula, sharing only the *definition*
//! with pan's block — never its loop/accumulation order. The LFO phase oracle
//! reaccumulates the recurrence independently and evaluates @sin itself; the
//! ADSR oracle runs a separate level state machine; the FeatureMap oracle
//! clamps in a different expression order. pan and the oracle agree only if
//! both independently arrive at the documented value.
//!
//! COMPARISON DISCIPLINE: pan-vs-pan facts (determinism, broadcast-uniformity,
//! split ≡ whole) are bit-exact (expectEqual). Oracle reconstructions of a
//! transcendental (sine) use expectApproxEqAbs with a stated tolerance; the
//! piecewise-linear shapes and the affine/clamp map are exact by construction.
//!
//! Reject diagnostics use std.debug.print (never std.log.err — the 0.16 test
//! runner counts logged errors and flips the suite to non-zero exit).
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14). Lfo/Adsr/FeatureMap are NON-generic plain struct types, so
//! they are named directly (no `(num)` instantiation); no @Type, no managed
//! ArrayList, all buffers are fixed comptime-sized arrays.

const std = @import("std");
const pan = @import("pan");

const S = pan.Scalar(f32);

// A pan-vs-pan bit-exact assertion that every lane of an emitted control block
// holds the SAME value (the documented broadcast: one control value per call,
// stored across the whole buffer so the executor's finite-check sees no
// undefined lane). Returns that single value.
fn expectBroadcast(out: []const S, what: []const u8) !f32 {
    const v = out[0].value;
    for (out, 0..) |o, i| {
        if (o.value != v) {
            std.debug.print("{s}: lane {d} = {d} differs from lane 0 = {d}\n", .{ what, i, o.value, v });
            return error.NotBroadcast;
        }
    }
    return v;
}

// ===========================================================================
// Comptime classification + element-type surface (the Yoneda "object identity"
// — a control block IS its class, its output element, and its param ports).
// These re-pin facts the blocks' own inline tests assert, here gathered so the
// EXTERNAL `pan` import surface (port.classify / MapOutPort / ParamPort) is the
// thing under test, not the in-file `@import("port.zig")`.
// ===========================================================================

test "classification: Lfo/Adsr/FeatureMap are all Map blocks" {
    try std.testing.expect(pan.port.classify(pan.gen.Lfo) == .Map);
    try std.testing.expect(pan.port.classify(pan.env.Adsr) == .Map);
    try std.testing.expect(pan.port.classify(pan.env.FeatureMap) == .Map);
}

test "classification: Lfo and Adsr are zero-sample-input sources; FeatureMap is not" {
    // Lfo and Adsr are path heads (generators) — no audio input port.
    try std.testing.expect(comptime pan.port.isSource(pan.gen.Lfo));
    try std.testing.expect(comptime pan.port.isSource(pan.env.Adsr));
    // FeatureMap is a 1:1 transform: it has an input, so it is NOT a source.
    try std.testing.expect(!comptime pan.port.isSource(pan.env.FeatureMap));
}

test "classification: every control block emits Scalar(f32)" {
    try std.testing.expect(pan.port.MapOutPort(pan.gen.Lfo).Elem == S);
    try std.testing.expect(pan.port.MapOutPort(pan.env.Adsr).Elem == S);
    try std.testing.expect(pan.port.MapOutPort(pan.env.FeatureMap).Elem == S);
}

test "classification: Adsr declares a gate parameter port of Scalar(f32)" {
    try std.testing.expect(pan.port.ParamPort(pan.env.Adsr, "gate").Elem == S);
}

// ===========================================================================
// Lfo — value = offset + amplitude · wave(phase); phase advances by
// out.len · increment per call, wrapping in [0, 1).
//
// The unit waveforms (range [-1, 1]):
//   sine     = sin(2π p)
//   triangle = p<0.5 ? 4p−1 : 3−4p
//   saw      = 2p−1
//   square   = p<0.5 ? +1 : −1
// ===========================================================================

// Independent unit-wave oracle: re-expresses each shape a different way than the
// block (sine via a separate @sin call; triangle as a distance-from-0.5 form;
// square via a sign test on (0.5 − p)), sharing only the documented definition.
fn waveOracle(wf: pan.gen.Waveform, p: f64) f64 {
    return switch (wf) {
        .sine => @sin(2.0 * std.math.pi * p),
        // triangle, re-derived: peak +1 at 0.5, −1 at the ends; the absolute
        // distance from 0.5 (max 0.5) scaled to a 2-unit fall. Equals 4p−1 /
        // 3−4p but computed through a different algebra.
        .triangle => 1.0 - 4.0 * @abs(p - 0.5),
        .saw => 2.0 * p - 1.0,
        .square => if ((0.5 - p) > 0.0) @as(f64, 1.0) else @as(f64, -1.0),
    };
}

// Independent phase-advance oracle: fractional part of phase + n·increment.
fn phaseOracle(phase: f64, increment: f64, n: usize) f64 {
    const raw = phase + increment * @as(f64, @floatFromInt(n));
    return raw - @floor(raw);
}

test "Lfo: sine at phase 0 emits exactly the offset (sin 0 = 0), broadcast" {
    var lfo: pan.gen.Lfo = .{ .increment = 0.0, .amplitude = 3, .offset = 7, .waveform = .sine };
    var out: [5]S = undefined;
    lfo.process(&out);
    const v = try expectBroadcast(&out, "Lfo sine@0");
    try std.testing.expectEqual(@as(f32, 7), v);
}

test "Lfo: zero amplitude collapses every waveform to the constant offset" {
    inline for (.{ pan.gen.Waveform.sine, .triangle, .saw, .square }) |wf| {
        var lfo: pan.gen.Lfo = .{ .increment = 0.13, .amplitude = 0, .offset = -2.5, .waveform = wf };
        var out: [3]S = undefined;
        // Advance through several blocks: amplitude 0 ⇒ output is offset always,
        // regardless of where the phase wandered.
        var k: usize = 0;
        while (k < 6) : (k += 1) {
            lfo.process(&out);
            const v = try expectBroadcast(&out, "Lfo amp0");
            try std.testing.expectEqual(@as(f32, -2.5), v);
        }
    }
}

test "Lfo: sine sweep matches the independent phase+sin oracle across many blocks" {
    // A non-trivial increment so the phase visits the whole circle and wraps.
    const inc: f64 = 0.077;
    const amp: f64 = 2.0;
    const off: f64 = 0.5;
    var lfo: pan.gen.Lfo = .{
        .increment = @floatCast(inc),
        .amplitude = @floatCast(amp),
        .offset = @floatCast(off),
        .waveform = .sine,
    };
    const N = 4; // out.len per block — also the per-block phase step multiplier
    var out: [N]S = undefined;

    var oracle_phase: f64 = 0; // an INDEPENDENT f64 phase accumulator
    var block: usize = 0;
    while (block < 40) : (block += 1) {
        const p_before: f64 = lfo.phase; // the block-start sampling point
        lfo.process(&out);
        const v = try expectBroadcast(&out, "Lfo sine sweep");
        // Value oracle reads the block-start phase (so the @sin comparison is in
        // the same phase domain — no f32-vs-f64 drift), sharing only the formula.
        const want = off + amp * waveOracle(.sine, p_before);
        try std.testing.expectApproxEqAbs(want, @as(f64, v), 1e-6);
        // Separately, pan's stored phase tracks the INDEPENDENT f64 recurrence
        // within f32 precision — the phase-advance law is its own assertion.
        oracle_phase = phaseOracle(oracle_phase, inc, N);
        try std.testing.expectApproxEqAbs(oracle_phase, @as(f64, lfo.phase), 1e-4);
        // The wrap invariant is total.
        try std.testing.expect(lfo.phase >= 0 and lfo.phase < 1);
    }
}

test "Lfo: triangle hits its documented landmark values (-1 at 0, +1 at 0.5, -1 at ~1)" {
    // increment chosen so successive block-start phases land exactly on the
    // landmark points: block size 1, increment 0.25 ⇒ phases 0, .25, .5, .75, 0…
    var lfo: pan.gen.Lfo = .{ .increment = 0.25, .amplitude = 1, .offset = 0, .waveform = .triangle };
    var out: [1]S = undefined;
    // phase 0 → −1
    lfo.process(&out);
    try std.testing.expectApproxEqAbs(@as(f32, -1), out[0].value, 1e-6);
    // phase .25 → 4·.25−1 = 0
    lfo.process(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].value, 1e-6);
    // phase .5 → +1
    lfo.process(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[0].value, 1e-6);
    // phase .75 → 3−4·.75 = 0
    lfo.process(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].value, 1e-6);
    // wrap back to phase 0 → −1
    lfo.process(&out);
    try std.testing.expectApproxEqAbs(@as(f32, -1), out[0].value, 1e-6);
}

test "Lfo: saw ramps linearly −1→+1 and matches the affine oracle" {
    // The phase recurrence is f32 in the block; to characterise the SAW VALUE
    // exactly (no wrap-boundary straddle between an f32 phase and an f64 oracle
    // phase) the oracle reads pan's own stored phase BEFORE each advance — it
    // shares the value definition `2p−1`, independent of the block's expression.
    var lfo: pan.gen.Lfo = .{ .increment = 0.1, .amplitude = 1, .offset = 0, .waveform = .saw };
    var out: [1]S = undefined;
    var k: usize = 0;
    while (k < 25) : (k += 1) {
        const p_before: f64 = lfo.phase; // block-start phase, the sampling point
        lfo.process(&out);
        const want = waveOracle(.saw, p_before); // 2p−1
        try std.testing.expectApproxEqAbs(want, @as(f64, out[0].value), 1e-6);
    }
}

test "Lfo: square is exactly +1 below phase 0.5 and exactly −1 at/above it" {
    var lfo: pan.gen.Lfo = .{ .increment = 0.1, .amplitude = 1, .offset = 0, .waveform = .square };
    var out: [2]S = undefined;
    var k: usize = 0;
    while (k < 30) : (k += 1) {
        const p_before: f64 = lfo.phase; // block-start phase (same f32 domain)
        lfo.process(&out);
        const v = try expectBroadcast(&out, "Lfo square");
        // Exact membership in {+1, −1}, never anything between.
        try std.testing.expect(v == 1 or v == -1);
        // The documented threshold: +1 strictly below 0.5, −1 at/above.
        const want: f32 = if (p_before < 0.5) 1 else -1;
        try std.testing.expectEqual(want, v);
    }
}

test "Lfo: amplitude/offset map the unit wave onto an arbitrary range" {
    // A classic cutoff sweep: offset = (hi+lo)/2, amplitude = (hi−lo)/2 puts the
    // sine output in [lo, hi]. Sample the extremes by landing phase on 0.25/0.75.
    const lo: f32 = 200;
    const hi: f32 = 2000;
    var lfo: pan.gen.Lfo = .{
        .increment = 0.25, // block size 1 ⇒ phases 0,.25,.5,.75,…
        .amplitude = (hi - lo) / 2.0,
        .offset = (hi + lo) / 2.0,
        .waveform = .sine,
    };
    var out: [1]S = undefined;
    lfo.process(&out); // phase 0: sin 0 = 0 → centre
    try std.testing.expectApproxEqAbs((hi + lo) / 2.0, out[0].value, 1e-3);
    lfo.process(&out); // phase .25: sin(π/2)=1 → hi
    try std.testing.expectApproxEqAbs(hi, out[0].value, 1e-3);
    lfo.process(&out); // phase .5: sin(π)=0 → centre
    try std.testing.expectApproxEqAbs((hi + lo) / 2.0, out[0].value, 1e-3);
    lfo.process(&out); // phase .75: sin(3π/2)=−1 → lo
    try std.testing.expectApproxEqAbs(lo, out[0].value, 1e-3);
}

test "Lfo: phase advance depends on out.len — a split render equals a whole render" {
    // The doc-comment: phase advances by out.len·increment, so a single 8-sample
    // block and two back-to-back 4-sample blocks must leave the SAME phase and
    // (for the trailing emission) the same value. This is the S6 granularity law
    // for a generator: chunking the time axis is invisible to phase.
    const inc: f32 = 0.031;

    var whole: pan.gen.Lfo = .{ .increment = inc, .amplitude = 1, .offset = 0, .waveform = .sine };
    var split: pan.gen.Lfo = .{ .increment = inc, .amplitude = 1, .offset = 0, .waveform = .sine };

    var ow: [8]S = undefined;
    var os: [8]S = undefined;
    // Whole: one 8-block.
    whole.process(&ow);
    // Split: 4 + 4 on a fresh instance.
    split.process(os[0..4]);
    const mid = split.phase; // phase after the first half
    split.process(os[4..8]);

    // The first 4 lanes of the whole block equal the block-start value (phase 0),
    // and the split's first half emits the identical value (also phase 0).
    try std.testing.expectEqual(ow[0].value, os[0].value);
    // After the whole 8-sample advance, phase == after the two 4-sample advances.
    try std.testing.expectEqual(whole.phase, split.phase);
    // And the mid phase is exactly the 4-sample advance, independently.
    try std.testing.expectApproxEqAbs(phaseOracle(0, inc, 4), @as(f64, mid), 1e-6);
}

test "Lfo: a zero-length block emits nothing and leaves phase untouched (no-op)" {
    var lfo: pan.gen.Lfo = .{ .increment = 0.2, .amplitude = 1, .offset = 0, .waveform = .sine };
    // Advance to a known non-zero phase first.
    var out: [3]S = undefined;
    lfo.process(&out);
    const before = lfo.phase;
    // Empty out slice: out.len == 0 ⇒ no lanes written, advance by 0·increment.
    var empty: [0]S = undefined;
    lfo.process(&empty);
    try std.testing.expectEqual(before, lfo.phase);
}

test "Lfo: identical configs are deterministic block-for-block (pan-vs-pan exact)" {
    var a: pan.gen.Lfo = .{ .increment = 0.019, .amplitude = 1.7, .offset = 0.3, .waveform = .triangle };
    var b: pan.gen.Lfo = .{ .increment = 0.019, .amplitude = 1.7, .offset = 0.3, .waveform = .triangle };
    var oa: [6]S = undefined;
    var ob: [6]S = undefined;
    var k: usize = 0;
    while (k < 50) : (k += 1) {
        a.process(&oa);
        b.process(&ob);
        for (oa, ob) |x, y| try std.testing.expectEqual(x.value, y.value);
        try std.testing.expectEqual(a.phase, b.phase);
    }
}

// ===========================================================================
// Adsr — gate→amplitude control source. process() emits the BLOCK-START level
// (broadcast), then integrates out.len samples internally. gate≥0.5 starts
// attack from idle/release; gate<0.5 starts release. Stages: idle, attack,
// decay, sustain, release. Increments are per-sample level deltas.
// ===========================================================================

// Independent ADSR oracle: a separate state machine over the documented stage
// rules, integrating sample by sample. Mirrors the *definition*, not pan's loop.
const OracleStage = enum { idle, attack, decay, sustain, release };
const OracleAdsr = struct {
    level: f64 = 0,
    stage: OracleStage = .idle,
    gate: f64 = 0,
    attack_inc: f64,
    decay_inc: f64,
    sustain: f64,
    release_inc: f64,

    fn applyGate(self: *OracleAdsr) void {
        if (self.gate >= 0.5) {
            if (self.stage == .idle or self.stage == .release) self.stage = .attack;
        } else {
            if (self.stage != .idle) self.stage = .release;
        }
    }
    fn step(self: *OracleAdsr) void {
        switch (self.stage) {
            .idle => {},
            .attack => {
                self.level += self.attack_inc;
                if (self.level >= 1.0) {
                    self.level = 1.0;
                    self.stage = .decay;
                }
            },
            .decay => {
                self.level -= self.decay_inc;
                if (self.level <= self.sustain) {
                    self.level = self.sustain;
                    self.stage = .sustain;
                }
            },
            .sustain => self.level = self.sustain,
            .release => {
                self.level -= self.release_inc;
                if (self.level <= 0.0) {
                    self.level = 0.0;
                    self.stage = .idle;
                }
            },
        }
    }
    // Emit the block-start level, then advance `n` samples — exactly the
    // documented process() contract, written independently.
    fn process(self: *OracleAdsr, n: usize) f64 {
        self.applyGate();
        const v = self.level;
        var i: usize = 0;
        while (i < n) : (i += 1) self.step();
        return v;
    }
};

test "Adsr: idle with no gate stays at level 0 forever (broadcast zeros)" {
    var env: pan.env.Adsr = .{ .attack_inc = 0.1, .decay_inc = 0.1, .sustain = 0.5, .release_inc = 0.1 };
    var out: [4]S = undefined;
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        env.process(&out);
        const v = try expectBroadcast(&out, "Adsr idle");
        try std.testing.expectEqual(@as(f32, 0), v);
        try std.testing.expect(env.stage == .idle);
    }
}

test "Adsr: full gate-on then gate-off trajectory matches the independent oracle" {
    // Block size 1 so every call advances exactly one sample, exposing each level.
    const A: f32 = 0.25;
    const D: f32 = 0.25;
    const SUS: f32 = 0.5;
    const R: f32 = 0.25;
    var env: pan.env.Adsr = .{ .attack_inc = A, .decay_inc = D, .sustain = SUS, .release_inc = R };
    var orc: OracleAdsr = .{ .attack_inc = A, .decay_inc = D, .sustain = SUS, .release_inc = R };
    var out: [1]S = undefined;

    // Gate on, run through attack → decay → sustain (held a while), then off.
    env.setParam(0, 1.0);
    orc.gate = 1.0;
    var k: usize = 0;
    while (k < 10) : (k += 1) {
        env.process(&out);
        const v = try expectBroadcast(&out, "Adsr held");
        try std.testing.expectApproxEqAbs(orc.process(1), @as(f64, v), 1e-6);
    }
    // Gate off → release down to idle.
    env.setParam(0, 0.0);
    orc.gate = 0.0;
    k = 0;
    while (k < 10) : (k += 1) {
        env.process(&out);
        const v = try expectBroadcast(&out, "Adsr released");
        try std.testing.expectApproxEqAbs(orc.process(1), @as(f64, v), 1e-6);
    }
    // Must have arrived at idle / level 0.
    try std.testing.expect(env.stage == .idle);
    try std.testing.expectEqual(@as(f32, 0), env.level);
}

test "Adsr: stages advance in the documented order idle→attack→decay→sustain→release→idle" {
    var env: pan.env.Adsr = .{ .attack_inc = 0.5, .decay_inc = 0.5, .sustain = 0.25, .release_inc = 0.5 };
    var out: [1]S = undefined;
    try std.testing.expect(env.stage == .idle);

    env.setParam(0, 1.0);
    // sample 0 emit 0 (idle→attack applied), level→0.5 (attack)
    env.process(&out);
    try std.testing.expect(env.stage == .attack);
    // emit 0.5, level→1.0 → decay
    env.process(&out);
    try std.testing.expect(env.stage == .decay);
    // emit 1.0, level→0.5 (still > sustain 0.25) stays decay
    env.process(&out);
    try std.testing.expect(env.stage == .decay);
    // emit 0.5, level→0.0 ≤ 0.25 ⇒ clamp to sustain → sustain
    env.process(&out);
    try std.testing.expect(env.stage == .sustain);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), env.level, 1e-6);

    env.setParam(0, 0.0);
    // emit 0.25, level→ −0.25 ≤ 0 ⇒ 0 → idle
    env.process(&out);
    try std.testing.expect(env.stage == .idle);
    try std.testing.expectEqual(@as(f32, 0), env.level);
}

test "Adsr: gate held high retriggers attack from idle (note-on edge from idle)" {
    var env: pan.env.Adsr = .{ .attack_inc = 0.3, .decay_inc = 0.3, .sustain = 0.4, .release_inc = 0.3 };
    var out: [1]S = undefined;
    // Gate is applied at the START of process, so the very first held call
    // transitions idle→attack BEFORE sampling — but the emitted level is still
    // the pre-attack level (0). The state, however, is now attack.
    env.setParam(0, 1.0);
    env.process(&out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
    try std.testing.expect(env.stage == .attack);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), env.level, 1e-6);
}

test "Adsr: a note-on during release retriggers attack from the CURRENT (non-zero) level" {
    // The doc-comment promises retrigger-from-current. Drive into release, leave
    // a partial level, then re-gate: attack must resume from that level, not 0.
    var env: pan.env.Adsr = .{ .attack_inc = 0.1, .decay_inc = 0.1, .sustain = 0.5, .release_inc = 0.1 };
    var orc: OracleAdsr = .{ .attack_inc = 0.1, .decay_inc = 0.1, .sustain = 0.5, .release_inc = 0.1 };
    var out: [1]S = undefined;

    // Hold, climb partway into the envelope (a few samples of attack).
    env.setParam(0, 1.0);
    orc.gate = 1.0;
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        env.process(&out);
        _ = orc.process(1);
    }
    // Release for two samples (level falls, stage = release, still non-zero).
    env.setParam(0, 0.0);
    orc.gate = 0.0;
    k = 0;
    while (k < 2) : (k += 1) {
        env.process(&out);
        _ = orc.process(1);
    }
    try std.testing.expect(env.stage == .release);
    const lvl_before = env.level;
    try std.testing.expect(lvl_before > 0); // genuinely mid-release, not zero

    // Re-gate: attack resumes from lvl_before, not from 0.
    env.setParam(0, 1.0);
    orc.gate = 1.0;
    env.process(&out);
    _ = orc.process(1);
    try std.testing.expect(env.stage == .attack);
    // Level rose by attack_inc from lvl_before (independent check).
    try std.testing.expectApproxEqAbs(@as(f64, lvl_before) + 0.1, @as(f64, env.level), 1e-6);
    // And tracks the oracle, which retriggers identically.
    try std.testing.expectApproxEqAbs(orc.level, @as(f64, env.level), 1e-6);
}

test "Adsr: a mid-block segment crossover lands at the right sample (block-size invariance)" {
    // The doc-comment: integration is per-sample internally, so a segment
    // boundary that falls inside a block is honoured. Render the SAME envelope
    // two ways — one big block vs many size-1 blocks — and require the emitted
    // block-start levels at the shared sample boundaries to match.
    const A: f32 = 0.2;
    const D: f32 = 0.15;
    const SUS: f32 = 0.3;
    const R: f32 = 0.2;

    // Reference: size-1 blocks, 12 samples, gate held the whole time.
    var ref: pan.env.Adsr = .{ .attack_inc = A, .decay_inc = D, .sustain = SUS, .release_inc = R };
    ref.setParam(0, 1.0);
    var ref_levels: [12]f32 = undefined;
    var out1: [1]S = undefined;
    for (&ref_levels) |*L| {
        ref.process(&out1);
        L.* = out1[0].value;
    }

    // Block-of-4 render: three 4-sample blocks. The block-START levels are
    // ref_levels[0], ref_levels[4], ref_levels[8] (the doc-comment says process
    // emits the level at sample 0 of the block then advances out.len).
    var blk: pan.env.Adsr = .{ .attack_inc = A, .decay_inc = D, .sustain = SUS, .release_inc = R };
    blk.setParam(0, 1.0);
    var out4: [4]S = undefined;
    blk.process(&out4);
    try std.testing.expectApproxEqAbs(ref_levels[0], try expectBroadcast(&out4, "blk0"), 1e-6);
    blk.process(&out4);
    try std.testing.expectApproxEqAbs(ref_levels[4], try expectBroadcast(&out4, "blk1"), 1e-6);
    blk.process(&out4);
    try std.testing.expectApproxEqAbs(ref_levels[8], try expectBroadcast(&out4, "blk2"), 1e-6);
    // Both arrive at the identical residual state (sustain reached, same level).
    try std.testing.expectApproxEqAbs(ref.level, blk.level, 1e-6);
    try std.testing.expect(ref.stage == blk.stage);
}

test "Adsr: split render equals whole render (S6 granularity for the envelope)" {
    // Any partition of the time axis must yield the same per-block-start emissions
    // and leave the state machine in the identical place. Gate held throughout.
    const A: f32 = 0.07;
    const D: f32 = 0.05;
    const SUS: f32 = 0.4;
    const R: f32 = 0.06;
    const N = 20;

    var whole: pan.env.Adsr = .{ .attack_inc = A, .decay_inc = D, .sustain = SUS, .release_inc = R };
    var split: pan.env.Adsr = .{ .attack_inc = A, .decay_inc = D, .sustain = SUS, .release_inc = R };
    whole.setParam(0, 1.0);
    split.setParam(0, 1.0);

    // Whole: one N-sample block. Its single emitted value is the level at sample 0.
    var ow: [N]S = undefined;
    whole.process(&ow);

    // Split: 5 | 7 | 8 on the fresh instance — only the FIRST sub-block's emission
    // corresponds to sample 0, so compare that, then compare residual state.
    var os: [N]S = undefined;
    split.process(os[0..5]);
    split.process(os[5..12]);
    split.process(os[12..N]);

    try std.testing.expectEqual(ow[0].value, os[0].value); // both = level at sample 0
    // After advancing N samples either way, state machine is identical.
    try std.testing.expectApproxEqAbs(whole.level, split.level, 1e-6);
    try std.testing.expect(whole.stage == split.stage);
}

test "Adsr: an immediate gate-off from idle is a no-op (release guard does not fire from idle)" {
    var env: pan.env.Adsr = .{ .attack_inc = 0.1, .decay_inc = 0.1, .sustain = 0.5, .release_inc = 0.1 };
    var out: [2]S = undefined;
    env.setParam(0, 0.0); // gate low while already idle
    env.process(&out);
    try std.testing.expect(env.stage == .idle); // stays idle, never enters release
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
}

test "Adsr: gate boundary at exactly 0.5 counts as held (>= 0.5)" {
    var env: pan.env.Adsr = .{ .attack_inc = 0.3, .decay_inc = 0.3, .sustain = 0.5, .release_inc = 0.3 };
    var out: [1]S = undefined;
    env.setParam(0, 0.5); // exactly the threshold
    env.process(&out);
    // 0.5 ≥ 0.5 ⇒ held ⇒ idle transitions to attack.
    try std.testing.expect(env.stage == .attack);

    // And just below the threshold from idle is NOT held.
    var env2: pan.env.Adsr = .{ .attack_inc = 0.3, .decay_inc = 0.3, .sustain = 0.5, .release_inc = 0.3 };
    env2.setParam(0, 0.49999);
    env2.process(&out);
    try std.testing.expect(env2.stage == .idle);
}

test "Adsr: setParam ignores out-of-range slots (only slot 0 is gate)" {
    var env: pan.env.Adsr = .{ .attack_inc = 0.3, .decay_inc = 0.3, .sustain = 0.5, .release_inc = 0.3 };
    var out: [1]S = undefined;
    env.setParam(1, 1.0); // not the gate slot ⇒ gate stays 0
    env.setParam(7, 1.0);
    env.process(&out);
    try std.testing.expect(env.stage == .idle); // gate never went high
    try std.testing.expectEqual(@as(f32, 0), env.gate);
}

test "Adsr: determinism — identical configs and gate histories agree bit-for-bit" {
    var a: pan.env.Adsr = .{ .attack_inc = 0.11, .decay_inc = 0.09, .sustain = 0.33, .release_inc = 0.07 };
    var b: pan.env.Adsr = .{ .attack_inc = 0.11, .decay_inc = 0.09, .sustain = 0.33, .release_inc = 0.07 };
    var oa: [3]S = undefined;
    var ob: [3]S = undefined;
    // Apply an identical gate schedule and compare every emission and the state.
    const gate_sched = [_]f32{ 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0 };
    for (gate_sched) |g| {
        a.setParam(0, g);
        b.setParam(0, g);
        a.process(&oa);
        b.process(&ob);
        for (oa, ob) |x, y| try std.testing.expectEqual(x.value, y.value);
        try std.testing.expectEqual(a.level, b.level);
        try std.testing.expect(a.stage == b.stage);
    }
}

// ===========================================================================
// FeatureMap — out = clamp(scale·in + bias, lo, hi). Rate 1:1, aliasing-safe.
// ===========================================================================

// Independent affine+clamp oracle, written in a different evaluation order
// (clamp expressed as two nested branches rather than std.math.clamp).
fn featureMapOracle(scale: f64, bias: f64, lo: f64, hi: f64, x: f64) f64 {
    var y = scale * x + bias;
    if (y < lo) y = lo;
    if (y > hi) y = hi;
    return y;
}

test "FeatureMap: declares aliasing_safe = true (the colorer may run it in place)" {
    try std.testing.expect(pan.env.FeatureMap.aliasing_safe);
}

test "FeatureMap: identity map (scale 1, bias 0, no clamp) passes values through" {
    var fm: pan.env.FeatureMap = .{};
    const in = [_]S{ .{ .value = -100 }, .{ .value = 0 }, .{ .value = 0.5 }, .{ .value = 1e9 } };
    var out: [4]S = undefined;
    fm.process(&in, &out);
    for (in, out) |x, o| try std.testing.expectEqual(x.value, o.value);
}

test "FeatureMap: affine rescale matches the independent oracle on a sweep" {
    var fm: pan.env.FeatureMap = .{ .scale = 1000, .bias = 200 }; // no clamp (±inf)
    var prng = std.Random.DefaultPrng.init(0xFEA12345);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 64) : (trial += 1) {
        const x = (rnd.float(f32) - 0.5) * 20.0;
        const in = [_]S{.{ .value = x }};
        var out: [1]S = undefined;
        fm.process(&in, &out);
        const want = featureMapOracle(1000, 200, -std.math.inf(f64), std.math.inf(f64), x);
        try std.testing.expectApproxEqAbs(want, @as(f64, out[0].value), 1e-3);
    }
}

test "FeatureMap: clamp pins values to [lo, hi] and passes interior through" {
    var fm: pan.env.FeatureMap = .{ .scale = 1, .bias = 0, .lo = 0, .hi = 5000 };
    const in = [_]S{
        .{ .value = -10 }, // below lo ⇒ lo
        .{ .value = 0 }, // exactly lo ⇒ lo
        .{ .value = 2500 }, // interior ⇒ itself
        .{ .value = 5000 }, // exactly hi ⇒ hi
        .{ .value = 9999 }, // above hi ⇒ hi
    };
    var out: [5]S = undefined;
    fm.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].value);
    try std.testing.expectEqual(@as(f32, 0), out[1].value);
    try std.testing.expectEqual(@as(f32, 2500), out[2].value);
    try std.testing.expectEqual(@as(f32, 5000), out[3].value);
    try std.testing.expectEqual(@as(f32, 5000), out[4].value);
}

test "FeatureMap: a negative scale inverts the mapping, clamp still bounds it" {
    var fm: pan.env.FeatureMap = .{ .scale = -2, .bias = 10, .lo = -5, .hi = 8 };
    const cases = [_]f32{ -10, 0, 1, 2, 5, 100 };
    for (cases) |x| {
        const in = [_]S{.{ .value = x }};
        var out: [1]S = undefined;
        fm.process(&in, &out);
        const want = featureMapOracle(-2, 10, -5, 8, x);
        try std.testing.expectApproxEqAbs(want, @as(f64, out[0].value), 1e-5);
    }
}

test "FeatureMap: 1:1 rate — a whole batch is mapped element-for-element" {
    var fm: pan.env.FeatureMap = .{ .scale = 3, .bias = -1, .lo = -100, .hi = 100 };
    var prng = std.Random.DefaultPrng.init(0xBA7C4);
    const rnd = prng.random();
    const N = 32;
    var in: [N]S = undefined;
    for (&in) |*e| e.* = .{ .value = (rnd.float(f32) - 0.5) * 80.0 };
    var out: [N]S = undefined;
    fm.process(&in, &out);
    for (in, out) |x, o| {
        const want = featureMapOracle(3, -1, -100, 100, x.value);
        try std.testing.expectApproxEqAbs(want, @as(f64, o.value), 1e-4);
    }
}

test "FeatureMap: in-place operation (out aliasing in) yields the same result (aliasing_safe)" {
    // aliasing_safe = true asserts a per-element write from only the matching
    // input element. Run the map IN PLACE (out == in slice) and require it equals
    // the out-of-place result — the contract the colorer relies on.
    const scale: f32 = 2.5;
    const bias: f32 = -3;
    const lo: f32 = -50;
    const hi: f32 = 50;

    var prng = std.Random.DefaultPrng.init(0xA11A5);
    const rnd = prng.random();
    const N = 16;

    var buf_inplace: [N]S = undefined;
    var buf_src: [N]S = undefined;
    for (0..N) |i| {
        const x: f32 = (rnd.float(f32) - 0.5) * 60.0;
        buf_inplace[i] = .{ .value = x };
        buf_src[i] = .{ .value = x };
    }

    var fm1: pan.env.FeatureMap = .{ .scale = scale, .bias = bias, .lo = lo, .hi = hi };
    var fm2: pan.env.FeatureMap = .{ .scale = scale, .bias = bias, .lo = lo, .hi = hi };

    // In place: in and out are the SAME slice.
    fm1.process(&buf_inplace, &buf_inplace);
    // Out of place reference.
    var out_ref: [N]S = undefined;
    fm2.process(&buf_src, &out_ref);

    for (buf_inplace, out_ref) |a, b| try std.testing.expectEqual(b.value, a.value);
}

test "FeatureMap: zero-length batch is a no-op (no writes, no crash)" {
    var fm: pan.env.FeatureMap = .{ .scale = 9, .bias = 9 };
    var empty_in: [0]S = undefined;
    var empty_out: [0]S = undefined;
    fm.process(&empty_in, &empty_out);
    // Reaching here without UB is the assertion.
    try std.testing.expect(true);
}

test "FeatureMap: clamp neutralizes a saturating feature (huge scale pinned to range)" {
    // A feature that blows up (e.g. a divide producing a huge value) must be
    // bounded by the clamp, never propagating an out-of-range parameter.
    var fm: pan.env.FeatureMap = .{ .scale = 1e30, .bias = 0, .lo = -1, .hi = 1 };
    const in = [_]S{ .{ .value = 1 }, .{ .value = -1 }, .{ .value = 0 } };
    var out: [3]S = undefined;
    fm.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 1), out[0].value); // huge ⇒ hi
    try std.testing.expectEqual(@as(f32, -1), out[1].value); // huge neg ⇒ lo
    try std.testing.expectEqual(@as(f32, 0), out[2].value); // 0·1e30 = 0 interior
}
