//! Delay-line fused tight-feedback kernels — feedback combs, all-passes, chorus,
//! flanger, and the Karplus-Strong plucked string.
//!
//! Each is authored as a single rate-1:1 `Map` block whose `process` runs the
//! per-sample feedback loop internally over fixed persistent state. The `z⁻¹`
//! lives *inside* the kernel, per sample, so the feedback is sample-accurate (not
//! quantized to the colorer's block granularity). The trade is explicit: you
//! forfeit scheduler visibility — the loop is opaque to the colorer, which cannot
//! fuse or split across it — in exchange for sample-accuracy. Each kernel declares
//! `delay_len` (its internal ring length) so it registers as a delay element (a
//! feedback cycle built from it passes the SCC-has-delay check, and a self-loop is
//! causal because the per-sample state supplies the `z⁻¹`). They are NOT
//! `aliasing_safe`: the state-dependent read-before-write ordering means an
//! in-place output would corrupt the recurrence.
//!
//! `noalias` placement: each kernel's `process` reads its whole input plane and
//! writes a distinct output plane; because none declares `aliasing_safe`, the
//! colorer never coalesces output onto input, so the in/out pool buffers are
//! provably distinct — the `noalias` qualifiers state a fact the commit pass
//! already guarantees. Float-only (a fixed-point feedback kernel needs the
//! per-kernel DF1/wide-accumulator coefficient-scaling treatment the fixed-point
//! Biquad uses, not yet ported here), declared loud via `requireFloat`.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;
const numeric = core.numeric;

const fxc = @import("fx_common.zig");
const scalarsConst = fxc.scalarsConst;
const scalars = fxc.scalars;
const requireFloat = fxc.requireFloat;

/// `Comb(num, max_delay)` — a feedback comb filter: `y[n] = x[n] + g·y[n−D]`,
/// `D ≤ max_delay`. For `|g| < 1` the impulse response is a decaying train of
/// echoes spaced `D` samples apart — the elementary unit of Schroeder
/// reverberation. The recurrence is per-sample, so the feedback is sample-accurate
/// and the whole loop is one `Map` (no graph feedback edge needed).
pub fn Comb(comptime num: numeric.Numeric, comptime max_delay: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (max_delay == 0) @compileError("pan: Comb max_delay must be >= 1");
    return struct {
        const Self = @This();

        /// Internal ring length — registers this as a delay element (SCC-has-delay).
        pub const delay_len: usize = max_delay;
        pub const state_size: usize = @sizeOf(usize) * 2 + @sizeOf(T);

        ring: [max_delay]T = @splat(0),
        /// Active delay in samples (`1 ≤ delay ≤ max_delay`).
        delay: usize = max_delay,
        /// Feedback gain `g` (set `|g| < 1` for a stable, decaying tail).
        feedback: T = 0,
        pos: usize = 0,

        pub fn process(self: *Self, noalias in: []const types.Sample(T), noalias out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const g = self.feedback;
            const d = self.delay;
            var p = self.pos;
            for (xs, ys) |x, *y| {
                const delayed = self.ring[p]; // y[n-D]
                const yv = x + g * delayed; // feedback comb recurrence
                self.ring[p] = yv;
                p += 1;
                if (p >= d) p = 0;
                y.* = yv;
            }
            self.pos = p;
        }
    };
}

/// `Allpass(num, max_delay)` — a Schroeder all-pass section: flat magnitude
/// response, frequency-dependent phase delay. Paired after a bank of `Comb`s it
/// turns their periodic echo train into the dense, colourless decay of a
/// reverberator. Standard form:
///
///     v        = ring[p]                 // x[n-D] + g·v[n-D] stored last time
///     y[n]     = −g·x[n] + v
///     ring[p]  = x[n] + g·y[n]
pub fn Allpass(comptime num: numeric.Numeric, comptime max_delay: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (max_delay == 0) @compileError("pan: Allpass max_delay must be >= 1");
    return struct {
        const Self = @This();

        pub const delay_len: usize = max_delay;
        pub const state_size: usize = @sizeOf(usize) * 2 + @sizeOf(T);

        ring: [max_delay]T = @splat(0),
        delay: usize = max_delay,
        /// All-pass coefficient `g` (`|g| < 1`; 0.5–0.7 are typical reverb values).
        feedback: T = 0.5,
        pos: usize = 0,

        pub fn process(self: *Self, noalias in: []const types.Sample(T), noalias out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const g = self.feedback;
            const d = self.delay;
            var p = self.pos;
            for (xs, ys) |x, *y| {
                const v = self.ring[p];
                const yv = -g * x + v;
                self.ring[p] = x + g * yv;
                p += 1;
                if (p >= d) p = 0;
                y.* = yv;
            }
            self.pos = p;
        }
    };
}

