//! Yoneda "tests as definition" suite for the VALIDATION stages of the pan
//! commit pass (`src/commit.zig`, stages 1–4: negotiate/validate, topo via
//! Kahn with a min-node-id tie-break, source-rooted SR3, and the
//! SCC-has-delay / delay-free-loop check on the full graph).
//!
//! THE YONEDA FRAMING. The commit pass is an opaque comptime function; we never
//! reach inside it. We know it ONLY through the two things it can hand back: the
//! `Plan(g.node_count)` it returns (observed through `op_count`, the per-op
//! input/output port counts and buffer ids, the per-op frame count, and the
//! comptime-constant `footprint_bytes`) and the `CommitError` it raises. Two
//! commit passes that agree on every such observation, for every graph, are the
//! same pass. So this file pins those observations across a broad family of
//! graphs: each accepted topology is identified by what its plan looks like, and
//! each rejected topology by which error fires — and, crucially, by which errors
//! DO NOT fire (the taxonomy must stay distinct).
//!
//! COMPARISON MODE: ⊢ structural / decidable. Every assertion is exact equality
//! (`expectEqual`) or an exact error (`expectError`). There is no float in the
//! observable surface of a validation result, so there is never a tolerance.
//!
//! THE LAWS, restated in plain words (no spec section numbers — src/ owns those):
//!   L1  Topo + determinism. A committed graph yields one op per node in a single
//!       deterministic order; re-committing the identical graph yields the
//!       identical plan. Kahn breaks ties by LOWEST node id, so the op at topo
//!       position i is fixed by insertion order, not by chance. Reconvergence
//!       (a diamond) is NOT a cycle and must be accepted.
//!   L2  UndeclaredCycle. A cycle built from ORDINARY (non-feedback) edges — a
//!       self-loop, a 2-cycle, a 3-cycle — survives the feedback-stripped topo
//!       sort and is rejected `error.UndeclaredCycle`.
//!   L3  UnrootedPath (source-rooted SR3). Every path head (a node with no
//!       non-feedback input edge) must be a Source (zero sample inputs). A
//!       Map/Sink head with an unfed input port is `error.UnrootedPath`; a
//!       Source-rooted graph (including a lone Source) is accepted.
//!   L4  DelayFreeLoop vs accept. A DECLARED feedback cycle with no delay element
//!       is `error.DelayFreeLoop`; the SAME topology with a delay block inside
//!       the cycle is accepted. The only difference is the delay — the crisp dual.
//!   L5  The taxonomy is distinct. UndeclaredCycle, DelayFreeLoop, and
//!       UnrootedPath each fire on their own graph and are never confused.
//!   L6  Malformed boundaries. A hand-built edge to an out-of-range node id is
//!       `error.MalformedGraph`; >8 edges out of one node is
//!       `error.PortCeilingExceeded`.
//!
//! Verified against zig 0.16.0 (the `zig-0-16` skill was loaded first). The whole
//! commit pass runs at comptime, so every graph is built in a `comptime` block
//! and committed with `comptime try` / `expectError(.., comptime commitComptime(g))`.

const std = @import("std");
const pan = @import("pan");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expect = std.testing.expect;

const Sample = pan.Sample;

// =====================================================================
// Synthetic blocks — the alphabet of element classes we wire graphs from.
// (Same idiom as the in-file tests in commit.zig: tiny structs whose
// signature shape IS their port profile.)
// =====================================================================

/// A SOURCE: zero sample inputs, so it may legally root a path.
const Src = struct {
    const Self = @This();
    pub fn process(self: *Self, out: []Sample(f32)) void {
        _ = self;
        _ = out;
    }
};

/// A rate-1:1 MAP: one input, one output.
const Map1 = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// A SINK: input only, no output port.
const Sink = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        _ = self;
        _ = in;
    }
};

/// A 2-input adder (fan-in): wired with MapInPortAt(Sum2, 0) / (Sum2, 1).
const Sum2 = struct {
    const Self = @This();
    pub fn process(self: *Self, in0: []const Sample(f32), in1: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (in0, in1, out) |x, y, *o| o.ch[0] = x.ch[0] + y.ch[0];
    }
};

