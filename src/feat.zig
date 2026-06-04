//! Feature-extraction blocks — the analysis side of the library.
//!
//! Every block here is a rate-1:1 **`Map`** over a per-hop **power spectrum**
//! (`FeatureFrame(bins)`, whose `v[k]` is the magnitude² of bin `k`, as emitted by
//! `spectral.PowerSpectrum`). A `Map` consumes one spectrum and emits one feature
//! per hop, i.e. one feature value per hop — one feature row per analysis frame,
//! the natural cadence for a per-frame downstream consumer. Holding per-call
//! history (the flux block keeps the
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
const spectral = @import("spectral.zig");

/// The baked analysis sample rate and reference shared by the rate/frequency-aware
/// blocks here (`Chroma`, and the documented bin→Hz mapping). A graph block cannot
/// read the runtime `Config` rate, so the standard analysis default is fixed at
/// comptime — surfaced rather than hidden; a different-rate graph re-instantiates
/// the block against a matching constant. (Mirrors `mfcc_sample_rate` below.)
const analysis_sample_rate: f64 = 48_000.0;

/// A float-lane guard for the time-domain blocks (which consume a `TimeFrame`, the
/// `Framer`'s float-only output element). Restating `spectral.requireFloat` locally
/// keeps the dependency one-directional and the error message specific.
fn requireFloatLane(comptime T: type) void {
    if (@typeInfo(T) != .float)
        @compileError("pan: this time-domain feature block requires a float lane (f32/f64); got " ++ @typeName(T));
}

// ===========================================================================
// Rms — broadband energy (a broadband amplitude/level descriptor)
// ===========================================================================

/// `Rms(num, bins)` — the per-hop broadband level, a broadband amplitude/level descriptor.
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
// DominantBand — the most active frequency bin (a band-index / dominant-frequency descriptor)
// ===========================================================================

/// `DominantBand(num, bins)` — the index of the loudest power-spectrum bin, a
/// band-index / dominant-frequency descriptor.
///
/// Formula: `out = argmax_k power[k]` (the first index attaining the maximum on a
/// tie). Output element `Scalar(u16)` — the bin index, not a Hz value; the
/// bin→Hz mapping (`k · sample_rate / fft_size`) is a downstream concern.
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

/// `SpectralCentroid(num, bins)` — the power-weighted mean bin index, a
/// brightness descriptor.
///
/// Formula: `out = (Σ_k k · power[k]) / (Σ_k power[k])`, in **bin units** (0 when
/// the spectrum is all-zero, by convention — a silent hop has no centroid). Output
/// element `Scalar(f32)`. (Multiply by `sample_rate / fft_size` downstream for Hz.)
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

// ===========================================================================
// SpectralRolloff — the frequency below which a fixed fraction of energy lies
// ===========================================================================

/// The energy fraction `SpectralRolloff` reports the boundary of. 0.85 is the
/// standard MIR convention (the bin under which 85% of the spectral energy sits).
const rolloff_fraction: f64 = 0.85;

/// `SpectralRolloff(num, bins)` — the **rolloff bin**: the lowest bin `k` such that
/// the cumulative power from bin 0 through `k` reaches `rolloff_fraction` (0.85) of
/// the total power. A brightness / spectral-shape descriptor (tonal-vs-noisy energy
/// distribution).
///
/// Formula: with `total = Σ_j power[j]`, the output is the smallest `k` for which
/// `Σ_{j≤k} power[j] ≥ 0.85 · total`, in **bin units** (0 when the spectrum is
/// all-zero, by convention). Output element `Scalar(f32)` (multiply by
/// `sample_rate / fft_size` downstream for Hz).
pub fn SpectralRolloff(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            for (in, out) |frame, *o| {
                var total: f64 = 0;
                for (frame.v) |p| total += @as(f64, p);
                var k_roll: u16 = 0;
                if (total > 0) {
                    const thresh = rolloff_fraction * total;
                    var cum: f64 = 0;
                    for (frame.v, 0..) |p, k| {
                        cum += @as(f64, p);
                        if (cum >= thresh) {
                            k_roll = @intCast(k);
                            break;
                        }
                    }
                }
                o.value = @floatFromInt(k_roll);
            }
        }
    };
}

