//! Yoneda-style behavioral specification of the lock-free control plane
//! (`src/control.zig`): the three control verbs at their exact memory orderings.
//!
//! In the Yoneda spirit, a control-plane object is *defined* by all its
//! observable morphisms — every enqueue/drain interaction, every set→read pair,
//! every ramp slope, every publish/enter epoch step. These tests enumerate those
//! morphisms exhaustively so that any implementation passing them is functionally
//! equivalent to the one under test. The orderings themselves are not directly
//! observable single-threaded, so the semantic tests pin the *effects* the
//! orderings exist to guarantee (FIFO, intact payloads, exact snaps, monotone
//! epochs) and one threaded test drives the SPSC handoff under a real producer
//! thread for the ThreadSanitizer surface.
//!
//! COMPARISON MODE: pan-vs-pan / structural. There is NO DSP here, so every
//! assertion is EXACT — exact integer equality, exact `f32` equality (no
//! tolerance, no oracle). The ramp cases are chosen so the divisions are exact in
//! binary `f32` (powers of two), letting the slope be pinned to the bit.
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rule 13/14). Diagnostics use `std.debug.print` (never `std.log.*`) so the
//! runner does not count them as failures (Rule 12).

const std = @import("std");
const pan = @import("pan");

const testing = std.testing;
const Command = pan.Command;
const CommandRing = pan.CommandRing;
const Param = pan.Param;
const Ramp = pan.Ramp;
const Rcu = pan.Rcu;

// ===========================================================================
// Test fixtures
// ===========================================================================

/// A consumer context that records every command `drain`/`drainUntil` applies,
/// in the order applied. The recorded order IS the FIFO order the ring claims.
const Collector = struct {
    items: std.ArrayList(Command) = .empty,
    gpa: std.mem.Allocator,
    pub fn apply(self: *Collector, cmd: Command) void {
        self.items.append(self.gpa, cmd) catch unreachable;
    }
};

/// A consumer that verifies strict FIFO + payload integrity inline without
/// allocating, so it is usable on the threaded (TSan) path. It treats `node` as a
/// monotonically increasing sequence number and cross-checks every other field
/// against the contract the producer used: at_sample == node, value == f32(node).
const StrictSink = struct {
    seen: usize = 0,
    next_expected: usize = 0,
    fifo_ok: bool = true,
    payload_ok: bool = true,
    pub fn apply(self: *@This(), cmd: Command) void {
        if (cmd.node != self.next_expected) self.fifo_ok = false;
        // Payload integrity: every field must match what the producer wrote for
        // this sequence number — a torn read would break one of these.
        if (cmd.at_sample != cmd.node) self.payload_ok = false;
        if (cmd.value != @as(f32, @floatFromInt(cmd.node))) self.payload_ok = false;
        self.next_expected = cmd.node + 1;
        self.seen += 1;
    }
};

// ===========================================================================
// 1. SPSC command ring — payload integrity & strict FIFO (`schedule` verb)
// ===========================================================================

test "ring: delivers every enqueued payload intact and in strict FIFO order" {
    var ring = CommandRing(Command, 8).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);

    // Distinct values in every field so a swapped/torn payload is detectable.
    const cmds = [_]Command{
        .{ .at_sample = 0, .node = 11, .param = 1, .value = 0.25 },
        .{ .at_sample = 4, .node = 22, .param = 2, .value = 0.50 },
        .{ .at_sample = 9, .node = 33, .param = 3, .value = 0.75 },
    };
    for (cmds) |cmd| try testing.expect(ring.enqueue(cmd));
    try testing.expectEqual(@as(usize, 3), ring.len());

    ring.drain(&c);

    try testing.expectEqual(@as(usize, 3), c.items.items.len);
    for (cmds, 0..) |expected, i| {
        // Every field round-trips bit-exact and in the order enqueued (FIFO).
        try testing.expectEqual(expected.at_sample, c.items.items[i].at_sample);
        try testing.expectEqual(expected.node, c.items.items[i].node);
        try testing.expectEqual(expected.param, c.items.items[i].param);
        try testing.expectEqual(expected.value, c.items.items[i].value);
    }
    try testing.expectEqual(@as(usize, 0), ring.len()); // ring is now empty
}

