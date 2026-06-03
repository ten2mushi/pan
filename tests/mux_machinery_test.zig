//! Mux machinery — the `SampleMux` seam as the *only* block↔transport coupling
//! (catalog §4: the mux laws; testing spec §0.5 comparison contract).
//!
//! By the representability (Yoneda) argument the catalog leans on, a block is
//! determined by its action under the *family* of muxes: the mux is the sole
//! channel through which bytes reach a block and leave it. These tests are the
//! operational definition of that seam. They characterize each of the four
//! `SampleMux` realizations against the laws the catalog pins:
//!
//!   1. ROUND-TRIP. Bytes written into the output buffer obtained from a mux
//!      come back out *exactly* through `getOutputBuffer`/`getInputBuffer`,
//!      regardless of realization. A block driven through any mux observes
//!      identical bytes — the seam is transparent.
//!   2. CURSOR MONOTONICITY (pull/ring). Repeated `update*(n)` drains
//!      availability monotonically to *exactly* 0; the post-advance buffer is
//!      the correctly offset sub-slice; the driver loop never over-reads.
//!   3. PUSH NO-OP COMMIT (`TestSampleMux`). Whole buffers are exposed and
//!      `update*` does NOT change availability — the structural difference from
//!      pull that the dual-mux probe exists to expose.
//!   4. SYNCHRONOUS PULL (`PullSampleMux`). `wait*` are immediate, `update*`
//!      are no-ops, buffers are the assigned pool arena.
//!   5. SIDE CHANNELS. `setEOS` sets the `eos` flag on muxes carrying one;
//!      `getNumReadersForOutput` reports the fan-out count (1 here).
//!   6. TYPED MULTI-CHUNK DRIVE. The element type is erased to `[]u8` at the
//!      seam; a typed wrapper recovers `[]Sample(f32)`. An identity copy driven
//!      chunk-by-chunk through the vtable reproduces the input exactly, across
//!      several chunk sizes including 1 and a size that does not divide the
//!      total (H∤N).
//!
//! COMPARISON MODE: bit-exact only (pan-vs-pan / structural — testing spec
//! §0.5). Byte streams are compared with `expectEqualSlices`; availability and
//! cursor counts with exact integer equality. Tolerance NEVER applies at this
//! seam — a near match is a failure. Verified against zig 0.16.0; the zig-0-16
//! skill was loaded before authoring (Rule 13/14).

const std = @import("std");
const pan = @import("pan");

const testing = std.testing;
const Sample = pan.Sample;

// --- byte-seam helpers (the seam erases the element type to `[]u8`) ---------

/// View a `[]T` as the raw bytes the seam traffics in. The mux never sees `T`.
fn bytesOf(comptime T: type, items: []T) []u8 {
    return std.mem.sliceAsBytes(items);
}
fn bytesOfConst(comptime T: type, items: []const T) []const u8 {
    return std.mem.sliceAsBytes(items);
}
/// Recover a typed slice from seam bytes. `bytesAsSlice` yields an under-aligned
/// slice; `@alignCast` restores it — sound because the bytes originate from an
/// aligned `T` array (the slices below all come from aligned `Sample` arrays).
fn samplesOf(comptime T: type, bytes: []u8) []T {
    return @alignCast(std.mem.bytesAsSlice(T, bytes));
}
fn samplesOfConst(comptime T: type, bytes: []const u8) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, bytes));
}

/// Deterministic byte ramp — a distinct value per index so a misordered or
/// offset copy cannot accidentally match. (xor 0x5a breaks the trivial identity
/// pattern so an off-by-one in a cursor offset is visible.)
fn fillRamp(buf: []u8, seed: u8) void {
    for (buf, 0..) |*b, i| b.* = @as(u8, @truncate(i)) ^ seed;
}

const esz = @sizeOf(Sample(f32));

// ===========================================================================
// LAW 1 — ROUND-TRIP: the seam is byte-transparent for every realization.
//
// Bytes written into the output buffer obtained from the mux must reappear,
// byte-for-byte, through the input buffer of an identity copy. Pinned for all
// four realizations in a single whole-buffer commit so the four are shown to
// agree on the transparent-copy contract.
// ===========================================================================

