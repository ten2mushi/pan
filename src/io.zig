//! The I/O boundary — LPCM codecs, channel-order reconciliation, dither, the
//! in-memory `LpcmSource`, and the device-transport seam (CoreAudio / ALSA).
//!
//! Internal processing is f32 (large headroom); the device/file speaks LPCM in
//! one of many sample formats. The boundary codec converts interleaved device
//! bytes ↔ the internal frame representation exactly once, at the edge:
//!
//!   - **format**: signed/unsigned 8/16/32-bit, 24-bit packed (`i24`, 3 bytes),
//!     and float PCM (`f32`/`f64`), little- or big-endian. Decode normalizes to
//!     f32 in [-1, 1); encode scales, optionally dithers, and saturates.
//!   - **channel order**: the device/file order (WAV, SMPTE, device-native) is
//!     reconciled to the layout's canonical channel order. For a known layout the
//!     permutation is **total and bijective** (proven by construction — a
//!     non-bijection is rejected); the byte values it moves are themselves only
//!     empirically correct.
//!   - **dither**: truncating f32 → a narrower integer lane without dither adds
//!     correlated quantization distortion (audible on quiet fades / reverb
//!     tails). Triangular-PDF (TPDF) dither decorrelates it; it is a genuine
//!     quality requirement on any down-bit conversion, called out here, not left
//!     implicit in the cast.
//!
//! The library speaks only LPCM and stays codec-free — WAV/FLAC/MP3 → raw-LPCM
//! decoding lives in `scripts/` (an app concern; keeps the core small and
//! disk-light). The device backends are a thin transport HAL behind one
//! interface so the same engine drives CoreAudio on macOS and ALSA on Linux.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const numeric = @import("numeric.zig");
const engine = @import("engine.zig");

// ===========================================================================
// LPCM sample formats
// ===========================================================================

/// How a raw LPCM sample is encoded on the wire.
pub const Encoding = enum { signed_int, unsigned_int, float_pcm };

/// A linear-PCM sample format: encoding + byte width + endianness. `bytes == 3`
/// with `signed_int` is the packed 24-bit format (`i24`, three bytes per sample,
/// no padding). The named constants below cover the common device/file formats.
pub const PcmFormat = struct {
    encoding: Encoding,
    bytes: u8,
    big_endian: bool = false,

    pub fn byteWidth(self: PcmFormat) usize {
        return self.bytes;
    }

    pub const u8_: PcmFormat = .{ .encoding = .unsigned_int, .bytes = 1 };
    pub const s8: PcmFormat = .{ .encoding = .signed_int, .bytes = 1 };
    pub const s16le: PcmFormat = .{ .encoding = .signed_int, .bytes = 2, .big_endian = false };
    pub const s16be: PcmFormat = .{ .encoding = .signed_int, .bytes = 2, .big_endian = true };
    pub const u16le: PcmFormat = .{ .encoding = .unsigned_int, .bytes = 2, .big_endian = false };
    pub const u16be: PcmFormat = .{ .encoding = .unsigned_int, .bytes = 2, .big_endian = true };
    pub const s24le: PcmFormat = .{ .encoding = .signed_int, .bytes = 3, .big_endian = false };
    pub const s24be: PcmFormat = .{ .encoding = .signed_int, .bytes = 3, .big_endian = true };
    pub const s32le: PcmFormat = .{ .encoding = .signed_int, .bytes = 4, .big_endian = false };
    pub const s32be: PcmFormat = .{ .encoding = .signed_int, .bytes = 4, .big_endian = true };
    pub const u32le: PcmFormat = .{ .encoding = .unsigned_int, .bytes = 4, .big_endian = false };
    pub const u32be: PcmFormat = .{ .encoding = .unsigned_int, .bytes = 4, .big_endian = true };
    pub const f32le: PcmFormat = .{ .encoding = .float_pcm, .bytes = 4, .big_endian = false };
    pub const f32be: PcmFormat = .{ .encoding = .float_pcm, .bytes = 4, .big_endian = true };
    pub const f64le: PcmFormat = .{ .encoding = .float_pcm, .bytes = 8, .big_endian = false };
    pub const f64be: PcmFormat = .{ .encoding = .float_pcm, .bytes = 8, .big_endian = true };
};

/// Read an unsigned integer of `bytes` width with the given endianness from the
/// front of `src` (which must hold at least `bytes` bytes).
fn readUint(src: []const u8, bytes: usize, big_endian: bool) u64 {
    var v: u64 = 0;
    if (big_endian) {
        for (src[0..bytes]) |b| v = (v << 8) | b;
    } else {
        var i: usize = bytes;
        while (i > 0) {
            i -= 1;
            v = (v << 8) | src[i];
        }
    }
    return v;
}

fn writeUint(dst: []u8, v: u64, bytes: usize, big_endian: bool) void {
    if (big_endian) {
        var i: usize = bytes;
        var x = v;
        while (i > 0) {
            i -= 1;
            dst[i] = @truncate(x);
            x >>= 8;
        }
    } else {
        var x = v;
        for (dst[0..bytes]) |*b| {
            b.* = @truncate(x);
            x >>= 8;
        }
    }
}

