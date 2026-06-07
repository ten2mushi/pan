//! Core event data types shared between the synthesis library and the render
//! engine: the per-note expression axis, the blessed `NoteEvent` union, the
//! time-stamped `Timed(Event)` wrapper, and the per-block event-count bound.
//!
//! These are plain comptime-known data types with no engine or DSP dependency,
//! so they live in the core layer and are consumed both by the engine's
//! out-of-band event store and by the synthesis blocks that walk the lane.

/// An MPE per-note expression axis (the continuous controllers a single held note
/// carries under MIDI Polyphonic Expression).
pub const ExprAxis = enum { timbre, bend, slide };

/// The blessed **`NoteEvent`** library union for instruments. **Pitch is in Hz**
/// (tuning-agnostic and microtonal-friendly — a note#→Hz tuning block is library,
/// not core, so the lane never assumes 12-TET). `note_id` is the routing key: an
/// `expression`/`pressure`/`note_off` carries the `note_id` of the note it targets,
/// letting `PolyVoice` route it to the exact voice slot sounding that note (MPE).
pub const NoteEvent = union(enum) {
    note_on: struct { note_id: u32, pitch_hz: f32, velocity: f32 },
    note_off: struct { note_id: u32, velocity: f32 },
    /// Polyphonic aftertouch / MPE channel pressure for one note.
    pressure: struct { note_id: u32, value: f32 },
    /// MPE per-note bend / timbre / slide.
    expression: struct { note_id: u32, axis: ExprAxis, value: f32 },
    /// A channel controller (CC number → value).
    control: struct { cc: u16, value: f32 },
    /// Channel pitch bend (normalised, −1..+1 of the bend range).
    pitch_bend: f32,
    /// Program / patch change.
    program: u16,
};

/// One time-stamped event: an `Event` tagged with the `sample_offset` within the
/// current render block at which it applies (`0 ≤ sample_offset < N`).
pub fn Timed(comptime Event: type) type {
    return struct {
        sample_offset: u32,
        event: Event,
    };
}

/// The maximum number of timed events one render block can deliver to a consuming
/// block. Bounds the engine's per-node event scratch and the stack lane builder.
pub const max_events_per_block = 128;
