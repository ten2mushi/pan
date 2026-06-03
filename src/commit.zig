//! The graph→op-list compiler — the commit pass, comptime-evaluable.
//!
//! This turns a committed graph into a flat render op-list plus a single static
//! memory figure. It runs once, off the hot path (at `comptime` on embedded), so
//! the render loop afterwards just replays the op-list with no graph walking.
//!
//! The pipeline, in order:
//!
//!   1. negotiate           — unify the Format of every edge. Element-type
//!                            identity (precision + channel layout + family) is
//!                            already guaranteed by `connect` at compile time, so
//!                            this stage (a) re-asserts that the producer's output
//!                            element equals the element the edge carries (catches
//!                            a malformed edge), (b) DECIDES which coercion morphism
//!                            a non-identical Format would need — a sample-rate
//!                            mismatch wants a resampler, a control (parameter) edge
//!                            wants ramp/hold, a precision/layout change wants a cast
//!                            or a registered up/down-mix matrix — and (c) rejects an
//!                            unregistered/incompatible pair as a hard mismatch. The
//!                            coercion *node bodies* (resampler, mix matrix) are
//!                            materialized by later phases; here is the DECISION and
//!                            the rejection. It also enforces the parameter
//!                            ONE-SOURCE rule: a slot driven by both a wired edge and
//!                            `set`/`schedule` is a commit error.
//!   2. topo (Kahn)         — a total order over the forward DAG (the declared
//!                            feedback edges sit in their own list, satisfied from
//!                            last block's persistent state, so they impose no order).
//!                            Ties break by lowest node id → a bit-reproducible
//!                            op-list. A surviving cycle of forward edges is an
//!                            UNDECLARED cycle → error.UndeclaredCycle.
//!   3. source-rooted check — every path head must be a source (a zero-input
//!                            generator) or a persistent generator, else it has no
//!                            producer for its inputs → error.UnrootedPath.
//!   4. delay-free-loop     — Tarjan's SCC over the FULL graph (forward edges ∪
//!                            feedback edges). Every cycle (a non-trivial SCC, or a
//!                            self-loop) must contain a delay element, else its output
//!                            would depend on itself within the block — not causal →
//!                            error.DelayFreeLoop. Run before buffer assignment so a
//!                            rejected graph halts early.
//!   5. liveness            — each produced value's live range over op indices
//!                            `[producer, last reader]`; persistent state (delay
//!                            rings, feedback read-sides) is pool-excluded.
//!   6. coloring            — buffer-id assignment. MODE-C (`colored`) runs per
//!                            element-class left-edge interval coloring (reuse a
//!                            buffer the moment its last reader has run); MODE-B
//!                            (`per_edge`) gives every value its own buffer (the
//!                            obviously-correct baseline the colored pool is
//!                            differenced against). Across classes never interfere.
//!   7. rate scheduling     — propagate the device demand N upstream through each
//!                            block's rate ratio: a map needs `want` inputs, a rate
//!                            block needs `ceil(want·q/p)` (never assuming the hop
//!                            divides N — the block's ring absorbs the remainder), a
//!                            varirate plans on its worst-case (min-ratio) demand, and
//!                            a source's output length is set by the demand itself.
//!   8. emit                — one render op per node, forward-topo order, gathering
//!                            input buffer ids (forward + feedback read-sides) and
//!                            scattering output buffer ids (forward + feedback writes).
//!   9. footprint           — Σ_class (colors · N · element_size) + Σ_delay
//!                            (ring · element_size) + Σ_block state — one number,
//!                            a comptime constant for a comptime graph.
//!
//! Everything is comptime-evaluable: fixed-size scratch sized by the comptime graph
//! dimensions, bounded loops, no allocator escaping comptime. The colorer's
//! free-buffer table is an `isize` array with a -1 "never used" sentinel. The build
//! compiling the smoke gate in a freestanding ReleaseSmall object is itself the
//! discharge that the pass evaluates at comptime for that graph.

const std = @import("std");
const graph = @import("graph.zig");
const port = @import("port.zig");

/// Which buffer-assignment strategy the commit pass uses.
pub const BufferMode = enum {
    /// One private buffer per produced value — the obviously-correct baseline.
    /// Used as the differential reference the colored pool is checked against.
    per_edge,
    /// Per-element-class left-edge interval coloring — buffers are reused the
    /// moment their last reader has run (the shipped pool).
    colored,
};

/// The coercion morphism a Format mismatch on an edge requires. Decided by the
/// negotiate stage; the node body for a non-trivial coercion is materialized by a
/// later phase. Element-type identity makes most of these compile-time-impossible
/// on a wired edge today (`connect` rejects a mismatch), so the live decision in
/// this phase is `.none` (identical) or `.resample`/`.ramp_hold` on the axes that
/// are not part of the element type (sample rate, control-rate parameter edges).
pub const Coercion = enum {
    none, // identical Format — no morphism
    precision_cast, // same layout & rate, different precision T
    channel_upmix, // registered layout widening (e.g. stereo → 5.1)
    channel_downmix, // registered layout narrowing
    resample, // sample-rate mismatch
    ramp_hold, // parameter (control-rate) edge reconciliation
    hard_mismatch, // unregistered / incompatible — a commit error (L2)
};

/// The Format an edge presents at one endpoint, for the coercion decision.
pub const EdgeFormat = struct {
    elem_name: []const u8,
    channels: u16,
    sample_rate: u32,
    is_param: bool,
};