// ===========================================================================
// SpectralFlatness — Wiener entropy (tonal vs noise-like)
// ===========================================================================

/// `SpectralFlatness(num, bins)` — the **Wiener entropy**: the ratio of the
/// geometric mean to the arithmetic mean of the power bins, in `[0, 1]`. Near 1 the
/// spectrum is flat (noise-like); near 0 it is peaky (tonal).
///
/// Formula: `out = exp( (1/bins) · Σ_k ln(max(power[k], ε)) ) / ( (1/bins) · Σ_k
/// power[k] )` with `ε = 1e-20` flooring the log so silent/zero bins stay finite.
/// The result is clamped to `[0, 1]`; an all-zero spectrum (arithmetic mean 0)
/// yields 0 by convention. Output element `Scalar(f32)`.
pub fn SpectralFlatness(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            const nf: f64 = @floatFromInt(bins);
            for (in, out) |frame, *o| {
                var sum: f64 = 0;
                var log_sum: f64 = 0;
                for (frame.v) |p| {
                    sum += @as(f64, p);
                    log_sum += @log(@max(@as(f64, p), 1e-20));
                }
                const arith = sum / nf;
                if (arith > 0) {
                    const geo = @exp(log_sum / nf);
                    o.value = @floatCast(std.math.clamp(geo / arith, 0.0, 1.0));
                } else {
                    o.value = 0;
                }
            }
        }
    };
}

// ===========================================================================
// SpectralEntropy — normalized Shannon entropy of the spectrum
// ===========================================================================

/// `SpectralEntropy(num, bins)` — the Shannon entropy of the power spectrum treated
/// as a probability distribution, normalized to `[0, 1]`. High when energy is spread
/// across many bins (noise-like), low when concentrated in few bins (tonal).
///
/// Formula: with `total = Σ_j power[j]` and `q_k = power[k] / total`, the output is
/// `( −Σ_k q_k · ln(q_k) ) / ln(bins)` (terms with `q_k = 0` contribute 0). The
/// `ln(bins)` denominator normalizes against the uniform-spectrum maximum, so the
/// result lies in `[0, 1]`; an all-zero spectrum yields 0. Output `Scalar(f32)`.
pub fn SpectralEntropy(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    if (bins < 2) @compileError("pan: SpectralEntropy needs bins >= 2 (ln(bins) normalizer)");
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            const norm: f64 = @log(@as(f64, @floatFromInt(bins)));
            for (in, out) |frame, *o| {
                var total: f64 = 0;
                for (frame.v) |p| total += @as(f64, p);
                if (total > 0) {
                    var h: f64 = 0;
                    for (frame.v) |p| {
                        const q = @as(f64, p) / total;
                        if (q > 0) h -= q * @log(q);
                    }
                    o.value = @floatCast(h / norm);
                } else {
                    o.value = 0;
                }
            }
        }
    };
}

// ===========================================================================
// Spectral moments — spread, skewness, kurtosis about the centroid
// ===========================================================================

/// `SpectralSpread(num, bins)` — the power-weighted standard deviation of bin index
/// about the spectral centroid (the second central moment's square root): how wide
/// the spectrum is around its center of mass.
///
/// Formula: with `total = Σ_k power[k]`, `c = (Σ_k k·power[k]) / total` (the
/// centroid), the output is `sqrt( Σ_k (k − c)² · power[k] / total )`, in **bin
/// units**. An all-zero spectrum yields 0. Output element `Scalar(f32)`.
pub fn SpectralSpread(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            for (in, out) |frame, *o| {
                var total: f64 = 0;
                var c_num: f64 = 0;
                for (frame.v, 0..) |p, k| {
                    total += @as(f64, p);
                    c_num += @as(f64, @floatFromInt(k)) * @as(f64, p);
                }
                if (total > 0) {
                    const c = c_num / total;
                    var var_acc: f64 = 0;
                    for (frame.v, 0..) |p, k| {
                        const d = @as(f64, @floatFromInt(k)) - c;
                        var_acc += d * d * @as(f64, p);
                    }
                    o.value = @floatCast(@sqrt(var_acc / total));
                } else {
                    o.value = 0;
                }
            }
        }
    };
}

