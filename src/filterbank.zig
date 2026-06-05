//! Multi-rate filterbanks — DWT octave trees and a constant-Q bank — built the
//! ONLY way the rate-elastic seam allows: as a CASCADE / BANK of uniform-rate
//! `Rate` stages, never as one block.
//!
//! A `Rate` block carries a SINGLE `out_per_in` ratio for the whole block; it
//! cannot describe a processor whose several outputs run at different rates. A
//! wavelet octave decomposition and a constant-Q transform are exactly such
//! processors, so they are not single `Rate` blocks — they DECOMPOSE:
//!
//!   - The wavelet octave tree is a CASCADE of identical 2-band analysis stages.
//!     Each stage is one uniform-rate `Rate` block (`out_per_in = 1:2`): it emits
//!     ONE `Subband{lo, hi}` element — carrying BOTH subbands, which therefore
//!     share the single stage rate — per TWO input samples. The tree applies that
//!     same stage recursively to the LOWPASS (approximation) band, so each deeper
//!     level runs at half the rate of the one above it; the per-level rates differ
//!     only BETWEEN cascade stages, never WITHIN one. That keeps every stage's
//!     `pull`/`needed_input` single-ratio, which is what makes the rate scheduler's
//!     recursion decidable.
//!
//!   - The constant-Q transform is a BANK of independent bandpass `Rate`/`Map`
//!     stages, one per geometrically-spaced centre frequency, each with the SAME
//!     quality factor `Q = f_c / Δf` (so the bandwidth Δf grows with f_c and the
//!     per-band time/frequency resolution is constant across the bank).
//!
//! **Wavelet family — Haar (`db1`) only (surfaced simplification).** The 2-band
//! stages implement the orthonormal Haar wavelet:
//!
//!     lo[n] = (x[2n] + x[2n+1]) / √2      (lowpass / approximation, ↓2)
//!     hi[n] = (x[2n] − x[2n+1]) / √2      (highpass / detail, ↓2)
//!
//! Haar is the one wavelet whose analysis→synthesis round-trip is EXACT perfect
//! reconstruction with ZERO delay (the synthesis inverts each 2×2 orthogonal
//! rotation locally), so it is the correctness oracle for the whole cascade.
//! Longer Daubechies families (db2/db4) need a multi-tap history ring and a
//! non-zero analysis/synthesis group delay; they are NOT implemented here — the
//! Haar core proves the rate decomposition and the reconstruction law without the
//! extra machinery.
//!
//! **Float-only.** Like the rest of the rate-elastic seam, these blocks need real
//! arithmetic (the 1/√2 rotation, the windowed-sinc bandpass kernels); the
//! fixed-point path would need the wide-accumulator block-floating-point treatment
//! the fixed-point `Biquad` uses and is not ported, so the integer lane fails loud.

const std = @import("std");
const types = @import("types.zig");
const numeric = @import("numeric.zig");
const filters = @import("filters.zig");

fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

fn requireFloat(comptime T: type) void {
    if (!isFloat(T))
        @compileError("pan: the multi-rate filterbank (DWT / CQT) blocks are float-only" ++
            " — the fixed-point (block-floating-point) path is not ported here. Use f32/f64.");
}

/// View a mono `Sample(T)` slice as its underlying scalar `[]T` — `Sample(T)` is
/// `Frame(T,.mono)`, layout-identical to a bare `T`, so the reinterpret is exact.
fn scalarsConst(comptime T: type, frames: []const types.Sample(T)) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}
fn scalars(comptime T: type, frames: []types.Sample(T)) []T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}

// ===========================================================================
// Subband — the 2-band analysis stage's output element
// ===========================================================================

/// `Subband(T)` — one critically-sampled 2-band analysis output: the lowpass
/// (approximation) and highpass (detail) coefficient produced from one input
/// PAIR. Both coefficients live in ONE element because both subbands share the
/// stage's single decimated rate (the rule that keeps a multi-rate filterbank a
/// cascade of uniform-rate `Rate` stages, not a per-output-port-rate block). A
/// named struct carrying a `typeName()`, so it is a legal port element and a
/// pool-class key `(Subband(T), want)`.
pub fn Subband(comptime T: type) type {
    return struct {
        lo: T = 0,
        hi: T = 0,

        pub const lane = T;

        pub fn typeName() []const u8 {
            return std.fmt.comptimePrint("Subband({s})", .{@typeName(T)});
        }
    };
}

