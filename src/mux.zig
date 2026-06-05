//! The `SampleMux` seam — the only coupling between a block and its transport.
//! A fixed 10-method vtable; a block's `process`/`pull` is handed slices by a
//! mux and never knows whether those slices are a private double-buffer, a
//! coalesced pool buffer, or a ring. This is the only reason the same block runs
//! unchanged under push, pull, and offline transports.
//!
//! Implemented as the type-erased `ptr + vtable` idiom. The element type is
//! erased to `[]u8` byte-slices at the seam; the block's typed wrapper recovers
//! `[]A`.
//!
//! These realisations are single-port-per-direction: the `port` index is part of
//! the fixed seam signature, and it is HONOURED, not silently ignored — every
//! method asserts `port == 0`, so wiring a multi-port block through one of these
//! before a real multi-port transport exists fails loud (in safe builds) rather
//! than quietly returning port-0's buffer. Per-port demultiplexing arrives with
//! the demand-tracking executor and the first multi-port block; until then the
//! one-port contract is explicit and checked.

const std = @import("std");

/// The 10-method `SampleMux` vtable. Methods are type-erased (a `*anyopaque`
/// instance pointer); buffers are byte slices at the seam.
pub const SampleMux = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // 1–2: availability / blocking.
        waitInputAvailable: *const fn (ptr: *anyopaque, port: usize, n: usize) void,
        getInputAvailable: *const fn (ptr: *anyopaque, port: usize) usize,
        getOutputAvailable: *const fn (ptr: *anyopaque, port: usize) usize,
        // 4–5: buffer access.
        getInputBuffer: *const fn (ptr: *anyopaque, port: usize) []const u8,
        getOutputBuffer: *const fn (ptr: *anyopaque, port: usize) []u8,
        // 6–7: cursor commit.
        updateInputBuffer: *const fn (ptr: *anyopaque, port: usize, n: usize) void,
        updateOutputBuffer: *const fn (ptr: *anyopaque, port: usize, n: usize) void,
        // 8: wait an output buffer becomes writable.
        waitOutputAvailable: *const fn (ptr: *anyopaque, port: usize, n: usize) void,
        // 9: fan-out reader count.
        getNumReadersForOutput: *const fn (ptr: *anyopaque, port: usize) usize,
        // 10: end-of-stream.
        setEOS: *const fn (ptr: *anyopaque) void,
    };

    // Thin dispatch wrappers (callers never touch the vtable directly).
    pub fn waitInputAvailable(self: SampleMux, port: usize, n: usize) void {
        self.vtable.waitInputAvailable(self.ptr, port, n);
    }
    pub fn getInputAvailable(self: SampleMux, port: usize) usize {
        return self.vtable.getInputAvailable(self.ptr, port);
    }
    pub fn getOutputAvailable(self: SampleMux, port: usize) usize {
        return self.vtable.getOutputAvailable(self.ptr, port);
    }
    pub fn getInputBuffer(self: SampleMux, port: usize) []const u8 {
        return self.vtable.getInputBuffer(self.ptr, port);
    }
    pub fn getOutputBuffer(self: SampleMux, port: usize) []u8 {
        return self.vtable.getOutputBuffer(self.ptr, port);
    }
    pub fn updateInputBuffer(self: SampleMux, port: usize, n: usize) void {
        self.vtable.updateInputBuffer(self.ptr, port, n);
    }
    pub fn updateOutputBuffer(self: SampleMux, port: usize, n: usize) void {
        self.vtable.updateOutputBuffer(self.ptr, port, n);
    }
    pub fn waitOutputAvailable(self: SampleMux, port: usize, n: usize) void {
        self.vtable.waitOutputAvailable(self.ptr, port, n);
    }
    pub fn getNumReadersForOutput(self: SampleMux, port: usize) usize {
        return self.vtable.getNumReadersForOutput(self.ptr, port);
    }
    pub fn setEOS(self: SampleMux) void {
        self.vtable.setEOS(self.ptr);
    }
};

