//! Fused tight-feedback kernels — the blessed idiom for sample-accurate feedback.
//!
//! Where a graph-level `DelayLine`-in-a-cycle (one-block feedback latency) is too
//! coarse — ladder filters, Karplus-Strong strings, feedback combs — the tight
//! loop is authored as a **single rate-1:1 `Map` block whose `process` runs the
//! per-sample feedback loop internally** over fixed persistent state. The `z⁻¹`
//! lives *inside* the kernel, per sample, so the feedback is **sample-accurate**
//! (not quantized to the colorer's block granularity).
//!
//! The trade is explicit: you **forfeit scheduler visibility** — the loop is
//! opaque to the colorer, which cannot fuse or split across it — **in exchange for
//! sample-accuracy**. Two consequences follow, and both are encoded here:
//!
//!   * Each kernel declares `delay_len` (its internal ring length), so it
//!     registers as a **delay element**: a feedback cycle built from it passes the
//!     SCC-has-delay check, and a self-loop is causal because the per-sample state
//!     supplies the `z⁻¹`. (Most uses need NO graph feedback edge at all — the loop
//!     is wholly internal.)
//!   * They are **NOT `aliasing_safe`**: the state-dependent read-before-write
//!     ordering means an in-place output would corrupt the recurrence. Omitting the
//!     declaration keeps the colorer from ever aliasing their output onto an input.
//!
//! Persistent state (the ring + cursors + coefficients) lives in the block
//! instance, allocated once at construction — the pool-excluded category, counted
//! by the footprint but never colored. **Denormal guard:** a decaying feedback
//! tail drives the state toward subnormal magnitudes; the realtime token's
//! flush-to-zero (set on the audio thread by `enterRealtimeThread`) collapses
//! those to zero so the tail does not provoke the ~100× per-op denormal CPU
//! stall — these kernels are exactly the paths that rule protects.
//!
//! Fixed-point feedback (limit cycles, coefficient scaling, accumulator headroom)
//! needs the same care a fixed-point `Biquad` does — which is now applied THERE
//! (the DF1 wider-coefficient-format + wide-accumulator + saturate technique in
//! `filters.zig`). These feedback kernels each have their own coefficient structure
//! and have not yet had that technique applied, so the integer path still fails
//! loud (a compile error, never silently-wrong audio); they ship float-only for now
//! and are not part of the embedded fixed-point chain (gain → biquad → sink).
//!
//! **`noalias` placement (▷ authoring convention).** Each kernel's `process` reads
//! its whole input plane and writes a distinct output plane; because none of these
//! blocks declares `aliasing_safe`, the colorer never coalesces output onto input,
//! so the in/out pool buffers are PROVABLY distinct (a non-coalesced `Map`'s
//! producer and last-reader intervals overlap end-inclusively → different colors).
//! The `noalias` qualifiers on the slice parameters therefore state a fact the
//! commit pass already guarantees, freeing the optimizer from the must-assume-
//! overlap restriction. `noalias` is the EXACT opposite of `aliasing_safe`: a block
//! may have one or the other, never both — an `aliasing_safe` block deliberately
//! aliases in/out and so must not carry `noalias`. pan cannot inject `noalias` into
//! an author's signature, so it is an authoring convention applied here where the
//! non-aliasing is structural (these fused kernels) rather than enforced. (`noalias`
//! is a *pointer*-parameter qualifier, so it rides the `[]const Sample(T)` slice
//! ports; a planar-view port like `FdnMatrix`'s is a struct value, not a pointer,
//! so the qualifier does not apply there — its planes are still distinct buffers.)

const std = @import("std");
const types = @import("types.zig");
const numeric = @import("numeric.zig");
const control = @import("control.zig");

fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

/// View a mono `Sample(T)` slice as its underlying scalar `[]T` — `Sample(T)` is
/// `Frame(T,.mono)`, layout-identical to a bare `T`, so the reinterpret is exact.
fn scalarsConst(comptime T: type, frames: []const types.Sample(T)) []const T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}
fn scalars(comptime T: type, frames: []types.Sample(T)) []T {
    return @alignCast(std.mem.bytesAsSlice(T, std.mem.sliceAsBytes(frames)));
}

fn requireFloat(comptime T: type) void {
    if (!isFloat(T))
        @compileError("pan: fixed-point feedback kernels are not yet supported — limit" ++
            " cycles + coefficient scaling need the per-kernel DF1/wide-accumulator" ++
            " treatment now applied to the fixed-point Biquad (filters.zig); it has" ++
            " not yet been ported to these reverb/synthesis kernels. Use f32/f64.");
}

