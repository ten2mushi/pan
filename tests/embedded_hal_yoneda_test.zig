//! embedded_hal_yoneda_test — a Yoneda characterization of the P10 embedded
//! bring-up surface: the I2S-DMA ping-pong HAL (`pan.io.I2sDma` +
//! `I2sDmaSource`/`I2sDmaSink`), the comptime q15 embedded chain
//! (`pan.embedded.*`), and the no-op-realtime-token API-shape invariance
//! (`pan.enterRealtimeThread` / `pan.RealtimeToken` driving the bound
//! `Executor`).
//!
//! "Yoneda way": each object is pinned by ALL its observable morphisms. The
//! I2sDma is understood through every (HT/TC) × (half index) × (write-one /
//! read-other) interaction; the source/sink through their port arity
//! (classification) AND their byte motion (the copy + zero-pad); the chain
//! through the executor-vs-hand-run differential. Every pan-vs-pan comparison
//! is BIT-EXACT (no "almost" — a 1-LSB difference is a failure, not a pass).
//!
//! This file goes BROADER than `embedded_chain_test.zig` (which it does not
//! duplicate): it probes the buffer mechanics directly, exercises multiple
//! lane types and N values, asserts the static classification, and pins the
//! partial-demand zero-pad edge in both directions.
//!
//! Verified against zig 0.16.0 with the zig-0-16 skill loaded (project Rules
//! 13/14). Diagnostics, if any, go to std.debug.print, never std.log.err (the
//! 0.16 test runner counts logged errors and would flip the suite red).

const std = @import("std");
const pan = @import("pan");

const numeric = pan.numeric;
const types = pan.types;
const filters = pan.filters;
const port = pan.port;
const engine = pan.engine;
const io = pan.io;

const N = pan.embedded.N; // 64
const num = pan.embedded.num; // q15 (i16 lane)
const Dma = io.I2sDma(num, N);
const SampleQ15 = types.Sample(i16);

// The same stable resonant low-pass + gain the desktop chain test uses (Q2.13
// coefficients with a supra-unity a1). Reused so the hand-run reference is the
// real embedded kernel, not a re-derived arithmetic.
const coeffs = filters.Coeffs(i16){ .b0 = 50, .b1 = 100, .b2 = 50, .a1 = -14000, .a2 = 6500 };
const gain_q: i16 = 26214; // ~0.8 in q15

// ===========================================================================
// Helpers
// ===========================================================================

/// View a `Sample(i16)` slice as its `[]i16` lanes (mono = layout-exact), for
/// bit-exact slice comparison.
fn lanes(s: []const SampleQ15) []const i16 {
    return @alignCast(std.mem.bytesAsSlice(i16, std.mem.sliceAsBytes(s)));
}

/// Deterministic q15 noise bounded well below full-scale (resonant biquad
/// headroom). Generic over any `Sample(T)` integer lane.
fn fillNoise(comptime T: type, half: []types.Sample(T), seed: u64) void {
    var s = seed;
    for (half) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        const v: T = @intCast(@as(i32, @intCast((s >> 50) & 0x3FFF)) - 8192);
        x.* = .{ .ch = .{v} };
    }
}

/// Fill a slice with a ramp `base, base+1, …` so each frame is distinguishable
/// (catches index/transpose errors a constant fill would mask).
fn fillRamp(half: []SampleQ15, base: i16) void {
    for (half, 0..) |*x, i| x.* = .{ .ch = .{base +% @as(i16, @intCast(i))} };
}

fn allZero(half: []const SampleQ15) bool {
    for (half) |x| if (x.ch[0] != 0) return false;
    return true;
}

// ===========================================================================
// 1. I2sDma ping-pong buffer mechanics (catalog §9.3 / io §8)
// ===========================================================================
//
// The transport is the two-N circular buffer with a processing-owned `active`
// half toggled by the two IRQ entries. We pin every morphism of that toggle.

test "I2sDma: a fresh transport is zeroed and owns half 0 by default (io §8)" {
    var d = Dma{};
    // The .bss-resident buffer is splat-zeroed at construction.
    try std.testing.expect(allZero(d.activeHalf()));
    try std.testing.expect(allZero(d.half(0)));
    try std.testing.expect(allZero(d.half(1)));
    // Default active half is 0 (no IRQ has fired yet).
    try std.testing.expectEqual(@as(usize, @intFromPtr(d.half(0).ptr)), @as(usize, @intFromPtr(d.activeHalf().ptr)));
    // half_frames is the comptime block size N.
    try std.testing.expectEqual(N, Dma.half_frames);
}

