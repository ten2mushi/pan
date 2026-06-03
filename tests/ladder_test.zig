//! ladder_test — the Yoneda characterization of `Ladder(num)` from `src/fx.zig`.
//!
//! `Ladder` is a Moog-style 4-pole resonant low-pass: ONE rate-1:1 `Map` whose
//! `process` runs a per-sample recurrence over four cascaded one-pole stages with
//! a single global resonance feedback (the `z⁻¹` is the previous-sample `s4`):
//!
//!     u   = x[n] − k·s4          // global resonance feedback (z⁻¹ on s4)
//!     s1 += g·(u  − s1)          // four cascaded one-pole low-passes
//!     s2 += g·(s1 − s2)
//!     s3 += g·(s2 − s3)
//!     s4 += g·(s3 − s4)
//!     y[n] = s4
//!
//! `g = cutoff ∈ (0,1)` (rises with cutoff frequency); `k = resonance ∈ [0,4)`
//! (self-oscillates at 4, kept strictly below for a stable, decaying response).
//!
//! We understand the kernel through ALL its observable morphisms — every way an
//! input window maps to an output window over the persistent stage state — so the
//! tests *define* the behavior rather than sample it. Coverage families:
//!
//!   1. ANALYTIC ORACLE (resonance = 0). With k = 0 the cascade is exactly four
//!      independent one-pole low-passes `s += g·(x − s)`. That is a deterministic
//!      scalar recurrence the test re-derives INDEPENDENTLY (a hand-rolled second
//!      computation, NOT a second pan path) and compares with `expectApproxEqAbs`.
//!      This is a ≈ analytic oracle, so f32 round-off is forgiven (tol scaled to
//!      the recurrence): it is NOT a pan-vs-pan bit-exact claim.
//!
//!   2. STRUCTURAL / STATE ORACLE (pan-vs-pan, BIT-EXACT). The internal z⁻¹ and the
//!      four stage words persist across `process` calls, so two pan runs that MUST
//!      agree are compared with `expectEqual` (an "almost" is a failure): a split
//!      render [0,k)+[k,N) is byte-identical to one whole [0,N) render. Same kernel,
//!      same arithmetic order ⇒ exact equality is the correct, strongest assertion.
//!
//!   3. BEHAVIOURAL / STABILITY ORACLE (≈, inequalities). Low-pass character (a DC
//!      step settles monotonically toward the input; a high-frequency ±1 input is
//!      attenuated relative to DC), cutoff monotonicity (higher cutoff settles
//!      faster), boundedness + finiteness for every k < 4, and resonance raising
//!      the ringing. These are order/decay facts ⇒ inequalities, not exact values.
//!
//!   4. LINEARITY (resonance = 0, ≈). With k = 0 the whole map is linear: scaling
//!      the input scales the output and superposition holds, to f32 tolerance.
//!
//!   5. CLASSIFICATION FACET (⊢). Classifies `.Map`, declares `delay_len` (= 1, the
//!      one-sample feedback z⁻¹), carries `state_size = 4·@sizeOf(T)`, and does NOT
//!      declare `aliasing_safe` (the read-before-write recurrence forbids in-place).
//!
//! COMPARISON TIERS (labelled in every test name):
//!   ⊢  structural facts   → `expectEqual` / `expect` (classification, decls, split≡whole).
//!   ≈  behavioural/oracle → `expectApproxEqAbs` / inequalities (the one-pole-cascade
//!                           oracle, decay, stability, linearity).
//! There is NO bit-exact pan-vs-pan NUMERIC path here (no second pan implementation
//! of the recurrence), so we never claim bit-exactness for the numeric behaviour —
//! only for the split≡whole identity, where both sides ARE the same pan kernel.
//!
//! Float-only: an integer `num` is a `@compileError` in `Ladder`; that is DOCUMENTED
//! as a commented-out stub below (instantiating it would break the build).
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring, per
//! project Rules 13/14). Diagnostics on any expected-reject path use
//! `std.debug.print`, never `std.log.err` (the 0.16 test runner counts logged
//! errors as failures).

const std = @import("std");
const pan = @import("pan");

const Ladder = pan.Ladder;
const Sample = pan.types.Sample;
const port = pan.port;

