//! Shared test backbone for the pan harness drivers.
//!
//! This file is the common infrastructure every `tests/<harness>_test.zig`
//! driver imports (by relative path, within the `tests/` module root). It holds:
//!
//!   - the comparison vocabulary: the `Tolerance` union, `allcloseF32` (the
//!     numpy.allclose policy used ONLY against the external float oracle) and
//!     `bitExact` (the exact check used for integer/fixed-point oracles AND for
//!     every pan-vs-pan differential, regardless of lane);
//!   - the alignment/measurement helpers `alignByLatency` and
//!     `measuredGroupDelay`;
//!   - render drivers that push a block's `process` THROUGH the byte-typed
//!     10-method SampleMux vtable under both push and pull semantics, so the
//!     drivers exercise the real seam rather than bypassing it;
//!   - a few reusable synthetic blocks (identity, aliasing-safe scale, a
//!     stateful accumulator) — the only blocks that exist at this phase, since
//!     the DSP library lands later. Harness drivers and the Yoneda test-writers
//!     characterize the backbone against these.
//!
//! Deliberately carries NO `test {}` blocks: it is imported into several test
//! modules, and a test here would be compiled and run once per importer.
//!
//! The one law restated inline (so this file stands alone): tolerance forgives
//! the *oracle's* different arithmetic — its f64 working precision, its
//! summation order, its libm transcendentals — but it never forgives pan
//! disagreeing with itself. A pan-vs-pan check is therefore always bit-exact;
//! a float "almost match" between two pan runs is a failure, not a pass.

const std = @import("std");
const pan = @import("pan");

pub const Sample = pan.Sample;

// --- reinterpretation at the byte seam ------------------------------------
//
// The SampleMux hands out byte slices; a block's typed wrapper recovers the
// element slice. `Sample(f32)` is a one-lane planar frame, bit-identical to a
// bare `f32`, so a sample slice and its byte slice round-trip exactly.

pub fn bytesOfConst(comptime T: type, items: []const T) []const u8 {
    return std.mem.sliceAsBytes(items);
}
pub fn bytesOf(comptime T: type, items: []T) []u8 {
    return std.mem.sliceAsBytes(items);
}
pub fn samplesOfConst(comptime T: type, bytes: []const u8) []const T {
    // The bytes originate from a properly-aligned `[]T`, so restoring the
    // element alignment with @alignCast is safe (and safety-checked in Debug).
    return @alignCast(std.mem.bytesAsSlice(T, bytes));
}
pub fn samplesOf(comptime T: type, bytes: []u8) []T {
    return @alignCast(std.mem.bytesAsSlice(T, bytes));
}

/// View a `[]Sample(f32)` as the `[]const f32` the allclose comparator wants
/// (one lane per frame, bit-identical storage).
pub fn sampleValues(frames: []const Sample(f32)) []const f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(frames)));
}

// --- the comparison vocabulary --------------------------------------------

/// The comparison mode a manifest selects: `approx` is numpy.allclose against
/// the external float oracle; `bit_exact` is exact bytes — the integer/
/// fixed-point oracle AND every pan-vs-pan differential.
pub const Tolerance = union(enum) {
    approx: struct { atol: f64, rtol: f64 },
    bit_exact,
};

/// numpy.allclose: |got - ref| <= atol + rtol*|ref|, elementwise. Used ONLY for
/// the external float oracle (the ≈ tier). A bit_exact tolerance handed to a
/// float oracle is a manifest error, so reading `tol.approx` is intentional.
pub fn allcloseF32(got: []const f32, ref: []const f32, tol: Tolerance) !void {
    const a = tol.approx;
    if (got.len != ref.len) return error.LengthMismatch;
    for (got, ref, 0..) |g, r, i| {
        const diff = @abs(@as(f64, g) - @as(f64, r));
        const bound = a.atol + a.rtol * @abs(@as(f64, r));
        if (diff > bound) {
            // Diagnostic to stderr (not the logging facility): a test that
            // deliberately characterizes the reject path must not inflate the
            // runner's logged-error count and flip an otherwise-passing suite to
            // a non-zero exit. The returned error is the loud signal.
            std.debug.print("oracle allclose fail @ {d}: |{d}-{d}| = {d} > {d}\n", .{ i, g, r, diff, bound });
            return error.OracleMismatch;
        }
    }
}

