//! Yoneda-style behavioral specification of the ANALYSIS-ROOT / COMBINATOR surface.
//!
//! Complements `tests/analysis_root_test.zig` (the Phase-9 gate) with deeper,
//! definition-by-morphism coverage of:
//!   - `Concat` named fan-in: `ConcatOut(spec)` column order = declaration order
//!     for several specs (incl. reordered → reordered), arities 1..8, name-keyed
//!     (not position-keyed) wiring through a real committed `runToCompletion`,
//!     and one-output-row-per-input-hop.
//!   - `FeatureCollectorSink`: lossless geometric growth past `capacity_hint`,
//!     `frames()` arrival order, sink/Map classification, leak-free deinit.
//!   - Law A8 (⊢): growable sink rejected on a realtime root, accepted via
//!     `commitAnalysis`, no false positive for a non-growable graph.
//!   - `runToCompletion`: input-exhaustion drains a non-looping source within a
//!     bounded block count; never-exhausting source → `error.NoExhaustibleSource`;
//!     collected row count consistent with input length / block size.
//!   - `encodeFeatureMatrix` / `featureMatrixColumns`: column count, row-major
//!     layout, integer-scalar widening, column order = Row field order, checked
//!     against an INDEPENDENT in-test flattening.
//!   - `ChannelMap(Sub, C)`: per-plane independence + C-scaled element.
//!
//! Comparison modes (project §0.5): structural / wiring / A8 / column-order facts
//! are EXACT (bit-exact f32 reproduction, exact integer/string/error equality).
//! Every feature value is PLANTED deterministically by an in-test source, so the
//! expected columns are exact — no tolerance is needed.

const std = @import("std");
const pan = @import("pan");
const testing = std.testing;

const Num = pan.numericFor(.f32, .{});

// ===========================================================================
// In-test deterministic sources — plant EXACT values so columns are bit-checkable
// ===========================================================================

/// A zero-input Map source that streams a fixed list of `Scalar(f32)` values then
/// reports exhausted (zero-padding the tail). Each instance carries a distinct
/// `tag` so a row column can be traced back to the producer that fed its name.
fn ScalarF32Source() type {
    return struct {
        const Self = @This();
        values: []const f32 = &.{},
        cursor: usize = 0,
        done: bool = false,
        pub fn process(self: *Self, out: []pan.Scalar(f32)) void {
            for (out) |*o| {
                if (self.cursor >= self.values.len) {
                    self.done = true;
                    o.* = .{ .value = 0 };
                    continue;
                }
                o.* = .{ .value = self.values[self.cursor] };
                self.cursor += 1;
            }
        }
        pub fn exhausted(self: *Self) bool {
            return self.done;
        }
    };
}

/// A zero-input Map source emitting a CONSTANT `Scalar(f32)` every hop. Used where
/// a per-name distinct constant is enough to prove name-keyed wiring; it never
/// exhausts (so a separate drainer drives the run).
fn ConstF32(comptime k: f32) type {
    return struct {
        const Self = @This();
        pub fn process(self: *Self, out: []pan.Scalar(f32)) void {
            _ = self;
            for (out) |*o| o.* = .{ .value = k };
        }
    };
}

/// A zero-input Map source emitting a CONSTANT `Scalar(u16)` every hop.
fn ConstU16(comptime k: u16) type {
    return struct {
        const Self = @This();
        pub fn process(self: *Self, out: []pan.Scalar(u16)) void {
            _ = self;
            for (out) |*o| o.* = .{ .value = k };
        }
    };
}

/// A zero-input Map source emitting a CONSTANT `FeatureFrame(K)` (lane `i` == base+i).
fn ConstFrame(comptime K: usize, comptime base: f32) type {
    return struct {
        const Self = @This();
        pub fn process(self: *Self, out: []pan.FeatureFrame(K)) void {
            _ = self;
            for (out) |*o| {
                inline for (0..K) |i| o.v[i] = base + @as(f32, @floatFromInt(i));
            }
        }
    };
}

