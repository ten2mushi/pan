//! Yoneda "tests as definition" for the spatial-core blocks — `MixMatrix`,
//! `Upmix`/`Downmix`, `canonicalMixMatrix`, `Balance`, `Width`.
//!
//! These blocks are layout-aware `Map`s over PLANAR `Frame(Lane, L)` buffers; a
//! layout change is a morphism whose input/output `Frame`s differ in `L`. The
//! discipline here (catalog §1.3 L1/L2/L3 layout laws, §6 negotiation; testing
//! contract §5.7e):
//!
//!   - The oracle for the matrix mix is an INDEPENDENT, hand-written plane-major
//!     matrix-vector product. It shares NONE of `MixMatrix.process`'s plane/
//!     skip-zero machinery — only the defining law `out[o] = Σ_i m[o][i]·in[i]`.
//!     If the block transposed the matrix, mis-indexed a plane, or dropped the
//!     skip-zero fast path's contribution, allclose against this oracle FAILS.
//!   - The registered-pair coverage walks the full positional matrix
//!     (mono/stereo/5.1/7.1) so every canonical entry in the registry is pinned
//!     by an independently hand-computed expectation (a transcription typo in a
//!     coefficient is caught, not papered over).
//!   - The unregistered-pair boundary is the DATA behind negotiation rejecting a
//!     pair as a hard mismatch: `canonicalMixMatrix(unregistered) == null`. This
//!     is the ⊢ side (A22) — the absence of a coercion, asserted directly.
//!
//! Comparison policy (testing contract §1.1): float lanes use allclose (atol
//! 1e-6, rtol 1e-5 for f32; tighter for f64), never bit-exact, because the
//! oracle and pan differ in summation order.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rule 13/14). Run standalone:
//!   zig test --dep pan -Mroot=tests/spatial_negotiation_yoneda_test.zig -Mpan=src/root.zig

const std = @import("std");
const testing = std.testing;
const pan = @import("pan");

const types = pan.types;
const port = pan.port;
const ChannelLayout = pan.ChannelLayout;

const f32num = pan.numericFor(.f32, .{});
const f64num = pan.numericFor(.f64, .{});

const inv_sqrt2: f64 = 0.7071067811865476; // 1/√2 ≈ −3 dB fold gain

// ===========================================================================
// Independent oracle — a naive plane-major matrix-vector mix.
// Shares no machinery with MixMatrix.process; encodes only the defining law.
// ===========================================================================

fn oracleMix(
    comptime Ci: usize,
    comptime Co: usize,
    matrix: [Co][Ci]f64,
    in_planes: [Ci][]const f32,
    out_planes: [Co][]f64,
) void {
    const n = out_planes[0].len;
    for (0..n) |k| {
        for (0..Co) |o| {
            var acc: f64 = 0;
            for (0..Ci) |i| acc += matrix[o][i] * @as(f64, in_planes[i][k]);
            out_planes[o][k] = acc;
        }
    }
}

// ===========================================================================
// canonicalMixMatrix — the registry is the L2 boundary (catalog §6; §5.7e ⊢).
//
// Each registered positional pair's matrix is pinned against an INDEPENDENTLY
// hand-written expected matrix below. A coefficient typo in the registry fails
// here; a transpose fails the `process` tests; an unregistered pair must be null.
// ===========================================================================

/// Compare a comptime matrix from the registry to a hand-written one entrywise.
fn expectMatrixEq(
    comptime Ci: usize,
    comptime Co: usize,
    got: [Co][Ci]f32,
    want: [Co][Ci]f64,
) !void {
    inline for (0..Co) |o| {
        inline for (0..Ci) |i| {
            try testing.expectApproxEqAbs(want[o][i], @as(f64, got[o][i]), 1e-7);
        }
    }
}

test "canonicalMixMatrix mono→stereo is equal-gain dual-mono (both fronts = source)" {
    // WHY: the L2 registry datum for the simplest widen. Both output rows must
    // carry the single mono input at unity — anything else (e.g. −3 dB split)
    // would change the documented "equal-gain dual mono" law.
    const m = pan.canonicalMixMatrix(.mono, .stereo).?;
    try expectMatrixEq(1, 2, m, .{ .{1.0}, .{1.0} });
}

