//! Yoneda "tests as definition" suite for the pan test-comparison backbone
//! (`tests/harness.zig`). These tests ARE the operational definition of the
//! locked comparison policy — they characterize each comparator by every
//! morphism that matters: the exact accept / reject / error boundary.
//!
//! THE LOAD-BEARING LAW (restated): tolerance forgives the *external oracle's*
//! different arithmetic (f64 working precision, summation order, libm
//! transcendentals) but NEVER forgives pan disagreeing with itself. Hence
//! `allcloseF32` is the ONLY float-tolerant comparator (oracle-only); every
//! pan-vs-pan check (`bitExact`, `alignByLatency`) is bit-exact.
//!
//! COMPARISON MODE (testing contract §0.5): we are testing the comparators
//! THEMSELVES. So we construct known `got` / `ref` / manifest inputs and assert
//! the exact accept / reject / error outcome. The deterministic helpers
//! (`measuredGroupDelay`, `resolveTolerance`, the latency cursor math) are
//! pinned by exact equality. All values that touch the `f64` allclose boundary
//! are chosen to be exactly representable (powers of two / dyadic rationals) so
//! the `>` test against the bound is decided without rounding slop.
//!
//! Verified against zig 0.16.0 (the `zig-0-16` skill was loaded before
//! authoring, per project Rules 13/14). Standalone command:
//!   zig test --dep pan -Mroot=tests/comparator_test.zig -Mpan=src/root.zig

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const testing = std.testing;

// ===========================================================================
// allcloseF32 — the numpy.allclose policy, the ONLY legal float tolerance.
//
// Policy: accept iff every elementwise |got - ref| <= atol + rtol*|ref|.
// Reject (error.OracleMismatch) on the first element past the bound. Error
// (error.LengthMismatch) on unequal lengths. We characterize the accept/reject
// boundary to the last bit.
// ===========================================================================

test "allcloseF32: identical slices pass under any non-negative tolerance (the trivial morphism)" {
    const got = [_]f32{ -1.0, 0.0, 0.5, 1.0, 1024.0 };
    const ref = got;
    // Even a zero/zero tolerance accepts an exact match: diff==0, bound==0, 0>0 is false.
    try h.allcloseF32(&got, &ref, .{ .approx = .{ .atol = 0.0, .rtol = 0.0 } });
    try h.allcloseF32(&got, &ref, .{ .approx = .{ .atol = 1e-6, .rtol = 1e-5 } });
}

test "allcloseF32: an empty pair is vacuously close (no element can violate the bound)" {
    const empty = [_]f32{};
    try h.allcloseF32(&empty, &empty, .{ .approx = .{ .atol = 0.0, .rtol = 0.0 } });
}

test "allcloseF32: a difference EXACTLY at the bound atol+rtol*|ref| is accepted (closed lower edge)" {
    // ref = 0 so the bound collapses to atol. atol = 0.25 (dyadic, exact in f64).
    // got = 0.25 -> diff = 0.25 == bound -> 0.25 > 0.25 is false -> ACCEPT.
    const ref = [_]f32{0.0};
    const got = [_]f32{0.25};
    try h.allcloseF32(&got, &ref, .{ .approx = .{ .atol = 0.25, .rtol = 0.0 } });
}

test "allcloseF32: a difference JUST PAST the bound is rejected (open upper edge)" {
    // bound = atol = 0.25 exactly; diff = 0.25 + one f32 ULP at ~0.5 magnitude.
    // The widened f64 diff strictly exceeds 0.25, so it must REJECT.
    const ref = [_]f32{0.0};
    const just_over: f32 = 0.25 + std.math.floatEps(f32) * 0.25;
    const got = [_]f32{just_over};
    // Sanity: the perturbation is genuinely larger than the bound in f64 space.
    try testing.expect(@as(f64, just_over) > 0.25);
    try testing.expectError(error.OracleMismatch, h.allcloseF32(&got, &ref, .{ .approx = .{ .atol = 0.25, .rtol = 0.0 } }));
}

