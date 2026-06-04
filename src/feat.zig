//! Feature-extraction blocks — the analysis side of the library.
//!
//! Every block here is a rate-1:1 **`Map`** over a per-hop **power spectrum**
//! (`FeatureFrame(bins)`, whose `v[k]` is the magnitude² of bin `k`, as emitted by
//! `spectral.PowerSpectrum`). A `Map` consumes one spectrum and emits one feature
//! per hop, so a block on a 60 fps-equivalent hop stream produces one feature row
//! per visualization frame — exactly the "Data for every point" cadence the
//! `notes/1.md` viz wants. Holding per-call history (the flux block keeps the
//! previous spectrum) does **not** make a block a `Rate`: a `Rate` changes the
//! output:input element *count*; a stateful `Map` still emits one-for-one.
//!
//! These are *not* proven correct — they are tested against an external
//! NumPy/librosa-equivalent oracle. To make that oracle trivial to write, each
//! block's doc-comment states its exact formula and conventions in plain prose.
//!
//! All features are computed in `f32`/`f64` regardless of the audio `Numeric`,
//! because the power spectrum is already `f32` (a `FeatureFrame`). The `num`
//! parameter is carried for surface consistency with the rest of the library
//! (`feat.Block(Num, …)`); the lane it names is the audio precision upstream, not
//! the feature precision.

const std = @import("std");
const numeric = @import("numeric.zig");
const types = @import("types.zig");

// ===========================================================================
// Rms — broadband energy (the viz "amplitude")
// ===========================================================================

/// `Rms(num, bins)` — the per-hop broadband level, the viz's **amplitude** channel.
///
/// Formula (spectral RMS): `out = sqrt( (1/bins) · Σ_k power[k] )`, the root-mean
/// of the power-spectrum bins. Accumulated in `f64` for stability, returned `f32`.
/// (This is a frequency-domain energy measure — Parseval-related to the time RMS,
/// and monotone in loudness — chosen because the analysis edge already carries the
/// power spectrum.) Output element `Scalar(f32)`.
pub fn Rms(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            for (in, out) |frame, *o| {
                var acc: f64 = 0;
                for (frame.v) |p| acc += @as(f64, p);
                o.value = @floatCast(@sqrt(acc / @as(f64, @floatFromInt(bins))));
            }
        }
    };
}

// ===========================================================================
// DominantBand — the most active frequency bin (the viz "color/frequency")
// ===========================================================================

/// `DominantBand(num, bins)` — the index of the loudest power-spectrum bin, the
/// viz's **color / frequency** channel (mapped to the 2 kHz–8 kHz gradient on the
/// Python side).
///
/// Formula: `out = argmax_k power[k]` (the first index attaining the maximum on a
/// tie). Output element `Scalar(u16)` — the bin index, not a Hz value; the
/// bin→Hz mapping (`k · sample_rate / fft_size`) is a viz-side concern.
pub fn DominantBand(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(u16)) void {
            _ = self;
            for (in, out) |frame, *o| {
                var best: f32 = frame.v[0];
                var best_k: u16 = 0;
                for (frame.v, 0..) |p, k| {
                    if (p > best) {
                        best = p;
                        best_k = @intCast(k);
                    }
                }
                o.value = best_k;
            }
        }
    };
}

// ===========================================================================
// SpectralCentroid — the spectral "center of mass"
// ===========================================================================

/// `SpectralCentroid(num, bins)` — the power-weighted mean bin index, the
/// brightness descriptor that drives part of the viz's oscillatory spatial
/// distribution.
///
/// Formula: `out = (Σ_k k · power[k]) / (Σ_k power[k])`, in **bin units** (0 when
/// the spectrum is all-zero, by convention — a silent hop has no centroid). Output
/// element `Scalar(f32)`. (Multiply by `sample_rate / fft_size` viz-side for Hz.)
pub fn SpectralCentroid(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            for (in, out) |frame, *o| {
                var num_acc: f64 = 0;
                var den_acc: f64 = 0;
                for (frame.v, 0..) |p, k| {
                    num_acc += @as(f64, @floatFromInt(k)) * @as(f64, p);
                    den_acc += @as(f64, p);
                }
                o.value = if (den_acc > 0) @floatCast(num_acc / den_acc) else 0;
            }
        }
    };
}

