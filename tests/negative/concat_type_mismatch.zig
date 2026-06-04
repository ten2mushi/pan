//! NEGATIVE-COMPILE fixture: wiring a `Scalar(f32)` producer into a named `Concat`
//! column typed `FeatureFrame(13)`. The Phase 9 guarantee "a wrong element type on
//! `node.in.<name>` is a compile error" is ⊢-by-construction (the `connect`
//! element-type check, `src/graph.zig:340`, fired through the named input port
//! `port.NamedInPort`). This fixture turns that claim from by-inspection into an
//! ACTIVE check: the `neg-compile` build step asserts THIS FILE FAILS to compile
//! (expects a non-zero `zig build-obj` exit). If the mismatch ever compiles, the
//! Concat column-typing guarantee regressed and the build step fails.
const std = @import("std");
const pan = @import("pan");

const Num = pan.numericFor(.f32, .{});

// A Concat with a single column `feat` typed FeatureFrame(13).
const Spec = .{ .feat = pan.FeatureFrame(13) };
const Collect = pan.combinators.Concat(Spec);

/// Build the bad graph: a `SpectralCentroid` (emits `Scalar(f32)`) wired into the
/// `feat` column (expects `FeatureFrame(13)`). The `g.connect` is where the
/// element-type `@compileError` fires.
fn buildBadGraph() !void {
    var g = pan.Graph.init(std.heap.page_allocator, .{ .precision = .f32, .channels = .mono, .block_size = 16 });
    defer g.deinit();
    const centroid = try g.add(pan.feat.SpectralCentroid(Num, 8), .{}); // → Scalar(f32)
    const collect = try g.add(Collect, .{});
    // MISMATCH: Scalar(f32) producer into a FeatureFrame(13) column → @compileError.
    try g.connect(centroid, collect.in.feat);
}

comptime {
    // Force semantic analysis of the bad connect so its @compileError fires during
    // `zig build-obj` (an object does not analyze `main` unless it is referenced).
    _ = &buildBadGraph;
}

pub fn main() void {}
