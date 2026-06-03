//! Yoneda characterization of the comptime PORT machinery (`src/port.zig`).
//!
//! "Tests as definition" (project Rule 14): each construct is pinned by ALL the
//! observable morphisms the graph/commit pass applies to it — the classifier
//! truth table, source detection, PortId/ParamPortId identity and decls, the
//! parameter-port mint, the Rate output-element reader, and the 8-port ceiling.
//! The decidable-static laws (⊢) are the oracles; the tests fail loudly if any
//! is broken. @compileError cases live as DISABLED commented stubs at the end
//! (they abort compilation and so cannot run as live tests).
//!
//! Catalog section citations in test names point at the morphism-class catalog
//! (Map §2.4, Rate §2.5, VariRate §2.6, Source §2.7, ports §3).
//!
//! Targets Zig 0.16.0 exactly.

const std = @import("std");
// Imports go through the `pan` library module (wired in build.zig), which
// re-exports `port` and `types` — Zig 0.16 forbids a harness module from
// `@import`-ing a `../src` path that escapes its own root directory.
const pan = @import("pan");
const port = pan.port;
const types = pan.types;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// ===========================================================================
// Stub blocks — minimal shapes that exercise exactly one classifier branch.
// Each is the smallest signature satisfying the field-presence contract.
// ===========================================================================

/// Ordinary in→out Map: `process(self, in, out)`. Not a source.
const MapGain = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// Generator Map: `process(self, out)` — ZERO sample-input ports ⇒ a Source.
const MapOsc = struct {
    const Self = @This();
    phase: f32 = 0,
    pub const params = .{ .freq = types.Scalar(f32) };
    pub fn process(self: *Self, out: []types.Sample(f32)) void {
        _ = self;
        _ = out;
    }
};

/// A Map whose input/output elements differ (a lane/family-changing block):
/// reads `Sample(f32)`, writes `Complex(f32)`. Pins that MapInElem and
/// MapOutElem read DIFFERENT params, not the same one twice.
const MapFft = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Complex(f32)) void {
        _ = self;
        _ = in;
        _ = out;
    }
};

/// A second ordinary Map with the IDENTICAL signature to MapGain — used to pin
/// node identity (distinct node type ⇒ distinct PortId type).
const MapGainTwin = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// Complete Rate: `out_per_in` + `pull` + `algorithmic_latency`.
const RateDecim = struct {
    const Self = @This();
    pub const out_per_in = .{ 1, 2 };
    pub const algorithmic_latency: usize = 3;
    pub fn pull(self: *Self, want: usize, out: []types.Sample(f32)) usize {
        _ = self;
        _ = out;
        return want;
    }
};

/// Complete VariRate: `rate_bounds` + `max_latency` + `pull`.
const VariResample = struct {
    const Self = @This();
    pub const rate_bounds = .{ .min = .{ 1, 2 }, .nominal = .{ 1, 1 }, .max = .{ 2, 1 } };
    pub const max_latency: usize = 2048;
    pub fn pull(self: *Self, want: usize, out: []types.Sample(f32)) usize {
        _ = self;
        _ = out;
        return want;
    }
};

/// A Rate whose `pull` output element is NOT Sample(f32) — pins RateOutElem
/// reads the actual declared element, not a hardcoded one.
const RateFeature = struct {
    const Self = @This();
    pub const out_per_in = .{ 1, 4 };
    pub const algorithmic_latency: usize = 0;
    pub fn pull(self: *Self, want: usize, out: []types.FeatureFrame(13)) usize {
        _ = self;
        _ = out;
        return want;
    }
};

