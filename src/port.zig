//! Comptime port machinery (type-model §1, exec §8, catalog §3.2).
//!
//! Reads a block's `process`/`pull` fn params via `@typeInfo`:
//!   - `.pointer.child`    = the port element type `A`
//!   - `.pointer.is_const` = input (const slice) vs output (mutable slice)
//! Mints a typed `PortId(Node, dir, Elem)` carrying node identity + direction
//! + element type. The 8-port-per-direction ceiling is enforced via a `u3`
//! index type. A comptime classifier labels a block `Map` vs `Rate` by the
//! presence of `out_per_in`/`pull`.

const std = @import("std");

/// Port direction. A `process`/`pull` param that is a `[]const A` slice is an
/// input; a `[]A` slice is an output (exec §8: `.pointer.is_const`).
pub const Direction = enum { in, out };

/// The 8-port-per-direction ceiling (catalog §3.2 / A2). The port index is a
/// `u3` (values 0..7). Indexing past 7 is rejected at comptime via the
/// `checkPortCeiling` helper below; `u3` is also the on-the-wire index type.
pub const PortIndex = u3;
pub const max_ports_per_direction: comptime_int = std.math.maxInt(PortIndex) + 1; // 8

/// Enforce the 8-port ceiling as a comptime `@compileError` (catalog §3.2, ⊢).
/// Called when minting port lists from a signature.
pub fn checkPortCeiling(comptime n: comptime_int, comptime dir: Direction) void {
    if (n > max_ports_per_direction) {
        @compileError(std.fmt.comptimePrint(
            "pan: {d} {s} ports exceeds the 8-port-per-direction ceiling (catalog §3.2)",
            .{ n, @tagName(dir) },
        ));
    }
}

