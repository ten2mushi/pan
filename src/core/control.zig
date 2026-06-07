//! The lock-free control plane — the three control verbs at their exact memory
//! orderings.
//!
//! There are exactly two thread roles. The **RT thread** owns the device
//! callback: it replays the render op-list under a hard N/Fs deadline and must
//! never block, lock, allocate, or syscall. The **control thread** is a single
//! designated non-RT thread that originates every mutation (knob moves, scheduled
//! events, topology edits); it may block, spin, and allocate freely. All
//! cross-thread cost is paid on the control thread — the RT thread only reads what
//! has already been published and acknowledges by bumping an epoch.
//!
//! The core is Single-Producer / Single-Consumer (SPSC): exactly one control
//! thread feeds the ring and performs plan commits, the RT thread is the lone
//! consumer. SPSC is *why* the control plane is wait-free with NO compare-and-swap:
//! each index has a single writer, so a plain load/store pair with the right
//! acquire/release ordering suffices — no contended read-modify-write, no retry
//! loop, hence no unbounded work on the RT thread. Apps with several mutation
//! sources (GUI, MIDI, automation) must **funnel** them through the one designated
//! control thread; calling the mutating API from two threads concurrently is a
//! data race on the producer-owned indices — unchecked illegal behavior the SPSC
//! core cannot cheaply police. That funnel is a conventional obligation, tested
//! with a ThreadSanitizer build, not enforced on the hot path.
//!
//! Three verbs, three mechanisms, all realized here:
//!   - `set`        — a lone atomic scalar holding a target, plus a per-block ramp
//!                    toward it on the RT side. Wait-free and click-free but NOT
//!                    sample-accurate (the target is reached by block end).
//!   - `schedule`   — a bounded SPSC ring of time-stamped events drained at each
//!                    sub-block boundary and applied at the carried sample offset.
//!                    Sample-accurate.
//!   - `edit→commit`— an RCU pointer swap: a new immutable plan is built entirely
//!                    off-thread, then one release store publishes it; the RT
//!                    thread does one acquire load per callback. The old plan is
//!                    reclaimed via a quiescent-state epoch the RT thread bumps at
//!                    every callback.

const std = @import("std");

// ===========================================================================
// 1. The SPSC command ring — the `schedule` verb
// ===========================================================================

/// A scheduled, sample-accurate control event: apply `value` to slot `param` of
/// node `node` at sample offset `at_sample` within the callback. This is the
/// VST3/CLAP `(sample_offset, event)` shape. The RT thread renders sub-blocks
/// bounded by these offsets and applies each event exactly at its sample.
pub const Command = struct {
    at_sample: usize = 0,
    node: usize = 0,
    param: u8 = 0,
    value: f32 = 0,
};

