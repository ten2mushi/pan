//! OfflineBatch (Tier C) — the push / throughput execution mode.
//!
//! A pan graph and its blocks are execution-agnostic: the same `process`/`pull`
//! kernels that the realtime pull executor drives also run under this offline
//! push executor. OfflineBatch has **no deadline** — blocking, allocation, and
//! many threads are all legal (the realtime no-malloc/no-lock prohibition does
//! not apply here). Its objective is throughput, and its three governing
//! invariants are:
//!
//!   O1  No deadline; blocking is legal. Worker threads may spin, yield, and
//!       allocate — latency is irrelevant offline.
//!   O2  Bounded, pre-sized footprint. The ring depths and the per-chunk render
//!       pools are all allocated up front from the supplied allocator; nothing
//!       grows without bound.
//!   O3  Bit-reproducibility. The output is independent of thread count and
//!       scheduling: the ordered merge writes each chunk to its fixed timeline
//!       offset, and fan-in reductions read inputs in fixed port order, so the
//!       timeline partition is invisible. Bit-identical to the sequential render
//!       for pipeline parallelism and for exact-warmup chunking; allclose within
//!       a block's declared tolerance for IIR/feedback chunking.
//!
//! Two parallelism levers compose:
//!
//!   * **Pipeline parallelism** (`renderPipeline`): map the op-list to stages,
//!     one stage per thread, connected by bounded SPSC rings. Exact and
//!     bit-reproducible by construction — the same data flows through the same
//!     stages in the same order. Always available; scales with the number of
//!     stages.
//!   * **Data-parallel timeline chunking** (`renderChunked`): partition the
//!     render timeline `[0, T)` into K chunks rendered concurrently across all
//!     cores, then merge in timeline order. The hazard is stateful blocks (a
//!     chunk starting at sample `t` needs the boundary state the block would
//!     have had at `t`); the fix is a discarded **warm-up lead-in**: render
//!     chunk `[t, t+L)` by feeding `[t − warmup, t+L)` and discarding the first
//!     `warmup` outputs, reconstructing that state. A finite-memory block (FIR,
//!     STFT) reconstructs it exactly (bit-exact merge); an infinite-memory block
//!     (IIR, feedback) decays to within its declared tolerance (allclose merge).
//!     Scales with cores.
//!
//! The **`warmup_samples`** block contract gates chunkability. A block declares
//!
//!     pub const warmup_samples: usize;       // lead-in to reconstruct boundary state
//!     pub const warmup_exact: bool = true;    // true: bit-exact; false: tolerance-bounded
//!
//! A block that does NOT declare `warmup_samples` is **not chunkable**: asking to
//! chunk a graph containing one is a compile-time error (the presence of the
//! field is what authorises partitioning the timeline through that block). Pure
//! stateless maps declare `warmup_samples = 0`.
//!
//! Design note — this executor is built at the comptime-graph level, the same
//! level as the frozen single-core `Executor`: a chunk worker is an independent
//! `Executor` instance, so K workers are K independent block-state copies with K
//! independent pools. That is what makes the timeline partition realisable and
//! the `K=1 ≡ K=ncores` differential bit-exact-testable.

const std = @import("std");
const types = @import("types.zig");
const graph = @import("graph.zig");
const port = @import("port.zig");
const engine = @import("engine.zig");
const mux = @import("mux.zig");
const fusion = @import("fusion.zig");

const Sample = types.Sample;

// ===========================================================================
// Offline I/O endpoint blocks
//
// An offline render is a pure function `input[] -> output[]`. These two blocks
// are how the timeline enters and leaves the graph: `Source` injects a window of
// the input timeline at the graph root, `Sink` captures the rendered output. For
// chunking, each worker's `Source` is seeked to its chunk's window (including the
// warm-up lead-in) and its `Sink` is pointed at that chunk's scratch.
// ===========================================================================

/// `Source` — an offline windowed buffer source: a zero-sample-input Map whose
/// per-block output is read from a caller-set `window` of the input timeline.
/// Reading past the window yields silence (the warm-up/tail pad). Declares
/// `warmup_samples = 0` (a source carries no cross-sample state) so it never
/// blocks chunkability.
pub const Source = struct {
    /// The current chunk's input window (its own samples plus any warm-up
    /// lead-in). A non-owning view; the executor sets it via `seek`.
    window: []const f32 = &.{},
    /// Read position within `window`, in samples.
    cursor: usize = 0,

    /// Stateless w.r.t. the audio timeline ⇒ chunkable with a zero lead-in.
    pub const warmup_samples: usize = 0;
    pub const warmup_exact: bool = true;
    /// Marker so the executor can locate the unique injection point in a graph.
    pub const is_offline_source = true;

    const Self = @This();

    /// Point the source at a new input window and rewind. The executor calls this
    /// once per chunk (with the chunk's `[start, end)` slice) before rendering it.
    pub fn seek(self: *Self, window: []const f32) void {
        self.window = window;
        self.cursor = 0;
    }

    pub fn process(self: *Self, out: []Sample(f32)) void {
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            // Past the window end the source emits silence: that region is either
            // discarded warm-up overshoot or a final zero-pad, never real output.
            out[i].ch[0] = if (self.cursor < self.window.len) self.window[self.cursor] else 0;
            self.cursor += 1;
        }
    }
};

/// `Sink` — an offline capture sink: an output-only Map that writes each block of
/// input into a caller-set destination buffer, clamping at its end (a partial
/// final block writes only the remainder). Declares `warmup_samples = 0`.
pub const Sink = struct {
    /// The current chunk's capture destination. A non-owning view; the executor
    /// sets it via `attach`.
    dest: []f32 = &.{},
    /// Write position within `dest`, in samples.
    cursor: usize = 0,

    pub const warmup_samples: usize = 0;
    pub const warmup_exact: bool = true;
    pub const is_offline_sink = true;

    const Self = @This();

    /// Point the sink at a new capture buffer and rewind.
    pub fn attach(self: *Self, dest: []f32) void {
        self.dest = dest;
        self.cursor = 0;
    }

    pub fn process(self: *Self, in: []const Sample(f32)) void {
        var i: usize = 0;
        while (i < in.len and self.cursor < self.dest.len) : (i += 1) {
            self.dest[self.cursor] = in[i].ch[0];
            self.cursor += 1;
        }
    }
};

