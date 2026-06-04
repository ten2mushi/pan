//! adaptive_yoneda_test — the INDEPENDENT-ORACLE ("tests as definition") suite for
//! the four adaptive-processor blocks in `src/fx.zig`: `Compressor`,
//! `CompressorController`, `Aec`, and `HowlSuppressor`. The Yoneda discipline: a
//! block is defined by its action under ALL observations, so each block is
//! characterised by every morphism we can probe — silence, DC, below/at/above the
//! threshold, envelope convergence, state carry-over across calls, the broadcast of
//! a control value, NLMS adaptation and its convergence, leakage boundedness,
//! classification + port-element identity, multi-input port arity, and determinism.
//!
//! Oracle strategy (Rule 9, hermetic — no SciPy, no disk): every expectation is
//! recomputed in-test by a DIRECT, INDEPENDENT reimplementation of the documented
//! formula, sharing only the DEFINITION with pan's block, never its loop or
//! accumulation order:
//!   - the compressor gain is recomputed via `std.math.exp2`/a log-domain grouping
//!     rather than pan's `std.math.pow(env/threshold, 1/ratio − 1)`, and also via a
//!     direct `pow` reference for the curve shape;
//!   - the one-pole envelope follower is re-derived sample by sample in f64;
//!   - the NLMS filter is reimplemented in f64 with the dot-products accumulated in
//!     DESCENDING index order (pan accumulates ascending), so the two agree only if
//!     both compute the documented recurrence.
//! For convergence (which has no closed form here) we assert STRUCTURAL properties:
//! late-block residual energy ≪ early-block, and the taps stay finite/bounded.
//! pan-vs-pan determinism checks use BIT-EXACT equality.
//!
//! Reject diagnostics, if any were added, would use std.debug.print (never
//! std.log.err — the 0.16 test runner counts logged errors and flips the suite to a
//! non-zero exit). No allocator is needed: every buffer is a fixed comptime array.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14): no @Type, no managed ArrayList, atomics-free, all state on the
//! stack-resident block structs.

const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

// `Sample(f32)` is `Frame(f32,.mono)` == `struct{ ch:[1]f32 }`; build/read mono.
fn S(x: f32) pan.Sample(f32) {
    return .{ .ch = .{x} };
}

// ===========================================================================
// Independent oracles (naive reimplementations; never share pan's loop order).
// ===========================================================================

/// The compressor gain curve, recomputed in a DIFFERENT grouping than pan's
/// `pow(env/threshold, 1/ratio − 1)`: here in the log2 domain,
/// gain = 2^((1/ratio − 1) · log2(env/threshold)). Mathematically identical, a
/// different float path — they agree only because the DEFINITION is the same.
/// Unity at or below threshold (and for degenerate non-positive params).
fn gainOracle(env: f32, threshold: f32, ratio: f32) f32 {
    if (env <= threshold or threshold <= 0 or ratio <= 0) return 1.0;
    const e: f64 = env;
    const t: f64 = threshold;
    const exponent: f64 = (1.0 / @as(f64, ratio)) - 1.0;
    const g = std.math.exp2(exponent * std.math.log2(e / t));
    return @floatCast(g);
}

/// The one-pole envelope follower, re-derived in f64: rise toward |x| at `attack`,
/// fall at `release`. Returns the envelope AFTER absorbing `x`.
fn followOracle(env: f64, x: f64, attack: f64, release: f64) f64 {
    const rect = @abs(x);
    const c: f64 = if (rect > env) attack else release;
    return env + c * (rect - env);
}

/// Run the envelope follower across a whole block, returning the final envelope.
fn envAfterBlock(env0: f64, xs: []const f32, attack: f64, release: f64) f64 {
    var env = env0;
    for (xs) |x| env = followOracle(env, x, attack, release);
    return env;
}

/// An INDEPENDENT NLMS adaptive FIR, reimplemented in f64 with the two dot-products
/// (yhat and the reference energy) accumulated in DESCENDING index order — the
/// opposite of pan's ascending loop. `leak == 0` is a plain NLMS (the `Aec` rule);
/// `leak > 0` is the leaky `HowlSuppressor` rule `w := (1−leak)·w + step`.
/// Mutates `w`/`xhist` in place and returns the per-sample error.
fn nlmsStep(
    comptime taps: usize,
    w: *[taps]f64,
    xhist: *[taps]f64,
    d: f64,
    x: f64,
    mu: f64,
    eps: f64,
    leak: f64,
) f64 {
    // Shift newest sample into index 0.
    var k: usize = taps - 1;
    while (k > 0) : (k -= 1) xhist[k] = xhist[k - 1];
    xhist[0] = x;
    // Dot-products, DESCENDING (pan goes ascending) — order-independent definition.
    var yhat: f64 = 0;
    var norm: f64 = eps;
    var j: usize = taps;
    while (j > 0) {
        j -= 1;
        yhat += w[j] * xhist[j];
        norm += xhist[j] * xhist[j];
    }
    const err = d - yhat;
    const g = mu * err / norm;
    const keep = 1.0 - leak;
    for (w, xhist) |*wk, xk| wk.* = keep * wk.* + g * xk;
    return err;
}

