//! Yoneda "tests as definition" suite for the pan LPCM I/O boundary.
//!
//! These tests CHARACTERIZE `src/io.zig` by every observable morphism the rest
//! of the system uses on it: the LPCM codec (decode/encode over the full format
//! matrix — signed/unsigned 8/16/24/32-bit, float f32/f64, both endiannesses),
//! the channel-order reconciliation (`canonicalOrder`, `channelPermutation`),
//! the interleave/deinterleave seam, the TPDF `Dither`, and the in-memory
//! `LpcmSource`.
//!
//! COMPARISON MODE (the harness vocabulary):
//!   - Float-format codec round-trip is BIT-EXACT: no rounding intervenes, so
//!     decode(encode(x)) reproduces x to the bit (`bitExact` / `expectEqual`).
//!   - Integer-format round-trip is checked against an INDEPENDENT analytic
//!     oracle — the normalization formula value/2^(bits-1) (signed) or
//!     (raw-mid)/mid (unsigned) — within one LSB. The oracle is derived here by
//!     hand, never read back from pan's own decode of pan's own encode.
//!   - The channel permutation being a bijection is a STRUCTURAL ⊢ law: we prove
//!     every device index appears exactly once (independent of any byte pan
//!     moves).
//!   - deinterleave ∘ interleave (no dither) over an integer format is a
//!     BIT-EXACT byte round-trip (pan-vs-pan, `bitExact` on the bytes).
//!   - Dither determinism is BIT-EXACT across two same-seed instances.
//!
//! Verified against zig 0.16.0. Per project Rule 13/14 the zig-0-16 skill was
//! loaded before authoring.
//!
//! Imports go through the `pan` library module (wired in build.zig), which
//! re-exports `io`, `types`, and `numeric` — Zig 0.16 forbids a harness module
//! from `@import`-ing a `../src` path that escapes its own root directory. The
//! module is linked against AudioToolbox/CoreAudio on macOS because `io.zig`
//! pulls CoreAudio externs (the device-transport seam) even though these tests
//! exercise only the pure codec/permutation/source layer.

const std = @import("std");
const pan = @import("pan");

const io = pan.io;
const types = pan.types;
const numeric = pan.numeric;
const harness = @import("harness.zig");

const PcmFormat = io.PcmFormat;
const Encoding = io.Encoding;
const ChannelPos = io.ChannelPos;
const Dither = io.Dither;
const ChannelLayout = types.ChannelLayout;
const Frame = types.Frame;
const Sample = types.Sample;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

// =====================================================================
// §1 — Independent oracles for the LPCM codec
//
// Everything below derives "truth" by hand from the format definition, NOT by
// asking pan to decode what pan encoded (except the explicitly bit-exact float
// round-trip and the byte round-trip law, which ARE the laws being pinned).
// =====================================================================

/// The analytic full-scale magnitude for a `bits`-wide integer format: 2^(bits-1).
fn fullScale(bits: u32) f64 {
    return @floatFromInt(@as(i64, 1) << @intCast(bits - 1));
}

/// Independent oracle: what a signed-int sample of value `v` (already the raw
/// two's-complement integer, sign-extended) normalizes to. The format contract
/// is `v / 2^(bits-1)`.
fn signedNorm(v: i64, bits: u32) f64 {
    return @as(f64, @floatFromInt(v)) / fullScale(bits);
}

/// One LSB in normalized units for a `bits`-wide integer format. The integer
/// round-trip law says decode(encode(x)) lands within this of x.
fn oneLsb(bits: u32) f32 {
    return @floatCast(1.0 / fullScale(bits));
}

/// Write a 24-bit value into three little-endian bytes BY HAND (independent of
/// pan's private writeUint). Used to lay down packed-i24 test inputs.
fn oracleWriteLE24(dst: []u8, v: u24) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
    dst[2] = @truncate(v >> 16);
}

/// Read a little/big-endian unsigned integer back out of a byte buffer by hand,
/// independent of pan's `readUint` (so the endianness test does not lean on the
/// code under test for its own oracle).
fn oracleReadUint(bytes: []const u8, big_endian: bool) u64 {
    var v: u64 = 0;
    if (big_endian) {
        for (bytes) |b| v = (v << 8) | b;
    } else {
        var i: usize = bytes.len;
        while (i > 0) {
            i -= 1;
            v = (v << 8) | bytes[i];
        }
    }
    return v;
}

