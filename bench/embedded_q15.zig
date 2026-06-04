//! Benchmark: the P10 embedded q15 profile.
//!
//! Measures (never asserts an oracle): the q15 chain's static `.bss` footprint
//! (`footprint_bytes`, a comptime constant — the embedded SRAM budget) and op
//! count; and **q15-vs-f32 throughput** for the `Gain` and `Biquad` kernels (the
//! fixed-point path the embedded build runs vs the desktop float path). Real
//! on-device cycle counts are deferred to the concrete-MCU phase; this reports the
//! host-measured ns/iter the kernels achieve when monomorphized at each precision.
//! Build/run: `zig build bench` (ReleaseFast).

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const N = 256; // a representative device block
const warm = 1000;
const iters = 200_000;

fn benchGain(comptime T: type, io: std.Io, label: []const u8, gain: T) void {
    const num = pan.numericFor(precisionOf(T), .{});
    var in: [N]pan.types.Sample(T) = undefined;
    fill(T, &in);
    var out: [N]pan.types.Sample(T) = undefined;
    var blk = pan.filters.Gain(num){ .gain = gain };
    for (0..warm) |_| blk.process(&in, &out);
    var timer = h.Timer.start(io);
    for (0..iters) |_| blk.process(&in, &out);
    report(label, timer.read());
    h.consume(&out);
}

fn benchBiquad(comptime T: type, io: std.Io, label: []const u8, coeffs: pan.filters.Coeffs(T)) void {
    const num = pan.numericFor(precisionOf(T), .{});
    var in: [N]pan.types.Sample(T) = undefined;
    fill(T, &in);
    var out: [N]pan.types.Sample(T) = undefined;
    var blk = pan.filters.Biquad(num){ .coeffs = coeffs };
    for (0..warm) |_| blk.process(&in, &out);
    var timer = h.Timer.start(io);
    for (0..iters) |_| blk.process(&in, &out);
    report(label, timer.read());
    h.consume(&out);
}

fn report(label: []const u8, ns: u64) void {
    const ns_per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters));
    const fps = @as(f64, @floatFromInt(N)) / (ns_per / 1e9);
    std.debug.print("  {s}: {d:.1} ns/iter  {d:.2}M frames/s\n", .{ label, ns_per, fps / 1e6 });
}

fn precisionOf(comptime T: type) pan.Precision {
    return switch (T) {
        f32 => .f32,
        i16 => .i16,
        else => @compileError("unsupported bench lane"),
    };
}

fn fill(comptime T: type, buf: []pan.types.Sample(T)) void {
    var s: u64 = 0x1234_5678;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        if (T == f32) {
            x.* = .{ .ch = .{@as(f32, @floatFromInt(@as(i32, @intCast((s >> 50) & 0x3FFF)) - 8192)) / 8192.0} };
        } else {
            x.* = .{ .ch = .{@intCast(@as(i32, @intCast((s >> 50) & 0x3FFF)) - 8192)} };
        }
    }
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("== P10 embedded q15 profile ==\n", .{});

    // Footprint: the static .bss budget for the embedded chain (comptime constant).
    std.debug.print("footprint (.bss, comptime): q15 chain op_count={d} footprint_bytes={d} (lane={d}B, N={d})\n", .{
        pan.embedded.Exec.committed.op_count,
        pan.embedded.footprint_bytes,
        @sizeOf(pan.types.Sample(i16)),
        pan.embedded.N,
    });

    // q15-vs-f32 throughput for the two embedded-chain kernels.
    const f32_coeffs = pan.filters.Coeffs(f32){ .b0 = 0.0061, .b1 = 0.0122, .b2 = 0.0061, .a1 = -1.709, .a2 = 0.793 };
    const q15_coeffs = pan.filters.Coeffs(i16){ .b0 = 50, .b1 = 100, .b2 = 50, .a1 = -14000, .a2 = 6500 };
    std.debug.print("throughput (Gain):\n", .{});
    benchGain(f32, io, "gain  f32", 0.8);
    benchGain(i16, io, "gain  q15", 26214);
    std.debug.print("throughput (Biquad):\n", .{});
    benchBiquad(f32, io, "biquad f32", f32_coeffs);
    benchBiquad(i16, io, "biquad q15", q15_coeffs);
}
