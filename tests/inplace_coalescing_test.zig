//! inplace_coalescing_test — the Yoneda characterization of the commit pass's
//! IN-PLACE COALESCING gate (`src/commit.zig`, stage "5b") and its two observable
//! morphisms: (1) the B≡C bit-exact differential that PROVES coalescing is sound,
//! and (2) the pool-buffer reduction that proves the optimization is REAL.
//!
//! ─────────────────────────────────────────────────────────────────────────────
//! WHAT COALESCING IS (the contract under test)
//! ─────────────────────────────────────────────────────────────────────────────
//! A unary `Map` block that declares `pub const aliasing_safe = true` may write
//! its output IN PLACE into its single input's buffer — eliding a copy — but the
//! colorer only honors this when it can PROVE three facts:
//!   (i)   the input value is single-consumer (this Map is its sole reader, so
//!         overwriting it harms no one),
//!   (ii)  input and output share element type & count (same pool class, same
//!         byte window),
//!   (iii) the consumer reads before any other producer overwrites — guaranteed
//!         because the merged live-range is colored as ONE interval.
//! Coalescing fires ONLY in `.colored` mode. `.per_edge` (one private buffer per
//! produced value) NEVER coalesces — it is the obviously-correct baseline the
//! colored pool is differenced against.
//!
//! ─────────────────────────────────────────────────────────────────────────────
//! THE ORACLE — B≡C BIT-EXACT (primary correctness check)
//! ─────────────────────────────────────────────────────────────────────────────
//! For the SAME graph + SAME seeded block instances + SAME input, rendering under
//! `ExecutorMode(g, blocks, .per_edge)` (mode B: private buffers) and
//! `ExecutorMode(g, blocks, .colored)` (mode C: colored pool WITH in-place
//! coalescing) MUST produce a BYTE-IDENTICAL sink output. This is a pan-vs-pan
//! equivalence: tolerance never forgives pan disagreeing with itself, so the
//! comparison is `expectEqualSlices` / bit compare, NEVER allclose. A divergence
//! would mean an in-place read-after-write corrupted a value the colorer believed
//! safe to overwrite — i.e. coalescing is unsound. This empirical differential is
//! the WHY: it is the only thing that catches a falsely-declared `aliasing_safe`.
//!
//! THE OPTIMIZATION — COALESCING REDUCES BUFFERS (the point of stage 5b):
//! a single-consumer chain of `aliasing_safe` unary `Gain`s collapses to ONE pool
//! buffer (`pool_bytes == 1·N·@sizeOf(Sample(f32))`), strictly smaller than the
//! per-edge baseline that keeps every value live.
//!
//! THE GATE — coalescing must NOT fire when unsafe:
//!   (a) fan-out: a producer value with 2+ consumers cannot be overwritten in
//!       place; the colored pool keeps it in its own buffer.
//!   (b) a non-`aliasing_safe` block (`Biquad`) is never coalesced.
//!   (c) a layout-CHANGING block (`ConstantPowerPan`, mono→stereo, different
//!       element class) fails condition (ii) and is never coalesced.
//! ACROSS-CLASS DISJOINTNESS: different element types never share a buffer.
//!
//! ─────────────────────────────────────────────────────────────────────────────
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring,
//! per project Rules 13/14). All diagnostics on this file go to `std.debug.print`,
//! never `std.log.err` (the 0.16 test runner counts logged errors and would flip
//! an otherwise-green suite to a non-zero exit). No external oracle is used: every
//! check is pan-vs-pan ⇒ bit-exact, or exact-integer equality on plan figures.

const std = @import("std");
const pan = @import("pan");

const commit = pan.commit;
const graph = pan.graph;
const port = pan.port;
const engine = pan.engine;
const filters = pan.filters;
const spatial = pan.spatial;
const numeric = pan.numeric;
const types = pan.types;

const num = numeric.numericFor(.f32, .{});
const Sample = pan.Sample(f32);

const Gain = filters.Gain(num);
const Biquad = filters.Biquad(num);
const Pan = spatial.ConstantPowerPan(num);

const SAMPLE_BYTES = @sizeOf(Sample);