/// Decode one LPCM sample at the front of `src` into normalized f32 in [-1, 1).
pub fn decodeSample(fmt: PcmFormat, src: []const u8) f32 {
    const w = fmt.byteWidth();
    switch (fmt.encoding) {
        .float_pcm => {
            if (w == 4) {
                const bits: u32 = @intCast(readUint(src, 4, fmt.big_endian));
                return @bitCast(bits);
            } else {
                const bits: u64 = readUint(src, 8, fmt.big_endian);
                return @floatCast(@as(f64, @bitCast(bits)));
            }
        },
        .signed_int => {
            const raw = readUint(src, w, fmt.big_endian);
            const bits: u6 = @intCast(w * 8);
            // Sign-extend the w-byte two's-complement value into i64.
            const shift: u6 = @intCast(64 - @as(u32, bits));
            const signed: i64 = @as(i64, @bitCast(raw << shift)) >> shift;
            const scale: f64 = @floatFromInt(@as(i64, 1) << @intCast(bits - 1));
            return @floatCast(@as(f64, @floatFromInt(signed)) / scale);
        },
        .unsigned_int => {
            const raw = readUint(src, w, fmt.big_endian);
            const bits: u32 = @intCast(w * 8);
            const mid: f64 = @floatFromInt(@as(u64, 1) << @intCast(bits - 1));
            return @floatCast((@as(f64, @floatFromInt(raw)) - mid) / mid);
        },
    }
}

/// Encode normalized f32 `x` (plus a dither offset in LSBs) into one LPCM sample
/// at the front of `dst`. Integer encodings round to nearest and saturate (never
/// wrap); `dither_lsb` is added before rounding (0 for no dither).
///
/// Clip policy at the boundary is **hard saturation**: a value outside [-1, +1)
/// is clamped to the lane's max/min code (never wrapped — a wrap would turn a
/// loud transient into full-scale noise of the opposite sign). A *soft* clip
/// (tanh-style knee) is a gain-staging choice that belongs upstream in the graph
/// as an explicit waveshaper block, not silently inside the cast.
pub fn encodeSample(fmt: PcmFormat, x: f32, dither_lsb: f32, dst: []u8) void {
    const w = fmt.byteWidth();
    switch (fmt.encoding) {
        .float_pcm => {
            if (w == 4) {
                writeUint(dst, @as(u32, @bitCast(x)), 4, fmt.big_endian);
            } else {
                writeUint(dst, @as(u64, @bitCast(@as(f64, x))), 8, fmt.big_endian);
            }
        },
        .signed_int => {
            const bits: u32 = @intCast(w * 8);
            const scale: f64 = @floatFromInt(@as(i64, 1) << @intCast(bits - 1));
            const lo: f64 = -scale;
            const hi: f64 = scale - 1.0;
            const q = std.math.clamp(@round(@as(f64, x) * scale + dither_lsb), lo, hi);
            const iv: i64 = @intFromFloat(q);
            const mask: u64 = if (bits >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(bits)) - 1;
            writeUint(dst, @as(u64, @bitCast(iv)) & mask, w, fmt.big_endian);
        },
        .unsigned_int => {
            const bits: u32 = @intCast(w * 8);
            const mid: f64 = @floatFromInt(@as(u64, 1) << @intCast(bits - 1));
            const hi: f64 = 2.0 * mid - 1.0;
            const q = std.math.clamp(@round((@as(f64, x) + 1.0) * mid + dither_lsb), 0.0, hi);
            writeUint(dst, @intFromFloat(q), w, fmt.big_endian);
        },
    }
}

// ===========================================================================
// Channel-order reconciliation
// ===========================================================================

/// A speaker position. Two layouts of the same channel count but different
/// channel order are distinguished by their position sequence, so reconciling a
/// device order to the canonical order is a permutation of positions.
pub const ChannelPos = enum(u8) {
    mono,
    front_left,
    front_right,
    front_center,
    lfe,
    back_left,
    back_right,
    side_left,
    side_right,
};

/// pan's canonical channel order for a layout (the order carried by `L` in
/// `Frame(Lane, L)`). Mono and stereo are the identity orders; surround uses the
/// SMPTE order (FL, FR, FC, LFE, side/back L, side/back R).
pub fn canonicalOrder(comptime L: types.ChannelLayout) []const ChannelPos {
    return switch (L) {
        .mono => &.{.mono},
        .stereo => &.{ .front_left, .front_right },
        .surround_5_1 => &.{ .front_left, .front_right, .front_center, .lfe, .side_left, .side_right },
        .surround_7_1 => &.{ .front_left, .front_right, .front_center, .lfe, .back_left, .back_right, .side_left, .side_right },
        else => @compileError("pan: canonicalOrder is defined for the positional layouts only"),
    };
}

/// Build the permutation that maps canonical channel slot `k` → its index in the
/// `device_order`. Verified TOTAL and BIJECTIVE: every canonical position must
/// appear exactly once in the device order, else `error.NotABijection` (a
/// mismatched channel set is not reconcilable by reordering alone). The proof is
/// the construction; the bytes it later moves are the empirical part.
pub fn channelPermutation(
    comptime C: usize,
    canonical: []const ChannelPos,
    device_order: []const ChannelPos,
) ![C]usize {
    if (canonical.len != C or device_order.len != C) return error.ChannelCountMismatch;
    var perm: [C]usize = undefined;
    var used = [_]bool{false} ** C;
    for (canonical, 0..) |pos, k| {
        var found: ?usize = null;
        for (device_order, 0..) |dpos, di| {
            if (dpos == pos and !used[di]) {
                found = di;
                break;
            }
        }
        const di = found orelse return error.NotABijection;
        used[di] = true;
        perm[k] = di;
    }
    return perm;
}