test "ring: single element round-trips (smallest non-empty payload)" {
    var ring = CommandRing(Command, 2).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);
    try testing.expect(ring.enqueue(.{ .node = 7, .param = 9, .value = -1.5 }));
    ring.drain(&c);
    try testing.expectEqual(@as(usize, 1), c.items.items.len);
    try testing.expectEqual(@as(usize, 7), c.items.items[0].node);
    try testing.expectEqual(@as(u8, 9), c.items.items[0].param);
    try testing.expectEqual(@as(f32, -1.5), c.items.items[0].value);
}

test "ring: drain on an empty ring applies nothing and leaves it empty" {
    var ring = CommandRing(Command, 4).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ring.len());
    ring.drain(&c);
    try testing.expectEqual(@as(usize, 0), c.items.items.len);
    try testing.expectEqual(@as(usize, 0), ring.len());
}

// ===========================================================================
// 2. Bounded ring — full ⇒ false (never blocks), and exact fill boundary
// ===========================================================================

test "ring: enqueue returns false exactly when full, never blocking" {
    var ring = CommandRing(Command, 4).empty;
    // Fill to exactly capacity: each succeeds.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try testing.expect(ring.enqueue(.{ .node = i }));
    }
    try testing.expectEqual(@as(usize, 4), ring.len());
    // The (capacity+1)-th enqueue must fail — and return (not block).
    try testing.expect(!ring.enqueue(.{ .node = 99 }));
    try testing.expect(!ring.enqueue(.{ .node = 100 })); // still full, still false
    // len is unchanged by the rejected enqueues; no slot was overwritten.
    try testing.expectEqual(@as(usize, 4), ring.len());
}

test "ring: a rejected (full) enqueue does not corrupt or reorder the contents" {
    var ring = CommandRing(Command, 2).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);

    try testing.expect(ring.enqueue(.{ .node = 1, .value = 1.0 }));
    try testing.expect(ring.enqueue(.{ .node = 2, .value = 2.0 }));
    try testing.expect(!ring.enqueue(.{ .node = 3, .value = 3.0 })); // dropped

    ring.drain(&c);
    // Exactly the two accepted commands, in order; the dropped one is absent.
    try testing.expectEqual(@as(usize, 2), c.items.items.len);
    try testing.expectEqual(@as(usize, 1), c.items.items[0].node);
    try testing.expectEqual(@as(usize, 2), c.items.items[1].node);
}

test "ring: freeing one slot via drain re-admits exactly one enqueue" {
    var ring = CommandRing(Command, 2).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);

    try testing.expect(ring.enqueue(.{ .node = 1 }));
    try testing.expect(ring.enqueue(.{ .node = 2 }));
    try testing.expect(!ring.enqueue(.{ .node = 3 })); // full

    ring.drain(&c); // frees both slots
    try testing.expectEqual(@as(usize, 2), c.items.items.len);

    // After draining the ring is empty again and accepts a full capacity again.
    try testing.expect(ring.enqueue(.{ .node = 4 }));
    try testing.expect(ring.enqueue(.{ .node = 5 }));
    try testing.expect(!ring.enqueue(.{ .node = 6 }));
}

// ===========================================================================
// 3. Wraparound — correctness far beyond `capacity` total items
// ===========================================================================

test "ring: stays correct across many enqueue/drain cycles past capacity (wraparound)" {
    // capacity 4, but we push 10_000 total: the free-running usize indices wrap
    // the mask many times. FIFO + payload integrity must hold throughout.
    var ring = CommandRing(Command, 4).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);

    const total: usize = 10_000;
    var produced: usize = 0;
    var verified: usize = 0;

    while (verified < total) {
        // Enqueue a small batch (may partially fill / hit full).
        var batch: usize = 0;
        while (batch < 3 and produced < total) {
            if (ring.enqueue(.{
                .at_sample = produced,
                .node = produced,
                .param = @truncate(produced),
                .value = @floatFromInt(produced % 1000),
            })) {
                produced += 1;
                batch += 1;
            } else break; // full; drain to make room
        }
        c.items.clearRetainingCapacity();
        ring.drain(&c);
        for (c.items.items) |cmd| {
            // Strict FIFO: each drained node equals the running counter.
            try testing.expectEqual(verified, cmd.node);
            try testing.expectEqual(verified, cmd.at_sample);
            try testing.expectEqual(@as(u8, @truncate(verified)), cmd.param);
            try testing.expectEqual(@as(f32, @floatFromInt(verified % 1000)), cmd.value);
            verified += 1;
        }
    }
    try testing.expectEqual(total, produced);
    try testing.expectEqual(total, verified);
    try testing.expectEqual(@as(usize, 0), ring.len());
}

