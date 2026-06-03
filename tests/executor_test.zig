//! executor_test — the Yoneda characterization of the Tier-A bound executor and
//! the realtime token (`src/engine.zig`).
//!
//! The executor is understood here through ALL its observable morphisms: what it
//! does to a graph's input is *defined* to be exactly what the same block
//! instances do when invoked by hand, in topo order, on the same input. That is
//! a pan-vs-pan equivalence, so it is checked BIT-EXACT (an "almost" between two
//! pan runs is a failure, not a pass). The reference path deliberately runs the
//! REAL `process` kernels by hand (not a re-derived arithmetic) so the executor's
//! gather/scatter-through-the-pool plumbing is the only thing under test — any
//! divergence is a plumbing bug, never a numerics difference.
//!
//! The other facets pinned: the render path REQUIRES a `RealtimeToken` (a ⊢
//! structural fact — we can only witness the positive: passing it compiles and
//! runs); flush-to-zero is live after `enterRealtimeThread()`; error isolation
//! silences a poisoned (NaN/Inf) output and raises `fault` (only when
//! `runtime_safety` is on, since the guard is compiled out in release); and the
//! executor's `committed` plan agrees with `commitComptime` on footprint/op-count
//! and reports `guards_compiled_out == !runtime_safety`.
//!
//! COMPARISON MODE: every executor-vs-hand-run check is pan-vs-pan ⇒ BIT-EXACT
//! (`std.testing.expectEqual` / `h.bitExact`). There is no external oracle.
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring,
//! per project Rules 13/14). Diagnostics on expected-reject paths go to
//! `std.debug.print`, never `std.log.err` (the 0.16 test runner counts logged
//! errors and would flip the suite to a non-zero exit).

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");
const pan = @import("pan");

const engine = pan.engine;
const graph = pan.graph;
const commit = pan.commit;
const port = pan.port;
const types = pan.types;
const filters = pan.filters;
const spatial = pan.spatial;
const numeric = pan.numeric;

const Sample = pan.Sample;
const Frame = types.Frame;
const Executor = engine.Executor;
const enterRealtimeThread = engine.enterRealtimeThread;

const num_f32 = numeric.numericFor(.f32, .{});

// ===========================================================================
// Boundary blocks: a mono source that emits a preloaded buffer, and a sink that
// drains its input to a destination. These ARE the device bridge for the
// Tier-A slice (the executor needs no external mux): a Source has zero sample
// inputs (it fills its output from its own backing store) and a Sink has zero
// outputs (it copies its input out). Both are mono `Sample(f32)` Map blocks.
// ===========================================================================

/// Mono source: copies its preloaded backing store into the output buffer.
const MonoSource = struct {
    const Self = @This();
    data: [*]const Sample(f32) = undefined,
    pub fn process(self: *Self, out: []Sample(f32)) void {
        @memcpy(out, self.data[0..out.len]);
    }
};

