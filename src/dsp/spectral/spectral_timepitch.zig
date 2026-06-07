//! Time- and pitch-domain resamplers: the fixed-ratio windowed-sinc `Resampler`,
//! the runtime-ratio `Varispeed` (VariRate), the pitch-preserving WSOLA
//! `TimeStretch` (VariRate), and the duration-preserving `PitchShift`
//! (TimeStretch ∘ resample).
//!
//! Each fixed/variable-rate block owns an internal clocked ring (the
//! overlap/history/cursor state), so it is not a pure function of its current input
//! slice. The pull contract is `pull(self, in, want, out) -> produced` (the source
//! `TimeStretch`/`PitchShift` take no `in`); a VariRate block is discriminated by a
//! bounded `rate_bounds` interval plus a worst-case `max_latency`. Float-only,
//! declared loud via `requireFloat`.

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
const hannWindow = sc.hannWindow;

// ===========================================================================
// Resampler — rational L:M windowed-sinc resampler (Rate)
// ===========================================================================

/// `Resampler(num, L, M, HALF)` — a linear-phase windowed-sinc rational resampler:
/// `L` output samples per `M` input samples (`out_per_in = L:M`). The prototype is
/// a Hann-windowed sinc of `2·HALF + 1` taps at the upsampled rate, cutoff
/// `π/max(L,M)` (the anti-imaging / anti-aliasing band), with `HALF` taps of group
/// delay. The block keeps an input history ring so the FIR has its left context
/// across `pull` calls.
///
/// `L = M = 1` degenerates to a linear-phase low-pass FIR with a clean,
/// unambiguous group delay of `HALF` output samples — the latency-contract probe;
/// `L ≠ M` is a genuine rate change whose output length tracks the `L:M` ratio.
/// (A full polyphase-partitioned, arbitrary-ratio drift-ASRC is the `VariRate`
/// phase; this is the fixed-ratio polyphase primitive.)
pub fn Resampler(comptime num: numeric.Numeric, comptime L: usize, comptime M: usize, comptime HALF: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (L == 0 or M == 0) @compileError("pan: Resampler L and M must be >= 1");
    if (HALF == 0) @compileError("pan: Resampler HALF (taps each side) must be >= 1");
    const up = @max(L, M);
    const TAPS = 2 * HALF + 1;
    if (HALF % M != 0)
        @compileError("pan: Resampler HALF must be a multiple of M so the group delay is an integer number of output samples");
    const proto = sincProto(T, TAPS, HALF, up, L);
    return struct {
        const Self = @This();

        pub const out_per_in = .{ L, M };
        /// Group delay in OUTPUT samples. The linear-phase prototype delays by
        /// `HALF` taps at the upsampled grid; one output sample is `M` upsampled-grid
        /// steps, so the delay is `HALF/M` output samples (integer by the `HALF % M`
        /// check). For the `L = M = 1` probe this is exactly `HALF`.
        pub const algorithmic_latency: usize = HALF / M;
        pub const state_size: usize = @sizeOf(usize);

        // Stateless within a single whole-stream pull: the signal starts at zero,
        // so the FIR's left context is the implicit zero pre-roll. (Cross-call
        // streaming via an input-history ring is folded into the VariRate ASRC of
        // a later phase; this is the fixed-ratio polyphase primitive.)
        _unused: usize = 0,

        pub fn needed_input(self: *Self, want: usize) usize {
            _ = self;
            return (want * M + L - 1) / L; // ceil(want·M/L)
        }

        pub fn pull(self: *Self, in: []const types.Sample(T), want: usize, out: []types.Sample(T)) usize {
            _ = self;
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            var j: usize = 0;
            while (j < want) : (j += 1) {
                // y[j] = Σ_tap proto[tap] · x_up[jM − tap], where the upsampled
                // stream x_up[m] = x[m/L] when L | m, else 0.
                var acc: T = 0;
                var tap: usize = 0;
                while (tap < TAPS) : (tap += 1) {
                    const m = @as(isize, @intCast(j * M)) - @as(isize, @intCast(tap));
                    if (m < 0) continue;
                    if (@mod(m, @as(isize, @intCast(L))) != 0) continue;
                    const in_idx: usize = @intCast(@divFloor(m, @as(isize, @intCast(L))));
                    if (in_idx >= xs.len) continue;
                    acc += proto[tap] * xs[in_idx];
                }
                ys[j] = acc;
            }
            return want;
        }
    };
}

