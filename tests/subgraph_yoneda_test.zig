//! subgraph_yoneda_test — INDEPENDENT adversarial characterization of the
//! block-size-1 subgraph combinator `combinators.Subgraph` (Phase 18 core),
//! complementary to `tests/subgraph_combinator_test.zig` (the gate). These are the
//! edge cases, boundary conditions, and compositional interactions a "tests as
//! definition" suite should pin — chosen autonomously, not prescribed:
//!
//!   - WINDOW-LENGTH INVARIANCE: driving the SAME Subgraph instance across one long
//!     window MUST equal driving it across the same samples split into several
//!     shorter windows (the inner driver is genuinely block-size-1, so the OUTER
//!     window length is irrelevant to the arithmetic; only the inner z⁻¹ history
//!     carried between calls matters). This is the persistence law sharpened.
//!   - MINIMAL DELAY BOUNDARY: a feedback comb at the SMALLEST representable delay
//!     (D=2 ⇒ inner DelayLine length D−1=1) reproduces `fx.Comb(2)` bit-for-bit —
//!     the one-sample-feedback-latency-plus-(D−1)-delay arithmetic must land exactly
//!     at the boundary, not just for comfortable D.
//!   - DELAY SWEEP: combs at several delays each ≡ the shipped fused `fx.Comb` oracle.
//!   - NESTED COMPOSITION: a Subgraph whose body itself contains a Subgraph
//!     (Subgraph∘Subgraph) equals the flat hand-written equivalent — associativity
//!     of the categorical composition the combinator realises.
//!   - CHUNK-ASSOCIATIVITY OF LINEAR FUSION: Subgraph(Gain→SoftClip→Trim) split as
//!     Subgraph(Subgraph(Gain→SoftClip)→Trim) is bit-identical (g∘f re-bracketed).
//!   - ELEMENT-TYPE VARIETY: an f64 comb ≡ f64 `fx.Comb` (the driver is lane-generic).
//!   - STATEFUL NON-FEEDBACK INTERIOR: a bare DelayLine inside a Subgraph threads its
//!     ring across outer calls exactly like a standalone DelayLine (no feedback edge,
//!     so this isolates pure pool-resident state persistence).
//!
//! Every check is pan-vs-pan ⇒ BIT-EXACT (`expectEqualSlices`), never approxEq:
//! a divergence is a driver/commit bug, never an external-numerics disagreement.
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
const Executor = engine.Executor;
const enterRealtimeThread = pan.enterRealtimeThread;

const num_f32 = numeric.numericFor(.f32, .{});
const num_f64 = numeric.numericFor(.f64, .{});
const S = Sample(f32);
const S64 = Sample(f64);

// ===========================================================================
// Helpers (mirroring tests/inplace_coalescing_test.zig + subgraph_combinator_test).
// ===========================================================================

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

fn fillNoise64(buf: []S64, seed: u64) void {
    var s = seed | 1;
    for (buf) |*frame| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        const u: u32 = @truncate(s);
        frame.ch[0] = @as(f64, @floatFromInt(u % 2_000_001)) / 1_000_000.0 - 1.0;
    }
}

fn lanes(frames: []const S) []const f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(frames)));
}
fn lanes64(frames: []const S64) []const f64 {
    return @alignCast(std.mem.bytesAsSlice(f64, std.mem.sliceAsBytes(frames)));
}

// ===========================================================================
// Inner sub-graph members (the feedback summer + a forwarder for nesting).
// ===========================================================================

/// `out = dry + g·wet`. Port 0 = forward (dry), port 1 = feedback (wet) z⁻¹ tap.
fn SummerT(comptime Smp: type) type {
    const Lane = @TypeOf(@as(Smp, undefined).ch[0]);
    return struct {
        g: Lane = 0.5,
        pub fn process(self: *@This(), dry: []const Smp, wet: []const Smp, out: []Smp) void {
            for (dry, wet, out) |d, w, *y| y.ch[0] = d.ch[0] + self.g * w.ch[0];
        }
    };
}
const Summer = SummerT(S);
const Summer64 = SummerT(S64);

const Gain = pan.filters.Gain(num_f32);
const SoftClip = pan.fx.SoftClip(num_f32);
const Trim = pan.fx.Trim(num_f32);

// ===========================================================================
// Comb sub-graph builders (lane-generic).
// ===========================================================================

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

