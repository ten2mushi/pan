//! Automatic comptime loop-fusion — a pure `graph + block-tuple → graph + block-
//! tuple` rewrite that detects adjacent fusable `Map` chains and folds each into ONE
//! `combinators.Subgraph` node, recovering the single-pass / byte-displacement-per-
//! render win WITHOUT the author opting in. Fusion is invisible at the authoring
//! API: the author writes plain separate blocks; an executor that wants the win
//! routes through `fuse` before committing.
//!
//! WHY THIS IS SOUND. Fusing adjacent rate-1:1, type-stable, single-consumer `Map`s
//! `g ∘ f` into one block-size-1 pass is denotationally identity and bit-exact:
//! `(g ∘ f)(x) = g(f(x))` holds sample-for-sample, and the `Subgraph` driver runs the
//! inner chain at window length 1 so the intermediate value never round-trips memory
//! (it stays in a register / the inner pool). This is plain categorical composition
//! of morphisms; fusion changes traffic, never values.
//!
//! WHAT IS NEVER FUSED (the two landmines, restated inline rather than cited):
//!   * Never fuse across a FAN-OUT value. If `u`'s output has more than one reader,
//!     folding `u` into a downstream block would destroy the buffer the other readers
//!     still need. We require `u`'s produced value to be single-consumer across BOTH
//!     forward edges and feedback read-sides.
//!   * Never fuse a FEEDBACK producer or consumer. A `z⁻¹` edge must stay visible to
//!     the scheduler (its persistent buffer carries state across the callback); a Map
//!     that writes or reads a declared `FeedbackEdge` is left unfused.
//! Also left unfused: sources, delay elements, rate-changing blocks, param-bearing or
//! event-consuming Maps (v1 scope — the `Subgraph` combinator forwards no control
//! plane), and the synthesized coercion / channel-matrix / PDC / bypassed nodes. Each
//! exclusion keeps the rewrite a strict contraction of non-feedback linear runs, so
//! the rewritten graph still passes source-rootedness and SCC-has-delay (fusion only
//! coalesces nodes that were already a simple linear run).
//!
//! Fusion is ORTHOGONAL to in-place coalescing: coalescing reduces footprint (shares
//! buffers), fusion reduces traffic (elides the intermediate round-trip). A coalesced
//! `aliasing_safe` chain is in fact the BEST fusion target, so — unlike the coalescing
//! gate — `fuse` does NOT require `aliasing_safe`.
//!
//! THE WIN IS TRAFFIC / FOOTPRINT, NOT LATENCY. Measured: displacement-per-render drops
//! sharply (the intermediate pool buffers vanish), but driving the chain one sample at a
//! time forfeits each kernel's per-window vectorisation, so wall-clock is WORSE than the
//! unfused chain. So fusion is opt-in and OFF by default — applied only via a dedicated
//! fused executor / offline wrapper, the right lever for SRAM- or bus-constrained
//! embedded targets; the base single-core and runtime engines never fuse. Treating it as
//! a throughput optimisation would be a mistake.

const std = @import("std");
const graph = @import("graph.zig");
const port = @import("port.zig");
const combinators = @import("combinators.zig");

/// Where an ORIGINAL node's block instance lands in the fused graph. A passthrough
/// node maps to one new top-level node id; a fused node maps to a position INSIDE a
/// `Subgraph`'s inner executor (the body position between its `Inlet` and `Outlet`).
pub const Route = union(enum) {
    /// The node survived as its own top-level node `id` in the fused graph.
    passthrough: usize,
    /// The node was folded into the `Subgraph` at top-level node `node`; its block
    /// instance lives at inner node id `inner` of that Subgraph's inner executor.
    fused: struct { node: usize, inner: usize },
};

/// The result of fusing a graph: the rewritten graph, its node-id-ordered block
/// tuple, and the per-original-node routing table (`route[i]` tells where original
/// node `i`'s seed instance goes). `route.len == g.node_count`.
pub const FuseResult = struct {
    graph: graph.Graph,
    blocks: []const type,
    route: []const Route,
};