test "TestSampleMux: output bytes round-trip the seam exactly (catalog §4 round-trip)" {
    var in = [_]u8{0} ** 32;
    var out = [_]u8{0xff} ** 32;
    fillRamp(&in, 0x5a);

    var tm = pan.TestSampleMux{ .input = &in, .output = &out };
    const mux = tm.sampleMux();

    const src = mux.getInputBuffer(0);
    const dst = mux.getOutputBuffer(0);
    @memcpy(dst, src);
    mux.updateOutputBuffer(0, in.len);

    // The bytes that left through getOutputBuffer are exactly the bytes that
    // entered through getInputBuffer — the seam added nothing and dropped
    // nothing.
    try testing.expectEqualSlices(u8, &in, &out);
}

test "PullTestSampleMux: output bytes round-trip the seam exactly (catalog §4 round-trip)" {
    var in = [_]u8{0} ** 32;
    var out = [_]u8{0xff} ** 32;
    fillRamp(&in, 0x33);

    var pm = pan.PullTestSampleMux{ .input = &in, .output = &out };
    const mux = pm.sampleMux();

    @memcpy(mux.getOutputBuffer(0), mux.getInputBuffer(0));
    mux.updateInputBuffer(0, in.len);
    mux.updateOutputBuffer(0, out.len);

    try testing.expectEqualSlices(u8, &in, &out);
}

test "PullSampleMux: output bytes round-trip the pool arena exactly (catalog §4 round-trip)" {
    var in = [_]u8{0} ** 32;
    var out = [_]u8{0xff} ** 32;
    fillRamp(&in, 0x0f);

    var ps = pan.PullSampleMux{ .in_buf = &in, .out_buf = &out };
    const mux = ps.sampleMux();

    @memcpy(mux.getOutputBuffer(0), mux.getInputBuffer(0));
    mux.updateOutputBuffer(0, out.len); // no-op, but the contract permits the call

    try testing.expectEqualSlices(u8, &in, &out);
}

test "RingSampleMux: output bytes round-trip the seam exactly (catalog §4 round-trip)" {
    var in = [_]u8{0} ** 32;
    var out = [_]u8{0xff} ** 32;
    fillRamp(&in, 0x77);

    var rm = pan.RingSampleMux{ .in_buf = &in, .out_buf = &out };
    const mux = rm.sampleMux();

    @memcpy(mux.getOutputBuffer(0), mux.getInputBuffer(0));
    mux.updateInputBuffer(0, in.len);
    mux.updateOutputBuffer(0, out.len);

    try testing.expectEqualSlices(u8, &in, &out);
}

// A buggy realization that swapped input/output, dropped a byte, or returned a
// stale buffer would fail the round-trip above. To make that discrimination
// explicit: the output must NOT equal its initial sentinel fill (the copy
// actually happened, the test isn't vacuous on a no-op mux).
test "round-trip is non-vacuous: the copy actually overwrites the sentinel" {
    var in = [_]u8{0xAB} ** 16;
    var out = [_]u8{0xCD} ** 16; // sentinel distinct from input
    var tm = pan.TestSampleMux{ .input = &in, .output = &out };
    const mux = tm.sampleMux();
    @memcpy(mux.getOutputBuffer(0), mux.getInputBuffer(0));
    // If getOutputBuffer had returned a detached/stale buffer, `out` would still
    // be all 0xCD here.
    for (out) |b| try testing.expectEqual(@as(u8, 0xAB), b);
}

// ===========================================================================
// LAW 2 — CURSOR MONOTONICITY (pull & ring): availability drains to exactly 0,
// post-advance buffers are correctly offset, the driver never over-reads.
// ===========================================================================