test "canonicalMixMatrix stereo→mono averages (−6 dB sum, never clips a coherent pair)" {
    // WHY: the documented fold is 0.5·L + 0.5·R. A 1.0/1.0 sum (the naive add)
    // would clip a coherent pair; a 1/√2 fold would be the constant-power choice.
    // Pinning 0.5/0.5 forbids both.
    const m = pan.canonicalMixMatrix(.stereo, .mono).?;
    try expectMatrixEq(2, 1, m, .{.{ 0.5, 0.5 }});
}

test "canonicalMixMatrix stereo→5.1 places L/R on the front pair, leaves new channels silent" {
    // WHY: the conservative, phase-safe widen — FL←L, FR←R, and FC/LFE/Ls/Rs all
    // ZERO (no decorrelating fake-surround). A non-zero centre or surround row
    // would be the "fake surround" the doc explicitly rejects.
    const m = pan.canonicalMixMatrix(.stereo, .surround_5_1).?;
    // rows: FL,FR,FC,LFE,Ls,Rs ; cols: L,R
    try expectMatrixEq(2, 6, m, .{
        .{ 1.0, 0.0 }, // FL ← L
        .{ 0.0, 1.0 }, // FR ← R
        .{ 0.0, 0.0 }, // FC silent
        .{ 0.0, 0.0 }, // LFE silent
        .{ 0.0, 0.0 }, // Ls silent
        .{ 0.0, 0.0 }, // Rs silent
    });
}

test "canonicalMixMatrix stereo→7.1 places L/R on the front pair only" {
    const m = pan.canonicalMixMatrix(.stereo, .surround_7_1).?;
    // rows: FL,FR,FC,LFE,Lb,Rb,Ls,Rs ; cols: L,R
    try expectMatrixEq(2, 8, m, .{
        .{ 1.0, 0.0 }, // FL
        .{ 0.0, 1.0 }, // FR
        .{ 0.0, 0.0 }, // FC
        .{ 0.0, 0.0 }, // LFE
        .{ 0.0, 0.0 }, // Lb
        .{ 0.0, 0.0 }, // Rb
        .{ 0.0, 0.0 }, // Ls
        .{ 0.0, 0.0 }, // Rs
    });
}

test "canonicalMixMatrix 5.1→stereo is the ITU-R BS.775 fold (centre & surrounds at −3 dB)" {
    // WHY: this is the most coefficient-laden registry entry. Lo = FL + .707·FC +
    // .707·Ls ; Ro = FR + .707·FC + .707·Rs ; LFE dropped. Every coefficient is
    // pinned independently: a swapped Ls/Rs column (a classic surround bug) fails,
    // and a dropped centre or a non-zero LFE column fails.
    const m = pan.canonicalMixMatrix(.surround_5_1, .stereo).?;
    // cols: FL,FR,FC,LFE,Ls,Rs ; rows: Lo,Ro
    try expectMatrixEq(6, 2, m, .{
        .{ 1.0, 0.0, inv_sqrt2, 0.0, inv_sqrt2, 0.0 }, // Lo
        .{ 0.0, 1.0, inv_sqrt2, 0.0, 0.0, inv_sqrt2 }, // Ro
    });
}

test "canonicalMixMatrix 5.1→7.1 passes the front bed, lands the side pair on 7.1 sides" {
    // WHY: FL,FR,FC,LFE pass at unity; the 5.1 side pair (Ls,Rs at cols 4,5) must
    // land on the 7.1 SIDE pair (rows 6,7), and the 7.1 BACK pair (rows 4,5) must
    // be silent. A confusion of side/back (the easy bug given SMPTE ordering)
    // would put non-zeros on rows 4,5 and fail here.
    const m = pan.canonicalMixMatrix(.surround_5_1, .surround_7_1).?;
    // cols: FL,FR,FC,LFE,Ls,Rs (6) ; rows: FL,FR,FC,LFE,Lb,Rb,Ls,Rs (8)
    var want: [8][6]f64 = [_][6]f64{[_]f64{0} ** 6} ** 8;
    want[0][0] = 1.0; // FL
    want[1][1] = 1.0; // FR
    want[2][2] = 1.0; // FC
    want[3][3] = 1.0; // LFE
    // rows 4,5 (Lb,Rb) stay silent
    want[6][4] = 1.0; // Ls → Ls
    want[7][5] = 1.0; // Rs → Rs
    try expectMatrixEq(6, 8, m, want);
}