// ===========================================================================
// The `warmup_samples` contract — comptime reflection
// ===========================================================================

/// The block's declared warm-up lead-in, or `null` if it declares none (⇒ not
/// chunkable, the presence-gates-chunkability law).
fn warmupOf(comptime Block: type) ?usize {
    if (@hasDecl(Block, "warmup_samples")) return Block.warmup_samples;
    return null;
}

/// Whether the block's warm-up reconstructs its boundary state exactly (FIR/STFT,
/// ⇒ bit-exact merge) or only to within a tolerance (IIR/feedback, ⇒ allclose
/// merge). Defaults to exact when unspecified, matching the field default.
fn exactOf(comptime Block: type) bool {
    if (@hasDecl(Block, "warmup_exact")) return Block.warmup_exact;
    return true;
}

// ===========================================================================
// OfflineBatch — the Tier C executor over a comptime graph
// ===========================================================================

/// The offline batch executor for a committed comptime graph `g` with one block
/// type per node (`node_blocks`, the `Executor` contract). The graph must contain
/// exactly one `offline.Source` and one `offline.Sink`; everything between them is
/// the processing chain. Mirrors `engine.Executor`: a chunk worker IS an
/// `Executor` instance, so the parallel paths reuse the proven single-core render.
pub fn OfflineBatch(comptime g: graph.Graph, comptime node_blocks: []const type) type {
    if (node_blocks.len != g.node_count)
        @compileError("pan: OfflineBatch needs exactly one block type per graph node");

    // Locate the unique injection (Source) and capture (Sink) endpoints.
    const endpoints = comptime locateEndpoints(node_blocks);

    // The single-core executor a chunk worker is an instance of.
    const Exec = engine.Executor(g, node_blocks);

    // Chunkability + warm-up, decided entirely at commit. `chunkable` holds iff
    // every node declares `warmup_samples` (W1: presence gates chunkability).
    // `total_warmup` is the lead-in the timeline source must provide so every
    // block downstream reconstructs its boundary state — the sum of the per-block
    // warm-ups, a conservative bound that equals the longest source→sink warm-up
    // path for the linear and parallel-mix shapes that batch here (more lead-in is
    // always still exact, never less). `all_exact` is true iff every block's
    // warm-up is exact, which is the condition for a bit-exact chunked merge.
    const meta = comptime computeChunkMeta(node_blocks);

    const N = g.block_size;

    return struct {
        const Self = @This();

        /// The committed plan, exposed for footprint/op-count reporting.
        pub const committed = Exec.committed;
        /// The instance tuple a caller seeds: one configured block per node.
        pub const InstanceTuple = @TypeOf(@as(Exec, undefined).instances);
        /// The graph's block size (samples per render call), and the source/sink
        /// node ids — exposed for tests and tooling.
        pub const block_size = N;
        pub const source_id = endpoints.source;
        pub const sink_id = endpoints.sink;
        /// Whether this graph may be data-parallel chunked (every block declares
        /// `warmup_samples`), and whether such a chunked render is bit-exact.
        pub const chunkable = meta.chunkable;
        pub const warmup_exact = meta.all_exact;
        /// The timeline lead-in (samples) a chunk's source provides before its
        /// first real output, reconstructing every downstream block's state.
        pub const total_warmup = meta.total_warmup;

        // -------------------------------------------------------------------
        // Sequential (K = 1) — the offline ground truth
        // -------------------------------------------------------------------

        /// Render the whole timeline with a single worker: the offline analogue of
        /// the Tier A sequential render, and the reference every parallel path must
        /// reproduce. `template` is the configured block tuple (its `Source`/`Sink`
        /// are overridden here); `input`/`output` are the f32 timeline, equal
        /// length. No threads, no allocation.
        pub fn renderSequential(template: InstanceTuple, input: []const f32, output: []f32) void {
            std.debug.assert(input.len == output.len);
            var exec: Exec = .{ .instances = template };
            driveWindow(&exec, input, output);
        }

        // -------------------------------------------------------------------
        // File-level parallelism (renderBatch) — embarrassingly parallel
        // -------------------------------------------------------------------

        /// One independent offline render: an input timeline and the
        /// equal-length destination it renders into. A batch is a list of these.
        pub const Job = struct { input: []const f32, output: []f32 };

        /// Render a list of fully independent jobs across up to `cores` worker
        /// threads. Each job is a complete, isolated `renderSequential` over its
        /// own freshly-seeded `Exec` instance (its own block state + pool), so
        /// jobs share nothing: there is no warm-up, boundary, or shape concern,
        /// and each job's output is **bit-identical** to running that one job
        /// through `renderSequential` alone — parallelism here changes only
        /// scheduling, never the per-job arithmetic. Workers pop job indices off
        /// a shared atomic counter (`fetchAdd`), so the work self-balances and a
        /// slow job does not stall the others. Offline (O1): a worker may block,
        /// spin, and allocate freely.
        ///
        /// Degenerate cases run inline with no threads: an empty job list is a
        /// no-op, and `cores <= 1` is a plain serial loop. A thread-spawn failure
        /// is propagated (the partial set already spawned is joined first so no
        /// worker is leaked).
        pub fn renderBatch(
            alloc: std.mem.Allocator,
            template: InstanceTuple,
            jobs: []const Job,
            cores: usize,
        ) !void {
            if (jobs.len == 0) return;

            // Serial fast path: one core (or fewer) ⇒ no threads at all.
            if (cores <= 1) {
                for (jobs) |job| renderSequential(template, job.input, job.output);
                return;
            }

            const n_threads = @min(cores, jobs.len);

            const Shared = struct {
                next: std.atomic.Value(usize) = .init(0),
                jobs: []const Job,
                template: InstanceTuple,

                fn work(s: *@This()) void {
                    while (true) {
                        // Claim the next unrendered job. Monotonic counter: once
                        // it reaches jobs.len every worker drains and returns.
                        const idx = s.next.fetchAdd(1, .monotonic);
                        if (idx >= s.jobs.len) return;
                        const job = s.jobs[idx];
                        // Each job gets its own fresh Exec instance via
                        // renderSequential — isolated state, bit-identical to a
                        // solo serial render of this job.
                        renderSequential(s.template, job.input, job.output);
                    }
                }
            };
            var shared = Shared{ .jobs = jobs, .template = template };

            const threads = try alloc.alloc(std.Thread, n_threads);
            defer alloc.free(threads);

            // Spawn the worker pool. On a spawn failure, join the workers already
            // started (so none leak) before propagating the error.
            var spawned: usize = 0;
            errdefer {
                for (threads[0..spawned]) |t| t.join();
            }
            while (spawned < n_threads) : (spawned += 1) {
                threads[spawned] = try std.Thread.spawn(.{}, Shared.work, .{&shared});
            }
            for (threads[0..spawned]) |t| t.join();
        }

        // -------------------------------------------------------------------
        // Automatic lever selection — the chunker's routing
        // -------------------------------------------------------------------

        /// Render the timeline, picking the parallelism lever automatically:
        /// data-parallel chunking across all cores when the graph is **chunkable**
        /// (every block declares `warmup_samples`), else **pipeline** parallelism
        /// for a linear chain, else the **sequential** ground truth. This is the
        /// W1 routing: a graph the chunker cannot partition — a block that declares
        /// no `warmup_samples` (a stateful block, or a controller-driven `VariRate`
        /// whose trajectory is not reproducible) — is forced onto the always-
        /// available pipeline/sequential path rather than chunked. The comptime
        /// condition prunes the unanalysed branch, so `renderChunked`'s
        /// not-chunkable `@compileError` is never reached when this is taken.
        pub fn render(alloc: std.mem.Allocator, template: InstanceTuple, input: []const f32, output: []f32) !void {
            if (comptime chunkable) {
                const k = std.Thread.getCpuCount() catch 1;
                return renderChunked(alloc, template, input, output, k);
            } else if (comptime (isLinearChain(g) and source_id == 0 and sink_id == node_blocks.len - 1)) {
                return renderPipeline(alloc, template, input, output);
            } else {
                renderSequential(template, input, output);
            }
        }

        // -------------------------------------------------------------------
        // Offline footprint (O2) — bounded, pre-sized, commit-known
        // -------------------------------------------------------------------

        /// The bounded offline footprint (bytes) for a `k_chunks`-way chunked
        /// render of a `total_samples`-long timeline: the `K` per-chunk render
        /// pools (each an `Exec` — colored pool + block instances) plus the `K`
        /// per-chunk capture scratches. A chunk spans at most `⌈T/K⌉ + total_warmup`
        /// samples (its slice plus the discarded warm-up lead-in), so the scratch
        /// total is bounded by `T + K·total_warmup` f32s. Every term is known once
        /// `K`, `T`, and the graph are fixed — pre-sized, no unbounded growth (O2).
        pub fn chunkFootprintBytes(k_chunks: usize, total_samples: usize) usize {
            const pools = k_chunks * @sizeOf(Exec);
            const scratch_f32 = total_samples + k_chunks * total_warmup;
            return pools + scratch_f32 * @sizeOf(f32);
        }

        /// The bounded pipeline footprint (bytes): the `S−1` inter-stage rings, each
        /// `ring_depth` slots of one block. Latency (`Σ ring_depth`) is irrelevant
        /// offline; the depth bounds the buffering.
        pub fn pipelineFootprintBytes() usize {
            const ring_depth = 4;
            const slot_bytes = N * @sizeOf(Sample(f32));
            const n_rings = if (node_blocks.len == 0) 0 else node_blocks.len - 1;
            return n_rings * ring_depth * slot_bytes;
        }

        // -------------------------------------------------------------------
        // Data-parallel timeline chunking (K = ncores) — scales with cores
        // -------------------------------------------------------------------

        /// Partition `[0, T)` into `k_req` chunks, render them concurrently (one
        /// thread per chunk), and merge in timeline order. Each chunk after the
        /// first is rendered with a `total_warmup` lead-in that is discarded,
        /// reconstructing its boundary state. Bit-identical to `renderSequential`
        /// when `warmup_exact` (FIR/STFT); allclose within tolerance otherwise
        /// (IIR/feedback). Chunking a graph that contains a block without a
        /// `warmup_samples` declaration is a compile-time error (W1 / A18).
        pub fn renderChunked(
            alloc: std.mem.Allocator,
            template: InstanceTuple,
            input: []const f32,
            output: []f32,
            k_req: usize,
        ) !void {
            if (comptime !chunkable)
                @compileError("pan: this graph is not data-parallel chunkable — a block on it " ++
                    "declares no `warmup_samples` (presence gates chunkability; declare it, " ++
                    "0 for a stateless block). Render it through renderPipeline instead.");
            std.debug.assert(input.len == output.len);
            const T = input.len;
            if (T == 0) return;

            const K = std.math.clamp(k_req, 1, T);

            // O2: pre-size everything up front. K render pools (the workers) and K
            // per-chunk capture scratches (each sized to its chunk + lead-in).
            const workers = try alloc.alloc(Exec, K);
            defer alloc.free(workers);
            const ctxs = try alloc.alloc(ChunkCtx, K);
            defer alloc.free(ctxs);

            // ONE cleanup for the per-chunk scratches: `allocated` is read at scope
            // exit, so this frees exactly the scratches actually built — covering a
            // mid-loop construction failure AND a later failure (or success) alike,
            // each scratch freed exactly once. (A separate `errdefer` for the partial
            // build would double with this `defer` on any post-loop error.) Runs
            // before the array `free` above by LIFO, so reading `ctxs[i].scratch` is
            // still valid.
            var allocated: usize = 0;
            defer for (ctxs[0..allocated]) |c| alloc.free(c.scratch);

            // Lay out the chunk boundaries and per-chunk windows/scratches.
            var i: usize = 0;
            while (i < K) : (i += 1) {
                const begin = (T * i) / K;
                const end = (T * (i + 1)) / K;
                const start = if (begin > total_warmup) begin - total_warmup else 0;
                const lead = begin - start; // discarded warm-up outputs
                const wlen = end - start; // window + real-output length
                const scratch = try alloc.alloc(f32, wlen);
                ctxs[i] = .{
                    .worker = &workers[i],
                    .template = template,
                    .window = input[start..end],
                    .scratch = scratch,
                    .lead = lead,
                    .out = output[begin..end],
                };
                allocated += 1;
            }

            // Spawn K−1 threads; the caller's thread renders chunk 0. Offline: a
            // worker may block/spin/allocate freely (O1). If a spawn fails we fall
            // back to rendering the rest inline — correctness over parallelism.
            const threads = try alloc.alloc(?std.Thread, K);
            defer alloc.free(threads);
            for (threads) |*t| t.* = null;
            i = 1;
            while (i < K) : (i += 1) {
                threads[i] = std.Thread.spawn(.{}, renderChunkCtx, .{&ctxs[i]}) catch null;
            }
            renderChunkCtx(&ctxs[0]);
            i = 1;
            while (i < K) : (i += 1) {
                if (threads[i]) |t| t.join() else renderChunkCtx(&ctxs[i]);
            }

            // O3 ordered merge: copy each chunk's real output (past its discarded
            // lead-in) to its fixed timeline offset, in timeline order. Independent
            // of completion order ⇒ the partition is invisible.
            for (ctxs) |c| {
                @memcpy(c.out, c.scratch[c.lead .. c.lead + c.out.len]);
            }
        }

        const ChunkCtx = struct {
            worker: *Exec,
            template: InstanceTuple,
            window: []const f32,
            scratch: []f32,
            lead: usize,
            out: []f32,
        };

        fn renderChunkCtx(c: *ChunkCtx) void {
            c.worker.* = .{ .instances = c.template };
            driveWindow(c.worker, c.window, c.scratch);
        }

        // -------------------------------------------------------------------
        // Pipeline parallelism — stage-per-thread + bounded SPSC rings
        // -------------------------------------------------------------------

        /// Render the timeline by running each op of a linear `Map` chain on its
        /// own thread, connected by bounded SPSC rings (`mux.Ring`); the middle
        /// stages are driven through `RingSampleMux`, the offline push transport.
        /// Exact and bit-reproducible by construction — the same data flows through
        /// the same stages in the same order, so the output equals
        /// `renderSequential` to the bit. Throughput is `1 / max_stage_time` (the
        /// bottleneck stage). Requires a linear chain (one input, one output per
        /// interior op); a non-linear graph returns `error.NotLinearChain`.
        pub fn renderPipeline(
            alloc: std.mem.Allocator,
            template: InstanceTuple,
            input: []const f32,
            output: []f32,
        ) !void {
            // A linear chain whose endpoints are the source (node 0) and sink
            // (node S−1) is the shape pipeline parallelism serves; anything else
            // (fan-in/out, a non-terminal endpoint) routes elsewhere.
            const S = node_blocks.len;
            if (comptime (!isLinearChain(g) or source_id != 0 or sink_id != S - 1))
                return error.NotLinearChain;
            std.debug.assert(input.len == output.len);
            const T = input.len;
            if (T == 0) return;

            // One configured instance set, shared across stage threads — each op
            // runs on exactly one thread, so its state is touched by one thread.
            var instances: InstanceTuple = template;
            instances[source_id].seek(input); // the source reads the whole timeline
            instances[sink_id].attach(output); // the sink writes the whole timeline

            // S−1 rings connect adjacent stages. Depth 4 slots of one block each is
            // ample to keep every stage busy without unbounded buffering (O2).
            const ring_depth = 4;
            const slot_bytes = N * @sizeOf(Sample(f32));
            const rings = try alloc.alloc(mux.Ring, S - 1);
            defer alloc.free(rings);
            // ONE cleanup for the constructed rings: `made` is read at scope exit, so
            // this deinits exactly the rings actually built — a mid-loop init failure
            // AND a later failure (or success) alike, each ring deinit'd once. (A
            // separate `errdefer` for the partial build would double with this `defer`
            // on any post-loop error, deinit'ing a ring twice.)
            var made: usize = 0;
            defer for (rings[0..made]) |*r| r.deinit(alloc);
            for (rings) |*r| {
                r.* = try mux.Ring.init(alloc, slot_bytes, ring_depth);
                made += 1;
            }

            const nb = (T + N - 1) / N; // whole blocks to cover the timeline

            const threads = try alloc.alloc(?std.Thread, S);
            defer alloc.free(threads);
            for (threads) |*t| t.* = null;
            var stage_ctx = try alloc.alloc(StageCtx, S);
            defer alloc.free(stage_ctx);

            inline for (0..S) |sid| {
                stage_ctx[sid] = .{
                    .inst = &instances[sid],
                    .in_ring = if (sid == 0) null else &rings[sid - 1],
                    .out_ring = if (sid == S - 1) null else &rings[sid],
                    .nb = nb,
                };
                threads[sid] = std.Thread.spawn(.{}, StageWorker(node_blocks[sid], sid, S).run, .{&stage_ctx[sid]}) catch null;
            }
            // Any stage whose spawn failed runs inline after the others are up.
            inline for (0..S) |sid| {
                if (threads[sid] == null) StageWorker(node_blocks[sid], sid, S).run(&stage_ctx[sid]);
            }
            for (threads) |t| if (t) |th| th.join();
        }

        const StageCtx = struct {
            inst: *anyopaque,
            in_ring: ?*mux.Ring,
            out_ring: ?*mux.Ring,
            nb: usize,
        };

        /// The per-stage worker for node `sid` of an `S`-stage chain. Stage 0 is
        /// the source (it reads from its pre-seeked window and feeds ring 0); stage
        /// `S−1` is the sink (it drains the last ring into its pre-attached output,
        /// clamping the final partial block); every interior stage is a 1-in/1-out
        /// Map carrying one `Ring` slot per call. The source zero-pads past the
        /// timeline and the sink clamps at its end, so a non-block-multiple length
        /// needs no special case. A type-returning helper so `.run` is a concrete
        /// function `std.Thread.spawn` can take.
        fn StageWorker(comptime Block: type, comptime sid: usize, comptime S: usize) type {
            return struct {
                pub fn run(c: *StageCtx) void {
                    const inst: *Block = @ptrCast(@alignCast(c.inst));
                    const tok = engine.enterRealtimeThread();
                    defer tok.leave();
                    if (sid == 0) {
                        const out_ring = c.out_ring.?;
                        var b: usize = 0;
                        while (b < c.nb) : (b += 1) {
                            const slot = out_ring.produceSlot();
                            inst.process(bytesAsSamples(slot));
                            out_ring.commitProduce();
                        }
                        out_ring.setEos();
                    } else if (sid == S - 1) {
                        const in_ring = c.in_ring.?;
                        while (in_ring.consumeSlot()) |slot| {
                            inst.process(bytesAsConstSamples(slot));
                            in_ring.commitConsume();
                        }
                    } else {
                        // Interior Map stage driven through the RingSampleMux push
                        // transport (the SampleMux seam over the in/out rings).
                        var m = mux.RingSampleMux{ .in_ring = c.in_ring, .out_ring = c.out_ring };
                        const sm = m.sampleMux();
                        const slot_bytes = N * @sizeOf(Sample(f32));
                        while (true) {
                            sm.waitInputAvailable(0, slot_bytes);
                            if (sm.getInputAvailable(0) == 0) {
                                sm.setEOS(); // input ended & drained ⇒ end our output
                                break;
                            }
                            sm.waitOutputAvailable(0, slot_bytes);
                            const in_s = bytesAsConstSamples(sm.getInputBuffer(0)[0..slot_bytes]);
                            const out_s = bytesAsSamples(sm.getOutputBuffer(0)[0..slot_bytes]);
                            inst.process(in_s, out_s);
                            sm.updateInputBuffer(0, slot_bytes);
                            sm.updateOutputBuffer(0, slot_bytes);
                        }
                    }
                }
            };
        }

        // -------------------------------------------------------------------
        // Shared driver — render one Exec over a window into a destination
        // -------------------------------------------------------------------

        /// Seed `exec`'s source with `window` and its sink with `dest`, then render
        /// `ceil(dest.len / N)` blocks under a per-thread realtime token (FTZ is
        /// per-thread on ARM64, so every offline worker enters it). The source
        /// zero-pads past the window and the sink clamps at `dest.len`, so an
        /// arbitrary-length timeline renders correctly with no scalar-tail special
        /// case.
        fn driveWindow(exec: *Exec, window: []const f32, dest: []f32) void {
            exec.instances[source_id].seek(window);
            exec.instances[sink_id].attach(dest);
            const tok = engine.enterRealtimeThread();
            defer tok.leave();
            var done: usize = 0;
            while (done < dest.len) : (done += N) {
                exec.render(tok);
            }
        }
    };
}

