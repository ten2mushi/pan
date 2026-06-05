//! Benchmark: pan's biquad-cascade graph path vs a bare fused loop vs **Apple
//! vDSP** (Accelerate) — a head-to-head against a top-tier hand-tuned DSP library
//! on the SAME hardware, so the gap is a tracked, regression-visible number.
//!
//! **macOS only** (gated in `build.zig`; links `-framework Accelerate`). On other
//! targets it is not registered.
//!
//! MEASURES (never asserts an oracle — bench convention): f32-mono ns/sample for
//! a D-section transposed-DF-II biquad cascade, three ways —
//!   1. **pan** — `OfflineBatch.renderSequential` over `Source → Biquad×D → Sink`
//!      (the real graph path: each block is a buffer→buffer pass through the
//!      colored pool);
//!   2. **bare** — a hand-rolled fused cascade keeping the running value in a
//!      register across all D sections (one pass; the "best a tight scalar loop
//!      can do");
//!   3. **vDSP** — `vDSP_biquad` over the same cascade (the top-tier reference).
//! It prints pan÷vDSP and bare÷vDSP so a regression in pan's relative standing is
//! visible. A `pan ≡ bare` bit-exact check confirms the comparison is fair (both
//! are the identical TDF-II recurrence, so they are the same work).
//!
//! The gap pan pays to vDSP (~3–4×) is the graph-engine generality tax (the
//! per-block buffer round-trip vs a register-fused single pass), NOT the biquad
//! math (pan ≈ bare). Tight-feedback fusion (§5.4) / the loop-fusion pass close it
//! for hot cascades. Build/run: `zig build bench` (ReleaseFast, on macOS).

const std = @import("std");
const builtin = @import("builtin");
const pan = @import("pan");
const h = @import("harness.zig");

const Sample = pan.Sample;
const Source = pan.offline.Source;
const Sink = pan.offline.Sink;
const num = pan.numericFor(.f32, .{});
const Biquad = pan.filters.Biquad(num);

const b0: f32 = 0.15;
const b1: f32 = 0.3;
const b2: f32 = 0.15;
const a1: f32 = -0.5;
const a2: f32 = 0.2;
const coeffs: pan.filters.Coeffs(f32) = .{ .b0 = b0, .b1 = b1, .b2 = b2, .a1 = a1, .a2 = a2 };

// Apple Accelerate / vDSP. `vDSP_biquad_CreateSetup` takes 5·M f64 coefficients
// ([b0,b1,b2,a1,a2] per section); `vDSP_biquad` needs a (2·M+2)-float delay buffer.
extern "c" fn vDSP_biquad_CreateSetup(coeffs: [*]const f64, M: usize) ?*anyopaque;
extern "c" fn vDSP_biquad(setup: ?*anyopaque, delays: [*]f32, input: [*]const f32, is: isize, output: [*]f32, os: isize, n: usize) void;
extern "c" fn vDSP_biquad_DestroySetup(setup: ?*anyopaque) void;

// Apple vDSP real-FFT surface. `vDSP_fft_zrip` does an in-place packed real FFT over a
// split-complex buffer; the real input is first packed even→real / odd→imag by
// `vDSP_ctoz`. The forward transform's bins come out at 2× the standard DFT (vDSP's
// convention), so a faithful magnitude is `0.5·|bin|`.
const DSPComplex = extern struct { real: f32, imag: f32 };
const DSPSplitComplex = extern struct { realp: [*]f32, imagp: [*]f32 };
extern "c" fn vDSP_create_fftsetup(log2n: c_ulong, radix: c_int) ?*anyopaque; // radix 0 = radix-2
extern "c" fn vDSP_destroy_fftsetup(setup: ?*anyopaque) void;
extern "c" fn vDSP_ctoz(c: [*]const DSPComplex, ic: c_long, z: *const DSPSplitComplex, iz: c_long, n: c_ulong) void;
extern "c" fn vDSP_fft_zrip(setup: ?*anyopaque, c: *const DSPSplitComplex, stride: c_long, log2n: c_ulong, direction: c_int) void; // direction 1 = forward

/// Source → Biquad×D → Sink, built at comptime.
fn cascadeGraph(comptime D: usize, comptime N: usize) pan.graph.Graph {
    var g = pan.graph.Graph.empty;
    g.block_size = N;
    const src = g.add(Source);
    var prev = src;
    var prev_source = true;
    inline for (0..D) |_| {
        const bq = g.add(Biquad);
        if (prev_source) {
            g.connect(pan.port.MapOutPort(Source), prev, 0, pan.port.MapInPort(Biquad), bq, 0);
        } else {
            g.connect(pan.port.MapOutPort(Biquad), prev, 0, pan.port.MapInPort(Biquad), bq, 0);
        }
        prev = bq;
        prev_source = false;
    }
    const sink = g.add(Sink);
    g.connect(pan.port.MapOutPort(Biquad), prev, 0, pan.port.MapInPort(Sink), sink, 0);
    return g;
}