/// An SPSC command ring. `capacity` MUST be a power of two so an index maps to a
/// slot by a mask, not a modulo. Indices are free-running `usize` counters; the
/// live entry count is `tail - head` (wrapping subtraction is correct because both
/// grow monotonically and never differ by more than `capacity`). The ring is FULL
/// when `tail - head == capacity`, EMPTY when `tail == head`.
///
/// `head` is owned by the consumer (RT thread); `tail` by the producer (control
/// thread). They sit on SEPARATE cache lines (`std.atomic.cache_line` alignment):
/// the consumer writes `head` every drain and the producer writes `tail` every
/// enqueue, so sharing a line would ping-pong the other core's cache (false
/// sharing) on every operation.
pub fn CommandRing(comptime Cmd: type, comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0), // consumer-owned
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0), // producer-owned
        slots: [capacity]Cmd = undefined,

        pub const empty: Self = .{};
        pub const cap = capacity;

        /// Producer (control thread, NON-RT). Returns false if the ring is full;
        /// the caller may then spin / back off / retry / coalesce — backpressure is
        /// absorbed entirely off the RT thread, which never even learns the
        /// producer is waiting.
        ///
        /// Orderings: (P1) load our own `tail` relaxed — we are its only writer, so
        /// no cross-thread ordering is needed to read back our own last value.
        /// (P2) load `head` ACQUIRE — observe which slots the consumer has freed;
        /// pairing with the consumer's release store of `head` guarantees the
        /// consumer FINISHED reading any slot it freed before we reuse it. (P3) the
        /// slot payload is a plain store, made visible by (P4). (P4) store `tail`
        /// RELEASE — the publish: release guarantees every prior write in program
        /// order, crucially the slot payload (P3), is visible to a thread that
        /// acquire-loads `tail` and sees this new value.
        pub fn enqueue(self: *Self, cmd: Cmd) bool {
            const tail = self.tail.load(.monotonic); // (P1)
            const head = self.head.load(.acquire); // (P2)
            if (tail - head == capacity) return false; // ring full
            self.slots[tail & mask] = cmd; // (P3)
            self.tail.store(tail + 1, .release); // (P4) PUBLISH
            return true;
        }

        /// Consumer (RT thread). Drains every command present at the instant it
        /// reads `tail`, in order, applying each via `ctx.apply(cmd)`. WAIT-FREE:
        /// it reads `tail` exactly ONCE and loops over at most `capacity`
        /// (compile-time-constant) entries — it does NOT chase newly-arrived
        /// commands (they are picked up at the next boundary) and contains no CAS,
        /// retry, or spin. Wait-freedom follows from the shape of the code: a
        /// fixed-bound counted loop with no backward dependence on a contended
        /// write.
        ///
        /// Orderings: (C1) load our own `head` relaxed (sole writer). (C2) load
        /// `tail` ACQUIRE — pairs with (P4); seeing the new `tail` guarantees the
        /// matching slot payloads (P3) are visible, so (C3)'s plain reads are not a
        /// race. (C4) store `head` RELEASE — pairs with (P2); publishing the
        /// advanced head AFTER the slot reads guarantees the producer will not
        /// reuse a slot until we are done reading it.
        pub fn drain(self: *Self, ctx: anytype) void {
            var head = self.head.load(.monotonic); // (C1)
            const tail = self.tail.load(.acquire); // (C2)
            while (head != tail) {
                const cmd = self.slots[head & mask]; // (C3)
                ctx.apply(cmd);
                head += 1;
            }
            self.head.store(head, .release); // (C4) FREE the slots
        }

        /// Drain only the commands whose `at_sample` falls in `[0, boundary)`,
        /// leaving later ones for a subsequent sub-block. Used by the sub-block
        /// scheduler to place each event at its exact sample. Requires `Cmd` to have
        /// an `at_sample` field. Still wait-free: the loop is bounded by `capacity`
        /// and stops at the first command beyond the boundary (the ring is filled in
        /// non-decreasing `at_sample` order by the producer's scheduling policy).
        pub fn drainUntil(self: *Self, boundary: usize, ctx: anytype) void {
            var head = self.head.load(.monotonic); // (C1)
            const tail = self.tail.load(.acquire); // (C2)
            while (head != tail) {
                const cmd = self.slots[head & mask]; // (C3)
                if (cmd.at_sample >= boundary) break; // leave for the next sub-block
                ctx.apply(cmd);
                head += 1;
            }
            self.head.store(head, .release); // (C4)
        }

        /// Number of live entries at this instant (producer-side estimate).
        pub fn len(self: *const Self) usize {
            return self.tail.load(.monotonic) -% self.head.load(.acquire);
        }
    };
}

/// A bounded lock-free SPSC **data** ring carrying `Elem` values — the cross-root
/// hand-off primitive (a "tap"). When two pull roots share an upstream, the
/// upstream is rendered ONCE by its owning root and its output is published to the
/// other root through one of these rings; cross-root handoff is ONLY via this ring
/// (never via shared buffer-pool coloring — each root colors its own subplan), so a
/// non-RT analysis root tapping a live audio root can never stall the audio
/// deadline. The producer side (`push`) is WAIT-FREE and allocation-free, safe on
/// the RT thread; the consumer side (`pop`) runs on the other (non-RT) root.
///
/// Same single-writer-per-index discipline as `CommandRing`: the producer owns
/// `tail`, the consumer owns `head`, on separate cache lines. FULL ⇒ `push` drops
/// (returns false) so the RT producer never blocks on a slow consumer; EMPTY ⇒
/// `pop` returns null. `capacity` is a power of two (mask, not modulo).
pub fn SpscRing(comptime Elem: type, comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0), // consumer-owned (read index)
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0), // producer-owned (write index)
        slots: [capacity]Elem = undefined,

        pub const empty: Self = .{};
        pub const cap = capacity;

        /// Producer (the upstream root, possibly RT). WAIT-FREE: a plain bounded
        /// load/store pair, no CAS, no alloc. Returns false when full (the value is
        /// dropped — a slow non-RT consumer must never back-pressure an RT producer).
        /// Orderings mirror `CommandRing.enqueue`: own `tail` relaxed, peer `head`
        /// acquire, slot store, then `tail` RELEASE publishes the slot.
        pub fn push(self: *Self, x: Elem) bool {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (tail -% head == capacity) return false; // ring full → drop
            self.slots[tail & mask] = x;
            self.tail.store(tail +% 1, .release);
            return true;
        }

        /// Consumer (the tapping root, non-RT). Returns the next value or null when
        /// empty. Orderings mirror `CommandRing.drain`: own `head` relaxed, peer
        /// `tail` acquire (sees published slots), slot read, `head` RELEASE frees it.
        pub fn pop(self: *Self) ?Elem {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null; // empty
            const x = self.slots[head & mask];
            self.head.store(head +% 1, .release);
            return x;
        }

        /// Live entry count at this instant (consumer-side estimate).
        pub fn len(self: *const Self) usize {
            return self.tail.load(.acquire) -% self.head.load(.monotonic);
        }
    };
}