fn CombSub64(comptime D: usize) struct { g: graph.Graph, blocks: []const type } {
    const In = combinators.Inlet(S64);
    const Out = combinators.Outlet(S64);
    const Dly = DelayLine(S64, D - 1);
    const blocks = &.{ In, Summer64, Dly, Out };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const inlet = gg.add(In);
        const sum = gg.add(Summer64);
        const dly = gg.add(Dly);
        const outlet = gg.add(Out);
        gg.connect(port.MapOutPort(In), inlet, 0, port.MapInPortAt(Summer64, 0), sum, 0);
        gg.connect(port.MapOutPort(Summer64), sum, 0, port.MapInPort(Out), outlet, 0);
        gg.connect(port.MapOutPort(Summer64), sum, 0, port.MapInPort(Dly), dly, 0);
        gg.connectFeedback(port.MapOutPort(Dly), dly, 0, port.MapInPortAt(Summer64, 1), sum, 1);
        break :blk gg;
    };
    return .{ .g = g, .blocks = blocks };
}

// ===========================================================================
// (A) WINDOW-LENGTH INVARIANCE — split-window ≡ one-shot for a feedback comb.
// ===========================================================================

test "catalog §5.4: a Subgraph comb is window-length-invariant (one shot ≡ split windows)" {
    // The inner driver is block-size-1, so the OUTER window only sets how many inner
    // renders happen per call; the per-sample arithmetic and the z⁻¹ carried between
    // calls are identical whether the stream arrives in one window or several. If the
    // driver ever leaked the outer length into the inner pass, the split would diverge.
    const D = 11;
    const g: f32 = 0.77;
    const N = 300;
    const sub = comptime CombSub(D);
    const Sub = combinators.Subgraph(sub.g, sub.blocks);

    var input: [N]S = undefined;
    fillNoise(&input, 0x5151_5151);

    // One shot.
    var one: [N]S = undefined;
    var a: Sub = .{};
    a.inner.instances[1].g = g;
    a.process(&input, &one);

    // Split into uneven windows 100 + 1 + 199.
    var split: [N]S = undefined;
    var b: Sub = .{};
    b.inner.instances[1].g = g;
    b.process(input[0..100], split[0..100]);
    b.process(input[100..101], split[100..101]);
    b.process(input[101..], split[101..]);

    try std.testing.expectEqualSlices(f32, lanes(&one), lanes(&split));
}

// ===========================================================================
// (B) MINIMAL DELAY BOUNDARY + (C) DELAY SWEEP vs fx.Comb oracle.
// ===========================================================================

fn combMatches(comptime D: usize, gain: f32, seed: u64) !void {
    const N = 257; // odd, prime-ish: no accidental period alignment with D
    const sub = comptime CombSub(D);
    const Sub = combinators.Subgraph(sub.g, sub.blocks);

    var input: [N]S = undefined;
    fillNoise(&input, seed);

    var got: [N]S = undefined;
    var inst: Sub = .{};
    inst.inner.instances[1].g = gain;
    inst.process(&input, &got);

    var ref: [N]S = undefined;
    var oracle = Comb(num_f32, D){ .feedback = gain, .delay = D };
    oracle.process(&input, &ref);

    try std.testing.expectEqualSlices(f32, lanes(&got), lanes(&ref));
}

test "catalog §5.4: a Subgraph comb at the MINIMAL delay D=2 ≡ fx.Comb(2) bit-for-bit" {
    try combMatches(2, 0.5, 0xB0_0B);
}

test "catalog §5.4: a delay sweep D∈{2,3,8,33,128} each ≡ the fused fx.Comb oracle" {
    try combMatches(2, 0.91, 0x01);
    try combMatches(3, 0.5, 0x02);
    try combMatches(8, 0.83, 0x03);
    try combMatches(33, 0.66, 0x04);
    try combMatches(128, 0.95, 0x05);
}

// ===========================================================================
// (D) ELEMENT-TYPE VARIETY — an f64 comb ≡ f64 fx.Comb (driver is lane-generic).
// ===========================================================================

test "catalog §5.4: an f64 Subgraph comb ≡ f64 fx.Comb bit-for-bit (lane-generic driver)" {
    const D = 9;
    const g: f64 = 0.72;
    const N = 200;
    const sub = comptime CombSub64(D);
    const Sub = combinators.Subgraph(sub.g, sub.blocks);

    var input: [N]S64 = undefined;
    fillNoise64(&input, 0xF64_C0FFEE);

    var got: [N]S64 = undefined;
    var inst: Sub = .{};
    inst.inner.instances[1].g = @floatCast(g);
    inst.process(&input, &got);

    var ref: [N]S64 = undefined;
    var oracle = Comb(num_f64, D){ .feedback = g, .delay = D };
    oracle.process(&input, &ref);

    try std.testing.expectEqualSlices(f64, lanes64(&got), lanes64(&ref));
}

// ===========================================================================
// (E) CHUNK-ASSOCIATIVITY OF LINEAR FUSION — re-bracketing g∘f∘e is bit-identical.
//   Subgraph(Gain→SoftClip→Trim) ≡ Subgraph( Subgraph(Gain→SoftClip) → Trim )
// A nested Subgraph in the body of an outer Subgraph: pins composition associativity
// AND that a Subgraph is itself a placeable rate-1:1 Map inside another sub-graph.
// ===========================================================================