fn cascadeNodes(comptime D: usize) [D + 2]type {
    var nb: [D + 2]type = undefined;
    nb[0] = Source;
    inline for (1..D + 1) |i| nb[i] = Biquad;
    nb[D + 1] = Sink;
    return nb;
}

/// Bare hand-rolled transposed-DF-II cascade — identical recurrence to
/// `pan.filters.Biquad`, but the running value stays in a register across all D
/// sections (one memory pass, no inter-stage buffer).
fn BareCascade(comptime D: usize) type {
    return struct {
        z1: [D]f32 = @splat(0),
        z2: [D]f32 = @splat(0),
        fn run(self: *@This(), in: []const f32, out: []f32) void {
            for (in, out) |x, *o| {
                var v = x;
                inline for (0..D) |d| {
                    const y = b0 * v + self.z1[d];
                    self.z1[d] = b1 * v + self.z2[d] - a1 * y;
                    self.z2[d] = b2 * v - a2 * y;
                    v = y;
                }
                o.* = v;
            }
        }
    };
}

fn fillNoise(buf: []f32, seed: u64) void {
    var s = seed;
    for (buf) |*x| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        x.* = @as(f32, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(s >> 16)))))) / 2.147483648e9;
    }
}

fn nsPerSample(ns: u64, T: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(T));
}

fn scenario(comptime D: usize, comptime N: usize, io: std.Io, gpa: std.mem.Allocator, T: usize) !void {
    const g = comptime cascadeGraph(D, N);
    const node_blocks = comptime cascadeNodes(D);
    const OB = pan.OfflineBatch(g, &node_blocks);
    var tmpl: OB.InstanceTuple = undefined;
    tmpl[0] = Source{};
    inline for (1..D + 1) |i| tmpl[i] = Biquad{ .coeffs = coeffs };
    tmpl[D + 1] = Sink{};

    const in = try gpa.alloc(f32, T);
    defer gpa.free(in);
    const out_pan = try gpa.alloc(f32, T);
    defer gpa.free(out_pan);
    const out_bare = try gpa.alloc(f32, T);
    defer gpa.free(out_bare);
    const out_vdsp = try gpa.alloc(f32, T);
    defer gpa.free(out_vdsp);
    fillNoise(in, 1);

    // --- pan graph path ---
    OB.renderSequential(tmpl, in, out_pan); // warm
    var ns_pan: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var t = h.Timer.start(io);
        OB.renderSequential(tmpl, in, out_pan);
        ns_pan = @min(ns_pan, t.read());
        h.consume(out_pan[T - 1]);
    }

    // --- bare fused loop ---
    var ns_bare: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var c = BareCascade(D){};
        var t = h.Timer.start(io);
        c.run(in, out_bare);
        ns_bare = @min(ns_bare, t.read());
        h.consume(out_bare[T - 1]);
    }

    // --- Apple vDSP ---
    var coeffs64: [5 * D]f64 = undefined;
    inline for (0..D) |d| {
        coeffs64[5 * d + 0] = b0;
        coeffs64[5 * d + 1] = b1;
        coeffs64[5 * d + 2] = b2;
        coeffs64[5 * d + 3] = a1;
        coeffs64[5 * d + 4] = a2;
    }
    const setup = vDSP_biquad_CreateSetup(&coeffs64, D) orelse return error.VdspSetupFailed;
    defer vDSP_biquad_DestroySetup(setup);
    var delays: [2 * D + 2]f32 = @splat(0);
    vDSP_biquad(setup, &delays, in.ptr, 1, out_vdsp.ptr, 1, T); // warm
    var ns_vdsp: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        @memset(&delays, 0);
        var t = h.Timer.start(io);
        vDSP_biquad(setup, &delays, in.ptr, 1, out_vdsp.ptr, 1, T);
        ns_vdsp = @min(ns_vdsp, t.read());
        h.consume(out_vdsp[T - 1]);
    }

    // pan and bare are the identical TDF-II recurrence ⇒ bit-exact (the fair-work
    // witness: the three time the SAME filtering, so the ratio is meaningful).
    const same_work = std.mem.eql(u8, std.mem.sliceAsBytes(out_pan), std.mem.sliceAsBytes(out_bare));

    std.debug.print(
        "{d}x cascade ({d:>2}th-order):  pan {d:>5.2}  bare {d:>5.2}  vDSP {d:>5.2} ns/sample" ++
            "   |  pan/vDSP {d:.2}x  bare/vDSP {d:.2}x  (pan≡bare: {})\n",
        .{
            D,                                                 2 * D,
            nsPerSample(ns_pan, T),                            nsPerSample(ns_bare, T),
            nsPerSample(ns_vdsp, T),                           nsPerSample(ns_pan, T) / nsPerSample(ns_vdsp, T),
            nsPerSample(ns_bare, T) / nsPerSample(ns_vdsp, T), same_work,
        },
    );
}