test "PullTestSampleMux: repeated update drains availability monotonically to exactly zero (catalog §4 cursor)" {
    var in = [_]u8{0} ** 30;
    var out = [_]u8{0} ** 30;
    fillRamp(&in, 0x5a);
    var pm = pan.PullTestSampleMux{ .input = &in, .output = &out };
    const mux = pm.sampleMux();

    // chunk of 7 does NOT divide 30 (H∤N): the loop must still land on exactly 0.
    const chunk: usize = 7;
    var prev_in = mux.getInputAvailable(0);
    var prev_out = mux.getOutputAvailable(0);
    try testing.expectEqual(@as(usize, 30), prev_in);
    try testing.expectEqual(@as(usize, 30), prev_out);

    while (mux.getInputAvailable(0) > 0) {
        const avail = mux.getInputAvailable(0);
        const n = @min(chunk, avail);

        // Buffer offered FROM the cursor is exactly the remaining-length slice,
        // and its first byte is the next un-consumed input byte. This catches a
        // realization that slices from 0 instead of from the cursor.
        const src = mux.getInputBuffer(0);
        try testing.expectEqual(avail, src.len);
        try testing.expectEqual(in[in.len - avail], src[0]);

        mux.updateInputBuffer(0, n);
        mux.updateOutputBuffer(0, n);

        // Strictly monotone non-increasing, dropping by exactly n each step.
        const now_in = mux.getInputAvailable(0);
        const now_out = mux.getOutputAvailable(0);
        try testing.expectEqual(prev_in - n, now_in);
        try testing.expectEqual(prev_out - n, now_out);
        try testing.expect(now_in <= prev_in);
        prev_in = now_in;
        prev_out = now_out;
    }
    // Drained to EXACTLY zero — not negative-wrapped, not a remainder left over.
    try testing.expectEqual(@as(usize, 0), mux.getInputAvailable(0));
    try testing.expectEqual(@as(usize, 0), mux.getOutputAvailable(0));
    // Cursors landed exactly at the buffer end.
    try testing.expectEqual(in.len, pm.in_cursor);
    try testing.expectEqual(out.len, pm.out_cursor);
}

test "RingSampleMux: repeated update drains availability monotonically to exactly zero (catalog §4 cursor)" {
    var in = [_]u8{0} ** 30;
    var out = [_]u8{0} ** 30;
    fillRamp(&in, 0x11);
    var rm = pan.RingSampleMux{ .in_buf = &in, .out_buf = &out };
    const mux = rm.sampleMux();

    const chunk: usize = 4; // 4∤30
    var prev = mux.getInputAvailable(0);
    try testing.expectEqual(@as(usize, 30), prev);
    while (mux.getInputAvailable(0) > 0) {
        const avail = mux.getInputAvailable(0);
        const n = @min(chunk, avail);
        const src = mux.getInputBuffer(0);
        try testing.expectEqual(avail, src.len);
        try testing.expectEqual(in[in.len - avail], src[0]);
        mux.updateInputBuffer(0, n);
        mux.updateOutputBuffer(0, n);
        const now = mux.getInputAvailable(0);
        try testing.expectEqual(prev - n, now);
        prev = now;
    }
    try testing.expectEqual(@as(usize, 0), mux.getInputAvailable(0));
    try testing.expectEqual(@as(usize, 0), mux.getOutputAvailable(0));
    try testing.expectEqual(in.len, rm.in_cursor);
    try testing.expectEqual(out.len, rm.out_cursor);
}

test "PullTestSampleMux: a single full-length update collapses availability to zero (catalog §4 cursor)" {
    var in = [_]u8{0} ** 8;
    var out = [_]u8{0} ** 8;
    var pm = pan.PullTestSampleMux{ .input = &in, .output = &out };
    const mux = pm.sampleMux();
    try testing.expectEqual(@as(usize, 8), mux.getInputAvailable(0));
    mux.updateInputBuffer(0, 8);
    mux.updateOutputBuffer(0, 8);
    try testing.expectEqual(@as(usize, 0), mux.getInputAvailable(0));
    try testing.expectEqual(@as(usize, 0), mux.getOutputAvailable(0));
    // The buffer offered after full drain is empty, not a wrap-around view.
    try testing.expectEqual(@as(usize, 0), mux.getInputBuffer(0).len);
    try testing.expectEqual(@as(usize, 0), mux.getOutputBuffer(0).len);
}

test "PullTestSampleMux: post-advance buffer is the correctly offset sub-slice (catalog §4 cursor)" {
    var in = [_]u8{ 10, 11, 12, 13, 14, 15 };
    var out = [_]u8{0} ** 6;
    var pm = pan.PullTestSampleMux{ .input = &in, .output = &out };
    const mux = pm.sampleMux();

    mux.updateInputBuffer(0, 2); // consume {10, 11}
    const after = mux.getInputBuffer(0);
    try testing.expectEqual(@as(usize, 4), after.len);
    try testing.expectEqualSlices(u8, in[2..], after); // exactly the tail

    mux.updateInputBuffer(0, 3); // consume {12, 13, 14}
    const after2 = mux.getInputBuffer(0);
    try testing.expectEqual(@as(usize, 1), after2.len);
    try testing.expectEqual(@as(u8, 15), after2[0]);
}

