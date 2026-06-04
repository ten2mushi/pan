//! polyvoice_behaviour_test — the INDEPENDENT-ORACLE ("tests as definition: the
//! Yoneda way") characterization of Phase-13, gate §5.7h: the typed event lane
//! and the fixed-capacity intra-block polyphony in `src/synth.zig`
//! (`EventLane(Event)`, `Timed(Event)`, `NoteEvent`, `SawVoice`,
//! `PolyVoice(Voice, Vmax)`, `VoiceMap(Voice, Vmax)`).
//!
//! The Yoneda discipline: a block IS the totality of its observable morphisms.
//! `PolyVoice.process` is pinned by ALL of them — the sub-block onset split that
//! makes a note land exactly on its `sample_offset` (bit-exact silence before,
//! sound after), the whole-block ≡ split-and-concatenate state-granularity
//! identity (proving the onset IS the sub-block split, not an approximation of
//! it), the Vmax-bounded voice allocation, click-free voice stealing (a steal
//! retriggers in place with phase + level continuous, so it does NOT introduce a
//! hard discontinuity a reset-to-zero voice would), note_id/MPE routing to the
//! exact owning slot, the replicated VoiceMap ≡ fused PolyVoice identity, and the
//! event-genericity of the lane mechanism (it keys only on `sample_offset`, never
//! the payload).
//!
//! ORACLE DISCIPLINE (Rule 9, hermetic — no SciPy/librosa, no disk): every
//! numeric expectation is an INDEPENDENT reconstruction. The onset oracle drives
//! a standalone `SawVoice` over the post-onset sub-range and asserts the fused
//! `process` output equals it sample-for-sample. The split-≡-whole oracle renders
//! the SAME event lane to a second buffer by hand-splitting at the event offsets,
//! so pan agrees with itself only if the onset placement IS exactly that split.
//! The routing oracle is a tiny in-file recording Voice (helper Voices live HERE,
//! never in src/) that captures which slot an expression/pressure event reached.
//!
//! COMPARISON DISCIPLINE: the load-bearing facts — silence-before-onset, the
//! split ≡ whole equivalence, VoiceMap ≡ PolyVoice, and determinism — are pan-vs-
//! pan BIT-EXACT (expectEqual on the raw f32). "Sounds" / "click-free" are
//! behavioural thresholds with a stated, discriminating bound (the steal delta is
//! contrasted against the much larger jump a hard-reset voice would produce).
//!
//! Reject diagnostics use std.debug.print (never std.log.err — the 0.16 test
//! runner counts logged errors and flips the suite to non-zero exit).
//!
//! Verified against zig 0.16.0; the zig-0-16 skill was loaded before authoring
//! (Rules 13/14). `Sample(f32)` is the mono `Frame`, read as `s.ch[0]`.

const std = @import("std");
const pan = @import("pan");

const S = pan.Sample(f32);
const NoteEvent = pan.NoteEvent;
const ExprAxis = pan.ExprAxis;

fn Lane(comptime E: type) type {
    return pan.EventLane(E);
}
fn TE(comptime E: type) type {
    return pan.Timed(E);
}

// A bit-exact, sample-for-sample buffer comparison (pan-vs-pan). Prints the first
// differing index to std.debug.print so a failure is diagnosable, then errors.
fn expectSameBuf(a: []const S, b: []const S, what: []const u8) !void {
    if (a.len != b.len) {
        std.debug.print("{s}: length {d} != {d}\n", .{ what, a.len, b.len });
        return error.LenMismatch;
    }
    for (a, b, 0..) |x, y, i| {
        if (x.ch[0] != y.ch[0]) {
            std.debug.print("{s}: sample {d} differs: {d} != {d}\n", .{ what, i, x.ch[0], y.ch[0] });
            return error.BufMismatch;
        }
    }
}

fn energy(buf: []const S) f32 {
    var e: f32 = 0;
    for (buf) |s| e += @abs(s.ch[0]);
    return e;
}

// The largest absolute sample-to-sample step inside `buf` — the discriminating
// "click" measure: a click is a single large discontinuity, so a click-free
// signal has every adjacent delta bounded.
fn maxAdjacentDelta(buf: []const S) f32 {
    var m: f32 = 0;
    var i: usize = 1;
    while (i < buf.len) : (i += 1) {
        const d = @abs(buf[i].ch[0] - buf[i - 1].ch[0]);
        if (d > m) m = d;
    }
    return m;
}

