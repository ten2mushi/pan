//! B≡C differential — colorer correctness (catalog §7.5; testing spec §5.3).
//!
//! The buffer colorer (Mode C: a single colored pool) is a pure storage
//! remapping of Mode B (one private double-buffer per edge). It must change
//! NOTHING observable — so the two pool modes, run on identical kernels and
//! inputs, must produce bit-identical output. Any float drift between them is the
//! colorer corrupting data, never numerics; this is the PRIMARY correctness check
//! for the colorer's implementation (empirical evidence, not a proof).
//!
//! Phase note: the colored pool (Mode C) lands later; this driver stands up the
//! Mode-B BASELINE (two independent per-edge renders, which must already agree
//! bit-for-bit) and the PARANOID NaN-poison mechanism, so the later phase only
//! swaps Mode C in behind the same comparison. The poison test proves the
//! mechanism flags a stale read rather than passing on a plausible value.
//!
//! COMPARISON MODE: bit-exact (pan-vs-pan) + paranoid NaN in Debug/ReleaseSafe.
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded (Rule 13/14).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");
const builtin = @import("builtin");

/// Paranoid mode is active in the safe build modes (asserts + guards on); it is
/// compiled out in the release-fast / release-small builds.
const paranoid = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

test "B≡C baseline: per-edge buffers ≡ per-edge buffers, bit-exact (catalog §7.5)" {
    // Until the colored pool exists, both "modes" are Mode B — the baseline the
    // differential is anchored to. They must already be bit-identical.
    const n = 1024;
    const gpa = std.testing.allocator;

    const input = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(input);
    h.fillNoise(input, 21);

    // Mode B render #1 — its own edge buffer.
    const edge_b1 = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(edge_b1);
    var blk1 = h.Scale{ .k = 0.75 };
    h.renderPush(h.Scale, &blk1, input, edge_b1, 128);

    // Mode B render #2 — a DISTINCT edge buffer, same kernel and input.
    const edge_b2 = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(edge_b2);
    var blk2 = h.Scale{ .k = 0.75 };
    h.renderPush(h.Scale, &blk2, input, edge_b2, 128);

    // Scale is aliasing_safe, so route the differential through the quote-back
    // comparator: agreement passes; a colorer that corrupted data would trip the
    // falsified-contract message (the §7.6 contract that mode C plugs into at P7).
    try h.expectPanVsPan(h.Scale, h.sampleValues(edge_b1), h.sampleValues(edge_b2), "mode B (buffer 1)", "mode B (buffer 2)");
}

test "paranoid mode: a poisoned (released) buffer reads back as NaN (catalog §7.5)" {
    if (!paranoid) return; // poison guards are compiled out in release-fast

    const n = 64;
    var buf: [n]f32 = undefined;
    for (&buf, 0..) |*x, i| x.* = @floatFromInt(i);
    try std.testing.expect(!h.anyNaN(&buf));

    // Releasing a pool buffer poisons it; a subsequent read-after-free surfaces
    // as a divergence (NaN) rather than a stale-but-plausible value.
    h.poisonNaN(&buf);
    try std.testing.expect(h.anyNaN(&buf));
}

test "paranoid poison does not survive a legitimate overwrite (no false positive)" {
    if (!paranoid) return;

    const n = 256;
    const gpa = std.testing.allocator;
    const scratch = try gpa.alloc(f32, n);
    defer gpa.free(scratch);

    h.poisonNaN(scratch); // pretend this buffer was just released back to the pool
    try std.testing.expect(h.anyNaN(scratch));

    // A fresh producer fully overwrites it before any reader runs — the legal
    // reuse path. No NaN must leak into the result.
    for (scratch) |*x| x.* = 1.0;
    try std.testing.expect(!h.anyNaN(scratch));
}
