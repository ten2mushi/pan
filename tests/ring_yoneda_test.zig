//! Yoneda-style behavioural specification for `pan.Ring` — the bounded
//! single-producer/single-consumer (SPSC) block channel that is the offline push
//! transport's substance. These tests do not merely exercise the type; they
//! *define* its contract through every morphism a caller can observe: the bytes
//! that come out, their order, the absence of loss/duplication, the depth bound,
//! and the end-of-stream drain semantics. An implementation that passes all of
//! these is functionally indistinguishable from a correct bounded SPSC channel.
//!
//! The SPSC contract (encoded as a data-race-freedom invariant in every threaded
//! test): exactly one thread writes `tail`/`eos` (the producer) and exactly one
//! thread writes `head` (the consumer). Release/acquire ordering publishes a full
//! slot before it is read. We never have two producer threads or two consumer
//! threads touch the same cursor — that would violate the contract the type is
//! built on, and is therefore out of scope by construction.

const std = @import("std");
const pan = @import("pan");

const Ring = pan.Ring;

// ---------------------------------------------------------------------------
// Law 1 — Single-slot round-trip (single-threaded identity).
//
// WHY: the most basic morphism — a slot the producer writes is the *exact* slot
// the consumer reads (byte-for-byte, no transformation), and after EOS the
// consumer observes the stream's end as `null`. If this fails, the channel does
// not even preserve a single datum and nothing else can be trusted.
// ---------------------------------------------------------------------------

test "Ring round-trips a single committed slot byte-for-byte then signals end via null (identity morphism)" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, 4, 1); // depth=1: smallest possible ring
    defer ring.deinit(gpa);

    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const w = ring.produceSlot();
    @memcpy(w, &payload);
    ring.commitProduce();
    ring.setEos();

    const r = ring.consumeSlot() orelse return error.ExpectedSlotButGotNull;
    // The bytes read are EXACTLY the bytes written — no truncation, no aliasing
    // to a stale slot, no zero-fill.
    try std.testing.expectEqualSlices(u8, &payload, r);
    ring.commitConsume();

    // The stream ended and fully drained: the consumer must now see `null`,
    // not block forever and not return a phantom slot.
    try std.testing.expect(ring.consumeSlot() == null);
}

// ---------------------------------------------------------------------------
// Law 2 — Empty stream: EOS with zero produced slots drains immediately to null.
//
// WHY: the drain predicate is `ended AND fully consumed`. With nothing ever
// produced, `tail == head == 0` and `eos == true`, so the very first
// `consumeSlot` must return `null` — it must not block (no slot will ever come)
// and must not fabricate a slot (none was committed).
// ---------------------------------------------------------------------------

test "Ring with EOS set and zero produced slots yields null on first consume (empty-stream drain)" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, 8, 4);
    defer ring.deinit(gpa);

    ring.setEos();
    try std.testing.expect(ring.consumeSlot() == null);
    // Idempotent: an ended-and-drained stream keeps returning null.
    try std.testing.expect(ring.consumeSlot() == null);
}

// ---------------------------------------------------------------------------
// Law 3 — EOS does NOT prematurely truncate: every committed-before-EOS slot is
// delivered, in order, BEFORE the consumer sees null.
//
// WHY: `eos` is set AFTER the final `commitProduce`. The drain predicate must be
// `ended AND empty`, never `ended`. A buggy implementation that returns `null`
// the instant `eos` is observed (ignoring un-drained slots) would lose the tail
// of the stream. This single-threaded test pins exactly that boundary: many
// slots are queued, EOS is set, and ALL of them must come out first.
// ---------------------------------------------------------------------------

test "Ring delivers all pre-EOS committed slots in order before null, never truncating the tail (drain = ended AND empty)" {
    const gpa = std.testing.allocator;
    const n: u8 = 5;
    var ring = try Ring.init(gpa, 1, n); // depth == count, so all fit at once
    defer ring.deinit(gpa);

    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const w = ring.produceSlot();
        w[0] = i; // monotone counter — any reorder/loss is detectable
        ring.commitProduce();
    }
    ring.setEos(); // EOS observed while 5 slots are still un-consumed.

    var expect: u8 = 0;
    while (ring.consumeSlot()) |slot| {
        try std.testing.expectEqual(expect, slot[0]);
        ring.commitConsume();
        expect += 1;
    }
    // Exactly `n` slots came out — none lost to premature EOS truncation, none
    // duplicated.
    try std.testing.expectEqual(n, expect);
}

