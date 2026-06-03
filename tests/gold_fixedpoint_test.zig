//! Fixed-point gold vector — the bit-exact half of the comparison contract.
//!
//! A float lane compares under numpy.allclose (the oracle's f64 arithmetic
//! differs from pan's f32); an INTEGER / fixed-point lane compares **bit-exact**.
//! This harness runs the real `Gain(q15)` kernel over the committed `gain_q15`
//! vector's input codes and asserts the output equals the oracle's `expected.bin`
//! to the bit. The oracle (`scripts/generate.py`) implements the SAME spec-defined
//! q15 multiply (`qMulStore`: rounded, arithmetic-shifted, saturated) in NumPy —
//! an independent implementation of the same integer arithmetic, which is exactly
//! what "bit-exact for fixed-point" means.
//!
//! To keep the bit-exactness robust, the manifest carries the already-quantized
//! integer coefficient `gain_q` (the value the kernel's `gain` field holds), so no
//! transcendental (`10^(db/20)`) enters the comparison — a 1-ULP f32-vs-f64
//! difference there would otherwise shift every output sample.
//!
//! The `expected.bin`/`input.bin` blobs are generate-on-demand and git-ignored, so
//! a missing blob is a graceful skip, never a hard failure (run
//! `python3 scripts/generate.py tests/vectors/gain_q15.json` to materialize them).
//! Verified against zig 0.16.0 with the zig-0-16 skill loaded.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const gain_q15_json = @embedFile("vectors/gain_q15.json");
const pan_q15_json = @embedFile("vectors/pan_q15.json");
const num_q15 = pan.numericFor(.i16, .{});
const SampleQ15 = pan.types.Sample(i16);

/// Read a cwd-relative blob, i16-aligned; `null` on FileNotFound (the
/// generate-on-demand skip), other I/O errors propagate.
fn readBlobOrNull(io: std.Io, gpa: std.mem.Allocator, sub_path: []const u8) !?[]align(2) u8 {
    const dir = std.Io.Dir.cwd();
    return dir.readFileAllocOptions(io, sub_path, gpa, .unlimited, .@"2", null) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

test "manifest schema: gain_q15.json carries the integer coeff + a bit-exact tolerance" {
    const parsed = try h.parseManifest(std.testing.allocator, gain_q15_json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("q15", parsed.value.format.precision);
    try std.testing.expect((try parsed.value.resolveTolerance()) == .bit_exact);
}

test "GoldVector: Gain(q15) ≡ the NumPy fixed-point oracle blob, BIT-EXACT (catalog §1.3 / §4.1)" {
    const gpa = std.testing.allocator;

    // The integer coefficient the kernel holds, read from the committed manifest
    // (the same value the oracle used) — no transcendental in the comparison.
    const gain_q: i16 = blk: {
        const dyn = try std.json.parseFromSlice(std.json.Value, gpa, gain_q15_json, .{});
        defer dyn.deinit();
        const params = dyn.value.object.get("params").?.object;
        break :blk @intCast(params.get("gain_q").?.integer);
    };
    try std.testing.expectEqual(@as(i16, 16423), gain_q); // matches the committed manifest

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const in_bytes = (try readBlobOrNull(io, gpa, "tests/vectors/gain_q15/input.bin")) orelse {
        std.debug.print("skip: gain_q15 blobs absent — run scripts/generate.py to materialize them\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(in_bytes);
    const exp_bytes = (try readBlobOrNull(io, gpa, "tests/vectors/gain_q15/expected.bin")) orelse {
        std.debug.print("skip: gain_q15 expected blob absent\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(exp_bytes);

    const input: []const SampleQ15 = @alignCast(std.mem.bytesAsSlice(SampleQ15, in_bytes));
    const expected: []const i16 = @alignCast(std.mem.bytesAsSlice(i16, exp_bytes));

    const out = try gpa.alloc(SampleQ15, input.len);
    defer gpa.free(out);

    // Gain is stateless, so a single whole-buffer render equals any chunking.
    var gain = pan.filters.Gain(num_q15){ .gain = gain_q };
    gain.process(input, out);

    const got: []const i16 = @alignCast(std.mem.bytesAsSlice(i16, std.mem.sliceAsBytes(out)));
    try h.bitExact(i16, got, expected);
}

test "GoldVector: ConstantPowerPan(q15) ≡ the NumPy fixed-point oracle blob, BIT-EXACT (catalog §1.3)" {
    const gpa = std.testing.allocator;

    // Pre-quantized constant-power gains from the committed manifest (the same
    // integers the oracle used) — no transcendental in the comparison.
    const lq: i16, const rq: i16 = blk: {
        const dyn = try std.json.parseFromSlice(std.json.Value, gpa, pan_q15_json, .{});
        defer dyn.deinit();
        const params = dyn.value.object.get("params").?.object;
        break :blk .{ @intCast(params.get("pan_lq").?.integer), @intCast(params.get("pan_rq").?.integer) };
    };
    try std.testing.expectEqual(@as(i16, 18205), lq);
    try std.testing.expectEqual(@as(i16, 27246), rq);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const in_bytes = (try readBlobOrNull(io, gpa, "tests/vectors/pan_q15/input.bin")) orelse {
        std.debug.print("skip: pan_q15 blobs absent — run scripts/generate.py to materialize them\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(in_bytes);
    const exp_bytes = (try readBlobOrNull(io, gpa, "tests/vectors/pan_q15/expected.bin")) orelse {
        std.debug.print("skip: pan_q15 expected blob absent\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(exp_bytes);

    const input: []const SampleQ15 = @alignCast(std.mem.bytesAsSlice(SampleQ15, in_bytes));
    const expected: []const i16 = @alignCast(std.mem.bytesAsSlice(i16, exp_bytes));
    const n = input.len;

    // pan renders into a PLANE-MAJOR q15 stereo buffer ([L-plane(n)][R-plane(n)]).
    const out_lanes = try gpa.alloc(i16, 2 * n);
    defer gpa.free(out_lanes);
    const out = pan.Planar(i16, .stereo).fromBase(out_lanes.ptr, n);

    // Drive the q15 pan with the EXACT integer gains (the embedded / bit-exact
    // path), not a runtime cos. Pan is stateless → a whole-buffer render suffices.
    var panner = pan.spatial.ConstantPowerPan(num_q15){ .gains_q = .{ lq, rq } };
    panner.process(input, out);

    // The planar output is [L-plane][R-plane] — exactly the oracle's plane-major
    // q15 layout (the generator emits plane-major for C>1). Bit-exact.
    const got: []const i16 = out_lanes;
    try h.bitExact(i16, got, expected);
}
