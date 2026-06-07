//! Modulation appliers & adaptive dynamics (parameter-port consumers/producers).
//!
//! These are the *applied* side of the modulation taxonomy (the *generators* — Lfo /
//! Adsr / FeatureMap — live in `gen.zig` / `env.zig`). They consume control (`Vca`)
//! or both consume audio and produce control (`AgcController`, `PowerGate`), and one
//! (`Agc`) is the fused controller-plus-applier. `Compressor`/`CompressorController`
//! are the dynamics processor in both the fused and decoupled realisations (the gain
//! is private to one block, vs exposed as a `Scalar` parameter a separate `Vca`
//! applies); `Limiter` and `Expander` round out the dynamics family. All are
//! float-only (a gain ramp / level estimate is f32), declared loud via
//! `requireFloat`. The control element is always `Scalar(f32)`; see `gen.zig`'s
//! header for the one-value-per-call / broadcast-storage convention a control
//! producer follows so the executor's per-lane NaN/Inf poison guard stays satisfied.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;
const numeric = core.numeric;
const control = core.control;

const primitives = @import("../primitives.zig");
const fxc = @import("fx_common.zig");
const scalarsConst = fxc.scalarsConst;
const scalars = fxc.scalars;
const requireFloat = fxc.requireFloat;

/// Block mean-square (average power) of a mono `Sample(T)` slice. `eps`-floored by
/// the caller where it divides.
fn blockPower(comptime T: type, xs: []const T) T {
    if (xs.len == 0) return 0;
    var acc: T = 0;
    for (xs) |x| acc += x * x;
    return acc / @as(T, @floatFromInt(xs.len));
}

/// `Vca(num)` — a voltage-controlled amplifier: a gain whose coefficient is a
/// **parameter port** (`vca.param.gain`), driven by `set`/`schedule` **or** a wired
/// modulation edge (an `Lfo`, an `Adsr`, an `AgcController`, a `PowerGate` — by the
/// one-source rule, a wired edge XOR an external set, never both). It holds the
/// latest target and **per-block ramps** toward it (the anti-zipper `control.Ramp`),
/// exactly as a `set` on a plain gain would. Because a wired parameter edge and an
/// external `set` both arrive through `setParam` and drive the *same* `Param`/`Ramp`,
/// an `Lfo → vca.param.gain` sweep is **bit-identical** to the same target sequence
/// pushed via `engine.set`. It is the canonical modulation *consumer* and the
/// multiply target for data-gating (a `PowerGate`'s `{0,1}` gate ramped to a
/// click-free fade).
pub fn Vca(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// The gain parameter port (control element `Scalar(f32)`). Slot 0.
        pub const params = .{ .gain = types.Scalar(f32) };

        /// Latest published target (atomic; set by the control thread OR by the
        /// wired-edge `applyParamInputs`). Read once per block on the RT thread.
        target: control.Param = control.Param.init(1.0),
        /// The live, audibly-rendered gain, ramped across blocks (persistent state).
        ramp: control.Ramp = control.Ramp.init(1.0),

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.target.set(value);
        }

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const tgt = self.target.read();
            // Per-sample ramp the gain toward the target, then snap to it.
            primitives.applyRampedGain(T, &self.ramp, tgt, xs, ys);
        }
    };
}

/// `Agc(num)` — **fused** automatic gain control: one block that estimates the
/// block level, drives a smoothed gain toward `target / level`, and applies it,
/// per-sample-ramped, to the audio in a single `process`. This is the **fused**
/// realisation of an adaptive processor (controller + applied filter in one block) —
/// the alternative to the *decoupled* realisation where the coefficient is a
/// parameter port driven by a separate controller node (`AgcController` below);
/// fusing is preferred when the coefficient is private. `rate ∈ (0, 1]` is the
/// per-block one-pole adaptation
/// speed; `max_gain` bounds make-up gain so silence does not explode to infinity.
pub fn Agc(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// Desired output RMS (linear). The control-rate set-point.
        target: f32 = 0.25,
        /// One-pole adaptation coefficient per block (0 = frozen, 1 = instant).
        rate: f32 = 0.1,
        /// Upper bound on the make-up gain.
        max_gain: f32 = 8.0,
        /// The smoothed gain, ramped across blocks (persistent).
        ramp: control.Ramp = control.Ramp.init(1.0),

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const rms: f32 = @floatCast(@sqrt(blockPower(T, xs)));
            const desired = @min(self.target / @max(rms, 1e-9), self.max_gain);
            // One-pole toward the desired gain, then per-sample ramp to it.
            const smoothed = self.ramp.value + self.rate * (desired - self.ramp.value);
            // Per-sample ramp the gain toward the smoothed target, then snap to it.
            primitives.applyRampedGain(T, &self.ramp, smoothed, xs, ys);
        }
    };
}

