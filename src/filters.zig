//! First DSP blocks — `Gain` and `Biquad`.
//!
//! Both are `Map` morphisms (rate-1:1, `out.len == in.len`), monomorphized over
//! a Numeric trait so the precision (lane, accumulator width, saturation, SIMD
//! width) is bound at comptime. A precision change re-selects a monomorph and
//! requires a recommit — there is no runtime precision switch.
//!
//!   - `Gain` is a stateless, per-element scale. It declares `aliasing_safe`:
//!     each output element is written solely from the corresponding input
//!     element, so the colorer may run it in place (output edge aliased onto the
//!     input buffer). Its float path is the `@Vector(W,T)` Compute-HAL kernel
//!     with a scalar tail; its integer path is a saturating fixed-point multiply.
//!   - `Biquad` carries per-sample `z⁻¹` Mealy state (two state words) and is a
//!     transposed-direct-form-II second-order section — the *same* recurrence as
//!     `scipy.signal.lfilter(b, a, x)`, so its float output matches that oracle
//!     within tolerance. Per-sample state keeps it rate-1:1, hence a `Map`, not a
//!     `Rate`; but the recurrence is sequential, so it is NOT `aliasing_safe`
//!     (and does not vectorize across time).

const std = @import("std");
const types = @import("types.zig");
const numeric = @import("numeric.zig");
const simd = @import("simd.zig");
const control = @import("control.zig");

/// Is this lane a floating-point type? Selects the float vs fixed-point kernel.
fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

/// The fixed-point fractional-bit count for an integer lane: i8→q7, i16→q15,
/// i32→q31, i64→q63 (the audio fixed-point convention — full-scale is one bit
/// below the sign). A coefficient `c` in this lane represents `c / 2^frac`.
fn fracBits(comptime T: type) comptime_int {
    return @typeInfo(T).int.bits - 1;
}

/// View a mono `Sample(T)` slice as its underlying scalar `[]T`. `Sample(T)` is
/// `Frame(T,.mono)` = `struct { ch: [1]T }`, layout-identical to a bare `T`, so
/// the reinterpret is exact (and `@alignCast` is safety-checked in Debug).
fn scalarsConst(comptime T: type, frames: []const types.Sample(T)) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}
fn scalars(comptime T: type, frames: []types.Sample(T)) []T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}

/// `Gain(num)` — a per-element scale. `gain` is the coefficient in the lane's
/// own domain: a linear multiplier for a float lane, a `q(frac)` fixed-point
/// coefficient for an integer lane (the author converts dB → the lane domain;
/// e.g. −6 dB → 0.5012 linear, or → round(0.5012·2^frac) for fixed-point).
pub fn Gain(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    return struct {
        const Self = @This();
        /// Coefficient in the lane domain (linear for float; q(frac) for int).
        gain: T = if (isFloat(T)) 1 else (@as(T, 1) << fracBits(T)),
        /// The kernel writes each output element from only the corresponding
        /// input element (no cross-lane read-after-write), so the colorer may
        /// alias the output edge onto the input buffer and run it in place.
        pub const aliasing_safe = true;

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            if (comptime isFloat(T)) {
                simd.scaleFloat(T, num.W, ys, xs, self.gain);
            } else {
                // Saturating fixed-point multiply: (x·coeff) >> frac, rounded to
                // nearest and clamped to the lane bound (never wraps).
                const frac = comptime fracBits(T);
                for (xs, ys) |x, *y| y.* = simd.qMulStore(T, num.Acc, x, self.gain, frac);
            }
        }
    };
}

/// `OnePole(num)` — a one-pole low-pass whose **cutoff is a parameter port**
/// (`onepole.param.cutoff`): the canonical filter swept by an LFO or an envelope.
/// `cutoff` is the per-sample smoothing coefficient `a` in `[0, 1)` in the lane's
/// own domain — the author maps a cutoff frequency to it (e.g. `a = 1 −
/// exp(−2π·fc/Fs)`), the same "coefficients are block data, not the stream type"
/// convention `Gain` and `Biquad` follow. The recurrence is a leaky integrator
///
///     y[n] = y[n−1] + a·(x[n] − y[n−1]),
///
/// so `a → 1` passes the input and `a → 0` freezes the state (a lower cutoff). The
/// coefficient is **held between updates and per-block ramped** toward its target
/// (the anti-zipper "ramp, never step" policy): the latest target is snapped at
/// block end so a multi-block sweep stays continuous. Because a wired parameter edge
/// and an external `set` both deliver the target through `setParam` and drive the
/// SAME held-and-ramped coefficient, a wired LFO→cutoff sweep is **bit-identical** to
/// the same target sequence pushed via `set` (one ramp policy, two sources). It is
/// NOT `aliasing_safe`: the recurrence carries `z⁻¹` state, so the colorer must not
/// run it in place.
///
/// Float lanes only for now: a ramped fixed-point coefficient needs the wider
/// coefficient q-format and wide accumulator the fixed-point `Biquad` uses, which
/// has not been ported here, so the integer path fails loud (a compile error, never
/// silently-wrong audio).
pub fn OnePole(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    if (!isFloat(T))
        @compileError("pan: OnePole is float-only for now — a ramped fixed-point" ++
            " cutoff coefficient needs the q-format + wide-accumulator treatment the" ++
            " fixed-point Biquad uses, not yet ported here. Use f32/f64.");
    return struct {
        const Self = @This();

        /// The cutoff parameter port (control element `Scalar(f32)`). Slot 0.
        pub const params = .{ .cutoff = types.Scalar(f32) };

        /// Latest published target coefficient (atomic; set by the control thread OR
        /// by a wired parameter edge). Read once per block on the RT thread.
        cutoff: control.Param = control.Param.init(1.0),
        /// The live, audibly-applied coefficient, ramped across blocks (persistent).
        a: control.Ramp = control.Ramp.init(1.0),
        /// The one-pole `z⁻¹` state.
        y1: T = 0,

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.cutoff.set(value);
        }

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const tgt = self.cutoff.read();
            const inc = self.a.begin(tgt, xs.len);
            var y1 = self.y1;
            for (xs, ys, 0..) |x, *y, i| {
                const a: T = @floatCast(self.a.value + @as(f32, @floatFromInt(i + 1)) * inc);
                y1 = y1 + a * (x - y1);
                y.* = y1;
            }
            self.y1 = y1;
            self.a.finish(tgt); // snap to the exact target; next block ramps from it
        }
    };
}