/// `SpectralSkewness(num, bins)` — the power-weighted third standardized moment of
/// bin index about the centroid: the spectrum's asymmetry. Positive ⇒ a tail toward
/// higher bins, negative ⇒ toward lower bins, 0 ⇒ symmetric.
///
/// Formula: with centroid `c` and spread `σ` (as in `SpectralSpread`), the output is
/// `( Σ_k (k − c)³ · power[k] / total ) / σ³`. Defined 0 when the spectrum is
/// all-zero or has zero spread (σ = 0). Output element `Scalar(f32)`.
pub fn SpectralSkewness(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            for (in, out) |frame, *o| {
                o.value = @floatCast(standardizedMoment(bins, frame.v, 3));
            }
        }
    };
}

/// `SpectralKurtosis(num, bins)` — the power-weighted fourth standardized moment of
/// bin index about the centroid: the spectrum's peakedness/tailedness. This is the
/// **raw** (not excess) kurtosis — a Gaussian-shaped distribution gives ≈3.
///
/// Formula: with centroid `c` and spread `σ`, the output is `( Σ_k (k − c)⁴ ·
/// power[k] / total ) / σ⁴`. Defined 0 when the spectrum is all-zero or σ = 0.
/// Output element `Scalar(f32)`.
pub fn SpectralKurtosis(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            for (in, out) |frame, *o| {
                o.value = @floatCast(standardizedMoment(bins, frame.v, 4));
            }
        }
    };
}

/// The `order`-th standardized central moment of bin index weighted by `power`:
/// `( Σ_k (k − c)^order · power[k] / total ) / σ^order`, where `c` is the centroid
/// and `σ` the spread. Returns 0 when `total = 0` or `σ = 0`. Shared by the skewness
/// (order 3) and kurtosis (order 4) blocks; computed in `f64`.
fn standardizedMoment(comptime bins: usize, v: [bins]f32, comptime order: u32) f64 {
    var total: f64 = 0;
    var c_num: f64 = 0;
    for (v, 0..) |p, k| {
        total += @as(f64, p);
        c_num += @as(f64, @floatFromInt(k)) * @as(f64, p);
    }
    if (total <= 0) return 0;
    const c = c_num / total;
    var var_acc: f64 = 0;
    var mom_acc: f64 = 0;
    for (v, 0..) |p, k| {
        const d = @as(f64, @floatFromInt(k)) - c;
        var_acc += d * d * @as(f64, p);
        mom_acc += std.math.pow(f64, d, @floatFromInt(order)) * @as(f64, p);
    }
    const variance = var_acc / total;
    if (variance <= 0) return 0;
    const sigma = @sqrt(variance);
    return (mom_acc / total) / std.math.pow(f64, sigma, @floatFromInt(order));
}

// ===========================================================================
// SpectralCrest — peakiness (max / mean)
// ===========================================================================

/// `SpectralCrest(num, bins)` — the spectral crest factor: the ratio of the loudest
/// bin's power to the mean power. 1 for a flat spectrum, large for a single dominant
/// tone — a simple tonality/peakiness descriptor.
///
/// Formula: `out = max_k power[k] / ( (1/bins) · Σ_k power[k] )`. An all-zero
/// spectrum (mean 0) yields 0 by convention. Output element `Scalar(f32)`.
pub fn SpectralCrest(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            const nf: f64 = @floatFromInt(bins);
            for (in, out) |frame, *o| {
                var sum: f64 = 0;
                var peak: f64 = 0;
                for (frame.v) |p| {
                    const pf = @as(f64, p);
                    sum += pf;
                    if (pf > peak) peak = pf;
                }
                const mean = sum / nf;
                o.value = if (mean > 0) @floatCast(peak / mean) else 0;
            }
        }
    };
}

