//! feat_chroma_contrast_yoneda_test — the INDEPENDENT-ORACLE (≈) check for three
//! newly-landed feature-extraction blocks of `src/feat.zig`: `Chroma`,
//! `SpectralContrast`, and the STATEFUL `DominantBandHysteresis`. The Yoneda
//! "tests as definition" discipline: each block is characterised by ALL its
//! morphisms — silence, lone peaks, octave pairs, ties, flat bands, empty bands,
//! and (for the stateful tracker) the full switch/hold boundary of its hysteresis
//! AND the per-hop S6 state granularity (whole-block render ≡ any sub-block split).
//!
//! Oracle strategy (Rule 9, hermetic — no SciPy/librosa, no disk, no network):
//! every expectation is recomputed in-test by a DIRECT, INDEPENDENT
//! reimplementation of each block's doc-comment formula, sharing only the
//! *definition* with pan's block, never its loop/accumulation order. Concretely:
//!   * Chroma — the bin→pitch-class map is recomputed from the documented
//!     sr=48000 / fft_size=2·(bins−1) / 440 Hz-ref / 20 Hz-floor rules in a
//!     standalone helper, accumulated in a different order, then max-normalised.
//!   * SpectralContrast — the geometric band edges and the per-band
//!     ln(peak+ε)−ln(valley+ε) (ε=1e-10) are recomputed independently; empty
//!     bands → 0.
//!   * DominantBandHysteresis — the leaky-integrator (λ=0.7) + decisive-switch
//!     (margin=0.5) state machine is re-run in a separate oracle that tracks the
//!     challenger argmax with a strictly-greater scan; the held band INDEX is a
//!     u16 so it is asserted EXACTLY (`expectEqual`), and its STATE EVOLUTION
//!     across crafted spectrum sequences is the heart of its definition.
//!
//! Float outputs (Chroma, SpectralContrast) use expectApproxEqAbs/Rel — never
//! bit-exact. The u16 band index is exact.
//!
//! Verified against zig 0.16.0 (zig-0-16 skill loaded, Rules 13/14).

const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});

fn frameOf(comptime bins: usize, vals: [bins]f32) pan.FeatureFrame(bins) {
    return .{ .v = vals };
}

// ===========================================================================
// Comptime classification + element-type surface (the Yoneda "object identity"
// — a block IS its class and its output element).
// ===========================================================================

test "feat: the three blocks classify as Map with the documented output elements" {
    try std.testing.expect(pan.port.classify(pan.feat.Chroma(Num, 9)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.SpectralContrast(Num, 9, 3)) == .Map);
    try std.testing.expect(pan.port.classify(pan.feat.DominantBandHysteresis(Num, 8)) == .Map);

    try std.testing.expect(pan.port.MapOutPort(pan.feat.Chroma(Num, 9)).Elem == pan.FeatureFrame(12));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.SpectralContrast(Num, 9, 3)).Elem == pan.FeatureFrame(3));
    try std.testing.expect(pan.port.MapOutPort(pan.feat.DominantBandHysteresis(Num, 8)).Elem == pan.Scalar(u16));
}

// ===========================================================================
// Chroma — fold linear-frequency power bins onto 12 pitch classes, octave-
// collapsing, then scale so the max entry == 1. Conventions baked at comptime:
//   bin k → f = k·48000/(2·(bins−1)) Hz; drop DC (k=0) and bins below 20 Hz;
//   pc = round(12·log2(f/440)) mod 12 (Euclidean), pitch class 0 = 440 Hz A.
// ===========================================================================

/// Independent bin→pitch-class map (−1 == dropped). Recomputed from the prose,
/// NOT imported from pan. Uses @rem + manual Euclidean wrap (round can go
/// negative for f < 440 Hz), exactly as the definition states.
fn chromaClass(comptime bins: usize) [bins]i32 {
    var m: [bins]i32 = undefined;
    const fft_size: f64 = @floatFromInt(2 * (bins - 1));
    for (0..bins) |k| {
        const f = @as(f64, @floatFromInt(k)) * 48_000.0 / fft_size;
        if (k == 0 or f < 20.0) {
            m[k] = -1;
        } else {
            const semis = 12.0 * std.math.log2(f / 440.0);
            var pc = @rem(@as(i32, @intFromFloat(std.math.round(semis))), 12);
            if (pc < 0) pc += 12;
            m[k] = pc;
        }
    }
    return m;
}