// ===========================================================================
// Dither
// ===========================================================================

/// Triangular-PDF dither source: the sum of two independent uniform draws in
/// [-0.5, 0.5) gives a triangular distribution over (-1, 1) LSB — the standard
/// quality choice for down-bit conversion (decorrelates the quantization error).
/// Seeded for reproducibility (a gold-vector codec round-trip needs determinism).
pub const Dither = struct {
    rng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Dither {
        return .{ .rng = std.Random.DefaultPrng.init(seed) };
    }

    /// Next TPDF sample in LSBs (range (-1, 1)); 0 disables when unused.
    pub fn next(self: *Dither) f32 {
        const r = self.rng.random();
        return (r.float(f32) - 0.5) + (r.float(f32) - 0.5);
    }
};

/// First-order error-feedback noise shaper, per channel. Flat (TPDF) dither
/// decorrelates the quantization error but leaves it white; a noise shaper feeds
/// the *previous* sample's quantization error back (high-pass `1 − z⁻¹`), pushing
/// the error spectrum up toward less-audible high frequencies — the standard
/// quality refinement on a down-bit conversion (f32 → i16/i24) for quiet
/// fades / reverb tails. Holds one error word per channel across calls, so it
/// must persist for the life of the stream (like `Dither`). No-op for a float
/// encoding (no quantization happens there).
pub fn NoiseShaper(comptime C: usize) type {
    return struct {
        err: [C]f32 = [_]f32{0} ** C,
    };
}

/// The integer code a format quantizes normalized `x` (+ a dither offset in LSBs)
/// to — round to nearest, saturate to the lane range, never wrap. Float formats
/// have no integer code (returns 0; callers gate on `encoding`).
fn quantizeCode(fmt: PcmFormat, x: f32, dither_lsb: f32) i64 {
    const w = fmt.byteWidth();
    const bits: u32 = @intCast(w * 8);
    switch (fmt.encoding) {
        .float_pcm => return 0,
        .signed_int => {
            const scale: f64 = @floatFromInt(@as(i64, 1) << @intCast(bits - 1));
            const lo: f64 = -scale;
            const hi: f64 = scale - 1.0;
            return @intFromFloat(std.math.clamp(@round(@as(f64, x) * scale + dither_lsb), lo, hi));
        },
        .unsigned_int => {
            const mid: f64 = @floatFromInt(@as(u64, 1) << @intCast(bits - 1));
            const hi: f64 = 2.0 * mid - 1.0;
            return @intFromFloat(std.math.clamp(@round((@as(f64, x) + 1.0) * mid + dither_lsb), 0.0, hi));
        },
    }
}

/// The normalized value an integer `code` represents under `fmt` — the inverse of
/// `quantizeCode`'s scaling, used to compute the residual quantization error.
fn codeNormalized(fmt: PcmFormat, code: i64) f32 {
    const bits: u32 = @intCast(fmt.byteWidth() * 8);
    switch (fmt.encoding) {
        .float_pcm => return 0,
        .signed_int => {
            const scale: f64 = @floatFromInt(@as(i64, 1) << @intCast(bits - 1));
            return @floatCast(@as(f64, @floatFromInt(code)) / scale);
        },
        .unsigned_int => {
            const mid: f64 = @floatFromInt(@as(u64, 1) << @intCast(bits - 1));
            return @floatCast((@as(f64, @floatFromInt(code)) - mid) / mid);
        },
    }
}

/// Write `code` as a `w`-byte integer sample (two's-complement for signed),
/// honoring endianness — the back half of an integer encode, shared by the
/// dithered/shaped path.
fn writeCode(fmt: PcmFormat, code: i64, dst: []u8) void {
    const w = fmt.byteWidth();
    const bits: u32 = @intCast(w * 8);
    const mask: u64 = if (bits >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(bits)) - 1;
    writeUint(dst, @as(u64, @bitCast(code)) & mask, w, fmt.big_endian);
}

/// Encode one sample of channel `ch` with first-order error-feedback noise
/// shaping (and optional dither) into `dst`. The shaper subtracts last sample's
/// quantization error before quantizing, then records the new error. Float
/// formats bypass shaping (exact). The order — shape, then dither, then quantize
/// — matches the standard EF-dither topology.
pub fn encodeShaped(
    comptime C: usize,
    fmt: PcmFormat,
    shaper: *NoiseShaper(C),
    ch: usize,
    x: f32,
    dither_lsb: f32,
    dst: []u8,
) void {
    if (fmt.encoding == .float_pcm) {
        encodeSample(fmt, x, 0, dst);
        return;
    }
    const v = x - shaper.err[ch]; // feed back (subtract) the previous error
    const code = quantizeCode(fmt, v, dither_lsb);
    shaper.err[ch] = codeNormalized(fmt, code) - v; // new residual error
    writeCode(fmt, code, dst);
}