/// Decide the coercion morphism reconciling `producer` to `consumer` — the
/// commit-time realization of "make the diagram commute". A non-commuting square
/// is either a coercion (insert a morphism) or, when no registered morphism
/// exists, a hard mismatch (reject). The standard channel layouts (mono/stereo/
/// 5.1/7.1, by their 1/2/6/8 counts) form the registered up/down-mix set; a count
/// outside it (ambisonic, custom) is unregistered and needs an explicit block.
pub fn coercionFor(producer: EdgeFormat, consumer: EdgeFormat) Coercion {
    // A parameter (control) edge is a side input reconciled to the consumer's
    // render rate by ramp/hold — the parameter analogue of a resampler — provided
    // the control element matches; a mismatched control element is unrepresentable.
    if (producer.is_param or consumer.is_param) {
        if (!std.mem.eql(u8, producer.elem_name, consumer.elem_name)) return .hard_mismatch;
        return .ramp_hold;
    }
    if (std.mem.eql(u8, producer.elem_name, consumer.elem_name)) {
        if (producer.sample_rate != consumer.sample_rate) return .resample;
        return .none;
    }
    // Different element. Same channel count ⇒ a precision/lane change (a cast);
    // different count ⇒ a channel up/down-mix iff both layouts are registered,
    // else a hard mismatch requiring an explicit spatial block (L2).
    if (producer.channels == consumer.channels) return .precision_cast;
    if (registeredLayoutCount(producer.channels) and registeredLayoutCount(consumer.channels))
        return if (consumer.channels > producer.channels) .channel_upmix else .channel_downmix;
    return .hard_mismatch;
}

/// Is this channel count one of the standard, registered layouts (mono, stereo,
/// 5.1, 7.1)? Up/down-mix matrices exist between these; other counts (ambisonic
/// orders, custom buses) are unregistered.
fn registeredLayoutCount(ch: u16) bool {
    return ch == 1 or ch == 2 or ch == 6 or ch == 8;
}

/// One render op — a single block invocation. The hot path replays
/// `op.fn_ptr(op.self_ptr, gather(input_buffer_ids), scatter(output_buffer_ids), n)`.
pub const RenderOp = struct {
    /// The graph node this op renders. The op-list is in forward-topo order, so
    /// op index ≠ node id; the executor keys off this to recover the node's
    /// monomorphized kernel and instance from the parallel block-type tuple.
    node_id: usize,
    /// Monomorphized Map/Rate kernel entry (erased). Null in the comptime IR: the
    /// op-list topology + buffer ids are fixed by the commit pass; the runnable
    /// kernel pointer is bound by the executor when it monomorphizes over the
    /// block-type tuple (the same op then runs `fn_ptr(self_ptr, in, out, n)`).
    fn_ptr: ?*const anyopaque,
    self_ptr: ?*anyopaque,
    /// Buffer ids feeding this node's input ports — forward edges then feedback
    /// read-sides (a pool id for an ordinary edge, a persistent id for a z⁻¹).
    input_buffer_ids: [port.max_ports_per_direction]usize,
    input_count: usize,
    /// Buffer ids this node produces — forward output values then feedback writes.
    output_buffer_ids: [port.max_ports_per_direction]usize,
    output_count: usize,
    /// Frames produced/consumed by this op this callback — the device demand N
    /// resolved for this node through the upstream rate ratios.
    n_or_pull_spec: usize,
};

/// The committed plan: a flat op-list (one op per node, forward-topo order) plus
/// the static footprint. `footprint_bytes` is a comptime constant for a comptime
/// graph, so it can size a `[footprint_bytes]u8` pool in `.bss`.
///
/// Beyond the op-list and the single footprint figure, the plan carries the
/// **pool layout** the executor needs to turn an op's `*_buffer_ids` into real
/// byte slices: each pool buffer id maps to a `[offset, offset+len)` window in
/// the engine's flat pool. The window is contiguous per element-class (a class's
/// `M` colored buffers sit back-to-back), and `len` is `N · element_size` for the
/// class. Persistent (delay/feedback) state lives past `pool_bytes`; for a graph
/// with no feedback `pool_bytes == footprint_bytes`.
pub fn Plan(comptime n_ops: usize) type {
    return struct {
        ops: [n_ops]RenderOp,
        op_count: usize,
        footprint_bytes: usize,
        /// Which buffer-assignment strategy produced this plan.
        buffer_mode: BufferMode,
        /// Number of distinct pool buffer ids (across all element classes).
        pool_buffer_count: usize = 0,
        /// Total bytes the colored/per-edge pools occupy (the executor's pool
        /// region). Excludes persistent delay/feedback state.
        pool_bytes: usize = 0,
        /// Byte offset of each pool buffer id into the engine's flat pool.
        buffer_offset: [graph.max_edges]usize = [_]usize{0} ** graph.max_edges,
        /// Byte length of each pool buffer id (`N · element_size` of its class).
        buffer_byte_len: [graph.max_edges]usize = [_]usize{0} ** graph.max_edges,
    };
}

pub const CommitError = error{
    /// A cycle made of ordinary (forward) edges survived the topological sort.
    /// The author wired a loop without declaring it as feedback.
    UndeclaredCycle,
    /// A path head has no producer for its sample inputs: neither a source nor a
    /// persistent generator. Every path must be rooted at a source.
    UnrootedPath,
    /// A feedback cycle contains no delay element — its output would depend on
    /// itself within the same block (not causal). Insert a unit delay / delay
    /// line, or author the loop as a fused tight-feedback kernel.
    DelayFreeLoop,
    /// An edge presents incompatible Formats with no registered coercion (e.g. an
    /// unregistered channel-layout pair), or a malformed edge whose carried
    /// element disagrees with its producer's output.
    LayoutMismatch,
    /// A parameter slot is driven by BOTH a wired parameter edge and an external
    /// `set`/`schedule` — the one-source rule forbids it.
    ParameterMultiplyDriven,
    /// An edge references a node id past the node count — a malformed graph.
    MalformedGraph,
    /// More than 8 ports on one direction of a node (also caught at port mint).
    PortCeilingExceeded,
};