/// A drainer: a zero-input `Scalar(f32)` source that emits `len` hops then reports
/// exhausted. It exists purely to give an input-exhaustion run a finish line when
/// the feature producers are non-exhausting constants. Its own column is ignored.
fn Drainer() type {
    return struct {
        const Self = @This();
        len: usize = 0,
        cursor: usize = 0,
        done: bool = false,
        pub fn process(self: *Self, out: []pan.Scalar(f32)) void {
            for (out) |*o| {
                if (self.cursor >= self.len) {
                    self.done = true;
                    o.* = .{ .value = -1 };
                    continue;
                }
                o.* = .{ .value = @floatFromInt(self.cursor) };
                self.cursor += 1;
            }
        }
        pub fn exhausted(self: *Self) bool {
            return self.done;
        }
    };
}

// ===========================================================================
// 1. Concat — ConcatOut field order == spec declaration order (pure comptime)
// ===========================================================================

test "Concat: ConcatOut field order is the spec declaration order (canonical column order)" {
    // The column identity is the field NAME and the order is declaration order, so
    // two specs differing only in declaration order produce differently-ordered rows.
    const A = pan.ConcatOut(.{
        .mfcc = pan.FeatureFrame(13),
        .centroid = pan.Scalar(f32),
        .dominant = pan.Scalar(u16),
    });
    const fa = @typeInfo(A).@"struct".fields;
    try testing.expectEqual(@as(usize, 3), fa.len);
    try testing.expectEqualStrings("mfcc", fa[0].name);
    try testing.expectEqualStrings("centroid", fa[1].name);
    try testing.expectEqualStrings("dominant", fa[2].name);

    // Reorder the SAME three names → the columns permute to match.
    const B = pan.ConcatOut(.{
        .dominant = pan.Scalar(u16),
        .mfcc = pan.FeatureFrame(13),
        .centroid = pan.Scalar(f32),
    });
    const fb = @typeInfo(B).@"struct".fields;
    try testing.expectEqualStrings("dominant", fb[0].name);
    try testing.expectEqualStrings("mfcc", fb[1].name);
    try testing.expectEqualStrings("centroid", fb[2].name);

    // The field TYPES travel with their names (the element type per column).
    try testing.expect(fa[0].type == pan.FeatureFrame(13));
    try testing.expect(fa[1].type == pan.Scalar(f32));
    try testing.expect(fa[2].type == pan.Scalar(u16));
    try testing.expect(fb[0].type == pan.Scalar(u16));
}

test "Concat: classifies as a Map and its arity respects the 8-port ceiling" {
    // A Concat is a rate-1:1 Map (one output row per input hop, no rate change).
    const C3 = pan.combinators.Concat(.{
        .a = pan.Scalar(f32),
        .b = pan.Scalar(f32),
        .c = pan.Scalar(f32),
    });
    try testing.expect(pan.classify(C3) == .Map);

    // The 8-arity ceiling is reachable (law A2): a full 8-input Concat compiles.
    const C8 = pan.combinators.Concat(.{
        .a = pan.Scalar(f32),
        .b = pan.Scalar(f32),
        .c = pan.Scalar(f32),
        .d = pan.Scalar(f32),
        .e = pan.Scalar(f32),
        .f = pan.Scalar(f32),
        .g = pan.Scalar(f32),
        .h = pan.Scalar(f32),
    });
    try testing.expect(pan.classify(C8) == .Map);
    try testing.expectEqual(@as(usize, 8), @typeInfo(pan.ConcatOut(.{
        .a = pan.Scalar(f32),
        .b = pan.Scalar(f32),
        .c = pan.Scalar(f32),
        .d = pan.Scalar(f32),
        .e = pan.Scalar(f32),
        .f = pan.Scalar(f32),
        .g = pan.Scalar(f32),
        .h = pan.Scalar(f32),
    })).@"struct".fields.len);
}

// ===========================================================================
// 1b. Concat — NAME-keyed wiring through a real committed analysis run
// ===========================================================================