/// Bit-exact: the integer/fixed-point oracle AND every pan-vs-pan check.
pub fn bitExact(comptime T: type, got: []const T, ref: []const T) !void {
    try std.testing.expectEqualSlices(T, ref, got);
}

/// Does `Block` declare itself in-place-safe (the M4 marker the in-place
/// coalescing gate checks)?
pub fn declaresAliasingSafe(comptime Block: type) bool {
    return @hasDecl(Block, "aliasing_safe") and Block.aliasing_safe;
}

/// The index of the first sample whose BIT PATTERN differs between the two
/// streams, or null if identical. Bit comparison (not value `!=`) so a NaN
/// paranoid-poison counts as a divergence rather than slipping past — and so
/// `+0.0`/`−0.0` are treated as the distinct bit patterns they are.
pub fn firstBitDivergence(a: []const f32, b: []const f32) ?usize {
    for (a, b, 0..) |x, y, i| {
        if (@as(u32, @bitCast(x)) != @as(u32, @bitCast(y))) return i;
    }
    return null;
}

/// Pan-vs-pan bit-exact comparison with the `aliasing_safe` failure-message
/// contract. `reference` is the obviously-correct path (per-edge double buffers /
/// non-aliased); `candidate` is the path under test (colored pool / aliased
/// in-place). On agreement, returns. On a divergence:
///   - if `Block` declared `aliasing_safe = true`, the divergence means that
///     claim is FALSE — emit the falsified-contract message that names and quotes
///     the assertion back, identifies the first divergent sample (with both
///     values), and states the fix, then return `error.AliasingSafeViolated`;
///   - otherwise the two paths run identical kernels on identical inputs and must
///     be bit-identical, so a divergence is a storage/colorer bug — emit a
///     generic pan-vs-pan divergence and return `error.PanDivergence`.
/// The diagnostic goes to stderr (not the logging facility) so a test that
/// deliberately characterizes the violation path does not flip the suite's exit
/// code; the returned error is the loud signal.
pub fn expectPanVsPan(
    comptime Block: type,
    reference: []const f32,
    candidate: []const f32,
    ref_label: []const u8,
    cand_label: []const u8,
) !void {
    if (reference.len != candidate.len) return error.LengthMismatch;
    const idx = firstBitDivergence(reference, candidate) orelse return;
    const rv = reference[idx];
    const cv = candidate[idx];
    if (comptime declaresAliasingSafe(Block)) {
        std.debug.print(
            \\error: aliasing hazard in block '{s}' — output differs between the {s} and
            \\       {s} execution paths.
            \\   This block declared `pub const aliasing_safe = true`, asserting process() never
            \\   reads an input element after the corresponding output element was written. That
            \\   assertion is FALSE.
            \\   first divergent sample: index {d}  ({s} = {d:.4}, {s} = {d:.4})
            \\   fix: remove `aliasing_safe` (forfeits in-place coalescing) OR restructure the
            \\        kernel so reads precede writes per lane.
            \\
        , .{ @typeName(Block), cand_label, ref_label, idx, ref_label, rv, cand_label, cv });
        return error.AliasingSafeViolated;
    }
    std.debug.print(
        \\error: pan-vs-pan divergence in block '{s}' between {s} and {s}.
        \\   These paths run identical kernels on identical inputs; they must be bit-identical,
        \\   so a divergence is a storage/colorer bug, not numerics.
        \\   first divergent sample: index {d}  ({s} = {d:.4}, {s} = {d:.4})
        \\
    , .{ @typeName(Block), ref_label, cand_label, idx, ref_label, rv, cand_label, cv });
    return error.PanDivergence;
}

/// Pan-vs-pan alignment: the pull stream lags the push stream by the declared
/// algorithmic_latency, so compare the overlapping region only — bit-exact,
/// tolerance never applies here.
pub fn alignByLatency(comptime T: type, push: []const T, pull: []const T, latency: usize) !void {
    if (push.len < latency or pull.len < latency) return error.TooShort;
    try std.testing.expectEqualSlices(T, push[latency..], pull[0 .. pull.len - latency]);
}