test "allcloseF32: with zero rtol a tiny atol behaves as a pure ABSOLUTE bound, independent of |ref|" {
    // Same absolute diff (0.5) against two very different ref magnitudes. With
    // rtol=0 the bound is atol everywhere, so a diff above atol fails REGARDLESS
    // of how large |ref| is — proving rtol is truly off.
    const atol = 0.5;
    {
        const ref = [_]f32{4.0};
        const got = [_]f32{4.5}; // diff 0.5 == atol -> accept
        try h.allcloseF32(&got, &ref, .{ .approx = .{ .atol = atol, .rtol = 0.0 } });
    }
    {
        const ref = [_]f32{1.0e6}; // huge |ref| but rtol is 0, so bound stays 0.5
        const got = [_]f32{1.0e6 + 1.0}; // diff 1.0 > 0.5 -> reject
        try testing.expectError(error.OracleMismatch, h.allcloseF32(&got, &ref, .{ .approx = .{ .atol = atol, .rtol = 0.0 } }));
    }
}

test "allcloseF32: rtol scales the bound with |ref| — the same absolute diff passes at large |ref|, fails at small" {
    // rtol = 0.125, atol = 0. bound = 0.125*|ref|.
    // |ref| = 8 -> bound = 1.0 ; a diff of 1.0 sits exactly on the edge -> accept.
    // |ref| = 4 -> bound = 0.5 ; the SAME diff of 1.0 is past the edge -> reject.
    const tol = h.Tolerance{ .approx = .{ .atol = 0.0, .rtol = 0.125 } };
    {
        const ref = [_]f32{8.0};
        const got = [_]f32{9.0}; // diff 1.0 == 0.125*8 -> accept
        try h.allcloseF32(&got, &ref, tol);
    }
    {
        const ref = [_]f32{4.0};
        const got = [_]f32{5.0}; // diff 1.0 > 0.125*4 = 0.5 -> reject
        try testing.expectError(error.OracleMismatch, h.allcloseF32(&got, &ref, tol));
    }
}

test "allcloseF32: rtol uses |ref| (the magnitude), so a NEGATIVE ref of equal magnitude gives the same bound" {
    // bound = rtol*|ref|; |−8| == 8, so the −8 case must behave like the +8 case.
    const tol = h.Tolerance{ .approx = .{ .atol = 0.0, .rtol = 0.125 } };
    const ref = [_]f32{-8.0};
    const got_edge = [_]f32{-9.0}; // diff = |−9 − (−8)| = 1.0 == 0.125*8 -> accept
    try h.allcloseF32(&got_edge, &ref, tol);
    const got_over = [_]f32{-9.5}; // diff = 1.5 > 1.0 -> reject
    try testing.expectError(error.OracleMismatch, h.allcloseF32(&got_over, &ref, tol));
}

test "allcloseF32: atol and rtol ADD — the bound is atol + rtol*|ref|, both contributing" {
    // atol = 0.5, rtol = 0.125, ref = 8 -> bound = 0.5 + 1.0 = 1.5.
    const tol = h.Tolerance{ .approx = .{ .atol = 0.5, .rtol = 0.125 } };
    const ref = [_]f32{8.0};
    const got_edge = [_]f32{9.5}; // diff 1.5 == bound -> accept
    try h.allcloseF32(&got_edge, &ref, tol);
    const got_over = [_]f32{9.625}; // diff 1.625 > 1.5 -> reject (1.625 is dyadic)
    try testing.expectError(error.OracleMismatch, h.allcloseF32(&got_over, &ref, tol));
}

test "allcloseF32: rejection is elementwise — one bad lane among many good ones fails the whole comparison" {
    var got = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const ref = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    got[3] = 4.5; // diff 0.5 > atol 0.1, all others exact
    try testing.expectError(error.OracleMismatch, h.allcloseF32(&got, &ref, .{ .approx = .{ .atol = 0.1, .rtol = 0.0 } }));
}