// ===========================================================================
// WaveletAnalysis — Sample -> Subband (Rate, 1:2), Haar
// ===========================================================================

/// `WaveletAnalysis(num)` — the orthonormal Haar 2-band analysis stage: one
/// `Subband{lo, hi}` per TWO input samples (`out_per_in = 1:2`). For each input
/// pair `(a, b) = (x[2n], x[2n+1])`:
///
///     lo = (a + b) / √2      hi = (a − b) / √2
///
/// the orthonormal Haar lowpass/highpass with ↓2 decimation folded in (the
/// filter is length 2, so "filter then decimate" is just this per-pair rotation).
/// Both outputs are decimated-by-2 and share the one stage rate — the single
/// ratio R5 requires.
///
/// **Zero group delay.** Each `Subband` depends only on its own input pair, so
/// the stage adds no algorithmic latency; the matched `WaveletSynthesis` inverts
/// it sample-aligned, giving EXACT (un-delayed) perfect reconstruction.
///
/// The only state is the first sample of an in-progress pair held across a `pull`
/// that ended on an odd boundary, so a render chopped at any sample equals a whole
/// render (no input is ever dropped on a mis-aligned chunk).
pub fn WaveletAnalysis(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    const Out = Subband(T);
    const inv_sqrt2: T = 1.0 / @sqrt(@as(T, 2.0));
    return struct {
        const Self = @This();

        /// One `Subband` (carrying both subbands) per two input samples.
        pub const out_per_in = .{ 1, 2 };
        /// Each output depends only on its own input pair — no priming delay.
        pub const algorithmic_latency: usize = 0;
        pub const state_size: usize = @sizeOf(T) + @sizeOf(bool);

        /// The first sample of an in-progress pair, held when a `pull` ended on an
        /// odd input boundary (`have_first` true). Persists across calls.
        first: T = 0,
        have_first: bool = false,

        /// How many input samples `want` output subbands consume: two each.
        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return want * 2;
        }

        pub fn pull(self: *Self, in: []const types.Sample(T), want: usize, out: []Out) usize {
            const xs = scalarsConst(T, in);
            var produced: usize = 0;
            for (xs) |x| {
                if (!self.have_first) {
                    self.first = x;
                    self.have_first = true;
                } else {
                    self.have_first = false;
                    if (produced < want) {
                        const a = self.first;
                        const b = x;
                        out[produced] = .{ .lo = (a + b) * inv_sqrt2, .hi = (a - b) * inv_sqrt2 };
                        produced += 1;
                    }
                }
            }
            return produced;
        }
    };
}

// ===========================================================================
// WaveletSynthesis — Subband -> Sample (Rate, 2:1), Haar
// ===========================================================================

/// `WaveletSynthesis(num)` — the inverse Haar 2-band synthesis stage: TWO output
/// samples per input `Subband` (`out_per_in = 2:1`). It inverts the analysis
/// rotation exactly:
///
///     x[2n]   = (lo + hi) / √2      x[2n+1] = (lo − hi) / √2
///
/// Because the Haar analysis rotation is orthogonal (its inverse is its
/// transpose, and 1/√2·1/√2 added/subtracted recovers the originals), this is
/// EXACT perfect reconstruction with ZERO delay: `WaveletSynthesis ∘
/// WaveletAnalysis` is the identity, sample-aligned, up to f32 round-off. That is
/// the decisive correctness oracle for the cascade.
pub fn WaveletSynthesis(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    const In = Subband(T);
    const inv_sqrt2: T = 1.0 / @sqrt(@as(T, 2.0));
    return struct {
        const Self = @This();

        /// Two reconstructed samples per input subband.
        pub const out_per_in = .{ 2, 1 };
        /// The local inverse rotation adds no group delay.
        pub const algorithmic_latency: usize = 0;
        pub const state_size: usize = 0;

        _unused: usize = 0,

        /// How many input subbands `want` output samples require: one per two.
        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return (want + 1) / 2; // ceil(want / 2)
        }

        pub fn pull(self: *Self, in: []const In, want: usize, out: []types.Sample(T)) usize {
            _ = self;
            const ys = scalars(T, out);
            const pairs = @min(in.len, want / 2);
            var k: usize = 0;
            while (k < pairs) : (k += 1) {
                const lo = in[k].lo;
                const hi = in[k].hi;
                ys[2 * k] = (lo + hi) * inv_sqrt2;
                ys[2 * k + 1] = (lo - hi) * inv_sqrt2;
            }
            return pairs * 2;
        }
    };
}

