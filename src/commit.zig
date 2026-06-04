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
    /// PARAMETER-edge inputs, kept SEPARATE from sample inputs. A parameter port
    /// is a control-rate side input (catalog §2.4 P1): it does not appear in the
    /// block's `process` signature (M1 ranges over sample slices only), so the
    /// executor must NOT consume it as a `process` argument. Instead, before
    /// invoking `process`, the executor reads the latest control value from each
    /// param-edge buffer and applies it to the block's parameter slot via the
    /// block's `setParam(slot, value)` — the in-graph analogue of `set`, ramped/
    /// held by the consumer exactly as `set` is (P3). `param_input_slots[i]` is the
    /// parameter-port index the i-th param edge drives.
    param_input_buffer_ids: [port.max_ports_per_direction]usize = [_]usize{0} ** port.max_ports_per_direction,
    param_input_slots: [port.max_ports_per_direction]u8 = [_]u8{0} ** port.max_ports_per_direction,
    param_input_count: usize = 0,
    /// RUNTIME-bound marker: this op is an auto-inserted RESAMPLER coercion whose
    /// `self_ptr` is an `io.RuntimeResampler`. The runtime render reads its
    /// phase-stateful `needed_input` to set the producer op's per-callback output
    /// count (the dynamic count that makes a non-integer SRC drift-free). False on
    /// the comptime path (no coercions are auto-inserted there). Carried IN the plan
    /// (RCU-published) so the render never reads engine state racily.
    is_resampler: bool = false,
    /// The op index (in this plan's op-list) whose output feeds this resampler's
    /// input — the op whose per-callback count the render overrides to `needed_input`.
    resampler_producer_op: usize = 0,
};