// ===========================================================================
// Hfc — high-frequency content (Masri)
// ===========================================================================

/// `Hfc(num, bins)` — the high-frequency content (Masri): the bin-index-weighted sum
/// of power, emphasizing energy in higher bins. A bright/onset-leaning descriptor —
/// transients with broadband high-frequency energy spike it.
///
/// Formula: `out = Σ_k k · power[k]` (bin index as the weight). Accumulated in `f64`;
/// 0 on silence (and on all-DC, since bin 0 has weight 0). Output `Scalar(f32)`.
pub fn Hfc(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(f32)) void {
            _ = self;
            for (in, out) |frame, *o| {
                var acc: f64 = 0;
                for (frame.v, 0..) |p, k| acc += @as(f64, @floatFromInt(k)) * @as(f64, p);
                o.value = @floatCast(acc);
            }
        }
    };
}

// ===========================================================================
// Chroma — 12-bin pitch-class profile
// ===========================================================================

/// `Chroma(num, bins)` — the 12-bin **pitch-class profile** (chromagram): power
/// folded from the `bins` linear-frequency bins onto the 12 chromatic pitch classes,
/// collapsing octaves. The classic harmony/key descriptor.
///
/// Each bin `k` sits at `f = k · sample_rate / fft_size` Hz (with `sample_rate =
/// 48000`, `fft_size = 2·(bins−1)`). Bins below 20 Hz (and DC, bin 0) are dropped.
/// A live bin maps to pitch class `pc = round(12 · log2(f / 440)) mod 12` (pitch
/// class 0 = the 440 Hz reference A, increasing by semitone); its power adds into
/// `chroma[pc]`. The 12-vector is then scaled so its maximum entry is 1 (an all-zero
/// frame stays all-zero). The bin→class map is built once at comptime. Output
/// element `FeatureFrame(12)`.
pub fn Chroma(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    if (bins < 2) @compileError("pan: Chroma needs bins >= 2");
    const In = types.FeatureFrame(bins);

    // --- comptime: bin → pitch class (or -1 for "dropped") --------------------
    const klass: [bins]i32 = comptime blk: {
        @setEvalBranchQuota(50_000);
        const fft_size: f64 = @floatFromInt(2 * (bins - 1));
        const f_ref: f64 = 440.0;
        const f_min: f64 = 20.0;
        var m: [bins]i32 = undefined;
        for (0..bins) |k| {
            const f = @as(f64, @floatFromInt(k)) * analysis_sample_rate / fft_size;
            if (k == 0 or f < f_min) {
                m[k] = -1;
            } else {
                const semis = 12.0 * std.math.log2(f / f_ref);
                const r = std.math.round(semis);
                // Euclidean mod 12 (round can be negative for f < f_ref).
                var pc = @as(i32, @intFromFloat(r)) % 12;
                if (pc < 0) pc += 12;
                m[k] = pc;
            }
        }
        break :blk m;
    };

    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.FeatureFrame(12)) void {
            _ = self;
            for (in, out) |frame, *o| {
                var acc: [12]f64 = @splat(0);
                for (frame.v, 0..) |p, k| {
                    const pc = klass[k];
                    if (pc >= 0) acc[@intCast(pc)] += @as(f64, p);
                }
                var peak: f64 = 0;
                for (acc) |a| {
                    if (a > peak) peak = a;
                }
                if (peak > 0) {
                    for (&o.v, acc) |*ov, a| ov.* = @floatCast(a / peak);
                } else {
                    o.v = @splat(0);
                }
            }
        }
    };
}

// ===========================================================================
// SpectralContrast — octave-band peak-to-valley level difference
// ===========================================================================

