//! Frequency-domain processors: the uniform-partitioned overlap-add FFT
//! convolution (`Rate`) and the per-bin spectral gate / EQ (`Map`s over the
//! `Spectrum` stream).
//!
//! `PartitionedConvolution` owns an internal clocked ring (a frequency-domain delay
//! line of recent input-block spectra plus a time-domain overlap-add accumulator),
//! so it is a `Rate` block even though its out:in is 1:1. `SpectralGate`/`SpectralEq`
//! are per-bin rate-1:1 `Map`s (element type unchanged, `Spectrum → Spectrum`).
//! Float-only, declared loud via `requireFloat`. The `Spectrum` port element and the
//! shared FFT kernel are imported from the sibling spectral files.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;
const numeric = core.numeric;
const control = core.control;

const sc = @import("spectral_common.zig");
const requireFloat = sc.requireFloat;
const isPow2 = sc.isPow2;
const scalarsConst = sc.scalarsConst;
const scalars = sc.scalars;
const rfftForward = sc.rfftForward;
const rfftInverse = sc.rfftInverse;

const Spectrum = @import("spectral_core.zig").Spectrum;

// ===========================================================================
// PartitionedConvolution — uniform-partitioned overlap-add FFT convolution (Rate)
// ===========================================================================

/// `PartitionedConvolution(num, FRAME, HOP, n_partitions)` — uniform-partitioned
/// overlap-add (UPOLA) frequency-domain convolution of the mono input with an
/// impulse response of up to `n_partitions·HOP` taps. A `Sample → Sample`
/// transform whose out:in is exactly 1:1, but it is a `Rate` block (not a `Map`):
/// it owns an internal clocked ring — a frequency-domain delay line of the last
/// `n_partitions` input-block spectra plus a time-domain overlap-add accumulator —
/// so its output is not a pure function of the current input slice. That ring is
/// the defining Rate smell, and it carries `HOP` samples of group delay.
///
/// **How it partitions and why FRAME ≥ 2·HOP.** The IR is sliced into
/// `n_partitions` contiguous blocks of `HOP` taps each (zero-padded if the IR is
/// shorter); block `p` is zero-extended to `FRAME` samples and pre-transformed to
/// its half-spectrum `H[p]` once, at `initialize`. Input is buffered into blocks
/// of `HOP` samples; each full block is zero-extended to `FRAME` and forward-rfft'd
/// to `X`, then pushed into the spectral delay line. The output block's spectrum is
/// the per-bin complex multiply-accumulate `Y = Σ_p X[now−p]·H[p]`, inverse-rfft'd
/// to `FRAME` time samples and overlap-added into a running accumulator; the
/// accumulator's first `HOP` samples are emitted and it shifts down by `HOP`. The
/// linear convolution of one `HOP`-sample input block with one `HOP`-tap IR block
/// has length `2·HOP − 1`; the per-block FFT must be at least that long or the
/// result time-aliases (the circular convolution wraps the tail back over the
/// head), so `FRAME ≥ 2·HOP` is required and enforced. With that, each block
/// product is an exact linear (not circular) convolution and the overlap-add of
/// the `2·HOP − 1`-sample spreads reconstructs the full linear convolution.
///
/// **Latency.** Zero group delay. A block of `HOP` inputs is buffered before its
/// `HOP` outputs can be produced, but that buffering is throughput latency, not
/// group delay: the spectral delay line is indexed so partition `p`'s contribution
/// lands at the correct output sample, so output block `b` carries `Σ_p
/// x_block[b−p] ⊛ h_part[p]` aligned with input block `b`. Convolving with a
/// unit-impulse IR (`ir[0] = 1`, rest 0) therefore returns the input UNSHIFTED (the
/// convolution identity); a general IR's group delay is the IR's own, in its taps.
///
/// **Float-only**, mono. The IR is block data set via `initialize(ir)`; an unset
/// IR convolves with silence (all-zero spectra ⇒ silent output).
pub fn PartitionedConvolution(
    comptime num: numeric.Numeric,
    comptime FRAME: usize,
    comptime HOP: usize,
    comptime n_partitions: usize,
) type {
    const T = num.Lane;
    requireFloat(T);
    if (!isPow2(FRAME)) @compileError("pan: PartitionedConvolution FRAME must be a power of two");
    if (HOP == 0) @compileError("pan: PartitionedConvolution HOP must be >= 1");
    if (FRAME < 2 * HOP)
        @compileError("pan: PartitionedConvolution FRAME must be >= 2·HOP — a HOP-sample" ++
            " block convolved with a HOP-tap IR partition is 2·HOP−1 samples long, so a" ++
            " shorter FFT would time-alias (the circular tail wraps over the head)");
    if (n_partitions == 0) @compileError("pan: PartitionedConvolution n_partitions must be >= 1");
    const BINS = FRAME / 2 + 1;
    const C = std.math.Complex(T);
    return struct {
        const Self = @This();

        /// Same number of samples out as in — convolution is rate-preserving.
        pub const out_per_in = .{ 1, 1 };
        /// Zero group delay. A block of `HOP` inputs is buffered before its `HOP`
        /// outputs are produced, but that is throughput latency, not group delay:
        /// the spectral delay line is indexed so partition `p`'s contribution lands
        /// at the correct output sample, so output block `b` carries `Σ_p
        /// x_block[b−p] ⊛ h_part[p]` aligned with input block `b`. (A Rate block may
        /// declare zero group delay — latency is orthogonal to the rate ratio;
        /// declaring it, even as 0, is the contract.) Convolving with a unit-impulse
        /// IR therefore returns the input UNSHIFTED; a general IR's group delay is
        /// the IR's own, carried in its taps.
        pub const algorithmic_latency: usize = 0;
        pub const state_size: usize = @sizeOf([n_partitions]([BINS]C)) +
            @sizeOf([BINS]C) * n_partitions + @sizeOf([FRAME]T) + 2 * @sizeOf([HOP]T) + 4 * @sizeOf(usize);

        /// IR partition spectra: `ir_spec[p]` is the half-spectrum of IR block `p`
        /// (taps `[p·HOP, p·HOP+HOP)` zero-extended to `FRAME`). Zero until set.
        ir_spec: [n_partitions][BINS]C =
            [_][BINS]C{[_]C{.{ .re = 0, .im = 0 }} ** BINS} ** n_partitions,
        /// Frequency-domain delay line of the most-recent input-block spectra:
        /// `fdl[(head − p) mod n_partitions]` is `X[now − p]`, the input block `p`
        /// blocks ago. A circular buffer indexed by `head`.
        fdl: [n_partitions][BINS]C =
            [_][BINS]C{[_]C{.{ .re = 0, .im = 0 }} ** BINS} ** n_partitions,
        /// Write cursor into `fdl`: the slot holding the most-recently inserted
        /// input-block spectrum.
        head: usize = 0,
        /// Time-domain overlap-add accumulator for the inverse-FFT output spreads.
        overlap: [FRAME]T = [_]T{0} ** FRAME,
        /// The current partially-filled input block (the clocked ring): `fill`
        /// samples accumulated toward the next `HOP`-sample block.
        block: [HOP]T = [_]T{0} ** HOP,
        /// Count of samples in `block` (0..HOP); carries the sub-`HOP` remainder of
        /// a chunk across `pull` calls so no input is dropped on a `HOP ∤ chunk` pull.
        fill: usize = 0,
        /// Completed-but-not-yet-emitted output samples — a FIFO ring. A whole block
        /// produces `HOP` outputs at once; if the caller's `want` is not block-aligned
        /// the leftover is held here and drained on the next `pull`, so no output is
        /// ever lost on a `HOP ∤ want` pull. Capacity `FRAME` (≥ `2·HOP`) absorbs a
        /// sub-`HOP` carry plus one freshly-completed block. `oavail` samples remain,
        /// the oldest at `ohead`, wrapping modulo `FRAME`.
        obuf: [FRAME]T = [_]T{0} ** FRAME,
        ohead: usize = 0,
        oavail: usize = 0,

        /// Install the impulse response (up to `n_partitions·HOP` taps). Each
        /// `HOP`-tap partition is zero-extended to `FRAME` and pre-transformed to
        /// its half-spectrum, so the per-block hot path is a pure spectral MAC.
        /// Taps past `ir.len` (and the zero-extension to `FRAME`) are silence.
        pub fn initialize(self: *Self, ir: []const T) void {
            var p: usize = 0;
            while (p < n_partitions) : (p += 1) {
                var padded: [FRAME]T = [_]T{0} ** FRAME;
                var t: usize = 0;
                while (t < HOP) : (t += 1) {
                    const idx = p * HOP + t;
                    padded[t] = if (idx < ir.len) ir[idx] else 0;
                }
                rfftForward(T, FRAME, &padded, &self.ir_spec[p]);
            }
        }

        /// Out:in is 1:1, so `want` outputs need `want` inputs.
        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return want;
        }

        pub fn pull(self: *Self, in: []const types.Sample(T), want: usize, out: []types.Sample(T)) usize {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            var produced: usize = 0;

            // Drain any output left over from a prior non-block-aligned pull first.
            self.drain(ys, &produced, want);

            // Consume ALL provided input (never drop a sample): each input goes into
            // the block ring; a completed block is convolved and its HOP outputs are
            // appended to the output FIFO; we then drain up to the `want` ceiling.
            // Whatever the `want` budget could not take stays in the FIFO (and a
            // sub-HOP remainder stays in `block`) for the next call. With the 1:1 rate
            // and the scheduler's `needed_input(want) == want` supply, the FIFO holds
            // at most a sub-HOP carry plus one freshly-completed block (≤ FRAME).
            for (xs) |x| {
                self.block[self.fill] = x;
                self.fill += 1;
                if (self.fill < HOP) continue;
                self.fill = 0;

                // The completed input block, zero-extended to FRAME, forward-rfft'd
                // and inserted at the head of the frequency-domain delay line.
                var padded: [FRAME]T = [_]T{0} ** FRAME;
                @memcpy(padded[0..HOP], self.block[0..HOP]);
                self.head = (self.head + 1) % n_partitions;
                rfftForward(T, FRAME, &padded, &self.fdl[self.head]);

                // Y = Σ_p X[now−p]·H[p], a per-bin complex multiply-accumulate over
                // the delay line against the IR partition spectra.
                var acc: [BINS]C = [_]C{.{ .re = 0, .im = 0 }} ** BINS;
                var p: usize = 0;
                while (p < n_partitions) : (p += 1) {
                    const slot = (self.head + n_partitions - p) % n_partitions;
                    const xf = &self.fdl[slot];
                    const hf = &self.ir_spec[p];
                    var b: usize = 0;
                    while (b < BINS) : (b += 1) {
                        // (a+bi)(c+di) = (ac−bd) + (ad+bc)i
                        acc[b].re += xf[b].re * hf[b].re - xf[b].im * hf[b].im;
                        acc[b].im += xf[b].re * hf[b].im + xf[b].im * hf[b].re;
                    }
                }

                // Inverse-rfft to FRAME time samples, overlap-add into the running
                // accumulator. The first HOP samples are this block's finished output;
                // append them to the output FIFO, then shift the accumulator down by
                // HOP and zero the vacated tail.
                var tdom: [FRAME]T = undefined;
                rfftInverse(T, FRAME, &acc, &tdom);
                for (&self.overlap, tdom) |*o, s| o.* += s;
                var k: usize = 0;
                while (k < HOP) : (k += 1) {
                    const w = (self.ohead + self.oavail) % FRAME; // FIFO write index
                    self.obuf[w] = self.overlap[k];
                    self.oavail += 1;
                }
                std.mem.copyForwards(T, self.overlap[0 .. FRAME - HOP], self.overlap[HOP..FRAME]);
                @memset(self.overlap[FRAME - HOP .. FRAME], 0);

                self.drain(ys, &produced, want);
            }
            return produced;
        }

        /// Move buffered output into `ys` up to the `want` ceiling, advancing the
        /// FIFO read cursor; the remainder (if `want` is reached mid-block) stays in
        /// the FIFO for the next call so no output sample is lost.
        fn drain(self: *Self, ys: []T, produced: *usize, want: usize) void {
            while (self.oavail > 0 and produced.* < want) {
                ys[produced.*] = self.obuf[self.ohead];
                self.ohead = (self.ohead + 1) % FRAME;
                self.oavail -= 1;
                produced.* += 1;
            }
        }
    };
}

