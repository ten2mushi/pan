//! layout_negotiation_test — the layout-negotiation gate, end-to-end through the
//! runtime Engine.
//!
//! A wired registered channel-layout mismatch (`connectCoerced`) must cause the
//! negotiation pass to AUTO-INSERT the canonical up/down-mix matrix coercion node,
//! and the rendered composite must match an INDEPENDENT matrix-vector oracle. An
//! UNregistered layout pair must be a commit-time hard mismatch
//! (`error.LayoutMismatch`). Separately, the I/O codec's device↔canonical channel
//! ORDER reconciliation must round-trip bit-exactly.
//!
//! These exercise the auto-insertion on the COMPOSITE (the real Engine commit +
//! render), not just the matrix kernel in isolation — the gate is "wiring a
//! mismatch produces the right output", not "the matrix multiplies".
//!
//! Verified against zig 0.16.0 (the zig-0-16 skill was loaded before authoring).

const std = @import("std");
const pan = @import("pan");
const types = pan.types;
const io = pan.io;
const Sample = pan.Sample;

const inv_sqrt2: f32 = 0.7071067811865476;

// --- boundary blocks --------------------------------------------------------

/// Mono source: copies a preloaded backing store into its (mono) output.
const MonoSource = struct {
    data: [*]const Sample(f32) = undefined,
    pub fn process(self: *@This(), out: []Sample(f32)) void {
        @memcpy(out, self.data[0..out.len]);
    }
};

/// 5.1 source: fills its 6 plane-major output planes from a backing store laid out
/// as 6 contiguous N-sample planes [FL,FR,FC,LFE,Ls,Rs].
const Surround51Source = struct {
    data: [*]const f32 = undefined,
    pub fn process(self: *@This(), out: types.Planar(f32, .surround_5_1)) void {
        const n = out.frames;
        inline for (0..6) |c| @memcpy(out.plane(c), self.data[c * n .. (c + 1) * n]);
    }
};

/// Stereo sink: drains its two input planes to a plane-major destination
/// ([L-plane of N][R-plane of N]).
const StereoSink = struct {
    dest: [*]f32 = undefined,
    pub fn process(self: *@This(), in: types.PlanarConst(f32, .stereo)) void {
        const n = in.frames;
        @memcpy(self.dest[0..n], in.plane(0));
        @memcpy(self.dest[n .. 2 * n], in.plane(1));
    }
};

/// A sink on an UNregistered 3-channel discrete bus — used to prove an
/// unregistered layout pair is rejected at commit.
const Discrete3Sink = struct {
    dest: [*]f32 = undefined,
    pub fn process(self: *@This(), in: types.PlanarConst(f32, .{ .discrete = 3 })) void {
        const n = in.frames;
        inline for (0..3) |c| @memcpy(self.dest[c * n .. (c + 1) * n], in.plane(c));
    }
};

fn cfg(comptime N: usize, ch: types.ChannelLayout) pan.Config {
    return .{ .precision = .f32, .channels = ch, .block_size = N };
}

// ===========================================================================
// 1. Registered mismatch auto-inserts the canonical matrix; output ≡ oracle.
// ===========================================================================

test "negotiation auto-inserts mono→stereo: both channels equal the mono source" {
    const N = 8;
    var input: [N]Sample(f32) = undefined;
    for (&input, 0..) |*s, i| s.ch[0] = @as(f32, @floatFromInt(i + 1)) * 0.3125;
    var out: [2 * N]f32 = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N, .mono));
    defer bg.deinit();
    const src = try bg.add(MonoSource, .{ .data = @as([*]const Sample(f32), &input) });
    const sink = try bg.add(StereoSink, .{ .dest = @as([*]f32, &out) });
    try bg.connectCoerced(src, sink); // mono out → stereo in (registered)
    var eng = try bg.commit();
    defer eng.deinit();

    // The auto-inserted matrix node is a real op in the plan (source, matrix, sink).
    try std.testing.expectEqual(@as(usize, 3), eng.op_count);

    const token = pan.realtime.enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    // Canonical mono→stereo matrix is [[1],[1]] — both channels equal the input.
    for (0..N) |k| {
        try std.testing.expectApproxEqAbs(input[k].ch[0], out[k], 1e-6); // L
        try std.testing.expectApproxEqAbs(input[k].ch[0], out[N + k], 1e-6); // R
    }
    try std.testing.expect(!eng.telemetry().fault);
}