test "ring: a power-of-two-sized full ring wraps and refills indefinitely" {
    // Repeatedly fill to capacity and fully drain, many laps, confirming the
    // mask arithmetic never desynchronizes head/tail.
    var ring = CommandRing(Command, 8).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);

    var lap: usize = 0;
    var seq: usize = 0;
    while (lap < 500) : (lap += 1) {
        // Fill to exactly full.
        var f: usize = 0;
        while (f < 8) : (f += 1) {
            try testing.expect(ring.enqueue(.{ .node = seq + f }));
        }
        try testing.expect(!ring.enqueue(.{ .node = 999_999 })); // full
        // Drain all 8 in order.
        c.items.clearRetainingCapacity();
        ring.drain(&c);
        try testing.expectEqual(@as(usize, 8), c.items.items.len);
        for (c.items.items, 0..) |cmd, k| {
            try testing.expectEqual(seq + k, cmd.node);
        }
        seq += 8;
    }
}

// ===========================================================================
// 4. drain wait-freedom & bounded snapshot semantics
// ===========================================================================

test "ring: drain processes exactly the entries present at its tail snapshot" {
    // drain reads tail ONCE; items enqueued AFTER that snapshot wait for the next
    // call. Single-threaded we model this as: enqueue batch A, drain (sees only
    // A), enqueue batch B, drain (sees only B). No B item leaks into A's drain.
    var ring = CommandRing(Command, 16).empty;
    var a = Collector{ .gpa = testing.allocator };
    var b = Collector{ .gpa = testing.allocator };
    defer a.items.deinit(testing.allocator);
    defer b.items.deinit(testing.allocator);

    try testing.expect(ring.enqueue(.{ .node = 1 }));
    try testing.expect(ring.enqueue(.{ .node = 2 }));
    ring.drain(&a); // snapshot sees {1,2} only
    try testing.expectEqual(@as(usize, 2), a.items.items.len);

    try testing.expect(ring.enqueue(.{ .node = 3 }));
    try testing.expect(ring.enqueue(.{ .node = 4 }));
    try testing.expect(ring.enqueue(.{ .node = 5 }));
    ring.drain(&b); // a fresh snapshot sees {3,4,5}
    try testing.expectEqual(@as(usize, 3), b.items.items.len);
    try testing.expectEqual(@as(usize, 3), b.items.items[0].node);
    try testing.expectEqual(@as(usize, 5), b.items.items[2].node);
}

test "ring: drain fully empties the ring (len 0 afterward)" {
    var ring = CommandRing(Command, 8).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 5) : (i += 1) try testing.expect(ring.enqueue(.{ .node = i }));
    ring.drain(&c);
    try testing.expectEqual(@as(usize, 5), c.items.items.len);
    try testing.expectEqual(@as(usize, 0), ring.len());
    // A second drain on the now-empty ring is a no-op.
    var c2 = Collector{ .gpa = testing.allocator };
    defer c2.items.deinit(testing.allocator);
    ring.drain(&c2);
    try testing.expectEqual(@as(usize, 0), c2.items.items.len);
}

// ===========================================================================
// 5. drainUntil — partition by `at_sample` boundary
// ===========================================================================

test "ring: drainUntil applies only commands with at_sample < boundary" {
    var ring = CommandRing(Command, 8).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);
    // Non-decreasing at_sample order (the producer's scheduling policy).
    _ = ring.enqueue(.{ .at_sample = 0, .node = 100 });
    _ = ring.enqueue(.{ .at_sample = 3, .node = 101 });
    _ = ring.enqueue(.{ .at_sample = 7, .node = 102 });
    _ = ring.enqueue(.{ .at_sample = 12, .node = 103 });

    ring.drainUntil(8, &c); // at_sample in {0,3,7} qualify; 12 does not
    try testing.expectEqual(@as(usize, 3), c.items.items.len);
    try testing.expectEqual(@as(usize, 100), c.items.items[0].node);
    try testing.expectEqual(@as(usize, 101), c.items.items[1].node);
    try testing.expectEqual(@as(usize, 102), c.items.items[2].node);
    // The remainder (at_sample 12) is still queued.
    try testing.expectEqual(@as(usize, 1), ring.len());
}