/// `Comb(num, max_delay)` — a feedback comb filter: `y[n] = x[n] + g·y[n−D]`,
/// `D ≤ max_delay`. For `|g| < 1` the impulse response is a decaying train of
/// echoes spaced `D` samples apart — the elementary unit of Schroeder
/// reverberation. The recurrence is per-sample, so the feedback is sample-accurate
/// and the whole loop is one `Map` (no graph feedback edge needed).
pub fn Comb(comptime num: numeric.Numeric, comptime max_delay: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (max_delay == 0) @compileError("pan: Comb max_delay must be >= 1");
    return struct {
        const Self = @This();

        /// Internal ring length — registers this as a delay element (SCC-has-delay).
        pub const delay_len: usize = max_delay;
        pub const state_size: usize = @sizeOf(usize) * 2 + @sizeOf(T);

        ring: [max_delay]T = @splat(0),
        /// Active delay in samples (`1 ≤ delay ≤ max_delay`).
        delay: usize = max_delay,
        /// Feedback gain `g` (set `|g| < 1` for a stable, decaying tail).
        feedback: T = 0,
        pos: usize = 0,

        pub fn process(self: *Self, noalias in: []const types.Sample(T), noalias out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const g = self.feedback;
            const d = self.delay;
            var p = self.pos;
            for (xs, ys) |x, *y| {
                const delayed = self.ring[p]; // y[n-D]
                const yv = x + g * delayed; // feedback comb recurrence
                self.ring[p] = yv;
                p += 1;
                if (p >= d) p = 0;
                y.* = yv;
            }
            self.pos = p;
        }
    };
}

/// `Allpass(num, max_delay)` — a Schroeder all-pass section: flat magnitude
/// response, frequency-dependent phase delay. Paired after a bank of `Comb`s it
/// turns their periodic echo train into the dense, colourless decay of a
/// reverberator. Standard form:
///
///     v        = ring[p]                 // x[n-D] + g·v[n-D] stored last time
///     y[n]     = −g·x[n] + v
///     ring[p]  = x[n] + g·y[n]
pub fn Allpass(comptime num: numeric.Numeric, comptime max_delay: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (max_delay == 0) @compileError("pan: Allpass max_delay must be >= 1");
    return struct {
        const Self = @This();

        pub const delay_len: usize = max_delay;
        pub const state_size: usize = @sizeOf(usize) * 2 + @sizeOf(T);

        ring: [max_delay]T = @splat(0),
        delay: usize = max_delay,
        /// All-pass coefficient `g` (`|g| < 1`; 0.5–0.7 are typical reverb values).
        feedback: T = 0.5,
        pos: usize = 0,

        pub fn process(self: *Self, noalias in: []const types.Sample(T), noalias out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const g = self.feedback;
            const d = self.delay;
            var p = self.pos;
            for (xs, ys) |x, *y| {
                const v = self.ring[p];
                const yv = -g * x + v;
                self.ring[p] = x + g * yv;
                p += 1;
                if (p >= d) p = 0;
                y.* = yv;
            }
            self.pos = p;
        }
    };
}

/// `KarplusStrong(num, max_delay)` — the plucked-string algorithm: a delay line of
/// `D` samples with a two-tap averaging low-pass in the feedback path,
/// `y[n] = x[n] + 0.5·damping·(y[n−D] + y[n−D−1])`. An impulse / noise burst at
/// the input excites a decaying, gently-darkening harmonic tone at `Fs/D` Hz — the
/// archetypal fused tight-feedback kernel.
pub fn KarplusStrong(comptime num: numeric.Numeric, comptime max_delay: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (max_delay < 2) @compileError("pan: KarplusStrong max_delay must be >= 2 (two-tap lowpass)");
    return struct {
        const Self = @This();

        pub const delay_len: usize = max_delay;
        pub const state_size: usize = @sizeOf(usize) * 2 + @sizeOf(T) * 2;

        ring: [max_delay]T = @splat(0),
        delay: usize = max_delay,
        /// Loop decay (`≤ 1`): 1.0 rings nearly forever, lower darkens/shortens.
        damping: T = 0.996,
        pos: usize = 0,
        /// The previous loop output, for the two-tap averaging low-pass.
        prev: T = 0,

        pub fn process(self: *Self, noalias in: []const types.Sample(T), noalias out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const d = self.delay;
            const k = self.damping;
            var p = self.pos;
            var prev = self.prev;
            for (xs, ys) |x, *y| {
                const tap = self.ring[p]; // y[n-D]
                const filtered = 0.5 * k * (tap + prev); // averaging lowpass in the loop
                const yv = x + filtered;
                self.ring[p] = yv;
                prev = tap;
                p += 1;
                if (p >= d) p = 0;
                y.* = yv;
            }
            self.pos = p;
            self.prev = prev;
        }
    };
}

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

// ---------------------------------------------------------------------------
// Tests — compile-coverage + a couple of invariants; the autonomous Yoneda suite
// owns the full matrix (impulse-response decay vs an oracle, SCC acceptance,
// FTZ/denormal behaviour, sample-accuracy of the internal z⁻¹).
// ---------------------------------------------------------------------------

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

fn S(x: f32) types.Sample(f32) {
    return .{ .ch = .{x} };
}

