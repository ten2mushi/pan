//! runtime_engine_test — the Yoneda characterization of the RUNTIME render
//! `Engine` (the RCU-swappable sibling of the comptime `Executor`, `src/engine.zig`
//! + `src/builder.zig` + `src/commit.zig`).
//!
//! The Engine is understood here through ALL its observable morphisms. The spine
//! is the Phase-5 GATE: the runtime-committed plan replays **bit-identically** to
//! the comptime `Executor` over the SAME graph. Both paths share `computePlan`
//! (the one commit algorithm) and the SAME gather/scatter LOGIC — only the
//! dispatch differs (comptime-inlined op-list vs a bound indirect call per op). So
//! any divergence in sink output is a binding/pool/dispatch bug, NEVER numerics —
//! the comparison is therefore pan-vs-pan and BIT-EXACT, never a tolerance.
//!
//! The gate is exercised over several topologies (single hop, a longer chain, and
//! a fan-out node feeding two consumers), each built BOTH ways from the same
//! blocks + params + input, with `engine.footprint_bytes == Exec.committed.
//! footprint_bytes` independently asserted.
//!
//! The other facets pinned (each chosen exhaustively per the Yoneda mandate):
//!   - source-rooted Map arithmetic (gain scales each sample; multi-stage composes
//!     left-to-right);
//!   - `recommit()` (edit→commit RCU swap): post-swap render bit-identical to
//!     pre-swap, the epoch advanced (`rcu.epochNow()` grew), `telemetry().fault`
//!     stays false;
//!   - `reconfigure(N)`: rebuilds plan+pool, footprint scales linearly with N
//!     (assignment is N-independent), post-reconfigure render correct at the new N;
//!   - the `set` verb anti-zipper: a `Param`+`Ramp` block glides toward the target
//!     with NO instantaneous jump (per-sample delta bounded by the ramp step,
//!     direction correct);
//!   - the `schedule` verb: applied at the next `renderInto` (drained from the
//!     SPSC ring); a burst exceeding ring capacity eventually returns false without
//!     blocking;
//!   - one-source (P2): `markSet` + a wired parameter edge to the same slot ⇒
//!     `commit()` returns `error.ParameterMultiplyDriven`;
//!   - no leaks (`std.testing.allocator`): a committed engine owns the instances
//!     (defer both `g.deinit()` and `eng.deinit()`, LIFO); a graph that fails to
//!     commit leaks nothing (the builder frees on the error path).
//!
//! COMPARISON MODE: pan-vs-pan — always BIT-EXACT (`std.testing.expectEqual`).
//! There is no external oracle here.
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring,
//! per project Rules 13/14). Reject-path diagnostics, if any, go to
//! `std.debug.print`, never `std.log.err` (the 0.16 runner counts logged errors
//! and would flip the suite to a non-zero exit).

const std = @import("std");
const pan = @import("pan");

const engine = pan.engine;
const graph = pan.graph;
const port = pan.port;
const types = pan.types;
const control = pan.control;

const Sample = pan.Sample;
const Executor = engine.Executor;
const enterRealtimeThread = engine.enterRealtimeThread;

// ===========================================================================
// Boundary + DSP blocks. A Source has zero sample inputs (it fills its output
// from its own backing store); a Sink has zero outputs (it drains its input to a
// destination). These ARE the device bridge for the runtime engine — no external
// mux is needed. All mono `Sample(f32)`.
// ===========================================================================

/// Mono source: copies its preloaded backing store into the output buffer.
const BufSource = struct {
    const Self = @This();
    data: [*]const Sample(f32) = undefined,
    pub fn process(self: *Self, out: []Sample(f32)) void {
        @memcpy(out, self.data[0..out.len]);
    }
};

/// Mono sink: copies its input buffer to a destination backing store.
const BufSink = struct {
    const Self = @This();
    dest: [*]Sample(f32) = undefined,
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

/// A scalar gain Map: out[i] = in[i] * gain.
const Gain = struct {
    const Self = @This();
    gain: f32 = 1.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.gain;
    }
};

