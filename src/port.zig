//! Comptime port machinery: classify a block, read its port element types off
//! its signature, and mint the typed `PortId` handles that `connect`
//! type-checks against.
//!
//! A block's sample ports are derived from its `process`/`pull` parameters: a
//! `[]const A` slice is an input port carrying element `A`, a `[]A` slice is an
//! output port. The element type rides inside the `PortId` so wiring a mismatch
//! is a compile error naming the offending port. The port index is a `u3`,
//! which also caps a direction at 8 ports — a readable compile error past that.

const std = @import("std");
const types = @import("types.zig");

/// Port direction. Derived purely from slice constness: `[]const A` is an
/// input, `[]A` is an output.
pub const Direction = enum { in, out };

/// The port-index type. `u3` indexes 0..7, which is also the 8-port-per-
/// direction ceiling — eight ports per direction is enough for every block, and
/// the small index type makes the ceiling a type-level fact.
pub const PortIndex = u3;
pub const max_ports_per_direction: comptime_int = std.math.maxInt(PortIndex) + 1; // 8

/// Reject more than 8 ports per direction with a readable compile error.
pub fn checkPortCeiling(comptime n: comptime_int, comptime dir: Direction) void {
    if (n > max_ports_per_direction) {
        @compileError(std.fmt.comptimePrint(
            "pan: {d} {s} ports exceeds the 8-port-per-direction ceiling",
            .{ n, @tagName(dir) },
        ));
    }
}

/// A typed `PortId` — the connect-checking handle. It carries node identity
/// (the `Node` type), `direction`, and the element type `Elem`. Because all
/// three ride in the type, `connect` type-checks both ends and rejects a
/// mismatch at compile time, and two ports of different nodes are distinct
/// types even with identical element/direction.
pub fn PortId(comptime NodeT: type, comptime dir: Direction, comptime ElemT: type) type {
    return struct {
        index: PortIndex,

        const Self = @This();
        pub const Node = NodeT;
        pub const direction = dir;
        pub const Elem = ElemT;

        pub fn init(index: PortIndex) Self {
            return .{ .index = index };
        }
    };
}

/// A typed parameter (control) `PortId`. Same shape as `PortId` plus the marker
/// `is_param`, so the rate-1:1 law can exclude parameter ports: a parameter
/// port delivers one coefficient per render call, not a length-N sample window.
pub fn ParamPortId(comptime NodeT: type, comptime ElemT: type) type {
    return struct {
        index: PortIndex,

        const Self = @This();
        pub const Node = NodeT;
        pub const direction: Direction = .in;
        pub const Elem = ElemT;
        pub const is_param = true;

        pub fn init(index: PortIndex) Self {
            return .{ .index = index };
        }
    };
}

/// Structural test: is `T` a `PortId` (or `ParamPortId`)? Used by `connect`.
/// Wrapped in a `comptime` block so the answer is comptime-known at the call
/// site (a chain of `@hasDecl` results does not constant-fold on its own here).
pub fn isPortId(comptime T: type) bool {
    comptime {
        if (@typeInfo(T) != .@"struct") return false;
        if (!@hasDecl(T, "Node")) return false;
        if (!@hasDecl(T, "direction")) return false;
        if (!@hasDecl(T, "Elem")) return false;
        return true;
    }
}

/// Is `T` specifically a parameter port (carries the `is_param` marker)?
pub fn isParamPort(comptime T: type) bool {
    comptime {
        return isPortId(T) and @hasDecl(T, "is_param");
    }
}

/// Is `ParamT` an EVENT LANE param — an `EventLane(Event)` value a block consumes
/// in its `process`/`pull` signature alongside (or instead of) its sample ports?
/// An event lane is neither a sample port (no pooled buffer) nor a parameter port
/// (no ramp/hold scalar): it is delivered out-of-band by the executor from the
/// engine's per-node event store, exactly as `set` values arrive out-of-band — so
/// the port scanners SKIP it (it adds no sample input/output), which keeps an
/// event-driven generator (e.g. a polyphonic voice block) a zero-sample-input
/// Source that roots its path. The marker is the `is_event_lane` decl on the
/// `EventLane(Event)` type.
pub fn isEventLaneParam(comptime ParamT: type) bool {
    comptime {
        return @typeInfo(ParamT) == .@"struct" and @hasDecl(ParamT, "is_event_lane") and ParamT.is_event_lane;
    }
}

