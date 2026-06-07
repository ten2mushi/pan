//! Resonant fused kernels — the Moog-style ladder filter and the FDN feedback
//! mixing matrix.
//!
//! Both are fused tight-feedback realisations: the recurrence runs per-sample over
//! persistent state inside a single rate-1:1 `Map`, so the feedback is
//! sample-accurate and opaque to the colorer. Each declares its internal feedback
//! `z⁻¹` as a `delay_len` (a delay element the SCC-has-delay check sees) and is NOT
//! `aliasing_safe` (the read-before-write recurrence would corrupt an in-place
//! output). Float-only — a fixed-point realisation needs the same coefficient-
//! scaling care a fixed-point Biquad does, declared loud via `requireFloat`.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;
const numeric = core.numeric;

const fxc = @import("fx_common.zig");
const scalarsConst = fxc.scalarsConst;
const scalars = fxc.scalars;
const requireFloat = fxc.requireFloat;

/// `Ladder(num)` — a Moog-style 4-pole resonant low-pass ladder. Four cascaded
/// one-pole low-pass stages with a single global feedback path whose strength is
/// the resonance; the canonical fused tight-feedback kernel where the loop spans
/// the whole cascade. Authored as ONE rate-1:1 `Map`: the per-sample recurrence
///
///     u      = x[n] − k·s4            // global resonance feedback (z⁻¹ on s4)
///     s1    += g·(u  − s1)            // four cascaded one-pole low-passes
///     s2    += g·(s1 − s2)
///     s3    += g·(s2 − s3)
///     s4    += g·(s3 − s4)
///     y[n]   = s4
///
/// runs internally over the four persistent stage states `s1..s4` (the `z⁻¹` is
/// `s4` fed back into `u`), so the feedback is **sample-accurate**. `cutoff` is the
/// one-pole coefficient `g ∈ (0,1)` (rises with cutoff frequency); `resonance` is
/// `k ∈ [0,4)` (self-oscillates at 4 — kept strictly below for a stable, decaying
/// response). Like the other fused kernels it declares `delay_len` (its internal
/// one-sample feedback `z⁻¹` ⇒ a delay element the SCC-has-delay check sees),
/// carries the four stage words as `state_size`, is **NOT** `aliasing_safe` (the
/// read-before-write recurrence would corrupt an in-place output), and is
/// float-only (a fixed-point ladder needs the same coefficient-scaling care as a
/// fixed-point biquad — the embedded-precision phase).
pub fn Ladder(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// The internal feedback `z⁻¹` (the global resonance tap reads `s4` from the
        /// previous sample) — registers this as a delay element (SCC-has-delay).
        pub const delay_len: usize = 1;
        /// Persistent state: the four cascaded one-pole stage words.
        pub const state_size: usize = @sizeOf(T) * 4;

        /// One-pole coefficient `g ∈ (0,1)` — higher is a higher cutoff frequency.
        cutoff: T = 0.3,
        /// Resonance `k ∈ [0,4)` — feedback amount; approaches self-oscillation at 4.
        resonance: T = 0,
        /// The four one-pole low-pass stage states (the ladder).
        s1: T = 0,
        s2: T = 0,
        s3: T = 0,
        s4: T = 0,

        pub fn process(self: *Self, noalias in: []const types.Sample(T), noalias out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const g = self.cutoff;
            const k = self.resonance;
            var s1 = self.s1;
            var s2 = self.s2;
            var s3 = self.s3;
            var s4 = self.s4;
            for (xs, ys) |x, *y| {
                const u = x - k * s4; // global resonance feedback (z⁻¹ on s4)
                s1 += g * (u - s1); // four cascaded one-pole low-passes
                s2 += g * (s1 - s2);
                s3 += g * (s2 - s3);
                s4 += g * (s3 - s4);
                y.* = s4;
            }
            self.s1 = s1;
            self.s2 = s2;
            self.s3 = s3;
            self.s4 = s4;
        }
    };
}

/// View a planar `Frame(Lane, L)` buffer as the underlying flat `[]Lane` lanes —
/// `C·N` plane-major lanes (channel `c`'s plane is `lanes[c*N .. (c+1)*N]`). The
/// matrix-mix kernel walks samples across the `C` planes, so it indexes lanes by
/// `c*N + n` rather than calling `plane(c)` per access.
fn planarLanesConst(comptime Lane: type, comptime L: types.ChannelLayout, v: types.PlanarConst(Lane, L)) []const Lane {
    return v.base[0 .. L.count() * v.frames];
}
fn planarLanes(comptime Lane: type, comptime L: types.ChannelLayout, v: types.Planar(Lane, L)) []Lane {
    return v.base[0 .. L.count() * v.frames];
}