test "allcloseF32: unequal lengths are error.LengthMismatch (checked before any elementwise compare)" {
    const got = [_]f32{ 1.0, 2.0, 3.0 };
    const ref = [_]f32{ 1.0, 2.0 };
    try testing.expectError(error.LengthMismatch, h.allcloseF32(&got, &ref, .{ .approx = .{ .atol = 1.0, .rtol = 1.0 } }));
    // Symmetric: ref longer than got is equally a length mismatch.
    try testing.expectError(error.LengthMismatch, h.allcloseF32(&ref, &got, .{ .approx = .{ .atol = 1.0, .rtol = 1.0 } }));
}

test "allcloseF32: a length mismatch outranks a value match — empty-vs-nonempty is still LengthMismatch" {
    const empty = [_]f32{};
    const one = [_]f32{0.0};
    try testing.expectError(error.LengthMismatch, h.allcloseF32(&empty, &one, .{ .approx = .{ .atol = 1e9, .rtol = 1e9 } }));
}

// ===========================================================================
// bitExact — exact slice equality. The pan-vs-pan comparator (and the
// integer/fixed-point oracle). NO tolerance is ever applied here.
// ===========================================================================

test "bitExact: identical slices pass (f32 lane)" {
    const got = [_]f32{ 0.0, 1.5, -2.25, 1024.0 };
    const ref = got;
    try h.bitExact(f32, &got, &ref);
}

test "bitExact: a single differing element fails — even a one-ULP float difference is a divergence, not an 'almost'" {
    const ref = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var got = ref;
    // The smallest possible perturbation at this magnitude: pan disagreeing with
    // itself by one ULP is a FAILURE (the load-bearing law — no float slack here).
    got[2] = std.math.nextAfter(f32, 3.0, std.math.inf(f32));
    try testing.expect(got[2] != ref[2]);
    try testing.expectError(error.TestExpectedEqual, h.bitExact(f32, &got, &ref));
}

test "bitExact: distinguishes +0.0 from −0.0 only if expectEqualSlices does — pin the actual contract" {
    // +0.0 and −0.0 are bit-DIFFERENT but compare equal under ==. bitExact uses
    // expectEqualSlices, which compares with ==, so these are treated as EQUAL.
    // This test pins that observable contract (not the bit pattern).
    const ref = [_]f32{0.0};
    const got = [_]f32{-0.0};
    try h.bitExact(f32, &got, &ref);
}

test "bitExact: works over integer lanes (the fixed-point/integer oracle path), exact match passes" {
    const ref = [_]i16{ -32768, -1, 0, 1, 32767 };
    const got = ref;
    try h.bitExact(i16, &got, &ref);
}

test "bitExact: one differing integer element fails" {
    const ref = [_]i16{ 10, 20, 30 };
    var got = ref;
    got[1] = 21;
    try testing.expectError(error.TestExpectedEqual, h.bitExact(i16, &got, &ref));
}

test "bitExact: a length difference fails (expectEqualSlices flags unequal lengths)" {
    const ref = [_]u8{ 1, 2, 3 };
    const got = [_]u8{ 1, 2 };
    try testing.expectError(error.TestExpectedEqual, h.bitExact(u8, &got, &ref));
}

test "bitExact: two empty slices are equal" {
    const empty = [_]u8{};
    try h.bitExact(u8, &empty, &empty);
}

// ===========================================================================
// alignByLatency — pan-vs-pan overlap comparison with a known shift.
//
// latency = 0 : full bit-exact comparison of the two whole streams.
// latency = L : compare push[L..] against pull[0 .. len-L], bit-exact.
// A stream shorter than L errors with error.TooShort.
// ===========================================================================

test "alignByLatency: latency 0 is a full bit-exact comparison (degenerates to bitExact of the wholes)" {
    const push = [_]f32{ 1, 2, 3, 4, 5 };
    const pull = [_]f32{ 1, 2, 3, 4, 5 };
    try h.alignByLatency(f32, &push, &pull, 0);
}

