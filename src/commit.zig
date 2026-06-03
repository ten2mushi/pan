//! The graph-commit pass — SKELETON, comptime-evaluable.
//!
//! The full pipeline is: topological sort (the DAG with feedback edges removed)
//! → liveness → per-element-class buffer coloring → delay-free-cycle check →
//! plugin-delay compensation → buffer-id assignment → emit the render op-list +
//! the static footprint.
//!
//! This skeleton implements only: edge validation, the >8-port rejection,
//! delay-free-cycle detection (`error.DelayFreeLoop`), per-edge buffer
//! assignment (MODE B = one buffer per edge — the obviously-correct baseline),
//! and a `footprint_bytes` that is a comptime constant for a comptime graph (the
//! bounded-static-memory guarantee the embedded profile relies on).
//!
//! TODO: optimal interval coloring (the left-edge algorithm) replacing MODE B,
//! and the plugin-delay-compensation longest-path pass.

const std = @import("std");
const graph = @import("graph.zig");
const port = @import("port.zig");

/// One render op. `fn_ptr`/`self_ptr` are erased; the hot path replays
/// `op.fn_ptr(op.self_ptr, gather(inputs), scatter(outputs), n)`.
pub const RenderOp = struct {
    /// Monomorphized Map/Rate kernel entry (erased). Optional in the skeleton
    /// because stub graphs may carry no bound kernel yet.
    fn_ptr: ?*const anyopaque,
    self_ptr: ?*anyopaque,
    /// Buffer ids into the per-element-class pools (MODE B: one id per edge).
    input_buffer_ids: [port.max_ports_per_direction]usize,
    input_count: usize,
    output_buffer_ids: [port.max_ports_per_direction]usize,
    output_count: usize,
    /// `n` (Map) or a pull spec (Rate). Skeleton carries the node id as a tag.
    n_or_pull_spec: usize,
};

/// The committed plan: a flat op-list + the static footprint.
pub fn Plan(comptime n_ops: usize) type {
    return struct {
        ops: [n_ops]RenderOp,
        op_count: usize,
        /// The static render-memory bound — a comptime constant for a comptime
        /// graph. MODE B: the sum over edges of element_size · element_count.
        footprint_bytes: usize,
    };
}

pub const CommitError = error{
    /// A feedback cycle whose strongly-connected component contains no delay
    /// element (proven ⊢ — a delay-free loop is not causal).
    DelayFreeLoop,
    /// More than 8 ports on a direction (proven ⊢; also caught at port mint).
    PortCeilingExceeded,
    /// Edge endpoints reference out-of-range nodes (malformed graph).
    MalformedGraph,
};

/// Commit a graph at COMPTIME. Returns a `Plan` whose `footprint_bytes` is a
/// comptime constant. The whole body is comptime-evaluable: that the build
/// compiles is itself the discharge of the comptime-commit obligation for this
/// graph (the embedded "same code, specialized" promise in miniature).
pub fn commitComptime(comptime g: graph.Graph) CommitError!Plan(g.edge_count) {
    comptime {
        // --- validate edges & port ceiling --------------------------------
        var in_degree: [graph.max_nodes]usize = [_]usize{0} ** graph.max_nodes;
        var out_degree: [graph.max_nodes]usize = [_]usize{0} ** graph.max_nodes;
        for (g.edges[0..g.edge_count]) |e| {
            if (e.from_node >= g.node_count or e.to_node >= g.node_count)
                return error.MalformedGraph;
            if (e.from_port >= port.max_ports_per_direction or
                e.to_port >= port.max_ports_per_direction)
                return error.PortCeilingExceeded;
            out_degree[e.from_node] += 1;
            in_degree[e.to_node] += 1;
            if (out_degree[e.from_node] > port.max_ports_per_direction or
                in_degree[e.to_node] > port.max_ports_per_direction)
                return error.PortCeilingExceeded;
        }

        // --- delay-free-cycle detection on the DAG minus feedback edges -----
        // A back-edge is legal only if its cycle contains a delay element, and
        // the topological sort runs on the graph with feedback edges removed. In
        // this skeleton a `feedback` flag *is* the declared delay (a UnitDelay /
        // DelayLine sits on that edge). So after removing feedback edges the
        // remainder must be acyclic; any cycle that survives is a delay-free
        // loop, which is not causal → error.DelayFreeLoop.
        try rejectDelayFreeCycle(g);

        // --- buffer-id assignment (pool MODE B: one buffer per edge) --------
        // TODO: replace with per-element-class interval coloring (the left-edge
        // algorithm, optimal in colors used). MODE B (one buffer per edge) is
        // the obviously-correct baseline the colored-pool path is differenced
        // against.
        var ops: [g.edge_count]RenderOp = undefined;
        var footprint: usize = 0;
        for (g.edges[0..g.edge_count], 0..) |e, i| {
            // MODE B: edge i owns buffer i. The per-edge element_count is 1 in
            // the skeleton; footprint = sum of element_size · element_count.
            footprint += e.elem_size;
            var in_ids: [port.max_ports_per_direction]usize = undefined;
            var out_ids: [port.max_ports_per_direction]usize = undefined;
            in_ids[0] = i;
            out_ids[0] = i;
            ops[i] = .{
                .fn_ptr = null, // stub kernel (empty kernels are allowed)
                .self_ptr = null,
                .input_buffer_ids = in_ids,
                .input_count = 1,
                .output_buffer_ids = out_ids,
                .output_count = 1,
                .n_or_pull_spec = e.from_node,
            };
        }

        return Plan(g.edge_count){
            .ops = ops,
            .op_count = g.edge_count,
            .footprint_bytes = footprint,
        };
    }
}

