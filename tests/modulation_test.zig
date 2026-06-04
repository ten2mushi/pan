//! modulation_test — the modulation/control blocks driving parameter ports,
//! exercised end-to-end through the REAL runtime builder→engine path
//! (`init → add → connect → commit → renderInto`).
//!
//! Three properties, plus an integration sanity:
//!
//!   1. **An `Lfo → param` sweep is bit-identical to the same sweep via `set`.**
//!      A wired parameter edge and the external `set` verb both arrive through the
//!      consumer's `setParam` and drive the SAME `control.Param`/`control.Ramp`, so
//!      the rendered audio is byte-for-byte identical — proved by comparing the two
//!      render paths with `expectEqualSlices(u8, ...)`. (pan-vs-pan, bit-exact: the
//!      wire is just an alternate source of the same target.)
//!   2. **A feature→param chain modulates correctly.** A control source → `FeatureMap`
//!      (affine rescale) → a `Vca`'s `param.gain`: the gain settles to `scale·feat +
//!      bias` and scales the audio accordingly.
//!   3. **Data-gating leaves the op-list static.** A `PowerGate` keyed off a sidechain
//!      mutes a constant tone through a `Vca`; the committed op-list is unchanged
//!      (`op_count` constant) whether the key is loud or silent — only the gate's
//!      DATA value changes, never the schedule (gating is data, never a skipped op).
//!
//! Verified against zig 0.16.0.

const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});
const S = pan.Sample(f32);
const Scalar = pan.Scalar(f32);

// --- local source / sink blocks (the standard test backbone) ----------------

/// A source filling its output from a preloaded, re-pointable buffer (a Source:
/// zero sample inputs, so it roots a path). `data` is reset between blocks to feed
/// a fresh window.
const BufSource = struct {
    const Self = @This();
    data: [*]const S = undefined,
    pub fn process(self: *Self, out: []S) void {
        @memcpy(out, self.data[0..out.len]);
    }
};