// in_cursor and out_cursor are independent: advancing one does not move the
// other. A realization that shared a single cursor would fail this.
test "PullTestSampleMux: input and output cursors advance independently (catalog §4 cursor)" {
    var in = [_]u8{0} ** 12;
    var out = [_]u8{0} ** 12;
    var pm = pan.PullTestSampleMux{ .input = &in, .output = &out };
    const mux = pm.sampleMux();
    mux.updateInputBuffer(0, 5);
    try testing.expectEqual(@as(usize, 7), mux.getInputAvailable(0));
    try testing.expectEqual(@as(usize, 12), mux.getOutputAvailable(0)); // untouched
    mux.updateOutputBuffer(0, 3);
    try testing.expectEqual(@as(usize, 7), mux.getInputAvailable(0)); // still
    try testing.expectEqual(@as(usize, 9), mux.getOutputAvailable(0));
    try testing.expectEqual(@as(usize, 5), pm.in_cursor);
    try testing.expectEqual(@as(usize, 3), pm.out_cursor);
}

// ===========================================================================
// LAW 3 — PUSH NO-OP COMMIT (`TestSampleMux`): whole buffers are exposed and
// `update*` does NOT change availability. This is the exact structural
// difference from pull that the dual-mux probe exists to expose.
// ===========================================================================

test "TestSampleMux: exposes whole buffers; availability is the full length (catalog §4 push)" {
    var in = [_]u8{0} ** 20;
    var out = [_]u8{0} ** 20;
    var tm = pan.TestSampleMux{ .input = &in, .output = &out };
    const mux = tm.sampleMux();
    try testing.expectEqual(@as(usize, 20), mux.getInputAvailable(0));
    try testing.expectEqual(@as(usize, 20), mux.getOutputAvailable(0));
    try testing.expectEqual(@as(usize, 20), mux.getInputBuffer(0).len);
    try testing.expectEqual(@as(usize, 20), mux.getOutputBuffer(0).len);
}

test "TestSampleMux: update is a no-op commit; availability is unchanged after commit (catalog §4 push)" {
    var in = [_]u8{0} ** 20;
    var out = [_]u8{0} ** 20;
    var tm = pan.TestSampleMux{ .input = &in, .output = &out };
    const mux = tm.sampleMux();

    // Several commits of varying size — push semantics: NONE of them move an
    // availability cursor (there is none). This is what distinguishes push from
    // the cursor-advancing pull/ring muxes.
    mux.updateOutputBuffer(0, 5);
    mux.updateInputBuffer(0, 8);
    mux.updateOutputBuffer(0, 20);
    try testing.expectEqual(@as(usize, 20), mux.getInputAvailable(0));
    try testing.expectEqual(@as(usize, 20), mux.getOutputAvailable(0));
    // And the exposed buffer is STILL the whole buffer, not an offset tail.
    try testing.expectEqual(@as(usize, 20), mux.getInputBuffer(0).len);
    try testing.expectEqual(@as(usize, 20), mux.getOutputBuffer(0).len);
}

// The push/pull structural divergence, pinned side by side: feed the SAME
// initial buffers, issue the SAME update(n), and assert push availability is
// unchanged while pull availability dropped by exactly n. This IS the property
// the dual-mux probe relies on.
test "push vs pull divergence: update moves the pull cursor but not the push cursor (catalog §4.2 dual-mux)" {
    var in_push = [_]u8{0} ** 16;
    var out_push = [_]u8{0} ** 16;
    var in_pull = [_]u8{0} ** 16;
    var out_pull = [_]u8{0} ** 16;

    var tm = pan.TestSampleMux{ .input = &in_push, .output = &out_push };
    var pm = pan.PullTestSampleMux{ .input = &in_pull, .output = &out_pull };
    const push = tm.sampleMux();
    const pull = pm.sampleMux();

    try testing.expectEqual(push.getInputAvailable(0), pull.getInputAvailable(0)); // start equal

    push.updateInputBuffer(0, 6);
    pull.updateInputBuffer(0, 6);

    try testing.expectEqual(@as(usize, 16), push.getInputAvailable(0)); // push: unchanged
    try testing.expectEqual(@as(usize, 10), pull.getInputAvailable(0)); // pull: −6
    // The divergence is real: the two muxes now report different availability
    // for identical buffers and identical calls.
    try testing.expect(push.getInputAvailable(0) != pull.getInputAvailable(0));
}