/// A biquad-like affine Map: out[i] = in[i]*a + b. Carries no z⁻¹ state (so it is
/// pool-only and stateless across renders), but it is a SECOND distinct kernel
/// shape downstream of Gain, composing into a non-trivial multi-stage transform.
const AffineMap = struct {
    const Self = @This();
    a: f32 = 1.0,
    b: f32 = 0.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *o| o.ch[0] = x.ch[0] * self.a + self.b;
    }
};

/// A 2-input adder (named fan-in): sums two mono inputs. Declares `inputs`, so the
/// builder wires it by name (`node.in.x`, `node.in.y`); the commit pass treats it
/// as a Map with two input ports. The DOWNSTREAM half of a fan-out diamond.
const Add2 = struct {
    const Self = @This();
    pub const inputs = .{ .x = Sample(f32), .y = Sample(f32) };
    pub fn process(self: *Self, x: []const Sample(f32), y: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (x, y, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
    }
};

/// A gain whose coefficient is driven by the `set`/`schedule` control verbs: an
/// atomic target (`control.Param`) ramped zipper-free toward over each block
/// (`control.Ramp`) — the anti-zipper policy. `setParam` is the control-verb
/// bridge the engine binds via its set thunk.
const RampGain = struct {
    const Self = @This();
    param: control.Param = control.Param.init(1.0),
    ramp: control.Ramp = control.Ramp.init(1.0),
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        const target = self.param.read(); // atomic load of the set target
        const inc = self.ramp.begin(target, in.len);
        for (in, out, 0..) |x, *o, i| {
            const g = self.ramp.value + @as(f32, @floatFromInt(i + 1)) * inc;
            o.ch[0] = x.ch[0] * g;
        }
        self.ramp.finish(target); // snap, no drift
    }
    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        if (slot == 0) self.param.set(value);
    }
};

// --- small helpers --------------------------------------------------------

fn ramp01(buf: []Sample(f32)) void {
    for (buf, 0..) |*s, i| s.ch[0] = @floatFromInt(i + 1);
}
fn fillNoise(buf: []Sample(f32), seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (buf) |*s| s.ch[0] = r.float(f32) * 2.0 - 1.0;
}
fn cfg(comptime N: usize) pan.Config {
    return .{ .precision = .f32, .channels = .mono, .block_size = N };
}

// ===========================================================================
// 1. THE PHASE-5 GATE: runtime Engine ≡ comptime Executor, bit-exact.
// ===========================================================================
//
// The spine. For each topology we build the SAME graph BOTH ways — the comptime
// `Executor` and the runtime `Engine` — seed identical block instances + identical
// input, render both under a realtime token, and assert the sink outputs are
// byte-identical. The two paths share `computePlan` and the gather/scatter logic;
// a divergence is a binding/pool/dispatch bug, never numerics. We also assert the
// runtime footprint equals the comptime footprint (the same plan was built).

test "GATE: runtime Engine ≡ comptime Executor for source→gain→sink (bit-exact)" {
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    // Awkward bits so a re-derived reference would risk diverging — forcing the
    // real kernel + pool plumbing to be the only variable.
    for (&input, 0..) |*s, i| s.ch[0] = @as(f32, @floatFromInt(i + 1)) * 0.30000001;
    var out_ct: [N]Sample(f32) = undefined;
    var out_rt: [N]Sample(f32) = undefined;

    const k: f32 = 0.5012; // a non-power-of-two coefficient

    // --- comptime Executor over the graph ---
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(BufSource);
        const gain = gg.add(Gain);
        const sink = gg.add(BufSink);
        gg.connect(port.MapOutPort(BufSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(BufSink), sink, 0);
        break :blk gg;
    };
    const Exec = Executor(g, &.{ BufSource, Gain, BufSink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = k },
        .{ .dest = &out_ct },
    } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    // --- runtime Engine over the SAME graph (same node-id order) ---
    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const gn = try bg.add(Gain, .{ .gain = k });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out_rt) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();
    eng.renderInto(token);

    // BIT-EXACT pan-vs-pan: the two outputs must be byte-identical.
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_ct[0..]), std.mem.sliceAsBytes(out_rt[0..]));
    try std.testing.expectEqual(@as(usize, 3), eng.op_count);
    // The runtime engine built the SAME plan — same footprint.
    try std.testing.expectEqual(Exec.committed.footprint_bytes, eng.footprint_bytes);
    try std.testing.expect(!eng.telemetry().fault);
}