test "alignByLatency: latency 0 rejects when the streams differ anywhere" {
    const push = [_]f32{ 1, 2, 3, 4, 5 };
    var pull = push;
    pull[4] = 99;
    try testing.expectError(error.TestExpectedEqual, h.alignByLatency(f32, &push, &pull, 0));
}

test "alignByLatency: latency L compares push[L..] against pull[0..len-L] for a known shift-by-L pair" {
    // Construct pull as push delayed by L=3: pull[i] = push[i-3], leading samples
    // are the delay fill. The overlap push[3..] vs pull[0..len-3] must match.
    const L = 3;
    const push = [_]f32{ 10, 11, 12, 13, 14, 15, 16, 17 };
    // pull is the SAME stream observed 3 samples late: its first len-3 samples
    // equal push[3..]. (Pull is longer/equal; only the overlap is compared.)
    const pull = [_]f32{ 13, 14, 15, 16, 17, 0, 0, 0 };
    try h.alignByLatency(f32, &push, &pull, L);
}

test "alignByLatency: a WRONG shift is rejected — the overlap must match bit-exactly, not approximately" {
    const L = 2;
    const push = [_]f32{ 1, 2, 3, 4, 5 };
    // pull claims latency 2 but is actually shifted by 1: overlap won't line up.
    const pull = [_]f32{ 2, 3, 4, 5, 6 };
    // push[2..] = {3,4,5}; pull[0..3] = {2,3,4} -> mismatch.
    try testing.expectError(error.TestExpectedEqual, h.alignByLatency(f32, &push, &pull, L));
}

test "alignByLatency: latency equal to length compares the empty overlap (vacuously passes)" {
    // push[len..] is empty and pull[0..0] is empty; equal-length empties match.
    const push = [_]f32{ 1, 2, 3 };
    const pull = [_]f32{ 9, 9, 9 };
    try h.alignByLatency(f32, &push, &pull, 3);
}

test "alignByLatency: a push stream shorter than the latency errors with TooShort" {
    const push = [_]f32{ 1, 2 };
    const pull = [_]f32{ 1, 2, 3, 4, 5 };
    try testing.expectError(error.TooShort, h.alignByLatency(f32, &push, &pull, 3));
}

test "alignByLatency: a pull stream shorter than the latency errors with TooShort" {
    const push = [_]f32{ 1, 2, 3, 4, 5 };
    const pull = [_]f32{ 1, 2 };
    try testing.expectError(error.TooShort, h.alignByLatency(f32, &push, &pull, 3));
}

// ===========================================================================
// measuredGroupDelay — index of the first sample whose magnitude exceeds eps.
// Returns null for an all-quiet response; sub-eps pre-ring must NOT be counted.
// ===========================================================================

test "measuredGroupDelay: an impulse at index 0 measures delay 0 (the first index)" {
    var ir = [_]f32{0.0} ** 16;
    ir[0] = 1.0;
    try testing.expectEqual(@as(?usize, 0), h.measuredGroupDelay(&ir, 1e-6));
}

test "measuredGroupDelay: an impulse at the LAST index measures that index (sweep includes the boundary)" {
    var ir = [_]f32{0.0} ** 16;
    ir[15] = 1.0;
    try testing.expectEqual(@as(?usize, 15), h.measuredGroupDelay(&ir, 1e-6));
}

test "measuredGroupDelay: a swept impulse position D is returned exactly for every interior D" {
    // Yoneda-style: characterize the map over its whole domain — every onset index.
    inline for (.{ 1, 2, 3, 5, 7, 11, 14 }) |D| {
        var ir = [_]f32{0.0} ** 16;
        ir[D] = 1.0;
        try testing.expectEqual(@as(?usize, D), h.measuredGroupDelay(&ir, 1e-6));
    }
}