// ===========================================================================
// LAW 4 — SYNCHRONOUS PULL (`PullSampleMux`): wait* immediate, update* no-ops,
// buffers are the assigned pool arena (the whole in/out byte arena).
// ===========================================================================

test "PullSampleMux: wait* return immediately and buffers are the whole arena (catalog §4 sync-pull)" {
    var in = [_]u8{0} ** 24;
    var out = [_]u8{0} ** 24;
    var ps = pan.PullSampleMux{ .in_buf = &in, .out_buf = &out };
    const mux = ps.sampleMux();

    // wait* are immediate: they return with no blocking and no state change.
    mux.waitInputAvailable(0, 24);
    mux.waitOutputAvailable(0, 24);

    // Buffers are the whole assigned arena (upstream already rendered).
    try testing.expectEqual(@as(usize, 24), mux.getInputAvailable(0));
    try testing.expectEqual(@as(usize, 24), mux.getOutputAvailable(0));
    try testing.expectEqual(@as(usize, 24), mux.getInputBuffer(0).len);
    try testing.expectEqual(@as(usize, 24), mux.getOutputBuffer(0).len);
}

test "PullSampleMux: update* are no-ops; the arena view never shrinks (catalog §4 sync-pull)" {
    var in = [_]u8{0} ** 24;
    var out = [_]u8{0} ** 24;
    var ps = pan.PullSampleMux{ .in_buf = &in, .out_buf = &out };
    const mux = ps.sampleMux();
    mux.updateInputBuffer(0, 10);
    mux.updateOutputBuffer(0, 10);
    // No cursor exists: availability and buffers are unchanged (the single-shot
    // render already happened; commits carry no liveness here).
    try testing.expectEqual(@as(usize, 24), mux.getInputAvailable(0));
    try testing.expectEqual(@as(usize, 24), mux.getOutputAvailable(0));
    try testing.expectEqual(@as(usize, 24), mux.getInputBuffer(0).len);
}

// ===========================================================================
// LAW 5 — SIDE CHANNELS: setEOS and getNumReadersForOutput.
// ===========================================================================

test "setEOS sets the eos flag on muxes that carry one (catalog §4 EOS)" {
    var tin = [_]u8{0} ** 4;
    var tout = [_]u8{0} ** 4;
    var tm = pan.TestSampleMux{ .input = &tin, .output = &tout };
    var pm = pan.PullTestSampleMux{ .input = &tin, .output = &tout };
    var rm = pan.RingSampleMux{ .in_buf = &tin, .out_buf = &tout };

    try testing.expect(!tm.eos);
    try testing.expect(!pm.eos);
    try testing.expect(!rm.eos);

    tm.sampleMux().setEOS();
    pm.sampleMux().setEOS();
    rm.sampleMux().setEOS();

    try testing.expect(tm.eos);
    try testing.expect(pm.eos);
    try testing.expect(rm.eos);
}

// setEOS is idempotent: a second call keeps the flag set (a realization that
// toggled would fail).
test "setEOS is idempotent (catalog §4 EOS)" {
    var tin = [_]u8{0} ** 4;
    var tout = [_]u8{0} ** 4;
    var tm = pan.TestSampleMux{ .input = &tin, .output = &tout };
    const mux = tm.sampleMux();
    mux.setEOS();
    mux.setEOS();
    try testing.expect(tm.eos);
}

// PullSampleMux's setEOS is a no-op (it carries no eos field). The dispatch must
// still be callable through the vtable without effect — pinned so the seam stays
// uniform across realizations that do and don't track EOS.
test "PullSampleMux: setEOS is a callable no-op (carries no eos state) (catalog §4 EOS)" {
    var in = [_]u8{0} ** 4;
    var out = [_]u8{0} ** 4;
    var ps = pan.PullSampleMux{ .in_buf = &in, .out_buf = &out };
    const mux = ps.sampleMux();
    mux.setEOS(); // must not crash; nothing observable changes
    try testing.expectEqual(@as(usize, 4), mux.getInputAvailable(0));
}