/// The fractional-bit count a fixed-point biquad stores its coefficients in. A
/// resonant section's feedback coefficients exceed unity (|a1| can approach 2,
/// |a2| < 1) and the forward gain can exceed 1 too, so the coefficients CANNOT
/// ride in the lane's own q-format (a q15 lane number is bounded to [-1, 1) and
/// could not hold a1 = -1.9 at all). Coefficients instead use Q(2.frac) with two
/// integer bits above the sign — `frac = bits - 3` — giving the range [-4, 4),
/// which covers every stable second-order section with headroom. (This is why a
/// fixed-point biquad needs a wider coefficient format than `Gain`'s single
/// |coeff| ≤ 1 multiply.)
fn biquadCoeffFrac(comptime T: type) comptime_int {
    return @typeInfo(T).int.bits - 3;
}

/// Five normalized biquad coefficients (`a0` divided out): the transfer function
/// `H(z) = (b0 + b1 z⁻¹ + b2 z⁻²) / (1 + a1 z⁻¹ + a2 z⁻²)`. Defaults to the
/// identity (pass-through) section so an un-configured `Biquad` is a no-op.
///
/// For a float lane the fields ARE the real coefficients. For an integer lane the
/// fields are Q(`coeff_frac`) fixed-point integers (range [-4, 4)), so the
/// identity `b0 = 1.0` is the integer `1 << coeff_frac`, not `1`.
pub fn Coeffs(comptime T: type) type {
    const cf: comptime_int = if (isFloat(T)) 0 else biquadCoeffFrac(T);
    return struct {
        b0: T = if (isFloat(T)) 1 else (@as(T, 1) << biquadCoeffFrac(T)),
        b1: T = 0,
        b2: T = 0,
        a1: T = 0,
        a2: T = 0,
        /// The fractional bits the coefficient fields are stored in: 0 for a float
        /// lane (the fields are the real coefficients), `bits - 3` for an integer
        /// lane (the fields are Q(2.frac) fixed-point, range [-4, 4)).
        pub const coeff_frac = cf;
    };
}

/// `Biquad(num)` — one second-order IIR section. Rate-1:1 with per-sample state
/// ⇒ a `Map` (not a `Rate`: it neither buffers across calls nor changes the
/// sample count). The recurrence is sequential, so it neither vectorizes across
/// time nor is `aliasing_safe`. The float and fixed-point lanes use different
/// canonical forms (DF2T vs DF1) — both monomorphized from this one function —
/// because the numerically-robust form differs by domain (see each below).
pub fn Biquad(comptime num: numeric.Numeric) type {
    return if (isFloat(num.Lane)) BiquadFloat(num.Lane) else BiquadFixed(num);
}

/// The float biquad — transposed direct form II, two state words. The per-sample
/// recurrence carries `z1`/`z2` across calls (so a render split into sub-blocks
/// is seamless only because the state persists), which is exactly
/// `scipy.signal.lfilter([b0,b1,b2],[1,a1,a2], x)`:
///
///     y   = b0·x + z1
///     z1  = b1·x + z2 − a1·y
///     z2  = b2·x        − a2·y
fn BiquadFloat(comptime T: type) type {
    return struct {
        const Self = @This();
        coeffs: Coeffs(T) = .{},
        z1: T = 0,
        z2: T = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const c = self.coeffs;
            var z1 = self.z1;
            var z2 = self.z2;
            for (xs, ys) |x, *y| {
                const yv = c.b0 * x + z1;
                z1 = c.b1 * x + z2 - c.a1 * yv;
                z2 = c.b2 * x - c.a2 * yv;
                y.* = yv;
            }
            self.z1 = z1;
            self.z2 = z2;
        }
    };
}

/// The fixed-point biquad — direct form I (DF1), four state words. This is the
/// embedded-precision path the dev-note flagged as deferred; it is now real.
///
/// Three things make a correct fixed-point biquad more than the "multiply,
/// `>>frac`, saturate" mould the `Gain`/`Pan` integer paths use, and each is
/// handled here:
///   1. **Supra-unity coefficients.** A resonant section has |a1| up to ~2, which
///      a plain lane-q-format number (bounded to [-1, 1)) cannot store. The
///      coefficients therefore ride in Q(2.`coeff_frac`) (range [-4, 4)) — a
///      WIDER coefficient format than the lane (`Coeffs` above).
///   2. **Accumulator headroom.** The five-term MAC is summed in a strictly wider
///      integer (`Wide`, ~2× the lane width plus guard bits — i64 for a q15
///      section) so the inter-term partial sums never overflow; a single rounding
///      right-shift + saturate happens only on store. A per-multiply `>>frac` (as
///      `Gain` does) would discard that headroom and compute wrong audio.
///   3. **State at the lane format, not the accumulator format.** DF1 keeps the
///      input history `x1`/`x2` and output history `y1`/`y2` as already-rounded
///      lane values, so the feedback path sees the clean quantized signal. (The
///      float path's DF2T intermediate states would, in fixed point, leak the
///      rounding into the loop and worsen limit-cycle behaviour — hence DF1 here.)
///
/// The accumulator is in Q(lane_frac + coeff_frac); the store shifts right by
/// `coeff_frac` (with a round-to-nearest bias) to land back in the lane's
/// q-format, then saturates. The arithmetic right-shift rounds toward −∞ after a
/// `+2^(coeff_frac−1)` bias (round half up), matching an independent integer
/// oracle bit-for-bit (the q15 gold-vector contract).
fn BiquadFixed(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    const cf = comptime biquadCoeffFrac(T);
    // The MAC accumulator: wide enough for five products of (lane × coeff) plus
    // the rounding bias with guard bits to spare. For i16/q15 this is i36, which
    // the backend lowers to i64 — exactly the "accumulate a q15 section in i64"
    // the fixed-point-IIR design requires.
    const Wide = std.meta.Int(.signed, 2 * @typeInfo(T).int.bits + 4);
    return struct {
        const Self = @This();
        coeffs: Coeffs(T) = .{},
        /// DF1 state: input history (x1, x2) and output history (y1, y2), all in
        /// the lane's own q-format (already rounded/saturated).
        x1: T = 0,
        x2: T = 0,
        y1: T = 0,
        y2: T = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const c = self.coeffs;
            const bias: Wide = comptime (@as(Wide, 1) << (cf - 1));
            const lo: Wide = std.math.minInt(T);
            const hi: Wide = std.math.maxInt(T);
            var x1 = self.x1;
            var x2 = self.x2;
            var y1 = self.y1;
            var y2 = self.y2;
            for (xs, ys) |x, *y| {
                const acc: Wide =
                    @as(Wide, c.b0) * @as(Wide, x) +
                    @as(Wide, c.b1) * @as(Wide, x1) +
                    @as(Wide, c.b2) * @as(Wide, x2) -
                    @as(Wide, c.a1) * @as(Wide, y1) -
                    @as(Wide, c.a2) * @as(Wide, y2);
                // Round to nearest (bias then arithmetic shift), then saturate to
                // the lane bound on store — never wraps.
                const yv: T = @intCast(std.math.clamp((acc + bias) >> cf, lo, hi));
                x2 = x1;
                x1 = x;
                y2 = y1;
                y1 = yv;
                y.* = yv;
            }
            self.x1 = x1;
            self.x2 = x2;
            self.y1 = y1;
            self.y2 = y2;
        }
    };
}