// ===========================================================================
// Interleaved LPCM ↔ internal frame conversion
// ===========================================================================
//
// KNOWN NON-CONFORMANCE (tracked, scheduled — not a silent deviation): the
// internal canonical buffer layout is mandated PLANAR (C contiguous N-sample
// channel planes, plane-major) — the SIMD-friendly form, a core throughput
// requirement. But `Frame(Lane, L)` is `struct { ch: [C]Lane }`, so a `[]Frame`
// buffer is **array-of-structs / interleaved** at the buffer level for C > 1,
// which VIOLATES the planar mandate. This codec currently deinterleaves into that
// AoS `Frame` representation; for a stereo f32 device stream AoS happens to equal
// the device's interleaved layout (so today there is no transpose), but that is
// the non-conformant path. The planar-conformance phase converts the element/port
// view + the C>1 surfaces to plane-major, after which `deinterleave` transposes
// device-interleaved → planes here (the boundary is the only place the transpose
// belongs). Mono (C = 1) is already planar-conformant.

/// Decode interleaved device LPCM bytes into internal f32 frames, reconciling the
/// device channel order to the layout's canonical order. `src` holds
/// `frames · C · fmt.byteWidth()` bytes (frame-major); `dst[f].ch[k]` receives the
/// canonical channel `k` of frame `f`.
pub fn deinterleave(
    comptime L: types.ChannelLayout,
    fmt: PcmFormat,
    perm: [L.count()]usize,
    src: []const u8,
    dst: []types.Frame(f32, L),
) void {
    const C = comptime L.count();
    const w = fmt.byteWidth();
    for (dst, 0..) |*frame, f| {
        inline for (0..C) |k| {
            const di = perm[k];
            const off = (f * C + di) * w;
            frame.ch[k] = decodeSample(fmt, src[off .. off + w]);
        }
    }
}

/// Encode internal f32 frames into interleaved device LPCM bytes in the device's
/// channel order (the inverse permutation of `deinterleave`), applying `dither`
/// on an integer encoding. `dst` must hold `src.len · C · fmt.byteWidth()` bytes.
pub fn interleave(
    comptime L: types.ChannelLayout,
    fmt: PcmFormat,
    perm: [L.count()]usize,
    dither: ?*Dither,
    src: []const types.Frame(f32, L),
    dst: []u8,
) void {
    const C = comptime L.count();
    const w = fmt.byteWidth();
    const use_dither = dither != null and fmt.encoding != .float_pcm;
    for (src, 0..) |frame, f| {
        inline for (0..C) |k| {
            const di = perm[k]; // canonical k goes back to device slot di
            const off = (f * C + di) * w;
            const d: f32 = if (use_dither) dither.?.next() else 0;
            encodeSample(fmt, frame.ch[k], d, dst[off .. off + w]);
        }
    }
}

/// As `interleave`, but with first-order error-feedback **noise shaping** (plus
/// optional dither) on a down-bit integer conversion — the quality path for
/// f32 → i16/i24 output. The shaper carries per-channel error across calls, so
/// pass the same `*NoiseShaper(C)` every block. Float encodings are exact and
/// ignore both the shaper and the dither.
pub fn interleaveShaped(
    comptime L: types.ChannelLayout,
    fmt: PcmFormat,
    perm: [L.count()]usize,
    dither: ?*Dither,
    shaper: *NoiseShaper(L.count()),
    src: []const types.Frame(f32, L),
    dst: []u8,
) void {
    const C = comptime L.count();
    const w = fmt.byteWidth();
    const use_dither = dither != null and fmt.encoding != .float_pcm;
    for (src, 0..) |frame, f| {
        inline for (0..C) |k| {
            const di = perm[k];
            const off = (f * C + di) * w;
            const d: f32 = if (use_dither) dither.?.next() else 0;
            encodeShaped(C, fmt, shaper, k, frame.ch[k], d, dst[off .. off + w]);
        }
    }
}

// ===========================================================================
// LpcmSource — an in-memory Map source over preloaded internal samples
// ===========================================================================

/// `LpcmSource(num)` — a zero-sample-input Map Source over a preloaded buffer of
/// internal samples. Its output length is set by the pull demand `N` (the source
/// is itself a pull head): each render copies the next `N` samples from `data`,
/// advancing a cursor and looping at the end (so a short clip streams forever).
/// A live file/network source is the same shape over an off-thread prefetch FIFO
/// instead of a fixed buffer; that FIFO lands with the streaming phase.
pub fn LpcmSource(comptime num: numeric.Numeric) type {
    const T = num.Lane;
    return struct {
        const Self = @This();
        data: []const types.Sample(T),
        cursor: usize = 0,

        pub fn process(self: *Self, out: []types.Sample(T)) void {
            if (self.data.len == 0) {
                @memset(std.mem.sliceAsBytes(out), 0);
                return;
            }
            for (out) |*o| {
                o.* = self.data[self.cursor];
                self.cursor += 1;
                if (self.cursor >= self.data.len) self.cursor = 0;
            }
        }
    };
}

// ===========================================================================
// The device-transport HAL — one interface, two desktop backends
// ===========================================================================

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

/// The platform's default output sink, selected at comptime by target OS. On an
/// unsupported target it is the no-op backend (the seam still compiles, so the
/// rest of the library is portable; only the transport is platform-specific).
pub const CoreAudioSink = if (builtin.os.tag.isDarwin()) darwin.CoreAudioSink else Unsupported;
pub const CoreAudioSource = if (builtin.os.tag.isDarwin()) darwin.CoreAudioSource else Unsupported;
pub const AlsaSink = if (builtin.os.tag == .linux) linux.AlsaSink else Unsupported;

