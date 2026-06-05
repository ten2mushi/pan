//! fx_dynamics_yoneda_test — the INDEPENDENT-ORACLE ("tests as definition") suite
//! for the four `src/fx.zig` shaping blocks the pre-existing `dynamics_yoneda_test`
//! does NOT touch: `Limiter`, `Expander`, `SoftClip`, `Trim`. (That sibling file is
//! the Phase-11 modulation/adaptive suite — it covers ONLY `Vca`, `Agc`,
//! `AgcController`, `PowerGate`; the four blocks here are entirely uncovered there,
//! so there is no overlap.)
//!
//! Yoneda discipline: a block is defined by its action under ALL observations, so
//! each is characterised by every morphism we can throw at it —
//!   - object identity: the port class + the control/data element types;
//!   - silence (the zero object) and DC (an eigen-input of the static curves);
//!   - sign symmetry (odd-symmetry of SoftClip; sign-preservation of every block);
//!   - the boundary cases of each piecewise law (exactly AT a threshold, just below,
//!     just above; drive = 1; gain_db = 0);
//!   - the per-sample envelope recurrence and its carry-over across calls (state);
//!   - the ordering law: a render split into sub-blocks equals the whole render
//!     (the only way the persistent envelope state can be observed);
//!   - the n = 1 edge (a single-sample block) and the empty block (n = 0);
//!   - determinism (same input twice → bit-identical output);
//!   - in-place aliasing ≡ non-aliased, the executable proof of `aliasing_safe`
//!     for the two stateless waveshapers (SoftClip, Trim).
//!
//! Oracle strategy (Rule 9, hermetic — no SciPy, no disk): every expectation is
//! recomputed in-test by a DIRECT, INDEPENDENT reimplementation of the documented
//! formula, sharing only the *definition* with pan's block, never its loop body.
//!   - The envelope one-pole `env += c·(|x|−env)` is iterated in a standalone helper
//!     so a state-carry bug in fx.zig cannot hide.
//!   - The cubic soft-clip `u−u³/3` is recomputed scalar-by-scalar (lane width 1),
//!     so a SIMD-kernel-vs-scalar-tail divergence in fx.zig would surface.
//!   - The dB→linear conversion `10^(dB/20)` is recomputed independently.
//!
//! COMPARISON DISCIPLINE:
//!   - pan-vs-pan (determinism; split==whole; in-place==copy) is BIT-EXACT
//!     (`expectEqual`): same f32 ops in the same order on both sides.
//!   - oracle checks that reproduce the SAME f32 ops in the SAME order the block uses
//!     are also expected bit-exact (`expectEqual`); where a transcendental
//!     (`pow`/`tan`) or a different summation order is unavoidable we drop to
//!     `expectApproxEqAbs` and say so at the call site.
//!
//! Reject diagnostics use std.debug.print, never std.log.err — the 0.16 test runner
//! counts logged errors and would flip the suite to a non-zero exit on a *passing*
//! run. Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring.
//! No @Type, no managed ArrayList; all buffers are fixed comptime arrays.

const std = @import("std");
const pan = @import("pan");
const testing = std.testing;

const Num = pan.numericFor(.f32, .{});

const Limiter = pan.fx.Limiter(Num);
const Expander = pan.fx.Expander(Num);
const SoftClip = pan.fx.SoftClip(Num);
const Trim = pan.fx.Trim(Num);

// `Sample(f32)` is `Frame(f32,.mono)` == `struct{ ch:[1]f32 }`.
fn S(x: f32) pan.Sample(f32) {
    return .{ .ch = .{x} };
}

// ===========================================================================
// Independent oracles — naive reimplementations of the doc-comment formulae.
// ===========================================================================

/// One-pole envelope follower, recomputed independently of fx.zig's `followEnvelope`.
/// rect = |x|; coefficient is `attack` when rising (rect > env) else `release`;
/// env' = env + c·(rect − env). Returns the NEW env.
fn envStep(env: f32, x: f32, attack: f32, release: f32) f32 {
    const rect = @abs(x);
    const c = if (rect > env) attack else release;
    return env + c * (rect - env);
}