/// Build the windowed-sinc prototype FIR (Hann-windowed, normalized to unity DC
/// gain after polyphase decimation). `up = max(L,M)` is the interpolation factor,
/// cutoff `π/up`; `gain` (= `L`) compensates the polyphase decimation so a DC input
/// passes at unity.
fn sincProto(comptime T: type, comptime TAPS: usize, comptime HALF: usize, comptime up: usize, comptime gain: usize) [TAPS]T {
    @setEvalBranchQuota(TAPS * 64);
    var h: [TAPS]T = undefined;
    const fc: T = 1.0 / @as(T, @floatFromInt(up)); // normalized cutoff (×π)
    var sum: T = 0;
    for (&h, 0..) |*c, i| {
        const n: T = @as(T, @floatFromInt(i)) - @as(T, @floatFromInt(HALF));
        const sinc: T = if (n == 0) fc else @sin(std.math.pi * fc * n) / (std.math.pi * n);
        const wphase = 2.0 * std.math.pi * @as(T, @floatFromInt(i)) / @as(T, @floatFromInt(TAPS - 1));
        const win: T = 0.5 * (1.0 - @cos(wphase));
        c.* = sinc * win;
        sum += sinc * win;
    }
    // Normalize to unity DC gain, then scale by the interpolation gain.
    const g: T = @as(T, @floatFromInt(gain)) / sum;
    for (&h) |*c| c.* *= g;
    return h;
}

// ===========================================================================
// Varispeed — arbitrary-runtime-ratio resampler (VariRate)
// ===========================================================================