test "ring: drainUntil leaves the remainder for a later boundary, in order" {
    var ring = CommandRing(Command, 8).empty;
    var c1 = Collector{ .gpa = testing.allocator };
    var c2 = Collector{ .gpa = testing.allocator };
    defer c1.items.deinit(testing.allocator);
    defer c2.items.deinit(testing.allocator);
    _ = ring.enqueue(.{ .at_sample = 2, .node = 10 });
    _ = ring.enqueue(.{ .at_sample = 9, .node = 11 });
    _ = ring.enqueue(.{ .at_sample = 20, .node = 12 });

    ring.drainUntil(8, &c1); // only at_sample 2
    try testing.expectEqual(@as(usize, 1), c1.items.items.len);
    try testing.expectEqual(@as(usize, 10), c1.items.items[0].node);

    ring.drainUntil(16, &c2); // now at_sample 9 (20 still beyond)
    try testing.expectEqual(@as(usize, 1), c2.items.items.len);
    try testing.expectEqual(@as(usize, 11), c2.items.items[0].node);
    try testing.expectEqual(@as(usize, 1), ring.len()); // node 12 remains
}

test "ring: drainUntil with boundary above all timestamps drains everything" {
    var ring = CommandRing(Command, 8).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);
    _ = ring.enqueue(.{ .at_sample = 1, .node = 1 });
    _ = ring.enqueue(.{ .at_sample = 2, .node = 2 });
    _ = ring.enqueue(.{ .at_sample = 3, .node = 3 });
    ring.drainUntil(1000, &c);
    try testing.expectEqual(@as(usize, 3), c.items.items.len);
    try testing.expectEqual(@as(usize, 0), ring.len());
}

test "ring: drainUntil with boundary at or below the first timestamp drains nothing" {
    var ring = CommandRing(Command, 8).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);
    _ = ring.enqueue(.{ .at_sample = 5, .node = 1 });
    _ = ring.enqueue(.{ .at_sample = 6, .node = 2 });
    // boundary == 5: at_sample 5 is NOT < 5, so it must stay (half-open [0,boundary)).
    ring.drainUntil(5, &c);
    try testing.expectEqual(@as(usize, 0), c.items.items.len);
    try testing.expectEqual(@as(usize, 2), ring.len()); // nothing consumed
}

test "ring: drainUntil stops at the first out-of-window command (boundary partition is a prefix)" {
    // The window is a strict prefix: once a command at >= boundary is seen the
    // scan stops, so a later in-window command (out of sorted order) is NOT
    // reached. This pins the documented "stops at the first command beyond the
    // boundary" behavior rather than a full filter.
    var ring = CommandRing(Command, 8).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);
    _ = ring.enqueue(.{ .at_sample = 1, .node = 1 }); // in window
    _ = ring.enqueue(.{ .at_sample = 100, .node = 2 }); // out of window -> stop here
    _ = ring.enqueue(.{ .at_sample = 2, .node = 3 }); // in window numerically, but unreachable this call
    ring.drainUntil(8, &c);
    try testing.expectEqual(@as(usize, 1), c.items.items.len);
    try testing.expectEqual(@as(usize, 1), c.items.items[0].node);
    // node 2 and node 3 both remain queued (the scan stopped at node 2).
    try testing.expectEqual(@as(usize, 2), ring.len());
}

// ===========================================================================
// 6. Param — atomic scalar target (`set` verb)
// ===========================================================================

test "param: init value is read back exactly" {
    const p = Param.init(0.75);
    try testing.expectEqual(@as(f32, 0.75), p.read());
}

test "param: set then read returns the stored value exactly (not torn)" {
    var p = Param.init(0.0);
    p.set(0.5);
    try testing.expectEqual(@as(f32, 0.5), p.read());
}

