//! The device-transport seam factored into the core layer: the render-callback
//! function type, the per-platform `AudioBackend` interface, and the musical
//! `Transport` timeline. Lives here (rather than in the I/O surface) so the engine
//! can depend on it directly. Imports the engine only for the realtime token type.

const engine = @import("engine.zig");

/// The render callback the device invokes: it is the realtime `PullRoot`. The
/// backend mints a `RealtimeToken` on its own audio thread (closing the FTZ
/// footgun) and hands it to the user render function along with the output frame
/// buffer and the frame count for this callback.
pub const RenderFn = *const fn (user: ?*anyopaque, token: engine.RealtimeToken, out: []f32, frames: usize) void;

/// A device backend: open a stream of `(sample_rate, channels, block_size)`,
/// start/stop the callback-driven transport, close. Implemented per platform; the
/// engine drives any backend through this seam unchanged.
pub const AudioBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Config = struct {
        sample_rate: u32 = 48_000,
        channels: u16 = 2,
        block_size: usize = 512,
    };

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, cfg: Config, render: RenderFn, user: ?*anyopaque) anyerror!void,
        stop: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(self: AudioBackend, cfg: Config, render: RenderFn, user: ?*anyopaque) !void {
        return self.vtable.start(self.ptr, cfg, render, user);
    }
    pub fn stop(self: AudioBackend) void {
        self.vtable.stop(self.ptr);
    }
};

/// `Transport` — the musical timeline: a sample-accurate play position the event
/// lane timestamps against, plus tempo and loop points. The engine advances it by
/// the block length each render, so an offline bounce is a **pure function of the
/// transport** (bit-reproducible regardless of wall-clock). Seekable and loopable;
/// external sync (MIDI clock / Ableton Link) would sit here (not implemented).
pub const Transport = struct {
    /// Sample-accurate play position (samples since transport start or last seek).
    position: u64 = 0,
    /// The render sample rate, for the seconds / PPQ conversions.
    sample_rate: f64 = 48_000,
    /// Tempo in quarter notes per minute (BPM).
    tempo_bpm: f64 = 120,
    /// Whether the transport is rolling (a stopped transport holds its position).
    playing: bool = true,
    /// Loop region: when enabled and `position` reaches `loop_end`, it wraps back to
    /// `loop_start` (sample-accurate, the loop length preserved across the wrap).
    loop_enabled: bool = false,
    loop_start: u64 = 0,
    loop_end: u64 = 0,

    /// Advance by `n` samples (one render block). A no-op while stopped. Wraps inside
    /// an active loop region so a looped bounce repeats deterministically.
    pub fn advance(self: *Transport, n: usize) void {
        if (!self.playing) return;
        self.position += n;
        if (self.loop_enabled and self.loop_end > self.loop_start and self.position >= self.loop_end) {
            const span = self.loop_end - self.loop_start;
            self.position = self.loop_start + (self.position - self.loop_start) % span;
        }
    }
    /// Jump to an absolute sample position (sample-accurate seek).
    pub fn seek(self: *Transport, pos: u64) void {
        self.position = pos;
    }
    pub fn setTempo(self: *Transport, bpm: f64) void {
        self.tempo_bpm = bpm;
    }
    /// Enable a loop region `[start, end)`; `end ≤ start` disables looping.
    pub fn setLoop(self: *Transport, start: u64, end: u64) void {
        self.loop_start = start;
        self.loop_end = end;
        self.loop_enabled = end > start;
    }
    /// Elapsed seconds at the current position.
    pub fn seconds(self: Transport) f64 {
        return @as(f64, @floatFromInt(self.position)) / self.sample_rate;
    }
    /// Musical position in quarter notes (PPQ) = seconds · tempo / 60.
    pub fn ppq(self: Transport) f64 {
        return self.seconds() * self.tempo_bpm / 60.0;
    }
};