/// The default output sink for the build target (CoreAudio on macOS, ALSA on
/// Linux, the no-op backend elsewhere).
pub const DefaultSink = if (builtin.os.tag.isDarwin())
    darwin.CoreAudioSink
else if (builtin.os.tag == .linux)
    linux.AlsaSink
else
    Unsupported;

/// The no-op backend for targets with no implemented transport. `start` reports
/// `error.UnsupportedAudioBackend`, so wiring it is a loud runtime failure rather
/// than silent silence.
pub const Unsupported = struct {
    const Self = @This();
    pub fn backend(self: *Self) AudioBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = AudioBackend.VTable{ .start = startFn, .stop = stopFn };
    fn startFn(ptr: *anyopaque, cfg: AudioBackend.Config, render: RenderFn, user: ?*anyopaque) anyerror!void {
        _ = ptr;
        _ = cfg;
        _ = render;
        _ = user;
        return error.UnsupportedAudioBackend;
    }
    fn stopFn(ptr: *anyopaque) void {
        _ = ptr;
    }
};

// --- macOS CoreAudio backend (extern seam; dev machine) --------------------

const darwin = struct {
    // The CoreAudio / AudioUnit C surface needed to open the default output unit
    // and install a render callback. Declared here as the `extern`/`callconv(.c)`
    // interop boundary (catalog: the I/O HAL is target-specific C interop). These
    // symbols resolve against the AudioToolbox framework, linked on macOS builds.
    const OSStatus = i32;
    const AudioUnit = ?*anyopaque;
    const AudioComponent = ?*anyopaque;

    const AudioComponentDescription = extern struct {
        componentType: u32,
        componentSubType: u32,
        componentManufacturer: u32,
        componentFlags: u32 = 0,
        componentFlagsMask: u32 = 0,
    };

    const SMPTETime = extern struct {
        mSubframes: i16 = 0,
        mSubframeDivisor: i16 = 0,
        mCounter: u32 = 0,
        mType: u32 = 0,
        mFlags: u32 = 0,
        mHours: i16 = 0,
        mMinutes: i16 = 0,
        mSeconds: i16 = 0,
        mFrames: i16 = 0,
    };
    const AudioTimeStamp = extern struct {
        mSampleTime: f64 = 0,
        mHostTime: u64 = 0,
        mRateScalar: f64 = 0,
        mWordClockTime: u64 = 0,
        mSMPTETime: SMPTETime = .{},
        mFlags: u32 = 0,
        mReserved: u32 = 0,
    };
    const AudioBuffer = extern struct {
        mNumberChannels: u32,
        mDataByteSize: u32,
        mData: ?*anyopaque,
    };
    const AudioBufferList = extern struct {
        mNumberBuffers: u32,
        mBuffers: [1]AudioBuffer,
    };
    const AURenderCallback = *const fn (
        in_ref: ?*anyopaque,
        io_action_flags: ?*u32,
        in_timestamp: ?*const AudioTimeStamp,
        in_bus: u32,
        in_frames: u32,
        io_data: ?*AudioBufferList,
    ) callconv(.c) OSStatus;
    const AURenderCallbackStruct = extern struct {
        inputProc: AURenderCallback,
        inputProcRefCon: ?*anyopaque,
    };

    extern "c" fn AudioComponentFindNext(inComponent: AudioComponent, inDesc: *const AudioComponentDescription) AudioComponent;
    extern "c" fn AudioComponentInstanceNew(inComponent: AudioComponent, outInstance: *AudioUnit) OSStatus;
    extern "c" fn AudioUnitInitialize(inUnit: AudioUnit) OSStatus;
    extern "c" fn AudioUnitUninitialize(inUnit: AudioUnit) OSStatus;
    extern "c" fn AudioOutputUnitStart(inUnit: AudioUnit) OSStatus;
    extern "c" fn AudioOutputUnitStop(inUnit: AudioUnit) OSStatus;
    extern "c" fn AudioUnitSetProperty(inUnit: AudioUnit, inID: u32, inScope: u32, inElement: u32, inData: ?*const anyopaque, inSize: u32) OSStatus;
    extern "c" fn AudioUnitRender(inUnit: AudioUnit, ioActionFlags: ?*u32, inTimeStamp: *const AudioTimeStamp, inBusNumber: u32, inNumberFrames: u32, ioData: *AudioBufferList) OSStatus;

    // Constants (from AudioUnit/AUComponent.h, AudioUnitProperties.h).
    const kAudioUnitType_Output: u32 = 0x61756f75; // 'auou'
    const kAudioUnitSubType_DefaultOutput: u32 = 0x64656620; // 'def '
    const kAudioUnitSubType_HALOutput: u32 = 0x6168616c; // 'ahal' (the I/O unit usable for input)
    const kAudioUnitManufacturer_Apple: u32 = 0x6170706c; // 'appl'
    const kAudioUnitProperty_SetRenderCallback: u32 = 23;
    const kAudioOutputUnitProperty_SetInputCallback: u32 = 2005;
    const kAudioOutputUnitProperty_EnableIO: u32 = 2003;
    const kAudioUnitScope_Global: u32 = 0;
    const kAudioUnitScope_Input: u32 = 1;
    const kAudioUnitScope_Output: u32 = 2;
    const output_bus: u32 = 0;
    const input_bus: u32 = 1;

    /// The CoreAudio default-output sink. `start` opens the default output unit,
    /// installs the render callback (which mints the realtime token on the device
    /// thread and calls the user render), and starts the transport. The token is
    /// minted inside the callback because the FPCR flush-to-zero bit is per-thread
    /// and the audio thread is owned by CoreAudio, not by us.
    pub const CoreAudioSink = struct {
        const Self = @This();
        unit: AudioUnit = null,
        user_render: ?RenderFn = null,
        user_ctx: ?*anyopaque = null,
        scratch: [4096]f32 = undefined,

        pub fn backend(self: *Self) AudioBackend {
            return .{ .ptr = self, .vtable = &vtable };
        }
        const vtable = AudioBackend.VTable{ .start = startFn, .stop = stopFn };

        fn startFn(ptr: *anyopaque, cfg: AudioBackend.Config, render: RenderFn, user: ?*anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            _ = cfg;
            self.user_render = render;
            self.user_ctx = user;
            var desc = AudioComponentDescription{
                .componentType = kAudioUnitType_Output,
                .componentSubType = kAudioUnitSubType_DefaultOutput,
                .componentManufacturer = kAudioUnitManufacturer_Apple,
            };
            const comp = AudioComponentFindNext(null, &desc) orelse return error.NoDefaultOutput;
            if (AudioComponentInstanceNew(comp, &self.unit) != 0) return error.AudioUnitOpenFailed;
            var cb = AURenderCallbackStruct{ .inputProc = renderCallback, .inputProcRefCon = self };
            if (AudioUnitSetProperty(self.unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, @sizeOf(AURenderCallbackStruct)) != 0)
                return error.SetCallbackFailed;
            if (AudioUnitInitialize(self.unit) != 0) return error.AudioUnitInitFailed;
            if (AudioOutputUnitStart(self.unit) != 0) return error.AudioUnitStartFailed;
        }

        fn stopFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.unit) |u| {
                _ = AudioOutputUnitStop(u);
                _ = AudioUnitUninitialize(u);
            }
        }

        fn renderCallback(
            in_ref: ?*anyopaque,
            io_action_flags: ?*u32,
            in_timestamp: ?*const AudioTimeStamp,
            in_bus: u32,
            in_frames: u32,
            io_data: ?*AudioBufferList,
        ) callconv(.c) OSStatus {
            _ = io_action_flags;
            _ = in_timestamp;
            _ = in_bus;
            const self: *Self = @ptrCast(@alignCast(in_ref.?));
            // Mint the token on THIS (CoreAudio-owned) thread — sets FTZ/DAZ.
            const token = engine.enterRealtimeThread();
            const bl = io_data orelse return 0;
            const buf = bl.mBuffers[0];
            const n: usize = @intCast(in_frames);
            const out_ptr: [*]f32 = @ptrCast(@alignCast(buf.mData.?));
            const out = out_ptr[0 .. n * buf.mNumberChannels];
            if (self.user_render) |r| r(self.user_ctx, token, out, n) else @memset(std.mem.sliceAsBytes(out), 0);
            return 0;
        }
    };

    /// CoreAudio input (capture) source — the mirror of the sink. It opens the
    /// HAL I/O AudioUnit, enables input (bus 1) and disables output (bus 0),
    /// installs an *input* callback, and starts. The callback mints the realtime
    /// token on the CoreAudio thread, `AudioUnitRender`s the captured frames into
    /// its scratch buffer, and hands them to the user render. (Like the sink, this
    /// is the `extern`/`callconv(.c)` interop seam; opening a live capture device
    /// is the on-device gate, deferred — the device-format negotiation, e.g. the
    /// stream's actual sample rate/format, is finalized against real hardware.)
    pub const CoreAudioSource = struct {
        const Self = @This();
        unit: AudioUnit = null,
        user_render: ?RenderFn = null,
        user_ctx: ?*anyopaque = null,
        channels: u32 = 1,
        scratch: [4096]f32 = undefined,

        pub fn backend(self: *Self) AudioBackend {
            return .{ .ptr = self, .vtable = &vtable };
        }
        const vtable = AudioBackend.VTable{ .start = startFn, .stop = stopFn };

        fn startFn(ptr: *anyopaque, cfg: AudioBackend.Config, render: RenderFn, user: ?*anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.user_render = render;
            self.user_ctx = user;
            self.channels = cfg.channels;
            var desc = AudioComponentDescription{
                .componentType = kAudioUnitType_Output,
                .componentSubType = kAudioUnitSubType_HALOutput,
                .componentManufacturer = kAudioUnitManufacturer_Apple,
            };
            const comp = AudioComponentFindNext(null, &desc) orelse return error.NoInputComponent;
            if (AudioComponentInstanceNew(comp, &self.unit) != 0) return error.AudioUnitOpenFailed;
            const on: u32 = 1;
            const off: u32 = 0;
            // Enable input on bus 1, disable output on bus 0.
            if (AudioUnitSetProperty(self.unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, input_bus, &on, @sizeOf(u32)) != 0)
                return error.EnableInputFailed;
            if (AudioUnitSetProperty(self.unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, output_bus, &off, @sizeOf(u32)) != 0)
                return error.DisableOutputFailed;
            var cb = AURenderCallbackStruct{ .inputProc = inputCallback, .inputProcRefCon = self };
            if (AudioUnitSetProperty(self.unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, output_bus, &cb, @sizeOf(AURenderCallbackStruct)) != 0)
                return error.SetInputCallbackFailed;
            if (AudioUnitInitialize(self.unit) != 0) return error.AudioUnitInitFailed;
            if (AudioOutputUnitStart(self.unit) != 0) return error.AudioUnitStartFailed;
        }

        fn stopFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.unit) |u| {
                _ = AudioOutputUnitStop(u);
                _ = AudioUnitUninitialize(u);
            }
        }

        fn inputCallback(
            in_ref: ?*anyopaque,
            io_action_flags: ?*u32,
            in_timestamp: ?*const AudioTimeStamp,
            in_bus: u32,
            in_frames: u32,
            io_data: ?*AudioBufferList,
        ) callconv(.c) OSStatus {
            _ = io_data; // input callback supplies its own buffer to AudioUnitRender
            const self: *Self = @ptrCast(@alignCast(in_ref.?));
            const token = engine.enterRealtimeThread();
            const n: usize = @intCast(in_frames);
            const total = @min(n * self.channels, self.scratch.len);
            var bl = AudioBufferList{
                .mNumberBuffers = 1,
                .mBuffers = .{.{
                    .mNumberChannels = self.channels,
                    .mDataByteSize = @intCast(total * @sizeOf(f32)),
                    .mData = &self.scratch,
                }},
            };
            const ts = in_timestamp orelse return 0;
            const st = AudioUnitRender(self.unit, io_action_flags, ts, in_bus, in_frames, &bl);
            if (st != 0) return st;
            if (self.user_render) |r| r(self.user_ctx, token, self.scratch[0..total], n);
            return 0;
        }
    };
};

