//! The runtime-ratio polyphase resampler used at the I/O boundary, factored into
//! the core layer so the engine can depend on it without pulling in the rest of
//! the I/O surface. Self-contained: needs only `std` (math + allocator).

const std = @import("std");

/// `RuntimeResampler` — a streaming rational `p:q` (out:in) windowed-sinc polyphase
/// resampler with a RUNTIME ratio (the rates come from the negotiation pass, not a
/// comptime monomorph like `spectral.Resampler`), the sample-rate-conversion
/// citizen at the I/O boundary where the device rate meets the pipeline rate.
///
/// It is **drift-free by construction**: `needed_input(want)` is **phase-stateful**
/// — `(acc + want·q) / p` against the live phase accumulator — so it reports the
/// EXACT number of input samples needed for `want` outputs *this* call (470 or 471
/// for 160:147 at N=512, averaging 470.4 with no accumulation). The caller produces
/// exactly that many; `process` consumes exactly that many and emits exactly `want`.
/// A fixed per-callback input count (e.g. the static op-list's `ceil`) would drift
/// for a non-integer ratio — that is why a correct mid-graph resampler needs the
/// dynamic per-callback count the runtime render computes from this method.
///
/// State: a windowed-sinc prototype (built once at `init` from `p:q`), a per-channel
/// circular history of the last `ksup` input samples (the FIR support, zero-primed →
/// the `algorithmic_latency` group-delay priming), and the phase `acc ∈ [0,p)`.
/// Buffers are plane-major f32 (`channels` planes); each plane resamples in lockstep.
pub const RuntimeResampler = struct {
    proto: []f32, // taps coefficients, upsampled-grid
    taps: usize,
    p: usize, // out_per_in numerator (output rate factor)
    q: usize, // out_per_in denominator (input rate factor)
    channels: usize,
    ksup: usize, // FIR taps per polyphase subfilter = ceil(taps/p)
    hist: []f32, // channels * ksup, per-channel circular history (cursor shared)
    cursor: usize = 0, // next slot to overwrite (oldest)
    acc: usize = 0, // phase accumulator in [0, p)
    half: usize, // prototype half-width (taps each side), for the group delay

    pub fn init(alloc: std.mem.Allocator, p: usize, q: usize, channels: usize, half: usize) !RuntimeResampler {
        std.debug.assert(p >= 1 and q >= 1 and channels >= 1 and half >= 1);
        const up = @max(p, q);
        const taps = 2 * half * up + 1;
        const ksup = (taps + p - 1) / p;
        const proto = try alloc.alloc(f32, taps);
        buildProto(proto, taps, half, up, p);
        const hist = try alloc.alloc(f32, channels * ksup);
        @memset(hist, 0);
        return .{ .proto = proto, .taps = taps, .p = p, .q = q, .channels = channels, .ksup = ksup, .hist = hist, .half = half };
    }

    pub fn deinit(self: *RuntimeResampler, alloc: std.mem.Allocator) void {
        alloc.free(self.proto);
        alloc.free(self.hist);
    }

    /// Group delay in OUTPUT samples. The linear-phase prototype centre sits at
    /// `half·up` upsampled samples; with this `process`'s compute-then-consume
    /// ordering an impulse at input 0 peaks at output `(half·up + p)/q` (verified by
    /// the impulse latency probe). Exact for ratios where `q | (half·up + p)`.
    pub fn latency(self: *const RuntimeResampler) usize {
        const up = @max(self.p, self.q);
        return (self.half * up + self.p) / self.q;
    }

    /// EXACT input samples needed to produce `want` outputs from the current phase
    /// (drift-free). The caller (the dynamic-count render) produces precisely this.
    pub fn needed_input(self: *const RuntimeResampler, want: usize) usize {
        return (self.acc + want * self.q) / self.p;
    }

    /// Resample `want` outputs, consuming exactly `needed_input(want)` inputs.
    /// `in`/`out` are plane-major f32 (`channels` planes of `in_count`/`want`).
    pub fn process(self: *RuntimeResampler, in: []const f32, in_count: usize, out: []f32, want: usize) void {
        var consumed: usize = 0;
        var j: usize = 0;
        while (j < want) : (j += 1) {
            // Output j at the current history + phase `acc`.
            var c: usize = 0;
            while (c < self.channels) : (c += 1) {
                var y: f32 = 0;
                var i: usize = 0;
                var k: usize = self.acc;
                while (k < self.taps) : (k += self.p) {
                    y += self.proto[k] * self.histGet(c, i);
                    i += 1;
                }
                out[c * want + j] = y;
            }
            // Advance the phase; consume one input each time it wraps past p.
            self.acc += self.q;
            while (self.acc >= self.p) {
                self.acc -= self.p;
                var cc: usize = 0;
                while (cc < self.channels) : (cc += 1)
                    self.hist[cc * self.ksup + self.cursor] = in[cc * in_count + consumed];
                self.cursor += 1;
                if (self.cursor == self.ksup) self.cursor = 0;
                consumed += 1;
            }
        }
    }

    /// The `i`-th most recent input sample of channel `c` (0 = newest); reads zero
    /// before the stream has supplied it (the priming pre-roll).
    fn histGet(self: *const RuntimeResampler, c: usize, i: usize) f32 {
        const slot = (self.cursor + self.ksup - 1 - (i % self.ksup)) % self.ksup;
        return self.hist[c * self.ksup + slot];
    }
};

/// Build a windowed-sinc prototype FIR of `taps` taps, centre at `half·up`, cutoff
/// `π/up`, normalized to unity DC gain × `gain` (the upsample-energy compensation).
fn buildProto(proto: []f32, taps: usize, half: usize, up: usize, gain: usize) void {
    const center: f64 = @floatFromInt(half * up);
    const fc: f64 = 1.0 / @as(f64, @floatFromInt(up));
    var sum: f64 = 0;
    for (proto, 0..) |*coef, i| {
        const n: f64 = @as(f64, @floatFromInt(i)) - center;
        const sinc: f64 = if (n == 0) fc else @sin(std.math.pi * fc * n) / (std.math.pi * n);
        const wphase = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(taps - 1));
        const win: f64 = 0.5 * (1.0 - @cos(wphase));
        const v = sinc * win;
        coef.* = @floatCast(v);
        sum += v;
    }
    const g: f64 = @as(f64, @floatFromInt(gain)) / sum;
    for (proto) |*coef| coef.* = @floatCast(@as(f64, coef.*) * g);
}