// ===========================================================================
// Boundary blocks (copied from tests/executor_test.zig per the brief). A Source
// has zero sample inputs (it fills its output from its own backing store) and a
// Sink has zero outputs (it copies its input out). All are Map blocks.
// ===========================================================================

/// Mono source: copies its preloaded backing store into the output buffer.
/// NOT `aliasing_safe` and `is_source` ⇒ it never coalesces (it has no input to
/// alias). Its OUTPUT value is, however, a legal coalescing TARGET for a
/// downstream `aliasing_safe` Map (provided that output is single-consumer).
const MonoSource = struct {
    const Self = @This();
    data: [*]const Sample = undefined,
    pub fn process(self: *Self, out: []Sample) void {
        @memcpy(out, self.data[0..out.len]);
    }
};

/// Mono sink: copies its input buffer to a destination backing store.
const MonoSink = struct {
    const Self = @This();
    dest: [*]Sample = undefined,
    pub fn process(self: *Self, in: []const Sample) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

/// Stereo sink: drains a stereo PLANAR input (the downstream of a pan) to a
/// plane-major destination buffer `[L-plane(N)][R-plane(N)]`.
const StereoSink = struct {
    const Self = @This();
    dest: [*]f32 = undefined,
    pub fn process(self: *Self, in: pan.PlanarConst(f32, .stereo)) void {
        const n = in.frames;
        @memcpy(self.dest[0..n], in.plane(0));
        @memcpy(self.dest[n .. 2 * n], in.plane(1));
    }
};

// ===========================================================================
// Helpers — identical seeding into both modes, bit-exact compare.
// ===========================================================================

/// Deterministic, awkward-bit noise so a re-derived (non-kernel) reference would
/// risk diverging — but here both paths run the REAL kernels, so any divergence
/// is a pool/coalescing-layout bug, never numerics. xorshift64 for reproducibility.
fn fillNoise(buf: []Sample, seed: u64) void {
    var s = seed | 1;
    for (buf) |*frame| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        // Map to a finite, non-trivial float in roughly [-1, 1) with fractional
        // mantissa bits (so plain memcpy-vs-scaled paths are distinguishable).
        const u: u32 = @truncate(s);
        const f = @as(f32, @floatFromInt(u % 2_000_001)) / 1_000_000.0 - 1.0;
        frame.ch[0] = f;
    }
}

/// View a `[]const Sample` as the `[]const f32` (one lane per frame, identical
/// storage) the bit comparator wants.
fn lanes(frames: []const Sample) []const f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(frames)));
}

/// pan-vs-pan ⇒ ALWAYS bit-exact. An "almost" between two pan runs is a failure,
/// not a pass: tolerance never forgives pan disagreeing with itself.
fn bitExact(got: []const f32, ref: []const f32) !void {
    try std.testing.expectEqualSlices(f32, ref, got);
}

// ===========================================================================
// 1. B≡C BIT-EXACT — the primary correctness check (coalescing is SOUND).
// ===========================================================================
//
// For each topology: build the graph, seed identical Gain/Biquad/Pan instances
// into the .per_edge (B) and .colored (C) executors, render both over the same
// input, and assert the sink output is BYTE-IDENTICAL. C performs in-place
// coalescing; B does not. Equality proves the colorer's in-place overwrites
// never corrupted a still-needed value.

test "B≡C bit-exact: a single aliasing_safe Gain coalesces yet matches per-edge" {
    const N = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const gain = gg.add(Gain);
        const sink = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xA11A5);

    const Colored = engine.ExecutorMode(g, &.{ MonoSource, Gain, MonoSink }, .colored);
    const PerEdge = engine.ExecutorMode(g, &.{ MonoSource, Gain, MonoSink }, .per_edge);

    // A non-power-of-two coefficient: in-place vs out-of-place must agree to the
    // BIT, so a coefficient that doesn't round trivially is the stricter probe.
    const k: f32 = 0.5012;
    var out_c: [N]Sample = undefined;
    var out_b: [N]Sample = undefined;

    var colored: Colored = .{ .instances = .{ .{ .data = &input }, .{ .gain = k }, .{ .dest = &out_c } } };
    var per_edge: PerEdge = .{ .instances = .{ .{ .data = &input }, .{ .gain = k }, .{ .dest = &out_b } } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    colored.render(token);
    per_edge.render(token);

    try bitExact(lanes(&out_c), lanes(&out_b));
}

