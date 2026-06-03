//! dsp_spatial_test — the behavioral SPECIFICATION of `spatial.ConstantPowerPan`
//! (src/spatial.zig), written the Yoneda way: characterize the block through
//! every morphism that matters (structural classification, the constant-power
//! analytic law, the hard-pan boundaries, parameter clamping, the storage layout
//! it claims, and the external SciPy/NumPy gold vector). Each assertion compares
//! pan against an INDEPENDENT oracle — the mathematical truth (`cos`/`sin`,
//! `L²+R²=1`) or the committed blob — never against pan's own output.
//!
//! Why these tests matter (Rule 9 — intent, not just behavior):
//!   - A *layout change* mono→stereo is the defining structural fact of this
//!     block; it is what makes the block interesting at `connect` time. If a
//!     refactor collapsed the output to mono, the analytic gain checks would
//!     still pass on `ch[0]` — only the structural port check catches it.
//!   - *Constant power* (L²+R²=1) is the entire reason this block exists rather
//!     than a linear pan; a linear-law regression keeps center≈0.5+0.5 but
//!     breaks unit power, so the sweep is the load-bearing law.
//!   - The *gold vector* pins pan's f32 arithmetic against an f64-working-precision
//!     oracle (numpy cos/sin), which is exactly why allclose — not bit-exact — is
//!     the right comparator here (harness law: tolerance forgives the oracle's
//!     different arithmetic, never pan disagreeing with itself).
//!
//! COMPARISON MODE:
//!   - analytic-law checks: `expectApproxEqAbs` against the independently-derived
//!     mathematical value (the standard libm θ=(p+1)·π/4, cos/sin in f64);
//!   - gold vector: `allcloseF32` with the manifest tolerance (the ≈ tier, the
//!     ONLY place numpy.allclose semantics apply).
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rule 13/14). Reject-path diagnostics go to stderr via `std.debug.print`
//! (not the logging facility) so a deliberately-exercised skip/diagnostic path
//! never flips the suite's exit code.

const std = @import("std");
const h = @import("harness.zig");
const pan = @import("pan");

const Sample = pan.Sample;
const Frame = pan.Frame;
const types = pan.types;
const port = pan.port;

const num = pan.numericFor(.f32, .{});
const Pan = pan.spatial.ConstantPowerPan(num);

// ---------------------------------------------------------------------------
// The analytic oracle. Independently re-derives the constant-power gains from
// the spec's law (θ=(p+1)·π/4, L=cos θ, R=sin θ) in f64 working precision — the
// same precision the NumPy oracle uses — so it is a genuine outside reference,
// not a restatement of pan's f32 kernel.
// ---------------------------------------------------------------------------
const OracleGains = struct { l: f64, r: f64 };

fn oracleGains(p: f64) OracleGains {
    const clamped = std.math.clamp(p, -1.0, 1.0);
    const theta = (clamped + 1.0) * (std.math.pi / 4.0);
    return .{ .l = @cos(theta), .r = @sin(theta) };
}

/// One stereo output frame, recovered from the planar buffer (plane 0 = L,
/// plane 1 = R) so the analytic checks read per-channel.
const StereoOut = struct { l: f32, r: f32 };

/// Run the real block once over a one-sample mono input at pan position `p`.
/// The block writes a planar stereo buffer ([L-plane][R-plane]); pull the single
/// frame's two channels back out of the planes.
fn renderOne(p: f32, x: f32) StereoOut {
    var blk = Pan{ .pan = p };
    var in: [1]Sample(f32) = .{.{ .ch = .{x} }};
    var out_buf: [2]f32 = undefined;
    const out = pan.Planar(f32, .stereo).fromBase(&out_buf, 1);
    blk.process(&in, out);
    return .{ .l = out.plane(0)[0], .r = out.plane(1)[0] };
}

// A tolerance that admits the f32-vs-f64 gap of a single cos/sin product. The
// analytic oracle works in f64; pan rounds the gain to f32 and multiplies in
// f32, so ~1 ulp(f32) of slack per product is expected and forgiven. This is
// NOT numpy.allclose — it is a hand-rolled absolute bound for the per-element
// analytic checks (allclose is reserved for the blob comparison below).
const analytic_abs: f32 = 1e-6;

// ===========================================================================
// 1. Structural identity — the block IS a layout-changing Map.
//
// These are independent facts about the type, decided by `port.classify` /
// the canonical port elements, not by any numeric output. They pin the single
// most important property a downstream `connect` relies on: the input port
// carries a MONO sample and the output port carries a STEREO frame — a true
// layout change (the `L` in `Frame(_,L)` differs across the morphism).
// ===========================================================================