test "Concat: node.in.<name> wires by NAME, not by add/connect order (committed run)" {
    // BUG DETECTED: named fan-in is NOT name-keyed at render time — it is
    // CONNECT-ORDER-keyed. The builder records `collect.in.<name>` with the spec's
    // declaration index as `to_port` (correct), but the commit emit pass
    // (`src/commit.zig` §8, ~line 999) gathers a node's forward input buffer ids in
    // EDGE-INSERTION order and never sorts them by `e.to_port`. The Concat `process`
    // assigns `field[i] = arg_i` positionally by port index, so when the connect
    // order differs from the declaration order the columns are mis-routed.
    // Expected: column "a" carries the producer wired to NAME a (100), etc.
    // Actual:   column "a" carries the value of the FIRST-connected producer (300).
    // This test connects in scrambled order (c, b, a) and asserts the NAME-keyed
    // result; it FAILS, pinning the bug. (Connecting in declaration order — see the
    // happy-path test below — masks it, which is why no prior test caught it.)
    const gpa = testing.allocator;
    const Spec = .{ .a = pan.Scalar(f32), .b = pan.Scalar(f32), .c = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 4 });
    defer g.deinit();

    // Each producer emits a DISTINCT constant. We deliberately permute BOTH the add
    // order and the connect order relative to the column order (a..b..c). If wiring
    // is name-keyed (the contract) the assertions hold; they FAIL under the
    // connect-order-keyed bug.
    const pc = try g.add(ConstF32(300.0), .{}); // feeds name "c"
    const pa = try g.add(ConstF32(100.0), .{}); // feeds name "a"
    const pb = try g.add(ConstF32(200.0), .{}); // feeds name "b"
    const drain = try g.add(Drainer(), .{ .len = 5 }); // gives the run a finish line
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 8 });

    // Connect in scrambled order: c first, then b, then a.
    try g.connect(pc, collect.in.c);
    try g.connect(pb, collect.in.b);
    try g.connect(pa, collect.in.a);
    try g.connect(collect, sink);
    // The drainer is wired to its own one-input collector → its own sink, so its
    // exhaustion drives the run without touching the column-order collector.
    const DrainSpec = .{ .d = pan.Scalar(f32) };
    const DrainCollect = pan.combinators.Concat(DrainSpec);
    const dcollect = try g.add(DrainCollect, .{});
    const dsink = try g.add(pan.io.FeatureCollectorSink(pan.ConcatOut(DrainSpec)), .{ .capacity_hint = 8 });
    try g.connect(drain, dcollect.in.d);
    try g.connect(dcollect, dsink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    try testing.expect(rows.len >= 5);
    // Column "a" carries 100 (the producer wired to NAME a), "b" 200, "c" 300 —
    // exactly, for every hop. Bit-exact: constants survive an identity copy.
    for (rows) |r| {
        try testing.expectEqual(@as(f32, 100.0), r.a.value);
        try testing.expectEqual(@as(f32, 200.0), r.b.value);
        try testing.expectEqual(@as(f32, 300.0), r.c.value);
    }
}

test "Concat: declaration-order wiring yields the named columns (happy path)" {
    // The masking case that hides the bug above: when producers are connected in the
    // SAME order as the spec declares the names, connect-order == port-order, so the
    // (buggy) connect-order keying coincides with the correct name keying and the
    // columns are right. This test stays GREEN and documents the working path; the
    // scrambled-order test above is what reveals the latent mis-routing.
    const gpa = testing.allocator;
    const Spec = .{ .a = pan.Scalar(f32), .b = pan.Scalar(f32), .c = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 4 });
    defer g.deinit();
    const pa = try g.add(ConstF32(100.0), .{});
    const pb = try g.add(ConstF32(200.0), .{});
    const pc = try g.add(ConstF32(300.0), .{});
    const drain = try g.add(Drainer(), .{ .len = 5 });
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 8 });
    // Connect in DECLARATION order: a, then b, then c.
    try g.connect(pa, collect.in.a);
    try g.connect(pb, collect.in.b);
    try g.connect(pc, collect.in.c);
    try g.connect(collect, sink);
    const DrainSpec = .{ .d = pan.Scalar(f32) };
    const DrainCollect = pan.combinators.Concat(DrainSpec);
    const dcollect = try g.add(DrainCollect, .{});
    const dsink = try g.add(pan.io.FeatureCollectorSink(pan.ConcatOut(DrainSpec)), .{ .capacity_hint = 8 });
    try g.connect(drain, dcollect.in.d);
    try g.connect(dcollect, dsink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    try testing.expect(rows.len >= 5);
    for (rows) |r| {
        try testing.expectEqual(@as(f32, 100.0), r.a.value);
        try testing.expectEqual(@as(f32, 200.0), r.b.value);
        try testing.expectEqual(@as(f32, 300.0), r.c.value);
    }
}

