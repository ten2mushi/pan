//! The synthesis library — the Instrument graph shape's building blocks: the typed
//! event lane, the blessed `NoteEvent` union, a worked `Voice`, and the
//! fixed-capacity intra-block polyphony block `PolyVoice`.
//!
//! ## The typed event lane
//!
//! An **event lane** runs parallel to the sample lanes. It is `EventLane(Event)`,
//! parameterised by a comptime `Event` type the consuming block chooses — exactly
//! as a sample port is element-generic. It carries a **time-sorted** list of
//! `(sample_offset, event)` pairs for the current render block. A block consumes a
//! lane by declaring an `EventLane(Event)` parameter in its `process`/`pull`
//! signature alongside (or instead of) its sample ports; the executor delivers the
//! lane out-of-band from the engine's per-node event store (the same way a `set`
//! value arrives out-of-band), so the event lane is **neither a pooled sample edge
//! nor a parameter port** and the static op-list stays unconditional — one op per
//! node, every callback. The port machinery skips the lane param, so a block whose
//! only "input" is an event lane is still a zero-sample-input **Source** that roots
//! its path.
//!
//! **Sample-accurate onsets without splitting the op-list.** Sample-accurate event
//! response is the consuming block's own job: it walks its sorted events and renders
//! the sub-segments between offsets (render `[0,k)`, apply the event, render
//! `[k,N)`). Because a generator/`Map` is pure over a sub-range, this internal
//! sub-block split is free and does not perturb the schedule — exactly the fused
//! tight-feedback-kernel discipline (an opaque internal loop, not a graph-op split).
//!
//! ## Polyphony is intra-block, fixed-capacity
//!
//! The render op-list is static and unconditional, so a note-on **cannot** spawn a
//! graph node on the audio thread. Dynamic-cardinality polyphony therefore lives
//! inside **one** fixed-capacity block: `PolyVoice(Voice, Vmax)` owns `Vmax` voice
//! slots as persistent state (allocated once, never on the audio thread), a
//! note→slot allocator (steal the oldest/quietest when full, retriggered in place so
//! the steal is click-free), and a summing mixer. `Vmax` is comptime, so the voice
//! pool is a commit/comptime-constant footprint and the block is a single static op
//! — a note-on allocates a *slot*, never a node.

const std = @import("std");
const core = @import("pan_core");
const types = core.types;
const port = core.port;
const event_types = core.events;

const Sample = types.Sample;

// ===========================================================================
// The typed event lane + the blessed NoteEvent
// ===========================================================================

/// Re-exports of the core event data types (defined in `events.zig`) so that
/// `synth.ExprAxis` / `synth.NoteEvent` / `synth.Timed` / `synth.max_events_per_block`
/// keep resolving for callers and for this file's own DSP-facing code.
pub const ExprAxis = event_types.ExprAxis;
pub const NoteEvent = event_types.NoteEvent;
pub const Timed = event_types.Timed;
pub const max_events_per_block = event_types.max_events_per_block;

/// `EventLane(Event)` — the event-type-generic lane a block consumes. It is a thin
/// read-only view over a **time-sorted** slice of `Timed(Event)` for the current
/// block; the consuming block walks it to render sub-block-accurate responses. The
/// `is_event_lane` marker is what the port machinery keys on to skip the lane param
/// (it is delivered out-of-band, not as a pooled buffer), and `Event` exposes the
/// element type so the executor can build the lane it hands the block.
pub fn EventLane(comptime EventT: type) type {
    return struct {
        const Self = @This();
        /// The current block's events, sorted by non-decreasing `sample_offset`.
        items: []const Timed(EventT) = &.{},

        /// The event element type (read by the executor's lane builder).
        pub const Event = EventT;
        /// Marker: this param is an event lane (the port scanners skip it).
        pub const is_event_lane = true;

        /// An empty lane — no events this block.
        pub const empty: Self = .{ .items = &.{} };

        /// Build a lane over a pre-sorted slice of timed events.
        pub fn fromSorted(items: []const Timed(EventT)) Self {
            return .{ .items = items };
        }

        /// How many events this block carries.
        pub fn len(self: Self) usize {
            return self.items.len;
        }
    };
}

// ===========================================================================
// The Voice contract + a worked SawVoice
// ===========================================================================