/// The `Event` element type a block's event-lane param carries (its
/// `EventLane(Event).Event`). Used by the executor to build the lane it hands the
/// block. `void` if the block declares no event-lane param (not event-driven).
pub fn EventOf(comptime Block: type) type {
    const decl = if (@hasDecl(Block, "process")) "process" else if (@hasDecl(Block, "pull")) "pull" else return void;
    const f = @typeInfo(@TypeOf(@field(Block, decl))).@"fn";
    inline for (f.params[1..]) |p| {
        if (comptime isEventLaneParam(p.type.?)) return p.type.?.Event;
    }
    return void;
}

/// Does `Block` consume an event lane (declare an `EventLane(Event)` param)?
pub fn isEventConsumer(comptime Block: type) bool {
    return EventOf(Block) != void;
}

/// Read one port param's element type and direction. Two shapes are accepted:
///
///   - A **planar buffer view** `Planar(Lane, L)` / `PlanarConst(Lane, L)` — the
///     enforced multi-channel form (`C` plane-major `[]Lane` planes). The
///     view's element IDENTITY is recovered from its `Elem` decl (`Frame(Lane,L)`)
///     and the direction from `is_const_view` (a const view is an input, a
///     mutable view an output). This is what `connect`/`PortId` type-check
///     against, so the pool class key and footprint are layout-agnostic.
///   - A plain **slice** `[]A` / `[]const A` — the single-plane form. Mono
///     (`A = Sample(T)`, one plane) and the non-`Frame` elements (`Scalar`,
///     `FeatureFrame`, `Complex`, …) ride here unchanged; one plane is
///     contiguous whether the port is spelled as a slice or a one-channel view.
///
/// The leading `self: *Self` is skipped by callers. A bare array slice element
/// is rejected: the buffer pool keys on the element and the diagnostics name it,
/// and a bare `[K]T` has no `typeName()` — it must be wrapped in a named struct
/// (e.g. `FeatureFrame(K)`).
fn portOfParam(comptime ParamT: type) struct { Elem: type, dir: Direction } {
    if (types.isPlanarView(ParamT)) {
        return .{
            .Elem = ParamT.Elem,
            .dir = if (ParamT.is_const_view) .in else .out,
        };
    }
    const info = @typeInfo(ParamT);
    if (info != .pointer or info.pointer.size != .slice) {
        @compileError("pan: a port param must be a planar view Planar(Lane,L)/" ++
            "PlanarConst(Lane,L) or a slice []A/[]const A, got " ++ @typeName(ParamT));
    }
    const Elem = info.pointer.child;
    if (@typeInfo(Elem) == .array)
        @compileError("pan: a port element may not be a bare array " ++ @typeName(Elem) ++
            " — wrap it in a named struct (e.g. FeatureFrame(K)) so it carries a typeName()");
    // STRICT PLANAR ENFORCEMENT (fail loud): a multi-channel audio stream buffer
    // must be PLANAR — `C` plane-major channel planes accessed via a planar view —
    // never an array-of-structs `[]Frame(Lane, L)` (which is interleaved L,R,L,R…
    // at the buffer level for `C > 1`). Reject a slice whose element is a Frame of
    // count > 1 here, so an AoS multi-channel port is a COMPILE ERROR, not silently
    // treated as interleaved. (Mono `Frame(.,.mono)` = `Sample` is one plane and
    // rides the slice path unchanged; `Scalar`/`FeatureFrame`/`Complex`/… are not
    // multi-channel Frames and are unaffected.)
    if (@hasDecl(Elem, "channel_count") and Elem.channel_count > 1)
        @compileError("pan: a multi-channel port must use a planar view " ++
            "Planar(Lane,L)/PlanarConst(Lane,L), not a slice of " ++ @typeName(Elem) ++
            " (array-of-structs is interleaved for C>1 — the internal buffer form is planar)");
    return .{
        .Elem = Elem,
        .dir = if (info.pointer.is_const) .in else .out,
    };
}

