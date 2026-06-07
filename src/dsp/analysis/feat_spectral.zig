//! Spectral-shape / moment / energy feature descriptors — the analysis blocks
//! that read a per-hop power spectrum (`FeatureFrame(bins)`, whose `v[k]` is the
//! magnitude² of bin `k`, as emitted by `spectral.PowerSpectrum`) and emit one
//! scalar descriptor per hop.
//!
//! Every block is a rate-1:1 `Map`: one spectrum in, one feature out per hop.
//! Holding per-call history (the flux block keeps the previous spectrum) does NOT
//! make a block a `Rate` — a `Rate` changes the output:input element count; a
//! stateful `Map` still emits one-for-one. These are not proven correct — they are
//! tested against an external NumPy/librosa-equivalent oracle, so each block's
//! doc-comment states its exact formula and conventions in plain prose. All
//! features are computed in `f32`/`f64` regardless of the audio `Numeric`, because
//! the power spectrum is already `f32`.

const std = @import("std");
const core = @import("pan_core");
const numeric = core.numeric;
const types = core.types;

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

        /// Timeline-chunking warm-up, in this Map's input element (one HOP /
        /// FeatureFrame per element). The only cross-hop state is `prev`, the
        /// immediately preceding spectrum. Feeding ONE frame of lead-in before a
        /// chunk's first real output processes that prior frame, leaving `prev`
        /// bit-identical to what a whole-timeline render would hold at the chunk
        /// boundary — hence exact, not tolerance-bounded.
        ///
        /// Scope of the warm-up lever (applies to every warm-up-declaring feat
        /// Map here): declaring `warmup_samples` only unlocks data-parallel
        /// timeline chunking for a LINEAR chain in which EVERY node declares it,
        /// expressed in the chain's element unit (hops/frames here). It does NOT
        /// make a full fan-out analysis DAG chunkable: such graphs route through a
        /// frame-domain Framer/Stft re-blocker (a rate-changing block that is not
        /// in this per-element warm-up model) and have fan-out, so they stay on
        /// the sequential or file-level path. These declarations let a feat block
        /// participate in a chunkable hop-domain linear stage, not in the DAG.
        pub const warmup_samples: usize = 1;
        pub const warmup_exact: bool = true;

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
// Tests — Map classification + minted element types. These two cover the whole
// feat surface (the autonomous Yoneda + NumPy-oracle suite owns the numerics),
// so they reach across the family files via sibling imports of the tonal and
// temporal blocks.
// ===========================================================================

const spectral = @import("../spectral/spectral.zig");
const feat_tonal = @import("feat_tonal.zig");
const feat_temporal = @import("feat_temporal.zig");
const Mfcc = feat_tonal.Mfcc;
const Chroma = feat_tonal.Chroma;
const SpectralContrast = feat_tonal.SpectralContrast;
const DominantBandHysteresis = feat_tonal.DominantBandHysteresis;
const Zcr = feat_temporal.Zcr;
const TeoMean = feat_temporal.TeoMean;
const BallisticEnvelope = feat_temporal.BallisticEnvelope;

test "feat blocks classify as Map and mint the right element types" {
    const port = core.port;
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
    const port = core.port;
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