test "Concat: permuting which producer feeds which NAME permutes the columns" {
    // BUG DETECTED (same root cause as the scrambled-order test): SAME producers, but
    // the name→producer mapping is swapped (100→b, 200→a) AND the connect order is
    // scrambled (b connected before a). Name-keyed wiring would give a=200, b=100;
    // the connect-order bug gives a=100 (first-connected), b=200.
    // Expected: a ← 200 (the producer wired to NAME a), b ← 100.
    // Actual:   a ← 100 (first connected), b ← 200.
    const gpa = testing.allocator;
    const Spec = .{ .a = pan.Scalar(f32), .b = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 4 });
    defer g.deinit();
    const p100 = try g.add(ScalarF32Source(), .{ .values = &[_]f32{ 100, 100, 100, 100, 100, 100 } });
    const p200 = try g.add(ConstF32(200.0), .{});
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 8 });
    // Scrambled: wire name "b" FIRST, then name "a" — so connect order ≠ port order.
    try g.connect(p100, collect.in.b);
    try g.connect(p200, collect.in.a);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    try testing.expect(rows.len >= 6);
    for (0..6) |i| {
        try testing.expectEqual(@as(f32, 200.0), rows[i].a.value); // a ← the 200 producer
        try testing.expectEqual(@as(f32, 100.0), rows[i].b.value); // b ← the 100 producer
    }
}

test "Concat: a heterogeneous 5-name row carries each named producer's value per hop" {
    // Mixed element types (FeatureFrame + f32 scalars + a u16 scalar), connected in
    // DECLARATION order so it exercises the END-TO-END happy path for a heterogeneous
    // row without tripping the connect-order bug. Driven to exhaustion by a counter.
    //
    // NOTE (severity of the bug above): for a heterogeneous spec the connect-order
    // mis-routing is not merely wrong values — it is a HARD CRASH. If `beta`
    // (Scalar(f32), 4 bytes) is connected before `frame` (FeatureFrame(3), 12 bytes),
    // the executor binds `frame`'s 12-byte port-0 slice to `beta`'s 4-byte buffer and
    // `std.mem.bytesAsSlice` panics on `@divExact(4, 12)` (engine.zig sliceConst).
    // So the same `commit.zig` emit ordering defect that mis-routes homogeneous
    // columns ABORTS the render for a heterogeneous one. This test connects in
    // declaration order to avoid that abort and stay green.
    const gpa = testing.allocator;
    const K = 3;
    const Spec = .{
        .frame = pan.FeatureFrame(K),
        .alpha = pan.Scalar(f32),
        .count = pan.Scalar(f32), // the driving counter (exhausts the run)
        .band = pan.Scalar(u16),
        .beta = pan.Scalar(f32),
    };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 8 });
    defer g.deinit();
    const N = 20;
    var counts: [N]f32 = undefined;
    for (&counts, 0..) |*c, i| c.* = @floatFromInt(i);

    const frame = try g.add(ConstFrame(K, 7.0), .{});
    const alpha = try g.add(ConstF32(1.5), .{});
    const beta = try g.add(ConstF32(2.5), .{});
    const band = try g.add(ConstU16(42), .{});
    const counter = try g.add(ScalarF32Source(), .{ .values = &counts });
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 32 });

    // Connect strictly in declaration order: frame, alpha, count, band, beta.
    try g.connect(frame, collect.in.frame);
    try g.connect(alpha, collect.in.alpha);
    try g.connect(counter, collect.in.count);
    try g.connect(band, collect.in.band);
    try g.connect(beta, collect.in.beta);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    try testing.expect(rows.len >= N);
    for (0..N) |i| {
        inline for (0..K) |k| try testing.expectEqual(7.0 + @as(f32, @floatFromInt(k)), rows[i].frame.v[k]);
        try testing.expectEqual(@as(f32, 1.5), rows[i].alpha.value);
        try testing.expectEqual(@as(f32, 2.5), rows[i].beta.value);
        try testing.expectEqual(@as(u16, 42), rows[i].band.value);
        try testing.expectEqual(@as(f32, @floatFromInt(i)), rows[i].count.value);
    }
}

// ===========================================================================
// 2. FeatureCollectorSink — lossless geometric growth past the hint
// ===========================================================================

