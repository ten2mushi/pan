//! varirate_gold_test — the EXTERNAL-ORACLE (≈) gold check for the arbitrary-ratio
//! `Varispeed` resampler, against the NumPy reference computed by
//! `scripts/generate.py` (the independent external truth — it tests the kernel, it
//! never defines it). A float oracle is compared with `allclose`
//! (|pan − ref| ≤ atol + rtol·|ref|): the tolerance forgives the f32-vs-f64
//! arithmetic gap (the final interpolation is done in f32 in pan, f64 in the oracle)
//! while keeping the oracle genuinely independent.
//!
//! Unlike a control SOURCE, `Varispeed` consumes an INPUT stream, so the gold loads
//! BOTH the generated `input.bin` (the exact samples the oracle resampled) and
//! `expected.bin` (the resampled result), renders `Varispeed` over that input at the
//! manifest's ratio, and allclose-compares.
//!
//! The blobs are generate-on-demand and git-ignored, so a missing blob is a graceful
//! skip, never a hard failure — run
//! `python3 scripts/generate.py tests/vectors/varispeed_f32.json` to materialize them.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.Sample;
const f32num = pan.numericFor(.f32, .{});
const VS = pan.Varispeed(f32num);

const manifest_json = @embedFile("vectors/varispeed_f32.json");

fn readBlobOrNull(io: std.Io, gpa: std.mem.Allocator, sub_path: []const u8) !?[]align(4) u8 {
    const dir = std.Io.Dir.cwd();
    return dir.readFileAllocOptions(io, sub_path, gpa, .unlimited, .@"4", null) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

fn jsonF32(v: std.json.Value) f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => unreachable,
    };
}

test "GoldVector: Varispeed(f32) ≡ the NumPy linear-resampler oracle blob, allclose" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const in_bytes = (try readBlobOrNull(io, gpa, "tests/vectors/varispeed_f32/input.bin")) orelse {
        std.debug.print("skip: varispeed_f32 input blob absent — run scripts/generate.py tests/vectors/varispeed_f32.json\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(in_bytes);
    const exp_bytes = (try readBlobOrNull(io, gpa, "tests/vectors/varispeed_f32/expected.bin")) orelse {
        std.debug.print("skip: varispeed_f32 expected blob absent — run scripts/generate.py tests/vectors/varispeed_f32.json\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(exp_bytes);

    // Mono `Sample(f32)` is layout-identical to a bare f32, so the input blob (a
    // plane-major mono f32 stream) views directly as a `Sample(f32)` slice.
    const input: []const Sample(f32) = @alignCast(std.mem.bytesAsSlice(Sample(f32), in_bytes));
    const expected: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, exp_bytes));

    // Read the SAME ratio the oracle used, from the committed manifest.
    const dyn = try std.json.parseFromSlice(std.json.Value, gpa, manifest_json, .{});
    defer dyn.deinit();
    const root = dyn.value.object;
    const ratio = jsonF32(root.get("params").?.object.get("ratio").?);

    var vs = VS{};
    vs.setParam(0, ratio);
    // Headroom for up to 4× upsampling plus slack; pull produces until input exhausted.
    const out = try gpa.alloc(Sample(f32), input.len * 5 + 8);
    defer gpa.free(out);
    const produced = vs.pull(input, out.len, out);

    try std.testing.expectEqual(expected.len, produced);
    const tol = h.Tolerance{ .approx = .{ .atol = 1e-6, .rtol = 1e-5 } };
    try h.allcloseF32(h.sampleValues(out[0..produced]), expected, tol);
}