// ===========================================================================
// SpectralGate — per-bin spectral noise gate (Map, Spectrum -> Spectrum)
// ===========================================================================

/// `SpectralGate(num, bins)` — a spectral noise gate: zero every bin whose
/// magnitude is below the `threshold` parameter, pass the rest unchanged. A
/// per-bin rate-1:1 `Map` over the spectrum stream (`Spectrum → Spectrum`, element
/// type unchanged), so it is a `Map`, not a `Rate`.
///
/// The gate compares `|z|²` against `threshold²` to avoid a per-bin square root
/// (magnitude ≥ threshold ⟺ power ≥ threshold², for non-negative threshold). A bin
/// at exactly the threshold passes (the boundary is inclusive). Float-only.
pub fn SpectralGate(comptime num: numeric.Numeric, comptime bins: usize) type {
    const T = num.Lane;
    requireFloat(T);
    const In = Spectrum(T, bins);
    return struct {
        const Self = @This();

        /// The gate threshold, a magnitude floor. Bins with `|z| < threshold` are
        /// zeroed; `|z| >= threshold` passes unchanged.
        pub const params = .{ .threshold = types.Scalar(f32) };

        threshold: control.Param = control.Param.init(0.0),

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.threshold.set(value);
        }

        pub fn process(self: *Self, in: []const In, out: []In) void {
            const thr: T = @floatCast(self.threshold.read()); // held per call
            const thr2 = thr * thr;
            for (in, out) |frame, *o| {
                for (&o.bin, frame.bin) |*ob, z| {
                    const power = z.re * z.re + z.im * z.im;
                    ob.* = if (power >= thr2) z else .{ .re = 0, .im = 0 };
                }
            }
        }
    };
}