/// A delay element: declares `delay_len`, so a feedback cycle through it is
/// causal. 1-in / 1-out otherwise.
fn DelayLine(comptime L: usize) type {
    return struct {
        const Self = @This();
        pub const delay_len: usize = L;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
}

// --- ports (terse aliases) -------------------------------------------------
const SrcOut = pan.port.MapOutPort(Src);
const Map1In = pan.port.MapInPort(Map1);
const Map1Out = pan.port.MapOutPort(Map1);
const SinkIn = pan.port.MapInPort(Sink);
const Sum2In0 = pan.port.MapInPortAt(Sum2, 0);
const Sum2In1 = pan.port.MapInPortAt(Sum2, 1);
const Sum2Out = pan.port.MapOutPort(Sum2);

// =====================================================================
// L1 — TOPO + DETERMINISM
// =====================================================================

test "L1: a straight source→map→sink chain is one op per node in forward order" {
    // The op-list is observed positionally: the source (no inputs) must be first,
    // the sink (no outputs) last — that ordering is the whole point of the topo.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = 64;
        const s = gg.add(Src);
        const m = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, Map1In, m, 0);
        gg.connect(Map1Out, m, 0, SinkIn, k, 0);
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 3), plan.op_count);
    // position 0 = the source: zero inputs, one output.
    try expectEqual(@as(usize, 0), plan.ops[0].input_count);
    try expectEqual(@as(usize, 1), plan.ops[0].output_count);
    // position 1 = the map: one in, one out.
    try expectEqual(@as(usize, 1), plan.ops[1].input_count);
    try expectEqual(@as(usize, 1), plan.ops[1].output_count);
    // position 2 = the sink: one in, zero out.
    try expectEqual(@as(usize, 1), plan.ops[2].input_count);
    try expectEqual(@as(usize, 0), plan.ops[2].output_count);
}

test "L1: re-committing the identical graph yields a byte-identical plan (determinism)" {
    // Determinism is the load-bearing property: the same graph must NEVER produce
    // two different op-lists. We pin EVERY observable field of EVERY op equal.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = 128;
        const s = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, Map1In, a, 0);
        gg.connect(Map1Out, a, 0, Map1In, b, 0);
        gg.connect(Map1Out, b, 0, SinkIn, k, 0);
        break :blk gg;
    };
    const p1 = comptime try pan.commitComptime(g);
    const p2 = comptime try pan.commitComptime(g);
    try expectEqual(p1.op_count, p2.op_count);
    try expectEqual(p1.footprint_bytes, p2.footprint_bytes);
    inline for (0..4) |i| {
        try expectEqual(p1.ops[i].input_count, p2.ops[i].input_count);
        try expectEqual(p1.ops[i].output_count, p2.ops[i].output_count);
        try expectEqual(p1.ops[i].n_or_pull_spec, p2.ops[i].n_or_pull_spec);
        try expectEqual(
            p1.ops[i].input_buffer_ids[0..p1.ops[i].input_count].*,
            p2.ops[i].input_buffer_ids[0..p2.ops[i].input_count].*,
        );
        try expectEqual(
            p1.ops[i].output_buffer_ids[0..p1.ops[i].output_count].*,
            p2.ops[i].output_buffer_ids[0..p2.ops[i].output_count].*,
        );
    }
}

