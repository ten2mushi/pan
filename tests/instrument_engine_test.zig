//! instrument_engine_test — the Instrument vertical slice driven through the
//! RUNTIME `Engine`: a `PolyVoice` source consuming the engine's note-event lane,
//! committed and rendered exactly as the device callback would, proving the
//! end-to-end event-delivery wiring (`engine.sendEvent` → the per-block event
//! drain → `buildEventLane` → `PolyVoice.process`).
//!
//! These tests verify the *engine integration* (the gate's "MIDI chord renders
//! Vmax-bounded polyphony; each onset lands sample-accurately; no audio-thread
//! malloc/lock"), not the voice DSP numerics (that is the §5.7g/§5.7h Yoneda
//! surface). The comparison is pan-vs-pan / behavioural: a note sounds, silence
//! before its onset is exact (bit-exact zero), and the voice pool stays bounded.
//!
//! COMPARISON MODE: pan-vs-pan (bit-exact for the silence/onset boundary;
//! behavioural energy thresholds for "sounds"). No external oracle.
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring,
//! per project Rules 13/14).

const std = @import("std");
const pan = @import("pan");

const Sample = pan.Sample;
const NoteEvent = pan.NoteEvent;
const enterRealtimeThread = pan.engine.enterRealtimeThread;

/// Mono sink: copies its input buffer into a destination backing store so a test
/// can read what the instrument rendered.
const BufSink = struct {
    const Self = @This();
    dest: [*]Sample(f32) = undefined,
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        @memcpy(self.dest[0..in.len], in);
    }
};

/// Stereo sink: drains the panner's two channel planes into separate backing
/// stores. Its input port is a `PlanarConst(f32, .stereo)` view — the planar
/// multi-channel form — so wiring a non-stereo producer into it is a layout
/// (connect/commit) error, which is the gate's "panner output carries layout L".
const StereoSink = struct {
    const Self = @This();
    destL: [*]f32 = undefined,
    destR: [*]f32 = undefined,
    pub fn process(self: *Self, in: pan.PlanarConst(f32, .stereo)) void {
        @memcpy(self.destL[0..in.frames], in.plane(0));
        @memcpy(self.destR[0..in.frames], in.plane(1));
    }
};

fn cfg(n: usize) pan.config.Config {
    return .{ .precision = .f32, .sample_rate = 48_000, .block_size = n, .channels = .mono };
}

fn energy(buf: []const Sample(f32)) f32 {
    var e: f32 = 0;
    for (buf) |s| e += @abs(s.ch[0]);
    return e;
}

const FastVoice: pan.SawVoice = .{ .attack_inc = 1.0, .decay_inc = 1.0, .sustain = 1.0, .release_inc = 1.0, .sample_rate = 48_000 };

test "Instrument: no events ⇒ the PolyVoice renders exact silence" {
    const N = 64;
    var out: [N]Sample(f32) = undefined;

    var g = pan.Graph.init(std.testing.allocator, cfg(N));
    defer g.deinit();
    const poly = try g.add(pan.PolyVoice(pan.SawVoice, 4), .{ .prototype = FastVoice });
    const sink = try g.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try g.connect(poly, sink);
    var eng = try g.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    for (out) |s| try std.testing.expectEqual(@as(f32, 0), s.ch[0]); // bit-exact silence
    try std.testing.expect(!eng.telemetry().fault);
}

test "Instrument: a note_on sent to the PolyVoice node makes it sound" {
    const N = 64;
    var out: [N]Sample(f32) = undefined;

    var g = pan.Graph.init(std.testing.allocator, cfg(N));
    defer g.deinit();
    const poly = try g.add(pan.PolyVoice(pan.SawVoice, 4), .{ .prototype = FastVoice });
    const sink = try g.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try g.connect(poly, sink);
    var eng = try g.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();

    // Deliver a note onset at the block start, then render: the voice sounds.
    try std.testing.expect(eng.sendEvent(poly.id, 0, .{ .note_on = .{ .note_id = 1, .pitch_hz = 880, .velocity = 1.0 } }));
    eng.renderInto(token);
    try std.testing.expect(energy(&out) > 0);
}