/// Commit a graph at COMPTIME with the shipped colored pool. See `commitComptimeMode`.
pub fn commitComptime(comptime g: graph.Graph) CommitError!Plan(g.node_count) {
    return commitComptimeMode(g, .colored);
}

/// Commit a graph at COMPTIME under an explicit buffer mode. `.colored` is the
/// shipped pool; `.per_edge` is the obviously-correct baseline the colored pool is
/// differenced against. Both share every other stage, so the only thing that
/// varies between them is the buffer-id assignment (and the footprint that follows
/// from it) — which is exactly what the differential test must isolate.
pub fn commitComptimeMode(comptime g: graph.Graph, comptime mode: BufferMode) CommitError!Plan(g.node_count) {
    comptime {
        // The Tarjan and per-class colorer loops are bounded by the graph
        // dimensions but their product can be large for a near-max graph; give
        // the comptime interpreter generous branch headroom.
        @setEvalBranchQuota(10_000_000);

        const NC = g.node_count;
        const EC = g.edge_count;
        const FC = g.feedback_count;
        const N = g.block_size;
        const max_nodes = graph.max_nodes;
        const max_edges = graph.max_edges;

        // ---- 0. validate edges + port ceiling ------------------------------
        var in_degree: [max_nodes]usize = [_]usize{0} ** max_nodes;
        var out_degree: [max_nodes]usize = [_]usize{0} ** max_nodes;
        for (g.edges[0..EC]) |e| {
            if (e.from_node >= NC or e.to_node >= NC) return error.MalformedGraph;
            if (e.from_port >= port.max_ports_per_direction or
                e.to_port >= port.max_ports_per_direction)
                return error.PortCeilingExceeded;
            out_degree[e.from_node] += 1;
            in_degree[e.to_node] += 1;
            if (out_degree[e.from_node] > port.max_ports_per_direction or
                in_degree[e.to_node] > port.max_ports_per_direction)
                return error.PortCeilingExceeded;
        }
        for (g.feedback[0..FC]) |f| {
            if (f.write_node >= NC or f.read_node >= NC) return error.MalformedGraph;
        }

        // ---- 1. negotiate (Format unification + coercion decision + P2) ----
        // L1 (element-type identity: precision + channel layout + family) is a
        // COMPILE-TIME guarantee — `connect` emits a `@compileError` naming the
        // port on any mismatch, so every wired edge's two endpoints already carry
        // the same element. The runnable work at commit is therefore (a) DECIDING
        // the coercion morphism for the Format axes NOT encoded in the element
        // type — sample rate (→ resampler) and a control-rate parameter edge (→
        // ramp/hold) — rejecting an unregistered/incompatible pair as a hard
        // mismatch (L2), and (b) the parameter one-source rule (P2). The coercion
        // node bodies are materialized by a later phase; here is the decision.
        for (g.edges[0..EC]) |e| {
            const producer: EdgeFormat = .{
                .elem_name = e.elem_name,
                .channels = e.channels,
                .sample_rate = g.nodes[e.from_node].sample_rate,
                .is_param = e.is_param,
            };
            const consumer: EdgeFormat = .{
                .elem_name = e.elem_name,
                .channels = e.channels,
                .sample_rate = g.nodes[e.to_node].sample_rate,
                .is_param = e.is_param,
            };
            // L2: an incompatible pair with no registered coercion is rejected.
            // (Cannot fire on a wired edge today — connect proves element identity
            // and graphs are single-rate — but the reject is wired for the relaxed
            // future path; the full policy is unit-tested via `coercionFor`.)
            if (coercionFor(producer, consumer) == .hard_mismatch) return error.LayoutMismatch;

            // P2 one-source: a parameter slot fed by a wired edge may not ALSO be
            // driven by an external set/schedule.
            if (e.is_param) {
                const bit = @as(u8, 1) << e.to_port;
                if (g.nodes[e.to_node].set_param_slots & bit != 0)
                    return error.ParameterMultiplyDriven;
            }
        }

        // ---- 2. topo — Kahn with a min-node-id tie-break -------------------
        var indeg: [max_nodes]usize = [_]usize{0} ** max_nodes;
        for (g.edges[0..EC]) |e| indeg[e.to_node] += 1;
        const indeg0: [max_nodes]usize = indeg;

        var topo: [max_nodes]usize = undefined;
        var topo_len: usize = 0;
        var placed: [max_nodes]bool = [_]bool{false} ** max_nodes;
        while (topo_len < NC) {
            var pick: ?usize = null;
            for (0..NC) |v| {
                if (placed[v] or indeg[v] != 0) continue;
                if (pick == null) pick = v; // ascending scan ⇒ first ready is min id
            }
            const v = pick orelse break;
            placed[v] = true;
            topo[topo_len] = v;
            topo_len += 1;
            for (g.edges[0..EC]) |e| {
                if (e.from_node != v) continue;
                indeg[e.to_node] -= 1;
            }
        }
        if (topo_len < NC) return error.UndeclaredCycle;

        var idx: [max_nodes]usize = undefined;
        for (0..NC) |i| idx[topo[i]] = i;

        // ---- 3. source-rooted check (SR3) ---------------------------------
        for (0..NC) |v| {
            if (indeg0[v] != 0) continue;
            if (!g.nodes[v].is_source) return error.UnrootedPath;
        }

        // ---- 4. delay-free-loop check — Tarjan on the FULL graph ----------
        // Build CSR adjacency over forward ∪ feedback edges (a feedback edge is a
        // producer→consumer arc for reachability, same as a forward edge).
        var succ_count: [max_nodes]usize = [_]usize{0} ** max_nodes;
        for (g.edges[0..EC]) |e| succ_count[e.from_node] += 1;
        for (g.feedback[0..FC]) |f| succ_count[f.write_node] += 1;
        var off: [max_nodes + 1]usize = undefined;
        off[0] = 0;
        for (0..NC) |v| off[v + 1] = off[v] + succ_count[v];
        var cursor: [max_nodes]usize = undefined;
        for (0..NC) |v| cursor[v] = off[v];
        var adj: [2 * max_edges]usize = undefined;
        for (g.edges[0..EC]) |e| {
            adj[cursor[e.from_node]] = e.to_node;
            cursor[e.from_node] += 1;
        }
        for (g.feedback[0..FC]) |f| {
            adj[cursor[f.write_node]] = f.read_node;
            cursor[f.write_node] += 1;
        }

        // Iterative Tarjan (explicit DFS + SCC stacks — no comptime recursion).
        var disc: [max_nodes]isize = [_]isize{-1} ** max_nodes; // discovery index
        var low: [max_nodes]usize = undefined;
        var on_stack: [max_nodes]bool = [_]bool{false} ** max_nodes;
        var sstack: [max_nodes]usize = undefined; // SCC stack
        var ssp: usize = 0;
        var fnode: [max_nodes]usize = undefined; // DFS frame: node
        var fchild: [max_nodes]usize = undefined; // DFS frame: next adj offset
        var fsp: usize = 0;
        var index_counter: usize = 0;
        for (0..NC) |s| {
            if (disc[s] != -1) continue;
            fnode[0] = s;
            fchild[0] = off[s];
            fsp = 1;
            disc[s] = @intCast(index_counter);
            low[s] = index_counter;
            index_counter += 1;
            sstack[ssp] = s;
            ssp += 1;
            on_stack[s] = true;
            while (fsp > 0) {
                const v = fnode[fsp - 1];
                if (fchild[fsp - 1] < off[v + 1]) {
                    const w = adj[fchild[fsp - 1]];
                    fchild[fsp - 1] += 1;
                    if (disc[w] == -1) {
                        disc[w] = @intCast(index_counter);
                        low[w] = index_counter;
                        index_counter += 1;
                        sstack[ssp] = w;
                        ssp += 1;
                        on_stack[w] = true;
                        fnode[fsp] = w;
                        fchild[fsp] = off[w];
                        fsp += 1;
                    } else if (on_stack[w]) {
                        const dw: usize = @intCast(disc[w]);
                        if (dw < low[v]) low[v] = dw;
                    }
                } else {
                    // v is fully explored. If it is an SCC root, pop the SCC.
                    if (low[v] == @as(usize, @intCast(disc[v]))) {
                        var members: [max_nodes]usize = undefined;
                        var m: usize = 0;
                        while (true) {
                            const u = sstack[ssp - 1];
                            ssp -= 1;
                            on_stack[u] = false;
                            members[m] = u;
                            m += 1;
                            if (u == v) break;
                        }
                        // A cycle = a non-trivial SCC, or a singleton with a
                        // self-edge. Every cycle must contain a delay element.
                        var is_cycle = m > 1;
                        if (m == 1) {
                            for (off[v]..off[v + 1]) |k| {
                                if (adj[k] == v) is_cycle = true;
                            }
                        }
                        if (is_cycle) {
                            var has_delay = false;
                            for (0..m) |k| {
                                if (g.nodes[members[k]].is_delay) has_delay = true;
                            }
                            if (!has_delay) return error.DelayFreeLoop;
                        }
                    }
                    fsp -= 1;
                    if (fsp > 0) {
                        const parent = fnode[fsp - 1];
                        if (low[v] < low[parent]) low[parent] = low[v];
                    }
                }
            }
        }

        // ---- 5. liveness — produced values, pool-eligible ------------------
        const Value = struct {
            from_node: usize,
            from_port: port.PortIndex,
            start: usize,
            end: usize,
            elem_size: usize,
            elem_name: []const u8,
            color: usize = 0,
            buffer_id: usize = 0,
        };
        var values: [max_edges]Value = undefined;
        var value_count: usize = 0;
        for (g.edges[0..EC]) |e| {
            const s = idx[e.from_node];
            const en = idx[e.to_node];
            var found: ?usize = null;
            for (0..value_count) |vi| {
                if (values[vi].from_node == e.from_node and values[vi].from_port == e.from_port) {
                    found = vi;
                    break;
                }
            }
            if (found) |vi| {
                if (en > values[vi].end) values[vi].end = en;
            } else {
                values[value_count] = .{
                    .from_node = e.from_node,
                    .from_port = e.from_port,
                    .start = s,
                    .end = en,
                    .elem_size = e.elem_size,
                    .elem_name = e.elem_name,
                };
                value_count += 1;
            }
        }

        // ---- 6. buffer-id assignment (per_edge baseline OR colored pool) ---
        var class_names: [max_edges][]const u8 = undefined;
        var class_elem_size: [max_edges]usize = undefined;
        var class_M: [max_edges]usize = [_]usize{0} ** max_edges;
        var class_count: usize = 0;
        for (0..value_count) |vi| {
            var ci: ?usize = null;
            for (0..class_count) |c| {
                if (std.mem.eql(u8, class_names[c], values[vi].elem_name)) {
                    ci = c;
                    break;
                }
            }
            if (ci == null) {
                class_names[class_count] = values[vi].elem_name;
                class_elem_size[class_count] = values[vi].elem_size;
                class_count += 1;
            }
        }
        for (0..class_count) |c| {
            // Gather this class's value indices, sorted by (start, value id).
            var order: [max_edges]usize = undefined;
            var order_len: usize = 0;
            for (0..value_count) |vi| {
                if (std.mem.eql(u8, values[vi].elem_name, class_names[c])) {
                    order[order_len] = vi;
                    order_len += 1;
                }
            }
            for (1..order_len) |a| {
                var b = a;
                while (b > 0) : (b -= 1) {
                    const hi = order[b];
                    const lo = order[b - 1];
                    const swap = values[hi].start < values[lo].start or
                        (values[hi].start == values[lo].start and hi < lo);
                    if (!swap) break;
                    order[b] = lo;
                    order[b - 1] = hi;
                }
            }
            switch (mode) {
                .per_edge => {
                    // One private buffer per value — no reuse (the baseline).
                    for (0..order_len) |oi| values[order[oi]].color = oi;
                    class_M[c] = order_len;
                },
                .colored => {
                    // Left-edge: reuse the lowest color whose last interval ended
                    // before this one starts (end-inclusive ⇒ strict `<`). The -1
                    // sentinel marks a never-used color (no allocator at comptime).
                    var color_end: [max_edges]isize = [_]isize{-1} ** max_edges;
                    var colors_used: usize = 0;
                    for (0..order_len) |oi| {
                        const vi = order[oi];
                        const start_i: isize = @intCast(values[vi].start);
                        var chosen: ?usize = null;
                        for (0..colors_used) |col| {
                            if (color_end[col] < start_i) {
                                chosen = col;
                                break;
                            }
                        }
                        const col = chosen orelse blk: {
                            const nc = colors_used;
                            colors_used += 1;
                            break :blk nc;
                        };
                        values[vi].color = col;
                        color_end[col] = @intCast(values[vi].end);
                    }
                    class_M[c] = colors_used;
                },
            }
        }
        var class_base: [max_edges]usize = undefined;
        var total_pool: usize = 0;
        for (0..class_count) |c| {
            class_base[c] = total_pool;
            total_pool += class_M[c];
        }
        for (0..value_count) |vi| {
            for (0..class_count) |c| {
                if (std.mem.eql(u8, values[vi].elem_name, class_names[c])) {
                    values[vi].buffer_id = class_base[c] + values[vi].color;
                    break;
                }
            }
        }
        // Forward edge → its value's pool id. Feedback read/write sides get
        // persistent ids past the pool region (pool-excluded z⁻¹ state).
        var edge_buf: [max_edges]usize = undefined;
        for (g.edges[0..EC], 0..) |e, ei| {
            for (0..value_count) |vi| {
                if (values[vi].from_node == e.from_node and values[vi].from_port == e.from_port) {
                    edge_buf[ei] = values[vi].buffer_id;
                    break;
                }
            }
        }
        var fb_buf: [max_edges]usize = undefined;
        for (0..FC) |fi| fb_buf[fi] = total_pool + fi;

        // ---- 7. rate scheduling — demand N propagated upstream ------------
        // want[v] = frames v must produce this callback. Sinks want N; a producer
        // wants the max, over its consumers, of needed_input(consumer) — for a
        // consumer with ratio p:q (p out per q in), producing `want[c]` outputs
        // takes ceil(want[c]·q/p) inputs (never assumes the hop divides N).
        var want: [max_nodes]usize = [_]usize{N} ** max_nodes;
        var ri = NC;
        while (ri > 0) {
            ri -= 1;
            const v = topo[ri];
            var has_consumer = false;
            var w: usize = 0;
            for (g.edges[0..EC]) |e| {
                if (e.from_node != v) continue;
                has_consumer = true;
                const cp = g.nodes[e.to_node].out_per_in_p;
                const cq = g.nodes[e.to_node].out_per_in_q;
                const demand = (want[e.to_node] * cq + cp - 1) / cp; // ceil
                if (demand > w) w = demand;
            }
            // A source (no consumer here only if it is a lone source) keeps N;
            // otherwise its output length is set by the downstream demand (SR1).
            if (has_consumer) want[v] = w;
        }

        // ---- 8. emit — one op per node, forward-topo order ----------------
        var ops: [NC]RenderOp = undefined;
        for (0..NC) |i| {
            const v = topo[i];
            var in_ids: [port.max_ports_per_direction]usize = undefined;
            var in_n: usize = 0;
            var out_ids: [port.max_ports_per_direction]usize = undefined;
            var out_n: usize = 0;
            for (g.edges[0..EC], 0..) |e, ei| {
                if (e.to_node == v) {
                    in_ids[in_n] = edge_buf[ei];
                    in_n += 1;
                }
                if (e.from_node == v) {
                    var seen = false;
                    for (0..out_n) |k| {
                        if (out_ids[k] == edge_buf[ei]) seen = true;
                    }
                    if (!seen) {
                        out_ids[out_n] = edge_buf[ei];
                        out_n += 1;
                    }
                }
            }
            // Feedback read-sides are this node's persistent inputs; feedback
            // write-sides are its persistent outputs (the z⁻¹ split).
            for (g.feedback[0..FC], 0..) |f, fi| {
                if (f.read_node == v) {
                    in_ids[in_n] = fb_buf[fi];
                    in_n += 1;
                }
                if (f.write_node == v) {
                    out_ids[out_n] = fb_buf[fi];
                    out_n += 1;
                }
            }
            ops[i] = .{
                .node_id = v,
                .fn_ptr = null,
                .self_ptr = null,
                .input_buffer_ids = in_ids,
                .input_count = in_n,
                .output_buffer_ids = out_ids,
                .output_count = out_n,
                .n_or_pull_spec = want[v],
            };
        }

        // ---- 9. footprint + pool layout -----------------------------------
        // pools + persistent (delay rings / feedback read-sides) + per-block
        // state. The plugin-delay-compensation term is zero until that pass lands.
        // While summing the pools, record each buffer id's byte window so the
        // executor can resolve an op's buffer ids into real slices: a class's M
        // colored buffers sit contiguously, each N·element_size bytes wide.
        var buffer_offset: [max_edges]usize = [_]usize{0} ** max_edges;
        var buffer_byte_len: [max_edges]usize = [_]usize{0} ** max_edges;
        var pool_bytes: usize = 0;
        for (0..class_count) |c| {
            const stride = N * class_elem_size[c];
            for (0..class_M[c]) |color| {
                const id = class_base[c] + color;
                buffer_offset[id] = pool_bytes;
                buffer_byte_len[id] = stride;
                pool_bytes += stride;
            }
        }
        var footprint: usize = pool_bytes;
        for (0..NC) |v| {
            if (g.nodes[v].is_delay)
                footprint += g.nodes[v].delay_len * g.nodes[v].out_elem_size;
            footprint += g.nodes[v].state_size;
        }

        return Plan(NC){
            .ops = ops,
            .op_count = NC,
            .footprint_bytes = footprint,
            .buffer_mode = mode,
            .pool_buffer_count = total_pool,
            .pool_bytes = pool_bytes,
            .buffer_offset = buffer_offset,
            .buffer_byte_len = buffer_byte_len,
        };
    }
}