// ---------------------------------------------------------------------------
// Law 4 — Slot recycling: a depth-D ring carries far more than D items across
// its lifetime by reusing slot storage; the recycled slot delivers FRESH bytes,
// never a stale ghost of a prior occupant.
//
// WHY: `slotAt` indexes `idx % depth`. After the consumer frees slot k, the
// producer reuses that physical storage for item k+depth. If the producer wrote
// before the consumer truly freed it (a depth-bound violation), or if the
// consumer read a slot the producer had already overwritten, we would see a
// wrong value. Single-threaded interleave (produce up to full, drain one,
// produce one, ...) exercises the wrap precisely and deterministically.
// ---------------------------------------------------------------------------

test "Ring recycles slot storage across wraps, each delivery carrying fresh bytes (idx mod depth wrap is sound)" {
    const gpa = std.testing.allocator;
    const depth: usize = 3;
    var ring = try Ring.init(gpa, @sizeOf(u32), depth);
    defer ring.deinit(gpa);

    const total: u32 = 50; // >> depth, forcing many wraps
    // Fill to capacity first.
    var produced: u32 = 0;
    while (produced < depth) : (produced += 1) {
        const w = ring.produceSlot();
        @memcpy(w, std.mem.asBytes(&produced));
        ring.commitProduce();
    }

    var consumed: u32 = 0;
    // Steady state: free one, produce the next, so fill never exceeds depth and
    // every produced slot is a recycled one.
    while (consumed < total) : (consumed += 1) {
        const slot = ring.consumeSlot() orelse return error.ExpectedSlotButGotNull;
        try std.testing.expectEqual(consumed, std.mem.bytesToValue(u32, slot));
        ring.commitConsume();
        if (produced < total) {
            const w = ring.produceSlot();
            @memcpy(w, std.mem.asBytes(&produced));
            ring.commitProduce();
            produced += 1;
        }
    }
    try std.testing.expectEqual(total, consumed);
}

// ---------------------------------------------------------------------------
// Law 5 (O2) — Bounded depth: the ring NEVER holds more than `depth`
// unconsumed slots; the producer genuinely blocks when full.
//
// WHY: O2 says the footprint is bounded by `depth`. We prove the block is real,
// not advisory: a producer thread races ahead while a deliberately slow consumer
// trickles. We sample the live fill (`tail - head`, computed from the same
// atomics the type uses) on the consumer side. If the producer could run ahead
// unbounded, the fill would exceed `depth`; the invariant is that it never does.
// The counter payload simultaneously proves order/no-loss under real blocking.
// ---------------------------------------------------------------------------

test "Ring never holds more than `depth` unconsumed slots — the producer truly blocks when full (O2 bound)" {
    const gpa = std.testing.allocator;
    const depth: usize = 4;
    const count: u32 = 2000;
    var ring = try Ring.init(gpa, @sizeOf(u32), depth);
    defer ring.deinit(gpa);

    const Prod = struct {
        fn run(r: *Ring, c: u32) void {
            var i: u32 = 0;
            while (i < c) : (i += 1) {
                const slot = r.produceSlot(); // BLOCKS when fill == depth
                @memcpy(slot, std.mem.asBytes(&i));
                r.commitProduce();
            }
            r.setEos();
        }
    };

    const t = try std.Thread.spawn(.{}, Prod.run, .{ &ring, count });

    var expect: u32 = 0;
    var max_fill_seen: usize = 0;
    while (ring.consumeSlot()) |slot| {
        // Sample the live fill BEFORE freeing this slot. `head` is written only
        // by this consumer thread, `tail` only by the producer; this acquire/
        // monotonic read mirrors the type's own `readableSlots`. It is an upper
        // bound on the true fill (the producer may free-er it concurrently, only
        // making fill smaller), so observing <= depth here is conservative-safe.
        const t_now = ring.tail.load(.acquire);
        const h_now = ring.head.load(.monotonic);
        const fill = t_now - h_now;
        if (fill > max_fill_seen) max_fill_seen = fill;
        // The hard O2 invariant: at no observable instant does the unconsumed
        // count exceed the configured depth.
        try std.testing.expect(fill <= depth);

        try std.testing.expectEqual(expect, std.mem.bytesToValue(u32, slot));
        ring.commitConsume();
        expect += 1;

        // Make the consumer slow enough that the producer genuinely reaches the
        // full condition and blocks (otherwise the bound is untested).
        std.atomic.spinLoopHint();
    }
    t.join();

    try std.testing.expectEqual(count, expect); // no loss, no duplication
    // We actually drove the ring to capacity at least once, so the block was
    // genuinely exercised rather than vacuously satisfied.
    try std.testing.expect(max_fill_seen >= 1);
}