/// `AgcController(num)` — the **decoupled** twin of `Agc`: it reads the audio and
/// *emits the make-up gain as a `Scalar(f32)`* (one value per call, broadcast) to
/// drive a separate `Vca`'s `param.gain`. The decoupling makes the adaptive
/// coefficient a first-class graph value — the same controller can drive several
/// `Vca`s, or be inspected/recorded, without re-measuring. The
/// per-block one-pole smoothing lives here; the per-sample anti-zipper ramp lives in
/// the `Vca` it feeds, so the pair is zipper-free end to end.
pub fn AgcController(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        target: f32 = 0.25,
        rate: f32 = 0.1,
        max_gain: f32 = 8.0,
        /// The smoothed make-up gain (persistent across calls).
        gain: f32 = 1.0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Scalar(f32)) void {
            const xs = scalarsConst(T, in);
            const rms: f32 = @floatCast(@sqrt(blockPower(T, xs)));
            const desired = @min(self.target / @max(rms, 1e-9), self.max_gain);
            self.gain += self.rate * (desired - self.gain);
            for (out) |*o| o.value = self.gain; // one control value, broadcast
        }
    };
}

/// `PowerGate(num)` — a **data-gating** noise/VAD gate: it estimates the block power
/// and emits a `Scalar(f32)` gate in `{0, 1}` (with hysteresis) that a downstream
/// `Vca` multiplies in. Gating is expressed as DATA, not control flow — the render
/// op-list stays static and unconditional (every op runs every callback); only the
/// gate's *value* changes, and the `Vca`'s ramp turns the `0↔1` step into a
/// click-free fade. This is the deliberate, only form of gating pan offers:
/// conditional/"skip these ops when silent" execution is out of scope, because a
/// static, unconditional op-list is what keeps the hot path deterministic and
/// analyzable. Hysteresis (`open_threshold > close_threshold`) prevents chatter
/// around the threshold.
pub fn PowerGate(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// Power to OPEN the gate, and (lower) power to CLOSE it — hysteresis.
        open_threshold: f32 = 1e-3,
        close_threshold: f32 = 1e-4,
        /// Whether the gate is currently open (persistent across calls).
        open: bool = false,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Scalar(f32)) void {
            const xs = scalarsConst(T, in);
            const power: f32 = @floatCast(blockPower(T, xs));
            if (self.open) {
                if (power < self.close_threshold) self.open = false;
            } else {
                if (power > self.open_threshold) self.open = true;
            }
            const g: f32 = if (self.open) 1.0 else 0.0;
            for (out) |*o| o.value = g; // one gate value, broadcast
        }
    };
}

/// The feed-forward compressor gain for an envelope level `env` (linear amplitude):
/// unity at or below `threshold`, and `(env/threshold)^(1/ratio − 1)` above it —
/// i.e. the amount by which the level exceeds the threshold is divided by `ratio` in
/// the logarithmic domain. `ratio → 1` is no compression; a large `ratio` approaches
/// a hard limiter. Returns ≤ 1 (a gain reduction) for `env > threshold`.
fn compressorGain(env: f32, threshold: f32, ratio: f32) f32 {
    if (env <= threshold or threshold <= 0 or ratio <= 0) return 1.0;
    return std.math.pow(f32, env / threshold, 1.0 / ratio - 1.0);
}

/// Advance a one-pole envelope follower one sample toward `|x|`: rise at `attack`,
/// fall at `release` (both per-sample one-pole coefficients in (0, 1] — higher is
/// faster; the author maps a time constant to them). The asymmetry is what gives a
/// compressor its fast-attack / slow-release character.
fn followEnvelope(env: f32, x: f32, attack: f32, release: f32) f32 {
    const rect = @abs(x);
    const c = if (rect > env) attack else release;
    return env + c * (rect - env);
}