/// The three morphism classes, discriminated at comptime by field presence:
/// `rate_bounds` ⇒ `VariRate`; `out_per_in`/`pull` ⇒ `Rate`; otherwise a block
/// with a `process` is a `Map`. (A Source — a generator with zero sample-input
/// ports — is still one of these; it is not a fourth class.)
pub const BlockClass = enum { Map, Rate, VariRate };

/// Classify a block. The contract for each class is checked structurally:
///   - A `VariRate` declares a bounded `rate_bounds` interval and a worst-case
///     `max_latency`; missing either is a build error (the variable out:in
///     ratio still needs a static plan, so the worst case must be declared).
///   - A `Rate` declares both `out_per_in` and `pull`, plus `algorithmic_latency`
///     (group delay is orthogonal to the rate ratio); missing any is a build
///     error.
///   - Anything else with a `process` is a `Map`.
pub fn classify(comptime Block: type) BlockClass {
    const has_rate_bounds = @hasDecl(Block, "rate_bounds");
    const has_ratio = @hasDecl(Block, "out_per_in");
    const has_pull = @hasDecl(Block, "pull");

    if (has_rate_bounds) {
        if (!@hasDecl(Block, "max_latency"))
            @compileError("pan: " ++ @typeName(Block) ++
                " declares rate_bounds but no max_latency — VariRate contract incomplete");
        if (!has_pull)
            @compileError("pan: " ++ @typeName(Block) ++
                " declares rate_bounds but no pull — VariRate contract incomplete");
        return .VariRate;
    }

    if (has_pull or has_ratio) {
        if (!has_pull)
            @compileError("pan: " ++ @typeName(Block) ++
                " declares out_per_in but no pull — Rate contract incomplete");
        if (!has_ratio)
            @compileError("pan: " ++ @typeName(Block) ++
                " declares pull but no out_per_in — Rate contract incomplete");
        if (!@hasDecl(Block, "algorithmic_latency"))
            @compileError("pan: " ++ @typeName(Block) ++
                " is a Rate but declares no algorithmic_latency");
        return .Rate;
    }

    if (!@hasDecl(Block, "process"))
        @compileError("pan: " ++ @typeName(Block) ++
            " is neither a Map (process) nor a Rate (out_per_in + pull)");
    return .Map;
}

/// Count a `Map`'s sample input/output ports by scanning its `process` params
/// (after `self`) and classifying each slice by constness.
fn mapPortCounts(comptime Block: type) struct { inputs: comptime_int, outputs: comptime_int } {
    const f = @typeInfo(@TypeOf(Block.process)).@"fn";
    var inputs: comptime_int = 0;
    var outputs: comptime_int = 0;
    inline for (f.params[1..]) |p| {
        if (comptime isEventLaneParam(p.type.?)) continue; // event lane: not a sample port
        const port = portOfParam(p.type.?);
        if (port.dir == .in) inputs += 1 else outputs += 1;
    }
    return .{ .inputs = inputs, .outputs = outputs };
}

/// A Source is a block with ZERO sample-input ports: a generator (oscillator,
/// noise, wavetable, constant) whose output length comes from the pull demand,
/// not from an input slice. It is not a class of its own — it is a Map or Rate
/// with an empty input side.
pub fn isSource(comptime Block: type) bool {
    comptime {
        return switch (classify(Block)) {
            .Map => mapPortCounts(Block).inputs == 0,
            // A stream/sample source is a Rate whose `pull` reads a backing
            // store rather than an upstream edge — its signature has ZERO sample
            // input ports (`pull(self, want, out)`), exactly as a generator Map
            // has zero input slices. A mid-graph transducer (`pull(self, in,
            // want, out)`) has one input port and is NOT a source.
            .Rate, .VariRate => rateInputCount(Block) == 0,
        };
    }
}

