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
//! and are not in the P10 embedded-chain gate (which is gain → biquad → sink).
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
