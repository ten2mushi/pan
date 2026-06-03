//! example_a_coloring_test — reproduce worked-example-A's per-class coloring
//! (`M_Sample = 3`, `M_Complex = 2`) at COMPTIME on the dry/wet FFT-diamond
//! topology (`src/commit.zig` left-edge colorer).
//!
//! The reference graph is the dry/wet diamond:
//!
//!   source → ┬─ dry: Gain → compDelay(DelayLine 1024) ─┐
//!            └─ wet: STFT → SpectralGain → iSTFT        ┴→ Mix → sink
//!
//! built from SYNTHETIC stub blocks — the STFT/SpectralGain/iSTFT carry no real
//! numerics here (those are the rate-elastic-seam phase); only their PORT SHAPES
//! matter to the colorer (`STFT: Sample→Complex`, `SpectralGain: Complex→Complex`,
//! `iSTFT: Complex→Sample`), so the commit pass sees exactly the two element
//! classes the worked example does. The dry branch carries an explicit
//! `DelayLine(1024)` standing in for the PDC compensating delay; its 3-way fan-in
//! at `Mix` (its output, the iSTFT output, and the still-live Gain→compDelay edge,
//! end-inclusively) is what forces three simultaneously-live `Sample` buffers.
//!
//! COMPARISON MODE: this is a ⊢ structural reproduction of the commit pass's own
//! output (the `M_class` counts), asserted from the committed `Plan` at comptime —
//! pan-vs-itself, exact integers, no oracle. We read each pool buffer's byte length
//! to count colors per class (a `Sample(f32)` color is `N·4 = 2048` B at `N=512`, a
//! `Complex(f32)` color is `N·8 = 4096` B), which is exactly `M_Sample` and
//! `M_Complex`.
//!
//! NOTE (honest scope): the spec's §10 *footprint figure* of 14352 B assumes the
//! spectral edges live on a hop-256 feature-frame rate domain (257-wide complex
//! frames) — that per-rate-domain sizing is the `Rate`-block phase. Here the STFT
//! stubs are rate-1:1 `Map`s, so each `Complex` pool buffer is `N`-wide (`N=512`),
//! and only the COLORING (`M_Sample=3`, `M_Complex=2`) — the gate's success
//! criterion — is reproduced, not the 14352 number.
//!
//! Verified against zig 0.16.0 (zig-0-16 skill loaded per Rules 13/14). Any
//! diagnostics on reject paths would use `std.debug.print`, never `std.log.err`.

const std = @import("std");
const pan = @import("pan");

const graph = pan.graph;
const commit = pan.commit;
const port = pan.port;
const types = pan.types;

const Sample = types.Sample;
const Complex = types.Complex;

// --- synthetic stub blocks (port shapes only; numerics are a later phase) ----

/// A mono `Sample(f32)` generator (zero sample inputs ⇒ a Source / legal path head).
const Source = struct {
    const Self = @This();
    pub fn process(self: *Self, out: []Sample(f32)) void {
        _ = self;
        _ = out;
    }
};

/// The dry-path gain: `Sample → Sample`, rate-1:1.
const Gain = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// STFT stub: `Sample → Complex` (the analysis edge that opens the spectral class).
const Stft = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Complex(f32)) void {
        _ = self;
        for (in, out) |x, *y| y.* = .{ .z = .{ .re = x.ch[0], .im = 0 } };
    }
};

/// Spectral processing: `Complex → Complex` (the overlapping spectral edge).
const SpectralGain = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Complex(f32), out: []Complex(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// iSTFT stub: `Complex → Sample` (closes the spectral class back into audio).
const Istft = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Complex(f32), out: []Sample(f32)) void {
        _ = self;
        for (in, out) |x, *y| y.* = .{ .ch = .{x.z.re} };
    }
};

/// The dry/wet summer: two `Sample` inputs → one `Sample` output.
const Mix = struct {
    const Self = @This();
    pub fn process(self: *Self, in0: []const Sample(f32), in1: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (in0, in1, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
    }
};

/// Mono sink: input only.
const Sink = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        _ = self;
        _ = in;
    }
};

/// The PDC compensating delay on the dry branch — a forward `DelayLine(1024)` whose
/// output edge participates in the `Sample` coloring and whose ring is counted in
/// the footprint (instance-resident, like the spec's persistent comp-delay).
const CompDelay = pan.DelayLine(Sample(f32), 1024);

