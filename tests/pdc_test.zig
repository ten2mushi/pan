//! pdc_test — the gate for Phase 8's per-rate-domain plugin-delay-compensation:
//! the dry/wet FFT diamond re-aligns sample-accurately.
//!
//! Two complementary discharges of "the dry/wet diamond re-aligns sample-accurately
//! (worked example A)":
//!   (A) COMMIT: `insertPdc` over the diamond (real `Stft`/`iStft`, NO manual
//!       comp-delay) auto-inserts a `DelayLine` of the wet path's latency on the
//!       SHORTER dry branch — per-rate-domain (the spectral branch's latency lives
//!       on the hop grid and is converted back to audio samples before the max).
//!   (B) RENDER: the diamond WITH a comp-delay of that length (the value (A) just
//!       computed), rendered through the Tier-A `Executor` (exercising the Rate
//!       `pull` binding + the want-keyed multi-rate pools), sums dry+wet coherently
//!       — `mix[n] ≈ 2·src[n − (FRAME−HOP)]`. Without the comp-delay the dry branch
//!       leads the wet by FRAME−HOP and the sum is NOT a clean scaled delay, which
//!       the negative control asserts.
//!
//! Plus the gate's error-distinction (`UndeclaredCycle` vs `DelayFreeLoop`) and the
//! multi-input pull rule (mixed-rate sample fan-in is rejected, not reconciled).
//!
//! COMPARISON: (A) is pan-vs-itself exact integers on the committed graph; (B) is
//! `allclose` (the FFT round-trip is approximate). Verified against zig 0.16.0
//! (zig-0-16 skill loaded, Rules 13/14); reject diagnostics use std.debug.print.

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const graph = pan.graph;
const commit = pan.commit;
const port = pan.port;
const Sample = pan.Sample;
const f32num = pan.numericFor(.f32, .{});

const FRAME = 64;
const HOP = 32;
const N = 256;
const Spec = pan.Spectrum(f32, FRAME / 2 + 1);
const StftB = pan.Stft(f32num, FRAME, HOP);
const IstftB = pan.iStft(f32num, FRAME, HOP);
const Comp = pan.DelayLine(Sample(f32), FRAME - HOP); // = the PDC comp-delay length

// --- diamond blocks --------------------------------------------------------

