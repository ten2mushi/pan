//! subgraph_combinator_test — the differential characterization of the
//! block-size-1 subgraph combinator `combinators.Subgraph` (Phase 18 core).
//!
//! `Subgraph` wraps an inner sub-graph (wired `Inlet → … → Outlet`) as ONE rate-1:1
//! `Map` that drives the sub-graph at window length 1 once per outer sample. Two
//! laws define it, and both are pinned here against an oracle that is ALSO pan code,
//! so a divergence is a driver/commit bug, never an external-numerics disagreement:
//!
//!   (1) SAMPLE-ACCURATE TIGHT FEEDBACK (combinator ≡ hand-fused kernel). A delay-
//!       guarded feedback cycle inside the sub-graph carries exactly one sample of
//!       latency at window length 1, so a `Summer + DelayLine(D−1)` cycle reproduces
//!       the hand-fused `fx.Comb`'s recurrence `y[n] = x[n] + g·y[n−D]` BIT-FOR-BIT
//!       (and likewise an `fx.Allpass` section rebuilt from primitives). The shipped
//!       fused kernels in `src/fx.zig` are the oracle; equality over a noise corpus
//!       is the gate. An "almost" is a failure — pan must not disagree with itself.
//!
//!   (2) SINGLE-PASS LINEAR FUSION (fused ≡ unfused). A linear param-free chain
//!       `Gain → SoftClip → Trim` driven through `Subgraph` (one fused pass per
//!       sample) is BIT-IDENTICAL to the same three blocks rendered as a separate
//!       unfused 3-op graph. Fusion is composition of rate-1:1 type-stable maps:
//!       `(g ∘ f)(x) = g(f(x))` must hold sample-for-sample.
//!
//! Also pinned: the `Subgraph` instance threads its inner persistent state across
//! outer `process` calls (the comb keeps ringing block to block), and a fresh
//! instance is bit-exactly reproducible (the inner z⁻¹ is a pure function of input
//! history, not residual cross-instance state).
//!
//! Verified against zig 0.16.0 (the `zig-0-16` skill was loaded before authoring,
//! per project Rules 13/14). No `std.log.err` — the 0.16 test runner counts logged
//! errors as failures.

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const port = pan.port;
const engine = pan.engine;
const numeric = pan.numeric;
const combinators = pan.combinators;

const Sample = pan.Sample;
const DelayLine = pan.DelayLine;
const Comb = pan.Comb;
const Allpass = pan.Allpass;
const Executor = engine.Executor;
const enterRealtimeThread = pan.enterRealtimeThread;

const num_f32 = numeric.numericFor(.f32, .{});
const S = Sample(f32);

// ===========================================================================
// Test-local helpers (mirroring tests/inplace_coalescing_test.zig).
// ===========================================================================

/// Deterministic finite noise in roughly [−1, 1) — xorshift64 so two runs see the
/// identical corpus. Fractional mantissa bits make a memcpy-vs-scaled path divergent.
fn fillNoise(buf: []S, seed: u64) void {
    var s = seed | 1;
    for (buf) |*frame| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        const u: u32 = @truncate(s);
        frame.ch[0] = @as(f32, @floatFromInt(u % 2_000_001)) / 1_000_000.0 - 1.0;
    }
}

/// View `[]const S` as `[]const f32` (one lane per mono frame, identical storage).
fn lanes(frames: []const S) []const f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(frames)));
}

/// pan-vs-pan ⇒ ALWAYS bit-exact.
fn bitExact(got: []const f32, ref: []const f32) !void {
    try std.testing.expectEqualSlices(f32, ref, got);
}

// ===========================================================================
// Inner sub-graph members.
// ===========================================================================

/// Two-input feedback summer: `out = dry + g·wet`. Port 0 is the forward (dry)
/// input; port 1 is the feedback (wet) z⁻¹ tap. The commit pass gathers forward
/// edges in declaration order then feedback read-sides, so `dry` is the port-0
/// forward edge and `wet` is the port-1 feedback edge — matching `fx.Comb`'s
/// `y = x + g·(delayed)`.
const Summer = struct {
    g: f32 = 0.5,
    pub fn process(self: *@This(), dry: []const S, wet: []const S, out: []S) void {
        for (dry, wet, out) |d, w, *y| y.ch[0] = d.ch[0] + self.g * w.ch[0];
    }
};