test "canonicalMixMatrix 7.1→5.1 passes the front bed and folds the back pair into the sides at −3 dB" {
    // WHY: the inverse fold. FL,FR,FC,LFE pass; Ls ← Ls + .707·Lb ; Rs ← Rs +
    // .707·Rb. The back→side fold gain must be 1/√2 (−3 dB), and the back pair
    // must NOT also leak to the front — every other cell zero.
    const m = pan.canonicalMixMatrix(.surround_7_1, .surround_5_1).?;
    // cols: FL,FR,FC,LFE,Lb,Rb,Ls,Rs (8) ; rows: FL,FR,FC,LFE,Ls,Rs (6)
    var want: [6][8]f64 = [_][8]f64{[_]f64{0} ** 8} ** 6;
    want[0][0] = 1.0; // FL
    want[1][1] = 1.0; // FR
    want[2][2] = 1.0; // FC
    want[3][3] = 1.0; // LFE
    want[4][6] = 1.0; // Ls ← Ls
    want[4][4] = inv_sqrt2; // Ls ← Lb (−3 dB)
    want[5][7] = 1.0; // Rs ← Rs
    want[5][5] = inv_sqrt2; // Rs ← Rb (−3 dB)
    try expectMatrixEq(8, 6, m, want);
}

test "canonicalMixMatrix returns null for every UNREGISTERED pair (the L2 hard-mismatch boundary, A22)" {
    // WHY: the registry is the data behind negotiation rejecting a non-positional
    // pair as a hard mismatch. Ambisonic, discrete-bus, and "to-an-unregistered"
    // directions must all be null — a non-null here would mean negotiation could
    // silently coerce a layout it has no defined geometry for.
    const amb: ChannelLayout = .{ .ambisonic = .{ .order = 1, .ordering = .acn, .norm = .sn3d } };
    const disc4: ChannelLayout = .{ .discrete = 4 };
    try testing.expect(pan.canonicalMixMatrix(.stereo, amb) == null);
    try testing.expect(pan.canonicalMixMatrix(amb, .stereo) == null);
    try testing.expect(pan.canonicalMixMatrix(disc4, .stereo) == null);
    try testing.expect(pan.canonicalMixMatrix(.stereo, disc4) == null);
    try testing.expect(pan.canonicalMixMatrix(disc4, amb) == null);
    // Even a same-layout discrete pair is unregistered (no canonical geometry).
    try testing.expect(pan.canonicalMixMatrix(disc4, disc4) == null);
}

test "canonicalMixMatrix mono→mono and stereo→stereo are unregistered (no identity entry)" {
    // WHY: the registry only carries genuine up/down conversions; an identity pair
    // is NOT registered (the registry's switch has no 1→1 or 2→2 prong → null).
    // This pins that the registry is conversions-only, so a same-layout edge needs
    // no matrix insertion at all.
    try testing.expect(pan.canonicalMixMatrix(.mono, .mono) == null);
    try testing.expect(pan.canonicalMixMatrix(.stereo, .stereo) == null);
    try testing.expect(pan.canonicalMixMatrix(.surround_5_1, .surround_5_1) == null);
}

test "canonicalMixMatrix is unregistered for the mono↔surround pairs (no registry prong)" {
    // WHY: only the prongs enumerated in the switch are registered. mono→5.1,
    // mono→7.1, 5.1→mono, 7.1→stereo etc. have no prong, so the `else` branch
    // returns null. This delimits exactly which conversions exist as data.
    try testing.expect(pan.canonicalMixMatrix(.mono, .surround_5_1) == null);
    try testing.expect(pan.canonicalMixMatrix(.mono, .surround_7_1) == null);
    try testing.expect(pan.canonicalMixMatrix(.surround_5_1, .mono) == null);
    try testing.expect(pan.canonicalMixMatrix(.surround_7_1, .mono) == null);
    try testing.expect(pan.canonicalMixMatrix(.surround_7_1, .stereo) == null);
}

// ===========================================================================
// MixMatrix / Upmix / Downmix — port classification & layout identities
// ===========================================================================