// --- Linux ALSA backend (extern seam; cross-compiles) ----------------------

const linux = struct {
    // The minimal ALSA PCM C surface (libasound). Declared as the interop
    // boundary; the symbols resolve against libasound when the Linux target is
    // actually linked. The cross-compile gate builds this for x86_64-linux-gnu to
    // prove the seam holds across ≥2 desktop backends — on-device testing is
    // deferred (dev is M3), the compile is the stand-in.
    const snd_pcm_t = opaque {};
    const SND_PCM_STREAM_PLAYBACK: c_int = 0;
    const SND_PCM_FORMAT_FLOAT_LE: c_int = 14;
    const SND_PCM_ACCESS_RW_INTERLEAVED: c_int = 3;

    extern "asound" fn snd_pcm_open(pcm: *?*snd_pcm_t, name: [*:0]const u8, stream: c_int, mode: c_int) c_int;
    extern "asound" fn snd_pcm_set_params(pcm: ?*snd_pcm_t, format: c_int, access: c_int, channels: c_uint, rate: c_uint, soft_resample: c_int, latency: c_uint) c_int;
    extern "asound" fn snd_pcm_writei(pcm: ?*snd_pcm_t, buffer: ?*const anyopaque, size: c_ulong) c_long;
    extern "asound" fn snd_pcm_recover(pcm: ?*snd_pcm_t, err: c_int, silent: c_int) c_int;
    extern "asound" fn snd_pcm_drain(pcm: ?*snd_pcm_t) c_int;
    extern "asound" fn snd_pcm_close(pcm: ?*snd_pcm_t) c_int;

    /// The ALSA playback sink. `start` opens the default PCM device for f32
    /// interleaved playback and drives a blocking write loop on its own thread,
    /// minting the realtime token there (FTZ is per-thread on every backend).
    pub const AlsaSink = struct {
        const Self = @This();
        pcm: ?*snd_pcm_t = null,
        running: bool = false,

        pub fn backend(self: *Self) AudioBackend {
            return .{ .ptr = self, .vtable = &vtable };
        }
        const vtable = AudioBackend.VTable{ .start = startFn, .stop = stopFn };

        fn startFn(ptr: *anyopaque, cfg: AudioBackend.Config, render: RenderFn, user: ?*anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (snd_pcm_open(&self.pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0)
                return error.AlsaOpenFailed;
            if (snd_pcm_set_params(self.pcm, SND_PCM_FORMAT_FLOAT_LE, SND_PCM_ACCESS_RW_INTERLEAVED, cfg.channels, cfg.sample_rate, 1, 100_000) < 0)
                return error.AlsaConfigFailed;
            self.running = true;
            // FTZ is per-thread on every backend, so mint the token on this
            // (ALSA write) thread before the render loop.
            const token = engine.enterRealtimeThread();
            defer token.leave();
            var buf: [4096]f32 = undefined;
            const ch = cfg.channels;
            const n = @min(cfg.block_size, buf.len / ch);
            while (self.running) {
                const out = buf[0 .. n * ch];
                render(user, token, out, n);
                var written = snd_pcm_writei(self.pcm, out.ptr, @intCast(n));
                if (written < 0) written = snd_pcm_recover(self.pcm, @intCast(written), 1);
            }
        }

        fn stopFn(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.running = false;
            if (self.pcm) |p| {
                _ = snd_pcm_drain(p);
                _ = snd_pcm_close(p);
            }
        }
    };
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "PcmFormat round-trip: float f32 is exact, integer is within one LSB" {
    const x: f32 = 0.3333;
    var buf: [4]u8 = undefined;
    encodeSample(PcmFormat.f32le, x, 0, &buf);
    try testing.expectEqual(x, decodeSample(PcmFormat.f32le, &buf));

    var b16: [2]u8 = undefined;
    encodeSample(PcmFormat.s16le, x, 0, &b16);
    const back = decodeSample(PcmFormat.s16le, &b16);
    try testing.expectApproxEqAbs(x, back, 1.0 / 32768.0);
}

test "endianness: s16le and s16be encode the same value to byte-swapped bytes" {
    var le: [2]u8 = undefined;
    var be: [2]u8 = undefined;
    encodeSample(PcmFormat.s16le, 0.5, 0, &le);
    encodeSample(PcmFormat.s16be, 0.5, 0, &be);
    try testing.expectEqual(le[0], be[1]);
    try testing.expectEqual(le[1], be[0]);
}

test "s24 packed: full-scale negative round-trips through three bytes" {
    var buf: [3]u8 = undefined;
    encodeSample(PcmFormat.s24le, -1.0, 0, &buf);
    const back = decodeSample(PcmFormat.s24le, &buf);
    try testing.expectApproxEqAbs(@as(f32, -1.0), back, 1e-6);
}

test "unsigned 8-bit centers at 128 and round-trips" {
    var buf: [1]u8 = undefined;
    encodeSample(PcmFormat.u8_, 0.0, 0, &buf);
    try testing.expectEqual(@as(u8, 128), buf[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.0), decodeSample(PcmFormat.u8_, &buf), 1.0 / 128.0);
}

test "encode saturates instead of wrapping at full scale" {
    var buf: [2]u8 = undefined;
    encodeSample(PcmFormat.s16le, 2.0, 0, &buf); // way over +1.0
    try testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, &buf, .little));
    encodeSample(PcmFormat.s16le, -2.0, 0, &buf);
    try testing.expectEqual(@as(i16, -32768), std.mem.readInt(i16, &buf, .little));
}