test "B≡C bit-exact: a deep chain of N=6 aliasing_safe Gains, in place ≡ per-edge" {
    // A long single-consumer chain is where coalescing does the MOST work: every
    // Gain overwrites the buffer the previous Gain just wrote. If the in-place
    // read-after-write were wrong, the divergence compounds down the chain — so a
    // deep chain is the most sensitive soundness probe.
    const N = 48;
    const CHAIN = 6;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        var prev = src;
        var prev_out: type = MonoSource;
        var i: usize = 0;
        while (i < CHAIN) : (i += 1) {
            const gn = gg.add(Gain);
            gg.connect(port.MapOutPort(prev_out), prev, 0, port.MapInPort(Gain), gn, 0);
            prev = gn;
            prev_out = Gain;
        }
        const sink = gg.add(MonoSink);
        gg.connect(port.MapOutPort(Gain), prev, 0, port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xC0FFEE);

    const blocks = &.{ MonoSource, Gain, Gain, Gain, Gain, Gain, Gain, MonoSink };
    const Colored = engine.ExecutorMode(g, blocks, .colored);
    const PerEdge = engine.ExecutorMode(g, blocks, .per_edge);

    // Distinct, non-trivial coefficients per stage so no accidental commutativity
    // masks a buffer mixup.
    const ks = [CHAIN]f32{ 0.9, 1.1, 0.4012, 1.7, 0.61, 0.337 };
    var out_c: [N]Sample = undefined;
    var out_b: [N]Sample = undefined;

    var colored: Colored = .{ .instances = .{
        .{ .data = &input }, .{ .gain = ks[0] }, .{ .gain = ks[1] }, .{ .gain = ks[2] },
        .{ .gain = ks[3] },  .{ .gain = ks[4] }, .{ .gain = ks[5] }, .{ .dest = &out_c },
    } };
    var per_edge: PerEdge = .{ .instances = .{
        .{ .data = &input }, .{ .gain = ks[0] }, .{ .gain = ks[1] }, .{ .gain = ks[2] },
        .{ .gain = ks[3] },  .{ .gain = ks[4] }, .{ .gain = ks[5] }, .{ .dest = &out_b },
    } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    colored.render(token);
    per_edge.render(token);

    try bitExact(lanes(&out_c), lanes(&out_b));
}

test "B≡C bit-exact: a coalesced Gain feeding a NON-aliasing Biquad ≡ per-edge" {
    // The Gain (aliasing_safe) coalesces into the source buffer; its output then
    // feeds a Biquad (NOT aliasing_safe, stateful recurrence) which must NOT
    // coalesce. The mixed chain must still match per-edge to the bit — coalescing
    // upstream of a non-coalescing consumer is the realistic case.
    const N = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const gain = gg.add(Gain);
        const bq = gg.add(Biquad);
        const sink = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(Biquad), bq, 0);
        gg.connect(port.MapOutPort(Biquad), bq, 0, port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xBADF00D);

    const blocks = &.{ MonoSource, Gain, Biquad, MonoSink };
    const Colored = engine.ExecutorMode(g, blocks, .colored);
    const PerEdge = engine.ExecutorMode(g, blocks, .per_edge);

    const coeffs = filters.Coeffs(f32){ .b0 = 0.4, .b1 = 0.2, .b2 = 0.05, .a1 = -0.6, .a2 = 0.1 };
    var out_c: [N]Sample = undefined;
    var out_b: [N]Sample = undefined;

    var colored: Colored = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.73 }, .{ .coeffs = coeffs }, .{ .dest = &out_c } } };
    var per_edge: PerEdge = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.73 }, .{ .coeffs = coeffs }, .{ .dest = &out_b } } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    colored.render(token);
    per_edge.render(token);

    try bitExact(lanes(&out_c), lanes(&out_b));
}