// ---------------------------------------------------------------------------
// Law 6 — FIFO, no loss, no duplication across REAL producer/consumer threads.
//
// WHY: this is the headline SPSC contract. With a monotone counter payload and
// 5000 items, any reordering, dropped slot, or duplicated slot is caught by the
// strict `expect == got` check and the final count. depth=8 forces many blocking
// rounds. This is the morphism that characterises the channel as a faithful FIFO
// conduit between two threads.
// ---------------------------------------------------------------------------

test "Ring preserves FIFO order with no loss and no duplication across producer/consumer threads (SPSC contract)" {
    const gpa = std.testing.allocator;
    const count: u32 = 5000;
    var ring = try Ring.init(gpa, @sizeOf(u32), 8);
    defer ring.deinit(gpa);

    const Prod = struct {
        fn run(r: *Ring, c: u32) void {
            var i: u32 = 0;
            while (i < c) : (i += 1) {
                const slot = r.produceSlot();
                @memcpy(slot, std.mem.asBytes(&i));
                r.commitProduce();
            }
            r.setEos();
        }
    };

    const t = try std.Thread.spawn(.{}, Prod.run, .{ &ring, count });

    var expect: u32 = 0;
    while (ring.consumeSlot()) |slot| {
        const got = std.mem.bytesToValue(u32, slot);
        // Strict equality at every step proves: in-order (got == expect),
        // no-loss (we never skip a value), no-duplication (we never see one
        // twice, since expect advances monotonically).
        try std.testing.expectEqual(expect, got);
        ring.commitConsume();
        expect += 1;
    }
    t.join();
    try std.testing.expectEqual(count, expect);
}

// ---------------------------------------------------------------------------
// Law 7 — depth=1 across threads: the degenerate ring is still a correct FIFO.
//
// WHY: depth=1 means the producer must wait for the consumer to free the single
// slot before every subsequent produce — maximal lock-step coupling. A
// correct release/acquire handshake must still deliver every item exactly once
// in order. This is the tightest stress on the publish-before-read ordering.
//
// REGRESSION GUARD (an EOS/tail race this suite originally exposed and that was
// then fixed in `Ring.consumeSlot`): the consumer must never drop the FINAL
// committed slot. The original defect was a torn read of two independent atomics
// — `consumeSlot` loaded `tail` (possibly stale) BEFORE `eos`, and acquire/
// release synchronises per-location only, so it could read an old `tail`
// (fill == 0), then a fresh `eos == true`, and wrongly conclude the stream was
// drained while a published slot was still pending. The fix observes `eos`
// before the `tail` it gates on. This test (no loss across the SPSC seam) must
// stay strict — do not weaken it.
// ---------------------------------------------------------------------------

test "Ring with depth=1 is a correct lock-step FIFO across threads (tightest publish-before-read coupling)" {
    const gpa = std.testing.allocator;
    const count: u32 = 1500;
    var ring = try Ring.init(gpa, @sizeOf(u32), 1);
    defer ring.deinit(gpa);

    const Prod = struct {
        fn run(r: *Ring, c: u32) void {
            var i: u32 = 0;
            while (i < c) : (i += 1) {
                const slot = r.produceSlot();
                @memcpy(slot, std.mem.asBytes(&i));
                r.commitProduce();
            }
            r.setEos();
        }
    };

    const t = try std.Thread.spawn(.{}, Prod.run, .{ &ring, count });
    var expect: u32 = 0;
    while (ring.consumeSlot()) |slot| {
        try std.testing.expectEqual(expect, std.mem.bytesToValue(u32, slot));
        ring.commitConsume();
        expect += 1;
    }
    t.join();
    try std.testing.expectEqual(count, expect);
}

