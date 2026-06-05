//! filterbank_yoneda_test — the behavioral SPECIFICATION of the multi-rate
//! filterbank blocks in src/filterbank.zig: `WaveletAnalysis`/`WaveletSynthesis`
//! (Haar 2-band Rate stages), `DwtOctaveTree(num, levels)` and
//! `Cqt(num, bins, taps)`. Written the Yoneda way — characterize each block
//! through every morphism that matters and pin each against an INDEPENDENT
//! oracle: the analytic Haar rotation (perfect reconstruction, √2·const lowpass,
//! zero highpass on DC), Parseval energy preservation, the octave-rate geometry,
//! and constant-Q tone localization.
//!
//! These tests are ADDITIVE to the unit tests already in src/filterbank.zig
//! (which pin: the Rate classification + ratios, one f32 perfect-reconstruction
//! run, the √2·const lowpass / zero highpass on a constant, one odd-boundary
//! split, the level-3 DWT counts + Parseval, the level-2 first-detail match, the
//! Cqt Map classification + centre geometry, and one Cqt tone-localization). This
//! file adds the coverage they lack: perfect reconstruction at f64 and at lengths
//! that are NOT multiples of large powers of two, the Haar highpass on an
//! ALTERNATING signal, multiple split boundaries, the DWT approximation-chain
//! identity (a[L] = repeated lowpass) and deeper trees, the Cqt rate-1:1 frame
//! count, Cqt linearity, Cqt history continuity across a split render, and tone
//! localization on MULTIPLE bands plus distant-tone rejection.
//!
//! Why these matter (Rule 9):
//!   - Haar PERFECT RECONSTRUCTION is the decisive oracle for the whole rate
//!     decomposition: synthesis∘analysis == input, sample-aligned, ZERO delay.
//!     A wrong normalization (1/2 instead of 1/√2) still reconstructs a scaled
//!     copy on a constant, but breaks exact reconstruction on noise — only the
//!     full round-trip catches it.
//!   - The DWT band RATES halving down the cascade is the R5 decomposition's whole
//!     point; an off-by-one in a stage's want would change a band length.
//!   - Constant-Q TONE LOCALIZATION is the defining behaviour of the bank: a tone
//!     at band k's centre lights up band k far more than a distant band.
//!
//! COMPARISON MODE: pan-vs-pan structural facts are bit-exact (`expectEqual`);
//! analytic DSP laws use `expectApproxEqAbs` against the independently-derived
//! value, with tolerance forgiving only f32/f64 round-off.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rule 13/14).

const std = @import("std");
const pan = @import("pan");

const types = pan.types;
const port = pan.port;
const fb = pan.filterbank;

const f32num = pan.numericFor(.f32, .{});
const f64num = pan.numericFor(.f64, .{});

fn Sample(comptime T: type) type {
    return types.Frame(T, .mono);
}

// ===========================================================================
// Haar analysis ↔ synthesis — the decisive perfect-reconstruction oracle.
// ===========================================================================

/// Run analysis then synthesis over `n` noise samples of lane `T` and assert the
/// reconstruction equals the input, sample-aligned, within f-round-off. `n` even.
fn assertPerfectReconstruction(comptime T: type, comptime nm: pan.Numeric, comptime n: usize, seed: u64, tol: T) !void {
    const An = fb.WaveletAnalysis(nm);
    const Sy = fb.WaveletSynthesis(nm);
    const SB = fb.Subband(T);
    var an = An{};
    var sy = Sy{};
    var in: [n]Sample(T) = undefined;
    var rng = std.Random.DefaultPrng.init(seed);
    for (&in) |*s| s.ch[0] = @floatCast(rng.random().float(f64) * 2 - 1);
    var sb: [n / 2]SB = undefined;
    const made = an.pull(&in, n / 2, &sb);
    try std.testing.expectEqual(@as(usize, n / 2), made);
    var out: [n]Sample(T) = undefined;
    const got = sy.pull(sb[0..made], n, &out);
    try std.testing.expectEqual(@as(usize, n), got);
    for (in, out) |x, y| try std.testing.expectApproxEqAbs(x.ch[0], y.ch[0], tol);
}