test "B≡C bit-exact: a FAN-OUT Gain (two consumers) must NOT coalesce, yet ≡ per-edge" {
    // The Gain's output is read by TWO downstream Gains. That value is multi-reader
    // ⇒ coalescing is FORBIDDEN: overwriting it in place would corrupt the second
    // reader. The colored pool must keep it in its own buffer. We sum the two
    // branches at a mixer sink and require the SUM bit-exact across modes — if the
    // colorer wrongly coalesced the fan-out source, one branch would read a
    // clobbered buffer and the sum would diverge.
    const N = 32;

    // A 2-input mixer sink (adds its two inputs into the destination).
    const MixSink = struct {
        const Self = @This();
        dest: [*]Sample = undefined,
        pub fn process(self: *Self, a: []const Sample, b: []const Sample) void {
            for (0..a.len) |i| self.dest[i].ch[0] = a[i].ch[0] + b[i].ch[0];
        }
    };

    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const fan = gg.add(Gain); // its output fans out to two consumers
        const l = gg.add(Gain);
        const r = gg.add(Gain);
        const sink = gg.add(MixSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), fan, 0);
        // fan's single output port feeds BOTH l and r (the fan-out).
        gg.connect(port.MapOutPort(Gain), fan, 0, port.MapInPort(Gain), l, 0);
        gg.connect(port.MapOutPort(Gain), fan, 0, port.MapInPort(Gain), r, 0);
        gg.connect(port.MapOutPort(Gain), l, 0, port.MapInPort(MixSink), sink, 0);
        gg.connect(port.MapOutPort(Gain), r, 0, port.MapInPort(MixSink), sink, 1);
        break :blk gg;
    };

    var input: [N]Sample = undefined;
    fillNoise(&input, 0xFA0);

    const blocks = &.{ MonoSource, Gain, Gain, Gain, MixSink };
    const Colored = engine.ExecutorMode(g, blocks, .colored);
    const PerEdge = engine.ExecutorMode(g, blocks, .per_edge);

    var out_c: [N]Sample = undefined;
    var out_b: [N]Sample = undefined;

    var colored: Colored = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.5 }, .{ .gain = 0.8 }, .{ .gain = 1.3 }, .{ .dest = &out_c } } };
    var per_edge: PerEdge = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.5 }, .{ .gain = 0.8 }, .{ .gain = 1.3 }, .{ .dest = &out_b } } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    colored.render(token);
    per_edge.render(token);

    try bitExact(lanes(&out_c), lanes(&out_b));
}

test "B≡C bit-exact: a layout-CHANGING Pan (mono→stereo) ≡ per-edge across modes" {
    // ConstantPowerPan changes the element class (mono Sample → stereo Frame), so
    // condition (ii) fails and it is never coalesced. With an upstream coalescing
    // Gain feeding it, both planes of the stereo sink must match per-edge to the
    // bit. This exercises an across-class boundary inside the B≡C oracle.
    const N = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const gain = gg.add(Gain);
        const panner = gg.add(Pan);
        const sink = gg.add(StereoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(Pan), panner, 0);
        gg.connect(port.MapOutPort(Pan), panner, 0, port.MapInPort(StereoSink), sink, 0);
        break :blk gg;
    };

    var input: [N]Sample = undefined;
    fillNoise(&input, 0x5EED);

    const blocks = &.{ MonoSource, Gain, Pan, StereoSink };
    const Colored = engine.ExecutorMode(g, blocks, .colored);
    const PerEdge = engine.ExecutorMode(g, blocks, .per_edge);

    // Plane-major stereo destinations: [L-plane(N)][R-plane(N)].
    var out_c: [2 * N]f32 = undefined;
    var out_b: [2 * N]f32 = undefined;

    var colored: Colored = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.66 }, .{ .pan = 0.3 }, .{ .dest = &out_c } } };
    var per_edge: PerEdge = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.66 }, .{ .pan = 0.3 }, .{ .dest = &out_b } } };

    const token = pan.enterRealtimeThread();
    defer token.leave();
    colored.render(token);
    per_edge.render(token);

    try bitExact(&out_c, &out_b);
}