const testing = std.testing;
const num_f32 = pan.numericFor(.f32, .{});
const num_f64 = pan.numericFor(.f64, .{});

// ---------------------------------------------------------------------------
// Small helpers: build a mono Sample(f32) and read its scalar back out.
// ---------------------------------------------------------------------------

fn S(x: f32) Sample(f32) {
    return .{ .ch = .{x} };
}

/// Fill a Sample(f32) buffer with a constant DC level.
fn fillDC(buf: []Sample(f32), level: f32) void {
    for (buf) |*s| s.* = S(level);
}

/// Fill with the highest representable frequency for a discrete signal: an
/// alternating ±amp square at the Nyquist rate. The 4-pole low-pass should crush
/// this far harder than a DC input of the same amplitude.
fn fillNyquist(buf: []Sample(f32), amp: f32) void {
    for (buf, 0..) |*s, i| s.* = S(if (i % 2 == 0) amp else -amp);
}

/// A reproducible white-ish signal in [-1, 1) — drives the linearity/superposition
/// oracle with a non-degenerate input.
fn fillNoise(buf: []Sample(f32), seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (buf) |*s| s.* = S(r.float(f32) * 2.0 - 1.0);
}

/// Peak |y| over an output window.
fn peakAbs(out: []const Sample(f32)) f32 {
    var p: f32 = 0;
    for (out) |s| p = @max(p, @abs(s.ch[0]));
    return p;
}

/// Σ y² over an output window (energy).
fn energy(out: []const Sample(f32)) f32 {
    var e: f32 = 0;
    for (out) |s| e += s.ch[0] * s.ch[0];
    return e;
}

/// The INDEPENDENT analytic oracle for resonance = 0: four cascaded one-pole
/// low-passes `s += g·(x − s)`, computed here with plain scalars in the SAME order
/// the kernel uses. This is NOT a second pan path — it is a hand-rolled reference
/// recurrence. Writes y[n] = s4 for each input sample. (Starts from rest, like a
/// freshly-constructed Ladder.)
fn oracleResZero(g: f32, xs: []const f32, ys: []f32) void {
    std.debug.assert(xs.len == ys.len);
    var s1: f32 = 0;
    var s2: f32 = 0;
    var s3: f32 = 0;
    var s4: f32 = 0;
    for (xs, ys) |x, *y| {
        // resonance = 0 ⇒ u = x (no feedback term).
        s1 += g * (x - s1);
        s2 += g * (s1 - s2);
        s3 += g * (s2 - s3);
        s4 += g * (s3 - s4);
        y.* = s4;
    }
}

// ===========================================================================
// 5. CLASSIFICATION FACET  (⊢ structural facts via expectEqual / expect)
// ===========================================================================

test "⊢ classify: Ladder is a .Map" {
    try testing.expectEqual(port.BlockClass.Map, port.classify(Ladder(num_f32)));
    try testing.expectEqual(port.BlockClass.Map, port.classify(Ladder(num_f64)));
}

test "⊢ decls: declares delay_len = 1 (the one-sample feedback z⁻¹)" {
    try testing.expect(@hasDecl(Ladder(num_f32), "delay_len"));
    try testing.expectEqual(@as(usize, 1), Ladder(num_f32).delay_len);
    try testing.expectEqual(@as(usize, 1), Ladder(num_f64).delay_len);
}

test "⊢ decls: is NOT aliasing_safe (read-before-write forbids in-place out)" {
    try testing.expect(!@hasDecl(Ladder(num_f32), "aliasing_safe"));
    try testing.expect(!@hasDecl(Ladder(num_f64), "aliasing_safe"));
}

test "⊢ decls: state_size counts the four stage words (4·@sizeOf(T))" {
    try testing.expectEqual(@as(usize, 4 * @sizeOf(f32)), Ladder(num_f32).state_size);
    try testing.expectEqual(@as(usize, 4 * @sizeOf(f64)), Ladder(num_f64).state_size);
}