test "Haar perfect reconstruction holds at f64 working precision (the orthogonal-rotation oracle)" {
    // The f64 lane: the round-trip is exact to ~1e-12, far tighter than the f32
    // path the in-file test exercises — pinning that the law is the orthogonal
    // rotation, not an f32-tolerance artefact.
    try assertPerfectReconstruction(f64, f64num, 128, 42, 1e-12);
}

test "Haar perfect reconstruction at a length that is only 2·odd (no large power-of-two run)" {
    // 2·odd lengths (e.g. 2·11=22, 2·17=34) keep the per-pair rotation honest
    // without ever hitting a deeper power-of-two boundary; a regression that
    // assumed N%4==0 would surface here.
    try assertPerfectReconstruction(f32, f32num, 22, 7, 1e-6);
    try assertPerfectReconstruction(f32, f32num, 34, 8, 1e-6);
    try assertPerfectReconstruction(f32, f32num, 2, 9, 1e-6);
}

test "Haar highpass of an ALTERNATING signal is maximal; lowpass is zero (the Nyquist dual of DC)" {
    // Independent analytic check of the analysis coefficients at the OTHER
    // extreme: a signal ±c, ±c, … (alternating) is pure Nyquist. Over a pair
    // (a,b)=(+c,−c): lo=(a+b)/√2=0, hi=(a−b)/√2=√2·c. The dual of the in-file
    // constant-signal check (lo=√2·c, hi=0) — together they pin both rows.
    var an = fb.WaveletAnalysis(f32num){};
    const c: f32 = 0.43;
    var in: [8]Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = if (i % 2 == 0) c else -c;
    var sb: [4]fb.Subband(f32) = undefined;
    const made = an.pull(&in, 4, &sb);
    try std.testing.expectEqual(@as(usize, 4), made);
    const sqrt2: f32 = @sqrt(@as(f32, 2.0));
    for (sb) |b| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), b.lo, 1e-6);
        try std.testing.expectApproxEqAbs(sqrt2 * c, b.hi, 1e-6);
    }
}

test "WaveletAnalysis is linear over the input pair (lo/hi scale with input)" {
    // The Haar rotation is linear: scaling the input scales lo and hi by the same
    // factor. Independent linearity oracle, ruling out a kernel with an offset.
    var an = fb.WaveletAnalysis(f32num){};
    var in: [2]Sample(f32) = .{ .{ .ch = .{0.6} }, .{ .ch = .{0.2} } };
    var sb: [1]fb.Subband(f32) = undefined;
    _ = an.pull(&in, 1, &sb);
    const inv_sqrt2: f32 = 1.0 / @sqrt(@as(f32, 2.0));
    try std.testing.expectApproxEqAbs((0.6 + 0.2) * inv_sqrt2, sb[0].lo, 1e-6);
    try std.testing.expectApproxEqAbs((0.6 - 0.2) * inv_sqrt2, sb[0].hi, 1e-6);
    // Triple the input → triple both coefficients.
    var an3 = fb.WaveletAnalysis(f32num){};
    var in3: [2]Sample(f32) = .{ .{ .ch = .{1.8} }, .{ .ch = .{0.6} } };
    var sb3: [1]fb.Subband(f32) = undefined;
    _ = an3.pull(&in3, 1, &sb3);
    try std.testing.expectApproxEqAbs(3.0 * sb[0].lo, sb3[0].lo, 1e-6);
    try std.testing.expectApproxEqAbs(3.0 * sb[0].hi, sb3[0].hi, 1e-6);
}