// ===========================================================================
// DwtOctaveTree — comptime cascade of WaveletAnalysis stages
// ===========================================================================

/// `DwtOctaveTree(num, levels)` — the discrete wavelet octave-band CASCADE: apply
/// the Haar 2-band analysis recursively to the LOWPASS (approximation) band
/// `levels` times. It is a cascade of `levels` `WaveletAnalysis` `Rate` stages,
/// NOT one block — the deeper a stage, the lower its rate (each operates on the
/// previous stage's decimated approximation).
///
/// Band structure for `levels = L`, over an input run of `N` samples:
///
///   - Stage 0 splits the input into detail `d[0]` (`N/2` highpass coefficients,
///     the FINEST octave) and approximation `a[0]` (`N/2` lowpass coefficients).
///   - Stage i (1 ≤ i < L) splits `a[i-1]` into detail `d[i]` (`N/2^(i+1)`
///     coefficients) and approximation `a[i]`.
///   - The outputs are the `L` detail bands `d[0..L]` plus the final approximation
///     `a[L-1]`. Band `d[i]` runs at rate `1 / 2^(i+1)` of the input; the final
///     approximation `a[L-1]` runs at `1 / 2^L`. So `L` levels yield `L + 1`
///     octave bands whose rates HALVE down the cascade — different rates BETWEEN
///     stages, one uniform rate WITHIN each stage (the R5 decomposition).
///
/// This type owns the `levels` analysis stages and exposes `analyze`, which runs a
/// whole input run through the cascade and writes each band into a caller-provided
/// per-level buffer. A `levels = 0` tree is rejected (it would decompose nothing).
pub fn DwtOctaveTree(comptime num: numeric.Numeric, comptime levels: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (levels == 0) @compileError("pan: DwtOctaveTree needs at least one level");
    const Stage = WaveletAnalysis(num);
    const SB = Subband(T);
    return struct {
        const Self = @This();

        /// The number of octave decomposition levels (cascade depth).
        pub const level_count = levels;
        /// The number of output bands: `levels` detail bands + 1 final approximation.
        pub const band_count = levels + 1;

        /// One Haar analysis stage per level; stage `i` consumes the approximation
        /// of stage `i-1`. Each carries its own pair-boundary state.
        stages: [levels]Stage = [_]Stage{.{}} ** levels,

        /// Run `in` (one whole input run) through the cascade. The detail band of
        /// level `i` is written as the `hi` lanes into `details[i]`, and the final
        /// approximation as the `lo`/`hi`-recombined samples into `approx`. Each
        /// `details[i]` must hold at least `in.len / 2^(i+1)` samples and `approx`
        /// at least `in.len / 2^levels`. Returns, per level, how many detail
        /// coefficients were produced, plus the approximation length, as a struct.
        ///
        /// `scratch` is a caller-provided ping-pong pair of `Subband` buffers, each
        /// at least `in.len / 2` long — the per-stage decimated approximation is fed
        /// to the next stage as samples, so the cascade needs working room for the
        /// largest (stage-0) subband run; the tree allocates nothing itself.
        pub fn analyze(
            self: *Self,
            in: []const types.Sample(T),
            details: *const [levels][]T,
            approx: []T,
            scratch_sb: []SB,
            scratch_lo: []types.Sample(T),
        ) DwtCounts(levels) {
            var counts: DwtCounts(levels) = .{ .detail = [_]usize{0} ** levels, .approx = 0 };
            // `cur` is the running approximation fed into the next stage. Stage 0
            // reads the original input; each later stage reads the previous
            // approximation re-viewed as samples.
            var cur: []const types.Sample(T) = in;
            inline for (0..levels) |i| {
                const want = cur.len / 2;
                const made = self.stages[i].pull(cur, want, scratch_sb[0..want]);
                // Detail band = the highpass coefficients of this stage.
                for (0..made) |j| details[i][j] = scratch_sb[j].hi;
                counts.detail[i] = made;
                // The approximation (lowpass) becomes the next stage's input
                // samples (and, on the last level, the final approximation output).
                for (0..made) |j| scratch_lo[j].ch[0] = scratch_sb[j].lo;
                if (i + 1 == levels) {
                    for (0..made) |j| approx[j] = scratch_sb[j].lo;
                    counts.approx = made;
                } else {
                    cur = scratch_lo[0..made];
                }
            }
            return counts;
        }
    };
}