/// Compile-time check that `Voice` satisfies the contract `PolyVoice` drives. A
/// voice is an internal sub-block (persistent state, not a graph node), so the
/// contract is a set of methods `PolyVoice` calls directly:
///
///   * `noteOn(*Voice, pitch_hz: f32, velocity: f32) void` — (re)trigger. A
///     retrigger of a still-sounding voice MUST be click-free (attack from the
///     current envelope level, phase continuous), which is what makes voice-stealing
///     click-free.
///   * `noteOff(*Voice) void` — begin the release segment.
///   * `renderAdd(*Voice, out: []Sample(f32)) void` — render `out.len` samples and
///     **add** them into `out` (the voice does its own summing into the mix).
///   * `isActive(*const Voice) bool` — is the voice still sounding (occupies its
///     slot)? A voice goes inactive when its release completes.
///
/// Optional (gated by `@hasDecl`): `setExpression(*Voice, ExprAxis, f32)`,
/// `setPressure(*Voice, f32)`, `setBend(*Voice, f32)`, and `level(*const Voice) f32`
/// (a current-amplitude probe used by the `.quietest` steal policy).
pub fn requireVoice(comptime Voice: type) void {
    comptime {
        for (.{ "noteOn", "noteOff", "renderAdd", "isActive" }) |m| {
            if (!@hasDecl(Voice, m))
                @compileError("pan: " ++ @typeName(Voice) ++ " is not a Voice — missing method `" ++ m ++ "`");
        }
    }
}

const gen = @import("../generation/gen.zig");

/// `SawVoice` — a worked single voice realising the canonical subtractive-synth
/// chain `osc → env → filter → VCA`, flattened into one struct: a band-limited
/// (PolyBLEP) sawtooth oscillator, a per-sample ADSR amplitude envelope, a one-pole
/// lowpass tone filter, and a velocity-scaled amplifier (the VCA). The oscillator's
/// phase, the envelope's `(stage, level)`, and the filter's state are its persistent
/// state; `renderAdd` runs the fused per-sample loop. A retrigger attacks from the
/// current envelope level with the oscillator phase and filter state left running,
/// so stealing this voice is click-free. (The filter defaults near-open, so the
/// voice's raw saw character is preserved unless `cutoff_hz` is lowered.)
pub const SawVoice = struct {
    const Self = @This();

    osc: gen.PolyBlepSaw = .{},

    /// Per-sample envelope increments (author converts from seconds with
    /// `1/(seconds·sample_rate)`) and the sustain plateau.
    attack_inc: f32 = 0.01,
    decay_inc: f32 = 0.001,
    sustain: f32 = 0.7,
    release_inc: f32 = 0.0005,

    /// One-pole lowpass tone-filter cutoff in Hz (the `filter` stage). Defaults
    /// near-Nyquist so the filter is nearly transparent until lowered.
    cutoff_hz: f32 = 18_000,
    /// The filter's persistent state (last lowpass output).
    lp: f32 = 0,

    /// The render sample rate, propagated to the oscillator.
    sample_rate: f32 = 48_000,

    level: f32 = 0,
    velocity: f32 = 0,
    stage: Stage = .idle,

    pub const Stage = enum { idle, attack, decay, sustain, release };

    pub fn noteOn(self: *Self, pitch_hz: f32, velocity: f32) void {
        self.osc.sample_rate = self.sample_rate;
        self.osc.setFrequency(pitch_hz);
        self.velocity = velocity;
        // Attack from the CURRENT level (not 0): a retrigger of a sounding voice has
        // no amplitude discontinuity, so stealing is click-free.
        self.stage = .attack;
    }

    pub fn noteOff(self: *Self) void {
        if (self.stage != .idle) self.stage = .release;
    }

    pub fn isActive(self: *const Self) bool {
        return self.stage != .idle;
    }

    /// The current output amplitude (for the `.quietest` steal policy).
    pub fn levelProbe(self: *const Self) f32 {
        return self.level;
    }

    fn stepEnv(self: *Self) void {
        switch (self.stage) {
            .idle => {},
            .attack => {
                self.level += self.attack_inc;
                if (self.level >= 1.0) {
                    self.level = 1.0;
                    self.stage = .decay;
                }
            },
            .decay => {
                self.level -= self.decay_inc;
                if (self.level <= self.sustain) {
                    self.level = self.sustain;
                    self.stage = .sustain;
                }
            },
            .sustain => self.level = self.sustain,
            .release => {
                self.level -= self.release_inc;
                if (self.level <= 0.0) {
                    self.level = 0.0;
                    self.stage = .idle;
                }
            },
        }
    }

    /// Render `out.len` samples and ADD into `out`: the per-sample chain is
    /// `saw(phase) → one-pole lowpass → · env_level · velocity`, with the oscillator,
    /// filter, and envelope advanced one step per sample (so the voice continues
    /// seamlessly across sub-block segments — phase, filter, and envelope all carry).
    pub fn renderAdd(self: *Self, out: []Sample(f32)) void {
        // One-pole lowpass coefficient a = 1 − e^(−2π·fc/fs): the fraction of the
        // input-minus-state step the filter takes each sample.
        const a: f32 = 1.0 - @exp(-2.0 * std.math.pi * self.cutoff_hz / self.sample_rate);
        for (out) |*o| {
            const s = self.osc.tick(); // osc
            self.lp += a * (s - self.lp); // filter (one-pole LP)
            o.ch[0] += self.velocity * self.level * self.lp; // env · VCA
            self.stepEnv();
        }
    }
};