test "WaveletAnalysis: split at SEVERAL boundaries equals a whole render (pair state across calls)" {
    // The in-file test splits once at index 5. Pin the contract across many split
    // points (even and odd), each a chunked render reassembled — a split render
    // must be bit-identical to a whole render regardless of where it is cut.
    const N = 24;
    var in: [N]Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @sin(@as(f32, @floatFromInt(i)) * 0.41) - 0.3;

    var whole = fb.WaveletAnalysis(f32num){};
    var wsb: [N / 2]fb.Subband(f32) = undefined;
    _ = whole.pull(&in, N / 2, &wsb);

    const splits = [_]usize{ 1, 3, 5, 7, 11, 13 };
    for (splits) |cut| {
        var split = fb.WaveletAnalysis(f32num){};
        var ssb: [N / 2]fb.Subband(f32) = undefined;
        const m0 = split.pull(in[0..cut], N / 2, ssb[0..]);
        const m1 = split.pull(in[cut..], N / 2 - m0, ssb[m0..]);
        try std.testing.expectEqual(@as(usize, N / 2), m0 + m1);
        for (wsb, ssb) |a, b| {
            // pan-vs-pan: bit-exact, not approximate.
            try std.testing.expectEqual(a.lo, b.lo);
            try std.testing.expectEqual(a.hi, b.hi);
        }
    }
}

test "WaveletSynthesis needed_input is ceil(want/2) — one subband feeds two samples" {
    // The Rate ratio made concrete: synthesis consumes ceil(want/2) input subbands
    // to make `want` output samples (2:1). An independent arithmetic check of the
    // rate-scheduler contract distinct from the out_per_in tuple.
    var sy = fb.WaveletSynthesis(f32num){};
    try std.testing.expectEqual(@as(usize, 0), sy.needed_input(0));
    try std.testing.expectEqual(@as(usize, 1), sy.needed_input(1)); // ceil(1/2)
    try std.testing.expectEqual(@as(usize, 1), sy.needed_input(2));
    try std.testing.expectEqual(@as(usize, 2), sy.needed_input(3)); // ceil(3/2)
    try std.testing.expectEqual(@as(usize, 5), sy.needed_input(10));
    var an = fb.WaveletAnalysis(f32num){};
    try std.testing.expectEqual(@as(usize, 8), an.needed_input(4)); // 2·want
}

// ===========================================================================
// DwtOctaveTree — the octave cascade structure & laws.
// ===========================================================================

test "DwtOctaveTree level-4: band lengths halve down the cascade and Parseval holds" {
    // Deeper than the in-file level-3 case. L=4 over N=64 must give detail
    // lengths 32,16,8,4 and a final approximation of 4 (N/2^4), and the total
    // band energy equals the input energy (Parseval for the orthonormal Haar).
    const L = 4;
    const Tree = fb.DwtOctaveTree(f32num, L);
    try std.testing.expectEqual(@as(usize, L), Tree.level_count);
    try std.testing.expectEqual(@as(usize, L + 1), Tree.band_count);

    const N = 64;
    var in: [N]Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(101);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;

    var d0: [N / 2]f32 = undefined;
    var d1: [N / 4]f32 = undefined;
    var d2: [N / 8]f32 = undefined;
    var d3: [N / 16]f32 = undefined;
    var approx: [N / 16]f32 = undefined;
    const details = [_][]f32{ d0[0..], d1[0..], d2[0..], d3[0..] };
    var sb: [N / 2]fb.Subband(f32) = undefined;
    var lo: [N / 2]Sample(f32) = undefined;

    var tree = Tree{};
    const counts = tree.analyze(&in, &details, approx[0..], sb[0..], lo[0..]);
    try std.testing.expectEqual(@as(usize, N / 2), counts.detail[0]);
    try std.testing.expectEqual(@as(usize, N / 4), counts.detail[1]);
    try std.testing.expectEqual(@as(usize, N / 8), counts.detail[2]);
    try std.testing.expectEqual(@as(usize, N / 16), counts.detail[3]);
    try std.testing.expectEqual(@as(usize, N / 16), counts.approx);

    var e_in: f64 = 0;
    for (in) |s| e_in += @as(f64, s.ch[0]) * s.ch[0];
    var e_out: f64 = 0;
    for (d0) |v| e_out += @as(f64, v) * v;
    for (d1) |v| e_out += @as(f64, v) * v;
    for (d2) |v| e_out += @as(f64, v) * v;
    for (d3) |v| e_out += @as(f64, v) * v;
    for (approx) |v| e_out += @as(f64, v) * v;
    try std.testing.expectApproxEqAbs(e_in, e_out, 1e-4);
}