/// `Chorus(num, max_delay)` — a single-voice chorus: the dry input is blended with
/// a copy read from a delay line whose length is slowly swept by a low-frequency
/// oscillator, producing the small time-varying pitch detune that thickens a sound.
/// The swept delay is read with LINEAR INTERPOLATION (a fractional delay), and the
/// sweep is `delay = base_delay + depth·sin(2π·phase)`. `out = (1−mix)·x + mix·wet`.
/// Rate-1:1 with persistent delay state ⇒ a `Map` (and a delay element, so a cycle
/// built through it is causal). Float-only.
pub fn Chorus(comptime num: numeric.Numeric, comptime max_delay: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (max_delay < 4) @compileError("pan: Chorus max_delay must be >= 4");
    return struct {
        const Self = @This();

        /// Internal ring length — registers this as a delay element (SCC-has-delay).
        pub const delay_len: usize = max_delay;

        ring: [max_delay]T = @splat(0),
        /// Centre (average) swept delay, in samples.
        base_delay: f32 = 0,
        /// Sweep depth in samples (peak deviation around `base_delay`); the realised
        /// delay is clamped to `[1, max_delay−2]` so the interpolation taps stay valid.
        depth: f32 = 0,
        /// LFO rate as a NORMALIZED frequency (cycles per sample = Hz / sample_rate).
        rate: f32 = 0,
        /// Dry/wet blend in `[0, 1]` (`0` = dry only, `1` = wet only).
        mix: f32 = 0.5,
        pos: usize = 0,
        phase: f32 = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const m: T = @floatCast(std.math.clamp(self.mix, 0.0, 1.0));
            var p = self.pos;
            var ph = self.phase;
            for (xs, ys) |x, *y| {
                const lfo = @sin(2.0 * std.math.pi * ph);
                const d = std.math.clamp(self.base_delay + self.depth * lfo, 1.0, @as(f32, @floatFromInt(max_delay - 2)));
                const k0: usize = @intFromFloat(@floor(d));
                const frac: T = @floatCast(d - @floor(d));
                // Read the fractional delayed sample from PAST slots (d ≥ 1 ⇒ the
                // current write slot is never one of them), then write the input.
                const a = self.ring[(p + max_delay - k0) % max_delay];
                const b = self.ring[(p + max_delay - k0 - 1) % max_delay];
                const wet = a * (1.0 - frac) + b * frac;
                self.ring[p] = x;
                y.* = (1.0 - m) * x + m * wet;
                p = (p + 1) % max_delay;
                ph += self.rate;
                if (ph >= 1.0) ph -= 1.0;
            }
            self.pos = p;
            self.phase = ph;
        }
    };
}

/// `Flanger(num, max_delay)` — like `Chorus` but with a SHORT swept delay and a
/// FEEDBACK path, so the comb notches it creates are deep and resonant (the
/// characteristic sweeping "jet" sound). The fed-back wet signal is written into
/// the ring: `ring[p] = x + feedback·wet`; `out = (1−mix)·x + mix·wet`. The internal
/// feedback makes it a fused tight-feedback kernel — keep `|feedback| < 1` for a
/// stable, decaying response. Rate-1:1 with persistent state ⇒ a `Map`. Float-only.
pub fn Flanger(comptime num: numeric.Numeric, comptime max_delay: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (max_delay < 4) @compileError("pan: Flanger max_delay must be >= 4");
    return struct {
        const Self = @This();

        pub const delay_len: usize = max_delay;

        ring: [max_delay]T = @splat(0),
        base_delay: f32 = 0,
        depth: f32 = 0,
        rate: f32 = 0,
        mix: f32 = 0.5,
        /// Feedback gain in the swept-delay path (`|feedback| < 1` for stability).
        feedback: T = 0,
        pos: usize = 0,
        phase: f32 = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const m: T = @floatCast(std.math.clamp(self.mix, 0.0, 1.0));
            const fb = self.feedback;
            var p = self.pos;
            var ph = self.phase;
            for (xs, ys) |x, *y| {
                const lfo = @sin(2.0 * std.math.pi * ph);
                const d = std.math.clamp(self.base_delay + self.depth * lfo, 1.0, @as(f32, @floatFromInt(max_delay - 2)));
                const k0: usize = @intFromFloat(@floor(d));
                const frac: T = @floatCast(d - @floor(d));
                const a = self.ring[(p + max_delay - k0) % max_delay];
                const b = self.ring[(p + max_delay - k0 - 1) % max_delay];
                const wet = a * (1.0 - frac) + b * frac;
                self.ring[p] = x + fb * wet; // feedback path
                y.* = (1.0 - m) * x + m * wet;
                p = (p + 1) % max_delay;
                ph += self.rate;
                if (ph >= 1.0) ph -= 1.0;
            }
            self.pos = p;
            self.phase = ph;
        }
    };
}