/// A Map carrying several parameter ports of distinct control elements.
const ParamBiquad = struct {
    const Self = @This();
    pub const params = .{
        .cutoff = types.Scalar(f32),
        .q = types.Scalar(f32),
        .gain = types.Scalar(f64),
    };
    pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// Non-PortId stub used to pin `isPortId` negatives: a struct that *looks*
/// structural but is missing the required decls.
const NotAPort = struct {
    index: port.PortIndex,
    pub fn init(i: port.PortIndex) @This() {
        return .{ .index = i };
    }
};

// ===========================================================================
// CLASSIFIER TRUTH TABLE (catalog §2.4–2.6, ⊢ decidable-static)
//   process only                              ⇒ .Map
//   out_per_in + pull + algorithmic_latency   ⇒ .Rate
//   rate_bounds + max_latency + pull          ⇒ .VariRate
// ===========================================================================

test "classifier: process-only ⇒ Map (catalog §2.4, ⊢)" {
    try expect(port.classify(MapGain) == .Map);
    try expect(port.classify(MapOsc) == .Map);
    try expect(port.classify(MapFft) == .Map);
}

test "classifier: out_per_in + pull + algorithmic_latency ⇒ Rate (catalog §2.5, ⊢)" {
    try expect(port.classify(RateDecim) == .Rate);
    try expect(port.classify(RateFeature) == .Rate);
}

test "classifier: rate_bounds + max_latency + pull ⇒ VariRate (catalog §2.6, ⊢)" {
    try expect(port.classify(VariResample) == .VariRate);
}

test "classifier: BlockClass enumerates exactly Map, Rate, VariRate (⊢)" {
    // The discrimination space is closed: no fourth class. (Source is a Map/Rate
    // predicate, not a class — pinned separately below.)
    const fields = @typeInfo(port.BlockClass).@"enum".fields;
    try expectEqual(@as(usize, 3), fields.len);
    try expect(port.classify(MapGain) == port.BlockClass.Map);
    try expect(port.classify(RateDecim) == port.BlockClass.Rate);
    try expect(port.classify(VariResample) == port.BlockClass.VariRate);
}

test "classifier: rate_bounds dominates pull/out_per_in (VariRate is checked first) (⊢)" {
    // VariResample has `pull` (a Rate signal) but classifies VariRate because
    // rate_bounds is present — the branch order is part of the contract.
    try expect(port.classify(VariResample) == .VariRate);
}

// ===========================================================================
// SOURCE DETECTION (catalog §2.7, ⊢)
//   Map  with ZERO sample-input ports ⇒ isSource == true
//   ordinary in→out Map               ⇒ isSource == false
//   Rate with ZERO sample-input ports ⇒ isSource == true  (a stream source, SR2:
//        `pull(self, want, out)` reads a backing store, not an upstream edge)
//   Rate with a sample-input port     ⇒ isSource == false (a mid-graph transducer)
// ===========================================================================

test "source: zero-sample-input generator Map is a Source (catalog §2.7, ⊢)" {
    try expect(comptime port.isSource(MapOsc));
}

test "source: an ordinary in→out Map is not a Source (catalog §2.7, ⊢)" {
    try expect(!comptime port.isSource(MapGain));
    try expect(!comptime port.isSource(MapFft));
}

test "source: a zero-input Rate is a stream Source; a Rate with an input port is not (SR2, ⊢)" {
    // SR2: a stream/sample source IS a Rate whose `pull(self, want, out)` has zero
    // sample-input ports (it reads a backing store) — structurally a source, just
    // as a generator Map with zero input slices is. These abstract blocks declare
    // exactly that shape.
    try expect(comptime port.isSource(RateDecim));
    try expect(comptime port.isSource(VariResample));
    try expect(comptime port.isSource(RateFeature));
    // A mid-graph Rate transducer (`pull(self, in, want, out)`) has an input port,
    // so it is NOT a source.
    const RateThru = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, 2 };
        pub const algorithmic_latency: usize = 0;
        pub fn pull(self: *Self, in: []const types.Sample(f32), want: usize, out: []types.Sample(f32)) usize {
            _ = self;
            _ = in;
            _ = out;
            return want;
        }
    };
    try expect(!comptime port.isSource(RateThru));
}

test "source: MapOutElem still reads the output of a source despite no input (⊢)" {
    // The Yoneda point: a source has no input port, yet its output element is
    // still observable through MapOutElem / MapOutPort.
    try expect(port.MapOutElem(MapOsc) == types.Sample(f32));
    try expect(port.MapOutPort(MapOsc).Elem == types.Sample(f32));
    try expect(port.MapOutPort(MapOsc).direction == .out);
}