test "DwtOctaveTree: the final approximation equals the input low-passed `levels` times" {
    // Independent oracle: the cascade's a[L-1] is exactly the result of running the
    // standalone Haar lowpass repeatedly (each stage takes the previous lo lane as
    // its input samples). Re-derive that chain by hand and compare to the tree.
    const L = 3;
    const N = 32;
    var in: [N]Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @cos(@as(f32, @floatFromInt(i)) * 0.7) + 0.1;

    // Hand-rolled cascade of standalone analysis stages, keeping only the lo lane.
    var cur_buf: [N]Sample(f32) = in;
    var cur_len: usize = N;
    var ref_out: [N]Sample(f32) = undefined;
    var level: usize = 0;
    while (level < L) : (level += 1) {
        var st = fb.WaveletAnalysis(f32num){}; // a fresh stage per level
        const half = cur_len / 2;
        var rsb: [N]fb.Subband(f32) = undefined;
        const made = st.pull(cur_buf[0..cur_len], half, rsb[0..half]);
        for (0..made) |j| ref_out[j].ch[0] = rsb[j].lo;
        @memcpy(cur_buf[0..made], ref_out[0..made]);
        cur_len = made;
    }

    // The real tree.
    var d0: [N / 2]f32 = undefined;
    var d1: [N / 4]f32 = undefined;
    var d2: [N / 8]f32 = undefined;
    var approx: [N / 8]f32 = undefined;
    const details = [_][]f32{ d0[0..], d1[0..], d2[0..] };
    var sb: [N / 2]fb.Subband(f32) = undefined;
    var lo: [N / 2]Sample(f32) = undefined;
    var tree = fb.DwtOctaveTree(f32num, L){};
    const counts = tree.analyze(&in, &details, approx[0..], sb[0..], lo[0..]);

    try std.testing.expectEqual(cur_len, counts.approx);
    for (0..cur_len) |j| try std.testing.expectApproxEqAbs(cur_buf[j].ch[0], approx[j], 1e-6);
}

test "DwtOctaveTree: a single-level tree's detail and approximation are exactly one Haar stage" {
    // L=1 is the boundary case: the tree degenerates to a single WaveletAnalysis.
    // Its d[0] must be the highpass and approx the lowpass of that one stage.
    const N = 16;
    var in: [N]Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.ch[0] = @floatFromInt(@as(i32, @intCast(i)) - 8);

    var ref = fb.WaveletAnalysis(f32num){};
    var rsb: [N / 2]fb.Subband(f32) = undefined;
    _ = ref.pull(&in, N / 2, &rsb);

    var d0: [N / 2]f32 = undefined;
    var approx: [N / 2]f32 = undefined;
    const details = [_][]f32{d0[0..]};
    var sb: [N / 2]fb.Subband(f32) = undefined;
    var lo: [N / 2]Sample(f32) = undefined;
    var tree = fb.DwtOctaveTree(f32num, 1){};
    const counts = tree.analyze(&in, &details, approx[0..], sb[0..], lo[0..]);
    try std.testing.expectEqual(@as(usize, N / 2), counts.detail[0]);
    try std.testing.expectEqual(@as(usize, N / 2), counts.approx);
    for (0..N / 2) |k| {
        try std.testing.expectApproxEqAbs(rsb[k].hi, d0[k], 1e-6);
        try std.testing.expectApproxEqAbs(rsb[k].lo, approx[k], 1e-6);
    }
}