/// Build the dry/wet FFT diamond at comptime (device `N = 512`, `f32`).
fn diamondGraph() graph.Graph {
    var g = graph.Graph.empty;
    g.block_size = 512;
    const src = g.add(Source);
    const gain = g.add(Gain); // dry
    const stft = g.add(Stft); // wet
    const spec = g.add(SpectralGain);
    const istft = g.add(Istft);
    const cdel = g.add(CompDelay); // dry PDC comp-delay
    const mix = g.add(Mix);
    const sink = g.add(Sink);

    // Fan-out from the source's single Sample output to both branches.
    g.connect(port.MapOutPort(Source), src, 0, port.MapInPort(Gain), gain, 0);
    g.connect(port.MapOutPort(Source), src, 0, port.MapInPort(Stft), stft, 0);
    // Dry branch: Gain → compDelay → Mix.in0.
    g.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(CompDelay), cdel, 0);
    g.connect(port.MapOutPort(CompDelay), cdel, 0, port.MapInPortAt(Mix, 0), mix, 0);
    // Wet branch: STFT → SpectralGain → iSTFT → Mix.in1.
    g.connect(port.MapOutPort(Stft), stft, 0, port.MapInPort(SpectralGain), spec, 0);
    g.connect(port.MapOutPort(SpectralGain), spec, 0, port.MapInPort(Istft), istft, 0);
    g.connect(port.MapOutPort(Istft), istft, 0, port.MapInPortAt(Mix, 1), mix, 1);
    // Mix → sink.
    g.connect(port.MapOutPort(Mix), mix, 0, port.MapInPort(Sink), sink, 0);
    return g;
}

/// Count pool buffers of a given byte length in the committed plan (one per color
/// of one class, since classes are uniform-size). This IS `M_class`.
fn countColorsOfSize(comptime n_ops: usize, plan: *const commit.Plan(n_ops), byte_len: usize) usize {
    var m: usize = 0;
    for (0..plan.pool_buffer_count) |id| {
        if (plan.buffer_byte_len[id] == byte_len) m += 1;
    }
    return m;
}

test "worked example A: the dry/wet diamond colors to M_Sample=3, M_Complex=2 at comptime" {
    const g = comptime diamondGraph();
    const plan = comptime try commit.commitComptime(g);

    const N = 512;
    const sample_color = N * @sizeOf(Sample(f32)); // 512·4 = 2048
    const complex_color = N * @sizeOf(Complex(f32)); // 512·8 = 4096

    // The two element classes, colored independently (⊢ across-class disjoint).
    const m_sample = comptime countColorsOfSize(g.node_count, &plan, sample_color);
    const m_complex = comptime countColorsOfSize(g.node_count, &plan, complex_color);
    try std.testing.expectEqual(@as(usize, 3), m_sample); // the §10.2 Sample class
    try std.testing.expectEqual(@as(usize, 2), m_complex); // the §10.2 Complex class

    // Exactly the 3 + 2 = 5 pool colors, no others.
    try std.testing.expectEqual(@as(usize, 5), plan.pool_buffer_count);
    // No feedback edges ⇒ no persistent tail.
    try std.testing.expectEqual(@as(usize, 0), plan.persistent_bytes);

    // Footprint = pools (3·2048 + 2·4096) + the comp-delay ring (1024·4) + the
    // comp-delay's instance state (its cursor, `@sizeOf(usize)` = 8 B). The stub
    // Maps carry no state. (The spec's 14352 assumes 257-wide spectral frames on a
    // separate rate domain — a later phase; see the file header.)
    const pools = 3 * sample_color + 2 * complex_color; // 6144 + 8192 = 14336
    const comp_delay_ring = 1024 * @sizeOf(Sample(f32)); // 4096
    const comp_delay_state = @sizeOf(usize); // DelayLine cursor = 8
    try std.testing.expectEqual(@as(usize, pools + comp_delay_ring + comp_delay_state), plan.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 18440), plan.footprint_bytes);

    // One op per node (8 nodes), forward-topo.
    try std.testing.expectEqual(@as(usize, 8), plan.op_count);
}

test "worked example A: the comptime M values are usable as array lengths (comptime constants)" {
    const g = comptime diamondGraph();
    const plan = comptime try commit.commitComptime(g);
    const m_sample = comptime countColorsOfSize(g.node_count, &plan, 512 * @sizeOf(Sample(f32)));
    const m_complex = comptime countColorsOfSize(g.node_count, &plan, 512 * @sizeOf(Complex(f32)));
    // Legal only because the M values are comptime-known (the H2 obligation).
    const sample_pool: [m_sample]u32 = undefined;
    const complex_pool: [m_complex]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 3), sample_pool.len);
    try std.testing.expectEqual(@as(usize, 2), complex_pool.len);
}
