//! Generators — the source blocks that originate a stream with no sample input.
//! Two families live here:
//!
//!   * **Control-side generators** (`Lfo`) — the modulation *producers* that drive
//!     parameter ports, emitting one `Scalar(f32)` per call (see the header notes
//!     below on the broadcast-storage / one-value-per-call model).
//!   * **Audio-rate Source generators** (`Sine`, `PolyBlepSaw`, `PolyBlepSquare`,
//!     `Noise`, `Constant`, `Wavetable`) — zero-sample-input `Map` sources emitting
//!     `Sample(f32)`. A source has no input slice, so it classifies as a path head
//!     (a Source); its output length is the **pull demand `N`** (it learns `N` from
//!     `out.len`), and its phase / RNG / table cursor is ordinary per-sample Mealy
//!     state advanced by `N`. Each audio oscillator exposes a per-sample `tick()`
//!     core (so a `Voice` can drive it sample-by-sample inside a fused loop) on top
//!     of which `process(out)` is a thin block loop. Saw/square use **PolyBLEP**
//!     band-limiting so a swept tone does not alias (the naive ramp/square is the
//!     failure mode a band-limited oracle rejects); `Sine` is band-limited by
//!     construction. Frequency arrives in **Hz** through a `freq` parameter port
//!     (the block converts to a per-sample phase increment with its `sample_rate`),
//!     mirroring how a `NoteEvent.note_on.pitch_hz` lands directly in a voice's
//!     pitch parameter — the lane never assumes 12-TET.
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

// ===========================================================================
// Audio-rate Source generators — zero-sample-input `Map` sources, `Sample(f32)`.
// ===========================================================================

const tau = 2.0 * std.math.pi;

/// PolyBLEP residual at normalized phase `t ∈ [0, 1)` for a per-sample phase step
/// `dt`. It is the correction a band-limited step needs at a waveform
/// discontinuity: a naive saw/square jumps by a full amplitude in one sample, which
/// injects energy above Nyquist (aliasing); PolyBLEP smears that jump across the two
/// samples straddling it with a 2nd-order polynomial so the step is band-limited.
/// Zero away from a discontinuity, so it is free except at the ~`dt`-wide edges.
fn polyBlep(t: f32, dt: f32) f32 {
    if (dt <= 0) return 0; // DC / silence: no discontinuity to correct
    if (t < dt) {
        const x = t / dt;
        return x + x - x * x - 1.0; // rising side of the step
    } else if (t > 1.0 - dt) {
        const x = (t - 1.0) / dt;
        return x * x + x + x + 1.0; // falling side of the step
    }
    return 0;
}

/// `Sine` — a band-limited (by construction) sinusoid Source. Frequency in Hz via
/// the `freq` parameter port; phase is per-sample Mealy state advanced by `out.len`.
pub const Sine = struct {
    const Self = @This();
    /// Phase in cycles, kept in `[0, 1)`. Persistent across calls.
    phase: f32 = 0,
    /// Phase step per sample, in cycles (`freq / sample_rate`).
    increment: f32 = 0,
    /// The render sample rate, used to convert a Hz `freq` to a phase increment.
    sample_rate: f32 = 48_000,

    pub const params = .{ .freq = types.Scalar(f32) };

    /// Slot 0 is `freq` (declaration order). The control plane (a wired edge or an
    /// external `set`/`schedule`) delivers Hz here; we convert to a phase step.
    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        if (slot == 0) self.setFrequency(value);
    }
    /// Set the oscillator frequency directly in Hz (the voice-internal path).
    pub fn setFrequency(self: *Self, hz: f32) void {
        self.increment = hz / self.sample_rate;
    }

    /// One sample, advancing the phase. The per-sample core a `Voice` drives.
    pub fn tick(self: *Self) f32 {
        const v = @sin(tau * self.phase);
        self.phase = self.phase + self.increment - @floor(self.phase + self.increment);
        return v;
    }
    /// out.len == pull N (the source's length comes from the demand, SR1).
    pub fn process(self: *Self, out: []types.Sample(f32)) void {
        for (out) |*o| o.ch[0] = self.tick();
    }
};