test "FeatureCollectorSink: appends one row per hop in arrival order, exactly N rows" {
    // One-output-row-per-input-hop: a counter source of length N, block_size B, must
    // produce exactly the N planted rows (followed only by zero-padded tail rows to
    // the final block edge) — never duplicated, never reordered.
    const gpa = testing.allocator;
    const Spec = .{ .count = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    const N = 37; // not a multiple of the block size, so a partial final block exists
    const B = 8;
    var vals: [N]f32 = undefined;
    for (&vals, 0..) |*v, i| v.* = @floatFromInt(i * 3 + 1);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = B });
    defer g.deinit();
    const counter = try g.add(ScalarF32Source(), .{ .values = &vals });
    const collect = try g.add(Collect, .{});
    // capacity_hint deliberately SMALLER than N → forces geometric growth.
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 4 });
    try g.connect(counter, collect.in.count);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    // The run renders whole blocks; with N=37, B=8 it stops after ceil-ish many
    // blocks. Rows are produced in block-sized batches, so the count is a multiple
    // of B, ≥ N and < N + B (the run breaks the block AFTER the source drained).
    try testing.expect(rows.len >= N);
    try testing.expect(rows.len % B == 0);
    try testing.expect(rows.len < N + B);
    // No overflow under the testing allocator — growth past the hint is lossless.
    try testing.expect(!sink.instance().overflowed);
    // The first N rows are the planted counter, in order; the tail is the zero pad.
    for (0..N) |i| try testing.expectEqual(vals[i], rows[i].count.value);
    for (N..rows.len) |i| try testing.expectEqual(@as(f32, 0), rows[i].count.value);
}

test "FeatureCollectorSink: many hops far past the hint stay lossless and ordered" {
    // Drive FAR more hops than the hint (×100) to exercise several geometric doublings.
    const gpa = testing.allocator;
    const Spec = .{ .count = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    const N = 500;
    const B = 16;
    var vals: [N]f32 = undefined;
    for (&vals, 0..) |*v, i| v.* = @floatFromInt(i);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = B });
    defer g.deinit();
    const counter = try g.add(ScalarF32Source(), .{ .values = &vals });
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 5 });
    try g.connect(counter, collect.in.count);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });

    const rows = sink.instance().frames();
    try testing.expect(rows.len >= N);
    try testing.expect(!sink.instance().overflowed);
    // Every planted value present at its index — geometric realloc preserved order.
    for (0..N) |i| try testing.expectEqual(vals[i], rows[i].count.value);
}

test "FeatureCollectorSink: input-only sink classifies as a Map (no output port)" {
    const Sink = pan.io.FeatureCollectorSink(pan.ConcatOut(.{ .x = pan.Scalar(f32) }));
    // A sink is a Map with an empty output side (process(self, in) only).
    try testing.expect(pan.classify(Sink) == .Map);
    // The growable_sink marker is what law A8 keys its rejection off.
    try testing.expect(Sink.growable_sink);
}

// ===========================================================================
// 3. Law A8 (⊢) — growable sink only on a non-RT analysis root
// ===========================================================================

test "A8: a growable sink on a realtime root is error.GrowableSinkOnRealtimeRoot" {
    const gpa = testing.allocator;
    const Spec = .{ .x = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 8 });
    defer g.deinit();
    const src = try g.add(ConstF32(1.0), .{});
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 8 });
    try g.connect(src, collect.in.x);
    try g.connect(collect, sink);

    // The realtime commit rejects the growable sink (its geometric realloc cannot
    // sit on the audio deadline).
    try testing.expectError(pan.CommitError.GrowableSinkOnRealtimeRoot, g.commit());
}

test "A8: the SAME growable-sink graph commits via commitAnalysis (non-RT root)" {
    const gpa = testing.allocator;
    const Spec = .{ .x = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 8 });
    defer g.deinit();
    const src = try g.add(Drainer(), .{ .len = 3 });
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 8 });
    try g.connect(src, collect.in.x);
    try g.connect(collect, sink);

    // The analysis commit accepts it (the contained H1 exception lives here).
    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });
    try testing.expect(sink.instance().frames().len >= 3);
}