// ===========================================================================
// Helper Voices (live HERE, not in src/) — used to characterize routing and to
// build a discriminating hard-reset contrast for the click-free steal proof.
// ===========================================================================

// A Voice that records every routed expression/pressure call with the SLOT it
// landed in is impossible without slot context, so instead it records the LAST
// routed value and its own per-instance id; PolyVoice owns an array of these and
// we read the array directly to learn which slot was hit. It satisfies the Voice
// contract (noteOn/noteOff/renderAdd/isActive) and adds the optional MPE hooks.
const RecordVoice = struct {
    const Self = @This();
    active: bool = false,
    // Last routed expression/pressure, defaulted to sentinels that no test sends.
    last_pressure: f32 = -1,
    last_expr_axis: ExprAxis = .timbre,
    last_expr_value: f32 = -1,
    expr_hits: u32 = 0,
    pressure_hits: u32 = 0,
    // A constant DC level so renderAdd produces a deterministic, comparable sum.
    dc: f32 = 0,

    pub fn noteOn(self: *Self, pitch_hz: f32, velocity: f32) void {
        _ = pitch_hz;
        self.active = true;
        self.dc = velocity; // make the slot's contribution identifiable by velocity
    }
    pub fn noteOff(self: *Self) void {
        self.active = false;
    }
    pub fn isActive(self: *const Self) bool {
        return self.active;
    }
    pub fn renderAdd(self: *Self, out: []S) void {
        for (out) |*o| o.ch[0] += self.dc;
    }
    pub fn setPressure(self: *Self, value: f32) void {
        self.last_pressure = value;
        self.pressure_hits += 1;
    }
    pub fn setExpression(self: *Self, axis: ExprAxis, value: f32) void {
        self.last_expr_axis = axis;
        self.last_expr_value = value;
        self.expr_hits += 1;
    }
};

// A Voice identical in audio to SawVoice's *contract* but that HARD-RESETS phase
// and level to zero on every noteOn (the WRONG, clicky stealing behaviour). It is
// the counter-example: a steal that reset like this WOULD produce a large
// discontinuity, which is exactly what we show pan does NOT do. A pure sinusoid is
// enough to expose the difference (a reset mid-cycle jumps to sin(0)=0).
const HardResetVoice = struct {
    const Self = @This();
    phase: f32 = 0,
    inc: f32 = 0,
    level: f32 = 0,
    vel: f32 = 0,
    stage_active: bool = false,

    pub fn noteOn(self: *Self, pitch_hz: f32, velocity: f32) void {
        // The clicky behaviour: slam phase AND level to zero on retrigger.
        self.phase = 0;
        self.level = 1;
        self.vel = velocity;
        self.inc = pitch_hz / 48_000.0;
        self.stage_active = true;
    }
    pub fn noteOff(self: *Self) void {
        self.stage_active = false;
    }
    pub fn isActive(self: *const Self) bool {
        return self.stage_active;
    }
    pub fn renderAdd(self: *Self, out: []S) void {
        const tau = 2.0 * std.math.pi;
        for (out) |*o| {
            o.ch[0] += self.vel * self.level * @sin(tau * self.phase);
            self.phase = self.phase + self.inc - @floor(self.phase + self.inc);
        }
    }
};

// A continuous-retrigger Voice mirroring SawVoice's click-free contract: noteOn
// keeps phase AND level running (no reset), so a steal is continuous. Sinusoidal,
// so adjacent-sample deltas are bounded by the per-sample phase step.
const ContinuousVoice = struct {
    const Self = @This();
    phase: f32 = 0,
    inc: f32 = 0,
    level: f32 = 1,
    vel: f32 = 1,
    stage_active: bool = false,

    pub fn noteOn(self: *Self, pitch_hz: f32, velocity: f32) void {
        // Click-free: phase and level left running; only frequency/velocity change.
        self.vel = velocity;
        self.inc = pitch_hz / 48_000.0;
        self.stage_active = true;
    }
    pub fn noteOff(self: *Self) void {
        self.stage_active = false;
    }
    pub fn isActive(self: *const Self) bool {
        return self.stage_active;
    }
    pub fn renderAdd(self: *Self, out: []S) void {
        const tau = 2.0 * std.math.pi;
        for (out) |*o| {
            o.ch[0] += self.vel * self.level * @sin(tau * self.phase);
            self.phase = self.phase + self.inc - @floor(self.phase + self.inc);
        }
    }
};