// ===========================================================================
// MAP ELEMENT READERS (catalog §3, ⊢)
//   MapInElem  ← first []const A param after self
//   MapOutElem ← first []A param after self
// ===========================================================================

test "map elements: in/out elements read off the process signature (catalog §3, ⊢)" {
    try expect(port.MapInElem(MapGain) == types.Sample(f32));
    try expect(port.MapOutElem(MapGain) == types.Sample(f32));
}

test "map elements: in and out elements may differ (lane/family-changing Map) (⊢)" {
    try expect(port.MapInElem(MapFft) == types.Sample(f32));
    try expect(port.MapOutElem(MapFft) == types.Complex(f32));
    try expect(port.MapInElem(MapFft) != port.MapOutElem(MapFft));
}

// ===========================================================================
// RATE OUTPUT ELEMENT (catalog §3, ⊢)
//   RateOutElem ← child of `pull(self, want, out: []Out)` param index 2
// ===========================================================================

test "rate element: RateOutElem reads pull's output element (catalog §3, ⊢)" {
    try expect(port.RateOutElem(RateDecim) == types.Sample(f32));
    try expect(port.RateOutElem(VariResample) == types.Sample(f32));
}

test "rate element: RateOutElem reads the actual declared element, not a default (⊢)" {
    try expect(port.RateOutElem(RateFeature) == types.FeatureFrame(13));
    try expect(port.RateOutElem(RateFeature) != types.Sample(f32));
}

// ===========================================================================
// PortId IDENTITY (catalog §3, ⊢ type-identity / exact)
//   carries Node, direction, Elem; node identity rides in the type;
//   direction derived purely from slice constness.
// ===========================================================================

test "portid: a minted PortId carries Node, direction, Elem decls (catalog §3, ⊢)" {
    const In = port.MapInPort(MapGain);
    try expect(In.Node == MapGain);
    try expect(In.direction == .in);
    try expect(In.Elem == types.Sample(f32));

    const Out = port.MapOutPort(MapGain);
    try expect(Out.Node == MapGain);
    try expect(Out.direction == .out);
    try expect(Out.Elem == types.Sample(f32));
}

test "portid: node identity rides in the type — twin signatures mint distinct ports (⊢)" {
    // MapGain and MapGainTwin have byte-identical process signatures.
    try expect(port.MapInPort(MapGain) != port.MapInPort(MapGainTwin));
    try expect(port.MapOutPort(MapGain) != port.MapOutPort(MapGainTwin));
    // ...yet their element types coincide (the distinction is node, not Elem).
    try expect(port.MapInPort(MapGain).Elem == port.MapInPort(MapGainTwin).Elem);
}

test "portid: direction derives from slice constness — same Elem, distinct in/out types (⊢)" {
    // []const A ⇒ .in, []A ⇒ .out. Same node, same Elem, opposite direction ⇒
    // distinct PortId types.
    const In = port.MapInPort(MapGain);
    const Out = port.MapOutPort(MapGain);
    try expect(In != Out);
    try expect(In.Elem == Out.Elem); // same element
    try expect(In.direction != Out.direction); // distinct direction
    try expect(In.Node == Out.Node); // same node
}

test "portid: PortId(N,d,E) is deterministic — identical args give the identical type (⊢)" {
    // The compiler caches monomorphizations: PortId(N,d,E) == PortId(N,d,E).
    try expect(port.PortId(MapGain, .in, types.Sample(f32)) ==
        port.PortId(MapGain, .in, types.Sample(f32)));
    try expect(port.PortId(MapGain, .in, types.Sample(f32)) == port.MapInPort(MapGain));
}

test "portid: varying ANY of (Node, direction, Elem) yields a distinct type (⊢)" {
    const base = port.PortId(MapGain, .in, types.Sample(f32));
    try expect(base != port.PortId(MapGainTwin, .in, types.Sample(f32))); // node varies
    try expect(base != port.PortId(MapGain, .out, types.Sample(f32))); // direction varies
    try expect(base != port.PortId(MapGain, .in, types.Scalar(f32))); // elem varies
}