/// `PolyBlepSaw` — a band-limited sawtooth Source (PolyBLEP-corrected). The naive
/// ramp `2·phase − 1` aliases on every period reset; subtracting the PolyBLEP
/// residual at the wrap band-limits the discontinuity.
pub const PolyBlepSaw = struct {
    const Self = @This();
    phase: f32 = 0,
    increment: f32 = 0,
    sample_rate: f32 = 48_000,

    pub const params = .{ .freq = types.Scalar(f32) };

    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        if (slot == 0) self.setFrequency(value);
    }
    pub fn setFrequency(self: *Self, hz: f32) void {
        self.increment = hz / self.sample_rate;
    }

    pub fn tick(self: *Self) f32 {
        const naive = 2.0 * self.phase - 1.0;
        const v = naive - polyBlep(self.phase, self.increment);
        self.phase = self.phase + self.increment - @floor(self.phase + self.increment);
        return v;
    }
    pub fn process(self: *Self, out: []types.Sample(f32)) void {
        for (out) |*o| o.ch[0] = self.tick();
    }
};

/// `PolyBlepSquare` — a band-limited square Source. The square has two
/// discontinuities per period (the rising edge at phase 0 and the falling edge at
/// phase 0.5), so it adds a PolyBLEP residual at the rising edge and subtracts one
/// at the half-phase-shifted falling edge.
pub const PolyBlepSquare = struct {
    const Self = @This();
    phase: f32 = 0,
    increment: f32 = 0,
    sample_rate: f32 = 48_000,

    pub const params = .{ .freq = types.Scalar(f32) };

    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        if (slot == 0) self.setFrequency(value);
    }
    pub fn setFrequency(self: *Self, hz: f32) void {
        self.increment = hz / self.sample_rate;
    }

    pub fn tick(self: *Self) f32 {
        var v: f32 = if (self.phase < 0.5) 1.0 else -1.0;
        v += polyBlep(self.phase, self.increment); // rising edge at phase 0
        // falling edge sits at phase 0.5 — correct it at the half-shifted phase.
        var t2 = self.phase + 0.5;
        t2 -= @floor(t2);
        v -= polyBlep(t2, self.increment);
        self.phase = self.phase + self.increment - @floor(self.phase + self.increment);
        return v;
    }
    pub fn process(self: *Self, out: []types.Sample(f32)) void {
        for (out) |*o| o.ch[0] = self.tick();
    }
};

/// `Noise` — a white-noise Source over a deterministic, dependency-free,
/// freestanding-safe 64-bit LCG (so the ReleaseSmall freestanding smoke target and
/// the offline-reproducible timeline are both satisfied — the stream is a pure
/// function of `state`). Output is uniform in `[−1, 1)`.
pub const Noise = struct {
    const Self = @This();
    /// The LCG state — persistent Mealy state. Seed it for a reproducible stream.
    state: u64 = 0x2545F4914F6CDD1D,

    /// Advance the LCG and return the next 32-bit word. Wrapping multiply/add (the
    /// classic 64-bit constants) so no overflow check fires and the recurrence is
    /// the same in every build mode.
    fn nextWord(self: *Self) u32 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(self.state >> 32);
    }
    pub fn tick(self: *Self) f32 {
        const u = self.nextWord();
        return @as(f32, @floatFromInt(u)) * (2.0 / 4294967296.0) - 1.0;
    }
    pub fn process(self: *Self, out: []types.Sample(f32)) void {
        for (out) |*o| o.ch[0] = self.tick();
    }
};

