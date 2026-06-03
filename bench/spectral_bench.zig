//! Benchmark: the rate-elastic seam (the P8 measurement set).
//!
//! Measures (never asserts an oracle — correctness lives in `tests/`):
//!   (a) STFT / iSTFT / Framer / Resampler THROUGHPUT — frames or samples per
//!       second through the `pull` contract (the radix-2 FFT + Hann overlap-add
//!       cost, and the windowed-sinc resampler cost);
//!   (b) the PDC comp-delay FOOTPRINT term — the dry/wet FFT diamond's committed
//!       `footprint_bytes` and the extra bytes the auto-inserted compensating
//!       `DelayLine` adds (`insertPdc` vs the bare diamond), plus the per-rate-domain
//!       want-keyed spectral pool sizing.
//!
//! Build/run: `zig build bench` (ReleaseFast). A timing/footprint bench; no
//! `-Dbench-gate` baseline (the footprint figures are deterministic and reported,
//! not regression-gated here).

const std = @import("std");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.types.Sample;
const f32num = pan.numericFor(.f32, .{});

const FRAME = 1024;
const HOP = 256;
const N = 512; // device block
const warm = 200;
const iters = 20_000;

fn benchStft(io: std.Io, noise: []const Sample(f32)) void {
    const S = pan.Stft(f32num, FRAME, HOP);
    const BINS = FRAME / 2 + 1;
    const n_frames = N / HOP;
    var blk = S{};
    var out: [n_frames]pan.Spectrum(f32, BINS) = undefined;
    for (0..warm) |_| _ = blk.pull(noise[0..N], n_frames, &out);
    var t = h.Timer.start(io);
    for (0..iters) |i| {
        _ = blk.pull(noise[(i % 8) * N ..][0..N], n_frames, &out);
        h.consume(out[0].bin[1].re);
    }
    const ns = t.read();
    std.debug.print("  Stft(F={d},H={d}): {d:.1} ns/render  {d:.2}M frames/s\n", .{
        FRAME,                                                                                 HOP, @as(f64, @floatFromInt(ns)) / iters,
        @as(f64, @floatFromInt(n_frames * iters)) / (@as(f64, @floatFromInt(ns)) / 1e9) / 1e6,
    });
}

fn benchIstft(io: std.Io, noise: []const Sample(f32)) void {
    const S = pan.Stft(f32num, FRAME, HOP);
    const I = pan.iStft(f32num, FRAME, HOP);
    const BINS = FRAME / 2 + 1;
    const n_frames = N / HOP;
    var an = S{};
    var spec: [n_frames]pan.Spectrum(f32, BINS) = undefined;
    _ = an.pull(noise[0..N], n_frames, &spec);
    var sy = I{};
    var out: [N]Sample(f32) = undefined;
    for (0..warm) |_| _ = sy.pull(&spec, N, &out);
    var t = h.Timer.start(io);
    for (0..iters) |_| {
        _ = sy.pull(&spec, N, &out);
        h.consume(out[0].ch[0]);
    }
    const ns = t.read();
    std.debug.print("  iStft(F={d},H={d}): {d:.1} ns/render  {d:.2}M samples/s\n", .{
        FRAME,                                                                          HOP, @as(f64, @floatFromInt(ns)) / iters,
        @as(f64, @floatFromInt(N * iters)) / (@as(f64, @floatFromInt(ns)) / 1e9) / 1e6,
    });
}

/// Head-to-head: full-complex FFT on real input (pack real→[FRAME]C, full FFT)
/// vs the real-input FFT (`rfftForward`, half-length complex FFT + untangle), on
/// identical FRAME data. Both are pure scalar (no SIMD/HAL) so the ratio is the
/// algorithmic win of exploiting real-input symmetry.
fn benchFftCompare(io: std.Io, noise: []const Sample(f32)) void {
    const C = std.math.Complex(f32);
    const F = 1024;
    var re: [F]f32 = undefined;
    for (&re, 0..) |*x, i| x.* = noise[i % noise.len].ch[0];

    // full-complex
    var full_buf: [F]C = undefined;
    var t1 = h.Timer.start(io);
    for (0..iters) |_| {
        for (&full_buf, re) |*c, x| c.* = .{ .re = x, .im = 0 };
        pan.spectral.fftInPlace(f32, F, &full_buf, false);
        h.consume(full_buf[1].re);
    }
    const ns_full = @as(f64, @floatFromInt(t1.read())) / iters;

    // real-input
    var bins: [F / 2 + 1]C = undefined;
    var t2 = h.Timer.start(io);
    for (0..iters) |_| {
        pan.spectral.rfftForward(f32, F, &re, &bins);
        h.consume(bins[1].re);
    }
    const ns_rfft = @as(f64, @floatFromInt(t2.read())) / iters;

    std.debug.print("  FFT {d}-pt on real input:  full-complex {d:.1} ns  |  rfft {d:.1} ns  |  speedup {d:.2}x  |  mem {d}B vs {d}B\n", .{
        F, ns_full, ns_rfft, ns_full / ns_rfft, F * @sizeOf(C), (F / 2) * @sizeOf(C),
    });
}