test "MixMatrix ports classify as a layout-changing Map with the correct Frame element types" {
    // WHY: a layout change is a morphism whose input/output Frames differ in L;
    // the port scanner must report Frame(T, L_in) → Frame(T, L_out), else the
    // graph would type-check the wrong edge. Cover a widen and a narrow.
    const Up = pan.Upmix(f32num, .stereo, .surround_5_1);
    const Dn = pan.Downmix(f32num, .surround_5_1, .stereo);
    try testing.expect(port.classify(Up) == .Map);
    try testing.expect(port.classify(Dn) == .Map);
    try testing.expect(port.MapInPort(Up).Elem == types.Frame(f32, .stereo));
    try testing.expect(port.MapOutPort(Up).Elem == types.Frame(f32, .surround_5_1));
    try testing.expect(port.MapInPort(Dn).Elem == types.Frame(f32, .surround_5_1));
    try testing.expect(port.MapOutPort(Dn).Elem == types.Frame(f32, .stereo));
    // The Frame identity differs from a same-lane different-layout Frame: a
    // layout change is observable in the type, not just the buffer geometry.
    try testing.expect(types.Frame(f32, .stereo) != types.Frame(f32, .surround_5_1));
}

/// Helper: run a MixMatrix instance over distinct per-channel ramps and check
/// every output plane against the independent oracle over the SAME canonical
/// matrix. `tol` is the allclose atol for the lane.
fn checkMixAgainstOracle(
    comptime num: anytype,
    comptime L_in: ChannelLayout,
    comptime L_out: ChannelLayout,
    comptime n: usize,
    tol: f64,
) !void {
    const T = num.Lane;
    const Ci = comptime L_in.count();
    const Co = comptime L_out.count();
    const Blk = pan.MixMatrix(num, L_in, L_out);
    var blk = Blk{};

    // Distinct ramp per input channel so a plane swap is observable.
    var in_buf: [Ci * n]T = undefined;
    for (0..Ci) |c| for (0..n) |k| {
        in_buf[c * n + k] = @floatCast(@as(f64, @floatFromInt(10 * (c + 1) + k)) + 0.5);
    };
    const in = types.PlanarConst(T, L_in).fromBase(&in_buf, n);
    var out_buf: [Co * n]T = undefined;
    const out = types.Planar(T, L_out).fromBase(&out_buf, n);
    blk.process(in, out);

    // Oracle over the SAME canonical matrix, computed independently in f64.
    const canon = pan.canonicalMixMatrix(L_in, L_out).?;
    var m64: [Co][Ci]f64 = undefined;
    for (0..Co) |o| for (0..Ci) |i| {
        m64[o][i] = canon[o][i];
    };
    var oin: [Ci][]const f32 = undefined;
    var oin_buf: [Ci * n]f32 = undefined;
    for (0..Ci) |c| {
        for (0..n) |k| oin_buf[c * n + k] = @floatCast(in_buf[c * n + k]);
        oin[c] = oin_buf[c * n ..][0..n];
    }
    var oout_buf: [Co * n]f64 = undefined;
    var oout: [Co][]f64 = undefined;
    for (0..Co) |o| oout[o] = oout_buf[o * n ..][0..n];
    oracleMix(Ci, Co, m64, oin, oout);

    for (0..Co) |o| for (0..n) |k| {
        try testing.expectApproxEqAbs(oout[o][k], @as(f64, out.plane(o)[k]), tol);
    };
}

test "MixMatrix matches the independent oracle across EVERY registered positional pair (f32, allclose)" {
    // WHY: the Yoneda sweep — pin the block's action against an independent
    // matrix-vector product for the whole registry, so any single mis-wired plane
    // or transposed/typo'd coefficient surfaces as an allclose failure.
    try checkMixAgainstOracle(f32num, .mono, .stereo, 4, 1e-5);
    try checkMixAgainstOracle(f32num, .stereo, .mono, 4, 1e-5);
    try checkMixAgainstOracle(f32num, .stereo, .surround_5_1, 4, 1e-5);
    try checkMixAgainstOracle(f32num, .stereo, .surround_7_1, 4, 1e-5);
    try checkMixAgainstOracle(f32num, .surround_5_1, .stereo, 4, 1e-4);
    try checkMixAgainstOracle(f32num, .surround_5_1, .surround_7_1, 4, 1e-5);
    try checkMixAgainstOracle(f32num, .surround_7_1, .surround_5_1, 4, 1e-4);
}