test "Instrument: a mid-block onset is silent before its sample offset (engine path)" {
    const N = 64;
    var out: [N]Sample(f32) = undefined;

    var g = pan.Graph.init(std.testing.allocator, cfg(N));
    defer g.deinit();
    const poly = try g.add(pan.PolyVoice(pan.SawVoice, 4), .{ .prototype = FastVoice });
    const sink = try g.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try g.connect(poly, sink);
    var eng = try g.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();

    // note_on at sample offset 32 ⇒ samples [0,32) silent, [32,64) sounding.
    try std.testing.expect(eng.sendEvent(poly.id, 32, .{ .note_on = .{ .note_id = 5, .pitch_hz = 1000, .velocity = 1.0 } }));
    eng.renderInto(token);
    try std.testing.expectEqual(@as(f32, 0), energy(out[0..32])); // bit-exact pre-onset silence
    try std.testing.expect(energy(out[32..64]) > 0);
}

test "Instrument: a held chord then release stays Vmax-bounded and goes quiet" {
    const N = 64;
    var out: [N]Sample(f32) = undefined;

    var g = pan.Graph.init(std.testing.allocator, cfg(N));
    defer g.deinit();
    // 4-voice pool; play a 3-note chord (fits).
    const poly = try g.add(pan.PolyVoice(pan.SawVoice, 4), .{ .prototype = FastVoice });
    const sink = try g.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try g.connect(poly, sink);
    var eng = try g.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();

    _ = eng.sendEvent(poly.id, 0, .{ .note_on = .{ .note_id = 1, .pitch_hz = 440, .velocity = 0.8 } });
    _ = eng.sendEvent(poly.id, 0, .{ .note_on = .{ .note_id = 2, .pitch_hz = 554, .velocity = 0.8 } });
    _ = eng.sendEvent(poly.id, 0, .{ .note_on = .{ .note_id = 3, .pitch_hz = 659, .velocity = 0.8 } });
    eng.renderInto(token);
    try std.testing.expect(energy(&out) > 0); // the chord sounds
    try std.testing.expect(!eng.telemetry().fault); // no NaN/Inf, no fault

    // Release all three; with the instant-release prototype they fall silent.
    _ = eng.sendEvent(poly.id, 0, .{ .note_off = .{ .note_id = 1, .velocity = 0 } });
    _ = eng.sendEvent(poly.id, 0, .{ .note_off = .{ .note_id = 2, .velocity = 0 } });
    _ = eng.sendEvent(poly.id, 0, .{ .note_off = .{ .note_id = 3, .velocity = 0 } });
    eng.renderInto(token);
    // The next block (after release completed) is exact silence.
    eng.renderInto(token);
    for (out) |s| try std.testing.expectEqual(@as(f32, 0), s.ch[0]);
}

test "Instrument slice: PolyVoice(SawVoice,16) → ConstantPowerPan(stereo) → stereo sink" {
    // The §13 vertical slice (CoreAudioSink replaced by a capturing stereo sink —
    // the device is the hardware-deferred step). Proves the layout-typed panner path
    // commits and renders: the mono voice sum becomes a stereo planar stream, both
    // channels carry the centred constant-power signal.
    const N = 64;
    var outL: [N]f32 = undefined;
    var outR: [N]f32 = undefined;

    const num = pan.numericFor(.f32, .{});
    var g = pan.Graph.init(std.testing.allocator, .{ .precision = .f32, .sample_rate = 48_000, .block_size = N, .channels = .stereo });
    defer g.deinit();
    const poly = try g.add(pan.PolyVoice(pan.SawVoice, 16), .{ .prototype = FastVoice });
    const panner = try g.add(pan.spatial.ConstantPowerPan(num), .{ .pan = 0.0 }); // centred
    const sink = try g.add(StereoSink, .{ .destL = @as([*]f32, &outL), .destR = @as([*]f32, &outR) });
    try g.connect(poly, panner);
    try g.connect(panner, sink);
    var eng = try g.commit(); // a layout mismatch on either edge would fail HERE
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();

    // A three-note chord through the 16-voice pool, panned centre.
    _ = eng.sendEvent(poly.id, 0, .{ .note_on = .{ .note_id = 1, .pitch_hz = 440, .velocity = 0.8 } });
    _ = eng.sendEvent(poly.id, 0, .{ .note_on = .{ .note_id = 2, .pitch_hz = 554, .velocity = 0.8 } });
    _ = eng.sendEvent(poly.id, 0, .{ .note_on = .{ .note_id = 3, .pitch_hz = 659, .velocity = 0.8 } });
    eng.renderInto(token);

    var eL: f32 = 0;
    var eR: f32 = 0;
    for (outL, outR) |l, r| {
        eL += @abs(l);
        eR += @abs(r);
    }
    try std.testing.expect(eL > 0 and eR > 0); // both stereo planes sound
    // Centred constant-power pan ⇒ L and R are the same √½-scaled signal.
    for (outL, outR) |l, r| try std.testing.expectApproxEqAbs(l, r, 1e-6);
    try std.testing.expect(!eng.telemetry().fault);
    // The panner's output port carries the declared stereo layout L (⊢).
    try std.testing.expect(pan.port.MapOutPort(pan.spatial.ConstantPowerPan(num)).Elem == pan.Frame(f32, .stereo));
}