// ===========================================================================
// SpectralEq — per-bin real-gain spectral EQ (Map, Spectrum -> Spectrum)
// ===========================================================================

/// `SpectralEq(num, bins)` — a linear-phase spectral equalizer: multiply each bin
/// by a real (zero-phase) gain from a settable `[bins]f32` curve. A per-bin
/// rate-1:1 `Map` over the spectrum stream (`Spectrum → Spectrum`, element type
/// unchanged), so it is a `Map`, not a `Rate`.
///
/// The gains are REAL (not complex): each bin is multiplied component-wise by
/// `gain[b]`. For a NON-NEGATIVE gain this is zero-phase (it scales the magnitude by
/// `gain[b]` and leaves the phase untouched); a negative gain is exactly a magnitude
/// scale by `|gain[b]|` plus a π phase flip (multiplying by a negative real). The
/// default curve is unity (all gains 1), which is the identity. Float-only.
pub fn SpectralEq(comptime num: numeric.Numeric, comptime bins: usize) type {
    const T = num.Lane;
    requireFloat(T);
    const In = Spectrum(T, bins);
    return struct {
        const Self = @This();

        /// Per-bin real gain curve; unity (identity) until set via `initialize`.
        gain: [bins]f32 = [_]f32{1.0} ** bins,

        /// Install the gain curve. `curve.len` must equal `bins`.
        pub fn initialize(self: *Self, curve: []const f32) void {
            std.debug.assert(curve.len == bins);
            @memcpy(&self.gain, curve);
        }

        pub fn process(self: *Self, in: []const In, out: []In) void {
            for (in, out) |frame, *o| {
                for (&o.bin, frame.bin, self.gain) |*ob, z, g| {
                    const gg: T = @floatCast(g);
                    ob.* = .{ .re = z.re * gg, .im = z.im * gg };
                }
            }
        }
    };
}