// ===========================================================================
// Object identity — a block IS its class and its port elements (Yoneda: the
// classifier + element types are the first morphisms we observe).
// ===========================================================================

test "adaptive: Compressor/CompressorController are Map blocks with the right out element" {
    const Comp = pan.fx.Compressor(Num);
    const Ctrl = pan.fx.CompressorController(Num);

    try expect(pan.port.classify(Comp) == .Map);
    try expect(pan.port.classify(Ctrl) == .Map);

    // The fused compressor maps audio→audio; the controller maps audio→control.
    try expect(pan.port.MapOutPort(Comp).Elem == pan.Sample(f32));
    try expect(pan.port.MapOutPort(Ctrl).Elem == pan.Scalar(f32));

    // Neither is a Source: both READ audio.
    try expect(!comptime pan.port.isSource(Comp));
    try expect(!comptime pan.port.isSource(Ctrl));
}

test "adaptive: Aec/HowlSuppressor are TWO-input Map blocks (mic/primary + ref → audio)" {
    const A = pan.fx.Aec(Num, 8);
    const H = pan.fx.HowlSuppressor(Num, 8);

    try expect(pan.port.classify(A) == .Map);
    try expect(pan.port.classify(H) == .Map);

    // Two sample inputs each: (mic, ref) and (primary, ref).
    try expectEqual(@as(comptime_int, 2), pan.port.mapInputCount(A));
    try expectEqual(@as(comptime_int, 2), pan.port.mapInputCount(H));

    // Both input ports carry audio; both output ports carry audio.
    try expect(pan.port.MapInPortAt(A, 0).Elem == pan.Sample(f32));
    try expect(pan.port.MapInPortAt(A, 1).Elem == pan.Sample(f32));
    try expect(pan.port.MapOutPort(A).Elem == pan.Sample(f32));
    try expect(pan.port.MapInPortAt(H, 0).Elem == pan.Sample(f32));
    try expect(pan.port.MapInPortAt(H, 1).Elem == pan.Sample(f32));
    try expect(pan.port.MapOutPort(H).Elem == pan.Sample(f32));
}

// ===========================================================================
// Compressor — fused: per-sample env=follow(env,|x|); gain=curve(env)·makeup; y=x·gain.
// ===========================================================================

test "adaptive: Compressor passes a sub-threshold signal at unity (gain==1 below threshold)" {
    // Instant attack/release so the envelope equals |x| each sample; a steady 0.25
    // never exceeds threshold 0.5, so every gain is exactly unity → pure pass-through.
    var comp = pan.fx.Compressor(Num){ .threshold = 0.5, .ratio = 4.0, .attack = 1.0, .release = 1.0 };
    var in: [16]pan.Sample(f32) = @splat(S(0.25));
    var out: [16]pan.Sample(f32) = undefined;
    comp.process(&in, &out);
    for (out) |s| try expectEqual(@as(f32, 0.25), s.ch[0]);
    // env settled exactly to 0.25 (≤ threshold).
    try expectApproxEqAbs(@as(f32, 0.25), comp.env, 1e-6);
}

test "adaptive: Compressor silence is exactly silent and leaves the envelope at zero" {
    var comp = pan.fx.Compressor(Num){};
    var in: [32]pan.Sample(f32) = @splat(S(0));
    var out: [32]pan.Sample(f32) = undefined;
    comp.process(&in, &out);
    for (out) |s| try expectEqual(@as(f32, 0), s.ch[0]);
    try expectEqual(@as(f32, 0), comp.env);
}

test "adaptive: Compressor attenuates a hot DC block to the independent gain-curve value" {
    // Steady 1.0 above threshold 0.5: with instant env, env==1.0 each sample, so
    // gain == (1/0.5)^(1/4 − 1) = 2^(−0.75). The oracle recomputes that gain in the
    // log2 domain; output == x·gain·makeup.
    var comp = pan.fx.Compressor(Num){ .threshold = 0.5, .ratio = 4.0, .attack = 1.0, .release = 1.0, .makeup = 1.0 };
    var in: [16]pan.Sample(f32) = @splat(S(1.0));
    var out: [16]pan.Sample(f32) = undefined;
    comp.process(&in, &out);

    const g = gainOracle(1.0, 0.5, 4.0); // ≈ 0.5946
    for (out) |s| try expectApproxEqAbs(@as(f32, 1.0) * g, s.ch[0], 1e-5);
    for (out) |s| try expect(s.ch[0] < 1.0); // genuinely attenuated
    // Cross-check the oracle against the textbook value 2^(−0.75).
    try expectApproxEqAbs(std.math.pow(f32, 2.0, -0.75), g, 1e-6);
}