// ===========================================================================
// OfflineBatchFused — OfflineBatch with automatic loop-fusion applied
//
// The offline analogue of `engine.FusedExecutor`: it runs the SAME `OfflineBatch`
// machinery, but on the FUSED graph produced by `fusion.fuse`. Fusing adjacent
// rate-1:1, type-stable, single-consumer, param-free `Map`s into one block-size-1
// `Subgraph` pass is denotationally identity — `(g ∘ f)(x) = g(f(x))` sample for
// sample — so the fused render is BIT-EXACT to the unfused render, while the
// intermediate value never round-trips memory (the byte-displacement win).
//
// The trick that keeps this from threading a `fuse` flag through every internal
// seeding site and footprint formula: we delegate wholesale to
// `OfflineBatch(f.graph, f.blocks)` — the same generic type on the fused graph —
// so chunk / pipeline / sequential routing, the footprint formulas, `chunkable`,
// and `isLinearChain` all compute UNCHANGED on the fused graph. The only new code
// is `scatterTemplate`, which turns the author's per-ORIGINAL-node template into
// the per-FUSED-node template the inner `OfflineBatch` expects (mirroring the
// `FusedExecutor.init` scatter): a `.passthrough` node copies straight across; a
// `.fused` node default-constructs the `Subgraph` and seeds its inner instances.
// ===========================================================================