test "Comb impulse response is a decaying echo train spaced D apart" {
    var comb = Comb(f32num, 4){ .delay = 3, .feedback = 0.5 };
    var in: [10]types.Sample(f32) = @splat(S(0));
    in[0] = S(1); // unit impulse
    var out: [10]types.Sample(f32) = undefined;
    comb.process(&in, &out);
    // y[n] = x[n] + 0.5 y[n-3]: echoes at 0,3,6,9 with gains 1, .5, .25, .125.
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[3].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[6].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.125), out[9].ch[0], 1e-6);
    // Off-echo samples are silent.
    try testing.expectEqual(@as(f32, 0), out[1].ch[0]);
    try testing.expectEqual(@as(f32, 0), out[5].ch[0]);
}

test "Comb tail decays (stable for |g|<1) and carries state across calls" {
    var comb = Comb(f32num, 8){ .delay = 5, .feedback = 0.7 };
    var in: [5]types.Sample(f32) = @splat(S(0));
    in[0] = S(1);
    var out: [5]types.Sample(f32) = undefined;
    comb.process(&in, &out);
    // The first echo has not yet recirculated; energy is still in the ring.
    var in2: [10]types.Sample(f32) = @splat(S(0));
    var out2: [10]types.Sample(f32) = undefined;
    comb.process(&in2, &out2);
    // The delayed impulse emerges on the next call (state carried) and is < 1.
    var peak: f32 = 0;
    for (out2) |s| peak = @max(peak, @abs(s.ch[0]));
    try testing.expect(peak > 0 and peak < 1.0);
}

test "Allpass passes a delayed/dispersed signal; energy is bounded" {
    var ap = Allpass(f32num, 4){ .delay = 2, .feedback = 0.5 };
    var in: [8]types.Sample(f32) = @splat(S(0));
    in[0] = S(1);
    var out: [8]types.Sample(f32) = undefined;
    ap.process(&in, &out);
    // Immediate output is -g·x = -0.5 (the through path), then the recirculation.
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[0].ch[0], 1e-6);
    var energy: f32 = 0;
    for (out) |s| energy += s.ch[0] * s.ch[0];
    try testing.expect(energy > 0 and energy < 4.0);
}

test "fused kernels classify as delay elements and are not aliasing_safe" {
    const port = @import("port.zig");
    try testing.expect(port.classify(Comb(f32num, 64)) == .Map);
    try testing.expect(@hasDecl(Comb(f32num, 64), "delay_len"));
    try testing.expect(!@hasDecl(Comb(f32num, 64), "aliasing_safe"));
    try testing.expect(@hasDecl(KarplusStrong(f32num, 64), "delay_len"));
    try testing.expect(!@hasDecl(Allpass(f32num, 64), "aliasing_safe"));
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
    const port = @import("port.zig");
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
    const port = @import("port.zig");
    try testing.expect(port.classify(FdnMatrix(f32num, 4)) == .Map);
    try testing.expect(!@hasDecl(FdnMatrix(f32num, 4), "aliasing_safe"));
    // Its bus element identity is the N-channel discrete Frame.
    try testing.expect(port.MapOutPort(FdnMatrix(f32num, 4)).Elem == types.Frame(f32, .{ .discrete = 4 }));
}

test "KarplusStrong sustains a noise burst into a decaying tone" {
    var ks = KarplusStrong(f32num, 16){ .delay = 8, .damping = 0.99 };
    var in: [8]types.Sample(f32) = undefined;
    for (&in, 0..) |*s, i| s.* = S(if (i % 2 == 0) @as(f32, 0.5) else -0.5); // excitation
    var out: [8]types.Sample(f32) = undefined;
    ks.process(&in, &out);
    // After the excitation, the loop keeps ringing (non-silent) on a zero input.
    var in2: [32]types.Sample(f32) = @splat(S(0));
    var out2: [32]types.Sample(f32) = undefined;
    ks.process(&in2, &out2);
    var late: f32 = 0;
    for (out2) |s| late = @max(late, @abs(s.ch[0]));
    try testing.expect(late > 0.01); // still sounding, not dead silence
}

// ===========================================================================
// Modulation appliers & adaptive dynamics (parameter-port consumers/producers)
// ===========================================================================
//
// These are the *applied* side of the modulation taxonomy (the *generators* — Lfo /
// Adsr / FeatureMap — live in `gen.zig` / `env.zig`). They consume control (`Vca`)
// or both consume audio and produce control (`AgcController`, `PowerGate`), and one
// (`Agc`) is the fused controller-plus-applier. All are float-only (a gain ramp /
// level estimate is f32), declared loud via `requireFloat`, mirroring the feedback
// kernels above. The control element is always `Scalar(f32)`; see `gen.zig`'s header
// for the one-value-per-call / broadcast-storage convention a control producer
// follows so the executor's per-lane NaN/Inf poison guard stays satisfied.