test "Instrument: scheduleEventAt places an absolute-transport event in the right block (§9 timeline)" {
    // The transport↔event-lane wiring: an event scheduled at an ABSOLUTE transport
    // sample is delivered in the block whose window contains it, at the correct
    // block-relative offset — driven by the transport advancing each render.
    const N = 32;
    var out: [N]Sample(f32) = undefined;

    var g = pan.Graph.init(std.testing.allocator, cfg(N));
    defer g.deinit();
    const poly = try g.add(pan.PolyVoice(pan.SawVoice, 4), .{ .prototype = FastVoice });
    const sink = try g.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try g.connect(poly, sink);
    var eng = try g.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();

    // note_on at absolute sample 40 ⇒ block 0 = [0,32) silent; block 1 = [32,64) has
    // the onset at offset 40−32 = 8; block 2 = [64,96) sustains. The single enqueue
    // sits in the timeline ring until block 1's window [32,64) reaches it.
    try std.testing.expect(eng.scheduleEventAt(poly.id, 40, .{ .note_on = .{ .note_id = 1, .pitch_hz = 800, .velocity = 1.0 } }));

    // Block 0 [0,32): the event (abs 40) is in the future ⇒ exact silence.
    eng.renderInto(token);
    try std.testing.expectEqual(@as(f32, 0), energy(&out));

    // Block 1 [32,64): the onset lands at offset 8 ⇒ silent before 8, sounding after.
    eng.renderInto(token);
    try std.testing.expectEqual(@as(f32, 0), energy(out[0..8])); // bit-exact pre-onset
    try std.testing.expect(energy(out[8..N]) > 0);

    // Block 2 [64,96): the note sustains (instant-attack, no release) ⇒ all sounding.
    eng.renderInto(token);
    try std.testing.expect(energy(&out) > 0);
    try std.testing.expect(!eng.telemetry().fault);
    try std.testing.expectEqual(@as(u64, 96), eng.transport.position); // advanced 3 blocks
}

test "Instrument: live + timeline events merge and sort within a block" {
    // A within-block (sendEvent) event and an absolute (scheduleEventAt) event that
    // both land in the same block are merged and offset-ordered; the earliest onset's
    // pre-roll is exactly silent and the block sounds from there.
    const N = 32;
    var out: [N]Sample(f32) = undefined;

    var g = pan.Graph.init(std.testing.allocator, cfg(N));
    defer g.deinit();
    const poly = try g.add(pan.PolyVoice(pan.SawVoice, 4), .{ .prototype = FastVoice });
    const sink = try g.add(BufSink, .{ .dest = @as([*]Sample(f32), &out) });
    try g.connect(poly, sink);
    var eng = try g.commit();
    defer eng.deinit();

    const token = enterRealtimeThread();
    defer token.leave();

    // Both land in block 0 [0,32): a live event at offset 20, and a timeline event at
    // absolute 4 (⇒ offset 4). After the merge+sort the onset at 4 precedes the one at
    // 20, so [0,4) is exactly silent and the block sounds from offset 4.
    try std.testing.expect(eng.sendEvent(poly.id, 20, .{ .note_on = .{ .note_id = 1, .pitch_hz = 600, .velocity = 1 } }));
    try std.testing.expect(eng.scheduleEventAt(poly.id, 4, .{ .note_on = .{ .note_id = 2, .pitch_hz = 700, .velocity = 1 } }));
    eng.renderInto(token);

    try std.testing.expectEqual(@as(f32, 0), energy(out[0..4])); // earliest onset is at 4
    try std.testing.expect(energy(out[4..N]) > 0);
    try std.testing.expect(!eng.telemetry().fault);
}

