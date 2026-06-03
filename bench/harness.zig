//! The benchmark measurement kit — the bench analogue of `tests/harness.zig`.
//!
//! A benchmark MEASURES; it never asserts an oracle match (correctness stays in
//! `tests/` under the ⊢/≈/▷ tiers). This kit holds the measurement primitives the
//! `bench/*.zig` drivers share, kept self-contained:
//!
//!   - a monotonic wall-clock timer over `std.Io.Clock` (`std.time.Timer` was
//!     removed in 0.16);
//!   - a result-consuming sink (`consume`) that defeats dead-code elimination so
//!     the optimizer cannot delete the timed work;
//!   - an instrumented counting allocator that reports bytes/allocations, so a
//!     "zero hot-path allocation" claim is measurable;
//!   - the metric reporter — frames/s, MB/s, × realtime, deadline headroom — and
//!     a byte-displacement helper (Σ over the op-list of bytes read + written per
//!     render), the dynamic cache traffic that coloring / fusion reduce.
//!
//! Carries NO `test {}` blocks (it is imported by several bench drivers).
//! Benchmark only in the shipped release modes; warm up; run many iterations;
//! report ns/iter; consume every result.

const std = @import("std");
const pan = @import("pan");

/// A monotonic timer over the 0.16 `std.Io.Clock` (the `std.time.Timer`
/// replacement). Construct with an `Io`, `start()` to mark, `read()` for elapsed
/// nanoseconds since the mark.
pub const Timer = struct {
    io: std.Io,
    mark: std.Io.Clock.Timestamp,

    pub fn start(io: std.Io) Timer {
        return .{ .io = io, .mark = std.Io.Clock.Timestamp.now(io, .awake) };
    }
    pub fn reset(self: *Timer) void {
        self.mark = std.Io.Clock.Timestamp.now(self.io, .awake);
    }
    /// Nanoseconds elapsed since the last start/reset.
    pub fn read(self: *Timer) u64 {
        return @intCast(self.mark.untilNow(self.io).raw.toNanoseconds());
    }
};

/// Consume a value so the optimizer cannot delete the work that produced it.
pub fn consume(x: anytype) void {
    std.mem.doNotOptimizeAway(x);
}

/// An allocator wrapper that counts bytes and allocation calls, so a bench can
/// assert (by reading, not by `assert`) that a hot path allocated nothing.
pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    bytes: usize = 0,
    allocs: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };
    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.bytes += len;
        self.allocs += 1;
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ra);
    }
    fn resizeFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.vtable.resize(self.child.ptr, mem, alignment, new_len, ra);
    }
    fn remapFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.vtable.remap(self.child.ptr, mem, alignment, new_len, ra);
    }
    fn freeFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, mem, alignment, ra);
    }
};

/// Byte displacement per render: Σ over the op-list of the bytes each op reads
/// (its input buffers) plus writes (its output buffers). The dynamic cache
/// traffic — distinct from the static footprint — that coloring and fusion move.
pub fn byteDisplacement(comptime n_ops: usize, plan: *const pan.commit.Plan(n_ops)) usize {
    var total: usize = 0;
    for (plan.ops[0..plan.op_count]) |op| {
        for (op.input_buffer_ids[0..op.input_count]) |id| total += plan.buffer_byte_len[id];
        for (op.output_buffer_ids[0..op.output_count]) |id| total += plan.buffer_byte_len[id];
    }
    return total;
}

/// Print one throughput line for a render benchmark.
pub fn reportRender(
    label: []const u8,
    ns_total: u64,
    iters: usize,
    frames_per_render: usize,
    channels: usize,
    bytes_per_frame: usize,
    sample_rate: u32,
    footprint_bytes: usize,
    displacement_bytes: usize,
) void {
    const ns_per: f64 = @as(f64, @floatFromInt(ns_total)) / @as(f64, @floatFromInt(iters));
    const frames: f64 = @floatFromInt(frames_per_render);
    const frames_per_s = frames / (ns_per / 1e9);
    const mb_per_s = frames_per_s * @as(f64, @floatFromInt(channels * bytes_per_frame)) / (1024.0 * 1024.0);
    const deadline_ns = frames / @as(f64, @floatFromInt(sample_rate)) * 1e9;
    const headroom = (deadline_ns - ns_per) / deadline_ns * 100.0;
    const x_realtime = deadline_ns / ns_per;
    std.debug.print(
        "{s}: {d:.1} ns/render  {d:.2}M frames/s  {d:.1} MB/s  {d:.1}x realtime  headroom {d:.1}%  footprint {d}B  displacement {d}B/render\n",
        .{ label, ns_per, frames_per_s / 1e6, mb_per_s, x_realtime, headroom, footprint_bytes, displacement_bytes },
    );
}