/// `SpectralContrast(num, bins, n_bands)` — the per-octave-band **peak-to-valley
/// contrast**: for each of `n_bands` geometrically spaced sub-bands, the log
/// difference between the loudest and quietest bin. High contrast ⇒ a clear
/// harmonic peak over a quiet floor (tonal); low contrast ⇒ flat/noisy. A timbre /
/// harmonicity descriptor (Jiang 2002, octave-based spectral contrast).
///
/// The `bins` (excluding DC) are split into `n_bands` bands with geometric
/// (octave-like) edges `e[b] = round( (bins−1)^(b/n_bands) )`, `b = 0..n_bands`, so
/// band `b` covers bins `[max(1,e[b]), e[b+1])`. For each band, `peak = max` and
/// `valley = min` of its power bins; the output coefficient is `ln(peak + ε) −
/// ln(valley + ε)` with `ε = 1e-10`. An empty band (collapsed by rounding) emits 0.
/// Band edges are baked at comptime. Output element `FeatureFrame(n_bands)`.
pub fn SpectralContrast(comptime num: numeric.Numeric, comptime bins: usize, comptime n_bands: usize) type {
    _ = num;
    if (bins < 3) @compileError("pan: SpectralContrast needs bins >= 3");
    if (n_bands == 0 or n_bands > bins - 1)
        @compileError("pan: SpectralContrast n_bands must be in 1..=bins-1");
    const In = types.FeatureFrame(bins);

    // --- comptime: the band [lo, hi) edges over bins [1, bins) ----------------
    const edges: [n_bands + 1]usize = comptime blk: {
        @setEvalBranchQuota(50_000);
        var e: [n_bands + 1]usize = undefined;
        const span: f64 = @floatFromInt(bins - 1);
        var prev: usize = 1;
        for (0..n_bands + 1) |b| {
            const frac = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(n_bands));
            var idx: usize = @intFromFloat(std.math.round(std.math.pow(f64, span, frac)));
            if (idx < 1) idx = 1;
            if (idx > bins - 1) idx = bins - 1;
            // keep the edge sequence non-decreasing
            if (b > 0 and idx < prev) idx = prev;
            e[b] = idx;
            prev = idx;
        }
        e[n_bands] = bins - 1; // last band closes at the top bin (exclusive upper)
        break :blk e;
    };

    return struct {
        const Self = @This();

        pub fn process(self: *Self, in: []const In, out: []types.FeatureFrame(n_bands)) void {
            _ = self;
            for (in, out) |frame, *o| {
                inline for (0..n_bands) |b| {
                    const lo = edges[b];
                    const hi = edges[b + 1];
                    if (hi > lo) {
                        var peak: f64 = frame.v[lo];
                        var valley: f64 = frame.v[lo];
                        var k = lo;
                        while (k < hi) : (k += 1) {
                            const pf = @as(f64, frame.v[k]);
                            if (pf > peak) peak = pf;
                            if (pf < valley) valley = pf;
                        }
                        o.v[b] = @floatCast(@log(peak + 1e-10) - @log(valley + 1e-10));
                    } else {
                        o.v[b] = 0;
                    }
                }
            }
        }
    };
}

// ===========================================================================
// DominantBandHysteresis — flicker-free dominant band (a dominant-band color/frequency-index descriptor)
// ===========================================================================

/// The leaky-integration pole for `DominantBandHysteresis`: each hop, the held
/// per-bin power moves a fraction `(1 − λ)` toward the new spectrum. λ near 1 ⇒
/// heavy smoothing (slow, stable); 0 ⇒ no memory.
const dom_lambda: f32 = 0.7;
/// The hysteresis margin for `DominantBandHysteresis`: a challenger bin must exceed
/// the held bin's smoothed power by this fraction before the dominant band switches,
/// which suppresses single-frame flicker between near-equal bins.
const dom_margin: f32 = 0.5;