test "⊢ ports: in/out elements are mono Sample(T); out direction is .out" {
    const L = Ladder(num_f32);
    try testing.expect(port.MapInPort(L).Elem == Sample(f32));
    try testing.expect(port.MapOutPort(L).Elem == Sample(f32));
    try testing.expect(port.MapInPort(L).direction == .in);
    try testing.expect(port.MapOutPort(L).direction == .out);
    // Exactly one sample input and one sample output port (a unary filter).
    try testing.expectEqual(@as(comptime_int, 1), port.mapInputCount(L));
    try testing.expectEqual(@as(comptime_int, 1), port.mapOutputCount(L));
    // Not a Source: it has a real sample input port.
    try testing.expect(!comptime port.isSource(L));
}

test "⊢ defaults: a default-constructed Ladder is at rest with the documented coeffs" {
    const lad = Ladder(num_f32){};
    try testing.expectEqual(@as(f32, 0.3), lad.cutoff); // documented default g
    try testing.expectEqual(@as(f32, 0.0), lad.resonance); // documented default k
    // Stage state starts from rest.
    try testing.expectEqual(@as(f32, 0), lad.s1);
    try testing.expectEqual(@as(f32, 0), lad.s2);
    try testing.expectEqual(@as(f32, 0), lad.s3);
    try testing.expectEqual(@as(f32, 0), lad.s4);
}

// ===========================================================================
// 1. ANALYTIC ORACLE — resonance = 0 ≡ four cascaded one-poles
//    (≈ via expectApproxEqAbs against an INDEPENDENT hand-rolled recurrence)
// ===========================================================================

test "≈ oracle: DC step, k=0 matches the four-one-pole cascade sample-for-sample" {
    const g: f32 = 0.3;
    var lad = Ladder(num_f32){ .cutoff = g, .resonance = 0 };

    var in: [256]Sample(f32) = undefined;
    fillDC(&in, 1.0);
    var out: [256]Sample(f32) = undefined;
    lad.process(&in, &out);

    var xs: [256]f32 = undefined;
    var ref: [256]f32 = undefined;
    for (&xs, in) |*x, s| x.* = s.ch[0];
    oracleResZero(g, &xs, &ref);

    // Allclose against the analytic oracle — a ≈ float oracle, so a small absolute
    // tolerance forgives only f32 round-off (same op order, so it stays tiny).
    for (out, ref) |y, r| try testing.expectApproxEqAbs(r, y.ch[0], 1e-6);
}

test "≈ oracle: impulse response, k=0 matches the cascade (the kernel IS its impulse response)" {
    const g: f32 = 0.45;
    var lad = Ladder(num_f32){ .cutoff = g, .resonance = 0 };

    var in: [128]Sample(f32) = @splat(S(0));
    in[0] = S(1); // unit impulse
    var out: [128]Sample(f32) = undefined;
    lad.process(&in, &out);

    var xs: [128]f32 = undefined;
    var ref: [128]f32 = undefined;
    for (&xs, in) |*x, s| x.* = s.ch[0];
    oracleResZero(g, &xs, &ref);

    for (out, ref) |y, r| try testing.expectApproxEqAbs(r, y.ch[0], 1e-6);
}

test "≈ oracle: noise input, k=0 matches the cascade (a non-degenerate signal)" {
    const g: f32 = 0.6;
    var lad = Ladder(num_f32){ .cutoff = g, .resonance = 0 };

    var in: [512]Sample(f32) = undefined;
    fillNoise(&in, 0xA17E_C0DE);
    var out: [512]Sample(f32) = undefined;
    lad.process(&in, &out);

    var xs: [512]f32 = undefined;
    var ref: [512]f32 = undefined;
    for (&xs, in) |*x, s| x.* = s.ch[0];
    oracleResZero(g, &xs, &ref);

    // Error accumulates a touch over 512 samples through a 4-deep cascade; a
    // slightly looser absolute tol still pins every sample tightly.
    for (out, ref) |y, r| try testing.expectApproxEqAbs(r, y.ch[0], 1e-5);
}

// ===========================================================================
// 3. BEHAVIOURAL / STABILITY ORACLE  (≈ inequalities)
// ===========================================================================