/// `OfflineBatch` with automatic comptime loop-fusion applied. Drop-in for the
/// plain `OfflineBatch` at the call site, except the public render entries take
/// the author's per-ORIGINAL-node `template` (the same tuple the unfused
/// `OfflineBatch` takes) and scatter it onto the fused graph internally. The
/// fused render is bit-exact to the unfused render; chunked/pipeline routing runs
/// on the fused graph (a graph that fused any chain is no longer `chunkable`,
/// since a `Subgraph` node declares no `warmup_samples` — sequential is then the
/// baseline and the routing falls back to pipeline/sequential automatically).
pub fn OfflineBatchFused(comptime g: graph.Graph, comptime node_blocks: []const type) type {
    if (node_blocks.len != g.node_count)
        @compileError("pan: OfflineBatchFused needs exactly one block type per graph node");

    const f = comptime fusion.fuse(g, node_blocks);
    // The real worker: the plain OfflineBatch over the FUSED graph and its fused
    // block tuple. Every render lever, footprint formula, and routing predicate is
    // its own, computed on the fused graph — we add nothing, only translate the
    // template before each call.
    const Fused = OfflineBatch(f.graph, f.blocks);

    return struct {
        const Self = @This();

        /// The author's per-ORIGINAL-node instance tuple (what the unfused
        /// `OfflineBatch` also takes), so this type is a drop-in: a caller seeds
        /// exactly as if no fusion happened.
        pub const InstanceTuple = std.meta.Tuple(node_blocks);

        /// The committed plan of the FUSED graph (op-list, footprint, buffer
        /// layout). Its `op_count` is ≤ the unfused plan's whenever any chain
        /// fused (each fused chain collapses to one top-level op) — the proof that
        /// fusion actually fired.
        pub const committed = Fused.committed;
        /// The fused graph's block size, source/sink node ids (in the fused graph),
        /// chunkability, and warm-up — exposed for tests and tooling.
        pub const block_size = Fused.block_size;
        pub const source_id = Fused.source_id;
        pub const sink_id = Fused.sink_id;
        pub const chunkable = Fused.chunkable;
        pub const warmup_exact = Fused.warmup_exact;
        pub const total_warmup = Fused.total_warmup;
        /// The fusion routing table, exposed for tests/tooling.
        pub const route = f.route;

        /// Translate the author's per-ORIGINAL-node template into the per-FUSED-node
        /// template the inner `OfflineBatch` consumes. For a `.passthrough` node the
        /// original instance is copied straight into its new top-level slot; for a
        /// `.fused` node the slot holds a default-constructed `Subgraph` whose inner
        /// executor's body instances are seeded from the originals (the `Inlet`/
        /// `Outlet` inner endpoints keep their defaults). Mirrors the scatter in
        /// `engine.FusedExecutor.init`.
        fn scatterTemplate(unfused: InstanceTuple) Fused.InstanceTuple {
            var out: Fused.InstanceTuple = undefined;
            // Default-construct every fused slot first, so each fused node's nested
            // Subgraph inner executor (its sub-instances + default Inlet/Outlet) is
            // initialized before we selectively overwrite the seeded body fields.
            inline for (f.blocks, 0..) |Block, j| out[j] = Block{};
            inline for (node_blocks, 0..) |_, i| {
                switch (comptime f.route[i]) {
                    .passthrough => |nid| out[nid] = unfused[i],
                    .fused => |fp| out[fp.node].inner.instances[fp.inner] = unfused[i],
                }
            }
            return out;
        }

        /// Render the whole timeline with a single worker, on the fused graph.
        /// Bit-exact to the unfused `OfflineBatch.renderSequential`.
        pub fn renderSequential(template: InstanceTuple, input: []const f32, output: []f32) void {
            Fused.renderSequential(scatterTemplate(template), input, output);
        }

        pub const Job = Fused.Job;

        /// File-level parallelism over the fused graph (each job an isolated render).
        pub fn renderBatch(
            alloc: std.mem.Allocator,
            template: InstanceTuple,
            jobs: []const Job,
            cores: usize,
        ) !void {
            return Fused.renderBatch(alloc, scatterTemplate(template), jobs, cores);
        }

        /// Auto-route the render on the fused graph: chunking when the fused graph is
        /// chunkable (rare — a `Subgraph` fused node declares no `warmup_samples`),
        /// else pipeline for a linear fused chain, else sequential.
        pub fn render(alloc: std.mem.Allocator, template: InstanceTuple, input: []const f32, output: []f32) !void {
            return Fused.render(alloc, scatterTemplate(template), input, output);
        }

        /// Data-parallel timeline chunking over the fused graph. Only callable when
        /// the fused graph is `chunkable`; a fused graph containing a `Subgraph` node
        /// is not, so the inner `@compileError` fires exactly as for the unfused case.
        pub fn renderChunked(
            alloc: std.mem.Allocator,
            template: InstanceTuple,
            input: []const f32,
            output: []f32,
            k_req: usize,
        ) !void {
            return Fused.renderChunked(alloc, scatterTemplate(template), input, output, k_req);
        }

        /// Pipeline parallelism over the fused graph. Runs each fused top-level op on
        /// its own thread; `error.NotLinearChain` if the fused graph is not linear.
        pub fn renderPipeline(
            alloc: std.mem.Allocator,
            template: InstanceTuple,
            input: []const f32,
            output: []f32,
        ) !void {
            return Fused.renderPipeline(alloc, scatterTemplate(template), input, output);
        }

        /// The bounded chunk footprint of the fused graph (O2).
        pub fn chunkFootprintBytes(k_chunks: usize, total_samples: usize) usize {
            return Fused.chunkFootprintBytes(k_chunks, total_samples);
        }

        /// The bounded pipeline footprint of the fused graph (O2).
        pub fn pipelineFootprintBytes() usize {
            return Fused.pipelineFootprintBytes();
        }
    };
}