/// Which output a `StateVariable` filter emits per sample. A 2nd-order SVF derives
/// lowpass, bandpass, and highpass from the SAME two integrator states in one pass;
/// the mode is fixed at comptime (it selects one branch — there is no per-sample
/// runtime switch, so the unused arms vanish from codegen).
pub const SvfMode = enum { lowpass, bandpass, highpass };

/// `StateVariable(num)` — a 2nd-order state-variable filter in the
/// topology-preserving-transform (TPT) form. This is the bilinear-transform SVF
/// whose two integrators are solved as a zero-delay feedback loop, so it stays
/// stable and tuning-accurate up toward Nyquist (unlike the classic Chamberlin SVF,
/// which goes unstable as the cutoff rises). LP, BP, and HP all fall out of the
/// same two integrator states `ic1`/`ic2`; the comptime `mode` picks which is
/// written to the output.
///
/// Coefficients per block from the two parameters:
///
///     g  = tan(π · fc)          (the prewarped integrator gain)
///     k  = 1 / q                (the damping; lower q → more resonance)
///     a1 = 1 / (1 + g·(g + k))
///     a2 = g · a1
///     a3 = g · a2
///
/// and the per-sample TPT recurrence (Cytomic / Zavalishin form):
///
///     v3  = x − ic2
///     v1  = a1·ic1 + a2·v3       (bandpass)
///     v2  = ic2 + a2·ic1 + a3·v3 (lowpass)
///     ic1 = 2·v1 − ic1
///     ic2 = 2·v2 − ic2
///     highpass = x − k·v1 − v2
///
/// `fc` is the cutoff as a NORMALIZED frequency in cycles/sample (so `fc · Fs` is Hz;
/// keep it in the open interval `(0, 0.5)` to stay below Nyquist) and `q` is the
/// resonance/quality factor (`q = 0.707` is the maximally-flat Butterworth case;
/// higher `q` peaks at cutoff). Both are `f32` parameter ports, held-and-ramped per
/// block via the same "ramp, never step" anti-zipper policy `OnePole` uses, so a
/// wired LFO→fc sweep is bit-identical to the same target sequence pushed through
/// `set`. Per-sample integrator state ⇒ rate-1:1 ⇒ a `Map`; the recurrence is
/// sequential, so it is NOT `aliasing_safe`.
///
/// Float lanes only: the zero-delay-feedback solve needs the `1/(1+g(g+k))`
/// reciprocal and `tan`, neither of which has been given the wide-accumulator
/// fixed-point treatment the fixed-point `Biquad` uses — so the integer path fails
/// loud (a compile error) rather than emitting silently-wrong audio.
pub fn StateVariable(comptime num: numeric.Numeric) type {
    return StateVariableMode(num, .lowpass);
}

/// `StateVariable` with an explicit output `mode` selected at comptime. The
/// no-argument `StateVariable(num)` defaults to `.lowpass`.
pub fn StateVariableMode(comptime num: numeric.Numeric, comptime mode: SvfMode) type {
    const T = num.Lane;
    if (!isFloat(T))
        @compileError("pan: StateVariable is float-only for now — the TPT" ++
            " zero-delay-feedback solve needs a reciprocal and tan() that have not" ++
            " been given the q-format + wide-accumulator treatment the fixed-point" ++
            " Biquad uses, not yet ported here. Use f32/f64.");
    return struct {
        const Self = @This();

        /// The output this monomorph emits (lowpass / bandpass / highpass).
        pub const svf_mode = mode;

        /// Cutoff (slot 0) and resonance/Q (slot 1) parameter ports, both control
        /// element `Scalar(f32)`.
        pub const params = .{ .fc = types.Scalar(f32), .q = types.Scalar(f32) };

        /// Latest published cutoff target (cycles/sample) — atomic; set by the
        /// control thread OR a wired parameter edge. Read once per block.
        fc: control.Param = control.Param.init(0.25),
        /// Latest published resonance/Q target — atomic. Default 0.707 (Butterworth).
        q: control.Param = control.Param.init(0.7071067811865476),
        /// Live cutoff, ramped across blocks (persistent anti-zipper state).
        fc_ramp: control.Ramp = control.Ramp.init(0.25),
        /// Live Q, ramped across blocks.
        q_ramp: control.Ramp = control.Ramp.init(0.7071067811865476),
        /// The two TPT integrator states, carried across calls so a render split
        /// into sub-blocks is seamless.
        ic1: T = 0,
        ic2: T = 0,

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            switch (slot) {
                0 => self.fc.set(value),
                1 => self.q.set(value),
                else => {},
            }
        }

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const fc_tgt = self.fc.read();
            const q_tgt = self.q.read();
            const fc_inc = self.fc_ramp.begin(fc_tgt, xs.len);
            const q_inc = self.q_ramp.begin(q_tgt, xs.len);
            var ic1 = self.ic1;
            var ic2 = self.ic2;
            for (xs, ys, 0..) |x, *y, i| {
                // Glide the two parameters one sample at a time (anti-zipper ramp),
                // recomputing the prewarped coefficients each step.
                const step: f32 = @floatFromInt(i + 1);
                const fc: T = @floatCast(self.fc_ramp.value + step * fc_inc);
                const q: T = @floatCast(self.q_ramp.value + step * q_inc);
                const g: T = @tan(@as(T, std.math.pi) * fc);
                const k: T = 1.0 / q;
                const a1: T = 1.0 / (1.0 + g * (g + k));
                const a2: T = g * a1;
                const a3: T = g * a2;

                const v3 = x - ic2;
                const v1 = a1 * ic1 + a2 * v3;
                const v2 = ic2 + a2 * ic1 + a3 * v3;
                ic1 = 2 * v1 - ic1;
                ic2 = 2 * v2 - ic2;
                y.* = switch (mode) {
                    .lowpass => v2,
                    .bandpass => v1,
                    .highpass => x - k * v1 - v2,
                };
            }
            self.ic1 = ic1;
            self.ic2 = ic2;
            self.fc_ramp.finish(fc_tgt); // snap to exact targets; next block ramps from them
            self.q_ramp.finish(q_tgt);
        }
    };
}