/// The element on a `Map`'s (first) input port — the first `[]const A` param.
pub fn MapInElem(comptime Block: type) type {
    const f = @typeInfo(@TypeOf(Block.process)).@"fn";
    inline for (f.params[1..]) |p| {
        if (comptime isEventLaneParam(p.type.?)) continue;
        const port = portOfParam(p.type.?);
        if (port.dir == .in) return port.Elem;
    }
    @compileError("pan: " ++ @typeName(Block) ++ " has no sample input port (is it a Source?)");
}

/// The element on a `Map`'s (first) output port — the first `[]A` param.
pub fn MapOutElem(comptime Block: type) type {
    const f = @typeInfo(@TypeOf(Block.process)).@"fn";
    inline for (f.params[1..]) |p| {
        if (comptime isEventLaneParam(p.type.?)) continue;
        const port = portOfParam(p.type.?);
        if (port.dir == .out) return port.Elem;
    }
    @compileError("pan: " ++ @typeName(Block) ++ " has no output port");
}

/// Mint the input `PortId` type for a `Map` block from its `process` signature.
pub fn MapInPort(comptime Block: type) type {
    checkPortCeiling(1, .in);
    return PortId(Block, .in, MapInElem(Block));
}

/// Mint the output `PortId` type for a `Map` block.
pub fn MapOutPort(comptime Block: type) type {
    checkPortCeiling(1, .out);
    return PortId(Block, .out, MapOutElem(Block));
}

/// The number of sample input ports a `Map` declares.
pub fn mapInputCount(comptime Block: type) comptime_int {
    return mapPortCounts(Block).inputs;
}

/// The number of sample output ports a `Map` declares.
pub fn mapOutputCount(comptime Block: type) comptime_int {
    return mapPortCounts(Block).outputs;
}

/// The element on a `Map`'s `i`-th input port (0-based, declaration order) — the
/// reader behind the homogeneous indexed accessor `node.in(i)`. An out-of-range
/// index is a compile error naming the block and its port count.
pub fn MapInElemAt(comptime Block: type, comptime i: usize) type {
    const f = @typeInfo(@TypeOf(Block.process)).@"fn";
    comptime var seen: usize = 0;
    inline for (f.params[1..]) |p| {
        if (comptime isEventLaneParam(p.type.?)) continue;
        const pinfo = portOfParam(p.type.?);
        if (pinfo.dir == .in) {
            if (seen == i) return pinfo.Elem;
            seen += 1;
        }
    }
    @compileError(std.fmt.comptimePrint(
        "pan: {s} has no input port {d} (it declares {d})",
        .{ @typeName(Block), i, seen },
    ));
}

/// Mint the `i`-th input `PortId` for a `Map` block (the typed `node.in(i)`
/// handle). The 8-port ceiling is enforced via the index.
pub fn MapInPortAt(comptime Block: type, comptime i: usize) type {
    checkPortCeiling(i + 1, .in);
    return PortId(Block, .in, MapInElemAt(Block, i));
}

/// Is `ParamT` a SAMPLE PORT param (a slice or a planar view), as opposed to a
/// scalar like the `want: usize` demand? A `Rate`'s `pull` interleaves the demand
/// scalar among its port slices, so port scanning must skip the non-port params.
/// Exposed so the executor's kernel-arg builder classifies `pull`/`process` params
/// the same way the port machinery does.
pub fn isPortParam(comptime ParamT: type) bool {
    if (types.isPlanarView(ParamT)) return true;
    const info = @typeInfo(ParamT);
    return info == .pointer and info.pointer.size == .slice;
}

/// The element on a `Rate`/`VariRate` block's OUTPUT port — the first MUTABLE
/// port (a `[]Out` slice or a `Planar` view) among `pull`'s params after `self`.
/// Scanning for the output port (rather than a fixed index) accepts BOTH the
/// zero-input source shape `pull(self, want, out)` and the mid-graph transducer
/// shape `pull(self, in, want, out)` — the `want: usize` demand is skipped as a
/// non-port param, and a const input slice is skipped as an input port.
pub fn RateOutElem(comptime Block: type) type {
    const f = @typeInfo(@TypeOf(Block.pull)).@"fn";
    inline for (f.params[1..]) |p| {
        const ParamT = p.type.?;
        if (comptime !isPortParam(ParamT)) continue;
        const pinfo = portOfParam(ParamT);
        if (pinfo.dir == .out) return pinfo.Elem;
    }
    @compileError("pan: " ++ @typeName(Block) ++ " has no Rate output port in pull()");
}