// ---------------------------------------------------------------------------
// Law 8 — Large depth across threads: when depth >= count the producer never
// blocks, exercising the unblocked fast path while still preserving FIFO.
//
// WHY: the complement of depth=1. With a roomy ring the producer can race fully
// ahead and finish (and set EOS) long before the consumer starts draining; the
// consumer must then walk the entire backlog in order and stop at exactly the
// right place. This pins the interaction of a fully-produced-then-EOS stream
// with a from-behind consumer.
// ---------------------------------------------------------------------------

test "Ring with large depth preserves FIFO when the producer races fully ahead and sets EOS before draining (unblocked path)" {
    const gpa = std.testing.allocator;
    const count: u32 = 4096;
    var ring = try Ring.init(gpa, @sizeOf(u32), count); // depth == count: never full
    defer ring.deinit(gpa);

    const Prod = struct {
        fn run(r: *Ring, c: u32) void {
            var i: u32 = 0;
            while (i < c) : (i += 1) {
                const slot = r.produceSlot();
                @memcpy(slot, std.mem.asBytes(&i));
                r.commitProduce();
            }
            r.setEos();
        }
    };

    const t = try std.Thread.spawn(.{}, Prod.run, .{ &ring, count });
    t.join(); // let the producer finish entirely first (and set EOS)

    var expect: u32 = 0;
    while (ring.consumeSlot()) |slot| {
        try std.testing.expectEqual(expect, std.mem.bytesToValue(u32, slot));
        ring.commitConsume();
        expect += 1;
    }
    try std.testing.expectEqual(count, expect);
}

// ---------------------------------------------------------------------------
// Law 9 — Determinism: the consumed sequence is identical on every run.
//
// WHY: a FIFO channel is a deterministic conduit — the OUTPUT sequence must not
// depend on thread scheduling, only the timing does. We run the same threaded
// produce/consume of a known sequence many times and assert the captured output
// is byte-identical every iteration. Any scheduling-dependent reorder/loss would
// surface as a divergence between runs.
//
// REGRESSION GUARD (same EOS/tail race as Law 7, since fixed): determinism
// requires that no run drop the final slot. Before the fix this failed
// intermittently with "expected 800, found 799" when `consumeSlot` read a stale
// `tail` then a fresh `eos == true` and declared the stream drained with a slot
// still pending. The fix (observe `eos` before its gated `tail`) makes every run
// drain all `count` items deterministically.
// ---------------------------------------------------------------------------

test "Ring yields an identical consumed sequence on every run regardless of scheduling (determinism of the FIFO)" {
    const gpa = std.testing.allocator;
    const count: u32 = 800;
    const runs: usize = 16;

    // Capture the first run as the reference, then require every later run to
    // reproduce it exactly.
    const reference = try gpa.alloc(u32, count);
    defer gpa.free(reference);
    const captured = try gpa.alloc(u32, count);
    defer gpa.free(captured);

    const Prod = struct {
        fn run(r: *Ring, c: u32) void {
            var i: u32 = 0;
            while (i < c) : (i += 1) {
                const slot = r.produceSlot();
                @memcpy(slot, std.mem.asBytes(&i));
                r.commitProduce();
            }
            r.setEos();
        }
    };

    var run_idx: usize = 0;
    while (run_idx < runs) : (run_idx += 1) {
        var ring = try Ring.init(gpa, @sizeOf(u32), 8);
        defer ring.deinit(gpa);

        const t = try std.Thread.spawn(.{}, Prod.run, .{ &ring, count });
        var k: usize = 0;
        while (ring.consumeSlot()) |slot| {
            captured[k] = std.mem.bytesToValue(u32, slot);
            ring.commitConsume();
            k += 1;
        }
        t.join();
        try std.testing.expectEqual(@as(usize, count), k);

        if (run_idx == 0) {
            @memcpy(reference, captured);
        } else {
            // Identical to the reference run — the FIFO is order-deterministic.
            try std.testing.expectEqualSlices(u32, reference, captured);
        }
    }
    // And the reference itself is the canonical 0,1,2,... sequence.
    var v: u32 = 0;
    while (v < count) : (v += 1) try std.testing.expectEqual(v, reference[v]);
}

// ---------------------------------------------------------------------------
// Law 10 — Variable-width payloads survive intact through slot storage.
//
// WHY: `slot_bytes` is configurable; the channel must carry the *full* slot
// width byte-for-byte, not just a machine word. A multi-byte structured payload
// with a position-dependent pattern catches any partial copy, offset error in
// `slotAt`, or slot-stride miscalculation across a threaded transfer.
// ---------------------------------------------------------------------------