test "measuredGroupDelay: an all-quiet (all-zero) response returns null" {
    const ir = [_]f32{0.0} ** 16;
    try testing.expectEqual(@as(?usize, null), h.measuredGroupDelay(&ir, 1e-6));
}

test "measuredGroupDelay: an empty response returns null (no sample can exceed eps)" {
    const ir = [_]f32{};
    try testing.expectEqual(@as(?usize, null), h.measuredGroupDelay(&ir, 1e-6));
}

test "measuredGroupDelay: a sub-eps pre-ring is IGNORED — onset is the first sample strictly above eps" {
    // Index 2 holds a tiny pre-ring at exactly eps (not strictly greater), index 5
    // is the true onset. eps is a strict lower bound (|s| > eps), so the pre-ring
    // at eps and the smaller ring before it are skipped; onset must be 5.
    const eps: f32 = 1e-3;
    var ir = [_]f32{0.0} ** 16;
    ir[1] = eps * 0.5; // below eps -> ignored
    ir[2] = eps; //       AT eps, not strictly above -> ignored (boundary is open)
    ir[5] = 1.0; //       the real onset
    try testing.expectEqual(@as(?usize, 5), h.measuredGroupDelay(&ir, eps));
}

test "measuredGroupDelay: magnitude is used, so a large NEGATIVE sample counts as onset" {
    var ir = [_]f32{0.0} ** 8;
    ir[3] = -0.9; // |−0.9| > eps -> onset at 3
    try testing.expectEqual(@as(?usize, 3), h.measuredGroupDelay(&ir, 1e-6));
}

test "measuredGroupDelay: a sample just ABOVE eps is counted (the strict boundary, from the other side)" {
    const eps: f32 = 1e-3;
    var ir = [_]f32{0.0} ** 8;
    ir[4] = std.math.nextAfter(f32, eps, std.math.inf(f32)); // smallest f32 > eps
    try testing.expect(ir[4] > eps);
    try testing.expectEqual(@as(?usize, 4), h.measuredGroupDelay(&ir, eps));
}

// ===========================================================================
// poisonNaN / anyNaN — the paranoid-mode poison + detection pair.
// ===========================================================================

test "poisonNaN then anyNaN: a poisoned buffer is flagged (the read-after-free trip wire fires)" {
    var buf = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    try testing.expect(!h.anyNaN(&buf)); // clean before poisoning
    h.poisonNaN(&buf);
    try testing.expect(h.anyNaN(&buf));
    // Every lane is poisoned, not just one.
    for (buf) |x| try testing.expect(std.math.isNan(x));
}

test "anyNaN: a clean finite buffer is NOT flagged (no false positive)" {
    const buf = [_]f32{ -1.0e30, 0.0, 1.0e30, 1.0 };
    try testing.expect(!h.anyNaN(&buf));
}

test "anyNaN: infinities are NOT NaN — only a NaN trips the detector" {
    const buf = [_]f32{ std.math.inf(f32), -std.math.inf(f32), 0.0 };
    try testing.expect(!h.anyNaN(&buf));
}

test "anyNaN: a single NaN among finite lanes is detected" {
    var buf = [_]f32{ 1.0, 2.0, 3.0 };
    buf[1] = std.math.nan(f32);
    try testing.expect(h.anyNaN(&buf));
}

test "anyNaN: an empty buffer holds no NaN" {
    const buf = [_]f32{};
    try testing.expect(!h.anyNaN(&buf));
}

// ===========================================================================
// Manifest.resolveTolerance — the {atol,rtol} vs {bit_exact} disambiguation.
// neither -> error.ToleranceMissing ; both -> error.ToleranceAmbiguous.
// ===========================================================================

fn manifestWith(tol: h.Manifest.ToleranceJson) h.Manifest {
    return .{
        .name = "t",
        .block = "B",
        .format = .{ .sample_rate = 48000, .precision = "f32", .channels = 1, .block_size = 256 },
        .out_per_in = "1:1",
        .algorithmic_latency = 0,
        .seed = 1,
        .n_frames = 4,
        .tolerance = tol,
    };
}