/// Schroeder all-pass summer rebuilt from primitives:
///     y      = −g·x + v          (v is the z⁻¹ tap fed back from the delay)
///     store  =  x + g·y          (pushed into the delay this sample)
/// emitted on TWO outputs: port 0 = `y` (the section output → Outlet), port 1 =
/// `store` (→ the delay → fed back as `v`). This reproduces `fx.Allpass`'s
/// `v = ring[p]; y = −g·x + v; ring[p] = x + g·y` when the delay carries v[n] = the
/// `store` written D samples earlier.
const AllpassCore = struct {
    g: f32 = 0.5,
    pub fn process(self: *@This(), x: []const S, v: []const S, y: []S, store: []S) void {
        for (x, v, y, store) |xi, vi, *yi, *si| {
            const yo = -self.g * xi.ch[0] + vi.ch[0];
            yi.ch[0] = yo;
            si.ch[0] = xi.ch[0] + self.g * yo;
        }
    }
};

// ===========================================================================
// (1) combinator ≡ hand-fused kernel — sample-accurate tight feedback.
// ===========================================================================

/// Build the inner comb sub-graph: Inlet → Summer.0 ; Summer → Outlet ;
/// Summer → DelayLine(D−1) ; DelayLine → Summer.1 (feedback). At window length 1
/// the feedback edge adds 1 sample of latency and the DelayLine adds D−1, so
/// `wet = y[n−D]` and the summer computes `y[n] = x[n] + g·y[n−D]` — exactly
/// `fx.Comb(D)`. (D ≥ 2 so the inner delay element has length ≥ 1.)
fn CombSub(comptime D: usize) struct { g: graph.Graph, blocks: []const type } {
    const In = combinators.Inlet(S);
    const Out = combinators.Outlet(S);
    const Dly = DelayLine(S, D - 1);
    const blocks = &.{ In, Summer, Dly, Out };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const inlet = gg.add(In);
        const sum = gg.add(Summer);
        const dly = gg.add(Dly);
        const outlet = gg.add(Out);
        gg.connect(port.MapOutPort(In), inlet, 0, port.MapInPortAt(Summer, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Out), outlet, 0);
        gg.connect(port.MapOutPort(Summer), sum, 0, port.MapInPort(Dly), dly, 0);
        gg.connectFeedback(port.MapOutPort(Dly), dly, 0, port.MapInPortAt(Summer, 1), sum, 1);
        break :blk gg;
    };
    return .{ .g = g, .blocks = blocks };
}

test "catalog §5.4: Subgraph(Summer+DelayLine cycle) ≡ hand-fused fx.Comb bit-for-bit" {
    const D = 7;
    const g: f32 = 0.84;
    const N = 512;

    const sub = comptime CombSub(D);
    const Sub = combinators.Subgraph(sub.g, sub.blocks);

    var input: [N]S = undefined;
    fillNoise(&input, 0xC0FFEE);

    // Combinator: seed the inner Summer's gain (node 1 in CombSub's order).
    var comb_out: [N]S = undefined;
    var sub_inst: Sub = .{};
    sub_inst.inner.instances[1].g = g;
    sub_inst.process(&input, &comb_out);

    // Oracle: the shipped fused fx.Comb at delay D, same g.
    var ref_out: [N]S = undefined;
    var oracle = Comb(num_f32, D){ .feedback = g, .delay = D };
    oracle.process(&input, &ref_out);

    try bitExact(lanes(&comb_out), lanes(&ref_out));
}

test "catalog §5.4: Subgraph comb threads persistent state across outer process calls" {
    // The inner z⁻¹ tail must survive between outer `process` calls: feeding an
    // impulse then silence in TWO separate calls must equal feeding the concatenated
    // impulse-then-silence to the fused oracle in one call. If the combinator reset
    // its inner state per call the second chunk would be silent — it must ring on.
    const D = 5;
    const g: f32 = 0.7;
    const N = 64;

    const sub = comptime CombSub(D);
    const Sub = combinators.Subgraph(sub.g, sub.blocks);

    var first: [N]S = @splat(.{ .ch = .{0} });
    first[0] = .{ .ch = .{1} }; // unit impulse
    var second: [N]S = @splat(.{ .ch = .{0} }); // silence

    var sub_inst: Sub = .{};
    sub_inst.inner.instances[1].g = g;
    var out_a: [N]S = undefined;
    var out_b: [N]S = undefined;
    sub_inst.process(&first, &out_a);
    sub_inst.process(&second, &out_b); // must still echo

    // Oracle fed the full 2N stream in one pass.
    var full_in: [2 * N]S = undefined;
    @memcpy(full_in[0..N], &first);
    @memcpy(full_in[N..], &second);
    var ref: [2 * N]S = undefined;
    var oracle = Comb(num_f32, D){ .feedback = g, .delay = D };
    oracle.process(&full_in, &ref);

    try bitExact(lanes(&out_a), lanes(ref[0..N]));
    try bitExact(lanes(&out_b), lanes(ref[N..]));
    // The carried-over chunk is genuinely non-silent (the loop kept ringing).
    var any: bool = false;
    for (out_b) |s| {
        if (s.ch[0] != 0) any = true;
    }
    try std.testing.expect(any);
}