test "portid: init stores the index; PortIndex is u3 (catalog §3, ⊢)" {
    const In = port.MapInPort(MapGain);
    const p = In.init(5);
    try expectEqual(@as(port.PortIndex, 5), p.index);
    try expect(port.PortIndex == u3);
}

// ===========================================================================
// isPortId / isParamPort STRUCTURAL TESTS (catalog §3, ⊢)
// ===========================================================================

test "isPortId: true on a minted sample PortId (catalog §3, ⊢)" {
    try expect(comptime port.isPortId(port.MapInPort(MapGain)));
    try expect(comptime port.isPortId(port.MapOutPort(MapGain)));
}

test "isPortId: true on a minted parameter PortId (catalog §3, ⊢)" {
    try expect(comptime port.isPortId(port.ParamPort(ParamBiquad, "cutoff")));
}

test "isPortId: false on a primitive, a slice, and an element struct (⊢)" {
    try expect(!comptime port.isPortId(u32)); // primitive (not a struct)
    try expect(!comptime port.isPortId([]const types.Sample(f32))); // a slice
    try expect(!comptime port.isPortId(types.Sample(f32))); // the element struct itself
    try expect(!comptime port.isPortId(port.Direction)); // an enum
}

test "isPortId: false on a struct missing the Node/direction/Elem decls (⊢)" {
    // NotAPort is a struct with an `index` field and an `init`, but none of the
    // three required decls — the structural check must reject it.
    try expect(!comptime port.isPortId(NotAPort));
}

test "isParamPort: true only on a port carrying the is_param marker (catalog §3, ⊢)" {
    const Cutoff = port.ParamPort(ParamBiquad, "cutoff");
    try expect(comptime port.isParamPort(Cutoff));
    // A sample PortId lacks is_param.
    try expect(!comptime port.isParamPort(port.MapInPort(MapGain)));
    try expect(!comptime port.isParamPort(port.MapOutPort(MapGain)));
}

test "isParamPort: false on a non-PortId type (⊢)" {
    try expect(!comptime port.isParamPort(u32));
    try expect(!comptime port.isParamPort(types.Scalar(f32)));
    try expect(!comptime port.isParamPort(NotAPort));
}

// ===========================================================================
// PARAMETER PORTS (catalog §3, ⊢)
//   ParamPort(Block,"name") mints a typed param PortId from
//   `pub const params = .{ .name = ControlElem }`.
//   .Elem == declared control element, .direction == .in, isParamPort == true.
// ===========================================================================

test "param port: ParamPort mints a typed param PortId from params (catalog §3, ⊢)" {
    const Cutoff = port.ParamPort(ParamBiquad, "cutoff");
    try expect(Cutoff.Elem == types.Scalar(f32));
    try expect(Cutoff.direction == .in);
    try expect(Cutoff.Node == ParamBiquad);
    try expect(Cutoff.is_param == true);
    try expect(comptime port.isParamPort(Cutoff));
    try expect(comptime port.isPortId(Cutoff));
}

test "param port: distinct slots read their own declared control element (⊢)" {
    const Cutoff = port.ParamPort(ParamBiquad, "cutoff"); // Scalar(f32)
    const Gain = port.ParamPort(ParamBiquad, "gain"); // Scalar(f64)
    try expect(Cutoff.Elem == types.Scalar(f32));
    try expect(Gain.Elem == types.Scalar(f64));
    try expect(Cutoff.Elem != Gain.Elem);
    // Same control element but different slot names mint the SAME type
    // (ParamPortId keys on Node+Elem, not the slot name) — pin that fact.
    const Q = port.ParamPort(ParamBiquad, "q"); // Scalar(f32), same as cutoff
    try expect(Cutoff == Q);
}

