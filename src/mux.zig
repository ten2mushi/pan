//! The `SampleMux` seam (catalog §4.1, exec §3) — the only coupling between a
//! block and its transport. A fixed 10-method vtable; a block's
//! `process`/`pull` is handed slices by a mux and never knows whether those
//! slices are a private double-buffer, a coalesced pool buffer, or a ring.
//!
//! This is the `ptr + vtable` idiom (skill ch.12). Element type is erased to
//! `[]u8` byte-slices at the seam; the block's typed wrapper recovers `[]A`.

const std = @import("std");

/// The 10-method `SampleMux` vtable (catalog §4.1). Methods are type-erased
/// (a `*anyopaque` instance pointer); buffers are byte slices at the seam.
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

/// `TestSampleMux` (catalog §4.1) — feeds exact bytes from caller-owned input
/// slices and exposes caller-owned output slices. *Defines* behaviour for the
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
        _ = port;
        _ = n;
    }
    fn getInputAvailable(ptr: *anyopaque, port: usize) usize {
        _ = port;
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.input.len;
    }
    fn getOutputAvailable(ptr: *anyopaque, port: usize) usize {
        _ = port;
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.output.len;
    }
    fn getInputBuffer(ptr: *anyopaque, port: usize) []const u8 {
        _ = port;
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.input;
    }
    fn getOutputBuffer(ptr: *anyopaque, port: usize) []u8 {
        _ = port;
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.output;
    }
    fn updateInputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        _ = port;
        _ = n;
    }
    fn updateOutputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        _ = port;
        _ = n;
    }
    fn waitOutputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        _ = port;
        _ = n;
    }
    fn getNumReadersForOutput(ptr: *anyopaque, port: usize) usize {
        _ = ptr;
        _ = port;
        return 1;
    }
    fn setEOS(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.eos = true;
    }
};

/// `PullSampleMux` skeleton (catalog §4.1, exec §3) — the synchronous-pull
/// executor seam. `waitInputAvailable` returns immediately (upstream was
/// rendered first, so exactly N is present); `update*` are no-ops (single-shot
/// render, liveness already known). Buffers slice into pool buffers handed in
/// by the engine; here a flat byte arena stands in for the colored pool.
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

    // Pull semantics (exec §3): wait* return immediately, update* are no-ops.
    fn waitInputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        _ = port;
        _ = n;
    }
    fn waitOutputAvailable(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        _ = port;
        _ = n;
    }
    fn getInputAvailable(ptr: *anyopaque, port: usize) usize {
        _ = port;
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.in_buf.len;
    }
    fn getOutputAvailable(ptr: *anyopaque, port: usize) usize {
        _ = port;
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.out_buf.len;
    }
    fn getInputBuffer(ptr: *anyopaque, port: usize) []const u8 {
        _ = port;
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.in_buf;
    }
    fn getOutputBuffer(ptr: *anyopaque, port: usize) []u8 {
        _ = port;
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.out_buf;
    }
    fn updateInputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        _ = port;
        _ = n;
    }
    fn updateOutputBuffer(ptr: *anyopaque, port: usize, n: usize) void {
        _ = ptr;
        _ = port;
        _ = n;
    }
    fn getNumReadersForOutput(ptr: *anyopaque, port: usize) usize {
        _ = ptr;
        _ = port;
        return 1;
    }
    fn setEOS(ptr: *anyopaque) void {
        _ = ptr;
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