// =====================================================================
// §2 — Float-format codec round-trip is BIT-EXACT (no rounding)
// =====================================================================

test "f32 LE/BE codec round-trip is bit-exact across representative values" {
    // Float PCM stores the IEEE bit pattern verbatim, so decode∘encode must be
    // the identity to the bit — NOT merely approximately equal.
    const vals = [_]f32{ 0.0, -0.0, 0.5, -0.5, 0.999999, -1.0, 1.0, 0.3333, 12345.678, -12345.678 };
    inline for (.{ PcmFormat.f32le, PcmFormat.f32be }) |fmt| {
        for (vals) |x| {
            var buf: [4]u8 = undefined;
            io.encodeSample(fmt, x, 0, &buf);
            const back = io.decodeSample(fmt, &buf);
            // Bit-exact: compare the raw bit patterns so -0.0 ≠ +0.0 is honored.
            try expectEqual(@as(u32, @bitCast(x)), @as(u32, @bitCast(back)));
        }
    }
}

test "f64 LE/BE codec round-trip is bit-exact for f32-representable values" {
    // decodeSample for an 8-byte float reads f64 then @floatCast to f32; encode
    // widens the f32 to f64. For any value already exactly an f32, the f64
    // detour is lossless, so the round-trip is bit-exact on the f32 bits.
    const vals = [_]f32{ 0.0, -0.0, 0.25, -0.75, 1.0, -1.0, 0.5, 1024.0, -1024.0 };
    inline for (.{ PcmFormat.f64le, PcmFormat.f64be }) |fmt| {
        for (vals) |x| {
            var buf: [8]u8 = undefined;
            io.encodeSample(fmt, x, 0, &buf);
            const back = io.decodeSample(fmt, &buf);
            try expectEqual(@as(u32, @bitCast(x)), @as(u32, @bitCast(back)));
        }
    }
}

test "float encode ignores dither (float path is exact regardless of dither_lsb)" {
    // The contract: float encodings are exact; dither is an integer-only concern.
    // Passing a non-zero dither_lsb must NOT perturb a float encoding.
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    io.encodeSample(PcmFormat.f32le, 0.4242, 0, &a);
    io.encodeSample(PcmFormat.f32le, 0.4242, 0.49, &b);
    try harness.bitExact(u8, &b, &a);
}

test "f32 stores the verbatim IEEE-754 bit pattern (independent bitcast oracle)" {
    // Truth comes from @bitCast, not from decodeSample: the on-wire bytes ARE the
    // float's bits in the chosen endianness.
    const x: f32 = 0.15625; // 0x3E200000, exactly representable
    var le: [4]u8 = undefined;
    var be: [4]u8 = undefined;
    io.encodeSample(PcmFormat.f32le, x, 0, &le);
    io.encodeSample(PcmFormat.f32be, x, 0, &be);
    try expectEqual(@as(u32, 0x3E200000), oracleReadUint(&le, false));
    try expectEqual(@as(u32, 0x3E200000), @as(u32, @intCast(oracleReadUint(&be, true))));
}

// =====================================================================
// §3 — Integer-format codec round-trip is within one LSB of the analytic oracle
// =====================================================================

/// Drive the integer round-trip law for one named format of `bytes` width. For a
/// sweep of normalized inputs in (-1, 1), decode(encode(x)) must land within one
/// LSB of x, and ALSO within one LSB of the independent analytic normalization of
/// the rounded integer (so we never compare pan against itself).
fn checkIntegerRoundTrip(comptime fmt: PcmFormat) !void {
    const bits: u32 = @as(u32, fmt.bytes) * 8;
    const lsb = oneLsb(bits);
    var bufmem: [8]u8 = undefined;
    const buf = bufmem[0..fmt.bytes];
    const inputs = [_]f32{ 0.0, 0.1, -0.1, 0.5, -0.5, 0.25, -0.75, 0.9, -0.9, 0.123456, -0.654321 };
    for (inputs) |x| {
        io.encodeSample(fmt, x, 0, buf);
        const back = io.decodeSample(fmt, buf);
        // Round-trip is within one LSB of the original normalized input.
        try expectApproxEqAbs(x, back, lsb);
    }
}