/// Is node `m` a *candidate* to participate in fusion at all — a plain author Map
/// that is rate-1:1, not a source/delay, not a synthesized coercion/matrix/PDC node,
/// not bypassed, and (v1 scope) declares no parameter ports and consumes no event
/// lane? A non-candidate is always left as its own passthrough node.
fn isFusableNode(comptime g: graph.Graph, comptime node_blocks: []const type, comptime m: usize) bool {
    const n = g.nodes[m];
    if (n.class != .Map) return false;
    if (n.out_per_in_p != n.out_per_in_q) return false; // rate-1:1 only
    if (n.is_source or n.is_delay) return false;
    if (n.is_coercion or n.is_channel_matrix or n.is_pdc or n.bypassed) return false;
    const Block = node_blocks[m];
    // The Subgraph wires its body as a single linear run Inlet → n1 → … → nk →
    // Outlet, so every fusable member must be a unary single-in / single-out Map.
    // This also excludes sinks (zero outputs — no value to fold forward, no element
    // for the Outlet) and multi-port Maps (a summer / splitter the linear wiring
    // can't express). Sources (zero inputs) are already excluded by `is_source`.
    if (port.mapInputCount(Block) != 1) return false;
    if (port.mapOutputCount(Block) != 1) return false;
    // Param-bearing or event-consuming Maps are a fusion boundary: the Subgraph
    // combinator forwards no control plane, so wrapping one would strand its control
    // inputs. Leaving it unfused is still correct.
    if (@hasDecl(Block, "params")) return false;
    if (port.isEventConsumer(Block)) return false;
    // A node that writes or reads a declared feedback edge must stay scheduler-
    // visible (its z⁻¹ buffer persists across the callback); never fold it.
    for (g.feedback[0..g.feedback_count]) |f| {
        if (f.write_node == m or f.read_node == m) return false;
    }
    return true;
}

/// Count the consumers of node `m`'s output value across BOTH forward edges and
/// feedback read-sides — the single-consumer test for a fusable producer. (A
/// rate-1:1 candidate Map has exactly one output port, so "the producer port" is
/// unambiguous and we count every reader of node `m`'s output.)
fn outputConsumerCount(comptime g: graph.Graph, comptime m: usize) usize {
    var c: usize = 0;
    for (g.edges[0..g.edge_count]) |e| {
        if (e.from_node == m) c += 1;
    }
    for (g.feedback[0..g.feedback_count]) |f| {
        if (f.write_node == m) c += 1;
    }
    return c;
}

/// The number of forward (non-param) sample input edges into node `v`, and the index
/// of the last such edge (valid only when the count is exactly 1).
fn forwardInputInfo(comptime g: graph.Graph, comptime v: usize) struct { count: usize, edge: usize } {
    var count: usize = 0;
    var edge: usize = 0;
    for (g.edges[0..g.edge_count], 0..) |e, ei| {
        if (e.to_node == v and !e.is_param) {
            count += 1;
            edge = ei;
        }
    }
    return .{ .count = count, .edge = edge };
}

/// Is the directed pair `u → v` fusable? Both must be fusable candidates, and the
/// *traffic* contract must hold: `v` has exactly one forward sample input and it comes
/// from `u`; `u`'s output value is single-consumer (so folding it strands no other
/// reader); and the `u → v` edge is type-stable (`u.out_elem_name` equals the edge's
/// carried element name, so the intermediate is one pool class). This mirrors the
/// in-place-coalescing gate's structural checks but is about TRAFFIC, not aliasing —
/// so it deliberately does NOT require `aliasing_safe`.
fn pairFusable(comptime g: graph.Graph, comptime node_blocks: []const type, comptime u: usize, comptime v: usize) bool {
    if (!isFusableNode(g, node_blocks, u)) return false;
    if (!isFusableNode(g, node_blocks, v)) return false;
    const fin = forwardInputInfo(g, v);
    if (fin.count != 1) return false; // v must be unary on the sample side
    const ein = g.edges[fin.edge];
    if (ein.from_node != u) return false; // v's sole sample input must come from u
    if (outputConsumerCount(g, u) != 1) return false; // u single-consumer (no fan-out)
    // Type-stable: u's output element class equals the carried element on the u→v
    // edge, so the fused intermediate is exactly one value type (no coercion hides
    // between them). `to_elem_name` non-empty would mean a layout coercion is pending
    // on this edge — never fuse across that.
    if (ein.to_elem_name.len != 0) return false;
    if (!std.mem.eql(u8, g.nodes[u].out_elem_name, ein.elem_name)) return false;
    return true;
}

/// The maximal-chain grouping of `g`'s nodes. `head[i]` is the original node id that
/// HEADS the chain node `i` belongs to (a length-1 chain heads itself); `next[i]` is
/// the original node id immediately after `i` in its chain, or `i` itself at the tail.
const Grouping = struct {
    head: [graph.max_nodes]usize,
    next: [graph.max_nodes]usize,
    /// True iff node `i` is the head of a chain of length ≥ 2 (a genuinely fused run).
    is_fused_head: [graph.max_nodes]bool,
    /// The fused-chain length when `i` is a head (1 for a passthrough singleton).
    chain_len: [graph.max_nodes]usize,
};

