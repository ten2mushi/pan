//! Dual-mux — push vs pull agreement (catalog §4.2; testing spec §5.2).
//!
//! A block's observable behaviour IS its action on the buffers a mux presents.
//! By the representability (Yoneda) argument, a block is determined by its action
//! under the family of muxes — so running every block under BOTH push
//! (`TestSampleMux`) and pull (`PullTestSampleMux`) is the structural check that
//! its behaviour is mux-independent. A surface leak between the two
//! interpretations shows up here as a divergence.
//!
//! COMPARISON MODE: bit-exact (pan-vs-pan — the same machine code under a
//! different mux), aligned by the declared algorithmic_latency. Tolerance never
//! applies: a float "almost match" is a failure. Verified against zig 0.16.0;
//! the zig-0-16 skill was loaded before authoring (Rule 13/14).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

fn pushPullAgree(comptime Block: type, mk: *const fn () Block, n: usize, chunk: usize, seed: u64) !void {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(input);
    const out_push = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(out_push);
    const out_pull = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(out_pull);

    h.fillNoise(input, seed);

    var bp = mk();
    h.renderPush(Block, &bp, input, out_push, chunk);
    var bq = mk();
    h.renderPull(Block, &bq, input, out_pull, chunk);

    // algorithmic_latency == 0 for these Map blocks: full overlap, bit-exact.
    try h.alignByLatency(f32, h.sampleValues(out_push), h.sampleValues(out_pull), 0);
}

fn mkIdentity() h.Identity {
    return .{};
}
fn mkScale() h.Scale {
    return .{ .k = 0.5 };
}

test "dual-mux: identity push ≡ pull, bit-exact (catalog §4.2, ≈ R4)" {
    try pushPullAgree(h.Identity, mkIdentity, 1024, 256, 11);
}

test "dual-mux: aliasing-safe scale push ≡ pull, bit-exact (catalog §4.2)" {
    try pushPullAgree(h.Scale, mkScale, 1024, 256, 12);
}

test "dual-mux: agreement is independent of chunk size (sub-block invariance)" {
    // Different chunkings of the pull stream must still agree with push — the
    // mux-independence claim is not an artefact of one block size.
    try pushPullAgree(h.Identity, mkIdentity, 1000, 1, 13); // sample-at-a-time pull
    try pushPullAgree(h.Identity, mkIdentity, 1000, 333, 13); // ragged chunk (H∤N)
    try pushPullAgree(h.Scale, mkScale, 1000, 999, 14);
}