/// A sink copying its input to a re-pointable destination.
const BufSink = struct {
    const Self = @This();
    dest: [*]S = undefined,
    pub fn process(self: *Self, in: []const S) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

fn cfg(n: usize) pan.config.Config {
    return .{ .precision = .f32, .channels = .mono, .block_size = n };
}

// ===========================================================================
// 1. GATE — Lfo → a filter's param.cutoff is BIT-IDENTICAL to the same sweep via `set`
// ===========================================================================

test "GATE: an Lfo→cutoff sweep is bit-identical to the same sweep via set" {
    const N = 8;
    const K = 6; // render six blocks so the LFO genuinely sweeps the cutoff across calls
    const alloc = std.testing.allocator;

    // A non-trivial, varying input so the one-pole's state genuinely evolves and any
    // divergence is a binding/ramp/state bug, not numerics.
    var input: [N]S = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = 0.10000001 * @as(f32, @floatFromInt(i + 1));

    var out_wired: [K * N]S = undefined;
    var out_set: [K * N]S = undefined;

    const INC: f32 = 0.013; // cycles per sample
    const AMP: f32 = 0.35;
    const OFF: f32 = 0.55; // cutoff coefficient swings in [0.2, 0.9] ⊂ (0, 1)

    // ---- Path A: the Lfo is WIRED into the filter's param.cutoff ---------
    var gA = pan.Graph.init(alloc, cfg(N));
    defer gA.deinit();
    const sa = try gA.add(BufSource, .{ .data = @as([*]const S, &input) });
    const la = try gA.add(pan.gen.Lfo, .{ .increment = INC, .amplitude = AMP, .offset = OFF, .waveform = .sine });
    const va = try gA.add(pan.filters.OnePole(Num), .{});
    const ka = try gA.add(BufSink, .{});
    try gA.connect(sa, va); // audio: source → filter sample input
    try gA.connect(la, va.param.cutoff); // modulation: lfo → cutoff (in-graph `set`)
    try gA.connect(va, ka);
    var engA = try gA.commit();
    defer engA.deinit();

    // ---- Path B: NO Lfo node; the same cutoff targets pushed via engine.set
    var gB = pan.Graph.init(alloc, cfg(N));
    defer gB.deinit();
    const sb = try gB.add(BufSource, .{ .data = @as([*]const S, &input) });
    const vb = try gB.add(pan.filters.OnePole(Num), .{});
    const kb = try gB.add(BufSink, .{});
    try gB.connect(sb, vb);
    try gB.connect(vb, kb);
    gB.markSet(vb.id, 0); // cutoff slot is set-driven (one-source rule: set XOR wire)
    var engB = try gB.commit();
    defer engB.deinit();

    // The set-path target sequence is produced by an INDEPENDENT Lfo instance run
    // exactly as the wired node is (same struct, same `process`, same out.len = N),
    // so target_k is byte-identical to the value the wired edge delivers in block k.
    var replica = pan.gen.Lfo{ .increment = INC, .amplitude = AMP, .offset = OFF, .waveform = .sine };
    var dummy: [N]Scalar = undefined;

    const token = pan.enterRealtimeThread();
    defer token.leave();

    var k: usize = 0;
    while (k < K) : (k += 1) {
        // Path A: render block k (its Lfo node emits this block's value + advances).
        ka.instance().dest = out_wired[k * N ..].ptr;
        engA.renderInto(token);

        // Path B: reproduce this block's target with the replica, set it, render.
        replica.process(&dummy);
        engB.set(vb.id, 0, dummy[0].value);
        kb.instance().dest = out_set[k * N ..].ptr;
        engB.renderInto(token);
    }

    // The two paths committed the same plan shape (one extra op for the Lfo node).
    try std.testing.expectEqual(@as(usize, 4), engA.op_count);
    try std.testing.expectEqual(@as(usize, 3), engB.op_count);
    try std.testing.expect(!engA.telemetry().fault);
    try std.testing.expect(!engB.telemetry().fault);

    // BIT-EXACT: the wired sweep and the `set` sweep are byte-identical audio.
    try std.testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(out_set[0..]),
        std.mem.sliceAsBytes(out_wired[0..]),
    );

    // And it is a genuine sweep (the gain actually moved across the run), not a
    // degenerate constant that would make bit-equality trivially hold.
    try std.testing.expect(out_wired[0].ch[0] != out_wired[(K - 1) * N].ch[0]);
}

// ===========================================================================
// 2. A feature→param chain modulates correctly
// ===========================================================================

/// A control source emitting a fixed power-spectrum frame (a stand-in for a real
/// `Framer→Stft→PowerSpectrum` chain, which is exercised elsewhere) so a genuine
/// `feat.zig` analysis block can root the feature→param chain.
fn SpectrumSource(comptime BINS: usize) type {
    return struct {
        const Self = @This();
        frame: pan.FeatureFrame(BINS) = .{ .v = [_]f32{0} ** BINS },
        pub fn process(self: *Self, out: []pan.FeatureFrame(BINS)) void {
            for (out) |*o| o.* = self.frame;
        }
    };
}