test "GATE: runtime Engine ≡ comptime Executor for a 4-stage chain (bit-exact)" {
    // source → gain → affine → gain → sink. Two distinct kernel shapes, three
    // pool hops; the colored pool must ping-pong buffers and still match the
    // comptime inline replay to the bit.
    const N = 16;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xC0FFEE);
    var out_ct: [N]Sample(f32) = undefined;
    var out_rt: [N]Sample(f32) = undefined;

    const k1: f32 = 0.7;
    const aa: f32 = 1.3;
    const bb: f32 = -0.21;
    const k2: f32 = 0.45;

    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(BufSource);
        const g1 = gg.add(Gain);
        const af = gg.add(AffineMap);
        const g2 = gg.add(Gain);
        const sink = gg.add(BufSink);
        gg.connect(port.MapOutPort(BufSource), src, 0, port.MapInPort(Gain), g1, 0);
        gg.connect(port.MapOutPort(Gain), g1, 0, port.MapInPort(AffineMap), af, 0);
        gg.connect(port.MapOutPort(AffineMap), af, 0, port.MapInPort(Gain), g2, 0);
        gg.connect(port.MapOutPort(Gain), g2, 0, port.MapInPort(BufSink), sink, 0);
        break :blk gg;
    };
    const Exec = Executor(g, &.{ BufSource, Gain, AffineMap, Gain, BufSink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = k1 },
        .{ .a = aa, .b = bb },
        .{ .gain = k2 },
        .{ .dest = &out_ct },
    } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const n1 = try bg.add(Gain, .{ .gain = k1 });
    const af = try bg.add(AffineMap, .{ .a = aa, .b = bb });
    const n2 = try bg.add(Gain, .{ .gain = k2 });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out_rt) });
    try bg.connect(s, n1);
    try bg.connect(n1, af);
    try bg.connect(af, n2);
    try bg.connect(n2, sk);
    var eng = try bg.commit();
    defer eng.deinit();
    eng.renderInto(token);

    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_ct[0..]), std.mem.sliceAsBytes(out_rt[0..]));
    try std.testing.expectEqual(@as(usize, 5), eng.op_count);
    try std.testing.expectEqual(Exec.committed.footprint_bytes, eng.footprint_bytes);
    try std.testing.expect(!eng.telemetry().fault);
}