// ===========================================================================
// Comptime helpers
// ===========================================================================

const Endpoints = struct { source: usize, sink: usize };

/// Find the unique `is_offline_source` and `is_offline_sink` nodes; a missing or
/// duplicated endpoint is a contract violation reported at commit.
fn locateEndpoints(comptime node_blocks: []const type) Endpoints {
    var src: ?usize = null;
    var snk: ?usize = null;
    for (node_blocks, 0..) |Block, i| {
        if (@hasDecl(Block, "is_offline_source")) {
            if (src != null) @compileError("pan: OfflineBatch graph has more than one offline.Source");
            src = i;
        }
        if (@hasDecl(Block, "is_offline_sink")) {
            if (snk != null) @compileError("pan: OfflineBatch graph has more than one offline.Sink");
            snk = i;
        }
    }
    if (src == null) @compileError("pan: OfflineBatch graph has no offline.Source (the timeline injection point)");
    if (snk == null) @compileError("pan: OfflineBatch graph has no offline.Sink (the timeline capture point)");
    return .{ .source = src.?, .sink = snk.? };
}

const ChunkMeta = struct { chunkable: bool, total_warmup: usize, all_exact: bool };

/// Decide chunkability and the timeline warm-up from the per-block declarations.
fn computeChunkMeta(comptime node_blocks: []const type) ChunkMeta {
    var chunkable = true;
    var total: usize = 0;
    var all_exact = true;
    for (node_blocks) |Block| {
        if (warmupOf(Block)) |w| {
            total += w;
            if (!exactOf(Block)) all_exact = false;
        } else {
            chunkable = false;
        }
    }
    return .{ .chunkable = chunkable, .total_warmup = if (chunkable) total else 0, .all_exact = all_exact };
}

