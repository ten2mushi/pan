//! Time-domain feature descriptors — zero-crossing rate, mean Teager-Kaiser
//! energy, and a ballistic amplitude envelope.
//!
//! Each block is a rate-1:1 `Map` over a `TimeFrame(T, FRAME)` (the `Framer`'s
//! windowed output element), emitting one value per hop, rate-aligned with the
//! spectral branch. Holding per-call state (the ballistic envelope) does NOT make a
//! block a `Rate` — a `Rate` changes the output:input element count; a stateful
//! `Map` still emits one-for-one. These are tested against an external
//! NumPy-equivalent oracle, so each doc-comment states its exact formula in plain
//! prose. The features are computed in `f64`/`f32`; the time-domain frame element is
//! float-only, guarded loud by `requireFloatLane`.

const std = @import("std");
const core = @import("pan_core");
const numeric = core.numeric;
const types = core.types;
const spectral = @import("../spectral/spectral.zig");

/// A float-lane guard for the time-domain blocks (which consume a `TimeFrame`, the
/// `Framer`'s float-only output element). Restating the float-lane requirement
/// locally keeps the dependency one-directional and the error message specific.
fn requireFloatLane(comptime T: type) void {
    if (@typeInfo(T) != .float)
        @compileError("pan: this time-domain feature block requires a float lane (f32/f64); got " ++ @typeName(T));
}

// ===========================================================================
// Zcr — zero-crossing rate over a time-domain frame
// ===========================================================================

/// `Zcr(num, FRAME)` — the **zero-crossing rate** of a time-domain analysis frame:
/// the fraction of adjacent sample pairs whose sign differs. A cheap noisiness /
/// pitch-proxy descriptor (high for unvoiced/noisy frames, low for low-pitched
/// voiced frames). Consumes a `TimeFrame(T, FRAME)` (the `Framer`'s output), so it
/// emits one value per hop, rate-aligned with the spectral branch.
///
/// Formula: counting a sign change between `s[k−1]` and `s[k]` whenever
/// `(s[k−1] < 0) ≠ (s[k] < 0)` (zero is treated as non-negative), the output is
/// `count / (FRAME − 1)`, in **crossings per sample** (multiply by `sample_rate / 2`
/// downstream for an approximate Hz). Frame-local (no cross-frame carry). Output
/// element `Scalar(f32)`.
pub fn Zcr(comptime num: numeric.Numeric, comptime FRAME: usize) type {
    const T = num.Lane;
    requireFloatLane(T);
    if (FRAME < 2) @compileError("pan: Zcr needs FRAME >= 2");
    const In = spectral.TimeFrame(T, FRAME);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            for (in, out) |frame, *o| {
                var count: usize = 0;
                var prev_neg = frame.s[0] < 0;
                var k: usize = 1;
                while (k < FRAME) : (k += 1) {
                    const cur_neg = frame.s[k] < 0;
                    if (cur_neg != prev_neg) count += 1;
                    prev_neg = cur_neg;
                }
                o.value = @floatCast(@as(f64, @floatFromInt(count)) / @as(f64, FRAME - 1));
            }
        }
    };
}

// ===========================================================================
// TeoMean — mean Teager-Kaiser energy over a time-domain frame
// ===========================================================================