/// Independent Chroma oracle: fold, then max-normalise. Accumulates classes in a
/// DIFFERENT order than pan (descending bin index) to avoid sharing a code path.
fn chromaOracle(comptime bins: usize, v: [bins]f32) [12]f64 {
    const klass = comptime chromaClass(bins);
    var acc: [12]f64 = @splat(0);
    var k: usize = bins;
    while (k > 0) {
        k -= 1;
        const pc = klass[k];
        if (pc >= 0) acc[@intCast(pc)] += @as(f64, v[k]);
    }
    var peak: f64 = 0;
    for (acc) |a| if (a > peak) {
        peak = a;
    };
    if (peak > 0) for (&acc) |*a| {
        a.* /= peak;
    };
    return acc;
}

test "Chroma: all-zero (silent) spectrum stays all-zero (no normalisation blow-up)" {
    const BINS = 9;
    var b: pan.feat.Chroma(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(0))};
    var out = [_]pan.FeatureFrame(12){.{ .v = @splat(7) }}; // non-zero sentinel
    b.process(&in, &out);
    inline for (0..12) |c| try std.testing.expectEqual(@as(f32, 0), out[0].v[c]);
}

test "Chroma: the DC bin and sub-20 Hz bins are dropped (here, none below 20 Hz)" {
    // For BINS=9 the lowest live bin (k=1) is 3000 Hz, so only DC (k=0) drops.
    // Put all energy in DC: it must be discarded ⇒ an all-zero chroma.
    const BINS = 9;
    var b: pan.feat.Chroma(Num, BINS) = .{};
    var v: [BINS]f32 = @splat(0);
    v[0] = 1000.0; // DC only
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out: [1]pan.FeatureFrame(12) = undefined;
    b.process(&in, &out);
    inline for (0..12) |c| try std.testing.expectEqual(@as(f32, 0), out[0].v[c]);
}

test "Chroma: a lone live bin lands in its documented pitch class, normalised to 1" {
    // BINS=9, fft_size=16, sr/fft=3000. Independently: k1→pc9, k3→pc4, k5→pc1,
    // k7→pc7. The single non-zero class normalises to exactly 1; all else 0.
    const BINS = 9;
    const klass = comptime chromaClass(BINS);
    inline for (.{ 1, 3, 5, 7 }) |peak| {
        var b: pan.feat.Chroma(Num, BINS) = .{};
        var v: [BINS]f32 = @splat(0);
        v[peak] = 42.0; // magnitude irrelevant after max-normalisation
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out: [1]pan.FeatureFrame(12) = undefined;
        b.process(&in, &out);
        const pc: usize = @intCast(klass[peak]);
        inline for (0..12) |c| {
            const want: f32 = if (c == pc) 1.0 else 0.0;
            try std.testing.expectApproxEqAbs(want, out[0].v[c], 1e-6);
        }
    }
}

test "Chroma: an octave pair (k1=3000, k2=6000) collapses into ONE pitch class" {
    // 6000 Hz is exactly one octave above 3000 Hz, so both map to pc9 — the
    // defining octave-collapse property. Two equal powers fold to 2·p in pc9,
    // which (being the only live class) normalises to 1. Crucially, no SECOND
    // class lights up: octave-equivalence, not two distinct classes.
    const BINS = 9;
    const klass = comptime chromaClass(BINS);
    try std.testing.expectEqual(@as(i32, 9), klass[1]);
    try std.testing.expectEqual(@as(i32, 9), klass[2]); // octave-equal
    var b: pan.feat.Chroma(Num, BINS) = .{};
    var v: [BINS]f32 = @splat(0);
    v[1] = 5.0;
    v[2] = 5.0;
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out: [1]pan.FeatureFrame(12) = undefined;
    b.process(&in, &out);
    inline for (0..12) |c| {
        const want: f32 = if (c == 9) 1.0 else 0.0;
        try std.testing.expectApproxEqAbs(want, out[0].v[c], 1e-6);
    }
}

