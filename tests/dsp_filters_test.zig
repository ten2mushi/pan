//! DSP-filters harness — the behavioral DEFINITION of the `Gain` and `Biquad`
//! Map blocks in `src/filters.zig`, written the Yoneda way: characterize each
//! block by every morphism that matters (its scaling/recurrence identity, its
//! SIMD-vs-scalar agreement, its push/pull/aliased differentials, and its match
//! against an external oracle) so any implementation passing all of these is
//! functionally equivalent to the one under test.
//!
//! COMPARISON DISCIPLINE (harness law, restated):
//!   - gold-vector vs the EXTERNAL oracle (the SciPy/NumPy blob) is the ≈ tier:
//!     `allcloseF32` with the manifest's resolved tolerance. Tolerance forgives
//!     the oracle's f64 working precision and summation order.
//!   - EVERY pan-vs-pan differential (dual-mux push≡pull, state-granularity
//!     split≡whole, in-place≡non-aliased) is BIT-EXACT. Tolerance never forgives
//!     pan disagreeing with itself.
//!   - the analytic one-pole oracle (closed-form geometric series) is an
//!     INDEPENDENT reference, compared approximately (libm `pow`, f64 working).
//!
//! Diagnostics on a deliberate mismatch/skip path go to `std.debug.print` (not
//! the logging facility) so a characterization test never inflates the runner's
//! logged-error count.
//!
//! Verified against zig 0.16.0; the `zig-0-16` skill was loaded before authoring
//! (project Rule 13/14).

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const num = pan.numericFor(.f32, .{});
const Gain = pan.filters.Gain(num);
const Biquad = pan.filters.Biquad(num);
const Coeffs = pan.filters.Coeffs(f32);
const Sample = pan.Sample(f32);

const testing = std.testing;

// --- local helpers ---------------------------------------------------------

/// A mutable `[]f32` view over a `[]Sample(f32)` (one lane per frame, bit-
/// identical storage) — the writable counterpart of harness `sampleValues`,
/// used as the destination when reading a raw f32 blob into a frame buffer.
fn mutableValues(frames: []Sample) []f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(frames)));
}

/// Wrap a bare `f32` slice as the planar one-lane `Sample(f32)` frames the
/// blocks consume. `Sample(f32)` is layout-identical to a bare `f32`, so this is
/// a faithful framing of a scalar test signal.
fn frame(comptime n: usize, vals: [n]f32) [n]Sample {
    var out: [n]Sample = undefined;
    for (&out, vals) |*o, v| o.ch[0] = v;
    return out;
}

/// A scalar reference for `Gain` over a float lane: element-wise `x * k`, with
/// NO vectorization. This is the independent oracle the `@Vector` kernel must
/// equal (the SIMD path is the implementation; this defines its meaning). The
/// product is formed at the lane width (f32) exactly as the scalar tail does, so
/// the comparison is legitimately bit-exact for the SIMD-vs-scalar law.
fn scalarGain(dst: []f32, src: []const f32, k: f32) void {
    for (dst, src) |*d, s| d.* = s * k;
}

/// The closed-form impulse response of the one-pole `y[n] = b0·x[n] − a1·y[n−1]`
/// driven by a unit impulse: `y[n] = b0 · (−a1)^n`. An independent analytic
/// oracle (no recurrence — a direct power), so a recurrence bug cannot hide.
fn onePoleImpulse(n: usize, b0: f32, a1: f32) f32 {
    return b0 * std.math.pow(f32, -a1, @floatFromInt(n));
}