/// The element on a mid-graph `Rate`/`VariRate` block's (first) sample INPUT port
/// — the first CONST port (`[]const In` slice or `PlanarConst` view) among
/// `pull`'s params. A zero-input Rate SOURCE (`pull(self, want, out)`) has none,
/// which is a compile error here (callers gate on `mapInputCount`-style counts).
pub fn RateInElem(comptime Block: type) type {
    const f = @typeInfo(@TypeOf(Block.pull)).@"fn";
    inline for (f.params[1..]) |p| {
        const ParamT = p.type.?;
        if (comptime !isPortParam(ParamT)) continue;
        const pinfo = portOfParam(ParamT);
        if (pinfo.dir == .in) return pinfo.Elem;
    }
    @compileError("pan: " ++ @typeName(Block) ++ " has no Rate sample input port (is it a Source?)");
}

/// How many sample INPUT ports a `Rate` block's `pull` declares (0 for a source).
pub fn rateInputCount(comptime Block: type) comptime_int {
    const f = @typeInfo(@TypeOf(Block.pull)).@"fn";
    comptime var n: comptime_int = 0;
    inline for (f.params[1..]) |p| {
        const ParamT = p.type.?;
        if (comptime !isPortParam(ParamT)) continue;
        if (portOfParam(ParamT).dir == .in) n += 1;
    }
    return n;
}

/// Mint the input `PortId` for a mid-graph `Rate` block (`node.in`).
pub fn RateInPort(comptime Block: type) type {
    checkPortCeiling(1, .in);
    return PortId(Block, .in, RateInElem(Block));
}

/// Mint the output `PortId` for a `Rate`/`VariRate` block (`node.out`).
pub fn RateOutPort(comptime Block: type) type {
    checkPortCeiling(1, .out);
    return PortId(Block, .out, RateOutElem(Block));
}

// --- named-input (Concat / fan-in by name) minting ------------------------
//
// A named-fan-in block declares `pub const inputs = .{ .name = ElemType, ... }`
// (a comptime struct-of-(name → element-type)). Each named input mints a typed
// `PortId` exposed as `node.in.<name>`, and the synthesized output struct's
// field order IS the canonical column order — wiring and column identity are
// the SAME declaration, so a transposed feature matrix is unrepresentable.

/// Read the element type declared for named input `name`.
fn NamedInputElem(comptime Block: type, comptime name: []const u8) type {
    if (!@hasDecl(Block, "inputs"))
        @compileError("pan: " ++ @typeName(Block) ++ " declares no named inputs");
    const spec = Block.inputs;
    if (!@hasField(@TypeOf(spec), name))
        @compileError("pan: " ++ @typeName(Block) ++ " has no named input '" ++ name ++ "'");
    return @field(spec, name);
}

/// Mint the typed input `PortId` for `node.in.<name>` on a named-fan-in block.
pub fn NamedInPort(comptime Block: type, comptime name: []const u8) type {
    return PortId(Block, .in, NamedInputElem(Block, name));
}