/// `DominantBandHysteresis(num, bins)` — a **flicker-free** dominant-band
/// (color/frequency-index) descriptor. Unlike the stateless
/// `DominantBand` (a raw per-hop argmax that can jitter between near-equal bins),
/// this leaky-integrates the spectrum over time and only switches the reported band
/// when a challenger decisively beats the incumbent.
///
/// State and update (per hop): a smoothed power `s[k]` per bin, leaky-integrated as
/// `s[k] ← λ · s[k] + (1 − λ) · power[k]` (`λ = 0.7`, `s` zero before the first
/// hop). Let `c = argmax_k s[k]` (first index on a tie). The held band switches to
/// `c` only if `s[c] > s[held] · (1 + margin)` (`margin = 0.5`); otherwise the held
/// band is retained. The first hop switches immediately (held starts at bin 0 with
/// `s[0] = 0`). Output `Scalar(u16)` — the bin index.
///
/// State note: `s` and `held` are per-instance and advance exactly once per
/// processed frame, so a render split into sub-blocks leaves the state identical to
/// a single whole-block render (the per-hop S6 granularity).
pub fn DominantBandHysteresis(comptime num: numeric.Numeric, comptime bins: usize) type {
    _ = num;
    if (bins == 0) @compileError("pan: DominantBandHysteresis needs bins >= 1");
    const In = types.FeatureFrame(bins);
    return struct {
        const Self = @This();

        /// The leaky-integrated per-bin power, zero before the stream began.
        smoothed: [bins]f32 = @splat(0),
        /// The currently reported (held) dominant bin.
        held: u16 = 0,

        pub fn process(self: *Self, in: []const In, out: []types.Scalar(u16)) void {
            for (in, out) |frame, *o| {
                // leaky-integrate, tracking the challenger argmax
                var best: f32 = -1;
                var best_k: u16 = 0;
                for (&self.smoothed, frame.v, 0..) |*s, p, k| {
                    s.* = dom_lambda * s.* + (1 - dom_lambda) * p;
                    if (s.* > best) {
                        best = s.*;
                        best_k = @intCast(k);
                    }
                }
                // switch only if the challenger decisively beats the incumbent
                if (self.smoothed[best_k] > self.smoothed[self.held] * (1 + dom_margin)) {
                    self.held = best_k;
                }
                o.value = self.held;
            }
        }
    };
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

test "extended feat blocks classify as Map and mint the right element types" {
    const port = @import("port.zig");
    const Num = numeric.numericFor(.f32, .{});
    const BINS = 16;
    const FRAME = 32;

    // Spectrum-consuming Maps → Scalar(f32) (the moment/shape descriptors).
    inline for (.{
        SpectralRolloff(Num, BINS),  SpectralFlatness(Num, BINS),
        SpectralEntropy(Num, BINS),  SpectralSpread(Num, BINS),
        SpectralSkewness(Num, BINS), SpectralKurtosis(Num, BINS),
        SpectralCrest(Num, BINS),    Hfc(Num, BINS),
    }) |Block| {
        try std.testing.expect(port.classify(Block) == .Map);
        try std.testing.expect(port.MapInPort(Block).Elem == types.FeatureFrame(BINS));
        try std.testing.expect(port.MapOutPort(Block).Elem == types.Scalar(f32));
    }

    // Vector-valued spectrum Maps → FeatureFrame(K).
    try std.testing.expect(port.classify(Chroma(Num, BINS)) == .Map);
    try std.testing.expect(port.MapOutPort(Chroma(Num, BINS)).Elem == types.FeatureFrame(12));
    try std.testing.expect(port.classify(SpectralContrast(Num, BINS, 6)) == .Map);
    try std.testing.expect(port.MapOutPort(SpectralContrast(Num, BINS, 6)).Elem == types.FeatureFrame(6));

    // The flicker-free dominant tracker → Scalar(u16) (the dominant-band (color-index) descriptor).
    try std.testing.expect(port.classify(DominantBandHysteresis(Num, BINS)) == .Map);
    try std.testing.expect(port.MapOutPort(DominantBandHysteresis(Num, BINS)).Elem == types.Scalar(u16));

    // Time-domain Maps over a TimeFrame(T, FRAME) → Scalar(f32).
    inline for (.{ Zcr(Num, FRAME), TeoMean(Num, FRAME), BallisticEnvelope(Num, FRAME) }) |Block| {
        try std.testing.expect(port.classify(Block) == .Map);
        try std.testing.expect(port.MapInPort(Block).Elem == spectral.TimeFrame(f32, FRAME));
        try std.testing.expect(port.MapOutPort(Block).Elem == types.Scalar(f32));
    }
}