/// Block mean-square (average power) of a mono `Sample(T)` slice. `eps`-floored by
/// the caller where it divides.
fn blockPower(comptime T: type, xs: []const T) T {
    if (xs.len == 0) return 0;
    var acc: T = 0;
    for (xs) |x| acc += x * x;
    return acc / @as(T, @floatFromInt(xs.len));
}

/// `Vca(num)` — a voltage-controlled amplifier: a gain whose coefficient is a
/// **parameter port** (`vca.param.gain`), driven by `set`/`schedule` **or** a wired
/// modulation edge (an `Lfo`, an `Adsr`, an `AgcController`, a `PowerGate` — by the
/// one-source rule, a wired edge XOR an external set, never both). It holds the
/// latest target and **per-block ramps** toward it (the anti-zipper `control.Ramp`),
/// exactly as a `set` on a plain gain would. Because a wired parameter edge and an
/// external `set` both arrive through `setParam` and drive the *same* `Param`/`Ramp`,
/// an `Lfo → vca.param.gain` sweep is **bit-identical** to the same target sequence
/// pushed via `engine.set`. It is the canonical modulation *consumer* and the
/// multiply target for data-gating (a `PowerGate`'s `{0,1}` gate ramped to a
/// click-free fade).
pub fn Vca(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// The gain parameter port (control element `Scalar(f32)`). Slot 0.
        pub const params = .{ .gain = types.Scalar(f32) };

        /// Latest published target (atomic; set by the control thread OR by the
        /// wired-edge `applyParamInputs`). Read once per block on the RT thread.
        target: control.Param = control.Param.init(1.0),
        /// The live, audibly-rendered gain, ramped across blocks (persistent state).
        ramp: control.Ramp = control.Ramp.init(1.0),

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.target.set(value);
        }

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const tgt = self.target.read();
            const inc = self.ramp.begin(tgt, xs.len);
            for (xs, ys, 0..) |x, *y, i| {
                const g: T = @floatCast(self.ramp.value + @as(f32, @floatFromInt(i + 1)) * inc);
                y.* = x * g;
            }
            self.ramp.finish(tgt); // snap to the exact target; next block ramps from it
        }
    };
}

/// `Agc(num)` — **fused** automatic gain control: one block that estimates the
/// block level, drives a smoothed gain toward `target / level`, and applies it,
/// per-sample-ramped, to the audio in a single `process`. This is the **fused**
/// realisation of an adaptive processor (controller + applied filter in one block) —
/// the alternative to the *decoupled* realisation where the coefficient is a
/// parameter port driven by a separate controller node (`AgcController` below);
/// fusing is preferred when the coefficient is private. `rate ∈ (0, 1]` is the
/// per-block one-pole adaptation
/// speed; `max_gain` bounds make-up gain so silence does not explode to infinity.
pub fn Agc(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// Desired output RMS (linear). The control-rate set-point.
        target: f32 = 0.25,
        /// One-pole adaptation coefficient per block (0 = frozen, 1 = instant).
        rate: f32 = 0.1,
        /// Upper bound on the make-up gain.
        max_gain: f32 = 8.0,
        /// The smoothed gain, ramped across blocks (persistent).
        ramp: control.Ramp = control.Ramp.init(1.0),

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const rms: f32 = @floatCast(@sqrt(blockPower(T, xs)));
            const desired = @min(self.target / @max(rms, 1e-9), self.max_gain);
            // One-pole toward the desired gain, then per-sample ramp to it.
            const smoothed = self.ramp.value + self.rate * (desired - self.ramp.value);
            const inc = self.ramp.begin(smoothed, xs.len);
            for (xs, ys, 0..) |x, *y, i| {
                const g: T = @floatCast(self.ramp.value + @as(f32, @floatFromInt(i + 1)) * inc);
                y.* = x * g;
            }
            self.ramp.finish(smoothed);
        }
    };
}

/// `AgcController(num)` — the **decoupled** twin of `Agc`: it reads the audio and
/// *emits the make-up gain as a `Scalar(f32)`* (one value per call, broadcast) to
/// drive a separate `Vca`'s `param.gain`. The decoupling makes the adaptive
/// coefficient a first-class graph value — the same controller can drive several
/// `Vca`s, or be inspected/recorded, without re-measuring. The
/// per-block one-pole smoothing lives here; the per-sample anti-zipper ramp lives in
/// the `Vca` it feeds, so the pair is zipper-free end to end.
pub fn AgcController(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        target: f32 = 0.25,
        rate: f32 = 0.1,
        max_gain: f32 = 8.0,
        /// The smoothed make-up gain (persistent across calls).
        gain: f32 = 1.0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Scalar(f32)) void {
            const xs = scalarsConst(T, in);
            const rms: f32 = @floatCast(@sqrt(blockPower(T, xs)));
            const desired = @min(self.target / @max(rms, 1e-9), self.max_gain);
            self.gain += self.rate * (desired - self.gain);
            for (out) |*o| o.value = self.gain; // one control value, broadcast
        }
    };
}

