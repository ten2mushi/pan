//! Control-side generators — the modulation *producers* that drive parameter
//! ports. The first is `Lfo`.
//!
//! A **parameter port** carries a *control element* (`Scalar(f32)`) — a node's
//! coefficient, one value per render call — as opposed to a sample port, which
//! carries a length-`N` window of a stream. A **control producer is a
//! zero-sample-input `Map` source emitting `Scalar(f32)`**: it has no input slice
//! (so it classifies as a Source — a path head), and its output element is the
//! control element, not an audio `Sample`. Wired into a consumer's
//! `node.param.<name>` it is the *in-graph analogue of the external `set` verb*:
//! each render call it emits **one control value**, the commit pass colors its
//! control buffer, and the executor reads that value (the producer buffer's first
//! lane) and hands it to the consumer's `setParam`, which **holds and per-block
//! ramps** it exactly as it ramps a `set` target. Because the wired edge and an
//! external `set` both arrive through the SAME `setParam`/ramp, a wired LFO sweep
//! is **bit-identical** to the same sweep pushed through `set`.
//!
//! Two mechanical facts of the parameter-port substrate this honours:
//!
//!   * The buffer-sizing pass sizes the producer's output buffer at the consumer's
//!     per-callback demand (`want == N` for a rate-1:1 consumer), and the executor
//!     finite-checks **every** lane of an output buffer (the NaN/Inf "poison" guard
//!     that silences a corrupt buffer). So a control producer **fills its whole
//!     `out` slice** with the block's single control value (a broadcast) — never
//!     leaving lanes undefined, which the guard would flag — while the consumer
//!     reads only the first lane. The control value is therefore one-per-call in
//!     *semantics*, broadcast in *storage*.
//!   * `out.len` is the block size `N`, so a generator learns the block length from
//!     its output slice and advances its phase by `out.len` samples per call — it
//!     needs no separate `N`. The LFO is sampled at **control rate** (once per
//!     block); the consumer's per-block ramp interpolates between successive values,
//!     so the modulation is zipper-free.

const std = @import("std");
const types = @import("types.zig");

/// The LFO output value at normalized phase `p ∈ [0, 1)`, before `amplitude`/
/// `offset` scaling. `sine` is the only bandlimited member; `triangle`/`saw`/
/// `square` are the naive (aliasing) shapes — fine for a control-rate modulator
/// whose output is sampled once per block and ramped, never summed into audio.
pub const Waveform = enum { sine, triangle, saw, square };

/// `Lfo` — a control-rate low-frequency oscillator: a zero-sample-input `Map`
/// source emitting `Scalar(f32)` to drive a parameter port (`connect(lfo, x.param.cutoff)`).
///
///   value = offset + amplitude · wave(phase)
///
/// `increment` is the phase step **per sample** in cycles (the author converts
/// from Hz with `freq / sample_rate`, mirroring how `Gain` takes a linear
/// coefficient and `Biquad` takes raw coefficients — block data, not stream type).
/// The phase advances by `out.len · increment` cycles each render call, wrapping in
/// `[0, 1)`. Set `offset`/`amplitude` to map the unit wave onto the parameter's
/// range (e.g. a cutoff sweep `offset = (hi+lo)/2`, `amplitude = (hi−lo)/2`).
///
/// It declares no parameter ports of its own (its rate/depth are construction
/// fields): an LFO is a pure generator — a Source (zero sample inputs), so it may
/// root a path.
pub const Lfo = struct {
    const Self = @This();

    /// Phase in cycles, kept in `[0, 1)`. Persistent state across calls.
    phase: f32 = 0,
    /// Phase step per sample, in cycles: `frequency / sample_rate`.
    increment: f32 = 0,
    /// Output amplitude (half the peak-to-peak swing of the unit wave).
    amplitude: f32 = 1,
    /// Output DC offset (the centre of the swing).
    offset: f32 = 0,
    /// Which waveform to emit.
    waveform: Waveform = .sine,

    /// Evaluate the unit waveform at phase `p ∈ [0, 1)`, range `[-1, 1]`.
    fn wave(wf: Waveform, p: f32) f32 {
        return switch (wf) {
            .sine => @sin(2.0 * std.math.pi * p),
            // Triangle: −1 at p=0, +1 at p=0.5, back to −1 at p→1.
            .triangle => if (p < 0.5) (4.0 * p - 1.0) else (3.0 - 4.0 * p),
            .saw => 2.0 * p - 1.0,
            .square => if (p < 0.5) @as(f32, 1) else @as(f32, -1),
        };
    }

    /// Emit this block's single control value (the wave sampled at the current
    /// block-start phase), broadcast across the whole control buffer, then advance
    /// the phase by `out.len` samples. The consumer reads the first lane and ramps
    /// to it; the broadcast keeps every lane finite for the executor's poison guard.
    pub fn process(self: *Self, out: []types.Scalar(f32)) void {
        const v = self.offset + self.amplitude * wave(self.waveform, self.phase);
        for (out) |*o| o.value = v;
        // Advance phase by the block length and wrap into [0, 1).
        var p = self.phase + self.increment * @as(f32, @floatFromInt(out.len));
        p -= @floor(p);
        self.phase = p;
    }
};

test "Lfo: classifies as a zero-input Scalar source" {
    const port = @import("port.zig");
    try std.testing.expect(port.classify(Lfo) == .Map);
    try std.testing.expect(comptime port.isSource(Lfo));
    try std.testing.expect(port.MapOutPort(Lfo).Elem == types.Scalar(f32));
}

test "Lfo: sine emits offset+amplitude*sin and advances phase by out.len" {
    var lfo: Lfo = .{ .increment = 0.01, .amplitude = 2, .offset = 10, .waveform = .sine };
    var out: [4]types.Scalar(f32) = undefined;

    // Block 0: phase 0 → sin(0)=0 → value = offset.
    lfo.process(&out);
    for (out) |o| try std.testing.expectEqual(@as(f32, 10), o.value);
    // Phase advanced by out.len·increment = 4·0.01 = 0.04.
    try std.testing.expectApproxEqAbs(@as(f32, 0.04), lfo.phase, 1e-6);

    // Block 1: value = 10 + 2·sin(2π·0.04).
    lfo.process(&out);
    const expect = 10.0 + 2.0 * @sin(2.0 * std.math.pi * 0.04);
    for (out) |o| try std.testing.expectApproxEqAbs(@as(f32, expect), o.value, 1e-6);
}

test "Lfo: square and saw stay in range, phase wraps in [0,1)" {
    var sq: Lfo = .{ .increment = 0.3, .waveform = .square };
    var out: [1]types.Scalar(f32) = undefined;
    // Run several blocks; the wrap keeps phase bounded and the square in {-1,1}.
    var k: usize = 0;
    while (k < 10) : (k += 1) {
        sq.process(&out);
        try std.testing.expect(out[0].value == 1 or out[0].value == -1);
        try std.testing.expect(sq.phase >= 0 and sq.phase < 1);
    }
}