test "≈ low-pass: a DC step settles monotonically toward the input level (k=0)" {
    var lad = Ladder(num_f32){ .cutoff = 0.3, .resonance = 0 };
    var in: [512]Sample(f32) = undefined;
    fillDC(&in, 1.0);
    var out: [512]Sample(f32) = undefined;
    lad.process(&in, &out);

    // Monotone non-decreasing ramp toward the DC level (no resonance ⇒ no overshoot).
    var prev: f32 = -1.0;
    for (out) |s| {
        const v = s.ch[0];
        try testing.expect(v >= prev - 1e-7); // monotone up (tiny slack for round-off)
        try testing.expect(v <= 1.0 + 1e-6); // never overshoots the input level
        prev = v;
    }
    // Starts low (the cascade has not charged) and ends very close to the input.
    try testing.expect(out[0].ch[0] < 0.05);
    try testing.expect(out[511].ch[0] > 0.99);
}

test "≈ low-pass: a Nyquist (±1) input is attenuated far below a DC input of equal amplitude" {
    const g: f32 = 0.3;

    var lad_dc = Ladder(num_f32){ .cutoff = g, .resonance = 0 };
    var dc_in: [512]Sample(f32) = undefined;
    fillDC(&dc_in, 1.0);
    var dc_out: [512]Sample(f32) = undefined;
    lad_dc.process(&dc_in, &dc_out);

    var lad_hf = Ladder(num_f32){ .cutoff = g, .resonance = 0 };
    var hf_in: [512]Sample(f32) = undefined;
    fillNyquist(&hf_in, 1.0);
    var hf_out: [512]Sample(f32) = undefined;
    lad_hf.process(&hf_in, &hf_out);

    // Compare the settled tail (last quarter): DC passes ≈ unity, Nyquist is crushed.
    const tail = 384;
    const dc_peak = peakAbs(dc_out[tail..]);
    const hf_peak = peakAbs(hf_out[tail..]);
    try testing.expect(dc_peak > 0.99); // DC passes essentially intact
    try testing.expect(hf_peak < 0.05); // Nyquist is heavily attenuated
    try testing.expect(hf_peak < dc_peak * 0.1); // and far below the DC level
}

test "≈ cutoff monotonicity: a higher cutoff settles toward a DC input faster" {
    // After a fixed number of samples of a DC step, the higher-cutoff ladder has
    // charged closer to the input level than the lower-cutoff one.
    const N = 32;
    var lo = Ladder(num_f32){ .cutoff = 0.15, .resonance = 0 };
    var hi = Ladder(num_f32){ .cutoff = 0.45, .resonance = 0 };

    var in: [N]Sample(f32) = undefined;
    fillDC(&in, 1.0);
    var lo_out: [N]Sample(f32) = undefined;
    var hi_out: [N]Sample(f32) = undefined;
    lo.process(&in, &lo_out);
    hi.process(&in, &hi_out);

    // Sample-by-sample, the higher cutoff is never behind and is strictly ahead by
    // the end of the window (faster charge).
    for (lo_out, hi_out) |l, h| try testing.expect(h.ch[0] >= l.ch[0] - 1e-7);
    try testing.expect(hi_out[N - 1].ch[0] > lo_out[N - 1].ch[0] + 0.05);
}

test "≈ stability: for every k < 4 an impulse yields a BOUNDED, finite response" {
    // Sweep a range of resonances strictly below self-oscillation. None may diverge,
    // and every output sample must be finite (no NaN/Inf from the feedback loop).
    const ks = [_]f32{ 0.0, 1.0, 2.0, 3.0, 3.5, 3.9, 3.99 };
    inline for (ks) |k| {
        var lad = Ladder(num_f32){ .cutoff = 0.25, .resonance = k };
        var in: [1024]Sample(f32) = @splat(S(0));
        in[0] = S(1); // unit impulse
        var out: [1024]Sample(f32) = undefined;
        lad.process(&in, &out);

        for (out) |s| try testing.expect(std.math.isFinite(s.ch[0]));
        // Bounded: the response never explodes (generous ceiling well clear of the
        // resonant peak but far below divergence).
        try testing.expect(peakAbs(&out) < 16.0);
        // Continue with silence: a stable loop's tail decays, it does not grow.
        var in2: [1024]Sample(f32) = @splat(S(0));
        var out2: [1024]Sample(f32) = undefined;
        lad.process(&in2, &out2);
        for (out2) |s| try testing.expect(std.math.isFinite(s.ch[0]));
        try testing.expect(peakAbs(&out2) <= peakAbs(&out) + 1e-4); // non-growing tail
    }
}