// ===========================================================================
// PolyVoice — fixed-capacity intra-block polyphony
// ===========================================================================

/// Which voice to reuse when a note-on arrives with every slot busy.
pub const StealPolicy = enum {
    /// Reuse the voice that has been sounding longest.
    oldest,
    /// Reuse the voice with the lowest current amplitude (needs `Voice.levelProbe`).
    quietest,
};

/// `PolyVoice(Voice, Vmax)` — fixed-capacity intra-block polyphony as a single
/// static op. It owns `Vmax` persistent `Voice` slots, a note→slot allocator, and a
/// summing mixer; it consumes an `EventLane(NoteEvent)` and renders mono audio.
///
/// **Fused realisation** (preferred for large `Vmax`): the render loop iterates the
/// `Vmax` slots and **skips inactive voices** — a block-internal `for active voices`
/// loop, NOT a graph-op skip, so the static unconditional op-list is intact (only
/// sounding voices cost CPU). `Vmax` comptime ⇒ the footprint is a commit constant.
///
/// **Allocation & click-free stealing.** A `note_on` takes a free slot if one
/// exists; otherwise it steals (oldest, or quietest if the voice exposes
/// `levelProbe`) and **retriggers that voice in place** — the voice attacks from its
/// current envelope level with its oscillator phase running, so the steal introduces
/// no amplitude discontinuity. A fresh slot is reset to the configured `prototype`
/// first. `note_off`/`pressure`/`expression` route by `note_id` to the owning slot.
///
/// **Sample-accurate onsets.** `process` walks the time-sorted lane and renders the
/// sub-segments between event offsets, applying each event at its boundary — so a
/// note lands exactly on its declared `sample_offset` without splitting the op-list.
pub fn PolyVoice(comptime Voice: type, comptime Vmax: usize) type {
    requireVoice(Voice);
    return struct {
        const Self = @This();

        /// The configured template every freshly-allocated voice is reset to (its
        /// ADSR shape / oscillator config). Set once at construction.
        prototype: Voice = .{},
        /// The voice-stealing policy when all `Vmax` slots are busy.
        steal: StealPolicy = .oldest,

        /// The persistent voice pool (`Vmax` comptime ⇒ bounded footprint).
        voices: [Vmax]Voice = [_]Voice{.{}} ** Vmax,
        /// The `note_id` each slot is currently sounding (for MPE routing).
        note_ids: [Vmax]u32 = [_]u32{0} ** Vmax,
        /// A monotonically increasing allocation stamp per slot (for `.oldest`).
        ages: [Vmax]u64 = [_]u64{0} ** Vmax,
        /// The next allocation stamp.
        next_age: u64 = 1,

        pub const voice_count = Vmax;

        /// Find a free (inactive) slot, or null if all `Vmax` are sounding.
        fn freeSlot(self: *Self) ?usize {
            for (&self.voices, 0..) |*v, i| {
                if (!v.isActive()) return i;
            }
            return null;
        }

        /// Pick the slot to steal under the configured policy.
        fn stealSlot(self: *Self) usize {
            switch (self.steal) {
                .oldest => {
                    var best: usize = 0;
                    var best_age: u64 = std.math.maxInt(u64);
                    for (self.ages, 0..) |a, i| {
                        if (a < best_age) {
                            best_age = a;
                            best = i;
                        }
                    }
                    return best;
                },
                .quietest => {
                    if (comptime !@hasDecl(Voice, "levelProbe")) return self.stealSlot_oldest();
                    var best: usize = 0;
                    var best_lvl: f32 = std.math.inf(f32);
                    for (&self.voices, 0..) |*v, i| {
                        const l = v.levelProbe();
                        if (l < best_lvl) {
                            best_lvl = l;
                            best = i;
                        }
                    }
                    return best;
                },
            }
        }

        fn stealSlot_oldest(self: *Self) usize {
            var best: usize = 0;
            var best_age: u64 = std.math.maxInt(u64);
            for (self.ages, 0..) |a, i| {
                if (a < best_age) {
                    best_age = a;
                    best = i;
                }
            }
            return best;
        }

        /// The single voice slot currently sounding `note_id`, or null if none.
        /// `note_id` is expected to be **unique among sounding voices** (the MPE
        /// convention); should two slots ever share one, the most-recently-allocated
        /// (the live note) is returned, so a `note_off`/expression routes to exactly
        /// ONE slot — never fanning out to every slot that ever held that id.
        fn findOwningSlot(self: *Self, note_id: u32) ?usize {
            var best: ?usize = null;
            var best_age: u64 = 0;
            for (&self.voices, 0..) |*v, i| {
                if (v.isActive() and self.note_ids[i] == note_id and (best == null or self.ages[i] > best_age)) {
                    best = i;
                    best_age = self.ages[i];
                }
            }
            return best;
        }

        fn applyEvent(self: *Self, ev: NoteEvent) void {
            switch (ev) {
                .note_on => |n| {
                    if (self.freeSlot()) |i| {
                        // Fresh slot: reset to the configured template, then trigger
                        // (a clean voice — phase 0, level 0, attack masks the onset).
                        self.voices[i] = self.prototype;
                        self.voices[i].noteOn(n.pitch_hz, n.velocity);
                        self.note_ids[i] = n.note_id;
                        self.ages[i] = self.next_age;
                        self.next_age += 1;
                    } else {
                        // Steal: retrigger in place (phase + level continuous ⇒
                        // click-free), without resetting to the prototype.
                        const i = self.stealSlot();
                        self.voices[i].noteOn(n.pitch_hz, n.velocity);
                        self.note_ids[i] = n.note_id;
                        self.ages[i] = self.next_age;
                        self.next_age += 1;
                    }
                },
                .note_off => |n| {
                    // Route to the single owning voice (EV2/Y5), not every slot that
                    // matches — a duplicate note_id must not release unrelated voices.
                    if (self.findOwningSlot(n.note_id)) |i| self.voices[i].noteOff();
                },
                .pressure => |n| {
                    if (comptime @hasDecl(Voice, "setPressure")) {
                        if (self.findOwningSlot(n.note_id)) |i| self.voices[i].setPressure(n.value);
                    }
                },
                .expression => |n| {
                    if (comptime @hasDecl(Voice, "setExpression")) {
                        if (self.findOwningSlot(n.note_id)) |i| self.voices[i].setExpression(n.axis, n.value);
                    }
                },
                // Channel-wide events: not routed per-note here (a future channel
                // controller maps these to parameters). Ignored by the voice pool.
                .control, .pitch_bend, .program => {},
            }
        }

        /// Add every active voice's contribution into `seg` (the fused internal-skip
        /// loop). `seg` is a disjoint sub-range of the pre-zeroed output.
        fn renderSegment(self: *Self, seg: []Sample(f32)) void {
            for (&self.voices) |*v| {
                if (v.isActive()) v.renderAdd(seg);
            }
        }

        /// The block kernel: a zero-sample-input `Map` source consuming the event
        /// lane and producing mono audio. `out.len` is the pull demand `N`.
        pub fn process(self: *Self, events: EventLane(NoteEvent), out: []Sample(f32)) void {
            // Zero the output once; the sub-segment renders ADD active voices in.
            for (out) |*o| o.ch[0] = 0;

            var cursor: usize = 0;
            for (events.items) |te| {
                const off = @min(@as(usize, te.sample_offset), out.len);
                if (off > cursor) self.renderSegment(out[cursor..off]);
                self.applyEvent(te.event);
                cursor = off;
            }
            if (cursor < out.len) self.renderSegment(out[cursor..]);
        }
    };
}