test "spatial.ConstantPowerPan classifies as a Map (rate-1:1, stateless morphism)" {
    try std.testing.expect(port.classify(Pan) == .Map);
}

test "input port element is mono Sample(f32); output port element is stereo Frame(f32,.stereo) — a layout change" {
    // Independent structural truth: the input is mono, the output is stereo, so
    // the layout L differs across the morphism. A regression that made the block
    // mono→mono (or stereo→stereo) would still pass every gain check on ch[0];
    // only this assertion distinguishes a panner from a gain.
    try std.testing.expect(port.MapInPort(Pan).Elem == Sample(f32));
    try std.testing.expect(port.MapOutPort(Pan).Elem == Frame(f32, .stereo));

    // And the layouts genuinely differ — the defining property of a layout change.
    try std.testing.expect(Sample(f32) != Frame(f32, .stereo));
    try std.testing.expectEqual(@as(usize, 1), types.Sample(f32).channel_count);
    try std.testing.expectEqual(@as(usize, 2), Frame(f32, .stereo).channel_count);
}

test "the input/output port directions are in/out respectively" {
    try std.testing.expect(port.MapInPort(Pan).direction == .in);
    try std.testing.expect(port.MapOutPort(Pan).direction == .out);
}

test "the block exposes a `pan` control parameter typed Scalar(f32)" {
    // The control-rate `pan` is the block's only knob; the param port must carry
    // a Scalar(f32) so a future wired `param.pan` type-checks at connect.
    try std.testing.expect(port.ParamPort(Pan, "pan").Elem == types.Scalar(f32));
}

// ===========================================================================
// 2. The storage-layout fact the gold comparison leans on (PLANAR).
//
// pan's internal stereo buffer is PLANE-MAJOR: an L-plane of N samples followed
// by an R-plane of N samples (NOT interleaved L0,R0,L1,R1,…). The plane-major
// gold blob is `[L-plane][R-plane]` to match, so the test can read it straight
// into pan's planar buffer with no transpose. This is an independent structural
// fact (the planar view's plane offsets) and the bridge that makes the blob
// comparison a flat per-plane allclose. Pin it explicitly: were the buffer to
// regress to interleaved AoS, plane(1) would no longer start N lanes in.
// ===========================================================================

test "stereo buffer is plane-major: plane 1 starts N lanes after plane 0 (catalog §9.3)" {
    const N = 2;
    // Plane-major backing [L0,L1][R0,R1].
    var backing: [2 * N]f32 = .{ 1, 2, 3, 4 };
    const v = pan.Planar(f32, .stereo).fromBase(&backing, N);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, v.plane(0)); // L-plane
    try std.testing.expectEqualSlices(f32, &.{ 3, 4 }, v.plane(1)); // R-plane
    // plane(1) begins exactly N lanes past plane(0) (the plane-major invariant).
    try std.testing.expectEqual(@intFromPtr(v.plane(0).ptr + N), @intFromPtr(v.plane(1).ptr));
    // The element identity for connect remains the two-lane Frame, no padding.
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(f32)), @sizeOf(Frame(f32, .stereo)));
}

// ===========================================================================
// 3. Constant power — the defining analytic law: L²+R² == 1 for every pan
//    position, independent of input level. This is THE reason the block is a
//    constant-power pan and not a linear one. Swept finely so a law that only
//    happens to hold at the endpoints/center can't slip through.
// ===========================================================================

test "constant power: L²+R² == 1 across the full pan sweep (unit input)" {
    var p: f32 = -1.0;
    while (p <= 1.0001) : (p += 0.05) {
        const o = renderOne(p, 1.0);
        const power = @as(f64, o.l) * o.l + @as(f64, o.r) * o.r;
        // Oracle: the constant-power law asserts unit power for EVERY position.
        std.testing.expectApproxEqAbs(@as(f64, 1.0), power, 1e-6) catch |e| {
            std.debug.print("constant-power violated @ pan={d}: L²+R²={d}\n", .{ p, power });
            return e;
        };
    }
}

test "power scales with the square of the input amplitude (L²+R² == x²)" {
    // For input x, output power must be x²·(cos²+sin²) = x². A linear-pan
    // regression (gains 1±p)/2 etc.) breaks this even though it preserves the
    // mono sum, so it is an independent discriminator.
    const amps = [_]f32{ 0.0, 0.25, 0.5, 1.0, 2.0, -0.75 };
    for (amps) |x| {
        const o = renderOne(0.3, x);
        const power = @as(f64, o.l) * o.l + @as(f64, o.r) * o.r;
        try std.testing.expectApproxEqAbs(@as(f64, x) * x, power, 1e-6);
    }
}