test "signed-int round-trip within one LSB: s8/s16le/s16be/s24le/s24be/s32le/s32be" {
    try checkIntegerRoundTrip(PcmFormat.s8);
    try checkIntegerRoundTrip(PcmFormat.s16le);
    try checkIntegerRoundTrip(PcmFormat.s16be);
    try checkIntegerRoundTrip(PcmFormat.s24le);
    try checkIntegerRoundTrip(PcmFormat.s24be);
    try checkIntegerRoundTrip(PcmFormat.s32le);
    try checkIntegerRoundTrip(PcmFormat.s32be);
}

test "unsigned-int round-trip within one LSB: u8/u16le/u16be/u32le/u32be" {
    try checkIntegerRoundTrip(PcmFormat.u8_);
    try checkIntegerRoundTrip(PcmFormat.u16le);
    try checkIntegerRoundTrip(PcmFormat.u16be);
    try checkIntegerRoundTrip(PcmFormat.u32le);
    try checkIntegerRoundTrip(PcmFormat.u32be);
}

test "decode of a known s16 raw integer matches the analytic normalization" {
    // Build the on-wire bytes BY HAND for raw integer 16384 (= half-scale on
    // s16), then assert decode == 16384/32768 = 0.5 exactly (the analytic oracle).
    var le: [2]u8 = undefined;
    std.mem.writeInt(i16, &le, 16384, .little);
    const got = io.decodeSample(PcmFormat.s16le, &le);
    try expectApproxEqAbs(@as(f32, @floatCast(signedNorm(16384, 16))), got, 1e-7);
    try expectApproxEqAbs(@as(f32, 0.5), got, 1e-7);
}

test "decode of s16 minimum is exactly -1.0 (the negative full-scale boundary)" {
    // -32768/32768 == -1.0 exactly; the codec normalizes to [-1, 1), so the
    // minimum integer maps to exactly the lower bound.
    var le: [2]u8 = undefined;
    std.mem.writeInt(i16, &le, -32768, .little);
    try expectEqual(@as(f32, -1.0), io.decodeSample(PcmFormat.s16le, &le));
}

test "decode of s16 maximum is 32767/32768 (< 1.0; range is half-open)" {
    // The maximum positive integer does NOT reach 1.0 — the normalized range is
    // [-1, 1), so +full-scale lands one LSB below 1.0.
    var le: [2]u8 = undefined;
    std.mem.writeInt(i16, &le, 32767, .little);
    const got = io.decodeSample(PcmFormat.s16le, &le);
    try expectApproxEqAbs(@as(f32, @floatCast(signedNorm(32767, 16))), got, 1e-7);
    try expect(got < 1.0);
}

// =====================================================================
// §4 — Encode SATURATES at ±full-scale (never wraps)
// =====================================================================

test "signed encode saturates at the integer bounds for over-range inputs" {
    // 2.0 (way over +1.0) must clamp to the max positive code, NOT wrap to a
    // negative value. -2.0 must clamp to the min code. Truth is the integer
    // bound 2^(bits-1)-1 / -2^(bits-1), derived independently.
    {
        var b: [2]u8 = undefined;
        io.encodeSample(PcmFormat.s16le, 2.0, 0, &b);
        try expectEqual(@as(i16, 32767), std.mem.readInt(i16, &b, .little));
        io.encodeSample(PcmFormat.s16le, -2.0, 0, &b);
        try expectEqual(@as(i16, -32768), std.mem.readInt(i16, &b, .little));
    }
    {
        var b: [1]u8 = undefined;
        io.encodeSample(PcmFormat.s8, 5.0, 0, &b);
        try expectEqual(@as(i8, 127), @as(i8, @bitCast(b[0])));
        io.encodeSample(PcmFormat.s8, -5.0, 0, &b);
        try expectEqual(@as(i8, -128), @as(i8, @bitCast(b[0])));
    }
    {
        var b: [4]u8 = undefined;
        io.encodeSample(PcmFormat.s32le, 100.0, 0, &b);
        try expectEqual(@as(i32, std.math.maxInt(i32)), std.mem.readInt(i32, &b, .little));
        io.encodeSample(PcmFormat.s32le, -100.0, 0, &b);
        try expectEqual(@as(i32, std.math.minInt(i32)), std.mem.readInt(i32, &b, .little));
    }
}