/// The committed plan: a flat op-list (one op per node, forward-topo order) plus
/// the static footprint. `footprint_bytes` is a comptime constant for a comptime
/// graph, so it can size a `[footprint_bytes]u8` pool in `.bss`.
///
/// Beyond the op-list and the single footprint figure, the plan carries the
/// **pool layout** the executor needs to turn an op's `*_buffer_ids` into real
/// byte slices: each buffer id maps to a `[offset, offset+len)` window in the
/// engine's flat pool. The pool window is contiguous per element-class (a class's
/// `M` colored buffers sit back-to-back), and `len` is `N · element_size` for the
/// class.
///
/// **The pool tail (persistent region).** Feedback `z⁻¹` buffers live PAST
/// `pool_bytes`, in `[pool_bytes, pool_bytes + persistent_bytes)`. Each feedback
/// edge carries one block of `N` elements across the callback boundary (its read
/// side reads the value its write side stored last block), so it gets one
/// `N·element_size` buffer that is **never colored and never zeroed mid-stream** —
/// the colored pool ahead of it is scratch (overwritten every block), the tail is
/// state (survives every block). The executor therefore allocates
/// `pool_bytes + persistent_bytes`; the colored prefix is the only part that is
/// reused across ops within one render.
///
/// `footprint_bytes` is the separate **H2 reporting figure** — the static memory
/// the graph needs by the locked formula `pools + Σ delay-rings + Σ block-state`.
/// Delay-element rings and per-block state live INSIDE the block instances
/// (allocated once at `initialize`, like ramp state), so they are counted by
/// `footprint_bytes` but do not appear in the executor's flat pool; the pool tail
/// holds only the feedback `z⁻¹` buffers. For a graph with no feedback,
/// `persistent_bytes == 0` and `pool_bytes == footprint_bytes`.
pub fn Plan(comptime n_ops: usize) type {
    return struct {
        ops: [n_ops]RenderOp,
        op_count: usize,
        footprint_bytes: usize,
        /// Which buffer-assignment strategy produced this plan.
        buffer_mode: BufferMode,
        /// Number of distinct pool buffer ids (across all element classes).
        pool_buffer_count: usize = 0,
        /// Total bytes the colored/per-edge pools occupy (the executor's scratch
        /// region). Excludes the persistent feedback tail.
        pool_bytes: usize = 0,
        /// Bytes the persistent feedback `z⁻¹` buffers occupy in the pool tail
        /// (`Σ feedback-edge  N · element_size`). The executor's flat pool is
        /// `pool_bytes + persistent_bytes`; this prefix-vs-tail split is what lets
        /// a feedback value survive a callback while scratch buffers are reused.
        persistent_bytes: usize = 0,
        /// Byte offset of each buffer id (pool color OR persistent feedback) into
        /// the engine's flat pool.
        buffer_offset: [graph.max_buffers]usize = [_]usize{0} ** graph.max_buffers,
        /// Byte length of each buffer id (`N · element_size` of its class).
        buffer_byte_len: [graph.max_buffers]usize = [_]usize{0} ** graph.max_buffers,
        /// For each POOL buffer id, the op index (forward-topo position) of the LAST
        /// read across every value that occupies it — the point after which the
        /// buffer is dead for the remainder of the render. `-1` marks an unused id
        /// AND every PERSISTENT feedback id (those survive the callback boundary and
        /// must NEVER be poisoned). The paranoid NaN-poison executor uses this to
        /// fill a retired pool buffer with NaN the instant its live range ends, so a
        /// colorer/coalescing bug that reads a buffer past its last legitimate
        /// reader surfaces as a NaN at the sink rather than as silently stale data.
        buffer_last_use: [graph.max_buffers]isize = [_]isize{-1} ** graph.max_buffers,
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
    /// A BYPASSED block with `algorithmic_latency > 0` has no compensating delay,
    /// so bypassing it would shift timing and break alignment on parallel paths
    /// (the bypass-preserves-latency law). Route the bypass through a compensating
    /// delay (the plugin-delay-compensation pass, `insertPdc`) instead of around it.
    BypassLatencyUncompensated,
    /// A node has two or more SAMPLE inputs that live on DIFFERENT rate domains
    /// (different out:in scale relative to the source) with no rate adapter between
    /// them. Mixed-rate sample fan-in is never implicitly reconciled — insert an
    /// explicit resampler/framer; only a parameter port auto-coerces across rates.
    MixedRateInputs,
    /// A GROWABLE sink (a `FeatureCollectorSink`, which may `realloc` past its
    /// capacity hint) was committed for a REALTIME root. A growing reallocation
    /// cannot sit on the audio deadline — growable sinks are legal only on a non-RT
    /// pull root (the contained H1 exception). Drive this graph as an analysis root
    /// (`commitAnalysis` / `runToCompletion`) instead, or remove the growable sink
    /// from the realtime path and tap it from a separate non-RT root. (Law A8.)
    GrowableSinkOnRealtimeRoot,
};

/// Commit a graph at COMPTIME with the shipped colored pool. See `commitComptimeMode`.
pub fn commitComptime(comptime g: graph.Graph) CommitError!Plan(g.node_count) {
    return commitComptimeMode(g, .colored);
}

fn gcd(a: usize, b: usize) usize {
    var x = a;
    var y = b;
    while (y != 0) {
        const r = x % y;
        x = y;
        y = r;
    }
    return if (x == 0) 1 else x;
}

/// The windowed-sinc prototype half-width an auto-inserted resampler coercion uses.
/// Shared between this pass (its declared `algorithmic_latency`) and the runtime
/// engine's bound `io.RuntimeResampler` kernel, so the declared latency matches the
/// kernel's actual group delay.
pub const resampler_half: usize = 16;

/// A reduced rational `num/den`.
const Rational = struct { num: usize, den: usize };

fn reduce(num: usize, den: usize) Rational {
    const g = gcd(num, den);
    return .{ .num = num / g, .den = den / g };
}

/// Audio-samples-per-output-element (`apa`) for every node, by a forward sweep in
/// topo order — the rate-domain scale relative to the source clock. A source ticks
/// at `1`; a node with rate ratio `p:q` (p out per q in) over an input at `apa_in`
/// produces output elements that each span `apa_in · q / p` audio samples (a
/// `Framer` 1:HOP → `apa · HOP`; an `iStft` HOP:1 → `apa / HOP`). The latency DP
/// (`insertPdc`) and the multi-rate fan-in check both read this to put every
/// branch's latency in one common (audio-sample) domain before comparing. `apa` is
/// taken from a node's FIRST sample input; mixed-rate sample fan-in (where that
/// choice would matter) is rejected separately.
fn computeApa(g: graph.Graph, topo: []const usize) [graph.max_nodes]Rational {
    const EC = g.edge_count;
    var apa: [graph.max_nodes]Rational = undefined;
    for (0..graph.max_nodes) |i| apa[i] = .{ .num = 1, .den = 1 };
    for (topo) |v| {
        // Find this node's first sample (non-param) input producer.
        var in_apa: ?Rational = null;
        for (g.edges[0..EC]) |e| {
            if (e.to_node != v or e.is_param) continue;
            in_apa = apa[e.from_node];
            break;
        }
        if (in_apa) |ia| {
            const p = g.nodes[v].out_per_in_p;
            const q = g.nodes[v].out_per_in_q;
            apa[v] = reduce(ia.num * q, ia.den * p);
        } else {
            // A source re-bases the rate domain to the PIPELINE clock: apa =
            // pipeline_rate / source_rate (sink-clock samples per source element).
            // For an all-same-rate graph this is 1/1 (backward-compatible); for a
            // source feeding a resampler (out_per_in = consumer:producer), the
            // propagation above then yields apa = 1 downstream of the resampler, so
            // a resampled stream merges cleanly with a native-pipeline stream and
            // the PDC DP converts latency across the clock bridge automatically.
            const sr = g.nodes[v].sample_rate;
            apa[v] = if (sr == 0 or g.sample_rate == 0) .{ .num = 1, .den = 1 } else reduce(g.sample_rate, sr);
        }
    }
    return apa;
}

/// Kahn topological sort over the forward DAG (feedback edges excluded), min-node-id
/// tie-break — the same order the commit pass uses. `ok` is false on a surviving
/// cycle (an undeclared loop). Comptime-evaluable (fixed arrays, no allocator).
fn topoSort(g: graph.Graph) struct { order: [graph.max_nodes]usize, len: usize, ok: bool } {
    const NC = g.node_count;
    const EC = g.edge_count;
    var indeg: [graph.max_nodes]usize = [_]usize{0} ** graph.max_nodes;
    for (g.edges[0..EC]) |e| indeg[e.to_node] += 1;
    var order: [graph.max_nodes]usize = undefined;
    var len: usize = 0;
    var placed: [graph.max_nodes]bool = [_]bool{false} ** graph.max_nodes;
    while (len < NC) {
        var pick: ?usize = null;
        for (0..NC) |v| {
            if (placed[v] or indeg[v] != 0) continue;
            pick = v;
            break;
        }
        const v = pick orelse break;
        placed[v] = true;
        order[len] = v;
        len += 1;
        for (g.edges[0..EC]) |e| {
            if (e.from_node == v) indeg[e.to_node] -= 1;
        }
    }
    return .{ .order = order, .len = len, .ok = len == NC };
}

/// The shared commit ALGORITHM — the single body both the comptime and the
/// runtime entry points run. It is ordinary Zig (no `comptime` block), so it
/// evaluates at compile time when called in a comptime context (the embedded
/// smoke gate, the `Executor`) AND runs at runtime when called from the runtime
/// `Engine`'s `edit → commit`. It returns a FIXED-CAPACITY `Plan(graph.max_nodes)`
/// (op count valid in `op_count`); the comptime wrapper repacks it to the exact
/// `Plan(g.node_count)` its callers expect. Sharing this body is the whole point:
/// the comptime path inlines the op-list (zero-overhead Tier-A render) and the
/// runtime path binds `fn_ptr`/`self_ptr` into the SAME `RenderOp`/pool model —
/// only the dispatch differs, never the plan.
fn computePlan(g: graph.Graph, comptime mode: BufferMode) CommitError!Plan(graph.max_nodes) {
    {
        // The Tarjan and per-class colorer loops are bounded by the graph
        // dimensions but their product can be large for a near-max graph; give
        // the comptime interpreter generous branch headroom (a no-op at runtime).
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

        // ---- 1b. bypass-preserves-latency law ------------------------------
        // A bypassed block that has algorithmic latency must STILL delay its signal
        // by exactly that latency, or bypassing shifts timing and breaks alignment
        // on parallel paths. The compensating delay is routed by the plugin-delay-
        // compensation pass (a later phase); until it exists, a bypassed latent
        // block is uncompensated and we reject it loudly rather than silently
        // mis-aligning the audio. A coercion node is never the bypass target.
        for (0..NC) |v| {
            if (g.nodes[v].bypassed and g.nodes[v].algorithmic_latency > 0 and !g.nodes[v].pdc_compensated)
                return error.BypassLatencyUncompensated;
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

        // ---- 3b. multi-input pull rule: no implicit mixed-rate sample fan-in
        // Each input edge is satisfied independently via its producer's rate, and
        // SAME-rate multi-input (sidechain, crossover sum, the dry/wet diamond's
        // audio-domain Mix) is ordinary — aligned later by PDC. But a node fed by
        // two SAMPLE inputs on DIFFERENT rate domains (different audio-samples-per-
        // element scale) needs an explicit rate adapter; pan never reconciles it
        // implicitly. (A parameter port is exempt — it ramp/hold-coerces across
        // rates.) Detected by comparing the producers' `apa` rate-domain scale.
        {
            const apa = computeApa(g, topo[0..NC]);
            for (0..NC) |v| {
                var first: ?Rational = null;
                for (g.edges[0..EC]) |e| {
                    if (e.to_node != v or e.is_param) continue;
                    const a = apa[e.from_node];
                    if (first) |f| {
                        if (f.num != a.num or f.den != a.den) return error.MixedRateInputs;
                    } else first = a;
                }
            }
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

        // ---- rate demand: want[v], computed BEFORE coloring ----------------
        // want[v] = elements v must produce this callback, so a value's pool buffer
        // can be sized by what its producer emits (NOT uniformly by the device N) —
        // a rate-changing producer (an STFT emitting 2 frames per callback) needs a
        // buffer of that many elements, not N. Sinks want N; a producer wants the
        // max over its consumers of needed_input: a consumer with ratio p:q (p out
        // per q in) producing `want[c]` outputs consumes `ceil(want[c]·q/p)` inputs
        // (never assuming the hop divides N — the block's ring absorbs the
        // remainder), a varirate plans on its worst-case (min) ratio, and a source's
        // length is the demand itself. For a rate-1:1 graph every `want[v] == N`, so
        // the buffer sizing below is byte-identical to the pre-P8 uniform-N pools.
        var want: [max_nodes]usize = [_]usize{N} ** max_nodes;
        {
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
                if (has_consumer) want[v] = w;
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
            /// Elements this value's producer emits per callback (`want[from_node]`)
            /// — the SECOND half of the pool class key `(elem_name, want)` and the
            /// per-buffer element count. A rate-1:1 value has `want == N`.
            want: usize,
            color: usize = 0,
            buffer_id: usize = 0,
            /// True iff this value's output port feeds a feedback read-side. Such a
            /// value carries the loop's z⁻¹ across the callback boundary, so it is
            /// **pool-excluded** (never colored): the producer writes it once, this
            /// block's forward consumers read it, and next block's feedback read
            /// reads the SAME buffer because the persistent region is not reused
            /// between callbacks. It gets a persistent id past the scratch pool.
            is_persistent: bool = false,
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
                    .want = want[e.from_node],
                };
                value_count += 1;
            }
        }
        // Mark feedback-source values persistent (pool-excluded), so the colorer
        // below skips them and they receive a persistent id past the scratch pool.
        for (0..value_count) |vi| {
            for (g.feedback[0..FC]) |f| {
                if (values[vi].from_node == f.write_node and values[vi].from_port == f.write_port)
                    values[vi].is_persistent = true;
            }
        }

        // ---- 5b. in-place coalescing gate (colored pool only) --------------
        // A unary `Map` whose author declared `aliasing_safe` may write its
        // output INTO its input buffer — eliding the copy — but ONLY when the
        // colorer proves it safe: (i) the input value is single-consumer (this
        // Map is its sole reader, so overwriting it harms no one), (ii) input and
        // output share element type & count (same class, same byte window), and
        // (iii) the consumer reads before any other producer overwrites — which
        // holds here because the merged value's live range is colored as ONE
        // interval, so no sibling value can claim the buffer mid-span. The output
        // value then *aliases* the input value's buffer (same color), and the emit
        // hands the Map the same pool slice for in and out.
        //
        // This is a hint the colorer MAY honor; a falsely-declared `aliasing_safe`
        // is not trusted but CAUGHT — the B≡C differential renders the same graph
        // pooled (this path, aliased) and per-edge (separate buffers) and asserts
        // bit-identical output, so an unsafe in-place read-after-write diverges and
        // the paranoid NaN-poison names the block. Mode B (`per_edge`) never
        // coalesces: it is exactly that obviously-correct baseline.
        //
        // `alias_root[v]` is a union-find parent: a coalesced output points at the
        // input value it shares a buffer with (chains a→b→c collapse to one root).
        var alias_root: [max_edges]usize = undefined;
        for (0..value_count) |vi| alias_root[vi] = vi;
        if (mode == .colored) {
            for (0..value_count) |vi| {
                const m = values[vi].from_node;
                // The producer must be a rate-1:1 author Map declaring aliasing_safe,
                // and not a source/delay (a generator has no input to alias; a delay
                // / feedback producer's output must persist, never share scratch).
                if (!g.nodes[m].aliasing_safe) continue;
                if (g.nodes[m].is_source or g.nodes[m].is_delay) continue;
                if (g.nodes[m].out_per_in_p != g.nodes[m].out_per_in_q) continue;
                var writes_feedback = false;
                for (g.feedback[0..FC]) |f| {
                    if (f.write_node == m) writes_feedback = true;
                }
                if (writes_feedback) continue;
                // M must be unary: exactly one forward (non-param) sample input, and
                // this value its only produced value.
                var sample_in: usize = 0;
                var in_edge: usize = 0;
                for (g.edges[0..EC], 0..) |e, ei| {
                    if (e.to_node == m and !e.is_param) {
                        sample_in += 1;
                        in_edge = ei;
                    }
                }
                if (sample_in != 1) continue;
                var out_vals: usize = 0;
                for (0..value_count) |k| {
                    if (values[k].from_node == m) out_vals += 1;
                }
                if (out_vals != 1) continue;
                // Resolve the input VALUE u feeding M.
                const ein = g.edges[in_edge];
                var u: ?usize = null;
                for (0..value_count) |k| {
                    if (values[k].from_node == ein.from_node and values[k].from_port == ein.from_port) {
                        u = k;
                        break;
                    }
                }
                const ui = u orelse continue;
                // Identical element type & per-callback count (same pool class & byte
                // window). For a rate-1:1 Map in==out count, so `want` matches; the
                // check also guards a (degenerate) rate-changing producer.
                if (!std.mem.eql(u8, values[ui].elem_name, values[vi].elem_name)) continue;
                if (values[ui].want != values[vi].want) continue;
                // u must be single-consumer: exactly one reader of its producer port
                // across BOTH forward edges and feedback read-sides.
                var consumers: usize = 0;
                for (g.edges[0..EC]) |e2| {
                    if (e2.from_node == ein.from_node and e2.from_port == ein.from_port) consumers += 1;
                }
                for (g.feedback[0..FC]) |f| {
                    if (f.write_node == ein.from_node and f.write_port == ein.from_port) consumers += 1;
                }
                if (consumers != 1) continue;
                // Merge v into u's buffer; extend the root's live range to cover v.
                var root = ui;
                while (alias_root[root] != root) root = alias_root[root];
                alias_root[vi] = root;
                if (values[vi].end > values[root].end) values[root].end = values[vi].end;
            }
        }

        // ---- 6. buffer-id assignment (per_edge baseline OR colored pool) ---
        // The pool class key is the element TYPE name (`@typeName`), and a class's
        // stride is `N · element_size`. Element_count is part of the element type's
        // identity — a `Frame`'s channel count rides in its layout name, a
        // `FeatureFrame(K)`'s K and a `Complex` bin width ride in their names — so
        // two values sharing an `elem_name` necessarily share `@sizeOf` (their type
        // is the same), and a class is UNIFORM-SIZE by construction. The spec's
        // first-fit-decreasing fallback for "heterogeneous element_count within one
        // class" (§4) is therefore UNREACHABLE under this keying: a differing count
        // is a differing name is a differing class. We keep the pure linear
        // left-edge colorer below and ASSERT the invariant here (a uniform-count
        // guard) rather than carry dead FFD bin-packing code — if a future keying
        // ever made a class non-uniform, this assert fires in Debug/ReleaseSafe.
        // The pool class key is `(element_type name, want)`: the element type's
        // `@typeName` (precision + layout + family + frame width all ride in it) AND
        // the per-callback element count. For a rate-1:1 graph every value's `want`
        // is N, so there is one class per element name exactly as before; a
        // rate-changing seam splits same-typed values of different `want` into
        // distinct, uniform-size classes — so each class is uniform by construction
        // and the spec's heterogeneous-count FFD fallback stays unreachable (the
        // assert below stands guard).
        var class_names: [max_edges][]const u8 = undefined;
        var class_elem_size: [max_edges]usize = undefined;
        var class_want: [max_edges]usize = undefined;
        var class_M: [max_edges]usize = [_]usize{0} ** max_edges;
        var class_count: usize = 0;
        for (0..value_count) |vi| {
            var ci: ?usize = null;
            for (0..class_count) |c| {
                if (std.mem.eql(u8, class_names[c], values[vi].elem_name) and class_want[c] == values[vi].want) {
                    ci = c;
                    break;
                }
            }
            if (ci) |c| {
                // Same (name, want) ⇒ same element type & count ⇒ same size.
                std.debug.assert(values[vi].elem_size == class_elem_size[c]);
            } else {
                class_names[class_count] = values[vi].elem_name;
                class_elem_size[class_count] = values[vi].elem_size;
                class_want[class_count] = values[vi].want;
                class_count += 1;
            }
        }
        for (0..class_count) |c| {
            // Gather this class's value indices, sorted by (start, value id). Only
            // buffer ROOTS are colored: a value coalesced in-place into another
            // shares that root's buffer and is assigned its color afterward (so it
            // consumes no color of its own and does not inflate `M_class`).
            var order: [max_edges]usize = undefined;
            var order_len: usize = 0;
            for (0..value_count) |vi| {
                if (alias_root[vi] != vi) continue;
                if (values[vi].is_persistent) continue; // pool-excluded z⁻¹ value
                if (std.mem.eql(u8, values[vi].elem_name, class_names[c]) and values[vi].want == class_want[c]) {
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
        // Propagate each coalesced value's color from its buffer root (a no-op in
        // per_edge mode, where every value is its own root).
        for (0..value_count) |vi| {
            if (alias_root[vi] == vi) continue;
            var root = vi;
            while (alias_root[root] != root) root = alias_root[root];
            values[vi].color = values[root].color;
        }
        var class_base: [max_edges]usize = undefined;
        var total_pool: usize = 0;
        for (0..class_count) |c| {
            class_base[c] = total_pool;
            total_pool += class_M[c];
        }
        for (0..value_count) |vi| {
            if (values[vi].is_persistent) continue; // gets a persistent id below
            for (0..class_count) |c| {
                if (std.mem.eql(u8, values[vi].elem_name, class_names[c]) and values[vi].want == class_want[c]) {
                    values[vi].buffer_id = class_base[c] + values[vi].color;
                    break;
                }
            }
        }
        // Persistent feedback z⁻¹ buffers: one per DISTINCT feedback source
        // (write_node, write_port), with ids past the scratch pool. A source that
        // is also a forward value shares this id — its producer writes it once, and
        // both this block's forward consumers and next block's feedback read-side
        // reference the same persistent buffer. `persist_elem[k]` is that id's
        // element size, for the footprint byte-window layout below.
        var fb_buf: [max_edges]usize = undefined;
        var persist_count: usize = 0;
        var persist_elem: [graph.max_edges]usize = [_]usize{0} ** graph.max_edges;
        var persist_want: [graph.max_edges]usize = [_]usize{0} ** graph.max_edges;
        for (0..FC) |fi| {
            const f = g.feedback[fi];
            var shared: ?usize = null;
            for (0..fi) |fj| {
                if (g.feedback[fj].write_node == f.write_node and g.feedback[fj].write_port == f.write_port) {
                    shared = fb_buf[fj];
                    break;
                }
            }
            if (shared) |id| {
                fb_buf[fi] = id;
                continue;
            }
            const id = total_pool + persist_count;
            persist_elem[persist_count] = f.elem_size;
            persist_want[persist_count] = want[f.write_node];
            persist_count += 1;
            fb_buf[fi] = id;
            for (0..value_count) |vi| {
                if (values[vi].from_node == f.write_node and values[vi].from_port == f.write_port)
                    values[vi].buffer_id = id;
            }
        }
        // Forward edge → its (pool or persistent) producer-value buffer id.
        var edge_buf: [max_edges]usize = undefined;
        for (g.edges[0..EC], 0..) |e, ei| {
            for (0..value_count) |vi| {
                if (values[vi].from_node == e.from_node and values[vi].from_port == e.from_port) {
                    edge_buf[ei] = values[vi].buffer_id;
                    break;
                }
            }
        }

        // ---- 7. rate scheduling — `want[v]` was computed before coloring ---
        // (so a value's buffer is sized by its producer's per-callback output). The
        // op's `n_or_pull_spec` is that `want[v]`: a Map slice length, a Source's
        // pull-demand-set output length, or a Rate `pull`'s output demand.

        // ---- 8. emit — one op per node, forward-topo order ----------------
        var ops: [graph.max_nodes]RenderOp = undefined;
        for (0..NC) |i| {
            const v = topo[i];
            var in_ids: [port.max_ports_per_direction]usize = undefined;
            // A node's sample inputs are placed BY DECLARED PORT INDEX, not in edge-
            // insertion order: a `process` reads its const-port args in declaration
            // (port) order, so `input_buffer_ids[p]` must be the buffer wired to port
            // `p`. A multi-input fan-in (a named `Concat`) may be wired out of port
            // order — wiring `node.in.<name>` by name records the column's port index
            // as `to_port`; placing by `to_port` is what makes the column identity the
            // NAME, not the connect order (so the feature matrix can't be transposed).
            // `max_in_port` tracks the highest port used (forward or feedback-read) so
            // `input_count` packs ports 0..=max densely. Sample inputs are total (every
            // declared input port has exactly one producer), so there are no gaps.
            var max_in_port: isize = -1;
            var pin_ids: [port.max_ports_per_direction]usize = undefined;
            var pin_slots: [port.max_ports_per_direction]u8 = undefined;
            var pin_n: usize = 0;
            var out_ids: [port.max_ports_per_direction]usize = undefined;
            var out_n: usize = 0;
            for (g.edges[0..EC], 0..) |e, ei| {
                if (e.to_node == v) {
                    // A parameter (control) edge is NOT a sample input — it is a
                    // side input applied to a parameter slot before `process`, so
                    // it is gathered separately and never consumed as a `process`
                    // argument. An ordinary sample edge feeds its declared port.
                    if (e.is_param) {
                        pin_ids[pin_n] = edge_buf[ei];
                        pin_slots[pin_n] = e.to_port;
                        pin_n += 1;
                    } else {
                        in_ids[e.to_port] = edge_buf[ei];
                        if (@as(isize, e.to_port) > max_in_port) max_in_port = e.to_port;
                    }
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
            // write-sides are its persistent outputs (the z⁻¹ split). The write-side
            // is deduped against the forward outputs: when the producer's output
            // port ALSO has a forward edge, its value is persistent and the forward
            // edge already routed `out` to the same persistent buffer — the producer
            // still writes exactly one output buffer.
            for (g.feedback[0..FC], 0..) |f, fi| {
                if (f.read_node == v) {
                    // A feedback read-side feeds a declared input port too — place it
                    // by `read_port`, sharing the port-indexed input space with the
                    // forward edges (a port has a single source, so no collision).
                    in_ids[f.read_port] = fb_buf[fi];
                    if (@as(isize, f.read_port) > max_in_port) max_in_port = f.read_port;
                }
                if (f.write_node == v) {
                    var seen = false;
                    for (0..out_n) |k| {
                        if (out_ids[k] == fb_buf[fi]) seen = true;
                    }
                    if (!seen) {
                        out_ids[out_n] = fb_buf[fi];
                        out_n += 1;
                    }
                }
            }
            // Inputs pack densely over ports 0..=max_in_port (every sample input port
            // has a producer, so no gaps); -1 means a pure source/sink (no inputs).
            const in_n: usize = if (max_in_port < 0) 0 else @intCast(max_in_port + 1);
            ops[i] = .{
                .node_id = v,
                .fn_ptr = null,
                .self_ptr = null,
                .input_buffer_ids = in_ids,
                .input_count = in_n,
                .output_buffer_ids = out_ids,
                .output_count = out_n,
                .n_or_pull_spec = want[v],
                .param_input_buffer_ids = pin_ids,
                .param_input_slots = pin_slots,
                .param_input_count = pin_n,
            };
        }

        // ---- 9. footprint + pool layout -----------------------------------
        // Two distinct quantities live here, and conflating them is a bug:
        //
        //   (a) The executor's FLAT POOL = the colored/per-edge scratch region
        //       [0, pool_bytes) PLUS the persistent feedback tail
        //       [pool_bytes, pool_bytes + persistent_bytes). The scratch prefix is
        //       reused across ops; the tail holds each feedback edge's z⁻¹ value
        //       (one block of N elements) so it survives the callback boundary,
        //       never colored and never zeroed mid-stream.
        //
        //   (b) The H2 FOOTPRINT FIGURE — the static memory the graph needs by the
        //       locked formula `pools + Σ delay-ring + Σ block-state (+ Σ PDC)`.
        //       Delay-element rings and per-block state live INSIDE the block
        //       instances (allocated once at initialize, like ramp state), so they
        //       are reported here but are NOT in the flat pool; the flat pool's
        //       tail holds only the feedback z⁻¹ buffers. The plugin-delay term is
        //       zero until that pass lands.
        //
        // While summing, record each buffer id's byte window so the executor can
        // resolve an op's buffer ids into real slices: a class's M colored buffers
        // sit contiguously (each N·element_size wide), then the feedback z⁻¹
        // buffers follow in the tail (ids `total_pool + fi`).
        var buffer_offset: [graph.max_buffers]usize = [_]usize{0} ** graph.max_buffers;
        var buffer_byte_len: [graph.max_buffers]usize = [_]usize{0} ** graph.max_buffers;
        var pool_bytes: usize = 0;
        for (0..class_count) |c| {
            // A class's stride is its per-callback element count `want` × element
            // size (== N × size for a rate-1:1 class — byte-identical to pre-P8).
            const stride = class_want[c] * class_elem_size[c];
            for (0..class_M[c]) |color| {
                const id = class_base[c] + color;
                buffer_offset[id] = pool_bytes;
                buffer_byte_len[id] = stride;
                pool_bytes += stride;
            }
        }
        // Persistent feedback z⁻¹ buffers, in the pool tail past the scratch pool —
        // one per distinct feedback source (deduped above), each `want` elements wide.
        var persistent_bytes: usize = 0;
        for (0..persist_count) |k| {
            const id = total_pool + k;
            const stride = persist_want[k] * persist_elem[k];
            buffer_offset[id] = pool_bytes + persistent_bytes;
            buffer_byte_len[id] = stride;
            persistent_bytes += stride;
        }
        // The H2 reporting figure (delay rings + per-block state are instance-
        // resident — counted, not pooled).
        var footprint: usize = pool_bytes;
        for (0..NC) |v| {
            if (g.nodes[v].is_delay)
                footprint += g.nodes[v].delay_len * g.nodes[v].out_elem_size;
            footprint += g.nodes[v].state_size;
        }

        // Per-pool-buffer last-use op index (for the paranoid NaN-poison executor).
        // Persistent feedback values are skipped, so their ids stay at the `-1`
        // "never poison" sentinel; a pool id's last use is the max `end` over every
        // value (including in-place-coalesced ones, which carry the root's id) that
        // shares it.
        var buffer_last_use: [graph.max_buffers]isize = [_]isize{-1} ** graph.max_buffers;
        for (0..value_count) |vi| {
            if (values[vi].is_persistent) continue;
            const id = values[vi].buffer_id;
            const e: isize = @intCast(values[vi].end);
            if (e > buffer_last_use[id]) buffer_last_use[id] = e;
        }

        return Plan(graph.max_nodes){
            .ops = ops,
            .op_count = NC,
            .footprint_bytes = footprint,
            .buffer_mode = mode,
            .pool_buffer_count = total_pool,
            .pool_bytes = pool_bytes,
            .persistent_bytes = persistent_bytes,
            .buffer_offset = buffer_offset,
            .buffer_byte_len = buffer_byte_len,
            .buffer_last_use = buffer_last_use,
        };
    }
}

/// Commit a graph at COMPTIME under an explicit buffer mode. `.colored` is the
/// shipped pool; `.per_edge` is the obviously-correct baseline the colored pool is
/// differenced against. Repacks the shared `computePlan` result into the exact
/// `Plan(g.node_count)` the comptime callers (`Executor`, smoke gate) consume — a
/// pure copy of the first `node_count` ops, so the returned plan is byte-identical
/// to the pre-refactor output (the layout-agnostic, share-the-algorithm proof).
pub fn commitComptimeMode(comptime g: graph.Graph, comptime mode: BufferMode) CommitError!Plan(g.node_count) {
    comptime {
        const full = try computePlan(g, mode);
        var p: Plan(g.node_count) = .{
            .ops = undefined,
            .op_count = full.op_count,
            .footprint_bytes = full.footprint_bytes,
            .buffer_mode = full.buffer_mode,
            .pool_buffer_count = full.pool_buffer_count,
            .pool_bytes = full.pool_bytes,
            .persistent_bytes = full.persistent_bytes,
            .buffer_offset = full.buffer_offset,
            .buffer_byte_len = full.buffer_byte_len,
            .buffer_last_use = full.buffer_last_use,
        };
        for (0..g.node_count) |i| p.ops[i] = full.ops[i];
        return p;
    }
}

/// Commit an already-finalized graph to a fixed-capacity plan (`op_count` valid),
/// running the SAME `computePlan` algorithm at runtime — no coercion insertion
/// (the graph is taken as-is). The runtime `Engine` uses this on the
/// post-`insertCoercions` graph so it can bind coercion-node kernels itself.
pub fn commitGraph(g: graph.Graph, comptime mode: BufferMode) CommitError!Plan(graph.max_nodes) {
    return computePlan(g, mode);
}

/// Commit a RUNTIME-built graph: first NEGOTIATE — insert the coercion morphisms a
/// Format mismatch needs (a resampler on a sample-rate mismatch) so the diagram
/// commutes — then run the shared `computePlan` over the result. This is the
/// `edit → commit` control verb's off-thread plan build. The caller (the runtime
/// `Engine`) binds each op's `fn_ptr`/`self_ptr` to the node's render thunk +
/// instance (a built-in kernel for an inserted coercion node), and publishes the
/// result with an RCU pointer swap. Reuses `RenderOp`/`Plan`/the pool-by-buffer-id
/// layout verbatim — there is no second IR.
pub fn commitRuntime(g: graph.Graph, comptime mode: BufferMode) CommitError!Plan(graph.max_nodes) {
    return computePlan(insertPdc(insertCoercions(g)), mode);
}

/// The negotiation insertion step (runtime path): where a wired edge crosses a
/// sample-rate boundary, insert a **resampler** coercion node so the producer →
/// consumer square commutes — the categorical "make the diagram commute" made
/// concrete (catalog §6). `producer → consumer` becomes `producer → resampler →
/// consumer`; the resampler's output sits at the consumer's rate. The resampler's
/// numerical body (polyphase sinc) is a later phase; the node is tagged
/// `is_coercion` and the runtime engine binds a built-in kernel for it. Only
/// sample-rate mismatches are auto-inserted here; an unregistered channel-layout
/// pair is a hard mismatch (rejected in `computePlan`), and a precision cast on a
/// wired edge cannot arise (element identity is proven at `connect`). Iterates the
/// ORIGINAL edges once (snapshot), appending the coercion nodes/edges past them.
pub fn insertCoercions(g: graph.Graph) graph.Graph {
    var g2 = g;
    const orig_edges = g2.edge_count;
    var ei: usize = 0;
    while (ei < orig_edges) : (ei += 1) {
        const e = g2.edges[ei];
        const producer_rate = g2.nodes[e.from_node].sample_rate;
        const consumer_rate = g2.nodes[e.to_node].sample_rate;
        if (producer_rate == consumer_rate) continue; // diagram already commutes
        if (g2.node_count >= graph.max_nodes or g2.edge_count >= graph.max_edges) continue; // capacity guard

        const cid = g2.node_count;
        const orig_to = e.to_node;
        const orig_to_port = e.to_port;
        // The resampler is a real `Rate` node: out_per_in = (consumer:producer)
        // reduced (p outputs per q inputs), with the windowed-sinc group delay. The
        // want-keyed buffer sizing + the runtime engine's dynamic per-callback count
        // (driven by the kernel's phase-stateful `needed_input`) make it correct;
        // `resampler_half` matches the bound kernel's prototype half-width.
        const rr = reduce(consumer_rate, producer_rate); // p:q = out:in
        const up = @max(rr.num, rr.den);
        const lat = (resampler_half * up + rr.num) / rr.den;
        g2.nodes[cid] = .{
            .id = cid,
            .class = .Map,
            .type_name = "(resampler)",
            .out_elem_size = e.elem_size,
            .out_elem_name = e.elem_name,
            .is_source = false,
            .is_delay = false,
            .delay_len = 0,
            .algorithmic_latency = lat,
            .out_per_in_p = rr.num,
            .out_per_in_q = rr.den,
            .aliasing_safe = false,
            .state_size = 0,
            .rate_domain = g2.nodes[orig_to].rate_domain,
            .sample_rate = consumer_rate, // the resampler emits at the consumer's rate
            .set_param_slots = 0,
            .is_coercion = true,
            .bypassed = false,
        };
        g2.node_count += 1;

        // Rewire: producer → resampler (this edge), then resampler → consumer (new).
        g2.edges[ei].to_node = cid;
        g2.edges[ei].to_port = 0;
        g2.edges[g2.edge_count] = .{
            .from_node = cid,
            .from_port = 0,
            .to_node = orig_to,
            .to_port = orig_to_port,
            .feedback = false,
            .elem_size = e.elem_size,
            .elem_name = e.elem_name,
            .is_param = e.is_param,
            .channels = e.channels,
        };
        g2.edge_count += 1;
    }
    return g2;
}

/// The plugin-delay-compensation insertion step (runtime path) — the categorical
/// re-alignment of a latency-mismatched fan-in. A longest-path DP over the DAG
/// gives each node's output latency in a common (audio-sample) domain — every
/// branch's `algorithmic_latency` converted by its rate-domain scale `apa`
/// (per-rate-domain, audit S7: an FFT-latency spectral path and a time-domain path
/// align in the correct domain, not naively in samples). At each fan-in, on each
/// SHORTER sample input a compensating `DelayLine` of `(Lmax − Lᵢ)` (converted back
/// into that input's element units) is inserted, so the signals re-align
/// sample-accurately. A BYPASSED block with `algorithmic_latency > 0` gets a
/// comp-delay on its output too (bypass-preserves-latency) and is marked
/// `pdc_compensated`. The comp-delays are ordinary delay elements (counted by the
/// footprint's delay-ring term, tagged `is_pdc` so the runtime engine binds a delay
/// kernel). A graph with no latency-mismatched fan-in is returned unchanged.
/// Comptime-evaluable (fixed arrays, no allocator), so `commitGraph(insertPdc(g))`
/// runs at comptime exactly as `insertCoercions` does.
pub fn insertPdc(g: graph.Graph) graph.Graph {
    const ts = topoSort(g);
    if (!ts.ok) return g; // an undeclared cycle — computePlan reports it
    const NC = g.node_count;
    const apa = computeApa(g, ts.order[0..ts.len]);

    // Longest-path latency DP, in audio samples. A node's own latency is declared in
    // its OUTPUT elements, so its audio-domain contribution is `alg_lat · apa[node]`.
    var lat: [graph.max_nodes]usize = [_]usize{0} ** graph.max_nodes;
    for (ts.order[0..ts.len]) |v| {
        var lin: usize = 0;
        for (g.edges[0..g.edge_count]) |e| {
            if (e.to_node != v or e.is_param) continue;
            if (lat[e.from_node] > lin) lin = lat[e.from_node];
        }
        const a = apa[v];
        const contrib = g.nodes[v].algorithmic_latency * a.num / a.den;
        lat[v] = lin + contrib;
    }

    var g2 = g;

    // Fan-in comp-delays: on each shorter sample input of every node, insert a
    // DelayLine of the latency deficit (converted into that input's element units).
    const orig_edges = g.edge_count;
    var ei: usize = 0;
    while (ei < orig_edges) : (ei += 1) {
        const e = g.edges[ei];
        if (e.is_param) continue;
        const v = e.to_node;
        // Lmax over v's sample inputs (on the original graph).
        var lmax: usize = 0;
        for (g.edges[0..orig_edges]) |e2| {
            if (e2.to_node != v or e2.is_param) continue;
            if (lat[e2.from_node] > lmax) lmax = lat[e2.from_node];
        }
        const lsrc = lat[e.from_node];
        if (lsrc >= lmax) continue; // this input is the (a) longest — no delay
        const src_apa = apa[e.from_node];
        // (Lmax − Lsrc) audio samples ÷ apa[src] = comp length in src's elements.
        const comp_len = (lmax - lsrc) * src_apa.den / src_apa.num;
        if (comp_len == 0) continue;
        if (g2.node_count >= graph.max_nodes or g2.edge_count >= graph.max_edges) continue;
        insertDelayOnEdge(&g2, ei, comp_len);
    }

    // Bypass-preserves-latency: a bypassed latent block keeps its delay via a
    // comp-delay on each of its outputs, then is marked compensated.
    for (0..NC) |v| {
        if (!(g2.nodes[v].bypassed and g.nodes[v].algorithmic_latency > 0)) continue;
        const comp_len = g.nodes[v].algorithmic_latency; // already in v's output elems
        var oei: usize = 0;
        const snapshot = g2.edge_count;
        while (oei < snapshot) : (oei += 1) {
            if (g2.edges[oei].from_node != v or g2.edges[oei].is_param) continue;
            if (g2.node_count >= graph.max_nodes or g2.edge_count >= graph.max_edges) continue;
            insertDelayOnEdge(&g2, oei, comp_len);
        }
        g2.nodes[v].pdc_compensated = true;
    }
    return g2;
}

/// Splice a PDC compensating `DelayLine` of `len` elements onto forward edge `ei`
/// (`src → dst` becomes `src → delay → dst`). The delay carries the edge's element
/// type, is a delay element (so it is counted in the footprint's delay-ring term),
/// and is tagged `is_pdc` for the runtime engine's kernel binding.
fn insertDelayOnEdge(g2: *graph.Graph, ei: usize, len: usize) void {
    const e = g2.edges[ei];
    const cid = g2.node_count;
    const orig_to = e.to_node;
    const orig_to_port = e.to_port;
    g2.nodes[cid] = .{
        .id = cid,
        .class = .Map,
        .type_name = "(pdc-delay)",
        .out_elem_size = e.elem_size,
        .out_elem_name = e.elem_name,
        .is_source = false,
        .is_delay = true,
        .delay_len = len,
        .algorithmic_latency = 0, // a deliberate signal delay, not algorithmic latency
        .out_per_in_p = 1,
        .out_per_in_q = 1,
        .aliasing_safe = false,
        .state_size = @sizeOf(usize), // the ring cursor
        .rate_domain = g2.nodes[orig_to].rate_domain,
        .sample_rate = g2.nodes[e.from_node].sample_rate,
        .set_param_slots = 0,
        .is_coercion = false,
        .bypassed = false,
        .pdc_compensated = false,
        .is_pdc = true,
    };
    g2.node_count += 1;
    g2.edges[ei].to_node = cid;
    g2.edges[ei].to_port = 0;
    g2.edges[g2.edge_count] = .{
        .from_node = cid,
        .from_port = 0,
        .to_node = orig_to,
        .to_port = orig_to_port,
        .feedback = false,
        .elem_size = e.elem_size,
        .elem_name = e.elem_name,
        .is_param = e.is_param,
        .channels = e.channels,
    };
    g2.edge_count += 1;
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

test "PDC: insertPdc compensates a latency-mismatched diamond fan-in" {
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
        const a = gg.add(Map1); // dry, latency 0
        const b = gg.add(Map1); // wet
        const mix = gg.add(Sum2);
        const out = gg.add(Sink);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), a, 0);
        gg.connect(port.MapOutPort(Src), src, 0, port.MapInPort(Map1), b, 0);
        gg.connect(port.MapOutPort(Map1), a, 0, port.MapInPortAt(Sum2, 0), mix, 0);
        gg.connect(port.MapOutPort(Map1), b, 0, port.MapInPortAt(Sum2, 1), mix, 1);
        gg.connect(port.MapOutPort(Sum2), mix, 0, port.MapInPort(Sink), out, 0);
        gg.nodes[b].algorithmic_latency = 64; // wet branch carries 64 samples of latency
        break :blk gg;
    };
    const g2 = comptime insertPdc(g);
    // Exactly one compensating delay inserted (on the shorter dry branch).
    try std.testing.expectEqual(@as(usize, 6), g2.node_count);
    var comp_len: usize = 0;
    var comp_count: usize = 0;
    for (g2.nodes[0..g2.node_count]) |n| if (n.is_pdc) {
        comp_len = n.delay_len;
        comp_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), comp_count);
    try std.testing.expectEqual(@as(usize, 64), comp_len); // = the wet latency
    // The compensated graph commits cleanly; the comp-delay ring is footprinted.
    const plan = comptime try commitGraph(g2, .colored);
    try std.testing.expect(plan.footprint_bytes > 0);
}

test "PDC: a latency-equal diamond (same latency both branches) inserts no delay" {
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
        break :blk gg; // both branches latency 0
    };
    const g2 = comptime insertPdc(g);
    try std.testing.expectEqual(@as(usize, 5), g2.node_count); // unchanged
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

test "negotiate: a wired sample-rate mismatch AUTO-INSERTS a resampler coercion node" {
    const RateSrc = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []t.Sample(f32)) void {
            _ = self;
            _ = out;
        }
    };
    const RateSink = struct {
        const Self = @This();
        pub fn process(self: *Self, in: []const t.Sample(f32)) void {
            _ = self;
            _ = in;
        }
    };
    // Build source@44.1k → sink@48k (a wired sample-rate mismatch). graph.add reads
    // the graph's current sample_rate into each node, so set it per-add.
    var g = graph.Graph.empty;
    g.sample_rate = 44_100;
    const src = g.add(RateSrc);
    g.sample_rate = 48_000;
    const sink = g.add(RateSink);
    g.connect(port.MapOutPort(RateSrc), src, 0, port.MapInPort(RateSink), sink, 0);

    // The negotiation pass inserts a resampler so the diagram commutes: the op-list
    // grows from 2 nodes to 3 (src → resampler → sink), and the inserted node is a
    // coercion sitting at the consumer's rate.
    const g2 = insertCoercions(g);
    try std.testing.expectEqual(@as(usize, 3), g2.node_count);
    try std.testing.expect(g2.nodes[2].is_coercion);
    try std.testing.expectEqual(@as(u32, 48_000), g2.nodes[2].sample_rate);

    const plan = try commitRuntime(g, .colored);
    try std.testing.expectEqual(@as(usize, 3), plan.op_count); // resampler is now an op

    // A same-rate graph inserts NOTHING (the diagram already commutes).
    var g3 = graph.Graph.empty; // default 48k everywhere
    const a = g3.add(RateSrc);
    const b = g3.add(RateSink);
    g3.connect(port.MapOutPort(RateSrc), a, 0, port.MapInPort(RateSink), b, 0);
    try std.testing.expectEqual(@as(usize, 2), insertCoercions(g3).node_count);
}

test "bypass-preserves-latency: a bypassed latent block with no compensation is a commit error" {
    const BypSrc = struct {
        const Self = @This();
        pub fn process(self: *Self, out: []t.Sample(f32)) void {
            _ = self;
            _ = out;
        }
    };
    var g = graph.Graph.empty;
    const src = g.add(BypSrc);
    // Give the node algorithmic latency and bypass it. On the RAW graph (no PDC
    // pass), a bypassed latent block is uncompensated — committing it would silently
    // shift timing, so it is rejected loudly.
    g.nodes[src].algorithmic_latency = 5;
    g.markBypassed(src);
    try std.testing.expectError(error.BypassLatencyUncompensated, commitGraph(g, .colored));

    // commitRuntime runs insertPdc, which routes the bypass through a compensating
    // delay (bypass-preserves-latency) and marks the node compensated, so the same
    // graph now commits cleanly.
    _ = try commitRuntime(g, .colored);

    // A bypassed block with ZERO latency is fine either way (nothing to compensate).
    var g2 = graph.Graph.empty;
    const s2 = g2.add(BypSrc);
    g2.markBypassed(s2);
    _ = try commitGraph(g2, .colored);
}