test "Chroma: two distinct classes — the larger fold normalises to 1, the other scales" {
    // BINS=9: k3→pc4 (power 1), k5→pc1 (power 3). pc1 is the larger fold ⇒ 1.0;
    // pc4 ⇒ 1/3. Everything else 0. A sharp relative-magnitude characterisation.
    const BINS = 9;
    var b: pan.feat.Chroma(Num, BINS) = .{};
    var v: [BINS]f32 = @splat(0);
    v[3] = 1.0; // pc4
    v[5] = 3.0; // pc1
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out: [1]pan.FeatureFrame(12) = undefined;
    b.process(&in, &out);
    const want = chromaOracle(BINS, v);
    inline for (0..12) |c| {
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(want[c])), out[0].v[c], 1e-6);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0].v[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), out[0].v[4], 1e-6);
}

test "Chroma: the max entry is exactly 1 for any non-silent frame (normalisation invariant)" {
    const BINS = 17; // a second geometry (fft_size=32, sr/fft=1500)
    var b: pan.feat.Chroma(Num, BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0xC4_12_0A);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 24) : (trial += 1) {
        var v: [BINS]f32 = undefined;
        for (&v) |*x| x.* = rnd.float(f32) * 9.0;
        const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
        var out: [1]pan.FeatureFrame(12) = undefined;
        b.process(&in, &out);
        // The maximum of the 12 entries must be (approximately) 1.
        var mx: f32 = -1;
        inline for (0..12) |c| if (out[0].v[c] > mx) {
            mx = out[0].v[c];
        };
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), mx, 1e-6);
        // And the whole vector matches the independent fold+normalise oracle.
        const want = chromaOracle(BINS, v);
        inline for (0..12) |c| {
            try std.testing.expectApproxEqAbs(@as(f32, @floatCast(want[c])), out[0].v[c], 1e-5);
        }
    }
}

test "Chroma: batches frames one-for-one, statelessly" {
    const BINS = 9;
    var b: pan.feat.Chroma(Num, BINS) = .{};
    var f0: [BINS]f32 = @splat(0);
    f0[5] = 2.0; // pc1
    const f1: [BINS]f32 = @splat(0); // silent
    var f2: [BINS]f32 = @splat(0);
    f2[7] = 9.0; // pc7
    const in = [_]pan.FeatureFrame(BINS){ frameOf(BINS, f0), frameOf(BINS, f1), frameOf(BINS, f2) };
    var out: [3]pan.FeatureFrame(12) = undefined;
    b.process(&in, &out);
    inline for (.{ f0, f1, f2 }, 0..) |v, i| {
        const want = chromaOracle(BINS, v);
        inline for (0..12) |c| {
            try std.testing.expectApproxEqAbs(@as(f32, @floatCast(want[c])), out[i].v[c], 1e-6);
        }
    }
}

// ===========================================================================
// SpectralContrast — per geometrically-spaced octave band,
//   ln(peak+ε) − ln(valley+ε),  ε=1e-10, peak=max bin, valley=min bin in band.
// Band edges e[b]=round((bins−1)^(b/n_bands)) over bins [1,bins); empty → 0.
// ===========================================================================

/// Independent band-edge recomputation from the prose (non-decreasing clamp,
/// last edge forced to bins−1). Different variable names / loop shape than pan.
fn contrastEdges(comptime bins: usize, comptime n_bands: usize) [n_bands + 1]usize {
    var e: [n_bands + 1]usize = undefined;
    const span: f64 = @floatFromInt(bins - 1);
    var prev: usize = 1;
    var b: usize = 0;
    while (b <= n_bands) : (b += 1) {
        const frac = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(n_bands));
        var idx: usize = @intFromFloat(std.math.round(std.math.pow(f64, span, frac)));
        if (idx < 1) idx = 1;
        if (idx > bins - 1) idx = bins - 1;
        if (b > 0 and idx < prev) idx = prev;
        e[b] = idx;
        prev = idx;
    }
    e[n_bands] = bins - 1;
    return e;
}