/// `TestSampleMux` — feeds exact bytes from caller-owned input slices and
/// exposes caller-owned output slices. It *defines* behaviour for the
/// gold-vector oracle. Single-port-per-direction skeleton (sufficient for the
/// tracer bullet).
pub const TestSampleMux = struct {
    input: []const u8,
    output: []u8,
    eos: bool = false,

    const Self = @This();

    pub fn sampleMux(self: *Self) SampleMux {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = SampleMux.VTable{
        .waitInputAvailable = waitInputAvailable,
        .getInputAvailable = getInputAvailable,
        .getOutputAvailable = getOutputAvailable,
        .getInputBuffer = getInputBuffer,
        .getOutputBuffer = getOutputBuffer,
        .updateInputBuffer = updateInputBuffer,
        .updateOutputBuffer = updateOutputBuffer,
        .waitOutputAvailable = waitOutputAvailable,
        .getNumReadersForOutput = getNumReadersForOutput,
        .setEOS = setEOS,
    };

    fn waitInputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn getInputAvailable(ptr: *anyopaque, port: usize) usize {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.input.len;
    }
    fn getOutputAvailable(ptr: *anyopaque, port: usize) usize {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.output.len;
    }
    fn getInputBuffer(ptr: *anyopaque, port: usize) []const u8 {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.input;
    }
    fn getOutputBuffer(ptr: *anyopaque, port: usize) []u8 {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.output;
    }
    fn updateInputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn updateOutputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn waitOutputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn getNumReadersForOutput(ptr: *anyopaque, port: usize) usize {
        _ = ptr;
        std.debug.assert(port == 0);
        return 1;
    }
    fn setEOS(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.eos = true;
    }
};

/// `PullSampleMux` skeleton — the synchronous-pull executor seam.
/// `waitInputAvailable` returns immediately (upstream was rendered first, so
/// exactly N is present); `update*` are no-ops (single-shot render, liveness
/// already known). Buffers slice into pool buffers handed in by the engine; here
/// a flat byte arena stands in for the colored pool.
pub const PullSampleMux = struct {
    in_buf: []const u8,
    out_buf: []u8,

    const Self = @This();

    pub fn sampleMux(self: *Self) SampleMux {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = SampleMux.VTable{
        .waitInputAvailable = waitInputAvailable,
        .getInputAvailable = getInputAvailable,
        .getOutputAvailable = getOutputAvailable,
        .getInputBuffer = getInputBuffer,
        .getOutputBuffer = getOutputBuffer,
        .updateInputBuffer = updateInputBuffer,
        .updateOutputBuffer = updateOutputBuffer,
        .waitOutputAvailable = waitOutputAvailable,
        .getNumReadersForOutput = getNumReadersForOutput,
        .setEOS = setEOS,
    };

    // Pull semantics: wait* return immediately, update* are no-ops.
    fn waitInputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn waitOutputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn getInputAvailable(ptr: *anyopaque, port: usize) usize {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.in_buf.len;
    }
    fn getOutputAvailable(ptr: *anyopaque, port: usize) usize {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.out_buf.len;
    }
    fn getInputBuffer(ptr: *anyopaque, port: usize) []const u8 {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.in_buf;
    }
    fn getOutputBuffer(ptr: *anyopaque, port: usize) []u8 {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.out_buf;
    }
    fn updateInputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn updateOutputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn getNumReadersForOutput(ptr: *anyopaque, port: usize) usize {
        _ = ptr;
        std.debug.assert(port == 0);
        return 1;
    }
    fn setEOS(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// `PullTestSampleMux` — the dual-mux partner of `TestSampleMux` under pull
/// semantics, so every block is exercised under BOTH push and pull (a surface
/// leak between the two interpretations is caught here). Same
/// caller-owned slices as `TestSampleMux`; `wait*` return immediately and
/// `update*` advance the cursor. The full demand-tracking executor lives in the
/// test backbone phase; this is the seam type.
pub const PullTestSampleMux = struct {
    input: []const u8,
    output: []u8,
    in_cursor: usize = 0,
    out_cursor: usize = 0,
    eos: bool = false,

    const Self = @This();

    pub fn sampleMux(self: *Self) SampleMux {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = SampleMux.VTable{
        .waitInputAvailable = waitInputAvailable,
        .getInputAvailable = getInputAvailable,
        .getOutputAvailable = getOutputAvailable,
        .getInputBuffer = getInputBuffer,
        .getOutputBuffer = getOutputBuffer,
        .updateInputBuffer = updateInputBuffer,
        .updateOutputBuffer = updateOutputBuffer,
        .waitOutputAvailable = waitOutputAvailable,
        .getNumReadersForOutput = getNumReadersForOutput,
        .setEOS = setEOS,
    };

    fn waitInputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn waitOutputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        std.debug.assert(port == 0);
        _ = n;
    }
    fn getInputAvailable(ptr: *anyopaque, port: usize) usize {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.input.len - self.in_cursor;
    }
    fn getOutputAvailable(ptr: *anyopaque, port: usize) usize {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.output.len - self.out_cursor;
    }
    fn getInputBuffer(ptr: *anyopaque, port: usize) []const u8 {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.input[self.in_cursor..];
    }
    fn getOutputBuffer(ptr: *anyopaque, port: usize) []u8 {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.output[self.out_cursor..];
    }
    fn updateInputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.in_cursor += n;
    }
    fn updateOutputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.out_cursor += n;
    }
    fn getNumReadersForOutput(ptr: *anyopaque, port: usize) usize {
        _ = ptr;
        std.debug.assert(port == 0);
        return 1;
    }
    fn setEOS(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.eos = true;
    }
};

/// `Ring` — a bounded single-producer/single-consumer block channel: the offline
/// push transport's substance. The storage is `depth` fixed-size slots of
/// `slot_bytes` each; the producer publishes a slot and advances `tail`, the
/// consumer reads a slot and advances `head`. There is **one writer of `tail`+
/// `eos`** (the producing stage) and **one writer of `head`** (the consuming
/// stage), so the cursors need no lock — release/acquire ordering alone publishes
/// a full slot before it is read. Offline has no deadline (O1), so a full ring
/// blocks the producer and an empty one blocks the consumer by spin-then-yield;
/// the depth bounds the footprint (O2). A wait returns when its condition holds
/// OR (for the consumer) the stream has ended and drained.
pub const Ring = struct {
    storage: []u8,
    slot_bytes: usize,
    depth: usize,
    /// Slots published by the producer (monotone; `tail − head` is the fill).
    tail: std.atomic.Value(usize) = .init(0),
    /// Slots consumed by the consumer (monotone).
    head: std.atomic.Value(usize) = .init(0),
    /// Set once by the producer after the last slot; lets the consumer's wait
    /// return `null` instead of spinning forever on a drained, ended stream.
    eos: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: std.mem.Allocator, slot_bytes: usize, depth: usize) !Ring {
        const storage = try alloc.alloc(u8, slot_bytes * depth);
        return .{ .storage = storage, .slot_bytes = slot_bytes, .depth = depth };
    }
    pub fn deinit(self: *Ring, alloc: std.mem.Allocator) void {
        alloc.free(self.storage);
        self.* = undefined;
    }

    fn slotAt(self: *Ring, idx: usize) []u8 {
        const off = (idx % self.depth) * self.slot_bytes;
        return self.storage[off .. off + self.slot_bytes];
    }

    // --- producer side (single writer of `tail`/`eos`) --------------------

    /// Block until a free slot exists, then return it for writing. The slot's
    /// bytes are not yet visible to the consumer; `commitProduce` publishes them.
    pub fn produceSlot(self: *Ring) []u8 {
        while (true) {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t - h < self.depth) return self.slotAt(t);
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
    /// Publish the slot returned by the last `produceSlot` (release so the
    /// consumer's acquire-load of `tail` also sees the slot's written bytes).
    pub fn commitProduce(self: *Ring) void {
        self.tail.store(self.tail.load(.monotonic) + 1, .release);
    }
    /// Signal end of stream (after the final `commitProduce`).
    pub fn setEos(self: *Ring) void {
        self.eos.store(true, .release);
    }

    // --- consumer side (single writer of `head`) --------------------------

    /// Block until a published slot exists and return it for reading, or `null`
    /// when the stream has ended and every slot has been consumed.
    ///
    /// `eos` is observed BEFORE the `tail` it gates on (and both are acquire
    /// loads). `eos` and `tail` are independent locations, and release/acquire
    /// synchronises per location, so reading a stale `tail` and then a fresh
    /// `eos` would let the EOS flag overtake the producer's final
    /// `commitProduce` and drop the last slot. Loading `eos` first means a
    /// `true` observation's happens-before (the producer's `setEos` follows its
    /// last `commitProduce`) covers the subsequent `tail` load, so an empty
    /// `tail` read after `eos == true` is the genuinely-drained state.
    pub fn consumeSlot(self: *Ring) ?[]const u8 {
        while (true) {
            const h = self.head.load(.monotonic);
            const eos_seen = self.eos.load(.acquire);
            const t = self.tail.load(.acquire);
            if (t - h > 0) return self.slotAt(h);
            if (eos_seen) return null;
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
    /// Release the slot returned by the last `consumeSlot`.
    pub fn commitConsume(self: *Ring) void {
        self.head.store(self.head.load(.monotonic) + 1, .release);
    }

    /// Published-but-unconsumed slot count (an acquire load of `tail`, monotonic
    /// of the consumer-owned `head`). For the consumer's own use.
    pub fn pending(self: *Ring) usize {
        return self.tail.load(.acquire) - self.head.load(.monotonic);
    }
    /// Free slot count from the producer's view (an acquire load of `head`).
    pub fn vacant(self: *Ring) usize {
        return self.depth - (self.tail.load(.monotonic) - self.head.load(.acquire));
    }
    pub fn ended(self: *Ring) bool {
        return self.eos.load(.acquire);
    }
};

/// `RingSampleMux` — the offline push transport (Tier C / OfflineBatch) as a
/// `SampleMux`. It adapts an upstream `in_ring` and a downstream `out_ring` (the
/// bounded SPSC `Ring`s above; either may be `null` at a source/sink endpoint) to
/// the fixed 10-method seam, so a pipeline stage's `process` is driven by exactly
/// the same vtable as under push/pull — the slices it receives are `Ring` slots,
/// one block per call. `waitInputAvailable`/`getInputBuffer` surface one published
/// input slot, `getOutputBuffer`/`updateOutputBuffer` reserve and publish one
/// output slot. `getInputAvailable` returns 0 once the input stream has ended and
/// drained, which is the stage loop's stop signal. No deadline (O1): a wait spins
/// then yields until its slot (or EOS) appears; the ring depth bounds buffering
/// (O2). This is the ZigRadio-shaped push transport the offline pipeline runs on.
pub const RingSampleMux = struct {
    in_ring: ?*Ring = null,
    out_ring: ?*Ring = null,

    const Self = @This();

    pub fn sampleMux(self: *Self) SampleMux {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = SampleMux.VTable{
        .waitInputAvailable = waitInputAvailable,
        .getInputAvailable = getInputAvailable,
        .getOutputAvailable = getOutputAvailable,
        .getInputBuffer = getInputBuffer,
        .getOutputBuffer = getOutputBuffer,
        .updateInputBuffer = updateInputBuffer,
        .updateOutputBuffer = updateOutputBuffer,
        .waitOutputAvailable = waitOutputAvailable,
        .getNumReadersForOutput = getNumReadersForOutput,
        .setEOS = setEOS,
    };

    fn waitInputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        std.debug.assert(port == 0);
        _ = n; // one slot at a time
        const self: *Self = @ptrCast(@alignCast(ptr));
        const r = self.in_ring orelse return;
        // Block until a slot is published, or the stream ends and drains.
        while (r.pending() == 0 and !r.ended()) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
    fn waitOutputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        std.debug.assert(port == 0);
        _ = n;
        const self: *Self = @ptrCast(@alignCast(ptr));
        const r = self.out_ring orelse return;
        while (r.vacant() == 0) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }
    fn getInputAvailable(ptr: *anyopaque, port: usize) usize {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        const r = self.in_ring orelse return 0;
        return if (r.pending() > 0) r.slot_bytes else 0;
    }
    fn getOutputAvailable(ptr: *anyopaque, port: usize) usize {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        const r = self.out_ring orelse return 0;
        return if (r.vacant() > 0) r.slot_bytes else 0;
    }
    fn getInputBuffer(ptr: *anyopaque, port: usize) []const u8 {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        const r = self.in_ring orelse return &.{};
        return r.slotAt(r.head.load(.monotonic));
    }
    fn getOutputBuffer(ptr: *anyopaque, port: usize) []u8 {
        std.debug.assert(port == 0);
        const self: *Self = @ptrCast(@alignCast(ptr));
        const r = self.out_ring orelse return &.{};
        return r.slotAt(r.tail.load(.monotonic));
    }
    fn updateInputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        std.debug.assert(port == 0);
        _ = n;
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.in_ring) |r| r.commitConsume();
    }
    fn updateOutputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        std.debug.assert(port == 0);
        _ = n;
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.out_ring) |r| r.commitProduce();
    }
    fn getNumReadersForOutput(ptr: *anyopaque, port: usize) usize {
        _ = ptr;
        std.debug.assert(port == 0);
        return 1;
    }
    fn setEOS(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.out_ring) |r| r.setEos();
    }
};