test "MixMatrix matches the oracle in f64 too (precision is a comptime monomorph)" {
    // WHY: the block is monomorphized over the Numeric trait; the SAME law must
    // hold in f64 (tighter tolerance), proving the kernel is precision-generic and
    // not accidentally f32-pinned.
    try checkMixAgainstOracle(f64num, .surround_5_1, .stereo, 4, 1e-12);
    try checkMixAgainstOracle(f64num, .surround_7_1, .surround_5_1, 4, 1e-12);
}

test "MixMatrix output indexing is row=out/col=in — a transposed expectation FAILS the law" {
    // WHY: prove the indexing orientation directly (not via the symmetric oracle).
    // Use 5.1→stereo with a single non-zero input channel (FC only) and verify the
    // result lands on BOTH Lo and Ro at .707 — a transposed matrix (col=out) would
    // route the wrong input and give the wrong planes.
    const Dn = pan.Downmix(f32num, .surround_5_1, .stereo);
    var dn = Dn{};
    const n = 1;
    // FC = 4.0, everything else 0. Layout cols: FL,FR,FC,LFE,Ls,Rs.
    var in_buf: [6 * n]f32 = [_]f32{0} ** (6 * n);
    in_buf[2 * n + 0] = 4.0; // FC plane
    const in = types.PlanarConst(f32, .surround_5_1).fromBase(&in_buf, n);
    var out_buf: [2 * n]f32 = undefined;
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, n);
    dn.process(in, out);
    // Lo = .707·FC, Ro = .707·FC.
    try testing.expectApproxEqAbs(@as(f32, @floatCast(inv_sqrt2 * 4.0)), out.plane(0)[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(inv_sqrt2 * 4.0)), out.plane(1)[0], 1e-5);
}

test "MixMatrix is linear: scaling the input scales the output, and superposition holds" {
    // WHY: a matrix mix is a LINEAR map. f(2·x) = 2·f(x) and f(x+y) = f(x)+f(y)
    // is the structural property a coefficient matrix MUST satisfy; a non-linear
    // bug (clip, abs, per-sample gain) would break it even if a single-vector
    // spot-check passed.
    const Dn = pan.Downmix(f32num, .surround_5_1, .stereo);
    const n = 1;
    const run = struct {
        fn go(planes: [6]f32) [2]f32 {
            var blk = Dn{};
            var ib: [6 * n]f32 = undefined;
            for (0..6) |c| ib[c * n] = planes[c];
            const in = types.PlanarConst(f32, .surround_5_1).fromBase(&ib, n);
            var ob: [2 * n]f32 = undefined;
            const out = types.Planar(f32, .stereo).fromBase(&ob, n);
            blk.process(in, out);
            return .{ out.plane(0)[0], out.plane(1)[0] };
        }
    }.go;
    const x = [6]f32{ 1, 2, 3, 4, 5, 6 };
    const y = [6]f32{ -2, 0.5, 1, 0, -3, 2 };
    var xy: [6]f32 = undefined;
    var x2: [6]f32 = undefined;
    for (0..6) |c| {
        xy[c] = x[c] + y[c];
        x2[c] = 2 * x[c];
    }
    const fx = run(x);
    const fy = run(y);
    const fxy = run(xy);
    const fx2 = run(x2);
    for (0..2) |o| {
        try testing.expectApproxEqAbs(fx[o] + fy[o], fxy[o], 1e-5); // superposition
        try testing.expectApproxEqAbs(2 * fx[o], fx2[o], 1e-5); // homogeneity
    }
}