// ===========================================================================
// INVARIANT 5 — Event-genericity (EV1): the lane keys ONLY on sample_offset,
// never the payload. Demonstrate EventLane(E) over a trivial non-NoteEvent E and
// a tiny consuming block that walks the lane with the SAME sub-block split idiom.
// ===========================================================================

// A trivial non-NoteEvent payload: a single integer "set the floor" command.
const SetLevel = struct { value: f32 };

// A tiny event-consuming block whose ONLY input is EventLane(SetLevel): it walks
// the sorted lane and writes `value` from the active set-point into each sample,
// rendering sub-segments between offsets exactly like PolyVoice. This proves the
// lane machinery is event-generic (any E works) and the split keys on offsets.
const StepBlock = struct {
    const Self = @This();
    current: f32 = 0,
    pub fn process(self: *Self, events: Lane(SetLevel), out: []S) void {
        var cursor: usize = 0;
        for (events.items) |te| {
            const off = @min(@as(usize, te.sample_offset), out.len);
            var i = cursor;
            while (i < off) : (i += 1) out[i].ch[0] = self.current;
            self.current = te.event.value;
            cursor = off;
        }
        var i = cursor;
        while (i < out.len) : (i += 1) out[i].ch[0] = self.current;
    }
};

test "§5.7h: EventLane(E) is event-generic — the split keys on sample_offset not payload (EV1)" {
    // The lane mechanism must work for an arbitrary, non-NoteEvent E.
    var blk: StepBlock = .{ .current = 0 };
    var out: [16]S = undefined;
    const ev = [_]TE(SetLevel){
        .{ .sample_offset = 4, .event = .{ .value = 0.25 } },
        .{ .sample_offset = 10, .event = .{ .value = 0.75 } },
    };
    blk.process(Lane(SetLevel).fromSorted(&ev), &out);
    // [0,4): the prior set-point 0; [4,10): 0.25; [10,16): 0.75 — keyed purely on
    // the offsets, the payload type is irrelevant to the lane's segmentation.
    for (out[0..4]) |o| try std.testing.expectEqual(@as(f32, 0), o.ch[0]);
    for (out[4..10]) |o| try std.testing.expectEqual(@as(f32, 0.25), o.ch[0]);
    for (out[10..16]) |o| try std.testing.expectEqual(@as(f32, 0.75), o.ch[0]);

    // The lane is also a thin read-only view: len()/items reflect the slice given.
    try std.testing.expectEqual(@as(usize, 2), Lane(SetLevel).fromSorted(&ev).len());
    try std.testing.expectEqual(@as(usize, 0), Lane(SetLevel).empty.len());
    // And EventLane is genuinely instantiable on a non-NoteEvent element type.
    try std.testing.expect(Lane(SetLevel).Event == SetLevel);
}

// ===========================================================================
// INVARIANT 1 — Sample-accurate onset via the sub-block split (Y2/EV3). THE
// LOAD-BEARING CHECK. A note_on at offset k ⇒ [0,k) bit-exact silent, [k,N) sound.
// ===========================================================================

test "§5.7h: note_on at offset k is BIT-EXACT silent before k, sounding after (Y2/EV3)" {
    const proto: pan.SawVoice = .{ .attack_inc = 1.0, .sustain = 1.0, .decay_inc = 1.0 };
    inline for (.{ 0, 1, 7, 8, 15 }) |k| {
        var poly: pan.PolyVoice(pan.SawVoice, 4) = .{ .prototype = proto };
        var out: [16]S = undefined;
        const ev = [_]TE(NoteEvent){
            .{ .sample_offset = k, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 2000, .velocity = 1.0 } } },
        };
        poly.process(Lane(NoteEvent).fromSorted(&ev), &out);
        // [0,k): the note has not been applied — bit-exact zero (no active voice).
        for (out[0..k], 0..) |o, i| {
            if (o.ch[0] != 0) {
                std.debug.print("onset k={d}: pre-onset sample {d} = {d}, expected 0\n", .{ k, i, o.ch[0] });
                return error.NotSilentBeforeOnset;
            }
        }
        // [k,N): the voice sounds — strictly positive total energy after the onset,
        // provided the post-onset tail is at least 2 samples. SawVoice attacks from
        // level 0 and renders each sample BEFORE stepping the envelope, so sample k
        // itself is exactly velocity·0·saw = 0; the tail is audible from sample k+1.
        // (A single-sample tail at k=15 is therefore legitimately silent — not a bug.)
        if (k < 15) try std.testing.expect(energy(out[k..]) > 0);
    }
}