/// The Limiter gain law, recomputed: pass at unity below the ceiling; clamp the
/// enveloped level to it above. gain = min(1, threshold/env), but only when the
/// threshold is positive AND the envelope has crossed it (the strict `>` matters).
fn limiterGain(env: f32, thr: f32) f32 {
    return if (env > thr and thr > 0) thr / env else 1.0;
}

/// The Expander gain law: unity at/above threshold; below it attenuate by
/// (env/threshold)^(ratio−1). Uses `pow` — a transcendental, so callers comparing
/// against this oracle must use a tolerance.
fn expanderGain(env: f32, thr: f32, ratio: f32) f32 {
    return if (env < thr and thr > 0 and ratio > 0)
        std.math.pow(f32, env / thr, ratio - 1.0)
    else
        1.0;
}

/// The memoryless cubic soft-clip, scalar (lane width 1), recomputed independently:
/// u = clamp(drive·x, −1, 1); y = (u − u³/3) / drive.
fn softClipScalar(x: f32, drive: f32) f32 {
    const u = std.math.clamp(x * drive, -1.0, 1.0);
    return (u - u * u * u * (1.0 / 3.0)) / drive;
}

// ===========================================================================
// Object identity — a block IS its class and its element type(s).
// ===========================================================================

test "fx_dynamics: classification + control/data element identity for the four blocks" {
    // All four are rate-1:1 process blocks → Map.
    try testing.expect(pan.port.classify(Limiter) == .Map);
    try testing.expect(pan.port.classify(Expander) == .Map);
    try testing.expect(pan.port.classify(SoftClip) == .Map);
    try testing.expect(pan.port.classify(Trim) == .Map);

    // Each consumes audio and emits audio (Sample, not Scalar) — none is a control
    // producer like AgcController.
    try testing.expect(pan.port.MapOutPort(Limiter).Elem == pan.Sample(f32));
    try testing.expect(pan.port.MapOutPort(Expander).Elem == pan.Sample(f32));
    try testing.expect(pan.port.MapOutPort(SoftClip).Elem == pan.Sample(f32));
    try testing.expect(pan.port.MapOutPort(Trim).Elem == pan.Sample(f32));

    // The dynamics processors expose dB-free control PORTS carrying Scalar(f32).
    try testing.expect(pan.port.ParamPort(Limiter, "threshold").Elem == pan.Scalar(f32));
    try testing.expect(pan.port.ParamPort(Limiter, "release").Elem == pan.Scalar(f32));
    try testing.expect(pan.port.ParamPort(Limiter, "attack").Elem == pan.Scalar(f32));
    try testing.expect(pan.port.ParamPort(Expander, "threshold").Elem == pan.Scalar(f32));
    try testing.expect(pan.port.ParamPort(Expander, "ratio").Elem == pan.Scalar(f32));

    // None of these is a Source (each reads an audio input).
    try testing.expect(!comptime pan.port.isSource(Limiter));
    try testing.expect(!comptime pan.port.isSource(Expander));
    try testing.expect(!comptime pan.port.isSource(SoftClip));
    try testing.expect(!comptime pan.port.isSource(Trim));

    // The two stateless waveshapers are declared in-place-safe; the two enveloped
    // dynamics blocks carry per-sample state, so they MUST NOT declare it.
    try testing.expect(@hasDecl(SoftClip, "aliasing_safe") and SoftClip.aliasing_safe);
    try testing.expect(@hasDecl(Trim, "aliasing_safe") and Trim.aliasing_safe);
    try testing.expect(!@hasDecl(Limiter, "aliasing_safe"));
    try testing.expect(!@hasDecl(Expander, "aliasing_safe"));
}

// ===========================================================================
// Limiter — y = x · min(1, threshold/env), env a one-pole peak follower.
// ===========================================================================

test "Limiter: silence stays exactly silent (zero object maps to zero)" {
    var lim: Limiter = .{ .threshold = pan.control.Param.init(0.5) };
    var in: [16]pan.Sample(f32) = @splat(S(0));
    var out: [16]pan.Sample(f32) = undefined;
    lim.process(&in, &out);
    for (out) |y| try testing.expectEqual(@as(f32, 0), y.ch[0]);
    // The envelope must also stay pinned at zero (|0| never exceeds 0).
    try testing.expectEqual(@as(f32, 0), lim.env);
}