/// Per-level produced-coefficient counts returned by `DwtOctaveTree.analyze`: the
/// detail-band length at each level and the final approximation length.
pub fn DwtCounts(comptime levels: usize) type {
    return struct {
        detail: [levels]usize,
        approx: usize,
    };
}

// ===========================================================================
// Cqt — constant-Q bandpass bank
// ===========================================================================

/// One constant-Q band: a windowed-sinc bandpass `Fir` centred on `fc` with a
/// fractional bandwidth `1/Q`, plus that band's centre frequency for reference.
fn CqtBand(comptime num: numeric.Numeric, comptime taps: usize) type {
    return struct {
        fir: filters.Fir(num, taps),
        fc: num.Lane,
    };
}

/// `Cqt(num, bins, taps)` — a constant-Q BANK: `bins` bandpass `Fir` stages at
/// geometrically-spaced centre frequencies, each with the SAME quality factor
/// `Q = f_c / Δf`, so the bandwidth grows with the centre frequency and every
/// band has the same number of cycles in its impulse response (constant relative
/// resolution — the defining constant-Q property). It is a BANK of uniform-rate
/// stages, NOT one block, exactly as a multi-rate filterbank must decompose.
///
/// The bank is parameterised by the lowest centre frequency `f_min` (normalized
/// cycles/sample, `0 < f_min < 0.5`) and the number of bins PER OCTAVE
/// `bins_per_octave`, set at construction. Band `k`'s centre is
///
///     f_c[k] = f_min · 2^(k / bins_per_octave)
///
/// and its bandwidth is `Δf[k] = f_c[k] / Q`, where `Q = 1 / (2^(1/bins_per_octave) − 1)`
/// is the quality factor that makes adjacent bands meet at their −3 dB points (the
/// standard constant-Q geometry). Each band is realised as a bandpass FIR: a
/// windowed-sinc lowpass at the upper edge minus one at the lower edge
/// (`f_c · 2^(±1/(2·bins_per_octave))`), so the passband spans exactly one
/// constant-Q bin. The per-band FIR is a rate-1:1 `Map`, so the bank as a whole is
/// run at the input rate and emits, per input sample, one `FeatureFrame(bins)` of
/// the `bins` band outputs — the canonical type-changing analysis `Map`.
///
/// **Surfaced simplifications (Rule 12).** This is the bandpass-bank CORE of a CQT,
/// not a full constant-Q transform: (1) the bands are NOT individually decimated —
/// a true CQT downsamples each band to its critical rate (which would make each
/// band a separate `Rate` stage at its own decimated rate); this bank keeps every
/// band at the input rate, trading the multi-rate footprint saving for a single
/// uniform rate. (2) The output is the per-sample band MAGNITUDE-less raw bandpass
/// signal collapsed to its instantaneous value, not a windowed per-bin complex
/// coefficient; a magnitude/energy reduction is a downstream feature `Map`. (3) The
/// FIR tap count is a fixed comptime `taps` for ALL bands; a true CQT scales the
/// kernel length per band (longer for lower bands to hold constant Q), so the
/// lowest bands here are under-resolved relative to an ideal CQT. These keep the
/// core small and correct (a tone at a band centre concentrates in that band and
/// distant tones are rejected) while naming exactly what a production CQT adds.
pub fn Cqt(comptime num: numeric.Numeric, comptime bins: usize, comptime taps: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (bins == 0) @compileError("pan: Cqt needs at least one band");
    if (taps == 0) @compileError("pan: Cqt needs at least one tap per band");
    return struct {
        const Self = @This();

        /// The number of constant-Q bands (output feature columns).
        pub const bin_count = bins;

        /// The bandpass bank: one FIR + its centre frequency per band.
        bands: [bins]CqtBand(num, taps) = undefined,

        /// Build a constant-Q bank with lowest centre `f_min` (cycles/sample) and
        /// `bins_per_octave` geometric bins per octave. Each band's bandpass FIR is
        /// designed once here from the constant-Q geometry; the resulting `Self` is
        /// a ready-to-run bank.
        pub fn init(comptime f_min: T, comptime bins_per_octave: T) Self {
            comptime {
                if (f_min <= 0 or f_min >= 0.5)
                    @compileError("pan: Cqt f_min must be in (0, 0.5) cycles/sample");
                if (bins_per_octave <= 0)
                    @compileError("pan: Cqt bins_per_octave must be > 0");
            }
            var self: Self = .{ .bands = undefined };
            // Half-octave edge ratio: a band centred at f_c spans
            // [f_c·2^(-1/(2·bpo)), f_c·2^(+1/(2·bpo))], one constant-Q bin wide.
            const half_edge: T = comptime std.math.pow(T, 2.0, 1.0 / (2.0 * bins_per_octave));
            inline for (0..bins) |k| {
                const fc: T = comptime f_min * std.math.pow(T, 2.0, @as(T, @floatFromInt(k)) / bins_per_octave);
                const f_lo: T = comptime fc / half_edge;
                const f_hi: T = comptime @min(fc * half_edge, @as(T, 0.4999));
                // Bandpass = (lowpass at upper edge) − (lowpass at lower edge): the
                // difference of two windowed-sinc lowpass kernels passes only the
                // band between the two cutoffs.
                const h_hi = comptime firwinLowpassT(T, taps, f_hi);
                const h_lo = comptime firwinLowpassT(T, taps, f_lo);
                var coeffs: [taps]T = undefined;
                inline for (0..taps) |i| coeffs[i] = h_hi[i] - h_lo[i];
                self.bands[k] = .{ .fir = .{ .coeffs = coeffs }, .fc = fc };
            }
            return self;
        }

        /// The centre frequency (cycles/sample) of band `k`.
        pub fn centre(self: *const Self, k: usize) T {
            return self.bands[k].fc;
        }

        /// Run the bank: for each input sample, emit a `FeatureFrame(bins)` whose
        /// `v[k]` is band `k`'s bandpass output at that sample. Rate-1:1 (the bank
        /// is uniform-rate), so `out.len == in.len`. The per-band FIRs carry their
        /// own history across calls, so a split render equals a whole render.
        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.FeatureFrame(bins)) void {
            // Run each band over the whole input run, scattering each band's output
            // into its feature column. Bands are independent, so the per-band passes
            // are order-free; each band's FIR carries its own persistent history.
            inline for (0..bins) |k| {
                const hist = &self.bands[k].fir;
                var i: usize = 0;
                while (i < in.len) : (i += 1) {
                    var one_in = [_]types.Sample(T){in[i]};
                    var one_out: [1]types.Sample(T) = undefined;
                    hist.process(&one_in, &one_out);
                    out[i].v[k] = @floatCast(one_out[0].ch[0]);
                }
            }
        }
    };
}