/// A typed `PortId` — the connect-checking handle (type-model §1, catalog §3.2).
/// Carries node identity (`Node` type + comptime index), direction, and element
/// type. Because `Elem` rides in the type, `connect` (graph.zig) type-checks
/// both ends and emits a named `@compileError` on a mismatch.
pub fn PortId(comptime NodeT: type, comptime dir: Direction, comptime ElemT: type) type {
    return struct {
        /// Index of this port within its direction on the node (0..7).
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

/// Is `T` a `PortId(...)`? Structural check used by `connect`. Written as a
/// comptime tag switch: a bare `@typeInfo(T) == .@"struct"` union-to-tag
/// compare degrades to a runtime value here (it does not constant-fold inside
/// the `and` chain on 0.16.0), so we switch on the tag instead.
pub fn isPortId(comptime T: type) bool {
    // NOTE (0.16.0): an `and`-chain of comptime `@hasDecl` results inside a
    // plain `fn ... bool` body lowers to a RUNTIME value (it does not
    // constant-fold), so callers that need a comptime answer must wrap the call
    // in `comptime`. We additionally guard with a `comptime` block here so the
    // returned value is comptime-known whenever the function is itself called
    // in a comptime context.
    comptime {
        if (@typeInfo(T) != .@"struct") return false;
        if (!@hasDecl(T, "Node")) return false;
        if (!@hasDecl(T, "direction")) return false;
        if (!@hasDecl(T, "Elem")) return false;
        return true;
    }
}

/// Extract the element type and direction of one slice param of a
/// `process`/`pull` fn. Asserts the param is a slice (`[]A` / `[]const A`);
/// `self: *Self` (the first param) is handled by the caller, not here.
fn portOfParam(comptime ParamT: type) struct { Elem: type, dir: Direction } {
    const info = @typeInfo(ParamT);
    if (info != .pointer or info.pointer.size != .slice) {
        @compileError("pan: port param must be a slice []A or []const A, got " ++
            @typeName(ParamT));
    }
    return .{
        .Elem = info.pointer.child,
        .dir = if (info.pointer.is_const) .in else .out,
    };
}

/// The two morphism classes (catalog §2). Discriminated ⊢ at comptime by
/// presence of `out_per_in`/`pull`.
pub const BlockClass = enum { Map, Rate };

/// Classify a block type as `Map` or `Rate` (catalog §2, exec §2; ⊢ A3).
/// A `Rate` declares `out_per_in` and `pull` (and `algorithmic_latency`); a
/// `Map` declares neither — it has a `process`. Field/decl presence is
/// structurally checkable, so this is decidable at comptime.
pub fn classify(comptime Block: type) BlockClass {
    const has_pull = @hasDecl(Block, "pull");
    const has_ratio = @hasDecl(Block, "out_per_in");
    if (has_pull or has_ratio) {
        // R1 (catalog §2.2): a Rate missing either declaration is a build error.
        if (!has_pull)
            @compileError("pan: " ++ @typeName(Block) ++
                " declares out_per_in but no pull — Rate contract incomplete (R1)");
        if (!has_ratio)
            @compileError("pan: " ++ @typeName(Block) ++
                " declares pull but no out_per_in — Rate contract incomplete (R1)");
        if (!@hasDecl(Block, "algorithmic_latency"))
            @compileError("pan: " ++ @typeName(Block) ++
                " is a Rate but declares no algorithmic_latency (R1, catalog §2.2)");
        return .Rate;
    }
    if (!@hasDecl(Block, "process"))
        @compileError("pan: " ++ @typeName(Block) ++
            " is neither Map (process) nor Rate (out_per_in+pull)");
    return .Map;
}

/// The element type carried by a `Map`'s input port (param 1 of `process`),
/// derived from the signature via `@typeInfo` (type-model §1).
pub fn MapInElem(comptime Block: type) type {
    const f = @typeInfo(@TypeOf(Block.process)).@"fn";
    // params: (self: *Self, in: []const In, out: []Out)
    const p = portOfParam(f.params[1].type.?);
    std.debug.assert(p.dir == .in);
    return p.Elem;
}

/// The element type carried by a `Map`'s output port (param 2 of `process`).
pub fn MapOutElem(comptime Block: type) type {
    const f = @typeInfo(@TypeOf(Block.process)).@"fn";
    const p = portOfParam(f.params[2].type.?);
    std.debug.assert(p.dir == .out);
    return p.Elem;
}

/// Mint the input `PortId` type for a `Map` block, reading its `process`
/// signature (type-model §1: the same handle `connect` type-checks).
pub fn MapInPort(comptime Block: type) type {
    checkPortCeiling(1, .in);
    return PortId(Block, .in, MapInElem(Block));
}

/// Mint the output `PortId` type for a `Map` block.
pub fn MapOutPort(comptime Block: type) type {
    checkPortCeiling(1, .out);
    return PortId(Block, .out, MapOutElem(Block));
}

test "classifier labels a Map block (catalog §2, ⊢ A3)" {
    const types = @import("types.zig");
    const Gain = struct {
        const Self = @This();
        gain: f32 = 1.0,
        // rate-1:1, element-preserving Map (empty stub kernel: copy).
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    try std.testing.expect(classify(Gain) == .Map);
    // PortId minting reads the signature: element type is Sample(f32).
    const InPort = MapInPort(Gain);
    const OutPort = MapOutPort(Gain);
    try std.testing.expect(InPort.Elem == types.Sample(f32));
    try std.testing.expect(OutPort.Elem == types.Sample(f32));
    try std.testing.expect(InPort.direction == .in);
    try std.testing.expect(OutPort.direction == .out);
    try std.testing.expect(comptime isPortId(InPort));
}

test "classifier labels a Rate block; channel-changing Map sees C-difference" {
    const types = @import("types.zig");
    // A Framer-shaped Rate stub (declarations present; pull body is a stub).
    const Framer = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 64 }; // 1 frame per 64 input samples (Ratio stub)
        pub const algorithmic_latency: usize = 0;
        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return want * 64;
        }
        pub fn pull(self: *Self, want: usize, out: []types.FeatureFrame(64)) usize {
            _ = self;
            _ = out;
            return want;
        }
    };
    try std.testing.expect(classify(Framer) == .Rate);

    // A channel-changing Map: in Frame(.,1), out Frame(.,2) — differ in C only.
    const Upmix = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Frame(f32, 1), out: []types.Frame(f32, 2)) void {
            _ = self;
            for (in, out) |s, *d| d.* = .{ .ch = .{ s.ch[0], s.ch[0] } };
        }
    };
    try std.testing.expect(classify(Upmix) == .Map);
    try std.testing.expect(MapInElem(Upmix) == types.Frame(f32, 1));
    try std.testing.expect(MapOutElem(Upmix) == types.Frame(f32, 2));
    // The element types differ => connect across a C-mismatch is a type error.
    try std.testing.expect(MapInElem(Upmix) != MapOutElem(Upmix));
}