// ===========================================================================
// In-file characterization. The commit pass is observed through the Plan it
// returns (op-per-node count, the comptime-constant footprint, the per-op buffer
// ids and frame counts) and through the CommitError it raises at each boundary.
// The two worked examples (a feedback comb accepted with an exact footprint, and a
// delay-free loop rejected) anchor the numbers; the rest pin each error boundary
// and each newly-closed stage (negotiate decision, Mode-B baseline, rate ratios).
// ===========================================================================

const t = @import("types.zig");

const Src = struct {
    const Self = @This();
    pub fn process(self: *Self, out: []t.Sample(f32)) void {
        _ = self;
        _ = out;
    }
};
const Map1 = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const t.Sample(f32), out: []t.Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};
const Sink = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const t.Sample(f32)) void {
        _ = self;
        _ = in;
    }
};

test "worked example B: feedback comb accepts and footprints to 3968 bytes" {
    const Sum = Map1;
    const Gain = Map1;
    const DelayLine = struct {
        const Self = @This();
        pub const delay_len: usize = 480;
        pub fn process(self: *Self, in: []const t.Sample(f32), out: []t.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 256;
        const in = gg.add(Src);
        const sum = gg.add(Sum);
        const dl = gg.add(DelayLine);
        const gain = gg.add(Gain);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Sum), sum, 0);
        gg.connect(port.MapOutPort(Sum), sum, 0, port.MapInPort(DelayLine), dl, 0);
        gg.connect(port.MapOutPort(DelayLine), dl, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(Sink), out, 0);
        gg.connectFeedback(port.MapOutPort(Gain), gain, 0, port.MapInPort(Sum), sum, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 5), plan.op_count);
    // pools: M_Sample=2 · 256 · 4 = 2048 ; persistent DelayLine: 480 · 4 = 1920.
    try std.testing.expectEqual(@as(usize, 2048 + 1920), plan.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 3968), plan.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 256), plan.ops[0].n_or_pull_spec);
}