test "param: the most recent of multiple sets wins" {
    var p = Param.init(1.0);
    p.set(2.0);
    p.set(3.0);
    p.set(-4.25);
    try testing.expectEqual(@as(f32, -4.25), p.read());
}

test "param: reads are idempotent (reading does not mutate the target)" {
    var p = Param.init(9.0);
    try testing.expectEqual(@as(f32, 9.0), p.read());
    try testing.expectEqual(@as(f32, 9.0), p.read());
    p.set(0.0);
    try testing.expectEqual(@as(f32, 0.0), p.read());
    try testing.expectEqual(@as(f32, 0.0), p.read());
}

test "param: special float values round-trip bit-exact" {
    var p = Param.init(0.0);
    p.set(std.math.inf(f32));
    try testing.expectEqual(std.math.inf(f32), p.read());
    p.set(-std.math.inf(f32));
    try testing.expectEqual(-std.math.inf(f32), p.read());
    // Negative zero is bit-distinct from positive zero; the store must preserve it.
    p.set(-0.0);
    try testing.expect(std.math.signbit(p.read()));
    try testing.expectEqual(@as(f32, 0.0), p.read()); // -0.0 == 0.0 numerically
}

// ===========================================================================
// 7. Ramp — per-block anti-zipper slope (`set` verb, RT half)
// ===========================================================================

test "ramp: begin returns the exact per-sample increment (target - value)/n" {
    // Chosen so the division is exact in binary f32 (powers of two).
    var r = Ramp.init(0.0);
    try testing.expectEqual(@as(f32, 0.25), r.begin(1.0, 4)); // 1/4
    try testing.expectEqual(@as(f32, 0.125), r.begin(1.0, 8)); // 1/8
    try testing.expectEqual(@as(f32, 0.5), r.begin(2.0, 4)); // 2/4
}

test "ramp: a downward jump yields a negative increment of the right magnitude" {
    var r = Ramp.init(1.0);
    try testing.expectEqual(@as(f32, -0.25), r.begin(0.0, 4)); // (0-1)/4
}

test "ramp: begin does not move the live value (value updates only on finish)" {
    var r = Ramp.init(0.3);
    _ = r.begin(1.0, 8);
    try testing.expectEqual(@as(f32, 0.3), r.value); // unchanged by begin
}

test "ramp: n==0 yields a zero step (degenerate block)" {
    var r = Ramp.init(0.42);
    try testing.expectEqual(@as(f32, 0.0), r.begin(1.0, 0));
    try testing.expectEqual(@as(f32, 0.0), r.begin(-5.0, 0));
    try testing.expectEqual(@as(f32, 0.42), r.value); // still unmoved
}

test "ramp: reconstructed per-sample values form a monotone slope with no jump beyond the step" {
    // A knob jump becomes a smooth slope: consecutive rendered samples differ by
    // EXACTLY `inc`, never by an instantaneous jump. Exact-in-f32 case (1/4).
    var r = Ramp.init(0.0);
    const n: usize = 4;
    const target: f32 = 1.0;
    const inc = r.begin(target, n);
    try testing.expectEqual(@as(f32, 0.25), inc);

    // Rendered sample i := value + (i+1)*inc, for i in [0,n).
    var prev = r.value; // start point (0.0)
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = r.value + @as(f32, @floatFromInt(i + 1)) * inc;
        // EXACT step: each sample is exactly `inc` above the previous one.
        try testing.expectEqual(inc, s - prev);
        // Monotone upward for a positive increment.
        try testing.expect(s > prev);
        prev = s;
    }
    // The final rendered sample lands exactly on target (this case is exact).
    try testing.expectEqual(target, prev);
}

test "ramp: a downward sweep is monotone decreasing by exactly the (negative) step" {
    var r = Ramp.init(2.0);
    const n: usize = 8;
    const target: f32 = 0.0;
    const inc = r.begin(target, n); // (0-2)/8 = -0.25, exact
    try testing.expectEqual(@as(f32, -0.25), inc);
    var prev = r.value;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = r.value + @as(f32, @floatFromInt(i + 1)) * inc;
        try testing.expectEqual(inc, s - prev);
        try testing.expect(s < prev); // strictly decreasing
        prev = s;
    }
    try testing.expectEqual(target, prev); // lands exactly on 0.0
}