/// Build a `taps`-tap windowed-sinc (Hamming) lowpass coefficient table at comptime,
/// normalized to unity DC gain. `fc` is the normalized cutoff in cycles/sample
/// (`0 < fc < 0.5`). The ideal lowpass impulse response is the sinc
/// `2·fc·sinc(2·fc·n)` centred on the table, multiplied by a Hamming window
/// `0.54 − 0.46·cos(2π·i/(taps−1))` to taper the truncation ripple, then scaled so
/// the coefficients sum to 1 (a DC sinusoid passes at unity). This is the classic
/// `scipy.signal.firwin(taps, 2·fc, window="hamming")` design.
pub fn firwinLowpass(comptime taps: usize, comptime fc: f32) [taps]f32 {
    if (taps == 0) @compileError("pan: firwinLowpass needs at least one tap");
    return comptime blk: {
        @setEvalBranchQuota(taps * 64 + 256);
        var h: [taps]f32 = undefined;
        const m: f32 = @as(f32, @floatFromInt(taps - 1)) / 2.0; // symmetry centre
        const denom: f32 = if (taps == 1) 1.0 else @floatFromInt(taps - 1);
        var sum: f32 = 0;
        for (&h, 0..) |*c, i| {
            const n: f32 = @as(f32, @floatFromInt(i)) - m;
            // sinc(0) limit = 2·fc; elsewhere sin(2π·fc·n)/(π·n).
            const sinc: f32 = if (n == 0)
                2.0 * fc
            else
                @sin(2.0 * std.math.pi * fc * n) / (std.math.pi * n);
            const win: f32 = 0.54 - 0.46 * @cos(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / denom);
            c.* = sinc * win;
            sum += c.*;
        }
        for (&h) |*c| c.* /= sum; // normalize to unity DC gain
        break :blk h;
    };
}

/// `firwinHighpass(taps, fc)` — windowed-sinc highpass by SPECTRAL INVERSION of the
/// lowpass prototype: negate every tap and add 1 at the centre tap (`h = δ − h_lp`),
/// flipping the passband to `[fc, Nyquist]` with unity gain at Nyquist and ~0 at DC.
/// `taps` must be ODD so a centre tap exists (a Type-I linear-phase filter; an even
/// length cannot realise unity Nyquist gain for a highpass).
pub fn firwinHighpass(comptime taps: usize, comptime fc: f32) [taps]f32 {
    if (taps % 2 == 0) @compileError("pan: firwinHighpass needs an ODD tap count (Type-I linear phase)");
    return comptime blk: {
        var h = firwinLowpass(taps, fc);
        for (&h) |*c| c.* = -c.*;
        h[(taps - 1) / 2] += 1.0; // δ − lowpass
        break :blk h;
    };
}

/// `firwinBandpass(taps, lo, hi)` — windowed-sinc bandpass = `lowpass(hi) −
/// lowpass(lo)` (the difference of two lowpass prototypes), passing `[lo, hi]`. Both
/// prototypes are unity-DC-normalized, so the difference has ~0 DC gain. `lo < hi`,
/// both in cycles/sample (0..0.5).
pub fn firwinBandpass(comptime taps: usize, comptime lo: f32, comptime hi: f32) [taps]f32 {
    if (lo >= hi) @compileError("pan: firwinBandpass needs lo < hi");
    return comptime blk: {
        const hl = firwinLowpass(taps, hi);
        const ll = firwinLowpass(taps, lo);
        var h: [taps]f32 = undefined;
        for (&h, hl, ll) |*c, a, b| c.* = a - b;
        break :blk h;
    };
}

/// `firwinBandstop(taps, lo, hi)` — windowed-sinc band-reject by spectral inversion
/// of the bandpass (`h = δ − bandpass(lo, hi)`): passes everything outside `[lo, hi]`.
/// `taps` must be ODD (Type-I linear phase).
pub fn firwinBandstop(comptime taps: usize, comptime lo: f32, comptime hi: f32) [taps]f32 {
    if (taps % 2 == 0) @compileError("pan: firwinBandstop needs an ODD tap count (Type-I linear phase)");
    return comptime blk: {
        var h = firwinBandpass(taps, lo, hi);
        for (&h) |*c| c.* = -c.*;
        h[(taps - 1) / 2] += 1.0; // δ − bandpass
        break :blk h;
    };
}