/// A `T`-typed windowed-sinc (Hamming) lowpass of `taps` taps at normalized cutoff
/// `fc` (cycles/sample), normalized to unity DC gain. Mirrors `filters.firwinLowpass`
/// (which is `f32`-fixed) for an arbitrary float lane `T`, so the constant-Q band
/// kernels are designed in the bank's own precision. The ideal lowpass impulse
/// response `2·fc·sinc(2·fc·n)` is tapered by a Hamming window and rescaled so the
/// taps sum to 1 (DC passes at unity) — the classic `firwin(taps, 2·fc, "hamming")`.
fn firwinLowpassT(comptime T: type, comptime taps: usize, comptime fc: T) [taps]T {
    if (taps == 0) @compileError("pan: firwinLowpassT needs at least one tap");
    return comptime blk: {
        @setEvalBranchQuota(taps * 64 + 256);
        var h: [taps]T = undefined;
        const m: T = @as(T, @floatFromInt(taps - 1)) / 2.0;
        const denom: T = if (taps == 1) 1.0 else @floatFromInt(taps - 1);
        var sum: T = 0;
        for (&h, 0..) |*c, i| {
            const n: T = @as(T, @floatFromInt(i)) - m;
            const sinc: T = if (n == 0)
                2.0 * fc
            else
                @sin(2.0 * std.math.pi * fc * n) / (std.math.pi * n);
            const win: T = 0.54 - 0.46 * @cos(2.0 * std.math.pi * @as(T, @floatFromInt(i)) / denom);
            c.* = sinc * win;
            sum += c.*;
        }
        for (&h) |*c| c.* /= sum;
        break :blk h;
    };
}