/// `PowerGate(num)` — a **data-gating** noise/VAD gate: it estimates the block power
/// and emits a `Scalar(f32)` gate in `{0, 1}` (with hysteresis) that a downstream
/// `Vca` multiplies in. Gating is expressed as DATA, not control flow — the render
/// op-list stays static and unconditional (every op runs every callback); only the
/// gate's *value* changes, and the `Vca`'s ramp turns the `0↔1` step into a
/// click-free fade. This is the deliberate, only form of gating pan offers:
/// conditional/"skip these ops when silent" execution is out of scope, because a
/// static, unconditional op-list is what keeps the hot path deterministic and
/// analyzable. Hysteresis (`open_threshold > close_threshold`) prevents chatter
/// around the threshold.
pub fn PowerGate(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        /// Power to OPEN the gate, and (lower) power to CLOSE it — hysteresis.
        open_threshold: f32 = 1e-3,
        close_threshold: f32 = 1e-4,
        /// Whether the gate is currently open (persistent across calls).
        open: bool = false,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Scalar(f32)) void {
            const xs = scalarsConst(T, in);
            const power: f32 = @floatCast(blockPower(T, xs));
            if (self.open) {
                if (power < self.close_threshold) self.open = false;
            } else {
                if (power > self.open_threshold) self.open = true;
            }
            const g: f32 = if (self.open) 1.0 else 0.0;
            for (out) |*o| o.value = g; // one gate value, broadcast
        }
    };
}

test "Vca: classifies as a Map with a gain param; ramps toward a set target" {
    const port = @import("port.zig");
    const V = Vca(f32num);
    try testing.expect(port.classify(V) == .Map);
    try testing.expect(port.ParamPort(V, "gain").Elem == types.Scalar(f32));

    var v: V = .{};
    v.setParam(0, 0.0); // glide gain 1 → 0
    var in: [4]types.Sample(f32) = @splat(S(1));
    var out: [4]types.Sample(f32) = undefined;
    v.process(&in, &out);
    // Linear glide: g_i = 1 + (i+1)·(0-1)/4 = {0.75, 0.5, 0.25, 0.0}.
    try testing.expectApproxEqAbs(@as(f32, 0.75), out[0].ch[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[3].ch[0], 1e-6);
    try testing.expectEqual(@as(f32, 0.0), v.ramp.value); // snapped to target
}

test "Agc: silence stays silent; a hot block is pulled toward the target" {
    var agc: Agc(f32num) = .{ .target = 0.25, .rate = 1.0, .max_gain = 8.0 };
    // A loud block (rms 1.0) with instant adaptation → gain heads toward 0.25.
    var in: [64]types.Sample(f32) = @splat(S(1));
    var out: [64]types.Sample(f32) = undefined;
    agc.process(&in, &out);
    // After a full one-pole step (rate=1) the smoothed gain is the desired 0.25.
    try testing.expectApproxEqAbs(@as(f32, 0.25), agc.ramp.value, 1e-6);
    // Silence: desired gain clamps to max_gain, but x=0 → output stays 0 (no blow-up).
    var sil: [64]types.Sample(f32) = @splat(S(0));
    var sout: [64]types.Sample(f32) = undefined;
    agc.process(&sil, &sout);
    for (sout) |s| try testing.expectEqual(@as(f32, 0), s.ch[0]);
}

test "AgcController: emits a make-up gain Scalar, broadcast across the buffer" {
    const port = @import("port.zig");
    const C = AgcController(f32num);
    try testing.expect(port.classify(C) == .Map);
    try testing.expect(port.MapOutPort(C).Elem == types.Scalar(f32));
    try testing.expect(!comptime port.isSource(C)); // it reads audio

    var c: C = .{ .target = 0.5, .rate = 1.0 };
    var in: [16]types.Sample(f32) = @splat(S(0.25)); // rms 0.25 → desired 2.0
    var out: [16]types.Scalar(f32) = undefined;
    c.process(&in, &out);
    for (out) |o| try testing.expectApproxEqAbs(@as(f32, 2.0), o.value, 1e-6);
}

test "PowerGate: hysteresis — opens above open_threshold, holds, closes below close" {
    var gate: PowerGate(f32num) = .{ .open_threshold = 0.1, .close_threshold = 0.01 };
    var out: [8]types.Scalar(f32) = undefined;

    // Quiet (power 0.0025) → stays closed.
    var quiet: [8]types.Sample(f32) = @splat(S(0.05));
    gate.process(&quiet, &out);
    try testing.expectEqual(@as(f32, 0), out[0].value);

    // Loud (power 0.25 > open) → opens.
    var loud: [8]types.Sample(f32) = @splat(S(0.5));
    gate.process(&loud, &out);
    try testing.expectEqual(@as(f32, 1), out[0].value);

    // Mid (power 0.04, BETWEEN close 0.01 and open 0.1) → hysteresis HOLDS open
    // (a fresh, closed gate at this level would NOT open — the hold is the point).
    var mid: [8]types.Sample(f32) = @splat(S(0.2));
    gate.process(&mid, &out);
    try testing.expectEqual(@as(f32, 1), out[0].value);

    // Quiet again (power 0.0025 < close 0.01) → closes.
    gate.process(&quiet, &out);
    try testing.expectEqual(@as(f32, 0), out[0].value);
}

// ===========================================================================
// Adaptive dynamics & adaptive-filter processors (the rest of the §-named class)
// ===========================================================================
//
// `Compressor`/`CompressorController` are the dynamics processor in both the fused
// and decoupled realisations (the gain is private to one block, vs exposed as a
// `Scalar` parameter a separate `Vca` applies). `Aec` and `HowlSuppressor` are
// adaptive-FIR processors (normalized least-mean-squares): an echo canceller and a
// leaky feedback/howl canceller. For an adaptive FIR the "coefficient" is a whole
// tap vector, so its decoupled (vector-parameter) realisation is heavier than the
// scalar case `Agc`/`Compressor` already demonstrate; these ship in the canonical
// fused form (the controller and the applied filter inside one block). All float-only.

/// The feed-forward compressor gain for an envelope level `env` (linear amplitude):
/// unity at or below `threshold`, and `(env/threshold)^(1/ratio − 1)` above it —
/// i.e. the amount by which the level exceeds the threshold is divided by `ratio` in
/// the logarithmic domain. `ratio → 1` is no compression; a large `ratio` approaches
/// a hard limiter. Returns ≤ 1 (a gain reduction) for `env > threshold`.
fn compressorGain(env: f32, threshold: f32, ratio: f32) f32 {
    if (env <= threshold or threshold <= 0 or ratio <= 0) return 1.0;
    return std.math.pow(f32, env / threshold, 1.0 / ratio - 1.0);
}

/// Advance a one-pole envelope follower one sample toward `|x|`: rise at `attack`,
/// fall at `release` (both per-sample one-pole coefficients in (0, 1] — higher is
/// faster; the author maps a time constant to them). The asymmetry is what gives a
/// compressor its fast-attack / slow-release character.
fn followEnvelope(env: f32, x: f32, attack: f32, release: f32) f32 {
    const rect = @abs(x);
    const c = if (rect > env) attack else release;
    return env + c * (rect - env);
}

/// `Compressor(num)` — a **fused** feed-forward dynamics compressor: a per-sample
/// envelope follower drives a static gain curve and the gain is applied in the same
/// block (controller + applied gain in one block). The envelope smoothing IS the
/// anti-zipper mechanism, so no separate ramp is needed. `threshold`/`ratio` shape
/// the curve; `attack`/`release` set the envelope's per-sample coefficients;
/// `makeup` is a linear make-up gain.
pub fn Compressor(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();
        threshold: f32 = 0.5,
        ratio: f32 = 4.0,
        attack: f32 = 0.25,
        release: f32 = 0.03,
        makeup: f32 = 1.0,
        /// The envelope-follower state (persistent across calls).
        env: f32 = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Sample(T)) void {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            var env = self.env;
            for (xs, ys) |x, *y| {
                env = followEnvelope(env, @floatCast(x), self.attack, self.release);
                const gv: T = @floatCast(compressorGain(env, self.threshold, self.ratio) * self.makeup);
                y.* = x * gv;
            }
            self.env = env;
        }
    };
}