/// Independent SpectralContrast oracle. ε=1e-10; empty band → 0. Scans each band
/// fresh (peak/valley seeded from the band's first bin), accumulating in f64.
fn contrastOracle(
    comptime bins: usize,
    comptime n_bands: usize,
    v: [bins]f32,
    out: *[n_bands]f64,
) void {
    const eps: f64 = 1e-10;
    const edges = comptime contrastEdges(bins, n_bands);
    for (0..n_bands) |b| {
        const lo = edges[b];
        const hi = edges[b + 1];
        if (hi <= lo) {
            out[b] = 0;
            continue;
        }
        var peak: f64 = v[lo];
        var valley: f64 = v[lo];
        var k = lo;
        while (k < hi) : (k += 1) {
            const p: f64 = v[k];
            if (p > peak) peak = p;
            if (p < valley) valley = p;
        }
        out[b] = std.math.log(f64, std.math.e, peak + eps) -
            std.math.log(f64, std.math.e, valley + eps);
    }
}

test "SpectralContrast: a flat (constant) spectrum gives ~0 contrast in every band" {
    // peak == valley in every band ⇒ ln(c+ε) − ln(c+ε) = 0.
    const BINS = 9;
    const NB = 3; // edges {1,2,4,8}
    var b: pan.feat.SpectralContrast(Num, BINS, NB) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, @splat(5.0))};
    var out: [1]pan.FeatureFrame(NB) = undefined;
    b.process(&in, &out);
    inline for (0..NB) |band| try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].v[band], 1e-5);
}

test "SpectralContrast: a single-bin band has peak==valley ⇒ exactly 0 contrast" {
    // BINS=5, NB=4 ⇒ edges {1,1,2,3,4}: band0 [1,1) empty, bands 1..3 are each a
    // single bin. Whatever the values, every band's contrast is 0.
    const BINS = 5;
    const NB = 4;
    const edges = comptime contrastEdges(BINS, NB);
    try std.testing.expectEqual(@as(usize, 1), edges[0]);
    try std.testing.expectEqual(@as(usize, 1), edges[1]); // band0 empty
    var b: pan.feat.SpectralContrast(Num, BINS, NB) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 0, 3, 7, 2, 9 })};
    var out: [1]pan.FeatureFrame(NB) = undefined;
    b.process(&in, &out);
    inline for (0..NB) |band| try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].v[band], 1e-5);
}

test "SpectralContrast: a collapsed (empty) band emits exactly 0" {
    // BINS=9, NB=5 ⇒ edges {1,2,2,3,5,8}: band1 is [2,2), empty ⇒ 0. The
    // surrounding multi-bin bands carry real contrast; the empty one must be 0
    // regardless of neighbours.
    const BINS = 9;
    const NB = 5;
    const edges = comptime contrastEdges(BINS, NB);
    try std.testing.expectEqual(edges[1], edges[2]); // band1 collapsed
    var b: pan.feat.SpectralContrast(Num, BINS, NB) = .{};
    // Loud, varied spectrum so neighbouring bands are clearly non-zero.
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 0, 8, 1, 100, 2, 50, 3, 0.01, 70 })};
    var out: [1]pan.FeatureFrame(NB) = undefined;
    b.process(&in, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].v[1], 1e-5); // the empty band
    // Independent oracle agreement across all bands.
    var want: [NB]f64 = undefined;
    contrastOracle(BINS, NB, in[0].v, &want);
    inline for (0..NB) |band| {
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(want[band])), out[0].v[band], 1e-4);
    }
}

test "SpectralContrast: a multi-bin band reports ln(peak+ε)−ln(valley+ε) exactly" {
    // BINS=9, NB=3 ⇒ edges {1,2,4,8}. Band2 = bins [4,8) = {v4,v5,v6,v7}.
    // Choose those so peak/valley are known: max=20, min=0.5 ⇒ ln(20+ε)−ln(0.5+ε).
    const BINS = 9;
    const NB = 3;
    var b: pan.feat.SpectralContrast(Num, BINS, NB) = .{};
    const v: [BINS]f32 = .{ 0, 1, 1, 1, 3, 20, 0.5, 7, 0 };
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out: [1]pan.FeatureFrame(NB) = undefined;
    b.process(&in, &out);
    const want_band2 = std.math.log(f64, std.math.e, 20.0 + 1e-10) -
        std.math.log(f64, std.math.e, 0.5 + 1e-10);
    try std.testing.expectApproxEqAbs(@as(f32, @floatCast(want_band2)), out[0].v[2], 1e-4);
    // Full oracle cross-check.
    var want: [NB]f64 = undefined;
    contrastOracle(BINS, NB, v, &want);
    inline for (0..NB) |band| {
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(want[band])), out[0].v[band], 1e-4);
    }
}