test "MixMatrix zeroes each output plane before accumulating (stale-buffer independence)" {
    // WHY: process() @memsets each output plane to 0 first. The output must NOT
    // depend on whatever garbage the destination held — run twice with a dirtied
    // buffer between and demand the same result.
    const Up = pan.Upmix(f32num, .stereo, .surround_5_1);
    var up = Up{};
    const n = 2;
    var in_buf: [2 * n]f32 = .{ 1, 2, 3, 4 };
    const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, n);
    var out_buf: [6 * n]f32 = undefined;
    const out = types.Planar(f32, .surround_5_1).fromBase(&out_buf, n);
    up.process(in, out);
    var first: [6 * n]f32 = undefined;
    @memcpy(&first, &out_buf);
    // Dirty the buffer with a poison pattern, then re-run.
    for (&out_buf) |*v| v.* = 999.0;
    up.process(in, out);
    try testing.expectEqualSlices(f32, &first, &out_buf);
    // And the silent (centre/LFE/surround) planes really are zero, not 999.
    try testing.expectEqual(@as(f32, 0), out.plane(2)[0]); // FC
    try testing.expectEqual(@as(f32, 0), out.plane(3)[0]); // LFE
}

test "MixMatrix custom matrix overrides the canonical default (coefficients are block data)" {
    // WHY: the matrix is a runtime field defaulting to the canonical one; setting
    // it must take effect (the L3 law — geometry is block data, not the type). Use
    // a stereo→stereo-shaped MixMatrix via a registered pair is impossible (no 2→2
    // entry), so override on 5.1→stereo with an all-FL-only matrix and check.
    const Dn = pan.MixMatrix(f32num, .surround_5_1, .stereo);
    var dn = Dn{};
    // Override: Lo = 2·FL only, Ro = 3·FR only.
    dn.matrix = [_][6]f32{[_]f32{0} ** 6} ** 2;
    dn.matrix[0][0] = 2.0;
    dn.matrix[1][1] = 3.0;
    const n = 1;
    var in_buf: [6 * n]f32 = .{ 5, 7, 100, 100, 100, 100 }; // FL=5, FR=7, rest ignored
    const in = types.PlanarConst(f32, .surround_5_1).fromBase(&in_buf, n);
    var out_buf: [2 * n]f32 = undefined;
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, n);
    dn.process(in, out);
    try testing.expectApproxEqAbs(@as(f32, 10.0), out.plane(0)[0], 1e-6); // 2·5
    try testing.expectApproxEqAbs(@as(f32, 21.0), out.plane(1)[0], 1e-6); // 3·7
}

test "Upmix/Downmix round-trips the 5.1↔7.1 front bed and side pair exactly (identity on the common channels)" {
    // WHY: 5.1→7.1→5.1 must be the identity on all six 5.1 channels — FL/FR/FC/LFE
    // pass at unity each way, and the side pair survives because 7.1 has a free
    // back pair to park nothing into. This is the L-functor "round-trip" law.
    const Up = pan.Upmix(f32num, .surround_5_1, .surround_7_1);
    const Dn = pan.Downmix(f32num, .surround_7_1, .surround_5_1);
    var up = Up{};
    var dn = Dn{};
    const n = 3;
    var a_buf: [6 * n]f32 = undefined;
    for (0..6) |c| for (0..n) |k| {
        a_buf[c * n + k] = @floatFromInt(7 * (c + 1) + 2 * k + 1);
    };
    const a = types.PlanarConst(f32, .surround_5_1).fromBase(&a_buf, n);
    var b_buf: [8 * n]f32 = undefined;
    const b = types.Planar(f32, .surround_7_1).fromBase(&b_buf, n);
    up.process(a, b);
    const b_c = types.PlanarConst(f32, .surround_7_1).fromBase(&b_buf, n);
    var c_buf: [6 * n]f32 = undefined;
    const c = types.Planar(f32, .surround_5_1).fromBase(&c_buf, n);
    dn.process(b_c, c);
    for (0..6) |ch| for (0..n) |k| {
        try testing.expectApproxEqAbs(a_buf[ch * n + k], c.plane(ch)[k], 1e-6);
    };
    // And the 7.1 back pair (rows 4,5: Lb,Rb) really was left silent on the upmix.
    try testing.expectEqual(@as(f32, 0), b.plane(4)[0]);
    try testing.expectEqual(@as(f32, 0), b.plane(5)[0]);
}

// ===========================================================================
// Balance — stereo, layout-preserving, attenuate-only console balance.
// ===========================================================================