test "resolveTolerance: {atol,rtol} resolves to .approx carrying those exact values" {
    const m = manifestWith(.{ .atol = 1e-6, .rtol = 1e-5 });
    const tol = try m.resolveTolerance();
    try testing.expect(tol == .approx);
    try testing.expectEqual(@as(f64, 1e-6), tol.approx.atol);
    try testing.expectEqual(@as(f64, 1e-5), tol.approx.rtol);
}

test "resolveTolerance: a partial approx (only atol given) resolves to .approx with the missing field defaulted to 0" {
    const m = manifestWith(.{ .atol = 1e-4 });
    const tol = try m.resolveTolerance();
    try testing.expect(tol == .approx);
    try testing.expectEqual(@as(f64, 1e-4), tol.approx.atol);
    try testing.expectEqual(@as(f64, 0.0), tol.approx.rtol); // rtol omitted -> 0
}

test "resolveTolerance: only rtol given likewise resolves to .approx with atol defaulted to 0" {
    const m = manifestWith(.{ .rtol = 1e-5 });
    const tol = try m.resolveTolerance();
    try testing.expect(tol == .approx);
    try testing.expectEqual(@as(f64, 0.0), tol.approx.atol);
    try testing.expectEqual(@as(f64, 1e-5), tol.approx.rtol);
}

test "resolveTolerance: {bit_exact:true} resolves to .bit_exact" {
    const m = manifestWith(.{ .bit_exact = true });
    const tol = try m.resolveTolerance();
    try testing.expect(tol == .bit_exact);
}

test "resolveTolerance: bit_exact:false with NO approx fields is treated as 'no tolerance' -> ToleranceMissing" {
    // is_exact = (false orelse false) = false; is_approx = false -> neither.
    const m = manifestWith(.{ .bit_exact = false });
    try testing.expectError(error.ToleranceMissing, m.resolveTolerance());
}

test "resolveTolerance: declaring NEITHER shape is error.ToleranceMissing" {
    const m = manifestWith(.{});
    try testing.expectError(error.ToleranceMissing, m.resolveTolerance());
}

test "resolveTolerance: declaring BOTH shapes is error.ToleranceAmbiguous (bit_exact AND atol)" {
    const m = manifestWith(.{ .atol = 1e-6, .bit_exact = true });
    try testing.expectError(error.ToleranceAmbiguous, m.resolveTolerance());
}

test "resolveTolerance: BOTH via bit_exact + rtol is equally ambiguous (any approx field counts)" {
    const m = manifestWith(.{ .rtol = 1e-5, .bit_exact = true });
    try testing.expectError(error.ToleranceAmbiguous, m.resolveTolerance());
}

test "resolveTolerance: ambiguity outranks missing — bit_exact:false + atol present resolves to approx, not an error" {
    // is_exact=false, is_approx=true: a present atol with bit_exact explicitly
    // false is an unambiguous approx tolerance.
    const m = manifestWith(.{ .atol = 1e-6, .bit_exact = false });
    const tol = try m.resolveTolerance();
    try testing.expect(tol == .approx);
    try testing.expectEqual(@as(f64, 1e-6), tol.approx.atol);
}

// ===========================================================================
// parseManifest — parses the committed schema; unknown fields ignored; the
// returned Parsed must be deinit()-ed (leak-checked via testing.allocator).
// ===========================================================================