// ===========================================================================
// Tests — convolution identity / naive-oracle / misalignment, and the per-bin
// Map laws (the autonomous Yoneda suite owns the full matrix).
// ===========================================================================

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

// --- PartitionedConvolution -------------------------------------------------

test "PartitionedConvolution classifies as a (Sample->Sample) Rate, zero group delay" {
    const port = core.port;
    const Conv = PartitionedConvolution(f32num, 16, 8, 4);
    try testing.expect(port.classify(Conv) == .Rate);
    try testing.expect(port.RateInElem(Conv) == types.Sample(f32));
    try testing.expect(port.RateOutElem(Conv) == types.Sample(f32));
    // Zero group delay (the buffering is throughput, not group delay).
    try testing.expectEqual(@as(usize, 0), Conv.algorithmic_latency);
    // Rate ratio is 1:1 (convolution is rate-preserving).
    try testing.expectEqual(@as(usize, 1), Conv.out_per_in[0]);
    try testing.expectEqual(@as(usize, 1), Conv.out_per_in[1]);
}

test "PartitionedConvolution: unit-impulse IR returns the input unshifted (identity)" {
    // ORACLE: convolving with δ[n] is the identity; the block declares zero group
    // delay, so the output must equal the input sample-for-sample. The reference is
    // the raw input series, independent of the block's own path. (The block buffers
    // a HOP-sample block before emitting, so the last partial sub-HOP block of the
    // stream is not yet flushed — only whole blocks are checked.)
    const FRAME = 16;
    const HOP = 8;
    const NP = 4;
    var conv = PartitionedConvolution(f32num, FRAME, HOP, NP){};
    conv.initialize(&[_]f32{1.0}); // δ: only tap 0 is 1, all later taps 0

    const N = 96; // a whole number of HOP blocks
    var in: [N]types.Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(13);
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;

    var out: [N]types.Sample(f32) = undefined;
    const got = conv.pull(&in, N, &out);
    try testing.expectEqual(@as(usize, N), got);

    var n: usize = 0;
    while (n < N) : (n += 1) try testing.expectApproxEqAbs(in[n].ch[0], out[n].ch[0], 1e-4);
}