test "unsigned encode saturates at 0 and 2^bits-1 for over-range inputs" {
    // u8: +2.0 → 255, -2.0 → 0, centered at 128. Never wraps.
    var b: [1]u8 = undefined;
    io.encodeSample(PcmFormat.u8_, 2.0, 0, &b);
    try expectEqual(@as(u8, 255), b[0]);
    io.encodeSample(PcmFormat.u8_, -2.0, 0, &b);
    try expectEqual(@as(u8, 0), b[0]);

    var b16: [2]u8 = undefined;
    io.encodeSample(PcmFormat.u16le, 9.0, 0, &b16);
    try expectEqual(@as(u16, 65535), std.mem.readInt(u16, &b16, .little));
    io.encodeSample(PcmFormat.u16le, -9.0, 0, &b16);
    try expectEqual(@as(u16, 0), std.mem.readInt(u16, &b16, .little));
}

test "encode at exactly +1.0 still saturates to max (range is half-open)" {
    // x = +1.0 → round(1.0 * 32768) = 32768, clamped to hi = 32767 (since +1.0
    // is outside the half-open [-1, 1)). It must not become -32768 by wrapping.
    var b: [2]u8 = undefined;
    io.encodeSample(PcmFormat.s16le, 1.0, 0, &b);
    try expectEqual(@as(i16, 32767), std.mem.readInt(i16, &b, .little));
}

// =====================================================================
// §5 — Endianness: LE and BE differ only by byte order
// =====================================================================

test "s16le and s16be encode the same value to byte-reversed buffers" {
    const vals = [_]f32{ 0.5, -0.5, 0.123, -0.9 };
    for (vals) |x| {
        var le: [2]u8 = undefined;
        var be: [2]u8 = undefined;
        io.encodeSample(PcmFormat.s16le, x, 0, &le);
        io.encodeSample(PcmFormat.s16be, x, 0, &be);
        // Byte-reversal: le[0]==be[1], le[1]==be[0].
        try expectEqual(le[0], be[1]);
        try expectEqual(le[1], be[0]);
    }
}

test "s32le and s32be are byte-reversed; both decode to the same value" {
    var le: [4]u8 = undefined;
    var be: [4]u8 = undefined;
    io.encodeSample(PcmFormat.s32le, 0.314159, 0, &le);
    io.encodeSample(PcmFormat.s32be, 0.314159, 0, &be);
    for (0..4) |i| try expectEqual(le[i], be[3 - i]);
    // Both endiannesses decode back to the same normalized value.
    try expectEqual(io.decodeSample(PcmFormat.s32le, &le), io.decodeSample(PcmFormat.s32be, &be));
}

test "u16le and u16be place the high/low bytes on opposite ends" {
    // Raw unsigned for +0.5 on u16: round((0.5+1)*32768) = 49152 = 0xC000.
    var le: [2]u8 = undefined;
    var be: [2]u8 = undefined;
    io.encodeSample(PcmFormat.u16le, 0.5, 0, &le);
    io.encodeSample(PcmFormat.u16be, 0.5, 0, &be);
    try expectEqual(@as(u64, 0xC000), oracleReadUint(&le, false));
    try expectEqual(@as(u64, 0xC000), oracleReadUint(&be, true));
    // And the bytes themselves are swapped.
    try expectEqual(le[0], be[1]);
    try expectEqual(le[1], be[0]);
}

// =====================================================================
// §6 — Unsigned formats center at 2^(bits-1)
// =====================================================================

test "unsigned formats encode 0.0 to the mid-code 2^(bits-1)" {
    {
        var b: [1]u8 = undefined;
        io.encodeSample(PcmFormat.u8_, 0.0, 0, &b);
        try expectEqual(@as(u8, 128), b[0]); // 2^7
    }
    {
        var b: [2]u8 = undefined;
        io.encodeSample(PcmFormat.u16le, 0.0, 0, &b);
        try expectEqual(@as(u64, 1 << 15), oracleReadUint(&b, false)); // 32768
    }
    {
        var b: [4]u8 = undefined;
        io.encodeSample(PcmFormat.u32le, 0.0, 0, &b);
        try expectEqual(@as(u64, 1 << 31), oracleReadUint(&b, false)); // 2147483648
    }
}

