//! Envelope generators and feature→parameter maps — the control transforms that
//! drive parameter ports. `Adsr` and `FeatureMap`.
//!
//! Both are **control producers/transforms** over the control element `Scalar(f32)`
//! (see `gen.zig`'s header for the one-value-per-call / broadcast-storage model and
//! why a wired control edge is bit-identical to the external `set` verb). `Adsr` is
//! a zero-sample-input source whose *gate* arrives as a parameter port; `FeatureMap`
//! is a rate-1:1 `Scalar → Scalar` map that rescales a feature node's output into a
//! parameter's units (the body of a feature→param modulation chain).

const std = @import("std");
const core = @import("pan_core");
const types = core.types;

/// `Adsr` — a control-rate attack/decay/sustain/release envelope: a zero-sample-
/// input `Map` source emitting `Scalar(f32)` amplitude, with its **gate** delivered
/// through a parameter port (`adsr.param.gate`, or the external `set`/`schedule`
/// verbs — by the one-source rule a slot has exactly one driver, a wired edge XOR an
/// external set). A gate ≥ 0.5 starts attack→decay→sustain; a gate < 0.5 starts
/// release. The envelope integrates **per sample internally**, advancing `out.len`
/// samples per call so a segment crossover that falls mid-block lands at the right
/// place; it emits the block-start level (broadcast across the buffer), and the
/// consumer's per-block ramp interpolates between successive block-start levels
/// (zipper-free at control rate).
///
/// The rates are level-per-sample increments (author converts from seconds with
/// `1 / (seconds · sample_rate)`, the same block-data convention as the rest of the
/// library): `attack_inc` rises toward 1, `decay_inc` falls toward `sustain`,
/// `release_inc` falls toward 0.
pub const Adsr = struct {
    const Self = @This();

    /// The gate parameter port: ≥ 0.5 is "note held", < 0.5 is "released".
    pub const params = .{ .gate = types.Scalar(f32) };

    pub const Stage = enum { idle, attack, decay, sustain, release };

    /// Current envelope level in `[0, 1]`. Persistent across calls.
    level: f32 = 0,
    stage: Stage = .idle,
    /// Last gate value seen (held between updates), for edge detection.
    gate: f32 = 0,

    /// Per-sample level increments and the sustain plateau.
    attack_inc: f32 = 1,
    decay_inc: f32 = 1,
    sustain: f32 = 1,
    release_inc: f32 = 1,

    /// Receive the gate from the control plane (a wired edge via `applyParamInputs`,
    /// or `set`/`schedule`). Slot 0 is `gate` (declaration order of `params`).
    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        if (slot == 0) self.gate = value;
    }

    /// Advance the envelope one sample, returning the new level. Pure function of
    /// `(stage, level, gate)`; transitions on segment completion.
    fn step(self: *Self) void {
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

    pub fn process(self: *Self, out: []types.Scalar(f32)) void {
        // Apply the gate edge to the stage BEFORE sampling this block's level, so a
        // note-on retriggers attack from the current (possibly non-zero) level.
        const held = self.gate >= 0.5;
        if (held) {
            if (self.stage == .idle or self.stage == .release) self.stage = .attack;
        } else {
            if (self.stage != .idle) self.stage = .release;
        }

        // Emit the block-start level (one control value, broadcast for the guard).
        const v = self.level;
        for (out) |*o| o.value = v;

        // Advance the envelope across the block so the NEXT call emits the level at
        // sample out.len, capturing any mid-block segment crossover.
        var i: usize = 0;
        while (i < out.len) : (i += 1) self.step();
    }
};