// ===========================================================================
// 2. COALESCING REDUCES BUFFERS — the optimization is REAL (plan figures).
// ===========================================================================
//
// These assert exact-integer equality on the committed plan's `pool_bytes`. They
// are comptime commits (no rendering), so they pin the colorer's buffer-id
// assignment directly.

/// Build `source → Gain → Gain → ... → Gain → sink` with `chain` single-consumer
/// Gains at block size `N`.
fn gainChainGraph(comptime N: usize, comptime chain: usize) graph.Graph {
    var gg = graph.Graph.empty;
    gg.block_size = N;
    const src = gg.add(MonoSource);
    var prev = src;
    var prev_out: type = MonoSource;
    var i: usize = 0;
    while (i < chain) : (i += 1) {
        const gn = gg.add(Gain);
        gg.connect(port.MapOutPort(prev_out), prev, 0, port.MapInPort(Gain), gn, 0);
        prev = gn;
        prev_out = Gain;
    }
    const sink = gg.add(MonoSink);
    gg.connect(port.MapOutPort(Gain), prev, 0, port.MapInPort(MonoSink), sink, 0);
    return gg;
}

test "coalescing: a single-consumer chain of N aliasing_safe Gains collapses to ONE pool buffer" {
    // `source → Gain → Gain → Gain → Gain → sink`. Every Gain is aliasing_safe,
    // unary, single-consumer ⇒ all outputs coalesce into the source's output
    // buffer. Colored pool == exactly ONE buffer's worth of scratch.
    const N = 64;
    const CHAIN = 4;
    const g = comptime gainChainGraph(N, CHAIN);

    const colored = comptime try commit.commitComptimeMode(g, .colored);
    const per_edge = comptime try commit.commitComptimeMode(g, .per_edge);

    // ONE buffer: 1 · N · sizeof(Sample(f32)).
    try std.testing.expectEqual(@as(usize, 1 * N * SAMPLE_BYTES), colored.pool_bytes);
    try std.testing.expectEqual(@as(usize, 1), colored.pool_buffer_count);

    // Per-edge keeps the source output + every Gain output live: (CHAIN+1) values.
    try std.testing.expectEqual(@as(usize, (CHAIN + 1) * N * SAMPLE_BYTES), per_edge.pool_bytes);
    try std.testing.expectEqual(@as(usize, CHAIN + 1), per_edge.pool_buffer_count);

    // The optimization is strictly real: coalescing shrinks the pool.
    try std.testing.expect(colored.pool_bytes < per_edge.pool_bytes);
    try std.testing.expectEqual(commit.BufferMode.colored, colored.buffer_mode);
    try std.testing.expectEqual(commit.BufferMode.per_edge, per_edge.buffer_mode);
}

test "coalescing: collapse-to-one holds for varying chain lengths (1, 2, 3, 7)" {
    // The single-buffer result is a property of the topology (single-consumer
    // aliasing_safe chain), not a coincidence of one length. Characterize it
    // across several N.
    const N = 32;
    inline for (.{ 1, 2, 3, 7 }) |CHAIN| {
        const g = comptime gainChainGraph(N, CHAIN);
        const colored = comptime try commit.commitComptimeMode(g, .colored);
        const per_edge = comptime try commit.commitComptimeMode(g, .per_edge);

        try std.testing.expectEqual(@as(usize, 1 * N * SAMPLE_BYTES), colored.pool_bytes);
        try std.testing.expectEqual(@as(usize, 1), colored.pool_buffer_count);
        try std.testing.expectEqual(@as(usize, (CHAIN + 1) * N * SAMPLE_BYTES), per_edge.pool_bytes);
    }
}

// ===========================================================================
// 3. GATING — coalescing must NOT fire when unsafe (plan figures).
// ===========================================================================