test "L1: a reconvergent diamond is ACCEPTED — reconvergence is not a cycle" {
    // src fans out to a and b; a and b reconverge into a 2-input mix. A naive
    // cycle detector that confuses "two paths meet" with "a path loops" would
    // wrongly reject this. It must commit to 5 ops.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const src = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const mix = gg.add(Sum2);
        const k = gg.add(Sink);
        gg.connect(SrcOut, src, 0, Map1In, a, 0);
        gg.connect(SrcOut, src, 0, Map1In, b, 0); // fan-out from one output
        gg.connect(Map1Out, a, 0, Sum2In0, mix, 0);
        gg.connect(Map1Out, b, 0, Sum2In1, mix, 1);
        gg.connect(Sum2Out, mix, 0, SinkIn, k, 0);
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 5), plan.op_count);
    // The mix node has two distinct inputs and one output — its op records both.
    // It sits at position 3 (after src=0, a=1, b=2 by the min-id tie-break).
    try expectEqual(@as(usize, 2), plan.ops[3].input_count);
    try expectEqual(@as(usize, 1), plan.ops[3].output_count);
    // The two reconverging branches feed DISTINCT pool buffers into the mix:
    // a's value and b's value are different live ranges, so different ids.
    try expect(plan.ops[3].input_buffer_ids[0] != plan.ops[3].input_buffer_ids[1]);
}

test "L1: the min-node-id tie-break orders independent ready nodes by insertion id" {
    // Two independent sources, each → its own sink. Nothing constrains the
    // relative order of the two chains EXCEPT the tie-break, which is lowest id.
    // src0(id0) and src1(id2) are both ready at the start; min-id picks src0
    // first. So position 0 is a source (id0), and the order is fully pinned.
    // We probe it through the per-op port profile sequence, which must be the
    // deterministic [source, source, sink, sink] interleave the tie-break forces:
    //   ready set start = {0:src, 2:src}; pick 0 (src) → its consumer 1:sink
    //   becomes ready = {1:sink, 2:src}; min-id picks 1 (sink) → ...
    // i.e. each source is immediately followed by draining toward its sink only
    // when that sink is the new minimum. With ids 0,1,2,3 the deterministic
    // sequence is: src0, sink1, src2, sink3.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const s0 = gg.add(Src); // id 0
        const k0 = gg.add(Sink); // id 1
        const s1 = gg.add(Src); // id 2
        const k1 = gg.add(Sink); // id 3
        gg.connect(SrcOut, s0, 0, SinkIn, k0, 0);
        gg.connect(SrcOut, s1, 0, SinkIn, k1, 0);
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 4), plan.op_count);
    // Deterministic interleave forced by lowest-id tie-break: src,sink,src,sink.
    try expectEqual(@as(usize, 0), plan.ops[0].input_count); // src0
    try expectEqual(@as(usize, 1), plan.ops[0].output_count);
    try expectEqual(@as(usize, 1), plan.ops[1].input_count); // sink1
    try expectEqual(@as(usize, 0), plan.ops[1].output_count);
    try expectEqual(@as(usize, 0), plan.ops[2].input_count); // src2
    try expectEqual(@as(usize, 1), plan.ops[2].output_count);
    try expectEqual(@as(usize, 1), plan.ops[3].input_count); // sink3
    try expectEqual(@as(usize, 0), plan.ops[3].output_count);
}

test "L1: a longer linear chain places every node in strict topo order" {
    // src → m0 → m1 → m2 → m3 → sink (6 nodes). A linear graph has a unique
    // topo order regardless of tie-break; pin that source is first, sink last,
    // and every interior node is a 1-in/1-out map.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const s = gg.add(Src);
        var prev = s;
        var maps: [4]usize = undefined;
        for (0..4) |i| {
            maps[i] = gg.add(Map1);
            gg.connect(if (i == 0) SrcOut else Map1Out, prev, 0, Map1In, maps[i], 0);
            prev = maps[i];
        }
        const k = gg.add(Sink);
        gg.connect(Map1Out, prev, 0, SinkIn, k, 0);
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 6), plan.op_count);
    try expectEqual(@as(usize, 0), plan.ops[0].input_count); // source first
    try expectEqual(@as(usize, 0), plan.ops[5].output_count); // sink last
    inline for (1..5) |i| {
        try expectEqual(@as(usize, 1), plan.ops[i].input_count);
        try expectEqual(@as(usize, 1), plan.ops[i].output_count);
    }
}