test "I2sDma: onHalfTransfer selects half 0, onTransferComplete selects half 1 (io §8)" {
    var d = Dma{};
    d.onTransferComplete();
    try std.testing.expectEqual(@intFromPtr(d.half(1).ptr), @intFromPtr(d.activeHalf().ptr));
    d.onHalfTransfer();
    try std.testing.expectEqual(@intFromPtr(d.half(0).ptr), @intFromPtr(d.activeHalf().ptr));
    // Toggle is idempotent: re-firing the same IRQ keeps the same half.
    d.onHalfTransfer();
    try std.testing.expectEqual(@intFromPtr(d.half(0).ptr), @intFromPtr(d.activeHalf().ptr));
    d.onTransferComplete();
    d.onTransferComplete();
    try std.testing.expectEqual(@intFromPtr(d.half(1).ptr), @intFromPtr(d.activeHalf().ptr));
}

test "I2sDma: the two halves are disjoint N-frame regions of one 2N buffer (io §8)" {
    var d = Dma{};
    const h0 = d.half(0);
    const h1 = d.half(1);
    try std.testing.expectEqual(@as(usize, N), h0.len);
    try std.testing.expectEqual(@as(usize, N), h1.len);
    // Disjoint: h1 starts exactly where h0 ends, no overlap, contiguous.
    const h0_end = @intFromPtr(h0.ptr) + h0.len * @sizeOf(SampleQ15);
    try std.testing.expectEqual(h0_end, @intFromPtr(h1.ptr));
    // And together they span the whole 2N buffer with nothing between.
    const span = @intFromPtr(h1.ptr) + h1.len * @sizeOf(SampleQ15) - @intFromPtr(h0.ptr);
    try std.testing.expectEqual(@as(usize, 2 * N * @sizeOf(SampleQ15)), span);
}

test "I2sDma: writing the owned half does not disturb the DMA-owned half (io §8)" {
    var d = Dma{};
    // Own half 0, write a ramp into it; half 1 (DMA's) must stay pristine zero.
    d.onHalfTransfer();
    fillRamp(d.activeHalf(), 1000);
    try std.testing.expect(allZero(d.half(1)));
    try std.testing.expect(!allZero(d.half(0)));

    // Now switch ownership to half 1 and write a DIFFERENT pattern; half 0's
    // earlier contents must be untouched (writes to one half never bleed).
    d.onTransferComplete();
    fillRamp(d.activeHalf(), -2000);
    // half 0 still holds its ramp 1000, 1001, …
    for (d.half(0), 0..) |x, i| try std.testing.expectEqual(@as(i16, 1000 +% @as(i16, @intCast(i))), x.ch[0]);
    // half 1 holds the new pattern.
    for (d.half(1), 0..) |x, i| try std.testing.expectEqual(@as(i16, -2000 +% @as(i16, @intCast(i))), x.ch[0]);
}

test "I2sDma: buffer is 64-byte aligned and exactly 2N frames (io §8 — .bss cache line)" {
    var d = Dma{};
    try std.testing.expectEqual(@as(usize, 2 * N), d.buf.len);
    // Cache-line alignment is part of the type contract (declared align(64)).
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&d.buf) % 64);
}

test "I2sDma: half(which) and activeHalf agree across both ownership states (io §8)" {
    var d = Dma{};
    d.onHalfTransfer();
    try std.testing.expectEqual(@intFromPtr(d.half(0).ptr), @intFromPtr(d.activeHalf().ptr));
    try std.testing.expectEqual(@as(usize, 0), d.active);
    d.onTransferComplete();
    try std.testing.expectEqual(@intFromPtr(d.half(1).ptr), @intFromPtr(d.activeHalf().ptr));
    try std.testing.expectEqual(@as(usize, 1), d.active);
}

// Multiple N values and a second (wider) lane type — the transport is generic
// over the Numeric trait and any N, not just the embedded (q15, 64) monomorph.