/// `Varispeed(num)` — a variable-rate resampler whose out:in ratio is a **live
/// parameter**, not a compile-time constant: a varispeed / scrub / sample-playback
/// pitch control. It is the canonical `VariRate` block — discriminated at comptime
/// not by a point `out_per_in` but by a *bounded rate interval* `rate_bounds`
/// (`{ min, nominal, max }` as `{p, q}` tuples) plus a worst-case `max_latency`.
///
/// **What "bounded interval + worst-case planning" buys you.** The operating ratio
/// can move anywhere in `[min, max]` at runtime, but the static commit plan sizes
/// every buffer and the upstream's per-callback demand on the `min` ratio — the
/// *most* input ever needed to make a given number of outputs — so the footprint
/// stays bounded no matter where the live ratio sits. Latency compensation plans on
/// `max_latency`, the worst delay over the whole interval. Both numbers are fixed at
/// compile time, so a varispeed seam can never silently under-size its input pull.
///
/// **Ratio held per call (no zipper, deterministic sub-blocks).** The operating
/// ratio is sampled exactly **once at the top of each render call** and held across
/// the whole buffer, exactly as any parameter is held — never re-read mid-buffer.
/// That preserves per-call reduction order and makes a sub-block render a strict
/// prefix of a whole-block render. The ratio arrives through `setParam` (the wired
/// parameter edge or an external `set`), so a wired ratio source and a `set` ratio
/// are the same source of the same held value.
///
/// **Determinism.** Driven by a deterministic parameter (automation), the render is
/// a pure function of the input and the ratio schedule — bit-reproducible. (The
/// *other* determinism class — a ratio nudged by a wall-clock drift controller — is
/// inherently empirical and lives in the device-boundary drift resampler, not here.)
///
/// The interpolation is 2-point **linear** between the two bracketing input samples:
/// cheap, low-latency (≤ 1 input sample of lookback), and adequate for varispeed /
/// scrub. A windowed-sinc / cubic kernel is the higher-quality tier and is not
/// implemented here. Mono only (`Sample(T)` is one channel); a multi-channel
/// varispeed would resample each plane with a shared cursor.
pub fn Varispeed(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    requireFloat(T);
    return struct {
        const Self = @This();

        // The bounded out:in interval: 1/4× (slowest, the MOST input per output —
        // the worst-case planning endpoint) up to 4× (fastest). Nominal is 1:1.
        pub const rate_bounds = .{ .min = .{ 1, 4 }, .nominal = .{ 1, 1 }, .max = .{ 4, 1 } };
        const min_ratio: f32 = 0.25;
        const max_ratio: f32 = 4.0;
        /// Worst-case group delay in OUTPUT samples over the whole interval. The
        /// linear interpolator looks back at most one input sample; one input sample
        /// is `ratio` output samples, so the worst case is `max_ratio` output samples
        /// rounded up, plus one sample of slack for the fractional bracket.
        pub const max_latency: usize = 5;
        /// The ratio is a deterministic parameter (automation), so the render is
        /// bit-reproducible — the parameter-driven determinism class.
        pub const ratio_source: enum { parameter, internal_controller } = .parameter;
        /// The operating out:in ratio, as a control-rate parameter port (slot 0).
        pub const params = .{ .ratio = types.Scalar(f32) };

        /// Latest published target ratio (atomic; set by the control thread OR the
        /// wired parameter edge). Read once per call on the RT thread (held-per-call).
        target: control.Param = control.Param.init(1.0),
        /// The previous input sample — the left bracket of the linear interpolation.
        /// Persists across calls so the resampler streams continuously; the implicit
        /// pre-roll is silence (`0`).
        prev: T = 0,
        /// Fractional read position in `[0, 1)` between `prev` and the next input
        /// sample. Persists across calls so a fractional remainder is never dropped.
        frac: f64 = 0,

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.target.set(value);
        }

        /// How many input samples `want` outputs consume at the current held ratio.
        /// One output advances the read cursor by `1/ratio` input samples; from the
        /// current fractional position that is `ceil(frac + want/ratio)`, plus one
        /// guard sample for the bracket so the pull can always fill `want`. Monotone
        /// non-decreasing in `want` and non-increasing in the ratio.
        pub fn needed_input(self: *Self, want: usize) usize {
            const r = clampRatio(self.target.read());
            const step = 1.0 / @as(f64, r);
            const span = self.frac + @as(f64, @floatFromInt(want)) * step;
            return @as(usize, @intFromFloat(@ceil(span))) + 1;
        }

        pub fn pull(self: *Self, in: []const types.Sample(T), want: usize, out: []types.Sample(T)) usize {
            const xs = scalarsConst(T, in);
            const ys = scalars(T, out);
            const r = clampRatio(self.target.read()); // sampled ONCE, held across the call
            const step = 1.0 / @as(f64, r);
            var produced: usize = 0;
            var i: usize = 0; // index of the next-unconsumed input (the right bracket)
            while (produced < want) {
                if (self.frac < 1.0) {
                    // Output reads inside [prev, xs[i]); linear-interpolate. The right
                    // bracket xs[i] is only PEEKED here, not consumed, so the state
                    // resumes cleanly across calls: `prev` is always the last input
                    // actually consumed.
                    if (i >= xs.len) break; // under-fed: stop short of `want`
                    const f: T = @floatCast(self.frac);
                    ys[produced] = self.prev + f * (xs[i] - self.prev);
                    produced += 1;
                    self.frac += step;
                } else {
                    // The read cursor crossed an input boundary: consume xs[i].
                    if (i >= xs.len) break;
                    self.prev = xs[i];
                    i += 1;
                    self.frac -= 1.0;
                }
            }
            return produced;
        }

        /// Clamp a requested ratio into the declared `rate_bounds` interval, so the
        /// measured out:in ratio can never leave `[min, max]` however the parameter
        /// is driven.
        fn clampRatio(v: f32) f32 {
            return @min(@max(v, min_ratio), max_ratio);
        }
    };
}

// ===========================================================================
// TimeStretch — WSOLA time-stretch with a runtime stretch factor (VariRate)
// ===========================================================================