test "§5.7h: whole-block process ≡ hand-split-and-concatenate, BIT-EXACT (Y2/§5.6 state-granularity)" {
    // The onset placement IS the sub-block split: rendering the whole block in one
    // process call equals rendering [0,k) (silence) then [k,N) (the voice) and
    // concatenating. The oracle drives a STANDALONE SawVoice over [k,N) — sharing
    // only SawVoice's definition with pan, never PolyVoice's loop — and we assert
    // pan's fused output is identical sample-for-sample.
    const proto: pan.SawVoice = .{ .attack_inc = 0.2, .sustain = 0.6, .decay_inc = 0.01 };
    inline for (.{ 1, 5, 9, 13 }) |k| {
        var poly: pan.PolyVoice(pan.SawVoice, 4) = .{ .prototype = proto };
        var got: [24]S = undefined;
        const ev = [_]TE(NoteEvent){
            .{ .sample_offset = k, .event = .{ .note_on = .{ .note_id = 9, .pitch_hz = 333, .velocity = 0.8 } } },
        };
        poly.process(Lane(NoteEvent).fromSorted(&ev), &got);

        // Oracle: zero everywhere, then a fresh prototype voice triggered at k and
        // rendered ADDITIVELY over [k,N) — exactly what process does in its tail
        // segment after applying the event at the boundary.
        var want: [24]S = undefined;
        for (&want) |*o| o.ch[0] = 0;
        var oracle: pan.SawVoice = proto;
        oracle.noteOn(333, 0.8);
        oracle.renderAdd(want[k..]);

        try expectSameBuf(&got, &want, "split≡whole onset");
    }
}

test "§5.7h: two onsets at different offsets split into THREE bit-exact sub-segments (Y2)" {
    // Two notes at k1<k2: [0,k1) silent, [k1,k2) voice A, [k2,N) A+B. The fused
    // process must equal the hand-built three-segment oracle bit-for-bit.
    const proto: pan.SawVoice = .{ .attack_inc = 0.3, .sustain = 0.5 };
    const k1 = 4;
    const k2 = 11;
    var poly: pan.PolyVoice(pan.SawVoice, 4) = .{ .prototype = proto };
    var got: [20]S = undefined;
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = k1, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 220, .velocity = 1.0 } } },
        .{ .sample_offset = k2, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 440, .velocity = 0.5 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&ev), &got);

    var want: [20]S = undefined;
    for (&want) |*o| o.ch[0] = 0;
    // Voice A: triggered at k1, renders the whole [k1,N) tail (it stays active).
    var a: pan.SawVoice = proto;
    a.noteOn(220, 1.0);
    a.renderAdd(want[k1..]);
    // Voice B: triggered at k2, renders [k2,N), ADDING onto A's contribution.
    var b: pan.SawVoice = proto;
    b.noteOn(440, 0.5);
    b.renderAdd(want[k2..]);

    try expectSameBuf(&got, &want, "two-onset three-segment split");
}

test "§5.7h: an event at offset ≥ N applies after all audio (no out-of-range render) (Y2)" {
    // process clamps off = @min(sample_offset, out.len). An event scheduled at the
    // block boundary therefore touches zero samples this block: output is bit-exact
    // silent (the note_on lands at the very end, after the last rendered sample).
    var poly: pan.PolyVoice(pan.SawVoice, 4) = .{ .prototype = .{ .attack_inc = 1.0, .sustain = 1.0 } };
    var out: [8]S = undefined;
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 8, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 500, .velocity = 1.0 } } },
        .{ .sample_offset = 100, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 500, .velocity = 1.0 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&ev), &out);
    for (out, 0..) |o, i| {
        if (o.ch[0] != 0) {
            std.debug.print("boundary onset: sample {d} = {d}, expected 0\n", .{ i, o.ch[0] });
            return error.NotSilentForBoundaryOnset;
        }
    }
    // Both notes DID allocate (the offset clamp only bounds rendering, not routing).
    try std.testing.expect(poly.voices[0].isActive());
    try std.testing.expect(poly.voices[1].isActive());
}

test "§5.7h: process zeros the output even with an EMPTY lane (no stale carry) (Y2)" {
    var poly: pan.PolyVoice(pan.SawVoice, 4) = .{};
    var out: [8]S = undefined;
    for (&out) |*o| o.ch[0] = 999; // poison
    poly.process(Lane(NoteEvent).empty, &out);
    for (out, 0..) |o, i| {
        if (o.ch[0] != 0) {
            std.debug.print("empty lane: sample {d} = {d}, expected 0\n", .{ i, o.ch[0] });
            return error.StaleOutput;
        }
    }
}