// === Yoneda coverage additions =========================================
// The port machinery is observed by the graph through: the signature reader
// (portOfParam) deriving Elem+direction from `[]const A`/`[]A`; the typed
// PortId carrying (Node, direction, Elem); the structural isPortId predicate
// connect() guards on; the u3 ceiling; and the Map/Rate classifier. We pin
// each, including the corner cases of the classifier and the const/elem
// derivation, plus DOCUMENTED expected-@compileError cases (negative comptime
// tests cannot run; see the commented stubs — they must stay disabled to keep
// the build green per the testing contract §7 note).

const test_types = @import("types.zig");

test "port direction is derived purely from slice constness ([]const A => in)" {
    // The single bit `is_const` decides direction (exec §8). A block whose
    // input/output lanes are the SAME element type still gets distinct
    // directions purely from constness — proving direction is NOT inferred
    // from element type or param position alone.
    const Id = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const test_types.Sample(f32), out: []test_types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const In = MapInPort(Id);
    const Out = MapOutPort(Id);
    try std.testing.expect(In.direction == .in);
    try std.testing.expect(Out.direction == .out);
    // Same element type, opposite directions => the PortId TYPES still differ.
    try std.testing.expect(In.Elem == Out.Elem);
    try std.testing.expect(In != Out);
}

test "PortId carries node identity, direction, and Elem as the connect handle" {
    const Blk = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const test_types.Frame(f32, 2), out: []test_types.Frame(f32, 2)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const In = MapInPort(Blk);
    try std.testing.expect(In.Node == Blk);
    try std.testing.expect(In.direction == .in);
    try std.testing.expect(In.Elem == test_types.Frame(f32, 2));
    // The runtime index field is a u3 carrying the port slot (0..7).
    const p = In.init(5);
    try std.testing.expectEqual(@as(PortIndex, 5), p.index);
    try std.testing.expect(@TypeOf(p.index) == u3);
}

test "PortId types for different nodes are distinct even with identical Elem/dir" {
    // Node identity rides in the TYPE: two blocks with the same signature mint
    // DIFFERENT PortId types, so connect cannot confuse one node for another.
    const A = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const test_types.Sample(f32), out: []test_types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const B = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const test_types.Sample(f32), out: []test_types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    try std.testing.expect(MapInPort(A) != MapInPort(B));
    try std.testing.expect(MapInPort(A).Node != MapInPort(B).Node);
    try std.testing.expect(MapInPort(A).Elem == MapInPort(B).Elem); // same Elem
}

test "isPortId: positive on a minted PortId, negative on non-PortId types" {
    const Blk = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const test_types.Sample(f32), out: []test_types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    try std.testing.expect(comptime isPortId(MapInPort(Blk)));
    try std.testing.expect(comptime isPortId(MapOutPort(Blk)));
    // Non-PortId types are rejected: a primitive, a slice, the element struct
    // itself, and a struct missing the Node/direction/Elem decls.
    try std.testing.expect(!comptime isPortId(u32));
    try std.testing.expect(!comptime isPortId([]const f32));
    try std.testing.expect(!comptime isPortId(test_types.Sample(f32)));
    const Faux = struct {
        pub const Node = u8; // has Node but not direction/Elem
    };
    try std.testing.expect(!comptime isPortId(Faux));
}

test "checkPortCeiling accepts up to 8 ports per direction (boundary, catalog §3.2)" {
    // The ceiling is INCLUSIVE of 8 (u3 indexes 0..7 = 8 slots). 1..8 must all
    // be accepted at comptime; 9 is the @compileError documented below.
    inline for (1..max_ports_per_direction + 1) |n| {
        checkPortCeiling(n, .in); // compiles => accepted
        checkPortCeiling(n, .out);
    }
    try std.testing.expectEqual(@as(comptime_int, 8), max_ports_per_direction);
    try std.testing.expectEqual(@as(comptime_int, 8), std.math.maxInt(PortIndex) + 1);
}