test "L1: fan-out shares ONE output buffer across all consumers (dedupe)" {
    // src → {a, b}: the source's single output value is read by two consumers,
    // so the emit stage must record exactly ONE output buffer id for the source,
    // not two. (This is the buffer-dedupe observation, distinct from the diamond.)
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const src = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const ka = gg.add(Sink);
        const kb = gg.add(Sink);
        gg.connect(SrcOut, src, 0, Map1In, a, 0);
        gg.connect(SrcOut, src, 0, Map1In, b, 0);
        gg.connect(Map1Out, a, 0, SinkIn, ka, 0);
        gg.connect(Map1Out, b, 0, SinkIn, kb, 0);
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 5), plan.op_count);
    // position 0 is the source (min id): its fan-out is a single output buffer.
    try expectEqual(@as(usize, 0), plan.ops[0].input_count);
    try expectEqual(@as(usize, 1), plan.ops[0].output_count);
}

// =====================================================================
// L2 — UndeclaredCycle (ordinary back-edges survive the topo sort)
// =====================================================================

test "L2: a plain self-loop (ordinary edge) is error.UndeclaredCycle" {
    // A map whose ordinary output is wired straight back to its own input.
    // It is its own predecessor, so Kahn never reaches indegree 0 for it.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const m = gg.add(Map1);
        gg.connect(Map1Out, m, 0, Map1In, m, 0); // ordinary self-loop
        break :blk gg;
    };
    try expectError(error.UndeclaredCycle, comptime pan.commitComptime(g));
}

test "L2: a length-2 ordinary cycle (a→b→a) is error.UndeclaredCycle" {
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        gg.connect(Map1Out, a, 0, Map1In, b, 0);
        gg.connect(Map1Out, b, 0, Map1In, a, 0); // ordinary back-wire
        break :blk gg;
    };
    try expectError(error.UndeclaredCycle, comptime pan.commitComptime(g));
}

test "L2: a length-3 ordinary cycle (a→b→c→a) is error.UndeclaredCycle" {
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const c = gg.add(Map1);
        gg.connect(Map1Out, a, 0, Map1In, b, 0);
        gg.connect(Map1Out, b, 0, Map1In, c, 0);
        gg.connect(Map1Out, c, 0, Map1In, a, 0); // closes the 3-cycle
        break :blk gg;
    };
    try expectError(error.UndeclaredCycle, comptime pan.commitComptime(g));
}

test "L2: an ordinary cycle dangling off an acyclic prefix still rejects" {
    // src → a → b → c → b (an ordinary back-edge c→b forms a 2-cycle {b,c}).
    // The acyclic prefix src→a does not save it: a surviving cycle is fatal.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const src = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const c = gg.add(Map1);
        gg.connect(SrcOut, src, 0, Map1In, a, 0);
        gg.connect(Map1Out, a, 0, Map1In, b, 0);
        gg.connect(Map1Out, b, 0, Map1In, c, 0);
        gg.connect(Map1Out, c, 0, Map1In, b, 0); // ordinary back-edge into b
        break :blk gg;
    };
    try expectError(error.UndeclaredCycle, comptime pan.commitComptime(g));
}

test "L2: a delay element does NOT rescue an ORDINARY cycle (only feedback does)" {
    // Same 2-cycle as before but one node is a delay element, wired with an
    // ORDINARY edge (not connectFeedback). The delay-free-loop relief is keyed
    // to the topo-sort surviving — but an ordinary cycle never survives topo, so
    // it is rejected as UndeclaredCycle BEFORE the SCC-delay check ever runs.
    // The author forgot to DECLARE the loop as feedback; a delay alone is not
    // the declaration.
    const Del = DelayLine(8);
    const DelIn = pan.port.MapInPort(Del);
    const DelOut = pan.port.MapOutPort(Del);
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const a = gg.add(Map1);
        const d = gg.add(Del);
        gg.connect(Map1Out, a, 0, DelIn, d, 0);
        gg.connect(DelOut, d, 0, Map1In, a, 0); // ORDINARY back-edge
        break :blk gg;
    };
    try expectError(error.UndeclaredCycle, comptime pan.commitComptime(g));
}