// ===========================================================================
// INVARIANT 2 — Voice allocation & click-free stealing (Y3).
// ===========================================================================

test "§5.7h: up to Vmax distinct note_ons each take a distinct slot (Y3)" {
    var poly: pan.PolyVoice(pan.SawVoice, 4) = .{ .prototype = .{ .attack_inc = 1.0, .sustain = 1.0 } };
    var out: [8]S = undefined;
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 10, .pitch_hz = 100, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 11, .pitch_hz = 200, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 12, .pitch_hz = 300, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 13, .pitch_hz = 400, .velocity = 1 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&ev), &out);
    // All four slots are sounding, each owning a distinct note_id (a permutation of
    // {10,11,12,13} across the slots — allocation never doubles up).
    var sounding: usize = 0;
    for (&poly.voices) |*v| {
        if (v.isActive()) sounding += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), sounding);
    var seen = [_]bool{false} ** 4;
    for (poly.note_ids) |id| {
        try std.testing.expect(id >= 10 and id <= 13);
        seen[id - 10] = true;
    }
    for (seen) |s| try std.testing.expect(s);
}

test "§5.7h: a note_on past Vmax steals the OLDEST and stays Vmax-bounded (Y3)" {
    var poly: pan.PolyVoice(pan.SawVoice, 3) = .{
        .steal = .oldest,
        .prototype = .{ .attack_inc = 1.0, .sustain = 1.0 },
    };
    var out: [8]S = undefined;
    // Four notes into a 3-voice pool: note 1 (oldest) is stolen by note 4.
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 100, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 200, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 3, .pitch_hz = 300, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 4, .pitch_hz = 400, .velocity = 1 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&ev), &out);
    var sounding: usize = 0;
    for (&poly.voices) |*v| {
        if (v.isActive()) sounding += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), sounding); // never exceeds Vmax
    // The pool now owns {2,3,4}; note 1 (the oldest) was evicted.
    var has1 = false;
    var has4 = false;
    for (poly.note_ids) |id| {
        if (id == 1) has1 = true;
        if (id == 4) has4 = true;
    }
    try std.testing.expect(!has1); // oldest gone
    try std.testing.expect(has4); // newcomer present
}

test "§5.7h: the .quietest steal policy evicts the lowest-level voice (Y3)" {
    // Build a 2-voice pool where one voice has been releasing (low level) and one is
    // at full sustain; a third note must steal the quieter one. We drive levels by
    // rendering: an instant-attack/instant-release voice given a note_off drops to a
    // lower level than a sustaining one over the same block.
    var poly: pan.PolyVoice(pan.SawVoice, 2) = .{
        .steal = .quietest,
        .prototype = .{ .attack_inc = 1.0, .decay_inc = 1.0, .sustain = 1.0, .release_inc = 0.05 },
    };
    var out: [4]S = undefined;
    // Block 1: two notes on; then note 1 OFF (it begins releasing → lower level).
    const b1 = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 100, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 200, .velocity = 1 } } },
        .{ .sample_offset = 1, .event = .{ .note_off = .{ .note_id = 1, .velocity = 0 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&b1), &out);
    // Identify which slot holds note 1 and confirm it is the quieter of the two.
    var slot1: usize = 999;
    var slot2: usize = 999;
    for (poly.note_ids, 0..) |id, i| {
        if (id == 1) slot1 = i;
        if (id == 2) slot2 = i;
    }
    try std.testing.expect(slot1 != 999 and slot2 != 999);
    try std.testing.expect(poly.voices[slot1].levelProbe() < poly.voices[slot2].levelProbe());

    // Block 2: a third note steals — under .quietest it must evict the releasing
    // note-1 slot, leaving note 2 untouched.
    const b2 = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 3, .pitch_hz = 300, .velocity = 1 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&b2), &out);
    try std.testing.expectEqual(@as(u32, 3), poly.note_ids[slot1]); // quiet slot reused
    try std.testing.expectEqual(@as(u32, 2), poly.note_ids[slot2]); // loud slot kept
}