test "catalog §5.4: two fresh Subgraph comb instances are bit-exactly reproducible" {
    // pan-vs-pan determinism: a fresh instance starts with a zeroed inner pool +
    // zeroed delay ring, so its output is a pure function of the input history.
    const D = 9;
    const g: f32 = 0.6;
    const N = 256;
    const sub = comptime CombSub(D);
    const Sub = combinators.Subgraph(sub.g, sub.blocks);

    var input: [N]S = undefined;
    fillNoise(&input, 0x5EED);

    var a: [N]S = undefined;
    var b: [N]S = undefined;
    var ia: Sub = .{};
    var ib: Sub = .{};
    ia.inner.instances[1].g = g;
    ib.inner.instances[1].g = g;
    ia.process(&input, &a);
    ib.process(&input, &b);
    try bitExact(lanes(&a), lanes(&b));
}

/// Build the inner all-pass sub-graph: Inlet → AllpassCore.x ; AllpassCore.y →
/// Outlet ; AllpassCore.store → DelayLine(D−1) ; DelayLine → AllpassCore.v
/// (feedback). The feedback edge's 1 sample + the DelayLine's D−1 give the `store`
/// written D samples ago as `v` — matching `fx.Allpass(D)`'s `v = ring[p]` tap.
fn AllpassSub(comptime D: usize) struct { g: graph.Graph, blocks: []const type } {
    const In = combinators.Inlet(S);
    const Out = combinators.Outlet(S);
    const Dly = DelayLine(S, D - 1);
    const blocks = &.{ In, AllpassCore, Dly, Out };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const inlet = gg.add(In);
        const core = gg.add(AllpassCore);
        const dly = gg.add(Dly);
        const outlet = gg.add(Out);
        gg.connect(port.MapOutPort(In), inlet, 0, port.MapInPortAt(AllpassCore, 0), core, 0);
        // AllpassCore output port 0 = y → Outlet; port 1 = store → delay. Both
        // outputs carry Sample(f32), so the single minted `MapOutPort` typed handle
        // serves both; the runtime out-index (0 / 1) selects the port.
        gg.connect(port.MapOutPort(AllpassCore), core, 0, port.MapInPort(Out), outlet, 0);
        gg.connect(port.MapOutPort(AllpassCore), core, 1, port.MapInPort(Dly), dly, 0);
        gg.connectFeedback(port.MapOutPort(Dly), dly, 0, port.MapInPortAt(AllpassCore, 1), core, 1);
        break :blk gg;
    };
    return .{ .g = g, .blocks = blocks };
}

test "catalog §5.4: Subgraph all-pass section ≡ hand-fused fx.Allpass bit-for-bit" {
    const D = 6;
    const g: f32 = 0.5;
    const N = 384;

    const sub = comptime AllpassSub(D);
    const Sub = combinators.Subgraph(sub.g, sub.blocks);

    var input: [N]S = undefined;
    fillNoise(&input, 0xA11_5EC7);

    var got: [N]S = undefined;
    var inst: Sub = .{};
    inst.inner.instances[1].g = g; // AllpassCore is node 1
    inst.process(&input, &got);

    var ref: [N]S = undefined;
    var oracle = Allpass(num_f32, D){ .feedback = g, .delay = D };
    oracle.process(&input, &ref);

    try bitExact(lanes(&got), lanes(&ref));
}

// ===========================================================================
// (2) fused ≡ unfused — single-pass linear fusion.
// ===========================================================================

const Gain = pan.filters.Gain(num_f32);
const SoftClip = pan.fx.SoftClip(num_f32);
const Trim = pan.fx.Trim(num_f32);