// ===========================================================================
// SpectralFlux — onset / rate-of-change (keeps previous-spectrum history)
// ===========================================================================

/// `SpectralFlux(num, bins)` — the half-wave-rectified spectral flux: how much the
/// power spectrum *rose* since the previous hop, an onset/novelty descriptor.
///
/// Formula: `out = sqrt( Σ_k max(0, power[k] − prev[k])² )`, the L2 norm of the
/// positive spectral difference (energy increases only — decays don't signal an
/// onset). The block keeps the previous hop's spectrum in `prev` (a per-instance
/// field, zero before the first hop), updated to the current spectrum after each
/// frame. This makes the block **stateful but still rate-1:1** — one flux value per
/// input spectrum. Output element `Scalar(f32)`.
///
/// State note: the `prev` carry is per-instance and advances exactly once per
/// processed frame, so a render split into sub-blocks leaves `prev` in the same
/// state as a single whole-block render (the per-hop S6 granularity).
pub fn SpectralFlux(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        /// The previous hop's power spectrum, zero before the stream began.
        prev: [bins]f32 = @splat(0),

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            for (in, out) |frame, *o| {
                var acc: f64 = 0;
                for (frame.v, &self.prev) |p, *pp| {
                    const d = p - pp.*;
                    if (d > 0) acc += @as(f64, d) * @as(f64, d);
                    pp.* = p; // carry the current spectrum forward
                }
                o.value = @floatCast(@sqrt(acc));
            }
        }
    };
}

// ===========================================================================
// Mfcc — mel-frequency cepstral coefficients
// ===========================================================================

/// The baked analysis conventions for `Mfcc`. The mel filterbank depends on the
/// sample rate and FFT size, which a graph block cannot read from the runtime
/// `Config`; they are fixed here as the standard analysis defaults so the
/// filterbank + DCT tables are built once at comptime (and baked into `.rodata`).
/// A graph driven at a different rate would re-instantiate `Mfcc` against a
/// matching constant — surfaced here rather than hidden.
const mfcc_sample_rate: f64 = 48_000.0;
const mfcc_n_mels: usize = 26;

fn hzToMel(hz: f64) f64 {
    return 2595.0 * std.math.log10(1.0 + hz / 700.0);
}
fn melToHz(mel: f64) f64 {
    return 700.0 * (std.math.pow(f64, 10.0, mel / 2595.0) - 1.0);
}