test "§5.7h: stealing is CLICK-FREE — the retrigger does NOT inject a hard discontinuity (Y3)" {
    // Discriminating measure: a steal that RESET phase+level to zero (HardResetVoice)
    // produces a large sample-to-sample jump at the steal instant; the click-free
    // contract (ContinuousVoice, mirroring SawVoice) keeps phase/level running so the
    // adjacent delta stays bounded by the per-sample phase step. We render the SAME
    // steal event into both a clicky and a continuous 1-voice pool and show the
    // continuous one's max adjacent delta is dramatically smaller.
    //
    // 1-voice pool so the second note_on is forced to steal the first in place.
    // BOTH note-ons use the SAME pitch (1000 Hz), so the ONLY thing that could
    // create a discontinuity at the steal instant is the retrigger's treatment of
    // phase/level — isolating the click-free property from any frequency change.
    // The steal is placed at offset 12, where the running phase (≈0.25 of a cycle
    // for 1000 Hz at 48 kHz) is near a sine peak: a hard reset-to-zero there slams
    // the output from ≈1.0 to 0, the maximally clicky case the continuous voice
    // must avoid.
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 1000, .velocity = 1 } } },
        .{ .sample_offset = 12, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 1000, .velocity = 1 } } },
    };

    var clicky: pan.PolyVoice(HardResetVoice, 1) = .{};
    var cont: pan.PolyVoice(ContinuousVoice, 1) = .{};
    var bc: [48]S = undefined;
    var bk: [48]S = undefined;
    clicky.process(Lane(NoteEvent).fromSorted(&ev), &bk);
    cont.process(Lane(NoteEvent).fromSorted(&ev), &bc);

    const click_jump = maxAdjacentDelta(&bk);
    const cont_jump = maxAdjacentDelta(&bc);

    // The continuous (click-free) retrigger's worst adjacent delta is bounded by a
    // small per-sample step; the hard-reset voice's is large (it slams to sin(0)=0
    // from a mid-cycle value). The click-free delta must be a fraction of the clicky
    // one — a sharp, discriminating separation, not a marginal one.
    if (!(cont_jump < click_jump * 0.5)) {
        std.debug.print("steal click: continuous max-delta {d} not < half clicky {d}\n", .{ cont_jump, click_jump });
        return error.StealNotClickFree;
    }
    // And the click-free retrigger keeps individual steps small in absolute terms
    // (a continuous sinusoid steps by at most ~2π·f/SR per sample, well under 0.5).
    try std.testing.expect(cont_jump < 0.5);
    // Sanity: the clicky contrast really does jump hard (so the test is meaningful).
    try std.testing.expect(click_jump > 0.5);
}

test "§5.7h: a steal does NOT silence the other sounding voices (Y3)" {
    // Stealing the oldest must leave the remaining voices sounding — the pool stays
    // full and the steal touches exactly one slot.
    var poly: pan.PolyVoice(pan.SawVoice, 2) = .{ .prototype = .{ .attack_inc = 1.0, .sustain = 1.0 } };
    var out: [8]S = undefined;
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 300, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 400, .velocity = 1 } } },
        .{ .sample_offset = 4, .event = .{ .note_on = .{ .note_id = 3, .pitch_hz = 500, .velocity = 1 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&ev), &out);
    // Both slots active, owning {2,3} (note 1, the oldest, was stolen by note 3).
    var ids = [_]u32{ poly.note_ids[0], poly.note_ids[1] };
    std.mem.sort(u32, &ids, {}, std.sort.asc(u32));
    try std.testing.expectEqual(@as(u32, 2), ids[0]);
    try std.testing.expectEqual(@as(u32, 3), ids[1]);
    try std.testing.expect(poly.voices[0].isActive() and poly.voices[1].isActive());
}

// ===========================================================================
// INVARIANT 3 — note_id / MPE routing (EV2/Y5). pressure/expression route to the
// slot sounding that note_id, not others.
// ===========================================================================