const MonoSource = struct {
    const Self = @This();
    data: [*]const Sample(f32) = undefined,
    pub fn process(self: *Self, out: []Sample(f32)) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const IdGain = struct {
    const Self = @This();
    pub const aliasing_safe = true;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (in, out) |x, *o| o.ch[0] = x.ch[0];
    }
};
const SpecGain = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Spec, out: []Spec) void {
        _ = self;
        @memcpy(out, in);
    }
};
const Mix = struct {
    const Self = @This();
    pub fn process(self: *Self, in0: []const Sample(f32), in1: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (in0, in1, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
    }
};
const MonoSink = struct {
    const Self = @This();
    dest: [*]Sample(f32) = undefined,
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

/// Build the diamond. `with_comp = true` splices the dry-branch comp-delay
/// (`Comp`) the PDC pass would otherwise insert; `false` leaves the bare topology
/// so `insertPdc` can be asked to insert it.
fn diamond(comptime with_comp: bool) graph.Graph {
    var g = graph.Graph.empty;
    g.block_size = N;
    const src = g.add(MonoSource);
    const gain = g.add(IdGain); // dry
    const stft = g.add(StftB); // wet
    const spec = g.add(SpecGain);
    const istft = g.add(IstftB);
    const cdel = if (with_comp) g.add(Comp) else 0;
    const mix = g.add(Mix);
    const sink = g.add(MonoSink);

    g.connect(port.MapOutPort(MonoSource), src, 0, port.MapInPort(IdGain), gain, 0);
    g.connect(port.MapOutPort(MonoSource), src, 0, port.RateInPort(StftB), stft, 0);
    g.connect(port.RateOutPort(StftB), stft, 0, port.MapInPort(SpecGain), spec, 0);
    g.connect(port.MapOutPort(SpecGain), spec, 0, port.RateInPort(IstftB), istft, 0);
    g.connect(port.RateOutPort(IstftB), istft, 0, port.MapInPortAt(Mix, 1), mix, 1);
    if (with_comp) {
        g.connect(port.MapOutPort(IdGain), gain, 0, port.MapInPort(Comp), cdel, 0);
        g.connect(port.MapOutPort(Comp), cdel, 0, port.MapInPortAt(Mix, 0), mix, 0);
    } else {
        g.connect(port.MapOutPort(IdGain), gain, 0, port.MapInPortAt(Mix, 0), mix, 0);
    }
    g.connect(port.MapOutPort(Mix), mix, 0, port.MapInPort(MonoSink), sink, 0);
    return g;
}

// === (A) commit: insertPdc auto-inserts the dry comp-delay, per-rate-domain ===

test "PDC: insertPdc inserts a dry-branch comp-delay = the wet STFT/iSTFT latency" {
    const g = comptime diamond(false);
    const g2 = comptime pan.insertPdc(g);
    // One PDC comp-delay inserted; nothing else changed.
    try std.testing.expectEqual(@as(usize, g.node_count + 1), g2.node_count);
    var comp_len: usize = 0;
    var comp_count: usize = 0;
    for (g2.nodes[0..g2.node_count]) |node| if (node.is_pdc) {
        comp_len = node.delay_len;
        comp_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), comp_count);
    // The wet path latency is the STFT analysis priming = (FRAME/HOP−1)·HOP =
    // FRAME−HOP audio samples, converted from the hop-grid frame domain back to
    // audio — exactly the comp-delay length on the dry branch.
    try std.testing.expectEqual(@as(usize, FRAME - HOP), comp_len);
    // The compensated graph commits cleanly.
    const plan = comptime try commit.commitGraph(g2, .colored);
    try std.testing.expect(plan.footprint_bytes > 0);
}

// === (B) render: the compensated diamond aligns dry+wet through the Executor ==

test "PDC: the compensated dry/wet diamond renders aligned (mix ≈ 2·src delayed)" {
    const g = comptime diamond(true);
    const Exec = pan.Executor(g, &.{ MonoSource, IdGain, StftB, SpecGain, IstftB, Comp, Mix, MonoSink });

    var input: [N]Sample(f32) = undefined;
    h.fillNoise(&input, 31);
    var output: [N]Sample(f32) = undefined;

    var exec: Exec = .{
        .instances = .{
            .{ .data = &input }, // MonoSource
            .{}, // IdGain
            .{}, // Stft
            .{}, // SpecGain
            .{}, // iStft
            .{}, // Comp (DelayLine)
            .{}, // Mix
            .{ .dest = &output }, // MonoSink
        },
    };
    const token = pan.enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    // Both branches now carry the same FRAME−HOP delay, so the sum is a clean 2×
    // of the input delayed by that amount. Check the steady-state region (past one
    // full frame, safely beyond the analysis/OLA priming).
    const delay = FRAME - HOP;
    const xs = h.sampleValues(&input);
    const ys = h.sampleValues(&output);
    var n: usize = FRAME;
    while (n < N) : (n += 1) {
        const want = 2.0 * xs[n - delay];
        try std.testing.expectApproxEqAbs(want, ys[n], 1e-3);
    }
}

test "PDC negative control: WITHOUT the comp-delay the diamond is misaligned" {
    // The bare diamond (dry undelayed) is still a legal graph and renders, but dry
    // leads wet by FRAME−HOP, so the sum is NOT 2·src[n−delay] — proving the
    // comp-delay is load-bearing, not cosmetic.
    const g = comptime diamond(false);
    const Exec = pan.Executor(g, &.{ MonoSource, IdGain, StftB, SpecGain, IstftB, Mix, MonoSink });
    var input: [N]Sample(f32) = undefined;
    h.fillNoise(&input, 31);
    var output: [N]Sample(f32) = undefined;
    var exec: Exec = .{ .instances = .{
        .{ .data = &input }, .{}, .{}, .{}, .{}, .{}, .{ .dest = &output },
    } };
    const token = pan.enterRealtimeThread();
    defer token.leave();
    exec.render(token);

    const delay = FRAME - HOP;
    const xs = h.sampleValues(&input);
    const ys = h.sampleValues(&output);
    var mismatch = false;
    var n: usize = FRAME;
    while (n < N) : (n += 1) {
        if (@abs(ys[n] - 2.0 * xs[n - delay]) > 1e-3) mismatch = true;
    }
    try std.testing.expect(mismatch); // uncompensated ⇒ NOT the aligned 2× delay
}

// === runtime Engine: insertPdc + the bound delay kernel actually compensate ===

test "PDC in the runtime Engine: a bypassed latent block is delay-compensated on render" {
    // The runtime Engine's buildBoundPlan now runs insertPdc and binds a real delay
    // kernel for the inserted comp-delay. A BYPASSED block with algorithmic_latency
    // L gets a DelayLine(L) routed on its output (bypass-preserves-latency), so an
    // impulse through Source→Latent(bypassed,L)→Sink emerges delayed by exactly L —
    // exercising insertPdc + the bound pdcDelayThunk + the inserted-state lifecycle.
    const engine = pan.engine;
    const L = 16;
    const Nn = 128;
    const Src = struct {
        const Self = @This();
        data: [*]const Sample(f32) = undefined,
        pub fn process(self: *Self, out: []Sample(f32)) void {
            @memcpy(out, self.data[0..out.len]);
        }
    };
    const Latent = struct {
        const Self = @This();
        pub const algorithmic_latency: usize = L;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in); // bypassed ⇒ passthrough; the comp-delay supplies the L delay
        }
    };
    const Snk = struct {
        const Self = @This();
        dest: [*]Sample(f32) = undefined,
        pub fn process(self: *Self, in: []const Sample(f32)) void {
            @memcpy(self.dest[0..in.len], in);
        }
    };

    const gpa = std.testing.allocator;
    var input: [Nn]Sample(f32) = undefined;
    h.fillImpulse(&input);
    var output: [Nn]Sample(f32) = [_]Sample(f32){.{ .ch = .{0} }} ** Nn;

    // Low-level IR (the builder doesn't expose bypass): Source → Latent → Sink.
    var ir = graph.Graph.empty;
    ir.block_size = Nn;
    const s = ir.add(Src);
    const lat = ir.add(Latent);
    const sk = ir.add(Snk);
    ir.connect(port.MapOutPort(Src), s, 0, port.MapInPort(Latent), lat, 0);
    ir.connect(port.MapOutPort(Latent), lat, 0, port.MapInPort(Snk), sk, 0);
    ir.markBypassed(lat);

    // Hand-build the bound nodes (instances owned by the engine, freed at deinit).
    const si = try gpa.create(Src);
    si.* = .{ .data = &input };
    const li = try gpa.create(Latent);
    li.* = .{};
    const ki = try gpa.create(Snk);
    ki.* = .{ .dest = &output };
    const bound = [_]engine.BoundNode{
        .{ .self_ptr = si, .render = engine.renderThunk(Src), .destroy = engine.destroyThunk(Src) },
        .{ .self_ptr = li, .render = engine.renderThunk(Latent), .destroy = engine.destroyThunk(Latent) },
        .{ .self_ptr = ki, .render = engine.renderThunk(Snk), .destroy = engine.destroyThunk(Snk) },
    };
    var eng = try engine.Engine.bind(gpa, ir, &bound, .{ .block_size = Nn }, .{});
    defer eng.deinit();

    // insertPdc added one comp-delay node ⇒ 4 ops (source, latent, pdc-delay, sink).
    try std.testing.expectEqual(@as(usize, 4), eng.op_count);

    const token = pan.enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    // The impulse emerges delayed by exactly L (the compensating delay).
    const ys = h.sampleValues(&output);
    const delay = h.measuredGroupDelay(ys, 1e-6) orelse return error.NoResponse;
    try std.testing.expectEqual(@as(usize, L), delay);
    try std.testing.expect(!eng.telemetry().fault);
}