test "GATE: runtime Engine ≡ comptime Executor for a fan-out diamond (bit-exact)" {
    // A node that FANS OUT: source feeds TWO gains; both feed an Add2 fan-in; the
    // sum drains to the sink. The source's single output buffer is read by two
    // consumers, so the colorer must keep it live until BOTH have run — a
    // non-trivial liveness case. Built both ways; outputs must match to the bit.
    //
    //          ┌── gA ──┐
    //   src ──►┤        ├─► add ──► sink
    //          └── gB ──┘
    const N = 12;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0xD1A);
    var out_ct: [N]Sample(f32) = undefined;
    var out_rt: [N]Sample(f32) = undefined;

    const ka: f32 = 0.6;
    const kb: f32 = -0.25; // negative so the two paths genuinely differ

    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(BufSource);
        const gA = gg.add(Gain);
        const gB = gg.add(Gain);
        const add = gg.add(Add2);
        const sink = gg.add(BufSink);
        // src fans out to BOTH gains (two edges from the same output port).
        gg.connect(port.MapOutPort(BufSource), src, 0, port.MapInPort(Gain), gA, 0);
        gg.connect(port.MapOutPort(BufSource), src, 0, port.MapInPort(Gain), gB, 0);
        // each gain feeds a named input of the adder.
        gg.connect(port.MapOutPort(Gain), gA, 0, port.NamedInPort(Add2, "x"), add, 0);
        gg.connect(port.MapOutPort(Gain), gB, 0, port.NamedInPort(Add2, "y"), add, 1);
        gg.connect(port.MapOutPort(Add2), add, 0, port.MapInPort(BufSink), sink, 0);
        break :blk gg;
    };
    const Exec = Executor(g, &.{ BufSource, Gain, Gain, Add2, BufSink });
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = ka },
        .{ .gain = kb },
        .{},
        .{ .dest = &out_ct },
    } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const gA = try bg.add(Gain, .{ .gain = ka });
    const gB = try bg.add(Gain, .{ .gain = kb });
    const add = try bg.add(Add2, .{});
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out_rt) });
    try bg.connect(s, gA); // src → gA (bare handles: out 0 → in 0)
    try bg.connect(s, gB); // src → gB (the FAN-OUT: same source out, second edge)
    try bg.connect(gA, add.in.x); // gA → adder input "x"
    try bg.connect(gB, add.in.y); // gB → adder input "y"
    try bg.connect(add, sk);
    var eng = try bg.commit();
    defer eng.deinit();
    eng.renderInto(token);

    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(out_ct[0..]), std.mem.sliceAsBytes(out_rt[0..]));
    try std.testing.expectEqual(@as(usize, 5), eng.op_count);
    try std.testing.expectEqual(Exec.committed.footprint_bytes, eng.footprint_bytes);
    try std.testing.expect(!eng.telemetry().fault);

    // Independently confirm the fan-out actually summed both branches: the sink
    // must equal in*(ka+kb), and since ka≠kb≠0 the result is neither branch alone
    // (so the test cannot pass vacuously with one edge dropped).
    for (input, out_rt) |x, y| {
        try std.testing.expectEqual(x.ch[0] * ka + x.ch[0] * kb, y.ch[0]);
    }
}

// ===========================================================================
// 2. Source-rooted Map arithmetic — the engine computes the expected transform.
// ===========================================================================

test "arithmetic: a halving gain scales every sample by exactly 0.5" {
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    ramp01(&input);
    var out: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const gn = try bg.add(Gain, .{ .gain = 0.5 });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    for (input, out) |x, y| try std.testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
    try std.testing.expect(!eng.telemetry().fault);
}

test "arithmetic: a multi-stage chain composes left-to-right (gain∘affine∘gain)" {
    // out = ((in * k1) * a + b) * k2 — the engine must apply the ops in topo
    // order; any reordering would change the result (affine is non-commutative
    // with gain because of the +b term).
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    ramp01(&input);
    var out: [N]Sample(f32) = undefined;

    const k1: f32 = 2.0;
    const aa: f32 = 0.5;
    const bb: f32 = 1.0;
    const k2: f32 = 3.0;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const n1 = try bg.add(Gain, .{ .gain = k1 });
    const af = try bg.add(AffineMap, .{ .a = aa, .b = bb });
    const n2 = try bg.add(Gain, .{ .gain = k2 });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, n1);
    try bg.connect(n1, af);
    try bg.connect(af, n2);
    try bg.connect(n2, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    for (input, out) |x, y| {
        const expected = ((x.ch[0] * k1) * aa + bb) * k2;
        try std.testing.expectEqual(expected, y.ch[0]);
    }
    try std.testing.expect(!eng.telemetry().fault);
}

// ===========================================================================
// 3. recommit() — the edit→commit RCU swap.
// ===========================================================================