/// `Mfcc(num, bins, n_coeffs)` — the first `n_coeffs` mel-frequency cepstral
/// coefficients of the power spectrum, the classic timbral feature vector.
///
/// Pipeline (standard): `bins` power bins → `n_mels` triangular mel-band energies
/// (filterbank over `[0, sample_rate/2]`, `n_mels = 26`, `sample_rate = 48000`) →
/// natural log (floored at a tiny epsilon so silence is finite) → orthonormal
/// DCT-II → keep the first `n_coeffs` coefficients. The mel filterbank and the
/// DCT-II basis are built once at comptime. Output element `FeatureFrame(n_coeffs)`.
///
/// The `fft_size` the `bins` came from is taken as `2·(bins − 1)` (the real-FFT
/// convention `bins = fft_size/2 + 1`), so bin `k` sits at
/// `k · sample_rate / fft_size` Hz.
pub fn Mfcc(comptime num: numeric.Numeric, comptime bins: usize, comptime n_coeffs: usize) type {
    _ = num;
    if (bins < 2) @compileError("pan: Mfcc needs bins >= 2");
    if (n_coeffs == 0 or n_coeffs > mfcc_n_mels)
        @compileError("pan: Mfcc n_coeffs must be in 1..=n_mels (26)");
    const In = types.FeatureFrame(bins);
    const n_mels = mfcc_n_mels;

    // --- comptime: the triangular mel filterbank `[n_mels][bins]f32` ----------
    const filt: [n_mels][bins]f32 = comptime blk: {
        @setEvalBranchQuota(50_000);
        const fft_size: f64 = @floatFromInt(2 * (bins - 1));
        const f_max: f64 = mfcc_sample_rate / 2.0;
        const mel_max = hzToMel(f_max);
        // n_mels+2 mel points equally spaced; centers are the inner n_mels.
        var pts: [n_mels + 2]f64 = undefined;
        for (&pts, 0..) |*p, i| {
            const mel = mel_max * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_mels + 1));
            p.* = melToHz(mel);
        }
        var fb: [n_mels][bins]f32 = undefined;
        for (&fb) |*row| row.* = @splat(0);
        for (0..n_mels) |m| {
            const lo = pts[m];
            const ce = pts[m + 1];
            const hi = pts[m + 2];
            for (0..bins) |k| {
                const f = @as(f64, @floatFromInt(k)) * mfcc_sample_rate / fft_size;
                var w: f64 = 0;
                if (f >= lo and f <= ce and ce > lo) {
                    w = (f - lo) / (ce - lo);
                } else if (f > ce and f <= hi and hi > ce) {
                    w = (hi - f) / (hi - ce);
                }
                fb[m][k] = @floatCast(w);
            }
        }
        break :blk fb;
    };

    // --- comptime: the orthonormal DCT-II basis `[n_coeffs][n_mels]f32` --------
    const dct: [n_coeffs][n_mels]f32 = comptime blk: {
        @setEvalBranchQuota(50_000);
        var d: [n_coeffs][n_mels]f64 = undefined;
        const scale0 = std.math.sqrt(1.0 / @as(f64, @floatFromInt(n_mels)));
        const scalei = std.math.sqrt(2.0 / @as(f64, @floatFromInt(n_mels)));
        for (0..n_coeffs) |c| {
            const s = if (c == 0) scale0 else scalei;
            for (0..n_mels) |m| {
                const arg = std.math.pi * @as(f64, @floatFromInt(c)) *
                    (@as(f64, @floatFromInt(m)) + 0.5) / @as(f64, @floatFromInt(n_mels));
                d[c][m] = s * @cos(arg);
            }
        }
        var out: [n_coeffs][n_mels]f32 = undefined;
        for (0..n_coeffs) |c| for (0..n_mels) |m| {
            out[c][m] = @floatCast(d[c][m]);
        };
        break :blk out;
    };

    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.FeatureFrame(n_coeffs)) void {
            _ = self;
            for (in, out) |frame, *o| {
                // mel-band log energies
                var log_e: [n_mels]f64 = undefined;
                for (0..n_mels) |m| {
                    var e: f64 = 0;
                    for (frame.v, filt[m]) |p, w| e += @as(f64, p) * @as(f64, w);
                    log_e[m] = std.math.log(f64, std.math.e, @max(e, 1e-10));
                }
                // DCT-II onto the first n_coeffs
                for (0..n_coeffs) |c| {
                    var acc: f64 = 0;
                    for (0..n_mels) |m| acc += @as(f64, dct[c][m]) * log_e[m];
                    o.v[c] = @floatCast(acc);
                }
            }
        }
    };
}

test "feat blocks classify as Map and mint the right element types" {
    const port = @import("port.zig");
    const Num = numeric.numericFor(.f32, .{});
    try std.testing.expect(port.classify(Rms(Num, 8)) == .Map);
    try std.testing.expect(port.classify(DominantBand(Num, 8)) == .Map);
    try std.testing.expect(port.classify(SpectralCentroid(Num, 8)) == .Map);
    try std.testing.expect(port.classify(SpectralFlux(Num, 8)) == .Map);
    try std.testing.expect(port.classify(Mfcc(Num, 8, 4)) == .Map);
    try std.testing.expect(port.MapOutPort(DominantBand(Num, 8)).Elem == types.Scalar(u16));
    try std.testing.expect(port.MapOutPort(Mfcc(Num, 8, 4)).Elem == types.FeatureFrame(4));
}