/// `CompressorController(num)` — the **decoupled** twin of `Compressor`: it runs the
/// same per-sample envelope follower and gain curve but *emits the gain as a
/// `Scalar(f32)`* (one value per call, broadcast) for a separate `Vca` to apply, so
/// the dynamics coefficient is a first-class graph value (the same `Vca` could be
/// driven by several controllers, inspected, or recorded). Control-rate: the
/// envelope advances per sample internally, the block-end gain is published, and the
/// `Vca`'s per-block ramp interpolates between blocks.
pub fn CompressorController(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();
        threshold: f32 = 0.5,
        ratio: f32 = 4.0,
        attack: f32 = 0.25,
        release: f32 = 0.03,
        makeup: f32 = 1.0,
        env: f32 = 0,

        pub fn process(self: *Self, in: []const types.Sample(T), out: []types.Scalar(f32)) void {
            const xs = scalarsConst(T, in);
            var env = self.env;
            for (xs) |x| env = followEnvelope(env, @floatCast(x), self.attack, self.release);
            self.env = env;
            const g = compressorGain(env, self.threshold, self.ratio) * self.makeup;
            for (out) |*o| o.value = g; // one control-rate gain, broadcast
        }
    };
}

/// `Aec(num, taps)` — a **fused** acoustic-echo canceller: a normalized least-mean-
/// squares (NLMS) adaptive FIR. The far-end **reference** `x` is filtered by the
/// adapting taps `w` to estimate the echo present in the **mic** signal `d`; the
/// output is the error `e = d − ŵ·x`, i.e. the mic with the estimated echo removed.
/// Each sample the taps adapt by `w += μ·e·x_hist / (‖x_hist‖² + ε)` — the
/// normalization makes the step size independent of the reference's level, so it
/// converges across loud and quiet far-end speech. The controller (the adaptation)
/// and the applied filter live in one block — the canonical fused adaptive processor.
pub fn Aec(comptime num: numeric.Numeric, comptime taps: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (taps == 0) @compileError("pan: Aec taps must be >= 1");
    return struct {
        const Self = @This();
        /// The adaptive FIR taps (the echo-path estimate), persistent across calls.
        w: [taps]f32 = @splat(0),
        /// The reference delay line, newest sample at index 0.
        xhist: [taps]f32 = @splat(0),
        /// NLMS step size in (0, 2) — larger converges faster but is less stable.
        mu: f32 = 0.5,
        /// Regularization, floors the denominator so silence cannot blow up the step.
        eps: f32 = 1e-6,

        pub fn process(
            self: *Self,
            mic: []const types.Sample(T),
            ref: []const types.Sample(T),
            out: []types.Sample(T),
        ) void {
            const ds = scalarsConst(T, mic);
            const xs = scalarsConst(T, ref);
            const es = scalars(T, out);
            for (ds, xs, es) |d, x, *e| {
                // Shift the newest reference sample into the history (index 0 = newest).
                var k: usize = taps - 1;
                while (k > 0) : (k -= 1) self.xhist[k] = self.xhist[k - 1];
                self.xhist[0] = @floatCast(x);
                // Estimate the echo and the reference energy in one pass.
                var yhat: f32 = 0;
                var norm: f32 = self.eps;
                for (self.w, self.xhist) |wk, xk| {
                    yhat += wk * xk;
                    norm += xk * xk;
                }
                const err = @as(f32, @floatCast(d)) - yhat;
                const g = self.mu * err / norm; // NLMS step
                for (&self.w, self.xhist) |*wk, xk| wk.* += g * xk;
                e.* = @floatCast(err);
            }
        }
    };
}