/// `Compressor(num)` — a **fused** feed-forward dynamics compressor: a per-sample
/// envelope follower drives a static gain curve and the gain is applied in the same
/// block (controller + applied gain in one block). The envelope smoothing IS the
/// anti-zipper mechanism, so no separate ramp is needed. `threshold`/`ratio` shape
/// the curve; `attack`/`release` set the envelope's per-sample coefficients;
/// `makeup` is a linear make-up gain.
pub fn Compressor(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();
        threshold: f32 = 0.5,
        ratio: f32 = 4.0,
        attack: f32 = 0.25,
        release: f32 = 0.03,
        makeup: f32 = 1.0,
        /// The envelope-follower state (persistent across calls).
        env: f32 = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            var env = self.env;
            for (xs, ys) |x, *y| {
                env = followEnvelope(env, @floatCast(x), self.attack, self.release);
                const gv: T = @floatCast(compressorGain(env, self.threshold, self.ratio) * self.makeup);
                y.* = x * gv;
            }
            self.env = env;
        }
    };
}

/// `CompressorController(num)` — the **decoupled** twin of `Compressor`: it runs the
/// same per-sample envelope follower and gain curve but *emits the gain as a
/// `Scalar(f32)`* (one value per call, broadcast) for a separate `Vca` to apply, so
/// the dynamics coefficient is a first-class graph value (the same `Vca` could be
/// driven by several controllers, inspected, or recorded). Control-rate: the
/// envelope advances per sample internally, the block-end gain is published, and the
/// `Vca`'s per-block ramp interpolates between blocks.
pub fn CompressorController(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();
        threshold: f32 = 0.5,
        ratio: f32 = 4.0,
        attack: f32 = 0.25,
        release: f32 = 0.03,
        makeup: f32 = 1.0,
        env: f32 = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Scalar(f32)) void {
            const xs = scalarsConst(T, in);
            var env = self.env;
            for (xs) |x| env = followEnvelope(env, @floatCast(x), self.attack, self.release);
            self.env = env;
            const g = compressorGain(env, self.threshold, self.ratio) * self.makeup;
            for (out) |*o| o.value = g; // one control-rate gain, broadcast
        }
    };
}

/// `Limiter(num)` — a brick-wall (peak) limiter: a downward compressor with an
/// effectively infinite ratio above `threshold`. A per-sample envelope follower
/// tracks the signal level; whenever that level exceeds `threshold` the gain is
/// reduced to exactly `threshold / env`, so the *enveloped* level is clamped at the
/// ceiling and never rises above it — the "brick wall". Below the threshold the
/// gain is unity (the signal passes untouched). A limiter is just the ratio→∞ limit
/// of a `Compressor`, so the gain law is `min(1, threshold/env)` rather than the
/// `(env/threshold)^(1/ratio−1)` soft knee.
///
/// `threshold`, `release`, and `attack` are **parameter ports** (`f32`), settable
/// via `set`/`schedule` or a wired modulation edge. The attack/release are the
/// per-sample one-pole envelope coefficients in `(0, 1]` (higher = faster); a fast
/// attack is what makes the limiter catch transients before they pass. The envelope
/// smoothing is itself the anti-zipper mechanism for the gain, so no separate ramp
/// is needed — and because the envelope (not the raw sample) is what is clamped, the
/// guarantee is "the smoothed level holds at the ceiling", with a brief overshoot
/// allowed only while the fast-attack envelope is still rising to a sudden transient.
///
/// NOT `aliasing_safe`: the envelope follower carries per-sample state, so the
/// colorer must not run it in place. Float lanes only (a level estimate / gain is
/// f32), declared loud via `requireFloat`.
pub fn Limiter(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// The ceiling, the release coefficient, and the attack coefficient — three
        /// control ports (control element `Scalar(f32)`) at slots 0, 1, 2.
        pub const params = .{
            .threshold = types.Scalar(f32),
            .release = types.Scalar(f32),
            .attack = types.Scalar(f32),
        };

        /// Peak ceiling (linear amplitude); the enveloped level is held at or below it.
        threshold: control.Param = control.Param.init(0.5),
        /// Envelope fall coefficient per sample in (0, 1] — slower recovery.
        release: control.Param = control.Param.init(0.05),
        /// Envelope rise coefficient per sample in (0, 1] — fast to catch transients.
        attack: control.Param = control.Param.init(0.5),
        /// The envelope-follower state (persistent across calls).
        env: f32 = 0,

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            switch (slot) {
                0 => self.threshold.set(value),
                1 => self.release.set(value),
                2 => self.attack.set(value),
                else => {},
            }
        }

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const thr = self.threshold.read();
            const atk = self.attack.read();
            const rel = self.release.read();
            var env = self.env;
            for (xs, ys) |x, *y| {
                env = followEnvelope(env, @floatCast(x), atk, rel);
                // Infinite-ratio law: pass below the ceiling, clamp the enveloped
                // level to it above. gain = min(1, threshold/env).
                const gv: T = @floatCast(if (env > thr and thr > 0) thr / env else 1.0);
                y.* = x * gv;
            }
            self.env = env;
        }
    };
}