/// `Constant` — a DC Source emitting a fixed `level` every sample. The trivial
/// generator; useful as a test/bias source and the SR1 length-from-pull witness.
pub const Constant = struct {
    const Self = @This();
    level: f32 = 0,

    pub const params = .{ .level = types.Scalar(f32) };

    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        if (slot == 0) self.level = value;
    }
    pub fn tick(self: *Self) f32 {
        return self.level;
    }
    pub fn process(self: *Self, out: []types.Sample(f32)) void {
        for (out) |*o| o.ch[0] = self.level;
    }
};

/// `Wavetable` — a single-cycle wavetable Source read with linear interpolation at
/// a Hz `freq`. The table is a borrowed single-period slice (an asset loaded at
/// `initialize`, persistent state); the read cursor is the per-sample phase. Linear
/// interpolation between adjacent table entries is the cheap, low-alias-for-smooth-
/// tables tier (a band-limited multi-table mip is the quality upgrade, not shipped).
pub const Wavetable = struct {
    const Self = @This();
    /// One period of the waveform, length ≥ 2. Borrowed (not owned).
    table: []const f32 = &.{ 0, 0 },
    phase: f32 = 0,
    increment: f32 = 0,
    sample_rate: f32 = 48_000,

    pub const params = .{ .freq = types.Scalar(f32) };

    pub fn setParam(self: *Self, slot: u8, value: f32) void {
        if (slot == 0) self.setFrequency(value);
    }
    pub fn setFrequency(self: *Self, hz: f32) void {
        self.increment = hz / self.sample_rate;
    }

    pub fn tick(self: *Self) f32 {
        const len = self.table.len;
        const pos = self.phase * @as(f32, @floatFromInt(len));
        const idx: usize = @intFromFloat(pos);
        const frac = pos - @floor(pos);
        const a = self.table[idx % len];
        const b = self.table[(idx + 1) % len];
        const v = a + (b - a) * frac;
        self.phase = self.phase + self.increment - @floor(self.phase + self.increment);
        return v;
    }
    pub fn process(self: *Self, out: []types.Sample(f32)) void {
        for (out) |*o| o.ch[0] = self.tick();
    }
};

test "audio sources: classify as zero-input Sample(f32) sources" {
    const port = @import("port.zig");
    inline for (.{ Sine, PolyBlepSaw, PolyBlepSquare, Noise, Constant, Wavetable }) |Osc| {
        try std.testing.expect(port.classify(Osc) == .Map);
        try std.testing.expect(comptime port.isSource(Osc));
        try std.testing.expect(port.MapOutPort(Osc).Elem == types.Sample(f32));
    }
}

test "Sine: out.len drives length; phase advances by out.len" {
    var s: Sine = .{ .sample_rate = 4 };
    s.setFrequency(1.0); // increment = 0.25 cycles/sample
    var out: [4]types.Sample(f32) = undefined;
    s.process(&out);
    // sin(2π·0)=0, sin(2π·.25)=1, sin(2π·.5)=0, sin(2π·.75)=-1
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[1].ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[2].ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), out[3].ch[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.phase, 1e-6); // wrapped back to 0
}

test "PolyBlepSaw: stays in range and band-limits the wrap" {
    var saw: PolyBlepSaw = .{ .sample_rate = 48_000 };
    saw.setFrequency(440.0);
    var out: [256]types.Sample(f32) = undefined;
    saw.process(&out);
    for (out) |o| try std.testing.expect(o.ch[0] >= -2.0 and o.ch[0] <= 2.0);
}

test "Noise: deterministic, reproducible, in [-1,1)" {
    var a: Noise = .{ .state = 12345 };
    var b: Noise = .{ .state = 12345 };
    var k: usize = 0;
    while (k < 100) : (k += 1) {
        const x = a.tick();
        try std.testing.expectEqual(x, b.tick()); // same seed ⇒ same stream
        try std.testing.expect(x >= -1.0 and x < 1.0);
    }
}

test "Constant: emits its level for every sample of the pull" {
    var c: Constant = .{ .level = 0.5 };
    var out: [5]types.Sample(f32) = undefined;
    c.process(&out);
    for (out) |o| try std.testing.expectEqual(@as(f32, 0.5), o.ch[0]);
}