// EXPECTED-@compileError (catalog §3.2, ⊢ A2): the 9th port per direction.
// A @compileError cannot be caught by a runtime test (it aborts compilation),
// so per the testing contract §7 note this case is pinned as a DISABLED stub.
// Un-commenting it MUST fail the build with the named ceiling diagnostic
// "9 in ports exceeds the 8-port-per-direction ceiling (catalog §3.2)".
//
//   test "EXPECTED COMPILE ERROR: 9th port exceeds the u3 ceiling" {
//       checkPortCeiling(9, .in); // => @compileError, build goes red (loud)
//   }

test "classify: a process-only block is a Map; bare process has no Rate decls" {
    const M = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const test_types.Sample(f32), out: []test_types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    try std.testing.expect(classify(M) == .Map);
}

test "classify: a complete Rate (out_per_in + pull + algorithmic_latency) is Rate" {
    // A Rate is recognized by the PRESENCE of out_per_in/pull, independent of
    // whether it also has a `process` — the classifier short-circuits on the
    // Rate decls. We give it no `process` to prove `process` is not required.
    const R = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 2 };
        pub const algorithmic_latency: usize = 3;
        pub fn pull(self: *Self, want: usize, out: []test_types.Sample(f32)) usize {
            _ = self;
            _ = out;
            return want;
        }
    };
    try std.testing.expect(classify(R) == .Rate);
}

// EXPECTED-@compileError corner cases of the classifier (catalog §2.2 R1).
// Each is an INCOMPLETE Rate contract that classify() rejects by name; they
// cannot run (they abort compilation) so they are pinned as disabled stubs.
// Un-commenting any one MUST fail the build with the quoted R1 diagnostic.
//
//   test "EXPECTED COMPILE ERROR: out_per_in without pull (R1 incomplete)" {
//       const Bad = struct {
//           pub const out_per_in = .{ 1, 2 };
//           pub fn process(_: *@This(), _: []const f32, _: []f32) void {}
//       };
//       _ = classify(Bad); // => "declares out_per_in but no pull"
//   }
//   test "EXPECTED COMPILE ERROR: pull without out_per_in (R1 incomplete)" {
//       const Bad = struct {
//           pub fn pull(_: *@This(), w: usize, _: []f32) usize { return w; }
//       };
//       _ = classify(Bad); // => "declares pull but no out_per_in"
//   }
//   test "EXPECTED COMPILE ERROR: Rate without algorithmic_latency (R1)" {
//       const Bad = struct {
//           pub const out_per_in = .{ 1, 2 };
//           pub fn pull(_: *@This(), w: usize, _: []f32) usize { return w; }
//       };
//       _ = classify(Bad); // => "is a Rate but declares no algorithmic_latency"
//   }
//   test "EXPECTED COMPILE ERROR: neither Map nor Rate" {
//       const Bad = struct { x: u8 = 0 };
//       _ = classify(Bad); // => "is neither Map (process) nor Rate"
//   }

test "MapInElem/MapOutElem read the exact element type off the signature" {
    // The reader must thread the Frame's lane AND channel count through, not
    // just the family — a downmix block sees C go 4 -> 1.
    const Downmix = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const test_types.Frame(i16, 4), out: []test_types.Frame(i16, 1)) void {
            _ = self;
            for (in, out) |s, *d| d.* = .{ .ch = .{s.ch[0]} };
        }
    };
    try std.testing.expect(MapInElem(Downmix) == test_types.Frame(i16, 4));
    try std.testing.expect(MapOutElem(Downmix) == test_types.Frame(i16, 1));
    // Sample/Frame identity is preserved through the reader: a Sample(f32) out
    // reads back as Frame(f32,1).
    const Mono = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const test_types.Sample(f32), out: []test_types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    try std.testing.expect(MapOutElem(Mono) == test_types.Frame(f32, 1));
}