test "worked example C: delay-free feedback loop is rejected (⊢ A4)" {
    const Sum = Map1;
    const Gain = Map1;
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const in = gg.add(Src);
        const sum = gg.add(Sum);
        const gain = gg.add(Gain);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Sum), sum, 0);
        gg.connect(port.MapOutPort(Sum), sum, 0, port.MapInPort(Gain), gain, 0);
        gg.connect(port.MapOutPort(Gain), gain, 0, port.MapInPort(Sink), out, 0);
        gg.connectFeedback(port.MapOutPort(Gain), gain, 0, port.MapInPort(Sum), sum, 0);
        break :blk gg;
    };
    try std.testing.expectError(error.DelayFreeLoop, comptime commitComptime(g));
}

test "an undeclared (plain) back-edge is error.UndeclaredCycle, not DelayFreeLoop" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const in = gg.add(Src);
        const sum = gg.add(Map1);
        const gain = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Map1), sum, 0);
        gg.connect(port.MapOutPort(Map1), sum, 0, port.MapInPort(Map1), gain, 0);
        gg.connect(port.MapOutPort(Map1), gain, 0, port.MapInPort(Sink), out, 0);
        gg.connect(port.MapOutPort(Map1), gain, 0, port.MapInPort(Map1), sum, 0); // plain
        break :blk gg;
    };
    try std.testing.expectError(error.UndeclaredCycle, comptime commitComptime(g));
}

