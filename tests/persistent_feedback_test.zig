//! persistent_feedback_test — the Yoneda characterization of graph-level feedback
//! EXECUTION and its commit handling (Phase 6).
//!
//! Graph-level feedback is understood here through ALL its observable morphisms,
//! across three independent facets that together pin its behaviour completely:
//!
//!   (A) SCC-HAS-DELAY (⊢ decidable, commit-time). The causality law: a feedback
//!       cycle is legal IFF it contains a delay element. A cycle WITH a delay
//!       (`DelayLine`/`UnitDelay`, or a fused `Comb`/`Allpass`/`KarplusStrong` —
//!       all declare `delay_len`) commits; a cycle with NO delay is rejected with
//!       `error.DelayFreeLoop`. Checked by exact `commitComptime` success and by
//!       `std.testing.expectError` — there is no oracle but the law itself.
//!
//!   (B) FOOTPRINT (⊢ comptime constant). For a feedback graph the H2 reporting
//!       figure `footprint_bytes` is derived BY HAND from the locked formula
//!       `Σ_class M_class·N·elem + Σ_delay delay_len·elem + Σ_block state_size`
//!       and asserted exactly. The persistent region is the z⁻¹ tail: a feedback
//!       graph has `persistent_bytes > 0` and `pool_bytes < footprint`; a graph
//!       with NO feedback has `persistent_bytes == 0` and `pool_bytes ==
//!       footprint_bytes`. The feedback EDGE itself contributes NO footprint term
//!       (only the delay element's ring does) — pinned by a counter-example.
//!
//!   (C) EXECUTION (pan-vs-pan, BIT-EXACT where two pan runs are compared). A
//!       comb-style feedback graph (source → 2-input summer → delay → sink, with
//!       the delay fed back into the summer's second input via `connectFeedback`)
//!       is driven with an impulse then silence. The defining facts: the dry
//!       impulse appears on block 0; the loop ECHOES on later blocks (the
//!       persistent tail carries signal ACROSS `render` calls); every output
//!       sample is `std.math.isFinite`; and for a stable gain |g|<1 the peak is
//!       NON-GROWING. Where two pan renders are compared (determinism / pool-mode
//!       agreement) the check is BIT-EXACT (`expectEqual`), an "almost" being a
//!       failure, not a pass.
//!
//! COMPARISON MODE: facets (A) and (B) are ⊢ decidable (exact equality /
//! `expectError`); facet (C)'s decay/finite/stability are qualitative
//! (`isFinite` + monotone-peak), and its determinism check is pan-vs-pan ⇒
//! BIT-EXACT. There is no external numerical oracle.
//!
//! Verified against zig 0.16.0 (the `zig-0-16` skill was loaded before authoring,
//! per project Rules 13/14). Expected-reject paths use `std.testing.expectError`
//! (no logging); any incidental print uses `std.debug.print`, never
//! `std.log.err` (the 0.16 test runner counts logged errors as failures).

const std = @import("std");
const pan = @import("pan");

const commit = pan.commit;
const graph = pan.graph;
const port = pan.port;
const engine = pan.engine;
const numeric = pan.numeric;

const Sample = pan.Sample;
const DelayLine = pan.DelayLine;
const UnitDelay = pan.UnitDelay;
const Comb = pan.Comb;
const Executor = engine.Executor;
const enterRealtimeThread = pan.enterRealtimeThread;

const num_f32 = numeric.numericFor(.f32, .{});

const S = Sample(f32);

// ===========================================================================
// Author-local boundary + arithmetic blocks. Small `Map` structs with a
// `process`, exactly as `tests/executor_test.zig` defines MonoSource/MonoSink.
// `Sample(f32) = struct { ch: [1]f32 }`.
// ===========================================================================

/// Mono source: copies a preloaded backing store into the output (zero sample
/// inputs — it fills its output from its own store, so it is a generator/source).
const Source = struct {
    data: [*]const S = undefined,
    pub fn process(self: *@This(), out: []S) void {
        @memcpy(out, self.data[0..out.len]);
    }
};