test "param port: a source's params slot is reachable too (⊢)" {
    // MapOsc declares params = .{ .freq = Scalar(f32) } despite being a source.
    const Freq = port.ParamPort(MapOsc, "freq");
    try expect(Freq.Elem == types.Scalar(f32));
    try expect(Freq.direction == .in);
    try expect(comptime port.isParamPort(Freq));
}

test "param port: ParamPortId always points inward and carries is_param (⊢)" {
    // Direct mint via ParamPortId (bypassing the params lookup).
    const P = port.ParamPortId(ParamBiquad, types.Scalar(f32));
    try expect(P.direction == .in);
    try expect(P.is_param == true);
    try expect(P.Node == ParamBiquad);
    try expect(P.Elem == types.Scalar(f32));
}

// ===========================================================================
// 8-PORT CEILING (catalog §3, ⊢)
//   checkPortCeiling(n) accepts n = 1..8 (u3 indexes 0..7 = 8 slots);
//   max_ports_per_direction == 8.
// ===========================================================================

test "ceiling: max_ports_per_direction == 8 and tracks PortIndex (catalog §3, ⊢)" {
    try expectEqual(@as(comptime_int, 8), port.max_ports_per_direction);
    // The ceiling is exactly maxInt(PortIndex)+1, the u3 slot count.
    try expectEqual(@as(comptime_int, std.math.maxInt(port.PortIndex) + 1), port.max_ports_per_direction);
}

test "ceiling: checkPortCeiling accepts 1..8 inclusive in both directions (catalog §3, ⊢)" {
    inline for (1..port.max_ports_per_direction + 1) |n| {
        port.checkPortCeiling(n, .in);
        port.checkPortCeiling(n, .out);
    }
}

test "ceiling: the boundary value 8 is accepted (inclusive upper bound) (⊢)" {
    // Exactly 8 is legal; the @compileError fires only past 8 (see disabled
    // stub below). This pins the boundary is inclusive, not exclusive.
    port.checkPortCeiling(8, .in);
    port.checkPortCeiling(8, .out);
}

// ===========================================================================
// Direction enum surface (⊢)
// ===========================================================================

test "direction: enum is exactly { in, out } (⊢)" {
    const fields = @typeInfo(port.Direction).@"enum".fields;
    try expectEqual(@as(usize, 2), fields.len);
    try expect(@hasField(port.Direction, "in"));
    try expect(@hasField(port.Direction, "out"));
}

// ===========================================================================
// ===========================================================================
//  NEGATIVE / @compileError CASES — DISABLED STUBS
//
//  These cannot run as live tests: each aborts compilation. They are kept here
//  as commented specifications. Un-commenting EXACTLY ONE at a time and
//  building must produce the stated diagnostic. They define the failure
//  boundary of the machinery just as the positive tests define its success
//  boundary (Yoneda: the morphisms that DON'T exist are part of the object).
// ===========================================================================
// ===========================================================================

// --- R1a: incomplete Rate — out_per_in without pull --------------------------
// Block declares out_per_in (a Rate signal) but no pull.
// EXPECTED DIAGNOSTIC (src/port.zig classify):
//   "pan: ... declares out_per_in but no pull — Rate contract incomplete"
//
// const _BadRate_NoPull = struct {
//     const Self = @This();
//     pub const out_per_in = .{ 1, 2 };
//     pub const algorithmic_latency: usize = 0;
// };
// test "R1a: out_per_in without pull is an incomplete Rate (⊢ rejects)" {
//     _ = port.classify(_BadRate_NoPull);
// }

// --- R1b: incomplete Rate — pull without out_per_in --------------------------
// Block declares pull (a Rate signal) but no out_per_in.
// EXPECTED DIAGNOSTIC (src/port.zig classify):
//   "pan: ... declares pull but no out_per_in — Rate contract incomplete"
//
// const _BadRate_NoRatio = struct {
//     const Self = @This();
//     pub const algorithmic_latency: usize = 0;
//     pub fn pull(self: *Self, want: usize, out: []types.Sample(f32)) usize {
//         _ = self; _ = out; return want;
//     }
// };
// test "R1b: pull without out_per_in is an incomplete Rate (⊢ rejects)" {
//     _ = port.classify(_BadRate_NoRatio);
// }