/// `Expander(num)` — a downward expander: the inverse of a compressor. *Above*
/// `threshold` the signal passes at unity; *below* it the signal is attenuated by
/// `ratio` (in the log domain), widening the dynamic range by pushing quiet material
/// further down. The gain law below threshold is `(env/threshold)^(ratio−1)`: with
/// `ratio = 1` it is unity (no expansion), and a larger `ratio` attenuates harder as
/// the level falls — the steep large-ratio limit is a noise gate (the hard-knee
/// `PowerGate` is that {0,1} extreme; this is its soft, continuous-ratio form).
///
/// `threshold`, `ratio`, `attack`, and `release` are **parameter ports** (`f32`).
/// The attack/release are the per-sample one-pole envelope coefficients in `(0, 1]`;
/// the envelope smoothing is the anti-zipper mechanism, so no separate ramp is
/// needed. NOT `aliasing_safe` (per-sample envelope state). Float lanes only.
pub fn Expander(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// Threshold, ratio, attack, release — four control ports (`Scalar(f32)`)
        /// at slots 0, 1, 2, 3.
        pub const params = .{
            .threshold = types.Scalar(f32),
            .ratio = types.Scalar(f32),
            .attack = types.Scalar(f32),
            .release = types.Scalar(f32),
        };

        /// Level below which attenuation begins (linear amplitude).
        threshold: control.Param = control.Param.init(0.1),
        /// Expansion ratio (≥ 1); 1 is no expansion, larger attenuates quiet harder.
        ratio: control.Param = control.Param.init(2.0),
        /// Envelope rise coefficient per sample in (0, 1].
        attack: control.Param = control.Param.init(0.5),
        /// Envelope fall coefficient per sample in (0, 1].
        release: control.Param = control.Param.init(0.05),
        /// The envelope-follower state (persistent across calls).
        env: f32 = 0,

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            switch (slot) {
                0 => self.threshold.set(value),
                1 => self.ratio.set(value),
                2 => self.attack.set(value),
                3 => self.release.set(value),
                else => {},
            }
        }

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const thr = self.threshold.read();
            const rat = self.ratio.read();
            const atk = self.attack.read();
            const rel = self.release.read();
            var env = self.env;
            for (xs, ys) |x, *y| {
                env = followEnvelope(env, @floatCast(x), atk, rel);
                // Unity at/above threshold; attenuate below by (env/threshold)^(ratio−1).
                // ratio ≥ 1 ⇒ exponent ≥ 0 ⇒ a gain ≤ 1 for env < threshold.
                const gv: T = @floatCast(if (env < thr and thr > 0 and rat > 0)
                    std.math.pow(f32, env / thr, rat - 1.0)
                else
                    1.0);
                y.* = x * gv;
            }
            self.env = env;
        }
    };
}

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

fn S(x: f32) types.Sample(f32) {
    return .{ .ch = .{x} };
}

test "Vca: classifies as a Map with a gain param; ramps toward a set target" {
    const port = core.port;
    const V = Vca(f32num);
    try testing.expect(port.classify(V) == .Map);
    try testing.expect(port.ParamPort(V, "gain").Elem == types.Scalar(f32));

    var v: V = .{};
    v.setParam(0, 0.0); // glide gain 1 → 0
    var in: [4]types.Sample(f32) = @splat(S(1));
    var out: [4]types.Sample(f32) = undefined;
    v.process(&in, &out);
    // Linear glide: g_i = 1 + (i+1)·(0-1)/4 = {0.75, 0.5, 0.25, 0.0}.
    try testing.expectApproxEqAbs(@as(f32, 0.75), out[0].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[3].ch[0], 1e-6);
    try testing.expectEqual(@as(f32, 0.0), v.ramp.value); // snapped to target
}

test "Agc: silence stays silent; a hot block is pulled toward the target" {
    var agc: Agc(f32num) = .{ .target = 0.25, .rate = 1.0, .max_gain = 8.0 };
    // A loud block (rms 1.0) with instant adaptation → gain heads toward 0.25.
    var in: [64]types.Sample(f32) = @splat(S(1));
    var out: [64]types.Sample(f32) = undefined;
    agc.process(&in, &out);
    // After a full one-pole step (rate=1) the smoothed gain is the desired 0.25.
    try testing.expectApproxEqAbs(@as(f32, 0.25), agc.ramp.value, 1e-6);
    // Silence: desired gain clamps to max_gain, but x=0 → output stays 0 (no blow-up).
    var sil: [64]types.Sample(f32) = @splat(S(0));
    var sout: [64]types.Sample(f32) = undefined;
    agc.process(&sil, &sout);
    for (sout) |s| try testing.expectEqual(@as(f32, 0), s.ch[0]);
}