/// Latency-contract measurement: the index of the first sample whose magnitude
/// exceeds `eps` is the measured group delay; it must equal the declared
/// algorithmic_latency. Returns null for an all-quiet response.
pub fn measuredGroupDelay(impulse_response: []const f32, eps: f32) ?usize {
    for (impulse_response, 0..) |s, i| if (@abs(s) > eps) return i;
    return null;
}

/// Poison a float buffer to NaN. The paranoid-mode mechanism: a buffer released
/// back to a pool is overwritten with NaN so a read-after-free or premature
/// reuse surfaces as a divergence rather than a stale-but-plausible value.
pub fn poisonNaN(buf: []f32) void {
    const nan = std.math.nan(f32);
    for (buf) |*x| x.* = nan;
}

/// Does any lane of this buffer hold a NaN? Used to assert the poison mechanism
/// actually flags a stale read.
pub fn anyNaN(buf: []const f32) bool {
    for (buf) |x| if (std.math.isNan(x)) return true;
    return false;
}

// --- render drivers: through the 10-method SampleMux vtable ----------------
//
// These mimic, at the seam, exactly what the executor will later do: obtain
// input/output slices FROM a mux and hand them to `process`. The availability
// counts are byte counts (the seam is byte-typed); we convert to element
// counts. Going through the vtable is the point — a surface leak between the
// push and pull interpretations is what the dual-mux probe catches.

/// Drive `blk.process` under PUSH semantics (`TestSampleMux`): a fresh
/// whole-buffer mux per chunk, output committed with `updateOutputBuffer`.
pub fn renderPush(
    comptime Block: type,
    blk: *Block,
    in: []const Sample(f32),
    out: []Sample(f32),
    chunk: usize,
) void {
    std.debug.assert(in.len == out.len);
    const esz = @sizeOf(Sample(f32));
    var i: usize = 0;
    while (i < in.len) {
        const n = @min(chunk, in.len - i);
        var tm = pan.TestSampleMux{
            .input = bytesOfConst(Sample(f32), in[i .. i + n]),
            .output = bytesOf(Sample(f32), out[i .. i + n]),
        };
        const mux = tm.sampleMux();
        mux.waitInputAvailable(0, n * esz);
        const src = samplesOfConst(Sample(f32), mux.getInputBuffer(0));
        const dst = samplesOf(Sample(f32), mux.getOutputBuffer(0));
        blk.process(src, dst);
        mux.updateOutputBuffer(0, n * esz);
        i += n;
    }
}

/// Drive `blk.process` under PULL semantics (`PullTestSampleMux`): one mux over
/// the whole buffer, cursors advanced by `updateInputBuffer`/`updateOutputBuffer`
/// each chunk until the input is drained.
pub fn renderPull(
    comptime Block: type,
    blk: *Block,
    in: []const Sample(f32),
    out: []Sample(f32),
    chunk: usize,
) void {
    std.debug.assert(in.len == out.len);
    const esz = @sizeOf(Sample(f32));
    var pm = pan.PullTestSampleMux{
        .input = bytesOfConst(Sample(f32), in),
        .output = bytesOf(Sample(f32), out),
    };
    const mux = pm.sampleMux();
    while (mux.getInputAvailable(0) > 0) {
        const avail = mux.getInputAvailable(0) / esz;
        const n = @min(chunk, avail);
        mux.waitInputAvailable(0, n * esz);
        const src = samplesOfConst(Sample(f32), mux.getInputBuffer(0))[0..n];
        const dst = samplesOf(Sample(f32), mux.getOutputBuffer(0))[0..n];
        blk.process(src, dst);
        mux.updateInputBuffer(0, n * esz);
        mux.updateOutputBuffer(0, n * esz);
    }
}

/// Drive `blk.process` with the output buffer ALIASED onto the input buffer
/// (in==out), the in-place transport. Only legal for an `aliasing_safe` block.
/// Writes the input into the shared buffer first, then renders in place.
pub fn renderAliased(
    comptime Block: type,
    blk: *Block,
    shared: []Sample(f32),
) void {
    const esz = @sizeOf(Sample(f32));
    // The SampleMux exposes the SAME backing bytes as both input and output.
    var tm = pan.TestSampleMux{
        .input = bytesOfConst(Sample(f32), shared),
        .output = bytesOf(Sample(f32), shared),
    };
    const mux = tm.sampleMux();
    mux.waitInputAvailable(0, shared.len * esz);
    const src = samplesOfConst(Sample(f32), mux.getInputBuffer(0));
    const dst = samplesOf(Sample(f32), mux.getOutputBuffer(0));
    blk.process(src, dst);
    mux.updateOutputBuffer(0, shared.len * esz);
}