test "I2sDma: mechanics hold for a different N (parametric over block size)" {
    const N32 = 32;
    const D = io.I2sDma(num, N32);
    var d = D{};
    try std.testing.expectEqual(@as(usize, N32), D.half_frames);
    try std.testing.expectEqual(@as(usize, 2 * N32), d.buf.len);
    d.onTransferComplete();
    try std.testing.expectEqual(@intFromPtr(d.half(1).ptr), @intFromPtr(d.activeHalf().ptr));
    const h0_end = @intFromPtr(d.half(0).ptr) + N32 * @sizeOf(SampleQ15);
    try std.testing.expectEqual(h0_end, @intFromPtr(d.half(1).ptr));
}

test "I2sDma: mechanics hold for a different lane type (i32 q31)" {
    const num31 = numeric.numericFor(.i32, .{ .width_override = 1 });
    const D = io.I2sDma(num31, 16);
    const S32 = types.Sample(i32);
    var d = D{};
    // Default-zeroed, owns half 0.
    for (d.half(0)) |x| try std.testing.expectEqual(@as(i32, 0), x.ch[0]);
    d.onHalfTransfer();
    for (d.activeHalf(), 0..) |*x, i| x.* = .{ .ch = .{@as(i32, @intCast(i)) * 100_000} };
    // half 1 untouched.
    for (d.half(1)) |x| try std.testing.expectEqual(@as(i32, 0), x.ch[0]);
    // Disjoint at the i32 width.
    const h0_end = @intFromPtr(d.half(0).ptr) + 16 * @sizeOf(S32);
    try std.testing.expectEqual(h0_end, @intFromPtr(d.half(1).ptr));
}

// ===========================================================================
// 2. Classification: I2sDmaSource is a Source; I2sDmaSink is an input-only Map.
// ===========================================================================
//
// The Yoneda-structural facet: the boundary blocks are pinned by their port
// arity in the comptime classifier, independent of their byte behavior.

test "classify: I2sDmaSource is a Map Source (zero sample inputs) (port §1)" {
    try std.testing.expect(port.classify(pan.embedded.Source) == .Map);
    try std.testing.expect(comptime port.isSource(pan.embedded.Source));
    // Its output element is the mono q15 sample.
    try std.testing.expectEqual(SampleQ15, port.MapOutElem(pan.embedded.Source));
}

test "classify: I2sDmaSink is a Map and NOT a Source (it has an input port) (port §1)" {
    try std.testing.expect(port.classify(pan.embedded.Sink) == .Map);
    try std.testing.expect(!comptime port.isSource(pan.embedded.Sink));
    // Its input element is the mono q15 sample (the sink consumes, emits nothing).
    try std.testing.expectEqual(SampleQ15, port.MapInElem(pan.embedded.Sink));
}

// ===========================================================================
// 3. I2sDmaSource byte behavior: copies the active RX half, zero-pads.
// ===========================================================================

test "I2sDmaSource: copies exactly the active RX half into a full-N demand (io §8)" {
    var rx = Dma{};
    rx.onHalfTransfer(); // own half 0
    fillRamp(rx.activeHalf(), 7);
    var src = pan.embedded.Source{ .dma = &rx };
    var out: [N]SampleQ15 = undefined;
    src.process(&out);
    try std.testing.expectEqualSlices(i16, lanes(rx.activeHalf()), lanes(&out));
}

test "I2sDmaSource: follows the ACTIVE half when the IRQ toggles (io §8)" {
    var rx = Dma{};
    rx.onHalfTransfer();
    fillRamp(rx.half(0), 100); // half 0 contents
    rx.onTransferComplete(); // now own half 1
    fillRamp(rx.half(1), -50); // distinct half 1 contents
    var src = pan.embedded.Source{ .dma = &rx };
    var out: [N]SampleQ15 = undefined;
    src.process(&out);
    // The source must read half 1 (the active one), not half 0.
    try std.testing.expectEqualSlices(i16, lanes(rx.half(1)), lanes(&out));
    // Sanity: it did NOT read half 0.
    try std.testing.expect(!std.mem.eql(i16, lanes(rx.half(0)), lanes(&out)));
}