/// `TimeStretch(num, FRAME)` — runtime time-stretching (tempo change WITHOUT pitch
/// change): a `VariRate` SOURCE over an owned mono asset whose output is `stretch`
/// times as long as the input, at a `stretch` factor that varies at runtime.
///
/// It is the **WSOLA** (waveform-similarity overlap-add) realisation. Analysis grains
/// are overlap-added on a fixed 50%-overlap synthesis grid (Hann window, COLA-exact:
/// `win[k] + win[k+FRAME/2] = 1`, so no amplitude normalisation). The variable-rate
/// seam is the *analysis* advance `Sa = (FRAME/2) / stretch`: a larger stretch reads
/// the asset more slowly while the synthesis grid stays fixed, so the output runs
/// longer. The crucial WSOLA step — and the reason this PRESERVES PITCH where a naive
/// overlap-add does not — is that each grain's read position is not taken at the bare
/// nominal advance but **searched within a small window for the offset whose leading
/// half best cross-correlates with the natural continuation of the previous grain**.
/// That alignment keeps the periodic waveform phase-coherent across the overlap, so
/// the output's frequency content is unchanged (only its duration moves). A plain OLA
/// without this search re-introduces a phase jump at every grain boundary and ends up
/// SCALING the frequency (acting as a resampler) instead of stretching time — which
/// is exactly the defect this search removes.
///
/// The stretch factor is a held-per-call `param.stretch` in the bounded interval
/// `[1/2, 2]` (out:in = the stretch), the parameter-driven (reproducible) class. For
/// good low-frequency behaviour `FRAME` should span at least two periods of the
/// lowest tone of interest. Mono.
pub fn TimeStretch(comptime num: numeric.Numeric, comptime FRAME: usize) type {
    const T = num.Lane;
    requireFloat(T);
    if (!isPow2(FRAME) or FRAME < 4)
        @compileError("pan: TimeStretch FRAME must be a power of two >= 4");
    const HS = FRAME / 2; // synthesis hop = 50% overlap (Hann COLA-exact)
    const DELTA: isize = @intCast(HS); // waveform-similarity search radius (± one hop)
    const win = hannWindow(T, FRAME);
    return struct {
        const Self = @This();

        // out:in == the stretch factor, in [1/2, 2]. The `min` endpoint (slowest
        // output per input = the most input per output) is the worst-case planner.
        pub const rate_bounds = .{ .min = .{ 1, 2 }, .nominal = .{ 1, 1 }, .max = .{ 2, 1 } };
        const min_stretch: f32 = 0.5;
        const max_stretch: f32 = 2.0;
        /// One full grain of overlap-add priming delay, in output samples.
        pub const max_latency: usize = FRAME;
        pub const ratio_source: enum { parameter, internal_controller } = .parameter;
        pub const params = .{ .stretch = types.Scalar(f32) };

        /// The owned mono asset (borrowed; set at `add`).
        data: []const types.Sample(T) = &.{},
        /// The nominal next analysis position (accumulates `Sa` per grain); the
        /// similarity search picks the actual read position near `round(nat_pos)`.
        nat_pos: f64 = 0,
        /// The last ACCEPTED integer analysis position (the search anchor — the next
        /// grain aligns to the continuation of the grain read here).
        prev_pos: usize = 0,
        /// False until the first grain has been read (the first grain reads at 0 with
        /// no search; subsequent grains search relative to `prev_pos`).
        started: bool = false,
        /// The second half of the previous grain — the overlap-add carry. Persists.
        tail: [HS]T = [_]T{0} ** HS,
        /// The current grain's finalised first-half output, awaiting emission.
        obuf: [HS]T = [_]T{0} ** HS,
        /// Read cursor into `obuf`; `== HS` means "empty, generate the next grain".
        ohead: usize = HS,
        /// Set once the asset has been fully consumed (further output is silence).
        done: bool = false,
        stretch: control.Param = control.Param.init(1.0),

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.stretch.set(value);
        }

        /// Worst-case input demand at the slowest stretch (1/2× ⇒ two input samples
        /// of asset per output). Documentation parity with the `VariRate` contract.
        pub fn needed_input(_: *Self, want: usize) usize {
            return want * 2;
        }

        /// One asset sample, zero outside the asset (the implicit silent pre/post-roll).
        fn at(self: *const Self, i: isize) T {
            if (i < 0) return 0;
            const u: usize = @intCast(i);
            return if (u < self.data.len) self.data[u].ch[0] else 0;
        }

        /// Normalised cross-correlation of the `HS`-sample segment at `a` against the
        /// target segment at `b` — the waveform-similarity score WSOLA maximises.
        fn similarity(self: *const Self, a: isize, b: isize) f64 {
            var dot: f64 = 0;
            var ea: f64 = 0;
            var eb: f64 = 0;
            var k: usize = 0;
            while (k < HS) : (k += 1) {
                const va: f64 = self.at(a + @as(isize, @intCast(k)));
                const vb: f64 = self.at(b + @as(isize, @intCast(k)));
                dot += va * vb;
                ea += va * va;
                eb += vb * vb;
            }
            const denom = @sqrt(ea * eb);
            return if (denom > 1e-20) dot / denom else 0;
        }

        /// Pick the read position near `center` whose leading half best matches the
        /// continuation of the previous grain (`asset[prev_pos+HS ..]`), searching
        /// `±DELTA`. This is the phase-coherence step that makes WSOLA pitch-preserving.
        fn searchPos(self: *const Self, center: isize) usize {
            const target: isize = @as(isize, @intCast(self.prev_pos)) + @as(isize, @intCast(HS));
            var best_delta: isize = 0;
            var best_score: f64 = -2;
            var delta: isize = -DELTA;
            while (delta <= DELTA) : (delta += 1) {
                const score = self.similarity(center + delta, target);
                if (score > best_score) {
                    best_score = score;
                    best_delta = delta;
                }
            }
            const pos = center + best_delta;
            return if (pos < 0) 0 else @intCast(pos);
        }

        /// Read one windowed analysis grain (at the WSOLA-aligned position), overlap-add
        /// its first half with the carried `tail` into `obuf`, stash its second half as
        /// the new `tail`, and advance the nominal analysis cursor by `Sa = HS/stretch`.
        fn genGrain(self: *Self, s: f32) void {
            const sa = @as(f64, HS) / @as(f64, @max(s, min_stretch));
            var pos: usize = 0;
            if (!self.started) {
                self.started = true;
                self.nat_pos = sa;
            } else {
                pos = self.searchPos(@intFromFloat(@round(self.nat_pos)));
                self.nat_pos += sa;
            }
            const p: isize = @intCast(pos);
            var k: usize = 0;
            while (k < HS) : (k += 1) {
                const head = win[k] * self.at(p + @as(isize, @intCast(k)));
                self.obuf[k] = self.tail[k] + head; // 50% Hann COLA: tail + head = unity
                self.tail[k] = win[HS + k] * self.at(p + @as(isize, @intCast(HS + k)));
            }
            self.prev_pos = pos;
            self.ohead = 0;
            if (pos + FRAME >= self.data.len) self.done = true;
        }

        pub fn pull(self: *Self, want: usize, out: []types.Sample(T)) usize {
            const s = @min(@max(self.stretch.read(), min_stretch), max_stretch); // held per call
            var produced: usize = 0;
            while (produced < want) : (produced += 1) {
                if (self.ohead >= HS) {
                    if (self.done) {
                        out[produced].ch[0] = 0;
                        continue;
                    }
                    self.genGrain(s);
                }
                out[produced].ch[0] = self.obuf[self.ohead];
                self.ohead += 1;
            }
            return produced;
        }

        pub fn exhausted(self: *Self) bool {
            return self.done and self.ohead >= HS;
        }
    };
}