/// Mono sink: copies its input buffer to a destination backing store.
const MonoSink = struct {
    const Self = @This();
    dest: [*]Sample(f32) = undefined,
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

/// Stereo sink: drains a stereo PLANAR input (the downstream of a pan) to a
/// plane-major destination buffer. Its input port is a `PlanarConst(f32,.stereo)`
/// view — the element identity is still `Frame(f32,.stereo)`, but the buffer is
/// two channel planes, so the chain's layout change (mono → stereo) is honored
/// end-to-end in the enforced planar form. `dest` is the plane-major backing
/// (`[L-plane][R-plane]`); the sink copies each plane through.
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
// 1. End-to-end equivalence: executor output ≡ hand-run block chain, bit-exact.
// ===========================================================================
//
// The defining property. For each topology we build the graph, seed identical
// block instances into the executor AND into a hand-run reference, render both,
// and assert the sink outputs are byte-identical. The reference invokes the
// SAME `process` methods (a fresh instance with the same params), so the only
// variable is the executor's pool gather/scatter — a divergence is a plumbing
// bug, not numerics.

test "executor: bound op-list ≡ hand-run source→gain→sink chain, bit-exact" {
    const Gain = filters.Gain(num_f32);
    const N = 8;

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

    var input: [N]Sample(f32) = undefined;
    // A signal with awkward bits so a re-derived reference (not the real kernel)
    // would risk diverging — forcing the test to exercise the actual kernel.
    for (&input, 0..) |*s, i| s.ch[0] = @as(f32, @floatFromInt(i + 1)) * 0.30000001;

    const k: f32 = 0.5012; // −6 dB-ish, a non-power-of-two coefficient

    // --- executor path ---
    var exec_out: [N]Sample(f32) = undefined;
    const Exec = Executor(g, &.{ MonoSource, Gain, MonoSink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = k },
        .{ .dest = &exec_out },
    } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    // --- hand-run reference: the SAME kernels, by hand, in topo order ---
    var ref_mid: [N]Sample(f32) = undefined;
    var ref_out: [N]Sample(f32) = undefined;
    var ref_src = MonoSource{ .data = &input };
    var ref_gain = Gain{ .gain = k };
    var ref_sink = MonoSink{ .dest = &ref_out };
    ref_src.process(&ref_mid); // src fills its output
    ref_gain.process(&ref_mid, &ref_mid); // gain is aliasing_safe (in place is fine)
    ref_sink.process(&ref_mid); // sink drains to ref_out

    try h.bitExact(f32, h.sampleValues(&exec_out), h.sampleValues(&ref_out));
    try std.testing.expect(!exec.telemetry().fault);
}

test "executor: bound op-list ≡ hand-run source→gain→biquad→sink chain, bit-exact" {
    // A second op (the stateful Biquad) downstream of Gain. Biquad is NOT
    // aliasing_safe and carries z⁻¹ state, so the reference must use disjoint
    // buffers and a fresh-but-identically-configured instance.
    const Gain = filters.Gain(num_f32);
    const Biquad = filters.Biquad(num_f32);
    const N = 16;

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

    var input: [N]Sample(f32) = undefined;
    h.fillNoise(&input, 0xBEEF);

    const k: f32 = 0.75;
    // A one-pole low-pass that actually rings (so state across the buffer matters).
    const coeffs = filters.Coeffs(f32){ .b0 = 0.2, .a1 = -0.8 };

    // --- executor path ---
    var exec_out: [N]Sample(f32) = undefined;
    const Exec = Executor(g, &.{ MonoSource, Gain, Biquad, MonoSink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = k },
        .{ .coeffs = coeffs },
        .{ .dest = &exec_out },
    } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    // --- hand-run reference ---
    var a: [N]Sample(f32) = undefined;
    var b: [N]Sample(f32) = undefined;
    var ref_out: [N]Sample(f32) = undefined;
    var ref_src = MonoSource{ .data = &input };
    var ref_gain = Gain{ .gain = k };
    var ref_bq = Biquad{ .coeffs = coeffs };
    var ref_sink = MonoSink{ .dest = &ref_out };
    ref_src.process(&a);
    ref_gain.process(&a, &b);
    ref_bq.process(&b, &a); // biquad: distinct in/out (not aliasing-safe); reuse `a`
    ref_sink.process(&a);

    try h.bitExact(f32, h.sampleValues(&exec_out), h.sampleValues(&ref_out));
    try std.testing.expect(!exec.telemetry().fault);
}

test "executor: layout-changing pan chain (mono→stereo) ≡ hand-run, bit-exact" {
    // ConstantPowerPan is the canonical layout-changing Map: a mono input, a
    // stereo output. The executor must size the downstream pool buffer for the
    // STEREO element (8 bytes/frame) and the StereoSink must receive both lanes.
    const Pan = spatial.ConstantPowerPan(num_f32);
    const N = 12;

    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const pan_node = gg.add(Pan);
        const sink = gg.add(StereoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Pan), pan_node, 0);
        gg.connect(port.MapOutPort(Pan), pan_node, 0, port.MapInPort(StereoSink), sink, 0);
        break :blk gg;
    };

    var input: [N]Sample(f32) = undefined;
    h.fillNoise(&input, 0xACE5);

    const pos: f32 = 0.37; // an off-center position so L ≠ R

    // --- executor path ---
    // Plane-major stereo destination: [L-plane(N)][R-plane(N)].
    var exec_out: [2 * N]f32 = undefined;
    const Exec = Executor(g, &.{ MonoSource, Pan, StereoSink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .pan = pos },
        .{ .dest = &exec_out },
    } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    // --- hand-run reference --- (same kernels, hand-plumbed through the planar
    // view; the only variable vs the executor is the pool gather/scatter)
    var mid: [N]Sample(f32) = undefined;
    var stereo: [2 * N]f32 = undefined;
    var ref_out: [2 * N]f32 = undefined;
    var ref_src = MonoSource{ .data = &input };
    var ref_pan = Pan{ .pan = pos };
    var ref_sink = StereoSink{ .dest = &ref_out };
    ref_src.process(&mid);
    ref_pan.process(&mid, pan.Planar(f32, .stereo).fromBase(&stereo, N));
    ref_sink.process(pan.PlanarConst(f32, .stereo).fromBase(&stereo, N));

    // Pan-vs-pan: bit-exact over the plane-major bytes.
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(ref_out[0..]), std.mem.sliceAsBytes(exec_out[0..]));
    try std.testing.expect(!exec.telemetry().fault);

    // And independently confirm the layout change actually happened: an
    // off-center pan must give L ≠ R for a non-zero sample (else the test would
    // pass vacuously even if the stereo lane were dropped). L-plane is the first
    // N lanes, R-plane the next N.
    var saw_distinct = false;
    for (0..N) |i| {
        if (exec_out[i] != exec_out[N + i]) saw_distinct = true;
    }
    try std.testing.expect(saw_distinct);
}