test "TestSampleMux feeds slices through the 10-method vtable" {
    var in = [_]u8{ 1, 2, 3, 4 };
    var out = [_]u8{ 0, 0, 0, 0 };
    var tm = TestSampleMux{ .input = &in, .output = &out };
    const mux = tm.sampleMux();

    mux.waitInputAvailable(0, 4); // returns immediately
    try std.testing.expectEqual(@as(usize, 4), mux.getInputAvailable(0));
    try std.testing.expectEqual(@as(usize, 4), mux.getOutputAvailable(0));
    try std.testing.expectEqual(@as(usize, 1), mux.getNumReadersForOutput(0));

    const src = mux.getInputBuffer(0);
    const dst = mux.getOutputBuffer(0);
    @memcpy(dst, src);
    mux.updateOutputBuffer(0, 4); // no-op commit
    try std.testing.expectEqualSlices(u8, &in, &out);

    mux.setEOS();
    try std.testing.expect(tm.eos);
}

test "PullTestSampleMux advances cursors through the same vtable" {
    var in = [_]u8{ 9, 8, 7 };
    var out = [_]u8{ 0, 0, 0 };
    var pm = PullTestSampleMux{ .input = &in, .output = &out };
    const mux = pm.sampleMux();
    try std.testing.expectEqual(@as(usize, 3), mux.getInputAvailable(0));
    const dst = mux.getOutputBuffer(0);
    @memcpy(dst, mux.getInputBuffer(0));
    mux.updateInputBuffer(0, 3);
    mux.updateOutputBuffer(0, 3);
    try std.testing.expectEqual(@as(usize, 0), mux.getInputAvailable(0));
    try std.testing.expectEqualSlices(u8, &in, &out);
}