/// `VoiceMap(Voice, Vmax)` — the **replicated** polyphony realisation (scheduler-
/// simple, good for a small fixed voice count): structurally identical to
/// `PolyVoice` but the render loop runs **all** `Vmax` voices every callback
/// (compute-and-discard for inactive ones) rather than skipping inactive slots. The
/// output is identical to the fused `PolyVoice` (an inactive voice adds silence);
/// the trade is CPU (all `Vmax` always run) for branch-free simplicity. Both are one
/// static op with a `Vmax`-comptime footprint.
pub fn VoiceMap(comptime Voice: type, comptime Vmax: usize) type {
    requireVoice(Voice);
    return struct {
        const Self = @This();
        inner: PolyVoice(Voice, Vmax) = .{},

        pub const voice_count = Vmax;

        fn renderSegmentAll(self: *Self, seg: []Sample(f32)) void {
            // Replicated: every voice renders unconditionally (no active-skip). An
            // idle voice adds silence, so the sum equals the fused result.
            for (&self.inner.voices) |*v| v.renderAdd(seg);
        }

        pub fn process(self: *Self, events: EventLane(NoteEvent), out: []Sample(f32)) void {
            for (out) |*o| o.ch[0] = 0;
            var cursor: usize = 0;
            for (events.items) |te| {
                const off = @min(@as(usize, te.sample_offset), out.len);
                if (off > cursor) self.renderSegmentAll(out[cursor..off]);
                self.inner.applyEvent(te.event);
                cursor = off;
            }
            if (cursor < out.len) self.renderSegmentAll(out[cursor..]);
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const expectApprox = std.testing.expectApproxEqAbs;

test "EventLane: classifies a consuming block as a zero-sample-input Source" {
    const Poly = PolyVoice(SawVoice, 4);
    try std.testing.expect(port.classify(Poly) == .Map);
    try std.testing.expect(comptime port.isSource(Poly)); // event lane is not a sample input
    try std.testing.expect(port.isEventConsumer(Poly));
    try std.testing.expect(port.EventOf(Poly) == NoteEvent);
    try std.testing.expect(port.MapOutPort(Poly).Elem == Sample(f32));
}

test "PolyVoice: a note_on allocates a slot and the voice sounds" {
    var poly: PolyVoice(SawVoice, 4) = .{ .prototype = .{ .attack_inc = 0.5, .sustain = 1.0 } };
    var out: [16]Sample(f32) = undefined;
    const ev = [_]Timed(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 1000, .velocity = 1.0 } } },
    };
    poly.process(EventLane(NoteEvent).fromSorted(&ev), &out);
    // Something nonzero was produced once the envelope opened.
    var energy: f32 = 0;
    for (out) |o| energy += @abs(o.ch[0]);
    try std.testing.expect(energy > 0);
}