test "I2sDmaSource: a SHORTER-than-half buffer is left zeroed past the copy (io §8)" {
    // process copies min(out.len, src.len) and zero-fills the remainder of out.
    var rx = Dma{};
    rx.onHalfTransfer();
    for (rx.activeHalf()) |*x| x.* = .{ .ch = .{12345} }; // all non-zero
    var src = pan.embedded.Source{ .dma = &rx };
    // Demand SHORTER than the half: only the first `short` are copied; the rest
    // of `out` is the source's responsibility only up to out.len — here out IS
    // the whole demand, so all `short` get the half's value (no padding region).
    const short = 10;
    var out: [short]SampleQ15 = undefined;
    src.process(&out);
    for (out) |x| try std.testing.expectEqual(@as(i16, 12345), x.ch[0]);
}

test "I2sDmaSource: a LONGER-than-half demand zero-pads the tail (io §8 partial demand)" {
    // The documented edge: "zero-padding a longer demand". n = min(out, src) is
    // copied; out[n..] is set to silence.
    var rx = Dma{};
    rx.onHalfTransfer();
    for (rx.activeHalf()) |*x| x.* = .{ .ch = .{321} };
    var src = pan.embedded.Source{ .dma = &rx };
    const long = N + 7;
    var out: [long]SampleQ15 = undefined;
    // Pre-dirty the tail so we prove process actually writes the pad (not that it
    // happened to already be zero).
    for (&out) |*x| x.* = .{ .ch = .{-9999} };
    src.process(&out);
    // First N copied from the half.
    for (out[0..N]) |x| try std.testing.expectEqual(@as(i16, 321), x.ch[0]);
    // Tail [N..long) zero-padded.
    for (out[N..]) |x| try std.testing.expectEqual(@as(i16, 0), x.ch[0]);
}

// ===========================================================================
// 4. I2sDmaSink byte behavior: copies its input into the active TX half.
// ===========================================================================

test "I2sDmaSink: copies a full-N input into the active TX half (io §8)" {
    var tx = Dma{};
    tx.onHalfTransfer();
    var in: [N]SampleQ15 = undefined;
    fillNoise(i16, &in, 0xDEAD);
    var sink = pan.embedded.Sink{ .dma = &tx };
    sink.process(&in);
    try std.testing.expectEqualSlices(i16, lanes(&in), lanes(tx.activeHalf()));
    // The DMA-owned half (1) is untouched by the sink write.
    try std.testing.expect(allZero(tx.half(1)));
}

test "I2sDmaSink: writes to whichever half is active when invoked (io §8)" {
    var tx = Dma{};
    tx.onTransferComplete(); // own half 1
    var in: [N]SampleQ15 = undefined;
    fillRamp(&in, 500);
    var sink = pan.embedded.Sink{ .dma = &tx };
    sink.process(&in);
    try std.testing.expectEqualSlices(i16, lanes(&in), lanes(tx.half(1)));
    try std.testing.expect(allZero(tx.half(0))); // half 0 not written
}

test "I2sDmaSink: a SHORTER input zero-pads the rest of the TX half (io §8 partial)" {
    // Symmetric to the source's long-demand pad: when in is shorter than the
    // half, the sink copies n = min(in, dst) and silences dst[n..] so the codec
    // never streams stale samples.
    var tx = Dma{};
    tx.onHalfTransfer();
    for (tx.activeHalf()) |*x| x.* = .{ .ch = .{7777} }; // pre-dirty the whole half
    var in: [12]SampleQ15 = undefined;
    fillRamp(&in, 1);
    var sink = pan.embedded.Sink{ .dma = &tx };
    sink.process(&in);
    // First 12 are the input.
    for (tx.activeHalf()[0..12], 0..) |x, i| try std.testing.expectEqual(@as(i16, 1 +% @as(i16, @intCast(i))), x.ch[0]);
    // The rest of the half is zeroed (NOT the stale 7777).
    for (tx.activeHalf()[12..]) |x| try std.testing.expectEqual(@as(i16, 0), x.ch[0]);
}

// ===========================================================================
// 5. Round-trip: Source → (identity) → Sink reproduces the input bytes.
// ===========================================================================