// === SRC: a real sample-rate-conversion coercion resamples through the Engine ==

test "SRC: a 44.1k→48k resampler coercion renders a 1 kHz sine resampled (runtime Engine)" {
    const engine = pan.engine;
    const pi = std.math.pi;
    const BN = 512;
    const f_hz: f64 = 1000.0;
    // A continuous 44.1 kHz sine generator (its phase carries across callbacks).
    const SineSrc = struct {
        const Self = @This();
        n: usize = 0,
        pub fn process(self: *Self, out: []Sample(f32)) void {
            for (out) |*o| {
                o.ch[0] = @floatCast(@sin(2.0 * pi * f_hz * @as(f64, @floatFromInt(self.n)) / 44100.0));
                self.n += 1;
            }
        }
    };
    const Snk = struct {
        const Self = @This();
        dest: [*]Sample(f32) = undefined,
        cur: usize = 0,
        pub fn process(self: *Self, in: []const Sample(f32)) void {
            @memcpy(self.dest[self.cur .. self.cur + in.len], in);
            self.cur += in.len;
        }
    };

    const gpa = std.testing.allocator;
    const callbacks = 12;
    const out = try gpa.alloc(Sample(f32), callbacks * BN);
    defer gpa.free(out);

    // Source @44.1k → Sink @48k (a wired sample-rate mismatch → a resampler coercion).
    var ir = graph.Graph.empty;
    ir.block_size = BN;
    ir.sample_rate = 44100;
    const s = ir.add(SineSrc);
    ir.sample_rate = 48000;
    const sk = ir.add(Snk);
    ir.sample_rate = 48000; // the pipeline (sink) rate
    ir.connect(port.MapOutPort(SineSrc), s, 0, port.MapInPort(Snk), sk, 0);

    const si = try gpa.create(SineSrc);
    si.* = .{};
    const ki = try gpa.create(Snk);
    ki.* = .{ .dest = out.ptr };
    const bound = [_]engine.BoundNode{
        .{ .self_ptr = si, .render = engine.renderThunk(SineSrc), .destroy = engine.destroyThunk(SineSrc) },
        .{ .self_ptr = ki, .render = engine.renderThunk(Snk), .destroy = engine.destroyThunk(Snk) },
    };
    var eng = try engine.Engine.bind(gpa, ir, &bound, .{ .block_size = BN, .sample_rate = 48000 }, .{});
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 3), eng.op_count); // src → resampler → sink

    const token = pan.enterRealtimeThread();
    defer token.leave();
    for (0..callbacks) |_| eng.renderInto(token);
    try std.testing.expect(!eng.telemetry().fault);

    // The output is the same 1 kHz tone at 48 kHz, delayed by the resampler's group
    // delay (fractional). Past the priming transient it matches the analytic sine.
    const p_r: usize = 160; // out_per_in = 48000:44100 reduced = 160:147
    const q_r: usize = 147;
    const half: usize = pan.commit.resampler_half;
    const up = @max(p_r, q_r);
    const gd: f64 = @as(f64, @floatFromInt(half * up + p_r)) / @as(f64, q_r);
    const ys = h.sampleValues(out);
    var n: usize = 64; // skip the priming transient
    while (n < callbacks * BN - 16) : (n += 1) {
        const want_v: f64 = @sin(2.0 * pi * f_hz * (@as(f64, @floatFromInt(n)) - gd) / 48000.0);
        try std.testing.expectApproxEqAbs(want_v, @as(f64, ys[n]), 5e-2);
    }
}