/// `KarplusStrong(num, max_delay)` — the plucked-string algorithm: a delay line of
/// `D` samples with a two-tap averaging low-pass in the feedback path,
/// `y[n] = x[n] + 0.5·damping·(y[n−D] + y[n−D−1])`. An impulse / noise burst at
/// the input excites a decaying, gently-darkening harmonic tone at `Fs/D` Hz — the
/// archetypal fused tight-feedback kernel.
pub fn KarplusStrong(comptime num: numeric.Numeric, comptime max_delay: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (max_delay < 2) @compileError("pan: KarplusStrong max_delay must be >= 2 (two-tap lowpass)");
    return struct {
        const Self = @This();

        pub const delay_len: usize = max_delay;
        pub const state_size: usize = @sizeOf(usize) * 2 + @sizeOf(T) * 2;

        ring: [max_delay]T = @splat(0),
        delay: usize = max_delay,
        /// Loop decay (`≤ 1`): 1.0 rings nearly forever, lower darkens/shortens.
        damping: T = 0.996,
        pos: usize = 0,
        /// The previous loop output, for the two-tap averaging low-pass.
        prev: T = 0,

        pub fn process(self: *Self, noalias in: []const types.Sample(T), noalias out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const d = self.delay;
            const k = self.damping;
            var p = self.pos;
            var prev = self.prev;
            for (xs, ys) |x, *y| {
                const tap = self.ring[p]; // y[n-D]
                const filtered = 0.5 * k * (tap + prev); // averaging lowpass in the loop
                const yv = x + filtered;
                self.ring[p] = yv;
                prev = tap;
                p += 1;
                if (p >= d) p = 0;
                y.* = yv;
            }
            self.pos = p;
            self.prev = prev;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — compile-coverage + a couple of invariants; the autonomous Yoneda suite
// owns the full matrix (impulse-response decay vs an oracle, SCC acceptance,
// FTZ/denormal behaviour, sample-accuracy of the internal z⁻¹).
// ---------------------------------------------------------------------------

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

fn S(x: f32) types.Sample(f32) {
    return .{ .ch = .{x} };
}

test "Comb impulse response is a decaying echo train spaced D apart" {
    var comb = Comb(f32num, 4){ .delay = 3, .feedback = 0.5 };
    var in: [10]types.Sample(f32) = @splat(S(0));
    in[0] = S(1); // unit impulse
    var out: [10]types.Sample(f32) = undefined;
    comb.process(&in, &out);
    // y[n] = x[n] + 0.5 y[n-3]: echoes at 0,3,6,9 with gains 1, .5, .25, .125.
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[3].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[6].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.125), out[9].ch[0], 1e-6);
    // Off-echo samples are silent.
    try testing.expectEqual(@as(f32, 0), out[1].ch[0]);
    try testing.expectEqual(@as(f32, 0), out[5].ch[0]);
}

test "Comb tail decays (stable for |g|<1) and carries state across calls" {
    var comb = Comb(f32num, 8){ .delay = 5, .feedback = 0.7 };
    var in: [5]types.Sample(f32) = @splat(S(0));
    in[0] = S(1);
    var out: [5]types.Sample(f32) = undefined;
    comb.process(&in, &out);
    // The first echo has not yet recirculated; energy is still in the ring.
    var in2: [10]types.Sample(f32) = @splat(S(0));
    var out2: [10]types.Sample(f32) = undefined;
    comb.process(&in2, &out2);
    // The delayed impulse emerges on the next call (state carried) and is < 1.
    var peak: f32 = 0;
    for (out2) |s| peak = @max(peak, @abs(s.ch[0]));
    try testing.expect(peak > 0 and peak < 1.0);
}

test "Allpass passes a delayed/dispersed signal; energy is bounded" {
    var ap = Allpass(f32num, 4){ .delay = 2, .feedback = 0.5 };
    var in: [8]types.Sample(f32) = @splat(S(0));
    in[0] = S(1);
    var out: [8]types.Sample(f32) = undefined;
    ap.process(&in, &out);
    // Immediate output is -g·x = -0.5 (the through path), then the recirculation.
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[0].ch[0], 1e-6);
    var energy: f32 = 0;
    for (out) |s| energy += s.ch[0] * s.ch[0];
    try testing.expect(energy > 0 and energy < 4.0);
}