test "Limiter: a quiet DC signal below the ceiling passes at unity (per-sample, bit-exact)" {
    // threshold 0.5, instant attack/release (=1) so the envelope == |x| every sample.
    var lim: Limiter = .{
        .threshold = pan.control.Param.init(0.5),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    const N = 12;
    var in: [N]pan.Sample(f32) = @splat(S(0.25)); // below 0.5
    var out: [N]pan.Sample(f32) = undefined;
    lim.process(&in, &out);

    // Recompute the SAME ops independently: env == 0.25 from sample 1 on, gain == 1.
    var env: f32 = 0;
    for (out) |y| {
        env = envStep(env, 0.25, 1.0, 1.0);
        const want = 0.25 * limiterGain(env, 0.5);
        try testing.expectEqual(want, y.ch[0]); // bit-exact: identical f32 op order
    }
    // Below the ceiling the gain is exactly 1, so the output equals the input.
    try testing.expectEqual(@as(f32, 0.25), out[N - 1].ch[0]);
}

test "Limiter: a hot DC signal is held at the ceiling once the envelope settles" {
    // Instant attack: env reaches |x|=1.0 on sample 0, gain = 0.5/1.0 = 0.5, y = 0.5.
    var lim: Limiter = .{
        .threshold = pan.control.Param.init(0.5),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    const N = 8;
    var in: [N]pan.Sample(f32) = @splat(S(1.0));
    var out: [N]pan.Sample(f32) = undefined;
    lim.process(&in, &out);
    var env: f32 = 0;
    for (out) |y| {
        env = envStep(env, 1.0, 1.0, 1.0);
        try testing.expectEqual(1.0 * limiterGain(env, 0.5), y.ch[0]);
    }
    // The held output sits AT the ceiling 0.5 (the enveloped level is clamped to it).
    try testing.expectEqual(@as(f32, 0.5), out[N - 1].ch[0]);
    try testing.expect(out[N - 1].ch[0] < 1.0); // genuinely limited
}

test "Limiter: env exactly AT threshold does NOT engage (strict >, gain stays unity)" {
    // |x| == threshold == 0.5: the law is `env > thr`, strict, so gain must be 1.
    var lim: Limiter = .{
        .threshold = pan.control.Param.init(0.5),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    var in: [4]pan.Sample(f32) = @splat(S(0.5));
    var out: [4]pan.Sample(f32) = undefined;
    lim.process(&in, &out);
    // env == 0.5 from sample 0; 0.5 is NOT > 0.5 ⇒ gain 1 ⇒ output unchanged.
    for (out) |y| try testing.expectEqual(@as(f32, 0.5), y.ch[0]);
}

test "Limiter: a zero/negative threshold disables limiting (the thr>0 guard)" {
    // With threshold 0, the `thr > 0` guard forces unity gain — the signal passes
    // untouched no matter how hot it is (a degenerate but defined configuration).
    var lim: Limiter = .{
        .threshold = pan.control.Param.init(0.0),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    var in: [6]pan.Sample(f32) = @splat(S(3.0));
    var out: [6]pan.Sample(f32) = undefined;
    lim.process(&in, &out);
    for (out) |y| try testing.expectEqual(@as(f32, 3.0), y.ch[0]);
}

test "Limiter: the slow-release envelope recurrence carries across calls (split == whole)" {
    // The ONLY way to observe the persistent envelope is to compare a whole render
    // against the same input split into two sub-blocks: the envelope state at the
    // seam must continue seamlessly.
    const cfg = .{
        .threshold = 0.4,
        .attack = 0.3,
        .release = 0.05, // genuinely slow so the seam matters
    };
    var whole: Limiter = .{
        .threshold = pan.control.Param.init(cfg.threshold),
        .attack = pan.control.Param.init(cfg.attack),
        .release = pan.control.Param.init(cfg.release),
    };
    var split: Limiter = .{
        .threshold = pan.control.Param.init(cfg.threshold),
        .attack = pan.control.Param.init(cfg.attack),
        .release = pan.control.Param.init(cfg.release),
    };
    const N = 20;
    var in: [N]pan.Sample(f32) = undefined;
    // A burst then decay so attack AND release both exercise.
    for (&in, 0..) |*s, i| s.* = S(if (i < 6) @as(f32, 0.9) else 0.05);

    var wout: [N]pan.Sample(f32) = undefined;
    whole.process(&in, &wout);

    var sout: [N]pan.Sample(f32) = undefined;
    split.process(in[0..7], sout[0..7]);
    split.process(in[7..], sout[7..]);

    for (wout, sout) |w, s| try testing.expectEqual(w.ch[0], s.ch[0]); // bit-exact seam
}

test "Limiter: a single-sample block (n=1) advances the envelope by exactly one step" {
    var lim: Limiter = .{
        .threshold = pan.control.Param.init(0.5),
        .attack = pan.control.Param.init(0.5),
        .release = pan.control.Param.init(0.1),
    };
    var in: [1]pan.Sample(f32) = .{S(1.0)};
    var out: [1]pan.Sample(f32) = undefined;
    lim.process(&in, &out);
    // env: 0 → 0 + 0.5·(1−0) = 0.5; 0.5 is not > 0.5 ⇒ gain 1 ⇒ y = 1.0.
    const env = envStep(0, 1.0, 0.5, 0.1);
    try testing.expectEqual(env, lim.env);
    try testing.expectEqual(1.0 * limiterGain(env, 0.5), out[0].ch[0]);
}

test "Limiter: an empty block (n=0) is a no-op and leaves the envelope untouched" {
    var lim: Limiter = .{ .env = 0.37 };
    var in: [0]pan.Sample(f32) = .{};
    var out: [0]pan.Sample(f32) = .{};
    lim.process(&in, &out);
    try testing.expectEqual(@as(f32, 0.37), lim.env); // unchanged
}

test "Limiter: determinism — same input through two fresh instances is bit-identical" {
    var a: Limiter = .{ .threshold = pan.control.Param.init(0.3), .release = pan.control.Param.init(0.07) };
    var b: Limiter = .{ .threshold = pan.control.Param.init(0.3), .release = pan.control.Param.init(0.07) };
    var in: [24]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = S(@sin(t * 0.7) * 1.5); // hot, sign-varying
    }
    var oa: [24]pan.Sample(f32) = undefined;
    var ob: [24]pan.Sample(f32) = undefined;
    a.process(&in, &oa);
    b.process(&in, &ob);
    for (oa, ob) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "Limiter: sign is preserved — the gain is non-negative, so y and x share a sign" {
    // gain = min(1, thr/env) with env=|x|≥0 and thr>0 ⇒ gain ∈ (0,1], so the output
    // is the input scaled by a positive factor: never a sign flip.
    var lim: Limiter = .{
        .threshold = pan.control.Param.init(0.2),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    var in: [8]pan.Sample(f32) = .{ S(-1), S(1), S(-0.5), S(0.5), S(-2), S(2), S(-0.1), S(0.1) };
    var out: [8]pan.Sample(f32) = undefined;
    lim.process(&in, &out);
    for (in, out) |x, y| {
        if (x.ch[0] == 0) {
            try testing.expectEqual(@as(f32, 0), y.ch[0]);
        } else {
            try testing.expect(std.math.sign(x.ch[0]) == std.math.sign(y.ch[0]));
            try testing.expect(@abs(y.ch[0]) <= @abs(x.ch[0]) + 1e-6); // never amplifies
        }
    }
}

// ===========================================================================
// Expander — unity at/above threshold; (env/thr)^(ratio−1) below it.
// ===========================================================================

test "Expander: silence maps to silence (x=0 → y=0 regardless of the gain law)" {
    var ex: Expander = .{};
    var in: [16]pan.Sample(f32) = @splat(S(0));
    var out: [16]pan.Sample(f32) = undefined;
    ex.process(&in, &out);
    for (out) |y| try testing.expectEqual(@as(f32, 0), y.ch[0]);
}

test "Expander: ratio == 1 is the identity (exponent 0 ⇒ unit gain everywhere)" {
    // With ratio 1 the law (env/thr)^(1−1) = (…)^0 = 1, so a quiet DC below threshold
    // must still pass at unity — the no-expansion fixpoint of the family.
    var ex: Expander = .{
        .threshold = pan.control.Param.init(0.5),
        .ratio = pan.control.Param.init(1.0),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    var in: [10]pan.Sample(f32) = @splat(S(0.1)); // below threshold
    var out: [10]pan.Sample(f32) = undefined;
    ex.process(&in, &out);
    // pow(anything, 0) == 1 exactly for the std impl; assert bit-exact identity.
    for (out) |y| try testing.expectEqual(@as(f32, 0.1), y.ch[0]);
}

test "Expander: a level at/above threshold passes at unity (the >= boundary)" {
    var ex: Expander = .{
        .threshold = pan.control.Param.init(0.3),
        .ratio = pan.control.Param.init(3.0),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    // |x| == 0.3 == threshold: the law is `env < thr` (strict), so AT threshold the
    // gain is unity. A hotter 0.6 is also unity.
    var in: [8]pan.Sample(f32) = .{ S(0.3), S(0.3), S(0.6), S(0.6), S(0.3), S(0.3), S(0.6), S(0.6) };
    var out: [8]pan.Sample(f32) = undefined;
    ex.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]); // unity at/above
}

test "Expander: a quiet level below threshold is attenuated by (env/thr)^(ratio-1)" {
    // threshold 0.5, ratio 2, instant env. |x|=0.1<0.5 ⇒ gain=(0.1/0.5)^(2-1)=0.2.
    var ex: Expander = .{
        .threshold = pan.control.Param.init(0.5),
        .ratio = pan.control.Param.init(2.0),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    const N = 12;
    var in: [N]pan.Sample(f32) = @splat(S(0.1));
    var out: [N]pan.Sample(f32) = undefined;
    ex.process(&in, &out);
    // Independent oracle (pow ⇒ tolerance). After settling env==0.1.
    const g = expanderGain(0.1, 0.5, 2.0); // == 0.2 analytically
    try testing.expectApproxEqAbs(@as(f32, 0.2), g, 1e-6);
    try testing.expectApproxEqAbs(0.1 * g, out[N - 1].ch[0], 1e-6);
    try testing.expect(out[N - 1].ch[0] < 0.1); // genuinely pushed down
}

test "Expander: a larger ratio attenuates quiet material harder (monotone in ratio)" {
    // Same quiet input through ratio 2 vs ratio 4: the steeper ratio must yield a
    // strictly smaller magnitude below threshold (the family's defining direction).
    const N = 8;
    var in: [N]pan.Sample(f32) = @splat(S(0.05)); // well below threshold
    var soft: Expander = .{
        .threshold = pan.control.Param.init(0.5),
        .ratio = pan.control.Param.init(2.0),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    var hard: Expander = .{
        .threshold = pan.control.Param.init(0.5),
        .ratio = pan.control.Param.init(4.0),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    var so: [N]pan.Sample(f32) = undefined;
    var ho: [N]pan.Sample(f32) = undefined;
    soft.process(&in, &so);
    hard.process(&in, &ho);
    try testing.expect(@abs(ho[N - 1].ch[0]) < @abs(so[N - 1].ch[0]));
}

test "Expander: a zero threshold disables expansion (the thr>0 guard ⇒ unity)" {
    var ex: Expander = .{
        .threshold = pan.control.Param.init(0.0),
        .ratio = pan.control.Param.init(8.0),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    var in: [6]pan.Sample(f32) = @splat(S(0.01));
    var out: [6]pan.Sample(f32) = undefined;
    ex.process(&in, &out);
    for (out) |y| try testing.expectEqual(@as(f32, 0.01), y.ch[0]);
}

test "Expander: the envelope recurrence carries across calls (split == whole, bit-exact)" {
    const mk = struct {
        fn f() Expander {
            return .{
                .threshold = pan.control.Param.init(0.4),
                .ratio = pan.control.Param.init(3.0),
                .attack = pan.control.Param.init(0.4),
                .release = pan.control.Param.init(0.06),
            };
        }
    }.f;
    var whole = mk();
    var split = mk();
    const N = 18;
    var in: [N]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(if (i < 5) @as(f32, 0.8) else 0.02);

    var wout: [N]pan.Sample(f32) = undefined;
    whole.process(&in, &wout);
    var sout: [N]pan.Sample(f32) = undefined;
    split.process(in[0..6], sout[0..6]);
    split.process(in[6..], sout[6..]);
    for (wout, sout) |w, s| try testing.expectEqual(w.ch[0], s.ch[0]);
}

test "Expander: sign is preserved — gain is non-negative below threshold" {
    var ex: Expander = .{
        .threshold = pan.control.Param.init(0.5),
        .ratio = pan.control.Param.init(3.0),
        .attack = pan.control.Param.init(1.0),
        .release = pan.control.Param.init(1.0),
    };
    var in: [6]pan.Sample(f32) = .{ S(-0.1), S(0.1), S(-0.2), S(0.2), S(-0.05), S(0.05) };
    var out: [6]pan.Sample(f32) = undefined;
    ex.process(&in, &out);
    for (in, out) |x, y| {
        try testing.expect(std.math.sign(x.ch[0]) == std.math.sign(y.ch[0]));
        try testing.expect(@abs(y.ch[0]) <= @abs(x.ch[0]) + 1e-6); // attenuates, never lifts
    }
}

// ===========================================================================
// SoftClip — memoryless cubic waveshaper, the only block here with no state.
// ===========================================================================

test "SoftClip: drive == 1 small-signal slope is unity (quiet signals pass ~transparently)" {
    // For |x| ≪ 1 the curve y = x − x³/3 has slope 1 at the origin; a tiny input
    // therefore passes essentially unchanged, with a cubic-order deviation only.
    var sc: SoftClip = .{ .drive = 1.0 };
    var in: [4]pan.Sample(f32) = .{ S(0.001), S(-0.001), S(0.01), S(-0.01) };
    var out: [4]pan.Sample(f32) = undefined;
    sc.process(&in, &out);
    for (in, out) |x, y| {
        try testing.expectEqual(softClipScalar(x.ch[0], 1.0), y.ch[0]); // bit-exact vs scalar oracle
        try testing.expectApproxEqAbs(x.ch[0], y.ch[0], 1e-6); // ~transparent
    }
}

test "SoftClip: odd symmetry — f(-x) == -f(x) for every input (bit-exact)" {
    var sc: SoftClip = .{ .drive = 2.0 };
    const probes = [_]f32{ 0.13, 0.5, 0.9, 1.7, 3.0 };
    inline for (probes) |p| {
        var inp: [2]pan.Sample(f32) = .{ S(p), S(-p) };
        var out: [2]pan.Sample(f32) = undefined;
        sc.process(&inp, &out);
        try testing.expectEqual(out[0].ch[0], -out[1].ch[0]); // exact odd symmetry
    }
}

test "SoftClip: a hot input saturates to the soft ceiling ±(2/3)/drive" {
    // Past the rails u = ±1, the curve flattens at u − u³/3 = ±2/3, scaled by 1/drive.
    const drives = [_]f32{ 1.0, 2.0, 4.0 };
    inline for (drives) |d| {
        var sc: SoftClip = .{ .drive = d };
        var inp: [2]pan.Sample(f32) = .{ S(100.0), S(-100.0) }; // far past the rails
        var out: [2]pan.Sample(f32) = undefined;
        sc.process(&inp, &out);
        const ceil = (2.0 / 3.0) / d;
        try testing.expectApproxEqAbs(ceil, out[0].ch[0], 1e-6);
        try testing.expectApproxEqAbs(-ceil, out[1].ch[0], 1e-6);
        // The output never exceeds that soft ceiling.
        try testing.expect(@abs(out[0].ch[0]) <= ceil + 1e-6);
    }
}

test "SoftClip: a higher drive lowers the ceiling and reduces level for a hot signal" {
    var lo: SoftClip = .{ .drive = 1.0 };
    var hi: SoftClip = .{ .drive = 4.0 };
    var inp: [1]pan.Sample(f32) = .{S(0.95)}; // hot but inside the rails for drive 1
    var olo: [1]pan.Sample(f32) = undefined;
    var ohi: [1]pan.Sample(f32) = undefined;
    lo.process(&inp, &olo);
    hi.process(&inp, &ohi);
    try testing.expect(@abs(ohi[0].ch[0]) < @abs(olo[0].ch[0])); // more saturation
}

test "SoftClip: the SIMD kernel equals the scalar oracle including a non-multiple-of-W tail" {
    // A length deliberately NOT a multiple of the SIMD width exercises BOTH the
    // vector body and the scalar tail; the doc-comment promises identical arithmetic.
    var sc: SoftClip = .{ .drive = 1.7 };
    const N = 4 * Num.W + 3; // never a clean multiple of W
    var in: [N]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i);
        s.* = S(@sin(t * 0.37) * 2.5); // sweeps through the rails
    }
    var out: [N]pan.Sample(f32) = undefined;
    sc.process(&in, &out);
    for (in, out) |x, y| {
        // SIMD body and scalar tail must each match the scalar reference. (We do not
        // require the SIMD lanes to be bit-identical to the scalar tail's f32 ops —
        // the multiply ORDER `u*u*u` is the same in both paths, so they agree here.)
        try testing.expectApproxEqAbs(softClipScalar(x.ch[0], 1.7), y.ch[0], 1e-6);
    }
}

test "SoftClip: in-place (aliased) == out-of-place (the executable proof of aliasing_safe)" {
    var sc_copy: SoftClip = .{ .drive = 2.3 };
    var sc_alias: SoftClip = .{ .drive = 2.3 };
    const N = 2 * Num.W + 5;
    var src: [N]pan.Sample(f32) = undefined;
    for (&src, 0..) |*s, i| s.* = S(@as(f32, @floatFromInt(@as(i32, @intCast(i)) - 7)) * 0.3);

    var copy_in = src;
    var copy_out: [N]pan.Sample(f32) = undefined;
    sc_copy.process(&copy_in, &copy_out);

    var alias_buf = src; // process in place: in and out are the SAME slice
    sc_alias.process(&alias_buf, &alias_buf);

    for (copy_out, alias_buf) |c, a| try testing.expectEqual(c.ch[0], a.ch[0]);
}

test "SoftClip: silence and an empty block are no-ops" {
    var sc: SoftClip = .{ .drive = 3.0 };
    var zin: [9]pan.Sample(f32) = @splat(S(0));
    var zout: [9]pan.Sample(f32) = undefined;
    sc.process(&zin, &zout);
    for (zout) |y| try testing.expectEqual(@as(f32, 0), y.ch[0]); // f(0) = 0

    var ein: [0]pan.Sample(f32) = .{};
    var eout: [0]pan.Sample(f32) = .{};
    sc.process(&ein, &eout); // must not trap
}

test "SoftClip: monotonic on the active region (a larger |x| gives a >= |y|)" {
    // The transfer curve is monotonically increasing on [−1,1], so a sorted ramp of
    // magnitudes (drive·x within the rails) must produce a sorted ramp of outputs.
    var sc: SoftClip = .{ .drive = 1.0 };
    const N = 16;
    var in: [N]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@as(f32, @floatFromInt(i)) / @as(f32, N)); // 0 .. ~1
    var out: [N]pan.Sample(f32) = undefined;
    sc.process(&in, &out);
    var k: usize = 1;
    while (k < N) : (k += 1) try testing.expect(out[k].ch[0] >= out[k - 1].ch[0]);
}

// ===========================================================================
// Trim — static dB gain, y = x · 10^(dB/20). The dB face of filters.Gain.
// ===========================================================================

test "Trim: gain_db == 0 is exactly unity (10^0 = 1 ⇒ a perfect pass-through)" {
    var tr: Trim = .{ .gain_db = 0 };
    var in: [7]pan.Sample(f32) = .{ S(1), S(-2), S(3), S(-4), S(5), S(0), S(0.5) };
    var out: [7]pan.Sample(f32) = undefined;
    tr.process(&in, &out);
    // 10^(0/20) == 1 exactly for the std pow; assert bit-identity.
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "Trim: +6 dB ≈ ×1.995 and -6 dB ≈ ×0.5012 (the dB→linear law)" {
    {
        var tr: Trim = .{ .gain_db = 6.0 };
        var in: [4]pan.Sample(f32) = @splat(S(1.0));
        var out: [4]pan.Sample(f32) = undefined;
        tr.process(&in, &out);
        const g = std.math.pow(f32, 10.0, 6.0 / 20.0);
        try testing.expectApproxEqAbs(@as(f32, 1.99526), g, 1e-4);
        for (out) |y| try testing.expectEqual(g, y.ch[0]); // bit-exact vs same pow op
    }
    {
        var tr: Trim = .{ .gain_db = -6.0 };
        var in: [4]pan.Sample(f32) = @splat(S(1.0));
        var out: [4]pan.Sample(f32) = undefined;
        tr.process(&in, &out);
        const g = std.math.pow(f32, 10.0, -6.0 / 20.0);
        try testing.expectApproxEqAbs(@as(f32, 0.50119), g, 1e-4);
        for (out) |y| try testing.expectEqual(g, y.ch[0]);
    }
}

test "Trim: -20 dB is exactly a factor of 0.1 (a round-number dB anchor)" {
    var tr: Trim = .{ .gain_db = -20.0 };
    var in: [3]pan.Sample(f32) = .{ S(1.0), S(2.0), S(-5.0) };
    var out: [3]pan.Sample(f32) = undefined;
    tr.process(&in, &out);
    const g = std.math.pow(f32, 10.0, -20.0 / 20.0); // == 0.1
    try testing.expectApproxEqAbs(@as(f32, 0.1), g, 1e-6);
    for (in, out) |x, y| try testing.expectApproxEqAbs(x.ch[0] * 0.1, y.ch[0], 1e-6);
}

test "Trim: the SIMD kernel equals the scalar reference including a non-multiple-of-W tail" {
    var tr: Trim = .{ .gain_db = 3.0 };
    const g = std.math.pow(f32, 10.0, 3.0 / 20.0);
    const N = 5 * Num.W + 2;
    var in: [N]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@as(f32, @floatFromInt(i)) - 11.0);
    var out: [N]pan.Sample(f32) = undefined;
    tr.process(&in, &out);
    // Same multiply on both sides ⇒ bit-exact across body and tail.
    for (in, out) |x, y| try testing.expectEqual(x.ch[0] * g, y.ch[0]);
}

test "Trim: in-place (aliased) == out-of-place (the executable proof of aliasing_safe)" {
    const N = 3 * Num.W + 1;
    var src: [N]pan.Sample(f32) = undefined;
    for (&src, 0..) |*s, i| s.* = S(@as(f32, @floatFromInt(i)) * 0.25 - 2.0);

    var tr_copy: Trim = .{ .gain_db = -9.0 };
    var tr_alias: Trim = .{ .gain_db = -9.0 };
    var copy_in = src;
    var copy_out: [N]pan.Sample(f32) = undefined;
    tr_copy.process(&copy_in, &copy_out);
    var alias_buf = src;
    tr_alias.process(&alias_buf, &alias_buf);
    for (copy_out, alias_buf) |c, a| try testing.expectEqual(c.ch[0], a.ch[0]);
}

test "Trim: silence stays silent and an empty block is a no-op" {
    var tr: Trim = .{ .gain_db = 12.0 }; // a big boost cannot lift zero
    var zin: [8]pan.Sample(f32) = @splat(S(0));
    var zout: [8]pan.Sample(f32) = undefined;
    tr.process(&zin, &zout);
    for (zout) |y| try testing.expectEqual(@as(f32, 0), y.ch[0]);

    var ein: [0]pan.Sample(f32) = .{};
    var eout: [0]pan.Sample(f32) = .{};
    tr.process(&ein, &eout);
}

test "Trim agrees with filters.Gain at the equivalent linear coefficient (the overlap is honest)" {
    // The doc-comment claims Trim is the dB face of filters.Gain: at gain_db = G the
    // two must produce the same output as Gain configured with coeff = 10^(G/20).
    const Gain = pan.filters.Gain(Num);
    const G_db: f32 = -4.5;
    const lin = std.math.pow(f32, 10.0, G_db / 20.0);

    var tr: Trim = .{ .gain_db = G_db };
    var gn = Gain{ .gain = lin };
    const N = 11;
    var in: [N]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@as(f32, @floatFromInt(i)) - 5.0);
    var to: [N]pan.Sample(f32) = undefined;
    var go: [N]pan.Sample(f32) = undefined;
    tr.process(&in, &to);
    gn.process(&in, &go);
    // Both multiply by the same linear coefficient; bit-exact.
    for (to, go) |t, g| try testing.expectEqual(t.ch[0], g.ch[0]);
}