// --- deterministic synthetic test signals ---------------------------------

/// A reproducible white-ish signal in [-1, 1). Mirrors the generator's intent
/// (a fixed RNG seed → byte-reproducible vector) without depending on a
/// git-ignored blob: the harness drivers are hermetic.
pub fn fillNoise(buf: []Sample(f32), seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (buf) |*s| s.ch[0] = r.float(f32) * 2.0 - 1.0;
}

/// A unit impulse at index 0, the rest silent — the latency-contract probe.
pub fn fillImpulse(buf: []Sample(f32)) void {
    for (buf) |*s| s.ch[0] = 0.0;
    if (buf.len > 0) buf[0].ch[0] = 1.0;
}

// --- reusable synthetic blocks (the only blocks that exist this phase) -----

/// The identity Map: copies input to output. NOT aliasing-safe (`@memcpy`
/// requires disjoint slices), so it is the non-aliased baseline.
pub const Identity = struct {
    const Self = @This();
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        @memcpy(out, in);
    }
};

/// An aliasing-safe scale (gain) Map: writes each output element from the
/// corresponding input element, so out==in (read-then-write per lane) is a
/// no-op-on-values for an unwritten neighbour — the in-place coalescing target.
/// Declares `aliasing_safe = true`, the M4 marker the in-place gate checks.
pub const Scale = struct {
    const Self = @This();
    k: f32 = 1.0,
    pub const aliasing_safe = true;
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |i, *o| o.ch[0] = i.ch[0] * self.k;
    }
};

/// A stateful one-pole accumulator (running sum) Map. Its end-state depends on
/// every prior sample, so splitting a render into sub-blocks is only correct if
/// the state carries across calls — the property the state-granularity harness
/// pins. (A stateless block would pass that harness vacuously.)
pub const Accumulator = struct {
    const Self = @This();
    acc: f32 = 0.0,
    pub fn process(self: *Self, in: []const Sample(f32), out: []Sample(f32)) void {
        for (in, out) |i, *o| {
            self.acc += i.ch[0];
            o.ch[0] = self.acc;
        }
    }
};

// --- gold-vector manifest schema (parse/validate the committed JSON) -------

/// The committed gold-vector manifest contract (the schema). Parsed with
/// `ignore_unknown_fields` so block-specific `params`/`in_ports`/`out_ports`
/// (validated structurally elsewhere) don't need to be modelled here.
pub const Manifest = struct {
    name: []const u8,
    block: []const u8,
    format: Format,
    out_per_in: []const u8,
    algorithmic_latency: i64,
    seed: i64,
    n_frames: usize,
    tolerance: ToleranceJson = .{},

    pub const Format = struct {
        sample_rate: u32,
        precision: []const u8,
        channels: u16,
        block_size: usize,
    };

    /// A manifest carries EITHER `{atol, rtol}` (float oracle) OR
    /// `{bit_exact: true}` (integer/fixed-point). Both shapes parse here; the
    /// resolver below turns it into the `Tolerance` union, rejecting a manifest
    /// that declares neither or both.
    pub const ToleranceJson = struct {
        atol: ?f64 = null,
        rtol: ?f64 = null,
        bit_exact: ?bool = null,
    };

    pub fn resolveTolerance(self: Manifest) !Tolerance {
        const t = self.tolerance;
        const is_exact = t.bit_exact orelse false;
        const is_approx = t.atol != null or t.rtol != null;
        if (is_exact and is_approx) return error.ToleranceAmbiguous;
        if (is_exact) return .bit_exact;
        if (is_approx) return .{ .approx = .{
            .atol = t.atol orelse 0,
            .rtol = t.rtol orelse 0,
        } };
        return error.ToleranceMissing;
    }
};

/// Parse a committed manifest's JSON text. Caller owns the returned `Parsed`
/// and must `deinit()` it (the strings borrow its arena).
pub fn parseManifest(alloc: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(Manifest, alloc, json_text, .{ .ignore_unknown_fields = true });
}