/// `FeatureMap` — an affine rescale of one control stream into another's units:
/// `out = clamp(scale · in + bias, lo, hi)`. A rate-1:1 `Map` over `Scalar(f32)`
/// (M1 holds: `out.len == in.len`), it is the body of a **feature→parameter chain**
/// — a `feat.zig` node emits a `Scalar(f32)` descriptor (e.g. spectral centroid),
/// `FeatureMap` scales it into Hz/dB/etc., and its output wires to a block's
/// `param.<name>`. Per-element and stateless, so it is `aliasing_safe` (the colorer
/// may run it in place). The clamp keeps a runaway feature from driving a parameter
/// out of its safe range (`lo`/`hi` default to ±inf — no clamp).
pub const FeatureMap = struct {
    const Self = @This();

    /// Per-element write from only the matching input element ⇒ in-place legal.
    pub const aliasing_safe = true;

    scale: f32 = 1,
    bias: f32 = 0,
    lo: f32 = -std.math.inf(f32),
    hi: f32 = std.math.inf(f32),

    pub fn process(self: *Self, in: []const types.Scalar(f32), out: []types.Scalar(f32)) void {
        for (in, out) |x, *o| {
            const y = self.scale * x.value + self.bias;
            o.value = std.math.clamp(y, self.lo, self.hi);
        }
    }
};

test "Adsr: classifies as a zero-input Scalar source with a gate param" {
    const port = core.port;
    try std.testing.expect(port.classify(Adsr) == .Map);
    try std.testing.expect(comptime port.isSource(Adsr));
    try std.testing.expect(port.MapOutPort(Adsr).Elem == types.Scalar(f32));
    try std.testing.expect(port.ParamPort(Adsr, "gate").Elem == types.Scalar(f32));
}

test "Adsr: gate-on climbs attack→decay→sustain; gate-off releases to zero" {
    // attack rises 0.25/sample, decay falls 0.25/sample toward sustain 0.5,
    // release falls 0.25/sample. Block size 1 so each call advances one sample.
    var env: Adsr = .{ .attack_inc = 0.25, .decay_inc = 0.25, .sustain = 0.5, .release_inc = 0.25 };
    var out: [1]types.Scalar(f32) = undefined;

    env.setParam(0, 1.0); // gate on
    // Each process emits the block-start level then advances one sample.
    env.process(&out); // emit 0.0, then attack to 0.25
    try std.testing.expectEqual(@as(f32, 0.0), out[0].value);
    env.process(&out); // emit 0.25, attack to 0.5
    try std.testing.expectEqual(@as(f32, 0.25), out[0].value);
    env.process(&out); // emit 0.5, attack to 0.75
    try std.testing.expectEqual(@as(f32, 0.5), out[0].value);
    env.process(&out); // emit 0.75, attack to 1.0 → switch to decay
    try std.testing.expectEqual(@as(f32, 0.75), out[0].value);
    try std.testing.expect(env.stage == .decay);
    env.process(&out); // emit 1.0, decay to 0.75
    try std.testing.expectEqual(@as(f32, 1.0), out[0].value);
    env.process(&out); // emit 0.75, decay to 0.5 → sustain
    try std.testing.expectEqual(@as(f32, 0.75), out[0].value);
    try std.testing.expect(env.stage == .sustain);
    env.process(&out); // emit 0.5 (sustain holds)
    try std.testing.expectEqual(@as(f32, 0.5), out[0].value);

    env.setParam(0, 0.0); // gate off → release
    env.process(&out); // emit 0.5, release to 0.25
    try std.testing.expectEqual(@as(f32, 0.5), out[0].value);
    try std.testing.expect(env.stage == .release);
    env.process(&out); // emit 0.25, release to 0.0
    env.process(&out); // emit 0.0 → idle
    try std.testing.expect(env.stage == .idle);
    try std.testing.expectEqual(@as(f32, 0.0), env.level);
}

test "FeatureMap: affine rescale with clamp, 1:1 and aliasing-safe" {
    const port = core.port;
    try std.testing.expect(port.classify(FeatureMap) == .Map);
    try std.testing.expect(FeatureMap.aliasing_safe);

    var fm: FeatureMap = .{ .scale = 1000, .bias = 200, .lo = 0, .hi = 5000 };
    const in = [_]types.Scalar(f32){ .{ .value = 0 }, .{ .value = 1 }, .{ .value = 10 } };
    var out: [3]types.Scalar(f32) = undefined;
    fm.process(&in, &out);
    try std.testing.expectEqual(@as(f32, 200), out[0].value); // 0·1000+200
    try std.testing.expectEqual(@as(f32, 1200), out[1].value); // 1·1000+200
    try std.testing.expectEqual(@as(f32, 5000), out[2].value); // 10·1000+200 clamped to hi
}