test "recommit: post-swap render is bit-identical to pre-swap and the epoch grows" {
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    fillNoise(&input, 0x5EED);
    var pre: [N]Sample(f32) = undefined;
    var post: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const gn = try bg.add(Gain, .{ .gain = 0.5 });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &pre) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token); // RT consume bumps the epoch
    const e0 = eng.rcu.epochNow();
    const fp0 = eng.footprint_bytes;

    // Re-aim the sink at a fresh buffer and RCU-swap in a freshly-built plan.
    eng.bound[sk.id].self_ptr = blk: {
        const inst: *BufSink = @ptrCast(@alignCast(eng.bound[sk.id].self_ptr));
        inst.dest = @as([*]Sample(f32), &post);
        break :blk eng.bound[sk.id].self_ptr;
    };
    try eng.recommit();
    eng.renderInto(token);

    // The rebuilt plan computes the same transform → bit-identical to pre-swap.
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(pre[0..]), std.mem.sliceAsBytes(post[0..]));
    // The epoch advanced past the swap (renders crossed callback boundaries).
    try std.testing.expect(eng.rcu.epochNow() > e0);
    // The swap is a pure storage no-op on footprint (same graph).
    try std.testing.expectEqual(fp0, eng.footprint_bytes);
    try std.testing.expect(!eng.telemetry().fault);
}

// ===========================================================================
// 4. reconfigure(N) — a block-size change rebuilds the plan + pool.
// ===========================================================================

test "reconfigure: footprint scales linearly with N and the new-N render is correct" {
    const N0 = 8;
    const N1 = 32; // 4× the block size
    var input: [N1]Sample(f32) = undefined;
    ramp01(&input);
    var out: [N1]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N0));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const gn = try bg.add(Gain, .{ .gain = 2.0 });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    const fp0 = eng.footprint_bytes;
    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);
    for (0..N0) |i| try std.testing.expectEqual(input[i].ch[0] * 2.0, out[i].ch[0]);

    // Route switch to N1 (transport stopped — backend == null in tests). The
    // buffer-id ASSIGNMENT is N-independent, so only the byte-sizes change: the
    // footprint must scale exactly by N1/N0.
    try std.testing.expect(eng.backend == null);
    try eng.reconfigure(N1);
    try std.testing.expectEqual(fp0 * (N1 / N0), eng.footprint_bytes);
    eng.renderInto(token);
    for (0..N1) |i| try std.testing.expectEqual(input[i].ch[0] * 2.0, out[i].ch[0]);
    try std.testing.expect(!eng.telemetry().fault);
}

// ===========================================================================
// 5. The `set` verb — atomic target, ramped zipper-free (anti-zipper).
// ===========================================================================

test "set: an atomic target glides toward 0 with NO instantaneous jump (anti-zipper)" {
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    for (&input) |*s| s.ch[0] = 1.0; // constant input isolates the ramp shape
    var out: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const rg = try bg.add(RampGain, .{}); // ramp starts at 1.0 (its default)
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, rg);
    try bg.connect(rg, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    // `set` the gain target to 0.0 from the control thread.
    eng.set(rg.id, 0, 0.0);

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    // Anti-zipper: each sample differs from the previous by at most the ramp step
    // (no click), and the stream descends 1 → 0 (direction correct).
    const step: f32 = (0.0 - 1.0) / @as(f32, N);
    var prev: f32 = 1.0; // the live value at block start
    for (out) |y| {
        try std.testing.expect(@abs(y.ch[0] - prev) <= @abs(step) + 1e-6);
        try std.testing.expect(y.ch[0] <= prev + 1e-6); // monotone non-increasing
        prev = y.ch[0];
    }
    try std.testing.expect(out[N - 1].ch[0] < out[0].ch[0]); // genuinely descended
    try std.testing.expect(!eng.telemetry().fault);
}