/// Inner linear chain Inlet → Gain → SoftClip → Trim → Outlet (no feedback, no
/// params). Driven at window length 1 by `Subgraph` ⇒ a single fused pass per
/// sample.
fn ChainSub() struct { g: graph.Graph, blocks: []const type } {
    const In = combinators.Inlet(S);
    const Out = combinators.Outlet(S);
    const blocks = &.{ In, Gain, SoftClip, Trim, Out };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const inlet = gg.add(In);
        const gain = gg.add(Gain);
        const clip = gg.add(SoftClip);
        const trim = gg.add(Trim);
        const outlet = gg.add(Out);
        gg.connect(port.MapOutPort(In), inlet, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(SoftClip), clip, 0);
        gg.connect(port.MapOutPort(SoftClip), clip, 0, port.MapInPort(Trim), trim, 0);
        gg.connect(port.MapOutPort(Trim), trim, 0, port.MapInPort(Out), outlet, 0);
        break :blk gg;
    };
    return .{ .g = g, .blocks = blocks };
}

/// The same three blocks as a standalone unfused graph, MonoSource → Gain →
/// SoftClip → Trim → MonoSink, rendered at the full window length by a normal
/// `Executor`. This is the unfused baseline the fused `Subgraph` must match.
const MonoSource = struct {
    data: [*]const S = undefined,
    pub fn process(self: *@This(), out: []S) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const MonoSink = struct {
    dest: [*]S = undefined,
    pub fn process(self: *@This(), in: []const S) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

test "catalog §11.3 T2: Subgraph(Gain→SoftClip→Trim) ≡ the unfused 3-op chain bit-for-bit" {
    const N = 512;
    const k: f32 = 1.7;
    const drive: f32 = 2.3;
    const trim_db: f32 = -3.0;

    var input: [N]S = undefined;
    fillNoise(&input, 0xFADE);

    // Fused path: drive the chain through Subgraph at window length 1.
    const sub = comptime ChainSub();
    const Sub = combinators.Subgraph(sub.g, sub.blocks);
    var fused: [N]S = undefined;
    var sub_inst: Sub = .{};
    sub_inst.inner.instances[1].gain = k; // Gain  (node 1)
    sub_inst.inner.instances[2].drive = drive; // SoftClip (node 2)
    sub_inst.inner.instances[3].gain_db = trim_db; // Trim (node 3)
    sub_inst.process(&input, &fused);

    // Unfused baseline: the same blocks in a separate full-window graph.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = N;
        const src = gg.add(MonoSource);
        const gain = gg.add(Gain);
        const clip = gg.add(SoftClip);
        const trim = gg.add(Trim);
        const sink = gg.add(MonoSink);
        gg.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(SoftClip), clip, 0);
        gg.connect(port.MapOutPort(SoftClip), clip, 0, port.MapInPort(Trim), trim, 0);
        gg.connect(port.MapOutPort(Trim), trim, 0, port.MapInPort(MonoSink), sink, 0);
        break :blk gg;
    };
    const Exec = Executor(g, &.{ MonoSource, Gain, SoftClip, Trim, MonoSink });
    var unfused: [N]S = undefined;
    var exec: Exec = .{ .instances = .{
        .{ .data = &input },
        .{ .gain = k },
        .{ .drive = drive },
        .{ .gain_db = trim_db },
        .{ .dest = &unfused },
    } };
    const token = enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    try bitExact(lanes(&fused), lanes(&unfused));
}

test "Subgraph identity: an Inlet→Outlet wire passes the input through unchanged" {
    // The degenerate sub-graph (no interior block) is the categorical identity
    // morphism: out = in, bit-for-bit. Pins that the driver's poke/render/read loop
    // is itself transparent.
    const In = combinators.Inlet(S);
    const Out = combinators.Outlet(S);
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const inlet = gg.add(In);
        const outlet = gg.add(Out);
        gg.connect(port.MapOutPort(In), inlet, 0, port.MapInPort(Out), outlet, 0);
        break :blk gg;
    };
    const Sub = combinators.Subgraph(g, &.{ In, Out });

    const N = 128;
    var input: [N]S = undefined;
    fillNoise(&input, 0x1D);
    var out: [N]S = undefined;
    var inst: Sub = .{};
    inst.process(&input, &out);
    try bitExact(lanes(&out), lanes(&input));
}