/// Read a committed gold blob (`tests/vectors/<name>/<file>`) into `dst` as raw
/// native-endian f32. Returns `true` when the blob was present and fully read,
/// `false` (with a stderr note) when absent — the generate-on-demand policy
/// git-ignores the blobs, so a missing blob is a graceful skip, never a failure.
/// `dst.len * 4` bytes are expected (frame-major mono f32); a short/long blob is
/// a real contract breach and is surfaced as an error.
fn loadBlob(name: []const u8, file: []const u8, dst: []f32) !bool {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tests/vectors/{s}/{s}", .{ name, file }) catch unreachable;

    const cwd = std.Io.Dir.cwd();
    const f = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "skip: gold blob '{s}' absent (generate-on-demand; run scripts/generate.py) — gold check skipped\n",
                .{path},
            );
            return false;
        },
        else => return err,
    };
    defer f.close(io);

    const want_bytes: u64 = @as(u64, dst.len) * @sizeOf(f32);
    const got_len = try f.length(io);
    if (got_len != want_bytes) {
        std.debug.print(
            "gold blob '{s}' size mismatch: {d} bytes on disk, expected {d}\n",
            .{ path, got_len, want_bytes },
        );
        return error.BlobSizeMismatch;
    }
    const bytes = std.mem.sliceAsBytes(dst);
    const read = try f.readPositionalAll(io, bytes, 0);
    if (read != want_bytes) return error.BlobShortRead;
    return true;
}

// ===========================================================================
// Gain — a stateless, aliasing-safe per-element scale.
// ===========================================================================

test "Gain: the default coefficient is unity (an unconfigured Gain is a no-op)" {
    var g = Gain{};
    try testing.expectEqual(@as(f32, 1.0), g.gain);
    var in = frame(5, .{ -2.0, -0.5, 0.0, 0.5, 2.0 });
    var out: [5]Sample = undefined;
    g.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "Gain: scales every element by the linear coefficient (identity / zero / negative)" {
    var in = frame(6, .{ 1.0, -1.0, 0.25, -0.75, 3.0, -4.0 });

    // Identity: k = 1 leaves the signal untouched.
    {
        var g = Gain{ .gain = 1.0 };
        var out: [6]Sample = undefined;
        g.process(&in, &out);
        for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
    }
    // Zero: k = 0 mutes — every output is exactly +0.0.
    {
        var g = Gain{ .gain = 0.0 };
        var out: [6]Sample = undefined;
        g.process(&in, &out);
        for (out) |y| try testing.expectEqual(@as(f32, 0.0), y.ch[0]);
    }
    // Negative: k = −1 inverts polarity (a sign flip, exact in f32).
    {
        var g = Gain{ .gain = -1.0 };
        var out: [6]Sample = undefined;
        g.process(&in, &out);
        for (in, out) |x, y| try testing.expectEqual(-x.ch[0], y.ch[0]);
    }
    // Fractional attenuation: k = 0.5 is exact in binary (halving), so bit-exact.
    {
        var g = Gain{ .gain = 0.5 };
        var out: [6]Sample = undefined;
        g.process(&in, &out);
        for (in, out) |x, y| try testing.expectEqual(x.ch[0] * 0.5, y.ch[0]);
    }
}

test "Gain: the @Vector kernel equals a scalar reference, including a non-multiple-of-W tail" {
    // A length deliberately NOT a multiple of any plausible SIMD width W exercises
    // both the vector body and the scalar tail; their union must equal the pure
    // scalar reference bit-for-bit (same lane width, same per-element product).
    const n = 37; // prime: never a multiple of 2/4/8/16.
    var in: [n]Sample = undefined;
    h.fillNoise(&in, 0xC0FFEE);
    const k: f32 = 0.7;

    var out: [n]Sample = undefined;
    var g = Gain{ .gain = k };
    g.process(&in, &out);

    var ref: [n]f32 = undefined;
    scalarGain(&ref, h.sampleValues(&in), k);

    try h.bitExact(f32, h.sampleValues(&out), &ref);
}

test "Gain: push ≡ pull through the dual-mux seam (bit-exact)" {
    // Driving the SAME block over the SAME input through the push mux and the
    // pull mux must produce byte-identical output. Gain is stateless and rate-1:1
    // so there is no latency to align — the two streams overlap fully.
    const n = 300;
    var in: [n]Sample = undefined;
    h.fillNoise(&in, 11);
    const k: f32 = -0.3125; // exact in binary, isolates seam from rounding.

    var out_push: [n]Sample = undefined;
    var out_pull: [n]Sample = undefined;
    var gp = Gain{ .gain = k };
    var gq = Gain{ .gain = k };
    // A chunk that does not divide n forces ragged final chunks on both paths.
    h.renderPush(Gain, &gp, &in, &out_push, 64);
    h.renderPull(Gain, &gq, &in, &out_pull, 64);

    try h.expectPanVsPan(Gain, h.sampleValues(&out_push), h.sampleValues(&out_pull), "push", "pull");
}

test "Gain: in-place (aliased) ≡ non-aliased (bit-exact — vindicates aliasing_safe)" {
    // Gain declares `aliasing_safe = true`. Running it with out aliased onto in
    // (the in-place transport) must equal the non-aliased render bit-for-bit. A
    // divergence here would falsify the contract; expectPanVsPan emits the
    // falsified-contract diagnostic in that case.
    comptime try testing.expect(Gain.aliasing_safe);

    const n = 128;
    var base: [n]Sample = undefined;
    h.fillNoise(&base, 22);
    const k: f32 = 1.5;

    // Non-aliased reference path.
    var ref_out: [n]Sample = undefined;
    var g_ref = Gain{ .gain = k };
    g_ref.process(&base, &ref_out);

    // In-place candidate: a shared buffer seeded with the same input.
    var shared: [n]Sample = undefined;
    @memcpy(&shared, &base);
    var g_alias = Gain{ .gain = k };
    h.renderAliased(Gain, &g_alias, &shared);

    try h.expectPanVsPan(Gain, h.sampleValues(&ref_out), h.sampleValues(&shared), "non-aliased", "in-place");
}

test "Gain: classifies as a Map and declares aliasing_safe" {
    try testing.expect(pan.classify(Gain) == .Map);
    try testing.expect(Gain.aliasing_safe);
}

// ===========================================================================
// Biquad — a transposed-direct-form-II second-order section with z⁻¹ state.
// ===========================================================================

test "Biquad: identity coeffs (b0=1, rest 0) pass the signal through unchanged" {
    var bq = Biquad{};
    // Default Coeffs are the identity section.
    try testing.expectEqual(@as(f32, 1.0), bq.coeffs.b0);
    var in = frame(6, .{ 1.0, -1.0, 0.5, -0.25, 0.0, 0.75 });
    var out: [6]Sample = undefined;
    bq.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0], y.ch[0]);
}