/// `TeoMean(num, FRAME)` — the mean **Teager-Kaiser energy operator** (TEO/TKEO) over
/// a time-domain analysis frame: a running estimate of the signal's instantaneous
/// energy that responds to both amplitude and frequency, sharpening transients and
/// onsets. Consumes a `TimeFrame(T, FRAME)` and emits one value per hop.
///
/// Formula: the discrete TKEO is `Ψ[n] = s[n]² − s[n−1]·s[n+1]`; the output is the
/// mean of `Ψ` over the interior samples `n = 1 … FRAME−2` (the endpoints have no
/// two neighbors and are excluded). Accumulated in `f64`. Frame-local. Output
/// element `Scalar(f32)`.
pub fn TeoMean(comptime num: numeric.Numeric, comptime FRAME: usize) type {
    const T = num.Lane;
    requireFloatLane(T);
    if (FRAME < 3) @compileError("pan: TeoMean needs FRAME >= 3 (interior TKEO)");
    const In = spectral.TimeFrame(T, FRAME);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            for (in, out) |frame, *o| {
                var acc: f64 = 0;
                var n: usize = 1;
                while (n < FRAME - 1) : (n += 1) {
                    const x: f64 = @floatCast(frame.s[n]);
                    const xm: f64 = @floatCast(frame.s[n - 1]);
                    const xp: f64 = @floatCast(frame.s[n + 1]);
                    acc += x * x - xm * xp;
                }
                o.value = @floatCast(acc / @as(f64, FRAME - 2));
            }
        }
    };
}

// ===========================================================================
// BallisticEnvelope — per-frame amplitude smoothed to [0,1] (a smoothed amplitude descriptor)
// ===========================================================================

/// `BallisticEnvelope(num, FRAME)` — a smoothed `[0, 1]` amplitude descriptor: each
/// time-domain frame's peak level passed through a ballistic (attack/release)
/// one-pole smoother across frames, clamped to `[0, 1]`. Fast attack catches
/// transients; slow release gives the natural "fall-off" a level meter wants.
/// Consumes a `TimeFrame(T, FRAME)` and emits one value per hop.
///
/// Update (per hop): `level = clamp(max_n |s[n]|, 0, 1)` (the frame's peak
/// magnitude; samples are assumed normalized to `[−1, 1]`); then the envelope moves
/// toward `level` by the attack fraction when rising and the release fraction when
/// falling — `env ← env + (level > env ? attack : release) · (level − env)`. `env`
/// starts at 0. `attack`/`release` are per-instance fields (per-frame smoothing
/// fractions in `[0, 1]`; defaults `attack = 0.6`, `release = 0.05`). Output element
/// `Scalar(f32)`, in `[0, 1]`.
///
/// State note: `env` is per-instance and advances exactly once per processed frame,
/// so a sub-block split leaves it identical to a whole-block render (S6 granularity).
pub fn BallisticEnvelope(comptime num: numeric.Numeric, comptime FRAME: usize) type {
    const T = num.Lane;
    requireFloatLane(T);
    if (FRAME == 0) @compileError("pan: BallisticEnvelope needs FRAME >= 1");
    const In = spectral.TimeFrame(T, FRAME);
    return struct {
        const Self = @This();

        /// The smoothed envelope, zero before the stream began.
        env: f32 = 0,
        /// The rising-edge smoothing fraction (fast).
        attack: f32 = 0.6,
        /// The falling-edge smoothing fraction (slow).
        release: f32 = 0.05,

        /// Timeline-chunking warm-up, in HOPs (frames). The only cross-frame
        /// state is `env`. A boundary error in `env` decays by (1 − coeff) each
        /// frame; the SLOWEST decay is the release edge (coeff = 0.05), giving a
        /// per-frame residual factor of 0.95. The release tail dominates the
        /// warm-up: 0.95^128 ≈ 1.5e-3, so 128 frames of discarded lead-in shrink
        /// a wrong boundary `env` to well under a tolerance, after which the
        /// reconstructed envelope tracks the true one. Because the convergence is
        /// asymptotic (an IIR settle), not finite, the warm-up is
        /// tolerance-bounded (allclose), never bit-exact.
        pub const warmup_samples: usize = 128;
        pub const warmup_exact: bool = false;

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            for (in, out) |frame, *o| {
                var peak: f32 = 0;
                for (frame.s) |s| {
                    const a = @abs(@as(f32, @floatCast(s)));
                    if (a > peak) peak = a;
                }
                const level = std.math.clamp(peak, 0.0, 1.0);
                const coeff = if (level > self.env) self.attack else self.release;
                self.env += coeff * (level - self.env);
                o.value = self.env;
            }
        }
    };
}