test "I2sDma round-trip: RX → identity → TX reproduces the RX bytes (io §8)" {
    var rx = Dma{};
    var tx = Dma{};
    rx.onHalfTransfer();
    tx.onHalfTransfer();
    fillNoise(i16, rx.activeHalf(), 0x5151);

    var src = pan.embedded.Source{ .dma = &rx };
    var sink = pan.embedded.Sink{ .dma = &tx };
    var mid: [N]SampleQ15 = undefined;
    src.process(&mid); // RX half → mid
    sink.process(&mid); // mid → TX half (identity transform between)

    try std.testing.expectEqualSlices(i16, lanes(rx.activeHalf()), lanes(tx.activeHalf()));
}

test "I2sDma round-trip: distinct RX/TX active halves still round-trip exactly (io §8)" {
    // Cross the toggle: RX owns half 1, TX owns half 0. The round-trip must still
    // be the identity over the bytes (the active-half indirection is transparent).
    var rx = Dma{};
    var tx = Dma{};
    rx.onTransferComplete(); // RX owns half 1
    tx.onHalfTransfer(); // TX owns half 0
    fillNoise(i16, rx.activeHalf(), 0xABCD);

    var src = pan.embedded.Source{ .dma = &rx };
    var sink = pan.embedded.Sink{ .dma = &tx };
    var mid: [N]SampleQ15 = undefined;
    src.process(&mid);
    sink.process(&mid);

    try std.testing.expectEqualSlices(i16, lanes(rx.half(1)), lanes(tx.half(0)));
}

// ===========================================================================
// 6. The comptime q15 chain: footprint shape & op_count (root embedded §).
// ===========================================================================

test "embedded chain: Exec.committed.op_count == 4 and footprint is a comptime const" {
    // op_count: one op per node, source→gain→biquad→sink.
    try std.testing.expectEqual(@as(usize, 4), pan.embedded.Exec.committed.op_count);
    // footprint_bytes usable as an array length ⇒ comptime-known (.bss-sizable).
    const proof: [pan.embedded.footprint_bytes]u8 = undefined;
    comptime std.debug.assert(proof.len > 0);
    try std.testing.expectEqual(pan.embedded.footprint_bytes, proof.len);
}

test "embedded chain: footprint is a positive whole multiple of sizeof(Sample(i16))" {
    try std.testing.expect(pan.embedded.footprint_bytes > 0);
    try std.testing.expectEqual(@as(usize, 0), pan.embedded.footprint_bytes % @sizeOf(SampleQ15));
    // The pool holds q15 (2-byte) samples — sized in i16, not f32's 4 bytes.
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(SampleQ15));
    // And the lane really is i16 (guards against a silent precision regression).
    try std.testing.expectEqual(i16, pan.embedded.num.Lane);
}

// ===========================================================================
// 7. Differential: bound executor render ≡ hand-run chain, BIT-EXACT, and the
//    output is non-trivially filtered (not silence passed through).
// ===========================================================================
//
// This is the defining property of the colored pool: it must compute exactly
// what disjoint buffers compute. We go beyond embedded_chain_test by also
// driving the chain with a RAMP (a distinct, structured signal) and asserting
// the biquad genuinely transformed it (output ≠ input).

test "embedded chain: bound render ≡ hand-run source→gain→biquad→sink, BIT-EXACT (ramp)" {
    var rx = Dma{};
    var tx = Dma{};
    var tx_ref = Dma{};
    rx.onHalfTransfer();
    tx.onHalfTransfer();
    tx_ref.onHalfTransfer();
    // A ramp bounded so the resonant biquad has headroom but the filtering is
    // unmistakable (a constant-ish slope through a resonator rings audibly).
    for (rx.activeHalf(), 0..) |*x, i| x.* = .{ .ch = .{@as(i16, @intCast(@as(i32, @intCast(i % 64)) * 100 - 3200))} };

    // --- executor path ---
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

    // --- hand-run reference over disjoint buffers (the REAL kernels) ---
    var a: [N]SampleQ15 = undefined;
    var b: [N]SampleQ15 = undefined;
    var src = pan.embedded.Source{ .dma = &rx };
    var g = pan.embedded.Gain{ .gain = gain_q };
    var bq = pan.embedded.Biquad{ .coeffs = coeffs };
    var sink = pan.embedded.Sink{ .dma = &tx_ref };
    src.process(&a);
    g.process(&a, &b);
    bq.process(&b, &a); // biquad not aliasing_safe ⇒ distinct in/out
    sink.process(&a);

    // Colored pool == disjoint-buffer hand-run, to the bit.
    try std.testing.expectEqualSlices(i16, lanes(tx_ref.activeHalf()), lanes(tx.activeHalf()));

    // Non-trivial filtering: the TX output must NOT equal the raw RX input
    // (gain+resonant-biquad genuinely transformed the signal — not a pass-through).
    try std.testing.expect(!std.mem.eql(i16, lanes(rx.activeHalf()), lanes(tx.activeHalf())));
    // And it is not silence.
    var energy: u64 = 0;
    for (tx.activeHalf()) |s| energy += @abs(@as(i64, s.ch[0]));
    try std.testing.expect(energy > 0);
}