/// `FdnMatrix(num, N)` — the mixing core of a Feedback Delay Network. It sums the
/// dry input bus with the `N×N` feedback matrix applied to the delayed feedback
/// bus, per sample: for the `N`-channel buses `x` (input) and `w` (delayed
/// feedback),
///
///     out[i][n] = x[i][n] + Σ_j A[i][j]·w[j][n]
///
/// Both buses are `Frame(Lane, .discrete(N))` planar views (channel `j`'s samples
/// are one contiguous plane). The matrix `A` is the FDN's feedback mixing transform;
/// it must be (sub-)unitary for a stable, lossless-then-damped tail — the default
/// is a normalized `N×N` Hadamard scaled by `decay < 1` (orthogonal ⇒ energy-
/// preserving, scaled ⇒ decaying), defined for `N` a power of two. Wire `N`
/// `(Planar)DelayLine` lengths between this block's output and its feedback input
/// (one feedback edge carrying the whole `discrete(N)` bus, or `N` scalar edges) and
/// the SCC contains the delay lines ⇒ the loop is causal (`error.DelayFreeLoop`
/// passes). Rate-1:1, stateless across calls (the delay state lives in the delay
/// nodes) ⇒ a `Map`; the matrix multiply reads each input fully before writing the
/// distinct output, but it is not declared `aliasing_safe` (two sample inputs, and
/// the per-sample cross-channel read pattern is not a unary in-place map).
pub fn FdnMatrix(comptime num: numeric.Numeric, comptime N: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (N == 0 or (N & (N - 1)) != 0)
        @compileError("pan: FdnMatrix order N must be a power of two (the default Hadamard mixing matrix needs it)");
    const L: types.ChannelLayout = .{ .discrete = N };
    return struct {
        const Self = @This();

        /// The `N×N` feedback mixing matrix in row-major order (`A[i][j] =
        /// matrix[i*N + j]`). Defaults to a normalized Hadamard scaled by `decay`
        /// (orthogonal × gain ⇒ a stable, decaying, well-diffused FDN).
        matrix: [N * N]T = defaultHadamard(),
        /// The scalar applied to the orthogonal Hadamard for the default matrix —
        /// the per-trip energy gain (`< 1` ⇒ a decaying tail). Carried for clarity;
        /// changing it after construction requires rebuilding `matrix`.
        decay: T = 0.85,

        /// A normalized `N×N` Hadamard (`H_N / √N` is orthogonal) scaled by `0.85`,
        /// built at comptime via the Sylvester recursion `H_2N = [[H,H],[H,−H]]`.
        fn defaultHadamard() [N * N]T {
            @setEvalBranchQuota(N * N * 8 + 1000);
            var h: [N * N]T = undefined;
            // Sylvester sign pattern: H[i][j] = (−1)^popcount(i & j).
            const norm: T = 1.0 / @sqrt(@as(T, @floatFromInt(N)));
            const gain: T = 0.85 * norm;
            for (0..N) |i| {
                for (0..N) |j| {
                    const bits = @popCount(i & j);
                    h[i * N + j] = if (bits & 1 == 0) gain else -gain;
                }
            }
            return h;
        }

        pub fn process(
            self: *Self,
            input: types.PlanarConst(T, L),
            feedback: types.PlanarConst(T, L),
            out: types.Planar(T, L),
        ) void {
            const frames = out.frames;
            const xs = planarLanesConst(T, L, input);
            const ws = planarLanesConst(T, L, feedback);
            const ys = planarLanes(T, L, out);
            const A = &self.matrix;
            // out[i][n] = x[i][n] + Σ_j A[i][j]·w[j][n], plane-major (i*frames + n).
            var n: usize = 0;
            while (n < frames) : (n += 1) {
                inline for (0..N) |i| {
                    var acc: T = xs[i * frames + n];
                    inline for (0..N) |j| {
                        acc += A[i * N + j] * ws[j * frames + n];
                    }
                    ys[i * frames + n] = acc;
                }
            }
        }
    };
}

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

fn S(x: f32) types.Sample(f32) {
    return .{ .ch = .{x} };
}