test "adaptive: Compressor makeup gain scales the whole output linearly" {
    // Same hot block, makeup 2.0 → output == x·gain·2. Probes that makeup multiplies
    // the curve gain (not the envelope or the threshold).
    var comp = pan.fx.Compressor(Num){ .threshold = 0.5, .ratio = 4.0, .attack = 1.0, .release = 1.0, .makeup = 2.0 };
    var in: [8]pan.Sample(f32) = @splat(S(1.0));
    var out: [8]pan.Sample(f32) = undefined;
    comp.process(&in, &out);
    const g = gainOracle(1.0, 0.5, 4.0);
    for (out) |s| try expectApproxEqAbs(@as(f32, 1.0) * g * 2.0, s.ch[0], 1e-5);
}

test "adaptive: Compressor ratio==1 is a no-op curve even above threshold (unity gain)" {
    // ratio 1 ⇒ exponent 1/1 − 1 = 0 ⇒ gain (env/threshold)^0 == 1 everywhere. The
    // compressor with ratio 1 is a pass-through regardless of level.
    var comp = pan.fx.Compressor(Num){ .threshold = 0.5, .ratio = 1.0, .attack = 1.0, .release = 1.0 };
    var in: [8]pan.Sample(f32) = @splat(S(0.9));
    var out: [8]pan.Sample(f32) = undefined;
    comp.process(&in, &out);
    for (out) |s| try expectApproxEqAbs(@as(f32, 0.9), s.ch[0], 1e-6);
}

test "adaptive: Compressor envelope follower matches the re-derived one-pole, sample by sample" {
    // A real attack/release (not instant) so the envelope LAGS the signal. We feed a
    // varying block and require pan's per-sample output to equal x·curve(env)·makeup
    // where env is the INDEPENDENTLY iterated one-pole. The whole point: the gain is
    // driven by the persistent, lagging envelope, not by the instantaneous |x|.
    const attack: f32 = 0.25;
    const release: f32 = 0.03;
    const threshold: f32 = 0.5;
    const ratio: f32 = 4.0;
    var comp = pan.fx.Compressor(Num){ .threshold = threshold, .ratio = ratio, .attack = attack, .release = release };

    var xs: [24]f32 = undefined;
    for (&xs, 0..) |*x, i| x.* = 0.8 * @sin(0.6 * @as(f32, @floatFromInt(i))) + 0.2;
    var in: [24]pan.Sample(f32) = undefined;
    for (&in, xs) |*s, x| s.* = S(x);
    var out: [24]pan.Sample(f32) = undefined;
    comp.process(&in, &out);

    // Independently iterate env and apply the curve oracle.
    var env: f64 = 0;
    for (xs, out) |x, y| {
        env = followOracle(env, x, attack, release);
        const g = gainOracle(@floatCast(env), threshold, ratio);
        try expectApproxEqAbs(x * g, y.ch[0], 2e-5);
    }
    // pan's persistent env must equal the oracle's final env.
    try expectApproxEqAbs(@as(f32, @floatCast(env)), comp.env, 2e-5);
}

test "adaptive: Compressor carries the envelope across calls (slow release rings down)" {
    // Block 1: a hot burst charges the envelope. Block 2: silence. With a SLOW release
    // the envelope (and thus the gain reduction) must persist into block 2 — i.e. the
    // state survives the call boundary. We track env independently across both blocks.
    const attack: f32 = 0.5;
    const release: f32 = 0.02;
    var comp = pan.fx.Compressor(Num){ .threshold = 0.3, .ratio = 4.0, .attack = attack, .release = release };

    var hot: [16]f32 = @splat(1.0);
    var in1: [16]pan.Sample(f32) = undefined;
    for (&in1, hot) |*s, x| s.* = S(x);
    var out1: [16]pan.Sample(f32) = undefined;
    comp.process(&in1, &out1);
    const env1 = envAfterBlock(0, &hot, attack, release);
    try expectApproxEqAbs(@as(f32, @floatCast(env1)), comp.env, 1e-5);
    try expect(env1 > 0.3); // above threshold → reduction is active

    // Block 2: silence; env must NOT instantly reset (slow release).
    var sil: [16]f32 = @splat(0.0);
    var in2: [16]pan.Sample(f32) = @splat(S(0));
    var out2: [16]pan.Sample(f32) = undefined;
    comp.process(&in2, &out2);
    const env2 = envAfterBlock(env1, &sil, attack, release);
    try expectApproxEqAbs(@as(f32, @floatCast(env2)), comp.env, 1e-5);
    // It decayed but is still well above zero — proof the state carried over.
    try expect(env2 > 0.1 and env2 < env1);
    // Output of block 2 is silence times whatever gain (silence in → silence out).
    for (out2) |s| try expectEqual(@as(f32, 0), s.ch[0]);
}