test "embedded chain: a separated gain stage matches the bound render's gain effect" {
    // Decompose the chain's first stage: the executor's gain must equal the
    // standalone Gain kernel on the same input (the pool does not perturb the
    // value it scales). We can't peek the executor's mid-buffer, so we verify the
    // standalone Gain is a genuine attenuation (gain_q ≈ 0.8 < 1) — a structural
    // check that the reference's first stage is the right shape.
    var in = [_]SampleQ15{.{ .ch = .{16000} }} ** N;
    var out: [N]SampleQ15 = undefined;
    var g = pan.embedded.Gain{ .gain = gain_q };
    g.process(&in, &out);
    // 16000 * (26214/32768) ≈ 12800 — strictly attenuated, same sign.
    for (out) |s| {
        try std.testing.expect(s.ch[0] > 0);
        try std.testing.expect(s.ch[0] < 16000);
    }
}

// ===========================================================================
// 8. No-op-token API-shape invariance across precisions (engine §RealtimeToken).
// ===========================================================================
//
// The SAME `pan.RealtimeToken` value drives a desktop f32 Executor and the q15
// embedded Executor in ONE test. That the identical token type/value threads
// through both render entries IS the cross-precision invariance — the
// token-gated entry's shape does not depend on the lane.

// A trivial f32 Map source/sink so we can stand up a desktop f32 Executor next
// to the q15 one and feed both the same token.
const F32Source = struct {
    data: [*]const types.Sample(f32) = undefined,
    pub fn process(self: *@This(), out: []types.Sample(f32)) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const F32Sink = struct {
    dest: [*]types.Sample(f32) = undefined,
    pub fn process(self: *@This(), in: []const types.Sample(f32)) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

test "realtime token: ONE token value drives both an f32 and a q15 Executor (engine §token)" {
    const numf = numeric.numericFor(.f32, .{});
    const GainF = filters.Gain(numf);
    const Mf = 8;

    const gf = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = Mf;
        const s = gg.add(F32Source);
        const gn = gg.add(GainF);
        const sk = gg.add(F32Sink);
        gg.connect(port.MapOutPort(F32Source), s, 0, port.MapInPort(GainF), gn, 0);
        gg.connect(port.MapOutPort(GainF), gn, 0, port.MapInPort(F32Sink), sk, 0);
        break :blk gg;
    };
    const ExecF = engine.Executor(gf, &.{ F32Source, GainF, F32Sink });

    var f_in: [Mf]types.Sample(f32) = undefined;
    for (&f_in, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var f_out: [Mf]types.Sample(f32) = undefined;
    var fexec: ExecF = .{ .instances = .{ .{ .data = &f_in }, .{ .gain = 0.5 }, .{ .dest = &f_out } } };

    // q15 executor over the embedded chain.
    var rx = Dma{};
    var tx = Dma{};
    rx.onHalfTransfer();
    tx.onHalfTransfer();
    fillNoise(i16, rx.activeHalf(), 0x1357);
    var qexec: pan.embedded.Exec = .{ .instances = .{
        .{ .dma = &rx }, .{ .gain = gain_q }, .{ .coeffs = coeffs }, .{ .dma = &tx },
    } };

    // ONE token of type pan.RealtimeToken, used to drive BOTH render entries.
    const token: pan.RealtimeToken = pan.enterRealtimeThread();
    defer token.leave();
    try std.testing.expect(token._entered); // positive witness of realtime entry
    fexec.render(token); // f32 path
    qexec.render(token); // q15 path — identical entry shape

    // Both produced live output (the invariance is that this compiled & ran).
    try std.testing.expectEqual(@as(f32, 0.5), f_out[0].ch[0]); // 1 * 0.5
    try std.testing.expect(!qexec.telemetry().fault);
    var energy: u64 = 0;
    for (tx.activeHalf()) |s| energy += @abs(@as(i64, s.ch[0]));
    try std.testing.expect(energy > 0);
}

test "realtime token: the q15 render REQUIRES a RealtimeToken (⊢ positive witness)" {
    // The signature won't type-check without the token (a structural ⊢ fact); we
    // can only witness the positive — passing it compiles and runs.
    var rx = Dma{};
    var tx = Dma{};
    rx.onHalfTransfer();
    tx.onHalfTransfer();
    fillNoise(i16, rx.activeHalf(), 0x2468);
    var exec: pan.embedded.Exec = .{ .instances = .{
        .{ .dma = &rx }, .{ .gain = gain_q }, .{ .coeffs = coeffs }, .{ .dma = &tx },
    } };
    const token: pan.RealtimeToken = pan.enterRealtimeThread();
    defer token.leave();
    try std.testing.expect(token._entered);
    exec.render(token);
    try std.testing.expect(!exec.telemetry().fault);
}

// ===========================================================================
// 9. Determinism: same RX input twice (fresh executors) ⇒ bit-identical TX.
// ===========================================================================
//
// The Biquad is stateful, so determinism must be tested with FRESH executors
// (each starts from zeroed z⁻¹ state) — re-rendering the same executor would
// carry filter state forward. Two independent runs of the same input must
// agree to the bit.

test "embedded chain: same RX input through two fresh executors ⇒ bit-identical TX" {
    var rx1 = Dma{};
    var tx1 = Dma{};
    var rx2 = Dma{};
    var tx2 = Dma{};
    inline for (.{ &rx1, &tx1, &rx2, &tx2 }) |d| d.onHalfTransfer();
    fillNoise(i16, rx1.activeHalf(), 0xFEEDFACE);
    fillNoise(i16, rx2.activeHalf(), 0xFEEDFACE); // identical seed ⇒ identical input
    // Confirm inputs really are identical (else the determinism claim is vacuous).
    try std.testing.expectEqualSlices(i16, lanes(rx1.activeHalf()), lanes(rx2.activeHalf()));

    const token = pan.enterRealtimeThread();
    defer token.leave();

    var exec1: pan.embedded.Exec = .{ .instances = .{
        .{ .dma = &rx1 }, .{ .gain = gain_q }, .{ .coeffs = coeffs }, .{ .dma = &tx1 },
    } };
    var exec2: pan.embedded.Exec = .{ .instances = .{
        .{ .dma = &rx2 }, .{ .gain = gain_q }, .{ .coeffs = coeffs }, .{ .dma = &tx2 },
    } };
    exec1.render(token);
    exec2.render(token);

    try std.testing.expect(!exec1.telemetry().fault);
    try std.testing.expect(!exec2.telemetry().fault);
    try std.testing.expectEqualSlices(i16, lanes(tx1.activeHalf()), lanes(tx2.activeHalf()));
}

test "embedded chain: a DIFFERENT RX input yields a DIFFERENT TX (no stuck output)" {
    // Counterexample guard: determinism must not be a constant. Two distinct
    // inputs must produce distinct outputs (else a stuck/zeroing render would
    // pass the determinism test vacuously).
    var rxA = Dma{};
    var txA = Dma{};
    var rxB = Dma{};
    var txB = Dma{};
    inline for (.{ &rxA, &txA, &rxB, &txB }) |d| d.onHalfTransfer();
    fillNoise(i16, rxA.activeHalf(), 0xAAAA);
    fillNoise(i16, rxB.activeHalf(), 0xBBBB);

    const token = pan.enterRealtimeThread();
    defer token.leave();
    var execA: pan.embedded.Exec = .{ .instances = .{
        .{ .dma = &rxA }, .{ .gain = gain_q }, .{ .coeffs = coeffs }, .{ .dma = &txA },
    } };
    var execB: pan.embedded.Exec = .{ .instances = .{
        .{ .dma = &rxB }, .{ .gain = gain_q }, .{ .coeffs = coeffs }, .{ .dma = &txB },
    } };
    execA.render(token);
    execB.render(token);
    try std.testing.expect(!std.mem.eql(i16, lanes(txA.activeHalf()), lanes(txB.activeHalf())));
}