test "SpectralContrast: a band touching zero exercises the ε floor (ln(0+ε) finite)" {
    // valley = 0 ⇒ ln(0 + 1e-10) = a large finite negative number, not −inf. A
    // band with peak=P and valley=0 yields ln(P+ε) − ln(ε) ≈ ln(P) + 23.0259…
    const BINS = 9;
    const NB = 3;
    var b: pan.feat.SpectralContrast(Num, BINS, NB) = .{};
    const v: [BINS]f32 = .{ 0, 4, 0, 4, 0, 0, 0, 0, 0 }; // band0 [1,2)={4}; band1 [2,4)={0,4}
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
    var out: [1]pan.FeatureFrame(NB) = undefined;
    b.process(&in, &out);
    // band1 = bins {2,3} = {0,4}: peak 4, valley 0.
    const want_band1 = std.math.log(f64, std.math.e, 4.0 + 1e-10) -
        std.math.log(f64, std.math.e, 0.0 + 1e-10);
    try std.testing.expect(std.math.isFinite(out[0].v[1]));
    try std.testing.expectApproxEqAbs(@as(f32, @floatCast(want_band1)), out[0].v[1], 1e-2);
}

test "SpectralContrast: arbitrary spectra match the independent oracle (two geometries)" {
    var prng = std.Random.DefaultPrng.init(0x5C_C0_17_A5);
    const rnd = prng.random();
    inline for (.{ .{ 17, 4 }, .{ 9, 3 } }) |geo| {
        const BINS = geo[0];
        const NB = geo[1];
        var b: pan.feat.SpectralContrast(Num, BINS, NB) = .{};
        var trial: usize = 0;
        while (trial < 20) : (trial += 1) {
            var v: [BINS]f32 = undefined;
            for (&v) |*x| x.* = rnd.float(f32) * 30.0;
            const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, v)};
            var out: [1]pan.FeatureFrame(NB) = undefined;
            b.process(&in, &out);
            var want: [NB]f64 = undefined;
            contrastOracle(BINS, NB, v, &want);
            inline for (0..NB) |band| {
                try std.testing.expectApproxEqAbs(@as(f32, @floatCast(want[band])), out[0].v[band], 1e-3);
            }
        }
    }
}

// ===========================================================================
// DominantBandHysteresis — STATEFUL flicker-free dominant-band tracker.
//   per hop: s[k] ← λ·s[k] + (1−λ)·power[k]   (λ=0.7, s starts 0)
//            c = argmax_k s[k]                  (first index on tie)
//            switch held→c iff s[c] > s[held]·(1+margin)   (margin=0.5)
//            output = held    (held starts 0, s[0]=0 ⇒ first hop switches)
// The u16 INDEX is asserted EXACTLY. The state EVOLUTION is the definition.
// ===========================================================================

const ORACLE_LAMBDA: f64 = 0.7;
const ORACLE_MARGIN: f64 = 0.5;

/// Independent hysteresis oracle: re-run the state machine in f64 with a
/// strictly-greater first-index argmax scan. Returns held bands AND the residual
/// (smoothed, held) so callers can check state carry. Different loop shape than
/// pan (separate challenger scan after the integrate, not fused).
fn DomOracle(comptime bins: usize) type {
    return struct {
        smoothed: [bins]f64 = @splat(0),
        held: u16 = 0,
        fn step(self: *@This(), power: [bins]f32) u16 {
            // integrate
            for (&self.smoothed, power) |*s, p| {
                s.* = ORACLE_LAMBDA * s.* + (1.0 - ORACLE_LAMBDA) * @as(f64, p);
            }
            // challenger argmax, first index on tie (strict >)
            var c: u16 = 0;
            var best: f64 = self.smoothed[0];
            for (self.smoothed, 0..) |s, k| {
                if (s > best) {
                    best = s;
                    c = @intCast(k);
                }
            }
            // decisive switch
            if (self.smoothed[c] > self.smoothed[self.held] * (1.0 + ORACLE_MARGIN)) {
                self.held = c;
            }
            return self.held;
        }
    };
}