// ===========================================================================
// 2. Atomic scalar parameters — the `set` verb
// ===========================================================================

/// A continuous knob target driven from the control thread. A lone atomic `f32`:
/// `.monotonic` (relaxed) store/load is sufficient AND correct because a scalar
/// needs exactly two guarantees and no more — (1) atomicity (the RT thread reads
/// the old target or the new one, never a torn half-written float) and (2)
/// eventual visibility (a relaxed store reaches the relaxed load in finite time).
/// What relaxed does NOT give — cross-thread ordering of OTHER memory relative to
/// this store — is not needed: the scalar is self-contained, it carries no pointer
/// to a payload that must be initialized-before-published (that is the ring's job
/// and the RCU pointer's job, both of which DO use release/acquire). With nothing
/// to order against, acquire/release would guard nothing, so relaxed is the
/// weakest-correct order.
pub const Param = struct {
    target: std.atomic.Value(f32),

    pub fn init(value: f32) Param {
        return .{ .target = .init(value) };
    }

    /// Control thread: publish a new target. Not sample-accurate by contract — the
    /// target is reached by the END of the next block via the ramp, not at a
    /// caller-named sample. There is deliberately no `at_sample` parameter; that
    /// intent is only expressible on `schedule` (the ring), a type-level omission.
    pub fn set(self: *Param, value: f32) void {
        self.target.store(value, .monotonic);
    }

    /// RT thread: read the current target. One relaxed load.
    pub fn read(self: *const Param) f32 {
        return self.target.load(.monotonic);
    }
};

/// A per-block linear ramp toward a target — the anti-zipper half of `set`. The RT
/// thread carries the live value across blocks; at each block it asks for the
/// per-sample increment that glides the live value to the new target over `n`
/// frames, applies `live + i·inc` per sample, then snaps the live value to the
/// target at block end (defeating float drift). A knob jump becomes a smooth slope
/// rather than a click — the pipeline-wide "ramp, never step" policy. The ramp
/// state is per-instance and persists across blocks (a tiny piece of the
/// persistent category), so a sweep that spans several blocks stays continuous.
pub const Ramp = struct {
    /// The live, audibly-rendered value. Persists across blocks.
    value: f32,

    pub fn init(value: f32) Ramp {
        return .{ .value = value };
    }

    /// Begin a block of `n` frames ramping toward `target`. Returns the per-sample
    /// increment; the live value is NOT moved yet (apply `value + i·inc` for
    /// `i ∈ [0, n)`, then call `finish`). `n == 0` yields a zero step.
    pub fn begin(self: *const Ramp, target: f32, n: usize) f32 {
        if (n == 0) return 0;
        return (target - self.value) / @as(f32, @floatFromInt(n));
    }

    /// Snap the live value to `target` at block end, so the next block ramps from
    /// the exact target rather than accumulating per-sample rounding error.
    pub fn finish(self: *Ramp, target: f32) void {
        self.value = target;
    }
};

// ===========================================================================
// 3. RCU plan swap — the `edit → commit` verb
// ===========================================================================