test "A8: a graph WITHOUT a growable sink commits fine on a realtime root (no false positive)" {
    // The A8 rejection keys strictly off the `growable_sink` marker — an ordinary
    // sink on a realtime root must NOT be rejected.
    const gpa = testing.allocator;
    const BufSrc = struct {
        const Self = @This();
        data: [*]const pan.Sample(f32) = undefined,
        pub fn process(self: *Self, out: []pan.Sample(f32)) void {
            @memcpy(out, self.data[0..out.len]);
        }
    };
    const PlainSink = struct {
        const Self = @This();
        dest: [*]pan.Sample(f32) = undefined,
        pub fn process(self: *Self, in: []const pan.Sample(f32)) void {
            @memcpy(self.dest[0..in.len], in);
        }
    };
    var input: [8]pan.Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @floatFromInt(i);
    var output: [8]pan.Sample(f32) = undefined;

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 8 });
    defer g.deinit();
    const src = try g.add(BufSrc, .{ .data = @as([*]const pan.Sample(f32), &input) });
    const sink = try g.add(PlainSink, .{ .dest = @as([*]pan.Sample(f32), &output) });
    try g.connect(src, sink);

    var eng = try g.commit(); // realtime commit succeeds — no growable sink present
    defer eng.deinit();
    try testing.expectEqual(@as(usize, 2), eng.op_count);
}

// ===========================================================================
// 4. runToCompletion — drains, bounds, and rejects the un-drainable
// ===========================================================================

test "runToCompletion: input-exhaustion drains a non-looping source within max_blocks" {
    const gpa = testing.allocator;
    const Spec = .{ .count = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    const N = 25;
    const B = 8;
    var vals: [N]f32 = undefined;
    for (&vals, 0..) |*v, i| v.* = @floatFromInt(i);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = B });
    defer g.deinit();
    const counter = try g.add(ScalarF32Source(), .{ .values = &vals });
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 64 });
    try g.connect(counter, collect.in.count);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    // A tight max_blocks ceiling that is still ample: ceil(N/B)=4 blocks suffice.
    try eng.runToCompletion(.{ .clock = .input_exhaustion, .max_blocks = 16 });

    const rows = sink.instance().frames();
    // Row count consistent with input length and block size: the run renders whole
    // blocks until the source drains, then breaks — so rows == ceil(N/B)*B exactly.
    const expected_blocks = (N + B - 1) / B;
    try testing.expectEqual(expected_blocks * B, rows.len);
}

test "runToCompletion: a never-exhausting source is rejected up front (NoExhaustibleSource)" {
    const gpa = testing.allocator;
    const Spec = .{ .x = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = 8 });
    defer g.deinit();
    // ConstF32 declares no `exhausted` probe → no drainable source.
    const src = try g.add(ConstF32(1.0), .{});
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 8 });
    try g.connect(src, collect.in.x);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    // No exhaustion probe anywhere ⇒ an input-exhaustion run could never terminate,
    // so it is rejected before rendering a single block.
    try testing.expectError(error.NoExhaustibleSource, eng.runToCompletion(.{ .clock = .input_exhaustion }));
    // And the sink stayed empty (no block was rendered).
    try testing.expectEqual(@as(usize, 0), sink.instance().frames().len);
}

test "runToCompletion: an empty (immediately-exhausted) source still terminates cleanly" {
    // A zero-length drainer reports exhausted after its very first block; the run
    // must terminate after exactly one block (its rows are the zero pad).
    const gpa = testing.allocator;
    const Spec = .{ .x = pan.Scalar(f32) };
    const Collect = pan.combinators.Concat(Spec);
    const Row = pan.ConcatOut(Spec);

    const B = 8;
    var g = pan.Graph.init(gpa, .{ .precision = .f32, .channels = .mono, .block_size = B });
    defer g.deinit();
    const src = try g.add(Drainer(), .{ .len = 0 });
    const collect = try g.add(Collect, .{});
    const sink = try g.add(pan.io.FeatureCollectorSink(Row), .{ .capacity_hint = 8 });
    try g.connect(src, collect.in.x);
    try g.connect(collect, sink);

    var eng = try g.commitAnalysis();
    defer eng.deinit();
    try eng.runToCompletion(.{ .clock = .input_exhaustion });
    // One block rendered, then the source was already drained → break.
    try testing.expectEqual(@as(usize, B), sink.instance().frames().len);
}

// ===========================================================================
// 5. encodeFeatureMatrix / featureMatrixColumns — column count, layout, widening
// ===========================================================================

/// An INDEPENDENT reimplementation of the row→f32 flatten, used as the oracle the
/// library's `encodeFeatureMatrix` must match bit-for-bit. Recomputes the column
/// width and the column values a second way (explicit per-field, no shared helper).
fn expectedColumns(comptime Row: type) usize {
    comptime var n: usize = 0;
    inline for (@typeInfo(Row).@"struct".fields) |f| {
        const F = f.type;
        if (@hasDecl(F, "feature_count")) {
            n += F.feature_count;
        } else {
            n += 1; // a Scalar
        }
    }
    return n;
}