// =====================================================================
// L3 — UnrootedPath (source-rooted SR3)
// =====================================================================

test "L3: a Map head with an unfed input port is error.UnrootedPath" {
    // m has an input port but nothing produces for it; it is a Kahn seed
    // (indegree 0) that is NOT a source.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const m = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(Map1Out, m, 0, SinkIn, k, 0);
        break :blk gg;
    };
    try expectError(error.UnrootedPath, comptime pan.commitComptime(g));
}

test "L3: a Sink with no producer (a lone, unfed sink) is error.UnrootedPath" {
    // A bare sink is a path head with an input port and no source feeding it.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        _ = gg.add(Sink);
        break :blk gg;
    };
    try expectError(error.UnrootedPath, comptime pan.commitComptime(g));
}

test "L3: a 2-input adder fed by only ONE source is unrooted on the other port" {
    // mix has two input ports. Wire a source to in0 but leave in1 unfed. mix
    // still has indegree>0 (one edge), so it is NOT a Kahn seed — but the SOURCE
    // is the head and is fine; the issue is that in1 has no producer. Whether
    // the pass flags this depends on its rooting model: it checks Kahn SEEDS,
    // and a partially-fed node is not a seed. So this graph is ACCEPTED at the
    // structural level (per-port completeness is a separate, later concern).
    // We pin the OBSERVED behavior: it commits (no UnrootedPath here).
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const src = gg.add(Src);
        const mix = gg.add(Sum2);
        const k = gg.add(Sink);
        gg.connect(SrcOut, src, 0, Sum2In0, mix, 0); // only in0 fed
        gg.connect(Sum2Out, mix, 0, SinkIn, k, 0);
        break :blk gg;
    };
    // Documented observation: the SR3 check is over Kahn seeds, and mix is not a
    // seed (it has one incoming edge), so this commits rather than raising
    // UnrootedPath. (A per-input-port completeness check is out of scope here.)
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 3), plan.op_count);
}

test "L3: a graph correctly rooted at a Source is accepted" {
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const s = gg.add(Src);
        const m = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, Map1In, m, 0);
        gg.connect(Map1Out, m, 0, SinkIn, k, 0);
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 3), plan.op_count);
}

test "L3: a lone Source (no edges) is a rooted, accepted, single-op plan" {
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        _ = gg.add(Src);
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 1), plan.op_count);
    try expectEqual(@as(usize, 0), plan.ops[0].input_count);
    try expectEqual(@as(usize, 0), plan.footprint_bytes); // no edges → no pool
}

test "L3: TWO independent sources both root cleanly (multiple roots are fine)" {
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const s0 = gg.add(Src);
        const s1 = gg.add(Src);
        const k0 = gg.add(Sink);
        const k1 = gg.add(Sink);
        gg.connect(SrcOut, s0, 0, SinkIn, k0, 0);
        gg.connect(SrcOut, s1, 0, SinkIn, k1, 0);
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 4), plan.op_count);
}

test "L3: a delay element at a path head is unrooted (it has a real input)" {
    // A delay is NOT a source — it has a genuine sample input. Putting one at the
    // head (nothing feeding it) must be rejected: a delay needs a producer.
    const Del = DelayLine(4);
    const DelIn = pan.port.MapInPort(Del);
    const DelOut = pan.port.MapOutPort(Del);
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const d = gg.add(Del);
        const k = gg.add(Sink);
        gg.connect(DelOut, d, 0, SinkIn, k, 0);
        _ = DelIn; // the input port exists but is unfed → unrooted head
        break :blk gg;
    };
    try expectError(error.UnrootedPath, comptime pan.commitComptime(g));
}

// =====================================================================
// L4 — DelayFreeLoop vs accept (SCC-has-delay on the FULL graph)
// =====================================================================

