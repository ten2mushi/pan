//! pan — the public API surface.
//!
//! This root module pins and re-exports the public identifiers. The load-
//! bearing type machinery (the Numeric trait, the channel-layout descriptor,
//! the canonical port elements, the typed `PortId`, the block classifier) is
//! real and exercised throughout; the builder/engine surface is pinned and its
//! authoring arc type-checks, while the executor, control plane, and the
//! layered DSP libraries are completed by later phases.

const std = @import("std");

// --- configuration --------------------------------------------------------

/// The Numeric trait & comptime precision switch. `precision` is comptime-known:
/// `numericFor(p, opts)` is a comptime switch and a precision change requires a
/// recommit.
pub const numeric = @import("numeric.zig");
pub const Numeric = numeric.Numeric;
pub const Precision = numeric.Precision;
pub const NumericOptions = numeric.NumericOptions;
pub const numericFor = numeric.numericFor;

pub const config = @import("config.zig");
pub const Config = config.Config;

// --- canonical port elements ----------------------------------------------

pub const types = @import("types.zig");
pub const ChannelLayout = types.ChannelLayout;
pub const Frame = types.Frame;
pub const Sample = types.Sample;
pub const Planar = types.Planar;
pub const PlanarConst = types.PlanarConst;
pub const isPlanarView = types.isPlanarView;
pub const Complex = types.Complex;
pub const FeatureFrame = types.FeatureFrame;
pub const Scalar = types.Scalar;
pub const Bounded = types.Bounded;

// --- comptime port machinery ----------------------------------------------

pub const port = @import("port.zig");
pub const PortId = port.PortId;
pub const ParamPortId = port.ParamPortId;
pub const ParamPort = port.ParamPort;
pub const NamedInPort = port.NamedInPort;
pub const ConcatOut = port.ConcatOut;
pub const Direction = port.Direction;
pub const BlockClass = port.BlockClass;
pub const classify = port.classify;
pub const isSource = port.isSource;

// --- the SampleMux seam (the only block ↔ transport coupling) --------------

pub const mux = @import("mux.zig");
pub const SampleMux = mux.SampleMux;
pub const TestSampleMux = mux.TestSampleMux;
pub const PullTestSampleMux = mux.PullTestSampleMux;
pub const PullSampleMux = mux.PullSampleMux;
pub const RingSampleMux = mux.RingSampleMux;

// --- graph, commit, engine ------------------------------------------------

/// The low-level comptime graph IR (the substrate the commit pass consumes).
pub const graph = @import("graph.zig");

pub const commit = @import("commit.zig");
pub const RenderOp = commit.RenderOp;
pub const Plan = commit.Plan;
pub const CommitError = commit.CommitError;
pub const BufferMode = commit.BufferMode;
pub const Coercion = commit.Coercion;
pub const EdgeFormat = commit.EdgeFormat;
pub const coercionFor = commit.coercionFor;
pub const commitComptime = commit.commitComptime;
pub const commitComptimeMode = commit.commitComptimeMode;

/// The developer-facing graph builder — `pan.Graph.init / add / connect /
/// commit`. Wraps the IR and the commit pass.
pub const builder = @import("builder.zig");
pub const Graph = builder.Graph;
pub const NodeHandle = builder.NodeHandle;
pub const Endpoint = builder.Endpoint;

pub const engine = @import("engine.zig");
pub const Engine = engine.Engine;
pub const ExecutionMode = engine.ExecutionMode;
pub const EngineOptions = engine.EngineOptions;
pub const Threads = engine.Threads;
pub const Edit = engine.Edit;
pub const Telemetry = engine.Telemetry;
pub const RealtimeToken = engine.RealtimeToken;
pub const enterRealtimeThread = engine.enterRealtimeThread;
pub const renderInto = engine.renderInto;
/// The Tier-A bound executor — monomorphize over a committed comptime graph and
/// its node-id → block-type tuple to get a runnable, wait-free pull renderer.
pub const Executor = engine.Executor;

// --- the Compute HAL (portable @Vector kernels) ---------------------------

pub const simd = @import("simd.zig");

// --- namespaced layered-library roots -------------------------------------

/// The I/O boundary: LPCM codecs (14 PCM formats + i24 packed + float PCM,
/// endianness, channel-order reconciliation, dither), the in-memory `LpcmSource`,
/// and the device backends (CoreAudio on macOS, ALSA on Linux) behind one seam.
pub const io = @import("io.zig");
/// First DSP filters — `Gain` (aliasing-safe) and `Biquad` (per-sample Mealy).
pub const filters = @import("filters.zig");
/// Spatial blocks — `ConstantPowerPan` (mono → stereo, layout-changing).
pub const spatial = @import("spatial.zig");
/// The realtime-thread entry: `pan.realtime.enterRealtimeThread()` sets FTZ/DAZ.
pub const realtime = struct {
    pub const enterRealtimeThread = engine.enterRealtimeThread;
    pub const RealtimeToken = engine.RealtimeToken;
};