test "Biquad: a pure feed-forward gain (b0=k, no poles) is just a scale" {
    // With a1=a2=b1=b2=0 the section degenerates to y = b0·x — a useful corner
    // that pins the b0 path independently of the recurrence.
    const k: f32 = 0.25;
    var bq = Biquad{ .coeffs = .{ .b0 = k } };
    var in = frame(5, .{ 1.0, 2.0, -3.0, 4.0, -8.0 });
    var out: [5]Sample = undefined;
    bq.process(&in, &out);
    for (in, out) |x, y| try testing.expectEqual(x.ch[0] * k, y.ch[0]);
}

test "Biquad: one-pole impulse response equals the closed-form geometric series" {
    // y[n] = b0·x[n] − a1·y[n−1]; driven by an impulse the closed form is
    // y[n] = b0·(−a1)^n. The analytic power is the INDEPENDENT oracle (no
    // recurrence), compared approximately (the geometric ratio is not exact in
    // f32 and libm differs in summation).
    const b0: f32 = 0.2;
    const a1: f32 = -0.8;
    var bq = Biquad{ .coeffs = .{ .b0 = b0, .a1 = a1 } };

    const n = 32;
    var in: [n]Sample = undefined;
    h.fillImpulse(&in); // unit impulse at index 0, rest silent.
    var out: [n]Sample = undefined;
    bq.process(&in, &out);

    for (out, 0..) |y, i| {
        const expected = onePoleImpulse(i, b0, a1);
        try testing.expectApproxEqAbs(expected, y.ch[0], 1e-6);
    }
}

test "Biquad: a stable pole decays toward zero (the recurrence does not blow up)" {
    // |−a1| = 0.8 < 1, so the impulse response is bounded and the tail decays.
    // This pins a qualitative invariant the closed form implies: late samples are
    // far smaller than the leading sample.
    const b0: f32 = 0.2;
    const a1: f32 = -0.8;
    var bq = Biquad{ .coeffs = .{ .b0 = b0, .a1 = a1 } };
    const n = 64;
    var in: [n]Sample = undefined;
    h.fillImpulse(&in);
    var out: [n]Sample = undefined;
    bq.process(&in, &out);
    try testing.expect(@abs(out[0].ch[0]) > @abs(out[n - 1].ch[0]));
    try testing.expect(@abs(out[n - 1].ch[0]) < 1e-3);
}