test "negotiation auto-inserts 5.1→stereo (BS.775); output matches the independent oracle" {
    const N = 4;
    // Distinct per-channel ramps so a swapped/dropped channel is caught.
    var data: [6 * N]f32 = undefined;
    for (0..6) |c| for (0..N) |k| {
        data[c * N + k] = @as(f32, @floatFromInt(10 * (c + 1) + k));
    };
    var out: [2 * N]f32 = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N, .surround_5_1));
    defer bg.deinit();
    const src = try bg.add(Surround51Source, .{ .data = @as([*]const f32, &data) });
    const sink = try bg.add(StereoSink, .{ .dest = @as([*]f32, &out) });
    try bg.connectCoerced(src, sink); // 5.1 out → stereo in (registered)
    var eng = try bg.commit();
    defer eng.deinit();

    const token = pan.realtime.enterRealtimeThread();
    defer token.leave();
    eng.renderInto(token);

    // Independent oracle (ITU-R BS.775): Lo = FL + .707·FC + .707·Ls,
    // Ro = FR + .707·FC + .707·Rs; LFE dropped. Planes: [FL,FR,FC,LFE,Ls,Rs].
    for (0..N) |k| {
        const fl = data[0 * N + k];
        const fr = data[1 * N + k];
        const fc = data[2 * N + k];
        const ls = data[4 * N + k];
        const rs = data[5 * N + k];
        try std.testing.expectApproxEqAbs(fl + inv_sqrt2 * fc + inv_sqrt2 * ls, out[k], 1e-4);
        try std.testing.expectApproxEqAbs(fr + inv_sqrt2 * fc + inv_sqrt2 * rs, out[N + k], 1e-4);
    }
    try std.testing.expect(!eng.telemetry().fault);
}

// ===========================================================================
// 2. Unregistered layout pair ⇒ commit-time hard mismatch.
// ===========================================================================

test "negotiation rejects an unregistered layout pair (stereo→discrete 3) at commit" {
    const N = 8;
    var input: [2 * N]f32 = undefined;
    @memset(&input, 0);
    var out: [3 * N]f32 = undefined;

    var bg = pan.Graph.init(std.testing.allocator, cfg(N, .stereo));
    defer bg.deinit(); // a failed commit leaks nothing (builder frees on error)
    // A stereo source for this test.
    const StereoSource = struct {
        data: [*]const f32 = undefined,
        pub fn process(self: *@This(), out_p: types.Planar(f32, .stereo)) void {
            const n = out_p.frames;
            @memcpy(out_p.plane(0), self.data[0..n]);
            @memcpy(out_p.plane(1), self.data[n .. 2 * n]);
        }
    };
    const src = try bg.add(StereoSource, .{ .data = @as([*]const f32, &input) });
    const sink = try bg.add(Discrete3Sink, .{ .dest = @as([*]f32, &out) });
    // stereo(2) → discrete(3): 3 is not a registered positional count, so no
    // canonical matrix exists — the negotiate stage must reject it.
    try bg.connectCoerced(src, sink);
    try std.testing.expectError(error.LayoutMismatch, bg.commit());
}

// ===========================================================================
// 3. I/O codec device↔canonical channel-ORDER reconciliation round-trips bit-exact.
// ===========================================================================

test "codec channel-order reconciliation round-trips bit-exactly (5.1, non-identity device order)" {
    const L: types.ChannelLayout = .surround_5_1;
    const C = comptime L.count(); // 6
    const N = 5;
    // A device that delivers channels in a NON-canonical order (e.g. a WAV whose
    // order is [FL,FR,FC,LFE,Ls,Rs] vs a device giving [FL,FR,Ls,Rs,FC,LFE]).
    const canonical = io.canonicalOrder(L);
    const device_order = [_]io.ChannelPos{ .front_left, .front_right, .side_left, .side_right, .front_center, .lfe };
    const perm = try io.channelPermutation(C, canonical, &device_order);

    // f32 PCM is exact (no quantization/dither), so a clean round-trip witnesses
    // ONLY the permutation, bit-for-bit.
    const fmt: io.PcmFormat = .f32le;

    var src_bytes: [N * C * 4]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0x5151);
    rng.random().bytes(&src_bytes);
    // Make the bytes valid finite f32s (random bytes can be NaN; round-trip of a
    // NaN bit-pattern is fine for bit-exactness, but keep it clean): overwrite with
    // a deterministic float ramp per interleaved slot.
    {
        var f: usize = 0;
        while (f < N) : (f += 1) {
            inline for (0..C) |c| {
                const v: f32 = @as(f32, @floatFromInt(f * C + c)) * 0.5 - 3.0;
                const off = (f * C + c) * 4;
                std.mem.writeInt(u32, src_bytes[off .. off + 4][0..4], @bitCast(v), .little);
            }
        }
    }

    var planar_buf: [C * N]f32 = undefined;
    const planar = types.Planar(f32, L).fromBase(&planar_buf, N);
    io.deinterleave(L, fmt, perm, &src_bytes, planar);

    var rt_bytes: [N * C * 4]u8 = undefined;
    const planar_c = types.PlanarConst(f32, L).fromBase(&planar_buf, N);
    io.interleave(L, fmt, perm, null, planar_c, &rt_bytes);

    // interleave ∘ deinterleave with the same permutation is the identity.
    try std.testing.expectEqualSlices(u8, &src_bytes, &rt_bytes);
}