test "parseManifest: the committed full schema parses, every modelled field landing in the struct" {
    const json =
        \\{
        \\  "name": "gain_f32",
        \\  "block": "Gain",
        \\  "format": { "sample_rate": 48000, "precision": "f32", "channels": 1, "block_size": 256 },
        \\  "out_per_in": "1:1",
        \\  "algorithmic_latency": 0,
        \\  "tolerance": { "atol": 1e-6, "rtol": 1e-5 },
        \\  "seed": 1,
        \\  "n_frames": 1024
        \\}
    ;
    const parsed = try h.parseManifest(testing.allocator, json);
    defer parsed.deinit(); // strings borrow the arena; must be released
    const m = parsed.value;

    try testing.expectEqualStrings("gain_f32", m.name);
    try testing.expectEqualStrings("Gain", m.block);
    try testing.expectEqualStrings("f32", m.format.precision);
    try testing.expectEqual(@as(u32, 48000), m.format.sample_rate);
    try testing.expectEqual(@as(u16, 1), m.format.channels);
    try testing.expectEqual(@as(usize, 256), m.format.block_size);
    try testing.expectEqualStrings("1:1", m.out_per_in);
    try testing.expectEqual(@as(i64, 0), m.algorithmic_latency);
    try testing.expectEqual(@as(i64, 1), m.seed);
    try testing.expectEqual(@as(usize, 1024), m.n_frames);

    const tol = try m.resolveTolerance();
    try testing.expect(tol == .approx);
    try testing.expectEqual(@as(f64, 1e-6), tol.approx.atol);
    try testing.expectEqual(@as(f64, 1e-5), tol.approx.rtol);
}