test "AgcController: emits a make-up gain Scalar, broadcast across the buffer" {
    const port = core.port;
    const C = AgcController(f32num);
    try testing.expect(port.classify(C) == .Map);
    try testing.expect(port.MapOutPort(C).Elem == types.Scalar(f32));
    try testing.expect(!comptime port.isSource(C)); // it reads audio

    var c: C = .{ .target = 0.5, .rate = 1.0 };
    var in: [16]types.Sample(f32) = @splat(S(0.25)); // rms 0.25 → desired 2.0
    var out: [16]types.Scalar(f32) = undefined;
    c.process(&in, &out);
    for (out) |o| try testing.expectApproxEqAbs(@as(f32, 2.0), o.value, 1e-6);
}

test "PowerGate: hysteresis — opens above open_threshold, holds, closes below close" {
    var gate: PowerGate(f32num) = .{ .open_threshold = 0.1, .close_threshold = 0.01 };
    var out: [8]types.Scalar(f32) = undefined;

    // Quiet (power 0.0025) → stays closed.
    var quiet: [8]types.Sample(f32) = @splat(S(0.05));
    gate.process(&quiet, &out);
    try testing.expectEqual(@as(f32, 0), out[0].value);

    // Loud (power 0.25 > open) → opens.
    var loud: [8]types.Sample(f32) = @splat(S(0.5));
    gate.process(&loud, &out);
    try testing.expectEqual(@as(f32, 1), out[0].value);

    // Mid (power 0.04, BETWEEN close 0.01 and open 0.1) → hysteresis HOLDS open
    // (a fresh, closed gate at this level would NOT open — the hold is the point).
    var mid: [8]types.Sample(f32) = @splat(S(0.2));
    gate.process(&mid, &out);
    try testing.expectEqual(@as(f32, 1), out[0].value);

    // Quiet again (power 0.0025 < close 0.01) → closes.
    gate.process(&quiet, &out);
    try testing.expectEqual(@as(f32, 0), out[0].value);
}

test "Compressor: passes below threshold, attenuates a hot signal above it" {
    var comp = Compressor(f32num){ .threshold = 0.5, .ratio = 4.0, .attack = 1.0, .release = 1.0 };
    // A steady 0.25 amplitude (below threshold) passes unchanged once the envelope
    // settles (instant attack/release here).
    var quiet: [32]types.Sample(f32) = @splat(S(0.25));
    var qout: [32]types.Sample(f32) = undefined;
    comp.process(&quiet, &qout);
    try testing.expectApproxEqAbs(@as(f32, 0.25), qout[31].ch[0], 1e-6); // unity gain below threshold

    // A steady 1.0 amplitude (above threshold 0.5) is attenuated: gain =
    // (1.0/0.5)^(1/4 − 1) = 2^(−0.75) ≈ 0.5946, so output ≈ 0.5946.
    var hot: [32]types.Sample(f32) = @splat(S(1.0));
    var hout: [32]types.Sample(f32) = undefined;
    comp.process(&hot, &hout);
    const want = std.math.pow(f32, 2.0, -0.75);
    try testing.expectApproxEqAbs(want, hout[31].ch[0], 1e-5);
    try testing.expect(hout[31].ch[0] < 1.0); // genuinely attenuated
}

test "CompressorController: emits unity below threshold, a reduction above it" {
    const port = core.port;
    const C = CompressorController(f32num);
    try testing.expect(port.classify(C) == .Map);
    try testing.expect(port.MapOutPort(C).Elem == types.Scalar(f32));

    var c = C{ .threshold = 0.5, .ratio = 4.0, .attack = 1.0, .release = 1.0 };
    var quiet: [16]types.Sample(f32) = @splat(S(0.25));
    var out: [16]types.Scalar(f32) = undefined;
    c.process(&quiet, &out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].value, 1e-6);

    var hot: [16]types.Sample(f32) = @splat(S(1.0));
    c.process(&hot, &out);
    try testing.expectApproxEqAbs(std.math.pow(f32, 2.0, -0.75), out[0].value, 1e-5);
}