/// Synthesize the output struct of a `Concat`/named-fan-in `spec` (a
/// struct-of-(name → element-type)): one field per named input, in declaration
/// order — the canonical feature-matrix column order.
pub fn ConcatOut(comptime spec: anytype) type {
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;
    comptime var names: [fields.len][:0]const u8 = undefined;
    comptime var elem_types: [fields.len]type = undefined;
    comptime var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (fields, 0..) |f, i| {
        names[i] = f.name;
        elem_types[i] = @field(spec, f.name);
        attrs[i] = .{};
    }
    const final_names = names;
    const final_types = elem_types;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

/// The control element type declared for parameter slot `name` in a block's
/// `pub const params = .{ .name = ControlElem, ... }`. A wrong name is a
/// compile error naming the slot.
fn ParamElem(comptime Block: type, comptime name: []const u8) type {
    if (!@hasDecl(Block, "params"))
        @compileError("pan: " ++ @typeName(Block) ++ " declares no parameter ports");
    const params = Block.params;
    if (!@hasField(@TypeOf(params), name))
        @compileError("pan: " ++ @typeName(Block) ++ " has no parameter port '" ++ name ++ "'");
    return @field(params, name);
}

/// Mint the typed parameter `PortId` for `node.param.<name>` — the in-graph
/// modulation handle. `connect` type-checks a driver's output against it, so a
/// wrong control element type is a compile error naming the slot.
pub fn ParamPort(comptime Block: type, comptime name: []const u8) type {
    return ParamPortId(Block, ParamElem(Block, name));
}

test "classify: a process-only block is a Map" {
    const Gain = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    try std.testing.expect(classify(Gain) == .Map);
    try std.testing.expect(MapInPort(Gain).Elem == types.Sample(f32));
    try std.testing.expect(MapOutPort(Gain).direction == .out);
    try std.testing.expect(comptime isPortId(MapInPort(Gain)));
}

test "classify: a complete Rate is Rate; a VariRate is VariRate" {
    const Decim = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 2 };
        pub const algorithmic_latency: usize = 3;
        pub fn pull(self: *Self, want: usize, out: []types.Sample(f32)) usize {
            _ = self;
            _ = out;
            return want;
        }
    };
    try std.testing.expect(classify(Decim) == .Rate);

    const Asrc = struct {
        const Self = @This();
        pub const rate_bounds = .{ .min = .{ 1, 2 }, .nominal = .{ 1, 1 }, .max = .{ 2, 1 } };
        pub const max_latency: usize = 2048;
        pub fn pull(self: *Self, want: usize, out: []types.Sample(f32)) usize {
            _ = self;
            _ = out;
            return want;
        }
    };
    try std.testing.expect(classify(Asrc) == .VariRate);
    try std.testing.expect(RateOutElem(Asrc) == types.Sample(f32));
}

test "Rate ports: source pull(want,out) vs mid-graph pull(in,want,out)" {
    // A zero-input Rate SOURCE: out read despite no input; classified a Source.
    const StreamSrc = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 1 };
        pub const algorithmic_latency: usize = 0;
        pub fn pull(self: *Self, want: usize, out: []types.Sample(f32)) usize {
            _ = self;
            _ = out;
            return want;
        }
    };
    try std.testing.expect(classify(StreamSrc) == .Rate);
    try std.testing.expect(comptime isSource(StreamSrc));
    try std.testing.expectEqual(@as(comptime_int, 0), rateInputCount(StreamSrc));
    try std.testing.expect(RateOutElem(StreamSrc) == types.Sample(f32));

    // A mid-graph Rate transducer: one const input port + the want demand + out.
    const Resamp = struct {
        const Self = @This();
        pub const out_per_in = .{ 2, 1 };
        pub const algorithmic_latency: usize = 4;
        pub fn pull(self: *Self, in: []const types.Sample(f32), want: usize, out: []types.Sample(f32)) usize {
            _ = self;
            _ = in;
            _ = out;
            return want;
        }
    };
    try std.testing.expect(classify(Resamp) == .Rate);
    try std.testing.expect(!comptime isSource(Resamp));
    try std.testing.expectEqual(@as(comptime_int, 1), rateInputCount(Resamp));
    try std.testing.expect(RateInElem(Resamp) == types.Sample(f32));
    try std.testing.expect(RateOutElem(Resamp) == types.Sample(f32));
    try std.testing.expect(RateInPort(Resamp).direction == .in);
    try std.testing.expect(RateOutPort(Resamp).direction == .out);
}

test "isSource: a zero-sample-input generator Map is a Source" {
    const Osc = struct {
        const Self = @This();
        phase: f32 = 0,
        pub const params = .{ .freq = types.Scalar(f32) };
        pub fn process(self: *Self, out: []types.Sample(f32)) void {
            _ = self;
            _ = out;
        }
    };
    try std.testing.expect(classify(Osc) == .Map);
    try std.testing.expect(comptime isSource(Osc));
    try std.testing.expect(MapOutElem(Osc) == types.Sample(f32)); // out read despite no input
}