test "feature→param chain: a real feat.Rms drives a Vca gain through FeatureMap" {
    const N = 8;
    const BINS = 4;
    const alloc = std.testing.allocator;

    var input: [N]S = @splat(.{ .ch = .{1.0} }); // unit tone, so output == gain
    var out: [N]S = undefined;

    var g = pan.Graph.init(alloc, cfg(N));
    defer g.deinit();

    // A flat power spectrum (every bin = 4.0) ⇒ feat.Rms = sqrt(mean(power)) = 2.0;
    // FeatureMap (0.25·rms + 0.1) = 0.6 ⇒ the Vca gain settles to 0.6.
    const spec = try g.add(SpectrumSource(BINS), .{ .frame = pan.FeatureFrame(BINS){ .v = [_]f32{4.0} ** BINS } });
    const rms = try g.add(pan.feat.Rms(Num, BINS), .{}); // REAL feat block → Scalar(f32)
    const map = try g.add(pan.env.FeatureMap, .{ .scale = 0.25, .bias = 0.1 });
    const src = try g.add(BufSource, .{ .data = @as([*]const S, &input) });
    const vca = try g.add(pan.fx.Vca(Num), .{});
    const sink = try g.add(BufSink, .{});

    try g.connect(spec, rms); // spectrum → feature (FeatureFrame → Scalar)
    try g.connect(rms, map); // feature → rescale (Scalar → Scalar, 1:1)
    try g.connect(map, vca.param.gain); // rescaled feature → gain
    try g.connect(src, vca);
    try g.connect(vca, sink);
    var eng = try g.commit();
    defer eng.deinit();

    const token = pan.enterRealtimeThread();
    defer token.leave();

    // First block: the Vca gain ramps from 1.0 toward the target 0.6.
    sink.instance().dest = (&out).ptr;
    eng.renderInto(token);
    // Second block: the target is held, the ramp has snapped to 0.6 → output is the
    // unit tone scaled by exactly 0.6 (constant across the block).
    eng.renderInto(token);
    for (out) |y| try std.testing.expectApproxEqAbs(@as(f32, 0.6), y.ch[0], 1e-6);
    try std.testing.expect(!eng.telemetry().fault);
}

// ===========================================================================
// 3. Data-gating leaves the op-list static
// ===========================================================================

test "data-gating: a PowerGate mutes a tone without changing the op-list" {
    const N = 8;
    const alloc = std.testing.allocator;

    var tone: [N]S = @splat(.{ .ch = .{1.0} }); // the signal the Vca passes/mutes
    var loud: [N]S = @splat(.{ .ch = .{1.0} }); // sidechain key: power 1.0 → opens
    var silent: [N]S = @splat(.{ .ch = .{0.0} }); // sidechain key: power 0.0 → closes
    var out: [N]S = undefined;

    var g = pan.Graph.init(alloc, cfg(N));
    defer g.deinit();

    const key = try g.add(BufSource, .{ .data = @as([*]const S, &loud) });
    const gate = try g.add(pan.fx.PowerGate(Num), .{ .open_threshold = 0.5, .close_threshold = 0.1 });
    const toneSrc = try g.add(BufSource, .{ .data = @as([*]const S, &tone) });
    const vca = try g.add(pan.fx.Vca(Num), .{ .ramp = pan.control.Ramp.init(0) }); // start muted
    const sink = try g.add(BufSink, .{});

    try g.connect(key, gate); // sidechain key → gate (audio in, Scalar out)
    try g.connect(gate, vca.param.gain); // gate value → vca gain (data-gating)
    try g.connect(toneSrc, vca); // the gated signal
    try g.connect(vca, sink);
    var eng = try g.commit();
    defer eng.deinit();

    // The op-list is static: five ops (two sources, gate, vca, sink), committed once.
    const ops_before = eng.op_count;
    try std.testing.expectEqual(@as(usize, 5), ops_before);

    const token = pan.enterRealtimeThread();
    defer token.leave();

    sink.instance().dest = (&out).ptr;
    // Key LOUD: render a few blocks so the gate opens and the gain ramps to 1.
    var k: usize = 0;
    while (k < 4) : (k += 1) eng.renderInto(token);
    for (out) |y| try std.testing.expectApproxEqAbs(@as(f32, 1.0), y.ch[0], 1e-6); // tone passes

    // Now key SILENT: the SAME op-list runs (op_count unchanged); the gate closes and
    // the gain ramps to 0, muting the (still unit) tone — gating is data, not control.
    key.instance().data = @as([*]const S, &silent);
    k = 0;
    while (k < 4) : (k += 1) eng.renderInto(token);
    for (out) |y| try std.testing.expectApproxEqAbs(@as(f32, 0.0), y.ch[0], 1e-6); // tone muted

    try std.testing.expectEqual(ops_before, eng.op_count); // schedule never changed
    try std.testing.expect(!eng.telemetry().fault);
}