test "L4: a DECLARED feedback self-loop with NO delay is error.DelayFreeLoop" {
    // Source → map, and map's output fed back to its own input via a DECLARED
    // feedback edge. The cycle is the single map node — no delay in it.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const s = gg.add(Src);
        const m = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, Map1In, m, 0);
        gg.connect(Map1Out, m, 0, SinkIn, k, 0);
        gg.connectFeedback(Map1Out, m, 0, Map1In, m, 0); // declared self-feedback
        break :blk gg;
    };
    try expectError(error.DelayFreeLoop, comptime pan.commitComptime(g));
}

test "L4: a DECLARED feedback self-loop THROUGH a delay element is accepted" {
    // The crisp dual of the previous test: the ONLY difference is that the looped
    // node is a delay element, which makes the cycle causal.
    const Del = DelayLine(16);
    const DelIn = pan.port.MapInPort(Del);
    const DelOut = pan.port.MapOutPort(Del);
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = 32;
        const s = gg.add(Src);
        const d = gg.add(Del);
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, DelIn, d, 0);
        gg.connect(DelOut, d, 0, SinkIn, k, 0);
        gg.connectFeedback(DelOut, d, 0, DelIn, d, 0); // feedback through the delay
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 3), plan.op_count);
    // Footprint includes the delay ring (16 elems · 4 bytes) plus the pool.
    try expect(plan.footprint_bytes > 16 * @sizeOf(Sample(f32)));
}

test "L4: a multi-node feedback SCC with no delay is error.DelayFreeLoop" {
    // src → sum → gain ──feedback──→ sum. The feedback SCC is {sum, gain}, two
    // nodes, no delay among them. (Mirrors worked example C, broadened by being
    // explicit that the SCC spans two nodes.)
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const s = gg.add(Src);
        const sum = gg.add(Map1);
        const gain = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, Map1In, sum, 0);
        gg.connect(Map1Out, sum, 0, Map1In, gain, 0);
        gg.connect(Map1Out, gain, 0, SinkIn, k, 0);
        gg.connectFeedback(Map1Out, gain, 0, Map1In, sum, 0); // declared feedback
        break :blk gg;
    };
    try expectError(error.DelayFreeLoop, comptime pan.commitComptime(g));
}

test "L4: a multi-node feedback SCC WITH a delay inside it is accepted" {
    // Same SCC topology as above but with a delay element on the loop path:
    // src → sum → delay → gain ──feedback──→ sum. The SCC {sum, delay, gain}
    // now holds a delay → causal → accepted.
    const Del = DelayLine(64);
    const DelIn = pan.port.MapInPort(Del);
    const DelOut = pan.port.MapOutPort(Del);
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        gg.block_size = 256;
        const s = gg.add(Src);
        const sum = gg.add(Map1);
        const d = gg.add(Del);
        const gain = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, Map1In, sum, 0);
        gg.connect(Map1Out, sum, 0, DelIn, d, 0);
        gg.connect(DelOut, d, 0, Map1In, gain, 0);
        gg.connect(Map1Out, gain, 0, SinkIn, k, 0);
        gg.connectFeedback(Map1Out, gain, 0, Map1In, sum, 0); // declared feedback
        break :blk gg;
    };
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 5), plan.op_count);
    try expect(plan.footprint_bytes > 64 * @sizeOf(Sample(f32))); // ring contributes
}

test "L4: the delay must be INSIDE the cycle — a delay off the loop does not rescue it" {
    // src → sum → gain ──feedback──→ sum  (delay-free cycle {sum, gain}),
    // PLUS a delay hanging off gain toward the sink. The delay is reachable from
    // the cycle but is NOT mutually reachable (it is downstream only), so it is
    // not in the SCC. The loop is still delay-free → rejected.
    const Del = DelayLine(32);
    const DelIn = pan.port.MapInPort(Del);
    const DelOut = pan.port.MapOutPort(Del);
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const s = gg.add(Src);
        const sum = gg.add(Map1);
        const gain = gg.add(Map1);
        const d = gg.add(Del); // delay OFF the loop, downstream
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, Map1In, sum, 0);
        gg.connect(Map1Out, sum, 0, Map1In, gain, 0);
        gg.connect(Map1Out, gain, 0, DelIn, d, 0); // gain → delay (not back to sum)
        gg.connect(DelOut, d, 0, SinkIn, k, 0);
        gg.connectFeedback(Map1Out, gain, 0, Map1In, sum, 0); // delay-free feedback
        break :blk gg;
    };
    try expectError(error.DelayFreeLoop, comptime pan.commitComptime(g));
}