/// Reject any cycle that survives removal of the declared feedback edges
/// (proven ⊢ — `error.DelayFreeLoop`; a loop with no delay is not causal).
/// DFS-based cycle detection on the non-feedback sub-graph (comptime-evaluable).
fn rejectDelayFreeCycle(comptime g: graph.Graph) CommitError!void {
    comptime {
        const White = 0;
        const Gray = 1;
        const Black = 2;
        var color: [graph.max_nodes]u8 = [_]u8{White} ** graph.max_nodes;

        // Iterative DFS with an explicit stack (no recursion depth surprises at
        // comptime). Each frame tracks the next outgoing edge to scan.
        const Frame = struct { node: usize, edge_cursor: usize };
        for (0..g.node_count) |start| {
            if (color[start] != White) continue;
            var stack: [graph.max_nodes]Frame = undefined;
            var sp: usize = 0;
            stack[sp] = .{ .node = start, .edge_cursor = 0 };
            sp += 1;
            color[start] = Gray;
            while (sp > 0) {
                const top = &stack[sp - 1];
                var advanced = false;
                var ec = top.edge_cursor;
                while (ec < g.edge_count) : (ec += 1) {
                    const e = g.edges[ec];
                    if (e.feedback) continue; // back-edge removed (it has a delay)
                    if (e.from_node != top.node) continue;
                    top.edge_cursor = ec + 1;
                    const dst = e.to_node;
                    if (color[dst] == Gray) {
                        // A non-feedback edge into a node on the current DFS
                        // path => a cycle with no delay in its SCC.
                        return error.DelayFreeLoop;
                    }
                    if (color[dst] == White) {
                        color[dst] = Gray;
                        stack[sp] = .{ .node = dst, .edge_cursor = 0 };
                        sp += 1;
                        advanced = true;
                        break;
                    }
                    // Black: already fully explored, skip.
                }
                if (!advanced and ec >= g.edge_count) {
                    color[top.node] = Black;
                    sp -= 1;
                }
            }
        }
    }
}

test "commit assigns per-edge buffers and a comptime footprint > 0" {
    const types = @import("types.zig");
    const Gain = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Gain);
        const b = gg.add(Gain);
        gg.connect(port.MapOutPort(Gain), a, 0, port.MapInPort(Gain), b, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expect(plan.footprint_bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), plan.op_count);
}

test "commit rejects a delay-free cycle with error.DelayFreeLoop (⊢ A4)" {
    const types = @import("types.zig");
    const Gain = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Gain);
        const b = gg.add(Gain);
        gg.connect(port.MapOutPort(Gain), a, 0, port.MapInPort(Gain), b, 0);
        // Plain (non-feedback) back-wire b -> a: a delay-free cycle.
        gg.connect(port.MapOutPort(Gain), b, 0, port.MapInPort(Gain), a, 0);
        break :blk gg;
    };
    try std.testing.expectError(error.DelayFreeLoop, comptime commitComptime(g));
}

test "a cycle WITH a declared feedback edge is accepted (catalog §5.2)" {
    const types = @import("types.zig");
    const Gain = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const types.Sample(f32), out: []types.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Gain);
        const b = gg.add(Gain);
        gg.connect(port.MapOutPort(Gain), a, 0, port.MapInPort(Gain), b, 0);
        // Back-wire as a DECLARED feedback edge (has a delay) — legal.
        gg.connectFeedback(port.MapOutPort(Gain), b, 0, port.MapInPort(Gain), a, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expect(plan.footprint_bytes > 0);
}