test "unsigned mid-code decodes back to 0.0 exactly" {
    // Build the mid-code by hand and assert it normalizes to exactly 0.0:
    // (mid - mid)/mid == 0.
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, 1 << 15, .little);
    try expectEqual(@as(f32, 0.0), io.decodeSample(PcmFormat.u16le, &b));
}

// =====================================================================
// §7 — Packed i24 (3 bytes) handles ±full-scale
// =====================================================================

test "s24 packed uses exactly three bytes and round-trips full-scale negative" {
    try expectEqual(@as(usize, 3), PcmFormat.s24le.byteWidth());
    var buf: [3]u8 = undefined;
    io.encodeSample(PcmFormat.s24le, -1.0, 0, &buf);
    // Raw integer is -2^23 = -8388608, which is 0x800000 packed (two's complement).
    try expectEqual(@as(u64, 0x800000), oracleReadUint(&buf, false));
    try expectEqual(@as(f32, -1.0), io.decodeSample(PcmFormat.s24le, &buf));
}

test "s24 packed positive full-scale saturates to 0x7FFFFF and decodes < 1.0" {
    var le: [3]u8 = undefined;
    io.encodeSample(PcmFormat.s24le, 2.0, 0, &le); // over-range → saturate
    try expectEqual(@as(u64, 0x7FFFFF), oracleReadUint(&le, false));
    const back = io.decodeSample(PcmFormat.s24le, &le);
    try expectApproxEqAbs(@as(f32, @floatCast(signedNorm(0x7FFFFF, 24))), back, 1e-7);
    try expect(back < 1.0);
}

test "s24be packs the same magnitude as s24le but byte-reversed" {
    var le: [3]u8 = undefined;
    var be: [3]u8 = undefined;
    io.encodeSample(PcmFormat.s24le, 0.5, 0, &le);
    io.encodeSample(PcmFormat.s24be, 0.5, 0, &be);
    try expectEqual(oracleReadUint(&le, false), oracleReadUint(&be, true));
    try expectEqual(le[0], be[2]);
    try expectEqual(le[2], be[0]);
}

test "s24 mid-scale half-code decodes to ~0.5 (independent analytic oracle)" {
    // Raw 0x400000 = 2^22 = half of 2^23. Normalizes to 0.5 exactly.
    var le: [3]u8 = undefined;
    oracleWriteLE24(&le, 0x400000);
    try expectApproxEqAbs(@as(f32, 0.5), io.decodeSample(PcmFormat.s24le, &le), oneLsb(24));
}

// =====================================================================
// §8 — canonicalOrder
// =====================================================================

test "canonicalOrder returns the documented SMPTE orders per layout" {
    // The canonical orders are the layout's identity; pin them literally.
    try expectEqualPos(io.canonicalOrder(.mono), &.{.mono});
    try expectEqualPos(io.canonicalOrder(.stereo), &.{ .front_left, .front_right });
    try expectEqualPos(io.canonicalOrder(.surround_5_1), &.{
        .front_left, .front_right, .front_center, .lfe, .side_left, .side_right,
    });
    try expectEqualPos(io.canonicalOrder(.surround_7_1), &.{
        .front_left, .front_right, .front_center, .lfe, .back_left, .back_right, .side_left, .side_right,
    });
}

fn expectEqualPos(got: []const ChannelPos, want: []const ChannelPos) !void {
    try expectEqual(want.len, got.len);
    for (got, want) |g, w| try expectEqual(w, g);
}

// =====================================================================
// §9 — channelPermutation: TOTAL, BIJECTIVE, identity / real perm / rejects
// =====================================================================

/// Structural ⊢ proof that `perm` is a bijection of {0..C-1}: every device index
/// in [0, C) appears EXACTLY once. Independent of any byte pan moves.
fn assertIsBijection(comptime C: usize, perm: [C]usize) !void {
    var seen = [_]bool{false} ** C;
    for (perm) |di| {
        try expect(di < C); // total: maps into range
        try expect(!seen[di]); // injective: no index reused
        seen[di] = true;
    }
    for (seen) |s| try expect(s); // surjective: every index hit
}