// ===========================================================================
// 4. Per-position gain correctness — each channel equals x·cos/x·sin against
//    the f64 analytic oracle. Constant power alone does not pin WHICH gain goes
//    to WHICH channel (a channel swap preserves L²+R²); these checks do.
// ===========================================================================

test "per-channel gains match the analytic cos/sin oracle at representative positions" {
    const positions = [_]f32{ -1.0, -0.6, -0.25, 0.0, 0.25, 0.6, 1.0 };
    const x: f32 = 0.8;
    for (positions) |p| {
        const o = renderOne(p, x);
        const g = oracleGains(p);
        const want_l: f32 = @floatCast(@as(f64, x) * g.l);
        const want_r: f32 = @floatCast(@as(f64, x) * g.r);
        std.testing.expectApproxEqAbs(want_l, o.l, analytic_abs) catch |e| {
            std.debug.print("L gain mismatch @ pan={d}: got {d}, oracle {d}\n", .{ p, o.l, want_l });
            return e;
        };
        std.testing.expectApproxEqAbs(want_r, o.r, analytic_abs) catch |e| {
            std.debug.print("R gain mismatch @ pan={d}: got {d}, oracle {d}\n", .{ p, o.r, want_r });
            return e;
        };
    }
}

test "center (pan=0) sends equal √½·x to both channels" {
    const root_half: f32 = @floatCast(@sqrt(0.5)); // independent: cos(π/4)=sin(π/4)
    const x: f32 = 0.5;
    const o = renderOne(0.0, x);
    try std.testing.expectApproxEqAbs(root_half * x, o.l, analytic_abs);
    try std.testing.expectApproxEqAbs(root_half * x, o.r, analytic_abs);
    // And the two channels are equal at center — the symmetry the law demands.
    try std.testing.expectApproxEqAbs(o.l, o.r, analytic_abs);
}

test "hard-left (pan=-1) puts all signal in L, none in R" {
    const x: f32 = 0.9;
    const o = renderOne(-1.0, x);
    // θ=0 ⇒ cos=1, sin=0: L=x, R=0.
    try std.testing.expectApproxEqAbs(x, o.l, analytic_abs);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), o.r, analytic_abs);
}

test "hard-right (pan=1) puts all signal in R, none in L" {
    const x: f32 = 0.9;
    const o = renderOne(1.0, x);
    // θ=π/2 ⇒ cos=0, sin=1: L=0, R=x.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), o.l, analytic_abs);
    try std.testing.expectApproxEqAbs(x, o.r, analytic_abs);
}

test "the L-gain decreases and the R-gain increases monotonically as pan goes left→right" {
    // The crossfade direction is part of the contract: panning right must move
    // energy from L to R, never the reverse. Independent of the exact curve.
    var prev_l: f32 = std.math.inf(f32);
    var prev_r: f32 = -std.math.inf(f32);
    var p: f32 = -1.0;
    while (p <= 1.0001) : (p += 0.1) {
        const o = renderOne(p, 1.0);
        std.testing.expect(o.l <= prev_l + analytic_abs) catch |e| {
            std.debug.print("L not non-increasing @ pan={d}: {d} > prev {d}\n", .{ p, o.l, prev_l });
            return e;
        };
        std.testing.expect(o.r >= prev_r - analytic_abs) catch |e| {
            std.debug.print("R not non-decreasing @ pan={d}: {d} < prev {d}\n", .{ p, o.r, prev_r });
            return e;
        };
        prev_l = o.l;
        prev_r = o.r;
    }
}

// ===========================================================================
// 5. Edge cases & invariants beyond the happy path.
// ===========================================================================

test "pan is clamped to [-1,1]: out-of-range positions saturate to the hard pans" {
    // The kernel clamps `pan` before computing θ. An independent observable:
    // pan=+5 must be byte-indistinguishable in behavior from pan=+1, and pan=-5
    // from pan=-1. (Compared against the hard-pan analytic truth, not against an
    // unclamped pan run.)
    const x: f32 = 0.7;
    const over_right = renderOne(5.0, x);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), over_right.l, analytic_abs);
    try std.testing.expectApproxEqAbs(x, over_right.r, analytic_abs);

    const over_left = renderOne(-5.0, x);
    try std.testing.expectApproxEqAbs(x, over_left.l, analytic_abs);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), over_left.r, analytic_abs);
}