test "ramp: finish snaps the live value to target exactly (zero drift)" {
    var r = Ramp.init(0.0);
    _ = r.begin(0.1, 7); // a target/n where the slope is NOT exact in f32
    r.finish(0.1);
    // Despite an inexact per-sample slope, finish assigns the target verbatim.
    try testing.expectEqual(@as(f32, 0.1), r.value);
}

test "ramp: stays continuous across consecutive blocks (no accumulated drift)" {
    // Block 1: 0 -> 1 over 4. finish snaps to 1.0 exactly.
    var r = Ramp.init(0.0);
    const inc1 = r.begin(1.0, 4);
    try testing.expectEqual(@as(f32, 0.25), inc1);
    r.finish(1.0);
    try testing.expectEqual(@as(f32, 1.0), r.value);

    // Block 2 begins from EXACTLY 1.0 (finish defeated drift), sweeps to 0.5.
    const inc2 = r.begin(0.5, 4); // (0.5-1.0)/4 = -0.125, exact
    try testing.expectEqual(@as(f32, -0.125), inc2);
    // The first sample of block 2 is contiguous with block 1's endpoint: it sits
    // exactly `inc2` below 1.0, with no discontinuity at the block boundary.
    const first_sample_block2 = r.value + inc2;
    try testing.expectEqual(@as(f32, 0.875), first_sample_block2);
    r.finish(0.5);
    try testing.expectEqual(@as(f32, 0.5), r.value);
}

test "ramp: a target equal to the current value yields a zero slope (no movement)" {
    var r = Ramp.init(0.6);
    try testing.expectEqual(@as(f32, 0.0), r.begin(0.6, 16));
    r.finish(0.6);
    try testing.expectEqual(@as(f32, 0.6), r.value);
}

// ===========================================================================
// 8. Rcu — plan-swap cell (`edit → commit` verb)
// ===========================================================================

test "rcu: enter sees the initial published plan" {
    var plan: u32 = 7;
    var rcu = Rcu(*u32).init(&plan);
    try testing.expectEqual(@as(u32, 7), rcu.enter().*);
}

test "rcu: each enter bumps the epoch by exactly one (monotone, once per callback)" {
    var plan: u32 = 0;
    var rcu = Rcu(*u32).init(&plan);
    try testing.expectEqual(@as(u64, 0), rcu.epochNow()); // initial epoch
    _ = rcu.enter();
    try testing.expectEqual(@as(u64, 1), rcu.epochNow());
    _ = rcu.enter();
    try testing.expectEqual(@as(u64, 2), rcu.epochNow());
    _ = rcu.enter();
    try testing.expectEqual(@as(u64, 3), rcu.epochNow());
}

test "rcu: current reads the plan WITHOUT bumping the epoch" {
    var plan: u32 = 5;
    var rcu = Rcu(*u32).init(&plan);
    try testing.expectEqual(@as(u32, 5), rcu.current().*);
    try testing.expectEqual(@as(u64, 0), rcu.epochNow()); // current() did not tick
    _ = rcu.current();
    try testing.expectEqual(@as(u64, 0), rcu.epochNow());
}

test "rcu: publish returns the prior pointer and installs the new one" {
    var plan_a: u32 = 1;
    var plan_b: u32 = 2;
    var rcu = Rcu(*u32).init(&plan_a);

    const old = rcu.publish(&plan_b);
    try testing.expectEqual(@as(u32, 1), old.*); // returned the previous plan
    try testing.expect(old == &plan_a); // exact pointer identity
    // The next enter sees the freshly published plan.
    try testing.expectEqual(@as(u32, 2), rcu.enter().*);
}

test "rcu: a sequence of publishes each returns its immediate predecessor" {
    var a: u32 = 10;
    var b: u32 = 20;
    var c: u32 = 30;
    var rcu = Rcu(*u32).init(&a);

    const o1 = rcu.publish(&b);
    try testing.expect(o1 == &a);
    const o2 = rcu.publish(&c);
    try testing.expect(o2 == &b);
    try testing.expect(rcu.current() == &c);
}