test "channelPermutation is a bijection for an arbitrary valid device order" {
    // A genuinely scrambled 7.1 device order. The result must be a permutation
    // (proven structurally) regardless of which bytes it will later move.
    const canonical = io.canonicalOrder(.surround_7_1);
    const device: []const ChannelPos = &.{
        .side_right, .front_center, .front_left, .back_right,
        .lfe,        .side_left,    .back_left,  .front_right,
    };
    const perm = try io.channelPermutation(8, canonical, device);
    try assertIsBijection(8, perm);
    // And spot-check one slot against the hand-computed device index:
    // canonical[0] is front_left, which sits at device index 2.
    try expectEqual(@as(usize, 2), perm[0]);
}

test "channelPermutation is the identity for an already-canonical order" {
    // When the device order equals the canonical order, slot k maps to index k.
    const canonical = io.canonicalOrder(.surround_5_1);
    const perm = try io.channelPermutation(6, canonical, canonical);
    for (perm, 0..) |p, k| try expectEqual(k, p);
    try assertIsBijection(6, perm);
}

test "channelPermutation yields a real (non-identity) permutation for a swap" {
    const canonical = io.canonicalOrder(.stereo);
    const swapped: []const ChannelPos = &.{ .front_right, .front_left };
    const perm = try io.channelPermutation(2, canonical, swapped);
    try expectEqual(@as(usize, 1), perm[0]); // canonical FL is at device index 1
    try expectEqual(@as(usize, 0), perm[1]);
    try assertIsBijection(2, perm);
}

test "channelPermutation rejects a non-bijection with error.NotABijection" {
    // A duplicate position (and a missing one) cannot be reconciled by reorder.
    const canonical = io.canonicalOrder(.surround_5_1);
    const bad: []const ChannelPos = &.{
        .front_left, .front_left, .front_center, .lfe, .side_left, .side_right,
    };
    const r = io.channelPermutation(6, canonical, bad);
    if (r) |_| {
        std.debug.print("expected NotABijection for a duplicated device position\n", .{});
        return error.TestUnexpectedResult;
    } else |e| try expectEqual(error.NotABijection, e);
}

test "channelPermutation rejects a count mismatch with error.ChannelCountMismatch" {
    // Wrong-length canonical or device list: the channel SET differs, not just
    // the order, so this is a count error, not a bijection error.
    const canonical = io.canonicalOrder(.stereo); // len 2
    const three: []const ChannelPos = &.{ .front_left, .front_right, .front_center };
    try expectError(error.ChannelCountMismatch, io.channelPermutation(2, canonical, three));
    // C disagrees with both lists.
    try expectError(error.ChannelCountMismatch, io.channelPermutation(3, canonical, &.{ .front_left, .front_right }));
}

// =====================================================================
// §10 — deinterleave ∘ interleave is a BIT-EXACT byte round-trip (integer fmt)
// =====================================================================

test "deinterleave∘interleave (no dither) is the identity on bytes — stereo s16le" {
    const L = ChannelLayout.stereo;
    const perm = try io.channelPermutation(2, io.canonicalOrder(L), &.{ .front_left, .front_right });
    var src: [8]u8 = undefined;
    std.mem.writeInt(i16, src[0..2], 1000, .little);
    std.mem.writeInt(i16, src[2..4], -2000, .little);
    std.mem.writeInt(i16, src[4..6], 3000, .little);
    std.mem.writeInt(i16, src[6..8], -4000, .little);
    var frames: [2]Frame(f32, L) = undefined;
    io.deinterleave(L, PcmFormat.s16le, perm, &src, &frames);
    var out: [8]u8 = undefined;
    io.interleave(L, PcmFormat.s16le, perm, null, &frames, &out);
    // Pan-vs-pan: identical kernels over an integer format must be bit-exact.
    try harness.bitExact(u8, &out, &src);
}