// ===========================================================================
// 3b. Adaptive AEC — a fused two-sample-input processor renders through the engine
// ===========================================================================

test "integration: a two-input Aec (mic + reference) renders through the runtime engine" {
    const N = 16;
    const alloc = std.testing.allocator;
    // Two distinct sources feed the AEC's two sample input ports. With the NLMS step
    // size held at 0 the taps never leave zero, so the output is the mic verbatim
    // (e = d − 0) — a deterministic check that BOTH inputs are wired and the mic port
    // is gathered as the primary, exercising multi-sample-input end to end.
    var mic_in: [N]S = undefined;
    var ref_in: [N]S = undefined;
    for (&mic_in, &ref_in, 0..) |*m, *r, i| {
        m.ch[0] = 0.3 * @as(f32, @floatFromInt(i + 1));
        r.ch[0] = -0.1 * @as(f32, @floatFromInt(i + 1)); // a different signal
    }
    var out: [N]S = undefined;

    var g = pan.Graph.init(alloc, cfg(N));
    defer g.deinit();
    const mic = try g.add(BufSource, .{ .data = @as([*]const S, &mic_in) });
    const ref = try g.add(BufSource, .{ .data = @as([*]const S, &ref_in) });
    const aec = try g.add(pan.fx.Aec(Num, 8), .{ .mu = 0.0 }); // adaptation frozen
    const sink = try g.add(BufSink, .{});
    try g.connect(mic, aec.in(0)); // mic → primary input port
    try g.connect(ref, aec.in(1)); // reference → second input port
    try g.connect(aec, sink);
    var eng = try g.commit();
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 4), eng.op_count);

    const token = pan.enterRealtimeThread();
    defer token.leave();
    sink.instance().dest = (&out).ptr;
    eng.renderInto(token);

    // mu = 0 ⇒ the AEC passes the mic through unchanged (taps stay zero).
    for (mic_in, out) |m, y| try std.testing.expectEqual(m.ch[0], y.ch[0]);
    try std.testing.expect(!eng.telemetry().fault);
}

// ===========================================================================
// 4. Integration sanity — a wired Lfo render is zipper-free and finite
// ===========================================================================

test "integration: wired Lfo→Vca renders a zipper-free gain sweep" {
    const N = 16;
    const alloc = std.testing.allocator;
    var input: [N]S = @splat(.{ .ch = .{1.0} });
    var out: [N]S = undefined;

    var g = pan.Graph.init(alloc, cfg(N));
    defer g.deinit();
    const src = try g.add(BufSource, .{ .data = @as([*]const S, &input) });
    const lfo = try g.add(pan.gen.Lfo, .{ .increment = 0.02, .amplitude = 0.5, .offset = 0.5 });
    const vca = try g.add(pan.fx.Vca(Num), .{});
    const sink = try g.add(BufSink, .{});
    try g.connect(src, vca);
    try g.connect(lfo, vca.param.gain);
    try g.connect(vca, sink);
    var eng = try g.commit();
    defer eng.deinit();

    const token = pan.enterRealtimeThread();
    defer token.leave();
    sink.instance().dest = (&out).ptr;
    eng.renderInto(token);

    // Anti-zipper: consecutive samples never jump by more than the per-block ramp
    // step (no click), and every sample is finite and within the gain's swing.
    var prev: f32 = out[0].ch[0];
    const max_step: f32 = 1.0 / @as(f32, N) + 1e-6; // gain spans at most ~1 over the block
    for (out) |y| {
        const v = y.ch[0];
        try std.testing.expect(std.math.isFinite(v));
        try std.testing.expect(@abs(v - prev) <= max_step);
        prev = v;
    }
    try std.testing.expect(!eng.telemetry().fault);
}