// ===========================================================================
// Tests — independent oracles for the rate decomposition and the DSP laws.
// ===========================================================================

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});
const port = @import("port.zig");

fn sampleSlice(comptime n: usize, vals: [n]f32) [n]types.Sample(f32) {
    var s: [n]types.Sample(f32) = undefined;
    for (&s, vals) |*o, v| o.ch[0] = v;
    return s;
}

test "WaveletAnalysis/Synthesis classify as Rate with the right out_per_in ratios" {
    // The single load-bearing structural fact: the stages are Rate (single ratio),
    // so the cascade composes uniform-rate Rate blocks — NOT a per-output-port-rate
    // multi-rate block. Analysis is 1:2, synthesis 2:1.
    try testing.expect(port.classify(WaveletAnalysis(f32num)) == .Rate);
    try testing.expect(port.classify(WaveletSynthesis(f32num)) == .Rate);
    try testing.expectEqual(@as(usize, 1), WaveletAnalysis(f32num).out_per_in[0]);
    try testing.expectEqual(@as(usize, 2), WaveletAnalysis(f32num).out_per_in[1]);
    try testing.expectEqual(@as(usize, 2), WaveletSynthesis(f32num).out_per_in[0]);
    try testing.expectEqual(@as(usize, 1), WaveletSynthesis(f32num).out_per_in[1]);
    // The Rate ports are mintable: Sample(f32) → Subband(f32) and back.
    try testing.expect(port.RateInElem(WaveletAnalysis(f32num)) == types.Sample(f32));
    try testing.expect(port.RateOutElem(WaveletAnalysis(f32num)) == Subband(f32));
    try testing.expect(port.RateInElem(WaveletSynthesis(f32num)) == Subband(f32));
    try testing.expect(port.RateOutElem(WaveletSynthesis(f32num)) == types.Sample(f32));
}

test "Haar analysis -> synthesis is EXACT perfect reconstruction (the decisive oracle)" {
    // WHY: the Haar 2-band rotation is orthogonal, so synthesis inverts analysis
    // sample-aligned with ZERO delay. Reconstruction == input is the property that
    // proves the whole rate decomposition is correct, not merely that it runs.
    var an = WaveletAnalysis(f32num){};
    var sy = WaveletSynthesis(f32num){};
    const N = 64;
    var in: [N]types.Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(11);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;

    var sb: [N / 2]Subband(f32) = undefined;
    const made = an.pull(&in, N / 2, &sb);
    try testing.expectEqual(@as(usize, N / 2), made);

    var out: [N]types.Sample(f32) = undefined;
    const got = sy.pull(sb[0..made], N, &out);
    try testing.expectEqual(@as(usize, N), got);

    // Zero delay: out[n] == in[n] exactly (within f32 round-off of the 1/√2 pair).
    for (in, out) |x, y| try testing.expectApproxEqAbs(x.ch[0], y.ch[0], 1e-6);
}