test "set: a node with no setParam is a silent no-op (set never reaches into a pure block)" {
    // The counterexample to the set wiring: `set` on a node whose block declares
    // no `setParam` must do nothing (the bound `set` thunk is null) and must not
    // corrupt the render. Gain has no setParam.
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    ramp01(&input);
    var out: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const gn = try bg.add(Gain, .{ .gain = 0.5 });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    // Gain declares no setParam → the bound thunk is null → this is a no-op.
    try std.testing.expect(eng.bound[gn.id].set == null);
    eng.set(gn.id, 0, 99.0); // must NOT change the gain coefficient

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);
    for (input, out) |x, y| try std.testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
}

// ===========================================================================
// 6. The `schedule` verb — SPSC ring, applied at the next renderInto.
// ===========================================================================

test "schedule: a queued value is applied at the next renderInto (drained from the ring)" {
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    for (&input) |*s| s.ch[0] = 1.0;
    var out: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const rg = try bg.add(RampGain, .{}); // starts gliding from 1.0
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, rg);
    try bg.connect(rg, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();

    // First, drive the ramp's live value DOWN to ~0 with a `set`, then render so
    // the ramp settles near 0 (live ≈ 0 at block end).
    eng.set(rg.id, 0, 0.0);
    eng.renderInto(token);
    try std.testing.expect(out[N - 1].ch[0] < 0.2); // near zero now

    // Now `schedule` a target of 1.0: enqueue must succeed, and the NEXT render
    // drains the ring (applying the new target) so the output rises again.
    try std.testing.expect(eng.schedule(.{ .at_sample = 0, .node = rg.id, .param = 0, .value = 1.0 }));
    eng.renderInto(token);
    // The scheduled target took effect: the stream now ascends from ~0 toward 1.
    try std.testing.expect(out[N - 1].ch[0] > out[0].ch[0]);
    try std.testing.expect(!eng.telemetry().fault);
}

test "schedule: a burst exceeding ring capacity eventually returns false without blocking" {
    // The ring is bounded (capacity = command_ring_capacity). With NO intervening
    // render to drain it, a producer burst must fill the ring and then report
    // backpressure (false) rather than block or overrun — the wait-free contract.
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    for (&input) |*s| s.ch[0] = 1.0;
    var out: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const rg = try bg.add(RampGain, .{});
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, rg);
    try bg.connect(rg, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    // Enqueue exactly `capacity` commands with no render in between: all accepted.
    const cap = engine.command_ring_capacity;
    var accepted: usize = 0;
    for (0..cap) |i| {
        if (eng.schedule(.{ .at_sample = 0, .node = rg.id, .param = 0, .value = @floatFromInt(i) }))
            accepted += 1;
    }
    try std.testing.expectEqual(cap, accepted);
    // The (capacity+1)-th must report full → false, NOT block, NOT overrun.
    try std.testing.expect(!eng.schedule(.{ .at_sample = 0, .node = rg.id, .param = 0, .value = 1.0 }));
    // Still false on a further attempt (the ring is genuinely full, not flaky).
    try std.testing.expect(!eng.schedule(.{ .at_sample = 0, .node = rg.id, .param = 0, .value = 2.0 }));

    // A render drains the ring; afterward the producer can enqueue again — the
    // backpressure was transient, the RT thread was never stalled.
    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);
    try std.testing.expect(eng.schedule(.{ .at_sample = 0, .node = rg.id, .param = 0, .value = 0.5 }));
}

// ===========================================================================
// 7. One-source (P2): a slot driven by BOTH a wired edge and `set` is rejected.
// ===========================================================================

/// An LFO-like source (zero sample input) producing a control scalar — a legal
/// path head that can drive a parameter edge.
const ParamSource = struct {
    const Self = @This();
    pub fn process(self: *Self, out: []types.Scalar(f32)) void {
        _ = self;
        _ = out;
    }
};

/// A block exposing a settable `cutoff` parameter slot (slot 0).
const Filt = struct {
    const Self = @This();
    pub const params = .{ .cutoff = types.Scalar(f32) };
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        _ = self;
        _ = slot;
        _ = value;
    }
};