test "adaptive: Compressor at a level exactly AT threshold is unity (boundary: env<=threshold)" {
    // The gain curve uses `env <= threshold → unity`, so a DC block whose settled
    // envelope equals the threshold EXACTLY must pass at unity. With instant attack
    // and a DC level equal to threshold, env == threshold to the bit.
    const lvl: f32 = 0.5;
    var comp = pan.fx.Compressor(Num){ .threshold = lvl, .ratio = 4.0, .attack = 1.0, .release = 1.0 };
    var in: [8]pan.Sample(f32) = @splat(S(lvl));
    var out: [8]pan.Sample(f32) = undefined;
    comp.process(&in, &out);
    for (out) |s| try expectEqual(@as(f32, lvl), s.ch[0]); // env==threshold → unity → identity
}

test "adaptive: Compressor determinism — two instances, identical input, bit-identical output" {
    var in: [40]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@sin(@as(f32, @floatFromInt(i)) * 0.3));
    var a = pan.fx.Compressor(Num){};
    var b = pan.fx.Compressor(Num){};
    var oa: [40]pan.Sample(f32) = undefined;
    var ob: [40]pan.Sample(f32) = undefined;
    a.process(&in, &oa);
    b.process(&in, &ob);
    for (oa, ob) |x, y| try expectEqual(x.ch[0], y.ch[0]);
    try expectEqual(a.env, b.env);
}

// ===========================================================================
// CompressorController — decoupled: same env + curve, but emits the BLOCK-END gain
// (one control value, broadcast to every out lane) instead of applying it.
// ===========================================================================

test "adaptive: CompressorController emits unity below threshold, broadcast to all lanes" {
    var c = pan.fx.CompressorController(Num){ .threshold = 0.5, .ratio = 4.0, .attack = 1.0, .release = 1.0 };
    var in: [16]pan.Sample(f32) = @splat(S(0.25)); // below threshold
    var out: [16]pan.Scalar(f32) = undefined;
    c.process(&in, &out);
    for (out) |o| try expectApproxEqAbs(@as(f32, 1.0), o.value, 1e-6);
    // Every lane carries the SAME value (it is a single block-end broadcast).
    for (out) |o| try expectEqual(out[0].value, o.value);
}

test "adaptive: CompressorController emits the block-end curve gain above threshold" {
    // The published value is the gain at the END of the block (the env after the last
    // sample), not a per-sample value. With instant env on a steady hot block the
    // block-end env == 1.0, so the gain == oracle(1.0, .5, 4).
    var c = pan.fx.CompressorController(Num){ .threshold = 0.5, .ratio = 4.0, .attack = 1.0, .release = 1.0, .makeup = 1.0 };
    var in: [16]pan.Sample(f32) = @splat(S(1.0));
    var out: [16]pan.Scalar(f32) = undefined;
    c.process(&in, &out);
    const g = gainOracle(1.0, 0.5, 4.0);
    for (out) |o| try expectApproxEqAbs(g, o.value, 1e-5);
    try expectApproxEqAbs(@as(f32, 1.0), c.env, 1e-6); // env tracked the hot DC
}

test "adaptive: CompressorController publishes the gain at the env AFTER the last sample" {
    // A ramped-in block with a real attack: the env at the LAST sample is what gets
    // published, even though earlier samples were below threshold. We compute the
    // block-end env independently and the gain from it, and require the broadcast to
    // match — this is the morphism that distinguishes the controller from the fused
    // applier (which would multiply each sample by its own per-sample gain).
    const attack: f32 = 0.4;
    const release: f32 = 0.05;
    const threshold: f32 = 0.4;
    const ratio: f32 = 3.0;
    const makeup: f32 = 1.25;
    var c = pan.fx.CompressorController(Num){ .threshold = threshold, .ratio = ratio, .attack = attack, .release = release, .makeup = makeup };

    var xs: [20]f32 = undefined;
    for (&xs, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i)) / 19.0; // 0 → 1 ramp
    var in: [20]pan.Sample(f32) = undefined;
    for (&in, xs) |*s, x| s.* = S(x);
    var out: [20]pan.Scalar(f32) = undefined;
    c.process(&in, &out);

    const env_end = envAfterBlock(0, &xs, attack, release);
    const g = gainOracle(@floatCast(env_end), threshold, ratio) * makeup;
    for (out) |o| try expectApproxEqAbs(g, o.value, 2e-5);
    try expectApproxEqAbs(@as(f32, @floatCast(env_end)), c.env, 2e-5);
}

test "adaptive: CompressorController carries the envelope across blocks (convergence)" {
    // The persistent env links the published gains across calls. We feed the SAME hot
    // block repeatedly; with a partial attack the env (and thus the published gain)
    // converges monotonically toward the steady-state curve value. We track env in
    // f64 across all blocks and require pan's published value to match each block.
    const attack: f32 = 0.2;
    const release: f32 = 0.05;
    const threshold: f32 = 0.5;
    const ratio: f32 = 4.0;
    var c = pan.fx.CompressorController(Num){ .threshold = threshold, .ratio = ratio, .attack = attack, .release = release };

    var xs: [8]f32 = @splat(1.0);
    var in: [8]pan.Sample(f32) = @splat(S(1.0));
    var out: [8]pan.Scalar(f32) = undefined;
    var env: f64 = 0;
    var prev_gain: f32 = 2.0; // start above any possible gain (≤1)
    var blk: usize = 0;
    while (blk < 12) : (blk += 1) {
        c.process(&in, &out);
        env = envAfterBlock(env, &xs, attack, release);
        const g = gainOracle(@floatCast(env), threshold, ratio);
        for (out) |o| try expectApproxEqAbs(g, o.value, 2e-5);
        // env rises toward 1.0, so gain (which is ≤1 and decreasing in env above
        // threshold) decreases monotonically toward the steady value.
        try expect(out[0].value <= prev_gain + 1e-6);
        prev_gain = out[0].value;
    }
    // After many blocks the env has essentially reached 1.0 → published gain ≈
    // 2^(−0.75), the steady curve value at env==1.0, threshold .5, ratio 4.
    try expectApproxEqAbs(std.math.pow(f32, 2.0, -0.75), prev_gain, 1e-3);
}