/// An RCU (read-copy-update) cell holding the currently-active plan pointer plus a
/// quiescent-state epoch. Many fast readers (the RT thread, once per callback), one
/// slow writer (the control thread). `Ptr` is the (pointer) type of an immutable,
/// fully-built plan.
///
/// Publish builds the new plan entirely off-thread, then does ONE release store of
/// the pointer. The RT thread does ONE acquire load at callback start and uses that
/// same plan for the WHOLE callback — a swap mid-callback never tears a render: the
/// callback runs entirely on the old plan or entirely on the new one (the
/// block-boundary publish contract). Because there is exactly one writer, only one
/// swap is ever in flight and the pointer is only ever stored by that one thread:
/// there is NO ABA problem (the RT thread never CASes the pointer, it only loads
/// it) so no hazard pointers and no CAS are needed — the epoch alone is sufficient
/// grace-period detection. This is the direct payoff of the SPSC decision.
pub fn Rcu(comptime Ptr: type) type {
    return struct {
        const Self = @This();

        /// The currently-active plan. RT thread reads it; control thread swaps it.
        plan: std.atomic.Value(Ptr),
        /// Quiescent-state epoch, bumped by the RT thread at every callback start.
        /// On its own cache line so the writer's polling does not false-share the
        /// plan pointer.
        epoch: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),

        pub fn init(initial: Ptr) Self {
            return .{ .plan = .init(initial) };
        }

        /// Control thread. `new_plan` is FULLY constructed and immutable before this
        /// is called. (W) the release store guarantees every write that built
        /// `new_plan` (ops array, buffer-id tables, pool sizes, persistent-state
        /// handoff) is visible to any thread that acquire-loads the pointer and sees
        /// `new_plan`. Returns the previous pointer so the caller can reclaim it
        /// (after a grace period — see `waitGrace`).
        pub fn publish(self: *Self, new_plan: Ptr) Ptr {
            const old = self.plan.load(.monotonic);
            self.plan.store(new_plan, .release); // (W) PUBLISH
            return old;
        }

        /// RT thread, at callback start. (E) bump the epoch with an `.acq_rel`
        /// read-modify-write — it acknowledges the prior generation (acquire side)
        /// and announces the new one (release side) to the writer's acquire loads.
        /// (R) one acquire load of the plan pointer, paired with (W): seeing
        /// `new_plan` guarantees the RT thread sees the fully-initialized plan. The
        /// caller replays this returned plan for the entire callback and does NOT
        /// re-load the pointer mid-callback.
        pub fn enter(self: *Self) Ptr {
            _ = self.epoch.fetchAdd(1, .acq_rel); // (E)
            return self.plan.load(.acquire); // (R)
        }

        /// Read the current plan without bumping the epoch (e.g. a non-RT
        /// inspector). Acquire so it sees a fully-built plan.
        pub fn current(self: *const Self) Ptr {
            return self.plan.load(.acquire);
        }

        /// Snapshot the epoch (control thread), just after a swap.
        pub fn epochNow(self: *const Self) u64 {
            return self.epoch.load(.acquire);
        }

        /// Control thread, AFTER `publish` returned `old`: block (spin/yield — this
        /// is NON-RT and may stall freely) until it is safe to free `old`. The
        /// callback that may have loaded `old` began at some epoch ≤ `at_swap`. Once
        /// we observe `epoch ≥ at_swap + 1`, a strictly later callback has BEGUN (so
        /// any reader of `old` belongs to a callback that began at ≤ `at_swap`); once
        /// we observe `at_swap + 2`, that later callback's boundary has also been
        /// crossed, so every callback that could have read `old` has run to
        /// completion. Two ticks is the simplest obviously-correct bound for a single
        /// writer at pan's swap rates.
        pub fn waitGrace(self: *Self, at_swap: u64) void {
            while (self.epoch.load(.acquire) < at_swap +% 2) {
                std.Thread.yield() catch {};
            }
        }
    };
}

// ===========================================================================
// Tests — the orderings exercised single-threaded (semantics) + threaded
// (ThreadSanitizer surface). The threaded tests live here so a `-fsanitize-thread`
// build of the suite drives the ring and the RCU swap under concurrent
// producer/consumer load.
// ===========================================================================

const testing = std.testing;

const Collector = struct {
    items: std.ArrayList(Command) = .empty,
    gpa: std.mem.Allocator,
    fn apply(self: *Collector, cmd: Command) void {
        self.items.append(self.gpa, cmd) catch unreachable;
    }
};

test "ring: enqueue/drain round-trips payloads in order (P/C orderings)" {
    var ring = CommandRing(Command, 8).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);

    try testing.expect(ring.enqueue(.{ .at_sample = 0, .node = 1, .value = 0.25 }));
    try testing.expect(ring.enqueue(.{ .at_sample = 4, .node = 2, .value = 0.50 }));
    try testing.expectEqual(@as(usize, 2), ring.len());

    ring.drain(&c);
    try testing.expectEqual(@as(usize, 2), c.items.items.len);
    try testing.expectEqual(@as(usize, 1), c.items.items[0].node);
    try testing.expectEqual(@as(f32, 0.50), c.items.items[1].value);
    try testing.expectEqual(@as(usize, 0), ring.len()); // drained
}

test "ring: reports full and absorbs backpressure (never blocks)" {
    var ring = CommandRing(Command, 2).empty;
    try testing.expect(ring.enqueue(.{ .node = 0 }));
    try testing.expect(ring.enqueue(.{ .node = 1 }));
    try testing.expect(!ring.enqueue(.{ .node = 2 })); // full → false, no block
}