/// Mono sink: drains its input to a destination backing store (zero outputs).
const Sink = struct {
    dest: [*]S = undefined,
    pub fn process(self: *@This(), in: []const S) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

/// Two-input feedback summer: `out = dry + g·wet`. Port 0 is the forward (dry)
/// input; port 1 is the feedback (wet) z⁻¹ tap read from the persistent buffer
/// the loop's delay element wrote last block. The `process` arg order matches the
/// commit pass's gather order (forward edges in declaration order, then feedback
/// read-sides), so `dry` is the port-0 forward edge and `wet` is the port-1
/// feedback edge.
const Summer = struct {
    g: f32 = 0.5,
    pub fn process(self: *@This(), dry: []const S, wet: []const S, out: []S) void {
        for (dry, wet, out) |d, w, *y| y.ch[0] = d.ch[0] + self.g * w.ch[0];
    }
};

/// A plain unary identity Map (no `delay_len`) — NOT a delay element. Used to
/// build a delay-FREE loop that must be rejected, and as a non-delay member of an
/// otherwise-legal cycle.
const Pass = struct {
    pub fn process(self: *@This(), in: []const S, out: []S) void {
        _ = self;
        @memcpy(out, in);
    }
};

// ===========================================================================
// (A) SCC-HAS-DELAY — the causality law, ⊢ decidable at commit time.
//     A cycle with a delay element commits; a cycle without one is rejected.
// ===========================================================================

test "scc-has-delay: a feedback cycle CONTAINING a DelayLine commits (causal)" {
    const N = 4;
    const Delay = DelayLine(S, N);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const delay = gg.add(Delay);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Delay), delay, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Delay), delay, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    // The SCC {sum, delay} contains the delay element ⇒ commits (no DelayFreeLoop).
    const plan = comptime try commit.commitComptime(g);
    try std.testing.expectEqual(@as(usize, 4), plan.op_count);
}

test "scc-has-delay: a UnitDelay (delay_len==1) in the cycle is sufficient to commit" {
    // The smallest possible delay element. UnitDelay == DelayLine(_, 1); its
    // single-sample z⁻¹ is exactly what makes the loop causal.
    const N = 4;
    const Z = UnitDelay(S);
    try std.testing.expectEqual(@as(usize, 1), Z.delay_len);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const z = gg.add(Z);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Z), z, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Z), z, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    _ = comptime try commit.commitComptime(g);
}

test "scc-has-delay: a fused Comb (declares delay_len) in the cycle commits" {
    // A fused tight-feedback kernel from src/fx.zig is ALSO a delay element (it
    // declares delay_len), so a graph-level loop routed THROUGH a Comb is causal
    // and commits — the SCC-has-delay check looks only for `is_delay`, not for a
    // specific block type.
    const N = 8;
    const Cmb = Comb(num_f32, 64);
    try std.testing.expect(@hasDecl(Cmb, "delay_len"));
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const cmb = gg.add(Cmb);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Cmb), cmb, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Cmb), cmb, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    _ = comptime try commit.commitComptime(g);
}

test "scc-has-delay: a feedback cycle with NO delay element is error.DelayFreeLoop" {
    // The counterexample. Replace the delay with a plain identity Map: the cycle
    // {sum, pass} has no delay element, so its output would depend on itself within
    // the block — not causal ⇒ rejected. This is the law's negative side, the one
    // that distinguishes a correct check from one that accepts every declared loop.
    const N = 4;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const pass = gg.add(Pass);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Pass), pass, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Pass), pass, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    try std.testing.expectError(error.DelayFreeLoop, comptime commit.commitComptime(g));
}

test "scc-has-delay: a self-loop feedback edge with no delay is also DelayFreeLoop" {
    // The singleton-SCC case: a node whose own output feeds back into its own input
    // with NO delay is a self-cycle and equally non-causal. The summer feeds its own
    // port-1 from its own output. Distinguishes the self-edge branch of the SCC check.
    const N = 4;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Summer), sum, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    try std.testing.expectError(error.DelayFreeLoop, comptime commit.commitComptime(g));
}

// ===========================================================================
// (B) FOOTPRINT — ⊢ comptime constant, derived BY HAND from the locked formula.
// ===========================================================================