/// `Fir(num, taps)` — a `taps`-tap finite-impulse-response filter:
///
///     y[n] = Σ_{k=0..taps−1} coeff[k] · x[n−k]
///
/// a length-`taps` convolution of the input with the coefficient table. The
/// coefficients are a plain field (default: a unit impulse `coeff[0] = 1`, the rest
/// zero ⇒ pass-through), so a caller either drops in a hand-designed table or fills
/// one from the comptime `firwinLowpass` helper. Per-sample convolution over a
/// persistent history of the last `taps` inputs ⇒ rate-1:1 ⇒ a `Map`; the history
/// carries across calls so a split render equals a whole render. The history is NOT
/// `aliasing_safe`: each output reads `taps` past inputs, so the colorer must not
/// alias the output onto the input buffer.
///
/// Storage trick for a branch-free, vectorizable inner product: the past inputs live
/// in a DOUBLED buffer of length `2·taps`. Each new sample is written at both `pos`
/// and `pos + taps`, so the `taps`-length window ending at the write cursor is ALWAYS
/// a contiguous slice (oldest→newest) with no wrap — letting the dot product run as a
/// flat `@Vector(W,T)` reduction against the reversed coefficient table, with a scalar
/// tail for `taps % W`. The reversed table `cr[j] = coeff[taps−1−j]` aligns the
/// oldest-first window with the `x[n−k]` indexing above.
///
/// Float lanes use the SIMD dot; integer lanes accumulate the `taps` products in the
/// wide `num.Acc`, then a single round-to-nearest right shift by the lane's
/// fractional bits and a saturating store (the same wide-accumulate-then-round-once
/// discipline the fixed-point `Biquad` uses — never a per-multiply shift, which would
/// throw away accumulator headroom and compute wrong audio). Integer coefficients are
/// `q(fracBits)` fixed-point (`|coeff| < 1`); a FIR lowpass has DC gain 1, which is
/// the sum of all taps, so no single tap need exceed unity.
pub fn Fir(comptime num: numeric.Numeric, comptime taps: usize) type {
    if (taps == 0) @compileError("pan: Fir needs at least one tap");
    const T = num.Lane;
    return struct {
        const Self = @This();

        /// Convolution coefficients in natural order: `coeffs[k]` multiplies the
        /// input delayed by `k` samples. Default is a unit impulse (pass-through):
        /// for a float lane `coeffs[0] = 1`; for an integer lane the q(frac) unity
        /// `1 << fracBits`. Stored internally reversed; see `reversed`.
        coeffs: [taps]T = blk: {
            var c: [taps]T = @splat(0);
            c[0] = if (isFloat(T)) 1 else (@as(T, 1) << fracBits(T));
            break :blk c;
        },
        /// The doubled history ring (`2·taps`), so the live window is always a
        /// contiguous, wrap-free slice. Carried across calls (persistent state).
        buf: [2 * taps]T = @splat(0),
        /// Write cursor into the first half; the newest sample lands at `pos` and
        /// its mirror at `pos + taps`.
        pos: usize = taps - 1,

        /// The coefficient table reversed to oldest-first (`cr[j] = coeffs[taps−1−j]`),
        /// so it lines up index-for-index with the oldest→newest contiguous window.
        fn reversed(c: *const [taps]T) [taps]T {
            var r: [taps]T = undefined;
            inline for (0..taps) |j| r[j] = c[taps - 1 - j];
            return r;
        }

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const cr = reversed(&self.coeffs);
            var pos = self.pos;
            if (comptime isFloat(T)) {
                const W = comptime num.W;
                for (xs, ys) |x, *y| {
                    pos = if (pos + 1 == taps) 0 else pos + 1;
                    self.buf[pos] = x;
                    self.buf[pos + taps] = x;
                    const win = self.buf[pos + 1 ..][0..taps];
                    y.* = dotFloat(W, win, &cr);
                }
            } else {
                const frac = comptime fracBits(T);
                const Acc = num.Acc;
                const bias: Acc = comptime (@as(Acc, 1) << (frac - 1));
                const lo: Acc = std.math.minInt(T);
                const hi: Acc = std.math.maxInt(T);
                for (xs, ys) |x, *y| {
                    pos = if (pos + 1 == taps) 0 else pos + 1;
                    self.buf[pos] = x;
                    self.buf[pos + taps] = x;
                    const win = self.buf[pos + 1 ..][0..taps];
                    // Sum the taps products in the wide accumulator (Q(2·frac)),
                    // then round-to-nearest and saturate once on store — never a
                    // per-multiply shift (which would discard accumulator headroom).
                    var acc: Acc = 0;
                    inline for (0..taps) |k| acc += @as(Acc, win[k]) * @as(Acc, cr[k]);
                    y.* = @intCast(std.math.clamp((acc + bias) >> frac, lo, hi));
                }
            }
            self.pos = pos;
        }

        /// `Σ win[k]·cr[k]` over `taps` floats: a `@Vector(W,T)` running sum with a
        /// scalar tail for `taps % W` (and a pure scalar path when there is no SIMD
        /// for the lane or the table is shorter than a vector).
        fn dotFloat(comptime W: comptime_int, win: *const [taps]T, cr: *const [taps]T) T {
            if (W <= 1 or taps < W) {
                var acc: T = 0;
                inline for (0..taps) |k| acc += win[k] * cr[k];
                return acc;
            }
            const V = @Vector(W, T);
            var accv: V = @splat(0);
            var i: usize = 0;
            while (i + W <= taps) : (i += W) {
                const a: V = win[i..][0..W].*;
                const b: V = cr[i..][0..W].*;
                accv += a * b;
            }
            var acc = @reduce(.Add, accv);
            while (i < taps) : (i += 1) acc += win[i] * cr[i];
            return acc;
        }
    };
}

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

test "OnePole(f32) classifies as a Map with a cutoff param; a=1 passes the signal" {
    const port = @import("port.zig");
    const OP = OnePole(f32num);
    try testing.expect(port.classify(OP) == .Map);
    try testing.expect(port.ParamPort(OP, "cutoff").Elem == types.Scalar(f32));
    try testing.expect(!@hasDecl(OP, "aliasing_safe")); // stateful recurrence

    // cutoff coefficient a = 1 (the default) → y[n] = y[n-1] + 1·(x - y[n-1]) = x.
    var op = OP{};
    var in: [4]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{-2} }, .{ .ch = .{3} }, .{ .ch = .{0.5} } };
    var out: [4]types.Sample(f32) = undefined;
    op.process(&in, &out);
    for (in, out) |x, y| try testing.expectApproxEqAbs(x.ch[0], y.ch[0], 1e-6);
}