test "a non-source path head is error.UnrootedPath (source-rooted SR3)" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const a = gg.add(Map1); // input port, but nothing feeds it
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Map1), a, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    try std.testing.expectError(error.UnrootedPath, comptime commitComptime(g));
}

test "a clean source→map→sink chain commits; op-per-node; footprint scales with N" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 128;
        const in = gg.add(Src);
        const m = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Map1), m, 0);
        gg.connect(port.MapOutPort(Map1), m, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 3), plan.op_count);
    try std.testing.expectEqual(@as(usize, 2 * 128 * @sizeOf(t.Sample(f32))), plan.footprint_bytes);
}

test "footprint_bytes is a COMPTIME CONSTANT usable as an array length (H2)" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const in = gg.add(Src);
        const m = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Map1), m, 0);
        gg.connect(port.MapOutPort(Map1), m, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    const proof: [plan.footprint_bytes]u8 = undefined;
    try std.testing.expect(proof.len > 0);
}

test "Mode-B baseline uses one buffer per value; never fewer than Mode-C" {
    // A 5-node chain: Mode-C ping-pongs 2 buffers; Mode-B keeps all 4 values live.
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 64;
        const in = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const c = gg.add(Map1);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Map1), a, 0);
        gg.connect(port.MapOutPort(Map1), a, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPort(Map1), c, 0);
        gg.connect(port.MapOutPort(Map1), c, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const colored = comptime try commitComptimeMode(g, .colored);
    const per_edge = comptime try commitComptimeMode(g, .per_edge);
    // 4 forward values; colored reuses 2, per-edge keeps 4.
    try std.testing.expectEqual(@as(usize, 2 * 64 * 4), colored.footprint_bytes);
    try std.testing.expectEqual(@as(usize, 4 * 64 * 4), per_edge.footprint_bytes);
    try std.testing.expect(per_edge.footprint_bytes >= colored.footprint_bytes);
    try std.testing.expectEqual(BufferMode.per_edge, per_edge.buffer_mode);
}

