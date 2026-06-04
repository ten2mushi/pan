//! modulation_gold_test — the EXTERNAL-ORACLE (≈) gold check for the control
//! generators `Lfo` and `Adsr`, against the NumPy reference computed by
//! `scripts/generate.py` (the independent external truth — it tests the kernels, it
//! never defines them). A float oracle is compared with `allclose` (|pan − ref| ≤
//! atol + rtol·|ref|): the tolerance forgives the f32-vs-f64 arithmetic gap (e.g. a
//! 1-ULP difference between Zig's `@sin` and NumPy's `sin`) while keeping the oracle
//! genuinely independent.
//!
//! Both blocks are control-rate SOURCES emitting one `Scalar(f32)` per render call;
//! the gold renders them block by block and collects the per-block control value
//! into a flat sequence, which is exactly the NumPy reference's per-sample form
//! (the block-start value broadcast across each block).
//!
//! The `expected.bin` blobs are generate-on-demand and git-ignored, so a missing
//! blob is a graceful skip, never a hard failure — run
//! `python3 scripts/generate.py tests/vectors/lfo_f32.json` (and `adsr_f32.json`)
//! to materialize them.
//!
//! Verified against zig 0.16.0.

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const lfo_json = @embedFile("vectors/lfo_f32.json");
const adsr_json = @embedFile("vectors/adsr_f32.json");

/// Read a cwd-relative blob, f32-aligned; `null` on FileNotFound (the
/// generate-on-demand skip), other I/O errors propagate.
fn readBlobOrNull(io: std.Io, gpa: std.mem.Allocator, sub_path: []const u8) !?[]align(4) u8 {
    const dir = std.Io.Dir.cwd();
    return dir.readFileAllocOptions(io, sub_path, gpa, .unlimited, .@"4", null) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

/// Coerce a JSON number (int or float) to f32 — manifest authors may write `1` or `1.0`.
fn jsonF32(v: std.json.Value) f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => unreachable,
    };
}

test "GoldVector: Lfo(f32) ≡ the NumPy LFO oracle blob, allclose" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const exp_bytes = (try readBlobOrNull(io, gpa, "tests/vectors/lfo_f32/expected.bin")) orelse {
        std.debug.print("skip: lfo_f32 expected blob absent — run scripts/generate.py tests/vectors/lfo_f32.json\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(exp_bytes);
    const expected: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, exp_bytes));

    // Read the SAME params the oracle used, from the committed manifest.
    const dyn = try std.json.parseFromSlice(std.json.Value, gpa, lfo_json, .{});
    defer dyn.deinit();
    const root = dyn.value.object;
    const p = root.get("params").?.object;
    const n_frames: usize = @intCast(root.get("n_frames").?.integer);
    const blk: usize = @intCast(p.get("block_size").?.integer);
    const wf_str = p.get("waveform").?.string;
    const wf: pan.gen.Waveform =
        if (std.mem.eql(u8, wf_str, "sine")) .sine else if (std.mem.eql(u8, wf_str, "triangle")) .triangle else if (std.mem.eql(u8, wf_str, "saw")) .saw else .square;

    var lfo = pan.gen.Lfo{
        .increment = jsonF32(p.get("increment").?),
        .amplitude = jsonF32(p.get("amplitude").?),
        .offset = jsonF32(p.get("offset").?),
        .waveform = wf,
    };

    const got = try gpa.alloc(f32, n_frames);
    defer gpa.free(got);
    const block = try gpa.alloc(pan.Scalar(f32), blk);
    defer gpa.free(block);

    var k: usize = 0;
    while ((k + 1) * blk <= n_frames) : (k += 1) {
        lfo.process(block);
        for (0..blk) |i| got[k * blk + i] = block[i].value;
    }

    const tol = h.Tolerance{ .approx = .{ .atol = 1e-6, .rtol = 1e-5 } };
    try h.allcloseF32(got, expected, tol);
}

test "GoldVector: Adsr(f32) ≡ the NumPy ADSR oracle blob, allclose" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const exp_bytes = (try readBlobOrNull(io, gpa, "tests/vectors/adsr_f32/expected.bin")) orelse {
        std.debug.print("skip: adsr_f32 expected blob absent — run scripts/generate.py tests/vectors/adsr_f32.json\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(exp_bytes);
    const expected: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, exp_bytes));

    const dyn = try std.json.parseFromSlice(std.json.Value, gpa, adsr_json, .{});
    defer dyn.deinit();
    const root = dyn.value.object;
    const p = root.get("params").?.object;
    const n_frames: usize = @intCast(root.get("n_frames").?.integer);
    const blk: usize = @intCast(p.get("block_size").?.integer);
    const gate_on: usize = @intCast(p.get("gate_on_blocks").?.integer);

    var adsr = pan.env.Adsr{
        .attack_inc = jsonF32(p.get("attack_inc").?),
        .decay_inc = jsonF32(p.get("decay_inc").?),
        .sustain = jsonF32(p.get("sustain").?),
        .release_inc = jsonF32(p.get("release_inc").?),
    };

    const got = try gpa.alloc(f32, n_frames);
    defer gpa.free(got);
    const block = try gpa.alloc(pan.Scalar(f32), blk);
    defer gpa.free(block);

    const n_blocks = n_frames / blk;
    var k: usize = 0;
    while (k < n_blocks) : (k += 1) {
        adsr.setParam(0, if (k < gate_on) @as(f32, 1.0) else 0.0); // gate held, then released
        adsr.process(block);
        for (0..blk) |i| got[k * blk + i] = block[i].value;
    }

    const tol = h.Tolerance{ .approx = .{ .atol = 1e-5, .rtol = 1e-5 } };
    try h.allcloseF32(got, expected, tol);
}