// === Yoneda coverage additions =========================================
// The commit pass is observed by callers through the Plan it returns (op_count
// + the comptime-constant footprint_bytes + the per-edge buffer ids) and through
// the CommitError it raises. We characterize it by: footprint = sum of edge
// element sizes (the MODE-B formula), the determinism / comptime-constancy of
// that footprint, op_count == edge_count, the MalformedGraph + cycle errors at
// their boundaries (self-loop, length-3 cycle, the legal diamond DAG), the
// feedback-breaks-the-cycle law, and the empty-graph degenerate case.

const tt = @import("types.zig");

const G32 = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const tt.Sample(f32), out: []tt.Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

fn chain(comptime n_nodes: usize) graph.Graph {
    var g = graph.Graph.empty;
    var ids: [n_nodes]usize = undefined;
    for (0..n_nodes) |i| ids[i] = g.add(G32);
    for (0..n_nodes - 1) |i|
        g.connect(port.MapOutPort(G32), ids[i], 0, port.MapInPort(G32), ids[i + 1], 0);
    return g;
}

test "footprint_bytes is the MODE-B sum Σ edge.elem_size (catalog §7.8)" {
    // A 4-node f32 chain has 3 edges; each Sample(f32) edge is 4 bytes (window
    // element_count = 1 in the skeleton) => footprint == 3 * 4 == 12.
    const g = comptime chain(4);
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 3), plan.op_count);
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(tt.Sample(f32))), plan.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 12), plan.footprint_bytes);
}

test "footprint scales with the element width carried on the edges" {
    // Swap the lane for a stereo f32 frame (8 bytes/edge): the SAME topology
    // doubles the footprint. The footprint tracks the element, not the edge
    // count alone — pinning the Σ element_size formula, not a per-edge constant.
    const Stereo = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const tt.Frame(f32, .stereo), out: []tt.Frame(f32, .stereo)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Stereo);
        const b = gg.add(Stereo);
        const c = gg.add(Stereo);
        gg.connect(port.MapOutPort(Stereo), a, 0, port.MapInPort(Stereo), b, 0);
        gg.connect(port.MapOutPort(Stereo), b, 0, port.MapInPort(Stereo), c, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 2), plan.op_count);
    try std.testing.expectEqual(@as(usize, 2 * 8), plan.footprint_bytes);
}

test "footprint_bytes is a COMPTIME CONSTANT, usable as an array length (H2, §7.8)" {
    // The H2 obligation: footprint must be comptime-known on a comptime graph.
    // Using it as an array length is the proof — only a comptime value is legal
    // there. (Same technique as the smoke gate; pinned independently here.)
    const g = comptime chain(3);
    const plan = comptime try commitComptime(g);
    const buf: [plan.footprint_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(tt.Sample(f32))), buf.len);
}

test "commit is deterministic: re-committing the same graph yields the same plan" {
    // The commit is a pure comptime transform: footprint + op_count are
    // identical across evaluations. A non-deterministic commit would silently
    // move the static-memory bound.
    const g = comptime chain(5);
    const p1 = comptime try commitComptime(g);
    const p2 = comptime try commitComptime(g);
    try std.testing.expectEqual(p1.footprint_bytes, p2.footprint_bytes);
    try std.testing.expectEqual(p1.op_count, p2.op_count);
    try std.testing.expectEqual(@as(usize, 4), p1.op_count);
}

test "op_count equals edge_count; each op gets its own MODE-B buffer ids" {
    const g = comptime chain(3);
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(g.edge_count, plan.op_count);
    // MODE B: edge i owns buffer i on both its input and output slot 0.
    try std.testing.expectEqual(@as(usize, 0), plan.ops[0].input_buffer_ids[0]);
    try std.testing.expectEqual(@as(usize, 0), plan.ops[0].output_buffer_ids[0]);
    try std.testing.expectEqual(@as(usize, 1), plan.ops[1].input_buffer_ids[0]);
    try std.testing.expectEqual(@as(usize, 1), plan.ops[1].output_buffer_ids[0]);
    // Skeleton kernels are erased/unbound (fn_ptr/self_ptr null) and each op
    // carries exactly one input and one output in the per-edge window.
    try std.testing.expect(plan.ops[0].fn_ptr == null);
    try std.testing.expectEqual(@as(usize, 1), plan.ops[0].input_count);
    try std.testing.expectEqual(@as(usize, 1), plan.ops[0].output_count);
}

test "the empty graph commits to an empty plan (degenerate boundary)" {
    const g = comptime graph.Graph.empty;
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 0), plan.op_count);
    try std.testing.expectEqual(@as(usize, 0), plan.footprint_bytes);
}

test "a single Map node with no edges commits to a zero-footprint plan" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        _ = gg.add(G32);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 0), plan.op_count);
    try std.testing.expectEqual(@as(usize, 0), plan.footprint_bytes);
}