/// `HowlSuppressor(num, taps)` — a **fused** acoustic-feedback (howl) suppressor: a
/// **leaky** NLMS adaptive FIR feedback canceller. Structurally like `Aec` — the
/// loudspeaker feed `x` (the reference) is filtered to estimate the feedback present
/// in the in-loop `primary` signal `d`, and the output is the suppressed error `e`.
/// The distinction is the **leakage** term: each step the taps are shrunk toward
/// zero (`w := (1 − leak)·w + step`). In a closed feedback loop the reference is
/// *correlated* with the desired signal (unlike an echo canceller's independent
/// far-end), which biases a plain adaptive filter; the leakage trades a little
/// cancellation depth for stability against that bias, which is exactly what keeps a
/// feedback canceller from itself ringing. Lower `leak` cancels harder but risks the
/// bias; higher `leak` is safer.
pub fn HowlSuppressor(comptime num: numeric.Numeric, comptime taps: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (taps == 0) @compileError("pan: HowlSuppressor taps must be >= 1");
    return struct {
        const Self = @This();
        w: [taps]f32 = @splat(0),
        xhist: [taps]f32 = @splat(0),
        mu: f32 = 0.5,
        eps: f32 = 1e-6,
        /// Leakage in [0, 1): the per-step tap shrinkage that decorrelates the
        /// adaptation from a reference correlated with the desired signal.
        leak: f32 = 1e-3,

        pub fn process(
            self: *Self,
            primary: []const types.Sample(T),
            ref: []const types.Sample(T),
            out: []types.Sample(T),
        ) void {
            const ds = scalarsConst(T, primary);
            const xs = scalarsConst(T, ref);
            const es = scalars(T, out);
            const keep = 1.0 - self.leak;
            for (ds, xs, es) |d, x, *e| {
                var k: usize = taps - 1;
                while (k > 0) : (k -= 1) self.xhist[k] = self.xhist[k - 1];
                self.xhist[0] = @floatCast(x);
                var yhat: f32 = 0;
                var norm: f32 = self.eps;
                for (self.w, self.xhist) |wk, xk| {
                    yhat += wk * xk;
                    norm += xk * xk;
                }
                const err = @as(f32, @floatCast(d)) - yhat;
                const g = self.mu * err / norm;
                for (&self.w, self.xhist) |*wk, xk| wk.* = keep * wk.* + g * xk; // leaky NLMS
                e.* = @floatCast(err);
            }
        }
    };
}