test "fused kernels classify as delay elements and are not aliasing_safe" {
    const port = core.port;
    try testing.expect(port.classify(Comb(f32num, 64)) == .Map);
    try testing.expect(@hasDecl(Comb(f32num, 64), "delay_len"));
    try testing.expect(!@hasDecl(Comb(f32num, 64), "aliasing_safe"));
    try testing.expect(@hasDecl(KarplusStrong(f32num, 64), "delay_len"));
    try testing.expect(!@hasDecl(Allpass(f32num, 64), "aliasing_safe"));
}

test "Chorus/Flanger classify as delay-element Maps; mix=0 is the dry signal" {
    const port = core.port;
    try testing.expect(port.classify(Chorus(f32num, 64)) == .Map);
    try testing.expect(port.classify(Flanger(f32num, 64)) == .Map);
    try testing.expect(@hasDecl(Chorus(f32num, 64), "delay_len"));
    try testing.expect(@hasDecl(Flanger(f32num, 64), "delay_len"));
    // mix=0 ⇒ pure dry passthrough, regardless of the sweep.
    var ch = Chorus(f32num, 64){ .base_delay = 10, .depth = 4, .rate = 0.01, .mix = 0 };
    var in: [16]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@floatFromInt(i + 1));
    var out: [16]types.Sample(f32) = undefined;
    ch.process(&in, &out);
    for (in, out) |x, y| try testing.expectApproxEqAbs(x.ch[0], y.ch[0], 1e-6);
}

test "Chorus with a static delay (depth=0) is a hand-computable dry+wet mix" {
    // depth=0 ⇒ a fixed integer delay D; wet[n] = x[n−D], out = (1−m)x + m·x[n−D].
    const D = 5;
    var ch = Chorus(f32num, 64){ .base_delay = D, .depth = 0, .rate = 0, .mix = 0.5 };
    var in: [12]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@floatFromInt(i + 1));
    var out: [12]types.Sample(f32) = undefined;
    ch.process(&in, &out);
    for (out, 0..) |y, n| {
        const dry = in[n].ch[0];
        const wet: f32 = if (n >= D) in[n - D].ch[0] else 0; // ring pre-rolls with zeros
        try testing.expectApproxEqAbs(0.5 * dry + 0.5 * wet, y.ch[0], 1e-5);
    }
}

test "Flanger feedback stays bounded for |feedback|<1 and reduces to Chorus at feedback=0" {
    const D = 4;
    var fl = Flanger(f32num, 64){ .base_delay = D, .depth = 0, .rate = 0, .mix = 0.5, .feedback = 0 };
    var ch = Chorus(f32num, 64){ .base_delay = D, .depth = 0, .rate = 0, .mix = 0.5 };
    var in: [10]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(@floatFromInt(i + 1));
    var of: [10]types.Sample(f32) = undefined;
    var oc: [10]types.Sample(f32) = undefined;
    fl.process(&in, &of);
    ch.process(&in, &oc);
    for (of, oc) |a, b| try testing.expectApproxEqAbs(a.ch[0], b.ch[0], 1e-6); // fb=0 ⇒ identical
    // With feedback the output stays finite and bounded for a unit-impulse excitation.
    var fl2 = Flanger(f32num, 64){ .base_delay = D, .depth = 0, .rate = 0, .mix = 1.0, .feedback = 0.7 };
    var imp: [200]types.Sample(f32) = [_]types.Sample(f32){S(0)} ** 200;
    imp[0] = S(1);
    var o2: [200]types.Sample(f32) = undefined;
    fl2.process(&imp, &o2);
    for (o2) |y| try testing.expect(@abs(y.ch[0]) < 10.0); // decaying, never blows up
}

test "KarplusStrong sustains a noise burst into a decaying tone" {
    var ks = KarplusStrong(f32num, 16){ .delay = 8, .damping = 0.99 };
    var in: [8]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(if (i % 2 == 0) @as(f32, 0.5) else -0.5); // excitation
    var out: [8]types.Sample(f32) = undefined;
    ks.process(&in, &out);
    // After the excitation, the loop keeps ringing (non-silent) on a zero input.
    var in2: [32]types.Sample(f32) = @splat(S(0));
    var out2: [32]types.Sample(f32) = undefined;
    ks.process(&in2, &out2);
    var late: f32 = 0;
    for (out2) |s| late = @max(late, @abs(s.ch[0]));
    try testing.expect(late > 0.01); // still sounding, not dead silence
}