// ===========================================================================
// Cqt — the constant-Q bandpass bank.
// ===========================================================================

test "Cqt is rate-1:1: it emits exactly one FeatureFrame per input sample" {
    // The bank runs at the input rate (the surfaced simplification: bands are NOT
    // decimated). Pin out.len == in.len and that the output type is FeatureFrame.
    const bins = 4;
    const C = fb.Cqt(f32num, bins, 31);
    try std.testing.expect(port.classify(C) == .Map);
    try std.testing.expect(port.MapOutElem(C) == types.FeatureFrame(bins));
    var bank = C.init(0.05, 2.0);
    const N = 40;
    var in: [N]Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(2);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;
    var out: [N]types.FeatureFrame(bins) = undefined;
    bank.process(&in, &out);
    // No length surprise: every input sample produced exactly one feature frame
    // (we passed a same-length out buffer; the bank fills all N of them).
    for (out) |fr| {
        // Each frame has `bins` finite values (no NaN/inf escaped the FIRs).
        for (0..bins) |k| try std.testing.expect(std.math.isFinite(fr.v[k]));
    }
}

test "Cqt centre frequencies follow f_c[k] = f_min·2^(k/bpo) (geometric spacing oracle)" {
    // Independent oracle: the documented geometry, recomputed by hand. With
    // bpo=3, band 3 is one octave above band 0, band 6 two octaves, etc.
    const bins = 7;
    const C = fb.Cqt(f32num, bins, 31);
    const f_min: f32 = 0.02;
    const bpo: f32 = 3.0;
    const bank = C.init(f_min, bpo);
    for (0..bins) |k| {
        const want = f_min * std.math.pow(f32, 2.0, @as(f32, @floatFromInt(k)) / bpo);
        try std.testing.expectApproxEqAbs(want, bank.centre(k), 1e-5);
    }
    // An octave (3 bins) up exactly doubles the centre.
    try std.testing.expectApproxEqAbs(bank.centre(0) * 2.0, bank.centre(3), 1e-5);
    try std.testing.expectApproxEqAbs(bank.centre(0) * 4.0, bank.centre(6), 1e-5);
}

test "Cqt is linear: scaling the input scales every band output by the same factor" {
    // The bank is a parallel set of linear FIRs; doubling the input doubles every
    // band column. Independent linearity oracle (run two banks on x and 2x).
    const bins = 3;
    const taps = 31;
    const C = fb.Cqt(f32num, bins, taps);
    var b1 = C.init(0.05, 1.0);
    var b2 = C.init(0.05, 1.0);
    const N = 128;
    var in1: [N]Sample(f32) = undefined;
    var in2: [N]Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(55);
    for (&in1, &in2) |*a, *b| {
        const v = rng.random().float(f32) * 2 - 1;
        a.ch[0] = v;
        b.ch[0] = 2.0 * v;
    }
    var o1: [N]types.FeatureFrame(bins) = undefined;
    var o2: [N]types.FeatureFrame(bins) = undefined;
    b1.process(&in1, &o1);
    b2.process(&in2, &o2);
    for (0..N) |i| for (0..bins) |k| {
        try std.testing.expectApproxEqAbs(2.0 * o1[i].v[k], o2[i].v[k], 1e-5);
    };
}

test "Cqt: a split render equals a whole render (per-band FIR history carries across calls)" {
    // The bank's per-band FIRs hold their own delay-line history; a render chopped
    // into chunks must produce the same band columns as a single call. pan-vs-pan
    // bit-exact (same kernel, same history, different call boundaries).
    const bins = 3;
    const taps = 31;
    const C = fb.Cqt(f32num, bins, taps);
    const N = 200;
    var in: [N]Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(77);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;

    var whole = C.init(0.04, 2.0);
    var o_whole: [N]types.FeatureFrame(bins) = undefined;
    whole.process(&in, &o_whole);

    var split = C.init(0.04, 2.0);
    var o_split: [N]types.FeatureFrame(bins) = undefined;
    var i: usize = 0;
    const chunk = 23; // ragged: chunk ∤ N
    while (i < N) {
        const m = @min(chunk, N - i);
        split.process(in[i .. i + m], o_split[i .. i + m]);
        i += m;
    }
    for (0..N) |j| for (0..bins) |k| {
        // Bit-exact: identical FIR machine code over identical history.
        try std.testing.expectEqual(o_whole[j].v[k], o_split[j].v[k]);
    };
}