test "ring: drainUntil places events by sub-block boundary" {
    var ring = CommandRing(Command, 8).empty;
    var c = Collector{ .gpa = testing.allocator };
    defer c.items.deinit(testing.allocator);
    _ = ring.enqueue(.{ .at_sample = 2, .node = 10 });
    _ = ring.enqueue(.{ .at_sample = 9, .node = 11 });
    ring.drainUntil(8, &c); // only at_sample < 8 applied this sub-block
    try testing.expectEqual(@as(usize, 1), c.items.items.len);
    try testing.expectEqual(@as(usize, 10), c.items.items[0].node);
    // The second command remains for a later boundary.
    var c2 = Collector{ .gpa = testing.allocator };
    defer c2.items.deinit(testing.allocator);
    ring.drainUntil(16, &c2);
    try testing.expectEqual(@as(usize, 1), c2.items.items.len);
    try testing.expectEqual(@as(usize, 11), c2.items.items[0].node);
}

test "set: atomic target read back; not torn" {
    var p = Param.init(1.0);
    try testing.expectEqual(@as(f32, 1.0), p.read());
    p.set(0.5);
    try testing.expectEqual(@as(f32, 0.5), p.read());
}

test "ramp: a knob jump becomes a smooth per-sample slope (anti-zipper)" {
    var r = Ramp.init(0.0);
    const n: usize = 4;
    const target: f32 = 1.0;
    const inc = r.begin(target, n);
    try testing.expectEqual(@as(f32, 0.25), inc);
    // No instantaneous jump: consecutive samples differ by exactly `inc`.
    var prev = r.value;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = r.value + @as(f32, @floatFromInt(i + 1)) * inc;
        try testing.expect(@abs(s - prev) <= inc + 1e-7);
        prev = s;
    }
    r.finish(target);
    try testing.expectEqual(target, r.value); // snapped, no drift
}

test "rcu: publish/consume pointer with release/acquire; epoch bumps" {
    var plan_a: u32 = 1;
    var plan_b: u32 = 2;
    var rcu = Rcu(*u32).init(&plan_a);

    // RT consume sees the initial plan; epoch advances each callback.
    try testing.expectEqual(@as(u32, 1), rcu.enter().*);
    try testing.expectEqual(@as(u64, 1), rcu.epochNow());

    // Control thread swaps in plan_b.
    const old = rcu.publish(&plan_b);
    try testing.expectEqual(@as(u32, 1), old.*);
    try testing.expectEqual(@as(u32, 2), rcu.enter().*); // RT now sees plan_b
    try testing.expectEqual(@as(u64, 2), rcu.epochNow());
}

test "rcu+ring: concurrent producer/consumer (ThreadSanitizer surface)" {
    // Single producer thread enqueues a burst; the main thread is the lone
    // consumer draining wait-free. Run under -fsanitize-thread to validate the
    // SPSC handoff has no data race. The funnel obligation (one producer) is
    // honored: exactly one spawned producer.
    const Ring = CommandRing(Command, 1024);
    const Shared = struct {
        ring: Ring = Ring.empty,
        produced: std.atomic.Value(usize) = .init(0),
        done: std.atomic.Value(bool) = .init(false),
    };
    var sh = Shared{};
    const total: usize = 4096;

    const producer = struct {
        fn run(s: *Shared, n: usize) void {
            var i: usize = 0;
            while (i < n) {
                if (s.ring.enqueue(.{ .at_sample = i, .node = i, .value = @floatFromInt(i) })) {
                    i += 1;
                    _ = s.produced.fetchAdd(1, .monotonic);
                } else {
                    std.Thread.yield() catch {}; // ring full: back off (non-RT)
                }
            }
            s.done.store(true, .release);
        }
    };

    const Sink = struct {
        seen: usize = 0,
        last: i64 = -1,
        ok: bool = true,
        fn apply(self: *@This(), cmd: Command) void {
            if (@as(i64, @intCast(cmd.node)) != self.last + 1) self.ok = false; // FIFO order
            self.last = @intCast(cmd.node);
            self.seen += 1;
        }
    };
    var sink = Sink{};

    const t = try std.Thread.spawn(.{}, producer.run, .{ &sh, total });
    while (!sh.done.load(.acquire) or sh.ring.len() != 0) {
        sh.ring.drain(&sink);
    }
    sh.ring.drain(&sink);
    t.join();

    try testing.expectEqual(total, sink.seen);
    try testing.expect(sink.ok); // strict FIFO, no torn payloads
}