test "rcu: enter after publish sees the new pointer, not the old" {
    var plan_a: u32 = 100;
    var plan_b: u32 = 200;
    var rcu = Rcu(*u32).init(&plan_a);

    try testing.expectEqual(@as(u32, 100), rcu.enter().*); // old plan
    _ = rcu.publish(&plan_b);
    try testing.expectEqual(@as(u32, 200), rcu.enter().*); // new plan
    // Epoch advanced once per enter (two enters here), independent of publish.
    try testing.expectEqual(@as(u64, 2), rcu.epochNow());
}

test "rcu: publish does not by itself advance the epoch (only enter does)" {
    var a: u32 = 1;
    var b: u32 = 2;
    var rcu = Rcu(*u32).init(&a);
    try testing.expectEqual(@as(u64, 0), rcu.epochNow());
    _ = rcu.publish(&b);
    try testing.expectEqual(@as(u64, 0), rcu.epochNow()); // publish is writer-side only
}

test "rcu: waitGrace returns once the epoch reaches at_swap + 2 (single-writer +2 grace)" {
    // Single-threaded: pre-advance the epoch via enters so the grace condition is
    // already satisfied, then assert waitGrace returns immediately (does not spin
    // forever). The grace bound is epoch >= at_swap + 2.
    var a: u32 = 1;
    var b: u32 = 2;
    var rcu = Rcu(*u32).init(&a);

    const at_swap = rcu.epochNow(); // 0
    _ = rcu.publish(&b);
    // Two callbacks cross the boundary -> epoch becomes at_swap + 2.
    _ = rcu.enter();
    _ = rcu.enter();
    try testing.expectEqual(at_swap + 2, rcu.epochNow());
    rcu.waitGrace(at_swap); // condition already met: returns without yielding forever
}

test "rcu: works with a non-pointer Ptr (plan handle is an opaque value)" {
    // Rcu is generic over Ptr; verify it carries a plain value type too — the
    // contract is "atomic cell + epoch", not specifically a pointer.
    var rcu = Rcu(u64).init(0xDEAD_BEEF);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), rcu.enter());
    const old = rcu.publish(0xFEED_FACE);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), old);
    try testing.expectEqual(@as(u64, 0xFEED_FACE), rcu.current());
}

// ===========================================================================
// 9. CONCURRENCY — single producer / single consumer under ThreadSanitizer
// ===========================================================================

test "spsc: one producer + one consumer deliver every item once, in FIFO, no torn payloads" {
    // EXACTLY ONE spawned producer thread enqueues a burst LARGER than capacity
    // (so the ring fills and the producer backs off without blocking), while the
    // MAIN thread is the lone consumer draining wait-free. This honors the funnel
    // obligation (one producer, one consumer) and is the ThreadSanitizer surface:
    // a -fsanitize-thread build must report no data race on the SPSC handoff.
    const cap = 256;
    const Ring = CommandRing(Command, cap);
    const Shared = struct {
        ring: Ring = Ring.empty,
        done: std.atomic.Value(bool) = .init(false),
    };
    var sh = Shared{};
    const total: usize = 50_000; // >> capacity, forcing many full/back-off cycles

    const producer = struct {
        fn run(s: *Shared, n: usize) void {
            var i: usize = 0;
            while (i < n) {
                // Payload contract the StrictSink cross-checks: at_sample == node,
                // value == f32(node). A torn read breaks one of these invariants.
                if (s.ring.enqueue(.{
                    .at_sample = i,
                    .node = i,
                    .param = @truncate(i),
                    .value = @floatFromInt(i),
                })) {
                    i += 1;
                } else {
                    std.Thread.yield() catch {}; // ring full: back off (non-RT thread)
                }
            }
            s.done.store(true, .release);
        }
    };

    var sink = StrictSink{};
    const t = try std.Thread.spawn(.{}, producer.run, .{ &sh, total });
    // Lone consumer: drain until the producer is done AND the ring is empty.
    while (!sh.done.load(.acquire) or sh.ring.len() != 0) {
        sh.ring.drain(&sink);
    }
    sh.ring.drain(&sink); // final sweep for anything published just before `done`
    t.join();

    try testing.expectEqual(total, sink.seen); // every item delivered exactly once
    try testing.expect(sink.fifo_ok); // strict FIFO order preserved
    try testing.expect(sink.payload_ok); // no torn / mismatched payloads
    try testing.expectEqual(total, sink.next_expected); // last seq+1 == total
}