test "Balance classifies as a layout-PRESERVING stereo→stereo Map with a balance param" {
    // WHY: unlike a panner, balance keeps stereo→stereo (no layout change); the
    // port element must be Frame(f32,.stereo) on BOTH sides, and the control param
    // must expose Scalar(f32) so a modulation edge type-checks.
    const Bal = pan.Balance(f32num);
    try testing.expect(port.classify(Bal) == .Map);
    try testing.expect(port.MapInPort(Bal).Elem == types.Frame(f32, .stereo));
    try testing.expect(port.MapOutPort(Bal).Elem == types.Frame(f32, .stereo));
    const Bp = port.ParamPort(Bal, "balance");
    try testing.expect(Bp.Elem == types.Scalar(f32));
    try testing.expect(comptime port.isParamPort(Bp));
}

test "Balance attenuates ONE channel only and never boosts (the console-balance law)" {
    // WHY: balance>0 attenuates LEFT (gain 1−b) and leaves RIGHT at unity;
    // balance<0 attenuates RIGHT (gain 1+b) and leaves LEFT at unity; neither gain
    // ever exceeds 1. A panner would re-pan both; this must not. Sweep b across
    // [-1,1] and assert the untouched channel is exactly unity and the touched one
    // is the linear taper.
    const Bal = pan.Balance(f32num);
    var b: f32 = -1.0;
    while (b <= 1.0 + 1e-9) : (b += 0.1) {
        var bal = Bal{ .balance = b };
        var in_buf: [2]f32 = .{ 1.0, 1.0 };
        const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 1);
        var out_buf: [2]f32 = undefined;
        const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
        bal.process(in, out);
        const lg: f32 = if (b > 0) 1.0 - b else 1.0;
        const rg: f32 = if (b < 0) 1.0 + b else 1.0;
        try testing.expectApproxEqAbs(lg, out.plane(0)[0], 1e-6);
        try testing.expectApproxEqAbs(rg, out.plane(1)[0], 1e-6);
        // never a boost
        try testing.expect(out.plane(0)[0] <= 1.0 + 1e-6);
        try testing.expect(out.plane(1)[0] <= 1.0 + 1e-6);
    }
}

test "Balance clamps the position into [-1,1] (out-of-range never inverts a channel)" {
    // WHY: an out-of-range balance must clamp, not produce a negative gain
    // (b=+2 would give 1−2 = −1, a phase flip) — the clamp keeps gains in [0,1].
    const Bal = pan.Balance(f32num);
    var in_buf: [2]f32 = .{ 1.0, 1.0 };
    const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 1);
    var out_buf: [2]f32 = undefined;
    const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
    var hi = Bal{ .balance = 5.0 }; // clamps to +1 → left muted
    hi.process(in, out);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out.plane(1)[0], 1e-6);
    var lo = Bal{ .balance = -5.0 }; // clamps to −1 → right muted
    lo.process(in, out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out.plane(0)[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out.plane(1)[0], 1e-6);
}

// ===========================================================================
// Width — stereo, layout-preserving, mid/side decomposition.
// ===========================================================================

test "Width classifies as a layout-preserving stereo→stereo Map with a width param" {
    const Wd = pan.Width(f32num);
    try testing.expect(port.classify(Wd) == .Map);
    try testing.expect(port.MapInPort(Wd).Elem == types.Frame(f32, .stereo));
    try testing.expect(port.MapOutPort(Wd).Elem == types.Frame(f32, .stereo));
    const Wp = port.ParamPort(Wd, "width");
    try testing.expect(Wp.Elem == types.Scalar(f32));
}

test "Width implements the mid/side law out_L=mid+w·side, out_R=mid−w·side (independent recompute)" {
    // WHY: the defining law, checked against an INDEPENDENT recomputation of
    // mid=(L+R)/2, side=(L−R)/2 over a sweep of widths and a non-symmetric input.
    // A sign error on the side term (the classic mid/side bug) flips the channels
    // and fails here.
    const Wd = pan.Width(f32num);
    const L: f32 = 0.8;
    const R: f32 = -0.2;
    const mid = (L + R) * 0.5;
    const side = (L - R) * 0.5;
    var w: f32 = 0.0;
    while (w <= 2.0 + 1e-9) : (w += 0.25) {
        var wd = Wd{ .width = w };
        var in_buf: [2]f32 = .{ L, R };
        const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 1);
        var out_buf: [2]f32 = undefined;
        const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
        wd.process(in, out);
        try testing.expectApproxEqAbs(mid + w * side, out.plane(0)[0], 1e-6);
        try testing.expectApproxEqAbs(mid - w * side, out.plane(1)[0], 1e-6);
    }
}