test "getNumReadersForOutput reports the fan-out reader count (1 here) for every realization (catalog §4 fan-out)" {
    var in = [_]u8{0} ** 4;
    var out = [_]u8{0} ** 4;
    var tm = pan.TestSampleMux{ .input = &in, .output = &out };
    var pm = pan.PullTestSampleMux{ .input = &in, .output = &out };
    var ps = pan.PullSampleMux{ .in_buf = &in, .out_buf = &out };
    var rm = pan.RingSampleMux{ .in_buf = &in, .out_buf = &out };
    try testing.expectEqual(@as(usize, 1), tm.sampleMux().getNumReadersForOutput(0));
    try testing.expectEqual(@as(usize, 1), pm.sampleMux().getNumReadersForOutput(0));
    try testing.expectEqual(@as(usize, 1), ps.sampleMux().getNumReadersForOutput(0));
    try testing.expectEqual(@as(usize, 1), rm.sampleMux().getNumReadersForOutput(0));
}

// ===========================================================================
// LAW 6 — TYPED MULTI-CHUNK DRIVE: the seam erases `Sample(f32)` to `[]u8`; a
// typed wrapper recovers it. Drive an identity copy chunk-by-chunk through the
// vtable and assert the full typed output equals the input, bit-exact, across
// several chunk sizes — including 1 and H∤N.
// ===========================================================================

/// Pull-style driver loop over `PullTestSampleMux`: obtain the cursor sub-slice,
/// recover the typed view, copy `n` elements, advance both cursors. This mirrors
/// exactly how the executor drives a Map block under pull.
fn driveIdentityPull(in: []const Sample(f32), out: []Sample(f32), chunk: usize) void {
    std.debug.assert(in.len == out.len);
    var pm = pan.PullTestSampleMux{
        .input = bytesOfConst(Sample(f32), in),
        .output = bytesOf(Sample(f32), out),
    };
    const mux = pm.sampleMux();
    while (mux.getInputAvailable(0) > 0) {
        const avail_elems = mux.getInputAvailable(0) / esz;
        const n = @min(chunk, avail_elems);
        mux.waitInputAvailable(0, n * esz);
        const src = samplesOfConst(Sample(f32), mux.getInputBuffer(0))[0..n];
        const dst = samplesOf(Sample(f32), mux.getOutputBuffer(0))[0..n];
        @memcpy(dst, src); // the identity block
        mux.updateInputBuffer(0, n * esz);
        mux.updateOutputBuffer(0, n * esz);
    }
}

/// Ring-style driver loop, structurally identical (RingSampleMux is the offline
/// push stub with the same cursor advance).
fn driveIdentityRing(in: []const Sample(f32), out: []Sample(f32), chunk: usize) void {
    std.debug.assert(in.len == out.len);
    var rm = pan.RingSampleMux{
        .in_buf = bytesOfConst(Sample(f32), in),
        .out_buf = bytesOf(Sample(f32), out),
    };
    const mux = rm.sampleMux();
    while (mux.getInputAvailable(0) > 0) {
        const avail_elems = mux.getInputAvailable(0) / esz;
        const n = @min(chunk, avail_elems);
        const src = samplesOfConst(Sample(f32), mux.getInputBuffer(0))[0..n];
        const dst = samplesOf(Sample(f32), mux.getOutputBuffer(0))[0..n];
        @memcpy(dst, src);
        mux.updateInputBuffer(0, n * esz);
        mux.updateOutputBuffer(0, n * esz);
    }
}

/// Push-style driver loop over per-chunk `TestSampleMux` instances (a fresh mux
/// over each window, the no-op-commit push model).
fn driveIdentityPush(in: []const Sample(f32), out: []Sample(f32), chunk: usize) void {
    std.debug.assert(in.len == out.len);
    var i: usize = 0;
    while (i < in.len) {
        const n = @min(chunk, in.len - i);
        var tm = pan.TestSampleMux{
            .input = bytesOfConst(Sample(f32), in[i .. i + n]),
            .output = bytesOf(Sample(f32), out[i .. i + n]),
        };
        const mux = tm.sampleMux();
        mux.waitInputAvailable(0, n * esz);
        const src = samplesOfConst(Sample(f32), mux.getInputBuffer(0));
        const dst = samplesOf(Sample(f32), mux.getOutputBuffer(0));
        @memcpy(dst, src);
        mux.updateOutputBuffer(0, n * esz);
        i += n;
    }
}

fn fillSampleRamp(buf: []Sample(f32), seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (buf) |*s| s.ch[0] = r.float(f32) * 2.0 - 1.0;
}