test "Biquad: state-granularity — a split render equals one whole render (bit-exact)" {
    // The defining property of a stateful block: chopping the render into
    // sub-blocks and carrying state across calls must reproduce, byte-for-byte,
    // the single whole-buffer render. A second-order section with both a
    // feed-forward zero and a pole makes both state words (z1, z2) load-bearing.
    const c = Coeffs{ .b0 = 0.5, .b1 = -0.4, .b2 = 0.2, .a1 = -0.3, .a2 = 0.15 };
    const n = 40;
    var in: [n]Sample = undefined;
    h.fillNoise(&in, 99);

    var whole_blk = Biquad{ .coeffs = c };
    var whole_out: [n]Sample = undefined;
    whole_blk.process(&in, &whole_out);

    // Ragged split boundaries (7, then 13, then the rest) so the seam is not on a
    // round number and the carried state truly spans irregular chunks.
    var split_blk = Biquad{ .coeffs = c };
    var split_out: [n]Sample = undefined;
    split_blk.process(in[0..7], split_out[0..7]);
    split_blk.process(in[7..20], split_out[7..20]);
    split_blk.process(in[20..], split_out[20..]);

    try h.expectPanVsPan(Biquad, h.sampleValues(&whole_out), h.sampleValues(&split_out), "whole", "split");
}

test "Biquad: single-element chunks equal the whole render (the finest state granularity)" {
    // The extreme of the split≡whole law: render one sample at a time. If the
    // z⁻¹ state did not persist exactly across calls this would diverge from the
    // whole render at the first non-trivial sample.
    const c = Coeffs{ .b0 = 0.7, .b1 = 0.1, .a1 = -0.5, .a2 = 0.2 };
    const n = 24;
    var in: [n]Sample = undefined;
    h.fillNoise(&in, 123);

    var whole_blk = Biquad{ .coeffs = c };
    var whole_out: [n]Sample = undefined;
    whole_blk.process(&in, &whole_out);

    var step_blk = Biquad{ .coeffs = c };
    var step_out: [n]Sample = undefined;
    for (0..n) |i| step_blk.process(in[i .. i + 1], step_out[i .. i + 1]);

    try h.expectPanVsPan(Biquad, h.sampleValues(&whole_out), h.sampleValues(&step_out), "whole", "one-at-a-time");
}

test "Biquad: push ≡ pull through the dual-mux seam (bit-exact)" {
    // Same recurrence, same input, two mux interpretations; rate-1:1 with zero
    // declared latency, so the streams overlap fully and must be byte-identical.
    const c = Coeffs{ .b0 = 0.3, .b1 = 0.2, .b2 = 0.1, .a1 = -0.4, .a2 = 0.25 };
    const n = 257; // prime length, ragged against the chunk size.
    var in: [n]Sample = undefined;
    h.fillNoise(&in, 4242);

    var bp = Biquad{ .coeffs = c };
    var bq = Biquad{ .coeffs = c };
    var out_push: [n]Sample = undefined;
    var out_pull: [n]Sample = undefined;
    h.renderPush(Biquad, &bp, &in, &out_push, 48);
    h.renderPull(Biquad, &bq, &in, &out_pull, 48);

    try h.expectPanVsPan(Biquad, h.sampleValues(&out_push), h.sampleValues(&out_pull), "push", "pull");
}

test "Biquad: classifies as a Map that is NOT aliasing_safe (the sequential recurrence)" {
    try testing.expect(pan.classify(Biquad) == .Map);
    try testing.expect(!@hasDecl(Biquad, "aliasing_safe"));
}

// ===========================================================================
// Manifest contract (always-validated) + external gold-vector oracle.
// ===========================================================================

const gain_f32_json = @embedFile("vectors/gain_f32.json");
const biquad_f32_json = @embedFile("vectors/biquad_f32.json");