test "≈ resonance raises the ringing: higher k ⇒ more residual tail ENERGY" {
    // Drive each with a unit impulse, then measure the residual on a LATER silent
    // block. More resonance keeps more energy circulating in the loop.
    //
    // NOTE (an honest characterization, learned by probing the kernel): for this
    // linearized topology the residual tail ENERGY grows monotonically with k, but
    // the tail PEAK is NOT monotone in k (it dips around k≈2 before climbing back).
    // So the discriminating, always-true invariant is on energy, not peak. A test
    // asserting peak-monotonicity would be WRONG for this kernel — we deliberately
    // do not make that claim.
    const g: f32 = 0.2;

    var low_res = Ladder(num_f32){ .cutoff = g, .resonance = 0.5 };
    var high_res = Ladder(num_f32){ .cutoff = g, .resonance = 3.99 };

    var imp: [16]Sample(f32) = @splat(S(0));
    imp[0] = S(1);
    var tmp: [16]Sample(f32) = undefined;
    low_res.process(&imp, &tmp);
    high_res.process(&imp, &tmp);

    var silence: [256]Sample(f32) = @splat(S(0));
    var lo_tail: [256]Sample(f32) = undefined;
    var hi_tail: [256]Sample(f32) = undefined;
    low_res.process(&silence, &lo_tail);
    high_res.process(&silence, &hi_tail);

    // The high-resonance loop retains markedly more energy.
    try testing.expect(energy(&hi_tail) > energy(&lo_tail));
    // Both remain finite and bounded (k < 4).
    for (hi_tail) |s| try testing.expect(std.math.isFinite(s.ch[0]));
    for (lo_tail) |s| try testing.expect(std.math.isFinite(s.ch[0]));
}

test "≈ resonance ↑ tail energy across the high-k range (3.0 → 3.99)" {
    // Across the HIGH-resonance range — where the feedback dominates and the loop
    // is near self-oscillation — the residual tail energy is monotone non-decreasing
    // in k. (At LOW k the energy is non-monotone, dipping around k≈1 before rising,
    // so this finer sweep is restricted to the high range where the claim holds;
    // making the monotone claim over the whole [0,4) range would be FALSE for this
    // kernel and we deliberately do not.)
    const g: f32 = 0.2;
    const ks = [_]f32{ 3.0, 3.5, 3.7, 3.9, 3.99 };
    var prev_e: f32 = -1.0;
    inline for (ks) |k| {
        var lad = Ladder(num_f32){ .cutoff = g, .resonance = k };
        var imp: [16]Sample(f32) = @splat(S(0));
        imp[0] = S(1);
        var tmp: [16]Sample(f32) = undefined;
        lad.process(&imp, &tmp);
        var silence: [256]Sample(f32) = @splat(S(0));
        var tail: [256]Sample(f32) = undefined;
        lad.process(&silence, &tail);
        const e = energy(&tail);
        try testing.expect(e >= prev_e); // monotone non-decreasing in k (high range)
        prev_e = e;
    }
}

// ===========================================================================
// 2. STRUCTURAL / STATE ORACLE  (⊢ pan-vs-pan BIT-EXACT via expectEqual)
//    The four stage words + the s4 feedback z⁻¹ carry across process() calls,
//    so a split render must equal one whole render to the bit.
// ===========================================================================

test "⊢ state: a split render [0,k)+[k,N) is BIT-IDENTICAL to one whole [0,N) render (k=0)" {
    var whole = Ladder(num_f32){ .cutoff = 0.3, .resonance = 0 };
    var split = Ladder(num_f32){ .cutoff = 0.3, .resonance = 0 };

    var in: [300]Sample(f32) = undefined;
    fillNoise(&in, 0x5151_2727);

    var out_whole: [300]Sample(f32) = undefined;
    whole.process(&in, &out_whole);

    var out_split: [300]Sample(f32) = undefined;
    const cuts = [_]usize{ 1, 17, 128, 200, 300 }; // irregular sub-block boundaries
    var lo: usize = 0;
    for (cuts) |hi| {
        split.process(in[lo..hi], out_split[lo..hi]);
        lo = hi;
    }
    // Same kernel, same per-sample arithmetic order across the seam ⇒ EXACT equality.
    for (out_whole, out_split) |w, s| try testing.expectEqual(w.ch[0], s.ch[0]);
}