test "rate scheduling: a Framer's input demand is want·H (H need not divide N)" {
    // Framer with out_per_in 1:H (one frame out per H samples in). To produce N
    // frames the upstream must supply N·H samples — ceil division, no H|N assumption.
    const H = 100; // deliberately does NOT divide N=256
    const Framer = struct {
        const Self = @This();
        pub const out_per_in = .{ 1, H };
        pub const algorithmic_latency: usize = 0;
        pub fn pull(self: *Self, want: usize, out: []t.Sample(f32)) usize {
            _ = self;
            _ = out;
            return want;
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 256;
        const in = gg.add(Src);
        const fr = gg.add(Framer);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.PortId(Framer, .in, t.Sample(f32)), fr, 0);
        gg.connect(port.PortId(Framer, .out, t.Sample(f32)), fr, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    // The source must produce ceil(256·H/1) = 25600 samples to feed the framer.
    try std.testing.expectEqual(@as(usize, 256 * H), plan.ops[0].n_or_pull_spec);
    // The framer itself produces the device demand N = 256.
    try std.testing.expectEqual(@as(usize, 256), plan.ops[1].n_or_pull_spec);
}

test "rate scheduling: a VariRate plans on its worst-case (min) ratio" {
    // A VariRate sizing on rate_bounds.min = 1:2 (one frame out per two in at the
    // worst case = the most input ever needed for a given demand). To produce N
    // frames the upstream must supply ceil(N·2/1) = 2N samples.
    const Asrc = struct {
        const Self = @This();
        pub const rate_bounds = .{ .min = .{ 1, 2 }, .nominal = .{ 1, 1 }, .max = .{ 2, 1 } };
        pub const max_latency: usize = 64;
        pub fn pull(self: *Self, want: usize, out: []t.Sample(f32)) usize {
            _ = self;
            _ = out;
            return want;
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 128;
        const in = gg.add(Src);
        const asrc = gg.add(Asrc);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.PortId(Asrc, .in, t.Sample(f32)), asrc, 0);
        gg.connect(port.PortId(Asrc, .out, t.Sample(f32)), asrc, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    // Source feeds the worst-case demand: ceil(128·2/1) = 256.
    try std.testing.expectEqual(@as(usize, 256), plan.ops[0].n_or_pull_spec);
    // The VariRate produces the device demand N = 128.
    try std.testing.expectEqual(@as(usize, 128), plan.ops[1].n_or_pull_spec);
}

test "negotiate: coercionFor classifies the catalog §6 table" {
    const f32_mono: EdgeFormat = .{ .elem_name = "Frame(f32,mono)", .channels = 1, .sample_rate = 48_000, .is_param = false };
    // identical → none
    try std.testing.expectEqual(Coercion.none, coercionFor(f32_mono, f32_mono));
    // same element, different sample rate → resample
    var slow = f32_mono;
    slow.sample_rate = 44_100;
    try std.testing.expectEqual(Coercion.resample, coercionFor(f32_mono, slow));
    // parameter edge → ramp/hold
    var p_a = f32_mono;
    p_a.is_param = true;
    var p_b = f32_mono;
    p_b.is_param = true;
    try std.testing.expectEqual(Coercion.ramp_hold, coercionFor(p_a, p_b));
    // same channels, different element (precision) → cast
    const f64_mono: EdgeFormat = .{ .elem_name = "Frame(f64,mono)", .channels = 1, .sample_rate = 48_000, .is_param = false };
    try std.testing.expectEqual(Coercion.precision_cast, coercionFor(f32_mono, f64_mono));
    // registered layout widening (stereo→5.1, counts 2→6) → upmix
    const st: EdgeFormat = .{ .elem_name = "Frame(f32,stereo)", .channels = 2, .sample_rate = 48_000, .is_param = false };
    const s51: EdgeFormat = .{ .elem_name = "Frame(f32,5_1)", .channels = 6, .sample_rate = 48_000, .is_param = false };
    try std.testing.expectEqual(Coercion.channel_upmix, coercionFor(st, s51));
    try std.testing.expectEqual(Coercion.channel_downmix, coercionFor(s51, st));
    // unregistered pair (ambisonic order-2 = 9ch → stereo) → hard mismatch (L2)
    const amb: EdgeFormat = .{ .elem_name = "Frame(f32,ambisonic2)", .channels = 9, .sample_rate = 48_000, .is_param = false };
    try std.testing.expectEqual(Coercion.hard_mismatch, coercionFor(amb, st));
}

test "negotiate: a parameter slot driven by both a wire and set is rejected (P2)" {
    const Osc = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []t.Scalar(f32)) void {
            _ = self;
            _ = out;
        }
    };
    const Filt = struct {
        const Self = @This();
        pub const params = .{ .cutoff = t.Scalar(f32) };
        pub fn process(self: *Self, in: []const t.Sample(f32), out: []t.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const osc = gg.add(Osc);
        const filt = gg.add(Filt);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Filt), filt, 0);
        gg.connect(port.MapOutPort(Osc), osc, 0, port.ParamPort(Filt, "cutoff"), filt, 0); // wired param
        gg.connect(port.MapOutPort(Filt), filt, 0, port.MapInPort(Sink), out, 0);
        gg.markSetParam(filt, 0); // ALSO driven by set → conflict
        break :blk gg;
    };
    try std.testing.expectError(error.ParameterMultiplyDriven, comptime commitComptime(g));
}

test "negotiate: a wired parameter edge alone (no set) commits cleanly (P4)" {
    const Osc = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []t.Scalar(f32)) void {
            _ = self;
            _ = out;
        }
    };
    const Filt = struct {
        const Self = @This();
        pub const params = .{ .cutoff = t.Scalar(f32) };
        pub fn process(self: *Self, in: []const t.Sample(f32), out: []t.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const osc = gg.add(Osc);
        const filt = gg.add(Filt);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Filt), filt, 0);
        gg.connect(port.MapOutPort(Osc), osc, 0, port.ParamPort(Filt, "cutoff"), filt, 0);
        gg.connect(port.MapOutPort(Filt), filt, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 4), plan.op_count);
}