test "channelPermutation is bijective; reorders 5.1 WAV→canonical and rejects a non-bijection" {
    // WAV 5.1 order: FL FR FC LFE BL BR; pan canonical uses side L/R names.
    const canonical = canonicalOrder(.surround_5_1);
    const wav: []const ChannelPos = &.{ .front_left, .front_right, .front_center, .lfe, .side_left, .side_right };
    const perm = try channelPermutation(6, canonical, wav);
    // This particular order is the identity (both list FL,FR,FC,LFE,SL,SR).
    for (perm, 0..) |p, k| try testing.expectEqual(k, p);

    // A swapped device order yields a real permutation, still bijective.
    const swapped: []const ChannelPos = &.{ .front_right, .front_left, .front_center, .lfe, .side_left, .side_right };
    const p2 = try channelPermutation(6, canonical, swapped);
    try testing.expectEqual(@as(usize, 1), p2[0]); // canonical FL is at device index 1
    try testing.expectEqual(@as(usize, 0), p2[1]);

    // A channel set that is not a permutation is rejected.
    const bad: []const ChannelPos = &.{ .front_left, .front_left, .front_center, .lfe, .side_left, .side_right };
    try testing.expectError(error.NotABijection, channelPermutation(6, canonical, bad));
}

test "deinterleave ↔ interleave is a bijection on the bytes (stereo, no dither)" {
    const L = types.ChannelLayout.stereo;
    const perm = try channelPermutation(2, canonicalOrder(L), &.{ .front_left, .front_right });
    // Two stereo frames as s16le interleaved L,R,L,R.
    var src: [8]u8 = undefined;
    std.mem.writeInt(i16, src[0..2], 1000, .little);
    std.mem.writeInt(i16, src[2..4], -2000, .little);
    std.mem.writeInt(i16, src[4..6], 3000, .little);
    std.mem.writeInt(i16, src[6..8], -4000, .little);
    var frames: [2]types.Frame(f32, L) = undefined;
    deinterleave(L, PcmFormat.s16le, perm, &src, &frames);
    var out: [8]u8 = undefined;
    interleave(L, PcmFormat.s16le, perm, null, &frames, &out);
    try testing.expectEqualSlices(u8, &src, &out);
}

test "Dither is deterministic for a fixed seed (gold-vector reproducibility)" {
    var a = Dither.init(42);
    var b = Dither.init(42);
    for (0..16) |_| try testing.expectEqual(a.next(), b.next());
}

test "LpcmSource fills the pull demand and loops at the buffer end" {
    const num = comptime numeric.numericFor(.f32, .{});
    const Src = LpcmSource(num);
    var data: [3]types.Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{2} }, .{ .ch = .{3} } };
    var src = Src{ .data = &data };
    var out: [5]types.Sample(f32) = undefined;
    src.process(&out);
    // 1,2,3 then loops to 1,2.
    const want = [_]f32{ 1, 2, 3, 1, 2 };
    for (out, want) |o, w| try testing.expectEqual(w, o.ch[0]);
}

test "the default backend exists for this target and reports through the seam" {
    // The seam compiles on every target; on an unsupported one, start() fails
    // loud rather than silently producing silence.
    var u = Unsupported{};
    const be = u.backend();
    try testing.expectError(error.UnsupportedAudioBackend, be.start(.{}, undefined, null));
}