test "PartitionedConvolution: matches a naive O(N·M) time-domain convolution" {
    // ORACLE: an independent, schoolbook linear convolution y[n] = Σ_m h[m]·x[n−m]
    // computed directly in the time domain (shares only the definition of
    // convolution with the FFT path, not the algorithm). The block's output is the
    // same series delayed by its declared HOP latency.
    const FRAME = 32;
    const HOP = 16;
    const NP = 3; // IR up to NP·HOP = 48 taps
    const M = 40; // an IR shorter than the full partition budget (last block partial)
    var ir: [M]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(2027);
    for (&ir) |*h| h.* = rng.random().float(f32) * 2 - 1;

    const N = 128;
    var x: [N]f32 = undefined;
    for (&x) |*v| v.* = rng.random().float(f32) * 2 - 1;

    // Independent naive convolution into a reference series of length N.
    var ref: [N]f32 = [_]f32{0} ** N;
    for (0..N) |n| {
        var acc: f32 = 0;
        for (0..M) |m| {
            if (m <= n) acc += ir[m] * x[n - m];
        }
        ref[n] = acc;
    }

    var conv = PartitionedConvolution(f32num, FRAME, HOP, NP){};
    conv.initialize(&ir);
    var in: [N]types.Sample(f32) = undefined;
    for (&in, x) |*s, v| s.ch[0] = v;
    var out: [N]types.Sample(f32) = undefined;
    _ = conv.pull(&in, N, &out);

    // Zero group delay: out[n] == ref[n] aligned (NP·HOP = 48 >= M = 40 taps, so
    // the whole IR is covered and no tail is dropped within the stream).
    var n: usize = 0;
    while (n < N) : (n += 1) {
        try testing.expectApproxEqAbs(ref[n], out[n].ch[0], 1e-3);
    }
}