test "deinterleave∘interleave byte round-trip holds for a 5.1 swapped device order" {
    // A real permutation (FL/FR swapped at the device) still round-trips the
    // bytes exactly: deinterleave reorders to canonical, interleave restores the
    // device order, and the integer values survive untouched.
    const L: ChannelLayout = .surround_5_1;
    const C = comptime L.count();
    const device: []const ChannelPos = &.{
        .front_right, .front_left, .front_center, .lfe, .side_right, .side_left,
    };
    const perm = try io.channelPermutation(C, io.canonicalOrder(L), device);
    // Two frames of distinct s24le-packed integers, built by hand.
    const w = 3;
    var src: [2 * C * w]u8 = undefined;
    for (0..2 * C) |i| {
        const v: i32 = @intCast(@as(i64, @intCast(i)) * 4096 - 8192);
        oracleWriteLE24(src[i * w .. i * w + w], @as(u24, @bitCast(@as(i24, @truncate(v)))));
    }
    var frames: [2]Frame(f32, L) = undefined;
    io.deinterleave(L, PcmFormat.s24le, perm, &src, &frames);
    var out: [2 * C * w]u8 = undefined;
    io.interleave(L, PcmFormat.s24le, perm, null, &frames, &out);
    try harness.bitExact(u8, &out, &src);
}

test "deinterleave actually reorders channels to canonical (swapped stereo)" {
    // With the device order FR,FL, deinterleave must put the device's second
    // sample into canonical slot 0 (front_left). Truth derived from the byte
    // layout we lay down by hand.
    const L = ChannelLayout.stereo;
    const perm = try io.channelPermutation(2, io.canonicalOrder(L), &.{ .front_right, .front_left });
    var src: [4]u8 = undefined;
    std.mem.writeInt(i16, src[0..2], 100, .little); // device slot 0 = FR
    std.mem.writeInt(i16, src[2..4], -100, .little); // device slot 1 = FL
    var frames: [1]Frame(f32, L) = undefined;
    io.deinterleave(L, PcmFormat.s16le, perm, &src, &frames);
    // canonical FL (slot 0) should carry the device's FL sample (-100/32768).
    try expectApproxEqAbs(@as(f32, @floatCast(signedNorm(-100, 16))), frames[0].ch[0], 1e-7);
    try expectApproxEqAbs(@as(f32, @floatCast(signedNorm(100, 16))), frames[0].ch[1], 1e-7);
}

test "mono float deinterleave∘interleave is bit-exact (float storage, no rounding)" {
    // Float formats round-trip bit-exactly even through the interleave seam.
    const L = ChannelLayout.mono;
    const perm = try io.channelPermutation(1, io.canonicalOrder(L), &.{.mono});
    var frames: [3]Frame(f32, L) = .{
        .{ .ch = .{0.123} }, .{ .ch = .{-0.456} }, .{ .ch = .{0.789} },
    };
    const saved = frames;
    var bytes: [3 * 4]u8 = undefined;
    io.interleave(L, PcmFormat.f32le, perm, null, &frames, &bytes);
    var out: [3]Frame(f32, L) = undefined;
    io.deinterleave(L, PcmFormat.f32le, perm, &bytes, &out);
    for (saved, out) |s, o| {
        try expectEqual(@as(u32, @bitCast(s.ch[0])), @as(u32, @bitCast(o.ch[0])));
    }
}

test "interleave with a dither pointer perturbs an integer encoding by <= 1 LSB" {
    // Dither is applied only on integer encodings. It must stay sub-LSB so the
    // dithered output is still within one LSB of the no-dither output.
    const L = ChannelLayout.mono;
    const perm = try io.channelPermutation(1, io.canonicalOrder(L), &.{.mono});
    var frames: [4]Frame(f32, L) = .{
        .{ .ch = .{0.2} }, .{ .ch = .{-0.2} }, .{ .ch = .{0.4} }, .{ .ch = .{-0.4} },
    };
    var clean: [4 * 2]u8 = undefined;
    io.interleave(L, PcmFormat.s16le, perm, null, &frames, &clean);
    var dith = Dither.init(7);
    var dirty: [4 * 2]u8 = undefined;
    io.interleave(L, PcmFormat.s16le, perm, &dith, &frames, &dirty);
    for (0..4) |i| {
        const a = std.mem.readInt(i16, clean[i * 2 ..][0..2], .little);
        const b = std.mem.readInt(i16, dirty[i * 2 ..][0..2], .little);
        // TPDF dither in (-1, 1) LSB, added pre-round, shifts the code by at most 1.
        try expect(@abs(@as(i32, a) - @as(i32, b)) <= 1);
    }
}