test "⊢ state: split ≡ whole holds WITH resonance (the feedback z⁻¹ also carries)" {
    // The same identity must hold when the global resonance loop is active — the
    // carried s4 (the z⁻¹ feedback tap) is what makes the seam transparent.
    var whole = Ladder(num_f32){ .cutoff = 0.25, .resonance = 3.5 };
    var split = Ladder(num_f32){ .cutoff = 0.25, .resonance = 3.5 };

    var in: [200]Sample(f32) = @splat(S(0));
    in[0] = S(1); // impulse so the resonant loop is excited and ringing across cuts
    var out_whole: [200]Sample(f32) = undefined;
    whole.process(&in, &out_whole);

    var out_split: [200]Sample(f32) = undefined;
    const cuts = [_]usize{ 1, 2, 64, 199, 200 };
    var lo: usize = 0;
    for (cuts) |hi| {
        split.process(in[lo..hi], out_split[lo..hi]);
        lo = hi;
    }
    for (out_whole, out_split) |w, s| try testing.expectEqual(w.ch[0], s.ch[0]);
}

test "⊢ state: a fresh single-sample-at-a-time render equals the whole render" {
    // The extreme split: one sample per call. Pins that NOTHING but the persistent
    // state crosses the call boundary.
    var whole = Ladder(num_f32){ .cutoff = 0.4, .resonance = 1.2 };
    var stepper = Ladder(num_f32){ .cutoff = 0.4, .resonance = 1.2 };

    var in: [64]Sample(f32) = undefined;
    fillNoise(&in, 0xDEAD_BEEF);
    var out_whole: [64]Sample(f32) = undefined;
    whole.process(&in, &out_whole);

    var out_step: [64]Sample(f32) = undefined;
    for (0..in.len) |i| stepper.process(in[i .. i + 1], out_step[i .. i + 1]);
    for (out_whole, out_step) |w, s| try testing.expectEqual(w.ch[0], s.ch[0]);
}

test "⊢ state: an empty render is a no-op (leaves state untouched)" {
    var lad = Ladder(num_f32){ .cutoff = 0.3, .resonance = 2.0 };
    // Charge it up a little first.
    var pre: [8]Sample(f32) = undefined;
    fillDC(&pre, 1.0);
    var pre_out: [8]Sample(f32) = undefined;
    lad.process(&pre, &pre_out);
    const snap = .{ lad.s1, lad.s2, lad.s3, lad.s4 };

    // Render zero samples: the state must be exactly unchanged.
    var empty_in: [0]Sample(f32) = .{};
    var empty_out: [0]Sample(f32) = .{};
    lad.process(&empty_in, &empty_out);
    try testing.expectEqual(snap[0], lad.s1);
    try testing.expectEqual(snap[1], lad.s2);
    try testing.expectEqual(snap[2], lad.s3);
    try testing.expectEqual(snap[3], lad.s4);
}

// ===========================================================================
// 4. LINEARITY at resonance = 0  (≈ — the cascade is then four linear one-poles)
// ===========================================================================

test "≈ linearity: scaling the input scales the output (k=0)" {
    const g: f32 = 0.35;
    const c: f32 = 2.75; // arbitrary scale factor

    var base = Ladder(num_f32){ .cutoff = g, .resonance = 0 };
    var scaled = Ladder(num_f32){ .cutoff = g, .resonance = 0 };

    var x: [256]Sample(f32) = undefined;
    fillNoise(&x, 0x1234_5678);
    var cx: [256]Sample(f32) = undefined;
    for (&cx, x) |*d, s| d.* = S(c * s.ch[0]);

    var y: [256]Sample(f32) = undefined;
    var ycx: [256]Sample(f32) = undefined;
    base.process(&x, &y);
    scaled.process(&cx, &ycx);

    // L(c·x) ≈ c·L(x), to f32 tolerance (a ≈ behavioural identity, not bit-exact).
    for (y, ycx) |yv, sv| try testing.expectApproxEqAbs(c * yv.ch[0], sv.ch[0], 1e-5);
}