test "PartitionedConvolution: HOP ∤ chunk misalignment drops no input (ring carries remainder)" {
    // Pulling in odd-sized chunks must equal one whole-stream pull: the internal
    // block ring carries the sub-HOP remainder across calls. ORACLE: the same
    // block fed the whole stream at once.
    const FRAME = 16;
    const HOP = 8;
    const NP = 2;
    var ir: [10]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(55);
    for (&ir) |*h| h.* = rng.random().float(f32) * 2 - 1;

    const N = 80;
    var in: [N]types.Sample(f32) = undefined;
    for (&in) |*s| s.ch[0] = rng.random().float(f32) * 2 - 1;

    var whole = PartitionedConvolution(f32num, FRAME, HOP, NP){};
    whole.initialize(&ir);
    var out_whole: [N]types.Sample(f32) = undefined;
    _ = whole.pull(&in, N, &out_whole);

    var split = PartitionedConvolution(f32num, FRAME, HOP, NP){};
    split.initialize(&ir);
    var out_split: [N]types.Sample(f32) = undefined;
    // Chunk sizes that are not multiples of HOP (5, 7, 5, …) exercise the remainder
    // ring. A Rate block under-produces a chunk until enough input accrues to fill a
    // block, so outputs are appended at the running `done` cursor, not per-chunk.
    var off: usize = 0; // input consumed
    var done: usize = 0; // outputs emitted so far
    const sizes = [_]usize{ 5, 7, 5, 11, 3, 9, 13, 27 };
    var si: usize = 0;
    while (off < N) {
        const want = @min(sizes[si % sizes.len], N - off);
        si += 1;
        const g = split.pull(in[off .. off + want], want, out_split[done..N]);
        try testing.expect(g <= want); // may under-produce; never over-produce
        off += want;
        done += g;
    }
    // Both paths flushed the same whole blocks; compare those.
    var n: usize = 0;
    while (n < done) : (n += 1) try testing.expectApproxEqAbs(out_whole[n].ch[0], out_split[n].ch[0], 1e-5);
}

// --- SpectralGate -----------------------------------------------------------

test "SpectralGate classifies as a (Spectrum->Spectrum) Map" {
    const port = core.port;
    const Gate = SpectralGate(f32num, 4);
    try testing.expect(port.classify(Gate) == .Map);
    try testing.expect(port.MapInElem(Gate) == Spectrum(f32, 4));
    try testing.expect(port.MapOutElem(Gate) == Spectrum(f32, 4));
}

test "SpectralGate: bins below threshold zero, bins at/above pass unchanged" {
    // ORACLE: a hand-classified expectation per bin. With threshold = 5, a bin of
    // magnitude 5 (|3+4i| = 5) sits exactly at the floor and PASSES; a bin of
    // magnitude < 5 is ZEROED; a large bin passes verbatim.
    var gate = SpectralGate(f32num, 4){};
    gate.setParam(0, 5.0);
    var in = [_]Spectrum(f32, 4){.{
        .bin = .{
            .{ .re = 3, .im = 4 }, // |z| = 5  -> at threshold, passes
            .{ .re = 1, .im = 0 }, // |z| = 1  -> below, zeroed
            .{ .re = 0, .im = 4 }, // |z| = 4  -> below, zeroed
            .{ .re = -10, .im = 0 }, // |z| = 10 -> above, passes
        },
    }};
    var out: [1]Spectrum(f32, 4) = undefined;
    gate.process(&in, &out);
    try testing.expectApproxEqAbs(@as(f32, 3), out[0].bin[0].re, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 4), out[0].bin[0].im, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].bin[1].re, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].bin[1].im, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].bin[2].im, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -10), out[0].bin[3].re, 1e-6);
}