/// A graph is a linear chain (for pipeline parallelism) iff each node feeds
/// exactly the next in node-id order and there is no fan-in/out — the canonical
/// `Source → Map → … → Sink` shape that batches through pipeline parallelism.
fn isLinearChain(comptime g: graph.Graph) bool {
    if (g.node_count < 2) return false;
    // Exactly one edge between consecutive node ids, none skipping or branching.
    var edge_count: usize = 0;
    for (g.edges[0..g.edge_count]) |e| {
        if (e.to_node != e.from_node + 1) return false;
        edge_count += 1;
    }
    return edge_count == g.node_count - 1;
}

// ===========================================================================
// Byte/sample views (the pipeline ring carries raw bytes)
// ===========================================================================

fn bytesAsSamples(bytes: []u8) []Sample(f32) {
    return @alignCast(std.mem.bytesAsSlice(Sample(f32), bytes));
}
fn bytesAsConstSamples(bytes: []const u8) []const Sample(f32) {
    return @alignCast(std.mem.bytesAsSlice(Sample(f32), bytes));
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// A short FIR (moving-average) — finite memory, so its warm-up is exact: feeding
/// `taps − 1` prior input samples reconstructs the exact filter state.
fn Fir(comptime taps: usize) type {
    return struct {
        hist: [taps]f32 = @splat(0),
        const Self = @This();
        pub const warmup_samples: usize = taps - 1;
        pub const warmup_exact: bool = true;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            for (in, out) |x, *y| {
                // shift history, push x, average
                var k: usize = taps - 1;
                while (k > 0) : (k -= 1) self.hist[k] = self.hist[k - 1];
                self.hist[0] = x.ch[0];
                var acc: f32 = 0;
                for (self.hist) |h| acc += h;
                y.ch[0] = acc / @as(f32, @floatFromInt(taps));
            }
        }
    };
}