/// Topo-sort `g` (Kahn with a min-node-id tie-break, mirroring the commit pass so the
/// greedy chain walk sees nodes in the same deterministic order the scheduler does),
/// then greedily grow maximal fusable chains. A node may belong to at most one chain;
/// once `u` is chained to a successor `v`, neither is reconsidered as another chain's
/// member. Greedy over topo order yields maximal linear runs because each fusable pair
/// is unique (single producer in, single consumer out).
fn computeGrouping(comptime g: graph.Graph, comptime node_blocks: []const type) Grouping {
    const NC = g.node_count;
    // ---- Kahn topo with ascending-id tie-break (same as the commit pass) --------
    var indeg = [_]usize{0} ** graph.max_nodes;
    for (g.edges[0..g.edge_count]) |e| indeg[e.to_node] += 1;
    var topo: [graph.max_nodes]usize = undefined;
    var topo_len: usize = 0;
    var placed = [_]bool{false} ** graph.max_nodes;
    while (topo_len < NC) {
        var pick: ?usize = null;
        var v: usize = 0;
        while (v < NC) : (v += 1) {
            if (placed[v] or indeg[v] != 0) continue;
            pick = v;
            break;
        }
        const w = pick orelse break;
        placed[w] = true;
        topo[topo_len] = w;
        topo_len += 1;
        for (g.edges[0..g.edge_count]) |e| {
            if (e.from_node != w) continue;
            indeg[e.to_node] -= 1;
        }
    }

    var grp: Grouping = .{
        .head = undefined,
        .next = undefined,
        .is_fused_head = [_]bool{false} ** graph.max_nodes,
        .chain_len = [_]usize{1} ** graph.max_nodes,
    };
    var i: usize = 0;
    while (i < NC) : (i += 1) {
        grp.head[i] = i;
        grp.next[i] = i; // tail-points-to-self until linked
    }

    // `in_chain[m]` marks a node already absorbed into some chain (as a non-head
    // member OR as a head that has grown a successor) so it is not re-walked.
    var consumed = [_]bool{false} ** graph.max_nodes;
    var ti: usize = 0;
    while (ti < topo_len) : (ti += 1) {
        const start = topo[ti];
        if (consumed[start]) continue;
        // Grow the chain forward from `start` while the next pair is fusable and the
        // successor is not already part of another chain.
        var cur = start;
        var len: usize = 1;
        grow: while (true) {
            // Find the unique forward consumer of `cur` that forms a fusable pair.
            var found: ?usize = null;
            var ei: usize = 0;
            while (ei < g.edge_count) : (ei += 1) {
                const e = g.edges[ei];
                if (e.from_node != cur or e.is_param) continue;
                const cand = e.to_node;
                if (consumed[cand]) continue;
                if (grp.head[cand] != cand) continue; // already a chain member
                if (pairFusable(g, node_blocks, cur, cand)) {
                    found = cand;
                    break;
                }
            }
            const nxt = found orelse break :grow;
            // Link cur → nxt into `start`'s chain.
            grp.next[cur] = nxt;
            grp.head[nxt] = start;
            consumed[cur] = true;
            consumed[nxt] = true; // a tail; reset to allow further growth below
            cur = nxt;
            len += 1;
        }
        if (len >= 2) {
            grp.is_fused_head[start] = true;
            grp.chain_len[start] = len;
        }
    }
    return grp;
}