test "gate (a): a FAN-OUT Gain output is multi-reader ⇒ kept in its own buffer, not coalesced" {
    // `source → fan(Gain) → {l(Gain), r(Gain)} → mixSink`. The fan Gain's output
    // has TWO consumers, so it is NOT a legal coalescing target: condition (i)
    // (single-consumer input) fails for l and r — neither may overwrite the shared
    // buffer. The source→fan edge IS single-consumer (fan coalesces into source).
    // Result: the colored pool must keep MORE than one buffer (the fan output is
    // simultaneously live with l's and r's outputs).
    const N = 32;
    const MixSink = struct {
        const Self = @This();
        dest: [*]Sample = undefined,
        pub fn process(self: *Self, a: []const Sample, b: []const Sample) void {
            for (0..a.len) |i| self.dest[i].ch[0] = a[i].ch[0] + b[i].ch[0];
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const fan = gg.add(Gain);
        const l = gg.add(Gain);
        const r = gg.add(Gain);
        const sink = gg.add(MixSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), fan, 0);
        gg.connect(port.MapOutPort(Gain), fan, 0, port.MapInPort(Gain), l, 0);
        gg.connect(port.MapOutPort(Gain), fan, 0, port.MapInPort(Gain), r, 0);
        gg.connect(port.MapOutPort(Gain), l, 0, port.MapInPort(MixSink), sink, 0);
        gg.connect(port.MapOutPort(Gain), r, 0, port.MapInPort(MixSink), sink, 1);
        break :blk gg;
    };

    const colored = comptime try commit.commitComptimeMode(g, .colored);

    // The fan output is live concurrently with l's and r's outputs ⇒ the colored
    // pool cannot collapse to one buffer. If coalescing wrongly fired on the
    // fan-out, pool_buffer_count would drop to 1 and the value would be clobbered.
    try std.testing.expect(colored.pool_buffer_count >= 2);

    // It must still never EXCEED the per-edge baseline (coloring is a reduction).
    const per_edge = comptime try commit.commitComptimeMode(g, .per_edge);
    try std.testing.expect(colored.pool_buffer_count <= per_edge.pool_buffer_count);
}

test "gate (b): a NON-aliasing_safe Biquad is never coalesced" {
    // `source → Biquad → Biquad → sink`. Biquad does NOT declare aliasing_safe, so
    // stage 5b skips it entirely. The colored pool therefore behaves like the
    // plain ping-pong colorer (no in-place merge): it CANNOT collapse the two
    // Biquad outputs into the source buffer the way an aliasing_safe chain would.
    // Concretely the colored pool keeps >1 buffer (no chain-collapse to 1), unlike
    // the aliasing_safe Gain chain of the same shape which collapses to 1.
    const N = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const a = gg.add(Biquad);
        const b = gg.add(Biquad);
        const sink = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Biquad), a, 0);
        gg.connect(port.MapOutPort(Biquad), a, 0, port.MapInPort(Biquad), b, 0);
        gg.connect(port.MapOutPort(Biquad), b, 0, port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };

    const colored = comptime try commit.commitComptimeMode(g, .colored);

    // No coalescing ⇒ the chain does NOT collapse to one buffer. (A ping-pong
    // colorer reuses buffers across non-overlapping live ranges, but adjacent
    // producer/consumer values overlap, so it needs at least 2.)
    try std.testing.expect(colored.pool_buffer_count >= 2);

    // Contrast: the SAME-shaped aliasing_safe Gain chain DOES collapse to 1.
    const g_gain = comptime gainChainGraph(N, 2);
    const colored_gain = comptime try commit.commitComptimeMode(g_gain, .colored);
    try std.testing.expectEqual(@as(usize, 1), colored_gain.pool_buffer_count);
    // So the Biquad chain strictly keeps more buffers than the equivalent Gain
    // chain — coalescing is the only difference, and it is gated off for Biquad.
    try std.testing.expect(colored.pool_buffer_count > colored_gain.pool_buffer_count);
}