/// A one-pole IIR — infinite memory, so its warm-up is tolerance-bounded: the
/// boundary state has only decayed by `warmup_samples`, not reconstructed exactly.
const Iir = struct {
    y1: f32 = 0,
    a: f32 = 0.9,
    const Self = @This();
    pub const warmup_samples: usize = 256; // decay-to-tolerance length
    pub const warmup_exact: bool = false;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| {
            self.y1 = (1 - self.a) * x.ch[0] + self.a * self.y1;
            y.ch[0] = self.y1;
        }
    }
};

fn firGraph(comptime taps: usize) graph.Graph {
    var g = graph.Graph.empty;
    g.block_size = 64;
    const s = g.add(Source);
    const f = g.add(Fir(taps));
    const k = g.add(Sink);
    g.connect(port.MapOutPort(Source), s, 0, port.MapInPort(Fir(taps)), f, 0);
    g.connect(port.MapOutPort(Fir(taps)), f, 0, port.MapInPort(Sink), k, 0);
    return g;
}

fn fillNoise(buf: []f32, seed: u64) void {
    var s = seed;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = @as(f32, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(s >> 16)))))) / 2.147483648e9;
    }
}

test "offline Source/Sink round-trip the timeline (identity chain)" {
    const Id = struct {
        const Self = @This();
        pub const warmup_samples: usize = 0;
        pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
            _ = self;
            for (in, out) |x, *y| y.* = x;
        }
    };
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 64;
        const s = gg.add(Source);
        const m = gg.add(Id);
        const k = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), s, 0, port.MapInPort(Id), m, 0);
        gg.connect(port.MapOutPort(Id), m, 0, port.MapInPort(Sink), k, 0);
        break :blk gg;
    };
    const OB = OfflineBatch(g, &.{ Source, Id, Sink });
    const T = 500;
    var input: [T]f32 = undefined;
    var output: [T]f32 = undefined;
    fillNoise(&input, 7);
    OB.renderSequential(.{ Source{}, Id{}, Sink{} }, &input, &output);
    try testing.expectEqualSlices(f32, &input, &output);
}

test "FIR chunked render is bit-identical to sequential (exact warm-up, O3)" {
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    try testing.expect(OB.chunkable);
    try testing.expect(OB.warmup_exact);
    try testing.expectEqual(@as(usize, taps - 1), OB.total_warmup);

    const T = 1000;
    var input: [T]f32 = undefined;
    fillNoise(&input, 11);
    var seq: [T]f32 = undefined;
    var par: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderChunked(testing.allocator, tmpl, &input, &par, 4);
    try testing.expectEqualSlices(f32, &seq, &par); // bit-exact
}

test "IIR chunked render is allclose to sequential (tolerance-bounded warm-up)" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 64;
        const s = gg.add(Source);
        const f = gg.add(Iir);
        const k = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), s, 0, port.MapInPort(Iir), f, 0);
        gg.connect(port.MapOutPort(Iir), f, 0, port.MapInPort(Sink), k, 0);
        break :blk gg;
    };
    const OB = OfflineBatch(g, &.{ Source, Iir, Sink });
    try testing.expect(OB.chunkable);
    try testing.expect(!OB.warmup_exact);

    const T = 2000;
    var input: [T]f32 = undefined;
    fillNoise(&input, 13);
    var seq: [T]f32 = undefined;
    var par: [T]f32 = undefined;
    const tmpl = .{ Source{}, Iir{}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderChunked(testing.allocator, tmpl, &input, &par, 4);
    for (seq, par) |a, b| try testing.expect(@abs(a - b) <= 1e-4);
}