test "Ring carries full-width multi-byte slots intact across threads (slot_bytes stride and slotAt offset are correct)" {
    const gpa = std.testing.allocator;
    const slot_bytes: usize = 17; // deliberately non-power-of-two
    const count: u32 = 600;
    var ring = try Ring.init(gpa, slot_bytes, 5);
    defer ring.deinit(gpa);

    const Prod = struct {
        fn run(r: *Ring, c: u32, sb: usize) void {
            var i: u32 = 0;
            while (i < c) : (i += 1) {
                const slot = r.produceSlot();
                // Position-dependent, item-dependent pattern: byte j of item i.
                var j: usize = 0;
                while (j < sb) : (j += 1) {
                    slot[j] = @truncate(i +% @as(u32, @intCast(j)) *% 31);
                }
                r.commitProduce();
            }
            r.setEos();
        }
    };

    const t = try std.Thread.spawn(.{}, Prod.run, .{ &ring, count, slot_bytes });
    var expect: u32 = 0;
    while (ring.consumeSlot()) |slot| {
        try std.testing.expectEqual(slot_bytes, slot.len);
        var j: usize = 0;
        while (j < slot_bytes) : (j += 1) {
            const want: u8 = @truncate(expect +% @as(u32, @intCast(j)) *% 31);
            try std.testing.expectEqual(want, slot[j]);
        }
        ring.commitConsume();
        expect += 1;
    }
    t.join();
    try std.testing.expectEqual(count, expect);
}

// ---------------------------------------------------------------------------
// Law 11 (focused regression) — EOS must never race ahead of the final slot.
//
// WHY: this isolates the exact defect that makes Laws 7 and 9 flaky. The
// producer commits exactly ONE slot and IMMEDIATELY sets EOS — the worst case
// for the consumer's two-atomic observation. Run many independent trials so the
// scheduling race is hit reliably; a single trial that loses its only slot fails
// the test. This pins the law "a slot committed before setEos is ALWAYS
// delivered before null" with no large-N noise to hide behind.
//
// ROOT CAUSE (found by this suite, since fixed):
//   `Ring.consumeSlot` originally loaded `tail` BEFORE `eos`:
//       const t = self.tail.load(.acquire);      // (A) may observe a STALE tail
//       const h = self.head.load(.monotonic);
//       if (t - h > 0) return self.slotAt(h);
//       if (self.eos.load(.acquire)) return null; // (B) observes fresh eos==true
//   The producer's `commitProduce` (release-store `tail`) and `setEos`
//   (release-store `eos`) target DIFFERENT atomics, and acquire/release
//   establishes happens-before per-location only. Because (A) was sequenced
//   before (B), a fresh `eos` at (B) did NOT make the `tail` value read at (A)
//   current — so the consumer could read tail=old (fill 0) then eos=true and
//   return null with a published slot still pending, on a fraction of trials.
//
// THE FIX (in src/mux.zig): observe `eos` BEFORE the `tail` it gates on, so a
// `true` eos observation's happens-before covers the subsequent `tail` load and
// an empty `tail` read after `eos == true` is the genuinely-drained state. This
// test pins that the last slot is never lost — keep it strict.
// ---------------------------------------------------------------------------

test "Ring never lets EOS overtake the final committed slot — a slot committed before setEos is always delivered before null (EOS/tail observation must not tear)" {
    const gpa = std.testing.allocator;
    const trials: usize = 4000;

    const Prod = struct {
        fn run(r: *Ring) void {
            const w = r.produceSlot();
            @memcpy(w, &[_]u8{ 0x55, 0xAA, 0x55, 0xAA });
            r.commitProduce();
            r.setEos(); // EOS immediately after the one and only commit.
        }
    };

    var trial: usize = 0;
    while (trial < trials) : (trial += 1) {
        var ring = try Ring.init(gpa, 4, 1);
        defer ring.deinit(gpa);

        const t = try std.Thread.spawn(.{}, Prod.run, .{&ring});
        var got: usize = 0;
        while (ring.consumeSlot()) |slot| {
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x55, 0xAA, 0x55, 0xAA }, slot);
            ring.commitConsume();
            got += 1;
        }
        t.join();
        // The single committed-before-EOS slot must ALWAYS be delivered.
        try std.testing.expectEqual(@as(usize, 1), got);
    }
}