test "DominantBandHysteresis: the first hop switches immediately off bin 0 (s0=0)" {
    // held starts 0 with s[0]=0; any positive bin makes s[c] > 0 = s[held]·1.5,
    // so the first hop always adopts the challenger.
    const BINS = 4;
    var b: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 0, 0, 1, 0 })};
    var out = [_]pan.Scalar(u16){.{ .value = 9999 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(u16, 2), out[0].value);
}

test "DominantBandHysteresis: a silent stream holds bin 0 forever (no spurious switch)" {
    // s stays all-zero; s[held]=0, s[c]=0, 0 > 0 is false ⇒ never switches.
    const BINS = 4;
    var b: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, @splat(0)),
        frameOf(BINS, @splat(0)),
        frameOf(BINS, @splat(0)),
    };
    var out: [3]pan.Scalar(u16) = undefined;
    b.process(&in, &out);
    for (out) |o| try std.testing.expectEqual(@as(u16, 0), o.value);
}

test "DominantBandHysteresis: a near-equal challenger BELOW the margin is suppressed (flicker-free)" {
    // The defining property. hop0: bin2 peak ⇒ held=2 (s2=3.0). hop1: bin1 fires
    // (s1=3.0) but s2 decays to 2.1; switch needs s1 > s2·1.5 = 3.15. 3.0 < 3.15
    // ⇒ HOLD at 2 despite bin1 being the argmax. This is the suppressed flicker.
    const BINS = 4;
    var b: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, .{ 0, 0, 10, 0 }),
        frameOf(BINS, .{ 0, 10, 0, 0 }),
    };
    var out: [2]pan.Scalar(u16) = undefined;
    b.process(&in, &out);
    try std.testing.expectEqual(@as(u16, 2), out[0].value); // adopted
    try std.testing.expectEqual(@as(u16, 2), out[1].value); // HELD — flicker suppressed
}

test "DominantBandHysteresis: a persistent challenger eventually crosses the margin and switches" {
    // Continuing the above: bin1 keeps firing. hop2: s1 accumulates to 5.1 while
    // s2 decays to 1.47; 5.1 > 1.47·1.5 = 2.205 ⇒ SWITCH to 1, and it stays held.
    const BINS = 4;
    var b: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, .{ 0, 0, 10, 0 }), // held=2
        frameOf(BINS, .{ 0, 10, 0, 0 }), // held=2 (suppressed)
        frameOf(BINS, .{ 0, 10, 0, 0 }), // held=1 (decisive)
        frameOf(BINS, .{ 0, 10, 0, 0 }), // held=1 (stays)
    };
    var out: [4]pan.Scalar(u16) = undefined;
    b.process(&in, &out);
    try std.testing.expectEqual(@as(u16, 2), out[0].value);
    try std.testing.expectEqual(@as(u16, 2), out[1].value);
    try std.testing.expectEqual(@as(u16, 1), out[2].value);
    try std.testing.expectEqual(@as(u16, 1), out[3].value);
}

test "DominantBandHysteresis: a decisively louder challenger switches on the very next hop" {
    // hop0: bin0 ⇒ held=0 (s0=3.0). hop1: bin2 blasts in at 100 ⇒ s2=30 while
    // s0 decays to 2.1; 30 > 2.1·1.5 = 3.15 ⇒ immediate SWITCH to 2.
    const BINS = 4;
    var b: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, .{ 10, 0, 0, 0 }),
        frameOf(BINS, .{ 0, 0, 100, 0 }),
    };
    var out: [2]pan.Scalar(u16) = undefined;
    b.process(&in, &out);
    try std.testing.expectEqual(@as(u16, 0), out[0].value);
    try std.testing.expectEqual(@as(u16, 2), out[1].value);
}