test "footprint: feedback comb graph footprints to the hand-derived locked formula" {
    // Topology: src → sum → {delay, sink} ; delay → sum (feedback). At N=256, f32.
    //
    // The locked formula is
    //     Σ_class M_class·N·elem  +  Σ_delay delay_len·elem  +  Σ_block state_size.
    //
    // POOL (Σ_class M_class·N·elem): the only pooled element class is Sample(f32)
    // (elem = 4 B). Pool buffers (the colored scratch): the source's output value
    // and the summer's output value are the only POOL-ELIGIBLE values — the delay's
    // output feeds ONLY the feedback read-side, so it is a PERSISTENT (pool-excluded)
    // value and never colored. The summer is not aliasing_safe, so no in-place
    // coalescing collapses the source/summer buffers; with overlapping live ranges
    // they take 2 colors ⇒ M_Sample = 2. Pool = 2 · 256 · 4 = 2048 B.
    //
    // DELAY rings (Σ_delay delay_len·elem): the DelayLine ring is 480 · 4 = 1920 B.
    // (It lives in the block instance — counted by footprint, NOT in the flat pool.)
    //
    // BLOCK state (Σ_block state_size): DelayLine.state_size = @sizeOf(usize) = 8 B;
    // every other block here declares no state_size ⇒ 0. So Σ_block = 8 B.
    //
    // The feedback EDGE itself adds NO footprint term — only the delay element's
    // ring does. footprint = 2048 + 1920 + 8 = 3976 B.
    const N = 256;
    const Delay = DelayLine(S, 480);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const delay = gg.add(Delay);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Delay), delay, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Delay), delay, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);

    const elem = @sizeOf(S); // 4
    const expect_pool: usize = 2 * N * elem; // 2048
    const expect_delay_rings: usize = 480 * elem; // 1920
    const expect_state: usize = @sizeOf(usize); // DelayLine.state_size = 8
    const expect_footprint = expect_pool + expect_delay_rings + expect_state;

    try std.testing.expectEqual(@as(usize, 2048), expect_pool);
    try std.testing.expectEqual(@as(usize, 1920), expect_delay_rings);
    try std.testing.expectEqual(@as(usize, 3976), expect_footprint);

    try std.testing.expectEqual(expect_pool, plan.pool_bytes);
    try std.testing.expectEqual(expect_footprint, plan.footprint_bytes);
}

test "footprint: a feedback graph has a non-empty persistent z⁻¹ tail (pool < footprint)" {
    // The persistent region IS the feedback z⁻¹ tail: one block of N elements per
    // distinct feedback source, surviving the callback boundary. For a feedback
    // graph it is strictly positive, sized N·elem, and lives PAST pool_bytes.
    const N = 8;
    const Delay = DelayLine(S, N);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const delay = gg.add(Delay);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Delay), delay, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Delay), delay, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);
    // Exactly one distinct feedback source ⇒ one z⁻¹ buffer of N·elem.
    try std.testing.expectEqual(@as(usize, N * @sizeOf(S)), plan.persistent_bytes);
    try std.testing.expect(plan.persistent_bytes > 0);
    // The tail is separate from the scratch pool, so the pool is strictly smaller
    // than the full footprint (which also counts the delay ring + state).
    try std.testing.expect(plan.pool_bytes < plan.footprint_bytes);
}

test "footprint: a NO-feedback graph has persistent_bytes==0 and pool_bytes==footprint" {
    // The counter-example pinning that the persistent tail exists IFF there is a
    // feedback edge. A pure forward chain src → sum(dry only) → sink has no
    // feedback, no delay element, no block state ⇒ persistent_bytes == 0 and
    // pool_bytes == footprint_bytes (the H2 figure is just the colored pool).
    //
    // Here the summer's port-1 (wet) is driven by a SECOND forward source, so it is
    // a plain DAG (no cycle, no delay element, no stateful block). The defining
    // facts for a no-feedback graph: persistent_bytes == 0 and the H2 footprint IS
    // the colored pool (no delay-ring term, no block-state term to add on top).
    const N = 16;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const a = gg.add(Source);
        const b = gg.add(Source);
        const sum = gg.add(Summer);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), a, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Source), b, 0, port.MapInPortAt(Summer, 1), sum, 1);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        break :blk gg;
    };
    const plan = comptime try commit.commitComptime(g);
    // No feedback edge ⇒ no z⁻¹ tail.
    try std.testing.expectEqual(@as(usize, 0), plan.persistent_bytes);
    // With no delay ring and no stateful block, the H2 footprint is exactly the
    // colored scratch pool — nothing is added on top of pool_bytes.
    try std.testing.expectEqual(plan.footprint_bytes, plan.pool_bytes);
    // The pool is a whole number of N·elem Sample(f32) buffers (the only class),
    // and at least 2 (the two live source buffers feeding the summer concurrently
    // cannot share a color). The exact color count is the colorer's business; the
    // footprint-is-pool-only invariant is what this test pins.
    const buf = N * @sizeOf(S);
    try std.testing.expect(plan.footprint_bytes >= 2 * buf);
    try std.testing.expectEqual(@as(usize, 0), plan.footprint_bytes % buf);
}