// Layered-library roots filled by later phases.
pub const gen = struct {};
pub const env = struct {};
pub const fx = struct {};
pub const spectral = struct {};
pub const feat = struct {};
pub const mix = struct {};
pub const time = struct {};
pub const synth = struct {};

/// Graph combinators. `Concat` is the named fan-in: a comptime
/// struct-of-(name → element-type) spec mints one typed input port per name
/// (`node.in.<name>`) and synthesizes the output struct whose field order is the
/// canonical column order. (Stub kernel; the full block lands with the analysis
/// phase.)
pub const combinators = struct {
    pub fn Concat(comptime spec: anytype) type {
        return struct {
            const Self = @This();
            pub const inputs = spec;
            pub const Out = port.ConcatOut(spec);
            pub fn process(self: *Self, out: []Out) void {
                _ = self;
                _ = out;
            }
        };
    }
};

// Pull in every re-exported submodule's `test {}` blocks when this root is the
// test target. Referencing each `pub const` submodule forces its analysis.
test {
    std.testing.refAllDecls(@This());
}

// =====================================================================
// The comptime-commit smoke gate (on the IR + the comptime commit pass).
//
// Build a tiny graph (source → gain → sink) and run the commit at comptime,
// then use the resulting `footprint_bytes` as an array length. Only a
// comptime-known value is legal as an array length, so the build compiling at
// all IS the discharge of the "the commit pass evaluates at comptime" promise
// for this graph — the same property the embedded profile relies on.
// =====================================================================

const SmokeSource = struct {
    const Self = @This();
    // A Source: zero sample inputs, so it may legally root a path (its output
    // length comes from the pull demand, not an input slice).
    pub fn process(self: *Self, out: []Sample(f32)) void {
        _ = self;
        _ = out;
    }
};

const SmokeGain = struct {
    const Self = @This();
    gain: f32 = 1.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

const SmokeSink = struct {
    const Self = @This();
    // A sink: input only, no output port.
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        _ = self;
        _ = in;
    }
};

/// The smoke graph, buildable at comptime on the IR: source → gain → sink.
pub fn smokeGraph() graph.Graph {
    var g = graph.Graph.empty;
    const src = g.add(SmokeSource);
    const gain = g.add(SmokeGain);
    const sink = g.add(SmokeSink);
    g.connect(port.MapOutPort(SmokeSource), src, 0, port.MapInPort(SmokeGain), gain, 0);
    g.connect(port.MapOutPort(SmokeGain), gain, 0, port.MapInPort(SmokeSink), sink, 0);
    return g;
}

test "comptime-commit smoke gate: footprint_bytes is a comptime constant > 0" {
    const g = comptime smokeGraph();
    const plan = comptime try commitComptime(g);

    // Legal only because footprint_bytes is comptime-known.
    const proof: [plan.footprint_bytes]u8 = undefined;
    comptime std.debug.assert(proof.len > 0);

    try std.testing.expect(plan.footprint_bytes > 0);
    // One op per node: source → gain → sink = 3 ops.
    try std.testing.expectEqual(@as(usize, 3), plan.op_count);
    // Two ping-pong pool buffers (M=2) over the default N=512: 2 · 512 · 4.
    try std.testing.expectEqual(@as(usize, 2 * 512 * @sizeOf(Sample(f32))), plan.footprint_bytes);
}

test "smoke gate: classifier + PortId minting on the stub blocks" {
    try std.testing.expect(classify(SmokeGain) == .Map);
    const InPort = port.MapInPort(SmokeGain);
    const OutPort = port.MapOutPort(SmokeGain);
    try std.testing.expect(InPort.Elem == Sample(f32));
    try std.testing.expect(OutPort.Elem == Sample(f32));
    try std.testing.expect(InPort.direction == .in);
    try std.testing.expect(OutPort.direction == .out);
}

test "DX surface: Concat named fan-in wires by name and commits" {
    const Collect = combinators.Concat(.{
        .mfcc = FeatureFrame(13),
        .centroid = Scalar(f32),
    });
    const Mfcc = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const Sample(f32), out: []FeatureFrame(13)) void {
            _ = self;
            _ = in;
            _ = out;
        }
    };
    const Centroid = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const Sample(f32), out: []Scalar(f32)) void {
            _ = self;
            _ = in;
            _ = out;
        }
    };
    var g = Graph.init(std.testing.allocator, .{});
    defer g.deinit();
    const mfcc = try g.add(Mfcc, .{});
    const centroid = try g.add(Centroid, .{});
    const collect = try g.add(Collect, .{});
    try g.connect(mfcc, collect.in.mfcc); // wired BY NAME
    try g.connect(centroid, collect.in.centroid);
    var eng = try g.commit();
    defer eng.deinit();
    try std.testing.expectEqual(@as(usize, 2), eng.op_count);
}
