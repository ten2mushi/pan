//! A thin unified entry façade — route a single `render` call by *intent* to the
//! existing execution tiers, without merging any tier's internals.
//!
//! pan already has three principled execution surfaces: the comptime single-core
//! Tier-A executors (`engine.Executor` / `engine.FusedExecutor`), the offline
//! throughput executor (`OfflineBatch`, Tier-C), and the device-callback runtime
//! `Engine` (Tier-A/B). Each is constructed and driven differently. This façade
//! adds only *discoverability*: one `pan.render(...)` that picks the right one
//! from a `RenderOptions.intent`, then delegates. It owns no scheduling, coloring,
//! or pooling — every code path here is a few lines that construct the existing
//! executor and call its existing entry point.
//!
//! Scope: the buffer-in / buffer-out form (`[]const f32 -> []f32`). That shape is
//! only well-defined for an **offline-style endpoint graph** — one `offline.Source`
//! at the head injecting the input timeline and one `offline.Sink` at the tail
//! capturing the output, both carrying a single mono `Sample(f32)` lane. That is
//! precisely the graph shape where the realtime and offline tiers are directly
//! comparable over the *same* `(input, output)` pair, which is what makes a single
//! uniform signature meaningful. A graph without those endpoints is rejected at
//! compile time (the endpoint location is delegated to `OfflineBatch`, which
//! `@compileError`s on a missing/duplicated `offline.Source`/`offline.Sink`).
//!
//! A buffer render has no device loop, so it does NOT own or drive the runtime
//! `Engine` (that tier is callback-driven: the device pulls blocks on its own
//! thread). Multicore *realtime* therefore cannot be honestly engaged from a
//! buffer render — see `render`'s `cores > 1` handling below, which runs the
//! single-core Tier-A path and says so rather than pretending to parallelise.

const std = @import("std");
const graph = @import("graph.zig");
const engine = @import("engine.zig");
const offline = @import("offline.zig");

/// How to execute a buffer render.
pub const RenderOptions = struct {
    /// `.realtime` drives the comptime single-core Tier-A executor block-by-block
    /// over the timeline (the deadline-respecting pull kernels, run here without a
    /// device). `.offline` drives the Tier-C `OfflineBatch` (throughput: it may
    /// chunk the timeline across cores, pipeline the stages, or run sequentially —
    /// it auto-routes). Both produce the same audio from the same graph; they
    /// differ only in *how* the work is scheduled.
    intent: enum { realtime, offline } = .realtime,
    /// Worker cores. Honoured by `.offline` (timeline chunking / file-level batch).
    /// For `.realtime` a buffer render has no device callback loop to drive a
    /// parallel render workgroup, so `cores > 1` does NOT parallelise here — it
    /// runs the single-core Tier-A path (see `render`). True multicore realtime is
    /// the device-driven runtime `Engine`, which a buffer façade does not own.
    cores: usize = 1,
    /// Apply automatic comptime loop-fusion on the realtime path (`FusedExecutor`
    /// vs the unfused `Executor`). Fusion is bit-transparent — it only changes
    /// memory traffic, never the output — so this is a performance knob, not a
    /// semantic one. Ignored by `.offline` (its workers are unfused `Executor`s).
    fuse: bool = true,
};