test "one-source (P2): markSet + a wired param edge to the same slot ⇒ commit rejects it" {
    // A parameter slot has exactly one source: a wired parameter edge XOR an
    // external set/schedule. Declaring `set` on a slot that is ALSO wired must be
    // rejected at commit with error.ParameterMultiplyDriven.
    var bg = pan.Graph.init(std.testing.allocator, cfg(8));
    defer bg.deinit(); // a FAILED commit must leak nothing (builder frees on error).
    const lfo = try bg.add(ParamSource, .{});
    const filt = try bg.add(Filt, .{});
    bg.markSet(filt.id, 0); // declare cutoff (slot 0) externally set
    try bg.connect(lfo, filt.param.cutoff); // ALSO wire a parameter edge to slot 0
    try std.testing.expectError(error.ParameterMultiplyDriven, bg.commit());
    // bg.deinit() now frees the instances the engine never adopted — under
    // std.testing.allocator a leak here would fail the test.
}

test "one-source (P2): markSet alone (no wired edge) commits cleanly" {
    // The counterexample: marking a slot external-set is fine on its own (a slot
    // with exactly one source). Only the DOUBLE drive is the violation, so this
    // must commit without error — proving the reject is specific, not blanket.
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    ramp01(&input);
    var out: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const filt = try bg.add(Filt, .{});
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    bg.markSet(filt.id, 0); // external-set only — single source, legal
    try bg.connect(s, filt);
    try bg.connect(filt, sk);
    var eng = try bg.commit();
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 3), eng.op_count);
}

// ===========================================================================
// 8. Ownership / no-leaks (std.testing.allocator is the leak detector).
// ===========================================================================

test "ownership: a committed engine owns the instances (deinit both, LIFO, no leak)" {
    // The defer ordering is LIFO: eng.deinit() runs FIRST (freeing the instances
    // it adopted + the pool + the plan), THEN bg.deinit() (which, seeing ownership
    // transferred, frees nothing). The std.testing.allocator asserts no leak and
    // no double-free at scope exit — the whole body IS the assertion.
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    ramp01(&input);
    var out: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const gn = try bg.add(Gain, .{ .gain = 0.5 });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);
    for (input, out) |x, y| try std.testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
}

test "ownership: a graph built but never committed frees its instances on deinit (no leak)" {
    // Off the commit path: add nodes, wire nothing-or-something, never commit. The
    // builder still owns every heap instance, so deinit must free them all. A leak
    // here (std.testing.allocator) would fail the test.
    var bg = pan.Graph.init(std.testing.allocator, cfg(8));
    defer bg.deinit();
    var input: [8]Sample(f32) = undefined;
    ramp01(&input);
    _ = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    _ = try bg.add(Gain, .{ .gain = 0.5 });
    _ = try bg.add(AffineMap, .{ .a = 2.0, .b = 1.0 });
    // No commit: ownership never transfers; bg.deinit() frees all three instances.
}

// ===========================================================================
// 9. Telemetry / guard-flag tracks the build mode.
// ===========================================================================

test "telemetry: guards_compiled_out equals !runtime_safety; a clean render leaves fault false" {
    // The build-mode contract: a release build can never SILENTLY drop the NaN/Inf
    // safety net — it must REPORT that the guards are gone. And a finite-output
    // render must not trip the fault flag (the guard does not over-fire).
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    ramp01(&input);
    var out: [N]Sample(f32) = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N));
    defer bg.deinit();
    const s = try bg.add(BufSource, .{ .data = @as([*]const Sample(f32), &input) });
    const gn = try bg.add(Gain, .{ .gain = 0.25 });
    const sk = try bg.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try bg.connect(s, gn);
    try bg.connect(gn, sk);
    var eng = try bg.commit();
    defer eng.deinit();

    try std.testing.expectEqual(!std.debug.runtime_safety, eng.telemetry().guards_compiled_out);

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);
    try std.testing.expect(!eng.telemetry().fault);
}