test "a self-loop with no feedback flag is a delay-free cycle (⊢ A4)" {
    // The tightest cycle: a node wired to itself, no delay declared.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(G32);
        gg.connect(port.MapOutPort(G32), a, 0, port.MapInPort(G32), a, 0);
        break :blk gg;
    };
    try std.testing.expectError(error.DelayFreeLoop, comptime commitComptime(g));
}

test "a length-3 delay-free cycle is rejected (cycle detection is not 2-only)" {
    // a -> b -> c -> a, all plain edges: the DFS must find the longer back-edge.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(G32);
        const b = gg.add(G32);
        const c = gg.add(G32);
        gg.connect(port.MapOutPort(G32), a, 0, port.MapInPort(G32), b, 0);
        gg.connect(port.MapOutPort(G32), b, 0, port.MapInPort(G32), c, 0);
        gg.connect(port.MapOutPort(G32), c, 0, port.MapInPort(G32), a, 0);
        break :blk gg;
    };
    try std.testing.expectError(error.DelayFreeLoop, comptime commitComptime(g));
}

test "a diamond DAG (reconvergent, acyclic) is ACCEPTED — no false positive" {
    // a -> b, a -> c, b -> d, c -> d. Reconvergence is NOT a cycle; a correct
    // detector must not flag it. (Guards against a too-eager Gray check.)
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(G32);
        const b = gg.add(G32);
        const c = gg.add(G32);
        const d = gg.add(G32);
        gg.connect(port.MapOutPort(G32), a, 0, port.MapInPort(G32), b, 0);
        gg.connect(port.MapOutPort(G32), a, 1, port.MapInPort(G32), c, 0);
        gg.connect(port.MapOutPort(G32), b, 0, port.MapInPort(G32), d, 0);
        gg.connect(port.MapOutPort(G32), c, 0, port.MapInPort(G32), d, 1);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 4), plan.op_count);
    try std.testing.expectEqual(@as(usize, 4 * @sizeOf(tt.Sample(f32))), plan.footprint_bytes);
}

test "feedback flag breaks the length-3 cycle: the SCC has a delay (catalog §5.2)" {
    // Same a->b->c->a topology, but the back-edge c->a is a DECLARED feedback
    // edge => its SCC contains a delay => legal. This is the exact dual of the
    // length-3 rejection above: the ONLY difference is the feedback flag.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(G32);
        const b = gg.add(G32);
        const c = gg.add(G32);
        gg.connect(port.MapOutPort(G32), a, 0, port.MapInPort(G32), b, 0);
        gg.connect(port.MapOutPort(G32), b, 0, port.MapInPort(G32), c, 0);
        gg.connectFeedback(port.MapOutPort(G32), c, 0, port.MapInPort(G32), a, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    // All 3 edges still appear in the op-list (feedback is removed only for the
    // acyclicity check, not from buffer allocation).
    try std.testing.expectEqual(@as(usize, 3), plan.op_count);
}

test "a malformed edge referencing an out-of-range node => error.MalformedGraph" {
    // Hand-build an edge pointing past node_count (the validator's first guard).
    // We append the bad edge directly to exercise the MalformedGraph branch.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        _ = gg.add(G32); // node 0 only
        gg.edges[gg.edge_count] = .{
            .from_node = 0,
            .from_port = 0,
            .to_node = 7, // no such node
            .to_port = 0,
            .feedback = false,
            .elem_size = @sizeOf(tt.Sample(f32)),
            .elem_name = "Frame(f32,1)",
        };
        gg.edge_count += 1;
        break :blk gg;
    };
    try std.testing.expectError(error.MalformedGraph, comptime commitComptime(g));
}

test "more than 8 edges out of one node => error.PortCeilingExceeded (⊢ A2)" {
    // The degree guard catches a fan-out exceeding the 8-port ceiling even
    // though each individual u3 port index is in range. Build 9 out-edges from
    // node 0 (to distinct sinks) by hand to trip out_degree > 8.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(G32);
        var sinks: [9]usize = undefined;
        for (0..9) |i| sinks[i] = gg.add(G32);
        // 9 edges all leaving `src` (port indices wrap within u3 range; the
        // degree check, not the index check, is what fires).
        for (0..9) |i| {
            gg.edges[gg.edge_count] = .{
                .from_node = src,
                .from_port = @intCast(i % 8),
                .to_node = sinks[i],
                .to_port = 0,
                .feedback = false,
                .elem_size = @sizeOf(tt.Sample(f32)),
                .elem_name = "Frame(f32,1)",
            };
            gg.edge_count += 1;
        }
        break :blk gg;
    };
    try std.testing.expectError(error.PortCeilingExceeded, comptime commitComptime(g));
}