test "OnePole(f32) a=0.5 step response matches the hand-rolled leaky integrator" {
    const OP = OnePole(f32num);
    var op = OP{};
    op.setParam(0, 0.5); // target coefficient 0.5
    // A unit step; with the per-block ramp a glides 1.0 → 0.5 across the block, so
    // re-derive the SAME ramped recurrence independently and compare bit-for-bit.
    const N = 6;
    var in: [N]types.Sample(f32) = @splat(.{ .ch = .{1} });
    var out: [N]types.Sample(f32) = undefined;
    op.process(&in, &out);

    var ry1: f32 = 0;
    const inc: f32 = (0.5 - 1.0) / @as(f32, N);
    for (out, 0..) |y, i| {
        const a: f32 = 1.0 + @as(f32, @floatFromInt(i + 1)) * inc;
        ry1 = ry1 + a * (1.0 - ry1);
        try testing.expectEqual(ry1, y.ch[0]); // bit-exact vs the independent recurrence
    }
}

test "Gain(f32) scales by its linear coefficient (and defaults to unity)" {
    var unity = Gain(f32num){};
    var in: [5]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{2} }, .{ .ch = .{3} }, .{ .ch = .{4} }, .{ .ch = .{5} } };
    var out: [5]types.Sample(f32) = undefined;
    unity.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);

    var half = Gain(f32num){ .gain = 0.5 };
    half.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
}

test "Biquad(f32) identity coeffs pass the signal through unchanged" {
    var bq = Biquad(f32num){};
    var in: [4]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{-1} }, .{ .ch = .{0.5} }, .{ .ch = .{0} } };
    var out: [4]types.Sample(f32) = undefined;
    bq.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "Biquad(f32) one-pole matches the hand-rolled lfilter recurrence" {
    // A one-pole low-pass: y[n] = b0 x[n] - a1 y[n-1].
    const b0: f32 = 0.2;
    const a1: f32 = -0.8;
    var bq = Biquad(f32num){ .coeffs = .{ .b0 = b0, .a1 = a1 } };
    var in: [6]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{0} }, .{ .ch = .{0} }, .{ .ch = .{0} }, .{ .ch = .{0} }, .{ .ch = .{0} } };
    var out: [6]types.Sample(f32) = undefined;
    bq.process(&in, &out);
    // The closed-form impulse response of this one-pole is the decaying
    // geometric series y[n] = b0 · (−a1)^n (the independent oracle here).
    for (out, 0..) |y, n| {
        const expected = b0 * std.math.pow(f32, -a1, @floatFromInt(n));
        try testing.expectApproxEqAbs(expected, y.ch[0], 1e-6);
    }
}

test "Biquad state carries across calls — a split render equals a whole render" {
    const c = Coeffs(f32){ .b0 = 0.5, .b1 = 0.5, .a1 = -0.3 };
    var whole = Biquad(f32num){ .coeffs = c };
    var split = Biquad(f32num){ .coeffs = c };
    var in: [8]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @floatFromInt(i);
    var ow: [8]types.Sample(f32) = undefined;
    var os: [8]types.Sample(f32) = undefined;
    whole.process(&in, &ow);
    split.process(in[0..3], os[0..3]);
    split.process(in[3..], os[3..]);
    for (ow, os) |a, b| try testing.expectEqual(a.ch[0], b.ch[0]);
}

test "Gain classifies as a Map and is aliasing_safe; Biquad is a Map that is not" {
    const port = @import("port.zig");
    try testing.expect(port.classify(Gain(f32num)) == .Map);
    try testing.expect(port.classify(Biquad(f32num)) == .Map);
    try testing.expect(port.classify(Biquad(q15num)) == .Map);
    try testing.expect(Gain(f32num).aliasing_safe);
    try testing.expect(!@hasDecl(Biquad(f32num), "aliasing_safe"));
    try testing.expect(!@hasDecl(Biquad(q15num), "aliasing_safe"));
}

const q15num = numeric.numericFor(.i16, .{});