fn flattenOracle(comptime Row: type, row: Row, out: []f32) void {
    comptime var col: usize = 0;
    inline for (@typeInfo(Row).@"struct".fields) |f| {
        const F = f.type;
        const v = @field(row, f.name);
        if (@hasDecl(F, "feature_count")) {
            inline for (0..F.feature_count) |i| {
                out[col + i] = v.v[i];
            }
            col += F.feature_count;
        } else {
            // Widen any numeric scalar lane to f32 a second, explicit way.
            const T = @TypeOf(v.value);
            out[col] = switch (@typeInfo(T)) {
                .float => @floatCast(v.value),
                .int => @floatFromInt(v.value),
                else => unreachable,
            };
            col += 1;
        }
    }
}

test "featureMatrixColumns: column count = sum of field widths (FeatureFrame K + scalars)" {
    const Row = pan.ConcatOut(.{
        .mfcc = pan.FeatureFrame(13),
        .centroid = pan.Scalar(f32),
        .dominant = pan.Scalar(u16),
        .chroma = pan.FeatureFrame(12),
        .rms = pan.Scalar(f32),
    });
    const cols = comptime pan.featureMatrixColumns(Row);
    try testing.expectEqual(@as(usize, 13 + 1 + 1 + 12 + 1), cols);
    // The independent recomputation agrees.
    try testing.expectEqual(comptime expectedColumns(Row), cols);
}

test "encodeFeatureMatrix: row-major layout matches an independent flatten (mixed shapes)" {
    const gpa = testing.allocator;
    const K = 4;
    const Row = pan.ConcatOut(.{
        .frame = pan.FeatureFrame(K),
        .centroid = pan.Scalar(f32),
        .band = pan.Scalar(u16),
        .rms = pan.Scalar(f32),
    });
    const cols = comptime pan.featureMatrixColumns(Row);

    // Build a small matrix of distinct, exactly-representable values per row.
    const R = 6;
    var matrix: [R]Row = undefined;
    for (&matrix, 0..) |*row, r| {
        inline for (0..K) |i| row.frame.v[i] = @floatFromInt(r * 10 + i);
        row.centroid = .{ .value = @as(f32, @floatFromInt(r)) + 0.25 };
        row.band = .{ .value = @intCast(r * 7) }; // u16 → widens to f32
        row.rms = .{ .value = @as(f32, @floatFromInt(r)) * 0.5 };
    }

    const mslice: []const Row = &matrix;
    const flat = try pan.encodeFeatureMatrix(gpa, mslice);
    defer gpa.free(flat);

    try testing.expectEqual(R * cols, flat.len);

    // Reproduce the expected flattening independently and assert BIT-EXACT equality.
    var oracle: [R * cols]f32 = undefined;
    for (matrix, 0..) |row, r| {
        flattenOracle(Row, row, oracle[r * cols ..][0..cols]);
    }
    try testing.expectEqualSlices(f32, oracle[0..], flat);

    // Spot-check the column ORDER explicitly: row r's columns are
    // [frame[0..K] | centroid | band | rms] contiguously.
    for (0..R) |r| {
        const base = r * cols;
        inline for (0..K) |i| try testing.expectEqual(@as(f32, @floatFromInt(r * 10 + i)), flat[base + i]);
        try testing.expectEqual(@as(f32, @floatFromInt(r)) + 0.25, flat[base + K]);
        // The u16 band widened to f32 exactly.
        try testing.expectEqual(@as(f32, @floatFromInt(r * 7)), flat[base + K + 1]);
        try testing.expectEqual(@as(f32, @floatFromInt(r)) * 0.5, flat[base + K + 2]);
    }
}

test "encodeFeatureMatrix: an empty matrix encodes to an empty (zero-length) buffer" {
    const gpa = testing.allocator;
    const Row = pan.ConcatOut(.{ .x = pan.Scalar(f32) });
    const empty: []const Row = &.{};
    const flat = try pan.encodeFeatureMatrix(gpa, empty);
    defer gpa.free(flat);
    try testing.expectEqual(@as(usize, 0), flat.len);
}