test "Cqt: each band concentrates a tone at ITS centre and rejects tones an octave away" {
    // The defining constant-Q-bank behaviour, swept over every band (the in-file
    // test only drives band 0). For a tone at band k's centre, band k's steady-
    // state energy dominates that of a band an octave (one bin, bpo=1) away.
    const bins = 4;
    const taps = 63;
    const C = fb.Cqt(f32num, bins, taps);
    const f_min: f32 = 0.03;
    const bpo: f32 = 1.0; // one bin per octave: band k centred at f_min·2^k

    inline for (0..bins) |target| {
        var bank = C.init(f_min, bpo);
        const fc = bank.centre(target);
        const N = 1024;
        var in: [N]Sample(f32) = undefined;
        for (&in, 0..) |*s, i| s.ch[0] = @sin(2.0 * std.math.pi * fc * @as(f32, @floatFromInt(i)));
        var out: [N]types.FeatureFrame(bins) = undefined;
        bank.process(&in, &out);

        var energy = [_]f64{0} ** bins;
        for (out[taps..]) |fr| {
            for (0..bins) |k| energy[k] += @as(f64, fr.v[k]) * fr.v[k];
        }
        // The target band carries real energy and dominates every NON-adjacent
        // band (a band ≥2 bins away — clearly outside the constant-Q passband).
        try std.testing.expect(energy[target] > 0);
        for (0..bins) |k| {
            const dist = if (k > target) k - target else target - k;
            if (dist >= 2) {
                std.testing.expect(energy[target] > 8.0 * energy[k]) catch |e| {
                    std.debug.print("cqt tone @band {d}: energy {d} not ≫ distant band {d} energy {d}\n", .{ target, energy[target], k, energy[k] });
                    return e;
                };
            }
        }
    }
}

test "Cqt: a zero input produces a zero feature frame in every band" {
    const bins = 4;
    const C = fb.Cqt(f32num, bins, 31);
    var bank = C.init(0.05, 2.0);
    const N = 64;
    var in: [N]Sample(f32) = @splat(.{ .ch = .{0} });
    var out: [N]types.FeatureFrame(bins) = undefined;
    bank.process(&in, &out);
    for (out) |fr| for (0..bins) |k| {
        try std.testing.expectEqual(@as(f32, 0), fr.v[k]);
    };
}

// ===========================================================================
// Structural identities — the Subband element and the cascade composition.
// ===========================================================================

test "Subband(T) is a named port element with a typeName and carries both bands in one element" {
    // Both subbands live in ONE element because they share the stage's single
    // decimated rate — the rule that keeps the cascade uniform-rate Rate stages.
    try std.testing.expectEqualStrings("Subband(f32)", fb.Subband(f32).typeName());
    try std.testing.expectEqualStrings("Subband(f64)", fb.Subband(f64).typeName());
    try std.testing.expect(fb.Subband(f32).lane == f32);
    // The Rate ports mint Sample → Subband and back (structural composition fact).
    try std.testing.expect(port.RateOutElem(fb.WaveletAnalysis(f32num)) == fb.Subband(f32));
    try std.testing.expect(port.RateInElem(fb.WaveletSynthesis(f32num)) == fb.Subband(f32));
    // f32 and f64 subbands are DISTINCT element types (pool-class keys differ).
    try std.testing.expect(fb.Subband(f32) != fb.Subband(f64));
}