test "RingSampleMux drives an interior stage over real rings (the offline push seam)" {
    const gpa = std.testing.allocator;
    var in_ring = try Ring.init(gpa, 4, 4);
    defer in_ring.deinit(gpa);
    var out_ring = try Ring.init(gpa, 4, 4);
    defer out_ring.deinit(gpa);

    // Seed one input slot upstream, then end the input stream.
    @memcpy(in_ring.produceSlot(), &[_]u8{ 1, 2, 3, 4 });
    in_ring.commitProduce();
    in_ring.setEos();

    var m = RingSampleMux{ .in_ring = &in_ring, .out_ring = &out_ring };
    const mux = m.sampleMux();

    mux.waitInputAvailable(0, 4);
    try std.testing.expectEqual(@as(usize, 4), mux.getInputAvailable(0));
    try std.testing.expectEqual(@as(usize, 1), mux.getNumReadersForOutput(0));
    mux.waitOutputAvailable(0, 4);
    @memcpy(mux.getOutputBuffer(0), mux.getInputBuffer(0)); // identity stage
    mux.updateInputBuffer(0, 4);
    mux.updateOutputBuffer(0, 4);
    mux.setEOS();

    // Next input wait returns with nothing available (ended & drained) — the stop signal.
    mux.waitInputAvailable(0, 4);
    try std.testing.expectEqual(@as(usize, 0), mux.getInputAvailable(0));

    const got = out_ring.consumeSlot() orelse return error.Unexpected;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, got);
    try std.testing.expect(out_ring.ended());
}