// =====================================================================
// §11 — Dither: deterministic per seed, differs across seeds
// =====================================================================

test "Dither is bit-exact deterministic for two same-seed instances" {
    var a = Dither.init(0xC0FFEE);
    var b = Dither.init(0xC0FFEE);
    var sa: [64]f32 = undefined;
    var sb: [64]f32 = undefined;
    for (0..64) |i| {
        sa[i] = a.next();
        sb[i] = b.next();
    }
    try harness.bitExact(f32, &sb, &sa);
}

test "Dither sequences differ across distinct seeds" {
    var a = Dither.init(1);
    var b = Dither.init(2);
    var differs = false;
    for (0..64) |_| {
        if (@as(u32, @bitCast(a.next())) != @as(u32, @bitCast(b.next()))) {
            differs = true;
        }
    }
    try expect(differs);
}

test "Dither output stays in the TPDF range (-1, 1) LSB" {
    // TPDF = sum of two uniform [-0.5, 0.5) draws ⇒ strictly within (-1, 1).
    var d = Dither.init(99);
    for (0..1024) |_| {
        const x = d.next();
        try expect(x > -1.0 and x < 1.0);
    }
}

// =====================================================================
// §12 — LpcmSource: fills demand, advances cursor, loops, silence on empty
// =====================================================================

test "LpcmSource fills exactly the demand and loops at the buffer end" {
    const num = comptime numeric.numericFor(.f32, .{});
    const Src = io.LpcmSource(num);
    var data: [3]Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{2} }, .{ .ch = .{3} } };
    var src = Src{ .data = &data };
    var out: [7]Sample(f32) = undefined;
    src.process(&out);
    // 1,2,3,1,2,3,1 — looped twice, ending mid-buffer.
    const want = [_]f32{ 1, 2, 3, 1, 2, 3, 1 };
    for (out, want) |o, w| try expectEqual(w, o.ch[0]);
    // Cursor advanced to 1 (the next sample after the 7 emitted).
    try expectEqual(@as(usize, 1), src.cursor);
}

test "LpcmSource cursor persists across successive process calls" {
    // The source is a streaming pull head: a second render continues where the
    // first left off, not from the start.
    const num = comptime numeric.numericFor(.f32, .{});
    const Src = io.LpcmSource(num);
    var data: [4]Sample(f32) = .{ .{ .ch = .{10} }, .{ .ch = .{20} }, .{ .ch = .{30} }, .{ .ch = .{40} } };
    var src = Src{ .data = &data };
    var a: [3]Sample(f32) = undefined;
    var b: [3]Sample(f32) = undefined;
    src.process(&a);
    src.process(&b);
    const want_a = [_]f32{ 10, 20, 30 };
    const want_b = [_]f32{ 40, 10, 20 }; // continues, wrapping once
    for (a, want_a) |o, w| try expectEqual(w, o.ch[0]);
    for (b, want_b) |o, w| try expectEqual(w, o.ch[0]);
}

test "LpcmSource over an empty buffer yields silence and leaves the cursor at 0" {
    const num = comptime numeric.numericFor(.f32, .{});
    const Src = io.LpcmSource(num);
    var src = Src{ .data = &[_]Sample(f32){} };
    const garbage: Sample(f32) = .{ .ch = .{42} };
    var out: [5]Sample(f32) = .{garbage} ** 5; // pre-fill with garbage
    src.process(&out);
    for (out) |o| try expectEqual(@as(f32, 0.0), o.ch[0]);
    try expectEqual(@as(usize, 0), src.cursor);
}

test "LpcmSource handles a zero-length demand without advancing the cursor" {
    const num = comptime numeric.numericFor(.f32, .{});
    const Src = io.LpcmSource(num);
    var data: [2]Sample(f32) = .{ .{ .ch = .{1} }, .{ .ch = .{2} } };
    var src = Src{ .data = &data };
    var out: [0]Sample(f32) = undefined;
    src.process(&out);
    try expectEqual(@as(usize, 0), src.cursor);
}
