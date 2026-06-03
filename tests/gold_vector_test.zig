//! GoldVectorTester — the external-oracle harness (catalog §4.2; testing spec
//! §5.1). Drives a block under `TestSampleMux` (push) and compares the output to
//! an independent reference under the manifest's tolerance: numpy.allclose for a
//! float lane, bit-exact for an integer/fixed-point lane.
//!
//! At this phase the DSP blocks and their generated blobs do not exist yet, so
//! this driver does two hermetic things: (1) it validates the committed manifest
//! parses against the locked schema (the contract half of the generate-on-demand
//! policy), and (2) it runs the identity block through the push mux against a
//! synthetic in-test oracle, exercising the full chunked-render + comparator
//! path that the real gold vectors will reuse unchanged.
//!
//! COMPARISON MODE: tolerance (allclose) for the float oracle path; bit-exact
//! for an integer manifest. Verified against zig 0.16.0; the zig-0-16 skill was
//! loaded before authoring (Rule 13/14).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const gain_f32_json = @embedFile("vectors/gain_f32.json");
const gain_q15_json = @embedFile("vectors/gain_q15.json");

test "manifest schema: gain_f32.json parses and resolves a float tolerance (catalog §4 / spec §4)" {
    const parsed = try h.parseManifest(std.testing.allocator, gain_f32_json);
    defer parsed.deinit();
    const m = parsed.value;

    try std.testing.expectEqualStrings("gain_f32", m.name);
    try std.testing.expectEqualStrings("Gain", m.block);
    try std.testing.expectEqualStrings("f32", m.format.precision);
    try std.testing.expectEqual(@as(u32, 48000), m.format.sample_rate);
    try std.testing.expectEqual(@as(u16, 1), m.format.channels);
    try std.testing.expectEqual(@as(i64, 0), m.algorithmic_latency);
    try std.testing.expectEqualStrings("1:1", m.out_per_in);

    const tol = try m.resolveTolerance();
    try std.testing.expect(tol == .approx);
    try std.testing.expect(tol.approx.atol > 0);
}

test "manifest schema: the q15 sibling resolves a bit-exact tolerance (spec §1.3 / §4.1)" {
    const parsed = try h.parseManifest(std.testing.allocator, gain_q15_json);
    defer parsed.deinit();
    const m = parsed.value;
    try std.testing.expectEqualStrings("q15", m.format.precision);
    const tol = try m.resolveTolerance();
    try std.testing.expect(tol == .bit_exact);
}

test "a manifest declaring neither tolerance shape is rejected (spec §4)" {
    const bad =
        \\{ "name":"x","block":"X",
        \\  "format":{"sample_rate":48000,"precision":"f32","channels":1,"block_size":256},
        \\  "out_per_in":"1:1","algorithmic_latency":0,"seed":1,"n_frames":4,
        \\  "tolerance":{} }
    ;
    const parsed = try h.parseManifest(std.testing.allocator, bad);
    defer parsed.deinit();
    try std.testing.expectError(error.ToleranceMissing, parsed.value.resolveTolerance());
}

test "GoldVector: identity ≡ synthetic float oracle through the push mux, allclose (spec §5.1)" {
    const n = 1024;
    var input: [n]pan.Sample(f32) = undefined;
    var output: [n]pan.Sample(f32) = undefined;
    h.fillNoise(&input, 1);

    // The independent oracle for the identity block is the input itself.
    var oracle: [n]pan.Sample(f32) = undefined;
    @memcpy(&oracle, &input);

    var blk = h.Identity{};
    h.renderPush(h.Identity, &blk, &input, &output, 256);

    const tol = h.Tolerance{ .approx = .{ .atol = 1e-6, .rtol = 1e-5 } };
    try h.allcloseF32(h.sampleValues(&output), h.sampleValues(&oracle), tol);
}

test "GoldVector: a float lane may also be checked bit-exact when pan==oracle byte-for-byte (spec §1)" {
    // The identity block is a pure copy, so its output is byte-identical to the
    // oracle — a stronger statement than allclose, valid because no arithmetic
    // rounding intervenes. (Real DSP blocks use allclose; this records that the
    // bit-exact comparator is wired and green.)
    const n = 256;
    var input: [n]pan.Sample(f32) = undefined;
    var output: [n]pan.Sample(f32) = undefined;
    h.fillNoise(&input, 7);
    var blk = h.Identity{};
    h.renderPush(h.Identity, &blk, &input, &output, 64);
    try h.bitExact(f32, h.sampleValues(&output), h.sampleValues(&input));
}
