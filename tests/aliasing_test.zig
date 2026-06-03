//! Aliasing — in-place vs non-aliased (catalog §7.4 / §2.1 M4; testing spec §5.4).
//!
//! In-place coalescing lets the colorer hand a block the SAME buffer as both its
//! input and output. For a block declaring `aliasing_safe = true`, that must be a
//! no-op on values: the aliased render and the non-aliased render must agree
//! bit-for-bit. A divergence is a FALSE aliasing_safe claim — the failure-message
//! contract (name the assertion, the first divergent sample, the fix) applies.
//!
//! COMPARISON MODE: bit-exact (pan-vs-pan). Verified against zig 0.16.0; the
//! zig-0-16 skill was loaded before authoring (Rule 13/14).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

test "aliasing: an aliasing_safe scale agrees in-place and out-of-place, bit-exact (catalog §7.4)" {
    // Only a block that declares aliasing_safe may take the in-place path.
    comptime std.debug.assert(@hasDecl(h.Scale, "aliasing_safe") and h.Scale.aliasing_safe);

    const n = 1024;
    const gpa = std.testing.allocator;

    const input = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(input);
    h.fillNoise(input, 31);

    // Non-aliased: separate input/output buffers.
    const out_disjoint = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(out_disjoint);
    var blk_a = h.Scale{ .k = 0.25 };
    h.renderPush(h.Scale, &blk_a, input, out_disjoint, 256);

    // Aliased: one shared buffer (in == out). Seed it with the input, then
    // render in place through the mux seam.
    const shared = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(shared);
    @memcpy(shared, input);
    var blk_b = h.Scale{ .k = 0.25 };
    h.renderAliased(h.Scale, &blk_b, shared);

    // Pan-vs-pan with the aliasing_safe quote-back contract: an agreement passes;
    // were Scale a false aliasing_safe claim, the divergence would quote the
    // assertion back, name the first divergent sample, and state the fix.
    try h.expectPanVsPan(h.Scale, h.sampleValues(out_disjoint), h.sampleValues(shared), "non-aliased", "aliased in-place");
}

test "aliasing: identity in-place is also a no-op on values (sanity)" {
    // The identity block, though authored with @memcpy (not aliasing_safe), is
    // value-stable in place because copying a buffer onto itself elementwise is a
    // no-op — a sanity anchor for the aliased driver itself.
    const n = 512;
    const gpa = std.testing.allocator;

    const input = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(input);
    h.fillNoise(input, 32);

    const shared = try gpa.alloc(pan.Sample(f32), n);
    defer gpa.free(shared);
    @memcpy(shared, input);

    // A degenerate scale of k=1 is the identity, and IS aliasing_safe.
    var blk = h.Scale{ .k = 1.0 };
    h.renderAliased(h.Scale, &blk, shared);

    try h.expectPanVsPan(h.Scale, h.sampleValues(input), h.sampleValues(shared), "input", "in-place k=1");
}
