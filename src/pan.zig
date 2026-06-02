//! pan — root module re-exporting the public surface (GAP-1 tracer bullet).
//!
//! This is a COMPILING tracer-bullet skeleton proving the comptime API
//! machinery lowers correctly in Zig 0.16.0. Kernels are empty/stub; the point
//! is that the typed ports / PortId / classifier / commit pass lower correctly.
//!
//! Single source of truth: specifications/catalog.md (and its siblings).

const std = @import("std");

// --- canonical port elements (catalog §1.3) -------------------------------
pub const types = @import("types.zig");
pub const Sample = types.Sample;
pub const Frame = types.Frame;
pub const Complex = types.Complex;
pub const FeatureFrame = types.FeatureFrame;
pub const Scalar = types.Scalar;
pub const Bounded = types.Bounded;

// --- the Numeric trait & comptime precision switch (catalog §1.4, §9) ------
pub const numeric = @import("numeric.zig");
pub const Numeric = numeric.Numeric;
pub const Precision = numeric.Precision;
pub const numericFor = numeric.numericFor;

// --- comptime port machinery (catalog §3.2, type-model §1) -----------------
pub const port = @import("port.zig");
pub const PortId = port.PortId;
pub const Direction = port.Direction;
pub const BlockClass = port.BlockClass;
pub const classify = port.classify;

// --- the SampleMux seam (catalog §4.1) -------------------------------------
pub const mux = @import("mux.zig");
pub const SampleMux = mux.SampleMux;
pub const TestSampleMux = mux.TestSampleMux;
pub const PullSampleMux = mux.PullSampleMux;

// --- graph + commit + engine (catalog §3, §8) ------------------------------
pub const graph = @import("graph.zig");
pub const Graph = graph.Graph;

pub const commit = @import("commit.zig");
pub const RenderOp = commit.RenderOp;
pub const Plan = commit.Plan;
pub const commitComptime = commit.commitComptime;

pub const engine = @import("engine.zig");
pub const RealtimeToken = engine.RealtimeToken;
pub const enterRealtimeThread = engine.enterRealtimeThread;
pub const renderInto = engine.renderInto;

// Pull in every module's tests when this root is the test target.
// NOTE: 0.16.0 std exposes `refAllDecls` (non-recursive) only; there is no
// `refAllDeclsRecursive`. Because this root re-exports each submodule as a
// `pub const`, referencing those decls causes each submodule file to be
// analyzed and its `test {}` blocks to be included in the test binary.
test {
    std.testing.refAllDecls(@This());
}

// =====================================================================
// The comptime-commit SMOKE GATE (catalog §8.5).
//
// Build a tiny comptime graph (I2S/stub source -> gain -> sink), call the
// commit at `comptime`, and assert `footprint_bytes > 0` is a comptime
// constant. The build compiling IS the discharge of the comptime-commit
// obligation for this smoke graph (the loud-failure gate of §8.5).
// =====================================================================

/// Stub I2S source: emits Sample(f32) frames. Map-shaped (rate-1:1) stub.
const I2sSource = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// Stub gain: rate-1:1 element-preserving Map (empty kernel = copy).
const Gain = struct {
    const Self = @This();
    gain: f32 = 1.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// Stub I2S sink: rate-1:1 Map (empty kernel).
const I2sSink = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// The smoke graph, built at comptime: source -> gain -> sink.
fn smokeGraph() Graph {
    var g = Graph.empty;
    const src = g.add(I2sSource);
    const gain = g.add(Gain);
    const sink = g.add(I2sSink);
    g.connect(port.MapOutPort(I2sSource), src, 0, port.MapInPort(Gain), gain, 0);
    g.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(I2sSink), sink, 0);
    return g;
}

test "comptime-commit smoke gate: footprint_bytes is a comptime constant > 0 (catalog §8.5)" {
    // Everything below runs at comptime — this is the embedded "same code,
    // specialized" obligation: the commit pass evaluated at `comptime`.
    const g = comptime smokeGraph();
    const plan = comptime try commitComptime(g);

    // `footprint_bytes` must be a *comptime constant* (H2, §7.8). We prove that
    // by using it as an array length — only a comptime-known value is legal here.
    const proof: [plan.footprint_bytes]u8 = undefined;
    comptime std.debug.assert(proof.len > 0);

    try std.testing.expect(plan.footprint_bytes > 0);
    try std.testing.expectEqual(@as(usize, 2), plan.op_count); // two edges
    // f32 Sample == Frame(f32,1) == { [1]f32 } => 4 bytes per edge, 2 edges.
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(Sample(f32))), plan.footprint_bytes);
}

test "smoke gate: PortId minting + Map/Rate classifier on the stub blocks" {
    // Positive test that the comptime port machinery works on a sample block.
    try std.testing.expect(classify(Gain) == .Map);
    const InPort = port.MapInPort(Gain);
    const OutPort = port.MapOutPort(Gain);
    try std.testing.expect(InPort.Elem == Sample(f32));
    try std.testing.expect(OutPort.Elem == Sample(f32));
    try std.testing.expect(InPort.direction == .in);
    try std.testing.expect(OutPort.direction == .out);
}