test "adaptive: CompressorController silence holds the published gain at unity" {
    var c = pan.fx.CompressorController(Num){};
    var in: [8]pan.Sample(f32) = @splat(S(0));
    var out: [8]pan.Scalar(f32) = undefined;
    c.process(&in, &out);
    for (out) |o| try expectEqual(@as(f32, 1.0), o.value); // env stays 0 ≤ threshold → unity
    try expectEqual(@as(f32, 0), c.env);
}

test "adaptive: CompressorController determinism across two instances" {
    var in: [24]pan.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(0.7 * @sin(@as(f32, @floatFromInt(i)) * 0.4));
    var a = pan.fx.CompressorController(Num){};
    var b = pan.fx.CompressorController(Num){};
    var oa: [24]pan.Scalar(f32) = undefined;
    var ob: [24]pan.Scalar(f32) = undefined;
    a.process(&in, &oa);
    b.process(&in, &ob);
    for (oa, ob) |x, y| try expectEqual(x.value, y.value);
    try expectEqual(a.env, b.env);
}

// ===========================================================================
// Aec — fused NLMS adaptive FIR: per sample shift ref into xhist, yhat=Σw·xhist,
// err=mic−yhat, w += mu·err·xhist/(Σxhist²+eps), out=err. Converges.
// ===========================================================================

test "adaptive: Aec with mu==0 is a transparent pass-through (mic → out, taps frozen)" {
    // No adaptation (mu 0) ⇒ taps stay zero ⇒ yhat 0 ⇒ err == mic. The Aec degenerates
    // to a wire from the mic to the output regardless of the reference.
    var aec = pan.fx.Aec(Num, 4){ .mu = 0.0 };
    var mic: [16]pan.Sample(f32) = undefined;
    var ref: [16]pan.Sample(f32) = undefined;
    for (0..16) |i| {
        mic[i] = S(@sin(@as(f32, @floatFromInt(i))));
        ref[i] = S(@cos(@as(f32, @floatFromInt(i)) * 0.5)); // arbitrary, must be ignored
    }
    var out: [16]pan.Sample(f32) = undefined;
    aec.process(&mic, &ref, &out);
    for (mic, out) |m, e| try expectEqual(m.ch[0], e.ch[0]);
    for (aec.w) |wk| try expectEqual(@as(f32, 0), wk); // taps never moved
}

test "adaptive: Aec first-block error equals the independent f64 NLMS, sample by sample" {
    // From zero taps, run one block of pan AND the descending-accumulation f64 oracle
    // on the SAME (mic, ref) and require equal per-sample error. This pins the exact
    // recurrence — the shift order (newest at 0), the use of the PRE-update taps for
    // yhat, and the post-yhat tap update with the current history.
    const taps = 6;
    var aec = pan.fx.Aec(Num, taps){ .mu = 0.5, .eps = 1e-6 };
    var mic: [20]pan.Sample(f32) = undefined;
    var ref: [20]pan.Sample(f32) = undefined;
    var micx: [20]f32 = undefined;
    var refx: [20]f32 = undefined;
    for (0..20) |i| {
        const t: f32 = @floatFromInt(i);
        refx[i] = 0.5 * @sin(0.7 * t) + 0.4 * @sin(1.3 * t);
        micx[i] = 0.3 * @sin(0.9 * t + 0.2); // some unrelated near-end + would-be echo
        mic[i] = S(micx[i]);
        ref[i] = S(refx[i]);
    }
    var out: [20]pan.Sample(f32) = undefined;
    aec.process(&mic, &ref, &out);

    var w: [taps]f64 = @splat(0);
    var xh: [taps]f64 = @splat(0);
    for (0..20) |i| {
        const e = nlmsStep(taps, &w, &xh, micx[i], refx[i], 0.5, 1e-6, 0.0);
        try expectApproxEqAbs(@as(f32, @floatCast(e)), out[i].ch[0], 1e-5);
    }
    // The pan taps must agree with the oracle taps too (state, not just output).
    for (aec.w, w) |pw, ow| try expectApproxEqAbs(@as(f32, @floatCast(ow)), pw, 1e-5);
}