test "DominantBandHysteresis: a modest challenger under the held band's margin never switches" {
    // hop0: bin0 ⇒ held=0 (s0=3.0). hop1: bin2 rises to 11 ⇒ s2=3.3, s0=5.1;
    // bin0 is still argmax and 3.3 < 5.1·1.5 anyway ⇒ HOLD at 0.
    const BINS = 4;
    var b: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    const in = [_]pan.FeatureFrame(BINS){
        frameOf(BINS, .{ 10, 0, 0, 0 }),
        frameOf(BINS, .{ 10, 0, 11, 0 }),
    };
    var out: [2]pan.Scalar(u16) = undefined;
    b.process(&in, &out);
    try std.testing.expectEqual(@as(u16, 0), out[0].value);
    try std.testing.expectEqual(@as(u16, 0), out[1].value);
}

test "DominantBandHysteresis: first-index tie-break in the challenger argmax (strict >)" {
    // Two bins share the smoothed maximum; the FIRST (lower index) is the
    // challenger. With held=0,s0=0, the first non-zero bin among equals wins.
    const BINS = 5;
    var b: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    // bins 1 and 3 equal ⇒ challenger is 1 ⇒ held becomes 1 on the first hop.
    const in = [_]pan.FeatureFrame(BINS){frameOf(BINS, .{ 0, 5, 0, 5, 0 })};
    var out = [_]pan.Scalar(u16){.{ .value = 9999 }};
    b.process(&in, &out);
    try std.testing.expectEqual(@as(u16, 1), out[0].value);
}

test "DominantBandHysteresis: matches the independent state-machine oracle on a long stream" {
    const BINS = 8;
    var b: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    var oracle: DomOracle(BINS) = .{};
    var prng = std.Random.DefaultPrng.init(0xD0_11_BA_17);
    const rnd = prng.random();
    const N = 40;
    var frames: [N]pan.FeatureFrame(BINS) = undefined;
    for (&frames) |*f| {
        for (&f.v) |*x| x.* = rnd.float(f32) * 12.0;
    }
    var out: [N]pan.Scalar(u16) = undefined;
    b.process(&frames, &out);
    for (frames, out) |f, o| {
        const want = oracle.step(f.v);
        try std.testing.expectEqual(want, o.value);
    }
    // Residual held band agrees too.
    try std.testing.expectEqual(oracle.held, b.held);
}

test "DominantBandHysteresis: sub-block split equals whole-block render (per-hop S6 granularity)" {
    // The state note: `s` and `held` advance exactly once per processed frame, so
    // any partition of the frame stream into sub-blocks must yield identical held
    // bands AND leave the residual (smoothed, held) state identical to one
    // whole-block render. This is the heart of the stateful definition.
    const BINS = 6;
    var prng = std.Random.DefaultPrng.init(0x5B_10_C_5B);
    const rnd = prng.random();
    const N = 13;
    var frames: [N]pan.FeatureFrame(BINS) = undefined;
    for (&frames) |*f| {
        for (&f.v) |*x| x.* = rnd.float(f32) * 8.0;
    }

    // Whole-block render.
    var whole: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    var out_whole: [N]pan.Scalar(u16) = undefined;
    whole.process(&frames, &out_whole);

    // Split render at arbitrary seams (4 | 1 | 1 | 7) on a fresh instance.
    var split: pan.feat.DominantBandHysteresis(Num, BINS) = .{};
    var out_split: [N]pan.Scalar(u16) = undefined;
    split.process(frames[0..4], out_split[0..4]);
    split.process(frames[4..5], out_split[4..5]);
    split.process(frames[5..6], out_split[5..6]);
    split.process(frames[6..N], out_split[6..N]);

    // 1) Identical held-band outputs (exact — these are u16 indices).
    for (out_whole, out_split) |w, s| {
        try std.testing.expectEqual(w.value, s.value);
    }
    // 2) Identical residual held band.
    try std.testing.expectEqual(whole.held, split.held);
    // 3) Identical residual smoothed state (bit-for-bit: same op sequence/order).
    for (whole.smoothed, split.smoothed) |w, s| {
        try std.testing.expectEqual(w, s);
    }
}