test "PolyVoice: note_off releases the voice to silence" {
    var poly: PolyVoice(SawVoice, 4) = .{
        .prototype = .{
            .attack_inc = 1.0, // instant attack
            .decay_inc = 1.0,
            .sustain = 1.0,
            .release_inc = 1.0, // instant release
        },
    };
    var out: [8]Sample(f32) = undefined;
    const on = [_]Timed(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 7, .pitch_hz = 500, .velocity = 1.0 } } },
    };
    poly.process(EventLane(NoteEvent).fromSorted(&on), &out);
    try std.testing.expect(poly.voices[0].isActive());

    const off = [_]Timed(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_off = .{ .note_id = 7, .velocity = 0.0 } } },
    };
    poly.process(EventLane(NoteEvent).fromSorted(&off), &out);
    // Instant release ⇒ the voice has gone idle by the end of the block.
    try std.testing.expect(!poly.voices[0].isActive());
}

test "PolyVoice: sub-block onset places the note at its sample offset" {
    var poly: PolyVoice(SawVoice, 4) = .{ .prototype = .{ .attack_inc = 1.0, .sustain = 1.0 } };
    var out: [16]Sample(f32) = undefined;
    // note_on at offset 8 ⇒ samples [0,8) are silent, [8,16) sound.
    const ev = [_]Timed(NoteEvent){
        .{ .sample_offset = 8, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 2000, .velocity = 1.0 } } },
    };
    poly.process(EventLane(NoteEvent).fromSorted(&ev), &out);
    var pre: f32 = 0;
    for (out[0..8]) |o| pre += @abs(o.ch[0]);
    var post: f32 = 0;
    for (out[8..16]) |o| post += @abs(o.ch[0]);
    try std.testing.expectEqual(@as(f32, 0), pre); // silent before the onset
    try std.testing.expect(post > 0); // sounding after
}