test "encodeFeatureMatrix: integer scalar columns widen to f32 across lane widths" {
    // A row of only integer scalars of different widths — each widens to the exact
    // f32 of its integer value, in field order.
    const gpa = testing.allocator;
    const Row = pan.ConcatOut(.{
        .u8v = pan.Scalar(u8),
        .u16v = pan.Scalar(u16),
        .i32v = pan.Scalar(i32),
    });
    const cols = comptime pan.featureMatrixColumns(Row);
    try testing.expectEqual(@as(usize, 3), cols);

    var matrix: [2]Row = undefined;
    matrix[0] = .{ .u8v = .{ .value = 200 }, .u16v = .{ .value = 5000 }, .i32v = .{ .value = -123456 } };
    matrix[1] = .{ .u8v = .{ .value = 1 }, .u16v = .{ .value = 65535 }, .i32v = .{ .value = 2000000 } };

    const mslice: []const Row = &matrix;
    const flat = try pan.encodeFeatureMatrix(gpa, mslice);
    defer gpa.free(flat);
    const want = [_]f32{ 200, 5000, -123456, 1, 65535, 2000000 };
    try testing.expectEqualSlices(f32, &want, flat);
}

// ===========================================================================
// 6. ChannelMap(Sub, C) — per-plane independence + C-scaled element
// ===========================================================================

test "ChannelMap: runs the mono Sub on each of C planes independently" {
    // A mono Map that doubles its input. ChannelMap(Sub, C) must apply it to each of
    // the C planes independently (the product functor C^(Sub)).
    const Double = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const pan.Sample(f32), out: []pan.Sample(f32)) void {
            _ = self;
            for (in, out) |x, *o| o.ch[0] = x.ch[0] * 2.0;
        }
    };
    const C = 3;
    const CM = pan.combinators.ChannelMap(Double, C);
    // ChannelMap classifies as a Map.
    try testing.expect(pan.classify(CM) == .Map);

    var cm: CM = .{};
    const L: pan.ChannelLayout = .{ .discrete = C };
    const N = 4;
    // Plane-major input: C contiguous N-sample planes with distinct per-plane data.
    var inbuf: [C * N]f32 = undefined;
    for (0..C) |c| {
        for (0..N) |f| inbuf[c * N + f] = @floatFromInt(c * 100 + f);
    }
    var outbuf: [C * N]f32 = [_]f32{0} ** (C * N);

    const inv = pan.PlanarConst(f32, L).fromBase(&inbuf, N);
    const outv = pan.Planar(f32, L).fromBase(&outbuf, N);
    cm.process(inv, outv);

    // Each plane independently doubled — no cross-plane contamination.
    for (0..C) |c| {
        for (0..N) |f| {
            const want: f32 = @as(f32, @floatFromInt(c * 100 + f)) * 2.0;
            try testing.expectEqual(want, outbuf[c * N + f]);
        }
    }
}

test "ChannelMap: holds C independent Sub instances (per-plane state)" {
    // The block owns exactly C Sub instances (one per plane), so per-plane state is
    // independent. We assert the instance count structurally via the field array.
    const Stateful = struct {
        const Self = @This();
        acc: f32 = 0,
        pub fn process(self: *Self, in: []const pan.Sample(f32), out: []pan.Sample(f32)) void {
            for (in, out) |x, *o| {
                self.acc += x.ch[0];
                o.ch[0] = self.acc; // running sum — reveals cross-plane leakage if any
            }
        }
    };
    const C = 2;
    const CM = pan.combinators.ChannelMap(Stateful, C);
    var cm: CM = .{};
    try testing.expectEqual(@as(usize, C), cm.subs.len);

    const L: pan.ChannelLayout = .{ .discrete = C };
    const N = 3;
    // Plane 0 = {1,1,1}; plane 1 = {10,10,10}.
    var inbuf = [_]f32{ 1, 1, 1, 10, 10, 10 };
    var outbuf = [_]f32{0} ** (C * N);
    const inv = pan.PlanarConst(f32, L).fromBase(&inbuf, N);
    const outv = pan.Planar(f32, L).fromBase(&outbuf, N);
    cm.process(inv, outv);

    // Plane 0 running sum {1,2,3}; plane 1 {10,20,30} — fully independent accumulators.
    const want = [_]f32{ 1, 2, 3, 10, 20, 30 };
    try testing.expectEqualSlices(f32, &want, &outbuf);
}