/// The core characterization: a typed identity render through a given driver
/// reproduces the input bit-exactly, for every chunk in `chunks`. A fresh output
/// buffer (poisoned with a sentinel) is used per chunk so a partial render is
/// caught.
fn expectTypedIdentity(
    driver: *const fn (in: []const Sample(f32), out: []Sample(f32), chunk: usize) void,
    n: usize,
    chunks: []const usize,
    seed: u64,
) !void {
    const gpa = testing.allocator;
    const in = try gpa.alloc(Sample(f32), n);
    defer gpa.free(in);
    const out = try gpa.alloc(Sample(f32), n);
    defer gpa.free(out);

    fillSampleRamp(in, seed);

    for (chunks) |chunk| {
        // Poison output so an incomplete drive (e.g. a cursor that stops short)
        // diverges from the input rather than coincidentally matching.
        for (out) |*s| s.ch[0] = std.math.nan(f32);
        driver(in, out, chunk);

        // Bit-exact comparison via the raw bytes — tolerance never applies at
        // this seam. NaN sentinels would also fail a value compare, but the byte
        // compare is the structural oracle.
        try testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(in),
            std.mem.sliceAsBytes(out),
        );
    }
}

test "typed identity drive through PullTestSampleMux is bit-exact across chunkings incl. 1 and H∤N (catalog §4.2)" {
    // 1 (sample-at-a-time), 256 (clean divisor of 1024), 333 (1024 % 333 != 0),
    // 1023 (one short of the whole), 1024 (the whole buffer in one chunk).
    try expectTypedIdentity(driveIdentityPull, 1024, &.{ 1, 256, 333, 1023, 1024 }, 0xA1);
}

test "typed identity drive through RingSampleMux is bit-exact across chunkings incl. 1 and H∤N (catalog §4.2)" {
    try expectTypedIdentity(driveIdentityRing, 1024, &.{ 1, 256, 333, 1023, 1024 }, 0xB2);
}

test "typed identity drive through TestSampleMux (push) is bit-exact across chunkings incl. 1 and H∤N (catalog §4.2)" {
    try expectTypedIdentity(driveIdentityPush, 1024, &.{ 1, 256, 333, 1023, 1024 }, 0xC3);
}

// The three driver realizations must agree byte-for-byte on the SAME input —
// the mux-independence claim made concrete. If any realization leaked a surface
// difference (offset error, stale buffer, lost tail), the three outputs would
// diverge here.
test "push, pull, and ring drivers produce byte-identical output for the same input (catalog §4.2 mux-independence)" {
    const gpa = testing.allocator;
    const n: usize = 1000;
    const in = try gpa.alloc(Sample(f32), n);
    defer gpa.free(in);
    const o_push = try gpa.alloc(Sample(f32), n);
    defer gpa.free(o_push);
    const o_pull = try gpa.alloc(Sample(f32), n);
    defer gpa.free(o_pull);
    const o_ring = try gpa.alloc(Sample(f32), n);
    defer gpa.free(o_ring);

    fillSampleRamp(in, 0xD4);

    // A ragged chunk (333 ∤ 1000) to stress the loop tails in all three.
    driveIdentityPush(in, o_push, 333);
    driveIdentityPull(in, o_pull, 333);
    driveIdentityRing(in, o_ring, 333);

    const b_in = std.mem.sliceAsBytes(in);
    try testing.expectEqualSlices(u8, b_in, std.mem.sliceAsBytes(o_push));
    try testing.expectEqualSlices(u8, b_in, std.mem.sliceAsBytes(o_pull));
    try testing.expectEqualSlices(u8, b_in, std.mem.sliceAsBytes(o_ring));
    // And, transitively, to each other.
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(o_push), std.mem.sliceAsBytes(o_pull));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(o_pull), std.mem.sliceAsBytes(o_ring));
}

// Empty stream edge: a zero-length buffer drives zero iterations and produces a
// zero-length, exactly-equal result (no over-read, no spurious iteration).
test "typed identity drive over an empty stream is a no-op with zero availability (catalog §4 boundary)" {
    var in_arr = [_]Sample(f32){};
    var out_arr = [_]Sample(f32){};
    driveIdentityPull(&in_arr, &out_arr, 16);
    driveIdentityRing(&in_arr, &out_arr, 16);
    driveIdentityPush(&in_arr, &out_arr, 16);
    // Availability of an empty pull mux is exactly 0 from the start.
    var pm = pan.PullTestSampleMux{
        .input = bytesOfConst(Sample(f32), &in_arr),
        .output = bytesOf(Sample(f32), &out_arr),
    };
    try testing.expectEqual(@as(usize, 0), pm.sampleMux().getInputAvailable(0));
}