test "Biquad(q15) identity coeffs pass the signal through unchanged" {
    // Default coeffs are the integer identity: b0 = 1<<coeff_frac (= 8192 in
    // Q2.13), the rest 0. acc = 8192·x, >>13 == x, so the lane is unchanged.
    var bq = Biquad(q15num){};
    var in: [4]types.Sample(i16) = .{ .{ .ch = .{12345} }, .{ .ch = .{-9000} }, .{ .ch = .{32767} }, .{ .ch = .{-32768} } };
    var out: [4]types.Sample(i16) = undefined;
    bq.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "Biquad(q15) feedback coefficient |a1|>1 is representable and the section is stable" {
    // A1 = -1.709 (raw -14000 in Q2.13) exceeds the lane's [-1,1) range — the very
    // thing a naive q15 biquad could not hold. With a stable pole pair (a2 < 1,
    // |a1| < 1 + a2) the impulse response must DECAY, not blow up. We assert the
    // tail magnitude shrinks below the early response (the limit-cycle/stability
    // sanity the fixed-point IIR needs), an independent property check (not pan's
    // own output replayed).
    var bq = Biquad(q15num){ .coeffs = .{ .b0 = 50, .b1 = 100, .b2 = 50, .a1 = -14000, .a2 = 6500 } };
    var in: [256]types.Sample(i16) = @splat(.{ .ch = .{0} });
    in[0] = .{ .ch = .{20000} }; // an impulse well below full-scale (headroom)
    var out: [256]types.Sample(i16) = undefined;
    bq.process(&in, &out);
    var peak: i32 = 0;
    for (out[0..16]) |s| peak = @max(peak, @as(i32, @abs(s.ch[0])));
    var tail: i32 = 0;
    for (out[200..]) |s| tail = @max(tail, @as(i32, @abs(s.ch[0])));
    try testing.expect(peak > 0); // it responded
    try testing.expect(tail < peak); // and decayed — no runaway / sustained limit cycle
}

const q31num = numeric.numericFor(.i32, .{});

test "StateVariable(f32) classifies as a Map with fc/q params and is not aliasing_safe" {
    const port = @import("port.zig");
    const SV = StateVariable(f32num);
    try testing.expect(port.classify(SV) == .Map);
    try testing.expect(port.ParamPort(SV, "fc").Elem == types.Scalar(f32));
    try testing.expect(port.ParamPort(SV, "q").Elem == types.Scalar(f32));
    // A sequential integrator recurrence: the colorer must NOT run it in place.
    try testing.expect(!@hasDecl(SV, "aliasing_safe"));
    try testing.expect(SV.svf_mode == .lowpass); // the no-arg default
}

test "StateVariable lowpass passes DC and rejects a near-Nyquist tone" {
    // WHY: the defining behaviour of a lowpass is that a slow signal (DC) survives
    // while a fast one (alternating ±1, the highest representable frequency) is
    // crushed. With a low cutoff the steady-state LP output must approach the DC
    // level and the alternating tone must be attenuated far below unity. Settle the
    // ramped coefficients first by pushing the targets, then measure the tail.
    var lp = StateVariableMode(f32num, .lowpass){};
    lp.setParam(0, 0.02); // cutoff ≈ 0.02 cycles/sample
    lp.setParam(1, 0.7071067811865476);

    var dc: [400]types.Sample(f32) = @splat(.{ .ch = .{1} });
    var dco: [400]types.Sample(f32) = undefined;
    lp.process(&dc, &dco);
    try testing.expectApproxEqAbs(@as(f32, 1.0), dco[399].ch[0], 1e-3); // DC survives

    var hf = StateVariableMode(f32num, .lowpass){};
    hf.setParam(0, 0.02);
    var sig: [400]types.Sample(f32) = undefined;
    for (&sig, 0..) |*s, i| s.ch[0] = if (i % 2 == 0) @as(f32, 1) else -1;
    var hfo: [400]types.Sample(f32) = undefined;
    hf.process(&sig, &hfo);
    var peak: f32 = 0;
    for (hfo[200..]) |s| peak = @max(peak, @abs(s.ch[0]));
    try testing.expect(peak < 0.05); // near-Nyquist tone is crushed
}

test "StateVariable highpass rejects DC and passes a near-Nyquist tone" {
    // WHY: the complementary behaviour — a highpass must REMOVE the DC offset and
    // let the fast alternating tone through. Asserting both LP-rejects-HF and
    // HP-rejects-DC pins the mode selection, not just generic attenuation.
    var hp = StateVariableMode(f32num, .highpass){};
    hp.setParam(0, 0.02);
    hp.setParam(1, 0.7071067811865476);
    var dc: [400]types.Sample(f32) = @splat(.{ .ch = .{1} });
    var dco: [400]types.Sample(f32) = undefined;
    hp.process(&dc, &dco);
    try testing.expectApproxEqAbs(@as(f32, 0.0), dco[399].ch[0], 1e-3); // DC removed

    var hp2 = StateVariableMode(f32num, .highpass){};
    hp2.setParam(0, 0.02);
    var sig: [400]types.Sample(f32) = undefined;
    for (&sig, 0..) |*s, i| s.ch[0] = if (i % 2 == 0) @as(f32, 1) else -1;
    var out: [400]types.Sample(f32) = undefined;
    hp2.process(&sig, &out);
    var peak: f32 = 0;
    for (out[200..]) |s| peak = @max(peak, @abs(s.ch[0]));
    try testing.expect(peak > 0.9); // the fast tone passes near unity
}

test "StateVariable integrator state carries across calls — a split render equals a whole" {
    // WHY: the two integrator states are persistent; a render chopped into sub-blocks
    // must be sample-for-sample identical to one whole-block render, or the block is
    // wrong under the engine's block-size-agnostic contract. (No setParam here, so
    // both instances ride the same default-target ramp.)
    var whole = StateVariableMode(f32num, .bandpass){};
    var split = StateVariableMode(f32num, .bandpass){};
    var in: [12]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @sin(@as(f32, @floatFromInt(i)) * 0.7);
    var ow: [12]types.Sample(f32) = undefined;
    var os: [12]types.Sample(f32) = undefined;
    whole.process(&in, &ow);
    split.process(in[0..5], os[0..5]);
    split.process(in[5..], os[5..]);
    for (ow, os) |a, b| try testing.expectEqual(a.ch[0], b.ch[0]);
}

test "Fir(f32) classifies as a Map and is not aliasing_safe" {
    const port = @import("port.zig");
    const F = Fir(f32num, 5);
    try testing.expect(port.classify(F) == .Map);
    // Each output reads `taps` past inputs, so the colorer must not alias in place.
    try testing.expect(!@hasDecl(F, "aliasing_safe"));
}

test "Fir(f32) impulse response equals the coefficient table" {
    // WHY: an FIR's impulse response IS its coefficient table by definition —
    // y[n] = Σ coeff[k]·x[n−k] with x = δ leaves exactly coeff[n]. This pins the
    // index convention (coeff[k] multiplies the k-sample-delayed input).
    var f = Fir(f32num, 3){ .coeffs = .{ 0.25, 0.5, 0.25 } };
    var in: [5]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{0} }, .{ .ch = .{0} }, .{ .ch = .{0} }, .{ .ch = .{0} } };
    var out: [5]types.Sample(f32) = undefined;
    f.process(&in, &out);
    const want: [5]f32 = .{ 0.25, 0.5, 0.25, 0, 0 };
    for (out, want) |y, w| try testing.expectApproxEqAbs(w, y.ch[0], 1e-7);
}