test "footprint: the feedback EDGE adds no footprint term — only the delay ring does" {
    // Differential: two graphs identical except the delay's ring length (4 vs 64).
    // Both have ONE feedback edge of the same element class, so the persistent tail
    // is IDENTICAL (N·elem) and the POOL is identical — the feedback edge itself
    // contributes nothing to the footprint. The ONLY footprint difference is the
    // delay-ring term (64−4)·elem, proving the feedback edge is footprint-free.
    const N = 4;
    const Short = DelayLine(S, 4);
    const Long = DelayLine(S, 64);

    const g_short = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const delay = gg.add(Short);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Short), delay, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Short), delay, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    const g_long = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const delay = gg.add(Long);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Long), delay, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Long), delay, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    const ps = comptime try commit.commitComptime(g_short);
    const pl = comptime try commit.commitComptime(g_long);

    // Same pool, same persistent tail (the feedback edge is footprint-free).
    try std.testing.expectEqual(ps.pool_bytes, pl.pool_bytes);
    try std.testing.expectEqual(ps.persistent_bytes, pl.persistent_bytes);
    // The whole footprint delta is exactly the extra delay-ring bytes (60·4 = 240),
    // plus zero from state (both DelayLine.state_size == @sizeOf(usize), equal).
    const elem = @sizeOf(S);
    try std.testing.expectEqual((64 - 4) * elem, pl.footprint_bytes - ps.footprint_bytes);
}

// ===========================================================================
// (C) EXECUTION — the Executor renders a DelayLine-in-a-cycle: impulse appears
//     immediately, the loop echoes across callbacks, stays finite, and decays.
// ===========================================================================

/// Build the canonical comb-feedback graph at comptime: src → sum.0 ;
/// sum → {delay, sink} ; delay → sum.1 (feedback). The delay length equals the
/// block size N, so the loop period is exactly one callback (each render's wet tap
/// is the previous render's summer output).
fn combGraph(comptime N: usize) graph.Graph {
    const Delay = DelayLine(S, N);
    return comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(Source);
        const sum = gg.add(Summer);
        const delay = gg.add(Delay);
        const sink = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), src, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Delay), delay, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Sink), sink, 0);
        gg.connectFeedback(port.MapOutPort(Delay), delay, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
}