fn flatChain() struct { g: graph.Graph, blocks: []const type } {
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

/// Inner Gain→SoftClip, packaged as a standalone Subgraph type (a fused Map).
fn innerGS() type {
    const In = combinators.Inlet(S);
    const Out = combinators.Outlet(S);
    const blocks = &.{ In, Gain, SoftClip, Out };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const inlet = gg.add(In);
        const gain = gg.add(Gain);
        const clip = gg.add(SoftClip);
        const outlet = gg.add(Out);
        gg.connect(port.MapOutPort(In), inlet, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(SoftClip), clip, 0);
        gg.connect(port.MapOutPort(SoftClip), clip, 0, port.MapInPort(Out), outlet, 0);
        break :blk gg;
    };
    return combinators.Subgraph(g, blocks);
}

test "catalog §5.4: nested Subgraph(Subgraph(Gain→SoftClip)→Trim) ≡ flat Subgraph(Gain→SoftClip→Trim)" {
    const N = 384;
    const k: f32 = 1.6;
    const drive: f32 = 2.1;
    const trim_db: f32 = -2.0;

    var input: [N]S = undefined;
    fillNoise(&input, 0xA55_0C);

    // Flat: one Subgraph over the whole 3-Map chain.
    const flat = comptime flatChain();
    const Flat = combinators.Subgraph(flat.g, flat.blocks);
    var out_flat: [N]S = undefined;
    var fi: Flat = .{};
    fi.inner.instances[1].gain = k;
    fi.inner.instances[2].drive = drive;
    fi.inner.instances[3].gain_db = trim_db;
    fi.process(&input, &out_flat);

    // Nested: outer Subgraph whose body is [ inner Subgraph(Gain→SoftClip) ] → Trim.
    const GS = innerGS();
    const In = combinators.Inlet(S);
    const Out = combinators.Outlet(S);
    const outer_blocks = &.{ In, GS, Trim, Out };
    const outer_g = comptime blk: {
        var gg = graph.Graph.empty;
        const inlet = gg.add(In);
        const gs = gg.add(GS);
        const trim = gg.add(Trim);
        const outlet = gg.add(Out);
        gg.connect(port.MapOutPort(In), inlet, 0, port.MapInPort(GS), gs, 0);
        gg.connect(port.MapOutPort(GS), gs, 0, port.MapInPort(Trim), trim, 0);
        gg.connect(port.MapOutPort(Trim), trim, 0, port.MapInPort(Out), outlet, 0);
        break :blk gg;
    };
    const Nested = combinators.Subgraph(outer_g, outer_blocks);
    var out_nested: [N]S = undefined;
    var ni: Nested = .{};
    // Seed the inner Subgraph's interior (Gain node 1, SoftClip node 2 inside GS),
    // and the outer Trim (node 2 in the outer body).
    ni.inner.instances[1].inner.instances[1].gain = k;
    ni.inner.instances[1].inner.instances[2].drive = drive;
    ni.inner.instances[2].gain_db = trim_db;
    ni.process(&input, &out_nested);

    try std.testing.expectEqualSlices(f32, lanes(&out_flat), lanes(&out_nested));
}

// ===========================================================================
// (F) STATEFUL NON-FEEDBACK INTERIOR — a bare DelayLine threads its ring across
// outer calls exactly like a standalone DelayLine. Isolates pure pool-resident
// state persistence (no feedback edge involved).
// ===========================================================================

test "catalog §5.4: a Subgraph wrapping a bare DelayLine ≡ a standalone DelayLine across calls" {
    const D = 6;
    const N = 64;
    const Dly = DelayLine(S, D);
    const In = combinators.Inlet(S);
    const Out = combinators.Outlet(S);
    const blocks = &.{ In, Dly, Out };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const inlet = gg.add(In);
        const dly = gg.add(Dly);
        const outlet = gg.add(Out);
        gg.connect(port.MapOutPort(In), inlet, 0, port.MapInPort(Dly), dly, 0);
        gg.connect(port.MapOutPort(Dly), dly, 0, port.MapInPort(Out), outlet, 0);
        break :blk gg;
    };
    const Sub = combinators.Subgraph(g, blocks);

    var input: [2 * N]S = undefined;
    fillNoise(&input, 0xDEAD_DE1A);

    // Subgraph, two calls (state must carry: the second window's first D samples come
    // from the first window's tail held in the inner pool).
    var sub_out: [2 * N]S = undefined;
    var inst: Sub = .{};
    inst.process(input[0..N], sub_out[0..N]);
    inst.process(input[N..], sub_out[N..]);

    // Standalone DelayLine over the full stream in one pass.
    var ref: [2 * N]S = undefined;
    var d = Dly{};
    d.process(&input, &ref);

    try std.testing.expectEqualSlices(f32, lanes(&sub_out), lanes(&ref));
}