/// pan's real FFT (`rfftForward`: real → N/2+1 complex bins) vs vDSP's packed real
/// FFT (`vDSP_fft_zrip`), same N-point transform of the same input, ns/transform.
/// Unlike the biquad there is no bit-exact check (the two use different bin packing
/// and vDSP's forward is 2× the standard DFT), so a magnitude-energy ratio is printed
/// as the fair-work witness — both transform the same signal, so it lands near 1.0.
fn fftScenario(comptime N: usize, io: std.Io, gpa: std.mem.Allocator, iters: usize) !void {
    _ = gpa;
    const C = std.math.Complex(f32);
    const log2n: c_ulong = comptime std.math.log2_int(usize, N);
    var re: [N]f32 = undefined;
    fillNoise(&re, 7);

    // --- pan rfftForward (real input → half-spectrum, allocation-free) ---
    var bins: [N / 2 + 1]C = undefined;
    pan.spectral.rfftForward(f32, N, &re, &bins); // warm
    var ns_pan: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var t = h.Timer.start(io);
        var it: usize = 0;
        while (it < iters) : (it += 1) pan.spectral.rfftForward(f32, N, &re, &bins);
        ns_pan = @min(ns_pan, t.read());
        h.consume(bins[1].re);
    }

    // --- vDSP packed real FFT (ctoz pack + in-place zrip forward) ---
    const setup = vDSP_create_fftsetup(log2n, 0) orelse return error.VdspFftSetupFailed;
    defer vDSP_destroy_fftsetup(setup);
    var realp: [N / 2]f32 = undefined;
    var imagp: [N / 2]f32 = undefined;
    const split = DSPSplitComplex{ .realp = &realp, .imagp = &imagp };
    const cin: [*]const DSPComplex = @ptrCast(&re);
    vDSP_ctoz(cin, 2, &split, 1, N / 2);
    vDSP_fft_zrip(setup, &split, 1, log2n, 1); // warm
    var ns_vdsp: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var t = h.Timer.start(io);
        var it: usize = 0;
        while (it < iters) : (it += 1) {
            vDSP_ctoz(cin, 2, &split, 1, N / 2);
            vDSP_fft_zrip(setup, &split, 1, log2n, 1);
        }
        ns_vdsp = @min(ns_vdsp, t.read());
        h.consume(realp[1]);
    }

    // Fair-work witness: total spectral energy. vDSP packs DC in realp[0], Nyquist in
    // imagp[0], and is 2× the standard DFT, so its energy is rescaled by 0.25 to compare
    // with pan's standard-DFT bins.
    var e_pan: f64 = 0;
    for (bins) |z| e_pan += @as(f64, z.re) * z.re + @as(f64, z.im) * z.im;
    var e_vdsp: f64 = 0;
    var k: usize = 0;
    while (k < N / 2) : (k += 1) e_vdsp += @as(f64, realp[k]) * realp[k] + @as(f64, imagp[k]) * imagp[k];
    e_vdsp *= 0.25;
    const per_pan = @as(f64, @floatFromInt(ns_pan)) / @as(f64, @floatFromInt(iters));
    const per_vdsp = @as(f64, @floatFromInt(ns_vdsp)) / @as(f64, @floatFromInt(iters));
    std.debug.print(
        "  rfft {d:>4}-pt:  pan {d:>8.1}  vDSP {d:>8.1} ns/transform   |  pan/vDSP {d:.2}x   (energy ratio {d:.3})\n",
        .{ N, per_pan, per_vdsp, per_pan / per_vdsp, if (e_vdsp > 0) e_pan / e_vdsp else 0 },
    );
}

pub fn main() !void {
    if (comptime !builtin.os.tag.isDarwin()) {
        std.debug.print("vdsp-compare: macOS-only (Accelerate); skipped on this target.\n", .{});
        return;
    }
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    std.debug.print("=== pan vs bare loop vs Apple vDSP — f32 mono biquad cascade (ns/sample, lower=faster) ===\n", .{});
    try scenario(2, 512, io, gpa, 1 << 22);
    try scenario(4, 512, io, gpa, 1 << 22);
    try scenario(8, 512, io, gpa, 1 << 22);

    std.debug.print("\n=== pan rfftForward vs Apple vDSP — f32 real FFT (ns/transform, lower=faster) ===\n", .{});
    try fftScenario(256, io, gpa, 1 << 14);
    try fftScenario(512, io, gpa, 1 << 14);
    try fftScenario(1024, io, gpa, 1 << 13);
    try fftScenario(2048, io, gpa, 1 << 13);
}