// --- R1c: incomplete Rate — no algorithmic_latency ---------------------------
// Block has out_per_in + pull but no algorithmic_latency.
// EXPECTED DIAGNOSTIC (src/port.zig classify):
//   "pan: ... is a Rate but declares no algorithmic_latency"
//
// const _BadRate_NoLatency = struct {
//     const Self = @This();
//     pub const out_per_in = .{ 1, 2 };
//     pub fn pull(self: *Self, want: usize, out: []types.Sample(f32)) usize {
//         _ = self; _ = out; return want;
//     }
// };
// test "R1c: Rate without algorithmic_latency is incomplete (⊢ rejects)" {
//     _ = port.classify(_BadRate_NoLatency);
// }

// --- V1a: incomplete VariRate — rate_bounds without max_latency --------------
// EXPECTED DIAGNOSTIC (src/port.zig classify):
//   "pan: ... declares rate_bounds but no max_latency — VariRate contract incomplete"
//
// const _BadVari_NoMaxLatency = struct {
//     const Self = @This();
//     pub const rate_bounds = .{ .min = .{ 1, 2 }, .nominal = .{ 1, 1 }, .max = .{ 2, 1 } };
//     pub fn pull(self: *Self, want: usize, out: []types.Sample(f32)) usize {
//         _ = self; _ = out; return want;
//     }
// };
// test "V1a: rate_bounds without max_latency is incomplete VariRate (⊢ rejects)" {
//     _ = port.classify(_BadVari_NoMaxLatency);
// }

// --- V1b: incomplete VariRate — rate_bounds without pull ---------------------
// EXPECTED DIAGNOSTIC (src/port.zig classify):
//   "pan: ... declares rate_bounds but no pull — VariRate contract incomplete"
//
// const _BadVari_NoPull = struct {
//     const Self = @This();
//     pub const rate_bounds = .{ .min = .{ 1, 2 }, .nominal = .{ 1, 1 }, .max = .{ 2, 1 } };
//     pub const max_latency: usize = 2048;
// };
// test "V1b: rate_bounds without pull is incomplete VariRate (⊢ rejects)" {
//     _ = port.classify(_BadVari_NoPull);
// }

// --- N1: a block that is neither Map nor Rate --------------------------------
// No process, no pull, no out_per_in, no rate_bounds.
// EXPECTED DIAGNOSTIC (src/port.zig classify):
//   "pan: ... is neither a Map (process) nor a Rate (out_per_in + pull)"
//
// const _NeitherBlock = struct {
//     const Self = @This();
//     state: u32 = 0,
// };
// test "N1: a block that is neither Map nor Rate is rejected (⊢ rejects)" {
//     _ = port.classify(_NeitherBlock);
// }

// --- C1: the 9th port per direction ------------------------------------------
// checkPortCeiling(9, ...) is one past the u3 ceiling.
// EXPECTED DIAGNOSTIC (src/port.zig checkPortCeiling):
//   "pan: 9 in ports exceeds the 8-port-per-direction ceiling"
//
// test "C1: a 9th port exceeds the 8-port ceiling (⊢ rejects)" {
//     port.checkPortCeiling(9, .in);
// }

// --- P1: ParamPort with a non-existent slot name -----------------------------
// EXPECTED DIAGNOSTIC (src/port.zig ParamElem):
//   "pan: ... has no parameter port 'nonexistent'"
//
// test "P1: ParamPort with a wrong slot name is rejected (⊢ rejects)" {
//     _ = port.ParamPort(ParamBiquad, "nonexistent");
// }

// --- P2: ParamPort on a block declaring no params ----------------------------
// EXPECTED DIAGNOSTIC (src/port.zig ParamElem):
//   "pan: ... declares no parameter ports"
//
// test "P2: ParamPort on a paramless block is rejected (⊢ rejects)" {
//     _ = port.ParamPort(MapGain, "cutoff");
// }