test "Haar lowpass of a constant is √2·const and the highpass is zero" {
    // WHY: an independent analytic check of the analysis coefficients themselves.
    // A constant signal has all its energy at DC: the lowpass must pass it (scaled
    // by the orthonormal 1/√2 over the pair, i.e. (c+c)/√2 = √2·c) and the highpass
    // (the difference) must be exactly zero.
    var an = WaveletAnalysis(f32num){};
    const c: f32 = 0.37;
    var in: [8]types.Sample(f32) = @splat(.{ .ch = .{c} });
    var sb: [4]Subband(f32) = undefined;
    const made = an.pull(&in, 4, &sb);
    try testing.expectEqual(@as(usize, 4), made);
    const sqrt2: f32 = @sqrt(@as(f32, 2.0));
    for (sb) |b| {
        try testing.expectApproxEqAbs(sqrt2 * c, b.lo, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0), b.hi, 1e-6);
    }
}

test "WaveletAnalysis carries pair state across a split render (odd boundary)" {
    // WHY: splitting the input on an ODD sample boundary must not drop the dangling
    // sample — the first half of a pair is held in state and completed by the first
    // sample of the next call. A split render must equal a whole render.
    const N = 16;
    var in: [N]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @floatFromInt(@as(i32, @intCast(i)) - 8);

    var whole = WaveletAnalysis(f32num){};
    var wsb: [N / 2]Subband(f32) = undefined;
    _ = whole.pull(&in, N / 2, &wsb);

    var split = WaveletAnalysis(f32num){};
    var ssb: [N / 2]Subband(f32) = undefined;
    // Split at index 5 (odd): the 5th sample is the first half of a pair, held over.
    const m0 = split.pull(in[0..5], N / 2, ssb[0..]);
    const m1 = split.pull(in[5..], N / 2 - m0, ssb[m0..]);
    try testing.expectEqual(@as(usize, N / 2), m0 + m1);
    for (wsb, ssb) |a, b| {
        try testing.expectEqual(a.lo, b.lo);
        try testing.expectEqual(a.hi, b.hi);
    }
}

test "DwtOctaveTree level count and per-band rates are as documented" {
    // WHY: the cascade's defining structure is that it produces `levels` detail
    // bands plus one approximation, with each band running at half the rate of the
    // one above. Assert the band counts and the geometric (halving) lengths.
    const L = 3;
    const Tree = DwtOctaveTree(f32num, L);
    try testing.expectEqual(@as(usize, L), Tree.level_count);
    try testing.expectEqual(@as(usize, L + 1), Tree.band_count);

    const N = 64;
    var in: [N]types.Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(5);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;

    var d0: [N / 2]f32 = undefined;
    var d1: [N / 4]f32 = undefined;
    var d2: [N / 8]f32 = undefined;
    var approx: [N / 8]f32 = undefined;
    const details = [_][]f32{ d0[0..], d1[0..], d2[0..] };
    var sb: [N / 2]Subband(f32) = undefined;
    var lo: [N / 2]types.Sample(f32) = undefined;

    var tree = Tree{};
    const counts = tree.analyze(&in, &details, approx[0..], sb[0..], lo[0..]);
    // Detail band i has N / 2^(i+1) coefficients; final approximation has N/2^L.
    try testing.expectEqual(@as(usize, N / 2), counts.detail[0]);
    try testing.expectEqual(@as(usize, N / 4), counts.detail[1]);
    try testing.expectEqual(@as(usize, N / 8), counts.detail[2]);
    try testing.expectEqual(@as(usize, N / 8), counts.approx);

    // Energy-preservation sanity (Parseval for an orthonormal transform): the total
    // energy in all bands equals the input energy. An independent property, not a
    // replay of pan's own output.
    var e_in: f32 = 0;
    for (in) |s| e_in += s.ch[0] * s.ch[0];
    var e_out: f32 = 0;
    for (d0) |v| e_out += v * v;
    for (d1) |v| e_out += v * v;
    for (d2) |v| e_out += v * v;
    for (approx) |v| e_out += v * v;
    try testing.expectApproxEqAbs(e_in, e_out, 1e-3);
}