// === gate: error distinctions + the multi-input pull rule ====================

test "PDC gate: error.UndeclaredCycle vs error.DelayFreeLoop are distinguished" {
    const Src = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []Sample(f32)) void {
            _ = self;
            _ = out;
        }
    };
    const Map1 = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const Sink = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const Sample(f32)) void {
            _ = self;
            _ = in;
        }
    };
    // (1) A plain (undeclared) back-edge that closes a forward cycle → UndeclaredCycle.
    const g_undeclared = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Src);
        const b = gg.add(Map1);
        const c = gg.add(Map1);
        const o = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), a, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPort(Map1), c, 0);
        gg.connect(port.MapOutPort(Map1), c, 0, port.MapInPort(Sink), o, 0);
        gg.connect(port.MapOutPort(Map1), c, 0, port.MapInPort(Map1), b, 0); // plain back-edge
        break :blk gg;
    };
    try std.testing.expectError(error.UndeclaredCycle, comptime commit.commitComptime(g_undeclared));

    // (2) A DECLARED feedback edge whose cycle has no delay element → DelayFreeLoop.
    const g_delayfree = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Src);
        const sum = gg.add(Map1);
        const gain = gg.add(Map1);
        const o = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), a, 0, port.MapInPort(Map1), sum, 0);
        gg.connect(port.MapOutPort(Map1), sum, 0, port.MapInPort(Map1), gain, 0);
        gg.connect(port.MapOutPort(Map1), gain, 0, port.MapInPort(Sink), o, 0);
        gg.connectFeedback(port.MapOutPort(Map1), gain, 0, port.MapInPort(Map1), sum, 0);
        break :blk gg;
    };
    try std.testing.expectError(error.DelayFreeLoop, comptime commit.commitComptime(g_delayfree));
}