test "SpectralGate: zero threshold is identity (every bin passes)" {
    // ORACLE: with threshold 0, |z| >= 0 is always true, so the gate is the
    // identity — output must equal input bin-for-bin.
    var gate = SpectralGate(f32num, 3){};
    // default threshold is already 0; assert that default is pass-through.
    var in = [_]Spectrum(f32, 3){.{ .bin = .{
        .{ .re = 0.001, .im = -0.002 },
        .{ .re = 7, .im = 8 },
        .{ .re = 0, .im = 0 },
    } }};
    var out: [1]Spectrum(f32, 3) = undefined;
    gate.process(&in, &out);
    for (out[0].bin, in[0].bin) |o, z| {
        try testing.expectApproxEqAbs(z.re, o.re, 1e-9);
        try testing.expectApproxEqAbs(z.im, o.im, 1e-9);
    }
}

// --- SpectralEq -------------------------------------------------------------

test "SpectralEq classifies as a (Spectrum->Spectrum) Map" {
    const port = core.port;
    const Eq = SpectralEq(f32num, 4);
    try testing.expect(port.classify(Eq) == .Map);
    try testing.expect(port.MapInElem(Eq) == Spectrum(f32, 4));
    try testing.expect(port.MapOutElem(Eq) == Spectrum(f32, 4));
}

test "SpectralEq: a known gain curve scales each bin's magnitude exactly" {
    // ORACLE: a real gain g[b] scales magnitude by g[b] and leaves phase intact, so
    // each output bin equals the input bin times g[b], component-wise. The
    // reference is the hand-multiplied (re·g, im·g), independent of the block.
    var eq = SpectralEq(f32num, 4){};
    eq.initialize(&[_]f32{ 2.0, 0.0, 0.5, 3.0 });
    var in = [_]Spectrum(f32, 4){.{ .bin = .{
        .{ .re = 1, .im = 2 },
        .{ .re = 5, .im = -5 },
        .{ .re = -4, .im = 8 },
        .{ .re = 0, .im = 1 },
    } }};
    var out: [1]Spectrum(f32, 4) = undefined;
    eq.process(&in, &out);
    const g = [_]f32{ 2.0, 0.0, 0.5, 3.0 };
    for (out[0].bin, in[0].bin, g) |o, z, gg| {
        try testing.expectApproxEqAbs(z.re * gg, o.re, 1e-6);
        try testing.expectApproxEqAbs(z.im * gg, o.im, 1e-6);
        // Magnitude scales by exactly gg.
        const mag_in = @sqrt(z.re * z.re + z.im * z.im);
        const mag_out = @sqrt(o.re * o.re + o.im * o.im);
        try testing.expectApproxEqAbs(mag_in * gg, mag_out, 1e-5);
    }
}

test "SpectralEq: a flat unity curve is the identity" {
    // ORACLE: the default curve is all-ones; identity output expected.
    var eq = SpectralEq(f32num, 3){};
    var in = [_]Spectrum(f32, 3){.{ .bin = .{
        .{ .re = 1.5, .im = -2.5 },
        .{ .re = 0, .im = 0 },
        .{ .re = 9, .im = 9 },
    } }};
    var out: [1]Spectrum(f32, 3) = undefined;
    eq.process(&in, &out);
    for (out[0].bin, in[0].bin) |o, z| {
        try testing.expectApproxEqAbs(z.re, o.re, 1e-9);
        try testing.expectApproxEqAbs(z.im, o.im, 1e-9);
    }
}
