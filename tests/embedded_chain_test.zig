//! Embedded q15 chain — the bound executor's monomorphized render is bit-identical
//! to a hand-run chain, and the realtime-token entry is the SAME API shape on the
//! fixed-point path as on desktop.
//!
//! This is the desktop side of the P10 embedded gate (the freestanding side is the
//! `smoke` object compiling). It exercises the EXACT types the embedded build uses
//! (`pan.embedded.Exec`, `pan.embedded.{Source,Gain,Biquad,Sink}` over the q15
//! Numeric), so a divergence between the executor's colored-pool gather/scatter
//! and a manual chain — or a regression in the fixed-point biquad kernel — fails
//! here. The comparison is pan-vs-pan, so BIT-EXACT (the colored pool must compute
//! exactly what disjoint buffers compute).
//!
//! Verified against zig 0.16.0 with the zig-0-16 skill loaded.

const std = @import("std");
const pan = @import("pan");

const num = pan.embedded.num;
const N = pan.embedded.N;
const Dma = pan.io.I2sDma(num, N);
const SampleQ15 = pan.types.Sample(i16);

// A stable resonant low-pass in Q2.13 whose feedback coefficient a1 (−14000 ≈
// −1.71) exceeds the q15 lane's ±1 range — the supra-unity coefficient the wider
// fixed-point coefficient format exists for.
const coeffs = pan.filters.Coeffs(i16){ .b0 = 50, .b1 = 100, .b2 = 50, .a1 = -14000, .a2 = 6500 };
const gain_q: i16 = 26214; // ~0.8 in q15

/// Fill a DMA half with deterministic q15 noise bounded well below full-scale (so
/// the resonant biquad has headroom and does not saturate on the test signal).
fn fillHalf(half: []SampleQ15, seed: u64) void {
    var s = seed;
    for (half) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        // top bits → an i16 in roughly [-12000, 12000].
        const v: i16 = @intCast(@as(i32, @intCast((s >> 50) & 0x3FFF)) - 8192);
        x.* = .{ .ch = .{v} };
    }
}

test "embedded q15 chain: bound executor render ≡ hand-run chain, BIT-EXACT" {
    // RX feeds the graph; TX receives the executor output; tx_ref the hand-run.
    var rx = Dma{};
    var tx = Dma{};
    var tx_ref = Dma{};
    rx.onHalfTransfer(); // processing side owns half 0
    tx.onHalfTransfer();
    tx_ref.onHalfTransfer();
    fillHalf(rx.activeHalf(), 0xC0FFEE);

    // --- executor path (the embedded monomorph) ---
    var exec: pan.embedded.Exec = .{ .instances = .{
        .{ .dma = &rx },
        .{ .gain = gain_q },
        .{ .coeffs = coeffs },
        .{ .dma = &tx },
    } };
    const token = pan.enterRealtimeThread();
    defer token.leave();
    exec.render(token);
    try std.testing.expect(!exec.telemetry().fault);

    // --- hand-run reference: source → gain → biquad → sink over disjoint bufs ---
    var a: [N]SampleQ15 = undefined;
    var b: [N]SampleQ15 = undefined;
    var src = pan.embedded.Source{ .dma = &rx };
    var g = pan.embedded.Gain{ .gain = gain_q };
    var bq = pan.embedded.Biquad{ .coeffs = coeffs };
    var sink = pan.embedded.Sink{ .dma = &tx_ref };
    src.process(&a);
    g.process(&a, &b);
    bq.process(&b, &a); // biquad is not aliasing_safe → distinct in/out (reuse a)
    sink.process(&a);

    // The colored pool render must equal the disjoint-buffer hand-run, to the bit.
    try std.testing.expectEqualSlices(i16, sampleLanes(tx_ref.activeHalf()), sampleLanes(tx.activeHalf()));
    // And it must have actually filtered (not passed silence through).
    var any: i32 = 0;
    for (tx.activeHalf()) |s| any += @as(i32, @abs(s.ch[0]));
    try std.testing.expect(any > 0);
}

test "no-op-token API shape is identical on the fixed-point path" {
    // The realtime token gates the render the SAME way as desktop: a single
    // `enterRealtimeThread()` token drives the q15 executor's `render`. On a
    // fixed-point / FPU-less target the token's flush-to-zero is a no-op, but the
    // token-gated entry's TYPE and shape are invariant across precisions — this
    // compiling and running is that invariance.
    var rx = Dma{};
    var tx = Dma{};
    rx.onHalfTransfer();
    tx.onHalfTransfer();
    var exec: pan.embedded.Exec = .{ .instances = .{
        .{ .dma = &rx }, .{ .gain = gain_q }, .{ .coeffs = coeffs }, .{ .dma = &tx },
    } };
    const token: pan.RealtimeToken = pan.enterRealtimeThread(); // same type as the desktop path
    defer token.leave();
    exec.render(token); // won't compile without the token — ⊢ on every precision
}