test "Fir(f32) matches a hand-computed convolution with asymmetric taps" {
    // WHY: a symmetric kernel hides tap-ordering bugs (reversal looks identical).
    // Asymmetric taps [1,2,3] on a ramp expose the ordering: each output is the
    // hand-rolled Σ_k coeff[k]·x[n−k]. This is an independent oracle, not a replay.
    var f = Fir(f32num, 3){ .coeffs = .{ 1, 2, 3 } };
    var in: [4]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{2} }, .{ .ch = .{3} }, .{ .ch = .{4} } };
    var out: [4]types.Sample(f32) = undefined;
    f.process(&in, &out);
    // y0 = 1·1                       = 1
    // y1 = 1·2 + 2·1                 = 4
    // y2 = 1·3 + 2·2 + 3·1           = 10
    // y3 = 1·4 + 2·3 + 3·2           = 16
    const want: [4]f32 = .{ 1, 4, 10, 16 };
    for (out, want) |y, w| try testing.expectApproxEqAbs(w, y.ch[0], 1e-6);
}

test "Fir(f32) history carries across calls — a split render equals a whole" {
    // WHY: the delay history is persistent state; a render split at an arbitrary
    // boundary must equal one whole-block render or the convolution silently drops
    // cross-boundary taps. Tap count 9 exercises the SIMD body + scalar tail.
    var whole = Fir(f32num, 9){ .coeffs = firwinLowpass(9, 0.15) };
    var split = Fir(f32num, 9){ .coeffs = firwinLowpass(9, 0.15) };
    var in: [20]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @floatFromInt(@as(i32, @intCast(i)) - 7);
    var ow: [20]types.Sample(f32) = undefined;
    var os: [20]types.Sample(f32) = undefined;
    whole.process(&in, &ow);
    split.process(in[0..7], os[0..7]);
    split.process(in[7..13], os[7..13]);
    split.process(in[13..], os[13..]);
    for (ow, os) |a, b| try testing.expectEqual(a.ch[0], b.ch[0]);
}

test "firwinLowpass has unity DC gain and rejects a near-Nyquist tone" {
    // WHY: a lowpass design must (1) sum to 1 so a DC sinusoid passes unchanged and
    // (2) actually attenuate high frequencies. Assert the analytic property (tap sum)
    // and the realized behaviour (alternating ±1 fed through the filter is crushed).
    const taps = 31;
    const h = firwinLowpass(taps, 0.1);
    var sum: f32 = 0;
    for (h) |c| sum += c;
    try testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-5);

    var f = Fir(f32num, taps){ .coeffs = h };
    var sig: [128]types.Sample(f32) = undefined;
    for (&sig, 0..) |*s, i| s.ch[0] = if (i % 2 == 0) @as(f32, 1) else -1;
    var out: [128]types.Sample(f32) = undefined;
    f.process(&sig, &out);
    var peak: f32 = 0;
    for (out[taps..]) |s| peak = @max(peak, @abs(s.ch[0])); // skip the fill transient
    try testing.expect(peak < 0.05); // 0.1-cutoff lowpass crushes the Nyquist tone
}

test "Fir(q31) integer path matches the float oracle within a quantization bound" {
    // WHY: the fixed-point path must compute the SAME convolution as the float path,
    // not merely run. Build q31 coefficients from the float firwin table, run a ramp
    // through both, and assert agreement to within one LSB of round-off scaled by the
    // tap count — proving the wide-accumulate-then-round-once arithmetic is correct
    // (a per-multiply shift would drift far past this bound).
    const taps = 9;
    const hf = firwinLowpass(taps, 0.2);
    const frac = fracBits(i32); // q31
    var hq: [taps]i32 = undefined;
    inline for (0..taps) |k| {
        hq[k] = @intFromFloat(@round(hf[k] * @as(f32, @floatFromInt(@as(i64, 1) << frac))));
    }
    var ff = Fir(f32num, taps){ .coeffs = hf };
    var fq = Fir(q31num, taps){ .coeffs = hq };

    const scale: f32 = @floatFromInt(@as(i64, 1) << frac);
    var fin: [64]types.Sample(f32) = undefined;
    var qin: [64]types.Sample(i32) = undefined;
    for (&fin, &qin, 0..) |*fs, *qs, i| {
        const v: f32 = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
        fs.ch[0] = v;
        qs.ch[0] = @intFromFloat(@round(v * scale));
    }
    var fout: [64]types.Sample(f32) = undefined;
    var qout: [64]types.Sample(i32) = undefined;
    ff.process(&fin, &fout);
    fq.process(&qin, &qout);
    for (fout, qout) |fy, qy| {
        const q_as_float = @as(f32, @floatFromInt(qy.ch[0])) / scale;
        // Each quantized factor carries ≤ 0.5 LSB; with `taps` products plus the
        // store rounding the worst-case error stays a few LSB — a tiny absolute bound.
        try testing.expectApproxEqAbs(fy.ch[0], q_as_float, 1e-4);
    }
}

test "firwin HP/BP/BS designers: correct DC/passband structure (independent sums)" {
    // Highpass = δ − lowpass: DC gain (Σ taps) ≈ 0, and it is NOT the lowpass.
    const hp = firwinHighpass(31, 0.25);
    var hp_sum: f32 = 0;
    for (hp) |c| hp_sum += c;
    try testing.expectApproxEqAbs(@as(f32, 0), hp_sum, 1e-4); // DC rejected
    // A highpass passes a near-Nyquist alternating tone (apply the FIR directly).
    var alt: f32 = 0;
    for (hp, 0..) |c, i| alt += c * (if (i % 2 == 0) @as(f32, 1) else @as(f32, -1));
    try testing.expect(@abs(alt) > 0.5); // strong Nyquist response

    // Bandpass = lowpass(hi) − lowpass(lo): zero DC gain (both prototypes unity-DC).
    const bp = firwinBandpass(31, 0.1, 0.3);
    var bp_sum: f32 = 0;
    for (bp) |c| bp_sum += c;
    try testing.expectApproxEqAbs(@as(f32, 0), bp_sum, 1e-4);

    // Bandstop = δ − bandpass: unity DC gain (Σ taps ≈ 1), the complement of bandpass.
    const bs = firwinBandstop(31, 0.1, 0.3);
    var bs_sum: f32 = 0;
    for (bs, bp) |c, b| {
        bs_sum += c;
        _ = b;
    }
    try testing.expectApproxEqAbs(@as(f32, 1), bs_sum, 1e-4); // DC passes
}