test "K=1 chunked equals K=ncores chunked, bit-for-bit (FIR)" {
    const taps = 5;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 777;
    var input: [T]f32 = undefined;
    fillNoise(&input, 17);
    var k1: [T]f32 = undefined;
    var kn: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    try OB.renderChunked(testing.allocator, tmpl, &input, &k1, 1);
    try OB.renderChunked(testing.allocator, tmpl, &input, &kn, 8);
    try testing.expectEqualSlices(f32, &k1, &kn);
}

test "pipeline render equals sequential, bit-for-bit (linear Map chain)" {
    const taps = 4;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 640;
    var input: [T]f32 = undefined;
    fillNoise(&input, 19);
    var seq: [T]f32 = undefined;
    var pipe: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.renderPipeline(testing.allocator, tmpl, &input, &pipe);
    try testing.expectEqualSlices(f32, &seq, &pipe);
}

test "render() auto-routes a chunkable graph to chunking, matching sequential (the W1 routing)" {
    const taps = 6;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    try testing.expect(OB.chunkable); // routes to renderChunked
    const T = 900;
    var input: [T]f32 = undefined;
    fillNoise(&input, 23);
    var seq: [T]f32 = undefined;
    var auto: [T]f32 = undefined;
    const tmpl = .{ Source{}, Fir(taps){}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.render(testing.allocator, tmpl, &input, &auto);
    try testing.expectEqualSlices(f32, &seq, &auto); // exact-warmup ⇒ bit-identical
}

/// A stateful block that declares NO `warmup_samples` ⇒ the graph is not
/// chunkable, so `render()` must route it through pipeline/sequential, not
/// chunking (the "chunker forces a non-chunkable block through pipeline" law).
const Unchunkable = struct {
    y1: f32 = 0,
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |x, *y| {
            self.y1 = 0.5 * x.ch[0] + 0.5 * self.y1;
            y.ch[0] = self.y1;
        }
    }
};

test "render() forces a non-chunkable graph onto the pipeline path (no @compileError reached)" {
    const g = comptime blk: {
        var gg = graph.Graph.empty;
        gg.block_size = 64;
        const s = gg.add(Source);
        const f = gg.add(Unchunkable);
        const k = gg.add(Sink);
        gg.connect(port.MapOutPort(Source), s, 0, port.MapInPort(Unchunkable), f, 0);
        gg.connect(port.MapOutPort(Unchunkable), f, 0, port.MapInPort(Sink), k, 0);
        break :blk gg;
    };
    const OB = OfflineBatch(g, &.{ Source, Unchunkable, Sink });
    try testing.expect(!OB.chunkable); // routes to renderPipeline (linear chain)
    const T = 512;
    var input: [T]f32 = undefined;
    fillNoise(&input, 29);
    var seq: [T]f32 = undefined;
    var auto: [T]f32 = undefined;
    const tmpl = .{ Source{}, Unchunkable{}, Sink{} };
    OB.renderSequential(tmpl, &input, &seq);
    try OB.render(testing.allocator, tmpl, &input, &auto);
    try testing.expectEqualSlices(f32, &seq, &auto); // pipeline is exact
}

test "the O2 footprint is bounded and commit-known (chunk pools + scratch; pipeline rings)" {
    const taps = 8;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 4096;
    // More chunks ⇒ a larger but still finite, monotone footprint (K·pool + T + K·W).
    const f1 = OB.chunkFootprintBytes(1, T);
    const f8 = OB.chunkFootprintBytes(8, T);
    try testing.expect(f8 > f1);
    try testing.expect(f1 > 0 and f8 < 1 << 30); // bounded, no overflow
    // The pipeline footprint is the inter-stage rings only (S−1 of them).
    try testing.expect(OB.pipelineFootprintBytes() > 0);
}

// The error-path cleanup discipline: a failure at ANY allocation point inside
// renderChunked / renderPipeline must free exactly what was built, once — no leak
// and no double-free. `checkAllAllocationFailures` runs the function repeatedly,
// failing each allocation in turn, and the leak-checking testing allocator catches
// a leak OR a double-free on every one of those paths.

test "renderChunked cleans up at every allocation-failure point (no leak / no double-free)" {
    const taps = 4;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 256;
    var input: [T]f32 = undefined;
    fillNoise(&input, 5);
    var output: [T]f32 = undefined;
    const tmpl: OB.InstanceTuple = .{ Source{}, Fir(taps){}, Sink{} };
    const Run = struct {
        fn run(alloc: std.mem.Allocator, in: []const f32, out: []f32, tm: OB.InstanceTuple) !void {
            try OB.renderChunked(alloc, tm, in, out, 4);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{ @as([]const f32, &input), @as([]f32, &output), tmpl });
}

test "renderPipeline cleans up at every allocation-failure point (no leak / no double-deinit)" {
    const taps = 4;
    const g = comptime firGraph(taps);
    const OB = OfflineBatch(g, &.{ Source, Fir(taps), Sink });
    const T = 256;
    var input: [T]f32 = undefined;
    fillNoise(&input, 6);
    var output: [T]f32 = undefined;
    const tmpl: OB.InstanceTuple = .{ Source{}, Fir(taps){}, Sink{} };
    const Run = struct {
        fn run(alloc: std.mem.Allocator, in: []const f32, out: []f32, tm: OB.InstanceTuple) !void {
            try OB.renderPipeline(alloc, tm, in, out);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{ @as([]const f32, &input), @as([]f32, &output), tmpl });
}