// =====================================================================
// L5 — THE ERROR TAXONOMY IS DISTINCT
// =====================================================================

test "L5: structurally similar 3-node loops fire THREE distinct errors" {
    // Same node trio (sum, gain) closed three different ways; each must raise its
    // own error and none of the other two. This is the taxonomy-separation law:
    // the discriminator is HOW the loop/head is wired, not its shape.

    // (a) ORDINARY back-edge → UndeclaredCycle.
    const undeclared = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const s = gg.add(Src);
        const sum = gg.add(Map1);
        const gain = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, Map1In, sum, 0);
        gg.connect(Map1Out, sum, 0, Map1In, gain, 0);
        gg.connect(Map1Out, gain, 0, SinkIn, k, 0);
        gg.connect(Map1Out, gain, 0, Map1In, sum, 0); // ORDINARY
        break :blk gg;
    };
    try expectError(error.UndeclaredCycle, comptime pan.commitComptime(undeclared));

    // (b) DECLARED feedback, no delay → DelayFreeLoop (NOT UndeclaredCycle).
    const delayfree = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const s = gg.add(Src);
        const sum = gg.add(Map1);
        const gain = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(SrcOut, s, 0, Map1In, sum, 0);
        gg.connect(Map1Out, sum, 0, Map1In, gain, 0);
        gg.connect(Map1Out, gain, 0, SinkIn, k, 0);
        gg.connectFeedback(Map1Out, gain, 0, Map1In, sum, 0); // DECLARED
        break :blk gg;
    };
    try expectError(error.DelayFreeLoop, comptime pan.commitComptime(delayfree));

    // (c) non-source head → UnrootedPath (NOT a cycle error at all).
    const unrooted = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const sum = gg.add(Map1); // head, unfed → unrooted
        const gain = gg.add(Map1);
        const k = gg.add(Sink);
        gg.connect(Map1Out, sum, 0, Map1In, gain, 0);
        gg.connect(Map1Out, gain, 0, SinkIn, k, 0);
        break :blk gg;
    };
    try expectError(error.UnrootedPath, comptime pan.commitComptime(unrooted));
}

test "L5: an UndeclaredCycle is reported even when its node is unrooted-ish" {
    // a→b→a is a pure ordinary 2-cycle with NO source anywhere. Both "no source"
    // and "cycle" are true, but the topo sort runs (stage 2) before the SR3
    // check (stage 3), and a surviving cycle means topo never completes — so the
    // cycle error wins. Pin that ordering: UndeclaredCycle, not UnrootedPath.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        gg.connect(Map1Out, a, 0, Map1In, b, 0);
        gg.connect(Map1Out, b, 0, Map1In, a, 0);
        break :blk gg;
    };
    try expectError(error.UndeclaredCycle, comptime pan.commitComptime(g));
}

// =====================================================================
// L6 — MALFORMED BOUNDARIES (hand-built raw edges)
// =====================================================================

test "L6: an edge to an out-of-range to_node is error.MalformedGraph" {
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        _ = gg.add(Src);
        gg.edges[gg.edge_count] = .{
            .from_node = 0,
            .from_port = 0,
            .to_node = 7, // no such node (only node 0 exists)
            .to_port = 0,
            .feedback = false,
            .elem_size = @sizeOf(Sample(f32)),
            .elem_name = "Frame(f32,mono)",
        };
        gg.edge_count += 1;
        break :blk gg;
    };
    try expectError(error.MalformedGraph, comptime pan.commitComptime(g));
}