test "multi-input pull rule: a mixed-rate sample fan-in is rejected (no implicit reconcile)" {
    // A node fed by an AUDIO-domain sample AND a hop-grid (post-Stft→iStft... here a
    // decimated) sample at different rates must be reconciled by an explicit
    // adapter. We build a fan-in where one branch passes through a 1:2 decimating
    // Rate and the other stays at the source rate, then sum them — different rate
    // domains, so commit rejects with error.MixedRateInputs.
    const Src = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []Sample(f32)) void {
            _ = self;
            _ = out;
        }
    };
    const Decim = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 2 }; // one out per two in → half rate
        pub const algorithmic_latency: usize = 0;
        pub fn pull(self: *Self, in: []const Sample(f32), want: usize, out: []Sample(f32)) usize {
            _ = self;
            _ = in;
            _ = out;
            return want;
        }
    };
    const Sum2 = struct {
        const Self = @This();
        pub fn process(self: *Self, in0: []const Sample(f32), in1: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            for (in0, in1, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
        }
    };
    const Sink = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const Sample(f32)) void {
            _ = self;
            _ = in;
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const dec = gg.add(Decim); // half-rate branch
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.RateInPort(Decim), dec, 0);
        gg.connect(port.RateOutPort(Decim), dec, 0, port.MapInPortAt(Sum2, 0), mix, 0); // half rate
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPortAt(Sum2, 1), mix, 1); // full rate
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    try std.testing.expectError(error.MixedRateInputs, comptime commit.commitComptime(g));
}

// === Rate-through-Executor: a Resampler runs in the bound op-list =============

test "Rate-in-Executor: a Resampler renders through the bound op-list (impulse delayed)" {
    const R = pan.Resampler(f32num, 1, 1, 8); // unit-ratio FIR, latency 8
    const Src = struct {
        const Self = @This();
        data: [*]const Sample(f32) = undefined,
        pub fn process(self: *Self, out: []Sample(f32)) void {
            @memcpy(out, self.data[0..out.len]);
        }
    };
    const Snk = struct {
        const Self = @This();
        dest: [*]Sample(f32) = undefined,
        pub fn process(self: *Self, in: []const Sample(f32)) void {
            @memcpy(self.dest[0..in.len], in);
        }
    };
    const M = 64;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = M;
        const s = gg.add(Src);
        const r = gg.add(R);
        const o = gg.add(Snk);
        gg.connect(port.MapOutPort(Src), s, 0, port.RateInPort(R), r, 0);
        gg.connect(port.RateOutPort(R), r, 0, port.MapInPort(Snk), o, 0);
        break :blk gg;
    };
    var input: [M]Sample(f32) = undefined;
    h.fillImpulse(&input);
    var output: [M]Sample(f32) = undefined;
    const Exec = pan.Executor(g, &.{ Src, R, Snk });
    var exec: Exec = .{ .instances = .{ .{ .data = &input }, .{}, .{ .dest = &output } } };
    const token = pan.enterRealtimeThread();
    defer token.leave();
    exec.render(token);
    // The unit-ratio FIR delays the impulse to its group-delay centre = 8.
    const delay = h.measuredGroupDelay(h.sampleValues(&output), 1e-6) orelse return error.NoResponse;
    try std.testing.expectEqual(@as(usize, R.algorithmic_latency), delay);
}