test "parseManifest: unknown fields (params, in_ports, out_ports) are IGNORED, not rejected" {
    // The exact committed gain_f32.json shape, including the block-specific fields
    // the schema deliberately does not model. ignore_unknown_fields must drop them.
    const json =
        \\{
        \\  "name": "gain_f32",
        \\  "block": "Gain",
        \\  "params": { "gain_db": -6.0 },
        \\  "format": { "sample_rate": 48000, "precision": "f32", "channels": 1, "block_size": 256 },
        \\  "in_ports":  [{ "name": "in",  "element_type": "Sample(f32)" }],
        \\  "out_ports": [{ "name": "out", "element_type": "Sample(f32)" }],
        \\  "out_per_in": "1:1",
        \\  "algorithmic_latency": 0,
        \\  "tolerance": { "atol": 1e-6, "rtol": 1e-5 },
        \\  "seed": 1,
        \\  "n_frames": 1024
        \\}
    ;
    const parsed = try h.parseManifest(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("gain_f32", parsed.value.name);
    try testing.expectEqual(@as(usize, 1024), parsed.value.n_frames);
}

test "parseManifest: a bit_exact integer manifest parses and resolves to .bit_exact" {
    const json =
        \\{
        \\  "name": "gain_q15",
        \\  "block": "Gain",
        \\  "format": { "sample_rate": 48000, "precision": "q15", "channels": 1, "block_size": 256 },
        \\  "out_per_in": "1:1",
        \\  "algorithmic_latency": 0,
        \\  "tolerance": { "bit_exact": true },
        \\  "seed": 1,
        \\  "n_frames": 1024
        \\}
    ;
    const parsed = try h.parseManifest(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("q15", parsed.value.format.precision);
    const tol = try parsed.value.resolveTolerance();
    try testing.expect(tol == .bit_exact);
}

test "parseManifest: an omitted tolerance object defaults to all-null, and resolution then reports ToleranceMissing" {
    // `tolerance` has a default (.{}), so a manifest may omit it entirely and
    // still parse; the MISSING-ness surfaces at resolveTolerance, not at parse.
    const json =
        \\{
        \\  "name": "no_tol",
        \\  "block": "X",
        \\  "format": { "sample_rate": 48000, "precision": "f32", "channels": 1, "block_size": 256 },
        \\  "out_per_in": "1:1",
        \\  "algorithmic_latency": 0,
        \\  "seed": 1,
        \\  "n_frames": 4
        \\}
    ;
    const parsed = try h.parseManifest(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectError(error.ToleranceMissing, parsed.value.resolveTolerance());
}

test "parseManifest: a manifest declaring BOTH tolerance shapes parses but resolves to ToleranceAmbiguous" {
    const json =
        \\{
        \\  "name": "both",
        \\  "block": "X",
        \\  "format": { "sample_rate": 48000, "precision": "f32", "channels": 1, "block_size": 256 },
        \\  "out_per_in": "1:1",
        \\  "algorithmic_latency": 0,
        \\  "tolerance": { "atol": 1e-6, "bit_exact": true },
        \\  "seed": 1,
        \\  "n_frames": 4
        \\}
    ;
    const parsed = try h.parseManifest(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectError(error.ToleranceAmbiguous, parsed.value.resolveTolerance());
}

test "parseManifest: a missing REQUIRED field (no default) is a parse error" {
    // `name` has no default, so omitting it must fail the parse outright.
    const json =
        \\{
        \\  "block": "X",
        \\  "format": { "sample_rate": 48000, "precision": "f32", "channels": 1, "block_size": 256 },
        \\  "out_per_in": "1:1",
        \\  "algorithmic_latency": 0,
        \\  "tolerance": { "bit_exact": true },
        \\  "seed": 1,
        \\  "n_frames": 4
        \\}
    ;
    try testing.expectError(error.MissingField, h.parseManifest(testing.allocator, json));
}

test "parseManifest: a negative algorithmic_latency parses (the field is i64, signedness preserved)" {
    // The schema types algorithmic_latency as i64; a negative value must round-trip
    // (validation that it's non-negative happens elsewhere, not at parse).
    const json =
        \\{
        \\  "name": "neg",
        \\  "block": "X",
        \\  "format": { "sample_rate": 48000, "precision": "f32", "channels": 1, "block_size": 256 },
        \\  "out_per_in": "1:1",
        \\  "algorithmic_latency": -5,
        \\  "tolerance": { "bit_exact": true },
        \\  "seed": -42,
        \\  "n_frames": 4
        \\}
    ;
    const parsed = try h.parseManifest(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, -5), parsed.value.algorithmic_latency);
    try testing.expectEqual(@as(i64, -42), parsed.value.seed);
}

// ===========================================================================
// The load-bearing law, made executable: the SAME pan-vs-pan divergence that a
// float tolerance would forgive on the ORACLE path is a hard failure on the
// pan-vs-pan path. This is the whole point of the two-comparator design.
// ===========================================================================

test "THE LAW: a one-ULP divergence allclose forgives on the oracle path, bitExact rejects on the pan path" {
    const ref = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var got = ref;
    got[2] = std.math.nextAfter(f32, 3.0, std.math.inf(f32)); // one ULP off

    // Oracle path (≈ tier): allclose with a sane tolerance FORGIVES the ULP —
    // the oracle is allowed different arithmetic.
    try h.allcloseF32(&got, &ref, .{ .approx = .{ .atol = 1e-6, .rtol = 1e-5 } });

    // Pan-vs-pan path: the SAME buffers compared bit-exactly must FAIL. pan is
    // never allowed to disagree with itself, not even by one ULP.
    try testing.expectError(error.TestExpectedEqual, h.bitExact(f32, &got, &ref));
}

test "THE LAW (via Sample lane view): sampleValues lets the oracle comparator see a Sample(f32) buffer" {
    // The render drivers produce []Sample(f32); the oracle comparator wants
    // []const f32. sampleValues bridges them bit-identically. Pin that the bridge
    // preserves values so allclose sees exactly what was written.
    const n = 8;
    var frames: [n]pan.Sample(f32) = undefined;
    for (&frames, 0..) |*s, i| s.ch[0] = @floatFromInt(i);
    const values = h.sampleValues(&frames);
    try testing.expectEqual(@as(usize, n), values.len);
    var ref: [n]f32 = undefined;
    for (&ref, 0..) |*r, i| r.* = @floatFromInt(i);
    // Identical view -> passes allclose at zero tolerance AND bitExact.
    try h.allcloseF32(values, &ref, .{ .approx = .{ .atol = 0.0, .rtol = 0.0 } });
    try h.bitExact(f32, values, &ref);
}
