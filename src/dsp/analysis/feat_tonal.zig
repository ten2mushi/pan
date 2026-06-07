//! Pitch / timbre feature descriptors — MFCCs, the chromagram, octave-band
//! spectral contrast, and the flicker-free dominant-band tracker.
//!
//! Each block is a rate-1:1 `Map` over a per-hop power spectrum
//! (`FeatureFrame(bins)`, whose `v[k]` is the magnitude² of bin `k`). It emits one
//! feature (a vector `FeatureFrame(K)` or a `Scalar`) per hop. Holding per-call
//! history (the dominant-band tracker's smoothed power) does NOT make a block a
//! `Rate` — a `Rate` changes the output:input element count; a stateful `Map` still
//! emits one-for-one. These are tested against an external NumPy/librosa-equivalent
//! oracle, so each doc-comment states its exact formula in plain prose. All features
//! are computed in `f32`/`f64` regardless of the audio `Numeric`.

const std = @import("std");
const core = @import("pan_core");
const numeric = core.numeric;
const types = core.types;

/// The baked analysis sample rate and reference shared by the rate/frequency-aware
/// blocks here (`Chroma`, and the documented bin→Hz mapping). A graph block cannot
/// read the runtime `Config` rate, so the standard analysis default is fixed at
/// comptime — surfaced rather than hidden; a different-rate graph re-instantiates
/// the block against a matching constant. (Mirrors `mfcc_sample_rate` below.)
const analysis_sample_rate: f64 = 48_000.0;

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

        /// Timeline-chunking warm-up, in HOPs (FeatureFrames). The smoothed
        /// power is a leaky integrator `s ← 0.7·s + 0.3·power`, so a wrong
        /// boundary value decays by 0.7 each frame: after n frames its residual
        /// influence is 0.7^n. Thirteen frames drives that residual to
        /// 0.7^13 ≈ 9.7e-3 of the original error — small enough that the
        /// reconstructed `smoothed` is within tolerance of the true value. The
        /// `held` band is a LATCHED hysteresis decision (not a decaying
        /// quantity), so even an exact `smoothed` cannot guarantee a bit-exact
        /// `held` across a chunk seam — hence the warm-up is tolerance-bounded
        /// (allclose), never bit-exact.
        pub const warmup_samples: usize = 13;
        pub const warmup_exact: bool = false;

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