test "executor: identity gain (unity) is a pure pass-through, bit-exact to source" {
    // A boundary value: gain = 1.0 must leave the signal byte-for-byte unchanged
    // through the whole pool round-trip (source → gain → sink). This pins that
    // the executor does not perturb data it merely transports.
    const Gain = filters.Gain(num_f32);
    const N = 32;
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
    var input: [N]Sample(f32) = undefined;
    h.fillNoise(&input, 99);
    var out: [N]Sample(f32) = undefined;
    const Exec = Executor(g, &.{ MonoSource, Gain, MonoSink });
    var exec: Exec = .{ .instances = .{ .{ .data = &input }, .{ .gain = 1.0 }, .{ .dest = &out } } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);
    try h.bitExact(f32, h.sampleValues(&out), h.sampleValues(&input));
}

// ===========================================================================
// 2. The render path requires a RealtimeToken (positive witness).
// ===========================================================================
//
// The negative (omitting the token fails to compile) is a structural ⊢ fact we
// cannot assert at runtime without breaking the build. We pin the positive: the
// token threads through and the render runs, and the token field witnessing
// realtime entry is set.

test "executor: render consumes a RealtimeToken and runs under it (⊢ witness, positive)" {
    const Gain = filters.Gain(num_f32);
    const N = 4;
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
    var input = [_]Sample(f32){ .{ .ch = .{1} }, .{ .ch = .{2} }, .{ .ch = .{3} }, .{ .ch = .{4} } };
    var out: [N]Sample(f32) = undefined;
    const Exec = Executor(g, &.{ MonoSource, Gain, MonoSink });
    var exec: Exec = .{ .instances = .{ .{ .data = &input }, .{ .gain = 2.0 }, .{ .dest = &out } } };

    const token = enterRealtimeThread();
    defer token.leave();
    // The signature would not type-check without the token argument; this call
    // compiling at all is the structural proof. Passing it and running is the
    // positive witness.
    try std.testing.expect(token._entered);
    exec.render(token);
    for (input, out) |x, y| try std.testing.expectEqual(x.ch[0] * 2.0, y.ch[0]);
}

// ===========================================================================
// 3. Flush-to-zero is live after enterRealtimeThread().
// ===========================================================================

test "realtime token: flush-to-zero underflows a subnormal-times-itself to exactly 0" {
    const token = enterRealtimeThread();
    defer token.leave();
    // Only meaningful where the target has an FP control word (ARM64/x86). On a
    // soft-float target the token is a structural no-op and FTZ is unobservable.
    if (token.fpenv.active) {
        const tiny: f32 = std.math.floatMin(f32) / 2.0; // a genuine subnormal
        var x: f32 = tiny;
        std.mem.doNotOptimizeAway(&x); // defeat constant folding: run it live
        const y = x * x; // underflows; with FTZ the result is flushed to +0
        std.mem.doNotOptimizeAway(y);
        try std.testing.expectEqual(@as(f32, 0.0), y);
        // Bit-exact: it must be +0.0, not −0.0.
        try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(y)));
    } else {
        // Record that this build has no FP control word; the token is a no-op.
        try std.testing.expect(token.fpenv.saved == 0);
    }
}

test "realtime token: leave() restores the FP environment (saved word round-trips)" {
    // After leave(), a thread that does non-pan float work expects the default
    // (gradual-underflow) environment back. We can only witness this structurally
    // on a target with a control word: enter twice and confirm the second enter
    // observes the same restored baseline as the first (idempotent re-entry).
    const t1 = enterRealtimeThread();
    const saved1 = t1.fpenv.saved;
    t1.leave();
    const t2 = enterRealtimeThread();
    defer t2.leave();
    if (t1.fpenv.active and t2.fpenv.active) {
        // leave() put the pre-token word back, so re-entering sees the same
        // baseline it saw the first time.
        try std.testing.expectEqual(saved1, t2.fpenv.saved);
    }
}