test "adaptive: Aec silence in both channels stays silent and leaves taps at zero" {
    // mic==ref==0 ⇒ err 0, and the normalized step is 0·anything/eps = 0, so taps
    // never move. The eps floor is exactly what keeps the silent denominator finite.
    var aec = pan.fx.Aec(Num, 8){ .mu = 0.5 };
    var z: [32]pan.Sample(f32) = @splat(S(0));
    var out: [32]pan.Sample(f32) = undefined;
    aec.process(&z, &z, &out);
    for (out) |e| try expectEqual(@as(f32, 0), e.ch[0]);
    for (aec.w) |wk| try expectEqual(@as(f32, 0), wk);
    for (aec.xhist) |xk| try expectEqual(@as(f32, 0), xk);
}

test "adaptive: Aec converges — a reference-derived echo in the mic is progressively cancelled" {
    // The defining behaviour: the mic is purely a delayed, scaled copy of the ref
    // (desired near-end == 0). A perfect canceller drives the error to 0, so the
    // residual energy per block must fall sharply as the taps adapt. We assert the
    // STRUCTURAL property (late ≪ early) rather than an exact value.
    const taps = 8;
    var aec = pan.fx.Aec(Num, taps){ .mu = 0.5 };
    var ref_prev = [_]f32{0} ** 3;
    var first_energy: f32 = 0;
    var last_energy: f32 = 0;
    var nidx: usize = 0;
    const blocks = 300;
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        var mic: [16]pan.Sample(f32) = undefined;
        var ref: [16]pan.Sample(f32) = undefined;
        for (0..16) |i| {
            const t: f32 = @floatFromInt(nidx);
            const x = 0.5 * @sin(0.7 * t) + 0.5 * @sin(1.9 * t + 0.4);
            nidx += 1;
            ref[i] = S(x);
            // echo = ref delayed by 3, scaled 0.6.
            mic[i] = S(0.6 * ref_prev[2]);
            ref_prev[2] = ref_prev[1];
            ref_prev[1] = ref_prev[0];
            ref_prev[0] = x;
        }
        var out: [16]pan.Sample(f32) = undefined;
        aec.process(&mic, &ref, &out);
        var energy: f32 = 0;
        for (out) |e| energy += e.ch[0] * e.ch[0];
        if (b == 0) first_energy = energy;
        if (b == blocks - 1) last_energy = energy;
    }
    try expect(last_energy < first_energy * 0.05); // ≥ ~13 dB of cancellation
    // The taps converged to finite values (no divergence).
    for (aec.w) |wk| try expect(std.math.isFinite(wk));
}

test "adaptive: Aec carries adaptation state across calls (block split == one long stream)" {
    // Feeding one 32-sample stream as a single block must give the SAME taps/output as
    // feeding it as two 16-sample blocks — the adaptation has no per-call reset. We run
    // both and compare the final taps and the second-half output bit-for-bit.
    const taps = 5;
    var micx: [32]f32 = undefined;
    var refx: [32]f32 = undefined;
    for (0..32) |i| {
        const t: f32 = @floatFromInt(i);
        refx[i] = 0.4 * @sin(0.8 * t) + 0.3 * @cos(1.7 * t);
        micx[i] = 0.5 * refx[i]; // a pure echo to exercise real adaptation
    }
    var mic: [32]pan.Sample(f32) = undefined;
    var ref: [32]pan.Sample(f32) = undefined;
    for (0..32) |i| {
        mic[i] = S(micx[i]);
        ref[i] = S(refx[i]);
    }

    var one = pan.fx.Aec(Num, taps){ .mu = 0.5 };
    var out_one: [32]pan.Sample(f32) = undefined;
    one.process(&mic, &ref, &out_one);

    var split = pan.fx.Aec(Num, taps){ .mu = 0.5 };
    var out_a: [16]pan.Sample(f32) = undefined;
    var out_b: [16]pan.Sample(f32) = undefined;
    split.process(mic[0..16], ref[0..16], &out_a);
    split.process(mic[16..32], ref[16..32], &out_b);

    for (out_one[16..32], out_b) |x, y| try expectEqual(x.ch[0], y.ch[0]);
    for (one.w, split.w) |a, c| try expectEqual(a, c);
    for (one.xhist, split.xhist) |a, c| try expectEqual(a, c);
}

test "adaptive: Aec determinism — two instances, identical input, bit-identical output and taps" {
    const taps = 7;
    var mic: [48]pan.Sample(f32) = undefined;
    var ref: [48]pan.Sample(f32) = undefined;
    for (0..48) |i| {
        const t: f32 = @floatFromInt(i);
        mic[i] = S(0.3 * @sin(1.1 * t));
        ref[i] = S(0.6 * @sin(0.5 * t + 0.3));
    }
    var a = pan.fx.Aec(Num, taps){ .mu = 0.5 };
    var b = pan.fx.Aec(Num, taps){ .mu = 0.5 };
    var oa: [48]pan.Sample(f32) = undefined;
    var ob: [48]pan.Sample(f32) = undefined;
    a.process(&mic, &ref, &oa);
    b.process(&mic, &ref, &ob);
    for (oa, ob) |x, y| try expectEqual(x.ch[0], y.ch[0]);
    for (a.w, b.w) |x, y| try expectEqual(x, y);
}