test "execution: impulse appears on block 0, then the loop echoes across callbacks" {
    const N = 4;
    const g = comptime combGraph(N);
    const Delay = DelayLine(S, N);
    const Exec = Executor(g, &.{ Source, Summer, Delay, Sink });

    var impulse: [N]S = @splat(.{ .ch = .{0} });
    impulse[0] = .{ .ch = .{1} }; // unit impulse on block 0
    var silence: [N]S = @splat(.{ .ch = .{0} });
    var out: [N]S = undefined;

    var exec: Exec = .{ .instances = .{
        .{ .data = &impulse },
        .{ .g = 0.5 },
        .{},
        .{ .dest = &out },
    } };
    const token = enterRealtimeThread();
    defer token.leave();

    // Block 0: the dry impulse passes straight through (the persistent z⁻¹ tail
    // started silent, so the wet tap contributes nothing this block). The summer
    // output [1,0,0,0] is what gets pushed into the delay this block.
    exec.render(token);
    try std.testing.expectEqual(@as(f32, 1), out[0].ch[0]);
    for (1..N) |i| try std.testing.expectEqual(@as(f32, 0), out[i].ch[0]);
    try std.testing.expect(!exec.telemetry().fault);

    // The exact echo schedule (verified by an independent hand-trace of the same
    // DelayLine recurrence): with N==4, a DelayLine(_, 4) emits ONE block of zero
    // pre-roll before re-emitting what was pushed into it, so the loop's round-trip
    // latency is TWO callbacks (the delay's own pre-roll block + the read-side z⁻¹).
    // Hence the echo recirculates every 2 blocks, halving each round:
    //   block 0 → 1 (dry impulse) ; block 1 → 0 ; block 2 → 0.5 ;
    //   block 3 → 0 ; block 4 → 0.25 ; ...
    // The non-zero echoes are PROOF the persistent tail carried signal across the
    // callback boundary; an executor that did not persist the z⁻¹ would output 0
    // on every block after the first.
    const want = [_]f32{ 0, 0.5, 0, 0.25, 0, 0.125 }; // blocks 1..6
    exec.instances[0].data = &silence;
    for (want) |expected| {
        exec.render(token);
        try std.testing.expectEqual(expected, out[0].ch[0]);
        for (1..N) |i| try std.testing.expectEqual(@as(f32, 0), out[i].ch[0]);
        try std.testing.expect(!exec.telemetry().fault);
    }
}

test "execution: every output is finite and the peak is non-growing for |g|<1 (stable)" {
    // Drive an impulse then a long silence and assert the two qualitative laws of a
    // stable feedback loop: (i) every sample stays finite (no NaN/Inf leaks from the
    // recirculation), and (ii) the per-block peak never grows (|g|<1 ⇒ contraction).
    const N = 4;
    const g = comptime combGraph(N);
    const Delay = DelayLine(S, N);
    const Exec = Executor(g, &.{ Source, Summer, Delay, Sink });

    var impulse: [N]S = @splat(.{ .ch = .{0} });
    impulse[0] = .{ .ch = .{1} };
    var silence: [N]S = @splat(.{ .ch = .{0} });
    var out: [N]S = undefined;

    var exec: Exec = .{ .instances = .{
        .{ .data = &impulse },
        .{ .g = 0.5 },
        .{},
        .{ .dest = &out },
    } };
    const token = enterRealtimeThread();
    defer token.leave();

    exec.render(token); // block 0: the impulse
    var prev_peak: f32 = 1;
    for (out) |s| try std.testing.expect(std.math.isFinite(s.ch[0]));

    exec.instances[0].data = &silence;
    var saw_echo = false;
    for (0..16) |_| {
        exec.render(token);
        var peak: f32 = 0;
        for (out) |s| {
            try std.testing.expect(std.math.isFinite(s.ch[0]));
            peak = @max(peak, @abs(s.ch[0]));
        }
        if (peak > 0) saw_echo = true;
        // Non-growing: a stable loop contracts (small epsilon for fp slack).
        try std.testing.expect(peak <= prev_peak + 1e-6);
        if (peak > 0) prev_peak = peak;
    }
    try std.testing.expect(saw_echo); // the feedback path actually carried signal
    try std.testing.expect(!exec.telemetry().fault);
}

test "execution: a marginally-stable g==1 loop neither grows nor leaks (boundary)" {
    // The boundary value |g| == 1: the loop is on the edge of stability. With an
    // impulse then silence and a one-block delay, the echo recirculates at constant
    // amplitude (no decay, no growth). The defining facts at the boundary: still
    // finite, and the peak is still NON-GROWING (it plateaus at the impulse height,
    // never exceeding it) — a check that a buggy loop accumulating energy would fail.
    const N = 4;
    const g = comptime combGraph(N);
    const Delay = DelayLine(S, N);
    const Exec = Executor(g, &.{ Source, Summer, Delay, Sink });

    var impulse: [N]S = @splat(.{ .ch = .{0} });
    impulse[0] = .{ .ch = .{1} };
    var silence: [N]S = @splat(.{ .ch = .{0} });
    var out: [N]S = undefined;

    var exec: Exec = .{ .instances = .{
        .{ .data = &impulse },
        .{ .g = 1.0 },
        .{},
        .{ .dest = &out },
    } };
    const token = enterRealtimeThread();
    defer token.leave();

    exec.render(token);
    try std.testing.expectEqual(@as(f32, 1), out[0].ch[0]);

    exec.instances[0].data = &silence;
    for (0..16) |_| {
        exec.render(token);
        for (out) |s| {
            try std.testing.expect(std.math.isFinite(s.ch[0]));
            // g==1, one-block delay, single impulse ⇒ the echo is constant-amplitude
            // 1.0 and never exceeds the original impulse: no energy accumulation.
            try std.testing.expect(@abs(s.ch[0]) <= 1.0 + 1e-6);
        }
    }
    try std.testing.expect(!exec.telemetry().fault);
}