// ===========================================================================
// 4. Error isolation: a poison block's output is silenced and fault is raised.
// ===========================================================================
//
// The guard is compiled out in release (guards_compiled_out == true), so this
// only runs in Debug / ReleaseSafe. A block that writes a NaN must have its
// output buffer zeroed and the executor's `fault` flag set.

/// A poison Map: writes a NaN into every output element (a misbehaving kernel).
const PoisonNaN = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        _ = in;
        const nan = std.math.nan(f32);
        for (out) |*o| o.ch[0] = nan;
    }
};

/// A poison Map that writes +Inf — the OTHER non-finite the guard must catch.
const PoisonInf = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        _ = in;
        const inf = std.math.inf(f32);
        for (out) |*o| o.ch[0] = inf;
    }
};

test "executor: a NaN-emitting block is silenced (output zeroed) and raises fault" {
    if (!std.debug.runtime_safety) return error.SkipZigTest; // guard compiled out

    const N = 8;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const poison = gg.add(PoisonNaN);
        const sink = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(PoisonNaN), poison, 0);
        gg.connect(port.MapOutPort(PoisonNaN), poison, 0, port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };
    var input: [N]Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var out: [N]Sample(f32) = undefined;
    const Exec = Executor(g, &.{ MonoSource, PoisonNaN, MonoSink });
    var exec: Exec = .{ .instances = .{ .{ .data = &input }, .{}, .{ .dest = &out } } };

    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    // The poisoned buffer was silenced before the sink read it, so every sink
    // output is exactly +0.0 (no NaN survives to the device), and fault is set.
    try std.testing.expect(exec.telemetry().fault);
    for (out) |o| {
        try std.testing.expect(!std.math.isNan(o.ch[0]));
        try std.testing.expectEqual(@as(f32, 0.0), o.ch[0]);
    }
}

test "executor: a +Inf-emitting block is silenced and raises fault (Inf, not just NaN)" {
    if (!std.debug.runtime_safety) return error.SkipZigTest;

    const N = 8;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const poison = gg.add(PoisonInf);
        const sink = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(PoisonInf), poison, 0);
        gg.connect(port.MapOutPort(PoisonInf), poison, 0, port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };
    var input: [N]Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var out: [N]Sample(f32) = undefined;
    const Exec = Executor(g, &.{ MonoSource, PoisonInf, MonoSink });
    var exec: Exec = .{ .instances = .{ .{ .data = &input }, .{}, .{ .dest = &out } } };

    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    try std.testing.expect(exec.telemetry().fault);
    for (out) |o| {
        try std.testing.expect(std.math.isFinite(o.ch[0]));
        try std.testing.expectEqual(@as(f32, 0.0), o.ch[0]);
    }
}

test "executor: a clean render leaves fault FALSE (the guard does not over-trip)" {
    // The counterexample to the fault tests: a finite-output chain must NOT raise
    // fault. A guard that fired spuriously would pass the poison tests yet be
    // wrong; this distinguishes correct isolation from a stuck flag.
    const Gain = filters.Gain(num_f32);
    const N = 8;
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
    var input: [N]Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
    var out: [N]Sample(f32) = undefined;
    const Exec = Executor(g, &.{ MonoSource, Gain, MonoSink });
    var exec: Exec = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.25 }, .{ .dest = &out } } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);
    try std.testing.expect(!exec.telemetry().fault);
}

// ===========================================================================
// 5. The committed plan agrees with commitComptime; guard-flag tracks build.
// ===========================================================================

test "executor: Exec.committed footprint_bytes & op_count match commitComptime for the same graph" {
    const Gain = filters.Gain(num_f32);
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
    const Exec = Executor(g, &.{ MonoSource, Gain, MonoSink });
    const plan = comptime try commit.commitComptime(g);

    // The executor's frozen plan IS the commit pass's plan for this graph.
    try std.testing.expectEqual(plan.footprint_bytes, Exec.committed.footprint_bytes);
    try std.testing.expectEqual(plan.op_count, Exec.committed.op_count);
    try std.testing.expectEqual(plan.pool_bytes, Exec.committed.pool_bytes);

    // And the concrete numbers, so the test fails if the layout silently shifts:
    // one op per node (3). `Gain` is a single-consumer unary `aliasing_safe` Map,
    // so the colored pool COALESCES its output in place into the source buffer —
    // the whole mono chain reuses ONE pool buffer of N·4 bytes (not the naive
    // two-buffer ping-pong). The B≡C differential proves this in-place result is
    // bit-identical to the per-edge baseline.
    try std.testing.expectEqual(@as(usize, 3), Exec.committed.op_count);
    try std.testing.expectEqual(@as(usize, 1 * N * @sizeOf(Sample(f32))), Exec.committed.footprint_bytes);
}