test "DwtOctaveTree first-level detail equals a direct Haar highpass" {
    // WHY: the cascade's stage 0 must be exactly the Haar 2-band analysis applied to
    // the raw input. Compare the tree's d[0] to a standalone WaveletAnalysis — an
    // independent oracle pinning that the cascade wires the first stage correctly.
    const N = 16;
    var in: [N]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @sin(@as(f32, @floatFromInt(i)) * 0.9);

    var ref = WaveletAnalysis(f32num){};
    var ref_sb: [N / 2]Subband(f32) = undefined;
    _ = ref.pull(&in, N / 2, &ref_sb);

    const L = 2;
    var d0: [N / 2]f32 = undefined;
    var d1: [N / 4]f32 = undefined;
    var approx: [N / 4]f32 = undefined;
    const details = [_][]f32{ d0[0..], d1[0..] };
    var sb: [N / 2]Subband(f32) = undefined;
    var lo: [N / 2]types.Sample(f32) = undefined;
    var tree = DwtOctaveTree(f32num, L){};
    _ = tree.analyze(&in, &details, approx[0..], sb[0..], lo[0..]);

    for (0..N / 2) |k| try testing.expectApproxEqAbs(ref_sb[k].hi, d0[k], 1e-6);
}

test "Cqt classifies as a type-changing Map and is a bank of bandpass stages" {
    const C = Cqt(f32num, 4, 31);
    try testing.expect(port.classify(C) == .Map);
    try testing.expect(port.MapInElem(C) == types.Sample(f32));
    try testing.expect(port.MapOutElem(C) == types.FeatureFrame(4));
    try testing.expectEqual(@as(usize, 4), C.bin_count);
    // Geometric centre spacing: each band is one bin-per-octave step above the last.
    const bank = C.init(0.05, 2.0); // 2 bins/octave, f_min = 0.05
    try testing.expect(bank.centre(2) > bank.centre(0)); // an octave up is higher
    try testing.expectApproxEqAbs(bank.centre(0) * 2.0, bank.centre(2), 1e-4);
}

test "Cqt concentrates a tone at a band centre and rejects a distant tone" {
    // WHY: the defining constant-Q-bank behaviour — a pure tone at band k's centre
    // frequency lights up band k far more than a band an octave away. Drive the bank
    // with a sinusoid at the centre of the lowest band and assert that band's output
    // energy dominates a distant band's. An independent behavioural oracle.
    const bins = 4;
    const taps = 63;
    const C = Cqt(f32num, bins, taps);
    const f_min: f32 = 0.04;
    const bpo: f32 = 1.0; // one bin per octave: band k centred at f_min·2^k
    var bank = C.init(f_min, bpo);

    const N = 512;
    var in: [N]types.Sample(f32) = undefined;
    // A tone exactly at band 0's centre frequency.
    for (&in, 0..) |*s, i| s.ch[0] = @sin(2.0 * std.math.pi * f_min * @as(f32, @floatFromInt(i)));
    var out: [N]types.FeatureFrame(bins) = undefined;
    bank.process(&in, &out);

    // Measure steady-state energy per band (skip the FIR fill transient).
    var energy = [_]f32{0} ** bins;
    for (out[taps..]) |fr| {
        for (0..bins) |k| energy[k] += fr.v[k] * fr.v[k];
    }
    // Band 0 (the tone's band) must carry far more energy than band 3 (3 octaves up).
    try testing.expect(energy[0] > 0);
    try testing.expect(energy[0] > 20.0 * energy[bins - 1]);
}

test "the filterbank Rate blocks fail loud on a non-float lane" {
    // WHY: the float-only contract must be a COMPILE-time guard, not silently-wrong
    // integer audio. We can't @compileError-probe at runtime, so assert the float
    // monomorph exists and the helper agrees the lane is float (the guard's predicate).
    try testing.expect(isFloat(f32num.Lane));
    try testing.expect(!isFloat(numeric.numericFor(.i16, .{}).Lane));
}