fn benchResampler(io: std.Io, noise: []const Sample(f32)) void {
    const R = pan.Resampler(f32num, 2, 3, 12); // 2:3 rational resample
    var blk = R{};
    var out: [N]Sample(f32) = undefined;
    for (0..warm) |_| _ = blk.pull(noise[0..N], N, &out);
    var t = h.Timer.start(io);
    for (0..iters) |i| {
        _ = blk.pull(noise[(i % 8) * N ..][0..N], N, &out);
        h.consume(out[0].ch[0]);
    }
    const ns = t.read();
    std.debug.print("  Resampler(2:3, 25-tap): {d:.1} ns/render  {d:.2}M samples/s\n", .{
        @as(f64, @floatFromInt(ns)) / iters,
        @as(f64, @floatFromInt(N * iters)) / (@as(f64, @floatFromInt(ns)) / 1e9) / 1e6,
    });
}

// --- the dry/wet diamond footprint, with vs without the PDC comp-delay -----

const Src = struct {
    data: [*]const Sample(f32) = undefined,
    pub fn process(self: *@This(), out: []Sample(f32)) void {
        @memcpy(out, self.data[0..out.len]);
    }
};
const Gain = struct {
    pub const aliasing_safe = true;
    pub fn process(self: *@This(), in: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (in, out) |x, *o| o.* = x;
    }
};
const SpecGain = struct {
    pub fn process(self: *@This(), in: []const pan.Spectrum(f32, FRAME / 2 + 1), out: []pan.Spectrum(f32, FRAME / 2 + 1)) void {
        _ = self;
        @memcpy(out, in);
    }
};
const Mix = struct {
    pub fn process(self: *@This(), a: []const Sample(f32), b: []const Sample(f32), out: []Sample(f32)) void {
        _ = self;
        for (a, b, out) |x, y, *o| o.ch[0] = x.ch[0] + y.ch[0];
    }
};
const Snk = struct {
    pub fn process(self: *@This(), in: []const Sample(f32)) void {
        _ = self;
        _ = in;
    }
};

fn bareDiamond() pan.graph.Graph {
    const StftB = pan.Stft(f32num, FRAME, HOP);
    const IstftB = pan.iStft(f32num, FRAME, HOP);
    var g = pan.graph.Graph.empty;
    g.block_size = N;
    const src = g.add(Src);
    const gain = g.add(Gain);
    const stft = g.add(StftB);
    const spec = g.add(SpecGain);
    const istft = g.add(IstftB);
    const mix = g.add(Mix);
    const sink = g.add(Snk);
    g.connect(pan.port.MapOutPort(Src), src, 0, pan.port.MapInPort(Gain), gain, 0);
    g.connect(pan.port.MapOutPort(Src), src, 0, pan.port.RateInPort(StftB), stft, 0);
    g.connect(pan.port.RateOutPort(StftB), stft, 0, pan.port.MapInPort(SpecGain), spec, 0);
    g.connect(pan.port.MapOutPort(SpecGain), spec, 0, pan.port.RateInPort(IstftB), istft, 0);
    g.connect(pan.port.RateOutPort(IstftB), istft, 0, pan.port.MapInPortAt(Mix, 1), mix, 1);
    g.connect(pan.port.MapOutPort(Gain), gain, 0, pan.port.MapInPortAt(Mix, 0), mix, 0);
    g.connect(pan.port.MapOutPort(Mix), mix, 0, pan.port.MapInPort(Snk), sink, 0);
    return g;
}

fn reportDiamondFootprint() void {
    const bare = comptime bareDiamond();
    const pdc = comptime pan.insertPdc(bare);
    const p_bare = comptime pan.commit.commitGraph(bare, .colored) catch unreachable;
    const p_pdc = comptime pan.commit.commitGraph(pdc, .colored) catch unreachable;
    std.debug.print("  dry/wet diamond (F={d},H={d},N={d}):\n", .{ FRAME, HOP, N });
    std.debug.print("    bare footprint     = {d} B\n", .{p_bare.footprint_bytes});
    std.debug.print("    +PDC footprint     = {d} B  (comp-delay adds {d} B)\n", .{
        p_pdc.footprint_bytes, p_pdc.footprint_bytes - p_bare.footprint_bytes,
    });
}

pub fn main() void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("pan bench: rate-elastic seam (P8), Fs=48k N={d}\n", .{N});

    var noise: [8 * N]Sample(f32) = undefined;
    var rng = std.Random.DefaultPrng.init(0x5EED);
    for (&noise) |*s| s.ch[0] = rng.random().float(f32) * 2.0 - 1.0;

    std.debug.print("throughput:\n", .{});
    benchStft(io, &noise);
    benchIstft(io, &noise);
    benchResampler(io, &noise);

    std.debug.print("FFT baseline comparison (rfft vs full-complex, both scalar):\n", .{});
    benchFftCompare(io, &noise);

    std.debug.print("footprint (per-rate-domain pools + PDC comp-delay):\n", .{});
    reportDiamondFootprint();
}