test "PolyVoice: stealing past Vmax keeps Vmax bound" {
    var poly: PolyVoice(SawVoice, 2) = .{ .prototype = .{ .attack_inc = 1.0, .sustain = 1.0 } };
    var out: [8]Sample(f32) = undefined;
    // Three simultaneous note-ons into a 2-voice pool: the third steals.
    const ev = [_]Timed(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 400, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 500, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 3, .pitch_hz = 600, .velocity = 1 } } },
    };
    poly.process(EventLane(NoteEvent).fromSorted(&ev), &out);
    // Only Vmax=2 slots exist; the oldest (note 1) was stolen by note 3.
    var sounding: usize = 0;
    for (&poly.voices) |*v| {
        if (v.isActive()) sounding += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), sounding);
    try std.testing.expectEqual(@as(u32, 3), poly.note_ids[0]); // slot 0 stolen by note 3
    try std.testing.expectEqual(@as(u32, 2), poly.note_ids[1]);
}

test "PolyVoice: a note_off routes to ONE owning slot, not all duplicate note_ids" {
    // Two notes sharing a note_id occupy two slots; a single note_off must release
    // exactly one (the most recently allocated), never both — the EV2/Y5 single-owner
    // routing. (A duplicate note_id is ill-formed per MPE, but must not corrupt the
    // pool by silencing an unrelated voice.)
    var poly: PolyVoice(SawVoice, 4) = .{ .prototype = .{ .attack_inc = 1.0, .sustain = 1.0, .release_inc = 1.0 } };
    var out: [4]Sample(f32) = undefined;
    const on = [_]Timed(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 9, .pitch_hz = 400, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 9, .pitch_hz = 500, .velocity = 1 } } },
    };
    poly.process(EventLane(NoteEvent).fromSorted(&on), &out);
    try std.testing.expect(poly.voices[0].isActive() and poly.voices[1].isActive());

    const off = [_]Timed(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_off = .{ .note_id = 9, .velocity = 0 } } },
    };
    poly.process(EventLane(NoteEvent).fromSorted(&off), &out);
    // Exactly one of the two went idle (instant release); the other still sounds.
    var active: usize = 0;
    for (&poly.voices) |*v| {
        if (v.isActive()) active += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), active);
}

test "PolyVoice: footprint is a Vmax-comptime constant (Y1)" {
    // The voice pool is `[Vmax]Voice` persistent state, so the block's footprint is a
    // comptime constant in Vmax — a note-on allocates a slot, never a node, and never
    // touches the audio-thread allocator. Assert the size is comptime-evaluable and
    // scales with Vmax (no dynamic/heap component).
    const one = @sizeOf(PolyVoice(SawVoice, 1));
    const big = comptime @sizeOf(PolyVoice(SawVoice, 64));
    try std.testing.expect(big > one); // strictly larger pool for more voices
    try std.testing.expectEqual(@as(usize, 8), PolyVoice(SawVoice, 8).voice_count);
    // The whole block is plain value state (no slice/pointer voice pool): its size is
    // at least Vmax voices.
    try std.testing.expect(@sizeOf(PolyVoice(SawVoice, 8)) >= 8 * @sizeOf(SawVoice));
}

test "VoiceMap: replicated render equals the fused PolyVoice output" {
    const proto: SawVoice = .{ .attack_inc = 0.2, .sustain = 0.8 };
    var fused: PolyVoice(SawVoice, 4) = .{ .prototype = proto };
    var repl: VoiceMap(SawVoice, 4) = .{ .inner = .{ .prototype = proto } };
    var a: [32]Sample(f32) = undefined;
    var b: [32]Sample(f32) = undefined;
    const ev = [_]Timed(NoteEvent){
        .{ .sample_offset = 4, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 440, .velocity = 0.9 } } },
    };
    fused.process(EventLane(NoteEvent).fromSorted(&ev), &a);
    repl.process(EventLane(NoteEvent).fromSorted(&ev), &b);
    for (a, b) |x, y| try std.testing.expectEqual(x.ch[0], y.ch[0]); // bit-identical
}