// ---------------------------------------------------------------------------
// Dynamics gaps: Limiter, Expander. Tests encode the defining guarantee of each
// block (Rule 9: WHY, not just WHAT) — the brick wall and the downward-expansion
// direction.
// ---------------------------------------------------------------------------

test "Limiter: classifies as a Map with threshold/release/attack params; not aliasing-safe" {
    const port = core.port;
    const L = Limiter(f32num);
    try testing.expect(port.classify(L) == .Map);
    try testing.expect(port.ParamPort(L, "threshold").Elem == types.Scalar(f32));
    try testing.expect(port.ParamPort(L, "release").Elem == types.Scalar(f32));
    try testing.expect(port.ParamPort(L, "attack").Elem == types.Scalar(f32));
    // Stateful envelope follower ⇒ the colorer must NOT run it in place.
    try testing.expect(!@hasDecl(L, "aliasing_safe"));
}

test "Limiter: brick wall — a loud steady input is held at the threshold ceiling" {
    // Instant attack/release (coeff 1.0) makes the envelope equal |x| each sample,
    // so the steady-state guarantee is exact and testable without settling lag.
    var lim = Limiter(f32num){
        .threshold = control.Param.init(0.5),
        .attack = control.Param.init(1.0),
        .release = control.Param.init(1.0),
    };
    // A hot 1.0 input (env = 1.0 > 0.5): gain = 0.5/1.0 = 0.5, output = 0.5 = ceiling.
    var hot: [64]types.Sample(f32) = @splat(S(1.0));
    var hout: [64]types.Sample(f32) = undefined;
    lim.process(&hot, &hout);
    // No sample exceeds the ceiling, and the steady level sits AT it (true limiting,
    // not mere attenuation): peak ≤ threshold and the tail equals it.
    var peak: f32 = 0;
    for (hout) |s| peak = @max(peak, @abs(s.ch[0]));
    try testing.expect(peak <= 0.5 + 1e-6); // brick wall: never above the ceiling
    try testing.expectApproxEqAbs(@as(f32, 0.5), hout[63].ch[0], 1e-6);

    // A quiet 0.25 input (env = 0.25 < 0.5) passes at unity — below the wall is untouched.
    var quiet: [16]types.Sample(f32) = @splat(S(0.25));
    var qout: [16]types.Sample(f32) = undefined;
    lim.process(&quiet, &qout);
    try testing.expectApproxEqAbs(@as(f32, 0.25), qout[15].ch[0], 1e-6);
}

test "Expander: classifies as a Map with four params; not aliasing-safe" {
    const port = core.port;
    const E = Expander(f32num);
    try testing.expect(port.classify(E) == .Map);
    try testing.expect(port.ParamPort(E, "threshold").Elem == types.Scalar(f32));
    try testing.expect(port.ParamPort(E, "ratio").Elem == types.Scalar(f32));
    try testing.expect(port.ParamPort(E, "attack").Elem == types.Scalar(f32));
    try testing.expect(port.ParamPort(E, "release").Elem == types.Scalar(f32));
    try testing.expect(!@hasDecl(E, "aliasing_safe"));
}

test "Expander: attenuates a quiet signal below threshold, passes a loud one ~unchanged" {
    // Instant envelope (coeff 1.0) so env = |x| each sample and the law is exact.
    var exp = Expander(f32num){
        .threshold = control.Param.init(0.5),
        .ratio = control.Param.init(2.0),
        .attack = control.Param.init(1.0),
        .release = control.Param.init(1.0),
    };
    // Quiet 0.25 (< threshold 0.5): gain = (0.25/0.5)^(2−1) = 0.5, output = 0.125.
    // The DEFINING direction of a downward expander: quiet gets quieter.
    var quiet: [32]types.Sample(f32) = @splat(S(0.25));
    var qout: [32]types.Sample(f32) = undefined;
    exp.process(&quiet, &qout);
    try testing.expectApproxEqAbs(@as(f32, 0.125), qout[31].ch[0], 1e-6);
    try testing.expect(qout[31].ch[0] < 0.25); // genuinely attenuated below threshold

    // Loud 0.8 (> threshold): passes at unity (above the threshold is the pass band).
    var loud: [16]types.Sample(f32) = @splat(S(0.8));
    var lout: [16]types.Sample(f32) = undefined;
    exp.process(&loud, &lout);
    try testing.expectApproxEqAbs(@as(f32, 0.8), lout[15].ch[0], 1e-6);
}
