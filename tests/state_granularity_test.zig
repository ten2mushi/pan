//! State-granularity — full-block vs sub-block render (catalog §2.1 M2; testing
//! spec §5.6).
//!
//! The sub-block homomorphism M2 says "splitting a render call is free": rendering
//! N frames in one call must produce the IDENTICAL sample stream — and the
//! identical post-render state — as rendering them in two calls of k and N−k
//! frames through the same block instance. This is exactly the property the
//! sample-accurate event lane relies on (a note onset lands mid-block by splitting
//! the render at the onset).
//!
//! The block under test is a STATEFUL accumulator: its end-state depends on every
//! prior sample, so a split that failed to carry state would diverge — the test
//! can actually fail when the state logic is wrong (Rule 9). A stateless block
//! would pass this harness vacuously.
//!
//! COMPARISON MODE: bit-exact output stream AND identical end-state (pan-vs-pan).
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded (Rule 13/14).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

fn fullVsSplit(n: usize, k: usize, seed: u64) !void {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(input);
    h.fillNoise(input, seed);

    // Full: one render of all N frames.
    const out_full = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(out_full);
    var blk_full = h.Accumulator{};
    blk_full.process(input, out_full);

    // Split: two renders, k then N−k, through the SAME instance (state carries).
    const out_split = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(out_split);
    var blk_split = h.Accumulator{};
    blk_split.process(input[0..k], out_split[0..k]);
    blk_split.process(input[k..], out_split[k..]);

    // The whole stream is bit-identical...
    try h.bitExact(f32, h.sampleValues(out_full), h.sampleValues(out_split));
    // ...and so is the post-render state (the Mealy end-state homomorphism).
    try std.testing.expectEqual(blk_full.acc, blk_split.acc);
}

test "state-granularity: full ≡ k + (N−k) for a stateful block, bit-exact (catalog §2.1 M2)" {
    try fullVsSplit(1024, 512, 41); // even split
    try fullVsSplit(1024, 1, 41); // degenerate: 1 + 1023
    try fullVsSplit(1024, 1023, 41); // degenerate: 1023 + 1
    try fullVsSplit(1000, 333, 42); // ragged split (H∤N)
}

test "state-granularity: a third split point is still bit-identical (associativity)" {
    // Splitting into three pieces must equal the single render — the homomorphism
    // composes, so the partition is invisible regardless of how it is cut.
    const n = 900;
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(input);
    h.fillNoise(input, 43);

    const out_full = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(out_full);
    var bf = h.Accumulator{};
    bf.process(input, out_full);

    const out_thirds = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(out_thirds);
    var bt = h.Accumulator{};
    bt.process(input[0..300], out_thirds[0..300]);
    bt.process(input[300..600], out_thirds[300..600]);
    bt.process(input[600..], out_thirds[600..]);

    try h.bitExact(f32, h.sampleValues(out_full), h.sampleValues(out_thirds));
    try std.testing.expectEqual(bf.acc, bt.acc);
}