test "feedback through a delay element is accepted (the dual of example C)" {
    const DelayLine = struct {
        const Self = @This();
        pub const delay_len: usize = 64;
        pub fn process(self: *Self, in: []const t.Sample(f32), out: []t.Sample(f32)) void {
            _ = self;
            @memcpy(out, in);
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const in = gg.add(Src);
        const sum = gg.add(Map1);
        const dl = gg.add(DelayLine);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), in, 0, port.MapInPort(Map1), sum, 0);
        gg.connect(port.MapOutPort(Map1), sum, 0, port.MapInPort(DelayLine), dl, 0);
        gg.connect(port.MapOutPort(DelayLine), dl, 0, port.MapInPort(Sink), out, 0);
        gg.connectFeedback(port.MapOutPort(DelayLine), dl, 0, port.MapInPort(Map1), sum, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expect(plan.footprint_bytes > 0);
}

test "a reconvergent diamond DAG is accepted — no false cycle positive" {
    const Sum2 = struct {
        const Self = @This();
        pub fn process(self: *Self, in0: []const t.Sample(f32), in1: []const t.Sample(f32), out: []t.Sample(f32)) void {
            _ = self;
            for (in0, in1, out) |x, y, *o| o.ch[0] = x.ch[0] + y.ch[0];
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        const a = gg.add(Map1);
        const b = gg.add(Map1);
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), a, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(Map1), a, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        break :blk gg;
    };
    const plan = comptime try commitComptime(g);
    try std.testing.expectEqual(@as(usize, 5), plan.op_count);
}

test "the empty graph and a lone source commit to degenerate plans" {
    const empty = comptime try commitComptime(graph.Graph.empty);
    try std.testing.expectEqual(@as(usize, 0), empty.op_count);
    try std.testing.expectEqual(@as(usize, 0), empty.footprint_bytes);

    const lone = comptime blk: {
        var gg = graph.Graph.empty;
        _ = gg.add(Src);
        break :blk gg;
    };
    const plan = comptime try commitComptime(lone);
    try std.testing.expectEqual(@as(usize, 1), plan.op_count);
    try std.testing.expectEqual(@as(usize, 0), plan.footprint_bytes);
}

test "a malformed edge to an out-of-range node => error.MalformedGraph" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        _ = gg.add(Src);
        gg.edges[gg.edge_count] = .{
            .from_node = 0,
            .from_port = 0,
            .to_node = 9,
            .to_port = 0,
            .elem_size = @sizeOf(t.Sample(f32)),
            .elem_name = "Frame(f32,mono)",
        };
        gg.edge_count += 1;
        break :blk gg;
    };
    try std.testing.expectError(error.MalformedGraph, comptime commitComptime(g));
}

test "more than 8 edges out of one node => error.PortCeilingExceeded" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        const src = gg.add(Src);
        var sinks: [9]usize = undefined;
        for (0..9) |i| sinks[i] = gg.add(Sink);
        for (0..9) |i| {
            gg.edges[gg.edge_count] = .{
                .from_node = src,
                .from_port = @intCast(i % 8),
                .to_node = sinks[i],
                .to_port = 0,
                .elem_size = @sizeOf(t.Sample(f32)),
                .elem_name = "Frame(f32,mono)",
            };
            gg.edge_count += 1;
        }
        break :blk gg;
    };
    try std.testing.expectError(error.PortCeilingExceeded, comptime commitComptime(g));
}