test "gate (c): a layout-CHANGING Pan (mono→stereo) is never coalesced (condition ii fails)" {
    // `source → Gain → Pan → stereoSink`. The Gain coalesces into the source
    // buffer (single-consumer aliasing_safe, same mono class). The Pan is
    // aliasing_safe-irrelevant: its output is a DIFFERENT element class (stereo
    // Frame), so condition (ii) (same element type & count) fails — it cannot
    // share the mono input buffer. The stereo output therefore occupies its own
    // buffer in a SEPARATE element class.
    const N = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const gain = gg.add(Gain);
        const panner = gg.add(Pan);
        const sink = gg.add(StereoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(Pan), panner, 0);
        gg.connect(port.MapOutPort(Pan), panner, 0, port.MapInPort(StereoSink), sink, 0);
        break :blk gg;
    };

    const colored = comptime try commit.commitComptimeMode(g, .colored);

    // The mono class collapses (source + Gain → 1 mono buffer). The stereo Pan
    // output lives in its OWN buffer (different class). So pool_buffer_count counts
    // at least the mono buffer + the stereo buffer = 2 distinct buffers.
    try std.testing.expect(colored.pool_buffer_count >= 2);

    // ACROSS-CLASS DISJOINTNESS: the mono coalesced buffer and the stereo Pan
    // buffer are different sizes (mono N·4 vs stereo 2·N·4). The colored pool's
    // total bytes must account for BOTH classes, never overlapping them.
    const mono_bytes = N * SAMPLE_BYTES;
    const stereo_bytes = 2 * N * SAMPLE_BYTES;
    // The pool holds (at least) one mono buffer and one stereo buffer.
    try std.testing.expect(colored.pool_bytes >= mono_bytes + stereo_bytes);
}

// ===========================================================================
// 4. ACROSS-CLASS DISJOINTNESS + per_edge never-coalesces (plan figures).
// ===========================================================================

test "per_edge NEVER coalesces: aliasing_safe Gains still get private buffers in Mode B" {
    // Mode B is the obviously-correct baseline: even a single-consumer chain of
    // aliasing_safe Gains gets one private buffer PER produced value. This is the
    // anchor the B≡C differential leans on — it must be coalescing-free by
    // construction.
    const N = 32;
    const CHAIN = 3;
    const g = comptime gainChainGraph(N, CHAIN);

    const per_edge = comptime try commit.commitComptimeMode(g, .per_edge);

    // source output + CHAIN Gain outputs = CHAIN+1 distinct buffers, no reuse.
    try std.testing.expectEqual(@as(usize, CHAIN + 1), per_edge.pool_buffer_count);
    try std.testing.expectEqual(@as(usize, (CHAIN + 1) * N * SAMPLE_BYTES), per_edge.pool_bytes);

    // And colored strictly beats it (the whole reason Mode C exists).
    const colored = comptime try commit.commitComptimeMode(g, .colored);
    try std.testing.expect(colored.pool_buffer_count < per_edge.pool_buffer_count);
    try std.testing.expect(colored.pool_bytes < per_edge.pool_bytes);
}

test "across-class disjointness: a coalesced mono chain + a distinct stereo class never share a buffer" {
    // Two element classes in one graph: a coalescing mono Gain chain and a stereo
    // Pan output. The colored pool must size to the SUM of the two classes' needs;
    // a value of one class can never reuse a buffer colored for the other.
    const N = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const g1 = gg.add(Gain);
        const g2 = gg.add(Gain);
        const panner = gg.add(Pan);
        const sink = gg.add(StereoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), g1, 0);
        gg.connect(port.MapOutPort(Gain), g1, 0, port.MapInPort(Gain), g2, 0);
        gg.connect(port.MapOutPort(Gain), g2, 0, port.MapInPort(Pan), panner, 0);
        gg.connect(port.MapOutPort(Pan), panner, 0, port.MapInPort(StereoSink), sink, 0);
        break :blk gg;
    };

    const colored = comptime try commit.commitComptimeMode(g, .colored);

    // The mono chain (source + g1 + g2) coalesces to ONE mono buffer (N·4). The
    // stereo Pan output is one stereo buffer (2·N·4). Disjoint classes ⇒ the pool
    // is exactly their sum: N·4 + 2·N·4 = 3·N·4.
    const mono = N * SAMPLE_BYTES;
    const stereo = 2 * N * SAMPLE_BYTES;
    try std.testing.expectEqual(@as(usize, mono + stereo), colored.pool_bytes);
    // Two distinct buffers, one per class — never merged across classes.
    try std.testing.expectEqual(@as(usize, 2), colored.pool_buffer_count);
}