test "executor: layout-changing chain's footprint sizes the downstream buffer for stereo" {
    // The pan's output buffer is a STEREO frame (8 bytes), not mono (4). The
    // colored pool's two buffers therefore differ in width — pinning that the
    // commit pass keys the buffer length off the element class, not a fixed lane.
    const Pan = spatial.ConstantPowerPan(num_f32);
    const N = 16;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const pan_node = gg.add(Pan);
        const sink = gg.add(StereoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Pan), pan_node, 0);
        gg.connect(port.MapOutPort(Pan), pan_node, 0, port.MapInPort(StereoSink), sink, 0);
        break :blk gg;
    };
    const Exec = Executor(g, &.{ MonoSource, Pan, StereoSink });
    const plan = comptime try commit.commitComptime(g);
    try std.testing.expectEqual(plan.footprint_bytes, Exec.committed.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 3), Exec.committed.op_count);
    // Footprint must account for at least one mono (4B) + one stereo (8B) buffer
    // over N frames, i.e. strictly more than two mono buffers would need.
    try std.testing.expect(Exec.committed.footprint_bytes >= N * (@sizeOf(Sample(f32)) + @sizeOf(Frame(f32, .stereo))));
}

test "executor: guards_compiled_out equals !runtime_safety and telemetry mirrors it" {
    const Gain = filters.Gain(num_f32);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 8;
        const src = gg.add(MonoSource);
        const gain = gg.add(Gain);
        const sink = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };
    const Exec = Executor(g, &.{ MonoSource, Gain, MonoSink });
    var input: [8]Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i);
    var out: [8]Sample(f32) = undefined;
    var exec: Exec = .{ .instances = .{ .{ .data = &input }, .{ .gain = 1.0 }, .{ .dest = &out } } };

    // The build-mode contract: a release build can never SILENTLY drop the
    // safety net — it must report that the guards are gone.
    try std.testing.expectEqual(!std.debug.runtime_safety, exec.tele.guards_compiled_out);
    try std.testing.expectEqual(!std.debug.runtime_safety, exec.telemetry().guards_compiled_out);
    // A fresh executor has not faulted.
    try std.testing.expect(!exec.telemetry().fault);
}

test "executor: committed.footprint_bytes is a comptime constant usable as an array length" {
    // The whole point of the comptime commit is a `.bss`-sizable pool. If the
    // footprint were not comptime-known this would not compile — so the build
    // passing IS the discharge of that promise for the bound executor.
    const Gain = filters.Gain(num_f32);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 8;
        const src = gg.add(MonoSource);
        const gain = gg.add(Gain);
        const sink = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };
    const Exec = Executor(g, &.{ MonoSource, Gain, MonoSink });
    const proof: [Exec.committed.footprint_bytes]u8 = undefined;
    comptime std.debug.assert(proof.len > 0);
    try std.testing.expect(proof.len == Exec.committed.footprint_bytes);
}

// ===========================================================================
// 6. Determinism: two renders of the same stateless graph agree bit-exact.
// ===========================================================================

test "executor: re-rendering a stateless graph is bit-exact reproducible" {
    // The Tier-A render is wait-free and deterministic: feeding the same input
    // twice through the same (stateless) executor yields byte-identical output.
    // (A stateful Biquad would NOT satisfy this without a reset, which is why the
    // graph here is the stateless Gain only — the property is about the executor
    // plumbing, not block state.)
    const Gain = filters.Gain(num_f32);
    const N = 16;
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
    var input: [N]Sample(f32) = undefined;
    h.fillNoise(&input, 0x1234);
    const Exec = Executor(g, &.{ MonoSource, Gain, MonoSink });

    var out1: [N]Sample(f32) = undefined;
    var out2: [N]Sample(f32) = undefined;
    var exec: Exec = .{ .instances = .{ .{ .data = &input }, .{ .gain = 0.6 }, .{ .dest = &out1 } } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);
    exec.instances[2].dest = &out2;
    exec.render(token);

    try h.bitExact(f32, h.sampleValues(&out2), h.sampleValues(&out1));
}