// ===========================================================================
// HowlSuppressor — leaky NLMS: identical to Aec but w := (1−leak)·w + step.
// Leakage keeps the taps bounded; structurally it still suppresses correlated
// feedback. leak==0 must reduce EXACTLY to the plain-NLMS Aec.
// ===========================================================================

test "adaptive: HowlSuppressor with leak==0 reduces exactly to plain NLMS (Aec identity)" {
    // The only structural difference from Aec is the leak. With leak 0 the keep factor
    // is 1, so the update is identical — the two blocks must produce bit-identical
    // output and taps on the same input. This pins the leak as the ONLY distinction.
    const taps = 6;
    var mic: [40]pan.Sample(f32) = undefined;
    var ref: [40]pan.Sample(f32) = undefined;
    for (0..40) |i| {
        const t: f32 = @floatFromInt(i);
        mic[i] = S(0.4 * @sin(0.9 * t + 0.1));
        ref[i] = S(0.5 * @sin(0.6 * t));
    }
    var aec = pan.fx.Aec(Num, taps){ .mu = 0.5, .eps = 1e-6 };
    var hs = pan.fx.HowlSuppressor(Num, taps){ .mu = 0.5, .eps = 1e-6, .leak = 0.0 };
    var oa: [40]pan.Sample(f32) = undefined;
    var oh: [40]pan.Sample(f32) = undefined;
    aec.process(&mic, &ref, &oa);
    hs.process(&mic, &ref, &oh);
    for (oa, oh) |x, y| try expectEqual(x.ch[0], y.ch[0]);
    for (aec.w, hs.w) |x, y| try expectEqual(x, y);
}

test "adaptive: HowlSuppressor first-block error equals the leaky f64 NLMS oracle" {
    // Pin the leaky recurrence: pan vs the f64 oracle with `leak > 0` (keep = 1−leak),
    // per sample. The descending-accumulation oracle agrees only if the documented
    // leaky update is what pan computes.
    const taps = 5;
    const leak: f32 = 1e-2; // exaggerated so the leakage term is clearly exercised
    var hs = pan.fx.HowlSuppressor(Num, taps){ .mu = 0.5, .eps = 1e-6, .leak = leak };
    var micx: [24]f32 = undefined;
    var refx: [24]f32 = undefined;
    for (0..24) |i| {
        const t: f32 = @floatFromInt(i);
        refx[i] = 0.5 * @sin(0.7 * t) + 0.3 * @sin(1.5 * t);
        micx[i] = 0.4 * @sin(0.4 * t + 0.5);
    }
    var mic: [24]pan.Sample(f32) = undefined;
    var ref: [24]pan.Sample(f32) = undefined;
    for (0..24) |i| {
        mic[i] = S(micx[i]);
        ref[i] = S(refx[i]);
    }
    var out: [24]pan.Sample(f32) = undefined;
    hs.process(&mic, &ref, &out);

    var w: [taps]f64 = @splat(0);
    var xh: [taps]f64 = @splat(0);
    for (0..24) |i| {
        const e = nlmsStep(taps, &w, &xh, micx[i], refx[i], 0.5, 1e-6, leak);
        try expectApproxEqAbs(@as(f32, @floatCast(e)), out[i].ch[0], 1e-5);
    }
    for (hs.w, w) |pw, ow| try expectApproxEqAbs(@as(f32, @floatCast(ow)), pw, 1e-5);
}

test "adaptive: HowlSuppressor converges on correlated feedback yet keeps taps bounded" {
    // Closed-loop-style feedback: primary == ref delayed/scaled (correlated). The leaky
    // canceller suppresses it (late residual ≪ early) but the leakage caps the taps —
    // they stay finite and small, which is the runaway-prevention property.
    const taps = 8;
    var hs = pan.fx.HowlSuppressor(Num, taps){ .mu = 0.5, .leak = 1e-3 };
    var ref_prev: f32 = 0;
    var first_energy: f32 = 0;
    var last_energy: f32 = 0;
    var nidx: usize = 0;
    const blocks = 300;
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        var primary: [16]pan.Sample(f32) = undefined;
        var ref: [16]pan.Sample(f32) = undefined;
        for (0..16) |i| {
            const t: f32 = @floatFromInt(nidx);
            const x = 0.5 * @sin(0.7 * t) + 0.5 * @sin(1.9 * t + 0.4);
            nidx += 1;
            ref[i] = S(x);
            primary[i] = S(0.7 * ref_prev); // feedback: ref delayed 1, scaled 0.7
            ref_prev = x;
        }
        var out: [16]pan.Sample(f32) = undefined;
        hs.process(&primary, &ref, &out);
        var energy: f32 = 0;
        for (out) |e| energy += e.ch[0] * e.ch[0];
        if (b == 0) first_energy = energy;
        if (b == blocks - 1) last_energy = energy;
    }
    try expect(last_energy < first_energy * 0.1); // suppressed (leakage caps depth)
    var wmax: f32 = 0;
    for (hs.w) |wk| wmax = @max(wmax, @abs(wk));
    try expect(wmax < 10.0 and std.math.isFinite(wmax));
}