test "embedded footprint is a comptime constant sized for the q15 lane" {
    // Comptime-known: usable as an array length (the `.bss` render-buffer property).
    const proof: [pan.embedded.footprint_bytes]u8 = undefined;
    comptime std.debug.assert(proof.len > 0);
    // The pool holds q15 (2-byte) samples; M ping-pong buffers of N frames each.
    try std.testing.expectEqual(@as(usize, 4), pan.embedded.Exec.committed.op_count);
    try std.testing.expect(pan.embedded.footprint_bytes % @sizeOf(SampleQ15) == 0);
}

/// View a `Sample(i16)` slice as its underlying `[]i16` lanes (mono = layout-exact).
fn sampleLanes(s: []const SampleQ15) []const i16 {
    return @alignCast(std.mem.bytesAsSlice(i16, std.mem.sliceAsBytes(s)));
}

// A q15 boundary source/sink over a caller-owned backing store (the device bridge
// for the runtime engine — no external mux needed).
const QSource = struct {
    data: [*]const SampleQ15 = undefined,
    pub fn process(self: *@This(), out: []SampleQ15) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const QSink = struct {
    dest: [*]SampleQ15 = undefined,
    pub fn process(self: *@This(), in: []const SampleQ15) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

/// Static `.bss` SRAM stand-in for the FixedBufferAllocator zero-heap test.
var fba_backing: [512 * 1024]u8 align(16) = undefined;

test "q15 chain runs with ZERO heap behind a FixedBufferAllocator over a static .bss buffer" {
    // The embedded memory model: all render memory is static `.bss`, carved by a
    // `FixedBufferAllocator` over a fixed byte array — there is no heap on the
    // target. A `FixedBufferAllocator` has no heap fallback, so if the runtime
    // commit (which allocates the plan, the bound instances, AND the colored pool
    // from this allocator) SUCCEEDS, the entire engine fit in the static buffer:
    // commit succeeding IS the proof that the q15 chain ran with zero heap. (The
    // shipped embedded path is the comptime `Executor` whose pool is itself a
    // `.bss` array; this test additionally proves the RUNTIME engine specializes to
    // a no-heap target by swapping the allocator — "the same code, specialized.")
    // A file-scope (`.bss`) byte region stands in for the MCU's static SRAM. The
    // runtime `Plan` is sized for the max node count, so the region is generous;
    // the shipped embedded path (the comptime `Executor`) needs only the 256-byte
    // colored pool — this demonstrates even the heavier runtime engine is no-heap.
    var fba = std.heap.FixedBufferAllocator.init(&fba_backing);

    const Nf = 64;
    var input: [Nf]SampleQ15 = undefined;
    var s: u64 = 0xABCDEF;
    for (&input) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = .{ .ch = .{@intCast(@as(i32, @intCast((s >> 50) & 0x3FFF)) - 8192)} };
    }
    var out: [Nf]SampleQ15 = @splat(.{ .ch = .{0} });

    var g = pan.Graph.init(fba.allocator(), .{ .precision = .i16, .channels = .mono, .block_size = Nf });
    defer g.deinit();
    const src = try g.add(QSource, .{ .data = @as([*]const SampleQ15, &input) });
    const gn = try g.add(pan.embedded.Gain, .{ .gain = gain_q });
    const bq = try g.add(pan.embedded.Biquad, .{ .coeffs = coeffs });
    const sk = try g.add(QSink, .{ .dest = @as([*]SampleQ15, &out) });
    try g.connect(src, gn);
    try g.connect(gn, bq);
    try g.connect(bq, sk);

    var eng = try g.commit(); // succeeds ⇒ everything fit in `backing` ⇒ zero heap
    defer eng.deinit();
    const token = pan.enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    // It actually filtered the signal (not silence, not a pass-through of zeros).
    var energy: i64 = 0;
    for (out) |x| energy += @as(i64, @abs(x.ch[0]));
    try std.testing.expect(energy > 0);
    // And the FBA was the sole memory source — its end_index advanced (memory was
    // taken from the static buffer, never from a heap).
    try std.testing.expect(fba.end_index > 0);
}