/// Build the inner `Subgraph` block type for a fused chain headed at original node
/// `start` of length `len`. The inner graph is wired `Inlet(InElem) → n1 → … → nk →
/// Outlet(OutElem)` where InElem is the head's Map input element and OutElem is the
/// tail's Map output element. Inner node ids are: Inlet = 0, the chain members =
/// 1..len (in chain order), Outlet = len + 1. The combinator drives this inner graph
/// at window length 1, folding the `len` kernels into one fused pass.
fn FusedBlock(comptime g: graph.Graph, comptime node_blocks: []const type, comptime start: usize, comptime len: usize) type {
    const grp = computeGroupingChain(g, node_blocks, start, len);
    const head_block = node_blocks[grp[0]];
    const tail_block = node_blocks[grp[len - 1]];
    const InElem = port.MapInElem(head_block);
    const OutElem = port.MapOutElem(tail_block);

    const Inlet = combinators.Inlet(InElem);
    const Outlet = combinators.Outlet(OutElem);

    // sub_blocks in inner node-id order: Inlet, the chain members, Outlet.
    const sub_blocks = comptime blk: {
        var sb: [len + 2]type = undefined;
        sb[0] = Inlet;
        var j: usize = 0;
        while (j < len) : (j += 1) sb[j + 1] = node_blocks[grp[j]];
        sb[len + 1] = Outlet;
        const fixed = sb;
        break :blk fixed;
    };

    // The inner graph: Inlet → n1, n_j → n_{j+1}, n_k → Outlet. The Inlet's output
    // and the Outlet's input are typed via the endpoint blocks; the interior edges
    // use each member Map's own out/in PortId, so the type check on each connect is
    // the same one the author's separate edges passed.
    const inner_g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 1; // window length 1 is the fusion mechanism (one inner pass)
        gg.sample_rate = g.sample_rate;
        const inlet = gg.add(Inlet);
        var ids: [len]usize = undefined;
        var j: usize = 0;
        while (j < len) : (j += 1) ids[j] = gg.add(node_blocks[grp[j]]);
        const outlet = gg.add(Outlet);
        // Inlet → first member, port 0.
        gg.connect(port.MapOutPort(Inlet), inlet, 0, port.MapInPort(node_blocks[grp[0]]), ids[0], 0);
        // Member j → member j+1.
        j = 0;
        while (j + 1 < len) : (j += 1) {
            gg.connect(
                port.MapOutPort(node_blocks[grp[j]]),
                ids[j],
                0,
                port.MapInPort(node_blocks[grp[j + 1]]),
                ids[j + 1],
                0,
            );
        }
        // Last member → Outlet.
        gg.connect(port.MapOutPort(node_blocks[grp[len - 1]]), ids[len - 1], 0, port.MapInPort(Outlet), outlet, 0);
        break :blk gg;
    };

    return combinators.Subgraph(inner_g, &sub_blocks);
}

/// Re-derive the ordered chain member ids for the chain headed at `start` (length
/// `len`) by walking `next` again. Returned as a fixed array of original node ids in
/// chain order (`grp[0] == start`, `grp[len-1]` is the tail).
fn computeGroupingChain(comptime g: graph.Graph, comptime node_blocks: []const type, comptime start: usize, comptime len: usize) [len]usize {
    const grouping = computeGrouping(g, node_blocks);
    var out: [len]usize = undefined;
    var cur = start;
    var j: usize = 0;
    while (j < len) : (j += 1) {
        out[j] = cur;
        cur = grouping.next[cur];
    }
    return out;
}