test "manifest: gain_f32.json parses and resolves a float (approx) tolerance" {
    const parsed = try h.parseManifest(testing.allocator, gain_f32_json);
    defer parsed.deinit();
    const m = parsed.value;
    try testing.expectEqualStrings("gain_f32", m.name);
    try testing.expectEqualStrings("Gain", m.block);
    try testing.expectEqualStrings("f32", m.format.precision);
    try testing.expectEqualStrings("1:1", m.out_per_in);
    try testing.expectEqual(@as(i64, 0), m.algorithmic_latency);
    const tol = try m.resolveTolerance();
    try testing.expect(tol == .approx);
    try testing.expect(tol.approx.atol > 0);
    try testing.expect(tol.approx.rtol > 0);
}

test "manifest: biquad_f32.json parses and resolves a float (approx) tolerance" {
    const parsed = try h.parseManifest(testing.allocator, biquad_f32_json);
    defer parsed.deinit();
    const m = parsed.value;
    try testing.expectEqualStrings("biquad_f32", m.name);
    try testing.expectEqualStrings("Biquad", m.block);
    try testing.expectEqualStrings("f32", m.format.precision);
    try testing.expectEqualStrings("1:1", m.out_per_in);
    const tol = try m.resolveTolerance();
    try testing.expect(tol == .approx);
    try testing.expect(tol.approx.atol > 0);
}

test "GoldVector: Gain(f32) vs the SciPy/NumPy oracle blob, allclose within manifest tolerance" {
    // Read the manifest for params (gain_db) + tolerance + n_frames; then run the
    // REAL Gain block through the push mux over the oracle's input.bin and compare
    // to expected.bin with numpy.allclose semantics. The blob is git-ignored
    // (generate-on-demand), so absence is a graceful skip, not a failure.
    const parsed = try h.parseManifest(testing.allocator, gain_f32_json);
    defer parsed.deinit();
    const m = parsed.value;
    const tol = try m.resolveTolerance();

    const n = m.n_frames; // manifest says 1024.
    const input = try testing.allocator.alloc(Sample, n);
    defer testing.allocator.free(input);
    const expected = try testing.allocator.alloc(f32, n);
    defer testing.allocator.free(expected);
    const output = try testing.allocator.alloc(Sample, n);
    defer testing.allocator.free(output);

    // input.bin is raw native f32, layout-identical to Sample(f32).
    if (!try loadBlob(m.name, "input.bin", mutableValues(input))) return;
    if (!try loadBlob(m.name, "expected.bin", expected)) return;

    // The manifest carries gain_db = −6 dB; the lane coefficient is 10^(db/20).
    // We derive the SAME linear gain the generator used (an independent compute,
    // not a copy of pan's output): both apply the standard dB→linear law.
    const gain_lin: f32 = std.math.pow(f32, 10.0, -6.0 / 20.0);
    var blk = Gain{ .gain = gain_lin };
    h.renderPush(Gain, &blk, input, output, m.format.block_size);

    try h.allcloseF32(h.sampleValues(output)[0..n], expected, tol);
}

test "GoldVector: Biquad(f32) vs the SciPy/NumPy oracle blob, allclose within manifest tolerance" {
    const parsed = try h.parseManifest(testing.allocator, biquad_f32_json);
    defer parsed.deinit();
    const m = parsed.value;
    const tol = try m.resolveTolerance();

    const n = m.n_frames;
    const input = try testing.allocator.alloc(Sample, n);
    defer testing.allocator.free(input);
    const expected = try testing.allocator.alloc(f32, n);
    defer testing.allocator.free(expected);
    const output = try testing.allocator.alloc(Sample, n);
    defer testing.allocator.free(output);

    if (!try loadBlob(m.name, "input.bin", mutableValues(input))) return;
    if (!try loadBlob(m.name, "expected.bin", expected)) return;

    // Coeffs from the manifest params (b0=0.2, a1=−0.8). Hard-coding the same
    // constants the generator used keeps the oracle independent of pan's output.
    var blk = Biquad{ .coeffs = .{ .b0 = 0.2, .b1 = 0.0, .b2 = 0.0, .a1 = -0.8, .a2 = 0.0 } };
    h.renderPush(Biquad, &blk, input, output, m.format.block_size);

    try h.allcloseF32(h.sampleValues(output)[0..n], expected, tol);
}