// ===========================================================================
// PitchShift — constant-duration pitch shift (TSM ∘ resample)
// ===========================================================================

/// `PitchShift(num, FRAME)` — shift pitch WITHOUT changing duration, by composing the
/// two variable-rate primitives: time-stretch by the pitch factor `P` (longer, same
/// pitch) then resample by `1/P` (back to the original duration, which slides the
/// pitch up by `P`). Net effect: same length, pitch scaled by `P`.
///
/// Because the net out:in rate is exactly 1:1 (duration is preserved), the COMPOSITE
/// is itself rate-preserving — a `Map` SOURCE — even though it is built from two
/// `VariRate` stages internally (a `TimeStretch` and a linear resampler). It owns the
/// inner `TimeStretch` and a 2-point resampling cursor over its output. `param.pitch`
/// (held per call) is the spectral shift factor in `[1/2, 2]` (an octave down to an
/// octave up). Quality inherits the OLA `TimeStretch` tier (phase-blurring on tonal
/// material); a phase-vocoder front-end is the fidelity upgrade.
pub fn PitchShift(comptime num: numeric.Numeric, comptime FRAME: usize) type {
    const T = num.Lane;
    requireFloat(T);
    const Inner = TimeStretch(num, FRAME);
    return struct {
        const Self = @This();
        const min_pitch: f32 = 0.5;
        const max_pitch: f32 = 2.0;

        pub const params = .{ .pitch = types.Scalar(f32) };

        /// The owned mono asset (borrowed; set at `add`). Forwarded to the inner
        /// time-stretch on first use.
        data: []const types.Sample(T) = &.{},
        /// The time-stretch stage (stretches by the pitch factor).
        inner: Inner = .{},
        /// The resample-by-1/P stage's linear-interpolation brackets + phase. The
        /// resampler reads the stretched stream at a step of `P` input-per-output.
        prev: T = 0,
        cur: T = 0,
        frac: f64 = 0,
        primed: bool = false,
        pitch: control.Param = control.Param.init(1.0),

        pub fn setParam(self: *Self, slot: u8, value: f32) void {
            if (slot == 0) self.pitch.set(value);
        }

        /// Pull one sample from the inner time-stretch stage.
        fn innerOne(self: *Self) T {
            var tmp: [1]types.Sample(T) = undefined;
            _ = self.inner.pull(1, &tmp);
            return tmp[0].ch[0];
        }

        pub fn process(self: *Self, out: []types.Sample(T)) void {
            const p = @min(@max(self.pitch.read(), min_pitch), max_pitch); // held per call
            self.inner.data = self.data; // forward the asset (idempotent)
            self.inner.setParam(0, p); // time-stretch by P (longer, same pitch)
            if (!self.primed) {
                self.prev = self.innerOne();
                self.cur = self.innerOne();
                self.primed = true;
            }
            const step = @as(f64, p); // resample read step = P (slides pitch up by P)
            for (out) |*o| {
                while (self.frac >= 1.0) {
                    self.prev = self.cur;
                    self.cur = self.innerOne();
                    self.frac -= 1.0;
                }
                const f: T = @floatCast(self.frac);
                o.ch[0] = self.prev + f * (self.cur - self.prev);
                self.frac += step;
            }
        }
    };
}

const testing = std.testing;
const f32num = numeric.numericFor(.f32, .{});

test "Resampler L=M=1 is a linear-phase FIR with group delay HALF (latency probe)" {
    const HALF = 8;
    var rs = Resampler(f32num, 1, 1, HALF){};
    const N = 64;
    var in: [N]types.Sample(f32) = undefined;
    for (&in) |*s| s.ch[0] = 0;
    in[0].ch[0] = 1; // unit impulse
    var out: [N]types.Sample(f32) = undefined;
    _ = rs.pull(&in, N, &out);
    // The impulse response peaks at the prototype centre = HALF.
    var peak: usize = 0;
    var peak_v: f32 = 0;
    for (out, 0..) |s, i| {
        if (@abs(s.ch[0]) > peak_v) {
            peak_v = @abs(s.ch[0]);
            peak = i;
        }
    }
    try testing.expectEqual(@as(usize, HALF), peak);
    try testing.expectEqual(@as(usize, HALF), @as(usize, Resampler(f32num, 1, 1, HALF).algorithmic_latency));
}