test "execution: re-running the loop from a fresh executor is bit-exact reproducible" {
    // pan-vs-pan determinism: two FRESH executors (each starts with a zeroed
    // persistent tail and zeroed delay rings) fed the identical impulse-then-silence
    // schedule must produce byte-identical sink output every block. The persistent
    // z⁻¹ state is therefore a pure function of the input history — not of any
    // residual cross-run state. An "almost" here is a failure, so this is BIT-EXACT.
    const N = 4;
    const g = comptime combGraph(N);
    const Delay = DelayLine(S, N);
    const Exec = Executor(g, &.{ Source, Summer, Delay, Sink });
    const blocks = 10;

    var impulse: [N]S = @splat(.{ .ch = .{0} });
    impulse[0] = .{ .ch = .{1} };
    var silence: [N]S = @splat(.{ .ch = .{0} });

    const token = enterRealtimeThread();
    defer token.leave();

    var run_a: [blocks][N]S = undefined;
    var run_b: [blocks][N]S = undefined;

    inline for (.{ &run_a, &run_b }) |runp| {
        var out: [N]S = undefined;
        var exec: Exec = .{ .instances = .{
            .{ .data = &impulse },
            .{ .g = 0.5 },
            .{},
            .{ .dest = &out },
        } };
        for (0..blocks) |b| {
            if (b == 1) exec.instances[0].data = &silence;
            exec.render(token);
            runp[b] = out;
        }
    }

    // Byte-identical across the two runs, block for block.
    for (0..blocks) |b| {
        try std.testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(run_a[b][0..]),
            std.mem.sliceAsBytes(run_b[b][0..]),
        );
    }
}

test "execution: the colored pool and the per-edge baseline agree bit-exact (B≡C)" {
    // The shipped colored pool reuses scratch buffers; the per-edge baseline gives
    // every value its own buffer. For the SAME feedback graph + instances + input
    // schedule the two must compute byte-identical sink output — a divergence would
    // be a colorer/persistent-tail bug, never numerics (both share every kernel).
    // This is the differential that catches an unsafe buffer reuse around the loop.
    const N = 4;
    const g = comptime combGraph(N);
    const Delay = DelayLine(S, N);
    const ExecC = engine.ExecutorMode(g, &.{ Source, Summer, Delay, Sink }, .colored);
    const ExecB = engine.ExecutorMode(g, &.{ Source, Summer, Delay, Sink }, .per_edge);
    const blocks = 8;

    var impulse: [N]S = @splat(.{ .ch = .{0} });
    impulse[0] = .{ .ch = .{1} };
    var silence: [N]S = @splat(.{ .ch = .{0} });

    const token = enterRealtimeThread();
    defer token.leave();

    var out_c: [N]S = undefined;
    var out_b: [N]S = undefined;
    var exec_c: ExecC = .{ .instances = .{ .{ .data = &impulse }, .{ .g = 0.5 }, .{}, .{ .dest = &out_c } } };
    var exec_b: ExecB = .{ .instances = .{ .{ .data = &impulse }, .{ .g = 0.5 }, .{}, .{ .dest = &out_b } } };

    for (0..blocks) |b| {
        if (b == 1) {
            exec_c.instances[0].data = &silence;
            exec_b.instances[0].data = &silence;
        }
        exec_c.render(token);
        exec_b.render(token);
        try std.testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(out_b[0..]),
            std.mem.sliceAsBytes(out_c[0..]),
        );
    }
}