test "a zero input maps to zero in both channels at every pan position" {
    // x=0 ⇒ 0·gain = 0 regardless of position; a non-zero output here would
    // mean a spurious additive term in the kernel.
    var p: f32 = -1.0;
    while (p <= 1.0001) : (p += 0.25) {
        const o = renderOne(p, 0.0);
        try std.testing.expectEqual(@as(f32, 0.0), o.l);
        try std.testing.expectEqual(@as(f32, 0.0), o.r);
    }
}

test "negative input is preserved through the gains (sign carries to both channels)" {
    // Gains are non-negative over [-1,1] (θ∈[0,π/2]), so a negative sample stays
    // negative in any channel that receives energy.
    const o = renderOne(0.0, -1.0);
    try std.testing.expect(o.l < 0.0);
    try std.testing.expect(o.r < 0.0);
    const root_half: f32 = @floatCast(@sqrt(0.5));
    try std.testing.expectApproxEqAbs(-root_half, o.l, analytic_abs);
    try std.testing.expectApproxEqAbs(-root_half, o.r, analytic_abs);
}

test "process is elementwise: a whole buffer equals per-sample independent renders (stateless)" {
    // The block holds `pan` across the buffer but is otherwise memoryless: frame
    // n of a batch render must equal a fresh one-sample render of x[n]. Pins that
    // there is no inter-sample state leaking (an independent per-sample oracle).
    const n = 64;
    var in: [n]Sample(f32) = undefined;
    h.fillNoise(&in, 99);
    // Plane-major stereo buffer: [L-plane(n)][R-plane(n)].
    var out_buf: [2 * n]f32 = undefined;
    const out = pan.Planar(f32, .stereo).fromBase(&out_buf, n);

    var blk = Pan{ .pan = 0.37 };
    blk.process(&in, out);

    for (in, out.plane(0), out.plane(1)) |s, l, r| {
        const ref = renderOne(0.37, s.ch[0]);
        try std.testing.expectEqual(ref.l, l);
        try std.testing.expectEqual(ref.r, r);
    }
}

test "chunked render equals whole-buffer render (no carry-over between process calls)" {
    // Splitting the input across multiple process() calls must give bit-identical
    // output to a single call — the stateless contract. Pan-vs-pan ⇒ bit-exact.
    const n = 100;
    var in: [n]Sample(f32) = undefined;
    h.fillNoise(&in, 1234);

    var whole_buf: [2 * n]f32 = undefined;
    var blk_whole = Pan{ .pan = -0.4 };
    blk_whole.process(&in, pan.Planar(f32, .stereo).fromBase(&whole_buf, n));

    var chunk_buf: [2 * n]f32 = undefined;
    const chunk_view = pan.Planar(f32, .stereo).fromBase(&chunk_buf, n);
    var blk_chunk = Pan{ .pan = -0.4 };
    var i: usize = 0;
    const chunk = 17;
    while (i < n) {
        const m = @min(chunk, n - i);
        // A sub-block view writes the [i, i+m) slice of each plane. Build the
        // view from the L-plane sub-pointer; its R-plane follows at +m (the
        // sub-buffer is itself plane-major over m frames).
        var sub_buf: [2 * 17]f32 = undefined;
        const sub = pan.Planar(f32, .stereo).fromBase(&sub_buf, m);
        blk_chunk.process(in[i .. i + m], sub);
        @memcpy(chunk_view.plane(0)[i .. i + m], sub.plane(0));
        @memcpy(chunk_view.plane(1)[i .. i + m], sub.plane(1));
        i += m;
    }

    // Pan-vs-pan: exact, never allclose. Compare both planes bit-for-bit.
    try h.bitExact(f32, chunk_view.plane(0), pan.Planar(f32, .stereo).fromBase(&whole_buf, n).plane(0));
    try h.bitExact(f32, chunk_view.plane(1), pan.Planar(f32, .stereo).fromBase(&whole_buf, n).plane(1));
}

// ===========================================================================
// 6. The external gold vector — pan vs the SciPy/NumPy oracle blob.
//
// Reads the GIT-IGNORED, generate-on-demand blobs at RUNTIME and SKIPS
// gracefully if absent (never hard-fails on a missing blob — the harness is
// hermetic without it). When present:
//   - the manifest (committed, embedded) supplies the pan position and tolerance;
//   - input.bin is the mono f32 the oracle was fed (read it, don't regenerate,
//     so pan sees the exact same quantized samples);
//   - expected.bin is the stereo PLANE-MAJOR [L-plane][R-plane] f32 oracle output
//     (pan's internal planar form — the generator emits plane-major for C>1);
//   - pan renders the real block over the mono input into a planar stereo buffer;
//     that buffer's flat f32 view is layout-identical to the plane-major oracle;
//   - compared with numpy.allclose semantics under the manifest tolerance (the
//     ≈ tier — the ONLY place allclose applies; tolerance forgives the oracle's
//     f64 cos/sin, never pan disagreeing with itself).
// ===========================================================================