/// `fuse(g, node_blocks)` — the pure, total comptime rewrite. Detects maximal fusable
/// `Map` chains and replaces each with one `combinators.Subgraph` node; every other
/// node passes through unchanged. Returns the rewritten graph, its node-id-ordered
/// block tuple, and the per-original-node routing table. A graph with no fusable chain
/// returns an isomorphic copy with all-passthrough routes. No allocator — every array
/// is comptime-bounded by `graph.max_nodes`.
pub fn fuse(comptime g: graph.Graph, comptime node_blocks: []const type) FuseResult {
    comptime {
        // The rewrite walks the node/edge arrays several times and re-derives each
        // fused chain's grouping; raise the comptime branch budget so a graph near the
        // node ceiling still evaluates (the default 1000 is exhausted by the repeated
        // O(nodes·edges) scans plus the per-fused-block inner-graph construction).
        @setEvalBranchQuota(100_000);
        const NC = g.node_count;
        const grp = computeGrouping(g, node_blocks);

        // Assign new top-level node ids by walking original ids in ascending order;
        // the first time we meet a chain HEAD (or a passthrough singleton) we mint the
        // next new id. Non-head chain members never get their own new id (they fold
        // into the head's fused node). `new_id[m]` is the new top-level id of the node
        // original `m` lands in.
        var new_id: [graph.max_nodes]usize = undefined;
        var new_block: [graph.max_nodes]type = undefined;
        var new_count: usize = 0;
        var m: usize = 0;
        while (m < NC) : (m += 1) {
            if (grp.head[m] != m) continue; // a non-head chain member — folded away
            const nid = new_count;
            new_id[m] = nid;
            if (grp.is_fused_head[m]) {
                new_block[nid] = FusedBlock(g, node_blocks, m, grp.chain_len[m]);
            } else {
                new_block[nid] = node_blocks[m];
            }
            new_count += 1;
        }
        // Propagate the head's new id to every chain member, so an edge endpoint on a
        // folded node resolves to its containing fused node.
        m = 0;
        while (m < NC) : (m += 1) new_id[m] = new_id[grp.head[m]];

        // Build the rewritten graph: add nodes (in new-id order), then rewire edges.
        var g2 = graph.Graph.empty;
        g2.block_size = g.block_size;
        g2.sample_rate = g.sample_rate;
        var added: usize = 0;
        while (added < new_count) : (added += 1) {
            _ = g2.add(new_block[added]);
        }
        // `add` recomputes every node-derived fact from the (possibly Subgraph) block
        // type, which is correct. Carry over the per-node MUTABLE flags a passthrough
        // node may have had set after `add` in the original graph (bypass / PDC /
        // set-param / coercion-kind markers). A fused node is a fresh Subgraph Map with
        // none of these, so only passthrough nodes copy them.
        m = 0;
        while (m < NC) : (m += 1) {
            if (grp.head[m] != m or grp.is_fused_head[m]) continue;
            const dst = new_id[m];
            const src = g.nodes[m];
            g2.nodes[dst].bypassed = src.bypassed;
            g2.nodes[dst].pdc_compensated = src.pdc_compensated;
            g2.nodes[dst].is_coercion = src.is_coercion;
            g2.nodes[dst].is_channel_matrix = src.is_channel_matrix;
            g2.nodes[dst].is_pdc = src.is_pdc;
            g2.nodes[dst].set_param_slots = src.set_param_slots;
            g2.nodes[dst].rate_domain = src.rate_domain;
            g2.nodes[dst].sample_rate = src.sample_rate;
        }

        // ---- forward edges -------------------------------------------------------
        // Keep only edges that CROSS a fused-node boundary (or connect two distinct
        // new nodes). An edge entirely INTERNAL to one chain (its from/to fold into the
        // same fused node) is absorbed by the Subgraph and dropped. An edge feeding the
        // chain HEAD retargets its `to_node` to the fused node (input port 0); an edge
        // leaving the chain TAIL re-sources its `from_node` from the fused node (output
        // port 0). All other field values (`elem_*`, `is_param`, ports, channel info)
        // are preserved verbatim.
        var ei: usize = 0;
        while (ei < g.edge_count) : (ei += 1) {
            const e = g.edges[ei];
            const fn_new = new_id[e.from_node];
            const tn_new = new_id[e.to_node];
            if (fn_new == tn_new) continue; // internal to one (fused) node — absorbed
            var ne = e;
            ne.from_node = fn_new;
            ne.to_node = tn_new;
            // If the producer side folded into a fused node, the chain TAIL's output is
            // the fused node's single output port 0.
            if (grp.head[e.from_node] != e.from_node or grp.is_fused_head[e.from_node])
                ne.from_port = 0;
            // If the consumer side folded into a fused node, the chain HEAD's input is
            // the fused node's single input port 0.
            if (grp.head[e.to_node] != e.to_node or grp.is_fused_head[e.to_node])
                ne.to_port = 0;
            g2.edges[g2.edge_count] = ne;
            g2.edge_count += 1;
        }

        // ---- feedback edges ------------------------------------------------------
        // A fusable node never writes or reads a feedback edge (the gate excludes
        // them), so a feedback endpoint is always a passthrough node — its new id is a
        // plain re-index and the port is unchanged. Copy verbatim with re-indexed
        // endpoints.
        var fi: usize = 0;
        while (fi < g.feedback_count) : (fi += 1) {
            var fe = g.feedback[fi];
            fe.write_node = new_id[fe.write_node];
            fe.read_node = new_id[fe.read_node];
            g2.feedback[g2.feedback_count] = fe;
            g2.feedback_count += 1;
        }

        // ---- route table ---------------------------------------------------------
        // For each original node: a passthrough head maps to its new id; a folded chain
        // member maps to its fused node + its inner body position. The inner body
        // position of chain member at chain index `j` (0-based) is `j + 1` (inner id 0
        // is the Inlet; the body runs 1..len; the Outlet is len+1).
        var route: [graph.max_nodes]Route = undefined;
        m = 0;
        while (m < NC) : (m += 1) {
            const head = grp.head[m];
            if (!grp.is_fused_head[head]) {
                route[m] = .{ .passthrough = new_id[m] };
            } else {
                // Find m's 0-based position in its chain by walking `next` from head.
                var pos: usize = 0;
                var cur = head;
                while (cur != m) : (pos += 1) cur = grp.next[cur];
                route[m] = .{ .fused = .{ .node = new_id[head], .inner = pos + 1 } };
            }
        }

        // Freeze the comptime-var arrays into constants the result can reference.
        const blocks_final = new_block[0..new_count].*;
        const route_final = route[0..NC].*;
        const g_final = g2;
        return .{
            .graph = g_final,
            .blocks = &blocks_final,
            .route = &route_final,
        };
    }
}