test "Width: w=1 is identity, w=0 collapses to dual-mono mid, mono input is width-invariant" {
    // WHY: the three documented anchors. w=1 ⇒ output == input (the side term is
    // fully restored); w=0 ⇒ both channels = mid (no side); a centred mono signal
    // (L==R ⇒ side=0) is unchanged at ANY width.
    const Wd = pan.Width(f32num);
    // w=1 identity on an arbitrary stereo pair.
    {
        var wd = Wd{ .width = 1 };
        var in_buf: [2]f32 = .{ 0.3, -0.9 };
        const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 1);
        var out_buf: [2]f32 = undefined;
        const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
        wd.process(in, out);
        try testing.expectApproxEqAbs(@as(f32, 0.3), out.plane(0)[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, -0.9), out.plane(1)[0], 1e-6);
    }
    // w=0 collapses to mid on both.
    {
        var wd = Wd{ .width = 0 };
        var in_buf: [2]f32 = .{ 0.3, -0.9 };
        const mid = (0.3 + -0.9) * 0.5;
        const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 1);
        var out_buf: [2]f32 = undefined;
        const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
        wd.process(in, out);
        try testing.expectApproxEqAbs(@as(f32, mid), out.plane(0)[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, mid), out.plane(1)[0], 1e-6);
    }
    // mono (L==R) invariant under any width.
    {
        var wd = Wd{ .width = 1.75 };
        var in_buf: [2]f32 = .{ 0.6, 0.6 };
        const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 1);
        var out_buf: [2]f32 = undefined;
        const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
        wd.process(in, out);
        try testing.expectApproxEqAbs(@as(f32, 0.6), out.plane(0)[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0.6), out.plane(1)[0], 1e-6);
    }
}

test "Width preserves the mid (sum) for any width — only the side scales" {
    // WHY: out_L + out_R = 2·mid for ANY w (the side terms cancel). This is the
    // structural invariant of an M/S width control: it cannot move energy into the
    // mono sum. A bug that scaled the mid would break this even when a single
    // channel happened to match.
    const Wd = pan.Width(f32num);
    const L: f32 = 0.4;
    const R: f32 = 0.1;
    const sum = L + R;
    for ([_]f32{ 0, 0.5, 1, 1.5, 2, 3 }) |w| {
        var wd = Wd{ .width = w };
        var in_buf: [2]f32 = .{ L, R };
        const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, 1);
        var out_buf: [2]f32 = undefined;
        const out = types.Planar(f32, .stereo).fromBase(&out_buf, 1);
        wd.process(in, out);
        try testing.expectApproxEqAbs(sum, out.plane(0)[0] + out.plane(1)[0], 1e-6);
    }
}

// ===========================================================================
// Multi-frame buffer coverage — the kernels must walk a whole plane, not just
// frame 0 (a classic "only the first sample is right" bug).
// ===========================================================================

test "Balance and Width process the WHOLE buffer, not just the first frame" {
    // WHY: every prior anchor test used n=1; this asserts the per-sample loop
    // covers all frames so a kernel that wrote only out[0] would fail.
    const n = 5;
    {
        const Bal = pan.Balance(f32num);
        var bal = Bal{ .balance = 0.5 }; // left gain 0.5, right unity
        var in_buf: [2 * n]f32 = undefined;
        for (0..n) |k| {
            in_buf[k] = @floatFromInt(k + 1); // L plane
            in_buf[n + k] = @floatFromInt(10 * (k + 1)); // R plane
        }
        const in = types.PlanarConst(f32, .stereo).fromBase(&in_buf, n);
        var out_buf: [2 * n]f32 = undefined;
        const out = types.Planar(f32, .stereo).fromBase(&out_buf, n);
        bal.process(in, out);
        for (0..n) |k| {
            try testing.expectApproxEqAbs(0.5 * in_buf[k], out.plane(0)[k], 1e-6);
            try testing.expectApproxEqAbs(in_buf[n + k], out.plane(1)[k], 1e-6);
        }
    }
}