test "§5.7h: pressure/expression route to the OWNING slot by note_id, not others (EV2/Y5)" {
    var poly: pan.PolyVoice(RecordVoice, 4) = .{};
    var out: [4]S = undefined;
    // Allocate three notes, then aim a pressure at note 22 and an expression at note
    // 33. Only their owning slots may record the routed value.
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 11, .pitch_hz = 0, .velocity = 0.1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 22, .pitch_hz = 0, .velocity = 0.2 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 33, .pitch_hz = 0, .velocity = 0.3 } } },
        .{ .sample_offset = 1, .event = .{ .pressure = .{ .note_id = 22, .value = 0.55 } } },
        .{ .sample_offset = 2, .event = .{ .expression = .{ .note_id = 33, .axis = .slide, .value = 0.77 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&ev), &out);

    // Find each note's owning slot (allocation order fills slots 0,1,2).
    var slot11: usize = 999;
    var slot22: usize = 999;
    var slot33: usize = 999;
    for (poly.note_ids, 0..) |id, i| {
        if (poly.voices[i].isActive()) {
            if (id == 11) slot11 = i;
            if (id == 22) slot22 = i;
            if (id == 33) slot33 = i;
        }
    }
    try std.testing.expect(slot11 != 999 and slot22 != 999 and slot33 != 999);

    // The pressure landed ONLY on note 22's slot.
    try std.testing.expectEqual(@as(u32, 1), poly.voices[slot22].pressure_hits);
    try std.testing.expectEqual(@as(f32, 0.55), poly.voices[slot22].last_pressure);
    try std.testing.expectEqual(@as(u32, 0), poly.voices[slot11].pressure_hits); // not note 11
    try std.testing.expectEqual(@as(u32, 0), poly.voices[slot33].pressure_hits); // not note 33

    // The expression landed ONLY on note 33's slot, carrying axis AND value.
    try std.testing.expectEqual(@as(u32, 1), poly.voices[slot33].expr_hits);
    try std.testing.expectEqual(ExprAxis.slide, poly.voices[slot33].last_expr_axis);
    try std.testing.expectEqual(@as(f32, 0.77), poly.voices[slot33].last_expr_value);
    try std.testing.expectEqual(@as(u32, 0), poly.voices[slot11].expr_hits);
    try std.testing.expectEqual(@as(u32, 0), poly.voices[slot22].expr_hits);
}

test "§5.7h: note_off routes by note_id and releases only the matching voice (EV2/Y5)" {
    var poly: pan.PolyVoice(pan.SawVoice, 4) = .{
        .prototype = .{
            .attack_inc = 1.0,
            .decay_inc = 1.0,
            .sustain = 1.0,
            .release_inc = 1.0, // instant release
        },
    };
    var out: [4]S = undefined;
    const on = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 5, .pitch_hz = 200, .velocity = 1 } } },
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 6, .pitch_hz = 300, .velocity = 1 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&on), &out);
    var slot5: usize = 999;
    var slot6: usize = 999;
    for (poly.note_ids, 0..) |id, i| {
        if (id == 5) slot5 = i;
        if (id == 6) slot6 = i;
    }
    // Release ONLY note 5; note 6 must remain sounding.
    const off = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_off = .{ .note_id = 5, .velocity = 0 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&off), &out);
    try std.testing.expect(!poly.voices[slot5].isActive()); // released
    try std.testing.expect(poly.voices[slot6].isActive()); // untouched
}

test "§5.7h: a pressure for an UNKNOWN note_id reaches no slot (EV2/Y5)" {
    var poly: pan.PolyVoice(RecordVoice, 4) = .{};
    var out: [4]S = undefined;
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 7, .pitch_hz = 0, .velocity = 0.5 } } },
        // note_id 999 owns no slot — the pressure must be dropped, not misrouted.
        .{ .sample_offset = 1, .event = .{ .pressure = .{ .note_id = 999, .value = 0.42 } } },
    };
    poly.process(Lane(NoteEvent).fromSorted(&ev), &out);
    for (&poly.voices) |*v| try std.testing.expectEqual(@as(u32, 0), v.pressure_hits);
}

// ===========================================================================
// INVARIANT 4 — Replicated ≡ fused: VoiceMap(Voice,Vmax) output is BIT-IDENTICAL
// to PolyVoice(Voice,Vmax) over the same lane.
// ===========================================================================