test "L6: an edge from an out-of-range from_node is error.MalformedGraph" {
    // The dual of the above: the SOURCE endpoint is out of range.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        _ = gg.add(Sink);
        gg.edges[gg.edge_count] = .{
            .from_node = 5, // no such node
            .from_port = 0,
            .to_node = 0,
            .to_port = 0,
            .feedback = false,
            .elem_size = @sizeOf(Sample(f32)),
            .elem_name = "Frame(f32,mono)",
        };
        gg.edge_count += 1;
        break :blk gg;
    };
    try expectError(error.MalformedGraph, comptime pan.commitComptime(g));
}

test "L6: more than 8 edges out of one node is error.PortCeilingExceeded" {
    // out_degree of a single node climbs past the 8-port-per-direction ceiling.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const src = gg.add(Src);
        var sinks: [9]usize = undefined;
        for (0..9) |i| sinks[i] = gg.add(Sink);
        for (0..9) |i| {
            gg.edges[gg.edge_count] = .{
                .from_node = src,
                .from_port = @intCast(i % 8),
                .to_node = sinks[i],
                .to_port = 0,
                .feedback = false,
                .elem_size = @sizeOf(Sample(f32)),
                .elem_name = "Frame(f32,mono)",
            };
            gg.edge_count += 1;
        }
        break :blk gg;
    };
    try expectError(error.PortCeilingExceeded, comptime pan.commitComptime(g));
}

test "L6: more than 8 edges INTO one node is error.PortCeilingExceeded" {
    // The in-degree dual: nine sources all fanning into one node's input side.
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        const k = gg.add(Sink);
        var srcs: [9]usize = undefined;
        for (0..9) |i| srcs[i] = gg.add(Src);
        for (0..9) |i| {
            gg.edges[gg.edge_count] = .{
                .from_node = srcs[i],
                .from_port = 0,
                .to_node = k,
                .to_port = @intCast(i % 8),
                .feedback = false,
                .elem_size = @sizeOf(Sample(f32)),
                .elem_name = "Frame(f32,mono)",
            };
            gg.edge_count += 1;
        }
        break :blk gg;
    };
    try expectError(error.PortCeilingExceeded, comptime pan.commitComptime(g));
}

test "L6: port index 7 is the LAST legal port — the ceiling boundary commits" {
    // The validate stage also guards the port index itself. A raw edge whose
    // to_port is >= max_ports_per_direction must be PortCeilingExceeded.
    // (port indices are u3 in the IR, so the max representable is 7; the guard
    // is `>= max_ports_per_direction`. We push exactly to the ceiling value via
    // a node count large enough to keep from_node/to_node in range.)
    const g = comptime blk: {
        var gg = pan.graph.Graph.empty;
        _ = gg.add(Src);
        _ = gg.add(Sink);
        gg.edges[gg.edge_count] = .{
            .from_node = 0,
            .from_port = 7, // max valid u3
            .to_node = 1,
            .to_port = 7, // also max valid; under the ceiling (8), so this PASSES the port guard
            .feedback = false,
            .elem_size = @sizeOf(Sample(f32)),
            .elem_name = "Frame(f32,mono)",
        };
        gg.edge_count += 1;
        break :blk gg;
    };
    // port 7 is the last LEGAL port (ceiling is 8, guard is `>=`), so this graph
    // does NOT trip PortCeilingExceeded on the index. It trips nothing on stage 1
    // and proceeds — the source roots it, no cycle — so it commits. We pin that
    // the boundary value 7 is accepted (the off-by-one boundary of the ceiling).
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 2), plan.op_count);
}

// =====================================================================
// DEGENERATE BOUNDARY
// =====================================================================

test "boundary: the empty graph commits to an empty plan" {
    const g = comptime pan.graph.Graph.empty;
    const plan = comptime try pan.commitComptime(g);
    try expectEqual(@as(usize, 0), plan.op_count);
    try expectEqual(@as(usize, 0), plan.footprint_bytes);
}