test "Ladder is a 4-pole low-pass: settles toward the DC input, bounded, stateful" {
    var lad = Ladder(f32num){ .cutoff = 0.3, .resonance = 0 };
    // A unit DC step: a stable low-pass settles toward the input level (1.0).
    var in: [256]types.Sample(f32) = @splat(S(1));
    var out: [256]types.Sample(f32) = undefined;
    lad.process(&in, &out);
    // The four cascaded one-poles ramp up monotonically toward 1 (no resonance).
    try testing.expect(out[0].ch[0] < out[255].ch[0]);
    try testing.expect(out[255].ch[0] > 0.9 and out[255].ch[0] <= 1.0);
    // State carries: continuing the DC input stays near the settled value.
    var out2: [16]types.Sample(f32) = undefined;
    lad.process(in[0..16], &out2);
    try testing.expect(out2[0].ch[0] > 0.9);
}

test "Ladder classifies as a delay-element Map and is not aliasing_safe" {
    const port = core.port;
    try testing.expect(port.classify(Ladder(f32num)) == .Map);
    try testing.expect(@hasDecl(Ladder(f32num), "delay_len"));
    try testing.expect(!@hasDecl(Ladder(f32num), "aliasing_safe"));
}

test "Ladder resonance raises the feedback: a resonant burst rings on" {
    var lad = Ladder(f32num){ .cutoff = 0.2, .resonance = 3.5 };
    var in: [8]types.Sample(f32) = @splat(S(0));
    in[0] = S(1); // impulse
    var out: [8]types.Sample(f32) = undefined;
    lad.process(&in, &out);
    // High resonance keeps energy circulating: the loop is still moving after the
    // impulse (a non-trivial, bounded response).
    var in2: [64]types.Sample(f32) = @splat(S(0));
    var out2: [64]types.Sample(f32) = undefined;
    lad.process(&in2, &out2);
    var peak: f32 = 0;
    for (out2) |s| peak = @max(peak, @abs(s.ch[0]));
    try testing.expect(peak > 0.0 and peak < 10.0); // ringing but bounded (k<4)
}

test "FdnMatrix mixes the N-channel feedback bus and adds the input (orthogonal default)" {
    const Fdn = FdnMatrix(f32num, 4);
    var m = Fdn{};
    // One frame, N=4 planar buses. Input = e0 (impulse in channel 0), feedback = 0.
    var in_buf: [4]f32 = .{ 1, 0, 0, 0 };
    var fb_buf: [4]f32 = .{ 0, 0, 0, 0 };
    var out_buf: [4]f32 = undefined;
    const L: types.ChannelLayout = .{ .discrete = 4 };
    const in = types.PlanarConst(f32, L).fromBase(&in_buf, 1);
    const fb = types.PlanarConst(f32, L).fromBase(&fb_buf, 1);
    const out = types.Planar(f32, L).fromBase(&out_buf, 1);
    m.process(in, fb, out);
    // With zero feedback the output is just the input bus.
    try testing.expectEqual(@as(f32, 1), out.plane(0)[0]);
    try testing.expectEqual(@as(f32, 0), out.plane(1)[0]);

    // Now drive the feedback bus with an impulse and zero input: the row of the
    // (orthogonal) Hadamard spreads it across all channels, energy-preserving.
    var fb2: [4]f32 = .{ 1, 0, 0, 0 };
    var in2: [4]f32 = .{ 0, 0, 0, 0 };
    var out2: [4]f32 = undefined;
    m.process(types.PlanarConst(f32, L).fromBase(&in2, 1), types.PlanarConst(f32, L).fromBase(&fb2, 1), types.Planar(f32, L).fromBase(&out2, 1));
    var energy: f32 = 0;
    for (0..4) |c| {
        const v = types.Planar(f32, L).fromBase(&out2, 1).plane(c)[0];
        energy += v * v;
    }
    // ‖A·e0‖² = decay² (Hadamard/√N is orthonormal, scaled by 0.85).
    try testing.expectApproxEqAbs(@as(f32, 0.85 * 0.85), energy, 1e-5);
}

test "FdnMatrix classifies as a Map and is not aliasing_safe" {
    const port = core.port;
    try testing.expect(port.classify(FdnMatrix(f32num, 4)) == .Map);
    try testing.expect(!@hasDecl(FdnMatrix(f32num, 4), "aliasing_safe"));
    // Its bus element identity is the N-channel discrete Frame.
    try testing.expect(port.MapOutPort(FdnMatrix(f32num, 4)).Elem == types.Frame(f32, .{ .discrete = 4 }));
}