test "parameter port minting: node.param.<name> is a typed param PortId" {
    const Biquad = struct {
        const Self = @This();
        pub const params = .{ .cutoff = types.Scalar(f32), .q = types.Scalar(f32) };
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const Cutoff = ParamPort(Biquad, "cutoff");
    try std.testing.expect(Cutoff.Elem == types.Scalar(f32));
    try std.testing.expect(Cutoff.direction == .in);
    try std.testing.expect(comptime isParamPort(Cutoff));
    try std.testing.expect(comptime isPortId(Cutoff));
    // A sample port is not a param port.
    try std.testing.expect(!comptime isParamPort(MapInPort(Biquad)));
}

test "PortId carries node identity: same signature, different node => distinct type" {
    const A = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const B = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    try std.testing.expect(MapInPort(A) != MapInPort(B));
    try std.testing.expect(MapInPort(A).Elem == MapInPort(B).Elem);
}

test "checkPortCeiling accepts up to 8 ports per direction" {
    inline for (1..max_ports_per_direction + 1) |n| {
        checkPortCeiling(n, .in);
        checkPortCeiling(n, .out);
    }
    try std.testing.expectEqual(@as(comptime_int, 8), max_ports_per_direction);
}

test "indexed inputs: node.in(i) reads the i-th input port element" {
    const Sum2 = struct {
        const Self = @This();
        pub fn process(self: *Self, in0: []const types.Sample(f32), in1: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            for (in0, in1, out) |a, b, *o| o.ch[0] = a.ch[0] + b.ch[0];
        }
    };
    try std.testing.expectEqual(@as(comptime_int, 2), mapInputCount(Sum2));
    try std.testing.expect(MapInPortAt(Sum2, 0).Elem == types.Sample(f32));
    try std.testing.expect(MapInPortAt(Sum2, 1).Elem == types.Sample(f32));
    // Same-element homogeneous inputs share one PortId TYPE; the runtime index
    // (the `.init(i)` field) disambiguates the two ports at the instance level.
    try std.testing.expect(MapInPortAt(Sum2, 0) == MapInPortAt(Sum2, 1));
    try std.testing.expectEqual(@as(PortIndex, 1), MapInPortAt(Sum2, 1).init(1).index);
}

test "named-input minting: NamedInPort + ConcatOut from a spec" {
    const spec = .{
        .mfcc = types.FeatureFrame(13),
        .centroid = types.Scalar(f32),
        .rms = types.Scalar(f32),
    };
    const Collect = struct {
        const Self = @This();
        pub const inputs = spec;
        pub fn process(self: *Self) void {
            _ = self;
        }
    };
    try std.testing.expect(NamedInPort(Collect, "mfcc").Elem == types.FeatureFrame(13));
    try std.testing.expect(NamedInPort(Collect, "centroid").Elem == types.Scalar(f32));
    try std.testing.expect(NamedInPort(Collect, "centroid").direction == .in);

    // The output struct mirrors the spec, field order = column order.
    const Out = ConcatOut(spec);
    const out_fields = @typeInfo(Out).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 3), out_fields.len);
    try std.testing.expectEqualStrings("mfcc", out_fields[0].name);
    try std.testing.expectEqualStrings("centroid", out_fields[1].name);
    try std.testing.expectEqualStrings("rms", out_fields[2].name);
    try std.testing.expect(out_fields[0].type == types.FeatureFrame(13));
}

// DISABLED @compileError stubs (cannot run — they abort compilation):
//   - A bare-array port element:
//       pub fn process(_: *@This(), _: []const [4]f32, _: []f32) void {}
//     => "a port element may not be a bare array [4]f32 — wrap it in a named struct"
//   - NamedInPort(Collect, "nope") => "has no named input 'nope'"
//   - MapInPortAt(Sum2, 2) => "has no input port 2 (it declares 2)"