const pan_manifest_json = @embedFile("vectors/pan_f32.json");

const PanVectorPaths = struct {
    input: []const u8 = "tests/vectors/pan_f32/input.bin",
    expected: []const u8 = "tests/vectors/pan_f32/expected.bin",
};

/// Read a blob from cwd-relative `sub_path`, f32-aligned. Returns `null` on
/// FileNotFound (the generate-on-demand skip), propagates other I/O errors.
fn readBlobOrNull(io: std.Io, gpa: std.mem.Allocator, sub_path: []const u8) !?[]align(4) u8 {
    const dir = std.Io.Dir.cwd();
    return dir.readFileAllocOptions(io, sub_path, gpa, .unlimited, .@"4", null) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

test "GoldVector: ConstantPowerPan ≈ the NumPy/SciPy oracle blob, allclose under the manifest tolerance" {
    const gpa = std.testing.allocator;

    // The manifest is committed, so it always parses (the contract half).
    const parsed = try h.parseManifest(gpa, pan_manifest_json);
    defer parsed.deinit();
    const m = parsed.value;
    try std.testing.expectEqualStrings("ConstantPowerPan", m.block);
    try std.testing.expectEqualStrings("f32", m.format.precision);
    const tol = try m.resolveTolerance();
    try std.testing.expect(tol == .approx); // the float-oracle ≈ tier

    // Pull the pan position out of the manifest's block-specific `params` (the
    // schema parses with ignore_unknown_fields, so `params` isn't modelled in
    // `Manifest` — re-parse the value generically just for `params.pan`).
    const pan_pos: f32 = blk: {
        const dyn = try std.json.parseFromSlice(std.json.Value, gpa, pan_manifest_json, .{});
        defer dyn.deinit();
        const params = dyn.value.object.get("params").?.object;
        break :blk @floatCast(params.get("pan").?.float);
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), pan_pos, 1e-9); // matches the committed manifest

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const paths = PanVectorPaths{};
    const input_bytes = (try readBlobOrNull(io, gpa, paths.input)) orelse {
        std.debug.print(
            "SKIP GoldVector(pan_f32): {s} absent — run `python scripts/generate.py tests/vectors/pan_f32.json` to materialize the blob.\n",
            .{paths.input},
        );
        return error.SkipZigTest;
    };
    defer gpa.free(input_bytes);
    const expected_bytes = (try readBlobOrNull(io, gpa, paths.expected)) orelse {
        std.debug.print(
            "SKIP GoldVector(pan_f32): {s} absent — run `python scripts/generate.py tests/vectors/pan_f32.json` to materialize the blob.\n",
            .{paths.expected},
        );
        return error.SkipZigTest;
    };
    defer gpa.free(expected_bytes);

    // Shape sanity against the manifest: input is mono f32 (n_frames lanes);
    // expected is stereo plane-major (2·n_frames lanes). A shape surprise here is
    // a generator/manifest mismatch, surfaced loud rather than silently sliced.
    const n = m.n_frames;
    try std.testing.expectEqual(n * @sizeOf(f32), input_bytes.len);
    try std.testing.expectEqual(n * 2 * @sizeOf(f32), expected_bytes.len);

    // Feed pan the EXACT mono input the oracle saw (read, don't regenerate).
    const in_scalars: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, input_bytes));
    const in_samples: []const Sample(f32) = @alignCast(std.mem.bytesAsSlice(Sample(f32), input_bytes));
    try std.testing.expectEqual(n, in_scalars.len);

    // pan renders into a PLANE-MAJOR stereo buffer ([L-plane(n)][R-plane(n)]).
    const out_lanes = try gpa.alloc(f32, 2 * n);
    defer gpa.free(out_lanes);
    const out = pan.Planar(f32, .stereo).fromBase(out_lanes.ptr, n);

    var blk = Pan{ .pan = pan_pos };
    blk.process(in_samples, out);

    // The planar buffer's flat f32 view == [L-plane][R-plane], bit-for-bit the
    // same plane-major layout as the oracle's expected.bin.
    const got_flat: []const f32 = out_lanes;
    const expected_flat: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, expected_bytes));

    // The ≈ tier: numpy.allclose against the external float oracle.
    try h.allcloseF32(got_flat, expected_flat, tol);
}