/// Render `input` into `output` through the committed graph `g` (one block type
/// per node in `node_blocks`), routing by `opts.intent`. `g` must be an
/// offline-style endpoint graph: exactly one `offline.Source` head and one
/// `offline.Sink` tail (enforced at compile time). `template` is the configured
/// per-node block tuple — its `Source`/`Sink` instances are overridden here with
/// `input`/`output`, so the caller leaves those at their defaults. `input` and
/// `output` must be the same length.
///
/// Routing:
///   * `.offline`            → `OfflineBatch(g, node_blocks).render` (auto-routes
///                             chunk / pipeline / sequential by graph shape).
///   * `.realtime, cores==1` → the comptime Tier-A executor, fused or unfused per
///                             `opts.fuse`, driven block-by-block over the timeline.
///   * `.realtime, cores>1`  → the SAME single-core Tier-A path (a buffer render
///                             has no device loop to engage true Tier-B parallel
///                             realtime — that is the runtime `Engine`). Honest by
///                             construction: this never silently claims to have
///                             parallelised; the work runs single-core.
pub fn render(
    comptime g: graph.Graph,
    comptime node_blocks: []const type,
    alloc: std.mem.Allocator,
    template: std.meta.Tuple(node_blocks),
    input: []const f32,
    output: []f32,
    opts: RenderOptions,
) !void {
    // Constructing OfflineBatch validates the offline-endpoint contract at compile
    // time (it `@compileError`s on a missing/duplicated Source/Sink) and gives us
    // the endpoint node ids — reused for the realtime seam so the endpoint location
    // is never duplicated here.
    const OB = offline.OfflineBatch(g, node_blocks);

    switch (opts.intent) {
        .offline => return OB.render(alloc, template, input, output),
        .realtime => {
            // A buffer render owns no device callback loop, so it cannot drive the
            // runtime Engine's Tier-B parallel render. cores > 1 falls through to
            // the single-core Tier-A path: correct, but NOT parallelised. For real
            // multicore realtime, drive the device-callback `engine.Engine` with
            // `EngineOptions{ .cores = N }` directly (out of scope for a uniform
            // buffer-in/buffer-out façade).
            if (opts.fuse) {
                driveFused(g, node_blocks, OB.source_id, OB.sink_id, template, input, output);
            } else {
                // The unfused single-core path is exactly OfflineBatch's offline
                // ground truth (one `Executor`, seek/attach the Source/Sink, render
                // block-by-block) — reuse it verbatim rather than re-implement the
                // block loop.
                OB.renderSequential(template, input, output);
            }
        },
    }
}

/// `.realtime` + `.fuse=true`: drive a `FusedExecutor` block-by-block over the
/// timeline. The Source/Sink are passthrough nodes under fusion (a zero-input
/// source and an output-only sink are not fusable Maps), so they keep their own
/// top-level slots; seeding the timeline through the template's `Source.window` /
/// `Sink.dest` fields (which `FusedExecutor.init` copies into those slots) points
/// the render at `input`/`output` without needing to reach the scattered instances
/// after init. The block loop mirrors `OfflineBatch.driveWindow`: the Source
/// zero-pads past the window and the Sink clamps at its end, so an arbitrary-length
/// timeline renders with no scalar-tail special case.
fn driveFused(
    comptime g: graph.Graph,
    comptime node_blocks: []const type,
    comptime source_id: usize,
    comptime sink_id: usize,
    template: std.meta.Tuple(node_blocks),
    input: []const f32,
    output: []f32,
) void {
    std.debug.assert(input.len == output.len);
    const N = g.block_size;

    // Seed the timeline endpoints into the template before init scatters it. The
    // Source reads from `window` (cursor starts at 0); the Sink writes into `dest`.
    var seeded = template;
    seeded[source_id].window = input;
    seeded[source_id].cursor = 0;
    seeded[sink_id].dest = output;
    seeded[sink_id].cursor = 0;

    const Fused = engine.FusedExecutor(g, node_blocks);
    var exec = Fused.init(seeded);

    const tok = engine.enterRealtimeThread();
    defer tok.leave();
    var done: usize = 0;
    while (done < output.len) : (done += N) {
        exec.render(tok);
    }
}

/// File-level offline parallelism: render a list of fully independent jobs across
/// up to `opts.cores` worker threads. Each `Job` is an `{ input, output }` pair
/// rendered in complete isolation (its own freshly-seeded executor, state, and
/// pool), so each job's output is **bit-identical** to running that one job alone
/// through the sequential `.offline` path — parallelism here changes only
/// scheduling, never the per-job arithmetic. Only the offline intent makes sense
/// for a batch (the throughput tier); `opts.intent`/`opts.fuse` are not consulted.
/// `Job` is `OfflineBatch(g, node_blocks).Job`.
pub fn renderJobs(
    comptime g: graph.Graph,
    comptime node_blocks: []const type,
    alloc: std.mem.Allocator,
    template: std.meta.Tuple(node_blocks),
    jobs: []const offline.OfflineBatch(g, node_blocks).Job,
    opts: RenderOptions,
) !void {
    const OB = offline.OfflineBatch(g, node_blocks);
    return OB.renderBatch(alloc, template, jobs, opts.cores);
}