test "≈ linearity: superposition L(a+b) ≈ L(a) + L(b) (k=0)" {
    const g: f32 = 0.4;

    var la = Ladder(num_f32){ .cutoff = g, .resonance = 0 };
    var lb = Ladder(num_f32){ .cutoff = g, .resonance = 0 };
    var lab = Ladder(num_f32){ .cutoff = g, .resonance = 0 };

    var a: [256]Sample(f32) = undefined;
    var b: [256]Sample(f32) = undefined;
    fillNoise(&a, 0x0BAD_F00D);
    fillNoise(&b, 0xFEED_FACE);
    var ab: [256]Sample(f32) = undefined;
    for (&ab, a, b) |*d, av, bv| d.* = S(av.ch[0] + bv.ch[0]);

    var ya: [256]Sample(f32) = undefined;
    var yb: [256]Sample(f32) = undefined;
    var yab: [256]Sample(f32) = undefined;
    la.process(&a, &ya);
    lb.process(&b, &yb);
    lab.process(&ab, &yab);

    for (ya, yb, yab) |yav, ybv, yabv|
        try testing.expectApproxEqAbs(yav.ch[0] + ybv.ch[0], yabv.ch[0], 1e-5);
}

test "≈ resonance lowers the DC gain to 1/(1+k) (the feedback OPPOSES the steady state)" {
    // A discriminating counterexample to the naive "resonance overshoots" intuition.
    // At true DC, s1=s2=s3=s4=y settles where g·(u − y) = 0 ⇒ y = u = x − k·y, i.e.
    //   y_∞ = x / (1 + k).
    // So for this linearized topology the resonant feedback ATTENUATES the DC level
    // (it does not overshoot it). We pin the closed-form steady state across k, and
    // also assert NO sample ever exceeds the input level for a DC step (no overshoot
    // at DC). A "resonance ignored" bug would settle to 1.0 and fail every prong;
    // an "overshoot" bug would breach the no-overshoot bound.
    const ks = [_]f32{ 1.0, 2.0, 3.0, 3.6 };
    inline for (ks) |k| {
        var lad = Ladder(num_f32){ .cutoff = 0.3, .resonance = k };
        var in: [4096]Sample(f32) = undefined; // long enough to settle to DC
        fillDC(&in, 1.0);
        var out: [4096]Sample(f32) = undefined;
        lad.process(&in, &out);
        const expected: f32 = 1.0 / (1.0 + k);
        try testing.expectApproxEqAbs(expected, out[4095].ch[0], 1e-4);
        // No DC overshoot: the resonance attenuates, it does not ring past the input.
        try testing.expect(peakAbs(&out) <= 1.0 + 1e-5);
    }
}

// ===========================================================================
// 6. PRECISION FACET — the same characterization holds for f64
// ===========================================================================

test "≈ f64: the resonance-0 cascade oracle holds at double precision (tighter tol)" {
    const g: f64 = 0.3;
    var lad = Ladder(num_f64){ .cutoff = g, .resonance = 0 };

    var in: [256]Sample(f64) = undefined;
    for (&in) |*s| s.* = .{ .ch = .{1.0} };
    var out: [256]Sample(f64) = undefined;
    lad.process(&in, &out);

    // Re-derive the cascade in f64.
    var s1: f64 = 0;
    var s2: f64 = 0;
    var s3: f64 = 0;
    var s4: f64 = 0;
    for (out) |y| {
        s1 += g * (1.0 - s1);
        s2 += g * (s1 - s2);
        s3 += g * (s2 - s3);
        s4 += g * (s3 - s4);
        try testing.expectApproxEqAbs(s4, y.ch[0], 1e-12);
    }
}

// ===========================================================================
// FLOAT-ONLY FACET (documented compile-error stub — NOT instantiated).
//
// Ladder calls requireFloat(T), which @compileError's on an integer lane:
//   "pan: fixed-point feedback kernels are not yet supported — … Use f32/f64."
// Instantiating an integer Ladder would abort the build, so we DOCUMENT the reject
// the way the codebase documents its other disabled @compileError stubs:
//
//   const num_i16 = pan.numericFor(.i16, .{});
//   _ = Ladder(num_i16);  // => @compileError: fixed-point feedback kernels …
//
// (Left commented so this file compiles; the structural fact is that an integer
// `num` never produces a type — it is rejected at comptime.)
// ===========================================================================