test "Ring publishes a slot from producer to consumer, then drains on EOS" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, 4, 2); // two 4-byte slots
    defer ring.deinit(gpa);

    // Producer publishes one slot.
    const w = ring.produceSlot();
    @memcpy(w, &[_]u8{ 9, 8, 7, 6 });
    ring.commitProduce();
    ring.setEos();

    // Consumer reads it, then sees the drained-and-ended stream as null.
    const r = ring.consumeSlot() orelse return error.Unexpected;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 6 }, r);
    ring.commitConsume();
    try std.testing.expect(ring.consumeSlot() == null);
}

test "Ring carries blocks across a producer and a consumer thread, in order" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, @sizeOf(u32), 4);
    defer ring.deinit(gpa);
    const Ctx = struct {
        ring: *Ring,
        fn produce(r: *Ring) void {
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                const slot = r.produceSlot();
                @memcpy(slot, std.mem.asBytes(&i));
                r.commitProduce();
            }
            r.setEos();
        }
    };
    const t = try std.Thread.spawn(.{}, Ctx.produce, .{&ring});
    var expect: u32 = 0;
    while (ring.consumeSlot()) |slot| {
        const got = std.mem.bytesToValue(u32, slot);
        try std.testing.expectEqual(expect, got);
        ring.commitConsume();
        expect += 1;
    }
    t.join();
    try std.testing.expectEqual(@as(u32, 100), expect);
}