// ===========================================================================
// O3 — An Instrument timeline bounce is reproducible (catalog §11.1b / plan §14
// gate). Render the SAME absolutely-timed score offline twice (two fresh engines,
// driven by the wall-clock timer for a fixed block count, NOT the audio device),
// and assert the captured output is BIT-IDENTICAL. The bounce is O3-reproducible
// because the engine's event timeline is deterministic: `scheduleEventAt` events
// are drained per block by their absolute transport window and stably offset-
// sorted, so neither thread scheduling nor wall-clock timing affects the result.
// ===========================================================================

/// A capture sink that ADVANCES across blocks (unlike `BufSink`, which overwrites
/// a single block), so a multi-block offline bounce lands in one contiguous
/// buffer. Clamps at the buffer end.
const BounceSink = struct {
    const Self = @This();
    dest: []Sample(f32) = &.{},
    cursor: usize = 0,
    pub fn process(self: *Self, in: []const Sample(f32)) void {
        const n = @min(in.len, self.dest.len - self.cursor);
        @memcpy(self.dest[self.cursor .. self.cursor + n], in[0..n]);
        self.cursor += n;
    }
};

fn bounceScoreOffline(alloc: std.mem.Allocator, out: []Sample(f32), n_blocks: usize) !void {
    const N = 64;
    var g = pan.Graph.init(alloc, cfg(N));
    defer g.deinit();
    const poly = try g.add(pan.PolyVoice(pan.SawVoice, 4), .{ .prototype = FastVoice });
    const sink = try g.add(BounceSink, .{ .dest = out });
    try g.connect(poly, sink);
    var eng = try g.commit();
    defer eng.deinit();

    // A deterministic absolute-transport score spanning several blocks.
    _ = eng.scheduleEventAt(poly.id, 10, .{ .note_on = .{ .note_id = 1, .pitch_hz = 440, .velocity = 1.0 } });
    _ = eng.scheduleEventAt(poly.id, 90, .{ .note_on = .{ .note_id = 2, .pitch_hz = 660, .velocity = 0.8 } });
    _ = eng.scheduleEventAt(poly.id, 200, .{ .note_off = .{ .note_id = 1, .velocity = 0 } });

    // Offline, fixed-length: the wall-clock-timer clock renders exactly `n_blocks`
    // blocks off the audio deadline (no device).
    try eng.renderOffline(.{ .clock = .{ .wall_clock_timer = 48_000 }, .max_blocks = n_blocks });
}

test "Instrument timeline bounce is O3-reproducible (two offline renders are bit-identical)" {
    const N = 64;
    const blocks = 6;
    const T = N * blocks;
    var a: [T]Sample(f32) = undefined;
    var b: [T]Sample(f32) = undefined;
    @memset(&a, .{ .ch = .{0} });
    @memset(&b, .{ .ch = .{0} });

    try bounceScoreOffline(std.testing.allocator, &a, blocks);
    try bounceScoreOffline(std.testing.allocator, &b, blocks);

    // Bit-identical across the two independent offline renders (O3), and the
    // score actually sounded (not vacuously-equal silence).
    try std.testing.expectEqualSlices(f32, sampleVals(&a), sampleVals(&b));
    try std.testing.expect(energy(&a) > 0);
}

fn sampleVals(frames: []const Sample(f32)) []const f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(frames)));
}