test "adaptive: HowlSuppressor leakage decays the taps toward zero when the reference goes silent" {
    // The leakage's signature: once the taps are charged (with active ref) and the
    // reference then goes SILENT, the taps shrink. There are two regimes during the
    // silent run: while the carried-over history still holds old ref samples a real
    // NLMS step still fires (err = −yhat with w ≠ 0), and only once the history is
    // fully flushed of the old reference (after `taps` silent samples) is the update
    // pure leakage `w := (1−leak)·w` — a clean geometric decay. A plain NLMS (leak 0)
    // would instead FREEZE the taps under silence. We replay BOTH the charge and the
    // silent run through the independent f64 oracle (mic=ref=0 in the silent phase),
    // so the carried-history transient is modelled exactly, and require pan's tap norm
    // to track it; the structural claim is that the norm STRICTLY decays.
    const taps = 6;
    const leak: f32 = 5e-2; // large so the decay is unmistakable over a few blocks
    var hs = pan.fx.HowlSuppressor(Num, taps){ .mu = 0.5, .leak = leak };

    // Charge the taps with a correlated block.
    var micx: [16]f32 = undefined;
    var refx: [16]f32 = undefined;
    for (0..16) |i| {
        const t: f32 = @floatFromInt(i);
        refx[i] = 0.6 * @sin(0.7 * t);
        micx[i] = 0.5 * refx[i];
    }
    var mic: [16]pan.Sample(f32) = undefined;
    var ref: [16]pan.Sample(f32) = undefined;
    for (0..16) |i| {
        mic[i] = S(micx[i]);
        ref[i] = S(refx[i]);
    }
    var out: [16]pan.Sample(f32) = undefined;
    hs.process(&mic, &ref, &out);

    var norm_before: f32 = 0;
    for (hs.w) |wk| norm_before += wk * wk;
    try expect(norm_before > 0); // taps actually charged

    // Independent oracle: replay the same charge block, then the silent run.
    var w: [taps]f64 = @splat(0);
    var xh: [taps]f64 = @splat(0);
    for (0..16) |i| _ = nlmsStep(taps, &w, &xh, micx[i], refx[i], 0.5, 1e-6, leak);

    // Now feed silence on BOTH channels for several blocks. The pan block and the
    // oracle both see x==0 ⇒ every step is err·0 = 0 in the dot/update once the old
    // history flushes, leaving only the (1−leak) shrinkage.
    var z: [16]pan.Sample(f32) = @splat(S(0));
    var zout: [16]pan.Sample(f32) = undefined;
    const silent_blocks = 4;
    var blk: usize = 0;
    while (blk < silent_blocks) : (blk += 1) {
        hs.process(&z, &z, &zout);
        for (0..16) |_| _ = nlmsStep(taps, &w, &xh, 0, 0, 0.5, 1e-6, leak);
    }

    var norm_after: f32 = 0;
    for (hs.w) |wk| norm_after += wk * wk;
    var oracle_norm: f64 = 0;
    for (w) |wk| oracle_norm += wk * wk;

    try expect(norm_after < norm_before); // strictly decayed (leak ≠ 0)
    // pan's decayed tap norm matches the independently-replayed oracle's.
    try expectApproxEqAbs(@as(f32, @floatCast(oracle_norm)), norm_after, @as(f32, @floatCast(oracle_norm)) * 1e-3 + 1e-9);
    // And it really did shrink toward zero: after this many leaky samples the norm is
    // a small fraction of the charged norm (the geometric tail dominates the tiny
    // history-transient contribution).
    try expect(norm_after < norm_before * 0.05);
}

test "adaptive: HowlSuppressor determinism — two instances agree bit-for-bit" {
    const taps = 8;
    var primary: [48]pan.Sample(f32) = undefined;
    var ref: [48]pan.Sample(f32) = undefined;
    for (0..48) |i| {
        const t: f32 = @floatFromInt(i);
        primary[i] = S(0.4 * @sin(1.0 * t + 0.2));
        ref[i] = S(0.5 * @sin(0.6 * t));
    }
    var a = pan.fx.HowlSuppressor(Num, taps){ .mu = 0.5, .leak = 1e-3 };
    var b = pan.fx.HowlSuppressor(Num, taps){ .mu = 0.5, .leak = 1e-3 };
    var oa: [48]pan.Sample(f32) = undefined;
    var ob: [48]pan.Sample(f32) = undefined;
    a.process(&primary, &ref, &oa);
    b.process(&primary, &ref, &ob);
    for (oa, ob) |x, y| try expectEqual(x.ch[0], y.ch[0]);
    for (a.w, b.w) |x, y| try expectEqual(x, y);
}