test "§5.7h: VoiceMap (replicated) ≡ PolyVoice (fused), BIT-EXACT over a rich lane (replicated≡fused)" {
    const proto: pan.SawVoice = .{ .attack_inc = 0.15, .decay_inc = 0.02, .sustain = 0.7, .release_inc = 0.03 };
    var fused: pan.PolyVoice(pan.SawVoice, 4) = .{ .prototype = proto };
    var repl: pan.VoiceMap(pan.SawVoice, 4) = .{ .inner = .{ .prototype = proto } };
    var a: [64]S = undefined;
    var b: [64]S = undefined;
    // A lane exercising onsets at distinct offsets, a note_off, and a steal-free mix.
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 3, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 220, .velocity = 0.9 } } },
        .{ .sample_offset = 12, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 277, .velocity = 0.6 } } },
        .{ .sample_offset = 20, .event = .{ .note_on = .{ .note_id = 3, .pitch_hz = 330, .velocity = 0.5 } } },
        .{ .sample_offset = 40, .event = .{ .note_off = .{ .note_id = 1, .velocity = 0 } } },
        .{ .sample_offset = 48, .event = .{ .note_on = .{ .note_id = 4, .pitch_hz = 440, .velocity = 0.8 } } },
    };
    fused.process(Lane(NoteEvent).fromSorted(&ev), &a);
    repl.process(Lane(NoteEvent).fromSorted(&ev), &b);
    try expectSameBuf(&a, &b, "VoiceMap≡PolyVoice");
    // Genuinely non-silent (the equivalence is over a signal, not over zero).
    try std.testing.expect(energy(&a) > 0);
}

test "§5.7h: VoiceMap ≡ PolyVoice even when stealing occurs (replicated≡fused)" {
    // Equivalence must hold under voice-stealing too: VoiceMap shares PolyVoice's
    // allocator (it embeds .inner and reuses applyEvent), only the render loop
    // differs (all-voices vs active-skip) — and an idle voice adds silence, so the
    // sums match bit-for-bit even after a steal.
    const proto: pan.SawVoice = .{ .attack_inc = 0.25, .sustain = 0.6 };
    var fused: pan.PolyVoice(pan.SawVoice, 2) = .{ .prototype = proto };
    var repl: pan.VoiceMap(pan.SawVoice, 2) = .{ .inner = .{ .prototype = proto } };
    var a: [40]S = undefined;
    var b: [40]S = undefined;
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 0, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 200, .velocity = 1 } } },
        .{ .sample_offset = 5, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 250, .velocity = 1 } } },
        .{ .sample_offset = 18, .event = .{ .note_on = .{ .note_id = 3, .pitch_hz = 300, .velocity = 1 } } }, // steals
    };
    fused.process(Lane(NoteEvent).fromSorted(&ev), &a);
    repl.process(Lane(NoteEvent).fromSorted(&ev), &b);
    try expectSameBuf(&a, &b, "VoiceMap≡PolyVoice under steal");
}

// ===========================================================================
// Determinism + comptime surface (the Yoneda object identity — a block IS its
// class and element types; identical inputs ⇒ identical outputs).
// ===========================================================================

test "§5.7h: process is deterministic — identical lane ⇒ BIT-EXACT identical output" {
    const proto: pan.SawVoice = .{ .attack_inc = 0.1, .sustain = 0.5 };
    const ev = [_]TE(NoteEvent){
        .{ .sample_offset = 2, .event = .{ .note_on = .{ .note_id = 1, .pitch_hz = 311, .velocity = 0.7 } } },
        .{ .sample_offset = 9, .event = .{ .note_on = .{ .note_id = 2, .pitch_hz = 415, .velocity = 0.4 } } },
    };
    var p1: pan.PolyVoice(pan.SawVoice, 4) = .{ .prototype = proto };
    var p2: pan.PolyVoice(pan.SawVoice, 4) = .{ .prototype = proto };
    var a: [32]S = undefined;
    var b: [32]S = undefined;
    p1.process(Lane(NoteEvent).fromSorted(&ev), &a);
    p2.process(Lane(NoteEvent).fromSorted(&ev), &b);
    try expectSameBuf(&a, &b, "determinism");
}

test "§5.7h: comptime surface — PolyVoice is an event-consuming zero-sample-input Source" {
    const Poly = pan.PolyVoice(pan.SawVoice, 4);
    // voice_count surfaces Vmax as a comptime constant.
    try std.testing.expectEqual(@as(usize, 4), Poly.voice_count);
    try std.testing.expectEqual(@as(usize, 8), pan.PolyVoice(pan.SawVoice, 8).voice_count);
    // VoiceMap mirrors the same capacity.
    try std.testing.expectEqual(@as(usize, 4), pan.VoiceMap(pan.SawVoice, 4).voice_count);
    // The NoteEvent union carries the documented variants (pitch in Hz, MPE axes).
    try std.testing.expect(@hasField(NoteEvent, "note_on"));
    try std.testing.expect(@hasField(NoteEvent, "expression"));
    try std.testing.expect(@hasField(NoteEvent, "pressure"));
    // ExprAxis enumerates the three MPE axes.
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(ExprAxis).@"enum".fields.len);
}