test "Compressor: passes below threshold, attenuates a hot signal above it" {
    var comp = Compressor(f32num){ .threshold = 0.5, .ratio = 4.0, .attack = 1.0, .release = 1.0 };
    // A steady 0.25 amplitude (below threshold) passes unchanged once the envelope
    // settles (instant attack/release here).
    var quiet: [32]types.Sample(f32) = @splat(S(0.25));
    var qout: [32]types.Sample(f32) = undefined;
    comp.process(&quiet, &qout);
    try testing.expectApproxEqAbs(@as(f32, 0.25), qout[31].ch[0], 1e-6); // unity gain below threshold

    // A steady 1.0 amplitude (above threshold 0.5) is attenuated: gain =
    // (1.0/0.5)^(1/4 − 1) = 2^(−0.75) ≈ 0.5946, so output ≈ 0.5946.
    var hot: [32]types.Sample(f32) = @splat(S(1.0));
    var hout: [32]types.Sample(f32) = undefined;
    comp.process(&hot, &hout);
    const want = std.math.pow(f32, 2.0, -0.75);
    try testing.expectApproxEqAbs(want, hout[31].ch[0], 1e-5);
    try testing.expect(hout[31].ch[0] < 1.0); // genuinely attenuated
}

test "CompressorController: emits unity below threshold, a reduction above it" {
    const port = @import("port.zig");
    const C = CompressorController(f32num);
    try testing.expect(port.classify(C) == .Map);
    try testing.expect(port.MapOutPort(C).Elem == types.Scalar(f32));

    var c = C{ .threshold = 0.5, .ratio = 4.0, .attack = 1.0, .release = 1.0 };
    var quiet: [16]types.Sample(f32) = @splat(S(0.25));
    var out: [16]types.Scalar(f32) = undefined;
    c.process(&quiet, &out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].value, 1e-6);

    var hot: [16]types.Sample(f32) = @splat(S(1.0));
    c.process(&hot, &out);
    try testing.expectApproxEqAbs(std.math.pow(f32, 2.0, -0.75), out[0].value, 1e-5);
}

/// A deterministic broadband-ish reference for the adaptive-filter tests: a sum of
/// two incommensurate tones, rich enough for the NLMS to converge.
fn refSignal(n: usize) f32 {
    const t: f32 = @floatFromInt(n);
    return 0.5 * @sin(0.7 * t) + 0.5 * @sin(1.9 * t + 0.4);
}

test "Aec: NLMS converges — a delayed-echo mic is progressively cancelled" {
    var aec = Aec(f32num, 8){ .mu = 0.5 };
    // Echo path = the reference delayed by 2 samples, gain 0.8 (desired signal = 0,
    // so a perfect canceller drives the error to 0). Feed many blocks; the residual
    // error energy must fall sharply as the taps adapt.
    var ref_prev = [_]f32{0} ** 2;
    var first_energy: f32 = 0;
    var last_energy: f32 = 0;
    const blocks = 200;
    var b: usize = 0;
    var nidx: usize = 0;
    while (b < blocks) : (b += 1) {
        var mic: [16]types.Sample(f32) = undefined;
        var ref: [16]types.Sample(f32) = undefined;
        for (0..16) |i| {
            const x = refSignal(nidx);
            nidx += 1;
            ref[i] = S(x);
            mic[i] = S(0.8 * ref_prev[1]); // echo: ref delayed 2, scaled 0.8
            ref_prev[1] = ref_prev[0];
            ref_prev[0] = x;
        }
        var out: [16]types.Sample(f32) = undefined;
        aec.process(&mic, &ref, &out);
        var energy: f32 = 0;
        for (out) |e| energy += e.ch[0] * e.ch[0];
        if (b == 0) first_energy = energy;
        if (b == blocks - 1) last_energy = energy;
    }
    // The adaptive filter cancels the echo: late-block residual ≪ first-block.
    try testing.expect(last_energy < first_energy * 0.05);
}

test "HowlSuppressor: leaky NLMS converges and keeps the taps bounded" {
    var hs = HowlSuppressor(f32num, 8){ .mu = 0.5, .leak = 1e-3 };
    var ref_prev: f32 = 0;
    var first_energy: f32 = 0;
    var last_energy: f32 = 0;
    const blocks = 200;
    var b: usize = 0;
    var nidx: usize = 0;
    while (b < blocks) : (b += 1) {
        var primary: [16]types.Sample(f32) = undefined;
        var ref: [16]types.Sample(f32) = undefined;
        for (0..16) |i| {
            const x = refSignal(nidx);
            nidx += 1;
            ref[i] = S(x);
            primary[i] = S(0.7 * ref_prev); // feedback: ref delayed 1, scaled 0.7
            ref_prev = x;
        }
        var out: [16]types.Sample(f32) = undefined;
        hs.process(&primary, &ref, &out);
        var energy: f32 = 0;
        for (out) |e| energy += e.ch[0] * e.ch[0];
        if (b == 0) first_energy = energy;
        if (b == blocks - 1) last_energy = energy;
    }
    try testing.expect(last_energy < first_energy * 0.1); // suppressed (leakage caps depth)
    // Leakage keeps the taps finite/bounded — no runaway.
    var wmax: f32 = 0;
    for (hs.w) |wk| wmax = @max(wmax, @abs(wk));
    try testing.expect(wmax < 10.0 and std.math.isFinite(wmax));
}
